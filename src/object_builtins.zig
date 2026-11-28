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
const zstring = @import("zstring");
const zarray = @import("zarray");
const property_desc = @import("property_desc.zig");
const temporal_builtins = @import("temporal_builtins.zig");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const regex_builtins = @import("regex_builtins.zig");
const function_builtins = @import("function_builtins.zig");
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
    .{ "toLocaleString", MethodSpec{ .call = objToLocaleString, .arity = 0 } },
    .{ "valueOf", MethodSpec{ .call = objValueOf, .arity = 0 } },
    .{ "isPrototypeOf", MethodSpec{ .call = objIsPrototypeOf, .arity = 1 } },
    .{ "__defineGetter__", MethodSpec{ .call = objDefineGetter, .arity = 2 } },
    .{ "__defineSetter__", MethodSpec{ .call = objDefineSetter, .arity = 2 } },
    .{ "__lookupGetter__", MethodSpec{ .call = objLookupGetter, .arity = 1 } },
    .{ "__lookupSetter__", MethodSpec{ .call = objLookupSetter, .arity = 1 } },
});

// ===== Object statics =====

fn objToLocaleString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    if (this_value.isNull() or this_value.isUndefined()) {
        return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    }
    const to_str = try self.getProperty(this_value, "toString");
    defer to_str.deinit();
    return self.callValue(to_str, this_value, &.{}, "toString");
}

fn requireObject(ctx: *anyopaque, v: JSValue, what: []const u8) anyerror!JSValue {
    if (!v.isObject()) return interp(ctx).throwError(.type_error, "{s} called on a non-object", .{what});
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
    const self = interp(ctx);
    const names = try objectGetOwnPropertyNames(ctx, allocator, JSValue.UNDEFINED, &.{v});
    defer names.deinit();
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |k| allocator.free(k);
        owned.deinit(allocator);
    }
    for (names.asArray().value.toSlice()) |item| {
        if (!item.isString()) continue;
        const k = item.asString().value.data;
        if (isSymbolKey(k)) continue;
        if ((try ownPropertyEnumerable(self, v, k)) orelse false) {
            try owned.append(allocator, try allocator.dupe(u8, k));
        }
    }
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
        _ = try result.asArray().value.push(try interp(ctx).gcNewString(k));
    }
    return result;
}

fn objectValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const o = arg(args, 0);
    const names = try objectGetOwnPropertyNames(ctx, allocator, JSValue.UNDEFINED, &.{o});
    defer names.deinit();
    var result = try self.gcNewArray();
    errdefer result.deinit();
    for (names.asArray().value.toSlice()) |item| {
        if (!item.isString()) continue;
        const k = item.asString().value.data;
        if (isSymbolKey(k)) continue;
        if (!((try ownPropertyEnumerable(self, o, k)) orelse false)) continue;
        _ = try result.asArray().value.push(try self.getProperty(o, k));
    }
    return result;
}

fn objectEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const o = arg(args, 0);
    const names = try objectGetOwnPropertyNames(ctx, allocator, JSValue.UNDEFINED, &.{o});
    defer names.deinit();
    var result = try self.gcNewArray();
    errdefer result.deinit();
    for (names.asArray().value.toSlice()) |item| {
        if (!item.isString()) continue;
        const k = item.asString().value.data;
        if (isSymbolKey(k)) continue;
        if (!((try ownPropertyEnumerable(self, o, k)) orelse false)) continue;
        const val = try self.getProperty(o, k);
        var pair = try self.gcNewArray();
        _ = try pair.asArray().value.push(try self.gcNewString(k));
        _ = try pair.asArray().value.push(val);
        _ = try result.asArray().value.push(pair);
    }
    return result;
}

fn objectAssign(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const target = try property_desc.toObject(self, arg(args, 0));
    for (args[1..]) |source| {
        if (source.isUndefined() or source.isNull()) continue;
        const from = try property_desc.toObject(self, source);
        defer from.deinit();
        const keys = try ownPropertyKeyList(self, allocator, from);
        defer freeOwnedKeys(allocator, keys);
        for (keys) |k| {
            const enum_opt = try ownPropertyEnumerable(self, from, k);
            if (enum_opt == null or !enum_opt.?) continue;
            const val = try self.getProperty(from, k);
            defer val.deinit();
            try self.setPropertyOnValue(target, k, val);
        }
    }
    return target;
}

// ===== Object.prototype methods (object_methods table) =====

fn requirePlainObject(ctx: *anyopaque, v: JSValue, what: []const u8) anyerror!JSValue {
    if (!v.isObject()) return interp(ctx).throwError(.type_error, "{s} called on non-object", .{what});
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

pub fn objHasOwnProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const key = try self.encodeKey(arg(args, 0));
    defer allocator.free(key);
    if (this_value.isUndefined() or this_value.isNull()) {
        return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    }
    return switch (this_value.unpack()) {
        .object => |box| blk: {
            if (self.global_object) |go| {
                if (this_value.asObject() == go.asObject()) {
                    break :blk JSValue.fromBool(self.global_var_names.contains(key) or self.eval_var_names.contains(key) or self.global_env.declaresLocally(key) or box.value.hasOwnProperty(key));
                }
            }
            break :blk JSValue.fromBool(box.value.hasOwnProperty(key));
        },
        .function => |box| blk: {
            const deleted = self.deletedFnProps(this_value);
            if (box.value.statics) |bag| {
                if (bag.asObject().value.hasOwnProperty(key)) break :blk JSValue.fromBool(true);
            }
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(!deleted.length);
            if (std.mem.eql(u8, key, "name")) break :blk JSValue.fromBool(!deleted.name);
            if (std.mem.eql(u8, key, "prototype")) break :blk JSValue.fromBool(!isProxyConstructor(self, this_value) and function_builtins.boundContext(this_value) == null and (box.value.prototype != null or box.value.constructable));
            break :blk JSValue.fromBool(false);
        },
        .array => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(!self.deleted_arguments_length.contains(@intFromPtr(box)));
            if (self.array_props.get(@intFromPtr(box))) |bag| {
                if (bag.asObject().value.hasOwnProperty(key)) break :blk JSValue.fromBool(true);
            }
            const idx = zarray.CanonicalNumericIndexString(key) orelse break :blk JSValue.fromBool(false);
            break :blk JSValue.fromBool(idx < box.value.length() and !box.value.isHole(idx));
        },
        .string => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(true);
            const idx = std.fmt.parseInt(usize, key, 10) catch break :blk JSValue.fromBool(false);
            break :blk JSValue.fromBool(idx < zstring.utf16.lengthUtf16(box.value.data));
        },
        .regex => JSValue.fromBool(std.mem.eql(u8, key, "lastIndex") or
            (if (self.regexProps(this_value)) |bag| bag.asObject().value.hasOwnProperty(key) else false)),
        .temporal => JSValue.fromBool(if (self.temporalProps(this_value)) |bag| bag.asObject().value.hasOwnProperty(key) else false),
        .typed_array => |box| switch (@import("interpreter_props.zig").canonicalNumericIndex(self.gc_allocator, key, box.value.len)) {
            .valid_index => JSValue.fromBool(!builtin_helpers.isTypedArrayDetached(&box.value)),
            .invalid_index => JSValue.fromBool(false),
            .not_numeric => JSValue.fromBool(if (self.extraProps(this_value)) |bag| bag.asObject().value.hasOwnProperty(key) else false),
        },
        else => JSValue.fromBool(if (self.extraProps(this_value)) |bag| bag.asObject().value.hasOwnProperty(key) else false),
    };
}

