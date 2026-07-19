//! Function.prototype.call/apply/bind (pre-phase for Test262: the
//! harness's assert.js needs them). Node-verified.
const std = @import("std");
const helpers = @import("helpers.zig");

test "call: explicit this and arguments" {
    try helpers.expectNumber("function f(a, b) { return this.x + a + b; } f.call({x: 1}, 2, 3);", 6);
}

test "apply: this plus an arguments array (and native targets)" {
    try helpers.expectNumber("function f(a, b) { return this.x + a + b; } f.apply({x: 10}, [20, 30]);", 60);
    try helpers.expectNumber("Math.max.apply(null, [3, 7, 2]);", 7);
}

test "bind: fixed this, pre-applied args, name and length" {
    try helpers.expectStdout(
        \\function f(a, b) { return this.x + a + b; }
        \\const b = f.bind({x: 100}, 200);
        \\console.log(b(300), b.name, f.bind({}).length);
    , "600 bound f 2\n");
}

test "a bound function ignores its call-site this" {
    try helpers.expectNumber(
        \\function who() { return this.tag; }
        \\const bound = who.bind({tag: 5});
        \\const o = { tag: 9, m: bound };
        \\o.m();
    , 5);
}

test "detached-style usage the Test262 harness relies on" {
    try helpers.expectStdout(
        \\function toStr() { return 'clase:' + this.k; }
        \\console.log(toStr.call({k: 'obj'}));
    , "clase:obj\n");
}
