//! The real constructors (Object/Array/Function/String/Number/Boolean),
//! their statics, and the Test262-harness patterns they unlock.
const std = @import("std");
const helpers = @import("helpers.zig");

test "Object is a function; Object(x) passes objects through; new Object() works" {
    try helpers.expectStdout("console.log(typeof Object, new Object() !== null); const o = {a:1}; console.log(Object(o) === o);", "function true\ntrue\n");
}

test "Array constructor forms and statics" {
    try helpers.expectStdout(
        \\console.log(Array(3).length, Array(1,2).join(','), new Array(2).length);
        \\console.log(Array.of(1,2).join(','), Array.from('ab').join(','), Array.from([1,2], x => x*2).join(','));
        \\try { Array(-1); } catch (e) { console.log(e.name + ': ' + e.message); }
    , "3 1,2 2\n1,2 a,b 2,4\nRangeError: Invalid array length\n");
}

test "Array.from drives the iterator protocol (generators included)" {
    try helpers.expectStdout(
        \\function* tres() { yield 1; yield 2; yield 3; }
        \\console.log(Array.from(tres()).join(','));
    , "1,2,3\n");
}

test "new Function parses and closes over globals" {
    try helpers.expectStdout(
        \\const suma = new Function('a', 'b', 'return a + b');
        \\console.log(suma(2, 3), typeof suma, suma.name);
        \\try { new Function('return @@@'); } catch (e) { console.log('bad:', e.name); }
    , "5 function anonymous\nbad: SyntaxError\n");
}

test "error values expose .constructor (the assert.throws contract)" {
    try helpers.expectStdout(
        \\console.log(new TypeError('x').constructor === TypeError);
        \\console.log(new Error('y').constructor === Error);
        \\try { null.x; } catch (e) { console.log(e.constructor === TypeError, e.constructor.name); }
    , "true\ntrue\ntrue TypeError\n");
}

test "plain objects answer Object.prototype methods" {
    try helpers.expectStdout(
        \\console.log(({}).hasOwnProperty('q'), ({q:1}).hasOwnProperty('q'), ({}).toString());
        \\const proto = {marca: 1};
        \\const hijo = Object.create(proto);
        \\console.log(proto.isPrototypeOf(hijo), hijo.isPrototypeOf(proto));
    , "false true [object Object]\ntrue false\n");
}

test "the propertyHelper harness pattern works end to end" {
    try helpers.expectStdout(
        \\const __hop = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
        \\console.log(__hop({q: 1}, 'q'), __hop({}, 'q'));
    , "true false\n");
}

test "String/Number/Boolean: callable coerces, constructable gives objects; statics" {
    try helpers.expectStdout(
        \\console.log(String(5), Number('7') + 1, Boolean(0));
        \\console.log(typeof new String('abc'), typeof new Number(5));
        \\console.log(Number.isNaN(NaN), Number.isNaN('x'), Number.isInteger(5.0), Number.isInteger(5.5));
        \\console.log(Number.MAX_SAFE_INTEGER, String.fromCharCode(72, 105));
    , "5 8 false\nobject object\ntrue false true false\n9007199254740991 Hi\n");
}
