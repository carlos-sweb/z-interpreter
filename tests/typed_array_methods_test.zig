//! Roadmap item 19, phase 3: `%TypedArray%.prototype`'s real method
//! surface (map/filter/forEach/slice/set/subarray/copyWithin/sort/join/
//! indexOf/iterators/...), installed once on the shared, non-exposed
//! `%TypedArray%.prototype` base every concrete `XArray.prototype` chains
//! to. Every value here was cross-checked against real Node.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "map/filter return a new TypedArray of the SAME concrete kind, not a plain array" {
    try helpers.expectStdout(
        \\const a = new Int32Array([5, 3, 8, 1]);
        \\const m = a.map(x => x * 2);
        \\console.log([...m], m instanceof Int32Array);
        \\const f = a.filter(x => x > 3);
        \\console.log([...f], f instanceof Int32Array, f.length);
    ,
        "[10, 6, 16, 2] true\n[5, 8] true 2\n",
    );
}

test "forEach/find/findIndex/findLast/findLastIndex/some/every visit every index, no holes" {
    try helpers.expectStdout(
        \\const a = new Int32Array([5, 3, 8, 1]);
        \\let seen = [];
        \\a.forEach((v, i) => seen.push(v + ':' + i));
        \\console.log(seen.join(','));
        \\console.log(a.find(x => x > 3), a.findIndex(x => x > 3));
        \\console.log(a.findLast(x => x > 3), a.findLastIndex(x => x > 3));
        \\console.log(a.some(x => x > 7), a.every(x => x > 0), a.every(x => x > 4));
    ,
        "5:0,3:1,8:2,1:3\n5 0\n8 2\ntrue true false\n",
    );
}

test "reduce/reduceRight with and without an initial value; empty+no-initial throws" {
    try helpers.expectStdout(
        \\const a = new Int32Array([1, 2, 3, 4]);
        \\console.log(a.reduce((acc, x) => acc + x, 0));
        \\console.log(a.reduce((acc, x) => acc + x));
        \\console.log(a.reduceRight((acc, x) => acc + '-' + x));
    ,
        "10\n10\n4-3-2-1\n",
    );
    try helpers.expectUncaught("new Int32Array(0).reduce((a, b) => a + b);", .type_error, "Reduce of empty array with no initial value");
}

test "indexOf uses strict equality (NaN never found), includes uses SameValueZero (NaN found)" {
    try helpers.expectStdout(
        \\const a = new Float64Array([1, NaN, 3]);
        \\console.log(a.indexOf(NaN), a.includes(NaN));
        \\const b = new Int32Array([1, 2, 3, 2]);
        \\console.log(b.indexOf(2), b.lastIndexOf(2));
    ,
        "-1 true\n1 3\n",
    );
}

test "join/toString/at" {
    try helpers.expectStdout(
        \\const a = new Int32Array([1, 2, 3]);
        \\console.log(a.join('-'), a.toString(), a.join());
        \\console.log(a.at(-1), a.at(0), a.at(99));
    ,
        "1-2-3 1,2,3 1,2,3\n3 1 undefined\n",
    );
}

test "fill/copyWithin/reverse mutate in place and return the same instance" {
    try helpers.expectStdout(
        \\const a = new Int32Array([1, 2, 3, 4, 5]);
        \\const r1 = a.fill(0, 1, 3);
        \\console.log([...a], r1 === a);
        \\const b = new Int32Array([10, 20, 30, 40, 50]);
        \\b.copyWithin(0, 3);
        \\console.log([...b]);
        \\const c = new Int32Array([1, 2, 3]);
        \\c.reverse();
        \\console.log([...c]);
    ,
        "[1, 0, 0, 4, 5] true\n[40, 50, 30, 40, 50]\n[3, 2, 1]\n",
    );
}

test "sort defaults to NUMERIC ascending (not string order) with NaN always last; a custom comparator works" {
    try helpers.expectStdout(
        \\console.log([...new Int32Array([10, 2, 33, 4]).sort()]);
        \\console.log([...new Float64Array([3, NaN, 1, 2]).sort()]);
        \\console.log([...new Int32Array([5, 3, 1, 4, 2]).sort((a, b) => b - a)]);
        \\console.log([...new BigInt64Array([3n, 1n, 2n]).sort()]);
    ,
        "[2, 4, 10, 33]\n[1, 2, 3, NaN]\n[5, 4, 3, 2, 1]\n[1n, 2n, 3n]\n",
    );
    try helpers.expectUncaught("new Int32Array(1).sort(5);", .type_error, "The comparison function must be either a function or undefined");
}

