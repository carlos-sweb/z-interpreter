//! RegExp: literals, the constructor, test/exec (with lastIndex), and the
//! String methods that take regex patterns. z-regex is the engine;
//! this wires it. Node-verified (strict).
const std = @import("std");
const helpers = @import("helpers.zig");

test "literal produces a RegExp with source/flags/booleans" {
    try helpers.expectStdout(
        \\const re = /abc/gi;
        \\console.log(re.source, re.flags, re.global, re.ignoreCase, re.multiline);
    , "abc gi true true false\n");
}

test "test: case-insensitive, anchors, scanning" {
    try helpers.expectStdout("console.log(/ab+c/i.test('xxABBBCyy'), /^\\d+$/.test('12a'));", "true false\n");
}

test "exec: capture groups, index, input, length" {
    try helpers.expectStdout(
        \\const m = /(\d)(\d)/.exec('x12y');
        \\console.log(m[0], m[1], m[2], m.index, m.input, m.length);
    , "12 1 2 1 x12y 3\n");
}

test "global exec advances lastIndex and returns null at the end" {
    try helpers.expectStdout(
        \\const g = /\d/g;
        \\console.log(g.exec('a1b2')[0], g.lastIndex, g.exec('a1b2')[0], g.lastIndex, g.exec('a1b2'));
    , "1 2 2 4 null\n");
}

test "String.match (global and non-global) and search" {
    try helpers.expectStdout("console.log('a1b2c3'.match(/\\d/g).join(','), 'hello'.match(/l+/)[0]);", "1,2,3 ll\n");
    try helpers.expectNumber("'hello world'.search(/world/);", 6);
}

test "String.replace: global, $-substitution, and function replacers" {
    try helpers.expectStdout("console.log('a-b-c'.replace(/-/g, '+'));", "a+b+c\n");
    try helpers.expectStdout("console.log('John Smith'.replace(/(\\w+)\\s(\\w+)/, '$2 $1'));", "Smith John\n");
    try helpers.expectStdout("console.log('abc'.replace(/(\\w)/g, (m, c) => c.toUpperCase()));", "ABC\n");
}

test "String.split with a regex, and matchAll" {
    try helpers.expectStdout("console.log('a,b;c d'.split(/[,; ]/).join('|'));", "a|b|c|d\n");
    try helpers.expectStdout(
        \\console.log([...'x1y2z3'.matchAll(/(\w)(\d)/g)].map(m => m[1] + m[2]).join(','));
    , "x1,y2,z3\n");
}

test "named capture groups" {
    try helpers.expectStdout(
        \\const m = /(?<year>\d{4})-(?<month>\d{2})/.exec('2026-07');
        \\console.log(m.groups.year, m.groups.month);
    , "2026 07\n");
}

test "RegExp constructor, flags, and toString" {
    try helpers.expectStdout("console.log(new RegExp('\\\\d+', 'g').test('abc123'));", "true\n");
    try helpers.expectStdout("console.log(/x/gim.flags, /x/gim.source, /bar/i.toString(), String(/foo/g));", "gim x /bar/i /foo/g\n");
}

test "an invalid pattern is a catchable SyntaxError" {
    try helpers.expectUncaught("new RegExp('[');", .syntax_error, "Invalid regular expression: /[/");
}

test "lastIndex is writable" {
    try helpers.expectStdout(
        \\const re = /\d/g; re.lastIndex = 2;
        \\console.log(re.exec('a1b2c3')[0], re.lastIndex);
    , "2 4\n");
}
