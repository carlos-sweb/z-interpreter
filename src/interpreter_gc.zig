//! GC subsystem: the "all live GC objects" registry (`GcNode`/
//! `GcRegistry`), the mark-sweep cycle collector (`Marker`/`Sweeper`/
//! `markRoots`/`freeGarbageNode`/`collectGarbage`), every `gcTrack*`/
//! `gcNew*` allocation-site helper, `traceValueChildren`, and
//! `Interpreter.init`/`deinit`. Also carries `throwValue`/`throwError`
//! (the exception-raising machinery): tiny (2 methods) but universally
//! called, and its only outbound dependency is `gcNewError` here, so it
//! rides along in the same file rather than getting its own.
//!
//! The ONLY cluster (of 21 identified by the call-graph analysis, see
//! z-interpreter-refactor.md's Phase C section) with ZERO outbound calls
//! into any other cluster -- confirmed mechanically, not just plausible
//! by inspection. Every method here is `pub` (even ones that were
//! `fn`-private inside the `Interpreter` struct) because
//! `interpreter.zig`'s `pub const foo = interpreter_gc.foo;` /
//! `const foo = interpreter_gc.foo;` alias declarations need to reach
//! them from a different file; the alias's OWN pub/private status (not
//! this file's) is what actually gates external visibility, exactly as
//! before the split. `GcNode` holds `*ClosureCtx`/`*FiberState`/
//! `*ClassCtx` pointers (types that stay in `interpreter.zig`, owned by
//! future Phase C batches) -- those three types plus
//! `classCtxFromOpaque` and their `traceChildren` methods were made
//! `pub` in `interpreter.zig` for this file to reach across.
//! z-interpreter-refactor.md, Step 5 Phase C batch 1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zparser = @import("zparser");
const zfunctions = @import("zfunctions");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
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

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const Environment = interpreter_mod.Environment;
const Protos = interpreter_mod.Protos;
const RegexState = interpreter_mod.RegexState;
const ClosureCtx = interpreter_mod.ClosureCtx;
const FiberState = interpreter_mod.FiberState;
const ClassCtx = interpreter_mod.ClassCtx;
const classCtxFromOpaque = interpreter_mod.classCtxFromOpaque;
const builtins = @import("builtins.zig");
const fiber_mod = @import("fiber.zig");

