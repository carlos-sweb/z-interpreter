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
    // Local-time getters
    .{ "getTime", dateGetTime },
    .{ "valueOf", dateGetTime },
    .{ "getFullYear", dateGetter("getFullYear") },
    .{ "getMonth", dateGetter("getMonth") },
    .{ "getDate", dateGetter("getDate") },
    .{ "getDay", dateGetter("getDay") },
    .{ "getHours", dateGetter("getHours") },
    .{ "getMinutes", dateGetter("getMinutes") },
    .{ "getSeconds", dateGetter("getSeconds") },
    .{ "getMilliseconds", dateGetter("getMilliseconds") },
    .{ "getTimezoneOffset", dateGetter("getTimezoneOffset") },
    .{ "getYear", dateGetter("getYear") }, // Annex B
    // UTC getters
    .{ "getUTCFullYear", dateGetter("getUTCFullYear") },
    .{ "getUTCMonth", dateGetter("getUTCMonth") },
    .{ "getUTCDate", dateGetter("getUTCDate") },
    .{ "getUTCDay", dateGetter("getUTCDay") },
    .{ "getUTCHours", dateGetter("getUTCHours") },
    .{ "getUTCMinutes", dateGetter("getUTCMinutes") },
    .{ "getUTCSeconds", dateGetter("getUTCSeconds") },
    .{ "getUTCMilliseconds", dateGetter("getUTCMilliseconds") },
    // Local-time setters (n_optional trailing components default to current)
    .{ "setTime", dateSetTime },
    .{ "setMilliseconds", dateSetter("setMilliseconds", 0) },
    .{ "setSeconds", dateSetter("setSeconds", 1) },
    .{ "setMinutes", dateSetter("setMinutes", 2) },
    .{ "setHours", dateSetter("setHours", 3) },
    .{ "setDate", dateSetter("setDate", 0) },
    .{ "setMonth", dateSetter("setMonth", 1) },
    .{ "setFullYear", dateSetter("setFullYear", 2) },
    .{ "setYear", dateSetter("setYear", 0) }, // Annex B
    // UTC setters
    .{ "setUTCMilliseconds", dateSetter("setUTCMilliseconds", 0) },
    .{ "setUTCSeconds", dateSetter("setUTCSeconds", 1) },
    .{ "setUTCMinutes", dateSetter("setUTCMinutes", 2) },
    .{ "setUTCHours", dateSetter("setUTCHours", 3) },
    .{ "setUTCDate", dateSetter("setUTCDate", 0) },
    .{ "setUTCMonth", dateSetter("setUTCMonth", 1) },
    .{ "setUTCFullYear", dateSetter("setUTCFullYear", 2) },
    // Formatting / conversion
    .{ "toISOString", dateToISOString },
    .{ "toJSON", dateToJSON },
    .{ "toString", dateFormatter("toString") },
    .{ "toDateString", dateFormatter("toDateString") },
    .{ "toTimeString", dateFormatter("toTimeString") },
    .{ "toUTCString", dateFormatter("toUTCString") },
    .{ "toGMTString", dateFormatter("toUTCString") }, // Annex B alias of toUTCString
    .{ "toLocaleString", dateLocale("toLocaleString") },
    .{ "toLocaleDateString", dateLocale("toLocaleDateString") },
    .{ "toLocaleTimeString", dateLocale("toLocaleTimeString") },
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

pub const regex_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "test", regexTest },
    .{ "exec", regexExec },
    .{ "toString", regexToString },
});

pub const map_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "get", mapGet },
    .{ "set", mapSet },
    .{ "has", mapHas },
    .{ "delete", mapDelete },
    .{ "clear", mapClear },
    .{ "forEach", mapForEach },
    .{ "keys", mapKeys },
    .{ "values", mapValues },
    .{ "entries", mapEntries },
});

pub const set_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "add", setAdd },
    .{ "has", setHas },
    .{ "delete", setDelete },
    .{ "clear", setClear },
    .{ "forEach", setForEach },
    .{ "keys", setValues },
    .{ "values", setValues },
    .{ "entries", setEntries },
});

pub const number_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "toString", numberToString },
    .{ "toLocaleString", numberToString },
    .{ "valueOf", numberValueOf },
    .{ "toFixed", numberToFixed },
    .{ "toExponential", numberToExponential },
    .{ "toPrecision", numberToPrecision },
});

