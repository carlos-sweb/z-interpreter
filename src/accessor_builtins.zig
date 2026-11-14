//! The builtin accessor properties that used to be synthesized per
//! receiver tag in `getProperty` (Map/Set `size`, ArrayBuffer/
//! SharedArrayBuffer/DataView/%TypedArray% `byteLength` & co., Symbol
//! `description`), plus the ones that didn't exist: the fixed-length
//! ArrayBuffer queries (`maxByteLength`, `resizable`, `detached`,
//! `growable`), the constructors' `get [Symbol.species]`, and Annex B's
//! `Object.prototype.__proto__`. Each is a real accessor on its prototype
//! (or constructor): a getter named "get <name>" with length 0, no setter
//! (except `__proto__`), enumerable false, configurable true -- so
//! getOwnPropertyDescriptor, overriding and `in` see what the spec says.
//! A getter called on the wrong kind of receiver is a TypeError.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const object_builtins = @import("object_builtins.zig");

const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const isObjectLike = builtin_helpers.isObjectLike;

/// An accessor with the attributes of every builtin accessor
/// (enumerable false, configurable true); `setter` may be null.
fn defineAccessor(self: *Interpreter, target: JSValue, key: []const u8, comptime name: []const u8, getter: NativeFn, setter: ?NativeFn) !void {
    const g = try native(self, "get " ++ name, 0, getter);
    const s: ?JSValue = if (setter) |f| try native(self, "set " ++ name, 1, f) else null;
    try target.object.value.defineAccessor(key, g, s, JSValue.UNDEFINED);
    const rec = target.object.value.getOwnRecordMut(key).?;
    rec.descriptor.enumerable = false;
    rec.descriptor.configurable = true;
}

fn incompatible(self: *Interpreter, comptime what: []const u8) anyerror {
    return self.throwError(.type_error, "Method get " ++ what ++ " called on incompatible receiver", .{});
}

fn num(n: usize) JSValue {
    return JSValue.fromNumber(@floatFromInt(n));
}

// ===== Map / Set =====

fn mapSize(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    if (this_value != .map) return incompatible(interp(ctx), "Map.prototype.size");
    return num(this_value.map.value.size());
}

fn setSize(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    if (this_value != .set) return incompatible(interp(ctx), "Set.prototype.size");
    return num(this_value.set.value.size());
}

// ===== ArrayBuffer / SharedArrayBuffer =====
//
// This engine's buffers are fixed-length and never detached (no resize,
// grow or transfer): per spec that makes maxByteLength = byteLength,
// resizable/growable false and detached false.

/// The receiver as an ArrayBuffer (`shared` false) or SharedArrayBuffer.
fn bufferOf(self: *Interpreter, this_value: JSValue, comptime shared: bool, comptime what: []const u8) anyerror!*zvalue.ArrayBuffer {
    if (this_value != .array_buffer or this_value.array_buffer.value.is_shared != shared) return incompatible(self, what);
    return &this_value.array_buffer.value;
}

fn bufferGetter(comptime shared: bool, comptime field: enum { byte_length, max_byte_length, flag_false }, comptime what: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = args;
            const buf = try bufferOf(interp(ctx), this_value, shared, what);
            return switch (field) {
                .byte_length, .max_byte_length => num(buf.byteLength()),
                .flag_false => JSValue.fromBool(false),
            };
        }
    }.call;
}

// ===== DataView =====

fn dataViewGetter(comptime field: enum { buffer, byte_length, byte_offset }, comptime what: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = args;
            if (this_value != .data_view) return incompatible(interp(ctx), what);
            const dv = &this_value.data_view.value;
            return switch (field) {
                .buffer => dv.owner.retain(),
                .byte_length => num(dv.view.byte_length),
                .byte_offset => num(dv.view.byte_offset),
            };
        }
    }.call;
}

// ===== %TypedArray%.prototype =====

fn typedArrayGetter(comptime field: enum { buffer, byte_length, byte_offset, length }, comptime what: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = args;
            if (this_value != .typed_array) return incompatible(interp(ctx), what);
            const ta = &this_value.typed_array.value;
            return switch (field) {
                .buffer => ta.owner.retain(),
                .byte_length => num(ta.len * ta.kind.elemSize()),
                .byte_offset => num(ta.byte_offset),
                .length => num(ta.len),
            };
        }
    }.call;
}

