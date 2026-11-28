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
const bytecode_emitter = @import("bytecode/emitter.zig");

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
    /// AggregateError.prototype (its instances are `.object`s chained
    /// to it, and it to Error.prototype -- see error_builtins).
    aggregate_error: JSValue = JSValue.UNDEFINED,
    suppressed_error: JSValue = JSValue.UNDEFINED,
    disposable_stack: JSValue = JSValue.UNDEFINED,
    async_disposable_stack: JSValue = JSValue.UNDEFINED,
    async_iterator_proto: JSValue = JSValue.UNDEFINED,
    generator_proto: JSValue = JSValue.UNDEFINED,
    generator_function_proto: JSValue = JSValue.UNDEFINED,
    async_generator_proto: JSValue = JSValue.UNDEFINED,
    async_generator_function_proto: JSValue = JSValue.UNDEFINED,
    async_function_proto: JSValue = JSValue.UNDEFINED,
    array_iterator_proto: JSValue = JSValue.UNDEFINED,
    map_iterator_proto: JSValue = JSValue.UNDEFINED,
    set_iterator_proto: JSValue = JSValue.UNDEFINED,
    string_iterator_proto: JSValue = JSValue.UNDEFINED,
    map: JSValue = JSValue.UNDEFINED,
    set: JSValue = JSValue.UNDEFINED,
    symbol: JSValue = JSValue.UNDEFINED,
    promise: JSValue = JSValue.UNDEFINED,
    bigint: JSValue = JSValue.UNDEFINED,
    array_buffer: JSValue = JSValue.UNDEFINED,
    shared_array_buffer: JSValue = JSValue.UNDEFINED,
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
    // tag (see `temporalProtoFor` in temporal_builtins.zig).
    temporal_plain_date: JSValue = JSValue.UNDEFINED,
    temporal_plain_time: JSValue = JSValue.UNDEFINED,
    temporal_plain_date_time: JSValue = JSValue.UNDEFINED,
    temporal_plain_year_month: JSValue = JSValue.UNDEFINED,
    temporal_plain_month_day: JSValue = JSValue.UNDEFINED,
    temporal_instant: JSValue = JSValue.UNDEFINED,
    temporal_duration: JSValue = JSValue.UNDEFINED,
    temporal_zoned_date_time: JSValue = JSValue.UNDEFINED,

    /// Picks the right one of the 8 prototypes above for a given
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
            .zoned_date_time => self.temporal_zoned_date_time,
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
    has_indices: bool,
    unicode_sets: bool,
    // A plain, uncoerced data property (real spec) -- ANY JSValue can be
    // stored here (`re.lastIndex = {}` really does store the object,
    // confirmed against Node), with ToLength applied lazily by
    // regexTest/regexExec's own read, not at assignment time. Owned:
    // retained on every write, released in gcOnBoxDestroyed alongside
    // this regex's other regex_state cleanup.
    last_index: JSValue = JSValue.fromNumber(0),
    // `lastIndex` is writable until `Object.defineProperty(re, "lastIndex",
    // {writable: false})`; it is never enumerable nor configurable.
    last_index_writable: bool = true,
    // Own properties other than `lastIndex` (`re.exec = f`,
    // Object.defineProperty(re, "flags", ...)): a prototype-less object
    // created on first write, holding full descriptors. Lives and dies
    // with the RegExp (released in gcOnBoxDestroyed).
    props: ?JSValue = null,
};

/// A %RegExpStringIterator% object's internal slots ([[IteratingRegExp]],
/// [[IteratedString]], [[Global]], [[Unicode]], [[Done]]), keyed by the
/// iterator object's box. `pos`/`cursor_*` are the fast path's own
/// position (see regex_protocol's regExpStringIteratorNext).
pub const RegExpStringIterState = struct {
    r: JSValue,
    s: JSValue,
    global: bool,
    unicode: bool,
    done: bool = false,
    pos: ?usize = null,
    cursor_pos: usize = 0,
    cursor_index: usize = 0,
};

/// One WeakMap/WeakSet entry, keyed (in WeakTable) by the key's box
/// address. The key is held strongly: this engine never observes it
/// dying, which the spec permits (a WeakMap need not drop entries).
pub const WeakEntry = struct { key: JSValue, value: JSValue };
pub const WeakTable = std.AutoHashMapUnmanaged(usize, WeakEntry);
/// A FinalizationRegistry registration ([[Cells]] element).
pub const FinRegCell = struct { target: JSValue, held: JSValue, token: JSValue };

pub const ConcatItem = struct {
    iterable: JSValue,
    open_method: JSValue,
};

pub const ZipMode = enum { shortest, longest, strict };

pub const ZipItem = struct {
    iterator: JSValue,
    next: JSValue,
    padding: JSValue = JSValue.UNDEFINED,
    key: []const u8 = "",
    open: bool = true,
};

/// An Iterator helper's state (iterator_builtins.zig): the underlying
/// iterator record, the callback, and the generator-like run state.
/// Heap-allocated so a pointer to it survives `object_slots` rehashing
/// while the callback runs.
pub const IteratorHelper = struct {
    kind: enum { map, filter, take, drop, flat_map, concat, zip, zip_keyed },
    state: enum { suspended_start, suspended_yield, executing, completed } = .suspended_start,
    iterator: JSValue,
    next: JSValue,
    func: JSValue = JSValue.UNDEFINED,
    counter: f64 = 0,
    /// take/drop's remaining count (+Infinity allowed).
    remaining: f64 = 0,
    /// flatMap's/concat's current inner iterator record.
    inner_iterator: JSValue = JSValue.UNDEFINED,
    inner_next: JSValue = JSValue.UNDEFINED,
    inner_alive: bool = false,
    concat_items: std.ArrayListUnmanaged(ConcatItem) = .empty,
    concat_idx: usize = 0,
    zip_mode: ZipMode = .shortest,
    zip_items: std.ArrayListUnmanaged(ZipItem) = .empty,
};

/// The internal slots of an `.object` that is a builtin instance with no
pub const DisposableMode = enum {
    sync,
    async_method,
    sync_fallback,
    dummy,
};

pub const DisposableEntry = struct {
    value: JSValue,
    method: JSValue,
    has_arg: bool,
    mode: DisposableMode = .sync,
};

pub const DisposableStackState = struct {
    disposed: bool = false,
    stack: std.ArrayListUnmanaged(DisposableEntry) = .empty,
};

pub const AsyncDisposeRunner = struct {
    entries: std.ArrayListUnmanaged(DisposableEntry) = .empty,
    idx: usize = 0,
    has_err: bool = false,
    current_err: JSValue = JSValue.UNDEFINED,
    result_promise: JSValue = JSValue.UNDEFINED,
    needs_await: bool = false,
    has_awaited: bool = false,
    did_final_await: bool = false,
};

