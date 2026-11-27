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
const inspect = @import("inspect.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const string_builtins = @import("string_builtins.zig");

const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;
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
    const msg = try self.toDisplayStringJS(allocator, arg(args, 0));
    defer allocator.free(msg);
    try self.console_writer.writeAll(msg);
    try self.console_writer.writeByte('\n');
    return JSValue.UNDEFINED;
}

// ===== Loose globals =====

pub fn globalParseInt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const s = try argString(self, allocator, args, 0);
    defer allocator.free(s);
    const radix: ?f64 = if (arg(args, 1).tag() == .undefined) null else try self.toNumberJS(arg(args, 1));
    return JSValue.fromNumber(try znumber.ParsingMethods.parseInt(allocator, s, radix));
}

pub fn globalParseFloat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const s = try argString(interp(ctx), allocator, args, 0);
    defer allocator.free(s);
    return JSValue.fromNumber(znumber.ParsingMethods.parseFloat(s));
}

fn globalIsNaN(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    return JSValue.fromBool(std.math.isNan(try interp(ctx).toNumberJS(arg(args, 0))));
}

fn globalIsFinite(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const n = try interp(ctx).toNumberJS(arg(args, 0));
    return JSValue.fromBool(!std.math.isNan(n) and !std.math.isInf(n));
}

