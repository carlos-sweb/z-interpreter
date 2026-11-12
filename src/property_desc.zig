const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const zarray = @import("zarray");
const zstring = @import("zstring");
const Interpreter = @import("interpreter.zig").Interpreter;
const builtin_helpers = @import("builtin_helpers.zig");
const coercion = @import("coercion.zig");
const regex_builtins = @import("regex_builtins.zig");
const temporal_builtins = @import("temporal_builtins.zig");
const function_builtins = @import("function_builtins.zig");

// ===== Property descriptors (ECMA-262 6.2.6, 10.1.6.3, 10.4.2) =====

pub const ParsedDesc = struct {
    has_value: bool = false,
    value: JSValue = JSValue.UNDEFINED,
    has_writable: bool = false,
    writable: bool = false,
    has_get: bool = false,
    get: JSValue = JSValue.UNDEFINED,
    has_set: bool = false,
    set: JSValue = JSValue.UNDEFINED,
    has_enumerable: bool = false,
    enumerable: bool = false,
    has_configurable: bool = false,
    configurable: bool = false,

    pub fn isAccessor(d: *const ParsedDesc) bool {
        return d.has_get or d.has_set;
    }
    pub fn isData(d: *const ParsedDesc) bool {
        return d.has_value or d.has_writable;
    }
    pub fn isGeneric(d: *const ParsedDesc) bool {
        return !d.isAccessor() and !d.isData();
    }
    pub fn deinit(d: *const ParsedDesc) void {
        d.value.deinit();
        d.get.deinit();
        d.set.deinit();
    }
};

pub fn isCallable(v: JSValue) bool {
    return switch (v) {
        .function => true,
        .proxy => |box| isCallable(box.value.target),
        else => false,
    };
}

pub fn sameValue(a: JSValue, b: JSValue) bool {
    if (a == .number and b == .number) {
        const x = a.number;
        const y = b.number;
        if (std.math.isNan(x) and std.math.isNan(y)) return true;
        if (x == 0 and y == 0) return std.math.signbit(x) == std.math.signbit(y);
        return x == y;
    }
    return zvalue.equality.strictEquals(a, b);
}

fn isSymbolKey(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__symbol_");
}

fn displayKey(key: []const u8) []const u8 {
    return if (isSymbolKey(key)) "Symbol()" else key;
}

pub fn isProxyConstructor(self: *Interpreter, v: JSValue) bool {
    const proxy_ctor = self.global_env.get("Proxy") orelse return false;
    return zvalue.equality.strictEquals(v, proxy_ctor);
}

pub fn hasProperty(self: *Interpreter, v: JSValue, key: []const u8) anyerror!bool {
    switch (v) {
        .object => |box| {
            if (self.global_object) |go| {
                if (v.object == go.object) {
                    if (self.global_var_names.contains(key) or self.global_env.declaresLocally(key) or box.value.hasOwnProperty(key)) return true;
                }
            }
            return box.value.has(key);
        },
        .proxy => {
            const k = try self.gcNewString(key);
            defer k.deinit();
            const r = try self.evalIn(k, v);
            return coercion.isTruthy(r);
        },
        else => {},
    }
    var cur = v.retain();
    defer cur.deinit();
    while (true) {
        switch (cur) {
            .object => |box| {
                if (box.value.hasOwnProperty(key)) return true;
                const p = box.value.getPrototype() orelse return false;
                const Box = @TypeOf(box.*);
                const p_box: *Box = @fieldParentPtr("value", p);
                const next = (JSValue{ .object = p_box }).retain();
                cur.deinit();
                cur = next;
            },
            .array => |box| {
                if (std.mem.eql(u8, key, "length")) return true;
                if (zarray.CanonicalNumericIndexString(key)) |idx| {
                    if (idx < box.value.length() and !box.value.isHole(idx)) return true;
                }
                if (self.array_props.get(@intFromPtr(box))) |bag| {
                    if (bag.object.value.hasOwnProperty(key)) return true;
                }
                const next = self.protos.array.retain();
                cur.deinit();
                cur = next;
            },
            else => return false,
        }
    }
}

