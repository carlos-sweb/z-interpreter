//! `Temporal.*` end-to-end through the interpreter (z-temporal wiring --
//! see `/home/sweb/z-test262/REPORT.md`'s analysis: this was the single
//! largest FAIL bucket, 0% pass, because the already-built z-temporal
//! library was never connected). Same discipline as date_test.zig: real
//! JS scripts through the whole engine, not just the Zig glue in
//! isolation. ZonedDateTime and I/O-dependent `Temporal.now.*` beyond
//! `.instant()` are deliberately not wired (see temporal_builtins.zig's
//! top doc comment) -- no tests for them here.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "Temporal global exists with all 7 wired types" {
    try helpers.expectStdout(
        \\console.log(
        \\  typeof Temporal, typeof Temporal.PlainDate, typeof Temporal.PlainTime,
        \\  typeof Temporal.PlainDateTime, typeof Temporal.PlainYearMonth,
        \\  typeof Temporal.PlainMonthDay, typeof Temporal.Instant,
        \\  typeof Temporal.Duration, typeof Temporal.now.instant
        \\);
    , "object function function function function function function function function\n");
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

test "Temporal.now.instant returns a real, current-ish time" {
    try helpers.expectStdout(
        \\console.log(Temporal.now.instant().epochMilliseconds > 1700000000000);
    , "true\n");
}

test "console.log renders a Temporal instance with its kind name and ISO string" {
    try helpers.expectStdout(
        \\console.log(new Temporal.PlainDate(2024, 6, 15));
    , "Temporal.PlainDate 2024-06-15\n");
}
