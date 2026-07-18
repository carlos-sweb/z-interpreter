//! Classes at runtime (ECMA-262 section 15.7, narrowed -- no fields,
//! no #private, no new.target). Every expected value cross-checked
//! against real Node.js.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "instantiation, methods, this, instanceof, typeof, name" {
    try helpers.expectStdout(
        \\class P { constructor(n) { this.n = n; } greet() { return 'hi ' + this.n; } }
        \\const p = new P('ana');
        \\console.log(p.greet(), p instanceof P, typeof P, P.name);
    , "hi ana true function P\n");
}

test "instance getters and setters" {
    try helpers.expectStdout(
        \\class C { get v() { return this._v || 7; } set v(x) { this._v = x * 2; } }
        \\const c = new C();
        \\console.log(c.v); c.v = 10; console.log(c.v);
    , "7\n20\n");
}

test "statics: methods, accessors, and setter dispatch" {
    try helpers.expectStdout(
        \\class S { static make() { return new S(); } static get tag() { return 'S!'; } }
        \\console.log(S.make() instanceof S, S.tag);
    , "true S!\n");
    try helpers.expectStdout(
        \\class G { static get x() { return 5; } static set x(v) { this._x = v; } }
        \\G.x = 3; console.log(G.x, G._x);
    , "5 3\n");
}

test "extends: super() in constructor, super.m(), method inheritance and override" {
    try helpers.expectStdout(
        \\class A { constructor(x) { this.x = x; } m() { return 'A:' + this.x; } static sa() { return 1; } }
        \\class B extends A { constructor(x) { super(x * 2); } m() { return 'B/' + super.m(); } }
        \\const b = new B(5);
        \\console.log(b.m(), b instanceof A, b instanceof B, B.sa());
    , "B/A:10 true true 1\n");
}

test "implicit derived constructor forwards this and args" {
    try helpers.expectStdout(
        \\class A { constructor(x) { this.x = x; } m() { return 'A:' + this.x; } }
        \\class D extends A {}
        \\const d = new D(9);
        \\console.log(d.x, d.m());
    , "9 A:9\n");
}

test "three-level chain: super through the middle class" {
    try helpers.expectStdout(
        \\class A { constructor(x) { this.x = x; } m() { return 'A:' + this.x; } }
        \\class B extends A { constructor(x) { super(x * 2); } m() { return 'B/' + super.m(); } }
        \\class E extends B { m() { return 'E>' + super.m(); } }
        \\console.log(new E(1).m());
    , "E>B/A:2\n");
}

test "class constructors cannot be invoked without new (Node message)" {
    try helpers.expectUncaught("class P {} P();", .type_error, "Class constructor P cannot be invoked without 'new'");
    try helpers.expectStdout("class P {} try { P(); } catch (e) { console.log(e.name); }", "TypeError\n");
}

test "extends a non-constructor is a TypeError (Node message)" {
    try helpers.expectUncaught("class Z extends 5 {}", .type_error, "Class extends value 5 is not a constructor or null");
}

test "class expressions: anonymous and named self-reference" {
    try helpers.expectStdout("const Anon = class { who() { return 'anon'; } }; console.log(new Anon().who());", "anon\n");
    try helpers.expectNumber(
        \\const Named = class NN { r(n) { return n <= 1 ? 1 : n * new NN().r(n - 1); } };
        \\new Named().r(4);
    , 24);
}

test "plain functions now take arbitrary properties (the property-bag gap is gone)" {
    try helpers.expectNumber("function f() {} f.myProp = 41; f.myProp + 1;", 42);
}

test "static inheritance through the bag chain" {
    try helpers.expectStdout(
        \\class A { static sa() { return 'sa'; } }
        \\class B extends A {}
        \\console.log(B.sa());
    , "sa\n");
}

test "methods are not constructable and prototype methods added later still resolve" {
    try helpers.expectStdout(
        \\class P { m() {} }
        \\try { new (new P().m)(); } catch (e) { console.log(e.name); }
    , "TypeError\n");
    try helpers.expectNumber(
        \\class P {}
        \\const p = new P();
        \\P.prototype.late = function () { return 6; };
        \\p.late();
    , 6);
}
