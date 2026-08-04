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
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const regex_builtins = @import("regex_builtins.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;
const toIntSat = builtin_helpers.toIntSat;
const makeArrayIterator = builtin_helpers.makeArrayIterator;
const regexFindFrom = regex_builtins.regexFindFrom;
const makeMatchArray = regex_builtins.makeMatchArray;
const regexSplit = regex_builtins.regexSplit;

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
    .{ "split", MethodSpec{ .call = stringSplit, .arity = 2 } },
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
    .{ "replace", MethodSpec{ .call = stringReplace, .arity = 2 } },
    .{ "replaceAll", MethodSpec{ .call = stringReplaceAll, .arity = 2 } },
    .{ "match", MethodSpec{ .call = stringMatch, .arity = 1 } },
    .{ "matchAll", MethodSpec{ .call = stringMatchAll, .arity = 1 } },
    .{ "search", MethodSpec{ .call = stringSearch, .arity = 1 } },
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

pub fn argString(allocator: Allocator, args: []const JSValue, i: usize) ![]u8 {
    return coercion.toDisplayString(allocator, arg(args, i));
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
    const idx: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try coercion.toNumber(arg(args, 0)));
    const out = try zstring.access.charAt(allocator, data, idx);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "indexOf");
    defer allocator.free(data);
    const search = try argString(allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromNumber(@floatFromInt(zstring.search.indexOf(data, search, null)));
}

fn stringIncludes(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "includes");
    defer allocator.free(data);
    const search = try argString(allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromBool(zstring.search.includes(data, search, null));
}

fn stringStartsWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "startsWith");
    defer allocator.free(data);
    const search = try argString(allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromBool(zstring.search.startsWith(data, search, null));
}

fn stringEndsWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "endsWith");
    defer allocator.free(data);
    const search = try argString(allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromBool(zstring.search.endsWith(data, search, null));
}

fn stringSlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "slice");
    defer allocator.free(data);
    const start: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try coercion.toNumber(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .undefined) null else toIntSat(try coercion.toNumber(arg(args, 1)));
    const out = try zstring.transform.slice(allocator, data, start, end);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringRepeat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "repeat");
    defer allocator.free(data);
    const nf = if (arg(args, 0) == .undefined) 0 else try coercion.toNumber(arg(args, 0));
    // A negative or infinite count is a RangeError (before any saturation).
    if (nf < 0 or std.math.isInf(nf)) return interp(ctx).throwError(.range_error, "Invalid count value: {d}", .{nf});
    const count: isize = toIntSat(nf);
    const out = try zstring.transform.repeat(allocator, data, count);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringSplit(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "split");
    defer allocator.free(data);
    if (arg(args, 0) == .regex) return regexSplit(interp(ctx), allocator, data, arg(args, 0));
    const sep: ?[]const u8 = if (arg(args, 0) == .string) arg(args, 0).string.value.data else null;
    const parts = try zstring.split.split(allocator, data, sep, null);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    var result = try interp(ctx).gcNewArray();
    for (parts) |p| {
        _ = try result.array.value.push(try interp(ctx).gcNewString(p));
    }
    return result;
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
    const idx: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try coercion.toNumber(arg(args, 0)));
    return if (zstring.access.charCodeAt(data, idx)) |c| JSValue.fromNumber(@floatFromInt(c)) else JSValue.fromNumber(std.math.nan(f64));
}

fn stringCodePointAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "codePointAt");
    defer allocator.free(data);
    const idx: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try coercion.toNumber(arg(args, 0)));
    return if (zstring.access.codePointAt(data, idx)) |c| JSValue.fromNumber(@floatFromInt(c)) else JSValue.UNDEFINED;
}

fn stringAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "at");
    defer allocator.free(data);
    const idx: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try coercion.toNumber(arg(args, 0)));
    const out = (try zstring.access.at(allocator, data, idx)) orelse return JSValue.UNDEFINED;
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringPadStart(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "padStart");
    defer allocator.free(data);
    const target: isize = toIntSat(try coercion.toNumber(arg(args, 0)));
    const pad_owned = try padFillArg(allocator, args);
    defer if (pad_owned) |p| allocator.free(p);
    const out = try zstring.padding.padStart(allocator, data, target, pad_owned);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringPadEnd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "padEnd");
    defer allocator.free(data);
    const target: isize = toIntSat(try coercion.toNumber(arg(args, 0)));
    const pad_owned = try padFillArg(allocator, args);
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
fn padFillArg(allocator: Allocator, args: []const JSValue) anyerror!?[]const u8 {
    if (arg(args, 1) == .undefined) return null;
    return try coercion.toDisplayString(allocator, arg(args, 1));
}

