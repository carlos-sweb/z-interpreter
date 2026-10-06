//! White-box refcount checks for the Phase-1 GC prep (roadmap item 15):
//! object-property overwrite/delete, Map set/delete, and variable
//! reassignment must release the value they displace, not leak it.
//!
//! Baseline these tests build on: after `let probe = <fresh value>; ...;
//! probe;` the box is at refcount 2 -- probe's binding, plus the script's
//! completion value (the final `probe;`), which the run hands back to the
//! test as an owned reference. Every test below starts from that baseline
//! and checks the DELTA an overwrite/delete/reassign should apply on top
//! of it, rather than asserting an absolute count in isolation.
const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const helpers = @import("helpers.zig");

fn expectObjectRefcount(source: []const u8, expected: usize) !void {
    try helpers.runAndCheck(source, expected, struct {
        fn check(want: usize, result: helpers.Result) !void {
            try testing.expect(result.value == .object);
            try testing.expectEqual(want, result.value.object.refCount());
        }
    }.check);
}

test "plain object declaration baseline is refcount 2 (documented quirk)" {
    try expectObjectRefcount("let probe = {}; probe;", 2);
}

test "overwriting an object property releases the value it displaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let obj = {};
        \\obj.a = probe; // +1 (property), now 3
        \\obj.a = {};    // displaces probe -- should release back to 2
        \\probe;
    , 2);
}

test "deleting an object property releases the deleted value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let obj = {};
        \\obj.a = probe; // +1 (property), now 3
        \\delete obj.a;  // should release back to 2
        \\probe;
    , 2);
}

test "Map.set on an existing key releases the displaced value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set('k', probe); // +1 (map value), now 3
        \\m.set('k', {});    // displaces probe -- should release back to 2
        \\probe;
    , 2);
}

test "Map.set on an existing key does not re-retain the key (put() leaves it in place)" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set(probe, 1); // new key -- +1 (map key), now 3
        \\m.set(probe, 2); // same key -- must NOT retain again, stays 3
        \\probe;
    , 3);
}

test "Map.delete releases the deleted value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set('k', probe); // +1 (map value), now 3
        \\m.delete('k');     // should release back to 2
        \\probe;
    , 2);
}

test "reassigning a variable releases the value it held" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let x = probe; // +1 (x's binding), now 3
        \\x = {};         // displaces probe from x -- should release back to 2
        \\probe;
    , 2);
}

test "copyWithin (non-overlapping) releases the old destination occupant and retains the new one" {
    // dest [2,4) and source [0,2) are disjoint -- the baseline sanity
    // check before the overlap tests below.
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA); // idx0, idx1
        \\arr.push(probeB); arr.push(probeB); // idx2, idx3
        \\arr.copyWithin(2, 0, 2); // dest [2,4) <- source [0,2): now all 4 slots hold A
        \\probeA; // occupies all 4 slots now: 2(baseline)+4 = 6
    , 6);
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA);
        \\arr.push(probeB); arr.push(probeB);
        \\arr.copyWithin(2, 0, 2);
        \\probeB; // no longer occupies any slot: back to the bare baseline, 2
    , 2);
}

test "copyWithin (overlapping, target inside the source range) still balances retain/release per slot" {
    // The exact shape a naive per-slot-interleaved release/retain would
    // get wrong: target(1) falls INSIDE source [0,2), so slot 1 is both
    // "still-unread source data" and "about to be overwritten
    // destination" at once. See the ordering comment on arrayCopyWithin
    // in array_builtins.zig.
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA); // idx0, idx1
        \\arr.push(probeB); arr.push(probeB); // idx2, idx3
        \\arr.copyWithin(1, 0, 2); // dest [1,3) <- source [0,2): idx1 stays A, idx2 becomes A (was B)
        \\probeA; // now occupies 3 slots instead of 2: 2(baseline)+3 = 5
    , 5);
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA);
        \\arr.push(probeB); arr.push(probeB);
        \\arr.copyWithin(1, 0, 2);
        \\probeB; // now occupies 1 slot instead of 2: 2(baseline)+1 = 3
    , 3);
}

