const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "number, boolean, null literals" {
    try helpers.expectNumber("42;", 42);
    try helpers.runAndCheck("true;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.isBool());
            try testing.expect(r.value.asBool() == true);
        }
    }.check);
    try helpers.runAndCheck("null;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.isNull());
        }
    }.check);
}

test "string literal" {
    try helpers.runAndCheck("'hello';", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.isString());
            try testing.expectEqualStrings("hello", r.value.asString().value.data);
        }
    }.check);
}

test "template literal with substitutions" {
    try helpers.runAndCheck("const x = 2; `a${x + 1}b`;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.isString());
            try testing.expectEqualStrings("a3b", r.value.asString().value.data);
        }
    }.check);
}

test "array literal with elision holes" {
    try helpers.runAndCheck("[1, , 3];", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.isArray());
            try testing.expectEqual(@as(usize, 3), r.value.asArray().value.length());
            try testing.expect(r.value.asArray().value.get(1).isUndefined());
        }
    }.check);
}

test "array literal with spread" {
    try helpers.runAndCheck("const a = [1, 2]; [...a, 3];", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqual(@as(usize, 3), r.value.asArray().value.length());
            try testing.expect(r.value.asArray().value.get(2).asNumber() == 3);
        }
    }.check);
}

test "object literal with shorthand and spread" {
    try helpers.runAndCheck("const x = 1; const base = {x}; ({...base, y: 2});", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.isObject());
            try testing.expect(r.value.asObject().value.get("x").?.asNumber() == 1);
            try testing.expect(r.value.asObject().value.get("y").?.asNumber() == 2);
        }
    }.check);
}

test "regex literal evaluates to a RegExp value" {
    try helpers.expectStdout("const re = /abc/gi; console.log(re.source, re.flags, re.global);", "abc gi true\n");
}
