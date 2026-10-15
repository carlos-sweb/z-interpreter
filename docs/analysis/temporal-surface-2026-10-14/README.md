# Temporal surface verification — 2026-10-14

## Scope and implementation

This change implements Block 2 of the Temporal binding plan on top of
z-interpreter v0.2.1 (`319649c`), using z-temporal v0.2.0 (`dd7700a`) and Zig
0.17.0. It does not change the native library, production dependency manifests,
Test262 sources, or historical baselines. No version bump or publication is part
of this change.

The adapter now exposes the missing Plain conversions and calendar changes;
ZonedDateTime `with`, arithmetic, differences, rounding, PlainTime/time-zone/calendar
changes; missing getters; prototype `toJSON`, `toLocaleString`, and `valueOf`;
constructor descriptors and `Symbol.toStringTag`. It also implements
`Date.prototype.toTemporalInstant` and `Object.getOwnPropertyDescriptors` used by
the tests. PlainYearMonth formatting respects `calendarName` and the constructor's
reference ISO day. Getter function names use interpreter-lifetime storage; temporary
conversion strings are freed after each native call.

`toLocaleString` provides the basic Temporal text fallback; Intl is not implemented.
Native difference operations receive explicit JavaScript unit defaults, including
`auto`, rather than relying on the native Instant defaults. All new methods check
the receiver brand, and new field/option extraction goes through JavaScript getters.

## Measured results

The frozen target set contains 833 unique historical failures: 340 missing-method,
224 unexposed-API, and 269 descriptor/getter/symbol/format cases. The last group
includes the 35 PlainYearMonth formatting prerequisites. This is a fixed diagnostic
selection, not a new canonical baseline.

Both baseline and candidate executables were run against identical paths on the
same day with the unchanged z-test262 runner, ReleaseFast, eight workers, five
seconds per test, and a 2 GiB address-space limit per worker. The broader segment
contains 4,603 Temporal tests and eight Date/toTemporalInstant tests. One runner
record represents one test path, not separate strict/non-strict variants.

| Scope | Baseline PASS | Candidate PASS | Candidate FAIL | CRASH | TIMEOUT | SKIP |
|---|---:|---:|---:|---:|---:|---:|
| 833 target paths | 0 | 693 | 140 | 0 | 0 | 0 |
| 4,611 segment paths | 2,659 | 3,377 | 1,234 | 0 | 0 | 0 |

There are **718 FAIL → PASS transitions and zero PASS losses** in the broader
segment. Coverage is identical with no duplicate paths. There were no crashes,
timeouts, or PASS losses requiring serial rechecks. This is not a full Test262 run
and does not establish full Temporal or ECMA-262 conformance.

| Target bucket | Paths | PASS | FAIL |
|---|---:|---:|---:|
| descriptors | 269 | 266 | 3 |
| missing-method | 340 | 212 | 128 |
| unexposed-API | 224 | 215 | 9 |

## Remaining target failures

Every remaining path, first failure, declared feature/include, attribution, and
supporting evidence is recorded in [remaining.json](remaining.json). Attribution
is deliberately limited to what was checked; unresolved cases must not be assigned
to the native library merely because the binding now exposes the API.

| First-failure attribution | Tests |
|---|---:|
| `existing-interpreter-epoch-BigInt-type-or-precision` | 102 |
| `existing-interpreter-instance-property-model` | 11 |
| `unresolved-semantic-edge` | 11 |
| `existing-interpreter-cross-type-coercion` | 5 |
| `native-PlainTime-parser` | 4 |
| `existing-interpreter-monthCode-coercion` | 2 |
| `native-ZonedDateTime-local-range` | 2 |
| `native-ZonedDateTime-duplicate-zone-parser` | 2 |
| `existing-interpreter-PlainMonthDay-format-options` | 1 |

The 102 epoch failures were checked against native Temporal in Node: the original
tests pass, while emulating the interpreter's existing Number epoch getter and
float round-trip in nanosecond constructors reproduces the identical first
assertion. These require a separate BigInt representation/coercion change.

The other confirmed interpreter gaps are the existing Temporal instance property
model, cross-type coercion, monthCode coercion, and PlainMonthDay formatting
options. These are semantic follow-up work beyond installing the missing surface.

Eight cases expose three native parser/range defects reproduced independently in
[native-evidence.json](native-evidence.json): ambiguous PlainTime strings without
`T`, duplicate time-zone annotations, and the lower local-date range boundary of
ZonedDateTime. Eleven cases remain unresolved semantic edges; their exact first
assertions are preserved for diagnosis. No fixes for those defects are included.

## Verification

- Interpreter Debug: 672 tests passed (602 executed plus 70 cached on the final run).
- Interpreter ReleaseSafe: 672/672 passed in the complete run; final exact-source
  verification passed 112 executed tests plus 560 cached, 105/105 build steps.
- Isolated z-run consumer tests: 71/71 passed, 22/22 build steps.
- Isolated z-run ReleaseFast installation: 6/6 build steps passed.
- Added regressions cover descriptors, symbols, getter brands/names, serialization,
  Plain conversions, ZonedDateTime DST arithmetic and unit defaults, PlainYearMonth
  formatting, Date exact limits, and retained values across garbage collection.
- The production z-run manifest and all other repositories remain unchanged.

The temporary consumer is a copy of z-run `aa98238` with only its temporary
z-interpreter dependency redirected to this working tree. It does not modify the
production z-run checkout.

## Evidence and reproduction

- [targets.json](targets.json): all 833 frozen paths, categories, and A/B outcomes.
- [remaining.json](remaining.json): all 140 remaining failures and evidence.
- [comparison.md](comparison.md): broader segment comparison.
- [metadata.json](metadata.json): source commits, suite commit, runner/binary hashes,
  and execution limits.

Raw measurements, logs, the temporary consumer, and orchestration scripts are in
`/tmp/temporal-surface-20261014-implementation/`. These temporary files are not
historical baselines and may be removed by system cleanup. Final raw outputs are
`baseline-full.jsonl`, `completed-full.jsonl`, `baseline-target.jsonl`, and
`completed-target.jsonl`.

With the local checkouts and binaries recorded in metadata, the unchanged runner
is invoked through the wrapper as follows:

```sh
python3 /tmp/temporal-surface-20261014-implementation/sweep.py completed \
  /tmp/temporal-surface-20261014-implementation/fast/bin/z-run
python3 /home/sweb/z-test262/compare.py \
  /tmp/temporal-surface-20261014-implementation/baseline-full.jsonl \
  /tmp/temporal-surface-20261014-implementation/completed-full.jsonl \
  --fail-on-regression
zig build test --summary all
zig build test -Doptimize=ReleaseSafe -j8 --summary all
```

The first command regenerates temporary candidate measurements; it must not be
pointed at historical baseline filenames. The historical 47,381-path sweep remains
untouched. This report records a successful surface implementation with residual
semantic gaps; it does not claim that all 833 cases are fixed.
