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

test "basic bytecode function is opt-in and preserves AST fallback" {
    try runAdd(false);
    try runAdd(true);
}
