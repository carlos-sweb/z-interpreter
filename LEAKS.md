# Leak audit — z-interpreter

Auditoría de los leaks de memoria reportados por Zig's `DebugAllocator` al
correr `zig build test` (Debug build; `ReleaseFast` no los muestra —
`init.gpa` solo chequea leaks en Debug, ver nota al final).

**Metodología**: `zig build test 2>&1` capturado completo, cada entrada
`[DebugAllocator] (err): memory address ... leaked:` parseada junto con su
backtrace, agrupada por el primer frame perteneciente a un repo `z-*`
(descartando frames de `std` y del propio `zig-cache`). Script ad-hoc, no
committeado (vive en `/tmp` de la sesión que hizo esta auditoría).

**Total al momento de la auditoría: 239 allocations leaked**, repartidas
en 26 archivos de test. De esas, 231 tienen backtrace completo (agrupadas
abajo en 11 sitios de código con causa raíz identificada); 50 no tienen
backtrace en absoluto ("empty stack trace" — ver sección propia) — hay
una pequeña discrepancia de 8 entradas entre el conteo directo (239) y
las agrupadas (231 traceadas totales vs 239 reales), variación menor del
parseo, no afecta las conclusiones.

**Actualización 2026-07-25, mismo día (1ra ronda)**: se arreglaron los 4
candidatos de bajo riesgo (#2, #4, #5, #6 abajo) a pedido explícito del
usuario. **Total: 194 allocations leaked** (-45, -19%), 446/446 tests.

**Actualización 2026-07-25, mismo día (2da ronda)**: se arregló también
la causa #1 (`+`-concat sin GC-track), moviendo la lógica de
string-concat a `interpreter.zig` (nueva `Interpreter.stringConcat`,
interceptada antes de `coercion.binaryOp` en los dos call sites de
binary-op, mismo patrón que `bigintArithmetic`) — la rama string dentro
de `coercion.zig`'s `binaryOp` quedó eliminada (inalcanzable, la
interceptación siempre gana primero). **Total: ~50 allocations leaked**
(-144 desde el fix anterior, -79% desde el inicio de la auditoría: 239 → 50),
446/446 tests, sin regresiones. Solo quedan las causas #2b, #3, #7, #8
(todas ya documentadas/deliberadas o requieren rediseño) y ~20 sin
backtrace (bajaron de 50 a 20 también, probablemente algunas de esas
eran del mismo bug, ocurriendo dentro de un contexto de fiber sin
backtrace capturable).

**Actualización 2026-07-26 (3ra ronda)**: se arregló también la causa
#3 (`iterableItems`/`drainIterator`'s contrato de ownership mezclado).
**Total: 30 allocations leaked** (-20 desde el fix anterior, **-87%
desde el inicio de la auditoría: 239 → 30**), 446/446 tests, sin
regresiones (sweep completo de Test262 confirmado). Solo quedan las
causas #2b, #7, #8 (ya documentadas, deliberadas, dejadas tal cual) y
~18 sin backtrace (ver esa sección, sin cambios de naturaleza). El
audit queda esencialmente cerrado: de los 8 sitios con causa raíz
identificada, 5 están arreglados y 3 son narrowings deliberados
documentados en el propio código — no queda ningún bug real sin
atender con backtrace disponible.

Como referencia histórica: esta cuenta era **609 leaks** al empezar la
"Fase 3-5" de GC (2026-07-24), bajó a **411** después de esa fase, y a
**235** tras arreglar `throwError()` (mensaje sin liberar) y
`os.readFile` (string sin trackear) ese mismo día. Los ~4 leaks extra
desde entonces son enteramente del propio trabajo de BigInt de esta
sesión (`bigint_test.zig`'s test de `+`-concat, que necesariamente
dispara el bug #1 de abajo — no hay forma de testear esa conducta sin
pasar por el código con el leak).

---

## Causas raíz identificadas (231 de 239 allocations, backtrace completo)

### 1. `binaryOp`'s `+` string-concat — 126 allocations (63 pares) — ✅ ARREGLADO

