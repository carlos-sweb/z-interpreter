//! `Object` statics (keys/values/entries/assign/defineProperty/
//! defineProperties/getOwnPropertyDescriptor/getOwnPropertyNames/
//! getOwnPropertySymbols/create/freeze/seal/preventExtensions/is/hasOwn/
//! fromEntries/setPrototypeOf/getPrototypeOf), `Object.prototype`
//! methods (hasOwnProperty/propertyIsEnumerable/toString/valueOf/
//! isPrototypeOf), and the `Object` constructor. Object bootstraps
//! FIRST in setupGlobals (its constructor + real `Object.prototype`
//! must exist before any other builtin can chain to it via
//! `self.ordinaryObject()`) -- `install` replicates that exact
//! ordering constraint, called first by builtins.zig instead of
//! inlined there.
//!
//! `definePropertyOn`/`objectGetOwnPropertyDescriptor`/
//! `objectGetOwnPropertyNames`/`objectGetPrototypeOf` are `pub` here:
//! Reflect (still in builtins.zig, not yet its own domain) reaches them
//! via `builtins.object_builtins.X` aliases -- same reach-back pattern
//! used since batch 3's `globalParseInt`/`globalParseFloat`.
//! `ownEnumerableKeys`/`freeOwnedKeys` stay `pub` (interpreter.zig
//! reaches them directly as `builtins.ownEnumerableKeys` for
//! for-in/spread/destructuring key enumeration).
//! z-interpreter-refactor.md, Step 5 Phase A batch 7.

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
const isSymbolKey = builtin_helpers.isSymbolKey;
const dneMethod = builtin_helpers.dneMethod;

pub const object_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "hasOwnProperty", MethodSpec{ .call = objHasOwnProperty, .arity = 1 } },
    .{ "propertyIsEnumerable", MethodSpec{ .call = objPropertyIsEnumerable, .arity = 1 } },
    .{ "toString", MethodSpec{ .call = objToString, .arity = 0 } },
    .{ "valueOf", MethodSpec{ .call = objValueOf, .arity = 0 } },
    .{ "isPrototypeOf", MethodSpec{ .call = objIsPrototypeOf, .arity = 1 } },
});

// ===== Object statics =====

fn requireObject(ctx: *anyopaque, v: JSValue, what: []const u8) anyerror!JSValue {
    if (v != .object) return interp(ctx).throwError(.type_error, "{s} called on a non-object", .{what});
    return v;
}

/// Own enumerable string keys of any value, for Object.keys/values/entries.
/// Functions expose the enumerable entries of their statics bag (builtin
/// statics are non-enumerable, so `Object.keys(Date)` is empty); null/
/// undefined throw; other primitives yield nothing (narrowed -- real JS
/// coerces strings to index keys). Every returned key is a fresh,
/// caller-owned copy (unlike `ZObject.keys()`'s own borrowed-pointer
/// contract) -- required for the `.proxy` case, whose keys come from a
/// trap-returned array that gets torn down before this function
/// returns, so nothing else could safely borrow from it. The other arms
/// dupe too even though they technically could borrow, purely so every
/// caller can free the same uniform way (see `freeOwnedKeys`) instead of
/// needing to special-case one variant.
pub fn ownEnumerableKeys(ctx: *anyopaque, allocator: Allocator, v: JSValue) anyerror![][]const u8 {
    const borrowed: [][]const u8 = switch (v) {
        .object => |box| try box.value.keys(allocator),
        .function => |box| if (box.value.statics) |bag| try bag.object.value.keys(allocator) else try allocator.alloc([]const u8, 0),
        .undefined, .null => return interp(ctx).throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        // ownKeys(target) -- narrowed: every trap-returned key is treated
        // as enumerable (real spec would filter via a
        // getOwnPropertyDescriptor call per key), matching this
        // engine's already-established "no invariant checking" scope
        // boundary for Proxy.
        .proxy => |box| {
            if (try interp(ctx).proxyTrap(box, "ownKeys")) |trap_fn| {
                defer trap_fn.deinit();
                const trap_result = try trap_fn.function.value.call(trap_fn.function.value.ctx, allocator, box.value.handler, &.{box.value.target});
                defer trap_result.deinit();
                if (trap_result != .array) return &.{};
                var keys: std.ArrayList([]const u8) = .empty;
                defer keys.deinit(allocator);
                for (trap_result.array.value.toSlice()) |item| {
                    if (item == .string) try keys.append(allocator, try allocator.dupe(u8, item.string.value.data));
                }
                return keys.toOwnedSlice(allocator);
            }
            return ownEnumerableKeys(ctx, allocator, box.value.target);
        },
        else => try allocator.alloc([]const u8, 0),
    };
    defer allocator.free(borrowed);
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |k| allocator.free(k);
        owned.deinit(allocator);
    }
    for (borrowed) |k| try owned.append(allocator, try allocator.dupe(u8, k));
    return owned.toOwnedSlice(allocator);
}

