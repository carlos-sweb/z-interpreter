const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "console.log(\"Hello World\")" {
    try helpers.expectStdout("console.log(\"Hello World\");", "Hello World\n");
}

test "console.log with multiple arguments, space-separated" {
    try helpers.expectStdout("console.log(1, 'a', true);", "1 a true\n");
}

test "console.log rendering of arrays and objects is legible, not spec-exact" {
    try helpers.expectStdout("console.log([1, 2, 3]);", "[1, 2, 3]\n");
    try helpers.expectStdout("console.log({a: 1});", "{ a: 1 }\n");
}

test "console.log(undefined) / console.log(null)" {
    try helpers.expectStdout("console.log(undefined);", "undefined\n");
    try helpers.expectStdout("console.log(null);", "null\n");
}
