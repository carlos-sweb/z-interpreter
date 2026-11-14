//! `ArrayBuffer` + `DataView` (roadmap item 19 phase 1) and the 10
//! JS-visible TypedArray constructors + the shared `%TypedArray%.prototype`
//! (roadmap item 19 phase 2, installed once on the shared, non-exposed
//! `typed_array_base` object every concrete `XArray.prototype` chains to).
//! Grouped into one file since TypedArray construction and its prototype
//! methods both reach into ArrayBuffer/DataView internals directly (byte
//! offsets, `typedElemGet`/`typedElemSet`). `normIndex` (used by
//! `taCopyWithin`/`taFill`/`taSlice`) stays `pub` in builtins.zig since
//! it's also shared with Array.prototype's extended methods, not yet
//! extracted -- same reach-back-across-the-circular-import pattern
//! `number_builtins.zig` already uses for `globalParseInt`/`globalParseFloat`.
//! z-interpreter-refactor.md, Step 5 Phase A batch 4.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zbigint = @import("zbigint");
const zbuffer = @import("zbuffer");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const builtins = @import("builtins.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;
const requireTag = builtin_helpers.requireTag;
const requireCallback = builtin_helpers.requireCallback;
const callCallbackWithThis = builtin_helpers.callCallbackWithThis;
const toNumberStrict = builtin_helpers.toNumberStrict;
const toByteIndexArg = builtin_helpers.toByteIndexArg;
const toIntSat = builtin_helpers.toIntSat;
const toBigIntValue = builtin_helpers.toBigIntValue;
const toUint8Wrap = builtin_helpers.toUint8Wrap;
const toInt8Wrap = builtin_helpers.toInt8Wrap;
const toUint16Wrap = builtin_helpers.toUint16Wrap;
const toInt16Wrap = builtin_helpers.toInt16Wrap;
const toU64Wrapped = builtin_helpers.toU64Wrapped;
const toI64Wrapped = builtin_helpers.toI64Wrapped;
const bigIntFromU64 = builtin_helpers.bigIntFromU64;
const typedElemGet = builtin_helpers.typedElemGet;
const typedElemSet = builtin_helpers.typedElemSet;
const toLength = builtin_helpers.toLength;
const ArrayIterCtx = builtin_helpers.ArrayIterCtx;
const arrayIterNext = builtin_helpers.arrayIterNext;
const iteratorSelfBuiltin = builtin_helpers.iteratorSelfBuiltin;
const normIndex = builtins.normIndex;

pub const array_buffer_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "slice", MethodSpec{ .call = arrayBufferSlice, .arity = 2 } },
});

pub const shared_array_buffer_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "slice", MethodSpec{ .call = arrayBufferSlice, .arity = 2 } },
});

pub const dataview_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "getInt8", MethodSpec{ .call = dataViewGetInt8, .arity = 1 } },
    .{ "getUint8", MethodSpec{ .call = dataViewGetUint8, .arity = 1 } },
    .{ "setInt8", MethodSpec{ .call = dataViewSetInt8, .arity = 2 } },
    .{ "setUint8", MethodSpec{ .call = dataViewSetUint8, .arity = 2 } },
    .{ "getInt16", MethodSpec{ .call = dataViewGetInt16, .arity = 1 } },
    .{ "getUint16", MethodSpec{ .call = dataViewGetUint16, .arity = 1 } },
    .{ "setInt16", MethodSpec{ .call = dataViewSetInt16, .arity = 2 } },
    .{ "setUint16", MethodSpec{ .call = dataViewSetUint16, .arity = 2 } },
    .{ "getInt32", MethodSpec{ .call = dataViewGetInt32, .arity = 1 } },
    .{ "getUint32", MethodSpec{ .call = dataViewGetUint32, .arity = 1 } },
    .{ "setInt32", MethodSpec{ .call = dataViewSetInt32, .arity = 2 } },
    .{ "setUint32", MethodSpec{ .call = dataViewSetUint32, .arity = 2 } },
    .{ "getFloat32", MethodSpec{ .call = dataViewGetFloat32, .arity = 1 } },
    .{ "setFloat32", MethodSpec{ .call = dataViewSetFloat32, .arity = 2 } },
    .{ "getFloat64", MethodSpec{ .call = dataViewGetFloat64, .arity = 1 } },
    .{ "setFloat64", MethodSpec{ .call = dataViewSetFloat64, .arity = 2 } },
    .{ "getBigInt64", MethodSpec{ .call = dataViewGetBigInt64, .arity = 1 } },
    .{ "getBigUint64", MethodSpec{ .call = dataViewGetBigUint64, .arity = 1 } },
    .{ "setBigInt64", MethodSpec{ .call = dataViewSetBigInt64, .arity = 2 } },
    .{ "setBigUint64", MethodSpec{ .call = dataViewSetBigUint64, .arity = 2 } },
});

// ===== ArrayBuffer / DataView (roadmap item 19, phase 1) =====
//
// TypedArray construction and `%TypedArray%.prototype` are a separate,
// not-yet-started follow-up phase (see the durable plan). Only
// ArrayBuffer + DataView are wired here.

fn arrayBufferConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor ArrayBuffer requires 'new'", .{});
    const len_arg = arg(args, 0);
    const byte_length: usize = if (len_arg == .undefined) 0 else try toByteIndexArg(self, len_arg, "length");
    const ab = try self.gcNewArrayBuffer(byte_length);
    errdefer ab.deinit();
    if (self.construct_proto) |proto| {
        if (!zvalue.equality.strictEquals(proto, self.protos.array_buffer)) {
            try self.setOwnedPrototype(ab, proto);
        }
    }
    return ab;
}

/// `SharedArrayBuffer` -- see atomics-sharedarraybuffer.md: this engine
/// has no real cross-agent memory model, so it's `ArrayBuffer` storage
/// with `is_shared = true` (dispatched to a different prototype, see
/// `arrayBufferProto`).
fn sharedArrayBufferConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor SharedArrayBuffer requires 'new'", .{});
    const len_arg = arg(args, 0);
    const byte_length: usize = if (len_arg == .undefined) 0 else try toByteIndexArg(self, len_arg, "length");
    const sab = try self.gcNewSharedArrayBuffer(byte_length);
    errdefer sab.deinit();
    if (self.construct_proto) |proto| {
        if (!zvalue.equality.strictEquals(proto, self.protos.shared_array_buffer)) {
            try self.setOwnedPrototype(sab, proto);
        }
    }
    return sab;
}

