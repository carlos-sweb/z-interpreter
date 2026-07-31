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
const zbigint = @import("zbigint");
const zbuffer = @import("zbuffer");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const temporal_builtins = @import("temporal_builtins.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const inspect = @import("inspect.zig");
const native_helpers = @import("native_helpers.zig");

// z-interpreter-refactor.md, Step 2: interp/arg/native/NativeFn now live in
// native_helpers.zig (a leaf module, no dependency on this file), shared
// with temporal_builtins.zig instead of each independently redefining
// them. Local aliases keep every existing call site in this file
// unchanged.
pub const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;

// z-interpreter-refactor.md, Step 5 Phase A prep: the cross-domain shared
// guards/coercion helpers/BuiltinSpec now live in builtin_helpers.zig, a
// leaf module (imports only native_helpers.zig, interpreter.zig,
// coercion.zig). Local aliases keep every existing call site in this file
// unchanged; future per-domain files import builtin_helpers.zig directly
// instead of reaching into builtins.zig.
const builtin_helpers = @import("builtin_helpers.zig");
const isSymbolKey = builtin_helpers.isSymbolKey;
const BuiltinSpec = builtin_helpers.BuiltinSpec;
const installBuiltin = builtin_helpers.installBuiltin;
const dneMethod = builtin_helpers.dneMethod;
const dneConst = builtin_helpers.dneConst;
const requireTag = builtin_helpers.requireTag;
const requirePrimitive = builtin_helpers.requirePrimitive;
const requireCallback = builtin_helpers.requireCallback;
const callCallback = builtin_helpers.callCallback;
const toIntSat = builtin_helpers.toIntSat;
const toBigIntValue = builtin_helpers.toBigIntValue;
const toByteIndexArg = builtin_helpers.toByteIndexArg;
const toUint8Wrap = builtin_helpers.toUint8Wrap;
const toInt8Wrap = builtin_helpers.toInt8Wrap;
const toUint16Wrap = builtin_helpers.toUint16Wrap;
const toInt16Wrap = builtin_helpers.toInt16Wrap;
const toUint8Clamp = builtin_helpers.toUint8Clamp;
const toU64Wrapped = builtin_helpers.toU64Wrapped;
const toI64Wrapped = builtin_helpers.toI64Wrapped;
const bigIntFromU64 = builtin_helpers.bigIntFromU64;
const typedView = builtin_helpers.typedView;
pub const typedElemGet = builtin_helpers.typedElemGet;
pub const typedElemSet = builtin_helpers.typedElemSet;
const oobIsNoop = builtin_helpers.oobIsNoop;
const toLength = builtin_helpers.toLength;
const hasIteratorMethod = builtin_helpers.hasIteratorMethod;
const arrayLikeToList = builtin_helpers.arrayLikeToList;
pub const ArrayIterCtx = builtin_helpers.ArrayIterCtx;
const arrayIterNext = builtin_helpers.arrayIterNext;
const makeArrayIterator = builtin_helpers.makeArrayIterator;
const iteratorSelfBuiltin = builtin_helpers.iteratorSelfBuiltin;
const isObjectLike = builtin_helpers.isObjectLike;

// z-interpreter-refactor.md, Step 5 Phase A: first domain-file batch
// (smallest/cleanest per the plan -- Promise+Timers, Function, Symbol,
// RegExp). Method tables and any pub type interpreter.zig reaches into
// via `builtins.X` are re-exported here so every existing external call
// site (interpreter.zig's materializeProtos/gcTrack*/typedElem*) keeps
// working unchanged. `regexFindFrom`/`makeMatchArray`/`regexSplit` are
// re-aliased too: String.prototype's regex-pattern methods (still living
// in this file until String's own extraction pass) call them by bare
// name.
const promise_builtins = @import("promise_builtins.zig");
const function_builtins = @import("function_builtins.zig");
const symbol_builtins = @import("symbol_builtins.zig");
const regex_builtins = @import("regex_builtins.zig");
pub const promise_methods = promise_builtins.promise_methods;
pub const function_methods = function_builtins.function_methods;
pub const symbol_methods = symbol_builtins.symbol_methods;
pub const regex_methods = regex_builtins.regex_methods;
pub const PromiseCapCtx = promise_builtins.PromiseCapCtx;
pub const FinallyCtx = promise_builtins.FinallyCtx;
pub const AllCtx = promise_builtins.AllCtx;
pub const AllElemCtx = promise_builtins.AllElemCtx;
pub const RaceCtx = promise_builtins.RaceCtx;
pub const BoundCtx = function_builtins.BoundCtx;
const regexFindFrom = regex_builtins.regexFindFrom;
const makeMatchArray = regex_builtins.makeMatchArray;
const regexSplit = regex_builtins.regexSplit;

// z-interpreter-refactor.md, Step 5 Phase A batch 2: Math/JSON/Proxy
// (statics-only or ctor-only, no cross-domain deps beyond
// builtin_helpers) and Boolean/BigInt (each needed one surgical
// single-function pull too: `globalBoolean` physically lived in the old
// "Loose globals" grab-bag section, not next to Boolean.prototype).
const math_builtins = @import("math_builtins.zig");
const json_builtins = @import("json_builtins.zig");
const boolean_builtins = @import("boolean_builtins.zig");
const bigint_builtins = @import("bigint_builtins.zig");
const proxy_builtins = @import("proxy_builtins.zig");
pub const boolean_methods = boolean_builtins.boolean_methods;
pub const bigint_methods = bigint_builtins.bigint_methods;

// z-interpreter-refactor.md, Step 5 Phase A batch 3: Date, Number (another
// surgical pull -- `globalNumber` physically lived in the old "Loose
// globals" grab-bag section, and `numberIsNaN`/`isFinite`/`isInteger` in a
// mixed "Number / String statics" section whose `stringFromCharCode` half
// stays behind for String's own extraction), Map/Set (grouped together --
// they share `iteratorFromValues` and install back-to-back). `nowMs` is
// re-exported since interpreter.zig's setTimeout/setInterval machinery
// calls it as `builtins.nowMs`.
const date_builtins = @import("date_builtins.zig");
const number_builtins = @import("number_builtins.zig");
const mapset_builtins = @import("mapset_builtins.zig");
pub const date_methods = date_builtins.date_methods;
pub const number_methods = number_builtins.number_methods;
pub const map_methods = mapset_builtins.map_methods;
pub const set_methods = mapset_builtins.set_methods;
pub const nowMs = date_builtins.nowMs;

// z-interpreter-refactor.md, Step 5 Phase A batch 4: ArrayBuffer/DataView
// (roadmap item 19 phase 1) + the 10 TypedArray constructors and the
// shared %TypedArray%.prototype (phase 2) -- grouped into one file since
// TypedArray construction/methods reach into ArrayBuffer/DataView
// internals directly.
const arraybuffer_builtins = @import("arraybuffer_builtins.zig");
pub const array_buffer_methods = arraybuffer_builtins.array_buffer_methods;
pub const dataview_methods = arraybuffer_builtins.dataview_methods;
pub const typed_array_methods = arraybuffer_builtins.typed_array_methods;

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
    const arena = self.gc_allocator;
    const g = self.global_env;

    try g.define(arena, "undefined", JSValue.UNDEFINED);
    try g.define(arena, "NaN", JSValue.fromNumber(std.math.nan(f64)));
    try g.define(arena, "Infinity", JSValue.fromNumber(std.math.inf(f64)));

    // Object comes first: its constructor and real `Object.prototype` are
    // created up front so every ordinary object built below (console, Math,
    // JSON, ...) can chain to it via `self.ordinaryObject()`. The prototype
    // is populated with its methods later, uniformly, in materializeProtos.
    const object_ctor = try self.gcNewFunction(.{
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

    try math_builtins.install(self);

    _ = try installBuiltin(self, .{ .name = "Reflect", .statics = &.{
        .{ .name = "get", .value = .{ .method = reflectGet } },
        .{ .name = "set", .value = .{ .method = reflectSet } },
        .{ .name = "has", .value = .{ .method = reflectHas } },
        .{ .name = "deleteProperty", .value = .{ .method = reflectDeleteProperty } },
        .{ .name = "ownKeys", .value = .{ .method = reflectOwnKeys } },
        .{ .name = "getPrototypeOf", .value = .{ .method = reflectGetPrototypeOf } },
        .{ .name = "defineProperty", .value = .{ .method = reflectDefineProperty } },
        .{ .name = "getOwnPropertyDescriptor", .value = .{ .method = reflectGetOwnPropertyDescriptor } },
        .{ .name = "apply", .value = .{ .method = reflectApply } },
        .{ .name = "construct", .value = .{ .method = reflectConstruct } },
    } });

    try json_builtins.install(self);

    // Array: constructable (new Array(n) / Array(a, b, c)) + statics.
    _ = try installBuiltin(self, .{ .name = "Array", .ctor = .{ .arity = 1, .call = arrayConstructor, .constructable = true }, .statics = &.{
        .{ .name = "isArray", .value = .{ .method = arrayIsArray } },
        .{ .name = "of", .value = .{ .method = arrayOf } },
        .{ .name = "from", .value = .{ .method = arrayFrom } },
    } });

    try function_builtins.install(self);

    try date_builtins.install(self);

    try temporal_builtins.install(self);

    try proxy_builtins.install(self);

    try arraybuffer_builtins.install(self);

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
        const ctor = try self.gcNewFunction(.{
            .ctx = self,
            .name = entry[0],
            .arity = 1,
            .call = errorConstructor(entry[1]),
            .constructable = true,
        });
        try g.define(arena, entry[0], ctor);
    }

    try promise_builtins.install(self);
    try symbol_builtins.install(self);

    try regex_builtins.install(self);
    try mapset_builtins.install(self);

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
    // String/Number/Boolean: callable = coercion (as before);
    // constructable = evalNew keeps the hollow instance (typeof "object",
    // no [[PrimitiveValue]] -- documented narrowing). Statics via bags.
    _ = try installBuiltin(self, .{ .name = "String", .ctor = .{ .arity = 1, .call = globalString, .constructable = true }, .statics = &.{
        .{ .name = "fromCharCode", .value = .{ .method = stringFromCharCode } },
        .{ .name = "fromCodePoint", .value = .{ .method = stringFromCodePoint } },
    } });

    try number_builtins.install(self);

    try boolean_builtins.install(self);
    try bigint_builtins.install(self);

    // Materialize every builtin prototype as a real object (own methods with
    // descriptors, chained to Object.prototype) now that all constructors
    // exist. Must be last: it reads the constructors back out of the globals.
    try self.materializeProtos();

    // globalThis: an object whose property access is backed by the global
    // environment (see Interpreter.global_object). It is itself a global, and
    // `globalThis.globalThis === globalThis`.
    const global_this = try self.ordinaryObject();
    // Same fix as eval_fn/symbol_iterator: self.global_object needs its
    // own retained reference, independent of the (reassignable)
    // `globalThis` global binding.
    self.global_object = global_this.retain();
    try g.define(arena, "globalThis", global_this);
}

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

// ===== Generic receiver guards (z-interpreter-refactor.md, Step 3) =====
//
// 16 requireX functions existed here, each independently re-implementing
// "check this_value's tag, throw a TypeError naming `method` if wrong,
// return something". Re-reading every one against current source (not
// trusting the plan's original guess) found two clean, truly-identical
// shapes -- requireTag below (9 functions: no unwrapping, returns the
// whole JSValue or void) and requirePrimitive (3 functions: unwraps a
// `new String()`/`new Number()`/`new Boolean()` primitive wrapper first,
// returns an inner scalar field) -- plus 4 genuinely divergent ones that
// stay hand-written because they don't fit either shape: requireCallback
// (checks args[0], not this_value), requireObject/requirePlainObject
// (caller supplies the whole message prefix, not just a method name --
// near-duplicates of EACH OTHER, not of this group), and requireDataView
// (takes `*Interpreter` directly instead of `*anyopaque`, and returns an
// extracted `.view` rather than the JSValue itself).
//
// The exact message template of every migrated function is preserved
// verbatim (passed as a comptime format string) -- this is a pure
// dedup, not a message-wording change.

// ===== Array.prototype =====

fn requireArray(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!void {
    _ = try requireTag(ctx, this_value, .array, "Array.prototype.{s} called on a non-array", method);
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
    return interp(ctx).gcNewString(buf.items);
}

fn arraySlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "slice");
    const start: ?isize = if (arg(args, 0) == .@"undefined") null else toIntSat(try coercion.toNumber(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .@"undefined") null else toIntSat(try coercion.toNumber(arg(args, 1)));
    // z-array's own slice() does the negative-index/clamping arithmetic
    // (same rules ECMA-262 wants); it just copies the raw JSValue bytes
    // without retaining (it doesn't know T might be refcounted), so we
    // retain each element ourselves on the way into the GC-tracked result.
    var sliced = try this_value.array.value.slice(start, end);
    defer sliced.deinit();
    var result = try interp(ctx).gcNewArray();
    for (sliced.toSlice()) |item| _ = try result.array.value.push(item.retain());
    return result;
}

fn arrayConcat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "concat");
    var result = try interp(ctx).gcNewArray();
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
    var result = try interp(ctx).gcNewArray();
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
    var result = try interp(ctx).gcNewArray();
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
    return (try requirePrimitive(ctx, this_value, .string, "String.prototype.{s} called on a non-string", method)).string.value.data;
}