pub const boolean_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "toString", booleanToString },
    .{ "valueOf", booleanValueOf },
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
    .{ "match", stringMatch },
    .{ "matchAll", stringMatchAll },
    .{ "search", stringSearch },
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

    // Object comes first: its constructor and real `Object.prototype` are
    // created up front so every ordinary object built below (console, Math,
    // JSON, ...) can chain to it via `self.ordinaryObject()`. The prototype
    // is populated with its methods later, uniformly, in materializeProtos.
    const object_ctor = try JSValue.newFunction(arena, .{
        .ctx = self,
        .name = "Object",
        .arity = 1,
        .call = objectConstructor,
        .constructable = true,
    });
    const object_statics = try self.functionStatics(object_ctor);
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
        .{ "getPrototypeOf", objectGetPrototypeOf },
        .{ "is", objectIs },                  .{ "hasOwn", objectHasOwn },
        .{ "fromEntries", objectFromEntries },
    }) |entry| {
        try dneMethod(object_statics, entry[0], try native(self, entry[0], entry[1]));
    }
    self.protos.object = try self.functionPrototype(object_ctor);
    try g.define(arena, "Object", object_ctor);

    const console_obj = try self.ordinaryObject();
    try dneMethod(console_obj, "log", try native(self, "log", consoleLog));
    try g.define(arena, "console", console_obj);

    const math_obj = try self.ordinaryObject();
    try dneConst(math_obj, "PI", JSValue.fromNumber(zmath.PI));
    try dneConst(math_obj, "E", JSValue.fromNumber(zmath.E));
    try dneMethod(math_obj, "floor", try native(self, "floor", mathFloor));
    try dneMethod(math_obj, "ceil", try native(self, "ceil", mathCeil));
    try dneMethod(math_obj, "round", try native(self, "round", mathRound));
    try dneMethod(math_obj, "trunc", try native(self, "trunc", mathTrunc));
    try dneMethod(math_obj, "abs", try native(self, "abs", mathAbs));
    try dneMethod(math_obj, "sign", try native(self, "sign", mathSign));
    try dneMethod(math_obj, "sqrt", try native(self, "sqrt", mathSqrt));
    try dneMethod(math_obj, "pow", try native(self, "pow", mathPow));
    try dneMethod(math_obj, "min", try native(self, "min", mathMin));
    try dneMethod(math_obj, "max", try native(self, "max", mathMax));
    try dneMethod(math_obj, "random", try native(self, "random", mathRandom));
    try g.define(arena, "Math", math_obj);

    const json_obj = try self.ordinaryObject();
    try dneMethod(json_obj, "stringify", try native(self, "stringify", jsonStringify));
    try dneMethod(json_obj, "parse", try native(self, "parse", jsonParse));
    try g.define(arena, "JSON", json_obj);

    // Array: constructable (new Array(n) / Array(a, b, c)) + statics.
    const array_ctor = try JSValue.newFunction(arena, .{
        .ctx = self,
        .name = "Array",
        .arity = 1,
        .call = arrayConstructor,
        .constructable = true,
    });
    const array_statics = try self.functionStatics(array_ctor);
    try dneMethod(array_statics, "isArray", try native(self, "isArray", arrayIsArray));
    try dneMethod(array_statics, "of", try native(self, "of", arrayOf));
    try dneMethod(array_statics, "from", try native(self, "from", arrayFrom));
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
    try g.define(arena, "Function", function_ctor);

    // A real constructable native: `new Date(...)` works through evalNew's
    // object-like-return-overrides rule (a .date return replaces the plain
    // instance). Static methods live in its property bag (like Number's).
    const date_ctor = try JSValue.newFunction(arena, .{
        .ctx = self,
        .name = "Date",
        .call = dateConstructor,
        .constructable = true,
    });
    const date_statics = try self.functionStatics(date_ctor);
    try dneMethod(date_statics, "now", try native(self, "now", dateNow));
    try dneMethod(date_statics, "parse", try native(self, "parse", dateParse));
    try dneMethod(date_statics, "UTC", try native(self, "UTC", dateUTC));
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
    try dneMethod(promise_statics, "resolve", try native(self, "resolve", promiseResolveStatic));
    try dneMethod(promise_statics, "reject", try native(self, "reject", promiseRejectStatic));
    try dneMethod(promise_statics, "all", try native(self, "all", promiseAll));
    try dneMethod(promise_statics, "race", try native(self, "race", promiseRace));
    try g.define(arena, "Promise", promise_ctor);

    // Symbol: callable but NOT constructable (`new Symbol()` throws).
    // The well-known symbols and the for()/keyFor() registry are JSValue
    // symbols owned by the interpreter (identity = Rc box).
    const symbol_ctor = try JSValue.newFunction(arena, .{ .ctx = self, .name = "Symbol", .arity = 0, .call = symbolConstructor });
    const symbol_statics = try self.functionStatics(symbol_ctor);
    inline for (.{ "iterator", "asyncIterator", "hasInstance", "toPrimitive", "toStringTag", "species", "isConcatSpreadable", "match", "replace", "search", "split", "unscopables" }) |wk| {
        const sym = try JSValue.newSymbol(arena, "Symbol." ++ wk);
        try dneConst(symbol_statics, wk, sym.retain());
        if (comptime std.mem.eql(u8, wk, "iterator")) self.symbol_iterator = sym;
    }
    try dneMethod(symbol_statics, "for", try native(self, "for", symbolFor));
    try dneMethod(symbol_statics, "keyFor", try native(self, "keyFor", symbolKeyFor));
    try g.define(arena, "Symbol", symbol_ctor);

    // Map / Set: constructable natives (require `new`); the .map/.set
    // return is preserved by evalNew's object-like-override rule.
    try g.define(arena, "RegExp", try JSValue.newFunction(arena, .{ .ctx = self, .name = "RegExp", .arity = 2, .call = regexpConstructor, .constructable = true }));
    try g.define(arena, "Map", try JSValue.newFunction(arena, .{ .ctx = self, .name = "Map", .arity = 0, .call = mapConstructor, .constructable = true }));
    try g.define(arena, "Set", try JSValue.newFunction(arena, .{ .ctx = self, .name = "Set", .arity = 0, .call = setConstructor, .constructable = true }));

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
    try dneMethod(string_statics, "fromCharCode", try native(self, "fromCharCode", stringFromCharCode));
    try dneMethod(string_statics, "fromCodePoint", try native(self, "fromCodePoint", stringFromCodePoint));
    try g.define(arena, "String", string_ctor);

    const number_ctor = try JSValue.newFunction(arena, .{ .ctx = self, .name = "Number", .arity = 1, .call = globalNumber, .constructable = true });
    const number_statics = try self.functionStatics(number_ctor);
    try dneMethod(number_statics, "isNaN", try native(self, "isNaN", numberIsNaN));
    try dneMethod(number_statics, "isFinite", try native(self, "isFinite", numberIsFinite));
    try dneMethod(number_statics, "isInteger", try native(self, "isInteger", numberIsInteger));
    try dneMethod(number_statics, "parseFloat", try native(self, "parseFloat", globalParseFloat));
    try dneMethod(number_statics, "parseInt", try native(self, "parseInt", globalParseInt));
    try dneConst(number_statics, "MAX_SAFE_INTEGER", JSValue.fromNumber(9007199254740991.0));
    try dneConst(number_statics, "MIN_SAFE_INTEGER", JSValue.fromNumber(-9007199254740991.0));
    try dneConst(number_statics, "EPSILON", JSValue.fromNumber(std.math.floatEps(f64)));
    try dneConst(number_statics, "NaN", JSValue.fromNumber(std.math.nan(f64)));
    try dneConst(number_statics, "MAX_VALUE", JSValue.fromNumber(std.math.floatMax(f64)));
    try dneConst(number_statics, "MIN_VALUE", JSValue.fromNumber(std.math.floatTrueMin(f64)));
    try dneConst(number_statics, "POSITIVE_INFINITY", JSValue.fromNumber(std.math.inf(f64)));
    try dneConst(number_statics, "NEGATIVE_INFINITY", JSValue.fromNumber(-std.math.inf(f64)));
    try g.define(arena, "Number", number_ctor);

    const boolean_ctor = try JSValue.newFunction(arena, .{ .ctx = self, .name = "Boolean", .arity = 1, .call = globalBoolean, .constructable = true });
    try g.define(arena, "Boolean", boolean_ctor);

    // Materialize every builtin prototype as a real object (own methods with
    // descriptors, chained to Object.prototype) now that all constructors
    // exist. Must be last: it reads the constructors back out of the globals.
    try self.materializeProtos();

    // globalThis: an object whose property access is backed by the global
    // environment (see Interpreter.global_object). It is itself a global, and
    // `globalThis.globalThis === globalThis`.
    const global_this = try self.ordinaryObject();
    self.global_object = global_this;
    try g.define(arena, "globalThis", global_this);
}

fn native(self: *Interpreter, name: []const u8, call_fn: NativeFn) !JSValue {
    return JSValue.newFunction(self.arena_state.allocator(), .{
        .ctx = self,
        .name = name,
        .call = call_fn,
    });
}

/// Define a builtin method/namespace property: NON-enumerable, writable,
/// configurable -- the spec attributes for e.g. Object.keys, Date.now,
/// Math.floor, Array.prototype.* (so `Object.keys(Date)` is empty and
/// verifyProperty sees enumerable:false).
fn dneMethod(obj: JSValue, name: []const u8, value: JSValue) !void {
    try obj.object.value.defineProperty(name, value, .{ .writable = true, .enumerable = false, .configurable = true });
}

/// Define a builtin constant: NON-enumerable, NON-writable, NON-configurable
/// (Number.MAX_SAFE_INTEGER, Math.PI, the well-known Symbols, ...).
fn dneConst(obj: JSValue, name: []const u8, value: JSValue) !void {
    try obj.object.value.defineProperty(name, value, .{ .writable = false, .enumerable = false, .configurable = false });
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

/// Live element at `i`, retained so it stays valid across a callback that
/// mutates the array (e.g. `arr.length = k`, which would otherwise free the
/// element and leave a cached `toSlice()` dangling -> "switch on corrupt
/// value"). Null when `i` is now out of bounds (removed mid-iteration ->
/// skip, matching the spec's per-index HasProperty check). The extra ref is
/// reclaimed with the run's arena; callers needn't release it.
fn liveElem(array: JSValue, i: usize) ?JSValue {
    if (i >= array.array.value.length()) return null;
    return array.array.value.get(i).retain();
}

fn arrayMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "map");
    const cb = try requireCallback(ctx, args);
    var result = try JSValue.newArray(allocator);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        // A removed index leaves a hole (undefined) so result.length stays
        // the originally-observed length, like real Array.prototype.map.
        if (liveElem(this_value, i)) |item| {
            const v = try callCallback(cb, allocator, item, i, this_value);
            _ = try result.array.value.push(v.retain());
        } else {
            _ = try result.array.value.push(JSValue.UNDEFINED);
        }
    }
    return result;
}

fn arrayFilter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "filter");
    const cb = try requireCallback(ctx, args);
    var result = try JSValue.newArray(allocator);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) {
            _ = try result.array.value.push(item.retain());
        }
    }
    return result;
}

fn arrayForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        _ = try callCallback(cb, allocator, item, i, this_value);
    }
    return JSValue.UNDEFINED;
}

fn arrayReduce(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "reduce");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var acc: JSValue = undefined;
    var have = args.len > 1;
    if (have) acc = args[1];
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        if (!have) {
            acc = item;
            have = true;
            continue;
        }
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{
            acc, item, JSValue.fromNumber(@floatFromInt(i)), this_value,
        });
    }
    if (!have) return interp(ctx).throwError(.type_error, "Reduce of empty array with no initial value", .{});
    return acc;
}

