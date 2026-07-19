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
const zfunctions = @import("zfunctions");
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

/// The reserved symbol-key encoding (`\x00S<ptr>`) -- invisible to
/// string-keyed reflection (keys/values/entries/getOwnPropertyNames).
fn isSymbolKey(k: []const u8) bool {
    return k.len > 0 and k[0] == 0;
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
    .{ "findIndex", arrayFindIndex },
    .{ "findLast", arrayFindLast },
    .{ "findLastIndex", arrayFindLastIndex },
    .{ "some", arraySome },
    .{ "every", arrayEvery },
    .{ "reduceRight", arrayReduceRight },
    .{ "flatMap", arrayFlatMap },
    .{ "at", arrayAt },
    .{ "lastIndexOf", arrayLastIndexOf },
    .{ "fill", arrayFill },
    .{ "copyWithin", arrayCopyWithin },
    .{ "flat", arrayFlat },
    .{ "splice", arraySplice },
    .{ "sort", arraySort },
    .{ "toString", arrayToStringMethod },
    .{ "keys", arrayKeys },
    .{ "values", arrayValues },
    .{ "entries", arrayEntries },
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

pub const symbol_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "toString", symbolToString },
    .{ "valueOf", symbolValueOf },
});

/// Object.prototype methods every plain object answers to (dispatched on
/// prototype-chain miss -- our objects have no real Object.prototype
/// parent; this table plays that role).
pub const object_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "hasOwnProperty", objHasOwnProperty },
    .{ "propertyIsEnumerable", objPropertyIsEnumerable },
    .{ "toString", objToString },
    .{ "valueOf", objValueOf },
    .{ "isPrototypeOf", objIsPrototypeOf },
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
    .{ "trimStart", stringTrimStart },
    .{ "trimEnd", stringTrimEnd },
    .{ "charCodeAt", stringCharCodeAt },
    .{ "codePointAt", stringCodePointAt },
    .{ "at", stringAt },
    .{ "padStart", stringPadStart },
    .{ "padEnd", stringPadEnd },
    .{ "substring", stringSubstring },
    .{ "substr", stringSubstr },
    .{ "lastIndexOf", stringLastIndexOf },
    .{ "concat", stringConcat },
    .{ "replace", stringReplace },
    .{ "replaceAll", stringReplaceAll },
    .{ "localeCompare", stringLocaleCompare },
    .{ "toString", stringToStringMethod },
    .{ "valueOf", stringToStringMethod },
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

    // Object: a real constructable function (typeof "function"), its
    // statics on the property bag, its .prototype pre-populated with the
    // same cached natives object_methods dispatches -- so the harness's
    // detached `Object.prototype.hasOwnProperty` pattern works.
    const object_ctor = try JSValue.newFunction(arena, .{
        .ctx = self,
        .name = "Object",
        .arity = 1,
        .call = objectConstructor,
        .constructable = true,
    });
    const object_statics = try self.functionStatics(object_ctor);
    const os_bag = object_statics.object.value;
    _ = os_bag;
    inline for (.{
        .{ "keys", objectKeys },              .{ "values", objectValues },
        .{ "entries", objectEntries },        .{ "assign", objectAssign },
        .{ "defineProperty", objectDefineProperty },
        .{ "defineProperties", objectDefineProperties },
        .{ "getOwnPropertyDescriptor", objectGetOwnPropertyDescriptor },
        .{ "getOwnPropertyNames", objectGetOwnPropertyNames },
        .{ "getOwnPropertySymbols", objectGetOwnPropertySymbols },
        .{ "create", objectCreate },
        .{ "freeze", objectFreeze },          .{ "isFrozen", objectIsFrozen },
        .{ "seal", objectSeal },              .{ "isSealed", objectIsSealed },
        .{ "preventExtensions", objectPreventExtensions },
        .{ "isExtensible", objectIsExtensible },
        .{ "setPrototypeOf", objectSetPrototypeOf },
    }) |entry| {
        try object_statics.object.value.set(entry[0], try native(self, entry[0], entry[1]));
    }
    const object_proto = try self.functionPrototype(object_ctor);
    inline for (.{
        .{ "hasOwnProperty", objHasOwnProperty },
        .{ "propertyIsEnumerable", objPropertyIsEnumerable },
        .{ "toString", objToString },
        .{ "valueOf", objValueOf },
        .{ "isPrototypeOf", objIsPrototypeOf },
    }) |entry| {
        try object_proto.object.value.set(entry[0], try self.nativeMethod("object", entry[0], entry[1]));
    }
    try g.define(arena, "Object", object_ctor);

    // Array: constructable (new Array(n) / Array(a, b, c)) + statics.
    const array_ctor = try JSValue.newFunction(arena, .{
        .ctx = self,
        .name = "Array",
        .arity = 1,
        .call = arrayConstructor,
        .constructable = true,
    });
    const array_statics = try self.functionStatics(array_ctor);
    try array_statics.object.value.set("isArray", try native(self, "isArray", arrayIsArray));
    try array_statics.object.value.set("of", try native(self, "of", arrayOf));
    try array_statics.object.value.set("from", try native(self, "from", arrayFrom));
    try g.define(arena, "Array", array_ctor);

    // Function: a constructor that PARSES -- new Function('a', 'return a')
    // composes and compiles a real closure (a bounded eval). Its
    // .prototype carries the cached call/apply/bind for the detached
    // harness pattern.
    const function_ctor = try JSValue.newFunction(arena, .{
        .ctx = self,
        .name = "Function",
        .arity = 1,
        .call = functionConstructor,
        .constructable = true,
    });
    const function_proto = try self.functionPrototype(function_ctor);
    inline for (.{
        .{ "call", fnCall },
        .{ "apply", fnApply },
        .{ "bind", fnBind },
    }) |entry| {
        try function_proto.object.value.set(entry[0], try self.nativeMethod("function", entry[0], entry[1]));
    }
    try g.define(arena, "Function", function_ctor);

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
        .{ "EvalError", zvalue.ErrorKind.eval_error },
        .{ "URIError", zvalue.ErrorKind.uri_error },
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

    // Symbol: callable but NOT constructable (`new Symbol()` throws).
    // The well-known symbols and the for()/keyFor() registry are JSValue
    // symbols owned by the interpreter (identity = Rc box).
    const symbol_ctor = try JSValue.newFunction(arena, .{ .ctx = self, .name = "Symbol", .arity = 0, .call = symbolConstructor });
    const symbol_statics = try self.functionStatics(symbol_ctor);
    inline for (.{ "iterator", "asyncIterator", "hasInstance", "toPrimitive", "toStringTag", "species", "isConcatSpreadable", "match", "replace", "search", "split", "unscopables" }) |wk| {
        const sym = try JSValue.newSymbol(arena, "Symbol." ++ wk);
        try symbol_statics.object.value.set(wk, sym.retain());
        if (comptime std.mem.eql(u8, wk, "iterator")) self.symbol_iterator = sym;
    }
    try symbol_statics.object.value.set("for", try native(self, "for", symbolFor));
    try symbol_statics.object.value.set("keyFor", try native(self, "keyFor", symbolKeyFor));
    try g.define(arena, "Symbol", symbol_ctor);

    try g.define(arena, "setTimeout", try native(self, "setTimeout", globalSetTimeout));
    try g.define(arena, "clearTimeout", try native(self, "clearTimeout", globalClearTimeout));

    try g.define(arena, "parseInt", try native(self, "parseInt", globalParseInt));
    try g.define(arena, "parseFloat", try native(self, "parseFloat", globalParseFloat));
    try g.define(arena, "isNaN", try native(self, "isNaN", globalIsNaN));
    try g.define(arena, "isFinite", try native(self, "isFinite", globalIsFinite));
    // String/Number/Boolean: callable = coercion (as before);
    // constructable = evalNew keeps the hollow instance (typeof "object",
    // no [[PrimitiveValue]] -- documented narrowing). Statics via bags.
    const string_ctor = try JSValue.newFunction(arena, .{ .ctx = self, .name = "String", .arity = 1, .call = globalString, .constructable = true });
    const string_statics = try self.functionStatics(string_ctor);
    try string_statics.object.value.set("fromCharCode", try native(self, "fromCharCode", stringFromCharCode));
    try string_statics.object.value.set("fromCodePoint", try native(self, "fromCodePoint", stringFromCodePoint));
    try g.define(arena, "String", string_ctor);

    const number_ctor = try JSValue.newFunction(arena, .{ .ctx = self, .name = "Number", .arity = 1, .call = globalNumber, .constructable = true });
    const number_statics = try self.functionStatics(number_ctor);
    try number_statics.object.value.set("isNaN", try native(self, "isNaN", numberIsNaN));
    try number_statics.object.value.set("isFinite", try native(self, "isFinite", numberIsFinite));
    try number_statics.object.value.set("isInteger", try native(self, "isInteger", numberIsInteger));
    try number_statics.object.value.set("parseFloat", try native(self, "parseFloat", globalParseFloat));
    try number_statics.object.value.set("parseInt", try native(self, "parseInt", globalParseInt));
    try number_statics.object.value.set("MAX_SAFE_INTEGER", JSValue.fromNumber(9007199254740991.0));
    try number_statics.object.value.set("MIN_SAFE_INTEGER", JSValue.fromNumber(-9007199254740991.0));
    try number_statics.object.value.set("EPSILON", JSValue.fromNumber(std.math.floatEps(f64)));
    try number_statics.object.value.set("NaN", JSValue.fromNumber(std.math.nan(f64)));
    try g.define(arena, "Number", number_ctor);

    const boolean_ctor = try JSValue.newFunction(arena, .{ .ctx = self, .name = "Boolean", .arity = 1, .call = globalBoolean, .constructable = true });
    try g.define(arena, "Boolean", boolean_ctor);
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
    for (ks) |k| {
        if (isSymbolKey(k)) continue;
        _ = try result.array.value.push(try JSValue.newString(allocator, k));
    }
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
    for (ks) |k| {
        if (isSymbolKey(k)) continue;
        _ = try result.array.value.push(try interp(ctx).getProperty(o, k));
    }
    return result;
}

