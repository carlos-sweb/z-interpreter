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
const error_builtins = @import("error_builtins.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const dneMethod = builtin_helpers.dneMethod;
const dneConst = builtin_helpers.dneConst;
const requireTag = builtin_helpers.requireTag;
const installBuiltin = builtin_helpers.installBuiltin;

pub const promise_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "then", MethodSpec{ .call = promiseThen, .arity = 2 } },
    .{ "catch", MethodSpec{ .call = promiseCatch, .arity = 1 } },
    .{ "finally", MethodSpec{ .call = promiseFinally, .arity = 1 } },
});

/// The pair of capabilities `new Promise(executor)` hands the executor.
pub const PromiseCapCtx = struct {
    interp: *Interpreter,
    promise: JSValue,
    already_resolved: bool = false,
};

fn capCtx(ctx: *anyopaque) *PromiseCapCtx {
    return @ptrCast(@alignCast(ctx));
}

pub fn capResolve(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c = capCtx(ctx);
    if (c.already_resolved) return JSValue.UNDEFINED;
    c.already_resolved = true;
    try c.interp.resolvePromise(c.promise, arg(args, 0));
    return JSValue.UNDEFINED;
}

pub fn capReject(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c = capCtx(ctx);
    if (c.already_resolved) return JSValue.UNDEFINED;
    c.already_resolved = true;
    try c.interp.rejectPromiseValue(c.promise, arg(args, 0));
    return JSValue.UNDEFINED;
}

pub fn isPromiseConstructor(v: JSValue) bool {
    return v.isFunction() and v.asFunction().value.call == promiseConstructor;
}

/// `new Promise(executor)`: executor runs SYNCHRONOUSLY (real spec
/// behavior -- logs inside it appear before the line after `new`); its
/// throw rejects. Calling Promise without `new` throws a TypeError.
fn promiseConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target == null) {
        return self.throwError(.type_error, "Promise constructor cannot be invoked without 'new'", .{});
    }
    const executor = arg(args, 0);
    if (!executor.isFunction()) {
        return self.throwError(.type_error, "Promise resolver {s} is not a function", .{executor.typeOf()});
    }
    const p = try interp(ctx).gcNewPromise();

    const cap = try allocator.create(PromiseCapCtx);
    cap.* = .{ .interp = self, .promise = p.retain() };
    try self.gcTrackPromiseCapCtx(cap);
    const resolve_fn = try interp(ctx).gcNewFunction(.{ .ctx = cap, .name = "", .arity = 1, .call = capResolve });
    const reject_fn = try interp(ctx).gcNewFunction(.{ .ctx = cap, .name = "", .arity = 1, .call = capReject });

    _ = executor.asFunction().value.call(executor.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{ resolve_fn, reject_fn }) catch |err0| {
        const err = self.throwIfGap(err0);
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception.?;
        self.pending_exception = null;
        if (!cap.already_resolved) {
            cap.already_resolved = true;
            try self.rejectPromiseValue(p, ex);
        } else {
            ex.deinit();
        }
    };
    return p;
}

fn requirePromise(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    return requireTag(ctx, this_value, .promise, "Promise.prototype.{s} called on a non-promise", method);
}

/// Non-callable handlers are the spec's pass-through (then(null, f) etc).
fn handlerOrNull(v: JSValue) ?JSValue {
    return if (v.isFunction()) v else null;
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
    aux: JSValue = JSValue.UNDEFINED,
};

fn finallyCtx(ctx: *anyopaque) *FinallyCtx {
    return @ptrCast(@alignCast(ctx));
}

fn finallyOnFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c = finallyCtx(ctx);
    const res = try c.handler.asFunction().value.call(c.handler.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{});
    defer res.deinit();
    return arg(args, 0).retain();
}

fn finallyOnRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c = finallyCtx(ctx);
    const res = try c.handler.asFunction().value.call(c.handler.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{});
    defer res.deinit();
    return c.interp.throwValue(arg(args, 0).retain());
}

