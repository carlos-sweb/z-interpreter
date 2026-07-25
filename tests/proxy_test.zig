//! Proxy plan phase 1: only the `.proxy` JSValue variant + GC plumbing +
//! transparent (no-trap) delegation in getProperty/evalIn exist so far --
//! there is no `Proxy(target, handler)` constructor reachable from JS yet
//! (phase 2), so these tests build a `.proxy` value directly via
//! `Interpreter.gcNewProxy` and inject it as a global, rather than
//! running `new Proxy(...)` JS source.
//!
//! IMPORTANT: target/handler objects here MUST be created via
//! `interp.gcNewObject()`, not the raw `zvalue.JSValue.newObject()` --
//! the latter is never registered in the GC registry, and a value handed
//! to `defineGlobal` that's never gcTrack'd leaks unconditionally at
//! shutdown (confirmed as a real, separate, pre-existing bug while
//! writing this file -- NOT a Proxy-specific issue, the same "untracked
//! value" class as the JSON/YAML/TOML gcAdoptTree fix earlier this
//! project, just via a different entry point: any embedder handing a
//! raw-constructed JSValue to `defineGlobal`, not JS source itself).
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const Ctx = struct {
    interp: zinterpreter.Interpreter,
    allocating: std.Io.Writer.Allocating,

    fn init() !*Ctx {
        const self = try testing.allocator.create(Ctx);
        self.allocating = std.Io.Writer.Allocating.init(testing.allocator);
        self.interp = try zinterpreter.Interpreter.init(testing.allocator, &self.allocating.writer);
        return self;
    }

    fn deinit(self: *Ctx) void {
        self.interp.deinit();
        self.allocating.deinit();
        testing.allocator.destroy(self);
    }
};

test "typeof a proxy over a plain object is \"object\" (no get trap needed for typeof)" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    const target = try ctx.interp.gcNewObject();
    const handler = try ctx.interp.gcNewObject();
    const p = try ctx.interp.gcNewProxy(target, handler);
    try ctx.interp.defineGlobal("p", p);
    _ = try ctx.interp.run("console.log(typeof p);");
    try testing.expectEqualStrings("object\n", ctx.allocating.written());
}

test "property read with no `get` trap delegates transparently to the target" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    const target = try ctx.interp.gcNewObject();
    try target.object.value.set("greeting", try ctx.interp.gcNewString("hi"));
    const handler = try ctx.interp.gcNewObject();
    const p = try ctx.interp.gcNewProxy(target, handler);
    try ctx.interp.defineGlobal("p", p);
    _ = try ctx.interp.run("console.log(p.greeting);");
    try testing.expectEqualStrings("hi\n", ctx.allocating.written());
}

test "'in' with no `has` trap delegates transparently to the target" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    const target = try ctx.interp.gcNewObject();
    try target.object.value.set("x", JSValue.fromNumber(1));
    const handler = try ctx.interp.gcNewObject();
    const p = try ctx.interp.gcNewProxy(target, handler);
    try ctx.interp.defineGlobal("p", p);
    _ = try ctx.interp.run("console.log('x' in p, 'y' in p);");
    try testing.expectEqualStrings("true false\n", ctx.allocating.written());
}
