# Shared Temporal `read*` helper map

**Read-only inventory:** 2026-10-22  
**Tree inspected:** `z-interpreter` `074cd2f` (the working tree has no source
changes for this report)  
**Failure evidence:** `/tmp/sweep-9f1394e.jsonl`, 171 Temporal FAIL records.
That sweep predates `074cd2f`; entries repaired after that SHA are marked as
historical rather than current.

## Method and scope

This map includes active `read*` implementations that are reached by two or
more Temporal public routes, either directly or through a thin `read*` wrapper.
It does not count ten-field loops such as `readDurationFromField` as shared
public-route helpers: they are repeated reads inside one API algorithm.
Likewise, `readDisambiguation`, `readOffsetOption`, and `readRelativeTo` have no
live direct call site in this revision and are listed under exclusions.

"Direct helper candidate" means the observed failure is plausibly repaired by
changing only that helper. "Route work" means the failing operation must first
change when it calls the helper, or must change its own coercion/validation.
The latter must not be folded into a transversal change.

## Inventory

| Helper and signature | Public routes reaching it | Current observable read order / acceptance | Spec-order relation | 9f1394e failures attributable to it | Risk |
|---|---|---|---|---|---|
| `readPlainOverflow(self, options) -> Overflow` | `PlainDate.{with,add,subtract}`; `PlainTime.with`; `PlainDateTime.{with,add,subtract}`; `PlainYearMonth.{with,add,subtract}`; `PlainMonthDay.with` | `GetOptionsObject`; then `Get(options, "overflow")`, then `ToString`; accepts all non-primitives through `surfaceOptions`. Callers choose when it runs. | The `overflow` subalgorithm is uniform; its position relative to fields/other arguments is method-specific. | Four `*/from/observable-get-overflow-argument-primitive.js` failures in the old sweep are **not** this helper: the `.from` routes call `observableFromOverflow` too early. `PlainMonthDay` is repaired by `074cd2f`. | R2 |
| `readRoundingOptionsGeneric(self, T, options, default_mode) -> T` | via `readRoundingOptions`: `Instant.{since,until}`; via `readRoundOptions`: `Instant.round` | For ordinary `.object` only: `smallestUnit`, `largestUnit`, `roundingIncrement`, `roundingMode`; validates each immediately. Proxy/function options default silently because the tag guard is `.object`. | `round` and difference settings have different required keys and orders; current shared order matches neither consistently. | Direct: `Instant.round/options-read-before-algorithmic-validation.js`, `options-wrong-type.js`, `roundingincrement-non-integer.js`; `Instant.{since,until}/{options-read-before,order-of-operations,roundingincrement-non-integer}.js` need this plus route-level unit validation. | R3 |
| `readRoundingOptions(self, options) -> RoundingOptions` | `Instant.{since,until}` | Calls `surfaceOptions` then generic reader. It accepts Proxy at the outer check, but the generic reader ignores it. | Difference order is shared by these two routes, but differs from `round`. | Same six `Instant.since/until` candidates above; not separately fixable from the generic reader. | R3 (wrapper) |
| `readRoundingOptionString(self, options, key) -> ?[]u8` | `readPlainRoundingOptionsGeneric`; `readDurationRoundOptions` | `Get` then `ToString`; accepts Proxy/callable options and propagates getters. | Uniform primitive operation; caller determines field sequence. | No isolated current failure. It is already the correct low-level operation. | R1 |
| `readRoundingOptionNumber(self, options, key) -> ?f64` | `readPlainRoundingOptionsGeneric`; `readDurationRoundOptions` | `Get`; BigInt -> TypeError; otherwise `ToNumber`. | Uniform primitive operation; caller determines sequencing/range checks. | No isolated current failure. Range/ordering failures are callers' deferred validation. | R1 |
| `readPlainRoundingOptionsGeneric(self, T, options, default_mode, is_difference) -> T` | Difference: `PlainDate.{since,until}`, `PlainTime.{since,until}`, `PlainDateTime.{since,until}`, `PlainYearMonth.{since,until}`. Round: `PlainTime.round`, `PlainDateTime.round`. | Difference: `largestUnit`, `roundingIncrement`, `roundingMode`, `smallestUnit`; round: omit `largestUnit`, then increment/mode/smallest. Acquires raw values before validation; accepts Proxy via `surfaceOptions`. | The boolean correctly represents the two families, but not every Temporal type: `Duration.round` has an independent alphabetical sequence. | No direct old-sweep failure conclusively points here. `PlainTime/PlainDateTime round/options-wrong-type.js` may include route required-option behavior; inspect before changing. | R2 |
| `readPlainRoundingOptions` / `readPlainRoundOptions` | The eight difference and two round routes above | Thin specializations of the previous helper. | Same two-family split. | No independent candidates. | R2 (wrappers) |
| `readDurationCompareOptions(self, options) -> ?RelativeTo` | `Duration.compare`, `Duration.round`, `Duration.total` | `Get(options, "relativeTo")`, then converts a string, Temporal ZDT, or property bag. | All three call it at different positions: compare is only `relativeTo`; round reads it between `largestUnit` and increment; total reads it before `unit`. | `Duration/{compare,prototype/round,prototype/total}/order-of-operations.js` fail, but the shown error is inside `relativeTo` bag coercion (`monthCode`), so each also needs local/read-relativeTo work. Invalid-offset failures are conversion/type mapping, not this getter alone. | R3 |
| `readZonedDateTimeBagRaw(self, fields) -> ZonedDateTimeBagRaw` | `ZonedDateTime.from` property-bag path; `coerceZonedDateTime` reached by `compare` and `equals`, and from Duration `relativeTo` readers | Acquires raw fields in `calendar, day, hour, microsecond, millisecond, minute, month, monthCode, nanosecond, offset, second, timeZone, year` order; accepts every non-primitive Object. | `PrepareTemporalFields` order is type-specific. Validation priority is intentionally partly outside this reader. | `ZonedDateTime/{from,compare,prototype/equals}/order-of-operations.js` involve it, but the immediate `monthCode`/offset errors are in `zonedDateTimeFromRawBag`; do not change this raw reader alone. | R3 |
| `readZonedDateTimeFromOptions(self, options) -> ZonedDateTimeFromOptions` | Three branches of `ZonedDateTime.from` (string, property bag, Temporal/other) | `GetOptionsObject`, then raw `Get` of `disambiguation, offset, overflow`, then converts all three. | Its own order is shared by these branches; its position versus string parsing/property fields differs by branch. | `ZonedDateTime/from/{options-read-before-algorithmic-validation,observable-get-overflow-argument-primitive}.js` require both branch scheduling and this reader; not helper-only. | R3 |

