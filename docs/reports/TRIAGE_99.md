# Temporal remaining-failure triage — sweep `216637d`

Date: 2026-10-25  
Input: `/tmp/sweep-216637d.jsonl` (read-only analysis; no suite was run).  
Scope: the 99 records whose result is `FAIL` under `test/built-ins/Temporal/`.

This is a classification of the failure symptom and the implicated layer, not a
claim that every category has been reproduced in isolation. `A` means adapter
work in `z-interpreter`; `B` means behavior in the `z-temporal` v0.2.4 API or
its ISO/zone implementation; `C` means host time-zone data/`Temporal.Now`.

## Result

| Class | Failures | Meaning |
|---|---:|---|
| A — adapter | 40 | Coercion, observable-read ordering, or interpreter construction behavior |
| B — z-temporal v0.2.4 | 50 | Native range/balancing/parser/zone semantics |
| C — environment | 9 | `Temporal.Now` time-zone parsing/data |
| **Total** | **99** | |

## Distribution seen in the sweep

| Base type | FAIL |
|---|---:|
| ZonedDateTime | 26 |
| Duration | 23 |
| PlainYearMonth | 12 |
| Temporal.Now | 9 |
| Instant | 7 |
| PlainTime | 7 |
| PlainDateTime | 6 |
| PlainDate | 5 |
| PlainMonthDay | 4 |

Largest method buckets are `Duration.prototype.round` (9),
`ZonedDateTime.from` (5), `ZonedDateTime.prototype.with` (5),
`Duration.prototype.total` (5), and `ZonedDateTime.prototype.equals` (4).
The leading raw error prefix is `Uncaught RangeError: Invalid or out-of-range
Temporal value` (39); it is spread across several native range clusters and is
not one adapter bug.

## Root-cause clusters

| # | Cluster | Count | Class | Paths / evidence | Likely implementation site |
|---:|---|---:|---|---|---|
| 1 | Observable property/option read order and deferred validation | 28 | A | `Duration.{compare,round,total}` order tests; Plain `with`, `from`, `toPlainDate`; `ZonedDateTime.{from,compare,equals,since,until,with}`. Reasons include `Partial date processed before throwing TypeError`, `day must be an integer`, and recorded `Actual [get ...]` orders. | `src/temporal_builtins.zig`: method-local option readers and observed-bag coercers. Do not reopen the old generic rounding reader. |
| 2 | Representable range and `relativeTo` boundaries | 21 | B | Duration `relativeTo` string/date-limit cases; PlainYearMonth add/subtract/since/until bounds; ZonedDateTime limits, date boundaries, and next-day boundary. Mostly `Invalid or out-of-range Temporal value` or missing expected `RangeError`. | z-temporal: `duration.zig`, `plain_year_month.zig`, `zoned_date_time.zig`, and relative-date balancing helpers. |
| 3 | ISO grammar / accepted string forms | 13 | B | PlainDate and PlainDateTime time-designator cases; 5 PlainTime time-designator cases; Instant `toZonedDateTimeISO` zone-string forms; ZonedDateTime optional-parts and `withPlainTime` strings. | z-temporal `src/iso_string.zig` and zone-string parsing. |
| 4 | Rounding, balancing, and `largestUnit: "auto"` | 11 | B | Duration half-even/roundingIncrement/auto and 4 `toString` cases; Instant `since`/`until` rounding increment; PlainYearMonth add/subtract algorithmic range tests. | z-temporal `rounding.zig`/`duration.zig` and the options contract that distinguishes omitted from `auto`. |
| 5 | `Temporal.Now` host zone handling | 9 | C | `plainDateISO` (2), `plainDateTimeISO` (2), `plainTimeISO` (2), `zonedDateTimeISO` (3): timezone-string, leap-second, and multiple-offset forms. | Host clock/zone provider and tzdata policy; not an adapter coercion fix. |
| 6 | Abrupt `newTarget.prototype` | 8 | A — **blocked** | One `get-prototype-from-constructor-throws.js` for each Temporal constructor; all say `Expected Test262Error but got TypeError`. | `function_builtins.zig` + `interpreter_props.zig` Callable/prototype model. Blocked by the structural Callable refactor; do not patch individual Temporal constructors. |
| 7 | ZonedDateTime native zone semantics | 5 | B | `equals` case-insensitive/offset-normalization (2), `hoursInDay` start-of-day behavior, and `with` basic/constrain behavior. | z-temporal `zoned_date_time.zig` plus time-zone resolution. |
| 8 | Observable `relativeTo` offset error classification | 3 | A | Duration `compare`, `round`, and `total` property-bag offset tests produce `Temporal offset must be a string` where the tests require post-coercion/RangeError behavior. | `temporal_builtins.zig`, Duration-only relativeTo/offset surface. |
| 9 | Instant epoch numeric coercion | 1 | A | `Instant/fromEpochMilliseconds/non-integer.js`: expected RangeError, got TypeError. | `temporal_builtins.zig` numeric conversion surface for `fromEpochMilliseconds`. |

The rows are mutually exclusive and sum to 99. The method-level membership is
intentionally summarized in the table; the raw, complete path/error record
remains `/tmp/sweep-216637d.jsonl`.

## Top five actionable groups

1. **Observable read order / delayed validation — 28 (A).** This is the
   biggest adapter-owned group. It should be split by method-specific reader,
   beginning with one type/method family at a time; its paths do *not* all share
   one safe generic helper.
2. **Range and `relativeTo` bounds — 21 (B).** Native range enforcement and
   calendar-relative balancing in z-temporal; prioritise duration and
   ZonedDateTime boundary primitives before wrapper changes.
3. **ISO grammar — 13 (B).** Parser work in z-temporal, chiefly the distinction
   between a time and a date-like string lacking `T`, plus zone annotation
   grammar.
4. **Rounding / `largestUnit: auto` — 11 (B).** Requires the native options
   representation to preserve `unset` versus explicit `auto`; adapter-only
   changes cannot repair the current v0.2.4 result.
5. **Temporal.Now zone handling — 9 (C).** Requires an explicit tzdata/system
   zone policy, rather than a Temporal binding change.

## Recommended order

1. Keep Cluster 6 explicitly blocked until the Callable/newTarget refactor is
   designed; it is eight tests but cross-cuts ordinary constructors.
2. Take Cluster 9, then Cluster 8, as narrow low-risk adapter commits.
3. Split Cluster 1 by exact method and retain regression guards per reader.
4. Move the B clusters to z-temporal, starting with range/boundary primitives;
   parser and rounding changes need standalone unit coverage before repinning
   z-interpreter.
5. Treat Cluster 5 as an environment decision and report it separately from
   library compatibility.

