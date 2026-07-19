//! Extended String.prototype coverage (regex-dependent methods deferred).
//! Node-verified (strict).
const std = @import("std");
const helpers = @import("helpers.zig");

test "charCodeAt, codePointAt, at" {
    try helpers.expectStdout("console.log('Hi'.charCodeAt(0), 'Hi'.codePointAt(1), 'abc'.at(-1));", "72 105 c\n");
    try helpers.expectStdout("console.log('x'.charCodeAt(5));", "NaN\n");
}

test "padStart and padEnd" {
    try helpers.expectStdout("console.log('5'.padStart(3, '0'), '5'.padEnd(3, '-'), 'abc'.padStart(2));", "005 5-- abc\n");
}

test "substring (clamps and swaps) and legacy substr" {
    try helpers.expectStdout("console.log('Hello World'.substring(6), 'Hello World'.substring(11, 6));", "World World\n");
    try helpers.expectStdout("console.log('hello'.substr(1, 3), 'hello'.substr(-2), 'hello'.substr(-2, 1));", "ell lo l\n");
}

test "lastIndexOf and concat" {
    try helpers.expectNumber("'Hello World'.lastIndexOf('o');", 7);
    try helpers.expectStdout("console.log('a'.concat('b', 'c', 1));", "abc1\n");
}

test "trimStart and trimEnd" {
    try helpers.expectStdout("console.log('  hi  '.trimStart() + '|', '|' + '  hi  '.trimEnd());", "hi  | |  hi\n");
}

test "replace (first) and replaceAll (string patterns), with a function replacer" {
    try helpers.expectStdout("console.log('aXbXc'.replace('X', '-'), 'aXbXc'.replaceAll('X', '-'));", "a-bXc a-b-c\n");
    try helpers.expectStdout("console.log('foo'.replace('o', (m, i) => '[' + i + ']'));", "f[1]o\n");
}

test "localeCompare and String.fromCodePoint" {
    try helpers.expectStdout("console.log('a'.localeCompare('b'), 'b'.localeCompare('b'), 'c'.localeCompare('b'));", "-1 0 1\n");
    try helpers.expectStdout("console.log(String.fromCodePoint(72, 105));", "Hi\n");
}
