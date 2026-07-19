//! Native bindings exposing the z-* ecosystem's already-implemented
//! methods to JS code: `[1,2].push(3)`, `'abc'.toUpperCase()`,
//! `Math.floor(x)`, `JSON.stringify(o)`, `Object.keys(o)`, `parseInt`...
//!
//! Every native's `ctx` is the `*Interpreter` (stable by the time
//! `setupGlobals` runs -- it's called lazily from `run()`, never from
//! `Interpreter.init`, which returns by value). That gives natives the
//! arena, `throwError` (catchable TypeErrors/SyntaxErrors), and the
//! ability to invoke JS callbacks (map/filter/reduce) via
//! `Callable.call`. Methods are shared per (type, name) -- `evalCall`
//! already passes the receiver as `this_value` for member calls, so no
//! per-receiver binding is needed; a detached call (`const f = a.push;
//! f()`) fails with a TypeError like real JS.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const zmath = @import("zmath");
const zjson = @import("zjson");
const zstring = @import("zstring");
const zdate = @import("zdate");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const inspect = @import("inspect.zig");

pub const NativeFn = *const fn (ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue;

fn interp(ctx: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(ctx));
}

fn arg(args: []const JSValue, i: usize) JSValue {
    return if (i < args.len) args[i] else JSValue.UNDEFINED;
}

// ===== Method tables (consulted by the interpreter's getProperty) =====

pub const array_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "push", arrayPush },
    .{ "pop", arrayPop },
    .{ "shift", arrayShift },
    .{ "unshift", arrayUnshift },
    .{ "indexOf", arrayIndexOf },
    .{ "includes", arrayIncludes },
    .{ "join", arrayJoin },
    .{ "slice", arraySlice },
    .{ "concat", arrayConcat },
    .{ "reverse", arrayReverse },
    .{ "map", arrayMap },
    .{ "filter", arrayFilter },
    .{ "forEach", arrayForEach },
    .{ "reduce", arrayReduce },
    .{ "find", arrayFind },
    .{ "some", arraySome },
    .{ "every", arrayEvery },
});

pub const date_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "getTime", dateGetTime },
    .{ "getFullYear", dateGetter("getFullYear") },
    .{ "getMonth", dateGetter("getMonth") },
    .{ "getDate", dateGetter("getDate") },
    .{ "getDay", dateGetter("getDay") },
    .{ "getHours", dateGetter("getHours") },
    .{ "getMinutes", dateGetter("getMinutes") },
    .{ "getSeconds", dateGetter("getSeconds") },
    .{ "toISOString", dateToISOString },
});

pub const promise_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "then", promiseThen },
    .{ "catch", promiseCatch },
    .{ "finally", promiseFinally },
});

pub const function_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "call", fnCall },
    .{ "apply", fnApply },
    .{ "bind", fnBind },
});

pub const string_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "toUpperCase", stringToUpperCase },
    .{ "toLowerCase", stringToLowerCase },
    .{ "charAt", stringCharAt },
    .{ "indexOf", stringIndexOf },
    .{ "includes", stringIncludes },
    .{ "startsWith", stringStartsWith },
    .{ "endsWith", stringEndsWith },
    .{ "slice", stringSlice },
    .{ "repeat", stringRepeat },
    .{ "split", stringSplit },
    .{ "trim", stringTrim },
});

// ===== Globals =====

