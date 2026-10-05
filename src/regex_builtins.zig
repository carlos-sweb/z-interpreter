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
    .{ "test", MethodSpec{ .call = regex_protocol.regexTest, .arity = 1 } },
    .{ "exec", MethodSpec{ .call = regexExec, .arity = 1 } },
    .{ "toString", MethodSpec{ .call = regexToString, .arity = 0 } },
});

const zregex = @import("zregex");
const zstring = @import("zstring");
const coercion = @import("coercion.zig");
const regex_protocol = @import("regex_protocol.zig");

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
    /// From the match's own slots (not the RegExp's current program,
    /// which RegExp.prototype.compile can replace).
    pub fn groupCount(self: RegexMatch) usize {
        return self.slots.len / 2 - 1;
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

/// UTF-16 indices of increasing subject positions in O(total length):
/// each call walks on from the previous position (a position before it
/// starts over).
pub const Utf16Cursor = struct {
    data: []const u8,
    pos: usize = 0,
    index: usize = 0,

    pub fn at(self: *Utf16Cursor, p: usize) usize {
        const mid = isMidPair(self.data, p);
        const base = if (mid) p - 2 else p;
        if (base < self.pos) {
            self.pos = 0;
            self.index = 0;
        }
        const piece = self.data[self.pos..base];
        self.index += zstring.utf16.byteIndexToUtf16(piece, piece.len) catch piece.len;
        self.pos = base;
        return self.index + @intFromBool(mid);
    }
};

/// The JS match-result array: [0]=whole match, [i]=capture i (undefined
/// if it didn't participate), plus own `index`, `input`, and `groups`.
/// `input` is the subject as a string value when the caller has one (it
/// is shared, not copied); null makes a new string of `m.data`.
pub fn makeMatchArray(self: *Interpreter, allocator: Allocator, m: RegexMatch, input: ?JSValue) anyerror!JSValue {
    return makeMatchArrayAt(self, allocator, m, posToUtf16(m.data, m.start()), input);
}

/// `makeMatchArray` with the match's UTF-16 index already known.
pub fn makeMatchArrayAt(self: *Interpreter, allocator: Allocator, m: RegexMatch, index: usize, input: ?JSValue) anyerror!JSValue {
    var result = try self.gcNewArray();
    const groups = try matchGroups(self, m);
    var g: usize = 0;
    while (g <= m.groupCount()) : (g += 1) {
        _ = try result.array.value.push(try m.capture(self, g));
    }
    // exec/match arrays carry extra own properties.
    try setArrayOwn(self, result, "index", JSValue.fromNumber(@floatFromInt(index)));
    try setArrayOwn(self, result, "input", if (input) |v| v.retain() else try self.gcNewString(m.data));
    try setArrayOwn(self, result, "groups", groups);
    if (self.regexState(m.re).has_indices) try setArrayOwn(self, result, "indices", try matchIndices(self, m));
    _ = allocator;
    return result;
}

/// The `indices` array of a `d` match (MakeMatchIndicesIndexPairArray):
/// [start, end] in UTF-16 units per group (undefined if it didn't take
/// part), with a `groups` object of the named groups' pairs (the same
/// pair objects) or undefined.
pub fn matchIndices(self: *Interpreter, m: RegexMatch) anyerror!JSValue {
    var indices = try self.gcNewArray();
    var g: usize = 0;
    while (g <= m.groupCount()) : (g += 1) {
        const a = m.slots[2 * g];
        const b = m.slots[2 * g + 1];
        if (a == null or b == null) {
            _ = try indices.array.value.push(JSValue.UNDEFINED);
            continue;
        }
        var pair = try self.gcNewArray();
        _ = try pair.array.value.push(JSValue.fromNumber(@floatFromInt(posToUtf16(m.data, a.?))));
        _ = try pair.array.value.push(JSValue.fromNumber(@floatFromInt(posToUtf16(m.data, b.?))));
        _ = try indices.array.value.push(pair);
    }
    const named = m.re.regex.value.compiled.named_groups;
    if (named.len == 0 or named[named.len - 1].index > m.groupCount()) {
        try setArrayOwn(self, indices, "groups", JSValue.UNDEFINED);
        return indices;
    }
    var groups = try self.gcNewObject();
    for (named) |ng| {
        const v = indices.array.value.get(ng.index);
        if (groups.object.value.getOwn(ng.name)) |old| {
            if (v == .undefined) continue;
            old.deinit();
        }
        try groups.object.value.set(ng.name, v.retain());
    }
    try setArrayOwn(self, indices, "groups", groups);
    return indices;
}

/// The `groups` object of a match (undefined without named groups). A
/// duplicate name (`(?<x>a)|(?<x>b)`) takes whichever of its groups took
/// part; the property keeps its first position.
pub fn matchGroups(self: *Interpreter, m: RegexMatch) anyerror!JSValue {
    const named = m.re.regex.value.compiled.named_groups;
    if (named.len == 0) return JSValue.UNDEFINED;
    var groups = try self.gcNewObject();
    for (named) |ng| {
        if (ng.index > m.groupCount()) continue;
        const v = try m.capture(self, ng.index);
        if (groups.object.value.getOwn(ng.name)) |old| {
            if (v == .undefined) continue;
            old.deinit();
        }
        try groups.object.value.set(ng.name, v);
    }
    return groups;
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
    // Real spec: ToLength(Get(R, "lastIndex")) is applied HERE, at read
    // time -- not eagerly coerced/clamped when `lastIndex` was assigned
    // (lastIndex.md's fix; see setPropertyOnValue) -- and always, even
    // when neither global nor sticky then discards it (step 4 before 8).
    // The flags are read after it: a valueOf can run
    // RegExp.prototype.compile (and the state pointer is fetched again,
    // since creating RegExps there can move the state table).
    const read_index = try toLength(self, self.regexState(re).last_index);
    const st = self.regexState(re);
    const stateful = st.global or st.sticky;
    const last_index = if (stateful) read_index else 0;
    const m = if (utf16ToPos(data, last_index)) |pos| try execRaw(allocator, re, data, pos) else null;
    if (stateful) {
        errdefer if (m) |mm| mm.deinit();
        try setLastIndex(self, re, JSValue.fromNumber(if (m) |mm| @floatFromInt(posToUtf16(data, mm.end())) else 0));
    }
    return m;
}

/// RegExp.prototype.exec, identified by RegExpExec to skip the call
/// when it is the method a RegExp would run.
pub const regexExecFn = regexExec;

fn regexExec(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const re = try requireRegex(ctx, this_value, "exec");
    const self = interp(ctx);
    const is_str = arg(args, 0) == .string;
    const input = if (is_str) arg(args, 0).string.value.data else try self.toDisplayStringJS(allocator, arg(args, 0));
    defer if (!is_str) allocator.free(input);
    const m = try builtinExec(self, allocator, re, input) orelse return JSValue.NULL;
    defer m.deinit();
    return makeMatchArray(self, allocator, m, if (is_str) arg(args, 0) else null);
}

fn regexToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const re = try requireRegex(ctx, this_value, "toString");
    const st = interp(ctx).regexState(re);
    var flags_buf: [8]u8 = undefined;
    const src = try escapePattern(allocator, st.source);
    defer allocator.free(src);
    const s = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ src, Interpreter.canonicalFlags(st, &flags_buf) });
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

