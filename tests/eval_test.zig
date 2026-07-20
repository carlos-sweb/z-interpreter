//! eval: direct (caller scope) and indirect (global scope), reusing the
//! parser + evalBody. Always-strict, so eval has its own scope. Node-verified.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "eval returns the completion value of the code" {
    try helpers.expectNumber("eval('1 + 2');", 3);
    try helpers.expectNumber("eval('var a = 1; a + 10');", 11);
    try helpers.expectNumber("eval('[1,2,3].reduce((a,b)=>a+b, 0)');", 6);
}

test "direct eval sees the caller's local scope" {
    try helpers.expectNumber("(function () { var x = 5; return eval('x + 1'); })();", 6);
}

test "indirect eval (aliased) runs, non-string arg is returned as-is" {
    try helpers.expectNumber("var e = eval; e('2 * 3');", 6);
    try helpers.expectNumber("eval(42);", 42);
}

test "a parse error in eval is a catchable SyntaxError" {
    try helpers.expectUncaught("eval('((');", .syntax_error, "Invalid or unexpected token in eval");
}

test "an exception thrown inside eval propagates" {
    try helpers.expectUncaught("eval('throw new TypeError(\"boom\")');", .type_error, "boom");
}
