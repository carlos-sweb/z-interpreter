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
    const self = interp(ctx);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |k| allocator.free(k);
        owned.deinit(allocator);
    }
    // `globalThis`: top-level var/function names (always enumerable) and
    // any ad-hoc-added global (enumerable, unlike an original builtin --
    // see global_builtin_names' doc comment) aren't in the object's own
    // bag, same gap as getOwnPropertyDescriptor/getOwnPropertyNames above.
    if (v == .object and isGlobalObject(self, v)) {
        if (self.global_var_env) |gve| {
            for (gve.bindings.items) |binding| {
                if (seen.contains(binding.name)) continue;
                try seen.put(allocator, binding.name, {});
                try owned.append(allocator, try allocator.dupe(u8, binding.name));
            }
        }
        for (self.global_env.bindings.items) |binding| {
            if (self.global_builtin_names.contains(binding.name)) continue;
            if (seen.contains(binding.name)) continue;
            try seen.put(allocator, binding.name, {});
            try owned.append(allocator, try allocator.dupe(u8, binding.name));
        }
    }
    const borrowed: [][]const u8 = switch (v) {
        .object => |box| try box.value.keys(allocator),
        .temporal => if (self.temporalProps(v)) |bag| try bag.object.value.keys(allocator) else try allocator.alloc([]const u8, 0),
        .function => |box| if (box.value.statics) |bag| try bag.object.value.keys(allocator) else try allocator.alloc([]const u8, 0),
        .undefined, .null => return interp(ctx).throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        // Neither had a case here at all (fell to the `else` empty-array
        // branch below) -- Object.keys/values/entries on a plain array
        // or string always returned []. Every index up to `.length` is
        // enumerable (own, no notion of holes in this engine's array/
        // string model). String length/index count is UTF-16 code
        // units, not UTF-8 bytes -- same fix as getProperty's `.string`
        // case (interpreter_props.zig). Both build their own fully-owned
        // result and return directly (bypassing the generic borrowed/
        // owned dedup below, exactly like `.proxy` already does) since
        // every string here is freshly allocated, not borrowed from
        // existing storage like `.object`/`.function`'s `.keys()` calls.
        .array => |box| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(allocator);
            var i: usize = 0;
            while (i < box.value.length()) : (i += 1) {
                try keys.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{i}));
            }
            return keys.toOwnedSlice(allocator);
        },
        .string => |box| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(allocator);
            var i: usize = 0;
            while (i < zstring.utf16.lengthUtf16(box.value.data)) : (i += 1) {
                try keys.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{i}));
            }
            return keys.toOwnedSlice(allocator);
        },
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
    for (borrowed) |k| {
        if (seen.contains(k)) continue;
        try owned.append(allocator, try allocator.dupe(u8, k));
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
    const self = interp(ctx);
    const target = try property_desc.toObject(self, arg(args, 0));
    for (args[1..]) |source| {
        if (source == .undefined or source == .null) continue;
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
    const self = interp(ctx);
    const key = try self.encodeKey(arg(args, 0));
    defer allocator.free(key);
    return switch (this_value) {
        .object => |box| blk: {
            if (self.global_object) |go| {
                if (this_value.object == go.object) {
                    break :blk JSValue.fromBool(self.global_var_names.contains(key) or self.global_env.declaresLocally(key) or box.value.hasOwnProperty(key));
                }
            }
            break :blk JSValue.fromBool(box.value.hasOwnProperty(key));
        },
        .function => |box| blk: {
            const deleted = self.deletedFnProps(this_value);
            if (box.value.statics) |bag| {
                if (bag.object.value.hasOwnProperty(key)) break :blk JSValue.fromBool(true);
            }
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(!deleted.length);
            if (std.mem.eql(u8, key, "name")) break :blk JSValue.fromBool(!deleted.name);
            if (std.mem.eql(u8, key, "prototype")) break :blk JSValue.fromBool(!isProxyConstructor(self, this_value) and function_builtins.boundContext(this_value) == null and (box.value.prototype != null or box.value.constructable));
            break :blk JSValue.fromBool(false);
        },
        .array => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(true);
            if (self.array_props.get(@intFromPtr(box))) |bag| {
                if (bag.object.value.hasOwnProperty(key)) break :blk JSValue.fromBool(true);
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
            (if (self.regexProps(this_value)) |bag| bag.object.value.hasOwnProperty(key) else false)),
        .temporal => JSValue.fromBool(if (self.temporalProps(this_value)) |bag| bag.object.value.hasOwnProperty(key) else false),
        else => JSValue.fromBool(if (self.extraProps(this_value)) |bag| bag.object.value.hasOwnProperty(key) else false),
    };
}

fn objPropertyIsEnumerable(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const key = try self.encodeKey(arg(args, 0));
    defer allocator.free(key);
    switch (this_value) {
        .object => return JSValue.fromBool(this_value.object.value.propertyIsEnumerable(key)),
        .temporal => return JSValue.fromBool(if (self.temporalProps(this_value)) |bag| bag.object.value.propertyIsEnumerable(key) else false),
        .array => |box| {
            if (std.mem.eql(u8, key, "length")) return JSValue.fromBool(false);
            if (self.array_props.get(@intFromPtr(box))) |bag| {
                if (bag.object.value.getOwnRecord(key)) |rec| return JSValue.fromBool(rec.descriptor.enumerable);
            }
            const idx = zarray.CanonicalNumericIndexString(key) orelse return JSValue.fromBool(false);
            return JSValue.fromBool(idx < box.value.length() and !box.value.isHole(idx));
        },
        else => return JSValue.fromBool(if (self.extraProps(this_value)) |bag| bag.object.value.propertyIsEnumerable(key) else false),
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
pub fn objToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    var owned_tag = JSValue.UNDEFINED;
    defer owned_tag.deinit();
    const tag: []const u8 = switch (this_value) {
        .undefined => "Undefined",
        .null => "Null",
        .array => "Array",
        .function => "Function",
        .@"error" => "Error",
        .date => "Date",
        .regex => "RegExp",
        // Real spec gets these via the generic `@@toStringTag` fallback
        // (Map.prototype/Set.prototype/Promise.prototype's own
        // property, now installed -- see materializeProtos), not the
        // hardcoded internal-slot list Array/Function/Error/Date/
        // RegExp above -- narrowed to a hardcoded case here too rather
        // than a real property lookup, so overriding e.g.
        // `Map.prototype[Symbol.toStringTag]` wouldn't change this
        // specific result (confirmed against real Node this matches
        // for the untouched-prototype case, which is the only one
        // that mattered for what was actually failing).
        .map => "Map",
        .set => "Set",
        .promise => "Promise",
        // Unlike Map/Set/Promise above, test262 has real coverage of
        // deleting/overriding Symbol.prototype/BigInt.prototype[Symbol.
        // toStringTag] and observing it here (symbol-tag-non-str-builtin
        // .js), so this can't be hardcoded -- it needs a real Get.
        // Neither type has a builtinTag entry in the spec's internal-
        // slot list, so the fallback (no tag installed, or a non-string
        // tag) is "Object", not "Symbol"/"BigInt".
        // ArrayBuffer.prototype/SharedArrayBuffer.prototype[Symbol.
        // toStringTag] are real own accessor properties too (spec
        // 25.1.5.4 / 25.2.5.6) -- same dynamic-Get fallback as
        // .symbol/.bigint/.object below, so it naturally distinguishes
        // the two via whichever prototype `arrayBufferProto` dispatched
        // this value's [[Prototype]] to (materializeProtos installs a
        // different string on each).
        .array_buffer, .symbol, .bigint, .temporal => blk: {
            if (self.symbol_to_string_tag) |tag_sym| {
                const tag_key = try self.encodeKey(tag_sym);
                defer self.gc_allocator.free(tag_key);
                owned_tag = try self.getProperty(this_value, tag_key);
                if (owned_tag == .string) break :blk owned_tag.string.value.data;
            }
            break :blk "Object";
        },
        .object => blk: {
            if (self.unboxPrimitiveWrapper(this_value)) |prim| {
                break :blk switch (prim) {
                    .number => "Number",
                    .string => "String",
                    .boolean => "Boolean",
                    else => "Object",
                };
            }
            // A plain object (Math, JSON, or any object with its own
            // [Symbol.toStringTag]) has no internal-slot builtinTag
            // entry, so real spec falls straight to a dynamic Get here
            // -- same mechanism as the .symbol/.bigint case above.
            if (self.symbol_to_string_tag) |tag_sym| {
                const tag_key = try self.encodeKey(tag_sym);
                defer self.gc_allocator.free(tag_key);
                owned_tag = try self.getProperty(this_value, tag_key);
                if (owned_tag == .string) break :blk owned_tag.string.value.data;
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

pub fn objectConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
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
    obj.object.value.defineProperty(key, value, descriptor) catch |err| return switch (err) {
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
    return obj == .object and obj.object == go.object;
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
    if (self.global_var_names.contains(key)) {
        const env = self.global_var_env orelse self.global_env;
        if (env.getLocalBinding(key)) |v| return try dataDescObj(self, v.retain(), true, true, false);
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
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    switch (obj) {
        .object => {
            if (isGlobalObject(self, obj)) {
                if (try globalPropertyDescriptor(self, key)) |d| return d;
            }
            const rec = obj.object.value.getOwnRecord(key) orelse return JSValue.UNDEFINED;
            return descFromRecord(self, rec);
        },
        .function => |box| {
            const deleted = self.deletedFnProps(obj);
            if (box.value.statics) |bag| {
                if (bag.object.value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            if (std.mem.eql(u8, key, "length"))
                return if (deleted.length) JSValue.UNDEFINED else dataDescObj(self, JSValue.fromNumber(@floatFromInt(box.value.arity)), false, false, true);
            if (std.mem.eql(u8, key, "name"))
                return if (deleted.name) JSValue.UNDEFINED else dataDescObj(self, try interp(ctx).gcNewString(box.value.name), false, false, true);
            if (std.mem.eql(u8, key, "prototype")) {
                if (!isProxyConstructor(self, obj) and function_builtins.boundContext(obj) == null and (box.value.prototype != null or box.value.constructable))
                    return dataDescObj(self, (try self.functionPrototype(obj)).retain(), !temporal_builtins.isIntrinsicConstructor(obj), false, false);
            }
            return JSValue.UNDEFINED;
        },
        .array => |box| {
            if (std.mem.eql(u8, key, "length"))
                return dataDescObj(self, JSValue.fromNumber(@floatFromInt(box.value.length())), box.value.isLengthWritable(), false, false);
            const bag_opt = self.array_props.get(@intFromPtr(box));
            if (bag_opt) |bag| {
                if (bag.object.value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            const idx = zarray.CanonicalNumericIndexString(key) orelse return JSValue.UNDEFINED;
            if (idx >= box.value.length() or box.value.isHole(idx)) return JSValue.UNDEFINED;
            const val = box.value.getOpt(idx) orelse return JSValue.UNDEFINED;
            const is_frozen = if (bag_opt) |b| b.object.value.is_frozen else false;
            const is_sealed = if (bag_opt) |b| b.object.value.is_sealed else false;
            return dataDescObj(self, val.retain(), !is_frozen, true, !(is_frozen or is_sealed));
        },
        .typed_array => |box| {
            const idx = zarray.CanonicalNumericIndexString(key) orelse {
                if (self.extraProps(obj)) |bag| {
                    if (bag.object.value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
                }
                return JSValue.UNDEFINED;
            };
            if (idx >= box.value.len) return JSValue.UNDEFINED;
            const val = try builtin_helpers.typedElemGet(self, box.value.kind, &box.value.owner.array_buffer.value, box.value.byte_offset, box.value.len, idx);
            return dataDescObj(self, val, true, true, false);
        },
        .undefined, .null => return self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        .proxy => |box| {
            if (try self.proxyTrap(box, "getOwnPropertyDescriptor")) |trap_fn| {
                defer trap_fn.deinit();
                const key_val = try property_desc.keyToValue(self, key);
                defer key_val.deinit();
                return try trap_fn.function.value.call(trap_fn.function.value.ctx, allocator, box.value.handler, &.{ box.value.target, key_val });
            }
            return objectGetOwnPropertyDescriptor(ctx, allocator, this_value, &.{ box.value.target, arg(args, 1) });
        },
        .regex => {
            if (std.mem.eql(u8, key, "lastIndex"))
                return dataDescObj(self, self.regexState(obj).last_index.retain(), self.regexState(obj).last_index_writable, false, false);
            if (self.regexProps(obj)) |bag| {
                if (bag.object.value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            return JSValue.UNDEFINED;
        },
        .temporal => {
            if (self.temporalProps(obj)) |bag| {
                if (bag.object.value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            return JSValue.UNDEFINED;
        },
        else => {
            if (self.extraProps(obj)) |bag| {
                if (bag.object.value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            return JSValue.UNDEFINED;
        },
    }
}

pub fn proxyOwnPropertyKeys(self: *Interpreter, allocator: Allocator, proxy_val: JSValue) anyerror!JSValue {
    const box = proxy_val.proxy;
    const trap_fn = (try self.proxyTrap(box, "ownKeys")) orelse {
        const names = try objectGetOwnPropertyNames(self, allocator, JSValue.UNDEFINED, &.{box.value.target});
        const syms = try objectGetOwnPropertySymbols(self, allocator, JSValue.UNDEFINED, &.{box.value.target});
        defer syms.deinit();
        for (syms.array.value.toSlice()) |s| _ = try names.array.value.push(s.retain());
        return names;
    };
    defer trap_fn.deinit();
    const trap_result = try trap_fn.function.value.call(trap_fn.function.value.ctx, allocator, box.value.handler, &.{box.value.target});
    defer trap_result.deinit();
    if (trap_result != .array) {
        return self.throwError(.type_error, "'ownKeys' on proxy: trap must return an array", .{});
    }
    const items = trap_result.array.value.toSlice();
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit(allocator);
    }
    for (items) |item| {
        if (item != .string and item != .symbol) {
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
    const is_extensible = if (extensibilityBag(self, target)) |bag| bag.object.value.is_extensible else (target == .array or target == .function or target == .temporal);
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
        const is_non_configurable = if (desc == .object)
            if (desc.object.value.get("configurable")) |c| !coercion.isTruthy(c) else false
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

    return trap_result.retain();
}

pub fn objectGetOwnPropertyNames(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const o = arg(args, 0);
    var result = try interp(ctx).gcNewArray();
    switch (o) {
        .object => {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(allocator);
            if (isGlobalObject(self, o)) {
                for (self.global_env.bindings.items) |binding| {
                    if (seen.contains(binding.name)) continue;
                    try seen.put(allocator, binding.name, {});
                    _ = try result.array.value.push(try interp(ctx).gcNewString(binding.name));
                }
                if (self.global_var_env) |gve| {
                    for (gve.bindings.items) |binding| {
                        if (seen.contains(binding.name)) continue;
                        try seen.put(allocator, binding.name, {});
                        _ = try result.array.value.push(try interp(ctx).gcNewString(binding.name));
                    }
                }
            }
            const names = try o.object.value.getOwnPropertyNames(allocator);
            defer allocator.free(names);
            for (names) |n| {
                if (isSymbolKey(n)) continue;
                if (seen.contains(n)) continue;
                _ = try result.array.value.push(try interp(ctx).gcNewString(n));
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
                    _ = try result.array.value.push(try interp(ctx).gcNewString(idx_str));
                }
            } else {
                var i: usize = 0;
                while (i < box.value.length()) : (i += 1) {
                    if (box.value.isHole(i)) continue;
                    const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{i});
                    defer allocator.free(idx_str);
                    _ = try result.array.value.push(try interp(ctx).gcNewString(idx_str));
                }
            }
            _ = try result.array.value.push(try interp(ctx).gcNewString("length"));
            if (self.array_props.get(@intFromPtr(box))) |bag| {
                const names = try bag.object.value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |n| {
                    if (isSymbolKey(n) or std.mem.eql(u8, n, "length") or zarray.CanonicalNumericIndexString(n) != null) continue;
                    _ = try result.array.value.push(try interp(ctx).gcNewString(n));
                }
            }
        },
        .function => |box| {
            _ = try result.array.value.push(try interp(ctx).gcNewString("length"));
            _ = try result.array.value.push(try interp(ctx).gcNewString("name"));
            if (!isProxyConstructor(self, o) and function_builtins.boundContext(o) == null and (box.value.prototype != null or box.value.constructable))
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
        .temporal => {
            if (self.temporalProps(o)) |bag| {
                const names = try bag.object.value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |name| {
                    if (!isSymbolKey(name)) _ = try result.array.value.push(try self.gcNewString(name));
                }
            }
        },
        .undefined, .null => return self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        .proxy => {
            const all_keys = try proxyOwnPropertyKeys(self, allocator, o);
            defer all_keys.deinit();
            for (all_keys.array.value.toSlice()) |item| {
                if (item == .string) _ = try result.array.value.push(item.retain());
            }
        },
        else => {
            if (self.extraProps(o)) |bag| {
                const names = try bag.object.value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |n| {
                    if (!isSymbolKey(n)) _ = try result.array.value.push(try interp(ctx).gcNewString(n));
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
    if (o == .undefined or o == .null) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    var result = try interp(ctx).gcNewArray();
    if (o == .proxy) {
        const all_keys = try proxyOwnPropertyKeys(self, allocator, o);
        defer all_keys.deinit();
        for (all_keys.array.value.toSlice()) |item| {
            if (item == .symbol) _ = try result.array.value.push(item.retain());
        }
        return result;
    }
    const bag_opt: ?JSValue = switch (o) {
        .object => o,
        .temporal => self.temporalProps(o),
        .array => |box| self.array_props.get(@intFromPtr(box)),
        .function => |box| box.value.statics,
        else => self.extraProps(o),
    };
    if (bag_opt) |bag| {
        const names = try bag.object.value.getOwnPropertyNames(allocator);
        defer allocator.free(names);
        for (names) |n| {
            if (!isSymbolKey(n)) continue;
            if (self.symbol_keys.get(n)) |sym| _ = try result.array.value.push(sym.retain());
        }
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
    const obj = try interp(ctx).gcNewObject();
    if (proto == .object) try self.setOwnedPrototype(obj, proto);
    if (args.len >= 2 and args[1] != .undefined) {
        try property_desc.objectDefinePropertiesImpl(self, allocator, obj, args[1]);
    }
    return obj;
}

fn extensibilityBag(self: *Interpreter, v: JSValue) ?JSValue {
    return switch (v) {
        .object => v,
        .function => |box| box.value.statics,
        .array => |box| self.array_props.get(@intFromPtr(box)),
        .regex => self.regexProps(v),
        .temporal => self.temporalProps(v),
        else => self.extraProps(v),
    };
}

fn extensibilityBagForWrite(self: *Interpreter, v: JSValue) anyerror!?JSValue {
    return switch (v) {
        .object => v,
        .function => try self.functionStatics(v),
        .array => try self.arrayPropsObject(v),
        .regex => try self.regexPropsObject(v),
        .temporal => try self.temporalPropsObject(v),
        else => try self.extraPropsObject(v),
    };
}

fn objectFreeze(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (v == .array) {
        v.array.value.setLengthWritable(false) catch {};
    }
    if (try extensibilityBagForWrite(self, v)) |bag| bag.object.value.freeze();
    if (v == .regex) self.regexState(v).last_index_writable = false;
    return v.retain();
}

fn objectIsFrozen(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (v == .array) {
        if (v.array.value.isLengthWritable() and v.array.value.length() > 0) return JSValue.fromBool(false);
    }
    if (extensibilityBag(self, v)) |bag| return JSValue.fromBool(bag.object.value.is_frozen);
    return JSValue.fromBool(!(v == .array or v == .function or v == .temporal));
}

fn objectSeal(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (try extensibilityBagForWrite(self, v)) |bag| bag.object.value.seal();
    return v.retain();
}

fn objectIsSealed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (extensibilityBag(self, v)) |bag| return JSValue.fromBool(bag.object.value.is_sealed or bag.object.value.is_frozen);
    return JSValue.fromBool(!(v == .array or v == .function or v == .temporal));
}

fn objectPreventExtensions(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (try extensibilityBagForWrite(self, v)) |bag| bag.object.value.preventExtensions();
    return v.retain();
}

fn objectIsExtensible(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (extensibilityBag(self, v)) |bag| return JSValue.fromBool(bag.object.value.is_extensible);
    return JSValue.fromBool(v == .array or v == .function or v == .temporal);
}

fn objectSetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    const proto = arg(args, 1);
    if (!builtin_helpers.isObjectLike(obj)) return self.throwError(.type_error, "Object.setPrototypeOf called on non-object", .{});
    if (proto != .object and proto != .null) {
        return self.throwError(.type_error, "Object prototype may only be an Object or null", .{});
    }
    try self.setOwnedPrototype(obj, proto);
    return obj.retain();
}

pub fn ownPropertyKeyList(self: *Interpreter, allocator: Allocator, v: JSValue) anyerror![][]const u8 {
    if (v == .proxy) {
        const all_keys = try proxyOwnPropertyKeys(self, allocator, v);
        defer all_keys.deinit();
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |k| allocator.free(k);
            out.deinit(allocator);
        }
        for (all_keys.array.value.toSlice()) |k| try out.append(allocator, try self.encodeKey(k));
        return out.toOwnedSlice(allocator);
    }
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |k| allocator.free(k);
        out.deinit(allocator);
    }
    const names = try objectGetOwnPropertyNames(self, allocator, JSValue.UNDEFINED, &.{v});
    defer names.deinit();
    for (names.array.value.toSlice()) |n| try out.append(allocator, try self.encodeKey(n));
    const syms = try objectGetOwnPropertySymbols(self, allocator, JSValue.UNDEFINED, &.{v});
    defer syms.deinit();
    for (syms.array.value.toSlice()) |s| try out.append(allocator, try self.encodeKey(s));
    return out.toOwnedSlice(allocator);
}

pub fn ownPropertyEnumerable(self: *Interpreter, v: JSValue, key: []const u8) anyerror!?bool {
    if (v == .object and !isGlobalObject(self, v) and self.unboxPrimitiveWrapper(v) == null) {
        const rec = v.object.value.getOwnRecord(key) orelse return null;
        return rec.descriptor.enumerable;
    }
    const kv = try property_desc.keyToValue(self, key);
    defer kv.deinit();
    const desc = try objectGetOwnPropertyDescriptor(self, self.gc_allocator, JSValue.UNDEFINED, &.{ v, kv });
    defer desc.deinit();
    if (desc == .undefined) return null;
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
    _ = allocator;
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
        // Real spec: the entry's key goes through ToPropertyKey (a Symbol
        // pair-key stays a real symbol-keyed property), not plain ToString.
        const ks = try self.encodeKey(k);
        defer self.gc_allocator.free(ks);
        try result.objectSet(ks, v.retain());
    }
    return result;
}

pub fn objectGetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (obj == .undefined or obj == .null) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    if (Interpreter.heapBoxAddress(obj)) |addr| if (self.proto_refs.get(addr)) |p| return p.retain();
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
        .array_buffer => |box| self.arrayBufferProto(box.value.is_shared).retain(),
        .data_view => self.protos.data_view.retain(),
        .typed_array => |box| self.typedArrayProto(box.value.kind).retain(),
        .temporal => self.temporalPrototype(obj).retain(),
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
    }) |entry| {
        try dneMethod(object_statics, entry[0], try native(self, entry[0], entry[1], entry[2]));
    }
    self.protos.object = try self.functionPrototype(object_ctor);
    try g.define(arena, "Object", object_ctor);
}

fn objectGetOwnPropertyDescriptors(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const value = arg(args, 0);
    if (value == .null or value == .undefined) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    const result = try self.ordinaryObject();
    errdefer result.deinit();
    if (value == .string) {
        const length = try self.getProperty(value, "length");
        try result.object.value.set("length", try dataDescObj(self, length, false, false, false));
        const n: usize = @intFromFloat(length.number);
        for (0..n) |i| {
            const key = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(key);
            try result.object.value.set(key, try dataDescObj(self, try self.getProperty(value, key), false, true, false));
        }
        return result;
    }
    const names = try objectGetOwnPropertyNames(ctx, allocator, this_value, args);
    defer names.deinit();
    const bag: ?JSValue = switch (value) {
        .object => value,
        .function => |box| box.value.statics,
        .array => |box| self.array_props.get(@intFromPtr(box)),
        .regex => self.regexProps(value),
        .temporal => self.temporalProps(value),
        else => null,
    };
    if (bag) |props| {
        const keys = try props.object.value.getOwnPropertyNames(allocator);
        defer allocator.free(keys);
        for (keys) |key| {
            if (isSymbolKey(key)) {
                if (self.symbol_keys.get(key)) |symbol| _ = try names.array.value.push(symbol.retain());
            } else _ = try names.array.value.push(try self.gcNewString(key));
        }
    }
    for (names.array.value.toSlice()) |key_value| {
        const key = try self.encodeKey(key_value);
        defer allocator.free(key);
        if (result.object.value.hasOwnProperty(key)) continue;
        const desc = try objectGetOwnPropertyDescriptor(ctx, allocator, this_value, &.{ value, key_value });
        if (desc == .undefined) continue;
        try result.object.value.set(key, desc);
    }
    return result;
}
