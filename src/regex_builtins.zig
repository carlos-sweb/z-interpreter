//! `RegExp`, `.test`/`.exec`/`.toString`, and the match/replace/split
//! machinery `String.prototype`'s regex-pattern methods (match/matchAll/
//! search/replace/replaceAll/split) reuse -- `execRaw`/`builtinExec`/
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
const toLength = builtin_helpers.toLength;

pub const regex_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "test", MethodSpec{ .call = regexTest, .arity = 1 } },
    .{ "exec", MethodSpec{ .call = regexExec, .arity = 1 } },
    .{ "toString", MethodSpec{ .call = regexToString, .arity = 0 } },
});

const zregex = @import("zregex");
const zstring = @import("zstring");

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
        owned_source = try self.toDisplayStringJS(allocator, pat_arg);
        source = owned_source.?;
    }
    if (arg(args, 1) != .undefined) {
        owned_flags = try self.toDisplayStringJS(allocator, arg(args, 1));
        flags = owned_flags.?;
    }
    return self.makeRegex(source, flags);
}

// ===== Matching: z-regex's execAt over the WTF-8 string =====
//
// JS strings live here as WTF-8, and every index JS sees (`index`,
// `lastIndex`, `search`'s result, a replacer's offset) is in UTF-16 code
// units. Matching runs on `zregex.Subject.wtf8` -- no copy of the string --
// and positions are converted only at that JS boundary.
//
// A position in the subject is z-regex's WTF-8 position: a byte offset at
// a sequence boundary, or `b+2` for the point between the two halves of an
// astral character whose 4-byte sequence starts at `b` (reachable without
// `u`, where an astral character is two code units). See z-regex's
// `subject` module.

/// Whether `p` is the `b+2` position between a surrogate pair's halves.
fn isMidPair(data: []const u8, p: usize) bool {
    return p >= 2 and p + 2 <= data.len and data[p - 2] >= 0xF0 and data[p - 2] <= 0xF4;
}

/// UTF-16 index of subject position `p`.
pub fn posToUtf16(data: []const u8, p: usize) usize {
    if (isMidPair(data, p)) return (zstring.utf16.byteIndexToUtf16(data, p - 2) catch p - 2) + 1;
    return zstring.utf16.byteIndexToUtf16(data, p) catch p;
}

/// Subject position of UTF-16 index `index`, or null past the end.
pub fn utf16ToPos(data: []const u8, index: usize) ?usize {
    const at = zstring.utf16.utf16IndexToBytePos(data, index) catch return null;
    return if (at.is_low_surrogate) at.byte_index + 2 else at.byte_index;
}

/// The lead or trail half of the astral character whose sequence starts
/// at `b`, WTF-8-encoded as a lone surrogate.
fn pairHalf(data: []const u8, b: usize, trail: bool) [3]u8 {
    const cp = std.unicode.utf8Decode(data[b .. b + 4]) catch 0x10000;
    const v: u21 = cp - 0x10000;
    const unit: u16 = if (trail) @intCast(0xDC00 + (v & 0x3FF)) else @intCast(0xD800 + (v >> 10));
    var buf: [3]u8 = undefined;
    zstring.utf16.encodeSurrogateWtf8(&buf, unit);
    return buf;
}

/// The JS string for subject positions [a, b). Either end can be a `b+2`
/// position, which cuts a surrogate pair: that half becomes a lone
/// surrogate, as in UTF-16.
pub fn sliceValue(self: *Interpreter, allocator: Allocator, data: []const u8, a: usize, b: usize) anyerror!JSValue {
    if (a >= b) return self.gcNewString("");
    const a_mid = isMidPair(data, a);
    const b_mid = isMidPair(data, b);
    if (!a_mid and !b_mid) return self.gcNewString(data[a..b]);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var from = a;
    if (a_mid) {
        try buf.appendSlice(allocator, &pairHalf(data, a - 2, true));
        from = a + 2;
    }
    if (b_mid) {
        if (from < b - 2) try buf.appendSlice(allocator, data[from .. b - 2]);
        try buf.appendSlice(allocator, &pairHalf(data, b - 2, false));
    } else if (from < b) {
        try buf.appendSlice(allocator, data[from..b]);
    }
    return self.gcNewString(buf.items);
}

