const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const zparser = @import("zparser");
const JSValue = zvalue.JSValue;

/// ECMA-262 ToBoolean. Arrays/objects/functions are truthy even when
/// empty -- the real JS quirk, not a bug.
pub fn isTruthy(v: JSValue) bool {
    return switch (v) {
        .@"undefined", .@"null" => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |box| box.value.data.len != 0,
        .array, .object, .regex, .symbol, .map, .set, .@"error", .function => true,
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
        .array, .object, .regex, .symbol, .map, .set, .@"error", .function => error.NotImplemented,
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
        .object, .regex, .symbol, .map, .set, .@"error", .function => error.NotImplemented,
    };
}

/// ECMA-262 Strict Equality plus a narrowed Abstract Equality Comparison
/// (`==`/`!=`) -- only the primitive-coercion cases; any comparison
/// involving a non-null/undefined array/object/function/etc. against a
/// mismatched tag is `error.NotImplemented` (needs real ToPrimitive).
fn looseEquals(a: JSValue, b: JSValue) !bool {
    if (@as(std.meta.Tag(JSValue), a) == @as(std.meta.Tag(JSValue), b)) {
        return zvalue.equality.strictEquals(a, b);
    }
    if ((a == .@"undefined" or a == .@"null") and (b == .@"undefined" or b == .@"null")) return true;
    if (a == .@"undefined" or a == .@"null" or b == .@"undefined" or b == .@"null") return false;
    if (a == .boolean) return looseEquals(JSValue.fromNumber(try toNumber(a)), b);
    if (b == .boolean) return looseEquals(a, JSValue.fromNumber(try toNumber(b)));
    if (a == .number and b == .string) return a.number == try toNumber(b);
    if (a == .string and b == .number) return (try toNumber(a)) == b.number;
    return error.NotImplemented;
}

/// Evaluates every non-short-circuiting BinaryOp. `&&`/`||`/`??` and their
/// compound-assignment forms are short-circuiting and live in the
/// interpreter's own expression evaluator instead, since they must not
/// eagerly evaluate the right operand.
pub fn binaryOp(allocator: Allocator, op: zparser.BinaryOp, left: JSValue, right: JSValue) !JSValue {
    return switch (op) {
        .add => blk: {
            if (left == .string or right == .string) {
                const ls = try toDisplayString(allocator, left);
                defer allocator.free(ls);
                const rs = try toDisplayString(allocator, right);
                defer allocator.free(rs);
                const joined = try std.mem.concat(allocator, u8, &.{ ls, rs });
                defer allocator.free(joined);
                break :blk try JSValue.newString(allocator, joined);
            }
            break :blk JSValue.fromNumber((try toNumber(left)) + (try toNumber(right)));
        },
        .sub => JSValue.fromNumber((try toNumber(left)) - (try toNumber(right))),
        .mul => JSValue.fromNumber((try toNumber(left)) * (try toNumber(right))),
        .div => JSValue.fromNumber((try toNumber(left)) / (try toNumber(right))),
        .mod => JSValue.fromNumber(@mod(try toNumber(left), try toNumber(right))),
        .pow => JSValue.fromNumber(std.math.pow(f64, try toNumber(left), try toNumber(right))),
        .lt => JSValue.fromBool((try toNumber(left)) < (try toNumber(right))),
        .gt => JSValue.fromBool((try toNumber(left)) > (try toNumber(right))),
        .le => JSValue.fromBool((try toNumber(left)) <= (try toNumber(right))),
        .ge => JSValue.fromBool((try toNumber(left)) >= (try toNumber(right))),
        .eqeqeq => JSValue.fromBool(zvalue.equality.strictEquals(left, right)),
        .noteqeq => JSValue.fromBool(!zvalue.equality.strictEquals(left, right)),
        .eq => JSValue.fromBool(try looseEquals(left, right)),
        .ne => JSValue.fromBool(!try looseEquals(left, right)),
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
        .instanceof, .in => error.NotImplemented,
    };
}
