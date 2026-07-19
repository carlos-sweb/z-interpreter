//! Map and Set with their JS API (constructors + methods + iteration).
//! Node-verified (strict).
const std = @import("std");
const helpers = @import("helpers.zig");

test "Map: construct from entries, get/has/size, chainable set, delete" {
    try helpers.expectStdout(
        \\const m = new Map([['a', 1], ['b', 2]]);
        \\console.log(m.size, m.get('a'), m.has('b'), m.get('z'));
        \\m.set('c', 3).set('d', 4);
        \\console.log(m.size, [...m.keys()].join(','), [...m.values()].join(','));
        \\console.log(m.delete('a'), m.delete('z'), m.size);
    , "2 1 true undefined\n4 a,b,c,d 1,2,3,4\ntrue false 3\n");
}

test "Map keys use SameValueZero (object identity, NaN)" {
    try helpers.expectStdout(
        \\const okey = {}; const m = new Map();
        \\m.set(okey, 'obj'); m.set(NaN, 'nan');
        \\console.log(m.get(okey), m.get(NaN), m.get({}));
    , "obj nan undefined\n");
}

test "Map: forEach order and entries iteration" {
    try helpers.expectStdout(
        \\const m = new Map([['a', 1], ['b', 2]]);
        \\const acc = []; m.forEach((v, k) => acc.push(k + '=' + v)); console.log(acc.join(','));
        \\console.log(JSON.stringify([...m.entries()]));
        \\for (const [k, v] of m) console.log(k, v);
    , "a=1,b=2\n[[\"a\",1],[\"b\",2]]\na 1\nb 2\n");
}

test "Set: uniqueness, has/delete/size, chainable add, iteration" {
    try helpers.expectStdout(
        \\const s = new Set([1, 2, 2, 3, 3, 3]);
        \\console.log(s.size, s.has(2), s.has(9), [...s].join(','));
        \\s.add(4).add(4);
        \\console.log(s.size, s.delete(1), s.size);
        \\const sv = []; s.forEach(v => sv.push(v)); console.log(sv.join(','));
        \\console.log(JSON.stringify([...s.entries()]));
    , "3 true false 1,2,3\n4 true 3\n2,3,4\n[[2,2],[3,3],[4,4]]\n");
}

test "Map/Set require new; spread and Array.from work" {
    try helpers.expectUncaught("Map();", .type_error, "Constructor Map requires 'new'");
    try helpers.expectUncaught("Set();", .type_error, "Constructor Set requires 'new'");
    try helpers.expectStdout("console.log(Array.from(new Set([3, 1, 2])).join(','));", "3,1,2\n");
    try helpers.expectNumber("Math.max(...new Set([5, 9, 2]));", 9);
}

test "clear empties the collection" {
    try helpers.expectStdout(
        \\const m = new Map([['a', 1]]); m.clear(); console.log(m.size);
        \\const s = new Set([1, 2]); s.clear(); console.log(s.size);
    , "0\n0\n");
}