/// Shared by `ArrayBuffer.prototype.slice` and
/// `SharedArrayBuffer.prototype.slice` (installed as two distinct
/// native function objects, one per prototype -- see `materializeProtos`
/// -- but the algorithm is identical): a NEW buffer holding a COPY,
/// same sharedness as the receiver (`is_shared` propagated onto the
/// copy since `zbuffer.ArrayBuffer.slice`'s own copy always starts
/// unshared).
fn arrayBufferSlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    if (this_value != .array_buffer) return self.throwError(.type_error, "ArrayBuffer.prototype.slice called on incompatible receiver", .{});
    const src = &this_value.array_buffer.value;
    const len = src.byteLength();
    const start_arg = arg(args, 0);
    const end_arg = arg(args, 1);
    const start: usize = if (start_arg == .undefined) 0 else try toByteIndexArg(self, start_arg, "start");
    const end: usize = if (end_arg == .undefined) len else try toByteIndexArg(self, end_arg, "end");
    const first = @min(start, len);
    const final = @min(end, len);
    const new_len = if (final > first) final - first else 0;
    if (try speciesConstructor(self, this_value)) |ctor| {
        defer ctor.deinit();
        const new_buf = try self.constructValue(ctor, &.{JSValue.fromNumber(@floatFromInt(new_len))}, "ArrayBuffer");
        errdefer new_buf.deinit();
        if (new_buf != .array_buffer or new_buf.array_buffer.value.is_shared != src.is_shared) {
            return self.throwError(.type_error, "Species constructor did not return a compatible ArrayBuffer", .{});
        }
        if (new_buf.array_buffer == this_value.array_buffer) {
            return self.throwError(.type_error, "Species constructor returned the same ArrayBuffer", .{});
        }
        if (new_buf.array_buffer.value.byteLength() < new_len) {
            return self.throwError(.type_error, "Species constructor returned an ArrayBuffer that is too small", .{});
        }
        if (new_len > 0) {
            @memcpy(new_buf.array_buffer.value.bytes[0..new_len], src.bytes[first .. first + new_len]);
        }
        return new_buf;
    }
    var copy = src.slice(self.gc_allocator, first, final) catch |e| return self.bufferErr(e);
    copy.is_shared = src.is_shared;
    return self.gcNewArrayBufferFromValue(copy);
}

fn dataViewConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor DataView requires 'new'", .{});
    const buffer_arg = arg(args, 0);
    if (buffer_arg != .array_buffer) {
        return self.throwError(.type_error, "First argument to DataView constructor must be an ArrayBuffer", .{});
    }
    const offset_arg = arg(args, 1);
    const byte_offset: usize = if (offset_arg == .undefined) 0 else try toByteIndexArg(self, offset_arg, "byteOffset");
    const length_arg = arg(args, 2);
    const byte_length: ?usize = if (length_arg == .undefined) null else try toByteIndexArg(self, length_arg, "byteLength");
    const dv = self.gcNewDataView(buffer_arg.retain(), byte_offset, byte_length) catch |e| return self.bufferErr(e);
    errdefer dv.deinit();
    if (self.construct_proto) |proto| {
        if (!zvalue.equality.strictEquals(proto, self.protos.data_view)) {
            try self.setOwnedPrototype(dv, proto);
        }
    }
    return dv;
}

fn requireDataView(self: *Interpreter, v: JSValue, method: []const u8) anyerror!zbuffer.DataView {
    if (v != .data_view) return self.throwError(.type_error, "DataView.prototype.{s} called on incompatible receiver", .{method});
    return v.data_view.value.view;
}

fn dataViewGetInt8(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getInt8");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getInt8(offset) catch |e| return self.bufferErr(e);
    return JSValue.fromNumber(@floatFromInt(v));
}
fn dataViewGetUint8(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getUint8");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getUint8(offset) catch |e| return self.bufferErr(e);
    return JSValue.fromNumber(@floatFromInt(v));
}
fn dataViewSetInt8(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setInt8");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value = try toInt8Wrap(self, arg(args, 1));
    dv.setInt8(offset, value) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}
fn dataViewSetUint8(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setUint8");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value = try toUint8Wrap(self, arg(args, 1));
    dv.setUint8(offset, value) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}

