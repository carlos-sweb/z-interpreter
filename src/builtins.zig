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
pub const error_methods = error_builtins.error_methods;
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

// z-interpreter-refactor.md, Step 5 Phase A batch 5: Array.prototype
// (basic + extended coverage) + the Array constructor/statics. No
// interleaving found (first batch since batch 4 without one) --
// confirmed via a whole-file cross-reference check, not guessed.
// `normIndex` moves here from its previous `pub fn` home directly in
// builtins.zig; `arraybuffer_builtins.zig`'s existing
// `const normIndex = builtins.normIndex;` needs no edit since this
// re-export keeps that name resolving the same way.
const array_builtins = @import("array_builtins.zig");
pub const array_methods = array_builtins.array_methods;
pub const normIndex = array_builtins.normIndex;

// z-interpreter-refactor.md, Step 5 Phase A batch 6: String.prototype
// (basic + extended coverage + RegExp-pattern methods) + the String
// constructor/statics. One interleaving find: `stringFromCodePoint`
// physically lived inside the old "String.prototype (extended
// coverage)" section (should have been next to `stringFromCharCode`, a
// static) -- grouped correctly in the new file instead of transcribed
// forward. `argString`'s `builtins.argString` re-export (added for
// `globalParseInt`/`globalParseFloat`'s sake) is gone as of batch 10:
// globals_builtins.zig now imports string_builtins.zig directly for it.
const string_builtins = @import("string_builtins.zig");
pub const string_methods = string_builtins.string_methods;

// z-interpreter-refactor.md, Step 5 Phase A batch 7: Object statics +
// Object.prototype methods + property descriptors -- the biggest
// remaining domain, with the real Object-must-come-first bootstrap
// ordering constraint (see object_builtins.zig's module doc comment).
// `ownEnumerableKeys`/`freeOwnedKeys` stay re-exported since
// interpreter.zig reaches them as `builtins.X`.
const object_builtins = @import("object_builtins.zig");
pub const object_methods = object_builtins.object_methods;
pub const ownEnumerableKeys = object_builtins.ownEnumerableKeys;
pub const freeOwnedKeys = object_builtins.freeOwnedKeys;

// z-interpreter-refactor.md, Step 5 Phase A batch 8: Reflect (statics-only,
// no constructor -- Math's pattern). No interleaving found: this section
// was already self-contained. `definePropertyOn`/
// `objectGetOwnPropertyDescriptor`/`objectGetOwnPropertyNames`/
// `objectGetPrototypeOf` (previously reached back from this file for
// Reflect's sake) are no longer needed here -- reflect_builtins.zig now
// imports object_builtins.zig directly for them.
const reflect_builtins = @import("reflect_builtins.zig");

// z-interpreter-refactor.md, Step 5 Phase A batch 9: the Error constructor
// family (Error/TypeError/RangeError/SyntaxError/ReferenceError/
// EvalError/URIError). No interleaving possible -- this was already a
// single self-contained section.
const error_builtins = @import("error_builtins.zig");

// z-interpreter-refactor.md, Step 5 Phase A batch 10 (FINAL batch of
// Phase A): the "loose globals" grab-bag -- console/print,
// parseInt/parseFloat/isNaN/isFinite, indirect eval. Nothing left in
// this file reaches back into it: number_builtins.zig now imports
// globals_builtins.zig directly for globalParseInt/globalParseFloat
// instead of through builtins.zig.
const globals_builtins = @import("globals_builtins.zig");

// ===== Globals =====

/// Installs every global binding. Called lazily from `run()` (never from
/// init) so `self: *Interpreter` is a stable address for native ctx.
pub fn setupGlobals(self: *Interpreter) !void {
    const arena = self.gc_allocator;
    const g = self.global_env;

    try g.define(arena, "undefined", JSValue.UNDEFINED);
    try g.define(arena, "NaN", JSValue.fromNumber(std.math.nan(f64)));
    try g.define(arena, "Infinity", JSValue.fromNumber(std.math.inf(f64)));

    // Object comes first: see object_builtins.zig's module doc comment for
    // why (every other builtin's ordinaryObject() calls need real
    // Object.prototype to already exist).
    try object_builtins.install(self);

    try math_builtins.install(self);

    try reflect_builtins.install(self);

    try json_builtins.install(self);

    try array_builtins.install(self);

    try function_builtins.install(self);

    try date_builtins.install(self);

    try temporal_builtins.install(self);

    try proxy_builtins.install(self);

    try arraybuffer_builtins.install(self);

    try error_builtins.install(self);

    try promise_builtins.install(self);
    try symbol_builtins.install(self);

    try regex_builtins.install(self);
    try mapset_builtins.install(self);

    try globals_builtins.install(self);

    try string_builtins.install(self);

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