pub fn toPropertyDescriptor(self: *Interpreter, desc: JSValue) anyerror!ParsedDesc {
    if (!builtin_helpers.isObjectLike(desc)) return self.throwError(.type_error, "Property description must be an object", .{});
    var d: ParsedDesc = .{};
    errdefer d.deinit();
    if (try hasProperty(self, desc, "enumerable")) {
        d.has_enumerable = true;
        const v = try self.getProperty(desc, "enumerable");
        defer v.deinit();
        d.enumerable = coercion.isTruthy(v);
    }
    if (try hasProperty(self, desc, "configurable")) {
        d.has_configurable = true;
        const v = try self.getProperty(desc, "configurable");
        defer v.deinit();
        d.configurable = coercion.isTruthy(v);
    }
    if (try hasProperty(self, desc, "value")) {
        d.has_value = true;
        d.value = try self.getProperty(desc, "value");
    }
    if (try hasProperty(self, desc, "writable")) {
        d.has_writable = true;
        const v = try self.getProperty(desc, "writable");
        defer v.deinit();
        d.writable = coercion.isTruthy(v);
    }
    if (try hasProperty(self, desc, "get")) {
        d.has_get = true;
        d.get = try self.getProperty(desc, "get");
        if (d.get != .undefined and !isCallable(d.get)) return self.throwError(.type_error, "Getter must be a function", .{});
    }
    if (try hasProperty(self, desc, "set")) {
        d.has_set = true;
        d.set = try self.getProperty(desc, "set");
        if (d.set != .undefined and !isCallable(d.set)) return self.throwError(.type_error, "Setter must be a function", .{});
    }
    if (d.isAccessor() and d.isData()) {
        return self.throwError(.type_error, "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute", .{});
    }
    return d;
}

pub fn fromParsedDesc(self: *Interpreter, d: *const ParsedDesc) anyerror!JSValue {
    var out = try self.ordinaryObject();
    errdefer out.deinit();
    if (d.has_value) try out.object.value.set("value", d.value.retain());
    if (d.has_writable) try out.object.value.set("writable", JSValue.fromBool(d.writable));
    if (d.has_get) try out.object.value.set("get", d.get.retain());
    if (d.has_set) try out.object.value.set("set", d.set.retain());
    if (d.has_enumerable) try out.object.value.set("enumerable", JSValue.fromBool(d.enumerable));
    if (d.has_configurable) try out.object.value.set("configurable", JSValue.fromBool(d.configurable));
    return out;
}

pub fn validateAndApply(self: *Interpreter, obj: JSValue, key: []const u8, d: *const ParsedDesc) anyerror!bool {
    _ = self;
    const zo = &obj.object.value;
    const existing = zo.getOwnRecordMut(key) orelse {
        if (!zo.is_extensible) return false;
        if (d.isAccessor()) {
            const g: ?JSValue = if (d.has_get and d.get != .undefined) d.get.retain() else null;
            const s: ?JSValue = if (d.has_set and d.set != .undefined) d.set.retain() else null;
            zo.defineAccessor(key, g, s, JSValue.UNDEFINED) catch |err| {
                if (g) |x| x.deinit();
                if (s) |x| x.deinit();
                return err;
            };
            const rec = zo.getOwnRecordMut(key).?;
            rec.descriptor.writable = false;
            rec.descriptor.enumerable = d.has_enumerable and d.enumerable;
            rec.descriptor.configurable = d.has_configurable and d.configurable;
            return true;
        }
        const v = if (d.has_value) d.value.retain() else JSValue.UNDEFINED;
        zo.defineProperty(key, v, .{
            .writable = d.has_writable and d.writable,
            .enumerable = d.has_enumerable and d.enumerable,
            .configurable = d.has_configurable and d.configurable,
        }) catch |err| {
            v.deinit();
            return switch (err) {
                error.ObjectNotExtensible, error.PropertyNotConfigurable => false,
                else => err,
            };
        };
        return true;
    };
    const rec = existing;
    if (!rec.descriptor.configurable) {
        if (d.has_configurable and d.configurable) return false;
        if (d.has_enumerable and d.enumerable != rec.descriptor.enumerable) return false;
        if (!d.isGeneric() and d.isAccessor() != rec.isAccessor()) return false;
        if (rec.isAccessor()) {
            if (d.has_get and !sameValue(d.get, rec.getter orelse JSValue.UNDEFINED)) return false;
            if (d.has_set and !sameValue(d.set, rec.setter orelse JSValue.UNDEFINED)) return false;
        } else if (!rec.descriptor.writable) {
            if (d.has_writable and d.writable) return false;
            if (d.has_value and !sameValue(d.value, rec.value)) return false;
        }
    }
    // Kind conversion keeps enumerable/configurable, resets the rest.
    if (d.isAccessor() and !rec.isAccessor()) {
        const old = rec.value;
        rec.value = JSValue.UNDEFINED;
        old.deinit();
        rec.descriptor.is_accessor = true;
        rec.descriptor.writable = false;
    } else if (d.isData() and rec.isAccessor()) {
        const og = rec.getter;
        const os = rec.setter;
        rec.getter = null;
        rec.setter = null;
        if (og) |x| x.deinit();
        if (os) |x| x.deinit();
        rec.descriptor.is_accessor = false;
        rec.descriptor.writable = false;
        rec.value = JSValue.UNDEFINED;
    }
    if (d.has_value) {
        const old = rec.value;
        rec.value = d.value.retain();
        old.deinit();
    }
    if (d.has_writable) rec.descriptor.writable = d.writable;
    if (d.has_get) {
        const old = rec.getter;
        rec.getter = if (d.get != .undefined) d.get.retain() else null;
        if (old) |x| x.deinit();
    }
    if (d.has_set) {
        const old = rec.setter;
        rec.setter = if (d.set != .undefined) d.set.retain() else null;
        if (old) |x| x.deinit();
    }
    if (d.has_enumerable) rec.descriptor.enumerable = d.enumerable;
    if (d.has_configurable) rec.descriptor.configurable = d.configurable;
    return true;
}

