//! Roadmap item 18 (BigInt), phase 3: literal evaluation + typeof + GC
//! lifecycle + property/proto access. Arithmetic/coercion (phase 4) and
//! BigInt() global/prototype methods (phase 5) are NOT covered here yet
//! -- see the durable plan for the full 7-phase breakdown.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "a bigint literal evaluates to a real bigint value, typeof is \"bigint\"" {
    try helpers.runAndCheck("123456789012345678901234567890n;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .bigint);
        }
    }.check);
    try helpers.expectStdout("console.log(typeof 123n);", "bigint\n");
}

test "hex/octal/binary bigint literals and underscore separators parse correctly" {
    try helpers.expectStdout("console.log(typeof 0xFFn, typeof 0o17n, typeof 0b101n, typeof 1_000n);", "bigint bigint bigint bigint\n");
}

test "console.log renders a bigint with a trailing n; template-literal ToString does not" {
    try helpers.expectStdout("console.log(123n);", "123n\n");
    try helpers.expectStdout("console.log(`${123n}`);", "123\n");
}

test "BigInt.prototype.toString/toLocaleString/valueOf, matching Number's contract" {
    try helpers.expectStdout("console.log(255n.toString(16), (255n).toString(), 255n.toLocaleString());", "ff 255 255\n");
    try helpers.expectStdout("console.log((-255n).toString(16));", "-ff\n");
    try helpers.expectUncaught("(255n).toString(37);", .range_error, "toString() radix argument must be between 2 and 36");
    try helpers.expectStdout("console.log(5n.valueOf() === 5n, typeof 5n.valueOf());", "true bigint\n");
}

test "BigInt(value) coerces number/string/boolean/bigint, matching Node's exact error messages" {
    try helpers.expectStdout("console.log(BigInt(5), BigInt('10'), BigInt(true), BigInt(false), BigInt(5n));", "5n 10n 1n 0n 5n\n");
    try helpers.expectStdout("console.log(BigInt('  10  '), BigInt(''), BigInt('0x1F'));", "10n 0n 31n\n");
    try helpers.expectUncaught("BigInt(5.5);", .range_error, "The number 5.5 cannot be converted to a BigInt because it is not an integer");
    try helpers.expectUncaught("BigInt(NaN);", .range_error, "The number NaN cannot be converted to a BigInt because it is not an integer");
    try helpers.expectUncaught("BigInt('abc');", .syntax_error, "Cannot convert abc to a BigInt");
    try helpers.expectUncaught("BigInt(undefined);", .type_error, "Cannot convert undefined to a BigInt");
    try helpers.expectUncaught("BigInt(null);", .type_error, "Cannot convert null to a BigInt");
    try helpers.expectUncaught("BigInt();", .type_error, "Cannot convert undefined to a BigInt");
    try helpers.expectUncaught("new BigInt(5);", .type_error, "BigInt is not a constructor");
    try helpers.expectStdout("console.log(typeof BigInt, BigInt.prototype.constructor === BigInt);", "function true\n");
}

test "BigInt(hugeFloat) converts the float's exact value, beyond f64's 53-bit mantissa" {
    try helpers.expectStdout("console.log(BigInt(1e21));", "1000000000000000000000n\n");
}

test "BigInt.asIntN/asUintN wrap to a fixed-width two's-complement representation" {
    try helpers.expectStdout(
        \\console.log(BigInt.asIntN(8, 255n), BigInt.asUintN(8, -1n), BigInt.asIntN(8, 127n), BigInt.asIntN(8, 128n));
    , "-1n 255n 127n -128n\n");
    try helpers.expectUncaught("BigInt.asUintN(-1, 5n);", .range_error, "Invalid value: not (convertible to) a safe integer");
    try helpers.expectUncaught("BigInt.asUintN(8, 5);", .type_error, "Cannot convert 5 to a BigInt");
}

// Phase 4: arithmetic/bitwise mixing rules. Every value cross-checked
// against real Node (`node --input-type=module`), including the exact
// error messages/kinds.

test "same-type bigint arithmetic: add/sub/mul/div/mod/pow" {
    try helpers.expectStdout(
        \\console.log(1n + 2n, 5n - 8n, 3n * 4n, 7n / 2n, 7n % 2n, 2n ** 10n);
    , "3n -3n 12n 3n 1n 1024n\n");
}

test "division/remainder truncate toward zero (not floor), matching real JS BigInt" {
    try helpers.expectStdout("console.log(-7n / 2n, -7n % 2n, 7n / -2n, 7n % -2n);", "-3n -1n -3n 1n\n");
}

