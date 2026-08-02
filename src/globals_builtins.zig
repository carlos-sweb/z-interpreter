//! The "loose globals" grab-bag: `console`/`print` (host-shell-style
//! core globals), `parseInt`/`parseFloat`/`isNaN`/`isFinite`, and
//! indirect `eval`. The final piece of Step 5 Phase A -- everything
//! else in the original monolithic builtins.zig now has its own
//! domain file. `globalParseInt`/`globalParseFloat` stay `pub`:
//! `number_builtins.zig` imports this file directly for
//! `Number.parseInt`/`Number.parseFloat` (which reuse the global
//! versions per spec) instead of reaching through builtins.zig.
//! z-interpreter-refactor.md, Step 5 Phase A batch 10.

const std = @import("std");
const Allocator = std.mem.Allocator;
const znumber = @import("znumber");
const zvalue = @import("zvalue");
const zurlcode = @import("zurlcode");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const inspect = @import("inspect.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const string_builtins = @import("string_builtins.zig");

const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;
const toIntSat = builtin_helpers.toIntSat;
const argString = string_builtins.argString;

// ===== console =====

fn consoleLog(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    try inspect.writeConsoleLog(allocator, self.console_writer, args);
    return JSValue.UNDEFINED;
}

fn consoleError(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    try inspect.writeConsoleLog(allocator, self.console_error_writer, args);
    return JSValue.UNDEFINED;
}

/// `print(msg)`: writes ToString(msg) + a newline. A d8/jsshell/qjs-style
/// core global (not host-specific like `os` -- it's exactly as fundamental
/// as `console`, which already lives here), and notably what Test262's own
/// harness (doneprintHandle.js's $DONE) uses to report async-test
/// completion -- so this also makes the runner able to detect "did an
/// async test finish" for every async/async-generator test that reaches
/// $DONE, not just this phase's own tests.
fn globalPrint(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const msg = try coercion.toDisplayString(allocator, arg(args, 0));
    defer allocator.free(msg);
    try self.console_writer.writeAll(msg);
    try self.console_writer.writeByte('\n');
    return JSValue.UNDEFINED;
}

// ===== Loose globals =====

pub fn globalParseInt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    const s = try argString(allocator, args, 0);
    defer allocator.free(s);
    const radix: ?u8 = if (arg(args, 1) == .undefined) null else blk: {
        // Clamp into u8; out-of-[2,36] values are left for parseInt to reject
        // (as NaN). Avoids @intFromFloat panicking on NaN/Infinity/huge radix.
        const r = toIntSat(try coercion.toNumber(arg(args, 1)));
        break :blk if (r >= 0 and r <= 36) @intCast(r) else 255;
    };
    return JSValue.fromNumber(znumber.ParsingMethods.parseInt(allocator, s, radix));
}

pub fn globalParseFloat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    const s = try argString(allocator, args, 0);
    defer allocator.free(s);
    return JSValue.fromNumber(znumber.ParsingMethods.parseFloat(s));
}

fn globalIsNaN(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    return JSValue.fromBool(std.math.isNan(try coercion.toNumber(arg(args, 0))));
}

fn globalIsFinite(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const n = try coercion.toNumber(arg(args, 0));
    return JSValue.fromBool(!std.math.isNan(n) and !std.math.isInf(n));
}