## Excluded or single-route readers

| Reader | Why excluded |
|---|---|
| `readOverflow` | Only reached through `observableFromOverflow`; semantic fan-out exists, but no second direct public route. It currently ignores Proxy itself (`options != .object`), so any future fix requires per-`from` sequencing guards. |
| `readDisambiguation`, `readOffsetOption`, `readRelativeTo` | No live direct caller found by static search at `074cd2f`; changing them cannot repair current behavior. |
| `readDurationFromField`, `readDurationWithField`, `readDurationWithFields` | Repeated fields within one Duration algorithm, not two public routes. |
| `readDurationRoundOptions`, `readDurationTotalOptions` | Single public route each; already intentionally separated after earlier Duration regressions. |

## Failure grouping: helper-only versus route work

### Candidate set A: generic Instant rounding reader — 9 named old-sweep failures

**Potential helper-only core:**

- `Instant/prototype/round/options-read-before-algorithmic-validation.js`
- `Instant/prototype/round/options-wrong-type.js`
- `Instant/prototype/round/roundingincrement-non-integer.js`

**Needs local method validation as well:**

- `Instant/prototype/since/{options-read-before-algorithmic-validation,order-of-operations,roundingincrement-non-integer}.js`
- `Instant/prototype/until/{options-read-before-algorithmic-validation,order-of-operations,roundingincrement-non-integer}.js`