/// Installs the `RegExp` constructor (no statics).
pub fn install(self: *Interpreter) !void {
    const ctor = try installBuiltin(self, .{ .name = "RegExp", .ctor = .{ .arity = 2, .call = regexpConstructor, .constructable = true } });
    self.regexp_ctor = ctor.retain();
}

// ===== RegExp.prototype accessors, Symbol methods, RegExp[Symbol.species] =====

/// `lastIndex` [[Set]] with Throw = true: a TypeError once
/// `Object.defineProperty` made it non-writable. Takes ownership of
/// `value` (released on the TypeError path too).
pub fn setLastIndex(self: *Interpreter, re: JSValue, value: JSValue) anyerror!void {
    const st = self.regexState(re);
    if (!st.last_index_writable) {
        value.deinit();
        return self.throwError(.type_error, "Cannot assign to read only property 'lastIndex' of object '[object RegExp]'", .{});
    }
    st.last_index.deinit();
    st.last_index = value;
}

/// EscapeRegExpPattern: the source text as `/source/flags` can show it.
/// An empty pattern is `(?:)`; a `/` outside a class becomes `\/`; a line
/// terminator (escaped or not) becomes `\n`, `\r`, ` ` or ` `.
/// The same output as V8.
pub fn escapePattern(allocator: Allocator, src: []const u8) ![]u8 {
    if (src.len == 0) return allocator.dupe(u8, "(?:)");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_class = false;
    var i: usize = 0;
    while (i < src.len) {
        const lt = lineTerminatorEscape(src[i..]);
        if (lt.len > 0) {
            try out.appendSlice(allocator, lt.escape);
            i += lt.len;
            continue;
        }
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            // An escaped line terminator is the same escape: `\` + LF -> `\n`.
            const next = lineTerminatorEscape(src[i + 1 ..]);
            if (next.len > 0) {
                try out.appendSlice(allocator, next.escape);
                i += 1 + next.len;
                continue;
            }
            try out.appendSlice(allocator, src[i .. i + 2]);
            i += 2;
            continue;
        }
        if (c == '[') in_class = true;
        if (c == ']') in_class = false;
        if (c == '/' and !in_class) {
            try out.appendSlice(allocator, "\\/");
        } else {
            try out.append(allocator, c);
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

const LineTerminator = struct { len: usize, escape: []const u8 };

fn lineTerminatorEscape(rest: []const u8) LineTerminator {
    if (rest.len == 0) return .{ .len = 0, .escape = "" };
    if (rest[0] == '\n') return .{ .len = 1, .escape = "\\n" };
    if (rest[0] == '\r') return .{ .len = 1, .escape = "\\r" };
    if (std.mem.startsWith(u8, rest, "\u{2028}")) return .{ .len = 3, .escape = "\\u2028" };
    if (std.mem.startsWith(u8, rest, "\u{2029}")) return .{ .len = 3, .escape = "\\u2029" };
    return .{ .len = 0, .escape = "" };
}

/// The receiver of a flag or `source` getter: the RegExp, or null for
/// %RegExp.prototype% itself (which has no [[OriginalFlags]] but answers
/// undefined / "(?:)"). Anything else is a TypeError.
fn flagReceiver(self: *Interpreter, this_value: JSValue, comptime getter: []const u8) anyerror!?JSValue {
    if (this_value == .regex) return this_value;
    if (!isObjectLike(this_value))
        return self.throwError(.type_error, "RegExp.prototype." ++ getter ++ " getter called on non-object", .{});
    if (this_value == .object and this_value.object == self.protos.regex.object) return null;
    return self.throwError(.type_error, "RegExp.prototype." ++ getter ++ " getter called on non-RegExp object", .{});
}

/// `get global`, `get ignoreCase`, ...: the flag from [[OriginalFlags]].
fn flagGetter(comptime field: []const u8, comptime getter: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = args;
            const self = interp(ctx);
            const re = try flagReceiver(self, this_value, getter) orelse return JSValue.UNDEFINED;
            return JSValue.fromBool(@field(self.regexState(re).*, field));
        }
    }.call;
}