fn arrayFind(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "find");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        // find visits absent indices as `undefined` (unlike forEach/map).
        const item = liveElem(this_value, i) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return item.retain();
    }
    return JSValue.UNDEFINED;
}

fn arraySome(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "some");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

fn arrayEvery(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "every");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
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
    const idx: isize = toIntSat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
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
    const start: isize = toIntSat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .@"undefined") null else toIntSat(try coercion.toNumber(arg(args, 1)));
    const out = try zstring.transform.slice(allocator, data, start, end);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringRepeat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "repeat");
    const nf = if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0));
    // A negative or infinite count is a RangeError (before any saturation).
    if (nf < 0 or std.math.isInf(nf)) return interp(ctx).throwError(.range_error, "Invalid count value: {d}", .{nf});
    const count: isize = toIntSat(nf);
    const out = try zstring.transform.repeat(allocator, data, count);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringSplit(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "split");
    if (arg(args, 0) == .regex) return regexSplit(interp(ctx), allocator, data, arg(args, 0));
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

/// z-date's Invalid Date sentinel (`Constants.INVALID_TIME`). `newDate`/
/// `fromTimestamp` map any out-of-range timestamp to it.
const INVALID_DATE_MS: i64 = std.math.maxInt(i64);

/// Coerce a JS value to an integer Date field (year/month/day/...). Returns
/// null when the value is NaN/±Infinity or outside i32, so the caller can
/// produce an Invalid Date instead of `@intFromFloat` panicking on an
/// out-of-range float (matching TimeClip ultimately yielding NaN).
fn dateField(v: JSValue) !?i32 {
    const n = try coercion.toNumber(v);
    if (!std.math.isFinite(n)) return null;
    const t = @trunc(n);
    if (t > @as(f64, std.math.maxInt(i32)) or t < @as(f64, std.math.minInt(i32))) return null;
    return @intFromFloat(t);
}

/// ECMA-262 TimeClip on a Number: non-finite or |t| > 8.64e15 ms becomes
/// Invalid Date. Also avoids `@intFromFloat` overflowing on a huge float.
fn timeClip(n: f64) i64 {
    if (!std.math.isFinite(n)) return INVALID_DATE_MS;
    const t = @trunc(n);
    if (t > 8.64e15 or t < -8.64e15) return INVALID_DATE_MS;
    return @intFromFloat(t);
}

/// `new Date()` -> now; `new Date(ms)` -> timestamp (TimeClip'd); `new
/// Date(str)` -> parsed; `new Date(dateValue)` -> copy; `new Date(y, m, d?,
/// h?, min?, s?, ms?)` -> from local components. Any non-finite / out-of-range
/// field yields an Invalid Date rather than crashing. Called without `new` it
/// still returns a .date (real JS returns a string there -- documented).
fn dateConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = this_value;
    if (args.len == 0) return JSValue.newDate(allocator, nowMs());
    if (args.len == 1) {
        const first = args[0];
        if (first == .string) {
            return JSValue.newDate(allocator, zvalue.ZDate.fromString(first.string.value.data).timestamp);
        }
        if (first == .date) return JSValue.newDate(allocator, first.date.value.getTime());
        return JSValue.newDate(allocator, timeClip(try coercion.toNumber(first)));
    }
    // Multi-arg form: read up to 7 fields; a present-but-invalid field (NaN,
    // Infinity, out of i32) makes the whole Date Invalid.
    var fields: [7]?i32 = .{ null, null, null, null, null, null, null };
    var i: usize = 0;
    while (i < args.len and i < 7) : (i += 1) {
        fields[i] = (try dateField(args[i])) orelse return JSValue.newDate(allocator, INVALID_DATE_MS);
    }
    // year and month are always present here (args.len >= 2).
    const d = zvalue.ZDate.fromComponents(fields[0].?, fields[1].?, fields[2], fields[3], fields[4], fields[5], fields[6]);
    return JSValue.newDate(allocator, d.timestamp);
}

/// `Date.now()` -> current time in ms.
fn dateNow(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    _ = args;
    return JSValue.fromNumber(@floatFromInt(nowMs()));
}

/// `Date.parse(str)` -> ms since epoch, or NaN if unparseable.
fn dateParse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const s = arg(args, 0);
    if (s != .string) return JSValue.fromNumber(std.math.nan(f64));
    const ms = zvalue.ZDate.parse(s.string.value.data);
    if (ms == INVALID_DATE_MS) return JSValue.fromNumber(std.math.nan(f64));
    return JSValue.fromNumber(@floatFromInt(ms));
}

/// `Date.UTC(y, m, d?, h?, min?, s?, ms?)` -> ms from UTC components, or NaN
/// if any provided field is non-finite / out of range.
fn dateUTC(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    // `Date.UTC()` with no args, and a NaN year, are both NaN.
    var fields: [7]?i32 = .{ null, null, null, null, null, null, null };
    var i: usize = 0;
    while (i < args.len and i < 7) : (i += 1) {
        fields[i] = (try dateField(args[i])) orelse return JSValue.fromNumber(std.math.nan(f64));
    }
    if (fields[0] == null) return JSValue.fromNumber(std.math.nan(f64));
    // Month defaults to 0 when only the year is given.
    const ms = zvalue.ZDate.UTC(fields[0].?, fields[1] orelse 0, fields[2], fields[3], fields[4], fields[5], fields[6]);
    if (ms == INVALID_DATE_MS) return JSValue.fromNumber(std.math.nan(f64));
    return JSValue.fromNumber(@floatFromInt(ms));
}

fn requireDate(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    if (this_value != .date) {
        return interp(ctx).throwError(.type_error, "Date.prototype.{s} called on a non-date", .{method});
    }
    return this_value;
}

/// A raw millisecond timestamp as a JS Number, mapping z-date's Invalid Date
/// (and any out-of-range value) to NaN -- what `getTime`/`valueOf`/the setters
/// must return for an Invalid Date (the ?i32 getters already yield NaN on
/// their own via z-date returning null).
fn msToNumber(ms: i64) JSValue {
    if (ms > 8_640_000_000_000_000 or ms < -8_640_000_000_000_000)
        return JSValue.fromNumber(std.math.nan(f64));
    return JSValue.fromNumber(@floatFromInt(ms));
}

fn dateGetTime(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const d = try requireDate(ctx, this_value, "getTime");
    return msToNumber(d.date.value.getTime());
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

/// `toJSON` -> ISO string, or `null` for an Invalid Date (real JS: it calls
/// toISOString only when the time is finite).
fn dateToJSON(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const d = try requireDate(ctx, this_value, "toJSON");
    const s = (d.date.value.toJSON(allocator) catch null) orelse return JSValue.NULL;
    defer allocator.free(s);
    return JSValue.newString(allocator, s);
}

/// String-returning ZDate formatters (`toString`/`toDateString`/... ). These
/// render "Invalid Date" for an invalid time rather than throwing (unlike
/// toISOString), matching real JS.
fn dateFormatter(comptime method: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = args;
            const d = try requireDate(ctx, this_value, method);
            const s = @field(zvalue.ZDate, method)(d.date.value, allocator) catch
                return JSValue.newString(allocator, "Invalid Date");
            defer allocator.free(s);
            return JSValue.newString(allocator, s);
        }
    }.call;
}

/// `toLocale*` formatters take an optional Locale (we pass null -> z-date's
/// default en-US locale; Intl options are out of scope).
fn dateLocale(comptime method: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = args;
            const d = try requireDate(ctx, this_value, method);
            const s = @field(zvalue.ZDate, method)(d.date.value, allocator, null) catch
                return JSValue.newString(allocator, "Invalid Date");
            defer allocator.free(s);
            return JSValue.newString(allocator, s);
        }
    }.call;
}

/// `setTime(ms)` -- replace the timestamp wholesale (TimeClip'd; NaN/huge ->
/// Invalid Date). Returns the new time.
fn dateSetTime(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const d = try requireDate(ctx, this_value, "setTime");
    _ = d.date.value.setTime(timeClip(try coercion.toNumber(arg(args, 0))));
    return msToNumber(d.date.value.getTime());
}

