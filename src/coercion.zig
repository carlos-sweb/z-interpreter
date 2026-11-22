const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const zparser = @import("zparser");
const zbigint = @import("zbigint");
const JSValue = zvalue.JSValue;

/// ECMA-262 ToBoolean. Arrays/objects/functions are truthy even when
/// empty -- the real JS quirk, not a bug.
pub fn isTruthy(v: JSValue) bool {
    return v.isTruthy();
}

fn isJsWhitespaceCp(cp: u21) bool {
    return switch (cp) {
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

fn trimJsWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        if (s[start] < 0x80) {
            if (!isJsWhitespaceCp(s[start])) break;
            start += 1;
        } else {
            const n = std.unicode.utf8ByteSequenceLength(s[start]) catch break;
            if (start + n > s.len) break;
            const cp = std.unicode.utf8Decode(s[start .. start + n]) catch break;
            if (!isJsWhitespaceCp(cp)) break;
            start += n;
        }
    }
    var end: usize = s.len;
    while (end > start) {
        if (s[end - 1] < 0x80) {
            if (!isJsWhitespaceCp(s[end - 1])) break;
            end -= 1;
        } else {
            var k: usize = end - 1;
            while (k > start and (s[k] & 0xC0) == 0x80) k -= 1;
            const cp = std.unicode.utf8Decode(s[k..end]) catch break;
            if (!isJsWhitespaceCp(cp)) break;
            end = k;
        }
    }
    return s[start..end];
}

fn isValidStrDecimalLiteral(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '+' or s[i] == '-') i += 1;
    if (i >= s.len) return false;
    if (std.mem.eql(u8, s[i..], "Infinity")) return true;
    var has_digits = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) has_digits = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) has_digits = true;
    }
    if (!has_digits) return false;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var has_exp = false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) has_exp = true;
        if (!has_exp) return false;
    }
    return i == s.len;
}

fn parseRadixLiteral(digits: []const u8, base: u8) f64 {
    if (digits.len == 0) return std.math.nan(f64);
    var acc: f64 = 0;
    const fbase: f64 = @floatFromInt(base);
    for (digits) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return std.math.nan(f64),
        };
        if (d >= base) return std.math.nan(f64);
        acc = acc * fbase + @as(f64, @floatFromInt(d));
    }
    return acc;
}

/// ECMA-262 ToNumber, narrowed to the primitives this phase's operators
/// need. Real ToPrimitive (valueOf/Symbol.toPrimitive) doesn't exist in
/// this ecosystem yet, so object-shaped values are `error.NotImplemented`.
pub fn toNumber(v: JSValue) !f64 {
    return switch (v.unpack()) {
        .number => |n| n,
        .boolean => |b| if (b) @as(f64, 1) else @as(f64, 0),
        .undefined => std.math.nan(f64),
        .null => 0,
        // Real ToNumber(string) requires the *whole* (trimmed) string to be
        // a valid numeric literal, else NaN -- znumber's parseFloat is more
        // permissive (stops at trailing garbage). Narrowed/simplified for
        // this phase; not spec-exact.
        //
        // One StringNumericLiteral case znumber's parseFloat gets wrong
        // for THIS caller specifically: an empty (or all-whitespace)
        // string is explicitly defined as 0 by the grammar (StrWhiteSpace
        // alone is a valid StringNumericLiteral, empty StrNumericLiteral
        // production), not NaN -- confirmed against real Node
        // (`Number("")`/`Number("   ")` === 0). `parseFloat`/
        // `Number.parseFloat` (the JS global, a DIFFERENT algorithm) is
        // NOT touched here and correctly keeps giving NaN for "" -- this
        // special case belongs only to ToNumber, not to znumber's shared
        // parser.
        .string => |box| blk: {
            const trimmed = trimJsWhitespace(box.value.data);
            if (trimmed.len == 0) break :blk 0;
            if (trimmed.len >= 3 and (trimmed[0] == '+' or trimmed[0] == '-') and trimmed[1] == '0') {
                const p = trimmed[2];
                if (p == 'x' or p == 'X' or p == 'b' or p == 'B' or p == 'o' or p == 'O') {
                    break :blk std.math.nan(f64);
                }
            }
            if (trimmed.len >= 2 and trimmed[0] == '0') {
                if (trimmed[1] == 'x' or trimmed[1] == 'X') break :blk parseRadixLiteral(trimmed[2..], 16);
                if (trimmed[1] == 'b' or trimmed[1] == 'B') break :blk parseRadixLiteral(trimmed[2..], 2);
                if (trimmed[1] == 'o' or trimmed[1] == 'O') break :blk parseRadixLiteral(trimmed[2..], 8);
            }
            if (!isValidStrDecimalLiteral(trimmed)) break :blk std.math.nan(f64);
            break :blk znumber.ParsingMethods.parseFloat(trimmed);
        },
        // Number(date) is its millisecond timestamp (real ToPrimitive
        // "number" hint behavior for Dates).
        .date => |box| @floatFromInt(box.value.getTime()),
        // Explicit Number(1n) is spec-legal and must work -- but this
        // function being callable does NOT mean implicit `1n + 1` is
        // safe; binaryOp/evalUnary must intercept bigint operands before
        // reaching a blind toNumber call on a mixed pair (roadmap item
        // 18, phase 4 -- not yet wired, so implicit arithmetic mixing
        // is temporarily silently permitted rather than a TypeError).
        .bigint => |box| box.value.toFloat(),
        .array, .object, .regex, .symbol, .map, .set, .@"error", .function, .promise, .proxy, .array_buffer, .data_view, .typed_array, .temporal => error.NotImplemented,
    };
}

