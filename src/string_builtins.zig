//! `String.prototype` (basic + extended coverage + RegExp-pattern
//! methods: match/matchAll/search/replace/replaceAll) and the `String`
//! constructor + statics (fromCharCode/fromCodePoint). `argString` is
//! `pub` here -- `globalParseInt`/`globalParseFloat` (still in
//! builtins.zig, "Loose globals", not yet its own domain) reach it via
//! `builtins.argString`. `stringFromCodePoint` physically lived inside
//! the old "String.prototype (extended coverage)" section in
//! builtins.zig (should have been next to stringFromCharCode, a
//! static) -- same recurring interleaving shape found in earlier
//! batches (globalBoolean/globalNumber), fixed here by grouping it with
//! the other static instead of transcribing the misplacement forward.
//! z-interpreter-refactor.md, Step 5 Phase A batch 6.

const std = @import("std");
const Allocator = std.mem.Allocator;
const znumber = @import("znumber");
const zstring = @import("zstring");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const regex_builtins = @import("regex_builtins.zig");
const regex_protocol = @import("regex_protocol.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;
const toIntSat = builtin_helpers.toIntSat;
const toLength = builtin_helpers.toLength;
const makeArrayIterator = builtin_helpers.makeArrayIterator;

pub const string_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "toUpperCase", MethodSpec{ .call = stringToUpperCase, .arity = 0 } },
    .{ "toLowerCase", MethodSpec{ .call = stringToLowerCase, .arity = 0 } },
    .{ "toLocaleUpperCase", MethodSpec{ .call = stringToLocaleUpperCase, .arity = 0 } },
    .{ "toLocaleLowerCase", MethodSpec{ .call = stringToLocaleLowerCase, .arity = 0 } },
    .{ "charAt", MethodSpec{ .call = stringCharAt, .arity = 1 } },
    .{ "indexOf", MethodSpec{ .call = stringIndexOf, .arity = 1 } },
    .{ "includes", MethodSpec{ .call = stringIncludes, .arity = 1 } },
    .{ "startsWith", MethodSpec{ .call = stringStartsWith, .arity = 1 } },
    .{ "endsWith", MethodSpec{ .call = stringEndsWith, .arity = 1 } },
    .{ "slice", MethodSpec{ .call = stringSlice, .arity = 2 } },
    .{ "repeat", MethodSpec{ .call = stringRepeat, .arity = 1 } },
    .{ "split", MethodSpec{ .call = regex_protocol.stringSplit, .arity = 2 } },
    .{ "trim", MethodSpec{ .call = stringTrim, .arity = 0 } },
    .{ "trimStart", MethodSpec{ .call = stringTrimStart, .arity = 0 } },
    .{ "trimEnd", MethodSpec{ .call = stringTrimEnd, .arity = 0 } },
    .{ "charCodeAt", MethodSpec{ .call = stringCharCodeAt, .arity = 1 } },
    .{ "codePointAt", MethodSpec{ .call = stringCodePointAt, .arity = 1 } },
    .{ "at", MethodSpec{ .call = stringAt, .arity = 1 } },
    .{ "padStart", MethodSpec{ .call = stringPadStart, .arity = 1 } },
    .{ "padEnd", MethodSpec{ .call = stringPadEnd, .arity = 1 } },
    .{ "substring", MethodSpec{ .call = stringSubstring, .arity = 2 } },
    .{ "substr", MethodSpec{ .call = stringSubstr, .arity = 2 } },
    .{ "lastIndexOf", MethodSpec{ .call = stringLastIndexOf, .arity = 1 } },
    .{ "concat", MethodSpec{ .call = stringConcat, .arity = 1 } },
    .{ "replace", MethodSpec{ .call = regex_protocol.stringReplace, .arity = 2 } },
    .{ "replaceAll", MethodSpec{ .call = regex_protocol.stringReplaceAll, .arity = 2 } },
    .{ "match", MethodSpec{ .call = regex_protocol.stringMatch, .arity = 1 } },
    .{ "matchAll", MethodSpec{ .call = regex_protocol.stringMatchAll, .arity = 1 } },
    .{ "search", MethodSpec{ .call = regex_protocol.stringSearch, .arity = 1 } },
    .{ "localeCompare", MethodSpec{ .call = stringLocaleCompare, .arity = 1 } },
    .{ "toString", MethodSpec{ .call = stringToStringMethod, .arity = 0 } },
    .{ "valueOf", MethodSpec{ .call = stringToStringMethod, .arity = 0 } },
});

