# String Cluster Residual Test Report

## Test residual estructural

- **Path:** `test/built-ins/String/prototype/indexOf/searchstring-tostring-errors.js`
- **Causa raíz:** `Object(Symbol)` no es desempaquetado a Symbol en `toDisplayStringJS` antes de invocar `toString()`, lo cual produce `"Symbol(1)"` en lugar de lanzar `TypeError`.
- **Área afectada:** Requiere modificar `coercion.zig` / `interpreter_support.zig` (fuera del alcance del batch de batallas pequeñas de String).
- **Conteo:** 1 test residual (los otros 24 de `indexOf`/`lastIndexOf` pasaron al 100%).