/// `get source`: EscapeRegExpPattern of [[OriginalSource]].
fn sourceGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const re = try flagReceiver(self, this_value, "source") orelse return self.gcNewString("(?:)");
    const src = try escapePattern(allocator, self.regexState(re).source);
    defer allocator.free(src);
    return self.gcNewString(src);
}

/// `get flags`: generic over any object -- reads each flag property
/// (hasIndices, global, ignoreCase, multiline, dotAll, unicode,
/// unicodeSets, sticky, in that order) and concatenates the letters of
/// the truthy ones.
fn flagsGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    if (!isObjectLike(this_value))
        return self.throwError(.type_error, "RegExp.prototype.flags getter called on non-object", .{});
    const order = [_]struct { []const u8, u8 }{
        .{ "hasIndices", 'd' }, .{ "global", 'g' },  .{ "ignoreCase", 'i' },  .{ "multiline", 'm' },
        .{ "dotAll", 's' },     .{ "unicode", 'u' }, .{ "unicodeSets", 'v' }, .{ "sticky", 'y' },
    };
    var buf: [order.len]u8 = undefined;
    var n: usize = 0;
    for (order) |e| {
        const v = try self.getProperty(this_value, e[0]);
        defer v.deinit();
        if (coercion.isTruthy(v)) {
            buf[n] = e[1];
            n += 1;
        }
    }
    return self.gcNewString(buf[0..n]);
}

