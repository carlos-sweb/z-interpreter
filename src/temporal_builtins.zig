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
//! Still NOT wired (z-temporal's own library gap, not a wiring gap --
//! see the plan's "Alcance NO"): `ZonedDateTime.prototype.add/subtract/
//! until/since/round/with/withCalendar/withPlainTime/withTimeZone` --
//! z-temporal's Phase 7a doesn't implement `ZonedDateTime` arithmetic
//! yet (confirmed reading `zoned_date_time.zig` in full: zero `pub fn`
//! for any of these). `toLocaleString` (no other Temporal type here has
//! it either -- would need real locale-aware formatting this engine
//! doesn't have).
const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const ztemporal = @import("ztemporal");
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
        error.InvalidRange => self.throwError(.range_error, "Value out of range for Temporal", .{}),
        error.InvalidFormat => self.throwError(.range_error, "Invalid Temporal string", .{}),
        error.InvalidField => self.throwError(.type_error, "Invalid or missing Temporal field", .{}),
        error.MixedCalendarUnits => self.throwError(.range_error, "Duration operand cannot mix calendar units with a relativeTo-less operation", .{}),
        error.NeedsRelativeTo => self.throwError(.range_error, "relativeTo is required for this operation", .{}),
        error.InvalidTimeZone => self.throwError(.range_error, "Invalid time zone", .{}),
        error.AmbiguousTime => self.throwError(.range_error, "Ambiguous or invalid wall-clock time", .{}),
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn requireI32(self: *Interpreter, v: JSValue, what: []const u8) anyerror!i32 {
    if (v != .number) return self.throwError(.type_error, "{s} must be a number", .{what});
    const n = v.number;
    if (!std.math.isFinite(n) or n != @trunc(n)) return self.throwError(.range_error, "{s} must be an integer", .{what});
    if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return self.throwError(.range_error, "{s} out of range", .{what});
    return @intFromFloat(n);
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

fn optionalI64(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!?i64 {
    if (obj != .object) return null;
    const v = obj.object.value.get(key) orelse return null;
    if (v == .undefined) return null;
    return try requireI64(self, v, key);
}

fn fieldI64(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!i64 {
    return (try optionalI64(self, obj, key)) orelse 0;
}

/// Reads `options.overflow` ("constrain"/"reject"), defaulting to
/// `.constrain` (real spec default for `.from`/`.with`). `options` may be
/// `undefined`.
fn readOverflow(self: *Interpreter, options: JSValue) anyerror!Overflow {
    if (options != .object) return .constrain;
    const v = options.object.value.get("overflow") orelse return .constrain;
    if (v == .undefined) return .constrain;
    if (v != .string) return self.throwError(.type_error, "overflow must be a string", .{});
    const s = v.string.value.data;
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
        .{ "ceil", .ceil },          .{ "floor", .floor },          .{ "trunc", .trunc },          .{ "expand", .expand },
        .{ "halfCeil", .half_ceil }, .{ "halfFloor", .half_floor }, .{ "halfTrunc", .half_trunc }, .{ "halfExpand", .half_expand },
        .{ "halfEven", .half_even },
    };
    for (names) |pair| {
        if (std.mem.eql(u8, s, pair[0])) return pair[1];
    }
    return self.throwError(.range_error, "Invalid roundingMode: {s}", .{s});
}

fn readRoundingOptionsGeneric(self: *Interpreter, comptime T: type, options: JSValue, default_mode: RoundingMode) anyerror!T {
    var out: T = .{ .rounding_mode = default_mode };
    if (options == .string) {
        // A bare unit string is shorthand for { smallestUnit: options }.
        out.smallest_unit = try unitFromString(self, options.string.value.data, "smallestUnit");
        return out;
    }
    if (options != .object) return out;
    const o = options.object.value;
    if (o.get("smallestUnit")) |v| if (v != .undefined) {
        if (v != .string) return self.throwError(.type_error, "smallestUnit must be a string", .{});
        out.smallest_unit = try unitFromString(self, v.string.value.data, "smallestUnit");
    };
    if (o.get("largestUnit")) |v| if (v != .undefined) {
        if (v != .string) return self.throwError(.type_error, "largestUnit must be a string", .{});
        out.largest_unit = try unitFromString(self, v.string.value.data, "largestUnit");
    };
    if (o.get("roundingIncrement")) |v| if (v != .undefined) {
        out.rounding_increment = try requireU32(self, v, "roundingIncrement");
    };
    if (o.get("roundingMode")) |v| if (v != .undefined) {
        if (v != .string) return self.throwError(.type_error, "roundingMode must be a string", .{});
        out.rounding_mode = try roundingModeFromString(self, v.string.value.data);
    };
    return out;
}

fn readRoundingOptions(self: *Interpreter, options: JSValue) anyerror!RoundingOptions {
    return readRoundingOptionsGeneric(self, RoundingOptions, options, .trunc);
}

fn readRoundOptions(self: *Interpreter, options: JSValue) anyerror!RoundOptions {
    return readRoundingOptionsGeneric(self, RoundOptions, options, .half_expand);
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
    if (v == .string) return ztemporal.Duration.parseIso(v.string.value.data) catch |e| temporalErr(self, e);
    if (v != .object) return self.throwError(.type_error, "Duration-like value required", .{});
    return ztemporal.Duration.create(
        try fieldI64(self, v, "years"),
        try fieldI64(self, v, "months"),
        try fieldI64(self, v, "weeks"),
        try fieldI64(self, v, "days"),
        try fieldI64(self, v, "hours"),
        try fieldI64(self, v, "minutes"),
        try fieldI64(self, v, "seconds"),
        try fieldI64(self, v, "milliseconds"),
        try fieldI64(self, v, "microseconds"),
        try fieldI64(self, v, "nanoseconds"),
    ) catch |e| temporalErr(self, e);
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
    const getter = try native(self, name, 0, call_fn);
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
    const year = try requireI32(self, arg(args, 0), "year");
    const month = try requireI32(self, arg(args, 1), "month");
    const day = try requireI32(self, arg(args, 2), "day");
    const pd = ztemporal.PlainDate.create(year, month, day, .reject) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = pd });
}

