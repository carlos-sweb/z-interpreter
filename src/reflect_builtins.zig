//! `Reflect` -- a plain non-constructable object (Math's pattern), each
//! static a thin wrapper around the same interpreter internals every
//! Proxy trap dispatches through. No interleaving found: this section
//! was already self-contained at the end of builtins.zig, using only
//! object_builtins.zig's `definePropertyOn`/
//! `objectGetOwnPropertyDescriptor`/`objectGetOwnPropertyNames`/
//! `objectGetPrototypeOf` (already `pub` there since batch 7's
//! reach-back) and builtin_helpers.zig's `isObjectLike`.
//! z-interpreter-refactor.md, Step 5 Phase A batch 8.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const object_builtins = @import("object_builtins.zig");

const interp = native_helpers.interp;
const arg = native_helpers.arg;
const installBuiltin = builtin_helpers.installBuiltin;
const isObjectLike = builtin_helpers.isObjectLike;
const definePropertyOn = object_builtins.definePropertyOn;
const objectGetOwnPropertyDescriptor = object_builtins.objectGetOwnPropertyDescriptor;
const objectGetOwnPropertyNames = object_builtins.objectGetOwnPropertyNames;
const objectGetPrototypeOf = object_builtins.objectGetPrototypeOf;

// ===== Reflect =====
//
// A plain non-constructable object (Math's pattern), each static a thin
// wrapper around the same interpreter internals every Proxy trap above
// dispatches through -- these take already-evaluated JSValue arguments,
// not AST nodes, so they're simpler than the trap dispatch itself.

fn reflectRequireObject(ctx: *anyopaque, what: []const u8, v: JSValue) anyerror!JSValue {
    if (!isObjectLike(v)) return interp(ctx).throwError(.type_error, "Reflect.{s} called on non-object", .{what});
    return v;
}

fn reflectGet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "get", arg(args, 0));
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    return self.getProperty(target, key);
}

fn reflectSet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "set", arg(args, 0));
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    try self.setPropertyOnValue(target, key, arg(args, 2));
    return JSValue.fromBool(true);
}

fn reflectHas(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "has", arg(args, 0));
    return self.evalIn(arg(args, 1), target);
}

fn reflectDeleteProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "deleteProperty", arg(args, 0));
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    return JSValue.fromBool(try self.deletePropertyOnValue(target, key));
}

/// Narrowing: excludes symbol-keyed properties, same as
/// `objectGetOwnPropertyNames` it delegates to (real `Reflect.ownKeys`
/// includes both string and symbol keys).
fn reflectOwnKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = try reflectRequireObject(ctx, "ownKeys", arg(args, 0));
    return objectGetOwnPropertyNames(ctx, allocator, this_value, args);
}

fn reflectGetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = try reflectRequireObject(ctx, "getPrototypeOf", arg(args, 0));
    return objectGetPrototypeOf(ctx, allocator, this_value, args);
}

fn reflectDefineProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "defineProperty", arg(args, 0));
    const key = try self.encodeKey(arg(args, 1));
    defer self.gc_allocator.free(key);
    // Narrowing: this engine's definePropertyOn throws on failure rather
    // than returning false for every real spec failure mode -- Reflect's
    // "return false instead of throwing" contract only actually applies
    // to the cases that don't already throw here.
    try definePropertyOn(self, "defineProperty", target, key, arg(args, 2));
    return JSValue.fromBool(true);
}

fn reflectGetOwnPropertyDescriptor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = try reflectRequireObject(ctx, "getOwnPropertyDescriptor", arg(args, 0));
    return objectGetOwnPropertyDescriptor(ctx, allocator, this_value, args);
}

fn reflectApply(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = arg(args, 0);
    const this_arg = arg(args, 1);
    const arg_list = arg(args, 2);
    const call_args: []const JSValue = switch (arg_list) {
        .undefined, .null => &.{},
        .array => |box| box.value.toSlice(),
        else => return self.throwError(.type_error, "CreateListFromArrayLike called on non-object", .{}),
    };
    return self.callValue(target, this_arg, call_args, "target");
}

fn reflectConstruct(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = arg(args, 0);
    const arg_list = arg(args, 1);
    const call_args: []const JSValue = switch (arg_list) {
        .undefined, .null => &.{},
        .array => |box| box.value.toSlice(),
        else => return self.throwError(.type_error, "CreateListFromArrayLike called on non-object", .{}),
    };
    if (!self.isConstructor(target)) {
        return self.throwError(.type_error, "target is not a constructor", .{});
    }
    const new_target_arg = arg(args, 2);
    const new_target: JSValue = if (new_target_arg == .undefined) target else new_target_arg;
    if (!self.isConstructor(new_target)) {
        return self.throwError(.type_error, "newTarget is not a constructor", .{});
    }
    // Narrowing: newTarget's distinct-prototype-source subclassing
    // behavior is not modeled -- constructValue always uses `target`'s
    // own prototype, matching plain `new target`.
    return self.constructValue(target, call_args, "target");
}

/// Installs the `Reflect` namespace (statics-only, no constructor).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "Reflect", .statics = &.{
        .{ .name = "get", .value = .{ .method = .{ .call = reflectGet, .arity = 2 } } },
        .{ .name = "set", .value = .{ .method = .{ .call = reflectSet, .arity = 3 } } },
        .{ .name = "has", .value = .{ .method = .{ .call = reflectHas, .arity = 2 } } },
        .{ .name = "deleteProperty", .value = .{ .method = .{ .call = reflectDeleteProperty, .arity = 2 } } },
        .{ .name = "ownKeys", .value = .{ .method = .{ .call = reflectOwnKeys, .arity = 1 } } },
        .{ .name = "getPrototypeOf", .value = .{ .method = .{ .call = reflectGetPrototypeOf, .arity = 1 } } },
        .{ .name = "defineProperty", .value = .{ .method = .{ .call = reflectDefineProperty, .arity = 3 } } },
        .{ .name = "getOwnPropertyDescriptor", .value = .{ .method = .{ .call = reflectGetOwnPropertyDescriptor, .arity = 2 } } },
        .{ .name = "apply", .value = .{ .method = .{ .call = reflectApply, .arity = 3 } } },
        .{ .name = "construct", .value = .{ .method = .{ .call = reflectConstruct, .arity = 2 } } },
    } });
}