fn argString(allocator: Allocator, args: []const JSValue, i: usize) ![]u8 {
    return coercion.toDisplayString(allocator, arg(args, i));
}

fn stringToUpperCase(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "toUpperCase");
    const out = try zstring.case.toUpperCase(allocator, data);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringToLowerCase(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "toLowerCase");
    const out = try zstring.case.toLowerCase(allocator, data);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringCharAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "charAt");
    const idx: isize = toIntSat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    const out = try zstring.access.charAt(allocator, data, idx);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
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
    return interp(ctx).gcNewString(out);
}

fn stringRepeat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "repeat");
    const nf = if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0));
    // A negative or infinite count is a RangeError (before any saturation).
    if (nf < 0 or std.math.isInf(nf)) return interp(ctx).throwError(.range_error, "Invalid count value: {d}", .{nf});
    const count: isize = toIntSat(nf);
    const out = try zstring.transform.repeat(allocator, data, count);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
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
    var result = try interp(ctx).gcNewArray();
    for (parts) |p| {
        _ = try result.array.value.push(try interp(ctx).gcNewString(p));
    }
    return result;
}

fn stringTrim(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "trim");
    const out = try zstring.trimming.trim(allocator, data);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
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
/// coerces strings to index keys). Every returned key is a fresh,
/// caller-owned copy (unlike `ZObject.keys()`'s own borrowed-pointer
/// contract) -- required for the `.proxy` case, whose keys come from a
/// trap-returned array that gets torn down before this function
/// returns, so nothing else could safely borrow from it. The other arms
/// dupe too even though they technically could borrow, purely so every
/// caller can free the same uniform way (see `freeOwnedKeys`) instead of
/// needing to special-case one variant.
pub fn ownEnumerableKeys(ctx: *anyopaque, allocator: Allocator, v: JSValue) anyerror![][]const u8 {
    const borrowed: [][]const u8 = switch (v) {
        .object => |box| try box.value.keys(allocator),
        .function => |box| if (box.value.statics) |bag| try bag.object.value.keys(allocator) else try allocator.alloc([]const u8, 0),
        .@"undefined", .@"null" => return interp(ctx).throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        // ownKeys(target) -- narrowed: every trap-returned key is treated
        // as enumerable (real spec would filter via a
        // getOwnPropertyDescriptor call per key), matching this
        // engine's already-established "no invariant checking" scope
        // boundary for Proxy.
        .proxy => |box| {
            if (try interp(ctx).proxyTrap(box, "ownKeys")) |trap_fn| {
                defer trap_fn.deinit();
                const trap_result = try trap_fn.function.value.call(trap_fn.function.value.ctx, allocator, box.value.handler, &.{box.value.target});
                defer trap_result.deinit();
                if (trap_result != .array) return &.{};
                var keys: std.ArrayList([]const u8) = .empty;
                defer keys.deinit(allocator);
                for (trap_result.array.value.toSlice()) |item| {
                    if (item == .string) try keys.append(allocator, try allocator.dupe(u8, item.string.value.data));
                }
                return keys.toOwnedSlice(allocator);
            }
            return ownEnumerableKeys(ctx, allocator, box.value.target);
        },
        else => try allocator.alloc([]const u8, 0),
    };
    defer allocator.free(borrowed);
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |k| allocator.free(k);
        owned.deinit(allocator);
    }
    for (borrowed) |k| try owned.append(allocator, try allocator.dupe(u8, k));
    return owned.toOwnedSlice(allocator);
}