/// Component setters (local and UTC). The first arg is required; `n_optional`
/// trailing args default to the current component when omitted. A present arg
/// that isn't a finite in-range integer makes the Date Invalid (returns NaN),
/// never panicking. Mutates the shared boxed ZDate in place (Date is mutable).
fn dateSetter(comptime method: []const u8, comptime n_optional: usize) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const d = try requireDate(ctx, this_value, method);
            const p = &d.date.value;
            const first = (try dateField(arg(args, 0))) orelse {
                p.* = zvalue.ZDate.fromTimestamp(INVALID_DATE_MS);
                return JSValue.fromNumber(std.math.nan(f64));
            };
            var opt: [n_optional]?i32 = undefined;
            inline for (0..n_optional) |k| {
                const a = arg(args, k + 1);
                if (a == .@"undefined") {
                    opt[k] = null;
                } else {
                    opt[k] = (try dateField(a)) orelse {
                        p.* = zvalue.ZDate.fromTimestamp(INVALID_DATE_MS);
                        return JSValue.fromNumber(std.math.nan(f64));
                    };
                }
            }
            const f = @field(zvalue.ZDate, method);
            const new_ts = if (n_optional == 0)
                f(p, first)
            else if (n_optional == 1)
                f(p, first, opt[0])
            else if (n_optional == 2)
                f(p, first, opt[0], opt[1])
            else
                f(p, first, opt[0], opt[1], opt[2]);
            return msToNumber(new_ts);
        }
    }.call;
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

/// Own enumerable string keys of any value, for Object.keys/values/entries.
/// Functions expose the enumerable entries of their statics bag (builtin
/// statics are non-enumerable, so `Object.keys(Date)` is empty); null/
/// undefined throw; other primitives yield nothing (narrowed -- real JS
/// coerces strings to index keys). Caller frees the slice.
fn ownEnumerableKeys(ctx: *anyopaque, allocator: Allocator, v: JSValue) anyerror![][]const u8 {
    return switch (v) {
        .object => |box| box.value.keys(allocator),
        .function => |box| if (box.value.statics) |bag| bag.object.value.keys(allocator) else allocator.alloc([]const u8, 0),
        .@"undefined", .@"null" => interp(ctx).throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        else => allocator.alloc([]const u8, 0),
    };
}

fn objectKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = arg(args, 0);
    const ks = try ownEnumerableKeys(ctx, allocator, o);
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
    const o = arg(args, 0);
    const ks = try ownEnumerableKeys(ctx, allocator, o);
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
    const o = arg(args, 0);
    const ks = try ownEnumerableKeys(ctx, allocator, o);
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
    const radix: ?u8 = if (arg(args, 1) == .@"undefined") null else blk: {
        // Clamp into u8; out-of-[2,36] values are left for parseInt to reject
        // (as NaN). Avoids @intFromFloat panicking on NaN/Infinity/huge radix.
        const r = toIntSat(try coercion.toNumber(arg(args, 1)));
        break :blk if (r >= 0 and r <= 36) @intCast(r) else 255;
    };
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
    _ = this_value;
    // String(symbol) is the one explicit coercion the spec allows --
    // "Symbol(desc)" -- unlike implicit `sym + ''` which throws.
    if (arg(args, 0) == .symbol) {
        const s = try arg(args, 0).symbol.value.toString(allocator);
        defer allocator.free(s);
        return JSValue.newString(allocator, s);
    }
    // String(regex) is regex.toString() -- /source/flags (with flags).
    if (arg(args, 0) == .regex) {
        const st = interp(ctx).regexState(arg(args, 0));
        const s = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ st.source, st.flags });
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

// ===== Number.prototype (only the primitive receiver; hollow `new Number()`
// wrapper objects have no [[NumberData]] here -- documented narrowing) =====

fn requireNumber(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!f64 {
    if (this_value != .number) return interp(ctx).throwError(.type_error, "Number.prototype.{s} called on a non-number", .{method});
    return this_value.number;
}

/// `n.toString(radix?)` / `toLocaleString` -- radix 2..36 (default 10).
fn numberToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const n = try requireNumber(ctx, this_value, "toString");
    var radix: ?u8 = null;
    if (arg(args, 0) != .@"undefined") {
        const r = toIntSat(try coercion.toNumber(arg(args, 0)));
        if (r < 2 or r > 36) return interp(ctx).throwError(.range_error, "toString() radix must be between 2 and 36", .{});
        radix = @intCast(r);
    }
    const s = try znumber.FormattingMethods.toString(n, allocator, radix);
    defer allocator.free(s);
    return JSValue.newString(allocator, s);
}

fn numberValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromNumber(try requireNumber(ctx, this_value, "valueOf"));
}

/// Shared 0..100 digit argument for toFixed/toExponential/toPrecision, with
/// the spec's RangeError. `null` when omitted (allowed by exponential/
/// precision). `lo` is the minimum (0 for fixed/exponential, 1 for precision).
fn digitArg(ctx: *anyopaque, args: []const JSValue, lo: i64) anyerror!?usize {
    if (arg(args, 0) == .@"undefined") return null;
    const d = toIntSat(try coercion.toNumber(arg(args, 0)));
    if (d < lo or d > 100) return interp(ctx).throwError(.range_error, "toFixed() digits argument must be between 0 and 100", .{});
    return @intCast(d);
}

fn numberToFixed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const n = try requireNumber(ctx, this_value, "toFixed");
    const digits = (try digitArg(ctx, args, 0)) orelse 0;
    const s = try znumber.FormattingMethods.toFixed(n, allocator, digits);
    defer allocator.free(s);
    return JSValue.newString(allocator, s);
}

fn numberToExponential(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const n = try requireNumber(ctx, this_value, "toExponential");
    const digits = try digitArg(ctx, args, 0);
    const s = try znumber.FormattingMethods.toExponential(n, allocator, digits);
    defer allocator.free(s);
    return JSValue.newString(allocator, s);
}

fn numberToPrecision(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const n = try requireNumber(ctx, this_value, "toPrecision");
    // Omitted precision behaves like toString.
    if (arg(args, 0) == .@"undefined") {
        const s = try znumber.FormattingMethods.toString(n, allocator, null);
        defer allocator.free(s);
        return JSValue.newString(allocator, s);
    }
    const p = (try digitArg(ctx, args, 1)).?;
    const s = try znumber.FormattingMethods.toPrecision(n, allocator, p);
    defer allocator.free(s);
    return JSValue.newString(allocator, s);
}

// ===== Boolean.prototype =====

fn requireBoolean(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!bool {
    if (this_value != .boolean) return interp(ctx).throwError(.type_error, "Boolean.prototype.{s} called on a non-boolean", .{method});
    return this_value.boolean;
}

fn booleanToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const b = try requireBoolean(ctx, this_value, "toString");
    return JSValue.newString(allocator, if (b) "true" else "false");
}