/// ECMA-262 7.1.6 ToInt32: NaN/±0/±Inf map to +0; otherwise truncate
/// toward zero and wrap modulo 2^32 into the signed 32-bit range.
pub fn toInt32(v: JSValue) !i32 {
    return @bitCast(try toUint32(v));
}

/// ECMA-262 7.1.7 ToUint32 -- same as ToInt32 but reinterpreted unsigned.
pub fn toUint32(v: JSValue) !u32 {
    const n = try toNumber(v);
    if (std.math.isNan(n) or std.math.isInf(n) or n == 0) return 0;
    // Truncate toward zero, then wrap modulo 2^32 (float @mod's result
    // takes the divisor's sign, so it already lands in [0, 2^32)).
    const wrapped = @mod(@trunc(n), 4294967296.0);
    return @intFromFloat(wrapped);
}

/// Array.prototype.join()/toString()'s per-element stringify policy: holes
/// (undefined/null) become "" rather than the literal "undefined"/"null"
/// text general ToString produces for those same values -- a rule specific
/// to Array join, not to ToString itself. Shared by toDisplayString's own
/// `.array` case below and by `array_builtins.zig`'s arrayJoin/
/// arrayToStringMethod, all three of which used to hand-roll this same
/// loop independently (see ~/.plans/builtins-consolidation-analysis.md).
/// z-array's joinWith() takes this as its comptime stringify callback.
pub fn joinElementToString(_: void, item: JSValue, allocator: Allocator) anyerror![]u8 {
    return switch (item.tag()) {
        .undefined, .null => try allocator.dupe(u8, ""),
        else => toDisplayString(allocator, item),
    };
}

/// ECMA-262 ToString, narrowed to what template literals and `+`'s
/// string-concat branch need. Caller owns the returned slice.
pub fn toDisplayString(allocator: Allocator, v: JSValue) ![]u8 {
    return switch (v.unpack()) {
        .number => |n| try znumber.FormattingMethods.toString(n, allocator, null),
        .string => |box| try allocator.dupe(u8, box.value.data),
        .boolean => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .undefined => try allocator.dupe(u8, "undefined"),
        .null => try allocator.dupe(u8, "null"),
        // Array.prototype.toString's default behavior: comma-join each
        // element's own ToString (holes/null/undefined become "").
        .array => |box| try box.value.joinWith(",", allocator, {}, joinElementToString),
        // ToString(date) uses toString() ("Wed Jul 20 2026 ...") -- NOT
        // toISOString (that's console.log/inspect's job); see the .date case
        // in inspect.zig.
        .date => |box| box.value.toString(allocator) catch try allocator.dupe(u8, "Invalid Date"),
        .promise => try allocator.dupe(u8, "[object Promise]"),
        // `/source/` (flags omitted -- the exact form is regex.toString()).
        .regex => |box| try std.fmt.allocPrint(allocator, "/{s}/", .{box.value.getPattern()}),
        // Digits only, no trailing `n` -- that suffix is a console.log/
        // inspect-only display convention (see inspect.zig's own .bigint
        // case), not part of ToString: `${1n}` === "1", not "1n".
        .bigint => |box| try box.value.toString(allocator, 10),
        .object, .symbol, .map, .set, .@"error", .function, .proxy, .array_buffer, .data_view, .typed_array, .temporal => error.NotImplemented,
    };
}