test "concat retains each element once per occurrence in the merged result" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let arr = [probe];       // array-literal element -- +1, now 3
        \\const merged = arr.concat(probe, [probe]);
        \\// The `[probe]` argument is its OWN array-literal construction
        \\// (+1 while the call runs), released with the other arguments
        \\// once concat() returns. concat() builds a brand new array with
        \\// 3 elements (arr's own probe, the loose probe, and the [probe]
        \\// arg's probe), each retained once as it's copied into that new
        \\// result -- +3 (now 6). arr's own element is retained AGAIN here
        \\// because concat() returns an independent shallow copy, not a
        \\// view onto arr.
        \\probe;
    , 6);
}

// ---- Call arguments, array literals and declarations ------------------
// Each of these used to keep one extra reference per evaluation: call
// arguments were never released after the call, an array literal
// retained an element it already owned, and a declaration retained its
// initializer's result on top of the binding's own reference.

test "call arguments are released after a JS function call" {
    // What remains is the callee's own: each parameter binding and each
    // `arguments` element holds one reference, and call environments are
    // not freed yet (a separate, known gap) -- f(probe, probe) keeps 2 + 2,
    // f(probe) keeps 1 + 1. The caller's own references (3 here) are gone.
    try expectObjectRefcount(
        \\let probe = {};
        \\function f(a, b) { return 0; }
        \\f(probe, probe); f(probe);
        \\probe;
    , 8);
}

test "call arguments are released after a native call and a constructor" {
    try expectObjectRefcount(
        \\let probe = {};
        \\Object.keys(probe); Object.is(probe, probe);
        \\new Array(probe); [].concat(probe);
        \\probe;
    , 2);
}

test "a returned argument is a new reference, the argument itself is released" {
    // count(probe, probe) keeps 2 parameters + 2 `arguments` elements and
    // keep(probe) 1 + 1 (call environments are not freed yet); `back`
    // holds the returned reference: 2 + 4 + 2 + 1.
    try expectObjectRefcount(
        \\let probe = {};
        \\function count(a, b) { return 0; }
        \\function keep(a) { return a; }
        \\count(probe, probe);
        \\const back = keep(probe);
        \\probe;
    , 9);
}

test "spread arguments are released after the call" {
    // Only the callee's `arguments` keeps its 2 elements (its environment
    // is not freed yet); the spread array and the caller's copies are gone.
    try expectObjectRefcount(
        \\let probe = {};
        \\function f() { return arguments.length; }
        \\f(...[probe, probe]);
        \\probe;
    , 4);
}

test "a discarded array literal releases its elements" {
    try expectObjectRefcount(
        \\let probe = {};
        \\[probe, probe];
        \\let tmp = [probe]; // +1 (element of a live array)
        \\probe;
    , 3);
}

test "let/const/var initializers hold exactly one reference each" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let a = probe; const b = probe; var c = probe; // +3
        \\probe;
    , 5);
}

test "a for-let initializer holds exactly the loop binding's reference" {
    // The loop scope's binding keeps its one reference (environments are
    // not freed yet -- a separate, known gap); the initializer adds none.
    try expectObjectRefcount(
        \\let probe = {};
        \\for (let i = probe; false;) {}
        \\probe;
    , 3);
}

test "assigning to a property costs exactly the property's reference" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let obj = {};
        \\obj.a = probe; // +1 (property), nothing else
        \\probe;
    , 3);
}

test "a generator keeps its arguments until it runs, and they stay valid" {
    try helpers.expectStdout(
        \\function* g(a, b) { yield a.v + b.v; }
        \\const it = g({ v: 1 }, { v: 2 }); // arguments are temporaries
        \\console.log(it.next().value);
    , "3\n");
}

test "a promise job keeps its value after the settling promise is gone" {
    try helpers.expectStdout(
        \\Promise.resolve('3').then(v => console.log(v));
        \\const p = Promise.resolve({ k: 'kept' });
        \\console.log(Promise.resolve(p) === p);
        \\p.then(o => console.log(o.k));
    , "true\n3\nkept\n");
}

// ---- Lifetimes the argument fix exposed -------------------------------

