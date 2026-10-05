//! WeakMap, WeakSet, WeakRef and FinalizationRegistry (ES2015/ES2021).
//! Their instances are ordinary `.object`s (created by `new`, so their
//! prototype is the constructor's `.prototype`) whose internal slots live
//! in the interpreter's `object_slots` table, released with the object.
//!
//! Without a collector that runs during execution, this engine never
//! observes a target becoming unreachable -- a behavior the spec permits:
//! a WeakMap/WeakSet keeps its entries (it exposes no size and no
//! iteration, so the difference is unobservable), WeakRef.prototype.deref
//! always returns the target, and a FinalizationRegistry's cleanup
//! callback is never called (registrations are still recorded, so
//! `unregister` answers correctly).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const ObjectSlots = interpreter_mod.ObjectSlots;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const regex_builtins = @import("regex_builtins.zig");

const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const isObjectLike = builtin_helpers.isObjectLike;
const installBuiltin = builtin_helpers.installBuiltin;

/// CanBeHeldWeakly(v): an object, or a symbol not in the global
/// Symbol.for registry.
pub fn canBeHeldWeakly(self: *Interpreter, v: JSValue) bool {
    if (isObjectLike(v)) return true;
    if (v != .symbol) return false;
    var it = self.symbol_registry.valueIterator();
    while (it.next()) |s| {
        if (s.* == .symbol and s.symbol == v.symbol) return false;
    }
    return true;
}

/// The identity of a weakly-holdable value (its box address).
fn identity(v: JSValue) usize {
    return Interpreter.heapBoxAddress(v).?;
}

/// The slots of `this` if it is an instance of the given kind.
fn slotsOf(self: *Interpreter, this_value: JSValue, comptime kind: std.meta.Tag(ObjectSlots)) ?*ObjectSlots {
    if (this_value != .object) return null;
    const slots = self.object_slots.getPtr(@intFromPtr(this_value.object)) orelse return null;
    if (slots.* != kind) return null;
    return slots;
}

fn incompatible(self: *Interpreter, comptime what: []const u8) anyerror {
    return self.throwError(.type_error, "Method " ++ what ++ " called on incompatible receiver", .{});
}

/// The instance a constructor initializes: `this` when called by `new`
/// (constructValue armed construct_target), else a TypeError.
fn newInstance(self: *Interpreter, ctx: *anyopaque, this_value: JSValue, comptime name: []const u8) anyerror!JSValue {
    if (self.construct_target != ctx or this_value != .object)
        return self.throwError(.type_error, "Constructor " ++ name ++ " requires 'new'", .{});
    return this_value;
}

// ===== WeakMap / WeakSet =====

fn weakCollectionConstructor(comptime is_map: bool) NativeFn {
    const name = if (is_map) "WeakMap" else "WeakSet";
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const self = interp(ctx);
            const o = try newInstance(self, ctx, this_value, name);
            const empty: interpreter_mod.WeakTable = .empty;
            try self.object_slots.put(self.gc_allocator, @intFromPtr(o.object), if (is_map) .{ .weak_map = empty } else .{ .weak_set = empty });
            const iterable = arg(args, 0);
            if (iterable == .undefined or iterable == .null) return o.retain();
            // AddEntriesFromIterable / the WeakSet loop: the adder is looked
            // up once, on the new object, and called per element.
            const adder = try self.getProperty(o, if (is_map) "set" else "add");
            defer adder.deinit();
            if (adder != .function) return self.throwError(.type_error, "'" ++ (if (is_map) "set" else "add") ++ "' returned for " ++ name ++ " is not a function", .{});
            const items = try self.iterableItems(iterable);
            defer self.gc_allocator.free(items);
            for (items) |item| {
                if (is_map) {
                    if (!isObjectLike(item)) return self.throwError(.type_error, "Iterator value is not an entry object", .{});
                    const k = try self.getProperty(item, "0");
                    defer k.deinit();
                    const v = try self.getProperty(item, "1");
                    defer v.deinit();
                    const r = try self.callValue(adder, o, &.{ k, v }, "set");
                    r.deinit();
                } else {
                    const r = try self.callValue(adder, o, &.{item}, "add");
                    r.deinit();
                }
            }
            return o.retain();
        }
    }.call;
}

