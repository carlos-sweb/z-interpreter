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

## Módulos auditados (turno 2)

### z-parser (v0.1.0, 57de367)

- Cobertura ES2024 §13 Expressions: completa salvo hooks delegados (`class`, `function`, `arrow`, `async`/`yield`) y `tagged-template` (`TRV` raw).
- Consumidores: `z-statements`, `z-functions`, `z-interpreter` (cascada triple).
- FAIL `language/expressions` (2,590): `799` `SyntaxError` (600 `dynamic-import` módulos, `class` fields/decorators en `z-functions`, 25 `tagged-template`), `529` `async`, `7` `$262`, `1,255` motor/semántica (`class` 571, `object` 162, `generators` 74, `assignment` 60).
- Veredicto: NO expandir en paralelo. El grueso es estructural/motor (`class`, módulos, `async`); fix independiente no compensa.

### z-statements (v0.2.0, 3452296)

- Cobertura ES2024 §14 Statements/Declarations: completa salvo `using`/`await using` (Explicit Resource Management), `for-await-of`, y hooks delegados (`class`/`function` en `z-functions`).
- Consumidores: `z-functions`, `z-interpreter` (cascada doble).
- FAIL `language/statements` (1,831): `294` `SyntaxError` (`await-using` 65, `using` 45, `for-await-of` 46, `class` fields), `417` `async`, `1,120` motor/semántica (`class` 652, `for-of` 116, `generators` 76, `function` 40).
- Veredicto: NO expandir. `using`/`for-await-of` son estructurales (requieren runtime `Symbol.dispose`/async iterators); el resto es motor.

### z-array (v0.2.1, 05466a7)

- Cobertura `Array`: almacenamiento denso/holey/sparse (`ZArray(T)`) + métodos base y ES2023 (`toReversed`/`toSorted`/`toSpliced`/`with`).
- Consumidores: `z-value`, `z-interpreter` (cascada doble).
- FAIL `built-ins/Array` (933): `93` `fromAsync` (estructural `async`), ~`840` adapter/estructural (`array_builtins.zig`: coerción array-like de `this` en `filter`/`reduce`/`reduceRight`/`splice`/`sort`/`concat`/`map`/`forEach`/`indexOf`, `ToLength`, `Symbol.species`, `own-props` sobre Date/Error).
- Veredicto: NO expandir `z-array`. El trabajo real está en el adapter `array_builtins.zig`.

### z-buffer (v0.1.0, e56f43b)

- Cobertura: `ArrayBuffer` fijo, `DataView` y `TypedArrayView(T)` (10 tipos). Deliberadamente excluye `resize`/`transfer`/`SharedArrayBuffer`.
- Consumidores: `z-value`, `z-json`, `z-interpreter` (cascada triple).
- FAIL clusters buffer (767 total: `TypedArray` 348 + `TypedArrayConstructors` 103 + `DataView` 155 + `ArrayBuffer` 130 + `SharedArrayBuffer` 31): `451` `TypedArray*` (motor `typedarray_builtins.zig`/estructural detached/RAB/species), `155` `DataView` (motor/RAB/Float16), `130` `ArrayBuffer` (96 son `transfer`/`resize`/`immutable` estructurales), `31` `SharedArrayBuffer`.
- Veredicto: NO expandir `z-buffer` como batalla independiente. `resize`/`transfer` son estructurales (observación cruzada en vistas + `z-value`).

## Módulos pendientes de auditoría

- **Cascada directa (11 pendientes):** `z-bigint`, `z-functions`, `z-map`, `z-number`, `z-object`, `z-regex`, `z-string`, `z-symbol`, `z-temporal`, `z-urlcode`, `z-value`. *(Nota: `z-set`, `z-error` y `z-json` fueron clasificados en auditoría separada como 0 FAIL de submódulo / todo adapter).*
- **Cascada transitiva (3 pendientes):** `z-equality` (`z-array`, `z-map`), `z-lexer` (`z-parser`), `z-promise` (`z-value`).

## Inventario completo (37 repos)