fn objPropertyIsEnumerable(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const key = try self.encodeKey(arg(args, 0));
    defer allocator.free(key);
    if (this_value.isUndefined() or this_value.isNull()) {
        return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    }
    switch (this_value.unpack()) {
        .object => {
            if (isGlobalObject(self, this_value)) {
                return JSValue.fromBool((try ownPropertyEnumerable(self, this_value, key)) orelse false);
            }
            return JSValue.fromBool(this_value.asObject().value.propertyIsEnumerable(key));
        },
        .function => |box| return JSValue.fromBool(if (box.value.statics) |bag| bag.asObject().value.propertyIsEnumerable(key) else false),
        .temporal => return JSValue.fromBool(if (self.temporalProps(this_value)) |bag| bag.asObject().value.propertyIsEnumerable(key) else false),
        .array => |box| {
            if (std.mem.eql(u8, key, "length")) return JSValue.fromBool(false);
            if (self.array_props.get(@intFromPtr(box))) |bag| {
                if (bag.asObject().value.getOwnRecord(key)) |rec| return JSValue.fromBool(rec.descriptor.enumerable);
            }
            const idx = zarray.CanonicalNumericIndexString(key) orelse return JSValue.fromBool(false);
            return JSValue.fromBool(idx < box.value.length() and !box.value.isHole(idx));
        },
        .typed_array => |box| switch (@import("interpreter_props.zig").canonicalNumericIndex(self.gc_allocator, key, box.value.len)) {
            .valid_index => return JSValue.fromBool(!builtin_helpers.isTypedArrayDetached(&box.value)),
            .invalid_index => return JSValue.fromBool(false),
            .not_numeric => return JSValue.fromBool(if (self.extraProps(this_value)) |bag| bag.asObject().value.propertyIsEnumerable(key) else false),
        },
        else => return JSValue.fromBool(if (self.extraProps(this_value)) |bag| bag.asObject().value.propertyIsEnumerable(key) else false),
    }
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
/// `pub`: array-generic-methods.md's `Array.prototype.toString`
/// reaches this directly (not via a live `Get(Object.prototype,
/// "toString")`) for its %Object.prototype.toString% intrinsic
/// fallback -- real spec means the FIXED intrinsic here, not
/// whatever currently lives at that property (which a test can and
/// does delete: `delete Object.prototype.toString` must not change
/// this fallback's behavior). Same reach-back pattern as
/// `reflect_builtins.zig`'s `object_builtins.X` aliases.
fn isArrayForToString(self: *Interpreter, v: JSValue) anyerror!bool {
    var cur = v;
    while (cur.isProxy()) {
        const box = cur.asProxy();
        if (box.value.handler.isNull()) {
            return self.throwError(.type_error, "Cannot perform 'isArray' on a proxy that has been revoked", .{});
        }
        cur = box.value.target;
    }
    if (!cur.isArray()) return false;
    return !self.arguments_arrays.contains(@intFromPtr(cur.asArray()));
}

pub fn objToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    if (this_value.isUndefined()) return self.gcNewString("[object Undefined]");
    if (this_value.isNull()) return self.gcNewString("[object Null]");

    const obj = try property_desc.toObject(self, this_value);
    defer obj.deinit();

    const is_array = try isArrayForToString(self, obj);
    const builtin_tag: []const u8 = if (is_array)
        "Array"
    else switch (obj.unpack()) {
        .array => |box| if (self.arguments_arrays.contains(@intFromPtr(box))) "Arguments" else "Array",
        .function => "Function",
        .@"error" => "Error",
        .date => "Date",
        .regex => "RegExp",
        .proxy => if (property_desc.isCallableWithInterp(self, obj)) "Function" else "Object",
        .object => blk_obj: {
            if (self.unboxPrimitiveWrapper(obj)) |prim| {
                break :blk_obj switch (prim.tag()) {
                    .boolean => "Boolean",
                    .number => "Number",
                    .string => "String",
                    else => "Object",
                };
            }
            if (obj.asObject().value.is_error_data) break :blk_obj "Error";
            if (zvalue.equality.strictEquals(obj, self.protos.function)) break :blk_obj "Function";
            break :blk_obj "Object";
        },
        else => "Object",
    };

    var owned_tag = JSValue.UNDEFINED;
    defer owned_tag.deinit();
    var tag: []const u8 = builtin_tag;
    if (self.symbol_to_string_tag) |tag_sym| {
        const tag_key = try self.encodeKey(tag_sym);
        defer self.gc_allocator.free(tag_key);
        owned_tag = try self.getProperty(obj, tag_key);
        if (owned_tag.isString()) tag = owned_tag.asString().value.data;
    }

    const msg = try std.fmt.allocPrint(self.gc_allocator, "[object {s}]", .{tag});
    defer self.gc_allocator.free(msg);
    return self.gcNewString(msg);
}

fn objValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return property_desc.toObject(interp(ctx), this_value);
}

fn objIsPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const v_arg = arg(args, 0);
    if (!builtin_helpers.isObjectLike(v_arg)) return JSValue.fromBool(false);
    const o = try property_desc.toObject(self, this_value);
    defer o.deinit();
    var cur = try objectGetPrototypeOf(ctx, allocator, JSValue.UNDEFINED, &.{v_arg});
    while (!cur.isNull()) {
        if (zvalue.equality.strictEquals(o, cur)) {
            cur.deinit();
            return JSValue.fromBool(true);
        }
        const next = try objectGetPrototypeOf(ctx, allocator, JSValue.UNDEFINED, &.{cur});
        cur.deinit();
        cur = next;
    }
    return JSValue.fromBool(false);
}

// ===== Object statics: constructor + descriptors =====

pub fn toObjectValue(self: *Interpreter, v: JSValue) anyerror!JSValue {
    return switch (v.tag()) {
        // Object(x) on object-likes returns x; on nothing, a fresh {}.
        .object, .array, .function, .@"error", .date, .promise, .map, .set, .regex, .temporal, .typed_array, .array_buffer, .data_view, .proxy => v.retain(),
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

pub fn objectConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    if (self.construct_target == ctx) {
        self.construct_target = null;
        if (self.construct_new_target) |nt| {
            if (self.global_env.get("Object")) |obj_ctor| {
                if (!zvalue.equality.strictEquals(nt, obj_ctor) and this_value.isObject()) {
                    return this_value.retain();
                }
            }
        }
    }
    return toObjectValue(self, arg(args, 0));
}

/// `Object(primitive)`'s wrapper: a fresh object chaining to `proto`
/// (the primitive's OWN prototype), registered in
/// primitive_wrapper_data so it unboxes exactly like `new Number(x)`/
/// etc (see `unboxPrimitiveWrapper`'s doc comment -- same side table,
/// same contract, just populated from a different call site).
fn boxWrapper(self: *Interpreter, proto: JSValue, primitive: JSValue) anyerror!JSValue {
    const obj = try self.gcNewObject();
    try obj.asObject().value.setPrototype(&proto.asObject().value);
    try self.primitive_wrapper_data.put(self.gc_allocator, @intFromPtr(obj.asObject()), primitive.retain());
    if (primitive.isString()) {
        try self.initStringWrapperProperties(obj, primitive);
    }
    return obj;
}

/// Shared by defineProperty/defineProperties/create: applies ONE
/// JS-shaped descriptor to obj[key], with the spec's partial-descriptor
/// merge on existing configurable properties. Defining bypasses
/// `writable` (that's assignment's rule, not definition's).
fn definePropertyFromJs(self: *Interpreter, obj: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    const arena = self.gc_allocator;
    if (!desc.isObject()) {
        return self.throwError(.type_error, "Property description must be an object", .{});
    }
    const d = &desc.asObject().value;

    const has_get = d.hasOwnProperty("get");
    const has_set = d.hasOwnProperty("set");
    const has_value = d.hasOwnProperty("value");
    const has_writable = d.hasOwnProperty("writable");
    if ((has_get or has_set) and (has_value or has_writable)) {
        return self.throwError(.type_error, "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute", .{});
    }

    const existing = obj.asObject().value.getOwnRecordMut(key);
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
            break :blk if (g.isFunction()) g.retain() else null;
        } else null;
        const setter = if (has_set) blk: {
            const s = d.get("set").?;
            break :blk if (s.isFunction()) s.retain() else null;
        } else null;
        try obj.asObject().value.defineAccessor(key, getter, setter, JSValue.UNDEFINED);
        const rec = obj.asObject().value.getOwnRecordMut(key).?;
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
        // Known leak: the old value (or getter/setter) is overwritten
        // without being released. Not migrated to objectDefine, which
        // replaces the whole descriptor instead of merging fields.
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
    obj.asObject().value.defineProperty(key, value, descriptor) catch |err| return switch (err) {
        error.ObjectNotExtensible => self.throwError(.type_error, "Cannot define property {s}, object is not extensible", .{key}),
        error.PropertyNotConfigurable => self.throwError(.type_error, "Cannot redefine property: {s}", .{key}),
        else => err,
    };
    _ = arena;
}

pub fn definePropertyOn(self: *Interpreter, what: []const u8, obj: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    return property_desc.definePropertyOn(self, what, obj, key, desc);
}

fn objectDefineProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (!builtin_helpers.isObjectLike(obj)) return self.throwError(.type_error, "Object.defineProperty called on non-object", .{});
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    try property_desc.definePropertyOn(self, "defineProperty", obj, key, arg(args, 2));
    return obj.retain();
}

fn objectDefineProperties(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (!builtin_helpers.isObjectLike(obj)) return self.throwError(.type_error, "Object.defineProperties called on non-object", .{});
    try property_desc.objectDefinePropertiesImpl(self, allocator, obj, arg(args, 1));
    return obj.retain();
}