fn stringSubstring(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "substring");
    defer allocator.free(data);
    const start: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try coercion.toNumber(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .undefined) null else toIntSat(try coercion.toNumber(arg(args, 1)));
    const out = try zstring.transform.substring(allocator, data, start, end);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

/// Legacy substr(start, length) -- start can be negative (from end).
fn stringSubstr(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "substr");
    defer allocator.free(data);
    const total: isize = @intCast(zstring.utf16.lengthUtf16(data));
    var start: isize = toIntSat(if (arg(args, 0) == .undefined) 0 else try coercion.toNumber(arg(args, 0)));
    if (start < 0) start = @max(total + start, 0);
    const length: isize = if (arg(args, 1) == .undefined) total else toIntSat(try coercion.toNumber(arg(args, 1)));
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
            const s = try coercion.toDisplayString(allocator, a);
            try owned.append(allocator, s);
            try pieces.append(allocator, s);
        }
    }
    const out = try zstring.transform.concat(allocator, data, pieces.items);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

/// replace/replaceAll -- string OR regex patterns; string OR function
/// replacements ($-substitution via z-regex for the string case).
fn stringReplaceImpl(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue, all: bool) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, if (all) "replaceAll" else "replace");
    defer allocator.free(data);
    const self = interp(ctx);
    if (arg(args, 0) == .regex) return regexReplace(self, allocator, data, arg(args, 0), arg(args, 1), all);
    if (arg(args, 0) != .string) return self.throwError(.type_error, "string replace with a non-string pattern is not supported", .{});
    const pattern = arg(args, 0).string.value.data;
    // The replacement: a string, or a function called (match, offset, whole).
    const repl_fn = arg(args, 1);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    var replaced = false;
    while (i < data.len) {
        if ((!replaced or all) and pattern.len > 0 and i + pattern.len <= data.len and std.mem.eql(u8, data[i .. i + pattern.len], pattern)) {
            if (repl_fn == .function) {
                const r = try repl_fn.function.value.call(repl_fn.function.value.ctx, allocator, JSValue.UNDEFINED, &.{
                    arg(args, 0), JSValue.fromNumber(@floatFromInt(i)), this_value,
                });
                const rs = try coercion.toDisplayString(allocator, r);
                defer allocator.free(rs);
                try buf.appendSlice(allocator, rs);
            } else if (repl_fn == .string) {
                try buf.appendSlice(allocator, repl_fn.string.value.data);
            }
            i += pattern.len;
            replaced = true;
            continue;
        }
        try buf.append(allocator, data[i]);
        i += 1;
    }
    return interp(ctx).gcNewString(buf.items);
}

fn stringReplace(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    return stringReplaceImpl(ctx, allocator, this_value, args, false);
}

fn stringReplaceAll(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    return stringReplaceImpl(ctx, allocator, this_value, args, true);
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

// ===== String methods with RegExp patterns =====

/// str.match(re): non-global -> a match array (or null); global -> an
/// array of all whole-match strings (or null).
fn stringMatch(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "match");
    defer allocator.free(data);
    const self = interp(ctx);
    const re = try coerceToRegex(self, allocator, arg(args, 0));
    const st = self.regexState(re);
    if (!st.global) {
        const hit = try regexFindFrom(re, data, 0);
        if (hit) |h| {
            defer h.match.deinit();
            return makeMatchArray(self, allocator, h);
        }
        return JSValue.NULL;
    }
    var all = try re.regex.value.findAll(data);
    defer {
        for (all.items) |*mm| mm.deinit();
        all.deinit(allocator);
    }
    if (all.items.len == 0) return JSValue.NULL;
    var result = try interp(ctx).gcNewArray();
    for (all.items) |match| _ = try result.array.value.push(try interp(ctx).gcNewString(match.group(data)));
    return result;
}

/// str.matchAll(re): an iterator of match arrays.
fn stringMatchAll(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "matchAll");
    defer allocator.free(data);
    const self = interp(ctx);
    const re = try coerceToRegex(self, allocator, arg(args, 0));
    var all = try re.regex.value.findAll(data);
    defer {
        for (all.items) |*mm| mm.deinit();
        all.deinit(allocator);
    }
    var arr = try interp(ctx).gcNewArray();
    for (all.items) |match| {
        _ = try arr.array.value.push(try makeMatchArray(self, allocator, .{ .match = match, .sub = data, .base = 0, .full = data, .group_count = re.regex.value.compiled.group_count }));
    }
    return makeArrayIterator(self, allocator, arr, .values);
}

