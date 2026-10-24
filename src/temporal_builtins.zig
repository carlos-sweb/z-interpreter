//! The `Temporal.*` global (TC39, ECMA-262-adjacent) -- wires the
//! already-built `z-temporal` library (PlainDate/PlainTime/PlainDateTime/
//! PlainYearMonth/PlainMonthDay/Instant/Duration/ZonedDateTime +
//! `Temporal.Now`) into the engine as real constructable types with
//! accessor getters and instance methods. See
//! `/home/sweb/z-test262/REPORT.md`'s analysis: this was the single
//! largest FAIL bucket (0% pass, ~4600 tests) precisely because the
//! underlying library existed but was never connected.
//!
//! `ZonedDateTime`/`Temporal.Now`'s I/O-dependent functions (real IANA
//! tzdata reads) needed `std.Io`, which this engine's core has no
//! ambient instance of in native-function context -- see `ioHandle()`
//! below (temporal-zoneddatetime-now-wiring.md): a self-contained, lazy
//! `Io.Threaded`, the same trick `z-print`'s `stdio.zig` already
//! established for this ecosystem's identical problem, rather than
//! threading `Io` through `Interpreter` itself (a bigger, separate
//! architectural change this plan deliberately avoided).
//!
//! Temporal values and algorithms come from z-temporal; this adapter owns
//! JavaScript receivers, coercions, descriptors, symbols and exceptions.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const ztemporal = @import("ztemporal");
const zbigint = @import("zbigint");
const JSValue = zvalue.JSValue;
const TemporalValue = zvalue.TemporalValue;
const Interpreter = @import("interpreter.zig").Interpreter;
const native_helpers = @import("native_helpers.zig");

const Overflow = ztemporal.Overflow;
const Unit = ztemporal.Unit;
const RoundingMode = ztemporal.RoundingMode;
const RoundingOptions = ztemporal.RoundingOptions;
const RoundOptions = ztemporal.RoundOptions;

// z-interpreter-refactor.md, Step 2: interp/arg/native/NativeFn used to be
// duplicated here byte-identical to builtins.zig's own copies -- now both
// files share native_helpers.zig instead.
const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;

fn dneMethod(obj: JSValue, name: []const u8, value: JSValue) !void {
    var v = value;
    errdefer v.deinit();
    try obj.object.value.set(name, v);
    const rec = obj.object.value.getOwnRecordMut(name).?;
    rec.descriptor.enumerable = false;
}

/// Converts a `ztemporal.TemporalError` into a real, catchable error --
/// bare `anyerror` (not `anyerror!JSValue`) so `return temporalErr(self,
/// e);` type-checks from ANY native helper here regardless of its own
/// return type, matching `Interpreter.throwError`'s own convention (it
/// too returns bare `anyerror`, never a real value).
fn temporalErr(self: *Interpreter, e: ztemporal.TemporalError) anyerror {
    return switch (e) {
        error.RangeError => self.throwError(.range_error, "Invalid or out-of-range Temporal value", .{}),
        error.TypeError => self.throwError(.type_error, "Invalid or missing Temporal field", .{}),
        error.OutOfMemory => error.OutOfMemory,
        error.IoError => error.IoError,
    };
}

/// Constructors alone adopt the current newTarget prototype. Static and
/// instance methods continue to use gcNewTemporal and therefore always return
/// intrinsic Temporal instances.
fn constructedTemporal(self: *Interpreter, value: TemporalValue) anyerror!JSValue {
    const result = try self.gcNewTemporal(value);
    errdefer result.deinit();
    if (self.construct_proto) |proto| {
        const intrinsic = self.protos.temporalProtoFor(result.temporal.value);
        if (proto != .object or proto.object != intrinsic.object) {
            try self.setTemporalPrototype(result, proto);
        }
    }
    return result;
}

fn requireI32(self: *Interpreter, v: JSValue, what: []const u8) anyerror!i32 {
    if (v == .bigint) return self.throwError(.type_error, "{s} must be a number", .{what});
    const n = try self.toNumberJS(v);
    if (!std.math.isFinite(n) or n != @trunc(n)) return self.throwError(.range_error, "{s} must be an integer", .{what});
    if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return self.throwError(.range_error, "{s} out of range", .{what});
    return @intFromFloat(n);
}

fn coerceConstructorI32(self: *Interpreter, v: JSValue, what: []const u8) anyerror!i32 {
    const n = try self.toNumberJS(v);
    return requireI32(self, JSValue.fromNumber(n), what);
}

/// Bounds-checked BEFORE `@intFromFloat` (which panics -- not a catchable
/// error -- on a magnitude beyond the target type's range). Test262's
/// Duration tests specifically probe this with values like
/// `Number.MAX_VALUE` (see `argument-duration-precision-exact-numerical-
/// values.js`, which found this the hard way: a real crash, caught and
/// fixed after a Test262 sweep showed 28 new CRASHes from this exact gap).
fn requireI64(self: *Interpreter, v: JSValue, what: []const u8) anyerror!i64 {
    if (v != .number) return self.throwError(.type_error, "{s} must be a number", .{what});
    const n = v.number;
    if (!std.math.isFinite(n) or n != @trunc(n)) return self.throwError(.range_error, "{s} must be an integer", .{what});
    const maxf: f64 = @floatFromInt(std.math.maxInt(i64));
    const minf: f64 = @floatFromInt(std.math.minInt(i64));
    if (n < minf or n > maxf) return self.throwError(.range_error, "{s} out of range", .{what});
    return @intFromFloat(n);
}

/// Bounds-checked BEFORE `@intCast` -- a raw `@intCast(try requireI32(...))`
/// panics (not a catchable error) on a negative value (e.g. a caller
/// probing `roundingIncrement: -1`), since `requireI32`'s own range check
/// is against i32, not u32. Found the same way as `requireI64`'s missing
/// bounds check: a real Test262-triggered crash, not a hypothetical.
fn requireU32(self: *Interpreter, v: JSValue, what: []const u8) anyerror!u32 {
    const n = try requireI32(self, v, what);
    if (n < 0) return self.throwError(.range_error, "{s} must be non-negative", .{what});
    return @intCast(n);
}

