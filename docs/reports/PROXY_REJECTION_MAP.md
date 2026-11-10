# Temporal adapter: map of Proxy and non-primitive-object rejection

**Scope.** Static read of `src/temporal_builtins.zig` at `422089b` on
`master`, plus filename/content search in the local Test262 checkout.  No source
or test was changed and no suite was run.

## Method and terminology

The inventory contains the **32 literal guard sites** whose source contains
`!= .object`, `== .object`, or `Interpreter.isPrimitiveTag(...)`.  `JSValue`
has separate tags for ordinary objects, Proxy, arrays, functions, maps, sets,
dates, errors, and other exotic objects.  In ECMAScript, a Proxy and those
exotic values are all Objects.  Therefore a Temporal abstract operation that
requires an Object/property bag must not use `.object` as its full object
predicate.

* **A — bug:** the site rejects a Proxy or another ECMAScript object which the
  relevant Temporal abstract operation accepts, or silently skips its fields.
* **B — correct:** it either accepts all non-primitives or explicitly includes
  Proxy, as required by the route.
* **C — undecided:** it is dead/structural or needs a prototype experiment;
  changing it as part of property-bag coercion would be unsafe.

“Candidate tests” means nearby Test262 tests identified by path/name and source
inspection; it is not a claim that each one currently fails or directly creates
a Proxy.  The installed suite has only eight literal `Proxy` references under
`test/built-ins/Temporal`, all in `toJSON` tests, so filenames alone cannot
provide an exact Proxy-test count.