/// Installs every global binding. Called lazily from `run()` (never from
/// init) so `self: *Interpreter` is a stable address for native ctx.
pub fn setupGlobals(self: *Interpreter) !void {
    const arena = self.arena_state.allocator();
    const g = self.global_env;

    try g.define(arena, "undefined", JSValue.UNDEFINED);
    try g.define(arena, "NaN", JSValue.fromNumber(std.math.nan(f64)));
    try g.define(arena, "Infinity", JSValue.fromNumber(std.math.inf(f64)));

    var console_obj = try JSValue.newObject(arena);
    try console_obj.object.value.set("log", try native(self, "log", consoleLog));
    try g.define(arena, "console", console_obj);

    var math_obj = try JSValue.newObject(arena);
    try math_obj.object.value.set("PI", JSValue.fromNumber(zmath.PI));
    try math_obj.object.value.set("E", JSValue.fromNumber(zmath.E));
    try math_obj.object.value.set("floor", try native(self, "floor", mathFloor));
    try math_obj.object.value.set("ceil", try native(self, "ceil", mathCeil));
    try math_obj.object.value.set("round", try native(self, "round", mathRound));
    try math_obj.object.value.set("trunc", try native(self, "trunc", mathTrunc));
    try math_obj.object.value.set("abs", try native(self, "abs", mathAbs));
    try math_obj.object.value.set("sign", try native(self, "sign", mathSign));
    try math_obj.object.value.set("sqrt", try native(self, "sqrt", mathSqrt));
    try math_obj.object.value.set("pow", try native(self, "pow", mathPow));
    try math_obj.object.value.set("min", try native(self, "min", mathMin));
    try math_obj.object.value.set("max", try native(self, "max", mathMax));
    try math_obj.object.value.set("random", try native(self, "random", mathRandom));
    try g.define(arena, "Math", math_obj);

    var json_obj = try JSValue.newObject(arena);
    try json_obj.object.value.set("stringify", try native(self, "stringify", jsonStringify));
    try json_obj.object.value.set("parse", try native(self, "parse", jsonParse));
    try g.define(arena, "JSON", json_obj);

    // Plain objects, not constructor functions -- functions here have no
    // general property bag (documented gap): typeof Object == "object",
    // and `new Object()` doesn't exist.
    var object_obj = try JSValue.newObject(arena);
    try object_obj.object.value.set("keys", try native(self, "keys", objectKeys));
    try object_obj.object.value.set("values", try native(self, "values", objectValues));
    try object_obj.object.value.set("entries", try native(self, "entries", objectEntries));
    try object_obj.object.value.set("assign", try native(self, "assign", objectAssign));
    try g.define(arena, "Object", object_obj);

    var array_obj = try JSValue.newObject(arena);
    try array_obj.object.value.set("isArray", try native(self, "isArray", arrayIsArray));
    try g.define(arena, "Array", array_obj);

    // A real constructable native: `new Date(...)` works through evalNew's
    // object-like-return-overrides rule (a .date return replaces the plain
    // instance). `Date.now()` is NOT available -- functions here have no
    // property bag; `new Date().getTime()` is the equivalent.
    const date_ctor = try JSValue.newFunction(arena, .{
        .ctx = self,
        .name = "Date",
        .call = dateConstructor,
        .constructable = true,
    });
    try g.define(arena, "Date", date_ctor);

    // Error constructors -- `new Error('msg')` (and `Error('msg')`, which
    // real JS also allows) produce catchable/throwable .error values of
    // the right kind.
    inline for (.{
        .{ "Error", zvalue.ErrorKind.generic },
        .{ "TypeError", zvalue.ErrorKind.type_error },
        .{ "RangeError", zvalue.ErrorKind.range_error },
        .{ "SyntaxError", zvalue.ErrorKind.syntax_error },
        .{ "ReferenceError", zvalue.ErrorKind.reference_error },
    }) |entry| {
        const ctor = try JSValue.newFunction(arena, .{
            .ctx = self,
            .name = entry[0],
            .arity = 1,
            .call = errorConstructor(entry[1]),
            .constructable = true,
        });
        try g.define(arena, entry[0], ctor);
    }

    // Promise: constructable native; the statics (resolve/reject/all/
    // race) ride the phase-10 property bag.
    const promise_ctor = try JSValue.newFunction(arena, .{
        .ctx = self,
        .name = "Promise",
        .arity = 1,
        .call = promiseConstructor,
        .constructable = true,
    });
    const promise_statics = try self.functionStatics(promise_ctor);
    try promise_statics.object.value.set("resolve", try native(self, "resolve", promiseResolveStatic));
    try promise_statics.object.value.set("reject", try native(self, "reject", promiseRejectStatic));
    try promise_statics.object.value.set("all", try native(self, "all", promiseAll));
    try promise_statics.object.value.set("race", try native(self, "race", promiseRace));
    try g.define(arena, "Promise", promise_ctor);

    try g.define(arena, "setTimeout", try native(self, "setTimeout", globalSetTimeout));
    try g.define(arena, "clearTimeout", try native(self, "clearTimeout", globalClearTimeout));

    try g.define(arena, "parseInt", try native(self, "parseInt", globalParseInt));
    try g.define(arena, "parseFloat", try native(self, "parseFloat", globalParseFloat));
    try g.define(arena, "isNaN", try native(self, "isNaN", globalIsNaN));
    try g.define(arena, "isFinite", try native(self, "isFinite", globalIsFinite));
    try g.define(arena, "String", try native(self, "String", globalString));
    try g.define(arena, "Number", try native(self, "Number", globalNumber));
    try g.define(arena, "Boolean", try native(self, "Boolean", globalBoolean));
}

fn native(self: *Interpreter, name: []const u8, call_fn: NativeFn) !JSValue {
    return JSValue.newFunction(self.arena_state.allocator(), .{
        .ctx = self,
        .name = name,
        .call = call_fn,
    });
}

