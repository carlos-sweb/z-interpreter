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

test "u flag: property escapes, astral code points, Unicode case folding" {
    try helpers.expectStdout(
        \\console.log(/\p{L}+/u.exec('123héllo')[0], /\u{1F600}/u.test('😀'), /\u212A/iu.test('k'));
    , "héllo true true\n");
}

test "u flag: strict syntax rejects what Annex B allows" {
    try helpers.expectStdout("console.log(/\\q/.test('q'));", "true\n");
    try helpers.expectUncaught("new RegExp('\\\\q', 'u');", .syntax_error, "Invalid regular expression: /\\q/");
}

test "v flag: set difference, intersection, \\q{} and properties of strings" {
    try helpers.expectStdout(
        \\console.log(/[\p{L}--[a-z]]+/v.exec('abcÉÑxyz')[0], /[[a-z]&&[aeiou]]+/v.exec('xxaeiyy')[0]);
        \\console.log(/[\q{abc|d}]/v.exec('zzabc')[0], /^\p{RGI_Emoji}$/v.test('👍🏽'), /x/v.unicodeSets);
    , "ÉÑ aei\nabc true true\n");
}

test "repeated flags and u together with v are SyntaxErrors" {
    try helpers.expectUncaught("new RegExp('a', 'gg');", .syntax_error, "Invalid flags supplied to RegExp constructor 'gg'");
    try helpers.expectUncaught("new RegExp('a', 'uv');", .syntax_error, "Invalid flags supplied to RegExp constructor 'uv'");
}

test "index, lastIndex and search are UTF-16 code units" {
    try helpers.expectStdout(
        \\const s = 'héllo wörld 😀 x😀y';
        \\const g = /o/g; g.exec(s);
        \\console.log(/w/.exec(s).index, /x/.exec(s).index, s.search(/y/), g.lastIndex);
        \\const y = /l/y; y.lastIndex = 2;
        \\console.log(y.test(s), y.lastIndex);
    , "6 15 18 5\ntrue 3\n");
}

test "lastIndex > 0 searches the whole string: ^, \\b and lookbehind see what precedes it" {
    try helpers.expectStdout(
        \\const a = /^b/g; a.lastIndex = 1;
        \\const b = /\bb/g; b.lastIndex = 1;
        \\const c = /(?<=a)b/g; c.lastIndex = 1;
        \\console.log(a.exec('ab'), b.exec('ab'), c.exec('ab')[0], c.lastIndex);
    , "null null b 2\n");
}

test "lastIndex is read even when neither global nor sticky, and left alone" {
    try helpers.expectStdout(
        \\let gets = 0; const counter = { valueOf() { gets++; return 0; } };
        \\const r = /./; r.lastIndex = counter;
        \\console.log(r.exec('abc')[0], r.lastIndex === counter, gets);
    , "a true 1\n");
}

test "without u, a match can cut a surrogate pair; with u it can't" {
    try helpers.expectStdout(
        \\const m = /\uDE00/.exec('😀');
        \\console.log(m.index, m[0].length, m[0].charCodeAt(0), /\uDE00/u.exec('😀'));
        \\console.log('😀a'.split(/(?:)/).length, '😀😀'.split(/(?:)/u).length);
    , "1 1 56832 null\n3 2\n");
}

test "matchAll, global match, split and a replacer's offset use UTF-16 positions" {
    try helpers.expectStdout(
        \\console.log([...'é😀é😀'.matchAll(/é/g)].map(m => m.index).join(), 'a😀b😀c'.match(/[a-c]/g).join());
        \\const o = []; 'ñ😀ñ'.replace(/ñ/g, (m, off) => { o.push(off); return m; });
        \\console.log(o.join(), 'a😀b😀c'.split(/😀/).join(), 'é1é2é'.split(/(\d)/).join());
    , "0,3 a,b,c\n0,3 a,b,c é,1,é,2,é\n");
}

test "a replacer that cuts a surrogate pair rejoins it into one character" {
    try helpers.expectStdout(
        \\const r = '😀'.replace(/\uDE00/, m => m);
        \\console.log(r === '😀', r.length, '😀'.replace(/\uDE00/g, () => '\uDE01').codePointAt(0));
    , "true 2 128513\n");
}

