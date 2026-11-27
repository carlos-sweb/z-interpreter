//! `Date` constructor + `Date.prototype`. z-interpreter-refactor.md,
//! Step 5 Phase A batch 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const property_desc = @import("property_desc.zig");

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
    .{ "toTemporalInstant", MethodSpec{ .call = dateToTemporalInstant, .arity = 0 } },
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
fn dateField(self: *Interpreter, v: JSValue) !?i32 {
    const n = try builtin_helpers.toNumberStrict(self, v);
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

/// ECMA-262 21.4.1.14 MakeTime(hour, min, sec, ms) in exact IEEE-754 f64 arithmetic.
fn makeTimeF64(hour: f64, min: f64, sec: f64, ms: f64) f64 {
    if (!std.math.isFinite(hour) or !std.math.isFinite(min) or !std.math.isFinite(sec) or !std.math.isFinite(ms)) {
        return std.math.nan(f64);
    }
    const h = @trunc(hour);
    const m = @trunc(min);
    const s = @trunc(sec);
    const milli = @trunc(ms);
    return ((h * 3_600_000.0 + m * 60_000.0) + s * 1_000.0) + milli;
}

/// Howard Hinnant's civil-from-days / days-from-civil in f64 for ECMA-262 MakeDay(year, month, date).
fn makeDayF64(year: f64, month: f64, date: f64) f64 {
    if (!std.math.isFinite(year) or !std.math.isFinite(month) or !std.math.isFinite(date)) {
        return std.math.nan(f64);
    }
    const y = @trunc(year);
    const m = @trunc(month);
    const dt = @trunc(date);
    const ym = y + @floor(m / 12.0);
    if (!std.math.isFinite(ym)) return std.math.nan(f64);
    var mn = @mod(m, 12.0);
    if (mn < 0) mn += 12.0;
    if (ym > 1_000_000.0 or ym < -1_000_000.0) return std.math.nan(f64);
    const yi: i64 = @intFromFloat(ym);
    const mi: i64 = @intFromFloat(mn); // 0..11 (Jan..Dec)
    const y_adj: i64 = if (mi <= 1) yi - 1 else yi;
    const era: i64 = @divFloor(y_adj, 400);
    const yoe: i64 = y_adj - era * 400; // [0, 399]
    const mp: i64 = if (mi > 1) mi - 2 else mi + 10; // [0, 11] (Mar..Feb)
    const doy: i64 = @divTrunc(153 * mp + 2, 5); // day-of-year of 1st of month
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days_first: f64 = @floatFromInt(era * 146097 + doe - 719468);
    return days_first + dt - 1.0;
}

fn computeUtcFieldsMs(self: *Interpreter, args: []const JSValue) !i64 {
    var raw: [7]f64 = .{ 0, 0, 1, 0, 0, 0, 0 };
    var i: usize = 0;
    while (i < args.len and i < 7) : (i += 1) {
        raw[i] = try builtin_helpers.toNumberStrict(self, args[i]);
    }
    if (args.len == 0 or !std.math.isFinite(raw[0])) return INVALID_DATE_MS;
    var yr = raw[0];
    const yi = @trunc(yr);
    if (yi >= 0 and yi <= 99) yr = 1900.0 + yi;
    const day = makeDayF64(yr, raw[1], raw[2]);
    const time = makeTimeF64(raw[3], raw[4], raw[5], raw[6]);
    return timeClip(day * 86_400_000.0 + time);
}

fn parseDateStringMs(str: []const u8) i64 {
    if (std.mem.startsWith(u8, str, "-000000")) return INVALID_DATE_MS;
    return zvalue.ZDate.fromString(str).timestamp;
}

/// `new Date()` -> now; `new Date(ms)` -> timestamp (TimeClip'd); `new
/// Date(str)` -> parsed; `new Date(dateValue)` -> copy; `new Date(y, m, d?,
/// h?, min?, s?, ms?)` -> from local components. Any non-finite / out-of-range
/// field yields an Invalid Date rather than crashing. Called without `new` it
/// ignores all arguments and returns `new Date().toString()`.
fn dateConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const is_construct = if (self.construct_target) |ct| ct == ctx else false;
    if (!is_construct) {
        const s = zvalue.ZDate.fromTimestamp(nowMs()).toString(allocator) catch
            return self.gcNewString("Invalid Date");
        defer allocator.free(s);
        return self.gcNewString(s);
    }
    const ts: i64 = blk: {
        if (args.len == 0) break :blk nowMs();
        if (args.len == 1) {
            const first = args[0];
            if (first.isDate()) break :blk first.asDate().value.getTime();
            const prim = if (Interpreter.isPrimitiveTag(first)) first.retain() else try self.toPrimitive(first, .default);
            defer prim.deinit();
            if (prim.isString()) {
                break :blk parseDateStringMs(prim.asString().value.data);
            }
            break :blk timeClip(try builtin_helpers.toNumberStrict(self, prim));
        }
        break :blk try computeUtcFieldsMs(self, args);
    };
    const d_val = try self.gcNewDate(ts);
    if (self.construct_proto) |cp| {
        try self.setOwnedPrototype(d_val, cp);
    }
    return d_val;
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
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const s_arg = arg(args, 0);
    const s_str = try self.toDisplayStringJS(self.gc_allocator, s_arg);
    defer self.gc_allocator.free(s_str);
    if (std.mem.startsWith(u8, s_str, "-000000")) return JSValue.fromNumber(std.math.nan(f64));
    const ms = zvalue.ZDate.parse(s_str);
    if (ms == INVALID_DATE_MS) return JSValue.fromNumber(std.math.nan(f64));
    return JSValue.fromNumber(@floatFromInt(ms));
}