/// Pairs with `ownEnumerableKeys`' now-uniform "every key is a fresh,
/// owned copy" contract -- frees each string, then the container.
pub fn freeOwnedKeys(allocator: Allocator, ks: [][]const u8) void {
    for (ks) |k| allocator.free(k);
    allocator.free(ks);
}

fn objectKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = arg(args, 0);
    const ks = try ownEnumerableKeys(ctx, allocator, o);
    defer freeOwnedKeys(allocator, ks);
    var result = try interp(ctx).gcNewArray();
    for (ks) |k| {
        if (isSymbolKey(k)) continue;
        _ = try result.array.value.push(try interp(ctx).gcNewString(k));
    }
    return result;
}

fn objectValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = arg(args, 0);
    const ks = try ownEnumerableKeys(ctx, allocator, o);
    defer freeOwnedKeys(allocator, ks);
    var result = try interp(ctx).gcNewArray();
    // Per-key getProperty (not ZObject.values) so accessor properties
    // invoke their getters, like real Object.values.
    for (ks) |k| {
        if (isSymbolKey(k)) continue;
        _ = try result.array.value.push(try interp(ctx).getProperty(o, k));
    }
    return result;
}

fn objectEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = arg(args, 0);
    const ks = try ownEnumerableKeys(ctx, allocator, o);
    defer freeOwnedKeys(allocator, ks);
    var result = try interp(ctx).gcNewArray();
    for (ks) |k| {
        if (isSymbolKey(k)) continue;
        var pair = try interp(ctx).gcNewArray();
        _ = try pair.array.value.push(try interp(ctx).gcNewString(k));
        // getProperty, not ZObject.get -- getters must fire here too.
        _ = try pair.array.value.push(try interp(ctx).getProperty(o, k));
        _ = try result.array.value.push(pair);
    }
    return result;
}

fn objectAssign(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const target = try requireObject(ctx, arg(args, 0), "Object.assign");
    for (args[1..]) |source| {
        if (source != .object) continue; // primitives are skipped, like real JS
        const ks = try source.object.value.keys(allocator);
        defer allocator.free(ks);
        for (ks) |k| {
            try target.object.value.set(k, source.object.value.get(k).?.retain());
        }
    }
    return target.retain();
}

// ===== Object.prototype methods (object_methods table) =====

fn requirePlainObject(ctx: *anyopaque, v: JSValue, what: []const u8) anyerror!JSValue {
    if (v != .object) return interp(ctx).throwError(.type_error, "{s} called on non-object", .{what});
    return v;
}

/// Real spec: `Proxy` is the one constructable builtin with NO own
/// `"prototype"` property (proxy exotic objects have no [[Prototype]]
/// slot needing initialization) -- every other constructor's own
/// `constructable` flag is the right signal, but this one needs an
/// identity carve-out (same shape as `.@"error"`'s "constructor"
/// identity check in getProperty).
fn isProxyConstructor(self: *Interpreter, v: JSValue) bool {
    const proxy_ctor = self.global_env.get("Proxy") orelse return false;
    return zvalue.equality.strictEquals(v, proxy_ctor);
}