/// Pairs with `ownEnumerableKeys`' now-uniform "every key is a fresh,
/// owned copy" contract -- frees each string, then the container.
pub fn freeOwnedKeys(allocator: Allocator, ks: [][]const u8) void {
    for (ks) |k| allocator.free(k);
    allocator.free(ks);
}

fn objectKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = arg(args, 0);
    const ks = try ownEnumerableKeys(ctx, allocator, o);
    defer freeOwnedKeys(allocator, ks);
    var result = try interp(ctx).gcNewArray();
    for (ks) |k| {
        if (isSymbolKey(k)) continue;
        _ = try result.array.value.push(try interp(ctx).gcNewString(k));
    }
    return result;
}

fn objectValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const o = arg(args, 0);
    const ks = try ownEnumerableKeys(ctx, allocator, o);
    defer freeOwnedKeys(allocator, ks);
    var result = try interp(ctx).gcNewArray();
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
    defer freeOwnedKeys(allocator, ks);
    var result = try interp(ctx).gcNewArray();
    for (ks) |k| {
        if (isSymbolKey(k)) continue;
        var pair = try interp(ctx).gcNewArray();
        _ = try pair.array.value.push(try interp(ctx).gcNewString(k));
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

pub fn globalParseInt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
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

fn globalString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    // String(symbol) is the one explicit coercion the spec allows --
    // "Symbol(desc)" -- unlike implicit `sym + ''` which throws.
    if (arg(args, 0) == .symbol) {
        const s = try arg(args, 0).symbol.value.toString(allocator);
        defer allocator.free(s);
        return self.boxPrimitiveIfConstructed(ctx, this_value, try self.gcNewString(s));
    }
    // String(regex) is regex.toString() -- /source/flags (with flags).
    if (arg(args, 0) == .regex) {
        const st = self.regexState(arg(args, 0));
        const s = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ st.source, st.flags });
        defer allocator.free(s);
        return self.boxPrimitiveIfConstructed(ctx, this_value, try self.gcNewString(s));
    }
    const s = try coercion.toDisplayString(allocator, arg(args, 0));
    defer allocator.free(s);
    return self.boxPrimitiveIfConstructed(ctx, this_value, try self.gcNewString(s));
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

