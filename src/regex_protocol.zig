//! The RegExp protocol of ECMA-262 around matching: RegExpExec,
//! RegExp.prototype.test, RegExp.prototype[@@match/@@matchAll/@@replace/
//! @@search/@@split], GetSubstitution, and the String.prototype methods
//! that dispatch to them (match/matchAll/replace/replaceAll/search/split).
//! The matching itself is z-regex's, through regex_builtins
//! (builtinExec/execRaw); every algorithm here follows the spec text
//! (ES2024 22.2.6, 22.1.3) and reaches a RegExp only through Get/Set/Call,
//! so a user `exec`, `flags` or `lastIndex` is honored like in any engine.
//! Indices are UTF-16 code units; strings are WTF-8 (see regex_builtins).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zstring = @import("zstring");
const zregex = @import("zregex");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const coercion = @import("coercion.zig");
const rb = @import("regex_builtins.zig");
const string_builtins = @import("string_builtins.zig");

const interp = native_helpers.interp;
const arg = native_helpers.arg;
const isObjectLike = builtin_helpers.isObjectLike;
const toLength = builtin_helpers.toLength;
const makeArrayIterator = builtin_helpers.makeArrayIterator;
const appendWtf8Merged = string_builtins.appendWtf8Merged;

// ===== Abstract operations =====

/// ToString(v) as a string JSValue (owned by the caller).
fn toStringValue(self: *Interpreter, allocator: Allocator, v: JSValue) anyerror!JSValue {
    if (v == .string) return v.retain();
    const s = try self.toDisplayStringJS(allocator, v);
    defer allocator.free(s);
    return self.gcNewString(s);
}

/// ToString(Get(o, key)) (owned).
fn getString(self: *Interpreter, allocator: Allocator, o: JSValue, key: []const u8) anyerror!JSValue {
    const v = try self.getProperty(o, key);
    defer v.deinit();
    return toStringValue(self, allocator, v);
}

/// ToLength(Get(o, key)).
fn getLength(self: *Interpreter, o: JSValue, key: []const u8) anyerror!usize {
    const v = try self.getProperty(o, key);
    defer v.deinit();
    return toLength(self, v);
}

/// Set(o, key, n, true) for a number.
fn setNumber(self: *Interpreter, o: JSValue, key: []const u8, n: usize) anyerror!void {
    try self.setPropertyOnValue(o, key, JSValue.fromNumber(@floatFromInt(n)));
}

fn isCallable(v: JSValue) bool {
    return switch (v) {
        .function => true,
        .proxy => |p| isCallable(p.value.target),
        else => false,
    };
}

fn hasFlag(flags: JSValue, c: u8) bool {
    return std.mem.indexOfScalar(u8, flags.string.value.data, c) != null;
}

/// UTF-16 length of a string JSValue.
fn len16(s: JSValue) usize {
    return zstring.utf16.lengthUtf16(s.string.value.data);
}

/// The subject position of UTF-16 index `i` (the end past the length).
fn posOf(data: []const u8, i: usize) usize {
    return rb.utf16ToPos(data, i) orelse data.len;
}

/// The substring [from, to) of `s`, in UTF-16 units.
fn substring(self: *Interpreter, allocator: Allocator, s: JSValue, from: usize, to: usize) anyerror!JSValue {
    const data = s.string.value.data;
    return rb.sliceValue(self, allocator, data, posOf(data, from), posOf(data, to));
}

/// ToIntegerOrInfinity(v), clamped to [0, max].
fn toClampedIndex(self: *Interpreter, v: JSValue, max: usize) anyerror!usize {
    const n = try self.toNumberJS(v);
    if (std.math.isNan(n) or n <= 0) return 0;
    const t = @trunc(n);
    if (t >= @as(f64, @floatFromInt(max))) return max;
    return @intFromFloat(t);
}

/// AdvanceStringIndex(S, index, unicode), in UTF-16 units.
fn advanceStringIndex(data: []const u8, index: usize, unicode: bool) usize {
    if (!unicode) return index + 1;
    if (index + 1 >= zstring.utf16.lengthUtf16(data)) return index + 1;
    const a = zstring.utf16.codeUnitAt(data, index) catch return index + 1;
    if (a < 0xD800 or a > 0xDBFF) return index + 1;
    const b = zstring.utf16.codeUnitAt(data, index + 1) catch return index + 1;
    return if (b >= 0xDC00 and b <= 0xDFFF) index + 2 else index + 1;
}

/// GetMethod(v, @@name): the callable, or null if undefined/null.
fn getMethod(self: *Interpreter, v: JSValue, comptime name: []const u8) anyerror!?JSValue {
    const key = try rb.wellKnownKey(self, name);
    defer self.gc_allocator.free(key);
    const f = try self.getProperty(v, key);
    if (f == .undefined or f == .null) return null;
    if (!isCallable(f)) {
        f.deinit();
        return self.throwError(.type_error, "Symbol." ++ name ++ " is not a function", .{});
    }
    return f;
}

/// IsRegExp(v): an object whose @@match is truthy, or (if @@match is
/// undefined) a real RegExp.
fn isRegExp(self: *Interpreter, v: JSValue) anyerror!bool {
    if (!isObjectLike(v)) return false;
    const key = try rb.wellKnownKey(self, "match");
    defer self.gc_allocator.free(key);
    const m = try self.getProperty(v, key);
    defer m.deinit();
    if (m != .undefined) return coercion.isTruthy(m);
    return v == .regex;
}

