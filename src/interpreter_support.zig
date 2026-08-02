//! Step 5 Phase C batch 6: the regex+arrayextra+boxing+coerce+native
//! grab-bag cluster -- RegExp value/state creation, the array named-own-
//! property side table, primitive-wrapper boxing, `+`/BigInt arithmetic
//! coercion helpers, and the shared native-method/proxy-trap/args-array
//! plumbing. Split out of interpreter.zig; see z-interpreter-refactor.md.

const std = @import("std");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const zparser = @import("zparser");
const zregex = @import("zregex");
const zbigint = @import("zbigint");
const zbuffer = @import("zbuffer");

const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const RegexState = interpreter_mod.RegexState;

/// Compiles `pattern` with `flags` into a `.regex` value and records
/// its JS-level state. A bad pattern is a catchable SyntaxError.
pub fn makeRegex(self: *Interpreter, pattern: []const u8, flags: []const u8) anyerror!JSValue {
    const arena = self.gc_allocator;
    var state: RegexState = .{
        .source = try arena.dupe(u8, pattern),
        .flags = try arena.dupe(u8, flags),
        .global = false,
        .ignore_case = false,
        .multiline = false,
        .dot_all = false,
        .sticky = false,
        .unicode = false,
    };
    // Only fires on an error return below (invalid flags/pattern) --
    // on success `state` is copied into `self.regex_state` and these
    // two dupes become that copy's own, no-longer-freeable-here data.
    errdefer arena.free(state.source);
    errdefer arena.free(state.flags);
    for (flags) |f| switch (f) {
        'g' => state.global = true,
        'i' => state.ignore_case = true,
        'm' => state.multiline = true,
        's' => state.dot_all = true,
        'y' => state.sticky = true,
        'u', 'd', 'v' => state.unicode = state.unicode or f == 'u',
        else => return self.throwError(.syntax_error, "Invalid flags supplied to RegExp constructor '{s}'", .{flags}),
    };
    const re = zregex.Regex.compileWithOptions(arena, pattern, .{
        .case_insensitive = state.ignore_case,
        .multiline = state.multiline,
        .dot_all = state.dot_all,
        .sticky = state.sticky,
    }) catch {
        return self.throwError(.syntax_error, "Invalid regular expression: /{s}/", .{pattern});
    };
    const value = try JSValue.fromRegex(arena, re);
    try self.gcTrack(value);
    try self.regex_state.put(arena, @intFromPtr(value.regex), state);
    return value;
}

/// The RegexState for a `.regex` value (always present -- every
/// `.regex` is created through makeRegex).
pub fn regexState(self: *Interpreter, value: JSValue) *RegexState {
    return self.regex_state.getPtr(@intFromPtr(value.regex)).?;
}

/// Stores a named own property on an array (via the array_props side
/// table) -- exec/match result arrays' index/input/groups.
pub fn setArrayExtra(self: *Interpreter, array: JSValue, key: []const u8, value: JSValue) anyerror!void {
    const arena = self.gc_allocator;
    const gop = try self.array_props.getOrPut(arena, @intFromPtr(array.array));
    if (!gop.found_existing) gop.value_ptr.* = try self.gcNewObject();
    try gop.value_ptr.object.value.set(key, value.retain());
}

/// A named own property of an array, if any (array_props side table).
pub fn arrayExtra(self: *Interpreter, array: JSValue, key: []const u8) ?JSValue {
    const extras = self.array_props.get(@intFromPtr(array.array)) orelse return null;
    return extras.object.value.get(key);
}

/// The array's named-own-property object (array_props side table),
/// created on first use. A real `.object`, so it carries full property
/// descriptors -- lets Object.defineProperty target an array's non-index
/// named keys.
pub fn arrayPropsObject(self: *Interpreter, array: JSValue) !JSValue {
    const arena = self.gc_allocator;
    const gop = try self.array_props.getOrPut(arena, @intFromPtr(array.array));
    if (!gop.found_existing) gop.value_ptr.* = try self.ordinaryObject();
    return gop.value_ptr.*;
}