test "code run by eval outlives the eval argument string" {
    // The source string is built at runtime and dropped right after the
    // call; functions defined in it must still find their identifiers.
    try helpers.expectStdout(
        \\var s1 = 'first'; var o;
        \\var code = 'o = { get foo() { return s' + '1; } };';
        \\eval(code);
        \\code = null;
        \\var junk = []; for (var i = 0; i < 500; i++) junk.push(('o = { get foo() { return QQ; } };' + i).slice(0, 34));
        \\console.log(o.foo);
    , "first\n");
}

test "a temporary prototype stays alive with its object" {
    try helpers.expectStdout(
        \\var a = Object.create({ p: 42 });
        \\var b = {}; Object.setPrototypeOf(b, { q: 'set' });
        \\var c = {}; c.__proto__ = { r: 'proto' };
        \\var junk = []; for (var i = 0; i < 500; i++) junk.push({ x: i, y: 'z' + i });
        \\console.log(a.p, b.q, c.r);
    , "42 set proto\n");
}

test "an object holds exactly one reference to a prototype set from JS" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let o = Object.create(probe); // +1 (o's prototype)
        \\probe;
    , 3);
}

test "replacing or clearing a prototype releases the old one" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let o = Object.create(probe);
        \\Object.setPrototypeOf(o, {}); // releases probe
        \\let p = {}; p.__proto__ = probe; p.__proto__ = null; // +1, then released
        \\probe;
    , 2);
}

test "an object that dies releases its prototype" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let o = Object.create(probe);
        \\o = null;
        \\probe;
    , 2);
}

// ---- z-value mutation wrappers / evalExpression ownership ----------------

/// Function boxes alive after `source` ran (no GC pass: the collector
/// would also reclaim a leaked, unreachable one). A box that reaches
/// refcount 0 leaves the GC registry at once.
fn liveFunctionBoxes(source: []const u8) !usize {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try @import("zinterpreter").Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();
    const value = try interp.run(source);
    value.deinit();
    var n: usize = 0;
    var it = interp.gc_registry.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .function) n += 1;
    }
    return n;
}

test "an object literal property holds exactly one reference to its value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let o = { a: probe }; // +1 (property), now 3
        \\probe;
    , 3);
}

test "a duplicate key in an object literal releases the value it replaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let o = { a: probe, a: 1 };
        \\probe;
    , 2);
}

test "a duplicate method in an object literal releases the method it replaces" {
    try testing.expectEqual(try liveFunctionBoxes("let o = { m() {} }; 0;"), try liveFunctionBoxes("let o = { m() {}, m() {} }; 0;"));
}

test "a method in an object literal releases the value it replaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let o = { a: probe, a() {} };
        \\probe;
    , 2);
}

test "Object.assign over an existing key releases the value it replaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let t = {};
        \\t.a = probe;            // now 3
        \\Object.assign(t, { a: 1 });
        \\probe;
    , 2);
}

test "Object.assign copies hold exactly one reference each" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let t = Object.assign({}, { a: probe }); // +1 (t.a), now 3
        \\probe;
    , 3);
}

test "spread with overlapping keys releases the value it replaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let o = { a: probe, ...{ a: 1 } };
        \\probe;
    , 2);
}

test "spread from a proxy with overlapping keys releases the value it replaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let o = { a: probe, ...new Proxy({ a: 1 }, {}) };
        \\probe;
    , 2);
}

test "Object.fromEntries with a repeated key releases the value it replaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let o = Object.fromEntries([['a', probe], ['a', 1]]);
        \\probe;
    , 2);
}

test "new Map holds exactly one reference per key and value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map([[probe, probe]]); // +1 key, +1 value, now 4
        \\probe;
    , 4);
}

test "new Map with a repeated key releases the value it replaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map([['k', probe], ['k', 1]]);
        \\probe;
    , 2);
}

test "new Map with a repeated key releases the redundant key" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map([[probe, 1], [probe, 2]]); // one stored key, now 3
        \\probe;
    , 3);
}

test "new Set with a repeated value holds one reference" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let s = new Set([probe, probe]); // +1, now 3
        \\probe;
    , 3);
}

