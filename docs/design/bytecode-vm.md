# Design: JavaScript Bytecode VM for z-interpreter

**Status:** design only — no implementation in this document  
**Date:** 2026-10-15  
**Scope:** replace the hot path of the tree-walking interpreter with a
compile-once, execute-many bytecode VM, using z-regex's compile→bytecode→VM
pipeline as the in-ecosystem reference model.  
**Non-goals:** writing Zig sources, changing production manifests, running
Test262 sweeps, or committing.

---

## 0. Motivation (measured)

Local microbenchmarks on the same host (ReleaseFast `z-run` vs Bun 1.3):

| Workload | bun | z-run | Ratio |
|----------|-----|-------|-------|
| `fib(0..19)` (startup-heavy) | ~11 ms | ~164 ms | ~15× |
| `fib(30)×5` (compute-heavy) | ~44 ms | ~42 s | ~957× |

The second row is **per-operation interpreter cost**, not parse or host I/O.
Bun embeds JavaScriptCore (bytecode + JIT). Closing the gap means changing the
**execution representation**. This document covers the current model, the
z-regex reference, JS-specific VM requirements, ISA/`CodeBlock` design,
AST/VM coexistence, risks, and Grok analysis phases 0–5 (2026-10-15).

---

## 1. Current interpreter: tree-walker over AST

### 1.1 End-to-end path (z-run → engine)

```
z-run main
  → Interpreter.init + host globals
  → runModule(path) | run(source)
       → ModuleLoader / source bytes
       → zfunctions.Parser.parseProgram()   // lexer → recursive descent → AST
       → evalBody / evalStatement…
            → evalExpression(node)          // switch on node.data
                 → .call → evalCall
                      → Callable.call → closureCall
                           → invokeFunctionNode
                                → gcChildEnv + params + evalBody
```

Relevant entry points (current sources under `/home/sweb/z-interpreter`):

- `interpreter_runtime.zig` — `run`, `evalSource`
- `interpreter_module.zig` — `runModule`, `loadModule` (parse + evaluate)
- `interpreter_expr.zig` — `evalExpression`, `evalCall`
- `interpreter_class.zig` — `invokeFunctionNode`, `closureCall`
- `environment.zig` — string-keyed `StringHashMap` bindings + parent walk
- `completion.zig` / `interpreter_stmt.zig` — Completion vs `error.JsThrow`

The AST lives on the interpreter's **arena** (bulk-freed with the run).
Runtime values and environments use the **GC allocator** and Rc boxes from
`z-value`.

### 1.2 How `evalExpression` walks the AST

`evalExpression(self, env, node)` is the expression hot path. Rough shape:

1. Optional stack-depth guard via `@frameAddress()` vs `stack_limit`.
2. `switch (node.data)` over every expression kind.
3. Recurse into child `*zparser.Node` pointers for compounds.

Representative arms (conceptual, not a code dump):

| AST arm | Behavior today |
|---------|----------------|
| `number_literal` / `boolean` / `null` | Build inline `JSValue` |
| `string_literal` | `gcNewString` |
| `identifier` | `env.lookup(name)` (HashMap + parent walk), then `retain` |
| `paren` | Recurse into inner node |
| `binary` | Eval left, eval right, `applyBinaryOp` / `instanceof` / `in` |
| `logical` | Short-circuit via `isTruthy` |
| `call` | Delegate to `evalCall` |
| `member` | Eval object, resolve key, `getProperty` |
| `assignment` | `evalAssignment` |
| function / class / await / yield / … | Specialized helpers |

Every recursive call pays: Zig frame setup, tag dispatch, pointer chasing
through arena-allocated nodes, and the uniform ownership contract
(`retain`/`deinit` on producers and discard points).

### 1.3 How a JS call works today

For a plain closure call (`fib(n-1)`):

1. `evalCall` evaluates the callee expression (often another `identifier`
   lookup of `fib`).