/// `get [Symbol.species]`: returns the receiver.
fn speciesGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = args;
    return this_value.retain();
}

/// A getter-only accessor, non-enumerable and configurable (the
/// attributes of every builtin accessor property).
fn defineGetter(self: *Interpreter, target: JSValue, key: []const u8, name: []const u8, call: NativeFn) !void {
    const getter = try native(self, name, 0, call);
    try target.object.value.defineAccessor(key, getter, null, JSValue.UNDEFINED);
    const rec = target.object.value.getOwnRecordMut(key).?;
    rec.descriptor.enumerable = false;
    rec.descriptor.configurable = true;
}

/// A well-known symbol (`Symbol.match`, ...) as a property key.
pub fn wellKnownKey(self: *Interpreter, comptime name: []const u8) ![]const u8 {
    const symbol_ctor = self.global_env.get("Symbol").?;
    const sym = (try self.functionStatics(symbol_ctor)).object.value.get(name).?;
    return self.encodeKey(sym);
}

/// Installs RegExp.prototype's accessors (flags, global, ..., source) and
/// [Symbol.match/matchAll/replace/search/split] methods, and
/// RegExp[Symbol.species]. Runs once RegExp.prototype exists
/// (materializeProtos).
pub fn installProtoExtras(self: *Interpreter) !void {
    const proto = self.protos.regex;
    inline for (.{
        .{ "hasIndices", "has_indices" }, .{ "global", "global" },  .{ "ignoreCase", "ignore_case" },     .{ "multiline", "multiline" },
        .{ "dotAll", "dot_all" },         .{ "unicode", "unicode" }, .{ "unicodeSets", "unicode_sets" }, .{ "sticky", "sticky" },
    }) |e| try defineGetter(self, proto, e[0], "get " ++ e[0], flagGetter(e[1], e[0]));
    try defineGetter(self, proto, "flags", "get flags", flagsGetter);
    try defineGetter(self, proto, "source", "get source", sourceGetter);

    inline for (.{
        .{ "match", 1, regex_protocol.symbolMatch },
        .{ "matchAll", 1, regex_protocol.symbolMatchAll },
        .{ "replace", 2, regex_protocol.symbolReplace },
        .{ "search", 1, regex_protocol.symbolSearch },
        .{ "split", 2, regex_protocol.symbolSplit },
    }) |e| {
        const key = try wellKnownKey(self, e[0]);
        defer self.gc_allocator.free(key);
        const f = try native(self, "[Symbol." ++ e[0] ++ "]", e[1], e[2]);
        try proto.object.value.defineProperty(key, f, .{ .writable = true, .enumerable = false, .configurable = true });
    }

    try proto.object.value.defineProperty("compile", try native(self, "compile", 2, regexCompile), .{ .writable = true, .enumerable = false, .configurable = true });
    try installStringIteratorProto(self);

    const species_key = try wellKnownKey(self, "species");
    defer self.gc_allocator.free(species_key);
    const statics = try self.functionStatics(self.global_env.get("RegExp").?);
    try defineGetter(self, statics, species_key, "get [Symbol.species]", speciesGetter);
    try statics.object.value.defineProperty("escape", try native(self, "escape", 1, regexpEscape), .{ .writable = true, .enumerable = false, .configurable = true });
}