// ===== String.prototype (direct reuse of z-string's standalone method
// modules, all operating on ([]const u8, allocator)) =====

/// Real spec: String.prototype methods are generic -- RequireObjectCoercible
/// (throw only for null/undefined) then ToString(this), NOT "this must
/// already be a string" (confirmed against real Node:
/// `String.prototype.charAt.call(new Object(42), 0)` works, giving "4").
/// Always returns a fresh, caller-owned copy (even for the already-a-
/// string fast path) so every call site has one uniform cleanup
/// contract regardless of which path produced it.
fn requireString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, method: []const u8) anyerror![]const u8 {
    if (this_value == .undefined or this_value == .null) {
        return interp(ctx).throwError(.type_error, "String.prototype.{s} called on null or undefined", .{method});
    }
    const self = interp(ctx);
    const v = self.unboxPrimitiveWrapper(this_value) orelse this_value;
    if (v == .string) return allocator.dupe(u8, v.string.value.data);
    // toDisplayStringJS (not the pure coercion.toDisplayString): a
    // plain object with a real .toString()/.valueOf()/@@toPrimitive
    // needs the interpreter to actually call it (real ToPrimitive),
    // which the allocation-only coercion.zig helper can't do on its
    // own -- confirmed String({toString(){...}}) already goes through
    // this same wrapper elsewhere, so reusing it here rather than the
    // narrower coercion.toDisplayString picks up that case too.
    return self.toDisplayStringJS(allocator, v);
}

pub fn argString(self: *Interpreter, allocator: Allocator, args: []const JSValue, i: usize) ![]u8 {
    return self.toDisplayStringJS(allocator, arg(args, i));
}

fn stringToUpperCase(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, allocator, this_value, "toUpperCase");
    defer allocator.free(data);
    const out = try zstring.case.toUpperCase(allocator, data);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringToLowerCase(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, allocator, this_value, "toLowerCase");
    defer allocator.free(data);
    const out = try zstring.case.toLowerCase(allocator, data);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

// toLocaleLowerCase/toLocaleUpperCase: locale-insensitive simplification
// (no Intl/locale data in this engine) -- same narrowing already used
// elsewhere for other toLocale* methods. Real spec permits a
// locale-unaware default mapping when no locale-specific one exists.
const stringToLocaleUpperCase = stringToUpperCase;
const stringToLocaleLowerCase = stringToLowerCase;

fn stringCharAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "charAt");
    defer allocator.free(data);
    const idx: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try interp(ctx).toNumberJS(arg(args, 0)));
    const out = try zstring.access.charAt(allocator, data, idx);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "indexOf");
    defer allocator.free(data);
    const search = try argString(interp(ctx), allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromNumber(@floatFromInt(zstring.search.indexOf(data, search, null)));
}

fn stringIncludes(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "includes");
    defer allocator.free(data);
    const search = try argString(interp(ctx), allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromBool(zstring.search.includes(data, search, null));
}

fn stringStartsWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "startsWith");
    defer allocator.free(data);
    const search = try argString(interp(ctx), allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromBool(zstring.search.startsWith(data, search, null));
}

fn stringEndsWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "endsWith");
    defer allocator.free(data);
    const search = try argString(interp(ctx), allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromBool(zstring.search.endsWith(data, search, null));
}

fn stringSlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "slice");
    defer allocator.free(data);
    const start: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try interp(ctx).toNumberJS(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .undefined) null else toIntSat(try interp(ctx).toNumberJS(arg(args, 1)));
    const out = try zstring.transform.slice(allocator, data, start, end);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringRepeat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "repeat");
    defer allocator.free(data);
    const nf = if (arg(args, 0) == .undefined) 0 else try interp(ctx).toNumberJS(arg(args, 0));
    // A negative or infinite count is a RangeError (before any saturation).
    if (nf < 0 or std.math.isInf(nf)) return interp(ctx).throwError(.range_error, "Invalid count value: {d}", .{nf});
    const count: isize = toIntSat(nf);
    const out = try zstring.transform.repeat(allocator, data, count);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringTrim(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, allocator, this_value, "trim");
    defer allocator.free(data);
    const out = try zstring.trimming.trim(allocator, data);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

// ===== String.prototype (extended coverage) =====