// ===== console =====

fn consoleLog(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    try inspect.writeConsoleLog(allocator, self.console_writer, args);
    return JSValue.UNDEFINED;
}

// ===== Array.prototype =====

fn requireArray(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!void {
    if (this_value != .array) {
        return interp(ctx).throwError(.type_error, "Array.prototype.{s} called on a non-array", .{method});
    }
}

fn requireCallback(ctx: *anyopaque, args: []const JSValue) anyerror!JSValue {
    const cb = arg(args, 0);
    if (cb != .function) return interp(ctx).throwError(.type_error, "callback is not a function", .{});
    return cb;
}

fn callCallback(cb: JSValue, allocator: Allocator, item: JSValue, index: usize, receiver: JSValue) anyerror!JSValue {
    return cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{
        item, JSValue.fromNumber(@floatFromInt(index)), receiver,
    });
}

fn arrayPush(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "push");
    for (args) |a| _ = try this_value.array.value.push(a.retain());
    return JSValue.fromNumber(@floatFromInt(this_value.array.value.length()));
}

fn arrayPop(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    try requireArray(ctx, this_value, "pop");
    return this_value.array.value.pop() orelse JSValue.UNDEFINED;
}

fn arrayShift(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    try requireArray(ctx, this_value, "shift");
    return this_value.array.value.shift() orelse JSValue.UNDEFINED;
}

fn arrayUnshift(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "unshift");
    // Insert in reverse so the args end up in order at the front.
    var i = args.len;
    while (i > 0) {
        i -= 1;
        _ = try this_value.array.value.unshift(args[i].retain());
    }
    return JSValue.fromNumber(@floatFromInt(this_value.array.value.length()));
}

fn arrayIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "indexOf");
    const idx = this_value.array.value.indexOf(arg(args, 0), null) orelse return JSValue.fromNumber(-1);
    return JSValue.fromNumber(@floatFromInt(idx));
}

fn arrayIncludes(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "includes");
    return JSValue.fromBool(this_value.array.value.includes(arg(args, 0), null));
}

fn arrayJoin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "join");
    const sep = if (arg(args, 0) == .string) arg(args, 0).string.value.data else ",";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        if (i != 0) try buf.appendSlice(allocator, sep);
        switch (item) {
            .@"undefined", .@"null" => {},
            else => {
                const s = try coercion.toDisplayString(allocator, item);
                defer allocator.free(s);
                try buf.appendSlice(allocator, s);
            },
        }
    }
    return JSValue.newString(allocator, buf.items);
}

fn arraySlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "slice");
    const len: f64 = @floatFromInt(this_value.array.value.length());
    var start: f64 = if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0));
    var end: f64 = if (arg(args, 1) == .@"undefined") len else try coercion.toNumber(arg(args, 1));
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    start = @min(start, len);
    end = @min(end, len);
    var result = try JSValue.newArray(allocator);
    var i: usize = @intFromFloat(start);
    const end_idx: usize = @intFromFloat(end);
    while (i < end_idx) : (i += 1) {
        _ = try result.array.value.push(this_value.array.value.get(i).retain());
    }
    return result;
}

fn arrayConcat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "concat");
    var result = try JSValue.newArray(allocator);
    for (this_value.array.value.toSlice()) |item| _ = try result.array.value.push(item.retain());
    for (args) |a| {
        if (a == .array) {
            for (a.array.value.toSlice()) |item| _ = try result.array.value.push(item.retain());
        } else {
            _ = try result.array.value.push(a.retain());
        }
    }
    return result;
}

fn arrayReverse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    try requireArray(ctx, this_value, "reverse");
    this_value.array.value.reverse();
    return this_value.retain();
}

fn arrayMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "map");
    const cb = try requireCallback(ctx, args);
    var result = try JSValue.newArray(allocator);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        const v = try callCallback(cb, allocator, item, i, this_value);
        _ = try result.array.value.push(v.retain());
    }
    return result;
}

fn arrayFilter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "filter");
    const cb = try requireCallback(ctx, args);
    var result = try JSValue.newArray(allocator);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) {
            _ = try result.array.value.push(item.retain());
        }
    }
    return result;
}

fn arrayForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        _ = try callCallback(cb, allocator, item, i, this_value);
    }
    return JSValue.UNDEFINED;
}

