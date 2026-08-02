//! `Date` constructor + `Date.prototype`. z-interpreter-refactor.md,
//! Step 5 Phase A batch 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
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

pub const date_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    // Local-time getters
    .{ "getTime", MethodSpec{ .call = dateGetTime, .arity = 0 } },
    .{ "valueOf", MethodSpec{ .call = dateGetTime, .arity = 0 } },
    .{ "getFullYear", MethodSpec{ .call = dateGetter("getFullYear"), .arity = 0 } },
    .{ "getMonth", MethodSpec{ .call = dateGetter("getMonth"), .arity = 0 } },
    .{ "getDate", MethodSpec{ .call = dateGetter("getDate"), .arity = 0 } },
    .{ "getDay", MethodSpec{ .call = dateGetter("getDay"), .arity = 0 } },
    .{ "getHours", MethodSpec{ .call = dateGetter("getHours"), .arity = 0 } },
    .{ "getMinutes", MethodSpec{ .call = dateGetter("getMinutes"), .arity = 0 } },
    .{ "getSeconds", MethodSpec{ .call = dateGetter("getSeconds"), .arity = 0 } },
    .{ "getMilliseconds", MethodSpec{ .call = dateGetter("getMilliseconds"), .arity = 0 } },
    .{ "getTimezoneOffset", MethodSpec{ .call = dateGetter("getTimezoneOffset"), .arity = 0 } },
    .{ "getYear", MethodSpec{ .call = dateGetter("getYear"), .arity = 0 } }, // Annex B
    // UTC getters
    .{ "getUTCFullYear", MethodSpec{ .call = dateGetter("getUTCFullYear"), .arity = 0 } },
    .{ "getUTCMonth", MethodSpec{ .call = dateGetter("getUTCMonth"), .arity = 0 } },
    .{ "getUTCDate", MethodSpec{ .call = dateGetter("getUTCDate"), .arity = 0 } },
    .{ "getUTCDay", MethodSpec{ .call = dateGetter("getUTCDay"), .arity = 0 } },
    .{ "getUTCHours", MethodSpec{ .call = dateGetter("getUTCHours"), .arity = 0 } },
    .{ "getUTCMinutes", MethodSpec{ .call = dateGetter("getUTCMinutes"), .arity = 0 } },
    .{ "getUTCSeconds", MethodSpec{ .call = dateGetter("getUTCSeconds"), .arity = 0 } },
    .{ "getUTCMilliseconds", MethodSpec{ .call = dateGetter("getUTCMilliseconds"), .arity = 0 } },
    // Local-time setters (n_optional trailing components default to current)
    .{ "setTime", MethodSpec{ .call = dateSetTime, .arity = 1 } },
    .{ "setMilliseconds", MethodSpec{ .call = dateSetter("setMilliseconds", 0), .arity = 1 } },
    .{ "setSeconds", MethodSpec{ .call = dateSetter("setSeconds", 1), .arity = 2 } },
    .{ "setMinutes", MethodSpec{ .call = dateSetter("setMinutes", 2), .arity = 3 } },
    .{ "setHours", MethodSpec{ .call = dateSetter("setHours", 3), .arity = 4 } },
    .{ "setDate", MethodSpec{ .call = dateSetter("setDate", 0), .arity = 1 } },
    .{ "setMonth", MethodSpec{ .call = dateSetter("setMonth", 1), .arity = 2 } },
    .{ "setFullYear", MethodSpec{ .call = dateSetter("setFullYear", 2), .arity = 3 } },
    .{ "setYear", MethodSpec{ .call = dateSetter("setYear", 0), .arity = 1 } }, // Annex B
    // UTC setters
    .{ "setUTCMilliseconds", MethodSpec{ .call = dateSetter("setUTCMilliseconds", 0), .arity = 1 } },
    .{ "setUTCSeconds", MethodSpec{ .call = dateSetter("setUTCSeconds", 1), .arity = 2 } },
    .{ "setUTCMinutes", MethodSpec{ .call = dateSetter("setUTCMinutes", 2), .arity = 3 } },
    .{ "setUTCHours", MethodSpec{ .call = dateSetter("setUTCHours", 3), .arity = 4 } },
    .{ "setUTCDate", MethodSpec{ .call = dateSetter("setUTCDate", 0), .arity = 1 } },
    .{ "setUTCMonth", MethodSpec{ .call = dateSetter("setUTCMonth", 1), .arity = 2 } },
    .{ "setUTCFullYear", MethodSpec{ .call = dateSetter("setUTCFullYear", 2), .arity = 3 } },
    // Formatting / conversion
    .{ "toISOString", MethodSpec{ .call = dateToISOString, .arity = 0 } },
    .{ "toJSON", MethodSpec{ .call = dateToJSON, .arity = 1 } },
    .{ "toString", MethodSpec{ .call = dateFormatter("toString"), .arity = 0 } },
    .{ "toDateString", MethodSpec{ .call = dateFormatter("toDateString"), .arity = 0 } },
    .{ "toTimeString", MethodSpec{ .call = dateFormatter("toTimeString"), .arity = 0 } },
    .{ "toUTCString", MethodSpec{ .call = dateFormatter("toUTCString"), .arity = 0 } },
    .{ "toGMTString", MethodSpec{ .call = dateFormatter("toUTCString"), .arity = 0 } }, // Annex B alias of toUTCString
    .{ "toLocaleString", MethodSpec{ .call = dateLocale("toLocaleString"), .arity = 0 } },
    .{ "toLocaleDateString", MethodSpec{ .call = dateLocale("toLocaleDateString"), .arity = 0 } },
    .{ "toLocaleTimeString", MethodSpec{ .call = dateLocale("toLocaleTimeString"), .arity = 0 } },
});

