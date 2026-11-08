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

test "bytecode VM top-level arithmetic, unaries, comparisons, and strings" {
    // 1 + 2 -> 3
    {
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
        defer interpreter.deinit();
        interpreter.compile_options.use_bytecode_vm = true;
        const res = try interpreter.run("1 + 2");
        defer res.deinit();
        try testing.expect(res == .number);
        try testing.expectEqual(@as(f64, 3), res.number);
    }
    // 10 * 5 - 3 -> 47
    {
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
        defer interpreter.deinit();
        interpreter.compile_options.use_bytecode_vm = true;
        const res = try interpreter.run("10 * 5 - 3");
        defer res.deinit();
        try testing.expect(res == .number);
        try testing.expectEqual(@as(f64, 47), res.number);
    }
    // "hello" + " " + "world" -> "hello world"
    {
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
        defer interpreter.deinit();
        interpreter.compile_options.use_bytecode_vm = true;
        const res = try interpreter.run("\"hello\" + \" \" + \"world\"");
        defer res.deinit();
        try testing.expect(res == .string);
        try testing.expectEqualStrings("hello world", res.string.value.data);
    }
    // 1 < 2 -> true
    {
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
        defer interpreter.deinit();
        interpreter.compile_options.use_bytecode_vm = true;
        const res = try interpreter.run("1 < 2");
        defer res.deinit();
        try testing.expect(res == .boolean);
        try testing.expectEqual(true, res.boolean);
    }
    // -5 + 3 -> -2
    {
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
        defer interpreter.deinit();
        interpreter.compile_options.use_bytecode_vm = true;
        const res = try interpreter.run("-5 + 3");
        defer res.deinit();
        try testing.expect(res == .number);
        try testing.expectEqual(@as(f64, -2), res.number);
    }
    // !true -> false
    {
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
        defer interpreter.deinit();
        interpreter.compile_options.use_bytecode_vm = true;
        const res = try interpreter.run("!true");
        defer res.deinit();
        try testing.expect(res == .boolean);
        try testing.expectEqual(false, res.boolean);
    }
    // !false -> true
    {
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
        defer interpreter.deinit();
        interpreter.compile_options.use_bytecode_vm = true;
        const res = try interpreter.run("!false");
        defer res.deinit();
        try testing.expect(res == .boolean);
        try testing.expectEqual(true, res.boolean);
    }
}

test "bytecode VM objects, arrays, and property access" {
    // ({a: 1, b: 2}).a -> 1
    try testing.expectEqual(@as(f64, 1), try runNumber("({a: 1, b: 2}).a", true));
    try testing.expectEqual(@as(f64, 2), try runNumber("({a: 1, b: 2}).b", true));

    // [1, 2, 3][1] -> 2
    try testing.expectEqual(@as(f64, 2), try runNumber("[1, 2, 3][1]", true));
    try testing.expectEqual(@as(f64, 1), try runNumber("[1, 2, 3][0]", true));
    try testing.expectEqual(@as(f64, 3), try runNumber("[1, 2, 3].length", true));

    // let o = {}; o.x = 5; o.x -> 5
    try testing.expectEqual(@as(f64, 5), try runNumber("let o = {}; o.x = 5; o.x", true));

    // let a = []; a[0] = 10; a[0] -> 10
    try testing.expectEqual(@as(f64, 10), try runNumber("let a = []; a[0] = 10; a[0]", true));

    // ({nested: {v: 42}}).nested.v -> 42
    try testing.expectEqual(@as(f64, 42), try runNumber("({nested: {v: 42}}).nested.v", true));

    // Getter fallback preserves AST evaluation
    try testing.expectEqual(@as(f64, 99), try runNumber("let o = { get val() { return 99; } }; o.val", true));
}

test "bytecode VM closures" {
    const source = "let counter = 0; function inc() { counter++; return counter; } inc(); inc();";
    try testing.expectEqual(@as(f64, 2), try runNumber(source, true));
}

test "bytecode VM for of iteration" {
    const source = "let sum = 0; for (const x of [1, 2, 3]) sum += x; sum;";
    try testing.expectEqual(@as(f64, 6), try runNumber(source, true));
}

test "bytecode VM try catch throw" {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
    defer interpreter.deinit();
    interpreter.compile_options.use_bytecode_vm = true;
    const res = try interpreter.run("let r; try { throw 'err'; } catch(e) { r = e; } r;");
    defer res.deinit();
    try testing.expect(res == .string);
    try testing.expectEqualStrings("err", res.string.value.data);
}

test "bytecode opt-in falls back for generator functions" {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
    defer interpreter.deinit();
    interpreter.compile_options.use_bytecode_vm = true;

    const source = "function* g() { yield 1; yield 2; } let it = g(); let r = [it.next().value, it.next().value]; r[0] + r[1];";
    const result = try interpreter.run(source);
    defer result.deinit();
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 3), result.number);
}

test "bytecode opt-in falls back for async functions" {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
    defer interpreter.deinit();
    interpreter.compile_options.use_bytecode_vm = true;

    const result = try interpreter.run("async function f() { return await 1; } f();");
    defer result.deinit();
    try testing.expect(result == .promise);
}

test "bytecode VM superinstructions" {
    // Funcional: let x = 5; let y = x - 2; return y; -> 3
    try testing.expectEqual(@as(f64, 3), try runNumber("(function() { let x = 5; let y = x - 2; return y; })()", true));
    // Funcional: let x = 5; if (x > 3) return 1; return 0; -> 1
    try testing.expectEqual(@as(f64, 1), try runNumber("(function() { let x = 5; if (x > 3) return 1; return 0; })()", true));
    // Tests for eq, inverted eq, lt, le, ge, add
    try testing.expectEqual(@as(f64, 1), try runNumber("(function() { let x = 5; return x == 5 ? 1 : 0; })()", true));
    try testing.expectEqual(@as(f64, 1), try runNumber("(function() { let x = 5; return 5 == x ? 1 : 0; })()", true));
    try testing.expectEqual(@as(f64, 1), try runNumber("(function() { let x = 5; return x < 10 ? 1 : 0; })()", true));
    try testing.expectEqual(@as(f64, 1), try runNumber("(function() { let x = 5; return x <= 5 ? 1 : 0; })()", true));
    try testing.expectEqual(@as(f64, 1), try runNumber("(function() { let x = 5; return x >= 5 ? 1 : 0; })()", true));
    try testing.expectEqual(@as(f64, 7), try runNumber("(function() { let x = 5; return x + 2; })()", true));
}

test "bytecode VM superinstructions disasm" {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
    defer interpreter.deinit();
    interpreter.compile_options.use_bytecode_vm = true;
    interpreter.compile_options.disasm = true;

    const result = try interpreter.run("function check(x) { return x == 5; } check(5);");
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, output.written(), "eq_local_const") != null);
}