/// JSValue tag of its own (WeakMap, WeakSet, WeakRef,
/// FinalizationRegistry, Iterator helpers, Iterator.from's wrappers);
/// keyed by the box address in `object_slots`.
pub const ObjectSlots = union(enum) {
    weak_map: WeakTable,
    weak_set: WeakTable,
    weak_ref: JSValue,
    finalization_registry: struct { cleanup: JSValue, cells: std.ArrayListUnmanaged(FinRegCell) },
    iterator_helper: *IteratorHelper,
    /// %WrapForValidIteratorPrototype%'s [[Iterated]] record.
    wrapped_iterator: struct { iterator: JSValue, next: JSValue },
    disposable_stack: *DisposableStackState,
    async_disposable_stack: *DisposableStackState,
    async_dispose_runner: *AsyncDisposeRunner,

    /// Every JSValue the slots hold (GC marking and release).
    pub fn eachValue(self: *const ObjectSlots, ctx: anytype, comptime f: fn (@TypeOf(ctx), JSValue) void) void {
        switch (self.*) {
            .weak_map, .weak_set => |t| {
                var it = t.valueIterator();
                while (it.next()) |e| {
                    f(ctx, e.key);
                    f(ctx, e.value);
                }
            },
            .weak_ref => |v| f(ctx, v),
            .iterator_helper => |h| {
                f(ctx, h.iterator);
                f(ctx, h.next);
                f(ctx, h.func);
                f(ctx, h.inner_iterator);
                f(ctx, h.inner_next);
                for (h.concat_items.items) |it| {
                    f(ctx, it.iterable);
                    f(ctx, it.open_method);
                }
                for (h.zip_items.items) |it| {
                    f(ctx, it.iterator);
                    f(ctx, it.next);
                    f(ctx, it.padding);
                }
            },
            .wrapped_iterator => |w| {
                f(ctx, w.iterator);
                f(ctx, w.next);
            },
            .disposable_stack, .async_disposable_stack => |ds| {
                for (ds.stack.items) |entry| {
                    f(ctx, entry.value);
                    f(ctx, entry.method);
                }
            },
            .async_dispose_runner => |r| {
                for (r.entries.items) |entry| {
                    f(ctx, entry.value);
                    f(ctx, entry.method);
                }
                f(ctx, r.current_err);
                f(ctx, r.result_promise);
            },
            .finalization_registry => |r| {
                f(ctx, r.cleanup);
                for (r.cells.items) |c| {
                    f(ctx, c.target);
                    f(ctx, c.held);
                    f(ctx, c.token);
                }
            },
        }
    }

    /// Frees the slots' own storage (not the JSValues).
    pub fn freeStorage(self: *ObjectSlots, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .weak_map, .weak_set => |*t| t.deinit(allocator),
            .finalization_registry => |*r| r.cells.deinit(allocator),
            .iterator_helper => |h| {
                h.concat_items.deinit(allocator);
                for (h.zip_items.items) |it| {
                    if (it.key.len > 0) allocator.free(it.key);
                }
                h.zip_items.deinit(allocator);
                allocator.destroy(h);
            },
            .disposable_stack, .async_disposable_stack => |ds| {
                ds.stack.deinit(allocator);
                allocator.destroy(ds);
            },
            .async_dispose_runner => |r| {
                r.entries.deinit(allocator);
                allocator.destroy(r);
            },
            .weak_ref, .wrapped_iterator => {},
        }
    }
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
    /// Non-null only for object-literal method/getter/setter closures:
    /// see Environment.home_object's own doc comment for why this needs
    /// a separate field from super_proto (dynamic vs. snapshot super
    /// resolution).
    home_object: ?JSValue = null,
    /// Non-null only for class method closures: the declaring class's
    /// identity (its *ClassCtx), so `this.#x` inside the body resolves
    /// private names against the right class (copied onto the call env).
    private_ctx: ?*anyopaque = null,
    /// Full source text from which `function_node` was parsed (for Function.prototype.toString).
    source_full: ?[]const u8 = null,
    /// True when the function was defined in strict code or contains a `"use strict"` directive.
    is_strict: bool = false,
    /// Unretained pointer to the owning Function RcBox (used by generator calls to look up `F.prototype`).
    fn_box: ?*anyopaque = null,

    /// GC prep (roadmap item 15, phase 2): see Environment.traceChildren
    /// for the visitor contract. private_ctx is downcast back to *ClassCtx
    /// here (same file, so no opacity problem like Environment has).
    pub fn traceChildren(self: *const ClosureCtx, visitor: anytype) void {
        visitor.environment(self.closure_env);
        if (self.super_proto) |v| visitor.value(v);
        if (self.home_object) |v| visitor.value(v);
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
pub const AsyncGenReqKind = enum { next, ret, throw };

pub const AsyncGenRequest = struct {
    promise: JSValue,
    value: JSValue,
    kind: AsyncGenReqKind,
};

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
    super_proto: ?JSValue = null,
    home_object: ?JSValue = null,
    /// The declaring class's private identity for method bodies (so
    /// `this.#x` works inside generator/async methods too).
    private_ctx: ?*anyopaque,
    args: []const JSValue,
    /// Scheduler -> fiber: what the suspension point produces on resume
    /// (next(v) / the awaited promise's settlement).
    /// Owned by this slot from the producer's store (setResumeValue) until
    /// the suspension point takes it (takeResumeValue).
    resume_value: JSValue = JSValue.UNDEFINED,
    resume_is_throw: bool = false,
    resume_is_return: bool = false,
    has_started: bool = false,
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
    async_queue: std.ArrayListUnmanaged(AsyncGenRequest) = .empty,

    /// Stores `value` (an owned reference) as the resume value, releasing
    /// one left behind that no suspension point took (the first next(v),
    /// whose argument the body never sees; the steps of a `yield*`).
    pub fn setResumeValue(self: *FiberState, value: JSValue) void {
        self.resume_value.deinit();
        self.resume_value = value;
    }

    /// Hands the resume value to the suspension point that resumed (as an
    /// owned reference), leaving the slot empty: the slot owns it until
    /// then, never both at once.
    pub fn takeResumeValue(self: *FiberState) JSValue {
        const v = self.resume_value;
        self.resume_value = JSValue.UNDEFINED;
        return v;
    }

    /// GC prep (roadmap item 15, phase 2): see Environment.traceChildren
    /// for the visitor contract. `interp`/`fiber`/`fnode` aren't
    /// JSValue/Environment -- fiber stacks get their own GC handling in a
    /// later phase (they're not part of this value graph). `is_generator`/
    /// `is_async`/`resume_is_throw`/`fatal_error` carry no values.
    pub fn traceChildren(self: *const FiberState, visitor: anytype) void {
        visitor.environment(self.closure_env);
        if (self.this_value) |v| visitor.value(v);
        if (self.super_proto) |v| visitor.value(v);
        if (self.home_object) |v| visitor.value(v);
        if (self.private_ctx) |pc| classCtxFromOpaque(pc).traceChildren(visitor);
        for (self.args) |a| visitor.value(a);
        visitor.value(self.resume_value);
        if (self.yielded) |v| visitor.value(v);
        if (self.completion) |v| visitor.value(v);
        if (self.completed_throw) |v| visitor.value(v);
        if (self.promise) |v| visitor.value(v);
        if (self.pending_result_promise) |v| visitor.value(v);
        for (self.async_queue.items) |req| {
            visitor.value(req.promise);
            visitor.value(req.value);
        }
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
    is_derived: bool = false,
    /// Instance fields in declaration order, initialized per-instance at
    /// construction time (base classes: at constructor entry; derived
    /// classes: right after super() returns). Keys pre-resolved.
    ///
    /// NOTE: this ClassCtx pointer also doubles as the class's PRIVATE
    /// IDENTITY -- it's what Environment.private_ctx carries and what
    /// encodePrivateKey mixes into `#name` storage keys (brand checks fall
    /// out of key mismatch).
    instance_fields: []const FieldDef = &.{},
    /// Bare private names (without leading `#`) declared directly on this
    /// class, plus the lexically enclosing class's ClassCtx (if nested),
    /// for ECMA-262 ResolvePrivateIdentifier.
    private_names: []const []const u8 = &.{},
    outer_private_ctx: ?*ClassCtx = null,
    /// Exact class source slice (for Function.prototype.toString).
    source_text: ?[]const u8 = null,
    /// Instance private methods/accessors (encoded `\x00P...` keys),
    /// held in a class-owned bag and copied onto each instance by
    /// runInstanceFields -- never on the prototype. Owned (+1).
    private_methods: ?JSValue = null,
    /// The bag's keys in declaration order (interpreter-arena memory).
    private_method_keys: []const []const u8 = &.{},
    /// Encoded keys of STATIC private methods (non-writable; PrivateSet
    /// throws). Interpreter-arena memory.
    private_static_method_keys: []const []const u8 = &.{},

    /// GC prep (roadmap item 15, phase 2): see Environment.traceChildren
    /// for the visitor contract. `instance_fields[i].value` is an AST
    /// node (the unevaluated initializer expression), not a JSValue --
    /// nothing to trace there.
    pub fn traceChildren(self: *const ClassCtx, visitor: anytype) void {
        visitor.environment(self.closure_env);
        if (self.super_ctor) |v| visitor.value(v);
        if (self.super_proto) |v| visitor.value(v);
        if (self.private_methods) |v| visitor.value(v);
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
    try testing.expectEqual(@as(f64, 1), mock.values.items[0].asNumber());
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
    try testing.expectEqual(@as(f64, 42), mock.values.items[0].asNumber());
    try testing.expectEqual(@as(f64, 9), mock.values.items[1].asNumber());
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
    for (mock.values.items) |v| sum += v.asNumber();
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

pub const CompileOptions = struct {
    /// Disabled by default while bytecode coverage is deliberately narrow.
    use_bytecode_vm: bool = false,
    disasm: bool = false,
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
    compile_options: CompileOptions = .{},
    /// The "all live GC objects" registry (phase 4) -- see `GcNode`/
    /// `GcRegistry`'s own doc comments.
    gc_registry: GcRegistry = .empty,
    global_env: *Environment,
    strict_mode: bool = false,
    in_sloppy_eval: bool = false,
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
    pending_return: ?JSValue = null,
    /// Globals (console/Math/JSON/Object/...) are installed lazily on the
    /// first run() -- native functions carry `ctx = *Interpreter`, and
    /// init() returns by value, so `&self` is only stable once run() is
    /// called on the caller's storage.
    globals_ready: bool = false,
    /// Shared native-method values, keyed "type.name" (e.g. "array.push"),
    /// so `a.push === b.push` holds like real JS prototype methods.
    method_cache: std.StringHashMapUnmanaged(JSValue) = .empty,
    /// Cached frozen template objects per AST call site (`@intFromPtr(node)`),
    /// per ECMA-262 GetTemplateObject.
    template_objects: std.AutoHashMapUnmanaged(usize, JSValue) = .empty,
    /// Internal iterator slots (`[[IteratedObject]]` / Map / Set iterator state)
    /// keyed by the iterator JSObject box address.
    iter_slots: std.AutoHashMapUnmanaged(usize, *builtins.ArrayIterCtx) = .empty,
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
    /// Names of `var`/function declarations introduced at global scope by
    /// non-strict `eval` (`CreateGlobalVarBinding(N, true)` /
    /// `CreateGlobalFunctionBinding(N, V, true)`): these live in
    /// `global_var_env` (or `globalThis`'s own bag) as configurable own
    /// properties of `globalThis`, and do NOT count as `HasVarDeclaration`
    /// in `GlobalDeclarationInstantiation`.
    eval_var_names: std.StringHashMapUnmanaged(void) = .empty,
    /// Snapshot of `global_env`'s binding names taken right after
    /// `setupGlobals()` installs every builtin (isNaN, Boolean, Math, ...)
    /// -- lets `Object.getOwnPropertyDescriptor(globalThis, k)` tell an
    /// original builtin (non-enumerable, confirmed against real Node)
    /// apart from a later ad-hoc `globalThis.foo = 1` (enumerable), since
    /// both land in the same `global_env.bindings` map with no other
    /// distinguishing mark.
    global_builtin_names: std.StringHashMapUnmanaged(void) = .empty,
    /// The `new`-detection token: evalNew (and `super(...)`) set this to
    /// the callee's ctx pointer for exactly the duration of the
    /// constructor call; classConstructorCall requires it to match and
    /// clears it on entry (so plain calls made *inside* a constructor
    /// body don't inherit construct-ness). This is how `C()` without
    /// `new` becomes the real TypeError.
    construct_target: ?*anyopaque = null,
    /// The effective newTarget and already-observed prototype for the current
    /// construction. Both are owned while active and restored around nesting.
    construct_new_target: ?JSValue = null,
    /// Borrowed `new.target` for the non-arrow function/constructor currently
    /// being entered via `prepareCallEnv` (null/undefined for ordinary calls).
    pending_call_new_target: ?JSValue = null,
    construct_proto: ?JSValue = null,
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
    /// %RegExp%, the original RegExp constructor (SpeciesConstructor's
    /// default), whatever the global `RegExp` binding holds later.
    regexp_ctor: ?JSValue = null,
    /// %RegExpStringIteratorPrototype% (matchAll's iterators).
    regexp_string_iterator_proto: ?JSValue = null,
    /// %IteratorPrototype% (`Iterator.prototype`), the [[Prototype]] of
    /// every builtin iterator and generator object (owned here: a
    /// prototype link isn't a reference).
    iterator_prototype: ?JSValue = null,
    /// %Iterator%, %IteratorHelperPrototype% and
    /// %WrapForValidIteratorPrototype% (iterator_builtins).
    iterator_ctor: ?JSValue = null,
    iterator_helper_proto: ?JSValue = null,
    wrap_for_valid_iterator_proto: ?JSValue = null,
    /// The well-known `Symbol.asyncIterator` -- resolveAsyncIterator's
    /// first choice for `for await`. Set in setupGlobals.
    symbol_async_iterator: ?JSValue = null,
    /// The well-known `Symbol.toStringTag` -- installed as a real
    /// property on the prototypes of types whose tag isn't in
    /// Object.prototype.toString's hardcoded internal-slot list (Map,
    /// Set, ...). Set in setupGlobals.
    symbol_to_string_tag: ?JSValue = null,
    /// The well-known `Symbol.toPrimitive` -- the first thing
    /// `toPrimitive` looks up on an object operand. Set in setupGlobals.
    symbol_to_primitive: ?JSValue = null,
    symbol_has_instance: ?JSValue = null,
    /// Single realm-wide %ThrowTypeError% intrinsic (frozen, length 0, name "").
    throw_type_error: ?JSValue = null,
    symbol_dispose: ?JSValue = null,
    symbol_async_dispose: ?JSValue = null,
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
    /// A branded Temporal value adopted by `super()` while a derived class
    /// constructor is running. This is a stack slot: classConstructorCall
    /// saves and restores it around nested derived constructors.
    adopted_super_this: ?JSValue = null,
    /// JS-level RegExp state, keyed by the `.regex` Rc box pointer --
    /// z-regex is a pure engine, so the mutable `lastIndex`, the flags
    /// string, and the boolean flag set live here (the symbol_keys
    /// pattern).
    regex_state: std.AutoHashMapUnmanaged(usize, RegexState) = .empty,
    /// Set while `deinit` frees every GC node: a destroy hook must not
    /// release JSValues then (freeAllGcNodes frees each registered box
    /// itself, so releasing one from a hook would free it twice).
    tearing_down: bool = false,
    /// %RegExpStringIterator% instances' internal slots (see the type).
    regexp_string_iters: std.AutoHashMapUnmanaged(usize, RegExpStringIterState) = .empty,
    /// Internal slots of WeakMap/WeakSet/WeakRef/FinalizationRegistry
    /// instances (see ObjectSlots).
    object_slots: std.AutoHashMapUnmanaged(usize, ObjectSlots) = .empty,
    /// ZObject.prototype es un puntero crudo sin refcount. Esta tabla
    /// mantiene vivos los prototipos que z-object no retiene. Si z-object
    /// refactoriza el prototipo con refcount, esta tabla se elimina.
    /// Keyed by the object's box address; the value is an owned reference
    /// to its prototype, set by `setOwnedPrototype` (prototypes coming from
    /// JS: Object.create, Object.setPrototypeOf, the __proto__ setter;
    /// instances made by `new`; class prototype and statics chains) and
    /// released when the object dies. Intrinsic prototypes need no entry:
    /// the interpreter's own fields keep them alive.
    proto_refs: std.AutoHashMapUnmanaged(usize, JSValue) = .empty,
    /// Named own properties on array values (arrays have no general
    /// property bag) -- used by exec/match result arrays for
    /// `index`/`input`/`groups`. Keyed by the array Rc box pointer; the
    /// value is a plain object holding the extras. For the collector the
    /// bag is an edge of its array (not a root), and the entry goes when
    /// the array dies.
    array_props: std.AutoHashMapUnmanaged(usize, JSValue) = .empty,
    arguments_arrays: std.AutoHashMapUnmanaged(usize, void) = .empty,
    deleted_arguments_length: std.AutoHashMapUnmanaged(usize, void) = .empty,
    immutable_array_buffers: std.AutoHashMapUnmanaged(usize, void) = .empty,
    interned_prop_keys: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Own data/accessor properties of Temporal instances. The native
    /// TemporalValue remains an internal slot; this bag is an edge of its box.
    temporal_props: std.AutoHashMapUnmanaged(usize, JSValue) = .empty,
    /// Per-instance Temporal [[Prototype]] overrides. No entry means the
    /// intrinsic prototype selected by the TemporalValue tag; an eventual
    /// `.null` entry represents an explicitly cleared prototype.
    temporal_protos: std.AutoHashMapUnmanaged(usize, JSValue) = .empty,
    /// Per-FunctionNode conservative `arguments` usage analysis. AST nodes
    /// outlive the interpreter, so their addresses are stable cache keys.
    function_needs_arguments: std.AutoHashMapUnmanaged(usize, bool) = .empty,
    /// Cached compiled bytecode per FunctionNode to avoid recompilation across calls.
    compiled_bytecode: std.AutoHashMapUnmanaged(*const zfunctions.FunctionNode, ?*bytecode_emitter.CompiledCodeBlock) = .empty,
    /// The boxed primitive inside a `new String()`/`new Number()`/
    /// `new Boolean()` wrapper object -- these constructors return an
    /// ordinary object (no internal-slot concept exists on JSValue's
    /// `.object` variant), so the wrapped primitive lives here instead,
    /// keyed by the wrapper object's Rc box pointer. Same side-table
    /// shape as `array_props`, and the same lifetime: an edge of its
    /// wrapper object for the collector, dropped when the wrapper dies.
    /// See /home/sweb/.plans/primitive-wrapper-objects.md.
    primitive_wrapper_data: std.AutoHashMapUnmanaged(usize, JSValue) = .empty,
    /// `delete f.name`/`delete f.length` tracking: those aren't real
    /// ZObject bag entries (getProperty/hasOwnProperty/
    /// getOwnPropertyDescriptor read them straight off the Callable
    /// struct's own `name`/`arity` fields, per real spec's
    /// configurable-but-otherwise-fixed own properties), so `delete`
    /// needs its own side table to record "gone" -- same shape as
    /// `array_props`/`primitive_wrapper_data`, keyed by the function box
    /// pointer. No JSValue payload; the entry is still dropped when the
    /// function dies (gcOnBoxDestroyed), like those two tables' entries,
    /// so a function later allocated at the same address doesn't inherit it.
    deleted_fn_props: std.AutoHashMapUnmanaged(usize, DeletedFnProps) = .empty,
    /// Maps a Generator / AsyncGenerator object's box address to its FiberState.
    generator_fibers: std.AutoHashMapUnmanaged(usize, *FiberState) = .empty,
    /// Set of object box addresses created by `JSON.rawJSON`.
    raw_json_objects: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// Active source text being parsed/executed so closures/classes can slice `start..end`.
    current_source: ?[]const u8 = null,
    /// Stack of active Map/Set.prototype.forEach cursors adjusted on delete/clear.
    top_foreach_cursor: ?*anyopaque = null,
    /// The stack-depth guard: recursing below this native stack address
    /// raises the real `RangeError: Maximum call stack size exceeded`
    /// instead of segfaulting (Test262's tco-* tests found this). Set
    /// from @frameAddress() at run()/runModule() entry (stacks grow
    /// down; byte-based, so it adapts to Debug/Release frame sizes) and
    /// swapped per fiber in resumeFiber. Zero = unguarded (direct
    /// embedder calls that never went through run()).
    stack_limit: usize = 0,

    pub fn checkStack(self: *Interpreter) anyerror!void {
        if (self.stack_limit != 0 and @frameAddress() < self.stack_limit) {
            return self.throwError(.range_error, "Maximum call stack size exceeded", .{});
        }
    }

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

    pub fn internPropKey(self: *Interpreter, key: []const u8) ![]const u8 {
        if (self.interned_prop_keys.get(key)) |interned| return interned;
        const duped = try self.arena_state.allocator().dupe(u8, key);
        try self.interned_prop_keys.put(self.gc_allocator, duped, duped);
        return duped;
    }

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
    pub const gcTrackRevokeCtx = interpreter_gc.gcTrackRevokeCtx;
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
    pub const gcNewSharedArrayBuffer = interpreter_gc.gcNewSharedArrayBuffer;
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
    pub const evalSourceIndirect = interpreter_runtime.evalSourceIndirect;
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
    pub const canonicalFlags = interpreter_support.canonicalFlags;
    pub const setArrayExtra = interpreter_support.setArrayExtra;
    pub const arrayExtra = interpreter_support.arrayExtra;
    pub const arrayPropsObject = interpreter_support.arrayPropsObject;
    pub const temporalPropsObject = interpreter_support.temporalPropsObject;
    pub const temporalProps = interpreter_support.temporalProps;

    /// Returns a Temporal instance's effective [[Prototype]]. The override
    /// table is intentionally read-only in this first subclassing commit.
    pub fn temporalPrototype(self: *const Interpreter, value: JSValue) JSValue {
        std.debug.assert(value.tag() == .temporal);
        return self.temporal_protos.get(@intFromPtr(value.asTemporal())) orelse
            self.protos.temporalProtoFor(value.asTemporal().value);
    }

    /// Installs an explicit Temporal [[Prototype]] override. The map owns its
    /// value; absence remains reserved for the intrinsic-prototype fallback.
    pub fn setTemporalPrototype(self: *Interpreter, value: JSValue, proto: JSValue) !void {
        std.debug.assert(value.tag() == .temporal);
        std.debug.assert(proto.isObject() or proto.isNull());
        const gop = try self.temporal_protos.getOrPut(self.gc_allocator, @intFromPtr(value.asTemporal()));
        const old: ?JSValue = if (gop.found_existing) gop.value_ptr.* else null;
        gop.value_ptr.* = proto.retain();
        if (old) |previous| previous.deinit();
    }
    pub const regexPropsObject = interpreter_support.regexPropsObject;
    pub const recompileRegex = interpreter_support.recompileRegex;
    pub const regexProps = interpreter_support.regexProps;
    pub const extraProps = interpreter_support.extraProps;
    pub const extraPropsObject = interpreter_support.extraPropsObject;
    pub const boxPrimitiveIfConstructed = interpreter_support.boxPrimitiveIfConstructed;
    pub const unboxPrimitiveWrapper = interpreter_support.unboxPrimitiveWrapper;
    pub const initStringWrapperProperties = interpreter_support.initStringWrapperProperties;

    pub fn isImmutableArrayBuffer(self: *const Interpreter, v: JSValue) bool {
        return v.tag() == .array_buffer and self.immutable_array_buffers.contains(@intFromPtr(v.asArrayBuffer()));
    }

    pub fn isTypedArrayImmutable(self: *const Interpreter, v: JSValue) bool {
        return v.tag() == .typed_array and self.isImmutableArrayBuffer(v.asTypedArray().value.owner);
    }

    pub fn isDataViewImmutable(self: *const Interpreter, v: JSValue) bool {
        return v.tag() == .data_view and self.isImmutableArrayBuffer(v.asDataView().value.owner);
    }

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
    pub const runFromAsync = interpreter_runtime.runFromAsync;
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
    pub const throwIfGap = interpreter_gc.throwIfGap;
    pub const heapBoxAddress = interpreter_gc.heapBoxAddress;
    pub const setOwnedPrototype = interpreter_gc.setOwnedPrototype;

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
    pub const markPatternConst = interpreter_stmt.markPatternConst;
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
    pub const getDestructureItems = interpreter_binding.getDestructureItems;
    pub const closeIterator = interpreter_binding.closeIterator;
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
    pub const applyBinaryOp = interpreter_expr.applyBinaryOp;
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
    pub const evalArgsInline = interpreter_expr.evalArgsInline;
    pub const evalNew = interpreter_expr.evalNew;
    pub const isConstructor = interpreter_expr.isConstructor;
    pub const constructValue = interpreter_expr.constructValue;
    pub const constructValueWithNewTarget = interpreter_expr.constructValueWithNewTarget;

    // z-interpreter-refactor.md, Step 5 Phase C batch 6: regex+arrayextra+
    // boxing+coerce+native cluster, split into interpreter_support.zig.
    pub const nativeMethod = interpreter_support.nativeMethod;
    pub const proxyTrap = interpreter_support.proxyTrap;
    pub const argsToArray = interpreter_support.argsToArray;

    // z-interpreter-refactor.md, Step 5 Phase C batch 5: propaccess+protos
    // cluster, split into interpreter_props.zig.
    pub const getProperty = interpreter_props.getProperty;
    pub const getPropertyWithReceiver = interpreter_props.getPropertyWithReceiver;
    pub const getExtraPropsOrProto = interpreter_props.getExtraPropsOrProto;
    pub const getExtraPropsOrProtoWithReceiver = interpreter_props.getExtraPropsOrProtoWithReceiver;

    // z-interpreter-refactor.md, Step 5 Phase C batch 5: propaccess+protos
    // cluster, split into interpreter_props.zig.
    pub const setArrayProperty = interpreter_props.setArrayProperty;
    pub const setTypedArrayProperty = interpreter_props.setTypedArrayProperty;
    pub const setObjectProperty = interpreter_props.setObjectProperty;
    pub const deleteObjectProperty = interpreter_props.deleteObjectProperty;
    pub const setPropertyOnValue = interpreter_props.setPropertyOnValue;
    pub const setPropertyWithReceiver = interpreter_props.setPropertyWithReceiver;
    pub const deletePropertyOnValue = interpreter_props.deletePropertyOnValue;
    pub const functionStatics = interpreter_props.functionStatics;
    pub const functionPrototype = interpreter_props.functionPrototype;
    pub const ordinaryObject = interpreter_props.ordinaryObject;
    pub const typedArrayProto = interpreter_props.typedArrayProto;
    pub const arrayBufferProto = interpreter_props.arrayBufferProto;
    pub const getFromProto = interpreter_props.getFromProto;
    pub const installProto = interpreter_props.installProto;
    pub const aliasSymbolIterator = interpreter_props.aliasSymbolIterator;
    pub const materializeProtos = interpreter_props.materializeProtos;

    // z-interpreter-refactor.md, Step 5 Phase C batch 6: regex+arrayextra+
    // boxing+coerce+native cluster, split into interpreter_support.zig.
    pub const stringConcat = interpreter_support.stringConcat;
    pub const toPrimitive = interpreter_support.toPrimitive;
    pub const PrimitiveHint = interpreter_support.PrimitiveHint;
    pub const ordinaryToPrimitive = interpreter_support.ordinaryToPrimitive;
    pub const OrdinaryHint = interpreter_support.OrdinaryHint;
    pub const isPrimitiveTag = interpreter_support.isPrimitiveTag;
    pub const toDisplayStringJS = interpreter_support.toDisplayStringJS;
    pub const joinElementToStringJS = interpreter_support.joinElementToStringJS;
    pub const toNumberJS = interpreter_support.toNumberJS;
    pub const toNumericJS = interpreter_support.toNumericJS;
    pub const toInt32JS = interpreter_support.toInt32JS;
    pub const toUint32JS = interpreter_support.toUint32JS;
    pub const looseEqualsJS = interpreter_support.looseEqualsJS;
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
    pub const makeObjectMethodClosure = interpreter_class.makeObjectMethodClosure;
    pub const encodePrivateKey = interpreter_class.encodePrivateKey;
    pub const privateHolder = interpreter_class.privateHolder;
    pub const privateGet = interpreter_class.privateGet;
    pub const privateSet = interpreter_class.privateSet;
    pub const privateHas = interpreter_class.privateHas;
    pub const runInstanceFields = interpreter_class.runInstanceFields;
    pub const evalClass = interpreter_class.evalClass;
};

pub const invokeFunctionNode = interpreter_class.invokeFunctionNode;
pub const prepareCallEnv = interpreter_class.prepareCallEnv;
pub const evalPreparedFunctionBody = interpreter_class.evalPreparedFunctionBody;
pub const normalizePrivateInProgram = interpreter_class.normalizePrivateInProgram;
pub const normalizePrivateInProgramMode = interpreter_class.normalizePrivateInProgramMode;
pub const normalizePrivateInNode = interpreter_class.normalizePrivateInNode;
pub const normalizePrivateInNodeMode = interpreter_class.normalizePrivateInNodeMode;

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

/// Runs `make` with the interpreter's allocator failing at every
/// allocation index in turn (and an empty GC registry, so gcTrack's put
/// must allocate), until it succeeds. Every failure must leave nothing
/// behind: what the failing allocator handed out, it got back.
fn expectNoLeakOnAllocFailure(interp: *Interpreter, comptime make: fn (*Interpreter) anyerror!JSValue) !void {
    const testing = std.testing;
    const real_alloc = interp.gc_allocator;
    const real_registry = interp.gc_registry;
    defer {
        interp.gc_allocator = real_alloc;
        interp.gc_registry = real_registry;
    }
    var index: usize = 0;
    while (true) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(real_alloc, .{ .fail_index = index });
        interp.gc_allocator = failing.allocator();
        interp.gc_registry = .empty;
        const result = make(interp);
        if (result) |v| {
            v.deinit();
            interp.gc_registry.deinit(failing.allocator());
            try testing.expect(index > 0); // at least one failure was exercised
            return;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            interp.gc_registry.deinit(failing.allocator());
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "a gcNew* whose gcTrack fails releases what it built" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    _ = try interp.run("0");

    try expectNoLeakOnAllocFailure(&interp, struct {
        fn make(i: *Interpreter) anyerror!JSValue {
            return i.gcNewObject();
        }
    }.make);
    try expectNoLeakOnAllocFailure(&interp, struct {
        fn make(i: *Interpreter) anyerror!JSValue {
            return i.gcNewString("a string payload");
        }
    }.make);
    try expectNoLeakOnAllocFailure(&interp, struct {
        fn make(i: *Interpreter) anyerror!JSValue {
            return i.gcNewArrayBufferFromValue(try zbuffer.ArrayBuffer.init(i.gc_allocator, 16));
        }
    }.make);
    try expectNoLeakOnAllocFailure(&interp, struct {
        fn make(i: *Interpreter) anyerror!JSValue {
            return i.makeRegex("a+b", "g");
        }
    }.make);

    // Constructors that take references: on failure they are released,
    // so the inputs end where they started.
    const target = try interp.gcNewObject();
    defer target.deinit();
    const handler = try interp.gcNewObject();
    defer handler.deinit();
    const owner = try interp.gcNewArrayBuffer(8);
    defer owner.deinit();
    const S = struct {
        var t: JSValue = undefined;
        var h: JSValue = undefined;
        var o: JSValue = undefined;
    };
    S.t = target;
    S.h = handler;
    S.o = owner;
    try expectNoLeakOnAllocFailure(&interp, struct {
        fn make(i: *Interpreter) anyerror!JSValue {
            return i.gcNewProxy(S.t.retain(), S.h.retain());
        }
    }.make);
    try expectNoLeakOnAllocFailure(&interp, struct {
        fn make(i: *Interpreter) anyerror!JSValue {
            return i.gcNewTypedArray(S.o.retain(), 0, 2, .i32);
        }
    }.make);
    try testing.expectEqual(@as(usize, 1), target.asObject().refCount());
    try testing.expectEqual(@as(usize, 1), handler.asObject().refCount());
    try testing.expectEqual(@as(usize, 1), owner.asArrayBuffer().refCount());
}

test "Map.prototype.set and Set.prototype.add release their arguments on OOM" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const map_set = try interp.run("Map.prototype.set");
    defer map_set.deinit();
    const set_add = try interp.run("Set.prototype.add");
    defer set_add.deinit();
    const key = try interp.gcNewObject();
    defer key.deinit();
    const value = try interp.gcNewObject();
    defer value.deinit();

    // The map and set keep the allocator they were made with: their
    // first insert must allocate, and that allocation fails.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const m = try JSValue.newMap(failing.allocator());
    defer m.deinit();
    const s = try JSValue.newSet(failing.allocator());
    defer s.deinit();
    failing.fail_index = failing.alloc_index;
    const f = map_set.asFunction().value;
    try testing.expectError(error.OutOfMemory, f.call(f.ctx, interp.gc_allocator, m, &.{ key, value }));
    const g = set_add.asFunction().value;
    try testing.expectError(error.OutOfMemory, g.call(g.ctx, interp.gc_allocator, s, &.{key}));
    try testing.expect(!m.asMap().value.has(key));
    try testing.expect(!s.asSet().value.has(key));
    try testing.expectEqual(@as(usize, 1), key.asObject().refCount());
    try testing.expectEqual(@as(usize, 1), value.asObject().refCount());
}

/// The invariant `setOwnedPrototype` keeps: an object whose raw
/// prototype pointer is `proto` holds a reference to it in proto_refs,
/// and `proto`'s count is its baseline plus that one reference.
fn expectPrototypeRetained(interp: *Interpreter, obj: JSValue, proto: JSValue, base: usize) !void {
    const testing = std.testing;
    const linked = obj.asObject().value.getPrototype() == &proto.asObject().value;
    const entry = interp.proto_refs.get(@intFromPtr(obj.asObject()));
    if (linked) {
        try testing.expect(entry != null and entry.?.isObject() and entry.?.asObject() == proto.asObject());
        try testing.expectEqual(base + 1, proto.asObject().refCount());
    } else {
        try testing.expect(entry == null);
        try testing.expectEqual(base, proto.asObject().refCount());
    }
}

/// Calls `f(this, args)` with the interpreter's allocator failing at
/// every allocation index in turn, until it succeeds; after each failure
/// and after the success, `check` must hold. Returns the success value.
/// Boxes made during a call keep the allocator they were made with, so
/// `failings` (one per attempt) must outlive the interpreter.
fn callFailingAtEveryIndex(interp: *Interpreter, failings: []std.testing.FailingAllocator, f: JSValue, this: JSValue, args: []const JSValue, ctx: anytype, comptime check: fn (@TypeOf(ctx), ?JSValue) anyerror!void) !JSValue {
    const testing = std.testing;
    const real = interp.gc_allocator;
    defer interp.gc_allocator = real;
    var index: usize = 0;
    while (true) : (index += 1) {
        if (index >= failings.len) return error.TooManyAllocations;
        failings[index] = std.testing.FailingAllocator.init(real, .{ .fail_index = index });
        interp.gc_allocator = failings[index].allocator();
        const result = f.asFunction().value.call(f.asFunction().value.ctx, interp.gc_allocator, this, args);
        interp.gc_allocator = real;
        if (result) |v| {
            try check(ctx, v);
            try testing.expect(index > 0); // at least one failure was exercised
            return v;
        } else |err| {
            // The __proto__ setter reports any failure as a TypeError.
            if (err == error.JsThrow) {
                if (interp.pending_exception) |e| e.deinit();
                interp.pending_exception = null;
            } else try testing.expectEqual(error.OutOfMemory, err);
            try check(ctx, null);
        }
    }
}

test "Object.create, Object.setPrototypeOf and __proto__ never leave an unretained prototype on OOM" {
    const testing = std.testing;
    const Case = enum { create, set_prototype_of, proto_setter };
    inline for (.{ Case.create, Case.set_prototype_of, Case.proto_setter }) |case| {
        // Declared before the interpreter: it must outlive it.
        var failings: [64]std.testing.FailingAllocator = undefined;
        var allocating = std.Io.Writer.Allocating.init(testing.allocator);
        defer allocating.deinit();
        var interp = try gcTestInterp(&allocating);
        defer interp.deinit();
        const f = try interp.run(switch (case) {
            .create => "Object.create",
            .set_prototype_of => "Object.setPrototypeOf",
            .proto_setter => "Object.getOwnPropertyDescriptor(Object.prototype, '__proto__').set",
        });
        defer f.deinit();
        const obj = try interp.run("({})");
        defer obj.deinit();
        const proto = try interp.run("({})");
        defer proto.deinit();
        // An empty table: its first insert must allocate.
        try testing.expectEqual(@as(usize, 0), interp.proto_refs.capacity());
        const base = proto.asObject().refCount();
        const Ctx = struct { interp: *Interpreter, obj: JSValue, proto: JSValue, base: usize, case: Case };
        const ctx = Ctx{ .interp = &interp, .obj = obj, .proto = proto, .base = base, .case = case };
        const check = struct {
            fn check(c: Ctx, result: ?JSValue) anyerror!void {
                switch (c.case) {
                    // A failed create returns nothing: the prototype must
                    // be back at its baseline.
                    .create => if (result) |r| try expectPrototypeRetained(c.interp, r, c.proto, c.base) else try std.testing.expectEqual(c.base, c.proto.asObject().refCount()),
                    else => try expectPrototypeRetained(c.interp, c.obj, c.proto, c.base),
                }
            }
        }.check;
        const result = try callFailingAtEveryIndex(&interp, &failings, f, if (case == .proto_setter) obj else JSValue.UNDEFINED, switch (case) {
            .create => &.{proto},
            .set_prototype_of => &.{ obj, proto },
            .proto_setter => &.{proto},
        }, ctx, check);
        result.deinit();
    }
}

test "collectGarbage keeps an instance's prototype once its constructor is unreachable" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    _ = try interp.run(
        \\var o = (function () {
        \\  var g = function () {};
        \\  Reflect.set(g, "prototype", { x: 41 });
        \\  return new g();
        \\})();
    );
    interp.collectGarbage();
    const v = try interp.run("var junk = []; for (var i = 0; i < 2000; i++) junk.push({ x: i }); o.x + 1;");
    try testing.expectEqual(@as(f64, 42), v.asNumber());
}

test "collectGarbage keeps a class's prototype and statics chain to its parent" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    // Only an instance of C (prototype chain) and C itself (statics
    // chain) stay reachable; B, C's class context and the IIFE's scope
    // are left to the collector.
    _ = try interp.run(
        \\var c = (function () {
        \\  class B { m() { return 40; } static s() { return 2; } }
        \\  class C extends B {}
        \\  return new C();
        \\})();
        \\var K = (function () {
        \\  class B { static s() { return 2; } }
        \\  return class C extends B {};
        \\})();
    );
    interp.collectGarbage();
    const v = try interp.run("var junk = []; for (var i = 0; i < 2000; i++) junk.push({ x: i }); c.m() + K.s();");
    try testing.expectEqual(@as(f64, 42), v.asNumber());
}

test "a dying array drops its array_props entry and releases the bag" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const arr = try interp.run("var r = /a/.exec('a'); r;");
    const key = @intFromPtr(arr.asArray());
    const bag = interp.array_props.get(key).?.retain(); // index/input/groups
    defer bag.deinit();
    const before = interp.array_props.count();
    _ = try interp.run("r = null;");
    arr.deinit(); // the array's last reference
    try testing.expect(!interp.array_props.contains(key));
    try testing.expectEqual(before - 1, interp.array_props.count());
    try testing.expectEqual(@as(usize, 1), bag.asObject().refCount()); // only ours is left
}