fn arrayReduce(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "reduce");
    const cb = try requireCallback(ctx, args);
    const slice = this_value.array.value.toSlice();
    var acc: JSValue = undefined;
    var start: usize = 0;
    if (args.len > 1) {
        acc = args[1];
    } else {
        if (slice.len == 0) return interp(ctx).throwError(.type_error, "Reduce of empty array with no initial value", .{});
        acc = slice[0];
        start = 1;
    }
    for (slice[start..], start..) |item, i| {
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{
            acc, item, JSValue.fromNumber(@floatFromInt(i)), this_value,
        });
    }
    return acc;
}

fn arrayFind(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "find");
    const cb = try requireCallback(ctx, args);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return item.retain();
    }
    return JSValue.UNDEFINED;
}

fn arraySome(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "some");
    const cb = try requireCallback(ctx, args);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

fn arrayEvery(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "every");
    const cb = try requireCallback(ctx, args);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        if (!coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromBool(false);
    }
    return JSValue.fromBool(true);
}

fn arrayIsArray(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    return JSValue.fromBool(arg(args, 0) == .array);
}

// ===== String.prototype (direct reuse of z-string's standalone method
// modules, all operating on ([]const u8, allocator)) =====

fn requireString(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror![]const u8 {
    if (this_value != .string) {
        return interp(ctx).throwError(.type_error, "String.prototype.{s} called on a non-string", .{method});
    }
    return this_value.string.value.data;
}

fn argString(allocator: Allocator, args: []const JSValue, i: usize) ![]u8 {
    return coercion.toDisplayString(allocator, arg(args, i));
}

fn stringToUpperCase(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "toUpperCase");
    const out = try zstring.case.toUpperCase(allocator, data);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringToLowerCase(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "toLowerCase");
    const out = try zstring.case.toLowerCase(allocator, data);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringCharAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "charAt");
    const idx: isize = @intFromFloat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    const out = try zstring.access.charAt(allocator, data, idx);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "indexOf");
    const search = try argString(allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromNumber(@floatFromInt(zstring.search.indexOf(data, search, null)));
}

fn stringIncludes(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "includes");
    const search = try argString(allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromBool(zstring.search.includes(data, search, null));
}

fn stringStartsWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "startsWith");
    const search = try argString(allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromBool(zstring.search.startsWith(data, search, null));
}

fn stringEndsWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "endsWith");
    const search = try argString(allocator, args, 0);
    defer allocator.free(search);
    return JSValue.fromBool(zstring.search.endsWith(data, search, null));
}

fn stringSlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "slice");
    const start: isize = @intFromFloat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .@"undefined") null else @intFromFloat(try coercion.toNumber(arg(args, 1)));
    const out = try zstring.transform.slice(allocator, data, start, end);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringRepeat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "repeat");
    const count: isize = @intFromFloat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    if (count < 0) return interp(ctx).throwError(.range_error, "Invalid count value: {d}", .{count});
    const out = try zstring.transform.repeat(allocator, data, count);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringSplit(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "split");
    const sep: ?[]const u8 = if (arg(args, 0) == .string) arg(args, 0).string.value.data else null;
    const parts = try zstring.split.split(allocator, data, sep, null);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    var result = try JSValue.newArray(allocator);
    for (parts) |p| {
        _ = try result.array.value.push(try JSValue.newString(allocator, p));
    }
    return result;
}

fn stringTrim(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "trim");
    const out = try zstring.trimming.trim(allocator, data);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

// ===== Date =====

/// Milliseconds since the Unix epoch via the raw Linux syscall -- this
/// Zig version's portable clock API needs an std.Io instance, which the
/// interpreter doesn't thread (Linux-only for now, like the dev setup).
pub fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// `new Date()` -> now; `new Date(ms)` -> from timestamp; `new Date(str)`
/// -> parsed. Also returns a .date when called WITHOUT `new` (real JS
/// returns a string there -- documented divergence).
fn dateConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    if (args.len == 0) return JSValue.newDate(allocator, nowMs());
    const first = args[0];
    if (first == .string) {
        const d = zvalue.ZDate.fromString(first.string.value.data);
        return JSValue.newDate(allocator, d.timestamp);
    }
    return JSValue.newDate(allocator, @intFromFloat(try coercion.toNumber(first)));
}

fn requireDate(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    if (this_value != .date) {
        return interp(ctx).throwError(.type_error, "Date.prototype.{s} called on a non-date", .{method});
    }
    return this_value;
}

fn dateGetTime(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const d = try requireDate(ctx, this_value, "getTime");
    return JSValue.fromNumber(@floatFromInt(d.date.value.getTime()));
}

