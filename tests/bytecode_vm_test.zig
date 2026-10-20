const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");

fn runAdd(use_bytecode_vm: bool) !void {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
    defer interpreter.deinit();
    interpreter.compile_options.use_bytecode_vm = use_bytecode_vm;

    const result = try interpreter.run("function add(a, b) { return a + b; } add(2, 3);");
    defer result.deinit();
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 5), result.number);
}

fn runNumber(source: []const u8, use_bytecode_vm: bool) !f64 {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
    defer interpreter.deinit();
    interpreter.compile_options.use_bytecode_vm = use_bytecode_vm;
    const result = try interpreter.run(source);
    defer result.deinit();
    try testing.expect(result == .number);
    return result.number;
}

test "basic bytecode function is opt-in and preserves AST fallback" {
    try runAdd(false);
    try runAdd(true);
}

test "bytecode opt-in falls back for an unsupported call expression" {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
    defer interpreter.deinit();
    interpreter.compile_options.use_bytecode_vm = true;

    const result = try interpreter.run("function identity(x) { return x; } function throughCall(x) { return identity(x); } throughCall(5);");
    defer result.deinit();
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 5), result.number);
}

test "bytecode VM matches AST recursion, branches, and calls" {
    const source = "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); } fib(10);";
    for (0..11) |n| {
        const program = try std.fmt.allocPrint(testing.allocator, "function fib(n) {{ return n < 2 ? n : fib(n - 1) + fib(n - 2); }} fib({d});", .{n});
        defer testing.allocator.free(program);
        const ast = try runNumber(program, false);
        const vm = try runNumber(program, true);
        try testing.expectEqual(ast, vm);
    }
    try testing.expectEqual(@as(f64, 55), try runNumber(source, true));
}

test "bytecode VM executes if else and while" {
    const source =
        "function count(n) { let total = 0; let i = 0; while (i < n) { if (i < 3) total = total + 1; else total = total + 2; i = i + 1; } return total; } count(5);";
    const ast = try runNumber(source, false);
    const vm = try runNumber(source, true);
    try testing.expectEqual(@as(f64, 7), ast);
    try testing.expectEqual(ast, vm);
}
