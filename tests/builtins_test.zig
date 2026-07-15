const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

fn expectString(source: []const u8, expected: []const u8) !void {
    try helpers.runAndCheck(source, expected, struct {
        fn check(want: []const u8, r: helpers.Result) !void {
            try testing.expect(r.value == .string);
            try testing.expectEqualStrings(want, r.value.string.value.data);
        }
    }.check);
}

fn expectBool(source: []const u8, expected: bool) !void {
    try helpers.runAndCheck(source, expected, struct {
        fn check(want: bool, r: helpers.Result) !void {
            try testing.expect(r.value == .boolean);
            try testing.expectEqual(want, r.value.boolean);
        }
    }.check);
}

// ===== Arrays =====

test "push/pop/shift/unshift and length" {
    try helpers.expectNumber("var a = [1]; a.push(2, 3); a.length;", 3);
    try helpers.expectNumber("var a = [1, 2, 3]; a.pop();", 3);
    try helpers.expectNumber("var a = [1, 2, 3]; a.shift();", 1);
    try helpers.expectNumber("var a = [3]; a.unshift(1, 2); a[0] * 100 + a[1] * 10 + a.length;", 123);
}

test "indexOf/includes" {
    try helpers.expectNumber("[10, 20, 30].indexOf(20);", 1);
    try helpers.expectNumber("[10, 20].indexOf(99);", -1);
    try expectBool("[1, 2].includes(2);", true);
    try expectBool("[1, 2].includes(5);", false);
}

test "join" {
    try expectString("[1, 2, 3].join('-');", "1-2-3");
    try expectString("[1, null, 3].join(',');", "1,,3");
    try expectString("[1, 2].join();", "1,2");
}

test "slice with negative indices" {
    try expectString("[1, 2, 3, 4, 5].slice(1, -1).join(',');", "2,3,4");
    try expectString("[1, 2, 3].slice(-2).join(',');", "2,3");
}

test "concat and reverse" {
    try expectString("[1, 2].concat([3, 4], 5).join(',');", "1,2,3,4,5");
    try expectString("[1, 2, 3].reverse().join(',');", "3,2,1");
}

test "map/filter with arrows" {
    try expectString("[1, 2, 3].map(x => x * 2).join(',');", "2,4,6");
    try expectString("[1, 2, 3, 4].filter(x => x % 2 == 0).join(',');", "2,4");
}

test "forEach accumulates via closure" {
    try helpers.expectNumber("var sum = 0; [1, 2, 3].forEach(x => { sum += x; }); sum;", 6);
}

