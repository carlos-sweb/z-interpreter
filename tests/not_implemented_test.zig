const std = @import("std");
const helpers = @import("helpers.zig");

test "explicitly deferred constructs raise error.NotImplemented, not a crash" {
    try helpers.expectNotImplemented("with ({}) { 1; }");
    try helpers.expectNotImplemented("for (const x in {a:1}) { x; }");
    try helpers.expectNotImplemented("for (const x of [1,2]) { x; }");
}
