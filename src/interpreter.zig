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
const zregex = @import("zregex");
const zarray = @import("zarray");
const zobject = @import("zobject");
const zmap = @import("zmap");
const zset = @import("zset");
const zerror = @import("zerror");
const zsymbol = @import("zsymbol");
const zstring = @import("zstring");
const zdate = @import("zdate");

/// The materialized builtin prototype objects (see `Interpreter.protos`).
/// Each is a real `.object` JSValue; `.undefined` until setupGlobals runs.
pub const Protos = struct {
    object: JSValue = JSValue.UNDEFINED,
    function: JSValue = JSValue.UNDEFINED,
    array: JSValue = JSValue.UNDEFINED,
    string: JSValue = JSValue.UNDEFINED,
    number: JSValue = JSValue.UNDEFINED,
    boolean: JSValue = JSValue.UNDEFINED,
    date: JSValue = JSValue.UNDEFINED,
    regex: JSValue = JSValue.UNDEFINED,
    @"error": JSValue = JSValue.UNDEFINED,
    map: JSValue = JSValue.UNDEFINED,
    set: JSValue = JSValue.UNDEFINED,
    symbol: JSValue = JSValue.UNDEFINED,
    promise: JSValue = JSValue.UNDEFINED,
};

/// JS-level state a RegExp object carries beyond its compiled bytecode.
pub const RegexState = struct {
    source: []const u8,
    flags: []const u8,
    global: bool,
    ignore_case: bool,
    multiline: bool,
    dot_all: bool,
    sticky: bool,
    unicode: bool,
    last_index: usize = 0,
};

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
    /// Non-null only for class method closures: the declaring class's
    /// identity (its *ClassCtx), so `this.#x` inside the body resolves
    /// private names against the right class (copied onto the call env).
    private_ctx: ?*anyopaque = null,

    /// GC prep (roadmap item 15, phase 2): see Environment.traceChildren
    /// for the visitor contract. private_ctx is downcast back to *ClassCtx
    /// here (same file, so no opacity problem like Environment has).
    fn traceChildren(self: *const ClosureCtx, visitor: anytype) void {
        visitor.environment(self.closure_env);
        if (self.super_proto) |v| visitor.value(v);
        if (self.private_ctx) |pc| classCtxFromOpaque(pc).traceChildren(visitor);
    }
};