fn dataViewGetInt16(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getInt16");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getInt16(offset, coercion.isTruthy(arg(args, 1))) catch |e| return self.bufferErr(e);
    return JSValue.fromNumber(@floatFromInt(v));
}
fn dataViewGetUint16(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getUint16");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getUint16(offset, coercion.isTruthy(arg(args, 1))) catch |e| return self.bufferErr(e);
    return JSValue.fromNumber(@floatFromInt(v));
}
fn dataViewSetInt16(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setInt16");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value = try toInt16Wrap(self, arg(args, 1));
    dv.setInt16(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}
fn dataViewSetUint16(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setUint16");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value = try toUint16Wrap(self, arg(args, 1));
    dv.setUint16(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}

fn dataViewGetInt32(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getInt32");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getInt32(offset, coercion.isTruthy(arg(args, 1))) catch |e| return self.bufferErr(e);
    return JSValue.fromNumber(@floatFromInt(v));
}
fn dataViewGetUint32(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getUint32");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getUint32(offset, coercion.isTruthy(arg(args, 1))) catch |e| return self.bufferErr(e);
    return JSValue.fromNumber(@floatFromInt(v));
}
fn dataViewSetInt32(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setInt32");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value: i32 = try self.toInt32JS(arg(args, 1));
    dv.setInt32(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}
fn dataViewSetUint32(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setUint32");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value: u32 = try self.toUint32JS(arg(args, 1));
    dv.setUint32(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}

fn dataViewGetFloat32(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getFloat32");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getFloat32(offset, coercion.isTruthy(arg(args, 1))) catch |e| return self.bufferErr(e);
    return JSValue.fromNumber(v);
}
fn dataViewSetFloat32(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setFloat32");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value: f32 = @floatCast(try self.toNumberJS(arg(args, 1)));
    dv.setFloat32(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}

fn dataViewGetFloat64(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getFloat64");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getFloat64(offset, coercion.isTruthy(arg(args, 1))) catch |e| return self.bufferErr(e);
    return JSValue.fromNumber(v);
}
fn dataViewSetFloat64(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setFloat64");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value: f64 = try self.toNumberJS(arg(args, 1));
    dv.setFloat64(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}

fn dataViewGetBigInt64(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getBigInt64");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getBigInt64(offset, coercion.isTruthy(arg(args, 1))) catch |e| return self.bufferErr(e);
    return self.gcNewBigIntValue(try zbigint.ZBigInt.fromInt(self.gc_allocator, v));
}

fn dataViewGetBigUint64(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "getBigUint64");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const v = dv.getBigUint64(offset, coercion.isTruthy(arg(args, 1))) catch |e| return self.bufferErr(e);
    return bigIntFromU64(self, v);
}
fn dataViewSetBigInt64(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setBigInt64");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const x = try toBigIntValue(self, self.gc_allocator, arg(args, 1));
    defer x.deinit();
    const value = try toI64Wrapped(self, x.bigint.value);
    dv.setBigInt64(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}
fn dataViewSetBigUint64(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setBigUint64");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const x = try toBigIntValue(self, self.gc_allocator, arg(args, 1));
    defer x.deinit();
    const value = try toU64Wrapped(self, x.bigint.value);
    dv.setBigUint64(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}

// ===== TypedArray (roadmap item 19, phase 2) =====
//
// Construction + integer-indexed element access + the
// length/byteLength/byteOffset/buffer accessors only.
// `%TypedArray%.prototype`'s real method surface (map/filter/forEach/
// slice/set/subarray/...) is a separate, not-yet-started follow-up
// phase.

/// One instance per named global (`Int8Array`, `Uint8Array`, ...),
/// allocated once at `setupGlobals` time -- see the registration loop's
/// own comment for why this isn't GC-tracked like `BoundCtx`/etc.
const TypedArrayCtorCtx = struct { interp: *Interpreter, kind: zvalue.TypedKind, name: []const u8 };

fn typedArrayCtx(ctx: *anyopaque) *TypedArrayCtorCtx {
    return @ptrCast(@alignCast(ctx));
}

pub fn isTypedArrayConstructor(v: JSValue) bool {
    return v == .function and v.function.value.call == typedArrayConstructor;
}

fn constructedTypedArray(self: *Interpreter, buf: JSValue, byte_offset: usize, len: ?usize, kind: zvalue.TypedKind) anyerror!JSValue {
    const ta = self.gcNewTypedArray(buf, byte_offset, len, kind) catch |e| return self.bufferErr(e);
    errdefer ta.deinit();
    if (self.construct_proto) |proto| {
        const intrinsic = self.typedArrayProto(kind);
        if (!zvalue.equality.strictEquals(proto, intrinsic)) {
            try self.setOwnedPrototype(ta, proto);
        }
    }
    return ta;
}

/// The 3 real constructor overloads: `new XArray(length)`, `new
/// XArray(buffer, byteOffset?, length?)`, `new XArray(iterableOrArray
/// Like)`. Non-iterable array-likes (`{length: 3, 0: 1, ...}` with no
/// `Symbol.iterator`) are a documented gap -- `iterableItems` doesn't
/// cover them today, same narrowing `Array.from` already has.
fn typedArrayConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const cctx = typedArrayCtx(ctx);
    const self = cctx.interp;
    const kind = cctx.kind;
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor {s} requires 'new'", .{cctx.name});
    const elem_size = kind.elemSize();
    const first = arg(args, 0);

    if (first == .array_buffer) {
        const byte_offset: usize = if (arg(args, 1) == .undefined) 0 else try toByteIndexArg(self, arg(args, 1), "byteOffset");
        const length_arg = arg(args, 2);
        const len: ?usize = if (length_arg == .undefined) null else try toByteIndexArg(self, length_arg, "length");
        return constructedTypedArray(self, first.retain(), byte_offset, len, kind);
    }

    if (!builtin_helpers.isObjectLike(first)) {
        const n: usize = if (first == .undefined) 0 else try toByteIndexArg(self, first, "length");
        const buf = self.gcNewArrayBuffer(n * elem_size) catch return self.throwError(.range_error, "Invalid typed array length: {d}", .{n});
        // gcNewTypedArray takes `buf` (its owner) even when it fails.
        return constructedTypedArray(self, buf, 0, n, kind);
    }

    if (first == .typed_array) {
        if (first.typed_array.value.kind.isBigInt() != kind.isBigInt()) {
            return self.throwError(.type_error, "Cannot mix BigInt and other types, use explicit conversions", .{});
        }
        const src_len = first.typed_array.value.len;
        const buf = self.gcNewArrayBuffer(src_len * elem_size) catch return self.throwError(.range_error, "Invalid typed array length: {d}", .{src_len});
        const ta = try constructedTypedArray(self, buf, 0, src_len, kind);
        errdefer ta.deinit();
        var i: usize = 0;
        while (i < src_len) : (i += 1) {
            const v = try taGet(self, first, i);
            defer v.deinit();
            try typedElemSet(self, kind, &buf.array_buffer.value, 0, src_len, i, v);
        }
        return ta;
    }

    var using_iter: JSValue = JSValue.UNDEFINED;
    if (self.symbol_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        using_iter = try self.getProperty(first, key);
    }
    defer using_iter.deinit();

    if (using_iter != .undefined and using_iter != .null) {
        if (using_iter != .function) return self.throwError(.type_error, "Symbol.iterator is not a function", .{});
        const iter = try self.callValue(using_iter, first, &.{}, "[Symbol.iterator]");
        defer iter.deinit();
        if (!builtin_helpers.isObjectLike(iter)) return self.throwError(.type_error, "Result of the Symbol.iterator method is not an object", .{});
        const values = try self.drainIterator(iter);
        defer {
            for (values) |v| v.deinit();
            self.gc_allocator.free(values);
        }
        const buf = self.gcNewArrayBuffer(values.len * elem_size) catch return self.throwError(.range_error, "Invalid typed array length: {d}", .{values.len});
        const ta = try constructedTypedArray(self, buf, 0, values.len, kind);
        errdefer ta.deinit();
        for (values, 0..) |item, i| {
            try typedElemSet(self, kind, &buf.array_buffer.value, 0, values.len, i, item);
        }
        return ta;
    }

    const len_v = try self.getProperty(first, "length");
    defer len_v.deinit();
    const len = try toLength(self, len_v);
    const buf = self.gcNewArrayBuffer(len * elem_size) catch return self.throwError(.range_error, "Invalid typed array length: {d}", .{len});
    const ta = try constructedTypedArray(self, buf, 0, len, kind);
    errdefer ta.deinit();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "{d}", .{i});
        defer allocator.free(key);
        const v = try self.getProperty(first, key);
        defer v.deinit();
        try typedElemSet(self, kind, &buf.array_buffer.value, 0, len, i, v);
    }
    return ta;
}

// ===== %TypedArray%.prototype -- installed ONCE on the shared, non-exposed
// `typed_array_base` object every concrete `XArray.prototype` chains to (see
// `materializeProtos`), so one function body here covers all 11 kinds. No
// "holes"/liveness concept like `liveElem` is needed -- a TypedArray has no
// holes and a fixed `len` for its lifetime. `taGet` already returns a
// FRESH/owned value (a plain number, or a freshly `gcNewBigIntValue`d
// BigInt with refcount 1) -- unlike `liveElem`'s BORROWED array slot, so
// none of the functions below `.retain()` what `taGet` hands them. =====

fn requireTypedArray(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!void {
    _ = try requireTag(ctx, this_value, .typed_array, "Method TypedArray.prototype.{s} called on incompatible receiver", method);
}

fn taLen(this_value: JSValue) usize {
    return this_value.typed_array.value.len;
}

fn taBuf(this_value: JSValue) *zbuffer.ArrayBuffer {
    return &this_value.typed_array.value.owner.array_buffer.value;
}

fn taGet(self: *Interpreter, this_value: JSValue, i: usize) anyerror!JSValue {
    const box = this_value.typed_array.value;
    return typedElemGet(self, box.kind, taBuf(this_value), box.byte_offset, box.len, i);
}

fn taWrite(self: *Interpreter, this_value: JSValue, i: usize, v: JSValue) anyerror!void {
    const box = this_value.typed_array.value;
    return typedElemSet(self, box.kind, taBuf(this_value), box.byte_offset, box.len, i, v);
}

/// Fresh zero-filled buffer + a same-kind view over the whole thing -- the
/// pattern `typedArrayConstructor`'s length-overload already uses inline,
/// factored out for reuse by map/filter/slice.
fn newSameKindTypedArray(self: *Interpreter, kind: zvalue.TypedKind, len: usize) anyerror!JSValue {
    const buf = try self.gcNewArrayBuffer(len * kind.elemSize());
    // gcNewTypedArray takes `buf` (its owner) even when it fails.
    return self.gcNewTypedArray(buf, 0, len, kind) catch |e| self.bufferErr(e);
}

fn speciesConstructor(self: *Interpreter, exemplar: JSValue) anyerror!?JSValue {
    const c = try self.getProperty(exemplar, "constructor");
    if (c == .undefined) return null;
    defer c.deinit();
    if (!builtin_helpers.isObjectLike(c)) return self.throwError(.type_error, "Constructor is not an object", .{});
    const key = try @import("regex_builtins.zig").wellKnownKey(self, "species");
    defer self.gc_allocator.free(key);
    const s = try self.getProperty(c, key);
    if (s == .undefined or s == .null) return null;
    if (self.isConstructor(s)) return s;
    s.deinit();
    return self.throwError(.type_error, "Species constructor is not a constructor", .{});
}

fn typedArraySpeciesCreate(self: *Interpreter, exemplar: JSValue, len: usize) anyerror!JSValue {
    const box = exemplar.typed_array.value;
    if (try speciesConstructor(self, exemplar)) |ctor| {
        defer ctor.deinit();
        return typedArrayCreateFromConstructor(self, ctor, len);
    }
    return newSameKindTypedArray(self, box.kind, len);
}

fn taForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    const this_arg = arg(args, 1);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) _ = try callCallbackWithThis(cb, allocator, this_arg, try taGet(self, this_value, i), i, this_value);
    return JSValue.UNDEFINED;
}

fn taMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "map");
    const cb = try requireCallback(ctx, args);
    const this_arg = arg(args, 1);
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    const result = try typedArraySpeciesCreate(self, this_value, len);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try callCallbackWithThis(cb, allocator, this_arg, try taGet(self, this_value, i), i, this_value);
        defer v.deinit();
        try taWrite(self, result, i, v);
    }
    return result;
}