/// Milliseconds since the Unix epoch via the raw Linux syscall -- this
/// Zig version's portable clock API needs an std.Io instance, which the
/// interpreter doesn't thread (Linux-only for now, like the dev setup).
pub fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// z-date's Invalid Date sentinel (`Constants.INVALID_TIME`). `newDate`/
/// `fromTimestamp` map any out-of-range timestamp to it.
const INVALID_DATE_MS: i64 = std.math.maxInt(i64);

/// Coerce a JS value to an integer Date field (year/month/day/...). Returns
/// null when the value is NaN/±Infinity or outside i32, so the caller can
/// produce an Invalid Date instead of `@intFromFloat` panicking on an
/// out-of-range float (matching TimeClip ultimately yielding NaN).
fn dateField(v: JSValue) !?i32 {
    const n = try coercion.toNumber(v);
    if (!std.math.isFinite(n)) return null;
    const t = @trunc(n);
    if (t > @as(f64, std.math.maxInt(i32)) or t < @as(f64, std.math.minInt(i32))) return null;
    return @intFromFloat(t);
}

/// ECMA-262 TimeClip on a Number: non-finite or |t| > 8.64e15 ms becomes
/// Invalid Date. Also avoids `@intFromFloat` overflowing on a huge float.
fn timeClip(n: f64) i64 {
    if (!std.math.isFinite(n)) return INVALID_DATE_MS;
    const t = @trunc(n);
    if (t > 8.64e15 or t < -8.64e15) return INVALID_DATE_MS;
    return @intFromFloat(t);
}

