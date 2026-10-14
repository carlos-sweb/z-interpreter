//! `Temporal.*` end-to-end through the interpreter (z-temporal wiring --
//! see `/home/sweb/z-test262/REPORT.md`'s analysis: this was the single
//! largest FAIL bucket, 0% pass, because the already-built z-temporal
//! library was never connected). Same discipline as date_test.zig: real
//! JS scripts through the whole engine, not just the Zig glue in
//! isolation. ZonedDateTime arithmetic and locale formatting are not
//! exposed by the interpreter bindings yet.
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

test "Temporal string input and partial field updates use the v0.1.0 API" {
    try helpers.expectStdout(
        \\console.log(Temporal.PlainTime.from('12:34:56').with({ minute: 1 }).toString());
        \\console.log(Temporal.PlainDateTime.from('2024-02-29T12:34:56').with({ hour: 6 }).toString());
        \\console.log(Temporal.PlainYearMonth.from('2024-02').with({ month: 3 }).toString());
        \\console.log(Temporal.PlainMonthDay.from('02-29').with({ day: 28 }).toString());
        \\console.log(Temporal.Duration.from('PT1H').with({ minutes: 30 }).toString());
        \\console.log(Temporal.Instant.from('2024-01-01T00:00:00Z').toString());
    , "12:01:56\n2024-02-29T06:34:56\n2024-03\n02-28\nPT1H30M\n2024-01-01T00:00:00Z\n");
}

test "Temporal rounding modes and calendar-relative Duration options" {
    try helpers.expectStdout(
        \\const time = new Temporal.PlainTime(12, 30);
        \\console.log(time.round({ smallestUnit: 'hour' }).toString());
        \\console.log(time.round({ smallestUnit: 'hour', roundingMode: 'halfFloor' }).toString());
        \\const duration = Temporal.Duration.from({ hours: 1, minutes: 30 });
        \\console.log(duration.round({ smallestUnit: 'hour' }).toString());
        \\console.log(duration.total('minutes'));
        \\console.log(Temporal.Duration.from({ months: 1 }).total({ unit: 'days', relativeTo: '2024-02-01' }));
        \\console.log(Temporal.Duration.compare({ months: 1 }, { days: 29 }, { relativeTo: '2024-02-01' }));
    , "13:00:00\n12:00:00\nPT2H\n90\n29\n0\n");
}

test "Duration Number components preserve integral values outside i64" {
    try helpers.expectNumber("Temporal.Duration.from({ nanoseconds: 100000000000000000000 }).nanoseconds;", 1e20);
    try helpers.expectNumber("new Temporal.Duration(0, 0, 0, 0, 0, 0, 0, 0, 0, 100000000000000000000).with({ nanoseconds: 100000000000000000000 }).nanoseconds;", 1e20);
    try helpers.expectStdout(
        \\try { Temporal.Duration.from({ seconds: 0.5 }); } catch (e) { console.log(e.name); }
        \\try { Temporal.Duration.from({ hours: 1, minutes: -1 }); } catch (e) { console.log(e.name); }
        \\try { Temporal.Duration.from({}); } catch (e) { console.log(e.name); }
        \\try { Temporal.PlainTime.from({}); } catch (e) { console.log(e.name); }
    , "RangeError\nRangeError\nTypeError\nTypeError\n");
}

test "Temporal week number and constructor versus from overflow" {
    try helpers.expectStdout(
        \\console.log(Temporal.PlainDate.from('2024-02-29').weekOfYear);
        \\console.log(Temporal.PlainDate.from({ year: 2024, month: 2, day: 30 }).toString());
        \\try { Temporal.PlainDate.from({ year: 2024, month: 2, day: 30 }, { overflow: 'reject' }); } catch (e) { console.log(e.name); }
        \\try { new Temporal.PlainDate(2024, 2, 30); } catch (e) { console.log(e.name); }
    , "9\n2024-02-29\nRangeError\nRangeError\n");
}

test "ZonedDateTime construction and string parsing retain the zone" {
    try helpers.expectStdout(
        \\const zoned = Temporal.ZonedDateTime.from('2024-01-01T00:00:00+00:00[UTC]');
        \\console.log(zoned.toString(), zoned.monthCode, zoned.weekOfYear);
        \\console.log(new Temporal.ZonedDateTime(0n, 'UTC').toString());
        \\console.log(Temporal.ZonedDateTime.from({ year: 2024, month: 1, day: 1, timeZone: 'UTC' }).toString());
    , "2024-01-01T00:00:00+00:00[UTC] M01 1\n1970-01-01T00:00:00+00:00[UTC]\n2024-01-01T00:00:00+00:00[UTC]\n");
}
