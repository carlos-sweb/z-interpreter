//! Cross-domain shared helpers extracted from builtins.zig
//! (z-interpreter-refactor.md, Step 5 Phase A prep). Everything here is
//! used by more than one JS-type domain -- generic receiver-guard
//! constructors, numeric coercion shared by BigInt/ArrayBuffer/DataView/
//! TypedArray, array-like/iterator helpers shared by Array/TypedArray/
//! Function, and the declarative BuiltinSpec/installBuiltin table used by
//! every domain's setupGlobals wiring. Single-domain requireX guards
//! (requireArray, requireDate, ...) stay with their own domain file.

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

pub const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;

/// The reserved symbol-key encoding (`\x00S<ptr>`) -- invisible to
/// string-keyed reflection (keys/values/entries/getOwnPropertyNames).
pub fn isSymbolKey(k: []const u8) bool {
    return k.len > 0 and k[0] == 0;
}

/// z-interpreter-refactor.md, Step 4: `setupGlobals` calls `gcNewFunction`
/// ~30 times, each usually followed by the same ceremony --
/// `functionStatics` + a loop of `dneMethod`/`dneConst`, then `g.define`.
/// `BuiltinSpec`/`installBuiltin` below turn that ceremony into data for
/// the shapes that are genuinely uniform across types:
///   - a statics-only namespace object with no constructor at all
///     (console/Math/JSON/Reflect: `ctor = null`)
///   - a constructor with no statics (Function/ArrayBuffer/Proxy/...)
///   - a constructor with a flat list of static methods/constants
///     (Array/Promise/String/Number/BigInt/Symbol's `for`/`keyFor`)
///
/// Phase A finding (validated against the hardest real cases before
/// writing this, not guessed): forcing EVERY setupGlobals entry through
/// one schema would be the wrong kind of generic. Left hand-written,
/// deliberately, because they don't fit this shape without distorting
/// it:
///   - **TypedArray** (11 constructors): each needs its own freshly
///     allocated `ctx` (a `{interp, kind, name}` struct), not the shared
///     `self` every other constructor uses -- `BuiltinSpec` has no slot
///     for a per-entry ctx factory, and adding one just for this single
///     caller wouldn't be a net simplification.
///   - **Error family** (7 constructors): `call` is itself a function
///     *generator* (`errorConstructor(kind)`), not a plain `NativeFn` --
///     already about as declarative as it needs to be via its own small
///     inline-for tuple list.
///   - **Object**: its constructor and prototype must exist BEFORE
///     anything else in `setupGlobals` runs (every other ordinary object
///     chains to `Object.prototype`) -- a real ordering dependency, not
///     ceremony.
///   - **Symbol**: installing its well-known-symbol statics has a real
///     side effect on two `Interpreter` fields (`symbol_iterator`/
///     `symbol_async_iterator`), which a generic static-value entry
///     can't express without adding an escape hatch just for one caller.
///   - **eval**: not a constructor at all (a plain global function via
///     `native()`), with its own `self.eval_fn` retain -- outside this
///     schema's scope entirely.
pub const BuiltinSpec = struct {
    name: []const u8,
    /// `null` = a statics-only namespace object (no constructor function
    /// at all) -- the statics list below installs directly onto it.
    ctor: ?struct {
        arity: usize = 0,
        call: NativeFn,
        constructable: bool = false,
    } = null,
    statics: []const StaticEntry = &.{},

    const StaticEntry = struct {
        name: []const u8,
        value: union(enum) { method: native_helpers.MethodSpec, constant: JSValue },
    };
};

/// Builds `spec.name` (a namespace object or a constructor function, per
/// `spec.ctor`), installs every static, and defines it as a global.
/// Returns the value in case a caller needs it for something beyond this
/// (e.g. capturing a constructor to read its `.prototype` back later) --
/// most callers just `try installBuiltin(self, ...)` and discard it.
pub fn installBuiltin(self: *Interpreter, comptime spec: BuiltinSpec) !JSValue {
    const value: JSValue = if (spec.ctor) |c|
        try self.gcNewFunction(.{ .ctx = self, .name = spec.name, .arity = c.arity, .call = c.call, .constructable = c.constructable })
    else
        try self.ordinaryObject();

    if (spec.statics.len > 0) {
        const bag = if (spec.ctor != null) try self.functionStatics(value) else value;
        inline for (spec.statics) |s| {
            switch (s.value) {
                .method => |m| try dneMethod(bag, s.name, try native(self, s.name, m.arity, m.call)),
                .constant => |v| try dneConst(bag, s.name, v),
            }
        }
    }
    try self.global_env.define(self.gc_allocator, spec.name, value);
    return value;
}