Categorías: **A** = cascada directa (`z-interpreter/build.zig.zon`), **B** = cascada transitiva, **C** = local fuera de cascada del motor, **D** = GitHub fuera de cascada (sin clonar).

| Repo | Cat | Master SHA | Último tag | Líneas núcleo (`src/*.zig`) | Tests propios | Cluster Test262 | FAIL actuales |
| :--- | :---: | :--- | :--- | ---: | ---: | :--- | ---: |
| `z-array` | A | `05466a7` | `v0.2.1` | 732 | 112 | `Array` | 933 |
| `z-bigint` | A | `3b6c9ff` | `v0.1.1` | 725 | 36 | `BigInt` | 7 |
| `z-buffer` | A | `e56f43b` | `v0.1.0` | 381 | 23 | `ArrayBuffer`+`TypedArray` | 478 |
| `z-date` | A | `bd26f9b` | `v0.1.0` | 4,613 | 310 | `Date` | 25 |
| `z-error` | A | `188058c` | `v0.1.0` | 164 | 8 | `Error`+`NativeErrors` | 86 |
| `z-functions` | A | `5fa2d8d` | `v0.2.0` | 803 | 47 | `Function` | 198 |
| `z-json` | A | `53be5fe` | `v0.1.2` | 750 | 24 | `JSON` | 83 |
| `z-map` | A | `8823f11` | `0.1.0` | 145 | 19 | `Map` | 51 |
| `z-math` | A | `8821a3b` | `v0.1.0` | 589 | 16 | `Math` | 0 |
| `z-number` | A | `9fb0c96` | `v0.1.0` | 1,683 | 235 | `Number` | 64 |
| `z-object` | A | `058dade` | `v0.2.0` | 1,143 | 131 | `Object` | 422 |
| `z-parser` | A | `57de367` | `v0.1.0` | 1,258 | 59 | `language/expressions` | 2,590 |
| `z-regex` | A | `2a48ab6` | `v0.9.1` | 5,514 | 737 | `RegExp` | 112 |
| `z-set` | A | `c61896e` | `0.1.0` | 103 | 9 | `Set` | 162 |
| `z-statements` | A | `3452296` | `v0.2.0` | 1,124 | 83 | `language/statements` | 1,831 |
| `z-string` | A | `b42a232` | `v0.4.1` | 96 | 417 | `String` | 33 |
| `z-symbol` | A | `f01df64` | `v0.1.0` | 323 | 15 | `Symbol` | 25 |
| `z-temporal` | A | `a3be106` | `v0.2.9` | 6,138 | 227 | `Temporal` | 24 |
| `z-urlcode` | A | `4a8a876` | `v0.1.0` | 197 | 19 | `encode/decodeURI*` | 10 |
| `z-value` | A | `9647a39` | `v0.1.2` | 1,351 | 148 | Transversal | — |
| `z-equality` | B | — | — | — | — | Transversal (`z-array`, `z-map`) | — |
| `z-lexer` | B | — | — | — | — | Léxico (`z-parser`) | — |
| `z-promise` | B | — | — | — | — | `Promise` (`z-value`) | — |
| `z-interpreter` | C | `9a34bf0` | `v0.3.11` | 26,712 | 826 | Motor completo | 9,616 |
| `z-run` | C | `ac22df8` | `v0.1.2` | 1,634 | 72 | CLI runtime | — |
| `z-test262` | C | `e13b563` | `none` | 0 | 0 | Harness Test262 | — |
| `z-args` | C | `ad8ff79` | `v0.1.0` | 1,177 | 51 | Tooling CLI | — |
| `z-print` | C | `90e650b` | `v0.1.0` | 6,331 | 437 | Tooling | — |
| `z-server` | C | `7b22270` | `v1.0.0` | 1,288 | 133 | Servidor HTTP | — |
| `z-toml` | C | `65040c7` | `v0.2.1` | 810 | 23 | Tooling (`z-run`) | — |
| `z-yaml` | C | `dee91b5` | `v0.2.1` | 837 | 38 | Tooling (`z-run`) | — |
| `z-crypto` | D | — | — | — | — | Tooling (`z-run`) | — |
| `z-lexbor` | D | — | — | — | — | HTML bindings | — |
| `z-libqr` | D | — | — | — | — | QR codes | — |
| `z-numeral` | D | — | — | — | — | Formateo numérico | — |
| `z-uuid` | D | — | — | — | — | UUID (`z-run`) | — |
| `z-voca` | D | — | — | — | — | Strings helper | — |

