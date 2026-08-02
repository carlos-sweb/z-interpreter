//! `BigInt`: never constructable, `.prototype.toString`/`.valueOf`,
//! `BigInt.asIntN`/`asUintN`. z-interpreter-refactor.md, Step 5 Phase A.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zbigint = @import("zbigint");
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
const installBuiltin = builtin_helpers.installBuiltin;

const requireTag = builtin_helpers.requireTag;
const toIntSat = builtin_helpers.toIntSat;
const toBigIntValue = builtin_helpers.toBigIntValue;

pub const bigint_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "toString", MethodSpec{ .call = bigintToString, .arity = 0 } },
    .{ "toLocaleString", MethodSpec{ .call = bigintToString, .arity = 0 } },
    .{ "valueOf", MethodSpec{ .call = bigintValueOf, .arity = 0 } },
});

/// `BigInt(value)`'s own algorithm: Number gets a special conversion
/// (NumberToBigInt, integer-only, RangeError otherwise) that plain
/// ToBigInt does NOT have -- everything else (including the "not an
/// integer" narrowing on strings/booleans-that-aren't-really-numbers)
/// delegates to the shared `toBigIntValue`.
fn globalBigInt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const a = arg(args, 0);
    if (a == .number) {
        if (std.math.isNan(a.number) or std.math.isInf(a.number) or @floor(a.number) != a.number) {
            const shown = try coercion.toDisplayString(allocator, a);
            defer allocator.free(shown);
            return self.throwError(.range_error, "The number {s} cannot be converted to a BigInt because it is not an integer", .{shown});
        }
        return self.gcNewBigIntValue(try zbigint.ZBigInt.fromFloat(self.gc_allocator, a.number));
    }
    return toBigIntValue(self, allocator, a);
}

fn requireBigInt(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    return requireTag(ctx, this_value, .bigint, "BigInt.prototype.{s} called on a non-BigInt", method);
}

/// `n.toString(radix?)` -- radix 2..36 (default 10), same contract as
/// `Number.prototype.toString`.
fn bigintToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const v = try requireBigInt(ctx, this_value, "toString");
    var radix: u8 = 10;
    if (arg(args, 0) != .undefined) {
        const r = toIntSat(try coercion.toNumber(arg(args, 0)));
        if (r < 2 or r > 36) return interp(ctx).throwError(.range_error, "toString() radix argument must be between 2 and 36", .{});
        radix = @intCast(r);
    }
    const s = try v.bigint.value.toString(allocator, radix);
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

fn bigintValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return (try requireBigInt(ctx, this_value, "valueOf")).retain();
}

/// Shared by `BigInt.asIntN`/`asUintN`: validates the `bits` argument
/// (a non-negative safe integer, matching Node's exact RangeError text)
/// and the `bigint` argument, then returns `(1n << bits) - 1n` (the
/// low-`bits`-bits mask) -- caller owns the returned `ZBigInt`.
fn bigintAsNArgs(ctx: *anyopaque, args: []const JSValue) anyerror!struct { bits: usize, x: JSValue, mask: zbigint.ZBigInt } {
    const self = interp(ctx);
    const bits_n = try coercion.toNumber(arg(args, 0));
    if (std.math.isNan(bits_n) or std.math.isInf(bits_n) or bits_n < 0 or @floor(bits_n) != bits_n) {
        return self.throwError(.range_error, "Invalid value: not (convertible to) a safe integer", .{});
    }
    const bits: usize = @intFromFloat(bits_n);
    // Real spec: `bigint` also goes through ToBigInt (accepts boolean/
    // string/number, not just an already-bigint value) -- `x` is OWNED
    // (`toBigIntValue` always returns a fresh reference), so every
    // caller must `.deinit()` it once done reading `.bigint.value`.
    const x = try toBigIntValue(self, self.gc_allocator, arg(args, 1));
    var one = try zbigint.ZBigInt.fromInt(self.gc_allocator, 1);
    defer one.deinit();
    var shifted = try zbigint.ZBigInt.shiftLeft(self.gc_allocator, one, bits);
    defer shifted.deinit();
    const mask = try zbigint.ZBigInt.sub(self.gc_allocator, shifted, one);
    return .{ .bits = bits, .x = x, .mask = mask };
}

fn bigintAsUintN(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    var parsed = try bigintAsNArgs(ctx, args);
    defer parsed.mask.deinit();
    defer parsed.x.deinit();
    const result = try zbigint.ZBigInt.bitAnd(self.gc_allocator, parsed.x.bigint.value, parsed.mask);
    return self.gcNewBigIntValue(result);
}

fn bigintAsIntN(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    var parsed = try bigintAsNArgs(ctx, args);
    defer parsed.mask.deinit();
    defer parsed.x.deinit();
    if (parsed.bits == 0) return self.gcNewBigIntValue(try zbigint.ZBigInt.fromInt(self.gc_allocator, 0));
    var unsigned_val = try zbigint.ZBigInt.bitAnd(self.gc_allocator, parsed.x.bigint.value, parsed.mask);
    defer unsigned_val.deinit();
    var one = try zbigint.ZBigInt.fromInt(self.gc_allocator, 1);
    defer one.deinit();
    var half = try zbigint.ZBigInt.shiftLeft(self.gc_allocator, one, parsed.bits - 1);
    defer half.deinit();
    if (unsigned_val.cmp(half) != .lt) {
        var full = try zbigint.ZBigInt.shiftLeft(self.gc_allocator, one, parsed.bits);
        defer full.deinit();
        return self.gcNewBigIntValue(try zbigint.ZBigInt.sub(self.gc_allocator, unsigned_val, full));
    }
    return self.gcNewBigIntValue(try unsigned_val.clone());
}

/// Installs the `BigInt` constructor (never constructable) and its
/// `asIntN`/`asUintN` statics.
pub fn install(self: *Interpreter) !void {
    // Unlike String/Number/Boolean, BigInt is NEVER constructable --
    // `new BigInt(5)` is a real TypeError in real JS (there's no
    // [[BigIntData]] wrapper object at all), which `constructValue`'s
    // existing generic `!callee.function.value.constructable` guard
    // already produces for free by just leaving this false.
    _ = try installBuiltin(self, .{ .name = "BigInt", .ctor = .{ .arity = 1, .call = globalBigInt, .constructable = false }, .statics = &.{
        .{ .name = "asIntN", .value = .{ .method = .{ .call = bigintAsIntN, .arity = 2 } } },
        .{ .name = "asUintN", .value = .{ .method = .{ .call = bigintAsUintN, .arity = 2 } } },
    } });
}
