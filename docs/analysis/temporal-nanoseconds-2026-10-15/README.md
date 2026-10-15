# Temporal epoch nanosecond verification — 2026-10-15

## Change and scope

Temporal Instant and ZonedDateTime now convert epoch nanoseconds through
JavaScript `BigInt` and native `i128` without a floating-point round trip. Their
`epochNanoseconds` getters return exact JavaScript `BigInt` values. The conversion
uses [z-bigint v0.1.1](https://github.com/carlos-sweb/z-bigint/releases/tag/v0.1.1),
which adds checked `i128` conversions. `ToBigInt` rejects Number values and
applies ECMAScript string grammar; out-of-range values raise RangeError.

The interpreter uses the same z-bigint module as z-value to keep their BigInt
types identical. z-temporal, z-value, the production z-run repository, the
Test262 runner, and the suite checkout were not changed for this verification.

## Test262 measurement

The frozen set contains 102 paths attributed by the previous
[Temporal surface analysis](../temporal-surface-2026-10-14/README.md) to epoch
BigInt type or precision. [resolved-102.json](resolved-102.json) records each
path and its before/after outcome.

Both measurements cover the same 4,611 Temporal and Date/toTemporalInstant test
paths from Test262 commit `9e61c12835c5e4a3bdba93850427e6742c4f64c4`.
They use the unchanged z-test262 runner, a ReleaseFast z-run consumer, eight
workers, five seconds per test, and a 2 GiB worker address-space limit. The
candidate consumer uses the published z-bigint v0.1.1 package. One result is
recorded per test path.

| Scope | Before PASS | After PASS | After FAIL | CRASH | TIMEOUT | SKIP |
|---|---:|---:|---:|---:|---:|---:|
| 102 frozen epoch paths | 0 | 102 | 0 | 0 | 0 | 0 |
| 833 earlier surface targets | 693 | 795 | 38 | 0 | 0 | 0 |
| 4,611 Temporal segment paths | 3,377 | 3,597 | 1,014 | 0 | 0 | 0 |

Across the full segment, **220 FAIL → PASS** and **zero PASS losses** were
observed. All 102 frozen epoch paths changed from FAIL to PASS; the other 118
gains are additional effects of the conversion and shared BigInt parsing.
Coverage is identical, with no duplicate paths. This segment is not the full
Test262 suite and does not establish full Temporal conformance.

## Verification

- z-bigint v0.1.1: 36/36 tests with Zig 0.16 and Zig 0.17, in Debug and
  ReleaseFast; documentation build passed.
- z-interpreter with the released package: 675/675 tests and 105/105 build
  steps in both Debug and ReleaseSafe.
- Isolated z-run consumer with the released package: 71/71 tests; ReleaseFast
  installation passed 6/6 build steps.
- The interpreter tests cover exact signed and boundary values, getter types,
  Number rejection, JavaScript `ToBigInt` coercion, and the ECMAScript string
  grammar. z-bigint tests cover signed `i128` round trips and overflow.

[metadata.json](metadata.json) records the package hash, binary hash, suite and
runner identities, and resource limits. The previous surface analysis remains
an unchanged historical record.
