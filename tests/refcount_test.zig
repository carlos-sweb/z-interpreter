//! White-box refcount checks for the Phase-1 GC prep (roadmap item 15):
//! object-property overwrite/delete, Map set/delete, and variable
//! reassignment must release the value they displace, not leak it.
//!
//! Each declaration retains one reference in its binding and releases its
//! initializer's owned temporary. These tests count stored owners: the
//! binding plus each property, map key/value or array slot that holds it.
//! `run()` returns one additional owned reference to the final expression;
//! exclude that caller-owned result when measuring stored references.
const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const helpers = @import("helpers.zig");

fn expectObjectRefcount(source: []const u8, expected: usize) !void {
    try helpers.runAndCheck(source, expected, struct {
        fn check(want: usize, result: helpers.Result) !void {
            try testing.expect(result.value == .object);
            try testing.expectEqual(want + 1, result.value.object.refCount());
        }
    }.check);
}

test "plain object declaration baseline is one stored reference" {
    try expectObjectRefcount("let probe = {}; probe;", 1);
}

test "overwriting an object property releases the value it displaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let obj = {};
        \\obj.a = probe; // +1 (property), now 2
        \\obj.a = {};    // displaces probe -- should release back to 1
        \\probe;
    , 1);
}

test "deleting an object property releases the deleted value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let obj = {};
        \\obj.a = probe; // +1 (property), now 2
        \\delete obj.a;  // should release back to 1
        \\probe;
    , 1);
}

test "Map.set on an existing key releases the displaced value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set('k', probe); // +1 (map value), now 2
        \\m.set('k', {});    // displaces probe -- should release back to 1
        \\probe;
    , 1);
}

test "Map.set on an existing key does not re-retain the key (put() leaves it in place)" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set(probe, 1); // new key -- +1 (map key), now 2
        \\m.set(probe, 2); // same key -- must NOT retain again, stays 2
        \\probe;
    , 2);
}

test "Map.delete releases the deleted value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set('k', probe); // +1 (map value), now 2
        \\m.delete('k');     // should release back to 1
        \\probe;
    , 1);
}

test "reassigning a variable releases the value it held" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let x = probe; // +1 (x's binding), now 2
        \\x = {};         // displaces probe from x -- should release back to 1
        \\probe;
    , 1);
}

test "copyWithin (non-overlapping) releases the old destination occupant and retains the new one" {
    // dest [2,4) and source [0,2) are disjoint -- the baseline sanity
    // check before the overlap tests below.
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA); // idx0, idx1
        \\arr.push(probeB); arr.push(probeB); // idx2, idx3
        \\arr.copyWithin(2, 0, 2); // dest [2,4) <- source [0,2): now all 4 slots hold A
        \\probeA; // occupies all 4 slots now: 1(binding)+4 = 5
    , 5);
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA);
        \\arr.push(probeB); arr.push(probeB);
        \\arr.copyWithin(2, 0, 2);
        \\probeB; // no longer occupies any slot: back to the bare baseline, 1
    , 1);
}

test "copyWithin (overlapping, target inside the source range) still balances retain/release per slot" {
    // The exact shape a naive per-slot-interleaved release/retain would
    // get wrong: target(1) falls INSIDE source [0,2), so slot 1 is both
    // "still-unread source data" and "about to be overwritten
    // destination" at once. See the ordering comment on arrayCopyWithin
    // in array_builtins.zig.
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA); // idx0, idx1
        \\arr.push(probeB); arr.push(probeB); // idx2, idx3
        \\arr.copyWithin(1, 0, 2); // dest [1,3) <- source [0,2): idx1 stays A, idx2 becomes A (was B)
        \\probeA; // now occupies 3 slots instead of 2: 1(binding)+3 = 4
    , 4);
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA);
        \\arr.push(probeB); arr.push(probeB);
        \\arr.copyWithin(1, 0, 2);
        \\probeB; // now occupies 1 slot instead of 2: 1(binding)+1 = 2
    , 2);
}

test "concat retains each element once per occurrence in the merged result" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let arr = [probe];
        \\const merged = arr.concat(probe, [probe]);
        \\// The temporary argument array is released when concat returns.
        \\// Remaining owners: probe's binding, arr's slot and merged's 3 slots.
        \\probe;
    , 5);
}
