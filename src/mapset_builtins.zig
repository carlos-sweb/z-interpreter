//! `Map` and `Set` constructors + prototypes. Grouped together (not split
//! into two files) since they share `iteratorFromValues` and are installed
//! back-to-back. z-interpreter-refactor.md, Step 5 Phase A batch 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
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
    .{ "getOrInsert", MethodSpec{ .call = mapGetOrInsert, .arity = 2 } },
    .{ "getOrInsertComputed", MethodSpec{ .call = mapGetOrInsertComputed, .arity = 2 } },
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
    .{ "union", MethodSpec{ .call = setUnion, .arity = 1 } },
    .{ "intersection", MethodSpec{ .call = setIntersection, .arity = 1 } },
    .{ "difference", MethodSpec{ .call = setDifference, .arity = 1 } },
    .{ "symmetricDifference", MethodSpec{ .call = setSymmetricDifference, .arity = 1 } },
    .{ "isSubsetOf", MethodSpec{ .call = setIsSubsetOf, .arity = 1 } },
    .{ "isSupersetOf", MethodSpec{ .call = setIsSupersetOf, .arity = 1 } },
    .{ "isDisjointFrom", MethodSpec{ .call = setIsDisjointFrom, .arity = 1 } },
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
    if (init.tag() != .undefined and init.tag() != .null) {
        const items = try self.iterableItems(init);
        defer self.gc_allocator.free(items);
        for (items) |entry| {
            if (entry.tag() != .array and entry.tag() != .object) return self.throwError(.type_error, "Iterator value {s} is not an entry object", .{entry.typeOf()});
            // getProperty hands back owned references: they move into
            // the map (mapSet consumes both, also on error).
            const k = try self.getProperty(entry, "0");
            const v = self.getProperty(entry, "1") catch |err| {
                k.deinit();
                return err;
            };
            try m.mapSet(k, v);
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
    if (init.tag() != .undefined and init.tag() != .null) {
        const items = try self.iterableItems(init);
        defer self.gc_allocator.free(items);
        // iterableItems' ownership is mixed (borrowed for array/set
        // sources, owned for string/iterator ones); this retain is right
        // for the borrowed case only. Pre-existing, left as is.
        for (items) |v| try s.setAdd(v.retain());
    }
    return s;
}

fn mapGet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "get");
    return if (m.asMap().value.get(arg(args, 0))) |v| v.retain() else JSValue.UNDEFINED;
}

fn mapSet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "set");
    // mapSet keeps the stored key on an existing entry and releases the
    // redundant one and the displaced value; on error it releases both.
    try m.mapSet(arg(args, 0).retain(), arg(args, 1).retain());
    return m.retain(); // chainable
}

fn mapHas(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "has");
    return JSValue.fromBool(m.asMap().value.has(arg(args, 0)));
}

fn mapDelete(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "delete");
    // Releases the STORED key (maybe a different, equal box than the
    // argument) and its value.
    return JSValue.fromBool(m.mapDelete(arg(args, 0)));
}

fn mapClear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const m = try requireMap(ctx, this_value, "clear");
    m.mapClear();
    return JSValue.UNDEFINED;
}

fn mapForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const m = try requireMap(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    const ks = m.asMap().value.keys();
    const vs = m.asMap().value.values();
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
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    for (snap_keys, snap_values) |k, v| {
        const res = try cb.asFunction().value.call(cb.asFunction().value.ctx, allocator, this_arg, &.{ v, k, m });
        res.deinit();
    }
    return JSValue.UNDEFINED;
}

fn canonicalizeKey(k: JSValue) JSValue {
    if (k.isNumber() and k.asNumber() == 0.0) return JSValue.fromNumber(0.0);
    return k;
}

fn mapGetOrInsert(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    var m = try requireMap(ctx, this_value, "getOrInsert");
    const key = canonicalizeKey(arg(args, 0));
    if (m.asMap().value.get(key)) |existing| {
        return existing.retain();
    }
    const val = arg(args, 1);
    try m.mapSet(key.retain(), val.retain());
    return val.retain();
}

fn mapGetOrInsertComputed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    var m = try requireMap(ctx, this_value, "getOrInsertComputed");
    const cb = arg(args, 1);
    if (!cb.isFunction()) {
        return interp(ctx).throwError(.type_error, "Map.prototype.getOrInsertComputed callback is not a function", .{});
    }
    const key = canonicalizeKey(arg(args, 0));
    if (m.asMap().value.get(key)) |existing| {
        return existing.retain();
    }
    const val = try cb.asFunction().value.call(cb.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{key});
    try m.mapSet(key.retain(), val.retain());
    return val;
}

