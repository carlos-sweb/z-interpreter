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
const callCallback = builtin_helpers.callCallback;
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
const hasIteratorMethod = builtin_helpers.hasIteratorMethod;
const ArrayIterCtx = builtin_helpers.ArrayIterCtx;
const arrayIterNext = builtin_helpers.arrayIterNext;
const iteratorSelfBuiltin = builtin_helpers.iteratorSelfBuiltin;
const normIndex = builtins.normIndex;

pub const array_buffer_methods = std.StaticStringMap(MethodSpec).initComptime(.{
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
    return self.gcNewArrayBuffer(byte_length);
}

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
    // Real ToIntegerOrInfinity clamping (negative/over-length indices
    // wrap/clamp instead of erroring) is not implemented -- narrowed to
    // already-in-range indices, matching this repo's existing ToIndex
    // narrowing elsewhere; out-of-range is a real RangeError here rather
    // than a silent clamp.
    const copy = src.slice(self.gc_allocator, @min(start, len), @min(end, len)) catch |e| return self.bufferErr(e);
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
    return self.gcNewDataView(buffer_arg.retain(), byte_offset, byte_length) catch |e| self.bufferErr(e);
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
    const value = try toInt8Wrap(arg(args, 1));
    dv.setInt8(offset, value) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}
fn dataViewSetUint8(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setUint8");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value = try toUint8Wrap(arg(args, 1));
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
    const value = try toInt16Wrap(arg(args, 1));
    dv.setInt16(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}
fn dataViewSetUint16(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setUint16");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value = try toUint16Wrap(arg(args, 1));
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
    const value: i32 = try coercion.toInt32(arg(args, 1));
    dv.setInt32(offset, value, coercion.isTruthy(arg(args, 2))) catch |e| return self.bufferErr(e);
    return JSValue.UNDEFINED;
}
fn dataViewSetUint32(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const dv = try requireDataView(self, this_value, "setUint32");
    const offset = try toByteIndexArg(self, arg(args, 0), "byteOffset");
    const value: u32 = try coercion.toUint32(arg(args, 1));
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
    const value: f32 = @floatCast(try coercion.toNumber(arg(args, 1)));
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
    const value: f64 = try coercion.toNumber(arg(args, 1));
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
        return self.gcNewTypedArray(first.retain(), byte_offset, len, kind) catch |e| self.bufferErr(e);
    }

    if (first == .undefined or first == .number) {
        const n: usize = if (first == .undefined) 0 else try toByteIndexArg(self, first, "length");
        const buf = try self.gcNewArrayBuffer(n * elem_size);
        return self.gcNewTypedArray(buf, 0, n, kind) catch |e| {
            buf.deinit();
            return self.bufferErr(e);
        };
    }

    // Non-iterable array-like (`{length:3, 0:1, ...}`, no @@iterator):
    // allocate the buffer FIRST, matching real spec order
    // (AllocateTypedArrayBuffer happens before InitializeTypedArray-
    // FromArrayLike's per-index Get loop) -- an absurd `length`
    // (`new Int32Array({length: 2**53})`) then fails fast via the
    // allocator itself refusing an impossible byte request, instead of
    // looping `length` times BEFORE ever attempting the allocation
    // (which would time out for any length past a few million).
    if (first == .object and !(try hasIteratorMethod(self, first))) {
        const len_v = try self.getProperty(first, "length");
        defer len_v.deinit();
        const len = try toLength(self, len_v);
        // Real spec (AllocateArrayBuffer): "If it is not possible to
        // create a Data Block of size byteLength bytes, throw a
        // RangeError" -- an allocation failure here is exactly that
        // case (`toLength` already clamped `len` to 2^53-1, so
        // `len * elem_size` can legitimately be an impossible request),
        // not an unrecoverable engine error.
        const buf = self.gcNewArrayBuffer(len * elem_size) catch return self.throwError(.range_error, "Invalid typed array length: {d}", .{len});
        const ta = self.gcNewTypedArray(buf, 0, len, kind) catch |e| {
            buf.deinit();
            return self.bufferErr(e);
        };
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const key = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(key);
            const v = try self.getProperty(first, key);
            defer v.deinit();
            typedElemSet(self, kind, &buf.array_buffer.value, 0, len, i, v) catch |e| {
                ta.deinit();
                return e;
            };
        }
        return ta;
    }

    // Iterable: copy element VALUES (coerced per kind, going through
    // the exact same conversion writes do), never a raw byte
    // reinterpretation -- `new Int32Array(new Uint8Array([1,2,3]))` is
    // `[1,2,3]`, not an empty/aliased view.
    const items = try self.iterableItems(first);
    defer self.gc_allocator.free(items);
    const buf = try self.gcNewArrayBuffer(items.len * elem_size);
    const ta = self.gcNewTypedArray(buf, 0, items.len, kind) catch |e| {
        buf.deinit();
        return self.bufferErr(e);
    };
    for (items, 0..) |item, i| {
        typedElemSet(self, kind, &buf.array_buffer.value, 0, items.len, i, item) catch |e| {
            ta.deinit();
            return e;
        };
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
    return self.gcNewTypedArray(buf, 0, len, kind) catch |e| {
        buf.deinit();
        return self.bufferErr(e);
    };
}

