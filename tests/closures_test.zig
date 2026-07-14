const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "a closure captures and mutates a variable across separate calls" {
    try helpers.expectNumber(
        \\function makeCounter() {
        \\  let n = 0;
        \\  return function() { n = n + 1; return n; };
        \\}
        \\const c = makeCounter();
        \\c(); c(); c();
    ,
        3,
    );
}

test "two independent closures from the same maker don't share state" {
    try helpers.expectNumber(
        \\function makeCounter() {
        \\  let n = 0;
        \\  return function() { n = n + 1; return n; };
        \\}
        \\const a = makeCounter();
        \\const b = makeCounter();
        \\a(); a(); b();
    ,
        1,
    );
}

test "this binding in a method call" {
    try helpers.expectNumber(
        "const obj = { n: 5, get: function() { return this.n; } }; obj.get();",
        5,
    );
}

test "arrow functions inherit `this` lexically, not from how they're called" {
    try helpers.expectNumber(
        \\const obj = {
        \\  n: 5,
        \\  makeGetter: function() { return () => this.n; }
        \\};
        \\const getter = obj.makeGetter();
        \\getter();
    ,
        5,
    );
}
