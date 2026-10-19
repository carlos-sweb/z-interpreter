# Known limitations

## Temporal status 2026-10-19

The latest focused Temporal Test262 sweep (`/tmp/sweep-f4ef98d.jsonl`) reports
**4,301 PASS / 310 FAIL (93.3%)** out of 4,611 Temporal tests. This is a point-in-time
binding measurement, not a conformance claim.

The remaining 310 failures are grouped by Temporal type as follows:

| Type | FAIL |
| --- | ---: |
| ZonedDateTime | 67 |
| Duration | 44 |
| PlainYearMonth | 44 |
| PlainDateTime | 40 |
| PlainDate | 36 |
| PlainTime | 29 |
| Instant | 26 |
| PlainMonthDay | 15 |
| Now | 9 |

The remaining work is concentrated in per-type edge cases: calendar and time-zone
validation, range boundaries, option/property-bag ordering, and method-specific
rounding or arithmetic behavior. Consult the 310-failure sweep above before
selecting another block; it remains the source of truth for paths and messages.

Recent binding work added per-instance Temporal subclass prototypes and adoption
through `newTarget`/`super()`, while preserving intrinsic return types from
Temporal methods. It also tightened options and property-bag coercion, including
primitive option rejection, numeric and rounding conversions, BigInt rejection
where `ToNumber` requires it, and observable fields. Duration `round()` and
`total()` now coerce string and property-bag `relativeTo` values, including
zoned references.

## Rendimiento actual (2026-10-19)

La medición `fib(30) × 5` bajó de **22.068 ms** a **8.858 ms**: una mejora de
**2,5×**. Los cambios fueron la materialización perezosa de `arguments`, el
camino rápido numérico para operadores binarios y los bindings de entorno en
array con búsqueda lineal.

La comparación con Bun es **29 ms**; el intérprete sigue siendo aproximadamente
**300× más lento**. El límite actual es el tree-walker: el siguiente paso real
es la Fase 2, una VM de bytecode documentada en
`docs/design/bytecode-vm.md`.