fn stringTrimStart(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, allocator, this_value, "trimStart");
    defer allocator.free(data);
    const out = try zstring.trimming.trimStart(allocator, data);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringTrimEnd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, allocator, this_value, "trimEnd");
    defer allocator.free(data);
    const out = try zstring.trimming.trimEnd(allocator, data);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringCharCodeAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "charCodeAt");
    defer allocator.free(data);
    const idx: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try interp(ctx).toNumberJS(arg(args, 0)));
    return if (zstring.access.charCodeAt(data, idx)) |c| JSValue.fromNumber(@floatFromInt(c)) else JSValue.fromNumber(std.math.nan(f64));
}

fn stringCodePointAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "codePointAt");
    defer allocator.free(data);
    const idx: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try interp(ctx).toNumberJS(arg(args, 0)));
    return if (zstring.access.codePointAt(data, idx)) |c| JSValue.fromNumber(@floatFromInt(c)) else JSValue.UNDEFINED;
}

fn stringAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "at");
    defer allocator.free(data);
    const idx: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try interp(ctx).toNumberJS(arg(args, 0)));
    const out = (try zstring.access.at(allocator, data, idx)) orelse return JSValue.UNDEFINED;
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringPadStart(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "padStart");
    defer allocator.free(data);
    const target: isize = toIntSat(try interp(ctx).toNumberJS(arg(args, 0)));
    const pad_owned = try padFillArg(interp(ctx), allocator, args);
    defer if (pad_owned) |p| allocator.free(p);
    const out = try zstring.padding.padStart(allocator, data, target, pad_owned);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringPadEnd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "padEnd");
    defer allocator.free(data);
    const target: isize = toIntSat(try interp(ctx).toNumberJS(arg(args, 0)));
    const pad_owned = try padFillArg(interp(ctx), allocator, args);
    defer if (pad_owned) |p| allocator.free(p);
    const out = try zstring.padding.padEnd(allocator, data, target, pad_owned);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

/// padStart/padEnd's `fillString` argument: `undefined` (including not
/// passed) means "use the default (space)", real spec's ONLY exemption
/// from ToString -- any other value (even `false`/a number/an object)
/// must be ToString-coerced, not silently treated as absent (confirmed
/// against real Node: `"abc".padEnd(10, false)` pads with "false", not
/// spaces).
fn padFillArg(self: *Interpreter, allocator: Allocator, args: []const JSValue) anyerror!?[]const u8 {
    if (arg(args, 1) == .undefined) return null;
    return try self.toDisplayStringJS(allocator, arg(args, 1));
}

fn stringSubstring(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "substring");
    defer allocator.free(data);
    const start: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try interp(ctx).toNumberJS(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .undefined) null else toIntSat(try interp(ctx).toNumberJS(arg(args, 1)));
    const out = try zstring.transform.substring(allocator, data, start, end);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

/// Legacy substr(start, length) -- start can be negative (from end).
fn stringSubstr(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "substr");
    defer allocator.free(data);
    const total: isize = @intCast(zstring.utf16.lengthUtf16(data));
    var start: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try interp(ctx).toNumberJS(arg(args, 0)));
    if (start < 0) start = @max(total + start, 0);
    const length: isize = if (arg(args, 1) == .undefined) total else toIntSat(try interp(ctx).toNumberJS(arg(args, 1)));
    const end = @min(start + @max(length, 0), total);
    const out = try zstring.transform.substring(allocator, data, start, end);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringLastIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "lastIndexOf");
    defer allocator.free(data);
    if (arg(args, 0) != .string) return JSValue.fromNumber(-1);
    return JSValue.fromNumber(@floatFromInt(zstring.search.lastIndexOf(data, arg(args, 0).string.value.data, null)));
}

fn stringConcat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "concat");
    defer allocator.free(data);
    const self = interp(ctx);
    var pieces: std.ArrayList([]const u8) = .empty;
    defer pieces.deinit(allocator);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |o| allocator.free(o);
        owned.deinit(allocator);
    }
    for (args) |a| {
        if (a == .string) {
            try pieces.append(allocator, a.string.value.data);
        } else {
            const s = try self.toDisplayStringJS(allocator, a);
            try owned.append(allocator, s);
            try pieces.append(allocator, s);
        }
    }
    const out = try zstring.transform.concat(allocator, data, pieces.items);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringLocaleCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "localeCompare");
    defer allocator.free(data);
    const other: []const u8 = if (arg(args, 0) == .string) arg(args, 0).string.value.data else "";
    return JSValue.fromNumber(switch (std.mem.order(u8, data, other)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    });
}