fn objHasOwnProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const key = try interp(ctx).encodeKey(arg(args, 0));
    defer allocator.free(key);
    return switch (this_value) {
        // `globalThis`: builtins (global_env) and top-level var/function
        // declarations (global_var_names -- NOT script-level let/const,
        // which real spec never reifies as globalThis own properties;
        // confirmed against real Node) aren't backed by a real ZObject
        // record on this object, so a bare hasOwnProperty would miss
        // them all -- same gap as getProperty's globalThis branch above.
        .object => |box| blk: {
            if (interp(ctx).global_object) |go| {
                if (this_value.object == go.object) {
                    const self = interp(ctx);
                    break :blk JSValue.fromBool(self.global_var_names.contains(key) or self.global_env.declaresLocally(key) or box.value.hasOwnProperty(key));
                }
            }
            break :blk JSValue.fromBool(box.value.hasOwnProperty(key));
        },
        // Functions expose name/length/prototype as own properties (mirrors
        // objectGetOwnPropertyDescriptor's own-property set for `.function`
        // below) plus whatever's on their statics bag.
        .function => |box| blk: {
            const deleted = interp(ctx).deletedFnProps(this_value);
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(!deleted.length);
            if (std.mem.eql(u8, key, "name")) break :blk JSValue.fromBool(!deleted.name);
            if (std.mem.eql(u8, key, "prototype")) break :blk JSValue.fromBool(!isProxyConstructor(interp(ctx), this_value) and (box.value.prototype != null or box.value.constructable));
            break :blk JSValue.fromBool(if (box.value.statics) |bag| bag.object.value.hasOwnProperty(key) else false);
        },
        // Arrays expose `length` and every in-bounds index as an own property
        // (they have no general ZObject bag, so answer these directly).
        .array => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(true);
            const idx = std.fmt.parseInt(usize, key, 10) catch break :blk JSValue.fromBool(interp(ctx).arrayExtra(this_value, key) != null);
            break :blk JSValue.fromBool(idx < box.value.length());
        },
        // Strings: `length` and in-bounds character indices are own props.
        .string => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(true);
            const idx = std.fmt.parseInt(usize, key, 10) catch break :blk JSValue.fromBool(false);
            break :blk JSValue.fromBool(idx < box.value.data.len);
        },
        else => JSValue.fromBool(false),
    };
}

fn objPropertyIsEnumerable(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    if (this_value != .object) return JSValue.fromBool(false);
    const key = try interp(ctx).encodeKey(arg(args, 0));
    defer allocator.free(key);
    return JSValue.fromBool(this_value.object.value.propertyIsEnumerable(key));
}

/// ECMA-262 20.1.3.6 Object.prototype.toString's built-in tag table --
/// NOT the full algorithm (that also consults an own/inherited
/// `@@toStringTag` string property for anything not on this hardcoded
/// list, e.g. Map/Set/Promise/Math -- unimplemented here, narrowing:
/// those stay "Object" until @@toStringTag exists on their
/// prototypes/namespace objects too). `new Number(x)`/`new String(x)`/
/// `new Boolean(x)` wrapper objects are `.object` with no internal-slot
/// concept of their own (see `unboxPrimitiveWrapper`'s doc comment),
/// so their tag comes from the boxed primitive's own JSValue tag.
fn objToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const tag: []const u8 = switch (this_value) {
        .undefined => "Undefined",
        .null => "Null",
        .array => "Array",
        .function => "Function",
        .@"error" => "Error",
        .date => "Date",
        .regex => "RegExp",
        // Real spec gets these via the generic `@@toStringTag` fallback
        // (Map.prototype/Set.prototype's own property, now installed --
        // see materializeProtos), not the hardcoded internal-slot list
        // Array/Function/Error/Date/RegExp above -- narrowed to a
        // hardcoded case here too rather than a real property lookup,
        // so overriding `Map.prototype[Symbol.toStringTag]` wouldn't
        // change this specific result (confirmed against real Node
        // this matches for the untouched-prototype case, which is the
        // only one that mattered for what was actually failing).
        .map => "Map",
        .set => "Set",
        .object => blk: {
            if (self.unboxPrimitiveWrapper(this_value)) |prim| {
                break :blk switch (prim) {
                    .number => "Number",
                    .string => "String",
                    .boolean => "Boolean",
                    else => "Object",
                };
            }
            break :blk "Object";
        },
        else => "Object",
    };
    const msg = try std.fmt.allocPrint(self.gc_allocator, "[object {s}]", .{tag});
    defer self.gc_allocator.free(msg);
    return self.gcNewString(msg);
}

fn objValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = args;
    return this_value.retain();
}

fn objIsPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    if (this_value != .object or arg(args, 0) != .object) return JSValue.fromBool(false);
    return JSValue.fromBool(this_value.object.value.isPrototypeOf(&arg(args, 0).object.value));
}

// ===== Object statics: constructor + descriptors =====

