//! Proxy plan phase 1: only the `.proxy` JSValue variant + GC plumbing +
//! transparent (no-trap) delegation in getProperty/evalIn exist so far --
//! there is no `Proxy(target, handler)` constructor reachable from JS yet
//! (phase 2), so these tests build a `.proxy` value directly via
//! `Interpreter.gcNewProxy` and inject it as a global, rather than
//! running `new Proxy(...)` JS source.
//!
//! IMPORTANT: target/handler objects here MUST be created via
//! `interp.gcNewObject()`, not the raw `zvalue.JSValue.newObject()` --
//! the latter is never registered in the GC registry, and a value handed
//! to `defineGlobal` that's never gcTrack'd leaks unconditionally at
//! shutdown (confirmed as a real, separate, pre-existing bug while
//! writing this file -- NOT a Proxy-specific issue, the same "untracked
//! value" class as the JSON/YAML/TOML gcAdoptTree fix earlier this
//! project, just via a different entry point: any embedder handing a
//! raw-constructed JSValue to `defineGlobal`, not JS source itself).
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const helpers = @import("helpers.zig");

const Ctx = struct {
    interp: zinterpreter.Interpreter,
    allocating: std.Io.Writer.Allocating,

    fn init() !*Ctx {
        const self = try testing.allocator.create(Ctx);
        self.allocating = std.Io.Writer.Allocating.init(testing.allocator);
        self.interp = try zinterpreter.Interpreter.init(testing.allocator, &self.allocating.writer);
        return self;
    }

    fn deinit(self: *Ctx) void {
        self.interp.deinit();
        self.allocating.deinit();
        testing.allocator.destroy(self);
    }
};

test "typeof a proxy over a plain object is \"object\" (no get trap needed for typeof)" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    const target = try ctx.interp.gcNewObject();
    const handler = try ctx.interp.gcNewObject();
    const p = try ctx.interp.gcNewProxy(target, handler);
    try ctx.interp.defineGlobal("p", p);
    _ = try ctx.interp.run("console.log(typeof p);");
    try testing.expectEqualStrings("object\n", ctx.allocating.written());
}

test "property read with no `get` trap delegates transparently to the target" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    const target = try ctx.interp.gcNewObject();
    try target.object.value.set("greeting", try ctx.interp.gcNewString("hi"));
    const handler = try ctx.interp.gcNewObject();
    const p = try ctx.interp.gcNewProxy(target, handler);
    try ctx.interp.defineGlobal("p", p);
    _ = try ctx.interp.run("console.log(p.greeting);");
    try testing.expectEqualStrings("hi\n", ctx.allocating.written());
}

test "new Proxy(target, handler) via real JS source, no traps" {
    try helpers.expectStdout(
        \\const target = { greeting: 'hi', x: 1 };
        \\const p = new Proxy(target, {});
        \\console.log(typeof p, p.greeting, 'x' in p, 'y' in p);
    , "object hi true false\n");
}

test "Proxy() without `new` is a real TypeError" {
    try helpers.expectUncaught("Proxy({}, {});", .type_error, "Constructor Proxy requires 'new'");
}

test "new Proxy with a non-object target or handler is a real TypeError (one combined message, matching Node)" {
    try helpers.expectUncaught("new Proxy(1, {});", .type_error, "Cannot create proxy with a non-object as target or handler");
    try helpers.expectUncaught("new Proxy({}, 1);", .type_error, "Cannot create proxy with a non-object as target or handler");
}

test "new Proxy over a function target: typeof is \"function\" (calling it is phase 4, not covered here)" {
    try helpers.expectStdout(
        \\function f() { return 42; }
        \\const p = new Proxy(f, {});
        \\console.log(typeof p);
    , "function\n");
}

test "get/set/has/deleteProperty traps all fire, in the right order, with the right args" {
    // Deliberately avoids `+` string concatenation inside the trap
    // bodies (console.log's comma-separated args instead) -- `+`
    // concat has a real, PRE-EXISTING, unrelated leak in this engine
    // (see operators_test.zig's "string concatenation via +"), and
    // using it here would misattribute that leak to this test.
    try helpers.expectStdout(
        \\const target = { a: 1 };
        \\const p = new Proxy(target, {
        \\  get(t, k, r) { console.log('get', k); return t[k]; },
        \\  set(t, k, v, r) { console.log('set', k, v); t[k] = v; return true; },
        \\  has(t, k) { console.log('has', k); return k in t; },
        \\  deleteProperty(t, k) { console.log('del', k); delete t[k]; return true; },
        \\});
        \\console.log(p.a);
        \\p.b = 2;
        \\console.log(target.b);
        \\console.log('a' in p);
        \\delete p.a;
        \\console.log(target.a);
    , "get a\n1\nset b 2\n2\nhas a\ntrue\ndel a\nundefined\n");
}

test "a falsy `set` trap result is a real TypeError (always-strict engine, matching Node's ESM/strict behavior)" {
    try helpers.expectUncaught("const p = new Proxy({}, { set() { return false; } }); p.x = 1;", .type_error, "'set' on proxy: trap returned falsish for property 'x'");
}