fn taFilter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "filter");
    const cb = try requireCallback(ctx, args);
    const this_arg = arg(args, 1);
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    var kept: std.ArrayList(JSValue) = .empty;
    defer {
        for (kept.items) |v| v.deinit();
        kept.deinit(allocator);
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try taGet(self, this_value, i);
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, this_value))) {
            try kept.append(allocator, item);
        } else {
            item.deinit();
        }
    }
    const result = try typedArraySpeciesCreate(self, this_value, kept.items.len);
    errdefer result.deinit();
    for (kept.items, 0..) |item, idx| try taWrite(self, result, idx, item);
    return result;
}

fn taFind(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "find");
    const cb = try requireCallback(ctx, args);
    const this_arg = arg(args, 1);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try taGet(self, this_value, i);
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, this_value))) return item;
    }
    return JSValue.UNDEFINED;
}

fn taFindIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "findIndex");
    const cb = try requireCallback(ctx, args);
    const this_arg = arg(args, 1);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, try taGet(self, this_value, i), i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn taFindLast(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "findLast");
    const cb = try requireCallback(ctx, args);
    const this_arg = arg(args, 1);
    const self = interp(ctx);
    var i = taLen(this_value);
    while (i > 0) {
        i -= 1;
        const item = try taGet(self, this_value, i);
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, this_value))) return item;
    }
    return JSValue.UNDEFINED;
}

fn taFindLastIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "findLastIndex");
    const cb = try requireCallback(ctx, args);
    const this_arg = arg(args, 1);
    const self = interp(ctx);
    var i = taLen(this_value);
    while (i > 0) {
        i -= 1;
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, try taGet(self, this_value, i), i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn taSome(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "some");
    const cb = try requireCallback(ctx, args);
    const this_arg = arg(args, 1);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, try taGet(self, this_value, i), i, this_value))) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

fn taEvery(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "every");
    const cb = try requireCallback(ctx, args);
    const this_arg = arg(args, 1);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, try taGet(self, this_value, i), i, this_value))) return JSValue.fromBool(false);
    }
    return JSValue.fromBool(true);
}

fn taReduce(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "reduce");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    var acc: JSValue = undefined;
    if (args.len > 1) {
        acc = args[1];
    } else {
        if (len == 0) return self.throwError(.type_error, "Reduce of empty array with no initial value", .{});
        acc = try taGet(self, this_value, 0);
        i = 1;
    }
    while (i < len) : (i += 1) {
        const item = try taGet(self, this_value, i);
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ acc, item, JSValue.fromNumber(@floatFromInt(i)), this_value });
    }
    return acc;
}

fn taReduceRight(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "reduceRight");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    var i = taLen(this_value);
    var acc: JSValue = undefined;
    var have = args.len > 1;
    if (have) acc = args[1];
    while (i > 0) {
        i -= 1;
        const item = try taGet(self, this_value, i);
        if (!have) {
            acc = item;
            have = true;
            continue;
        }
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ acc, item, JSValue.fromNumber(@floatFromInt(i)), this_value });
    }
    if (!have) return self.throwError(.type_error, "Reduce of empty array with no initial value", .{});
    return acc;
}