fn stringToStringMethod(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, allocator, this_value, "toString");
    defer allocator.free(data);
    return interp(ctx).gcNewString(data);
}

/// Appends `chunk` to `buf`, merging a WTF-8 high-surrogate tail with a
/// WTF-8 low-surrogate head into the real 4-byte UTF-8 astral sequence --
/// see z-string-surrogate-charat.md (same helper as interpreter_expr.zig's
/// and array_builtins.zig's).
pub fn appendWtf8Merged(buf: *std.ArrayList(u8), allocator: Allocator, chunk: []const u8) !void {
    if (zstring.utf16.mergeSurrogateBoundary(buf.items, chunk)) |merged| {
        buf.items.len -= 3;
        try buf.appendSlice(allocator, &merged);
        try buf.appendSlice(allocator, chunk[3..]);
    } else {
        try buf.appendSlice(allocator, chunk);
    }
}

// ===== String statics (fromCharCode/fromCodePoint) =====

fn stringFromCharCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const self = interp(ctx);
    for (args) |a| {
        // ToUint16: wrap into [0, 65536) (NaN/Infinity -> 0), never panicking.
        const num = try self.toNumberJS(a);
        const wrapped: f64 = if (std.math.isFinite(num)) @mod(@trunc(num), 65536.0) else 0;
        const code: u21 = @intFromFloat(wrapped);
        // A lone surrogate (0xD800-0xDFFF) is a real, legal UTF-16
        // code unit -- `fromCharCode` just encodes each argument as
        // its own code unit, no pairing/validation at all (real spec
        // never checks; confirmed against Node:
        // `String.fromCharCode(0xD800).length === 1`). std.unicode's
        // own encoder rejects it as an invalid Unicode scalar value,
        // so WTF-8-encode it directly instead (z-string's
        // encodeSurrogateWtf8; z-string-surrogate-charat.md) -- this
        // used to silently DROP the argument entirely (`catch
        // continue`).
        if (code >= 0xD800 and code <= 0xDFFF) {
            var tmp: [3]u8 = undefined;
            zstring.utf16.encodeSurrogateWtf8(&tmp, @intCast(code));
            // Building up one code unit per argument is really the
            // same as repeated concatenation -- a high surrogate
            // argument immediately followed by a low surrogate one
            // must canonicalize into real UTF-8 at that boundary too,
            // same as `+`/String.prototype.concat (confirmed against
            // Node: `String.fromCharCode(0xD83D, 0xDE00) === "😀"`).
            if (zstring.utf16.mergeSurrogateBoundary(buf.items, &tmp)) |merged| {
                buf.items.len -= 3;
                try buf.appendSlice(allocator, &merged);
            } else {
                try buf.appendSlice(allocator, &tmp);
            }
            continue;
        }
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(code, &tmp) catch continue;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return interp(ctx).gcNewString(buf.items);
}