test "division by zero and a negative exponent are RangeErrors, not TypeErrors" {
    try helpers.expectUncaught("1n / 0n;", .range_error, "Division by zero");
    try helpers.expectUncaught("1n % 0n;", .range_error, "Division by zero");
    try helpers.expectUncaught("2n ** -1n;", .range_error, "Exponent must be positive");
}

test "mixing BigInt and Number in an arithmetic operator is a real TypeError, matching Node's exact message" {
    try helpers.expectUncaught("1n + 1;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
    try helpers.expectUncaught("1n - 1;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
    try helpers.expectUncaught("1n * 1;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
    try helpers.expectUncaught("1 / 1n;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
    try helpers.expectUncaught("1n % 1;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
    try helpers.expectUncaught("1n ** 1;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
    try helpers.expectUncaught("1n & 1;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
    try helpers.expectUncaught("1n + null;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
}

test "`+` with a string operand always concatenates, even mixed with bigint (bypasses the mixing check)" {
    // This test necessarily exercises `+`'s string-concat path, which
    // has a real, PRE-EXISTING, unrelated leak in this engine
    // (`binaryOp`'s `add` branch boxes its result via a raw
    // `JSValue.newString`, not a GC-tracked `gcNew*` -- same root cause
    // as operators_test.zig's already-baseline-leaky "string
    // concatenation via +"). Not fixable here without fixing that
    // pre-existing bug, which is out of scope for BigInt's own plan --
    // this test joins that same known-leaky baseline rather than being
    // rewritten to dodge the very behavior it's meant to verify.
    try helpers.expectStdout("console.log(1n + 'x', 'x' + 1n);", "1x x1\n");
}

test "same-type bigint bitwise: and/or/xor/not/shl/shr" {
    try helpers.expectStdout("console.log(5n & 3n, 5n | 2n, 5n ^ 1n, ~5n, 1n << 3n, 256n >> 4n);", "1n 7n 4n -6n 8n 16n\n");
}

test "a negative shift count flips direction, matching real JS BigInt" {
    try helpers.expectStdout("console.log(1n << -1n, 4n >> -1n);", "0n 8n\n");
}

test ">>> is a real TypeError for BigInt -- both same-type (specific message) and mixed (generic mixing message)" {
    try helpers.expectUncaught("1n >>> 1n;", .type_error, "BigInts have no unsigned right shift, use >> instead");
    try helpers.expectUncaught("1n >>> 1;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
    try helpers.expectUncaught("1 >>> 1n;", .type_error, "Cannot mix BigInt and other types, use explicit conversions");
}

test "relational and (in)equality operators allow mixing BigInt and Number/String/Boolean without throwing" {
    try helpers.expectStdout(
        \\console.log(1n < 2, 2n > 1, 1n <= 1, 1n >= 1n);
        \\console.log(1n == 1, 1n == '1', 1n == true, 0n == false, 1n == '1x', 1n == null);
        \\console.log(1n === 1, 1n !== 1, 1n === 1n);
    , "true true true true\ntrue true true true false false\nfalse true true\n");
}

test "unary minus negates a bigint; unary plus on a bigint is a real TypeError (unlike explicit Number())" {
    try helpers.expectStdout("console.log(-(5n), -(-5n), -(0n));", "-5n 5n 0n\n");
    try helpers.expectUncaught("+1n;", .type_error, "Cannot convert a BigInt value to a number");
    try helpers.expectStdout("console.log(Number(5n));", "5\n");
}

test "unary bitnot (~) on a bigint uses -(a+1), not a 32-bit flip" {
    try helpers.expectStdout("console.log(~0n, ~(-1n), ~123456789012345678901234567890n);", "-1n 0n -123456789012345678901234567891n\n");
}

test "prefix/postfix increment and decrement stay bigint, not Number" {
    try helpers.expectStdout(
        \\let a = 1n;
        \\console.log(a++, a, ++a, a);
        \\let b = 5n;
        \\console.log(b--, b, --b, b);
        \\console.log(typeof a, typeof b);
    , "1n 2n 3n 3n\n5n 4n 3n 3n\nbigint bigint\n");
}

test "both-bigint relational comparison is exact (no float precision loss)" {
    try helpers.expectStdout(
        \\const huge1 = 100000000000000000000000000000000000001n;
        \\const huge2 = 100000000000000000000000000000000000002n;
        \\console.log(huge1 < huge2, huge1 > huge2, huge1 === huge1);
    , "true false true\n");
}