fn virtualDataAllows(d: *const ParsedDesc, cur: JSValue, writable: bool, enumerable: bool, configurable: bool) bool {
    if (configurable) return !d.isAccessor() or true;
    if (d.has_configurable and d.configurable) return false;
    if (d.has_enumerable and d.enumerable != enumerable) return false;
    if (d.isAccessor()) return false;
    if (!writable) {
        if (d.has_writable and d.writable) return false;
        if (d.has_value and !sameValue(d.value, cur)) return false;
    }
    return true;
}

fn bagInsertRaw(bag: JSValue, key: []const u8, value: JSValue, desc: zvalue.PropertyDescriptor) !void {
    const zo = &bag.object.value;
    const saved = zo.is_extensible;
    zo.is_extensible = true;
    defer zo.is_extensible = saved;
    zo.defineProperty(key, value, desc) catch |err| {
        value.deinit();
        return err;
    };
}

pub fn materializeFnVirtual(self: *Interpreter, f: JSValue, key: []const u8) anyerror!void {
    const bag = try self.functionStatics(f);
    if (bag.object.value.hasOwnProperty(key)) return;
    const box = f.function;
    const deleted = self.deletedFnProps(f);
    const ro = zvalue.PropertyDescriptor{ .writable = false, .enumerable = false, .configurable = true };
    if (std.mem.eql(u8, key, "length")) {
        if (deleted.length) return;
        try bagInsertRaw(bag, key, JSValue.fromNumber(@floatFromInt(box.value.arity)), ro);
    } else if (std.mem.eql(u8, key, "name")) {
        if (deleted.name) return;
        try bagInsertRaw(bag, key, try self.gcNewString(box.value.name), ro);
    } else if (std.mem.eql(u8, key, "prototype")) {
        if (isProxyConstructor(self, f) or function_builtins.boundContext(f) != null or !(box.value.prototype != null or box.value.constructable)) return;
        const p = (try self.functionPrototype(f)).retain();
        try bagInsertRaw(bag, key, p, .{ .writable = !temporal_builtins.isIntrinsicConstructor(f), .enumerable = false, .configurable = false });
    }
}

pub fn syncFnPrototypeSlot(f: JSValue) void {
    const bag = f.function.value.statics orelse return;
    const rec = bag.object.value.getOwnRecord("prototype") orelse return;
    if (rec.isAccessor()) return;
    if (rec.value != .object) return;
    const old = f.function.value.prototype;
    f.function.value.prototype = rec.value.retain();
    if (old) |o| o.deinit();
}

