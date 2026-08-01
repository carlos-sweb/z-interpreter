//! Extended Array.prototype coverage + array index/length writes.
//! Node-verified (strict).
const std = @import("std");
const helpers = @import("helpers.zig");

test "concat with a mix of arrays, loose values, and a nested array (shallow)" {
    try helpers.expectStdout(
        "console.log(JSON.stringify([1, 2].concat(3, [4, 5], 6, [[7]])));",
        "[1,2,3,4,5,6,[7]]\n",
    );
    try helpers.expectStdout("console.log([].concat().length);", "0\n");
    try helpers.expectStdout("console.log([1].concat([2, 3]).length);", "3\n");
    try helpers.expectStdout("console.log([].concat([]).length);", "0\n");
}

test "concat retains a shared object independently per occurrence" {
    try helpers.expectStdout(
        \\const obj = { x: 1 };
        \\const merged = [obj].concat([obj], obj);
        \\merged[0].x = 99;
        \\console.log(merged[1].x, merged[2].x, merged.length);
    , "99 99 3\n");
}

test "index and length writes (the transversal gap)" {
    try helpers.expectStdout(
        \\const a = [1, 2, 3]; a[1] = 9; a[5] = 7; a[0] += 100;
        \\console.log(a.join(','), a.length);
        \\a.length = 2; console.log(a.join(','));
        \\const b = []; for (let i = 0; i < 3; i++) b[i] = i * i; console.log(b.join(','));
    , "101,9,3,,,7 6\n101,9\n0,1,4\n");
}

test "at, lastIndexOf, findIndex, findLast, findLastIndex" {
    try helpers.expectNumber("[10, 20, 30].at(-1);", 30);
    try helpers.expectNumber("[1, 2, 3, 2].lastIndexOf(2);", 3);
    try helpers.expectNumber("[5, 6, 7].findIndex(x => x === 6);", 1);
    try helpers.expectNumber("[1, 2, 3, 4].findLast(x => x % 2 === 0);", 4);
    try helpers.expectNumber("[1, 2, 3, 4].findLastIndex(x => x % 2 === 0);", 3);
}

test "reduceRight and flatMap" {
    try helpers.expectStdout("console.log([1, 2, 3].reduceRight((a, x) => a + x, ''));", "321\n");
    try helpers.expectStdout("console.log([1, 2, 3].flatMap(x => [x, x * 10]).join(','));", "1,10,2,20,3,30\n");
}

test "flat with depth" {
    try helpers.expectStdout("console.log([1, [2, [3, [4]]]].flat().join(','), [1, [2, [3]]].flat(2).join(','));", "1,2,3,4 1,2,3\n");
}

test "fill and copyWithin" {
    try helpers.expectStdout("console.log([1, 2, 3, 4, 5].fill(0, 1, 3).join(','));", "1,0,0,4,5\n");
    try helpers.expectStdout("console.log([1, 2, 3, 4, 5].copyWithin(0, 3).join(','));", "4,5,3,4,5\n");
}

test "copyWithin with negative indices" {
    try helpers.expectStdout("console.log([1, 2, 3, 4, 5].copyWithin(-2, 0).join(','));", "1,2,3,1,2\n");
    try helpers.expectStdout("console.log([1, 2, 3, 4, 5].copyWithin(0, -2).join(','));", "4,5,3,4,5\n");
}

test "copyWithin with overlapping source/destination ranges, both shift directions" {
    // target(1) is inside the source range [0,3) -- shifting right/down.
    try helpers.expectStdout("console.log([1, 2, 3, 4, 5].copyWithin(1, 0, 3).join(','));", "1,1,2,3,5\n");
    // target(0) is inside the source range [1,4) -- shifting left/up.
    try helpers.expectStdout("console.log([1, 2, 3, 4, 5].copyWithin(0, 1, 4).join(','));", "2,3,4,4,5\n");
    // target == start + 1, single-element overlap, worst case for an
    // interleaved release/retain implementation (Node-verified).
    try helpers.expectStdout("console.log([1, 2, 3].copyWithin(1, 0, 2).join(','));", "1,1,2\n");
}

test "copyWithin no-ops: empty range, target beyond bounds, target == start" {
    try helpers.expectStdout("console.log([1, 2, 3].copyWithin(0, 2, 1).join(','));", "1,2,3\n");
    try helpers.expectStdout("console.log([1, 2, 3].copyWithin(5, 0, 2).join(','));", "1,2,3\n");
    try helpers.expectStdout("console.log([1, 2, 3].copyWithin(1, 1, 2).join(','));", "1,2,3\n");
}

test "splice mutates in place and returns the removed elements" {
    try helpers.expectStdout(
        \\const s = [1, 2, 3, 4, 5];
        \\const rem = s.splice(1, 2, 'a', 'b', 'c');
        \\console.log(s.join(','), '|', rem.join(','));
    , "1,a,b,c,4,5 | 2,3\n");
}

test "sort: default lexicographic and with a numeric comparator" {
    try helpers.expectStdout(
        \\console.log([3, 1, 2].sort().join(','));
        \\console.log([10, 2, 1].sort().join(','));
        \\console.log([10, 2, 1].sort((a, b) => a - b).join(','));
        \\console.log([3, 1, 2].sort((a, b) => b - a).join(','));
    , "1,2,3\n1,10,2\n1,2,10\n3,2,1\n");
}

test "keys/values/entries iterators, and callbacks get the array arg" {
    try helpers.expectStdout("console.log([...['a', 'b'].keys()].join(','), [...['a', 'b'].values()].join(','));", "0,1 a,b\n");
    try helpers.expectStdout("console.log(JSON.stringify([...[10, 20].entries()]));", "[[0,10],[1,20]]\n");
    try helpers.expectStdout("console.log([1, 2, 3].map((x, i, arr) => x + i + arr.length).join(','));", "4,6,8\n");
}
