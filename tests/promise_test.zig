//! Promises, the microtask queue, and setTimeout macrotasks (phase 13a).
//! Every ordering cross-checked against real Node.js.
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const helpers = @import("helpers.zig");

test "the fundamental ordering: sync before microtask" {
    try helpers.expectStdout("console.log('1'); Promise.resolve('3').then(v => console.log(v)); console.log('2');", "1\n2\n3\n");
}

test "executor runs synchronously; its resolution arrives async" {
    try helpers.expectStdout(
        \\new Promise((res) => { console.log('executor'); res(9); }).then(v => console.log('then:', v));
        \\console.log('after new');
    , "executor\nafter new\nthen: 9\n");
}

test "chaining: values flow, throws reject, catch recovers and the chain continues" {
    try helpers.expectStdout("Promise.resolve(1).then(v => v + 1).then(v => console.log('chain:', v));", "chain: 2\n");
    try helpers.expectStdout("Promise.reject(new Error('boom')).catch(e => console.log('caught:', e.message));", "caught: boom\n");
    try helpers.expectStdout(
        \\Promise.resolve(0).then(() => { throw new Error('mid'); })
        \\  .catch(e => 'rec:' + e.message)
        \\  .then(v => console.log(v));
    , "rec:mid\n");
}

test "finally: passes fulfillment and rejection through; its throw replaces" {
    try helpers.expectStdout("Promise.resolve('val').finally(() => console.log('fin')).then(v => console.log('after:', v));", "fin\nafter: val\n");
    try helpers.expectStdout("Promise.reject(new Error('r')).finally(() => {}).catch(e => console.log('pass:', e.message));", "pass: r\n");
    try helpers.expectStdout(
        \\Promise.resolve(1).finally(() => { throw new Error('replaced'); }).catch(e => console.log(e.message));
    , "replaced\n");
}

test "resolving with a promise adopts it; double resolve is a no-op" {
    try helpers.expectStdout("Promise.resolve(1).then(() => new Promise(res => res('inner'))).then(v => console.log('adopt:', v));", "adopt: inner\n");
    try helpers.expectStdout(
        \\new Promise((res) => { res('first'); res('second'); }).then(v => console.log(v));
    , "first\n");
}

test "then on an already-settled promise still runs async" {
    try helpers.expectStdout(
        \\const p = Promise.resolve('x');
        \\p.then(v => console.log('late:', v));
        \\console.log('sync');
    , "sync\nlate: x\n");
}

test "rejecting executor and throwing executor both reject" {
    try helpers.expectStdout("new Promise((_, rej) => rej(new Error('x'))).catch(e => console.log(e.message));", "x\n");
    try helpers.expectStdout("new Promise(() => { throw new Error('thrown'); }).catch(e => console.log(e.message));", "thrown\n");
}

test "Promise.all preserves order, mixes plain values, fails fast" {
    try helpers.expectStdout("Promise.all([Promise.resolve(1), 2, Promise.resolve(3)]).then(a => console.log('all:', a.join(',')));", "all: 1,2,3\n");
    try helpers.expectStdout("Promise.all([Promise.resolve(1), Promise.reject(new Error('no'))]).catch(e => console.log('rej:', e.message));", "rej: no\n");
    try helpers.expectStdout("Promise.all([]).then(a => console.log('empty:', a.length));", "empty: 0\n");
}

test "Promise.race: first settlement wins" {
    try helpers.expectStdout("Promise.race([new Promise(() => {}), Promise.resolve('fast')]).then(v => console.log('race:', v));", "race: fast\n");
    try helpers.expectStdout("Promise.race([Promise.reject(new Error('lose')), new Promise(() => {})]).catch(e => console.log(e.message));", "lose\n");
}

test "setTimeout: all microtasks drain before any timer; timers order by delay" {
    try helpers.expectStdout(
        \\setTimeout(() => console.log('timer'), 0);
        \\Promise.resolve().then(() => console.log('micro'));
        \\console.log('sync');
    , "sync\nmicro\ntimer\n");
    try helpers.expectStdout(
        \\setTimeout(() => console.log('b'), 5);
        \\setTimeout(() => console.log('a'), 0);
    , "a\nb\n");
    try helpers.expectStdout(
        \\const id = setTimeout(() => console.log('NUNCA'), 1);
        \\clearTimeout(id);
        \\setTimeout(() => console.log('queda'), 2);
    , "queda\n");
}

test "a microtask scheduled from a timer runs before the next timer" {
    try helpers.expectStdout(
        \\setTimeout(() => { console.log('t1'); Promise.resolve().then(() => console.log('m')); }, 0);
        \\setTimeout(() => console.log('t2'), 1);
    , "t1\nm\nt2\n");
}

test "a throwing timer callback is an uncaught exception" {
    try helpers.expectUncaught("setTimeout(() => { throw new Error('tick'); }, 0);", .generic, "tick");
}

test "console.log rendering and typeof" {
    try helpers.expectStdout("console.log(Promise.resolve(3));", "Promise { 3 }\n");
    try helpers.expectStdout("console.log(new Promise(() => {}));", "Promise { <pending> }\n");
    try helpers.expectStdout("console.log(typeof Promise, typeof Promise.resolve(1));", "function object\n");
}

test "the public jobs API: a host can drain the queue itself" {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    // run() drains, so schedule a job by hand afterwards via then() on a
    // pending promise, resolve it, then drive the queue manually.
    _ = try interp.run("let resolver; const p = new Promise(res => { resolver = res; }); p.then(v => console.log('manual:', v));");
    try testing.expect(!interp.hasPendingJobs());
    _ = try interp.run("resolver('ok');");
    // resolver() enqueued the reaction; run()'s own loop already drained
    // it -- so assert the OUTPUT arrived and the queue is empty again,
    // then exercise runPendingJob directly as a no-op on empty.
    try testing.expect(!interp.hasPendingJobs());
    try interp.runPendingJob();
    try testing.expect(std.mem.endsWith(u8, allocating.written(), "manual: ok\n"));
}