/// ECMA-262 19.2.6.4/19.2.6.1: percent-encode everything outside
/// uriReserved+uriUnescaped+"#".
fn globalEncodeURI(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const s = try argString(allocator, args, 0);
    defer allocator.free(s);
    const encoded = zurlcode.encode(allocator, s, .uri) catch |err| switch (err) {
        error.InvalidUtf8 => unreachable, // ZString's data is always valid UTF-8
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(encoded);
    return interp(ctx).gcNewString(encoded);
}

/// ECMA-262 19.2.6.5/19.2.6.1: percent-encode everything outside
/// uriUnescaped (uriReserved gets encoded too, unlike encodeURI).
fn globalEncodeURIComponent(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const s = try argString(allocator, args, 0);
    defer allocator.free(s);
    const encoded = zurlcode.encode(allocator, s, .component) catch |err| switch (err) {
        error.InvalidUtf8 => unreachable, // ZString's data is always valid UTF-8
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(encoded);
    return interp(ctx).gcNewString(encoded);
}

/// ECMA-262 19.2.6.2/19.2.6.1: unescape %XY sequences, leaving a
/// reserved-set (uriReserved+"#") %XY literal rather than decoding it.
fn globalDecodeURI(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const s = try argString(allocator, args, 0);
    defer allocator.free(s);
    const decoded = zurlcode.decode(allocator, s, true) catch |err| switch (err) {
        error.MalformedUri => return interp(ctx).throwError(.uri_error, "URI malformed", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(decoded);
    return interp(ctx).gcNewString(decoded);
}

/// ECMA-262 19.2.6.3/19.2.6.1: unescape every %XY sequence, no exceptions.
fn globalDecodeURIComponent(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const s = try argString(allocator, args, 0);
    defer allocator.free(s);
    const decoded = zurlcode.decode(allocator, s, false) catch |err| switch (err) {
        error.MalformedUri => return interp(ctx).throwError(.uri_error, "URI malformed", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(decoded);
    return interp(ctx).gcNewString(decoded);
}

/// Indirect `eval` (called as a plain value, not the literal `eval(...)`
/// form): runs its string argument in the GLOBAL scope. A non-string
/// argument is returned unchanged. Direct eval is handled in evalCall.
fn globalEval(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const a = arg(args, 0);
    if (a != .string) return a.retain();
    return self.evalSource(self.global_env, a.string.value.data);
}

/// Installs `console`/`print`, `parseInt`/`parseFloat`/`isNaN`/
/// `isFinite`, and indirect `eval`.
pub fn install(self: *Interpreter) !void {
    const arena = self.gc_allocator;
    const g = self.global_env;

    // Real Node: log/info/debug -> stdout, error/warn -> stderr (verified
    // against actual Node, not assumed) -- same rendering either way,
    // only the destination writer differs. See consoleLog/consoleError.
    _ = try installBuiltin(self, .{ .name = "console", .statics = &.{
        .{ .name = "log", .value = .{ .method = consoleLog } },
        .{ .name = "info", .value = .{ .method = consoleLog } },
        .{ .name = "debug", .value = .{ .method = consoleLog } },
        .{ .name = "error", .value = .{ .method = consoleError } },
        .{ .name = "warn", .value = .{ .method = consoleError } },
    } });
    try g.define(arena, "print", try native(self, "print", globalPrint));

    const eval_fn = try native(self, "eval", globalEval);
    // self.eval_fn needs its OWN retained reference -- see the same fix
    // on symbol_iterator/global_object for why (an interpreter field
    // aliasing a reassignable global binding, without its own retain, is
    // left dangling the moment that binding's old value gets released).
    self.eval_fn = eval_fn.retain();
    try g.define(arena, "eval", eval_fn);

    try g.define(arena, "parseInt", try native(self, "parseInt", globalParseInt));
    try g.define(arena, "parseFloat", try native(self, "parseFloat", globalParseFloat));
    try g.define(arena, "isNaN", try native(self, "isNaN", globalIsNaN));
    try g.define(arena, "isFinite", try native(self, "isFinite", globalIsFinite));

    try g.define(arena, "encodeURI", try native(self, "encodeURI", globalEncodeURI));
    try g.define(arena, "encodeURIComponent", try native(self, "encodeURIComponent", globalEncodeURIComponent));
    try g.define(arena, "decodeURI", try native(self, "decodeURI", globalDecodeURI));
    try g.define(arena, "decodeURIComponent", try native(self, "decodeURIComponent", globalDecodeURIComponent));
}
