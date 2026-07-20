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
    // Builtin static methods are non-enumerable (writable, configurable).
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(Date, "now");
        \\console.log(d.value === Date.now, d.writable, d.enumerable, d.configurable);
    , "true true false true\n");
    // Function name/length carry the spec attributes (non-writable,
    // non-enumerable, configurable).
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(function foo(a, b) {}, "length");
        \\console.log(d.value, d.writable, d.enumerable, d.configurable);
    , "2 false false true\n");
}

test "builtin statics and constants are non-enumerable" {
    // Object.keys over constructors / namespaces sees no builtin statics.
    try helpers.expectStdout("console.log(Object.keys(Date).length, Object.keys(Math).length, Object.keys(Object).length);", "0 0 0\n");
    // Number's numeric constants are non-writable, non-enumerable, non-config.
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(Number, "MAX_SAFE_INTEGER");
        \\console.log(d.writable, d.enumerable, d.configurable, d.value);
    , "false false false 9007199254740991\n");
    // Well-known symbols on Symbol are non-enumerable too.
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(Symbol, "iterator");
        \\console.log(d.enumerable, d.writable, d.configurable);
    , "false false false\n");
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

test "Number.prototype methods" {
    try helpers.expectStdout("console.log((255).toString(16), (255).toString(2), (10).toString());", "ff 11111111 10\n");
    try helpers.expectStdout("console.log((3.14159).toFixed(2), (0).toFixed(0));", "3.14 0\n");
    try helpers.expectStdout("console.log((12345).toExponential(2));", "1.23e+4\n");
    try helpers.expectStdout("console.log((123.456).toPrecision(4));", "123.5\n");
    try helpers.expectNumber("(5).valueOf();", 5);
    try helpers.expectUncaught("(5).toString(37);", .range_error, "toString() radix must be between 2 and 36");
}

test "reflection over arrays and functions" {
    // defineProperty on an array (index / length) and a function (statics).
    try helpers.expectStdout("const a=[0,1]; Object.defineProperty(a,'2',{value:9}); console.log(a[2], a.length);", "9 3\n");
    try helpers.expectStdout("const b=[1,2,3]; Object.defineProperty(b,'length',{value:1}); console.log(b.length);", "1\n");
    try helpers.expectStdout("function f(){}; Object.defineProperty(f,'x',{value:7}); console.log(f.x, Object.getOwnPropertyDescriptor(f,'x').value);", "7 7\n");
    // getOwnPropertyNames over an array / function.
    try helpers.expectStdout("console.log(Object.getOwnPropertyNames([10,20]).join(','));", "0,1,length\n");
}

test "globalThis is backed by the global environment" {
    try helpers.expectStdout("console.log(typeof globalThis, globalThis.globalThis === globalThis);", "object true\n");
    try helpers.expectStdout("console.log(globalThis.Object === Object, globalThis.Math === Math);", "true true\n");
    // Reads a builtin global; writing creates a real global binding.
    try helpers.expectStdout("console.log(globalThis.parseInt('10'));", "10\n");
    try helpers.expectStdout("globalThis.gtx = 42; console.log(gtx, globalThis.gtx);", "42 42\n");
    // Object.prototype methods still resolve through the chain.
    try helpers.expectStdout("console.log(typeof globalThis.hasOwnProperty);", "function\n");
}

test "Object.is / hasOwn / fromEntries" {
    try helpers.expectStdout("console.log(Object.is(NaN,NaN), Object.is(0,-0), Object.is(2,2));", "true false true\n");
    try helpers.expectStdout("console.log(Object.hasOwn({a:1},'a'), Object.hasOwn({a:1},'b'), Object.hasOwn([9],'0'));", "true false true\n");
    try helpers.expectStdout("console.log(JSON.stringify(Object.fromEntries([['a',1],['b',2]])));", "{\"a\":1,\"b\":2}\n");
}

test "Boolean.prototype methods" {
    try helpers.expectStdout("console.log(true.toString(), false.toString());", "true false\n");
    try helpers.runAndCheck("true.valueOf();", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .boolean and r.value.boolean == true);
        }
    }.check);
}