/// `new String(...)`/`new Number(...)`/`new Boolean(...)`: JSValue's
/// `.object` variant has no internal-slot concept, so the wrapped
/// primitive a boxed constructor computes has nowhere to live inside
/// the object `evalNew` already created -- store it in the
/// primitive_wrapper_data side table (same shape as array_props),
/// keyed by the wrapper's Rc box pointer, and return the wrapper
/// object itself instead of the bare primitive (evalNew already
/// keeps `.object` results as-is, no changes needed there). Called
/// from inside a constructor native (globalString/globalNumber/
/// globalBoolean) with the primitive it just computed; a plain call
/// (no `new`) passes `primitive` through unchanged. Ownership: takes
/// `primitive` by value, no retain -- the constructor's own local
/// computation is the only reference, and it's either returned
/// (plain call) or moved into the table (constructed call), never
/// both. See /home/sweb/.plans/primitive-wrapper-objects.md.
pub fn boxPrimitiveIfConstructed(self: *Interpreter, ctx: *anyopaque, this_value: JSValue, primitive: JSValue) anyerror!JSValue {
    if (self.construct_target != ctx) return primitive;
    try self.primitive_wrapper_data.put(self.gc_allocator, @intFromPtr(this_value.object), primitive);
    return this_value;
}

/// The primitive value boxed inside a wrapper object created via
/// `boxPrimitiveIfConstructed`, if `value` is one (primitive_wrapper_data
/// side table). Used by requireString/requireNumber/requireBoolean to
/// unwrap `new String(x)`/etc. before falling back to a TypeError.
pub fn unboxPrimitiveWrapper(self: *Interpreter, value: JSValue) ?JSValue {
    if (value != .object) return null;
    return self.primitive_wrapper_data.get(@intFromPtr(value.object));
}

/// `delete f.name`/`delete f.length`'s deletion state (deleted_fn_props
/// side table), defaulting to "not deleted" for a function never touched.
pub fn deletedFnProps(self: *Interpreter, fn_val: JSValue) interpreter_mod.DeletedFnProps {
    return self.deleted_fn_props.get(@intFromPtr(fn_val.function)) orelse .{};
}

/// Marks one of `name`/`length` as deleted on `fn_val` (deleted_fn_props
/// side table) -- called by `deletePropertyOnValue`'s `.function` case.
pub fn markFnPropDeleted(self: *Interpreter, fn_val: JSValue, comptime field: []const u8) anyerror!void {
    const gop = try self.deleted_fn_props.getOrPut(self.gc_allocator, @intFromPtr(fn_val.function));
    if (!gop.found_existing) gop.value_ptr.* = .{};
    @field(gop.value_ptr.*, field) = true;
}


/// A shared native-method JSValue for a (type, name) pair, cached so
/// `a.push === b.push` holds like real JS prototype methods.
pub fn nativeMethod(self: *Interpreter, comptime type_prefix: []const u8, name: []const u8, call_fn: native_helpers.NativeFn) anyerror!JSValue {
    const arena = self.gc_allocator;
    const cache_key = try std.fmt.allocPrint(arena, type_prefix ++ ".{s}", .{name});
    // Ownership: method_cache holds its OWN retained reference,
    // independent of whatever the caller does with the one they get
    // back (every consumer, cached hit or fresh miss, gets a
    // reference they own and must eventually release -- same
    // contract as every other getter in this file). Getting this
    // wrong (as it used to be: no retain either way) meant a shared
    // cached method could be decref'd to zero by ONE holder
    // releasing its copy while method_cache -- and every OTHER
    // holder -- still pointed at it.
    if (self.method_cache.get(cache_key)) |cached| {
        self.gc_allocator.free(cache_key);
        return cached.retain();
    }
    const fn_value = try self.gcNewFunction(.{ .ctx = self, .name = name, .call = call_fn });
    try self.method_cache.put(arena, cache_key, fn_value.retain());
    return fn_value;
}

