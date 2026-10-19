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