## Mapa de correlación Test262 → módulo

| Cluster Test262 | Módulo | FAIL | PASS | % pass | Estado de auditoría |
| :--- | :--- | ---: | ---: | ---: | :--- |
| `language/expressions` | `z-parser` | 2,590 | 7,922 | 75.3% | **Auditado (NO expandir)** |
| `language/statements` | `z-statements` | 1,831 | 7,034 | 79.3% | **Auditado (NO expandir)** |
| `Array` | `z-array` | 933 | 2,111 | 69.3% | **Auditado (NO expandir)** |
| `ArrayBuffer`+`TypedArray` | `z-buffer` | 478 | 1,181 | 71.2% | **Auditado (NO expandir)** |
| `Object` | `z-object` | 422 | 2,978 | 87.6% | Pendiente |
| `Function` | `z-functions` | 198 | 223 | 53.0% | Pendiente |
| `Set` | `z-set` | 162 | 220 | 57.6% | Pendiente |
| `RegExp` | `z-regex` | 112 | 1,766 | 94.0% | Pendiente |
| `Error`+`NativeErrors` | `z-error` | 86 | 101 | 54.0% | Pendiente |
| `JSON` | `z-json` | 83 | 82 | 49.7% | Pendiente |
| `Number` | `z-number` | 64 | 276 | 81.2% | Pendiente |
| `Map` | `z-map` | 51 | 150 | 73.9% | Pendiente |
| `String` | `z-string` | 33 | 1,187 | 97.3% | Pendiente |
| `Date` | `z-date` | 25 | 569 | 95.8% | **Auditado (NO expandir)** |
| `Symbol` | `z-symbol` | 25 | 71 | 74.0% | Pendiente |
| `Temporal` | `z-temporal` | 24 | 4,579 | 99.5% | Pendiente |
| `encode/decodeURI*` | `z-urlcode` | 10 | 161 | 93.1% | Pendiente |
| `BigInt` | `z-bigint` | 7 | 70 | 90.9% | Pendiente |
| `Math` | `z-math` | 0 | 327 | 100.0% | **Auditado (NO expandir)** |

## Próximos pasos

Orden sugerido de auditoría profunda por densidad de FAIL Test262 frente a tamaño del núcleo (y menor riesgo de cascada):
1. `z-parser` (2,590 FAIL / 1,258 líneas) y `z-statements` (1,831 FAIL / 1,124 líneas)
2. `z-set` (162 FAIL / 103 líneas) y `z-map` (51 FAIL / 145 líneas) — alta densidad FAIL/línea
3. `z-array` (933 FAIL / 732 líneas) y `z-buffer` (478 FAIL / 381 líneas)
4. `z-error` (86 FAIL / 164 líneas) y `z-json` (83 FAIL / 750 líneas)
5. `z-object` (422 FAIL / 1,143 líneas) y `z-functions` (198 FAIL / 803 líneas)

## Hallazgo colateral

- `date_builtins.zig` define `INVALID_DATE_MS = 9223372036854776000` en lugar de `NaN`. Rompe `year-zero.js` y probablemente tests de rango inválido. Fix local en 1 línea del adapter. Deuda técnica independiente de submódulos.
- `z-interpreter/build.zig.zon` tiene 3 dependencias transitivas ocultas en su cascada: `z-equality` (usada por `z-array` y `z-map`), `z-lexer` (usada por `z-parser`), y `z-promise` (usada por `z-value`).
- `z-map` y `z-set` usan tags `0.1.0` (sin prefijo `v`), a diferencia del resto del ecosistema (`v0.x.y`).