fn promiseFinally(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    if (!builtin_helpers.isObjectLike(this_value)) {
        return self.throwError(.type_error, "Promise.prototype.finally called on non-object", .{});
    }
    const p = try requirePromise(ctx, this_value, "finally");
    const handler = handlerOrNull(arg(args, 0)) orelse return self.promiseThen(p, null, null);

    const c = try allocator.create(FinallyCtx);
    c.* = .{ .interp = self, .handler = handler.retain() };
    try self.gcTrackFinallyCtx(c);
    const on_f = try interp(ctx).gcNewFunction(.{ .ctx = c, .name = "", .arity = 1, .call = finallyOnFulfilled });
    const on_r = try interp(ctx).gcNewFunction(.{ .ctx = c, .name = "", .arity = 1, .call = finallyOnRejected });
    return self.promiseThen(p, on_f, on_r);
}

const Capability = struct {
    promise: JSValue,
    resolve: JSValue,
    reject: JSValue,
    is_native: bool,
};

fn customCapExecutor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c = finallyCtx(ctx);
    if (!c.handler.isUndefined() or !c.aux.isUndefined()) {
        return c.interp.throwError(.type_error, "Promise capability executor already called", .{});
    }
    c.handler = arg(args, 0).retain();
    c.aux = arg(args, 1).retain();
    return JSValue.UNDEFINED;
}

fn newPromiseCapability(self: *Interpreter, allocator: Allocator, ctor: JSValue) anyerror!Capability {
    if (!builtin_helpers.isObjectLike(ctor)) {
        return self.throwError(.type_error, "Promise capability target is not an object", .{});
    }
    if (isPromiseConstructor(ctor)) {
        const p = try self.gcNewPromise();
        const cap = try allocator.create(PromiseCapCtx);
        cap.* = .{ .interp = self, .promise = p.retain() };
        try self.gcTrackPromiseCapCtx(cap);
        const resolve_fn = try self.gcNewFunction(.{ .ctx = cap, .name = "", .arity = 1, .call = capResolve });
        const reject_fn = try self.gcNewFunction(.{ .ctx = cap, .name = "", .arity = 1, .call = capReject });
        return .{ .promise = p, .resolve = resolve_fn, .reject = reject_fn, .is_native = true };
    }
    if (!self.isConstructor(ctor)) {
        return self.throwError(.type_error, "Promise capability target is not a constructor", .{});
    }
    const c = try allocator.create(FinallyCtx);
    c.* = .{ .interp = self, .handler = JSValue.UNDEFINED, .aux = JSValue.UNDEFINED };
    try self.gcTrackFinallyCtx(c);
    const exec_fn = try self.gcNewFunction(.{ .ctx = c, .name = "", .arity = 2, .call = customCapExecutor });
    const promise = try self.constructValue(ctor, &.{exec_fn}, "");
    errdefer promise.deinit();
    if (!c.handler.isFunction() or !c.aux.isFunction()) {
        return self.throwError(.type_error, "Promise resolve or reject function is not callable", .{});
    }
    return .{ .promise = promise, .resolve = c.handler, .reject = c.aux, .is_native = false };
}

fn promiseResolveStatic(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    if (!builtin_helpers.isObjectLike(this_value)) {
        return self.throwError(.type_error, "Promise.resolve called on non-object", .{});
    }
    const v = arg(args, 0);
    if (isPromiseConstructor(this_value)) {
        if (v.isPromise()) {
            const ctor_prop = self.getProperty(v, "constructor") catch |err0| {
                const err = self.throwIfGap(err0);
                if (err != error.JsThrow) return err;
                const ex = self.pending_exception.?;
                self.pending_exception = null;
                return self.throwValue(ex);
            };
            defer ctor_prop.deinit();
            if (zvalue.equality.strictEquals(ctor_prop, this_value)) {
                return v.retain();
            }
        }
        const p = try self.gcNewPromise();
        try self.resolvePromise(p, v);
        return p;
    }
    const cap = try newPromiseCapability(self, allocator, this_value);
    const r = try cap.resolve.asFunction().value.call(cap.resolve.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{v});
    r.deinit();
    return cap.promise;
}

fn promiseRejectStatic(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    if (!builtin_helpers.isObjectLike(this_value)) {
        return self.throwError(.type_error, "Promise.reject called on non-object", .{});
    }
    const v = arg(args, 0);
    if (isPromiseConstructor(this_value)) {
        return self.rejectedPromise(v);
    }
    const cap = try newPromiseCapability(self, allocator, this_value);
    const r = try cap.reject.asFunction().value.call(cap.reject.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{v});
    r.deinit();
    return cap.promise;
}

fn promiseWithResolvers(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const cap = try newPromiseCapability(self, allocator, this_value);
    var obj = try self.ordinaryObject();
    try obj.asObject().value.set("promise", cap.promise);
    try obj.asObject().value.set("resolve", cap.resolve.retain());
    try obj.asObject().value.set("reject", cap.reject.retain());
    return obj;
}

