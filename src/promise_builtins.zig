//! `Promise`, `.then`/`.catch`/`.finally`, `Promise.resolve`/`reject`/
//! `all`/`race`, and `setTimeout`/`clearTimeout` -- grouped per README's
//! "Promises, the microtask queue, and timers" section (z-interpreter-
//! refactor.md, Step 5 Phase A).

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
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const dneMethod = builtin_helpers.dneMethod;
const dneConst = builtin_helpers.dneConst;
const requireTag = builtin_helpers.requireTag;
const installBuiltin = builtin_helpers.installBuiltin;

pub const promise_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "then", promiseThen },
    .{ "catch", promiseCatch },
    .{ "finally", promiseFinally },
});

/// The pair of capabilities `new Promise(executor)` hands the executor.
pub const PromiseCapCtx = struct {
    interp: *Interpreter,
    promise: JSValue,
};

fn capCtx(ctx: *anyopaque) *PromiseCapCtx {
    return @ptrCast(@alignCast(ctx));
}

fn capResolve(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c = capCtx(ctx);
    try c.interp.resolvePromise(c.promise, arg(args, 0));
    return JSValue.UNDEFINED;
}

fn capReject(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c = capCtx(ctx);
    try c.interp.rejectPromiseValue(c.promise, arg(args, 0));
    return JSValue.UNDEFINED;
}

/// `new Promise(executor)`: executor runs SYNCHRONOUSLY (real spec
/// behavior -- logs inside it appear before the line after `new`); its
/// throw rejects. Calling Promise without `new` also works here (real JS
/// requires new -- documented narrowing).
fn promiseConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const executor = arg(args, 0);
    if (executor != .function) {
        return self.throwError(.type_error, "Promise resolver {s} is not a function", .{executor.typeOf()});
    }
    const p = try interp(ctx).gcNewPromise();

    const cap = try allocator.create(PromiseCapCtx);
    cap.* = .{ .interp = self, .promise = p };
    try self.gcTrackPromiseCapCtx(cap);
    const resolve_fn = try interp(ctx).gcNewFunction(.{ .ctx = cap, .name = "resolve", .arity = 1, .call = capResolve });
    const reject_fn = try interp(ctx).gcNewFunction(.{ .ctx = cap, .name = "reject", .arity = 1, .call = capReject });

    _ = executor.function.value.call(executor.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ resolve_fn, reject_fn }) catch |err| {
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception.?;
        self.pending_exception = null;
        try self.rejectPromiseValue(p, ex);
    };
    return p;
}

fn requirePromise(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    return requireTag(ctx, this_value, .promise, "Promise.prototype.{s} called on a non-promise", method);
}

/// Non-callable handlers are the spec's pass-through (then(null, f) etc).
fn handlerOrNull(v: JSValue) ?JSValue {
    return if (v == .function) v else null;
}

fn promiseThen(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const p = try requirePromise(ctx, this_value, "then");
    return interp(ctx).promiseThen(p, handlerOrNull(arg(args, 0)), handlerOrNull(arg(args, 1)));
}

fn promiseCatch(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const p = try requirePromise(ctx, this_value, "catch");
    return interp(ctx).promiseThen(p, null, handlerOrNull(arg(args, 0)));
}

/// finally(f) = then(wrapper, wrapper) where each wrapper calls f() with
/// no arguments and passes the original settlement through -- the
/// rejection side by re-throwing the original reason. f's own throw
/// replaces the settlement (both spec behaviors), for free, because the
/// job runner already turns a handler throw into a derived rejection.
pub const FinallyCtx = struct {
    interp: *Interpreter,
    handler: JSValue,
};

fn finallyCtx(ctx: *anyopaque) *FinallyCtx {
    return @ptrCast(@alignCast(ctx));
}

fn finallyOnFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c = finallyCtx(ctx);
    _ = try c.handler.function.value.call(c.handler.function.value.ctx, allocator, JSValue.UNDEFINED, &.{});
    return arg(args, 0);
}

fn finallyOnRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c = finallyCtx(ctx);
    _ = try c.handler.function.value.call(c.handler.function.value.ctx, allocator, JSValue.UNDEFINED, &.{});
    return c.interp.throwValue(arg(args, 0).retain());
}

fn promiseFinally(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const p = try requirePromise(ctx, this_value, "finally");
    const self = interp(ctx);
    const handler = handlerOrNull(arg(args, 0)) orelse return self.promiseThen(p, null, null);

    const c = try allocator.create(FinallyCtx);
    c.* = .{ .interp = self, .handler = handler.retain() };
    try self.gcTrackFinallyCtx(c);
    const on_f = try interp(ctx).gcNewFunction(.{ .ctx = c, .name = "", .call = finallyOnFulfilled });
    const on_r = try interp(ctx).gcNewFunction(.{ .ctx = c, .name = "", .call = finallyOnRejected });
    return self.promiseThen(p, on_f, on_r);
}

fn promiseResolveStatic(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    // Promise.resolve(promise) returns it unchanged (real behavior).
    if (v == .promise) return v;
    return interp(ctx).fulfilledPromise(v);
}

fn promiseRejectStatic(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    return interp(ctx).rejectedPromise(arg(args, 0));
}

