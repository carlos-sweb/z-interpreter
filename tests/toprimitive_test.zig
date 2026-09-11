const helpers = @import("helpers.zig");

// ToPrimitive (ECMA-262 7.1.1). Expected outputs captured from real Node
// v26 before implementing (~/.plans/pendientes/toprimitive-coercion.md).

test "@@toPrimitive receives the hint of each coercion context" {
    try helpers.expectStdout(
        \\var hints = [];
        \\var o = { [Symbol.toPrimitive](h) { hints.push(h); return 1; } };
        \\`${o}`; +o; o == 1;
        \\console.log(hints.join(","));
    , "string,number,default\n");
}

test "@@toPrimitive must be callable and return a primitive" {
    try helpers.expectStdout(
        \\var r = [];
        \\try { `${ {[Symbol.toPrimitive]() { return {}; }} }`; } catch (e) { r.push(e.name); }
        \\try { +{[Symbol.toPrimitive]: 1}; } catch (e) { r.push(e.name); }
        \\try { +{ valueOf() { return {}; }, toString() { return {}; } }; } catch (e) { r.push(e.name); }
        \\console.log(r.join(","));
    , "TypeError,TypeError,TypeError\n");
}

test "@@toPrimitive undefined/null falls back to OrdinaryToPrimitive" {
    try helpers.expectStdout(
        \\console.log(`${ {[Symbol.toPrimitive]: undefined, toString() { return "s"; }} }`);
        \\console.log(+{[Symbol.toPrimitive]: null, valueOf() { return 7; }});
    , "s\n7\n");
}

test "inherited @@toPrimitive is honored" {
    try helpers.expectStdout(
        \\var p = { [Symbol.toPrimitive](h) { return "p:" + h; } };
        \\console.log(`${Object.create(p)}`);
    , "p:string\n");
}

test "objects without @@toPrimitive keep OrdinaryToPrimitive behavior" {
    try helpers.expectStdout(
        \\console.log([] == "", [1, 2] == "1,2", ({}) == "[object Object]");
    , "true true true\n");
}

test "Date.prototype[Symbol.toPrimitive]: shape and hint mapping" {
    try helpers.expectStdout(
        \\var f = Date.prototype[Symbol.toPrimitive];
        \\var d = Object.getOwnPropertyDescriptor(Date.prototype, Symbol.toPrimitive);
        \\console.log(typeof f, f.name, f.length, d.writable, d.enumerable, d.configurable);
        \\var o = { valueOf() { return 1; }, toString() { return "s"; } };
        \\console.log(f.call(o, "default"), f.call(o, "string"), f.call(o, "number"));
        \\try { f.call(o, "bogus"); } catch (e) { console.log(e.name); }
        \\try { f.call(1, "number"); } catch (e) { console.log(e.name); }
    , "function [Symbol.toPrimitive] 1 false false true\ns s 1\nTypeError\nTypeError\n");
}

test "a Date's default hint is string" {
    try helpers.expectStdout(
        \\var d = new Date(0);
        \\console.log(d == d.toString(), +new Date(5));
    , "true 5\n");
}

test "implicit Symbol conversion is a TypeError; explicit String(sym) is not" {
    try helpers.expectStdout(
        \\var r = [];
        \\try { `${Symbol("a")}`; } catch (e) { r.push(e.name + ": " + e.message); }
        \\try { +Symbol(); } catch (e) { r.push(e.name + ": " + e.message); }
        \\console.log(r.join("|"));
        \\console.log(String(Symbol("d")));
    , "TypeError: Cannot convert a Symbol value to a string|TypeError: Cannot convert a Symbol value to a number\nSymbol(d)\n");
}