/// The %RegExp% intrinsic (the original constructor, whatever the global
/// `RegExp` binding holds now).
fn regExpIntrinsic(self: *Interpreter) JSValue {
    return self.regexp_ctor.?;
}

/// SpeciesConstructor(o, %RegExp%) (owned).
fn speciesConstructor(self: *Interpreter, o: JSValue) anyerror!JSValue {
    const c = try self.getProperty(o, "constructor");
    if (c == .undefined) return regExpIntrinsic(self).retain();
    defer c.deinit();
    if (!isObjectLike(c)) return self.throwError(.type_error, "object.constructor is not an object", .{});
    const key = try rb.wellKnownKey(self, "species");
    defer self.gc_allocator.free(key);
    const s = try self.getProperty(c, key);
    if (s == .undefined or s == .null) return regExpIntrinsic(self).retain();
    if (self.isConstructor(s)) return s;
    s.deinit();
    return self.throwError(.type_error, "object.constructor[Symbol.species] is not a constructor", .{});
}

/// RegExpCreate(p, flags): `p` and `flags` undefined are "".
fn regExpCreate(self: *Interpreter, allocator: Allocator, p: JSValue, flags: []const u8) anyerror!JSValue {
    const src = if (p == .undefined) try allocator.dupe(u8, "") else try self.toDisplayStringJS(allocator, p);
    defer allocator.free(src);
    return self.makeRegex(src, flags);
}

/// RegExpExec(r, s): a callable `exec` (own or inherited) is called and
/// must return an object or null; otherwise `r` must be a real RegExp
/// and RegExpBuiltinExec runs. Returns the match object or null (owned).
pub fn regExpExec(self: *Interpreter, allocator: Allocator, r: JSValue, s: JSValue) anyerror!JSValue {
    const exec = try self.getProperty(r, "exec");
    defer exec.deinit();
    // The original RegExp.prototype.exec on a RegExp is RegExpBuiltinExec
    // itself: skip the call.
    if (r == .regex and exec == .function and exec.function.value.call == rb.regexExecFn) {
        return builtinExecValue(self, allocator, r, s);
    }
    if (isCallable(exec)) {
        const result = try self.callValue(exec, r, &.{s}, "exec");
        if (result != .null and !isObjectLike(result)) {
            result.deinit();
            return self.throwError(.type_error, "exec result must be an object or null", .{});
        }
        return result;
    }
    if (r != .regex) return self.throwError(.type_error, "RegExp exec method called on an incompatible receiver", .{});
    return builtinExecValue(self, allocator, r, s);
}

fn builtinExecValue(self: *Interpreter, allocator: Allocator, r: JSValue, s: JSValue) anyerror!JSValue {
    const m = try rb.builtinExec(self, allocator, r, s.string.value.data) orelse return JSValue.NULL;
    defer m.deinit();
    return rb.makeMatchArray(self, allocator, m, s);
}

/// GetSubstitution(matched, str, position, captures, namedCaptures,
/// template), appended to `buf`. `before_end` is the subject position of
/// `position` (the end of $`), `after_start` that of
/// min(position + matched length, length) (the start of $'). Each
/// capture is undefined or a string; `named` is undefined or an object.
fn getSubstitution(self: *Interpreter, allocator: Allocator, buf: *std.ArrayList(u8), template: []const u8, matched: []const u8, data: []const u8, before_end: usize, after_start: usize, captures: []const JSValue, named: JSValue) anyerror!void {
    var i: usize = 0;
    while (i < template.len) {
        // A run of literal text up to the next `$`.
        const dollar = std.mem.indexOfScalarPos(u8, template, i, '$') orelse template.len;
        if (dollar > i) {
            try appendWtf8Merged(buf, allocator, template[i..dollar]);
            i = dollar;
            continue;
        }
        if (i + 1 >= template.len) {
            try appendWtf8Merged(buf, allocator, "$");
            i += 1;
            continue;
        }
        const next = template[i + 1];
        switch (next) {
            '$' => {
                try appendWtf8Merged(buf, allocator, "$");
                i += 2;
            },
            '&' => {
                try appendWtf8Merged(buf, allocator, matched);
                i += 2;
            },
            '`' => {
                try appendValue(self, allocator, buf, data, 0, before_end);
                i += 2;
            },
            '\'' => {
                try appendValue(self, allocator, buf, data, after_start, data.len);
                i += 2;
            },
            '0'...'9' => {
                var digits: usize = if (i + 2 < template.len and std.ascii.isDigit(template[i + 2])) 2 else 1;
                var index: usize = std.fmt.parseInt(usize, template[i + 1 .. i + 1 + digits], 10) catch 0;
                if (index > captures.len and digits == 2) {
                    digits = 1;
                    index = next - '0';
                }
                if (index >= 1 and index <= captures.len) {
                    const cap = captures[index - 1];
                    if (cap == .string) try appendWtf8Merged(buf, allocator, cap.string.value.data);
                } else {
                    try appendWtf8Merged(buf, allocator, template[i .. i + 1 + digits]);
                }
                i += 1 + digits;
            },
            '<' => {
                const gt = std.mem.indexOfScalarPos(u8, template, i + 2, '>');
                if (named == .undefined or gt == null) {
                    try appendWtf8Merged(buf, allocator, "$<");
                    i += 2;
                    continue;
                }
                const capture = try self.getProperty(named, template[i + 2 .. gt.?]);
                defer capture.deinit();
                if (capture != .undefined) {
                    const cs = try toStringValue(self, allocator, capture);
                    defer cs.deinit();
                    try appendWtf8Merged(buf, allocator, cs.string.value.data);
                }
                i = gt.? + 1;
            },
            else => {
                try appendWtf8Merged(buf, allocator, "$");
                i += 1;
            },
        }
    }
}