/// A `{value, writable, enumerable, configurable}` descriptor object (chained
/// to Object.prototype like any ordinary object).
/// True when `obj` is the well-known `globalThis` object -- reads/writes
/// on it are redirected to the global environment rather than a real
/// property bag (see interpreter_props.zig's getProperty/
/// setPropertyOnValue), so reflective APIs need the same redirect.
fn isGlobalObject(self: *Interpreter, obj: JSValue) bool {
    const go = self.global_object orelse return false;
    return obj.isObject() and obj.asObject() == go.asObject();
}

/// `Object.getOwnPropertyDescriptor(globalThis, key)` for a name that
/// lives in the global environment rather than a real property bag --
/// null if `key` isn't one of these (falls through to the normal bag
/// lookup). Attributes confirmed against real Node: top-level `var`/
/// function declarations are enumerable but non-configurable
/// (CreateGlobalVarBinding); `undefined`/`NaN`/`Infinity` are fully
/// locked down; an original builtin (isNaN, Boolean, Math, ...) is
/// writable and configurable but non-enumerable, while a later ad-hoc
/// `globalThis.foo = 1` write is writable, enumerable, AND configurable
/// (distinguished via global_builtin_names -- see its doc comment).
/// Mirrors getProperty's own precedence (global-env binding shadows a
/// same-named bag record).
fn globalPropertyDescriptor(self: *Interpreter, key: []const u8) !?JSValue {
    if (self.global_object) |go| {
        if (go.asObject().value.getOwnRecord(key)) |rec| {
            return try descFromRecord(self, rec);
        }
    }
    if (self.global_var_names.contains(key)) {
        const env = self.global_var_env orelse self.global_env;
        if (env.getLocalBinding(key)) |v| return try dataDescObj(self, v.retain(), true, true, false);
        return null;
    }
    if (self.eval_var_names.contains(key)) {
        const env = self.global_var_env orelse self.global_env;
        if (env.getLocalBinding(key)) |v| return try dataDescObj(self, v.retain(), true, true, true);
        return null;
    }
    if (std.mem.eql(u8, key, "undefined") or std.mem.eql(u8, key, "NaN") or std.mem.eql(u8, key, "Infinity")) {
        if (self.global_env.getLocalBinding(key)) |v| return try dataDescObj(self, v.retain(), false, false, false);
        return null;
    }
    if (self.global_env.getLocalBinding(key)) |v| {
        const is_builtin = self.global_builtin_names.contains(key);
        return try dataDescObj(self, v.retain(), true, !is_builtin, true);
    }
    return null;
}

fn dataDescObj(self: *Interpreter, value: JSValue, writable: bool, enumerable: bool, configurable: bool) !JSValue {
    var out = try self.ordinaryObject();
    try out.asObject().value.set("value", value);
    try out.asObject().value.set("writable", JSValue.fromBool(writable));
    try out.asObject().value.set("enumerable", JSValue.fromBool(enumerable));
    try out.asObject().value.set("configurable", JSValue.fromBool(configurable));
    return out;
}

/// A descriptor object built from a stored property record (data or accessor).
fn descFromRecord(self: *Interpreter, rec: anytype) !JSValue {
    var out = try self.ordinaryObject();
    if (rec.isAccessor()) {
        try out.asObject().value.set("get", if (rec.getter) |g| g.retain() else JSValue.UNDEFINED);
        try out.asObject().value.set("set", if (rec.setter) |s| s.retain() else JSValue.UNDEFINED);
    } else {
        try out.asObject().value.set("value", rec.value.retain());
        try out.asObject().value.set("writable", JSValue.fromBool(rec.descriptor.writable));
    }
    try out.asObject().value.set("enumerable", JSValue.fromBool(rec.descriptor.enumerable));
    try out.asObject().value.set("configurable", JSValue.fromBool(rec.descriptor.configurable));
    return out;
}

