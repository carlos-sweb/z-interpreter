//! Property descriptors: defineProperty/getOwnPropertyDescriptor,
//! enforcement (always-strict), freeze/seal, delete. Node-verified.
const std = @import("std");
const helpers = @import("helpers.zig");

test "defineProperty defaults, descriptor readback, readonly enforcement" {
    try helpers.expectStdout(
        \\const o = {};
        \\Object.defineProperty(o, 'x', { value: 1 });
        \\console.log(JSON.stringify(Object.getOwnPropertyDescriptor(o, 'x')));
        \\try { o.x = 2; } catch (e) { console.log(e.name + ': ' + e.message); }
    , "{\"value\":1,\"writable\":false,\"enumerable\":false,\"configurable\":false}\nTypeError: Cannot assign to read only property 'x' of object\n");
}

test "partial descriptors merge on configurable properties" {
    try helpers.expectStdout(
        \\const o = {};
        \\Object.defineProperty(o, 'y', { value: 5, writable: true, enumerable: true, configurable: true });
        \\Object.defineProperty(o, 'y', { enumerable: false });
        \\console.log(JSON.stringify(Object.getOwnPropertyDescriptor(o, 'y')), Object.keys(o).length, o.y);
    , "{\"value\":5,\"writable\":true,\"enumerable\":false,\"configurable\":true} 0 5\n");
}

test "accessor descriptors: define, dispatch, readback" {
    try helpers.expectStdout(
        \\const acc = {}; let backing = 7;
        \\Object.defineProperty(acc, 'v', { get() { return backing; }, set(n) { backing = n; }, configurable: true });
        \\acc.v = 9; console.log(acc.v);
        \\const d = Object.getOwnPropertyDescriptor(acc, 'v');
        \\console.log(typeof d.get, typeof d.set, d.enumerable, d.configurable);
    , "9\nfunction function false true\n");
}

test "non-configurable: redefine and delete both throw" {
    try helpers.expectStdout(
        \\const nc = {};
        \\Object.defineProperty(nc, 'k', { value: 1 });
        \\try { Object.defineProperty(nc, 'k', { value: 2 }); } catch (e) { console.log('redef:', e.message); }
        \\try { delete nc.k; } catch (e) { console.log('del:', e.name); }
    , "redef: Cannot redefine property: k\ndel: TypeError\n");
}

test "delete: configurable properties, missing keys, non-members" {
    try helpers.expectStdout(
        \\const del = { a: 1 };
        \\console.log(delete del.a, del.a, delete del.nope, delete 5);
    , "true undefined true true\n");
}

test "freeze and seal enforce and report" {
    try helpers.expectStdout(
        \\const frozen = Object.freeze({z: 1});
        \\try { frozen.z = 2; } catch (e) { console.log('frozen:', e.name); }
        \\console.log(Object.isFrozen(frozen), Object.isSealed(frozen), Object.isExtensible(frozen));
    , "frozen: TypeError\ntrue true false\n");
}

test "Object.create with prototype and property descriptors" {
    try helpers.expectStdout(
        \\const proto = { saluda() { return 'hola ' + this.nombre; } };
        \\const hijo = Object.create(proto, { nombre: { value: 'ana', enumerable: true } });
        \\console.log(hijo.saluda(), Object.keys(hijo).join(','));
    , "hola ana nombre\n");
}

test "enumerable:false hides from for-in, keys, and JSON" {
    try helpers.expectStdout(
        \\const o = { visible: 1 };
        \\Object.defineProperty(o, 'oculta', { value: 2, enumerable: false });
        \\const seen = []; for (const k in o) seen.push(k);
        \\console.log(seen.join(','), JSON.stringify(o), Object.getOwnPropertyNames(o).join(','));
    , "visible {\"visible\":1} visible,oculta\n");
}

test "a function's prototype descriptor holds its own reference to the prototype" {
    // F's prototype: F's own reference, `p` and the completion value = 3.
    // The descriptor adds one and gives it back when it dies; without its
    // own reference, its death would drop the prototype to 2 (and to 0,
    // freeing it under F, for a prototype nothing else holds).
    try helpers.runAndCheck(
        \\function F() {}
        \\let p = Reflect.get(F, "prototype");
        \\let d = Object.getOwnPropertyDescriptor(F, "prototype");
        \\d = null;
        \\p;
    , @as(usize, 3), struct {
        fn check(want: usize, result: helpers.Result) !void {
            try std.testing.expect(result.value == .object);
            try std.testing.expectEqual(want, result.value.object.refCount());
        }
    }.check);
}

test "dropping a builtin prototype's descriptor keeps the prototype alive" {
    try helpers.expectStdout(
        \\var d = Object.getOwnPropertyDescriptor(Function, "prototype");
        \\d = null;
        \\d = Object.getOwnPropertyDescriptor(Object, "prototype");
        \\d = null;
        \\var junk = []; for (var i = 0; i < 2000; i++) junk.push({ x: i });
        \\console.log(Reflect.get(Function, "prototype") === Object.getPrototypeOf(function () {}), Object.hasOwnProperty("prototype"), Reflect.get(Object, "prototype") === Object.getPrototypeOf({}));
    , "true true true\n");
}
