//! Hoisting, TDZ, and redeclaration checks (phase 11 -- closes Etapa B).
//! Every expected value/message cross-checked against real Node.js.
//! This engine is always-strict; "use strict" is an accepted no-op.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "var hoists to function/script scope as undefined (the headline fix)" {
    try helpers.expectStdout("console.log(x); var x = 1;", "undefined\n");
    try helpers.expectStdout("console.log(x); var x = 1; console.log(x);", "undefined\n1\n");
}

test "function declarations hoist fully: call-before-declaration and mutual recursion" {
    try helpers.expectNumber("function f() { return g(); } function g() { return 7; } f();", 7);
    try helpers.expectNumber("const r = f(); function f() { return 7; } r;", 7);
    // Inside a nested function body too.
    try helpers.expectNumber("function outer() { return inner(); function inner() { return 3; } } outer();", 3);
}

test "function declarations hoist within their own block only (no Annex B escape)" {
    try helpers.expectStdout("{ console.log(inner()); function inner() { return 'in'; } }", "in\n");
}

test "var escapes blocks and loop heads" {
    try helpers.expectNumber("if (true) { var y = 5; } y;", 5);
    try helpers.expectNumber("for (var i = 0; i < 3; i = i + 1) {} i;", 3);
    // for-of var: one shared binding, visible after the loop.
    try helpers.expectStdout("var acc = ''; for (var k of ['a', 'b']) { acc = acc + k; } console.log(acc, k);", "ab b\n");
}

test "var does not clobber a same-named parameter" {
    try helpers.expectNumber("function h(a) { var a; return a; } h(9);", 9);
}

test "TDZ: use before let/class initialization is the real ReferenceError" {
    try helpers.expectUncaught("zz; let zz = 1;", .reference_error, "Cannot access 'zz' before initialization");
    try helpers.expectUncaught("new C(); class C {}", .reference_error, "Cannot access 'C' before initialization");
    try helpers.expectUncaught("qq = 1; let qq;", .reference_error, "Cannot access 'qq' before initialization");
    // Catchable like any JS error.
    try helpers.expectStdout("try { zz; let zz = 1; } catch (e) { console.log(e.name); }", "ReferenceError\n");
}

test "TDZ shadowing: an inner dead let hides an initialized outer binding" {
    try helpers.expectUncaught("let w = 1; { w; let w = 2; }", .reference_error, "Cannot access 'w' before initialization");
}

test "typeof: TDZ throws, undeclared still gives 'undefined'" {
    try helpers.expectUncaught("typeof t1; let t1;", .reference_error, "Cannot access 't1' before initialization");
    try helpers.expectStdout("console.log(typeof nunca);", "undefined\n");
}

test "redeclaration in the same scope is the real SyntaxError" {
    try helpers.expectUncaught("let d1; let d1;", .syntax_error, "Identifier 'd1' has already been declared");
    try helpers.expectUncaught("let d2; var d2;", .syntax_error, "Identifier 'd2' has already been declared");
    try helpers.expectUncaught("const d3 = 1; let d3;", .syntax_error, "Identifier 'd3' has already been declared");
    try helpers.expectUncaught("let f2; function f2() {}", .syntax_error, "Identifier 'f2' has already been declared");
    try helpers.expectUncaught("class D {} class D {}", .syntax_error, "Identifier 'D' has already been declared");
}

test "legal redeclarations stay legal" {
    try helpers.expectNumber("var v1 = 1; var v1 = 2; v1;", 2);
    try helpers.expectNumber("function r() { return 1; } function r() { return 2; } r();", 2);
    // Same names in different scopes are fine.
    try helpers.expectNumber("let s = 1; { let s = 2; } s;", 1);
}

test "shadowing a builtin is legal (builtins are not script-scope lexical bindings)" {
    try helpers.expectNumber("let console = 5; console;", 5);
}

test "'use strict' is an accepted no-op" {
    try helpers.expectNumber("'use strict'; 1 + 1;", 2);
}

test "hoisted function closures still capture correctly" {
    // counter is hoisted above the var initializer in source order, but
    // both live in the same function scope -- the closure sees n.
    try helpers.expectNumber(
        \\function make() {
        \\  var n = 0;
        \\  return counter;
        \\  function counter() { n = n + 1; return n; }
        \\}
        \\const c = make();
        \\c(); c();
    , 2);
    // And a hoisted-but-unreached var initializer stays undefined: the
    // hoisted binding exists, its assignment never ran (Node: NaN).
    try helpers.expectStdout(
        \\function make() { return counter; function counter() { n = n + 1; return n; } var n = 0; }
        \\console.log(make()());
    , "NaN\n");
}