fn objectConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    return switch (v) {
        // Object(x) on object-likes returns x; on nothing, a fresh {}.
        .object, .array, .function, .@"error", .date, .promise, .map, .set, .regex, .temporal => v.retain(),
        // Real ToObject on a primitive: a boxed wrapper chaining to
        // that primitive's OWN prototype (Number.prototype/etc, not
        // Object.prototype), carrying the primitive so
        // requirePrimitive-gated methods (`.valueOf()`,
        // `Number.prototype.toFixed`, ...) unwrap it correctly --
        // previously this fell to the `else` branch below and just
        // silently produced an empty `{}`, losing the primitive
        // entirely (confirmed against real Node: `Object(5).valueOf()
        // === 5`, this returned `{}` instead).
        .number => try boxWrapper(self, self.protos.number, v),
        .string => try boxWrapper(self, self.protos.string, v),
        .boolean => try boxWrapper(self, self.protos.boolean, v),
        .symbol => try boxWrapper(self, self.protos.symbol, v),
        .bigint => try boxWrapper(self, self.protos.bigint, v),
        else => try self.ordinaryObject(),
    };
}

/// `Object(primitive)`'s wrapper: a fresh object chaining to `proto`
/// (the primitive's OWN prototype), registered in
/// primitive_wrapper_data so it unboxes exactly like `new Number(x)`/
/// etc (see `unboxPrimitiveWrapper`'s doc comment -- same side table,
/// same contract, just populated from a different call site).
fn boxWrapper(self: *Interpreter, proto: JSValue, primitive: JSValue) anyerror!JSValue {
    const obj = try self.gcNewObject();
    try obj.object.value.setPrototype(&proto.object.value);
    try self.primitive_wrapper_data.put(self.gc_allocator, @intFromPtr(obj.object), primitive.retain());
    return obj;
}

/// Shared by defineProperty/defineProperties/create: applies ONE
/// JS-shaped descriptor to obj[key], with the spec's partial-descriptor
/// merge on existing configurable properties. Defining bypasses
/// `writable` (that's assignment's rule, not definition's).
fn definePropertyFromJs(self: *Interpreter, obj: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    const arena = self.gc_allocator;
    if (desc != .object) {
        return self.throwError(.type_error, "Property description must be an object", .{});
    }
    const d = &desc.object.value;

    const has_get = d.hasOwnProperty("get");
    const has_set = d.hasOwnProperty("set");
    const has_value = d.hasOwnProperty("value");
    const has_writable = d.hasOwnProperty("writable");
    if ((has_get or has_set) and (has_value or has_writable)) {
        return self.throwError(.type_error, "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute", .{});
    }

    const existing = obj.object.value.getOwnRecordMut(key);
    if (existing) |rec| {
        if (!rec.descriptor.configurable) {
            // Narrowed: any redefinition attempt on a non-configurable
            // property throws (the real spec allows some same-value and
            // writable:true->value cases).
            return self.throwError(.type_error, "Cannot redefine property: {s}", .{key});
        }
    }

    if (has_get or has_set) {
        const getter = if (has_get) blk: {
            const g = d.get("get").?;
            break :blk if (g == .function) g.retain() else null;
        } else null;
        const setter = if (has_set) blk: {
            const s = d.get("set").?;
            break :blk if (s == .function) s.retain() else null;
        } else null;
        try obj.object.value.defineAccessor(key, getter, setter, JSValue.UNDEFINED);
        const rec = obj.object.value.getOwnRecordMut(key).?;
        if (existing == null) {
            // New accessor property: flag defaults are FALSE per spec.
            rec.descriptor.enumerable = false;
            rec.descriptor.configurable = false;
        }
        if (d.hasOwnProperty("enumerable")) rec.descriptor.enumerable = coercion.isTruthy(d.get("enumerable").?);
        if (d.hasOwnProperty("configurable")) rec.descriptor.configurable = coercion.isTruthy(d.get("configurable").?);
        return;
    }

    if (existing) |rec| {
        // Partial merge onto an existing (configurable) property.
        if (has_value) {
            rec.value = d.get("value").?.retain();
            rec.getter = null;
            rec.setter = null;
        }
        if (has_writable) rec.descriptor.writable = coercion.isTruthy(d.get("writable").?);
        if (d.hasOwnProperty("enumerable")) rec.descriptor.enumerable = coercion.isTruthy(d.get("enumerable").?);
        if (d.hasOwnProperty("configurable")) rec.descriptor.configurable = coercion.isTruthy(d.get("configurable").?);
        return;
    }

    // New data property: absent fields default to false/undefined.
    const value = if (has_value) d.get("value").?.retain() else JSValue.UNDEFINED;
    const descriptor = zvalue.PropertyDescriptor{
        .writable = if (has_writable) coercion.isTruthy(d.get("writable").?) else false,
        .enumerable = if (d.hasOwnProperty("enumerable")) coercion.isTruthy(d.get("enumerable").?) else false,
        .configurable = if (d.hasOwnProperty("configurable")) coercion.isTruthy(d.get("configurable").?) else false,
    };
    obj.object.value.defineProperty(key, value, descriptor) catch |err| return switch (err) {
        error.ObjectNotExtensible => self.throwError(.type_error, "Cannot define property {s}, object is not extensible", .{key}),
        error.PropertyNotConfigurable => self.throwError(.type_error, "Cannot redefine property: {s}", .{key}),
        else => err,
    };
    _ = arena;
}