fn taIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireTypedArray(ctx, this_value, "indexOf");
    const self = interp(ctx);
    const len = taLen(this_value);
    if (len == 0) return JSValue.fromNumber(-1);
    const target = arg(args, 0);
    const n = if (args.len >= 2) try toNumberStrict(self, args[1]) else 0.0;
    if (std.math.isPositiveInf(n)) return JSValue.fromNumber(-1);
    const start = normIndex(n, len);
    var i: usize = start;
    while (i < len) : (i += 1) {
        if (zvalue.equality.strictEquals(try taGet(self, this_value, i), target)) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn taIncludes(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireTypedArray(ctx, this_value, "includes");
    const self = interp(ctx);
    const len = taLen(this_value);
    if (len == 0) return JSValue.fromBool(false);
    const target = arg(args, 0);
    const n = if (args.len >= 2) try toNumberStrict(self, args[1]) else 0.0;
    if (std.math.isPositiveInf(n)) return JSValue.fromBool(false);
    const start = normIndex(n, len);
    var i: usize = start;
    while (i < len) : (i += 1) {
        if (zvalue.equality.sameValueZero(try taGet(self, this_value, i), target)) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

fn taLastIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireTypedArray(ctx, this_value, "lastIndexOf");
    const self = interp(ctx);
    const len = taLen(this_value);
    if (len == 0) return JSValue.fromNumber(-1);
    const target = arg(args, 0);
    const n = if (args.len >= 2) try toNumberStrict(self, args[1]) else @as(f64, @floatFromInt(len - 1));
    if (std.math.isNegativeInf(n)) return JSValue.fromNumber(-1);
    const rel = toIntSat(n);
    const k_signed: isize = if (rel >= 0) @min(rel, @as(isize, @intCast(len)) - 1) else @as(isize, @intCast(len)) + rel;
    if (k_signed < 0) return JSValue.fromNumber(-1);
    var i: usize = @as(usize, @intCast(k_signed)) + 1;
    while (i > 0) {
        i -= 1;
        if (zvalue.equality.strictEquals(try taGet(self, this_value, i), target)) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn taAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireTypedArray(ctx, this_value, "at");
    const self = interp(ctx);
    const len: isize = @intCast(taLen(this_value));
    const rel = toIntSat(try toNumberStrict(self, arg(args, 0)));
    const idx = if (rel < 0) len + rel else rel;
    if (idx < 0 or idx >= len) return JSValue.UNDEFINED;
    return taGet(self, this_value, @intCast(idx));
}

fn taJoinWith(self: *Interpreter, allocator: Allocator, this_value: JSValue, sep: []const u8) anyerror!JSValue {
    const len = taLen(this_value);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i != 0) try buf.appendSlice(allocator, sep);
        const s = try coercion.toDisplayString(allocator, try taGet(self, this_value, i));
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    return self.gcNewString(buf.items);
}

fn taJoin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "join");
    const self = interp(ctx);
    // Real spec: `undefined` (including not passed) is the only case
    // that means the default ",", same real-ToString-of-the-separator
    // rule as Array.prototype.join (see array_builtins.zig's arrayJoin
    // and its comment -- `[1,2].join(null)` is "1null2", not "1,2").
    const sep_arg = arg(args, 0);
    const owned_sep: ?[]const u8 = if (sep_arg == .undefined) null else try self.toDisplayStringJS(allocator, sep_arg);
    defer if (owned_sep) |s| allocator.free(s);
    const sep = owned_sep orelse ",";
    return taJoinWith(self, allocator, this_value, sep);
}

fn taToLocaleString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireTypedArray(ctx, this_value, "toLocaleString");
    const self = interp(ctx);
    const len = taLen(this_value);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i != 0) try buf.appendSlice(allocator, ",");
        const elem = try taGet(self, this_value, i);
        defer elem.deinit();
        const tl_fn = try self.getProperty(elem, "toLocaleString");
        defer tl_fn.deinit();
        if (tl_fn != .function and tl_fn != .proxy) {
            return self.throwError(.type_error, "toLocaleString is not a function", .{});
        }
        const res = try self.callValue(tl_fn, elem, &.{}, "toLocaleString");
        defer res.deinit();
        const s = try self.toDisplayStringJS(allocator, res);
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    return self.gcNewString(buf.items);
}

fn taToStringMethod(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireTypedArray(ctx, this_value, "toString");
    return taJoinWith(interp(ctx), allocator, this_value, ",");
}

fn taFill(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireTypedArray(ctx, this_value, "fill");
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    const coerced_val: JSValue = if (box.kind.isBigInt())
        try toBigIntValue(self, self.gc_allocator, arg(args, 0))
    else
        JSValue.fromNumber(try toNumberStrict(self, arg(args, 0)));
    defer coerced_val.deinit();
    const start = if (arg(args, 1) == .undefined) 0 else normIndex(try toNumberStrict(self, arg(args, 1)), len);
    const end = if (arg(args, 2) == .undefined) len else normIndex(try toNumberStrict(self, arg(args, 2)), len);
    var i = start;
    while (i < end) : (i += 1) try taWrite(self, this_value, i, coerced_val);
    return this_value.retain();
}

fn taCopyWithin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "copyWithin");
    const self = interp(ctx);
    const len = taLen(this_value);
    const target = normIndex(try toNumberStrict(self, arg(args, 0)), len);
    const start = if (arg(args, 1) == .undefined) 0 else normIndex(try toNumberStrict(self, arg(args, 1)), len);
    const end = if (arg(args, 2) == .undefined) len else normIndex(try toNumberStrict(self, arg(args, 2)), len);
    if (start >= end or target >= len) return this_value.retain();
    const count = @min(end - start, len - target);
    // Snapshot first so overlapping source/destination ranges are always
    // correct regardless of copy direction (same trick `arrayCopyWithin`
    // already uses).
    const tmp = try allocator.alloc(JSValue, count);
    defer allocator.free(tmp);
    var i: usize = 0;
    while (i < count) : (i += 1) tmp[i] = try taGet(self, this_value, start + i);
    i = 0;
    while (i < count) : (i += 1) try taWrite(self, this_value, target + i, tmp[i]);
    return this_value.retain();
}

fn taReverse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    try requireTypedArray(ctx, this_value, "reverse");
    const self = interp(ctx);
    const len = taLen(this_value);
    if (len > 1) {
        var lo: usize = 0;
        var hi: usize = len - 1;
        while (lo < hi) {
            const a = try taGet(self, this_value, lo);
            const b = try taGet(self, this_value, hi);
            try taWrite(self, this_value, lo, b);
            try taWrite(self, this_value, hi, a);
            lo += 1;
            hi -= 1;
        }
    }
    return this_value.retain();
}

/// Default (no-comparator) ordering is NUMERIC ascending -- unlike
/// `Array.prototype.sort`'s default STRING order -- with NaN always
/// sorting last (real spec's SortCompare); BigInt kinds compare exactly.
fn taSortLess(self: *Interpreter, allocator: Allocator, cmp: JSValue, kind: zvalue.TypedKind, a: JSValue, b: JSValue) anyerror!bool {
    if (cmp == .function) {
        const r = try cmp.function.value.call(cmp.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ a, b });
        defer r.deinit();
        return (try toNumberStrict(self, r)) < 0;
    }
    if (kind.isBigInt()) return a.bigint.value.cmp(b.bigint.value) == .lt;
    if (std.math.isNan(a.number)) return false;
    if (std.math.isNan(b.number)) return true;
    if (a.number == 0 and b.number == 0) return std.math.signbit(a.number) and !std.math.signbit(b.number);
    return a.number < b.number;
}

fn taSort(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "sort");
    const self = interp(ctx);
    const cmp = arg(args, 0);
    if (cmp != .undefined and cmp != .function) return self.throwError(.type_error, "The comparison function must be either a function or undefined", .{});
    const box = this_value.typed_array.value;
    const n = box.len;
    if (n < 2) return this_value.retain();
    const tmp = try allocator.alloc(JSValue, n);
    defer allocator.free(tmp);
    var i: usize = 0;
    while (i < n) : (i += 1) tmp[i] = try taGet(self, this_value, i);
    // Insertion sort (stable), same shape as `arraySort`.
    i = 1;
    while (i < n) : (i += 1) {
        const key = tmp[i];
        var j = i;
        while (j > 0) {
            const before = try taSortLess(self, allocator, cmp, box.kind, key, tmp[j - 1]);
            if (!before) break;
            tmp[j] = tmp[j - 1];
            j -= 1;
        }
        tmp[j] = key;
    }
    i = 0;
    while (i < n) : (i += 1) try taWrite(self, this_value, i, tmp[i]);
    return this_value.retain();
}