/// One match: `slots[2g]`/`slots[2g + 1]` are group g's subject positions
/// (null if it didn't take part); group 0 is the whole match.
pub const RegexMatch = struct {
    re: JSValue,
    data: []const u8,
    slots: []?usize,
    allocator: Allocator,

    pub fn deinit(self: RegexMatch) void {
        self.allocator.free(self.slots);
    }
    pub fn start(self: RegexMatch) usize {
        return self.slots[0].?;
    }
    pub fn end(self: RegexMatch) usize {
        return self.slots[1].?;
    }
    pub fn groupCount(self: RegexMatch) usize {
        return self.re.regex.value.groupCount();
    }
    /// Group g's string, or undefined if it didn't take part.
    pub fn capture(self: RegexMatch, interp_: *Interpreter, g: usize) anyerror!JSValue {
        const a = self.slots[2 * g] orelse return JSValue.UNDEFINED;
        const b = self.slots[2 * g + 1] orelse return JSValue.UNDEFINED;
        return sliceValue(interp_, self.allocator, self.data, a, b);
    }
};

/// The subject of a JS string.
pub fn subjectOf(data: []const u8) zregex.Subject {
    return .{ .wtf8 = data };
}

/// The match z-regex finds from subject position `pos`: exactly there if
/// the regex is sticky, the first one at `pos` or after otherwise. Null
/// if none (or `pos` is past the end).
pub fn execRaw(allocator: Allocator, re: JSValue, data: []const u8, pos: usize) anyerror!?RegexMatch {
    if (pos > data.len) return null;
    const rx = &re.regex.value;
    const slots = try allocator.alloc(?usize, rx.slotCount());
    errdefer allocator.free(slots);
    var out: zregex.MatchSlots = .{ .slots = slots };
    var scratch = zregex.Scratch.init(allocator);
    defer scratch.deinit();
    if (!try rx.execAt(subjectOf(data), pos, &scratch, &out, .{})) {
        allocator.free(slots);
        return null;
    }
    return .{ .re = re, .data = data, .slots = slots, .allocator = allocator };
}

/// AdvanceStringIndex over subject positions: one code unit past `pos`
/// without `u`/`v`, one code point with it.
pub fn advancePos(re: JSValue, data: []const u8, pos: usize) usize {
    return re.regex.value.advanceIndex(subjectOf(data), pos);
}

