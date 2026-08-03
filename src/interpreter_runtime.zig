//! The runtime/execution-loop cluster: script entry points (`run`/
//! `evalSource`/`defineGlobal`), the Promise state machine
//! (`resolvePromise`..`rejectedPromise`), the fiber/generator/async
//! machinery (`resumeFiber`..`makeAsyncGeneratorObject` plus their
//! private free-function helpers: `fiberEntry`/`iteratorSelf`/
//! `generatorNext`/`asyncGeneratorNext`/`iterResult`/
//! `awaitOnFulfilled`/`awaitOnRejected`, used ONLY here, so they move
//! along instead of staying behind), and `setTimeout` macrotasks
//! (`addTimer`/`clearTimer`/`runEventLoop`). These four sub-clusters
//! (`entry`+`promise`+`async`+`timers`) were NOT contiguous in the
//! original file -- the RegExp/array-extra/primitive-boxing section
//! (a future "support" batch) and the just-extracted module-loading
//! section both sit between them -- so this file is assembled from
//! four separate line ranges, same "multiple disjoint pieces, one new
//! file" shape as several Phase A batches. All struct-method pieces
//! made `pub` regardless of original visibility (batch 1/2's
//! confirmed lesson); the 7 free-function helpers stay non-`pub` since
//! nothing outside this file ever references them.
//! `invokeFunctionNode` (used by `fiberEntry` here, but ALSO by the
//! not-yet-extracted class cluster) stays in `interpreter.zig`, made
//! `pub` there instead of moving.
//! z-interpreter-refactor.md, Step 5 Phase C batch 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const zfunctions = @import("zfunctions");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const fiber_mod = @import("fiber.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const Environment = interpreter_mod.Environment;
const Completion = interpreter_mod.Completion;
const FiberState = interpreter_mod.FiberState;
const invokeFunctionNode = interpreter_mod.invokeFunctionNode;
const native_helpers = @import("native_helpers.zig");
const interp = native_helpers.interp;
const builtins = @import("builtins.zig");

/// Runs the whole function body on the fiber's stack. A generator (sync or
/// async) records its outcome for whoever reads it next (generatorNext
/// synchronously, or resumeFiber's post-switch check for async generators);
/// a plain async function settles its one-shot promise directly here
/// (resolvePromise/rejectPromiseValue only enqueue jobs, never switch, so
/// calling them from ON the fiber is safe).
fn fiberEntry(arg: *anyopaque) void {
    const fs: *FiberState = @ptrCast(@alignCast(arg));
    const self = fs.interp;
    const arena = self.gc_allocator;
    const result = invokeFunctionNode(self, fs.fnode, fs.closure_env, arena, fs.this_value, null, null, fs.private_ctx, fs.args, null) catch |err| {
        if (err == error.JsThrow) {
            const ex = self.pending_exception.?;
            self.pending_exception = null;
            if (fs.is_generator) {
                fs.completed_throw = ex;
            } else {
                self.rejectPromiseValue(fs.promise.?, ex) catch |e2| {
                    fs.fatal_error = e2;
                };
            }
        } else {
            fs.fatal_error = err;
        }
        return;
    };
    if (fs.is_generator) {
        fs.completion = result;
    } else {
        self.resolvePromise(fs.promise.?, result) catch |e2| {
            fs.fatal_error = e2;
        };
    }
}

/// A `[Symbol.iterator]()` method that returns the receiver (generator
/// objects are their own iterators).
fn iteratorSelf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = args;
    return this_value.retain();
}

/// `gen.next(v)` -- native with ctx = *FiberState.
fn generatorNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    const self = fs.interp;
    if (fs.fiber.finished) return iterResult(self, JSValue.UNDEFINED, true);

    fs.resume_value = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    fs.resume_is_throw = false;
    fs.yielded = null;
    try self.resumeFiber(fs);

    if (fs.yielded) |y| {
        fs.yielded = null;
        return iterResult(self, y, false);
    }
    if (fs.completed_throw) |ex| {
        fs.completed_throw = null;
        return self.throwValue(ex);
    }
    const c = fs.completion orelse JSValue.UNDEFINED;
    fs.completion = null;
    return iterResult(self, c, true);
}

