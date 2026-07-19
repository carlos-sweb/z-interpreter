//! The `arguments` object. Materialized as a real array snapshot
//! (always-strict => unmapped); the exotic Arguments object's tag /
//! Array.isArray===false / callee are documented narrowings. Behavior
//! cross-checked against Node in STRICT mode (the engine's mode).
const std = @import("std");
const helpers = @import("helpers.zig");

test "length, indexing, and iteration" {
    try helpers.expectNumber("function f() { return arguments.length; } f(1, 2, 3);", 3);
    try helpers.expectNumber("function f() { return arguments[0] + arguments[2]; } f(10, 20, 30);", 40);
    try helpers.expectStdout("function f() { for (const a of arguments) console.log(a); } f('x', 'y');", "x\ny\n");
    try helpers.expectStdout("function f() { return [...arguments].join(','); } console.log(f(1, 2, 3));", "1,2,3\n");
}

test "unmapped in strict mode: mutating a param does not change arguments" {
    try helpers.expectNumber("function f(a) { a = 9; return arguments[0]; } f(1);", 1);
}

test "arrows have no own arguments -- they inherit the enclosing function's" {
    try helpers.expectNumber("function f() { return (() => arguments[0])(); } f(7);", 7);
    try helpers.expectNumber("function f() { return (() => arguments.length)(); } f(1, 2, 3);", 3);
}

test "a parameter or rest named arguments shadows the object" {
    try helpers.expectNumber("function f(arguments) { return arguments; } f(5);", 5);
    try helpers.expectStdout("function f(...arguments) { return arguments.join('-'); } console.log(f(1, 2));", "1-2\n");
}

test "methods and constructors get their own arguments" {
    try helpers.expectNumber("const o = { m() { return arguments.length; } }; o.m(1, 2);", 2);
    try helpers.expectNumber("class C { constructor() { this.n = arguments.length; } } new C(1, 2, 3).n;", 3);
}

test "recursion: each frame has its own arguments" {
    try helpers.expectStdout(
        \\function f(n) { if (n === 0) return; console.log(arguments.length, arguments[0]); f(n - 1); }
        \\f(2);
    , "1 2\n1 1\n");
}

test "spread of arguments into another call, and Array.from" {
    try helpers.expectNumber("function f() { return Math.max(...arguments); } f(3, 9, 5);", 9);
    try helpers.expectNumber("function f() { return Array.from(arguments).length; } f(1, 2, 3, 4);", 4);
}

test "documented narrowing: arguments is a real array here (diverges from Node)" {
    // Real JS: Array.isArray(arguments) === false. Ours is true -- the
    // pragmatic array-snapshot representation. Asserted as OUR behavior.
    try helpers.expectStdout("function f() { console.log(Array.isArray(arguments)); } f();", "true\n");
}