fn optionalI32(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!?i32 {
    if (obj != .object) return null;
    const v = obj.object.value.get(key) orelse return null;
    if (v == .undefined) return null;
    return try requireI32(self, v, key);
}

fn optionalTemporalString(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.value.get(key) orelse return null;
    if (v == .undefined) return null;
    if (v != .string) return self.throwError(.type_error, "{s} must be a string", .{key});
    return v.string.value.data;
}

/// Plain `with()` methods use Get so proxies and accessors remain observable.
/// Unlike the legacy helpers above, this result owns its converted string.
fn plainOptionalI32(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!?i32 {
    const value = try self.getProperty(obj, key);
    defer value.deinit();
    if (value == .undefined) return null;
    return try requireI32(self, value, key);
}

fn plainOptionalString(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!?[]u8 {
    const value = try self.getProperty(obj, key);
    defer value.deinit();
    if (value == .undefined) return null;
    return try self.toDisplayStringJS(self.gc_allocator, value);
}

fn optionalBagMonthCode(self: *Interpreter, obj: JSValue) anyerror!?[]const u8 {
    const code = try optionalTemporalString(self, obj, "monthCode") orelse return null;
    // Month-code syntax precedes year coercion; calendar suitability follows it.
    if ((code.len != 3 and code.len != 4) or code[0] != 'M' or
        !std.ascii.isDigit(code[1]) or !std.ascii.isDigit(code[2]) or
        (code.len == 4 and code[3] != 'L'))
    {
        return self.throwError(.range_error, "Invalid monthCode syntax", .{});
    }
    return code;
}

fn rejectWithCalendarOrTimeZone(self: *Interpreter, fields: JSValue) anyerror!void {
    const calendar = try self.getProperty(fields, "calendar");
    defer calendar.deinit();
    if (calendar != .undefined) return self.throwError(.type_error, "with forbids calendar", .{});
    const time_zone = try self.getProperty(fields, "timeZone");
    defer time_zone.deinit();
    if (time_zone != .undefined) return self.throwError(.type_error, "with forbids timeZone", .{});
}

fn optionalBagCalendar(self: *Interpreter, obj: JSValue) anyerror!?[]const u8 {
    const calendar = try self.getProperty(obj, "calendar");
    defer calendar.deinit();
    return calendarFromValue(self, calendar);
}

fn calendarFromValue(self: *Interpreter, value: JSValue) anyerror!?[]const u8 {
    if (value == .undefined) return null;
    if (value == .string) return try surfaceCalendar(self, value.string.value.data);
    if (value == .temporal) switch (value.temporal.value) {
        .plain_date => |date| return date.calendarId(),
        .plain_date_time => |date_time| return date_time.calendarId(),
        .plain_year_month => |year_month| return year_month.calendarId(),
        .plain_month_day => |month_day| return month_day.calendarId(),
        .zoned_date_time => |zoned| return zoned.calendarId(),
        else => {},
    };
    return self.throwError(.type_error, "calendar must be a string or Temporal calendar carrier", .{});
}

fn optionalConstructorCalendar(self: *Interpreter, value: JSValue) anyerror!?[]const u8 {
    if (value == .undefined) return null;
    if (value != .string) return self.throwError(.type_error, "calendar must be a string", .{});
    return value.string.value.data;
}

/// Duration stores integral JavaScript Numbers, including values outside i64.
/// Let z-temporal validate component magnitudes and mixed signs.
fn requireDurationNumber(self: *Interpreter, v: JSValue, what: []const u8) anyerror!f64 {
    if (v == .bigint) return self.throwError(.type_error, "{s} must be a number", .{what});
    const n = try self.toNumberJS(v);
    if (!std.math.isFinite(n) or n != @trunc(n)) return self.throwError(.range_error, "{s} must be an integer", .{what});
    return n;
}

fn optionalDurationNumber(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!?f64 {
    if (obj != .object) return null;
    const v = obj.object.value.get(key) orelse return null;
    if (v == .undefined) return null;
    if (v == .bigint) return self.throwError(.type_error, "{s} must be a number", .{key});
    return try requireDurationNumber(self, JSValue.fromNumber(try self.toNumberJS(v)), key);
}

fn observableDurationNumber(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!?f64 {
    const value = try self.getProperty(obj, key);
    defer value.deinit();
    if (value == .undefined) return null;
    return try requireDurationNumber(self, JSValue.fromNumber(try self.toNumberJS(value)), key);
}

/// Reads `options.overflow` ("constrain"/"reject"), defaulting to
/// `.constrain` (real spec default for `.from`/`.with`). `options` may be
/// `undefined`.
fn readOverflow(self: *Interpreter, options: JSValue) anyerror!Overflow {
    try surfaceOptions(self, options);
    if (options != .object) return .constrain;
    const v = try self.getProperty(options, "overflow");
    defer v.deinit();
    if (v == .undefined) return .constrain;
    const s = try self.toDisplayStringJS(self.gc_allocator, v);
    defer self.gc_allocator.free(s);
    if (std.mem.eql(u8, s, "constrain")) return .constrain;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return self.throwError(.range_error, "overflow must be \"constrain\" or \"reject\"", .{});
}

/// Plain operations must observe `overflow` after their field reads.
fn readPlainOverflow(self: *Interpreter, options: JSValue) anyerror!Overflow {
    try surfaceOptions(self, options);
    if (options == .undefined) return .constrain;
    const v = try self.getProperty(options, "overflow");
    defer v.deinit();
    if (v == .undefined) return .constrain;
    const s = try self.toDisplayStringJS(self.gc_allocator, v);
    defer self.gc_allocator.free(s);
    if (std.mem.eql(u8, s, "constrain")) return .constrain;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return self.throwError(.range_error, "overflow must be \"constrain\" or \"reject\"", .{});
}

/// Self-contained, lazy `std.Io` for `ZonedDateTime`/`Temporal.Now`'s
/// timezone-dependent functions (real IANA tzdata I/O) -- Zig 0.16 has
/// no ambient `Io` this interpreter threads down to native-function
/// context, and adding that just for these few call sites would be
/// exactly the interpreter-architecture change the wiring plan ruled
/// out. Same pattern `z-print/src/stdio.zig` already established for
/// this ecosystem's identical problem (`async_limit`/`concurrent_limit`
/// = `.nothing` since nothing here is ever actually async).
var temporal_io_threaded: ?std.Io.Threaded = null;
fn ioHandle() std.Io {
    if (temporal_io_threaded == null) {
        temporal_io_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
            .async_limit = .nothing,
            .concurrent_limit = .nothing,
        });
    }
    return temporal_io_threaded.?.io();
}

/// Reads `options.disambiguation` ("compatible"/"earlier"/"later"/
/// "reject"), defaulting to `.compatible` (real spec default). `options`
/// may be `undefined`.
fn readDisambiguation(self: *Interpreter, options: JSValue) anyerror!ztemporal.Disambiguation {
    try surfaceOptions(self, options);
    if (options != .object) return .compatible;
    const v = options.object.value.get("disambiguation") orelse return .compatible;
    if (v == .undefined) return .compatible;
    if (v != .string) return self.throwError(.type_error, "disambiguation must be a string", .{});
    const s = v.string.value.data;
    if (std.mem.eql(u8, s, "compatible")) return .compatible;
    if (std.mem.eql(u8, s, "earlier")) return .earlier;
    if (std.mem.eql(u8, s, "later")) return .later;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return self.throwError(.range_error, "disambiguation must be \"compatible\", \"earlier\", \"later\", or \"reject\"", .{});
}

/// Reads `options.offset` ("use"/"prefer"/"ignore"/"reject"), defaulting
/// to `.reject` (real spec default -- a DIFFERENT default axis than
/// `disambiguation`'s own). `options` may be `undefined`.
fn readOffsetOption(self: *Interpreter, options: JSValue) anyerror!ztemporal.OffsetOption {
    try surfaceOptions(self, options);
    if (options != .object) return .reject;
    const v = options.object.value.get("offset") orelse return .reject;
    if (v == .undefined) return .reject;
    if (v != .string) return self.throwError(.type_error, "offset must be a string", .{});
    const s = v.string.value.data;
    if (std.mem.eql(u8, s, "use")) return .use;
    if (std.mem.eql(u8, s, "prefer")) return .prefer;
    if (std.mem.eql(u8, s, "ignore")) return .ignore;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return self.throwError(.range_error, "offset must be \"use\", \"prefer\", \"ignore\", or \"reject\"", .{});
}

fn transitionDirectionFromString(self: *Interpreter, s: []const u8) anyerror!ztemporal.ZonedDateTime.TransitionDirection {
    if (std.mem.eql(u8, s, "next")) return .next;
    if (std.mem.eql(u8, s, "previous")) return .previous;
    return self.throwError(.range_error, "direction must be \"next\" or \"previous\"", .{});
}

fn unitFromString(self: *Interpreter, s: []const u8, what: []const u8) anyerror!Unit {
    const names = [_]struct { []const u8, Unit }{
        .{ "year", .year },               .{ "years", .year },
        .{ "month", .month },             .{ "months", .month },
        .{ "week", .week },               .{ "weeks", .week },
        .{ "day", .day },                 .{ "days", .day },
        .{ "hour", .hour },               .{ "hours", .hour },
        .{ "minute", .minute },           .{ "minutes", .minute },
        .{ "second", .second },           .{ "seconds", .second },
        .{ "millisecond", .millisecond }, .{ "milliseconds", .millisecond },
        .{ "microsecond", .microsecond }, .{ "microseconds", .microsecond },
        .{ "nanosecond", .nanosecond },   .{ "nanoseconds", .nanosecond },
    };
    for (names) |pair| {
        if (std.mem.eql(u8, s, pair[0])) return pair[1];
    }
    return self.throwError(.range_error, "Invalid {s}: {s}", .{ what, s });
}

fn roundingModeFromString(self: *Interpreter, s: []const u8) anyerror!RoundingMode {
    const names = [_]struct { []const u8, RoundingMode }{
        .{ "ceil", .ceil },         .{ "floor", .floor },         .{ "trunc", .trunc },         .{ "expand", .expand },
        .{ "halfCeil", .halfCeil }, .{ "halfFloor", .halfFloor }, .{ "halfTrunc", .halfTrunc }, .{ "halfExpand", .halfExpand },
        .{ "halfEven", .halfEven },
    };
    for (names) |pair| {
        if (std.mem.eql(u8, s, pair[0])) return pair[1];
    }
    return self.throwError(.range_error, "Invalid roundingMode: {s}", .{s});
}

const RoundingOptionValues = struct {
    largest_unit: ?[]u8 = null,
    rounding_increment: ?f64 = null,
    rounding_mode: ?[]u8 = null,
    smallest_unit: ?[]u8 = null,

    fn deinit(self: *RoundingOptionValues, allocator: Allocator) void {
        if (self.largest_unit) |value| allocator.free(value);
        if (self.rounding_mode) |value| allocator.free(value);
        if (self.smallest_unit) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn readRoundingOptionString(self: *Interpreter, options: JSValue, key: []const u8) anyerror!?[]u8 {
    const value = try self.getProperty(options, key);
    defer value.deinit();
    if (value == .undefined) return null;
    return try self.toDisplayStringJS(self.gc_allocator, value);
}

fn readRoundingOptionNumber(self: *Interpreter, options: JSValue, key: []const u8) anyerror!?f64 {
    const value = try self.getProperty(options, key);
    defer value.deinit();
    if (value == .undefined) return null;
    if (value == .bigint) return self.throwError(.type_error, "{s} must be a number", .{key});
    return try self.toNumberJS(value);
}

/// Performs every observable Get and To* conversion before validating an
/// option value. GetDifferenceSettings observes largestUnit first; round()
/// has no largestUnit and starts with roundingIncrement.
fn readPlainRoundingOptionsGeneric(self: *Interpreter, comptime T: type, options: JSValue, default_mode: RoundingMode, comptime is_difference: bool) anyerror!T {
    var out: T = .{ .roundingMode = default_mode };
    if (!is_difference and options == .string) {
        // A bare unit string is shorthand for { smallestUnit: options }.
        out.smallestUnit = try unitFromString(self, options.string.value.data, "smallestUnit");
        return out;
    }
    try surfaceOptions(self, options);
    if (options == .undefined) return out;

    var raw: RoundingOptionValues = .{};
    defer raw.deinit(self.gc_allocator);
    if (is_difference) raw.largest_unit = try readRoundingOptionString(self, options, "largestUnit");
    raw.rounding_increment = try readRoundingOptionNumber(self, options, "roundingIncrement");
    raw.rounding_mode = try readRoundingOptionString(self, options, "roundingMode");
    raw.smallest_unit = try readRoundingOptionString(self, options, "smallestUnit");

    if (is_difference) if (raw.largest_unit) |text| {
        if (!std.mem.eql(u8, text, "auto")) out.largestUnit = try unitFromString(self, text, "largestUnit");
    };
    if (raw.rounding_increment) |number| {
        if (!std.math.isFinite(number) or @trunc(number) < 1 or @trunc(number) > 1_000_000_000)
            return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        out.roundingIncrement = @intFromFloat(@trunc(number));
    }
    if (raw.rounding_mode) |text| out.roundingMode = try roundingModeFromString(self, text);
    if (raw.smallest_unit) |text| out.smallestUnit = try unitFromString(self, text, "smallestUnit");
    return out;
}

fn readPlainRoundingOptions(self: *Interpreter, options: JSValue) anyerror!RoundingOptions {
    return readPlainRoundingOptionsGeneric(self, RoundingOptions, options, .trunc, true);
}

fn readPlainRoundOptions(self: *Interpreter, options: JSValue) anyerror!RoundOptions {
    return readPlainRoundingOptionsGeneric(self, RoundOptions, options, .halfExpand, false);
}

/// The round() algorithms for PlainTime and PlainDateTime require
/// smallestUnit. Keep their observable option reads separate from the shared
/// reader, whose callers have different required fields and read orders.
fn readRequiredPlainRoundOptions(self: *Interpreter, options: JSValue) anyerror!RoundOptions {
    if (options == .undefined)
        return self.throwError(.type_error, "round() requires an options object", .{});
    if (options == .string) {
        return .{ .smallestUnit = try unitFromString(self, options.string.value.data, "smallestUnit") };
    }
    try surfaceOptions(self, options);

    const rounding_increment = try readRoundingOptionNumber(self, options, "roundingIncrement");
    const rounding_mode = try readRoundingOptionString(self, options, "roundingMode");
    defer if (rounding_mode) |value| self.gc_allocator.free(value);
    const smallest_unit = try readRoundingOptionString(self, options, "smallestUnit");
    defer if (smallest_unit) |value| self.gc_allocator.free(value);

    var out: RoundOptions = .{};
    if (rounding_increment) |number| {
        if (!std.math.isFinite(number)) return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        const integer = @trunc(number);
        if (integer < 1 or integer > 1_000_000_000)
            return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        out.roundingIncrement = @intFromFloat(integer);
    }
    if (rounding_mode) |text| out.roundingMode = try roundingModeFromString(self, text);
    out.smallestUnit = if (smallest_unit) |text|
        try unitFromString(self, text, "smallestUnit")
    else
        return self.throwError(.range_error, "round() requires smallestUnit", .{});
    return out;
}

fn readPlainTimeRoundOptions(self: *Interpreter, options: JSValue) anyerror!RoundOptions {
    return readRequiredPlainRoundOptions(self, options);
}

fn readPlainDateTimeRoundOptions(self: *Interpreter, options: JSValue) anyerror!RoundOptions {
    return readRequiredPlainRoundOptions(self, options);
}

/// Extracts a `T` payload from a `.temporal` JSValue whose inner tag must
/// be exactly `tag`, else a catchable TypeError -- the per-type analogue
/// of `crypto_globals.zig`'s `coerceBytes`/os_globals's `requireString`.
fn requireTemporal(self: *Interpreter, v: JSValue, comptime tag: std.meta.Tag(TemporalValue), what: []const u8) anyerror!@FieldType(TemporalValue, @tagName(tag)) {
    if (v != .temporal or v.temporal.value != tag) {
        return self.throwError(.type_error, "this is not a {s}", .{what});
    }
    return @field(v.temporal.value, @tagName(tag));
}

/// Extracts a `Duration` from a duration-like JS argument: another
/// `Temporal.Duration` instance, an ISO 8601 duration string, or a plain
/// object with any of the 10 duration fields (missing ones default to 0).
fn coerceDuration(self: *Interpreter, v: JSValue) anyerror!ztemporal.Duration {
    if (v == .temporal and v.temporal.value == .duration) return v.temporal.value.duration;
    if (v == .string) return ztemporal.Duration.from(.{ .string = v.string.value.data }) catch |e| temporalErr(self, e);
    if (v == .proxy) {
        const days = try observableDurationNumber(self, v, "days");
        const hours = try observableDurationNumber(self, v, "hours");
        const microseconds = try observableDurationNumber(self, v, "microseconds");
        const milliseconds = try observableDurationNumber(self, v, "milliseconds");
        const minutes = try observableDurationNumber(self, v, "minutes");
        const months = try observableDurationNumber(self, v, "months");
        const nanoseconds = try observableDurationNumber(self, v, "nanoseconds");
        const seconds = try observableDurationNumber(self, v, "seconds");
        const weeks = try observableDurationNumber(self, v, "weeks");
        const years = try observableDurationNumber(self, v, "years");
        return ztemporal.Duration.from(.{ .fields = .{
            .years = years, .months = months, .weeks = weeks, .days = days,
            .hours = hours, .minutes = minutes, .seconds = seconds,
            .milliseconds = milliseconds, .microseconds = microseconds, .nanoseconds = nanoseconds,
        } }) catch |e| temporalErr(self, e);
    }
    if (v != .object) return self.throwError(.type_error, "Duration-like value required", .{});
    return ztemporal.Duration.from(.{ .fields = .{
        .years = try optionalDurationNumber(self, v, "years"),
        .months = try optionalDurationNumber(self, v, "months"),
        .weeks = try optionalDurationNumber(self, v, "weeks"),
        .days = try optionalDurationNumber(self, v, "days"),
        .hours = try optionalDurationNumber(self, v, "hours"),
        .minutes = try optionalDurationNumber(self, v, "minutes"),
        .seconds = try optionalDurationNumber(self, v, "seconds"),
        .milliseconds = try optionalDurationNumber(self, v, "milliseconds"),
        .microseconds = try optionalDurationNumber(self, v, "microseconds"),
        .nanoseconds = try optionalDurationNumber(self, v, "nanoseconds"),
    } }) catch |e| temporalErr(self, e);
}

/// temporal-argument-coercion.md: the same "instance/string/property-
/// bag" coercion `coerceDuration` above already does for `Duration`
/// arguments, extracted from each type's own `.from()` for reuse by
/// every method that implicitly coerces an argument with no `options`
/// of its own (`compare`/`until`/`since`/`equals`). Confirmed against
/// Node: these use the exact same default `overflow: "constrain"`
/// `.from()` uses when ITS OWN `options` is omitted (e.g.
/// `pd.equals({year:2024,month:13,day:1})` returns `false`, doesn't
/// throw -- month 13 constrains to 12).
fn coercePlainDate(self: *Interpreter, v: JSValue, overflow: Overflow) anyerror!ztemporal.PlainDate {
    if (v == .temporal and v.temporal.value == .plain_date) return v.temporal.value.plain_date;
    if (v == .temporal) switch (v.temporal.value) {
        .plain_date_time => |date_time| return date_time.toPlainDate(),
        .zoned_date_time => |zoned| return zoned.toPlainDate(self.gc_allocator, ioHandle()) catch |e| temporalErr(self, e),
        else => {},
    };
    if (v == .string) return ztemporal.PlainDate.from(.{ .string = v.string.value.data }, .{}) catch |e| temporalErr(self, e);
    if (v == .proxy) return plainDateFromObservedBag(self, v, JSValue.UNDEFINED);
    if (v != .object) return self.throwError(.type_error, "Temporal.PlainDate.from requires a string or an object", .{});
    const month_code = try optionalBagMonthCode(self, v);
    const year = (try optionalI32(self, v, "year")) orelse return self.throwError(.type_error, "year is required", .{});
    const month = try optionalI32(self, v, "month");
    if (month == null and month_code == null) return self.throwError(.type_error, "month or monthCode is required", .{});
    const day = (try optionalI32(self, v, "day")) orelse return self.throwError(.type_error, "day is required", .{});
    return ztemporal.PlainDate.from(.{ .fields = .{ .year = year, .month = month, .monthCode = month_code, .day = day, .calendar = try optionalBagCalendar(self, v) } }, .{ .overflow = overflow }) catch |e| temporalErr(self, e);
}

fn plainTimeFromObservedBag(self: *Interpreter, fields: JSValue, overflow: Overflow) anyerror!ztemporal.PlainTime {
    // PrepareTemporalFields's canonical field order for PlainTime.
    const hour = try observedTemporalIntegerField(self, fields, "hour");
    const microsecond = try observedTemporalIntegerField(self, fields, "microsecond");
    const millisecond = try observedTemporalIntegerField(self, fields, "millisecond");
    const minute = try observedTemporalIntegerField(self, fields, "minute");
    const nanosecond = try observedTemporalIntegerField(self, fields, "nanosecond");
    const second = try observedTemporalIntegerField(self, fields, "second");
    return ztemporal.PlainTime.from(.{ .fields = .{
        .hour = hour,
        .minute = minute,
        .second = second,
        .millisecond = millisecond,
        .microsecond = microsecond,
        .nanosecond = nanosecond,
    } }, .{ .overflow = overflow }) catch |e| temporalErr(self, e);
}

fn coercePlainTime(self: *Interpreter, v: JSValue, overflow: Overflow) anyerror!ztemporal.PlainTime {
    if (v == .temporal and v.temporal.value == .plain_time) return v.temporal.value.plain_time;
    if (v == .temporal) switch (v.temporal.value) {
        .plain_date_time => |date_time| return date_time.toPlainTime(),
        .zoned_date_time => |zoned| return zoned.toPlainTime(self.gc_allocator, ioHandle()) catch |e| temporalErr(self, e),
        else => {},
    };
    if (v == .string) return ztemporal.PlainTime.from(.{ .string = v.string.value.data }, .{}) catch |e| temporalErr(self, e);
    if (v == .proxy) return plainTimeFromObservedBag(self, v, overflow);
    if (v != .object) return self.throwError(.type_error, "Temporal.PlainTime.from requires a string or an object", .{});
    return ztemporal.PlainTime.from(.{
        .fields = .{
            .hour = try optionalI32(self, v, "hour"),
            .minute = try optionalI32(self, v, "minute"),
            .second = try optionalI32(self, v, "second"),
            .millisecond = try optionalI32(self, v, "millisecond"),
            .microsecond = try optionalI32(self, v, "microsecond"),
            .nanosecond = try optionalI32(self, v, "nanosecond"),
        },
    }, .{
        .overflow = overflow,
    }) catch |e| temporalErr(self, e);
}

fn coercePlainDateTime(self: *Interpreter, v: JSValue, overflow: Overflow) anyerror!ztemporal.PlainDateTime {
    if (v == .temporal and v.temporal.value == .plain_date_time) return v.temporal.value.plain_date_time;
    if (v == .temporal) switch (v.temporal.value) {
        .plain_date => |date| return date.toPlainDateTime(null) catch |e| temporalErr(self, e),
        .zoned_date_time => |zoned| return zoned.toPlainDateTime(self.gc_allocator, ioHandle()) catch |e| temporalErr(self, e),
        else => {},
    };
    if (v == .string) return ztemporal.PlainDateTime.from(.{ .string = v.string.value.data }, .{}) catch |e| temporalErr(self, e);
    if (v == .proxy) return plainDateTimeFromObservedBag(self, v, JSValue.UNDEFINED, false);
    if (v != .object) return self.throwError(.type_error, "Temporal.PlainDateTime.from requires a string or an object", .{});
    const month_code = try optionalBagMonthCode(self, v);
    const year = (try optionalI32(self, v, "year")) orelse return self.throwError(.type_error, "year is required", .{});
    const month = try optionalI32(self, v, "month");
    if (month == null and month_code == null) return self.throwError(.type_error, "month or monthCode is required", .{});
    const day = (try optionalI32(self, v, "day")) orelse return self.throwError(.type_error, "day is required", .{});
    return ztemporal.PlainDateTime.from(.{
        .fields = .{
            .year = year,
            .month = month,
            .monthCode = month_code,
            .day = day,
            .calendar = try optionalBagCalendar(self, v),
            .hour = (try optionalI32(self, v, "hour")) orelse 0,
            .minute = (try optionalI32(self, v, "minute")) orelse 0,
            .second = (try optionalI32(self, v, "second")) orelse 0,
            .millisecond = (try optionalI32(self, v, "millisecond")) orelse 0,
            .microsecond = (try optionalI32(self, v, "microsecond")) orelse 0,
            .nanosecond = (try optionalI32(self, v, "nanosecond")) orelse 0,
        },
    }, .{
        .overflow = overflow,
    }) catch |e| temporalErr(self, e);
}

/// `Instant` has no property-bag form at all (real spec: no date/time
/// fields to accept) -- simpler than the other 4 date/time types,
/// instance or string only. An object argument is NOT an immediate
/// TypeError though: real ToTemporalInstant runs ToString (via
/// ToPrimitive) on it first and attempts to parse THAT as ISO --
/// confirmed against Node, `Temporal.Instant.from({})` is a
/// RangeError (from parsing "[object Object]"), not the TypeError
/// every other non-string/non-instance type gets. Found via this
/// plan's own Node cross-check, not anticipated in the design.
fn coerceInstant(self: *Interpreter, allocator: Allocator, v: JSValue) anyerror!ztemporal.Instant {
    if (v == .temporal and v.temporal.value == .instant) return v.temporal.value.instant;
    if (v == .temporal and v.temporal.value == .zoned_date_time) return v.temporal.value.zoned_date_time.toInstant();
    // ToTemporalInstant applies ToString to every remaining Object value.
    // This includes Proxy and callable objects, not just ordinary objects.
    if (!Interpreter.isPrimitiveTag(v)) {
        const s = try self.toDisplayStringJS(allocator, v);
        defer allocator.free(s);
        return ztemporal.Instant.from(.{ .string = s }) catch |e| temporalErr(self, e);
    }
    if (v != .string) return self.throwError(.type_error, "Temporal.Instant.from requires a string", .{});
    return ztemporal.Instant.from(.{ .string = v.string.value.data }) catch |e| temporalErr(self, e);
}

fn coercePlainYearMonth(self: *Interpreter, v: JSValue, overflow: Overflow) anyerror!ztemporal.PlainYearMonth {
    if (v == .temporal and v.temporal.value == .plain_year_month) return v.temporal.value.plain_year_month;
    if (v == .temporal) switch (v.temporal.value) {
        .plain_date => |date| return date.toPlainYearMonth() catch |e| temporalErr(self, e),
        .plain_date_time => |date_time| return date_time.toPlainYearMonth() catch |e| temporalErr(self, e),
        .zoned_date_time => |zoned| return zoned.toPlainYearMonth(self.gc_allocator, ioHandle()) catch |e| temporalErr(self, e),
        else => {},
    };
    if (v == .string) return ztemporal.PlainYearMonth.from(.{ .string = v.string.value.data }, .{}) catch |e| temporalErr(self, e);
    if (v == .proxy) return plainYearMonthFromObservedBag(self, v, JSValue.UNDEFINED, false);
    if (v != .object) return self.throwError(.type_error, "Temporal.PlainYearMonth.from requires a string or an object", .{});
    const month_code = try optionalBagMonthCode(self, v);
    const year = (try optionalI32(self, v, "year")) orelse return self.throwError(.type_error, "year is required", .{});
    const month = try optionalI32(self, v, "month");
    if (month == null and month_code == null) return self.throwError(.type_error, "month or monthCode is required", .{});
    return ztemporal.PlainYearMonth.from(.{ .fields = .{ .year = year, .month = month, .monthCode = month_code, .calendar = try optionalBagCalendar(self, v) } }, .{ .overflow = overflow }) catch |e| temporalErr(self, e);
}

fn coercePlainMonthDay(self: *Interpreter, v: JSValue, overflow: Overflow) anyerror!ztemporal.PlainMonthDay {
    if (v == .temporal and v.temporal.value == .plain_month_day) return v.temporal.value.plain_month_day;
    if (v == .temporal) switch (v.temporal.value) {
        .plain_date => |date| return date.toPlainMonthDay() catch |e| temporalErr(self, e),
        .plain_date_time => |date_time| return date_time.toPlainMonthDay() catch |e| temporalErr(self, e),
        .zoned_date_time => |zoned| return zoned.toPlainMonthDay(self.gc_allocator, ioHandle()) catch |e| temporalErr(self, e),
        else => {},
    };
    if (v == .string) return ztemporal.PlainMonthDay.from(.{ .string = v.string.value.data }, .{}) catch |e| temporalErr(self, e);
    if (v != .object) return self.throwError(.type_error, "Temporal.PlainMonthDay.from requires a string or an object", .{});
    const month_code = try optionalBagMonthCode(self, v);
    const month = try optionalI32(self, v, "month");
    if (month == null and month_code == null) return self.throwError(.type_error, "month or monthCode is required", .{});
    const day = (try optionalI32(self, v, "day")) orelse return self.throwError(.type_error, "day is required", .{});
    return ztemporal.PlainMonthDay.from(.{ .fields = .{ .month = month, .monthCode = month_code, .day = day, .year = try optionalI32(self, v, "year"), .calendar = try optionalBagCalendar(self, v) } }, .{ .overflow = overflow }) catch |e| temporalErr(self, e);
}

/// Installs a JS-string-valued getter accessor onto `proto`, backed by a
/// native fn -- the shared shape every `installGetter` call site below
/// wants (matches the object-literal-getter machinery's
/// `defineAccessor(key, getter, setter, empty_value)` contract).
/// `std.math.Order` is `{lt=0, eq=1, gt=2}`, NOT `{-1,0,1}` -- every
/// Temporal `.compare()` needs the real JS convention explicitly, not a
/// raw `@intFromEnum` cast (caught by an end-to-end check against a real
/// PlainDate pair before writing the other 6 types' compare functions).
fn orderToJs(order: std.math.Order) f64 {
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn installGetter(self: *Interpreter, proto: JSValue, name: []const u8, call_fn: NativeFn) !void {
    // Real spec: every accessor getter has arity 0 (takes no arguments).
    const getter_name = try std.fmt.allocPrint(self.arena_state.allocator(), "get {s}", .{name});
    const getter = try native(self, getter_name, 0, call_fn);
    try proto.object.value.defineAccessor(name, getter, null, JSValue.UNDEFINED);
    const rec = proto.object.value.getOwnRecordMut(name).?;
    rec.descriptor.enumerable = false;
    rec.descriptor.configurable = true;
}

// ===================== PlainDate =====================

fn pdSelf(self: *Interpreter, this_value: JSValue) anyerror!ztemporal.PlainDate {
    return requireTemporal(self, this_value, .plain_date, "Temporal.PlainDate");
}

fn plainDateConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Temporal.PlainDate requires 'new'", .{});
    const year = try requireI32(self, arg(args, 0), "year");
    const month = try requireI32(self, arg(args, 1), "month");
    const day = try requireI32(self, arg(args, 2), "day");
    const pd = ztemporal.PlainDate.init(year, month, day, try optionalConstructorCalendar(self, arg(args, 3))) catch |e| return temporalErr(self, e);
    return constructedTemporal(self, .{ .plain_date = pd });
}

fn observableFromOverflow(self: *Interpreter, options: JSValue) anyerror!Overflow {
    try surfaceOptions(self, options);
    if (options != .proxy) return readOverflow(self, options);
    const value = try self.getProperty(options, "overflow");
    defer value.deinit();
    if (value == .undefined) return .constrain;
    const text = try self.toDisplayStringJS(self.gc_allocator, value);
    defer self.gc_allocator.free(text);
    if (std.mem.eql(u8, text, "constrain")) return .constrain;
    if (std.mem.eql(u8, text, "reject")) return .reject;
    return self.throwError(.range_error, "overflow must be \"constrain\" or \"reject\"", .{});
}

fn observedTemporalIntegerField(self: *Interpreter, fields: JSValue, key: []const u8) anyerror!?i32 {
    const value = try self.getProperty(fields, key);
    defer value.deinit();
    if (value == .undefined) return null;
    const number = try self.toNumberJS(value);
    if (!std.math.isFinite(number)) return self.throwError(.range_error, "{s} must be finite", .{key});
    const integer = @trunc(number);
    if (integer < std.math.minInt(i32) or integer > std.math.maxInt(i32))
        return self.throwError(.range_error, "{s} out of range", .{key});
    return @intFromFloat(integer);
}

fn plainDateFromObservedBag(self: *Interpreter, fields: JSValue, options: JSValue) anyerror!ztemporal.PlainDate {
    const calendar_value = try self.getProperty(fields, "calendar");
    defer calendar_value.deinit();
    const calendar = try calendarFromValue(self, calendar_value);
    const day = try observedTemporalIntegerField(self, fields, "day");
    const month = try observedTemporalIntegerField(self, fields, "month");
    const month_code_value = try self.getProperty(fields, "monthCode");
    defer month_code_value.deinit();
    const month_code = if (month_code_value == .undefined) null else try self.toDisplayStringJS(self.gc_allocator, month_code_value);
    defer if (month_code) |code| self.gc_allocator.free(code);
    const year = try observedTemporalIntegerField(self, fields, "year");
    const overflow = try observableFromOverflow(self, options);
    return ztemporal.PlainDate.from(.{ .fields = .{
        .year = year orelse return self.throwError(.type_error, "year is required", .{}),
        .month = month,
        .monthCode = month_code,
        .day = day orelse return self.throwError(.type_error, "day is required", .{}),
        .calendar = calendar,
    } }, .{ .overflow = overflow }) catch |e| temporalErr(self, e);
}

fn plainDateFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const value = arg(args, 0);
    const options = arg(args, 1);
    if (Interpreter.isPrimitiveTag(value) and value != .string)
        return self.throwError(.type_error, "Temporal.PlainDate.from requires a string or an object", .{});
    if (value == .string)
        _ = ztemporal.iso_string.parsePlainDate(value.string.value.data) catch |e| return temporalErr(self, e);
    const pd = if (value == .proxy)
        try plainDateFromObservedBag(self, value, options)
    else blk: {
        const overflow = try observableFromOverflow(self, options);
        break :blk try coercePlainDate(self, value, overflow);
    };
    return self.gcNewTemporal(.{ .plain_date = pd });
}

fn plainDateCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try coercePlainDate(self, arg(args, 0), .constrain);
    const b = try coercePlainDate(self, arg(args, 1), .constrain);
    return JSValue.fromNumber(orderToJs(ztemporal.PlainDate.compare(a, b)));
}

fn pdGetYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdSelf(interp(ctx), this_value)).year()));
}
fn pdGetMonth(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdSelf(interp(ctx), this_value)).month()));
}
fn pdGetDay(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdSelf(interp(ctx), this_value)).day()));
}
fn pdGetMonthCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    var buf: [4]u8 = undefined;
    return self.gcNewString((try pdSelf(self, this_value)).monthCode(&buf));
}
fn pdGetCalendarId(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewString((try pdSelf(self, this_value)).calendarId());
}
fn pdGetDayOfWeek(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdSelf(interp(ctx), this_value)).dayOfWeek()));
}
fn pdGetDayOfYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdSelf(interp(ctx), this_value)).dayOfYear()));
}
fn pdGetDaysInMonth(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdSelf(interp(ctx), this_value)).daysInMonth()));
}
fn pdGetDaysInYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdSelf(interp(ctx), this_value)).daysInYear()));
}
fn pdGetMonthsInYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdSelf(interp(ctx), this_value)).monthsInYear()));
}
fn pdGetInLeapYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromBool((try pdSelf(interp(ctx), this_value)).inLeapYear());
}
fn pdGetWeekOfYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const w = (try pdSelf(interp(ctx), this_value)).weekOfYear();
    return JSValue.fromNumber(@floatFromInt(w orelse return JSValue.UNDEFINED));
}

fn pdWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const fields = arg(args, 0);
    if (fields != .object and fields != .proxy) return self.throwError(.type_error, "with() requires an object", .{});
    try rejectWithCalendarOrTimeZone(self, fields);
    const day = try plainOptionalI32(self, fields, "day");
    const month = try plainOptionalI32(self, fields, "month");
    const month_code = try plainOptionalString(self, fields, "monthCode");
    defer if (month_code) |value| self.gc_allocator.free(value);
    const year = try plainOptionalI32(self, fields, "year");
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pd.with(.{
        .year = year,
        .month = month,
        .monthCode = month_code,
        .day = day,
    }, .{
        .overflow = overflow,
    }) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = result });
}