fn objectEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = try requireObject(ctx, arg(args, 0), "Object.entries");
    const ks = try o.object.value.keys(allocator);
    defer allocator.free(ks);
    var result = try JSValue.newArray(allocator);
    for (ks) |k| {
        if (isSymbolKey(k)) continue;
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
    // String(symbol) is the one explicit coercion the spec allows --
    // "Symbol(desc)" -- unlike implicit `sym + ''` which throws.
    if (arg(args, 0) == .symbol) {
        const s = try arg(args, 0).symbol.value.toString(allocator);
        defer allocator.free(s);
        return JSValue.newString(allocator, s);
    }
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

// ===== Object.prototype methods (object_methods table) =====

fn requirePlainObject(ctx: *anyopaque, v: JSValue, what: []const u8) anyerror!JSValue {
    if (v != .object) return interp(ctx).throwError(.type_error, "{s} called on non-object", .{what});
    return v;
}

fn objHasOwnProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    if (this_value != .object) return JSValue.fromBool(false);
    const key = try coercion.toDisplayString(allocator, arg(args, 0));
    return JSValue.fromBool(this_value.object.value.hasOwnProperty(key));
}

fn objPropertyIsEnumerable(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    if (this_value != .object) return JSValue.fromBool(false);
    const key = try coercion.toDisplayString(allocator, arg(args, 0));
    return JSValue.fromBool(this_value.object.value.propertyIsEnumerable(key));
}

