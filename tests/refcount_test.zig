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