fn booleanValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    return JSValue.fromBool(try requireBoolean(ctx, this_value, "valueOf"));
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
    const key = try coercion.toDisplayString(allocator, arg(args, 0));
    return switch (this_value) {
        .object => |box| JSValue.fromBool(box.value.hasOwnProperty(key)),
        // Arrays expose `length` and every in-bounds index as an own property
        // (they have no general ZObject bag, so answer these directly).
        .array => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(true);
            const idx = std.fmt.parseInt(usize, key, 10) catch break :blk JSValue.fromBool(interp(ctx).arrayExtra(this_value, key) != null);
            break :blk JSValue.fromBool(idx < box.value.length());
        },
        // Strings: `length` and in-bounds character indices are own props.
        .string => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(true);
            const idx = std.fmt.parseInt(usize, key, 10) catch break :blk JSValue.fromBool(false);
            break :blk JSValue.fromBool(idx < box.value.data.len);
        },
        else => JSValue.fromBool(false),
    };
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
    _ = allocator;
    _ = this_value;
    const v = arg(args, 0);
    return switch (v) {
        // Object(x) on object-likes returns x; on nothing, a fresh {}.
        .object, .array, .function, .@"error", .date, .promise, .map, .set, .regex => v.retain(),
        else => try interp(ctx).ordinaryObject(),
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

/// Define `obj[key]` from a JS descriptor, dispatching by target type:
/// plain objects go through the full descriptor machinery; functions define
/// into their statics bag (a real object); arrays handle length/index by
/// value (no per-index descriptors in this model) and named keys via the
/// array_props object. Non-objects are a TypeError.
fn definePropertyOn(self: *Interpreter, what: []const u8, obj: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    switch (obj) {
        .object => try definePropertyFromJs(self, obj, key, desc),
        .function => try definePropertyFromJs(self, try self.functionStatics(obj), key, desc),
        .array => try arrayDefineProperty(self, obj, key, desc),
        else => return self.throwError(.type_error, "Object.{s} called on non-object", .{what}),
    }
}

/// Best-effort Object.defineProperty on an array: `length` and canonical
/// indices set the value (arrays have no per-element descriptor storage, so
/// writable/enumerable/configurable on those are ignored); any other named
/// key is defined on the array's real array_props object.
fn arrayDefineProperty(self: *Interpreter, arr: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    if (desc != .object) return self.throwError(.type_error, "Property description must be an object", .{});
    if (std.mem.eql(u8, key, "length")) {
        if (desc.object.value.get("value")) |v| try self.setArrayProperty(arr, "length", v);
        return;
    }
    if (std.fmt.parseInt(usize, key, 10)) |_| {
        const v = desc.object.value.get("value") orelse JSValue.UNDEFINED;
        try self.setArrayProperty(arr, key, v);
        return;
    } else |_| {}
    try definePropertyFromJs(self, try self.arrayPropsObject(arr), key, desc);
}

fn objectDefineProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    const key = try coercion.toDisplayString(allocator, arg(args, 1));
    try definePropertyOn(self, "defineProperty", obj, key, arg(args, 2));
    return obj.retain();
}

fn objectDefineProperties(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    if (obj != .object and obj != .function and obj != .array)
        return self.throwError(.type_error, "Object.defineProperties called on non-object", .{});
    const props = arg(args, 1);
    if (props != .object) return self.throwError(.type_error, "Property description must be an object", .{});
    const keys = try props.object.value.keys(allocator);
    defer allocator.free(keys);
    for (keys) |k| {
        try definePropertyOn(self, "defineProperties", obj, k, props.object.value.get(k).?);
    }
    return obj.retain();
}

/// A `{value, writable, enumerable, configurable}` descriptor object (chained
/// to Object.prototype like any ordinary object).
fn dataDescObj(self: *Interpreter, value: JSValue, writable: bool, enumerable: bool, configurable: bool) !JSValue {
    var out = try self.ordinaryObject();
    try out.object.value.set("value", value);
    try out.object.value.set("writable", JSValue.fromBool(writable));
    try out.object.value.set("enumerable", JSValue.fromBool(enumerable));
    try out.object.value.set("configurable", JSValue.fromBool(configurable));
    return out;
}

/// A descriptor object built from a stored property record (data or accessor).
fn descFromRecord(self: *Interpreter, rec: anytype) !JSValue {
    var out = try self.ordinaryObject();
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

fn objectGetOwnPropertyDescriptor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    const key = try coercion.toDisplayString(allocator, arg(args, 1));
    switch (obj) {
        .object => {
            const rec = obj.object.value.getOwnRecord(key) orelse return JSValue.UNDEFINED;
            return descFromRecord(self, rec);
        },
        // Functions expose name/length/prototype as own properties (with the
        // spec attributes) plus whatever's on their statics bag.
        .function => |box| {
            if (std.mem.eql(u8, key, "length"))
                return dataDescObj(self, JSValue.fromNumber(@floatFromInt(box.value.arity)), false, false, true);
            if (std.mem.eql(u8, key, "name"))
                return dataDescObj(self, try JSValue.newString(allocator, box.value.name), false, false, true);
            if (std.mem.eql(u8, key, "prototype") and (box.value.prototype != null or box.value.constructable))
                return dataDescObj(self, try self.functionPrototype(obj), true, false, false);
            if (box.value.statics) |bag| {
                if (bag.object.value.getOwnRecord(key)) |rec| return descFromRecord(self, rec);
            }
            return JSValue.UNDEFINED;
        },
        // Arrays: `length` and in-bounds indices are own data properties.
        .array => |box| {
            if (std.mem.eql(u8, key, "length"))
                return dataDescObj(self, JSValue.fromNumber(@floatFromInt(box.value.length())), true, false, false);
            const idx = std.fmt.parseInt(usize, key, 10) catch return JSValue.UNDEFINED;
            if (idx >= box.value.length()) return JSValue.UNDEFINED;
            return dataDescObj(self, box.value.get(idx).retain(), true, true, true);
        },
        .@"undefined", .@"null" => return self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        // Other object-likes (date/regex/map/...) have no string-keyed own
        // data properties in this model yet.
        else => return JSValue.UNDEFINED,
    }
}

fn objectGetOwnPropertyNames(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const o = arg(args, 0);
    var result = try JSValue.newArray(allocator);
    switch (o) {
        .object => {
            const names = try o.object.value.getOwnPropertyNames(allocator);
            defer allocator.free(names);
            for (names) |n| {
                if (isSymbolKey(n)) continue;
                _ = try result.array.value.push(try JSValue.newString(allocator, n));
            }
        },
        // Arrays: every index (as a string), then "length".
        .array => |box| {
            var i: usize = 0;
            while (i < box.value.length()) : (i += 1) {
                _ = try result.array.value.push(try JSValue.newString(allocator, try std.fmt.allocPrint(allocator, "{d}", .{i})));
            }
            _ = try result.array.value.push(try JSValue.newString(allocator, "length"));
        },
        // Functions: length, name, prototype (if any), then statics bag names.
        .function => |box| {
            _ = try result.array.value.push(try JSValue.newString(allocator, "length"));
            _ = try result.array.value.push(try JSValue.newString(allocator, "name"));
            if (box.value.prototype != null or box.value.constructable)
                _ = try result.array.value.push(try JSValue.newString(allocator, "prototype"));
            if (box.value.statics) |bag| {
                const names = try bag.object.value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |n| {
                    if (isSymbolKey(n)) continue;
                    _ = try result.array.value.push(try JSValue.newString(allocator, n));
                }
            }
        },
        .@"undefined", .@"null" => return self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        else => {},
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

/// Object.is(a, b) -- SameValue: like `===` but NaN equals NaN and +0 differs
/// from -0.
fn objectIs(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a == .number and b == .number) {
        const x = a.number;
        const y = b.number;
        if (std.math.isNan(x) and std.math.isNan(y)) return JSValue.fromBool(true);
        if (x == 0 and y == 0) return JSValue.fromBool(std.math.signbit(x) == std.math.signbit(y));
        return JSValue.fromBool(x == y);
    }
    return JSValue.fromBool(zvalue.equality.strictEquals(a, b));
}

/// Object.hasOwn(o, key) -- the static form of hasOwnProperty (ES2022).
fn objectHasOwn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = arg(args, 0);
    if (o == .@"undefined" or o == .@"null") return interp(ctx).throwError(.type_error, "Cannot convert undefined or null to object", .{});
    return objHasOwnProperty(ctx, allocator, o, if (args.len > 1) args[1..] else &.{});
}

/// Object.fromEntries(iterable) -- builds an object from [key, value] pairs.
/// Narrowed to an array of pair-arrays (the common case); other iterables
/// are a documented gap.
fn objectFromEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const src = arg(args, 0);
    if (src != .array) return self.throwError(.type_error, "Object.fromEntries requires an iterable of entries", .{});
    var result = try self.ordinaryObject();
    for (src.array.value.toSlice()) |pair| {
        if (pair != .array) return self.throwError(.type_error, "Iterator value is not an entry object", .{});
        const p = &pair.array.value;
        const k = if (p.length() > 0) p.get(0) else JSValue.UNDEFINED;
        const v = if (p.length() > 1) p.get(1) else JSValue.UNDEFINED;
        const ks = try coercion.toDisplayString(allocator, k);
        defer allocator.free(ks);
        try result.object.value.set(ks, v.retain());
    }
    return result;
}

