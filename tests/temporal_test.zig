//! End-to-end Temporal integration, metadata, conversions, arithmetic and GC.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "Temporal global exists with all 8 wired types" {
    try helpers.expectStdout(
        \\console.log(
        \\  typeof Temporal, typeof Temporal.PlainDate, typeof Temporal.PlainTime,
        \\  typeof Temporal.PlainDateTime, typeof Temporal.PlainYearMonth,
        \\  typeof Temporal.PlainMonthDay, typeof Temporal.Instant,
        \\  typeof Temporal.Duration, typeof Temporal.ZonedDateTime,
        \\  typeof Temporal.Now, typeof Temporal.Now.instant
        \\);
    , "object function function function function function function function function object function\n");
}

test "Temporal epoch nanoseconds preserve BigInt type and exact values" {
    try helpers.expectStdout(
        \\const n = 957270896987654321n;
        \\const instant = new Temporal.Instant(n);
        \\const zoned = new Temporal.ZonedDateTime(n, 'UTC');
        \\console.log(typeof instant.epochNanoseconds, instant.epochNanoseconds === n);
        \\console.log(typeof zoned.epochNanoseconds, zoned.epochNanoseconds === n);
        \\console.log(Temporal.Instant.fromEpochNanoseconds(-n).epochNanoseconds === -n);
        \\console.log(Temporal.Instant.fromEpochNanoseconds(0n).epochNanoseconds === 0n);
        \\console.log(Temporal.Instant.fromEpochNanoseconds(8640000000000000000000n).epochNanoseconds === 8640000000000000000000n);
        \\console.log(Temporal.Instant.fromEpochNanoseconds(-8640000000000000000000n).epochNanoseconds === -8640000000000000000000n);
    , "bigint true\nbigint true\ntrue\ntrue\ntrue\ntrue\n");
}

test "Temporal epoch nanoseconds use ToBigInt and reject out-of-range values" {
    try helpers.expectStdout(
        \\console.log(new Temporal.Instant('123').epochNanoseconds === 123n);
        \\console.log(new Temporal.Instant(true).epochNanoseconds === 1n);
        \\console.log(new Temporal.Instant({ valueOf() { return -123n; } }).epochNanoseconds === -123n);
        \\for (const input of [1, 1.5, 8640000000000000000001n, -8640000000000000000001n, 170141183460469231731687303715884105728n]) {
        \\  try { new Temporal.Instant(input); console.log('accepted'); }
        \\  catch (e) { console.log(e.name); }
        \\}
        \\try { new Temporal.ZonedDateTime(1, 'UTC'); console.log('accepted'); }
        \\catch (e) { console.log(e.name); }
    , "true\ntrue\ntrue\nTypeError\nTypeError\nRangeError\nRangeError\nRangeError\nTypeError\n");
}

test "PlainDate: construction, getters, leap year" {
    try helpers.expectStdout(
        \\const pd = new Temporal.PlainDate(2024, 6, 15);
        \\console.log(pd.year, pd.month, pd.day, pd.monthCode, pd.dayOfWeek, pd.daysInMonth, pd.inLeapYear, pd.toString());
    , "2024 6 15 M06 6 30 true 2024-06-15\n");
}

test "PlainDate.from: string and object, with an overflow option" {
    try helpers.expectStdout(
        \\console.log(Temporal.PlainDate.from('2024-06-15').toString());
        \\console.log(Temporal.PlainDate.from({ year: 2024, month: 6, day: 15 }).toString());
        \\console.log(Temporal.PlainDate.from({ year: 2024, month: 2, day: 30 }, { overflow: 'constrain' }).toString());
    , "2024-06-15\n2024-06-15\n2024-02-29\n");
}

test "PlainDate.add/subtract/with/until/since round-trip" {
    try helpers.expectStdout(
        \\const a = new Temporal.PlainDate(2024, 1, 1);
        \\const b = new Temporal.PlainDate(2024, 12, 31);
        \\const d = a.until(b);
        \\console.log(a.add(d).equals(b));
        \\console.log(b.subtract(d).equals(a));
        \\console.log(a.since(b).sign, b.since(a).sign);
        \\console.log(a.with({ month: 6 }).toString());
    , "true\ntrue\n-1 1\n2024-06-01\n");
}