fn plainDateFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const item = arg(args, 0);
    const overflow = try readOverflow(self, arg(args, 1));
    if (item == .temporal and item.temporal.value == .plain_date) return self.gcNewTemporal(.{ .plain_date = item.temporal.value.plain_date });
    if (item == .string) {
        const pd = ztemporal.PlainDate.parseIso(item.string.value.data) catch |e| return temporalErr(self, e);
        return self.gcNewTemporal(.{ .plain_date = pd });
    }
    if (item != .object) return self.throwError(.type_error, "Temporal.PlainDate.from requires a string or an object", .{});
    const year = (try optionalI32(self, item, "year")) orelse return self.throwError(.type_error, "year is required", .{});
    const month = (try optionalI32(self, item, "month")) orelse return self.throwError(.type_error, "month is required", .{});
    const day = (try optionalI32(self, item, "day")) orelse return self.throwError(.type_error, "day is required", .{});
    const pd = ztemporal.PlainDate.create(year, month, day, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = pd });
}

fn plainDateCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try requireTemporal(self, arg(args, 0), .plain_date, "Temporal.PlainDate");
    const b = try requireTemporal(self, arg(args, 1), .plain_date, "Temporal.PlainDate");
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
    var buf: [3]u8 = undefined;
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
    return JSValue.fromNumber(@floatFromInt(w.week));
}

fn pdWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const fields = arg(args, 0);
    if (fields != .object) return self.throwError(.type_error, "with() requires an object", .{});
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pd.withFields(
        try optionalI32(self, fields, "year"),
        try optionalI32(self, fields, "month"),
        try optionalI32(self, fields, "day"),
        overflow,
    ) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = result });
}

fn pdAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pd.add(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = result });
}

fn pdSubtract(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pd.subtract(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date = result });
}

fn pdUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_date, "Temporal.PlainDate");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = pd.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pdSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_date, "Temporal.PlainDate");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = pd.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pdEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_date, "Temporal.PlainDate");
    return JSValue.fromBool(ztemporal.PlainDate.equals(pd, other));
}