fn pdAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pd.add(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = result });
}

fn pdSubtract(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pd.subtract(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = result });
}

fn pdUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const other = try coercePlainDate(self, arg(args, 0), .constrain);
    const opts = try readPlainRoundingOptions(self, arg(args, 1));
    const d = pd.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pdSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const other = try coercePlainDate(self, arg(args, 0), .constrain);
    const opts = try readPlainRoundingOptions(self, arg(args, 1));
    const d = pd.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pdEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const other = try coercePlainDate(self, arg(args, 0), .constrain);
    return JSValue.fromBool(ztemporal.PlainDate.equals(pd, other));
}

fn pdToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const calendar_name = try surfaceEnum(self, arg(args, 0), "calendarName", ztemporal.CalendarName, .auto);
    const s = pd.toString(allocator, .{ .calendarName = calendar_name }) catch |e| return temporalErr(self, e);
    defer allocator.free(s);
    return self.gcNewString(s);
}

fn installPlainDate(self: *Interpreter, temporal_ns: JSValue) !void {
    const ctor = try self.gcNewFunction(.{ .ctx = self, .name = "PlainDate", .arity = 3, .call = plainDateConstructor, .constructable = true });
    const statics = try self.functionStatics(ctor);
    try dneMethod(statics, "from", try native(self, "from", 1, plainDateFrom));
    try dneMethod(statics, "compare", try native(self, "compare", 2, plainDateCompare));

    const proto = try self.functionPrototype(ctor);
    try installGetter(self, proto, "year", pdGetYear);
    try installGetter(self, proto, "month", pdGetMonth);
    try installGetter(self, proto, "day", pdGetDay);
    try installGetter(self, proto, "monthCode", pdGetMonthCode);
    try installGetter(self, proto, "calendarId", pdGetCalendarId);
    try installGetter(self, proto, "dayOfWeek", pdGetDayOfWeek);
    try installGetter(self, proto, "dayOfYear", pdGetDayOfYear);
    try installGetter(self, proto, "daysInMonth", pdGetDaysInMonth);
    try installGetter(self, proto, "daysInYear", pdGetDaysInYear);
    try installGetter(self, proto, "monthsInYear", pdGetMonthsInYear);
    try installGetter(self, proto, "inLeapYear", pdGetInLeapYear);
    try installGetter(self, proto, "weekOfYear", pdGetWeekOfYear);
    try dneMethod(proto, "with", try native(self, "with", 1, pdWith));
    try dneMethod(proto, "add", try native(self, "add", 1, pdAdd));
    try dneMethod(proto, "subtract", try native(self, "subtract", 1, pdSubtract));
    try dneMethod(proto, "until", try native(self, "until", 1, pdUntil));
    try dneMethod(proto, "since", try native(self, "since", 1, pdSince));
    try dneMethod(proto, "equals", try native(self, "equals", 1, pdEquals));
    try dneMethod(proto, "toString", try native(self, "toString", 0, pdToString));

    self.protos.temporal_plain_date = proto;
    try dneMethod(temporal_ns, "PlainDate", ctor);
}

// ===================== PlainTime =====================

fn ptSelf(self: *Interpreter, this_value: JSValue) anyerror!ztemporal.PlainTime {
    return requireTemporal(self, this_value, .plain_time, "Temporal.PlainTime");
}

fn plainTimeConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Temporal.PlainTime requires 'new'", .{});
    const hour = if (arg(args, 0) != .undefined) try requireI32(self, arg(args, 0), "hour") else 0;
    const minute = if (arg(args, 1) != .undefined) try requireI32(self, arg(args, 1), "minute") else 0;
    const second = if (arg(args, 2) != .undefined) try requireI32(self, arg(args, 2), "second") else 0;
    const ms = if (arg(args, 3) != .undefined) try requireI32(self, arg(args, 3), "millisecond") else 0;
    const us = if (arg(args, 4) != .undefined) try requireI32(self, arg(args, 4), "microsecond") else 0;
    const ns = if (arg(args, 5) != .undefined) try requireI32(self, arg(args, 5), "nanosecond") else 0;
    const pt = ztemporal.PlainTime.init(hour, minute, second, ms, us, ns) catch |e| return temporalErr(self, e);
    return constructedTemporal(self, .{ .plain_time = pt });
}

fn plainTimeFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const value = arg(args, 0);
    const parsed_string: ?ztemporal.PlainTime = if (value == .string) try coercePlainTime(self, value, .constrain) else null;
    const options = arg(args, 1);
    const pt = if (value == .object or value == .proxy) blk: {
        const hour = try observedTemporalIntegerField(self, value, "hour");
        const microsecond = try observedTemporalIntegerField(self, value, "microsecond");
        const millisecond = try observedTemporalIntegerField(self, value, "millisecond");
        const minute = try observedTemporalIntegerField(self, value, "minute");
        const nanosecond = try observedTemporalIntegerField(self, value, "nanosecond");
        const second = try observedTemporalIntegerField(self, value, "second");
        const overflow = try observableFromOverflow(self, options);
        break :blk ztemporal.PlainTime.from(.{ .fields = .{
            .hour = hour, .minute = minute, .second = second,
            .millisecond = millisecond, .microsecond = microsecond, .nanosecond = nanosecond,
        } }, .{ .overflow = overflow }) catch |e| return temporalErr(self, e);
    } else blk: {
        const overflow = try observableFromOverflow(self, options);
        break :blk parsed_string orelse try coercePlainTime(self, value, overflow);
    };
    return self.gcNewTemporal(.{ .plain_time = pt });
}

fn plainTimeCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try coercePlainTime(self, arg(args, 0), .constrain);
    const b = try coercePlainTime(self, arg(args, 1), .constrain);
    return JSValue.fromNumber(orderToJs(ztemporal.PlainTime.compare(a, b)));
}

fn ptGetHour(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try ptSelf(interp(ctx), this_value)).hour));
}
fn ptGetMinute(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try ptSelf(interp(ctx), this_value)).minute));
}
fn ptGetSecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try ptSelf(interp(ctx), this_value)).second));
}
fn ptGetMillisecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try ptSelf(interp(ctx), this_value)).millisecond));
}
fn ptGetMicrosecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try ptSelf(interp(ctx), this_value)).microsecond));
}
fn ptGetNanosecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try ptSelf(interp(ctx), this_value)).nanosecond));
}

fn ptWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const fields = arg(args, 0);
    if (fields != .object and fields != .proxy) return self.throwError(.type_error, "with() requires an object", .{});
    try rejectWithCalendarOrTimeZone(self, fields);
    const hour = try plainOptionalI32(self, fields, "hour");
    const microsecond = try plainOptionalI32(self, fields, "microsecond");
    const millisecond = try plainOptionalI32(self, fields, "millisecond");
    const minute = try plainOptionalI32(self, fields, "minute");
    const nanosecond = try plainOptionalI32(self, fields, "nanosecond");
    const second = try plainOptionalI32(self, fields, "second");
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pt.with(.{
        .hour = hour,
        .minute = minute,
        .second = second,
        .millisecond = millisecond,
        .microsecond = microsecond,
        .nanosecond = nanosecond,
    }, .{
        .overflow = overflow,
    }) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_time = result });
}

fn ptAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    return self.gcNewTemporal(.{ .plain_time = pt.add(d) });
}

fn ptSubtract(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    return self.gcNewTemporal(.{ .plain_time = pt.subtract(d) });
}

fn ptRound(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const opts = try readPlainTimeRoundOptions(self, arg(args, 0));
    const result = pt.round(opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_time = result });
}

fn ptUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const other = try coercePlainTime(self, arg(args, 0), .constrain);
    const opts = try readPlainRoundingOptions(self, arg(args, 1));
    const d = pt.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn ptSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const other = try coercePlainTime(self, arg(args, 0), .constrain);
    const opts = try readPlainRoundingOptions(self, arg(args, 1));
    const d = pt.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn ptEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const other = try coercePlainTime(self, arg(args, 0), .constrain);
    return JSValue.fromBool(ztemporal.PlainTime.equals(pt, other));
}

fn ptToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const options = try surfaceStringOptions(self, arg(args, 0), .plain_time);
    const s = pt.toString(allocator, options) catch |e| return temporalErr(self, e);
    defer allocator.free(s);
    return self.gcNewString(s);
}

fn installPlainTime(self: *Interpreter, temporal_ns: JSValue) !void {
    const ctor = try self.gcNewFunction(.{ .ctx = self, .name = "PlainTime", .arity = 0, .call = plainTimeConstructor, .constructable = true });
    const statics = try self.functionStatics(ctor);
    try dneMethod(statics, "from", try native(self, "from", 1, plainTimeFrom));
    try dneMethod(statics, "compare", try native(self, "compare", 2, plainTimeCompare));

    const proto = try self.functionPrototype(ctor);
    try installGetter(self, proto, "hour", ptGetHour);
    try installGetter(self, proto, "minute", ptGetMinute);
    try installGetter(self, proto, "second", ptGetSecond);
    try installGetter(self, proto, "millisecond", ptGetMillisecond);
    try installGetter(self, proto, "microsecond", ptGetMicrosecond);
    try installGetter(self, proto, "nanosecond", ptGetNanosecond);
    try dneMethod(proto, "with", try native(self, "with", 1, ptWith));
    try dneMethod(proto, "add", try native(self, "add", 1, ptAdd));
    try dneMethod(proto, "subtract", try native(self, "subtract", 1, ptSubtract));
    try dneMethod(proto, "round", try native(self, "round", 1, ptRound));
    try dneMethod(proto, "until", try native(self, "until", 1, ptUntil));
    try dneMethod(proto, "since", try native(self, "since", 1, ptSince));
    try dneMethod(proto, "equals", try native(self, "equals", 1, ptEquals));
    try dneMethod(proto, "toString", try native(self, "toString", 0, ptToString));

    self.protos.temporal_plain_time = proto;
    try dneMethod(temporal_ns, "PlainTime", ctor);
}

// ===================== PlainDateTime =====================

fn pdtSelf(self: *Interpreter, this_value: JSValue) anyerror!ztemporal.PlainDateTime {
    return requireTemporal(self, this_value, .plain_date_time, "Temporal.PlainDateTime");
}

fn plainDateTimeConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Temporal.PlainDateTime requires 'new'", .{});
    const year = try coerceConstructorI32(self, arg(args, 0), "year");
    const month = try coerceConstructorI32(self, arg(args, 1), "month");
    const day = try coerceConstructorI32(self, arg(args, 2), "day");
    const hour = if (arg(args, 3) != .undefined) try coerceConstructorI32(self, arg(args, 3), "hour") else 0;
    const minute = if (arg(args, 4) != .undefined) try coerceConstructorI32(self, arg(args, 4), "minute") else 0;
    const second = if (arg(args, 5) != .undefined) try coerceConstructorI32(self, arg(args, 5), "second") else 0;
    const ms = if (arg(args, 6) != .undefined) try coerceConstructorI32(self, arg(args, 6), "millisecond") else 0;
    const us = if (arg(args, 7) != .undefined) try coerceConstructorI32(self, arg(args, 7), "microsecond") else 0;
    const ns = if (arg(args, 8) != .undefined) try coerceConstructorI32(self, arg(args, 8), "nanosecond") else 0;
    const pdt = ztemporal.PlainDateTime.init(year, month, day, hour, minute, second, ms, us, ns, try optionalConstructorCalendar(self, arg(args, 9))) catch |e| return temporalErr(self, e);
    return constructedTemporal(self, .{ .plain_date_time = pdt });
}

fn plainDateTimeFromObservedBag(self: *Interpreter, fields: JSValue, options: JSValue, strict_month_code: bool) anyerror!ztemporal.PlainDateTime {
    const calendar_value = try self.getProperty(fields, "calendar");
    defer calendar_value.deinit();
    const calendar = try calendarFromValue(self, calendar_value);
    const day = try observedTemporalIntegerField(self, fields, "day");
    const hour = try observedTemporalIntegerField(self, fields, "hour");
    const microsecond = try observedTemporalIntegerField(self, fields, "microsecond");
    const millisecond = try observedTemporalIntegerField(self, fields, "millisecond");
    const minute = try observedTemporalIntegerField(self, fields, "minute");
    const month = try observedTemporalIntegerField(self, fields, "month");
    const month_code_value = try self.getProperty(fields, "monthCode");
    defer month_code_value.deinit();
    var owned_month_code: ?[]u8 = null;
    defer if (owned_month_code) |code| self.gc_allocator.free(code);
    const month_code: ?[]const u8 = if (month_code_value == .undefined) null else if (strict_month_code) blk: {
        if (month_code_value != .string) return self.throwError(.type_error, "monthCode must be a string", .{});
        break :blk month_code_value.string.value.data;
    } else blk: {
        const code = try self.toDisplayStringJS(self.gc_allocator, month_code_value);
        owned_month_code = code;
        break :blk code;
    };
    const nanosecond = try observedTemporalIntegerField(self, fields, "nanosecond");
    const second = try observedTemporalIntegerField(self, fields, "second");
    const year = try observedTemporalIntegerField(self, fields, "year");
    const overflow = try observableFromOverflow(self, options);
    return ztemporal.PlainDateTime.from(.{ .fields = .{
        .year = year orelse return self.throwError(.type_error, "year is required", .{}),
        .monthCode = month_code,
        .month = month,
        .day = day orelse return self.throwError(.type_error, "day is required", .{}),
        .calendar = calendar,
        .hour = hour orelse 0,
        .minute = minute orelse 0,
        .second = second orelse 0,
        .millisecond = millisecond orelse 0,
        .microsecond = microsecond orelse 0,
        .nanosecond = nanosecond orelse 0,
    } }, .{ .overflow = overflow }) catch |e| temporalErr(self, e);
}

fn plainDateTimeFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const value = arg(args, 0);
    const options = arg(args, 1);
    if (Interpreter.isPrimitiveTag(value) and value != .string)
        return self.throwError(.type_error, "Temporal.PlainDateTime.from requires a string or an object", .{});
    if (value == .string)
        _ = ztemporal.iso_string.parsePlainDateTime(value.string.value.data) catch |e| return temporalErr(self, e);
    const pdt = if (value == .object or value == .proxy)
        try plainDateTimeFromObservedBag(self, value, options, true)
    else blk: {
        const overflow = try observableFromOverflow(self, options);
        break :blk try coercePlainDateTime(self, value, overflow);
    };
    return self.gcNewTemporal(.{ .plain_date_time = pdt });
}

fn plainDateTimeCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try coercePlainDateTime(self, arg(args, 0), .constrain);
    const b = try coercePlainDateTime(self, arg(args, 1), .constrain);
    return JSValue.fromNumber(orderToJs(ztemporal.PlainDateTime.compare(a, b)));
}

fn pdtGetYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).date.year()));
}
fn pdtGetMonth(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).date.month()));
}
fn pdtGetDay(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).date.day()));
}
fn pdtGetHour(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).time.hour));
}
fn pdtGetMinute(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).time.minute));
}
fn pdtGetSecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).time.second));
}
fn pdtGetMillisecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).time.millisecond));
}
fn pdtGetMicrosecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).time.microsecond));
}
fn pdtGetNanosecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).time.nanosecond));
}
fn pdtGetMonthCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    var buf: [4]u8 = undefined;
    return self.gcNewString((try pdtSelf(self, this_value)).date.monthCode(&buf));
}
fn pdtGetDayOfWeek(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).date.dayOfWeek()));
}
fn pdtGetDaysInMonth(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pdtSelf(interp(ctx), this_value)).date.daysInMonth()));
}
fn pdtGetInLeapYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromBool((try pdtSelf(interp(ctx), this_value)).date.inLeapYear());
}
fn pdtGetCalendarId(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewString((try pdtSelf(self, this_value)).calendarId());
}

fn pdtToPlainDate(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewTemporal(.{ .plain_date = (try pdtSelf(self, this_value)).toPlainDate() });
}

fn pdtToPlainTime(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewTemporal(.{ .plain_time = (try pdtSelf(self, this_value)).toPlainTime() });
}

fn pdtWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const fields = arg(args, 0);
    if (fields != .object and fields != .proxy) return self.throwError(.type_error, "with() requires an object", .{});
    try rejectWithCalendarOrTimeZone(self, fields);
    const day = try plainOptionalI32(self, fields, "day");
    const hour = try plainOptionalI32(self, fields, "hour");
    const microsecond = try plainOptionalI32(self, fields, "microsecond");
    const millisecond = try plainOptionalI32(self, fields, "millisecond");
    const minute = try plainOptionalI32(self, fields, "minute");
    const month = try plainOptionalI32(self, fields, "month");
    const month_code = try plainOptionalString(self, fields, "monthCode");
    defer if (month_code) |value| self.gc_allocator.free(value);
    const nanosecond = try plainOptionalI32(self, fields, "nanosecond");
    const second = try plainOptionalI32(self, fields, "second");
    const year = try plainOptionalI32(self, fields, "year");
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pdt.with(.{
        .year = year,
        .month = month,
        .monthCode = month_code,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .millisecond = millisecond,
        .microsecond = microsecond,
        .nanosecond = nanosecond,
    }, .{
        .overflow = overflow,
    }) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = result });
}

fn pdtAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pdt.add(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = result });
}

fn pdtSubtract(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pdt.subtract(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = result });
}

fn pdtRound(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const opts = try readPlainDateTimeRoundOptions(self, arg(args, 0));
    const result = pdt.round(opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = result });
}

fn pdtUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const other = try coercePlainDateTime(self, arg(args, 0), .constrain);
    const opts = try readPlainRoundingOptions(self, arg(args, 1));
    const d = pdt.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pdtSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const other = try coercePlainDateTime(self, arg(args, 0), .constrain);
    const opts = try readPlainRoundingOptions(self, arg(args, 1));
    const d = pdt.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pdtEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const other = try coercePlainDateTime(self, arg(args, 0), .constrain);
    return JSValue.fromBool(ztemporal.PlainDateTime.equals(pdt, other));
}

fn pdtToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const options = try surfaceStringOptions(self, arg(args, 0), .plain_date_time);
    const s = pdt.toString(allocator, options) catch |e| return temporalErr(self, e);
    defer allocator.free(s);
    return self.gcNewString(s);
}

fn installPlainDateTime(self: *Interpreter, temporal_ns: JSValue) !void {
    const ctor = try self.gcNewFunction(.{ .ctx = self, .name = "PlainDateTime", .arity = 3, .call = plainDateTimeConstructor, .constructable = true });
    const statics = try self.functionStatics(ctor);
    try dneMethod(statics, "from", try native(self, "from", 1, plainDateTimeFrom));
    try dneMethod(statics, "compare", try native(self, "compare", 2, plainDateTimeCompare));

    const proto = try self.functionPrototype(ctor);
    try installGetter(self, proto, "year", pdtGetYear);
    try installGetter(self, proto, "month", pdtGetMonth);
    try installGetter(self, proto, "day", pdtGetDay);
    try installGetter(self, proto, "hour", pdtGetHour);
    try installGetter(self, proto, "minute", pdtGetMinute);
    try installGetter(self, proto, "second", pdtGetSecond);
    try installGetter(self, proto, "millisecond", pdtGetMillisecond);
    try installGetter(self, proto, "microsecond", pdtGetMicrosecond);
    try installGetter(self, proto, "nanosecond", pdtGetNanosecond);
    try installGetter(self, proto, "monthCode", pdtGetMonthCode);
    try installGetter(self, proto, "dayOfWeek", pdtGetDayOfWeek);
    try installGetter(self, proto, "daysInMonth", pdtGetDaysInMonth);
    try installGetter(self, proto, "inLeapYear", pdtGetInLeapYear);
    try installGetter(self, proto, "calendarId", pdtGetCalendarId);
    try dneMethod(proto, "toPlainDate", try native(self, "toPlainDate", 0, pdtToPlainDate));
    try dneMethod(proto, "toPlainTime", try native(self, "toPlainTime", 0, pdtToPlainTime));
    try dneMethod(proto, "with", try native(self, "with", 1, pdtWith));
    try dneMethod(proto, "add", try native(self, "add", 1, pdtAdd));
    try dneMethod(proto, "subtract", try native(self, "subtract", 1, pdtSubtract));
    try dneMethod(proto, "round", try native(self, "round", 1, pdtRound));
    try dneMethod(proto, "until", try native(self, "until", 1, pdtUntil));
    try dneMethod(proto, "since", try native(self, "since", 1, pdtSince));
    try dneMethod(proto, "equals", try native(self, "equals", 1, pdtEquals));
    try dneMethod(proto, "toString", try native(self, "toString", 0, pdtToString));

    self.protos.temporal_plain_date_time = proto;
    try dneMethod(temporal_ns, "PlainDateTime", ctor);
}

// ===================== Instant =====================

fn instSelf(self: *Interpreter, this_value: JSValue) anyerror!ztemporal.Instant {
    return requireTemporal(self, this_value, .instant, "Temporal.Instant");
}

fn coerceEpochNanoseconds(self: *Interpreter, v: JSValue, what: []const u8) anyerror!i128 {
    const bigint_value = try @import("builtin_helpers.zig").toBigIntValue(self, self.gc_allocator, v);
    defer bigint_value.deinit();
    return bigint_value.bigint.value.toI128() catch return self.throwError(.range_error, "{s} out of range", .{what});
}