fn weakMapGet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const s = slotsOf(self, this_value, .weak_map) orelse return incompatible(self, "WeakMap.prototype.get");
    const key = arg(args, 0);
    if (!canBeHeldWeakly(self, key)) return JSValue.UNDEFINED;
    const e = s.weak_map.get(identity(key)) orelse return JSValue.UNDEFINED;
    return e.value.retain();
}

fn weakMapSet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const s = slotsOf(self, this_value, .weak_map) orelse return incompatible(self, "WeakMap.prototype.set");
    const key = arg(args, 0);
    if (!canBeHeldWeakly(self, key)) return self.throwError(.type_error, "Invalid value used as weak map key", .{});
    const gop = try s.weak_map.getOrPut(self.gc_allocator, identity(key));
    if (gop.found_existing) {
        gop.value_ptr.value.deinit();
        gop.value_ptr.value = arg(args, 1).retain();
    } else {
        gop.value_ptr.* = .{ .key = key.retain(), .value = arg(args, 1).retain() };
    }
    return this_value.retain();
}

fn weakHas(comptime kind: std.meta.Tag(ObjectSlots), comptime what: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const self = interp(ctx);
            const s = slotsOf(self, this_value, kind) orelse return incompatible(self, what);
            const key = arg(args, 0);
            if (!canBeHeldWeakly(self, key)) return JSValue.fromBool(false);
            return JSValue.fromBool(@field(s, @tagName(kind)).contains(identity(key)));
        }
    }.call;
}

fn weakDelete(comptime kind: std.meta.Tag(ObjectSlots), comptime what: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const self = interp(ctx);
            const s = slotsOf(self, this_value, kind) orelse return incompatible(self, what);
            const key = arg(args, 0);
            if (!canBeHeldWeakly(self, key)) return JSValue.fromBool(false);
            const kv = @field(s, @tagName(kind)).fetchRemove(identity(key)) orelse return JSValue.fromBool(false);
            kv.value.key.deinit();
            kv.value.value.deinit();
            return JSValue.fromBool(true);
        }
    }.call;
}

fn weakSetAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const s = slotsOf(self, this_value, .weak_set) orelse return incompatible(self, "WeakSet.prototype.add");
    const v = arg(args, 0);
    if (!canBeHeldWeakly(self, v)) return self.throwError(.type_error, "Invalid value used in weak set", .{});
    const gop = try s.weak_set.getOrPut(self.gc_allocator, identity(v));
    if (!gop.found_existing) gop.value_ptr.* = .{ .key = v.retain(), .value = JSValue.UNDEFINED };
    return this_value.retain();
}

// ===== WeakRef =====

fn weakRefConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const o = try newInstance(self, ctx, this_value, "WeakRef");
    const target = arg(args, 0);
    if (!canBeHeldWeakly(self, target)) return self.throwError(.type_error, "WeakRef: invalid target", .{});
    try self.object_slots.put(self.gc_allocator, @intFromPtr(o.object), .{ .weak_ref = target.retain() });
    return o.retain();
}

fn weakRefDeref(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const s = slotsOf(self, this_value, .weak_ref) orelse return incompatible(self, "WeakRef.prototype.deref");
    return s.weak_ref.retain();
}

// ===== FinalizationRegistry =====

fn finRegConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const o = try newInstance(self, ctx, this_value, "FinalizationRegistry");
    const cleanup = arg(args, 0);
    if (cleanup != .function) return self.throwError(.type_error, "FinalizationRegistry: cleanup must be callable", .{});
    try self.object_slots.put(self.gc_allocator, @intFromPtr(o.object), .{ .finalization_registry = .{ .cleanup = cleanup.retain(), .cells = .empty } });
    return o.retain();
}

