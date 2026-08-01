//! White-box refcount checks for the Phase-1 GC prep (roadmap item 15):
//! object-property overwrite/delete, Map set/delete, and variable
//! reassignment must release the value they displace, not leak it.
//!
//! Baseline quirk these tests build on: `let x = <fresh value>;` leaves the
//! box at refcount 2, not 1 -- the literal's own creation (count=1) is
//! never separately released once bindPattern's declare-time retain adds a
//! second owner (out of scope for this phase; see the GC plan). Every test
//! below starts from that known baseline and checks the DELTA an
//! overwrite/delete/reassign should apply on top of it, rather than
//! asserting an absolute count in isolation.
const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const helpers = @import("helpers.zig");

fn expectObjectRefcount(source: []const u8, expected: usize) !void {
    try helpers.runAndCheck(source, expected, struct {
        fn check(want: usize, result: helpers.Result) !void {
            try testing.expect(result.value == .object);
            try testing.expectEqual(want, result.value.object.count);
        }
    }.check);
}

test "plain object declaration baseline is refcount 2 (documented quirk)" {
    try expectObjectRefcount("let probe = {}; probe;", 2);
}

test "overwriting an object property releases the value it displaces" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let obj = {};
        \\obj.a = probe; // +1 (property), now 3
        \\obj.a = {};    // displaces probe -- should release back to 2
        \\probe;
    , 2);
}

test "deleting an object property releases the deleted value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let obj = {};
        \\obj.a = probe; // +1 (property), now 3
        \\delete obj.a;  // should release back to 2
        \\probe;
    , 2);
}

test "Map.set on an existing key releases the displaced value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set('k', probe); // +1 (map value), now 3
        \\m.set('k', {});    // displaces probe -- should release back to 2
        \\probe;
    , 2);
}

test "Map.set on an existing key does not re-retain the key (put() leaves it in place)" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set(probe, 1); // new key -- +1 (map key), now 3
        \\m.set(probe, 2); // same key -- must NOT retain again, stays 3
        \\probe;
    , 3);
}

test "Map.delete releases the deleted value" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let m = new Map();
        \\m.set('k', probe); // +1 (map value), now 3
        \\m.delete('k');     // should release back to 2
        \\probe;
    , 2);
}

test "reassigning a variable releases the value it held" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let x = probe; // +1 (x's binding), now 3
        \\x = {};         // displaces probe from x -- should release back to 2
        \\probe;
    , 2);
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
        \\probeA; // occupies all 4 slots now: 2(baseline)+4 = 6
    , 6);
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA);
        \\arr.push(probeB); arr.push(probeB);
        \\arr.copyWithin(2, 0, 2);
        \\probeB; // no longer occupies any slot: back to the bare baseline, 2
    , 2);
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
        \\probeA; // now occupies 3 slots instead of 2: 2(baseline)+3 = 5
    , 5);
    try expectObjectRefcount(
        \\let probeA = {};
        \\let probeB = {};
        \\let arr = [];
        \\arr.push(probeA); arr.push(probeA);
        \\arr.push(probeB); arr.push(probeB);
        \\arr.copyWithin(1, 0, 2);
        \\probeB; // now occupies 1 slot instead of 2: 2(baseline)+1 = 3
    , 3);
}

test "concat retains each element once per occurrence in the merged result" {
    try expectObjectRefcount(
        \\let probe = {};
        \\let arr = [probe];       // array-literal element -- +1, now 3
        \\const merged = arr.concat(probe, [probe]);
        \\// Evaluating the `[probe]` argument is its OWN array-literal
        \\// construction -- +1 (now 4) BEFORE concat() even runs. concat()
        \\// then builds a brand new array with 3 elements (arr's own probe,
        \\// the loose probe, and the [probe] arg's probe), each retained
        \\// once as it's copied into that new result -- +3 (now 7). arr's
        \\// own element is retained AGAIN here because concat() returns an
        \\// independent shallow copy, not a view onto arr.
        \\probe;
    , 7);
}
