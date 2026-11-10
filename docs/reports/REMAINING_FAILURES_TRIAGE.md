# Temporal remaining-failures triage

Date: 2026-10-23  
Sweep input: `/tmp/sweep-feb8f7b.jsonl`  
Interpreter revision measured: `feb8f7b`  
Scope: the 152 records with `result == "FAIL"` under `test/built-ins/Temporal/`.

This is a read-only classification from the stored runner reasons and representative
Test262 sources. It is not a new sweep. The sweep's z-run build resolves the
published z-temporal dependency, so a **B** label identifies work owned by
z-temporal; it does not establish whether an unmeasured local z-temporal checkout
has already fixed it.

## Summary

| Class | Meaning | Failures |
|---|---|---:|
| A | Adapter / z-interpreter binding and observable coercion | 60 |
| B | z-temporal arithmetic, ISO parsing, range, or field semantics | 83 |
| C | Host clock / time-zone environment | 9 |
| **Total** |  | **152** |

## Clusters

The clusters below are mutually exclusive and exhaustive; their counts sum to 152.
The `type / method` column records the affected surface rather than claiming a
single method when the same root cause spans several types.

| # | Cluster and type / method | Count | Class | Evidence and next ownership |
|---:|---|---:|---|---|
| 1 | Range and representable-boundary behavior: Duration relativeTo; PlainMonthDay overflow; PlainYearMonth add/subtract/since/until; ZonedDateTime from/compare/equals/since/until | 28 | B | `Invalid or out-of-range Temporal value`, missing range throws at ISO limits, and boundary normalization. z-temporal needs representable-boundary/range semantics; local checkout status is not measured. |
| 2 | Observable option/field order: Duration compare/round/total/toString; Plain*.with/add/subtract/toPlainDate; ZonedDateTime from/with/since/until/getTimeZoneTransition | 24 | A | Getter traces or premature `TypeError`/`RangeError`. Route-specific readers in `src/temporal_builtins.zig`; split by method family, not a shared R3 helper. |
| 3 | Calendar-unit balancing and exact multiples: Duration.round/toString; Instant since/until; PlainDate/PlainDateTime/PlainYearMonth/ZonedDateTime since/until | 17 | B | Exact-multiple assertions, calendar balancing, `largestUnit: auto`, and non-integer increment behavior. z-temporal rounding/balance algorithms need changes. |
| 4 | Remaining z-temporal semantic/error-type behavior: Duration relativeTo offsets/rounding; Instant epoch conversion; PlainDateTime/PlainYearMonth month-code validation timing; ZonedDateTime transition/hoursInDay | 13 | B | Native results are wrong (not merely observable Gets): offset validation class, missing RangeError, native calendar constraints. Requires targeted z-temporal work; local status unmeasured. |
| 5 | ISO and time-zone parser grammar: Instant sub-minute offsets/toZonedDateTimeISO; ZonedDateTime duplicate zone annotations | 12 | B | Missing rejection of sub-minute offsets and repeated bracket annotations. z-temporal ISO parser. |
| 6 | `Temporal.Now.*` time-zone string / leap-second paths | 9 | C | All nine `Now` failures are host time-zone/clock conversion paths (`timezone-string-datetime`, `timezone-string-leap-second`, multiple offsets). Needs tzdata/host-zone capability, not adapter ordering. |
| 7 | ISO `T` time-designator grammar: PlainDate conversion, PlainDateTime.withPlainTime, PlainTime from/compare/equals/since/until, ZonedDateTime.withPlainTime | 9 | B | The parser accepts ambiguous `"12-14"` where Test262 requires a `T` prefix. z-temporal ISO parser. |
| 8 | Abrupt `newTarget.prototype`: all eight Temporal constructors | 8 | A | `Expected Test262Error but got TypeError`. Constructor/prototype resolution is in interpreter object construction (`interpreter_expr.zig` / property access), not z-temporal. |
| 9 | Constructor / argument field conversion order: PlainDate, PlainDateTime, PlainMonthDay, PlainTime, PlainYearMonth | 7 | A | `argument-convert.js` and calendar-invalid getter traces show field conversion/error sequencing in `temporal_builtins.zig`. |
| 10 | Observed `monthCode` coercion/order: PlainDateTime.from; PlainYearMonth from/since/until; ZonedDateTime from/compare/equals | 7 | A | `monthCode must be a string` occurs while observable bags require `ToString`. Continue the strict-direct vs observed-bag split in the relevant observed-bag readers. |
| 11 | Temporal calendar objects: PlainDate/PlainDateTime/ZonedDateTime withCalendar/since/until | 5 | A | `Calendar must be a string` for a Temporal calendar object. Central calendar-value coercion in `temporal_builtins.zig`. |
| 12 | ZonedDateTime offset coercion/order: compare/from/equals | 5 | A | Invalid offset bags yield the wrong type, or `overflow` is read at the wrong time. Local to ZonedDateTime coercion/readers in `temporal_builtins.zig`. |
| 13 | Field/balance semantics: PlainYearMonth add/subtract; ZonedDateTime.with | 4 | B | Lower duration units and missing/invalid ZDT field constraints are accepted/rejected incorrectly by native semantics. z-temporal. |
| 14 | Enum/numeric option conversion: ZonedDateTime getTimeZoneTransition/since/until | 4 | A | `direction` and BigInt `roundingIncrement` have incorrect ToString/ToNumber error classification. Local adapter readers. |

