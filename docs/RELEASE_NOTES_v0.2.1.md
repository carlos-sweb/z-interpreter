# Release notes: v0.2.1

## Temporal updates (2026-10-19)

The following master commits improve the Temporal binding without changing its
public API:

- `715c0ca`, `a8dbac7`, `c78bc76`, `a3285d5`, and `72288bd`: preserve a
  Temporal instance's subclass prototype during construction and adopt it only
  through registered Temporal `newTarget` results in `super()`.
- `93077fe`, `16110ff`, `79c5045`, `0c3d43c`, and `ceff40d`: align options,
  duration fields, and rounding-increment coercion with JavaScript conversion
  and error semantics.
- `265e23f` and `f4ef98d`: validate `relativeTo.timeZone` and coerce
  `relativeTo` for `Duration.prototype.round()` and `total()`.

The latest focused Temporal Test262 sweep reports **4,301 PASS / 4,611 (93.3%)**.
No JavaScript API additions, removals, or signature changes are included in this
work.
