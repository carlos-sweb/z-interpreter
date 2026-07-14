const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "number, boolean, null literals" {
    try helpers.expectNumber("42;", 42);
    try helpers.runAndCheck("true;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .boolean);
            try testing.expect(r.value.boolean == true);
        }
    }.check);
    try helpers.runAndCheck("null;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .@"null");
        }
    }.check);
}

test "string literal" {
    try helpers.runAndCheck("'hello';", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .string);
            try testing.expectEqualStrings("hello", r.value.string.value.data);
        }
    }.check);
}

test "template literal with substitutions" {
    try helpers.runAndCheck("const x = 2; `a${x + 1}b`;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .string);
            try testing.expectEqualStrings("a3b", r.value.string.value.data);
        }
    }.check);
}

test "array literal with elision holes" {
    try helpers.runAndCheck("[1, , 3];", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .array);
            try testing.expectEqual(@as(usize, 3), r.value.array.value.length());
            try testing.expect(r.value.array.value.get(1) == .@"undefined");
        }
    }.check);
}

test "array literal with spread" {
    try helpers.runAndCheck("const a = [1, 2]; [...a, 3];", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqual(@as(usize, 3), r.value.array.value.length());
            try testing.expect(r.value.array.value.get(2).number == 3);
        }
    }.check);
}

test "object literal with shorthand and spread" {
    try helpers.runAndCheck("const x = 1; const base = {x}; ({...base, y: 2});", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .object);
            try testing.expect(r.value.object.value.get("x").?.number == 1);
            try testing.expect(r.value.object.value.get("y").?.number == 2);
        }
    }.check);
}

test "regex literal evaluates without erroring (not implemented, deferred)" {
    try helpers.expectNotImplemented("/abc/g;");
}