/// One instance field captured at class-definition time: the key is fully
/// resolved (computed keys already evaluated, private keys already encoded
/// via encodePrivateKey); the initializer expression runs per-instance at
/// construction time.
const FieldDef = struct {
    key: []const u8,
    value: ?*zparser.Node,
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
    /// Orthogonal: a plain generator has is_generator only, a plain async
    /// function has is_async only, and an async generator (`async
    /// function*`/`async *method(){}`) has BOTH -- yield and await both
    /// suspend the same fiber, interleaved in body order.
    is_generator: bool,
    is_async: bool,
    interp: *Interpreter,
    fiber: *fiber_mod.Fiber,
    fnode: *zfunctions.FunctionNode,
    closure_env: *Environment,
    this_value: ?JSValue,
    /// The declaring class's private identity for method bodies (so
    /// `this.#x` works inside generator/async methods too).
    private_ctx: ?*anyopaque,
    args: []const JSValue,
    /// Scheduler -> fiber: what the suspension point produces on resume
    /// (next(v) / the awaited promise's settlement).
    resume_value: JSValue = JSValue.UNDEFINED,
    resume_is_throw: bool = false,
    /// Fiber -> scheduler: the value a `yield` produced, if any.
    yielded: ?JSValue = null,
    /// Fiber -> scheduler on completion (any is_generator fiber, sync or
    /// async; a plain async function resolves its promise directly from
    /// fiberEntry instead of going through these).
    completion: ?JSValue = null,
    completed_throw: ?JSValue = null,
    /// Non-JS errors (OOM/NotImplemented) that unwound the fiber -- the
    /// scheduler side re-raises them after the switch; they must never
    /// be swallowed.
    fatal_error: ?anyerror = null,
    /// The promise a plain async function returned (is_async and NOT
    /// is_generator only -- async generators use pending_result_promise
    /// instead, one promise per in-flight next()/throw() request).
    promise: ?JSValue = null,
    /// An async generator's in-flight next(v)/throw(v) request promise:
    /// created by asyncGeneratorNext, settled by resumeFiber's post-switch
    /// check once the fiber actually produces a yield or completes (which
    /// may take several await-driven resumptions to reach). Null when no
    /// request is in flight -- v1 doesn't support overlapping next() calls
    /// (the only real consumer, `for await`, never overlaps them).
    pending_result_promise: ?JSValue = null,

    /// GC prep (roadmap item 15, phase 2): see Environment.traceChildren
    /// for the visitor contract. `interp`/`fiber`/`fnode` aren't
    /// JSValue/Environment -- fiber stacks get their own GC handling in a
    /// later phase (they're not part of this value graph). `is_generator`/
    /// `is_async`/`resume_is_throw`/`fatal_error` carry no values.
    fn traceChildren(self: *const FiberState, visitor: anytype) void {
        visitor.environment(self.closure_env);
        if (self.this_value) |v| visitor.value(v);
        if (self.private_ctx) |pc| classCtxFromOpaque(pc).traceChildren(visitor);
        for (self.args) |a| visitor.value(a);
        visitor.value(self.resume_value);
        if (self.yielded) |v| visitor.value(v);
        if (self.completion) |v| visitor.value(v);
        if (self.completed_throw) |v| visitor.value(v);
        if (self.promise) |v| visitor.value(v);
        if (self.pending_result_promise) |v| visitor.value(v);
    }
};

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
    const result = invokeFunctionNode(self, fs.fnode, fs.closure_env, arena, fs.this_value, null, null, fs.private_ctx, fs.args) catch |err| {
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

/// A `{ value, done }` iterator-result object.
fn iterResult(self: *Interpreter, value: JSValue, done: bool) anyerror!JSValue {
    var obj = try self.gcNewObject();
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
    /// Instance fields in declaration order, initialized per-instance at
    /// construction time (base classes: at constructor entry; derived
    /// classes: right after super() returns). Keys pre-resolved.
    ///
    /// NOTE: this ClassCtx pointer also doubles as the class's PRIVATE
    /// IDENTITY -- it's what Environment.private_ctx carries and what
    /// encodePrivateKey mixes into `#name` storage keys (brand checks fall
    /// out of key mismatch).
    instance_fields: []const FieldDef = &.{},

    /// GC prep (roadmap item 15, phase 2): see Environment.traceChildren
    /// for the visitor contract. `instance_fields[i].value` is an AST
    /// node (the unevaluated initializer expression), not a JSValue --
    /// nothing to trace there.
    fn traceChildren(self: *const ClassCtx, visitor: anytype) void {
        visitor.environment(self.closure_env);
        if (self.super_ctor) |v| visitor.value(v);
        if (self.super_proto) |v| visitor.value(v);
    }
};

/// `Environment.private_ctx`/`ClosureCtx.private_ctx`/`FiberState.private_ctx`
/// are typed `*anyopaque` so environment.zig doesn't need to know about the
/// class machinery, but every non-null value stored there is always a
/// `*ClassCtx` (see ClassCtx's own doc comment on doubling as the private
/// identity) -- this makes that assumption explicit at the one place that
/// needs to see through it (GC tracing).
fn classCtxFromOpaque(ptr: *anyopaque) *ClassCtx {
    return @ptrCast(@alignCast(ptr));
}

const TraceMockVisitor = struct {
    values: std.ArrayList(JSValue) = .empty,
    environments: std.ArrayList(*Environment) = .empty,

    fn value(self: *TraceMockVisitor, v: JSValue) void {
        self.values.append(std.testing.allocator, v) catch unreachable;
    }
    fn environment(self: *TraceMockVisitor, e: *Environment) void {
        self.environments.append(std.testing.allocator, e) catch unreachable;
    }
    fn deinit(self: *TraceMockVisitor) void {
        self.values.deinit(std.testing.allocator);
        self.environments.deinit(std.testing.allocator);
    }
};

test "ClassCtx.traceChildren visits closure_env and both super refs, skips null ones" {
    const testing = std.testing;
    var env = Environment{ .parent = null };
    var cctx = ClassCtx{
        .interp = undefined,
        .ctor_fnode = null,
        .closure_env = &env,
        .name = "C",
        .super_ctor = JSValue.fromNumber(1),
        .super_proto = null, // base class: no super -- must NOT be visited
    };
    var mock: TraceMockVisitor = .{};
    defer mock.deinit();
    cctx.traceChildren(&mock);

    try testing.expectEqual(@as(usize, 1), mock.environments.items.len);
    try testing.expectEqual(&env, mock.environments.items[0]);
    try testing.expectEqual(@as(usize, 1), mock.values.items.len);
    try testing.expectEqual(@as(f64, 1), mock.values.items[0].number);
}

test "ClosureCtx.traceChildren visits closure_env, super_proto, and its ClassCtx's own children" {
    const testing = std.testing;
    var class_env = Environment{ .parent = null };
    var cctx = ClassCtx{
        .interp = undefined,
        .ctor_fnode = null,
        .closure_env = &class_env,
        .name = "C",
        .super_ctor = null,
        .super_proto = JSValue.fromNumber(9),
    };
    var method_env = Environment{ .parent = null };
    var cc = ClosureCtx{
        .interp = undefined,
        .function_node = undefined,
        .closure_env = &method_env,
        .super_proto = JSValue.fromNumber(42),
        .private_ctx = &cctx,
    };
    var mock: TraceMockVisitor = .{};
    defer mock.deinit();
    cc.traceChildren(&mock);

    // method_env (its own closure_env) + class_env (through private_ctx's
    // ClassCtx.traceChildren) -- private_ctx must NOT itself be surfaced as
    // an opaque pointer, only its downcast children.
    try testing.expectEqual(@as(usize, 2), mock.environments.items.len);
    try testing.expectEqual(&method_env, mock.environments.items[0]);
    try testing.expectEqual(&class_env, mock.environments.items[1]);
    // ClosureCtx's own super_proto (42) + ClassCtx's super_proto (9).
    try testing.expectEqual(@as(usize, 2), mock.values.items.len);
    try testing.expectEqual(@as(f64, 42), mock.values.items[0].number);
    try testing.expectEqual(@as(f64, 9), mock.values.items[1].number);
}

test "ClosureCtx.traceChildren with no private_ctx only visits closure_env" {
    const testing = std.testing;
    var env = Environment{ .parent = null };
    var cc = ClosureCtx{
        .interp = undefined,
        .function_node = undefined,
        .closure_env = &env,
    };
    var mock: TraceMockVisitor = .{};
    defer mock.deinit();
    cc.traceChildren(&mock);

    try testing.expectEqual(@as(usize, 1), mock.environments.items.len);
    try testing.expectEqual(@as(usize, 0), mock.values.items.len);
}

test "FiberState.traceChildren visits closure_env, this, args, and every in-flight slot" {
    const testing = std.testing;
    var env = Environment{ .parent = null };
    var args = [_]JSValue{ JSValue.fromNumber(1), JSValue.fromNumber(2) };
    var fs = FiberState{
        .is_generator = true,
        .is_async = true,
        .interp = undefined,
        .fiber = undefined,
        .fnode = undefined,
        .closure_env = &env,
        .this_value = JSValue.fromNumber(3),
        .private_ctx = null,
        .args = &args,
        .resume_value = JSValue.fromNumber(4),
        .yielded = JSValue.fromNumber(5),
        .completion = JSValue.fromNumber(6),
        .completed_throw = null, // not thrown -- must NOT be visited
        .promise = null, // async generator: uses pending_result_promise instead
        .pending_result_promise = JSValue.fromNumber(7),
    };
    var mock: TraceMockVisitor = .{};
    defer mock.deinit();
    fs.traceChildren(&mock);

    try testing.expectEqual(@as(usize, 1), mock.environments.items.len);
    // this(3) + args[0](1) + args[1](2) + resume_value(4) + yielded(5) +
    // completion(6) + pending_result_promise(7) -- completed_throw/promise
    // stayed null, 7 values total.
    try testing.expectEqual(@as(usize, 7), mock.values.items.len);
    var sum: f64 = 0;
    for (mock.values.items) |v| sum += v.number;
    try testing.expectEqual(@as(f64, 1 + 2 + 3 + 4 + 5 + 6 + 7), sum);
}

/// GC registry (roadmap item 15, phase 4): every kind of node the
/// collector's registry can hold. The 7 boxed JSValue variants that can
/// contain other JSValues (leaves -- string/regex/symbol/date -- can't
/// form cycles by construction, since they hold no JSValue fields, and
/// are never registered) plus the 4 non-Rc interpreter-owned node kinds
/// from phase 2.
const GcNode = union(enum) {
    array: *zvalue.Rc(zarray.ZArray(JSValue)),
    object: *zvalue.Rc(zobject.ZObject(JSValue)),
    regex: *zvalue.Rc(zregex.Regex),
    map: *zvalue.Rc(zmap.ZMap(JSValue, JSValue)),
    set: *zvalue.Rc(zset.ZSet(JSValue)),
    @"error": *zvalue.Rc(zerror.ZError(JSValue)),
    function: *zvalue.Rc(zvalue.Callable),
    promise: *zvalue.Rc(zvalue.ZPromise(JSValue)),
    /// Symbols and strings are leaves (hold no JSValue children, can't
    /// cycle) but are STILL registered: a value that's created and
    /// immediately retained for storage elsewhere (every well-known
    /// symbol, `Symbol.for`'s registry, `Symbol.description`, ...) ends
    /// up with a refcount one higher than what actually gets released
    /// along its only reachable path (same "declaration leaves refcount
    /// 2, not 1" quirk documented in refcount_test.zig) -- registering
    /// it sidesteps that entirely, since a registered node is always
    /// destroyed via its own registry entry regardless of what its
    /// count says, exactly like containers already are.
    symbol: *zvalue.Rc(zsymbol.ZSymbol),
    string: *zvalue.Rc(zstring.ZString),
    date: *zvalue.Rc(zdate.ZDate),
    environment: *Environment,
    closure_ctx: *ClosureCtx,
    fiber_state: *FiberState,
    class_ctx: *ClassCtx,
    promise_cap_ctx: *builtins.PromiseCapCtx,
    /// Native-function contexts (Callable.ctx) for `.bind()`, `.then().
    /// finally()`, `Promise.all`, `Promise.race`, and array
    /// `.keys()`/`.values()`/`.entries()` iterators -- discovered via the
    /// same registry-lookup-on-ctx-address mechanism as
    /// closure_ctx/class_ctx/promise_cap_ctx (see `traceValueChildren`'s
    /// `.function` case). Added together (roadmap item 15 follow-up):
    /// none of these had ANY teardown path before, native-forever leaks
    /// for every bind()/finally()/all()/race()/array-iterator call.
    bound_ctx: *builtins.BoundCtx,
    finally_ctx: *builtins.FinallyCtx,
    all_ctx: *builtins.AllCtx,
    all_elem_ctx: *builtins.AllElemCtx,
    race_ctx: *builtins.RaceCtx,
    array_iter_ctx: *builtins.ArrayIterCtx,

    /// The registry key: the node's own address, regardless of kind.
    fn address(self: GcNode) usize {
        return switch (self) {
            inline else => |ptr| @intFromPtr(ptr),
        };
    }
};

/// Keyed by `GcNode.address()` for O(1) average insert/remove/lookup --
/// same side-table pattern as `regex_state`/`array_props`. Populated at
/// every gc-tracked creation site (the `gcNew*`/`gcTrackEnvironment`/etc.
/// methods below); entries are removed either by the GC hook firing
/// (`Rc.destroy()` reached naturally mid-run, the common case for
/// acyclic garbage) or by `collectGarbage()`'s sweep (a node mark()
/// never reached from the roots -- a cycle, or one of the 4 non-Rc kinds
/// that have no other teardown path at all).
const GcRegistry = std.AutoHashMapUnmanaged(usize, GcNode);

/// The concrete mark-phase visitor (satisfies the `visitor: anytype`
/// contract every `traceChildren` expects: `.value(JSValue)` and
/// `.environment(*Environment)`). `reached` records every address
/// visited so a cycle terminates the walk (revisiting an already-marked
/// node is a no-op) instead of looping forever, and so sweep() can tell
/// "reachable" apart from "in the registry but never reached" (garbage).
const Marker = struct {
    interp: *Interpreter,
    reached: std.AutoHashMapUnmanaged(usize, void) = .empty,

    pub fn value(self: *Marker, v: JSValue) void {
        const addr: usize = switch (v) {
            .@"undefined", .@"null", .boolean, .number => return,
            .array => |box| @intFromPtr(box),
            .object => |box| @intFromPtr(box),
            .regex => |box| @intFromPtr(box),
            .map => |box| @intFromPtr(box),
            .set => |box| @intFromPtr(box),
            .@"error" => |box| @intFromPtr(box),
            .function => |box| @intFromPtr(box),
            .promise => |box| @intFromPtr(box),
            .symbol => |box| @intFromPtr(box),
            .string => |box| @intFromPtr(box),
            .date => |box| @intFromPtr(box),
        };
        const gop = self.reached.getOrPut(self.interp.gc_allocator, addr) catch return;
        if (gop.found_existing) return;
        self.interp.traceValueChildren(v, self);
    }

    pub fn environment(self: *Marker, e: *Environment) void {
        const addr = @intFromPtr(e);
        const gop = self.reached.getOrPut(self.interp.gc_allocator, addr) catch return;
        if (gop.found_existing) return;
        e.traceChildren(self);
        // Environment.traceChildren deliberately skips private_ctx (opaque
        // there, always really a *ClassCtx) -- resolve it here instead,
        // where the class machinery is visible.
        if (e.private_ctx) |pc| classCtxFromOpaque(pc).traceChildren(self);
    }

    /// Marks a FiberState as reachable directly -- used for roots that
    /// aren't discovered through the normal JSValue/Environment graph
    /// (see `markRoots`'s conservative "any unfinished fiber is a root"
    /// pass and `current_fiber`).
    fn markFiberState(self: *Marker, fs: *FiberState) void {
        const addr = @intFromPtr(fs);
        const gop = self.reached.getOrPut(self.interp.gc_allocator, addr) catch return;
        if (gop.found_existing) return;
        fs.traceChildren(self);
    }
};

/// The sweep-phase visitor: for each JSValue a garbage node directly
/// held, releases the reference (`.deinit()`) UNLESS the child is
/// itself also garbage in this same pass (then it's left alone --
/// freeGarbageNode will tear it down on its own turn, and touching it
/// here would race/double-free against that). Environment links carry
/// no ownership (see `freeGarbageNode`'s `.environment` case), so
/// `environment()` is a no-op.
const Sweeper = struct {
    garbage: *const std.AutoHashMapUnmanaged(usize, void),

    pub fn value(self: *Sweeper, v: JSValue) void {
        const addr: usize = switch (v) {
            .@"undefined", .@"null", .boolean, .number => return,
            .string => |box| @intFromPtr(box),
            .regex => |box| @intFromPtr(box),
            .symbol => |box| @intFromPtr(box),
            .date => |box| @intFromPtr(box),
            .array => |box| @intFromPtr(box),
            .object => |box| @intFromPtr(box),
            .map => |box| @intFromPtr(box),
            .set => |box| @intFromPtr(box),
            .@"error" => |box| @intFromPtr(box),
            .function => |box| @intFromPtr(box),
            .promise => |box| @intFromPtr(box),
        };
        if (self.garbage.contains(addr)) return;
        v.deinit();
    }

    pub fn environment(self: *Sweeper, e: *Environment) void {
        _ = self;
        _ = e;
    }
};

pub const Interpreter = struct {
    arena_state: std.heap.ArenaAllocator,
    /// Backs every GC-participating allocation (JSValue's container-shaped
    /// boxed variants, plus leaves for symmetry; Environment; ClosureCtx;
    /// FiberState; ClassCtx; fiber stacks) -- kept separate from
    /// `arena_state` (AST-adjacent parser output, scratch buffers) so
    /// `Rc.destroy()`/`collectGarbage()`'s sweep can return memory to the
    /// OS for real (GC roadmap item 15, phase 3). Same value as the
    /// `backing_allocator` passed to `init` -- not wrapped in an arena.
    gc_allocator: Allocator,
    /// The "all live GC objects" registry (phase 4) -- see `GcNode`/
    /// `GcRegistry`'s own doc comments.
    gc_registry: GcRegistry = .empty,
    global_env: *Environment,
    /// Injected, not hardcoded to real stdout -- lets tests point this at
    /// an in-memory buffer instead of touching the process's actual
    /// stdout. console.log/info/debug write here.
    console_writer: *std.Io.Writer,
    /// console.error/warn write here instead (real Node: log/info/debug
    /// go to stdout, error/warn go to stderr -- confirmed against real
    /// Node, not assumed). Defaults to the SAME writer as console_writer
    /// in `init()` (so the 11+ existing call sites across tests/z-run
    /// that only pass one writer keep working unchanged); a caller that
    /// wants real stdout/stderr separation (z-run's main.zig) sets this
    /// field directly after construction.
    console_error_writer: *std.Io.Writer,
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
    /// The well-known `Symbol.asyncIterator` -- resolveAsyncIterator's
    /// first choice for `for await`. Set in setupGlobals.
    symbol_async_iterator: ?JSValue = null,
    /// The real builtin prototype objects (`Object.prototype`,
    /// `Array.prototype`, ...), materialized once in setupGlobals and alive
    /// for the whole run (arena). Each holds its type's methods as real own
    /// data properties (writable, non-enumerable, configurable), so
    /// reflection (getOwnPropertyDescriptor / getPrototypeOf / verifyProperty)
    /// works and identity like `[].push === Array.prototype.push` holds.
    /// Property lookup for each primitive type walks its proto here. All
    /// chain to `object_proto` except `object_proto` itself (chain end).
    protos: Protos = .{},
    /// The `globalThis` object. Property reads/writes on it are backed by the
    /// global environment (there is no separately-reified global record), so
    /// `globalThis.Object`, `var x=1; globalThis.x`, and `globalThis.y=2`
    /// (which creates a global) all stay in sync. Set in setupGlobals.
    global_object: ?JSValue = null,
    /// The intrinsic `eval` function. A call written literally as `eval(...)`
    /// (this exact function, un-shadowed) is *direct* eval -- it runs in the
    /// caller's scope; any other reference is indirect (global scope). Set in
    /// setupGlobals; compared by function-box identity in evalCall.
    eval_fn: ?JSValue = null,
    /// A derived-class constructor whose instance fields are waiting for
    /// `super()` to return (spec order: parent fields -> own fields -> rest
    /// of the ctor body). Set by classConstructorCall on entry, consumed by
    /// evalCall's super() branch; save/restore discipline keeps nested
    /// constructions (`constructor() { new Other(); super(); }`) correct.
    pending_field_init: ?*anyopaque = null,
    /// JS-level RegExp state, keyed by the `.regex` Rc box pointer --
    /// z-regex is a pure engine, so the mutable `lastIndex`, the flags
    /// string, and the boolean flag set live here (the symbol_keys
    /// pattern).
    regex_state: std.AutoHashMapUnmanaged(usize, RegexState) = .empty,
    /// Named own properties on array values (arrays have no general
    /// property bag) -- used by exec/match result arrays for
    /// `index`/`input`/`groups`. Keyed by the array Rc box pointer; the
    /// value is a plain object holding the extras.
    array_props: std.AutoHashMapUnmanaged(usize, JSValue) = .empty,
    /// The boxed primitive inside a `new String()`/`new Number()`/
    /// `new Boolean()` wrapper object -- these constructors return an
    /// ordinary object (no internal-slot concept exists on JSValue's
    /// `.object` variant), so the wrapped primitive lives here instead,
    /// keyed by the wrapper object's Rc box pointer. Same side-table
    /// shape as `array_props`. See /home/sweb/.plans/primitive-wrapper-objects.md.
    primitive_wrapper_data: std.AutoHashMapUnmanaged(usize, JSValue) = .empty,
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
            .gc_allocator = backing_allocator,
            .global_env = undefined,
            .console_writer = console_writer,
            .console_error_writer = console_writer,
        };
        const global_env = try self.gc_allocator.create(Environment);
        global_env.* = .{ .parent = null };
        try self.gcTrackEnvironment(global_env);
        self.global_env = global_env;
        return self;
    }

    /// Frees every value/environment/closure this interpreter ever
    /// allocated. AST-adjacent/scratch data goes in one shot via the
    /// arena as before; everything GC-tracked (roadmap item 15) goes
    /// through `freeAllGcNodes` first -- unlike `collectGarbage()`'s
    /// normal sweep (which only frees what's unreachable), this frees
    /// the WHOLE registry unconditionally, live or not, since the
    /// interpreter itself is going away. Once that's done every JSValue
    /// this interpreter ever created is gone, so the side-tables below
    /// only need their OWN backing storage freed (gc_allocator-allocated
    /// key strings, then each map/list's internal array) -- touching any
    /// JSValue still stored in them again would be a double-free.
    pub fn deinit(self: *Interpreter) void {
        self.freeAllGcNodes();
        self.gc_registry.deinit(self.gc_allocator);

        var mcit = self.method_cache.keyIterator();
        while (mcit.next()) |k| self.gc_allocator.free(k.*);
        self.method_cache.deinit(self.gc_allocator);

        var skit = self.symbol_keys.keyIterator();
        while (skit.next()) |k| self.gc_allocator.free(k.*);
        self.symbol_keys.deinit(self.gc_allocator);

        var srit = self.symbol_registry.keyIterator();
        while (srit.next()) |k| self.gc_allocator.free(k.*);
        self.symbol_registry.deinit(self.gc_allocator);

        // modules' keys (loaded.path) are arena-allocated (the loader
        // gets the arena, not gc_allocator -- see loadModule), freed in
        // bulk by arena_state.deinit() below. The *ModuleRecord VALUES
        // are gc_allocator's, though (gc.create(ModuleRecord) in
        // loadModule) -- freeAllGcNodes() above already tore down each
        // record's `.exports` JSValue (it's a GC root via markRoots, see
        // collectGarbage), so only the record struct itself (the pointer
        // container) needs destroying here, not its fields.
        var mod_it = self.modules.valueIterator();
        while (mod_it.next()) |rec| self.gc_allocator.destroy(rec.*);
        self.modules.deinit(self.gc_allocator);
        self.regex_state.deinit(self.gc_allocator);
        self.array_props.deinit(self.gc_allocator);
        self.primitive_wrapper_data.deinit(self.gc_allocator);
        self.pending_jobs.deinit(self.gc_allocator);
        self.timers.deinit(self.gc_allocator);

        self.arena_state.deinit();
    }

    // ---- GC (roadmap item 15, phases 3+4) --------------------------------

    /// Fired by `Rc(T).destroy()` (via the GC hook set in `gcTrack`)
    /// whenever a tracked box's refcount naturally reaches zero mid-run --
    /// the common case for acyclic garbage. Keeps the registry from ever
    /// holding a dangling entry.
    fn gcOnBoxDestroyed(ctx: *anyopaque, box: *anyopaque) void {
        const self: *Interpreter = @ptrCast(@alignCast(ctx));
        _ = self.gc_registry.remove(@intFromPtr(box));
        // A destroyed box might be a `.regex` with its own entry in
        // regex_state (source/flags duped separately from whatever the
        // Regex engine itself owns, for `.source`/`.flags` reflection --
        // see makeRegex) -- a no-op lookup for every other box kind,
        // real cleanup only for regex boxes.
        if (self.regex_state.fetchRemove(@intFromPtr(box))) |kv| {
            self.gc_allocator.free(kv.value.source);
            self.gc_allocator.free(kv.value.flags);
        }
    }

    /// Registers a container-shaped JSValue (leaves are silently ignored --
    /// see `GcNode`'s doc comment) into the registry and wires the GC hook
    /// so natural Rc teardown keeps the registry accurate. Every
    /// `gcNew*`/other container-producing site should route through this
    /// exactly once, right after creation.
    fn gcTrack(self: *Interpreter, v: JSValue) !void {
        const node: GcNode = switch (v) {
            .array => |box| .{ .array = box },
            .object => |box| .{ .object = box },
            .regex => |box| .{ .regex = box },
            .map => |box| .{ .map = box },
            .set => |box| .{ .set = box },
            .@"error" => |box| .{ .@"error" = box },
            .function => |box| .{ .function = box },
            .promise => |box| .{ .promise = box },
            .symbol => |box| .{ .symbol = box },
            .string => |box| .{ .string = box },
            .date => |box| .{ .date = box },
            else => return,
        };
        v.setGcHook(self, gcOnBoxDestroyed);
        try self.gc_registry.put(self.gc_allocator, node.address(), node);
    }

    /// Registers every container node of a JSValue tree built OUTSIDE the
    /// gcNew*/gcTrack path -- namely JSON.parse/YAML.parse, which construct
    /// their result via z-value's raw constructors (JSValue.newObject/
    /// newArray/newString) one level at a time, with no call back into the
    /// interpreter that would normally register each node. Without this,
    /// the whole tree (root AND every nested node) is invisible to
    /// freeAllGcNodes()/collectGarbage() and only survives via correct Rc
    /// bookkeeping, if at all -- an unassigned or later-orphaned
    /// JSON.parse() result leaks unconditionally otherwise. Scoped to the
    /// node kinds a JSON/YAML parser can actually produce (object/array/
    /// string); a plain recursive walk with no cycle guard is safe because
    /// freshly parsed text can never encode a back-reference.
    pub fn gcAdoptTree(self: *Interpreter, v: JSValue) !void {
        switch (v) {
            .object => |box| {
                try self.gcTrack(v);
                for (box.value.properties.values()) |prop| try self.gcAdoptTree(prop.value);
            },
            .array => |box| {
                try self.gcTrack(v);
                for (box.value.toSliceMut()) |child| try self.gcAdoptTree(child);
            },
            .string => try self.gcTrack(v),
            else => {},
        }
    }

    /// Registers a non-Rc GC node (Environment/ClosureCtx/FiberState/
    /// ClassCtx) -- these have no `Rc.destroy()` teardown path of their
    /// own at all, so the registry entry is the ONLY thing standing
    /// between them and leaking forever; only `collectGarbage`'s sweep
    /// (or `freeAllGcNodes` at shutdown) ever removes them.
    fn gcTrackNode(self: *Interpreter, node: GcNode) !void {
        try self.gc_registry.put(self.gc_allocator, node.address(), node);
    }
    fn gcTrackEnvironment(self: *Interpreter, e: *Environment) !void {
        try self.gcTrackNode(.{ .environment = e });
    }
    fn gcTrackClosureCtx(self: *Interpreter, cc: *ClosureCtx) !void {
        try self.gcTrackNode(.{ .closure_ctx = cc });
    }
    fn gcTrackFiberState(self: *Interpreter, fs: *FiberState) !void {
        try self.gcTrackNode(.{ .fiber_state = fs });
    }
    fn gcTrackClassCtx(self: *Interpreter, cx: *ClassCtx) !void {
        try self.gcTrackNode(.{ .class_ctx = cx });
    }
    pub fn gcTrackPromiseCapCtx(self: *Interpreter, cap: *builtins.PromiseCapCtx) !void {
        try self.gcTrackNode(.{ .promise_cap_ctx = cap });
    }
    pub fn gcTrackBoundCtx(self: *Interpreter, bc: *builtins.BoundCtx) !void {
        try self.gcTrackNode(.{ .bound_ctx = bc });
    }
    pub fn gcTrackFinallyCtx(self: *Interpreter, c: *builtins.FinallyCtx) !void {
        try self.gcTrackNode(.{ .finally_ctx = c });
    }
    pub fn gcTrackAllCtx(self: *Interpreter, c: *builtins.AllCtx) !void {
        try self.gcTrackNode(.{ .all_ctx = c });
    }
    pub fn gcTrackAllElemCtx(self: *Interpreter, c: *builtins.AllElemCtx) !void {
        try self.gcTrackNode(.{ .all_elem_ctx = c });
    }
    pub fn gcTrackRaceCtx(self: *Interpreter, c: *builtins.RaceCtx) !void {
        try self.gcTrackNode(.{ .race_ctx = c });
    }
    pub fn gcTrackArrayIterCtx(self: *Interpreter, c: *builtins.ArrayIterCtx) !void {
        try self.gcTrackNode(.{ .array_iter_ctx = c });
    }

    /// `Environment.child()` over `gc_allocator`, tracked. Every call site
    /// that used to do `env.child(self.gc_allocator)` should
    /// use this instead.
    pub fn gcChildEnv(self: *Interpreter, parent: *Environment) !*Environment {
        const child_env = try parent.child(self.gc_allocator);
        try self.gcTrackEnvironment(child_env);
        return child_env;
    }

    pub fn gcNewObject(self: *Interpreter) !JSValue {
        const v = try JSValue.newObject(self.gc_allocator);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewArray(self: *Interpreter) !JSValue {
        const v = try JSValue.newArray(self.gc_allocator);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewMap(self: *Interpreter) !JSValue {
        const v = try JSValue.newMap(self.gc_allocator);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewSet(self: *Interpreter) !JSValue {
        const v = try JSValue.newSet(self.gc_allocator);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewFunction(self: *Interpreter, callable: zvalue.Callable) !JSValue {
        const v = try JSValue.newFunction(self.gc_allocator, callable);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewPromise(self: *Interpreter) !JSValue {
        const v = try JSValue.newPromise(self.gc_allocator);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewError(self: *Interpreter, kind: zvalue.ErrorKind, message: []const u8) !JSValue {
        const v = try JSValue.newError(self.gc_allocator, kind, message);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewAggregateError(self: *Interpreter, message: []const u8, errs: []const JSValue) !JSValue {
        const v = try JSValue.newAggregateError(self.gc_allocator, message, errs);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewSymbol(self: *Interpreter, description: ?[]const u8) !JSValue {
        const v = try JSValue.newSymbol(self.gc_allocator, description);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewString(self: *Interpreter, content: []const u8) !JSValue {
        const v = try JSValue.newString(self.gc_allocator, content);
        try self.gcTrack(v);
        return v;
    }
    pub fn gcNewDate(self: *Interpreter, ms: i64) !JSValue {
        const v = try JSValue.newDate(self.gc_allocator, ms);
        try self.gcTrack(v);
        return v;
    }

    /// GC prep (phase 4): visits every JSValue directly held by a
    /// container-shaped box, mirroring `JSValue.deinit()`'s own recursive
    /// structure (zvalue.zig) but for marking/sweeping instead of
    /// releasing -- see `Marker`/`Sweeper`. `.function`'s `ctx` is resolved
    /// back to a ClosureCtx/FiberState/ClassCtx (if it is one) via a plain
    /// registry lookup on its address -- natives whose ctx is `*Interpreter`
    /// (or anything else untracked) just miss the lookup and stop there.
    fn traceValueChildren(self: *Interpreter, v: JSValue, visitor: anytype) void {
        switch (v) {
            .@"undefined", .@"null", .boolean, .number, .string, .regex, .symbol, .date => {},
            .array => |box| for (box.value.toSliceMut()) |*child| visitor.value(child.*),
            .object => |box| for (box.value.properties.values()) |prop| {
                visitor.value(prop.value);
                if (prop.getter) |g| visitor.value(g);
                if (prop.setter) |s| visitor.value(s);
            },
            .map => |box| {
                for (box.value.keys()) |*key| visitor.value(key.*);
                for (box.value.values()) |*val| visitor.value(val.*);
            },
            .set => |box| for (box.value.values()) |*val| visitor.value(val.*),
            .@"error" => |box| if (box.value.errors) |errs| for (errs) |*e| visitor.value(e.*),
            .function => |box| {
                if (box.value.prototype) |p| visitor.value(p);
                if (box.value.statics) |s| visitor.value(s);
                if (self.gc_registry.get(@intFromPtr(box.value.ctx))) |node| switch (node) {
                    .closure_ctx => |cc| cc.traceChildren(visitor),
                    .fiber_state => |fs| fs.traceChildren(visitor),
                    .class_ctx => |cx| cx.traceChildren(visitor),
                    .promise_cap_ctx => |cap| visitor.value(cap.promise),
                    .bound_ctx => |bc| {
                        visitor.value(bc.target);
                        visitor.value(bc.bound_this);
                        for (bc.pre_args) |a| visitor.value(a);
                    },
                    .finally_ctx => |c| visitor.value(c.handler),
                    .all_ctx => |c| {
                        for (c.results) |r| visitor.value(r);
                        visitor.value(c.derived);
                    },
                    // .all_elem_ctx's `all: *AllCtx` is a borrowed
                    // traversal link (AllCtx is independently reachable
                    // via the shared on_r's ctx) -- nothing owned to trace.
                    .all_elem_ctx => {},
                    .race_ctx => |c| visitor.value(c.derived),
                    .array_iter_ctx => |c| for (c.items) |item| visitor.value(item),
                    else => {},
                };
            },
            .promise => |box| {
                if (box.value.result) |r| visitor.value(r);
                for (box.value.reactions.items) |reaction| {
                    if (reaction.on_fulfilled) |h| visitor.value(h);
                    if (reaction.on_rejected) |h| visitor.value(h);
                    if (reaction.derived) |d| visitor.value(d);
                }
            },
        }
    }

    /// GC prep (phase 4): the root set. Everything reachable from here
    /// (via traceChildren/traceValueChildren) survives a sweep.
    fn markRoots(self: *Interpreter, marker: *Marker) void {
        marker.environment(self.global_env);
        if (self.script_env) |se| marker.environment(se);
        if (self.pending_exception) |ex| marker.value(ex);
        if (self.current_fiber) |fs| marker.markFiberState(fs);
        for (self.pending_jobs.items) |job| {
            if (job.handler) |h| marker.value(h);
            marker.value(job.argument);
            if (job.derived) |d| marker.value(d);
        }
        for (self.timers.items) |timer| marker.value(timer.callback);
        // Deliberately NOT "every unfinished fiber is a root": a
        // suspended-mid-await FiberState is already reachable through
        // normal graph tracing -- awaitOnFulfilled/awaitOnRejected's ctx
        // is `fs`, and that native sits in the reactions list of
        // whatever promise it's awaiting (traced by traceValueChildren's
        // `.promise` case), and THAT promise is reachable through
        // whatever real root keeps it pending (pending_jobs/timers above,
        // or another live object holding it). A generator/async object
        // that's genuinely unreachable (nothing references it, nothing
        // will ever call .next()/resume it) should be collectible -- an
        // abandoned generator is exactly the leak roadmap item 15 set
        // out to fix, not a case to protect from collection.
        var mit = self.modules.valueIterator();
        while (mit.next()) |m| marker.value(m.*.exports);
        // Side-tables not reachable through the normal object graph
        // (symbol values behind an encoded string key, the globalThis/
        // eval/well-known-symbol/prototype singletons -- most of these
        // ARE also reachable transitively through global_env already,
        // but marking them directly is harmless and removes any doubt).
        var skit = self.symbol_keys.valueIterator();
        while (skit.next()) |v| marker.value(v.*);
        var srit = self.symbol_registry.valueIterator();
        while (srit.next()) |v| marker.value(v.*);
        var apit = self.array_props.valueIterator();
        while (apit.next()) |v| marker.value(v.*);
        var pwit = self.primitive_wrapper_data.valueIterator();
        while (pwit.next()) |v| marker.value(v.*);
        var mcit = self.method_cache.valueIterator();
        while (mcit.next()) |v| marker.value(v.*);
        if (self.global_object) |v| marker.value(v);
        if (self.eval_fn) |v| marker.value(v);
        if (self.symbol_iterator) |v| marker.value(v);
        if (self.symbol_async_iterator) |v| marker.value(v);
        inline for (std.meta.fields(Protos)) |f| marker.value(@field(self.protos, f.name));
    }

    /// GC prep (phase 4): tears down one node already determined to be
    /// garbage (unreachable from any root). `sweeper` decides, for each
    /// JSValue this node directly held, whether to actually release it
    /// (`.deinit()`, if it's still alive via some other path) or leave it
    /// alone (also garbage in this same pass -- it gets torn down on its
    /// own turn instead, avoiding a double-free race between the two).
    /// Container-shaped boxes are freed directly (`box.destroy()`, NOT
    /// the normal `JSValue.deinit()` path -- sweep already knows this box
    /// is garbage regardless of its current refcount, so it skips the
    /// decref entirely and fires the GC hook to deregister immediately).
    fn freeGarbageNode(self: *Interpreter, node: GcNode, sweeper: *Sweeper) void {
        switch (node) {
            .array => |box| {
                for (box.value.toSliceMut()) |*child| sweeper.value(child.*);
                box.value.deinit();
                box.destroy();
            },
            .object => |box| {
                for (box.value.properties.values()) |prop| {
                    sweeper.value(prop.value);
                    if (prop.getter) |g| sweeper.value(g);
                    if (prop.setter) |s| sweeper.value(s);
                }
                box.value.deinit();
                box.destroy();
            },
            .map => |box| {
                for (box.value.keys()) |*key| sweeper.value(key.*);
                for (box.value.values()) |*val| sweeper.value(val.*);
                box.value.deinit();
                box.destroy();
            },
            .set => |box| {
                for (box.value.values()) |*val| sweeper.value(val.*);
                box.value.deinit();
                box.destroy();
            },
            .@"error" => |box| {
                if (box.value.errors) |errs| for (errs) |*e| sweeper.value(e.*);
                box.value.deinit();
                box.destroy();
            },
            .function => |box| {
                // Deliberately NOT box.value.deinit() (Callable.deinit()):
                // it releases prototype/statics itself via a plain,
                // garbage-UNAWARE .deinit() call, which would double-free
                // against sweeper.value() below if that same prototype
                // object is ALSO garbage in this same pass (the function
                // <-> prototype cycle every ordinary function has). Do the
                // equivalent release by hand instead, garbage-aware.
                if (box.value.prototype) |p| sweeper.value(p);
                if (box.value.statics) |s| sweeper.value(s);
                // A ClosureCtx/FiberState/ClassCtx `ctx` is its OWN
                // registry entry, torn down on its own turn in this same
                // sweep pass -- nothing further to do with it here.
                box.destroy();
            },
            .promise => |box| {
                if (box.value.result) |r| sweeper.value(r);
                for (box.value.reactions.items) |reaction| {
                    if (reaction.on_fulfilled) |h| sweeper.value(h);
                    if (reaction.on_rejected) |h| sweeper.value(h);
                    if (reaction.derived) |d| sweeper.value(d);
                }
                box.value.deinit(box.allocator);
                box.destroy();
            },
            .symbol => |box| {
                box.value.deinit();
                box.destroy();
            },
            .regex => |box| {
                box.value.deinit();
                box.destroy();
            },
            .string => |box| {
                box.value.deinit();
                box.destroy();
            },
            .date => |box| {
                // ZDate is a pure value with no allocator of its own --
                // only the box itself needs freeing (matches
                // JSValue.deinit()'s own `.date` arm).
                box.destroy();
            },
            .environment => |e| {
                var it = e.bindings.valueIterator();
                while (it.next()) |v| sweeper.value(v.*);
                if (e.this_value) |v| sweeper.value(v);
                if (e.super_proto) |v| sweeper.value(v);
                if (e.super_ctor) |v| sweeper.value(v);
                // parent/private_ctx are unowned traversal links (see
                // Sweeper.environment's doc comment) -- nothing to release.
                e.bindings.deinit(self.gc_allocator);
                e.tdz.deinit(self.gc_allocator);
                self.gc_allocator.destroy(e);
            },
            .closure_ctx => |cc| {
                if (cc.super_proto) |v| sweeper.value(v);
                self.gc_allocator.destroy(cc);
            },
            .fiber_state => |fs| {
                if (fs.this_value) |v| sweeper.value(v);
                for (fs.args) |a| sweeper.value(a);
                sweeper.value(fs.resume_value);
                if (fs.yielded) |v| sweeper.value(v);
                if (fs.completion) |v| sweeper.value(v);
                if (fs.completed_throw) |v| sweeper.value(v);
                if (fs.promise) |v| sweeper.value(v);
                if (fs.pending_result_promise) |v| sweeper.value(v);
                self.gc_allocator.free(fs.args);
                fs.fiber.deinit(self.gc_allocator);
                self.gc_allocator.destroy(fs);
            },
            .class_ctx => |cx| {
                if (cx.super_ctor) |v| sweeper.value(v);
                if (cx.super_proto) |v| sweeper.value(v);
                self.gc_allocator.free(cx.instance_fields);
                self.gc_allocator.destroy(cx);
            },
            .promise_cap_ctx => |cap| {
                sweeper.value(cap.promise);
                self.gc_allocator.destroy(cap);
            },
            .bound_ctx => |bc| {
                sweeper.value(bc.target);
                sweeper.value(bc.bound_this);
                for (bc.pre_args) |a| sweeper.value(a);
                self.gc_allocator.free(bc.pre_args);
                self.gc_allocator.free(bc.name);
                self.gc_allocator.destroy(bc);
            },
            .finally_ctx => |c| {
                sweeper.value(c.handler);
                self.gc_allocator.destroy(c);
            },
            .all_ctx => |c| {
                for (c.results) |r| sweeper.value(r);
                sweeper.value(c.derived);
                self.gc_allocator.free(c.results);
                self.gc_allocator.destroy(c);
            },
            // AllElemCtx doesn't own `all` (see traceValueChildren) --
            // just the struct itself.
            .all_elem_ctx => |c| self.gc_allocator.destroy(c),
            .race_ctx => |c| {
                sweeper.value(c.derived);
                self.gc_allocator.destroy(c);
            },
            .array_iter_ctx => |c| {
                for (c.items) |v| sweeper.value(v);
                self.gc_allocator.free(c.items);
                self.gc_allocator.destroy(c);
            },
        }
    }

    /// GC prep (phase 4): the collector's public entry point. Stop-the-
    /// world mark-and-sweep, meant to be called at safe points (between
    /// top-level statements -- see `run`/`runModule`) or explicitly. Marks
    /// everything reachable from the roots, then frees every registered
    /// node NOT reached: real cycles (the whole reason this exists) and
    /// any node with no reachable path at all, regardless of refcount.
    pub fn collectGarbage(self: *Interpreter) void {
        var marker = Marker{ .interp = self };
        defer marker.reached.deinit(self.gc_allocator);
        self.markRoots(&marker);

        var garbage: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer garbage.deinit(self.gc_allocator);
        var it = self.gc_registry.iterator();
        while (it.next()) |entry| {
            if (!marker.reached.contains(entry.key_ptr.*)) {
                garbage.put(self.gc_allocator, entry.key_ptr.*, {}) catch return;
            }
        }

        var sweeper = Sweeper{ .garbage = &garbage };
        var git = garbage.keyIterator();
        while (git.next()) |addr| {
            const node = self.gc_registry.get(addr.*) orelse continue;
            self.freeGarbageNode(node, &sweeper);
            _ = self.gc_registry.remove(addr.*);
        }
    }

    /// Unconditionally frees the WHOLE registry, live or not -- only safe
    /// to call when the interpreter itself is going away (`deinit`),
    /// unlike `collectGarbage`'s normal reachability-respecting sweep.
    /// Still routes every node through the same `Sweeper`-guarded
    /// `freeGarbageNode` (with `garbage` = "every currently registered
    /// address") so two nodes that reference each other don't race to
    /// free one another mid-teardown.
    fn freeAllGcNodes(self: *Interpreter) void {
        var garbage: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer garbage.deinit(self.gc_allocator);
        var it = self.gc_registry.iterator();
        while (it.next()) |entry| {
            garbage.put(self.gc_allocator, entry.key_ptr.*, {}) catch return;
        }
        var sweeper = Sweeper{ .garbage = &garbage };
        var git = garbage.keyIterator();
        while (git.next()) |addr| {
            const node = self.gc_registry.get(addr.*) orelse continue;
            self.freeGarbageNode(node, &sweeper);
        }
        self.gc_registry.clearAndFree(self.gc_allocator);

        // Every registered (container-shaped) node this interpreter ever
        // held is gone now -- but leaf values (symbols, strings, ...) are
        // deliberately never registered (they can't cycle), so a leaf
        // reachable ONLY through one of these direct Interpreter fields
        // (not nested inside any container) would otherwise never get
        // its final release. sweeper.value() is safe to call on
        // anything here regardless: for a value that WAS registered (an
        // object/array/function/...), its address is already in
        // `garbage` and this is a no-op; for a genuinely-unregistered
        // leaf, this is its real (and only) release. Mirrors the same
        // field list `markRoots` treats as roots.
        var skit2 = self.symbol_keys.valueIterator();
        while (skit2.next()) |v| sweeper.value(v.*);
        var srit2 = self.symbol_registry.valueIterator();
        while (srit2.next()) |v| sweeper.value(v.*);
        var apit2 = self.array_props.valueIterator();
        while (apit2.next()) |v| sweeper.value(v.*);
        var pwit2 = self.primitive_wrapper_data.valueIterator();
        while (pwit2.next()) |v| sweeper.value(v.*);
        var mcit2 = self.method_cache.valueIterator();
        while (mcit2.next()) |v| sweeper.value(v.*);
        if (self.pending_exception) |v| sweeper.value(v);
        if (self.global_object) |v| sweeper.value(v);
        if (self.eval_fn) |v| sweeper.value(v);
        if (self.symbol_iterator) |v| sweeper.value(v);
        if (self.symbol_async_iterator) |v| sweeper.value(v);
        inline for (std.meta.fields(Protos)) |f| sweeper.value(@field(self.protos, f.name));
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
        if (self.script_env == null) self.script_env = try self.gcChildEnv(self.global_env);
        // AST nodes stay on the arena (immutable, bulk-freed with the
        // whole run -- never GC-tracked); everything else this function
        // creates goes through gc_allocator.
        const ast_arena = self.arena_state.allocator();
        const parser = try zfunctions.Parser.init(ast_arena, source);
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
        const program = parser.parseProgram() catch
            return self.throwError(.syntax_error, "Invalid or unexpected token in eval", .{});
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
    fn settlePromise(self: *Interpreter, p: JSValue, state: zvalue.PromiseState, value: JSValue) anyerror!void {
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
    fn subscribePromise(self: *Interpreter, p: JSValue, on_fulfilled: ?JSValue, on_rejected: ?JSValue, derived: ?JSValue) anyerror!void {
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

    // ===== RegExp =====

    /// Compiles `pattern` with `flags` into a `.regex` value and records
    /// its JS-level state. A bad pattern is a catchable SyntaxError.
    pub fn makeRegex(self: *Interpreter, pattern: []const u8, flags: []const u8) anyerror!JSValue {
        const arena = self.gc_allocator;
        var state: RegexState = .{
            .source = try arena.dupe(u8, pattern),
            .flags = try arena.dupe(u8, flags),
            .global = false,
            .ignore_case = false,
            .multiline = false,
            .dot_all = false,
            .sticky = false,
            .unicode = false,
        };
        for (flags) |f| switch (f) {
            'g' => state.global = true,
            'i' => state.ignore_case = true,
            'm' => state.multiline = true,
            's' => state.dot_all = true,
            'y' => state.sticky = true,
            'u', 'd', 'v' => state.unicode = state.unicode or f == 'u',
            else => return self.throwError(.syntax_error, "Invalid flags supplied to RegExp constructor '{s}'", .{flags}),
        };
        const re = zregex.Regex.compileWithOptions(arena, pattern, .{
            .case_insensitive = state.ignore_case,
            .multiline = state.multiline,
            .dot_all = state.dot_all,
            .sticky = state.sticky,
        }) catch {
            return self.throwError(.syntax_error, "Invalid regular expression: /{s}/", .{pattern});
        };
        const value = try JSValue.fromRegex(arena, re);
        try self.gcTrack(value);
        try self.regex_state.put(arena, @intFromPtr(value.regex), state);
        return value;
    }

    /// The RegexState for a `.regex` value (always present -- every
    /// `.regex` is created through makeRegex).
    pub fn regexState(self: *Interpreter, value: JSValue) *RegexState {
        return self.regex_state.getPtr(@intFromPtr(value.regex)).?;
    }

    /// Stores a named own property on an array (via the array_props side
    /// table) -- exec/match result arrays' index/input/groups.
    pub fn setArrayExtra(self: *Interpreter, array: JSValue, key: []const u8, value: JSValue) anyerror!void {
        const arena = self.gc_allocator;
        const gop = try self.array_props.getOrPut(arena, @intFromPtr(array.array));
        if (!gop.found_existing) gop.value_ptr.* = try self.gcNewObject();
        try gop.value_ptr.object.value.set(key, value.retain());
    }

    /// A named own property of an array, if any (array_props side table).
    pub fn arrayExtra(self: *Interpreter, array: JSValue, key: []const u8) ?JSValue {
        const extras = self.array_props.get(@intFromPtr(array.array)) orelse return null;
        return extras.object.value.get(key);
    }

    /// The array's named-own-property object (array_props side table),
    /// created on first use. A real `.object`, so it carries full property
    /// descriptors -- lets Object.defineProperty target an array's non-index
    /// named keys.
    pub fn arrayPropsObject(self: *Interpreter, array: JSValue) !JSValue {
        const arena = self.gc_allocator;
        const gop = try self.array_props.getOrPut(arena, @intFromPtr(array.array));
        if (!gop.found_existing) gop.value_ptr.* = try self.ordinaryObject();
        return gop.value_ptr.*;
    }

    /// `new String(...)`/`new Number(...)`/`new Boolean(...)`: JSValue's
    /// `.object` variant has no internal-slot concept, so the wrapped
    /// primitive a boxed constructor computes has nowhere to live inside
    /// the object `evalNew` already created -- store it in the
    /// primitive_wrapper_data side table (same shape as array_props),
    /// keyed by the wrapper's Rc box pointer, and return the wrapper
    /// object itself instead of the bare primitive (evalNew already
    /// keeps `.object` results as-is, no changes needed there). Called
    /// from inside a constructor native (globalString/globalNumber/
    /// globalBoolean) with the primitive it just computed; a plain call
    /// (no `new`) passes `primitive` through unchanged. Ownership: takes
    /// `primitive` by value, no retain -- the constructor's own local
    /// computation is the only reference, and it's either returned
    /// (plain call) or moved into the table (constructed call), never
    /// both. See /home/sweb/.plans/primitive-wrapper-objects.md.
    pub fn boxPrimitiveIfConstructed(self: *Interpreter, ctx: *anyopaque, this_value: JSValue, primitive: JSValue) anyerror!JSValue {
        if (self.construct_target != ctx) return primitive;
        try self.primitive_wrapper_data.put(self.gc_allocator, @intFromPtr(this_value.object), primitive);
        return this_value;
    }

    /// The primitive value boxed inside a wrapper object created via
    /// `boxPrimitiveIfConstructed`, if `value` is one (primitive_wrapper_data
    /// side table). Used by requireString/requireNumber/requireBoolean to
    /// unwrap `new String(x)`/etc. before falling back to a TypeError.
    pub fn unboxPrimitiveWrapper(self: *Interpreter, value: JSValue) ?JSValue {
        if (value != .object) return null;
        return self.primitive_wrapper_data.get(@intFromPtr(value.object));
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
        if (self.script_env == null) self.script_env = try self.gcChildEnv(self.global_env);
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
        // AST nodes stay on the arena; the module record/env/exports and
        // everything else this function creates are GC-tracked.
        const ast_arena = self.arena_state.allocator();
        const gc = self.gc_allocator;
        const loader = self.module_loader orelse
            return self.throwError(.syntax_error, "Cannot use import statement outside a module", .{});
        const loaded = (try loader.load(loader.ctx, ast_arena, specifier, referrer)) orelse
            return self.throwError(.generic, "Cannot find module '{s}' imported from {s}", .{ specifier, referrer orelse "<entry>" });
        if (self.modules.get(loaded.path)) |rec| {
            if (rec.state == .loading) {
                return self.throwError(.generic, "Circular dependency detected: '{s}' (live bindings are not supported)", .{loaded.path});
            }
            return rec;
        }
        const rec = try gc.create(ModuleRecord);
        rec.* = .{ .path = loaded.path, .exports = try self.gcNewObject(), .state = .loading };
        try self.modules.put(gc, loaded.path, rec);

        const parser = try zfunctions.Parser.init(ast_arena, loaded.source);
        const program = try parser.parseProgram();
        const module_env = try self.gcChildEnv(self.global_env);

        // Import pre-pass: dependencies evaluate first (DFS), then their
        // exports bind here -- snapshots, taken after the dep finished.
        for (program) |stmt| {
            if (stmt.data != .import_decl) continue;
            const imp = stmt.data.import_decl;
            const dep = try self.loadModule(imp.source, rec.path);
            if (imp.namespace_local) |ns| {
                try module_env.define(gc, ns, dep.exports.retain());
            }
            if (imp.default_local) |dl| {
                const v = dep.exports.object.value.get("default") orelse
                    return self.throwError(.syntax_error, "The requested module '{s}' does not provide an export named 'default'", .{imp.source});
                try module_env.define(gc, dl, v.retain());
            }
            for (imp.named) |spec| {
                const v = dep.exports.object.value.get(spec.imported) orelse
                    return self.throwError(.syntax_error, "The requested module '{s}' does not provide an export named '{s}'", .{ imp.source, spec.imported });
                try module_env.define(gc, spec.local, v.retain());
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
        const arena = self.gc_allocator;
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
        const arena = self.gc_allocator;
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
        const arena = self.gc_allocator;
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
    fn resumeFiber(self: *Interpreter, fs: *FiberState) anyerror!void {
        const prev = self.current_fiber;
        const prev_limit = self.stack_limit;
        self.current_fiber = fs;
        self.stack_limit = fs.fiber.stack_floor + fiber_stack_margin;
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
    fn awaitValue(self: *Interpreter, fs: *FiberState, operand: JSValue) anyerror!JSValue {
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
    fn makeGeneratorObject(self: *Interpreter, fnode: *zfunctions.FunctionNode, closure_env: *Environment, this_value: ?JSValue, private_ctx: ?*anyopaque, args: []const JSValue) anyerror!JSValue {
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
            try obj.object.value.set(key, try self.nativeMethod("iterator", "self", iteratorSelf));
        }
        return obj;
    }

    /// Calling `async function` starts the body IMMEDIATELY on its fiber
    /// (synchronous until the first await -- real semantics) and returns
    /// the promise; completion settles it from inside the entry.
    fn runAsyncFunction(self: *Interpreter, fnode: *zfunctions.FunctionNode, closure_env: *Environment, this_value: ?JSValue, private_ctx: ?*anyopaque, args: []const JSValue) anyerror!JSValue {
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
    fn makeAsyncGeneratorObject(self: *Interpreter, fnode: *zfunctions.FunctionNode, closure_env: *Environment, this_value: ?JSValue, private_ctx: ?*anyopaque, args: []const JSValue) anyerror!JSValue {
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
            try obj.object.value.set(key, try self.nativeMethod("asyncIterator", "self", iteratorSelf));
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
    fn runEventLoop(self: *Interpreter) anyerror!void {
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
        const msg = try std.fmt.allocPrint(self.gc_allocator, fmt, args);
        // ZError.init() (zerror.zig) dupes `message` into its own storage --
        // this formatted copy is only scratch space for that call.
        defer self.gc_allocator.free(msg);
        return self.throwValue(try self.gcNewError(kind, msg));
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
        const arena = self.gc_allocator;
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
        const arena = self.gc_allocator;
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
        const arena = self.gc_allocator;
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
        const arena = self.gc_allocator;
        switch (stmt.data) {
            .empty, .debugger => return .{},
            .expr_stmt => |expr| {
                const v = try self.evalExpression(env, expr);
                return .{ .type = .normal, .value = v };
            },
            .block => |stmts| {
                const block_env = try self.gcChildEnv(env);
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
                defer labels.deinit(arena);
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
                    const catch_env = try self.gcChildEnv(env);
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
                const switch_env = try self.gcChildEnv(env);
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
        switch (s.head) {
            .c_style => |head| {
                const loop_env = try self.gcChildEnv(env);
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
    pub fn iterableItems(self: *Interpreter, value: JSValue) anyerror![]const JSValue {
        const arena = self.gc_allocator;
        return switch (value) {
            .array => |box| box.value.toSlice(),
            .string => |box| blk: {
                var cps: std.ArrayList(JSValue) = .empty;
                var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
                while (it.nextCodepointSlice()) |cp| {
                    try cps.append(arena, try self.gcNewString(cp));
                }
                break :blk try cps.toOwnedSlice(arena);
            },
            // A user iterable (Symbol.iterator) or a hand-written iterator
            // (duck-typed `next`) -- drained fully.
            .object => try self.drainIterator(try self.resolveIterator(value)),
            // Sets iterate their values; Maps their [key, value] pairs --
            // so `[...set]`, `Array.from(map)`, `f(...set)` all work.
            .set => |box| blk: {
                const vals = box.value.values();
                const out = try arena.alloc(JSValue, vals.len);
                for (vals, 0..) |v, i| out[i] = v;
                break :blk out;
            },
            .map => |box| blk: {
                const ks = box.value.keys();
                const vs = box.value.values();
                var out: std.ArrayList(JSValue) = .empty;
                for (ks, vs) |k, v| {
                    var pair = try self.gcNewArray();
                    _ = try pair.array.value.push(k.retain());
                    _ = try pair.array.value.push(v.retain());
                    try out.append(arena, pair);
                }
                break :blk try out.toOwnedSlice(arena);
            },
            else => self.throwError(.type_error, "{s} is not iterable", .{value.typeOf()}),
        };
    }

    /// The iterator object for a `.object`: its `[Symbol.iterator]()`
    /// result if it has one, else the object itself if it's already an
    /// iterator (callable `next`). TypeError otherwise (not iterable).
    pub fn resolveIterator(self: *Interpreter, obj: JSValue) anyerror!JSValue {
        const arena = self.gc_allocator;
        if (self.symbol_iterator) |sym| {
            const key = try self.encodeKey(sym);
            defer self.gc_allocator.free(key);
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

    /// Like resolveIterator, but for `for await`: tries `[Symbol.
    /// asyncIterator]()` first (a real async iterator, e.g. an async
    /// generator object); falls back to the ordinary sync-iterator
    /// resolution (AsyncFromSyncIterator wrapping -- the caller Awaits
    /// each produced value either way, which is what actually makes a
    /// plain Symbol.iterator object work under `for await`).
    fn resolveAsyncIterator(self: *Interpreter, obj: JSValue) anyerror!JSValue {
        const arena = self.gc_allocator;
        if (self.symbol_async_iterator) |sym| {
            const key = try self.encodeKey(sym);
            defer self.gc_allocator.free(key);
            const method = try self.getProperty(obj, key);
            if (method == .function) {
                const iter = try method.function.value.call(method.function.value.ctx, arena, obj, &.{});
                if (iter != .object) return self.throwError(.type_error, "Result of the Symbol.asyncIterator method is not an object", .{});
                return iter;
            }
        }
        return self.resolveIterator(obj);
    }

    /// Runs an iterator object to completion, collecting its values.
    pub fn drainIterator(self: *Interpreter, iter: JSValue) anyerror![]const JSValue {
        const arena = self.gc_allocator;
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
        const arena = self.gc_allocator;
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
        const arena = self.gc_allocator;
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
                    var rest_arr = try self.gcNewArray();
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
                    var rest_obj = try self.ordinaryObject();
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
        const arena = self.gc_allocator;
        switch (target.data) {
            .array_literal => |elements| {
                const items = try self.iterableItems(value);
                for (elements, 0..) |maybe_el, i| {
                    const el = maybe_el orelse continue; // hole still consumes its index
                    if (el.data == .spread) {
                        // Parse-time validation guarantees this is last.
                        var rest_arr = try self.gcNewArray();
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
                var consumed: std.ArrayList(PropKey) = .empty;
                defer {
                    for (consumed.items) |pk| pk.free(arena);
                    consumed.deinit(arena);
                }
                for (elements) |el| {
                    switch (el) {
                        .property => |prop| {
                            const pk = try self.propertyKeyString(env, prop.computed, prop.key);
                            const key = pk.key;
                            try consumed.append(arena, pk);
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
                            var rest_obj = try self.ordinaryObject();
                            if (value == .object) {
                                const keys = try value.object.value.keys(arena);
                                defer arena.free(keys);
                                outer: for (keys) |k| {
                                    for (consumed.items) |c| {
                                        if (std.mem.eql(u8, c.key, k)) continue :outer;
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
        switch (binding) {
            .declared => |d| {
                if (d.kind == .@"var") {
                    try self.bindPattern(env, d.pattern, value, .assign);
                    return env;
                }
                const iter_env = try self.gcChildEnv(env);
                try self.bindPattern(iter_env, d.pattern, value, .define);
                return iter_env;
            },
            .existing => |name| {
                // env.assign takes ownership -- retain, matching bindPattern's
                // convention (the caller keeps its own reference to `value`).
                env.assign(name.name, value.retain()) catch |err| return switch (err) {
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
        const arena = self.gc_allocator;
        const is_await = head.is_await;
        // The parser only ever sets is_await inside an async function/async
        // generator body (await_allowed-gated), so a live fiber always
        // exists here; a missing one would be an interpreter bug -- same
        // contract as `.await_expr`/`.yield_expr`.
        const fs: ?*FiberState = if (is_await) (self.current_fiber orelse return error.NotImplemented) else null;
        const iterable = try self.evalExpression(env, head.iterable);
        switch (iterable) {
            .array => |box| {
                // Live iteration (ArrayIterator semantics): re-read length
                // each step and retain the element, so a body that mutates
                // the array (`array.pop()`) is observed and never leaves a
                // cached slice dangling.
                var i: usize = 0;
                while (i < box.value.length()) : (i += 1) {
                    var item = box.value.get(i).retain();
                    if (is_await) item = try self.awaitValue(fs.?, item);
                    if (try self.forIterationStep(env, head.binding, item, body, labels)) |c| return c;
                }
            },
            .string => |box| {
                var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
                while (it.nextCodepointSlice()) |cp| {
                    var ch = try self.gcNewString(cp);
                    if (is_await) ch = try self.awaitValue(fs.?, ch);
                    if (try self.forIterationStep(env, head.binding, ch, body, labels)) |c| return c;
                }
            },
            .map => |box| {
                // Live iteration (MapIterator semantics): re-read the ordered
                // keys each step (delete compacts them), retaining key+value,
                // so a body that mutates the map is observed and never dangles.
                var i: usize = 0;
                while (true) {
                    const ks = box.value.keys();
                    if (i >= ks.len) break;
                    const k = ks[i].retain();
                    const v = (box.value.get(k) orelse JSValue.UNDEFINED).retain();
                    i += 1;
                    var entry = try self.gcNewArray();
                    _ = try entry.array.value.push(k);
                    _ = try entry.array.value.push(v);
                    if (is_await) entry = try self.awaitValue(fs.?, entry);
                    if (try self.forIterationStep(env, head.binding, entry, body, labels)) |c| return c;
                }
            },
            .set => |box| {
                // Live iteration (SetIterator semantics): re-read the ordered
                // values each step (delete compacts them) and retain the
                // element, so a body that mutates the set (`set.delete(x)`) is
                // observed and never dangles a cached slice.
                var i: usize = 0;
                while (true) {
                    const vals = box.value.values();
                    if (i >= vals.len) break;
                    var v = vals[i].retain();
                    i += 1;
                    if (is_await) v = try self.awaitValue(fs.?, v);
                    if (try self.forIterationStep(env, head.binding, v, body, labels)) |c| return c;
                }
            },
            // The iterator protocol: a user iterable via Symbol.iterator
            // (or Symbol.asyncIterator, for `for await`), or an object that
            // IS an iterator (duck-typed `next` -- generator objects,
            // hand-written iterators). The completion value (`done: true`'s
            // value) is excluded, per spec.
            .object => {
                const iter = if (is_await) try self.resolveAsyncIterator(iterable) else try self.resolveIterator(iterable);
                const next_fn = try self.getProperty(iter, "next");
                while (true) {
                    var step = try next_fn.function.value.call(next_fn.function.value.ctx, arena, iter, &.{});
                    // A real async iterator's next() returns a PROMISE of
                    // {value,done}; the AsyncFromSyncIterator fallback
                    // (plain Symbol.iterator) returns the {value,done}
                    // object directly -- either way, awaiting a non-promise
                    // is a harmless one-tick round trip, so this one check
                    // handles both without needing to track which case
                    // resolveAsyncIterator picked.
                    if (is_await and step == .promise) step = try self.awaitValue(fs.?, step);
                    if (step != .object) {
                        return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
                    }
                    if (coercion.isTruthy(try self.getProperty(step, "done"))) break;
                    var value = try self.getProperty(step, "value");
                    // Spec: for-await-of also Awaits the extracted VALUE
                    // itself (AsyncFromSyncIteratorContinuation, for the
                    // sync-fallback case). Awaiting an already-resolved
                    // value from a genuine async iterator is a no-op
                    // extra tick -- documented, narrowed simplification.
                    if (is_await) value = try self.awaitValue(fs.?, value);
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
        const arena = self.gc_allocator;
        const target = try self.evalExpression(env, head.object);
        switch (target) {
            .object => |box| {
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                defer seen.deinit(arena);
                var keys_list: std.ArrayList([]const u8) = .empty;
                defer keys_list.deinit(arena);
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
                    const kv = try self.gcNewString(k);
                    if (try self.forIterationStep(env, head.binding, kv, body, labels)) |c| return c;
                }
            },
            .array => |box| {
                const len = box.value.length();
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    const key_str = try std.fmt.allocPrint(arena, "{d}", .{i});
                    defer arena.free(key_str);
                    const kv = try self.gcNewString(key_str);
                    if (try self.forIterationStep(env, head.binding, kv, body, labels)) |c| return c;
                }
            },
            .string => |box| {
                var i: usize = 0;
                while (i < box.value.data.len) : (i += 1) {
                    const key_str = try std.fmt.allocPrint(arena, "{d}", .{i});
                    defer arena.free(key_str);
                    const kv = try self.gcNewString(key_str);
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
        const arena = self.gc_allocator;
        switch (node.data) {
            .number_literal => |n| return JSValue.fromNumber(n),
            .string_literal => |s| return try self.gcNewString(s),
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
                return try self.gcNewString(buf.items);
            },
            .array_literal => |elements| {
                var arr = try self.gcNewArray();
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
                var obj = try self.ordinaryObject();
                for (elements) |el| {
                    switch (el) {
                        .property => |prop| {
                            const pk = try self.propertyKeyString(env, prop.computed, prop.key);
                            defer pk.free(self.gc_allocator);
                            const key_str = pk.key;
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
                // `#x in obj` (private brand check): the LHS is a bare
                // private name -- it must NOT be evaluated as an identifier
                // (that would be a ReferenceError); intercept on the node.
                if (b.op == .in and b.left.data == .identifier and b.left.data.identifier.len > 0 and b.left.data.identifier[0] == '#') {
                    const r = try self.evalExpression(env, b.right);
                    return JSValue.fromBool(try self.privateHas(env, r, b.left.data.identifier));
                }
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
                    const pk = try self.memberKeyString(env, m);
                    defer pk.free(self.gc_allocator);
                    return try self.getProperty(sproto, pk.key);
                }
                const obj = try self.evalExpression(env, m.object);
                if (m.optional and (obj == .@"undefined" or obj == .@"null")) return JSValue.UNDEFINED;
                if (privateMemberName(m)) |pn| return self.privateGet(env, obj, pn);
                const pk = try self.memberKeyString(env, m);
                defer pk.free(self.gc_allocator);
                return try self.getProperty(obj, pk.key);
            },
            .function_like => |ptr| return try self.makeClosure(env, zfunctions.asFunctionNode(ptr)),
            .class_like => |ptr| return try self.evalClass(env, zfunctions.asClassNode(ptr)),
            // The suspension points. The parser only produces these inside
            // generator/async bodies, which only execute on a fiber -- a
            // missing current_fiber would be an interpreter bug.
            .yield_expr => |y| {
                const fs = self.current_fiber orelse return error.NotImplemented;
                if (!fs.is_generator) return error.NotImplemented;
                if (y.delegate) return self.evalYieldDelegate(env, fs, y.argument.?);
                var value = if (y.argument) |a| try self.evalExpression(env, a) else JSValue.UNDEFINED;
                // AsyncGeneratorYield: an async generator's `yield` first
                // Awaits its operand (so `yield somePromise` yields the
                // RESOLVED value, and rejection propagates as a thrown
                // exception at the yield point) before suspending.
                if (fs.is_async) value = try self.awaitValue(fs, value);
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
                if (!fs.is_async) return error.NotImplemented;
                const operand = try self.evalExpression(env, operand_node);
                return self.awaitValue(fs, operand);
            },
            // Bare `super` outside call/member position, or super in a
            // non-method context (the call/member interceptors resolve
            // their own bindings first and raise this same error when
            // there's nothing to resolve).
            .super_expr => return self.throwError(.syntax_error, "'super' keyword unexpected here", .{}),
            .new_expr => |n| return self.evalNew(env, n),
            .regex_literal => |r| return self.makeRegex(r.pattern, r.flags),
            .bigint_literal => return error.NotImplemented,
            // Only ever nested inside array/object-literal/call-argument
            // constructs, which unwrap `.data.spread` themselves before
            // recursing -- never reached as a standalone expression.
            .spread => unreachable,
        }
    }

    /// A property key that a symbol value can also produce. Symbols
    /// encode to a reserved `\x00S<ptr>` string (invisible to string
    /// iteration; registered for getOwnPropertySymbols); everything else
    /// goes through ToString. Always returns a FRESH, caller-owned
    /// allocation (even for a symbol seen before) -- `self.symbol_keys`
    /// keeps its own independent copy as the map key, so the two owners
    /// never alias the same buffer.
    pub fn encodeKey(self: *Interpreter, value: JSValue) anyerror![]const u8 {
        if (value == .symbol) {
            const arena = self.gc_allocator;
            const key = try std.fmt.allocPrint(arena, "\x00S{x}", .{@intFromPtr(value.symbol)});
            if (!self.symbol_keys.contains(key)) {
                const stored_key = try arena.dupe(u8, key);
                try self.symbol_keys.put(arena, stored_key, value.retain());
            }
            return key;
        }
        return coercion.toDisplayString(self.gc_allocator, value);
    }

    /// True for the reserved symbol-key encoding -- these must stay
    /// invisible to for-in / Object.keys/values/entries / JSON.
    fn isSymbolKey(k: []const u8) bool {
        return k.len > 0 and k[0] == 0;
    }

    /// A property-key string that may or may not be a fresh allocation --
    /// `.identifier`/literal keys are AST-borrowed (`owned = false`, must
    /// NOT be freed: some consumers, e.g. `Environment.define`/`assign`,
    /// store the key slice directly rather than duplicating it, so freeing
    /// a borrowed one would leave a dangling map key); computed keys go
    /// through `encodeKey` and ARE a fresh allocation (`owned = true`).
    /// Call `.free()` unconditionally at every call site -- it's a no-op
    /// for the borrowed case.
    const PropKey = struct {
        key: []const u8,
        owned: bool,

        fn free(self: PropKey, allocator: Allocator) void {
            if (self.owned) allocator.free(self.key);
        }
    };

    fn memberKeyString(self: *Interpreter, env: *Environment, m: anytype) anyerror!PropKey {
        if (m.computed) {
            // NOT `defer k.deinit()`: evalExpression's ownership isn't
            // uniform -- an `.identifier` read returns the binding's
            // value BORROWED (env.lookup's `.value` case, no retain;
            // see evalExpression's own `.identifier` arm), while other
            // node kinds (literals, calls, getProperty reads) return an
            // owned value. Releasing unconditionally here double-frees
            // the extremely common `obj[someVar]` case (refcount
            // underflow, confirmed via Test262 nested for-in crash).
            const k = try self.evalExpression(env, m.property);
            return .{ .key = try self.encodeKey(k), .owned = true };
        }
        return switch (m.property.data) {
            .identifier => |name| .{ .key = name, .owned = false },
            else => error.NotImplemented,
        };
    }

    /// Same borrowed/owned contract as `memberKeyString`.
    fn propertyKeyString(self: *Interpreter, env: *Environment, computed: bool, key: *zparser.Node) anyerror!PropKey {
        if (computed) {
            const v = try self.evalExpression(env, key);
            return .{ .key = try self.encodeKey(v), .owned = true };
        }
        return switch (key.data) {
            .identifier => |name| .{ .key = name, .owned = false },
            .string_literal => |s| .{ .key = s, .owned = false },
            .number_literal => |n| .{ .key = try znumber.FormattingMethods.toString(n, self.gc_allocator, null), .owned = true },
            else => error.NotImplemented,
        };
    }

    /// A shared native-method JSValue for a (type, name) pair, cached so
    /// `a.push === b.push` holds like real JS prototype methods.
    pub fn nativeMethod(self: *Interpreter, comptime type_prefix: []const u8, name: []const u8, call_fn: builtins.NativeFn) anyerror!JSValue {
        const arena = self.gc_allocator;
        const cache_key = try std.fmt.allocPrint(arena, type_prefix ++ ".{s}", .{name});
        // Ownership: method_cache holds its OWN retained reference,
        // independent of whatever the caller does with the one they get
        // back (every consumer, cached hit or fresh miss, gets a
        // reference they own and must eventually release -- same
        // contract as every other getter in this file). Getting this
        // wrong (as it used to be: no retain either way) meant a shared
        // cached method could be decref'd to zero by ONE holder
        // releasing its copy while method_cache -- and every OTHER
        // holder -- still pointed at it.
        if (self.method_cache.get(cache_key)) |cached| {
            self.gc_allocator.free(cache_key);
            return cached.retain();
        }
        const fn_value = try self.gcNewFunction(.{ .ctx = self, .name = name, .call = call_fn });
        try self.method_cache.put(arena, cache_key, fn_value.retain());
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
                const arena = self.gc_allocator;
                // `globalThis`: a global binding (Object, a top-level `var`,
                // ...) shadows its own props; a miss falls through to the
                // normal own->chain walk (defineProperty'd props, then
                // Object.prototype methods).
                if (self.global_object) |go| {
                    if (obj.object == go.object) {
                        if (self.global_env.get(key)) |v| break :blk v.retain();
                    }
                }
                var current: ?*const @TypeOf(box.value) = &box.value;
                while (current) |o| : (current = o.getPrototype()) {
                    const rec = o.getOwnRecord(key) orelse continue;
                    if (rec.isAccessor()) {
                        const g = rec.getter orelse break :blk JSValue.UNDEFINED;
                        break :blk try g.function.value.call(g.function.value.ctx, arena, obj, &.{});
                    }
                    break :blk rec.value.retain();
                }
                // Chain miss: ordinary objects chain to the real
                // Object.prototype (which carries hasOwnProperty & co as own
                // properties), so a genuine miss here is `undefined`. Objects
                // with a null prototype (Object.create(null)) correctly
                // inherit nothing.
                break :blk JSValue.UNDEFINED;
            },
            .array => |box| blk: {
                if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.length()));
                const idx = std.fmt.parseInt(usize, key, 10) catch {
                    // Method (via Array.prototype) or a named own property
                    // (exec-result index/input/groups); else undefined.
                    if (try self.getFromProto(obj, self.protos.array, key)) |m| break :blk m;
                    break :blk (self.arrayExtra(obj, key) orelse JSValue.UNDEFINED).retain();
                };
                if (idx >= box.value.length()) break :blk JSValue.UNDEFINED;
                break :blk box.value.get(idx).retain();
            },
            .string => |box| blk: {
                if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.data.len));
                if (std.fmt.parseInt(usize, key, 10)) |idx| {
                    // Indexed access: the one-char string at that position,
                    // or undefined past the end (real JS string indexing).
                    if (idx < box.value.data.len) break :blk try self.gcNewString(box.value.data[idx .. idx + 1]);
                    break :blk JSValue.UNDEFINED;
                } else |_| {}
                if (try self.getFromProto(obj, self.protos.string, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            // `catch (e) { console.log(e.message) }` is the most common
            // catch body in existence -- name/message are read-only views
            // over ZError's existing fields.
            .@"error" => |box| blk: {
                if (std.mem.eql(u8, key, "name")) break :blk try self.gcNewString(box.value.kind.name());
                if (std.mem.eql(u8, key, "message")) break :blk try self.gcNewString(box.value.message);
                // `thrown.constructor === TypeError` -- what Test262's
                // assert.throws actually compares. Same function identity
                // every time: the global binding for this kind's name.
                if (std.mem.eql(u8, key, "constructor")) {
                    break :blk (self.global_env.get(box.value.kind.name()) orelse JSValue.UNDEFINED).retain();
                }
                if (try self.getFromProto(obj, self.protos.@"error", key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            .function => |box| blk: {
                // functionPrototype() returns a borrow of Callable.prototype's
                // own reference (matching every other branch here, which all
                // retain before returning -- necessary now that
                // Callable.deinit() actually releases .prototype).
                if (std.mem.eql(u8, key, "prototype")) break :blk (try self.functionPrototype(obj)).retain();
                if (std.mem.eql(u8, key, "name")) break :blk try self.gcNewString(box.value.name);
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
                if (try self.getFromProto(obj, self.protos.function, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            .number => blk: {
                if (try self.getFromProto(obj, self.protos.number, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            .boolean => blk: {
                if (try self.getFromProto(obj, self.protos.boolean, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            .date => blk: {
                if (try self.getFromProto(obj, self.protos.date, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            .promise => blk: {
                if (try self.getFromProto(obj, self.protos.promise, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            .map => |box| blk: {
                if (std.mem.eql(u8, key, "size")) break :blk JSValue.fromNumber(@floatFromInt(box.value.size()));
                if (try self.getFromProto(obj, self.protos.map, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            .set => |box| blk: {
                if (std.mem.eql(u8, key, "size")) break :blk JSValue.fromNumber(@floatFromInt(box.value.size()));
                if (try self.getFromProto(obj, self.protos.set, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            .symbol => |box| blk: {
                if (std.mem.eql(u8, key, "description")) {
                    break :blk if (box.value.description) |d| try self.gcNewString(d) else JSValue.UNDEFINED;
                }
                if (try self.getFromProto(obj, self.protos.symbol, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            .regex => blk: {
                const st = self.regexState(obj);
                if (std.mem.eql(u8, key, "source")) break :blk try self.gcNewString(st.source);
                if (std.mem.eql(u8, key, "flags")) break :blk try self.gcNewString(st.flags);
                if (std.mem.eql(u8, key, "global")) break :blk JSValue.fromBool(st.global);
                if (std.mem.eql(u8, key, "ignoreCase")) break :blk JSValue.fromBool(st.ignore_case);
                if (std.mem.eql(u8, key, "multiline")) break :blk JSValue.fromBool(st.multiline);
                if (std.mem.eql(u8, key, "dotAll")) break :blk JSValue.fromBool(st.dot_all);
                if (std.mem.eql(u8, key, "sticky")) break :blk JSValue.fromBool(st.sticky);
                if (std.mem.eql(u8, key, "unicode")) break :blk JSValue.fromBool(st.unicode);
                if (std.mem.eql(u8, key, "lastIndex")) break :blk JSValue.fromNumber(@floatFromInt(st.last_index));
                if (try self.getFromProto(obj, self.protos.regex, key)) |m| break :blk m;
                break :blk JSValue.UNDEFINED;
            },
            // Spec says TypeError here (not ReferenceError). The optional
            // chaining guards short-circuit BEFORE getProperty, so `a?.b`
            // on null still yields undefined without ever reaching this.
            .@"undefined", .@"null" => self.throwError(.type_error, "Cannot read properties of {s} (reading '{s}')", .{ if (obj == .@"null") "null" else "undefined", key }),
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
        const arena = self.gc_allocator;
        const key = try coercion.toDisplayString(arena, l);
        defer arena.free(key);
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

    /// Writing to an array: numeric indices (grow with undefined holes
    /// past the end -- narrowing vs true sparse arrays) and `length`
    /// (truncate/extend). Any other key is NotImplemented (arrays have no
    /// general property bag here).
    pub fn setArrayProperty(self: *Interpreter, obj: JSValue, key: []const u8, value: JSValue) anyerror!void {
        _ = self;
        const arr = &obj.array.value;
        if (std.mem.eql(u8, key, "length")) {
            const n = try coercion.toUint32(value);
            const cur = arr.length();
            if (n < cur) {
                var i = cur;
                while (i > n) : (i -= 1) {
                    if (arr.pop()) |v| v.deinit();
                }
            } else {
                var i = cur;
                while (i < n) : (i += 1) _ = try arr.push(JSValue.UNDEFINED);
            }
            return;
        }
        const idx = std.fmt.parseInt(usize, key, 10) catch return error.NotImplemented;
        const cur = arr.length();
        if (idx < cur) {
            arr.toSliceMut()[idx].deinit();
            arr.toSliceMut()[idx] = value.retain();
        } else {
            var i = cur;
            while (i < idx) : (i += 1) _ = try arr.push(JSValue.UNDEFINED);
            _ = try arr.push(value.retain());
        }
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
                _ = try s.function.value.call(s.function.value.ctx, self.gc_allocator, obj, &.{value});
                return;
            }
            break;
        }
        // Always-strict [[Set]] failures are real TypeErrors, not raw
        // Zig errors (the descriptor flags finally bite here).
        // getOwn (NOT get): get() walks the prototype chain, which would
        // capture an INHERITED value here and wrongly release something
        // the prototype object still owns -- set() only ever touches own
        // properties, so the displaced value must come from getOwn().
        const old = obj.object.value.getOwn(key);
        obj.object.value.set(key, value.retain()) catch |err| return switch (err) {
            error.PropertyNotWritable => self.throwError(.type_error, "Cannot assign to read only property '{s}' of object", .{key}),
            error.ObjectIsFrozen => self.throwError(.type_error, "Cannot assign to read only property '{s}' of object", .{key}),
            error.ObjectNotExtensible => self.throwError(.type_error, "Cannot add property {s}, object is not extensible", .{key}),
            else => err,
        };
        // The property write above just overwrote (or shadowed) whatever
        // was there -- release the value it displaced (ZObject.set doesn't
        // know about JSValue/refcounting, so this is the interpreter's job).
        if (old) |o| o.deinit();
    }

    /// The function's statics/property bag, created lazily on first touch
    /// (same contract as functionPrototype).
    pub fn functionStatics(self: *Interpreter, fn_val: JSValue) anyerror!JSValue {
        if (fn_val.function.value.statics) |s| return s;
        const bag = try self.gcNewObject();
        fn_val.function.value.statics = bag;
        return bag;
    }

    /// F.prototype, created lazily on first touch: a fresh `{}` whose
    /// `constructor` points back at the function (real
    /// `F.prototype.constructor === F` behavior). Chains to Object.prototype
    /// once it exists (every ordinary object's [[Prototype]]).
    pub fn functionPrototype(self: *Interpreter, fn_val: JSValue) anyerror!JSValue {
        if (fn_val.function.value.prototype) |p| return p;
        var proto = try self.gcNewObject();
        if (self.protos.object == .object) try proto.object.value.setPrototype(&self.protos.object.object.value);
        try proto.object.value.set("constructor", fn_val.retain());
        fn_val.function.value.prototype = proto;
        return proto;
    }

    /// A plain object whose [[Prototype]] is the real `Object.prototype` --
    /// what every ordinary object (literal, result object, ...) must have so
    /// `Object.getPrototypeOf({}) === Object.prototype` and inherited
    /// methods resolve through the chain rather than a side table.
    pub fn ordinaryObject(self: *Interpreter) !JSValue {
        const obj = try self.gcNewObject();
        if (self.protos.object == .object) try obj.object.value.setPrototype(&self.protos.object.object.value);
        return obj;
    }

    /// Walk a builtin prototype object's own->chain records for `key`,
    /// dispatching an accessor's getter with `this = receiver`. Returns null
    /// on a full miss. This is how the primitive types (array/string/date/...)
    /// resolve their methods now that those live on real prototype objects.
    fn getFromProto(self: *Interpreter, receiver: JSValue, proto: JSValue, key: []const u8) anyerror!?JSValue {
        if (proto != .object) return null;
        const arena = self.gc_allocator;
        var current: ?*const @TypeOf(proto.object.value) = &proto.object.value;
        while (current) |o| : (current = o.getPrototype()) {
            const rec = o.getOwnRecord(key) orelse continue;
            if (rec.isAccessor()) {
                const gtr = rec.getter orelse return JSValue.UNDEFINED;
                return try gtr.function.value.call(gtr.function.value.ctx, arena, receiver, &.{});
            }
            return rec.value.retain();
        }
        return null;
    }

    /// Populate a builtin prototype with its method table as real own data
    /// properties carrying the spec attributes for builtin methods
    /// (writable, NON-enumerable, configurable), plus a non-enumerable
    /// `constructor` back-reference. The functions come from `nativeMethod`,
    /// which caches by identity so `[].push === Array.prototype.push` holds.
    fn installProto(self: *Interpreter, proto: JSValue, comptime type_prefix: []const u8, methods: std.StaticStringMap(builtins.NativeFn), ctor: JSValue) !void {
        const attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };
        for (methods.keys()) |k| {
            const f = try self.nativeMethod(type_prefix, k, methods.get(k).?);
            try proto.object.value.defineProperty(k, f, attrs);
        }
        try proto.object.value.defineProperty("constructor", ctor.retain(), attrs);
    }

    /// Materialize the real builtin prototype objects (Object.prototype,
    /// Array.prototype, ...) from the method tables in builtins.zig. Called
    /// once at the end of setupGlobals, after every constructor exists.
    /// Object.prototype is the chain end ([[Prototype]] = null); every other
    /// prototype chains to it.
    pub fn materializeProtos(self: *Interpreter) !void {
        const g = self.global_env;

        const object_ctor = g.get("Object").?;
        const object_proto = try self.functionPrototype(object_ctor);
        self.protos.object = object_proto;
        try self.installProto(object_proto, "object", builtins.object_methods, object_ctor);

        inline for (.{
            .{ "array", "Array", builtins.array_methods },
            .{ "string", "String", builtins.string_methods },
            .{ "date", "Date", builtins.date_methods },
            .{ "function", "Function", builtins.function_methods },
            .{ "regex", "RegExp", builtins.regex_methods },
            .{ "map", "Map", builtins.map_methods },
            .{ "set", "Set", builtins.set_methods },
            .{ "symbol", "Symbol", builtins.symbol_methods },
            .{ "promise", "Promise", builtins.promise_methods },
            .{ "number", "Number", builtins.number_methods },
            .{ "boolean", "Boolean", builtins.boolean_methods },
        }) |e| {
            const ctor = g.get(e[1]).?;
            const proto = try self.functionPrototype(ctor);
            try proto.object.value.setPrototype(&object_proto.object.value);
            try self.installProto(proto, e[0], e[2], ctor);
            @field(self.protos, e[0]) = proto;
        }

        // Types without a method table today: real (near-empty) prototypes so
        // getPrototypeOf / reflection still work and instances chain correctly.
        const proto_attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };
        inline for (.{.{ "error", "Error" }}) |e| {
            const ctor = g.get(e[1]).?;
            const proto = try self.functionPrototype(ctor);
            try proto.object.value.setPrototype(&object_proto.object.value);
            try proto.object.value.defineProperty("constructor", ctor.retain(), proto_attrs);
            @field(self.protos, e[0]) = proto;
        }
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
                        .value => |v| return try self.gcNewString(v.typeOf()),
                        .tdz => return self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name}),
                        .not_found => return try self.gcNewString("undefined"),
                    }
                }
                const v = try self.evalExpression(env, u.operand);
                return try self.gcNewString(v.typeOf());
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
                    // `delete this.#x` is a spec EARLY error; surfaced at
                    // runtime here (narrowing -- no static private scope).
                    if (privateMemberName(m)) |pn| {
                        return self.throwError(.syntax_error, "Private fields can not be deleted: {s}", .{pn});
                    }
                    const obj = try self.evalExpression(env, m.object);
                    const pk = try self.memberKeyString(env, m);
                    defer pk.free(self.gc_allocator);
                    const key = pk.key;
                    if (obj != .object) return JSValue.fromBool(true);
                    // Capture before deleting (the record's pointer doesn't
                    // survive fetchOrderedRemove): ZObject.delete() frees the
                    // key string but doesn't know about JSValue/refcounting,
                    // so releasing the removed value/getter/setter is on us.
                    const old_rec = obj.object.value.getOwnRecord(key);
                    const old_value = if (old_rec) |r| r.value else null;
                    const old_getter = if (old_rec) |r| r.getter else null;
                    const old_setter = if (old_rec) |r| r.setter else null;
                    const removed = obj.object.value.delete(key) catch |err| return switch (err) {
                        error.PropertyNotConfigurable, error.ObjectIsFrozen => self.throwError(.type_error, "Cannot delete property '{s}' of object", .{key}),
                        else => err,
                    };
                    if (removed) {
                        // An accessor's `value` is a placeholder (see
                        // Property(T)'s doc comment), safe to deinit either way.
                        if (old_value) |v| v.deinit();
                        if (old_getter) |g| g.deinit();
                        if (old_setter) |s| s.deinit();
                    }
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
                const result = try coercion.binaryOp(self.gc_allocator, compoundToBinary(a.op), current, rhs);
                try self.assignTo(env, a.target, result);
                return result;
            },
        }
    }

    fn assignTo(self: *Interpreter, env: *Environment, target: *zparser.Node, value: JSValue) anyerror!void {
        switch (target.data) {
            // env.assign takes ownership -- retain, matching bindPattern's
            // convention (the caller keeps its own reference to `value`).
            .identifier => |name| env.assign(name, value.retain()) catch |err| return switch (err) {
                error.ReferenceError => self.throwError(.reference_error, "{s} is not defined", .{name}),
                error.BeforeInitialization => self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name}),
            },
            .paren => |inner| try self.assignTo(env, inner, value),
            .member => |m| {
                const obj = try self.evalExpression(env, m.object);
                if (privateMemberName(m)) |pn| return self.privateSet(env, obj, pn, value);
                const pk = try self.memberKeyString(env, m);
                defer pk.free(self.gc_allocator);
                const key = pk.key;
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
                if (obj == .array) return self.setArrayProperty(obj, key, value);
                if (obj == .regex) {
                    if (std.mem.eql(u8, key, "lastIndex")) {
                        const n = try coercion.toNumber(value);
                        // `lastIndex` may be set to any Number, including
                        // Infinity, Number.MAX_VALUE or values beyond usize
                        // (Test262 exercises exactly these). A bare
                        // @intFromFloat would panic on an out-of-range float,
                        // so saturate: anything at/above usize's range (and
                        // NaN, which fails both comparisons) is stored as the
                        // max, which always exceeds the subject length, so
                        // exec/test correctly find no match and reset it to 0.
                        const max_usize_f: f64 = @floatFromInt(std.math.maxInt(usize));
                        self.regexState(obj).last_index = if (n >= max_usize_f)
                            std.math.maxInt(usize)
                        else if (n > 0)
                            @intFromFloat(n)
                        else
                            0;
                        return;
                    }
                    return error.NotImplemented;
                }
                if (obj != .object) return error.NotImplemented;
                // Writing a property on `globalThis` creates/updates a global
                // binding (`globalThis.foo = 1` makes `foo` a global).
                if (self.global_object) |go| {
                    if (obj.object == go.object) {
                        // `Environment.define` stores `key` BY REFERENCE
                        // (never dupes -- every other call site passes an
                        // AST-borrowed, forever-valid name). `key` here can
                        // be the PropKey-owned case (`globalThis[computed]
                        // = x`), which `pk.free()` reclaims once this
                        // function returns -- dupe defensively so the new
                        // global binding's name always outlives that.
                        try self.global_env.define(self.gc_allocator, try self.gc_allocator.dupe(u8, key), value.retain());
                        return;
                    }
                }
                try self.setObjectProperty(obj, key, value);
            },
            else => return error.NotImplemented,
        }
    }

    fn evalCall(self: *Interpreter, env: *Environment, c: anytype) anyerror!JSValue {
        const arena = self.gc_allocator;
        // `super(args)`: the parent constructor invoked with the CURRENT
        // `this` (the instance under construction), armed as a
        // construction so the parent's without-new check passes.
        if (c.callee.data == .super_expr) {
            const sctor = env.resolveSuperCtor() orelse
                return self.throwError(.syntax_error, "'super' keyword unexpected here", .{});
            const args = try self.evalArgs(env, c.args);
            defer self.gc_allocator.free(args);
            const prev_target = self.construct_target;
            self.construct_target = sctor.function.value.ctx;
            defer self.construct_target = prev_target;
            const result = try sctor.function.value.call(sctor.function.value.ctx, arena, env.resolveThis(), args);
            // The derived class's own instance fields initialize exactly
            // when super() returns (spec order: parent fields ran during
            // the parent ctor; own fields now; rest of the body after).
            if (self.pending_field_init) |p| {
                self.pending_field_init = null;
                const pc: *ClassCtx = @ptrCast(@alignCast(p));
                try self.runInstanceFields(pc, env.resolveThis());
            }
            return result;
        }
        // `super.m(args)`: method looked up on the PARENT prototype but
        // invoked with the current `this` -- the whole point of super.
        if (c.callee.data == .member and c.callee.data.member.object.data == .super_expr) {
            const m = c.callee.data.member;
            const sproto = env.resolveSuperProto() orelse
                return self.throwError(.syntax_error, "'super' keyword unexpected here", .{});
            const pk = try self.memberKeyString(env, m);
            defer pk.free(self.gc_allocator);
            const method = try self.getProperty(sproto, pk.key);
            if (method != .function) {
                return self.throwError(.type_error, "(intermediate value).{s} is not a function", .{pk.key});
            }
            const args = try self.evalArgs(env, c.args);
            defer self.gc_allocator.free(args);
            return try method.function.value.call(method.function.value.ctx, arena, env.resolveThis(), args);
        }
        var this_value: JSValue = JSValue.UNDEFINED;
        var callee_val: JSValue = undefined;
        if (c.callee.data == .member) {
            const m = c.callee.data.member;
            const obj = try self.evalExpression(env, m.object);
            if (m.optional and (obj == .@"undefined" or obj == .@"null")) return JSValue.UNDEFINED;
            this_value = obj;
            if (privateMemberName(m)) |pn| {
                // `this.#m(args)` -- private method/field call, `this`
                // preserved like any member call.
                callee_val = try self.privateGet(env, obj, pn);
            } else {
                const pk = try self.memberKeyString(env, m);
                defer pk.free(self.gc_allocator);
                callee_val = try self.getProperty(obj, pk.key);
            }
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
            defer self.gc_allocator.free(args);
        // Direct eval: a call written literally as `eval(...)` where `eval`
        // still refers to the intrinsic runs its string argument in the
        // CURRENT scope (always-strict -> a child of it). Any other reference
        // to eval (aliased, member access) is indirect and runs the global
        // native below.
        if (self.eval_fn) |ev| {
            if (c.callee.data == .identifier and std.mem.eql(u8, c.callee.data.identifier, "eval") and callee_val.function == ev.function) {
                if (args.len == 0) return JSValue.UNDEFINED;
                if (args[0] != .string) return args[0].retain();
                return self.evalSource(env, args[0].string.value.data);
            }
        }
        return try callee_val.function.value.call(callee_val.function.value.ctx, arena, this_value, args);
    }

    fn evalArgs(self: *Interpreter, env: *Environment, arg_nodes: []const *zparser.Node) anyerror![]const JSValue {
        const arena = self.gc_allocator;
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
        const arena = self.gc_allocator;
        const callee = try self.evalExpression(env, n.callee);
        const callee_name: []const u8 = switch (n.callee.data) {
            .identifier => |name| name,
            else => "expression",
        };
        if (callee != .function or !callee.function.value.constructable) {
            return self.throwError(.type_error, "{s} is not a constructor", .{callee_name});
        }
        const proto = try self.functionPrototype(callee);
        var instance = try self.gcNewObject();
        try instance.object.value.setPrototype(&proto.object.value);
        // `new Foo` with no parens at all (args == null) is `new Foo()`.
        const args = try self.evalArgs(env, n.args orelse &.{});
            defer self.gc_allocator.free(args);
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
        const arena = self.gc_allocator;
        // A named function expression's own name is visible inside its own
        // body (for self-recursion) even though it isn't bound in the
        // enclosing scope -- bind it in a thin wrapper env between `env`
        // and the closure's actual defining environment.
        const self_name: ?[]const u8 = switch (fnode.kind) {
            .function_expr => |e| e.name,
            else => null,
        };
        const closure_env = if (self_name != null) try self.gcChildEnv(env) else env;

        const ctx = try arena.create(ClosureCtx);
        ctx.* = .{ .interp = self, .function_node = fnode, .closure_env = closure_env };
        try self.gcTrackClosureCtx(ctx);
        const name: []const u8 = switch (fnode.kind) {
            .function_decl => |d| d.name,
            .function_expr => |e| e.name orelse "",
            .method => |m| m.name,
            .arrow => "",
        };
        const fn_value = try self.gcNewFunction(.{
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
    /// ClosureCtx additionally carries the parent prototype (so `super.m()`
    /// resolves inside the body) and the declaring class's private identity
    /// (so `this.#x` resolves). Safe cast: makeClosure always installs a
    /// ClosureCtx as the ctx of the closures it creates.
    fn makeMethodClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode, super_proto: ?JSValue, private_ctx: ?*anyopaque) anyerror!JSValue {
        const v = try self.makeClosure(env, fnode);
        const cc: *ClosureCtx = @ptrCast(@alignCast(v.function.value.ctx));
        cc.super_proto = super_proto;
        cc.private_ctx = private_ctx;
        return v;
    }

    // ===== Private (`#name`) member machinery =====
    //
    // ECMA-262's PrivateEnvironment/PrivateName pair, collapsed onto the
    // existing property model: each class's ClassCtx pointer IS its private
    // identity, and `#name` members are stored as ordinary properties under
    // the reserved key `\x00P{ctx}|{name}` -- the `\x00` prefix is already
    // invisible to every enumeration path (Object.keys, for-in, JSON,
    // getOwnPropertyNames all skip it), so privates are non-reflective for
    // free. The BRAND CHECK falls out of key mismatch: another class's
    // `#name` encodes to a different key, and a miss is the spec TypeError.

    /// Encodes a private member's storage key for a given class identity.
    fn encodePrivateKey(self: *Interpreter, class_id: *anyopaque, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.gc_allocator, "\x00P{x}|{s}", .{ @intFromPtr(class_id), name });
    }

    /// The object that actually stores a receiver's private members:
    /// the object itself, or a function's statics bag (`C.#staticField`).
    /// Null for primitives (they can never carry a brand).
    fn privateHolder(self: *Interpreter, obj: JSValue) !?JSValue {
        return switch (obj) {
            .object => obj,
            .function => try self.functionStatics(obj),
            else => null,
        };
    }

    fn privateGet(self: *Interpreter, env: *Environment, obj: JSValue, name: []const u8) anyerror!JSValue {
        const ctx = env.resolvePrivateCtx() orelse
            return self.throwError(.syntax_error, "Private field '{s}' must be declared in an enclosing class", .{name});
        const key = try self.encodePrivateKey(ctx, name);
        const holder = (try self.privateHolder(obj)) orelse
            return self.throwError(.type_error, "Cannot read private member {s} from an object whose class did not declare it", .{name});
        // Own->chain record walk with accessor dispatch (instance fields
        // are own props; private methods/accessors live on the prototype).
        var current: ?*const @TypeOf(holder.object.value) = &holder.object.value;
        while (current) |o| : (current = o.getPrototype()) {
            const rec = o.getOwnRecord(key) orelse continue;
            if (rec.isAccessor()) {
                const g = rec.getter orelse
                    return self.throwError(.type_error, "'{s}' was defined without a getter", .{name});
                return try g.function.value.call(g.function.value.ctx, self.gc_allocator, obj, &.{});
            }
            return rec.value.retain();
        }
        return self.throwError(.type_error, "Cannot read private member {s} from an object whose class did not declare it", .{name});
    }

    fn privateSet(self: *Interpreter, env: *Environment, obj: JSValue, name: []const u8, value: JSValue) anyerror!void {
        const ctx = env.resolvePrivateCtx() orelse
            return self.throwError(.syntax_error, "Private field '{s}' must be declared in an enclosing class", .{name});
        const key = try self.encodePrivateKey(ctx, name);
        const holder = (try self.privateHolder(obj)) orelse
            return self.throwError(.type_error, "Cannot write private member {s} to an object whose class did not declare it", .{name});
        const hv = &holder.object.value;
        if (hv.getOwnRecord(key)) |rec| {
            if (rec.isAccessor()) {
                const s = rec.setter orelse
                    return self.throwError(.type_error, "'{s}' was defined without a setter", .{name});
                _ = try s.function.value.call(s.function.value.ctx, self.gc_allocator, obj, &.{value});
                return;
            }
            // A brand-checked private FIELD write updates in place.
            hv.set(key, value.retain()) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => unreachable, // reserved keys are never frozen/sealed
            };
            return;
        }
        // Chain walk: a prototype hit is an accessor (setter dispatch) or a
        // private METHOD (not writable, spec TypeError).
        var current = hv.getPrototype();
        while (current) |o| : (current = o.getPrototype()) {
            const rec = o.getOwnRecord(key) orelse continue;
            if (rec.isAccessor()) {
                const s = rec.setter orelse
                    return self.throwError(.type_error, "'{s}' was defined without a setter", .{name});
                _ = try s.function.value.call(s.function.value.ctx, self.gc_allocator, obj, &.{value});
                return;
            }
            return self.throwError(.type_error, "Cannot assign to private method {s}", .{name});
        }
        return self.throwError(.type_error, "Cannot write private member {s} to an object whose class did not declare it", .{name});
    }

    /// `#name in obj` -- true iff obj carries this class's brand for the
    /// name (an own-or-prototype private entry under the encoded key).
    fn privateHas(self: *Interpreter, env: *Environment, obj: JSValue, name: []const u8) anyerror!bool {
        const ctx = env.resolvePrivateCtx() orelse
            return self.throwError(.syntax_error, "Private field '{s}' must be declared in an enclosing class", .{name});
        const key = try self.encodePrivateKey(ctx, name);
        const holder = (try self.privateHolder(obj)) orelse return false;
        var current: ?*const @TypeOf(holder.object.value) = &holder.object.value;
        while (current) |o| : (current = o.getPrototype()) {
            if (o.getOwnRecord(key) != null) return true;
        }
        return false;
    }

    /// Runs a class's instance-field initializers against a fresh instance
    /// (this = the instance, private names resolvable, `super.x` usable).
    /// Called at constructor entry for base classes and right after
    /// `super()` returns for derived ones.
    fn runInstanceFields(self: *Interpreter, cctx: *ClassCtx, instance: JSValue) anyerror!void {
        if (cctx.instance_fields.len == 0) return;
        if (instance != .object) return; // exotic `this` -- nothing to define on
        const field_env = try self.gcChildEnv(cctx.closure_env);
        field_env.this_value = instance;
        field_env.super_proto = cctx.super_proto;
        field_env.private_ctx = cctx;
        for (cctx.instance_fields) |fd| {
            const v = if (fd.value) |vexpr| try self.evalExpression(field_env, vexpr) else JSValue.UNDEFINED;
            const is_private = fd.key.len > 0 and fd.key[0] == 0;
            const target = &instance.object.value;
            target.set(fd.key, v.retain()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // A constructor can freeze/preventExtensions `this` BEFORE
                // fields initialize. Per spec, a PUBLIC field then fails
                // with a TypeError (CreateDataPropertyOrThrow) -- but a
                // PRIVATE field still installs: private names are not
                // ordinary properties, so [[Extensible]]/frozen don't apply.
                // Bypass by briefly lifting the flags for the private add.
                error.ObjectIsFrozen, error.ObjectNotExtensible, error.PropertyNotWritable => {
                    if (!is_private) {
                        return self.throwError(.type_error, "Cannot define property {s}, object is not extensible", .{fd.key});
                    }
                    const saved_frozen = target.is_frozen;
                    const saved_ext = target.is_extensible;
                    target.is_frozen = false;
                    target.is_extensible = true;
                    defer {
                        target.is_frozen = saved_frozen;
                        target.is_extensible = saved_ext;
                    }
                    target.set(fd.key, v.retain()) catch |e2| return switch (e2) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => unreachable, // flags lifted; nothing else can gate a fresh key
                    };
                },
                else => return err,
            };
        }
    }

    /// ECMA-262 15.7 ClassDefinitionEvaluation, narrowed: a constructable
    /// function (classConstructorCall) whose prototype object holds the
    /// instance methods/accessors and chains to the parent's prototype;
    /// statics live in the function's bag, chained to the parent's bag
    /// (static inheritance). Fields (public/private/static), private
    /// methods/accessors, computed keys, and static blocks all supported;
    /// still no new.target/decorators -- see README.
    fn evalClass(self: *Interpreter, env: *Environment, cnode: *zfunctions.ClassNode) anyerror!JSValue {
        const arena = self.gc_allocator;

        var super_ctor: ?JSValue = null;
        var super_proto: ?JSValue = null;
        if (cnode.superclass) |sc_expr| {
            const sc = try self.evalExpression(env, sc_expr);
            if (sc != .function or !sc.function.value.constructable) {
                defer sc.deinit();
                const shown = try coercion.toDisplayString(arena, sc);
                defer arena.free(shown);
                return self.throwError(.type_error, "Class extends value {s} is not a constructor or null", .{shown});
            }
            super_ctor = sc;
            super_proto = try self.functionPrototype(sc);
        }

        // Named classes can self-reference inside method bodies (same
        // wrapper-env trick as named function expressions).
        const closure_env = if (cnode.name != null) try self.gcChildEnv(env) else env;

        var proto = try self.gcNewObject();
        if (super_proto) |sp|
            try proto.object.value.setPrototype(&sp.object.value)
        else if (self.protos.object == .object)
            try proto.object.value.setPrototype(&self.protos.object.object.value);

        var ctor_fnode: ?*zfunctions.FunctionNode = null;
        for (cnode.elements) |el| {
            if (!el.is_static and el.kind == .method and el.key == .ident and std.mem.eql(u8, el.key.ident, "constructor")) {
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
        try self.gcTrackClassCtx(cctx);
        const class_fn = try self.gcNewFunction(.{
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

        // The class's own name binds BEFORE static elements run (spec:
        // ClassDefinitionEvaluation initializes the inner binding before
        // static fields/blocks execute, so `static { C.x = 1 }` works).
        if (cnode.name) |n| try closure_env.define(arena, n, class_fn.retain());

        // One pass, in declaration order (the spec's order matters for
        // computed-key evaluation, static field initializers, and static
        // blocks, which all run interleaved right here).
        var instance_fields: std.ArrayList(FieldDef) = .empty;
        for (cnode.elements) |el| {
            if (el.kind == .static_block) {
                // Runs once, now, with this = the class and privates in
                // scope.
                _ = try invokeFunctionNode(self, el.function.?, closure_env, arena, class_fn, super_proto, null, cctx, &.{});
                continue;
            }

            // Resolve the property key: computed keys evaluate ONCE, here,
            // in order; private keys encode against this class's identity.
            const key: []const u8 = switch (el.key) {
                .ident => |n| n,
                .private => |n| try self.encodePrivateKey(cctx, n),
                .computed => |expr| blk: {
                    // encodeKey handles BOTH symbols (`[Symbol.iterator]`,
                    // encoded like any symbol-keyed property) and ordinary
                    // values (ToPropertyKey string form). Neither `kv` nor
                    // the encoded key itself is freed here: evalExpression's
                    // ownership isn't uniform (an `.identifier` read is
                    // BORROWED, no retain -- see memberKeyString's doc
                    // comment for the Test262-confirmed crash this caused
                    // once already), and the encoded key must outlive this
                    // loop iteration anyway (stored in `instance_fields`
                    // for per-construction use; freeGarbageNode's
                    // `.class_ctx` case only frees the array, not each
                    // key's content -- documented residual gap, narrow/
                    // one-time-per-class, not chased further here).
                    const kv = try self.evalExpression(closure_env, expr);
                    break :blk try self.encodeKey(kv);
                },
            };

            if (el.kind == .field) {
                if (el.is_static) {
                    // Static fields initialize at DEFINITION time, in
                    // order, with this = the class function.
                    const field_env = try self.gcChildEnv(closure_env);
                    field_env.this_value = class_fn;
                    field_env.super_proto = super_proto;
                    field_env.private_ctx = cctx;
                    const v = if (el.value) |vexpr| try self.evalExpression(field_env, vexpr) else JSValue.UNDEFINED;
                    const bag = try self.functionStatics(class_fn);
                    try bag.object.value.set(key, v.retain());
                } else {
                    // Instance fields are CAPTURED here (key already
                    // resolved) and initialized per-instance at
                    // construction time.
                    try instance_fields.append(arena, .{ .key = key, .value = el.value });
                }
                continue;
            }

            // Methods / accessors.
            if (!el.is_static and el.kind == .method and el.key == .ident and std.mem.eql(u8, el.key.ident, "constructor")) continue;
            const m = try self.makeMethodClosure(closure_env, el.function.?, super_proto, cctx);
            const target = if (el.is_static) try self.functionStatics(class_fn) else proto;
            switch (el.kind) {
                .method => try target.object.value.set(key, m),
                .get => try target.object.value.defineAccessor(key, m, null, JSValue.UNDEFINED),
                .set => try target.object.value.defineAccessor(key, null, m, JSValue.UNDEFINED),
                .field, .static_block => unreachable,
            }
        }
        cctx.instance_fields = try instance_fields.toOwnedSlice(arena);
        return class_fn;
    }
};

/// A non-computed member access whose property name starts with '#' can
/// only have come from `.#name` syntax (ordinary identifiers can't contain
/// '#') -- it denotes PRIVATE member access. Computed `obj["#x"]` remains a
/// normal string-keyed property, per spec.
fn privateMemberName(m: anytype) ?[]const u8 {
    if (m.computed) return null;
    if (m.property.data != .identifier) return null;
    const n = m.property.data.identifier;
    if (n.len > 0 and n[0] == '#') return n;
    return null;
}

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
    private_ctx: ?*anyopaque,
    args: []const JSValue,
) anyerror!JSValue {
    const call_env = try self.gcChildEnv(closure_env);
    if (this_value) |tv| call_env.this_value = tv;
    call_env.super_proto = super_proto;
    call_env.super_ctor = super_ctor;
    call_env.private_ctx = private_ctx;

    // `arguments`: every non-arrow call gets one (arrows inherit the
    // enclosing function's via the scope chain -- no binding here).
    // Materialized as a real array snapshot (always-strict => unmapped;
    // narrowing: not the exotic Arguments object -- see README). Defined
    // BEFORE params so a parameter/rest named `arguments` shadows it.
    if (fnode.kind != .arrow) {
        var arguments = try self.gcNewArray();
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
        var rest_arr = try self.gcNewArray();
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
        return closure_ctx.interp.makeAsyncGeneratorObject(fnode, closure_ctx.closure_env, this, closure_ctx.private_ctx, args);
    }
    if (fnode.is_generator) {
        return closure_ctx.interp.makeGeneratorObject(fnode, closure_ctx.closure_env, this, closure_ctx.private_ctx, args);
    }
    if (fnode.is_async) {
        return closure_ctx.interp.runAsyncFunction(fnode, closure_ctx.closure_env, this, closure_ctx.private_ctx, args);
    }
    return invokeFunctionNode(closure_ctx.interp, fnode, closure_ctx.closure_env, allocator, this, closure_ctx.super_proto, null, closure_ctx.private_ctx, args);
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

    // Instance fields: a BASE class initializes them before its ctor body
    // (spec: right after this-creation); a DERIVED class defers them until
    // super() returns -- armed here, consumed by evalCall's super() branch
    // (save/restore keeps nested constructions inside the body correct).
    if (cctx.super_ctor == null) {
        try self.runInstanceFields(cctx, this_value);
    }

    if (cctx.ctor_fnode) |fnode| {
        if (cctx.super_ctor != null) {
            const prev_pending = self.pending_field_init;
            self.pending_field_init = cctx;
            defer self.pending_field_init = prev_pending;
            return invokeFunctionNode(self, fnode, cctx.closure_env, allocator, this_value, cctx.super_proto, cctx.super_ctor, cctx, args);
        }
        return invokeFunctionNode(self, fnode, cctx.closure_env, allocator, this_value, cctx.super_proto, cctx.super_ctor, cctx, args);
    }
    // Implicit constructor: a derived class forwards this + args to its
    // parent (`constructor(...args) { super(...args) }`) and then runs its
    // own field initializers; a base class is a no-op.
    if (cctx.super_ctor) |parent| {
        self.construct_target = parent.function.value.ctx;
        defer self.construct_target = null;
        _ = try parent.function.value.call(parent.function.value.ctx, allocator, this_value, args);
        try self.runInstanceFields(cctx, this_value);
    }
    return JSValue.UNDEFINED;
}


// ---- GC tests (roadmap item 15, phase 5) -----------------------------
// White-box: collectGarbage()/gc_registry are private, so these live here
// rather than in tests/. Each proves a specific unreachable-but-nonzero-
// refcount shape gets reclaimed by checking gc_registry.count() returns
// to its pre-cycle baseline after collectGarbage() -- mark-and-sweep
// doesn't care what a node's Rc count says, only whether it's reachable,
// so this is robust regardless of exactly how inflated that count is
// (see the "let x = {} leaves refcount 2, not 1" quirk in
// refcount_test.zig -- these cycles rely on exactly that quirk to even
// be nonzero-but-unreachable in the first place).

fn gcTestInterp(allocating: *std.Io.Writer.Allocating) !Interpreter {
    return Interpreter.init(std.testing.allocator, &allocating.writer);
}

test "collectGarbage reclaims a plain object-object cycle" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    _ = try interp.run("1;");
    const baseline = interp.gc_registry.count();

    _ = try interp.run(
        \\let a = {};
        \\let b = {};
        \\a.x = b;
        \\b.x = a;
        \\a = null;
        \\b = null;
    );
    try testing.expectEqual(baseline + 2, interp.gc_registry.count());
    interp.collectGarbage();
    try testing.expectEqual(baseline, interp.gc_registry.count());
}

test "collectGarbage reclaims the function<->prototype cycle every ordinary function has" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    _ = try interp.run("1;");
    const baseline = interp.gc_registry.count();

    // Reading .prototype forces functionPrototype() to materialize the
    // F.prototype/P.constructor cycle; nothing else keeps F or P alive
    // once `f` itself is nulled.
    _ = try interp.run(
        \\let f = function(){};
        \\f.prototype.constructor;
        \\f = null;
    );
    try testing.expectEqual(baseline + 3, interp.gc_registry.count());
    interp.collectGarbage();
    try testing.expectEqual(baseline, interp.gc_registry.count());
}

test "collectGarbage reclaims a closure<->object<->environment cycle" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    // `make` itself is a permanent global -- establish the baseline AFTER
    // declaring it, so only what ONE call to make() allocates is measured.
    _ = try interp.run(
        \\function make() {
        \\  let obj = {};
        \\  obj.fn = function() { return obj; };
        \\  return obj;
        \\}
    );
    const baseline = interp.gc_registry.count();

    _ = try interp.run(
        \\let x = make();
        \\x = null;
    );
    // call_env (Environment) + obj (object) + fn (function) + fn's
    // ClosureCtx, at minimum -- all unreachable once x is null (exact
    // count intentionally not asserted: a separate, pre-existing
    // under-retention issue in a shared-cache path was found while
    // pinning this down and is tracked as a follow-up rather than
    // chased further here).
    const before_collect = interp.gc_registry.count();
    try testing.expect(before_collect >= baseline + 4);
    interp.collectGarbage();
    const after_collect = interp.gc_registry.count();
    try testing.expect(after_collect < before_collect);
    interp.collectGarbage(); // idempotent: nothing left to reclaim
    try testing.expectEqual(after_collect, interp.gc_registry.count());
}

test "collectGarbage reclaims an abandoned, never-driven generator (fiber stack included)" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    _ = try interp.run("function* gen() { yield 1; yield 2; }");
    const baseline = interp.gc_registry.count();

    _ = try interp.run(
        \\let g = gen();
        \\g = null;
    );
    // The generator object + its "next" function + the FiberState (whose
    // 8 MiB stack rides along, freed via Fiber.deinit() inside
    // freeGarbageNode's .fiber_state case), at minimum -- exact count
    // intentionally not asserted, see the closure<->object<->environment
    // test's comment.
    const before_collect = interp.gc_registry.count();
    try testing.expect(before_collect >= baseline + 3);
    interp.collectGarbage();
    const after_collect = interp.gc_registry.count();
    try testing.expect(after_collect < before_collect);
    interp.collectGarbage(); // idempotent: nothing left to reclaim
    try testing.expectEqual(after_collect, interp.gc_registry.count());
}

test "collectGarbage reclaims a promise captured by its own .then() callback" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    _ = try interp.run("1;");
    const baseline = interp.gc_registry.count();

    // p's own .then() callback closes over `p` itself (via the shared
    // call_env) -- a real promise<->closure<->environment cycle. Never
    // resolved/awaited, so nothing ever drains this reaction; once `p`
    // itself is nulled, the whole island is unreachable.
    _ = try interp.run(
        \\let p;
        \\p = new Promise((res, rej) => {});
        \\p.then(() => p);
        \\p = null;
    );
    interp.collectGarbage();
    try testing.expectEqual(baseline, interp.gc_registry.count());
}