/// Looks up `proxy.handler[trap_name]`; returns it if present AND
/// callable, `null` otherwise -- `null` is exactly the "no trap
/// installed, delegate to target directly" case every Proxy
/// operation falls back to. `getProperty` on the handler already
/// returns an owned (retained) value; callers of this function own
/// the returned function and must `.deinit()` it when done (a
/// `null` result has already released it).
pub fn proxyTrap(self: *Interpreter, proxy: *zvalue.Rc(zvalue.Proxy), trap_name: []const u8) anyerror!?JSValue {
    if (proxy.value.handler != .object) return null;
    const fn_val = try self.getProperty(proxy.value.handler, trap_name);
    if (fn_val != .function) {
        fn_val.deinit();
        return null;
    }
    return fn_val;
}

/// Builds a real JS array from a native args slice -- the shape the
/// `apply`/`construct` traps' `argumentsList` parameter needs (a
/// real Array, not a raw Zig slice). Retains each item, matching
/// every other array-building site.
pub fn argsToArray(self: *Interpreter, args: []const JSValue) anyerror!JSValue {
    var arr = try self.gcNewArray();
    for (args) |a| _ = try arr.array.value.push(a.retain());
    return arr;
}


/// `+`'s string-concat path (ECMA-262: if either operand's
/// ToPrimitive is a String, `+` concatenates rather than adding
/// numerically) -- intercepted here, before `coercion.binaryOp`,
/// instead of living inside `coercion.binaryOp` itself (which used
/// to build the result via a raw `JSValue.newString`, invisible to
/// the GC registry -- a real, long-documented leak, since nothing
/// ever calls `gcTrack`/`deinit` on a bare expression-statement
/// result that's simply discarded). `gcNewString` needs `self`,
/// which `coercion.zig` deliberately doesn't have (same reasoning as
/// `bigintArithmetic` right below). Returns `null` when neither
/// operand is a string, so the caller falls through to
/// `coercion.binaryOp`'s plain numeric `+`.
pub fn stringConcat(self: *Interpreter, left: JSValue, right: JSValue) anyerror!?JSValue {
    if (left != .string and right != .string) return null;
    const ls = try toDisplayStringJS(self, self.gc_allocator, left);
    defer self.gc_allocator.free(ls);
    const rs = try toDisplayStringJS(self, self.gc_allocator, right);
    defer self.gc_allocator.free(rs);
    const joined = try std.mem.concat(self.gc_allocator, u8, &.{ ls, rs });
    defer self.gc_allocator.free(joined);
    return try self.gcNewString(joined);
}

/// ECMA-262 7.1.1 ToPrimitive, narrowed: no `Symbol.toPrimitive` lookup
/// (not implemented anywhere in this engine yet), just the
/// `OrdinaryToPrimitive` fallback -- hint "string" tries
/// `toString()` then `valueOf()`; "number"/"default" tries `valueOf()`
/// then `toString()`. Needs `self` (real method dispatch via
/// `getProperty`/`callValue`, through the same prototype chain
/// `instanceof`/`in` walk) -- `coercion.zig` deliberately has none of
/// that, hence its object-shaped `error.NotImplemented`.
pub fn toPrimitive(self: *Interpreter, v: JSValue, hint: enum { default, number, string }) anyerror!JSValue {
    if (isPrimitiveTag(v)) return v.retain();
    const order: [2][]const u8 = if (hint == .string) .{ "toString", "valueOf" } else .{ "valueOf", "toString" };
    for (order) |method_name| {
        const method = try self.getProperty(v, method_name);
        defer method.deinit();
        if (method != .function and method != .proxy) continue;
        const result = try self.callValue(method, v, &.{}, method_name);
        if (isPrimitiveTag(result)) return result;
        result.deinit();
    }
    return self.throwError(.type_error, "Cannot convert object to primitive value", .{});
}

