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

/// ProxyCreate's argument checks. Real Node uses ONE combined message
/// for either failure, not two distinct ones (verified against actual
/// Node, not assumed).
fn proxyCreate(self: *Interpreter, target: JSValue, handler: JSValue) anyerror!JSValue {
    if (!isObjectLike(target) or !isObjectLike(handler)) {
        return self.throwError(.type_error, "Cannot create proxy with a non-object as target or handler", .{});
    }
    return self.gcNewProxy(target.retain(), handler.retain());
}

fn proxyConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Proxy requires 'new'", .{});
    return proxyCreate(self, arg(args, 0), arg(args, 1));
}

/// A Proxy.revocable revoke function's [[RevocableProxy]] slot: the
/// proxy until the first call, `null` afterwards.
pub const RevokeCtx = struct {
    interp: *Interpreter,
    proxy: JSValue,
};

/// Revoking sets the proxy's [[ProxyHandler]] to null; every trap
/// lookup on it then throws (interpreter_support.proxyTrap).
fn proxyRevoke(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    const c: *RevokeCtx = @ptrCast(@alignCast(ctx));
    if (c.proxy != .proxy) return JSValue.UNDEFINED;
    const p = c.proxy;
    c.proxy = JSValue.NULL;
    const old = p.proxy.value.handler;
    p.proxy.value.handler = JSValue.NULL;
    old.deinit();
    p.deinit();
    return JSValue.UNDEFINED;
}

/// Proxy.revocable(target, handler): `{ proxy, revoke }`.
fn proxyRevocable(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const proxy = try proxyCreate(self, arg(args, 0), arg(args, 1));
    const c = try self.gc_allocator.create(RevokeCtx);
    c.* = .{ .interp = self, .proxy = proxy.retain() };
    try self.gcTrackRevokeCtx(c);
    const revoke = try self.gcNewFunction(.{ .ctx = c, .name = "", .arity = 0, .call = proxyRevoke });
    var result = try self.ordinaryObject();
    try result.object.value.set("proxy", proxy);
    try result.object.value.set("revoke", revoke);
    return result;
}

/// Installs the `Proxy` constructor and `Proxy.revocable`.
pub fn install(self: *Interpreter) !void {
    // `new Proxy(target, handler)` -- unlike Date, MUST reject a bare
    // (non-new) call (proxyConstructor's own construct_target check).
    _ = try installBuiltin(self, .{ .name = "Proxy", .ctor = .{ .arity = 2, .call = proxyConstructor, .constructable = true }, .statics = &.{
        .{ .name = "revocable", .value = .{ .method = .{ .call = proxyRevocable, .arity = 2 } } },
    } });
}