fn pdToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const pd = try pdSelf(self, this_value);
    const s = pd.toIsoString(allocator, false) catch |e| return temporalErr(self, e);
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
    const hour = if (args.len > 0) try requireI32(self, arg(args, 0), "hour") else 0;
    const minute = if (args.len > 1) try requireI32(self, arg(args, 1), "minute") else 0;
    const second = if (args.len > 2) try requireI32(self, arg(args, 2), "second") else 0;
    const ms = if (args.len > 3) try requireI32(self, arg(args, 3), "millisecond") else 0;
    const us = if (args.len > 4) try requireI32(self, arg(args, 4), "microsecond") else 0;
    const ns = if (args.len > 5) try requireI32(self, arg(args, 5), "nanosecond") else 0;
    const pt = ztemporal.PlainTime.create(hour, minute, second, ms, us, ns, .reject) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_time = pt });
}

fn plainTimeFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const item = arg(args, 0);
    const overflow = try readOverflow(self, arg(args, 1));
    if (item == .temporal and item.temporal.value == .plain_time) return self.gcNewTemporal(.{ .plain_time = item.temporal.value.plain_time });
    if (item == .string) {
        const pt = ztemporal.PlainTime.parseIso(item.string.value.data) catch |e| return temporalErr(self, e);
        return self.gcNewTemporal(.{ .plain_time = pt });
    }
    if (item != .object) return self.throwError(.type_error, "Temporal.PlainTime.from requires a string or an object", .{});
    const pt = ztemporal.PlainTime.create(
        (try optionalI32(self, item, "hour")) orelse 0,
        (try optionalI32(self, item, "minute")) orelse 0,
        (try optionalI32(self, item, "second")) orelse 0,
        (try optionalI32(self, item, "millisecond")) orelse 0,
        (try optionalI32(self, item, "microsecond")) orelse 0,
        (try optionalI32(self, item, "nanosecond")) orelse 0,
        overflow,
    ) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_time = pt });
}

fn plainTimeCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try requireTemporal(self, arg(args, 0), .plain_time, "Temporal.PlainTime");
    const b = try requireTemporal(self, arg(args, 1), .plain_time, "Temporal.PlainTime");
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
    if (fields != .object) return self.throwError(.type_error, "with() requires an object", .{});
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pt.withFields(
        try optionalI32(self, fields, "hour"),
        try optionalI32(self, fields, "minute"),
        try optionalI32(self, fields, "second"),
        try optionalI32(self, fields, "millisecond"),
        try optionalI32(self, fields, "microsecond"),
        try optionalI32(self, fields, "nanosecond"),
        overflow,
    ) catch |e| return temporalErr(self, e);
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
    const opts = try readRoundOptions(self, arg(args, 0));
    const result = pt.round(opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_time = result });
}

fn ptUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_time, "Temporal.PlainTime");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = pt.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn ptSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_time, "Temporal.PlainTime");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = pt.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn ptEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_time, "Temporal.PlainTime");
    return JSValue.fromBool(ztemporal.PlainTime.equals(pt, other));
}

fn ptToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const pt = try ptSelf(self, this_value);
    const s = pt.toIsoString(allocator) catch |e| return temporalErr(self, e);
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
    const year = try requireI32(self, arg(args, 0), "year");
    const month = try requireI32(self, arg(args, 1), "month");
    const day = try requireI32(self, arg(args, 2), "day");
    const hour = if (args.len > 3) try requireI32(self, arg(args, 3), "hour") else 0;
    const minute = if (args.len > 4) try requireI32(self, arg(args, 4), "minute") else 0;
    const second = if (args.len > 5) try requireI32(self, arg(args, 5), "second") else 0;
    const ms = if (args.len > 6) try requireI32(self, arg(args, 6), "millisecond") else 0;
    const us = if (args.len > 7) try requireI32(self, arg(args, 7), "microsecond") else 0;
    const ns = if (args.len > 8) try requireI32(self, arg(args, 8), "nanosecond") else 0;
    const pdt = ztemporal.PlainDateTime.create(year, month, day, hour, minute, second, ms, us, ns, .reject) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = pdt });
}