// ===== Error constructors =====

/// Comptime factory: one native per ErrorKind. The message argument is
/// coerced with toDisplayString (Node stringifies it too); no argument =
/// empty message.
fn errorConstructor(comptime kind: zvalue.ErrorKind) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = this_value;
            const has_msg = arg(args, 0) != .@"undefined";
            const msg: []const u8 = if (has_msg) try coercion.toDisplayString(allocator, arg(args, 0)) else "";
            defer if (has_msg) allocator.free(msg);
            return interp(ctx).gcNewError(kind, msg);
        }
    }.call;
}

// ===== Object.prototype methods (object_methods table) =====

fn requirePlainObject(ctx: *anyopaque, v: JSValue, what: []const u8) anyerror!JSValue {
    if (v != .object) return interp(ctx).throwError(.type_error, "{s} called on non-object", .{what});
    return v;
}

fn objHasOwnProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const key = try interp(ctx).encodeKey(arg(args, 0));
    defer allocator.free(key);
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
    if (this_value != .object) return JSValue.fromBool(false);
    const key = try interp(ctx).encodeKey(arg(args, 0));
    defer allocator.free(key);
    return JSValue.fromBool(this_value.object.value.propertyIsEnumerable(key));
}

fn objToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    return interp(ctx).gcNewString("[object Object]");
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
        .object, .array, .function, .@"error", .date, .promise, .map, .set, .regex, .temporal => v.retain(),
        else => try interp(ctx).ordinaryObject(),
    };
}