/// Appends the text at subject positions [a, b).
fn appendValue(self: *Interpreter, allocator: Allocator, buf: *std.ArrayList(u8), data: []const u8, a: usize, b: usize) anyerror!void {
    if (a >= b) return;
    const v = try rb.sliceValue(self, allocator, data, a, b);
    defer v.deinit();
    try appendWtf8Merged(buf, allocator, v.string.value.data);
}

fn requireObject(self: *Interpreter, v: JSValue, comptime method: []const u8) anyerror!void {
    if (!isObjectLike(v)) return self.throwError(.type_error, "RegExp.prototype" ++ method ++ " called on a non-object", .{});
}

/// Releases every value of a list, then the list.
fn deinitList(allocator: Allocator, list: *std.ArrayList(JSValue)) void {
    for (list.items) |v| v.deinit();
    list.deinit(allocator);
}

// ===== Fast paths =====
//
// For a RegExp whose `exec` is the original builtin (an inherited data
// property, not overridden on the instance), whose `flags` read matches
// its own flags and whose lastIndex is writable, the spec's global loops
// (Set lastIndex / RegExpExec / Get lastIndex ...) observe nothing a plain
// search loop over subject positions doesn't: same matches, same
// lastIndex at the end (0). That loop is O(length) instead of converting
// lastIndex <-> UTF-16 on every exec.

fn pristine(self: *Interpreter, rx: JSValue, flags: JSValue) bool {
    if (!pristineExec(self, rx)) return false;
    var buf: [8]u8 = undefined;
    return std.mem.eql(u8, Interpreter.canonicalFlags(self.regexState(rx), &buf), flags.string.value.data);
}

/// A RegExp whose `exec` is the original builtin (inherited as a data
/// property, not overridden on it) and whose lastIndex is writable.
fn pristineExec(self: *Interpreter, rx: JSValue) bool {
    if (rx != .regex) return false;
    const st = self.regexState(rx);
    if (!st.last_index_writable) return false;
    if (st.props) |bag| {
        if (bag.object.value.getOwnRecord("exec") != null) return false;
    }
    const rec = self.protos.regex.object.value.getOwnRecord("exec") orelse return false;
    return !rec.isAccessor() and rec.value == .function and rec.value.function.value.call == rb.regexExecFn;
}

/// Every match of a global search from position 0 (RegexMatch slots in
/// subject positions), then lastIndex = 0 as the spec loop leaves it.
fn allMatches(self: *Interpreter, allocator: Allocator, rx: JSValue, data: []const u8, list: *std.ArrayList(rb.RegexMatch)) anyerror!void {
    var pos: usize = 0;
    while (try rb.execRaw(allocator, rx, data, pos)) |m| {
        try list.append(allocator, m);
        pos = if (m.end() == m.start()) rb.advancePos(rx, data, m.end()) else m.end();
    }
    try setNumber(self, rx, "lastIndex", 0);
}

fn deinitMatches(allocator: Allocator, list: *std.ArrayList(rb.RegexMatch)) void {
    for (list.items) |m| m.deinit();
    list.deinit(allocator);
}

fn matchFast(self: *Interpreter, allocator: Allocator, rx: JSValue, s: JSValue) anyerror!JSValue {
    const data = s.string.value.data;
    var list: std.ArrayList(rb.RegexMatch) = .empty;
    defer deinitMatches(allocator, &list);
    try allMatches(self, allocator, rx, data, &list);
    if (list.items.len == 0) return JSValue.NULL;
    var a = try self.gcNewArray();
    errdefer a.deinit();
    for (list.items) |m| _ = try a.array.value.push(try rb.sliceValue(self, allocator, data, m.start(), m.end()));
    return a;
}