fn stringFromCodePoint(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const self = interp(ctx);
    for (args) |a| {
        // Each argument must be an integer code point in [0, 0x10FFFF].
        const num = try self.toNumberJS(a);
        if (!std.math.isFinite(num) or num != @trunc(num) or num < 0 or num > 0x10FFFF)
            return interp(ctx).throwError(.range_error, "Invalid code point {d}", .{num});
        const cp: u21 = @intFromFloat(num);
        // Real spec's range check above (0-0x10FFFF) does NOT exclude
        // the surrogate range -- confirmed against Node:
        // `String.fromCodePoint(0xD800)` succeeds (length 1, not a
        // RangeError). std.unicode's own encoder rejects it as an
        // invalid Unicode scalar value, so WTF-8-encode it directly
        // instead (same as fromCharCode above; z-string's
        // encodeSurrogateWtf8; z-string-surrogate-charat.md).
        if (cp >= 0xD800 and cp <= 0xDFFF) {
            var tmp: [3]u8 = undefined;
            zstring.utf16.encodeSurrogateWtf8(&tmp, @intCast(cp));
            // Same boundary canonicalization as fromCharCode above
            // (confirmed against Node: `String.fromCodePoint(0xD83D,
            // 0xDE00) === "😀"`).
            if (zstring.utf16.mergeSurrogateBoundary(buf.items, &tmp)) |merged| {
                buf.items.len -= 3;
                try buf.appendSlice(allocator, &merged);
            } else {
                try buf.appendSlice(allocator, &tmp);
            }
            continue;
        }
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch continue;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return interp(ctx).gcNewString(buf.items);
}

/// String.raw(template, ...substitutions) -- ECMA-262 22.1.2.4. Doesn't
/// need real tagged-template SYNTAX support (not implemented in this
/// engine's parser yet, confirmed separately): the function itself only
/// needs a "template object" with a `.raw` array-like, which test262
/// mostly constructs by hand (`String.raw({raw: [...]}, ...)`) rather
/// than via `` tag`...` ``.
fn stringRaw(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const template = arg(args, 0);
    if (template == .undefined or template == .null) {
        return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    }
    const raw = try self.getProperty(template, "raw");
    if (raw == .undefined or raw == .null) {
        return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    }
    const len_val = try self.getProperty(raw, "length");
    const len_f = try self.toNumberJS(len_val);
    // ToLength clamps to [0, 2^53-1] (real spec) -- well within usize
    // range on any platform this engine targets, so a straight
    // @intFromFloat after that clamp never overflows.
    const len: usize = if (len_f > 0) @intFromFloat(@min(len_f, 9007199254740991.0)) else 0;
    const subs: []const JSValue = if (args.len > 1) args[1..] else &.{};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "{d}", .{i});
        defer allocator.free(key);
        const lit_val = try self.getProperty(raw, key);
        const lit = try self.toDisplayStringJS(allocator, lit_val);
        defer allocator.free(lit);
        try out.appendSlice(allocator, lit);
        if (i + 1 == len) break;
        if (i < subs.len) {
            const sub = try self.toDisplayStringJS(allocator, subs[i]);
            defer allocator.free(sub);
            try out.appendSlice(allocator, sub);
        }
    }
    return self.gcNewString(out.items);
}

// ===== String constructor callable (String(x) / new String(x)) =====

fn globalString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    // Real spec (22.1.1.1): "If no arguments were passed to this function
    // invocation, let s be the empty String." -- NOT ToString(undefined)
    // ("undefined"), which is what a bare `arg(args, 0)` default would
    // give since a missing argument reads as JSValue.UNDEFINED here.
    // Confirmed against real Node: `new String()` boxes "", `new
    // String(undefined)` (an EXPLICIT undefined argument) boxes
    // "undefined" -- the empty-arg-list case is genuinely special, not
    // just ToString of the default.
    if (args.len == 0) return self.boxPrimitiveIfConstructed(ctx, this_value, try self.gcNewString(""));
    // String(symbol) is the one explicit coercion the spec allows --
    // "Symbol(desc)" -- unlike implicit `sym + ''` which throws.
    if (arg(args, 0) == .symbol) {
        const s = try arg(args, 0).symbol.value.toString(allocator);
        defer allocator.free(s);
        return self.boxPrimitiveIfConstructed(ctx, this_value, try self.gcNewString(s));
    }
    // String(regex) is regex.toString() -- /source/flags (with flags).
    if (arg(args, 0) == .regex) {
        const st = self.regexState(arg(args, 0));
        var flags_buf: [8]u8 = undefined;
        const s = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ st.source, Interpreter.canonicalFlags(st, &flags_buf) });
        defer allocator.free(s);
        return self.boxPrimitiveIfConstructed(ctx, this_value, try self.gcNewString(s));
    }
    const s = try self.toDisplayStringJS(allocator, arg(args, 0));
    defer allocator.free(s);
    return self.boxPrimitiveIfConstructed(ctx, this_value, try self.gcNewString(s));
}

/// Installs the `String` constructor + statics.
pub fn install(self: *Interpreter) !void {
    // String/Number/Boolean: callable = coercion (as before);
    // constructable = evalNew keeps the hollow instance (typeof "object",
    // no [[PrimitiveValue]] -- documented narrowing). Statics via bags.
    _ = try installBuiltin(self, .{ .name = "String", .ctor = .{ .arity = 1, .call = globalString, .constructable = true }, .statics = &.{
        .{ .name = "fromCharCode", .value = .{ .method = .{ .call = stringFromCharCode, .arity = 1 } } },
        .{ .name = "fromCodePoint", .value = .{ .method = .{ .call = stringFromCodePoint, .arity = 1 } } },
        .{ .name = "raw", .value = .{ .method = .{ .call = stringRaw, .arity = 1 } } },
    } });
}
