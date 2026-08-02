//! `Boolean.prototype`, and the `Boolean` constructor (`globalBoolean`
//! moved here from its old home in the "Loose globals" section --
//! that section mixed several unrelated types' global entry points
//! together; this is the Boolean-specific one). z-interpreter-
//! refactor.md, Step 5 Phase A.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zbigint = @import("zbigint");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;

const requirePrimitive = builtin_helpers.requirePrimitive;

pub const boolean_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "toString", MethodSpec{ .call = booleanToString, .arity = 0 } },
    .{ "valueOf", MethodSpec{ .call = booleanValueOf, .arity = 0 } },
});

fn requireBoolean(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!bool {
    return (try requirePrimitive(ctx, this_value, .boolean, "Boolean.prototype.{s} called on a non-boolean", method)).boolean;
}

fn booleanToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const b = try requireBoolean(ctx, this_value, "toString");
    return interp(ctx).gcNewString(if (b) "true" else "false");
}

fn booleanValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromBool(try requireBoolean(ctx, this_value, "valueOf"));
}

fn globalBoolean(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const primitive = JSValue.fromBool(coercion.isTruthy(arg(args, 0)));
    return interp(ctx).boxPrimitiveIfConstructed(ctx, this_value, primitive);
}

/// Installs the `Boolean` constructor (no statics).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "Boolean", .ctor = .{ .arity = 1, .call = globalBoolean, .constructable = true } });
}
