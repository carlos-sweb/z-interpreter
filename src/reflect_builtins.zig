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
const property_desc = @import("property_desc.zig");

const interp = native_helpers.interp;
const arg = native_helpers.arg;
const installBuiltin = builtin_helpers.installBuiltin;
const isObjectLike = builtin_helpers.isObjectLike;
const definePropertyOn = object_builtins.definePropertyOn;
const objectGetOwnPropertyDescriptor = object_builtins.objectGetOwnPropertyDescriptor;
const objectGetOwnPropertyNames = object_builtins.objectGetOwnPropertyNames;
const objectGetOwnPropertySymbols = object_builtins.objectGetOwnPropertySymbols;
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
/// Real spec's [[OwnPropertyKeys]]: every string key (integer indices
/// ascending, then the rest in creation order -- objectGetOwnPropertyNames
/// already gets that part right) FOLLOWED BY every symbol key (creation
/// order). objectGetOwnPropertyNames deliberately excludes symbols
/// (correct for its own real name, Object.getOwnPropertyNames), so
/// Reflect.ownKeys can't just delegate to it alone -- confirmed against
/// real Node that a plain object with both string and symbol own
/// properties returns both from Reflect.ownKeys, in that order.
fn reflectOwnKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const target = try reflectRequireObject(ctx, "ownKeys", arg(args, 0));
    if (target == .proxy) {
        return object_builtins.proxyOwnPropertyKeys(interp(ctx), allocator, target);
    }
    const names = try objectGetOwnPropertyNames(ctx, allocator, this_value, args);
    const symbols = try objectGetOwnPropertySymbols(ctx, allocator, this_value, args);
    defer symbols.deinit();
    for (symbols.array.value.toSlice()) |s| _ = try names.array.value.push(s.retain());
    return names;
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
    var d = try property_desc.toPropertyDescriptor(self, arg(args, 2));
    defer d.deinit();
    const ok = try property_desc.defineOwnProperty(self, target, key, &d);
    return JSValue.fromBool(ok);
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
    return self.constructValueWithNewTarget(target, call_args, new_target, "target");
}

fn reflectSetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "setPrototypeOf", arg(args, 0));
    const proto = arg(args, 1);
    if (proto != .object and proto != .null) {
        return self.throwError(.type_error, "Object prototype may only be an Object or null", .{});
    }
    const ok = object_builtins.setPrototypeOfInternal(self, target, proto) catch |err| switch (err) {
        error.PrototypeCycle, error.ObjectNotExtensible => false,
        else => return err,
    };
    return JSValue.fromBool(ok);
}

/// Installs the `Reflect` namespace (statics-only, no constructor).
pub fn install(self: *Interpreter) !void {
    const reflect_obj = try installBuiltin(self, .{ .name = "Reflect", .statics = &.{
        .{ .name = "get", .value = .{ .method = .{ .call = reflectGet, .arity = 2 } } },
        .{ .name = "set", .value = .{ .method = .{ .call = reflectSet, .arity = 3 } } },
        .{ .name = "has", .value = .{ .method = .{ .call = reflectHas, .arity = 2 } } },
        .{ .name = "deleteProperty", .value = .{ .method = .{ .call = reflectDeleteProperty, .arity = 2 } } },
        .{ .name = "ownKeys", .value = .{ .method = .{ .call = reflectOwnKeys, .arity = 1 } } },
        .{ .name = "getPrototypeOf", .value = .{ .method = .{ .call = reflectGetPrototypeOf, .arity = 1 } } },
        .{ .name = "setPrototypeOf", .value = .{ .method = .{ .call = reflectSetPrototypeOf, .arity = 2 } } },
        .{ .name = "defineProperty", .value = .{ .method = .{ .call = reflectDefineProperty, .arity = 3 } } },
        .{ .name = "getOwnPropertyDescriptor", .value = .{ .method = .{ .call = reflectGetOwnPropertyDescriptor, .arity = 2 } } },
        .{ .name = "apply", .value = .{ .method = .{ .call = reflectApply, .arity = 3 } } },
        .{ .name = "construct", .value = .{ .method = .{ .call = reflectConstruct, .arity = 2 } } },
    } });
    if (self.symbol_to_string_tag) |tag_sym| {
        const tag_key = try self.encodeKey(tag_sym);
        defer self.gc_allocator.free(tag_key);
        try reflect_obj.object.value.defineProperty(tag_key, try self.gcNewString("Reflect"), .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        });
    }
}