/// Shared bookkeeping for one Promise.all call.
pub const AllCtx = struct {
    interp: *Interpreter,
    remaining: usize,
    results: []JSValue,
    derived: JSValue,

    fn completeIfDone(c: *AllCtx) anyerror!void {
        if (c.remaining != 0) return;
        var array = try c.interp.gcNewArray();
        for (c.results) |r| _ = try array.array.value.push(r.retain());
        try c.interp.resolvePromise(c.derived, array);
    }
};

/// Per-element fulfillment handler: stores at its index, resolves the
/// derived array when the last one lands.
pub const AllElemCtx = struct {
    all: *AllCtx,
    index: usize,
};

fn allElemFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *AllElemCtx = @ptrCast(@alignCast(ctx));
    c.all.results[c.index] = arg(args, 0).retain();
    c.all.remaining -= 1;
    try c.all.completeIfDone();
    return JSValue.UNDEFINED;
}

fn allRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *AllCtx = @ptrCast(@alignCast(ctx));
    // First rejection wins; settle idempotence makes later ones no-ops.
    try c.interp.rejectPromiseValue(c.derived, arg(args, 0));
    return JSValue.UNDEFINED;
}

/// Promise.all over an ARRAY (narrowed -- general iterables need the
/// Symbol.iterator protocol this ecosystem doesn't have). Order is
/// preserved by index; rejection is fail-fast.
fn promiseAll(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const input = arg(args, 0);
    if (input != .array) return self.throwError(.type_error, "{s} is not iterable", .{input.typeOf()});
    const items = input.array.value.toSlice();

    const derived = try interp(ctx).gcNewPromise();
    const all = try allocator.create(AllCtx);
    all.* = .{
        .interp = self,
        .remaining = items.len,
        .results = try allocator.alloc(JSValue, items.len),
        .derived = derived,
    };
    try self.gcTrackAllCtx(all);
    for (all.results) |*r| r.* = JSValue.UNDEFINED;
    if (items.len == 0) {
        try all.completeIfDone();
        return derived;
    }

    const on_r = try interp(ctx).gcNewFunction(.{ .ctx = all, .name = "", .call = allRejected });
    for (items, 0..) |item, i| {
        const elem = try allocator.create(AllElemCtx);
        elem.* = .{ .all = all, .index = i };
        try self.gcTrackAllElemCtx(elem);
        const on_f = try interp(ctx).gcNewFunction(.{ .ctx = elem, .name = "", .call = allElemFulfilled });
        const p = if (item == .promise) item else try self.fulfilledPromise(item);
        _ = try self.promiseThen(p, on_f, on_r);
    }
    return derived;
}

/// Per-race resolution handler: first settle of ANY element settles the
/// derived promise; the rest are silent no-ops via settle idempotence.
pub const RaceCtx = struct {
    interp: *Interpreter,
    derived: JSValue,
};

fn raceFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *RaceCtx = @ptrCast(@alignCast(ctx));
    try c.interp.resolvePromise(c.derived, arg(args, 0));
    return JSValue.UNDEFINED;
}

fn raceRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *RaceCtx = @ptrCast(@alignCast(ctx));
    try c.interp.rejectPromiseValue(c.derived, arg(args, 0));
    return JSValue.UNDEFINED;
}

fn promiseRace(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const input = arg(args, 0);
    if (input != .array) return self.throwError(.type_error, "{s} is not iterable", .{input.typeOf()});

    const derived = try interp(ctx).gcNewPromise();
    const rc = try allocator.create(RaceCtx);
    rc.* = .{ .interp = self, .derived = derived };
    try self.gcTrackRaceCtx(rc);
    const on_f = try interp(ctx).gcNewFunction(.{ .ctx = rc, .name = "", .call = raceFulfilled });
    const on_r = try interp(ctx).gcNewFunction(.{ .ctx = rc, .name = "", .call = raceRejected });
    for (input.array.value.toSlice()) |item| {
        const p = if (item == .promise) item else try self.fulfilledPromise(item);
        _ = try self.promiseThen(p, on_f, on_r);
    }
    return derived;
}

fn globalSetTimeout(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const cb = arg(args, 0);
    if (cb != .function) return self.throwError(.type_error, "The \"callback\" argument must be of type function", .{});
    const delay = if (arg(args, 1) == .number) arg(args, 1).number else 0;
    return JSValue.fromNumber(try self.addTimer(cb, delay));
}

fn globalClearTimeout(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    if (arg(args, 0) == .number) interp(ctx).clearTimer(arg(args, 0).number);
    return JSValue.UNDEFINED;
}

/// Installs the `Promise` constructor + statics and the timer globals.
pub fn install(self: *Interpreter) !void {
    const arena = self.gc_allocator;
    const g = self.global_env;

    // Promise: constructable native; the statics (resolve/reject/all/
    // race) ride the phase-10 property bag.
    _ = try installBuiltin(self, .{ .name = "Promise", .ctor = .{ .arity = 1, .call = promiseConstructor, .constructable = true }, .statics = &.{
        .{ .name = "resolve", .value = .{ .method = promiseResolveStatic } },
        .{ .name = "reject", .value = .{ .method = promiseRejectStatic } },
        .{ .name = "all", .value = .{ .method = promiseAll } },
        .{ .name = "race", .value = .{ .method = promiseRace } },
    } });

    try g.define(arena, "setTimeout", try native(self, "setTimeout", globalSetTimeout));
    try g.define(arena, "clearTimeout", try native(self, "clearTimeout", globalClearTimeout));
}