/// Define a builtin method/namespace property: NON-enumerable, writable,
/// configurable -- the spec attributes for e.g. Object.keys, Date.now,
/// Math.floor, Array.prototype.* (so `Object.keys(Date)` is empty and
/// verifyProperty sees enumerable:false).
pub fn dneMethod(obj: JSValue, name: []const u8, value: JSValue) !void {
    try obj.asObject().value.defineProperty(name, value, .{ .writable = true, .enumerable = false, .configurable = true });
}

/// Define a builtin constant: NON-enumerable, NON-writable, NON-configurable
/// (Number.MAX_SAFE_INTEGER, Math.PI, the well-known Symbols, ...).
pub fn dneConst(obj: JSValue, name: []const u8, value: JSValue) !void {
    try obj.asObject().value.defineProperty(name, value, .{ .writable = false, .enumerable = false, .configurable = false });
}

pub fn requireTag(ctx: *anyopaque, this_value: JSValue, comptime expected_tag: JSValue.Tag, comptime message: []const u8, method: []const u8) anyerror!JSValue {
    if (this_value.tag() != expected_tag) {
        return interp(ctx).throwError(.type_error, message, .{method});
    }
    return this_value;
}

/// Same shape as `requireTag`, but first unwraps a `new String()`/
/// `new Number()`/`new Boolean()` primitive-wrapper object (see
/// `Interpreter.unboxPrimitiveWrapper`'s doc) before checking the tag --
/// shared by the 3 primitive-prototype guards that need to accept both
/// `"x".toUpperCase()` and `new String("x").toUpperCase()`.
pub fn requirePrimitive(ctx: *anyopaque, this_value: JSValue, comptime expected_tag: JSValue.Tag, comptime message: []const u8, method: []const u8) anyerror!JSValue {
    const v: JSValue = if (this_value.tag() == expected_tag) this_value else interp(ctx).unboxPrimitiveWrapper(this_value) orelse this_value;
    if (v.tag() != expected_tag) {
        return interp(ctx).throwError(.type_error, message, .{method});
    }
    return v;
}

pub fn requireCallback(ctx: *anyopaque, args: []const JSValue) anyerror!JSValue {
    const cb = arg(args, 0);
    if (!cb.isFunction()) return interp(ctx).throwError(.type_error, "callback is not a function", .{});
    return cb;
}

pub fn callCallback(cb: JSValue, allocator: Allocator, item: JSValue, index: usize, receiver: JSValue) anyerror!JSValue {
    return cb.asFunction().value.call(cb.asFunction().value.ctx, allocator, JSValue.UNDEFINED, &.{
        item, JSValue.fromNumber(@floatFromInt(index)), receiver,
    });
}

pub fn callCallbackWithThis(cb: JSValue, allocator: Allocator, this_arg: JSValue, item: JSValue, index: usize, receiver: JSValue) anyerror!JSValue {
    return cb.asFunction().value.call(cb.asFunction().value.ctx, allocator, this_arg, &.{
        item, JSValue.fromNumber(@floatFromInt(index)), receiver,
    });
}

/// ECMA ToIntegerOrInfinity saturated into isize, so `@intFromFloat` can't
/// panic on NaN / +/-Infinity / out-of-i64-range floats (NaN -> 0). Callers
/// that need a length clamp non-negative afterwards.
pub fn toIntSat(n: f64) isize {
    if (std.math.isNan(n)) return 0;
    const maxf: f64 = @floatFromInt(std.math.maxInt(isize));
    const minf: f64 = @floatFromInt(std.math.minInt(isize));
    if (n >= maxf) return std.math.maxInt(isize);
    if (n <= minf) return std.math.minInt(isize);
    return @intFromFloat(@trunc(n));
}

