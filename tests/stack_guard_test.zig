//! The stack-depth guard (Test262's tco-* tests exposed the segfault):
//! deep recursion and deep expression trees raise the real RangeError
//! instead of overflowing the native stack. Byte-based via
//! @frameAddress(), so Debug/Release frame sizes and fiber stacks are
//! all handled by the same check.
const std = @import("std");
const helpers = @import("helpers.zig");

test "deep recursion is a catchable RangeError with Node's message, and the engine survives" {
    try helpers.expectStdout(
        \\function f(n) { return n === 0 ? 0 : f(n - 1) + 1; }
        \\try { f(100000); } catch (e) { console.log(e.name + ': ' + e.message); }
        \\console.log('vivo:', f(50));
    , "RangeError: Maximum call stack size exceeded\nvivo: 50\n");
}

test "runaway recursion inside a generator (fiber stack) is the same catchable RangeError" {
    try helpers.expectStdout(
        \\function f(n) { return n === 0 ? 0 : f(n - 1) + 1; }
        \\function* g() { yield f(100000); }
        \\try { g().next(); } catch (e) { console.log('fiber:', e.name); }
        \\console.log('ok');
    , "fiber: RangeError\nok\n");
}

test "mutual recursion trips the guard too" {
    try helpers.expectUncaught(
        \\function a(n) { return b(n + 1); }
        \\function b(n) { return a(n + 1); }
        \\a(0);
    , .range_error, "Maximum call stack size exceeded");
}

test "an async function overflowing rejects instead of crashing" {
    try helpers.expectStdout(
        \\function f(n) { return n === 0 ? 0 : f(n - 1) + 1; }
        \\async function work() { return f(100000); }
        \\work().catch(e => console.log('rechazo:', e.name));
    , "rechazo: RangeError\n");
}
