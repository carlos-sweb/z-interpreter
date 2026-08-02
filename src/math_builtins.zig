//! `Math`: a statics-only namespace, no constructor, no prototype.
//! z-interpreter-refactor.md, Step 5 Phase A.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zmath = @import("zmath");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

pub const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;

fn mathUnary(comptime f: fn (f64) f64) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = ctx;
            _ = allocator;
            _ = this_value;
            return JSValue.fromNumber(f(try coercion.toNumber(arg(args, 0))));
        }
    }.call;
}

const mathFloor = mathUnary(zmath.floor);
const mathCeil = mathUnary(zmath.ceil);
const mathRound = mathUnary(zmath.round);
const mathTrunc = mathUnary(zmath.trunc);
const mathAbs = mathUnary(zmath.abs);
const mathSign = mathUnary(zmath.sign);
const mathSqrt = mathUnary(zmath.sqrt);

fn mathPow(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    return JSValue.fromNumber(std.math.pow(f64, try coercion.toNumber(arg(args, 0)), try coercion.toNumber(arg(args, 1))));
}

fn mathVariadic(ctx: *anyopaque, allocator: Allocator, args: []const JSValue, comptime f: fn ([]const f64) f64) anyerror!JSValue {
    _ = ctx;
    const nums = try allocator.alloc(f64, args.len);
    defer allocator.free(nums);
    for (args, 0..) |a, i| nums[i] = try coercion.toNumber(a);
    return JSValue.fromNumber(f(nums));
}

fn mathMin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return mathVariadic(ctx, allocator, args, zmath.min);
}

fn mathMax(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return mathVariadic(ctx, allocator, args, zmath.max);
}

fn mathRandom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    // Not cryptographic (neither is JS's Math.random). Seeded once per
    // process from ASLR'd addresses -- this Zig version's OS entropy API
    // needs an std.Io instance, which this interpreter doesn't thread.
    const S = struct {
        var prng: ?std.Random.DefaultPrng = null;
    };
    if (S.prng == null) {
        const seed = @intFromPtr(&S.prng) ^ (@intFromPtr(ctx) << 16);
        S.prng = std.Random.DefaultPrng.init(seed);
    }
    return JSValue.fromNumber(S.prng.?.random().float(f64));
}

/// Installs the `Math` namespace (no constructor).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "Math", .statics = &.{
        .{ .name = "PI", .value = .{ .constant = JSValue.fromNumber(zmath.PI) } },
        .{ .name = "E", .value = .{ .constant = JSValue.fromNumber(zmath.E) } },
        .{ .name = "LN10", .value = .{ .constant = JSValue.fromNumber(zmath.LN10) } },
        .{ .name = "LN2", .value = .{ .constant = JSValue.fromNumber(zmath.LN2) } },
        .{ .name = "LOG10E", .value = .{ .constant = JSValue.fromNumber(zmath.LOG10E) } },
        .{ .name = "LOG2E", .value = .{ .constant = JSValue.fromNumber(zmath.LOG2E) } },
        .{ .name = "SQRT1_2", .value = .{ .constant = JSValue.fromNumber(zmath.SQRT1_2) } },
        .{ .name = "SQRT2", .value = .{ .constant = JSValue.fromNumber(zmath.SQRT2) } },
        .{ .name = "floor", .value = .{ .method = .{ .call = mathFloor, .arity = 1 } } },
        .{ .name = "ceil", .value = .{ .method = .{ .call = mathCeil, .arity = 1 } } },
        .{ .name = "round", .value = .{ .method = .{ .call = mathRound, .arity = 1 } } },
        .{ .name = "trunc", .value = .{ .method = .{ .call = mathTrunc, .arity = 1 } } },
        .{ .name = "abs", .value = .{ .method = .{ .call = mathAbs, .arity = 1 } } },
        .{ .name = "sign", .value = .{ .method = .{ .call = mathSign, .arity = 1 } } },
        .{ .name = "sqrt", .value = .{ .method = .{ .call = mathSqrt, .arity = 1 } } },
        .{ .name = "pow", .value = .{ .method = .{ .call = mathPow, .arity = 2 } } },
        .{ .name = "min", .value = .{ .method = .{ .call = mathMin, .arity = 2 } } },
        .{ .name = "max", .value = .{ .method = .{ .call = mathMax, .arity = 2 } } },
        .{ .name = "random", .value = .{ .method = .{ .call = mathRandom, .arity = 0 } } },
    } });
}