test "Map.delete releases the stored key" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set(probe, 1); // now 3
        \\m.delete(probe);
        \\probe;
    , 2);
}

test "Set.add of a value already present does not retain it again" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let s = new Set();
        \\s.add(probe); // now 3
        \\s.add(probe);
        \\probe;
    , 3);
}

test "Map.clear releases every key and value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set(probe, probe); // now 4
        \\m.clear();
        \\probe;
    , 2);
}

test "a static field holds exactly one reference to its value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\class C { static x = probe; } // +1 (C.x), now 3
        \\probe;
    , 3);
}

test "a duplicate static field releases the value it replaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\class C { static x = probe; static x = 1; }
        \\probe;
    , 2);
}

test "a duplicate class method releases the method it replaces" {
    try testing.expectEqual(try liveFunctionBoxes("class C { m() {} } 0;"), try liveFunctionBoxes("class C { m() {} m() {} } 0;"));
    try testing.expectEqual(try liveFunctionBoxes("class C { static m() {} } 0;"), try liveFunctionBoxes("class C { static m() {} static m() {} } 0;"));
}

// ---- owned evalExpression values in class/default/sequence paths --------

/// Refcount of the `.function` a script completes with.
fn functionRefcountOf(source: []const u8) !usize {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try @import("zinterpreter").Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();
    const value = try interp.run(source);
    defer value.deinit();
    try testing.expect(value == .function);
    return value.function.refCount();
}

test "an instance field holds exactly one reference to its value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\class C { x = probe; }
        \\let c = new C(); // +1 (c.x), now 3
        \\probe;
    , 3);
}

test "a parameter default is released after binding; a passed argument is not" {
    // The call's environment keeps `x` (+1) until the collector runs.
    try expectObjectRefcount(
        \\let probe = {};
        \\let f = (x = probe) => 0;
        \\f();
        \\probe;
    , 3);
    try expectObjectRefcount(
        \\let probe = {};
        \\let f = (x = {}) => 0;
        \\f(probe);
        \\probe;
    , 3);
}

test "an array pattern default is released after binding; an item is not" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let [a = probe] = []; // +1 (a), now 3
        \\probe;
    , 3);
    try expectObjectRefcount(
        \\let probe = {};
        \\let [a = {}] = [probe];
        \\probe;
    , 3);
}

test "an object pattern default is released after binding" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let { a = probe } = {}; // +1 (a), now 3
        \\probe;
    , 3);
    // Not from the default: the getProperty result still leaks one
    // reference (block D); this pins that it is not released twice.
    try expectObjectRefcount(
        \\let probe = {};
        \\let { a = {} } = { a: probe };
        \\probe;
    , 4);
}

test "an array assignment default is released after assigning; an item is not" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let a;
        \\[a = probe] = []; // +1 (a), now 3
        \\probe;
    , 3);
    try expectObjectRefcount(
        \\let probe = {};
        \\let a;
        \\[a = {}] = [probe];
        \\probe;
    , 3);
}

test "an object assignment default is released after assigning" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let a;
        \\({ a: a = probe } = {}); // +1 (a), now 3
        \\probe;
    , 3);
    // Not from the default: the getProperty result still leaks one
    // reference (block D); this pins that it is not released twice.
    try expectObjectRefcount(
        \\let probe = {};
        \\let a;
        \\({ a: a = {} } = { a: probe });
        \\probe;
    , 4);
}

test "extends holds exactly one reference to the parent class" {
    // The class's context keeps one; the evaluated `extends` value is
    // released.
    const alone = try functionRefcountOf("let probe = class {}; probe.prototype; probe;");
    const extended = try functionRefcountOf("let probe = class {}; probe.prototype; class C extends probe {} probe;");
    try testing.expectEqual(alone + 1, extended);
}

test "a sequence expression releases the values it discards" {
    try expectObjectRefcount(
        \\let probe = {};
        \\(probe, 0);
        \\probe;
    , 2);
    try expectObjectRefcount(
        \\let probe = {};
        \\let f = () => probe;
        \\(f(), 0);
        \\probe;
    , 2);
}
