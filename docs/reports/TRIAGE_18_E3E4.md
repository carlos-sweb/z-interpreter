# Triage: 18 Known Gaps in E3/E4 Conformance — [RESOLVED]

- **Fecha:** 2026-11-12
- **Initial Sweep Commit:** `05de8dc` (`feat/e3-e4-conformance`)
- **Resolution Branch:** `feat/e3e4-remaining-gaps`
- **Baseline de Comparación:** Test262 run 2026-10-14 (`runs/2026-10-14-zig017`)
- **Total Test262:** 34,741 PASS (+1,183 vs baseline 33,558), 0 crashes, 9 timeouts, 4,587/24 Temporal PASS.
- **Estado de los 18 gaps:** 18/18 RESUELTOS Y VERIFICADOS (PASS).

## Resumen Ejecutivo

Los 18 tests listados abajo aparecían inicialmente como `PASS -> FAIL` al comparar contra el baseline de octubre de 2026.
No eran regresiones de las optimizaciones, sino gaps preexistentes en la implementación base (`6b50a51`) que en el baseline de octubre pasaban como falsos positivos.

Todos los 18 tests han sido corregidos, verificados individualmente y validados contra el suite de pruebas unitarias local (826/826 tests pass). Los microbenchmarks (`obj`, `fib`, `diag4`, `closure`) mantienen paridad completa con E1.

---

## Clusters, Fixes y Commits de Resolución

