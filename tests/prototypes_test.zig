//! Real builtin prototype objects + the reflection layer over them:
//! Object.getPrototypeOf / getOwnPropertyDescriptor, method identity, and
//! the spec attributes of builtin methods. Node-verified.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "builtin methods are real own props of the prototype with spec attributes" {
    // writable:true, enumerable:false, configurable:true
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(Date.prototype, "getTime");
        \\console.log(d.writable, d.enumerable, d.configurable, typeof d.value);
    , "true false true function\n");
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(Array.prototype, "push");
        \\console.log(d.writable, d.enumerable, d.configurable);
    , "true false true\n");
}

test "getPrototypeOf resolves the real builtin prototypes" {
    try helpers.expectStdout("console.log(Object.getPrototypeOf([]) === Array.prototype);", "true\n");
    try helpers.expectStdout("console.log(Object.getPrototypeOf({}) === Object.prototype);", "true\n");
    try helpers.expectStdout("console.log(Object.getPrototypeOf('x') === String.prototype);", "true\n");
    try helpers.expectStdout("console.log(Object.getPrototypeOf(Object.prototype));", "null\n");
}

test "method identity holds across values (same function on the prototype)" {
    try helpers.expectStdout("console.log([].push === Array.prototype.push, 'a'.slice === String.prototype.slice);", "true true\n");
}

test "Object.create(null) inherits nothing" {
    try helpers.runAndCheck("typeof Object.create(null).hasOwnProperty === 'undefined';", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
}

test "getOwnPropertyDescriptor over functions (name/length/prototype/statics)" {
    // A static method is reported as an own property of the constructor.
    // (Its enumerable flag is currently true -- builtin statics ride the
    // property bag's default data descriptor; making them non-enumerable
    // like the spec is a separate follow-up.)
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(Date, "now");
        \\console.log(d.value === Date.now);
    , "true\n");
    // Function name/length carry the spec attributes (non-writable,
    // non-enumerable, configurable).
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(function foo(a, b) {}, "length");
        \\console.log(d.value, d.writable, d.enumerable, d.configurable);
    , "2 false false true\n");
}

test "builtin methods are non-enumerable (keys / for-in ignore them)" {
    try helpers.expectStdout("console.log(Object.keys({a:1,b:2}).join(','));", "a,b\n");
    try helpers.expectStdout(
        \\let s = []; for (const k in {a:1,b:2}) s.push(k); console.log(s.join(','));
    , "a,b\n");
}

test "hasOwnProperty over arrays and strings (indices + length)" {
    try helpers.expectStdout(
        \\console.log([1,2].hasOwnProperty('0'), [1,2].hasOwnProperty('5'), [1,2].hasOwnProperty('length'));
    , "true false true\n");
    try helpers.expectStdout("console.log('ab'.hasOwnProperty('1'), 'ab'.hasOwnProperty('2'));", "true false\n");
}

test "prototype.constructor round-trips and plain objects get Object.prototype" {
    try helpers.expectStdout("console.log(Date.prototype.constructor === Date, Array.prototype.constructor === Array);", "true true\n");
    try helpers.expectStdout("console.log(Object.prototype.hasOwnProperty.call({a:1}, 'a'));", "true\n");
}

test "string index access reads a one-char string" {
    try helpers.expectStdout("console.log('abc'[1], 'abc'[9]);", "b undefined\n");
}