/// Snapshot slice -> array iterator (reuses the array-iterator machinery).
fn iteratorFromValues(self: *Interpreter, allocator: Allocator, items: []const JSValue) anyerror!JSValue {
    var arr = try self.gcNewArray();
    for (items) |it| _ = try arr.asArray().value.push(it.retain());
    return makeArrayIterator(self, allocator, arr, .values);
}

fn mapKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const m = try requireMap(ctx, this_value, "keys");
    return iteratorFromValues(interp(ctx), allocator, m.asMap().value.keys());
}

fn mapValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const m = try requireMap(ctx, this_value, "values");
    return iteratorFromValues(interp(ctx), allocator, m.asMap().value.values());
}

fn mapEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const m = try requireMap(ctx, this_value, "entries");
    const ks = m.asMap().value.keys();
    const vs = m.asMap().value.values();
    var pairs: std.ArrayList(JSValue) = .empty;
    defer pairs.deinit(allocator);
    for (ks, vs) |k, v| {
        var pair = try interp(ctx).gcNewArray();
        _ = try pair.asArray().value.push(k.retain());
        _ = try pair.asArray().value.push(v.retain());
        try pairs.append(allocator, pair);
    }
    return iteratorFromValues(interp(ctx), allocator, pairs.items);
}

const SetRecord = struct {
    obj: JSValue,
    size: f64,
    has_fn: JSValue,
    keys_fn: JSValue,

    fn deinit(self: SetRecord) void {
        self.has_fn.deinit();
        self.keys_fn.deinit();
    }
};

fn getSetRecord(self: *Interpreter, obj: JSValue) anyerror!SetRecord {
    if (!builtin_helpers.isObjectLike(obj)) {
        return self.throwError(.type_error, "Set operation argument must be an object", .{});
    }
    const raw_size = try self.getProperty(obj, "size");
    defer raw_size.deinit();
    const num_size = try self.toNumberJS(raw_size);
    if (std.math.isNan(num_size)) {
        return self.throwError(.type_error, "Set-like size is NaN", .{});
    }
    const int_size = @trunc(num_size);
    if (int_size < 0) {
        return self.throwError(.range_error, "Set-like size must be non-negative", .{});
    }
    const has_fn = try self.getProperty(obj, "has");
    errdefer has_fn.deinit();
    if (!has_fn.isFunction()) {
        return self.throwError(.type_error, "Set-like .has is not a function", .{});
    }
    const keys_fn = try self.getProperty(obj, "keys");
    errdefer keys_fn.deinit();
    if (!keys_fn.isFunction()) {
        return self.throwError(.type_error, "Set-like .keys is not a function", .{});
    }
    return .{
        .obj = obj,
        .size = int_size,
        .has_fn = has_fn,
        .keys_fn = keys_fn,
    };
}

const KeysIterator = struct {
    iter: JSValue,
    next_fn: JSValue,

    fn deinit(self: KeysIterator) void {
        self.iter.deinit();
        self.next_fn.deinit();
    }
};

fn getKeysIterator(self: *Interpreter, allocator: Allocator, rec: SetRecord) anyerror!KeysIterator {
    const iter = try rec.keys_fn.asFunction().value.call(rec.keys_fn.asFunction().value.ctx, allocator, rec.obj, &.{});
    errdefer iter.deinit();
    if (!builtin_helpers.isObjectLike(iter)) {
        return self.throwError(.type_error, "Set-like .keys() did not return an object", .{});
    }
    const next_fn = try self.getProperty(iter, "next");
    errdefer next_fn.deinit();
    if (!next_fn.isFunction()) {
        return self.throwError(.type_error, "Set-like iterator .next is not a function", .{});
    }
    return .{ .iter = iter, .next_fn = next_fn };
}

fn stepKeysIterator(self: *Interpreter, allocator: Allocator, it: KeysIterator) anyerror!?JSValue {
    const step = try it.next_fn.asFunction().value.call(it.next_fn.asFunction().value.ctx, allocator, it.iter, &.{});
    defer step.deinit();
    if (!builtin_helpers.isObjectLike(step)) {
        return self.throwError(.type_error, "Iterator result is not an object", .{});
    }
    const done_val = try self.getProperty(step, "done");
    const done = coercion.isTruthy(done_val);
    done_val.deinit();
    if (done) return null;
    const val = try self.getProperty(step, "value");
    return canonicalizeKey(val);
}

