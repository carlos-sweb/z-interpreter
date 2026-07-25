//! Roadmap item 18 (BigInt), phase 3: literal evaluation + typeof + GC
//! lifecycle + property/proto access. Arithmetic/coercion (phase 4) and
//! BigInt() global/prototype methods (phase 5) are NOT covered here yet
//! -- see the durable plan for the full 7-phase breakdown.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "a bigint literal evaluates to a real bigint value, typeof is \"bigint\"" {
    try helpers.runAndCheck("123456789012345678901234567890n;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .bigint);
        }
    }.check);
    try helpers.expectStdout("console.log(typeof 123n);", "bigint\n");
}

test "hex/octal/binary bigint literals and underscore separators parse correctly" {
    try helpers.expectStdout("console.log(typeof 0xFFn, typeof 0o17n, typeof 0b101n, typeof 1_000n);", "bigint bigint bigint bigint\n");
}

test "console.log renders a bigint with a trailing n; template-literal ToString does not" {
    try helpers.expectStdout("console.log(123n);", "123n\n");
    try helpers.expectStdout("console.log(`${123n}`);", "123\n");
}

test "property access on a bigint returns undefined (no prototype methods wired yet -- phase 5)" {
    try helpers.expectStdout("console.log(123n.toString);", "undefined\n");
}