/// Define `obj[key]` from a JS descriptor, dispatching by target type:
/// plain objects go through the full descriptor machinery; functions define
/// into their statics bag (a real object); arrays handle length/index by
/// value (no per-index descriptors in this model) and named keys via the
/// array_props object. Non-objects are a TypeError.
pub fn definePropertyOn(self: *Interpreter, what: []const u8, obj: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    switch (obj) {
        .object => try definePropertyFromJs(self, obj, key, desc),
        .function => try definePropertyFromJs(self, try self.functionStatics(obj), key, desc),
        .array => try arrayDefineProperty(self, obj, key, desc),
        .proxy => |box| {
            if (try self.proxyTrap(box, "defineProperty")) |trap_fn| {
                defer trap_fn.deinit();
                const key_val = try self.gcNewString(key);
                defer key_val.deinit();
                const result = try trap_fn.function.value.call(trap_fn.function.value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, key_val, desc });
                defer result.deinit();
                if (!coercion.isTruthy(result)) {
                    return self.throwError(.type_error, "'defineProperty' on proxy: trap returned falsish for property '{s}'", .{key});
                }
                return;
            }
            return definePropertyOn(self, what, box.value.target, key, desc);
        },
        else => return self.throwError(.type_error, "Object.{s} called on non-object", .{what}),
    }
}

/// Best-effort Object.defineProperty on an array: `length` and canonical
/// indices set the value (arrays have no per-element descriptor storage, so
/// writable/enumerable/configurable on those are ignored); any other named
/// key is defined on the array's real array_props object.
fn arrayDefineProperty(self: *Interpreter, arr: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    if (desc != .object) return self.throwError(.type_error, "Property description must be an object", .{});
    if (std.mem.eql(u8, key, "length")) {
        if (desc.object.value.get("value")) |v| try self.setArrayProperty(arr, "length", v);
        return;
    }
    if (std.fmt.parseInt(usize, key, 10)) |_| {
        const v = desc.object.value.get("value") orelse JSValue.UNDEFINED;
        try self.setArrayProperty(arr, key, v);
        return;
    } else |_| {}
    try definePropertyFromJs(self, try self.arrayPropsObject(arr), key, desc);
}

fn objectDefineProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    try definePropertyOn(self, "defineProperty", obj, key, arg(args, 2));
    return obj.retain();
}

fn objectDefineProperties(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (obj != .object and obj != .function and obj != .array)
        return self.throwError(.type_error, "Object.defineProperties called on non-object", .{});
    const props = arg(args, 1);
    if (props != .object) return self.throwError(.type_error, "Property description must be an object", .{});
    const keys = try props.object.value.keys(allocator);
    defer allocator.free(keys);
    for (keys) |k| {
        try definePropertyOn(self, "defineProperties", obj, k, props.object.value.get(k).?);
    }
    return obj.retain();
}

/// A `{value, writable, enumerable, configurable}` descriptor object (chained
/// to Object.prototype like any ordinary object).
fn dataDescObj(self: *Interpreter, value: JSValue, writable: bool, enumerable: bool, configurable: bool) !JSValue {
    var out = try self.ordinaryObject();
    try out.object.value.set("value", value);
    try out.object.value.set("writable", JSValue.fromBool(writable));
    try out.object.value.set("enumerable", JSValue.fromBool(enumerable));
    try out.object.value.set("configurable", JSValue.fromBool(configurable));
    return out;
}

/// A descriptor object built from a stored property record (data or accessor).
fn descFromRecord(self: *Interpreter, rec: anytype) !JSValue {
    var out = try self.ordinaryObject();
    if (rec.isAccessor()) {
        try out.object.value.set("get", if (rec.getter) |g| g.retain() else JSValue.UNDEFINED);
        try out.object.value.set("set", if (rec.setter) |s| s.retain() else JSValue.UNDEFINED);
    } else {
        try out.object.value.set("value", rec.value.retain());
        try out.object.value.set("writable", JSValue.fromBool(rec.descriptor.writable));
    }
    try out.object.value.set("enumerable", JSValue.fromBool(rec.descriptor.enumerable));
    try out.object.value.set("configurable", JSValue.fromBool(rec.descriptor.configurable));
    return out;
}