/// ?i32-returning ZDate getters (null = Invalid Date -> NaN, real JS).
fn dateGetter(comptime method: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = args;
            const d = try requireDate(ctx, this_value, method);
            const v = @field(zvalue.ZDate, method)(d.date.value) orelse return JSValue.fromNumber(std.math.nan(f64));
            return JSValue.fromNumber(@floatFromInt(v));
        }
    }.call;
}

fn dateToISOString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const d = try requireDate(ctx, this_value, "toISOString");
    const iso = d.date.value.toISOString(allocator) catch
        return interp(ctx).throwError(.range_error, "Invalid time value", .{});
    defer allocator.free(iso);
    return JSValue.newString(allocator, iso);
}

// ===== Math =====

fn mathUnary(comptime f: fn (f64) f64) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = ctx;
            _ = allocator;
            _ = this_value;
            return JSValue.fromNumber(f(try coercion.toNumber(arg(args, 0))));
        }
    }.call;
}

const mathFloor = mathUnary(zmath.floor);
const mathCeil = mathUnary(zmath.ceil);
const mathRound = mathUnary(zmath.round);
const mathTrunc = mathUnary(zmath.trunc);
const mathAbs = mathUnary(zmath.abs);
const mathSign = mathUnary(zmath.sign);
const mathSqrt = mathUnary(zmath.sqrt);

fn mathPow(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    return JSValue.fromNumber(std.math.pow(f64, try coercion.toNumber(arg(args, 0)), try coercion.toNumber(arg(args, 1))));
}

fn mathVariadic(ctx: *anyopaque, allocator: Allocator, args: []const JSValue, comptime f: fn ([]const f64) f64) anyerror!JSValue {
    _ = ctx;
    const nums = try allocator.alloc(f64, args.len);
    defer allocator.free(nums);
    for (args, 0..) |a, i| nums[i] = try coercion.toNumber(a);
    return JSValue.fromNumber(f(nums));
}

fn mathMin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return mathVariadic(ctx, allocator, args, zmath.min);
}

fn mathMax(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return mathVariadic(ctx, allocator, args, zmath.max);
}

fn mathRandom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    // Not cryptographic (neither is JS's Math.random). Seeded once per
    // process from ASLR'd addresses -- this Zig version's OS entropy API
    // needs an std.Io instance, which this interpreter doesn't thread.
    const S = struct {
        var prng: ?std.Random.DefaultPrng = null;
    };
    if (S.prng == null) {
        const seed = @intFromPtr(&S.prng) ^ (@intFromPtr(ctx) << 16);
        S.prng = std.Random.DefaultPrng.init(seed);
    }
    return JSValue.fromNumber(S.prng.?.random().float(f64));
}

// ===== JSON =====

fn jsonStringify(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const out = zjson.stringify(allocator, arg(args, 0)) catch |err| switch (err) {
        error.CircularStructure => return interp(ctx).throwError(.type_error, "Converting circular structure to JSON", .{}),
        else => return err,
    };
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn jsonParse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const text = arg(args, 0);
    if (text != .string) return interp(ctx).throwError(.syntax_error, "Unexpected token in JSON", .{});
    return zjson.parse(allocator, text.string.value.data) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // A real, catchable SyntaxError -- matching JSON.parse's spec'd
        // failure mode.
        else => interp(ctx).throwError(.syntax_error, "Unexpected token in JSON", .{}),
    };
}

// ===== Object statics =====

fn requireObject(ctx: *anyopaque, v: JSValue, what: []const u8) anyerror!JSValue {
    if (v != .object) return interp(ctx).throwError(.type_error, "{s} called on a non-object", .{what});
    return v;
}

fn objectKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = try requireObject(ctx, arg(args, 0), "Object.keys");
    const ks = try o.object.value.keys(allocator);
    defer allocator.free(ks);
    var result = try JSValue.newArray(allocator);
    for (ks) |k| _ = try result.array.value.push(try JSValue.newString(allocator, k));
    return result;
}

fn objectValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = try requireObject(ctx, arg(args, 0), "Object.values");
    const ks = try o.object.value.keys(allocator);
    defer allocator.free(ks);
    var result = try JSValue.newArray(allocator);
    // Per-key getProperty (not ZObject.values) so accessor properties
    // invoke their getters, like real Object.values.
    for (ks) |k| _ = try result.array.value.push(try interp(ctx).getProperty(o, k));
    return result;
}

