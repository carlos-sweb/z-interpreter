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
const AsyncDisposeRunner = interpreter_mod.AsyncDisposeRunner;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const property_desc = @import("property_desc.zig");
const error_builtins = @import("error_builtins.zig");
const promise_builtins = @import("promise_builtins.zig");

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

    try installAsync(self);
}

// ===== AsyncDisposableStack =====

fn requireAsyncDisposableStack(self: *Interpreter, this_value: JSValue) !*DisposableStackState {
    if (this_value.tag() != .object) {
        return self.throwError(.type_error, "Method called on incompatible receiver", .{});
    }
    const slots = self.object_slots.get(@intFromPtr(this_value.asObject())) orelse {
        return self.throwError(.type_error, "Method called on incompatible receiver", .{});
    };
    return switch (slots) {
        .async_disposable_stack => |ds| ds,
        else => self.throwError(.type_error, "Method called on incompatible receiver", .{}),
    };
}

fn asyncDisposableStackConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    if (self.construct_target != ctx or this_value.tag() != .object) {
        return self.throwError(.type_error, "Constructor AsyncDisposableStack requires 'new'", .{});
    }
    const state = try self.gc_allocator.create(DisposableStackState);
    state.* = .{};
    errdefer self.gc_allocator.destroy(state);
    try self.object_slots.put(self.gc_allocator, @intFromPtr(this_value.asObject()), .{ .async_disposable_stack = state });
    return this_value.retain();
}

fn asyncDisposableStackDisposedGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const ds = try requireAsyncDisposableStack(self, this_value);
    return JSValue.fromBool(ds.disposed);
}

fn asyncDisposableStackUse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const ds = try requireAsyncDisposableStack(self, this_value);
    if (ds.disposed) return self.throwError(.reference_error, "AsyncDisposableStack is already disposed", .{});
    const v = arg(args, 0);
    if (v.isUndefined() or v.isNull()) {
        try ds.stack.append(self.gc_allocator, .{
            .value = JSValue.UNDEFINED,
            .method = JSValue.UNDEFINED,
            .has_arg = false,
            .mode = .dummy,
        });
        return v.retain();
    }
    if (!builtin_helpers.isObjectLike(v)) {
        return self.throwError(.type_error, "Object expected in AsyncDisposableStack.prototype.use", .{});
    }
    const async_sym = self.symbol_async_dispose orelse return self.throwError(.type_error, "Symbol.asyncDispose is not defined", .{});
    const async_key = try self.encodeKey(async_sym);
    defer self.gc_allocator.free(async_key);
    const async_method = try self.getProperty(v, async_key);
    if (!async_method.isUndefined() and !async_method.isNull()) {
        errdefer async_method.deinit();
        if (!property_desc.isCallable(async_method)) {
            return self.throwError(.type_error, "Symbol.asyncDispose is not a function", .{});
        }
        try ds.stack.append(self.gc_allocator, .{
            .value = v.retain(),
            .method = async_method,
            .has_arg = false,
            .mode = .async_method,
        });
        return v.retain();
    }
    async_method.deinit();

    const sync_sym = self.symbol_dispose orelse return self.throwError(.type_error, "Symbol.dispose is not defined", .{});
    const sync_key = try self.encodeKey(sync_sym);
    defer self.gc_allocator.free(sync_key);
    const sync_method = try self.getProperty(v, sync_key);
    errdefer sync_method.deinit();
    if (sync_method.isUndefined() or sync_method.isNull()) {
        return self.throwError(.type_error, "Object is not disposable", .{});
    }
    if (!property_desc.isCallable(sync_method)) {
        return self.throwError(.type_error, "Symbol.dispose is not a function", .{});
    }
    try ds.stack.append(self.gc_allocator, .{
        .value = v.retain(),
        .method = sync_method,
        .has_arg = false,
        .mode = .sync_fallback,
    });
    return v.retain();
}

fn asyncDisposableStackAdopt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const ds = try requireAsyncDisposableStack(self, this_value);
    if (ds.disposed) return self.throwError(.reference_error, "AsyncDisposableStack is already disposed", .{});
    const on_dispose = arg(args, 1);
    if (!property_desc.isCallable(on_dispose)) {
        return self.throwError(.type_error, "onDispose is not a function", .{});
    }
    const v = arg(args, 0);
    try ds.stack.append(self.gc_allocator, .{
        .value = v.retain(),
        .method = on_dispose.retain(),
        .has_arg = true,
        .mode = .async_method,
    });
    return v.retain();
}