fn callSetRecordHas(allocator: Allocator, rec: SetRecord, val: JSValue) anyerror!bool {
    const res = try rec.has_fn.asFunction().value.call(rec.has_fn.asFunction().value.ctx, allocator, rec.obj, &.{val});
    defer res.deinit();
    return coercion.isTruthy(res);
}

fn setUnion(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const s = try requireSet(ctx, this_value, "union");
    const other_rec = try getSetRecord(self, arg(args, 0));
    defer other_rec.deinit();
    const it = try getKeysIterator(self, allocator, other_rec);
    defer it.deinit();

    var result = try self.gcNewSet();
    errdefer result.deinit();
    for (s.asSet().value.values()) |v| {
        try result.setAdd(canonicalizeKey(v).retain());
    }
    while (try stepKeysIterator(self, allocator, it)) |next_val| {
        try result.setAdd(next_val);
    }
    return result;
}

fn setIntersection(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const s = try requireSet(ctx, this_value, "intersection");
    const other_rec = try getSetRecord(self, arg(args, 0));
    defer other_rec.deinit();

    var result = try self.gcNewSet();
    errdefer result.deinit();

    if (@as(f64, @floatFromInt(s.asSet().value.values().len)) <= other_rec.size) {
        var i: usize = 0;
        while (i < s.asSet().value.values().len) : (i += 1) {
            const e = canonicalizeKey(s.asSet().value.values()[i]).retain();
            defer e.deinit();
            if (try callSetRecordHas(allocator, other_rec, e)) {
                try result.setAdd(e.retain());
            }
        }
    } else {
        const it = try getKeysIterator(self, allocator, other_rec);
        defer it.deinit();
        while (try stepKeysIterator(self, allocator, it)) |next_val| {
            defer next_val.deinit();
            if (s.asSet().value.has(next_val)) {
                try result.setAdd(next_val.retain());
            }
        }
    }
    return result;
}

fn setDifference(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const s = try requireSet(ctx, this_value, "difference");
    const other_rec = try getSetRecord(self, arg(args, 0));
    defer other_rec.deinit();

    var result = try self.gcNewSet();
    errdefer result.deinit();
    for (s.asSet().value.values()) |v| {
        try result.setAdd(canonicalizeKey(v).retain());
    }

    if (@as(f64, @floatFromInt(s.asSet().value.values().len)) <= other_rec.size) {
        const vs = result.asSet().value.values();
        const snap = try allocator.alloc(JSValue, vs.len);
        defer allocator.free(snap);
        for (vs, 0..) |v, i| snap[i] = v.retain();
        defer for (snap) |v| v.deinit();
        for (snap) |e| {
            if (try callSetRecordHas(allocator, other_rec, e)) {
                _ = result.setDelete(e);
            }
        }
    } else {
        const it = try getKeysIterator(self, allocator, other_rec);
        defer it.deinit();
        while (try stepKeysIterator(self, allocator, it)) |next_val| {
            defer next_val.deinit();
            if (result.asSet().value.has(next_val)) {
                _ = result.setDelete(next_val);
            }
        }
    }
    return result;
}

fn setSymmetricDifference(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const s = try requireSet(ctx, this_value, "symmetricDifference");
    const other_rec = try getSetRecord(self, arg(args, 0));
    defer other_rec.deinit();
    const it = try getKeysIterator(self, allocator, other_rec);
    defer it.deinit();

    var result = try self.gcNewSet();
    errdefer result.deinit();
    for (s.asSet().value.values()) |v| {
        try result.setAdd(canonicalizeKey(v).retain());
    }

    while (try stepKeysIterator(self, allocator, it)) |next_val| {
        const in_this = s.asSet().value.has(next_val);
        if (result.asSet().value.has(next_val)) {
            if (in_this) {
                _ = result.setDelete(next_val);
            }
            next_val.deinit();
        } else {
            if (!in_this) {
                try result.setAdd(next_val);
            } else {
                next_val.deinit();
            }
        }
    }
    return result;
}

fn setIsSubsetOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const s = try requireSet(ctx, this_value, "isSubsetOf");
    const other_rec = try getSetRecord(self, arg(args, 0));
    defer other_rec.deinit();

    if (@as(f64, @floatFromInt(s.asSet().value.values().len)) > other_rec.size) {
        return JSValue.fromBool(false);
    }
    var i: usize = 0;
    while (i < s.asSet().value.values().len) : (i += 1) {
        const e = canonicalizeKey(s.asSet().value.values()[i]).retain();
        defer e.deinit();
        if (!(try callSetRecordHas(allocator, other_rec, e))) {
            return JSValue.fromBool(false);
        }
    }
    return JSValue.fromBool(true);
}