fn promiseTryStatic(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const cap = try newPromiseCapability(self, allocator, this_value);
    const cb = arg(args, 0);
    const call_args = if (args.len > 1) args[1..] else &[_]JSValue{};
    const call_res: anyerror!JSValue = if (cb.isFunction())
        cb.asFunction().value.call(cb.asFunction().value.ctx, allocator, JSValue.UNDEFINED, call_args)
    else
        self.throwError(.type_error, "Promise.try callback is not a function", .{});
    if (call_res) |val| {
        defer val.deinit();
        const r = try cap.resolve.asFunction().value.call(cap.resolve.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{val});
        r.deinit();
    } else |err0| {
        const err = self.throwIfGap(err0);
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception.?;
        self.pending_exception = null;
        defer ex.deinit();
        const r = try cap.reject.asFunction().value.call(cap.reject.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{ex});
        r.deinit();
    }
    return cap.promise;
}

/// Shared bookkeeping for one Promise.all / allSettled / any call.
pub const AllCtx = struct {
    interp: *Interpreter,
    remaining: usize,
    /// Fulfillment values (all), settlement records (allSettled) or
    /// rejection reasons (any), by index.
    results: []JSValue,
    derived: JSValue,
    resolve_fn: JSValue = JSValue.UNDEFINED,
    reject_fn: JSValue = JSValue.UNDEFINED,
    settled: bool = false,
    mode: enum { all, all_settled, any } = .all,

    fn completeIfDone(c: *AllCtx) anyerror!void {
        if (c.remaining != 0 or c.settled) return;
        c.settled = true;
        if (c.mode == .any) {
            const err = try error_builtins.newAggregateError(c.interp, "All promises were rejected", c.results);
            defer err.deinit();
            if (c.reject_fn.isFunction()) {
                const r = try c.reject_fn.asFunction().value.call(c.reject_fn.asFunction().value.ctx, c.interp.gc_allocator, JSValue.UNDEFINED, &.{err});
                r.deinit();
            } else {
                try c.interp.rejectPromiseValue(c.derived, err);
            }
            return;
        }
        var array = try c.interp.gcNewArray();
        for (c.results) |r| _ = try array.asArray().value.push(r.retain());
        if (c.resolve_fn.isFunction()) {
            defer array.deinit();
            const r = try c.resolve_fn.asFunction().value.call(c.resolve_fn.asFunction().value.ctx, c.interp.gc_allocator, JSValue.UNDEFINED, &.{array});
            r.deinit();
        } else {
            try c.interp.resolvePromise(c.derived, array);
        }
    }
};

/// Per-element handler state: its index, and [[AlreadyCalled]] (an
/// element's resolve/reject functions settle its slot at most once).
pub const AllElemCtx = struct {
    all: *AllCtx,
    index: usize,
    called: bool = false,
};

fn allElemFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *AllElemCtx = @ptrCast(@alignCast(ctx));
    if (c.called) return JSValue.UNDEFINED;
    c.called = true;
    c.all.results[c.index] = arg(args, 0).retain();
    c.all.remaining -= 1;
    try c.all.completeIfDone();
    return JSValue.UNDEFINED;
}

fn allRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c: *AllCtx = @ptrCast(@alignCast(ctx));
    if (c.settled) return JSValue.UNDEFINED;
    c.settled = true;
    if (c.reject_fn.isFunction()) {
        const r = try c.reject_fn.asFunction().value.call(c.reject_fn.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{arg(args, 0)});
        r.deinit();
    } else {
        try c.interp.rejectPromiseValue(c.derived, arg(args, 0));
    }
    return JSValue.UNDEFINED;
}

/// `{ status, value }` / `{ status, reason }` for Promise.allSettled.
fn settledRecord(self: *Interpreter, fulfilled: bool, v: JSValue) anyerror!JSValue {
    var o = try self.ordinaryObject();
    try o.asObject().value.set("status", try self.gcNewString(if (fulfilled) "fulfilled" else "rejected"));
    try o.asObject().value.set(if (fulfilled) "value" else "reason", v.retain());
    return o;
}