/// `BigInt(value)` -- unlike String/Number/Boolean, never reached via
/// `new` (the constructor isn't `constructable` at all, see its
/// registration), so there's no hollow-wrapper case to handle here.
/// ECMA-262 ToBigInt -- used by `BigInt.asIntN`/`asUintN`'s own
/// `bigint` parameter, and by everything the `BigInt(value)` global
/// itself doesn't special-case. Real ToBigInt REJECTS Number with a
/// TypeError (`BigInt.asUintN(8, 5)` really does throw in Node) --
/// Number only converts via the DIFFERENT NumberToBigInt algorithm the
/// `BigInt(value)` constructor call runs instead, never through this.
/// ECMA-262 ToBigInt: reduce a non-primitive `a_in` via ToPrimitive(hint
/// number) FIRST -- this is what makes an object's `.valueOf()` returning
/// a bigint directly succeed, and makes an unconvertible plain object
/// fall through to the SAME SyntaxError a literal `"[object Object]"`
/// string already gets below (confirmed against real Node: both give the
/// identical error). `a_in` is borrowed; the reduced primitive is freed
/// here if this function produced it.
pub fn toBigIntValue(self: *Interpreter, allocator: Allocator, a_in: JSValue) anyerror!JSValue {
    const owned = !Interpreter.isPrimitiveTag(a_in);
    const a = if (owned) try self.toPrimitive(a_in, .number) else a_in;
    defer if (owned) a.deinit();
    return switch (a.unpack()) {
        .bigint => a.retain(),
        .boolean => |b| self.gcNewBigIntValue(try zbigint.ZBigInt.fromInt(self.gc_allocator, if (b) 1 else 0)),
        .string => |box| {
            const v = zbigint.ZBigInt.fromEcmaString(self.gc_allocator, box.value.data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.throwError(.syntax_error, "Cannot convert {s} to a BigInt", .{box.value.data}),
            };
            return self.gcNewBigIntValue(v);
        },
        .undefined => self.throwError(.type_error, "Cannot convert undefined to a BigInt", .{}),
        .null => self.throwError(.type_error, "Cannot convert null to a BigInt", .{}),
        .number => {
            const shown = try coercion.toDisplayString(allocator, a);
            defer allocator.free(shown);
            return self.throwError(.type_error, "Cannot convert {s} to a BigInt", .{shown});
        },
        .symbol => |box| {
            const shown = try box.value.toString(allocator);
            defer allocator.free(shown);
            return self.throwError(.type_error, "Cannot convert {s} to a BigInt", .{shown});
        },
        else => unreachable, // `a` is a ToPrimitive result: always primitive.
    };
}

/// ECMA-262 7.1.4 ToNumber: invokes ToPrimitive(v, number) for objects and
/// throws TypeError on Symbol or BigInt (unlike `coercion.toNumber` which
/// permits BigInt->f64 for internal helpers).
pub fn toNumberStrict(self: *Interpreter, v: JSValue) anyerror!f64 {
    const prim = if (Interpreter.isPrimitiveTag(v)) v.retain() else try self.toPrimitive(v, .number);
    defer prim.deinit();
    if (prim.isSymbol() or prim.isBigInt()) {
        return self.throwError(.type_error, "Cannot convert a {s} value to a number", .{@tagName(prim.tag())});
    }
    return try self.toNumberJS(prim);
}

/// ECMA-262 ToIndex: ToIntegerOrInfinity (real ToNumber, so an object
/// with valueOf/@@toPrimitive works, a fractional number truncates
/// toward zero, and NaN becomes +0 -- NOT "must already be an integer
/// Number", which is what this function used to require, rejecting
/// strings/objects outright and rejecting fractional/NaN numbers with a
/// RangeError instead of ECMA's own conversion rules) -- then range-check
/// against [0, 2^53-1]. Checked BEFORE @intFromFloat, which panics (not
/// an error) on a magnitude that doesn't fit in the target type.
pub fn toByteIndexArg(self: *Interpreter, v: JSValue, what: []const u8) anyerror!usize {
    const n = try toNumberStrict(self, v);
    const integer: f64 = if (std.math.isNan(n)) 0 else @trunc(n);
    const max_index: f64 = 9007199254740991.0;
    if (integer < 0 or integer > max_index) {
        return self.throwError(.range_error, "Invalid {s}: must be a non-negative safe integer", .{what});
    }
    return @intFromFloat(integer);
}

/// ECMA-262 ToInt8/ToUint8/ToInt16/ToUint16: same modulo-2^n wraparound
/// technique as `coercion.toInt32`/`toUint32` (NOT saturating, NOT
/// clamping -- `DataView` has no "clamped" variant, that's
/// `Uint8ClampedArray`-only and belongs to the future TypedArray phase).
pub fn toUint8Wrap(self: *Interpreter, v: JSValue) anyerror!u8 {
    return @truncate(try self.toUint32JS(v));
}

pub fn toInt8Wrap(self: *Interpreter, v: JSValue) anyerror!i8 {
    return @bitCast(try toUint8Wrap(self, v));
}

pub fn toUint16Wrap(self: *Interpreter, v: JSValue) anyerror!u16 {
    return @truncate(try self.toUint32JS(v));
}

pub fn toInt16Wrap(self: *Interpreter, v: JSValue) anyerror!i16 {
    return @bitCast(try toUint16Wrap(self, v));
}

/// ECMA-262 ToUint8Clamp: NaN -> 0, clamped to [0,255], round-half-to-
/// EVEN at the .5 boundary (2.5 -> 2, 3.5 -> 4) -- the one JS-specific
/// numeric conversion `Uint8ClampedArray` needs that nothing else in
/// this engine has built yet (plain `Uint8Array` WRAPS modulo 256 via
/// `toUint8Wrap` above; `Uint8ClampedArray` CLAMPS -- two genuinely
/// different algorithms sharing the same 1-byte storage).
pub fn toUint8Clamp(self: *Interpreter, v: JSValue) anyerror!u8 {
    const n = try self.toNumberJS(v);
    if (std.math.isNan(n) or n <= 0) return 0;
    if (n >= 255) return 255;
    const f = @floor(n);
    if (f + 0.5 < n) return @intFromFloat(f + 1);
    if (n < f + 0.5) return @intFromFloat(f);
    const fi: u8 = @intFromFloat(f);
    return if (fi % 2 == 0) fi else fi + 1;
}