fn plainDateTimeFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const item = arg(args, 0);
    const overflow = try readOverflow(self, arg(args, 1));
    if (item == .temporal and item.temporal.value == .plain_date_time) return self.gcNewTemporal(.{ .plain_date_time = item.temporal.value.plain_date_time });
    if (item == .string) {
        const pdt = ztemporal.PlainDateTime.parseIso(item.string.value.data) catch |e| return temporalErr(self, e);
        return self.gcNewTemporal(.{ .plain_date_time = pdt });
    }
    if (item != .object) return self.throwError(.type_error, "Temporal.PlainDateTime.from requires a string or an object", .{});
    const year = (try optionalI32(self, item, "year")) orelse return self.throwError(.type_error, "year is required", .{});
    const month = (try optionalI32(self, item, "month")) orelse return self.throwError(.type_error, "month is required", .{});
    const day = (try optionalI32(self, item, "day")) orelse return self.throwError(.type_error, "day is required", .{});
    const pdt = ztemporal.PlainDateTime.create(
        year,
        month,
        day,
        (try optionalI32(self, item, "hour")) orelse 0,
        (try optionalI32(self, item, "minute")) orelse 0,
        (try optionalI32(self, item, "second")) orelse 0,
        (try optionalI32(self, item, "millisecond")) orelse 0,
        (try optionalI32(self, item, "microsecond")) orelse 0,
        (try optionalI32(self, item, "nanosecond")) orelse 0,
        overflow,
    ) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = pdt });
}

fn plainDateTimeCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try requireTemporal(self, arg(args, 0), .plain_date_time, "Temporal.PlainDateTime");
    const b = try requireTemporal(self, arg(args, 1), .plain_date_time, "Temporal.PlainDateTime");
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
    var buf: [3]u8 = undefined;
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
    if (fields != .object) return self.throwError(.type_error, "with() requires an object", .{});
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pdt.withFields(
        try optionalI32(self, fields, "year"),
        try optionalI32(self, fields, "month"),
        try optionalI32(self, fields, "day"),
        try optionalI32(self, fields, "hour"),
        try optionalI32(self, fields, "minute"),
        try optionalI32(self, fields, "second"),
        try optionalI32(self, fields, "millisecond"),
        try optionalI32(self, fields, "microsecond"),
        try optionalI32(self, fields, "nanosecond"),
        overflow,
    ) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = result });
}

fn pdtAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pdt.add(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = result });
}

fn pdtSubtract(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pdt.subtract(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = result });
}

fn pdtRound(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const opts = try readRoundOptions(self, arg(args, 0));
    const result = pdt.round(opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_date_time = result });
}

fn pdtUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_date_time, "Temporal.PlainDateTime");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = pdt.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pdtSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_date_time, "Temporal.PlainDateTime");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = pdt.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pdtEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_date_time, "Temporal.PlainDateTime");
    return JSValue.fromBool(ztemporal.PlainDateTime.equals(pdt, other));
}

fn pdtToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const pdt = try pdtSelf(self, this_value);
    const s = pdt.toIsoString(allocator, false) catch |e| return temporalErr(self, e);
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

/// `epochNanoseconds` is a BigInt in real Temporal (nanosecond precision
/// exceeds Number.MAX_SAFE_INTEGER routinely). NARROWING: z-bigint has no
/// i128 extraction yet (only `toFloat`), so a bigint argument here goes
/// through a float round-trip -- exact for a plain JS number, lossy past
/// 2^53 for a real bigint literal. A number argument is accepted directly
/// (also real spec behavior for `fromEpochMilliseconds`, just not for
/// nanoseconds -- kept permissive here rather than rejecting outright).
fn coerceEpochNanoseconds(self: *Interpreter, v: JSValue, what: []const u8) anyerror!i128 {
    const n = switch (v) {
        .number => |num| num,
        .bigint => |box| box.value.toFloat(),
        else => return self.throwError(.type_error, "{s} must be a number or bigint", .{what}),
    };
    if (!std.math.isFinite(n)) return self.throwError(.range_error, "{s} must be finite", .{what});
    // Bounds-checked BEFORE @intFromFloat (panics, not a catchable error,
    // past i128's range) -- same discipline as requireI64 above.
    const maxf: f64 = @floatFromInt(std.math.maxInt(i128));
    const minf: f64 = @floatFromInt(std.math.minInt(i128));
    if (n < minf or n > maxf) return self.throwError(.range_error, "{s} out of range", .{what});
    return @intFromFloat(n);
}