/// An allSettled element's onFulfilled/onRejected, or an any element's
/// onRejected: records at the element's index, completes on the last.
fn settleElem(comptime fulfilled: bool) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = this_value;
            const c: *AllElemCtx = @ptrCast(@alignCast(ctx));
            if (c.called) return JSValue.UNDEFINED;
            c.called = true;
            const all = c.all;
            all.results[c.index] = if (all.mode == .all_settled)
                try settledRecord(all.interp, fulfilled, arg(args, 0))
            else
                arg(args, 0).retain();
            all.remaining -= 1;
            try all.completeIfDone();
            return JSValue.UNDEFINED;
        }
    }.call;
}

/// Promise.any's shared onFulfilled: the first fulfillment wins.
fn anyFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c: *AllCtx = @ptrCast(@alignCast(ctx));
    if (c.settled) return JSValue.UNDEFINED;
    c.settled = true;
    if (c.resolve_fn.isFunction()) {
        const r = try c.resolve_fn.asFunction().value.call(c.resolve_fn.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{arg(args, 0)});
        r.deinit();
    } else {
        try c.interp.resolvePromise(c.derived, arg(args, 0));
    }
    return JSValue.UNDEFINED;
}

/// Per-race resolution handler: first settle of ANY element settles the
/// derived promise; the rest are silent no-ops via settle idempotence.
pub const RaceCtx = struct {
    interp: *Interpreter,
    derived: JSValue,
    resolve_fn: JSValue = JSValue.UNDEFINED,
    reject_fn: JSValue = JSValue.UNDEFINED,
};

fn raceFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c: *RaceCtx = @ptrCast(@alignCast(ctx));
    if (c.resolve_fn.isFunction()) {
        const r = try c.resolve_fn.asFunction().value.call(c.resolve_fn.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{arg(args, 0)});
        r.deinit();
    } else {
        try c.interp.resolvePromise(c.derived, arg(args, 0));
    }
    return JSValue.UNDEFINED;
}

fn raceRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c: *RaceCtx = @ptrCast(@alignCast(ctx));
    if (c.reject_fn.isFunction()) {
        const r = try c.reject_fn.asFunction().value.call(c.reject_fn.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{arg(args, 0)});
        r.deinit();
    } else {
        try c.interp.rejectPromiseValue(c.derived, arg(args, 0));
    }
    return JSValue.UNDEFINED;
}

const CombinatorMode = enum { all, all_settled, any, race };

fn closeIteratorPreservingThrow(self: *Interpreter, iter: JSValue) void {
    const saved = self.pending_exception;
    self.pending_exception = null;
    defer self.pending_exception = saved;
    self.closeIterator(iter) catch {
        if (self.pending_exception) |ie| ie.deinit();
        self.pending_exception = null;
    };
}

fn getIteratorStrict(self: *Interpreter, allocator: Allocator, iterable: JSValue) anyerror!struct { iter: JSValue, next_fn: JSValue } {
    if (iterable.isUndefined() or iterable.isNull()) {
        return self.throwError(.type_error, "Cannot read properties of {s} (reading 'Symbol(Symbol.iterator)')", .{iterable.typeOf()});
    }
    const sym = self.symbol_iterator orelse return self.throwError(.type_error, "Symbol.iterator is not defined", .{});
    const key = try self.encodeKey(sym);
    defer self.gc_allocator.free(key);
    const method = try self.getProperty(iterable, key);
    defer method.deinit();
    if (method.isUndefined()) {
        const str: ?JSValue = if (iterable.isString())
            iterable
        else if (self.unboxPrimitiveWrapper(iterable)) |u|
            (if (u.isString()) u else null)
        else
            null;
        if (str) |sv| {
            const cps = try self.iterableItems(sv);
            defer self.gc_allocator.free(cps);
            var arr = try self.gcNewArray();
            defer arr.deinit();
            for (cps) |cp| _ = try arr.asArray().value.push(cp);
            const iter = try builtin_helpers.makeArrayIterator(self, allocator, arr, .values);
            errdefer iter.deinit();
            const next_fn = try self.getProperty(iter, "next");
            return .{ .iter = iter, .next_fn = next_fn };
        }
    }
    if (!method.isFunction()) {
        return self.throwError(.type_error, "{s} is not iterable", .{iterable.typeOf()});
    }
    const iter = try method.asFunction().value.call(method.asFunction().value.ctx, allocator, iterable, &.{});
    errdefer iter.deinit();
    if (!builtin_helpers.isObjectLike(iter)) {
        return self.throwError(.type_error, "Result of the Symbol.iterator method is not an object", .{});
    }
    const next_fn = try self.getProperty(iter, "next");
    return .{ .iter = iter, .next_fn = next_fn };
}

