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

## Known gaps (deferred to future phases)

- **`switch`, `try`/`catch`/`finally`/`throw`**: no JS-level exception model yet (`Completion`'s `type` enum has room for a future `throw_completion` without reshaping anything).
- **`with`**.
- **`for-in`/`for-of`**: needs the iteration protocol (`Symbol.iterator`), a real follow-on piece even though `.function` (needed for a `next()` method) now technically exists.
- **Labelled `break`/`continue`**: unlabelled works (the nearest-enclosing-loop case falls out of recursive Completion propagation for free); labelled needs a label-stack threaded through statement recursion (mirroring `z-statements`' own parse-time `is_loop`/label-chain walk) — real, self-contained work, not a one-liner. `Completion.target` is already in place for when this lands.
- **`new`** (constructor/prototype-for-instances semantics), **`instanceof`**, **`in`**.
- **Classes, generators, `async`/`await`, destructuring**: not even parseable yet anywhere in this ecosystem.
- **Regex literals**: parse fine (`z-parser`), but evaluating one to a real `.regex` `JSValue` needs `zregexp`, which this repo deliberately doesn't depend on for this narrow phase — `error.NotImplemented`.
- **No hoisting, no TDZ**: `var`/`let`/`const`/function declarations are all evaluated strictly in source order, defining directly into the current environment. A real, known divergence from spec (e.g. `console.log(x); var x = 1;` is `undefined` in real JS via hoisting; here it's a `ReferenceError`).
- **Bitwise operators** (`&`/`|`/`^`/`<<`/`>>`/`>>>`): need ToInt32, not implemented this phase.
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
