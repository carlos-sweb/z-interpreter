//! Explicit Resource Management: `DisposableStack` (ES2025/Stage 3).
//! Internal stack state lives in `Interpreter.object_slots`
//! (`.disposable_stack`) so GC marks/sweeps all retained disposables
//! automatically without adding a new JSValue tag.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const DisposableEntry = interpreter_mod.DisposableEntry;
const DisposableStackState = interpreter_mod.DisposableStackState;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const property_desc = @import("property_desc.zig");
const error_builtins = @import("error_builtins.zig");

const interp = native_helpers.interp;
const arg = native_helpers.arg;
const method_attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };
const tag_attrs = zvalue.PropertyDescriptor{ .writable = false, .enumerable = false, .configurable = true };

fn requireDisposableStack(self: *Interpreter, this_value: JSValue) !*DisposableStackState {
    if (this_value.tag() != .object) {
        return self.throwError(.type_error, "Method called on incompatible receiver", .{});
    }
    const slots = self.object_slots.get(@intFromPtr(this_value.asObject())) orelse {
        return self.throwError(.type_error, "Method called on incompatible receiver", .{});
    };
    return switch (slots) {
        .disposable_stack => |ds| ds,
        else => self.throwError(.type_error, "Method called on incompatible receiver", .{}),
    };
}

fn disposableStackConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    if (self.construct_target != ctx or this_value.tag() != .object) {
        return self.throwError(.type_error, "Constructor DisposableStack requires 'new'", .{});
    }
    const state = try self.gc_allocator.create(DisposableStackState);
    state.* = .{};
    errdefer self.gc_allocator.destroy(state);
    try self.object_slots.put(self.gc_allocator, @intFromPtr(this_value.asObject()), .{ .disposable_stack = state });
    return this_value.retain();
}

fn disposableStackDisposedGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const ds = try requireDisposableStack(self, this_value);
    return JSValue.fromBool(ds.disposed);
}

fn disposableStackUse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const ds = try requireDisposableStack(self, this_value);
    if (ds.disposed) return self.throwError(.reference_error, "DisposableStack is already disposed", .{});
    const v = arg(args, 0);
    if (v.isUndefined() or v.isNull()) return v.retain();
    if (!builtin_helpers.isObjectLike(v)) {
        return self.throwError(.type_error, "Object expected in DisposableStack.prototype.use", .{});
    }
    const sym = self.symbol_dispose orelse return self.throwError(.type_error, "Symbol.dispose is not defined", .{});
    const key = try self.encodeKey(sym);
    defer self.gc_allocator.free(key);
    const method = try self.getProperty(v, key);
    errdefer method.deinit();
    if (method.isUndefined() or method.isNull()) {
        return self.throwError(.type_error, "Object is not disposable", .{});
    }
    if (!property_desc.isCallable(method)) {
        return self.throwError(.type_error, "Symbol.dispose is not a function", .{});
    }
    try ds.stack.append(self.gc_allocator, .{ .value = v.retain(), .method = method, .has_arg = false });
    return v.retain();
}

fn disposableStackAdopt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const ds = try requireDisposableStack(self, this_value);
    if (ds.disposed) return self.throwError(.reference_error, "DisposableStack is already disposed", .{});
    const on_dispose = arg(args, 1);
    if (!property_desc.isCallable(on_dispose)) {
        return self.throwError(.type_error, "onDispose is not a function", .{});
    }
    const v = arg(args, 0);
    try ds.stack.append(self.gc_allocator, .{ .value = v.retain(), .method = on_dispose.retain(), .has_arg = true });
    return v.retain();
}

fn disposableStackDefer(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const ds = try requireDisposableStack(self, this_value);
    if (ds.disposed) return self.throwError(.reference_error, "DisposableStack is already disposed", .{});
    const on_dispose = arg(args, 0);
    if (!property_desc.isCallable(on_dispose)) {
        return self.throwError(.type_error, "onDispose is not a function", .{});
    }
    try ds.stack.append(self.gc_allocator, .{ .value = JSValue.UNDEFINED, .method = on_dispose.retain(), .has_arg = false });
    return JSValue.UNDEFINED;
}

