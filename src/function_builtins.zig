//! `Function.prototype.call`/`.apply`/`.bind`, and the `Function`
//! constructor (`new Function('a', 'return a')` -- a bounded eval).
//! z-interpreter-refactor.md, Step 5 Phase A.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zbigint = @import("zbigint");
const zfunctions = @import("zfunctions");
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
const dneMethod = builtin_helpers.dneMethod;
const dneConst = builtin_helpers.dneConst;
const requireTag = builtin_helpers.requireTag;
const installBuiltin = builtin_helpers.installBuiltin;

pub const function_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "call", MethodSpec{ .call = fnCall, .arity = 1 } },
    .{ "apply", MethodSpec{ .call = fnApply, .arity = 2 } },
    .{ "bind", MethodSpec{ .call = fnBind, .arity = 1 } },
});

fn requireFunction(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    return requireTag(ctx, this_value, .function, "Function.prototype.{s} called on a non-function", method);
}

fn fnCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const target = try requireFunction(ctx, this_value, "call");
    const this_arg = arg(args, 0);
    const rest = if (args.len > 1) args[1..] else &[_]JSValue{};
    return target.function.value.call(target.function.value.ctx, allocator, this_arg, rest);
}

fn fnApply(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const target = try requireFunction(ctx, this_value, "apply");
    const this_arg = arg(args, 0);
    const arg_list = arg(args, 1);
    const call_args: []const JSValue = switch (arg_list) {
        .undefined, .null => &.{},
        .array => |box| box.value.toSlice(),
        else => return interp(ctx).throwError(.type_error, "CreateListFromArrayLike called on non-object", .{}),
    };
    return target.function.value.call(target.function.value.ctx, allocator, this_arg, call_args);
}

/// ctx for one bound function: the target, the fixed this, and any
/// pre-applied arguments.
pub const BoundCtx = struct {
    target: JSValue,
    bound_this: JSValue,
    pre_args: []const JSValue,
    /// Owned (formatted fresh per `.bind()` call -- "bound " ++ target's
    /// name); freed alongside the ctx itself, see freeGarbageNode's
    /// `.bound_ctx` case. Unlike every other `Callable.name` in this file
    /// (always a string literal or AST-borrowed slice), this one is real
    /// heap memory that needs an owner.
    name: []const u8,
};

fn boundCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value; // a bound function ignores its call-site this (spec)
    const bc: *BoundCtx = @ptrCast(@alignCast(ctx));
    const total = try allocator.alloc(JSValue, bc.pre_args.len + args.len);
    defer allocator.free(total);
    @memcpy(total[0..bc.pre_args.len], bc.pre_args);
    @memcpy(total[bc.pre_args.len..], args);
    return bc.target.function.value.call(bc.target.function.value.ctx, allocator, bc.bound_this, total);
}

/// Narrowed [[Bind]]: the bound function is NOT constructable (real
/// bound functions are; `new (f.bind(x))()` is a documented gap).
fn fnBind(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const target = try requireFunction(ctx, this_value, "bind");
    const bc = try allocator.create(BoundCtx);
    const pre = if (args.len > 1) args[1..] else &[_]JSValue{};
    const pre_copy = try allocator.alloc(JSValue, pre.len);
    for (pre, 0..) |a, i| pre_copy[i] = a.retain();
    const name = try std.fmt.allocPrint(allocator, "bound {s}", .{target.function.value.name});
    bc.* = .{
        .target = target.retain(),
        .bound_this = arg(args, 0).retain(),
        .pre_args = pre_copy,
        .name = name,
    };
    try interp(ctx).gcTrackBoundCtx(bc);
    const target_arity = target.function.value.arity;
    const bound_arity = if (target_arity > pre.len) target_arity - pre.len else 0;
    return interp(ctx).gcNewFunction(.{
        .ctx = bc,
        .name = name,
        .arity = bound_arity,
        .call = boundCall,
    });
}

/// `new Function('a', 'b', 'return a + b')` -- compose, parse with the
/// real parser, close over the global env. A bounded eval.
fn functionConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(allocator, "(function anonymous(");
    if (args.len > 1) {
        for (args[0 .. args.len - 1], 0..) |a, i| {
            if (i != 0) try src.appendSlice(allocator, ", ");
            const s = try coercion.toDisplayString(allocator, a);
            defer allocator.free(s);
            try src.appendSlice(allocator, s);
        }
    }
    try src.appendSlice(allocator, "\n) {\n");
    if (args.len > 0) {
        const body = try coercion.toDisplayString(allocator, args[args.len - 1]);
        defer allocator.free(body);
        try src.appendSlice(allocator, body);
    }
    try src.appendSlice(allocator, "\n})");

    const parser = zfunctions.Parser.init(allocator, src.items) catch {
        return self.throwError(.syntax_error, "Invalid function source", .{});
    };
    const node = parser.parseExpression() catch |err| {
        return self.throwError(.syntax_error, "Function constructor: {s}", .{@errorName(err)});
    };
    const fnode_ptr = switch (node.data) {
        .paren => |inner| switch (inner.data) {
            .function_like => |ptr| ptr,
            else => return self.throwError(.syntax_error, "Invalid function source", .{}),
        },
        else => return self.throwError(.syntax_error, "Invalid function source", .{}),
    };
    return self.makeClosure(self.global_env, zfunctions.asFunctionNode(fnode_ptr));
}

/// Installs the `Function` constructor (no statics).
pub fn install(self: *Interpreter) !void {
    // Function: a constructor that PARSES -- new Function('a', 'return a')
    // composes and compiles a real closure (a bounded eval). Its
    // .prototype carries the cached call/apply/bind for the detached
    // harness pattern.
    _ = try installBuiltin(self, .{ .name = "Function", .ctor = .{ .arity = 1, .call = functionConstructor, .constructable = true } });
}
