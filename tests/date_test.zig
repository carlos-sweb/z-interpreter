const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

fn expectString(source: []const u8, expected: []const u8) !void {
    try helpers.runAndCheck(source, expected, struct {
        fn check(want: []const u8, r: helpers.Result) !void {
            try testing.expect(r.value == .string);
            try testing.expectEqualStrings(want, r.value.string.value.data);
        }
    }.check);
}

test "new Date(ms) round-trips through getTime" {
    try helpers.expectNumber("new Date(0).getTime();", 0);
    try helpers.expectNumber("new Date(86400000).getTime();", 86400000);
}

test "getters over a known timestamp (local zone defaults to UTC)" {
    // 2020-01-02T03:04:05.000Z == 1577934245000 ms
    try helpers.expectNumber("new Date(1577934245000).getFullYear();", 2020);
    try helpers.expectNumber("new Date(1577934245000).getMonth();", 0); // January is 0
    try helpers.expectNumber("new Date(1577934245000).getDate();", 2);
    try helpers.expectNumber("new Date(1577934245000).getHours();", 3);
    try helpers.expectNumber("new Date(1577934245000).getMinutes();", 4);
    try helpers.expectNumber("new Date(1577934245000).getSeconds();", 5);
    try helpers.expectNumber("new Date(86400000).getDay();", 5); // 1970-01-02 was a Friday
}

test "new Date(string) parses ISO 8601" {
    try helpers.expectNumber("new Date('2020-01-02T03:04:05.000Z').getTime();", 1577934245000);
}

test "toISOString" {
    try expectString("new Date(0).toISOString();", "1970-01-01T00:00:00.000Z");
}

test "typeof and Number() coercion" {
    try expectString("typeof new Date(0);", "object");
    try helpers.expectNumber("Number(new Date(5));", 5);
}

test "JSON.stringify of a Date is its quoted ISO string" {
    try expectString("JSON.stringify(new Date(0));", "\"1970-01-01T00:00:00.000Z\"");
}

test "new Date() with no args is 'now' (sanity: later than 2020)" {
    try helpers.runAndCheck("new Date().getTime() > 1577934245000;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
}

test "console.log renders a Date as ISO" {
    try helpers.expectStdout("console.log(new Date(0));", "1970-01-01T00:00:00.000Z\n");
}

test "Date methods on a non-date receiver are a TypeError" {
    try helpers.runAndCheck("var f = new Date(0).getTime; var r; try { f(); } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "multi-arg constructor (local == UTC in this runtime)" {
    // new Date(2026, 6, 20, 12, 30, 15, 500) -- month is 0-based (July).
    try helpers.expectNumber("new Date(2026, 6, 20, 12, 30, 15, 500).getUTCFullYear();", 2026);
    try helpers.expectNumber("new Date(2026, 6, 20).getUTCMonth();", 6);
    try helpers.expectNumber("new Date(2026, 6, 20).getUTCDate();", 20);
    try helpers.expectNumber("new Date(2026, 6, 20, 12, 30, 15, 500).getUTCMilliseconds();", 500);
}

test "UTC getters and getTimezoneOffset" {
    try helpers.expectNumber("new Date(1577934245000).getUTCHours();", 3);
    try helpers.expectNumber("new Date(1577934245000).getMilliseconds();", 0);
    try helpers.expectNumber("new Date(0).getTimezoneOffset();", 0);
}

test "setters mutate in place and return the new time" {
    try helpers.expectNumber("var d = new Date(0); d.setUTCFullYear(2000); d.getUTCFullYear();", 2000);
    try helpers.expectNumber("var d = new Date(0); d.setTime(86400000); d.getTime();", 86400000);
    try helpers.expectNumber("new Date(0).setUTCMonth(11);", 28857600000); // 1970-12-01
    // Chained hours/minutes/seconds via the optional trailing args.
    try helpers.expectNumber("var d = new Date(0); d.setUTCHours(1, 2, 3, 4); d.getUTCMinutes();", 2);
}

test "static methods: now, parse, UTC" {
    try expectString("typeof Date.now();", "number");
    try helpers.expectNumber("Date.UTC(2020, 0, 2, 3, 4, 5);", 1577934245000);
    try helpers.expectNumber("Date.parse('2020-01-02T03:04:05.000Z');", 1577934245000);
}

test "valueOf, and String()/template coercion use toString (not ISO)" {
    try helpers.expectNumber("new Date(5).valueOf();", 5);
    // toString format begins with the weekday; enough to prove it's not ISO.
    try helpers.expectStdout("console.log(String(new Date(0)).slice(0, 3));", "Thu\n");
    try helpers.expectStdout("console.log(`${new Date(0)}`.slice(0, 3));", "Thu\n");
}

test "Invalid Date: getTime is NaN, toString is 'Invalid Date', toJSON is null" {
    try helpers.runAndCheck("Number.isNaN(new Date(NaN).getTime());", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
    try helpers.runAndCheck("Number.isNaN(new Date('nope').getTime());", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
    try expectString("String(new Date(NaN));", "Invalid Date");
    try helpers.runAndCheck("new Date(NaN).toJSON();", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .@"null");
        }
    }.check);
}

test "out-of-range and NaN inputs don't crash (Invalid Date)" {
    try helpers.runAndCheck("Number.isNaN(new Date(1e300).getTime());", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
    try helpers.runAndCheck("Number.isNaN(new Date(0).setHours(Infinity));", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
}
