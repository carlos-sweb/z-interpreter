# Temporal failure triage — sweep `621fe1e`

Date: 2026-10-25  
Input: `/tmp/sweep-621fe1e.jsonl` (read-only analysis; no commands were run
against Test262).  
Scope: 90 `FAIL` records below `test/built-ins/Temporal/`.

`A` is adapter/interpreter work, `B` is z-temporal v0.2.5 behavior, and `C`
is host time-zone data or `Temporal.Now` policy. The clusters below are
mutually exclusive and sum to 90.

## Result

| Class | FAIL |
|---|---:|
| A — z-interpreter adapter | 40 |
| B — z-temporal v0.2.5 | 41 |
| C — environment / Now | 9 |
| **Total** | **90** |

| Base type | FAIL |
|---|---:|
| Duration | 23 |
| ZonedDateTime | 19 |
| PlainYearMonth | 10 |
| Temporal.Now | 9 |
| Instant | 7 |
| PlainTime | 7 |
| PlainDateTime | 6 |
| PlainDate | 5 |
| PlainMonthDay | 4 |

The largest raw error prefixes are `Invalid or out-of-range Temporal value`
(37), `Expected Test262Error but got TypeError` (8), and `Temporal offset must
be a string` (5). The first prefix is not a single bug: it spans native range,
ISO parser, and time-zone parsing paths.

## Clusters

| # | Root cause | Count | Class | Representative paths | Likely site |
|---:|---|---:|---|---|---|
| 1 | Observable option/field ordering and deferred validation | 28 | A | Duration `compare`/`round`/`total`; Plain `with`/`from`/`toPlainDate`; ZDT `from`/`compare`/`equals`/`since`/`until`/`with` | `src/temporal_builtins.zig`, method-local readers only |
| 2 | Relative-duration / representable boundary behavior | 13 | B | Duration `relativeTo` strings/date limits; PlainYearMonth `since`/`until` limits; ZDT `since`/`until` `argument-at-limits`; Duration round next-day edge | z-temporal `relative.zig`, `duration.zig`, `zoned_date_time.zig`, `plain_year_month.zig` |
| 3 | ISO and time-zone string grammar | 13 | B | 10 time-designator cases across PlainDate/Time/DateTime/ZDT, plus 3 Instant `toZonedDateTimeISO/timezone-string-*` | z-temporal `iso_string.zig` and time-zone string conversion |
| 4 | Rounding, balancing, and `largestUnit: "auto"` | 11 | B | Duration round/toString, Instant since/until increment, PlainYearMonth add/subtract algorithmic validation | z-temporal `rounding.zig`, `duration.zig`, `plain_year_month.zig` |
| 5 | `Temporal.Now` time-zone conversion | 9 | C | all `Now/*ISO/timezone-string-{datetime,leap-second,multiple-offsets}` | host clock / tzdata policy |
| 6 | Abrupt `newTarget.prototype` | 8 | A — blocked | one `get-prototype-from-constructor-throws.js` per Temporal constructor | Callable/prototype model in `function_builtins.zig` and `interpreter_props.zig` |
| 7 | ZonedDateTime native zone/field semantics | 4 | B | equals case/offset normalization; `with/basic`; `with/constrain-day` | z-temporal `zoned_date_time.zig` and zone normalization |
| 8 | Duration observed `relativeTo.offset` error class | 3 | A | `compare`, `round`, `total` property-bag invalid-offset tests | `temporal_builtins.zig` Duration relativeTo bag reader |
| 9 | Instant epoch-milliseconds numeric surface | 1 | A | `Instant/fromEpochMilliseconds/non-integer.js` | `temporal_builtins.zig` numeric conversion |

## Required confirmations

- **Cluster 8 / newTarget:** exactly **8** failures remain. They are still
  blocked by the structural Callable/newTarget-prototype refactor, not by
  Temporal constructors.
- **Residual ISO parser:** **10** direct time-designator-required failures
  remain. There are **0** remaining paths named for sub-minute offsets or
  duplicate bracketed zone annotations. Three additional Instant
  `timezone-string-*` failures are kept separate in Cluster 3 because they
  parse a time-zone argument, not a Temporal date-time string.
- **Observable order/validation:** exactly **28** failures remain; they are
  still the highest-return adapter-owned group, but have method-specific
  ordering and must not be repaired through one generic options helper.

## Top five and recommendation

1. **Observable order/validation — 28 (A):** highest test count, but split
   into method-local commits in `temporal_builtins.zig` with ordering guards.
2. **Relative/boundary behavior — 13 (B):** next native target; current
   v0.2.5 fixed nine prior paths but not Duration calendar balancing and ZDT
   operand-at-limit handling.
3. **ISO/time-zone grammar — 13 (B):** parser-specific follow-up after the
   boundary work; avoid reopening already-fixed sub-minute/duplicate-zone
   rules without focused tests.
4. **Rounding/balancing/auto — 11 (B):** requires preserving `unset` versus
   explicit `auto` in z-temporal's options representation.
5. **Temporal.Now — 9 (C):** requires a documented host/tzdata decision,
   not adapter coercion.

Recommendation: attack **Cluster 1 in z-interpreter first**, one method family
at a time; it owns 28 failures and has no release/tzdata dependency, while the
remaining native clusters need broader standalone semantic work.
