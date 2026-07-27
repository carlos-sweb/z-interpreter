//! Roadmap item 19, phase 2: TypedArray construction + integer-indexed
//! element access. `%TypedArray%.prototype`'s real method surface
//! (map/filter/forEach/slice/set/subarray/...) is a separate, not-yet-
//! started follow-up phase. Every value here was cross-checked against
//! real Node during development.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "new XArray(length) is zero-filled, .length/.byteLength/.byteOffset are real accessors" {
    try helpers.expectStdout(
        "const a = new Int32Array(3); console.log(a.length, a.byteLength, a.byteOffset, a[0]);",
        "3 12 0 0\n",
    );
}

test "new XArray(buffer, byteOffset, length) views an existing ArrayBuffer" {
    try helpers.expectStdout(
        \\const buf = new ArrayBuffer(16);
        \\const v = new Int16Array(buf, 4, 3);
        \\console.log(v.length, v.byteOffset, v.byteLength, v.buffer === buf);
    ,
        "3 4 6 true\n",
    );
}

test "new XArray(iterable) copies element VALUES, cross-kind included" {
    try helpers.expectStdout(
        \\console.log([...new Float64Array([1.5, 2.5, 3.5])]);
        \\console.log([...new Int32Array(new Uint8Array([1, 2, 3]))]);
        \\console.log([...new Uint8Array(new Set([9, 8, 7]))]);
    ,
        "[1.5, 2.5, 3.5]\n[1, 2, 3]\n[9, 8, 7]\n",
    );
}

test "new XArray(arrayLike) -- non-iterable array-like construction (no Symbol.iterator)" {
    try helpers.expectStdout(
        \\console.log([...new Int32Array({ length: 3, 0: 1, 1: 2, 2: 3 })]);
        \\console.log(new Int32Array({}).length);
        \\console.log(new Int32Array({ length: '3', 0: 1, 1: 2, 2: 3 }).length);
        \\console.log(new Int32Array({ length: -1 }).length);
        \\console.log(new Int32Array({ length: 2.9, 0: 5, 1: 6 }).length);
    ,
        "[1, 2, 3]\n0\n3\n0\n2\n",
    );
}

test "new XArray(arrayLike): Symbol.iterator takes priority over length when both present" {
    try helpers.expectStdout(
        \\const weird = { length: 5, 0: 'x', [Symbol.iterator]() { let i = 0; return { next: () => i < 2 ? { value: i++ * 10, done: false } : { value: undefined, done: true } }; } };
        \\console.log([...new Int32Array(weird)]);
    ,
        "[0, 10]\n",
    );
}

test "reading out of range is undefined, writing out of range is a silent no-op (real spec, not a throw)" {
    try helpers.expectStdout(
        \\const t = new Int8Array(2);
        \\t[100] = 5;
        \\console.log(t[100], t.length);
    ,
        "undefined 2\n",
    );
}

test "Int8/Uint8/Int16/Uint16 wrap modulo 2^n (no clamping) -- Uint8Array" {
    try helpers.expectStdout("console.log([...new Uint8Array([1, 2, 300])]);", "[1, 2, 44]\n");
}

test "Uint8ClampedArray clamps [0,255] with round-half-to-even at the boundary" {
    try helpers.expectStdout(
        \\const c = new Uint8ClampedArray(4);
        \\c[0] = 2.5; c[1] = 3.5; c[2] = 300; c[3] = -10;
        \\console.log([...c]);
    ,
        "[2, 4, 255, 0]\n",
    );
}

test "BigInt64Array/BigUint64Array round-trip via iterable construction; a non-BigInt write throws" {
    try helpers.expectStdout(
        "console.log([...new BigInt64Array([1n, -1n, 9223372036854775807n])]);",
        "[1n, -1n, 9223372036854775807n]\n",
    );
    try helpers.expectUncaught(
        "const b = new BigInt64Array(1); b[0] = 5;",
        .type_error,
        "Cannot convert 5 to a BigInt",
    );
}

test "instanceof and getPrototypeOf identity, including the shared %TypedArray%.prototype base" {
    try helpers.expectStdout(
        \\const a = new Int32Array(3);
        \\console.log(a instanceof Int32Array, a instanceof Float64Array);
        \\console.log(Object.getPrototypeOf(a) === Int32Array.prototype);
        \\const c = new Uint8ClampedArray(1);
        \\console.log(c instanceof Uint8ClampedArray, c instanceof Uint8Array);
        \\console.log(Object.getPrototypeOf(Int32Array.prototype) === Object.getPrototypeOf(Float64Array.prototype));
    ,
        "true false\ntrue\ntrue false\ntrue\n",
    );
}

test "constructors reject a bare non-'new' call" {
    try helpers.expectUncaught("Int32Array(3);", .type_error, "Constructor Int32Array requires 'new'");
}

test "a misaligned byteOffset is a RangeError" {
    try helpers.expectUncaught("new Int32Array(new ArrayBuffer(8), 1);", .range_error, "byte_offset is not a multiple of the element size");
}

test "auto-length view over a buffer that doesn't divide evenly is a RangeError, not a silent truncation" {
    try helpers.expectUncaught("new Int32Array(new ArrayBuffer(6));", .range_error, "Offset is outside the bounds of the buffer");
}
