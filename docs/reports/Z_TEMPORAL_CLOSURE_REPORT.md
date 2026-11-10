# Z-Temporal closure report

## Scope and identity

- Report timestamp: `2026-10-20T12:40:11-03:00` (America/Santiago, UTC-03:00).
- z-interpreter branch and SHA: `master` / `00949ee5d9c1ef5f0bd01a6df577d54299a4c30c`.
- z-temporal package selected by `z-run`: published `ztemporal` `v0.2.1` from `build.zig.zon`; this is the package exercised by Test262.
- Separate local z-temporal checkout inspected for implementation status: `67b3d27f75e5333128a9a3aa2bf9eec80e943538`. It was not substituted into the z-run build.
- Test262 checkout: `9e61c12835c5e4a3bdba93850427e6742c4f64c4`; runner checkout: `337f010a4dad87facceef7432db3264edb0bc6d4`.

## Measurement

### Test262 Temporal through z-interpreter

- Result: **4359 PASS / 244 FAIL / 4603 total**; no SKIP, CRASH, or TIMEOUT records in this focused output.
- Raw result file: `/tmp/ztemporal-closure-00949ee.jsonl` (not committed; the complete list is reproduced in Appendix A).
- Exact commands used:

```sh
cd /home/sweb/z-run
timeout 300 zig build install --fork /home/sweb/z-interpreter -Doptimize=Debug -p /tmp/zrun-temporal-closure > /tmp/ztemporal-closure-build.log 2>&1
cd /home/sweb/z-interpreter
timeout 300 python3 /home/sweb/z-test262/runner.py --suite /home/sweb/test262 --zrun /tmp/zrun-temporal-closure/bin/z-run --jobs 4 --timeout 5 --out /tmp/ztemporal-closure-00949ee.jsonl test/built-ins/Temporal > /tmp/ztemporal-closure-runner.log 2>&1
```

This is a JavaScript Test262 measurement through `z-run` and the current `z-interpreter` adapter, including its property access, coercion, prototype, error, and Temporal wrapping layers. It is **not** a direct z-temporal unit-test result.

### Separate z-temporal unit metric

- Local checkout command: `cd /home/sweb/z-temporal && timeout 300 zig build test > /tmp/ztemporal-unit-test.log 2>&1`.
- Result: exit status 0; the log is empty. The build does not print a test count, so a numeric unit-test total was not measured and is not combined with Test262.

## Remaining failures by type

| Type | FAIL | Status |
| --- | ---: | --- |
| PlainTime | 22 | partial |
| PlainDate | 23 | partial |
| PlainDateTime | 29 | partial |
| PlainYearMonth | 35 | partial |
| PlainMonthDay | 11 | partial |
| Duration | 36 | partial |
| Instant | 23 | partial |
| ZonedDateTime | 56 | partial |
| Now | 9 | partial |

## Checklist of surface and internal capability

| Area | Status | Evidence / boundary |
| --- | --- | --- |
| PlainTime | Partial | 22 focused Test262 failures remain. |
| PlainDate | Partial | 23 focused Test262 failures remain. |
| PlainDateTime | Partial | 29 focused Test262 failures remain. |
| PlainYearMonth | Partial | 35 focused Test262 failures remain. |
| PlainMonthDay | Partial | 11 focused Test262 failures remain. |
| Duration | Partial | 36 focused Test262 failures remain, chiefly relativeTo, rounding, and observable options. |
| Instant | Partial | 23 focused Test262 failures remain. |
| ZonedDateTime | Partial | 56 focused Test262 failures remain, the largest type bucket. |
| Temporal.Now | Partial | 9 focused Test262 failures remain; they concern supplied time-zone string validation, not a measured host-clock failure. |
| Calendar protocol | Pending | z-temporal supports typed calendar IDs; the adapter does not establish a full JavaScript Calendar-object protocol. |
| TimeZone protocol | Pending | Named IANA IDs and fixed offsets are supported by z-temporal; a full JavaScript TimeZone-object protocol was not demonstrated by this measurement. |
| ISO parsing / formatting | Partial | Most coverage passes; failures include ambiguous time strings, duplicate zone annotations, range limits, and offset validation. |
| Rounding | Partial | Failures remain in increment conversion, largest/smallest unit constraints, and calendar/zoned balancing. |
| Overflow | Partial | Observable ordering and several reject/constrain edge cases remain. |
| Balance / difference / total | Partial | Duration and date-family exact-multiple and calendar-unit cases remain. |
| Temporal subclass instances | Closed for this sweep | No `subclass.js` or `subclassing-ignored.js` path is in the 244 failures. |
| Per-instance Temporal properties/prototypes | Partial | 8 `get-prototype-from-constructor-throws.js` failures remain. |
| ICU / Intl localization | Pending in this build | z-run was built without `-Dtemporal-intl=true`; ICU functionality was not enabled or measured. |

## Failure categorization

The categories below are an attribution ledger, not a claim that every non-wrapper failure is a z-temporal-library defect. A failure is assigned to **f** only when its path directly exercises JS adapter semantics. All other failures are deliberately **h = indeterminate** until reproduced through the typed z-temporal API or a narrower adapter trace.

