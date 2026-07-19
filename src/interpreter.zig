const std = @import("std");
const Allocator = std.mem.Allocator;
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const zfunctions = @import("zfunctions");
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const JSValue = zvalue.JSValue;

const environment = @import("environment.zig");
pub const Environment = environment.Environment;
const completion_mod = @import("completion.zig");
pub const Completion = completion_mod.Completion;
const coercion = @import("coercion.zig");
const inspect = @import("inspect.zig");
const builtins = @import("builtins.zig");
const fiber_mod = @import("fiber.zig");

/// A user-defined closure's opaque Callable context: the parsed function's
/// AST node, the environment it closed over at definition time, and a back
/// pointer to the Interpreter so `closureCall` can recurse into
/// `evalProgram`/`evalExpression`. Safe to store `*Interpreter` here
/// because closures are only ever created from inside `evalExpression`
/// (which already takes `self: *Interpreter`, i.e. the caller's own stable
/// address) -- never during `Interpreter.init`.
const ClosureCtx = struct {
    interp: *Interpreter,
    function_node: *zfunctions.FunctionNode,
    closure_env: *Environment,
    /// Non-null only for class method closures: the parent class's
    /// prototype, so `super.m()` resolves inside the body (copied onto
    /// the call env; arrows nested in the method inherit via chain walk).
    super_proto: ?JSValue = null,
};

/// ctx for a class's constructor function -- the value `class C {...}`
/// evaluates to. Distinct from ClosureCtx because a class may have NO
/// constructor element (implicit constructor: derived classes forward to
/// super, base classes no-op) and needs the super bindings + its name for
/// the without-`new` TypeError.
/// One promise reaction microtask: call `handler(argument)` and settle
/// `derived` with the outcome. Null handler = pass-through (adoption and
/// the missing side of .then/.catch); `finally` needs no special kind --
/// builtins implements it as then() with native wrappers that re-throw.
const Job = struct {
    handler: ?JSValue,
    argument: JSValue,
    /// Whether `argument` is a rejection reason (drives which
    /// pass-through side fires).
    rejected: bool,
    derived: ?JSValue,
};

const Timer = struct {
    id: f64,
    due_ms: i64,
    callback: JSValue,
};

pub const LoadedModule = struct {
    /// Loader-RESOLVED path -- the module cache key and the referrer for
    /// this module's own imports.
    path: []const u8,
    source: []const u8,
};

/// The host side of module loading: resolve a specifier against its
/// referrer and produce the source. Returning null means "not found"
/// (the engine raises the catchable Cannot-find-module error). All
/// allocations from the passed arena.
pub const ModuleLoader = struct {
    ctx: *anyopaque,
    load: *const fn (ctx: *anyopaque, arena: Allocator, specifier: []const u8, referrer: ?[]const u8) anyerror!?LoadedModule,
};

const ModuleRecord = struct {
    path: []const u8,
    /// The module's export map (a plain object -- also serves directly
    /// as the `import * as ns` namespace object).
    exports: JSValue,
    state: enum { loading, evaluated },
};

/// Everything one suspended activation needs: a generator object's guts,
/// or a running async function. The JS body executes on `fiber`'s stack
/// via the ordinary invokeFunctionNode -- yield/await switch out, the
/// scheduler side (generatorNext / the await-resumption natives) switches
/// back in with the resume slots filled.
const FiberState = struct {
    kind: enum { generator, async_fn },
    interp: *Interpreter,
    fiber: *fiber_mod.Fiber,
    fnode: *zfunctions.FunctionNode,
    closure_env: *Environment,
    this_value: ?JSValue,
    args: []const JSValue,
    /// Scheduler -> fiber: what the suspension point produces on resume
    /// (next(v) / the awaited promise's settlement).
    resume_value: JSValue = JSValue.UNDEFINED,
    resume_is_throw: bool = false,
    /// Fiber -> scheduler: the value a `yield` produced, if any.
    yielded: ?JSValue = null,
    /// Fiber -> scheduler on completion (generators only; async resolves
    /// its promise from inside the entry instead).
    completion: ?JSValue = null,
    completed_throw: ?JSValue = null,
    /// Non-JS errors (OOM/NotImplemented) that unwound the fiber -- the
    /// scheduler side re-raises them after the switch; they must never
    /// be swallowed.
    fatal_error: ?anyerror = null,
    /// The promise an async function returned (kind == .async_fn only).
    promise: ?JSValue = null,
};

