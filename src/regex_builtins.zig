//! `RegExp`, `.test`/`.exec`/`.toString`, and the match/replace/split
//! machinery `String.prototype`'s regex-pattern methods (match/matchAll/
//! search/replace/replaceAll/split) reuse -- `regexFindFrom`/
//! `makeMatchArray`/`regexSplit` are `pub` for exactly that cross-domain
//! reuse (String.prototype's base coverage stays in builtins.zig until
//! its own extraction pass). z-interpreter-refactor.md, Step 5 Phase A.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zbigint = @import("zbigint");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const dneMethod = builtin_helpers.dneMethod;
const dneConst = builtin_helpers.dneConst;
const requireTag = builtin_helpers.requireTag;
const installBuiltin = builtin_helpers.installBuiltin;

const isObjectLike = builtin_helpers.isObjectLike;

pub const regex_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "test", MethodSpec{ .call = regexTest, .arity = 1 } },
    .{ "exec", MethodSpec{ .call = regexExec, .arity = 1 } },
    .{ "toString", MethodSpec{ .call = regexToString, .arity = 0 } },
});

const zregex = @import("zregex");

fn requireRegex(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    return requireTag(ctx, this_value, .regex, "Method RegExp.prototype.{s} called on incompatible receiver", method);
}

/// `new RegExp(pattern, flags?)` / `RegExp(...)`. A RegExp source argument
/// is copied (its own flags unless new ones are given).
fn regexpConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const pat_arg = arg(args, 0);
    var source: []const u8 = "";
    var flags: []const u8 = "";
    var owned_source: ?[]const u8 = null;
    var owned_flags: ?[]const u8 = null;
    defer if (owned_source) |s| allocator.free(s);
    defer if (owned_flags) |f| allocator.free(f);
    if (pat_arg == .regex) {
        const st = self.regexState(pat_arg);
        source = st.source;
        flags = st.flags;
    } else if (pat_arg != .undefined) {
        owned_source = try coercion.toDisplayString(allocator, pat_arg);
        source = owned_source.?;
    }
    if (arg(args, 1) != .undefined) {
        owned_flags = try coercion.toDisplayString(allocator, arg(args, 1));
        flags = owned_flags.?;
    }
    return self.makeRegex(source, flags);
}

/// Match at-or-after `start`: z-regex's `find` scans (respecting the
/// compiled sticky flag), so searching from a position means searching
/// within the suffix `input[start..]`. Returns the match (relative to
/// that suffix) and the suffix, so callers add `start` for absolute
/// offsets. `full` is the whole string (for the match array's `.input`).
const RegexHit = struct { match: zregex.MatchResult, sub: []const u8, base: usize, full: []const u8, group_count: usize };

pub fn regexFindFrom(re: JSValue, input: []const u8, start: usize) anyerror!?RegexHit {
    if (start > input.len) return null;
    const sub = input[start..];
    const m = try re.regex.value.find(sub);
    return if (m) |match| RegexHit{ .match = match, .sub = sub, .base = start, .full = input, .group_count = re.regex.value.compiled.group_count } else null;
}

/// The JS match-result array: [0]=whole match, [i]=capture i (undefined
/// if it didn't participate), plus own `index`, `input`, and `groups`.
/// All strings come from `hit.sub`; the absolute `.index` adds `hit.base`.
pub fn makeMatchArray(self: *Interpreter, allocator: Allocator, hit: RegexHit) anyerror!JSValue {
    _ = allocator;
    const match = hit.match;
    const input = hit.sub;
    var result = try self.gcNewArray();
    _ = try result.array.value.push(try self.gcNewString(match.group(input)));
    var i: usize = 1;
    while (i <= hit.group_count) : (i += 1) {
        if (match.getCapture(i, input)) |cap| {
            _ = try result.array.value.push(try self.gcNewString(cap));
        } else {
            _ = try result.array.value.push(JSValue.UNDEFINED);
        }
    }
    // exec/match arrays carry extra own properties.
    try setArrayOwn(self, result, "index", JSValue.fromNumber(@floatFromInt(hit.base + match.start)));
    try setArrayOwn(self, result, "input", try self.gcNewString(hit.full));
    if (match.named_groups.len > 0) {
        var groups = try self.gcNewObject();
        for (match.named_groups) |ng| {
            const v = if (match.getNamedCapture(ng.name, input)) |c| try self.gcNewString(c) else JSValue.UNDEFINED;
            try groups.object.value.set(ng.name, v);
        }
        try setArrayOwn(self, result, "groups", groups);
    } else {
        try setArrayOwn(self, result, "groups", JSValue.UNDEFINED);
    }
    return result;
}