fn instantConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Temporal.Instant requires 'new'", .{});
    const ns = try coerceEpochNanoseconds(self, arg(args, 0), "epochNanoseconds");
    const inst = ztemporal.Instant.fromEpochNanoseconds(ns) catch |e| return temporalErr(self, e);
    return constructedTemporal(self, .{ .instant = inst });
}

fn instantFromEpochMilliseconds(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ms = try requireI64(self, arg(args, 0), "epochMilliseconds");
    const inst = ztemporal.Instant.fromEpochMilliseconds(ms) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .instant = inst });
}

fn instantFromEpochNanoseconds(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ns = try coerceEpochNanoseconds(self, arg(args, 0), "epochNanoseconds");
    const inst = ztemporal.Instant.fromEpochNanoseconds(ns) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .instant = inst });
}

fn instantFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const inst = try coerceInstant(self, allocator, arg(args, 0));
    return self.gcNewTemporal(.{ .instant = inst });
}

fn instantCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const a = try coerceInstant(self, allocator, arg(args, 0));
    const b = try coerceInstant(self, allocator, arg(args, 1));
    return JSValue.fromNumber(orderToJs(ztemporal.Instant.compare(a, b)));
}

fn instGetEpochMilliseconds(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try instSelf(interp(ctx), this_value)).epochMilliseconds()));
}

fn instGetEpochNanoseconds(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewBigIntValue(try zbigint.ZBigInt.fromI128(self.gc_allocator, (try instSelf(self, this_value)).epochNanoseconds()));
}

fn instAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const result = inst.add(d) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .instant = result });
}

fn instSubtract(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const result = inst.subtract(d) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .instant = result });
}

/// Instant.since/until use GetDifferenceSettings. It has a distinct
/// observable order and accepts Proxy/function option objects, so it must not
/// share the historical round-option reader.
fn readInstantDifferenceOptions(self: *Interpreter, options: JSValue) anyerror!RoundingOptions {
    try surfaceOptions(self, options);
    if (options == .undefined) return .{};

    const largest_unit = try readRoundingOptionString(self, options, "largestUnit");
    defer if (largest_unit) |value| self.gc_allocator.free(value);
    const rounding_increment = try readRoundingOptionNumber(self, options, "roundingIncrement");
    const rounding_mode = try readRoundingOptionString(self, options, "roundingMode");
    defer if (rounding_mode) |value| self.gc_allocator.free(value);
    const smallest_unit = try readRoundingOptionString(self, options, "smallestUnit");
    defer if (smallest_unit) |value| self.gc_allocator.free(value);

    var out: RoundingOptions = .{};
    if (largest_unit) |text| {
        if (!std.mem.eql(u8, text, "auto")) out.largestUnit = try unitFromString(self, text, "largestUnit");
    }
    if (rounding_increment) |number| {
        if (!std.math.isFinite(number) or number != @trunc(number) or number < 1 or number > 1_000_000_000)
            return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        out.roundingIncrement = @intFromFloat(number);
    }
    if (rounding_mode) |text| out.roundingMode = try roundingModeFromString(self, text);
    if (smallest_unit) |text| out.smallestUnit = try unitFromString(self, text, "smallestUnit");
    return out;
}

fn instUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const other = try coerceInstant(self, allocator, arg(args, 0));
    const opts = try readInstantDifferenceOptions(self, arg(args, 1));
    const d = inst.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn instSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const other = try coerceInstant(self, allocator, arg(args, 0));
    const opts = try readInstantDifferenceOptions(self, arg(args, 1));
    const d = inst.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

/// Instant.round has its own options algorithm. Keep it separate from the
/// shared reader: its properties are read in alphabetical order and all
/// algorithmic validation happens after those observable conversions.
fn readInstantRoundOptions(self: *Interpreter, options: JSValue) anyerror!RoundOptions {
    if (options == .undefined)
        return self.throwError(.type_error, "round() requires an options object", .{});
    if (options == .string) {
        return .{ .smallestUnit = try unitFromString(self, options.string.value.data, "smallestUnit") };
    }
    try surfaceOptions(self, options);

    const rounding_increment = try readRoundingOptionNumber(self, options, "roundingIncrement");
    const rounding_mode = try readRoundingOptionString(self, options, "roundingMode");
    defer if (rounding_mode) |value| self.gc_allocator.free(value);
    const smallest_unit = try readRoundingOptionString(self, options, "smallestUnit");
    defer if (smallest_unit) |value| self.gc_allocator.free(value);

    var out: RoundOptions = .{};
    if (rounding_increment) |number| {
        if (!std.math.isFinite(number)) return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        const integer = @trunc(number);
        if (integer < 1 or integer > 1_000_000_000)
            return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        out.roundingIncrement = @intFromFloat(integer);
    }
    if (rounding_mode) |text| out.roundingMode = try roundingModeFromString(self, text);
    out.smallestUnit = if (smallest_unit) |text|
        try unitFromString(self, text, "smallestUnit")
    else
        return self.throwError(.range_error, "round() requires smallestUnit", .{});
    return out;
}

fn instRound(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const opts = try readInstantRoundOptions(self, arg(args, 0));
    const result = inst.round(opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .instant = result });
}

fn instEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const other = try coerceInstant(self, allocator, arg(args, 0));
    return JSValue.fromBool(ztemporal.Instant.equals(inst, other));
}

fn instToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const options = try surfaceStringOptions(self, arg(args, 0), .instant);
    defer if (options.timeZone) |zone| self.gc_allocator.free(zone);
    const s = inst.toString(allocator, options) catch |e| return temporalErr(self, e);
    defer allocator.free(s);
    return self.gcNewString(s);
}

/// Closes out the item z-temporal's own README documents as "deferred
/// since Phase 5" -- an exact instant needs no disambiguation, so this
/// was always trivial once `ZonedDateTime`'s own `Io` story (`ioHandle`
/// above) existed.
fn instToZonedDateTimeISO(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const tz_arg = arg(args, 0);
    if (tz_arg != .string) return self.throwError(.type_error, "timeZone must be a string", .{});
    const zdt = inst.toZonedDateTimeISO(allocator, ioHandle(), tz_arg.string.value.data) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .zoned_date_time = zdt });
}

fn installInstant(self: *Interpreter, temporal_ns: JSValue) !void {
    const ctor = try self.gcNewFunction(.{ .ctx = self, .name = "Instant", .arity = 1, .call = instantConstructor, .constructable = true });
    const statics = try self.functionStatics(ctor);
    try dneMethod(statics, "from", try native(self, "from", 1, instantFrom));
    try dneMethod(statics, "compare", try native(self, "compare", 2, instantCompare));
    try dneMethod(statics, "fromEpochMilliseconds", try native(self, "fromEpochMilliseconds", 1, instantFromEpochMilliseconds));
    try dneMethod(statics, "fromEpochNanoseconds", try native(self, "fromEpochNanoseconds", 1, instantFromEpochNanoseconds));

    const proto = try self.functionPrototype(ctor);
    try installGetter(self, proto, "epochMilliseconds", instGetEpochMilliseconds);
    try installGetter(self, proto, "epochNanoseconds", instGetEpochNanoseconds);
    try dneMethod(proto, "add", try native(self, "add", 1, instAdd));
    try dneMethod(proto, "subtract", try native(self, "subtract", 1, instSubtract));
    try dneMethod(proto, "until", try native(self, "until", 1, instUntil));
    try dneMethod(proto, "since", try native(self, "since", 1, instSince));
    try dneMethod(proto, "round", try native(self, "round", 1, instRound));
    try dneMethod(proto, "equals", try native(self, "equals", 1, instEquals));
    try dneMethod(proto, "toString", try native(self, "toString", 0, instToString));
    try dneMethod(proto, "toZonedDateTimeISO", try native(self, "toZonedDateTimeISO", 1, instToZonedDateTimeISO));

    self.protos.temporal_instant = proto;
    try dneMethod(temporal_ns, "Instant", ctor);
}

// ===================== Duration =====================

fn durSelf(self: *Interpreter, this_value: JSValue) anyerror!ztemporal.Duration {
    return requireTemporal(self, this_value, .duration, "Temporal.Duration");
}

fn durationConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Temporal.Duration requires 'new'", .{});
    var vals: [10]f64 = @splat(0);
    for (0..@min(args.len, 10)) |i| {
        if (args[i] != .undefined) vals[i] = try requireDurationNumber(self, args[i], "duration field");
    }
    const d = ztemporal.Duration.init(vals[0], vals[1], vals[2], vals[3], vals[4], vals[5], vals[6], vals[7], vals[8], vals[9]) catch |e| return temporalErr(self, e);
    return constructedTemporal(self, .{ .duration = d });
}

const DurationFromRaw = struct {
    days: ?f64,
    hours: ?f64,
    microseconds: ?f64,
    milliseconds: ?f64,
    minutes: ?f64,
    months: ?f64,
    nanoseconds: ?f64,
    seconds: ?f64,
    weeks: ?f64,
    years: ?f64,
};

fn readDurationFromField(self: *Interpreter, item: JSValue, key: []const u8) anyerror!?f64 {
    const value = try self.getProperty(item, key);
    defer value.deinit();
    if (value == .undefined) return null;
    if (value == .bigint) return self.throwError(.type_error, "{s} must be a number", .{key});
    return try self.toNumberJS(value);
}

fn validateDurationFromField(self: *Interpreter, value: ?f64, key: []const u8) anyerror!?f64 {
    if (value) |number| return try requireDurationNumber(self, JSValue.fromNumber(number), key);
    return null;
}

/// Duration.from converts property bags through ToTemporalPartialDurationRecord.
/// Keep it here because other duration-like callers retain their current paths.
fn durationFromObservedBag(self: *Interpreter, item: JSValue) anyerror!ztemporal.Duration {
    const raw: DurationFromRaw = .{
        .days = try readDurationFromField(self, item, "days"),
        .hours = try readDurationFromField(self, item, "hours"),
        .microseconds = try readDurationFromField(self, item, "microseconds"),
        .milliseconds = try readDurationFromField(self, item, "milliseconds"),
        .minutes = try readDurationFromField(self, item, "minutes"),
        .months = try readDurationFromField(self, item, "months"),
        .nanoseconds = try readDurationFromField(self, item, "nanoseconds"),
        .seconds = try readDurationFromField(self, item, "seconds"),
        .weeks = try readDurationFromField(self, item, "weeks"),
        .years = try readDurationFromField(self, item, "years"),
    };
    return ztemporal.Duration.from(.{ .fields = .{
        .days = try validateDurationFromField(self, raw.days, "days"),
        .hours = try validateDurationFromField(self, raw.hours, "hours"),
        .microseconds = try validateDurationFromField(self, raw.microseconds, "microseconds"),
        .milliseconds = try validateDurationFromField(self, raw.milliseconds, "milliseconds"),
        .minutes = try validateDurationFromField(self, raw.minutes, "minutes"),
        .months = try validateDurationFromField(self, raw.months, "months"),
        .nanoseconds = try validateDurationFromField(self, raw.nanoseconds, "nanoseconds"),
        .seconds = try validateDurationFromField(self, raw.seconds, "seconds"),
        .weeks = try validateDurationFromField(self, raw.weeks, "weeks"),
        .years = try validateDurationFromField(self, raw.years, "years"),
    } }) catch |e| temporalErr(self, e);
}

fn durationFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const item = arg(args, 0);
    const d = if (item == .object or item == .proxy) try durationFromObservedBag(self, item) else try coerceDuration(self, item);
    return self.gcNewTemporal(.{ .duration = d });
}

fn durationCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const a = try coerceDuration(self, arg(args, 0));
    const b = try coerceDuration(self, arg(args, 1));
    const order = ztemporal.Duration.compare(a, b, .{
        .relativeTo = try readDurationCompareOptions(self, arg(args, 2)),
        .allocator = allocator,
        .io = ioHandle(),
    }) catch |e| return temporalErr(self, e);
    return JSValue.fromNumber(orderToJs(order));
}

/// Duration.compare has a distinct option record: only relativeTo is
/// observable. Coerce both duration arguments before rejecting primitive
/// options, as ToTemporalDuration precedes GetOptions in the specification.
fn readDurationCompareOptions(self: *Interpreter, options: JSValue) anyerror!?ztemporal.Duration.RelativeTo {
    try surfaceOptions(self, options);
    if (options == .undefined) return null;
    const v = try self.getProperty(options, "relativeTo");
    defer v.deinit();
    if (v == .undefined) return null;
    if (v == .temporal) switch (v.temporal.value) {
        .plain_date => |date| return .{ .plainDate = date },
        .plain_date_time => |dt| return .{ .plainDateTime = dt },
        .zoned_date_time => |dt| return .{ .zonedDateTime = dt },
        else => {},
    };
    if (v == .string) {
        if (relativeToHasTimeZoneAnnotation(v.string.value.data))
            return .{ .zonedDateTime = try coerceZonedDateTime(self, self.gc_allocator, v, .constrain, .compatible, .reject) };
        return .{ .plainDateTime = try coercePlainDateTime(self, v, .constrain) };
    }
    if (v == .object or v == .proxy) {
        const time_zone = try self.getProperty(v, "timeZone");
        defer time_zone.deinit();
        if (time_zone != .undefined) return .{ .zonedDateTime = try relativeToZonedDateTimeFromObservedBag(self, v) };
        return .{ .plainDateTime = try plainDateTimeFromObservedBag(self, v, JSValue.UNDEFINED, false) };
    }
    return .{ .plainDateTime = try coercePlainDateTime(self, v, .constrain) };
}

fn durField(comptime field: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = args;
            const d = try durSelf(interp(ctx), this_value);
            return JSValue.fromNumber(@field(d, field));
        }
    }.call;
}

fn durGetSign(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try durSelf(interp(ctx), this_value)).sign()));
}

fn durGetBlank(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromBool((try durSelf(interp(ctx), this_value)).blank());
}

fn durNegated(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewTemporal(.{ .duration = (try durSelf(self, this_value)).negated() });
}

fn durAbs(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewTemporal(.{ .duration = (try durSelf(self, this_value)).abs() });
}

const DurationWithRaw = struct {
    days: ?f64,
    hours: ?f64,
    microseconds: ?f64,
    milliseconds: ?f64,
    minutes: ?f64,
    months: ?f64,
    nanoseconds: ?f64,
    seconds: ?f64,
    weeks: ?f64,
    years: ?f64,
};

fn readDurationWithField(self: *Interpreter, fields: JSValue, key: []const u8) anyerror!?f64 {
    const value = try self.getProperty(fields, key);
    defer value.deinit();
    if (value == .undefined) return null;
    if (value == .bigint) return self.throwError(.type_error, "{s} must be a number", .{key});
    return try self.toNumberJS(value);
}

fn validateDurationWithField(self: *Interpreter, value: ?f64, key: []const u8) anyerror!?f64 {
    if (value) |number| return try requireDurationNumber(self, JSValue.fromNumber(number), key);
    return null;
}

/// Duration.with has no options argument. Its partial-duration fields are read
/// alphabetically and only then validated.
fn readDurationWithFields(self: *Interpreter, fields: JSValue) anyerror!DurationWithRaw {
    if (Interpreter.isPrimitiveTag(fields)) return self.throwError(.type_error, "with() requires an object", .{});
    return .{
        .days = try readDurationWithField(self, fields, "days"),
        .hours = try readDurationWithField(self, fields, "hours"),
        .microseconds = try readDurationWithField(self, fields, "microseconds"),
        .milliseconds = try readDurationWithField(self, fields, "milliseconds"),
        .minutes = try readDurationWithField(self, fields, "minutes"),
        .months = try readDurationWithField(self, fields, "months"),
        .nanoseconds = try readDurationWithField(self, fields, "nanoseconds"),
        .seconds = try readDurationWithField(self, fields, "seconds"),
        .weeks = try readDurationWithField(self, fields, "weeks"),
        .years = try readDurationWithField(self, fields, "years"),
    };
}

fn durWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const raw = try readDurationWithFields(self, arg(args, 0));
    const result = d.with(.{
        .days = try validateDurationWithField(self, raw.days, "days"),
        .hours = try validateDurationWithField(self, raw.hours, "hours"),
        .microseconds = try validateDurationWithField(self, raw.microseconds, "microseconds"),
        .milliseconds = try validateDurationWithField(self, raw.milliseconds, "milliseconds"),
        .minutes = try validateDurationWithField(self, raw.minutes, "minutes"),
        .months = try validateDurationWithField(self, raw.months, "months"),
        .nanoseconds = try validateDurationWithField(self, raw.nanoseconds, "nanoseconds"),
        .seconds = try validateDurationWithField(self, raw.seconds, "seconds"),
        .weeks = try validateDurationWithField(self, raw.weeks, "weeks"),
        .years = try validateDurationWithField(self, raw.years, "years"),
    }) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = result });
}

fn durAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const other = try coerceDuration(self, arg(args, 0));
    const result = d.add(other) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = result });
}

fn durSubtract(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const other = try coerceDuration(self, arg(args, 0));
    const result = d.subtract(other) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = result });
}

/// Calendar-unit operations carry `relativeTo` in their options. Preserve
/// PlainDate string/property-bag coercion and accept all three Temporal
/// reference types supported by z-temporal v0.1.0.
fn readRelativeTo(self: *Interpreter, options: JSValue) anyerror!?ztemporal.Duration.RelativeTo {
    if (options != .object) return null;
    const v = try self.getProperty(options, "relativeTo");
    defer v.deinit();
    if (v == .undefined) return null;
    if (v == .temporal) switch (v.temporal.value) {
        .plain_date => |date| return .{ .plainDate = date },
        .plain_date_time => |dt| return .{ .plainDateTime = dt },
        .zoned_date_time => |dt| return .{ .zonedDateTime = dt },
        else => {},
    };
    if (v == .string) {
        // A bracket annotation without '=' is a time-zone annotation. A
        // calendar annotation remains a PlainDateTime relativeTo.
        if (relativeToHasTimeZoneAnnotation(v.string.value.data))
            return .{ .zonedDateTime = try coerceZonedDateTime(self, self.gc_allocator, v, .constrain, .compatible, .reject) };
        return .{ .plainDateTime = try coercePlainDateTime(self, v, .constrain) };
    }
    // A property bag with timeZone denotes a ZonedDateTime. Route it through
    // the shared coercer so the timeZone type and identifier are validated.
    if (v == .object) {
        const time_zone = try self.getProperty(v, "timeZone");
        defer time_zone.deinit();
        if (time_zone != .undefined) return .{ .zonedDateTime = try relativeToZonedDateTimeFromObservedBag(self, v) };
        return .{ .plainDateTime = try plainDateTimeFromObservedBag(self, v, JSValue.UNDEFINED, false) };
    }
    // temporal-argument-coercion.md: `relativeTo` accepts a string or
    // property-bag too (real spec's ToRelativeTemporalObject), not
    // just an already-constructed instance -- found during that
    // plan's execution (this exact site wasn't caught by the original
    // `requireTemporal(self, arg(args, N), ...)` grep since it reads
    // from an options object, not directly from `args`). Confirmed
    // against Node: `Duration.round({smallestUnit:"week", relativeTo:
    // "2024-01-01"})` and the property-bag form both work.
    return .{ .plainDateTime = try coercePlainDateTime(self, v, .constrain) };
}

fn relativeToHasTimeZoneAnnotation(text: []const u8) bool {
    const open = std.mem.indexOfScalar(u8, text, '[') orelse return false;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, ']') orelse return false;
    return std.mem.indexOfScalar(u8, text[open + 1 .. close], '=') == null;
}

fn relativeToZonedDateTimeFromObservedBag(self: *Interpreter, fields: JSValue) anyerror!ztemporal.ZonedDateTime {
    const calendar_value = try self.getProperty(fields, "calendar");
    defer calendar_value.deinit();
    const calendar = try calendarFromValue(self, calendar_value);
    const day = try observedTemporalIntegerField(self, fields, "day");
    const hour = try observedTemporalIntegerField(self, fields, "hour");
    const microsecond = try observedTemporalIntegerField(self, fields, "microsecond");
    const millisecond = try observedTemporalIntegerField(self, fields, "millisecond");
    const minute = try observedTemporalIntegerField(self, fields, "minute");
    const month = try observedTemporalIntegerField(self, fields, "month");
    const month_code_value = try self.getProperty(fields, "monthCode");
    defer month_code_value.deinit();
    const month_code = if (month_code_value == .undefined) null else try self.toDisplayStringJS(self.gc_allocator, month_code_value);
    defer if (month_code) |code| self.gc_allocator.free(code);
    const nanosecond = try observedTemporalIntegerField(self, fields, "nanosecond");
    const offset_value = try self.getProperty(fields, "offset");
    defer offset_value.deinit();
    const offset = if (offset_value == .undefined) null else try self.toDisplayStringJS(self.gc_allocator, offset_value);
    defer if (offset) |text| self.gc_allocator.free(text);
    const second = try observedTemporalIntegerField(self, fields, "second");
    const time_zone_value = try self.getProperty(fields, "timeZone");
    defer time_zone_value.deinit();
    const time_zone = try surfaceZoneArgument(self, time_zone_value);
    defer self.gc_allocator.free(time_zone);
    const year = try observedTemporalIntegerField(self, fields, "year");
    return ztemporal.ZonedDateTime.from(self.gc_allocator, ioHandle(), .{ .fields = .{
        .year = year,
        .month = month,
        .monthCode = month_code,
        .day = day,
        .calendar = calendar,
        .hour = hour,
        .minute = minute,
        .second = second,
        .millisecond = millisecond,
        .microsecond = microsecond,
        .nanosecond = nanosecond,
        .timeZone = time_zone,
        .offset = offset,
    } }, .{ .overflow = .constrain, .offset = .reject, .disambiguation = .compatible }) catch |e| temporalErr(self, e);
}