pub fn objectGetOwnPropertyDescriptor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const obj = arg(args, 0);
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    switch (obj.unpack()) {
        .object => {
            if (isGlobalObject(self, obj)) {
                if (try globalPropertyDescriptor(self, key)) |d| return d;
            }
            const rec = obj.asObject().value.getOwnRecord(key) orelse return JSValue.UNDEFINED;
            return descFromRecord(self, rec);
        },
        .function => |box| {
            const deleted = self.deletedFnProps(obj);
            if (box.value.statics) |bag| {
                if (bag.asObject().value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            if (std.mem.eql(u8, key, "length"))
                return if (deleted.length) JSValue.UNDEFINED else dataDescObj(self, JSValue.fromNumber(@floatFromInt(box.value.arity)), false, false, true);
            if (std.mem.eql(u8, key, "name"))
                return if (deleted.name) JSValue.UNDEFINED else dataDescObj(self, try interp(ctx).gcNewString(box.value.name), false, false, true);
            if (std.mem.eql(u8, key, "prototype")) {
                if (!isProxyConstructor(self, obj) and function_builtins.boundContext(obj) == null and (box.value.prototype != null or box.value.constructable)) {
                    const is_builtin = box.value.ctx == @as(*anyopaque, @ptrCast(self));
                    return dataDescObj(self, (try self.functionPrototype(obj)).retain(), !is_builtin, false, false);
                }
            }
            return JSValue.UNDEFINED;
        },
        .array => |box| {
            const bag_opt = self.array_props.get(@intFromPtr(box));
            if (std.mem.eql(u8, key, "length")) {
                if (bag_opt) |bag| {
                    if (bag.asObject().value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
                }
                if (self.deleted_arguments_length.contains(@intFromPtr(box))) return JSValue.UNDEFINED;
                const configurable = self.arguments_arrays.contains(@intFromPtr(box));
                return dataDescObj(self, JSValue.fromNumber(@floatFromInt(box.value.length())), box.value.isLengthWritable(), false, configurable);
            }
            if (bag_opt) |bag| {
                if (bag.asObject().value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            const idx = zarray.CanonicalNumericIndexString(key) orelse return JSValue.UNDEFINED;
            if (idx >= box.value.length() or box.value.isHole(idx)) return JSValue.UNDEFINED;
            const val = box.value.getOpt(idx) orelse return JSValue.UNDEFINED;
            const is_frozen = if (bag_opt) |b| b.asObject().value.is_frozen else false;
            const is_sealed = if (bag_opt) |b| b.asObject().value.is_sealed else false;
            return dataDescObj(self, val.retain(), !is_frozen, true, !(is_frozen or is_sealed));
        },
        .typed_array => |box| {
            switch (@import("interpreter_props.zig").canonicalNumericIndex(self.gc_allocator, key, box.value.len)) {
                .valid_index => |idx| {
                    if (builtin_helpers.isTypedArrayDetached(&box.value)) return JSValue.UNDEFINED;
                    const val = try builtin_helpers.typedElemGet(self, box.value.kind, &box.value.owner.asArrayBuffer().value, box.value.byte_offset, box.value.len, idx);
                    return dataDescObj(self, val, true, true, true);
                },
                .invalid_index => return JSValue.UNDEFINED,
                .not_numeric => {
                    if (self.extraProps(obj)) |bag| {
                        if (bag.asObject().value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
                    }
                    return JSValue.UNDEFINED;
                },
            }
        },
        .undefined, .null => return self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        .proxy => |box| {
            if (try self.proxyTrap(box, "getOwnPropertyDescriptor")) |trap_fn| {
                defer trap_fn.deinit();
                const key_val = try property_desc.keyToValue(self, key);
                defer key_val.deinit();
                const trap_result = try trap_fn.asFunction().value.call(trap_fn.asFunction().value.ctx, allocator, box.value.handler, &.{ box.value.target, key_val });
                errdefer trap_result.deinit();
                if (!trap_result.isUndefined() and !trap_result.isObject()) {
                    return self.throwError(.type_error, "'getOwnPropertyDescriptor' on proxy: trap returned neither object nor undefined", .{});
                }
                const target_desc = try objectGetOwnPropertyDescriptor(ctx, allocator, this_value, &.{ box.value.target, arg(args, 1) });
                defer target_desc.deinit();
                if (trap_result.isUndefined()) {
                    if (target_desc.isObject()) {
                        const target_cfg = if (target_desc.asObject().value.get("configurable")) |c| coercion.isTruthy(c) else false;
                        if (!target_cfg) {
                            return self.throwError(.type_error, "'getOwnPropertyDescriptor' on proxy: trap returned undefined for property '{s}' which is non-configurable in the proxy target", .{property_desc.displayKey(key)});
                        }
                        if (!try isExtensibleInternal(self, box.value.target)) {
                            return self.throwError(.type_error, "'getOwnPropertyDescriptor' on proxy: trap returned undefined for property '{s}' which exists in the non-extensible proxy target", .{property_desc.displayKey(key)});
                        }
                    }
                    return JSValue.UNDEFINED;
                }
                var result_desc = try property_desc.toPropertyDescriptor(self, trap_result);
                defer result_desc.deinit();
                const ext = try isExtensibleInternal(self, box.value.target);
                if (target_desc.isUndefined()) {
                    if (!ext) {
                        return self.throwError(.type_error, "'getOwnPropertyDescriptor' on proxy: trap returned descriptor for property '{s}' that does not exist in the non-extensible proxy target", .{property_desc.displayKey(key)});
                    }
                    if (!result_desc.configurable) {
                        return self.throwError(.type_error, "'getOwnPropertyDescriptor' on proxy: trap returned non-configurable descriptor for property '{s}' that does not exist in the proxy target", .{property_desc.displayKey(key)});
                    }
                } else if (target_desc.isObject()) {
                    const td_obj = &target_desc.asObject().value;
                    const target_cfg = if (td_obj.get("configurable")) |c| coercion.isTruthy(c) else false;
                    if (target_cfg and !result_desc.configurable) {
                        return self.throwError(.type_error, "'getOwnPropertyDescriptor' on proxy: trap reported non-configurability for property '{s}' which is configurable in the proxy target", .{property_desc.displayKey(key)});
                    }
                    if (!result_desc.configurable and result_desc.has_writable and !result_desc.writable) {
                        const target_w = if (td_obj.get("writable")) |wv| coercion.isTruthy(wv) else false;
                        if (target_w) {
                            return self.throwError(.type_error, "'getOwnPropertyDescriptor' on proxy: trap reported non-configurable and non-writable for property '{s}' which is writable in the proxy target", .{property_desc.displayKey(key)});
                        }
                    }
                }
                if (result_desc.isGeneric() or result_desc.isData()) {
                    if (!result_desc.has_value) {
                        result_desc.has_value = true;
                        result_desc.value = JSValue.UNDEFINED;
                    }
                    if (!result_desc.has_writable) {
                        result_desc.has_writable = true;
                        result_desc.writable = false;
                    }
                } else {
                    if (!result_desc.has_get) {
                        result_desc.has_get = true;
                        result_desc.get = JSValue.UNDEFINED;
                    }
                    if (!result_desc.has_set) {
                        result_desc.has_set = true;
                        result_desc.set = JSValue.UNDEFINED;
                    }
                }
                if (!result_desc.has_enumerable) {
                    result_desc.has_enumerable = true;
                    result_desc.enumerable = false;
                }
                if (!result_desc.has_configurable) {
                    result_desc.has_configurable = true;
                    result_desc.configurable = false;
                }
                trap_result.deinit();
                return property_desc.fromParsedDesc(self, &result_desc);
            }
            return objectGetOwnPropertyDescriptor(ctx, allocator, this_value, &.{ box.value.target, arg(args, 1) });
        },
        .string => |box| {
            const raw = box.value.data;
            const len = zstring.utf16.lengthUtf16(raw);
            if (std.mem.eql(u8, key, "length")) {
                return dataDescObj(self, JSValue.fromNumber(@floatFromInt(len)), false, false, false);
            }
            const idx = zarray.CanonicalNumericIndexString(key) orelse return JSValue.UNDEFINED;
            if (idx >= len) return JSValue.UNDEFINED;
            const ch = try zstring.access.charAt(self.gc_allocator, raw, @intCast(idx));
            defer self.gc_allocator.free(ch);
            return dataDescObj(self, try self.gcNewString(ch), false, true, false);
        },
        .regex => {
            if (std.mem.eql(u8, key, "lastIndex"))
                return dataDescObj(self, self.regexState(obj).last_index.retain(), self.regexState(obj).last_index_writable, false, false);
            if (self.regexProps(obj)) |bag| {
                if (bag.asObject().value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            return JSValue.UNDEFINED;
        },
        .temporal => {
            if (self.temporalProps(obj)) |bag| {
                if (bag.asObject().value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            return JSValue.UNDEFINED;
        },
        else => {
            if (self.extraProps(obj)) |bag| {
                if (bag.asObject().value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            return JSValue.UNDEFINED;
        },
    }
}

pub fn proxyOwnPropertyKeys(self: *Interpreter, allocator: Allocator, proxy_val: JSValue) anyerror!JSValue {
    const box = proxy_val.asProxy();
    const trap_fn = (try self.proxyTrap(box, "ownKeys")) orelse {
        const names = try objectGetOwnPropertyNames(self, allocator, JSValue.UNDEFINED, &.{box.value.target});
        const syms = try objectGetOwnPropertySymbols(self, allocator, JSValue.UNDEFINED, &.{box.value.target});
        defer syms.deinit();
        for (syms.asArray().value.toSlice()) |s| _ = try names.asArray().value.push(s.retain());
        return names;
    };
    defer trap_fn.deinit();
    const trap_result = try self.callValue(trap_fn, box.value.handler, &.{box.value.target}, "ownKeys");
    defer trap_result.deinit();
    if (!builtin_helpers.isObjectLike(trap_result)) {
        return self.throwError(.type_error, "'ownKeys' on proxy: trap must return an object", .{});
    }
    const items_owned = try builtin_helpers.arrayLikeToList(self, allocator, trap_result);
    defer {
        for (items_owned) |it| it.deinit();
        allocator.free(items_owned);
    }
    const items = items_owned;
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit(allocator);
    }
    for (items) |item| {
        if (!item.isString() and !item.isSymbol()) {
            return self.throwError(.type_error, "'ownKeys' on proxy: trap result must be string or symbol", .{});
        }
        const key_str = try self.encodeKey(item);
        if (seen.contains(key_str)) {
            allocator.free(key_str);
            return self.throwError(.type_error, "'ownKeys' on proxy: trap returned duplicate entry '{s}'", .{property_desc.displayKey(key_str)});
        }
        try seen.put(allocator, key_str, {});
    }

    const target = box.value.target;
    const is_extensible = try isExtensibleInternal(self, target);
    const target_keys = try ownPropertyKeyList(self, allocator, target);
    defer freeOwnedKeys(allocator, target_keys);

    var target_key_set = std.StringHashMapUnmanaged(void).empty;
    defer target_key_set.deinit(allocator);
    for (target_keys) |k| try target_key_set.put(allocator, k, {});

    for (target_keys) |k| {
        const kv = try property_desc.keyToValue(self, k);
        defer kv.deinit();
        const desc = try objectGetOwnPropertyDescriptor(self, allocator, JSValue.UNDEFINED, &.{ target, kv });
        defer desc.deinit();
        const is_non_configurable = if (desc.isObject())
            if (desc.asObject().value.get("configurable")) |c| !coercion.isTruthy(c) else false
        else
            false;

        if (is_non_configurable) {
            if (!seen.contains(k)) {
                return self.throwError(.type_error, "'ownKeys' on proxy: trap result did not include non-configurable key '{s}'", .{property_desc.displayKey(k)});
            }
        }
    }

    if (!is_extensible) {
        for (target_keys) |k| {
            if (!seen.contains(k)) {
                return self.throwError(.type_error, "'ownKeys' on proxy: trap result did not include target key '{s}' of non-extensible target", .{property_desc.displayKey(k)});
            }
        }
        var it = seen.keyIterator();
        while (it.next()) |k| {
            if (!target_key_set.contains(k.*)) {
                return self.throwError(.type_error, "'ownKeys' on proxy: trap result included extra key '{s}' not in non-extensible target", .{property_desc.displayKey(k.*)});
            }
        }
    }

    var out_arr = try self.gcNewArray();
    for (items) |it| _ = try out_arr.asArray().value.push(it.retain());
    return out_arr;
}

pub fn objectGetOwnPropertyNames(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const o = arg(args, 0);
    var result = try interp(ctx).gcNewArray();
    switch (o.unpack()) {
        .object => {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(allocator);
            if (isGlobalObject(self, o)) {
                if (self.global_var_env) |gve| {
                    for (gve.bindings.items) |binding| {
                        if (!self.global_var_names.contains(binding.name) and !self.eval_var_names.contains(binding.name)) continue;
                        if (seen.contains(binding.name)) continue;
                        try seen.put(allocator, binding.name, {});
                        _ = try result.asArray().value.push(try interp(ctx).gcNewString(binding.name));
                    }
                }
                for (self.global_env.bindings.items) |binding| {
                    if (seen.contains(binding.name)) continue;
                    try seen.put(allocator, binding.name, {});
                    _ = try result.asArray().value.push(try interp(ctx).gcNewString(binding.name));
                }
            }
            const names = try o.asObject().value.getOwnPropertyNames(allocator);
            defer allocator.free(names);
            for (names) |n| {
                if (isSymbolKey(n)) continue;
                if (seen.contains(n)) continue;
                _ = try result.asArray().value.push(try interp(ctx).gcNewString(n));
            }
        },
        .array => |box| {
            if (box.value.getSparse()) |sp| {
                var keys_list: std.ArrayList(usize) = .empty;
                defer keys_list.deinit(allocator);
                var it = sp.iterator();
                while (it.next()) |e| {
                    if (e.key_ptr.* < box.value.length()) try keys_list.append(allocator, e.key_ptr.*);
                }
                std.mem.sort(usize, keys_list.items, {}, std.sort.asc(usize));
                for (keys_list.items) |idx| {
                    const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{idx});
                    defer allocator.free(idx_str);
                    _ = try result.asArray().value.push(try interp(ctx).gcNewString(idx_str));
                }
            } else {
                var i: usize = 0;
                while (i < box.value.length()) : (i += 1) {
                    if (box.value.isHole(i)) continue;
                    const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{i});
                    defer allocator.free(idx_str);
                    _ = try result.asArray().value.push(try interp(ctx).gcNewString(idx_str));
                }
            }
            const bag_opt = self.array_props.get(@intFromPtr(box));
            const has_len = !self.deleted_arguments_length.contains(@intFromPtr(box)) or
                (if (bag_opt) |b| b.asObject().value.hasOwnProperty("length") else false);
            if (has_len) _ = try result.asArray().value.push(try interp(ctx).gcNewString("length"));
            if (bag_opt) |bag| {
                const names = try bag.asObject().value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |n| {
                    if (isSymbolKey(n) or std.mem.eql(u8, n, "length") or zarray.CanonicalNumericIndexString(n) != null) continue;
                    _ = try result.asArray().value.push(try interp(ctx).gcNewString(n));
                }
            }
        },
        .function => |box| {
            const deleted = self.deletedFnProps(o);
            const has_proto = !isProxyConstructor(self, o) and function_builtins.boundContext(o) == null and (box.value.prototype != null or box.value.constructable);
            var statics_names: ?[]const []const u8 = null;
            defer if (statics_names) |sn| allocator.free(sn);
            if (box.value.statics) |bag| {
                const names = try bag.asObject().value.getOwnPropertyNames(allocator);
                statics_names = names;
                for (names) |n| {
                    if (isSymbolKey(n)) continue;
                    if (zarray.CanonicalNumericIndexString(n) != null) {
                        _ = try result.asArray().value.push(try interp(ctx).gcNewString(n));
                    }
                }
            }
            if (!deleted.length) _ = try result.asArray().value.push(try interp(ctx).gcNewString("length"));
            if (!deleted.name) _ = try result.asArray().value.push(try interp(ctx).gcNewString("name"));
            if (has_proto)
                _ = try result.asArray().value.push(try interp(ctx).gcNewString("prototype"));
            if (statics_names) |names| {
                for (names) |n| {
                    if (isSymbolKey(n)) continue;
                    if (zarray.CanonicalNumericIndexString(n) != null) continue;
                    if (!deleted.length and std.mem.eql(u8, n, "length")) continue;
                    if (!deleted.name and std.mem.eql(u8, n, "name")) continue;
                    if (has_proto and std.mem.eql(u8, n, "prototype")) continue;
                    _ = try result.asArray().value.push(try interp(ctx).gcNewString(n));
                }
            }
        },
        .string => |box| {
            const len = zstring.utf16.lengthUtf16(box.value.data);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{i});
                defer allocator.free(idx_str);
                _ = try result.asArray().value.push(try interp(ctx).gcNewString(idx_str));
            }
            _ = try result.asArray().value.push(try interp(ctx).gcNewString("length"));
        },
        .regex => {
            if (self.regexProps(o)) |bag| {
                const names = try bag.asObject().value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |n| {
                    if (isSymbolKey(n)) continue;
                    if (zarray.CanonicalNumericIndexString(n) != null) {
                        _ = try result.asArray().value.push(try interp(ctx).gcNewString(n));
                    }
                }
                _ = try result.asArray().value.push(try interp(ctx).gcNewString("lastIndex"));
                for (names) |n| {
                    if (isSymbolKey(n) or std.mem.eql(u8, n, "lastIndex")) continue;
                    if (zarray.CanonicalNumericIndexString(n) != null) continue;
                    _ = try result.asArray().value.push(try interp(ctx).gcNewString(n));
                }
            } else {
                _ = try result.asArray().value.push(try interp(ctx).gcNewString("lastIndex"));
            }
        },
        .temporal => {
            if (self.temporalProps(o)) |bag| {
                const names = try bag.asObject().value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |name| {
                    if (!isSymbolKey(name)) _ = try result.asArray().value.push(try self.gcNewString(name));
                }
            }
        },
        .undefined, .null => return self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        .proxy => {
            const all_keys = try proxyOwnPropertyKeys(self, allocator, o);
            defer all_keys.deinit();
            for (all_keys.asArray().value.toSlice()) |item| {
                if (item.isString()) _ = try result.asArray().value.push(item.retain());
            }
        },
        .typed_array => |box| {
            var i: usize = 0;
            const ta_len = if (builtin_helpers.isTypedArrayDetached(&box.value)) 0 else box.value.len;
            while (i < ta_len) : (i += 1) {
                const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{i});
                defer allocator.free(idx_str);
                _ = try result.asArray().value.push(try interp(ctx).gcNewString(idx_str));
            }
            if (self.extraProps(o)) |bag| {
                const names = try bag.asObject().value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |n| {
                    if (!isSymbolKey(n)) _ = try result.asArray().value.push(try interp(ctx).gcNewString(n));
                }
            }
        },
        else => {
            if (self.extraProps(o)) |bag| {
                const names = try bag.asObject().value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |n| {
                    if (!isSymbolKey(n)) _ = try result.asArray().value.push(try interp(ctx).gcNewString(n));
                }
            }
        },
    }
    return result;
}

pub fn objectGetOwnPropertySymbols(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const o = arg(args, 0);
    if (o.isUndefined() or o.isNull()) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    var result = try interp(ctx).gcNewArray();
    if (o.isProxy()) {
        const all_keys = try proxyOwnPropertyKeys(self, allocator, o);
        defer all_keys.deinit();
        for (all_keys.asArray().value.toSlice()) |item| {
            if (item.isSymbol()) _ = try result.asArray().value.push(item.retain());
        }
        return result;
    }
    const bag_opt: ?JSValue = switch (o.unpack()) {
        .object => o,
        .temporal => self.temporalProps(o),
        .array => |box| self.array_props.get(@intFromPtr(box)),
        .function => |box| box.value.statics,
        .regex => self.regexProps(o),
        else => self.extraProps(o),
    };
    if (bag_opt) |bag| {
        const names = try bag.asObject().value.getOwnPropertyNames(allocator);
        defer allocator.free(names);
        for (names) |n| {
            if (!isSymbolKey(n)) continue;
            if (self.symbol_keys.get(n)) |sym| _ = try result.asArray().value.push(sym.retain());
        }
    }
    return result;
}

fn objectCreate(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const proto = arg(args, 0);
    if (!builtin_helpers.isObjectLike(proto) and !proto.isNull()) {
        return self.throwError(.type_error, "Object prototype may only be an Object or null", .{});
    }
    const obj = try interp(ctx).gcNewObject();
    if (!proto.isNull()) try self.setOwnedPrototype(obj, proto);
    if (args.len >= 2 and !args[1].isUndefined()) {
        try property_desc.objectDefinePropertiesImpl(self, allocator, obj, args[1]);
    }
    return obj;
}

fn extensibilityBag(self: *Interpreter, v: JSValue) ?JSValue {
    return switch (v.unpack()) {
        .object => v,
        .function => |box| box.value.statics,
        .array => |box| self.array_props.get(@intFromPtr(box)),
        .regex => self.regexProps(v),
        .temporal => self.temporalProps(v),
        else => self.extraProps(v),
    };
}

fn extensibilityBagForWrite(self: *Interpreter, v: JSValue) anyerror!?JSValue {
    return switch (v.tag()) {
        .object => v,
        .function => try self.functionStatics(v),
        .array => try self.arrayPropsObject(v),
        .regex => try self.regexPropsObject(v),
        .temporal => try self.temporalPropsObject(v),
        else => try self.extraPropsObject(v),
    };
}

fn objectFreeze(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (!builtin_helpers.isObjectLike(v)) return v.retain();
    if (!try preventExtensionsInternal(self, v)) {
        return self.throwError(.type_error, "Cannot prevent extensions", .{});
    }
    const keys = try ownPropertyKeyList(self, allocator, v);
    defer freeOwnedKeys(allocator, keys);
    const arr_bag_opt = if (v.isArray()) self.array_props.get(@intFromPtr(v.asArray())) else null;
    for (keys) |k| {
        if (v.isArray() and zarray.CanonicalNumericIndexString(k) != null) {
            if (arr_bag_opt == null or !arr_bag_opt.?.asObject().value.hasOwnProperty(k)) continue;
        }
        const kv = try property_desc.keyToValue(self, k);
        defer kv.deinit();
        const current_desc = try objectGetOwnPropertyDescriptor(ctx, allocator, JSValue.UNDEFINED, &.{ v, kv });
        defer current_desc.deinit();
        if (!current_desc.isUndefined()) {
            const is_accessor = current_desc.isObject() and (current_desc.asObject().value.hasOwnProperty("get") or current_desc.asObject().value.hasOwnProperty("set"));
            var d = if (is_accessor)
                property_desc.ParsedDesc{ .has_configurable = true, .configurable = false }
            else
                property_desc.ParsedDesc{ .has_configurable = true, .configurable = false, .has_writable = true, .writable = false };
            if (!try property_desc.defineOwnProperty(self, v, k, &d)) {
                return self.throwError(.type_error, "Cannot freeze property: {s}", .{property_desc.displayKey(k)});
            }
        }
    }
    if (!v.isProxy()) {
        if (v.isArray()) v.asArray().value.setLengthWritable(false) catch {};
        if (try extensibilityBagForWrite(self, v)) |bag| bag.asObject().value.freeze();
        if (v.isRegex()) self.regexState(v).last_index_writable = false;
    }
    return v.retain();
}

fn testIntegrityLevel(ctx: *anyopaque, allocator: Allocator, v: JSValue, is_frozen: bool) anyerror!JSValue {
    const self = interp(ctx);
    if (!builtin_helpers.isObjectLike(v)) return JSValue.fromBool(true);
    if (try isExtensibleInternal(self, v)) return JSValue.fromBool(false);
    const keys = try ownPropertyKeyList(self, allocator, v);
    defer freeOwnedKeys(allocator, keys);
    for (keys) |k| {
        const kv = try property_desc.keyToValue(self, k);
        defer kv.deinit();
        const current_desc = try objectGetOwnPropertyDescriptor(ctx, allocator, JSValue.UNDEFINED, &.{ v, kv });
        defer current_desc.deinit();
        if (current_desc.isObject()) {
            if (current_desc.asObject().value.get("configurable")) |cfg| {
                if (coercion.isTruthy(cfg)) return JSValue.fromBool(false);
            }
            if (is_frozen) {
                if (current_desc.asObject().value.get("writable")) |w| {
                    if (coercion.isTruthy(w)) return JSValue.fromBool(false);
                }
            }
        }
    }
    return JSValue.fromBool(true);
}

fn objectIsFrozen(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return testIntegrityLevel(ctx, allocator, arg(args, 0), true);
}

fn objectSeal(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (!builtin_helpers.isObjectLike(v)) return v.retain();
    if (!try preventExtensionsInternal(self, v)) {
        return self.throwError(.type_error, "Cannot prevent extensions", .{});
    }
    const keys = try ownPropertyKeyList(self, allocator, v);
    defer freeOwnedKeys(allocator, keys);
    const arr_bag_opt = if (v.isArray()) self.array_props.get(@intFromPtr(v.asArray())) else null;
    for (keys) |k| {
        if (v.isArray() and zarray.CanonicalNumericIndexString(k) != null) {
            if (arr_bag_opt == null or !arr_bag_opt.?.asObject().value.hasOwnProperty(k)) continue;
        }
        var d = property_desc.ParsedDesc{ .has_configurable = true, .configurable = false };
        if (!try property_desc.defineOwnProperty(self, v, k, &d)) {
            return self.throwError(.type_error, "Cannot seal property: {s}", .{property_desc.displayKey(k)});
        }
    }
    if (!v.isProxy()) {
        if (try extensibilityBagForWrite(self, v)) |bag| bag.asObject().value.seal();
    }
    return v.retain();
}

fn objectIsSealed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return testIntegrityLevel(ctx, allocator, arg(args, 0), false);
}

pub fn preventExtensionsInternal(self: *Interpreter, obj: JSValue) anyerror!bool {
    if (obj.isProxy()) {
        const box = obj.asProxy();
        if (try self.proxyTrap(box, "preventExtensions")) |trap_fn| {
            defer trap_fn.deinit();
            const res = try trap_fn.asFunction().value.call(trap_fn.asFunction().value.ctx, self.gc_allocator, box.value.handler, &.{box.value.target});
            defer res.deinit();
            const boolean_trap_result = coercion.isTruthy(res);
            if (boolean_trap_result) {
                if (try isExtensibleInternal(self, box.value.target)) {
                    return self.throwError(.type_error, "'preventExtensions' on proxy: trap returned truish but the proxy target is extensible", .{});
                }
            }
            return boolean_trap_result;
        }
        return preventExtensionsInternal(self, box.value.target);
    }
    if (try extensibilityBagForWrite(self, obj)) |bag| bag.asObject().value.preventExtensions();
    return true;
}

pub fn isExtensibleInternal(self: *Interpreter, obj: JSValue) anyerror!bool {
    if (obj.isProxy()) {
        const box = obj.asProxy();
        if (try self.proxyTrap(box, "isExtensible")) |trap_fn| {
            defer trap_fn.deinit();
            const res = try trap_fn.asFunction().value.call(trap_fn.asFunction().value.ctx, self.gc_allocator, box.value.handler, &.{box.value.target});
            defer res.deinit();
            const boolean_trap_result = coercion.isTruthy(res);
            const target_result = try isExtensibleInternal(self, box.value.target);
            if (boolean_trap_result != target_result) {
                return self.throwError(.type_error, "'isExtensible' on proxy: trap result does not reflect extensibility of proxy target", .{});
            }
            return boolean_trap_result;
        }
        return isExtensibleInternal(self, box.value.target);
    }
    if (!builtin_helpers.isObjectLike(obj)) return false;
    if (extensibilityBag(self, obj)) |bag| return bag.asObject().value.is_extensible;
    return true;
}

fn objectPreventExtensions(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (!builtin_helpers.isObjectLike(v)) return v.retain();
    if (!try preventExtensionsInternal(self, v)) {
        return self.throwError(.type_error, "Cannot prevent extensions", .{});
    }
    return v.retain();
}

fn objectIsExtensible(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    return JSValue.fromBool(try isExtensibleInternal(self, arg(args, 0)));
}

pub fn setPrototypeOfInternal(self: *Interpreter, obj: JSValue, proto: JSValue) anyerror!bool {
    if (self.protos.object.isObject() and zvalue.equality.strictEquals(obj, self.protos.object)) {
        return proto.isNull();
    }
    if (obj.isProxy()) {
        const box = obj.asProxy();
        if (try self.proxyTrap(box, "setPrototypeOf")) |trap_fn| {
            defer trap_fn.deinit();
            const result = try trap_fn.asFunction().value.call(trap_fn.asFunction().value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, proto });
            defer result.deinit();
            if (!coercion.isTruthy(result)) return false;
            const ext = try objectIsExtensible(self, self.gc_allocator, JSValue.UNDEFINED, &.{box.value.target});
            if (!coercion.isTruthy(ext)) {
                const target_proto = try objectGetPrototypeOf(self, self.gc_allocator, JSValue.UNDEFINED, &.{box.value.target});
                defer target_proto.deinit();
                if (!zvalue.equality.strictEquals(proto, target_proto)) {
                    return self.throwError(.type_error, "'setPrototypeOf' on proxy: proxy target is not extensible and prototype does not match", .{});
                }
            }
            return true;
        }
        return setPrototypeOfInternal(self, box.value.target, proto);
    }
    if (!obj.isObject()) {
        const cur_proto = try objectGetPrototypeOf(self, self.gc_allocator, JSValue.UNDEFINED, &.{obj});
        defer cur_proto.deinit();
        if (zvalue.equality.strictEquals(proto, cur_proto)) return true;
        if (extensibilityBag(self, obj)) |bag| {
            if (!bag.asObject().value.is_extensible) return error.ObjectNotExtensible;
        }
    }
    try self.setOwnedPrototype(obj, proto);
    return true;
}

fn objectSetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    const proto = arg(args, 1);
    if (obj.isUndefined() or obj.isNull()) return self.throwError(.type_error, "Object.setPrototypeOf called on null or undefined", .{});
    if (!proto.isNull() and !builtin_helpers.isObjectLike(proto)) {
        return self.throwError(.type_error, "Object prototype may only be an Object or null", .{});
    }
    if (!builtin_helpers.isObjectLike(obj)) return obj.retain();
    const success = setPrototypeOfInternal(self, obj, proto) catch |err| switch (err) {
        error.PrototypeCycle, error.ObjectNotExtensible => false,
        else => return err,
    };
    if (!success) {
        return self.throwError(.type_error, "Object.setPrototypeOf: cannot set prototype", .{});
    }
    return obj.retain();
}

pub fn ownPropertyKeyList(self: *Interpreter, allocator: Allocator, v: JSValue) anyerror![][]const u8 {
    if (v.isProxy()) {
        const all_keys = try proxyOwnPropertyKeys(self, allocator, v);
        defer all_keys.deinit();
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |k| allocator.free(k);
            out.deinit(allocator);
        }
        for (all_keys.asArray().value.toSlice()) |k| try out.append(allocator, try self.encodeKey(k));
        return out.toOwnedSlice(allocator);
    }
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |k| allocator.free(k);
        out.deinit(allocator);
    }
    const names = try objectGetOwnPropertyNames(self, allocator, JSValue.UNDEFINED, &.{v});
    defer names.deinit();
    for (names.asArray().value.toSlice()) |n| try out.append(allocator, try self.encodeKey(n));
    const syms = try objectGetOwnPropertySymbols(self, allocator, JSValue.UNDEFINED, &.{v});
    defer syms.deinit();
    for (syms.asArray().value.toSlice()) |s| try out.append(allocator, try self.encodeKey(s));
    return out.toOwnedSlice(allocator);
}

