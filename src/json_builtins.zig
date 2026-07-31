//! `JSON`: a statics-only namespace, no constructor, no prototype.
//! z-interpreter-refactor.md, Step 5 Phase A.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zjson = @import("zjson");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

pub const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;

fn jsonStringify(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const v = arg(args, 0);
    // Real spec: JSON.stringify(undefined | function | symbol) at the TOP
    // LEVEL returns the JS value `undefined` (not the string "undefined"),
    // it does NOT throw -- z-json's stringify() surfaces this same case as
    // JSONError.Unserializable (there's no []u8 to return), so it must be
    // special-cased BEFORE calling it, or the interpreter can't tell it
    // apart from the BigInt case below (which DOES throw).
    if (v == .undefined or v == .function or v == .symbol) return JSValue.UNDEFINED;
    const out = zjson.stringify(allocator, v) catch |err| switch (err) {
        error.CircularStructure => return interp(ctx).throwError(.type_error, "Converting circular structure to JSON", .{}),
        // Real Node: JSON.stringify(5n) (BigInt anywhere in the tree, not
        // just top-level) throws a catchable TypeError, not an uncaught
        // engine error -- was falling through to `else => return err`,
        // propagating a raw Zig error instead of a real JS exception.
        error.Unserializable => return interp(ctx).throwError(.type_error, "Do not know how to serialize a BigInt", .{}),
        else => return err,
    };
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn jsonParse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const text = arg(args, 0);
    if (text != .string) return self.throwError(.syntax_error, "Unexpected token in JSON", .{});
    const value = zjson.parse(allocator, text.string.value.data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A real, catchable SyntaxError -- matching JSON.parse's spec'd
        // failure mode.
        else => return self.throwError(.syntax_error, "Unexpected token in JSON", .{}),
    };
    // zjson.parse builds the tree via z-value's raw constructors, bypassing
    // gcNew*/gcTrack at every level -- see gcAdoptTree's doc comment.
    try self.gcAdoptTree(value);
    return value;
}

/// Installs the `JSON` namespace (no constructor).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "JSON", .statics = &.{
        .{ .name = "stringify", .value = .{ .method = jsonStringify } },
        .{ .name = "parse", .value = .{ .method = jsonParse } },
    } });
}
