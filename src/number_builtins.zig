//! `Number.prototype`, the `Number` constructor (`globalNumber` moved here
//! from its old home in the "Loose globals" section), and the
//! `Number.isNaN`/`isFinite`/`isInteger` statics (moved from the old mixed
//! "Number / String statics" section -- `stringFromCharCode` there stays
//! behind for String's own extraction pass). `Number.parseInt`/`parseFloat`
//! reuse the global `parseInt`/`parseFloat` (`globalParseInt`/
//! `globalParseFloat`), imported directly from globals_builtins.zig since
//! batch 10. z-interpreter-refactor.md, Step 5 Phase A batch 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const globals_builtins = @import("globals_builtins.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;
const requirePrimitive = builtin_helpers.requirePrimitive;
const toIntSat = builtin_helpers.toIntSat;

pub const number_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "toString", MethodSpec{ .call = numberToString, .arity = 1 } },
    .{ "toLocaleString", MethodSpec{ .call = numberToString, .arity = 0 } },
    .{ "valueOf", MethodSpec{ .call = numberValueOf, .arity = 0 } },
    .{ "toFixed", MethodSpec{ .call = numberToFixed, .arity = 1 } },
    .{ "toExponential", MethodSpec{ .call = numberToExponential, .arity = 1 } },
    .{ "toPrecision", MethodSpec{ .call = numberToPrecision, .arity = 1 } },
});

fn requireNumber(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!f64 {
    return (try requirePrimitive(ctx, this_value, .number, "Number.prototype.{s} called on a non-number", method)).number;
}

/// `n.toString(radix?)` / `toLocaleString` -- radix 2..36 (default 10).
fn numberToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const n = try requireNumber(ctx, this_value, "toString");
    var radix: ?u8 = null;
    if (arg(args, 0) != .undefined) {
        const r = toIntSat(try coercion.toNumber(arg(args, 0)));
        if (r < 2 or r > 36) return interp(ctx).throwError(.range_error, "toString() radix must be between 2 and 36", .{});
        radix = @intCast(r);
    }
    const s = try znumber.FormattingMethods.toString(n, allocator, radix);
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

fn numberValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(try requireNumber(ctx, this_value, "valueOf"));
}

/// Shared 0..100 digit argument for toFixed/toExponential/toPrecision, with
/// the spec's RangeError. `null` when omitted (allowed by exponential/
/// precision). `lo` is the minimum (0 for fixed/exponential, 1 for precision).
fn digitArg(ctx: *anyopaque, args: []const JSValue, lo: i64) anyerror!?usize {
    if (arg(args, 0) == .undefined) return null;
    const d = toIntSat(try coercion.toNumber(arg(args, 0)));
    if (d < lo or d > 100) return interp(ctx).throwError(.range_error, "toFixed() digits argument must be between 0 and 100", .{});
    return @intCast(d);
}

fn numberToFixed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const n = try requireNumber(ctx, this_value, "toFixed");
    const digits = (try digitArg(ctx, args, 0)) orelse 0;
    const s = try znumber.FormattingMethods.toFixed(n, allocator, digits);
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

fn numberToExponential(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const n = try requireNumber(ctx, this_value, "toExponential");
    const digits = try digitArg(ctx, args, 0);
    const s = try znumber.FormattingMethods.toExponential(n, allocator, digits);
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

fn numberToPrecision(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const n = try requireNumber(ctx, this_value, "toPrecision");
    // Omitted precision behaves like toString.
    if (arg(args, 0) == .undefined) {
        const s = try znumber.FormattingMethods.toString(n, allocator, null);
        defer allocator.free(s);
        return interp(ctx).gcNewString(s);
    }
    const p = (try digitArg(ctx, args, 1)).?;
    const s = try znumber.FormattingMethods.toPrecision(n, allocator, p);
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

fn globalNumber(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const primitive = JSValue.fromNumber(try self.toNumberJS(arg(args, 0)));
    return self.boxPrimitiveIfConstructed(ctx, this_value, primitive);
}

fn numberIsNaN(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(v == .number and std.math.isNan(v.number));
}

fn numberIsFinite(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(v == .number and std.math.isFinite(v.number));
}

fn numberIsInteger(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(v == .number and std.math.isFinite(v.number) and v.number == @trunc(v.number));
}

/// Installs the `Number` constructor + statics.
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "Number", .ctor = .{ .arity = 1, .call = globalNumber, .constructable = true }, .statics = &.{
        .{ .name = "isNaN", .value = .{ .method = .{ .call = numberIsNaN, .arity = 1 } } },
        .{ .name = "isFinite", .value = .{ .method = .{ .call = numberIsFinite, .arity = 1 } } },
        .{ .name = "isInteger", .value = .{ .method = .{ .call = numberIsInteger, .arity = 1 } } },
        .{ .name = "parseFloat", .value = .{ .method = .{ .call = globals_builtins.globalParseFloat, .arity = 1 } } },
        .{ .name = "parseInt", .value = .{ .method = .{ .call = globals_builtins.globalParseInt, .arity = 2 } } },
        .{ .name = "MAX_SAFE_INTEGER", .value = .{ .constant = JSValue.fromNumber(9007199254740991.0) } },
        .{ .name = "MIN_SAFE_INTEGER", .value = .{ .constant = JSValue.fromNumber(-9007199254740991.0) } },
        .{ .name = "EPSILON", .value = .{ .constant = JSValue.fromNumber(std.math.floatEps(f64)) } },
        .{ .name = "NaN", .value = .{ .constant = JSValue.fromNumber(std.math.nan(f64)) } },
        .{ .name = "MAX_VALUE", .value = .{ .constant = JSValue.fromNumber(std.math.floatMax(f64)) } },
        .{ .name = "MIN_VALUE", .value = .{ .constant = JSValue.fromNumber(std.math.floatTrueMin(f64)) } },
        .{ .name = "POSITIVE_INFINITY", .value = .{ .constant = JSValue.fromNumber(std.math.inf(f64)) } },
        .{ .name = "NEGATIVE_INFINITY", .value = .{ .constant = JSValue.fromNumber(-std.math.inf(f64)) } },
    } });
}