fn instantConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const ns = try coerceEpochNanoseconds(self, arg(args, 0), "epochNanoseconds");
    const inst = ztemporal.Instant.fromEpochNanoseconds(ns) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .instant = inst });
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
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const item = arg(args, 0);
    if (item == .temporal and item.temporal.value == .instant) return self.gcNewTemporal(.{ .instant = item.temporal.value.instant });
    if (item != .string) return self.throwError(.type_error, "Temporal.Instant.from requires a string", .{});
    const inst = ztemporal.Instant.parseIso(item.string.value.data) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .instant = inst });
}

fn instantCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try requireTemporal(self, arg(args, 0), .instant, "Temporal.Instant");
    const b = try requireTemporal(self, arg(args, 1), .instant, "Temporal.Instant");
    return JSValue.fromNumber(orderToJs(ztemporal.Instant.compare(a, b)));
}

fn instGetEpochMilliseconds(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try instSelf(interp(ctx), this_value)).epochMilliseconds()));
}

/// NARROWING: real `.epochNanoseconds` is a BigInt getter; exposed here
/// as a Number (precision-lossy past 2^53), same tradeoff as
/// `coerceEpochNanoseconds` above, until z-bigint gets i128 support.
fn instGetEpochNanoseconds(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(@floatFromInt((try instSelf(interp(ctx), this_value)).epochNanoseconds()));
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

fn instUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .instant, "Temporal.Instant");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = inst.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn instSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .instant, "Temporal.Instant");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = inst.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn instRound(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const opts = try readRoundOptions(self, arg(args, 0));
    const result = inst.round(opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .instant = result });
}

fn instEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .instant, "Temporal.Instant");
    return JSValue.fromBool(ztemporal.Instant.equals(inst, other));
}

fn instToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const inst = try instSelf(self, this_value);
    const s = inst.toIsoString(allocator) catch |e| return temporalErr(self, e);
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
    var vals: [10]i64 = .{0} ** 10;
    for (0..@min(args.len, 10)) |i| vals[i] = try requireI64(self, args[i], "duration field");
    const d = ztemporal.Duration.create(vals[0], vals[1], vals[2], vals[3], vals[4], vals[5], vals[6], vals[7], vals[8], vals[9]) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn durationFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const d = try coerceDuration(self, arg(args, 0));
    return self.gcNewTemporal(.{ .duration = d });
}

fn durationCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try coerceDuration(self, arg(args, 0));
    const b = try coerceDuration(self, arg(args, 1));
    const order = ztemporal.Duration.compare(a, b) catch |e| return temporalErr(self, e);
    return JSValue.fromNumber(orderToJs(order));
}