fn performCombinatorInner(
    self: *Interpreter,
    allocator: Allocator,
    ctor: JSValue,
    iterable: JSValue,
    cap: Capability,
    comptime mode: CombinatorMode,
) anyerror!void {
    const promise_resolve = try self.getProperty(ctor, "resolve");
    defer promise_resolve.deinit();
    if (!promise_resolve.isFunction()) {
        return self.throwError(.type_error, "Promise.resolve is not callable", .{});
    }

    const it_rec = try getIteratorStrict(self, allocator, iterable);
    defer it_rec.iter.deinit();
    defer it_rec.next_fn.deinit();
    if (!it_rec.next_fn.isFunction()) {
        return self.throwError(.type_error, "iterator.next is not a function", .{});
    }

    if (mode == .race) {
        const rc = try self.gc_allocator.create(RaceCtx);
        rc.* = .{
            .interp = self,
            .derived = cap.promise.retain(),
            .resolve_fn = cap.resolve.retain(),
            .reject_fn = cap.reject.retain(),
        };
        try self.gcTrackRaceCtx(rc);
        const on_f = if (cap.is_native)
            try self.gcNewFunction(.{ .ctx = rc, .name = "", .arity = 1, .call = raceFulfilled })
        else
            cap.resolve;
        const on_r = if (cap.is_native)
            try self.gcNewFunction(.{ .ctx = rc, .name = "", .arity = 1, .call = raceRejected })
        else
            cap.reject;

        while (true) {
            const step = try it_rec.next_fn.asFunction().value.call(it_rec.next_fn.asFunction().value.ctx, allocator, it_rec.iter, &.{});
            defer step.deinit();
            if (!builtin_helpers.isObjectLike(step)) {
                return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
            }
            const done_val = try self.getProperty(step, "done");
            const done = coercion.isTruthy(done_val);
            done_val.deinit();
            if (done) return;

            const next_val = try self.getProperty(step, "value");
            defer next_val.deinit();

            errdefer closeIteratorPreservingThrow(self, it_rec.iter);
            const next_promise = try promise_resolve.asFunction().value.call(promise_resolve.asFunction().value.ctx, allocator, ctor, &.{next_val});
            defer next_promise.deinit();
            const then_fn = try self.getProperty(next_promise, "then");
            defer then_fn.deinit();
            if (!then_fn.isFunction()) {
                return self.throwError(.type_error, "then is not a function", .{});
            }
            const then_res = try then_fn.asFunction().value.call(then_fn.asFunction().value.ctx, allocator, next_promise, &.{ on_f, on_r });
            then_res.deinit();
        }
    }

    const all_mode: @TypeOf(@as(AllCtx, undefined).mode) = switch (mode) {
        .all => .all,
        .all_settled => .all_settled,
        .any => .any,
        .race => unreachable,
    };
    const all = try self.gc_allocator.create(AllCtx);
    all.* = .{
        .interp = self,
        .remaining = 1,
        .results = try self.gc_allocator.alloc(JSValue, 0),
        .derived = cap.promise.retain(),
        .resolve_fn = cap.resolve.retain(),
        .reject_fn = cap.reject.retain(),
        .mode = all_mode,
    };
    try self.gcTrackAllCtx(all);

    const shared_on_r: ?JSValue = if (mode == .all)
        (if (cap.is_native) try self.gcNewFunction(.{ .ctx = all, .name = "", .arity = 1, .call = allRejected }) else cap.reject)
    else
        null;
    const shared_on_f: ?JSValue = if (mode == .any)
        (if (cap.is_native) try self.gcNewFunction(.{ .ctx = all, .name = "", .arity = 1, .call = anyFulfilled }) else cap.resolve)
    else
        null;

    var index: usize = 0;
    while (true) : (index += 1) {
        const step = try it_rec.next_fn.asFunction().value.call(it_rec.next_fn.asFunction().value.ctx, allocator, it_rec.iter, &.{});
        defer step.deinit();
        if (!builtin_helpers.isObjectLike(step)) {
            return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
        }
        const done_val = try self.getProperty(step, "done");
        const done = coercion.isTruthy(done_val);
        done_val.deinit();
        if (done) {
            all.remaining -= 1;
            try all.completeIfDone();
            return;
        }

        const next_val = try self.getProperty(step, "value");
        defer next_val.deinit();

        errdefer closeIteratorPreservingThrow(self, it_rec.iter);
        const old_res = all.results;
        const new_res = try self.gc_allocator.alloc(JSValue, index + 1);
        @memcpy(new_res[0..index], old_res);
        new_res[index] = JSValue.UNDEFINED;
        self.gc_allocator.free(old_res);
        all.results = new_res;

        all.remaining += 1;
        const elem = try self.gc_allocator.create(AllElemCtx);
        elem.* = .{ .all = all, .index = index };
        try self.gcTrackAllElemCtx(elem);

        const on_f = shared_on_f orelse try self.gcNewFunction(.{
            .ctx = elem,
            .name = "",
            .arity = 1,
            .call = if (mode == .all) allElemFulfilled else settleElem(true),
        });
        const on_r = shared_on_r orelse try self.gcNewFunction(.{
            .ctx = elem,
            .name = "",
            .arity = 1,
            .call = settleElem(false),
        });

        const next_promise = try promise_resolve.asFunction().value.call(promise_resolve.asFunction().value.ctx, allocator, ctor, &.{next_val});
        defer next_promise.deinit();
        const then_fn = try self.getProperty(next_promise, "then");
        defer then_fn.deinit();
        if (!then_fn.isFunction()) {
            return self.throwError(.type_error, "then is not a function", .{});
        }
        const then_res = try then_fn.asFunction().value.call(then_fn.asFunction().value.ctx, allocator, next_promise, &.{ on_f, on_r });
        then_res.deinit();
    }
}