const DurationRoundRaw = struct {
    largest_unit: ?[]u8 = null,
    rounding_increment: ?f64 = null,
    rounding_mode: ?[]u8 = null,
    smallest_unit: ?[]u8 = null,

    fn deinit(self: *DurationRoundRaw, allocator: Allocator) void {
        if (self.largest_unit) |value| allocator.free(value);
        if (self.rounding_mode) |value| allocator.free(value);
        if (self.smallest_unit) |value| allocator.free(value);
    }
};

/// Duration.round reads its option fields in the specification's alphabetical
/// sequence. This is intentionally separate from the shared readers.
fn readDurationRoundOptions(self: *Interpreter, options: JSValue, allocator: Allocator) anyerror!ztemporal.Duration.RoundOptions {
    if (options == .undefined) return self.throwError(.type_error, "round() requires an options object", .{});
    if (options == .string) {
        // The specification creates a null-prototype { smallestUnit } record.
        // Do not inspect Object.prototype-backed option fields on this path.
        return .{
            .smallestUnit = try unitFromString(self, options.string.value.data, "smallestUnit"),
            .allocator = allocator,
            .io = ioHandle(),
        };
    }
    try surfaceOptions(self, options);

    var raw: DurationRoundRaw = .{};
    defer raw.deinit(self.gc_allocator);
    // GetTemporalUnitValuedOption, GetTemporalRelativeToOption,
    // GetRoundingIncrementOption, GetRoundingModeOption, then smallestUnit.
    raw.largest_unit = try readRoundingOptionString(self, options, "largestUnit");
    const relative_to = try readDurationCompareOptions(self, options);
    raw.rounding_increment = try readRoundingOptionNumber(self, options, "roundingIncrement");
    raw.rounding_mode = try readRoundingOptionString(self, options, "roundingMode");
    raw.smallest_unit = try readRoundingOptionString(self, options, "smallestUnit");

    var out: ztemporal.Duration.RoundOptions = .{
        .relativeTo = relative_to,
        .allocator = allocator,
        .io = ioHandle(),
    };
    if (raw.largest_unit) |text| {
        if (!std.mem.eql(u8, text, "auto")) out.largestUnit = try unitFromString(self, text, "largestUnit");
    }
    if (raw.rounding_increment) |number| {
        if (!std.math.isFinite(number) or number != @trunc(number) or number < 1 or number > 1_000_000_000)
            return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        out.roundingIncrement = @intFromFloat(number);
    }
    if (raw.rounding_mode) |text| out.roundingMode = try roundingModeFromString(self, text);
    if (raw.smallest_unit) |text| out.smallestUnit = try unitFromString(self, text, "smallestUnit");
    return out;
}

fn durRound(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const result = d.round(try readDurationRoundOptions(self, arg(args, 0), allocator)) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = result });
}

/// Duration.total observes relativeTo before unit, then performs the unit and
/// relative-duration checks only after both values have been acquired.
fn readDurationTotalOptions(self: *Interpreter, options: JSValue, allocator: Allocator) anyerror!ztemporal.Duration.TotalOptions {
    if (options == .undefined) return self.throwError(.type_error, "total() requires an options object", .{});
    if (options == .string) {
        // The shorthand is a conceptual null-prototype { unit } object.
        return .{ .unit = try unitFromString(self, options.string.value.data, "unit"), .allocator = allocator, .io = ioHandle() };
    }
    try surfaceOptions(self, options);

    const relative_to = try readDurationCompareOptions(self, options);
    const unit_value = try self.getProperty(options, "unit");
    defer unit_value.deinit();
    if (unit_value == .undefined) return self.throwError(.range_error, "total() requires a unit", .{});
    const unit_text = try self.toDisplayStringJS(self.gc_allocator, unit_value);
    defer self.gc_allocator.free(unit_text);
    return .{
        .relativeTo = relative_to,
        .unit = try unitFromString(self, unit_text, "unit"),
        .allocator = allocator,
        .io = ioHandle(),
    };
}

fn durTotal(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const result = d.total(try readDurationTotalOptions(self, arg(args, 0), allocator)) catch |e| return temporalErr(self, e);
    return JSValue.fromNumber(result);
}

fn durToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const options = try surfaceStringOptions(self, arg(args, 0), .duration);
    const s = d.toString(allocator, options) catch |e| return temporalErr(self, e);
    defer allocator.free(s);
    return self.gcNewString(s);
}

fn installDuration(self: *Interpreter, temporal_ns: JSValue) !void {
    const ctor = try self.gcNewFunction(.{ .ctx = self, .name = "Duration", .arity = 0, .call = durationConstructor, .constructable = true });
    const statics = try self.functionStatics(ctor);
    try dneMethod(statics, "from", try native(self, "from", 1, durationFrom));
    try dneMethod(statics, "compare", try native(self, "compare", 2, durationCompare));

    const proto = try self.functionPrototype(ctor);
    try installGetter(self, proto, "years", durField("years"));
    try installGetter(self, proto, "months", durField("months"));
    try installGetter(self, proto, "weeks", durField("weeks"));
    try installGetter(self, proto, "days", durField("days"));
    try installGetter(self, proto, "hours", durField("hours"));
    try installGetter(self, proto, "minutes", durField("minutes"));
    try installGetter(self, proto, "seconds", durField("seconds"));
    try installGetter(self, proto, "milliseconds", durField("milliseconds"));
    try installGetter(self, proto, "microseconds", durField("microseconds"));
    try installGetter(self, proto, "nanoseconds", durField("nanoseconds"));
    try installGetter(self, proto, "sign", durGetSign);
    try installGetter(self, proto, "blank", durGetBlank);
    try dneMethod(proto, "negated", try native(self, "negated", 0, durNegated));
    try dneMethod(proto, "abs", try native(self, "abs", 0, durAbs));
    try dneMethod(proto, "with", try native(self, "with", 1, durWith));
    try dneMethod(proto, "add", try native(self, "add", 1, durAdd));
    try dneMethod(proto, "subtract", try native(self, "subtract", 1, durSubtract));
    try dneMethod(proto, "round", try native(self, "round", 1, durRound));
    try dneMethod(proto, "total", try native(self, "total", 1, durTotal));
    try dneMethod(proto, "toString", try native(self, "toString", 0, durToString));

    self.protos.temporal_duration = proto;
    try dneMethod(temporal_ns, "Duration", ctor);
}

// ===================== PlainYearMonth =====================

fn pymSelf(self: *Interpreter, this_value: JSValue) anyerror!ztemporal.PlainYearMonth {
    return requireTemporal(self, this_value, .plain_year_month, "Temporal.PlainYearMonth");
}

fn plainYearMonthConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Temporal.PlainYearMonth requires 'new'", .{});
    const year = try coerceConstructorI32(self, arg(args, 0), "year");
    const month = try coerceConstructorI32(self, arg(args, 1), "month");
    const reference_day: ?i32 = if (arg(args, 3) == .undefined) null else try coerceConstructorI32(self, arg(args, 3), "referenceISODay");
    const pym = ztemporal.PlainYearMonth.init(year, month, try optionalConstructorCalendar(self, arg(args, 2)), reference_day) catch |e| return temporalErr(self, e);
    return constructedTemporal(self, .{ .plain_year_month = pym });
}

fn plainYearMonthFromObservedBag(self: *Interpreter, fields: JSValue, options: JSValue, strict_month_code: bool) anyerror!ztemporal.PlainYearMonth {
    const calendar_value = try self.getProperty(fields, "calendar");
    defer calendar_value.deinit();
    const calendar = try calendarFromValue(self, calendar_value);
    const month = try observedTemporalIntegerField(self, fields, "month");
    const month_code_value = try self.getProperty(fields, "monthCode");
    defer month_code_value.deinit();
    var owned_month_code: ?[]u8 = null;
    defer if (owned_month_code) |code| self.gc_allocator.free(code);
    const month_code: ?[]const u8 = if (month_code_value == .undefined) null else if (strict_month_code) blk: {
        if (month_code_value != .string) return self.throwError(.type_error, "monthCode must be a string", .{});
        break :blk month_code_value.string.value.data;
    } else blk: {
        const code = try self.toDisplayStringJS(self.gc_allocator, month_code_value);
        owned_month_code = code;
        break :blk code;
    };
    const year = try observedTemporalIntegerField(self, fields, "year");
    const overflow = try observableFromOverflow(self, options);
    return ztemporal.PlainYearMonth.from(.{ .fields = .{
        .year = year orelse return self.throwError(.type_error, "year is required", .{}),
        .monthCode = month_code,
        .month = month,
        .calendar = calendar,
    } }, .{ .overflow = overflow }) catch |e| temporalErr(self, e);
}

fn plainYearMonthFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const value = arg(args, 0);
    const options = arg(args, 1);
    if (Interpreter.isPrimitiveTag(value) and value != .string)
        return self.throwError(.type_error, "Temporal.PlainYearMonth.from requires a string or an object", .{});
    if (value == .string)
        _ = ztemporal.iso_string.parsePlainYearMonth(value.string.value.data) catch |e| return temporalErr(self, e);
    const pym = if (value == .object or value == .proxy)
        try plainYearMonthFromObservedBag(self, value, options, true)
    else blk: {
        const overflow = try observableFromOverflow(self, options);
        break :blk try coercePlainYearMonth(self, value, overflow);
    };
    return self.gcNewTemporal(.{ .plain_year_month = pym });
}

fn plainYearMonthCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try coercePlainYearMonth(self, arg(args, 0), .constrain);
    const b = try coercePlainYearMonth(self, arg(args, 1), .constrain);
    return JSValue.fromNumber(orderToJs(ztemporal.PlainYearMonth.compare(a, b)));
}

fn pymGetYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pymSelf(interp(ctx), this_value)).year()));
}
fn pymGetMonth(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pymSelf(interp(ctx), this_value)).month()));
}
fn pymGetMonthCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    var buf: [4]u8 = undefined;
    return self.gcNewString((try pymSelf(self, this_value)).monthCode(&buf));
}
fn pymGetCalendarId(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewString((try pymSelf(self, this_value)).calendarId());
}
fn pymGetDaysInMonth(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pymSelf(interp(ctx), this_value)).daysInMonth()));
}
fn pymGetDaysInYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pymSelf(interp(ctx), this_value)).daysInYear()));
}
fn pymGetMonthsInYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pymSelf(interp(ctx), this_value)).monthsInYear()));
}
fn pymGetInLeapYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromBool((try pymSelf(interp(ctx), this_value)).inLeapYear());
}

fn pymToPlainDate(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const fields = arg(args, 0);
    const day = (try optionalI32(self, fields, "day")) orelse return self.throwError(.type_error, "day is required", .{});
    const pd = pym.toPlainDate(day) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = pd });
}

fn pymWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const fields = arg(args, 0);
    if (fields != .object and fields != .proxy) return self.throwError(.type_error, "with() requires an object", .{});
    try rejectWithCalendarOrTimeZone(self, fields);
    const month = try plainOptionalI32(self, fields, "month");
    const month_code = try plainOptionalString(self, fields, "monthCode");
    defer if (month_code) |value| self.gc_allocator.free(value);
    const year = try plainOptionalI32(self, fields, "year");
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pym.with(.{
        .year = year,
        .month = month,
        .monthCode = month_code,
    }, .{
        .overflow = overflow,
    }) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_year_month = result });
}

fn pymAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pym.add(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_year_month = result });
}

fn pymSubtract(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pym.subtract(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_year_month = result });
}

fn pymUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const other = try coercePlainYearMonth(self, arg(args, 0), .constrain);
    const opts = try readPlainRoundingOptions(self, arg(args, 1));
    const d = pym.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pymSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const other = try coercePlainYearMonth(self, arg(args, 0), .constrain);
    const opts = try readPlainRoundingOptions(self, arg(args, 1));
    const d = pym.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pymEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const other = try coercePlainYearMonth(self, arg(args, 0), .constrain);
    return JSValue.fromBool(ztemporal.PlainYearMonth.equals(pym, other));
}

fn pymToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const calendar_name = try surfaceEnum(self, arg(args, 0), "calendarName", ztemporal.CalendarName, .auto);
    const s = pym.toString(allocator, .{ .calendarName = calendar_name }) catch |e| return temporalErr(self, e);
    defer allocator.free(s);
    return self.gcNewString(s);
}

fn installPlainYearMonth(self: *Interpreter, temporal_ns: JSValue) !void {
    const ctor = try self.gcNewFunction(.{ .ctx = self, .name = "PlainYearMonth", .arity = 2, .call = plainYearMonthConstructor, .constructable = true });
    const statics = try self.functionStatics(ctor);
    try dneMethod(statics, "from", try native(self, "from", 1, plainYearMonthFrom));
    try dneMethod(statics, "compare", try native(self, "compare", 2, plainYearMonthCompare));

    const proto = try self.functionPrototype(ctor);
    try installGetter(self, proto, "year", pymGetYear);
    try installGetter(self, proto, "month", pymGetMonth);
    try installGetter(self, proto, "monthCode", pymGetMonthCode);
    try installGetter(self, proto, "calendarId", pymGetCalendarId);
    try installGetter(self, proto, "daysInMonth", pymGetDaysInMonth);
    try installGetter(self, proto, "daysInYear", pymGetDaysInYear);
    try installGetter(self, proto, "monthsInYear", pymGetMonthsInYear);
    try installGetter(self, proto, "inLeapYear", pymGetInLeapYear);
    try dneMethod(proto, "toPlainDate", try native(self, "toPlainDate", 1, pymToPlainDate));
    try dneMethod(proto, "with", try native(self, "with", 1, pymWith));
    try dneMethod(proto, "add", try native(self, "add", 1, pymAdd));
    try dneMethod(proto, "subtract", try native(self, "subtract", 1, pymSubtract));
    try dneMethod(proto, "until", try native(self, "until", 1, pymUntil));
    try dneMethod(proto, "since", try native(self, "since", 1, pymSince));
    try dneMethod(proto, "equals", try native(self, "equals", 1, pymEquals));
    try dneMethod(proto, "toString", try native(self, "toString", 0, pymToString));

    self.protos.temporal_plain_year_month = proto;
    try dneMethod(temporal_ns, "PlainYearMonth", ctor);
}

// ===================== PlainMonthDay =====================
// NOTE: real Temporal.PlainMonthDay has ZERO arithmetic (no add/subtract/
// until/since/compare/round on the real prototype -- ground-truthed in
// z-temporal's own Phase 4 notes) -- only construction/parsing/equals/
// toPlainDate/toString, matching what's wired below.

fn pmdSelf(self: *Interpreter, this_value: JSValue) anyerror!ztemporal.PlainMonthDay {
    return requireTemporal(self, this_value, .plain_month_day, "Temporal.PlainMonthDay");
}

fn plainMonthDayConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Temporal.PlainMonthDay requires 'new'", .{});
    const month = try coerceConstructorI32(self, arg(args, 0), "month");
    const day = try coerceConstructorI32(self, arg(args, 1), "day");
    const calendar_arg = arg(args, 2);
    const calendar: ?[]const u8 = if (calendar_arg == .undefined) null else if (calendar_arg == .string) calendar_arg.string.value.data else return self.throwError(.type_error, "calendar must be a string", .{});
    const reference_year: ?i32 = if (arg(args, 3) == .undefined) null else try coerceConstructorI32(self, arg(args, 3), "referenceISOYear");
    const pmd = ztemporal.PlainMonthDay.init(month, day, calendar, reference_year) catch |e| return temporalErr(self, e);
    return constructedTemporal(self, .{ .plain_month_day = pmd });
}

fn validatePlainMonthDayMonthCodeSyntax(self: *Interpreter, code: []const u8) anyerror!void {
    if ((code.len != 3 and code.len != 4) or code[0] != 'M' or
        !std.ascii.isDigit(code[1]) or !std.ascii.isDigit(code[2]) or
        (code.len == 4 and code[3] != 'L'))
    {
        return self.throwError(.range_error, "Invalid monthCode syntax", .{});
    }
}

fn validatePlainMonthDayMonthCode(self: *Interpreter, code: []const u8, month: ?i32) anyerror!void {
    const code_month: i32 = @as(i32, code[1] - '0') * 10 + @as(i32, code[2] - '0');
    if (code_month < 1 or code_month > 12 or code.len == 4)
        return self.throwError(.range_error, "Invalid monthCode", .{});
    if (month) |numeric_month| {
        if (numeric_month >= 1 and numeric_month <= 12 and numeric_month != code_month)
            return self.throwError(.range_error, "month and monthCode conflict", .{});
    }
}

fn plainMonthDayFromObservedBag(self: *Interpreter, fields: JSValue, options: JSValue) anyerror!ztemporal.PlainMonthDay {
    const calendar_value = try self.getProperty(fields, "calendar");
    defer calendar_value.deinit();
    const calendar = try calendarFromValue(self, calendar_value);
    const day = try observedTemporalIntegerField(self, fields, "day");
    const month = try observedTemporalIntegerField(self, fields, "month");
    const month_code_value = try self.getProperty(fields, "monthCode");
    defer month_code_value.deinit();
    const month_code = if (month_code_value == .undefined) null else try self.toDisplayStringJS(self.gc_allocator, month_code_value);
    defer if (month_code) |code| self.gc_allocator.free(code);
    if (month == null and month_code == null)
        return self.throwError(.type_error, "month or monthCode is required", .{});
    const required_day = day orelse return self.throwError(.type_error, "day is required", .{});
    if (month_code) |code| try validatePlainMonthDayMonthCodeSyntax(self, code);
    const year = try observedTemporalIntegerField(self, fields, "year");
    const overflow = try observableFromOverflow(self, options);
    if (month_code) |code| try validatePlainMonthDayMonthCode(self, code, month);
    return ztemporal.PlainMonthDay.from(.{ .fields = .{
        .monthCode = month_code,
        .month = month,
        .day = required_day,
        .year = year,
        .calendar = calendar,
    } }, .{ .overflow = overflow }) catch |e| temporalErr(self, e);
}

fn plainMonthDayFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const value = arg(args, 0);
    const options = arg(args, 1);
    const parsed_string: ?ztemporal.PlainMonthDay = if (value == .string) try coercePlainMonthDay(self, value, .constrain) else null;
    // PrepareTemporalFields accepts every ECMAScript Object. Keep Temporal
    // instances on their existing conversion path, but let Proxy, callable,
    // and other object-shaped bags use the observable field reader.
    const pmd = if (!Interpreter.isPrimitiveTag(value) and value != .temporal)
        try plainMonthDayFromObservedBag(self, value, options)
    else blk: {
        const result = parsed_string orelse try coercePlainMonthDay(self, value, .constrain);
        _ = try observableFromOverflow(self, options);
        break :blk result;
    };
    return self.gcNewTemporal(.{ .plain_month_day = pmd });
}

fn pmdGetDay(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try pmdSelf(interp(ctx), this_value)).day()));
}
fn pmdGetMonthCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    var buf: [4]u8 = undefined;
    return self.gcNewString((try pmdSelf(self, this_value)).monthCode(&buf));
}
fn pmdGetCalendarId(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewString((try pmdSelf(self, this_value)).calendarId());
}

fn pmdToPlainDate(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pmd = try pmdSelf(self, this_value);
    const fields = arg(args, 0);
    const year = (try optionalI32(self, fields, "year")) orelse return self.throwError(.type_error, "year is required", .{});
    const pd = pmd.toPlainDate(year) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = pd });
}

fn pmdWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pmd = try pmdSelf(self, this_value);
    const fields = arg(args, 0);
    if (fields != .object and fields != .proxy) return self.throwError(.type_error, "with() requires an object", .{});
    try rejectWithCalendarOrTimeZone(self, fields);
    const day = try plainOptionalI32(self, fields, "day");
    const month = try plainOptionalI32(self, fields, "month");
    const month_code = try plainOptionalString(self, fields, "monthCode");
    defer if (month_code) |value| self.gc_allocator.free(value);
    const year = try plainOptionalI32(self, fields, "year");
    const overflow = try readPlainOverflow(self, arg(args, 1));
    const result = pmd.with(.{
        .month = month,
        .day = day,
        .monthCode = month_code,
        .year = year,
    }, .{
        .overflow = overflow,
    }) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_month_day = result });
}

fn pmdEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pmd = try pmdSelf(self, this_value);
    const other = try coercePlainMonthDay(self, arg(args, 0), .constrain);
    return JSValue.fromBool(ztemporal.PlainMonthDay.equals(pmd, other));
}

fn pmdToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const pmd = try pmdSelf(self, this_value);
    const calendar_name = try surfaceEnum(self, arg(args, 0), "calendarName", ztemporal.CalendarName, .auto);
    const s = pmd.toString(allocator, .{ .calendarName = calendar_name }) catch |e| return temporalErr(self, e);
    defer allocator.free(s);
    return self.gcNewString(s);
}