The generic reader is the common mechanism, but `since`/`until` must preserve
`other` conversion before option access and enforce their permitted unit set.
A standalone generic edit previously regressed Duration; this is not safe as an
unparameterized change.

### Candidate set B: Plain rounding primitive readers — no demonstrated helper-only failures

`readPlainRoundingOptionsGeneric` already obtains all of its raw values before
validation and its wrappers divide round from difference. The three old-sweep
`options-wrong-type` failures (`PlainTime.round`, `PlainDateTime.round`, and
related `with`) have distinct missing-option or field-before-options behavior.
They need route tests before any helper edit.

### Candidate set C: overflow — 4 historical failures, all route scheduling

- `PlainDate/from/observable-get-overflow-argument-primitive.js`
- `PlainDateTime/from/observable-get-overflow-argument-primitive.js`
- `PlainMonthDay/from/observable-get-overflow-argument-primitive.js` (repaired in `074cd2f`)
- `PlainYearMonth/from/observable-get-overflow-argument-primitive.js`

Each requires coercing/rejecting the item before obtaining `options.overflow`.
The common textual symptom is not a reason to modify `readPlainOverflow` or
`readOverflow`: those helpers do not decide when their callers invoke them.

### Candidate set D: Duration `relativeTo` — 3 order failures plus type mapping

- `Duration/compare/order-of-operations.js`
- `Duration/prototype/round/order-of-operations.js`
- `Duration/prototype/total/order-of-operations.js`

The shared `relativeTo` acquisition can be improved, but it is embedded at a
different position in each operation. The invalid-offset tests under the same
three APIs also require offset-string type/error conversion. Split by public
method or parameterize the sequence with route-specific tests.

### Candidate set E: ZonedDateTime raw/options — at least 5 mixed failures

The `from`, `compare`, and `equals` order failures, plus `from` option-order
failures, share raw readers but have error-priority rules in
`zonedDateTimeFromRawBag` and different preambles. They are not helper-only.

## Risk classification and implementation order

| Priority | Helper / scope | Named failure opportunity | Risk | Files | Commit shape |
|---:|---|---:|---|---|---|
| 1 | `readRoundingOptionString` and `readRoundingOptionNumber` | 0 direct; prerequisite guard only | R1 | `temporal_builtins.zig`, tests | Do not make a behavior-only commit; retain as tested primitives. |
| 2 | `readPlainRoundingOptionsGeneric` with its two wrappers | 0 proven helper-only; 10 callers protected | R2 | `temporal_builtins.zig`, tests | One helper commit only if a reproduced Plain reader defect is isolated. |
| 3 | `readPlainOverflow` scheduling callers | 3 remaining historical primitive-item candidates after `074cd2f` | R2 | `temporal_builtins.zig`, tests | **One commit per `.from` type**, not a helper commit. |
| 4 | `readRoundingOptionsGeneric` plus Instant wrappers | 3 direct round + 6 mixed since/until candidates | R3 | `temporal_builtins.zig`, tests | Split `Instant.round` from `Instant.since/until`; parameterize or replace the generic reader only after guards for both. |
| 5 | `readDurationCompareOptions` | 3 ordering + invalid-offset variants | R3 | `temporal_builtins.zig`, tests | One commit per Duration API family; do not make this a global `relativeTo` edit. |
| 6 | ZonedDateTime raw/options readers | >=5 mixed candidates | R3 | `temporal_builtins.zig`, tests | Separate `from` scheduling from raw-field validation; protect compare/equals. |

## Totals and recommendation

- **11 active shared `read*` helpers/wrappers** are in scope under the stated
  route-reachability definition.
- **R1: 2; R2: 4; R3: 5.**
- There is no high-return R1 edit supported by the failure evidence. The
  best next low-risk work is the three remaining Plain `.from` primitive-item
  scheduling fixes, but they are local callers of overflow reading, not a
  `read*` transversal. The highest-return shared helper is
  `readRoundingOptionsGeneric`, but it is R3 and should be split into
  `Instant.round` and `Instant.since/until` commits.
