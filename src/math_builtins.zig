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
            _ = allocator;
            _ = this_value;
            // toNumberJS, not the pure coercion.toNumber: real ToNumber
            // calls ToPrimitive on an object (valueOf()/toString()/
            // @@toPrimitive), which needs interpreter access -- confirmed
            // against real Node (Math.sin({valueOf(){return 1;}}) works).
            return JSValue.fromNumber(f(try interp(ctx).toNumberJS(arg(args, 0))));
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
const mathSin = mathUnary(zmath.sin);
const mathCos = mathUnary(zmath.cos);
const mathTan = mathUnary(zmath.tan);
const mathAsin = mathUnary(zmath.asin);
const mathAcos = mathUnary(zmath.acos);
const mathAtan = mathUnary(zmath.atan);
const mathSinh = mathUnary(zmath.sinh);
const mathCosh = mathUnary(zmath.cosh);
const mathTanh = mathUnary(zmath.tanh);
const mathAsinh = mathUnary(zmath.asinh);
const mathAcosh = mathUnary(zmath.acosh);
const mathAtanh = mathUnary(zmath.atanh);
const mathExp = mathUnary(zmath.exp);
const mathExpm1 = mathUnary(zmath.expm1);
const mathLog = mathUnary(zmath.log);
const mathLog2 = mathUnary(zmath.log2);
const mathLog10 = mathUnary(zmath.log10);
const mathLog1p = mathUnary(zmath.log1p);
const mathCbrt = mathUnary(zmath.cbrt);
const mathClz32 = mathUnary(zmath.clz32);
const mathFround = mathUnary(zmath.fround);
const mathF16round = mathUnary(zmath.f16round);

fn mathPow(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    // zmath.pow, NOT std.math.pow directly: JS's Number::exponentiate
    // checks the exponent for NaN/Infinity before the base, diverging
    // from C99/IEEE754 pow() for cases like pow(1, Infinity) (1 in C,
    // NaN in JS) -- zmath.pow already implements the exact spec
    // algorithm (see its own doc comment), std.math.pow does not.
    // toNumberJS (real ToPrimitive) for the same reason as mathUnary.
    const self = interp(ctx);
    return JSValue.fromNumber(zmath.pow(try self.toNumberJS(arg(args, 0)), try self.toNumberJS(arg(args, 1))));
}

fn mathBinary(comptime f: fn (f64, f64) f64) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = this_value;
            const self = interp(ctx);
            return JSValue.fromNumber(f(try self.toNumberJS(arg(args, 0)), try self.toNumberJS(arg(args, 1))));
        }
    }.call;
}

const mathAtan2 = mathBinary(zmath.atan2);
const mathImul = mathBinary(zmath.imul);