The relevant normative rule is repeated throughout Temporal: abstract
operations such as `GetOptionsObject`, `PrepareTemporalFields`,
`ToTemporal*` property-bag branches, and `ToTemporalPartialDurationRecord`
operate on an ECMAScript **Object**.  Useful entry points are the
[Temporal specification](https://tc39.es/proposal-temporal/),
[ToTemporalPartialDurationRecord](https://tc39.es/proposal-temporal/#sec-totemporalpartialdurationrecord),
[Temporal.PlainMonthDay.from](https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.from),
and [Temporal.ZonedDateTime.from](https://tc39.es/proposal-temporal/#sec-temporal.zoneddatetime.from).

## Complete inventory

| Line | Check / effective route | Spec treatment | Proxy today | Cluster | Candidate tests |
|---:|---|---|---|---|---|
| 75 | `constructedTemporal`: `newTarget.prototype` | `GetPrototypeFromConstructor` accepts any Object, including Proxy | Proxy falls back to intrinsic prototype | C | `*/get-prototype-from-constructor-throws.js`; structural subclass tests |
| 123 | `optionalI32`, used by ordinary-object Plain*/ZDT property bags | fields are obtained with `Get` from Object | only ordinary object reaches this helper | A | `*/from/argument-propertybag-*`, `*/observable-get-*` |
| 130 | `optionalTemporalString` / `optionalBagMonthCode` | same Object/`Get` rule | only ordinary object reaches it | A | `Plain{Date,DateTime,YearMonth,MonthDay}/from/month-code-wrong-type.js` |
| 210 | `optionalDurationNumber` in ordinary-object Duration-like coercion | duration-like is Object; fields use `Get` | Proxy has a separate path; other exotic objects rejected | A | `Duration/{from,compare}/argument-propertybag-optional-properties.js` |
| 229 | `readOverflow` generic options helper | `GetOptionsObject` accepts Proxy and reads `overflow` | Proxy is accepted earlier but its property is silently ignored | A | `*/from/observable-get-overflow-*`, `*/**/overflow-wrong-type.js` |
| 278 | `readDisambiguation` generic options helper | options may be any Object | Proxy property silently ignored | A | `ZonedDateTime/from/disambiguation-wrong-type.js`, `PlainDateTime/prototype/toZonedDateTime/*` |
| 295 | `readOffsetOption` generic options helper | options may be any Object | Proxy property silently ignored | A | `ZonedDateTime/from/offset-wrong-type.js`, `ZonedDateTime/prototype/with/offset-wrong-type.js` |
| 351 | `readRoundingOptionsGeneric` | options may be any Object; each requested property is `Get` | Proxy receives defaults rather than reads | A | `*/prototype/{round,since,until}/*-wrong-type.js`, order tests |
| 487 | `coerceDuration` (`from`, `add`, `subtract`, and other duration-like callers) | accepts a duration-like Object | Proxy has an observed path; arrays/functions/dates/etc. are rejected by `.object` guard | A | `Duration/from/argument-propertybag-optional-properties.js`; `Duration/prototype/{add,subtract}/*propertybag*` |
| 520 | `coercePlainDate` (from/compare/equals/since/until) | property-bag branch accepts Object | Proxy has a dedicated path; other exotic objects rejected | A | `PlainDate/{from,compare}/argument-propertybag-*`, `PlainDate/*/argument-convert.js` |
| 556 | `coercePlainTime` (from/compare/equals/since/until) | property-bag branch accepts Object | Proxy has a dedicated path; other exotic objects rejected | A | `PlainTime/from/argument-wrong-type.js`, `PlainTime/prototype/*/argument-wrong-type.js` |
| 580 | `coercePlainDateTime` (from/compare/equals/since/until) | property-bag branch accepts Object | Proxy has a dedicated path; other exotic objects rejected | A | `PlainDateTime/{from,compare}/argument-propertybag-*` |
| 617 | `coerceInstant` (from/compare/equals/since/until) | non-Temporal objects go through `ToString`/`ToPrimitive` | Proxy is rejected before coercion | A | `Instant/from/argument-wrong-type.js`; `Instant/{compare,prototype/equals,prototype/since,prototype/until}/argument-wrong-type.js` |
| 636 | `coercePlainYearMonth` (from/compare/equals/since/until) | property-bag branch accepts Object | Proxy has a dedicated path; other exotic objects rejected | A | `PlainYearMonth/{from,compare}/argument-propertybag-*` |
| 653 | `coercePlainMonthDay` (from/equals) | property-bag branch accepts Object | Proxy and other exotic objects are rejected | A | 9 named `PlainMonthDay/from/{argument-propertybag-*,observable-get-*}` candidates |
| 846 | `PlainDate.prototype.with` | partial bag must be Object | explicitly accepts ordinary object and Proxy | B | `PlainDate/prototype/with/*` |
| 981 | `PlainTime.from` | property bag accepts Object | explicitly accepts ordinary object and Proxy | B | `PlainTime/from/*` |
| 1045 | `PlainTime.prototype.with` | partial bag must be Object | explicitly accepts ordinary object and Proxy | B | `PlainTime/prototype/with/*` |
| 1221 | `PlainDateTime.from` | property bag accepts Object | explicitly accepts ordinary object and Proxy | B | `PlainDateTime/from/*` |
| 1332 | `PlainDateTime.prototype.with` | partial bag must be Object | explicitly accepts ordinary object and Proxy | B | `PlainDateTime/prototype/with/*` |
| 1711 | `Duration.from` | duration-like accepts Object | explicitly accepts ordinary object and Proxy | B | `Duration/from/get-property-throws.js` |
| 1748 | `readDurationCompareOptions` / `relativeTo` | property bag accepts Object | explicitly accepts ordinary object and Proxy | B | `Duration/compare/relativeto-propertybag-*` |
| 1823 | `Duration.prototype.with` | partial duration must be Object | `isPrimitiveTag` admits every object tag | B | `Duration/prototype/with/order-of-operations.js` |
| 1880 | `readRelativeTo`: outer `options` | options should be Object | Proxy would be treated as absent | C | no current caller found by static search; do not change as part of a live-route fix |
| 1899 | `readRelativeTo`: `relativeTo` bag | property bag should be Object | a Proxy bag misses the `timeZone` branch | C | same dead helper; `Duration/*/relativeto-propertybag-*` if revived |
| 2145 | `PlainYearMonth.from` | property bag accepts Object | explicitly accepts ordinary object and Proxy | B | `PlainYearMonth/from/*` |
| 2222 | `PlainYearMonth.prototype.with` | partial bag must be Object | explicitly accepts ordinary object and Proxy | B | `PlainYearMonth/prototype/with/*` |
| 2400 | `PlainMonthDay.from` entry point | property bag accepts Object | entry accepts Proxy; legacy coercer still rejects it on the non-observed fallback | B | `PlainMonthDay/from/*` |
| 2443 | `PlainMonthDay.prototype.with` | partial bag must be Object | explicitly accepts ordinary object and Proxy | B | `PlainMonthDay/prototype/with/*` |
| 2533 | `coerceZonedDateTime` (`from`, `compare`, `equals`, `since`, `until`) | property-bag branch accepts Object | Proxy and other exotic objects rejected | A | 26 named `ZonedDateTime/from/argument-propertybag-*` candidates; 17 under `compare/` |
| 3010 | `surfaceObject` used by surface API options/fields | requires Object | `isPrimitiveTag` correctly admits Proxy and every object tag | B | all `surface*` callers |
| 3377 | `PlainDate.prototype.toZonedDateTime` argument branch | object shorthand is allowed | correctly probes every non-primitive, including Proxy | B | `PlainDate/prototype/toZonedDateTime/argument-object-*` |

## Clusters

### Cluster A — real acceptance/observation bugs: 15 sites

1. **Narrow direct-object field helpers** (123, 130, 210): these make a
   `.object` tag stand in for Object.  They are shared plumbing for ordinary
   property-bag paths and cannot be widened blindly: they currently read the
   ordinary object map rather than uniformly doing observable `Get`.
2. **Generic options readers** (229, 278, 295, 351): after `surfaceOptions`
   accepts Proxy, each helper defaults instead of performing `Get`.  This is a
   real semantic error, but has a wide fan-out.  It is also exactly the class of
   shared-helper change that previously caused non-Plain regressions.
3. **Duration/Plain coercers with a special Proxy path** (487, 520, 556, 580,
   636): Proxy itself is admitted, but any other object-tag is rejected.  The
   route is only partially compliant until it uses the same observable field
   path for all Object values.
4. **Immediate rejects**: `coerceInstant` (617), `coercePlainMonthDay` (653),
   and `coerceZonedDateTime` (2533).  The first rejects Proxy before the
   required object-to-string conversion; the latter two reject Proxy property
   bags outright.

### Cluster B — correct guards/admission: 14 sites

The Plain `with`/`from` routes listed above that explicitly include `.proxy`,
`Duration.from`, `Duration.compare`, `Duration.with`, `PlainYearMonth` and
`PlainMonthDay` entry points, `surfaceObject`, and the `toZonedDateTime`
object shorthand already admit the required object classes.  They do not
justify a transversal predicate replacement.

### Cluster C — three sites requiring a separate decision: 3 sites

* **75** is construction/subclass prototype handling, not property-bag
  coercion.  A Proxy prototype should be observable under the specification,
  but changing this needs a prototype-model test.
* **1880 and 1899** are an old `readRelativeTo` helper.  There is no live call
  site in this revision; its replacement helpers are used by current Duration
  routes.  Remove or revive it only with a call-graph decision.

## Recommended implementation order for Cluster A

| Priority | Scope / likely direct candidate files | Estimated named candidates | Risk | Production files | Reason |
|---:|---|---:|---|---|---|
| 1 | `coercePlainMonthDay` (653) | 9 `from` bag/observable names | Low | `src/temporal_builtins.zig` | Local missing Proxy branch; mirror the already-installed observed-bag helper. |
| 2 | `coerceInstant` (617) | 5 argument-coercion paths | Low–medium | `src/temporal_builtins.zig` | Local Object-to-string path; must preserve Symbol/BigInt error behavior. |
| 3 | `coerceZonedDateTime` (2533) | at least 43 named property-bag candidates: 26 `from`, 17 `compare` | Medium | `src/temporal_builtins.zig` | Highest direct return; needs one observed-bag route including `timeZone`, calendar, and field order. Consumers share it. |
| 4 | PlainDate/Time/DateTime/YearMonth and Duration direct-object fallback (487, 520, 556, 580, 636; helpers 123/130/210) | broad; no exact Proxy filename coverage | Medium | `src/temporal_builtins.zig` | Replace tag-specific fallback by the existing observed field readers only after checking ordinary accessor behavior. Split by type to contain regressions. |
| 5 | generic option helpers (229/278/295/351) | 193 `*options*` named files in the checkout, but only a subset reaches each helper | High | `src/temporal_builtins.zig` | Large blast radius and prior Duration regressions. Prefer per-route Proxy-aware readers first, then a separately gated generic refactor. |

For every implementation item, a local guard test belongs in the existing
Temporal order/coercion test file, but no additional production source file is
necessary on the evidence collected here.  The only likely exception is the
construction-prototype item in Cluster C, which may require object-model work
outside `temporal_builtins.zig`.

## Limits of this map

* It measures literal tag guards, not every coercion bug.  A route can accept a
  Proxy and still get its field order or conversion wrong.
* The named-candidate totals come from local Test262 paths; no test was run and
  no sweep result was inferred.
* Exact coverage for Proxy needs focused tests because the local Temporal tree
  has only eight literal `Proxy` references and they are unrelated `toJSON`
  tests.