fn asyncDisposableStackDefer(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const ds = try requireAsyncDisposableStack(self, this_value);
    if (ds.disposed) return self.throwError(.reference_error, "AsyncDisposableStack is already disposed", .{});
    const on_dispose = arg(args, 0);
    if (!property_desc.isCallable(on_dispose)) {
        return self.throwError(.type_error, "onDispose is not a function", .{});
    }
    try ds.stack.append(self.gc_allocator, .{
        .value = JSValue.UNDEFINED,
        .method = on_dispose.retain(),
        .has_arg = false,
        .mode = .async_method,
    });
    return JSValue.UNDEFINED;
}

fn asyncDisposableStackMove(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const ds = try requireAsyncDisposableStack(self, this_value);
    if (ds.disposed) return self.throwError(.reference_error, "AsyncDisposableStack is already disposed", .{});

    var new_obj = try self.gcNewObject();
    errdefer new_obj.deinit();
    if (self.protos.async_disposable_stack.tag() == .object) {
        try new_obj.asObject().value.setPrototype(&self.protos.async_disposable_stack.asObject().value);
    }
    const new_state = try self.gc_allocator.create(DisposableStackState);
    new_state.* = .{ .disposed = false, .stack = ds.stack };
    errdefer self.gc_allocator.destroy(new_state);
    try self.object_slots.put(self.gc_allocator, @intFromPtr(new_obj.asObject()), .{ .async_disposable_stack = new_state });
    ds.stack = .empty;
    ds.disposed = true;
    return new_obj;
}

fn recordAsyncError(self: *Interpreter, r: *AsyncDisposeRunner, err_val: JSValue) !void {
    if (r.has_err) {
        const sup = try error_builtins.newSuppressedError(self, err_val, r.current_err, "An error was suppressed during disposal");
        r.current_err.deinit();
        r.current_err = sup;
    } else {
        r.current_err = err_val.retain();
        r.has_err = true;
    }
}

fn asyncDisposeOnFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    const c: *promise_builtins.FinallyCtx = @ptrCast(@alignCast(ctx));
    try advanceAsyncDispose(c.interp, c.handler);
    return JSValue.UNDEFINED;
}

fn asyncDisposeOnRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *promise_builtins.FinallyCtx = @ptrCast(@alignCast(ctx));
    const slots = c.interp.object_slots.get(@intFromPtr(c.handler.asObject())).?;
    try recordAsyncError(c.interp, slots.async_dispose_runner, arg(args, 0));
    try advanceAsyncDispose(c.interp, c.handler);
    return JSValue.UNDEFINED;
}

fn subscribeRunnerStep(self: *Interpreter, runner_obj: JSValue, awaited_val: JSValue) !void {
    const p = try self.gcNewPromise();
    defer p.deinit();
    try self.resolvePromise(p, awaited_val);

    const c = try self.gc_allocator.create(promise_builtins.FinallyCtx);
    c.* = .{ .interp = self, .handler = runner_obj.retain() };
    try self.gcTrackFinallyCtx(c);
    const on_f = try self.gcNewFunction(.{ .ctx = c, .name = "", .arity = 1, .call = asyncDisposeOnFulfilled });
    defer on_f.deinit();
    const on_r = try self.gcNewFunction(.{ .ctx = c, .name = "", .arity = 1, .call = asyncDisposeOnRejected });
    defer on_r.deinit();
    try self.subscribePromise(p, on_f, on_r, null);
}

fn advanceAsyncDispose(self: *Interpreter, runner_obj: JSValue) anyerror!void {
    const slots = self.object_slots.get(@intFromPtr(runner_obj.asObject())).?;
    const r = slots.async_dispose_runner;

    while (r.idx > 0) {
        r.idx -= 1;
        const entry = r.entries.items[r.idx];
        switch (entry.mode) {
            .dummy => {
                r.needs_await = true;
            },
            .sync_fallback => {
                r.needs_await = true;
                const call_res = self.callValue(entry.method, entry.value, &.{}, "dispose");
                if (call_res) |val| {
                    val.deinit();
                    r.has_awaited = true;
                    try subscribeRunnerStep(self, runner_obj, JSValue.UNDEFINED);
                    return;
                } else |err0| {
                    const err = self.throwIfGap(err0);
                    if (err != error.JsThrow) return err;
                    const caught = self.pending_exception orelse JSValue.UNDEFINED;
                    self.pending_exception = null;
                    defer caught.deinit();
                    try recordAsyncError(self, r, caught);
                }
            },
            .async_method, .sync => {
                const call_res = if (entry.has_arg)
                    self.callValue(entry.method, JSValue.UNDEFINED, &.{entry.value}, "onDispose")
                else
                    self.callValue(entry.method, entry.value, &.{}, "asyncDispose");

                if (call_res) |val| {
                    defer val.deinit();
                    r.has_awaited = true;
                    try subscribeRunnerStep(self, runner_obj, val);
                    return;
                } else |err0| {
                    const err = self.throwIfGap(err0);
                    if (err != error.JsThrow) return err;
                    const caught = self.pending_exception orelse JSValue.UNDEFINED;
                    self.pending_exception = null;
                    defer caught.deinit();
                    try recordAsyncError(self, r, caught);
                }
            },
        }
    }

    if (r.needs_await and !r.has_awaited and !r.did_final_await) {
        r.did_final_await = true;
        try subscribeRunnerStep(self, runner_obj, JSValue.UNDEFINED);
        return;
    }

    if (r.has_err) {
        try self.rejectPromiseValue(r.result_promise, r.current_err);
    } else {
        try self.resolvePromise(r.result_promise, JSValue.UNDEFINED);
    }
}

