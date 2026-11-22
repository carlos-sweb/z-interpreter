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
    const name = if (name_v.tag() == .undefined) try allocator.dupe(u8, "Error") else try self.toDisplayStringJS(allocator, name_v);
    defer allocator.free(name);
    const msg_v = try self.getProperty(this_value, "message");
    defer msg_v.deinit();
    const msg = if (msg_v.tag() == .undefined) try allocator.dupe(u8, "") else try self.toDisplayStringJS(allocator, msg_v);
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

/// ECMA-262 ES2025 Error.isError(arg): returns true iff arg has [[ErrorData]].
fn errorIsError(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    if (args.len == 0) return JSValue.fromBool(false);
    const v = args[0];
    return JSValue.fromBool(v.isError() or (v.tag() == .object and v.asObject().value.is_error_data));
}

// ===== Error constructors =====

fn installErrorCause(self: *Interpreter, o: JSValue, options: JSValue) anyerror!void {
    const has_cause = if (builtin_helpers.isObjectLike(options)) blk: {
        const k = try self.gcNewString("cause");
        defer k.deinit();
        break :blk (try self.evalIn(k, options)).asBool();
    } else false;
    if (has_cause) {
        const cause = try self.getProperty(options, "cause");
        try o.asObject().value.defineProperty("cause", cause, hidden);
    }
}

fn nativeErrorProto(self: *Interpreter, kind: zvalue.ErrorKind) !JSValue {
    if (kind == .generic) return self.protos.@"error";
    const ctor = self.global_env.get(kind.name()) orelse return self.protos.@"error";
    return try self.functionPrototype(ctor);
}

/// Comptime factory: one native per ErrorKind. Produces an ordinary
/// `.object` with `is_error_data = true` ([[ErrorData]]), chained to
/// the corresponding `%NativeError%.prototype` (or `this_value` when
/// invoked via `new` / `super()`).
fn errorConstructor(comptime kind: zvalue.ErrorKind) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            const self = interp(ctx);
            const o: JSValue = if (self.construct_target == ctx and this_value.tag() == .object) this_value.retain() else blk: {
                var fresh = try self.gcNewObject();
                const proto = try nativeErrorProto(self, kind);
                if (proto.tag() == .object) try fresh.asObject().value.setPrototype(&proto.asObject().value);
                break :blk fresh;
            };
            errdefer o.deinit();
            o.asObject().value.is_error_data = true;
            const msg_v = arg(args, 0);
            if (msg_v.tag() != .undefined) {
                if (msg_v.tag() == .symbol) return self.throwError(.type_error, "Cannot convert a Symbol value to a string", .{});
                const msg = try self.toDisplayStringJS(allocator, msg_v);
                defer allocator.free(msg);
                try o.asObject().value.defineProperty("message", try self.gcNewString(msg), hidden);
            }
            try installErrorCause(self, o, arg(args, 1));
            return o;
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
        if (std.mem.eql(u8, entry[0], "Error")) {
            const bag = try self.functionStatics(ctor);
            try builtin_helpers.dneMethod(bag, "isError", try native_helpers.native(self, "isError", 1, errorIsError));
        }
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
    o.asObject().value.is_error_data = true;
    try o.asObject().value.setPrototype(&self.protos.aggregate_error.asObject().value);
    if (message) |m| try o.asObject().value.defineProperty("message", try self.gcNewString(m), hidden);
    var list = try self.gcNewArray();
    for (errs) |e| _ = try list.asArray().value.push(e.retain());
    try o.asObject().value.defineProperty("errors", list, hidden);
    return o;
}

/// AggregateError(errors, message, options), with or without `new`:
/// message, then InstallErrorCause, then `errors` from the iterable.
fn aggregateErrorConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const o: JSValue = if (self.construct_target == ctx and this_value.tag() == .object) this_value.retain() else blk: {
        var fresh = try self.gcNewObject();
        try fresh.asObject().value.setPrototype(&self.protos.aggregate_error.asObject().value);
        break :blk fresh;
    };
    errdefer o.deinit();
    o.asObject().value.is_error_data = true;
    const msg_v = arg(args, 1);
    if (msg_v.tag() != .undefined) {
        if (msg_v.tag() == .symbol) return self.throwError(.type_error, "Cannot convert a Symbol value to a string", .{});
        const m = try self.toDisplayStringJS(allocator, msg_v);
        defer allocator.free(m);
        try o.asObject().value.defineProperty("message", try self.gcNewString(m), hidden);
    }
    try installErrorCause(self, o, arg(args, 2));
    const items = try self.iterableItems(arg(args, 0));
    defer self.gc_allocator.free(items);
    var list = try self.gcNewArray();
    for (items) |e| _ = try list.asArray().value.push(e.retain());
    try o.asObject().value.defineProperty("errors", list, hidden);
    return o;
}