fn objectEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = try requireObject(ctx, arg(args, 0), "Object.entries");
    const ks = try o.object.value.keys(allocator);
    defer allocator.free(ks);
    var result = try JSValue.newArray(allocator);
    for (ks) |k| {
        var pair = try JSValue.newArray(allocator);
        _ = try pair.array.value.push(try JSValue.newString(allocator, k));
        // getProperty, not ZObject.get -- getters must fire here too.
        _ = try pair.array.value.push(try interp(ctx).getProperty(o, k));
        _ = try result.array.value.push(pair);
    }
    return result;
}

fn objectAssign(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const target = try requireObject(ctx, arg(args, 0), "Object.assign");
    for (args[1..]) |source| {
        if (source != .object) continue; // primitives are skipped, like real JS
        const ks = try source.object.value.keys(allocator);
        defer allocator.free(ks);
        for (ks) |k| {
            try target.object.value.set(k, source.object.value.get(k).?.retain());
        }
    }
    return target.retain();
}

// ===== Loose globals =====

fn globalParseInt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    const s = try argString(allocator, args, 0);
    defer allocator.free(s);
    const radix: ?u8 = if (arg(args, 1) == .@"undefined") null else @intFromFloat(try coercion.toNumber(arg(args, 1)));
    return JSValue.fromNumber(znumber.ParsingMethods.parseInt(allocator, s, radix));
}

fn globalParseFloat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
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

fn globalString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    const s = try coercion.toDisplayString(allocator, arg(args, 0));
    defer allocator.free(s);
    return JSValue.newString(allocator, s);
}

fn globalNumber(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    return JSValue.fromNumber(try coercion.toNumber(arg(args, 0)));
}

fn globalBoolean(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    return JSValue.fromBool(coercion.isTruthy(arg(args, 0)));
}

// ===== Promise =====

/// The pair of capabilities `new Promise(executor)` hands the executor.
const PromiseCapCtx = struct {
    interp: *Interpreter,
    promise: JSValue,
};

fn capCtx(ctx: *anyopaque) *PromiseCapCtx {
    return @ptrCast(@alignCast(ctx));
}

fn capResolve(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c = capCtx(ctx);
    try c.interp.resolvePromise(c.promise, arg(args, 0));
    return JSValue.UNDEFINED;
}

fn capReject(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c = capCtx(ctx);
    try c.interp.rejectPromiseValue(c.promise, arg(args, 0));
    return JSValue.UNDEFINED;
}

/// `new Promise(executor)`: executor runs SYNCHRONOUSLY (real spec
/// behavior -- logs inside it appear before the line after `new`); its
/// throw rejects. Calling Promise without `new` also works here (real JS
/// requires new -- documented narrowing).
fn promiseConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const executor = arg(args, 0);
    if (executor != .function) {
        return self.throwError(.type_error, "Promise resolver {s} is not a function", .{executor.typeOf()});
    }
    const p = try JSValue.newPromise(allocator);

    const cap = try allocator.create(PromiseCapCtx);
    cap.* = .{ .interp = self, .promise = p };
    const resolve_fn = try JSValue.newFunction(allocator, .{ .ctx = cap, .name = "resolve", .arity = 1, .call = capResolve });
    const reject_fn = try JSValue.newFunction(allocator, .{ .ctx = cap, .name = "reject", .arity = 1, .call = capReject });

    _ = executor.function.value.call(executor.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ resolve_fn, reject_fn }) catch |err| {
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception.?;
        self.pending_exception = null;
        try self.rejectPromiseValue(p, ex);
    };
    return p;
}

fn requirePromise(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    if (this_value != .promise) {
        return interp(ctx).throwError(.type_error, "Promise.prototype.{s} called on a non-promise", .{method});
    }
    return this_value;
}

/// Non-callable handlers are the spec's pass-through (then(null, f) etc).
fn handlerOrNull(v: JSValue) ?JSValue {
    return if (v == .function) v else null;
}

fn promiseThen(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const p = try requirePromise(ctx, this_value, "then");
    return interp(ctx).promiseThen(p, handlerOrNull(arg(args, 0)), handlerOrNull(arg(args, 1)));
}

fn promiseCatch(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const p = try requirePromise(ctx, this_value, "catch");
    return interp(ctx).promiseThen(p, null, handlerOrNull(arg(args, 0)));
}

/// finally(f) = then(wrapper, wrapper) where each wrapper calls f() with
/// no arguments and passes the original settlement through -- the
/// rejection side by re-throwing the original reason. f's own throw
/// replaces the settlement (both spec behaviors), for free, because the
/// job runner already turns a handler throw into a derived rejection.
const FinallyCtx = struct {
    interp: *Interpreter,
    handler: JSValue,
};

fn finallyCtx(ctx: *anyopaque) *FinallyCtx {
    return @ptrCast(@alignCast(ctx));
}