const GcNode = union(enum) {
    array: *zvalue.Rc(zarray.ZArray(JSValue)),
    object: *zvalue.Rc(zobject.ZObject(JSValue)),
    regex: *zvalue.Rc(zregex.Regex),
    map: *zvalue.Rc(zmap.ZMap(JSValue, JSValue)),
    set: *zvalue.Rc(zset.ZSet(JSValue)),
    @"error": *zvalue.Rc(zerror.ZError(JSValue)),
    function: *zvalue.Rc(zvalue.Callable),
    promise: *zvalue.Rc(zvalue.ZPromise(JSValue)),
    /// NOT a leaf like symbol/string/date/bigint below -- holds
    /// `target`/`handler` JSValues that can form real cycles (a handler
    /// closing over the very proxy it traps), so it needs full
    /// trace/sweep like array/object/map/set/error/function/promise
    /// above.
    proxy: *zvalue.Rc(zvalue.Proxy),
    /// `.array_buffer` is a leaf like symbol/string/date/bigint below
    /// (owns raw bytes, no JSValue children); `.data_view` is NOT --
    /// it holds an `owner: JSValue` (the `.array_buffer` it reads/writes
    /// through), same non-leaf category as proxy above.
    array_buffer: *zvalue.Rc(zvalue.ArrayBuffer),
    data_view: *zvalue.Rc(zvalue.DataViewBox),
    /// Same non-leaf category as `.data_view` -- holds an `owner`
    /// JSValue (the `.array_buffer` it reads/writes through).
    typed_array: *zvalue.Rc(zvalue.TypedArrayBox),
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
    /// Same "leaf, but still registered" rationale as symbol/string above
    /// -- a BigInt literal is created and often immediately retained for
    /// storage elsewhere, hitting the same "declaration leaves refcount
    /// 2, not 1" quirk.
    bigint: *zvalue.Rc(zbigint.ZBigInt),
    /// Same "leaf, but still registered" rationale as symbol/string/date/
    /// bigint above -- every z-temporal type is a pure value with no
    /// JSValue children.
    temporal: *zvalue.Rc(zvalue.TemporalValue),
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
pub const GcRegistry = std.AutoHashMapUnmanaged(usize, GcNode);

/// The box address of a heap-boxed JSValue, or null for the 4 inline/leaf
/// variants (undefined/null/boolean/number) that never enter the GC
/// registry at all. Shared by `Marker.value`/`Sweeper.value`, which
/// otherwise independently re-enumerated the exact same 17-variant list
/// (z-interpreter-refactor.md, Step 1b) -- `gcTrack` keeps its own
/// separate switch (Step 1c uses this one as a gate on that one, rather
/// than merging them, since gcTrack needs a typed `GcNode`, not just an
/// address).
fn heapBoxAddress(v: JSValue) ?usize {
    return switch (v) {
        .undefined, .null, .boolean, .number => null,
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
        .bigint => |box| @intFromPtr(box),
        .proxy => |box| @intFromPtr(box),
        .array_buffer => |box| @intFromPtr(box),
        .data_view => |box| @intFromPtr(box),
        .typed_array => |box| @intFromPtr(box),
        .temporal => |box| @intFromPtr(box),
    };
}

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
        const addr = heapBoxAddress(v) orelse return;
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
        const addr = heapBoxAddress(v) orelse return;
        if (self.garbage.contains(addr)) return;
        v.deinit();
    }

    pub fn environment(self: *Sweeper, e: *Environment) void {
        _ = self;
        _ = e;
    }
};

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
pub fn gcOnBoxDestroyed(ctx: *anyopaque, box: *anyopaque) void {
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
pub fn gcTrack(self: *Interpreter, v: JSValue) !void {
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
        .bigint => |box| .{ .bigint = box },
        .proxy => |box| .{ .proxy = box },
        .array_buffer => |box| .{ .array_buffer = box },
        .data_view => |box| .{ .data_view = box },
        .typed_array => |box| .{ .typed_array = box },
        .temporal => |box| .{ .temporal = box },
        else => {
            // heapBoxAddress is the source of truth for "does this
            // variant need tracking at all" -- if it says yes but the
            // switch above (which independently lists every boxed
            // variant, since it builds a *typed* GcNode heapBoxAddress
            // can't construct) has no case for it, that's exactly the
            // silent-miss bug class that let `.temporal` leak
            // permanently before this was caught (z-interpreter-refactor.md,
            // Step 1c). Fail loud immediately instead of silently
            // dropping the value from the GC registry.
            if (heapBoxAddress(v) != null) unreachable;
            return;
        },
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
pub fn gcTrackNode(self: *Interpreter, node: GcNode) !void {
    try self.gc_registry.put(self.gc_allocator, node.address(), node);
}
pub fn gcTrackEnvironment(self: *Interpreter, e: *Environment) !void {
    try self.gcTrackNode(.{ .environment = e });
}
pub fn gcTrackClosureCtx(self: *Interpreter, cc: *ClosureCtx) !void {
    try self.gcTrackNode(.{ .closure_ctx = cc });
}
pub fn gcTrackFiberState(self: *Interpreter, fs: *FiberState) !void {
    try self.gcTrackNode(.{ .fiber_state = fs });
}
pub fn gcTrackClassCtx(self: *Interpreter, cx: *ClassCtx) !void {
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
pub fn gcNewTemporal(self: *Interpreter, value: zvalue.TemporalValue) !JSValue {
    const v = try JSValue.newTemporal(self.gc_allocator, value);
    try self.gcTrack(v);
    return v;
}
pub fn gcNewBigInt(self: *Interpreter, raw_digit_text: []const u8) !JSValue {
    const v = try JSValue.newBigInt(self.gc_allocator, raw_digit_text);
    try self.gcTrack(v);
    return v;
}
/// For a `ZBigInt` already computed by an arithmetic op (`.add`/
/// `.mul`/etc.), not parsed from literal digit text.
pub fn gcNewBigIntValue(self: *Interpreter, v: zbigint.ZBigInt) !JSValue {
    const jv = try JSValue.newBigIntFromValue(self.gc_allocator, v);
    try self.gcTrack(jv);
    return jv;
}
pub fn gcNewProxy(self: *Interpreter, target: JSValue, handler: JSValue) !JSValue {
    const v = try JSValue.newProxy(self.gc_allocator, target, handler);
    try self.gcTrack(v);
    return v;
}
pub fn gcNewArrayBuffer(self: *Interpreter, byte_length: usize) !JSValue {
    const v = try JSValue.newArrayBuffer(self.gc_allocator, byte_length);
    try self.gcTrack(v);
    return v;
}
/// For an `ArrayBuffer` already computed by an operation (e.g.
/// `ArrayBuffer.prototype.slice`'s copy), not freshly zero-allocated
/// -- same shape as `gcNewBigIntValue` for an already-computed
/// `ZBigInt`.
pub fn gcNewArrayBufferFromValue(self: *Interpreter, v: zbuffer.ArrayBuffer) !JSValue {
    const jv: JSValue = .{ .array_buffer = try zvalue.Rc(zvalue.ArrayBuffer).create(self.gc_allocator, v) };
    try self.gcTrack(jv);
    return jv;
}
/// `owner` must already be a retained `.array_buffer` JSValue handed
/// off to this call (see `JSValue.newDataView`'s doc comment) --
/// callers pass `owner.retain()` at the call site, not a bare
/// `owner`.
pub fn gcNewDataView(self: *Interpreter, owner: JSValue, byte_offset: usize, byte_length: ?usize) zbuffer.BufferError!JSValue {
    const v = try JSValue.newDataView(self.gc_allocator, owner, byte_offset, byte_length);
    try self.gcTrack(v);
    return v;
}
/// `owner` must already be a retained `.array_buffer` JSValue (see
/// `gcNewDataView`'s doc comment -- same convention).
pub fn gcNewTypedArray(self: *Interpreter, owner: JSValue, byte_offset: usize, len: ?usize, kind: zvalue.TypedKind) zbuffer.BufferError!JSValue {
    const v = try JSValue.newTypedArray(self.gc_allocator, owner, byte_offset, len, kind);
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
pub fn traceValueChildren(self: *Interpreter, v: JSValue, visitor: anytype) void {
    switch (v) {
        // "No children" here is a DIFFERENT axis than heapBoxAddress's
        // leaf/boxed split (Step 1b/1c) -- don't expect the two lists to
        // match. heapBoxAddress asks "does this variant live in the GC
        // registry at all" (4 inline variants: no); this switch asks
        // "does this variant hold any JSValue to recurse into" (11
        // variants: no) -- string/regex/symbol/date/bigint/array_buffer/
        // temporal ARE heap-boxed and DO need registry tracking, they
        // just have no JSValue children to trace. This switch has no
        // `else`, so Zig already forces a case for any newly-added
        // JSValue variant (unlike gcTrack's old bug) -- the audit here
        // (z-interpreter-refactor.md, Step 1d) is confirming *this*
        // leaf group is genuinely correct, not just present: every
        // sibling library backing these 7 types (z-string/z-regex/
        // z-symbol/z-date/z-bigint/z-buffer/z-temporal) has zero
        // dependency on z-value, so none of them can hold a JSValue even
        // in principle -- verified via each one's build.zig.zon, not
        // assumed.
        .undefined, .null, .boolean, .number, .string, .regex, .symbol, .date, .bigint, .array_buffer, .temporal => {},
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
        .proxy => |box| {
            visitor.value(box.value.target);
            visitor.value(box.value.handler);
        },
        .data_view => |box| visitor.value(box.value.owner),
        .typed_array => |box| visitor.value(box.value.owner),
    }
}

/// GC prep (phase 4): the root set. Everything reachable from here
/// (via traceChildren/traceValueChildren) survives a sweep.
pub fn markRoots(self: *Interpreter, marker: *Marker) void {
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
pub fn freeGarbageNode(self: *Interpreter, node: GcNode, sweeper: *Sweeper) void {
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
        .temporal => |box| {
            // Every z-temporal type is a pure value, same as .date.
            box.destroy();
        },
        .bigint => |box| {
            box.value.deinit();
            box.destroy();
        },
        .proxy => |box| {
            sweeper.value(box.value.target);
            sweeper.value(box.value.handler);
            box.destroy();
        },
        .array_buffer => |box| {
            box.value.deinit();
            box.destroy();
        },
        .data_view => |box| {
            sweeper.value(box.value.owner);
            box.destroy();
        },
        .typed_array => |box| {
            sweeper.value(box.value.owner);
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
pub fn freeAllGcNodes(self: *Interpreter) void {
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
