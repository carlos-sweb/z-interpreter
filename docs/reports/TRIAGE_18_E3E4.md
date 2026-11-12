# Triage: 18 Known Gaps in E3/E4 Conformance

- **Fecha:** 2026-11-12
- **Sweep Commit:** `05de8dc` (`feat/e3-e4-conformance`)
- **Baseline de Comparación:** Test262 run 2026-10-14 (`runs/2026-10-14-zig017`)
- **Total Test262:** 34,723 PASS (+1,165 vs baseline 33,558), 0 crashes, 9 timeouts, 4,587/24 Temporal PASS.

## Resumen Ejecutivo

Los 18 tests listados abajo aparecen como `PASS -> FAIL` al comparar contra el baseline de octubre de 2026.
**No son regresiones introducidas por las correcciones de E3/E4 ni por esta rama**, sino gaps preexistentes en la implementación base (`6b50a51`) que en el baseline de octubre pasaban como **falsos positivos**: el motor previo lanzaba ciegamente `TypeError: called on non-object` para descriptores en tipos no estándar, lo que satisfacía fortuitamente `assert.throws(TypeError)`. Al implementarse `extraPropsObject` y descriptores reales en E3, las operaciones ya no lanzan ese error genérico y ahora revelan la falta de la lógica de especificación correspondiente.

---

## Clusters y Causas Raíz

### 1. TypedArray `DefineOwnProperty` (8 tests) — **Prioridad Alta**
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/key-is-numericindex-accessor-desc-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/key-is-numericindex-desc-not-configurable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/key-is-numericindex-desc-not-enumerable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/key-is-numericindex-desc-not-writable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/BigInt/key-is-numericindex-accessor-desc-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/BigInt/key-is-numericindex-desc-not-configurable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/BigInt/key-is-numericindex-desc-not-enumerable-throws.js`
- `test/built-ins/TypedArrayConstructors/internals/DefineOwnProperty/BigInt/key-is-numericindex-desc-not-writable-throws.js`
- **Causa raíz:** `src/property_desc.zig:357` (`defineOwnProperty`). Falta rama específica para `.typed_array`; actualmente cae en `else => validateAndApply(extraPropsObject)`, permitiendo definir propiedades no configurables/no escribibles en vez de aplicar las reglas de Integer-Indexed Exotic Objects (debe retornar false / lanzar TypeError).
- **Estimación de fix:** ~15–20 líneas en `property_desc.zig`. Resuelve los 8 tests de una vez.

### 2. `Object.getOwnPropertySymbols` Proxy Invariants (4 tests) — **Prioridad Media-Alta**
- `test/built-ins/Object/getOwnPropertySymbols/proxy-invariant-absent-not-configurable-string-key.js`
- `test/built-ins/Object/getOwnPropertySymbols/proxy-invariant-duplicate-string-entry.js`
- `test/built-ins/Object/getOwnPropertySymbols/proxy-invariant-not-extensible-absent-string-key.js`
- `test/built-ins/Object/getOwnPropertySymbols/proxy-invariant-not-extensible-extra-string-key.js`
- **Causa raíz:** `src/object_builtins.zig:835-841` (`objectGetOwnPropertySymbols`). A diferencia de `objectGetOwnPropertyNames:800`, `getOwnPropertySymbols` carece de rama `.proxy =>`. En vez de invocar la trampa `ownKeys` y validar las invariantes del target (e.g. que no falten propiedades no configurables), cae en `else => extraProps` y devuelve `[]` sin validación.
- **Estimación de fix:** ~15–25 líneas en `object_builtins.zig` (análogo al bloque de `objectGetOwnPropertyNames`).

### 3. `Object.defineProperty` Desync de Bag en Arrays/Arguments (2 tests) — **Prioridad Media**
- `test/built-ins/Object/defineProperty/15.2.3.6-4-333-10.js`
- `test/built-ins/Object/defineProperty/15.2.3.6-4-333-4.js`
- **Causa raíz:** `src/interpreter_props.zig:334` (`setArrayProperty`). Cuando `Object.defineProperty` define una propiedad `writable: true, configurable: false`, se registra en el `bag` de descriptores. Las asignaciones subsiguientes (`arr[0] = 1001`) actualizan el elemento en `arr.set(0, 1001)`, pero no actualizan `rec.value` en el `bag`. `getProperty` prioriza `bag` y devuelve el valor viejo.
- **Estimación de fix:** ~6–10 líneas en `setArrayProperty`.

### 4. `Object.assign` con Target Primitivo String (1 test) — **Prioridad Baja**
- `test/built-ins/Object/assign/assignment-to-readonly-property-of-target-must-throw-a-typeerror-exception.js`
- **Causa raíz:** `src/object_builtins.zig:222` (`objectAssign`). `toObject('a')` crea un objeto envoltorio ordinario, pero no define las propiedades indexadas de caracteres como propiedades propias `writable: false`. Al asignar `[1]`, sobrescribe `"0"` sin lanzar `TypeError`.
- **Estimación de fix:** ~10 líneas en `boxWrapper` / `objectAssign`.

### 5. `Proxy.setPrototypeOf` Trap Missing (1 test) — **Prioridad Baja**
- `test/built-ins/Proxy/setPrototypeOf/trap-is-missing-target-is-proxy.js`
- **Causa raíz:** `src/object_builtins.zig:957` (`objectSetPrototypeOf`). No implementa la trampa `setPrototypeOf` para receptores `Proxy`; delega ciegamente a `setOwnedPrototype` sin invocar trampas.
- **Estimación de fix:** ~12–15 líneas en `object_builtins.zig`.

### 6. `Promise` Constructor Evaluación Eager de `newTarget.prototype` (1 test) — **Prioridad Baja**
- `test/built-ins/Promise/get-prototype-abrupt-executor-not-callable.js`
- **Causa raíz:** `src/interpreter_expr.zig:1090` (`constructValueWithNewTarget`). Se lee impacientemente `new_target.prototype` antes de llamar al constructor `Promise`, el cual debería verificar primero que `executor` sea invocable (`IsCallable(executor)`) antes de disparar `GetPrototypeFromConstructor`.
- **Estimación de fix:** ~8–12 líneas en `constructValueWithNewTarget`.

### 7. `TypedArrayConstructors` Pre-Prototype Argument Validation (1 test) — **Prioridad Baja**
- `test/built-ins/TypedArrayConstructors/ctors/typedarray-arg/throw-type-error-before-custom-proto-access.js`
- **Causa raíz:** Mismo patrón de evaluación impaciente en `constructValueWithNewTarget`: el prototipo de `newTarget` se consulta antes de validar que los argumentos del constructor de TypedArray sean válidos.
- **Estimación de fix:** Compartido con el fix del cluster 6 (~5 líneas).

---

## Recomendación de Secuencia de Trabajo
1. Resolver Cluster 1 (TypedArray DefineOwnProperty): 8 tests con bajo esfuerzo (~20 líneas).
2. Resolver Cluster 2 (Object.getOwnPropertySymbols Proxy): 4 tests replicando el patrón de `objectGetOwnPropertyNames` (~20 líneas).
3. Resolver Cluster 3 (Object.defineProperty desync en array bag): 2 tests actualizando `rec.value` en `setArrayProperty` (~8 líneas).
4. Abordar Clusters 4–7 en un pase de limpieza de conformancia de constructores y proxies.