/// RegExp.prototype.compile(pattern, flags) (Annex B): RegExpInitialize
/// on this RegExp -- a RegExp pattern lends its source and flags (and
/// then `flags` must be undefined) -- then lastIndex = 0 (a TypeError if
/// it is read-only, after the new pattern is in place).
fn regexCompile(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const re = try requireRegex(ctx, this_value, "compile");
    const pattern = arg(args, 0);
    const flags = arg(args, 1);
    var p: []u8 = undefined;
    var f: []u8 = undefined;
    if (pattern == .regex) {
        if (flags != .undefined) return self.throwError(.type_error, "Cannot supply flags when constructing one RegExp from another", .{});
        const st = self.regexState(pattern);
        p = try allocator.dupe(u8, st.source);
        f = try allocator.dupe(u8, st.flags);
    } else {
        p = if (pattern == .undefined) try allocator.dupe(u8, "") else try self.toDisplayStringJS(allocator, pattern);
        errdefer allocator.free(p);
        f = if (flags == .undefined) try allocator.dupe(u8, "") else try self.toDisplayStringJS(allocator, flags);
    }
    defer allocator.free(p);
    defer allocator.free(f);
    try self.recompileRegex(re, p, f);
    try setLastIndex(self, re, JSValue.fromNumber(0));
    return re.retain();
}

/// RegExp.escape(S) (ES2025): S with every character that could mean
/// something in a pattern escaped, valid with and without u/v.
fn regexpEscape(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const s = arg(args, 0);
    if (s != .string) return self.throwError(.type_error, "RegExp.escape requires a string", .{});
    const data = s.string.value.data;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < data.len) {
        const c = decodeWtf8(data, i);
        // A leading digit or ASCII letter would merge with a preceding
        // \0, \c, \x... in a larger pattern: always \xHH.
        if (out.items.len == 0 and c.cp < 0x80 and std.ascii.isAlphanumeric(@intCast(c.cp))) {
            try appendFmt(allocator, &out, "\\x{x:0>2}", .{c.cp});
        } else {
            try encodeForRegExpEscape(allocator, &out, c.cp, data[i .. i + c.len]);
        }
        i += c.len;
    }
    return self.gcNewString(out.items);
}

/// `out.print` for an ArrayList(u8) (short formatted pieces).
fn appendFmt(allocator: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    var buf: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, fmt, args));
}

const FmtAppender = struct {
    allocator: Allocator,
    out: *std.ArrayList(u8),
    fn print(self: FmtAppender, comptime fmt: []const u8, args: anytype) !void {
        return appendFmt(self.allocator, self.out, fmt, args);
    }
    fn writeAll(self: FmtAppender, bytes: []const u8) !void {
        return self.out.appendSlice(self.allocator, bytes);
    }
};

const Decoded = struct { cp: u21, len: usize };

/// One code point of a WTF-8 string (a lone surrogate is its own; an
/// invalid byte is that byte's value).
fn decodeWtf8(data: []const u8, i: usize) Decoded {
    const n = std.unicode.utf8ByteSequenceLength(data[i]) catch return .{ .cp = data[i], .len = 1 };
    if (i + n > data.len) return .{ .cp = data[i], .len = 1 };
    if (std.unicode.utf8Decode(data[i .. i + n])) |cp| return .{ .cp = cp, .len = n } else |_| {}
    if (n == 3) {
        if (zstring.utf16.decodeSurrogateWtf8(data[i .. i + 3])) |u| return .{ .cp = u, .len = 3 };
    }
    return .{ .cp = data[i], .len = 1 };
}