pub fn newSuppressedError(self: *Interpreter, err_val: JSValue, suppressed_val: JSValue, message: ?[]const u8) !JSValue {
    var o = try self.gcNewObject();
    errdefer o.deinit();
    o.asObject().value.is_error_data = true;
    try o.asObject().value.setPrototype(&self.protos.suppressed_error.asObject().value);
    if (message) |m| try o.asObject().value.defineProperty("message", try self.gcNewString(m), hidden);
    try o.asObject().value.defineProperty("error", err_val.retain(), hidden);
    try o.asObject().value.defineProperty("suppressed", suppressed_val.retain(), hidden);
    return o;
}

/// SuppressedError(error, suppressed, message), with or without `new`:
/// message first, then `error` and `suppressed` own properties.
fn suppressedErrorConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const o: JSValue = if (self.construct_target == ctx and this_value.tag() == .object) this_value.retain() else blk: {
        var fresh = try self.gcNewObject();
        try fresh.asObject().value.setPrototype(&self.protos.suppressed_error.asObject().value);
        break :blk fresh;
    };
    errdefer o.deinit();
    o.asObject().value.is_error_data = true;
    const msg_v = arg(args, 2);
    if (msg_v.tag() != .undefined) {
        if (msg_v.tag() == .symbol) return self.throwError(.type_error, "Cannot convert a Symbol value to a string", .{});
        const m = try self.toDisplayStringJS(allocator, msg_v);
        defer allocator.free(m);
        try o.asObject().value.defineProperty("message", try self.gcNewString(m), hidden);
    }
    try o.asObject().value.defineProperty("error", arg(args, 0).retain(), hidden);
    try o.asObject().value.defineProperty("suppressed", arg(args, 1).retain(), hidden);
    return o;
}

/// The `AggregateError` global and its prototype, and NativeError
/// prototypes chained to Error.prototype. Runs from materializeProtos,
/// once Error.prototype exists.
pub fn installAggregate(self: *Interpreter) !void {
    const eproto = self.protos.@"error";
    const ector = self.global_env.get("Error").?;
    try eproto.asObject().value.defineProperty("constructor", ector.retain(), hidden);
    try eproto.asObject().value.defineProperty("name", try self.gcNewString("Error"), hidden);
    try eproto.asObject().value.defineProperty("message", try self.gcNewString(""), hidden);

    inline for (.{
        "EvalError",
        "RangeError",
        "ReferenceError",
        "SyntaxError",
        "TypeError",
        "URIError",
    }) |name| {
        const nctor = self.global_env.get(name).?;
        const nproto = try self.functionPrototype(nctor);
        try nproto.asObject().value.setPrototype(&self.protos.@"error".asObject().value);
        try nproto.asObject().value.defineProperty("constructor", nctor.retain(), hidden);
        try nproto.asObject().value.defineProperty("name", try self.gcNewString(name), hidden);
        try nproto.asObject().value.defineProperty("message", try self.gcNewString(""), hidden);
    }

    const ctor = try builtin_helpers.installBuiltin(self, .{ .name = "AggregateError", .ctor = .{ .arity = 2, .call = aggregateErrorConstructor, .constructable = true } });
    const proto = try self.functionPrototype(ctor);
    try proto.asObject().value.setPrototype(&self.protos.@"error".asObject().value);
    try proto.asObject().value.defineProperty("constructor", ctor.retain(), hidden);
    try proto.asObject().value.defineProperty("name", try self.gcNewString("AggregateError"), hidden);
    try proto.asObject().value.defineProperty("message", try self.gcNewString(""), hidden);
    self.protos.aggregate_error = proto;

    const sctor = try builtin_helpers.installBuiltin(self, .{ .name = "SuppressedError", .ctor = .{ .arity = 3, .call = suppressedErrorConstructor, .constructable = true } });
    const sproto = try self.functionPrototype(sctor);
    try sproto.asObject().value.setPrototype(&self.protos.@"error".asObject().value);
    try sproto.asObject().value.defineProperty("constructor", sctor.retain(), hidden);
    try sproto.asObject().value.defineProperty("name", try self.gcNewString("SuppressedError"), hidden);
    try sproto.asObject().value.defineProperty("message", try self.gcNewString(""), hidden);
    self.protos.suppressed_error = sproto;
}