pub fn defineOwnProperty(self: *Interpreter, obj: JSValue, key: []const u8, d: *const ParsedDesc) anyerror!bool {
    switch (obj) {
        .object => return validateAndApply(self, obj, key, d),
        .function => {
            if (std.mem.eql(u8, key, "prototype") and temporal_builtins.isIntrinsicConstructor(obj)) {
                const proto = try self.functionPrototype(obj);
                return virtualDataAllows(d, proto, false, false, false);
            }
            if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "length") or std.mem.eql(u8, key, "prototype"))
                try materializeFnVirtual(self, obj, key);
            const ok = try validateAndApply(self, try self.functionStatics(obj), key, d);
            if (ok and std.mem.eql(u8, key, "prototype")) syncFnPrototypeSlot(obj);
            return ok;
        },
        .array => return arrayDefineOwnProperty(self, obj, key, d),
        .temporal => return validateAndApply(self, try self.temporalPropsObject(obj), key, d),
        .regex => {
            if (std.mem.eql(u8, key, "lastIndex")) {
                const st = self.regexState(obj);
                if (!virtualDataAllows(d, st.last_index, st.last_index_writable, false, false)) return false;
                if (d.has_value) try regex_builtins.setLastIndex(self, obj, d.value.retain());
                if (d.has_writable) st.last_index_writable = d.writable;
                return true;
            }
            return validateAndApply(self, try self.regexPropsObject(obj), key, d);
        },
        .proxy => |box| {
            if (try self.proxyTrap(box, "defineProperty")) |trap_fn| {
                defer trap_fn.deinit();
                const key_val = try keyToValue(self, key);
                defer key_val.deinit();
                const desc_obj = try fromParsedDesc(self, d);
                defer desc_obj.deinit();
                const result = try trap_fn.function.value.call(trap_fn.function.value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, key_val, desc_obj });
                defer result.deinit();
                return coercion.isTruthy(result);
            }
            return defineOwnProperty(self, box.value.target, key, d);
        },
        .undefined, .null, .boolean, .number, .string, .symbol, .bigint => return false,
        else => return validateAndApply(self, try self.extraPropsObject(obj), key, d),
    }
}

pub fn keyToValue(self: *Interpreter, key: []const u8) anyerror!JSValue {
    if (isSymbolKey(key)) {
        if (self.symbol_keys.get(key)) |sym| return sym.retain();
    }
    return self.gcNewString(key);
}

pub fn definePropertyOn(self: *Interpreter, what: []const u8, obj: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    if (!builtin_helpers.isObjectLike(obj)) return self.throwError(.type_error, "Object.{s} called on non-object", .{what});
    var d = try toPropertyDescriptor(self, desc);
    defer d.deinit();
    if (!try defineOwnProperty(self, obj, key, &d)) {
        if (obj == .proxy) return self.throwError(.type_error, "'defineProperty' on proxy: trap returned falsish for property '{s}'", .{displayKey(key)});
        return self.throwError(.type_error, "Cannot redefine property: {s}", .{displayKey(key)});
    }
}

pub fn arrayDefineOwnProperty(self: *Interpreter, obj: JSValue, key: []const u8, d: *const ParsedDesc) anyerror!bool {
    const arr = &obj.array.value;
    if (std.mem.eql(u8, key, "length")) return arraySetLengthDesc(self, obj, d);
    const idx = zarray.CanonicalNumericIndexString(key) orelse
        return validateAndApply(self, try self.arrayPropsObject(obj), key, d);
    if (idx >= arr.length() and !arr.isLengthWritable()) return false;
    const bag = try self.arrayPropsObject(obj);
    const zo = &bag.object.value;
    if (zo.getOwnRecord(key) == null) {
        if (arr.getOpt(idx)) |cur| {
            try bagInsertRaw(bag, key, cur.retain(), .{
                .writable = !zo.is_frozen,
                .enumerable = true,
                .configurable = !(zo.is_frozen or zo.is_sealed),
            });
        }
    }
    if (!try validateAndApply(self, bag, key, d)) return false;
    try arr.setHasElementDescriptors(true);
    const rec = zo.getOwnRecord(key).?;
    const new_val: JSValue = if (rec.isAccessor()) JSValue.UNDEFINED else rec.value.retain();
    const old = arr.getOpt(idx);
    arr.set(idx, new_val) catch |err| {
        new_val.deinit();
        return err;
    };
    if (old) |o| o.deinit();
    return true;
}