/// EncodeForRegExpEscape(c), appended to `out` (`raw` is c's own bytes).
fn encodeForRegExpEscape(allocator: Allocator, out: *std.ArrayList(u8), cp: u21, raw: []const u8) !void {
    const w = FmtAppender{ .allocator = allocator, .out = out };
    // SyntaxCharacter or `/`: a backslash before it.
    if (cp < 0x80 and std.mem.indexOfScalar(u8, "^$\\.*+?()[]{}|/", @intCast(cp)) != null) {
        try w.print("\\{c}", .{@as(u8, @intCast(cp))});
        return;
    }
    // ControlEscape.
    switch (cp) {
        0x09 => return w.writeAll("\\t"),
        0x0A => return w.writeAll("\\n"),
        0x0B => return w.writeAll("\\v"),
        0x0C => return w.writeAll("\\f"),
        0x0D => return w.writeAll("\\r"),
        else => {},
    }
    const other_punctuator = cp < 0x80 and std.mem.indexOfScalar(u8, ",-=<>#&!%:;@~'`\"", @intCast(cp)) != null;
    if (other_punctuator or isWhiteSpaceOrLineTerminator(cp) or (cp >= 0xD800 and cp <= 0xDFFF)) {
        if (cp <= 0xFF) return w.print("\\x{x:0>2}", .{cp});
        if (cp <= 0xFFFF) return w.print("\\u{x:0>4}", .{cp});
        const v = cp - 0x10000;
        return w.print("\\u{x:0>4}\\u{x:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
    }
    try out.appendSlice(allocator, raw);
}

/// WhiteSpace or LineTerminator (ECMA-262 12.2, 12.3).
fn isWhiteSpaceOrLineTerminator(cp: u21) bool {
    return switch (cp) {
        0x09, 0x0B, 0x0C, 0x20, 0xA0, 0xFEFF, 0x0A, 0x0D, 0x2028, 0x2029, 0x1680, 0x202F, 0x205F, 0x3000 => true,
        0x2000...0x200A => true,
        else => false,
    };
}

/// Installs %RegExpStringIteratorPrototype%: `next`, @@toStringTag "RegExp
/// String Iterator", and its parent %IteratorPrototype% (an object with
/// @@iterator returning the receiver; iterator_builtins makes it
/// `Iterator.prototype` and adds the helpers).
fn installStringIteratorProto(self: *Interpreter) !void {
    const parent = try self.ordinaryObject();
    if (self.symbol_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        try parent.object.value.defineProperty(key, try native(self, "[Symbol.iterator]", 0, builtin_helpers.iteratorSelfBuiltin), .{ .writable = true, .enumerable = false, .configurable = true });
    }
    const proto = try self.gcNewObject();
    try proto.object.value.setPrototype(&parent.object.value);
    try proto.object.value.defineProperty("next", try native(self, "next", 0, regex_protocol.regExpStringIteratorNext), .{ .writable = true, .enumerable = false, .configurable = true });
    const tag_key = try wellKnownKey(self, "toStringTag");
    defer self.gc_allocator.free(tag_key);
    try proto.object.value.defineProperty(tag_key, try self.gcNewString("RegExp String Iterator"), .{ .writable = false, .enumerable = false, .configurable = true });
    // [[Prototype]] is a raw pointer, not a counted reference: the
    // interpreter field owns `parent`.
    self.iterator_prototype = parent;
    self.regexp_string_iterator_proto = proto;
}

/// SameValue (Object.is).
pub fn sameValue(a: JSValue, b: JSValue) bool {
    if (a == .number and b == .number) {
        const x = a.number;
        const y = b.number;
        if (std.math.isNan(x) and std.math.isNan(y)) return true;
        return x == y and std.math.signbit(x) == std.math.signbit(y);
    }
    return zvalue.equality.sameValueZero(a, b);
}

/// `Object.defineProperty(re, "lastIndex", desc)`: `lastIndex` is a data
/// property that is never enumerable nor configurable, so a descriptor may
/// make it non-writable and set its value (ValidateAndApplyPropertyDescriptor),
/// nothing else. (Other keys go to the RegExp's own-property bag.)
pub fn regexDefineProperty(self: *Interpreter, re: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    _ = key;
    if (desc != .object) return self.throwError(.type_error, "Property description must be an object", .{});
    const d = &desc.object.value;
    const st = self.regexState(re);
    const redefine = d.hasOwnProperty("get") or d.hasOwnProperty("set") or
        (if (d.get("enumerable")) |v| coercion.isTruthy(v) else false) or
        (if (d.get("configurable")) |v| coercion.isTruthy(v) else false);
    if (redefine) return self.throwError(.type_error, "Cannot redefine property: lastIndex", .{});
    const writable = if (d.get("writable")) |v| coercion.isTruthy(v) else st.last_index_writable;
    const value = d.get("value");
    if (!st.last_index_writable) {
        if (writable) return self.throwError(.type_error, "Cannot redefine property: lastIndex", .{});
        if (value) |v| if (!sameValue(v, st.last_index)) return self.throwError(.type_error, "Cannot redefine property: lastIndex", .{});
        return;
    }
    if (value) |v| {
        st.last_index.deinit();
        st.last_index = v.retain();
    }
    st.last_index_writable = writable;
}