test "PlainDate.compare, equals, and identity semantics (never ===)" {
    try helpers.expectStdout(
        \\const a = new Temporal.PlainDate(2024, 1, 1);
        \\const b = new Temporal.PlainDate(2024, 1, 2);
        \\console.log(Temporal.PlainDate.compare(a, a), Temporal.PlainDate.compare(a, b), Temporal.PlainDate.compare(b, a));
        \\console.log(a.equals(a), a.equals(b));
        \\console.log(a === Temporal.PlainDate.from('2024-01-01'));
    , "0 -1 1\ntrue false\nfalse\n");
}

test "PlainDate: invalid input is a catchable RangeError, wrong receiver a TypeError" {
    try helpers.expectStdout(
        \\try { new Temporal.PlainDate(2024, 13, 1); console.log('no error'); } catch (e) { console.log(e.name); }
        \\try { Temporal.PlainDate.prototype.year; console.log('no error'); } catch (e) { console.log(e.name); }
    , "RangeError\nTypeError\n");
}

test "PlainTime: construction, arithmetic, comparison" {
    try helpers.expectStdout(
        \\const t = new Temporal.PlainTime(13, 30, 15);
        \\console.log(t.hour, t.minute, t.second, t.toString());
        \\console.log(t.add({ hours: 12 }).toString());
        \\console.log(Temporal.PlainTime.compare(t, new Temporal.PlainTime(13, 30, 15)));
    , "13 30 15 13:30:15\n01:30:15\n0\n");
}

test "PlainDateTime: construction, getters, toPlainDate/toPlainTime" {
    try helpers.expectStdout(
        \\const dt = new Temporal.PlainDateTime(2024, 6, 15, 13, 30, 0);
        \\console.log(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.toString());
        \\console.log(dt.toPlainDate().toString(), dt.toPlainTime().toString());
    , "2024 6 15 13 30 2024-06-15T13:30:00\n2024-06-15 13:30:00\n");
}

test "PlainYearMonth: leap year Feb has 29 days, non-leap has 28" {
    try helpers.expectStdout(
        \\console.log(new Temporal.PlainYearMonth(2024, 2).daysInMonth);
        \\console.log(new Temporal.PlainYearMonth(2023, 2).daysInMonth);
    , "29\n28\n");
}

test "PlainMonthDay: construction and toPlainDate, no arithmetic methods exist" {
    try helpers.expectStdout(
        \\const pmd = Temporal.PlainMonthDay.from({ month: 2, day: 29 });
        \\console.log(pmd.monthCode, pmd.day, pmd.toString());
        \\console.log(pmd.toPlainDate({ year: 2024 }).toString());
        \\console.log(typeof pmd.add, typeof pmd.until);
    , "M02 29 02-29\n2024-02-29\nundefined undefined\n");
}

test "Instant: fromEpochMilliseconds, getters, arithmetic" {
    try helpers.expectStdout(
        \\const inst = Temporal.Instant.fromEpochMilliseconds(1718000000000);
        \\console.log(inst.epochMilliseconds, inst.toString());
        \\const later = inst.add({ hours: 1 });
        \\console.log(later.epochMilliseconds - inst.epochMilliseconds);
    , "1718000000000 2024-06-10T06:13:20Z\n3600000\n");
}

test "Duration: fields, sign, negated, abs, arithmetic, toString" {
    try helpers.expectStdout(
        \\const d = Temporal.Duration.from({ years: 1, months: 2, days: 3 });
        \\console.log(d.years, d.months, d.days, d.sign, d.blank, d.toString());
        \\const neg = d.negated();
        \\console.log(neg.years, neg.sign);
        \\console.log(d.abs().sign);
        \\console.log(new Temporal.Duration().blank);
    , "1 2 3 1 false P1Y2M3D\n-1 -1\n1\ntrue\n");
}

test "Duration.compare and Duration.add" {
    try helpers.expectStdout(
        \\const a = Temporal.Duration.from({ hours: 1 });
        \\const b = Temporal.Duration.from({ hours: 2 });
        \\console.log(Temporal.Duration.compare(a, b), Temporal.Duration.compare(a, a));
        \\console.log(a.add(b).hours);
    , "-1 0\n3\n");
}

test "Temporal.Now.instant returns a real, current-ish time" {
    try helpers.expectStdout(
        \\console.log(Temporal.Now.instant().epochMilliseconds > 1700000000000);
    , "true\n");
}

test "console.log renders a Temporal instance with its kind name and ISO string" {
    try helpers.expectStdout(
        \\console.log(new Temporal.PlainDate(2024, 6, 15));
    , "Temporal.PlainDate 2024-06-15\n");
}