fn replaceFast(self: *Interpreter, allocator: Allocator, rx: JSValue, s: JSValue, repl: JSValue, functional: bool) anyerror!JSValue {
    const data = s.string.value.data;
    var list: std.ArrayList(rb.RegexMatch) = .empty;
    defer deinitMatches(allocator, &list);
    try allMatches(self, allocator, rx, data, &list);
    // Every match's captures and groups before any replacer runs (one
    // may recompile rx; the matches must not depend on its program).
    const Prepared = struct { captures: []JSValue, named: JSValue, position: usize };
    var prepared = try allocator.alloc(Prepared, list.items.len);
    var n_prepared: usize = 0;
    defer {
        for (prepared[0..n_prepared]) |pr| {
            for (pr.captures) |c| c.deinit();
            allocator.free(pr.captures);
            pr.named.deinit();
        }
        allocator.free(prepared);
    }
    var cursor: rb.Utf16Cursor = .{ .data = data };
    for (list.items, 0..) |m, k| {
        const caps = try allocator.alloc(JSValue, m.groupCount() + 1);
        var g: usize = 0;
        while (g < caps.len) : (g += 1) caps[g] = try m.capture(self, g);
        prepared[k] = .{ .captures = caps, .named = try rb.matchGroups(self, m), .position = cursor.at(m.start()) };
        n_prepared += 1;
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var last: usize = 0;
    for (list.items, prepared) |m, pr| {
        try appendValue(self, allocator, &buf, data, last, m.start());
        if (functional) {
            var call_args: std.ArrayList(JSValue) = .empty;
            defer call_args.deinit(allocator);
            try call_args.appendSlice(allocator, pr.captures);
            try call_args.append(allocator, JSValue.fromNumber(@floatFromInt(pr.position)));
            try call_args.append(allocator, s);
            if (pr.named != .undefined) try call_args.append(allocator, pr.named);
            const r = try self.callValue(repl, JSValue.UNDEFINED, call_args.items, "replacer");
            defer r.deinit();
            const rs = try toStringValue(self, allocator, r);
            defer rs.deinit();
            try appendWtf8Merged(&buf, allocator, rs.string.value.data);
        } else {
            try getSubstitution(self, allocator, &buf, repl.string.value.data, pr.captures[0].string.value.data, data, m.start(), m.end(), pr.captures[1..], pr.named);
        }
        last = m.end();
    }
    try appendValue(self, allocator, &buf, data, last, data.len);
    return self.gcNewString(buf.items);
}

// ===== RegExp.prototype methods =====

/// RegExp.prototype.test(S): RegExpExec(R, S) !== null.
pub fn regexTest(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    try requireObject(self, this_value, ".test");
    const s = try toStringValue(self, allocator, arg(args, 0));
    defer s.deinit();
    const m = try regExpExec(self, allocator, this_value, s);
    defer m.deinit();
    return JSValue.fromBool(m != .null);
}

/// RegExp.prototype[@@match](string).
pub fn symbolMatch(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const rx = this_value;
    try requireObject(self, rx, "[Symbol.match]");
    const s = try toStringValue(self, allocator, arg(args, 0));
    defer s.deinit();
    const flags = try getString(self, allocator, rx, "flags");
    defer flags.deinit();
    if (!hasFlag(flags, 'g')) return regExpExec(self, allocator, rx, s);
    const full_unicode = hasFlag(flags, 'u') or hasFlag(flags, 'v');
    try setNumber(self, rx, "lastIndex", 0);
    if (pristine(self, rx, flags)) return matchFast(self, allocator, rx, s);
    var result: ?JSValue = null;
    errdefer if (result) |a| a.deinit();
    while (true) {
        const m = try regExpExec(self, allocator, rx, s);
        if (m == .null) return result orelse JSValue.NULL;
        defer m.deinit();
        const match_str = try getString(self, allocator, m, "0");
        if (result == null) result = try self.gcNewArray();
        _ = try result.?.array.value.push(match_str);
        if (match_str.string.value.data.len == 0) {
            const this_index = try getLength(self, rx, "lastIndex");
            try setNumber(self, rx, "lastIndex", advanceStringIndex(s.string.value.data, this_index, full_unicode));
        }
    }
}

/// RegExp.prototype[@@search](string).
pub fn symbolSearch(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const rx = this_value;
    try requireObject(self, rx, "[Symbol.search]");
    const s = try toStringValue(self, allocator, arg(args, 0));
    defer s.deinit();
    const previous = try self.getProperty(rx, "lastIndex");
    defer previous.deinit();
    const zero = JSValue.fromNumber(0);
    if (!rb.sameValue(previous, zero)) try self.setPropertyOnValue(rx, "lastIndex", zero);
    const m = try regExpExec(self, allocator, rx, s);
    defer m.deinit();
    const current = try self.getProperty(rx, "lastIndex");
    defer current.deinit();
    if (!rb.sameValue(current, previous)) try self.setPropertyOnValue(rx, "lastIndex", previous);
    if (m == .null) return JSValue.fromNumber(-1);
    return self.getProperty(m, "index");
}

/// RegExp.prototype[@@replace](string, replaceValue).
pub fn symbolReplace(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const rx = this_value;
    try requireObject(self, rx, "[Symbol.replace]");
    const s = try toStringValue(self, allocator, arg(args, 0));
    defer s.deinit();
    const data = s.string.value.data;
    const length_s = len16(s);
    const functional = isCallable(arg(args, 1));
    const repl = if (functional) arg(args, 1).retain() else try toStringValue(self, allocator, arg(args, 1));
    defer repl.deinit();
    const flags = try getString(self, allocator, rx, "flags");
    defer flags.deinit();
    const global = hasFlag(flags, 'g');
    const full_unicode = hasFlag(flags, 'u') or hasFlag(flags, 'v');
    if (global) {
        try setNumber(self, rx, "lastIndex", 0);
        if (pristine(self, rx, flags)) return replaceFast(self, allocator, rx, s, repl, functional);
    }

    // Every match first (all the exec calls happen before any replacer).
    var results: std.ArrayList(JSValue) = .empty;
    defer deinitList(allocator, &results);
    while (true) {
        const m = try regExpExec(self, allocator, rx, s);
        if (m == .null) break;
        try results.append(allocator, m);
        if (!global) break;
        const match_str = try getString(self, allocator, m, "0");
        defer match_str.deinit();
        if (match_str.string.value.data.len == 0) {
            const this_index = try getLength(self, rx, "lastIndex");
            try setNumber(self, rx, "lastIndex", advanceStringIndex(data, this_index, full_unicode));
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var next_source: usize = 0; // UTF-16 index
    for (results.items) |result| {
        const n_captures = (try getLength(self, result, "length")) -| 1;
        const matched = try getString(self, allocator, result, "0");
        defer matched.deinit();
        const match_length = len16(matched);
        const index_v = try self.getProperty(result, "index");
        defer index_v.deinit();
        const position = try toClampedIndex(self, index_v, length_s);
        var captures: std.ArrayList(JSValue) = .empty;
        defer deinitList(allocator, &captures);
        var n: usize = 1;
        while (n <= n_captures) : (n += 1) {
            var key_buf: [24]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "{d}", .{n});
            const cap = try self.getProperty(result, key);
            if (cap == .undefined) {
                try captures.append(allocator, cap);
            } else {
                defer cap.deinit();
                try captures.append(allocator, try toStringValue(self, allocator, cap));
            }
        }
        const named = try self.getProperty(result, "groups");
        defer named.deinit();

        var replacement: std.ArrayList(u8) = .empty;
        defer replacement.deinit(allocator);
        if (functional) {
            var call_args: std.ArrayList(JSValue) = .empty;
            defer call_args.deinit(allocator);
            try call_args.append(allocator, matched);
            try call_args.appendSlice(allocator, captures.items);
            try call_args.append(allocator, JSValue.fromNumber(@floatFromInt(position)));
            try call_args.append(allocator, s);
            if (named != .undefined) try call_args.append(allocator, named);
            const r = try self.callValue(repl, JSValue.UNDEFINED, call_args.items, "replacer");
            defer r.deinit();
            const rs = try toStringValue(self, allocator, r);
            defer rs.deinit();
            try replacement.appendSlice(allocator, rs.string.value.data);
        } else {
            if (named != .undefined and !isObjectLike(named)) {
                // ToObject(namedCaptures): null throws, a primitive boxes
                // (its properties are read through Get either way).
                if (named == .null) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
            }
            try getSubstitution(self, allocator, &replacement, repl.string.value.data, matched.string.value.data, data, posOf(data, position), posOf(data, @min(position + match_length, length_s)), captures.items, named);
        }
        if (position >= next_source) {
            try appendValue(self, allocator, &buf, data, posOf(data, next_source), posOf(data, position));
            try appendWtf8Merged(&buf, allocator, replacement.items);
            next_source = position + match_length;
        }
    }
    if (next_source < length_s) try appendValue(self, allocator, &buf, data, posOf(data, next_source), data.len);
    return self.gcNewString(buf.items);
}

/// RegExp.prototype[@@split](string, limit).
pub fn symbolSplit(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const rx = this_value;
    try requireObject(self, rx, "[Symbol.split]");
    const s = try toStringValue(self, allocator, arg(args, 0));
    defer s.deinit();
    const data = s.string.value.data;
    const c = try speciesConstructor(self, rx);
    defer c.deinit();
    const flags = try getString(self, allocator, rx, "flags");
    defer flags.deinit();
    const unicode_matching = hasFlag(flags, 'u') or hasFlag(flags, 'v');
    const new_flags = if (hasFlag(flags, 'y')) flags.retain() else blk: {
        const f = try std.mem.concat(allocator, u8, &.{ flags.string.value.data, "y" });
        defer allocator.free(f);
        break :blk try self.gcNewString(f);
    };
    defer new_flags.deinit();
    const splitter = try self.constructValue(c, &.{ rx, new_flags }, "RegExp");
    defer splitter.deinit();

    var a = try self.gcNewArray();
    errdefer a.deinit();
    const lim: u32 = if (arg(args, 1) == .undefined) std.math.maxInt(u32) else try self.toUint32JS(arg(args, 1));
    if (lim == 0) return a;
    const size = len16(s);
    if (size == 0) {
        const z = try regExpExec(self, allocator, splitter, s);
        defer z.deinit();
        if (z == .null) _ = try a.array.value.push(s.retain());
        return a;
    }
    if (try pristineSplitter(self, splitter, c)) |plain| {
        defer plain.deinit();
        try splitFast(self, allocator, &a, plain, data, lim);
        return a;
    }
    var length_a: usize = 0;
    var p: usize = 0;
    var q: usize = 0;
    while (q < size) {
        try setNumber(self, splitter, "lastIndex", q);
        const z = try regExpExec(self, allocator, splitter, s);
        if (z == .null) {
            q = advanceStringIndex(data, q, unicode_matching);
            continue;
        }
        defer z.deinit();
        const e = @min(try getLength(self, splitter, "lastIndex"), size);
        if (e == p) {
            q = advanceStringIndex(data, q, unicode_matching);
            continue;
        }
        _ = try a.array.value.push(try substring(self, allocator, s, p, q));
        length_a += 1;
        if (length_a == lim) return a;
        p = e;
        const n_captures = (try getLength(self, z, "length")) -| 1;
        var i: usize = 1;
        while (i <= n_captures) : (i += 1) {
            var key_buf: [24]u8 = undefined;
            _ = try a.array.value.push(try self.getProperty(z, try std.fmt.bufPrint(&key_buf, "{d}", .{i})));
            length_a += 1;
            if (length_a == lim) return a;
        }
        q = p;
    }
    _ = try a.array.value.push(try substring(self, allocator, s, p, size));
    return a;
}

/// When the splitter is a fresh %RegExp% instance whose `exec` is the
/// original builtin, the spec's per-position sticky loop can be run as a
/// search loop instead (same pieces, no observable difference: nobody
/// else holds the splitter). Returns a non-sticky copy of it to search
/// with, or null to take the generic path.
fn pristineSplitter(self: *Interpreter, splitter: JSValue, c: JSValue) anyerror!?JSValue {
    if (splitter != .regex or c != .function or c.function != regExpIntrinsic(self).function) return null;
    const exec = try self.getProperty(splitter, "exec");
    defer exec.deinit();
    if (exec != .function or exec.function.value.call != rb.regexExecFn) return null;
    const st = self.regexState(splitter);
    var flags_buf: [8]u8 = undefined;
    var n: usize = 0;
    for (Interpreter.canonicalFlags(st, &flags_buf)) |f| {
        if (f == 'y') continue;
        flags_buf[n] = f;
        n += 1;
    }
    return try self.makeRegex(st.source, flags_buf[0..n]);
}

/// SplitMatcher's loop as a search over subject positions (see
/// pristineSplitter), with the limit.
fn splitFast(self: *Interpreter, allocator: Allocator, a: *JSValue, re: JSValue, data: []const u8, lim: u32) anyerror!void {
    var length_a: usize = 0;
    var p: usize = 0; // end of the last piece
    var q: usize = 0; // where the next search starts
    while (q < data.len) {
        const m = try rb.execRaw(allocator, re, data, q) orelse break;
        defer m.deinit();
        if (m.start() >= data.len) break;
        const e = @min(m.end(), data.len);
        if (e == p) {
            q = rb.advancePos(re, data, m.start());
            continue;
        }
        _ = try a.array.value.push(try rb.sliceValue(self, allocator, data, p, m.start()));
        length_a += 1;
        if (length_a == lim) return;
        var g: usize = 1;
        while (g <= m.groupCount()) : (g += 1) {
            _ = try a.array.value.push(try m.capture(self, g));
            length_a += 1;
            if (length_a == lim) return;
        }
        p = e;
        q = p;
    }
    _ = try a.array.value.push(try rb.sliceValue(self, allocator, data, p, data.len));
}

/// RegExp.prototype[@@matchAll](string). The %RegExpStringIterator% it
/// returns is run to completion here and handed out as an array
/// iterator (the lazy iterator object is separate work).
pub fn symbolMatchAll(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const r = this_value;
    try requireObject(self, r, "[Symbol.matchAll]");
    const s = try toStringValue(self, allocator, arg(args, 0));
    defer s.deinit();
    const c = try speciesConstructor(self, r);
    defer c.deinit();
    const flags = try getString(self, allocator, r, "flags");
    defer flags.deinit();
    const matcher = try self.constructValue(c, &.{ r, flags }, "RegExp");
    defer matcher.deinit();
    const last_index = try getLength(self, r, "lastIndex");
    try setNumber(self, matcher, "lastIndex", last_index);
    return createRegExpStringIterator(self, matcher, s, hasFlag(flags, 'g'), hasFlag(flags, 'u') or hasFlag(flags, 'v'));
}

// ===== %RegExpStringIterator% =====

/// CreateRegExpStringIterator(R, S, global, fullUnicode): an object
/// inheriting %RegExpStringIteratorPrototype%, its slots in the
/// interpreter's regexp_string_iters table.
fn createRegExpStringIterator(self: *Interpreter, r: JSValue, s: JSValue, global: bool, unicode: bool) anyerror!JSValue {
    const it = try self.gcNewObject();
    errdefer it.deinit();
    try it.object.value.setPrototype(&self.regexp_string_iterator_proto.?.object.value);
    try self.regexp_string_iters.put(self.gc_allocator, @intFromPtr(it.object), .{ .r = r.retain(), .s = s.retain(), .global = global, .unicode = unicode });
    return it;
}

/// CreateIterResultObject(value, done); takes ownership of `value`.
fn iterResult(self: *Interpreter, value: JSValue, done: bool) anyerror!JSValue {
    const o = try self.ordinaryObject();
    try o.object.value.set("value", value);
    try o.object.value.set("done", JSValue.fromBool(done));
    return o;
}

/// %RegExpStringIteratorPrototype%.next(). For a matcher only this
/// iterator holds (it was constructed by @@matchAll) and whose exec is
/// still the original, a global iteration keeps its own position instead
/// of round-tripping lastIndex through UTF-16 on every step (nothing can
/// observe the difference); the moment exec is replaced it writes
/// lastIndex back and follows the spec steps.
pub fn regExpStringIteratorNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    if (!isObjectLike(this_value)) return self.throwError(.type_error, "%RegExpStringIterator%.next called on a non-object", .{});
    if (this_value != .object or self.regexp_string_iters.getPtr(@intFromPtr(this_value.object)) == null)
        return self.throwError(.type_error, "%RegExpStringIterator%.next called on an incompatible receiver", .{});
    const key = @intFromPtr(this_value.object);
    const snap = self.regexp_string_iters.get(key).?;
    if (snap.done) return iterResult(self, JSValue.UNDEFINED, true);
    const r = snap.r;
    const s = snap.s;
    const data = s.string.value.data;

    if (snap.global and pristineExec(self, r)) {
        const st = self.regexp_string_iters.getPtr(key).?;
        const pos = st.pos orelse (rb.utf16ToPos(data, try getLength(self, r, "lastIndex")) orelse data.len + 1);
        const m = try rb.execRaw(allocator, r, data, pos) orelse {
            const st2 = self.regexp_string_iters.getPtr(key).?;
            st2.done = true;
            st2.pos = null;
            try setNumber(self, r, "lastIndex", 0);
            return iterResult(self, JSValue.UNDEFINED, true);
        };
        defer m.deinit();
        var cursor: rb.Utf16Cursor = .{ .data = data, .pos = st.cursor_pos, .index = st.cursor_index };
        const arr = try rb.makeMatchArrayAt(self, allocator, m, cursor.at(m.start()), s);
        const st2 = self.regexp_string_iters.getPtr(key).?;
        st2.cursor_pos = cursor.pos;
        st2.cursor_index = cursor.index;
        st2.pos = if (m.end() == m.start()) rb.advancePos(r, data, m.end()) else m.end();
        return iterResult(self, arr, false);
    }

    // The spec steps. A position the fast path kept goes back into
    // lastIndex first.
    if (snap.pos) |pos| {
        const st = self.regexp_string_iters.getPtr(key).?;
        st.pos = null;
        try setNumber(self, r, "lastIndex", rb.posToUtf16(data, pos));
    }
    const match = try regExpExec(self, allocator, r, s);
    if (match == .null) {
        self.regexp_string_iters.getPtr(key).?.done = true;
        return iterResult(self, JSValue.UNDEFINED, true);
    }
    errdefer match.deinit();
    if (snap.global) {
        const match_str = try getString(self, allocator, match, "0");
        defer match_str.deinit();
        if (match_str.string.value.data.len == 0) {
            const this_index = try getLength(self, r, "lastIndex");
            try setNumber(self, r, "lastIndex", advanceStringIndex(data, this_index, snap.unicode));
        }
        return iterResult(self, match, false);
    }
    self.regexp_string_iters.getPtr(key).?.done = true;
    return iterResult(self, match, false);
}

// ===== String.prototype methods =====

fn requireCoercible(self: *Interpreter, v: JSValue, comptime method: []const u8) anyerror!void {
    if (v == .undefined or v == .null) return self.throwError(.type_error, "String.prototype." ++ method ++ " called on null or undefined", .{});
}

/// ToString(this) for a String.prototype method (owned).
fn thisString(self: *Interpreter, allocator: Allocator, this_value: JSValue) anyerror!JSValue {
    const v = self.unboxPrimitiveWrapper(this_value) orelse this_value;
    return toStringValue(self, allocator, v);
}

/// Invoke(v, @@name, args).
fn invoke(self: *Interpreter, v: JSValue, comptime name: []const u8, args: []const JSValue) anyerror!JSValue {
    const key = try rb.wellKnownKey(self, name);
    defer self.gc_allocator.free(key);
    const f = try self.getProperty(v, key);
    defer f.deinit();
    return self.callValue(f, v, args, "Symbol." ++ name);
}

/// String.prototype.match / search: an object argument's @@match /
/// @@search (a primitive's is never looked up, ES2025), or a new RegExp's.
fn matchOrSearch(comptime name: []const u8) native_helpers.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            const self = interp(ctx);
            try requireCoercible(self, this_value, name);
            const regexp = arg(args, 0);
            if (isObjectLike(regexp)) {
                if (try getMethod(self, regexp, name)) |m| {
                    defer m.deinit();
                    return self.callValue(m, regexp, &.{this_value}, name);
                }
            }
            const s = try thisString(self, allocator, this_value);
            defer s.deinit();
            const rx = try regExpCreate(self, allocator, regexp, "");
            defer rx.deinit();
            return invoke(self, rx, name, &.{s});
        }
    }.call;
}

