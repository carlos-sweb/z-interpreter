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
    return switch (v) {
        .@"undefined", .@"null" => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |box| box.value.data.len != 0,
        // Falsy only for 0n -- the one variant here that isn't
        // unconditionally true, matching real JS ToBoolean(BigInt).
        .bigint => |box| !box.value.isZero(),
        .array, .object, .regex, .symbol, .map, .set, .@"error", .function, .date, .promise, .proxy, .array_buffer, .data_view, .typed_array, .temporal => true,
    };
}

/// ECMA-262 ToNumber, narrowed to the primitives this phase's operators
/// need. Real ToPrimitive (valueOf/Symbol.toPrimitive) doesn't exist in
/// this ecosystem yet, so object-shaped values are `error.NotImplemented`.
pub fn toNumber(v: JSValue) !f64 {
    return switch (v) {
        .number => |n| n,
        .boolean => |b| if (b) @as(f64, 1) else @as(f64, 0),
        .@"undefined" => std.math.nan(f64),
        .@"null" => 0,
        // Real ToNumber(string) requires the *whole* (trimmed) string to be
        // a valid numeric literal, else NaN -- znumber's parseFloat is more
        // permissive (stops at trailing garbage). Narrowed/simplified for
        // this phase; not spec-exact.
        .string => |box| znumber.ParsingMethods.parseFloat(box.value.data),
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

/// ECMA-262 ToString, narrowed to what template literals and `+`'s
/// string-concat branch need. Caller owns the returned slice.
pub fn toDisplayString(allocator: Allocator, v: JSValue) ![]u8 {
    return switch (v) {
        .number => |n| try znumber.FormattingMethods.toString(n, allocator, null),
        .string => |box| try allocator.dupe(u8, box.value.data),
        .boolean => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .@"undefined" => try allocator.dupe(u8, "undefined"),
        .@"null" => try allocator.dupe(u8, "null"),
        // Array.prototype.toString's default behavior: comma-join each
        // element's own ToString (holes/null/undefined become "").
        .array => |box| {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            for (box.value.toSlice(), 0..) |item, i| {
                if (i != 0) try buf.append(allocator, ',');
                switch (item) {
                    .@"undefined", .@"null" => {},
                    else => {
                        const s = try toDisplayString(allocator, item);
                        defer allocator.free(s);
                        try buf.appendSlice(allocator, s);
                    },
                }
            }
            return buf.toOwnedSlice(allocator);
        },
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
/// mismatched tag is `error.NotImplemented` (needs real ToPrimitive).
fn looseEquals(allocator: Allocator, a: JSValue, b: JSValue) !bool {
    if (@as(std.meta.Tag(JSValue), a) == @as(std.meta.Tag(JSValue), b)) {
        return zvalue.equality.strictEquals(a, b);
    }
    if ((a == .@"undefined" or a == .@"null") and (b == .@"undefined" or b == .@"null")) return true;
    if (a == .@"undefined" or a == .@"null" or b == .@"undefined" or b == .@"null") return false;
    if (a == .boolean) return looseEquals(allocator, JSValue.fromNumber(try toNumber(a)), b);
    if (b == .boolean) return looseEquals(allocator, a, JSValue.fromNumber(try toNumber(b)));
    if (a == .number and b == .string) return a.number == try toNumber(b);
    if (a == .string and b == .number) return (try toNumber(a)) == b.number;
    // Real JS explicitly allows `==`/`!=` to mix BigInt with Number/
    // String (unlike the arithmetic operators, which throw) --
    // number mixing is narrowed to float comparison (documented
    // precision-loss narrowing, same as ToNumber(bigint) elsewhere in
    // this file); string mixing parses exact digit text (StringToBigInt
    // is integer-only, unlike the general numeric-string grammar), a
    // parse failure meaning "not equal", not an error.
    if (a == .bigint and b == .number) return bigintEqualsNumber(a.bigint.value, b.number);
    if (a == .number and b == .bigint) return bigintEqualsNumber(b.bigint.value, a.number);
    if (a == .bigint and b == .string) return try bigintEqualsString(allocator, a.bigint.value, b.string.value.data);
    if (a == .string and b == .bigint) return try bigintEqualsString(allocator, b.bigint.value, a.string.value.data);
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
        .mod => JSValue.fromNumber(@mod(try toNumber(left), try toNumber(right))),
        .pow => JSValue.fromNumber(std.math.pow(f64, try toNumber(left), try toNumber(right))),
        // Real JS allows `<`/`>`/`<=`/`>=` to mix BigInt and Number
        // without throwing. Both-bigint compares exactly (no precision
        // loss); a mixed pair falls back to the existing ToNumber path
        // (documented narrowing -- same precision-loss tradeoff as
        // ToNumber(bigint) elsewhere in this file).
        .lt => if (left == .bigint and right == .bigint)
            JSValue.fromBool(left.bigint.value.cmp(right.bigint.value) == .lt)
        else
            JSValue.fromBool((try toNumber(left)) < (try toNumber(right))),
        .gt => if (left == .bigint and right == .bigint)
            JSValue.fromBool(left.bigint.value.cmp(right.bigint.value) == .gt)
        else
            JSValue.fromBool((try toNumber(left)) > (try toNumber(right))),
        .le => if (left == .bigint and right == .bigint)
            JSValue.fromBool(left.bigint.value.cmp(right.bigint.value) != .gt)
        else
            JSValue.fromBool((try toNumber(left)) <= (try toNumber(right))),
        .ge => if (left == .bigint and right == .bigint)
            JSValue.fromBool(left.bigint.value.cmp(right.bigint.value) != .lt)
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
