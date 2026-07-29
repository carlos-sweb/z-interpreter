//! The stack-depth guard (Test262's tco-* tests exposed the segfault):
//! deep recursion and deep expression trees raise the real RangeError
//! instead of overflowing the native stack. Byte-based via
//! @frameAddress(), so Debug/Release frame sizes and fiber stacks are
//! all handled by the same check.
//!
//! The tests below this point cover the OTHER half of the same problem
//! (see `/home/sweb/.plans/z-parser-improve.md`): deeply nested SOURCE
//! TEXT (parens, `new`-chains, prefix-operator chains) could crash while
//! z-parser is still building the AST, before `evalExpression` above is
//! ever reached -- this repo's own guard gave that phase zero protection
//! until `Interpreter.stack_limit` was threaded down through
//! z-functions/z-statements into z-parser's own `checkStackDepth`.
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const helpers = @import("helpers.zig");

fn nestedParensSource(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var src: std.ArrayList(u8) = .empty;
    for (0..n) |_| try src.append(allocator, '(');
    try src.append(allocator, '1');
    for (0..n) |_| try src.append(allocator, ')');
    return src.toOwnedSlice(allocator);
}

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

test "deeply nested top-level source fails as a reported error, not a segfault" {
    const allocator = testing.allocator;
    const nested = try nestedParensSource(allocator, 5000);
    defer allocator.free(nested);
    const source = try std.fmt.allocPrint(allocator, "{s};", .{nested});
    defer allocator.free(source);

    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();
    // A top-level parse failure isn't JS-catchable (matches how every
    // other ParseError already behaves here -- there's no enclosing
    // script to catch it in), it propagates as a raw Zig error.
    try testing.expectError(error.MaxNestingDepthExceeded, interp.run(source));
}

test "deeply nested eval() is a catchable RangeError, not a crash" {
    const allocator = testing.allocator;
    const nested = try nestedParensSource(allocator, 5000);
    defer allocator.free(nested);
    const source = try std.fmt.allocPrint(allocator, "eval('{s}');", .{nested});
    defer allocator.free(source);

    try helpers.expectUncaught(source, .range_error, "Maximum call stack size exceeded");
}

test "a script-level try/catch around a deeply nested eval() sees the RangeError" {
    const allocator = testing.allocator;
    const nested = try nestedParensSource(allocator, 5000);
    defer allocator.free(nested);
    const source = try std.fmt.allocPrint(allocator,
        \\try {{
        \\  eval('{s}');
        \\  console.log('no error');
        \\}} catch (e) {{
        \\  console.log(e.name, e.message);
        \\}}
    , .{nested});
    defer allocator.free(source);

    try helpers.expectStdout(source, "RangeError Maximum call stack size exceeded\n");
}