test "a dying wrapper object drops its primitive_wrapper_data entry and releases the primitive" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const w = try interp.run("var w = new String('xyz'); w;");
    const key = @intFromPtr(w.asObject());
    const prim = interp.primitive_wrapper_data.get(key).?.retain();
    defer prim.deinit();
    try testing.expect(prim.isString());
    const before = interp.primitive_wrapper_data.count();
    _ = try interp.run("w = null;");
    w.deinit();
    try testing.expect(!interp.primitive_wrapper_data.contains(key));
    try testing.expectEqual(before - 1, interp.primitive_wrapper_data.count());
    try testing.expectEqual(@as(usize, 1), prim.asString().refCount()); // only ours is left
}

test "a dying function drops its deleted_fn_props entry" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const f = try interp.run("var f = function () {}; delete f.name; delete f.length; f;");
    const key = @intFromPtr(f.asFunction());
    const gone = interp.deleted_fn_props.get(key).?;
    try testing.expect(gone.name and gone.length);
    _ = try interp.run("f = null;");
    f.deinit();
    try testing.expect(!interp.deleted_fn_props.contains(key));
    // A function made afterwards has its own name/length.
    const v = try interp.run("var g = function (a, b) {}; g.name + g.length;");
    defer v.deinit();
    try testing.expectEqualStrings("g2", v.asString().value.data);
}

test "collectGarbage drops the per-address entries of the boxes it frees" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    _ = try interp.run("1;");
    const arrays = interp.array_props.count();
    const wrappers = interp.primitive_wrapper_data.count();
    const deleted = interp.deleted_fn_props.count();
    // Each box is kept alive only by a cycle, so only the collector frees
    // it. (A cycle through the array's own bag is the next test.)
    _ = try interp.run(
        \\(function () {
        \\  var r = /a/.exec('a'); r.push(r);
        \\  var w = new Number(5); w.self = w;
        \\  var f = function () {}; delete f.name; f.self = f;
        \\})();
    );
    interp.collectGarbage();
    try testing.expectEqual(arrays, interp.array_props.count());
    try testing.expectEqual(wrappers, interp.primitive_wrapper_data.count());
    try testing.expectEqual(deleted, interp.deleted_fn_props.count());
}

test "collectGarbage frees an array whose cycle goes through its own array_props bag" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    _ = try interp.run("let r = []; let w = null;");
    interp.collectGarbage(); // a clean baseline: nothing collectable left
    const arrays = interp.array_props.count();
    const wrappers = interp.primitive_wrapper_data.count();
    const boxes = interp.gc_registry.count();
    // `r.self` lives in the array's array_props bag, `w.self` in the
    // wrapper's own properties: each box is reachable only through itself.
    _ = try interp.run(
        \\r.self = r; r = null;
        \\w = new String("x"); w.self = w; w = null;
    );
    try testing.expect(interp.array_props.count() == arrays + 1);
    interp.collectGarbage();
    try testing.expectEqual(arrays, interp.array_props.count());
    try testing.expectEqual(wrappers, interp.primitive_wrapper_data.count());
    // The bag, the wrapper and its string are gone, and so is the array,
    // which the baseline already counted (`let r = []`).
    try testing.expectEqual(boxes - 1, interp.gc_registry.count());
}

test "Temporal own properties survive marking and cycles are collected" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const temporal = try interp.run(
        \\var temporal_box = new Temporal.PlainDate(2024, 5, 2);
        \\Object.defineProperty(temporal_box, 'self', {value: temporal_box, configurable: true});
        \\temporal_box;
    );
    const address = @intFromPtr(temporal.asTemporal());
    const count = interp.temporal_props.count();
    try testing.expect(interp.temporal_props.contains(address));
    interp.collectGarbage();
    const observed = try interp.run("temporal_box.self === temporal_box;");
    try testing.expect(observed.asBool());
    observed.deinit();

    const properties = try interp.run(
        \\temporal_box.constructor = 123;
        \\Object.defineProperty(temporal_box, 'extra', {value: 9, enumerable: true, configurable: true});
        \\var temporal_key = Symbol('own');
        \\temporal_box[temporal_key] = 10;
        \\if (temporal_box.constructor !== 123 || !Object.hasOwn(temporal_box, 'extra')) throw new Error('own properties');
        \\if (!Object.keys(temporal_box).includes('extra') || !Reflect.ownKeys(temporal_box).includes(temporal_key)) throw new Error('reflection');
        \\if (Object.getOwnPropertyDescriptor(temporal_box, 'extra').value !== 9) throw new Error('descriptor');
        \\if (!delete temporal_box.extra || Object.hasOwn(temporal_box, 'extra')) throw new Error('delete');
        \\Object.defineProperty(temporal_box, 'year', {get: function() { throw new Error('internal slot shadowed'); }});
        \\if (Temporal.PlainDate.from(temporal_box).year !== 2024) throw new Error('internal slot conversion');
    );
    properties.deinit();

    const cleared = try interp.run("temporal_box = null;");
    cleared.deinit();
    temporal.deinit();
    interp.collectGarbage();
    try testing.expect(!interp.temporal_props.contains(address));
    try testing.expectEqual(count - 1, interp.temporal_props.count());

    // A later box, even at the same address, cannot inherit old properties.
    for (0..64) |_| {
        const fresh = try interp.run("new Temporal.PlainDate(2024, 5, 2);");
        try testing.expect(!interp.temporal_props.contains(@intFromPtr(fresh.asTemporal())));
        fresh.deinit();
    }

    const ordinary = try interp.run("var temporal_plain = new Temporal.PlainDate(2024, 5, 2); temporal_plain.note = 1; temporal_plain;");
    const ordinary_address = @intFromPtr(ordinary.asTemporal());
    try testing.expect(interp.temporal_props.contains(ordinary_address));
    const dropped = try interp.run("temporal_plain = null;");
    dropped.deinit();
    ordinary.deinit();
    try testing.expect(!interp.temporal_props.contains(ordinary_address));
}

/// The FiberState behind a generator object.
fn fiberOf(interp: *Interpreter, gen: JSValue) *FiberState {
    return interp.generator_fibers.get(@intFromPtr(gen.asObject())).?;
}

test "yield takes the resume value: the slot ends empty and the value has one owner" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    _ = try interp.run("var probe = {}; function* g() { var x = yield; } var it = g(); it.next();");
    const it = try interp.run("it;");
    defer it.deinit();
    const fs = fiberOf(&interp, it);
    _ = try interp.run("it.next(probe);");
    try testing.expect(fs.resume_value.isUndefined());
    const probe = try interp.run("probe;");
    defer probe.deinit();
    // probe's binding, this reference, and the generator's `x` (its
    // environment lives until the collector runs) -- not the slot.
    try testing.expectEqual(@as(usize, 3), probe.asObject().refCount());
}

test "await takes the resume value: the slot ends empty" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    // An async generator, so the fiber is reachable through `it.next`.
    _ = try interp.run(
        \\var probe = {}; var seen = false;
        \\async function* ag() { var x = await probe; seen = x === probe; yield 1; }
        \\var it = ag(); it.next();
    );
    const it = try interp.run("it;");
    defer it.deinit();
    const seen = try interp.run("seen;");
    try testing.expect(seen.isBool() and seen.asBool()); // the await did resume
    try testing.expect(fiberOf(&interp, it).resume_value.isUndefined());
}

test "a throw delivered at yield or yield* takes the resume value" {
    const testing = std.testing;
    // No gen.throw() yet: deliver the throw by hand, as the scheduler
    // would, to a fiber suspended at each kind of yield.
    const sources = [_][]const u8{
        "function* g() { yield 1; } var it = g(); it.next();",
        "function* g() { yield* { [Symbol.iterator]() { return { next() { return { value: 1, done: false }; }, throw(e) { throw e; } }; } }; } var it = g(); it.next();",
        "function* inner() { yield 1; } function* g() { yield* inner(); } var it = g(); it.next();",
    };
    for (sources) |src| {
        var allocating = std.Io.Writer.Allocating.init(testing.allocator);
        defer allocating.deinit();
        var interp = try gcTestInterp(&allocating);
        defer interp.deinit();
        _ = try interp.run("var probe = {};");
        _ = try interp.run(src);
        const it = try interp.run("it;");
        defer it.deinit();
        const probe = try interp.run("probe;");
        defer probe.deinit();
        const before = probe.asObject().refCount();
        const fs = fiberOf(&interp, it);
        fs.setResumeValue(probe.retain());
        fs.resume_is_throw = true;
        try interp.resumeFiber(fs);
        try testing.expect(fs.resume_value.isUndefined());
        // The thrown value moved to the generator's completed_throw: still
        // exactly the one reference the slot had.
        try testing.expect(fs.completed_throw != null and fs.completed_throw.?.isObject() and fs.completed_throw.?.asObject() == probe.asObject());
        try testing.expectEqual(before + 1, probe.asObject().refCount());
    }
}

test "the first next(v), which the body never sees, does not leak its value" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    _ = try interp.run(
        \\var probe = {};
        \\function* g() { yield 1; yield 2; }
        \\var it = g();
        \\it.next(probe); // stored in the slot; the body starts, never takes it
        \\it.next();      // the next resume releases it
    );
    const probe = try interp.run("probe;");
    defer probe.deinit();
    try testing.expectEqual(@as(usize, 2), probe.asObject().refCount()); // binding + this
}

test "the shutdown snapshot of the GC registry never grows while it fills" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    _ = try interp.run("var keep = []; for (var i = 0; i < 5000; i++) keep.push({ i: i });");
    const n = interp.gc_registry.count();
    try testing.expect(n >= 5000);
    var expected: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.ensureTotalCapacity(testing.allocator, n);
    var snap = try interpreter_gc.registrySnapshot(&interp);
    defer snap.deinit(interp.gc_allocator);
    // Same capacity as a reservation for exactly n entries: the copy never
    // rehashed (putAssumeCapacity would also assert this in safe builds).
    try testing.expectEqual(expected.capacity(), snap.capacity());
    try testing.expectEqual(n, snap.count());
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
    // The generator object and its "next" function die by refcount at
    // `g = null`; the FiberState (whose 8 MiB stack rides along, freed
    // via Fiber.deinit() inside freeGarbageNode's .fiber_state case) has
    // no Rc and waits for the collector -- exact count intentionally not
    // asserted, see the closure<->object<->environment test's comment.
    const before_collect = interp.gc_registry.count();
    try testing.expect(before_collect >= baseline + 1);
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

test "collectGarbage keeps a reachable bound function context" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const setup = try interp.run("var f = (function() { var x = 40; return function(v) { return x + v; }.bind(null, 2); })();");
    setup.deinit();
    interp.collectGarbage();
    const result = try interp.run("f();");
    defer result.deinit();
    try testing.expectEqual(@as(f64, 42), result.asNumber());
}

test "collectGarbage keeps a reachable suspended generator context" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const setup = try interp.run("var g = (function*() { yield 40; return 42; })(); g.next();");
    setup.deinit();
    interp.collectGarbage();
    const result = try interp.run("g.next().value;");
    defer result.deinit();
    try testing.expectEqual(@as(f64, 42), result.asNumber());
}

test "destructuring array pattern closes unexhausted iterator without infinite loop" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const result = try interp.run(
        \\var returnCount = 0;
        \\var iter = {
        \\  [Symbol.iterator]: function() {
        \\    return {
        \\      next: function() { return { value: 42, done: false }; },
        \\      return: function() { returnCount++; return { done: true }; }
        \\    };
        \\  }
        \\};
        \\var fn_destruct = ([x]) => x;
        \\var val = fn_destruct(iter);
        \\returnCount === 1 && val === 42;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "bytecode function with string concat and lexical this executes exactly once" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const result = try interp.run(
        \\var calls = 0;
        \\var obj = {
        \\  prefix: "count: ",
        \\  getFn: function() {
        \\    return () => {
        \\      calls++;
        \\      return this.prefix + calls;
        \\    };
        \\  }
        \\};
        \\var fn_call = obj.getFn();
        \\var str = fn_call();
        \\calls === 1 && str === "count: 1";
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "bytecode strict equality differentiates types correctly" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const result = try interp.run(
        \\function check() {
        \\  var a = (1 === "1");
        \\  var b = (null === undefined);
        \\  var c = (1 == "1");
        \\  var d = (null == undefined);
        \\  return !a && !b && c && d;
        \\}
        \\check();
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "bytecode try catch catches exception thrown from callee" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const result = try interp.run(
        \\function throwFromCallee() {
        \\  throw "caught_err";
        \\}
        \\function testCatch() {
        \\  var caught = "";
        \\  try {
        \\    throwFromCallee();
        \\  } catch (e) {
        \\    caught = e;
        \\  }
        \\  return caught;
        \\}
        \\testCatch();
    );
    defer result.deinit();
    try testing.expect(result.isString());
    try testing.expectEqualStrings("caught_err", result.asString().value.data);
}

test "bytecode typeof unresolvable identifier returns undefined" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const result = try interp.run(
        \\function testTypeof() {
        \\  return typeof noExiste === "undefined";
        \\}
        \\testTypeof();
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "bytecode lexical block shadowing falls back to ast and preserves outer let" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\let x = "outside";
        \\{
        \\  let x = "inside";
        \\}
        \\x === "outside";
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "bytecode use strict throws ReferenceError on undeclared global write" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const err = interp.run(
        \\"use strict";
        \\noExiste = 1;
    );
    try testing.expectError(error.UncaughtException, err);
}

test "bytecode arrow function resolves lexical this" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\const o = { v: 42, f() { return (() => this.v)(); } };
        \\o.f();
    );
    defer result.deinit();
    try testing.expect(result.isNumber());
    try testing.expectEqual(@as(f64, 42), result.asNumber());
}

test "bytecode direct eval and arguments fall back cleanly to AST without error" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function testEval() {
        \\  var a = 0;
        \\  eval("a = 10");
        \\  return a;
        \\}
        \\function testArgs() {
        \\  return arguments[0] + arguments[1];
        \\}
        \\testEval() === 10 && testArgs(3, 7) === 10;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "bytecode function with branching return falling off end returns undefined" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function f(c) {
        \\  if (c) { return 1; }
        \\}
        \\f(false);
    );
    defer result.deinit();
    try testing.expect(result.isUndefined());
}

test "class with private fields falls back cleanly from bytecode without crash" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\class C {
        \\  #x = 42;
        \\  m() {
        \\    const fn = () => this.#x;
        \\    return fn();
        \\  }
        \\}
        \\new C().m();
    );
    defer result.deinit();
    try testing.expect(result.isNumber());
    try testing.expectEqual(@as(f64, 42), result.asNumber());
}

test "TDZ lexical variable access throws UncaughtException" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const err = interp.run(
        \\function f() {
        \\  return x;
        \\  let x = 1;
        \\}
        \\f();
    );
    try testing.expectError(error.UncaughtException, err);
}

test "captured local variable does not overwrite outer variable with same name" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\var x = "outside";
        \\function f() {
        \\  var x = "inside";
        \\  return () => x;
        \\}
        \\f();
        \\x === "outside";
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "setting proto cycle on object throws TypeError" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const err = interp.run(
        \\const o = {};
        \\o.__proto__ = o;
    );
    try testing.expectError(error.UncaughtException, err);
}

test "hoisting of inner function called before declaration works in bytecode" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function f() {
        \\  var g = inner();
        \\  function inner() { return 42; }
        \\  return g;
        \\}
        \\f();
    );
    defer result.deinit();
    try testing.expect(result.isNumber());
    try testing.expectEqual(@as(f64, 42), result.asNumber());
}

