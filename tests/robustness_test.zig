//! Regressions for latent crashes in Array/String methods: out-of-range /
//! non-finite numeric arguments (@intFromFloat panics) and callbacks that
//! mutate the array mid-iteration (dangling cached slice). Node-verified.
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "non-finite numeric args don't panic (saturate / throw like real JS)" {
    // repeat: negative or infinite count is a RangeError, not a crash.
    try helpers.expectUncaught("'x'.repeat(Infinity);", .range_error, "Invalid count value: inf");
    try helpers.expectUncaught("'x'.repeat(-1);", .range_error, "Invalid count value: -1");
    // padStart maxLength: NaN/-Infinity coerce to 0 -> no padding.
    try helpers.expectStdout("console.log('abc'.padStart(NaN,'d'), 'abc'.padStart(-Infinity,'d'));", "abc abc\n");
    // fromCodePoint out of range / non-integer -> RangeError.
    try helpers.expectUncaught("String.fromCodePoint(0x110000);", .range_error, "Invalid code point 1114112");
    try helpers.expectUncaught("String.fromCodePoint(1.5);", .range_error, "Invalid code point 1.5");
    // fromCharCode wraps (ToUint16); NaN -> 0.
    try helpers.expectNumber("String.fromCharCode(65, NaN, 66).length;", 3);
    // Array.prototype.at with NaN / out-of-range index.
    try helpers.expectNumber("[10,20,30].at(NaN);", 10);
    try helpers.runAndCheck("[1,2,3].at(9);", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value == .@"undefined");
        }
    }.check);
    // flat(Infinity) fully flattens without panicking.
    try helpers.expectStdout("console.log([1,[2,[3,[4]]]].flat(Infinity).join(','));", "1,2,3,4\n");
}

test "callback that truncates the array mid-iteration doesn't corrupt memory" {
    // forEach visits only still-present indices (len captured once).
    try helpers.expectNumber(
        \\let n = 0; [1,2,3,4,5].forEach(function(v,i,a){ a.length = 3; n++; }); n;
    , 3);
    // map keeps the originally-observed length, leaving holes for removed
    // indices.
    try helpers.expectStdout(
        \\const r = [1,2,3,4,5].map(function(v,i,a){ a.length = 2; return 1; });
        \\console.log(r.length, r[2]);
    , "5 undefined\n");
    // reduce over a truncated array doesn't read freed elements.
    try helpers.expectNumber(
        \\[1,2,3,4,5].reduce(function(acc,v,i,a){ if (i===0) a.length = 2; return acc+v; }, 0);
    , 3); // 1 + 2 (indices 2..4 removed)
}