pub const stringMatch = matchOrSearch("match");
pub const stringSearch = matchOrSearch("search");

/// String.prototype.matchAll(regexp).
pub fn stringMatchAll(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    try requireCoercible(self, this_value, "matchAll");
    const regexp = arg(args, 0);
    if (isObjectLike(regexp)) {
        if (try isRegExp(self, regexp)) try requireGlobalFlags(self, allocator, regexp, "matchAll");
        if (try getMethod(self, regexp, "matchAll")) |m| {
            defer m.deinit();
            return self.callValue(m, regexp, &.{this_value}, "matchAll");
        }
    }
    const s = try thisString(self, allocator, this_value);
    defer s.deinit();
    const rx = try regExpCreate(self, allocator, regexp, "g");
    defer rx.deinit();
    return invoke(self, rx, "matchAll", &.{s});
}

/// matchAll/replaceAll with a RegExp argument: its `flags` must contain g.
fn requireGlobalFlags(self: *Interpreter, allocator: Allocator, regexp: JSValue, comptime method: []const u8) anyerror!void {
    const flags = try self.getProperty(regexp, "flags");
    defer flags.deinit();
    if (flags == .undefined or flags == .null) return self.throwError(.type_error, "String.prototype." ++ method ++ " called with a RegExp whose flags are null or undefined", .{});
    const fs = try toStringValue(self, allocator, flags);
    defer fs.deinit();
    if (!hasFlag(fs, 'g')) return self.throwError(.type_error, "String.prototype." ++ method ++ " called with a non-global RegExp argument", .{});
}