test "z-temporal v0.2.0: PlainTime ignores unknown calendar annotations" {
    try helpers.expectStdout(
        \\const a = Temporal.PlainTime.from('12:34:56.987654321[!u-ca=unknown]');
        \\const b = Temporal.PlainTime.from('1970-01-01T12:34:56.987654321[u-ca=hebrew]');
        \\console.log(a.toString(), a.equals(b), a.until(b).blank, a.since(b).blank);
    , "12:34:56.987654321 true true true\n");
}

test "z-temporal v0.2.0: Instant rounding increments use a full day" {
    try helpers.expectStdout(
        \\const a = Temporal.Instant.from('1976-11-18T14:23:30.123456789Z');
        \\console.log(a.round({ smallestUnit: 'minute', roundingIncrement: 1440 }).toString());
        \\console.log(a.round({ smallestUnit: 'second', roundingIncrement: 86400 }).toString());
        \\console.log(a.round({ smallestUnit: 'millisecond', roundingIncrement: 86400000 }).toString());
    , "1976-11-19T00:00:00Z\n1976-11-19T00:00:00Z\n1976-11-19T00:00:00Z\n");
}

test "Temporal surface: constructor attributes and ordinary function controls" {
    try helpers.expectStdout(
        \\for (const C of [Temporal.PlainDate, Temporal.PlainTime, Temporal.PlainDateTime, Temporal.PlainYearMonth, Temporal.PlainMonthDay, Temporal.Instant, Temporal.Duration, Temporal.ZonedDateTime]) {
        \\  const p = Object.getOwnPropertyDescriptor(C, 'prototype');
        \\  if (p.writable || p.enumerable || p.configurable) throw 'prototype attributes';
        \\  const c = Object.getOwnPropertyDescriptor(C.prototype, 'constructor');
        \\  if (!c.writable || c.enumerable || !c.configurable || c.value !== C) throw 'constructor attributes';
        \\  Object.defineProperty(C, 'prototype', { value: C.prototype });
        \\  try { C.prototype = {}; throw 'assignment accepted'; } catch (e) { if (!(e instanceof TypeError)) throw e; }
        \\  try { Object.defineProperty(C, 'prototype', { writable: true }); throw 'redefinition accepted'; } catch (e) { if (!(e instanceof TypeError)) throw e; }
        \\}
        \\function F() {} F.prototype = { ok: true };
        \\console.log(F.prototype.ok, Object.getOwnPropertyDescriptor(F, 'prototype').writable);
    , "true true\n");
}

test "Temporal surface: dynamic symbols and branded getter metadata" {
    try helpers.expectStdout(
        \\const d = new Temporal.PlainDate(2024, 2, 29);
        \\console.log(Object.prototype.toString.call(d), Object.prototype.toString.call(Temporal), Object.prototype.toString.call(Temporal.Now));
        \\const descriptor = Object.getOwnPropertyDescriptor(Temporal.PlainDate.prototype, Symbol.toStringTag);
        \\console.log(descriptor.writable, descriptor.enumerable, descriptor.configurable);
        \\Object.defineProperty(Temporal.PlainDate.prototype, Symbol.toStringTag, { value: 'Changed', configurable: true });
        \\console.log(Object.prototype.toString.call(d));
        \\delete Temporal.PlainDate.prototype[Symbol.toStringTag];
        \\console.log(Object.prototype.toString.call(d));
        \\const g = Object.getOwnPropertyDescriptor(Temporal.PlainDate.prototype, 'era').get;
        \\console.log(g.name, g.length, d.era, d.daysInWeek, d.yearOfWeek);
        \\try { g.call({}); } catch (e) { console.log(e instanceof TypeError); }
    , "[object Temporal.PlainDate] [object Temporal] [object Temporal.Now]\nfalse false true\n[object Changed]\n[object Object]\nget era 0 undefined 7 2024\ntrue\n");
}

test "Temporal surface: serialization, locale fallback and rejecting valueOf" {
    try helpers.expectStdout(
        \\const values = [new Temporal.PlainDate(2024, 2, 29), new Temporal.PlainTime(12), new Temporal.PlainDateTime(2024, 2, 29), new Temporal.PlainYearMonth(2024, 2), new Temporal.PlainMonthDay(2, 29), new Temporal.Instant(0n), new Temporal.Duration(0, 0, 0, 1), new Temporal.ZonedDateTime(0n, 'UTC')];
        \\for (const v of values) {
        \\  if (v.toJSON() !== v.toString() || v.toLocaleString('en', {}) !== v.toString()) throw 'serialization';
        \\  try { v.valueOf(); throw 'valueOf accepted'; } catch (e) { if (!(e instanceof TypeError)) throw e; }
        \\  try { v.toJSON.call({}); throw 'receiver accepted'; } catch (e) { if (!(e instanceof TypeError)) throw e; }
        \\}
        \\console.log('ok');
    , "ok\n");
}