/// ToBigInt64/ToBigUint64 (ECMA-262 7.1.20/7.1.21): wraps an arbitrary
/// ZBigInt into the low 64 bits, two's complement -- matches real
/// `DataView.setBigInt64`/`setBigUint64` exactly, including values
/// outside the i64/u64 range (real JS wraps rather than throws). Reuses
/// the same mask-via-bitAnd technique `BigInt.asUintN`/`asIntN` already
/// use above, fixed at 64 bits.
pub fn toU64Wrapped(self: *Interpreter, big: zbigint.ZBigInt) anyerror!u64 {
    var one = try zbigint.ZBigInt.fromInt(self.gc_allocator, 1);
    defer one.deinit();
    var shifted = try zbigint.ZBigInt.shiftLeft(self.gc_allocator, one, 64);
    defer shifted.deinit();
    var mask = try zbigint.ZBigInt.sub(self.gc_allocator, shifted, one);
    defer mask.deinit();
    var masked = try zbigint.ZBigInt.bitAnd(self.gc_allocator, big, mask);
    defer masked.deinit();
    // Guaranteed to fit: masked into [0, 2^64) by construction above.
    return masked.value.toInt(u64) catch unreachable;
}

pub fn toI64Wrapped(self: *Interpreter, big: zbigint.ZBigInt) anyerror!i64 {
    return @bitCast(try toU64Wrapped(self, big));
}

/// Boxes a raw `u64` as a real (conceptually unsigned) BigInt.
/// `ZBigInt.fromInt` takes `i64` -- a u64 above i64's max reinterprets
/// as negative there, so route through the same bit pattern deliberately
/// (u64 -> i64 bit-for-bit) and correct the sign by adding 2^64.
pub fn bigIntFromU64(self: *Interpreter, v: u64) anyerror!JSValue {
    if (v <= std.math.maxInt(i64)) {
        return self.gcNewBigIntValue(try zbigint.ZBigInt.fromInt(self.gc_allocator, @intCast(v)));
    }
    var lo = try zbigint.ZBigInt.fromInt(self.gc_allocator, @bitCast(v));
    defer lo.deinit();
    var two_64 = try zbigint.ZBigInt.fromInt(self.gc_allocator, 1);
    defer two_64.deinit();
    var shifted = try zbigint.ZBigInt.shiftLeft(self.gc_allocator, two_64, 64);
    defer shifted.deinit();
    return self.gcNewBigIntValue(try zbigint.ZBigInt.add(self.gc_allocator, lo, shifted));
}

pub fn typedView(comptime T: type, buffer: *zbuffer.ArrayBuffer, byte_offset: usize, len: usize) zbuffer.TypedArrayView(T) {
    return .{ .buffer = buffer, .byte_offset = byte_offset, .len = len };
}

/// Reads element `index` (already bounds-checked by the caller against
/// `len` -- `BufferError.OutOfBounds` here would be an internal-
/// invariant violation, not a JS-facing condition, since real spec
/// out-of-range reads are `undefined` handled entirely at the
/// getProperty call site, never reaching this far).
pub fn isTypedArrayDetached(ta: anytype) bool {
    return ta.owner.isArrayBuffer() and ta.owner.asArrayBuffer().value.isDetached();
}

pub fn typedElemGet(self: *Interpreter, kind: zvalue.TypedKind, buffer: *zbuffer.ArrayBuffer, byte_offset: usize, len: usize, index: usize) anyerror!JSValue {
    if (buffer.isDetached()) return JSValue.UNDEFINED;
    return switch (kind) {
        .i8 => JSValue.fromNumber(@floatFromInt(typedView(i8, buffer, byte_offset, len).get(index) catch unreachable)),
        .u8, .u8_clamped => JSValue.fromNumber(@floatFromInt(typedView(u8, buffer, byte_offset, len).get(index) catch unreachable)),
        .i16 => JSValue.fromNumber(@floatFromInt(typedView(i16, buffer, byte_offset, len).get(index) catch unreachable)),
        .u16 => JSValue.fromNumber(@floatFromInt(typedView(u16, buffer, byte_offset, len).get(index) catch unreachable)),
        .i32 => JSValue.fromNumber(@floatFromInt(typedView(i32, buffer, byte_offset, len).get(index) catch unreachable)),
        .u32 => JSValue.fromNumber(@floatFromInt(typedView(u32, buffer, byte_offset, len).get(index) catch unreachable)),
        .f32 => JSValue.fromNumber(typedView(f32, buffer, byte_offset, len).get(index) catch unreachable),
        .f64 => JSValue.fromNumber(typedView(f64, buffer, byte_offset, len).get(index) catch unreachable),
        .i64 => self.gcNewBigIntValue(try zbigint.ZBigInt.fromInt(self.gc_allocator, typedView(i64, buffer, byte_offset, len).get(index) catch unreachable)),
        .u64 => bigIntFromU64(self, typedView(u64, buffer, byte_offset, len).get(index) catch unreachable),
    };
}

