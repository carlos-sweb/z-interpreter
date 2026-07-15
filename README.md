# Z-Interpreter

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A minimal **tree-walking interpreter** for the z-* ECMAScript engine — the fifth repo, and the first that actually *executes* code instead of only tokenizing/parsing it. Ties together [z-parser](https://github.com/carlos-sweb/z-parser) (§13 expressions), [z-statements](https://github.com/carlos-sweb/z-statements) (§14 statements), [z-functions](https://github.com/carlos-sweb/z-functions) (§15 functions/arrows), and [z-value](https://github.com/carlos-sweb/z-value) (`JSValue`) into something that produces observable behavior — including a real `console.log("Hello World")`. Part of the [z-*](https://github.com/carlos-sweb) micro-library family.

## Scope: enough to make closures, loops, and console output actually work

Not spec completeness — validating the whole pipeline end-to-end for the first time. In scope: all literals, identifiers, template literals, array/object literals (including spread), every non-bitwise operator, member access (`.`/`[]`/`?.`), call expressions with correct `this`-binding for method calls, function declarations/expressions/arrows (with closures that genuinely capture and mutate variables across calls), default/rest parameters, `if`/`while`/`do-while`/C-style `for` with correct `break`/`continue`/`return` semantics across arbitrarily nested blocks, and a `console` global. See [Known gaps](#known-gaps-deferred-to-future-phases) for what's deliberately not wired up yet (each raises `error.NotImplemented`, not a crash or silent wrong answer).

## Design

- **`JSValue` gained a `.function` variant** (in `z-value`, not here) — see that repo's own changelog. The payload, `Callable` (`ctx: *anyopaque` + `call: *const fn(...) anyerror!JSValue`), is z-value's own type, deliberately independent of this repo — this repo supplies two kinds of `ctx`/`call` pairs: native functions (`console.log`) and user closures (`ClosureCtx { function_node, closure_env, interp }`).
- **One arena for an entire interpreter run** (`Interpreter.arena_state`), used for *both* environments and every `JSValue` this interpreter creates. Closures need their defining environment to outlive the call that created them (a classic aliasing problem); the correct general solution is GC or a refcounted environment graph (with the same cycle risk `z-value` already documents as an accepted gap). For a first interpreter, one arena freed in a single shot at `Interpreter.deinit()` is the pragmatic, explicitly-chosen simplification — correct for a single script run, which is the only case that matters here. `Rc(T)`'s `retain()`/`deinit()` discipline is still followed everywhere (the underflow assert in `Rc(T).decref()` remains a real bug detector even though the underlying free is a no-op under an arena).
- **Real ECMA-262 Completion Records** (`{ type, value, target }` in `completion.zig`), not naive Zig `break`/`continue`/`return` — those can't express "unwind through arbitrarily nested blocks/`if`s to the nearest loop/function boundary," which is exactly what JS's control-flow statements need. Every statement-evaluation function returns a `Completion`; blocks/loops/function-call boundaries each catch the completion types relevant to them and propagate the rest unchanged.
- **A narrow coercion layer** (`coercion.zig`) supplies ToBoolean/ToNumber/ToString/a subset of Abstract Equality — none of which exist anywhere upstream (`JSValue` deliberately has none of this). Scoped to exactly what this phase's operators need; anything requiring real ToPrimitive (object/array/function on the left of `+`'s numeric branch, `==` against a mismatched non-primitive tag, etc.) is `error.NotImplemented`.
- **`console.log`'s formatter (`inspect.zig`) is standalone, not `z-json`** — `JSON.stringify`'s rules (omits `undefined`/functions, quotes every string) are wrong for `console.log` (top-level strings shouldn't be quoted; `undefined` should still print something). Legible, not spec-exact.
- **Named function expressions can reference themselves recursively by name** (`const f = function fact(n) { return fact(n-1); }`) via a thin wrapper environment binding the name to the closure itself — the name is visible only inside the function's own body, not in the enclosing scope.
- **`console_writer: *std.Io.Writer` is injected**, never hardcoded to real stdout — tests point it at `std.Io.Writer.Allocating` instead of touching the process's actual stdout.

## Exceptions

`throw`/`try`/`catch`/`finally` are fully implemented per ECMA-262 §14.15.3, including the classic finally-override semantics (`try { return 1 } finally { return 2 }` → 2; a finally-throw drops the original exception) — each gotcha cross-checked against real Node.js. Exceptions travel as a module-private Zig error signal (`error.JsThrow`) plus a `pending_exception: ?JSValue` side channel on `Interpreter`, **not** as a `Completion` variant — they must unwind through *expression* evaluation too (any call can throw), and `evalExpression` returns `JSValue`, not `Completion`; the Zig error channel crosses every frame including the `Callable.call` vtable boundary. Engine errors (`ReferenceError`/`TypeError`) are real catchable JS values with Node-matching messages, and `e.name`/`e.message` work in catch bodies. Interpreter feature gaps (`error.NotImplemented`) are deliberately **not** catchable from JS — a `catch` swallowing "the interpreter doesn't support this yet" would produce silently-wrong programs. Uncaught exceptions surface as `error.UncaughtException` with the thrown value inspectable via `pending_exception`.

## Constructors and prototypes

`new F(args)` implements a narrowed ECMA-262 10.2.2 [[Construct]]: a fresh object wired (via `ZObject`'s existing prototype-chain machinery) to `F.prototype` — created lazily with `constructor` pointing back at `F` — becomes `this` inside the constructor body, and an object-like return value overrides the instance while a primitive return is ignored. Method lookup through the chain is live (methods added to `F.prototype` *after* an instance was constructed still resolve). Arrows and native functions are not constructors (`constructable: false` on `Callable`) — `new` on them is a real TypeError. `instanceof` walks the LHS prototype chain by pointer identity against `F.prototype`; `in` checks own + inherited properties (plus numeric indices/`length` on arrays), with the spec's TypeError on primitive receivers. All Node-verified.

## Switch and labels

`switch` implements ECMA-262 §14.12 CaseBlockEvaluation faithfully: the discriminant is evaluated once, selectors are evaluated in order only until the first strict-equality match, fallthrough is natural (including *through* a mid-list `default`'s statements when the match came before it), and the whole CaseBlock is one lexical scope. Labelled `break`/`continue` implement §14.13 via label sets passed as a parameter to each loop evaluator (the spec's own labelSet, not mutable interpreter state) — chains (`a: b: for(...)`) attach every label in the chain, labelled breaks travel correctly through intervening `switch`/`try-finally` frames, and non-loop labelled statements (`a: { break a; }`, `a: if (...) break a;`) convert a matching break to normal at the labelled wrapper. All cross-checked against real Node.js.

## Built-ins

The z-* ecosystem's already-implemented methods are exposed to JS as native functions: **Array.prototype** (`push`/`pop`/`shift`/`unshift`/`indexOf`/`includes`/`join`/`slice`/`concat`/`reverse` plus the callback-taking `map`/`filter`/`forEach`/`reduce`/`find`/`some`/`every`, which invoke JS callables from native code), **String.prototype** (`toUpperCase`/`toLowerCase`/`charAt`/`indexOf`/`includes`/`startsWith`/`endsWith`/`slice`/`repeat`/`split`/`trim` — direct reuse of z-string's standalone method modules), **Math** (z-math's spec-exact functions + `PI`/`E`/`random`), **JSON** (`stringify`/`parse` via z-json, with parse failures as catchable SyntaxErrors), **Object** statics (`keys`/`values`/`entries`/`assign`), `Array.isArray`, and loose globals (`parseInt`/`parseFloat`/`isNaN`/`isFinite`/`String`/`Number`/`Boolean`). Methods are shared per (type, name) and cached, so `a.push === b.push` holds like real prototype methods; `evalCall` already passes the receiver as `this`, so no per-receiver binding exists and a detached call (`const f = a.push; f()`) is a TypeError like real JS. `Object`/`Array`/`Math`/`JSON` are plain objects, not constructor functions (`typeof Object === "object"`, no `new Object()`) — functions here have no property bag.

## Iteration

`for-of` iterates the built-in iterables natively: arrays (elements), strings (**Unicode code points**, surrogate pairs together — the real spec behavior), maps (`[key, value]` pair arrays), and sets (values); everything else — plain objects included — is a real TypeError, exactly like Node. `for-in` yields enumerable string keys, own **and inherited** (walking the prototype chain, shadowed keys seen once), array/string indices as strings, and — per spec — zero iterations without error over `null`/`undefined`. Declared bindings (`let`/`const`) get a fresh environment per iteration, so closures created in the body capture that iteration's value. All Node-verified.

## Known gaps (deferred to future phases)

- **`with`**.
- **User-defined iterables (`Symbol.iterator` protocol)**: requires symbol-keyed properties, and `ZObject` is string-keyed only — for-of covers the built-in iterables natively instead.
- **`constructor` shows up in `for-in`**: our narrowed model stores it as an ordinary (enumerable) property; real JS marks it non-enumerable.
- **Arbitrary properties on function values**: only `prototype` (writable), `name`, and `length` exist — functions here have no general property bag (`F.myProp = 1` is NotImplemented).
- **Classes, generators, `async`/`await`, destructuring**: not even parseable yet anywhere in this ecosystem.
- **Regex literals**: parse fine (`z-parser`), but evaluating one to a real `.regex` `JSValue` needs `zregexp`, which this repo deliberately doesn't depend on for this narrow phase — `error.NotImplemented`.
- **No hoisting, no TDZ**: `var`/`let`/`const`/function declarations are all evaluated strictly in source order, defining directly into the current environment. A real, known divergence from spec (e.g. `console.log(x); var x = 1;` is `undefined` in real JS via hoisting; here it's a `ReferenceError`).
- **`this` for constructors**: only the member-call case (`obj.method()`) is wired; no `new`-based `this` binding.

## Usage

```zig
const zinterpreter = @import("zinterpreter");

var allocating = std.Io.Writer.Allocating.init(allocator);
defer allocating.deinit();

var interp = try zinterpreter.Interpreter.init(allocator, &allocating.writer);
defer interp.deinit();

const result = try interp.run("console.log(\"Hello World\");");
// allocating.written() == "Hello World\n"
```

## Testing

```bash
zig build test
```

## License

MIT