2. `evalArgs` evaluates each argument expression.
3. `Callable.call` → `closureCall` → `invokeFunctionNode`.
4. `invokeFunctionNode`:
   - `gcChildEnv(closure_env)` — new `Environment`, GC-tracked.
   - Materializes an **`arguments` array** for every non-arrow call.
   - Binds parameters via `bindPattern` (name → HashMap slot).
   - Runs the body with `evalBody` / `evalExpression` again.

For `fib(30)×5` this path runs on the order of **millions of calls**. Parse
happens once; almost all wall time is steps 1–4.

### 1.4 Strengths and limits

Good for: spec-shaped iteration, growing language surface, debugging without
a separate sourcemap. Insufficient for a competitive executor: no compact
instruction stream, no slot addressing, no cheap call convention, no IR for
ICs/JIT.

**Bottleneck ranking (`fib`-class; confirmed by 15× → 957× when work grows):**
(1) re-walking AST, (2) `Environment` + `arguments` per call, (3) string
HashMap lookups, (4) generic operators, (5) deep Zig frames (~1k practical),
(6) parse/startup (tiny scripts only).

---

## 2. Reference model: z-regex

z-regex (pinned in the z-run package cache as `zregex-0.9.1`, sources under
`zig-pkg/zregex-0.9.1-…`) already implements the architectural pattern this
design wants for JS: **front-end → IR → bytecode → VM loop**, with the
bytecode as the stable execution artifact.

### 2.1 Compile pipeline

High-level flow (`src/compile.zig` orchestrates):

```
pattern string
  → frontend (lexer / parser / lower to HIR)
  → tier classification (tier0 linear VM vs tier2 backtracker)
  → CodeGenerator (tier2/codegen/generator.zig)
  → BytecodeWriter → []u8 bytecode
  → CompileResult { bytecode, charsets, group_count, mode, … }
```

Important properties:

- The **pattern AST/HIR is not interpreted** at match time for the common
  path; matching runs against bytecode.
- `CompileResult` packages bytecode **plus side tables** the bytecode alone
  cannot carry (notably `charsets`). The docs state explicitly that bytecode
  alone is not a complete executable program.
- Compilation is **once per pattern**; execution is many times (`test`,
  `exec`, `find`, …).

### 2.2 Opcodes: domain-complete for regex

Defined in `tier2/bytecode/opcodes.zig` (libregexp-inspired `enum(u8)`).
Categories that matter as a design lesson:

| Category | Examples | Why they suffice for regex |
|----------|----------|----------------------------|
| Character match | `CHAR`, `CHAR32`, `CHAR_RANGE`, `CHAR_CLASS`, `CHAR_SET`, Unicode property/script ops | Consume / test one subject character |
| Control flow | `MATCH`, `GOTO`, `SPLIT`, `SPLIT_GREEDY`, `SPLIT_LAZY`, `SPLIT_POSSESSIVE` | Alternation, quantifiers, success |
| Captures | `SAVE_START`, `SAVE_END`, `CLEAR_CAPTURE`, named variants | Group slots as indices |
| Backrefs / anchors / lookarounds | `BACK_REF*`, `STRING_START`, `LINE_*`, look ops | Regex-specific state on the subject |
| Repeat guards | `REPEAT_MARK`, `REPEAT_CHECK` | Nullable-quantifier progress |

The ISA is **small, byte-oriented, and PC-relative**. Operands are immediate
or table indices. There is no heap object model, no dynamic types, and no
user-defined functions inside the match VM.

Why this is enough for the domain:

- The “program” is a pure recognizer over a subject string.
- Branching is nondeterministic (backtrack / split), not JS control flow.
- “Locals” are capture slots and mark slots — fixed at compile time.
- Failure is “no match”, not an exception object.

### 2.3 Execution: VM loop and dispatch

Tier-2 backtracker (`tier2/executor/backtrack.zig`), conceptual loop:

```
pc = start_pc
pos = start_pos
while true:
    inst = decode(bytecode, pc)
    result = exec1(inst)   // switch on opcode
    if MATCH: return pos
    if fail:  if !backtrack(&pc, &pos): return null
    else:     continue with updated pc/pos
```

