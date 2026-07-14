const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "closures + loops + console output together" {
    try helpers.runAndCheck(
        \\function makeAccumulator() {
        \\  let total = 0;
        \\  return function(n) {
        \\    for (let i = 0; i < n; i = i + 1) {
        \\      total = total + i;
        \\    }
        \\    return total;
        \\  };
        \\}
        \\const acc = makeAccumulator();
        \\console.log("first:", acc(3));
        \\console.log("second:", acc(3));
        \\acc(0);
    ,
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expectEqualStrings("first: 3\nsecond: 6\n", r.stdout);
                try testing.expect(r.value.number == 6);
            }
        }.check,
    );
}

test "Hello World, the actual deliverable" {
    try helpers.expectStdout("console.log(\"Hello World\");", "Hello World\n");
}