/// Shared by defineProperty/defineProperties/create: applies ONE
/// JS-shaped descriptor to obj[key], with the spec's partial-descriptor
/// merge on existing configurable properties. Defining bypasses
/// `writable` (that's assignment's rule, not definition's).
fn definePropertyFromJs(self: *Interpreter, obj: JSValue, key: []const u8, desc: JSValue) anyerror!void {
    const arena = self.gc_allocator;
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
        .proxy => |box| {
            if (try self.proxyTrap(box, "defineProperty")) |trap_fn| {
                defer trap_fn.deinit();
                const key_val = try self.gcNewString(key);
                defer key_val.deinit();
                const result = try trap_fn.function.value.call(trap_fn.function.value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, key_val, desc });
                defer result.deinit();
                if (!coercion.isTruthy(result)) {
                    return self.throwError(.type_error, "'defineProperty' on proxy: trap returned falsish for property '{s}'", .{key});
                }
                return;
            }
            return definePropertyOn(self, what, box.value.target, key, desc);
        },
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
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
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
    const self = interp(ctx);
    const obj = arg(args, 0);
    // ToPropertyKey, not ToString: a Symbol argument must resolve to the
    // exact same encoded key `arr[Symbol.iterator]`/`defineProperty`'s own
    // computed-key path already produces (`encodeKey`) -- ToString(symbol)
    // throws in real JS, but ToPropertyKey never stringifies a symbol at
    // all. Found via this session's own new Array/Map/Set/TypedArray
    // `[Symbol.iterator]` properties: `Object.getOwnPropertyDescriptor(arr,
    // Symbol.iterator)` (the natural way to introspect them, and test262's
    // own `verifyProperty` helper's exact call shape) previously threw an
    // uncatchable error instead of returning a real descriptor.
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
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
                return dataDescObj(self, try interp(ctx).gcNewString(box.value.name), false, false, true);
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
        .proxy => |box| {
            if (try self.proxyTrap(box, "getOwnPropertyDescriptor")) |trap_fn| {
                defer trap_fn.deinit();
                const key_val = try self.gcNewString(key);
                defer key_val.deinit();
                return try trap_fn.function.value.call(trap_fn.function.value.ctx, allocator, box.value.handler, &.{ box.value.target, key_val });
            }
            return objectGetOwnPropertyDescriptor(ctx, allocator, this_value, &.{ box.value.target, arg(args, 1) });
        },
        // Other object-likes (date/regex/map/...) have no string-keyed own
        // data properties in this model yet.
        else => return JSValue.UNDEFINED,
    }
}