test "flag and source getters are accessors on RegExp.prototype, not own properties" {
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(RegExp.prototype, 'global');
        \\console.log(typeof d.get, d.set, d.enumerable, d.configurable, d.get.name, d.get.length);
        \\console.log(/x/g.hasOwnProperty('global'), 'global' in /x/, /x/g.global, RegExp.prototype.global);
        \\console.log(RegExp.prototype.source, RegExp.prototype.flags === '', /a/dgimsuy.flags, /a/v.unicodeSets);
    , "function undefined false true get global 0\nfalse true true undefined\n(?:) true dgimsuy true\n");
}

test "a flag getter on a non-RegExp receiver is a TypeError" {
    try helpers.expectUncaught(
        "Object.getOwnPropertyDescriptor(RegExp.prototype, 'global').get.call({});",
        .type_error,
        "RegExp.prototype.global getter called on non-RegExp object",
    );
    try helpers.expectUncaught(
        "Object.getOwnPropertyDescriptor(RegExp.prototype, 'source').get.call(1);",
        .type_error,
        "RegExp.prototype.source getter called on non-object",
    );
}

test "flags is generic and reads the flags in spec order" {
    try helpers.expectStdout(
        \\const log = []; const o = {};
        \\['hasIndices', 'global', 'ignoreCase', 'multiline', 'dotAll', 'unicode', 'unicodeSets', 'sticky']
        \\  .forEach(k => Object.defineProperty(o, k, { get() { log.push(k[0]); return k !== 'dotAll'; } }));
        \\console.log(Object.getOwnPropertyDescriptor(RegExp.prototype, 'flags').get.call(o), log.join(''));
    , "dgimuvy hgimduus\n");
}

test "source escapes / and line terminators; an empty pattern is (?:)" {
    try helpers.expectStdout(
        \\console.log(new RegExp('').source, new RegExp('/').source, new RegExp('[/]').source, new RegExp('a\nb').source);
        \\console.log(new RegExp('/', 'g').toString(), new RegExp('').toString());
    , "(?:) \\/ [/] a\\nb\n/\\//g /(?:)/\n");
}

test "lastIndex is an own data property that defineProperty can make read-only" {
    try helpers.expectStdout(
        \\const d = Object.getOwnPropertyDescriptor(/x/, 'lastIndex');
        \\console.log(d.value, d.writable, d.enumerable, d.configurable);
        \\const r = /c/y; Object.defineProperty(r, 'lastIndex', { value: 1, writable: false });
        \\console.log(Object.getOwnPropertyDescriptor(r, 'lastIndex').writable, r.lastIndex);
        \\try { r.exec('abc'); } catch (e) { console.log(e.name); }
    , "0 true false false\nfalse 1\nTypeError\n");
    try helpers.expectUncaught("Object.defineProperty(/c/, 'lastIndex', { enumerable: true });", .type_error, "Cannot redefine property: lastIndex");
}

test "RegExp.prototype[Symbol.match/matchAll/replace/search/split] and RegExp[Symbol.species]" {
    try helpers.expectStdout(
        \\const P = RegExp.prototype;
        \\console.log(['match', 'matchAll', 'replace', 'search', 'split'].map(k => P[Symbol[k]].name + '/' + P[Symbol[k]].length).join(' '));
        \\console.log(/b+/[Symbol.match]('abbc')[0], /b/g[Symbol.replace]('abcb', 'X'), /c/[Symbol.search]('abc'), /,/[Symbol.split]('a,b').join('|'));
        \\const s = Object.getOwnPropertyDescriptor(RegExp, Symbol.species);
        \\console.log(RegExp[Symbol.species] === RegExp, s.get.name, s.set, s.enumerable, s.configurable);
    , "[Symbol.match]/1 [Symbol.matchAll]/1 [Symbol.replace]/2 [Symbol.search]/1 [Symbol.split]/2\nbb aXcX 2 a|b\ntrue get [Symbol.species] undefined false true\n");
}

test "a static getter's this is the class" {
    try helpers.expectStdout("class A { static get x() { return this; } } console.log(A.x === A);", "true\n");
}