pub fn objectGetOwnPropertyDescriptor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const obj = arg(args, 0);
    // ToPropertyKey, not ToString: a Symbol argument must resolve to the
    // exact same encoded key `arr[Symbol.iterator]`/`defineProperty`'s own
    // computed-key path already produces (`encodeKey`) -- ToString(symbol)
    // throws in real JS, but ToPropertyKey never stringifies a symbol at
    // all. Found via this session's own new Array/Map/Set/TypedArray
    // `[Symbol.iterator]` properties: `Object.getOwnPropertyDescriptor(arr,
    // Symbol.iterator)` (the natural way to introspect them, and test262's
    // own `verifyProperty` helper's exact call shape) previously threw an
    // uncatchable error instead of returning a real descriptor.
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    switch (obj) {
        .object => {
            const rec = obj.object.value.getOwnRecord(key) orelse return JSValue.UNDEFINED;
            return descFromRecord(self, rec);
        },
        // Functions expose name/length/prototype as own properties (with the
        // spec attributes) plus whatever's on their statics bag.
        .function => |box| {
            const deleted = self.deletedFnProps(obj);
            if (std.mem.eql(u8, key, "length"))
                return if (deleted.length) JSValue.UNDEFINED else dataDescObj(self, JSValue.fromNumber(@floatFromInt(box.value.arity)), false, false, true);
            if (std.mem.eql(u8, key, "name"))
                return if (deleted.name) JSValue.UNDEFINED else dataDescObj(self, try interp(ctx).gcNewString(box.value.name), false, false, true);
            if (std.mem.eql(u8, key, "prototype") and !isProxyConstructor(self, obj) and (box.value.prototype != null or box.value.constructable))
                return dataDescObj(self, try self.functionPrototype(obj), true, false, false);
            if (box.value.statics) |bag| {
                if (bag.object.value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            return JSValue.UNDEFINED;
        },
        // Arrays: `length` and in-bounds indices are own data properties.
        .array => |box| {
            if (std.mem.eql(u8, key, "length"))
                return dataDescObj(self, JSValue.fromNumber(@floatFromInt(box.value.length())), true, false, false);
            const idx = std.fmt.parseInt(usize, key, 10) catch return JSValue.UNDEFINED;
            if (idx >= box.value.length()) return JSValue.UNDEFINED;
            return dataDescObj(self, box.value.get(idx).retain(), true, true, true);
        },
        .undefined, .null => return self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        .proxy => |box| {
            if (try self.proxyTrap(box, "getOwnPropertyDescriptor")) |trap_fn| {
                defer trap_fn.deinit();
                const key_val = try self.gcNewString(key);
                defer key_val.deinit();
                return try trap_fn.function.value.call(trap_fn.function.value.ctx, allocator, box.value.handler, &.{ box.value.target, key_val });
            }
            return objectGetOwnPropertyDescriptor(ctx, allocator, this_value, &.{ box.value.target, arg(args, 1) });
        },
        // Other object-likes (date/regex/map/...) have no string-keyed own
        // data properties in this model yet.
        else => return JSValue.UNDEFINED,
    }
}

pub fn objectGetOwnPropertyNames(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const o = arg(args, 0);
    var result = try interp(ctx).gcNewArray();
    switch (o) {
        .object => {
            const names = try o.object.value.getOwnPropertyNames(allocator);
            defer allocator.free(names);
            for (names) |n| {
                if (isSymbolKey(n)) continue;
                _ = try result.array.value.push(try interp(ctx).gcNewString(n));
            }
        },
        // Arrays: every index (as a string), then "length".
        .array => |box| {
            var i: usize = 0;
            while (i < box.value.length()) : (i += 1) {
                const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{i});
                defer allocator.free(idx_str);
                _ = try result.array.value.push(try interp(ctx).gcNewString(idx_str));
            }
            _ = try result.array.value.push(try interp(ctx).gcNewString("length"));
        },
        // Functions: length, name, prototype (if any), then statics bag names.
        .function => |box| {
            _ = try result.array.value.push(try interp(ctx).gcNewString("length"));
            _ = try result.array.value.push(try interp(ctx).gcNewString("name"));
            if (box.value.prototype != null or box.value.constructable)
                _ = try result.array.value.push(try interp(ctx).gcNewString("prototype"));
            if (box.value.statics) |bag| {
                const names = try bag.object.value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |n| {
                    if (isSymbolKey(n)) continue;
                    _ = try result.array.value.push(try interp(ctx).gcNewString(n));
                }
            }
        },
        .undefined, .null => return self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        .proxy => |box| {
            if (try self.proxyTrap(box, "ownKeys")) |trap_fn| {
                defer trap_fn.deinit();
                const trap_result = try trap_fn.function.value.call(trap_fn.function.value.ctx, allocator, box.value.handler, &.{box.value.target});
                defer trap_result.deinit();
                if (trap_result == .array) {
                    for (trap_result.array.value.toSlice()) |item| {
                        if (item == .string) _ = try result.array.value.push(item.retain());
                    }
                }
            } else {
                const delegated = try objectGetOwnPropertyNames(ctx, allocator, this_value, &.{box.value.target});
                defer delegated.deinit();
                for (delegated.array.value.toSlice()) |item| _ = try result.array.value.push(item.retain());
            }
        },
        else => {},
    }
    return result;
}