fn finRegRegister(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const s = slotsOf(self, this_value, .finalization_registry) orelse return incompatible(self, "FinalizationRegistry.prototype.register");
    const target = arg(args, 0);
    const held = arg(args, 1);
    const token = arg(args, 2);
    if (!canBeHeldWeakly(self, target)) return self.throwError(.type_error, "FinalizationRegistry.prototype.register: invalid target", .{});
    if (regex_builtins.sameValue(target, held)) return self.throwError(.type_error, "FinalizationRegistry.prototype.register: target and holdings must not be same", .{});
    if (token != .undefined and !canBeHeldWeakly(self, token)) return self.throwError(.type_error, "FinalizationRegistry.prototype.register: invalid unregister token", .{});
    try s.finalization_registry.cells.append(self.gc_allocator, .{ .target = target.retain(), .held = held.retain(), .token = token.retain() });
    return JSValue.UNDEFINED;
}

fn finRegUnregister(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const s = slotsOf(self, this_value, .finalization_registry) orelse return incompatible(self, "FinalizationRegistry.prototype.unregister");
    const token = arg(args, 0);
    if (!canBeHeldWeakly(self, token)) return self.throwError(.type_error, "FinalizationRegistry.prototype.unregister: invalid unregister token", .{});
    const cells = &s.finalization_registry.cells;
    var removed = false;
    var i: usize = 0;
    while (i < cells.items.len) {
        const c = cells.items[i];
        if (c.token != .undefined and regex_builtins.sameValue(c.token, token)) {
            c.target.deinit();
            c.held.deinit();
            c.token.deinit();
            _ = cells.orderedRemove(i);
            removed = true;
        } else i += 1;
    }
    return JSValue.fromBool(removed);
}

// ===== install =====

const method_attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };

/// A constructor global, its `.prototype` (chained to Object.prototype,
/// non-enumerable `constructor`, @@toStringTag) and its methods.
fn installClass(self: *Interpreter, comptime name: []const u8, comptime arity: usize, comptime call: NativeFn, methods: anytype, tag_key: []const u8) !void {
    const ctor = try installBuiltin(self, .{ .name = name, .ctor = .{ .arity = arity, .call = call, .constructable = true } });
    const proto = try self.functionPrototype(ctor);
    try proto.object.value.defineProperty("constructor", ctor.retain(), method_attrs);
    inline for (methods) |m| {
        try proto.object.value.defineProperty(m[0], try native(self, m[0], m[1], m[2]), method_attrs);
    }
    try proto.object.value.defineProperty(tag_key, try self.gcNewString(name), .{ .writable = false, .enumerable = false, .configurable = true });
    // The constructor's `prototype` is non-writable, non-enumerable,
    // non-configurable; this engine keeps it on the Callable itself.
}

/// Installs the four globals. Runs at the end of materializeProtos.
pub fn install(self: *Interpreter) !void {
    const tag_key = try regex_builtins.wellKnownKey(self, "toStringTag");
    defer self.gc_allocator.free(tag_key);
    try installClass(self, "WeakMap", 0, weakCollectionConstructor(true), .{
        .{ "delete", 1, weakDelete(.weak_map, "WeakMap.prototype.delete") },
        .{ "get", 1, weakMapGet },
        .{ "has", 1, weakHas(.weak_map, "WeakMap.prototype.has") },
        .{ "set", 2, weakMapSet },
    }, tag_key);
    try installClass(self, "WeakSet", 0, weakCollectionConstructor(false), .{
        .{ "add", 1, weakSetAdd },
        .{ "delete", 1, weakDelete(.weak_set, "WeakSet.prototype.delete") },
        .{ "has", 1, weakHas(.weak_set, "WeakSet.prototype.has") },
    }, tag_key);
    try installClass(self, "WeakRef", 1, weakRefConstructor, .{
        .{ "deref", 0, weakRefDeref },
    }, tag_key);
    try installClass(self, "FinalizationRegistry", 1, finRegConstructor, .{
        .{ "register", 2, finRegRegister },
        .{ "unregister", 1, finRegUnregister },
    }, tag_key);
}
