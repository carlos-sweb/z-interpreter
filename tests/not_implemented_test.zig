const std = @import("std");
const helpers = @import("helpers.zig");

test "explicitly deferred constructs raise error.NotImplemented, not a crash" {
    try helpers.expectNotImplemented("with ({}) { 1; }");
}