fn objToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    _ = args;
    return JSValue.newString(allocator, "[object Object]");
}

fn objValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = args;
    return this_value.retain();
}

fn objIsPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    if (this_value != .object or arg(args, 0) != .object) return JSValue.fromBool(false);
    return JSValue.fromBool(this_value.object.value.isPrototypeOf(&arg(args, 0).object.value));
}

// ===== Object statics: constructor + descriptors =====

fn objectConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    const v = arg(args, 0);
    return switch (v) {
        // Object(x) on object-likes returns x; on nothing, a fresh {}.
        .object, .array, .function, .@"error", .date, .promise, .map, .set, .regex => v.retain(),
        else => JSValue.newObject(allocator),
    };
}

/// Shared by defineProperty/defineProperties/create: applies ONE
/// JS-shaped descriptor to obj[key], with the spec's partial-descriptor
/// merge on existing configurable properties. Defining bypasses
/// `writable` (that's assignment's rule, not definition's).
fn definePropertyFromJs(self: *Interpreter, obj: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    const arena = self.arena_state.allocator();
    if (desc != .object) {
        return self.throwError(.type_error, "Property description must be an object", .{});
    }
    const d = &desc.object.value;

    const has_get = d.hasOwnProperty("get");
    const has_set = d.hasOwnProperty("set");
    const has_value = d.hasOwnProperty("value");
    const has_writable = d.hasOwnProperty("writable");
    if ((has_get or has_set) and (has_value or has_writable)) {
        return self.throwError(.type_error, "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute", .{});
    }

    const existing = obj.object.value.getOwnRecordMut(key);
    if (existing) |rec| {
        if (!rec.descriptor.configurable) {
            // Narrowed: any redefinition attempt on a non-configurable
            // property throws (the real spec allows some same-value and
            // writable:true->value cases).
            return self.throwError(.type_error, "Cannot redefine property: {s}", .{key});
        }
    }

    if (has_get or has_set) {
        const getter = if (has_get) blk: {
            const g = d.get("get").?;
            break :blk if (g == .function) g.retain() else null;
        } else null;
        const setter = if (has_set) blk: {
            const s = d.get("set").?;
            break :blk if (s == .function) s.retain() else null;
        } else null;
        try obj.object.value.defineAccessor(key, getter, setter, JSValue.UNDEFINED);
        const rec = obj.object.value.getOwnRecordMut(key).?;
        if (existing == null) {
            // New accessor property: flag defaults are FALSE per spec.
            rec.descriptor.enumerable = false;
            rec.descriptor.configurable = false;
        }
        if (d.hasOwnProperty("enumerable")) rec.descriptor.enumerable = coercion.isTruthy(d.get("enumerable").?);
        if (d.hasOwnProperty("configurable")) rec.descriptor.configurable = coercion.isTruthy(d.get("configurable").?);
        return;
    }

    if (existing) |rec| {
        // Partial merge onto an existing (configurable) property.
        if (has_value) {
            rec.value = d.get("value").?.retain();
            rec.getter = null;
            rec.setter = null;
        }
        if (has_writable) rec.descriptor.writable = coercion.isTruthy(d.get("writable").?);
        if (d.hasOwnProperty("enumerable")) rec.descriptor.enumerable = coercion.isTruthy(d.get("enumerable").?);
        if (d.hasOwnProperty("configurable")) rec.descriptor.configurable = coercion.isTruthy(d.get("configurable").?);
        return;
    }

    // New data property: absent fields default to false/undefined.
    const value = if (has_value) d.get("value").?.retain() else JSValue.UNDEFINED;
    const descriptor = zvalue.PropertyDescriptor{
        .writable = if (has_writable) coercion.isTruthy(d.get("writable").?) else false,
        .enumerable = if (d.hasOwnProperty("enumerable")) coercion.isTruthy(d.get("enumerable").?) else false,
        .configurable = if (d.hasOwnProperty("configurable")) coercion.isTruthy(d.get("configurable").?) else false,
    };
    obj.object.value.defineProperty(key, value, descriptor) catch |err| return switch (err) {
        error.ObjectNotExtensible => self.throwError(.type_error, "Cannot define property {s}, object is not extensible", .{key}),
        error.PropertyNotConfigurable => self.throwError(.type_error, "Cannot redefine property: {s}", .{key}),
        else => err,
    };
    _ = arena;
}

fn objectDefineProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (obj != .object) return self.throwError(.type_error, "Object.defineProperty called on non-object", .{});
    const key = try coercion.toDisplayString(allocator, arg(args, 1));
    try definePropertyFromJs(self, obj, key, arg(args, 2));
    return obj.retain();
}