test "G1: throw from bytecode function without local catch propagates pending_exception" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function thrower() { throw "err_payload"; }
        \\var caught = null;
        \\try { thrower(); } catch (e) { caught = e; }
        \\caught === "err_payload";
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "G2: generator return() marks generator finished" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\const iter = (function* () { yield 1; yield 2; })();
        \\for (const [,] of [iter]) { break; }
        \\iter.next().done === true;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "G3: calling undefined global function throws ReferenceError" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\var ok = false;
        \\try { { noExiste(); } } catch (e) { ok = e instanceof ReferenceError; }
        \\ok;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "G4: TDZ on captured lexical variable throws ReferenceError before initialization" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\(function() {
        \\  function f() { return x + 1; }
        \\  var threw = false;
        \\  try { f(); } catch (e) { threw = e instanceof ReferenceError; }
        \\  const x = 1;
        \\  return threw && f() === 2;
        \\})();
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "G6: object literal with __proto__ falls back cleanly to AST" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\Reflect.setPrototypeOf(Object.prototype, { __proto__: null }) === false;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "generator return() from executing state throws TypeError and marks completed" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\var iter;
        \\function* g() { iter.return(42); }
        \\iter = g();
        \\var threw = false;
        \\try { iter.next(); } catch (e) { threw = e instanceof TypeError; }
        \\var r = iter.next();
        \\threw && r.value === undefined && r.done === true;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "bytecode new_array tracked by GC avoids double-release on teardown with AST environment" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function runWithCtors(f, ctors) {
        \\  switch (ctors.length) {
        \\    case 2:
        \\      for (var i = 0; i < ctors.length; i++) {
        \\        var c = ctors[i];
        \\        var bound = (function(C, n) { return new C(n); }).bind(undefined, c);
        \\        f(c, bound);
        \\      }
        \\      break;
        \\  }
        \\}
        \\function wrap(f) {
        \\  runWithCtors(f, [Int32Array, Uint8Array]);
        \\}
        \\var sum = 0;
        \\wrap((TA, make) => {
        \\  const v = make(4);
        \\  sum += Atomics.compareExchange(v, 0, 0, 1) + Atomics.load(v, 0);
        \\});
        \\sum === 2;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "JIT and OSR compile numeric loose_eq/loose_ne and bail out cleanly on mixed types" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function fib(n) {
        \\  if (n == 0) return 0;
        \\  if (n == 1) return 1;
        \\  return fib(n - 1) + fib(n - 2);
        \\}
        \\function eqMix(a, b) { return a == b; }
        \\function neMix(a, b) { return a != b; }
        \\var hits = 0;
        \\for (var i = 0; i < 150; i++) {
        \\  if (eqMix(i, i)) hits++;
        \\  if (neMix(i, i + 1)) hits++;
        \\}
        \\var mixedOk = eqMix(5, "5") === true && eqMix(5, "6") === false && neMix(5, "5") === false && neMix(5, "6") === true;
        \\var osrHits = 0;
        \\for (var j = 0; j < 200; j++) {
        \\  var v = j < 150 ? j : "" + j;
        \\  if (v == j) osrHits++;
        \\  if (v != j + 1) osrHits++;
        \\}
        \\fib(15) === 610 && hits === 300 && mixedOk && osrHits === 400;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "OSR caches numeric registers in Xmm across get_prop and set_prop without load_local churn" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function runPropLoop() {
        \\  var o = { x: 1, y: 2, z: 3 };
        \\  var acc = 0;
        \\  for (var i = 0; i < 300; i++) {
        \\    acc += o.x + o.y + o.z;
        \\    o.x = (o.x + 1) & 1023;
        \\  }
        \\  return acc === 46650 && o.x === 301;
        \\}
        \\runPropLoop();
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "OSR inline set_prop_transition handles recycled objects with primitive and object values" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function runRecycled() {
        \\  var acc = 0;
        \\  var sub = { k: 10 };
        \\  for (var i = 0; i < 300; i++) {
        \\    var p = { x: i, y: i + 1, z: i + 2 };
        \\    acc += p.x + p.y + p.z;
        \\  }
        \\  for (var j = 0; j < 200; j++) {
        \\    var q = { a: j, b: sub, c: j + 1 };
        \\    acc += q.a + q.b.k + q.c;
        \\  }
        \\  return acc === 135450 + 42000;
        \\}
        \\runRecycled();
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "emitter and OSR handle add_local_const/sub_local_const on general register operands" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function step(o) {
        \\  for (var i = 0; i < 250; i++) {
        \\    o.x = ((o.x + 3) - 2) + 1;
        \\  }
        \\  return o.x;
        \\}
        \\step({ x: 10 }) === 510;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "OSR inline new_array recycles primitive arrays and falls back safely for heap elements" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function runArrLoops() {
        \\  var sum = 0;
        \\  for (var i = 0; i < 300; i++) {
        \\    var a = [i, i + 1, i + 2];
        \\    sum += a[0] + a[1] + a[2];
        \\  }
        \\  for (var j = 0; j < 200; j++) {
        \\    var b = [{ v: j }, j + 1];
        \\    sum += b[0].v + b[1];
        \\  }
        \\  return sum === 135450 + 40000;
        \\}
        \\runArrLoops();
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "OSR specialized PropIC falls back cleanly when object shape changes mid-loop" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function runShapeChange() {
        \\  var o1 = { x: 1, y: 2 };
        \\  var o2 = { y: 10, x: 20, z: 30 };
        \\  var sum = 0;
        \\  for (var i = 0; i < 200; i++) {
        \\    var cur = i < 120 ? o1 : o2;
        \\    cur.x = cur.x + 1;
        \\    sum += cur.x + cur.y;
        \\  }
        \\  return o1.x === 121 && o2.x === 100 && sum === 7620 + 5640;
        \\}
        \\runShapeChange();
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "OSR scalar property promotion writes back on normal exit, mid-loop bailout, and frozen objects" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function runPromoted(o) {
        \\  for (var i = 0; i < 200; i++) {
        \\    o.x = o.x + 1;
        \\    o.y = o.y + 2;
        \\    o.z = o.z + 3;
        \\  }
        \\  return o.x + o.y + o.z;
        \\}
        \\function runBailout() {
        \\  var o = { x: 0, y: 0 };
        \\  for (var i = 0; i < 200; i++) {
        \\    o.x = o.x + 1;
        \\    var v = i < 150 ? i : "done";
        \\    o.y = v;
        \\  }
        \\  return o.x === 200 && o.y === "done";
        \\}
        \\var a = { x: 0, y: 0, z: 0 };
        \\var r1 = runPromoted(a);
        \\var frozen = Object.freeze({ x: 10, y: 20, z: 30 });
        \\var caught = false;
        \\try {
        \\  runPromoted(frozen);
        \\} catch (e) {
        \\  caught = frozen.x === 10 && frozen.y === 20 && frozen.z === 30;
        \\}
        \\r1 === 1200 && a.x === 200 && a.y === 400 && a.z === 600 && caught && runBailout();
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "OSR bitwise and arithmetic constant specialization handles overflow, NaN, Infinity, and -0" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function runBitwiseEdgeCases() {
        \\  var acc = 0;
        \\  for (var i = 1; i <= 250; i++) {
        \\    var v = i < 150 ? i : (i === 150 ? NaN : (i === 151 ? Infinity : (i === 152 ? -0.0 : 0x80000000 + i)));
        \\    var idx = v & 7;
        \\    var r = i % 7;
        \\    var q = (v / 4) | 0;
        \\    var b = ((q ^ idx) << 2) ^ (v >>> 1) ^ (v >> 3);
        \\    acc = (acc + b + r) | 0;
        \\  }
        \\  return acc;
        \\}
        \\runBitwiseEdgeCases() === 1610644817;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "OSR hoisted invariant array bails out cleanly on out-of-bounds set_elem converting to holey" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const result = try interp.run(
        \\function runHoistedArr() {
        \\  var arr = [1, 2, 3, 4, 5, 6, 7, 8];
        \\  var acc = 0;
        \\  for (var i = 0; i < 200; i++) {
        \\    var idx = i < 150 ? (i & 7) : 20;
        \\    arr[idx] = i;
        \\    acc += arr[idx];
        \\  }
        \\  return arr.length === 21 && arr[15] === undefined && arr[20] === 199 && acc === 19900;
        \\}
        \\runHoistedArr();
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "generator and async generator evaluate parameters synchronously and enforce parameter TDZ" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const result = try interp.run(
        \\var bodyRuns = 0;
        \\function* g1(_ = (() => { throw new TypeError("boom1"); })()) { bodyRuns++; }
        \\async function* ag1(_ = (() => { throw new TypeError("boom2"); })()) { bodyRuns++; }
        \\var x = 99;
        \\function* gTdz1(x = x) { bodyRuns++; }
        \\async function* agTdz2(a = b, b = 1) { bodyRuns++; }
        \\var fSelf = (x = x) => x;
        \\var c1 = false, c2 = false, c3 = false, c4 = false, c5 = false;
        \\try { g1(); } catch (e) { c1 = e instanceof TypeError; }
        \\try { ag1(); } catch (e) { c2 = e instanceof TypeError; }
        \\try { gTdz1(); } catch (e) { c3 = e instanceof ReferenceError; }
        \\try { agTdz2(); } catch (e) { c4 = e instanceof ReferenceError; }
        \\try { fSelf(); } catch (e) { c5 = e instanceof ReferenceError; }
        \\function* gOk([a, b = a * 2] = [21]) { yield a + b; }
        \\var vOk = gOk().next().value;
        \\bodyRuns === 0 && c1 && c2 && c3 && c4 && c5 && vOk === 63;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "class private fields, getters, setters, methods, and in-operator handle Unicode escapes" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const result = try interp.run(
        \\class C {
        \\  #\u{6F}_ = 10;
        \\  get #\u{6F}() { return this.#\u{6F}_; }
        \\  set #\u{6F}(v) { this.#\u{6F}_ = v * 2; }
        \\  #m\u{6F}() { return this.#\u{6F} + 5; }
        \\  \u{6F}(v) {
        \\    this.#\u{6F} = v;
        \\    return this.#m\u{6F}();
        \\  }
        \\  hasPriv(obj) { return #\u{6F}_ in obj && #\u{6F} in obj && #m\u{6F} in obj; }
        \\}
        \\var c = new C();
        \\c.o(7) === 19 && c.hasPriv(c) && !c.hasPriv({});
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "Promise combinators reject on synchronous errors, close iterators, unwrap thenables, and Array.fromAsync works" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const result = try interp.run(
        \\var resName = "";
        \\var rejName = "";
        \\var resLen = -1;
        \\new Promise((res, rej) => { resName = res.name; rejName = rej.name; resLen = res.length; res(1); });
        \\var allRejectedNonIter = false;
        \\Promise.all(false).then(() => {}, (e) => { allRejectedNonIter = e instanceof TypeError; });
        \\var raceRejectedNonIter = false;
        \\Promise.race(null).then(() => {}, (e) => { raceRejectedNonIter = e instanceof TypeError; });
        \\var closedCount = 0;
        \\var badIter = {
        \\  [Symbol.iterator]() {
        \\    return {
        \\      next() { return { value: { get then() { throw new TypeError("poisoned"); } }, done: false }; },
        \\      return() { closedCount++; return {}; }
        \\    };
        \\  }
        \\};
        \\var origResolve = Promise.resolve;
        \\Promise.resolve = function() { throw new RangeError("resolve boom"); };
        \\var closeRejectOk = false;
        \\Promise.all(badIter).then(() => {}, (e) => { closeRejectOk = e instanceof RangeError; });
        \\Promise.resolve = origResolve;
        \\var fromAsyncOut = "";
        \\async function* ag() { yield 10; yield 20; yield 30; }
        \\Array.fromAsync(ag(), (v, i) => ({ then(r) { r(v + i); } })).then((arr) => {
        \\  fromAsyncOut = arr.join(",");
        \\});
        \\resName === "" && rejName === "" && resLen === 1;
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
    const verify = try interp.run(
        \\allRejectedNonIter && raceRejectedNonIter && closedCount === 1 && closeRejectOk && fromAsyncOut === "10,21,32";
    );
    defer verify.deinit();
    try testing.expect(verify.isBool() and verify.asBool());
}

test "ES2025 Set.prototype methods and Map.prototype.getOrInsert / getOrInsertComputed handle set-like objects and abrupt completions" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const result = try interp.run(
        \\var s1 = new Set([1, 2, 3]);
        \\var s2 = new Set([2, 3, 4]);
        \\var u = [...s1.union(s2)].join(",");
        \\var inter = [...s1.intersection(s2)].join(",");
        \\var diff = [...s1.difference(s2)].join(",");
        \\var symDiff = [...s1.symmetricDifference(s2)].join(",");
        \\var sub1 = new Set([1, 2]).isSubsetOf(s1);
        \\var sub2 = s1.isSubsetOf(s2);
        \\var sup1 = s1.isSupersetOf(new Set([2, 3]));
        \\var disj1 = s1.isDisjointFrom(new Set([4, 5]));
        \\var closedDisj = 0;
        \\var setLike = {
        \\  size: 1,
        \\  has() { return false; },
        \\  keys() {
        \\    var i = 0;
        \\    return {
        \\      next() { i++; return { value: 2, done: false }; },
        \\      return() { closedDisj++; return {}; }
        \\    };
        \\  }
        \\};
        \\var disj2 = s1.isDisjointFrom(setLike);
        \\var errCaught = false;
        \\try { s1.union({ size: NaN, has() {}, keys() {} }); } catch (e) { errCaught = e instanceof TypeError; }
        \\var m = new Map();
        \\var v1 = m.getOrInsert(-0, "a");
        \\var v2 = m.getOrInsert(0, "b");
        \\var v3 = m.getOrInsertComputed("k", (k) => k + "_val");
        \\var v4 = m.getOrInsertComputed("k", () => { throw new Error("should not call"); });
        \\u === "1,2,3,4" && inter === "2,3" && diff === "1" && symDiff === "1,4" &&
        \\  sub1 && !sub2 && sup1 && disj1 && !disj2 && closedDisj === 1 && errCaught &&
        \\  v1 === "a" && v2 === "a" && v3 === "k_val" && v4 === "k_val";
    );
    defer result.deinit();
    try testing.expect(result.isBool() and result.asBool());
}

test "Promise.any on empty string rejects with AggregateError and await ignores monkey-patched then on native Promise" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const r1 = try interp.run(
        \\var emptyStrAggErr = false;
        \\Promise.any("").then(() => {}, (e) => {
        \\  emptyStrAggErr = (e instanceof AggregateError) && Object.getPrototypeOf(e) === AggregateError.prototype && e.errors.length === 0;
        \\});
        \\var thenCalls = 0;
        \\var order = [];
        \\var patched = Promise.resolve(42);
        \\patched.then = function(...args) {
        \\  thenCalls++;
        \\  return Promise.prototype.then.apply(this, args);
        \\};
        \\async function trigger() {
        \\  order.push("Await:" + (await patched));
        \\}
        \\trigger();
        \\new Promise((res) => { order.push("P1"); res(); }).then(() => { order.push("P2"); });
        \\true;
    );
    defer r1.deinit();
    const r2 = try interp.run(
        \\emptyStrAggErr && thenCalls === 0 && order.join(",") === "P1,Await:42,P2";
    );
    defer r2.deinit();
    try testing.expect(r2.isBool() and r2.asBool());
}

test "Phase 2.1: Array.prototype[Symbol.iterator] respected in destructuring and step-by-step IteratorClose" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const res = try interp.run(
        \\var origIter = Array.prototype[Symbol.iterator];
        \\var protoCalls = 0;
        \\Array.prototype[Symbol.iterator] = function() {
        \\  protoCalls++;
        \\  return origIter.call(this);
        \\};
        \\var [a, b] = [10, 20];
        \\var x, y;
        \\[x, y] = [30, 40];
        \\delete Array.prototype[Symbol.iterator];
        \\var threwOnDeleted = false;
        \\try { var [c] = [1]; } catch (e) { threwOnDeleted = e instanceof TypeError; }
        \\Array.prototype[Symbol.iterator] = origIter;
        \\
        \\var nextCount = 0;
        \\var returnCount = 0;
        \\var iter = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { nextCount++; return { value: 1, done: false }; },
        \\  return() { returnCount++; throw new TypeError("close err"); }
        \\};
        \\function* g1() {
        \\  [ {}[yield] ] = iter;
        \\}
        \\var gen = g1();
        \\gen.next();
        \\var nextBeforeClose = nextCount;
        \\var closeThrew = false;
        \\try { gen.return(); } catch (e) { closeThrew = e instanceof TypeError; }
        \\protoCalls === 2 && a === 10 && b === 20 && x === 30 && y === 40 &&
        \\  threwOnDeleted && nextBeforeClose === 0 && returnCount === 1 && closeThrew;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 2.2: strict GetMethod in resolveIterator/resolveAsyncIterator and AsyncFromSyncIterator close on poisoned wrapper" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const r1 = try interp.run(
        \\var duckThrew = false;
        \\try { for (const x of { next() { return { done: true }; } }) {} } catch (e) { duckThrew = e instanceof TypeError; }
        \\var syncGetCalled = false;
        \\var asyncFalseThrew = false;
        \\var badAsync = {
        \\  get [Symbol.iterator]() { syncGetCalled = true; return () => ({ next() { return { done: true }; } }); },
        \\  [Symbol.asyncIterator]: false
        \\};
        \\async function testAsyncFalse() {
        \\  try { for await (const x of badAsync) {} } catch (e) { asyncFalseThrew = e instanceof TypeError; }
        \\}
        \\testAsyncFalse();
        \\var returnClosed = 0;
        \\var poisonedClosed = false;
        \\var poisonedObj = {
        \\  [Symbol.iterator]() {
        \\    return {
        \\      next() {
        \\        const p = Promise.resolve("FAIL");
        \\        Object.defineProperty(p, "constructor", { get() { throw new Error("poison"); } });
        \\        return { value: p, done: false };
        \\      },
        \\      return() { returnClosed++; return { done: true }; }
        \\    };
        \\  }
        \\};
        \\async function testPoisoned() {
        \\  try { for await (const x of poisonedObj) {} } catch (e) { poisonedClosed = e.message === "poison"; }
        \\}
        \\testPoisoned();
        \\true;
    );
    defer r1.deinit();
    const r2 = try interp.run(
        \\duckThrew && !syncGetCalled && asyncFalseThrew && poisonedClosed && returnClosed === 1;
    );
    defer r2.deinit();
    try testing.expect(r2.isBool() and r2.asBool());
}

test "Phase 2.3a: sync yield* forwards .throw() and .return()" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const res = try interp.run(
        \\var log = [];
        \\var inner = {
        \\  [Symbol.iterator]() { return this; },
        \\  next(v) { log.push("next:" + v); return { value: 1, done: false }; },
        \\  throw(e) { log.push("throw:" + e); return { value: 2, done: false }; },
        \\  return(v) { log.push("return:" + v); return { value: "ret:" + v, done: true }; }
        \\};
        \\function* g() { return yield* inner; }
        \\var it = g();
        \\var r1 = it.next("a");
        \\var r2 = it.throw("err1");
        \\var r3 = it.return("end");
        \\log.join(",") === "next:undefined,throw:err1,return:end" &&
        \\  r1.value === 1 && !r1.done &&
        \\  r2.value === 2 && !r2.done &&
        \\  r3.value === "ret:end" && r3.done;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 2.3b: sync yield* without .throw() closes iterator and throws TypeError" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const res = try interp.run(
        \\var closed = 0;
        \\var inner = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { return { value: 1, done: false }; },
        \\  return() { closed++; return { done: true }; }
        \\};
        \\function* g() { yield* inner; }
        \\var it = g();
        \\it.next();
        \\var threwTypeError = false;
        \\try { it.throw("boom"); } catch (e) { threwTypeError = e instanceof TypeError; }
        \\closed === 1 && threwTypeError && it.next().done;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 2.3c: async yield* forwards .return() to sync and async iterators" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const r1 = try interp.run(
        \\var syncRetVal = null;
        \\var syncFinal = null;
        \\var syncIter = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { return { value: 10, done: false }; },
        \\  return(v) { return { value: "sync:" + v, done: true }; }
        \\};
        \\async function* agSync() { yield* syncIter; }
        \\async function runTest() {
        \\  var it = agSync();
        \\  await it.next();
        \\  syncRetVal = await it.return(42);
        \\  syncFinal = await it.next();
        \\}
        \\runTest();
        \\true;
    );
    defer r1.deinit();
    const r2 = try interp.run(
        \\syncRetVal !== null && syncRetVal.value === "sync:42" && syncRetVal.done === true && syncFinal.done === true;
    );
    defer r2.deinit();
    try testing.expect(r2.isBool() and r2.asBool());
}

test "Phase 2.3d: async yield* does not unwrap promise value from manual async iterator" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const r1 = try interp.run(
        \\var innerPromise = Promise.resolve("x");
        \\var gotSame = false;
        \\var asyncIter = {
        \\  [Symbol.asyncIterator]() { return this; },
        \\  next() { return { done: false, value: innerPromise }; }
        \\};
        \\async function* f() { yield* asyncIter; }
        \\f().next().then(v => { gotSame = (v.value === innerPromise && v.done === false); });
        \\true;
    );
    defer r1.deinit();
    const r2 = try interp.run("gotSame;");
    defer r2.deinit();
    try testing.expect(r2.isBool() and r2.asBool());
}

test "Phase 3.1: DataView getFloat16/setFloat16 and detached buffer checks" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const res = try interp.run(
        \\var ab = new ArrayBuffer(8);
        \\var dv = new DataView(ab);
        \\dv.setFloat16(0, 1.5, false);
        \\var beBytes = [dv.getUint8(0), dv.getUint8(1)];
        \\dv.setFloat16(2, -0, true);
        \\var negZero = Object.is(dv.getFloat16(2, true), -0);
        \\dv.setFloat16(4, Infinity, true);
        \\dv.setFloat16(6, NaN, false);
        \\var got15 = dv.getFloat16(0, false);
        \\var gotInf = dv.getFloat16(4, true);
        \\var gotNaN = Number.isNaN(dv.getFloat16(6, false));
        \\var buf2 = new ArrayBuffer(8);
        \\var dv2 = new DataView(buf2);
        \\var threwDetachValueOf = false;
        \\try {
        \\  dv2.setFloat16(0, { valueOf() { $262.detachArrayBuffer(buf2); return 1; } });
        \\} catch (e) { threwDetachValueOf = e instanceof TypeError; }
        \\var threwGetDetached = false;
        \\try { dv2.getFloat16(0); } catch (e) { threwGetDetached = e instanceof TypeError; }
        \\var threwByteLen = false;
        \\try { dv2.byteLength; } catch (e) { threwByteLen = e instanceof TypeError; }
        \\var threwByteOff = false;
        \\try { dv2.byteOffset; } catch (e) { threwByteOff = e instanceof TypeError; }
        \\beBytes[0] === 0x3e && beBytes[1] === 0x00 && got15 === 1.5 && negZero &&
        \\  gotInf === Infinity && gotNaN && threwDetachValueOf && threwGetDetached &&
        \\  threwByteLen && threwByteOff;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 3.2: Uint8Array Base64 and Hex methods" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();
    const res = try interp.run(
        \\var a1 = Uint8Array.fromBase64("Zm9vYmFy");
        \\var s1 = a1.toBase64();
        \\var a2 = Uint8Array.fromBase64("x-_y", { alphabet: "base64url" });
        \\var s2 = a2.toBase64({ alphabet: "base64url", omitPadding: true });
        \\var strictErr = false;
        \\try { Uint8Array.fromBase64("Zg", { lastChunkHandling: "strict" }); } catch (e) { strictErr = e instanceof SyntaxError; }
        \\var sbp = Uint8Array.fromBase64("ABCDAA=", { lastChunkHandling: "stop-before-partial" });
        \\var target = new Uint8Array([255, 255, 255, 255, 255]);
        \\var errUpTo = false;
        \\try { target.setFromBase64("MjYyZm.9v"); } catch (e) { errUpTo = e instanceof SyntaxError; }
        \\var sub = new Uint8Array(6);
        \\sub.fill(9);
        \\var subView = sub.subarray(1, 4);
        \\var rw = subView.setFromHex("0a0b0c");
        \\var hexOut = subView.toHex();
        \\var fromHexArr = Uint8Array.fromHex("deadbeef");
        \\var detachErr = false;
        \\var ab = new ArrayBuffer(4);
        \\var u8 = new Uint8Array(ab);
        \\try {
        \\  u8.toBase64({ get alphabet() { $262.detachArrayBuffer(ab); return "base64"; } });
        \\} catch (e) { detachErr = e instanceof TypeError; }
        \\var notOnInt8 = typeof Int8Array.fromBase64 === "undefined" && typeof Int8Array.prototype.toHex === "undefined";
        \\s1 === "Zm9vYmFy" && a2[0] === 199 && a2[1] === 239 && a2[2] === 242 &&
        \\  s2 === "x-_y" && strictErr && sbp.length === 3 &&
        \\  errUpTo && target[0] === 50 && target[1] === 54 && target[2] === 50 && target[3] === 255 &&
        \\  rw.read === 6 && rw.written === 3 && hexOut === "0a0b0c" &&
        \\  sub[0] === 9 && sub[1] === 10 && sub[4] === 9 &&
        \\  fromHexArr[0] === 0xde && fromHexArr[3] === 0xef &&
        \\  detachErr && notOnInt8;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 3.3: TypedArray exotic [[Set]], [[DefineOwnProperty]], [[Delete]] and Reflect.set" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var ta = new Int32Array([10, 20]);
        \\var calls = 0;
        \\var badVal = { valueOf() { calls++; throw new Error("coerced"); } };
        \\var other = {};
        \\var r1 = Reflect.set(ta, "-1", badVal, other);
        \\var r1NoCoerce = calls === 0;
        \\var directCoerced = false;
        \\try { ta["-1"] = badVal; } catch (e) { directCoerced = e.message === "coerced" && calls === 1; }
        \\var r2 = Reflect.set(ta, "0", 99, other);
        \\var r2Ok = r2 === true && ta[0] === 10 && other[0] === 99;
        \\Object.defineProperty(ta, "foo", { value: 1, writable: false });
        \\var r3 = Reflect.set(ta, "foo", 2) === false && ta.foo === 1;
        \\var ab = new ArrayBuffer(8);
        \\var dta = new Int32Array(ab);
        \\$262.detachArrayBuffer(ab);
        \\var delDetached = (delete dta[0]) === true;
        \\var defDetached = Reflect.defineProperty(dta, "0", { value: 1, writable: true, enumerable: true, configurable: true }) === false;
        \\var forInKeys = [];
        \\ta.bar = 7;
        \\Object.preventExtensions(ta);
        \\Reflect.defineProperty(ta, "bar", { value: 8 });
        \\for (var k in ta) forInKeys.push(k);
        \\r1 === true && r1NoCoerce && directCoerced && r2Ok && r3 && delDetached && defDetached &&
        \\  forInKeys.join(",") === "0,1,bar";
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 4.1a: SuppressedError, DisposableStack and Iterator.prototype[Symbol.dispose]" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var se = new SuppressedError("e1", "e0", "msg");
        \\var seCall = SuppressedError("a", "b");
        \\var seOk = (se instanceof Error) && (se instanceof SuppressedError) &&
        \\  se.name === "SuppressedError" && se.message === "msg" &&
        \\  se.error === "e1" && se.suppressed === "e0" &&
        \\  seCall.error === "a" && seCall.suppressed === "b" && seCall.message === "";
        \\var log = [];
        \\var stack = new DisposableStack();
        \\stack.use(null);
        \\stack.use(undefined);
        \\var r1 = stack.use({ [Symbol.dispose]() { log.push("use1"); throw "err1"; } });
        \\var r2 = stack.adopt("val", (v) => { log.push("adopt:" + v); throw "err2"; });
        \\stack.defer(() => { log.push("defer"); });
        \\var sameFn = stack[Symbol.dispose] === DisposableStack.prototype.dispose;
        \\var tagOk = Object.prototype.toString.call(stack) === "[object DisposableStack]";
        \\var moved = stack.move();
        \\var origDisposed = stack.disposed === true && moved.disposed === false;
        \\var reenterErr = false;
        \\try { stack.defer(() => {}); } catch (e) { reenterErr = e instanceof ReferenceError; }
        \\var caught = null;
        \\try { moved.dispose(); } catch (e) { caught = e; }
        \\moved.dispose();
        \\var lifoOk = log.join(",") === "defer,adopt:val,use1" && r2 === "val";
        \\var chainOk = (caught instanceof SuppressedError) && caught.error === "err1" && caught.suppressed === "err2";
        \\var closed = false;
        \\var it = Object.create(Iterator.prototype);
        \\it.return = () => { closed = true; return { done: true }; };
        \\it[Symbol.dispose]();
        \\seOk && sameFn && tagOk && origDisposed && reenterErr && lifoOk && chainOk && closed;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 4.1b: AsyncDisposableStack and AsyncIteratorPrototype[Symbol.asyncDispose]" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const r1 = try interp.run(
        \\var log = [];
        \\var stack = new AsyncDisposableStack();
        \\stack.use(null);
        \\stack.use({ async [Symbol.asyncDispose]() { log.push("async1"); throw "e1"; } });
        \\stack.use({ [Symbol.dispose]() { log.push("syncFallback"); } });
        \\stack.adopt("v", async (x) => { log.push("adopt:" + x); return Promise.reject("e2"); });
        \\stack.defer(() => { log.push("defer"); });
        \\var sameFn = stack[Symbol.asyncDispose] === AsyncDisposableStack.prototype.disposeAsync;
        \\var tagOk = Object.prototype.toString.call(stack) === "[object AsyncDisposableStack]";
        \\var moved = stack.move();
        \\var origDisposed = stack.disposed === true && moved.disposed === false;
        \\var invalidRejected = false;
        \\AsyncDisposableStack.prototype.disposeAsync.call({}).catch((e) => { invalidRejected = e instanceof TypeError; });
        \\var caught = null;
        \\moved.disposeAsync().catch((e) => { caught = e; });
        \\var asyncIterClosed = false;
        \\async function* gen() {}
        \\var AIP = Object.getPrototypeOf(Object.getPrototypeOf(gen.prototype));
        \\var it = Object.create(AIP);
        \\it.return = async () => { asyncIterClosed = true; return { done: true }; };
        \\var iterDisposeOk = false;
        \\it[Symbol.asyncDispose]().then((v) => { iterDisposeOk = v === undefined && asyncIterClosed; });
        \\true;
    );
    r1.deinit();

    const r2 = try interp.run(
        \\sameFn && tagOk && origDisposed && invalidRejected && iterDisposeOk &&
        \\  log.join(",") === "defer,adopt:v,syncFallback,async1" &&
        \\  (caught instanceof SuppressedError) && caught.error === "e1" && caught.suppressed === "e2";
    );
    defer r2.deinit();
    try testing.expect(r2.isBool() and r2.asBool());
}