| Category | Count | Basis |
| --- | ---: | --- |
| a) non-ISO calendar | 0 | No current failing path/reason uniquely establishes a non-ISO-calendar backend defect. |
| b) IANA / tzdata | 0 | No current failing path/reason uniquely establishes a TZif database or transition-data defect. |
| c) Temporal.Now system clock/zone | 0 | The 9 Now failures use supplied invalid time-zone strings; they do not measure host-clock or detected-zone behavior. |
| d) Intl / ICU | 0 | The run has ICU disabled, but no failure was individually proven to be ICU-only. |
| e) confirmed z-temporal bug | 0 | No failure was isolated to the typed library in this read-only report. |
| f) z-interpreter wrapping | 113 | Path names directly assert getters/order, primitive/object coercion, `newTarget.prototype`, or Temporal-object adapter conversion. |
| g) test extraction / outside scope | 0 | All 4,603 records come from `test/built-ins/Temporal`; none was excluded as malformed. |
| h) other: indeterminate | 131 | Algorithm, parsing, range, rounding, and zone-facing failures needing isolation before assignment to the library or adapter. |

### Evidence separating library from adapter

- **f (113)**: 36 `order-of-operations`, 30 `options-read-before-algorithmic-validation`, 23 `*wrong-type*`, 8 `get-prototype-from-constructor-throws`, 5 `observable-get-*`, 5 `argument-convert`, 5 `calendar-temporal-object`, 4 `argument-wrong-type`, and 1 `get-property-throws` cases (overlap removed in the total). These require JS getters/proxies, `To*` conversions, exception identity, or `newTarget.prototype`; the relevant adapter owns those paths in `src/temporal_builtins.zig`, `src/interpreter_props.zig`, and construction in `src/interpreter_expr.zig`/`src/interpreter_class.zig`.
- **e (0)**: none confirmed. This report intentionally does not relabel the 131 remaining cases as library defects without a typed-API reproduction.

## Decisions pending

### tzdata

- Current implementation: z-temporal defaults to `/usr/share/zoneinfo`, reads IANA TZif through `z-date`, supports fixed offsets and `UTC`, and includes a link table generated from tzdata 2026b. It is system data in this measurement, not an embedded immutable database.
- Exact count attributable to tzdata: **not measured / 0 confirmed**. The 56 ZonedDateTime failures include zone-facing parsing and option semantics, but no isolated TZif-data mismatch was established.

### Non-ISO calendars

- Current implementation: `calendar.zig` enumerates ISO plus buddhist, chinese, coptic, dangi, ethioaa, ethiopic, gregory, hebrew, indian, islamic-civil, islamic-tbla, islamic-umalqura, japanese, persian, and roc. All non-ISO operations require `-Dintl=true` and ICU; ISO works without ICU.
- Exact count attributable to non-ISO calendars: **not measured / 0 confirmed** in this default, ICU-disabled run. A dedicated `-Dtemporal-intl=true` build plus categorized rerun is required.

### ICU estimate

- The stated “~2,600 tests require ICU” figure is **not measured by this runner**. The runner output has no ICU requirement classification and no files were excluded on that basis.
- Exact number identified and excluded from this metric: **0**. All 4,603 Temporal paths were executed; the report cannot infer how many would require ICU without an explicit per-test feature map or an ICU A/B run.

## Risks and blockers

- The 131 indeterminate failures include real algorithm candidates and adapter candidates. Treating them as z-temporal bugs without isolation would misdirect the closeout work.
- Default builds depend on host `/usr/share/zoneinfo`; reproducible release validation must pass `-Dtzdata-dir` with a frozen database.
- ICU availability/version is an external build dependency. z-temporal documents ICU 78.3 and tzdata 2026b for parity work, while this measurement used neither pinned override.
- The Test262 runner is a compatibility probe: it wraps tests into temporary files and has documented module/host limitations in `/home/sweb/z-run/AGENTS.md`. This report does not convert the result into a standards-conformance claim.

## No medido

- A direct typed-API reproduction for each of the 131 indeterminate failures.
- The exact number of ICU-required Test262 Temporal tests.
- An ICU-enabled and pinned-tzdata focused Test262 comparison.
- A numeric count of z-temporal unit tests; the successful build emitted no count.
- A current full-suite Test262 regression comparison; this report intentionally ran only `test/built-ins/Temporal`.

## Appendix A — complete raw failure list

Source: `/tmp/ztemporal-closure-00949ee.jsonl`; each line below preserves the runner path and reason. `f` and `h` use the categorization rule above.