/// `asyncGen.next(v)` -- native with ctx = *FiberState (is_generator AND
/// is_async both true). Unlike the sync generatorNext, this must itself
/// return a PROMISE synchronously: resumeFiber may settle it right away (a
/// yield/completion reached before any pending await) or leave it pending
/// (the fiber suspended at an intermediate await) -- resumeFiber's
/// post-switch check (see its doc comment) settles it either way, possibly
/// after further await-driven resumptions.
fn asyncGeneratorNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    const self = fs.interp;
    if (fs.fiber.finished) return self.fulfilledPromise(try iterResult(self, JSValue.UNDEFINED, true));

    const p = try self.gcNewPromise();
    fs.pending_result_promise = p;
    fs.resume_value = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    fs.resume_is_throw = false;
    try self.resumeFiber(fs);
    return p;
}

/// A `{ value, done }` iterator-result object, chained to Object.prototype
/// like any ordinary object -- confirmed against real Node that
/// `Object.getPrototypeOf(gen().next())` is Object.prototype, not null.
fn iterResult(self: *Interpreter, value: JSValue, done: bool) anyerror!JSValue {
    var obj = try self.ordinaryObject();
    try obj.object.value.set("value", value.retain());
    try obj.object.value.set("done", JSValue.fromBool(done));
    return obj;
}

/// The awaited promise settled -- refill the resume slots and switch
/// back into the async function's fiber. Runs inside runPendingJob.
fn awaitOnFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    fs.resume_value = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    fs.resume_is_throw = false;
    try fs.interp.resumeFiber(fs);
    return JSValue.UNDEFINED;
}

fn awaitOnRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    fs.resume_value = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    fs.resume_is_throw = true;
    try fs.interp.resumeFiber(fs);
    return JSValue.UNDEFINED;
}

/// Parses + evaluates a whole script; returns the completion value of
/// the last top-level statement (UNDEFINED if the program is empty or
/// ends on a non-value-producing statement). An uncaught JS exception
/// surfaces as `error.UncaughtException` with the thrown value left in
/// `pending_exception` for inspection -- `error.JsThrow` is a private
/// signal that never escapes this module's public API.
pub fn run(self: *Interpreter, source: []const u8) anyerror!JSValue {
    self.pending_exception = null; // stale state from a previous run()
    self.stack_limit = @frameAddress() -| Interpreter.main_stack_budget;
    if (!self.globals_ready) {
        try builtins.setupGlobals(self);
        self.globals_ready = true;
    }
    if (self.script_env == null) {
        self.script_env = try self.gcChildEnv(self.global_env);
        // Real spec: a classic Script's top-level `this` is globalThis
        // -- run() IS the classic-script entry point (eval/REPL/embed),
        // unlike runModule(), so there's no module-vs-script ambiguity
        // to resolve here at all. Confirmed against real Node this was
        // simply missing (this === undefined before this fix).
        self.script_env.?.this_value = self.global_object;
    }
    if (self.global_var_env == null) self.global_var_env = self.script_env;
    // AST nodes stay on the arena (immutable, bulk-freed with the
    // whole run -- never GC-tracked); everything else this function
    // creates goes through gc_allocator.
    const ast_arena = self.arena_state.allocator();
    const parser = try zfunctions.Parser.init(ast_arena, source);
    parser.setStackLimit(self.stack_limit);
    const program = try parser.parseProgram();
    const c = self.evalBody(self.script_env.?, program) catch |err| {
        if (err != error.JsThrow) return err;
        return error.UncaughtException;
    };
    // Script done -> drain the queues (microtasks, then timers), the
    // js_std_loop shape. Hosts that own their loop drive
    // hasPendingJobs/runPendingJob themselves instead.
    try self.runEventLoop();
    return c.value;
}