pub fn ownPropertyEnumerable(self: *Interpreter, v: JSValue, key: []const u8) anyerror!?bool {
    if (v.isObject() and !isGlobalObject(self, v)) {
        const rec = v.asObject().value.getOwnRecord(key) orelse return null;
        return rec.descriptor.enumerable;
    }
    const kv = try property_desc.keyToValue(self, key);
    defer kv.deinit();
    const desc = try objectGetOwnPropertyDescriptor(self, self.gc_allocator, JSValue.UNDEFINED, &.{ v, kv });
    defer desc.deinit();
    if (desc.isUndefined()) return null;
    const e = try self.getProperty(desc, "enumerable");
    defer e.deinit();
    return coercion.isTruthy(e);
}

/// Object.is(a, b) -- SameValue: like `===` but NaN equals NaN and +0 differs
/// from -0.
fn objectIs(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNumber();
        const y = b.asNumber();
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
    if (o.isUndefined() or o.isNull()) return interp(ctx).throwError(.type_error, "Cannot convert undefined or null to object", .{});
    return objHasOwnProperty(ctx, allocator, o, if (args.len > 1) args[1..] else &.{});
}

fn objDefineAccessor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue, is_setter: bool) anyerror!JSValue {
    const self = interp(ctx);
    const obj = try property_desc.toObject(self, this_value);
    defer obj.deinit();
    const fn_val = arg(args, 1);
    if (!fn_val.isFunction()) {
        return self.throwError(.type_error, "Object.prototype.__define{s}__: Expecting function", .{if (is_setter) "Setter" else "Getter"});
    }
    const key = try self.encodeKey(arg(args, 0));
    defer allocator.free(key);
    var d = property_desc.ParsedDesc{
        .has_get = !is_setter,
        .get = if (!is_setter) fn_val else JSValue.UNDEFINED,
        .has_set = is_setter,
        .set = if (is_setter) fn_val else JSValue.UNDEFINED,
        .has_enumerable = true,
        .enumerable = true,
        .has_configurable = true,
        .configurable = true,
    };
    if (!try property_desc.defineOwnProperty(self, obj, key, &d)) {
        return self.throwError(.type_error, "Cannot redefine property: {s}", .{property_desc.displayKey(key)});
    }
    return JSValue.UNDEFINED;
}