/// `Date.UTC(y, m, d?, h?, min?, s?, ms?)` -> ms from UTC components, or NaN
/// if any provided field is non-finite / out of range.
fn dateUTC(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ms = try computeUtcFieldsMs(self, args);
    if (ms == INVALID_DATE_MS) return JSValue.fromNumber(std.math.nan(f64));
    return JSValue.fromNumber(@floatFromInt(ms));
}

fn requireDate(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    return requireTag(ctx, this_value, .date, "Date.prototype.{s} called on a non-date", method);
}

/// ECMA-262 21.4.4.45 `Date.prototype[@@toPrimitive](hint)`. Generic over
/// any object receiver, not just Dates. "default" behaves like "string",
/// which is what makes `new Date() + 1` concatenate instead of add.
/// Installed on Date.prototype by `materializeProtos`.
pub fn dateToPrimitive(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    if (Interpreter.isPrimitiveTag(this_value)) {
        return self.throwError(.type_error, "Date.prototype [ @@toPrimitive ] called on non-object", .{});
    }
    const h = arg(args, 0);
    const hint: Interpreter.OrdinaryHint = blk: {
        if (h.tag() == .string) {
            const s = h.asString().value.data;
            if (std.mem.eql(u8, s, "string") or std.mem.eql(u8, s, "default")) break :blk .string;
            if (std.mem.eql(u8, s, "number")) break :blk .number;
        }
        return self.throwError(.type_error, "Invalid hint", .{});
    };
    return self.ordinaryToPrimitive(this_value, hint);
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
    return msToNumber(d.asDate().value.getTime());
}

/// ?i32-returning ZDate getters (null = Invalid Date -> NaN, real JS).
fn dateGetter(comptime method: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = args;
            const d = try requireDate(ctx, this_value, method);
            const v = @field(zvalue.ZDate, method)(d.asDate().value) orelse return JSValue.fromNumber(std.math.nan(f64));
            return JSValue.fromNumber(@floatFromInt(v));
        }
    }.call;
}

fn dateToISOString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const d = try requireDate(ctx, this_value, "toISOString");
    const iso = d.asDate().value.toISOString(allocator) catch
        return interp(ctx).throwError(.range_error, "Invalid time value", .{});
    defer allocator.free(iso);
    return interp(ctx).gcNewString(iso);
}