/// Runs the whole function body on the fiber's stack. Completion is
/// recorded (generator) or settles the promise directly (async --
/// resolvePromise only enqueues jobs, it never switches, so calling it
/// from ON the fiber is safe).
fn fiberEntry(arg: *anyopaque) void {
    const fs: *FiberState = @ptrCast(@alignCast(arg));
    const self = fs.interp;
    const arena = self.arena_state.allocator();
    const result = invokeFunctionNode(self, fs.fnode, fs.closure_env, arena, fs.this_value, null, null, fs.args) catch |err| {
        if (err == error.JsThrow) {
            const ex = self.pending_exception.?;
            self.pending_exception = null;
            switch (fs.kind) {
                .generator => fs.completed_throw = ex,
                .async_fn => self.rejectPromiseValue(fs.promise.?, ex) catch |e2| {
                    fs.fatal_error = e2;
                },
            }
        } else {
            fs.fatal_error = err;
        }
        return;
    };
    switch (fs.kind) {
        .generator => fs.completion = result,
        .async_fn => self.resolvePromise(fs.promise.?, result) catch |e2| {
            fs.fatal_error = e2;
        },
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
    _ = this_value;
    const fs: *FiberState = @ptrCast(@alignCast(ctx));
    const self = fs.interp;
    if (fs.fiber.finished) return iterResult(allocator, JSValue.UNDEFINED, true);

    fs.resume_value = if (args.len > 0) args[0] else JSValue.UNDEFINED;
    fs.resume_is_throw = false;
    fs.yielded = null;
    try self.resumeFiber(fs);

    if (fs.yielded) |y| {
        fs.yielded = null;
        return iterResult(allocator, y, false);
    }
    if (fs.completed_throw) |ex| {
        fs.completed_throw = null;
        return self.throwValue(ex);
    }
    const c = fs.completion orelse JSValue.UNDEFINED;
    fs.completion = null;
    return iterResult(allocator, c, true);
}

/// A `{ value, done }` iterator-result object.
fn iterResult(allocator: Allocator, value: JSValue, done: bool) anyerror!JSValue {
    var obj = try JSValue.newObject(allocator);
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

const ClassCtx = struct {
    interp: *Interpreter,
    ctor_fnode: ?*zfunctions.FunctionNode,
    closure_env: *Environment,
    name: []const u8,
    super_ctor: ?JSValue,
    super_proto: ?JSValue,
};

pub const Interpreter = struct {
    arena_state: std.heap.ArenaAllocator,
    global_env: *Environment,
    /// Injected, not hardcoded to real stdout -- lets tests point this at
    /// an in-memory buffer instead of touching the process's actual
    /// stdout.
    console_writer: *std.Io.Writer,
    /// The JS exception currently in flight. INVARIANT: meaningful only
    /// while `error.JsThrow` is unwinding; every raiser (throwValue/
    /// throwError) sets it unconditionally immediately before returning
    /// `error.JsThrow`, and every catcher takes it (reads + nulls)
    /// immediately. Never `catch` around evalExpression/evalStatement/
    /// Callable.call except in the two sanctioned places (`runCapturing`
    /// and `run()`), and those filter to exactly `error.JsThrow` --
    /// OutOfMemory/NotImplemented always propagate untouched. After an
    /// `error.UncaughtException` from run(), this field holds the
    /// uncaught value for the caller to inspect.
    pending_exception: ?JSValue = null,
    /// Globals (console/Math/JSON/Object/...) are installed lazily on the
    /// first run() -- native functions carry `ctx = *Interpreter`, and
    /// init() returns by value, so `&self` is only stable once run() is
    /// called on the caller's storage.
    globals_ready: bool = false,
    /// Shared native-method values, keyed "type.name" (e.g. "array.push"),
    /// so `a.push === b.push` holds like real JS prototype methods.
    method_cache: std.StringHashMapUnmanaged(JSValue) = .empty,
    /// The `new`-detection token: evalNew (and `super(...)`) set this to
    /// the callee's ctx pointer for exactly the duration of the
    /// constructor call; classConstructorCall requires it to match and
    /// clears it on entry (so plain calls made *inside* a constructor
    /// body don't inherit construct-ness). This is how `C()` without
    /// `new` becomes the real TypeError.
    construct_target: ?*anyopaque = null,
    /// User code runs in this child of global_env (created on first
    /// run(), persistent across runs). The separation makes the lexical
    /// redeclaration check ("already declared in THIS env") correct:
    /// `let console = 5` must be legal -- builtins aren't lexical
    /// bindings of the script scope, just reachable through the chain.
    script_env: ?*Environment = null,
    /// The microtask queue (promise reaction jobs), FIFO. PUBLIC contract
    /// (QuickJS's JS_ExecutePendingJob): the engine enqueues, the HOST
    /// drains via hasPendingJobs/runPendingJob -- run() drains as a
    /// convenience for script-shaped usage.
    pending_jobs: std.ArrayList(Job) = .empty,
    /// setTimeout macrotasks, unordered (runEventLoop scans for the
    /// earliest due). Cleared entries are swap-removed.
    timers: std.ArrayList(Timer) = .empty,
    next_timer_id: f64 = 1,
    /// The fiber whose stack is currently executing, if any --
    /// yield/await evaluation reaches its state through this;
    /// resumeFiber save/restores it (nesting: a generator driven from
    /// inside an async function, etc.).
    current_fiber: ?*FiberState = null,
    /// Host-provided module loader (QuickJS's JS_SetModuleLoaderFunc
    /// shape) -- the engine never reads files. Null = `import` is a
    /// catchable SyntaxError.
    module_loader: ?ModuleLoader = null,
    /// Module cache keyed by the loader-resolved path: each module
    /// parses and evaluates exactly once.
    modules: std.StringHashMapUnmanaged(*ModuleRecord) = .empty,
    /// Symbol-keyed properties are stored in ZObject (string-keyed only)
    /// under an encoded reserved key (`\x00S<ptr>`). This maps the
    /// encoded key back to the symbol JSValue -- for
    /// getOwnPropertySymbols and to keep symbol identity. Populated
    /// lazily as symbol keys are used.
    symbol_keys: std.StringHashMapUnmanaged(JSValue) = .empty,
    /// `Symbol.for(k)` registry: the same symbol for the same key.
    symbol_registry: std.StringHashMapUnmanaged(JSValue) = .empty,
    /// The well-known `Symbol.iterator` value (the only one wired into
    /// real behavior). Set in setupGlobals.
    symbol_iterator: ?JSValue = null,
    /// The stack-depth guard: recursing below this native stack address
    /// raises the real `RangeError: Maximum call stack size exceeded`
    /// instead of segfaulting (Test262's tco-* tests found this). Set
    /// from @frameAddress() at run()/runModule() entry (stacks grow
    /// down; byte-based, so it adapts to Debug/Release frame sizes) and
    /// swapped per fiber in resumeFiber. Zero = unguarded (direct
    /// embedder calls that never went through run()).
    stack_limit: usize = 0,

    /// Native-stack budget assumed for the main thread (typical ulimit
    /// is 8 MiB; leave headroom for panic handling and the host below
    /// run()'s frame).
    const main_stack_budget: usize = 6 * 1024 * 1024;
    /// Reserved floor inside each 8 MiB fiber stack.
    const fiber_stack_margin: usize = 1024 * 1024;

    pub fn init(backing_allocator: Allocator, console_writer: *std.Io.Writer) !Interpreter {
        var self: Interpreter = .{
            .arena_state = std.heap.ArenaAllocator.init(backing_allocator),
            .global_env = undefined,
            .console_writer = console_writer,
        };
        const arena = self.arena_state.allocator();
        const global_env = try arena.create(Environment);
        global_env.* = .{ .parent = null };
        self.global_env = global_env;
        return self;
    }

    /// Frees every value/environment/closure this interpreter ever
    /// allocated, in one shot -- see the module-level doc comment on the
    /// "one arena per run" design (environment.zig).
    pub fn deinit(self: *Interpreter) void {
        self.arena_state.deinit();
    }

    /// Parses + evaluates a whole script; returns the completion value of
    /// the last top-level statement (UNDEFINED if the program is empty or
    /// ends on a non-value-producing statement). An uncaught JS exception
    /// surfaces as `error.UncaughtException` with the thrown value left in
    /// `pending_exception` for inspection -- `error.JsThrow` is a private
    /// signal that never escapes this module's public API.
    pub fn run(self: *Interpreter, source: []const u8) anyerror!JSValue {
        self.pending_exception = null; // stale state from a previous run()
        self.stack_limit = @frameAddress() -| main_stack_budget;
        if (!self.globals_ready) {
            try builtins.setupGlobals(self);
            self.globals_ready = true;
        }
        const arena = self.arena_state.allocator();
        if (self.script_env == null) self.script_env = try self.global_env.child(arena);
        const parser = try zfunctions.Parser.init(arena, source);
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

    /// Installs a host-provided global binding (QuickJS-libc-style: the
    /// engine stays free of any runtime concern; hosts like z-run add
    /// their `os`/`std` objects through this). Retains the value. Define
    /// BEFORE the first run() if user code must see it from the first
    /// statement (globals land in global_env, above the script scope, so
    /// user `let`/`const` may shadow them -- exactly like `console`).
    pub fn defineGlobal(self: *Interpreter, name: []const u8, value: JSValue) !void {
        try self.global_env.define(self.arena_state.allocator(), name, value.retain());
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
        const arena = self.arena_state.allocator();

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
                const cycle = try JSValue.newError(self.arena_state.allocator(), .type_error, "Chaining cycle detected for promise");
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
    fn settlePromise(self: *Interpreter, p: JSValue, state: zvalue.PromiseState, value: JSValue) anyerror!void {
        const arena = self.arena_state.allocator();
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
    fn subscribePromise(self: *Interpreter, p: JSValue, on_fulfilled: ?JSValue, on_rejected: ?JSValue, derived: ?JSValue) anyerror!void {
        const arena = self.arena_state.allocator();
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
        const derived = try JSValue.newPromise(self.arena_state.allocator());
        try self.subscribePromise(p, on_fulfilled, on_rejected, derived);
        return derived;
    }

    /// Freshly-fulfilled promise (Promise.resolve on a non-promise).
    pub fn fulfilledPromise(self: *Interpreter, value: JSValue) anyerror!JSValue {
        const p = try JSValue.newPromise(self.arena_state.allocator());
        try self.settlePromise(p, .fulfilled, value);
        return p;
    }

    pub fn rejectedPromise(self: *Interpreter, reason: JSValue) anyerror!JSValue {
        const p = try JSValue.newPromise(self.arena_state.allocator());
        try self.settlePromise(p, .rejected, reason);
        return p;
    }

    // ===== Modules (import/export) =====

    pub fn setModuleLoader(self: *Interpreter, loader: ModuleLoader) void {
        self.module_loader = loader;
    }

    /// Loads and evaluates a module graph from its entry specifier, then
    /// drains the event loop (async-heavy modules behave like run()).
    /// The loader must be set first.
    pub fn runModule(self: *Interpreter, specifier: []const u8) anyerror!JSValue {
        self.pending_exception = null;
        self.stack_limit = @frameAddress() -| main_stack_budget;
        if (!self.globals_ready) {
            try builtins.setupGlobals(self);
            self.globals_ready = true;
        }
        const arena = self.arena_state.allocator();
        if (self.script_env == null) self.script_env = try self.global_env.child(arena);
        _ = self.loadModule(specifier, null) catch |err| {
            if (err != error.JsThrow) return err;
            return error.UncaughtException;
        };
        self.runEventLoop() catch |err| {
            if (err != error.JsThrow) return err;
            return error.UncaughtException;
        };
        return JSValue.UNDEFINED;
    }

    /// Resolve + parse + evaluate one module, once (cache by resolved
    /// path). Cycles are the documented narrowing: bindings snapshot at
    /// the end of a module's evaluation instead of staying live, so a
    /// dependency cycle can't be linked -- catchable error instead.
    fn loadModule(self: *Interpreter, specifier: []const u8, referrer: ?[]const u8) anyerror!*ModuleRecord {
        const arena = self.arena_state.allocator();
        const loader = self.module_loader orelse
            return self.throwError(.syntax_error, "Cannot use import statement outside a module", .{});
        const loaded = (try loader.load(loader.ctx, arena, specifier, referrer)) orelse
            return self.throwError(.generic, "Cannot find module '{s}' imported from {s}", .{ specifier, referrer orelse "<entry>" });
        if (self.modules.get(loaded.path)) |rec| {
            if (rec.state == .loading) {
                return self.throwError(.generic, "Circular dependency detected: '{s}' (live bindings are not supported)", .{loaded.path});
            }
            return rec;
        }
        const rec = try arena.create(ModuleRecord);
        rec.* = .{ .path = loaded.path, .exports = try JSValue.newObject(arena), .state = .loading };
        try self.modules.put(arena, loaded.path, rec);

        const parser = try zfunctions.Parser.init(arena, loaded.source);
        const program = try parser.parseProgram();
        const module_env = try self.global_env.child(arena);

        // Import pre-pass: dependencies evaluate first (DFS), then their
        // exports bind here -- snapshots, taken after the dep finished.
        for (program) |stmt| {
            if (stmt.data != .import_decl) continue;
            const imp = stmt.data.import_decl;
            const dep = try self.loadModule(imp.source, rec.path);
            if (imp.namespace_local) |ns| {
                try module_env.define(arena, ns, dep.exports.retain());
            }
            if (imp.default_local) |dl| {
                const v = dep.exports.object.value.get("default") orelse
                    return self.throwError(.syntax_error, "The requested module '{s}' does not provide an export named 'default'", .{imp.source});
                try module_env.define(arena, dl, v.retain());
            }
            for (imp.named) |spec| {
                const v = dep.exports.object.value.get(spec.imported) orelse
                    return self.throwError(.syntax_error, "The requested module '{s}' does not provide an export named '{s}'", .{ imp.source, spec.imported });
                try module_env.define(arena, spec.local, v.retain());
            }
        }

        try self.evalModuleBody(module_env, program, rec);
        rec.state = .evaluated;
        return rec;
    }

    /// The module-flavored evalBody: same hoisting (the pre-passes see
    /// through `export` wrappers), plus export handling. Exported values
    /// are collected AFTER the body runs -- `export { x }` before the
    /// declaration works, and an `export let` mutated during evaluation
    /// exports its final value.
    fn evalModuleBody(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement, rec: *ModuleRecord) anyerror!void {
        const arena = self.arena_state.allocator();
        try self.hoistVarScope(env, stmts);
        try self.hoistLexical(env, stmts);

        var decl_names: std.ArrayList([]const u8) = .empty;
        var local_specs: std.ArrayList(zstatements.ExportSpecifier) = .empty;

        for (stmts) |stmt| {
            switch (stmt.data) {
                .import_decl => {}, // bound by the pre-pass
                .export_decl => |e| switch (e) {
                    .declaration => |inner| {
                        _ = try self.evalStatement(env, inner);
                        try self.collectDeclaredNames(inner, &decl_names);
                    },
                    .default => |expr| {
                        const v = try self.evalExpression(env, expr);
                        try rec.exports.object.value.set("default", v.retain());
                    },
                    .named => |n| {
                        if (n.source) |src| {
                            const dep = try self.loadModule(src, rec.path);
                            for (n.specifiers) |spec| {
                                const v = dep.exports.object.value.get(spec.local) orelse
                                    return self.throwError(.syntax_error, "The requested module '{s}' does not provide an export named '{s}'", .{ src, spec.local });
                                try rec.exports.object.value.set(spec.exported, v.retain());
                            }
                        } else {
                            for (n.specifiers) |spec| try local_specs.append(arena, spec);
                        }
                    },
                    .all => |a| {
                        // `export *` re-exports everything EXCEPT default
                        // (the real rule).
                        const dep = try self.loadModule(a.source, rec.path);
                        const keys = try dep.exports.object.value.keys(arena);
                        defer arena.free(keys);
                        for (keys) |k| {
                            if (std.mem.eql(u8, k, "default")) continue;
                            try rec.exports.object.value.set(k, dep.exports.object.value.get(k).?.retain());
                        }
                    },
                },
                else => _ = try self.evalStatement(env, stmt),
            }
        }

        for (decl_names.items) |name| {
            const v = env.get(name) orelse continue;
            try rec.exports.object.value.set(name, v.retain());
        }
        for (local_specs.items) |spec| {
            const v = env.get(spec.local) orelse
                return self.throwError(.syntax_error, "Export '{s}' is not defined in module", .{spec.local});
            try rec.exports.object.value.set(spec.exported, v.retain());
        }
    }

    /// Every name an exported declaration binds: declarator patterns
    /// (destructuring included), function and class names.
    fn collectDeclaredNames(self: *Interpreter, stmt: *zstatements.Statement, list: *std.ArrayList([]const u8)) anyerror!void {
        const arena = self.arena_state.allocator();
        switch (stmt.data) {
            .variable => |v| for (v.declarators) |d| try self.collectPatternNames(d.pattern, list),
            .function_declaration => |ptr| {
                try list.append(arena, zfunctions.asFunctionNode(ptr).kind.function_decl.name);
            },
            .class_declaration => |ptr| {
                try list.append(arena, zfunctions.asClassNode(ptr).name.?);
            },
            else => {},
        }
    }

    fn collectPatternNames(self: *Interpreter, pattern: *const zstatements.BindingPattern, list: *std.ArrayList([]const u8)) anyerror!void {
        const arena = self.arena_state.allocator();
        switch (pattern.*) {
            .identifier => |id| try list.append(arena, id.name),
            .array => |arr| {
                for (arr.elements) |maybe_el| {
                    if (maybe_el) |el| try self.collectPatternNames(el.pattern, list);
                }
                if (arr.rest) |r| try self.collectPatternNames(r, list);
            },
            .object => |obj| {
                for (obj.properties) |p| try self.collectPatternNames(p.value, list);
                if (obj.rest) |r| try list.append(arena, r.name);
            },
        }
    }

    // ===== Fibers (generators / async functions) =====

    /// Scheduler -> fiber, with current_fiber bookkeeping and fatal
    /// (non-JS) error propagation. Returns when the fiber suspends or
    /// finishes.
    fn resumeFiber(self: *Interpreter, fs: *FiberState) anyerror!void {
        const prev = self.current_fiber;
        const prev_limit = self.stack_limit;
        self.current_fiber = fs;
        self.stack_limit = fs.fiber.stack_floor + fiber_stack_margin;
        fs.fiber.switchTo();
        self.current_fiber = prev;
        self.stack_limit = prev_limit;
        if (fs.fatal_error) |err| {
            fs.fatal_error = null;
            return err;
        }
    }

    /// Calling `function*` builds the generator object -- a plain object
    /// whose `next` native drives the (not-yet-started) fiber. The body
    /// runs nothing until the first next() (real semantics).
    fn makeGeneratorObject(self: *Interpreter, fnode: *zfunctions.FunctionNode, closure_env: *Environment, this_value: ?JSValue, args: []const JSValue) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        const fs = try arena.create(FiberState);
        fs.* = .{
            .kind = .generator,
            .interp = self,
            .fiber = undefined,
            .fnode = fnode,
            .closure_env = closure_env,
            .this_value = this_value,
            .args = try arena.dupe(JSValue, args),
        };
        fs.fiber = try fiber_mod.Fiber.init(arena, fiberEntry, fs);
        var obj = try JSValue.newObject(arena);
        try obj.object.value.set("next", try JSValue.newFunction(arena, .{ .ctx = fs, .name = "next", .call = generatorNext }));
        // A generator IS its own iterable: `gen()[Symbol.iterator]()`
        // returns the generator itself (so `[...gen()]` works via the
        // Symbol.iterator path too, and `gen()[Symbol.iterator]() === gen()`).
        if (self.symbol_iterator) |sym| {
            const key = try self.encodeKey(sym);
            try obj.object.value.set(key, try self.nativeMethod("iterator", "self", iteratorSelf));
        }
        return obj;
    }

    /// Calling `async function` starts the body IMMEDIATELY on its fiber
    /// (synchronous until the first await -- real semantics) and returns
    /// the promise; completion settles it from inside the entry.
    fn runAsyncFunction(self: *Interpreter, fnode: *zfunctions.FunctionNode, closure_env: *Environment, this_value: ?JSValue, args: []const JSValue) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        const fs = try arena.create(FiberState);
        fs.* = .{
            .kind = .async_fn,
            .interp = self,
            .fiber = undefined,
            .fnode = fnode,
            .closure_env = closure_env,
            .this_value = this_value,
            .args = try arena.dupe(JSValue, args),
            .promise = try JSValue.newPromise(arena),
        };
        fs.fiber = try fiber_mod.Fiber.init(arena, fiberEntry, fs);
        try self.resumeFiber(fs);
        return fs.promise.?;
    }

    // ===== Timers (setTimeout macrotasks) =====

    pub fn addTimer(self: *Interpreter, callback: JSValue, delay_ms: f64) !f64 {
        const arena = self.arena_state.allocator();
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
    fn runEventLoop(self: *Interpreter) anyerror!void {
        const arena = self.arena_state.allocator();
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

    // ===== Exception machinery =====

    /// Raise an arbitrary JSValue as a JS exception (throw statement,
    /// rethrow). See the invariant on `pending_exception`. Public so
    /// builtins.zig's natives can raise catchable errors too.
    pub fn throwValue(self: *Interpreter, value: JSValue) anyerror {
        self.pending_exception = value;
        return error.JsThrow;
    }

    /// Build an engine error (ReferenceError/TypeError/...) and raise it.
    /// allocPrint's OOM propagates as OOM, never as JsThrow.
    pub fn throwError(self: *Interpreter, kind: zvalue.ErrorKind, comptime fmt: []const u8, args: anytype) anyerror {
        const arena = self.arena_state.allocator();
        const msg = try std.fmt.allocPrint(arena, fmt, args);
        return self.throwValue(try JSValue.newError(arena, kind, msg));
    }

    /// Everything a statement can do, flattened into one value: the
    /// Completion channel (normal/return/break/continue) and the JsThrow
    /// channel. This is the merge point try/finally hangs on.
    const Outcome = union(enum) {
        completion: Completion,
        thrown: JSValue,
    };

    /// Runs a statement, capturing BOTH abrupt channels. Catches ONLY
    /// error.JsThrow; OutOfMemory, NotImplemented, etc. propagate
    /// untouched (a JS `catch` must never swallow an interpreter feature
    /// gap).
    fn runCapturing(self: *Interpreter, env: *Environment, stmt: *zstatements.Statement) anyerror!Outcome {
        const c = self.evalStatement(env, stmt) catch |err| {
            if (err != error.JsThrow) return err;
            const ex = self.pending_exception orelse unreachable; // raiser invariant
            self.pending_exception = null; // take
            return Outcome{ .thrown = ex };
        };
        return Outcome{ .completion = c };
    }

    /// Re-delivers an Outcome on its original channel.
    fn deliver(self: *Interpreter, outcome: Outcome) anyerror!Completion {
        return switch (outcome) {
            .completion => |c| c,
            .thrown => |ex| self.throwValue(ex),
        };
    }

    /// The raw statement loop -- no hoisting. Callers go through
    /// `evalBody` (function/script bodies: var + lexical pre-passes) or
    /// `evalStatementList` (blocks: lexical pre-pass only).
    pub fn evalProgram(self: *Interpreter, env: *Environment, program: []const *zstatements.Statement) anyerror!Completion {
        var last_value: JSValue = JSValue.UNDEFINED;
        for (program) |stmt| {
            const c = try self.evalStatement(env, stmt);
            if (c.type != .normal) return c;
            last_value = c.value;
        }
        return .{ .type = .normal, .value = last_value };
    }

    /// Function-body / script entry: `var` names hoist here (defined as
    /// undefined unless already present -- parameters win), then the
    /// ordinary per-StatementList lexical hoisting runs.
    fn evalBody(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement) anyerror!Completion {
        try self.hoistVarScope(env, stmts);
        return self.evalStatementList(env, stmts);
    }

    /// Every StatementList entry: function declarations become callable
    /// immediately, let/const/class names enter their TDZ, then the
    /// statements run.
    fn evalStatementList(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement) anyerror!Completion {
        try self.hoistLexical(env, stmts);
        return self.evalProgram(env, stmts);
    }

    // ===== Hoisting pre-passes =====

    /// Collects every `var`-declared name in a function/script body,
    /// recursing through blocks, if arms, loop bodies AND loop heads,
    /// switch cases, try/catch/finally, and labelled statements -- but
    /// never into nested function or class bodies (their vars are their
    /// own). Annex B's sloppy-mode escape of block-level function
    /// declarations to function scope is deliberately NOT implemented
    /// (this engine is always-strict; see README).
    fn hoistVarScope(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement) anyerror!void {
        for (stmts) |stmt| try self.hoistVarsInStatement(env, stmt);
    }

    fn hoistVarsInStatement(self: *Interpreter, env: *Environment, stmt: *zstatements.Statement) anyerror!void {
        switch (stmt.data) {
            .variable => |v| if (v.kind == .@"var") {
                for (v.declarators) |decl| try self.hoistVarPattern(env, decl.pattern);
            },
            .block => |stmts| try self.hoistVarScope(env, stmts),
            .if_stmt => |s| {
                try self.hoistVarsInStatement(env, s.consequent);
                if (s.alternate) |alt| try self.hoistVarsInStatement(env, alt);
            },
            .while_stmt => |s| try self.hoistVarsInStatement(env, s.body),
            .do_while => |s| try self.hoistVarsInStatement(env, s.body),
            .for_stmt => |s| {
                switch (s.head) {
                    .c_style => |head| if (head.init) |init_clause| {
                        switch (init_clause) {
                            .decl => |d| if (d.kind == .@"var") {
                                for (d.declarators) |decl| try self.hoistVarPattern(env, decl.pattern);
                            },
                            .expr => {},
                        }
                    },
                    .for_in => |head| try self.hoistVarForBinding(env, head.binding),
                    .for_of => |head| try self.hoistVarForBinding(env, head.binding),
                }
                try self.hoistVarsInStatement(env, s.body);
            },
            .labelled => |s| try self.hoistVarsInStatement(env, s.body),
            .try_stmt => |s| {
                try self.hoistVarsInStatement(env, s.block);
                if (s.handler) |h| try self.hoistVarsInStatement(env, h.body);
                if (s.finalizer) |fin| try self.hoistVarsInStatement(env, fin);
            },
            .switch_stmt => |s| for (s.cases) |case| {
                for (case.consequent) |cs| try self.hoistVarsInStatement(env, cs);
            },
            .with_stmt => |s| try self.hoistVarsInStatement(env, s.body),
            // `export var x = ...` must hoist like its bare declaration.
            .export_decl => |e| switch (e) {
                .declaration => |inner| try self.hoistVarsInStatement(env, inner),
                else => {},
            },
            else => {},
        }
    }

    fn hoistVarForBinding(self: *Interpreter, env: *Environment, binding: zstatements.ForBinding) anyerror!void {
        switch (binding) {
            .declared => |d| if (d.kind == .@"var") try self.hoistVarPattern(env, d.pattern),
            .existing, .existing_pattern => {},
        }
    }

    /// Defines every name a var declarator's pattern binds as undefined,
    /// unless this env already has it (parameters, earlier vars).
    fn hoistVarPattern(self: *Interpreter, env: *Environment, pattern: *const zstatements.BindingPattern) anyerror!void {
        const arena = self.arena_state.allocator();
        switch (pattern.*) {
            .identifier => |id| if (!env.bindings.contains(id.name)) {
                try env.define(arena, id.name, JSValue.UNDEFINED);
            },
            .array => |arr| {
                for (arr.elements) |maybe_el| {
                    if (maybe_el) |el| try self.hoistVarPattern(env, el.pattern);
                }
                if (arr.rest) |r| try self.hoistVarPattern(env, r);
            },
            .object => |obj| {
                for (obj.properties) |p| try self.hoistVarPattern(env, p.value);
                if (obj.rest) |r| if (!env.bindings.contains(r.name)) {
                    try env.define(arena, r.name, JSValue.UNDEFINED);
                };
            },
        }
    }

    /// The per-StatementList lexical pre-pass, over DIRECT statements
    /// only (nested blocks get their own on entry). Function declarations
    /// hoist fully (mutual recursion, call-before-declaration);
    /// let/const/class names enter the TDZ; duplicate declarations in the
    /// same scope are the real "already been declared" SyntaxError
    /// (catchable here since this engine has no parse-time scope
    /// analysis).
    fn hoistLexical(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement) anyerror!void {
        const arena = self.arena_state.allocator();
        for (stmts) |stmt| {
            switch (stmt.data) {
                .function_declaration => |ptr| {
                    const fnode = zfunctions.asFunctionNode(ptr);
                    const name = fnode.kind.function_decl.name;
                    // `let f; function f() {}` is the real SyntaxError;
                    // f-over-f or f-over-var stays legal (later wins).
                    if (env.tdz.contains(name)) {
                        return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{name});
                    }
                    const value = try self.makeClosure(env, fnode);
                    try env.define(arena, name, value);
                },
                .variable => |v| {
                    if (v.kind == .@"var") {
                        // Bindings come from the var pre-pass; here vars
                        // only participate in the redeclaration check
                        // (`let x; var x;` is the real SyntaxError).
                        for (v.declarators) |decl| try self.checkVarNotShadowingLexical(env, decl.pattern);
                        continue;
                    }
                    for (v.declarators) |decl| try self.markPatternTDZ(env, decl.pattern);
                },
                .class_declaration => |ptr| {
                    const cnode = zfunctions.asClassNode(ptr);
                    const name = cnode.name.?;
                    if (env.declaresLocally(name)) {
                        return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{name});
                    }
                    try env.markTDZ(arena, name);
                },
                // `export function f() {}` hoists exactly like the bare
                // declaration (call-before-declaration inside the module).
                .export_decl => |e| switch (e) {
                    .declaration => |inner| try self.hoistLexical(env, &.{inner}),
                    else => {},
                },
                else => {},
            }
        }
    }

    fn markPatternTDZ(self: *Interpreter, env: *Environment, pattern: *const zstatements.BindingPattern) anyerror!void {
        const arena = self.arena_state.allocator();
        switch (pattern.*) {
            .identifier => |id| {
                if (env.declaresLocally(id.name)) {
                    return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{id.name});
                }
                try env.markTDZ(arena, id.name);
            },
            .array => |arr| {
                for (arr.elements) |maybe_el| {
                    if (maybe_el) |el| try self.markPatternTDZ(env, el.pattern);
                }
                if (arr.rest) |r| try self.markPatternTDZ(env, r);
            },
            .object => |obj| {
                for (obj.properties) |p| try self.markPatternTDZ(env, p.value);
                if (obj.rest) |r| {
                    if (env.declaresLocally(r.name)) {
                        return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{r.name});
                    }
                    try env.markTDZ(arena, r.name);
                }
            },
        }
    }

    fn checkVarNotShadowingLexical(self: *Interpreter, env: *Environment, pattern: *const zstatements.BindingPattern) anyerror!void {
        switch (pattern.*) {
            .identifier => |id| if (env.tdz.contains(id.name)) {
                return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{id.name});
            },
            .array => |arr| {
                for (arr.elements) |maybe_el| {
                    if (maybe_el) |el| try self.checkVarNotShadowingLexical(env, el.pattern);
                }
                if (arr.rest) |r| try self.checkVarNotShadowingLexical(env, r);
            },
            .object => |obj| {
                for (obj.properties) |p| try self.checkVarNotShadowingLexical(env, p.value);
                if (obj.rest) |r| if (env.tdz.contains(r.name)) {
                    return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{r.name});
                };
            },
        }
    }

    // ===== Statements =====

    pub fn evalStatement(self: *Interpreter, env: *Environment, stmt: *zstatements.Statement) anyerror!Completion {
        const arena = self.arena_state.allocator();
        switch (stmt.data) {
            .empty, .debugger => return .{},
            .expr_stmt => |expr| {
                const v = try self.evalExpression(env, expr);
                return .{ .type = .normal, .value = v };
            },
            .block => |stmts| {
                const block_env = try env.child(arena);
                return self.evalStatementList(block_env, stmts);
            },
            .variable => |v| {
                for (v.declarators) |decl| {
                    // An initializer-less `var a;` is a no-op at execution
                    // time -- the hoist pre-pass already created the
                    // binding, and real JS does NOT reset an existing
                    // value (`function h(a) { var a; return a; }` keeps
                    // the argument).
                    if (v.kind == .@"var" and decl.init == null) continue;
                    const value = if (decl.init) |init_expr| try self.evalExpression(env, init_expr) else JSValue.UNDEFINED;
                    // var writes to its hoisted function-scope binding
                    // (that's how `if (1) { var x = 5; } x` works);
                    // let/const define here, ending their TDZ.
                    try self.bindPattern(env, decl.pattern, value, if (v.kind == .@"var") .assign else .define);
                }
                return .{};
            },
            .if_stmt => |s| {
                const test_v = try self.evalExpression(env, s.test_expr);
                if (coercion.isTruthy(test_v)) return self.evalStatement(env, s.consequent);
                if (s.alternate) |alt| return self.evalStatement(env, alt);
                return .{};
            },
            .while_stmt => |s| return self.evalWhile(env, s, &.{}),
            .do_while => |s| return self.evalDoWhile(env, s, &.{}),
            .for_stmt => |s| return self.evalForStatement(env, s, &.{}),
            .return_stmt => |arg| {
                const v = if (arg) |e| try self.evalExpression(env, e) else JSValue.UNDEFINED;
                return .{ .type = .return_completion, .value = v };
            },
            // Label validity (label exists, continue targets a loop) was
            // already guaranteed at parse time by z-statements
            // (UndefinedLabel/IllegalContinue), so the runtime can trust
            // every target resolves to some enclosing labelled statement.
            .break_stmt => |label| return .{ .type = .break_completion, .target = label },
            .continue_stmt => |label| return .{ .type = .continue_completion, .target = label },
            // ECMA-262 14.13.4 LabelledEvaluation: collect the whole label
            // chain (`a: b: for (...)` attaches BOTH labels to the loop)
            // and hand it to the loop as its label set; for non-loop
            // bodies, a matching labelled break converts to normal here.
            .labelled => |s| {
                var labels: std.ArrayList([]const u8) = .empty;
                try labels.append(arena, s.label);
                var inner = s.body;
                while (inner.data == .labelled) {
                    try labels.append(arena, inner.data.labelled.label);
                    inner = inner.data.labelled.body;
                }
                const c = switch (inner.data) {
                    .while_stmt => |w| try self.evalWhile(env, w, labels.items),
                    .do_while => |d| try self.evalDoWhile(env, d, labels.items),
                    .for_stmt => |f| try self.evalForStatement(env, f, labels.items),
                    else => try self.evalStatement(env, inner),
                };
                if (c.type == .break_completion) {
                    if (c.target) |t| {
                        if (labelIn(t, labels.items)) return .{ .type = .normal, .value = c.value };
                    }
                }
                return c;
            },
            .function_declaration => |ptr| {
                const fnode = zfunctions.asFunctionNode(ptr);
                const value = try self.makeClosure(env, fnode);
                const name = switch (fnode.kind) {
                    .function_decl => |d| d.name,
                    else => unreachable, // z-functions always produces .function_decl at statement position
                };
                try env.define(arena, name, value);
                return .{};
            },
            .class_declaration => |ptr| {
                const cnode = zfunctions.asClassNode(ptr);
                const value = try self.evalClass(env, cnode);
                // Declarations always carry a name (MissingClassName is a
                // parse error otherwise).
                try env.define(arena, cnode.name.?, value.retain());
                return .{};
            },
            // Reaching these through evalStatement means they're NOT at a
            // module's top level (evalModuleBody intercepts those) -- a
            // classic script, or nested in a block. Real JS rejects both
            // at parse time; ours is a catchable runtime error.
            .import_decl => return self.throwError(.syntax_error, "Cannot use import statement outside a module", .{}),
            .export_decl => return self.throwError(.syntax_error, "Unexpected token 'export'", .{}),
            .throw_stmt => |arg| {
                // The `try` on the argument is load-bearing: `throw f()`
                // where f itself throws must propagate f's exception.
                const v = try self.evalExpression(env, arg);
                return self.throwValue(v);
            },
            // ECMA-262 14.15.3 TryStatement evaluation. h.body/s.block/
            // s.finalizer are always `.block` statements, so the existing
            // `.block` arm supplies each fresh scope (the catch_env holding
            // the param becomes its parent -- spec-correct nesting for
            // free). Completion.target rides along inside
            // Outcome.completion untouched, so future labelled-break
            // support changes nothing here.
            .try_stmt => |s| {
                var result = try self.runCapturing(env, s.block);

                if (result == .thrown and s.handler != null) {
                    const h = s.handler.?;
                    const catch_env = try env.child(arena);
                    if (h.param) |p| try self.bindPattern(catch_env, p, result.thrown, .define);
                    // A throw from the catch body becomes the new .thrown
                    // result; the original exception is dropped
                    // (spec-correct).
                    result = try self.runCapturing(catch_env, h.body);
                }

                // The finalizer runs on EVERY path (normal, caught,
                // uncaught-throw, return/break/continue). Its result
                // overrides iff it is abrupt: `try { return 1 } finally
                // { return 2 }` is 2, and a finally-throw drops the
                // original exception. A *normal* finally keeps `result`
                // INCLUDING its value: `try { 1 } finally { 2 }` is 1.
                if (s.finalizer) |fin| {
                    const fin_outcome = try self.runCapturing(env, fin);
                    switch (fin_outcome) {
                        .completion => |fc| if (fc.type != .normal) {
                            result = fin_outcome;
                        },
                        .thrown => result = fin_outcome,
                    }
                }

                return try self.deliver(result);
            },
            // ECMA-262 14.12 CaseBlockEvaluation. The AST's flat case order
            // is already "A clauses, default, B clauses", so one selector
            // scan (skipping default) equals the spec's A-then-B search
            // order, and executing from the chosen index to the end gives
            // natural fallthrough -- INCLUDING the default's statements
            // when the match came before it (real JS semantics).
            .switch_stmt => |s| {
                const disc = try self.evalExpression(env, s.discriminant); // evaluated ONCE
                // The whole CaseBlock is ONE lexical scope (a let in one
                // case is visible in later ones -- real JS quirk), so the
                // lexical pre-pass runs over every case's consequent
                // before any selector/statement evaluates.
                const switch_env = try env.child(arena);
                for (s.cases) |case| try self.hoistLexical(switch_env, case.consequent);

                var start_index: ?usize = null;
                for (s.cases, 0..) |case, i| {
                    const t = case.test_expr orelse continue;
                    const v = try self.evalExpression(switch_env, t);
                    if (zvalue.equality.strictEquals(disc, v)) {
                        start_index = i;
                        break;
                    }
                }
                if (start_index == null) {
                    for (s.cases, 0..) |case, i| {
                        if (case.test_expr == null) {
                            start_index = i;
                            break;
                        }
                    }
                }

                var last_value: JSValue = JSValue.UNDEFINED;
                if (start_index) |start| {
                    for (s.cases[start..]) |case| {
                        for (case.consequent) |case_stmt| {
                            const c = try self.evalStatement(switch_env, case_stmt);
                            switch (c.type) {
                                .normal => last_value = c.value,
                                .break_completion => {
                                    if (c.target == null) return .{ .type = .normal, .value = last_value };
                                    return c; // labelled break: handled by the labelled wrapper/loop
                                },
                                .return_completion, .continue_completion => return c,
                            }
                        }
                    }
                }
                return .{ .type = .normal, .value = last_value };
            },
            .with_stmt => return error.NotImplemented,
        }
    }

    // ===== Loops (each takes the labelSet attached by any enclosing
    // labelled statement -- ECMA-262's labelSet parameter; empty for a
    // plain unlabelled loop) =====

    /// Decides whether this loop owns an abrupt break/continue: unlabelled
    /// ones always belong to the nearest enclosing loop; labelled ones only
    /// if the target is in this loop's label set.
    fn loopOwns(target: ?[]const u8, labels: []const []const u8) bool {
        const t = target orelse return true;
        return labelIn(t, labels);
    }

    fn evalWhile(self: *Interpreter, env: *Environment, s: anytype, labels: []const []const u8) anyerror!Completion {
        while (coercion.isTruthy(try self.evalExpression(env, s.test_expr))) {
            const c = try self.evalStatement(env, s.body);
            switch (c.type) {
                .break_completion => {
                    if (loopOwns(c.target, labels)) break;
                    return c;
                },
                .continue_completion => {
                    if (!loopOwns(c.target, labels)) return c;
                },
                .return_completion => return c,
                .normal => {},
            }
        }
        return .{};
    }

    fn evalDoWhile(self: *Interpreter, env: *Environment, s: anytype, labels: []const []const u8) anyerror!Completion {
        while (true) {
            const c = try self.evalStatement(env, s.body);
            switch (c.type) {
                .break_completion => {
                    if (loopOwns(c.target, labels)) break;
                    return c;
                },
                .continue_completion => {
                    if (!loopOwns(c.target, labels)) return c;
                },
                .return_completion => return c,
                .normal => {},
            }
            if (!coercion.isTruthy(try self.evalExpression(env, s.test_expr))) break;
        }
        return .{};
    }

    fn evalForStatement(self: *Interpreter, env: *Environment, s: anytype, labels: []const []const u8) anyerror!Completion {
        const arena = self.arena_state.allocator();
        switch (s.head) {
            .c_style => |head| {
                const loop_env = try env.child(arena);
                if (head.init) |init_clause| {
                    switch (init_clause) {
                        .decl => |d| {
                            for (d.declarators) |decl| {
                                // Same no-op rule as the .variable arm:
                                // `for (var i; ...)` must not reset a
                                // hoisted binding.
                                if (d.kind == .@"var" and decl.init == null) continue;
                                const value = if (decl.init) |e| try self.evalExpression(loop_env, e) else JSValue.UNDEFINED;
                                try self.bindPattern(loop_env, decl.pattern, value, if (d.kind == .@"var") .assign else .define);
                            }
                        },
                        .expr => |e| _ = try self.evalExpression(loop_env, e),
                    }
                }
                while (true) {
                    if (head.test_expr) |t| {
                        if (!coercion.isTruthy(try self.evalExpression(loop_env, t))) break;
                    }
                    const c = try self.evalStatement(loop_env, s.body);
                    switch (c.type) {
                        .break_completion => {
                            if (loopOwns(c.target, labels)) break;
                            return c;
                        },
                        .continue_completion => {
                            if (!loopOwns(c.target, labels)) return c;
                        },
                        .return_completion => return c,
                        .normal => {},
                    }
                    if (head.update) |u| _ = try self.evalExpression(loop_env, u);
                }
                return .{};
            },
            .for_in => |head| return self.evalForIn(env, head, s.body, labels),
            .for_of => |head| return self.evalForOf(env, head, s.body, labels),
        }
    }

    /// The source side of array destructuring, shared by binding patterns
    /// and destructuring assignment: the same narrowed iterables as for-of
    /// (arrays by element, strings by code point); anything else is the
    /// real TypeError Node raises.
    fn iterableItems(self: *Interpreter, value: JSValue) anyerror![]const JSValue {
        const arena = self.arena_state.allocator();
        return switch (value) {
            .array => |box| box.value.toSlice(),
            .string => |box| blk: {
                var cps: std.ArrayList(JSValue) = .empty;
                var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
                while (it.nextCodepointSlice()) |cp| {
                    try cps.append(arena, try JSValue.newString(arena, cp));
                }
                break :blk try cps.toOwnedSlice(arena);
            },
            // A user iterable (Symbol.iterator) or a hand-written iterator
            // (duck-typed `next`) -- drained fully.
            .object => try self.drainIterator(try self.resolveIterator(value)),
            else => self.throwError(.type_error, "{s} is not iterable", .{value.typeOf()}),
        };
    }

    /// The iterator object for a `.object`: its `[Symbol.iterator]()`
    /// result if it has one, else the object itself if it's already an
    /// iterator (callable `next`). TypeError otherwise (not iterable).
    pub fn resolveIterator(self: *Interpreter, obj: JSValue) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        if (self.symbol_iterator) |sym| {
            const key = try self.encodeKey(sym);
            const method = try self.getProperty(obj, key);
            if (method == .function) {
                const iter = try method.function.value.call(method.function.value.ctx, arena, obj, &.{});
                if (iter != .object) return self.throwError(.type_error, "Result of the Symbol.iterator method is not an object", .{});
                return iter;
            }
        }
        // Fallback: the object is itself an iterator (generator objects,
        // hand-written `{ next() {} }`).
        if ((try self.getProperty(obj, "next")) == .function) return obj;
        return self.throwError(.type_error, "{s} is not iterable", .{obj.typeOf()});
    }

    /// Runs an iterator object to completion, collecting its values.
    pub fn drainIterator(self: *Interpreter, iter: JSValue) anyerror![]const JSValue {
        const arena = self.arena_state.allocator();
        const next_fn = try self.getProperty(iter, "next");
        if (next_fn != .function) return self.throwError(.type_error, "iterator.next is not a function", .{});
        var out: std.ArrayList(JSValue) = .empty;
        while (true) {
            const step = try next_fn.function.value.call(next_fn.function.value.ctx, arena, iter, &.{});
            if (step != .object) return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
            if (coercion.isTruthy(try self.getProperty(step, "done"))) break;
            try out.append(arena, try self.getProperty(step, "value"));
        }
        return out.toOwnedSlice(arena);
    }

    /// `yield* iterable`: drives an inner iterable, re-yielding each of
    /// its values from the current (outer) generator and forwarding the
    /// outer's resume value into the inner. Narrowed to iterator-protocol
    /// objects (callable `next`), arrays, and strings -- no arbitrary
    /// Symbol.iterator. The expression's own value is the inner
    /// iterator's return value (arrays/strings: undefined).
    fn evalYieldDelegate(self: *Interpreter, env: *Environment, fs: *FiberState, arg_node: *zparser.Node) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        const iterable = try self.evalExpression(env, arg_node);

        // Iterator-protocol object: forward next(resume), return the
        // completion value.
        if (iterable == .object) {
            const next_fn = try self.getProperty(iterable, "next");
            if (next_fn == .function) {
                var resume_value = JSValue.UNDEFINED;
                while (true) {
                    const step = try next_fn.function.value.call(next_fn.function.value.ctx, arena, iterable, &.{resume_value});
                    if (step != .object) return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
                    if (coercion.isTruthy(try self.getProperty(step, "done"))) {
                        return self.getProperty(step, "value");
                    }
                    fs.yielded = try self.getProperty(step, "value");
                    fs.fiber.suspendSelf();
                    if (fs.resume_is_throw) {
                        fs.resume_is_throw = false;
                        return self.throwValue(fs.resume_value);
                    }
                    resume_value = fs.resume_value;
                }
            }
        }

        // Arrays and strings: re-yield each element (resume value is not
        // fed anywhere -- they aren't real iterators).
        const items = try self.iterableItems(iterable);
        for (items) |item| {
            fs.yielded = item;
            fs.fiber.suspendSelf();
            if (fs.resume_is_throw) {
                fs.resume_is_throw = false;
                return self.throwValue(fs.resume_value);
            }
        }
        return JSValue.UNDEFINED;
    }

    /// How bindPattern lands a name: `.define` creates the binding in
    /// `env` (let/const/params/catch); `.assign` writes to an existing
    /// binding up the chain -- `var` declarators, whose bindings the
    /// hoisting pre-pass already created at function scope.
    const BindMode = enum { define, assign };

    /// Recursive BindingInitialization (ECMA-262 8.6.2) -- every binding
    /// position (declarators, params, catch, for-in/of declared bindings)
    /// funnels here. Destructuring as an assignment target (`[a, b] =
    /// arr` without a declaration) is separate machinery (phase 8b), not
    /// this. Defaults are evaluated in `env` itself, so a later element's
    /// default can reference an earlier binding (`[a, b = a]` -- real
    /// spec order). Ownership: the caller keeps its reference to `value`;
    /// identifier bindings retain.
    fn bindPattern(self: *Interpreter, env: *Environment, pattern: *const zstatements.BindingPattern, value: JSValue, mode: BindMode) anyerror!void {
        const arena = self.arena_state.allocator();
        switch (pattern.*) {
            .identifier => |id| {
                const v = value.retain();
                switch (mode) {
                    .define => try env.define(arena, id.name, v),
                    // The pre-pass defined every var name; the fallback
                    // define is belt-and-braces, not a real path.
                    .assign => env.assign(id.name, v) catch try env.define(arena, id.name, v),
                }
            },
            .array => |arr_pat| {
                const items = try self.iterableItems(value);
                for (arr_pat.elements, 0..) |maybe_el, i| {
                    const el = maybe_el orelse continue; // elision hole
                    var v = if (i < items.len) items[i] else JSValue.UNDEFINED;
                    if (v == .@"undefined") {
                        if (el.default) |def| v = try self.evalExpression(env, def);
                    }
                    try self.bindPattern(env, el.pattern, v, mode);
                }
                if (arr_pat.rest) |rest_pat| {
                    var rest_arr = try JSValue.newArray(arena);
                    if (arr_pat.elements.len < items.len) {
                        for (items[arr_pat.elements.len..]) |item| {
                            _ = try rest_arr.array.value.push(item.retain());
                        }
                    }
                    try self.bindPattern(env, rest_pat, rest_arr, mode);
                }
            },
            .object => |obj_pat| {
                if (value == .@"undefined" or value == .@"null") {
                    const what: []const u8 = if (value == .@"null") "null" else "undefined";
                    if (obj_pat.properties.len > 0) {
                        return self.throwError(.type_error, "Cannot destructure property '{s}' of '{s}' as it is {s}.", .{ obj_pat.properties[0].key, what, what });
                    }
                    return self.throwError(.type_error, "Cannot destructure '{s}' as it is {s}.", .{ what, what });
                }
                // getProperty is the whole point of the reuse: string
                // `.length`, error `.message`, prototype-chain lookups on
                // objects -- all already live there.
                for (obj_pat.properties) |prop| {
                    var v = try self.getProperty(value, prop.key);
                    if (v == .@"undefined") {
                        if (prop.default) |def| v = try self.evalExpression(env, def);
                    }
                    try self.bindPattern(env, prop.value, v, mode);
                }
                if (obj_pat.rest) |rest_name| {
                    // Own keys of an object source, minus the ones already
                    // destructured; non-object sources rest to an empty
                    // object (narrowed -- real JS copies own enumerable
                    // props of the coerced object).
                    var rest_obj = try JSValue.newObject(arena);
                    if (value == .object) {
                        const keys = try value.object.value.keys(arena);
                        defer arena.free(keys);
                        outer: for (keys) |k| {
                            for (obj_pat.properties) |prop| {
                                if (std.mem.eql(u8, prop.key, k)) continue :outer;
                            }
                            try rest_obj.object.value.set(k, value.object.value.get(k).?.retain());
                        }
                    }
                    switch (mode) {
                        .define => try env.define(arena, rest_name.name, rest_obj),
                        .assign => env.assign(rest_name.name, rest_obj) catch try env.define(arena, rest_name.name, rest_obj),
                    }
                }
            },
        }
    }

    /// Destructuring *assignment* (ECMA-262 13.15.5
    /// DestructuringAssignmentEvaluation): the target is an array/object
    /// *literal* node reinterpreted as a pattern -- already validated at
    /// parse time by z-parser's isValidAssignmentPattern, so the shapes
    /// seen here are exactly the valid ones. Mirrors bindPattern's source
    /// semantics (iterableItems, getProperty lookups, defaults only on
    /// undefined), but every leaf goes through assignTo -- which is what
    /// makes member-expression targets (`[o.x] = [1]`) work, something
    /// BindingPattern can't even represent.
    fn destructuringAssign(self: *Interpreter, env: *Environment, target: *zparser.Node, value: JSValue) anyerror!void {
        const arena = self.arena_state.allocator();
        switch (target.data) {
            .array_literal => |elements| {
                const items = try self.iterableItems(value);
                for (elements, 0..) |maybe_el, i| {
                    const el = maybe_el orelse continue; // hole still consumes its index
                    if (el.data == .spread) {
                        // Parse-time validation guarantees this is last.
                        var rest_arr = try JSValue.newArray(arena);
                        if (i < items.len) {
                            for (items[i..]) |item| _ = try rest_arr.array.value.push(item.retain());
                        }
                        try self.destructuringAssignTarget(env, el.data.spread, rest_arr);
                        break;
                    }
                    var v = if (i < items.len) items[i] else JSValue.UNDEFINED;
                    var el_target = el;
                    if (el.data == .assignment and el.data.assignment.op == .assign) {
                        if (v == .@"undefined") v = try self.evalExpression(env, el.data.assignment.value);
                        el_target = el.data.assignment.target;
                    }
                    try self.destructuringAssignTarget(env, el_target, v);
                }
            },
            .object_literal => |elements| {
                if (value == .@"undefined" or value == .@"null") {
                    const what: []const u8 = if (value == .@"null") "null" else "undefined";
                    const first_key: ?[]const u8 = for (elements) |el| {
                        switch (el) {
                            .property => |p| if (!p.computed and p.key.data == .identifier) break p.key.data.identifier,
                            .spread => {},
                        }
                    } else null;
                    if (first_key) |k| {
                        return self.throwError(.type_error, "Cannot destructure property '{s}' of '{s}' as it is {s}.", .{ k, what, what });
                    }
                    return self.throwError(.type_error, "Cannot destructure '{s}' as it is {s}.", .{ what, what });
                }
                var consumed: std.ArrayList([]const u8) = .empty;
                for (elements) |el| {
                    switch (el) {
                        .property => |prop| {
                            const key = try self.propertyKeyString(env, prop.computed, prop.key);
                            try consumed.append(arena, key);
                            var v = try self.getProperty(value, key);
                            var el_target = prop.value;
                            if (el_target.data == .assignment and el_target.data.assignment.op == .assign) {
                                if (v == .@"undefined") v = try self.evalExpression(env, el_target.data.assignment.value);
                                el_target = el_target.data.assignment.target;
                            }
                            try self.destructuringAssignTarget(env, el_target, v);
                        },
                        .spread => |sp| {
                            // Object rest: own keys not already consumed;
                            // non-object sources rest to an empty object
                            // (same narrowing as bindPattern's rest). The
                            // element holds a `.spread` node wrapping the
                            // actual target.
                            const arg = sp.data.spread;
                            var rest_obj = try JSValue.newObject(arena);
                            if (value == .object) {
                                const keys = try value.object.value.keys(arena);
                                defer arena.free(keys);
                                outer: for (keys) |k| {
                                    for (consumed.items) |c| {
                                        if (std.mem.eql(u8, c, k)) continue :outer;
                                    }
                                    try rest_obj.object.value.set(k, value.object.value.get(k).?.retain());
                                }
                            }
                            try self.destructuringAssignTarget(env, arg, rest_obj);
                        },
                    }
                }
            },
            else => unreachable, // only ever called with array/object literal targets
        }
    }

    /// One target position inside a destructuring assignment: nested
    /// literals recurse as patterns; everything else (identifier, member,
    /// paren-wrapped) is an ordinary assignment leaf.
    fn destructuringAssignTarget(self: *Interpreter, env: *Environment, node: *zparser.Node, value: JSValue) anyerror!void {
        switch (node.data) {
            .array_literal, .object_literal => try self.destructuringAssign(env, node, value),
            else => try self.assignTo(env, node, value),
        }
    }

    /// Binds the loop variable for one for-in/for-of iteration. Declared
    /// let/const bindings get a FRESH child env per iteration, so
    /// closures created in the body capture that iteration's value (real
    /// let/const semantics); `for (var x of ...)` assigns to the single
    /// hoisted function-scope binding instead (real shared-var
    /// semantics). Existing bindings assign into the enclosing scope
    /// chain.
    fn bindForIteration(self: *Interpreter, env: *Environment, binding: zstatements.ForBinding, value: JSValue) anyerror!*Environment {
        const arena = self.arena_state.allocator();
        switch (binding) {
            .declared => |d| {
                if (d.kind == .@"var") {
                    try self.bindPattern(env, d.pattern, value, .assign);
                    return env;
                }
                const iter_env = try env.child(arena);
                try self.bindPattern(iter_env, d.pattern, value, .define);
                return iter_env;
            },
            .existing => |name| {
                env.assign(name.name, value) catch |err| return switch (err) {
                    error.ReferenceError => self.throwError(.reference_error, "{s} is not defined", .{name.name}),
                    error.BeforeInitialization => self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name.name}),
                };
                return env;
            },
            // `for ([a, b] of x)` over existing bindings -- a destructuring
            // assignment per iteration, no fresh env.
            .existing_pattern => |node| {
                try self.destructuringAssign(env, node, value);
                return env;
            },
        }
    }

    /// Runs one for-in/for-of iteration with the loop variable bound to
    /// `value`. Returns null to proceed to the next iteration, or a
    /// Completion the whole loop must deliver (an owned break converts to
    /// normal-and-stop; everything else abrupt propagates).
    fn forIterationStep(self: *Interpreter, env: *Environment, binding: zstatements.ForBinding, value: JSValue, body: *zstatements.Statement, labels: []const []const u8) anyerror!?Completion {
        const iter_env = try self.bindForIteration(env, binding, value);
        const c = try self.evalStatement(iter_env, body);
        switch (c.type) {
            .break_completion => {
                if (loopOwns(c.target, labels)) return Completion{};
                return c;
            },
            .continue_completion => {
                if (!loopOwns(c.target, labels)) return c;
                return null;
            },
            .return_completion => return c,
            .normal => return null,
        }
    }

    /// for-of over the built-in iterables, natively: arrays (elements),
    /// strings (Unicode code points -- the spec iterates by code point,
    /// surrogate pairs together), maps ([key, value] pair arrays), sets
    /// (values). Everything else -- plain objects included -- is a real
    /// TypeError, exactly like Node (plain objects aren't iterable there
    /// either). The one genuine gap vs. spec: user-defined iterables via
    /// Symbol.iterator, impossible until ZObject supports symbol keys.
    fn evalForOf(self: *Interpreter, env: *Environment, head: anytype, body: *zstatements.Statement, labels: []const []const u8) anyerror!Completion {
        const arena = self.arena_state.allocator();
        const iterable = try self.evalExpression(env, head.iterable);
        switch (iterable) {
            .array => |box| {
                for (box.value.toSlice()) |item| {
                    if (try self.forIterationStep(env, head.binding, item, body, labels)) |c| return c;
                }
            },
            .string => |box| {
                var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
                while (it.nextCodepointSlice()) |cp| {
                    const ch = try JSValue.newString(arena, cp);
                    if (try self.forIterationStep(env, head.binding, ch, body, labels)) |c| return c;
                }
            },
            .map => |box| {
                const pairs = try box.value.entries(arena);
                defer arena.free(pairs);
                for (pairs) |pair| {
                    var entry = try JSValue.newArray(arena);
                    _ = try entry.array.value.push(pair.key.retain());
                    _ = try entry.array.value.push(pair.value.retain());
                    if (try self.forIterationStep(env, head.binding, entry, body, labels)) |c| return c;
                }
            },
            .set => |box| {
                for (box.value.values()) |v| {
                    if (try self.forIterationStep(env, head.binding, v, body, labels)) |c| return c;
                }
            },
            // The iterator protocol: a user iterable via Symbol.iterator,
            // or an object that IS an iterator (duck-typed `next` --
            // generator objects, hand-written iterators). The completion
            // value (`done: true`'s value) is excluded, per spec.
            .object => {
                const iter = try self.resolveIterator(iterable);
                const next_fn = try self.getProperty(iter, "next");
                while (true) {
                    const step = try next_fn.function.value.call(next_fn.function.value.ctx, arena, iter, &.{});
                    if (step != .object) {
                        return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
                    }
                    if (coercion.isTruthy(try self.getProperty(step, "done"))) break;
                    const value = try self.getProperty(step, "value");
                    if (try self.forIterationStep(env, head.binding, value, body, labels)) |c| return c;
                }
            },
            else => return self.throwError(.type_error, "{s} is not iterable", .{iterable.typeOf()}),
        }
        return .{};
    }

    /// for-in over enumerable string keys: own + inherited (walking the
    /// prototype chain, shadowed keys seen once), array/string indices as
    /// STRINGS (for-in keys are always strings in real JS), and -- per
    /// spec -- zero iterations without error over null/undefined. Types
    /// with no string-keyed property model here (number, boolean, map,
    /// set, ...) iterate zero times.
    fn evalForIn(self: *Interpreter, env: *Environment, head: anytype, body: *zstatements.Statement, labels: []const []const u8) anyerror!Completion {
        const arena = self.arena_state.allocator();
        const target = try self.evalExpression(env, head.object);
        switch (target) {
            .object => |box| {
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                var keys_list: std.ArrayList([]const u8) = .empty;
                var current: ?*const @TypeOf(box.value) = &box.value;
                while (current) |o| : (current = o.getPrototype()) {
                    const ks = try o.keys(arena);
                    defer arena.free(ks);
                    for (ks) |k| {
                        if (isSymbolKey(k)) continue; // symbols never in for-in
                        if (!seen.contains(k)) {
                            try seen.put(arena, k, {});
                            try keys_list.append(arena, k);
                        }
                    }
                }
                for (keys_list.items) |k| {
                    const kv = try JSValue.newString(arena, k);
                    if (try self.forIterationStep(env, head.binding, kv, body, labels)) |c| return c;
                }
            },
            .array => |box| {
                const len = box.value.length();
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    const key_str = try std.fmt.allocPrint(arena, "{d}", .{i});
                    const kv = try JSValue.newString(arena, key_str);
                    if (try self.forIterationStep(env, head.binding, kv, body, labels)) |c| return c;
                }
            },
            .string => |box| {
                var i: usize = 0;
                while (i < box.value.data.len) : (i += 1) {
                    const key_str = try std.fmt.allocPrint(arena, "{d}", .{i});
                    const kv = try JSValue.newString(arena, key_str);
                    if (try self.forIterationStep(env, head.binding, kv, body, labels)) |c| return c;
                }
            },
            else => {}, // incl. null/undefined: zero iterations, no error (spec)
        }
        return .{};
    }

    // ===== Expressions =====

    pub fn evalExpression(self: *Interpreter, env: *Environment, node: *zparser.Node) anyerror!JSValue {
        // The stack-depth guard (byte-based: adapts to Debug/Release
        // frame sizes and to fiber stacks) -- deep call chains AND deep
        // expression trees both surface as the real RangeError instead
        // of a native stack overflow.
        if (self.stack_limit != 0 and @frameAddress() < self.stack_limit) {
            return self.throwError(.range_error, "Maximum call stack size exceeded", .{});
        }
        const arena = self.arena_state.allocator();
        switch (node.data) {
            .number_literal => |n| return JSValue.fromNumber(n),
            .string_literal => |s| return try JSValue.newString(arena, s),
            .boolean_literal => |b| return JSValue.fromBool(b),
            .null_literal => return JSValue.NULL,
            .identifier => |name| switch (env.lookup(name)) {
                .value => |v| return v,
                .tdz => return self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name}),
                .not_found => return self.throwError(.reference_error, "{s} is not defined", .{name}),
            },
            .this_expr => return env.resolveThis(),
            .paren => |inner| return self.evalExpression(env, inner),
            .sequence => |items| {
                var result: JSValue = JSValue.UNDEFINED;
                for (items) |item| result = try self.evalExpression(env, item);
                return result;
            },
            .template_literal => |t| {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(arena);
                for (t.quasis, 0..) |quasi, i| {
                    try buf.appendSlice(arena, quasi);
                    if (i < t.expressions.len) {
                        const v = try self.evalExpression(env, t.expressions[i]);
                        const s = try coercion.toDisplayString(arena, v);
                        defer arena.free(s);
                        try buf.appendSlice(arena, s);
                    }
                }
                return try JSValue.newString(arena, buf.items);
            },
            .array_literal => |elements| {
                var arr = try JSValue.newArray(arena);
                for (elements) |maybe_el| {
                    const el = maybe_el orelse {
                        _ = try arr.array.value.push(JSValue.UNDEFINED);
                        continue;
                    };
                    if (el.data == .spread) {
                        const spread_val = try self.evalExpression(env, el.data.spread);
                        for (try self.iterableItems(spread_val)) |item| _ = try arr.array.value.push(item.retain());
                        continue;
                    }
                    const v = try self.evalExpression(env, el);
                    _ = try arr.array.value.push(v.retain());
                }
                return arr;
            },
            .object_literal => |elements| {
                var obj = try JSValue.newObject(arena);
                for (elements) |el| {
                    switch (el) {
                        .property => |prop| {
                            const key_str = try self.propertyKeyString(env, prop.computed, prop.key);
                            switch (prop.kind) {
                                .init => {
                                    const value = try self.evalExpression(env, prop.value);
                                    try obj.object.value.set(key_str, value.retain());
                                },
                                .method => {
                                    const f = try self.makeClosure(env, zfunctions.asFunctionNode(prop.value.data.function_like));
                                    try obj.object.value.set(key_str, f);
                                },
                                // get+set for the same key merge into one
                                // accessor property (defineAccessor's
                                // contract); data-only consumers see
                                // UNDEFINED as its value.
                                .get, .set => {
                                    const f = try self.makeClosure(env, zfunctions.asFunctionNode(prop.value.data.function_like));
                                    try obj.object.value.defineAccessor(
                                        key_str,
                                        if (prop.kind == .get) f else null,
                                        if (prop.kind == .set) f else null,
                                        JSValue.UNDEFINED,
                                    );
                                },
                            }
                        },
                        .spread => |spread_node| {
                            const spread_val = try self.evalExpression(env, spread_node.data.spread);
                            if (spread_val != .object) return error.NotImplemented;
                            const keys = try spread_val.object.value.keys(arena);
                            defer arena.free(keys);
                            for (keys) |k| {
                                try obj.object.value.set(k, spread_val.object.value.get(k).?.retain());
                            }
                        },
                    }
                }
                return obj;
            },
            .unary => |u| return self.evalUnary(env, u),
            .binary => |b| {
                const l = try self.evalExpression(env, b.left);
                const r = try self.evalExpression(env, b.right);
                // instanceof/in need the throw machinery and the prototype
                // chain, which coercion.zig doesn't have -- intercepted
                // here, never delegated.
                switch (b.op) {
                    .instanceof => return self.evalInstanceof(l, r),
                    .in => return self.evalIn(l, r),
                    else => return try coercion.binaryOp(arena, b.op, l, r),
                }
            },
            .logical => |l| {
                const left = try self.evalExpression(env, l.left);
                return switch (l.op) {
                    .and_op => if (!coercion.isTruthy(left)) left else try self.evalExpression(env, l.right),
                    .or_op => if (coercion.isTruthy(left)) left else try self.evalExpression(env, l.right),
                    .nullish => if (left != .@"undefined" and left != .@"null") left else try self.evalExpression(env, l.right),
                };
            },
            .assignment => |a| return self.evalAssignment(env, a),
            .conditional => |c| {
                if (coercion.isTruthy(try self.evalExpression(env, c.test_expr))) return self.evalExpression(env, c.consequent);
                return self.evalExpression(env, c.alternate);
            },
            .call => |c| return self.evalCall(env, c),
            .member => |m| {
                // `super.x` as a plain value: lookup on the parent
                // prototype (accessor getters get the current `this` --
                // getProperty's receiver rule -- close enough for this
                // narrow phase).
                if (m.object.data == .super_expr) {
                    const sproto = env.resolveSuperProto() orelse
                        return self.throwError(.syntax_error, "'super' keyword unexpected here", .{});
                    const key = try self.memberKeyString(env, m);
                    return try self.getProperty(sproto, key);
                }
                const obj = try self.evalExpression(env, m.object);
                if (m.optional and (obj == .@"undefined" or obj == .@"null")) return JSValue.UNDEFINED;
                const key = try self.memberKeyString(env, m);
                return try self.getProperty(obj, key);
            },
            .function_like => |ptr| return try self.makeClosure(env, zfunctions.asFunctionNode(ptr)),
            .class_like => |ptr| return try self.evalClass(env, zfunctions.asClassNode(ptr)),
            // The suspension points. The parser only produces these inside
            // generator/async bodies, which only execute on a fiber -- a
            // missing current_fiber would be an interpreter bug.
            .yield_expr => |y| {
                const fs = self.current_fiber orelse return error.NotImplemented;
                if (fs.kind != .generator) return error.NotImplemented;
                if (y.delegate) return self.evalYieldDelegate(env, fs, y.argument.?);
                const value = if (y.argument) |a| try self.evalExpression(env, a) else JSValue.UNDEFINED;
                fs.yielded = value;
                fs.fiber.suspendSelf();
                if (fs.resume_is_throw) {
                    fs.resume_is_throw = false;
                    return self.throwValue(fs.resume_value);
                }
                return fs.resume_value;
            },
            .await_expr => |operand_node| {
                const fs = self.current_fiber orelse return error.NotImplemented;
                if (fs.kind != .async_fn) return error.NotImplemented;
                const operand = try self.evalExpression(env, operand_node);
                // Awaiting a non-promise still takes one trip through the
                // queue (real semantics -- `await 5` yields to microtasks).
                const p = if (operand == .promise) operand else try self.fulfilledPromise(operand);
                const on_f = try JSValue.newFunction(arena, .{ .ctx = fs, .name = "", .call = awaitOnFulfilled });
                const on_r = try JSValue.newFunction(arena, .{ .ctx = fs, .name = "", .call = awaitOnRejected });
                try self.subscribePromise(p, on_f, on_r, null);
                fs.fiber.suspendSelf();
                if (fs.resume_is_throw) {
                    fs.resume_is_throw = false;
                    return self.throwValue(fs.resume_value);
                }
                return fs.resume_value;
            },
            // Bare `super` outside call/member position, or super in a
            // non-method context (the call/member interceptors resolve
            // their own bindings first and raise this same error when
            // there's nothing to resolve).
            .super_expr => return self.throwError(.syntax_error, "'super' keyword unexpected here", .{}),
            .new_expr => |n| return self.evalNew(env, n),
            .regex_literal, .bigint_literal => return error.NotImplemented,
            // Only ever nested inside array/object-literal/call-argument
            // constructs, which unwrap `.data.spread` themselves before
            // recursing -- never reached as a standalone expression.
            .spread => unreachable,
        }
    }

    /// A property key that a symbol value can also produce. Symbols
    /// encode to a reserved `\x00S<ptr>` string (invisible to string
    /// iteration; registered for getOwnPropertySymbols); everything else
    /// goes through ToString.
    pub fn encodeKey(self: *Interpreter, value: JSValue) anyerror![]const u8 {
        if (value == .symbol) {
            const arena = self.arena_state.allocator();
            const key = try std.fmt.allocPrint(arena, "\x00S{x}", .{@intFromPtr(value.symbol)});
            if (!self.symbol_keys.contains(key)) {
                try self.symbol_keys.put(arena, key, value.retain());
            }
            return key;
        }
        return coercion.toDisplayString(self.arena_state.allocator(), value);
    }

    /// True for the reserved symbol-key encoding -- these must stay
    /// invisible to for-in / Object.keys/values/entries / JSON.
    fn isSymbolKey(k: []const u8) bool {
        return k.len > 0 and k[0] == 0;
    }

    fn memberKeyString(self: *Interpreter, env: *Environment, m: anytype) anyerror![]const u8 {
        if (m.computed) {
            const k = try self.evalExpression(env, m.property);
            return self.encodeKey(k);
        }
        return switch (m.property.data) {
            .identifier => |name| name,
            else => error.NotImplemented,
        };
    }

    fn propertyKeyString(self: *Interpreter, env: *Environment, computed: bool, key: *zparser.Node) anyerror![]const u8 {
        if (computed) {
            const v = try self.evalExpression(env, key);
            return self.encodeKey(v);
        }
        return switch (key.data) {
            .identifier => |name| name,
            .string_literal => |s| s,
            .number_literal => |n| try znumber.FormattingMethods.toString(n, self.arena_state.allocator(), null),
            else => error.NotImplemented,
        };
    }

    /// A shared native-method JSValue for a (type, name) pair, cached so
    /// `a.push === b.push` holds like real JS prototype methods.
    pub fn nativeMethod(self: *Interpreter, comptime type_prefix: []const u8, name: []const u8, call_fn: builtins.NativeFn) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        const cache_key = try std.fmt.allocPrint(arena, type_prefix ++ ".{s}", .{name});
        if (self.method_cache.get(cache_key)) |cached| return cached;
        const fn_value = try JSValue.newFunction(arena, .{ .ctx = self, .name = name, .call = call_fn });
        try self.method_cache.put(arena, cache_key, fn_value);
        return fn_value;
    }

    pub fn getProperty(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!JSValue {
        return switch (obj) {
            // Own-then-chain walk over property *records* (not values), so
            // accessor properties dispatch: a getter is invoked with
            // this = the original receiver (not the prototype that holds
            // it), a setter-only accessor reads as undefined. Data
            // properties behave exactly as the old ZObject.get did.
            .object => |box| blk: {
                const arena = self.arena_state.allocator();
                var current: ?*const @TypeOf(box.value) = &box.value;
                while (current) |o| : (current = o.getPrototype()) {
                    const rec = o.getOwnRecord(key) orelse continue;
                    if (rec.isAccessor()) {
                        const g = rec.getter orelse break :blk JSValue.UNDEFINED;
                        break :blk try g.function.value.call(g.function.value.ctx, arena, obj, &.{});
                    }
                    break :blk rec.value.retain();
                }
                // Chain miss -> the Object.prototype methods every plain
                // object responds to (hasOwnProperty & co).
                if (builtins.object_methods.get(key)) |f| break :blk try self.nativeMethod("object", key, f);
                break :blk JSValue.UNDEFINED;
            },
            .array => |box| blk: {
                if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.length()));
                if (builtins.array_methods.get(key)) |f| break :blk try self.nativeMethod("array", key, f);
                const idx = std.fmt.parseInt(usize, key, 10) catch return error.NotImplemented;
                if (idx >= box.value.length()) break :blk JSValue.UNDEFINED;
                break :blk box.value.get(idx).retain();
            },
            .string => |box| blk: {
                if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.data.len));
                if (builtins.string_methods.get(key)) |f| break :blk try self.nativeMethod("string", key, f);
                break :blk error.NotImplemented;
            },
            // `catch (e) { console.log(e.message) }` is the most common
            // catch body in existence -- name/message are read-only views
            // over ZError's existing fields.
            .@"error" => |box| blk: {
                const arena = self.arena_state.allocator();
                if (std.mem.eql(u8, key, "name")) break :blk try JSValue.newString(arena, box.value.kind.name());
                if (std.mem.eql(u8, key, "message")) break :blk try JSValue.newString(arena, box.value.message);
                // `thrown.constructor === TypeError` -- what Test262's
                // assert.throws actually compares. Same function identity
                // every time: the global binding for this kind's name.
                if (std.mem.eql(u8, key, "constructor")) {
                    break :blk (self.global_env.get(box.value.kind.name()) orelse JSValue.UNDEFINED).retain();
                }
                break :blk JSValue.UNDEFINED;
            },
            .function => |box| blk: {
                if (std.mem.eql(u8, key, "prototype")) break :blk try self.functionPrototype(obj);
                if (std.mem.eql(u8, key, "name")) break :blk try JSValue.newString(self.arena_state.allocator(), box.value.name);
                if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.arity));
                // The statics bag (class statics, F.myProp = 1) shadows
                // the Function.prototype methods, like an own property
                // would. Recursing through getProperty gives accessor
                // dispatch and -- because class bags chain to the
                // parent's bag -- static inheritance. Narrowing: a static
                // getter's `this` is the bag, not the class function, so
                // `this.otherStatic` works but `this === C` doesn't.
                if (box.value.statics) |bag| {
                    if (bag.object.value.has(key)) break :blk try self.getProperty(bag, key);
                }
                if (builtins.function_methods.get(key)) |f| break :blk try self.nativeMethod("function", key, f);
                break :blk JSValue.UNDEFINED;
            },
            .date => blk: {
                if (builtins.date_methods.get(key)) |f| break :blk try self.nativeMethod("date", key, f);
                break :blk JSValue.UNDEFINED;
            },
            .promise => blk: {
                if (builtins.promise_methods.get(key)) |f| break :blk try self.nativeMethod("promise", key, f);
                break :blk JSValue.UNDEFINED;
            },
            .symbol => |box| blk: {
                if (std.mem.eql(u8, key, "description")) {
                    break :blk if (box.value.description) |d| try JSValue.newString(self.arena_state.allocator(), d) else JSValue.UNDEFINED;
                }
                if (builtins.symbol_methods.get(key)) |f| break :blk try self.nativeMethod("symbol", key, f);
                break :blk JSValue.UNDEFINED;
            },
            // Spec says TypeError here (not ReferenceError). The optional
            // chaining guards short-circuit BEFORE getProperty, so `a?.b`
            // on null still yields undefined without ever reaching this.
            .@"undefined", .@"null" => self.throwError(.type_error, "Cannot read properties of {s} (reading '{s}')", .{ if (obj == .@"null") "null" else "undefined", key }),
            else => error.NotImplemented,
        };
    }

    /// ECMA-262 13.10.2 InstanceofOperator, narrowed (no
    /// Symbol.hasInstance): walk the LHS object's prototype chain looking
    /// for the RHS function's prototype object, by pointer identity.
    fn evalInstanceof(self: *Interpreter, l: JSValue, r: JSValue) anyerror!JSValue {
        if (r != .function) {
            return self.throwError(.type_error, "Right-hand side of 'instanceof' is not callable", .{});
        }
        // A never-touched prototype slot means this function never
        // constructed anything -- nothing can be an instance of it.
        const proto = r.function.value.prototype orelse return JSValue.fromBool(false);
        if (proto != .object) return JSValue.fromBool(false);
        if (l != .object) return JSValue.fromBool(false); // primitives are never instances
        var current = l.object.value.getPrototype();
        while (current) |p| : (current = p.getPrototype()) {
            if (p == &proto.object.value) return JSValue.fromBool(true);
        }
        return JSValue.fromBool(false);
    }

    /// The `in` operator: property existence including the prototype chain
    /// (ZObject.has already walks it). Arrays support numeric indices and
    /// "length"; primitives are a real spec TypeError; map/set/etc are
    /// objects in real JS but have no property model here yet.
    fn evalIn(self: *Interpreter, l: JSValue, r: JSValue) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        const key = try coercion.toDisplayString(arena, l);
        return switch (r) {
            .object => |box| JSValue.fromBool(box.value.has(key)),
            .array => |box| blk: {
                if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(true);
                const idx = std.fmt.parseInt(usize, key, 10) catch break :blk JSValue.fromBool(false);
                break :blk JSValue.fromBool(idx < box.value.length());
            },
            .@"undefined", .@"null", .boolean, .number, .string => self.throwError(.type_error, "Cannot use 'in' operator to search for '{s}'", .{key}),
            .function, .regex, .symbol, .map, .set, .@"error", .date, .promise => error.NotImplemented,
        };
    }

    /// [[Set]] on an `.object` JSValue with accessor dispatch: a setter
    /// anywhere on the chain is invoked with this = the receiver; a
    /// getter-only accessor swallows the write silently (sloppy-mode
    /// [[Set]]); the first *data* record found stops the walk and the
    /// write shadows it as an own property, exactly like real JS.
    fn setObjectProperty(self: *Interpreter, obj: JSValue, key: []const u8, value: JSValue) anyerror!void {
        var current: ?*const @TypeOf(obj.object.value) = &obj.object.value;
        while (current) |o| : (current = o.getPrototype()) {
            const rec = o.getOwnRecord(key) orelse continue;
            if (rec.isAccessor()) {
                const s = rec.setter orelse return; // getter-only: silent no-op
                _ = try s.function.value.call(s.function.value.ctx, self.arena_state.allocator(), obj, &.{value});
                return;
            }
            break;
        }
        // Always-strict [[Set]] failures are real TypeErrors, not raw
        // Zig errors (the descriptor flags finally bite here).
        obj.object.value.set(key, value.retain()) catch |err| return switch (err) {
            error.PropertyNotWritable => self.throwError(.type_error, "Cannot assign to read only property '{s}' of object", .{key}),
            error.ObjectIsFrozen => self.throwError(.type_error, "Cannot assign to read only property '{s}' of object", .{key}),
            error.ObjectNotExtensible => self.throwError(.type_error, "Cannot add property {s}, object is not extensible", .{key}),
            else => err,
        };
    }

    /// The function's statics/property bag, created lazily on first touch
    /// (same contract as functionPrototype).
    pub fn functionStatics(self: *Interpreter, fn_val: JSValue) anyerror!JSValue {
        if (fn_val.function.value.statics) |s| return s;
        const bag = try JSValue.newObject(self.arena_state.allocator());
        fn_val.function.value.statics = bag;
        return bag;
    }

    /// F.prototype, created lazily on first touch: a fresh `{}` whose
    /// `constructor` points back at the function (real
    /// `F.prototype.constructor === F` behavior).
    pub fn functionPrototype(self: *Interpreter, fn_val: JSValue) anyerror!JSValue {
        if (fn_val.function.value.prototype) |p| return p;
        const arena = self.arena_state.allocator();
        var proto = try JSValue.newObject(arena);
        try proto.object.value.set("constructor", fn_val.retain());
        fn_val.function.value.prototype = proto;
        return proto;
    }

    fn evalUnary(self: *Interpreter, env: *Environment, u: anytype) anyerror!JSValue {
        switch (u.op) {
            .not => return JSValue.fromBool(!coercion.isTruthy(try self.evalExpression(env, u.operand))),
            .minus => return JSValue.fromNumber(-(try coercion.toNumber(try self.evalExpression(env, u.operand)))),
            .plus => return JSValue.fromNumber(try coercion.toNumber(try self.evalExpression(env, u.operand))),
            .typeof => {
                // typeof on an undeclared identifier is "undefined", not a
                // ReferenceError -- a real, deliberate spec quirk. But a
                // TDZ binding still throws (`typeof x; let x;` is the real
                // ReferenceError).
                if (u.operand.data == .identifier) {
                    const name = u.operand.data.identifier;
                    switch (env.lookup(name)) {
                        .value => |v| return try JSValue.newString(self.arena_state.allocator(), v.typeOf()),
                        .tdz => return self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name}),
                        .not_found => return try JSValue.newString(self.arena_state.allocator(), "undefined"),
                    }
                }
                const v = try self.evalExpression(env, u.operand);
                return try JSValue.newString(self.arena_state.allocator(), v.typeOf());
            },
            .void_op => {
                _ = try self.evalExpression(env, u.operand);
                return JSValue.UNDEFINED;
            },
            .pre_inc, .pre_dec => {
                const old = try coercion.toNumber(try self.evalExpression(env, u.operand));
                const new_val = JSValue.fromNumber(if (u.op == .pre_inc) old + 1 else old - 1);
                try self.assignTo(env, u.operand, new_val);
                return new_val;
            },
            .post_inc, .post_dec => {
                const old = try coercion.toNumber(try self.evalExpression(env, u.operand));
                const new_val = JSValue.fromNumber(if (u.op == .post_inc) old + 1 else old - 1);
                try self.assignTo(env, u.operand, new_val);
                return JSValue.fromNumber(old);
            },
            .bitnot => {
                const n = try coercion.toInt32(try self.evalExpression(env, u.operand));
                return JSValue.fromNumber(@floatFromInt(~n));
            },
            .delete => {
                // Always-strict delete: unqualified identifiers are the
                // real SyntaxError; member deletion enforces
                // configurable; anything else evaluates and yields true.
                if (u.operand.data == .identifier) {
                    return self.throwError(.syntax_error, "Delete of an unqualified identifier in strict mode.", .{});
                }
                if (u.operand.data == .member) {
                    const m = u.operand.data.member;
                    const obj = try self.evalExpression(env, m.object);
                    const key = try self.memberKeyString(env, m);
                    if (obj != .object) return JSValue.fromBool(true);
                    const removed = obj.object.value.delete(key) catch |err| return switch (err) {
                        error.PropertyNotConfigurable, error.ObjectIsFrozen => self.throwError(.type_error, "Cannot delete property '{s}' of object", .{key}),
                        else => err,
                    };
                    _ = removed;
                    return JSValue.fromBool(true);
                }
                _ = try self.evalExpression(env, u.operand);
                return JSValue.fromBool(true);
            },
        }
    }

    fn evalAssignment(self: *Interpreter, env: *Environment, a: anytype) anyerror!JSValue {
        if (a.op == .assign) {
            const value = try self.evalExpression(env, a.value);
            switch (a.target.data) {
                // Cover-grammar reinterpretation: the literal IS the
                // pattern. The expression's own value stays the RHS
                // (`([a] = [7])[0]` is 7), per spec.
                .array_literal, .object_literal => try self.destructuringAssign(env, a.target, value),
                else => try self.assignTo(env, a.target, value),
            }
            return value;
        }
        switch (a.op) {
            .logical_and, .logical_or, .nullish => {
                const current = try self.evalExpression(env, a.target);
                const should_assign = switch (a.op) {
                    .logical_and => coercion.isTruthy(current),
                    .logical_or => !coercion.isTruthy(current),
                    .nullish => current == .@"undefined" or current == .@"null",
                    else => unreachable,
                };
                if (!should_assign) return current;
                const value = try self.evalExpression(env, a.value);
                try self.assignTo(env, a.target, value);
                return value;
            },
            else => {
                const current = try self.evalExpression(env, a.target);
                const rhs = try self.evalExpression(env, a.value);
                const result = try coercion.binaryOp(self.arena_state.allocator(), compoundToBinary(a.op), current, rhs);
                try self.assignTo(env, a.target, result);
                return result;
            },
        }
    }

    fn assignTo(self: *Interpreter, env: *Environment, target: *zparser.Node, value: JSValue) anyerror!void {
        switch (target.data) {
            .identifier => |name| env.assign(name, value) catch |err| return switch (err) {
                error.ReferenceError => self.throwError(.reference_error, "{s} is not defined", .{name}),
                error.BeforeInitialization => self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name}),
            },
            .paren => |inner| try self.assignTo(env, inner, value),
            .member => |m| {
                const obj = try self.evalExpression(env, m.object);
                const key = try self.memberKeyString(env, m);
                // Split, not a blanket conversion: null/undefined is a real
                // spec TypeError, but every other non-object receiver
                // (arrays, strings, numbers) is a genuine feature gap --
                // NotImplemented is the honest answer, and a JS `catch`
                // must never swallow it.
                if (obj == .@"undefined" or obj == .@"null") {
                    return self.throwError(.type_error, "Cannot set properties of {s} (setting '{s}')", .{ if (obj == .@"null") "null" else "undefined", key });
                }
                if (obj == .function) {
                    // `F.prototype = {...}` overwrites the callable's
                    // slot; everything else goes into the statics bag
                    // (class statics, F.myProp = 1 -- the old "functions
                    // have no property bag" gap is gone).
                    if (std.mem.eql(u8, key, "prototype")) {
                        if (value != .object) return error.NotImplemented;
                        obj.function.value.prototype = value.retain();
                        return;
                    }
                    const bag = try self.functionStatics(obj);
                    return self.setObjectProperty(bag, key, value);
                }
                if (obj != .object) return error.NotImplemented;
                try self.setObjectProperty(obj, key, value);
            },
            else => return error.NotImplemented,
        }
    }

    fn evalCall(self: *Interpreter, env: *Environment, c: anytype) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        // `super(args)`: the parent constructor invoked with the CURRENT
        // `this` (the instance under construction), armed as a
        // construction so the parent's without-new check passes.
        if (c.callee.data == .super_expr) {
            const sctor = env.resolveSuperCtor() orelse
                return self.throwError(.syntax_error, "'super' keyword unexpected here", .{});
            const args = try self.evalArgs(env, c.args);
            const prev_target = self.construct_target;
            self.construct_target = sctor.function.value.ctx;
            defer self.construct_target = prev_target;
            return try sctor.function.value.call(sctor.function.value.ctx, arena, env.resolveThis(), args);
        }
        // `super.m(args)`: method looked up on the PARENT prototype but
        // invoked with the current `this` -- the whole point of super.
        if (c.callee.data == .member and c.callee.data.member.object.data == .super_expr) {
            const m = c.callee.data.member;
            const sproto = env.resolveSuperProto() orelse
                return self.throwError(.syntax_error, "'super' keyword unexpected here", .{});
            const key = try self.memberKeyString(env, m);
            const method = try self.getProperty(sproto, key);
            if (method != .function) {
                return self.throwError(.type_error, "(intermediate value).{s} is not a function", .{key});
            }
            const args = try self.evalArgs(env, c.args);
            return try method.function.value.call(method.function.value.ctx, arena, env.resolveThis(), args);
        }
        var this_value: JSValue = JSValue.UNDEFINED;
        var callee_val: JSValue = undefined;
        if (c.callee.data == .member) {
            const m = c.callee.data.member;
            const obj = try self.evalExpression(env, m.object);
            if (m.optional and (obj == .@"undefined" or obj == .@"null")) return JSValue.UNDEFINED;
            const key = try self.memberKeyString(env, m);
            this_value = obj;
            callee_val = try self.getProperty(obj, key);
        } else {
            callee_val = try self.evalExpression(env, c.callee);
        }
        if (c.optional and (callee_val == .@"undefined" or callee_val == .@"null")) return JSValue.UNDEFINED;
        if (callee_val != .function) {
            // Best-effort callee name for the message -- no expression
            // printer, just the two cheap cases.
            const callee_name: []const u8 = switch (c.callee.data) {
                .identifier => |name| name,
                .member => |m| if (!m.computed and m.property.data == .identifier) m.property.data.identifier else "expression",
                else => "expression",
            };
            return self.throwError(.type_error, "{s} is not a function", .{callee_name});
        }

        const args = try self.evalArgs(env, c.args);
        return try callee_val.function.value.call(callee_val.function.value.ctx, arena, this_value, args);
    }

    fn evalArgs(self: *Interpreter, env: *Environment, arg_nodes: []const *zparser.Node) anyerror![]const JSValue {
        const arena = self.arena_state.allocator();
        var args: std.ArrayList(JSValue) = .empty;
        for (arg_nodes) |arg_node| {
            if (arg_node.data == .spread) {
                const spread_val = try self.evalExpression(env, arg_node.data.spread);
                for (try self.iterableItems(spread_val)) |item| try args.append(arena, item.retain());
            } else {
                try args.append(arena, try self.evalExpression(env, arg_node));
            }
        }
        return args.toOwnedSlice(arena);
    }

    /// ECMA-262 10.2.2 [[Construct]], narrowed: fresh object wired to
    /// F.prototype, constructor called with it as `this`, and an
    /// object-like return value overrides the instance (a primitive
    /// return is ignored -- the real rule).
    fn evalNew(self: *Interpreter, env: *Environment, n: anytype) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        const callee = try self.evalExpression(env, n.callee);
        const callee_name: []const u8 = switch (n.callee.data) {
            .identifier => |name| name,
            else => "expression",
        };
        if (callee != .function or !callee.function.value.constructable) {
            return self.throwError(.type_error, "{s} is not a constructor", .{callee_name});
        }
        const proto = try self.functionPrototype(callee);
        var instance = try JSValue.newObject(arena);
        try instance.object.value.setPrototype(&proto.object.value);
        // `new Foo` with no parens at all (args == null) is `new Foo()`.
        const args = try self.evalArgs(env, n.args orelse &.{});
        // Arm the construct token for exactly this call -- see the field
        // doc on `construct_target`.
        const prev_target = self.construct_target;
        self.construct_target = callee.function.value.ctx;
        defer self.construct_target = prev_target;
        const result = try callee.function.value.call(callee.function.value.ctx, arena, instance, args);
        return switch (result) {
            .object, .array, .function, .regex, .map, .set, .@"error", .date, .promise => result,
            else => instance,
        };
    }

    pub fn makeClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        // A named function expression's own name is visible inside its own
        // body (for self-recursion) even though it isn't bound in the
        // enclosing scope -- bind it in a thin wrapper env between `env`
        // and the closure's actual defining environment.
        const self_name: ?[]const u8 = switch (fnode.kind) {
            .function_expr => |e| e.name,
            else => null,
        };
        const closure_env = if (self_name != null) try env.child(arena) else env;

        const ctx = try arena.create(ClosureCtx);
        ctx.* = .{ .interp = self, .function_node = fnode, .closure_env = closure_env };
        const name: []const u8 = switch (fnode.kind) {
            .function_decl => |d| d.name,
            .function_expr => |e| e.name orelse "",
            .method => |m| m.name,
            .arrow => "",
        };
        const fn_value = try JSValue.newFunction(arena, .{
            .ctx = ctx,
            .name = name,
            .arity = fnode.params.items.len,
            .call = closureCall,
            // Arrows and object-literal methods are not constructors
            // (spec); natives keep the default false via their own
            // newFunction call sites.
            .constructable = switch (fnode.kind) {
                .arrow, .method => false,
                .function_decl, .function_expr => true,
            },
        });
        if (self_name) |n| try closure_env.define(arena, n, fn_value.retain());
        return fn_value;
    }

    /// A class-body method closure: an ordinary makeClosure whose
    /// ClosureCtx additionally carries the parent prototype, so `super.m()`
    /// resolves inside the body. Safe cast: makeClosure always installs a
    /// ClosureCtx as the ctx of the closures it creates.
    fn makeMethodClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode, super_proto: ?JSValue) anyerror!JSValue {
        const v = try self.makeClosure(env, fnode);
        const cc: *ClosureCtx = @ptrCast(@alignCast(v.function.value.ctx));
        cc.super_proto = super_proto;
        return v;
    }

    /// ECMA-262 15.7 ClassDefinitionEvaluation, narrowed: a constructable
    /// function (classConstructorCall) whose prototype object holds the
    /// instance methods/accessors and chains to the parent's prototype;
    /// statics live in the function's bag, chained to the parent's bag
    /// (static inheritance). No fields/#private/new.target -- see README.
    fn evalClass(self: *Interpreter, env: *Environment, cnode: *zfunctions.ClassNode) anyerror!JSValue {
        const arena = self.arena_state.allocator();

        var super_ctor: ?JSValue = null;
        var super_proto: ?JSValue = null;
        if (cnode.superclass) |sc_expr| {
            const sc = try self.evalExpression(env, sc_expr);
            if (sc != .function or !sc.function.value.constructable) {
                const shown = try coercion.toDisplayString(arena, sc);
                return self.throwError(.type_error, "Class extends value {s} is not a constructor or null", .{shown});
            }
            super_ctor = sc;
            super_proto = try self.functionPrototype(sc);
        }

        // Named classes can self-reference inside method bodies (same
        // wrapper-env trick as named function expressions).
        const closure_env = if (cnode.name != null) try env.child(arena) else env;

        var proto = try JSValue.newObject(arena);
        if (super_proto) |sp| try proto.object.value.setPrototype(&sp.object.value);

        var ctor_fnode: ?*zfunctions.FunctionNode = null;
        for (cnode.elements) |el| {
            if (!el.is_static and el.kind == .method and std.mem.eql(u8, el.key, "constructor")) {
                ctor_fnode = el.function;
            }
        }

        const cctx = try arena.create(ClassCtx);
        cctx.* = .{
            .interp = self,
            .ctor_fnode = ctor_fnode,
            .closure_env = closure_env,
            .name = cnode.name orelse "",
            .super_ctor = super_ctor,
            .super_proto = super_proto,
        };
        const class_fn = try JSValue.newFunction(arena, .{
            .ctx = cctx,
            .name = cnode.name orelse "",
            .arity = if (ctor_fnode) |f| f.params.items.len else 0,
            .call = classConstructorCall,
            .constructable = true,
        });
        try proto.object.value.set("constructor", class_fn.retain());
        class_fn.function.value.prototype = proto;

        // A derived class always gets a statics bag chained to the
        // parent's (forcing the parent's into existence) so static
        // inheritance works even when this class declares no statics.
        if (super_ctor) |parent| {
            const parent_bag = try self.functionStatics(parent);
            const bag = try self.functionStatics(class_fn);
            try bag.object.value.setPrototype(&parent_bag.object.value);
        }

        for (cnode.elements) |el| {
            if (!el.is_static and el.kind == .method and std.mem.eql(u8, el.key, "constructor")) continue;
            const m = try self.makeMethodClosure(closure_env, el.function, super_proto);
            const target = if (el.is_static) try self.functionStatics(class_fn) else proto;
            switch (el.kind) {
                .method => try target.object.value.set(el.key, m),
                .get => try target.object.value.defineAccessor(el.key, m, null, JSValue.UNDEFINED),
                .set => try target.object.value.defineAccessor(el.key, null, m, JSValue.UNDEFINED),
            }
        }

        if (cnode.name) |n| try closure_env.define(arena, n, class_fn.retain());
        return class_fn;
    }
};