test "subarray shares the SAME buffer (a view); slice copies into a NEW one" {
    try helpers.expectStdout(
        \\const c = new Int32Array([1, 2, 3, 4, 5]);
        \\const s = c.subarray(1, 3);
        \\s[0] = 99;
        \\console.log([...c], [...s], s.buffer === c.buffer);
        \\const sl = c.slice(1, 3);
        \\sl[0] = -1;
        \\console.log([...c], [...sl], sl.buffer === c.buffer);
        \\console.log([...c.subarray(-2)]);
        \\console.log([...c.subarray(1, 100)]);
    ,
        "[1, 99, 3, 4, 5] [99, 3] true\n[1, 99, 3, 4, 5] [-1, 3] false\n[4, 5]\n[99, 3, 4, 5]\n",
    );
}

test "set copies element VALUES from another typed array (cross-kind) or a plain array, at an offset; RangeErrors on bad fit" {
    try helpers.expectStdout(
        \\const d = new Int32Array(5);
        \\d.set([7, 8, 9], 1);
        \\console.log([...d]);
        \\const e = new Int32Array(3);
        \\e.set(new Uint8Array([1, 2, 3]));
        \\console.log([...e]);
        \\// Overlapping same-buffer set must not corrupt the source read.
        \\const f = new Int32Array([1, 2, 3, 4, 5]);
        \\f.set(f.subarray(0, 3), 1);
        \\console.log([...f]);
    ,
        "[0, 7, 8, 9, 0]\n[1, 2, 3]\n[1, 1, 2, 3, 5]\n",
    );
    try helpers.expectUncaught("new Int32Array(3).set([1, 2, 3, 4]);", .range_error, "Source is too large");
    try helpers.expectUncaught("new Int32Array(3).set([1], -1);", .range_error, "Offset is out of bounds");
    try helpers.expectUncaught("new Int32Array(3).set([1], 4);", .range_error, "Offset is out of bounds");
}

test "keys/values/entries are real iterators" {
    try helpers.expectStdout(
        \\const a = new Int32Array([10, 20, 30]);
        \\console.log([...a.keys()]);
        \\console.log([...a.values()]);
        \\console.log([...a.entries()].map(p => JSON.stringify(p)));
        \\const it = a.values();
        \\console.log(it.next().value, it.next().value, it.next().done);
    ,
        "[0, 1, 2]\n[10, 20, 30]\n[[0,10], [1,20], [2,30]]\n10 20 false\n",
    );
}

test "Uint8ClampedArray fill/copyWithin/sort go through the SAME clamped coercion as indexed writes" {
    try helpers.expectStdout(
        \\const c = new Uint8ClampedArray([1, 2, 3, 4]);
        \\c.fill(300, 0, 2);
        \\console.log([...c]);
        \\c.copyWithin(2, 0, 2);
        \\console.log([...c]);
    ,
        "[255, 255, 3, 4]\n[255, 255, 255, 255]\n",
    );
}

test "BYTES_PER_ELEMENT is a real per-kind own property on the concrete prototype (not shared)" {
    try helpers.expectStdout(
        \\console.log(Int8Array.prototype.BYTES_PER_ELEMENT, Int32Array.prototype.BYTES_PER_ELEMENT, Float64Array.prototype.BYTES_PER_ELEMENT);
        \\console.log(Int32Array.prototype.hasOwnProperty('BYTES_PER_ELEMENT'), Int32Array.prototype.hasOwnProperty('map'));
    ,
        "1 4 8\ntrue false\n",
    );
}

test "the method surface lives ONCE on the shared %TypedArray%.prototype base, identical across kinds" {
    try helpers.expectStdout(
        \\console.log(Int32Array.prototype.map === Float64Array.prototype.map);
        \\console.log(Object.getPrototypeOf(Int32Array.prototype).hasOwnProperty('map'));
        \\console.log(typeof Int32Array.prototype.set, typeof Int32Array.prototype.subarray);
    ,
        "true\ntrue\nfunction function\n",
    );
}

test "methods reject a non-TypedArray receiver" {
    try helpers.expectUncaught("Int32Array.prototype.map.call([1, 2], x => x);", .type_error, "Method TypedArray.prototype.map called on incompatible receiver");
}
