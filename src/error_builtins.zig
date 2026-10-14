//! The Error constructor family: `Error`/`TypeError`/`RangeError`/
//! `SyntaxError`/`ReferenceError`/`EvalError`/`URIError`. One comptime
//! factory generates all 7 natives; `install` replicates the original
//! inline `inline for` loop byte-for-byte. No interleaving possible --
//! this was already a single self-contained section.
//! z-interpreter-refactor.md, Step 5 Phase A batch 9.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

const interp = native_helpers.interp;
const arg = native_helpers.arg;
pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;

// ===== Error.prototype methods =====

/// ECMA-262 20.5.3.4 Error.prototype.toString: "{name}: {message}", or
/// just whichever of the two is non-empty, or "Error" if `name` is
/// undefined -- via real property reads (getProperty), not `this_value`'s
/// raw `.@"error"` fields directly, so it also works if `this`/`name`/
/// `message` were reassigned (spec allows any receiver, not just a real
/// Error instance).
fn errorToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    const name_v = try self.getProperty(this_value, "name");
    defer name_v.deinit();
    const name = if (name_v == .undefined) try allocator.dupe(u8, "Error") else try self.toDisplayStringJS(allocator, name_v);
    defer allocator.free(name);
    const msg_v = try self.getProperty(this_value, "message");
    defer msg_v.deinit();
    const msg = if (msg_v == .undefined) try allocator.dupe(u8, "") else try self.toDisplayStringJS(allocator, msg_v);
    defer allocator.free(msg);
    if (name.len == 0) return self.gcNewString(msg);
    if (msg.len == 0) return self.gcNewString(name);
    const combined = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, msg });
    defer allocator.free(combined);
    return self.gcNewString(combined);
}

pub const error_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "toString", MethodSpec{ .call = errorToString, .arity = 0 } },
});

// ===== Error constructors =====

/// Comptime factory: one native per ErrorKind. The message argument is
/// coerced with toDisplayString (Node stringifies it too); no argument =
/// empty message.
fn errorConstructor(comptime kind: zvalue.ErrorKind) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = this_value;
            const has_msg = arg(args, 0) != .undefined;
            const msg: []const u8 = if (has_msg) try interp(ctx).toDisplayStringJS(allocator, arg(args, 0)) else "";
            defer if (has_msg) allocator.free(msg);
            return interp(ctx).gcNewError(kind, msg);
        }
    }.call;
}

/// Installs `Error`/`TypeError`/`RangeError`/`SyntaxError`/
/// `ReferenceError`/`EvalError`/`URIError`. `new Error('msg')` (and
/// `Error('msg')`, which real JS also allows) produce catchable/
/// throwable .error values of the right kind.
pub fn install(self: *Interpreter) !void {
    const arena = self.gc_allocator;
    const g = self.global_env;
    inline for (.{
        .{ "Error", zvalue.ErrorKind.generic },
        .{ "TypeError", zvalue.ErrorKind.type_error },
        .{ "RangeError", zvalue.ErrorKind.range_error },
        .{ "SyntaxError", zvalue.ErrorKind.syntax_error },
        .{ "ReferenceError", zvalue.ErrorKind.reference_error },
        .{ "EvalError", zvalue.ErrorKind.eval_error },
        .{ "URIError", zvalue.ErrorKind.uri_error },
    }) |entry| {
        const ctor = try self.gcNewFunction(.{
            .ctx = self,
            .name = entry[0],
            .arity = 1,
            .call = errorConstructor(entry[1]),
            .constructable = true,
        });
        try g.define(arena, entry[0], ctor);
    }
}

// ===== AggregateError =====
//
// Unlike the kinds above, an AggregateError is an ordinary `.object`
// (the `.error` tag has no property bag for `errors`/`cause`): its
// [[Prototype]] is AggregateError.prototype, chained to Error.prototype,
// so `instanceof`, Error.prototype.toString and `name` resolve through
// the chain.

const hidden = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };

/// A new AggregateError instance: `message` (an own property only when
/// given) and `errors` (a fresh array of `errs`, each retained).
pub fn newAggregateError(self: *Interpreter, message: ?[]const u8, errs: []const JSValue) !JSValue {
    var o = try self.gcNewObject();
    errdefer o.deinit();
    try o.object.value.setPrototype(&self.protos.aggregate_error.object.value);
    if (message) |m| try o.object.value.defineProperty("message", try self.gcNewString(m), hidden);
    var list = try self.gcNewArray();
    for (errs) |e| _ = try list.array.value.push(e.retain());
    try o.object.value.defineProperty("errors", list, hidden);
    return o;
}

/// AggregateError(errors, message, options), with or without `new`:
/// message, then InstallErrorCause, then `errors` from the iterable.
fn aggregateErrorConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const o: JSValue = if (self.construct_target == ctx and this_value == .object) this_value.retain() else blk: {
        var fresh = try self.gcNewObject();
        try fresh.object.value.setPrototype(&self.protos.aggregate_error.object.value);
        break :blk fresh;
    };
    errdefer o.deinit();
    const msg_v = arg(args, 1);
    if (msg_v != .undefined) {
        if (msg_v == .symbol) return self.throwError(.type_error, "Cannot convert a Symbol value to a string", .{});
        const m = try self.toDisplayStringJS(allocator, msg_v);
        defer allocator.free(m);
        try o.object.value.defineProperty("message", try self.gcNewString(m), hidden);
    }
    const options = arg(args, 2);
    const has_cause = if (builtin_helpers.isObjectLike(options)) blk: {
        const k = try self.gcNewString("cause");
        defer k.deinit();
        break :blk (try self.evalIn(k, options)).boolean;
    } else false;
    if (has_cause) {
        const cause = try self.getProperty(options, "cause");
        try o.object.value.defineProperty("cause", cause, hidden);
    }
    const items = try self.iterableItems(arg(args, 0));
    defer self.gc_allocator.free(items);
    var list = try self.gcNewArray();
    for (items) |e| _ = try list.array.value.push(e.retain());
    try o.object.value.defineProperty("errors", list, hidden);
    return o;
}

/// The `AggregateError` global and its prototype. Runs from
/// materializeProtos, once Error.prototype exists.
pub fn installAggregate(self: *Interpreter) !void {
    const ctor = try builtin_helpers.installBuiltin(self, .{ .name = "AggregateError", .ctor = .{ .arity = 2, .call = aggregateErrorConstructor, .constructable = true } });
    const proto = try self.functionPrototype(ctor);
    try proto.object.value.setPrototype(&self.protos.@"error".object.value);
    try proto.object.value.defineProperty("constructor", ctor.retain(), hidden);
    try proto.object.value.defineProperty("name", try self.gcNewString("AggregateError"), hidden);
    try proto.object.value.defineProperty("message", try self.gcNewString(""), hidden);
    self.protos.aggregate_error = proto;
}