fn typedArrayToStringTag(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    if (this_value != .typed_array) return JSValue.UNDEFINED;
    const name: []const u8 = switch (this_value.typed_array.value.kind) {
        .i8 => "Int8Array",
        .u8 => "Uint8Array",
        .u8_clamped => "Uint8ClampedArray",
        .i16 => "Int16Array",
        .u16 => "Uint16Array",
        .i32 => "Int32Array",
        .u32 => "Uint32Array",
        .f32 => "Float32Array",
        .f64 => "Float64Array",
        .i64 => "BigInt64Array",
        .u64 => "BigUint64Array",
    };
    return interp(ctx).gcNewString(name);
}

// ===== Symbol.prototype.description =====

fn symbolDescription(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const sym = if (this_value == .symbol) this_value else self.unboxPrimitiveWrapper(this_value) orelse JSValue.UNDEFINED;
    if (sym != .symbol) return incompatible(self, "Symbol.prototype.description");
    const d = sym.symbol.value.description orelse return JSValue.UNDEFINED;
    return self.gcNewString(d);
}

// ===== get [Symbol.species] =====

fn speciesGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = args;
    return this_value.retain();
}

// ===== Object.prototype.__proto__ (Annex B.2.2.1) =====

fn getPrototypeOfWithTypedArray(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (@import("arraybuffer_builtins.zig").isTypedArrayConstructor(obj)) {
        if (Interpreter.heapBoxAddress(obj)) |addr| {
            if (self.proto_refs.get(addr)) |p| return p.retain();
        }
        if (self.protos.typed_array_base.object.value.get("constructor")) |ta_ctor| {
            return ta_ctor.retain();
        }
    }
    return object_builtins.objectGetPrototypeOf(ctx, allocator, this_value, args);
}

fn reflectGetPrototypeOfWithTypedArray(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    if (!isObjectLike(arg(args, 0))) return self.throwError(.type_error, "Reflect.getPrototypeOf called on non-object", .{});
    return getPrototypeOfWithTypedArray(ctx, allocator, this_value, args);
}

fn protoGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    // ToObject(this), then [[GetPrototypeOf]] (objectGetPrototypeOf
    // throws the TypeError for undefined/null).
    return getPrototypeOfWithTypedArray(ctx, allocator, JSValue.UNDEFINED, &.{this_value});
}

fn protoSetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    if (this_value == .undefined or this_value == .null)
        return self.throwError(.type_error, "Object.prototype.__proto__ called on null or undefined", .{});
    const proto = arg(args, 0);
    // A non-object, non-null value is ignored; so is a primitive receiver.
    if (proto != .null and !isObjectLike(proto)) return JSValue.UNDEFINED;
    if (!isObjectLike(this_value)) return JSValue.UNDEFINED;
    const ok = object_builtins.setPrototypeOfInternal(self, this_value, proto) catch |err| switch (err) {
        error.PrototypeCycle => return self.throwError(.type_error, "Cyclic __proto__ value", .{}),
        else => return self.throwError(.type_error, "Object.prototype.__proto__ setter failed: {s}", .{@errorName(err)}),
    };
    if (!ok) return self.throwError(.type_error, "Object.prototype.__proto__ setter failed", .{});
    return JSValue.UNDEFINED;
}