fn objectGetOwnPropertyNames(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const o = arg(args, 0);
    var result = try interp(ctx).gcNewArray();
    switch (o) {
        .object => {
            const names = try o.object.value.getOwnPropertyNames(allocator);
            defer allocator.free(names);
            for (names) |n| {
                if (isSymbolKey(n)) continue;
                _ = try result.array.value.push(try interp(ctx).gcNewString(n));
            }
        },
        // Arrays: every index (as a string), then "length".
        .array => |box| {
            var i: usize = 0;
            while (i < box.value.length()) : (i += 1) {
                const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{i});
                defer allocator.free(idx_str);
                _ = try result.array.value.push(try interp(ctx).gcNewString(idx_str));
            }
            _ = try result.array.value.push(try interp(ctx).gcNewString("length"));
        },
        // Functions: length, name, prototype (if any), then statics bag names.
        .function => |box| {
            _ = try result.array.value.push(try interp(ctx).gcNewString("length"));
            _ = try result.array.value.push(try interp(ctx).gcNewString("name"));
            if (box.value.prototype != null or box.value.constructable)
                _ = try result.array.value.push(try interp(ctx).gcNewString("prototype"));
            if (box.value.statics) |bag| {
                const names = try bag.object.value.getOwnPropertyNames(allocator);
                defer allocator.free(names);
                for (names) |n| {
                    if (isSymbolKey(n)) continue;
                    _ = try result.array.value.push(try interp(ctx).gcNewString(n));
                }
            }
        },
        .@"undefined", .@"null" => return self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
        .proxy => |box| {
            if (try self.proxyTrap(box, "ownKeys")) |trap_fn| {
                defer trap_fn.deinit();
                const trap_result = try trap_fn.function.value.call(trap_fn.function.value.ctx, allocator, box.value.handler, &.{box.value.target});
                defer trap_result.deinit();
                if (trap_result == .array) {
                    for (trap_result.array.value.toSlice()) |item| {
                        if (item == .string) _ = try result.array.value.push(item.retain());
                    }
                }
            } else {
                const delegated = try objectGetOwnPropertyNames(ctx, allocator, this_value, &.{box.value.target});
                defer delegated.deinit();
                for (delegated.array.value.toSlice()) |item| _ = try result.array.value.push(item.retain());
            }
        },
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
    var result = try interp(ctx).gcNewArray();
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
    var obj = try interp(ctx).gcNewObject();
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
        .bigint => self.protos.bigint.retain(),
        .array_buffer => self.protos.array_buffer.retain(),
        .data_view => self.protos.data_view.retain(),
        .typed_array => |box| self.typedArrayProto(box.value.kind).retain(),
        .temporal => |box| self.protos.temporalProtoFor(box.value).retain(),
        // No getPrototypeOf trap dispatch yet (Proxy plan, later phase)
        // -- delegates transparently to target, correct for the
        // no-trap case.
        .proxy => |box| objectGetPrototypeOf(ctx, allocator, this_value, &.{box.value.target}),
        .@"undefined", .@"null" => self.throwError(.type_error, "Cannot convert undefined or null to object", .{}),
    };
}

// ===== Array / Function constructors and statics =====

fn arrayConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    var result = try self.gcNewArray();
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
    _ = allocator;
    _ = this_value;
    var result = try interp(ctx).gcNewArray();
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
    var result = try interp(ctx).gcNewArray();
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
        .set, .map => {
            const items = try self.iterableItems(src);
            defer self.gc_allocator.free(items);
            for (items) |item| {
                try push_mapped(self, allocator, &result, map_fn, item, index);
                index += 1;
            }
        },
        .string => |box| {
            var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
            while (it.nextCodepointSlice()) |cp| {
                try push_mapped(self, allocator, &result, map_fn, try interp(ctx).gcNewString(cp), index);
                index += 1;
            }
        },
        .object => {
            // Real @@iterator-presence-first, array-like fallback --
            // the array-like helper is shared with the TypedArray
            // constructor's equivalent overload (also fixes the
            // previous inline version's two spec inaccuracies: string
            // `length` now coerces, and a bare `{next(){...}}` object
            // with no `Symbol.iterator` is now correctly treated as
            // array-like, matching real Node).
            if (!(try hasIteratorMethod(self, src))) {
                const items = try arrayLikeToList(self, allocator, src);
                defer {
                    for (items) |it| it.deinit();
                    allocator.free(items);
                }
                for (items) |item| {
                    try push_mapped(self, allocator, &result, map_fn, item, index);
                    index += 1;
                }
            } else {
                // Manual per-step drain (NOT `iterableItems`, which
                // eagerly drains to completion before any caller code
                // runs) -- `mapFn` must be applied INLINE per `next()`
                // step so an infinite iterator combined with an
                // early-throwing `mapFn` still terminates (a real,
                // tested pattern: Array.from(infiniteIter, fnThatThrows)).
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

// ===== Number / String statics =====


fn stringFromCharCode(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
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
    return interp(ctx).gcNewString(buf.items);
}

// ===== Array.prototype (extended coverage) =====

pub fn normIndex(raw: f64, len: usize) usize {
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
    var result = try interp(ctx).gcNewArray();
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
    const val = arg(args, 0);
    const start: ?isize = if (arg(args, 1) == .@"undefined") null else toIntSat(try coercion.toNumber(arg(args, 1)));
    const end: ?isize = if (arg(args, 2) == .@"undefined") null else toIntSat(try coercion.toNumber(arg(args, 2)));
    // z-array's fill() copies `val`'s raw bytes into every touched slot
    // without retaining (doesn't know T is refcounted) and without
    // releasing what was there before. Use slice() as a read-only probe
    // over the SAME index math fill() will use internally, purely to
    // find out which slots are about to be touched: release what's
    // there now, retain `val` once per slot, then let fill() do the
    // actual write.
    var touched = try arr.slice(start, end);
    defer touched.deinit();
    for (touched.toSlice()) |v| v.deinit();
    for (touched.toSlice()) |_| _ = val.retain();
    arr.fill(val, start, end);
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
    var result = try interp(ctx).gcNewArray();
    try flattenInto(&result, allocator, this_value.array.value.toSlice(), depth);
    return result;
}

fn arraySplice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "splice");
    const arr = &this_value.array.value;
    const start: isize = if (args.len == 0) 0 else toIntSat(try coercion.toNumber(arg(args, 0)));
    // Spec nuance z-array's own `null` default doesn't capture: with
    // ZERO arguments at all, deleteCount is 0 (not "delete the rest");
    // with exactly one argument (start only, no deleteCount), it IS
    // "delete the rest" -- z-array's `null` already means that.
    const delete_count: ?usize = if (args.len == 0)
        0
    else if (args.len == 1)
        null
    else blk: {
        const dc = try coercion.toNumber(arg(args, 1));
        if (dc <= 0) break :blk 0;
        break :blk @intCast(toIntSat(dc));
    };
    // Retain each inserted value once (the array gains a reference,
    // separate from whatever the caller still holds) -- z-array's own
    // splice() copies raw bytes in, no retain of its own.
    const raw_inserts = if (args.len > 2) args[2..] else &[_]JSValue{};
    const inserts = try allocator.alloc(JSValue, raw_inserts.len);
    defer allocator.free(inserts);
    for (raw_inserts, 0..) |item, i| inserts[i] = item.retain();

    var deleted = try arr.splice(start, delete_count, inserts);
    defer deleted.deinit();
    // z-array's splice() already physically removed these from `arr`
    // (self.items.replaceRange), so `deleted` is the sole owner of that
    // reference -- moving it into the GC-tracked result is NOT a retain,
    // same "shallow move" contract as everywhere else this file talks to
    // z-array's raw ZArray(T).
    var removed = try interp(ctx).gcNewArray();
    for (deleted.toSlice()) |item| _ = try removed.array.value.push(item);
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
    return interp(ctx).gcNewString(s);
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
    return interp(ctx).gcNewString(out);
}

