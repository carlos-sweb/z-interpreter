const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");

fn observedOptions(entries: []const u8) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var interpreter = try zinterpreter.Interpreter.init(testing.allocator, &output.writer);
    defer interpreter.deinit();

    const result = try interpreter.run(entries);
    defer result.deinit();
    try testing.expect(result == .string);
    return try testing.allocator.dupe(u8, result.string.value.data);
}

test "PlainDate since reads all difference settings before validation" {
    const actual = try observedOptions(
        "let log = []; let options = {};" ++
            "for (let pair of [[\"largestUnit\", \"hour\"], [\"roundingIncrement\", 1], [\"roundingMode\", \"halfFloor\"], [\"smallestUnit\", \"nanosecond\"]])" ++
            " Object.defineProperty(options, pair[0], { get() { log.push(pair[0]); return pair[1]; } });" ++
            "try { new Temporal.PlainDate(2025, 8, 14).since(new Temporal.PlainDate(2025, 3, 14), options); } catch (e) {} log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("largestUnit,roundingIncrement,roundingMode,smallestUnit", actual);
}

test "PlainDateTime round reads all settings before validation" {
    const actual = try observedOptions(
        "let log = []; let options = {};" ++
            "for (let pair of [[\"roundingIncrement\", 25], [\"roundingMode\", \"expand\"], [\"smallestUnit\", \"hour\"]])" ++
            " Object.defineProperty(options, pair[0], { get() { log.push(pair[0]); return pair[1]; } });" ++
            "try { new Temporal.PlainDateTime(2025, 8, 14, 12).round(options); } catch (e) {} log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("roundingIncrement,roundingMode,smallestUnit", actual);
}

test "PlainTime until reads difference settings in canonical order" {
    const actual = try observedOptions(
        "let log = []; let options = {};" ++
            "for (let pair of [[\"largestUnit\", \"hour\"], [\"roundingIncrement\", 1], [\"roundingMode\", \"trunc\"], [\"smallestUnit\", \"nanosecond\"]])" ++
            " Object.defineProperty(options, pair[0], { get() { log.push(pair[0]); return pair[1]; } });" ++
            "new Temporal.PlainTime(12).until(new Temporal.PlainTime(13), options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("largestUnit,roundingIncrement,roundingMode,smallestUnit", actual);
}

test "PlainYearMonth with reads fields before overflow" {
    const actual = try observedOptions(
        "let log = []; let fields = {}; let options = {};" ++
            "Object.defineProperty(fields, 'calendar', { get() { log.push('calendar'); } });" ++
            "Object.defineProperty(fields, 'timeZone', { get() { log.push('timeZone'); } });" ++
            "Object.defineProperty(fields, 'month', { get() { log.push('month'); return 6; } });" ++
            "Object.defineProperty(fields, 'monthCode', { get() { log.push('monthCode'); return 'M06'; } });" ++
            "Object.defineProperty(fields, 'year', { get() { log.push('year'); return 2001; } });" ++
            "Object.defineProperty(options, 'overflow', { get() { log.push('overflow'); return 'constrain'; } });" ++
            "new Temporal.PlainYearMonth(2000, 5).with(fields, options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("calendar,timeZone,month,monthCode,year,overflow", actual);
}

test "Duration round retains pre-Phase-A option access order" {
    const actual = try observedOptions(
        "let log = []; let options = { smallestUnit: \"minute\" };" ++
            "for (let pair of [[\"largestUnit\", \"hour\"], [\"roundingIncrement\", 1], [\"roundingMode\", \"halfExpand\"]])" ++
            " Object.defineProperty(options, pair[0], { get() { log.push(pair[0]); return pair[1]; } });" ++
            "new Temporal.Duration(0, 0, 0, 0, 1).round(options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("", actual);
}

test "Instant round retains pre-Phase-A option access order" {
    const actual = try observedOptions(
        "let log = []; let options = { smallestUnit: \"second\" };" ++
            "for (let pair of [[\"largestUnit\", \"minute\"], [\"roundingIncrement\", 1], [\"roundingMode\", \"halfExpand\"]])" ++
            " Object.defineProperty(options, pair[0], { get() { log.push(pair[0]); return pair[1]; } });" ++
            "new Temporal.Instant(0n).round(options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("", actual);
}

test "PlainDate direct property bags retain monthCode through from and arithmetic" {
    const actual = try observedOptions(
        "let date = Temporal.PlainDate.from({ year: 2021, monthCode: 'M07', day: 16 });" ++
            "date = date.add({ days: 1 }).subtract({ days: 1 }).with({ monthCode: 'M02' });" ++
            "let invalid; try { Temporal.PlainDate.from({ year: 2000, monthCode: 'M13', day: 1 }); } catch (e) { invalid = e.name; }" ++
            "let comparison = Temporal.PlainDate.compare({ year: 2021, monthCode: 'M02', day: 16, calendar: 'ISO8601' }, date);" ++
            "date.toString() + ',' + invalid + ',' + comparison;",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("2021-02-16,RangeError,0", actual);
}

test "Duration.compare reads relativeTo after both arguments" {
    const actual = try observedOptions(
        "let log = []; let options = new Proxy({ relativeTo: undefined }, { get(target, key) { log.push(key); return target[key]; } });" ++
            "Temporal.Duration.compare({ days: 2 }, { days: 1 }, options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("relativeTo", actual);
}

test "Duration.compare rejects primitive options after duration coercion" {
    const actual = try observedOptions(
        "try { Temporal.Duration.compare({ hours: 1 }, { hours: 1 }, null); 'no error'; } catch (e) { e.name; }",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("TypeError", actual);
}