fn finallyOnFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c = finallyCtx(ctx);
    _ = try c.handler.function.value.call(c.handler.function.value.ctx, allocator, JSValue.UNDEFINED, &.{});
    return arg(args, 0);
}

fn finallyOnRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const c = finallyCtx(ctx);
    _ = try c.handler.function.value.call(c.handler.function.value.ctx, allocator, JSValue.UNDEFINED, &.{});
    return c.interp.throwValue(arg(args, 0).retain());
}

fn promiseFinally(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const p = try requirePromise(ctx, this_value, "finally");
    const self = interp(ctx);
    const handler = handlerOrNull(arg(args, 0)) orelse return self.promiseThen(p, null, null);

    const c = try allocator.create(FinallyCtx);
    c.* = .{ .interp = self, .handler = handler.retain() };
    const on_f = try JSValue.newFunction(allocator, .{ .ctx = c, .name = "", .call = finallyOnFulfilled });
    const on_r = try JSValue.newFunction(allocator, .{ .ctx = c, .name = "", .call = finallyOnRejected });
    return self.promiseThen(p, on_f, on_r);
}

fn promiseResolveStatic(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    // Promise.resolve(promise) returns it unchanged (real behavior).
    if (v == .promise) return v;
    return interp(ctx).fulfilledPromise(v);
}

fn promiseRejectStatic(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    return interp(ctx).rejectedPromise(arg(args, 0));
}

/// Shared bookkeeping for one Promise.all call.
const AllCtx = struct {
    interp: *Interpreter,
    remaining: usize,
    results: []JSValue,
    derived: JSValue,

    fn completeIfDone(c: *AllCtx) anyerror!void {
        if (c.remaining != 0) return;
        const arena = c.interp.arena_state.allocator();
        var array = try JSValue.newArray(arena);
        for (c.results) |r| _ = try array.array.value.push(r.retain());
        try c.interp.resolvePromise(c.derived, array);
    }
};

/// Per-element fulfillment handler: stores at its index, resolves the
/// derived array when the last one lands.
const AllElemCtx = struct {
    all: *AllCtx,
    index: usize,
};

fn allElemFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *AllElemCtx = @ptrCast(@alignCast(ctx));
    c.all.results[c.index] = arg(args, 0).retain();
    c.all.remaining -= 1;
    try c.all.completeIfDone();
    return JSValue.UNDEFINED;
}

fn allRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *AllCtx = @ptrCast(@alignCast(ctx));
    // First rejection wins; settle idempotence makes later ones no-ops.
    try c.interp.rejectPromiseValue(c.derived, arg(args, 0));
    return JSValue.UNDEFINED;
}

/// Promise.all over an ARRAY (narrowed -- general iterables need the
/// Symbol.iterator protocol this ecosystem doesn't have). Order is
/// preserved by index; rejection is fail-fast.
fn promiseAll(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const input = arg(args, 0);
    if (input != .array) return self.throwError(.type_error, "{s} is not iterable", .{input.typeOf()});
    const items = input.array.value.toSlice();

    const derived = try JSValue.newPromise(allocator);
    const all = try allocator.create(AllCtx);
    all.* = .{
        .interp = self,
        .remaining = items.len,
        .results = try allocator.alloc(JSValue, items.len),
        .derived = derived,
    };
    for (all.results) |*r| r.* = JSValue.UNDEFINED;
    if (items.len == 0) {
        try all.completeIfDone();
        return derived;
    }

    const on_r = try JSValue.newFunction(allocator, .{ .ctx = all, .name = "", .call = allRejected });
    for (items, 0..) |item, i| {
        const elem = try allocator.create(AllElemCtx);
        elem.* = .{ .all = all, .index = i };
        const on_f = try JSValue.newFunction(allocator, .{ .ctx = elem, .name = "", .call = allElemFulfilled });
        const p = if (item == .promise) item else try self.fulfilledPromise(item);
        _ = try self.promiseThen(p, on_f, on_r);
    }
    return derived;
}

/// Per-race resolution handler: first settle of ANY element settles the
/// derived promise; the rest are silent no-ops via settle idempotence.
const RaceCtx = struct {
    interp: *Interpreter,
    derived: JSValue,
};

fn raceFulfilled(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *RaceCtx = @ptrCast(@alignCast(ctx));
    try c.interp.resolvePromise(c.derived, arg(args, 0));
    return JSValue.UNDEFINED;
}

fn raceRejected(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *RaceCtx = @ptrCast(@alignCast(ctx));
    try c.interp.rejectPromiseValue(c.derived, arg(args, 0));
    return JSValue.UNDEFINED;
}