test "reduce with and without an initial value" {
    try helpers.expectNumber("[1, 2, 3, 4].reduce((acc, x) => acc + x, 100);", 110);
    try helpers.expectNumber("[1, 2, 3, 4].reduce((acc, x) => acc + x);", 10);
    try helpers.runAndCheck("var r; try { [].reduce((a, x) => a + x); } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "find/some/every" {
    try helpers.expectNumber("[1, 5, 10].find(x => x > 3);", 5);
    try expectBool("[1, 5].some(x => x > 3);", true);
    try expectBool("[1, 5].every(x => x > 3);", false);
    try expectBool("[4, 5].every(x => x > 3);", true);
}

test "method identity: a.push === b.push" {
    try expectBool("var a = [1]; var b = [2]; a.push === b.push;", true);
}

test "a detached method call is a TypeError" {
    try helpers.runAndCheck("var f = [1].push; var r; try { f(2); } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

// ===== Strings =====

test "string case, trim, repeat" {
    try expectString("'AbC'.toUpperCase();", "ABC");
    try expectString("'AbC'.toLowerCase();", "abc");
    try expectString("'  hi  '.trim();", "hi");
    try expectString("'ab'.repeat(3);", "ababab");
}

test "string search methods" {
    try helpers.expectNumber("'hello world'.indexOf('world');", 6);
    try helpers.expectNumber("'hello'.indexOf('x');", -1);
    try expectBool("'hello'.includes('ell');", true);
    try expectBool("'hello'.startsWith('he');", true);
    try expectBool("'hello'.endsWith('lo');", true);
}

test "charAt and slice" {
    try expectString("'abc'.charAt(1);", "b");
    try expectString("'hello'.slice(1, 3);", "el");
    try expectString("'hello'.slice(-3);", "llo");
}

test "split and chained split/join" {
    try expectString("'a b c'.split(' ').join('-');", "a-b-c");
    try helpers.expectNumber("'a,b,c'.split(',').length;", 3);
}

// ===== Math =====

test "Math basics" {
    try helpers.expectNumber("Math.floor(3.7);", 3);
    try helpers.expectNumber("Math.ceil(3.2);", 4);
    try helpers.expectNumber("Math.round(-0.5);", 0); // the spec quirk: -0.5 rounds to -0, not -1
    try helpers.expectNumber("Math.trunc(-3.7);", -3);
    try helpers.expectNumber("Math.abs(-5);", 5);
    try helpers.expectNumber("Math.sign(-3);", -1);
    try helpers.expectNumber("Math.sqrt(16);", 4);
    try helpers.expectNumber("Math.pow(2, 10);", 1024);
}

test "Math.min/max are variadic" {
    try helpers.expectNumber("Math.max(1, 9, 4);", 9);
    try helpers.expectNumber("Math.min(5, 2, 8);", 2);
}

test "Math.PI and Math.random range" {
    try expectBool("Math.PI > 3.14 && Math.PI < 3.15;", true);
    try expectBool("var r = Math.random(); r >= 0 && r < 1;", true);
}

// ===== JSON =====

test "JSON.stringify" {
    try expectString("JSON.stringify({a: 1, b: [true, null]});", "{\"a\":1,\"b\":[true,null]}");
}

test "JSON.parse round-trip" {
    try helpers.expectNumber("JSON.parse('{\"x\": 42}').x;", 42);
    try helpers.expectNumber("JSON.parse(JSON.stringify({n: 7})).n;", 7);
}

test "JSON.parse of invalid input is a catchable SyntaxError" {
    try helpers.runAndCheck("var r; try { JSON.parse('{oops'); } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("SyntaxError", r.value.string.value.data);
        }
    }.check);
}

// ===== Object statics + Array.isArray =====

test "Object.keys/values/entries" {
    try expectString("Object.keys({a: 1, b: 2}).join(',');", "a,b");
    try expectString("Object.values({a: 1, b: 2}).join(',');", "1,2");
    try expectString("Object.entries({a: 1}).map(p => p[0] + '=' + p[1]).join(',');", "a=1");
}

test "Object.assign" {
    try helpers.expectNumber("var t = {a: 1}; Object.assign(t, {b: 2}, {c: 3}); t.a + t.b + t.c;", 6);
}

test "Array.isArray" {
    try expectBool("Array.isArray([1]);", true);
    try expectBool("Array.isArray({});", false);
    try expectBool("Array.isArray('nope');", false);
}

// ===== Loose globals =====

test "parseInt/parseFloat" {
    try helpers.expectNumber("parseInt('42');", 42);
    try helpers.expectNumber("parseInt('ff', 16);", 255);
    try helpers.expectNumber("parseFloat('3.5abc');", 3.5);
}

test "isNaN/isFinite" {
    try expectBool("isNaN(NaN);", true);
    try expectBool("isNaN(5);", false);
    try expectBool("isFinite(Infinity);", false);
    try expectBool("isFinite(3);", true);
}

test "String/Number/Boolean converters" {
    try expectString("String(5);", "5");
    try helpers.expectNumber("Number('3');", 3);
    try expectBool("Boolean(0);", false);
    try expectBool("Boolean('x');", true);
}

// ===== Integration =====

test "a realistic pipeline combining several builtins" {
    try expectString("[1, 2, 3, 4].map(x => x * 2).filter(x => x > 2).join(',');", "4,6,8");
}

test "builtins compose with user closures and control flow" {
    try helpers.expectNumber(
        \\function sumEvens(nums) {
        \\  return nums.filter(n => n % 2 == 0).reduce((a, n) => a + n, 0);
        \\}
        \\sumEvens([1, 2, 3, 4, 5, 6]);
    ,
        12,
    );
}