fn taToReversed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    try requireTypedArray(ctx, this_value, "toReversed");
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    const result = try newSameKindTypedArray(self, box.kind, len);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try taGet(self, this_value, len - 1 - i);
        defer v.deinit();
        try taWrite(self, result, i, v);
    }
    return result;
}

fn taToSorted(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "toSorted");
    const self = interp(ctx);
    const cmp = arg(args, 0);
    if (cmp != .undefined and cmp != .function) return self.throwError(.type_error, "The comparison function must be either a function or undefined", .{});
    const box = this_value.typed_array.value;
    const n = box.len;
    const tmp = try allocator.alloc(JSValue, n);
    defer allocator.free(tmp);
    var i: usize = 0;
    while (i < n) : (i += 1) tmp[i] = try taGet(self, this_value, i);
    if (n >= 2) {
        i = 1;
        while (i < n) : (i += 1) {
            const key = tmp[i];
            var j = i;
            while (j > 0) {
                const before = try taSortLess(self, allocator, cmp, box.kind, key, tmp[j - 1]);
                if (!before) break;
                tmp[j] = tmp[j - 1];
                j -= 1;
            }
            tmp[j] = key;
        }
    }
    const result = try newSameKindTypedArray(self, box.kind, n);
    errdefer result.deinit();
    i = 0;
    while (i < n) : (i += 1) try taWrite(self, result, i, tmp[i]);
    return result;
}

fn taWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireTypedArray(ctx, this_value, "with");
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    const rel = toIntSat(try toNumberStrict(self, arg(args, 0)));
    const actual_index: isize = if (rel >= 0) rel else @as(isize, @intCast(len)) + rel;
    const coerced_val: JSValue = if (box.kind.isBigInt())
        try toBigIntValue(self, self.gc_allocator, arg(args, 1))
    else
        JSValue.fromNumber(try toNumberStrict(self, arg(args, 1)));
    defer coerced_val.deinit();
    if (actual_index < 0 or actual_index >= @as(isize, @intCast(len))) {
        return self.throwError(.range_error, "Invalid typed array index", .{});
    }
    const target_idx: usize = @intCast(actual_index);
    const result = try newSameKindTypedArray(self, box.kind, len);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = if (i == target_idx) coerced_val.retain() else try taGet(self, this_value, i);
        defer v.deinit();
        try taWrite(self, result, i, v);
    }
    return result;
}

/// `TypedArray.prototype.set(source, offset=0)`: copies element VALUES
/// (per-kind coerced, like every other write path) from `source` into
/// `this` starting at `offset`. Source values are all materialized FIRST
/// when `source` is a TypedArray, which correctly handles the
/// same-buffer-overlap case by construction; non-TypedArray sources use
/// `SetTypedArrayFromArrayLike` (`ToObject` + `LengthOfArrayLike` +
/// per-index `Get`).
fn taSetMethod(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "set");
    const self = interp(ctx);
    const len = taLen(this_value);
    const source = arg(args, 0);
    const offset_raw = if (arg(args, 1) == .undefined) 0.0 else try toNumberStrict(self, arg(args, 1));
    const offset_int: f64 = if (std.math.isNan(offset_raw)) 0.0 else @trunc(offset_raw);
    if (offset_int < 0) return self.throwError(.range_error, "Offset is out of bounds", .{});

    if (source == .typed_array) {
        if (source.typed_array.value.kind.isBigInt() != this_value.typed_array.value.kind.isBigInt()) {
            return self.throwError(.type_error, "Cannot mix BigInt and other types, use explicit conversions", .{});
        }
        const slen = source.typed_array.value.len;
        if (std.math.isPositiveInf(offset_int) or offset_int + @as(f64, @floatFromInt(slen)) > @as(f64, @floatFromInt(len))) {
            const msg = if (offset_int > @as(f64, @floatFromInt(len))) "Offset is out of bounds" else "Source is too large";
            return self.throwError(.range_error, "{s}", .{msg});
        }
        const offset: usize = @intFromFloat(offset_int);
        var values: std.ArrayList(JSValue) = .empty;
        defer {
            for (values.items) |v| v.deinit();
            values.deinit(allocator);
        }
        var i: usize = 0;
        while (i < slen) : (i += 1) try values.append(allocator, try taGet(self, source, i));
        for (values.items, 0..) |v, idx| try taWrite(self, this_value, offset + idx, v);
        return JSValue.UNDEFINED;
    }

    if (source == .undefined or source == .null) {
        return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    }
    const len_v = try self.getProperty(source, "length");
    defer len_v.deinit();
    const slen = try toLength(self, len_v);
    if (std.math.isPositiveInf(offset_int) or offset_int + @as(f64, @floatFromInt(slen)) > @as(f64, @floatFromInt(len))) {
        const msg = if (offset_int > @as(f64, @floatFromInt(len))) "Offset is out of bounds" else "Source is too large";
        return self.throwError(.range_error, "{s}", .{msg});
    }
    const offset: usize = @intFromFloat(offset_int);
    var k: usize = 0;
    while (k < slen) : (k += 1) {
        var key_buf: [32]u8 = undefined;
        const pk = std.fmt.bufPrint(&key_buf, "{d}", .{k}) catch unreachable;
        const val = try self.getProperty(source, pk);
        defer val.deinit();
        try taWrite(self, this_value, offset + k, val);
    }
    return JSValue.UNDEFINED;
}

/// A VIEW sharing the SAME underlying `.array_buffer` (unlike `slice`,
/// which copies) -- clamped like `slice`, never throws on out-of-range.
fn taSubarray(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireTypedArray(ctx, this_value, "subarray");
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    const start = if (arg(args, 0) == .undefined) 0 else normIndex(try toNumberStrict(self, arg(args, 0)), len);
    const end = if (arg(args, 1) == .undefined) len else normIndex(try toNumberStrict(self, arg(args, 1)), len);
    const count = if (end > start) end - start else 0;
    const new_byte_offset = box.byte_offset + start * box.kind.elemSize();
    if (try speciesConstructor(self, this_value)) |ctor| {
        defer ctor.deinit();
        const new_ta = try self.constructValue(ctor, &.{
            box.owner,
            JSValue.fromNumber(@floatFromInt(new_byte_offset)),
            JSValue.fromNumber(@floatFromInt(count)),
        }, "TypedArray");
        errdefer new_ta.deinit();
        if (new_ta != .typed_array) return self.throwError(.type_error, "Derived TypedArray constructor created a non-TypedArray object", .{});
        return new_ta;
    }
    return self.gcNewTypedArray(box.owner.retain(), new_byte_offset, count, box.kind) catch |e| self.bufferErr(e);
}