fn promiseCombinator(comptime mode: CombinatorMode) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            const self = interp(ctx);
            const cap = try newPromiseCapability(self, allocator, this_value);
            performCombinatorInner(self, allocator, this_value, arg(args, 0), cap, mode) catch |err0| {
                const err = self.throwIfGap(err0);
                if (err != error.JsThrow) return err;
                const ex = self.pending_exception.?;
                self.pending_exception = null;
                defer ex.deinit();
                const r = try cap.reject.asFunction().value.call(cap.reject.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{ex});
                r.deinit();
            };
            return cap.promise;
        }
    }.call;
}

fn globalSetTimeout(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const cb = arg(args, 0);
    if (!cb.isFunction()) return self.throwError(.type_error, "The \"callback\" argument must be of type function", .{});
    const delay = if (arg(args, 1).isNumber()) arg(args, 1).asNumber() else 0;
    return JSValue.fromNumber(try self.addTimer(cb, delay));
}

fn globalClearTimeout(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    if (arg(args, 0).isNumber()) interp(ctx).clearTimer(arg(args, 0).asNumber());
    return JSValue.UNDEFINED;
}

/// Installs the `Promise` constructor + statics and the timer globals.
pub fn install(self: *Interpreter) !void {
    const arena = self.gc_allocator;
    const g = self.global_env;

    // Promise: constructable native; the statics (resolve/reject/all/
    // race) ride the phase-10 property bag.
    _ = try installBuiltin(self, .{ .name = "Promise", .ctor = .{ .arity = 1, .call = promiseConstructor, .constructable = true }, .statics = &.{
        .{ .name = "resolve", .value = .{ .method = .{ .call = promiseResolveStatic, .arity = 1 } } },
        .{ .name = "reject", .value = .{ .method = .{ .call = promiseRejectStatic, .arity = 1 } } },
        .{ .name = "all", .value = .{ .method = .{ .call = promiseCombinator(.all), .arity = 1 } } },
        .{ .name = "race", .value = .{ .method = .{ .call = promiseCombinator(.race), .arity = 1 } } },
        .{ .name = "allSettled", .value = .{ .method = .{ .call = promiseCombinator(.all_settled), .arity = 1 } } },
        .{ .name = "any", .value = .{ .method = .{ .call = promiseCombinator(.any), .arity = 1 } } },
        .{ .name = "withResolvers", .value = .{ .method = .{ .call = promiseWithResolvers, .arity = 0 } } },
        .{ .name = "try", .value = .{ .method = .{ .call = promiseTryStatic, .arity = 1 } } },
    } });

    try g.define(arena, "setTimeout", try native(self, "setTimeout", 2, globalSetTimeout));
    try g.define(arena, "clearTimeout", try native(self, "clearTimeout", 1, globalClearTimeout));
}