fn setIsSupersetOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const s = try requireSet(ctx, this_value, "isSupersetOf");
    const other_rec = try getSetRecord(self, arg(args, 0));
    defer other_rec.deinit();

    if (@as(f64, @floatFromInt(s.asSet().value.values().len)) < other_rec.size) {
        return JSValue.fromBool(false);
    }
    const it = try getKeysIterator(self, allocator, other_rec);
    defer it.deinit();
    while (try stepKeysIterator(self, allocator, it)) |next_val| {
        defer next_val.deinit();
        if (!s.asSet().value.has(next_val)) {
            try self.closeIterator(it.iter);
            return JSValue.fromBool(false);
        }
    }
    return JSValue.fromBool(true);
}

fn setIsDisjointFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const s = try requireSet(ctx, this_value, "isDisjointFrom");
    const other_rec = try getSetRecord(self, arg(args, 0));
    defer other_rec.deinit();

    if (@as(f64, @floatFromInt(s.asSet().value.values().len)) <= other_rec.size) {
        var i: usize = 0;
        while (i < s.asSet().value.values().len) : (i += 1) {
            const e = canonicalizeKey(s.asSet().value.values()[i]).retain();
            defer e.deinit();
            if (try callSetRecordHas(allocator, other_rec, e)) {
                return JSValue.fromBool(false);
            }
        }
    } else {
        const it = try getKeysIterator(self, allocator, other_rec);
        defer it.deinit();
        while (try stepKeysIterator(self, allocator, it)) |next_val| {
            defer next_val.deinit();
            if (s.asSet().value.has(next_val)) {
                try self.closeIterator(it.iter);
                return JSValue.fromBool(false);
            }
        }
    }
    return JSValue.fromBool(true);
}

fn setAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const s = try requireSet(ctx, this_value, "add");
    // setAdd releases the reference if the value is already present.
    try s.setAdd(arg(args, 0).retain());
    return s.retain(); // chainable
}

fn setHas(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const s = try requireSet(ctx, this_value, "has");
    return JSValue.fromBool(s.asSet().value.has(arg(args, 0)));
}

fn setDelete(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const s = try requireSet(ctx, this_value, "delete");
    // Set.delete/clear no liberan porque iterableItems devuelve elementos
    // prestados. Migrar (a setDelete/setClear) cuando iterableItems
    // devuelva referencias propias: hoy liberar aquí deja colgando la
    // lista de un llamador que ejecuta JS mientras la recorre
    // (Array.from(set, fn), yield* set).
    return JSValue.fromBool(s.asSet().value.delete(arg(args, 0)));
}

fn setClear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const s = try requireSet(ctx, this_value, "clear");
    // Set.delete/clear no liberan porque iterableItems devuelve elementos
    // prestados. Migrar (a setDelete/setClear) cuando iterableItems
    // devuelva referencias propias: hoy liberar aquí deja colgando la
    // lista de un llamador que ejecuta JS mientras la recorre
    // (Array.from(set, fn), yield* set).
    s.asSet().value.clear();
    return JSValue.UNDEFINED;
}

fn setForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const s = try requireSet(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    const vs = s.asSet().value.values();
    // Same snapshot-and-retain rationale as mapForEach above.
    const snap_values = try allocator.alloc(JSValue, vs.len);
    defer allocator.free(snap_values);
    for (vs, 0..) |v, i| snap_values[i] = v.retain();
    defer for (snap_values) |v| v.deinit();
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    for (snap_values) |v| {
        const res = try cb.asFunction().value.call(cb.asFunction().value.ctx, allocator, this_arg, &.{ v, v, s });
        res.deinit();
    }
    return JSValue.UNDEFINED;
}

fn setValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const s = try requireSet(ctx, this_value, "values");
    return iteratorFromValues(interp(ctx), allocator, s.asSet().value.values());
}

fn setEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const s = try requireSet(ctx, this_value, "entries");
    var pairs: std.ArrayList(JSValue) = .empty;
    defer pairs.deinit(allocator);
    for (s.asSet().value.values()) |v| {
        var pair = try interp(ctx).gcNewArray();
        _ = try pair.asArray().value.push(v.retain());
        _ = try pair.asArray().value.push(v.retain());
        try pairs.append(allocator, pair);
    }
    return iteratorFromValues(interp(ctx), allocator, pairs.items);
}

/// Installs the `Map` and `Set` constructors (no statics on either).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "Map", .ctor = .{ .call = mapConstructor, .constructable = true } });
    _ = try installBuiltin(self, .{ .name = "Set", .ctor = .{ .call = setConstructor, .constructable = true } });
}