/// ECMA-262 19.2.6.4/19.2.6.1: percent-encode everything outside
/// uriReserved+uriUnescaped+"#".
pub fn globalEncodeURI(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const a0 = arg(args, 0);
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    const s = if (a0.isString()) a0.asString().value.data else blk: {
        const str = try argString(interp(ctx), allocator, args, 0);
        owned = str;
        break :blk str;
    };
    const encoded = zurlcode.encode(allocator, s, .uri) catch |err| switch (err) {
        error.InvalidUtf8 => return interp(ctx).throwError(.uri_error, "URI malformed", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(encoded);
    return interp(ctx).gcNewString(encoded);
}

/// ECMA-262 19.2.6.5/19.2.6.1: percent-encode everything outside
/// uriUnescaped (uriReserved gets encoded too, unlike encodeURI).
pub fn globalEncodeURIComponent(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const a0 = arg(args, 0);
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    const s = if (a0.isString()) a0.asString().value.data else blk: {
        const str = try argString(interp(ctx), allocator, args, 0);
        owned = str;
        break :blk str;
    };
    const encoded = zurlcode.encode(allocator, s, .component) catch |err| switch (err) {
        error.InvalidUtf8 => return interp(ctx).throwError(.uri_error, "URI malformed", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(encoded);
    return interp(ctx).gcNewString(encoded);
}

fn hexDigitFast(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => null,
    };
}

fn hexByteFast(hi: u8, lo: u8) ?u8 {
    const h = hexDigitFast(hi) orelse return null;
    const l = hexDigitFast(lo) orelse return null;
    return (h << 4) | l;
}

fn isUriReservedFast(c: u8) bool {
    return switch (c) {
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => true,
        else => false,
    };
}

/// Stack fast-path for short strings (`s.len <= 64`) in decodeURI / decodeURIComponent.
/// Avoids heap ArrayList growth + allocation + free on every call.
fn decodeShortFast(s: []const u8, keep_reserved: bool, out: *[64]u8) ?[]const u8 {
    if (s.len > 64) return null;
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '%') {
            out[out_len] = s[i];
            out_len += 1;
            i += 1;
            continue;
        }
        if (i + 3 > s.len) return null;
        const b0 = hexByteFast(s[i + 1], s[i + 2]) orelse return null;
        const n: u3 = if (b0 & 0x80 == 0) 1 else if (b0 & 0xE0 == 0xC0) 2 else if (b0 & 0xF0 == 0xE0) 3 else if (b0 & 0xF8 == 0xF0) 4 else return null;
        if (n == 1) {
            if (keep_reserved and isUriReservedFast(b0)) {
                @memcpy(out[out_len .. out_len + 3], s[i .. i + 3]);
                out_len += 3;
            } else {
                out[out_len] = b0;
                out_len += 1;
            }
            i += 3;
            continue;
        }
        var octets: [4]u8 = undefined;
        octets[0] = b0;
        var pos = i + 3;
        var k: u3 = 1;
        while (k < n) : (k += 1) {
            if (pos + 3 > s.len or s[pos] != '%') return null;
            octets[k] = hexByteFast(s[pos + 1], s[pos + 2]) orelse return null;
            if (octets[k] & 0xC0 != 0x80) return null;
            pos += 3;
        }
        _ = switch (n) {
            2 => std.unicode.utf8Decode2(octets[0..2].*),
            3 => std.unicode.utf8Decode3(octets[0..3].*),
            4 => std.unicode.utf8Decode4(octets[0..4].*),
            else => unreachable,
        } catch return null;
        @memcpy(out[out_len .. out_len + n], octets[0..n]);
        out_len += n;
        i = pos;
    }
    return out[0..out_len];
}

/// ECMA-262 19.2.6.2/19.2.6.1: unescape %XY sequences, leaving a
/// reserved-set (uriReserved+"#") %XY literal rather than decoding it.
pub fn globalDecodeURI(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const a0 = arg(args, 0);
    if (a0.isString()) {
        var sbuf: [64]u8 = undefined;
        if (decodeShortFast(a0.asString().value.data, true, &sbuf)) |fast| {
            return interp(ctx).gcNewString(fast);
        }
    }
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    const s = if (a0.isString()) a0.asString().value.data else blk: {
        const str = try argString(interp(ctx), allocator, args, 0);
        owned = str;
        break :blk str;
    };
    const decoded = zurlcode.decode(allocator, s, true) catch |err| switch (err) {
        error.MalformedUri => return interp(ctx).throwError(.uri_error, "URI malformed", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(decoded);
    return interp(ctx).gcNewString(decoded);
}

/// ECMA-262 19.2.6.3/19.2.6.1: unescape every %XY sequence, no exceptions.
pub fn globalDecodeURIComponent(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const a0 = arg(args, 0);
    if (a0.isString()) {
        var sbuf: [64]u8 = undefined;
        if (decodeShortFast(a0.asString().value.data, false, &sbuf)) |fast| {
            return interp(ctx).gcNewString(fast);
        }
    }
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    const s = if (a0.isString()) a0.asString().value.data else blk: {
        const str = try argString(interp(ctx), allocator, args, 0);
        owned = str;
        break :blk str;
    };
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
    if (a.tag() != .string) return a.retain();
    const global_scope = self.global_var_env orelse self.script_env orelse self.global_env;
    return self.evalSourceIndirect(global_scope, a.asString().value.data);
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
        .{ .name = "log", .value = .{ .method = .{ .call = consoleLog, .arity = 0 } } },
        .{ .name = "info", .value = .{ .method = .{ .call = consoleLog, .arity = 0 } } },
        .{ .name = "debug", .value = .{ .method = .{ .call = consoleLog, .arity = 0 } } },
        .{ .name = "error", .value = .{ .method = .{ .call = consoleError, .arity = 0 } } },
        .{ .name = "warn", .value = .{ .method = .{ .call = consoleError, .arity = 0 } } },
    } });
    try g.define(arena, "print", try native(self, "print", 1, globalPrint));

    const eval_fn = try native(self, "eval", 1, globalEval);
    // self.eval_fn needs its OWN retained reference -- see the same fix
    // on symbol_iterator/global_object for why (an interpreter field
    // aliasing a reassignable global binding, without its own retain, is
    // left dangling the moment that binding's old value gets released).
    self.eval_fn = eval_fn.retain();
    try g.define(arena, "eval", eval_fn);

    try g.define(arena, "parseInt", try native(self, "parseInt", 2, globalParseInt));
    try g.define(arena, "parseFloat", try native(self, "parseFloat", 1, globalParseFloat));
    try g.define(arena, "isNaN", try native(self, "isNaN", 1, globalIsNaN));
    try g.define(arena, "isFinite", try native(self, "isFinite", 1, globalIsFinite));

    try g.define(arena, "encodeURI", try native(self, "encodeURI", 1, globalEncodeURI));
    try g.define(arena, "encodeURIComponent", try native(self, "encodeURIComponent", 1, globalEncodeURIComponent));
    try g.define(arena, "decodeURI", try native(self, "decodeURI", 1, globalDecodeURI));
    try g.define(arena, "decodeURIComponent", try native(self, "decodeURIComponent", 1, globalDecodeURIComponent));
}
