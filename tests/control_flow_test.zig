const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "if/else chains" {
    try helpers.expectNumber("if (true) { 1; } else { 2; }", 1);
    try helpers.expectNumber("if (false) { 1; } else { 2; }", 2);
    try helpers.expectNumber("if (false) { 1; } else if (true) { 2; } else { 3; }", 2);
}

test "while loop accumulating a sum" {
    try helpers.expectNumber(
        "let i = 0; let sum = 0; while (i < 5) { sum = sum + i; i = i + 1; } sum;",
        10,
    );
}

test "do-while runs at least once" {
    try helpers.expectNumber("let i = 0; do { i = i + 1; } while (false); i;", 1);
}

test "C-style for computing a factorial" {
    try helpers.expectNumber(
        "let result = 1; for (let i = 1; i <= 5; i = i + 1) { result = result * i; } result;",
        120,
    );
}

test "break exits the loop early" {
    try helpers.expectNumber(
        "let i = 0; for (;;) { if (i == 3) { break; } i = i + 1; } i;",
        3,
    );
}

test "continue skips the rest of the current iteration" {
    try helpers.expectNumber(
        "let sum = 0; for (let i = 0; i < 5; i = i + 1) { if (i == 2) { continue; } sum = sum + i; } sum;",
        8, // 0+1+3+4, 2 skipped
    );
}

