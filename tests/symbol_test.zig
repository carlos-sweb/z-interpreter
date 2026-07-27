//! Symbol: the primitive, symbol-keyed properties, and Symbol.iterator
//! wired into the real iteration protocol. Node-verified (strict).
const std = @import("std");
const helpers = @import("helpers.zig");

test "symbols: uniqueness, typeof, description, toString, String()" {
    try helpers.expectStdout(
        \\const s = Symbol('x'), t = Symbol('x');
        \\console.log(s !== t, typeof s, s.description, s.toString(), String(s));
    , "true symbol x Symbol(x) Symbol(x)\n");
    try helpers.expectStdout("console.log(Symbol().description);", "undefined\n");
}

test "Symbol is not a constructor" {
    try helpers.expectUncaught("new Symbol();", .type_error, "Symbol is not a constructor");
}

test "Symbol.for / keyFor registry" {
    try helpers.expectStdout(
        \\console.log(Symbol.for('k') === Symbol.for('k'), Symbol.keyFor(Symbol.for('k')));
        \\console.log(Symbol.keyFor(Symbol('nope')));
    , "true k\nundefined\n");
}

test "symbol-keyed properties are invisible to string reflection" {
    try helpers.expectStdout(
        \\const s = Symbol('k');
        \\const o = { visible: 1 };
        \\o[s] = 42;
        \\console.log(o[s], Object.keys(o).join(','), JSON.stringify(o));
        \\const syms = Object.getOwnPropertySymbols(o);
        \\console.log(syms.length, syms[0] === s);
    , "42 visible {\"visible\":1}\n1 true\n");
}

test "distinct symbols are distinct keys; computed object-literal symbol keys" {
    try helpers.expectStdout(
        \\const a = Symbol(), b = Symbol();
        \\const o = { [a]: 'A', [b]: 'B' };
        \\console.log(o[a], o[b], Object.getOwnPropertySymbols(o).length);
    , "A B 2\n");
}

test "Symbol.iterator: user-defined iterables in for-of, spread, Array.from, destructuring" {
    const iterable =
        \\const it = { [Symbol.iterator]() { let i = 0; return { next: () => i < 3 ? {value: i++, done: false} : {value: undefined, done: true} }; } };
    ;
    try helpers.expectStdout(iterable ++ "\nconsole.log([...it].join(','));", "0,1,2\n");
    try helpers.expectStdout(iterable ++ "\nfor (const x of it) console.log(x);", "0\n1\n2\n");
    try helpers.expectStdout(iterable ++ "\nconsole.log(Array.from(it).join(','));", "0,1,2\n");
    try helpers.expectStdout(iterable ++ "\nconst [a, b] = it; console.log(a, b);", "0 1\n");
    try helpers.expectStdout(iterable ++ "\nconsole.log(Math.max(...it));", "2\n");
}

test "a generator is its own iterable via Symbol.iterator" {
    try helpers.expectStdout(
        \\function* g() { yield 1; yield 2; }
        \\const it = g();
        \\console.log(it[Symbol.iterator]() === it, [...g()].join(','));
    , "true 1,2\n");
}

test "Array.from over an array-like object (length + indices, no iterator)" {
    try helpers.expectStdout(
        \\console.log(Array.from({ length: 3, 0: 'a', 1: 'b', 2: 'c' }).join(','));
    , "a,b,c\n");
}

test "Array.from array-like: no length -> empty, string length coerces, negative/fractional clamp" {
    try helpers.expectStdout("console.log(Array.from({}).length);", "0\n");
    try helpers.expectStdout(
        \\console.log(Array.from({ length: '3', 0: 'a', 1: 'b', 2: 'c' }).join(','));
    , "a,b,c\n");
    try helpers.expectStdout("console.log(Array.from({ length: -1 }).length);", "0\n");
    try helpers.expectStdout(
        \\console.log(Array.from({ length: 2.9, 0: 5, 1: 6 }).join(','));
    , "5,6\n");
}

test "Array.from array-like: Symbol.iterator takes priority over length when both present" {
    try helpers.expectStdout(
        \\const weird = { length: 5, 0: 'x', [Symbol.iterator]() { let i = 0; return { next: () => i < 2 ? { value: i++ * 10, done: false } : { value: undefined, done: true } }; } };
        \\console.log(Array.from(weird).join(','));
    , "0,10\n");
}

test "Array.from over a bare next()-only object (no Symbol.iterator) is array-like, not drained as an iterator" {
    try helpers.expectStdout(
        \\const bareIter = { next() { return { value: 1, done: false }; } };
        \\console.log(Array.from(bareIter).length);
    , "0\n");
}

test "Array.prototype/Map.prototype/Set.prototype[Symbol.iterator] are real own properties aliasing values/entries" {
    try helpers.expectStdout(
        \\console.log(Array.prototype[Symbol.iterator] === Array.prototype.values);
        \\console.log(Map.prototype[Symbol.iterator] === Map.prototype.entries);
        \\console.log(Set.prototype[Symbol.iterator] === Set.prototype.values);
        \\const d = Object.getOwnPropertyDescriptor(Array.prototype, Symbol.iterator);
        \\console.log(d.writable, d.enumerable, d.configurable);
        \\console.log(Object.keys(Array.prototype).length, Object.getOwnPropertySymbols(Array.prototype).includes(Symbol.iterator));
        \\console.log(typeof [1, 2, 3][Symbol.iterator]().next);
    , "true\ntrue\ntrue\ntrue false true\n0 true\nfunction\n");
}

test "%TypedArray%.prototype[Symbol.iterator] === %TypedArray%.prototype.values, shared across kinds" {
    try helpers.expectStdout(
        \\const base = Object.getPrototypeOf(Int32Array.prototype);
        \\console.log(base[Symbol.iterator] === base.values);
        \\console.log(Object.getPrototypeOf(Float64Array.prototype)[Symbol.iterator] === base[Symbol.iterator]);
        \\const it = new Int32Array([1, 2, 3])[Symbol.iterator]();
        \\console.log(it.next().value, it.next().value, it.next().value, it.next().done);
    , "true\ntrue\n1 2 3 true\n");
}