/// The JS match-result array: [0]=whole match, [i]=capture i (undefined
/// if it didn't participate), plus own `index`, `input`, and `groups`.
pub fn makeMatchArray(self: *Interpreter, allocator: Allocator, m: RegexMatch) anyerror!JSValue {
    _ = allocator;
    var result = try self.gcNewArray();
    var g: usize = 0;
    while (g <= m.groupCount()) : (g += 1) {
        _ = try result.array.value.push(try m.capture(self, g));
    }
    // exec/match arrays carry extra own properties.
    try setArrayOwn(self, result, "index", JSValue.fromNumber(@floatFromInt(posToUtf16(m.data, m.start()))));
    try setArrayOwn(self, result, "input", try self.gcNewString(m.data));
    const named = m.re.regex.value.compiled.named_groups;
    if (named.len > 0) {
        var groups = try self.gcNewObject();
        // A duplicate name (`(?<x>a)|(?<x>b)`) takes whichever of its
        // groups took part; the property keeps its first position.
        for (named) |ng| {
            const v = try m.capture(self, ng.index);
            if (groups.object.value.getOwn(ng.name)) |old| {
                if (v == .undefined) continue;
                old.deinit();
            }
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

/// RegExpBuiltinExec: reads `lastIndex` (ToLength, in UTF-16 units) when
/// the regex is global or sticky, starts there (0 otherwise), and on a
/// match sets `lastIndex` to the match's end; on a failure a global or
/// sticky regex's `lastIndex` goes back to 0. The caller owns the match.
pub fn builtinExec(self: *Interpreter, allocator: Allocator, re: JSValue, data: []const u8) anyerror!?RegexMatch {
    const st = self.regexState(re);
    const stateful = st.global or st.sticky;
    // Real spec: ToLength(Get(R, "lastIndex")) is applied HERE, at read
    // time -- not eagerly coerced/clamped when `lastIndex` was assigned
    // (lastIndex.md's fix; see setPropertyOnValue) -- and always, even
    // when neither global nor sticky then discards it (step 4 before 8).
    const read_index = try toLength(self, st.last_index);
    const last_index = if (stateful) read_index else 0;
    const m = if (utf16ToPos(data, last_index)) |pos| try execRaw(allocator, re, data, pos) else null;
    if (stateful) {
        st.last_index.deinit();
        st.last_index = JSValue.fromNumber(if (m) |mm| @floatFromInt(posToUtf16(data, mm.end())) else 0);
    }
    return m;
}

fn regexTest(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const re = try requireRegex(ctx, this_value, "test");
    const self = interp(ctx);
    const is_str = arg(args, 0) == .string;
    const input = if (is_str) arg(args, 0).string.value.data else try self.toDisplayStringJS(allocator, arg(args, 0));
    defer if (!is_str) allocator.free(input);
    const m = try builtinExec(self, allocator, re, input) orelse return JSValue.fromBool(false);
    m.deinit();
    return JSValue.fromBool(true);
}

fn regexExec(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const re = try requireRegex(ctx, this_value, "exec");
    const self = interp(ctx);
    const is_str = arg(args, 0) == .string;
    const input = if (is_str) arg(args, 0).string.value.data else try self.toDisplayStringJS(allocator, arg(args, 0));
    defer if (!is_str) allocator.free(input);
    const m = try builtinExec(self, allocator, re, input) orelse return JSValue.NULL;
    defer m.deinit();
    return makeMatchArray(self, allocator, m);
}

fn regexToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const re = try requireRegex(ctx, this_value, "toString");
    const st = interp(ctx).regexState(re);
    var flags_buf: [8]u8 = undefined;
    const s = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ st.source, Interpreter.canonicalFlags(st, &flags_buf) });
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

/// String.prototype.split with a regex separator: splits at each match,
/// interleaving the separator's captures (SplitMatcher's loop). A match
/// that ends where the previous piece ended (an empty one there) is
/// stepped over by one character; a match at the very end never splits.
/// `pub`: String.prototype.split calls this.
pub fn regexSplit(self: *Interpreter, allocator: Allocator, data: []const u8, re: JSValue) anyerror!JSValue {
    var result = try self.gcNewArray();
    var p: usize = 0; // end of the last piece
    var q: usize = 0; // where the next search starts
    while (q < data.len) {
        const m = try execRaw(allocator, re, data, q) orelse break;
        defer m.deinit();
        if (m.start() >= data.len) break;
        const e = @min(m.end(), data.len);
        if (e == p) {
            q = advancePos(re, data, m.start());
            continue;
        }
        _ = try result.array.value.push(try sliceValue(self, allocator, data, p, m.start()));
        var g: usize = 1;
        while (g <= m.groupCount()) : (g += 1) _ = try result.array.value.push(try m.capture(self, g));
        p = e;
        q = p;
    }
    _ = try result.array.value.push(try sliceValue(self, allocator, data, p, data.len));
    return result;
}

/// Installs the `RegExp` constructor (no statics).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "RegExp", .ctor = .{ .arity = 2, .call = regexpConstructor, .constructable = true } });
}
