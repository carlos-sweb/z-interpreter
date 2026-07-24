//! Async generators (async function*, async *method(){}), Symbol.asyncIterator,
//! and `for await`. All orderings Node-verified. Deferred (documented, same
//! narrowing as the sync generator and async/await phases): yield* delegation
//! into/through an async generator, AsyncGenerator.prototype.return/.throw,
//! overlapping .next() calls without awaiting the previous one, top-level await.
const std = @import("std");
const helpers = @import("helpers.zig");

test "next() on an async generator returns a promise of {value, done}" {
    try helpers.expectStdout(
        \\async function* g() { yield 1; yield 2; return 'FIN'; }
        \\const it = g();
        \\it.next().then(r => console.log(r.value, r.done));
    , "1 false\n");
}

test "await inside an async generator body, then yield the awaited value" {
    try helpers.expectStdout(
        \\async function* g() { const v = await Promise.resolve(10); yield v * 2; }
        \\g().next().then(r => console.log(r.value, r.done));
    , "20 false\n");
}

test "interleaved yield/await ordering across multiple next() calls" {
    try helpers.expectStdout(
        \\const log = [];
        \\async function* g() {
        \\  log.push('a');
        \\  await Promise.resolve();
        \\  log.push('b');
        \\  yield 1;
        \\  log.push('c');
        \\  const v = await Promise.resolve(2);
        \\  log.push('d');
        \\  yield v;
        \\  log.push('e');
        \\}
        \\async function drive() {
        \\  const it = g();
        \\  log.push('start');
        \\  const r1 = await it.next();
        \\  log.push('r1:' + r1.value);
        \\  const r2 = await it.next();
        \\  log.push('r2:' + r2.value);
        \\  const r3 = await it.next();
        \\  log.push('r3:' + r3.done);
        \\  console.log(log.join(','));
        \\}
        \\drive();
    , "start,a,b,r1:1,c,d,r2:2,e,r3:true\n");
}

test "for await over an async generator" {
    try helpers.expectStdout(
        \\async function* g() { yield 1; yield 2; yield 3; }
        \\async function drive() {
        \\  const out = [];
        \\  for await (const v of g()) out.push(v);
        \\  console.log(out.join(','));
        \\}
        \\drive();
    , "1,2,3\n");
}

test "for await over a plain array awaits every value, promise or not" {
    try helpers.expectStdout(
        \\async function drive() {
        \\  const out = [];
        \\  for await (const v of [Promise.resolve('a'), 'b', Promise.resolve('c')]) out.push(v);
        \\  console.log(out.join(','));
        \\}
        \\drive();
    , "a,b,c\n");
}

test "async generator method on a class sees the right `this` and private fields" {
    try helpers.expectStdout(
        \\class C {
        \\  #n = 0;
        \\  async *countTo(max) {
        \\    while (this.#n < max) { this.#n = this.#n + 1; yield this.#n; }
        \\  }
        \\}
        \\async function drive() {
        \\  const c = new C();
        \\  const out = [];
        \\  for await (const v of c.countTo(3)) out.push(v);
        \\  console.log(out.join(','));
        \\}
        \\drive();
    , "1,2,3\n");
}

test "an exception thrown inside an async generator body rejects next() and for-await surfaces it" {
    try helpers.expectStdout(
        \\async function* g() { yield 1; throw new Error('boom'); }
        \\async function drive() {
        \\  try {
        \\    for await (const v of g()) console.log('v:', v);
        \\  } catch (e) { console.log('atrapado:', e.message); }
        \\}
        \\drive();
    , "v: 1\natrapado: boom\n");
}