fn durField(comptime field: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = args;
            const d = try durSelf(interp(ctx), this_value);
            return JSValue.fromNumber(@floatFromInt(@field(d, field)));
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

fn durWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const fields = arg(args, 0);
    if (fields != .object) return self.throwError(.type_error, "with() requires an object", .{});
    const result = d.withFields(.{
        .years = try optionalI64(self, fields, "years"),
        .months = try optionalI64(self, fields, "months"),
        .weeks = try optionalI64(self, fields, "weeks"),
        .days = try optionalI64(self, fields, "days"),
        .hours = try optionalI64(self, fields, "hours"),
        .minutes = try optionalI64(self, fields, "minutes"),
        .seconds = try optionalI64(self, fields, "seconds"),
        .milliseconds = try optionalI64(self, fields, "milliseconds"),
        .microseconds = try optionalI64(self, fields, "microseconds"),
        .nanoseconds = try optionalI64(self, fields, "nanoseconds"),
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

/// `relativeTo` (a `Temporal.PlainDate`) is required for calendar-unit
/// operations (see `TemporalError.NeedsRelativeTo`) -- optional here,
/// `null` when absent/undefined, matching `round`/`.total()`'s own
/// `?PlainDate` parameter.
fn readRelativeTo(self: *Interpreter, options: JSValue) anyerror!?ztemporal.PlainDate {
    if (options != .object) return null;
    const v = options.object.value.get("relativeTo") orelse return null;
    if (v == .undefined) return null;
    return try requireTemporal(self, v, .plain_date, "Temporal.PlainDate");
}

fn durRound(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const options = arg(args, 0);
    const opts = try readRoundOptions(self, options);
    const relative_to = try readRelativeTo(self, options);
    const result = d.round(relative_to, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = result });
}

fn durTotal(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const options = arg(args, 0);
    var unit_str: []const u8 = "";
    if (options == .string) {
        unit_str = options.string.value.data;
    } else if (options == .object) {
        if (options.object.value.get("unit")) |v| if (v == .string) {
            unit_str = v.string.value.data;
        };
    }
    if (unit_str.len == 0) return self.throwError(.type_error, "total() requires a unit", .{});
    const unit = try unitFromString(self, unit_str, "unit");
    const relative_to = try readRelativeTo(self, options);
    const result = d.total(relative_to, unit) catch |e| return temporalErr(self, e);
    return JSValue.fromNumber(result);
}

fn durToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const d = try durSelf(self, this_value);
    const s = d.toIsoString(allocator) catch |e| return temporalErr(self, e);
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
    const year = try requireI32(self, arg(args, 0), "year");
    const month = try requireI32(self, arg(args, 1), "month");
    const pym = ztemporal.PlainYearMonth.create(year, month, .reject) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_year_month = pym });
}

fn plainYearMonthFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const item = arg(args, 0);
    const overflow = try readOverflow(self, arg(args, 1));
    if (item == .temporal and item.temporal.value == .plain_year_month) return self.gcNewTemporal(.{ .plain_year_month = item.temporal.value.plain_year_month });
    if (item == .string) {
        const pym = ztemporal.PlainYearMonth.parseIso(item.string.value.data) catch |e| return temporalErr(self, e);
        return self.gcNewTemporal(.{ .plain_year_month = pym });
    }
    if (item != .object) return self.throwError(.type_error, "Temporal.PlainYearMonth.from requires a string or an object", .{});
    const year = (try optionalI32(self, item, "year")) orelse return self.throwError(.type_error, "year is required", .{});
    const month = (try optionalI32(self, item, "month")) orelse return self.throwError(.type_error, "month is required", .{});
    const pym = ztemporal.PlainYearMonth.create(year, month, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_year_month = pym });
}

fn plainYearMonthCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try requireTemporal(self, arg(args, 0), .plain_year_month, "Temporal.PlainYearMonth");
    const b = try requireTemporal(self, arg(args, 1), .plain_year_month, "Temporal.PlainYearMonth");
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
    var buf: [3]u8 = undefined;
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
    if (fields != .object) return self.throwError(.type_error, "with() requires an object", .{});
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pym.withFields(try optionalI32(self, fields, "year"), try optionalI32(self, fields, "month"), overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_year_month = result });
}

fn pymAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pym.add(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_year_month = result });
}

fn pymSubtract(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const d = try coerceDuration(self, arg(args, 0));
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pym.subtract(d, overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_year_month = result });
}

fn pymUntil(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_year_month, "Temporal.PlainYearMonth");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = pym.until(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pymSince(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_year_month, "Temporal.PlainYearMonth");
    const opts = try readRoundingOptions(self, arg(args, 1));
    const d = pym.since(other, opts) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .duration = d });
}

fn pymEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_year_month, "Temporal.PlainYearMonth");
    return JSValue.fromBool(ztemporal.PlainYearMonth.equals(pym, other));
}

fn pymToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const pym = try pymSelf(self, this_value);
    const s = pym.toIsoString(allocator, false) catch |e| return temporalErr(self, e);
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
    const month = try requireI32(self, arg(args, 0), "month");
    const day = try requireI32(self, arg(args, 1), "day");
    const pmd = ztemporal.PlainMonthDay.create(month, day, .reject) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_month_day = pmd });
}