pub fn objectGetOwnPropertySymbols(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const o = try requirePlainObject(ctx, arg(args, 0), "Object.getOwnPropertySymbols");
    const names = try o.object.value.getOwnPropertyNames(allocator);
    defer allocator.free(names);
    var result = try interp(ctx).gcNewArray();
    for (names) |n| {
        if (!isSymbolKey(n)) continue;
        if (self.symbol_keys.get(n)) |sym| _ = try result.array.value.push(sym.retain());
    }
    return result;
}

fn objectCreate(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const proto = arg(args, 0);
    if (proto != .object and proto != .null) {
        return self.throwError(.type_error, "Object prototype may only be an Object or null", .{});
    }
    var obj = try interp(ctx).gcNewObject();
    if (proto == .object) try obj.object.value.setPrototype(@constCast(&proto.object.value));
    const props = arg(args, 1);
    if (props == .object) {
        const keys = try props.object.value.keys(allocator);
        defer allocator.free(keys);
        for (keys) |k| try definePropertyFromJs(self, obj, k, props.object.value.get(k).?);
    }
    return obj;
}

fn objectFreeze(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    if (v == .object) v.object.value.freeze();
    return v.retain();
}

fn objectIsFrozen(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(if (v == .object) v.object.value.is_frozen else true);
}

fn objectSeal(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    if (v == .object) v.object.value.seal();
    return v.retain();
}

fn objectIsSealed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(if (v == .object) v.object.value.is_sealed or v.object.value.is_frozen else true);
}

fn objectPreventExtensions(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    if (v == .object) v.object.value.preventExtensions();
    return v.retain();
}

fn objectIsExtensible(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(if (v == .object) v.object.value.is_extensible else false);
}

fn objectSetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    const proto = arg(args, 1);
    if (obj != .object) return self.throwError(.type_error, "Object.setPrototypeOf called on non-object", .{});
    if (proto == .object) {
        try obj.object.value.setPrototype(@constCast(&proto.object.value));
    } else if (proto == .null) {
        try obj.object.value.setPrototype(null);
    } else {
        return self.throwError(.type_error, "Object prototype may only be an Object or null", .{});
    }
    return obj.retain();
}

/// Object.is(a, b) -- SameValue: like `===` but NaN equals NaN and +0 differs
/// from -0.
fn objectIs(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a == .number and b == .number) {
        const x = a.number;
        const y = b.number;
        if (std.math.isNan(x) and std.math.isNan(y)) return JSValue.fromBool(true);
        if (x == 0 and y == 0) return JSValue.fromBool(std.math.signbit(x) == std.math.signbit(y));
        return JSValue.fromBool(x == y);
    }
    return JSValue.fromBool(zvalue.equality.strictEquals(a, b));
}

/// Object.hasOwn(o, key) -- the static form of hasOwnProperty (ES2022).
fn objectHasOwn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = arg(args, 0);
    if (o == .undefined or o == .null) return interp(ctx).throwError(.type_error, "Cannot convert undefined or null to object", .{});
    return objHasOwnProperty(ctx, allocator, o, if (args.len > 1) args[1..] else &.{});
}