/// Parse and run `src` (an `eval` string) as a program in a fresh child of
/// `scope`. Always-strict, so eval gets its own scope and declarations
/// don't leak. A parse error becomes a catchable SyntaxError; a thrown
/// exception from the code propagates. Returns eval's completion value.
pub fn evalSource(self: *Interpreter, scope: *Environment, src: []const u8) anyerror!JSValue {
    const ast_arena = self.arena_state.allocator();
    const parser = zfunctions.Parser.init(ast_arena, src) catch
        return self.throwError(.syntax_error, "Invalid or unexpected token in eval", .{});
    // Reuse whatever budget is already active for the current
    // execution context (main-thread `run()`, or the fiber-scoped
    // value `resumeFiber` swaps in) -- `eval()` can be called from
    // deep inside an already-recursed script, so a freshly-computed
    // budget here would over-allow (see z-parser-improve.md).
    parser.setStackLimit(self.stack_limit);
    const program = parser.parseProgram() catch |err| switch (err) {
        // Same message as `evalExpression`'s own stack guard (line
        // ~3387) -- deeply nested source text and deeply nested
        // evaluation now report the identical RangeError, whichever
        // phase actually trips.
        error.MaxNestingDepthExceeded => return self.throwError(.range_error, "Maximum call stack size exceeded", .{}),
        else => return self.throwError(.syntax_error, "Invalid or unexpected token in eval", .{}),
    };
    const eval_scope = try self.gcChildEnv(scope);
    const c = try self.evalBody(eval_scope, program);
    return c.value;
}

/// Installs a host-provided global binding (QuickJS-libc-style: the
/// engine stays free of any runtime concern; hosts like z-run add
/// their `os`/`std` objects through this). Retains the value. Define
/// BEFORE the first run() if user code must see it from the first
/// statement (globals land in global_env, above the script scope, so
/// user `let`/`const` may shadow them -- exactly like `console`).
pub fn defineGlobal(self: *Interpreter, name: []const u8, value: JSValue) !void {
    try self.global_env.define(self.gc_allocator, name, value.retain());
}

// ===== Promise jobs and timers (the engine side of the event loop) =====
//
// The QuickJS contract: the engine owns the MICROTASK queue and
// exposes it (hasPendingJobs/runPendingJob) for the host to drain;
// run() drains it itself as a convenience for script-shaped usage.
// Handlers are ordinary Callables -- JS closures and native functions
// (Promise.all's bookkeeping) go through the exact same path.

pub fn hasPendingJobs(self: *Interpreter) bool {
    return self.pending_jobs.items.len != 0;
}

/// Runs ONE pending promise job (FIFO). A handler that throws rejects
/// the job's derived promise -- the exception never escapes here; a
/// rejection nobody subscribed to is silently dropped (unhandled-
/// rejection tracking is a documented gap).
pub fn runPendingJob(self: *Interpreter) anyerror!void {
    if (self.pending_jobs.items.len == 0) return;
    const job = self.pending_jobs.orderedRemove(0);
    const arena = self.gc_allocator;

    const handler = job.handler orelse {
        // Pass-through: adoption and the missing side of .then/.catch.
        if (job.derived) |d| {
            if (job.rejected) {
                try self.settlePromise(d, .rejected, job.argument);
            } else {
                try self.resolvePromise(d, job.argument);
            }
        }
        return;
    };
    const result = handler.function.value.call(handler.function.value.ctx, arena, JSValue.UNDEFINED, &.{job.argument}) catch |err| {
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception.?;
        self.pending_exception = null;
        if (job.derived) |d| try self.settlePromise(d, .rejected, ex);
        return;
    };
    if (job.derived) |d| try self.resolvePromise(d, result);
}

/// ECMA-262 27.2.1.3.2 resolve, narrowed: resolving with another
/// promise ADOPTS its eventual state (thenables that aren't real
/// promises are not detected -- documented narrowing); resolving with
/// itself is the spec's chaining-cycle TypeError; anything else
/// fulfills.
pub fn resolvePromise(self: *Interpreter, p: JSValue, value: JSValue) anyerror!void {
    if (value == .promise) {
        if (value.promise == p.promise) {
            const cycle = try self.gcNewError(.type_error, "Chaining cycle detected for promise");
            return self.settlePromise(p, .rejected, cycle);
        }
        return self.subscribePromise(value, null, null, p);
    }
    try self.settlePromise(p, .fulfilled, value);
}