/// `new Date()` -> now; `new Date(ms)` -> timestamp (TimeClip'd); `new
/// Date(str)` -> parsed; `new Date(dateValue)` -> copy; `new Date(y, m, d?,
/// h?, min?, s?, ms?)` -> from local components. Any non-finite / out-of-range
/// field yields an Invalid Date rather than crashing. Called without `new` it
/// still returns a .date (real JS returns a string there -- documented).
fn dateConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    if (args.len == 0) return interp(ctx).gcNewDate(nowMs());
    if (args.len == 1) {
        const first = args[0];
        if (first == .string) {
            return interp(ctx).gcNewDate(zvalue.ZDate.fromString(first.string.value.data).timestamp);
        }
        if (first == .date) return interp(ctx).gcNewDate(first.date.value.getTime());
        return interp(ctx).gcNewDate(timeClip(try coercion.toNumber(first)));
    }
    // Multi-arg form: read up to 7 fields; a present-but-invalid field (NaN,
    // Infinity, out of i32) makes the whole Date Invalid.
    var fields: [7]?i32 = .{ null, null, null, null, null, null, null };
    var i: usize = 0;
    while (i < args.len and i < 7) : (i += 1) {
        fields[i] = (try dateField(args[i])) orelse return interp(ctx).gcNewDate(INVALID_DATE_MS);
    }
    // year and month are always present here (args.len >= 2).
    const d = zvalue.ZDate.fromComponents(fields[0].?, fields[1].?, fields[2], fields[3], fields[4], fields[5], fields[6]);
    return interp(ctx).gcNewDate(d.timestamp);
}

/// `Date.now()` -> current time in ms.
fn dateNow(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    _ = args;
    return JSValue.fromNumber(@floatFromInt(nowMs()));
}

/// `Date.parse(str)` -> ms since epoch, or NaN if unparseable.
fn dateParse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const s = arg(args, 0);
    if (s != .string) return JSValue.fromNumber(std.math.nan(f64));
    const ms = zvalue.ZDate.parse(s.string.value.data);
    if (ms == INVALID_DATE_MS) return JSValue.fromNumber(std.math.nan(f64));
    return JSValue.fromNumber(@floatFromInt(ms));
}

/// `Date.UTC(y, m, d?, h?, min?, s?, ms?)` -> ms from UTC components, or NaN
/// if any provided field is non-finite / out of range.
fn dateUTC(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    // `Date.UTC()` with no args, and a NaN year, are both NaN.
    var fields: [7]?i32 = .{ null, null, null, null, null, null, null };
    var i: usize = 0;
    while (i < args.len and i < 7) : (i += 1) {
        fields[i] = (try dateField(args[i])) orelse return JSValue.fromNumber(std.math.nan(f64));
    }
    if (fields[0] == null) return JSValue.fromNumber(std.math.nan(f64));
    // Month defaults to 0 when only the year is given.
    const ms = zvalue.ZDate.UTC(fields[0].?, fields[1] orelse 0, fields[2], fields[3], fields[4], fields[5], fields[6]);
    if (ms == INVALID_DATE_MS) return JSValue.fromNumber(std.math.nan(f64));
    return JSValue.fromNumber(@floatFromInt(ms));
}

fn requireDate(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    return requireTag(ctx, this_value, .date, "Date.prototype.{s} called on a non-date", method);
}

/// A raw millisecond timestamp as a JS Number, mapping z-date's Invalid Date
/// (and any out-of-range value) to NaN -- what `getTime`/`valueOf`/the setters
/// must return for an Invalid Date (the ?i32 getters already yield NaN on
/// their own via z-date returning null).
fn msToNumber(ms: i64) JSValue {
    if (ms > 8_640_000_000_000_000 or ms < -8_640_000_000_000_000)
        return JSValue.fromNumber(std.math.nan(f64));
    return JSValue.fromNumber(@floatFromInt(ms));
}

fn dateGetTime(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const d = try requireDate(ctx, this_value, "getTime");
    return msToNumber(d.date.value.getTime());
}

/// ?i32-returning ZDate getters (null = Invalid Date -> NaN, real JS).
fn dateGetter(comptime method: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = args;
            const d = try requireDate(ctx, this_value, method);
            const v = @field(zvalue.ZDate, method)(d.date.value) orelse return JSValue.fromNumber(std.math.nan(f64));
            return JSValue.fromNumber(@floatFromInt(v));
        }
    }.call;
}

