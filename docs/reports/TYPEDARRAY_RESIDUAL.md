# TypedArray Residual

- **Date:** 2026-11-14
- **Sweep SHA (Etapa 1+2):** `fd7c00c` / `bf45b00` (`v0.3.5`)
- **Baseline SHA:** `fe647ca` (`v0.3.4`)
- **Grupos 3+4 Commits:** `daeb6d0` (Grupo 3) + `04dcd09` (Grupo 4)

## Grupo 3 — Integer-Indexed Exotic Object 10.4.5 — RESUELTO (`daeb6d0`)

- **Status:** **RESUELTO** en commit `daeb6d0`.
- **Summary:** Implementación completa de los métodos internos de Integer-Indexed Exotic Object (ECMA-262 10.4.5): `canonicalNumericIndex`, `[[Get]]`, `[[Set]]` (propiedades indexadas + bag `extraProps` para propiedades nombradas y símbolos + cadena de prototipos), `[[HasProperty]]` (`in`), `[[GetOwnProperty]]`, `[[DefineOwnProperty]]`, `[[Delete]]` (`Reflect.deleteProperty` devuelve `false` en índices válidos; `delete ta[i]` lanza `TypeError`), `[[OwnPropertyKeys]]`, `[[IsExtensible]]` / niveles de integridad (`preventExtensions`/`seal`/`freeze`), y `[[SetPrototypeOf]]` / `__proto__`.

## Grupo 4 — Subclassing / `new.target` / `TypedArraySpeciesCreate` — RESUELTO (`04dcd09`)

- **Status:** **RESUELTO** en commit `04dcd09`.
- **Paths (22 deudas previas):**
  - `test/language/expressions/class/subclass-builtins/subclass-{BigInt64,BigUint64,Float32,Float64,Int16,Int32,Int8,Uint16,Uint32,Uint8,Uint8Clamped}Array.js` (11 constructors)
  - `test/language/statements/class/subclass-builtins/subclass-{BigInt64,BigUint64,Float32,Float64,Int16,Int32,Int8,Uint16,Uint32,Uint8,Uint8Clamped}Array.js` (11 constructors)
- **Summary:** Implementación de `TypedArraySpeciesCreate` y `SpeciesConstructor` en `map`, `filter`, `slice` y `subarray` (más `ArrayBuffer.prototype.slice` / `SharedArrayBuffer.prototype.slice`), propagación de `GetPrototypeFromConstructor(newTarget, defaultProto)` en `typedArrayConstructor` (`constructedTypedArray`), y adopción de instancia exótica (`.typed_array`, `.array_buffer`, `.data_view`) en constructores derivados implícitos y explícitos (`super()`).

## Grupo 5 — Detached buffer + `fromIndex` — PENDIENTE (4 deudas + tests `$262.detachArrayBuffer`)

- **Paths (4 deudas de Etapa 1+2):**
  - `test/built-ins/TypedArray/prototype/indexOf/detached-buffer-during-fromIndex-returns-minus-one-for-undefined.js`
  - `test/built-ins/TypedArray/prototype/indexOf/BigInt/detached-buffer-during-fromIndex-returns-minus-one-for-undefined.js`
  - `test/built-ins/TypedArray/prototype/lastIndexOf/detached-buffer-during-fromIndex-returns-minus-one-for-undefined.js`
  - `test/built-ins/TypedArray/prototype/lastIndexOf/BigInt/detached-buffer-during-fromIndex-returns-minus-one-for-undefined.js`
- **Cause:** Pasaban antes por accidente porque `indexOf` y `lastIndexOf` ignoraban el argumento `fromIndex` y nunca invocaban `fromIndex.valueOf()` (que llama a `$DETACHBUFFER(sample.buffer)`). Etapa 2 implementó `ToIntegerOrInfinity(fromIndex)` según spec, exponiendo la ausencia de `$262.detachArrayBuffer` y `IsDetachedBuffer`.
- **Requires:** Grupo 5 del roadmap de TypedArray (`ArrayBuffer` detachment + `IsDetachedBuffer` / `ValidateTypedArray` + `$262.detachArrayBuffer`).

## Grupo 6 — Resizable ArrayBuffer (RAB) / Growable SharedArrayBuffer (GSAB) — PENDIENTE

- **Summary:** Soporte para `new ArrayBuffer(len, { maxByteLength })`, `ArrayBuffer.prototype.resize`, `SharedArrayBuffer.prototype.grow`, y vistas `TypedArray` auto-ajustables o out-of-bounds por encogimiento del buffer subyacente. Diferido fuera del contrato de longitud fija previo al JIT.