fn objectDefineProperties(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (obj != .object) return self.throwError(.type_error, "Object.defineProperties called on non-object", .{});
    const props = arg(args, 1);
    if (props != .object) return self.throwError(.type_error, "Property description must be an object", .{});
    const keys = try props.object.value.keys(allocator);
    defer allocator.free(keys);
    for (keys) |k| {
        try definePropertyFromJs(self, obj, k, props.object.value.get(k).?);
    }
    return obj.retain();
}

fn objectGetOwnPropertyDescriptor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (obj != .object) return self.throwError(.type_error, "Object.getOwnPropertyDescriptor called on non-object", .{});
    const key = try coercion.toDisplayString(allocator, arg(args, 1));
    const rec = obj.object.value.getOwnRecord(key) orelse return JSValue.UNDEFINED;

    var out = try JSValue.newObject(allocator);
    if (rec.isAccessor()) {
        try out.object.value.set("get", if (rec.getter) |g| g.retain() else JSValue.UNDEFINED);
        try out.object.value.set("set", if (rec.setter) |s| s.retain() else JSValue.UNDEFINED);
    } else {
        try out.object.value.set("value", rec.value.retain());
        try out.object.value.set("writable", JSValue.fromBool(rec.descriptor.writable));
    }
    try out.object.value.set("enumerable", JSValue.fromBool(rec.descriptor.enumerable));
    try out.object.value.set("configurable", JSValue.fromBool(rec.descriptor.configurable));
    return out;
}

fn objectGetOwnPropertyNames(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = try requirePlainObject(ctx, arg(args, 0), "Object.getOwnPropertyNames");
    const names = try o.object.value.getOwnPropertyNames(allocator);
    defer allocator.free(names);
    var result = try JSValue.newArray(allocator);
    for (names) |n| {
        if (isSymbolKey(n)) continue;
        _ = try result.array.value.push(try JSValue.newString(allocator, n));
    }
    return result;
}

fn objectGetOwnPropertySymbols(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const o = try requirePlainObject(ctx, arg(args, 0), "Object.getOwnPropertySymbols");
    const names = try o.object.value.getOwnPropertyNames(allocator);
    defer allocator.free(names);
    var result = try JSValue.newArray(allocator);
    for (names) |n| {
        if (!isSymbolKey(n)) continue;
        if (self.symbol_keys.get(n)) |sym| _ = try result.array.value.push(sym.retain());
    }
    return result;
}

fn objectCreate(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const proto = arg(args, 0);
    if (proto != .object and proto != .@"null") {
        return self.throwError(.type_error, "Object prototype may only be an Object or null", .{});
    }
    var obj = try JSValue.newObject(allocator);
    if (proto == .object) try obj.object.value.setPrototype(@constCast(&proto.object.value));
    const props = arg(args, 1);
    if (props == .object) {
        const keys = try props.object.value.keys(allocator);
        defer allocator.free(keys);
        for (keys) |k| try definePropertyFromJs(self, obj, k, props.object.value.get(k).?);
    }
    return obj;
}

fn objectFreeze(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    if (v == .object) v.object.value.freeze();
    return v.retain();
}

fn objectIsFrozen(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(if (v == .object) v.object.value.is_frozen else true);
}

fn objectSeal(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    if (v == .object) v.object.value.seal();
    return v.retain();
}

fn objectIsSealed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(if (v == .object) v.object.value.is_sealed or v.object.value.is_frozen else true);
}

fn objectPreventExtensions(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    if (v == .object) v.object.value.preventExtensions();
    return v.retain();
}

fn objectIsExtensible(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(if (v == .object) v.object.value.is_extensible else false);
}

fn objectSetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    const proto = arg(args, 1);
    if (obj != .object) return self.throwError(.type_error, "Object.setPrototypeOf called on non-object", .{});
    if (proto == .object) {
        try obj.object.value.setPrototype(@constCast(&proto.object.value));
    } else if (proto == .@"null") {
        try obj.object.value.setPrototype(null);
    } else {
        return self.throwError(.type_error, "Object prototype may only be an Object or null", .{});
    }
    return obj.retain();
}

// ===== Array / Function constructors and statics =====

fn arrayConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    var result = try JSValue.newArray(allocator);
    if (args.len == 1 and args[0] == .number) {
        const n = args[0].number;
        if (n < 0 or n != @trunc(n) or n > 4294967294.0) {
            return self.throwError(.range_error, "Invalid array length", .{});
        }
        var i: usize = 0;
        const len: usize = @intFromFloat(n);
        while (i < len) : (i += 1) _ = try result.array.value.push(JSValue.UNDEFINED);
        return result;
    }
    for (args) |a| _ = try result.array.value.push(a.retain());
    return result;
}

fn arrayOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    var result = try JSValue.newArray(allocator);
    for (args) |a| _ = try result.array.value.push(a.retain());
    return result;
}

