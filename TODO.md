# TODO

- **iterableItems: return owned references.** Fixes the Set.delete/Set.clear
  migration (to z-value's `setDelete`/`setClear`, blocked today because
  releasing what they remove would leave iterableItems' borrowed list
  dangling) and the existing array use-after-free (`a.pop()` during
  `Array.from`).

- **array_props y primitive_wrapper_data se marcan como raíces del GC**, no
  como aristas de su caja dueña. Un array cuyo ciclo pasa por su propia
  bolsa (`r.self = r`) nunca lo recoge el colector. Arreglo: cambiar el
  marcado para que esas entradas cuelguen de su caja, como `proto_refs`.
  Toca el marcador del GC. Encontrado en D0 (b56769a).

- **Bloque B del precheck de yield/await: fugas de yielded, completion,
  on_f/on_r y promesas de await.** Toca el camino de promesas (reacciones,
  trabajos pendientes, derived). Precheck propio.

- **yield\* sobre arrays mutados: use-after-free conocido.** Va con
  iterableItems.
