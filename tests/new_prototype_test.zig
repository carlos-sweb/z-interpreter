const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "basic constructor: new binds this to a fresh instance" {
    try helpers.expectNumber(
        "function Point(x, y) { this.x = x; this.y = y; } var p = new Point(3, 4); p.x + p.y;",
        7,
    );
}

test "methods on the prototype resolve through the chain -- even when added AFTER construction" {
    try helpers.expectNumber(
        \\function Point(x, y) { this.x = x; this.y = y; }
        \\var p = new Point(3, 4);
        \\Point.prototype.mag = function() { return this.x * this.x + this.y * this.y; };
        \\p.mag();
    ,
        25,
    );
}

test "two instances share the same prototype method (identity)" {
    try helpers.runAndCheck(
        \\function F() {}
        \\F.prototype.m = function() { return 1; };
        \\var a = new F();
        \\var b = new F();
        \\a.m === b.m;
    ,
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expect(r.value.boolean == true);
            }
        }.check,
    );
}

test "F.prototype.constructor === F" {
    try helpers.runAndCheck("function F() {} F.prototype.constructor === F;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == true);
        }
    }.check);
}

test "an object returned from the constructor overrides the instance" {
    try helpers.expectNumber(
        "function F() { this.a = 1; return { a: 99 }; } var o = new F(); o.a;",
        99,
    );
}

test "a primitive returned from the constructor is ignored" {
    try helpers.expectNumber(
        "function F() { this.a = 1; return 42; } var o = new F(); o.a;",
        1,
    );
}

test "new Foo without parens equals new Foo()" {
    try helpers.expectNumber("function F() { this.a = 5; } var o = new F; o.a;", 5);
}

test "new on an arrow function is a TypeError" {
    try helpers.runAndCheck("var A = () => {}; var r; try { new A(); } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "new on a non-function and on a native are TypeErrors" {
    try helpers.runAndCheck("var x = 5; var r; try { new x(); } catch (e) { r = e.message; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("x is not a constructor", r.value.string.value.data);
        }
    }.check);
    try helpers.runAndCheck("var r; try { new console.log(); } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "instanceof: true for instances, false for plain objects and primitives" {
    try helpers.runAndCheck(
        "function P() {} var p = new P(); [p instanceof P, ({}) instanceof P, 5 instanceof P];",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                const items = r.value.array.value.toSlice();
                try testing.expect(items[0].boolean == true);
                try testing.expect(items[1].boolean == false);
                try testing.expect(items[2].boolean == false);
            }
        }.check,
    );
}

test "instanceof against a function whose prototype was never touched" {
    try helpers.runAndCheck("function P() {} var p = new P(); function Q() {} p instanceof Q;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expect(r.value.boolean == false);
        }
    }.check);
}

test "instanceof with a non-callable RHS is a catchable TypeError" {
    try helpers.runAndCheck("var r; try { ({}) instanceof 5; } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "in: own, inherited, and missing properties" {
    try helpers.runAndCheck(
        \\function P() { this.x = 1; }
        \\P.prototype.m = function() {};
        \\var p = new P();
        \\['x' in p, 'm' in p, 'nope' in p];
    ,
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                const items = r.value.array.value.toSlice();
                try testing.expect(items[0].boolean == true);
                try testing.expect(items[1].boolean == true);
                try testing.expect(items[2].boolean == false);
            }
        }.check,
    );
}

test "in on arrays: indices and length" {
    try helpers.runAndCheck("[0 in [1, 2], 5 in [1, 2], 'length' in [1]];", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            const items = r.value.array.value.toSlice();
            try testing.expect(items[0].boolean == true);
            try testing.expect(items[1].boolean == false);
            try testing.expect(items[2].boolean == true);
        }
    }.check);
}

test "in on null is a catchable TypeError" {
    try helpers.runAndCheck("var r; try { 'a' in null; } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "F.name and F.length" {
    try helpers.runAndCheck("function foo(a, b) {} foo.name + ':' + foo.length;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("foo:2", r.value.string.value.data);
        }
    }.check);
}

test "replacing F.prototype changes what NEW instances inherit, not old ones" {
    try helpers.expectNumber(
        \\function F() {}
        \\F.prototype.v = function() { return 1; };
        \\var old = new F();
        \\F.prototype = { v: function() { return 2; } };
        \\var young = new F();
        \\old.v() * 10 + young.v();
    ,
        12,
    );
}