test "apply trap fires on a proxy-wrapped callable target, and no-trap delegates transparently" {
    try helpers.expectStdout(
        \\function f(a, b) { return a + b; }
        \\const p = new Proxy(f, {
        \\  apply(target, thisArg, args) { console.log('apply', args.length, args.join(',')); return target.apply(thisArg, args) * 2; }
        \\});
        \\console.log(p(3, 4));
        \\const p2 = new Proxy(f, {});
        \\console.log(p2(1, 2));
    , "apply 2 3,4\n14\n3\n");
}

test "construct trap fires on `new proxy(...)`, and no-trap delegates transparently" {
    try helpers.expectStdout(
        \\class C { constructor(x) { this.x = x; } }
        \\const p3 = new Proxy(C, {
        \\  construct(target, args, newTarget) { console.log('construct', args.length, args.join(',')); return new target(...args); }
        \\});
        \\console.log(new p3(5).x);
        \\const p4 = new Proxy(C, {});
        \\console.log(new p4(9).x);
    , "construct 1 5\n5\n9\n");
}

test "calling or constructing a proxy over a non-callable target is a real TypeError" {
    try helpers.expectUncaught("const p = new Proxy({}, {}); p();", .type_error, "p is not a function");
    try helpers.expectUncaught("const p = new Proxy({}, {}); new p();", .type_error, "p is not a constructor");
}

test "ownKeys/getOwnPropertyDescriptor/defineProperty traps fire, matching Node" {
    try helpers.expectStdout(
        \\const target = { a: 1, b: 2 };
        \\const p = new Proxy(target, {
        \\  ownKeys(t) { console.log('ownKeys'); return Reflect.ownKeys(t); }
        \\});
        \\console.log(Object.keys(p).join(','));
        \\
        \\const p2 = new Proxy(target, {
        \\  getOwnPropertyDescriptor(t, k) { console.log('gopd', k); return Reflect.getOwnPropertyDescriptor(t, k); }
        \\});
        \\console.log(Object.getOwnPropertyDescriptor(p2, 'a').value);
        \\
        \\const p3 = new Proxy({}, {
        \\  defineProperty(t, k, d) { console.log('defineProperty', k); return Reflect.defineProperty(t, k, d); }
        \\});
        \\Object.defineProperty(p3, 'x', { value: 42, enumerable: true, writable: true, configurable: true });
        \\console.log(p3.x);
    , "ownKeys\na,b\ngopd a\n1\ndefineProperty x\n42\n");
}

test "every Reflect.* method, matching Node" {
    try helpers.expectStdout(
        \\const target = { a: 1, b: 2 };
        \\console.log(Reflect.get(target, 'a'));
        \\console.log(Reflect.set(target, 'c', 3), target.c);
        \\console.log(Reflect.has(target, 'a'), Reflect.has(target, 'zzz'));
        \\console.log(Reflect.deleteProperty(target, 'c'), target.c);
        \\console.log(Reflect.ownKeys(target).join(','));
        \\console.log(Reflect.getPrototypeOf(target) === Object.prototype);
        \\console.log(Reflect.defineProperty(target, 'd', { value: 4, enumerable: true, writable: true, configurable: true }), target.d);
        \\console.log(Reflect.getOwnPropertyDescriptor(target, 'a').value);
        \\function add(a, b) { return a + b; }
        \\console.log(Reflect.apply(add, null, [1, 2]));
        \\class C { constructor(x) { this.x = x; } }
        \\console.log(Reflect.construct(C, [9]).x);
    , "1\ntrue 3\ntrue false\ntrue undefined\na,b\ntrue\ntrue 4\n1\n3\n9\n");
}

test "object-literal spread, destructuring rest (binding and assignment), and for-in all see a proxy's keys" {
    try helpers.expectStdout(
        \\const target = { a: 1, b: 2, c: 3 };
        \\const p = new Proxy(target, {});
        \\console.log(JSON.stringify({...p}));
        \\const { a, ...rest } = p;
        \\console.log(a, JSON.stringify(rest));
        \\let x, rest2;
        \\({ a: x, ...rest2 } = p);
        \\console.log(x, JSON.stringify(rest2));
        \\const seen = [];
        \\for (const k in p) seen.push(k);
        \\console.log(seen.join(','));
    , "{\"a\":1,\"b\":2,\"c\":3}\n1 {\"b\":2,\"c\":3}\n1 {\"b\":2,\"c\":3}\na,b,c\n");
}

test "'in' with no `has` trap delegates transparently to the target" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    const target = try ctx.interp.gcNewObject();
    try target.object.value.set("x", JSValue.fromNumber(1));
    const handler = try ctx.interp.gcNewObject();
    const p = try ctx.interp.gcNewProxy(target, handler);
    try ctx.interp.defineGlobal("p", p);
    _ = try ctx.interp.run("console.log('x' in p, 'y' in p);");
    try testing.expectEqualStrings("true false\n", ctx.allocating.written());
}
