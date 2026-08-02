//! `Map` and `Set` constructors + prototypes. Grouped together (not split
//! into two files) since they share `iteratorFromValues` and are installed
//! back-to-back. z-interpreter-refactor.md, Step 5 Phase A batch 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;
const requireTag = builtin_helpers.requireTag;
const requireCallback = builtin_helpers.requireCallback;
const makeArrayIterator = builtin_helpers.makeArrayIterator;

pub const map_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "get", MethodSpec{ .call = mapGet, .arity = 1 } },
    .{ "set", MethodSpec{ .call = mapSet, .arity = 2 } },
    .{ "has", MethodSpec{ .call = mapHas, .arity = 1 } },
    .{ "delete", MethodSpec{ .call = mapDelete, .arity = 1 } },
    .{ "clear", MethodSpec{ .call = mapClear, .arity = 0 } },
    .{ "forEach", MethodSpec{ .call = mapForEach, .arity = 1 } },
    .{ "keys", MethodSpec{ .call = mapKeys, .arity = 0 } },
    .{ "values", MethodSpec{ .call = mapValues, .arity = 0 } },
    .{ "entries", MethodSpec{ .call = mapEntries, .arity = 0 } },
});

pub const set_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "add", MethodSpec{ .call = setAdd, .arity = 1 } },
    .{ "has", MethodSpec{ .call = setHas, .arity = 1 } },
    .{ "delete", MethodSpec{ .call = setDelete, .arity = 1 } },
    .{ "clear", MethodSpec{ .call = setClear, .arity = 0 } },
    .{ "forEach", MethodSpec{ .call = setForEach, .arity = 1 } },
    .{ "keys", MethodSpec{ .call = setValues, .arity = 0 } },
    .{ "values", MethodSpec{ .call = setValues, .arity = 0 } },
    .{ "entries", MethodSpec{ .call = setEntries, .arity = 0 } },
});

fn requireMap(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    return requireTag(ctx, this_value, .map, "Method Map.prototype.{s} called on incompatible receiver", method);
}

fn requireSet(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    return requireTag(ctx, this_value, .set, "Method Set.prototype.{s} called on incompatible receiver", method);
}

fn mapConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Map requires 'new'", .{});
    var m = try interp(ctx).gcNewMap();
    const init = arg(args, 0);
    if (init != .undefined and init != .null) {
        const items = try self.iterableItems(init);
        defer self.gc_allocator.free(items);
        for (items) |entry| {
            if (entry != .array and entry != .object) return self.throwError(.type_error, "Iterator value {s} is not an entry object", .{entry.typeOf()});
            const k = try self.getProperty(entry, "0");
            const v = try self.getProperty(entry, "1");
            try m.map.value.set(k.retain(), v.retain());
        }
    }
    return m;
}

fn setConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Set requires 'new'", .{});
    var s = try interp(ctx).gcNewSet();
    const init = arg(args, 0);
    if (init != .undefined and init != .null) {
        const items = try self.iterableItems(init);
        defer self.gc_allocator.free(items);
        for (items) |v| try s.set.value.add(v.retain());
    }
    return s;
}

fn mapGet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "get");
    return if (m.map.value.get(arg(args, 0))) |v| v.retain() else JSValue.UNDEFINED;
}

fn mapSet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "set");
    const key = arg(args, 0);
    const value = arg(args, 1);
    // std.array_hash_map's put() only replaces the VALUE on an existing
    // key (getOrPutContext leaves key_ptr alone) -- so retaining the key
    // argument when the key already exists would retain something that
    // never gets stored, a pure leak. Capture+release the displaced value
    // the same way (set() silently overwrites it otherwise).
    const existed = m.map.value.has(key);
    const old_value = if (existed) m.map.value.get(key) else null;
    try m.map.value.set(if (existed) key else key.retain(), value.retain());
    if (old_value) |v| v.deinit();
    return m.retain(); // chainable
}

fn mapHas(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "has");
    return JSValue.fromBool(m.map.value.has(arg(args, 0)));
}

fn mapDelete(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "delete");
    const key = arg(args, 0);
    // delete() only returns a bool (no removed key/value) -- capture the
    // value first so we can release it. The stored KEY isn't released here
    // (deliberately out of scope): for object/symbol/function keys
    // SameValueZero is reference identity so `key` IS the stored box, but
    // for strings it's value equality over possibly-different boxes, and
    // ZMap doesn't expose "the actual stored key" to disambiguate safely.
    const old_value = m.map.value.get(key);
    const removed = m.map.value.delete(key);
    if (removed) if (old_value) |v| v.deinit();
    return JSValue.fromBool(removed);
}