/// Array.from over arrays, strings (code points), and iterator-protocol
/// objects (callable `next`), with the optional mapFn.
fn arrayFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const src = arg(args, 0);
    const map_fn = arg(args, 1);
    var result = try JSValue.newArray(allocator);
    var index: f64 = 0;

    const push_mapped = struct {
        fn go(s: *Interpreter, alloc: Allocator, res: *JSValue, mf: JSValue, item: JSValue, i: f64) anyerror!void {
            var v = item;
            if (mf == .function) {
                v = try mf.function.value.call(mf.function.value.ctx, alloc, JSValue.UNDEFINED, &.{ item, JSValue.fromNumber(i) });
            }
            _ = s;
            _ = try res.array.value.push(v.retain());
        }
    }.go;

    switch (src) {
        .array => |box| for (box.value.toSlice()) |item| {
            try push_mapped(self, allocator, &result, map_fn, item, index);
            index += 1;
        },
        .string => |box| {
            var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
            while (it.nextCodepointSlice()) |cp| {
                try push_mapped(self, allocator, &result, map_fn, try JSValue.newString(allocator, cp), index);
                index += 1;
            }
        },
        .object => {
            // Array-like fallback (has numeric `length` but is not
            // iterable) OR the iterator protocol (Symbol.iterator /
            // duck-typed next).
            const len_v = try self.getProperty(src, "length");
            const iter_key = if (self.symbol_iterator) |sym| try self.encodeKey(sym) else "";
            const has_iter = iter_key.len > 0 and (try self.getProperty(src, iter_key)) == .function;
            if (!has_iter and (try self.getProperty(src, "next")) != .function and len_v == .number) {
                const n: usize = @intFromFloat(@max(0, len_v.number));
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const key = try std.fmt.allocPrint(allocator, "{d}", .{i});
                    try push_mapped(self, allocator, &result, map_fn, try self.getProperty(src, key), index);
                    index += 1;
                }
            } else {
                const iter = try self.resolveIterator(src);
                const next_fn = try self.getProperty(iter, "next");
                while (true) {
                    const step = try next_fn.function.value.call(next_fn.function.value.ctx, allocator, iter, &.{});
                    if (step != .object) return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
                    if (coercion.isTruthy(try self.getProperty(step, "done"))) break;
                    try push_mapped(self, allocator, &result, map_fn, try self.getProperty(step, "value"), index);
                    index += 1;
                }
            }
        },
        else => return self.throwError(.type_error, "{s} is not iterable", .{src.typeOf()}),
    }
    return result;
}

/// `new Function('a', 'b', 'return a + b')` -- compose, parse with the
/// real parser, close over the global env. A bounded eval.
fn functionConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(allocator, "(function anonymous(");
    if (args.len > 1) {
        for (args[0 .. args.len - 1], 0..) |a, i| {
            if (i != 0) try src.appendSlice(allocator, ", ");
            const s = try coercion.toDisplayString(allocator, a);
            try src.appendSlice(allocator, s);
        }
    }
    try src.appendSlice(allocator, "\n) {\n");
    if (args.len > 0) {
        const body = try coercion.toDisplayString(allocator, args[args.len - 1]);
        try src.appendSlice(allocator, body);
    }
    try src.appendSlice(allocator, "\n})");

    const parser = zfunctions.Parser.init(allocator, src.items) catch {
        return self.throwError(.syntax_error, "Invalid function source", .{});
    };
    const node = parser.parseExpression() catch |err| {
        return self.throwError(.syntax_error, "Function constructor: {s}", .{@errorName(err)});
    };
    const fnode_ptr = switch (node.data) {
        .paren => |inner| switch (inner.data) {
            .function_like => |ptr| ptr,
            else => return self.throwError(.syntax_error, "Invalid function source", .{}),
        },
        else => return self.throwError(.syntax_error, "Invalid function source", .{}),
    };
    return self.makeClosure(self.global_env, zfunctions.asFunctionNode(fnode_ptr));
}

// ===== Number / String statics =====

fn numberIsNaN(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(v == .number and std.math.isNan(v.number));
}

fn numberIsFinite(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(v == .number and std.math.isFinite(v.number));
}

fn numberIsInteger(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return JSValue.fromBool(v == .number and std.math.isFinite(v.number) and v.number == @trunc(v.number));
}

fn stringFromCharCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (args) |a| {
        const code: u21 = @intCast(@as(u32, @intFromFloat(try coercion.toNumber(a))) & 0xFFFF);
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(code, &tmp) catch continue;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return JSValue.newString(allocator, buf.items);
}

// ===== Symbol =====

fn symbolConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    // `new Symbol()` is a real TypeError -- Symbol is not a constructor.
    if (self.construct_target == ctx) {
        return self.throwError(.type_error, "Symbol is not a constructor", .{});
    }
    const desc: ?[]const u8 = switch (arg(args, 0)) {
        .@"undefined" => null,
        else => |v| try coercion.toDisplayString(allocator, v),
    };
    return JSValue.newSymbol(allocator, desc);
}

fn symbolToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    if (this_value != .symbol) return interp(ctx).throwError(.type_error, "Symbol.prototype.toString requires a symbol", .{});
    const s = try this_value.symbol.value.toString(allocator);
    defer allocator.free(s);
    return JSValue.newString(allocator, s);
}

fn symbolValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = args;
    return this_value.retain();
}

fn symbolFor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const key = try coercion.toDisplayString(allocator, arg(args, 0));
    if (self.symbol_registry.get(key)) |sym| return sym.retain();
    const sym = try JSValue.newSymbol(self.arena_state.allocator(), key);
    try self.symbol_registry.put(self.arena_state.allocator(), key, sym.retain());
    return sym;
}

fn symbolKeyFor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (target != .symbol) return self.throwError(.type_error, "Symbol.keyFor requires a symbol", .{});
    var it = self.symbol_registry.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .symbol and entry.value_ptr.symbol == target.symbol) {
            return JSValue.newString(self.arena_state.allocator(), entry.key_ptr.*);
        }
    }
    return JSValue.UNDEFINED;
}

// ===== Array.prototype (extended coverage) =====

fn normIndex(raw: f64, len: usize) usize {
    if (raw < 0) {
        const from_end = @as(f64, @floatFromInt(len)) + raw;
        return if (from_end < 0) 0 else @intFromFloat(from_end);
    }
    const i: usize = @intFromFloat(raw);
    return @min(i, len);
}