/// Rejects an EXISTING promise with a reason (executor's reject,
/// Promise.all's fail-fast). Public for builtins.
pub fn rejectPromiseValue(self: *Interpreter, p: JSValue, reason: JSValue) anyerror!void {
    try self.settlePromise(p, .rejected, reason);
}

/// Settles (idempotently -- a second settle is the spec's no-op) and
/// enqueues every stored reaction with the settlement.
pub fn settlePromise(self: *Interpreter, p: JSValue, state: zvalue.PromiseState, value: JSValue) anyerror!void {
    const arena = self.gc_allocator;
    const reactions = try p.promise.value.settle(arena, state, value.retain());
    defer arena.free(reactions);
    for (reactions) |r| {
        try self.pending_jobs.append(arena, .{
            .handler = if (state == .fulfilled) r.on_fulfilled else r.on_rejected,
            .argument = value,
            .rejected = state == .rejected,
            .derived = r.derived,
        });
    }
}

/// Registers interest in `p`'s settlement: stores the reaction while
/// pending, or enqueues the job immediately if already settled (a
/// .then on a settled promise still runs asynchronously -- through
/// the queue, never inline).
pub fn subscribePromise(self: *Interpreter, p: JSValue, on_fulfilled: ?JSValue, on_rejected: ?JSValue, derived: ?JSValue) anyerror!void {
    const arena = self.gc_allocator;
    const settled = try p.promise.value.subscribe(arena, .{
        .on_fulfilled = if (on_fulfilled) |h| h.retain() else null,
        .on_rejected = if (on_rejected) |h| h.retain() else null,
        .derived = if (derived) |d| d.retain() else null,
    }) orelse return;
    try self.pending_jobs.append(arena, .{
        .handler = if (settled.state == .fulfilled) on_fulfilled else on_rejected,
        .argument = settled.result,
        .rejected = settled.state == .rejected,
        .derived = derived,
    });
}

/// `p.then(onF, onR)` -- creates and returns the derived promise.
/// Non-callable handlers are ignored (the spec's pass-through).
/// Public for builtins (then/catch/finally/all/race are thin wrappers).
pub fn promiseThen(self: *Interpreter, p: JSValue, on_fulfilled: ?JSValue, on_rejected: ?JSValue) anyerror!JSValue {
    const derived = try self.gcNewPromise();
    try self.subscribePromise(p, on_fulfilled, on_rejected, derived);
    return derived;
}

/// Freshly-fulfilled promise (Promise.resolve on a non-promise).
pub fn fulfilledPromise(self: *Interpreter, value: JSValue) anyerror!JSValue {
    const p = try self.gcNewPromise();
    try self.settlePromise(p, .fulfilled, value);
    return p;
}

pub fn rejectedPromise(self: *Interpreter, reason: JSValue) anyerror!JSValue {
    const p = try self.gcNewPromise();
    try self.settlePromise(p, .rejected, reason);
    return p;
}

// ===== Fibers (generators / async functions) =====

/// Scheduler -> fiber, with current_fiber bookkeeping and fatal
/// (non-JS) error propagation. Returns when the fiber suspends or
/// finishes.
///
/// For an async generator with a request in flight (pending_result_
/// promise != null), ALSO settles that promise once the fiber actually
/// produces something: a yield (resolve with {value,done:false}), a
/// throw (reject), or a normal completion (resolve with
/// {value,done:true}). If the fiber suspended at a plain `await`
/// instead -- nothing produced yet -- the promise stays pending; a
/// later resumeFiber call (driven by that await's own promise settling,
/// via awaitOnFulfilled/awaitOnRejected) will reach this same check
/// again and eventually settle it. This centralizes the settling logic
/// so it doesn't matter whether asyncGeneratorNext or an await-
/// resumption job is the one calling resumeFiber for a given leg.
pub fn resumeFiber(self: *Interpreter, fs: *FiberState) anyerror!void {
    const prev = self.current_fiber;
    const prev_limit = self.stack_limit;
    self.current_fiber = fs;
    self.stack_limit = fs.fiber.stack_floor + Interpreter.fiber_stack_margin;
    fs.fiber.switchTo();
    self.current_fiber = prev;
    self.stack_limit = prev_limit;
    if (fs.is_generator and fs.is_async) {
        if (fs.pending_result_promise) |p| {
            if (fs.yielded) |y| {
                fs.yielded = null;
                fs.pending_result_promise = null;
                try self.resolvePromise(p, try iterResult(self, y, false));
            } else if (fs.completed_throw) |ex| {
                fs.completed_throw = null;
                fs.pending_result_promise = null;
                try self.rejectPromiseValue(p, ex);
            } else if (fs.completion) |c| {
                fs.completion = null;
                fs.pending_result_promise = null;
                try self.resolvePromise(p, try iterResult(self, c, true));
            }
            // Else: suspended at a plain await mid-body -- nothing to
            // settle yet, leave pending_result_promise as-is.
        }
    }
    if (fs.fatal_error) |err| {
        fs.fatal_error = null;
        return err;
    }
}

