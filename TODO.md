# TODO

- **Separate z-temporal Duration.toString work (duration.zig:461).** Rounding
  can produce 60 seconds without carrying into minutes, and the rounded
  duration is formatted without revalidation. This affects three Test262
  cases from Temporal block B1.

- **iterableItems: return owned references.** Fixes the Set.delete/Set.clear
  migration (to z-value's `setDelete`/`setClear`, blocked today because
  releasing what they remove would leave iterableItems' borrowed list
  dangling) and the existing array use-after-free (`a.pop()` during
  `Array.from`).

- **Bloque B del precheck de yield/await: fugas de yielded, completion,
  on_f/on_r y promesas de await.** Toca el camino de promesas (reacciones,
  trabajos pendientes, derived). Precheck propio.

- **yield\* sobre arrays mutados: use-after-free conocido.** Va con
  iterableItems.