fn objectGetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const obj = arg(args, 0);
    return switch (obj) {
        .object => blk: {
            const p = obj.object.value.getPrototype() orelse break :blk JSValue.NULL;
            // Recover the owning Rc box from the raw *ZObject the chain
            // stores (it always points at a box's `value` field).
            const Box = @TypeOf(obj.object.*);
            const box: *Box = @fieldParentPtr("value", p);
            break :blk (JSValue{ .object = box }).retain();
        },
        .array => self.protos.array.retain(),
        .string => self.protos.string.retain(),
        .number => self.protos.number.retain(),
        .boolean => self.protos.boolean.retain(),
        .function => self.protos.function.retain(),
        .date => self.protos.date.retain(),
        .regex => self.protos.regex.retain(),
        .@"error" => self.protos.@"error".retain(),
        .map => self.protos.map.retain(),
        .set => self.protos.set.retain(),
        .symbol => self.protos.symbol.retain(),
        .promise => self.protos.promise.retain(),
        .@"undefined", .@"null" => self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
    };
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
        // Sets/Maps are iterable -- drain via the shared iterable path.
        .set, .map => for (try self.iterableItems(src)) |item| {
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
                const n: usize = @intCast(@max(0, toIntSat(len_v.number)));
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
        // ToUint16: wrap into [0, 65536) (NaN/Infinity -> 0), never panicking.
        const num = try coercion.toNumber(a);
        const wrapped: f64 = if (std.math.isFinite(num)) @mod(@trunc(num), 65536.0) else 0;
        const code: u21 = @intFromFloat(wrapped);
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

/// ECMA ToIntegerOrInfinity saturated into isize, so `@intFromFloat` can't
/// panic on NaN / +/-Infinity / out-of-i64-range floats (NaN -> 0). Callers
/// that need a length clamp non-negative afterwards.
fn toIntSat(n: f64) isize {
    if (std.math.isNan(n)) return 0;
    const maxf: f64 = @floatFromInt(std.math.maxInt(isize));
    const minf: f64 = @floatFromInt(std.math.minInt(isize));
    if (n >= maxf) return std.math.maxInt(isize);
    if (n <= minf) return std.math.minInt(isize);
    return @intFromFloat(@trunc(n));
}

fn normIndex(raw: f64, len: usize) usize {
    const i = toIntSat(raw); // NaN/Infinity-safe
    if (i < 0) {
        const from_end = @as(isize, @intCast(len)) + i;
        return if (from_end < 0) 0 else @intCast(from_end);
    }
    return @min(@as(usize, @intCast(i)), len);
}

fn arrayAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "at");
    const len: isize = @intCast(this_value.array.value.length());
    const rel = toIntSat(try coercion.toNumber(arg(args, 0)));
    const idx = if (rel < 0) len + rel else rel;
    if (idx < 0 or idx >= len) return JSValue.UNDEFINED;
    return this_value.array.value.get(@intCast(idx)).retain();
}

fn arrayFindIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "findIndex");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayFindLast(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "findLast");
    const cb = try requireCallback(ctx, args);
    var i = this_value.array.value.length();
    while (i > 0) {
        i -= 1;
        const item = liveElem(this_value, i) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return item.retain();
    }
    return JSValue.UNDEFINED;
}

fn arrayFindLastIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "findLastIndex");
    const cb = try requireCallback(ctx, args);
    var i = this_value.array.value.length();
    while (i > 0) {
        i -= 1;
        const item = liveElem(this_value, i) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayReduceRight(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "reduceRight");
    const cb = try requireCallback(ctx, args);
    var acc: JSValue = undefined;
    var have = args.len > 1;
    if (have) acc = args[1];
    var i: usize = this_value.array.value.length();
    while (i > 0) {
        i -= 1;
        const item = liveElem(this_value, i) orelse continue;
        if (!have) {
            acc = item;
            have = true;
            continue;
        }
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ acc, item, JSValue.fromNumber(@floatFromInt(i)), this_value });
    }
    if (!have) return interp(ctx).throwError(.type_error, "Reduce of empty array with no initial value", .{});
    return acc;
}

fn arrayFlatMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "flatMap");
    const cb = try requireCallback(ctx, args);
    var result = try JSValue.newArray(allocator);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
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
    const depth: i64 = if (arg(args, 0) == .@"undefined") 1 else toIntSat(try coercion.toNumber(arg(args, 0)));
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
        break :blk @min(@as(usize, @intCast(toIntSat(dc))), len - start);
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

pub fn makeArrayIterator(self: *Interpreter, allocator: Allocator, this_value: JSValue, kind: @FieldType(ArrayIterCtx, "kind")) anyerror!JSValue {
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
    const idx: isize = toIntSat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    return if (zstring.access.charCodeAt(data, idx)) |c| JSValue.fromNumber(@floatFromInt(c)) else JSValue.fromNumber(std.math.nan(f64));
}

fn stringCodePointAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const data = try requireString(ctx, this_value, "codePointAt");
    const idx: isize = toIntSat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    return if (zstring.access.codePointAt(data, idx)) |c| JSValue.fromNumber(@floatFromInt(c)) else JSValue.UNDEFINED;
}

fn stringAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "at");
    const idx: isize = toIntSat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    const out = (try zstring.access.at(allocator, data, idx)) orelse return JSValue.UNDEFINED;
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringPadStart(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "padStart");
    const target: isize = toIntSat(try coercion.toNumber(arg(args, 0)));
    const pad: ?[]const u8 = if (arg(args, 1) == .string) arg(args, 1).string.value.data else null;
    const out = try zstring.padding.padStart(allocator, data, target, pad);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringPadEnd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "padEnd");
    const target: isize = toIntSat(try coercion.toNumber(arg(args, 0)));
    const pad: ?[]const u8 = if (arg(args, 1) == .string) arg(args, 1).string.value.data else null;
    const out = try zstring.padding.padEnd(allocator, data, target, pad);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

fn stringSubstring(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "substring");
    const start: isize = toIntSat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .@"undefined") null else toIntSat(try coercion.toNumber(arg(args, 1)));
    const out = try zstring.transform.substring(allocator, data, start, end);
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}

/// Legacy substr(start, length) -- start can be negative (from end).
fn stringSubstr(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "substr");
    const total: isize = @intCast(zstring.utf16.lengthUtf16(data));
    var start: isize = toIntSat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    if (start < 0) start = @max(total + start, 0);
    const length: isize = if (arg(args, 1) == .@"undefined") total else toIntSat(try coercion.toNumber(arg(args, 1)));
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

/// replace/replaceAll -- string OR regex patterns; string OR function
/// replacements ($-substitution via z-regex for the string case).
fn stringReplaceImpl(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue, all: bool) anyerror!JSValue {
    const data = try requireString(ctx, this_value, if (all) "replaceAll" else "replace");
    const self = interp(ctx);
    if (arg(args, 0) == .regex) return regexReplace(self, allocator, data, arg(args, 0), arg(args, 1), all);
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
    _ = this_value;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (args) |a| {
        // Each argument must be an integer code point in [0, 0x10FFFF].
        const num = try coercion.toNumber(a);
        if (!std.math.isFinite(num) or num != @trunc(num) or num < 0 or num > 0x10FFFF)
            return interp(ctx).throwError(.range_error, "Invalid code point {d}", .{num});
        const cp: u21 = @intFromFloat(num);
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch continue;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return JSValue.newString(allocator, buf.items);
}

// ===== Map / Set =====

fn requireMap(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    if (this_value != .map) return interp(ctx).throwError(.type_error, "Method Map.prototype.{s} called on incompatible receiver", .{method});
    return this_value;
}

fn requireSet(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    if (this_value != .set) return interp(ctx).throwError(.type_error, "Method Set.prototype.{s} called on incompatible receiver", .{method});
    return this_value;
}

fn mapConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Map requires 'new'", .{});
    var m = try JSValue.newMap(allocator);
    const init = arg(args, 0);
    if (init != .@"undefined" and init != .@"null") {
        for (try self.iterableItems(init)) |entry| {
            if (entry != .array and entry != .object) return self.throwError(.type_error, "Iterator value {s} is not an entry object", .{entry.typeOf()});
            const k = try self.getProperty(entry, "0");
            const v = try self.getProperty(entry, "1");
            try m.map.value.set(k.retain(), v.retain());
        }
    }
    return m;
}