fn disposableStackMove(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const ds = try requireDisposableStack(self, this_value);
    if (ds.disposed) return self.throwError(.reference_error, "DisposableStack is already disposed", .{});

    var new_obj = try self.gcNewObject();
    errdefer new_obj.deinit();
    if (self.protos.disposable_stack.tag() == .object) {
        try new_obj.asObject().value.setPrototype(&self.protos.disposable_stack.asObject().value);
    }
    const new_state = try self.gc_allocator.create(DisposableStackState);
    new_state.* = .{ .disposed = false, .stack = ds.stack };
    errdefer self.gc_allocator.destroy(new_state);
    try self.object_slots.put(self.gc_allocator, @intFromPtr(new_obj.asObject()), .{ .disposable_stack = new_state });
    ds.stack = .empty;
    ds.disposed = true;
    return new_obj;
}

fn disposableStackDispose(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const ds = try requireDisposableStack(self, this_value);
    if (ds.disposed) return JSValue.UNDEFINED;
    ds.disposed = true;
    var entries = ds.stack;
    ds.stack = .empty;

    var has_err = false;
    var current_err = JSValue.UNDEFINED;
    errdefer if (has_err) current_err.deinit();

    var i = entries.items.len;
    defer {
        while (i > 0) {
            i -= 1;
            entries.items[i].value.deinit();
            entries.items[i].method.deinit();
        }
        entries.deinit(self.gc_allocator);
    }
    while (i > 0) {
        i -= 1;
        const entry: DisposableEntry = entries.items[i];
        defer {
            entry.value.deinit();
            entry.method.deinit();
        }
        const call_res = if (entry.has_arg)
            self.callValue(entry.method, JSValue.UNDEFINED, &.{entry.value}, "onDispose")
        else
            self.callValue(entry.method, entry.value, &.{}, "dispose");

        if (call_res) |r| {
            r.deinit();
        } else |err0| {
            const err = self.throwIfGap(err0);
            if (err != error.JsThrow) return err;
            const caught = self.pending_exception orelse JSValue.UNDEFINED;
            self.pending_exception = null;
            if (has_err) {
                const sup = error_builtins.newSuppressedError(self, caught, current_err, "An error was suppressed during disposal") catch |alloc_err| {
                    caught.deinit();
                    return alloc_err;
                };
                caught.deinit();
                current_err.deinit();
                current_err = sup;
            } else {
                current_err = caught;
                has_err = true;
            }
        }
    }
    if (has_err) {
        const err_to_throw = current_err;
        has_err = false;
        return self.throwValue(err_to_throw);
    }
    return JSValue.UNDEFINED;
}

pub fn install(self: *Interpreter) !void {
    const ctor = try builtin_helpers.installBuiltin(self, .{
        .name = "DisposableStack",
        .ctor = .{ .arity = 0, .call = disposableStackConstructor, .constructable = true },
    });
    const proto = try self.functionPrototype(ctor);
    if (self.protos.object.tag() == .object) {
        try proto.asObject().value.setPrototype(&self.protos.object.asObject().value);
    }
    try proto.asObject().value.defineProperty("constructor", ctor.retain(), method_attrs);

    const disposed_getter = try self.nativeMethod("disposable_stack", "get disposed", 0, disposableStackDisposedGetter);
    try proto.asObject().value.defineAccessor("disposed", disposed_getter, null, JSValue.UNDEFINED);
    if (proto.asObject().value.getOwnRecordMut("disposed")) |rec| {
        rec.descriptor.enumerable = false;
        rec.descriptor.configurable = true;
    }

    try proto.asObject().value.defineProperty("use", try self.nativeMethod("disposable_stack", "use", 1, disposableStackUse), method_attrs);
    try proto.asObject().value.defineProperty("adopt", try self.nativeMethod("disposable_stack", "adopt", 2, disposableStackAdopt), method_attrs);
    try proto.asObject().value.defineProperty("defer", try self.nativeMethod("disposable_stack", "defer", 1, disposableStackDefer), method_attrs);
    try proto.asObject().value.defineProperty("move", try self.nativeMethod("disposable_stack", "move", 0, disposableStackMove), method_attrs);

    const dispose_fn = try self.nativeMethod("disposable_stack", "dispose", 0, disposableStackDispose);
    try proto.asObject().value.defineProperty("dispose", dispose_fn, method_attrs);
    if (self.symbol_dispose) |sym| {
        const disp_key = try self.encodeKey(sym);
        defer self.gc_allocator.free(disp_key);
        try proto.asObject().value.defineProperty(disp_key, dispose_fn.retain(), method_attrs);
    }
    if (self.symbol_to_string_tag) |tag_sym| {
        const tag_key = try self.encodeKey(tag_sym);
        defer self.gc_allocator.free(tag_key);
        try proto.asObject().value.defineProperty(tag_key, try self.gcNewString("DisposableStack"), tag_attrs);
    }
    self.protos.disposable_stack = proto;
}
