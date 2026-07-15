const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

// ===== for-of =====

test "for-of over an array" {
    try helpers.expectNumber("var sum = 0; for (const x of [1, 2, 3, 4]) { sum += x; } sum;", 10);
}

test "for-of over a string iterates Unicode code points, not bytes" {
    try helpers.runAndCheck(
        "var count = 0; var last = ''; for (const ch of 'a\u{00F1}\u{1F600}') { count += 1; last = ch; } last + count;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                // 3 code points; the last one is the 4-byte emoji
                try testing.expectEqualStrings("\u{1F600}3", r.value.string.value.data);
            }
        }.check,
    );
}

test "for-of break/continue and labels" {
    try helpers.expectNumber(
        "var sum = 0; for (const x of [1, 2, 3, 4, 5]) { if (x == 2) { continue; } if (x == 4) { break; } sum += x; } sum;",
        4, // 1 + 3
    );
    try helpers.expectNumber(
        \\var sum = 0;
        \\outer: for (const x of [1, 2, 3]) {
        \\  for (const y of [10, 20]) {
        \\    if (y == 20) { continue outer; }
        \\    sum += x * y;
        \\  }
        \\}
        \\sum;
    ,
        60, // 10 + 20 + 30
    );
}

test "for-of over a plain object is a catchable TypeError (matches Node)" {
    try helpers.runAndCheck("var r; try { for (const x of {a: 1}) {} } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "for-of over null is a catchable TypeError" {
    try helpers.runAndCheck("var r; try { for (const x of null) {} } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "each for-of iteration gets its own binding (closure capture)" {
    try helpers.expectNumber(
        "var f; for (const x of [1, 2, 3]) { if (x == 2) { f = () => x; } } f();",
        2,
    );
}

test "for-of with an existing (pre-declared) binding" {
    try helpers.expectNumber("var x; var sum = 0; for (x of [5, 6]) { sum += x; } sum + x;", 17); // 11 + last x=6
}

// ===== for-in =====

test "for-in over an object yields own keys in insertion order" {
    try helpers.runAndCheck(
        "var out = ''; for (const k in {b: 1, a: 2, c: 3}) { out += k; } out;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expectEqualStrings("bac", r.value.string.value.data);
            }
        }.check,
    );
}

test "for-in includes inherited enumerable keys via the prototype chain" {
    try helpers.runAndCheck(
        \\function F() { this.own = 1; }
        \\F.prototype.inherited = 2;
        \\var o = new F();
        \\var out = '';
        \\for (const k in o) { out += k + ','; }
        \\out;
    ,
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                // own first, then walk the chain -- constructor is
                // enumerable in our narrowed model (documented divergence:
                // real JS marks it non-enumerable)
                try testing.expect(std.mem.indexOf(u8, r.value.string.value.data, "own,") != null);
                try testing.expect(std.mem.indexOf(u8, r.value.string.value.data, "inherited,") != null);
            }
        }.check,
    );
}

test "a shadowed key is seen exactly once" {
    try helpers.expectNumber(
        \\function F() { this.v = 1; }
        \\F.prototype.v = 2;
        \\var o = new F();
        \\var count = 0;
        \\for (const k in o) { if (k == 'v') { count += 1; } }
        \\count;
    ,
        1,
    );
}

test "for-in over an array yields STRING indices" {
    try helpers.runAndCheck(
        "var out = ''; var t; for (const k in [10, 20, 30]) { out += k; t = typeof k; } out + ':' + t;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expectEqualStrings("012:string", r.value.string.value.data);
            }
        }.check,
    );
}

test "for-in over a string yields index strings" {
    try helpers.runAndCheck("var out = ''; for (const k in 'ab') { out += k; } out;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("01", r.value.string.value.data);
        }
    }.check);
}

test "for-in over null/undefined: zero iterations, NO error (spec)" {
    try helpers.expectNumber("var n = 0; for (const k in null) { n += 1; } for (const k in undefined) { n += 1; } n;", 0);
}

test "for-in with an existing binding leaves the last key behind" {
    try helpers.runAndCheck("var k; for (k in {x: 1, y: 2}) {} k;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("y", r.value.string.value.data);
        }
    }.check);
}