fn asyncDisposableStackDisposeAsync(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const p = try self.gcNewPromise();
    errdefer p.deinit();

    const ds = requireAsyncDisposableStack(self, this_value) catch |err0| {
        const err = self.throwIfGap(err0);
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception orelse JSValue.UNDEFINED;
        self.pending_exception = null;
        defer ex.deinit();
        try self.rejectPromiseValue(p, ex);
        return p;
    };

    if (ds.disposed) {
        try self.resolvePromise(p, JSValue.UNDEFINED);
        return p;
    }
    ds.disposed = true;

    const runner = try self.gc_allocator.create(AsyncDisposeRunner);
    runner.* = .{
        .entries = ds.stack,
        .idx = ds.stack.items.len,
        .result_promise = p.retain(),
    };
    ds.stack = .empty;

    var runner_obj = try self.gcNewObject();
    defer runner_obj.deinit();
    self.object_slots.put(self.gc_allocator, @intFromPtr(runner_obj.asObject()), .{ .async_dispose_runner = runner }) catch |err| {
        runner.entries.deinit(self.gc_allocator);
        self.gc_allocator.destroy(runner);
        return err;
    };

    try advanceAsyncDispose(self, runner_obj);
    return p;
}

fn installAsync(self: *Interpreter) !void {
    const ctor = try builtin_helpers.installBuiltin(self, .{
        .name = "AsyncDisposableStack",
        .ctor = .{ .arity = 0, .call = asyncDisposableStackConstructor, .constructable = true },
    });
    const proto = try self.functionPrototype(ctor);
    if (self.protos.object.tag() == .object) {
        try proto.asObject().value.setPrototype(&self.protos.object.asObject().value);
    }
    try proto.asObject().value.defineProperty("constructor", ctor.retain(), method_attrs);

    const disposed_getter = try self.nativeMethod("async_disposable_stack", "get disposed", 0, asyncDisposableStackDisposedGetter);
    try proto.asObject().value.defineAccessor("disposed", disposed_getter, null, JSValue.UNDEFINED);
    if (proto.asObject().value.getOwnRecordMut("disposed")) |rec| {
        rec.descriptor.enumerable = false;
        rec.descriptor.configurable = true;
    }

    try proto.asObject().value.defineProperty("use", try self.nativeMethod("async_disposable_stack", "use", 1, asyncDisposableStackUse), method_attrs);
    try proto.asObject().value.defineProperty("adopt", try self.nativeMethod("async_disposable_stack", "adopt", 2, asyncDisposableStackAdopt), method_attrs);
    try proto.asObject().value.defineProperty("defer", try self.nativeMethod("async_disposable_stack", "defer", 1, asyncDisposableStackDefer), method_attrs);
    try proto.asObject().value.defineProperty("move", try self.nativeMethod("async_disposable_stack", "move", 0, asyncDisposableStackMove), method_attrs);

    const dispose_fn = try self.nativeMethod("async_disposable_stack", "disposeAsync", 0, asyncDisposableStackDisposeAsync);
    try proto.asObject().value.defineProperty("disposeAsync", dispose_fn, method_attrs);
    if (self.symbol_async_dispose) |sym| {
        const disp_key = try self.encodeKey(sym);
        defer self.gc_allocator.free(disp_key);
        try proto.asObject().value.defineProperty(disp_key, dispose_fn.retain(), method_attrs);
    }
    if (self.symbol_to_string_tag) |tag_sym| {
        const tag_key = try self.encodeKey(tag_sym);
        defer self.gc_allocator.free(tag_key);
        try proto.asObject().value.defineProperty(tag_key, try self.gcNewString("AsyncDisposableStack"), tag_attrs);
    }
    self.protos.async_disposable_stack = proto;
}
