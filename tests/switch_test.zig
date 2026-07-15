const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "basic match with break" {
    try helpers.expectNumber("var r; switch (2) { case 1: r = 10; break; case 2: r = 20; break; case 3: r = 30; break; } r;", 20);
}

test "default clause when nothing matches" {
    try helpers.expectNumber("var r; switch (9) { case 1: r = 10; break; default: r = 99; } r;", 99);
}

test "fallthrough without break accumulates" {
    try helpers.expectNumber("var r = 0; switch (1) { case 1: r += 1; case 2: r += 2; case 3: r += 4; } r;", 7);
}

test "no match and no default: nothing runs, value undefined" {
    try helpers.runAndCheck("var r = 0; switch (9) { case 1: r = 1; case 2: r = 2; } r;", {}, struct {
        fn check(_: void, res: helpers.Result) !void {
            try testing.expectEqual(@as(f64, 0), res.value.number);
        }
    }.check);
}

test "default in the middle: a match BEFORE it falls through the default's statements" {
    // Node: switch(1){case 1: r+=1; default: r+=10; case 2: r+=100} -> 111
    try helpers.expectNumber("var r = 0; switch (1) { case 1: r += 1; default: r += 10; case 2: r += 100; } r;", 111);
}

test "default in the middle: no match starts at default and falls into B clauses" {
    // Node: switch(9){case 1: r+=1; default: r+=10; case 2: r+=100} -> 110
    try helpers.expectNumber("var r = 0; switch (9) { case 1: r += 1; default: r += 10; case 2: r += 100; } r;", 110);
}

test "matching is strict: '1' does not match case 1" {
    try helpers.expectNumber("var r = 0; switch ('1') { case 1: r = 1; break; default: r = 2; } r;", 2);
}

test "the discriminant is evaluated exactly once" {
    try helpers.expectNumber(
        "var calls = 0; function d() { calls += 1; return 2; } switch (d()) { case 1: break; case 2: break; case 3: break; } calls;",
        1,
    );
}

test "selectors are only evaluated until the first match" {
    try helpers.expectNumber(
        "var evals = 0; function c(n) { evals += 1; return n; } switch (2) { case c(1): break; case c(2): break; case c(3): break; } evals;",
        2, // c(1) and c(2) run; c(3) never does
    );
}

test "return from inside a switch inside a function" {
    try helpers.expectNumber("function f(x) { switch (x) { case 1: return 10; case 2: return 20; } return 0; } f(2);", 20);
}

test "a throw from a case body is caught by an enclosing try" {
    try helpers.expectNumber("var r; try { switch (1) { case 1: throw 5; } } catch (e) { r = e; } r;", 5);
}

test "nested switch: inner break doesn't cut the outer one" {
    try helpers.expectNumber(
        "var r = 0; switch (1) { case 1: switch (2) { case 2: r += 1; break; } r += 10; break; case 9: r += 100; } r;",
        11,
    );
}

test "unlabelled break inside a switch inside a loop breaks the switch, not the loop" {
    try helpers.expectNumber(
        "var r = 0; for (var i = 0; i < 3; i = i + 1) { switch (i) { case 1: break; default: r += 1; } } r;",
        2, // i=0 and i=2 hit default; i=1 breaks only the switch
    );
}