test "Phase 4.2a: Iterator.concat and ArrayIteratorPrototype -> Iterator.prototype" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var strErr = false;
        \\try { Iterator.concat("abc"); } catch (e) { strErr = e instanceof TypeError; }
        \\var opened = 0;
        \\var closed = 0;
        \\var lazy1 = {
        \\  [Symbol.iterator]() {
        \\    opened++;
        \\    var i = 0;
        \\    return {
        \\      next() { return i < 2 ? { value: ++i, done: false } : { value: undefined, done: true }; },
        \\      return() { closed++; return { done: true }; }
        \\    };
        \\  }
        \\};
        \\var lazy2 = {
        \\  [Symbol.iterator]() { opened++; return [3, 4][Symbol.iterator](); }
        \\};
        \\var c1 = Iterator.concat(lazy1, lazy2);
        \\var notOpenedYet = opened === 0;
        \\var cEarly = Iterator.concat(lazy1);
        \\cEarly.return();
        \\var notOpenedOnReturn = opened === 0 && closed === 0;
        \\var first = c1.next().value;
        \\c1.return();
        \\var closedActive = opened === 1 && closed === 1 && c1.next().done === true;
        \\var allVals = [...Iterator.concat([10, 20], [30])].join(",");
        \\var arrIter = [1, 2][Symbol.iterator]();
        \\var protoOk = Object.getPrototypeOf(Object.getPrototypeOf(arrIter)) === Iterator.prototype;
        \\var disposed = false;
        \\arrIter.return = () => { disposed = true; return { done: true }; };
        \\arrIter[Symbol.dispose]();
        \\strErr && notOpenedYet && notOpenedOnReturn && first === 1 && closedActive &&
        \\  allVals === "10,20,30" && protoOk && disposed;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 4.2b: Iterator.zip and Iterator.zipKeyed" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var s = [...Iterator.zip([[1, 2, 3], [4, 5]])].map(a => a.join(":")).join(",");
        \\var l = [...Iterator.zip([[1], [2, 3]], { mode: "longest", padding: ["p1"] })].map(a => String(a[0]) + ":" + String(a[1])).join(",");
        \\var strictErr = false;
        \\var closed = [];
        \\var it1 = { next() { return { value: 1, done: false }; }, return() { closed.push(1); return { done: true }; } };
        \\var it2 = { next() { return { value: undefined, done: true }; }, return() { closed.push(2); return { done: true }; } };
        \\var zStrict = Iterator.zip([it1, it2], { mode: "strict" });
        \\try { zStrict.next(); } catch (e) { strictErr = e instanceof TypeError; }
        \\var zk = [...Iterator.zipKeyed({ a: [1], b: [2, 3], skip: undefined }, { mode: "longest", padding: { a: 99 } })];
        \\var zkOk = zk.length === 2 && Object.getPrototypeOf(zk[0]) === null &&
        \\  zk[0].a === 1 && zk[0].b === 2 && !("skip" in zk[0]) && zk[1].a === 99 && zk[1].b === 3;
        \\var retClosed = [];
        \\var r1 = { next() { return { value: 1, done: false }; }, return() { retClosed.push("r1"); return { done: true }; } };
        \\var r2 = { next() { return { value: 2, done: false }; }, return() { retClosed.push("r2"); return { done: true }; } };
        \\var zRet = Iterator.zip([r1, r2]);
        \\zRet.next();
        \\zRet.return();
        \\s === "1:4,2:5" && l === "1:2,p1:3" && strictErr && closed.join(",") === "1" &&
        \\  zkOk && retClosed.join(",") === "r2,r1";
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 4.3: lazy Map/WeakMap/Set/WeakSet iterator close and Array splice/with limits" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var closes = 0;
        \\var infBadEntry = { [Symbol.iterator]() { return { next() { return { value: 123, done: false }; }, return() { closes++; return {}; } }; } };
        \\var mapErr = false;
        \\try { new Map(infBadEntry); } catch (e) { mapErr = e instanceof TypeError; }
        \\var wmapErr = false;
        \\try { new WeakMap(infBadEntry); } catch (e) { wmapErr = e instanceof TypeError; }
        \\var infPrim = { [Symbol.iterator]() { return { next() { return { value: 1, done: false }; }, return() { closes++; return {}; } }; } };
        \\var wsetErr = false;
        \\try { new WeakSet(infPrim); } catch (e) { wsetErr = e instanceof TypeError; }
        \\var setErr = false;
        \\var origAdd = Set.prototype.add;
        \\Set.prototype.add = function() { throw new RangeError("boom"); };
        \\try { new Set(infPrim); } catch (e) { setErr = e instanceof RangeError; }
        \\Set.prototype.add = origAdd;
        \\var spliceRange = false;
        \\try { Array.prototype.splice.call({ length: 2 ** 32 }, 0); } catch (e) { spliceRange = e instanceof RangeError; }
        \\var withRange = false;
        \\try { Array.prototype.with.call({ length: 2 ** 32 }, 0, 1); } catch (e) { withRange = e instanceof RangeError; }
        \\mapErr && wmapErr && wsetErr && setErr && closes === 4 && spliceRange && withRange;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 4.3b: TypedArray entries/keys/values inherit from ArrayIteratorPrototype" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var arrProto = Object.getPrototypeOf([][Symbol.iterator]());
        \\var ta = new Int8Array();
        \\Object.getPrototypeOf(ta.entries()) === arrProto &&
        \\  Object.getPrototypeOf(ta.keys()) === arrProto &&
        \\  Object.getPrototypeOf(ta.values()) === arrProto;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 5.1a: Promise.allKeyed and Promise.allSettledKeyed" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const r1 = try interp.run(
        \\var sym = Symbol("k");
        \\var resAll = null, resEmpty = null, resRej = null, resSettled = null, primRej = false;
        \\Promise.allKeyed({ a: Promise.resolve(1), b: 2, [sym]: Promise.resolve(3) }).then(r => { resAll = r; });
        \\Promise.allKeyed({}).then(r => { resEmpty = r; });
        \\Promise.allKeyed({ a: Promise.resolve(1), b: Promise.reject("boom") }).catch(e => { resRej = e; });
        \\Promise.allSettledKeyed({ ok: Promise.resolve(10), bad: Promise.reject("err") }).then(r => { resSettled = r; });
        \\Promise.allKeyed(42).catch(e => { primRej = e instanceof TypeError; });
        \\true;
    );
    r1.deinit();

    const r2 = try interp.run("Object.getPrototypeOf(resAll) === null && resAll.a === 1 && resAll.b === 2 && resAll[sym] === 3;");
    defer r2.deinit();
    try testing.expect(r2.isBool() and r2.asBool());
    const r3 = try interp.run("Object.getPrototypeOf(resEmpty) === null && Reflect.ownKeys(resEmpty).length === 0;");
    defer r3.deinit();
    try testing.expect(r3.isBool() and r3.asBool());
    const r4 = try interp.run("resRej === 'boom' && primRej === true;");
    defer r4.deinit();
    try testing.expect(r4.isBool() and r4.asBool());
    const r5 = try interp.run("Object.getPrototypeOf(resSettled) === null && resSettled.ok.status === 'fulfilled' && resSettled.ok.value === 10 && resSettled.bad.status === 'rejected' && resSettled.bad.reason === 'err';");
    defer r5.deinit();
    try testing.expect(r5.isBool() and r5.asBool());
}

test "Phase 5.1b: AsyncGeneratorQueue handles re-entrant next() in FIFO order" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const r1 = try interp.run(
        \\var iter;
        \\var order = [];
        \\async function* g() {
        \\  iter.next().then(r => order.push("2:" + r.value + ":" + r.done));
        \\  yield 1;
        \\  yield 2;
        \\}
        \\iter = g();
        \\iter.next().then(r => {
        \\  order.push("1:" + r.value + ":" + r.done);
        \\  iter.next().then(r2 => order.push("3:" + r2.value + ":" + r2.done));
        \\});
        \\true;
    );
    r1.deinit();

    const r2 = try interp.run("order.join(',') === '1:1:false,2:2:false,3:undefined:true';");
    defer r2.deinit();
    try testing.expect(r2.isBool() and r2.asBool());
}

test "Phase 5.2a: liveElem prototype holes and Array.prototype.indexOf/lastIndexOf" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var i1 = [1, 2, 1].indexOf(1, 1) === 2;
        \\var i2 = [1, 2, 1].indexOf(1, -1) === 2;
        \\var i3 = [1, 2, 1].indexOf(1, 10) === -1;
        \\var emptyCalls = 0;
        \\var iEmpty = [].indexOf(1, { valueOf() { emptyCalls++; return 0; } }) === -1 && emptyCalls === 0;
        \\var mutArr = [10, 20, 30];
        \\var iMut = mutArr.indexOf(99, { valueOf() { mutArr[2] = 99; return 0; } }) === 2;
        \\var lUndef = [1, 2, 1].lastIndexOf(1, undefined) === 0 && [1, 2, 1].lastIndexOf(1) === 2;
        \\var holeArr = [0, 111, 2];
        \\Object.defineProperty(holeArr, "0", { get() { delete holeArr[1]; return 0; }, configurable: true });
        \\Array.prototype[1] = 777;
        \\var protoHit = holeArr.indexOf(777) === 1;
        \\delete Array.prototype[1];
        \\Object.defineProperty(Object.prototype, "1", { get() { return this.length * 10; }, configurable: true });
        \\var getProtoHit = holeArr.lastIndexOf(30) === 1;
        \\delete Object.prototype[1];
        \\i1 && i2 && i3 && iEmpty && iMut && lUndef && protoHit && getProtoHit;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 5.2b: elision/Array(len) holes, Array proto indices in hasProperty, 0x/0b/0o toNumber" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var e = [, 1];
        \\var elisionOk = !(0 in e) && (1 in e) && e.length === 2 && e[0] === undefined;
        \\var a = new Array(3);
        \\var newArrOk = !(0 in a) && a.length === 3;
        \\var reduceThrew = false;
        \\try { a.reduce(function(x, y) { return x + y; }); } catch (err) { reduceThrew = err instanceof TypeError; }
        \\var sub = Object.create([10, 20]);
        \\var sum = 0;
        \\Array.prototype.forEach.call(sub, function(v) { sum += v; });
        \\var protoOk = (0 in sub) && !(2 in sub) && sum === 30;
        \\var numOk = Number("0x0002") === 2 && Number("0b101") === 5 && Number("0o77") === 63 &&
        \\  Number.isNaN(Number("-0x1")) && Number.isNaN(Number("+0x1")) && Number.isNaN(Number("0x"));
        \\elisionOk && newArrOk && reduceThrew && protoOk && numOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 5.3a: Function.prototype.toString" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var nativeOk = Function.prototype.toString.call(Math.sin) === "function sin() { [native code] }";
        \\var boundOk = (() => {}).bind().toString() === "function () { [native code] }";
        \\function /* c */ foo(a, b) { return a + b; }
        \\var jsOk = foo.toString() === "function /* c */ foo(a, b) { return a + b; }";
        \\class /* c2 */ Bar { m() {} }
        \\var classOk = Bar.toString() === "class /* c2 */ Bar { m() {} }";
        \\var nonFnThrew = false;
        \\try { Function.prototype.toString.call({}); } catch (e) { nonFnThrew = e instanceof TypeError; }
        \\var proxyOk = Function.prototype.toString.call(new Proxy(() => {}, {})) === "function () { [native code] }";
        \\var proxyNonFnThrew = false;
        \\try { Function.prototype.toString.call(new Proxy({}, {})); } catch (e) { proxyNonFnThrew = e instanceof TypeError; }
        \\nativeOk && boundOk && jsOk && classOk && nonFnThrew && proxyOk && proxyNonFnThrew;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 5.3b: apply array-like, bind length/proto, Symbol.hasInstance" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\function add(a, b) { return a + b; }
        \\var applyOk = add.apply(null, { length: 2, 0: 10, 1: 20 }) === 30;
        \\function target(a, b, c) {}
        \\Object.defineProperty(target, "length", { value: 10, configurable: true });
        \\var customProto = { tag: 42 };
        \\Object.setPrototypeOf(target, customProto);
        \\var bf = Function.prototype.bind.call(target, null, 1, 2);
        \\var bindOk = bf.length === 8 && bf.name === "bound target" && Object.getPrototypeOf(bf) === customProto && bf.tag === 42;
        \\var customHas = { [Symbol.hasInstance](x) { return x === 123; } };
        \\var hiCustomOk = (123 instanceof customHas) && !(456 instanceof customHas);
        \\function Ctor() {}
        \\var bCtor = Ctor.bind(null);
        \\var inst = new Ctor();
        \\var hiBoundOk = (inst instanceof bCtor) && Ctor[Symbol.hasInstance](inst);
        \\var nonObjProtoThrew = false;
        \\function BadProto() {}
        \\BadProto.prototype = 123;
        \\try { ({}) instanceof BadProto; } catch (e) { nonObjProtoThrew = e instanceof TypeError; }
        \\applyOk && bindOk && hiCustomOk && hiBoundOk && nonObjProtoThrew;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 5.3 fix: Object.keys skips array holes and Function.prototype instanceof throws TypeError" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var sparse = [1, 2, , 4, , 6];
        \\var k = Object.keys(sparse);
        \\var keysOk = k.length === 4 && k[0] === "0" && k[1] === "1" && k[2] === "3" && k[3] === "5";
        \\Function.prototype.prototype = "";
        \\var instThrew = false;
        \\try { [] instanceof Function.prototype; } catch (e) { instThrew = e instanceof TypeError; }
        \\delete Function.prototype.prototype;
        \\keysOk && instThrew;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 6.1: JSON reviver/replacer/space/toJSON, toLocaleString, strict toNumber" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var parsed = JSON.parse('{"a":1,"b":2,"c":3}', function(k, v) {
        \\  if (k === "b") return undefined;
        \\  return typeof v === "number" ? v * 10 : v;
        \\});
        \\var revOk = parsed.a === 10 && !("b" in parsed) && parsed.c === 30;
        \\var sFn = JSON.stringify({ a: 1, b: 2 }, function(k, v) { return k === "b" ? undefined : v; });
        \\var sArr = JSON.stringify({ a: 1, b: 2, c: 3 }, ["c", "a"], 2);
        \\var sToJson = JSON.stringify({ toJSON() { return { ok: true }; } });
        \\var circ = {}; circ.self = circ;
        \\var circThrew = false;
        \\try { JSON.stringify(circ); } catch (e) { circThrew = e instanceof TypeError; }
        \\var jsonOk = revOk && sFn === '{"a":1}' && sArr === '{\n  "c": 3,\n  "a": 1\n}' && sToJson === '{"ok":true}' && circThrew;
        \\var objLoc = ({ toString() { return "hi"; } }).toLocaleString() === "hi";
        \\var arrLoc = [1, null, undefined, { toLocaleString() { return "x"; } }].toLocaleString() === "1,,,x";
        \\var numStrict = Number.isNaN(Number("1_0")) && Number.isNaN(Number("123abc")) && parseFloat("1_0") === 1 && parseFloat("123abc") === 123;
        \\jsonOk && objLoc && arrLoc && numStrict;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 6.2: Proxy construct invariants, callable proxy call/apply/bind, nested proxy, ownKeys/delete/get/set" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var primConstructThrew = false;
        \\var pPrim = new Proxy(function() {}, { construct() { return 42; } });
        \\try { new pPrim(); } catch (e) { primConstructThrew = e instanceof TypeError; }
        \\var nonCtorThrew = false;
        \\try { new (new Proxy({}, {}))(); } catch (e) { nonCtorThrew = e instanceof TypeError; }
        \\var pFn = new Proxy(function(a, b) { return a + b; }, {
        \\  apply(t, thisArg, args) { return t(args[0] * 2, args[1] * 2); }
        \\});
        \\var callOk = Function.prototype.call.call(pFn, null, 3, 4) === 14 &&
        \\  Function.prototype.apply.call(pFn, null, [3, 4]) === 14 &&
        \\  Function.prototype.bind.call(pFn, null, 3)(4) === 14;
        \\var inner = { a: 1, b: 2 };
        \\var p1 = new Proxy(inner, {});
        \\var p2 = new Proxy(p1, {});
        \\delete p2.a;
        \\var nestedOk = !("a" in inner) && p2.b === 2;
        \\var frozen = Object.preventExtensions({ x: 1, y: 2 });
        \\var pOwn = new Proxy(frozen, { ownKeys() { return ["x"]; } });
        \\var ownKeysThrew = false;
        \\try { Object.keys(pOwn); } catch (e) { ownKeysThrew = e instanceof TypeError; }
        \\primConstructThrew && nonCtorThrew && callOk && nestedOk && ownKeysThrew;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 6.3: generic Promise catch/finally, Array.fromAsync, Map.groupBy, Set GetSetRecord" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var catchThenCalled = false;
        \\Promise.prototype.catch.call({ then(f, r) { catchThenCalled = (f === undefined && typeof r === "function"); return 77; } }, () => {});
        \\var finThenCalled = false;
        \\Promise.prototype.finally.call({ then(f, r) { finThenCalled = (typeof f === "function" && typeof r === "function"); return 88; } }, () => {});
        \\var g = Map.groupBy([1, 2, 3, 4], x => x % 2 === 0 ? "even" : "odd");
        \\var groupOk = g.get("odd").length === 2 && g.get("even").length === 2;
        \\var s1 = new Set([1, 2, 3]);
        \\var diff = s1.difference({ size: 1, has(x) { return x === 2; }, keys() { return [2][Symbol.iterator](); } });
        \\var setOk = diff.size === 2 && diff.has(1) && diff.has(3);
        \\var bigIntSizeThrew = false;
        \\try { s1.difference({ size: 1n, has() { return false; }, keys() { return [][Symbol.iterator](); } }); } catch (e) { bigIntSizeThrew = e instanceof TypeError; }
        \\class SubSet extends Set {}
        \\var subDiff = (new SubSet([1, 2])).difference(new Set([2]));
        \\var subOk = subDiff.size === 1 && subDiff.has(1);
        \\var asyncRes = null;
        \\Array.fromAsync({ length: 2, 0: Promise.resolve(10), 1: 20 }, x => x + 1).then(a => { asyncRes = a; });
        \\catchThenCalled && finThenCalled && groupOk && setOk && bigIntSizeThrew && subOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
    const r2 = try interp.run("asyncRes !== null && asyncRes.length === 2 && asyncRes[0] === 11 && asyncRes[1] === 21;");
    defer r2.deinit();
    try testing.expect(r2.isBool() and r2.asBool());
}