fn isPrimitiveTag(v: JSValue) bool {
    return switch (v) {
        .undefined, .null, .boolean, .number, .string, .bigint, .symbol => true,
        else => false,
    };
}

/// `coercion.toDisplayString` plus a real ToPrimitive fallback for the
/// object-shaped kinds it can't handle on its own (see `toPrimitive`
/// above) -- the general-purpose ToString callers (template literals,
/// `String(x)`, `+`'s string-concat path) should reach for this
/// instead of `coercion.toDisplayString` directly.
pub fn toDisplayStringJS(self: *Interpreter, allocator: std.mem.Allocator, v: JSValue) anyerror![]u8 {
    return coercion.toDisplayString(allocator, v) catch |err| switch (err) {
        error.NotImplemented => blk: {
            const prim = try toPrimitive(self, v, .string);
            defer prim.deinit();
            break :blk try coercion.toDisplayString(allocator, prim);
        },
        else => err,
    };
}

/// `coercion.toNumber` plus the same real-ToPrimitive fallback (hint
/// "number") that `toDisplayStringJS` gives ToString.
pub fn toNumberJS(self: *Interpreter, v: JSValue) anyerror!f64 {
    // coercion.toNumber's inferred error set is just `error.NotImplemented`
    // (no allocation in its body, unlike toDisplayString) -- a bare `catch`
    // covers it without an unreachable `else` prong.
    return coercion.toNumber(v) catch {
        const prim = try toPrimitive(self, v, .number);
        defer prim.deinit();
        return try coercion.toNumber(prim);
    };
}

/// Real JS BigInt arithmetic/bitwise operators need same-type
/// enforcement (mixing BigInt and Number is a TypeError, not a
/// silent coercion) plus RangeError machinery (division by zero,
/// negative exponent) that coercion.zig's `binaryOp` deliberately
/// doesn't have (same reasoning as instanceof/in above) -- also
/// needs `gcNewBigIntValue` to keep the result GC-tracked, which
/// coercion.zig has no access to at all. Intercepted here, before
/// `coercion.binaryOp`, whenever at least one operand is a bigint.
///
/// Returns `null` for anything that should fall through to
/// `coercion.binaryOp` unchanged: neither operand is a bigint, `+`'s
/// string-concat path (handled separately by `stringConcat`, a
/// bigint operand there just needs its ToString, which
/// `coercion.toDisplayString` already handles), and every
/// relational/equality operator (`<`/`>`/`<=`/`>=`/`==`/`!=`/`===`/
/// `!==`) -- real JS allows those to mix BigInt and Number without
/// throwing, and `coercion.zig` already handles that mixing itself
/// (no throw machinery needed for a comparison).
pub fn bigintArithmetic(self: *Interpreter, op: zparser.BinaryOp, left: JSValue, right: JSValue) anyerror!?JSValue {
    const l_big = left == .bigint;
    const r_big = right == .bigint;
    if (!l_big and !r_big) return null;
    switch (op) {
        .add => if (left == .string or right == .string) return null,
        .lt, .gt, .le, .ge, .eq, .ne, .eqeqeq, .noteqeq => return null,
        .instanceof, .in => unreachable, // intercepted by the caller before this is ever reached
        else => {},
    }
    if (op == .ushr) {
        if (l_big and r_big) {
            return self.throwError(.type_error, "BigInts have no unsigned right shift, use >> instead", .{});
        }
        return self.throwError(.type_error, "Cannot mix BigInt and other types, use explicit conversions", .{});
    }
    if (!l_big or !r_big) {
        return self.throwError(.type_error, "Cannot mix BigInt and other types, use explicit conversions", .{});
    }
    const a = left.bigint.value;
    const b = right.bigint.value;
    const result: zbigint.ZBigInt = switch (op) {
        .add => zbigint.ZBigInt.add(self.gc_allocator, a, b) catch |e| return try self.bigintErr(e),
        .sub => zbigint.ZBigInt.sub(self.gc_allocator, a, b) catch |e| return try self.bigintErr(e),
        .mul => zbigint.ZBigInt.mul(self.gc_allocator, a, b) catch |e| return try self.bigintErr(e),
        .div => zbigint.ZBigInt.divTrunc(self.gc_allocator, a, b) catch |e| return try self.bigintErr(e),
        .mod => zbigint.ZBigInt.remTrunc(self.gc_allocator, a, b) catch |e| return try self.bigintErr(e),
        .pow => zbigint.ZBigInt.pow(self.gc_allocator, a, b) catch |e| return try self.bigintErr(e),
        .bitand => zbigint.ZBigInt.bitAnd(self.gc_allocator, a, b) catch |e| return try self.bigintErr(e),
        .bitor => zbigint.ZBigInt.bitOr(self.gc_allocator, a, b) catch |e| return try self.bigintErr(e),
        .bitxor => zbigint.ZBigInt.bitXor(self.gc_allocator, a, b) catch |e| return try self.bigintErr(e),
        // A negative shift count flips direction (`a << -n === a >>
        // n`), matching real JS BigInt semantics -- z-bigint's own
        // shiftLeft/shiftRight only take an unsigned `usize`.
        .shl => try self.bigintShift(a, b, true),
        .shr => try self.bigintShift(a, b, false),
        else => unreachable,
    };
    return try self.gcNewBigIntValue(result);
}

