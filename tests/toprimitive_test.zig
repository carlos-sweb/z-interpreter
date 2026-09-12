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

// Phase 2: operators reduce object operands (hint per operator, left
// before right) and keep BigInt through ToNumeric.

test "arithmetic, bitwise, shift and compound assignment reduce objects via valueOf" {
    try helpers.expectStdout(
        \\var log = [];
        \\function V(t, v) { return { valueOf() { log.push(t); return v; }, toString() { log.push(t + ".ts"); return "T" + t; } }; }
        \\var r = [];
        \\r.push(V("a", 2) * 3);
        \\var o = V("b", 2); o *= 3; r.push(o);
        \\var p = V("c", 5); p += 1; r.push(p);
        \\r.push(V("d", 7) | 0);
        \\r.push(V("e", -1) >>> 0);
        \\r.push(V("f", -1) >>> V("g", 33));
        \\r.push([5] << 1, [2] ** [3]);
        \\r.push(V("h", 3) ** 2);
        \\var x = { q: V("i", 1) }; x.q += 1; r.push(x.q);
        \\console.log(r.join(","));
        \\console.log(log.join(","));
    , "6,6,6,7,4294967295,2147483647,10,8,9,2\na,b,c,d,e,f,g,h,i\n");
}

test "+ uses hint default and concatenates when either side is a string" {
    try helpers.expectStdout(
        \\function V(v, s) { return { valueOf() { return v; }, toString() { return s; } }; }
        \\console.log([V(2, "s") + 1, V(2, "s") + "", "a" + V(1, "z"), true + V(1, "z"), null + { toString() { return "x"; } }, [] + {}, [] + 1, ({}) + 1].join("|"));
        \\console.log(typeof (new Date(0) + 1), new Date(0) - 0, new Date(5) - 1);
    , "3|2|a1|2|nullx|[object Object]|1|[object Object]1\nstring 0 4\n");
}

test "relational operators use hint number, left before right" {
    try helpers.expectStdout(
        \\var log = [];
        \\function V(t, v) { return { valueOf() { log.push(t); return v; }, toString() { return "x"; } }; }
        \\console.log(V("a", "10") < "9", V("l", 1) >= V("r", 1), V("l2", 1) > V("r2", 2), 1n < V("b", 2));
        \\console.log(log.join(","));
    , "true true false true\na,l,r,l2,r2,b\n");
}

test "BigInt survives ToPrimitive/ToNumeric" {
    try helpers.expectStdout(
        \\function B(v) { return { valueOf() { return v; } }; }
        \\var r = [String(Object(1n) + 1n), String(-B(1n)), String(~B(1n)), String(B(1n) * B(3n))];
        \\var o = B(1n); var old = o++;
        \\r.push(typeof old + ":" + String(old), typeof o + ":" + String(o));
        \\try { B(1n) + 1; } catch (e) { r.push(e.name); }
        \\console.log(r.join(","));
    , "2,-1,-2,3,bigint:1,bigint:2,TypeError\n");
}

test "++/-- call valueOf exactly once and yield the ToNumeric value" {
    try helpers.expectStdout(
        \\var n = 0;
        \\var o = { valueOf() { n++; return "5"; } };
        \\var a = o++;
        \\var p = { valueOf() { n++; return "5"; } };
        \\var b = ++p;
        \\console.log(a, o, b, p, n);
    , "5 6 6 6 2\n");
}

test "Symbol operands are TypeErrors with Node's messages" {
    try helpers.expectStdout(
        \\var r = [];
        \\function t(f) { try { f(); r.push("no throw"); } catch (e) { r.push(e.message); } }
        \\t(() => Symbol() < 1);
        \\t(() => 1 + Symbol());
        \\t(() => "" + Symbol());
        \\t(() => ({ valueOf() { return Symbol(); } }) * 1);
        \\console.log(r.join("|"));
    , "Cannot convert a Symbol value to a number|Cannot convert a Symbol value to a number|Cannot convert a Symbol value to a string|Cannot convert a Symbol value to a number\n");
}

test "values returned by reference from conversion methods survive repeated coercion" {
    // Regression: a `return someVar` result is a borrowed reference;
    // releasing it corrupted the variable (use-after-free) after a few
    // coercions. Found by test262 addition/coerce-symbol-to-prim-return-prim.js.
    try helpers.expectStdout(
        \\var s = Symbol("x");
        \\var y = { [Symbol.toPrimitive]() { return s; } };
        \\for (var i = 0; i < 20; i++) { try { 0 + y; } catch (e) {} }
        \\var t = "a".repeat(3);
        \\var z = { [Symbol.toPrimitive]() { return t; } };
        \\var r;
        \\for (var i = 0; i < 20; i++) { r = 0 + z; }
        \\var o2 = { a: 1 };
        \\var w = { valueOf() { return o2; }, toString() { return "s"; } };
        \\var q;
        \\for (var i = 0; i < 20; i++) { q = w + ""; }
        \\var y2 = {};
        \\y2[Symbol.toPrimitive] = function () { return Symbol.toPrimitive; };
        \\for (var i = 0; i < 20; i++) { try { y2 + ""; } catch (e) {} }
        \\console.log(String(s), r, t, q, o2.a, typeof Symbol.toPrimitive);
    , "Symbol(x) 0aaa aaa s 1 symbol\n");
}

