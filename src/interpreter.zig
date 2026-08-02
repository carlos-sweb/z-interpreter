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
const native_helpers = @import("native_helpers.zig");
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
const zbigint = @import("zbigint");
const zbuffer = @import("zbuffer");

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
    bigint: JSValue = JSValue.UNDEFINED,
    array_buffer: JSValue = JSValue.UNDEFINED,
    data_view: JSValue = JSValue.UNDEFINED,
    /// The abstract, non-exposed `%TypedArray%.prototype` every concrete
    /// kind's own prototype chains to (real spec: `Int8Array.prototype
    /// .__proto__ === %TypedArray%.prototype`). Carries no methods this
    /// phase (phase 3's job) -- exists purely so `instanceof`/
    /// `getPrototypeOf` chain identity is already correct.
    typed_array_base: JSValue = JSValue.UNDEFINED,
    int8_array: JSValue = JSValue.UNDEFINED,
    uint8_array: JSValue = JSValue.UNDEFINED,
    uint8_clamped_array: JSValue = JSValue.UNDEFINED,
    int16_array: JSValue = JSValue.UNDEFINED,
    uint16_array: JSValue = JSValue.UNDEFINED,
    int32_array: JSValue = JSValue.UNDEFINED,
    uint32_array: JSValue = JSValue.UNDEFINED,
    float32_array: JSValue = JSValue.UNDEFINED,
    float64_array: JSValue = JSValue.UNDEFINED,
    bigint64_array: JSValue = JSValue.UNDEFINED,
    biguint64_array: JSValue = JSValue.UNDEFINED,
    // Temporal (TC39, see /home/sweb/.plans -- z-temporal wiring): one
    // prototype per wrapped type, dispatched by `TemporalValue`'s inner
    // tag (see `temporalProtoFor` in temporal_builtins.zig). ZonedDateTime
    // is deliberately not wired yet (needs real I/O for tzdata, unlike
    // every other Temporal type here).
    temporal_plain_date: JSValue = JSValue.UNDEFINED,
    temporal_plain_time: JSValue = JSValue.UNDEFINED,
    temporal_plain_date_time: JSValue = JSValue.UNDEFINED,
    temporal_plain_year_month: JSValue = JSValue.UNDEFINED,
    temporal_plain_month_day: JSValue = JSValue.UNDEFINED,
    temporal_instant: JSValue = JSValue.UNDEFINED,
    temporal_duration: JSValue = JSValue.UNDEFINED,

    /// Picks the right one of the 7 prototypes above for a given
    /// `TemporalValue`'s inner tag -- the single dispatch point every
    /// `.temporal` case elsewhere (`getProperty`, `objectGetPrototypeOf`,
    /// ...) goes through, so the tag-to-prototype mapping lives in exactly
    /// one place.
    pub fn temporalProtoFor(self: *const Protos, tv: zvalue.TemporalValue) JSValue {
        return switch (tv) {
            .plain_date => self.temporal_plain_date,
            .plain_time => self.temporal_plain_time,
            .plain_date_time => self.temporal_plain_date_time,
            .plain_year_month => self.temporal_plain_year_month,
            .plain_month_day => self.temporal_plain_month_day,
            .instant => self.temporal_instant,
            .duration => self.temporal_duration,
            .zoned_date_time => JSValue.UNDEFINED, // not wired yet
        };
    }
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

/// `delete f.name`/`delete f.length` state -- see `deleted_fn_props`.
pub const DeletedFnProps = struct {
    name: bool = false,
    length: bool = false,
};

