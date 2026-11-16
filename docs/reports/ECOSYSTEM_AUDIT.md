# Ecosystem Audit — submódulos z-*

Última actualización: 2026-11-16
Sweep de referencia: `/tmp/sweep-9764c11.jsonl` (`z-interpreter` `9764c11`, `v0.3.11`)

## Resumen ejecutivo

Estado de auditoría de submódulos `z-*` que están en la cascada del motor. Objetivo: identificar oportunidades de expansión independientes (solo submódulo) vs acopladas al motor (requieren tocar `z-interpreter`) vs sin impacto Test262.

## Módulos auditados

### z-date (v0.1.0, bd26f9b)

- Cobertura ES2024 Date: ~95%. Implementa constructor, getters/setters locales y UTC, `toISOString`/`toJSON`/`toUTCString`, parsing ISO 8601 + legacy (validado contra V8 con 150+ casos), 145 locales embebidos sin ICU/CLDR.
- Tests propios: 310 en 18 archivos.
- Consumidores: `z-interpreter`, `z-value`, `z-temporal` (`Timezone`). Cascada doble.
- FAIL Test262 atribuibles: 1 de 25 (`Date/UTC/fp-evaluation-order.js` — `ZDate.UTC` pierde precisión `f64` de `MakeTime`).
- Los otros 24 FAIL de Date son del adapter (`date_builtins.zig`, `interpreter_props.zig`) y harness (`$262`).
- Veredicto: NO expandir. 1 test recuperable con cascada doble no compensa.

### z-math (v0.1.0, 8821a3b)

- Cobertura ES2026 Math: 100% (37/37 funciones + 8/8 constantes). Cubre `NaN`, `-0`, `Infinity`, `round(-0.5) === -0`, `pow(1, Infinity) === NaN`.
- Tests propios: 16.
- Consumidores: solo `z-interpreter`. Cascada simple.
- FAIL Test262 atribuibles: 0 de 0 (`Math` 327/327 PASS, 100%).
- Veredicto: NO expandir. Ya completo.

## Módulos pendientes de auditoría

*(Pendiente de completar en inventario.)*

## Hallazgo colateral

- `date_builtins.zig` define `INVALID_DATE_MS = 9223372036854776000` en lugar de `NaN`. Rompe `year-zero.js` y probablemente tests de rango inválido. Fix local en 1 línea del adapter. Deuda técnica independiente de submódulos.