fn stringSearch(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, allocator, this_value, "search");
    defer allocator.free(data);
    const self = interp(ctx);
    const re = try coerceToRegex(self, allocator, arg(args, 0));
    const m = try re.regex.value.find(data);
    if (m) |match| {
        defer match.deinit();
        return JSValue.fromNumber(@floatFromInt(match.start));
    }
    return JSValue.fromNumber(-1);
}

/// Coerce a match/replace/search/split argument to a `.regex` (a plain
/// string becomes a source-literal regex, real JS behavior).
fn coerceToRegex(self: *Interpreter, allocator: Allocator, v: JSValue) anyerror!JSValue {
    if (v == .regex) return v;
    const has_src = v != .undefined;
    const source = if (has_src) try coercion.toDisplayString(allocator, v) else "";
    defer if (has_src) allocator.free(source);
    return self.makeRegex(source, "");
}

/// String.prototype.replace/replaceAll with a regex pattern. Delegates
/// string replacements to z-regex (JS `$` substitution included);
/// function replacements loop the matches.
fn regexReplace(self: *Interpreter, allocator: Allocator, data: []const u8, re: JSValue, repl: JSValue, all_flag: bool) anyerror!JSValue {
    const st = self.regexState(re);
    const replace_all = st.global or all_flag;
    if (repl != .function) {
        const has_repl = repl != .undefined;
        const rs = if (has_repl) try coercion.toDisplayString(allocator, repl) else "undefined";
        defer if (has_repl) allocator.free(rs);
        const out = if (replace_all)
            try re.regex.value.replaceAll(allocator, data, rs)
        else
            try re.regex.value.replace(allocator, data, rs);
        defer allocator.free(out);
        return self.gcNewString(out);
    }
    // Function replacement: build the result splicing each match's
    // fn(match, ...captures, offset, input) result.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var pos: usize = 0;
    while (pos <= data.len) {
        const m = try re.regex.value.findAt(data, pos);
        const match = m orelse break;
        defer match.deinit();
        try buf.appendSlice(allocator, data[pos..match.start]);
        // callback args: (match, cap1, cap2, ..., offset, input)
        var call_args: std.ArrayList(JSValue) = .empty;
        defer {
            for (call_args.items) |a| a.deinit();
            call_args.deinit(allocator);
        }
        try call_args.append(allocator, try self.gcNewString(match.group(data)));
        var i: usize = 1;
        while (i <= re.regex.value.compiled.group_count) : (i += 1) {
            const cap = if (match.getCapture(i, data)) |c| try self.gcNewString(c) else JSValue.UNDEFINED;
            try call_args.append(allocator, cap);
        }
        try call_args.append(allocator, JSValue.fromNumber(@floatFromInt(match.start)));
        try call_args.append(allocator, try self.gcNewString(data));
        const r = try repl.function.value.call(repl.function.value.ctx, allocator, JSValue.UNDEFINED, call_args.items);
        defer r.deinit();
        const rs = try coercion.toDisplayString(allocator, r);
        defer allocator.free(rs);
        try buf.appendSlice(allocator, rs);
        // advance past the match (empty match -> step one to avoid a loop)
        pos = if (match.end > match.start) match.end else match.end + 1;
        if (!replace_all) {
            try buf.appendSlice(allocator, data[match.end..]);
            return self.gcNewString(buf.items);
        }
    }
    if (pos < data.len) try buf.appendSlice(allocator, data[pos..]);
    return self.gcNewString(buf.items);
}

// ===== String statics (fromCharCode/fromCodePoint) =====

fn stringFromCharCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (args) |a| {
        // ToUint16: wrap into [0, 65536) (NaN/Infinity -> 0), never panicking.
        const num = try coercion.toNumber(a);
        const wrapped: f64 = if (std.math.isFinite(num)) @mod(@trunc(num), 65536.0) else 0;
        const code: u21 = @intFromFloat(wrapped);
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
    for (args) |a| {
        // Each argument must be an integer code point in [0, 0x10FFFF].
        const num = try coercion.toNumber(a);
        if (!std.math.isFinite(num) or num != @trunc(num) or num < 0 or num > 0x10FFFF)
            return interp(ctx).throwError(.range_error, "Invalid code point {d}", .{num});
        const cp: u21 = @intFromFloat(num);
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