fn arrayAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "at");
    const slice = this_value.array.value.toSlice();
    var idx: f64 = @floatFromInt(@as(i64, @intCast(slice.len)));
    const n = try coercion.toNumber(arg(args, 0));
    idx = if (n < 0) @as(f64, @floatFromInt(slice.len)) + n else n;
    if (idx < 0 or idx >= @as(f64, @floatFromInt(slice.len))) return JSValue.UNDEFINED;
    return slice[@intFromFloat(idx)].retain();
}

fn arrayFindIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "findIndex");
    const cb = try requireCallback(ctx, args);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayFindLast(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "findLast");
    const cb = try requireCallback(ctx, args);
    const slice = this_value.array.value.toSlice();
    var i = slice.len;
    while (i > 0) {
        i -= 1;
        if (coercion.isTruthy(try callCallback(cb, allocator, slice[i], i, this_value))) return slice[i].retain();
    }
    return JSValue.UNDEFINED;
}

fn arrayFindLastIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "findLastIndex");
    const cb = try requireCallback(ctx, args);
    const slice = this_value.array.value.toSlice();
    var i = slice.len;
    while (i > 0) {
        i -= 1;
        if (coercion.isTruthy(try callCallback(cb, allocator, slice[i], i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayReduceRight(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "reduceRight");
    const cb = try requireCallback(ctx, args);
    const slice = this_value.array.value.toSlice();
    var acc: JSValue = undefined;
    var i: usize = slice.len;
    if (args.len > 1) {
        acc = args[1];
    } else {
        if (slice.len == 0) return interp(ctx).throwError(.type_error, "Reduce of empty array with no initial value", .{});
        i -= 1;
        acc = slice[i];
    }
    while (i > 0) {
        i -= 1;
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ acc, slice[i], JSValue.fromNumber(@floatFromInt(i)), this_value });
    }
    return acc;
}

fn arrayFlatMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "flatMap");
    const cb = try requireCallback(ctx, args);
    var result = try JSValue.newArray(allocator);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        const v = try callCallback(cb, allocator, item, i, this_value);
        if (v == .array) {
            for (v.array.value.toSlice()) |sub| _ = try result.array.value.push(sub.retain());
        } else {
            _ = try result.array.value.push(v.retain());
        }
    }
    return result;
}

fn arrayLastIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "lastIndexOf");
    const target = arg(args, 0);
    const slice = this_value.array.value.toSlice();
    var i = slice.len;
    while (i > 0) {
        i -= 1;
        if (zvalue.equality.strictEquals(slice[i], target)) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayFill(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "fill");
    const arr = &this_value.array.value;
    const len = arr.length();
    const val = arg(args, 0);
    const start = if (arg(args, 1) == .@"undefined") 0 else normIndex(try coercion.toNumber(arg(args, 1)), len);
    const end = if (arg(args, 2) == .@"undefined") len else normIndex(try coercion.toNumber(arg(args, 2)), len);
    var i = start;
    const mut = arr.toSliceMut();
    while (i < end) : (i += 1) {
        mut[i].deinit();
        mut[i] = val.retain();
    }
    return this_value.retain();
}

fn arrayCopyWithin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "copyWithin");
    const arr = &this_value.array.value;
    const len = arr.length();
    const target = normIndex(try coercion.toNumber(arg(args, 0)), len);
    const start = if (arg(args, 1) == .@"undefined") 0 else normIndex(try coercion.toNumber(arg(args, 1)), len);
    const end = if (arg(args, 2) == .@"undefined") len else normIndex(try coercion.toNumber(arg(args, 2)), len);
    // Snapshot the source slice (retained) so overlapping copies are correct.
    var tmp: std.ArrayList(JSValue) = .empty;
    defer tmp.deinit(std.heap.page_allocator);
    var i = start;
    while (i < end) : (i += 1) try tmp.append(std.heap.page_allocator, arr.toSlice()[i]);
    const mut = arr.toSliceMut();
    var t = target;
    for (tmp.items) |src| {
        if (t >= len) break;
        mut[t].deinit();
        mut[t] = src.retain();
        t += 1;
    }
    return this_value.retain();
}

fn flattenInto(result: *JSValue, allocator: Allocator, slice: []const JSValue, depth: i64) anyerror!void {
    for (slice) |item| {
        if (depth > 0 and item == .array) {
            try flattenInto(result, allocator, item.array.value.toSlice(), depth - 1);
        } else {
            _ = try result.array.value.push(item.retain());
        }
    }
}

fn arrayFlat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "flat");
    const depth: i64 = if (arg(args, 0) == .@"undefined") 1 else @intFromFloat(try coercion.toNumber(arg(args, 0)));
    var result = try JSValue.newArray(allocator);
    try flattenInto(&result, allocator, this_value.array.value.toSlice(), depth);
    return result;
}