pub fn bigintShift(self: *Interpreter, a: zbigint.ZBigInt, b: zbigint.ZBigInt, left_shift: bool) anyerror!zbigint.ZBigInt {
    const amt = b.value.toInt(i64) catch return self.throwError(.range_error, "BigInt shift amount out of range", .{});
    const do_left = if (amt >= 0) left_shift else !left_shift;
    const magnitude: usize = @intCast(if (amt >= 0) amt else -amt);
    return if (do_left) zbigint.ZBigInt.shiftLeft(self.gc_allocator, a, magnitude) else zbigint.ZBigInt.shiftRight(self.gc_allocator, a, magnitude);
}

pub fn bigintErr(self: *Interpreter, e: zbigint.BigIntError) anyerror!JSValue {
    return switch (e) {
        error.DivisionByZero => self.throwError(.range_error, "Division by zero", .{}),
        error.NegativeExponent => self.throwError(.range_error, "Exponent must be positive", .{}),
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidDigits => unreachable, // arithmetic ops never parse text
    };
}

/// Converts a `zbuffer.BufferError` into a real, catchable
/// `RangeError` -- matches real JS: both an out-of-range byte
/// offset/length AND a misaligned TypedArray byte_offset are
/// RangeErrors, not TypeErrors.
pub fn bufferErr(self: *Interpreter, e: zbuffer.BufferError) anyerror!JSValue {
    return switch (e) {
        error.OutOfBounds => self.throwError(.range_error, "Offset is outside the bounds of the buffer", .{}),
        error.Misaligned => self.throwError(.range_error, "byte_offset is not a multiple of the element size", .{}),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// `++`/`--`'s shared "add or subtract exactly one" step -- bigint
/// stays bigint (`1n++` must not silently become a Number), anything
/// else goes through the existing ToNumber-based path unchanged.
pub fn incDecOne(self: *Interpreter, current: JSValue, increment: bool) anyerror!JSValue {
    if (current == .bigint) {
        var one = try zbigint.ZBigInt.fromInt(self.gc_allocator, 1);
        defer one.deinit();
        const result = if (increment)
            try zbigint.ZBigInt.add(self.gc_allocator, current.bigint.value, one)
        else
            try zbigint.ZBigInt.sub(self.gc_allocator, current.bigint.value, one);
        return try self.gcNewBigIntValue(result);
    }
    const n = try coercion.toNumber(current);
    return JSValue.fromNumber(if (increment) n + 1 else n - 1);
}

