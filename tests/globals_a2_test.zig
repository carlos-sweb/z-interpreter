//! Globals with no object-model dependency: WeakMap/WeakSet/WeakRef/
//! FinalizationRegistry (weak_builtins.zig), AggregateError,
//! Promise.allSettled/any and Proxy.revocable.
const std = @import("std");
const helpers = @import("helpers.zig");

test "WeakMap and WeakSet hold objects and non-registered symbols" {
    try helpers.expectStdout(
        \\const k = {}, k2 = {}, s = Symbol('s');
        \\const wm = new WeakMap([[k, 1]]);
        \\wm.set(k2, 2).set(s, 3);
        \\console.log(wm.get(k), wm.get(k2), wm.get(s), wm.has(1), wm.delete(k), wm.has(k));
        \\const ws = new WeakSet([k]);
        \\console.log(ws.has(k), ws.add(k2) === ws, ws.delete(k2), ws.has(k2));
        \\console.log(Object.prototype.toString.call(wm), Object.prototype.toString.call(ws));
    , "1 2 3 false true false\ntrue true true false\n[object WeakMap] [object WeakSet]\n");
}

test "WeakMap rejects an invalid key and a call without new" {
    try helpers.expectUncaught("new WeakMap().set(1, 2);", .type_error, "Invalid value used as weak map key");
    try helpers.expectUncaught("new WeakSet().add(Symbol.for('r'));", .type_error, "Invalid value used in weak set");
    try helpers.expectUncaught("WeakMap();", .type_error, "Constructor WeakMap requires 'new'");
}

test "WeakRef derefs its target; FinalizationRegistry tracks tokens" {
    try helpers.expectStdout(
        \\const t = {}, tok = {};
        \\const fr = new FinalizationRegistry(() => {});
        \\fr.register(t, 'held', tok);
        \\console.log(new WeakRef(t).deref() === t, fr.unregister(tok), fr.unregister(tok));
    , "true true false\n");
}

test "AggregateError carries message, cause and errors" {
    try helpers.expectStdout(
        \\const e = new AggregateError(new Set([1, 2]), 'm', { cause: 'c' });
        \\console.log(e instanceof AggregateError, e instanceof Error, e.message, e.cause, e.errors.join(), String(e));
        \\console.log(Object.getPrototypeOf(AggregateError.prototype) === Error.prototype, AggregateError([]).hasOwnProperty('message'));
    , "true true m c 1,2 AggregateError: m\ntrue false\n");
}

test "Promise.allSettled and Promise.any" {
    try helpers.expectStdout(
        \\Promise.allSettled([1, Promise.reject(2)]).then(v => console.log(JSON.stringify(v)));
        \\Promise.any([Promise.reject(1), Promise.resolve(2)]).then(v => console.log('any', v));
        \\Promise.any([Promise.reject(1), Promise.reject(2)]).catch(e => console.log(e instanceof AggregateError, e.errors.join()));
    , "[{\"status\":\"fulfilled\",\"value\":1},{\"status\":\"rejected\",\"reason\":2}]\nany 2\ntrue 1,2\n");
}

test "Proxy.revocable: a revoked proxy throws" {
    try helpers.expectStdout(
        \\const r = Proxy.revocable({ a: 1 }, {});
        \\console.log(Object.keys(r).join(), r.proxy.a);
        \\r.revoke(); r.revoke();
        \\try { r.proxy.a; } catch (e) { console.log(e instanceof TypeError); }
    , "proxy,revoke 1\ntrue\n");
}