fn setConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    if (self.construct_target != ctx) return self.throwError(.type_error, "Constructor Set requires 'new'", .{});
    var s = try JSValue.newSet(allocator);
    const init = arg(args, 0);
    if (init != .@"undefined" and init != .@"null") {
        for (try self.iterableItems(init)) |v| try s.set.value.add(v.retain());
    }
    return s;
}

fn mapGet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "get");
    return if (m.map.value.get(arg(args, 0))) |v| v.retain() else JSValue.UNDEFINED;
}

fn mapSet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "set");
    try m.map.value.set(arg(args, 0).retain(), arg(args, 1).retain());
    return m.retain(); // chainable
}

fn mapHas(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "has");
    return JSValue.fromBool(m.map.value.has(arg(args, 0)));
}

fn mapDelete(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const m = try requireMap(ctx, this_value, "delete");
    return JSValue.fromBool(m.map.value.delete(arg(args, 0)));
}

fn mapClear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const m = try requireMap(ctx, this_value, "clear");
    m.map.value.clear();
    return JSValue.UNDEFINED;
}

fn mapForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const m = try requireMap(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    const ks = m.map.value.keys();
    const vs = m.map.value.values();
    for (ks, vs) |k, v| {
        _ = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ v, k, m });
    }
    return JSValue.UNDEFINED;
}

/// Snapshot slice -> array iterator (reuses the array-iterator machinery).
fn iteratorFromValues(self: *Interpreter, allocator: Allocator, items: []const JSValue) anyerror!JSValue {
    var arr = try JSValue.newArray(allocator);
    for (items) |it| _ = try arr.array.value.push(it.retain());
    return makeArrayIterator(self, allocator, arr, .values);
}

fn mapKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const m = try requireMap(ctx, this_value, "keys");
    return iteratorFromValues(interp(ctx), allocator, m.map.value.keys());
}

fn mapValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const m = try requireMap(ctx, this_value, "values");
    return iteratorFromValues(interp(ctx), allocator, m.map.value.values());
}

fn mapEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const m = try requireMap(ctx, this_value, "entries");
    const ks = m.map.value.keys();
    const vs = m.map.value.values();
    var pairs: std.ArrayList(JSValue) = .empty;
    defer pairs.deinit(allocator);
    for (ks, vs) |k, v| {
        var pair = try JSValue.newArray(allocator);
        _ = try pair.array.value.push(k.retain());
        _ = try pair.array.value.push(v.retain());
        try pairs.append(allocator, pair);
    }
    return iteratorFromValues(interp(ctx), allocator, pairs.items);
}

fn setAdd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const s = try requireSet(ctx, this_value, "add");
    if (!s.set.value.has(arg(args, 0))) try s.set.value.add(arg(args, 0).retain());
    return s.retain(); // chainable
}

fn setHas(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const s = try requireSet(ctx, this_value, "has");
    return JSValue.fromBool(s.set.value.has(arg(args, 0)));
}

fn setDelete(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const s = try requireSet(ctx, this_value, "delete");
    return JSValue.fromBool(s.set.value.delete(arg(args, 0)));
}

fn setClear(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const s = try requireSet(ctx, this_value, "clear");
    s.set.value.clear();
    return JSValue.UNDEFINED;
}

fn setForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const s = try requireSet(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    for (s.set.value.values()) |v| {
        _ = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ v, v, s });
    }
    return JSValue.UNDEFINED;
}

fn setValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const s = try requireSet(ctx, this_value, "values");
    return iteratorFromValues(interp(ctx), allocator, s.set.value.values());
}

fn setEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const s = try requireSet(ctx, this_value, "entries");
    var pairs: std.ArrayList(JSValue) = .empty;
    defer pairs.deinit(allocator);
    for (s.set.value.values()) |v| {
        var pair = try JSValue.newArray(allocator);
        _ = try pair.array.value.push(v.retain());
        _ = try pair.array.value.push(v.retain());
        try pairs.append(allocator, pair);
    }
    return iteratorFromValues(interp(ctx), allocator, pairs.items);
}

// ===== RegExp =====

const zregex = @import("zregex");

fn requireRegex(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    if (this_value != .regex) return interp(ctx).throwError(.type_error, "Method RegExp.prototype.{s} called on incompatible receiver", .{method});
    return this_value;
}

/// `new RegExp(pattern, flags?)` / `RegExp(...)`. A RegExp source argument
/// is copied (its own flags unless new ones are given).
fn regexpConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const pat_arg = arg(args, 0);
    var source: []const u8 = "";
    var flags: []const u8 = "";
    if (pat_arg == .regex) {
        const st = self.regexState(pat_arg);
        source = st.source;
        flags = st.flags;
    } else if (pat_arg != .@"undefined") {
        source = try coercion.toDisplayString(allocator, pat_arg);
    }
    if (arg(args, 1) != .@"undefined") flags = try coercion.toDisplayString(allocator, arg(args, 1));
    return self.makeRegex(source, flags);
}

/// Match at-or-after `start`: z-regex's `find` scans (respecting the
/// compiled sticky flag), so searching from a position means searching
/// within the suffix `input[start..]`. Returns the match (relative to
/// that suffix) and the suffix, so callers add `start` for absolute
/// offsets. `full` is the whole string (for the match array's `.input`).
const RegexHit = struct { match: zregex.MatchResult, sub: []const u8, base: usize, full: []const u8, group_count: usize };

fn regexFindFrom(re: JSValue, input: []const u8, start: usize) anyerror!?RegexHit {
    if (start > input.len) return null;
    const sub = input[start..];
    const m = try re.regex.value.find(sub);
    return if (m) |match| RegexHit{ .match = match, .sub = sub, .base = start, .full = input, .group_count = re.regex.value.compiled.group_count } else null;
}

/// The JS match-result array: [0]=whole match, [i]=capture i (undefined
/// if it didn't participate), plus own `index`, `input`, and `groups`.
/// All strings come from `hit.sub`; the absolute `.index` adds `hit.base`.
fn makeMatchArray(self: *Interpreter, allocator: Allocator, hit: RegexHit) anyerror!JSValue {
    const match = hit.match;
    const input = hit.sub;
    var result = try JSValue.newArray(allocator);
    _ = try result.array.value.push(try JSValue.newString(allocator, match.group(input)));
    var i: usize = 1;
    while (i <= hit.group_count) : (i += 1) {
        if (match.getCapture(i, input)) |cap| {
            _ = try result.array.value.push(try JSValue.newString(allocator, cap));
        } else {
            _ = try result.array.value.push(JSValue.UNDEFINED);
        }
    }
    // exec/match arrays carry extra own properties.
    try setArrayOwn(self, result, "index", JSValue.fromNumber(@floatFromInt(hit.base + match.start)));
    try setArrayOwn(self, result, "input", try JSValue.newString(allocator, hit.full));
    if (match.named_groups.len > 0) {
        var groups = try JSValue.newObject(allocator);
        for (match.named_groups) |ng| {
            const v = if (match.getNamedCapture(ng.name, input)) |c| try JSValue.newString(allocator, c) else JSValue.UNDEFINED;
            try groups.object.value.set(ng.name, v);
        }
        try setArrayOwn(self, result, "groups", groups);
    } else {
        try setArrayOwn(self, result, "groups", JSValue.UNDEFINED);
    }
    return result;
}

