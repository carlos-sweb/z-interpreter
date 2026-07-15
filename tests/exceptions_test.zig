const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const helpers = @import("helpers.zig");

// ===== Throw basics =====

test "uncaught throw of a primitive surfaces the raw value" {
    try helpers.expectUncaughtValue("throw 42;", {}, struct {
        fn check(_: void, ex: zvalue.JSValue) !void {
            try testing.expect(ex == .number);
            try testing.expectEqual(@as(f64, 42), ex.number);
        }
    }.check);
}

test "throw of an arbitrary object, caught and read" {
    try helpers.expectNumber("var r; try { throw {code: 5}; } catch (e) { r = e.code; } r;", 5);
}

test "caught primitive binds to the catch param" {
    try helpers.expectNumber("var r; try { throw 1; } catch (e) { r = e; } r;", 1);
}

test "catch without a param" {
    try helpers.expectNumber("var r = 0; try { throw 1; } catch { r = 2; } r;", 2);
}

test "catch param lives in its own scope, doesn't clobber an outer binding" {
    try helpers.runAndCheck("var e = 'outer'; try { throw 'in'; } catch (e) {} e;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("outer", r.value.string.value.data);
        }
    }.check);
}

test "try-statement completion value flows out" {
    try helpers.expectNumber("try { 1; } catch (e) { 2; }", 1);
    try helpers.expectNumber("try { throw 0; } catch (e) { 2; }", 2);
}

// ===== Unwinding through frames (the design's raison d'etre) =====

test "a throw crosses the closure-call vtable boundary" {
    try helpers.expectNumber("function f() { throw 7; } var r; try { f(); } catch (e) { r = e; } r;", 7);
}

test "a throw unwinds from expression position, mid binary op" {
    try helpers.expectNumber("function f() { throw 7; } var r = 0; try { r = 1 + f() * 2; } catch (e) { r = e; } r;", 7);
}

test "a throw unwinds through three nested call frames" {
    try helpers.runAndCheck(
        "function a() { throw 'deep'; } function b() { a(); } function c() { b(); } var r; try { c(); } catch (e) { r = e; } r;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expectEqualStrings("deep", r.value.string.value.data);
            }
        }.check,
    );
}

test "rethrow from a catch body" {
    try helpers.expectNumber("var r; try { try { throw 1; } catch (e) { throw e + 1; } } catch (e2) { r = e2; } r;", 2);
}

test "nested try, inner handles, outer untouched" {
    try helpers.runAndCheck(
        "var r = ''; try { try { throw 'x'; } catch (e) { r = 'inner'; } r += '!'; } catch (e) { r = 'outer'; } r;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expectEqualStrings("inner!", r.value.string.value.data);
            }
        }.check,
    );
}

test "a throw inside a for-loop update is caught by an enclosing try" {
    try helpers.expectNumber("function f() { throw 9; } var r; try { for (var i = 0; i < 3; i = f()) {} } catch (e) { r = e; } r;", 9);
}

// ===== Finally semantics (the gotcha battery, each Node-verified) =====

test "finally-return overrides the try block's return" {
    try helpers.expectNumber("function f() { try { return 1; } finally { return 2; } } f();", 2);
}

test "a NORMAL finally does not override the return" {
    try helpers.runAndCheck(
        "var log = ''; function f() { try { return 1; } finally { log = 'fin'; } } const r = f(); log + r;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expectEqualStrings("fin1", r.value.string.value.data);
            }
        }.check,
    );
}

test "a throw in finally drops the original exception" {
    try helpers.expectNumber("var r; try { try { throw 1; } finally { throw 2; } } catch (e) { r = e; } r;", 2);
}

test "finally runs on the uncaught-throw path and the exception is re-raised after" {
    try helpers.runAndCheck(
        "var log = ''; var r; try { try { throw 1; } finally { log = 'f'; } } catch (e) { r = e; } log + r;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expectEqualStrings("f1", r.value.string.value.data);
            }
        }.check,
    );
}

test "a normal finally does not swallow the try block's value" {
    try helpers.expectNumber("try { 1; } finally { 2; }", 1);
}

test "break in finally overrides return" {
    try helpers.expectNumber("function f() { while (true) { try { return 1; } finally { break; } } return 3; } f();", 3);
}

test "break/continue from the try BLOCK pass through a finally" {
    try helpers.expectNumber(
        "var s = 0; for (var i = 0; i < 3; i = i + 1) { try { if (i == 1) { continue; } s += 1; } finally { s += 10; } } s;",
        32, // i=0: 1+10; i=1: continue, +10; i=2: 1+10
    );
}

test "catch throws, finally still runs, order preserved" {
    try helpers.runAndCheck(
        "var order = ''; var r; try { try { throw 1; } catch (e) { order += 'c'; throw 2; } finally { order += 'f'; } } catch (e2) { r = e2; } order + r;",
        {},
        struct {
            fn check(_: void, r: helpers.Result) !void {
                try testing.expectEqualStrings("cf2", r.value.string.value.data);
            }
        }.check,
    );
}

test "try-finally with no catch, normal path" {
    try helpers.expectNumber("var r = 0; try { r = 1; } finally { r += 10; } r;", 11);
}

// ===== Engine errors are catchable, right kind, right shape =====

test "reading an undeclared identifier throws a catchable ReferenceError" {
    try helpers.runAndCheck("var r; try { nope; } catch (e) { r = e; } typeof r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("object", r.value.string.value.data);
        }
    }.check);
    try helpers.runAndCheck("var r; try { nope; } catch (e) { r = e.name + ': ' + e.message; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("ReferenceError: nope is not defined", r.value.string.value.data);
        }
    }.check);
}

test "member access on null/undefined throws TypeError with Node's message" {
    try helpers.runAndCheck("var r; try { null.x; } catch (e) { r = e.message; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("Cannot read properties of null (reading 'x')", r.value.string.value.data);
        }
    }.check);
    try helpers.runAndCheck("var r; try { undefined.foo; } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "calling a non-function throws TypeError" {
    try helpers.runAndCheck("var x = 5; var r; try { x(); } catch (e) { r = e.message; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("x is not a function", r.value.string.value.data);
        }
    }.check);
}

test "assigning to an undeclared name throws ReferenceError" {
    try helpers.runAndCheck("var r; try { zz = 1; } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("ReferenceError", r.value.string.value.data);
        }
    }.check);
}

test "setting a property on null throws TypeError" {
    try helpers.runAndCheck("var r; try { null.a = 1; } catch (e) { r = e.name; } r;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("TypeError", r.value.string.value.data);
        }
    }.check);
}

test "typeof on an undeclared identifier still doesn't throw (spec quirk preserved)" {
    try helpers.runAndCheck("typeof nope;", {}, struct {
        fn check(_: void, r: helpers.Result) !void {
            try testing.expectEqualStrings("undefined", r.value.string.value.data);
        }
    }.check);
}

test "uncaught engine error at the run() boundary" {
    try helpers.expectUncaught("nope;", .reference_error, "nope is not defined");
}

test "console.log renders a caught error legibly" {
    try helpers.expectStdout(
        "try { null.x; } catch (e) { console.log(e); }",
        "TypeError: Cannot read properties of null (reading 'x')\n",
    );
}

// ===== Feature gaps stay uncatchable =====

test "a JS catch must NOT swallow interpreter feature gaps" {
    // Array element assignment is unimplemented -- that's NotImplemented,
    // not a JS exception, and it must abort the run even inside try/catch.
    try helpers.expectNotImplemented("try { var a = [1]; a[0] = 2; } catch (e) {}");
}
