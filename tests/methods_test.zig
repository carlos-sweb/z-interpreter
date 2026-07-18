//! Object-literal methods, getters, and setters at runtime. Every
//! expected value cross-checked against real Node.js. Known narrowing:
//! JSON.stringify sees accessors as undefined and omits them (real JS
//! invokes the getter) -- asserted below as our documented behavior.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "method shorthand: this-binding, name, typeof, not constructable" {
    try helpers.expectNumber("const o = { m() { return this.x; }, x: 5 }; o.m();", 5);
    try helpers.expectStdout("const o = { m() {} }; console.log(o.m.name, typeof o.m);", "m function\n");
    try helpers.expectStdout("const o = { m() {} }; try { new o.m(); } catch (e) { console.log(e.name); }", "TypeError\n");
}

test "getter: invoked per access with this = receiver" {
    try helpers.expectNumber("const g = { n: 0, get x() { this.n = this.n + 1; return this.n; } }; g.x; g.x; g.x;", 3);
}

test "get + set for the same key merge into one accessor" {
    try helpers.expectNumber("const gs = { _v: 0, get v() { return this._v; }, set v(x) { this._v = x * 2; } }; gs.v = 21; gs.v;", 42);
}

test "assigning through a getter-only accessor is a silent no-op (sloppy)" {
    try helpers.expectNumber("const go = { get x() { return 1; } }; go.x = 99; go.x;", 1);
}

test "setter-only accessor reads as undefined" {
    try helpers.expectStdout("const so = { set only(v) { this.got = v; } }; console.log(so.only); so.only = 8; console.log(so.got);", "undefined\n8\n");
}

test "accessors dispatch through the prototype chain with the instance as this" {
    try helpers.expectNumber("function F() {} F.prototype = { get seven() { return 7; } }; new F().seven;", 7);
    try helpers.expectNumber(
        \\function F(v) { this._v = v; }
        \\F.prototype = { get v() { return this._v; }, set v(x) { this._v = x + 1; } };
        \\const a = new F(1);
        \\a.v = 10;
        \\a.v;
    , 11);
}

test "computed method and accessor keys" {
    try helpers.expectNumber("const k = 'go'; const o = { [k]() { return 4; } }; o.go();", 4);
    try helpers.expectNumber("const o = { get ['c' + 'x']() { return 9; } }; o.cx;", 9);
}

test "destructuring and builtins invoke getters" {
    // bindPattern goes through getProperty, so getters fire for free.
    try helpers.expectNumber("const {x} = { get x() { return 3; } }; x;", 3);
    try helpers.expectStdout("console.log(Object.values({ get a() { return 1; }, b: 2 }).join(','));", "1,2\n");
    try helpers.expectStdout("console.log(Object.entries({ get a() { return 5; } })[0].join(':'));", "a:5\n");
}

test "for-in sees accessor keys" {
    try helpers.expectStdout("const keys = []; for (const k in { get a() {}, b: 1 }) keys.push(k); console.log(keys.join(','));", "a,b\n");
}

test "JSON.stringify omits accessors (documented narrowing -- real JS invokes getters)" {
    try helpers.expectStdout("console.log(JSON.stringify({ get a() { return 1; }, b: 2 }));", "{\"b\":2}\n");
}

test "methods calling sibling methods through this" {
    try helpers.expectNumber(
        \\const calc = {
        \\  total: 0,
        \\  add(n) { this.total = this.total + n; return this; },
        \\  double() { return this.add(this.total); },
        \\};
        \\calc.add(3).double().total;
    , 6);
}