/// ECMA-262 21.4.4.44 Date.prototype.toJSON: generic per spec.
/// 1. Let O be ? ToObject(this value).
/// 2. Let tv be ? ToPrimitive(O, number).
/// 3. If tv is a Number and tv is not finite, return null.
/// 4. Return ? Invoke(O, "toISOString").
fn dateToJSON(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const o = try property_desc.toObject(self, this_value);
    defer o.deinit();
    const tv = try self.toPrimitive(o, .number);
    defer tv.deinit();
    if (tv.tag() == .number and !std.math.isFinite(tv.asNumber())) return JSValue.NULL;
    const to_iso = try self.getProperty(o, "toISOString");
    defer to_iso.deinit();
    return self.callValue(to_iso, o, &.{}, "toISOString");
}

/// String-returning ZDate formatters (`toString`/`toDateString`/... ). These
/// render "Invalid Date" for an invalid time rather than throwing (unlike
/// toISOString), matching real JS.
fn dateFormatter(comptime method: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = args;
            const d = try requireDate(ctx, this_value, method);
            const s = @field(zvalue.ZDate, method)(d.asDate().value, allocator) catch
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
            const s = @field(zvalue.ZDate, method)(d.asDate().value, allocator, null) catch
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
    _ = d.asDate().value.setTime(timeClip(try interp(ctx).toNumberJS(arg(args, 0))));
    return msToNumber(d.asDate().value.getTime());
}

/// Component setters (local and UTC). The first arg is required; `n_optional`
/// trailing args default to the current component when omitted. A present arg
/// that isn't a finite in-range integer makes the Date Invalid (returns NaN),
/// never panicking. Mutates the shared boxed ZDate in place (Date is mutable).
fn dateSetter(comptime method: []const u8, comptime n_optional: usize) NativeFn {
    const is_year = std.mem.indexOf(u8, method, "Year") != null;
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const self = interp(ctx);
            const d = try requireDate(ctx, this_value, method);
            const p = &d.asDate().value;
            const initial_t = p.getTime();
            // Every provided field is ToNumber'd regardless of an earlier
            // one already being invalid (confirmed against Node: every
            // valueOf still runs) -- convert them all first, THEN decide.
            const raw_first = try dateField(self, arg(args, 0));
            var raw_opt: [n_optional]?i32 = undefined;
            inline for (0..n_optional) |k| {
                raw_opt[k] = if (k + 1 < args.len) try dateField(self, args[k + 1]) else null;
            }
            if (!is_year and initial_t == INVALID_DATE_MS) {
                return JSValue.fromNumber(std.math.nan(f64));
            }
            const first = raw_first orelse {
                p.* = zvalue.ZDate.fromTimestamp(INVALID_DATE_MS);
                return JSValue.fromNumber(std.math.nan(f64));
            };
            var opt: [n_optional]?i32 = undefined;
            inline for (0..n_optional) |k| {
                if (k + 1 < args.len) {
                    opt[k] = raw_opt[k] orelse {
                        p.* = zvalue.ZDate.fromTimestamp(INVALID_DATE_MS);
                        return JSValue.fromNumber(std.math.nan(f64));
                    };
                } else {
                    opt[k] = null;
                }
            }
            p.* = zvalue.ZDate.fromTimestamp(initial_t);
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
    _ = try installBuiltin(self, .{ .name = "Date", .ctor = .{ .call = dateConstructor, .arity = 7, .constructable = true }, .statics = &.{
        .{ .name = "now", .value = .{ .method = .{ .call = dateNow, .arity = 0 } } },
        .{ .name = "parse", .value = .{ .method = .{ .call = dateParse, .arity = 1 } } },
        .{ .name = "UTC", .value = .{ .method = .{ .call = dateUTC, .arity = 7 } } },
    } });
}

fn dateToTemporalInstant(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const date = try requireDate(ctx, this_value, "toTemporalInstant");
    const ms = date.asDate().value.getTime();
    if (ms > 8_640_000_000_000_000 or ms < -8_640_000_000_000_000) return self.throwError(.range_error, "Invalid Date", .{});
    const instant = @import("ztemporal").Instant.fromEpochMilliseconds(ms) catch return self.throwError(.range_error, "Invalid Date", .{});
    return self.gcNewTemporal(.{ .instant = instant });
}