fn objDefineGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    return objDefineAccessor(ctx, allocator, this_value, args, false);
}

fn objDefineSetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    return objDefineAccessor(ctx, allocator, this_value, args, true);
}

fn objLookupAccessor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue, field: []const u8) anyerror!JSValue {
    const self = interp(ctx);
    var cur = try property_desc.toObject(self, this_value);
    defer cur.deinit();
    const key_val = arg(args, 0);
    // ToPropertyKey(P) once upfront per spec
    const key_str = try self.encodeKey(key_val);
    allocator.free(key_str);
    while (true) {
        const desc = try objectGetOwnPropertyDescriptor(ctx, allocator, JSValue.UNDEFINED, &.{ cur, key_val });
        defer desc.deinit();
        if (desc.isObject()) {
            if (desc.asObject().value.getOwn(field)) |f| return f.retain();
            return JSValue.UNDEFINED;
        }
        const next = try objectGetPrototypeOf(ctx, allocator, JSValue.UNDEFINED, &.{cur});
        if (next.isNull() or next.isUndefined()) {
            next.deinit();
            return JSValue.UNDEFINED;
        }
        cur.deinit();
        cur = next;
    }
}

fn objLookupGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    return objLookupAccessor(ctx, allocator, this_value, args, "get");
}

fn objLookupSetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    return objLookupAccessor(ctx, allocator, this_value, args, "set");
}