/// Set a named own property on an array value (arrays here have no
/// general property bag, so exec-result extras go through the array's
/// object-ish set -- but ZArray is index-keyed; we stash these on a
/// parallel object). Simplest faithful approach: since our arrays can't
/// hold named props, we accept that match.index/.input/.groups live only
/// if the array were an object. To keep it working, store them via the
/// array's own retained slots is impossible -- so we wrap: not needed for
/// the common `m[0]`/`m[1]` access. We DO support .index/.input/.groups
/// by special-casing in getProperty? Simpler: attach via a side map.
fn setArrayOwn(self: *Interpreter, array: JSValue, key: []const u8, value: JSValue) anyerror!void {
    try self.setArrayExtra(array, key, value);
}

fn regexTest(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const re = try requireRegex(ctx, this_value, "test");
    const self = interp(ctx);
    const input = if (arg(args, 0) == .string) arg(args, 0).string.value.data else try coercion.toDisplayString(allocator, arg(args, 0));
    const st = self.regexState(re);
    const stateful = st.global or st.sticky;
    const hit = try regexFindFrom(re, input, if (stateful) st.last_index else 0);
    if (hit) |h| {
        defer h.match.deinit();
        if (stateful) st.last_index = h.base + h.match.end;
        return JSValue.fromBool(true);
    }
    if (stateful) st.last_index = 0;
    return JSValue.fromBool(false);
}

fn regexExec(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const re = try requireRegex(ctx, this_value, "exec");
    const self = interp(ctx);
    const input = if (arg(args, 0) == .string) arg(args, 0).string.value.data else try coercion.toDisplayString(allocator, arg(args, 0));
    const st = self.regexState(re);
    const stateful = st.global or st.sticky;
    const hit = try regexFindFrom(re, input, if (stateful) st.last_index else 0);
    if (hit) |h| {
        defer h.match.deinit();
        const abs_end = h.base + h.match.end;
        if (stateful) st.last_index = if (h.match.end > h.match.start) abs_end else abs_end + 1;
        return makeMatchArray(self, allocator, h);
    }
    if (stateful) st.last_index = 0;
    return JSValue.NULL;
}

fn regexToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const re = try requireRegex(ctx, this_value, "toString");
    const st = interp(ctx).regexState(re);
    const s = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ st.source, st.flags });
    defer allocator.free(s);
    return JSValue.newString(allocator, s);
}

// ===== String methods with RegExp patterns =====

/// str.match(re): non-global -> a match array (or null); global -> an
/// array of all whole-match strings (or null).
fn stringMatch(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "match");
    const self = interp(ctx);
    const re = try coerceToRegex(self, allocator, arg(args, 0));
    const st = self.regexState(re);
    if (!st.global) {
        const hit = try regexFindFrom(re, data, 0);
        if (hit) |h| {
            defer h.match.deinit();
            return makeMatchArray(self, allocator, h);
        }
        return JSValue.NULL;
    }
    var all = try re.regex.value.findAll(data);
    defer {
        for (all.items) |*mm| mm.deinit();
        all.deinit(allocator);
    }
    if (all.items.len == 0) return JSValue.NULL;
    var result = try JSValue.newArray(allocator);
    for (all.items) |match| _ = try result.array.value.push(try JSValue.newString(allocator, match.group(data)));
    return result;
}

/// str.matchAll(re): an iterator of match arrays.
fn stringMatchAll(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "matchAll");
    const self = interp(ctx);
    const re = try coerceToRegex(self, allocator, arg(args, 0));
    var all = try re.regex.value.findAll(data);
    defer {
        for (all.items) |*mm| mm.deinit();
        all.deinit(allocator);
    }
    var arr = try JSValue.newArray(allocator);
    for (all.items) |match| {
        _ = try arr.array.value.push(try makeMatchArray(self, allocator, .{ .match = match, .sub = data, .base = 0, .full = data, .group_count = re.regex.value.compiled.group_count }));
    }
    return makeArrayIterator(self, allocator, arr, .values);
}

fn stringSearch(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "search");
    const self = interp(ctx);
    const re = try coerceToRegex(self, allocator, arg(args, 0));
    const m = try re.regex.value.find(data);
    if (m) |match| {
        defer match.deinit();
        return JSValue.fromNumber(@floatFromInt(match.start));
    }
    return JSValue.fromNumber(-1);
}

/// Coerce a match/replace/search/split argument to a `.regex` (a plain
/// string becomes a source-literal regex, real JS behavior).
fn coerceToRegex(self: *Interpreter, allocator: Allocator, v: JSValue) anyerror!JSValue {
    if (v == .regex) return v;
    const source = if (v == .@"undefined") "" else try coercion.toDisplayString(allocator, v);
    return self.makeRegex(source, "");
}

/// String.prototype.replace/replaceAll with a regex pattern. Delegates
/// string replacements to z-regex (JS `$` substitution included);
/// function replacements loop the matches.
fn regexReplace(self: *Interpreter, allocator: Allocator, data: []const u8, re: JSValue, repl: JSValue, all_flag: bool) anyerror!JSValue {
    const st = self.regexState(re);
    const replace_all = st.global or all_flag;
    if (repl != .function) {
        const rs = if (repl == .@"undefined") "undefined" else try coercion.toDisplayString(allocator, repl);
        const out = if (replace_all)
            try re.regex.value.replaceAll(allocator, data, rs)
        else
            try re.regex.value.replace(allocator, data, rs);
        defer allocator.free(out);
        return JSValue.newString(allocator, out);
    }
    // Function replacement: build the result splicing each match's
    // fn(match, ...captures, offset, input) result.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var pos: usize = 0;
    while (pos <= data.len) {
        const m = try re.regex.value.findAt(data, pos);
        const match = m orelse break;
        defer match.deinit();
        try buf.appendSlice(allocator, data[pos..match.start]);
        // callback args: (match, cap1, cap2, ..., offset, input)
        var call_args: std.ArrayList(JSValue) = .empty;
        defer call_args.deinit(allocator);
        try call_args.append(allocator, try JSValue.newString(allocator, match.group(data)));
        var i: usize = 1;
        while (i <= re.regex.value.compiled.group_count) : (i += 1) {
            const cap = if (match.getCapture(i, data)) |c| try JSValue.newString(allocator, c) else JSValue.UNDEFINED;
            try call_args.append(allocator, cap);
        }
        try call_args.append(allocator, JSValue.fromNumber(@floatFromInt(match.start)));
        try call_args.append(allocator, try JSValue.newString(allocator, data));
        const r = try repl.function.value.call(repl.function.value.ctx, allocator, JSValue.UNDEFINED, call_args.items);
        const rs = try coercion.toDisplayString(allocator, r);
        defer allocator.free(rs);
        try buf.appendSlice(allocator, rs);
        // advance past the match (empty match -> step one to avoid a loop)
        pos = if (match.end > match.start) match.end else match.end + 1;
        if (!replace_all) {
            try buf.appendSlice(allocator, data[match.end..]);
            return JSValue.newString(allocator, buf.items);
        }
    }
    if (pos < data.len) try buf.appendSlice(allocator, data[pos..]);
    return JSValue.newString(allocator, buf.items);
}

/// String.prototype.split with a regex separator. Splits at each match;
/// the separator's capture groups are interleaved (real JS behavior).
fn regexSplit(self: *Interpreter, allocator: Allocator, data: []const u8, re: JSValue) anyerror!JSValue {
    _ = self;
    var result = try JSValue.newArray(allocator);
    var all = try re.regex.value.findAll(data);
    defer {
        for (all.items) |*mm| mm.deinit();
        all.deinit(allocator);
    }
    var last: usize = 0;
    for (all.items) |match| {
        if (match.end == match.start and match.start == last) continue; // skip empty at boundary
        _ = try result.array.value.push(try JSValue.newString(allocator, data[last..match.start]));
        var gi: usize = 1;
        while (gi <= re.regex.value.compiled.group_count) : (gi += 1) {
            const cap = if (match.getCapture(gi, data)) |c| try JSValue.newString(allocator, c) else JSValue.UNDEFINED;
            _ = try result.array.value.push(cap);
        }
        last = match.end;
    }
    _ = try result.array.value.push(try JSValue.newString(allocator, data[last..]));
    return result;
}
