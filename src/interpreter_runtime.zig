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
const bytecode_emitter = @import("bytecode/emitter.zig");
const bytecode_vm = @import("bytecode/vm.zig");
const codeblock = @import("bytecode/codeblock.zig");
const fiber_mod = @import("fiber.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const Environment = interpreter_mod.Environment;
const Completion = interpreter_mod.Completion;
const FiberState = interpreter_mod.FiberState;
const invokeFunctionNode = interpreter_mod.invokeFunctionNode;
const prepareCallEnv = interpreter_mod.prepareCallEnv;
const evalPreparedFunctionBody = interpreter_mod.evalPreparedFunctionBody;
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
    const res_or_err = if (fs.is_generator)
        evalPreparedFunctionBody(self, fs.fnode, fs.closure_env)
    else
        invokeFunctionNode(self, fs.fnode, fs.closure_env, arena, fs.this_value, null, null, fs.private_ctx, fs.args, null);
    const result = res_or_err catch |err0| {
        if (err0 == error.JsReturn) {
            const rv = self.pending_return orelse JSValue.UNDEFINED;
            self.pending_return = null;
            if (fs.is_generator) {
                fs.completion = rv;
            } else {
                self.resolvePromise(fs.promise.?, rv) catch |e2| {
                    fs.fatal_error = e2;
                };
            }
            return;
        }
        const err = self.throwIfGap(err0);
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
    if (self.current_fiber == fs) return self.throwError(.type_error, "Generator is already running", .{});
    if (fs.fiber.finished) return iterResult(self, JSValue.UNDEFINED, true);

    fs.has_started = true;
    fs.setResumeValue(if (args.len > 0) args[0].retain() else JSValue.UNDEFINED);
    fs.resume_is_throw = false;
    fs.resume_is_return = false;
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

fn generatorReturn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    const self = fs.interp;
    if (self.current_fiber == fs) return self.throwError(.type_error, "Generator is already running", .{});
    const val = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    if (!fs.has_started or fs.fiber.finished) {
        fs.fiber.finished = true;
        return iterResult(self, val, true);
    }
    fs.setResumeValue(val.retain());
    fs.resume_is_return = true;
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

fn generatorThrow(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    const self = fs.interp;
    if (self.current_fiber == fs) return self.throwError(.type_error, "Generator is already running", .{});
    const val = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    if (!fs.has_started or fs.fiber.finished) {
        fs.fiber.finished = true;
        return self.throwValue(val.retain());
    }
    fs.setResumeValue(val.retain());
    fs.resume_is_throw = true;
    fs.resume_is_return = false;
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

fn asyncGeneratorReturn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    const self = fs.interp;
    if (self.current_fiber == fs) return self.throwError(.type_error, "Generator is already running", .{});
    const val = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    if (!fs.has_started or fs.fiber.finished) {
        fs.fiber.finished = true;
        return self.fulfilledPromise(try iterResult(self, val, true));
    }
    const p = try self.gcNewPromise();
    fs.pending_result_promise = p.retain();
    fs.setResumeValue(val.retain());
    fs.resume_is_return = true;
    fs.resume_is_throw = false;
    try self.resumeFiber(fs);
    return p;
}

fn asyncGeneratorThrow(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    const self = fs.interp;
    if (self.current_fiber == fs) return self.throwError(.type_error, "Generator is already running", .{});
    const val = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    if (!fs.has_started or fs.fiber.finished) {
        fs.fiber.finished = true;
        return self.rejectedPromise(val.retain());
    }
    const p = try self.gcNewPromise();
    fs.pending_result_promise = p.retain();
    fs.setResumeValue(val.retain());
    fs.resume_is_throw = true;
    fs.resume_is_return = false;
    try self.resumeFiber(fs);
    return p;
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

    fs.has_started = true;
    const p = try self.gcNewPromise();
    // `fs` keeps its own reference (settled later from inside
    // resumeFiber) and this call ALSO returns `p` as its own owned
    // result -- same double-ownership shape as runAsyncFunction's
    // `fs.promise`/promiseConstructor's `cap.promise`.
    fs.pending_result_promise = p.retain();
    fs.setResumeValue(if (args.len > 0) args[0].retain() else JSValue.UNDEFINED);
    fs.resume_is_throw = false;
    fs.resume_is_return = false;
    try self.resumeFiber(fs);
    return p;
}

/// A `{ value, done }` iterator-result object, chained to Object.prototype
/// like any ordinary object -- confirmed against real Node that
/// `Object.getPrototypeOf(gen().next())` is Object.prototype, not null.
fn iterResult(self: *Interpreter, value: JSValue, done: bool) anyerror!JSValue {
    var obj = try self.ordinaryObject();
    try obj.asObject().value.set("value", value.retain());
    try obj.asObject().value.set("done", JSValue.fromBool(done));
    return obj;
}

/// The awaited promise settled -- refill the resume slots and switch
/// back into the async function's fiber. Runs inside runPendingJob.
fn awaitOnFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    fs.setResumeValue(if (args.len > 0) args[0].retain() else JSValue.UNDEFINED);
    fs.resume_is_throw = false;
    try fs.interp.resumeFiber(fs);
    return JSValue.UNDEFINED;
}

fn awaitOnRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    fs.setResumeValue(if (args.len > 0) args[0].retain() else JSValue.UNDEFINED);
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
        if (self.global_object) |go| self.script_env.?.this_value = go.retain();
    }
    if (self.global_var_env == null) self.global_var_env = self.script_env;
    // AST nodes stay on the arena (immutable, bulk-freed with the
    // whole run -- never GC-tracked); everything else this function
    // creates goes through gc_allocator.
    const ast_arena = self.arena_state.allocator();
    const parser = try zfunctions.Parser.init(ast_arena, source);
    parser.setStackLimit(self.stack_limit);
    const program = try parser.parseProgram();
    try interpreter_mod.normalizePrivateInProgram(ast_arena, source, program);
    if (codeblock.hasUseStrict(program)) self.strict_mode = true;
    if (self.compile_options.use_bytecode_vm) {
        var compiled = bytecode_emitter.BytecodeEmitter.emitScript(self.gc_allocator, program) catch |err| switch (err) {
            error.UnsupportedSyntax, error.UnknownLocal => blk: {
                _ = self.console_error_writer.writeAll("warning: bytecode compilation fallback to tree-walker (unsupported syntax)\n") catch {};
                break :blk null;
            },
            else => return err,
        };
        if (compiled) |*block| {
            if (self.strict_mode) block.block.flags.is_strict = true;
            defer block.deinit(self.gc_allocator);
            try self.hoistVarScope(self.script_env.?, program);
            try self.hoistLexical(self.script_env.?, program);
            if (self.compile_options.disasm) {
                const text = bytecode_emitter.disassemble(self.gc_allocator, &block.block) catch null;
                if (text) |t| {
                    defer self.gc_allocator.free(t);
                    _ = self.console_error_writer.writeAll(t) catch {};
                }
            }
            const this_val = if (self.global_object) |go| go else JSValue.UNDEFINED;
            const vm_result = bytecode_vm.vmCall(self.gc_allocator, &block.block, self.script_env, this_val, &.{}, self) catch |err0| blk: {
                const err = self.throwIfGap(err0);
                if (err == error.UnsupportedOpcode) break :blk null;
                if (err == error.JsThrow) return error.UncaughtException;
                return err;
            };
            if (vm_result) |value| {
                try self.runEventLoop();
                return value;
            }
        }
    }
    const c = self.evalBody(self.script_env.?, program) catch |err0| {
        const err = self.throwIfGap(err0);
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
    // The AST points into its source text (identifiers, string bodies),
    // and `src` belongs to the caller's string, which can die as soon as
    // eval() returns -- while functions defined in the code live on. The
    // arena copy lives as long as the AST.
    const owned_src = try ast_arena.dupe(u8, src);
    const parser = zfunctions.Parser.init(ast_arena, owned_src) catch
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
    try interpreter_mod.normalizePrivateInProgram(ast_arena, owned_src, program);
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
    // The job holds its own reference to its argument and handler (the
    // promise that queued it may be gone by now); dropped once it ran.
    defer {
        job.argument.deinit();
        if (job.handler) |h| h.deinit();
    }

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
    const result = handler.asFunction().value.call(handler.asFunction().value.ctx, arena, JSValue.UNDEFINED, &.{job.argument}) catch |err0| {
        const err = self.throwIfGap(err0);
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception.?;
        self.pending_exception = null;
        if (job.derived) |d| try self.settlePromise(d, .rejected, ex);
        return;
    };
    if (job.derived) |d| try self.resolvePromise(d, result);
}