/// The suspend/resume mechanics of ONE `await`: subscribe to the
/// operand's settlement (wrapping a non-promise in an already-fulfilled
/// one, so `await 5` still takes a real trip through the microtask
/// queue -- real semantics), suspend the fiber, and once resumed either
/// return the settled value or re-throw it. Shared by the `.await_expr`
/// evaluator, AsyncGeneratorYield's implicit Await of a yielded value,
/// and `for await`'s per-value Await.
pub fn awaitValue(self: *Interpreter, fs: *FiberState, operand: JSValue) anyerror!JSValue {
    const p = if (operand == .promise) operand else try self.fulfilledPromise(operand);
    const on_f = try self.gcNewFunction(.{ .ctx = fs, .name = "", .call = awaitOnFulfilled });
    const on_r = try self.gcNewFunction(.{ .ctx = fs, .name = "", .call = awaitOnRejected });
    try self.subscribePromise(p, on_f, on_r, null);
    fs.fiber.suspendSelf();
    if (fs.resume_is_throw) {
        fs.resume_is_throw = false;
        return self.throwValue(fs.resume_value);
    }
    return fs.resume_value;
}

/// Calling `function*` builds the generator object -- a plain object
/// whose `next` native drives the (not-yet-started) fiber. The body
/// runs nothing until the first next() (real semantics).
pub fn makeGeneratorObject(self: *Interpreter, fnode: *zfunctions.FunctionNode, closure_env: *Environment, this_value: ?JSValue, private_ctx: ?*anyopaque, args: []const JSValue) anyerror!JSValue {
    const arena = self.gc_allocator;
    const fs = try arena.create(FiberState);
    fs.* = .{
        .is_generator = true,
        .is_async = false,
        .interp = self,
        .fiber = undefined,
        .fnode = fnode,
        .closure_env = closure_env,
        .this_value = this_value,
        .private_ctx = private_ctx,
        .args = try arena.dupe(JSValue, args),
    };
    fs.fiber = try fiber_mod.Fiber.init(arena, fiberEntry, fs);
    try self.gcTrackFiberState(fs);
    var obj = try self.gcNewObject();
    try obj.object.value.set("next", try self.gcNewFunction(.{ .ctx = fs, .name = "next", .call = generatorNext }));
    // A generator IS its own iterable: `gen()[Symbol.iterator]()`
    // returns the generator itself (so `[...gen()]` works via the
    // Symbol.iterator path too, and `gen()[Symbol.iterator]() === gen()`).
    if (self.symbol_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        try obj.object.value.set(key, try self.nativeMethod("iterator", "self", 0, iteratorSelf));
    }
    return obj;
}

/// Calling `async function` starts the body IMMEDIATELY on its fiber
/// (synchronous until the first await -- real semantics) and returns
/// the promise; completion settles it from inside the entry.
pub fn runAsyncFunction(self: *Interpreter, fnode: *zfunctions.FunctionNode, closure_env: *Environment, this_value: ?JSValue, private_ctx: ?*anyopaque, args: []const JSValue) anyerror!JSValue {
    const arena = self.gc_allocator;
    const fs = try arena.create(FiberState);
    fs.* = .{
        .is_generator = false,
        .is_async = true,
        .interp = self,
        .fiber = undefined,
        .fnode = fnode,
        .closure_env = closure_env,
        .this_value = this_value,
        .private_ctx = private_ctx,
        .args = try arena.dupe(JSValue, args),
        .promise = try self.gcNewPromise(),
    };
    fs.fiber = try fiber_mod.Fiber.init(arena, fiberEntry, fs);
    try self.gcTrackFiberState(fs);
    try self.resumeFiber(fs);
    return fs.promise.?;
}