fn installPlainMonthDay(self: *Interpreter, temporal_ns: JSValue) !void {
    const ctor = try self.gcNewFunction(.{ .ctx = self, .name = "PlainMonthDay", .arity = 2, .call = plainMonthDayConstructor, .constructable = true });
    const statics = try self.functionStatics(ctor);
    try dneMethod(statics, "from", try native(self, "from", 1, plainMonthDayFrom));

    const proto = try self.functionPrototype(ctor);
    try installGetter(self, proto, "day", pmdGetDay);
    try installGetter(self, proto, "monthCode", pmdGetMonthCode);
    try installGetter(self, proto, "calendarId", pmdGetCalendarId);
    try dneMethod(proto, "toPlainDate", try native(self, "toPlainDate", 1, pmdToPlainDate));
    try dneMethod(proto, "with", try native(self, "with", 1, pmdWith));
    try dneMethod(proto, "equals", try native(self, "equals", 1, pmdEquals));
    try dneMethod(proto, "toString", try native(self, "toString", 0, pmdToString));

    self.protos.temporal_plain_month_day = proto;
    try dneMethod(temporal_ns, "PlainMonthDay", ctor);
}

// ===================== ZonedDateTime =====================
// temporal-zoneddatetime-now-wiring.md: the one type needing real I/O
// (IANA tzdata) -- see `ioHandle()`'s doc comment above.

fn zdtSelf(self: *Interpreter, this_value: JSValue) anyerror!ztemporal.ZonedDateTime {
    return requireTemporal(self, this_value, .zoned_date_time, "Temporal.ZonedDateTime");
}

fn zonedDateTimeConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Temporal.ZonedDateTime requires 'new'", .{});
    const ns = try coerceEpochNanoseconds(self, arg(args, 0), "epochNanoseconds");
    const tz_arg = arg(args, 1);
    if (tz_arg != .string) return self.throwError(.type_error, "timeZone must be a string", .{});
    const calendar = try optionalConstructorCalendar(self, arg(args, 2));
    const zdt = ztemporal.ZonedDateTime.init(allocator, ioHandle(), ns, tz_arg.string.value.data, calendar) catch |e| return temporalErr(self, e);
    return constructedTemporal(self, .{ .zoned_date_time = zdt });
}

/// temporal-argument-coercion.md: same "instance/string/property-bag"
/// shape as the 6 `coerceXxx` helpers above, extracted from
/// `zonedDateTimeFrom` for reuse by `zonedDateTimeCompare`/`zdtEquals`
/// (no `options` of their own -- defaults: `overflow: .constrain`,
/// `disambiguation: .compatible`, `offsetOption: .reject`, matching
/// each's own real-spec default when `.from()`'s own `options` is
/// omitted).
const ZonedDateTimeBagRaw = struct {
    calendar: JSValue,
    day: JSValue,
    hour: JSValue,
    microsecond: JSValue,
    millisecond: JSValue,
    minute: JSValue,
    month: JSValue,
    month_code: JSValue,
    nanosecond: JSValue,
    offset: JSValue,
    second: JSValue,
    time_zone: JSValue,
    year: JSValue,

    fn deinit(self: *ZonedDateTimeBagRaw) void {
        inline for (@typeInfo(ZonedDateTimeBagRaw).@"struct".field_names) |name| @field(self, name).deinit();
    }
};

const ZonedDateTimeFromOptions = struct {
    overflow: Overflow,
    disambiguation: ztemporal.Disambiguation,
    offset: ztemporal.OffsetOption,
};

/// PrepareTemporalFields reads every field before conversions or validation.
/// Keeping the raw values alive makes this true for ordinary objects, Proxy,
/// functions, and every other ECMAScript object tag.
fn readZonedDateTimeBagRaw(self: *Interpreter, fields: JSValue) anyerror!ZonedDateTimeBagRaw {
    var raw: ZonedDateTimeBagRaw = undefined;
    raw.calendar = try self.getProperty(fields, "calendar");
    errdefer raw.calendar.deinit();
    raw.day = try self.getProperty(fields, "day");
    errdefer raw.day.deinit();
    raw.hour = try self.getProperty(fields, "hour");
    errdefer raw.hour.deinit();
    raw.microsecond = try self.getProperty(fields, "microsecond");
    errdefer raw.microsecond.deinit();
    raw.millisecond = try self.getProperty(fields, "millisecond");
    errdefer raw.millisecond.deinit();
    raw.minute = try self.getProperty(fields, "minute");
    errdefer raw.minute.deinit();
    raw.month = try self.getProperty(fields, "month");
    errdefer raw.month.deinit();
    raw.month_code = try self.getProperty(fields, "monthCode");
    errdefer raw.month_code.deinit();
    raw.nanosecond = try self.getProperty(fields, "nanosecond");
    errdefer raw.nanosecond.deinit();
    raw.offset = try self.getProperty(fields, "offset");
    errdefer raw.offset.deinit();
    raw.second = try self.getProperty(fields, "second");
    errdefer raw.second.deinit();
    raw.time_zone = try self.getProperty(fields, "timeZone");
    errdefer raw.time_zone.deinit();
    raw.year = try self.getProperty(fields, "year");
    return raw;
}

fn zonedDateTimeIntegerFromValue(self: *Interpreter, value: JSValue, key: []const u8) anyerror!?i32 {
    if (value == .undefined) return null;
    const number = try self.toNumberJS(value);
    if (!std.math.isFinite(number)) return self.throwError(.range_error, "{s} must be finite", .{key});
    const integer = @trunc(number);
    if (integer < std.math.minInt(i32) or integer > std.math.maxInt(i32))
        return self.throwError(.range_error, "{s} out of range", .{key});
    return @intFromFloat(integer);
}

fn zonedDateTimeMonthCodeFromValue(self: *Interpreter, value: JSValue, strict_month_code: bool) anyerror!?[]u8 {
    if (value == .undefined) return null;
    const code = if (strict_month_code) blk: {
        if (value != .string) return self.throwError(.type_error, "monthCode must be a string", .{});
        break :blk try self.gc_allocator.dupe(u8, value.string.value.data);
    } else try self.toDisplayStringJS(self.gc_allocator, value);
    errdefer self.gc_allocator.free(code);
    // Month-code syntax is checked before later field conversions. Its
    // calendar suitability remains z-temporal validation after all fields.
    if ((code.len != 3 and code.len != 4) or code[0] != 'M' or
        !std.ascii.isDigit(code[1]) or !std.ascii.isDigit(code[2]) or
        (code.len == 4 and code[3] != 'L'))
    {
        return self.throwError(.range_error, "Invalid monthCode syntax", .{});
    }
    return code;
}

/// Offset fields in a direct ZonedDateTime.from() property bag use ToString
/// for objects, but reject primitive values other than strings.  The generic
/// ToTemporalZonedDateTime paths used by compare()/equals() require a string
/// outright.  Keep that distinction at this local coercion boundary.
fn zonedDateTimeOffsetFromValue(self: *Interpreter, value: JSValue, coerce_objects: bool) anyerror!?[]u8 {
    if (value == .undefined) return null;
    if (value == .string) return try self.gc_allocator.dupe(u8, value.string.value.data);
    if (coerce_objects and !Interpreter.isPrimitiveTag(value))
        return try self.toDisplayStringJS(self.gc_allocator, value);
    return self.throwError(.type_error, "Temporal offset must be a string", .{});
}

/// Validate offset grammar before later field conversions.  The typed
/// ZonedDateTime constructor validates this only after creating its
/// PlainDateTime, whereas Temporal requires malformed offset syntax to win
/// over a later field type error.
fn validateZonedDateTimeOffsetSyntax(self: *Interpreter, offset: []const u8) anyerror!void {
    if (offset.len == 0 or offset[0] == 'Z' or offset[0] == 'z')
        return self.throwError(.range_error, "Invalid UTC offset", .{});
    const source = try std.fmt.allocPrint(self.gc_allocator, "1970-01-01T00:00{s}", .{offset});
    defer self.gc_allocator.free(source);
    _ = ztemporal.iso_string.parseInstant(source) catch |e| return temporalErr(self, e);
}

fn zonedDateTimeOptionFromValue(self: *Interpreter, value: JSValue, key: []const u8, comptime T: type, fallback: T) anyerror!T {
    if (value == .undefined) return fallback;
    const text = try self.toDisplayStringJS(self.gc_allocator, value);
    defer self.gc_allocator.free(text);
    inline for (@typeInfo(T).@"enum".field_names) |name| {
        if (std.mem.eql(u8, text, name)) return @field(T, name);
    }
    return self.throwError(.range_error, "Invalid {s}: {s}", .{ key, text });
}

/// ZonedDateTime.from obtains its option values after a property-bag's fields,
/// but obtains all three option properties before validating any of them.
fn readZonedDateTimeFromOptions(self: *Interpreter, options: JSValue) anyerror!ZonedDateTimeFromOptions {
    try surfaceOptions(self, options);
    if (options == .undefined) return .{ .overflow = .constrain, .disambiguation = .compatible, .offset = .reject };
    const disambiguation = try self.getProperty(options, "disambiguation");
    defer disambiguation.deinit();
    const offset = try self.getProperty(options, "offset");
    defer offset.deinit();
    const overflow = try self.getProperty(options, "overflow");
    defer overflow.deinit();
    return .{
        .disambiguation = try zonedDateTimeOptionFromValue(self, disambiguation, "disambiguation", ztemporal.Disambiguation, .compatible),
        .offset = try zonedDateTimeOptionFromValue(self, offset, "offset", ztemporal.OffsetOption, .reject),
        .overflow = try zonedDateTimeOptionFromValue(self, overflow, "overflow", Overflow, .constrain),
    };
}

fn zonedDateTimeFromRawBag(self: *Interpreter, allocator: Allocator, raw: *const ZonedDateTimeBagRaw, options: ZonedDateTimeFromOptions, strict_month_code: bool, coerce_offset_objects: bool) anyerror!ztemporal.ZonedDateTime {
    const calendar = try calendarFromValue(self, raw.calendar);
    // Preserve the established calendar error priority over a missing
    // timeZone, after all observable field reads have completed.
    if (calendar) |id| _ = ztemporal.PlainDate.init(1970, 1, 1, id) catch |e| return temporalErr(self, e);
    const day = try zonedDateTimeIntegerFromValue(self, raw.day, "day");
    const hour = try zonedDateTimeIntegerFromValue(self, raw.hour, "hour");
    const microsecond = try zonedDateTimeIntegerFromValue(self, raw.microsecond, "microsecond");
    const millisecond = try zonedDateTimeIntegerFromValue(self, raw.millisecond, "millisecond");
    const minute = try zonedDateTimeIntegerFromValue(self, raw.minute, "minute");
    const month = try zonedDateTimeIntegerFromValue(self, raw.month, "month");
    const month_code = try zonedDateTimeMonthCodeFromValue(self, raw.month_code, strict_month_code);
    defer if (month_code) |code| self.gc_allocator.free(code);
    const nanosecond = try zonedDateTimeIntegerFromValue(self, raw.nanosecond, "nanosecond");
    const offset = try zonedDateTimeOffsetFromValue(self, raw.offset, coerce_offset_objects);
    defer if (offset) |text| self.gc_allocator.free(text);
    if (offset) |text| try validateZonedDateTimeOffsetSyntax(self, text);
    const second = try zonedDateTimeIntegerFromValue(self, raw.second, "second");
    if (raw.time_zone == .undefined) return self.throwError(.type_error, "timeZone is required", .{});
    const time_zone = try surfaceZone(self, raw.time_zone);
    const year = try zonedDateTimeIntegerFromValue(self, raw.year, "year");
    return ztemporal.ZonedDateTime.from(allocator, ioHandle(), .{ .fields = .{
        .year = year orelse return self.throwError(.type_error, "year is required", .{}),
        .month = month,
        .monthCode = month_code,
        .day = day orelse return self.throwError(.type_error, "day is required", .{}),
        .calendar = calendar,
        .hour = hour orelse 0,
        .minute = minute orelse 0,
        .second = second orelse 0,
        .millisecond = millisecond orelse 0,
        .microsecond = microsecond orelse 0,
        .nanosecond = nanosecond orelse 0,
        .timeZone = time_zone,
        .offset = offset,
    } }, .{
        .overflow = options.overflow,
        .disambiguation = options.disambiguation,
        .offset = options.offset,
    }) catch |e| temporalErr(self, e);
}

fn coerceZonedDateTime(self: *Interpreter, allocator: Allocator, v: JSValue, overflow: Overflow, disambiguation: ztemporal.Disambiguation, offset_option: ztemporal.OffsetOption) anyerror!ztemporal.ZonedDateTime {
    if (v == .temporal and v.temporal.value == .zoned_date_time) return v.temporal.value.zoned_date_time;
    if (v == .string) return ztemporal.ZonedDateTime.from(allocator, ioHandle(), .{
        .string = v.string.value.data,
    }, .{
        .overflow = overflow,
        .offset = offset_option,
        .disambiguation = disambiguation,
    }) catch |e| temporalErr(self, e);
    if (Interpreter.isPrimitiveTag(v)) return self.throwError(.type_error, "Temporal.ZonedDateTime.from requires a string or an object", .{});
    var raw = try readZonedDateTimeBagRaw(self, v);
    defer raw.deinit();
    return zonedDateTimeFromRawBag(self, allocator, &raw, .{ .overflow = overflow, .disambiguation = disambiguation, .offset = offset_option }, false, false);
}

fn zonedDateTimeFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const item = arg(args, 0);
    const option_value = arg(args, 1);
    const zdt = if (item == .temporal and item.temporal.value == .zoned_date_time) blk: {
        // ZonedDateTime.from(instance, options) returns an equivalent fresh
        // Temporal value, but still performs all three option conversions.
        _ = try readZonedDateTimeFromOptions(self, option_value);
        break :blk item.temporal.value.zoned_date_time;
    } else if (item == .string) blk: {
        // ISO parsing precedes option access. Use `ignore` only for this
        // syntax preflight: user-supplied offset policy still governs the
        // actual conversion below.
        _ = ztemporal.ZonedDateTime.from(allocator, ioHandle(), .{ .string = item.string.value.data }, .{
            .overflow = .constrain,
            .offset = .ignore,
            .disambiguation = .compatible,
        }) catch |e| return temporalErr(self, e);
        const options = try readZonedDateTimeFromOptions(self, option_value);
        break :blk try coerceZonedDateTime(self, allocator, item, options.overflow, options.disambiguation, options.offset);
    } else if (!Interpreter.isPrimitiveTag(item) and !(item == .temporal and item.temporal.value == .zoned_date_time)) blk: {
        var raw = try readZonedDateTimeBagRaw(self, item);
        defer raw.deinit();
        const options = try readZonedDateTimeFromOptions(self, option_value);
        break :blk try zonedDateTimeFromRawBag(self, allocator, &raw, options, true, true);
    } else blk: {
        // Primitive non-strings fail before options are observable.
        break :blk try coerceZonedDateTime(self, allocator, item, .constrain, .compatible, .reject);
    };
    return self.gcNewTemporal(.{ .zoned_date_time = zdt });
}

fn zonedDateTimeCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const a = try coerceZonedDateTime(self, allocator, arg(args, 0), .constrain, .compatible, .reject);
    const b = try coerceZonedDateTime(self, allocator, arg(args, 1), .constrain, .compatible, .reject);
    return JSValue.fromNumber(orderToJs(ztemporal.ZonedDateTime.compare(a, b)));
}

// ----- Getters needing real I/O (via ioHandle()) -----

fn zdtGetYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.year(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetMonth(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.month(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetDay(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.day(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetHour(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.hour(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetMinute(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.minute(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetSecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.second(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetMillisecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.millisecond(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetMicrosecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.microsecond(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetNanosecond(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.nanosecond(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetDayOfWeek(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.dayOfWeek(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetOffsetNanoseconds(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(@floatFromInt(zdt.offsetNanoseconds(allocator, ioHandle()) catch |e| return temporalErr(self, e)));
}
fn zdtGetHoursInDay(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    return JSValue.fromNumber(zdt.hoursInDay(allocator, ioHandle()) catch |e| return temporalErr(self, e));
}
/// Real spec's ISO-8601-string offset (e.g. `"-05:00"`), distinct from
/// the numeric `offsetNanoseconds` -- z-temporal has no dedicated
/// getter for this (only its internal `toString` formats one), so
/// this duplicates that formatting inline rather than adding a new
/// z-temporal function for one call site.
fn zdtGetOffset(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const offset_ns = zdt.offsetNanoseconds(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    const sign: u8 = if (offset_ns < 0) '-' else '+';
    const mag_ns = @abs(offset_ns);
    const mag_min: u32 = @intCast(@divTrunc(mag_ns, 60_000_000_000));
    var buf: [7]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{c}{d:0>2}:{d:0>2}", .{ sign, mag_min / 60, mag_min % 60 }) catch unreachable;
    return self.gcNewString(s);
}

/// The remaining calendar-derived getters (real spec has them on
/// `ZonedDateTime` too, not just `PlainDate`) -- z-temporal's
/// `ZonedDateTime` doesn't implement them itself, but `PlainDate`
/// already does, so each delegates through `toPlainDate` rather than
/// duplicating calendar math. `daysInWeek`/`yearOfWeek`/`era`/`eraYear`
/// are NOT wired here -- confirmed `PlainDate`'s own wiring doesn't
/// have them either (pre-existing, shared gap; `era`/`eraYear` are
/// `undefined` for iso8601 on real Node, `daysInWeek` is trivially 7,
/// `yearOfWeek` has its own getter -- easy to add later alongside
/// fixing PlainDate's own gap, out of scope here).
fn zdtGetMonthCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pd = zdt.toPlainDate(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    var buf: [4]u8 = undefined;
    return self.gcNewString(pd.monthCode(&buf));
}
fn zdtGetDayOfYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pd = zdt.toPlainDate(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return JSValue.fromNumber(@floatFromInt(pd.dayOfYear()));
}
fn zdtGetDaysInMonth(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pd = zdt.toPlainDate(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return JSValue.fromNumber(@floatFromInt(pd.daysInMonth()));
}
fn zdtGetDaysInYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pd = zdt.toPlainDate(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return JSValue.fromNumber(@floatFromInt(pd.daysInYear()));
}
fn zdtGetMonthsInYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pd = zdt.toPlainDate(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return JSValue.fromNumber(@floatFromInt(pd.monthsInYear()));
}
fn zdtGetInLeapYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pd = zdt.toPlainDate(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return JSValue.fromBool(pd.inLeapYear());
}
fn zdtGetWeekOfYear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pd = zdt.toPlainDate(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return JSValue.fromNumber(@floatFromInt(pd.weekOfYear() orelse return JSValue.UNDEFINED));
}

// ----- Pure getters (no I/O: derived from epochNanoseconds/the fixed timeZoneId) -----

fn zdtGetEpochMilliseconds(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try zdtSelf(interp(ctx), this_value)).toInstant().epochMilliseconds()));
}
fn zdtGetEpochNanoseconds(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewBigIntValue(try zbigint.ZBigInt.fromI128(self.gc_allocator, (try zdtSelf(self, this_value)).toInstant().epochNanoseconds()));
}
fn zdtGetTimeZoneId(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    var zdt = try zdtSelf(self, this_value);
    return self.gcNewString(zdt.timeZoneId());
}
fn zdtGetCalendarId(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return interp(ctx).gcNewString((try zdtSelf(interp(ctx), this_value)).calendarId());
}

// ----- Methods -----

fn zdtToInstant(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    return self.gcNewTemporal(.{ .instant = (try zdtSelf(self, this_value)).toInstant() });
}
fn zdtToPlainDate(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pd = zdt.toPlainDate(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = pd });
}
fn zdtToPlainTime(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pt = zdt.toPlainTime(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_time = pt });
}
fn zdtToPlainDateTime(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pdt = zdt.toPlainDateTime(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = pdt });
}
fn zdtEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const other = try coerceZonedDateTime(self, allocator, arg(args, 0), .constrain, .compatible, .reject);
    return JSValue.fromBool(ztemporal.ZonedDateTime.equals(zdt, other));
}
fn zdtStartOfDay(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const result = zdt.startOfDay(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .zoned_date_time = result });
}
fn zdtGetTimeZoneTransition(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const dir_arg = arg(args, 0);
    const direction_value = if (dir_arg == .string) dir_arg.retain() else blk: {
        try surfaceObject(self, dir_arg);
        break :blk try self.getProperty(dir_arg, "direction");
    };
    defer direction_value.deinit();
    if (direction_value == .undefined)
        return self.throwError(.range_error, "direction is required", .{});
    const direction_text = try self.toDisplayStringJS(self.gc_allocator, direction_value);
    defer self.gc_allocator.free(direction_text);
    const direction = try transitionDirectionFromString(self, direction_text);
    const result = zdt.getTimeZoneTransition(allocator, ioHandle(), direction) catch |e| return temporalErr(self, e);
    const found = result orelse return JSValue.NULL;
    return self.gcNewTemporal(.{ .zoned_date_time = found });
}
fn zdtToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const options = try surfaceStringOptions(self, arg(args, 0), .zoned_date_time);
    const s = zdt.toString(allocator, ioHandle(), options) catch |e| return temporalErr(self, e);
    defer allocator.free(s);
    return self.gcNewString(s);
}
fn zdtToJSON(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    return zdtToString(ctx, allocator, this_value, &.{});
}
fn zdtValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    return interp(ctx).throwError(.type_error, "Cannot convert a Temporal.ZonedDateTime to a primitive value", .{});
}

fn installZonedDateTime(self: *Interpreter, temporal_ns: JSValue) !void {
    const ctor = try self.gcNewFunction(.{ .ctx = self, .name = "ZonedDateTime", .arity = 2, .call = zonedDateTimeConstructor, .constructable = true });
    const statics = try self.functionStatics(ctor);
    try dneMethod(statics, "from", try native(self, "from", 1, zonedDateTimeFrom));
    try dneMethod(statics, "compare", try native(self, "compare", 2, zonedDateTimeCompare));

    const proto = try self.functionPrototype(ctor);
    try installGetter(self, proto, "year", zdtGetYear);
    try installGetter(self, proto, "month", zdtGetMonth);
    try installGetter(self, proto, "day", zdtGetDay);
    try installGetter(self, proto, "hour", zdtGetHour);
    try installGetter(self, proto, "minute", zdtGetMinute);
    try installGetter(self, proto, "second", zdtGetSecond);
    try installGetter(self, proto, "millisecond", zdtGetMillisecond);
    try installGetter(self, proto, "microsecond", zdtGetMicrosecond);
    try installGetter(self, proto, "nanosecond", zdtGetNanosecond);
    try installGetter(self, proto, "dayOfWeek", zdtGetDayOfWeek);
    try installGetter(self, proto, "offsetNanoseconds", zdtGetOffsetNanoseconds);
    try installGetter(self, proto, "hoursInDay", zdtGetHoursInDay);
    try installGetter(self, proto, "epochMilliseconds", zdtGetEpochMilliseconds);
    try installGetter(self, proto, "epochNanoseconds", zdtGetEpochNanoseconds);
    try installGetter(self, proto, "timeZoneId", zdtGetTimeZoneId);
    try installGetter(self, proto, "calendarId", zdtGetCalendarId);
    try installGetter(self, proto, "offset", zdtGetOffset);
    try installGetter(self, proto, "monthCode", zdtGetMonthCode);
    try installGetter(self, proto, "dayOfYear", zdtGetDayOfYear);
    try installGetter(self, proto, "daysInMonth", zdtGetDaysInMonth);
    try installGetter(self, proto, "daysInYear", zdtGetDaysInYear);
    try installGetter(self, proto, "monthsInYear", zdtGetMonthsInYear);
    try installGetter(self, proto, "inLeapYear", zdtGetInLeapYear);
    try installGetter(self, proto, "weekOfYear", zdtGetWeekOfYear);
    try dneMethod(proto, "toInstant", try native(self, "toInstant", 0, zdtToInstant));
    try dneMethod(proto, "toPlainDate", try native(self, "toPlainDate", 0, zdtToPlainDate));
    try dneMethod(proto, "toPlainTime", try native(self, "toPlainTime", 0, zdtToPlainTime));
    try dneMethod(proto, "toPlainDateTime", try native(self, "toPlainDateTime", 0, zdtToPlainDateTime));
    try dneMethod(proto, "equals", try native(self, "equals", 1, zdtEquals));
    try dneMethod(proto, "startOfDay", try native(self, "startOfDay", 0, zdtStartOfDay));
    try dneMethod(proto, "getTimeZoneTransition", try native(self, "getTimeZoneTransition", 1, zdtGetTimeZoneTransition));
    try dneMethod(proto, "toString", try native(self, "toString", 0, zdtToString));
    try dneMethod(proto, "toJSON", try native(self, "toJSON", 0, zdtToJSON));
    try dneMethod(proto, "valueOf", try native(self, "valueOf", 0, zdtValueOf));

    self.protos.temporal_zoned_date_time = proto;
    try dneMethod(temporal_ns, "ZonedDateTime", ctor);
}

// ===================== Temporal.now =====================

fn nowInstant(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    const self = interp(ctx);
    return self.gcNewTemporal(.{ .instant = ztemporal.Now.instant(ioHandle()) });
}

/// A `timeZoneLike` argument, real spec: when given, must be a string
/// (this repo's existing "explicit parameter, no object-with-
/// getOffsetNanosecondsFor style custom time zones" narrowing); when
/// omitted, falls back to the system's configured zone. Always returns
/// an allocator-owned copy (even for the given-string case) so every
/// caller has one uniform ownership rule to `defer allocator.free`,
/// rather than branching on which path produced it. `environ` is
/// always `null` here -- this interpreter has no `std.process.Environ`
/// threaded down to native-function context, so the `TZ` env var isn't
/// consulted; only `/etc/localtime` resolution (z-temporal's fallback)
/// applies.
fn resolveTimeZoneArg(self: *Interpreter, allocator: Allocator, tz_arg: JSValue) anyerror![]u8 {
    if (tz_arg != .undefined) {
        if (tz_arg != .string) return self.throwError(.type_error, "timeZone must be a string", .{});
        return try allocator.dupe(u8, tz_arg.string.value.data);
    }
    return ztemporal.Now.timeZoneId(allocator, ioHandle(), null) catch |e| return temporalErr(self, e);
}

fn nowZonedDateTimeISO(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const tz = try resolveTimeZoneArg(self, allocator, arg(args, 0));
    defer allocator.free(tz);
    const zdt = ztemporal.Now.zonedDateTimeISO(allocator, ioHandle(), tz) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .zoned_date_time = zdt });
}
fn nowPlainDateISO(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const tz = try resolveTimeZoneArg(self, allocator, arg(args, 0));
    defer allocator.free(tz);
    const pd = ztemporal.Now.plainDateISO(allocator, ioHandle(), tz) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = pd });
}
fn nowPlainTimeISO(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const tz = try resolveTimeZoneArg(self, allocator, arg(args, 0));
    defer allocator.free(tz);
    const pt = ztemporal.Now.plainTimeISO(allocator, ioHandle(), tz) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_time = pt });
}
fn nowPlainDateTimeISO(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const tz = try resolveTimeZoneArg(self, allocator, arg(args, 0));
    defer allocator.free(tz);
    const pdt = ztemporal.Now.plainDateTimeISO(allocator, ioHandle(), tz) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = pdt });
}
fn nowTimeZoneId(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    _ = args;
    const self = interp(ctx);
    const s = ztemporal.Now.timeZoneId(allocator, ioHandle(), null) catch |e| return temporalErr(self, e);
    defer allocator.free(s);
    return self.gcNewString(s);
}