### 1. TypedArray `DefineOwnProperty` (8 tests) — **RESUELTO**
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/key-is-numericindex-accessor-desc-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/key-is-numericindex-desc-not-configurable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/key-is-numericindex-desc-not-enumerable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/key-is-numericindex-desc-not-writable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/BigInt/key-is-numericindex-accessor-desc-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/BigInt/key-is-numericindex-desc-not-configurable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/BigInt/key-is-numericindex-desc-not-enumerable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/BigInt/key-is-numericindex-desc-not-writable-throws.js`
- **Causa raíz:** `src/property_desc.zig` no implementaba las reglas de Integer-Indexed Exotic Objects para TypedArray en `defineOwnProperty`.
- **Fix:** Implementado `typedArrayDefineOwnProperty` validando incompatibilidad de descriptores (accessors, non-configurable, non-enumerable, non-writable lanzan TypeError o retornan false) y actualizando elementos vía `typedElemSet`.
- **Commit:** `a307e14` (`fix(typedarray): implement IntegerIndexedExotic DefineOwnProperty rules`)
- **Estado:** 8/8 PASS.

### 2. `Object.getOwnPropertySymbols` Proxy Invariants (4 tests) — **RESUELTO**
- `test/built-ins/Object/getOwnPropertySymbols/proxy-invariant-absent-not-configurable-string-key.js`
- `test/built-ins/Object/getOwnPropertySymbols/proxy-invariant-duplicate-string-entry.js`
- `test/built-ins/Object/getOwnPropertySymbols/proxy-invariant-not-extensible-absent-string-key.js`
- `test/built-ins/Object/getOwnPropertySymbols/proxy-invariant-not-extensible-extra-string-key.js`
- **Causa raíz:** `objectGetOwnPropertySymbols` no contaba con rama `.proxy =>` y no validaba invariantes de la trampa `ownKeys` respecto al target.
- **Fix:** Creada función compartida `proxyOwnPropertyKeys` que valida entradas duplicadas, claves no configurables presentes en el target y extensibilidad del target en `objectGetOwnPropertyNames`, `objectGetOwnPropertySymbols`, `ownPropertyKeyList` y `reflectOwnKeys`.
- **Commit:** `5282ebc` (`fix(proxy): validate ownKeys invariants in getOwnPropertySymbols/Names`)
- **Estado:** 4/4 PASS.

### 3. `Object.defineProperty` Desync de Bag en Arrays/Arguments (2 tests) — **RESUELTO**
- `test/built-ins/Object/defineProperty/15.2.3.6-4-333-10.js`
- `test/built-ins/Object/defineProperty/15.2.3.6-4-333-4.js`
- **Causa raíz:** `setArrayProperty` en `src/interpreter_props.zig` modificaba el array backing storage pero no actualizaba `rec.value` en el property bag de descriptores.
- **Fix:** Sincronizado `rec.value` en el bag cuando existe registro con descriptor modificable.
- **Commit:** `1ec7eab` (`fix(array): sync property bag on array element write`)
- **Estado:** 2/2 PASS.

### 4. `Object.assign` con Target Primitivo String (1 test) — **RESUELTO**
- `test/built-ins/Object/assign/assignment-to-readonly-property-of-target-must-throw-a-typeerror-exception.js`
- **Causa raíz:** `boxWrapper` y `boxPrimitiveIfConstructed` no inicializaban propiedades indexadas en el wrapper del string con `writable: false`.
- **Fix:** Implementada `initStringWrapperProperties` definiendo índices como no-escribibles, no-configurables y enumerables, y `length` como no-escribible y no-enumerable.
- **Commit:** `d5ef6f6` (`fix(object): initialize indexed properties with writable:false on string wrapper objects`)
- **Estado:** 1/1 PASS.

### 5. `Proxy.setPrototypeOf` Trap Missing (1 test) — **RESUELTO**
- `test/built-ins/Proxy/setPrototypeOf/trap-is-missing-target-is-proxy.js`
- **Causa raíz:** `objectSetPrototypeOf` no invocaba la trampa `setPrototypeOf` en receptores Proxy ni reenviaba a proxies anidados.
- **Fix:** Creada `setPrototypeOfInternal` que invoca la trampa `setPrototypeOf`, valida el resultado booleano e invariantes de extensibilidad del target, y reenvía recursivamente al target cuando falta la trampa.
- **Commit:** `459e85b` (`fix(proxy): forward setPrototypeOf to trap and target`)
- **Estado:** 1/1 PASS.

### 6. `Promise` Constructor Evaluación Eager de `newTarget.prototype` (1 test) — **RESUELTO**
- `test/built-ins/Promise/get-prototype-abrupt-executor-not-callable.js`
- **Causa raíz:** `constructValueWithNewTarget` leía `newTarget.prototype` antes de que el constructor de `Promise` validara que `executor` sea invocable (`IsCallable`).
- **Fix:** Pre-validación de `executor` en `constructValueWithNewTarget` previo a la lectura de `newTarget.prototype`.
- **Commit:** `d49b98d` (`fix(construct): validate Promise and TypedArray arguments before newTarget prototype read`)
- **Estado:** 1/1 PASS.

### 7. `TypedArrayConstructors` Pre-Prototype Argument Validation (1 test) — **RESUELTO**
- `test/built-ins/TypedArrayConstructors/ctors/typedarray-arg/throw-type-error-before-custom-proto-access.js`
- **Causa raíz:** `constructValueWithNewTarget` leía `newTarget.prototype` antes de la validación y coerción numérica (`ToIndex`) del primer argumento no-objeto de TypedArray.
- **Fix:** Pre-validación de coercibilidad numérica (rechaza Symbol/BigInt) en `constructValueWithNewTarget` previo a la lectura de `newTarget.prototype`.
- **Commit:** `d49b98d` (`fix(construct): validate Promise and TypedArray arguments before newTarget prototype read`)
- **Estado:** 1/1 PASS.

---

## Verificación de Rendimiento

Benchmarks medidos con ReleaseFast (`--engine=bytecode`), 5 iteraciones cada uno:
- `obj`: 1.75s (E1 baseline: 1.74s - 1.77s)
- `fib`: 1.02s (E1 baseline: 1.07s)
- `diag4`: 0.80s (E1 baseline: 0.78s - 0.82s)
- `closure`: 0.16s (E1 baseline: 0.15s - 0.16s)
Cero regresión de rendimiento.
