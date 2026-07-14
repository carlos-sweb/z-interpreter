const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "arithmetic" {
    try helpers.expectNumber("1 + 2 * 3;", 7);
    try helpers.expectNumber("2 ** 10;", 1024);
    try helpers.expectNumber("10 % 3;", 1);
}

test "string concatenation via +" {
    try helpers.runAndCheck("'a' + 1;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("a1", r.value.string.value.data);
        }
    }.check);
}

test "comparisons" {
    try helpers.runAndCheck("1 < 2;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
}

test "strict vs loose equality" {
    try helpers.runAndCheck("1 === '1';", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == false);
        }
    }.check);
    try helpers.runAndCheck("1 == '1';", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
    try helpers.runAndCheck("null == undefined;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
    try helpers.runAndCheck("true == 1;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
}

test "logical operators" {
    try helpers.expectNumber("0 || 5;", 5);
    try helpers.expectNumber("1 && 5;", 5);
    try helpers.runAndCheck("null ?? 'd';", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("d", r.value.string.value.data);
        }
    }.check);
}

test "logical short-circuit actually short-circuits (side effect proof)" {
    try helpers.runAndCheck(
        "let calls = 0; function bump() { calls = calls + 1; return 1; } true || bump(); calls;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expect(r.value.number == 0);
            }
        }.check,
    );
    try helpers.runAndCheck(
        "let calls = 0; function bump() { calls = calls + 1; return 1; } false && bump(); calls;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expect(r.value.number == 0);
            }
        }.check,
    );
}

test "compound and logical assignment" {
    try helpers.expectNumber("let x = 1; x += 2; x;", 3);
    try helpers.expectNumber("let x = null; x ??= 5; x;", 5);
    try helpers.expectNumber("let x = 0; x ||= 7; x;", 7);
}