/// ECMA-262 Strict Equality plus a narrowed Abstract Equality Comparison
/// (`==`/`!=`) -- only the primitive-coercion cases; any comparison
/// involving a non-null/undefined array/object/function/etc. against a
/// mismatched tag is `error.NotImplemented` (needs real ToPrimitive --
/// see `interpreter_support.zig`'s `looseEqualsJS`, which retries via
/// `toPrimitive` on whichever side isn't already primitive). `pub` so
/// that wrapper can call back into the primitive-only cases here once
/// both sides have been reduced to primitives.
pub fn looseEquals(allocator: Allocator, a: JSValue, b: JSValue) !bool {
    if (a.tag() == b.tag()) {
        return zvalue.equality.strictEquals(a, b);
    }
    if ((a.isUndefined() or a.isNull()) and (b.isUndefined() or b.isNull())) return true;
    if (a.isUndefined() or a.isNull() or b.isUndefined() or b.isNull()) return false;
    if (a.isBool()) return looseEquals(allocator, JSValue.fromNumber(try toNumber(a)), b);
    if (b.isBool()) return looseEquals(allocator, a, JSValue.fromNumber(try toNumber(b)));
    if (a.isNumber() and b.isString()) return a.asNumber() == try toNumber(b);
    if (a.isString() and b.isNumber()) return (try toNumber(a)) == b.asNumber();
    // Real JS explicitly allows `==`/`!=` to mix BigInt with Number/
    // String (unlike the arithmetic operators, which throw) --
    // number mixing is narrowed to float comparison (documented
    // precision-loss narrowing, same as ToNumber(bigint) elsewhere in
    // this file); string mixing parses exact digit text (StringToBigInt
    // is integer-only, unlike the general numeric-string grammar), a
    // parse failure meaning "not equal", not an error.
    if (a.isBigInt() and b.isNumber()) return bigintEqualsNumber(a.asBigInt().value, b.asNumber());
    if (a.isNumber() and b.isBigInt()) return bigintEqualsNumber(b.asBigInt().value, a.asNumber());
    if (a.isBigInt() and b.isString()) return try bigintEqualsString(allocator, a.asBigInt().value, b.asString().value.data);
    if (a.isString() and b.isBigInt()) return try bigintEqualsString(allocator, b.asBigInt().value, a.asString().value.data);
    return error.NotImplemented;
}

fn bigintEqualsNumber(bi: zbigint.ZBigInt, n: f64) bool {
    if (std.math.isNan(n) or std.math.isInf(n) or @floor(n) != n) return false;
    return bi.toFloat() == n;
}

fn bigintEqualsString(allocator: Allocator, bi: zbigint.ZBigInt, s: []const u8) !bool {
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    if (trimmed.len == 0) return bi.isZero();
    var parsed = zbigint.ZBigInt.fromDigitText(allocator, trimmed) catch return false;
    defer parsed.deinit();
    return bi.eql(parsed);
}