/// A user-defined closure's opaque Callable context: the parsed function's
/// AST node, the environment it closed over at definition time, and a back
/// pointer to the Interpreter so `closureCall` can recurse into
/// `evalProgram`/`evalExpression`. Safe to store `*Interpreter` here
/// because closures are only ever created from inside `evalExpression`
/// (which already takes `self: *Interpreter`, i.e. the caller's own stable
/// address) -- never during `Interpreter.init`.
// z-interpreter-refactor.md, Step 5 Phase C batch 1: `pub` here (struct +
// traceChildren) because GcNode (now in interpreter_gc.zig) holds a
// `*ClosureCtx`, and interpreter_gc.zig's traceValueChildren calls
// `cc.traceChildren(visitor)` across the file boundary.
pub const ClosureCtx = struct {
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
    pub fn traceChildren(self: *const ClosureCtx, visitor: anytype) void {
        visitor.environment(self.closure_env);
        if (self.super_proto) |v| visitor.value(v);
        if (self.private_ctx) |pc| classCtxFromOpaque(pc).traceChildren(visitor);
    }
};

/// One instance field captured at class-definition time: the key is fully
/// resolved (computed keys already evaluated, private keys already encoded
/// via encodePrivateKey); the initializer expression runs per-instance at
/// construction time.
pub const FieldDef = struct {
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

// z-interpreter-refactor.md, Step 5 Phase C batch 2: `pub` here so
// interpreter_module.zig (loadModule/evalModuleBody) can name it.
pub const ModuleRecord = struct {
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
// z-interpreter-refactor.md, Step 5 Phase C batch 1: `pub` here (struct +
// traceChildren) -- same reason as ClosureCtx above: GcNode (now in
// interpreter_gc.zig) holds a `*FiberState`.
pub const FiberState = struct {
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
    pub fn traceChildren(self: *const FiberState, visitor: anytype) void {
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

// z-interpreter-refactor.md, Step 5 Phase C batch 1: `pub` here (struct +
// traceChildren) -- same reason as ClosureCtx/FiberState above: GcNode
// (now in interpreter_gc.zig) holds a `*ClassCtx`, and
// classCtxFromOpaque (below, also now `pub`) is called from
// interpreter_gc.zig's Marker.environment.
pub const ClassCtx = struct {
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
    pub fn traceChildren(self: *const ClassCtx, visitor: anytype) void {
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
pub fn classCtxFromOpaque(ptr: *anyopaque) *ClassCtx {
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
// z-interpreter-refactor.md, Step 5 Phase C batch 1: GcNode/GcRegistry/
// heapBoxAddress/Marker/Sweeper moved to interpreter_gc.zig, alongside
// every gcTrack*/gcNew*/traceValueChildren/markRoots/freeGarbageNode/
// collectGarbage/freeAllGcNodes/init/deinit method (aliased back in
// below, same `pub const foo = other_file.foo;` pattern Phase A used
// throughout builtins.zig). ClosureCtx/FiberState/ClassCtx above are
// `pub` now specifically so interpreter_gc.zig's GcNode/Marker can
// reach them by pointer.
const interpreter_gc = @import("interpreter_gc.zig");
const GcRegistry = interpreter_gc.GcRegistry;

// z-interpreter-refactor.md, Step 5 Phase C batch 2: module loading
// (setModuleLoader/runModule/loadModule/evalModuleBody/
// collectDeclaredNames/collectPatternNames) moved to
// interpreter_module.zig. No interleaving -- already a single
// self-contained section.
const interpreter_module = @import("interpreter_module.zig");

// z-interpreter-refactor.md, Step 5 Phase C batch 3: the runtime/
// execution-loop cluster (entry points, Promise state machine,
// fiber/generator/async machinery, setTimeout timers) moved to
// interpreter_runtime.zig. Not contiguous in the original file --
// assembled from 4 separate ranges.
const interpreter_runtime = @import("interpreter_runtime.zig");
const interpreter_class = @import("interpreter_class.zig");
const interpreter_props = @import("interpreter_props.zig");
const interpreter_support = @import("interpreter_support.zig");
const interpreter_binding = @import("interpreter_binding.zig");
const interpreter_stmt = @import("interpreter_stmt.zig");
const interpreter_expr = @import("interpreter_expr.zig");

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
    /// The environment whose `var`/function hoisting counts as "global
    /// declaration instantiation" for `globalThis` reification purposes --
    /// `run()` sets this to `script_env`; `runModule`'s entry file (no
    /// referrer -- z-run always executes even import-less scripts as a
    /// "module" for import/export support, but the entry file itself
    /// still needs classic-script globalThis semantics) sets it to that
    /// file's own module_env. A DEPENDENCY module loaded via `import`
    /// never touches this field, so its top-level `var`s correctly stay
    /// module-local (real spec: only a classic script's declarations
    /// become global object properties, never a module's).
    global_var_env: ?*Environment = null,
    /// Names of top-level `var`/function declarations in `global_var_env`.
    /// Real spec's CreateGlobalVarBinding/CreateGlobalFunctionBinding make
    /// these genuine (non-configurable) own properties of the global
    /// object; `let`/`const`/`class` at script scope do NOT (confirmed
    /// against real Node) -- since Environment doesn't tag bindings by
    /// declaration kind, this set is the only record of which
    /// global_var_env names are var/function-kind, consulted by
    /// hasOwnProperty et al on globalThis. Keys are AST-borrowed slices
    /// (same lifetime contract as Environment.bindings), never freed
    /// individually.
    global_var_names: std.StringHashMapUnmanaged(void) = .empty,
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
    /// `delete f.name`/`delete f.length` tracking: those aren't real
    /// ZObject bag entries (getProperty/hasOwnProperty/
    /// getOwnPropertyDescriptor read them straight off the Callable
    /// struct's own `name`/`arity` fields, per real spec's
    /// configurable-but-otherwise-fixed own properties), so `delete`
    /// needs its own side table to record "gone" -- same shape as
    /// `array_props`/`primitive_wrapper_data`, keyed by the function box
    /// pointer. No JSValue payload, so no GC-tracking/cleanup needed
    /// (unlike those two).
    deleted_fn_props: std.AutoHashMapUnmanaged(usize, DeletedFnProps) = .empty,
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
    // z-interpreter-refactor.md, Step 5 Phase C batch 2: `pub` so
    // interpreter_module.zig's runModule can reach it as
    // `Interpreter.main_stack_budget`.
    pub const main_stack_budget: usize = 6 * 1024 * 1024;
    /// Reserved floor inside each 8 MiB fiber stack.
    // z-interpreter-refactor.md, Step 5 Phase C batch 3: `pub` so
    // interpreter_runtime.zig's resumeFiber can reach it as
    // `Interpreter.fiber_stack_margin`.
    pub const fiber_stack_margin: usize = 1024 * 1024;

    pub const init = interpreter_gc.init;
    pub const deinit = interpreter_gc.deinit;
    pub const gcOnBoxDestroyed = interpreter_gc.gcOnBoxDestroyed;
    pub const gcTrack = interpreter_gc.gcTrack;
    pub const gcAdoptTree = interpreter_gc.gcAdoptTree;
    pub const gcTrackNode = interpreter_gc.gcTrackNode;
    pub const gcTrackEnvironment = interpreter_gc.gcTrackEnvironment;
    pub const gcTrackClosureCtx = interpreter_gc.gcTrackClosureCtx;
    pub const gcTrackFiberState = interpreter_gc.gcTrackFiberState;
    pub const gcTrackClassCtx = interpreter_gc.gcTrackClassCtx;
    pub const gcTrackPromiseCapCtx = interpreter_gc.gcTrackPromiseCapCtx;
    pub const gcTrackBoundCtx = interpreter_gc.gcTrackBoundCtx;
    pub const gcTrackFinallyCtx = interpreter_gc.gcTrackFinallyCtx;
    pub const gcTrackAllCtx = interpreter_gc.gcTrackAllCtx;
    pub const gcTrackAllElemCtx = interpreter_gc.gcTrackAllElemCtx;
    pub const gcTrackRaceCtx = interpreter_gc.gcTrackRaceCtx;
    pub const gcTrackArrayIterCtx = interpreter_gc.gcTrackArrayIterCtx;
    pub const gcChildEnv = interpreter_gc.gcChildEnv;
    pub const gcNewObject = interpreter_gc.gcNewObject;
    pub const gcNewArray = interpreter_gc.gcNewArray;
    pub const gcNewMap = interpreter_gc.gcNewMap;
    pub const gcNewSet = interpreter_gc.gcNewSet;
    pub const gcNewFunction = interpreter_gc.gcNewFunction;
    pub const gcNewPromise = interpreter_gc.gcNewPromise;
    pub const gcNewError = interpreter_gc.gcNewError;
    pub const gcNewAggregateError = interpreter_gc.gcNewAggregateError;
    pub const gcNewSymbol = interpreter_gc.gcNewSymbol;
    pub const gcNewString = interpreter_gc.gcNewString;
    pub const gcNewDate = interpreter_gc.gcNewDate;
    pub const gcNewTemporal = interpreter_gc.gcNewTemporal;
    pub const gcNewBigInt = interpreter_gc.gcNewBigInt;
    pub const gcNewBigIntValue = interpreter_gc.gcNewBigIntValue;
    pub const gcNewProxy = interpreter_gc.gcNewProxy;
    pub const gcNewArrayBuffer = interpreter_gc.gcNewArrayBuffer;
    pub const gcNewArrayBufferFromValue = interpreter_gc.gcNewArrayBufferFromValue;
    pub const gcNewDataView = interpreter_gc.gcNewDataView;
    pub const gcNewTypedArray = interpreter_gc.gcNewTypedArray;
    pub const traceValueChildren = interpreter_gc.traceValueChildren;
    pub const markRoots = interpreter_gc.markRoots;
    pub const freeGarbageNode = interpreter_gc.freeGarbageNode;
    pub const collectGarbage = interpreter_gc.collectGarbage;
    pub const freeAllGcNodes = interpreter_gc.freeAllGcNodes;

    pub const run = interpreter_runtime.run;
    pub const evalSource = interpreter_runtime.evalSource;
    pub const defineGlobal = interpreter_runtime.defineGlobal;
    pub const hasPendingJobs = interpreter_runtime.hasPendingJobs;
    pub const runPendingJob = interpreter_runtime.runPendingJob;
    pub const resolvePromise = interpreter_runtime.resolvePromise;
    pub const rejectPromiseValue = interpreter_runtime.rejectPromiseValue;
    pub const settlePromise = interpreter_runtime.settlePromise;
    pub const subscribePromise = interpreter_runtime.subscribePromise;
    pub const promiseThen = interpreter_runtime.promiseThen;
    pub const fulfilledPromise = interpreter_runtime.fulfilledPromise;
    pub const rejectedPromise = interpreter_runtime.rejectedPromise;
    // ===== RegExp =====

    // z-interpreter-refactor.md, Step 5 Phase C batch 6: regex+arrayextra+
    // boxing+coerce+native cluster, split into interpreter_support.zig.
    pub const makeRegex = interpreter_support.makeRegex;
    pub const regexState = interpreter_support.regexState;
    pub const setArrayExtra = interpreter_support.setArrayExtra;
    pub const arrayExtra = interpreter_support.arrayExtra;
    pub const arrayPropsObject = interpreter_support.arrayPropsObject;
    pub const boxPrimitiveIfConstructed = interpreter_support.boxPrimitiveIfConstructed;
    pub const unboxPrimitiveWrapper = interpreter_support.unboxPrimitiveWrapper;

    // ===== Modules (import/export) =====
    // z-interpreter-refactor.md, Step 5 Phase C batch 2: moved to
    // interpreter_module.zig. All `pub` (batch 1's lesson: self.foo()
    // always resolves through this file's alias regardless of where the
    // calling method's body lives, even for calls between two moved
    // methods).
    pub const setModuleLoader = interpreter_module.setModuleLoader;
    pub const runModule = interpreter_module.runModule;
    pub const loadModule = interpreter_module.loadModule;
    pub const evalModuleBody = interpreter_module.evalModuleBody;
    pub const collectDeclaredNames = interpreter_module.collectDeclaredNames;
    pub const collectPatternNames = interpreter_module.collectPatternNames;

    // ===== Fibers (generators / async functions) =====
    pub const resumeFiber = interpreter_runtime.resumeFiber;
    pub const awaitValue = interpreter_runtime.awaitValue;
    pub const makeGeneratorObject = interpreter_runtime.makeGeneratorObject;
    pub const runAsyncFunction = interpreter_runtime.runAsyncFunction;
    pub const makeAsyncGeneratorObject = interpreter_runtime.makeAsyncGeneratorObject;
    // ===== Timers (setTimeout macrotasks) =====
    pub const addTimer = interpreter_runtime.addTimer;
    pub const clearTimer = interpreter_runtime.clearTimer;
    pub const runEventLoop = interpreter_runtime.runEventLoop;

    // ===== Exception machinery =====
    // z-interpreter-refactor.md, Step 5 Phase C batch 1: moved to
    // interpreter_gc.zig (rides along with the GC subsystem -- its only
    // outbound dependency is gcNewError, also there).
    pub const throwValue = interpreter_gc.throwValue;
    pub const throwError = interpreter_gc.throwError;

    // z-interpreter-refactor.md, Step 5 Phase C batch 8: statement/
    // hoisting/loop cluster, split into interpreter_stmt.zig.
    pub const runCapturing = interpreter_stmt.runCapturing;
    pub const deliver = interpreter_stmt.deliver;
    pub const evalProgram = interpreter_stmt.evalProgram;
    pub const evalBody = interpreter_stmt.evalBody;
    pub const evalStatementList = interpreter_stmt.evalStatementList;
    pub const hoistVarScope = interpreter_stmt.hoistVarScope;
    pub const hoistVarsInStatement = interpreter_stmt.hoistVarsInStatement;
    pub const hoistVarForBinding = interpreter_stmt.hoistVarForBinding;
    pub const hoistVarPattern = interpreter_stmt.hoistVarPattern;
    pub const hoistLexical = interpreter_stmt.hoistLexical;
    pub const markPatternTDZ = interpreter_stmt.markPatternTDZ;
    pub const checkVarNotShadowingLexical = interpreter_stmt.checkVarNotShadowingLexical;
    pub const evalStatement = interpreter_stmt.evalStatement;
    pub const loopOwns = interpreter_stmt.loopOwns;
    pub const evalWhile = interpreter_stmt.evalWhile;
    pub const evalDoWhile = interpreter_stmt.evalDoWhile;
    pub const evalForStatement = interpreter_stmt.evalForStatement;

    // z-interpreter-refactor.md, Step 5 Phase C batch 7: binding+iter
    // cluster, split into interpreter_binding.zig.
    pub const iterableItems = interpreter_binding.iterableItems;
    pub const resolveIterator = interpreter_binding.resolveIterator;
    pub const resolveAsyncIterator = interpreter_binding.resolveAsyncIterator;
    pub const drainIterator = interpreter_binding.drainIterator;
    pub const evalYieldDelegate = interpreter_binding.evalYieldDelegate;
    pub const bindPattern = interpreter_binding.bindPattern;
    pub const destructuringAssign = interpreter_binding.destructuringAssign;
    pub const destructuringAssignTarget = interpreter_binding.destructuringAssignTarget;
    pub const bindForIteration = interpreter_binding.bindForIteration;
    pub const forIterationStep = interpreter_binding.forIterationStep;
    pub const evalForOf = interpreter_binding.evalForOf;
    pub const evalForIn = interpreter_binding.evalForIn;

    // ===== Expressions =====

    // z-interpreter-refactor.md, Step 5 Phase C batch 9 (FINAL): expr+
    // propkey cluster, split into interpreter_expr.zig.
    pub const evalExpression = interpreter_expr.evalExpression;
    pub const encodeKey = interpreter_expr.encodeKey;
    pub const isSymbolKey = interpreter_expr.isSymbolKey;
    pub const PropKey = interpreter_expr.PropKey;
    pub const memberKeyString = interpreter_expr.memberKeyString;
    pub const propertyKeyString = interpreter_expr.propertyKeyString;
    pub const evalInstanceof = interpreter_expr.evalInstanceof;
    pub const evalIn = interpreter_expr.evalIn;
    pub const evalUnary = interpreter_expr.evalUnary;
    pub const evalAssignment = interpreter_expr.evalAssignment;
    pub const assignTo = interpreter_expr.assignTo;
    pub const evalCall = interpreter_expr.evalCall;
    pub const callValue = interpreter_expr.callValue;
    pub const evalArgs = interpreter_expr.evalArgs;
    pub const evalNew = interpreter_expr.evalNew;
    pub const isConstructor = interpreter_expr.isConstructor;
    pub const constructValue = interpreter_expr.constructValue;

    // z-interpreter-refactor.md, Step 5 Phase C batch 6: regex+arrayextra+
    // boxing+coerce+native cluster, split into interpreter_support.zig.
    pub const nativeMethod = interpreter_support.nativeMethod;
    pub const proxyTrap = interpreter_support.proxyTrap;
    pub const argsToArray = interpreter_support.argsToArray;

    // z-interpreter-refactor.md, Step 5 Phase C batch 5: propaccess+protos
    // cluster, split into interpreter_props.zig.
    pub const getProperty = interpreter_props.getProperty;

    // z-interpreter-refactor.md, Step 5 Phase C batch 5: propaccess+protos
    // cluster, split into interpreter_props.zig.
    pub const setArrayProperty = interpreter_props.setArrayProperty;
    pub const setTypedArrayProperty = interpreter_props.setTypedArrayProperty;
    pub const setObjectProperty = interpreter_props.setObjectProperty;
    pub const deleteObjectProperty = interpreter_props.deleteObjectProperty;
    pub const setPropertyOnValue = interpreter_props.setPropertyOnValue;
    pub const deletePropertyOnValue = interpreter_props.deletePropertyOnValue;
    pub const functionStatics = interpreter_props.functionStatics;
    pub const functionPrototype = interpreter_props.functionPrototype;
    pub const ordinaryObject = interpreter_props.ordinaryObject;
    pub const typedArrayProto = interpreter_props.typedArrayProto;
    pub const getFromProto = interpreter_props.getFromProto;
    pub const installProto = interpreter_props.installProto;
    pub const aliasSymbolIterator = interpreter_props.aliasSymbolIterator;
    pub const materializeProtos = interpreter_props.materializeProtos;

    // z-interpreter-refactor.md, Step 5 Phase C batch 6: regex+arrayextra+
    // boxing+coerce+native cluster, split into interpreter_support.zig.
    pub const stringConcat = interpreter_support.stringConcat;
    pub const toPrimitive = interpreter_support.toPrimitive;
    pub const toDisplayStringJS = interpreter_support.toDisplayStringJS;
    pub const toNumberJS = interpreter_support.toNumberJS;
    pub const deletedFnProps = interpreter_support.deletedFnProps;
    pub const markFnPropDeleted = interpreter_support.markFnPropDeleted;
    pub const bigintArithmetic = interpreter_support.bigintArithmetic;
    pub const bigintShift = interpreter_support.bigintShift;
    pub const bigintErr = interpreter_support.bigintErr;
    pub const bufferErr = interpreter_support.bufferErr;
    pub const incDecOne = interpreter_support.incDecOne;

    // z-interpreter-refactor.md, Step 5 Phase C batch 4: class+private+closures
    // cluster, split into interpreter_class.zig.
    pub const makeClosure = interpreter_class.makeClosure;
    pub const maybeNameAnonymousValue = interpreter_class.maybeNameAnonymousValue;
    pub const makeMethodClosure = interpreter_class.makeMethodClosure;
    pub const encodePrivateKey = interpreter_class.encodePrivateKey;
    pub const privateHolder = interpreter_class.privateHolder;
    pub const privateGet = interpreter_class.privateGet;
    pub const privateSet = interpreter_class.privateSet;
    pub const privateHas = interpreter_class.privateHas;
    pub const runInstanceFields = interpreter_class.runInstanceFields;
    pub const evalClass = interpreter_class.evalClass;
};

pub const invokeFunctionNode = interpreter_class.invokeFunctionNode;


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