fn plainMonthDayFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const item = arg(args, 0);
    const overflow = try readOverflow(self, arg(args, 1));
    if (item == .temporal and item.temporal.value == .plain_month_day) return self.gcNewTemporal(.{ .plain_month_day = item.temporal.value.plain_month_day });
    if (item == .string) {
        const pmd = ztemporal.PlainMonthDay.parseIso(item.string.value.data) catch |e| return temporalErr(self, e);
        return self.gcNewTemporal(.{ .plain_month_day = pmd });
    }
    if (item != .object) return self.throwError(.type_error, "Temporal.PlainMonthDay.from requires a string or an object", .{});
    const month = (try optionalI32(self, item, "month")) orelse return self.throwError(.type_error, "month is required", .{});
    const day = (try optionalI32(self, item, "day")) orelse return self.throwError(.type_error, "day is required", .{});
    const pmd = ztemporal.PlainMonthDay.create(month, day, overflow) catch |e| return temporalErr(self, e);
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
    var buf: [3]u8 = undefined;
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
    if (fields != .object) return self.throwError(.type_error, "with() requires an object", .{});
    const overflow = try readOverflow(self, arg(args, 1));
    const result = pmd.withFields(try optionalI32(self, fields, "month"), try optionalI32(self, fields, "day"), overflow) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .plain_month_day = result });
}

fn pmdEquals(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    const pmd = try pmdSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .plain_month_day, "Temporal.PlainMonthDay");
    return JSValue.fromBool(ztemporal.PlainMonthDay.equals(pmd, other));
}

fn pmdToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const pmd = try pmdSelf(self, this_value);
    const s = pmd.toIsoString(allocator, false) catch |e| return temporalErr(self, e);
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

/// `new Temporal.ZonedDateTime(epochNanoseconds, timeZone, calendar?)`.
/// The `calendar` argument is accepted but not read/validated -- same
/// precedent every other wired Temporal type here already has (none
/// reads its own trailing `calendar` constructor argument; the library
/// only supports iso8601, so there is nothing else to select).
/// The `calendar` argument, real spec: `undefined`/omitted defaults to
/// `"iso8601"`; anything else must be a string equal to a recognized
/// calendar ID -- narrowed here to exactly `"iso8601"`, the only one
/// this library supports (its own README: "non-iso8601 calendar
/// annotations are rejected"). A non-string throws TypeError the same
/// observable way real ToTemporalCalendarIdentifier would (a Symbol
/// can't even be ToString'd; a number/bigint/object stringifies to
/// something that isn't a valid calendar ID either way).
fn requireIso8601Calendar(self: *Interpreter, v: JSValue) anyerror!void {
    if (v == .undefined) return;
    if (v == .string and std.mem.eql(u8, v.string.value.data, "iso8601")) return;
    return self.throwError(.type_error, "Invalid calendar", .{});
}

fn zonedDateTimeConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Temporal.ZonedDateTime requires 'new'", .{});
    const ns = try coerceEpochNanoseconds(self, arg(args, 0), "epochNanoseconds");
    const tz_arg = arg(args, 1);
    if (tz_arg != .string) return self.throwError(.type_error, "timeZone must be a string", .{});
    try requireIso8601Calendar(self, arg(args, 2));
    const zdt = ztemporal.ZonedDateTime.create(allocator, ioHandle(), ns, tz_arg.string.value.data) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .zoned_date_time = zdt });
}

