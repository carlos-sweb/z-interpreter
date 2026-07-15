const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

pub const Result = struct {
    value: JSValue,
    stdout: []const u8,
};

/// Runs `source` against a fresh Interpreter backed by an in-memory
/// stdout buffer (never the real process stdout), then hands both the
/// completion value and captured stdout to `check`. Owns the full
/// lifecycle (arena + writer buffer), so `check` doesn't need to worry
/// about cleanup.
pub fn runAndCheck(source: []const u8, context: anytype, comptime check: fn (@TypeOf(context), Result) anyerror!void) !void {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();
    const value = try interp.run(source);
    try check(context, .{ .value = value, .stdout = allocating.written() });
}

pub fn expectNumber(source: []const u8, expected: f64) !void {
    try runAndCheck(source, expected, struct {
        fn check(want: f64, result: Result) !void {
            try testing.expect(result.value == .number);
            try testing.expectEqual(want, result.value.number);
        }
    }.check);
}

pub fn expectStdout(source: []const u8, expected: []const u8) !void {
    try runAndCheck(source, expected, struct {
        fn check(want: []const u8, result: Result) !void {
            try testing.expectEqualStrings(want, result.stdout);
        }
    }.check);
}

pub fn expectNotImplemented(source: []const u8) !void {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();
    try testing.expectError(error.NotImplemented, interp.run(source));
}

/// Asserts the script dies with an uncaught engine error of the given
/// kind/message (readable via `pending_exception` after run() returns
/// error.UncaughtException).
pub fn expectUncaught(source: []const u8, kind: zvalue.ErrorKind, message: []const u8) !void {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();
    try testing.expectError(error.UncaughtException, interp.run(source));
    const ex = interp.pending_exception.?;
    try testing.expect(ex == .@"error");
    try testing.expectEqual(kind, ex.@"error".value.kind);
    try testing.expectEqualStrings(message, ex.@"error".value.message);
}

/// Like expectUncaught but for `throw <non-error value>` -- hands the raw
/// thrown JSValue to `check`.
pub fn expectUncaughtValue(source: []const u8, context: anytype, comptime check: fn (@TypeOf(context), JSValue) anyerror!void) !void {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();
    try testing.expectError(error.UncaughtException, interp.run(source));
    try check(context, interp.pending_exception.?);
}