fn mapClear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const m = try requireMap(ctx, this_value, "clear");
    m.map.value.clear();
    return JSValue.UNDEFINED;
}

fn mapForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const m = try requireMap(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    const ks = m.map.value.keys();
    const vs = m.map.value.values();
    // Snapshot + retain before calling into JS: `ks`/`vs` are live slices
    // into the map's storage, and the callback may mutate `m` (delete/
    // set), which can resize/compact that storage and invalidate them
    // mid-iteration -- a real, confirmed crash ("switch on corrupt
    // value" in JSValue.retain(), Test262). A copy WITHOUT retaining
    // isn't enough either: a callback that deletes the very entry being
    // visited would leave the snapshot pointing at an already-freed box.
    const snap_keys = try allocator.alloc(JSValue, ks.len);
    defer allocator.free(snap_keys);
    const snap_values = try allocator.alloc(JSValue, ks.len);
    defer allocator.free(snap_values);
    for (ks, vs, 0..) |k, v, i| {
        snap_keys[i] = k.retain();
        snap_values[i] = v.retain();
    }
    defer for (snap_keys, snap_values) |k, v| {
        k.deinit();
        v.deinit();
    };
    for (snap_keys, snap_values) |k, v| {
        _ = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ v, k, m });
    }
    return JSValue.UNDEFINED;
}

/// Snapshot slice -> array iterator (reuses the array-iterator machinery).
fn iteratorFromValues(self: *Interpreter, allocator: Allocator, items: []const JSValue) anyerror!JSValue {
    var arr = try self.gcNewArray();
    for (items) |it| _ = try arr.array.value.push(it.retain());
    return makeArrayIterator(self, allocator, arr, .values);
}

fn mapKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const m = try requireMap(ctx, this_value, "keys");
    return iteratorFromValues(interp(ctx), allocator, m.map.value.keys());
}

fn mapValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const m = try requireMap(ctx, this_value, "values");
    return iteratorFromValues(interp(ctx), allocator, m.map.value.values());
}

fn mapEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const m = try requireMap(ctx, this_value, "entries");
    const ks = m.map.value.keys();
    const vs = m.map.value.values();
    var pairs: std.ArrayList(JSValue) = .empty;
    defer pairs.deinit(allocator);
    for (ks, vs) |k, v| {
        var pair = try interp(ctx).gcNewArray();
        _ = try pair.array.value.push(k.retain());
        _ = try pair.array.value.push(v.retain());
        try pairs.append(allocator, pair);
    }
    return iteratorFromValues(interp(ctx), allocator, pairs.items);
}

fn setAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const s = try requireSet(ctx, this_value, "add");
    if (!s.set.value.has(arg(args, 0))) try s.set.value.add(arg(args, 0).retain());
    return s.retain(); // chainable
}

fn setHas(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const s = try requireSet(ctx, this_value, "has");
    return JSValue.fromBool(s.set.value.has(arg(args, 0)));
}

fn setDelete(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const s = try requireSet(ctx, this_value, "delete");
    return JSValue.fromBool(s.set.value.delete(arg(args, 0)));
}

fn setClear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const s = try requireSet(ctx, this_value, "clear");
    s.set.value.clear();
    return JSValue.UNDEFINED;
}

fn setForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const s = try requireSet(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    const vs = s.set.value.values();
    // Same snapshot-and-retain rationale as mapForEach above.
    const snap_values = try allocator.alloc(JSValue, vs.len);
    defer allocator.free(snap_values);
    for (vs, 0..) |v, i| snap_values[i] = v.retain();
    defer for (snap_values) |v| v.deinit();
    for (snap_values) |v| {
        _ = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ v, v, s });
    }
    return JSValue.UNDEFINED;
}

fn setValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const s = try requireSet(ctx, this_value, "values");
    return iteratorFromValues(interp(ctx), allocator, s.set.value.values());
}

fn setEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const s = try requireSet(ctx, this_value, "entries");
    var pairs: std.ArrayList(JSValue) = .empty;
    defer pairs.deinit(allocator);
    for (s.set.value.values()) |v| {
        var pair = try interp(ctx).gcNewArray();
        _ = try pair.array.value.push(v.retain());
        _ = try pair.array.value.push(v.retain());
        try pairs.append(allocator, pair);
    }
    return iteratorFromValues(interp(ctx), allocator, pairs.items);
}

/// Installs the `Map` and `Set` constructors (no statics on either).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "Map", .ctor = .{ .call = mapConstructor, .constructable = true } });
    _ = try installBuiltin(self, .{ .name = "Set", .ctor = .{ .call = setConstructor, .constructable = true } });
}