fn taForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) _ = try callCallback(cb, allocator, try taGet(self, this_value, i), i, this_value);
    return JSValue.UNDEFINED;
}

fn taMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "map");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    const result = try newSameKindTypedArray(self, box.kind, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try callCallback(cb, allocator, try taGet(self, this_value, i), i, this_value);
        try taWrite(self, result, i, v);
    }
    return result;
}

fn taFilter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "filter");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    var kept: std.ArrayList(JSValue) = .empty;
    defer kept.deinit(allocator);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try taGet(self, this_value, i);
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) try kept.append(allocator, item);
    }
    const result = try newSameKindTypedArray(self, box.kind, kept.items.len);
    for (kept.items, 0..) |item, idx| try taWrite(self, result, idx, item);
    return result;
}

fn taFind(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "find");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try taGet(self, this_value, i);
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return item;
    }
    return JSValue.UNDEFINED;
}

fn taFindIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "findIndex");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (coercion.isTruthy(try callCallback(cb, allocator, try taGet(self, this_value, i), i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn taFindLast(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "findLast");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    var i = taLen(this_value);
    while (i > 0) {
        i -= 1;
        const item = try taGet(self, this_value, i);
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return item;
    }
    return JSValue.UNDEFINED;
}

fn taFindLastIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "findLastIndex");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    var i = taLen(this_value);
    while (i > 0) {
        i -= 1;
        if (coercion.isTruthy(try callCallback(cb, allocator, try taGet(self, this_value, i), i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn taSome(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "some");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (coercion.isTruthy(try callCallback(cb, allocator, try taGet(self, this_value, i), i, this_value))) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

fn taEvery(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "every");
    const cb = try requireCallback(ctx, args);
    const self = interp(ctx);
    const len = taLen(this_value);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!coercion.isTruthy(try callCallback(cb, allocator, try taGet(self, this_value, i), i, this_value))) return JSValue.fromBool(false);
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
    const target = arg(args, 0);
    var i: usize = 0;
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
    const target = arg(args, 0);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (zvalue.equality.sameValueZero(try taGet(self, this_value, i), target)) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

fn taLastIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireTypedArray(ctx, this_value, "lastIndexOf");
    const self = interp(ctx);
    const target = arg(args, 0);
    var i = taLen(this_value);
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
    const rel = toIntSat(try coercion.toNumber(arg(args, 0)));
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
    const sep = if (arg(args, 0) == .string) arg(args, 0).string.value.data else ",";
    return taJoinWith(interp(ctx), allocator, this_value, sep);
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
    const len = taLen(this_value);
    const val = arg(args, 0);
    const start = if (arg(args, 1) == .undefined) 0 else normIndex(try coercion.toNumber(arg(args, 1)), len);
    const end = if (arg(args, 2) == .undefined) len else normIndex(try coercion.toNumber(arg(args, 2)), len);
    var i = start;
    while (i < end) : (i += 1) try taWrite(self, this_value, i, val);
    return this_value.retain();
}

fn taCopyWithin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "copyWithin");
    const self = interp(ctx);
    const len = taLen(this_value);
    const target = normIndex(try coercion.toNumber(arg(args, 0)), len);
    const start = if (arg(args, 1) == .undefined) 0 else normIndex(try coercion.toNumber(arg(args, 1)), len);
    const end = if (arg(args, 2) == .undefined) len else normIndex(try coercion.toNumber(arg(args, 2)), len);
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
fn taSortLess(allocator: Allocator, cmp: JSValue, kind: zvalue.TypedKind, a: JSValue, b: JSValue) anyerror!bool {
    if (cmp == .function) {
        const r = try cmp.function.value.call(cmp.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ a, b });
        return (try coercion.toNumber(r)) < 0;
    }
    if (kind.isBigInt()) return a.bigint.value.cmp(b.bigint.value) == .lt;
    if (std.math.isNan(a.number)) return false;
    if (std.math.isNan(b.number)) return true;
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
            const before = try taSortLess(allocator, cmp, box.kind, key, tmp[j - 1]);
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

/// `TypedArray.prototype.set(source, offset=0)`: copies element VALUES
/// (per-kind coerced, like every other write path) from `source` into
/// `this` starting at `offset`. Source values are all materialized FIRST,
/// which correctly handles the same-buffer-overlap case by construction
/// (same trick `copyWithin` uses) without needing to detect overlap
/// explicitly.
fn taSetMethod(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireTypedArray(ctx, this_value, "set");
    const self = interp(ctx);
    const len = taLen(this_value);
    const source = arg(args, 0);
    const offset_n = if (arg(args, 1) == .undefined) 0 else try coercion.toNumber(arg(args, 1));
    if (std.math.isNan(offset_n) or offset_n < 0 or offset_n > @as(f64, @floatFromInt(len))) {
        return self.throwError(.range_error, "Offset is out of bounds", .{});
    }
    const offset: usize = @intFromFloat(offset_n);

    var values: std.ArrayList(JSValue) = .empty;
    defer values.deinit(allocator);
    if (source == .typed_array) {
        const slen = source.typed_array.value.len;
        var i: usize = 0;
        while (i < slen) : (i += 1) try values.append(allocator, try taGet(self, source, i));
    } else {
        const items = try self.iterableItems(source);
        defer self.gc_allocator.free(items);
        try values.appendSlice(allocator, items);
    }
    if (offset + values.items.len > len) return self.throwError(.range_error, "Source is too large", .{});
    for (values.items, 0..) |v, i| try taWrite(self, this_value, offset + i, v);
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
    const start = if (arg(args, 0) == .undefined) 0 else normIndex(try coercion.toNumber(arg(args, 0)), len);
    const end = if (arg(args, 1) == .undefined) len else normIndex(try coercion.toNumber(arg(args, 1)), len);
    const count = if (end > start) end - start else 0;
    const new_byte_offset = box.byte_offset + start * box.kind.elemSize();
    return self.gcNewTypedArray(box.owner.retain(), new_byte_offset, count, box.kind) catch |e| self.bufferErr(e);
}

/// A COPY into a fresh buffer (unlike `subarray`).
fn taSlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireTypedArray(ctx, this_value, "slice");
    const self = interp(ctx);
    const box = this_value.typed_array.value;
    const len = box.len;
    const start = if (arg(args, 0) == .undefined) 0 else normIndex(try coercion.toNumber(arg(args, 0)), len);
    const end = if (arg(args, 1) == .undefined) len else normIndex(try coercion.toNumber(arg(args, 1)), len);
    const count = if (end > start) end - start else 0;
    const result = try newSameKindTypedArray(self, box.kind, count);
    var i: usize = 0;
    while (i < count) : (i += 1) try taWrite(self, result, i, try taGet(self, this_value, start + i));
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
    .{ "toLocaleString", MethodSpec{ .call = taToStringMethod, .arity = 0 } },
    .{ "toString", MethodSpec{ .call = taToStringMethod, .arity = 0 } },
    .{ "values", MethodSpec{ .call = taValues, .arity = 0 } },
});

/// Installs `ArrayBuffer`, `DataView`, and the 10 TypedArray constructors.
pub fn install(self: *Interpreter) !void {
    const arena = self.gc_allocator;
    const g = self.global_env;
    // `new ArrayBuffer(byteLength)` / `new DataView(buffer, byteOffset,
    // byteLength)` -- both reject a bare (non-new) call, same pattern as
    // Proxy above. TypedArray constructors are a separate, not-yet-
    // started follow-up phase.
    _ = try installBuiltin(self, .{ .name = "ArrayBuffer", .ctor = .{ .arity = 1, .call = arrayBufferConstructor, .constructable = true } });
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
            .arity = 1,
            .call = typedArrayConstructor,
            .constructable = true,
        });
        try g.define(arena, e[0], ctor);
    }
}