fn zonedDateTimeFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const item = arg(args, 0);
    const options = arg(args, 1);
    if (item == .temporal and item.temporal.value == .zoned_date_time) return self.gcNewTemporal(.{ .zoned_date_time = item.temporal.value.zoned_date_time });
    const disambiguation = try readDisambiguation(self, options);
    if (item == .string) {
        const offset_option = try readOffsetOption(self, options);
        const zdt = ztemporal.ZonedDateTime.parseIso(allocator, ioHandle(), item.string.value.data, offset_option, disambiguation) catch |e| return temporalErr(self, e);
        return self.gcNewTemporal(.{ .zoned_date_time = zdt });
    }
    if (item != .object) return self.throwError(.type_error, "Temporal.ZonedDateTime.from requires a string or an object", .{});
    const overflow = try readOverflow(self, options);
    const tz_v = item.object.value.get("timeZone") orelse return self.throwError(.type_error, "timeZone is required", .{});
    if (tz_v != .string) return self.throwError(.type_error, "timeZone must be a string", .{});
    const year = (try optionalI32(self, item, "year")) orelse return self.throwError(.type_error, "year is required", .{});
    const month = (try optionalI32(self, item, "month")) orelse return self.throwError(.type_error, "month is required", .{});
    const day = (try optionalI32(self, item, "day")) orelse return self.throwError(.type_error, "day is required", .{});
    const zdt = ztemporal.ZonedDateTime.fromFields(
        allocator,
        ioHandle(),
        year,
        month,
        day,
        (try optionalI32(self, item, "hour")) orelse 0,
        (try optionalI32(self, item, "minute")) orelse 0,
        (try optionalI32(self, item, "second")) orelse 0,
        (try optionalI32(self, item, "millisecond")) orelse 0,
        (try optionalI32(self, item, "microsecond")) orelse 0,
        (try optionalI32(self, item, "nanosecond")) orelse 0,
        tz_v.string.value.data,
        overflow,
        disambiguation,
    ) catch |e| return temporalErr(self, e);
    return self.gcNewTemporal(.{ .zoned_date_time = zdt });
}

fn zonedDateTimeCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = try requireTemporal(self, arg(args, 0), .zoned_date_time, "Temporal.ZonedDateTime");
    const b = try requireTemporal(self, arg(args, 1), .zoned_date_time, "Temporal.ZonedDateTime");
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
/// getter for this (only its internal `toIsoString` formats one), so
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
/// `yearOfWeek` is `weekOfYear().year` -- easy to add later alongside
/// fixing PlainDate's own gap, out of scope here).
fn zdtGetMonthCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const pd = zdt.toPlainDate(allocator, ioHandle()) catch |e| return temporalErr(self, e);
    var buf: [3]u8 = undefined;
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
    return JSValue.fromNumber(@floatFromInt(pd.weekOfYear().week));
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
    return JSValue.fromNumber(@floatFromInt((try zdtSelf(interp(ctx), this_value)).toInstant().epochNanoseconds()));
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
    _ = allocator;
    const self = interp(ctx);
    const zdt = try zdtSelf(self, this_value);
    const other = try requireTemporal(self, arg(args, 0), .zoned_date_time, "Temporal.ZonedDateTime");
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
    if (dir_arg != .string) return self.throwError(.type_error, "direction must be a string", .{});
    const direction = try transitionDirectionFromString(self, dir_arg.string.value.data);
    const result = zdt.getTimeZoneTransition(allocator, ioHandle(), direction) catch |e| return temporalErr(self, e);
    const found = result orelse return JSValue.NULL;
    return self.gcNewTemporal(.{ .zoned_date_time = found });
}
fn zdtToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    var zdt = try zdtSelf(self, this_value);
    // Real spec default (confirmed against Node): show the offset and
    // the time zone name, but not a `[u-ca=iso8601]` calendar
    // annotation (iso8601 is implicit). `toString`'s options object
    // (`offset`/`timeZoneName`/`calendarName`) isn't read here --
    // same "don't chase every formatting option" precedent this
    // engine's other Temporal `toString`s already have.
    // `toIsoString`'s inferred error set also includes `error.NoSpaceLeft`
    // from its internal fixed-size offset buffer -- unreachable in
    // practice (the buffer is sized exactly for "+HH:MM"), but Zig's
    // inferred set still requires handling it to narrow the rest back
    // down to `TemporalError` for `temporalErr`.
    const s = zdt.toIsoString(allocator, ioHandle(), true, true, false) catch |e| switch (e) {
        error.NoSpaceLeft => unreachable,
        else => |te| return temporalErr(self, te),
    };
    defer allocator.free(s);
    return self.gcNewString(s);
}
fn zdtToJSON(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    return zdtToString(ctx, allocator, this_value, args);
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
    return self.gcNewTemporal(.{ .instant = ztemporal.Now.instant() });
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

    try self.global_env.define(self.gc_allocator, "Temporal", temporal_ns);
}
