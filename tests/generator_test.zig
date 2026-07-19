//! Generators (phase 12): function*, yield, next(v), the iterator
//! protocol in for-of. All Node-verified. Deferred (documented):
//! yield* delegation, gen.return/gen.throw, generator methods.
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const helpers = @import("helpers.zig");

test "next() sequence with {value, done}; return value lands on done: true" {
    try helpers.expectStdout(
        \\function* tres() { yield 'a'; yield 'b'; return 'FIN'; }
        \\const g = tres();
        \\let r = g.next(); console.log(r.value, r.done);
        \\r = g.next(); console.log(r.value, r.done);
        \\r = g.next(); console.log(r.value, r.done);
        \\r = g.next(); console.log(r.value, r.done);
    , "a false\nb false\nFIN true\nundefined true\n");
}

test "next(v) becomes the yield expression's value" {
    try helpers.expectStdout(
        \\function* contador(desde) {
        \\  let n = desde;
        \\  while (true) { const salto = yield n; n = n + (salto || 1); }
        \\}
        \\const g = contador(10);
        \\console.log(g.next().value, g.next().value, g.next(5).value);
    , "10 11 16\n");
}

test "for-of drives the generator and excludes the return value" {
    try helpers.expectStdout(
        \\function* tres() { yield 'a'; yield 'b'; return 'FIN'; }
        \\for (const x of tres()) console.log('for-of:', x);
    , "for-of: a\nfor-of: b\n");
}

test "infinite generator + break; destructuring in the body works on the fiber" {
    try helpers.expectStdout(
        \\function* fib() { let [a, b] = [0, 1]; while (true) { yield a; [a, b] = [b, a + b]; } }
        \\const out = [];
        \\for (const n of fib()) { if (out.length === 7) break; out.push(n); }
        \\console.log(out.join(','));
    , "0,1,1,2,3,5,8\n");
}

test "two instances of the same generator are independent" {
    try helpers.expectStdout(
        \\function* dos() { yield 1; yield 2; }
        \\const g1 = dos(), g2 = dos();
        \\g1.next();
        \\console.log(g1.next().value, g2.next().value);
    , "2 1\n");
}

test "yield inside try/finally: finally runs when the body completes" {
    try helpers.expectStdout(
        \\function* conTry() { try { yield 'dentro'; } finally { console.log('finally del gen'); } }
        \\const t = conTry();
        \\console.log(t.next().value);
        \\console.log(t.next().done);
    , "dentro\nfinally del gen\ntrue\n");
}

test "a throw inside the generator body surfaces from next() and finishes it" {
    try helpers.expectStdout(
        \\function* boom() { yield 1; throw new Error('gen boom'); }
        \\const g = boom();
        \\g.next();
        \\try { g.next(); } catch (e) { console.log('atrapado:', e.message); }
        \\console.log(g.next().done);
    , "atrapado: gen boom\ntrue\n");
}

test "hand-written iterator objects work in for-of via the same protocol" {
    try helpers.expectStdout(
        \\const iter = { n: 0, next() { this.n = this.n + 1; return { value: this.n, done: this.n > 3 }; } };
        \\for (const x of iter) console.log(x);
    , "1\n2\n3\n");
}

test "generator methods in object literals and classes" {
    try helpers.expectStdout(
        \\const o = { *gen() { yield 1; yield 2; } };
        \\for (const v of o.gen()) console.log(v);
    , "1\n2\n");
    try helpers.expectStdout(
        \\class C { *nums() { yield 3; yield 4; } }
        \\console.log([...(function(){ const a = []; for (const v of new C().nums()) a.push(v); return a; })()].join(','));
    , "3,4\n");
}

test "yield* delegates to another generator, forwarding the return value" {
    try helpers.expectStdout(
        \\function* inner() { yield 'a'; yield 'b'; return 'FIN'; }
        \\function* outer() { const r = yield* inner(); console.log('ret:', r); yield 'c'; }
        \\for (const v of outer()) console.log(v);
    , "a\nb\nret: FIN\nc\n");
}

test "yield* over an array and a string" {
    try helpers.expectStdout(
        \\function* g() { yield* [1, 2]; yield* 'ab'; }
        \\for (const v of g()) console.log(v);
    , "1\n2\na\nb\n");
}

test "yield* forwards the outer resume value into the inner generator" {
    try helpers.expectStdout(
        \\function* echo() { while (true) { const x = yield; console.log('recibido:', x); } }
        \\function* deleg() { yield* echo(); }
        \\const d = deleg(); d.next(); d.next('forward');
    , "recibido: forward\n");
}

test "yield outside a generator body stays a parse error" {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();
    try testing.expectError(error.UnexpectedToken, interp.run("yield 5;"));
}