fn labelIn(target: []const u8, labels: []const []const u8) bool {
    for (labels) |l| {
        if (std.mem.eql(u8, l, target)) return true;
    }
    return false;
}

fn compoundToBinary(op: zparser.AssignOp) zparser.BinaryOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .shl => .shl,
        .shr => .shr,
        .ushr => .ushr,
        .bitand => .bitand,
        .bitor => .bitor,
        .bitxor => .bitxor,
        .assign, .logical_and, .logical_or, .nullish => unreachable, // handled separately by evalAssignment
    };
}

/// The shared body of every user-code invocation: fresh call env off the
/// closure env, this/super bindings, parameter binding (defaults, rest,
/// destructuring via bindPattern), then the body. `this_value` null =
/// don't bind (arrows -- resolveThis walks up instead).
fn invokeFunctionNode(
    self: *Interpreter,
    fnode: *zfunctions.FunctionNode,
    closure_env: *Environment,
    allocator: Allocator,
    this_value: ?JSValue,
    super_proto: ?JSValue,
    super_ctor: ?JSValue,
    args: []const JSValue,
) anyerror!JSValue {
    const call_env = try closure_env.child(allocator);
    if (this_value) |tv| call_env.this_value = tv;
    call_env.super_proto = super_proto;
    call_env.super_ctor = super_ctor;

    // `arguments`: every non-arrow call gets one (arrows inherit the
    // enclosing function's via the scope chain -- no binding here).
    // Materialized as a real array snapshot (always-strict => unmapped;
    // narrowing: not the exotic Arguments object -- see README). Defined
    // BEFORE params so a parameter/rest named `arguments` shadows it.
    if (fnode.kind != .arrow) {
        var arguments = try JSValue.newArray(allocator);
        for (args) |a| _ = try arguments.array.value.push(a.retain());
        try call_env.define(allocator, "arguments", arguments);
    }

    for (fnode.params.items, 0..) |param, i| {
        var value = if (i < args.len) args[i] else JSValue.UNDEFINED;
        if (value == .@"undefined") {
            if (param.default) |def| value = try self.evalExpression(call_env, def);
        }
        try self.bindPattern(call_env, param.pattern, value, .define);
    }
    if (fnode.params.rest) |rest| {
        var rest_arr = try JSValue.newArray(allocator);
        const start = fnode.params.items.len;
        if (start < args.len) {
            for (args[start..]) |a| _ = try rest_arr.array.value.push(a.retain());
        }
        try call_env.define(allocator, rest.name, rest_arr);
    }

    switch (fnode.body) {
        .block => |body_stmt| {
            const c = try self.evalBody(call_env, body_stmt.data.block);
            if (c.type == .return_completion) return c.value;
            return JSValue.UNDEFINED;
        },
        .expression => |expr| return try self.evalExpression(call_env, expr),
    }
}

