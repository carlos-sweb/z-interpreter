const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "basic bitwise binary operators" {
    try helpers.expectNumber("5 & 3;", 1);
    try helpers.expectNumber("5 | 3;", 7);
    try helpers.expectNumber("5 ^ 3;", 6);
}

test "bitwise not" {
    try helpers.expectNumber("~5;", -6);
    try helpers.expectNumber("~-1;", 0);
    try helpers.expectNumber("~~3.7;", 3); // the classic truncation idiom
}

test "shifts" {
    try helpers.expectNumber("1 << 4;", 16);
    try helpers.expectNumber("-8 >> 1;", -4); // arithmetic shift keeps the sign
    try helpers.expectNumber("-8 >>> 1;", 2147483644); // logical shift doesn't
}

test "32-bit wrapping edge cases (Node-verified)" {
    try helpers.expectNumber("1 << 31;", -2147483648);
    try helpers.expectNumber("-1 >>> 0;", 4294967295);
    try helpers.expectNumber("4294967296 | 0;", 0); // 2**32 wraps to 0
    try helpers.expectNumber("2147483648 | 0;", -2147483648); // 2**31 wraps negative
    try helpers.expectNumber("1 << 32;", 1); // shift count is mod 32
}

test "ToInt32 coercion: NaN, strings, truncation toward zero" {
    try helpers.expectNumber("NaN & 1;", 0);
    try helpers.expectNumber("'12' & '10';", 8);
    try helpers.expectNumber("3.7 | 0;", 3);
    try helpers.expectNumber("-3.7 | 0;", -3); // toward zero, NOT floor
    try helpers.expectNumber("null | 0;", 0);
    try helpers.expectNumber("true | 0;", 1);
}

test "compound bitwise assignment operators" {
    try helpers.expectNumber("let x = 5; x &= 3; x;", 1);
    try helpers.expectNumber("let x = 5; x |= 3; x;", 7);
    try helpers.expectNumber("let x = 5; x ^= 3; x;", 6);
    try helpers.expectNumber("let x = 1; x <<= 4; x;", 16);
    try helpers.expectNumber("let x = -8; x >>= 1; x;", -4);
    try helpers.expectNumber("let x = -8; x >>>= 1; x;", 2147483644);
}