/// String.prototype.replace / replaceAll.
fn replaceImpl(comptime all: bool) native_helpers.NativeFn {
    const name = if (all) "replaceAll" else "replace";
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            const self = interp(ctx);
            try requireCoercible(self, this_value, name);
            const search_value = arg(args, 0);
            const replace_value = arg(args, 1);
            if (isObjectLike(search_value)) {
                if (all and try isRegExp(self, search_value)) try requireGlobalFlags(self, allocator, search_value, name);
                if (try getMethod(self, search_value, "replace")) |m| {
                    defer m.deinit();
                    return self.callValue(m, search_value, &.{ this_value, replace_value }, name);
                }
            }
            const s = try thisString(self, allocator, this_value);
            defer s.deinit();
            const search = try toStringValue(self, allocator, search_value);
            defer search.deinit();
            const functional = isCallable(replace_value);
            const repl = if (functional) replace_value.retain() else try toStringValue(self, allocator, replace_value);
            defer repl.deinit();
            return stringReplaceSearch(self, allocator, s, search, repl, functional, all);
        }
    }.call;
}

pub const stringReplace = replaceImpl(false);
pub const stringReplaceAll = replaceImpl(true);

/// The string-pattern half of replace/replaceAll: every (or the first)
/// occurrence of `search` in `s`, by StringIndexOf, replaced through the
/// replacer or GetSubstitution.
fn stringReplaceSearch(self: *Interpreter, allocator: Allocator, s: JSValue, search: JSValue, repl: JSValue, functional: bool, all: bool) anyerror!JSValue {
    const data = s.string.value.data;
    const needle = search.string.value.data;
    // Match positions (subject positions). An empty search matches at
    // every code-unit boundary, between a surrogate pair's halves too.
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(allocator);
    const subject = rb.subjectOf(data);
    var from: usize = 0;
    while (from <= data.len) {
        const p = if (needle.len == 0) from else std.mem.indexOfPos(u8, data, from, needle) orelse break;
        try positions.append(allocator, p);
        if (!all) break;
        from = if (needle.len == 0) subject.advanceIndex(.code_unit, p) else p + needle.len;
    }
    if (positions.items.len == 0) return s.retain();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var end_of_last: usize = 0;
    for (positions.items) |p| {
        try appendValue(self, allocator, &buf, data, end_of_last, p);
        if (functional) {
            const r = try self.callValue(repl, JSValue.UNDEFINED, &.{ search, JSValue.fromNumber(@floatFromInt(rb.posToUtf16(data, p))), s }, "replacer");
            defer r.deinit();
            const rs = try toStringValue(self, allocator, r);
            defer rs.deinit();
            try appendWtf8Merged(&buf, allocator, rs.string.value.data);
        } else {
            try getSubstitution(self, allocator, &buf, repl.string.value.data, needle, data, p, p + needle.len, &.{}, JSValue.UNDEFINED);
        }
        end_of_last = p + needle.len;
    }
    try appendValue(self, allocator, &buf, data, end_of_last, data.len);
    return self.gcNewString(buf.items);
}