test "Temporal surface: Plain conversions and calendar-preserving changes" {
    try helpers.expectStdout(
        \\const d = new Temporal.PlainDate(2024, 2, 29);
        \\console.log(d.toPlainDateTime().toString(), d.toPlainYearMonth().toString(), d.toPlainMonthDay().toString());
        \\console.log(d.toZonedDateTime({ timeZone: 'UTC', plainTime: { hour: 12 } }).hour);
        \\const dt = d.toPlainDateTime('12:34');
        \\console.log(dt.withPlainTime().hour, dt.withPlainTime({ hour: '9' }).hour, dt.withCalendar('iso8601').calendarId);
        \\console.log(dt.toZonedDateTime('UTC').hour, d.withCalendar('iso8601').calendarId);
        \\console.log(d.withCalendar('01-01').calendarId, dt.withCalendar('2024-02').calendarId);
    , "2024-02-29T00:00:00 2024-02 02-29\n12\n0 9 iso8601\n12 iso8601\niso8601 iso8601\n");
}

test "Temporal surface: ZonedDateTime arithmetic, DST and differences" {
    try helpers.expectStdout(
        \\const a = Temporal.ZonedDateTime.from('2024-03-09T12:00[America/New_York]');
        \\const b = a.add({ days: 1 });
        \\console.log(b.hour, a.add({ hours: 24 }).hour, a.until(b, { largestUnit: 'hour' }).hours, b.since(a, { largestUnit: 'hour' }).hours);
        \\console.log(b.subtract({ days: 1 }).equals(a), b.with({ hour: 9 }).hour, b.withPlainTime().hour);
        \\console.log(a.until(b).hours, a.until(b, { largestUnit: 'auto' }).hours);
        \\console.log(b.withTimeZone('UTC').hour, b.withCalendar('iso8601').calendarId, b.round('day').hour);
    , "12 13 23 23\ntrue 9 0\n23 23\n16 iso8601 0\n");
}

test "Temporal surface: PlainYearMonth calendar formatting preserves reference day" {
    try helpers.expectStdout(
        \\const y = new Temporal.PlainYearMonth(2024, 2, 'iso8601', 15);
        \\console.log(y.toString(), y.toString({ calendarName: 'always' }), y.toString({ calendarName: 'critical' }), y.toString({ calendarName: 'never' }));
        \\const f = () => {}; f.calendarName = 'always'; console.log(y.toString(f));
    , "2024-02 2024-02-15[u-ca=iso8601] 2024-02-15[!u-ca=iso8601] 2024-02\n2024-02-15[u-ca=iso8601]\n");
}

test "Temporal surface: Date conversion validates brand and preserves exact milliseconds" {
    try helpers.expectStdout(
        \\console.log(new Date(-1).toTemporalInstant().toString());
        \\console.log(new Date(8640000000000000).toTemporalInstant().toString());
        \\try { new Date(NaN).toTemporalInstant(); } catch (e) { console.log(e instanceof RangeError); }
        \\try { Date.prototype.toTemporalInstant.call({}); } catch (e) { console.log(e instanceof TypeError); }
    , "1969-12-31T23:59:59.999Z\n+275760-09-13T00:00:00Z\ntrue\ntrue\n");
}

test "Temporal surface: converted values remain reachable through collection" {
    const zinterpreter = @import("zinterpreter");
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
    defer interpreter.deinit();
    const initial = try interpreter.run(
        \\var date = new Temporal.PlainDate(2024, 2, 29);
        \\var zoned = date.toZonedDateTime('UTC').add({ days: 1 }).withTimeZone('America/New_York');
        \\var describe = () => Object.getOwnPropertyDescriptors(Temporal.PlainDate.prototype);
    );
    initial.deinit();
    interpreter.collectGarbage();
    const result = try interpreter.run(
        \\console.log(zoned.toPlainDate().day, typeof describe().era.get, Object.prototype.toString.call(date));
    );
    defer result.deinit();
    try testing.expectEqualStrings("29 function [object Temporal.PlainDate]\n", output.written());
}