`exec1` is a dense `switch (inst.opcode)`: character ops advance `pos`,
`GOTO`/`SPLIT*` adjust `pc` and may push choice points, capture ops write
slots (with undo on backtrack).

Tier-0 exists as a faster linear VM for a restricted pattern class — a useful
reminder that **one ISA can have multiple executors**.

### 2.4 Reuse vs do-not-reuse

**Reuse (ideas, not the regex ISA):** compile-once/run-many; bytecode + side
tables; indexed slots; dense opcode-switch VM; explicit program object
(`CompileResult` ≈ `CodeBlock`); tiered executors (slow path for rare shapes).

**Do not reuse:** subject cursor; `SPLIT`/backtracking as control; match/fail
as sole outcome; capture undo instead of retained closures; per-op character
decode; treating the program as stateless over an external tape; regex
`max_steps` as the budget model.

Share the *pipeline shape* (compile → compact code → loop), not the opcode
enum. Do not extend regex opcodes into a JS VM.

---

## 3. What a JS bytecode needs that z-regex does not have

### 3.1 Closures (capture by slots, not by string)

Today a closure is a `Callable` whose `ClosureCtx` holds `*FunctionNode` +
`*Environment`. Free variables are found by **string lookup** up the parent
chain at every access.

Bytecode requirement:

- Scope analysis assigns each binding a **slot index** (local) or a
  **capture index** (closed-over).
- A closure value carries a `CodeBlock*` plus a **capture vector**
  (`[]JSValue` or a compact environment object keyed by index).
- Opcodes: `LoadLocal r,i`, `StoreLocal r,i`, `LoadCapture r,i`,
  `StoreCapture r,i`, `MakeClosure dst, code_idx, capture_list`.

No `HashMap` on the hot path for `n` inside `fib`.

### 3.2 `this`

JS calls distinguish:

- Bare calls → `this` is `undefined` (engine is always-strict).
- Method calls (`obj.m()`) → `this` is the base object.
- `super` / constructors → additional construct-target state.
- Arrows → lexical `this` (inherit; do not bind).

Bytecode requirement:

- Call protocol passes an explicit `this` register/operand.
- Arrow `CodeBlock` flag: `lexical_this` — ignore caller's `this`, read from
  the captured environment.
- Opcodes: `LoadThis r`, and call forms `Call` / `CallMethod` that set `this`.

### 3.3 Exceptions (`try` / `catch` / `finally`)

Today:

- Normal/abrupt non-throw completions use `Completion`
  (`normal`, `return`, `break`, `continue`).
- Throws use **`error.JsThrow` + `pending_exception`** (deliberately not a
  Completion variant), merged at try/finally via `Outcome`.

Bytecode requirement:

- Per-`CodeBlock` **exception table**: `[start_pc, end_pc) → handler_pc`
  with handler kind (`catch`, `finally`, or combined).
- `Throw r` sets pending exception and unwinds VM frames until a handler
  covers the current PC.