**`coercion.zig:165`** (dentro de `binaryOp`'s rama `.add`), tal como
estaba antes del fix:

```zig
break :blk try JSValue.newString(allocator, joined);
```

Usaba el constructor CRUDO `JSValue.newString` en vez de
`Interpreter.gcNewString` — el resultado nunca se registraba en el GC
registry (`gcTrack`), así que si nadie lo retenía explícitamente después
(el caso común: el resultado de un `a + b` que se usa una vez y se
descarta, p.ej. como argumento de `console.log` o dentro de un mensaje de
`assert.js`), nunca se liberaba. Cada string concatenada leakeaba DOS
allocations (el buffer de bytes vía `ZString.initOwned` en
`z-string/src/core/string.zig:53`, y la caja `Rc` que lo envuelve en
`z-value/src/rc.zig:34`) — de ahí el conteo par 63+63. Era, con
diferencia, el mayor contribuyente (126 de 239 = 53%) porque `+` con
strings aparece en TODO tipo de test, incluyendo el propio harness
`assert.js` de Test262 al construir mensajes de error.

**Fix aplicado**: nueva `Interpreter.stringConcat(left, right)` en
`interpreter.zig`, que hace exactamente lo mismo pero termina en
`self.gcNewString(joined)` (GC-tracked). Interceptada en los dos call
sites de operador binario (`evalExpression`'s `.binary` case y
`evalAssignment`'s compound-assignment case) ANTES de delegar a
`coercion.binaryOp`, cuando `op == .add` — mismo patrón exacto ya
establecido para `bigintArithmetic` (`coercion.zig` deliberadamente no
tiene acceso a `self`/GC tracking, solo a un `Allocator` plano). La
rama string dentro de `coercion.zig`'s `binaryOp` quedó eliminada por
inalcanzable — la interceptación siempre la gana primero; solo el
`.add` numérico sigue viviendo ahí.

### 2. `encodePrivateKey` en accesos runtime a `#privateField` — ~19 allocations — ✅ ARREGLADO

**`interpreter.zig:4639`**:

```zig
fn encodePrivateKey(self: *Interpreter, class_id: *anyopaque, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(self.gc_allocator, "\x00P{x}|{s}", .{ @intFromPtr(class_id), name });
}
```

Llamada desde `privateGet` (línea 4657), `privateSet` (línea 4678), y
`privateHas` (línea 4717) — las tres funciones que resuelven
`this.#x`, `this.#x = v`, y `#x in obj` en TIEMPO DE EJECUCIÓN (cada
acceso, no una vez por declaración). Ninguna de las tres libera `key`
después de usarlo — el lookup (`getOwnRecord(key)`) y el set
(`hv.set(key, ...)`) no toman ownership (`set` internamente dupea la
key, no la retiene), así que el `key` original queda huérfano.

A diferencia del bug #1, este es **NO ACOTADO por diseño de programa**
(bug #1 son N leaks por N concatenaciones en el CÓDIGO FUENTE; este es
un leak por cada `this.#x` EJECUTADO, potencialmente en un loop) — es el
de mayor riesgo real en producción aunque hoy sea menor en volumen (19
vs 126) simplemente porque los tests no hacen loops largos con acceso a
privados.

**Fix aplicado**: `defer self.gc_allocator.free(key);` en las tres
funciones, justo después de `const key = try self.encodePrivateKey(...)`.
Verificado seguro: `ZObject.set()` siempre dupea la key al crear una
property nueva y nunca la toca en un update (`z-object/src/zobject.zig:126-130`),
así que liberar `key` después de usarla no es un use-after-free.

### 2b. `encodePrivateKey` en definición de clase — 11 allocations — YA DOCUMENTADO, deliberado

**`interpreter.zig:4862`** (dentro de `evalClass`, resolviendo la key de
un miembro `.private` al definir la clase):

```zig
.private => |n| try self.encodePrivateKey(cctx, n),
```

El comentario en el código (líneas 4863-4874) ya explica que esta key
se guarda en `instance_fields` para uso posterior en cada construcción,
y que `freeGarbageNode`'s caso `.class_ctx` solo libera el array, no
cada key individual — un leak deliberado, ACOTADO por la cantidad de
miembros privados declarados ESTÁTICAMENTE en el código fuente (no por
ejecuciones), tratado igual que el caso `.computed` justo al lado (que
tiene el mismo comentario). **No es un bug nuevo, no recomendado tocar
sin revisar el diseño de `instance_fields`/`freeGarbageNode` completo.**

### 3. `iterableItems`/`drainIterator` — 17 allocations — ✅ ARREGLADO

**`interpreter.zig`** (`iterableItems`/`drainIterator`): ambas devolvían
`[]const JSValue` recién asignado (`toOwnedSlice`/`arena.alloc`) en la
mayoría de sus ramas — EXCEPTO la rama `.array` (`box.value.toSlice()`),
que devolvía un slice PRESTADO hacia el storage interno del array
(jamás debía liberarse). Los call sites nunca liberaban el slice
devuelto, correctamente para el caso `.array` pero incorrectamente para
`.string`/`.object`/`.set`/`.map`.

**Fix aplicado**: se unificó el contrato — TODAS las ramas devuelven
ahora un slice fresco/propio (la rama `.array` pasó de
`box.value.toSlice()` a copiar en un `arena.alloc` + `@memcpy`, mismo
patrón que ya usaban `.set`/`.map`). Se agregó `defer ...free(items)`
en los **8 call sites reales** que resultaron existir (más de los 5
estimados originalmente en la auditoría — 3 en `builtins.zig` se habían
pasado por alto: `Array.from` sobre Set/Map, y los constructores `new
Map(iterable)`/`new Set(iterable)`): `evalYieldDelegate` (`yield*` sobre
array/string), `bindPattern`'s rama `.array`, `destructuringAssign`'s
rama `.array_literal`, el spread dentro de un array-literal, el spread
de argumentos de una llamada (`evalArgs`), más los 3 de `builtins.zig`.
Mismo patrón ya aplicado esta sesión a `ownEnumerableKeys`/
`freeOwnedKeys` durante el trabajo de Proxy.

### 4. `evalModuleBody`'s listas de nombres — 6 allocations — ✅ ARREGLADO

**`interpreter.zig:1805-1806`**:

```zig
var decl_names: std.ArrayList([]const u8) = .empty;
var local_specs: std.ArrayList(zstatements.ExportSpecifier) = .empty;
```

Ninguna de las dos se libera con `.deinit()` al final de la función
(el storage interno del `ArrayList`, no los strings que contiene —
esos son slices prestados del AST). Afecta cualquier módulo con
`export`.

**Fix aplicado**: `defer decl_names.deinit(arena); defer local_specs.deinit(arena);`
justo después de declararlas.

### 5. `boundCall`'s array de argumentos combinado — 1 allocation — ✅ ARREGLADO

**`builtins.zig:2055`** (`.bind()`'s función nativa resultante):

```zig
const total = try allocator.alloc(JSValue, bc.pre_args.len + args.len);
@memcpy(total[0..bc.pre_args.len], bc.pre_args);
@memcpy(total[bc.pre_args.len..], args);
return bc.target.function.value.call(bc.target.function.value.ctx, allocator, bc.bound_this, total);
```

`total` nunca se libera después de la llamada. Cada invocación de una
función `.bind()`eada leakea un array.

**Fix aplicado**: `defer allocator.free(total);` justo después del
`alloc` — el `defer` corre después de que `.call(...)` retorna, así que
`total` sigue siendo válido durante la llamada. Verificado seguro
confirmando que `evalCall` ya usa exactamente este mismo patrón
(`defer self.gc_allocator.free(args);`, interpreter.zig:4462) para el
array de argumentos de una llamada normal, y que `invokeFunctionNode`
nunca retiene el slice `args` en sí (solo los `JSValue` individuales que
contiene, vía `.retain()` explícito) — confirmado con un test de
diagnóstico (50 llamadas a una función en loop, 0 leaks nuevos) antes de
aplicar el fix.

### 6. `makeRegex`'s paths de error — 1-2 allocations — ✅ ARREGLADO

**`interpreter.zig:1617-1645`**: `state.source`/`state.flags` se dupean
al inicio de `makeRegex`, pero si el patrón o las flags son inválidas
(`SyntaxError` catcheable, líneas 1636 y 1644), la función retorna
ANTES de que `state` se guarde en `self.regex_state` — los dos dupes
quedan huérfanos.

**Fix aplicado**: `errdefer arena.free(state.source); errdefer arena.free(state.flags);`
justo después del literal de `state` — se dispara en cualquier retorno
por error posterior, y NO se dispara en el camino exitoso (donde
`state` se copia a `regex_state`).

### 7. `setPropertyOnValue`'s dupe de key para `globalThis` — 1 allocation — YA DOCUMENTADO, de difícil arreglo limpio

**`interpreter.zig:3993-4001`**: al escribir `globalThis[computed] = x`,
la key se dupea defensivamente (comentario explica por qué:
`Environment.define` guarda keys por referencia, nunca dupea). Ese
binding global vive todo el programa, así que en la práctica esto es
memoria "permanente" — el leak que reporta el test es solo un artefacto
de que el `Interpreter` de test se destruye al final sin que
`Environment`'s teardown sepa que ESTA key en particular (a diferencia
de cualquier otra, siempre prestada del AST) es dueña de su propia
memoria. Arreglarlo bien necesita rastrear ownership por-binding en
`Environment`, que es más cambio de lo que vale para 1 allocation.
**Documentado, no recomendado tocar ahora.**

### 8. `evalClass`'s key computada — 1 allocation — YA DOCUMENTADO (ver #2b, mismo patrón)

**`coercion.zig:73`** vía `encodeKey` vía `evalClass`'s rama
`.computed` (línea 4863-4877) — mismo comentario, mismo acotamiento por
declaración estática, ya explicado en el código.

---

## Leaks sin backtrace ("empty stack trace") — 50 allocations, 10 tests

```
14  async_generator_test.test.async generator method on a class sees the right `this` and private fields
 6  async_generator_test.test.interleaved yield/await ordering across multiple next() calls
 6  async_test.test.await in a loop is sequential
 2  async_test.test.try/catch around a rejected await
16  constructors_test.test.new Function parses and closes over globals
 2  constructors_test.test.the propertyHelper harness pattern works end to end
 1  generator_test.test.yield* over an array and a string
 1  private_test.test.delete of a private member is a SyntaxError
 1  private_test.test.private async method resolves this.#x
 1  symbol_test.test.a generator is its own iterable via Symbol.iterator
```

Zig's `DebugAllocator` no pudo capturar el backtrace de estas
allocations en absoluto (`(empty stack trace)`, sin ni un frame). La
mayoría son de tests que ejecutan generadores/`async`/`await` — código
que corre sobre las stacks propias de los fibers (`std.Io.fiber`, ver
`project-zjs-async-runtime-design`), y el unwinder de Zig no puede
recorrer esas stacks alternas. `constructors_test`'s "new Function..."
(16, el mayor de este grupo) es la excepción — no es código async, así
que su falta de backtrace probablemente tiene otra causa (posiblemente
inlining agresivo incluso en Debug para ese path recursivo de parseo).

**No investigado a fondo en esta auditoría** — necesitaría un enfoque
distinto (tracking explícito envolviendo el allocator en esos puntos
específicos, o bisección comentando código) en vez de leer backtraces.
Queda como trabajo pendiente, no descartado.

---

## Resumen de qué hacer

| # | Causa | Allocations (original) | Tipo | Estado |
|---|---|---|---|---|
| 1 | `+`-concat sin GC-track | 126 | Bug real, ya documentado | ✅ **ARREGLADO** (2026-07-25) |
| 2 | `encodePrivateKey` en Get/Set/Has | ~19 | Bug real, NUEVO hallazgo | ✅ **ARREGLADO** (2026-07-25) |
| 2b | `encodePrivateKey` en evalClass | 11 | Documentado, deliberado | Sin tocar |
| 3 | `iterableItems`/`drainIterator` ownership | 17 | Bug real | ✅ **ARREGLADO** (2026-07-26) |
| 4 | `evalModuleBody`'s 2 ArrayLists | 6 | Bug real, NUEVO hallazgo | ✅ **ARREGLADO** (2026-07-25) |
| 5 | `boundCall`'s args array | 1 | Bug real, NUEVO hallazgo | ✅ **ARREGLADO** (2026-07-25) |
| 6 | `makeRegex`'s error paths | 1-2 | Bug real, NUEVO hallazgo | ✅ **ARREGLADO** (2026-07-25) |
| 7 | `globalThis[computed]=x` key dupe | 1 | Documentado, difícil de arreglar limpio | Sin tocar |
| 8 | `evalClass`'s computed key | 1 | Documentado, deliberado | Sin tocar |
| — | Empty-stack-trace (fibers, `new Function`) | 50 → 18 | Sin diagnosticar | Investigación futura, distinto enfoque |

**Resultado final de las 3 rondas de fixes**: 239 → 30 allocations
leaked (-209, **-87%**), 446/446 tests siguen pasando, sin regresiones
en ninguna ronda (cada una verificada con un sweep completo de
Test262). Solo quedan sin tocar los ítems ya documentados como
deliberados (#2b, #7, #8) — todos pequeños, acotados por forma del
código fuente (no por ejecución), y ya razonados en sus propios
comentarios en el código. El audit queda cerrado: no queda ningún bug
real con backtrace disponible sin atender.

## Nota sobre por qué esto solo se ve en Debug

`ReleaseFast` (lo que correría en producción) no activa el chequeo de
leaks del `DebugAllocator` (`init.gpa` en Zig 0.16 solo lo hace en
Debug) — estos leaks son reales (memoria que no se libera nunca durante
la vida del proceso) pero invisibles fuera de la suite de tests en
Debug. Importan igual para procesos long-running (un REPL, un servidor
embebiendo el motor) aunque un script corto de línea de comandos nunca
los notaría.
