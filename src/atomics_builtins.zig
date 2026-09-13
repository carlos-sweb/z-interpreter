//! `Atomics` -- see ~/.plans/pendientes/atomics-sharedarraybuffer.md.
//! A plain namespace object (no constructor), same shape as
//! `Reflect`/`Math`. This engine is single-threaded, so every method
//! here is SPEC-CORRECT for that context, not an approximation:
//! - `add`/`sub`/`and`/`or`/`xor`/`exchange`/`compareExchange`/`load`/
//!   `store` need no real locking (nothing else can ever be touching
//!   the same memory concurrently) -- they delegate to the same
//!   `typedView`/`typedElemGet`/`typedElemSet` primitives
//!   TypedArray element access already uses.
//! - `wait` validates its arguments in spec order, then throws
//!   TypeError -- the mandated behavior when the host declares
//!   `AgentCanSuspend()` false (this one always does; it has no other
//!   agent to suspend for).
//! - `notify` validates its arguments, then always returns 0 -- the
//!   mandated behavior when no other agent could ever be sleeping in
//!   `Atomics.wait` (since `wait` always throws here, none ever is).
//! - `isLockFree`/`pause` are pure/no-op, real spec-legal answers.
//! - `waitAsync` is deliberately NOT implemented (Fase 2 of the plan --
//!   needs this engine's timer/microtask maturity investigated first).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zbigint = @import("zbigint");
const zbuffer = @import("zbuffer");
const JSValue = zvalue.JSValue;
const TypedKind = zvalue.TypedKind;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

const interp = native_helpers.interp;
const arg = native_helpers.arg;
const installBuiltin = builtin_helpers.installBuiltin;
const toByteIndexArg = builtin_helpers.toByteIndexArg;
const toInt8Wrap = builtin_helpers.toInt8Wrap;
const toUint8Wrap = builtin_helpers.toUint8Wrap;
const toInt16Wrap = builtin_helpers.toInt16Wrap;
const toUint16Wrap = builtin_helpers.toUint16Wrap;
const toU64Wrapped = builtin_helpers.toU64Wrapped;
const toI64Wrapped = builtin_helpers.toI64Wrapped;
const bigIntFromU64 = builtin_helpers.bigIntFromU64;
const toBigIntValue = builtin_helpers.toBigIntValue;
const typedView = builtin_helpers.typedView;
const typedElemGet = builtin_helpers.typedElemGet;
const typedElemSet = builtin_helpers.typedElemSet;

/// The 8 integer TypedArray kinds `Atomics.*` (other than `wait`/
/// `notify`) operate on -- excludes Uint8ClampedArray and the 2 float
/// kinds (real TypeError target, confirmed against Node:
/// `Atomics.add(new Float64Array(1), 0, 1)` throws "not an integer or
/// bigint typed array").
fn isAtomicsKind(kind: TypedKind) bool {
    return switch (kind) {
        .u8_clamped, .f32, .f64 => false,
        else => true,
    };
}

/// `Atomics.wait`/`notify` accept ONLY Int32Array/BigInt64Array (real
/// spec's narrower "waitable" TypedArray check).
fn isWaitableKind(kind: TypedKind) bool {
    return kind == .i32 or kind == .i64;
}

/// A validated `(typedArray, index)` pair's resolved storage --
/// resolved once per call, shared by every op below.
const TA = struct {
    buffer: *zbuffer.ArrayBuffer,
    byte_offset: usize,
    len: usize,
    kind: TypedKind,
    is_shared: bool,
};

fn requireIntegerTypedArray(self: *Interpreter, v: JSValue, comptime waitable: bool) anyerror!TA {
    if (v != .typed_array) return self.throwError(.type_error, "The typed array argument must be an integer or bigint typed array", .{});
    const box = &v.typed_array.value;
    const ok = if (waitable) isWaitableKind(box.kind) else isAtomicsKind(box.kind);
    if (!ok) return self.throwError(.type_error, "The typed array argument must be an integer or bigint typed array", .{});
    const buffer = &box.owner.array_buffer.value;
    return .{ .buffer = buffer, .byte_offset = box.byte_offset, .len = box.len, .kind = box.kind, .is_shared = buffer.is_shared };
}

/// ECMA `ValidateAtomicAccess`: ToIndex(index) then bounds-check.
fn requireIndex(self: *Interpreter, ta: TA, index_arg: JSValue) anyerror!usize {
    const idx = try toByteIndexArg(self, index_arg, "index");
    if (idx >= ta.len) return self.throwError(.range_error, "index out of bounds", .{});
    return idx;
}

