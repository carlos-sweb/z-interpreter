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

test "Duration round reads B2 options before validation" {
    const actual = try observedOptions(
        "let log = []; let options = { smallestUnit: \"minute\" };" ++
            "for (let pair of [[\"largestUnit\", \"hour\"], [\"roundingIncrement\", 1], [\"roundingMode\", \"halfExpand\"]])" ++
            " Object.defineProperty(options, pair[0], { get() { log.push(pair[0]); return pair[1]; } });" ++
            "new Temporal.Duration(0, 0, 0, 0, 1).round(options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("largestUnit,roundingIncrement,roundingMode", actual);
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

test "Duration round reads its options in test262 order" {
    const actual = try observedOptions(
        "let log = []; let values = { largestUnit: 'hour', relativeTo: undefined, roundingIncrement: 1, roundingMode: 'halfExpand', smallestUnit: 'minute' };" ++
            "let options = new Proxy(values, { get(target, key) { log.push(key); return target[key]; } });" ++
            "new Temporal.Duration(0, 0, 0, 1).round(options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("largestUnit,relativeTo,roundingIncrement,roundingMode,smallestUnit", actual);
}

test "Duration round rejects primitive and omitted options" {
    const actual = try observedOptions(
        "let d = new Temporal.Duration(0, 0, 0, 1); let a; let b; try { d.round(null); } catch (e) { a = e.name; } try { d.round(); } catch (e) { b = e.name; } a + ',' + b;",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("TypeError,TypeError", actual);
}

test "Duration round reads relativeTo for calendar smallest units" {
    const actual = try observedOptions(
        "let log = []; let values = { largestUnit: undefined, relativeTo: undefined, roundingIncrement: 1, roundingMode: 'halfExpand', smallestUnit: 'day' };" ++
            "let options = new Proxy(values, { get(target, key) { log.push(key); return target[key]; } });" ++
            "try { new Temporal.Duration(0, 0, 0, 1).round(options); } catch (e) {} log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("largestUnit,relativeTo,roundingIncrement,roundingMode,smallestUnit", actual);
}

test "Duration round reads relativeTo for non-calendar smallest units" {
    const actual = try observedOptions(
        "let log = []; let values = { largestUnit: undefined, relativeTo: undefined, roundingIncrement: 1, roundingMode: 'halfExpand', smallestUnit: 'hour' };" ++
            "let options = new Proxy(values, { get(target, key) { log.push(key); return target[key]; } });" ++
            "new Temporal.Duration(0, 0, 0, 0, 1).round(options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("largestUnit,relativeTo,roundingIncrement,roundingMode,smallestUnit", actual);
}

test "Duration round without units throws RangeError" {
    const actual = try observedOptions(
        "try { new Temporal.Duration(0, 0, 0, 0, 1).round({}); 'no error'; } catch (e) { e.name; }",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("RangeError", actual);
}

test "Duration total reads relativeTo before unit" {
    const actual = try observedOptions(
        "let log = []; let values = { relativeTo: undefined, unit: 'hour' };" ++
            "let options = new Proxy(values, { get(target, key) { log.push(key); return target[key]; } });" ++
            "new Temporal.Duration(0, 0, 0, 0, 1).total(options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("relativeTo,unit", actual);
}

test "Duration total validates required and converted unit values" {
    const actual = try observedOptions(
        "let d = new Temporal.Duration(0, 0, 0, 0, 1); let a, b, c;" ++
            "try { d.total({}); } catch (e) { a = e.name; }" ++
            "try { d.total({ unit: 2 }); } catch (e) { b = e.name; }" ++
            "try { d.total({ unit: Symbol() }); } catch (e) { c = e.name; } a + ',' + b + ',' + c;",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("RangeError,RangeError,TypeError", actual);
}

test "Duration total rejects calendar unit without relativeTo after reads" {
    const actual = try observedOptions(
        "try { new Temporal.Duration(1).total({ relativeTo: undefined, unit: 'week' }); 'no error'; } catch (e) { e.name; }",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("RangeError", actual);
}

test "Duration with reads proxy fields in alphabetical order" {
    const actual = try observedOptions(
        "let log = []; let values = { days: 1, hours: 1, microseconds: 1, milliseconds: 1, minutes: 1, months: 1, nanoseconds: 1, seconds: 1, weeks: 1, years: 1 };" ++
            "let fields = new Proxy(values, { get(target, key) { log.push(key); return target[key]; } });" ++
            "new Temporal.Duration().with(fields); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("days,hours,microseconds,milliseconds,minutes,months,nanoseconds,seconds,weeks,years", actual);
}

test "Duration with propagates field getter errors" {
    const actual = try observedOptions(
        "let fields = { get days() { throw new Error('sentinel'); } }; try { new Temporal.Duration().with(fields); } catch (e) { e.name + ',' + e.message; }",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("Error,sentinel", actual);
}

test "Duration with rejects primitive field bags" {
    const actual = try observedOptions(
        "let d = new Temporal.Duration(); let a; let b; try { d.with(null); } catch (e) { a = e.name; } try { d.with(1); } catch (e) { b = e.name; } a + ',' + b;",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("TypeError,TypeError", actual);
}

test "Duration from reads proxy fields in alphabetical order" {
    const actual = try observedOptions(
        "let log = []; let values = { days: 1, hours: 1, microseconds: 1, milliseconds: 1, minutes: 1, months: 1, nanoseconds: 1, seconds: 1, weeks: 1, years: 1 };" ++
            "let item = new Proxy(values, { get(target, key) { log.push(key); return target[key]; } });" ++
            "Temporal.Duration.from(item); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("days,hours,microseconds,milliseconds,minutes,months,nanoseconds,seconds,weeks,years", actual);
}

test "Duration from propagates field getter errors" {
    const actual = try observedOptions(
        "let item = { get days() { throw new Error('sentinel'); } }; try { Temporal.Duration.from(item); } catch (e) { e.name + ',' + e.message; }",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("Error,sentinel", actual);
}

test "Duration from rejects primitive duration-like values" {
    const actual = try observedOptions(
        "try { Temporal.Duration.from(1); 'no error'; } catch (e) { e.name; }",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("TypeError", actual);
}

test "ZonedDateTime from reads proxy fields before validation and options" {
    const actual = try observedOptions(
        "let log = []; let values = { calendar: 'iso8601', day: 2, hour: 6, microsecond: 654, millisecond: 987, minute: 54, month: 5, monthCode: 'M05', nanosecond: 321, offset: '+00:00', second: 32, timeZone: 'UTC', year: 2001 };" ++
            "let item = new Proxy(values, { get(target, key) { log.push(key); return target[key]; } });" ++
            "let options = new Proxy({ disambiguation: 'compatible', offset: 'reject', overflow: 'constrain' }, { get(target, key) { log.push(key); return target[key]; } });" ++
            "Temporal.ZonedDateTime.from(item, options); log.join(',');",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("calendar,day,hour,microsecond,millisecond,minute,month,monthCode,nanosecond,offset,second,timeZone,year,disambiguation,offset,overflow", actual);
}

test "ZonedDateTime from propagates proxy getter errors after earlier fields" {
    const actual = try observedOptions(
        "let item = new Proxy({ calendar: 'iso8601' }, { get(target, key) { if (key === 'day') throw new Error('sentinel'); return target[key]; } });" ++
            "try { Temporal.ZonedDateTime.from(item); } catch (e) { e.name + ',' + e.message; }",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("Error,sentinel", actual);
}

test "ZonedDateTime with accepts a proxy partial bag" {
    const actual = try observedOptions(
        "new Temporal.ZonedDateTime(0n, 'UTC').with(new Proxy({ year: 2001 }, {})).year + '';",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("2001", actual);
}

test "ZonedDateTime until and since accept proxy arguments" {
    const actual = try observedOptions(
        "let base = new Temporal.ZonedDateTime(0n, 'UTC');" ++
            "let other = new Proxy({ year: 1970, month: 1, day: 1, hour: 1, timeZone: 'UTC' }, {});" ++
            "base.until(other).hours + ',' + base.since(other).hours;",
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("1,-1", actual);
}