// Phase 3: ToPropertyKey -- object keys go through ToPrimitive(string).

test "object keys are converted with ToPrimitive(string) everywhere a key is used" {
    try helpers.expectStdout(
        \\var log = [];
        \\function K(t, s) { return { toString() { log.push(t); return s; }, valueOf() { log.push(t + ".vo"); return "V"; } }; }
        \\var o = {}; o[K("a", "key")] = 1;
        \\var r = [Object.keys(o).join(), ({ key: 5 })[K("b", "key")], K("c", "x") in { x: 1 }, [10, 20][K("d", "1")]];
        \\var s = Symbol("s"); var o2 = {}; o2[{ toString() { return s; } }] = 2; r.push(o2[s]);
        \\var o3 = {}; o3[{ toString: undefined, valueOf() { return "vv"; } }] = 3; r.push(Object.keys(o3).join());
        \\r.push(Object.keys({ [K("f", "lit")]: 1 }).join());
        \\var o4 = { key: 1 }; r.push(delete o4[K("g", "key")], Object.keys(o4).length);
        \\console.log(r.join(","));
        \\console.log(log.join(","));
    , "key,5,true,20,2,vv,lit,true,0\na,b,c,d,f,g\n");
}

test "builtins taking a property key apply ToPropertyKey" {
    try helpers.expectStdout(
        \\var log = [];
        \\function K(t, s) { return { toString() { log.push(t); return s; } }; }
        \\var r = [];
        \\var o = {}; Object.defineProperty(o, K("a", "d"), { value: 1, enumerable: true }); r.push(Object.keys(o).join());
        \\r.push(({ h: 1 }).hasOwnProperty(K("b", "h")), Object.getOwnPropertyDescriptor({ g: 4 }, K("c", "g")).value, Reflect.get({ r: 6 }, K("d", "r")));
        \\var a = [1, 2]; a[K("e", "0")] = 9; r.push(a.join(""));
        \\var hints = []; var o5 = {}; o5[{ [Symbol.toPrimitive](h) { hints.push(h); return "p"; } }] = 1; r.push(hints.join(), Object.keys(o5).join());
        \\console.log(r.join(","));
        \\console.log(log.join(","));
    , "d,true,4,6,92,string,p\na,b,c,d,e\n");
}

test "ToPropertyKey order and abrupt completions" {
    try helpers.expectStdout(
        \\var log = [];
        \\function K(t, s) { return { toString() { log.push(t); return s; } }; }
        \\var o = {}; o[K("k1", "key")] = (log.push("rhs1"), 1);
        \\var o2 = { key: 1 }; o2[K("k2", "key")] += (log.push("rhs2"), 1);
        \\var r = [o2.key];
        \\try { var o3 = {}; o3[{ [Symbol.toPrimitive]() { throw new RangeError("K"); } }] = 1; } catch (e) { r.push(e.name); }
        \\try { var o4 = {}; o4[{ toString() { return {}; }, valueOf() { return {}; } }] = 1; } catch (e) { r.push(e.name); }
        \\console.log(r.join(","));
        \\console.log(log.join(","));
    , "2,RangeError,TypeError\nrhs1,k1,k2,rhs2,k2\n");
}

test "a valueOf/toString read via a shared accessor getter does not corrupt refcounts" {
    // Regression: ordinaryToPrimitive used to `deinit()` the result of
    // reading `valueOf`/`toString`, assuming getProperty always hands
    // back a fresh reference. An ACCESSOR property's getter can instead
    // return a value borrowed from its own closure (here, the same
    // `fn` returned on every read) -- deinit'ing it crashed (Rc.decref
    // underflow) on the second coercion. Found by test262
    // Symbol.prototype/Symbol.toPrimitive/removed-symbol-wrapper-ordinary-toprimitive.js.
    try helpers.expectStdout(
        \\var calls = 0;
        \\var fn = function () { calls++; return 5; };
        \\Object.defineProperty(Object.prototype, "valueOf", { get() { return fn; } });
        \\var o1 = {};
        \\var o2 = {};
        \\console.log(o1 + 1, o2 * 2, calls);
    , "6 10 2\n");
}

test "a throwing left operand stops before the right one is converted" {
    try helpers.expectStdout(
        \\var log = [];
        \\try { ({ valueOf() { throw new RangeError("L"); } }) - { valueOf() { log.push("r"); return 1; } }; } catch (e) { log.push(e.name); }
        \\console.log(log.join(","));
    , "RangeError\n");
}