/// Evaluates every non-short-circuiting BinaryOp. `&&`/`||`/`??` and their
/// compound-assignment forms are short-circuiting and live in the
/// interpreter's own expression evaluator instead, since they must not
/// eagerly evaluate the right operand.
pub fn binaryOp(allocator: Allocator, op: zparser.BinaryOp, left: JSValue, right: JSValue) !JSValue {
    return switch (op) {
        // String-concat is always intercepted by the interpreter's own
        // `stringConcat` BEFORE reaching here (needs `gcNewString` for
        // GC tracking, which this module deliberately doesn't have --
        // same reasoning as instanceof/in below) -- only the plain
        // numeric case ever actually runs this branch.
        .add => JSValue.fromNumber((try toNumber(left)) + (try toNumber(right))),
        .sub => JSValue.fromNumber((try toNumber(left)) - (try toNumber(right))),
        .mul => JSValue.fromNumber((try toNumber(left)) * (try toNumber(right))),
        .div => JSValue.fromNumber((try toNumber(left)) / (try toNumber(right))),
        // ECMA-262 `%` is a truncated-division remainder (result takes
        // the DIVIDEND's sign, e.g. -1 % 2 === -1) -- `@rem`, not `@mod`
        // (Zig's `@mod` is floored, taking the DIVISOR's sign instead,
        // e.g. would give -1 % 2 === 1). Confirmed against real Node.
        .mod => JSValue.fromNumber(@rem(try toNumber(left), try toNumber(right))),
        .pow => JSValue.fromNumber(std.math.pow(f64, try toNumber(left), try toNumber(right))),
        // Real JS allows `<`/`>`/`<=`/`>=` to mix BigInt and Number
        // without throwing. Both-bigint compares exactly (no precision
        // loss); a mixed pair falls back to the existing ToNumber path
        // (documented narrowing -- same precision-loss tradeoff as
        // ToNumber(bigint) elsewhere in this file).
        //
        // Real spec's Abstract Relational Comparison (11.8.5) special-
        // cases "both operands are Strings": a lexicographic code-unit
        // comparison, NOT ToNumber(string) on each side -- ToNumber
        // only applies when at least one side isn't a String. Missing
        // this branch made every string `<`/`>` comparison silently
        // wrong (e.g. `"a" < "b"` gave `false`, since ToNumber("a") is
        // NaN on both sides), not just the embedded-NUL edge case that
        // surfaced it (test262 test/language/types/string/S8.4_A5.js).
        // `std.mem.order` on the raw UTF-8 bytes matches UTF-16
        // code-unit order for every codepoint that doesn't need a
        // surrogate pair (BMP-only, the overwhelming common case) --
        // documented narrowing, same spirit as the bigint precision-loss
        // notes elsewhere in this file.
        .lt => if (left.isBigInt() and right.isBigInt())
            JSValue.fromBool(left.asBigInt().value.cmp(right.asBigInt().value) == .lt)
        else if (left.isString() and right.isString())
            JSValue.fromBool(std.mem.order(u8, left.asString().value.data, right.asString().value.data) == .lt)
        else
            JSValue.fromBool((try toNumber(left)) < (try toNumber(right))),
        .gt => if (left.isBigInt() and right.isBigInt())
            JSValue.fromBool(left.asBigInt().value.cmp(right.asBigInt().value) == .gt)
        else if (left.isString() and right.isString())
            JSValue.fromBool(std.mem.order(u8, left.asString().value.data, right.asString().value.data) == .gt)
        else
            JSValue.fromBool((try toNumber(left)) > (try toNumber(right))),
        .le => if (left.isBigInt() and right.isBigInt())
            JSValue.fromBool(left.asBigInt().value.cmp(right.asBigInt().value) != .gt)
        else if (left.isString() and right.isString())
            JSValue.fromBool(std.mem.order(u8, left.asString().value.data, right.asString().value.data) != .gt)
        else
            JSValue.fromBool((try toNumber(left)) <= (try toNumber(right))),
        .ge => if (left.isBigInt() and right.isBigInt())
            JSValue.fromBool(left.asBigInt().value.cmp(right.asBigInt().value) != .lt)
        else if (left.isString() and right.isString())
            JSValue.fromBool(std.mem.order(u8, left.asString().value.data, right.asString().value.data) != .lt)
        else
            JSValue.fromBool((try toNumber(left)) >= (try toNumber(right))),
        .eqeqeq => JSValue.fromBool(zvalue.equality.strictEquals(left, right)),
        .noteqeq => JSValue.fromBool(!zvalue.equality.strictEquals(left, right)),
        .eq => JSValue.fromBool(try looseEquals(allocator, left, right)),
        .ne => JSValue.fromBool(!try looseEquals(allocator, left, right)),
        .bitand => JSValue.fromNumber(@floatFromInt((try toInt32(left)) & (try toInt32(right)))),
        .bitor => JSValue.fromNumber(@floatFromInt((try toInt32(left)) | (try toInt32(right)))),
        .bitxor => JSValue.fromNumber(@floatFromInt((try toInt32(left)) ^ (try toInt32(right)))),
        // Shift counts are ToUint32(rhs) mod 32 per spec -- @truncate to u5
        // IS that mod. Left shifts run on the u32 bit pattern (Zig's `<<`
        // on a signed operand would be checked arithmetic, but JS wants
        // plain bit movement with silent wrap); `>>` on i32 is Zig's
        // arithmetic shift, exactly JS's `>>`.
        .shl => blk: {
            const l: u32 = @bitCast(try toInt32(left));
            const shift: u5 = @truncate(try toUint32(right));
            break :blk JSValue.fromNumber(@floatFromInt(@as(i32, @bitCast(l << shift))));
        },
        .shr => blk: {
            const l = try toInt32(left);
            const shift: u5 = @truncate(try toUint32(right));
            break :blk JSValue.fromNumber(@floatFromInt(l >> shift));
        },
        .ushr => blk: {
            const l = try toUint32(left);
            const shift: u5 = @truncate(try toUint32(right));
            break :blk JSValue.fromNumber(@floatFromInt(l >> shift));
        },
        // Always intercepted by the interpreter's own .binary arm (they
        // need the throw machinery and the prototype chain, which this
        // module doesn't have) -- never delegated here.
        .instanceof, .in => unreachable,
    };
}