- `finally` must run on return/break/continue/throw — either by synthesizing
  exits at compile time or by a small exit-reason register the handler
  inspects (mirrors today's `Outcome` merge).
- Do **not** invent a second exception channel; keep `pending_exception` as
  the engine-visible throw state so natives and the VM share one model.

### 3.4 Generators and async (existing fibers)

Today generators/async/async-generators allocate a `FiberState`, run the
evaluator on a fiber stack, and suspend on `yield` / `await` via
`resumeFiber` / `awaitValue`.

Bytecode requirement:

- A suspending `CodeBlock` is still ordinary bytecode, but the **VM frame**
  (PC + registers + try stack) must be saveable into `FiberState` instead of
  relying on native Zig recursion depth inside `evalExpression`.
- Opcodes: `Yield r`, `Await r` (or `Yield`/`Await` that write into a
  designated resume slot).
- On resume, restore PC/regs and continue the VM loop — the fiber trampoline
  stays; the payload becomes “run VM from saved PC” rather than “re-enter
  tree-walker”.

This is the largest integration constraint: **fibers must own VM frames**,
not AST evaluation stacks.

### 3.5 Types (`JSValue`)

Regex ops are untyped character tests. JS ops are dynamically typed:

- Numbers are often inline in the `JSValue` union (cheap `retain`/`deinit`).
- Objects/strings/functions are Rc boxes.
- Operators must implement ToNumber / ToPrimitive / string concat, etc.

Bytecode requirement:

- Values in registers are `JSValue` (or a VM-internal tagged word isomorphic
  to it).
- Fast-path opcodes for monomorphic number ops (`AddNum`, `SubNum`, `EqNum`,
  `LtNum`, …) that fall back to generic ops or throw on mismatch.
- Generic opcodes (`Add`, `EqLoose`, `EqStrict`, …) call into existing
  `coercion.zig` helpers so semantics stay shared with the AST path during
  the transition.

### 3.6 Environments and scopes

Today every call builds a heap `Environment` with string maps (bindings, TDZ,
consts).

Bytecode requirement:

- **Activation record** = register file of length `local_count`, plus optional
  cell box for captured mutables.
- TDZ becomes a bitset or sentinel in the slot, checked by `LoadLocal` when
  the binding is temporal-dead.
- `var` / function hoisting become compile-time slot allocation + prologue
  stores, not a runtime HashMap fill of names.
- Global / module env can remain object-like or name-keyed at the boundary;
  the win is inside function activations.

### 3.7 Summary gap table

| Concern | z-regex | JS VM needs |
|---------|---------|-------------|
| Values | positions / bits | `JSValue` |
| Names | group indices | slot / capture indices + property keys |
| Calls | none | call protocol + `this` + args |
| Control | SPLIT/backtrack | jumps, loops, switch, return |
| Failure | no-match | exceptions + Completion |
| Suspension | none | fiber-saveable frames |
| Heap | side tables only | full JS heap via z-value |
| Host | N/A | jobs API, natives, modules |

---

## 4. Proposed design

### 4.1 ISA choice: register-based

**Choice: register-based** (Lua / QuickJS / Hermes style), not pure stack.

Reasons:

1. **Slots fall out of scope analysis** — locals already want indices; a
   register file *is* the activation.
2. **Fewer memory ops than stack traffic** for `a = b + c` style code (the
   `fib` body).
3. **Closer to a future baseline JIT** — registers map to machine regs or
   spill slots more directly than a value stack.
4. **Matches the closure model** — captures are just another register-like
   index space.
5. z-regex's PC+immediate style still applies: instructions remain compact
   (`op`, `A`, `B`, `C` or `op`, `A`, `imm`).

Stack-based is simpler to emit from a naive AST walk, but we already plan a
real compiler pass for slots; paying that cost once favors registers.

**Encoding sketch (illustrative):**

- Fixed-width 32-bit instructions where possible: `op:8 | a:8 | b:8 | c:8`
  or `op:8 | a:8 | imm:16`.
- Wide immediates and constant indices via `op + u32` trailing word when
  needed (same spirit as regex multi-byte operands).

### 4.2 Core opcode families (v1)

Enough for `fib` and most strict-mode bodies; ICs later.

- **Moves/constants:** `LoadConst`, `Move`, `LoadLocal`/`StoreLocal`,
  `LoadCapture`/`StoreCapture`, `LoadGlobal`/`StoreGlobal`, `LoadThis`,
  `LoadUndefined`/`Null`/`True`/`False`.
- **Number fast path:** `AddNum`/`SubNum`/`MulNum`/`DivNum`/`ModNum`,
  `EqNum`/`LtNum`/…, `ToNumber`.
- **Generic ops:** `Add`, `EqStrict`, `EqLoose`, `TypeOf`, `InstanceOf`, `In`.
- **Control:** `Jump`, `JumpIfTrue`/`False`, `Return`, `ReturnUndefined`,
  `Throw`.
- **Calls/objects:** `Call`, `CallMethod`, `New`, `GetProp`/`SetProp`,
  `GetElem`/`SetElem`, `MakeArray`/`MakeObject`/`MakeClosure`.
- **Suspension:** `Yield`, `Await` (fiber-backed).
- **Meta:** `PrepareArguments` only if `flags.needs_arguments`; rest /
  destructuring can lower to element ops.

### 4.3 `CodeBlock`

```
CodeBlock
  ops, constants, exception_table
  source_map?                  // op → AST/span (optional in v1)
  local_count, register_count, param_count, capture_count
  flags: arrow | generator | async | needs_arguments | lexical_this | has_try | …
  name: ?[]const u8
  // optional back-pointer to FunctionNode for deopt/tools
```

Immutable after compile (IC side tables may be mutable later). Prefer
GC-tracked lifetime for functions that outlive the parse arena.

| z-regex `CompileResult` | `CodeBlock` |
|-------------------------|-------------|
| `bytecode` | `ops` |
| `charsets` | constants + exception table (+ later ICs) |
| `group_count` | `local_count` / `capture_count` |
| `mode` | `flags` |

### 4.4 Constant pool

Literals (number/string/bigint), property-key strings, nested `CodeBlock`
refs for `MakeClosure`, optional RegExp templates. Same Rc rules as today;
intern keys where profitable; never store mutable binding cells in the pool.

### 4.5 Closures

```
Closure { code: *CodeBlock, captures: []CaptureCell|JSValue, /* Callable meta */ }
```

- Immutable captures: copy `JSValue` at `MakeClosure`.
- Mutable captures: shared **cell** so assignments stay visible.
- Emit: fill capture vector from current frame → wrap `Callable` with
  `vmClosureCall` instead of AST `closureCall`.

### 4.6 Compiling a `FunctionNode`

```
FunctionNode → ScopeAnalyzer (slots, TDZ, captures, needs_arguments)
            → BytecodeEmitter (body + exception table)
            → CodeBlock
```

Prologue: args → locals, defaults, rest array, `var`→`undefined`,
`let`/`const` in TDZ until init. Inner functions compile first; outer emits
`MakeClosure`. Destination-driven expression emission (no separate stack IR).

Mental lowering of `fib` (locals `n=@0`): compare `@0` to const 0/1 and
`Return`; else `Call fib(@0-1)`, `Call fib(@0-2)`, `AddNum`, `Return`. Prefer
keeping `fib` in a local/module slot over repeated `LoadGlobal`.

### 4.7 Exceptions

```
Handler { start_pc, end_pc, target_pc, kind: catch|finally|catch_finally, catch_local? }
```

`Throw r` → `pending_exception` → find covering handler → catch stores into
`catch_local` or finally runs with an exit-reason → else pop frame → else
uncaught as today. `return`/`break`/`continue` through `finally`: v1 may
duplicate finally bodies; prefer an exit-reason register if nesting is heavy
(mirrors `Outcome`). Natives keep `throwError` → `JsThrow` on the same field.

### 4.8 Fibers

Keep: engine owns promises/microtasks; host owns I/O; fibers suspend.

| Today | With VM |
|-------|---------|
| Fiber runs tree-walker | Fiber runs `vmExecute` |
| `yield` switches out of native eval | `Yield` saves `{code,pc,regs,…}` into `FiberState` |
| `awaitValue` parks on a promise | Same; resume restores VM frame |
| `resumeFiber` re-enters evaluator | `resumeFiber` → `vmResume(fs)` |

Generators' `next` natives call `vmResume`. Async still returns a Promise and
settles on VM `Return` / uncaught `Throw`.

### 4.9 VM call frame and entry

```
VmFrame { code, pc, regs[register_count], captures, this, caller? }
```

Push frame → copy args/defaults → optional `arguments` if flagged → dispatch
→ `Return` writes caller's `dst` and pops. Prefer a **JS-frame** depth budget
mapping to the existing RangeError (more faithful once native frames shrink).

```
if (fnode.code_block) |cb| return vmCall(cb, captures, this, args);
else return invokeFunctionNode(...); // AST fallback
```

Top-level may stay AST initially (§5.4).

---

## 5. Compatibility and transition

### 5.1 What the AST keeps forever

The AST (and the existing parsers) remain the source of truth for:

- Parsing and early errors
- `eval` / `new Function` (parse → AST → then compile or interpret)
- Devtools, error spans, pretty-printing, experimental syntax
- Any feature not yet lowered by the emitter (fallback)

### 5.2 What the VM replaces

**Normal execution** of compiled functions and, eventually, module/script
top-level evaluation.

Semantic invariants that must not change:

- Always-strict engine behavior
- Ownership / Rc contracts at the JSValue boundary
- Jobs API (`hasPendingJobs` / `runPendingJob`)
- Module loader host split
- `pending_exception` throw model
- Fiber-based generators/async observable behavior

### 5.3 Coexistence strategy

Phased flags (design-level; names illustrative):

1. **Shadow mode** — compile `CodeBlock` but still execute AST; compare
   results in debug builds for a corpus of functions.
2. **Opt-in VM** — execute VM for functions marked simple (no try, no
   gen/async, no destructuring) behind a compile-time or env flag.
3. **Default VM for eligible functions** — AST fallback only for unsupported
   shapes.
4. **VM-first** — AST execution remains only for tools / unimplemented
   lowerings.

During transition, **one semantics library** (`coercion.zig`, property
dispatch, natives) must serve both paths. Do not fork ToNumber.

`eval` / `new Function`: parse to AST, then either compile immediately or
interpret with the tree-walker until the emitter covers the required
surface.

### 5.4 Module and script entry

`run` / `runModule` today parse then `evalBody`. Transition options:

- **A.** Compile the top-level program to a `CodeBlock` and `vmCall` it.
- **B.** Keep top-level as AST statements, but compile each function
  declaration's body ahead of time.

Recommend **B** first (smaller blast radius), then **A**.

---

## 6. Risks

### 6.1 What breaks if done wrong

| Failure mode | Symptom |
|--------------|---------|
| Wrong slot assignment | TDZ bugs, `const` assignment misses, closure sees stale values |
| Capture cells vs copies confused | Closures miss mutations (classic incorrect-let-in-loop) |
| `arguments` elision too aggressive | Test262 / user code relying on `arguments` breaks |
| Exception table gaps | `finally` skipped; completion value leaks; wrong rethrow |
| Fiber frame not fully saved | Generators resume with corrupt regs; async hangs |
| Dual semantics drift | AST path and VM path disagree on coercion edge cases |
| Identity of functions | `f === g` / `.prototype` / bound functions mishandled if Callable wrapping changes |
| Stack overflow behavior change | Infinite recursion no longer throws the same RangeError |
| Ownership bugs | Rc under/overflow — historically crash-prone in this codebase |

### 6.2 Test262 expectations (no sweep in this task)

This document does not run sweeps. When implementation starts, the
**existing local suite** and targeted language tests must stay green before
any broad conformance run. Categories that especially guard this design:

- `language/arguments-object`
- `language/eval-code`
- `language/expressions/call`, `operators`
- `language/statements/try`, `for`, `switch`
- `language/statements/generators`, `async-*`, `for-await`
- `language/module-code` (loader still host-driven)
- Built-ins that depend on call/construct protocol (`Function`, `Reflect.apply`)

Harness limitations documented in z-run `AGENTS.md` still apply (module
entry, always-strict, negative-test looseness). Do not treat historical PASS
rates as certification.

### 6.3 Verifying AST-walker ↔ VM equivalence

Recommended harness (design):

1. **Function corpus** — extract bodies from unit tests + a frozen list of
   `fib`-like microbenches + selected Test262 fixtures runnable under the
   current harness.
2. **Shadow execution** (debug) — for each call, run VM and AST (or compare
   against a recorded AST trace) on equal inputs; compare result values with
   SameValue, and compare thrown exception names/messages where stable.
3. **Differential fuzz** — random expressions in a restricted grammar
   (numbers, locals, calls, if/return) comparing both engines.
4. **Opcode golden tests** — like z-regex bytecode snapshots: hash
   `CodeBlock.ops` for fixed fixtures to catch emitter drift.
5. **Fiber resume tests** — generators/async with multiple `next`/`await`
   steps; ensure PC/regs restore.

Gate: no production default to VM until shadow mode is silent on the local
suite for eligible functions.

---

## 7. Phased roadmap (Grok analysis reference)

From the Grok performance analysis (2026-10-15). Expectations, not promises;
re-measure with the same `fib_bench` recipe after each phase.

| Phase | Mechanism | `fib(30)×5` (order of mag.) | vs bun (~44 ms) |
|-------|-----------|-----------------------------|-----------------|
| Today | AST walk | ~42 s | ~1000× |
| 0 | Measure (perf, alloc counters); confirm §1.4 ranking | — | — |
| 1 | Lazy `arguments`, slot envs, num fast paths, thinner frames | ~1–8 s | ~20–200× |
| 2 | **Bytecode VM** (`CodeBlock`, emitter, `vmCall`, AST fallback) | ~0.2–2 s | ~5–50× |
| 3 | Call/property ICs + type feedback | ~0.1–0.5 s | ~2–10× |
| 4 | Baseline JIT (template/copy-and-patch, deopt to bytecode) | ~50–200 ms | ~1–5× |
| 5 | Optimizing JIT (SSA/inlining; horizon) | bun zone | competitive |

Practical path toward bun: **Phase 2, then 3–4**. Phase 1 alone is not
enough. JIT without bytecode is rejected — `CodeBlock` is the durable IR.

---

## 8. Principles, build order, open questions

**Principles:** keep engine/host + jobs API; one shared semantics library for
AST and VM; compile after the existing AST; treat `fib` as a microbench not
conformance; no commit/push without authorization; ground truth with unit
tests / reference engine under known harness limits.

**Build order (when coding is authorized):** (1) scope analyzer only,
(2) `CodeBlock` + disassembler/snapshots, (3) emitter for literals/locals/
number ops/if/return/calls, (4) VM + `fib`-shaped wiring, (5) lazy
`arguments` + capture cells, (6) exception tables, (7) fiber save/restore,
(8) widen eligibility + shadow equivalence, then default-on.

**Open questions:** GC vs arena for `CodeBlock`; finally exit-reason vs
duplication; top-level compile timing (§5.4 B then A); IC storage; shadow
mode always-on vs flag; do **not** share opcode/writer code with z-regex.

---

## 9. References

### In-repo / local sources

- z-interpreter expression eval: `src/interpreter_expr.zig` (`evalExpression`,
  `evalCall`)
- Function invocation: `src/interpreter_class.zig` (`invokeFunctionNode`,
  `closureCall`)
- Environments: `src/environment.zig`
- Completions / try merge: `src/completion.zig`, `src/interpreter_stmt.zig`
- Fibers: `src/interpreter_runtime.zig` (`resumeFiber`, `awaitValue`,
  `makeGeneratorObject`, …)
- Module entry: `src/interpreter_module.zig` (`runModule`, `loadModule`)
- z-run CLI entry: `/home/sweb/z-run/src/main.zig` (`runModule` path)
- Project execution notes: `/home/sweb/z-run/AGENTS.md`

### z-regex reference (package cache)

- Compile API: `zregex-0.9.1-…/src/compile.zig`
- Opcodes: `…/src/tier2/bytecode/opcodes.zig`
- Program object: `…/src/tier2/program.zig` (`CompileResult`)
- Codegen: `…/src/tier2/codegen/generator.zig`
- VM loop: `…/src/tier2/executor/backtrack.zig` (`run` / `exec1`)

### Prior analysis

- Grok session analysis (2026-10-15): parser → AST → interpreter bottleneck
  ranking; Bun/JSC comparison; Phases 0–5 and expectation table reproduced
  in §7.

---

## 10. Document history

| Date | Change |
|------|--------|
| 2026-10-15 | Initial design-only draft (`bytecode-vm.md`). No implementation. |

---

*End of design document.*