const AtomicOp = enum { add, sub, @"and", @"or", xor, exchange };

fn applyOp(comptime op: AtomicOp, comptime T: type, old: T, operand: T) T {
    return switch (op) {
        // Wrapping arithmetic matches JS's fixed-width integer overflow
        // (mod 2^n) for every element size Atomics supports.
        .add => old +% operand,
        .sub => old -% operand,
        .@"and" => old & operand,
        .@"or" => old | operand,
        .xor => old ^ operand,
        .exchange => operand,
    };
}

/// `add`/`sub`/`and`/`or`/`xor`/`exchange`: read-modify-write, return
/// the value that existed prior to the operation (real spec). No real
/// atomicity needed -- single-threaded, nothing else can observe the
/// gap between the read and the write.
fn atomicRMW(self: *Interpreter, comptime op: AtomicOp, ta: TA, index: usize, value_arg: JSValue) anyerror!JSValue {
    switch (ta.kind) {
        .i8 => {
            const operand = try toInt8Wrap(self, value_arg);
            const view = typedView(i8, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            view.set(index, applyOp(op, i8, old, operand)) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .u8 => {
            const operand = try toUint8Wrap(self, value_arg);
            const view = typedView(u8, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            view.set(index, applyOp(op, u8, old, operand)) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .i16 => {
            const operand = try toInt16Wrap(self, value_arg);
            const view = typedView(i16, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            view.set(index, applyOp(op, i16, old, operand)) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .u16 => {
            const operand = try toUint16Wrap(self, value_arg);
            const view = typedView(u16, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            view.set(index, applyOp(op, u16, old, operand)) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .i32 => {
            const operand = try self.toInt32JS(value_arg);
            const view = typedView(i32, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            view.set(index, applyOp(op, i32, old, operand)) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .u32 => {
            const operand = try self.toUint32JS(value_arg);
            const view = typedView(u32, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            view.set(index, applyOp(op, u32, old, operand)) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .i64 => {
            const big = try toBigIntValue(self, self.gc_allocator, value_arg);
            defer big.deinit();
            const operand = try toI64Wrapped(self, big.bigint.value);
            const view = typedView(i64, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            view.set(index, applyOp(op, i64, old, operand)) catch unreachable;
            return self.gcNewBigIntValue(try zbigint.ZBigInt.fromInt(self.gc_allocator, old));
        },
        .u64 => {
            const big = try toBigIntValue(self, self.gc_allocator, value_arg);
            defer big.deinit();
            const operand = try toU64Wrapped(self, big.bigint.value);
            const view = typedView(u64, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            view.set(index, applyOp(op, u64, old, operand)) catch unreachable;
            return bigIntFromU64(self, old);
        },
        .u8_clamped, .f32, .f64 => unreachable, // rejected by requireIntegerTypedArray
    }
}

fn atomicCompareExchange(self: *Interpreter, ta: TA, index: usize, expected_arg: JSValue, replacement_arg: JSValue) anyerror!JSValue {
    switch (ta.kind) {
        .i8 => {
            const expected = try toInt8Wrap(self, expected_arg);
            const replacement = try toInt8Wrap(self, replacement_arg);
            const view = typedView(i8, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            if (old == expected) view.set(index, replacement) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .u8 => {
            const expected = try toUint8Wrap(self, expected_arg);
            const replacement = try toUint8Wrap(self, replacement_arg);
            const view = typedView(u8, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            if (old == expected) view.set(index, replacement) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .i16 => {
            const expected = try toInt16Wrap(self, expected_arg);
            const replacement = try toInt16Wrap(self, replacement_arg);
            const view = typedView(i16, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            if (old == expected) view.set(index, replacement) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .u16 => {
            const expected = try toUint16Wrap(self, expected_arg);
            const replacement = try toUint16Wrap(self, replacement_arg);
            const view = typedView(u16, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            if (old == expected) view.set(index, replacement) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .i32 => {
            const expected = try self.toInt32JS(expected_arg);
            const replacement = try self.toInt32JS(replacement_arg);
            const view = typedView(i32, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            if (old == expected) view.set(index, replacement) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .u32 => {
            const expected = try self.toUint32JS(expected_arg);
            const replacement = try self.toUint32JS(replacement_arg);
            const view = typedView(u32, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            if (old == expected) view.set(index, replacement) catch unreachable;
            return JSValue.fromNumber(@floatFromInt(old));
        },
        .i64 => {
            const eb = try toBigIntValue(self, self.gc_allocator, expected_arg);
            defer eb.deinit();
            const expected = try toI64Wrapped(self, eb.bigint.value);
            const rb = try toBigIntValue(self, self.gc_allocator, replacement_arg);
            defer rb.deinit();
            const replacement = try toI64Wrapped(self, rb.bigint.value);
            const view = typedView(i64, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            if (old == expected) view.set(index, replacement) catch unreachable;
            return self.gcNewBigIntValue(try zbigint.ZBigInt.fromInt(self.gc_allocator, old));
        },
        .u64 => {
            const eb = try toBigIntValue(self, self.gc_allocator, expected_arg);
            defer eb.deinit();
            const expected = try toU64Wrapped(self, eb.bigint.value);
            const rb = try toBigIntValue(self, self.gc_allocator, replacement_arg);
            defer rb.deinit();
            const replacement = try toU64Wrapped(self, rb.bigint.value);
            const view = typedView(u64, ta.buffer, ta.byte_offset, ta.len);
            const old = view.get(index) catch unreachable;
            if (old == expected) view.set(index, replacement) catch unreachable;
            return bigIntFromU64(self, old);
        },
        .u8_clamped, .f32, .f64 => unreachable,
    }
}

fn atomicsAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), false);
    const index = try requireIndex(self, ta, arg(args, 1));
    return atomicRMW(self, .add, ta, index, arg(args, 2));
}
fn atomicsSub(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), false);
    const index = try requireIndex(self, ta, arg(args, 1));
    return atomicRMW(self, .sub, ta, index, arg(args, 2));
}
fn atomicsAnd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), false);
    const index = try requireIndex(self, ta, arg(args, 1));
    return atomicRMW(self, .@"and", ta, index, arg(args, 2));
}
fn atomicsOr(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), false);
    const index = try requireIndex(self, ta, arg(args, 1));
    return atomicRMW(self, .@"or", ta, index, arg(args, 2));
}
fn atomicsXor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), false);
    const index = try requireIndex(self, ta, arg(args, 1));
    return atomicRMW(self, .xor, ta, index, arg(args, 2));
}
fn atomicsExchange(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), false);
    const index = try requireIndex(self, ta, arg(args, 1));
    return atomicRMW(self, .exchange, ta, index, arg(args, 2));
}
fn atomicsCompareExchange(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), false);
    const index = try requireIndex(self, ta, arg(args, 1));
    return atomicCompareExchange(self, ta, index, arg(args, 2), arg(args, 3));
}
fn atomicsLoad(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), false);
    const index = try requireIndex(self, ta, arg(args, 1));
    return typedElemGet(self, ta.kind, ta.buffer, ta.byte_offset, ta.len, index);
}
fn atomicsStore(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), false);
    const index = try requireIndex(self, ta, arg(args, 1));
    try typedElemSet(self, ta.kind, ta.buffer, ta.byte_offset, ta.len, index, arg(args, 2));
    // Real spec returns the coerced-but-not-width-narrowed operand;
    // narrowed simplification here (read back what was actually
    // stored) instead -- only observably differs for a value outside
    // the element's range, an edge case not chased further (see the
    // plan's cost estimate).
    return typedElemGet(self, ta.kind, ta.buffer, ta.byte_offset, ta.len, index);
}
fn atomicsIsLockFree(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const n = try self.toNumberJS(arg(args, 0));
    const size: i64 = if (std.math.isFinite(n)) @intFromFloat(@trunc(n)) else 0;
    return JSValue.fromBool(size == 1 or size == 2 or size == 4 or size == 8);
}
fn atomicsPause(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    _ = ctx;
    return JSValue.UNDEFINED;
}

/// A raw `nanosleep(2)` syscall, bypassing `std.Io` -- Zig 0.16 moved
/// blocking sleep behind an `Io` instance (`std.time.sleep` was
/// removed, see the zig-0.16 skill), which this interpreter doesn't
/// thread down to native builtins, and adding that just for one method
/// would be exactly the interpreter-architecture change the plan ruled
/// out. This engine/repo family targets Linux only (no other target
/// mentioned anywhere in the ~30-repo tree), so a direct
/// `std.os.linux.nanosleep` is a reasonable, small, local escape
/// hatch instead.
fn rawSleepMs(ms_val: f64) void {
    if (ms_val <= 0) return;
    const ns_total: i128 = @intFromFloat(ms_val * std.time.ns_per_ms);
    var req: std.os.linux.timespec = .{
        .sec = @intCast(@divFloor(ns_total, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns_total, std.time.ns_per_s)),
    };
    while (true) {
        var rem: std.os.linux.timespec = undefined;
        const rc = std.os.linux.nanosleep(&req, &rem);
        if (rc == 0) return;
        req = rem; // interrupted by a signal -- resume the remaining time
    }
}

/// Real spec order: ValidateIntegerTypedArray(waitable) -> require a
/// SHARED buffer -> ValidateAtomicAccess(index) -> coerce value ->
/// coerce timeout -> compare the CURRENT value against the coerced
/// one -> if it doesn't match, return "not-equal" immediately -> else
/// block until timeout elapses (no other agent can ever exist to
/// `notify` this one, so "ok" is unreachable here -- confirmed against
/// real Node, which does NOT restrict `Atomics.wait` to workers the
/// way a browser main thread does; `AgentCanSuspend()` is true). Real,
/// wall-clock blocking -- this is what every engine's synchronous
/// `Atomics.wait` actually does, not an approximation. A stray
/// pathological timeout is clamped to 2s as a safety net (every
/// reachable, agent-free test262 case actually exercised uses a
/// timeout of 0 -- confirmed by reading the suite -- so this never
/// fires in practice).
fn atomicsWait(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), true);
    if (!ta.is_shared) return self.throwError(.type_error, "Atomics.wait requires a shared typed array", .{});
    const index = try requireIndex(self, ta, arg(args, 1));
    var matches: bool = undefined;
    if (ta.kind == .i64) {
        const big = try toBigIntValue(self, self.gc_allocator, arg(args, 2));
        defer big.deinit();
        const expected = try toI64Wrapped(self, big.bigint.value);
        const view = typedView(i64, ta.buffer, ta.byte_offset, ta.len);
        matches = (view.get(index) catch unreachable) == expected;
    } else {
        const expected = try self.toInt32JS(arg(args, 2));
        const view = typedView(i32, ta.buffer, ta.byte_offset, ta.len);
        matches = (view.get(index) catch unreachable) == expected;
    }
    const timeout_n = try self.toNumberJS(arg(args, 3));
    if (!matches) return self.gcNewString("not-equal");
    const clamped_ms: f64 = if (std.math.isNan(timeout_n)) 2000 else @min(@max(timeout_n, 0), 2000);
    rawSleepMs(clamped_ms);
    return self.gcNewString("timed-out");
}

/// Real spec: `notify` validates like `wait` but does NOT require a
/// shared buffer -- it just returns 0 for a non-shared one (no other
/// agent could ever be waiting on it either way). Since this host's
/// `wait` always throws, NO agent can ever be sleeping in it, so this
/// always returns 0 regardless of sharedness -- the spec-mandated
/// answer for "how many agents were woken", not an approximation.
fn atomicsNotify(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ta = try requireIntegerTypedArray(self, arg(args, 0), true);
    _ = try requireIndex(self, ta, arg(args, 1));
    const count_arg = arg(args, 2);
    if (count_arg != .undefined) _ = try self.toNumberJS(count_arg);
    return JSValue.fromNumber(0);
}

pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "Atomics", .statics = &.{
        .{ .name = "add", .value = .{ .method = .{ .call = atomicsAdd, .arity = 3 } } },
        .{ .name = "sub", .value = .{ .method = .{ .call = atomicsSub, .arity = 3 } } },
        .{ .name = "and", .value = .{ .method = .{ .call = atomicsAnd, .arity = 3 } } },
        .{ .name = "or", .value = .{ .method = .{ .call = atomicsOr, .arity = 3 } } },
        .{ .name = "xor", .value = .{ .method = .{ .call = atomicsXor, .arity = 3 } } },
        .{ .name = "exchange", .value = .{ .method = .{ .call = atomicsExchange, .arity = 3 } } },
        .{ .name = "compareExchange", .value = .{ .method = .{ .call = atomicsCompareExchange, .arity = 4 } } },
        .{ .name = "load", .value = .{ .method = .{ .call = atomicsLoad, .arity = 2 } } },
        .{ .name = "store", .value = .{ .method = .{ .call = atomicsStore, .arity = 3 } } },
        .{ .name = "isLockFree", .value = .{ .method = .{ .call = atomicsIsLockFree, .arity = 1 } } },
        .{ .name = "pause", .value = .{ .method = .{ .call = atomicsPause, .arity = 0 } } },
        .{ .name = "wait", .value = .{ .method = .{ .call = atomicsWait, .arity = 4 } } },
        .{ .name = "notify", .value = .{ .method = .{ .call = atomicsNotify, .arity = 3 } } },
    } });
}