/// Object.fromEntries(iterable) -- builds an object from [key, value] pairs.
fn objectFromEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const src = arg(args, 0);
    if (src.isUndefined() or src.isNull()) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    const binding = @import("interpreter_binding.zig");
    var result = try self.ordinaryObject();
    errdefer result.deinit();
    if (src.isArray()) {
        for (src.asArray().value.toSlice()) |pair| {
            if (!builtin_helpers.isObjectLike(pair)) return self.throwError(.type_error, "Iterator value is not an entry object", .{});
            const k = try self.getProperty(pair, "0");
            defer k.deinit();
            const v = try self.getProperty(pair, "1");
            defer v.deinit();
            const ks = try self.encodeKey(k);
            defer self.gc_allocator.free(ks);
            try result.objectSet(ks, v.retain());
        }
        return result;
    }
    if (src.isMap()) {
        const ks = src.asMap().value.keys();
        const vs = src.asMap().value.values();
        for (ks, vs) |k, v| {
            const kstr = try self.encodeKey(k);
            defer self.gc_allocator.free(kstr);
            try result.objectSet(kstr, v.retain());
        }
        return result;
    }
    if (!builtin_helpers.isObjectLike(src)) return self.throwError(.type_error, "Object.fromEntries requires an iterable of entries", .{});
    const iter = try binding.resolveIterator(self, src);
    defer iter.deinit();
    while (true) {
        const next_fn = try self.getProperty(iter, "next");
        defer next_fn.deinit();
        const step = try self.callValue(next_fn, iter, &.{}, "next");
        defer step.deinit();
        if (!builtin_helpers.isObjectLike(step)) return self.throwError(.type_error, "Iterator result is not an object", .{});
        const done = try self.getProperty(step, "done");
        defer done.deinit();
        if (coercion.isTruthy(done)) break;
        const pair = try self.getProperty(step, "value");
        defer pair.deinit();
        if (!builtin_helpers.isObjectLike(pair)) {
            _ = self.throwError(.type_error, "Iterator value is not an entry object", .{}) catch {};
            binding.closeIteratorOnThrow(self, iter);
            return error.JsThrow;
        }
        const k = self.getProperty(pair, "0") catch |err| {
            binding.closeIteratorOnThrow(self, iter);
            return err;
        };
        defer k.deinit();
        const v = self.getProperty(pair, "1") catch |err| {
            binding.closeIteratorOnThrow(self, iter);
            return err;
        };
        defer v.deinit();
        const ks = self.encodeKey(k) catch |err| {
            binding.closeIteratorOnThrow(self, iter);
            return err;
        };
        defer allocator.free(ks);
        try result.objectSet(ks, v.retain());
    }
    return result;
}

