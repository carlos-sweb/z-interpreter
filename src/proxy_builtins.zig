//! `Proxy`: constructable, rejects a bare (non-`new`) call. No
//! prototype method table -- traps are dispatched specially elsewhere
//! in interpreter.zig, not through the usual method-table mechanism.
//! z-interpreter-refactor.md, Step 5 Phase A.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zbigint = @import("zbigint");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

pub const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;

const isObjectLike = builtin_helpers.isObjectLike;

fn proxyConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Proxy requires 'new'", .{});
    const target = arg(args, 0);
    const handler = arg(args, 1);
    // Real Node uses ONE combined message for either failure, not two
    // distinct ones (verified against actual Node, not assumed).
    if (!isObjectLike(target) or !isObjectLike(handler)) {
        return self.throwError(.type_error, "Cannot create proxy with a non-object as target or handler", .{});
    }
    return self.gcNewProxy(target.retain(), handler.retain());
}

/// Installs the `Proxy` constructor (no statics).
pub fn install(self: *Interpreter) !void {
    // `new Proxy(target, handler)` -- unlike Date, MUST reject a bare
    // (non-new) call (proxyConstructor's own construct_target check).
    _ = try installBuiltin(self, .{ .name = "Proxy", .ctor = .{ .arity = 2, .call = proxyConstructor, .constructable = true } });
}