/// Calling `async function*`/`async *method(){}` builds an async
/// generator object: like makeGeneratorObject, but `next` is
/// asyncGeneratorNext (returns a promise per call) and the
/// self-iterator hook is keyed by Symbol.asyncIterator, not
/// Symbol.iterator (spec: AsyncGenerator.prototype[Symbol.asyncIterator]
/// returns `this`). The body runs nothing until the first next(),
/// same as a sync generator.
pub fn makeAsyncGeneratorObject(self: *Interpreter, fnode: *zfunctions.FunctionNode, closure_env: *Environment, this_value: ?JSValue, private_ctx: ?*anyopaque, args: []const JSValue) anyerror!JSValue {
    const arena = self.gc_allocator;
    const fs = try arena.create(FiberState);
    fs.* = .{
        .is_generator = true,
        .is_async = true,
        .interp = self,
        .fiber = undefined,
        .fnode = fnode,
        .closure_env = closure_env,
        .this_value = this_value,
        .private_ctx = private_ctx,
        .args = try arena.dupe(JSValue, args),
    };
    fs.fiber = try fiber_mod.Fiber.init(arena, fiberEntry, fs);
    try self.gcTrackFiberState(fs);
    var obj = try self.gcNewObject();
    try obj.object.value.set("next", try self.gcNewFunction(.{ .ctx = fs, .name = "next", .call = asyncGeneratorNext }));
    if (self.symbol_async_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        try obj.object.value.set(key, try self.nativeMethod("asyncIterator", "self", 0, iteratorSelf));
    }
    return obj;
}

// ===== Timers (setTimeout macrotasks) =====

pub fn addTimer(self: *Interpreter, callback: JSValue, delay_ms: f64) !f64 {
    const arena = self.gc_allocator;
    const id = self.next_timer_id;
    self.next_timer_id += 1;
    const delay: i64 = if (delay_ms > 0) @intFromFloat(delay_ms) else 0;
    try self.timers.append(arena, .{
        .id = id,
        .due_ms = builtins.nowMs() + delay,
        .callback = callback.retain(),
    });
    return id;
}

pub fn clearTimer(self: *Interpreter, id: f64) void {
    for (self.timers.items, 0..) |t, i| {
        if (t.id == id) {
            _ = self.timers.swapRemove(i);
            return;
        }
    }
}

/// The convenience event loop qjs calls js_std_loop: drain microtasks,
/// then sleep to the earliest timer and fire it, until both queues are
/// empty. Lives here until z-run takes ownership of the loop (Etapa C
/// completa); a timer callback that throws is an ordinary uncaught
/// exception. Linux-only sleep, same note as Date's clock_gettime.
pub fn runEventLoop(self: *Interpreter) anyerror!void {
    const arena = self.gc_allocator;
    while (true) {
        while (self.hasPendingJobs()) try self.runPendingJob();
        if (self.timers.items.len == 0) return;

        var earliest: usize = 0;
        for (self.timers.items, 0..) |t, i| {
            if (t.due_ms < self.timers.items[earliest].due_ms) earliest = i;
        }
        const timer = self.timers.items[earliest];
        _ = self.timers.swapRemove(earliest);

        const now = builtins.nowMs();
        if (timer.due_ms > now) {
            const wait_ms: u64 = @intCast(timer.due_ms - now);
            var req: std.os.linux.timespec = .{
                .sec = @intCast(wait_ms / 1000),
                .nsec = @intCast((wait_ms % 1000) * 1_000_000),
            };
            _ = std.os.linux.nanosleep(&req, null);
        }
        _ = timer.callback.function.value.call(timer.callback.function.value.ctx, arena, JSValue.UNDEFINED, &.{}) catch |err| {
            if (err != error.JsThrow) return err;
            return error.UncaughtException;
        };
    }
}