fn thenableJobCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c: *builtins.FinallyCtx = @ptrCast(@alignCast(ctx));
    const self = c.interp;
    const thenable = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    const cap = try allocator.create(builtins.PromiseCapCtx);
    cap.* = .{ .interp = self, .promise = c.aux.retain() };
    try self.gcTrackPromiseCapCtx(cap);
    const resolve_fn = try self.gcNewFunction(.{ .ctx = cap, .name = "", .arity = 1, .call = builtins.capResolve });
    const reject_fn = try self.gcNewFunction(.{ .ctx = cap, .name = "", .arity = 1, .call = builtins.capReject });
    const res = c.handler.asFunction().value.call(c.handler.asFunction().value.ctx, allocator, thenable, &.{ resolve_fn, reject_fn }) catch |err0| {
        const err = self.throwIfGap(err0);
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception.?;
        self.pending_exception = null;
        if (!cap.already_resolved) {
            cap.already_resolved = true;
            try self.rejectPromiseValue(c.aux, ex);
        } else {
            ex.deinit();
        }
        return JSValue.UNDEFINED;
    };
    res.deinit();
    return JSValue.UNDEFINED;
}

/// ECMA-262 27.2.1.3.2 resolve: resolving with itself is the spec's
/// chaining-cycle TypeError; resolving with an object/promise checks
/// for a callable `then` property (enqueueing a PromiseResolveThenableJob
/// if custom, or fast-subscribing if native Promise); anything else fulfills.
pub fn resolvePromise(self: *Interpreter, p: JSValue, value: JSValue) anyerror!void {
    if (value.isPromise()) {
        if (value.asPromise() == p.asPromise()) {
            const cycle = try self.gcNewError(.type_error, "Chaining cycle detected for promise");
            return self.settlePromise(p, .rejected, cycle);
        }
        if (self.extraProps(value) == null) {
            return self.subscribePromise(value, null, null, p);
        }
    }
    if (builtins.isObjectLike(value)) {
        const then_val = self.getProperty(value, "then") catch |err0| {
            const err = self.throwIfGap(err0);
            if (err != error.JsThrow) return err;
            const ex = self.pending_exception.?;
            self.pending_exception = null;
            return self.settlePromise(p, .rejected, ex);
        };
        if (then_val.isFunction()) {
            const c = try self.gc_allocator.create(builtins.FinallyCtx);
            c.* = .{ .interp = self, .handler = then_val, .aux = p.retain() };
            try self.gcTrackFinallyCtx(c);
            const job_fn = try self.gcNewFunction(.{ .ctx = c, .name = "", .call = thenableJobCall });
            try self.pending_jobs.append(self.gc_allocator, .{
                .handler = job_fn,
                .argument = value.retain(),
                .rejected = false,
                .derived = null,
            });
            return;
        }
        then_val.deinit();
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
    const reactions = try p.asPromise().value.settle(arena, state, value.retain());
    defer arena.free(reactions);
    for (reactions) |r| {
        try self.pending_jobs.append(arena, .{
            .handler = if (state == .fulfilled) r.on_fulfilled else r.on_rejected,
            .argument = value.retain(),
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
    const settled = try p.asPromise().value.subscribe(arena, .{
        .on_fulfilled = if (on_fulfilled) |h| h.retain() else null,
        .on_rejected = if (on_rejected) |h| h.retain() else null,
        .derived = if (derived) |d| d.retain() else null,
    }) orelse return;
    try self.pending_jobs.append(arena, .{
        .handler = if (settled.state == .fulfilled) (if (on_fulfilled) |h| h.retain() else null) else (if (on_rejected) |h| h.retain() else null),
        .argument = settled.result.retain(),
        .rejected = settled.state == .rejected,
        // Same double-ownership shape as the pending branch above
        // (which already retains): `derived` is also promiseThen's own
        // return value, so this job needs its own copy too.
        .derived = if (derived) |d| d.retain() else null,
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
    const is_native_promise = if (operand.isPromise()) blk: {
        if (self.extraProps(operand)) |bag| {
            if (bag.asObject().value.getOwnRecord("constructor") != null) {
                const ctor_prop = try self.getProperty(operand, "constructor");
                defer ctor_prop.deinit();
                break :blk builtins.isPromiseConstructor(ctor_prop);
            }
        }
        break :blk true;
    } else false;
    const p = if (is_native_promise)
        operand
    else blk: {
        const fresh = try self.gcNewPromise();
        try self.resolvePromise(fresh, operand);
        break :blk fresh;
    };
    const on_f = try self.gcNewFunction(.{ .ctx = fs, .name = "", .call = awaitOnFulfilled });
    const on_r = try self.gcNewFunction(.{ .ctx = fs, .name = "", .call = awaitOnRejected });
    try self.subscribePromise(p, on_f, on_r, null);
    fs.fiber.suspendSelf();
    if (fs.resume_is_throw) {
        fs.resume_is_throw = false;
        return self.throwValue(fs.takeResumeValue());
    }
    return fs.takeResumeValue();
}

/// A fiber's own copy of its call arguments: the caller releases its
/// references once the call returns, but the body may only bind them
/// later (a generator runs nothing until the first next()), so the
/// FiberState holds a reference to each -- released when it is swept.
fn retainedCopy(allocator: std.mem.Allocator, args: []const JSValue) ![]JSValue {
    const copy = try allocator.dupe(JSValue, args);
    for (copy) |a| _ = a.retain();
    return copy;
}

/// Calling `function*` builds the generator object -- a plain object
/// whose `next` native drives the (not-yet-started) fiber. Parameter
/// binding runs synchronously at call time (ECMA-262 GeneratorStart);
/// the body runs nothing until the first next().
pub fn makeGeneratorObject(
    self: *Interpreter,
    fnode: *zfunctions.FunctionNode,
    closure_env: *Environment,
    this_value: ?JSValue,
    super_proto: ?JSValue,
    private_ctx: ?*anyopaque,
    args: []const JSValue,
    home_object: ?JSValue,
) anyerror!JSValue {
    const arena = self.gc_allocator;
    const call_env = try prepareCallEnv(self, fnode, closure_env, arena, this_value, super_proto, null, private_ctx, args, home_object, true);
    const fs = try arena.create(FiberState);
    fs.* = .{
        .is_generator = true,
        .is_async = false,
        .interp = self,
        .fiber = undefined,
        .fnode = fnode,
        .closure_env = call_env,
        .this_value = null,
        .private_ctx = private_ctx,
        .args = try arena.alloc(JSValue, 0),
    };
    fs.fiber = try fiber_mod.Fiber.init(arena, fiberEntry, fs);
    try self.gcTrackFiberState(fs);
    var obj = try self.gcNewObject();
    if (self.iterator_prototype) |p| try obj.asObject().value.setPrototype(&p.asObject().value);
    try obj.asObject().value.set("next", try self.gcNewFunction(.{ .ctx = fs, .name = "next", .arity = 1, .call = generatorNext }));
    try obj.asObject().value.set("return", try self.gcNewFunction(.{ .ctx = fs, .name = "return", .arity = 1, .call = generatorReturn }));
    try obj.asObject().value.set("throw", try self.gcNewFunction(.{ .ctx = fs, .name = "throw", .arity = 1, .call = generatorThrow }));
    // A generator IS its own iterable: `gen()[Symbol.iterator]()`
    // returns the generator itself (so `[...gen()]` works via the
    // Symbol.iterator path too, and `gen()[Symbol.iterator]() === gen()`).
    if (self.symbol_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        try obj.asObject().value.set(key, try self.nativeMethod("iterator", "self", 0, iteratorSelf));
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
        .this_value = if (this_value) |tv| tv.retain() else null,
        .private_ctx = private_ctx,
        .args = try retainedCopy(arena, args),
        .promise = try self.gcNewPromise(),
    };
    fs.fiber = try fiber_mod.Fiber.init(arena, fiberEntry, fs);
    try self.gcTrackFiberState(fs);
    try self.resumeFiber(fs);
    // `fs` keeps its own reference (used later by resolvePromise/
    // rejectPromiseValue when the body settles) -- the caller gets an
    // independent one. Before uniform-ownership-contract.md's Etapa 1,
    // this call's result was implicitly borrowed by convention (nobody
    // freed a discarded call result), so aliasing the same box was
    // invisible; now that discarded values are freed, this needs its
    // own copy like every other "producer" in the migration.
    return fs.promise.?.retain();
}

/// Calling `async function*`/`async *method(){}` builds an async
/// generator object: like makeGeneratorObject, but `next` is
/// asyncGeneratorNext (returns a promise per call) and the
/// self-iterator hook is keyed by Symbol.asyncIterator, not
/// Symbol.iterator (spec: AsyncGenerator.prototype[Symbol.asyncIterator]
/// returns `this`). Parameter binding runs synchronously at call time;
/// the body runs nothing until the first next(), same as a sync generator.
pub fn makeAsyncGeneratorObject(
    self: *Interpreter,
    fnode: *zfunctions.FunctionNode,
    closure_env: *Environment,
    this_value: ?JSValue,
    super_proto: ?JSValue,
    private_ctx: ?*anyopaque,
    args: []const JSValue,
    home_object: ?JSValue,
) anyerror!JSValue {
    const arena = self.gc_allocator;
    const call_env = try prepareCallEnv(self, fnode, closure_env, arena, this_value, super_proto, null, private_ctx, args, home_object, true);
    const fs = try arena.create(FiberState);
    fs.* = .{
        .is_generator = true,
        .is_async = true,
        .interp = self,
        .fiber = undefined,
        .fnode = fnode,
        .closure_env = call_env,
        .this_value = null,
        .private_ctx = private_ctx,
        .args = try arena.alloc(JSValue, 0),
    };
    fs.fiber = try fiber_mod.Fiber.init(arena, fiberEntry, fs);
    try self.gcTrackFiberState(fs);
    var obj = try self.gcNewObject();
    if (self.protos.async_generator_proto.isObject()) {
        try obj.asObject().value.setPrototype(&self.protos.async_generator_proto.asObject().value);
    }
    try obj.asObject().value.set("next", try self.gcNewFunction(.{ .ctx = fs, .name = "next", .arity = 1, .call = asyncGeneratorNext }));
    try obj.asObject().value.set("return", try self.gcNewFunction(.{ .ctx = fs, .name = "return", .arity = 1, .call = asyncGeneratorReturn }));
    try obj.asObject().value.set("throw", try self.gcNewFunction(.{ .ctx = fs, .name = "throw", .arity = 1, .call = asyncGeneratorThrow }));
    if (self.symbol_async_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        try obj.asObject().value.set(key, try self.nativeMethod("asyncIterator", "self", 0, iteratorSelf));
    }
    return obj;
}

fn asyncCloseOnError(self: *Interpreter, fs: *FiberState, iter: JSValue) void {
    const saved = self.pending_exception;
    self.pending_exception = null;
    defer self.pending_exception = saved;
    const ret_fn = self.getProperty(iter, "return") catch {
        if (self.pending_exception) |ie| ie.deinit();
        self.pending_exception = null;
        return;
    };
    defer ret_fn.deinit();
    if (ret_fn.isFunction()) {
        const res = ret_fn.asFunction().value.call(ret_fn.asFunction().value.ctx, self.gc_allocator, iter, &.{}) catch {
            if (self.pending_exception) |ie| ie.deinit();
            self.pending_exception = null;
            return;
        };
        defer res.deinit();
        const awaited = self.awaitValue(fs, res) catch {
            if (self.pending_exception) |ie| ie.deinit();
            self.pending_exception = null;
            return;
        };
        awaited.deinit();
    }
}

fn syncCloseOnError(self: *Interpreter, iter: JSValue) void {
    const saved = self.pending_exception;
    self.pending_exception = null;
    defer self.pending_exception = saved;
    self.closeIterator(iter) catch {
        if (self.pending_exception) |ie| ie.deinit();
        self.pending_exception = null;
    };
}

fn createDataPropOnFromAsyncTarget(self: *Interpreter, target: JSValue, index: usize, value: JSValue) anyerror!void {
    if (target.isArray()) {
        var arr = &target.asArray().value;
        if (index == arr.toSlice().len) {
            _ = try arr.push(value.retain());
            return;
        }
    }
    var buf: [32]u8 = undefined;
    const pk = std.fmt.bufPrint(&buf, "{d}", .{index}) catch unreachable;
    if (target.isObject()) {
        var obj = &target.asObject().value;
        if (obj.getOwnRecord(pk)) |rec| {
            if (!rec.descriptor.configurable) {
                return self.throwError(.type_error, "Cannot redefine property: {s}", .{pk});
            }
        } else if (!obj.is_extensible) {
            return self.throwError(.type_error, "Cannot add property {s}, object is not extensible", .{pk});
        }
        try obj.defineProperty(pk, value.retain(), .{ .writable = true, .enumerable = true, .configurable = true });
        return;
    }
    try self.setPropertyOnValue(target, pk, value);
}

fn fromAsyncBody(self: *Interpreter, fs: *FiberState) anyerror!JSValue {
    const arena = self.gc_allocator;
    const c_val = fs.this_value orelse JSValue.UNDEFINED;
    const items = if (fs.args.len > 0) fs.args[0] else JSValue.UNDEFINED;
    const mapfn = if (fs.args.len > 1) fs.args[1] else JSValue.UNDEFINED;
    const this_arg = if (fs.args.len > 2) fs.args[2] else JSValue.UNDEFINED;

    const has_map = !mapfn.isUndefined();
    if (has_map and !mapfn.isFunction()) {
        return self.throwError(.type_error, "Array.fromAsync mapper is not a function", .{});
    }
    if (items.isUndefined() or items.isNull()) {
        return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    }

    var using_async: JSValue = JSValue.UNDEFINED;
    if (self.symbol_async_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer arena.free(key);
        using_async = try self.getProperty(items, key);
        if (!using_async.isUndefined() and !using_async.isNull() and !using_async.isFunction()) {
            using_async.deinit();
            return self.throwError(.type_error, "Symbol.asyncIterator is not a function", .{});
        }
    }
    defer using_async.deinit();

    var using_sync: JSValue = JSValue.UNDEFINED;
    if (using_async.isUndefined() or using_async.isNull()) {
        if (self.symbol_iterator) |sym| {
            const key = try self.encodeKey(sym);
            defer arena.free(key);
            using_sync = try self.getProperty(items, key);
            if (!using_sync.isUndefined() and !using_sync.isNull() and !using_sync.isFunction()) {
                using_sync.deinit();
                return self.throwError(.type_error, "Symbol.iterator is not a function", .{});
            }
        }
    }
    defer using_sync.deinit();

    const coercion = @import("coercion.zig");
    if (using_async.isFunction() or using_sync.isFunction()) {
        const is_async_iter = using_async.isFunction();
        const method = if (is_async_iter) using_async else using_sync;
        const iter = try method.asFunction().value.call(method.asFunction().value.ctx, arena, items, &.{});
        defer iter.deinit();
        if (!builtins.isObjectLike(iter)) {
            return self.throwError(.type_error, "Iterator is not an object", .{});
        }
        const next_fn = try self.getProperty(iter, "next");
        defer next_fn.deinit();
        if (!next_fn.isFunction()) {
            return self.throwError(.type_error, "iterator.next is not a function", .{});
        }

        const result_arr = if (self.isConstructor(c_val))
            try self.constructValue(c_val, &.{}, "")
        else
            try self.gcNewArray();
        errdefer result_arr.deinit();

        var k: usize = 0;
        while (true) : (k += 1) {
            if (k >= 9007199254740991) {
                _ = self.throwError(.type_error, "Array length exceeded maximum safe integer", .{}) catch {};
                if (is_async_iter) asyncCloseOnError(self, fs, iter) else syncCloseOnError(self, iter);
                return error.JsThrow;
            }
            const raw_step = try next_fn.asFunction().value.call(next_fn.asFunction().value.ctx, arena, iter, &.{});
            const step = if (is_async_iter) blk: {
                defer raw_step.deinit();
                break :blk try self.awaitValue(fs, raw_step);
            } else raw_step;
            defer step.deinit();

            if (!builtins.isObjectLike(step)) {
                return self.throwError(.type_error, "Iterator result is not an object", .{});
            }
            const done_val = try self.getProperty(step, "done");
            const done = coercion.isTruthy(done_val);
            done_val.deinit();
            if (done) {
                if (result_arr.isArray()) {
                    try self.setArrayProperty(result_arr, "length", JSValue.fromNumber(@floatFromInt(k)));
                } else {
                    try self.setPropertyOnValue(result_arr, "length", JSValue.fromNumber(@floatFromInt(k)));
                }
                return result_arr;
            }

            const raw_val = try self.getProperty(step, "value");
            const next_val = if (!is_async_iter) blk: {
                defer raw_val.deinit();
                break :blk self.awaitValue(fs, raw_val) catch |err| {
                    syncCloseOnError(self, iter);
                    return err;
                };
            } else raw_val;
            defer next_val.deinit();

            const mapped_val = if (has_map) blk: {
                const m = mapfn.asFunction().value.call(mapfn.asFunction().value.ctx, arena, this_arg, &.{ next_val, JSValue.fromNumber(@floatFromInt(k)) }) catch |err| {
                    if (is_async_iter) asyncCloseOnError(self, fs, iter) else syncCloseOnError(self, iter);
                    return err;
                };
                defer m.deinit();
                break :blk self.awaitValue(fs, m) catch |err| {
                    if (is_async_iter) asyncCloseOnError(self, fs, iter) else syncCloseOnError(self, iter);
                    return err;
                };
            } else next_val.retain();
            defer mapped_val.deinit();

            createDataPropOnFromAsyncTarget(self, result_arr, k, mapped_val) catch |err| {
                if (is_async_iter) asyncCloseOnError(self, fs, iter) else syncCloseOnError(self, iter);
                return err;
            };
        }
    }

    const len_val = try self.getProperty(items, "length");
    defer len_val.deinit();
    const raw_len = try self.toNumberJS(len_val);
    const clamped_len_f = if (std.math.isNan(raw_len) or raw_len <= 0)
        0.0
    else
        @min(@trunc(raw_len), 9007199254740991.0);

    const result_arr = if (self.isConstructor(c_val))
        try self.constructValue(c_val, &.{JSValue.fromNumber(clamped_len_f)}, "")
    else blk: {
        if (clamped_len_f > 4294967295.0) {
            return self.throwError(.range_error, "Invalid array length", .{});
        }
        break :blk try self.gcNewArray();
    };
    errdefer result_arr.deinit();

    if (clamped_len_f > 4294967295.0) {
        return self.throwError(.range_error, "Invalid array length", .{});
    }
    const len: usize = @intFromFloat(clamped_len_f);
    var k: usize = 0;
    while (k < len) : (k += 1) {
        var buf: [32]u8 = undefined;
        const pk = std.fmt.bufPrint(&buf, "{d}", .{k}) catch unreachable;
        const k_val = try self.getProperty(items, pk);
        const awaited_k = blk: {
            defer k_val.deinit();
            break :blk try self.awaitValue(fs, k_val);
        };
        defer awaited_k.deinit();

        const mapped_val = if (has_map) blk: {
            const m = try mapfn.asFunction().value.call(mapfn.asFunction().value.ctx, arena, this_arg, &.{ awaited_k, JSValue.fromNumber(@floatFromInt(k)) });
            defer m.deinit();
            break :blk try self.awaitValue(fs, m);
        } else awaited_k.retain();
        defer mapped_val.deinit();

        try createDataPropOnFromAsyncTarget(self, result_arr, k, mapped_val);
    }
    if (result_arr.isArray()) {
        try self.setArrayProperty(result_arr, "length", JSValue.fromNumber(@floatFromInt(len)));
    } else {
        try self.setPropertyOnValue(result_arr, "length", JSValue.fromNumber(@floatFromInt(len)));
    }
    return result_arr;
}

fn fromAsyncFiberEntry(arg: *anyopaque) void {
    const fs: *FiberState = @ptrCast(@alignCast(arg));
    const self = fs.interp;
    const result = fromAsyncBody(self, fs) catch |err0| {
        const err = self.throwIfGap(err0);
        if (err == error.JsThrow) {
            const ex = self.pending_exception.?;
            self.pending_exception = null;
            self.rejectPromiseValue(fs.promise.?, ex) catch |e2| {
                fs.fatal_error = e2;
            };
        } else {
            fs.fatal_error = err;
        }
        return;
    };
    self.resolvePromise(fs.promise.?, result) catch |e2| {
        fs.fatal_error = e2;
    };
}

pub fn runFromAsync(self: *Interpreter, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const arena = self.gc_allocator;
    const fs = try arena.create(FiberState);
    fs.* = .{
        .is_generator = false,
        .is_async = true,
        .interp = self,
        .fiber = undefined,
        .fnode = undefined,
        .closure_env = self.global_env,
        .this_value = this_value.retain(),
        .private_ctx = null,
        .args = try retainedCopy(arena, args),
        .promise = try self.gcNewPromise(),
    };
    fs.fiber = try fiber_mod.Fiber.init(arena, fromAsyncFiberEntry, fs);
    try self.gcTrackFiberState(fs);
    try self.resumeFiber(fs);
    return fs.promise.?.retain();
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
        _ = timer.callback.asFunction().value.call(timer.callback.asFunction().value.ctx, arena, JSValue.UNDEFINED, &.{}) catch |err0| {
            const err = self.throwIfGap(err0);
            if (err != error.JsThrow) return err;
            return error.UncaughtException;
        };
    }
}