## Top five by count

1. **28 — B — range / representable boundaries.** z-temporal must implement
   ISO-range and relativeTo boundary semantics. No local checkout verification was
   performed, so whether 67b3d27 already fixes any subset is **indeterminado**.
2. **24 — A — observable order/options.** `src/temporal_builtins.zig` has
   method-specific readers that still validate during observable field acquisition.
   Highest adapter return, but split it into `Duration`, `Plain*.with`, and
   `ZonedDateTime` commits to avoid another cross-method regression.
3. **17 — B — calendar rounding/balance.** Exact-multiple and largest-unit-auto
   behavior belongs in z-temporal's rounding/balance implementation.
4. **13 — B — native semantic/error-type behavior.** Includes duration relativeTo
   and native range/error handling; smaller, heterogeneous z-temporal fixes.
5. **12 — B — ISO/time-zone grammar.** Parser rejection of invalid offsets and
   duplicate zone annotations.

## Directly actionable adapter order

1. Cluster 8 (8): propagate abrupt `newTarget.prototype` exceptions. It is
   transversal but has a crisp expected-error signal.
2. Cluster 10 (7): observed `monthCode` coercion, starting with the existing
   PlainDateTime strict/observed split and then the YearMonth/ZonedDateTime
   observed readers.
3. Cluster 11 (5): Temporal calendar objects through common calendar coercion.
4. Cluster 12 (5) and 14 (4): ZonedDateTime option/offset and enum numeric
   coercion, each isolated to their local readers.
5. Cluster 2 (24): only after per-method spec-order review; it is the largest
   adapter group but deliberately not a single shared-helper change.

## Raw evidence

The complete per-test result, path, and assertion/error text remains in
`/tmp/sweep-feb8f7b.jsonl`. The paths in each table row are recoverable by the
prefixes and method families named above; no result was inferred from a new test
execution.

## Limits

- This report does not run z-temporal standalone tests or the Test262 suite.
- “B” means the failing behavior crosses the adapter and reaches native
  z-temporal semantics in the published dependency used by the sweep; local
  z-temporal fixes were not measured here.
- The 9 “C” cases may also need z-temporal parsing support, but their public API
  is `Temporal.Now` and their current trigger is host time-zone/clock input, so
  they are not suitable for an adapter-only commit.

## Adapter closure update (2026-10-24)

The three active cases formerly retained under Cluster 2 --
`Duration.prototype.toString` and `PlainYearMonth.prototype.add`/
`subtract` -- are reclassified as **Class B**. Their option acquisition is
already completed by the adapter; the missing algorithmic `RangeError` is in
z-temporal's formatting and PlainYearMonth boundary semantics.

The adapter is closed at the user-measured Temporal result of **4483 PASS /
128 FAIL (97.2%)**. The only remaining Class A cases are Cluster 8's eight
`newTarget.prototype` abrupt-completion tests, blocked on the structural
Callable refactor that separates constructability from a function's own
`prototype` property. The next measurement should use the local z-temporal
checkout before further adapter work is attempted.