/// Writes element `index` -- unlike `typedElemGet`, the CALLER does NOT
/// pre-check bounds: `value` is coerced UNCONDITIONALLY first (real
/// spec: `IntegerIndexedElementSet` converts the value before checking
/// the index, so a conversion that throws does so even for an out-of-
/// range index -- verified against real Node), and an out-of-range
/// index is then a silent no-op (never a throw, matches spec exactly).
pub fn typedElemSet(self: *Interpreter, kind: zvalue.TypedKind, buffer: *zbuffer.ArrayBuffer, byte_offset: usize, len: usize, index: usize, value: JSValue) anyerror!void {
    // Real spec: ToNumber(Symbol) (or ToBigInt(Symbol) for the i64/u64
    // kinds) is a TypeError, e.g. `ta[0] = Symbol()` -- pre-existing gap
    // found while verifying array-like TypedArray construction (which
    // newly reaches this coercion for element values read off a plain
    // object): every per-kind branch below bottoms out in
    // `coercion.toNumber`/`toBigIntValue`, neither of which has a
    // catchable throw for Symbol today (`error.NotImplemented`, which
    // is uncatchable from JS). Guarded once here rather than in each of
    // the 8 branches.
    if (value.isSymbol()) return self.throwError(.type_error, "Cannot convert a Symbol value to a {s}", .{if (kind.isBigInt()) "BigInt" else "number"});
    const num_val: JSValue = if (kind.isBigInt()) JSValue.UNDEFINED else JSValue.fromNumber(try toNumberStrict(self, value));
    if (buffer.isDetached()) return;
    switch (kind) {
        .i8 => {
            const v = try toInt8Wrap(self, num_val);
            typedView(i8, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .u8 => {
            const v = try toUint8Wrap(self, num_val);
            typedView(u8, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .u8_clamped => {
            const v = try toUint8Clamp(self, num_val);
            typedView(u8, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .i16 => {
            const v = try toInt16Wrap(self, num_val);
            typedView(i16, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .u16 => {
            const v = try toUint16Wrap(self, num_val);
            typedView(u16, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .i32 => {
            const v = try self.toInt32JS(num_val);
            typedView(i32, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .u32 => {
            const v = try self.toUint32JS(num_val);
            typedView(u32, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .f32 => {
            const v: f32 = @floatCast(num_val.asNumber());
            typedView(f32, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .f64 => {
            const v = num_val.asNumber();
            typedView(f64, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .i64 => {
            const x = try toBigIntValue(self, self.gc_allocator, value);
            defer x.deinit();
            const v = try toI64Wrapped(self, x.asBigInt().value);
            typedView(i64, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
        .u64 => {
            const x = try toBigIntValue(self, self.gc_allocator, value);
            defer x.deinit();
            const v = try toU64Wrapped(self, x.asBigInt().value);
            typedView(u64, buffer, byte_offset, len).set(index, v) catch |e| return oobIsNoop(e);
        },
    }
}

/// `zbuffer`'s `.set()` only ever fails with `OutOfBounds` on an
/// already-validly-constructed view (never `Misaligned`/`OutOfMemory` --
/// those are init-time-only concerns) -- and per real spec, an
/// out-of-range indexed TypedArray write is a silent no-op, never a
/// throw.
pub fn oobIsNoop(e: zbuffer.BufferError) anyerror!void {
    return switch (e) {
        error.OutOfBounds => {},
        error.Misaligned, error.OutOfMemory => unreachable,
    };
}

/// ECMA-262 7.1.20 ToLength: ToNumber then clamp to [0, 2^53-1], floor.
/// Distinct from `toIntSat` (no ToNumber coercion, isize range, no
/// 2^53-1 cap) and `toByteIndexArg` (throws instead of clamping) --
/// this one matches how a real `length` read behaves: a
/// string/undefined/negative/fractional length never throws. A Symbol
/// `length` DOES throw in real JS (`ToNumber(Symbol)` is a TypeError,
/// e.g. `new Int32Array({length: Symbol()})`) -- `coercion.toNumber`
/// only has an uncatchable `error.NotImplemented` for that today, so it
/// must be mapped to a real, catchable TypeError here.
pub fn toLength(self: *Interpreter, v: JSValue) anyerror!usize {
    const n = try toNumberStrict(self, v);
    if (std.math.isNan(n) or n <= 0) return 0;
    return @intFromFloat(@min(@floor(n), 9007199254740991.0));
}

/// `GetMethod(value, @@iterator)` narrowed to "does @@iterator resolve
/// to a callable" -- the real spec's iterator-vs-array-like decision
/// point for Array.from / the TypedArray constructor. Properly
/// `.deinit()`s the probed value (getProperty always returns owned).
pub fn hasIteratorMethod(self: *Interpreter, value: JSValue) anyerror!bool {
    const sym = self.symbol_iterator orelse return false;
    const key = try self.encodeKey(sym);
    defer self.gc_allocator.free(key);
    const m = try self.getProperty(value, key);
    defer m.deinit();
    return m.isFunction();
}

/// ECMA-262 LengthOfArrayLike + per-index Get -- the array-like
/// fallback used when `value` has no @@iterator. Returns an OWNED
/// slice of OWNED/retained items (unlike `iterableItems`'s
/// borrowed-items convention): `getProperty` always returns owned
/// values (an accessor getter can fabricate a brand-new one with no
/// other owner), so treating these as borrowed would risk a stale
/// reference. Caller must `.deinit()` each item AND free the slice.
pub fn arrayLikeToList(self: *Interpreter, allocator: Allocator, value: JSValue) anyerror![]JSValue {
    const len_v = try self.getProperty(value, "length");
    defer len_v.deinit();
    const len = try toLength(self, len_v);
    var out: std.ArrayList(JSValue) = .empty;
    errdefer {
        for (out.items) |it| it.deinit();
        out.deinit(allocator);
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "{d}", .{i});
        defer allocator.free(key);
        try out.append(allocator, try self.getProperty(value, key));
    }
    return out.toOwnedSlice(allocator);
}

pub const IterProtoKind = enum { array, map, set, string };

/// keys()/values()/entries() -- iterator objects with internal slot in
/// `interp.iter_slots`, inheriting `next` from `%ArrayIteratorPrototype%` /
/// `%MapIteratorPrototype%` / `%SetIteratorPrototype%`.
pub const ArrayIterCtx = struct {
    interp: *Interpreter,
    proto_kind: IterProtoKind = .array,
    source: JSValue = JSValue.UNDEFINED,
    items: []const JSValue = &.{},
    index: usize = 0,
    exhausted: bool = false,
    kind: enum { keys, values, entries },
};

fn iterStepFromCtx(ic: *ArrayIterCtx) anyerror!JSValue {
    const self = ic.interp;
    var result = try self.ordinaryObject();
    errdefer result.deinit();
    if (ic.exhausted) {
        try result.asObject().value.set("value", JSValue.UNDEFINED);
        try result.asObject().value.set("done", JSValue.fromBool(true));
        return result;
    }
    switch (ic.source.unpack()) {
        .string => |box| {
            const data = box.value.data;
            if (ic.index >= data.len) {
                ic.exhausted = true;
                try result.asObject().value.set("value", JSValue.UNDEFINED);
                try result.asObject().value.set("done", JSValue.fromBool(true));
                return result;
            }
            const seq_len = std.unicode.utf8ByteSequenceLength(data[ic.index]) catch 1;
            const end = @min(ic.index + seq_len, data.len);
            const ch = try self.gcNewString(data[ic.index..end]);
            ic.index = end;
            try result.asObject().value.set("value", ch);
            try result.asObject().value.set("done", JSValue.fromBool(false));
            return result;
        },
        .array => |box| {
            const len = box.value.length();
            if (ic.index >= len) {
                ic.exhausted = true;
                try result.asObject().value.set("value", JSValue.UNDEFINED);
                try result.asObject().value.set("done", JSValue.fromBool(true));
                return result;
            }
            const i = ic.index;
            ic.index += 1;
            const val: JSValue = switch (ic.kind) {
                .keys => JSValue.fromNumber(@floatFromInt(i)),
                .values => blk: {
                    var buf: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                    break :blk try self.getProperty(ic.source, key);
                },
                .entries => blk: {
                    var buf: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                    const el = try self.getProperty(ic.source, key);
                    var pair = try self.gcNewArray();
                    _ = try pair.asArray().value.push(JSValue.fromNumber(@floatFromInt(i)));
                    _ = try pair.asArray().value.push(el);
                    break :blk pair;
                },
            };
            try result.asObject().value.set("value", val);
            try result.asObject().value.set("done", JSValue.fromBool(false));
            return result;
        },
        .typed_array => |box| {
            if (isTypedArrayDetached(&box.value)) {
                return self.throwError(.type_error, "Cannot iterate over a detached TypedArray", .{});
            }
            const len = box.value.len;
            if (ic.index >= len) {
                ic.exhausted = true;
                try result.asObject().value.set("value", JSValue.UNDEFINED);
                try result.asObject().value.set("done", JSValue.fromBool(true));
                return result;
            }
            const i = ic.index;
            ic.index += 1;
            const val: JSValue = switch (ic.kind) {
                .keys => JSValue.fromNumber(@floatFromInt(i)),
                .values => try typedElemGet(self, box.value.kind, &box.value.owner.asArrayBuffer().value, box.value.byte_offset, len, i),
                .entries => blk: {
                    const el = try typedElemGet(self, box.value.kind, &box.value.owner.asArrayBuffer().value, box.value.byte_offset, len, i);
                    var pair = try self.gcNewArray();
                    _ = try pair.asArray().value.push(JSValue.fromNumber(@floatFromInt(i)));
                    _ = try pair.asArray().value.push(el);
                    break :blk pair;
                },
            };
            try result.asObject().value.set("value", val);
            try result.asObject().value.set("done", JSValue.fromBool(false));
            return result;
        },
        .map => |box| {
            const ks = box.value.keys();
            const vs = box.value.values();
            if (ic.index >= ks.len) {
                ic.exhausted = true;
                try result.asObject().value.set("value", JSValue.UNDEFINED);
                try result.asObject().value.set("done", JSValue.fromBool(true));
                return result;
            }
            const i = ic.index;
            ic.index += 1;
            const val: JSValue = switch (ic.kind) {
                .keys => ks[i].retain(),
                .values => vs[i].retain(),
                .entries => blk: {
                    var pair = try self.gcNewArray();
                    _ = try pair.asArray().value.push(ks[i].retain());
                    _ = try pair.asArray().value.push(vs[i].retain());
                    break :blk pair;
                },
            };
            try result.asObject().value.set("value", val);
            try result.asObject().value.set("done", JSValue.fromBool(false));
            return result;
        },
        .set => |box| {
            const vs = box.value.values();
            if (ic.index >= vs.len) {
                ic.exhausted = true;
                try result.asObject().value.set("value", JSValue.UNDEFINED);
                try result.asObject().value.set("done", JSValue.fromBool(true));
                return result;
            }
            const i = ic.index;
            ic.index += 1;
            const val: JSValue = switch (ic.kind) {
                .keys, .values => vs[i].retain(),
                .entries => blk: {
                    var pair = try self.gcNewArray();
                    _ = try pair.asArray().value.push(vs[i].retain());
                    _ = try pair.asArray().value.push(vs[i].retain());
                    break :blk pair;
                },
            };
            try result.asObject().value.set("value", val);
            try result.asObject().value.set("done", JSValue.fromBool(false));
            return result;
        },
        else => {
            if (ic.index >= ic.items.len) {
                ic.exhausted = true;
                try result.asObject().value.set("value", JSValue.UNDEFINED);
                try result.asObject().value.set("done", JSValue.fromBool(true));
                return result;
            }
            const i = ic.index;
            ic.index += 1;
            const val: JSValue = switch (ic.kind) {
                .keys => JSValue.fromNumber(@floatFromInt(i)),
                .values => ic.items[i].retain(),
                .entries => blk: {
                    var pair = try self.gcNewArray();
                    _ = try pair.asArray().value.push(JSValue.fromNumber(@floatFromInt(i)));
                    _ = try pair.asArray().value.push(ic.items[i].retain());
                    break :blk pair;
                },
            };
            try result.asObject().value.set("value", val);
            try result.asObject().value.set("done", JSValue.fromBool(false));
            return result;
        },
    }
}

pub fn arrayIterNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    const ic: *ArrayIterCtx = @ptrCast(@alignCast(ctx));
    return iterStepFromCtx(ic);
}

fn iterProtoNextImpl(ctx: *anyopaque, this_value: JSValue, expected: IterProtoKind, label: []const u8) anyerror!JSValue {
    const self = interp(ctx);
    if (!this_value.isObject()) {
        return self.throwError(.type_error, "Method {s} Iterator.prototype.next called on incompatible receiver", .{label});
    }
    const ic = self.iter_slots.get(@intFromPtr(this_value.asObject())) orelse {
        return self.throwError(.type_error, "Method {s} Iterator.prototype.next called on incompatible receiver", .{label});
    };
    if (ic.proto_kind != expected) {
        return self.throwError(.type_error, "Method {s} Iterator.prototype.next called on incompatible receiver", .{label});
    }
    return iterStepFromCtx(ic);
}

pub fn arrayIterProtoNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return iterProtoNextImpl(ctx, this_value, .array, "Array");
}

pub fn stringIterProtoNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return iterProtoNextImpl(ctx, this_value, .string, "String");
}

pub fn mapIterProtoNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return iterProtoNextImpl(ctx, this_value, .map, "Map");
}

pub fn setIterProtoNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return iterProtoNextImpl(ctx, this_value, .set, "Set");
}

pub fn makeArrayIterator(self: *Interpreter, allocator: Allocator, this_value: JSValue, kind: @FieldType(ArrayIterCtx, "kind")) anyerror!JSValue {
    const ic = try allocator.create(ArrayIterCtx);
    if (this_value.isArray() or this_value.isTypedArray()) {
        ic.* = .{ .interp = self, .proto_kind = .array, .source = this_value.retain(), .kind = kind };
    } else {
        const len_v = try self.getProperty(this_value, "length");
        defer len_v.deinit();
        const len = try toLength(self, len_v);
        if (len > 4294967295) {
            allocator.destroy(ic);
            return self.throwError(.range_error, "Invalid array length", .{});
        }
        const s = try allocator.alloc(JSValue, len);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            var buf: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            s[i] = try self.getProperty(this_value, key);
        }
        ic.* = .{ .interp = self, .proto_kind = .array, .items = s, .kind = kind };
    }
    try self.gcTrackArrayIterCtx(ic);
    var obj = try self.gcNewObject();
    errdefer obj.deinit();
    const iter_proto = if (self.protos.array_iterator_proto.isObject())
        self.protos.array_iterator_proto
    else
        (self.iterator_prototype orelse JSValue.UNDEFINED);
    if (iter_proto.isObject()) try obj.asObject().value.setPrototype(&iter_proto.asObject().value);
    try self.iter_slots.put(self.gc_allocator, @intFromPtr(obj.asObject()), ic);
    return obj;
}

pub fn makeMapIterator(self: *Interpreter, allocator: Allocator, map_val: JSValue, kind: @FieldType(ArrayIterCtx, "kind")) anyerror!JSValue {
    const ic = try allocator.create(ArrayIterCtx);
    ic.* = .{ .interp = self, .proto_kind = .map, .source = map_val.retain(), .kind = kind };
    try self.gcTrackArrayIterCtx(ic);
    var obj = try self.gcNewObject();
    errdefer obj.deinit();
    const iter_proto = if (self.protos.map_iterator_proto.isObject())
        self.protos.map_iterator_proto
    else
        (self.iterator_prototype orelse JSValue.UNDEFINED);
    if (iter_proto.isObject()) try obj.asObject().value.setPrototype(&iter_proto.asObject().value);
    try self.iter_slots.put(self.gc_allocator, @intFromPtr(obj.asObject()), ic);
    return obj;
}

pub fn makeSetIterator(self: *Interpreter, allocator: Allocator, set_val: JSValue, kind: @FieldType(ArrayIterCtx, "kind")) anyerror!JSValue {
    const ic = try allocator.create(ArrayIterCtx);
    ic.* = .{ .interp = self, .proto_kind = .set, .source = set_val.retain(), .kind = kind };
    try self.gcTrackArrayIterCtx(ic);
    var obj = try self.gcNewObject();
    errdefer obj.deinit();
    const iter_proto = if (self.protos.set_iterator_proto.isObject())
        self.protos.set_iterator_proto
    else
        (self.iterator_prototype orelse JSValue.UNDEFINED);
    if (iter_proto.isObject()) try obj.asObject().value.setPrototype(&iter_proto.asObject().value);
    try self.iter_slots.put(self.gc_allocator, @intFromPtr(obj.asObject()), ic);
    return obj;
}

pub fn makeStringIterator(self: *Interpreter, allocator: Allocator, str_val: JSValue) anyerror!JSValue {
    const ic = try allocator.create(ArrayIterCtx);
    ic.* = .{ .interp = self, .proto_kind = .string, .source = str_val.retain(), .kind = .values };
    try self.gcTrackArrayIterCtx(ic);
    var obj = try self.gcNewObject();
    errdefer obj.deinit();
    const iter_proto = if (self.protos.string_iterator_proto.isObject())
        self.protos.string_iterator_proto
    else
        (self.iterator_prototype orelse JSValue.UNDEFINED);
    if (iter_proto.isObject()) try obj.asObject().value.setPrototype(&iter_proto.asObject().value);
    try self.iter_slots.put(self.gc_allocator, @intFromPtr(obj.asObject()), ic);
    return obj;
}

/// A `[Symbol.iterator]()` returning the receiver -- for builtin iterator
/// objects (mirrors the interpreter's own iteratorSelf).
pub fn iteratorSelfBuiltin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = args;
    return this_value.retain();
}

/// Real `new Proxy(target, handler)` requires BOTH to be "an Object" in
/// spec terms -- which spans every non-primitive JSValue tag in this
/// engine (plain objects, arrays, functions, regexes, maps, sets,
/// errors, dates, promises, even another proxy), not just `.object`.
pub fn isObjectLike(v: JSValue) bool {
    return switch (v.tag()) {
        .undefined, .null, .boolean, .number, .string, .symbol, .bigint => false,
        else => true,
    };
}