fn arraySplice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "splice");
    const arr = &this_value.array.value;
    const len = arr.length();
    const start = if (args.len == 0) 0 else normIndex(try coercion.toNumber(arg(args, 0)), len);
    const delete_count: usize = if (args.len < 2)
        (if (args.len == 0) 0 else len - start)
    else blk: {
        const dc = try coercion.toNumber(arg(args, 1));
        if (dc <= 0) break :blk 0;
        break :blk @min(@as(usize, @intFromFloat(dc)), len - start);
    };
    // Removed elements -> returned array (retained).
    var removed = try JSValue.newArray(allocator);
    for (arr.toSlice()[start .. start + delete_count]) |item| _ = try removed.array.value.push(item.retain());
    // Rebuild: prefix + inserts + suffix.
    const inserts = if (args.len > 2) args[2..] else &[_]JSValue{};
    var rebuilt: std.ArrayList(JSValue) = .empty;
    defer rebuilt.deinit(allocator);
    for (arr.toSlice()[0..start]) |item| try rebuilt.append(allocator, item.retain());
    for (inserts) |item| try rebuilt.append(allocator, item.retain());
    for (arr.toSlice()[start + delete_count ..]) |item| try rebuilt.append(allocator, item.retain());
    // Replace the backing contents.
    while (arr.pop()) |v| v.deinit();
    for (rebuilt.items) |item| _ = try arr.push(item);
    return removed;
}

fn arraySort(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "sort");
    const self = interp(ctx);
    const cmp = arg(args, 0);
    if (cmp != .@"undefined" and cmp != .function) return self.throwError(.type_error, "The comparison function must be either a function or undefined", .{});
    const arr = &this_value.array.value;
    const n = arr.length();
    // Insertion sort over the live backing (stable; O(n^2) is fine for
    // the sizes involved and lets us call a JS comparator per compare).
    var i: usize = 1;
    const mut = arr.toSliceMut();
    while (i < n) : (i += 1) {
        const key = mut[i];
        var j = i;
        while (j > 0) {
            const before = try sortLess(allocator, cmp, key, mut[j - 1]);
            if (!before) break;
            mut[j] = mut[j - 1];
            j -= 1;
        }
        mut[j] = key;
    }
    return this_value.retain();
}

/// Whether `a` should sort before `b` (comparator < 0, or default string
/// order). undefined always sorts last (spec).
fn sortLess(allocator: Allocator, cmp: JSValue, a: JSValue, b: JSValue) anyerror!bool {
    if (a == .@"undefined") return false;
    if (b == .@"undefined") return true;
    if (cmp == .function) {
        const r = try cmp.function.value.call(cmp.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ a, b });
        return (try coercion.toNumber(r)) < 0;
    }
    const sa = try coercion.toDisplayString(allocator, a);
    defer allocator.free(sa);
    const sb = try coercion.toDisplayString(allocator, b);
    defer allocator.free(sb);
    return std.mem.order(u8, sa, sb) == .lt;
}

fn arrayToStringMethod(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireArray(ctx, this_value, "toString");
    const s = try coercion.toDisplayString(allocator, this_value);
    defer allocator.free(s);
    return JSValue.newString(allocator, s);
}

/// keys()/values()/entries() -- iterator objects with `next` and a
/// Symbol.iterator returning self. A snapshot over the current elements.
const ArrayIterCtx = struct {
    interp: *Interpreter,
    items: []const JSValue, // retained snapshot
    index: usize = 0,
    kind: enum { keys, values, entries },
};

fn arrayIterNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    _ = args;
    const ic: *ArrayIterCtx = @ptrCast(@alignCast(ctx));
    var result = try JSValue.newObject(allocator);
    if (ic.index >= ic.items.len) {
        try result.object.value.set("value", JSValue.UNDEFINED);
        try result.object.value.set("done", JSValue.fromBool(true));
        return result;
    }
    const i = ic.index;
    ic.index += 1;
    const value: JSValue = switch (ic.kind) {
        .keys => JSValue.fromNumber(@floatFromInt(i)),
        .values => ic.items[i].retain(),
        .entries => blk: {
            var pair = try JSValue.newArray(allocator);
            _ = try pair.array.value.push(JSValue.fromNumber(@floatFromInt(i)));
            _ = try pair.array.value.push(ic.items[i].retain());
            break :blk pair;
        },
    };
    try result.object.value.set("value", value);
    try result.object.value.set("done", JSValue.fromBool(false));
    return result;
}

fn makeArrayIterator(self: *Interpreter, allocator: Allocator, this_value: JSValue, kind: @FieldType(ArrayIterCtx, "kind")) anyerror!JSValue {
    const src = this_value.array.value.toSlice();
    const snapshot = try allocator.alloc(JSValue, src.len);
    for (src, 0..) |item, i| snapshot[i] = item.retain();
    const ic = try allocator.create(ArrayIterCtx);
    ic.* = .{ .interp = self, .items = snapshot, .kind = kind };
    var obj = try JSValue.newObject(allocator);
    try obj.object.value.set("next", try JSValue.newFunction(allocator, .{ .ctx = ic, .name = "next", .call = arrayIterNext }));
    if (self.symbol_iterator) |sym| {
        const key = try self.encodeKey(sym);
        try obj.object.value.set(key, try self.nativeMethod("iterator", "self", iteratorSelfBuiltin));
    }
    return obj;
}

/// A `[Symbol.iterator]()` returning the receiver -- for builtin iterator
/// objects (mirrors the interpreter's own iteratorSelf).
fn iteratorSelfBuiltin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = args;
    return this_value.retain();
}

fn arrayKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireArray(ctx, this_value, "keys");
    return makeArrayIterator(interp(ctx), allocator, this_value, .keys);
}

fn arrayValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireArray(ctx, this_value, "values");
    return makeArrayIterator(interp(ctx), allocator, this_value, .values);
}

fn arrayEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireArray(ctx, this_value, "entries");
    return makeArrayIterator(interp(ctx), allocator, this_value, .entries);
}

// ===== String.prototype (extended coverage) =====