fn mathVariadic(ctx: *anyopaque, allocator: Allocator, args: []const JSValue, comptime f: fn ([]const f64) f64) anyerror!JSValue {
    const self = interp(ctx);
    const nums = try allocator.alloc(f64, args.len);
    defer allocator.free(nums);
    for (args, 0..) |a, i| nums[i] = try self.toNumberJS(a);
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

fn mathHypot(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return mathVariadic(ctx, allocator, args, zmath.hypot);
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

/// Best-effort IteratorClose: calls `.return()` if present, discarding
/// its outcome either way -- this engine has no general IteratorClose
/// primitive yet (see ~/.plans/pendientes/destructuring-iterator-protocol.md),
/// so this is a narrow one-off matching exactly what
/// Math.sumPrecise needs (real spec: on an abrupt completion, the
/// ORIGINAL error always wins over anything `.return()` itself throws).
fn closeIterator(self: *Interpreter, allocator: Allocator, iter: JSValue) void {
    const return_fn = self.getProperty(iter, "return") catch return;
    defer return_fn.deinit();
    if (return_fn != .function) return;
    const result = return_fn.function.value.call(return_fn.function.value.ctx, allocator, iter, &.{}) catch return;
    result.deinit();
}

/// Math.sumPrecise(iterable) -- ES2025. Real spec: RequireObjectCoercible
/// then GetIterator, stepping ONE element at a time (NOT an eager full
/// drain like this engine's iterableItems -- confirmed by test262's own
/// throws-on-non-number.js, which feeds an INFINITE custom iterator and
/// asserts exactly 1 next() + 1 return() call, i.e. the algorithm must
/// stop and close immediately on the first non-Number element rather
/// than exhausting the iterator first). Each element must already be a
/// Number (no ToNumber coercion -- TypeError otherwise, confirmed
/// test262 checks valueOf()/toString() are never invoked). NaN/+-
/// Infinity collision/all-minus-zero are resolved by a state machine
/// before any finite value reaches zmath.sumPrecise's exact-summation
/// core (see that function's own doc comment for why the split).
fn mathSumPrecise(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const iterable = arg(args, 0);
    if (iterable == .undefined or iterable == .null) {
        return self.throwError(.type_error, "Cannot convert undefined or null to object", .{});
    }
    const iter = try self.resolveIterator(iterable);
    const next_fn = try self.getProperty(iter, "next");
    if (next_fn != .function) return self.throwError(.type_error, "iterator.next is not a function", .{});

    var has_nan = false;
    var has_pos_inf = false;
    var has_neg_inf = false;
    var has_finite = false;
    var finite_nums: std.ArrayList(f64) = .empty;
    defer finite_nums.deinit(allocator);
    var count: f64 = 0;

    while (true) {
        const step = try next_fn.function.value.call(next_fn.function.value.ctx, allocator, iter, &.{});
        if (step != .object) return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
        if (coercion.isTruthy(try self.getProperty(step, "done"))) break;
        const value = try self.getProperty(step, "value");

        count += 1;
        if (count >= 9007199254740992.0) {
            closeIterator(self, allocator, iter);
            return self.throwError(.range_error, "Too many values to sum", .{});
        }
        if (value != .number) {
            closeIterator(self, allocator, iter);
            return self.throwError(.type_error, "Cannot convert {s} to a number", .{value.typeOf()});
        }
        const n = value.number;

        if (std.math.isNan(n)) {
            has_nan = true;
        } else if (n == std.math.inf(f64)) {
            has_pos_inf = true;
        } else if (n == -std.math.inf(f64)) {
            has_neg_inf = true;
        } else if (!(n == 0 and std.math.signbit(n))) {
            has_finite = true;
            try finite_nums.append(allocator, n);
        }
    }

    if (has_nan or (has_pos_inf and has_neg_inf)) return JSValue.fromNumber(std.math.nan(f64));
    if (has_pos_inf) return JSValue.fromNumber(std.math.inf(f64));
    if (has_neg_inf) return JSValue.fromNumber(-std.math.inf(f64));
    if (!has_finite) return JSValue.fromNumber(-0.0);

    const result = zmath.sumPrecise(allocator, finite_nums.items) catch |err| switch (err) {
        error.Overflow => return self.throwError(.range_error, "overflow", .{}),
        error.OutOfMemory => return err,
    };
    return JSValue.fromNumber(result);
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
        .{ .name = "sin", .value = .{ .method = .{ .call = mathSin, .arity = 1 } } },
        .{ .name = "cos", .value = .{ .method = .{ .call = mathCos, .arity = 1 } } },
        .{ .name = "tan", .value = .{ .method = .{ .call = mathTan, .arity = 1 } } },
        .{ .name = "asin", .value = .{ .method = .{ .call = mathAsin, .arity = 1 } } },
        .{ .name = "acos", .value = .{ .method = .{ .call = mathAcos, .arity = 1 } } },
        .{ .name = "atan", .value = .{ .method = .{ .call = mathAtan, .arity = 1 } } },
        .{ .name = "atan2", .value = .{ .method = .{ .call = mathAtan2, .arity = 2 } } },
        .{ .name = "sinh", .value = .{ .method = .{ .call = mathSinh, .arity = 1 } } },
        .{ .name = "cosh", .value = .{ .method = .{ .call = mathCosh, .arity = 1 } } },
        .{ .name = "tanh", .value = .{ .method = .{ .call = mathTanh, .arity = 1 } } },
        .{ .name = "asinh", .value = .{ .method = .{ .call = mathAsinh, .arity = 1 } } },
        .{ .name = "acosh", .value = .{ .method = .{ .call = mathAcosh, .arity = 1 } } },
        .{ .name = "atanh", .value = .{ .method = .{ .call = mathAtanh, .arity = 1 } } },
        .{ .name = "exp", .value = .{ .method = .{ .call = mathExp, .arity = 1 } } },
        .{ .name = "expm1", .value = .{ .method = .{ .call = mathExpm1, .arity = 1 } } },
        .{ .name = "log", .value = .{ .method = .{ .call = mathLog, .arity = 1 } } },
        .{ .name = "log2", .value = .{ .method = .{ .call = mathLog2, .arity = 1 } } },
        .{ .name = "log10", .value = .{ .method = .{ .call = mathLog10, .arity = 1 } } },
        .{ .name = "log1p", .value = .{ .method = .{ .call = mathLog1p, .arity = 1 } } },
        .{ .name = "cbrt", .value = .{ .method = .{ .call = mathCbrt, .arity = 1 } } },
        .{ .name = "clz32", .value = .{ .method = .{ .call = mathClz32, .arity = 1 } } },
        .{ .name = "fround", .value = .{ .method = .{ .call = mathFround, .arity = 1 } } },
        .{ .name = "f16round", .value = .{ .method = .{ .call = mathF16round, .arity = 1 } } },
        .{ .name = "imul", .value = .{ .method = .{ .call = mathImul, .arity = 2 } } },
        .{ .name = "hypot", .value = .{ .method = .{ .call = mathHypot, .arity = 2 } } },
        .{ .name = "sumPrecise", .value = .{ .method = .{ .call = mathSumPrecise, .arity = 1 } } },
    } });
}