/// Set a named own property on an array value (arrays here have no
/// general property bag, so exec-result extras go through the array's
/// object-ish set -- but ZArray is index-keyed; we stash these on a
/// parallel object). Simplest faithful approach: since our arrays can't
/// hold named props, we accept that match.index/.input/.groups live only
/// if the array were an object. To keep it working, store them via the
/// array's own retained slots is impossible -- so we wrap: not needed for
/// the common `m[0]`/`m[1]` access. We DO support .index/.input/.groups
/// by special-casing in getProperty? Simpler: attach via a side map.
fn setArrayOwn(self: *Interpreter, array: JSValue, key: []const u8, value: JSValue) anyerror!void {
    try self.setArrayExtra(array, key, value);
}

fn regexTest(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const re = try requireRegex(ctx, this_value, "test");
    const self = interp(ctx);
    const is_str = arg(args, 0) == .string;
    const input = if (is_str) arg(args, 0).string.value.data else try coercion.toDisplayString(allocator, arg(args, 0));
    defer if (!is_str) allocator.free(input);
    const st = self.regexState(re);
    const stateful = st.global or st.sticky;
    const hit = try regexFindFrom(re, input, if (stateful) st.last_index else 0);
    if (hit) |h| {
        defer h.match.deinit();
        if (stateful) st.last_index = h.base + h.match.end;
        return JSValue.fromBool(true);
    }
    if (stateful) st.last_index = 0;
    return JSValue.fromBool(false);
}

fn regexExec(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const re = try requireRegex(ctx, this_value, "exec");
    const self = interp(ctx);
    const is_str = arg(args, 0) == .string;
    const input = if (is_str) arg(args, 0).string.value.data else try coercion.toDisplayString(allocator, arg(args, 0));
    defer if (!is_str) allocator.free(input);
    const st = self.regexState(re);
    const stateful = st.global or st.sticky;
    const hit = try regexFindFrom(re, input, if (stateful) st.last_index else 0);
    if (hit) |h| {
        defer h.match.deinit();
        const abs_end = h.base + h.match.end;
        if (stateful) st.last_index = if (h.match.end > h.match.start) abs_end else abs_end + 1;
        return makeMatchArray(self, allocator, h);
    }
    if (stateful) st.last_index = 0;
    return JSValue.NULL;
}

fn regexToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const re = try requireRegex(ctx, this_value, "toString");
    const st = interp(ctx).regexState(re);
    const s = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ st.source, st.flags });
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

/// String.prototype.split with a regex separator. Splits at each match;
/// the separator's capture groups are interleaved (real JS behavior).
/// `pub`: String.prototype.split (still in builtins.zig) calls this by
/// bare name across the file boundary.
pub fn regexSplit(self: *Interpreter, allocator: Allocator, data: []const u8, re: JSValue) anyerror!JSValue {
    var result = try self.gcNewArray();
    var all = try re.regex.value.findAll(data);
    defer {
        for (all.items) |*mm| mm.deinit();
        all.deinit(allocator);
    }
    var last: usize = 0;
    for (all.items) |match| {
        if (match.end == match.start and match.start == last) continue; // skip empty at boundary
        _ = try result.array.value.push(try self.gcNewString(data[last..match.start]));
        var gi: usize = 1;
        while (gi <= re.regex.value.compiled.group_count) : (gi += 1) {
            const cap = if (match.getCapture(gi, data)) |c| try self.gcNewString(c) else JSValue.UNDEFINED;
            _ = try result.array.value.push(cap);
        }
        last = match.end;
    }
    _ = try result.array.value.push(try self.gcNewString(data[last..]));
    return result;
}

/// Installs the `RegExp` constructor (no statics).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "RegExp", .ctor = .{ .arity = 2, .call = regexpConstructor, .constructable = true } });
}