fn stringTrimStart(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "trimStart");
    const out = try zstring.trimming.trimStart(allocator, data);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringTrimEnd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "trimEnd");
    const out = try zstring.trimming.trimEnd(allocator, data);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringCharCodeAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const data = try requireString(ctx, this_value, "charCodeAt");
    const idx: isize = @intFromFloat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    return if (zstring.access.charCodeAt(data, idx)) |c| JSValue.fromNumber(@floatFromInt(c)) else JSValue.fromNumber(std.math.nan(f64));
}

fn stringCodePointAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const data = try requireString(ctx, this_value, "codePointAt");
    const idx: isize = @intFromFloat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    return if (zstring.access.codePointAt(data, idx)) |c| JSValue.fromNumber(@floatFromInt(c)) else JSValue.UNDEFINED;
}

fn stringAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "at");
    const idx: isize = @intFromFloat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    const out = (try zstring.access.at(allocator, data, idx)) orelse return JSValue.UNDEFINED;
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringPadStart(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "padStart");
    const target: isize = @intFromFloat(try coercion.toNumber(arg(args, 0)));
    const pad: ?[]const u8 = if (arg(args, 1) == .string) arg(args, 1).string.value.data else null;
    const out = try zstring.padding.padStart(allocator, data, target, pad);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringPadEnd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "padEnd");
    const target: isize = @intFromFloat(try coercion.toNumber(arg(args, 0)));
    const pad: ?[]const u8 = if (arg(args, 1) == .string) arg(args, 1).string.value.data else null;
    const out = try zstring.padding.padEnd(allocator, data, target, pad);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringSubstring(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "substring");
    const start: isize = @intFromFloat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .@"undefined") null else @intFromFloat(try coercion.toNumber(arg(args, 1)));
    const out = try zstring.transform.substring(allocator, data, start, end);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

/// Legacy substr(start, length) -- start can be negative (from end).
fn stringSubstr(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "substr");
    const total: isize = @intCast(zstring.utf16.lengthUtf16(data));
    var start: isize = @intFromFloat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    if (start < 0) start = @max(total + start, 0);
    const length: isize = if (arg(args, 1) == .@"undefined") total else @intFromFloat(try coercion.toNumber(arg(args, 1)));
    const end = @min(start + @max(length, 0), total);
    const out = try zstring.transform.substring(allocator, data, start, end);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringLastIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const data = try requireString(ctx, this_value, "lastIndexOf");
    if (arg(args, 0) != .string) return JSValue.fromNumber(-1);
    return JSValue.fromNumber(@floatFromInt(zstring.search.lastIndexOf(data, arg(args, 0).string.value.data, null)));
}

fn stringConcat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "concat");
    var pieces: std.ArrayList([]const u8) = .empty;
    defer pieces.deinit(allocator);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |o| allocator.free(o);
        owned.deinit(allocator);
    }
    for (args) |a| {
        if (a == .string) {
            try pieces.append(allocator, a.string.value.data);
        } else {
            const s = try coercion.toDisplayString(allocator, a);
            try owned.append(allocator, s);
            try pieces.append(allocator, s);
        }
    }
    const out = try zstring.transform.concat(allocator, data, pieces.items);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

/// replace/replaceAll with STRING patterns only (regex deferred). No `$`
/// substitution patterns (narrowing).
fn stringReplaceImpl(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue, all: bool) anyerror!JSValue {
    const data = try requireString(ctx, this_value, if (all) "replaceAll" else "replace");
    const self = interp(ctx);
    if (arg(args, 0) != .string) return self.throwError(.type_error, "string replace with a non-string pattern is not supported", .{});
    const pattern = arg(args, 0).string.value.data;
    // The replacement: a string, or a function called (match, offset, whole).
    const repl_fn = arg(args, 1);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    var replaced = false;
    while (i < data.len) {
        if ((!replaced or all) and pattern.len > 0 and i + pattern.len <= data.len and std.mem.eql(u8, data[i .. i + pattern.len], pattern)) {
            if (repl_fn == .function) {
                const r = try repl_fn.function.value.call(repl_fn.function.value.ctx, allocator, JSValue.UNDEFINED, &.{
                    arg(args, 0), JSValue.fromNumber(@floatFromInt(i)), this_value,
                });
                const rs = try coercion.toDisplayString(allocator, r);
                defer allocator.free(rs);
                try buf.appendSlice(allocator, rs);
            } else if (repl_fn == .string) {
                try buf.appendSlice(allocator, repl_fn.string.value.data);
            }
            i += pattern.len;
            replaced = true;
            continue;
        }
        try buf.append(allocator, data[i]);
        i += 1;
    }
    return JSValue.newString(allocator, buf.items);
}

fn stringReplace(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    return stringReplaceImpl(ctx, allocator, this_value, args, false);
}

fn stringReplaceAll(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    return stringReplaceImpl(ctx, allocator, this_value, args, true);
}

fn stringLocaleCompare(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const data = try requireString(ctx, this_value, "localeCompare");
    const other: []const u8 = if (arg(args, 0) == .string) arg(args, 0).string.value.data else "";
    return JSValue.fromNumber(switch (std.mem.order(u8, data, other)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    });
}

fn stringToStringMethod(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "toString");
    return JSValue.newString(allocator, data);
}

fn stringFromCodePoint(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (args) |a| {
        const cp: u21 = @intCast(@as(u32, @intFromFloat(try coercion.toNumber(a))) & 0x1FFFFF);
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch continue;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return JSValue.newString(allocator, buf.items);
}