fn stringTrimEnd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const data = try requireString(ctx, this_value, "trimEnd");
    const out = try zstring.trimming.trimEnd(allocator, data);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
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
    return interp(ctx).gcNewString(out);
}

fn stringPadStart(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "padStart");
    const target: isize = toIntSat(try coercion.toNumber(arg(args, 0)));
    const pad: ?[]const u8 = if (arg(args, 1) == .string) arg(args, 1).string.value.data else null;
    const out = try zstring.padding.padStart(allocator, data, target, pad);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringPadEnd(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "padEnd");
    const target: isize = toIntSat(try coercion.toNumber(arg(args, 0)));
    const pad: ?[]const u8 = if (arg(args, 1) == .string) arg(args, 1).string.value.data else null;
    const out = try zstring.padding.padEnd(allocator, data, target, pad);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
}

fn stringSubstring(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const data = try requireString(ctx, this_value, "substring");
    const start: isize = toIntSat(if (arg(args, 0) == .@"undefined") 0 else try coercion.toNumber(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .@"undefined") null else toIntSat(try coercion.toNumber(arg(args, 1)));
    const out = try zstring.transform.substring(allocator, data, start, end);
    defer allocator.free(out);
    return interp(ctx).gcNewString(out);
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
    return interp(ctx).gcNewString(out);
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
    return interp(ctx).gcNewString(out);
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
    return interp(ctx).gcNewString(buf.items);
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
    _ = allocator;
    _ = args;
    const data = try requireString(ctx, this_value, "toString");
    return interp(ctx).gcNewString(data);
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
    return interp(ctx).gcNewString(buf.items);
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
    var result = try interp(ctx).gcNewArray();
    for (all.items) |match| _ = try result.array.value.push(try interp(ctx).gcNewString(match.group(data)));
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
    var arr = try interp(ctx).gcNewArray();
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
    const has_src = v != .@"undefined";
    const source = if (has_src) try coercion.toDisplayString(allocator, v) else "";
    defer if (has_src) allocator.free(source);
    return self.makeRegex(source, "");
}

/// String.prototype.replace/replaceAll with a regex pattern. Delegates
/// string replacements to z-regex (JS `$` substitution included);
/// function replacements loop the matches.
fn regexReplace(self: *Interpreter, allocator: Allocator, data: []const u8, re: JSValue, repl: JSValue, all_flag: bool) anyerror!JSValue {
    const st = self.regexState(re);
    const replace_all = st.global or all_flag;
    if (repl != .function) {
        const has_repl = repl != .@"undefined";
        const rs = if (has_repl) try coercion.toDisplayString(allocator, repl) else "undefined";
        defer if (has_repl) allocator.free(rs);
        const out = if (replace_all)
            try re.regex.value.replaceAll(allocator, data, rs)
        else
            try re.regex.value.replace(allocator, data, rs);
        defer allocator.free(out);
        return self.gcNewString(out);
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
        defer {
            for (call_args.items) |a| a.deinit();
            call_args.deinit(allocator);
        }
        try call_args.append(allocator, try self.gcNewString(match.group(data)));
        var i: usize = 1;
        while (i <= re.regex.value.compiled.group_count) : (i += 1) {
            const cap = if (match.getCapture(i, data)) |c| try self.gcNewString(c) else JSValue.UNDEFINED;
            try call_args.append(allocator, cap);
        }
        try call_args.append(allocator, JSValue.fromNumber(@floatFromInt(match.start)));
        try call_args.append(allocator, try self.gcNewString(data));
        const r = try repl.function.value.call(repl.function.value.ctx, allocator, JSValue.UNDEFINED, call_args.items);
        defer r.deinit();
        const rs = try coercion.toDisplayString(allocator, r);
        defer allocator.free(rs);
        try buf.appendSlice(allocator, rs);
        // advance past the match (empty match -> step one to avoid a loop)
        pos = if (match.end > match.start) match.end else match.end + 1;
        if (!replace_all) {
            try buf.appendSlice(allocator, data[match.end..]);
            return self.gcNewString(buf.items);
        }
    }
    if (pos < data.len) try buf.appendSlice(allocator, data[pos..]);
    return self.gcNewString(buf.items);
}

// ===== Reflect =====
//
// A plain non-constructable object (Math's pattern), each static a thin
// wrapper around the same interpreter internals every Proxy trap above
// dispatches through -- these take already-evaluated JSValue arguments,
// not AST nodes, so they're simpler than the trap dispatch itself.

fn reflectRequireObject(ctx: *anyopaque, what: []const u8, v: JSValue) anyerror!JSValue {
    if (!isObjectLike(v)) return interp(ctx).throwError(.type_error, "Reflect.{s} called on non-object", .{what});
    return v;
}

fn reflectGet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "get", arg(args, 0));
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    return self.getProperty(target, key);
}