pub fn arraySetLengthDesc(self: *Interpreter, obj: JSValue, d: *const ParsedDesc) anyerror!bool {
    const arr = &obj.array.value;
    var new_len: u32 = @intCast(arr.length());
    if (d.has_value) {
        new_len = try self.toUint32JS(d.value);
        const num = try self.toNumberJS(d.value);
        if (@as(f64, @floatFromInt(new_len)) != num) return self.throwError(.range_error, "Invalid array length", .{});
    }
    if (d.has_configurable and d.configurable) return false;
    if (d.has_enumerable and d.enumerable) return false;
    if (d.isAccessor()) return false;
    if (!arr.isLengthWritable()) {
        if (d.has_writable and d.writable) return false;
        return new_len == arr.length();
    }
    const ok = try arraySetLengthRaw(self, obj, new_len);
    if (d.has_writable and !d.writable) try arr.setLengthWritable(false);
    return ok;
}

pub fn arraySetLengthRaw(self: *Interpreter, obj: JSValue, new_len: u32) anyerror!bool {
    const arr = &obj.array.value;
    const cur = arr.length();
    if (new_len >= cur) {
        if (new_len - cur <= 1024 and !arr.isSparse() and arr.items.items.len == cur) {
            var i = cur;
            while (i < new_len) : (i += 1) try arr.appendHole();
        } else try arr.setLength(new_len);
        return true;
    }
    var stop: usize = new_len;
    var ok = true;
    const bag_opt = self.array_props.get(@intFromPtr(obj.array));
    if (bag_opt) |bag| {
        const zo = &bag.object.value;
        for (zo.properties.keys(), zo.properties.values()) |k, p| {
            const i = zarray.CanonicalNumericIndexString(k) orelse continue;
            if (i >= new_len and i < cur and !p.descriptor.configurable and i + 1 > stop) {
                stop = i + 1;
                ok = false;
            }
        }
        if (zo.is_sealed or zo.is_frozen) {
            var i = cur;
            while (i > stop) {
                i -= 1;
                if (!arr.isHole(i)) {
                    stop = i + 1;
                    ok = false;
                    break;
                }
            }
        }
        var doomed: std.ArrayList([]const u8) = .empty;
        defer {
            for (doomed.items) |k| self.gc_allocator.free(k);
            doomed.deinit(self.gc_allocator);
        }
        for (zo.properties.keys()) |k| {
            const i = zarray.CanonicalNumericIndexString(k) orelse continue;
            if (i >= stop) try doomed.append(self.gc_allocator, try self.gc_allocator.dupe(u8, k));
        }
        for (doomed.items) |k| _ = try self.deleteObjectProperty(bag, k);
    }
    if (stop < cur) {
        const items = arr.items.items;
        var i = stop;
        while (i < @min(items.len, cur)) : (i += 1) items[i].deinit();
        if (arr.getSparse()) |sp| {
            var it = sp.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.* >= stop) e.value_ptr.deinit();
            }
        }
        try arr.setLength(@intCast(stop));
    }
    return ok;
}

pub fn toObject(self: *Interpreter, v: JSValue) anyerror!JSValue {
    if (v == .undefined or v == .null) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    if (builtin_helpers.isObjectLike(v)) return v.retain();
    const object_builtins = @import("object_builtins.zig");
    return object_builtins.objectConstructor(self, self.gc_allocator, JSValue.UNDEFINED, &.{v});
}

pub fn objectDefinePropertiesImpl(self: *Interpreter, allocator: Allocator, obj: JSValue, properties: JSValue) anyerror!void {
    const props = try toObject(self, properties);
    defer props.deinit();
    const object_builtins = @import("object_builtins.zig");
    const keys = try object_builtins.ownPropertyKeyList(self, allocator, props);
    defer object_builtins.freeOwnedKeys(allocator, keys);
    var descs: std.ArrayList(ParsedDesc) = .empty;
    var desc_keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (descs.items) |*d| d.deinit();
        descs.deinit(allocator);
        desc_keys.deinit(allocator);
    }
    for (keys) |k| {
        const enumerable = (try object_builtins.ownPropertyEnumerable(self, props, k)) orelse continue;
        if (!enumerable) continue;
        const desc_obj = try self.getProperty(props, k);
        defer desc_obj.deinit();
        const d = try toPropertyDescriptor(self, desc_obj);
        descs.append(allocator, d) catch |err| {
            d.deinit();
            return err;
        };
        try desc_keys.append(allocator, k);
    }
    for (descs.items, desc_keys.items) |*d, k| {
        if (!try defineOwnProperty(self, obj, k, d))
            return self.throwError(.type_error, "Cannot redefine property: {s}", .{displayKey(k)});
    }
}
