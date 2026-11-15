# Bytecode VM Residual — Closures & ScopeAnalyzer Redesign

- **Fecha:** 2026-11-15
- **SHA del intento (descartado):** `7e5dd55`
- **SHA baseline / master:** `93123e8` (v0.3.8)

---

## Closures — resolución incorrecta de ScopeAnalyzer

### Síntoma
- `closure_bench.js` degradó severamente de **0.16s** a **37.66s** (+23,400% de regresión).
- Aumento drástico a más de 33,000,000 minor page faults durante la ejecución del benchmark.

### Causa raíz
- `ScopeAnalyzer` clasifica identificadores globales de script como capturas cuando aparecen como identificadores libres dentro de funciones anidadas.
- En `closure_bench.js`, la función `run()` emite la instrucción `load_capture r3, @0` para resolver `makeCounter` en lugar de emitir `load_global`.

### Consecuencia
- En runtime, `load_capture @0` extrae un valor incorrecto del `Environment` (específicamente el valor numérico del contador en lugar del objeto función invocable).
- La invocación `call` falla en tiempo de ejecución, provocando que el mecanismo de fallback re-ejecute la función completa en el tree-walker por cada iteración del bucle caliente.

### Por qué el gate no lo detectó
- Los 826 tests locales del motor no ejercen el patrón de interacción específico de "función hermana llamando a otra función a nivel de script que devuelve un closure".

### Diseño requerido
- `ScopeAnalyzer` debe distinguir formalmente tres categorías de resolución de identificadores:
  1. **(a)** Variable local de la función actual $\to$ registro.
  2. **(b)** Captura de una función padre (ámbito léxico intermedio) $\to$ `load_capture` / `store_capture`.
  3. **(c)** Global de script / módulo $\to$ `load_global` / `store_global`.
- Solo la categoría **(b)** debe emitir `load_capture` / `store_capture`.

### Nivel actual
- La implementación descartada solo soportaba 1 nivel de closure scope (`frame.closure_env`). ECMAScript real requiere resolución encadenada de $N$ niveles léxicos.

### Requiere
- Rediseño completo de `ScopeAnalyzer` con cálculo de frontera de captura (*frontier analysis*) o una sesión de trabajo dedicada a scope chaining.