fn reflectSet(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "set", arg(args, 0));
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    try self.setPropertyOnValue(target, key, arg(args, 2));
    return JSValue.fromBool(true);
}

fn reflectHas(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "has", arg(args, 0));
    return self.evalIn(arg(args, 1), target);
}

fn reflectDeleteProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "deleteProperty", arg(args, 0));
    const key = try self.encodeKey(arg(args, 1));
    defer allocator.free(key);
    return JSValue.fromBool(try self.deletePropertyOnValue(target, key));
}

/// Narrowing: excludes symbol-keyed properties, same as
/// `objectGetOwnPropertyNames` it delegates to (real `Reflect.ownKeys`
/// includes both string and symbol keys).
fn reflectOwnKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = try reflectRequireObject(ctx, "ownKeys", arg(args, 0));
    return objectGetOwnPropertyNames(ctx, allocator, this_value, args);
}

fn reflectGetPrototypeOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = try reflectRequireObject(ctx, "getPrototypeOf", arg(args, 0));
    return objectGetPrototypeOf(ctx, allocator, this_value, args);
}

fn reflectDefineProperty(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = try reflectRequireObject(ctx, "defineProperty", arg(args, 0));
    const key = try self.encodeKey(arg(args, 1));
    defer self.gc_allocator.free(key);
    // Narrowing: this engine's definePropertyOn throws on failure rather
    // than returning false for every real spec failure mode -- Reflect's
    // "return false instead of throwing" contract only actually applies
    // to the cases that don't already throw here.
    try definePropertyOn(self, "defineProperty", target, key, arg(args, 2));
    return JSValue.fromBool(true);
}

fn reflectGetOwnPropertyDescriptor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = try reflectRequireObject(ctx, "getOwnPropertyDescriptor", arg(args, 0));
    return objectGetOwnPropertyDescriptor(ctx, allocator, this_value, args);
}

fn reflectApply(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = arg(args, 0);
    const this_arg = arg(args, 1);
    const arg_list = arg(args, 2);
    const call_args: []const JSValue = switch (arg_list) {
        .@"undefined", .@"null" => &.{},
        .array => |box| box.value.toSlice(),
        else => return self.throwError(.type_error, "CreateListFromArrayLike called on non-object", .{}),
    };
    return self.callValue(target, this_arg, call_args, "target");
}

fn reflectConstruct(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = arg(args, 0);
    const arg_list = arg(args, 1);
    const call_args: []const JSValue = switch (arg_list) {
        .@"undefined", .@"null" => &.{},
        .array => |box| box.value.toSlice(),
        else => return self.throwError(.type_error, "CreateListFromArrayLike called on non-object", .{}),
    };
    if (!self.isConstructor(target)) {
        return self.throwError(.type_error, "target is not a constructor", .{});
    }
    const new_target_arg = arg(args, 2);
    const new_target: JSValue = if (new_target_arg == .@"undefined") target else new_target_arg;
    if (!self.isConstructor(new_target)) {
        return self.throwError(.type_error, "newTarget is not a constructor", .{});
    }
    // Narrowing: newTarget's distinct-prototype-source subclassing
    // behavior is not modeled -- constructValue always uses `target`'s
    // own prototype, matching plain `new target`.
    return self.constructValue(target, call_args, "target");
}
