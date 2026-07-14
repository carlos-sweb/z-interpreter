const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "function declaration and call" {
    try helpers.expectNumber("function add(a, b) { return a + b; } add(2, 3);", 5);
}

test "function expression, named and anonymous" {
    try helpers.expectNumber("const f = function(a) { return a * 2; }; f(21);", 42);
}

test "arrow function, concise and block body" {
    try helpers.expectNumber("const f = a => a + 1; f(41);", 42);
    try helpers.expectNumber("const f = (a, b) => { return a * b; }; f(6, 7);", 42);
}

test "default parameters" {
    try helpers.expectNumber("function f(a, b = 10) { return a + b; } f(5);", 15);
    try helpers.expectNumber("function f(a, b = 10) { return a + b; } f(5, 2);", 7);
}

test "rest parameters collect the remainder into an array" {
    try helpers.expectNumber(
        "function f(a, ...rest) { return a + rest.length; } f(1, 2, 3, 4);",
        4, // a=1, rest=[2,3,4], length=3, 1+3
    );
}

test "recursion via a named function declaration" {
    try helpers.expectNumber(
        "function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); } fact(6);",
        720,
    );
}

test "recursion via a named function expression" {
    try helpers.expectNumber(
        "const fact = function f(n) { return n <= 1 ? 1 : n * f(n - 1); }; fact(6);",
        720,
    );
}

test "IIFE" {
    try helpers.expectNumber("(function(){ return 1 + 1; })();", 2);
    try helpers.expectNumber("(() => 1 + 1)();", 2);
}