/// A COPY into a fresh buffer (unlike `subarray`).
fn taSlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "slice");
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    const start = if (arg(args, 0) == .undefined) 0 else normIndex(try toNumberStrict(self, arg(args, 0)), len);
    const end = if (arg(args, 1) == .undefined) len else normIndex(try toNumberStrict(self, arg(args, 1)), len);
    const count = if (end > start) end - start else 0;
    const result = try typedArraySpeciesCreate(self, this_value, count);
    errdefer result.deinit();
    if (count > 0) {
        const tmp = try allocator.alloc(JSValue, count);
        defer {
            for (tmp) |v| v.deinit();
            allocator.free(tmp);
        }
        var i: usize = 0;
        while (i < count) : (i += 1) tmp[i] = try taGet(self, this_value, start + i);
        i = 0;
        while (i < count) : (i += 1) try taWrite(self, result, i, tmp[i]);
    }
    return result;
}

/// `keys`/`values`/`entries` reuse `ArrayIterCtx`/`arrayIterNext` (defined
/// above, above `makeArrayIterator`) UNCHANGED -- that machinery already
/// operates on a plain owned `[]const JSValue` snapshot, not on `.array`
/// specifically. Only the snapshot-building step differs from
/// `makeArrayIterator` (via `taGet` instead of `.array.value.toSlice()` +
/// `.retain()` -- `taGet`'s results are already owned, see the section
/// comment above).
fn taIterator(self: *Interpreter, allocator: Allocator, this_value: JSValue, kind: @FieldType(ArrayIterCtx, "kind")) anyerror!JSValue {
    const len = taLen(this_value);
    const snapshot = try allocator.alloc(JSValue, len);
    var i: usize = 0;
    while (i < len) : (i += 1) snapshot[i] = try taGet(self, this_value, i);
    const ic = try allocator.create(ArrayIterCtx);
    ic.* = .{ .interp = self, .items = snapshot, .kind = kind };
    try self.gcTrackArrayIterCtx(ic);
    var obj = try self.gcNewObject();
    if (self.iterator_prototype) |p| try obj.object.value.setPrototype(&p.object.value);
    try obj.object.value.set("next", try self.gcNewFunction(.{ .ctx = ic, .name = "next", .call = arrayIterNext }));
    if (self.symbol_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer allocator.free(key);
        try obj.object.value.set(key, try self.nativeMethod("iterator", "self", 0, iteratorSelfBuiltin));
    }
    return obj;
}

fn taKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireTypedArray(ctx, this_value, "keys");
    return taIterator(interp(ctx), allocator, this_value, .keys);
}

fn taValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireTypedArray(ctx, this_value, "values");
    return taIterator(interp(ctx), allocator, this_value, .values);
}

fn taEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireTypedArray(ctx, this_value, "entries");
    return taIterator(interp(ctx), allocator, this_value, .entries);
}

pub const typed_array_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "at", MethodSpec{ .call = taAt, .arity = 1 } },
    .{ "copyWithin", MethodSpec{ .call = taCopyWithin, .arity = 2 } },
    .{ "entries", MethodSpec{ .call = taEntries, .arity = 0 } },
    .{ "every", MethodSpec{ .call = taEvery, .arity = 1 } },
    .{ "fill", MethodSpec{ .call = taFill, .arity = 1 } },
    .{ "filter", MethodSpec{ .call = taFilter, .arity = 1 } },
    .{ "find", MethodSpec{ .call = taFind, .arity = 1 } },
    .{ "findIndex", MethodSpec{ .call = taFindIndex, .arity = 1 } },
    .{ "findLast", MethodSpec{ .call = taFindLast, .arity = 1 } },
    .{ "findLastIndex", MethodSpec{ .call = taFindLastIndex, .arity = 1 } },
    .{ "forEach", MethodSpec{ .call = taForEach, .arity = 1 } },
    .{ "includes", MethodSpec{ .call = taIncludes, .arity = 1 } },
    .{ "indexOf", MethodSpec{ .call = taIndexOf, .arity = 1 } },
    .{ "join", MethodSpec{ .call = taJoin, .arity = 1 } },
    .{ "keys", MethodSpec{ .call = taKeys, .arity = 0 } },
    .{ "lastIndexOf", MethodSpec{ .call = taLastIndexOf, .arity = 1 } },
    .{ "map", MethodSpec{ .call = taMap, .arity = 1 } },
    .{ "reduce", MethodSpec{ .call = taReduce, .arity = 1 } },
    .{ "reduceRight", MethodSpec{ .call = taReduceRight, .arity = 1 } },
    .{ "reverse", MethodSpec{ .call = taReverse, .arity = 0 } },
    .{ "set", MethodSpec{ .call = taSetMethod, .arity = 1 } },
    .{ "slice", MethodSpec{ .call = taSlice, .arity = 2 } },
    .{ "some", MethodSpec{ .call = taSome, .arity = 1 } },
    .{ "sort", MethodSpec{ .call = taSort, .arity = 1 } },
    .{ "subarray", MethodSpec{ .call = taSubarray, .arity = 2 } },
    .{ "toLocaleString", MethodSpec{ .call = taToLocaleString, .arity = 0 } },
    .{ "toReversed", MethodSpec{ .call = taToReversed, .arity = 0 } },
    .{ "toSorted", MethodSpec{ .call = taToSorted, .arity = 1 } },
    .{ "toString", MethodSpec{ .call = taToStringMethod, .arity = 0 } },
    .{ "values", MethodSpec{ .call = taValues, .arity = 0 } },
    .{ "with", MethodSpec{ .call = taWith, .arity = 2 } },
});

fn typedArrayAbstractConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor TypedArray requires 'new'", .{});
    return self.throwError(.type_error, "Abstract class TypedArray not directly constructable", .{});
}

fn typedArrayCreateFromConstructor(self: *Interpreter, ctor: JSValue, len: usize) anyerror!JSValue {
    if (!self.isConstructor(ctor)) return self.throwError(.type_error, "{s} is not a constructor", .{ctor.typeOf()});
    const new_ta = try self.constructValue(ctor, &.{JSValue.fromNumber(@floatFromInt(len))}, "TypedArray");
    errdefer new_ta.deinit();
    if (new_ta != .typed_array) return self.throwError(.type_error, "Derived TypedArray constructor created a non-TypedArray object", .{});
    if (new_ta.typed_array.value.len < len) return self.throwError(.type_error, "Derived TypedArray constructor created an array which was too small", .{});
    return new_ta;
}

