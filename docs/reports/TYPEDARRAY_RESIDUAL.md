# TypedArray Residual (Etapa 1 + Etapa 2)

- **Date:** 2026-11-14
- **Sweep SHA:** `fd7c00c` (`feat/typedarray-hierarchy-methods`)
- **Baseline SHA:** `fe647ca` (`v0.3.4`)
- **Sweep Summary:** 35,548 PASS (vs 35,010 baseline), +564 FAIL→PASS, 26 PASS→FAIL (0 CRASH, Temporal 4,587/24). Net gain: **+538 PASS** (+564 FAIL→PASS; the largest single-batch gain in the project).

## Grupo 4 — Subclassing / `new.target` (22 tests)

- **Paths:**
  - `test/language/expressions/class/subclass-builtins/subclass-{BigInt64,BigUint64,Float32,Float64,Int16,Int32,Int8,Uint16,Uint32,Uint8,Uint8Clamped}Array.js` (11 constructors)
  - `test/language/statements/class/subclass-builtins/subclass-{BigInt64,BigUint64,Float32,Float64,Int16,Int32,Int8,Uint16,Uint32,Uint8,Uint8Clamped}Array.js` (11 constructors)
- **Cause:** Passed previously by accident (without intrinsic `%TypedArray%` and with on-demand `XArray.prototype` creation). Now `%TypedArray%` and fixed `XArray.prototype` descriptors exist, exposing that `typedArrayConstructor` does not yet perform `GetPrototypeFromConstructor(newTarget, "%TypedArray.prototype%")` to propagate `new.target.prototype` onto the constructed instance.
- **Requires:** Grupo 4 of the TypedArray roadmap (`new.target` / `GetPrototypeFromConstructor` / `TypedArraySpeciesCreate`).
- **Impact:** 22 tests. No functional regression; the prior pass was a false positive from incomplete prototype wiring.

## Grupo 5 — Detached buffer + `fromIndex` (4 tests)

- **Paths:**
  - `test/built-ins/TypedArray/prototype/indexOf/detached-buffer-during-fromIndex-returns-minus-one-for-undefined.js`
  - `test/built-ins/TypedArray/prototype/indexOf/BigInt/detached-buffer-during-fromIndex-returns-minus-one-for-undefined.js`
  - `test/built-ins/TypedArray/prototype/lastIndexOf/detached-buffer-during-fromIndex-returns-minus-one-for-undefined.js`
  - `test/built-ins/TypedArray/prototype/lastIndexOf/BigInt/detached-buffer-during-fromIndex-returns-minus-one-for-undefined.js`
- **Cause:** Passed previously by accident because `indexOf` and `lastIndexOf` ignored the `fromIndex` argument and never invoked `fromIndex.valueOf()` (which calls `$DETACHBUFFER(sample.buffer)`). Etapa 2 implements `ToIntegerOrInfinity(fromIndex)` per spec, executing `valueOf()` and exposing the unimplemented `$262.detachArrayBuffer` harness hook and `IsDetachedBuffer` validation.
- **Requires:** Grupo 5 of the TypedArray roadmap (`ArrayBuffer` detachment + `IsDetachedBuffer` / `ValidateTypedArray`).
- **Impact:** 4 tests. No functional regression.