/// Installs the `Temporal` global: one ordinary object holding each
/// wired type's constructor, plus `Temporal.Now`. Call from
/// `builtins.setupGlobals` alongside Date/Math/JSON.
pub fn install(self: *Interpreter) !void {
    const temporal_ns = try self.ordinaryObject();
    try installPlainDate(self, temporal_ns);
    try installPlainTime(self, temporal_ns);
    try installPlainDateTime(self, temporal_ns);
    try installPlainYearMonth(self, temporal_ns);
    try installPlainMonthDay(self, temporal_ns);
    try installInstant(self, temporal_ns);
    try installDuration(self, temporal_ns);
    try installZonedDateTime(self, temporal_ns);

    // `Temporal.Now` -- real spec name is capital-N `Now` (this engine
    // previously defined lowercase `now`, silently never matching any
    // real code or test that reads `Temporal.Now`).
    const now_obj = try self.ordinaryObject();
    try dneMethod(now_obj, "instant", try native(self, "instant", 0, nowInstant));
    try dneMethod(now_obj, "zonedDateTimeISO", try native(self, "zonedDateTimeISO", 0, nowZonedDateTimeISO));
    try dneMethod(now_obj, "plainDateISO", try native(self, "plainDateISO", 0, nowPlainDateISO));
    try dneMethod(now_obj, "plainTimeISO", try native(self, "plainTimeISO", 0, nowPlainTimeISO));
    try dneMethod(now_obj, "plainDateTimeISO", try native(self, "plainDateTimeISO", 0, nowPlainDateTimeISO));
    try dneMethod(now_obj, "timeZoneId", try native(self, "timeZoneId", 0, nowTimeZoneId));
    try dneMethod(temporal_ns, "Now", now_obj);

    try installSurface(self, temporal_ns);
    try self.global_env.define(self.gc_allocator, "Temporal", temporal_ns);
}

// JavaScript surface shared by the typed Temporal adapters.
pub fn isIntrinsicConstructor(value: JSValue) bool {
    if (value != .function) return false;
    inline for (.{ plainDateConstructor, plainTimeConstructor, plainDateTimeConstructor, plainYearMonthConstructor, plainMonthDayConstructor, instantConstructor, durationConstructor, zonedDateTimeConstructor }) |callback| {
        if (value.function.value.call == callback) return true;
    }
    return false;
}

pub fn installTags(self: *Interpreter, key: []const u8) !void {
    const attrs = zvalue.PropertyDescriptor{ .writable = false, .enumerable = false, .configurable = true };
    try self.protos.temporal_plain_date.object.value.defineProperty(key, try self.gcNewString("Temporal.PlainDate"), attrs);
    try self.protos.temporal_plain_time.object.value.defineProperty(key, try self.gcNewString("Temporal.PlainTime"), attrs);
    try self.protos.temporal_plain_date_time.object.value.defineProperty(key, try self.gcNewString("Temporal.PlainDateTime"), attrs);
    try self.protos.temporal_plain_year_month.object.value.defineProperty(key, try self.gcNewString("Temporal.PlainYearMonth"), attrs);
    try self.protos.temporal_plain_month_day.object.value.defineProperty(key, try self.gcNewString("Temporal.PlainMonthDay"), attrs);
    try self.protos.temporal_instant.object.value.defineProperty(key, try self.gcNewString("Temporal.Instant"), attrs);
    try self.protos.temporal_duration.object.value.defineProperty(key, try self.gcNewString("Temporal.Duration"), attrs);
    try self.protos.temporal_zoned_date_time.object.value.defineProperty(key, try self.gcNewString("Temporal.ZonedDateTime"), attrs);
    if (self.global_env.get("Temporal")) |ns| {
        try ns.object.value.defineProperty(key, try self.gcNewString("Temporal"), attrs);
        if (ns.object.value.get("Now")) |now| try now.object.value.defineProperty(key, try self.gcNewString("Temporal.Now"), attrs);
    }
}

fn surfaceObject(self: *Interpreter, value: JSValue) anyerror!void {
    if (Interpreter.isPrimitiveTag(value)) return self.throwError(.type_error, "Temporal requires an object", .{});
}

fn surfaceOptions(self: *Interpreter, value: JSValue) anyerror!void {
    if (value != .undefined) try surfaceObject(self, value);
}

fn surfaceEnum(self: *Interpreter, options: JSValue, key: []const u8, comptime T: type, default: T) anyerror!T {
    try surfaceOptions(self, options);
    if (options == .undefined) return default;
    const value = try self.getProperty(options, key);
    defer value.deinit();
    if (value == .undefined) return default;
    const text = try self.toDisplayStringJS(self.gc_allocator, value);
    defer self.gc_allocator.free(text);
    inline for (@typeInfo(T).@"enum".field_names) |name| {
        if (std.mem.eql(u8, text, name)) return @field(T, name);
    }
    return self.throwError(.range_error, "Invalid {s}: {s}", .{ key, text });
}

const StringOptionsKind = enum { plain_time, plain_date_time, duration, instant, zoned_date_time };

fn surfaceStringOptions(self: *Interpreter, options: JSValue, comptime kind: StringOptionsKind) anyerror!ztemporal.StringOptions {
    try surfaceOptions(self, options);
    if (options == .undefined) return .{};
    var out: ztemporal.StringOptions = .{};
    if (comptime kind == .plain_date_time or kind == .zoned_date_time) {
        out.calendarName = try surfaceEnum(self, options, "calendarName", ztemporal.CalendarName, .auto);
    }
    const digits = try self.getProperty(options, "fractionalSecondDigits");
    defer digits.deinit();
    if (digits != .undefined) {
        if (digits == .number) {
            const n = @floor(digits.number);
            if (!std.math.isFinite(n) or n < 0 or n > 9) return self.throwError(.range_error, "Invalid fractionalSecondDigits", .{});
            out.fractionalSecondDigits = @intFromFloat(n);
        } else {
            const digits_text = try self.toDisplayStringJS(self.gc_allocator, digits);
            defer self.gc_allocator.free(digits_text);
            if (!std.mem.eql(u8, digits_text, "auto")) return self.throwError(.range_error, "Invalid fractionalSecondDigits", .{});
        }
    }
    if (comptime kind == .zoned_date_time) {
        out.offset = try surfaceEnum(self, options, "offset", @TypeOf(out.offset), .auto);
    }
    out.roundingMode = try surfaceEnum(self, options, "roundingMode", RoundingMode, .trunc);
    const smallest = try self.getProperty(options, "smallestUnit");
    defer smallest.deinit();
    if (smallest != .undefined) {
        const name = try self.toDisplayStringJS(self.gc_allocator, smallest);
        defer self.gc_allocator.free(name);
        out.smallestUnit = try unitFromString(self, name, "smallestUnit");
    }
    if (comptime kind == .zoned_date_time) {
        out.timeZoneName = try surfaceEnum(self, options, "timeZoneName", ztemporal.TimeZoneName, .auto);
    }
    if (comptime kind == .instant) {
        const zone = try self.getProperty(options, "timeZone");
        defer zone.deinit();
        if (zone != .undefined) {
            out.timeZone = try surfaceZoneArgument(self, zone);
            out.io = ioHandle();
        }
    }
    return out;
}

fn surfaceI32(self: *Interpreter, object: JSValue, key: []const u8) anyerror!?i32 {
    const value = try self.getProperty(object, key);
    defer value.deinit();
    if (value == .undefined) return null;
    const n = try self.toNumberJS(value);
    if (!std.math.isFinite(n) or @trunc(n) < std.math.minInt(i32) or @trunc(n) > std.math.maxInt(i32)) return self.throwError(.range_error, "Invalid Temporal field {s}", .{key});
    return @intFromFloat(@trunc(n));
}

fn surfaceString(self: *Interpreter, object: JSValue, key: []const u8) anyerror!?[]const u8 {
    const value = try self.getProperty(object, key);
    defer value.deinit();
    if (value == .undefined) return null;
    if (std.mem.eql(u8, key, "calendar")) {
        const identifier = try calendarFromValue(self, value) orelse return null;
        return try self.gc_allocator.dupe(u8, identifier);
    }
    if (std.mem.eql(u8, key, "offset") and value != .string) return self.throwError(.type_error, "Temporal offset must be a string", .{});
    if (std.mem.eql(u8, key, "timeZone")) return try surfaceZoneArgument(self, value);
    return try self.toDisplayStringJS(self.gc_allocator, value);
}

fn surfaceValue(self: *Interpreter, value: anytype) anyerror!JSValue {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |v| surfaceValue(self, v) else JSValue.UNDEFINED,
        .int, .comptime_int => JSValue.fromNumber(@floatFromInt(value)),
        .float => JSValue.fromNumber(value),
        .pointer => self.gcNewString(value),
        else => @compileError("Unsupported Temporal getter result"),
    };
}

fn surfaceGetter(comptime tag: std.meta.Tag(TemporalValue), comptime method: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = args;
            const self = interp(ctx);
            const value = try requireTemporal(self, receiver, tag, "Temporal getter");
            const result = if (comptime tag == .zoned_date_time and !std.mem.eql(u8, method, "daysInWeek"))
                @field(@TypeOf(value), method)(value, allocator, ioHandle()) catch |e| return temporalErr(self, e)
            else
                @field(@TypeOf(value), method)(value);
            return surfaceValue(self, result);
        }
    }.call;
}

fn surfaceSerialize(comptime tag: std.meta.Tag(TemporalValue)) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = args;
            const self = interp(ctx);
            const value = try requireTemporal(self, receiver, tag, "Temporal serialization");
            const text = if (tag == .zoned_date_time)
                value.toString(allocator, ioHandle(), .{}) catch |e| return temporalErr(self, e)
            else
                value.toString(allocator, .{}) catch |e| return temporalErr(self, e);
            defer allocator.free(text);
            return self.gcNewString(text);
        }
    }.call;
}

fn surfaceValueOf(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = receiver;
    _ = args;
    return interp(ctx).throwError(.type_error, "Temporal values cannot be converted to primitives", .{});
}

fn installSurface(self: *Interpreter, ns: JSValue) !void {
    {
        const proto = self.protos.temporal_plain_date;
        proto.object.value.getOwnRecordMut("constructor").?.descriptor.enumerable = false;
        try dneMethod(proto, "toJSON", try native(self, "toJSON", 0, surfaceSerialize(.plain_date)));
        try dneMethod(proto, "valueOf", try native(self, "valueOf", 0, surfaceValueOf));
        try dneMethod(proto, "toLocaleString", try native(self, "toLocaleString", 0, surfaceSerialize(.plain_date)));
        try installGetter(self, proto, "daysInWeek", surfaceGetter(.plain_date, "daysInWeek"));
        try installGetter(self, proto, "era", surfaceGetter(.plain_date, "era"));
        try installGetter(self, proto, "eraYear", surfaceGetter(.plain_date, "eraYear"));
        try installGetter(self, proto, "yearOfWeek", surfaceGetter(.plain_date, "yearOfWeek"));
        try dneMethod(proto, "toPlainDateTime", try native(self, "toPlainDateTime", 0, surfacePdToDateTime));
        try dneMethod(proto, "toPlainYearMonth", try native(self, "toPlainYearMonth", 0, surfacePdToYearMonth));
        try dneMethod(proto, "toPlainMonthDay", try native(self, "toPlainMonthDay", 0, surfacePdToMonthDay));
        try dneMethod(proto, "toZonedDateTime", try native(self, "toZonedDateTime", 1, surfacePdToZoned));
        try dneMethod(proto, "withCalendar", try native(self, "withCalendar", 1, surfaceWithCalendar(.plain_date)));
    }
    {
        const proto = self.protos.temporal_plain_time;
        proto.object.value.getOwnRecordMut("constructor").?.descriptor.enumerable = false;
        try dneMethod(proto, "toJSON", try native(self, "toJSON", 0, surfaceSerialize(.plain_time)));
        try dneMethod(proto, "valueOf", try native(self, "valueOf", 0, surfaceValueOf));
        try dneMethod(proto, "toLocaleString", try native(self, "toLocaleString", 0, surfaceSerialize(.plain_time)));
    }
    {
        const proto = self.protos.temporal_plain_date_time;
        proto.object.value.getOwnRecordMut("constructor").?.descriptor.enumerable = false;
        try dneMethod(proto, "toJSON", try native(self, "toJSON", 0, surfaceSerialize(.plain_date_time)));
        try dneMethod(proto, "valueOf", try native(self, "valueOf", 0, surfaceValueOf));
        try dneMethod(proto, "toLocaleString", try native(self, "toLocaleString", 0, surfaceSerialize(.plain_date_time)));
        try installGetter(self, proto, "dayOfYear", surfaceGetter(.plain_date_time, "dayOfYear"));
        try installGetter(self, proto, "daysInWeek", surfaceGetter(.plain_date_time, "daysInWeek"));
        try installGetter(self, proto, "daysInYear", surfaceGetter(.plain_date_time, "daysInYear"));
        try installGetter(self, proto, "era", surfaceGetter(.plain_date_time, "era"));
        try installGetter(self, proto, "eraYear", surfaceGetter(.plain_date_time, "eraYear"));
        try installGetter(self, proto, "monthsInYear", surfaceGetter(.plain_date_time, "monthsInYear"));
        try installGetter(self, proto, "weekOfYear", surfaceGetter(.plain_date_time, "weekOfYear"));
        try installGetter(self, proto, "yearOfWeek", surfaceGetter(.plain_date_time, "yearOfWeek"));
        try dneMethod(proto, "withPlainTime", try native(self, "withPlainTime", 0, surfaceWithPlainTime(.plain_date_time)));
        try dneMethod(proto, "withCalendar", try native(self, "withCalendar", 1, surfaceWithCalendar(.plain_date_time)));
        try dneMethod(proto, "toZonedDateTime", try native(self, "toZonedDateTime", 1, surfacePdtToZoned));
    }
    {
        const proto = self.protos.temporal_plain_year_month;
        proto.object.value.getOwnRecordMut("constructor").?.descriptor.enumerable = false;
        try dneMethod(proto, "toJSON", try native(self, "toJSON", 0, surfaceSerialize(.plain_year_month)));
        try dneMethod(proto, "valueOf", try native(self, "valueOf", 0, surfaceValueOf));
        try dneMethod(proto, "toLocaleString", try native(self, "toLocaleString", 0, surfaceSerialize(.plain_year_month)));
        try installGetter(self, proto, "era", surfaceGetter(.plain_year_month, "era"));
        try installGetter(self, proto, "eraYear", surfaceGetter(.plain_year_month, "eraYear"));
    }
    {
        const proto = self.protos.temporal_plain_month_day;
        proto.object.value.getOwnRecordMut("constructor").?.descriptor.enumerable = false;
        try dneMethod(proto, "toJSON", try native(self, "toJSON", 0, surfaceSerialize(.plain_month_day)));
        try dneMethod(proto, "valueOf", try native(self, "valueOf", 0, surfaceValueOf));
        try dneMethod(proto, "toLocaleString", try native(self, "toLocaleString", 0, surfaceSerialize(.plain_month_day)));
    }
    {
        const proto = self.protos.temporal_instant;
        proto.object.value.getOwnRecordMut("constructor").?.descriptor.enumerable = false;
        try dneMethod(proto, "toJSON", try native(self, "toJSON", 0, surfaceSerialize(.instant)));
        try dneMethod(proto, "valueOf", try native(self, "valueOf", 0, surfaceValueOf));
        try dneMethod(proto, "toLocaleString", try native(self, "toLocaleString", 0, surfaceSerialize(.instant)));
    }
    {
        const proto = self.protos.temporal_duration;
        proto.object.value.getOwnRecordMut("constructor").?.descriptor.enumerable = false;
        try dneMethod(proto, "toJSON", try native(self, "toJSON", 0, surfaceSerialize(.duration)));
        try dneMethod(proto, "valueOf", try native(self, "valueOf", 0, surfaceValueOf));
        try dneMethod(proto, "toLocaleString", try native(self, "toLocaleString", 0, surfaceSerialize(.duration)));
    }
    {
        const proto = self.protos.temporal_zoned_date_time;
        proto.object.value.getOwnRecordMut("constructor").?.descriptor.enumerable = false;
        try dneMethod(proto, "toLocaleString", try native(self, "toLocaleString", 0, surfaceSerialize(.zoned_date_time)));
        try installGetter(self, proto, "daysInWeek", surfaceGetter(.zoned_date_time, "daysInWeek"));
        try installGetter(self, proto, "era", surfaceGetter(.zoned_date_time, "era"));
        try installGetter(self, proto, "eraYear", surfaceGetter(.zoned_date_time, "eraYear"));
        try installGetter(self, proto, "yearOfWeek", surfaceGetter(.zoned_date_time, "yearOfWeek"));
        try dneMethod(proto, "with", try native(self, "with", 1, surfaceZdtWith));
        try dneMethod(proto, "add", try native(self, "add", 1, surfaceZdtArithmetic(false)));
        try dneMethod(proto, "subtract", try native(self, "subtract", 1, surfaceZdtArithmetic(true)));
        try dneMethod(proto, "until", try native(self, "until", 1, surfaceZdtDifference(false)));
        try dneMethod(proto, "since", try native(self, "since", 1, surfaceZdtDifference(true)));
        try dneMethod(proto, "round", try native(self, "round", 1, surfaceZdtRound));
        try dneMethod(proto, "withPlainTime", try native(self, "withPlainTime", 0, surfaceWithPlainTime(.zoned_date_time)));
        try dneMethod(proto, "withTimeZone", try native(self, "withTimeZone", 1, surfaceZdtWithZone));
        try dneMethod(proto, "withCalendar", try native(self, "withCalendar", 1, surfaceWithCalendar(.zoned_date_time)));
    }
    _ = ns;
}

