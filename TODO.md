# TODO

- **iterableItems: return owned references.** Fixes the Set.delete/Set.clear
  migration (to z-value's `setDelete`/`setClear`, blocked today because
  releasing what they remove would leave iterableItems' borrowed list
  dangling) and the existing array use-after-free (`a.pop()` during
  `Array.from`).

- **Bloque de prototipos: constructValue debe hacer que la instancia retenga
  su prototipo (proto_refs).** Necesario antes del bloque D. Añade una
  entrada por `new`; precheck propio. Desbloquea también liberar el
  `callee` en `evalNew` (hoy su fuga mantiene vivo al constructor; sin
  ella, `g.prototype = {…}; o = new g(); g = null; o.x` lee memoria
  liberada).
