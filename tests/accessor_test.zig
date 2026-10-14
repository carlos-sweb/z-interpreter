//! Builtin accessor properties (accessor_builtins.zig): real accessors on
//! their prototypes/constructors, with the spec's descriptors.
const std = @import("std");
const helpers = @import("helpers.zig");

test "Map/Set size, buffer and view lengths, Symbol description are prototype accessors" {
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(Map.prototype, 'size');
        \\console.log(typeof d.get, d.set, d.enumerable, d.configurable, d.get.name, d.get.length);
        \\const b = new ArrayBuffer(8), dv = new DataView(b, 2, 4), u = new Uint16Array(b, 2, 2);
        \\console.log(new Map([[1, 2]]).size, new Set([1, 2, 3]).size, b.byteLength, b.maxByteLength, b.resizable, b.detached);
        \\console.log(dv.buffer === b, dv.byteLength, dv.byteOffset, u.length, u.byteLength, u.byteOffset, u.buffer === b);
        \\console.log(Symbol('q').description, Symbol().description, new Map().hasOwnProperty('size'));
    , "function undefined false true get size 0\n1 3 8 8 false false\ntrue 4 2 2 4 2 true\nq undefined false\n");
}

test "an accessor on the wrong receiver is a TypeError" {
    try helpers.expectUncaught(
        "Object.getOwnPropertyDescriptor(Map.prototype, 'size').get.call(new Set());",
        .type_error,
        "Method get Map.prototype.size called on incompatible receiver",
    );
    try helpers.expectUncaught(
        "Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, 'byteLength').get.call(new SharedArrayBuffer(1));",
        .type_error,
        "Method get ArrayBuffer.prototype.byteLength called on incompatible receiver",
    );
}

test "a prototype accessor can be overridden" {
    try helpers.expectStdout(
        \\const o = Object.getOwnPropertyDescriptor(Map.prototype, 'size');
        \\Object.defineProperty(Map.prototype, 'size', { get() { return 99; }, configurable: true });
        \\const r = new Map().size; Object.defineProperty(Map.prototype, 'size', o);
        \\console.log(r, new Map().size);
    , "99 0\n");
}

test "get [Symbol.species] on Array, ArrayBuffer, Map, Set, Promise" {
    try helpers.expectStdout(
        \\console.log(['Array', 'ArrayBuffer', 'SharedArrayBuffer', 'Map', 'Set', 'Promise'].map(c => {
        \\  const d = Object.getOwnPropertyDescriptor(globalThis[c], Symbol.species);
        \\  return d.get.name + '/' + (globalThis[c][Symbol.species] === globalThis[c]);
        \\}).join(' '));
    , "get [Symbol.species]/true get [Symbol.species]/true get [Symbol.species]/true get [Symbol.species]/true get [Symbol.species]/true get [Symbol.species]/true\n");
}

test "Object.prototype.__proto__ (Annex B)" {
    try helpers.expectStdout(
        \\const p = { x: 1 }, o = {}; o.__proto__ = p;
        \\const q = {}; q.__proto__ = 5;
        \\console.log(({}).__proto__ === Object.prototype, [].__proto__ === Array.prototype, o.x, Object.keys(o).length, Object.getPrototypeOf(q) === Object.prototype);
    , "true true 1 0 true\n");
    try helpers.expectUncaught("const a = {}, b = Object.create(a); a.__proto__ = b;", .type_error, "Cyclic __proto__ value");
}

test "an array's own named property shadows the inherited one" {
    try helpers.expectStdout(
        \\const a = []; a.constructor = {};
        \\const b = [1]; Object.defineProperty(b, 'g', { get() { return this.length; } });
        \\console.log(a.constructor === Array, typeof a.constructor, b.g, [].constructor === Array);
    , "false object 1 true\n");
}