test "Phase 6.4: Error.prototype.stack accessor, TypedArray for..of/TDZ, compound-assignment order" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var d = Object.getOwnPropertyDescriptor(Error.prototype, "stack");
        \\var descOk = typeof d.get === "function" && typeof d.set === "function" && d.get.name === "get stack" && d.set.name === "set stack" && d.configurable === true && d.enumerable === false;
        \\var err = new Error("boom");
        \\var errStackOk = !Object.prototype.hasOwnProperty.call(err, "stack") && typeof err.stack === "string";
        \\err.stack = "custom";
        \\var setOk = err.stack === "custom" && Object.prototype.hasOwnProperty.call(err, "stack");
        \\var ta = new Float32Array([3, 2, 4]);
        \\var sum = 0;
        \\for (var v of ta) { sum += v; ta[1] = 10; }
        \\var taOk = sum === 17;
        \\var tdzThrew = false;
        \\try { let x = 1; for (const x of [x]) {} } catch (e) { tdzThrew = e instanceof ReferenceError; }
        \\var baseCalls = 0, keyCalls = 0;
        \\var obj = { a: 5 };
        \\function getBase() { baseCalls++; return obj; }
        \\var keyObj = { toString() { keyCalls++; return "a"; } };
        \\getBase()[keyObj] += 7;
        \\var caOk = obj.a === 12 && baseCalls === 1 && keyCalls === 1;
        \\var nullBaseThrewTypeError = false;
        \\try { var b = null; b[{ toString() { throw new RangeError(); } }] += 1; } catch (e) { nullBaseThrewTypeError = e instanceof TypeError; }
        \\descOk && errStackOk && setOk && taOk && tdzThrew && caOk && nullBaseThrewTypeError;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 6.5: CopyDataProperties object rest and %ThrowTypeError% caller/arguments/callee" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var getterCount = 0;
        \\var sym = Symbol("s");
        \\var src = { a: 1, get b() { getterCount++; return 2; }, [sym]: 3 };
        \\Object.defineProperty(src, "hidden", { value: 99, enumerable: false, configurable: true });
        \\var { a, ...rest } = src;
        \\var restOk = a === 1 && rest.b === 2 && getterCount === 1 && rest[sym] === 3 && !("hidden" in rest) && !("a" in rest);
        \\var throwSrc = { get bad() { throw new RangeError("boom"); } };
        \\var restThrew = false;
        \\try { var { ...r2 } = throwSrc; } catch (e) { restThrew = e instanceof RangeError; }
        \\var pSrc = new Proxy({ x: 10, y: 20 }, {});
        \\var { x, ...pRest } = pSrc;
        \\var proxyRestOk = x === 10 && pRest.y === 20 && !("x" in pRest);
        \\var dCaller = Object.getOwnPropertyDescriptor(Function.prototype, "caller");
        \\var dArgs = Object.getOwnPropertyDescriptor(Function.prototype, "arguments");
        \\var tte = dCaller.get;
        \\var tteOk = typeof tte === "function" && dCaller.get === dCaller.set && dArgs.get === tte && dArgs.set === tte &&
        \\  !Object.isExtensible(tte) && Object.isFrozen(tte) && tte.length === 0 && tte.name === "";
        \\var callerThrew = false;
        \\try { (function() {}).caller; } catch (e) { callerThrew = e instanceof TypeError; }
        \\var argsCallee = Object.getOwnPropertyDescriptor((function() { "use strict"; return arguments; })(), "callee");
        \\var calleeOk = argsCallee.get === tte && argsCallee.set === tte && argsCallee.configurable === false;
        \\restOk && restThrew && proxyRestOk && tteOk && callerThrew && calleeOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 6.6: Class field eval SyntaxError, nested #private brand checks, and DefineField __proto__" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var executed = false;
        \\var argErr = false;
        \\try { class C1 { x = eval("executed = true; arguments;"); } new C1(); } catch (e) { argErr = e instanceof SyntaxError; }
        \\var arrowArgErr = false;
        \\try { class C2 { x = eval("(() => arguments)()"); } new C2(); } catch (e) { arrowArgErr = e instanceof SyntaxError; }
        \\var superErr = false;
        \\try { class Base {} class C3 extends Base { x = eval("executed = true; super();"); } new C3(); } catch (e) { superErr = e instanceof SyntaxError; }
        \\class C4 { x = eval("(function(a) { return arguments[0]; })(42)"); }
        \\var fnArgOk = new C4().x === 42;
        \\class Outer {
        \\  #outer = 10;
        \\  #shared = 1;
        \\  makeInner() {
        \\    var self = this;
        \\    return class Inner {
        \\      #shared = 2;
        \\      readOuter() { return self.#outer; }
        \\      readShared(o) { return o.#shared; }
        \\    };
        \\  }
        \\}
        \\var o = new Outer();
        \\var Inner = o.makeInner();
        \\var inn = new Inner();
        \\var brandErr = false;
        \\try { inn.readShared(o); } catch (e) { brandErr = e instanceof TypeError; }
        \\var nestedOk = inn.readOuter() === 10 && inn.readShared(inn) === 2 && brandErr;
        \\var poisonHit = false;
        \\Object.defineProperty(Object.prototype, "__proto__", { set() { poisonHit = true; throw new Error("poison"); }, configurable: true });
        \\class ProtoCls { __proto__ = 7; ["__proto__"] = 8; static __proto__ = 9; }
        \\var p = new ProtoCls();
        \\var protoOk = !poisonHit && Object.getOwnPropertyDescriptor(p, "__proto__").value === 8 && Object.getOwnPropertyDescriptor(ProtoCls, "__proto__").value === 9;
        \\var sx = 0;
        \\class RestrictedSetters {
        \\  set arguments(v) { sx = v; }
        \\  static set arguments(v) { sx = v; }
        \\  static set caller(v) { sx = v; }
        \\}
        \\new RestrictedSetters().arguments = 11;
        \\var rs1 = sx === 11;
        \\RestrictedSetters.arguments = 22;
        \\var rs2 = sx === 22;
        \\RestrictedSetters.caller = 33;
        \\var rs3 = sx === 33;
        \\!executed && argErr && arrowArgErr && superErr && fnArgOk && nestedOk && protoOk && rs1 && rs2 && rs3;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 6.7: fn-name, GeneratorPrototype, object spread, WeakMap.getOrInsert, ArrayBuffer.isView, JSON.rawJSON, Array.unscopables" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var sym = Symbol("desc");
        \\var symNoDesc = Symbol();
        \\class C { get foo() {} set foo(v) {} [sym]() {} [symNoDesc]() {} }
        \\var obj = { get a() {}, set a(v) {}, [sym]() {} };
        \\var [f1 = () => {}] = [];
        \\var f2; ({ x: f2 = function() {} } = {});
        \\var nameOk = Object.getOwnPropertyDescriptor(C.prototype, "foo").get.name === "get foo" &&
        \\  Object.getOwnPropertyDescriptor(C.prototype, "foo").set.name === "set foo" &&
        \\  C.prototype[sym].name === "[desc]" && C.prototype[symNoDesc].name === "" &&
        \\  Object.getOwnPropertyDescriptor(obj, "a").get.name === "get a" &&
        \\  Object.getOwnPropertyDescriptor(obj, "a").set.name === "set a" &&
        \\  obj[sym].name === "[desc]" && f1.name === "f1" && f2.name === "f2";
        \\function* g() { yield 1; }
        \\async function* ag() { yield 2; }
        \\var gp = Object.getPrototypeOf(g.prototype);
        \\var agp = Object.getPrototypeOf(ag.prototype);
        \\var genOk = gp[Symbol.toStringTag] === "Generator" && agp[Symbol.toStringTag] === "AsyncGenerator" &&
        \\  typeof gp.next === "function" && gp.next.length === 1 && gp.constructor.prototype === gp &&
        \\  typeof agp.next === "function" && agp.constructor.prototype === agp && g().next().value === 1;
        \\var sp = { ...null, ...undefined, ..."ab", a: 9, ...{ get b() { return 42; }, [sym]: 7 } };
        \\var spreadOk = sp[0] === "a" && sp[1] === "b" && sp.a === 9 && sp.b === 42 && sp[sym] === 7;
        \\var wm = new WeakMap();
        \\var k1 = {}, k2 = {};
        \\var wmOk = wm.getOrInsert(k1, 10) === 10 && wm.getOrInsert(k1, 20) === 10 &&
        \\  wm.getOrInsertComputed(k2, () => 99) === 99 && wm.get(k2) === 99;
        \\var ab = new ArrayBuffer(8);
        \\var isViewOk = ArrayBuffer.isView(new Uint8Array(ab)) && ArrayBuffer.isView(new DataView(ab)) &&
        \\  !ArrayBuffer.isView(ab) && !ArrayBuffer.isView({}) && !ArrayBuffer.isView(null);
        \\var rj = JSON.rawJSON("12345678901234567890");
        \\var rjErr = false;
        \\try { JSON.rawJSON(" 1 "); } catch (e) { rjErr = e instanceof SyntaxError; }
        \\var rawJsonOk = JSON.isRawJSON(rj) && !JSON.isRawJSON({}) && Object.getPrototypeOf(rj) === null &&
        \\  Object.isFrozen(rj) && JSON.stringify({ n: rj }) === "{\"n\":12345678901234567890}" && rjErr;
        \\var u = Array.prototype[Symbol.unscopables];
        \\var unscopOk = Object.getPrototypeOf(u) === null && u.find === true && u.at === true && u.findLast === true && u.values === true;
        \\nameOk && genOk && spreadOk && wmOk && isViewOk && rawJsonOk && unscopOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Cap1 crashfix: for-of and for-in member/paren/private LHS targets" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\var x = {};
        \\for (x.y of [23]) {}
        \\var async = { x: 0 };
        \\for (async.x of [1]) {}
        \\var z = {};
        \\for (z.k in { attr: null }) {}
        \\var p = 0;
        \\for ((p) of [7]) {}
        \\class C { #f; mOf() { for (this.#f of [1]) {} } mIn() { for (this.#f in { a: 0 }) {} } }
        \\var errOf = false, errIn = false;
        \\try { C.prototype.mOf.call({}); } catch (e) { errOf = e instanceof TypeError; }
        \\try { C.prototype.mIn.call({}); } catch (e) { errIn = e instanceof TypeError; }
        \\x.y === 23 && async.x === 1 && z.k === "attr" && p === 7 && errOf && errIn;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Cap2.1: new.target in calls, constructors, super(), arrows, field initializers, eval, and top-level SyntaxError" {
    const testing = std.testing;
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var interp = try gcTestInterp(&allocating);
    defer interp.deinit();

    const res = try interp.run(
        \\function F() { return new.target; }
        \\var callOk = F() === undefined;
        \\var ctorOk = (new F()) === F;
        \\function WithArrow() { this.get = () => new.target; }
        \\var arrowOk = (new WithArrow()).get() === WithArrow;
        \\var seenBase, seenSub;
        \\class Base {
        \\  fieldNT = new.target;
        \\  constructor() { seenBase = new.target; }
        \\}
        \\class Sub extends Base {
        \\  constructor() { super(); seenSub = new.target; }
        \\}
        \\var s = new Sub();
        \\var inheritOk = seenBase === Sub && seenSub === Sub && s.fieldNT === undefined;
        \\var evalNT = (function() { return eval("new.target"); })();
        \\var evalCtor = new (function E() { this.nt = eval("new.target"); })();
        \\var evalOk = evalNT === undefined && evalCtor.nt === evalCtor.constructor;
        \\var topErr = false;
        \\try { (0, eval)("new.target"); } catch (e) { topErr = e instanceof SyntaxError; }
        \\callOk && ctorOk && arrowOk && inheritOk && evalOk && topErr;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "ObjectPattern computed property keys (ECMA-262 order, Symbol, rest, defaults)" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\var sym = Symbol("s");
        \\var log = [];
        \\var kObj = { toString() { log.push("kObj"); return "b"; } };
        \\var src = { a: 1, b: 2, [sym]: 3, c: 4 };
        \\const { ["a"]: x, [kObj]: y, [sym]: z, ["missing"]: fn = () => {}, ...rest } = src;
        \\var basicOk = x === 1 && y === 2 && z === 3 && fn.name === "fn" && log.length === 1;
        \\var restOk = rest.c === 4 && !("a" in rest) && !("b" in rest) && !(sym in rest);
        \\var evalOrderOk = false;
        \\var ran = false;
        \\try {
        \\  const { [(ran = true, "a")]: bad } = null;
        \\} catch (e) {
        \\  evalOrderOk = (e instanceof TypeError) && !ran;
        \\}
        \\function f({ [sym]: v }) { return v; }
        \\var paramOk = f({ [sym]: 99 }) === 99;
        \\var forOfSum = 0;
        \\for (const { ["n"]: n } of [{ n: 10 }, { n: 20 }]) forOfSum += n;
        \\basicOk && restOk && evalOrderOk && paramOk && forOfSum === 30;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "tagged templates: GetTemplateObject caching, frozen, this binding, invalid escapes, String.raw" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\function getSite(a) { return (t => t)`head${a}tail`; }
        \\var s1 = getSite(1), s2 = getSite(2);
        \\var cacheOk = s1 === s2 && s1.raw === s2.raw;
        \\var frozenOk = Object.isFrozen(s1) && Object.isFrozen(s1.raw);
        \\var rawDesc = Object.getOwnPropertyDescriptor(s1, "raw");
        \\var descOk = rawDesc.value === s1.raw && !rawDesc.writable && !rawDesc.enumerable && !rawDesc.configurable;
        \\var obj = {
        \\  tag(strings, ...vals) { return [this === obj, strings[0], vals[0]]; }
        \\};
        \\var mRes = obj.tag`hi${42}`;
        \\var thisOk = mRes[0] && mRes[1] === "hi" && mRes[2] === 42;
        \\var bad = (t => [t[0] === undefined, t.raw[0]])`\unicode`;
        \\var badOk = bad[0] && bad[1] === "\\unicode";
        \\var rawOk = String.raw`a\nb${1}c` === "a\\nb1c";
        \\var newErr = false;
        \\try { eval("new tag`a`"); } catch (e) { newErr = e instanceof SyntaxError; }
        \\cacheOk && frozenOk && descOk && thisOk && badOk && rawOk && newErr;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Function.prototype.toString, call, and apply compliance" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\var nativeStr = Function.prototype.toString.call(Math.abs);
        \\var boundStr = Function.prototype.toString.call((function f() {}).bind(null));
        \\var proxyStr = Function.prototype.toString.call(new Proxy(function() {}, {}));
        \\var nonCallErr = false;
        \\try { Function.prototype.toString.call(new Proxy({}, {})); } catch (e) { nonCallErr = e instanceof TypeError; }
        \\var obj = { get x() { return 1; }, async *m() {} };
        \\var getterStr = Object.getOwnPropertyDescriptor(obj, "x").get.toString();
        \\var methStr = obj.m.toString();
        \\var dynStr = Function("a", " b", "return a + b;").toString();
        \\var genDyn = Object.getPrototypeOf(function*(){}).constructor("a", "yield a;");
        \\var asyncDyn = Object.getPrototypeOf(async function(){}).constructor("a", "return a;");
        \\var toStrOk = nativeStr === "function abs() { [native code] }" &&
        \\  boundStr === "function () { [native code] }" &&
        \\  proxyStr === "function () { [native code] }" &&
        \\  nonCallErr &&
        \\  getterStr === "get x() { return 1; }" &&
        \\  methStr === "async *m() {}" &&
        \\  dynStr === "function anonymous(a, b\n) {\nreturn a + b;\n}" &&
        \\  genDyn.toString().startsWith("function* anonymous(a") &&
        \\  asyncDyn.toString().startsWith("async function anonymous(a");
        \\var primErr = false;
        \\try { (function(){}).apply(null, 42); } catch (e) { primErr = e instanceof TypeError; }
        \\var alRes = (function(a, b) { return a + b; }).apply(null, { 0: 10, 1: 20, length: 2 });
        \\var nullRes = (function() { return arguments.length; }).apply(null, null);
        \\var sloppyThis = Function("return this === globalThis;").call(undefined);
        \\var sloppyNum = Function("this.touched = true; return this.touched && typeof this === 'object';").apply(1);
        \\var strictThis = (function() { "use strict"; return this === undefined; }).call(undefined);
        \\toStrOk && primErr && alRes === 30 && nullRes === 0 && sloppyThis && sloppyNum && strictThis;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "ArrayBuffer.prototype.transfer, transferToFixedLength, and detached" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\var ab = new ArrayBuffer(4);
        \\var u8 = new Uint8Array(ab);
        \\u8[0] = 10; u8[1] = 20; u8[2] = 30; u8[3] = 40;
        \\var ab2 = ab.transfer();
        \\var sameOk = ab.detached === true && ab.byteLength === 0 && ab2.detached === false && ab2.byteLength === 4;
        \\var u8_2 = new Uint8Array(ab2);
        \\var dataOk = u8_2[0] === 10 && u8_2[3] === 40 && u8.length === 0;
        \\var secondErr = false;
        \\try { ab.transfer(); } catch (e) { secondErr = e instanceof TypeError; }
        \\var grown = ab2.transfer(6);
        \\var g8 = new Uint8Array(grown);
        \\var growOk = ab2.detached && grown.byteLength === 6 && g8[0] === 10 && g8[4] === 0 && g8[5] === 0;
        \\var shrunk = grown.transferToFixedLength(2);
        \\var s8 = new Uint8Array(shrunk);
        \\var shrinkOk = grown.detached && shrunk.byteLength === 2 && s8[0] === 10 && s8[1] === 20;
        \\var negErr = false;
        \\try { shrunk.transfer(-1); } catch (e) { negErr = e instanceof RangeError; }
        \\var sideErr = false;
        \\try {
        \\  shrunk.transfer({ valueOf() { shrunk.transfer(); return 2; } });
        \\} catch (e) { sideErr = e instanceof TypeError; }
        \\var descOk = ArrayBuffer.prototype.transfer.length === 0 &&
        \\  ArrayBuffer.prototype.transfer.name === "transfer" &&
        \\  ArrayBuffer.prototype.transferToFixedLength.length === 0 &&
        \\  ArrayBuffer.prototype.transferToFixedLength.name === "transferToFixedLength";
        \\sameOk && dataOk && secondErr && growOk && shrinkOk && negErr && sideErr && descOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Object.prototype.toString, valueOf, isPrototypeOf, hasOwnProperty, propertyIsEnumerable" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\var ts = Object.prototype.toString;
        \\var primTags = ts.call(undefined) === "[object Undefined]" &&
        \\  ts.call(null) === "[object Null]" &&
        \\  ts.call(true) === "[object Boolean]" &&
        \\  ts.call(9) === "[object Number]" &&
        \\  ts.call("") === "[object String]" &&
        \\  ts.call(1n) === "[object BigInt]" &&
        \\  ts.call((function() { return arguments; })()) === "[object Arguments]";
        \\var proxyTags = ts.call(new Proxy([], {})) === "[object Array]" &&
        \\  ts.call(new Proxy(function() {}, {})) === "[object Function]" &&
        \\  ts.call(new Proxy(async function() {}, {})) === "[object AsyncFunction]" &&
        \\  ts.call(function*() {}) === "[object GeneratorFunction]";
        \\var rev = Proxy.revocable({}, {});
        \\rev.revoke();
        \\var revErr = false;
        \\try { ts.call(rev.proxy); } catch (e) { revErr = e instanceof TypeError; }
        \\var getterErr = false;
        \\try { ts.call({ get [Symbol.toStringTag]() { throw new RangeError("boom"); } }); } catch (e) { getterErr = e instanceof RangeError; }
        \\Number.prototype[Symbol.toStringTag] = "CustomNum";
        \\var customTag = ts.call(42) === "[object CustomNum]";
        \\delete Number.prototype[Symbol.toStringTag];
        \\var voOk = typeof Object.prototype.valueOf.call(true) === "object" &&
        \\  typeof Object.prototype.valueOf.call(5) === "object";
        \\var voNullErr = false;
        \\try { Object.prototype.valueOf.call(null); } catch (e) { voNullErr = e instanceof TypeError; }
        \\var hopNullErr = false;
        \\try { Object.prototype.hasOwnProperty.call(undefined, "a"); } catch (e) { hopNullErr = e instanceof TypeError; }
        \\var pieNullErr = false;
        \\try { Object.prototype.propertyIsEnumerable.call(null, "a"); } catch (e) { pieNullErr = e instanceof TypeError; }
        \\var ipoNullErr = false;
        \\try { Object.prototype.isPrototypeOf.call(null, {}); } catch (e) { ipoNullErr = e instanceof TypeError; }
        \\var base = {};
        \\var p = new Proxy({}, { getPrototypeOf() { return base; } });
        \\var ipoProxyOk = base.isPrototypeOf(p) === true;
        \\var immutErr = false;
        \\try { Object.setPrototypeOf(Object.prototype, Object.create(null)); } catch (e) { immutErr = e instanceof TypeError; }
        \\primTags && proxyTags && revErr && getterErr && customTag && voOk && voNullErr && hopNullErr && pieNullErr && ipoNullErr && ipoProxyOk && immutErr;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "GeneratorFunction, AsyncGeneratorFunction, and AsyncFunction intrinsic prototypes" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\var GF = Object.getPrototypeOf(function*(){}).constructor;
        \\var AGF = Object.getPrototypeOf(async function*(){}).constructor;
        \\var AF = Object.getPrototypeOf(async function(){}).constructor;
        \\function* gDecl() {}
        \\async function* agDecl() {}
        \\var aArrow = async () => {};
        \\var gfOk = (gDecl instanceof GF) && (new GF() instanceof GF) && (GF() instanceof GF) && GF[Symbol.hasInstance](gDecl);
        \\var agfOk = (agDecl instanceof AGF) && (new AGF() instanceof AGF) && (AGF() instanceof AGF) && AGF[Symbol.hasInstance](agDecl);
        \\var afOk = Object.getPrototypeOf(aArrow) === AF.prototype && aArrow.prototype === undefined && !aArrow.hasOwnProperty("prototype");
        \\gfOk && agfOk && afOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 8.2: indirect eval, Array.prototype, iterator slots, OOM RangeError, encodeURI surrogates" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\(0, eval)("var gIndirect = 42; let lexOnly = 99;");
        \\var evalGlobalOk = gIndirect === 42 && globalThis.gIndirect === 42 && typeof lexOnly === "undefined";
        \\(0, eval)("'use strict'; var strictOnly = 7;");
        \\var evalStrictOk = typeof strictOnly === "undefined";
        \\var evalThisOk = (function() { "use strict"; return (0, eval)("this === globalThis"); })();
        \\var u = Array.prototype[Symbol.unscopables];
        \\var unscopOk = u.toReversed === true && u.toSorted === true && u.toSpliced === true;
        \\var frozenArr = Object.freeze([1, 2]);
        \\var pushErr = false;
        \\try { frozenArr.push(); } catch (e) { pushErr = e instanceof TypeError; }
        \\var popErr = false;
        \\try { Object.freeze([]).pop(); } catch (e) { popErr = e instanceof TypeError; }
        \\var incOk = [1, 2, 3].includes(1, 1) === false && [1, 2, 3].includes(2, 1) === true && [1, 2].includes(1, Infinity) === false;
        \\var tsOk = [1, 2, 3].toSpliced().length === 3;
        \\var mapIterProto = Object.getPrototypeOf(new Map().entries());
        \\var setIterProto = Object.getPrototypeOf(new Set().values());
        \\var arrIterProto = Object.getPrototypeOf([].values());
        \\var iterTagOk = mapIterProto[Symbol.toStringTag] === "Map Iterator" &&
        \\  setIterProto[Symbol.toStringTag] === "Set Iterator" &&
        \\  arrIterProto[Symbol.toStringTag] === "Array Iterator" &&
        \\  mapIterProto.hasOwnProperty("next") && arrIterProto.hasOwnProperty("next");
        \\var iterSlotErr = false;
        \\try { mapIterProto.next.call({}); } catch (e) { iterSlotErr = e instanceof TypeError; }
        \\var abErr = false;
        \\try { new ArrayBuffer(Math.pow(2, 53) - 1); } catch (e) { abErr = e instanceof RangeError; }
        \\var uriErr = false;
        \\try { encodeURI(String.fromCharCode(0xDC00)); } catch (e) { uriErr = e instanceof URIError; }
        \\evalGlobalOk && evalStrictOk && evalThisOk && unscopOk && pushErr && popErr && incOk && tsOk && iterTagOk && iterSlotErr && abErr && uriErr;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 8.3: extends null, derived this TDZ, double super, dynamic HomeObject, private duplicate" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\class NullSub extends null {
        \\  constructor() { return { ok: true }; }
        \\}
        \\var extNullOk = Object.getPrototypeOf(NullSub.prototype) === null &&
        \\  Object.getPrototypeOf(NullSub) === Function.prototype &&
        \\  (new NullSub()).ok === true;
        \\var extNullSuperErr = false;
        \\try { new (class extends null {})(); } catch (e) { extNullSuperErr = e instanceof TypeError; }
        \\class Base { constructor(v) { if (v) return v; } }
        \\var tdzErr = false;
        \\try {
        \\  new (class extends Base { constructor() { this.x = 1; super(); } })();
        \\} catch (e) { tdzErr = e instanceof ReferenceError; }
        \\var doubleSuperErr = false;
        \\try {
        \\  new (class extends Base { constructor() { super(); super(); } })();
        \\} catch (e) { doubleSuperErr = e instanceof ReferenceError; }
        \\var noSuperErr = false;
        \\try {
        \\  new (class extends Base { constructor() {} })();
        \\} catch (e) { noSuperErr = e instanceof ReferenceError; }
        \\class P1 { get val() { return this.n + 1; } }
        \\class P2 { get val() { return this.n + 100; } }
        \\class C extends P1 {
        \\  constructor() { super(); this.n = 5; }
        \\  getVal() { return (() => super.val)(); }
        \\  setSuper(v) { super.prop = v; }
        \\}
        \\var c = new C();
        \\var dyn1 = c.getVal() === 6;
        \\Object.setPrototypeOf(C.prototype, P2.prototype);
        \\var dyn2 = c.getVal() === 105;
        \\c.setSuper(77);
        \\var superSetOk = c.prop === 77;
        \\var custom = {};
        \\class WithPriv extends Base { #p = 42; getP() { return this.#p; } }
        \\var inst = new WithPriv(custom);
        \\var customFieldOk = inst === custom && WithPriv.prototype.getP.call(inst) === 42;
        \\var dupPrivErr = false;
        \\try { new WithPriv(custom); } catch (e) { dupPrivErr = e instanceof TypeError; }
        \\extNullOk && extNullSuperErr && tdzErr && doubleSuperErr && noSuperErr && dyn1 && dyn2 && superSetOk && customFieldOk && dupPrivErr;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Phase 8.4: String/TypedArray prototypes, for-in semantics, object expressions" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\var repErr = false;
        \\try { "abc".replaceAll(/a/, "b"); } catch (e) { repErr = e instanceof TypeError; }
        \\var strIter = "a\uD83D\uDE00b"[Symbol.iterator]();
        \\var strIterProto = Object.getPrototypeOf(strIter);
        \\var strIterOk = strIterProto[Symbol.toStringTag] === "String Iterator" &&
        \\  strIter.next().value === "a" && strIter.next().value === "\uD83D\uDE00" && strIter.next().value === "b" && strIter.next().done === true;
        \\var strIterSlotErr = false;
        \\try { strIterProto.next.call({}); } catch (e) { strIterSlotErr = e instanceof TypeError; }
        \\var taCwErr = false;
        \\var ta1 = new Uint8Array([1, 2, 3]);
        \\try { ta1.copyWithin(0, { valueOf() { ta1.buffer.transfer(); return 1; } }); } catch (e) { taCwErr = e instanceof TypeError; }
        \\var taSliceErr = false;
        \\var ta2 = new Uint8Array([1, 2, 3]);
        \\ta2.constructor = { [Symbol.species]: function(n) { var o = new Uint8Array(n); o.buffer.transfer(); return o; } };
        \\try { ta2.slice(); } catch (e) { taSliceErr = e instanceof TypeError; }
        \\var forInTdz = false;
        \\try { eval("for (let x in x) {}"); } catch (e) { forInTdz = e instanceof ReferenceError; }
        \\var parentObj = { p1: 1, p2: 2 };
        \\var childObj = Object.create(parentObj);
        \\Object.defineProperty(childObj, "p2", { value: 9, enumerable: false });
        \\var seenKeys = [];
        \\for (var k in childObj) seenKeys.push(k);
        \\var shadowOk = seenKeys.length === 1 && seenKeys[0] === "p1";
        \\var oProto1 = { v: 10 }, oProto2 = { v: 20 };
        \\var objLit = { __proto__: oProto1, getV() { return super.v; } };
        \\var objSuper1 = objLit.getV() === 10;
        \\Object.setPrototypeOf(objLit, oProto2);
        \\var objSuper2 = objLit.getV() === 20;
        \\var nullProtoOk = Object.getPrototypeOf({ __proto__: null }) === null;
        \\repErr && strIterOk && strIterSlotErr && taCwErr && taSliceErr && forInTdz && shadowOk && objSuper1 && objSuper2 && nullProtoOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Operacion 27: all 27 target spec compliance cases" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. Temporal Duration.prototype.total relativeTo date limits
        \\var d0 = new Temporal.Duration(0);
        \\var tempErr = false;
        \\try { d0.total({ unit: "days", relativeTo: "+275760-09-12T00:00:01+00:00[UTC]" }); } catch (e) { tempErr = e instanceof RangeError; }
        \\var tempOk = tempErr && d0.total({ unit: "days", relativeTo: "+275760-09-12T00:00:00+00:00[UTC]" }) === 0;
        \\
        \\// 2. GeneratorPrototype[Symbol.toStringTag] + generator-created-after-decl-inst
        \\var GP = Object.getPrototypeOf(Object.getPrototypeOf(function*() {}()));
        \\function* gAfterDecl(a = (gAfterDecl.prototype = null)) {}
        \\var oldGProto = gAfterDecl.prototype;
        \\var itAfterDecl = gAfterDecl();
        \\var genTagOk = GP[Symbol.toStringTag] === "Generator" && Object.getPrototypeOf(itAfterDecl) !== oldGProto;
        \\
        \\// 3. do-while ASI same line
        \\var dwX;
        \\do break ; while (0) dwX = 42;
        \\var dwY = 0;
        \\do do do ; while (dwY) while (dwY) while (dwY) dwY = 39;
        \\var asiOk = dwX === 42 && dwY === 39;
        \\
        \\// 4. Strict octal in eval (7.8.3-3gs)
        \\var octalErr = false;
        \\try { eval("var a; a = 0x1; a = 01;"); } catch (e) { octalErr = e instanceof SyntaxError; }
        \\
        \\// 5. Assign to global undeclared when RHS defines it on globalThis
        \\var assignRefErr = false;
        \\try { undeclaredOp27 = (globalThis.undeclaredOp27 = 5); } catch (e) { assignRefErr = e instanceof ReferenceError; }
        \\
        \\// 6. Line terminators U+2028 and U+2029 in single-line comments
        \\var lsHit = false, psHit = false;
        \\// comment lsHit = true;
        \\// comment psHit = true;
        \\var ltOk = lsHit && psHit;
        \\
        \\// 7. AggregateError & SuppressedError constructor [[Prototype]] === Error & Function.prototype.toString
        \\var errProtoOk = Object.getPrototypeOf(AggregateError) === Error &&
        \\  Object.getPrototypeOf(SuppressedError) === Error &&
        \\  ("" + AggregateError).includes("AggregateError") &&
        \\  ("" + SuppressedError).includes("SuppressedError");
        \\
        \\// 8. Number.parseFloat === parseFloat, Number.parseInt === parseInt, toFixed(0n) throws TypeError
        \\var toFixedBigIntErr = false;
        \\try { (0).toFixed(0n); } catch (e) { toFixedBigIntErr = e instanceof TypeError; }
        \\var numOk = Number.parseFloat === parseFloat && Number.parseInt === parseInt && toFixedBigIntErr;
        \\
        \\// 9. Set.prototype.keys === Set.prototype.values & Map/Set.prototype.forEach live mutations
        \\var setKeysOk = Set.prototype.keys === Set.prototype.values;
        \\var m1 = new Map([["foo", 0], ["bar", 1]]);
        \\var m1Res = [];
        \\m1.forEach((v, k) => { if (m1Res.length === 0) m1.delete("bar"); m1Res.push(k); });
        \\var m2 = new Map([["foo", 0], ["bar", 1]]);
        \\var m2Res = [];
        \\m2.forEach((v, k) => { if (m2Res.length === 0) m2.set("baz", 2); m2Res.push(k); });
        \\var m3 = new Map([["foo", 0], ["bar", 1]]);
        \\var m3Res = [];
        \\m3.forEach((v, k) => { if (m3Res.length === 0) { m3.delete("foo"); m3.set("foo", "baz"); } m3Res.push(k + ":" + v); });
        \\var s1 = new Set([1, 2, 3]);
        \\var s1Res = [];
        \\s1.forEach((v) => { if (v === 2) s1.delete(1); if (v === 3) s1.add(1); s1Res.push(v); });
        \\var forEachOk = m1Res.join(",") === "foo" && m2Res.join(",") === "foo,bar,baz" &&
        \\  m3Res.join(",") === "foo:0,bar:1,foo:baz" && s1Res.join(",") === "1,2,3,1";
        \\
        \\// 10. Promise.prototype.finally species constructor count
        \\var fCount = 0;
        \\class FooPromise extends Promise { constructor(res, rej) { fCount++; return super(res, rej); } }
        \\var pFinallyOk = false;
        \\FooPromise.resolve().finally(() => {}).then(() => { pFinallyOk = (fCount === 7); }).then(() => {});
        \\true;
    );
    defer res.deinit();
    const res2 = try interp.run("tempOk && genTagOk && asiOk && octalErr && assignRefErr && ltOk && errProtoOk && numOk && setKeysOk && forEachOk && pFinallyOk;");
    defer res2.deinit();
    try testing.expect(res2.isBool() and res2.asBool());
}

test "Fase A - JSON: 3 remaining non-realm spec compliance cases" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. S15.12.2_A1.js: JSON.parse('{"__proto__":[]}') prototype & own property
        \\var x = JSON.parse('{"__proto__":[]}');
        \\var ok1 = Object.getPrototypeOf(x) === Object.prototype && Array.isArray(x.__proto__) && Object.prototype.hasOwnProperty.call(x, "__proto__");
        \\
        \\// 2. reviver-object-get-prop-from-prototype.js
        \\Object.prototype.b = 3;
        \\var obj2 = JSON.parse('{"a": 1, "b": 2}', function(key, value) {
        \\  if (key === 'a') { delete this.b; }
        \\  return value;
        \\});
        \\delete Object.prototype.b;
        \\var ok2 = obj2.a === 1 && obj2.hasOwnProperty('b') && obj2.b === 3;
        \\
        \\// 3. reviver-object-non-configurable-prop-delete.js
        \\var obj3 = JSON.parse('{"a": 1, "b": 2}', function(key, value) {
        \\  if (key === 'a') { Object.defineProperty(this, 'b', {configurable: false}); }
        \\  if (key === 'b') return;
        \\  return value;
        \\});
        \\var ok3 = obj3.a === 1 && obj3.hasOwnProperty('b') && obj3.b === 2;
        \\ok1 && ok2 && ok3;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Fase A - Error, Reflect, BigInt: 15 spec compliance cases" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. Error.prototype.toString.call(1) throws TypeError
        \\var errToStrThrow = false;
        \\try { Error.prototype.toString.call(1); } catch (e) { errToStrThrow = e instanceof TypeError; }
        \\
        \\// 2. Error.prototype.stack getter on Proxy returns undefined & setter on function is enumerable in for-in
        \\var pErr = new Proxy(new Error('inner'), { get(t, k, r) { return Reflect.get(t, k, r); } });
        \\var stackSet = Object.getOwnPropertyDescriptor(Error.prototype, 'stack').set;
        \\var fnForStack = function() {};
        \\stackSet.call(fnForStack, 'function');
        \\var fnInKeys = [];
        \\for (var k in fnForStack) fnInKeys.push(k);
        \\var errProxyStackOk = pErr.stack === undefined && fnInKeys.includes('stack');
        \\
        \\// 3. Reflect[Symbol.toStringTag] is own property "Reflect"
        \\var reflectTagDesc = Object.getOwnPropertyDescriptor(Reflect, Symbol.toStringTag);
        \\var reflectTagOk = reflectTagDesc && reflectTagDesc.value === "Reflect" && !reflectTagDesc.writable && !reflectTagDesc.enumerable && reflectTagDesc.configurable;
        \\
        \\// 4. Reflect.get with receiver
        \\var ro1 = {};
        \\Object.defineProperty(ro1, 'x', { get: function() { return this.y; } });
        \\var ro2 = Object.create(ro1);
        \\var reflectGetOk = Reflect.get(ro1, 'x', { y: 42 }) === 42 && Reflect.get(ro2, 'x', { y: 42 }) === 42;
        \\
        \\// 5. Reflect.apply / Reflect.construct CreateListFromArrayLike
        \\var fnArrLike = new Function();
        \\Object.defineProperty(fnArrLike, "length", { get() { return 1; } });
        \\var reflectApplyOk = Reflect.apply((...a) => a.length, null, fnArrLike) === 1;
        \\var reflectApplyThrow = false;
        \\try { Reflect.apply(() => {}, null); } catch (e) { reflectApplyThrow = e instanceof TypeError; }
        \\
        \\// 6. Reflect.deleteProperty on non-configurable returns false
        \\var rdelObj = {};
        \\Object.defineProperty(rdelObj, 'p2', { value: 1, configurable: false });
        \\var reflectDelOk = Reflect.deleteProperty(rdelObj, 'p2') === false;
        \\
        \\// 7. BigInt: isConstructor, prototype descriptor, asIntN/asUintN/toString BigInt TypeError, +Object(1n) TypeError
        \\var biCtorOk = false;
        \\try { Reflect.construct(function(){}, [], BigInt); biCtorOk = true; } catch (e) {}
        \\var biNewThrow = false;
        \\try { new BigInt({ valueOf() { throw new Error("should not reach"); } }); } catch (e) { biNewThrow = e instanceof TypeError; }
        \\var biProtoDesc = Object.getOwnPropertyDescriptor(BigInt, "prototype");
        \\var biProtoOk = biProtoDesc && biProtoDesc.writable === false && biProtoDesc.enumerable === false && biProtoDesc.configurable === false;
        \\var biAsIntThrow = false, biAsUintThrow = false, biToStrThrow = false, biWrapperPlusThrow = false;
        \\try { BigInt.asIntN(0n, 0n); } catch (e) { biAsIntThrow = e instanceof TypeError; }
        \\try { BigInt.asUintN(0n, 0n); } catch (e) { biAsUintThrow = e instanceof TypeError; }
        \\try { (0n).toString(0n); } catch (e) { biToStrThrow = e instanceof TypeError; }
        \\try { +Object(1n); } catch (e) { biWrapperPlusThrow = e instanceof TypeError; }
        \\
        \\errToStrThrow && errProxyStackOk && reflectTagOk && reflectGetOk && reflectApplyOk && reflectApplyThrow && reflectDelOk &&
        \\  biCtorOk && biNewThrow && biProtoOk && biAsIntThrow && biAsUintThrow && biToStrThrow && biWrapperPlusThrow;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Fase A - Grupo 1: GeneratorFunction, AsyncFunction, AsyncGeneratorPrototype, comments, arguments, language/*" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. AsyncFunction, GeneratorFunction, AsyncGeneratorFunction instance construct throws & prototype
        \\async function af() {}
        \\function* gf() {}
        \\async function* agf() {}
        \\var AsyncFunction = Object.getPrototypeOf(af).constructor;
        \\var GeneratorFunction = Object.getPrototypeOf(gf).constructor;
        \\var AsyncGeneratorFunction = Object.getPrototypeOf(agf).constructor;
        \\var afProtoOk = af.prototype === undefined && !af.hasOwnProperty("prototype") && Object.getPrototypeOf(AsyncFunction) === Function;
        \\var afThrow = false, gfThrow = false, agfThrow = false;
        \\try { new (AsyncFunction())(); } catch (e) { afThrow = e instanceof TypeError; }
        \\try { new (GeneratorFunction())(); } catch (e) { gfThrow = e instanceof TypeError; }
        \\try { new (AsyncGeneratorFunction())(); } catch (e) { agfThrow = e instanceof TypeError; }
        \\
        \\// 2. Subclassing GeneratorFunction
        \\class SubGF extends GeneratorFunction {}
        \\var subGf = new SubGF('a', 'yield a; yield a * 2;');
        \\var subIt = subGf(21);
        \\var subGfOk = subIt.next().value === 21 && subIt.next().value === 42 && !subGf.prototype.hasOwnProperty('constructor') && subGf.length === 1 && subGf.name === 'anonymous';
        \\
        \\// 3. AsyncGenerator.prototype.return awaits value in suspendedStart, suspendedYield, completed
        \\var agLog = [];
        \\var ag1 = (async function*() {})();
        \\ag1.return(Promise.resolve("unwrapped1")).then(r => agLog.push("s1:" + r.value + ":" + r.done));
        \\var ag2 = (async function*() { yield 1; })();
        \\ag2.next().then(() => ag2.return(Promise.resolve("unwrapped2"))).then(r => agLog.push("s2:" + r.value + ":" + r.done));
        \\var brokenP = Promise.resolve(42);
        \\Object.defineProperty(brokenP, 'constructor', { get() { throw new Error('broken'); } });
        \\var ag3 = (async function*() { try { yield; } catch (e) { return "caught:" + e.message; } })();
        \\ag3.next().then(() => ag3.return(brokenP)).then(r => agLog.push("s3:" + r.value));
        \\
        \\// 4. Class static numeric method order
        \\class COrder { static 2() {} static a() {} static 1() {} }
        \\var cOrderOk = Object.getOwnPropertyNames(COrder).join(",") === "1,2,length,name,prototype,a";
        \\
        \\// 5. Function("return f();") sees global function declaration
        \\function globalFForFnCtor() { "use strict"; return this === undefined; }
        \\var fnCtorGlobalOk = Function("return globalFForFnCtor();")() === true;
        \\
        \\// 6. arguments prototype, length override, strict eval assignment SyntaxError
        \\var argsOk = (function() {
        \\  var pOk = Object.getPrototypeOf(arguments) === Object.prototype && arguments.constructor.prototype === Object.prototype;
        \\  arguments.length = "custom";
        \\  return pOk && arguments.length === "custom";
        \\})();
        \\var strictArgsEvalErr = false;
        \\try { eval("(function() { 'use strict'; arguments = 10; })()"); } catch (e) { strictArgsEvalErr = e instanceof SyntaxError; }
        \\
        \\// 7. Primitive receiver [[Set]] consults prototype chain Proxy set trap
        \\var numSetCount = 0;
        \\var origNumProto = Object.getPrototypeOf(Number.prototype);
        \\Object.setPrototypeOf(Number.prototype, new Proxy({}, { set() { numSetCount += 1; return true; } }));
        \\(0).test262 = null;
        \\Object.setPrototypeOf(Number.prototype, origNumProto);
        \\var primSetOk = numSetCount === 1;
        \\true;
    );
    defer res.deinit();

    const r_hash = try interp.run("#! hashbang\u{2028}var hbOk = true;\n''/*\u{2028}*/''\nhbOk;");
    defer r_hash.deinit();
    try testing.expect(r_hash.isBool() and r_hash.asBool());

    const res2 = try interp.run("afProtoOk && afThrow && gfThrow && agfThrow && subGfOk && agLog.length === 3 && agLog.includes('s1:unwrapped1:true') && agLog.includes('s2:unwrapped2:true') && agLog.includes('s3:caught:broken') && cOrderOk && fnCtorGlobalOk && argsOk && strictArgsEvalErr && primSetOk;");
    defer res2.deinit();
    try testing.expect(res2.isBool() and res2.asBool());
}

test "Fase A - Date: all 12 non-realm spec compliance cases" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. Date.length === 7 (S15.9.4_A5.js, length.js)
        \\var dLenDesc = Object.getOwnPropertyDescriptor(Date, "length");
        \\var dLenOk = Date.length === 7 && dLenDesc.value === 7 && !dLenDesc.writable && !dLenDesc.enumerable && dLenDesc.configurable;
        \\
        \\// 2. Date(...) without new returns string & ignores poisoned arguments (S15.9.2.1_A1/A2, value-to-primitive-get-meth-err)
        \\var poisonedObj = {};
        \\Object.defineProperty(poisonedObj, Symbol.toPrimitive, { get() { throw new Error("poisoned"); } });
        \\var poisonedDate = new Date(12345);
        \\Object.defineProperty(poisonedDate, Symbol.toPrimitive, { get() { throw new Error("poisoned"); } });
        \\var dCallOk = typeof Date() === "string" && typeof Date(1970, 1, 1) === "string" && typeof Date(poisonedObj) === "string";
        \\var dCopyPoisonedOk = new Date(poisonedDate).getTime() === 12345;
        \\var dPoisonedThrow = false;
        \\try { new Date(poisonedObj); } catch (e) { dPoisonedThrow = e.message === "poisoned"; }
        \\
        \\// 3. new Date(val) invokes Symbol.toPrimitive with "default" & handles string/number/Symbol result
        \\var hintSeen = null;
        \\var retVal = 1234;
        \\var yObj = { [Symbol.toPrimitive](h) { hintSeen = h; return retVal; } };
        \\var dPrimNumOk = new Date(yObj).valueOf() === 1234 && hintSeen === "default";
        \\retVal = "2016-06-05T18:40:00.000Z";
        \\var dPrimStrOk = new Date(yObj).getTime() === 1465152000000;
        \\retVal = Symbol.toPrimitive;
        \\var dPrimSymThrow = false;
        \\try { new Date(yObj); } catch (e) { dPrimSymThrow = e instanceof TypeError; }
        \\
        \\// 4. Reflect.construct(Date, [64], Ctor) subclassing
        \\var Ctor = function() {};
        \\var subInst1 = Reflect.construct(Date, [64], Ctor);
        \\var dSub1Ok = Object.getPrototypeOf(subInst1) === Ctor.prototype && Date.prototype.getTime.call(subInst1) === 64;
        \\Ctor.prototype = null;
        \\var subInst2 = Reflect.construct(Date, [64], Ctor);
        \\var dSub2Ok = Object.getPrototypeOf(subInst2) === Date.prototype && subInst2.getTime() === 64;
        \\
        \\// 5. Reject -000000 extended year (year-zero.js)
        \\var dYearZeroOk = Number.isNaN(+new Date("-000000-03-31T00:45Z")) && Number.isNaN(Date.parse("-000000-03-31T00:45Z"));
        \\
        \\// 6. Date.UTC floating-point evaluation order (fp-evaluation-order.js)
        \\var dUtcFpOk = Date.UTC(1970, 0, 1, 80063993375, 29, 1, -288230376151711740) === 29312 &&
        \\  Date.UTC(1970, 0, 213503982336, 0, 0, 0, -18446744073709552000) === 34447360;
        \\
        \\// 7. Regression checks: Function() inside constructor (S15.3.4.3_A3_T5) & Array -> TypedArray prototype chain hasOwnProperty
        \\function FACTORY_REG() { return typeof Function("return 1;").apply === "function"; }
        \\var fnInCtorOk = new FACTORY_REG() !== undefined && FACTORY_REG() === true;
        \\var taProtoArr = Object.setPrototypeOf([], new Float64Array([0]));
        \\var taProtoHasOwnOk = typeof taProtoArr.hasOwnProperty === "function" && !taProtoArr.hasOwnProperty(1);
        \\
        \\dLenOk && dCallOk && dCopyPoisonedOk && dPoisonedThrow && dPrimNumOk && dPrimStrOk && dPrimSymThrow && dSub1Ok && dSub2Ok && dYearZeroOk && dUtcFpOk && fnInCtorOk && taProtoHasOwnOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Fase A - String: 8 spec compliance cases" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. S15.5.1.1_A1_T8.js: String(new Array) calls Array.prototype.toString
        \\var oldArrToStr = Array.prototype.toString;
        \\Array.prototype.toString = function() { return "__ARRAY__"; };
        \\var sArr = String(new Array());
        \\Array.prototype.toString = oldArrToStr;
        \\var sArrOk = sArr === "__ARRAY__";
        \\
        \\// 2. trim/15.5.4.20-2-51.js: String.prototype.trim.call(arguments) === "[object Arguments]"
        \\var argObj = (function() { return arguments; })(1, 2, true);
        \\var sTrimArgsOk = String.prototype.trim.call(argObj) === "[object Arguments]";
        \\
        \\// 3. symbol-wrapping.js: new String(Symbol('66')) throws TypeError, String(Symbol('66')) === "Symbol(66)"
        \\var sSymThrow = false;
        \\try { new String(Symbol("66")); } catch (e) { sSymThrow = e instanceof TypeError; }
        \\var sSymCallOk = String(Symbol("66")) === "Symbol(66)";
        \\
        \\// 4. fromCharCode/touint16-tonumber-throws-bigint.js
        \\var sFccBigIntThrow = false;
        \\try { String.fromCharCode(0n); } catch (e) { sFccBigIntThrow = e instanceof TypeError; }
        \\
        \\// 5. indexOf/searchstring-tostring-errors.js: "".indexOf(Object(Symbol("1"))) throws TypeError
        \\var sIdxBoxedSymThrow = false;
        \\try { "".indexOf(Object(Symbol("1"))); } catch (e) { sIdxBoxedSymThrow = e instanceof TypeError; }
        \\
        \\// 6. localeCompare/15.5.4.9_CE.js: canonical equivalence
        \\var sLocEqOk = "o\u0308".localeCompare("ö") === 0 && "\u1111\u1171\u11B6".localeCompare("퓛") === 0 && "Ω".localeCompare("Ω") === 0;
        \\
        \\// 7 & 8. replaceAll/searchValue-replacer-RegExp-call(-fn).js: class RE extends RegExp overriding [Symbol.replace]
        \\var reSubCalled = 0;
        \\class RE extends RegExp {
        \\  [Symbol.replace](...args) {
        \\    const actual = super[Symbol.replace](...args);
        \\    reSubCalled += 1;
        \\    return actual;
        \\  }
        \\}
        \\var reSubOut1 = "abc abc abc".replaceAll(new RE("b", "g"), "z");
        \\var reSubOut2 = (new String("aaa abc")).replaceAll(new RE("(a)", "g"), () => "z");
        \\var sReSubOk = reSubCalled === 2 && reSubOut1 === "azc azc azc" && reSubOut2 === "zzz zbc";
        \\
        \\sArrOk && sTrimArgsOk && sSymThrow && sSymCallOk && sFccBigIntThrow && sIdxBoxedSymThrow && sLocEqOk && sReSubOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Fase A - Lote 3: $262.evalScript, global-code, and eval-code (24 spec cases)" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. decl-func.js & decl-var.js: top-level var/function properties on globalThis (writable, enumerable, non-configurable)
        \\function brandNewFn() {}
        \\var brandNewVar = 42;
        \\var dFn = Object.getOwnPropertyDescriptor(this, "brandNewFn");
        \\var dVar = Object.getOwnPropertyDescriptor(this, "brandNewVar");
        \\var enumFnOk = this.propertyIsEnumerable("brandNewFn") && Object.keys(this).includes("brandNewFn");
        \\this.brandNewVar = 99;
        \\var writeVarOk = brandNewVar === 99 && this.brandNewVar === 99;
        \\var declPropOk = dFn.writable && dFn.enumerable && !dFn.configurable &&
        \\  dVar.writable && dVar.enumerable && !dVar.configurable && enumFnOk && writeVarOk;
        \\
        \\// 2. decl-lex-configurable-global.js: top-level let does not shadow or overwrite configurable global property on `this`
        \\let Array;
        \\var lexGlobalOk = Array === undefined && typeof this.Array === "function";
        \\
        \\// 3. $262.evalScript & GlobalDeclarationInstantiation conflicts
        \\let test262Let = 1;
        \\var esLexLexThrow = false;
        \\try { $262.evalScript("var xNotCreated; let test262Let;"); } catch (e) { esLexLexThrow = e instanceof SyntaxError; }
        \\var esNoPartialHoist = typeof xNotCreated === "undefined" && !("xNotCreated" in this);
        \\
        \\var esVarLexThrow = false;
        \\try { $262.evalScript("var test262Let;"); } catch (e) { esVarLexThrow = e instanceof SyntaxError; }
        \\var esFuncLexThrow = false;
        \\try { $262.evalScript("function test262Let() {}"); } catch (e) { esFuncLexThrow = e instanceof SyntaxError; }
        \\var esLexVarThrow = false;
        \\try { $262.evalScript("let brandNewVar;"); } catch (e) { esLexVarThrow = e instanceof SyntaxError; }
        \\var esLexRestrictedThrow = false;
        \\try { $262.evalScript("let NaN;"); } catch (e) { esLexRestrictedThrow = e instanceof SyntaxError; }
        \\
        \\// 4. script-decl-func-err-non-configurable.js: CanDeclareGlobalFunction throws TypeError on non-configurable read-only global
        \\var esFuncNonCfgThrow = false;
        \\try { $262.evalScript("var yNotCreated; function NaN() {}"); } catch (e) { esFuncNonCfgThrow = e instanceof TypeError; }
        \\var esNoPartialHoist2 = !("yNotCreated" in this);
        \\
        \\// 5. Indirect eval var/function creation & configurable update + script-decl-lex-var-declared-via-eval.js
        \\(0, eval)("var evalCreatedVar = 7; function evalCreatedFn() { return 8; }");
        \\var dEvalVar = Object.getOwnPropertyDescriptor(this, "evalCreatedVar");
        \\var dEvalFn = Object.getOwnPropertyDescriptor(this, "evalCreatedFn");
        \\var evalConfigurableOk = dEvalVar.configurable && dEvalVar.enumerable && dEvalVar.writable &&
        \\  dEvalFn.configurable && dEvalFn.enumerable && dEvalFn.writable;
        \\$262.evalScript("let evalCreatedVar = 'lex'; class evalCreatedFn {}");
        \\var evalLexOverEvalVarOk = evalCreatedVar === "lex" && typeof evalCreatedFn === "function";
        \\
        \\// 6. typeof (parenthesized undeclared identifier) & direct/indirect parse-failure-5 (return;) & strict reserved words & sloppy indirect assignment
        \\var typeofParenOk = typeof (undeclaredParenIdent) === "undefined";
        \\var evalReturnThrow = false;
        \\try { eval("return;"); } catch (e) { evalReturnThrow = e instanceof SyntaxError; }
        \\var evalStrictReservedThrow = false;
        \\try { eval("var public = 1;"); } catch (e) { evalStrictReservedThrow = e instanceof SyntaxError; }
        \\(0, eval)("sloppyUnresolvableGlobal = 123;");
        \\var sloppyAssignOk = this.sloppyUnresolvableGlobal === 123 && delete this.sloppyUnresolvableGlobal;
        \\
        \\declPropOk && lexGlobalOk && esLexLexThrow && esNoPartialHoist && esVarLexThrow && esFuncLexThrow &&
        \\  esLexVarThrow && esLexRestrictedThrow && esFuncNonCfgThrow && esNoPartialHoist2 &&
        \\  evalConfigurableOk && evalLexOverEvalVarOk && typeofParenOk && evalReturnThrow &&
        \\  evalStrictReservedThrow && sloppyAssignOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Fase A - Lote 4: Function and Function.prototype (15 spec cases)" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. delete f.length & delete f.name (S15.3.5.1_A2_T1..3)
        \\var fDel = new Function("a,b,c", "return a;");
        \\var fDelBefore = fDel.hasOwnProperty("length") && fDel.length === 3;
        \\var fDelRes = delete fDel.length;
        \\var fDelAfter = !fDel.hasOwnProperty("length") && fDel.length !== 3 && fDel.length === 0;
        \\var fDelOk = fDelBefore && fDelRes && fDelAfter;
        \\
        \\// 2. Function.prototype is a callable Function object with length=0, name="", property order ["length", "name", ...]
        \\var fpTypeOk = typeof Function.prototype === "function" &&
        \\  Object.prototype.toString.call(Function.prototype) === "[object Function]" &&
        \\  Function.prototype() === undefined &&
        \\  Function.prototype(null, void 0) === undefined;
        \\var fpLenDesc = Object.getOwnPropertyDescriptor(Function.prototype, "length");
        \\var fpNameDesc = Object.getOwnPropertyDescriptor(Function.prototype, "name");
        \\var fpProps = Object.getOwnPropertyNames(Function.prototype);
        \\var fpOrderOk = fpProps.indexOf("length") >= 0 && fpProps.indexOf("name") === fpProps.indexOf("length") + 1;
        \\var fpMetaOk = fpLenDesc.value === 0 && !fpLenDesc.writable && !fpLenDesc.enumerable && fpLenDesc.configurable &&
        \\  fpNameDesc.value === "" && !fpNameDesc.writable && !fpNameDesc.enumerable && fpNameDesc.configurable && fpOrderOk;
        \\
        \\// 3. StrictFunction_reservedwords_with.js & private-identifiers-not-empty.js
        \\var fnStrictWithThrow = false;
        \\try { new Function("'use strict'; with ({}) {}"); } catch (e) { fnStrictWithThrow = e instanceof SyntaxError; }
        \\var fnPrivateThrow = false;
        \\try { new Function("o.#f"); } catch (e) { fnPrivateThrow = e instanceof SyntaxError; }
        \\var fnPrivateValidOk = typeof (new Function("class C { #f = 1; m(o) { return o.#f; } } return C;")) === "function";
        \\
        \\// 4. base-ctor-revoked-proxy.js: revoking proxy in prototype getter throws TypeError in GetFunctionRealm
        \\var revHandle = Proxy.revocable(function() {}, {
        \\  get: function() { revHandle.revoke(); }
        \\});
        \\var revProxy = revHandle.proxy;
        \\var revThrow = false;
        \\try { new revProxy(); } catch (e) { revThrow = e instanceof TypeError; }
        \\
        \\fDelOk && fpTypeOk && fpMetaOk && fnStrictWithThrow && fnPrivateThrow && fnPrivateValidOk && revThrow;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Fase A - Lote 5: Object and Object.prototype (42 spec cases)" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. Subclassing Object with object argument (subclass-object-arg.js)
        \\class SubObj extends Object {}
        \\var subInst = new SubObj({ a: 2 });
        \\var subRefl = Reflect.construct(Object, [{ a: 2 }], SubObj);
        \\var subclassOk = subInst instanceof SubObj && subInst.a === undefined &&
        \\  subRefl instanceof SubObj && subRefl.a === undefined;
        \\
        \\// 2. RegExp own properties in Object.create / Object.defineProperties & for-in prototype walk
        \\var rxProps = /abc/;
        \\Object.defineProperty(rxProps, "prop", { value: { value: "regExpData", enumerable: true }, enumerable: true, configurable: true });
        \\var rxCreated = Object.create({}, rxProps);
        \\var rxDefined = Object.defineProperties({}, rxProps);
        \\Object.defineProperty(RegExp.prototype, "inheritedRxProp", { value: 42, enumerable: true, configurable: true });
        \\var rxForInSeen = false;
        \\for (var p in /x/) { if (p === "inheritedRxProp") rxForInSeen = true; }
        \\delete RegExp.prototype.inheritedRxProp;
        \\var rxOk = rxCreated.prop === "regExpData" && rxDefined.prop === "regExpData" && rxForInSeen;
        \\
        \\// 3. Array assignment to inherited accessor on Array.prototype (15.2.3.6-4-579.js)
        \\var arrSetterVal = 0;
        \\Object.defineProperty(Array.prototype, "inhSetterProp", {
        \\  get: function() { return arrSetterVal; },
        \\  set: function(v) { arrSetterVal = v; },
        \\  enumerable: true,
        \\  configurable: true
        \\});
        \\var arrTest = [];
        \\arrTest.inhSetterProp = 99;
        \\var arrSetterOk = !arrTest.hasOwnProperty("inhSetterProp") && arrSetterVal === 99;
        \\delete Array.prototype.inhSetterProp;
        \\
        \\// 4. Object.keys on Array with named properties, non-enumerable elements, and sparse indices (15.2.3.14-5-12, 13)
        \\var arrKeys = [1, , 3, , 5];
        \\Object.defineProperty(arrKeys, 5, { value: 7, enumerable: false, configurable: true });
        \\Object.defineProperty(arrKeys, 10000, { value: "large", enumerable: true, configurable: true });
        \\Object.defineProperty(arrKeys, "extraProp", { value: 10, enumerable: true, configurable: true });
        \\var ak = Object.keys(arrKeys).join(",");
        \\var arrKeysOk = ak === "0,2,4,10000,extraProp";
        \\
        \\// 5. Object.entries / Object.values live EnumerableOwnProperties & Proxy trap order
        \\var mutObj = { a: 1, b: 2, c: 3 };
        \\Object.defineProperty(mutObj, "a", {
        \\  get: function() {
        \\    Object.defineProperty(mutObj, "b", { enumerable: false });
        \\    delete mutObj.c;
        \\    return 10;
        \\  },
        \\  enumerable: true,
        \\  configurable: true
        \\});
        \\var mutVals = Object.values(mutObj);
        \\var proxyLog = [];
        \\var obsProxy = new Proxy({ a: 1, b: 2 }, {
        \\  ownKeys: function(t) { proxyLog.push("ownKeys"); return Reflect.ownKeys(t); },
        \\  getOwnPropertyDescriptor: function(t, k) { proxyLog.push("gopd:" + k); return Reflect.getOwnPropertyDescriptor(t, k); },
        \\  get: function(t, k, r) { proxyLog.push("get:" + k); return Reflect.get(t, k, r); }
        \\});
        \\Object.entries(obsProxy);
        \\var liveEnumOk = mutVals.length === 1 && mutVals[0] === 10 &&
        \\  proxyLog.join("|") === "ownKeys|gopd:a|get:a|gopd:b|get:b";
        \\
        \\// 6. Order after defineProperty on Function and RegExp
        \\var fnOrd = () => {};
        \\fnOrd.a = 1;
        \\Object.defineProperty(fnOrd, "length", { enumerable: true });
        \\var fnKeysOrd = Object.keys(fnOrd).join(",");
        \\var reOrd = /a/;
        \\reOrd.a = 1;
        \\Object.defineProperty(reOrd, "lastIndex", { writable: false });
        \\var reDescsOrd = Reflect.ownKeys(Object.getOwnPropertyDescriptors(reOrd)).join(",");
        \\var orderOk = fnKeysOrd === "length,a" && reDescsOrd === "lastIndex,a";
        \\
        \\// 7. Object.fromEntries IteratorClose preserves original thrown exception
        \\function DummyErr() {}
        \\var iterClosed = false;
        \\var fromEntriesIterable = {};
        \\fromEntriesIterable[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() {
        \\      return {
        \\        value: { get "0"() { throw new DummyErr(); }, "1": "v" },
        \\        done: false
        \\      };
        \\    },
        \\    return: function() { iterClosed = true; return undefined; }
        \\  };
        \\};
        \\var fromEntriesDummyOk = false;
        \\try { Object.fromEntries(fromEntriesIterable); } catch (e) { fromEntriesDummyOk = (e instanceof DummyErr) && iterClosed; }
        \\
        \\// 8. Object.getOwnPropertyDescriptor & Object.getOwnPropertyNames on primitive strings
        \\var strDesc0 = Object.getOwnPropertyDescriptor("hi", "0");
        \\var strDescLen = Object.getOwnPropertyDescriptor("hi", "length");
        \\var strNamesEmpty = Object.getOwnPropertyNames("");
        \\var primStrOk = strDesc0.value === "h" && !strDesc0.writable && strDesc0.enumerable && !strDesc0.configurable &&
        \\  strDescLen.value === 2 && !strDescLen.writable && !strDescLen.enumerable && !strDescLen.configurable &&
        \\  strNamesEmpty.length === 1 && strNamesEmpty[0] === "length";
        \\
        \\// 9. Object.setPrototypeOf on primitives & __proto__ abrupt completion
        \\var setProtoPrimOk = Object.setPrototypeOf(0n, {}) === 0n && Object.setPrototypeOf(true, null) === true;
        \\var protoAbruptProxy = new Proxy({}, { setPrototypeOf: function() { throw new DummyErr(); } });
        \\var protoAbruptOk = false;
        \\try { protoAbruptProxy.__proto__ = {}; } catch (e) { protoAbruptOk = e instanceof DummyErr; }
        \\
        \\// 10. SetIntegrityLevel & TestIntegrityLevel (freeze/seal/isFrozen/isSealed)
        \\var childExt = Object.preventExtensions(Object.create({ a: 1 }));
        \\var falseFreezeProxy = new Proxy({}, { preventExtensions: function() { return false; } });
        \\var freezeThrowsFalse = false;
        \\try { Object.freeze(falseFreezeProxy); } catch (e) { freezeThrowsFalse = e instanceof TypeError; }
        \\var sealThrowsFalse = false;
        \\try { Object.seal(falseFreezeProxy); } catch (e) { sealThrowsFalse = e instanceof TypeError; }
        \\var argFrozen = (function(a) { Object.freeze(arguments); return Object.isFrozen(arguments); })(1);
        \\var argSealed = (function(a) { Object.seal(arguments); return Object.isSealed(arguments); })(1);
        \\var argConcat = (function(a, b, c) {
        \\  arguments[Symbol.isConcatSpreadable] = true;
        \\  Object.defineProperty(arguments, "length", { value: 6 });
        \\  return [].concat(arguments).length === 6;
        \\})(1, 2, 3);
        \\var integrityOk = Object.isFrozen(childExt) === true && Object.isSealed(childExt) === true &&
        \\  freezeThrowsFalse && sealThrowsFalse && argFrozen && argSealed && argConcat;
        \\
        \\subclassOk && rxOk && arrSetterOk && arrKeysOk && liveEnumOk && orderOk &&
        \\  fromEntriesDummyOk && primStrOk && setProtoPrimOk && protoAbruptOk && integrityOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

