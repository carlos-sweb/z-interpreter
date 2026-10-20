const std = @import("std");
const zinterpreter = @import("zinterpreter");

const allocator = std.heap.page_allocator;
const repetitions = 5;

const fib_definition =
    "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }";

fn median(samples: *[repetitions]u64) u64 {
    var index: usize = 0;
    while (index < samples.len) : (index += 1) {
        var smallest = index;
        var candidate = index + 1;
        while (candidate < samples.len) : (candidate += 1) {
            if (samples[candidate] < samples[smallest]) smallest = candidate;
        }
        std.mem.swap(u64, &samples[index], &samples[smallest]);
    }
    return samples[samples.len / 2];
}

fn measure(io: std.Io, n: u8, use_bytecode_vm: bool) !u64 {
    var samples: [repetitions]u64 = undefined;
    for (&samples) |*sample| sample.* = try measureOnce(io, n, use_bytecode_vm);
    return median(&samples);
}

fn measureOnce(io: std.Io, n: u8, use_bytecode_vm: bool) !u64 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(allocator, &output.writer);
    defer interpreter.deinit();
    interpreter.compile_options.use_bytecode_vm = use_bytecode_vm;

    const setup = try interpreter.run(fib_definition);
    setup.deinit();

    const source = try std.fmt.allocPrint(allocator, "fib({d});", .{n});
    defer allocator.free(source);
    const start = std.Io.Clock.awake.now(io);
    const result = try interpreter.run(source);
    const elapsed: u64 = @intCast(start.untilNow(io, .awake).nanoseconds);
    defer result.deinit();
    if (result != .number) return error.UnexpectedResult;
    return elapsed;
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("n  AST (ms)  VM (ms)  VM/AST\n", .{});
    for ([_]u8{ 20, 22, 24 }) |n| {
        const ast = try measure(io, n, false);
        const vm = try measure(io, n, true);
        std.debug.print("{d: >2} {d: >8.3} {d: >8.3} {d: >7.2}\n", .{
            n,
            @as(f64, @floatFromInt(ast)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(vm)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(vm)) / @as(f64, @floatFromInt(ast)),
        });
    }
}