| Category | Test | Runner reason |
| --- | --- | --- |
| h | `test/built-ins/Temporal/Duration/compare/relativeto-string-limits.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Duration/compare/relativeto-string.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| f | `test/built-ins/Temporal/Duration/compare/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.relativeTo] should have the same contents. all options should be read first } |
| f | `test/built-ins/Temporal/Duration/compare/options-wrong-type.js` | Uncaught { message: TypeError on wrong options type object Expected a TypeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/Duration/compare/order-of-operations.js` | Uncaught { message: Actual [get one.days, get one.days.valueOf, call one.days.valueOf, get one.hours, get one.hours.valueOf, call one.hours.valueOf, get one.microseconds, get one.microseconds.valueOf, |
| h | `test/built-ins/Temporal/Duration/compare/relativeto-propertybag-invalid-offset-string.js` | Uncaught { message: "1000 is not a valid offset string Expected a TypeError but got a RangeError } |
| f | `test/built-ins/Temporal/Duration/from/get-property-throws.js` | Uncaught { message: name = years Expected a Test262Error but got a TypeError } |
| f | `test/built-ins/Temporal/Duration/get-prototype-from-constructor-throws.js` | Uncaught { message: Expected a Test262Error but got a TypeError } |
| h | `test/built-ins/Temporal/Duration/prototype/round/balances-up-to-weeks.js` | Uncaught { message: Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/Duration/prototype/round/case-where-relativeto-affects-rounding-mode-half-even.js` | Uncaught { message: halfEven rounding is upward with ZonedDateTime relativeTo: hours result: Expected SameValue(«8», «16») to be true } |
| h | `test/built-ins/Temporal/Duration/prototype/round/exact-multiple-of-larger-unit-plaindate.js` | Uncaught { message: P31D weeks..months ceil: weeks result: Expected SameValue(«1», «0») to be true } |
| h | `test/built-ins/Temporal/Duration/prototype/round/exact-multiple-of-larger-unit-zoned.js` | Uncaught { message: P7D days..weeks ceil: days result: Expected SameValue(«1», «0») to be true } |
| h | `test/built-ins/Temporal/Duration/prototype/round/next-day-out-of-range.js` | Uncaught { message: Next day boundary is out of range Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/Duration/prototype/round/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.largestUnit, get options.largestUnit.toString, call options.largestUnit.toString, get options.relativeTo, get options.roundingIncrement, get opt |
| f | `test/built-ins/Temporal/Duration/prototype/round/options-wrong-type.js` | Uncaught { message: TypeError on missing options argument Expected a TypeError but got a RangeError } |
| f | `test/built-ins/Temporal/Duration/prototype/round/order-of-operations.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Duration/prototype/round/relativeto-date-limits.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Duration/prototype/round/relativeto-propertybag-invalid-offset-string.js` | Uncaught { message: "0" is not a valid offset string Expected a TypeError but got a RangeError } |
| h | `test/built-ins/Temporal/Duration/prototype/round/relativeto-string-limits.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Duration/prototype/round/relativeto-string.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Duration/prototype/round/round-and-balance-calendar-units-with-increment-disallowed.js` | Uncaught { message: Cannot round to an increment of months while also balancing to years Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/Duration/prototype/round/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| h | `test/built-ins/Temporal/Duration/prototype/round/succeeds-with-largest-unit-auto.js` | Uncaught RangeError: Invalid largestUnit: auto |
| f | `test/built-ins/Temporal/Duration/prototype/toString/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when result is out of range Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/Duration/prototype/toString/round-cross-unit-boundary.js` | Uncaught { message: 1:59:60 balances to 2 hours Expected SameValue(«"PT1H59M60S"», «"PT2H0S"») to be true } |
| h | `test/built-ins/Temporal/Duration/prototype/toString/throws-when-rounded-duration-is-invalid.js` | Uncaught { message: Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/Duration/prototype/toString/total-of-duration-time-units-out-of-range.js` | Uncaught { message: Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/Duration/prototype/total/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when total of calendar unit requested without relativeTo Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/Duration/prototype/total/order-of-operations.js` | Uncaught TypeError: total() requires a unit |
| h | `test/built-ins/Temporal/Duration/prototype/total/throws-if-unit-property-missing.js` | Uncaught { message: Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/Duration/prototype/total/unit-wrong-type.js` | Uncaught { message: null Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/Duration/prototype/with/order-of-operations.js` | Uncaught TypeError: with() requires an object |
| h | `test/built-ins/Temporal/Duration/prototype/total/relativeto-date-limits.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Duration/prototype/total/relativeto-propertybag-invalid-offset-string.js` | Uncaught { message: "0" is not a valid offset string Expected a TypeError but got a RangeError } |
| h | `test/built-ins/Temporal/Duration/prototype/total/relativeto-string-limits.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Duration/prototype/total/relativeto-string.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| f | `test/built-ins/Temporal/Instant/get-prototype-from-constructor-throws.js` | Uncaught { message: Expected a Test262Error but got a TypeError } |
| f | `test/built-ins/Temporal/Instant/compare/argument-wrong-type.js` | Uncaught { message: Temporal.Instant, object does not convert to a valid ISO string (first argument) Expected a RangeError but got a TypeError } |
| h | `test/built-ins/Temporal/Instant/from/argument-object-tostring.js` | Uncaught { message: Temporal.Instant object is not a valid ISO string Expected a RangeError but got a TypeError } |
| h | `test/built-ins/Temporal/Instant/from/instant-string-sub-minute-offset.js` | Uncaught { message: ISO strings cannot have sub-minute offsets in time zone annotations: 2021-08-19T17:30-07:00:01[-07:00:01] Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/Instant/fromEpochMilliseconds/non-integer.js` | Uncaught { message: undefined Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/Instant/prototype/equals/argument-wrong-type.js` | Uncaught { message: Temporal.Instant, object does not convert to a valid ISO string Expected a RangeError but got a TypeError } |
| h | `test/built-ins/Temporal/Instant/prototype/equals/instant-string-sub-minute-offset.js` | Uncaught { message: ISO strings cannot have sub-minute offsets in time zone annotations: 2021-08-19T17:30-07:00:01[-07:00:01] Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/Instant/prototype/round/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.roundingIncrement, get options.roundingIncrement.valueOf, call options.roundingIncrement.valueOf, get options.roundingMode, get options.rounding |
| f | `test/built-ins/Temporal/Instant/prototype/round/options-wrong-type.js` | Uncaught { message: TypeError on missing options argument Expected a TypeError but got a RangeError } |
| h | `test/built-ins/Temporal/Instant/prototype/round/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| f | `test/built-ins/Temporal/Instant/prototype/since/argument-wrong-type.js` | Uncaught { message: Temporal.Instant, object does not convert to a valid ISO string Expected a RangeError but got a TypeError } |
| h | `test/built-ins/Temporal/Instant/prototype/since/instant-string-sub-minute-offset.js` | Uncaught { message: ISO strings cannot have sub-minute offsets in time zone annotations: 2021-08-19T17:30-07:00:01[-07:00:01] Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/Instant/prototype/since/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when largestUnit disallowed Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/Instant/prototype/since/order-of-operations.js` | Uncaught { message: Actual [get other.toString, call other.toString] and expected [get other.toString, call other.toString, get options.largestUnit, get options.largestUnit.toString, call options.larg |
| h | `test/built-ins/Temporal/Instant/prototype/since/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| h | `test/built-ins/Temporal/Instant/prototype/toZonedDateTimeISO/timezone-string-datetime.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Instant/prototype/toZonedDateTimeISO/timezone-string-leap-second.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Instant/prototype/toZonedDateTimeISO/timezone-string-multiple-offsets.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| f | `test/built-ins/Temporal/Instant/prototype/until/argument-wrong-type.js` | Uncaught { message: Temporal.Instant, object does not convert to a valid ISO string Expected a RangeError but got a TypeError } |
| h | `test/built-ins/Temporal/Instant/prototype/until/instant-string-sub-minute-offset.js` | Uncaught { message: ISO strings cannot have sub-minute offsets in time zone annotations: 2021-08-19T17:30-07:00:01[-07:00:01] Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/Instant/prototype/until/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when largestUnit disallowed Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/Instant/prototype/until/order-of-operations.js` | Uncaught { message: Actual [get other.toString, call other.toString] and expected [get other.toString, call other.toString, get options.largestUnit, get options.largestUnit.toString, call options.larg |
| h | `test/built-ins/Temporal/Instant/prototype/until/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| h | `test/built-ins/Temporal/Now/plainDateISO/timezone-string-datetime.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Now/plainDateISO/timezone-string-leap-second.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Now/plainDateTimeISO/timezone-string-datetime.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Now/plainDateTimeISO/timezone-string-leap-second.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Now/plainTimeISO/timezone-string-datetime.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Now/plainTimeISO/timezone-string-leap-second.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Now/zonedDateTimeISO/timezone-string-datetime.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Now/zonedDateTimeISO/timezone-string-leap-second.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/Now/zonedDateTimeISO/timezone-string-multiple-offsets.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| f | `test/built-ins/Temporal/PlainDate/argument-convert.js` | Uncaught RangeError: year must be an integer |
| f | `test/built-ins/Temporal/PlainDate/get-prototype-from-constructor-throws.js` | Uncaught { message: Expected a Test262Error but got a TypeError } |
| f | `test/built-ins/Temporal/PlainDate/from/observable-get-overflow-argument-primitive.js` | Uncaught { message: Actual [get options.overflow, get options.overflow.toString, call options.overflow.toString] and expected [] should have the same contents. Failing call before options is processed |
| f | `test/built-ins/Temporal/PlainDate/prototype/add/options-read-before-algorithmic-validation.js` | Uncaught { message: overflow reject exception thrown Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainDate/prototype/add/order-of-operations.js` | Uncaught { message: Actual [get fields.days, get fields.days.valueOf, call fields.days.valueOf, get fields.hours, get fields.hours.valueOf, call fields.hours.valueOf, get fields.microseconds, get fiel |
| h | `test/built-ins/Temporal/PlainDate/prototype/since/exact-multiple-of-larger-unit.js` | Uncaught { message: P1M weeks..months ceil: weeks result: Expected SameValue(«1», «0») to be true } |
| h | `test/built-ins/Temporal/PlainDate/prototype/since/largestunit-default.js` | Uncaught RangeError: Invalid largestUnit: auto |
| f | `test/built-ins/Temporal/PlainDate/prototype/since/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when largestUnit disallowed Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainDate/prototype/since/order-of-operations.js` | Uncaught TypeError: Temporal.PlainDate.from requires a string or an object |
| h | `test/built-ins/Temporal/PlainDate/prototype/since/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| f | `test/built-ins/Temporal/PlainDate/prototype/subtract/options-read-before-algorithmic-validation.js` | Uncaught { message: overflow reject exception thrown Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainDate/prototype/subtract/order-of-operations.js` | Uncaught { message: Actual [get fields.days, get fields.days.valueOf, call fields.days.valueOf, get fields.hours, get fields.hours.valueOf, call fields.hours.valueOf, get fields.microseconds, get fiel |
| h | `test/built-ins/Temporal/PlainDate/prototype/toPlainDateTime/argument-string-time-designator-required-for-disambiguation.js` | Uncaught { message: '12-14' is ambiguous and requires T prefix Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/PlainDate/prototype/toZonedDateTime/argument-string-time-designator-required-for-disambiguation.js` | Uncaught { message: '12-14' is ambiguous and requires T prefix Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/PlainDate/prototype/until/exact-multiple-of-larger-unit.js` | Uncaught { message: P1M weeks..months ceil: weeks result: Expected SameValue(«1», «0») to be true } |
| h | `test/built-ins/Temporal/PlainDate/prototype/until/largestunit-default.js` | Uncaught RangeError: Invalid largestUnit: auto |
| f | `test/built-ins/Temporal/PlainDate/prototype/until/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when largestUnit disallowed Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainDate/prototype/until/order-of-operations.js` | Uncaught TypeError: Temporal.PlainDate.from requires a string or an object |
| h | `test/built-ins/Temporal/PlainDate/prototype/until/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| f | `test/built-ins/Temporal/PlainDate/prototype/with/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.overflow, get options.overflow.toString, call options.overflow.toString] should have the same contents. all options should be read first } |
| f | `test/built-ins/Temporal/PlainDate/prototype/with/options-wrong-type.js` | Uncaught { message: Partial date processed before throwing TypeError Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/PlainDate/prototype/with/order-of-operations.js` | Uncaught TypeError: with() requires an object |
| f | `test/built-ins/Temporal/PlainDate/prototype/withCalendar/calendar-temporal-object.js` | Uncaught TypeError: Calendar must be a string |
| f | `test/built-ins/Temporal/PlainDateTime/argument-convert.js` | Uncaught RangeError: year must be an integer |
| f | `test/built-ins/Temporal/PlainDateTime/get-prototype-from-constructor-throws.js` | Uncaught { message: Expected a Test262Error but got a TypeError } |
| h | `test/built-ins/Temporal/PlainDateTime/from/monthcode-invalid.js` | Uncaught { message: Month code syntax is validated before year type is validated Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/PlainDateTime/from/observable-get-overflow-argument-primitive.js` | Uncaught { message: Actual [get options.overflow, get options.overflow.toString, call options.overflow.toString] and expected [] should have the same contents. Failing call before options is processed |
| f | `test/built-ins/Temporal/PlainDateTime/from/order-of-operations.js` | Uncaught TypeError: monthCode must be a string |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/add/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.overflow, get options.overflow.toString, call options.overflow.toString] should have the same contents. all options should be read first } |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/add/order-of-operations.js` | Uncaught { message: Actual [get fields.days, get fields.days.valueOf, call fields.days.valueOf, get fields.hours, get fields.hours.valueOf, call fields.hours.valueOf, get fields.microseconds, get fiel |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/round/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.roundingIncrement, get options.roundingIncrement.valueOf, call options.roundingIncrement.valueOf, get options.roundingMode, get options.rounding |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/round/throws-no-argument.js` | Uncaught { message: throws without any parameters Expected a TypeError but got a RangeError } |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/round/throws-undefined.js` | Uncaught { message: throws without undefined as sole parameter Expected a TypeError but got a RangeError } |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/round/options-wrong-type.js` | Uncaught { message: TypeError on missing options argument Expected a TypeError but got a RangeError } |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/round/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/since/exact-multiple-of-larger-unit.js` | Uncaught { message: P1M weeks..months ceil: weeks result: Expected SameValue(«1», «0») to be true } |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/since/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when smallestUnit > largestUnit Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/since/order-of-operations.js` | Uncaught TypeError: Temporal.PlainDateTime.from requires a string or an object |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/since/returns-days.js` | Uncaught RangeError: Invalid largestUnit: auto |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/since/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/subtract/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.overflow, get options.overflow.toString, call options.overflow.toString] should have the same contents. all options should be read first } |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/subtract/order-of-operations.js` | Uncaught { message: Actual [get fields.days, get fields.days.valueOf, call fields.days.valueOf, get fields.hours, get fields.hours.valueOf, call fields.hours.valueOf, get fields.microseconds, get fiel |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/until/exact-multiple-of-larger-unit.js` | Uncaught { message: P1M weeks..months ceil: weeks result: Expected SameValue(«1», «0») to be true } |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/until/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when smallestUnit > largestUnit Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/until/order-of-operations.js` | Uncaught TypeError: Temporal.PlainDateTime.from requires a string or an object |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/until/returns-days.js` | Uncaught RangeError: Invalid largestUnit: auto |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/with/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.overflow, get options.overflow.toString, call options.overflow.toString] should have the same contents. all options should be read first } |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/with/options-wrong-type.js` | Uncaught { message: Partial datetime processed before throwing TypeError Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/with/order-of-operations.js` | Uncaught TypeError: with() requires an object |
| f | `test/built-ins/Temporal/PlainDateTime/prototype/withCalendar/calendar-temporal-object.js` | Uncaught TypeError: Calendar must be a string |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/until/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| h | `test/built-ins/Temporal/PlainDateTime/prototype/withPlainTime/argument-string-time-designator-required-for-disambiguation.js` | Uncaught { message: '12-14' is ambiguous and requires T prefix Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainMonthDay/argument-convert.js` | Uncaught RangeError: month must be an integer |
| h | `test/built-ins/Temporal/PlainMonthDay/calendar-invalid.js` | Uncaught { message: Actual [get month.valueOf, call month.valueOf, get day.valueOf, call day.valueOf, get year.valueOf, call year.valueOf] and expected [get month.valueOf, call month.valueOf, get day. |
| f | `test/built-ins/Temporal/PlainMonthDay/get-prototype-from-constructor-throws.js` | Uncaught { message: Expected a Test262Error but got a TypeError } |
| h | `test/built-ins/Temporal/PlainMonthDay/from/iso-year-used-only-for-overflow.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| f | `test/built-ins/Temporal/PlainMonthDay/from/observable-get-overflow-argument-primitive.js` | Uncaught { message: Actual [get options.overflow, get options.overflow.toString, call options.overflow.toString] and expected [] should have the same contents. Failing call before options is processed |
| f | `test/built-ins/Temporal/PlainMonthDay/prototype/toPlainDate/order-of-operations.js` | Uncaught TypeError: year is required |
| h | `test/built-ins/Temporal/PlainMonthDay/prototype/with/basic.js` | Uncaught TypeError: Invalid or missing Temporal field |
| h | `test/built-ins/Temporal/PlainMonthDay/prototype/with/iso-year-used-only-for-overflow.js` | Uncaught TypeError: Invalid or missing Temporal field |
| h | `test/built-ins/Temporal/PlainTime/compare/argument-string-time-designator-required-for-disambiguation.js` | Uncaught { message: '12-14' is ambiguous and requires T prefix (first argument) Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainMonthDay/prototype/with/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when month code incorrect for calendar Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/PlainMonthDay/prototype/with/options-wrong-type.js` | Uncaught { message: Partial date processed before throwing TypeError Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/PlainMonthDay/prototype/with/order-of-operations.js` | Uncaught TypeError: with() requires an object |
| f | `test/built-ins/Temporal/PlainTime/argument-convert.js` | Uncaught RangeError: hour must be an integer |
| f | `test/built-ins/Temporal/PlainTime/get-prototype-from-constructor-throws.js` | Uncaught { message: Expected a Test262Error but got a TypeError } |
| h | `test/built-ins/Temporal/PlainTime/from/argument-string-time-designator-required-for-disambiguation.js` | Uncaught { message: '12-14' is ambiguous and requires T prefix Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/PlainTime/prototype/equals/argument-string-time-designator-required-for-disambiguation.js` | Uncaught { message: '12-14' is ambiguous and requires T prefix Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainTime/prototype/round/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.roundingIncrement, get options.roundingIncrement.valueOf, call options.roundingIncrement.valueOf, get options.roundingMode, get options.rounding |
| f | `test/built-ins/Temporal/PlainTime/prototype/round/options-wrong-type.js` | Uncaught { message: TypeError on missing options argument Expected a TypeError but got a RangeError } |
| h | `test/built-ins/Temporal/PlainTime/prototype/round/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| h | `test/built-ins/Temporal/PlainTime/prototype/since/largestunit.js` | Uncaught RangeError: Invalid largestUnit: auto |
| f | `test/built-ins/Temporal/PlainTime/prototype/since/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when largestUnit disallowed Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainTime/prototype/since/order-of-operations.js` | Uncaught TypeError: Temporal.PlainTime.from requires a string or an object |
| h | `test/built-ins/Temporal/PlainTime/prototype/round/smallestunit-missing.js` | Uncaught { message: Expected a TypeError but got a RangeError } |
| h | `test/built-ins/Temporal/PlainTime/prototype/since/argument-string-time-designator-required-for-disambiguation.js` | Uncaught { message: '12-14' is ambiguous and requires T prefix Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/PlainTime/prototype/since/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| h | `test/built-ins/Temporal/PlainTime/prototype/until/argument-string-time-designator-required-for-disambiguation.js` | Uncaught { message: '12-14' is ambiguous and requires T prefix Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/PlainTime/prototype/until/largestunit.js` | Uncaught RangeError: Invalid largestUnit: auto |
| f | `test/built-ins/Temporal/PlainTime/prototype/until/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when largestUnit disallowed Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainTime/prototype/until/order-of-operations.js` | Uncaught TypeError: Temporal.PlainTime.from requires a string or an object |
| f | `test/built-ins/Temporal/PlainTime/prototype/with/options-read-before-algorithmic-validation.js` | Uncaught { message: overflow reject exception thrown Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainTime/prototype/with/options-wrong-type.js` | Uncaught { message: Partial time processed before throwing TypeError Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/PlainTime/prototype/with/order-of-operations.js` | Uncaught TypeError: with() requires an object |
| f | `test/built-ins/Temporal/PlainYearMonth/argument-convert.js` | Uncaught RangeError: year must be an integer |
| h | `test/built-ins/Temporal/PlainYearMonth/calendar-invalid.js` | Uncaught { message: Actual [get year.valueOf, call year.valueOf, get month.valueOf, call month.valueOf, get day.valueOf, call day.valueOf] and expected [get year.valueOf, call year.valueOf, get month. |
| h | `test/built-ins/Temporal/PlainTime/prototype/until/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| f | `test/built-ins/Temporal/PlainYearMonth/get-prototype-from-constructor-throws.js` | Uncaught { message: Expected a Test262Error but got a TypeError } |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/add/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when converting -271821-04 to date Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/add/order-of-operations.js` | Uncaught { message: Actual [get fields.days, get fields.days.valueOf, call fields.days.valueOf, get fields.hours, get fields.hours.valueOf, call fields.hours.valueOf, get fields.microseconds, get fiel |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/add/overflow.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/add/subtract-from-last-representable-month.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/PlainYearMonth/from/monthcode-invalid.js` | Uncaught { message: Month code syntax is validated before year type is validated Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/PlainYearMonth/from/observable-get-overflow-argument-primitive.js` | Uncaught { message: Actual [get options.overflow, get options.overflow.toString, call options.overflow.toString] and expected [] should have the same contents. Failing call before options is processed |
| f | `test/built-ins/Temporal/PlainYearMonth/from/order-of-operations.js` | Uncaught TypeError: monthCode must be a string |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/add/argument-lower-units.js` | Uncaught { message: adding a unit lower than months should throw, no options Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/since/argument-string-limits.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/since/exact-multiple-of-larger-unit.js` | Uncaught { message: P1Y months..years ceil: months result: Expected SameValue(«2», «0») to be true } |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/since/throws-if-year-outside-valid-iso-range.js` | Uncaught { message: minYearMonth.since(epochYearMonth) Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/subtract/argument-lower-units.js` | Uncaught { message: subtracting a unit lower than months should throw, no options Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/since/largestunit-auto.js` | Uncaught RangeError: Invalid largestUnit: auto |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/since/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown largestUnit disallowed Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/since/order-of-operations.js` | Uncaught TypeError: Temporal.PlainYearMonth.from requires a string or an object |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/since/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/subtract/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when converting -271821-04 to date Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/subtract/order-of-operations.js` | Uncaught { message: Actual [get fields.days, get fields.days.valueOf, call fields.days.valueOf, get fields.hours, get fields.hours.valueOf, call fields.hours.valueOf, get fields.microseconds, get fiel |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/subtract/overflow.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/subtract/subtract-from-last-representable-month.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/toPlainDate/order-of-operations.js` | Uncaught TypeError: day is required |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/until/argument-string-limits.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/until/exact-multiple-of-larger-unit.js` | Uncaught { message: P1Y months..years ceil: months result: Expected SameValue(«2», «0») to be true } |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/until/largestunit-auto.js` | Uncaught RangeError: Invalid largestUnit: auto |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/until/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown largestUnit disallowed Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/until/order-of-operations.js` | Uncaught TypeError: Temporal.PlainYearMonth.from requires a string or an object |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/until/roundingincrement-non-integer.js` | Uncaught RangeError: roundingIncrement must be an integer |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/until/throws-if-year-outside-valid-iso-range.js` | Uncaught { message: minYearMonth.until(epochYearMonth) Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/PlainYearMonth/prototype/with/basic.js` | Uncaught TypeError: Invalid or missing Temporal field |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/with/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when month code incorrect for calendar Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/with/options-wrong-type.js` | Uncaught { message: Partial date processed before throwing TypeError Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/PlainYearMonth/prototype/with/order-of-operations.js` | Uncaught TypeError: with() requires an object |
| f | `test/built-ins/Temporal/ZonedDateTime/get-prototype-from-constructor-throws.js` | Uncaught { message: Expected a Test262Error but got a TypeError } |
| h | `test/built-ins/Temporal/ZonedDateTime/compare/argument-propertybag-invalid-offset-string.js` | Uncaught { message: "00:00 is not a valid offset string (second argument) Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/compare/argument-propertybag-offset-not-agreeing-with-timezone.js` | Uncaught { message: offset property not matching time zone is rejected (first argument) Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/compare/argument-string-limits.js` | Uncaught { message: "-271821-04-19T23:00-01:00[-01:00]" is outside the representable range of ZonedDateTime (first argument) Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/compare/argument-string-multiple-time-zone.js` | Uncaught { message: reject more than one time zone annotation: 1970-01-01T00:00[UTC][UTC] (first argument) Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/ZonedDateTime/compare/order-of-operations.js` | Uncaught TypeError: Temporal.ZonedDateTime.from requires a string or an object |
| h | `test/built-ins/Temporal/ZonedDateTime/from/argument-propertybag-invalid-offset-string.js` | Uncaught { message: "00:00 is not a valid offset string (with offset option use) Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/from/argument-propertybag-offset-not-agreeing-with-timezone.js` | Uncaught { message: offset property not matching time zone is rejected Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/from/argument-string-limits.js` | Uncaught { message: wall-clock time of "-271821-04-19T23:00-01:00[-01:00]" is outside the representable range of ZonedDateTime (offset=prefer) Expected a RangeError to be thrown but no exception was t |
| h | `test/built-ins/Temporal/ZonedDateTime/from/argument-string-multiple-time-zone.js` | Uncaught { message: reject more than one time zone annotation: 1970-01-01T00:00[UTC][UTC] Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/from/argument-string-optional-parts.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/ZonedDateTime/from/disambiguation-invalid-string.js` | Uncaught { message: Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/ZonedDateTime/from/disambiguation-wrong-type.js` | Uncaught { message: null Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/ZonedDateTime/from/observable-get-overflow-argument-primitive.js` | Uncaught { message: Actual [] and expected [get options.disambiguation, get options.disambiguation.toString, call options.disambiguation.toString, get options.offset, get options.offset.toString, call |
| h | `test/built-ins/Temporal/ZonedDateTime/from/offset-does-not-match-iana-time-zone.js` | Uncaught { message: Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/from/offset-string-invalid.js` | Uncaught { message: UTC offset 'garbage' is not well-formed Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/from/offset-undefined.js` | Uncaught { message: default offset is reject Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/ZonedDateTime/from/offset-wrong-type.js` | Uncaught { message: null Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/ZonedDateTime/from/options-read-before-algorithmic-validation.js` | Uncaught { message: Actual [] and expected [get options.disambiguation, get options.disambiguation.toString, call options.disambiguation.toString, get options.offset, get options.offset.toString, call |
| f | `test/built-ins/Temporal/ZonedDateTime/from/options-wrong-type.js` | Uncaught { message: Invalid string string processed before throwing TypeError Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/ZonedDateTime/from/order-of-operations.js` | Uncaught TypeError: Temporal.ZonedDateTime.from requires a string or an object |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/equals/argument-propertybag-invalid-offset-string.js` | Uncaught { message: "00:00 is not a valid offset string Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/equals/argument-propertybag-offset-not-agreeing-with-timezone.js` | Uncaught { message: offset property not matching time zone is rejected Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/equals/argument-propertybag-timezone-case-insensitive.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/equals/argument-propertybag-timezone-normalize-offset-strings.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/equals/argument-string-limits.js` | Uncaught { message: "-271821-04-19T23:00-01:00[-01:00]" is outside the representable range of ZonedDateTime Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/equals/argument-string-multiple-time-zone.js` | Uncaught { message: reject more than one time zone annotation: 1970-01-01T00:00[UTC][UTC] Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/equals/order-of-operations.js` | Uncaught TypeError: Temporal.ZonedDateTime.from requires a string or an object |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/getTimeZoneTransition/direction-undefined.js` | Uncaught { message: Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/getTimeZoneTransition/direction-wrong-type.js` | Uncaught { message: Non-Symbol throws a RangeError Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/getTimeZoneTransition/order-of-operations.js` | Uncaught TypeError: direction must be a string |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/getTimeZoneTransition/wrong-string.js` | Uncaught { message: Expected a RangeError but got a TypeError } |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/hoursInDay/get-start-of-day-throws.js` | Uncaught { message: Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/hoursInDay/next-day-out-of-range.js` | Uncaught { message: Next day boundary is out of range Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/round/roundingincrement-wrong-type.js` | Uncaught { message: bigint Expected a TypeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/since/argument-at-limits.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/since/argument-string-limits.js` | Uncaught { message: "-271821-04-19T23:00-01:00[-01:00]" is outside the representable range of ZonedDateTime Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/since/argument-string-multiple-time-zone.js` | Uncaught { message: reject more than one time zone annotation: 1970-01-01T00:00[UTC][UTC] Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/since/calendar-temporal-object.js` | Uncaught TypeError: Temporal calendar must be a string |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/since/exact-multiple-of-larger-unit.js` | Uncaught { message: P7D days..weeks ceil: days result: Expected SameValue(«1», «0») to be true } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/since/order-of-operations.js` | Uncaught TypeError: Temporal offset must be a string |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/since/roundingincrement-wrong-type.js` | Uncaught { message: bigint Expected a TypeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/until/argument-at-limits.js` | Uncaught RangeError: Invalid or out-of-range Temporal value |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/until/argument-string-limits.js` | Uncaught { message: "-271821-04-19T23:00-01:00[-01:00]" is outside the representable range of ZonedDateTime Expected a RangeError to be thrown but no exception was thrown at all } |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/until/argument-string-multiple-time-zone.js` | Uncaught { message: reject more than one time zone annotation: 1970-01-01T00:00[UTC][UTC] Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/until/calendar-temporal-object.js` | Uncaught TypeError: Temporal calendar must be a string |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/until/exact-multiple-of-larger-unit.js` | Uncaught { message: P7D days..weeks ceil: days result: Expected SameValue(«1», «0») to be true } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/until/order-of-operations.js` | Uncaught TypeError: Temporal offset must be a string |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/with/basic.js` | Uncaught TypeError: Invalid or missing Temporal field |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/with/constrain-day.js` | Uncaught TypeError: Invalid or missing Temporal field |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/with/options-read-before-algorithmic-validation.js` | Uncaught { message: exception thrown when month code incorrect for calendar Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/with/options-wrong-type.js` | Uncaught { message: Partial datetime processed before throwing TypeError Expected a RangeError but got a TypeError } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/with/order-of-operations.js` | Uncaught TypeError: Temporal offset must be a string |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/withCalendar/calendar-temporal-object.js` | Uncaught TypeError: Calendar must be a string |
| h | `test/built-ins/Temporal/ZonedDateTime/prototype/withPlainTime/argument-string-time-designator-required-for-disambiguation.js` | Uncaught { message: '12-14' is ambiguous and requires T prefix Expected a RangeError to be thrown but no exception was thrown at all } |
| f | `test/built-ins/Temporal/ZonedDateTime/prototype/until/roundingincrement-wrong-type.js` | Uncaught { message: bigint Expected a TypeError to be thrown but no exception was thrown at all } |