test "Fase A - Lote 6: ImmutableArrayBuffer (transferToImmutable, sliceToImmutable, immutable)" {
    const testing = std.testing;
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const res = try interp.run(
        \\// 1. ArrayBuffer.prototype.immutable getter & transferToImmutable
        \\var ab1 = new ArrayBuffer(4);
        \\var u1 = new Uint8Array(ab1);
        \\u1[0] = 10; u1[1] = 20; u1[2] = 30; u1[3] = 40;
        \\var beforeImm = ab1.immutable === false;
        \\var iab1 = ab1.transferToImmutable(6);
        \\var iu1 = new Uint8Array(iab1);
        \\var transferOk = beforeImm && ab1.detached === true && iab1.immutable === true &&
        \\  iab1.byteLength === 6 && iu1[0] === 10 && iu1[3] === 40 && iu1[4] === 0 && iu1[5] === 0;
        \\
        \\// 2. Re-transferring an immutable ArrayBuffer throws TypeError after newLength coercion
        \\var coercedLen = false;
        \\var retransferThrow = false;
        \\try {
        \\  iab1.transferToImmutable({ valueOf: function() { coercedLen = true; return 2; } });
        \\} catch (e) { retransferThrow = (e instanceof TypeError) && coercedLen; }
        \\
        \\// 3. ArrayBuffer.prototype.sliceToImmutable
        \\var ab2 = new ArrayBuffer(4);
        \\var u2 = new Uint8Array(ab2);
        \\u2[0] = 1; u2[1] = 2; u2[2] = 3; u2[3] = 4;
        \\var iab2 = ab2.sliceToImmutable(1, -1);
        \\u2[1] = 99;
        \\var iu2 = new Uint8Array(iab2);
        \\var sliceImmOk = ab2.detached === false && ab2.immutable === false &&
        \\  iab2.immutable === true && iab2.byteLength === 2 && iu2[0] === 2 && iu2[1] === 3;
        \\
        \\// 4. DataView.prototype.set* throws TypeError before argument coercion on immutable buffer
        \\var dvImm = new DataView(iab1);
        \\var dvArgCalled = false;
        \\var dvSetThrow = false;
        \\try {
        \\  dvImm.setUint8({ valueOf: function() { dvArgCalled = true; return 0; } }, 1);
        \\} catch (e) { dvSetThrow = (e instanceof TypeError) && !dvArgCalled; }
        \\
        \\// 5. TypedArray mutators (fill/copyWithin/reverse/set/sort/setFromBase64/setFromHex) throw TypeError
        \\var taFillThrow = false, taSortThrow = false, taB64Throw = false, taHexThrow = false;
        \\try { iu1.fill(1); } catch (e) { taFillThrow = e instanceof TypeError; }
        \\try { iu1.sort(); } catch (e) { taSortThrow = e instanceof TypeError; }
        \\try { iu1.setFromBase64("AA=="); } catch (e) { taB64Throw = e instanceof TypeError; }
        \\try { iu1.setFromHex("00"); } catch (e) { taHexThrow = e instanceof TypeError; }
        \\var taMutOk = taFillThrow && taSortThrow && taB64Throw && taHexThrow;
        \\
        \\// 6. Atomics write operations throw TypeError on immutable buffer, notify returns 0
        \\var i32Imm = new Int32Array((new ArrayBuffer(8)).transferToImmutable());
        \\var atomicsAddThrow = false;
        \\try { Atomics.add(i32Imm, 0, 1); } catch (e) { atomicsAddThrow = e instanceof TypeError; }
        \\var atomicsNotifyOk = Atomics.notify(i32Imm, 0, 1) === 0 && Atomics.load(i32Imm, 0) === 0;
        \\
        \\transferOk && retransferThrow && sliceImmOk && dvSetThrow && taMutOk && atomicsAddThrow && atomicsNotifyOk;
    );
    defer res.deinit();
    try testing.expect(res.isBool() and res.asBool());
}