/// Installs every accessor above. Runs at the end of materializeProtos,
/// once every prototype (including %TypedArray%.prototype) exists.
pub fn install(self: *Interpreter) !void {
    const p = &self.protos;
    try defineAccessor(self, p.map, "size", "size", mapSize, null);
    try defineAccessor(self, p.set, "size", "size", setSize, null);

    try defineAccessor(self, p.array_buffer, "byteLength", "byteLength", bufferGetter(false, .byte_length, "ArrayBuffer.prototype.byteLength"), null);
    try defineAccessor(self, p.array_buffer, "maxByteLength", "maxByteLength", bufferGetter(false, .max_byte_length, "ArrayBuffer.prototype.maxByteLength"), null);
    try defineAccessor(self, p.array_buffer, "resizable", "resizable", bufferGetter(false, .flag_false, "ArrayBuffer.prototype.resizable"), null);
    try defineAccessor(self, p.array_buffer, "detached", "detached", bufferGetter(false, .flag_false, "ArrayBuffer.prototype.detached"), null);
    try defineAccessor(self, p.shared_array_buffer, "byteLength", "byteLength", bufferGetter(true, .byte_length, "SharedArrayBuffer.prototype.byteLength"), null);
    try defineAccessor(self, p.shared_array_buffer, "maxByteLength", "maxByteLength", bufferGetter(true, .max_byte_length, "SharedArrayBuffer.prototype.maxByteLength"), null);
    try defineAccessor(self, p.shared_array_buffer, "growable", "growable", bufferGetter(true, .flag_false, "SharedArrayBuffer.prototype.growable"), null);

    try defineAccessor(self, p.data_view, "buffer", "buffer", dataViewGetter(.buffer, "DataView.prototype.buffer"), null);
    try defineAccessor(self, p.data_view, "byteLength", "byteLength", dataViewGetter(.byte_length, "DataView.prototype.byteLength"), null);
    try defineAccessor(self, p.data_view, "byteOffset", "byteOffset", dataViewGetter(.byte_offset, "DataView.prototype.byteOffset"), null);

    try defineAccessor(self, p.typed_array_base, "buffer", "buffer", typedArrayGetter(.buffer, "%TypedArray%.prototype.buffer"), null);
    try defineAccessor(self, p.typed_array_base, "byteLength", "byteLength", typedArrayGetter(.byte_length, "%TypedArray%.prototype.byteLength"), null);
    try defineAccessor(self, p.typed_array_base, "byteOffset", "byteOffset", typedArrayGetter(.byte_offset, "%TypedArray%.prototype.byteOffset"), null);
    try defineAccessor(self, p.typed_array_base, "length", "length", typedArrayGetter(.length, "%TypedArray%.prototype.length"), null);
    if (self.symbol_to_string_tag) |tag_sym| {
        const tag_key = try self.encodeKey(tag_sym);
        defer self.gc_allocator.free(tag_key);
        try defineAccessor(self, p.typed_array_base, tag_key, "[Symbol.toStringTag]", typedArrayToStringTag, null);
    }

    try defineAccessor(self, p.symbol, "description", "description", symbolDescription, null);

    try defineAccessor(self, p.object, "__proto__", "__proto__", protoGetter, protoSetter);

    // get [Symbol.species] on the constructors that have one (RegExp's
    // is installed with the rest of RegExp; %TypedArray%'s is installed
    // on the intrinsic %TypedArray% statics bag).
    const species_sym = (try self.functionStatics(self.global_env.get("Symbol").?)).object.value.get("species").?;
    const species_key = try self.encodeKey(species_sym);
    defer self.gc_allocator.free(species_key);
    inline for (.{ "Array", "ArrayBuffer", "SharedArrayBuffer", "Map", "Set", "Promise" }) |name| {
        const statics = try self.functionStatics(self.global_env.get(name).?);
        try defineAccessor(self, statics, species_key, "[Symbol.species]", speciesGetter, null);
    }
    const ta_statics = try @import("arraybuffer_builtins.zig").installHierarchy(self);
    try defineAccessor(self, ta_statics, species_key, "[Symbol.species]", speciesGetter, null);
    const object_statics = try self.functionStatics(self.global_env.get("Object").?);
    const old_obj_gpo = object_statics.object.value.get("getPrototypeOf");
    try builtin_helpers.dneMethod(object_statics, "getPrototypeOf", try native(self, "getPrototypeOf", 1, getPrototypeOfWithTypedArray));
    if (old_obj_gpo) |old| old.deinit();
    if (self.global_env.get("Reflect")) |reflect_obj| {
        const old_ref_gpo = reflect_obj.object.value.get("getPrototypeOf");
        try builtin_helpers.dneMethod(reflect_obj, "getPrototypeOf", try native(self, "getPrototypeOf", 1, reflectGetPrototypeOfWithTypedArray));
        if (old_ref_gpo) |old| old.deinit();
    }
}