fn surfaceFields(self: *Interpreter, value: JSValue, comptime T: type) anyerror!T {
    return surfaceFieldsMode(self, value, T, false);
}

fn surfaceFieldsMode(self: *Interpreter, value: JSValue, comptime T: type, comptime partial: bool) anyerror!T {
    try surfaceObject(self, value);
    var fields: T = .{};
    errdefer freeSurfaceFields(self, fields);
    inline for (.{ "calendar", "day", "hour", "microsecond", "millisecond", "minute", "month", "monthCode", "nanosecond", "offset", "second", "timeZone", "year" }) |key| {
        if (comptime @hasField(T, key) and !(partial and (std.mem.eql(u8, key, "calendar") or std.mem.eql(u8, key, "timeZone")))) {
            if (comptime @FieldType(T, key) == ?i32) @field(fields, key) = try surfaceI32(self, value, key) else @field(fields, key) = try surfaceString(self, value, key);
        }
    }
    return fields;
}

fn surfaceTime(self: *Interpreter, value: JSValue) anyerror!ztemporal.PlainTime {
    if (value == .temporal) switch (value.temporal.value) {
        .plain_time => |v| return v,
        .plain_date_time => |v| return v.time,
        .zoned_date_time => |v| return v.toPlainTime(self.gc_allocator, ioHandle()) catch |e| temporalErr(self, e),
        else => {},
    };
    if (value == .string) return ztemporal.PlainTime.from(.{ .string = value.string.value.data }, .{}) catch |e| temporalErr(self, e);
    return ztemporal.PlainTime.from(.{ .fields = try surfaceFields(self, value, ztemporal.PlainTime.Fields) }, .{}) catch |e| temporalErr(self, e);
}

fn surfaceDuration(self: *Interpreter, value: JSValue) anyerror!ztemporal.Duration {
    if (value == .string or (value == .temporal and value.temporal.value == .duration)) return coerceDuration(self, value);
    try surfaceObject(self, value);
    var fields: ztemporal.Duration.Fields = .{};
    inline for (.{ "days", "hours", "microseconds", "milliseconds", "minutes", "months", "nanoseconds", "seconds", "weeks", "years" }) |key| {
        const v = try self.getProperty(value, key);
        defer v.deinit();
        if (v != .undefined) {
            const n = try self.toNumberJS(v);
            if (!std.math.isFinite(n) or @trunc(n) != n) return self.throwError(.range_error, "Invalid duration field {s}", .{key});
            @field(fields, key) = n;
        }
    }
    return ztemporal.Duration.from(.{ .fields = fields }) catch |e| temporalErr(self, e);
}

fn surfaceZone(self: *Interpreter, value: JSValue) anyerror![]const u8 {
    if (value == .temporal and value.temporal.value == .zoned_date_time) return value.temporal.value.zoned_date_time.timeZoneId();
    if (value != .string) return self.throwError(.type_error, "Time zone must be a string or ZonedDateTime", .{});
    return surfaceZoneText(self, value.string.value.data);
}

fn surfaceZoneText(self: *Interpreter, text: []const u8) anyerror![]const u8 {
    const is_iso = text.len >= 8 and ((std.ascii.isDigit(text[0]) and std.ascii.isDigit(text[1]) and std.ascii.isDigit(text[2]) and std.ascii.isDigit(text[3])) or ((text[0] == '+' or text[0] == '-') and text.len >= 13));
    if (!is_iso) return text;
    // Validate the ISO grammar before extracting its time zone identifier.
    if (ztemporal.PlainDateTime.from(.{ .string = text }, .{})) |_| {} else |_| {
        _ = ztemporal.Instant.from(.{ .string = text }) catch |e| return temporalErr(self, e);
    }
    // ToTemporalTimeZoneIdentifier accepts a zone annotation or an ISO offset.
    if (std.mem.indexOfScalar(u8, text, '[')) |open| {
        if (std.mem.indexOfScalarPos(u8, text, open, ']')) |close| {
            const inner = text[open + 1 .. close];
            if (std.mem.indexOfScalar(u8, inner, '=') == null) return if (std.mem.startsWith(u8, inner, "!")) inner[1..] else inner;
        }
    }
    if (std.mem.indexOfAny(u8, text, "Tt ")) |time| {
        if (std.mem.endsWith(u8, text, "Z") or std.mem.endsWith(u8, text, "z")) return "UTC";
        if (std.mem.indexOfAnyPos(u8, text, time + 1, "+-")) |offset| return text[offset..];
        return self.throwError(.range_error, "ISO time zone string requires an offset", .{});
    }
    return text;
}

fn surfaceZoneArgument(self: *Interpreter, value: JSValue) anyerror![]const u8 {
    // The returned identifier may be a slice of an owned getter result.
    const zone = try surfaceZone(self, value);
    return self.gc_allocator.dupe(u8, zone);
}

fn surfaceWithCalendar(comptime tag: std.meta.Tag(TemporalValue)) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const self = interp(ctx);
            const value = try requireTemporal(self, receiver, tag, "Temporal.withCalendar");
            const calendar = arg(args, 0);
            const identifier = try calendarFromValue(self, calendar) orelse
                return self.throwError(.type_error, "Calendar must be a string or Temporal calendar carrier", .{});
            const result = value.withCalendar(identifier) catch |e| return temporalErr(self, e);
            return self.gcNewTemporal(@unionInit(TemporalValue, @tagName(tag), result));
        }
    }.call;
}

fn surfaceWithPlainTime(comptime tag: std.meta.Tag(TemporalValue)) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
            const self = interp(ctx);
            const value = try requireTemporal(self, receiver, tag, "Temporal.withPlainTime");
            const time: ?ztemporal.PlainTime = if (arg(args, 0) == .undefined) null else try surfaceTime(self, arg(args, 0));
            const result = if (tag == .zoned_date_time)
                value.withPlainTime(allocator, ioHandle(), time) catch |e| return temporalErr(self, e)
            else
                value.withPlainTime(time) catch |e| return temporalErr(self, e);
            return self.gcNewTemporal(@unionInit(TemporalValue, @tagName(tag), result));
        }
    }.call;
}

fn surfacePdToDateTime(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const date = try pdSelf(self, receiver);
    const time: ?ztemporal.PlainTime = if (arg(args, 0) == .undefined) null else try surfaceTime(self, arg(args, 0));
    return self.gcNewTemporal(.{ .plain_date_time = date.toPlainDateTime(time) catch |e| return temporalErr(self, e) });
}

fn surfacePdToYearMonth(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const date = try pdSelf(self, receiver);
    return self.gcNewTemporal(.{ .plain_year_month = date.toPlainYearMonth() catch |e| return temporalErr(self, e) });
}

fn surfacePdToMonthDay(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const date = try pdSelf(self, receiver);
    return self.gcNewTemporal(.{ .plain_month_day = date.toPlainMonthDay() catch |e| return temporalErr(self, e) });
}

fn surfacePdToZoned(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const date = try pdSelf(self, receiver);
    const item = arg(args, 0);
    var zone_value = item.retain();
    defer zone_value.deinit();
    var time_value = JSValue.UNDEFINED;
    defer time_value.deinit();
    if (!Interpreter.isPrimitiveTag(item)) {
        const v = try self.getProperty(item, "timeZone");
        if (v != .undefined) {
            zone_value.deinit();
            zone_value = v;
            time_value = try self.getProperty(item, "plainTime");
        } else v.deinit();
    }
    const zone = try surfaceZoneArgument(self, zone_value);
    defer self.gc_allocator.free(zone);
    const time: ?ztemporal.PlainTime = if (time_value == .undefined) null else try surfaceTime(self, time_value);
    return self.gcNewTemporal(.{ .zoned_date_time = date.toZonedDateTime(allocator, ioHandle(), zone, time) catch |e| return temporalErr(self, e) });
}

fn surfacePdtToZoned(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const dt = try pdtSelf(self, receiver);
    const zone = try surfaceZoneArgument(self, arg(args, 0));
    defer self.gc_allocator.free(zone);
    const disambiguation = try surfaceEnum(self, arg(args, 1), "disambiguation", ztemporal.Disambiguation, .compatible);
    return self.gcNewTemporal(.{ .zoned_date_time = dt.toZonedDateTime(allocator, ioHandle(), zone, disambiguation) catch |e| return temporalErr(self, e) });
}

fn surfaceZdtWithZone(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const dt = try zdtSelf(self, receiver);
    const zone = try surfaceZoneArgument(self, arg(args, 0));
    defer self.gc_allocator.free(zone);
    return self.gcNewTemporal(.{ .zoned_date_time = dt.withTimeZone(allocator, ioHandle(), zone) catch |e| return temporalErr(self, e) });
}

fn surfaceZdtWith(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const dt = try zdtSelf(self, receiver);
    const item = arg(args, 0);
    try surfaceObject(self, item);
    if (item == .temporal) return self.throwError(.type_error, "with requires a partial property bag", .{});
    const calendar = try self.getProperty(item, "calendar");
    defer calendar.deinit();
    if (calendar != .undefined) return self.throwError(.type_error, "with forbids calendar", .{});
    const zone = try self.getProperty(item, "timeZone");
    defer zone.deinit();
    if (zone != .undefined) return self.throwError(.type_error, "with forbids timeZone", .{});
    const fields = try surfaceFieldsMode(self, item, ztemporal.ZonedDateTime.Fields, true);
    defer freeSurfaceFields(self, fields);
    const options = arg(args, 1);
    const disambiguation = try surfaceEnum(self, options, "disambiguation", ztemporal.Disambiguation, .compatible);
    const offset = try surfaceEnum(self, options, "offset", ztemporal.OffsetOption, .prefer);
    const overflow = try surfaceEnum(self, options, "overflow", Overflow, .constrain);
    return self.gcNewTemporal(.{ .zoned_date_time = dt.with(allocator, ioHandle(), fields, .{ .overflow = overflow, .offset = offset, .disambiguation = disambiguation }) catch |e| return temporalErr(self, e) });
}

fn surfaceZdtArithmetic(comptime subtract: bool) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
            const self = interp(ctx);
            const dt = try zdtSelf(self, receiver);
            const duration = try surfaceDuration(self, arg(args, 0));
            const overflow = try surfaceEnum(self, arg(args, 1), "overflow", Overflow, .constrain);
            const result = if (subtract) dt.subtract(allocator, ioHandle(), duration, overflow) catch |e| return temporalErr(self, e) else dt.add(allocator, ioHandle(), duration, overflow) catch |e| return temporalErr(self, e);
            return self.gcNewTemporal(.{ .zoned_date_time = result });
        }
    }.call;
}

fn surfaceZoned(self: *Interpreter, allocator: Allocator, item: JSValue) anyerror!ztemporal.ZonedDateTime {
    if (item == .temporal and item.temporal.value == .zoned_date_time) return item.temporal.value.zoned_date_time;
    if (item == .string) return ztemporal.ZonedDateTime.from(allocator, ioHandle(), .{ .string = item.string.value.data }, .{}) catch |e| temporalErr(self, e);
    var fields = try surfaceFields(self, item, ztemporal.ZonedDateTime.Fields);
    defer freeSurfaceFields(self, fields);
    if (fields.calendar) |text| {
        const identifier = try surfaceCalendar(self, text);
        _ = ztemporal.PlainDate.init(1970, 1, 1, identifier) catch |e| return temporalErr(self, e);
        const owned = try self.gc_allocator.dupe(u8, identifier);
        self.gc_allocator.free(text);
        fields.calendar = owned;
    }
    if (fields.timeZone) |text| {
        const zone = try surfaceZoneText(self, text);
        const owned = try self.gc_allocator.dupe(u8, zone);
        self.gc_allocator.free(text);
        fields.timeZone = owned;
    }
    return ztemporal.ZonedDateTime.from(allocator, ioHandle(), .{ .fields = fields }, .{}) catch |e| temporalErr(self, e);
}

/// ZonedDateTime.since/until use a local reader so their ToNumber boundary
/// stays explicit: ToNumber(BigInt) throws TypeError rather than converting
/// it through the host numeric helper.
fn readZonedDateTimeDifferenceOptions(self: *Interpreter, options: JSValue) anyerror!RoundingOptions {
    var result: RoundingOptions = .{ .roundingMode = .trunc };
    try surfaceOptions(self, options);
    if (options == .undefined) return result;

    const largest = try surfaceString(self, options, "largestUnit");
    defer if (largest) |text| self.gc_allocator.free(text);
    if (largest) |text| {
        if (!std.mem.eql(u8, text, "auto"))
            result.largestUnit = try unitFromString(self, text, "largestUnit");
    }

    const increment = try self.getProperty(options, "roundingIncrement");
    defer increment.deinit();
    if (increment != .undefined) {
        if (increment == .bigint)
            return self.throwError(.type_error, "roundingIncrement must be a number", .{});
        const number = try self.toNumberJS(increment);
        if (!std.math.isFinite(number) or @trunc(number) < 1 or @trunc(number) > 1_000_000_000)
            return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        result.roundingIncrement = @intFromFloat(@trunc(number));
    }
    result.roundingMode = try surfaceEnum(self, options, "roundingMode", RoundingMode, .trunc);
    const smallest = try surfaceString(self, options, "smallestUnit");
    defer if (smallest) |text| self.gc_allocator.free(text);
    if (smallest) |text| result.smallestUnit = try unitFromString(self, text, "smallestUnit");
    return result;
}

fn surfaceRounding(self: *Interpreter, options: JSValue, comptime T: type, default_mode: RoundingMode, shorthand: bool) anyerror!T {
    var result: T = .{ .roundingMode = default_mode };
    if (shorthand and options == .string) {
        result.smallestUnit = try unitFromString(self, options.string.value.data, "smallestUnit");
        return result;
    }
    try surfaceOptions(self, options);
    if (options == .undefined) return result;
    if (comptime T == RoundingOptions) {
        const largest = try surfaceString(self, options, "largestUnit");
        defer if (largest) |text| self.gc_allocator.free(text);
        if (largest) |text| if (!std.mem.eql(u8, text, "auto")) {
            result.largestUnit = try unitFromString(self, text, "largestUnit");
        };
    }
    const increment = try self.getProperty(options, "roundingIncrement");
    defer increment.deinit();
    if (increment != .undefined) {
        const n = try self.toNumberJS(increment);
        if (!std.math.isFinite(n) or @trunc(n) < 1 or @trunc(n) > 1_000_000_000) return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        result.roundingIncrement = @intFromFloat(@trunc(n));
    }
    result.roundingMode = try surfaceEnum(self, options, "roundingMode", RoundingMode, default_mode);
    if (try surfaceString(self, options, "smallestUnit")) |text| {
        defer self.gc_allocator.free(text);
        result.smallestUnit = try unitFromString(self, text, "smallestUnit");
    }
    return result;
}

fn surfaceZdtDifference(comptime since: bool) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
            const self = interp(ctx);
            const dt = try zdtSelf(self, receiver);
            const other = try surfaceZoned(self, allocator, arg(args, 0));
            var options = try readZonedDateTimeDifferenceOptions(self, arg(args, 1));
            // Resolve the JS ZonedDateTime default before the native time-unit
            // path delegates to Instant, whose own default is seconds.
            if (options.largestUnit == null) {
                options.largestUnit = if (options.smallestUnit) |unit|
                    (if (@backingInt(unit) < @backingInt(Unit.hour)) unit else .hour)
                else
                    .hour;
            }
            const result = if (since) dt.since(allocator, ioHandle(), other, options) catch |e| return temporalErr(self, e) else dt.until(allocator, ioHandle(), other, options) catch |e| return temporalErr(self, e);
            return self.gcNewTemporal(.{ .duration = result });
        }
    }.call;
}

/// ZonedDateTime.round has no zone-specific options, but its required
/// smallestUnit and observable read order differ from surfaceRounding's
/// difference-method callers.
fn readZonedDateTimeRoundOptions(self: *Interpreter, options: JSValue) anyerror!RoundOptions {
    if (options == .undefined)
        return self.throwError(.type_error, "round requires options", .{});
    if (options == .string) {
        return .{ .smallestUnit = try unitFromString(self, options.string.value.data, "smallestUnit") };
    }
    try surfaceOptions(self, options);

    const rounding_increment = try readRoundingOptionNumber(self, options, "roundingIncrement");
    const rounding_mode = try readRoundingOptionString(self, options, "roundingMode");
    defer if (rounding_mode) |value| self.gc_allocator.free(value);
    const smallest_unit = try readRoundingOptionString(self, options, "smallestUnit");
    defer if (smallest_unit) |value| self.gc_allocator.free(value);

    var out: RoundOptions = .{};
    if (rounding_increment) |number| {
        if (!std.math.isFinite(number)) return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        const integer = @trunc(number);
        if (integer < 1 or integer > 1_000_000_000)
            return self.throwError(.range_error, "Invalid roundingIncrement", .{});
        out.roundingIncrement = @intFromFloat(integer);
    }
    if (rounding_mode) |text| out.roundingMode = try roundingModeFromString(self, text);
    out.smallestUnit = if (smallest_unit) |text|
        try unitFromString(self, text, "smallestUnit")
    else
        return self.throwError(.range_error, "round() requires smallestUnit", .{});
    return out;
}

fn surfaceZdtRound(ctx: *anyopaque, allocator: Allocator, receiver: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const dt = try zdtSelf(self, receiver);
    const options = try readZonedDateTimeRoundOptions(self, arg(args, 0));
    return self.gcNewTemporal(.{ .zoned_date_time = dt.round(allocator, ioHandle(), options) catch |e| return temporalErr(self, e) });
}

fn freeSurfaceFields(self: *Interpreter, fields: anytype) void {
    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |key| {
        if (comptime @FieldType(@TypeOf(fields), key) == ?[]const u8) {
            if (@field(fields, key)) |text| self.gc_allocator.free(text);
        }
    }
}

fn surfaceCalendar(self: *Interpreter, text: []const u8) anyerror![]const u8 {
    if (std.ascii.eqlIgnoreCase(text, "iso8601")) return "iso8601";
    if (text.len < 2 or (!std.ascii.isDigit(text[0]) and text[0] != '+' and text[0] != '-' and text[0] != 'T' and text[0] != 't')) return text;
    if (ztemporal.PlainDate.from(.{ .string = text }, .{})) |_| {} else |_| {
        if (ztemporal.PlainTime.from(.{ .string = text }, .{})) |_| {} else |_| {
            if (ztemporal.PlainYearMonth.from(.{ .string = text }, .{})) |_| {} else |_| {
                if (ztemporal.PlainMonthDay.from(.{ .string = text }, .{})) |_| {} else |_| {
                    _ = ztemporal.Instant.from(.{ .string = text }) catch |e| return temporalErr(self, e);
                }
            }
        }
    }
    // Calendar-like ISO strings select their first calendar annotation;
    // the typed calendar operation validates the extracted identifier.
    const normal = std.mem.indexOf(u8, text, "[u-ca=");
    const critical = std.mem.indexOf(u8, text, "[!u-ca=");
    if (normal != null or critical != null) {
        const use_critical = critical != null and (normal == null or critical.? < normal.?);
        const value_start = if (use_critical) critical.? + 7 else normal.? + 6;
        if (std.mem.indexOfScalarPos(u8, text, value_start, ']')) |end| return text[value_start..end];
    }
    return "iso8601";
}
