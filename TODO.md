# TODO

- **iterableItems: return owned references.** Fixes the Set.delete/Set.clear
  migration (to z-value's `setDelete`/`setClear`, blocked today because
  releasing what they remove would leave iterableItems' borrowed list
  dangling) and the existing array use-after-free (`a.pop()` during
  `Array.from`).
