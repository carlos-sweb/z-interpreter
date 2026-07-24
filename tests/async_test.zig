//! async/await (phase 13b) over the phase-13a queues. All orderings
//! Node-verified. Deferred (documented): async arrows, async methods,
//! async generators, top-level await.
const std = @import("std");
const helpers = @import("helpers.zig");

test "an async function returns a promise; sync until the first await" {
    try helpers.expectStdout(
        \\async function trabajo() {
        \\  console.log('antes del await');
        \\  const v = await Promise.resolve(42);
        \\  console.log('despues:', v);
        \\  return v * 2;
        \\}
        \\trabajo().then(r => console.log('resultado:', r));
        \\console.log('sync sigue');
    , "antes del await\nsync sigue\ndespues: 42\nresultado: 84\n");
}

test "awaiting a non-promise still takes one queue trip" {
    try helpers.expectStdout(
        \\async function f() { const v = await 5; console.log('v:', v); }
        \\f();
        \\console.log('sync');
    , "sync\nv: 5\n");
}

test "try/catch around a rejected await" {
    try helpers.expectStdout(
        \\async function f() {
        \\  try { await Promise.reject(new Error('no')); }
        \\  catch (e) { return 'atrapado: ' + e.message; }
        \\}
        \\f().then(r => console.log(r));
    , "atrapado: no\n");
}

test "a throw in an async body rejects its promise" {
    try helpers.expectStdout(
        \\async function g() { throw new Error('directo'); }
        \\g().catch(e => console.log('rechazo:', e.message));
    , "rechazo: directo\n");
}

test "await in a loop is sequential" {
    try helpers.expectStdout(
        \\async function seq() {
        \\  let acc = '';
        \\  for (const x of ['a', 'b', 'c']) { acc = acc + (await Promise.resolve(x)); }
        \\  return acc;
        \\}
        \\seq().then(r => console.log('seq:', r));
    , "seq: abc\n");
}

test "async functions awaiting async functions" {
    try helpers.expectStdout(
        \\async function inner() { return 10; }
        \\async function outer() { return (await inner()) + 1; }
        \\outer().then(r => console.log('anidado:', r));
    , "anidado: 11\n");
}

test "await new Promise(res => setTimeout(res)) -- the full fibers+timers integration" {
    try helpers.expectStdout(
        \\async function sleepy() {
        \\  await new Promise(res => setTimeout(res, 5));
        \\  return 'desperto';
        \\}
        \\sleepy().then(r => console.log(r));
        \\console.log('mientras duerme');
    , "mientras duerme\ndesperto\n");
}

test "Promise.all over async function results" {
    try helpers.expectStdout(
        \\async function inner() { return 10; }
        \\async function outer() { return (await inner()) + 1; }
        \\Promise.all([inner(), outer()]).then(a => console.log('all:', a.join(',')));
    , "all: 10,11\n");
}

test "async function expressions work too" {
    try helpers.expectStdout(
        \\const f = async function (x) { return (await Promise.resolve(x)) * 3; };
        \\f(7).then(r => console.log(r));
    , "21\n");
}

test "await stays an ordinary identifier outside async bodies" {
    try helpers.expectNumber("const await = 4; await + 1;", 5);
}

test "async arrow functions (parenless and paren'd)" {
    try helpers.expectStdout(
        \\const f = async () => await Promise.resolve('flecha');
        \\f().then(v => console.log(v));
    , "flecha\n");
    try helpers.expectStdout(
        \\const g = async x => x * 2;
        \\g(21).then(v => console.log('param:', v));
    , "param: 42\n");
    // An async arrow captures `this` lexically like any arrow.
    try helpers.expectStdout(
        \\const obj = { tag: 5, run() { const f = async () => this.tag; return f(); } };
        \\obj.run().then(v => console.log(v));
    , "5\n");
}

test "async methods in object literals and classes" {
    try helpers.expectStdout(
        \\const o = { async m() { return await Promise.resolve(7); } };
        \\o.m().then(v => console.log('obj:', v));
    , "obj: 7\n");
    try helpers.expectStdout(
        \\class C { async m() { return 8; } static async sm() { return 9; } }
        \\new C().m().then(v => console.log('inst:', v));
        \\C.sm().then(v => console.log('static:', v));
    , "inst: 8\nstatic: 9\n");
}

test "async generator methods work (moved to async_generator_test.zig)" {
    try helpers.expectStdout(
        \\const o = { async *ag() { yield 1; } };
        \\o.ag().next().then(r => console.log(r.value, r.done));
    , "1 false\n");
}

test "a generator driven from inside an async function (nested fibers)" {
    try helpers.expectStdout(
        \\function* nums() { yield 1; yield 2; }
        \\async function suma() {
        \\  let total = 0;
        \\  for (const n of nums()) { total = total + (await Promise.resolve(n)); }
        \\  return total;
        \\}
        \\suma().then(r => console.log('total:', r));
    , "total: 3\n");
}