fn dateToISOString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const d = try requireDate(ctx, this_value, "toISOString");
    const iso = d.date.value.toISOString(allocator) catch
        return interp(ctx).throwError(.range_error, "Invalid time value", .{});
    defer allocator.free(iso);
    return interp(ctx).gcNewString(iso);
}

/// `toJSON` -> ISO string, or `null` for an Invalid Date (real JS: it calls
/// toISOString only when the time is finite).
fn dateToJSON(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const d = try requireDate(ctx, this_value, "toJSON");
    const s = (d.date.value.toJSON(allocator) catch null) orelse return JSValue.NULL;
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

/// String-returning ZDate formatters (`toString`/`toDateString`/... ). These
/// render "Invalid Date" for an invalid time rather than throwing (unlike
/// toISOString), matching real JS.
fn dateFormatter(comptime method: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = args;
            const d = try requireDate(ctx, this_value, method);
            const s = @field(zvalue.ZDate, method)(d.date.value, allocator) catch
                return interp(ctx).gcNewString("Invalid Date");
            defer allocator.free(s);
            return interp(ctx).gcNewString(s);
        }
    }.call;
}

/// `toLocale*` formatters take an optional Locale (we pass null -> z-date's
/// default en-US locale; Intl options are out of scope).
fn dateLocale(comptime method: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = args;
            const d = try requireDate(ctx, this_value, method);
            const s = @field(zvalue.ZDate, method)(d.date.value, allocator, null) catch
                return interp(ctx).gcNewString("Invalid Date");
            defer allocator.free(s);
            return interp(ctx).gcNewString(s);
        }
    }.call;
}

/// `setTime(ms)` -- replace the timestamp wholesale (TimeClip'd; NaN/huge ->
/// Invalid Date). Returns the new time.
fn dateSetTime(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const d = try requireDate(ctx, this_value, "setTime");
    _ = d.date.value.setTime(timeClip(try coercion.toNumber(arg(args, 0))));
    return msToNumber(d.date.value.getTime());
}

/// Component setters (local and UTC). The first arg is required; `n_optional`
/// trailing args default to the current component when omitted. A present arg
/// that isn't a finite in-range integer makes the Date Invalid (returns NaN),
/// never panicking. Mutates the shared boxed ZDate in place (Date is mutable).
fn dateSetter(comptime method: []const u8, comptime n_optional: usize) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const d = try requireDate(ctx, this_value, method);
            const p = &d.date.value;
            const first = (try dateField(arg(args, 0))) orelse {
                p.* = zvalue.ZDate.fromTimestamp(INVALID_DATE_MS);
                return JSValue.fromNumber(std.math.nan(f64));
            };
            var opt: [n_optional]?i32 = undefined;
            inline for (0..n_optional) |k| {
                const a = arg(args, k + 1);
                if (a == .undefined) {
                    opt[k] = null;
                } else {
                    opt[k] = (try dateField(a)) orelse {
                        p.* = zvalue.ZDate.fromTimestamp(INVALID_DATE_MS);
                        return JSValue.fromNumber(std.math.nan(f64));
                    };
                }
            }
            const f = @field(zvalue.ZDate, method);
            const new_ts = if (n_optional == 0)
                f(p, first)
            else if (n_optional == 1)
                f(p, first, opt[0])
            else if (n_optional == 2)
                f(p, first, opt[0], opt[1])
            else
                f(p, first, opt[0], opt[1], opt[2]);
            return msToNumber(new_ts);
        }
    }.call;
}

/// Installs the `Date` constructor + statics (no method table wiring here --
/// `date_methods` is consulted directly by materializeProtos).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "Date", .ctor = .{ .call = dateConstructor, .constructable = true }, .statics = &.{
        .{ .name = "now", .value = .{ .method = .{ .call = dateNow, .arity = 0 } } },
        .{ .name = "parse", .value = .{ .method = .{ .call = dateParse, .arity = 1 } } },
        .{ .name = "UTC", .value = .{ .method = .{ .call = dateUTC, .arity = 7 } } },
    } });
}