fn objectGroupBy(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const items = arg(args, 0);
    const cb = arg(args, 1);
    if (items.isUndefined() or items.isNull()) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    if (!cb.isFunction()) return self.throwError(.type_error, "Object.groupBy requires a callable callback", .{});
    const binding = @import("interpreter_binding.zig");
    var result = try self.gcNewObject(); // [[Prototype]] = null
    errdefer result.deinit();

    const addGroup = struct {
        fn go(s: *Interpreter, alloc: Allocator, res: *JSValue, cb_fn: JSValue, val: JSValue, k_idx: usize) anyerror!void {
            const key_val = try cb_fn.asFunction().value.call(cb_fn.asFunction().value.ctx, alloc, JSValue.UNDEFINED, &.{ val, JSValue.fromNumber(@floatFromInt(k_idx)) });
            defer key_val.deinit();
            const key = try s.encodeKey(key_val);
            defer s.gc_allocator.free(key);
            if (res.asObject().value.getOwn(key)) |existing| {
                _ = try existing.asArray().value.push(val.retain());
            } else {
                var arr = try s.gcNewArray();
                _ = try arr.asArray().value.push(val.retain());
                try res.asObject().value.defineProperty(key, arr, .{ .writable = true, .enumerable = true, .configurable = true });
            }
        }
    }.go;

    if (items.isArray()) {
        for (items.asArray().value.toSlice(), 0..) |val, k_idx| {
            try addGroup(self, allocator, &result, cb, val, k_idx);
        }
        return result;
    }
    if (items.isString()) {
        var it = std.unicode.Utf8Iterator{ .bytes = items.asString().value.data, .i = 0 };
        var k_idx: usize = 0;
        while (it.nextCodepointSlice()) |cp| : (k_idx += 1) {
            const s = try self.gcNewString(cp);
            defer s.deinit();
            try addGroup(self, allocator, &result, cb, s, k_idx);
        }
        return result;
    }
    if (items.isSet()) {
        for (items.asSet().value.values(), 0..) |val, k_idx| {
            try addGroup(self, allocator, &result, cb, val, k_idx);
        }
        return result;
    }
    if (items.isObject()) {
        const iter = try binding.resolveIterator(self, items);
        defer iter.deinit();
        var k_idx: usize = 0;
        while (true) : (k_idx += 1) {
            const next_fn = try self.getProperty(iter, "next");
            defer next_fn.deinit();
            const step = try self.callValue(next_fn, iter, &.{}, "next");
            defer step.deinit();
            if (!builtin_helpers.isObjectLike(step)) return self.throwError(.type_error, "Iterator result is not an object", .{});
            const done = try self.getProperty(step, "done");
            defer done.deinit();
            if (coercion.isTruthy(done)) break;
            const val = try self.getProperty(step, "value");
            defer val.deinit();
            addGroup(self, allocator, &result, cb, val, k_idx) catch |err| {
                binding.closeIterator(self, iter) catch {};
                return err;
            };
        }
        return result;
    }
    return self.throwError(.type_error, "{s} is not iterable", .{items.typeOf()});
}

pub fn objectGetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (obj.isUndefined() or obj.isNull()) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    if (Interpreter.heapBoxAddress(obj)) |addr| if (self.proto_refs.get(addr)) |p| return p.retain();
    return switch (obj.unpack()) {
        .object => blk: {
            const p = obj.asObject().value.getPrototype() orelse break :blk JSValue.NULL;
            // Recover the owning Rc box from the raw *ZObject the chain
            // stores (it always points at a box's `value` field).
            const Box = @TypeOf(obj.asObject().*);
            const box: *Box = @fieldParentPtr("value", p);
            break :blk (JSValue.fromObject(box)).retain();
        },
        .array => |box| if (self.arguments_arrays.contains(@intFromPtr(box))) self.protos.object.retain() else self.protos.array.retain(),
        .string => self.protos.string.retain(),
        .number => self.protos.number.retain(),
        .boolean => self.protos.boolean.retain(),
        .function => |box| blk: {
            const iclass = @import("interpreter_class.zig");
            if (box.value.call == iclass.classConstructorCall) {
                const cctx: *interpreter_mod.ClassCtx = @ptrCast(@alignCast(box.value.ctx));
                if (cctx.super_ctor) |sc| break :blk sc.retain();
            }
            if (@import("error_builtins.zig").isErrorSubclassConstructor(box.value.call)) {
                if (self.global_env.get("Error")) |ector| break :blk ector.retain();
            }
            if (function_builtins.isFunctionSubclassConstructor(box.value.call)) {
                if (self.global_env.get("Function")) |fctor| break :blk fctor.retain();
            }
            if (box.value.call == iclass.closureCall) {
                const cctx: *interpreter_mod.ClosureCtx = @ptrCast(@alignCast(box.value.ctx));
                if (cctx.function_node.is_generator and cctx.function_node.is_async and self.protos.async_generator_function_proto.isObject()) {
                    break :blk self.protos.async_generator_function_proto.retain();
                }
                if (cctx.function_node.is_generator and !cctx.function_node.is_async and self.protos.generator_function_proto.isObject()) {
                    break :blk self.protos.generator_function_proto.retain();
                }
                if (!cctx.function_node.is_generator and cctx.function_node.is_async and self.protos.async_function_proto.isObject()) {
                    break :blk self.protos.async_function_proto.retain();
                }
            }
            break :blk self.protos.function.retain();
        },
        .date => self.protos.date.retain(),
        .regex => self.protos.regex.retain(),
        .@"error" => blk: {
            const kind_name = obj.asError().value.kind.name();
            if (!std.mem.eql(u8, kind_name, "Error")) {
                if (self.global_env.get(kind_name)) |ctor| {
                    if (self.functionPrototype(ctor)) |ep| break :blk ep.retain() else |_| {}
                }
            }
            break :blk self.protos.@"error".retain();
        },
        .map => self.protos.map.retain(),
        .set => self.protos.set.retain(),
        .symbol => self.protos.symbol.retain(),
        .promise => self.protos.promise.retain(),
        .bigint => self.protos.bigint.retain(),
        .array_buffer => |box| self.arrayBufferProto(box.value.is_shared).retain(),
        .data_view => self.protos.data_view.retain(),
        .typed_array => |box| self.typedArrayProto(box.value.kind).retain(),
        .temporal => self.temporalPrototype(obj).retain(),
        .proxy => |box| blk: {
            if (try self.proxyTrap(box, "getPrototypeOf")) |trap_fn| {
                defer trap_fn.deinit();
                const handler_proto = try trap_fn.asFunction().value.call(trap_fn.asFunction().value.ctx, allocator, box.value.handler, &.{box.value.target});
                errdefer handler_proto.deinit();
                if (!builtin_helpers.isObjectLike(handler_proto) and !handler_proto.isNull()) {
                    return self.throwError(.type_error, "'getPrototypeOf' on proxy: trap returned neither object nor null", .{});
                }
                if (!try isExtensibleInternal(self, box.value.target)) {
                    const target_proto = try objectGetPrototypeOf(ctx, allocator, this_value, &.{box.value.target});
                    defer target_proto.deinit();
                    if (!zvalue.equality.strictEquals(handler_proto, target_proto)) {
                        return self.throwError(.type_error, "'getPrototypeOf' on proxy: proxy target is not extensible and trap did not return its actual prototype", .{});
                    }
                }
                break :blk handler_proto;
            }
            break :blk objectGetPrototypeOf(ctx, allocator, this_value, &.{box.value.target});
        },
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
        .{ "keys", 1, objectKeys },                                           .{ "values", 1, objectValues },
        .{ "entries", 1, objectEntries },                                     .{ "assign", 2, objectAssign },
        .{ "defineProperty", 3, objectDefineProperty },                       .{ "defineProperties", 2, objectDefineProperties },
        .{ "getOwnPropertyDescriptors", 1, objectGetOwnPropertyDescriptors }, .{ "getOwnPropertyDescriptor", 2, objectGetOwnPropertyDescriptor },
        .{ "getOwnPropertyNames", 1, objectGetOwnPropertyNames },             .{ "getOwnPropertySymbols", 1, objectGetOwnPropertySymbols },
        .{ "create", 2, objectCreate },                                       .{ "freeze", 1, objectFreeze },
        .{ "isFrozen", 1, objectIsFrozen },                                   .{ "seal", 1, objectSeal },
        .{ "isSealed", 1, objectIsSealed },                                   .{ "preventExtensions", 1, objectPreventExtensions },
        .{ "isExtensible", 1, objectIsExtensible },                           .{ "setPrototypeOf", 2, objectSetPrototypeOf },
        .{ "getPrototypeOf", 1, objectGetPrototypeOf },                       .{ "is", 2, objectIs },
        .{ "hasOwn", 2, objectHasOwn },                                       .{ "fromEntries", 1, objectFromEntries },
        .{ "groupBy", 2, objectGroupBy },
    }) |entry| {
        try dneMethod(object_statics, entry[0], try native(self, entry[0], entry[1], entry[2]));
    }
    self.protos.object = try self.functionPrototype(object_ctor);
    try g.define(arena, "Object", object_ctor);
}

fn objectGetOwnPropertyDescriptors(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const value = arg(args, 0);
    if (value.isNull() or value.isUndefined()) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    const result = try self.ordinaryObject();
    errdefer result.deinit();
    const keys = try ownPropertyKeyList(self, allocator, value);
    defer freeOwnedKeys(allocator, keys);
    for (keys) |key| {
        const key_value = try property_desc.keyToValue(self, key);
        defer key_value.deinit();
        const desc = try objectGetOwnPropertyDescriptor(ctx, allocator, this_value, &.{ value, key_value });
        if (desc.isUndefined()) continue;
        try result.asObject().value.set(key, desc);
    }
    return result;
}
