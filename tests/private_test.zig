//! Modern class features: fields (public/private/static), private
//! methods/accessors, brand checks, computed keys, and static blocks.
//! Node-verified (strict).
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "field initialization order: parent fields -> parent ctor -> own fields -> own ctor" {
    try helpers.expectStdout(
        \\const log = [];
        \\class A { x = (log.push("A.x"), 1); constructor() { log.push("A.ctor"); } }
        \\class B extends A { y = (log.push("B.y"), 2); constructor() { super(); log.push("B.ctor"); } }
        \\const b = new B();
        \\console.log(log.join(","), b.x, b.y);
    , "A.x,A.ctor,B.y,B.ctor 1 2\n");
}

test "private fields, methods, statics, and #x in obj brand checks" {
    try helpers.expectStdout(
        \\class Counter {
        \\  #n = 0;
        \\  static #instances = 0;
        \\  constructor() { Counter.#instances++; }
        \\  inc() { return ++this.#n; }
        \\  get value() { return this.#n; }
        \\  #double() { return this.#n * 2; }
        \\  dbl() { return this.#double(); }
        \\  static count() { return Counter.#instances; }
        \\  static isCounter(o) { return #n in o; }
        \\}
        \\const c = new Counter(); c.inc(); c.inc();
        \\console.log(c.value, c.dbl(), Counter.count(), Counter.isCounter(c), Counter.isCounter({}));
    , "2 4 1 true false\n");
}

test "accessing another class's private is a brand TypeError" {
    try helpers.expectStdout(
        \\class A { #n = 1; }
        \\class Other { #n = 9; peek(o) { return o.#n; } }
        \\try { new Other().peek(new A()); } catch (e) { console.log(e.constructor.name); }
    , "TypeError\n");
}

test "private getters/setters dispatch" {
    try helpers.expectStdout(
        \\class Temp {
        \\  #c = 0;
        \\  get #f() { return this.#c * 9/5 + 32; }
        \\  set #f(v) { this.#c = (v - 32) * 5/9; }
        \\  toF() { return this.#f; }
        \\  setF(v) { this.#f = v; }
        \\}
        \\const t = new Temp(); t.setF(212); console.log(t.toF());
    , "212\n");
}

test "computed keys evaluate once at definition; numeric keys work" {
    try helpers.expectStdout(
        \\let evals = 0;
        \\const K = () => (evals++, "dyn");
        \\class D { [K()]() { return "computed"; } 1() { return "one"; } }
        \\console.log(new D().dyn(), new D()[1](), evals);
    , "computed one 1\n");
}

test "static fields and static blocks run at definition time, in order" {
    try helpers.expectStdout(
        \\class D { static x = 10; static { D.y = D.x * 2; } }
        \\console.log(D.x, D.y);
    , "10 20\n");
}

test "modifier-named fields; privates invisible to keys/JSON" {
    try helpers.expectStdout(
        \\class E { static = 1; get = 2; #hidden = 3; has() { return this.#hidden; } }
        \\const e = new E();
        \\console.log(e.static, e.get, Object.keys(e).length, JSON.stringify(e), e.has());
    , "1 2 2 {\"static\":1,\"get\":2} 3\n");
}

test "static/get/set followed by ( stay methods (regression)" {
    try helpers.expectStdout(
        \\class F { static() { return 1; } get() { return 2; } async() { return 3; } }
        \\const f = new F();
        \\console.log(f.static(), f.get(), f.async());
    , "1 2 3\n");
}

test "private async method resolves this.#x" {
    try helpers.expectStdout(
        \\class G {
        \\  #v = 41;
        \\  async #load() { return this.#v + 1; }
        \\  run() { return this.#load(); }
        \\}
        \\new G().run().then(v => console.log(v));
    , "42\n");
}

test "delete of a private member is a SyntaxError" {
    try helpers.expectUncaught(
        \\class H { #x = 1; kill() { delete this.#x; } }
        \\new H().kill();
    , .syntax_error, "Private fields can not be deleted: #x");
}

test "implicit derived constructor still runs own fields after super" {
    try helpers.expectStdout(
        \\class A { constructor() { this.base = 1; } }
        \\class B extends A { extra = this.base + 10; }
        \\console.log(new B().extra);
    , "11\n");
}
