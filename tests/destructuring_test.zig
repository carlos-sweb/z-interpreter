//! Destructuring in binding positions (declarators, params, catch,
//! for-of/for-in declared bindings). Every expected value below was
//! cross-checked against real Node.js. Assignment-target destructuring
//! (`[a, b] = arr` without a declaration) is a separate, still-deferred
//! phase.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "array pattern: basic, holes, defaults, rest, nesting" {
    try helpers.expectNumber("const [a, b] = [1, 2]; a + b;", 3);
    try helpers.expectNumber("const [, x] = [1, 2]; x;", 2);
    try helpers.expectNumber("const [p = 5] = []; p;", 5);
    // default does NOT fire on a present non-undefined value
    try helpers.expectNumber("const [q = 5] = [7]; q;", 7);
    try helpers.expectNumber("const [h, ...t] = [1, 2, 3]; t.length * 10 + t[0];", 22);
    try helpers.expectNumber("const [[m], [n]] = [[7], [8]]; m + n;", 15);
    // a later default can reference an earlier binding (spec eval order)
    try helpers.expectNumber("const [j1 = 1, j2 = j1 * 2] = []; j1 * 10 + j2;", 12);
}

test "array pattern over a string destructures by code point" {
    try helpers.expectStdout("const [s1, s2] = 'hi'; console.log(s1, s2);", "h i\n");
    try helpers.expectStdout("const [d1 = 'z'] = 'y'; console.log(d1);", "y\n");
}

test "object pattern: shorthand, rename, defaults, nesting, rest" {
    try helpers.expectNumber("const {x, y} = {x: 1, y: 2}; x + y;", 3);
    try helpers.expectNumber("const {x: z} = {x: 9}; z;", 9);
    try helpers.expectNumber("const {w = 9} = {}; w;", 9);
    try helpers.expectNumber("const {a: {b}} = {a: {b: 42}}; b;", 42);
    try helpers.expectStdout("const {c, ...resto} = {c: 1, d: 2, e: 3}; console.log(Object.keys(resto).join(','));", "d,e\n");
    // getProperty reuse: string .length works as a destructuring source
    try helpers.expectNumber("const {length} = 'abc'; length;", 3);
}

test "object pattern default fires only on undefined, not null (Node-verified)" {
    try helpers.runAndCheck("const {q = 9} = {q: null}; q;", {}, struct {
        fn check(_: void, result: helpers.Result) !void {
            try testing.expect(result.value == .@"null");
        }
    }.check);
}

test "destructuring parameters" {
    try helpers.expectNumber("function f([u, v]) { return u * v; } f([3, 4]);", 12);
    try helpers.expectNumber("const g = ({x, y}) => x + y; g({x: 1, y: 2});", 3);
    // param-level default supplies {} so the pattern-level default fires
    try helpers.expectNumber("function h({k = 1} = {}) { return k; } h() * 10 + h({k: 5});", 15);
}

test "destructuring catch binding" {
    try helpers.expectNumber("var r; try { throw {code: 42}; } catch ({code}) { r = code; } r;", 42);
    // error objects destructure via getProperty (.message lives there)
    try helpers.expectStdout("try { null.x; } catch ({message}) { console.log(message); }", "Cannot read properties of null (reading 'x')\n");
}

test "destructuring for-of binding with Object.entries" {
    try helpers.expectStdout("for (const [k, v] of Object.entries({a: 1})) console.log(k, v);", "a 1\n");
    try helpers.expectStdout("for (const [k, v] of [[1, 2], [3, 4]]) console.log(k * v);", "2\n12\n");
}

test "iterating destructured bindings get a fresh env per iteration" {
    try helpers.expectStdout(
        \\const fns = [];
        \\for (const [n] of [[1], [2]]) fns.push(() => n);
        \\console.log(fns[0]() + fns[1]());
    , "3\n");
}

test "destructuring a non-iterable is a catchable TypeError" {
    // Message narrowed vs Node ("5 is not iterable"): ours reports the
    // type, matching for-of's existing message.
    try helpers.expectUncaught("const [e1] = 5;", .type_error, "number is not iterable");
    try helpers.expectStdout("try { const [e1] = 5; } catch (e) { console.log(e.name); }", "TypeError\n");
}

test "destructuring null/undefined with an object pattern is a catchable TypeError with Node's message" {
    try helpers.expectUncaught("const {m1} = null;", .type_error, "Cannot destructure property 'm1' of 'null' as it is null.");
    try helpers.expectUncaught("const {m1} = undefined;", .type_error, "Cannot destructure property 'm1' of 'undefined' as it is undefined.");
}