fn typedArrayFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const C = this_value;
    if (!self.isConstructor(C)) return self.throwError(.type_error, "{s} is not a constructor", .{C.typeOf()});
    const source = arg(args, 0);
    const mapfn = arg(args, 1);
    const this_arg = arg(args, 2);
    if (mapfn != .undefined and mapfn != .function) return self.throwError(.type_error, "TypedArray.from: mapfn is not a function", .{});
    const mapping = mapfn == .function;
    if (source == .undefined or source == .null) return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});

    var using_iter: JSValue = JSValue.UNDEFINED;
    if (self.symbol_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        using_iter = try self.getProperty(source, key);
    }
    defer using_iter.deinit();

    if (using_iter != .undefined and using_iter != .null) {
        if (using_iter != .function) return self.throwError(.type_error, "Symbol.iterator is not a function", .{});
        const iter = try self.callValue(using_iter, source, &.{}, "[Symbol.iterator]");
        defer iter.deinit();
        if (!builtin_helpers.isObjectLike(iter)) return self.throwError(.type_error, "Result of the Symbol.iterator method is not an object", .{});
        const values = try self.drainIterator(iter);
        defer {
            for (values) |v| v.deinit();
            self.gc_allocator.free(values);
        }
        const target_obj = try typedArrayCreateFromConstructor(self, C, values.len);
        errdefer target_obj.deinit();
        for (values, 0..) |k_val, k| {
            const mapped = if (mapping)
                try mapfn.function.value.call(mapfn.function.value.ctx, allocator, this_arg, &.{ k_val, JSValue.fromNumber(@floatFromInt(k)) })
            else
                k_val.retain();
            defer mapped.deinit();
            try taWrite(self, target_obj, k, mapped);
        }
        return target_obj;
    }

    const len_v = try self.getProperty(source, "length");
    defer len_v.deinit();
    const len = try toLength(self, len_v);
    const target_obj = try typedArrayCreateFromConstructor(self, C, len);
    errdefer target_obj.deinit();
    var k: usize = 0;
    while (k < len) : (k += 1) {
        var key_buf: [32]u8 = undefined;
        const pk = std.fmt.bufPrint(&key_buf, "{d}", .{k}) catch unreachable;
        const k_val = try self.getProperty(source, pk);
        defer k_val.deinit();
        const mapped = if (mapping)
            try mapfn.function.value.call(mapfn.function.value.ctx, allocator, this_arg, &.{ k_val, JSValue.fromNumber(@floatFromInt(k)) })
        else
            k_val.retain();
        defer mapped.deinit();
        try taWrite(self, target_obj, k, mapped);
    }
    return target_obj;
}

fn typedArrayOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const C = this_value;
    if (!self.isConstructor(C)) return self.throwError(.type_error, "{s} is not a constructor", .{C.typeOf()});
    const new_obj = try typedArrayCreateFromConstructor(self, C, args.len);
    errdefer new_obj.deinit();
    for (args, 0..) |item, k| {
        try taWrite(self, new_obj, k, item);
    }
    return new_obj;
}

/// Wires the intrinsic `%TypedArray%` constructor, its `.from`/`.of` statics,
/// `%TypedArray%.prototype.constructor`, and the prototype/statics inheritance
/// chain for all 11 concrete TypedArray constructors. Returns `%TypedArray%`'s
/// statics bag so `accessor_builtins.install` can attach `get [Symbol.species]`.
pub fn installHierarchy(self: *Interpreter) !JSValue {
    const typed_array_base = self.protos.typed_array_base;
    const typed_array_ctor = try self.gcNewFunction(.{
        .ctx = self,
        .name = "TypedArray",
        .arity = 0,
        .call = typedArrayAbstractConstructor,
        .constructable = true,
    });
    typed_array_ctor.function.value.prototype = typed_array_base.retain();
    const ta_statics = try self.functionStatics(typed_array_ctor);
    try builtin_helpers.dneConst(ta_statics, "prototype", typed_array_base.retain());
    try builtin_helpers.dneMethod(ta_statics, "from", try native(self, "from", 1, typedArrayFrom));
    try builtin_helpers.dneMethod(ta_statics, "of", try native(self, "of", 0, typedArrayOf));
    try builtin_helpers.dneMethod(typed_array_base, "constructor", typed_array_ctor.retain());
    if (self.protos.array.object.value.get("toString")) |arr_to_str| {
        const old_to_str = typed_array_base.object.value.get("toString");
        try builtin_helpers.dneMethod(typed_array_base, "toString", arr_to_str.retain());
        if (old_to_str) |old| old.deinit();
    }

    const g = self.global_env;
    inline for (.{
        "Int8Array",
        "Uint8Array",
        "Uint8ClampedArray",
        "Int16Array",
        "Uint16Array",
        "Int32Array",
        "Uint32Array",
        "Float32Array",
        "Float64Array",
        "BigInt64Array",
        "BigUint64Array",
    }) |name| {
        const ctor = g.get(name).?;
        const proto = try self.functionPrototype(ctor);
        const ctor_statics = try self.functionStatics(ctor);
        try builtin_helpers.dneConst(ctor_statics, "prototype", proto.retain());
        try ctor_statics.object.value.setPrototype(&ta_statics.object.value);
    }
    return ta_statics;
}

/// Installs `ArrayBuffer`, `DataView`, and the 10 TypedArray constructors.
pub fn install(self: *Interpreter) !void {
    const arena = self.gc_allocator;
    const g = self.global_env;
    // `new ArrayBuffer(byteLength)` / `new DataView(buffer, byteOffset,
    // byteLength)` -- both reject a bare (non-new) call, same pattern as
    // Proxy above. TypedArray constructors are a separate, not-yet-
    // started follow-up phase.
    _ = try installBuiltin(self, .{ .name = "ArrayBuffer", .ctor = .{ .arity = 1, .call = arrayBufferConstructor, .constructable = true } });
    _ = try installBuiltin(self, .{ .name = "SharedArrayBuffer", .ctor = .{ .arity = 1, .call = sharedArrayBufferConstructor, .constructable = true } });
    _ = try installBuiltin(self, .{ .name = "DataView", .ctor = .{ .arity = 1, .call = dataViewConstructor, .constructable = true } });

    // The 10 JS-visible TypedArray constructors (roadmap item 19, phase
    // 2) -- one shared native, one small per-instance ctx (`interp` +
    // which `TypedKind` this particular global is) allocated once here
    // and living forever (bulk-freed with the AST arena at shutdown,
    // same "persistent setup-time ctx" convention z-run's `RunCtx`
    // already uses -- not a per-call ctx like `BoundCtx`).
    // `%TypedArray%.prototype`'s real method surface is a separate,
    // not-yet-started follow-up phase.
    inline for (.{
        .{ "Int8Array", zvalue.TypedKind.i8 },
        .{ "Uint8Array", zvalue.TypedKind.u8 },
        .{ "Uint8ClampedArray", zvalue.TypedKind.u8_clamped },
        .{ "Int16Array", zvalue.TypedKind.i16 },
        .{ "Uint16Array", zvalue.TypedKind.u16 },
        .{ "Int32Array", zvalue.TypedKind.i32 },
        .{ "Uint32Array", zvalue.TypedKind.u32 },
        .{ "Float32Array", zvalue.TypedKind.f32 },
        .{ "Float64Array", zvalue.TypedKind.f64 },
        .{ "BigInt64Array", zvalue.TypedKind.i64 },
        .{ "BigUint64Array", zvalue.TypedKind.u64 },
    }) |e| {
        const cctx = try self.arena_state.allocator().create(TypedArrayCtorCtx);
        cctx.* = .{ .interp = self, .kind = e[1], .name = e[0] };
        const ctor = try self.gcNewFunction(.{
            .ctx = cctx,
            .name = e[0],
            .arity = 3,
            .call = typedArrayConstructor,
            .constructable = true,
        });
        try g.define(arena, e[0], ctor);
    }
}