/// String.prototype.split(separator, limit).
pub fn stringSplit(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    try requireCoercible(self, this_value, "split");
    const separator = arg(args, 0);
    const limit = arg(args, 1);
    if (isObjectLike(separator)) {
        if (try getMethod(self, separator, "split")) |m| {
            defer m.deinit();
            return self.callValue(m, separator, &.{ this_value, limit }, "split");
        }
    }
    const s = try thisString(self, allocator, this_value);
    defer s.deinit();
    const data = s.string.value.data;
    const lim: u32 = if (limit == .undefined) std.math.maxInt(u32) else try self.toUint32JS(limit);
    const r = try toStringValue(self, allocator, separator);
    defer r.deinit();
    var a = try self.gcNewArray();
    errdefer a.deinit();
    if (lim == 0) return a;
    if (separator == .undefined) {
        _ = try a.array.value.push(s.retain());
        return a;
    }
    const sep = r.string.value.data;
    if (sep.len == 0) {
        // Each code unit of the first `lim` (a lone surrogate for each
        // half of a pair).
        const subject = rb.subjectOf(data);
        var p: usize = 0;
        var n: usize = 0;
        while (p < data.len and n < lim) : (n += 1) {
            const next = subject.advanceIndex(.code_unit, p);
            _ = try a.array.value.push(try rb.sliceValue(self, allocator, data, p, next));
            p = next;
        }
        return a;
    }
    if (data.len == 0) {
        _ = try a.array.value.push(s.retain());
        return a;
    }
    var i: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, sep)) |j| {
        _ = try a.array.value.push(try rb.sliceValue(self, allocator, data, i, j));
        count += 1;
        if (count == lim) return a;
        i = j + sep.len;
    }
    _ = try a.array.value.push(try rb.sliceValue(self, allocator, data, i, data.len));
    return a;
}