fn promiseRace(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const input = arg(args, 0);
    if (input != .array) return self.throwError(.type_error, "{s} is not iterable", .{input.typeOf()});

    const derived = try JSValue.newPromise(allocator);
    const rc = try allocator.create(RaceCtx);
    rc.* = .{ .interp = self, .derived = derived };
    const on_f = try JSValue.newFunction(allocator, .{ .ctx = rc, .name = "", .call = raceFulfilled });
    const on_r = try JSValue.newFunction(allocator, .{ .ctx = rc, .name = "", .call = raceRejected });
    for (input.array.value.toSlice()) |item| {
        const p = if (item == .promise) item else try self.fulfilledPromise(item);
        _ = try self.promiseThen(p, on_f, on_r);
    }
    return derived;
}

// ===== Timers =====

fn globalSetTimeout(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const cb = arg(args, 0);
    if (cb != .function) return self.throwError(.type_error, "The \"callback\" argument must be of type function", .{});
    const delay = if (arg(args, 1) == .number) arg(args, 1).number else 0;
    return JSValue.fromNumber(try self.addTimer(cb, delay));
}

fn globalClearTimeout(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    if (arg(args, 0) == .number) interp(ctx).clearTimer(arg(args, 0).number);
    return JSValue.UNDEFINED;
}

// ===== Error constructors =====

/// Comptime factory: one native per ErrorKind. The message argument is
/// coerced with toDisplayString (Node stringifies it too); no argument =
/// empty message.
fn errorConstructor(comptime kind: zvalue.ErrorKind) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = ctx;
            _ = this_value;
            const msg: []const u8 = switch (arg(args, 0)) {
                .@"undefined" => "",
                else => |v| try coercion.toDisplayString(allocator, v),
            };
            return JSValue.newError(allocator, kind, msg);
        }
    }.call;
}

// ===== Function.prototype.call / apply / bind =====

fn requireFunction(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    if (this_value != .function) {
        return interp(ctx).throwError(.type_error, "Function.prototype.{s} called on a non-function", .{method});
    }
    return this_value;
}

fn fnCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const target = try requireFunction(ctx, this_value, "call");
    const this_arg = arg(args, 0);
    const rest = if (args.len > 1) args[1..] else &[_]JSValue{};
    return target.function.value.call(target.function.value.ctx, allocator, this_arg, rest);
}

fn fnApply(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const target = try requireFunction(ctx, this_value, "apply");
    const this_arg = arg(args, 0);
    const arg_list = arg(args, 1);
    const call_args: []const JSValue = switch (arg_list) {
        .@"undefined", .@"null" => &.{},
        .array => |box| box.value.toSlice(),
        else => return interp(ctx).throwError(.type_error, "CreateListFromArrayLike called on non-object", .{}),
    };
    return target.function.value.call(target.function.value.ctx, allocator, this_arg, call_args);
}

/// ctx for one bound function: the target, the fixed this, and any
/// pre-applied arguments.
const BoundCtx = struct {
    target: JSValue,
    bound_this: JSValue,
    pre_args: []const JSValue,
};

fn boundCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value; // a bound function ignores its call-site this (spec)
    const bc: *BoundCtx = @ptrCast(@alignCast(ctx));
    const total = try allocator.alloc(JSValue, bc.pre_args.len + args.len);
    @memcpy(total[0..bc.pre_args.len], bc.pre_args);
    @memcpy(total[bc.pre_args.len..], args);
    return bc.target.function.value.call(bc.target.function.value.ctx, allocator, bc.bound_this, total);
}

/// Narrowed [[Bind]]: the bound function is NOT constructable (real
/// bound functions are; `new (f.bind(x))()` is a documented gap).
fn fnBind(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const target = try requireFunction(ctx, this_value, "bind");
    const bc = try allocator.create(BoundCtx);
    const pre = if (args.len > 1) args[1..] else &[_]JSValue{};
    const pre_copy = try allocator.alloc(JSValue, pre.len);
    for (pre, 0..) |a, i| pre_copy[i] = a.retain();
    bc.* = .{
        .target = target.retain(),
        .bound_this = arg(args, 0).retain(),
        .pre_args = pre_copy,
    };
    const target_arity = target.function.value.arity;
    const bound_arity = if (target_arity > pre.len) target_arity - pre.len else 0;
    const name = try std.fmt.allocPrint(allocator, "bound {s}", .{target.function.value.name});
    return JSValue.newFunction(allocator, .{
        .ctx = bc,
        .name = name,
        .arity = bound_arity,
        .call = boundCall,
    });
}