/// Object.fromEntries(iterable) -- builds an object from [key, value] pairs.
/// Narrowed to an array of pair-arrays (the common case); other iterables
/// are a documented gap.
fn objectFromEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const src = arg(args, 0);
    if (src != .array) return self.throwError(.type_error, "Object.fromEntries requires an iterable of entries", .{});
    var result = try self.ordinaryObject();
    for (src.array.value.toSlice()) |pair| {
        if (pair != .array) return self.throwError(.type_error, "Iterator value is not an entry object", .{});
        const p = &pair.array.value;
        const k = if (p.length() > 0) p.get(0) else JSValue.UNDEFINED;
        const v = if (p.length() > 1) p.get(1) else JSValue.UNDEFINED;
        const ks = try coercion.toDisplayString(allocator, k);
        defer allocator.free(ks);
        try result.object.value.set(ks, v.retain());
    }
    return result;
}

pub fn objectGetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const obj = arg(args, 0);
    return switch (obj) {
        .object => blk: {
            const p = obj.object.value.getPrototype() orelse break :blk JSValue.NULL;
            // Recover the owning Rc box from the raw *ZObject the chain
            // stores (it always points at a box's `value` field).
            const Box = @TypeOf(obj.object.*);
            const box: *Box = @fieldParentPtr("value", p);
            break :blk (JSValue{ .object = box }).retain();
        },
        .array => self.protos.array.retain(),
        .string => self.protos.string.retain(),
        .number => self.protos.number.retain(),
        .boolean => self.protos.boolean.retain(),
        .function => self.protos.function.retain(),
        .date => self.protos.date.retain(),
        .regex => self.protos.regex.retain(),
        .@"error" => self.protos.@"error".retain(),
        .map => self.protos.map.retain(),
        .set => self.protos.set.retain(),
        .symbol => self.protos.symbol.retain(),
        .promise => self.protos.promise.retain(),
        .bigint => self.protos.bigint.retain(),
        .array_buffer => self.protos.array_buffer.retain(),
        .data_view => self.protos.data_view.retain(),
        .typed_array => |box| self.typedArrayProto(box.value.kind).retain(),
        .temporal => |box| self.protos.temporalProtoFor(box.value).retain(),
        // No getPrototypeOf trap dispatch yet (Proxy plan, later phase)
        // -- delegates transparently to target, correct for the
        // no-trap case.
        .proxy => |box| objectGetPrototypeOf(ctx, allocator, this_value, &.{box.value.target}),
        .undefined, .null => self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
    };
}

/// Installs the `Object` constructor + statics. Must run FIRST (before
/// any other builtin) -- see the module doc comment.
pub fn install(self: *Interpreter) !void {
    const arena = self.gc_allocator;
    const g = self.global_env;

    // Object comes first: its constructor and real `Object.prototype` are
    // created up front so every ordinary object built below (console, Math,
    // JSON, ...) can chain to it via `self.ordinaryObject()`. The prototype
    // is populated with its methods later, uniformly, in materializeProtos.
    const object_ctor = try self.gcNewFunction(.{
        .ctx = self,
        .name = "Object",
        .arity = 1,
        .call = objectConstructor,
        .constructable = true,
    });
    const object_statics = try self.functionStatics(object_ctor);
    inline for (.{
        .{ "keys", 1, objectKeys },                                         .{ "values", 1, objectValues },
        .{ "entries", 1, objectEntries },                                   .{ "assign", 2, objectAssign },
        .{ "defineProperty", 3, objectDefineProperty },                     .{ "defineProperties", 2, objectDefineProperties },
        .{ "getOwnPropertyDescriptor", 2, objectGetOwnPropertyDescriptor }, .{ "getOwnPropertyNames", 1, objectGetOwnPropertyNames },
        .{ "getOwnPropertySymbols", 1, objectGetOwnPropertySymbols },       .{ "create", 2, objectCreate },
        .{ "freeze", 1, objectFreeze },                                     .{ "isFrozen", 1, objectIsFrozen },
        .{ "seal", 1, objectSeal },                                         .{ "isSealed", 1, objectIsSealed },
        .{ "preventExtensions", 1, objectPreventExtensions },               .{ "isExtensible", 1, objectIsExtensible },
        .{ "setPrototypeOf", 2, objectSetPrototypeOf },                     .{ "getPrototypeOf", 1, objectGetPrototypeOf },
        .{ "is", 2, objectIs },                                             .{ "hasOwn", 2, objectHasOwn },
        .{ "fromEntries", 1, objectFromEntries },
    }) |entry| {
        try dneMethod(object_statics, entry[0], try native(self, entry[0], entry[1], entry[2]));
    }
    self.protos.object = try self.functionPrototype(object_ctor);
    try g.define(arena, "Object", object_ctor);
}