fn closureCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const closure_ctx: *ClosureCtx = @ptrCast(@alignCast(ctx));
    const fnode = closure_ctx.function_node;
    // Arrows have no own `this` binding -- passing null makes
    // `resolveThis()` walk up to closure_env's, matching real lexical
    // `this` inheritance.
    const this: ?JSValue = if (fnode.kind != .arrow) this_value else null;
    if (fnode.is_generator and fnode.is_async) {
        return closure_ctx.interp.throwError(.type_error, "async generators are not supported yet", .{});
    }
    if (fnode.is_generator) {
        return closure_ctx.interp.makeGeneratorObject(fnode, closure_ctx.closure_env, this, args);
    }
    if (fnode.is_async) {
        return closure_ctx.interp.runAsyncFunction(fnode, closure_ctx.closure_env, this, args);
    }
    return invokeFunctionNode(closure_ctx.interp, fnode, closure_ctx.closure_env, allocator, this, closure_ctx.super_proto, null, args);
}

fn classConstructorCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const cctx: *ClassCtx = @ptrCast(@alignCast(ctx));
    const self = cctx.interp;
    if (self.construct_target != ctx) {
        return self.throwError(.type_error, "Class constructor {s} cannot be invoked without 'new'", .{cctx.name});
    }
    // Consume the token: plain calls made inside the constructor body
    // must not look like constructions (evalNew's defer restores it for
    // its own caller either way).
    self.construct_target = null;

    if (cctx.ctor_fnode) |fnode| {
        return invokeFunctionNode(self, fnode, cctx.closure_env, allocator, this_value, cctx.super_proto, cctx.super_ctor, args);
    }
    // Implicit constructor: a derived class forwards this + args to its
    // parent (`constructor(...args) { super(...args) }`); a base class
    // is a no-op.
    if (cctx.super_ctor) |parent| {
        self.construct_target = parent.function.value.ctx;
        defer self.construct_target = null;
        _ = try parent.function.value.call(parent.function.value.ctx, allocator, this_value, args);
    }
    return JSValue.UNDEFINED;
}

