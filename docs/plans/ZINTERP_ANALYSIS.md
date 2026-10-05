# Análisis del flujo de z-interpreter

Fecha: 2026-10-05. Commit analizado: `a1cb817` (rama `claude/z-regex-verification-712ffo`).
z-regex en `1690c9f`, sin cambios. Solo lectura: no se tocó `src/`.

**Cómo leer las afirmaciones.** Cada una lleva una de estas tres marcas:

- **[medido]**: hay una ejecución que lo demuestra (test262, sonda JS o tiempo/memoria).
- **[código]**: se ve en el fuente, en el fichero y la línea indicados.
- **[hipótesis]**: es plausible, pero no está verificado.

## 0. Cifras de partida

### test262 completo

- Configuración: `test/built-ins`, `test/language` y `test/annexB`; z-run en ReleaseFast, timeout de 10 s y 4 jobs; runner de z-test262.
- Fichero de resultados: `full.jsonl` en el scratchpad de la sesión.

| | Tests |
|---|---|
| Total | 48.633 |
| Ejecutados | 46.101 |
| **PASS** | **30.392 (65,9%)** |
| FAIL | 15.443 |
| TIMEOUT | 185 |
| CRASH | 81 |
| SKIP (`noStrict`, por diseño) | 2.532 |

El `REPORT.md` anterior de z-test262 marcaba 64,9% sobre 45.639 tests, con 0 CRASH.

| Área | Pasa | % |
|---|---|---|
| language | 17.041 / 22.182 | 76,8% |
| built-ins | 13.250 / 23.623 | 56,1% |
| annexB | 101 / 296 | 34,1% |
| built-ins/RegExp | 1.763 / 1.878 | 93,9% |
| built-ins/String | 1.085 / 1.220 | 88,9% |
| built-ins/Array | 1.789 / 3.046 | 58,7% |
| built-ins/Object | 2.281 / 3.400 | 67,1% |
| built-ins/Promise | 201 / 729 | 27,6% |
| built-ins/Proxy | 83 / 300 | 27,7% |
| built-ins/TypedArray | 476 / 1.445 | 32,9% |
| built-ins/Iterator | 13 / 654 | 2,0% |
| built-ins/Temporal | 2.075 / 4.605 | 45,1% |
| built-ins/Weak{Map,Set,Ref}, FinalizationRegistry | 0 / 302 | 0% |

### Batería de sondas contra Node 22

- 128 casos JS, en `probe/p.js` del scratchpad, cada uno ejecutado aislado.
- **67 de los 119 que se ejecutan difieren de Node.**
- 9 no llegan a ejecutarse: 7 abortan con `NotImplemented`, uno no parsea (`new.target`) y uno no termina (`a[4294967294] = 1`).

## 1. Inventario

### 1.1 Flujo de ejecución

**Entrada del código.** El camino es `run(source)` → parser de z-functions/z-parser → AST → `evalBody` → `runEventLoop` (`interpreter_runtime.zig:177-210`) [código].

- No hay bytecode ni forma intermedia: es un **tree-walker directo sobre el AST**.
- El AST vive en un arena por intérprete y se libera en bloque en `deinit` (`interpreter_runtime.zig:194-198`) [código].
- `eval` y `new Function` vuelven a parsear sobre ese mismo arena, que solo crece (`interpreter_runtime.zig:216-217`) [código].

**Sentencias y expresiones.**

- `evalStatement` y `evalProgram` viven en `interpreter_stmt.zig`; `evalExpression` y su familia, en `interpreter_expr.zig` [código].
- El resultado de las sentencias es un `Completion {type, value, target}`.
- **No existe una compleción "throw"** (`completion.zig:4-16`) [código]. Las excepciones viajan como el error de Zig `error.JsThrow`, más el canal lateral `pending_exception`; `try/finally` mezcla ambos canales.

**Hoisting.** Hay dos pasadas sobre el AST en tiempo de ejecución, en cada entrada de función o `StatementList` (`README.md`): una para `var` y otra para funciones y TDZ [código]. No existe análisis de ámbitos en el parseo.

**Funciones** (`invokeFunctionNode`, `interpreter_class.zig:555-628`) [código]:

- Cada llamada crea un `Environment` con `gcChildEnv`.
- Copia y retiene `this`, `super` y `home_object`.
- **Materializa siempre un array `arguments`** en las funciones que no son flecha.
- Enlaza los parámetros con `bindPattern` y evalúa el cuerpo.
- Las closures capturan su `Environment` de definición mediante un `ClosureCtx`.
- Las variables se resuelven por nombre, con un `StringHashMap` por entorno, recorriendo la cadena de padres (`environment.zig`).
- No hay recursión de cola. Un guardián de pila basado en `@frameAddress` convierte el desbordamiento en `RangeError` (`interpreter_runtime.zig:179`).

**Generadores y async.** Usan fibras con pila propia (`fiber.zig`) sobre `std.Io.fiber`, y el evaluador recursivo corre dentro de la fibra (`README.md`) [código].

**Bucles.** `for`, `while`, `for-in` y `for-of` están en `interpreter_stmt.zig` y `interpreter_binding.zig`. El protocolo de iteración es "duck-typed": basta con que `next` sea invocable (`README.md`) [código].

**Modo estricto.** El motor es **siempre estricto**. Los 2.532 tests `noStrict` se saltan por diseño.

### 1.2 Modelo de objetos y propiedades

`JSValue` está definido en la biblioteca **externa** z-value (`z-value/src/zvalue.zig:65-86`) [código].

- Es una unión con 21 etiquetas: `object`, `array`, `function`, `regex`, `map`, `set`, `error`, `date`, `promise`, `proxy`, `typed_array`, `temporal`, …
- **Solo `.object` lleva una bolsa general de propiedades** (`ZObject`, de z-object), con descriptores, accessors y claves de símbolo codificadas como `\x00S<ptr>`.
- **El resto de etiquetas no tiene bolsa.** Sus propiedades se sintetizan en `getProperty`, con un `switch` por etiqueta en `interpreter_props.zig:27-267`, o viven en tablas laterales del intérprete:

| Tabla lateral | Para | Ciclo de vida |
|---|---|---|
| `Callable.statics` (en z-value) | propiedades de funciones | con la función |
| `array_props` (`interpreter.zig:699`) | propiedades con nombre de arrays | **raíz del GC; nunca se elimina al morir el array** |
| `RegexState.props` (`interpreter.zig`) | propiedades de RegExp (bloque 2) | muere con la regex |
| `primitive_wrapper_data` | `new String/Number/Boolean` | raíz |
| `deleted_fn_props` | `delete f.name/length` | — |
| `regexp_string_iters` | slots del iterador de `matchAll` | muere con el objeto |
| *(ninguna)* | Map, Set, Date, Error, Promise, ArrayBuffer… | — |

**Cadena de prototipos.** Es un puntero crudo (`ZObject.prototype`). `getFromProto` la recorre e invoca los getters con el receptor correcto (`interpreter_props.zig:707-720`) [código]. **El enlace de prototipo no cuenta como referencia ni lo recorre el GC** (`interpreter_gc.zig:579-607`) [código].

**Descriptores.** `definePropertyFromJs` está completo para `.object` (`object_builtins.zig:457-528`). En el resto, cada operación lleva su propio `switch` por etiqueta (`definePropertyOn`, `hasOwnProperty`, `getOwnPropertyDescriptor`, `delete`, `in`, `extensibilityBag`), con cobertura desigual [código].

**¿Se generaliza la bolsa de RegExp?** Sí, como patrón: un campo `props` en el estado por instancia, con el mismo ciclo de vida que el objeto. Pero hoy cada tipo necesitaría:

- su propia tabla de estado (Map, Date, Error y Promise no tienen ninguna);
- los mismos ~9 puntos de integración que tuvo RegExp en el bloque 2.

Es el síntoma, no la cura (§3.1).

**¿Es `array_props` el patrón general?** No. Es la variante más antigua y peor:

- Es raíz del GC y nunca se borra cuando el array muere.
- Va indexada por la dirección de memoria, así que si esa dirección se reutiliza para otro array, el nuevo hereda las propiedades del anterior [código + hipótesis].
- No la consultan `Object.keys` ni `propertyIsEnumerable` [medido, §2].

### 1.3 Coerción

**ToPrimitive y OrdinaryToPrimitive** son correctos y genéricos: buscan `@@toPrimitive` y luego `toString`/`valueOf` por la cadena (`interpreter_support.zig:345-390`) [código], y las sondas con objetos planos coinciden con Node [medido].

**ToString y ToNumber** (`coercion.zig:100-120` y `:50-63`) [código] **resuelven directamente**, sin pasar por ToPrimitive:

- `ToString`: `.array` (con `joinWith`), `.date`, `.promise`, `.regex` (como `"/src/"`, sin flags) y `.bigint`.
- `ToNumber`: `.date`.
- `toDisplayStringJS` solo llama a ToPrimitive cuando ese atajo devuelve `NotImplemented` (`interpreter_support.zig:391-404`).
- **Resultado:** se ignoran `Array.prototype.toString`/`join` modificados, el `toString` propio de un array o de una regex, y los flags al convertir una regex dentro de una plantilla [medido: sondas B "array toString override", "Array.prototype.join override", "template re", "re toString override"].

**ToObject** no existe como operación general. Cada builtin decide qué etiquetas acepta (por ejemplo, `Object.assign` exige `.object` en `object_builtins.zig:55`) [código].

### 1.4 Builtins

- `builtins.setupGlobals` instala los constructores con `installBuiltin` (`builtin_helpers.zig:91`).
- `materializeProtos` (`interpreter_props.zig:770-860`) crea un objeto prototipo por constructor y le copia la tabla de métodos con `installProto`. Encadena todo a `Object.prototype` [código].
- Los prototipos intrínsecos están en el struct `Protos` (`interpreter.zig:33`): object, function, array, string, number, boolean, date, regex, map, set, symbol, promise, bigint, array_buffer, shared_array_buffer, data_view, `typed_array_base` y los once TypedArray, temporal_*, y un único `error`.

**Faltan como intrínsecos** [medido, sondas C]:

- `%IteratorPrototype%`, `%ArrayIteratorPrototype%`, `%MapIteratorPrototype%`, `%SetIteratorPrototype%` y `%StringIteratorPrototype%`. Los iteradores son objetos sueltos con `next` propio (`builtin_helpers.zig:507-521`), así que `[].values().next !== [1].keys().next` y `toString` da `[object Object]`.
- `%GeneratorPrototype%` encadenado y `%AsyncIteratorPrototype%`.
- Los prototipos de los errores nativos: `TypeError.prototype` no hereda de `Error.prototype`, y `TypeError` no hereda de `Error`.
- El constructor intrínseco `%TypedArray%`.

**Globals ausentes** [medido]: `Iterator`, `WeakMap`, `WeakSet`, `WeakRef`, `FinalizationRegistry`, `AggregateError`, `SuppressedError`, `DisposableStack`, `AsyncDisposableStack`, `ShadowRealm`, `escape`/`unescape`.

**Species.** Solo existe `RegExp[Symbol.species]` (añadido en el bloque 1). `Array`, `Promise` y `Map` no tienen `@@species` [medido, sondas E].

**Accessors de prototipo.** Solo RegExp los tiene como accessors reales [medido, sondas G]. `Map.prototype.size`, `Set.prototype.size`, `ArrayBuffer.prototype.byteLength`, `Symbol.prototype.description` y la `length` de los TypedArray se sintetizan en `getProperty`: no tienen descriptor y no se pueden sobrescribir.

**`Error`** (`interpreter_props.zig:101-111`) [código]:

- `name` y `message` se sintetizan; no son propiedades propias.
- `constructor` se resuelve buscando en la variable global.
- No existen `stack` ni `cause` [medido].

### 1.5 Gestión de memoria

**Es un modelo híbrido:** cuenta de referencias en `Rc(T)` de z-value, más un mark-sweep (`collectGarbage`, `interpreter_gc.zig:906`) diseñado para cortar ciclos.

- **`collectGarbage` no se llama nunca durante una ejecución real.** Solo lo usan los tests (`interpreter.zig:1115`), y z-run tampoco lo invoca [código].
- En la práctica solo libera la cuenta de referencias. Los ciclos y todo lo que no está contado se acumula hasta `deinit` (`freeAllGcNodes`).
- **Los `Environment` no cuentan referencias** (`environment.zig:13-16`: "never individually freed").

Memoria medida [medido; RSS máximo con `getrusage`]:

| Caso | Iteraciones | RSS |
|---|---|---|
| Bucle vacío, o creando objetos temporales | 400.000 | 9 MB |
| `f()` vacía en bucle | 100.000 | 96 MB |
| `f()` vacía en bucle | 400.000 | **378 MB** (~0,9 KB por llamada, nunca liberados) |
| `'a' + i` en bucle | 400.000 | 71 MB (~170 B por iteración) |
| `(function(){})` en bucle | 400.000 | 68 MB |

La causa de las llamadas es el entorno y su `arguments` [código]. La de strings y closures es **[hipótesis]**: no se trazó.

Riesgos encontrados durante el trabajo de RegExp (los tres están corregidos en `a1cb817`):

- doble liberación al desmontar el intérprete (se resolvió con la marca `tearing_down`);
- el puntero de z-regex al buffer del llamador (`Regex.pattern`);
- recompilar una regex dentro de un callback.

Riesgos que siguen latentes [código + hipótesis]:

- Un `[[Prototype]]` sin otra referencia se libera si llega a correr `collectGarbage` (por ejemplo con `Object.create(tmp)`).
- `array_props` hereda propiedades al reutilizarse una dirección de memoria.
- Puntero al estado de una tabla lateral guardado mientras corre código de usuario: si ese código añade entradas, la tabla se redimensiona y el puntero queda colgando. En `builtinExec` ya se corrigió; el patrón puede repetirse en otros sitios.

### 1.6 Módulos y capas

`src/` tiene 41 ficheros y 19.939 líneas:

- **Núcleo del evaluador:** `interpreter*.zig` (expr, stmt, props, class, binding, runtime, module, gc, support).
- **Builtins:** un fichero por tipo (`*_builtins.zig`, más `regex_protocol.zig`).
- **Utilidades:** `coercion`, `environment`, `completion`, `fiber`, `inspect`.

Relaciones de importación [código]:

- `interpreter.zig` importa los `interpreter_*` y `builtins.zig`, y estos importan `interpreter.zig` (ciclo de imports, admitido en Zig).
- `builtins.zig` es el concentrador que instala todo.
- Las funciones nativas se acceden a través de `native_helpers` y `builtin_helpers`.

**Frontera con las bibliotecas externas.**

- El intérprete usa z-parser, z-statements y z-functions (parser y AST), z-value (`JSValue`, `Rc`, `Callable`) y las bibliotecas de cada tipo: z-string, z-regex, z-number, z-math, z-json, z-date, z-array, z-object, z-map, z-set, z-error, z-symbol, z-bigint, z-buffer, z-temporal y z-urlcode.
- **El modelo de objetos lo fija z-value**, porque la unión incrusta los tipos concretos de las otras bibliotecas.
- De z-regex usa `Regex.compileWithOptions`, `execAt`, `Subject`, `Scratch`, `MatchSlots`, `advanceIndex`, `groupCount`/`slotCount` y `compiled.named_groups`; este último está fuera de la API estable.
- Ya no usa `find`, `findAll`, `replace` ni `replaceAll` (desde el bloque 2).

## 2. Los 10 huecos de RegExp: causa estructural

| # | Hueco | Causa | ¿Aislado o patrón? | Evidencia |
|---|---|---|---|---|
| 1 | `String(re)`, plantillas y `join` no llaman a `toString` | Atajos de ToString por etiqueta, sin ToPrimitive (`coercion.zig:100-120`) | **Patrón P2** (afecta también a Array y Date) | sondas B |
| 2 | El constructor RegExp no aplica IsRegExp | Falta un paso del spec en un constructor | Aislado | 2 tests de `Symbol.matchAll` y 1 de Annex B |
| 3 | `class X extends RegExp` | `Construct` ignora `newTarget` para builtins: el constructor nativo devuelve su etiqueta, sin enlazar el prototipo de la subclase (`constructValue`, `interpreter_expr.zig:927-950`) | **Patrón P1** (Array, Map, RegExp, Function y Promise fallan en las sondas D; Error se crea pero pierde `message`) | sondas D y `Reflect.construct newTarget` |
| 4 | `propertyIsEnumerable` y `Object.keys` en arrays | Las propiedades de los objetos exóticos están repartidas por etiqueta y tabla lateral | **Patrón P1** | sondas A: 20 de 28 difieren |
| 5 | `length` de `new String(...)` | El envoltorio guarda su valor en `primitive_wrapper_data` y `getProperty` no lo consulta para `length` ni índices | **Patrón P1** | sondas A "String obj length/index" y `gOPN` |
| 6 | `Object.assign` con una regex como destino | El destino debe ser `.object`; las fuentes que no lo son se ignoran; usa `ZObject.set` directo, sin `[[Set]]` (no llama a setters ni a getters de la fuente) | **Patrón P1**, más un ToObject inexistente | sondas A "assign …": 7 de 8 difieren |
| 7 | `%IteratorPrototype%` | Los iteradores son objetos sueltos, sin grafo de intrínsecos | **Patrón P3** | sondas C: 16 de 19 difieren |
| 8 | `deepEqual.js` no parsea | **z-parser no tiene plantillas etiquetadas** | **Patrón P4** (huecos del parser) | `` tag`a${1}b` `` → `SyntaxError` |
| 9 | Estáticos legacy de Annex B | Funcionalidad no implementada | Aislado | 24 tests |
| 10 | `while (re.exec(s))` es O(n) por llamada | Strings en WTF-8 con API en UTF-16 y sin caché de longitud ni de índice | **Patrón P5** | §3.4: `s.length` es O(n) |

**¿Tienen una causa común?** Siete de los diez salen de dos decisiones de base:

- **(a) Objetos.** El modelo de objetos de z-value es una unión por etiquetas en la que solo `.object` es un objeto completo (huecos 3, 4, 5 y 6).
- **(b) Atajos.** Las operaciones abstractas (ToString, ToObject, Construct, la iteración) se implementaron como atajos por etiqueta, en lugar de seguir el algoritmo genérico del spec (huecos 1, 3, 6 y 7).

El hueco 10 sale de la representación de strings y el 8 del parser. Solo el 2 y el 9 son casos aislados.

## 3. Huecos estructurales encontrados (más allá de RegExp)

### 3.1 P1: el modelo de objetos está repartido por etiqueta [medido]

- **20 de 28 sondas A difieren de Node.** Ejemplos:
  - `Object.keys` de un array no incluye sus propiedades con nombre.
  - `propertyIsEnumerable` da siempre `false` fuera de `.object`.
  - `for-in` sobre `new String` no da sus índices.
  - `delete a[0]` no crea un hueco.
  - Un getter definido en un índice de array devuelve `undefined`.
  - Congelar un array no impide `push`.
  - `defineProperty` sobre un `Set` lanza TypeError.
- **Asignar una propiedad a un Map, Date, Error o Promise aborta el script** con `NotImplemented`, que no es capturable (§3.2).
- **Subclases:** fallan Array, Map, RegExp, Function y Promise; Error se crea pero pierde `message`; `Reflect.construct(A, [], B)` no usa `B.prototype` [sondas D].
- **Arrays densos, sin huecos** (`interpreter_props.zig:294` y `:307`) [código]:
  - `a[k] = v` rellena con `undefined` hasta `k`; `a[1e7] = 1` tarda 93 ms y reserva ~160 MB.
  - `defineProperty(arr, "length", {value: "-42"})` intenta crecer a 2³²−42 elementos en vez de lanzar `RangeError`.
  - **Los 81 CRASH de test262 son `exit -9`.** El caso reproducido es este; 39 de los 81 contienen longitudes o índices enormes y el resto no lo verifiqué.
  - Además, `0 in a` da `true` sobre un hueco.

### 3.2 `NotImplemented`: un error de Zig que JS no puede capturar [medido + código]

- Hay 28 sitios que devuelven `error.NotImplemented` (`interpreter_expr` 9, `interpreter_props` 6, `coercion` 5, `interpreter_support` 4, …).
- Ese error **atraviesa `try/catch` de JS y aborta el script**.
- En test262 hay **781 fallos** con esta causa: Array 170, TypedArray 137, language 174, Promise 68, Object 45, …
- Lo que corresponde según el spec es un `TypeError` o el comportamiento real; tal como está, el usuario recibe un abort sin traza.

### 3.3 P3: el grafo de intrínsecos está incompleto [medido]

- Faltan los prototipos de iteradores y generadores, y la cadena `NativeError` → `Error`.
- Falta `%TypedArray%` como constructor.
- `@@species` existe solo en RegExp.
- Los accessors de prototipo existen solo en RegExp.
- Faltan globals: `Iterator` (559 fallos entre `Iterator` y `iterator-helpers`) y las colecciones débiles (210 fallos por `ReferenceError`).
- **Accessors ausentes:** 223 fallos con `Cannot read properties of undefined (reading 'get'/'set')`, sobre todo en ArrayBuffer, Temporal, Error, DataView y SharedArrayBuffer.
- **`Symbol.species`:** 239 fallos (15,8% de paso); 123 de ellos por `NotImplemented`.

### 3.4 P5: strings WTF-8 con API UTF-16 [medido]

Comparación de bucles sobre un string de 40.000 caracteres (z-run frente a Node):

| Operación | z-run | Node |
|---|---|---|
| `for (i < s.length; i++)` | **19.031 ms** (10.000: 1.113 ms; 20.000: 4.947 ms; cuadrático) | 0 ms |
| `s[i]` en bucle | 9.759 ms | 0 ms |
| `charCodeAt(i)` en bucle | 9.418 ms | 0 ms |
| `for-of` sobre el string | 44 ms (lineal) | 2 ms |

- Causa: `lengthUtf16` y `utf16IndexToByte` recorren el string desde el principio en cada llamada (`interpreter_props.zig:82` y `z-string/src/core/utf16.zig:139`) [código].
- Es la misma raíz que el hueco 10.
- **Concatenación `r += 'x'`:** 40.000 tarda 420 ms, 80.000 tarda 3.394 ms y 160.000 tarda 12.930 ms (cuadrática: cada `+=` copia el string entero). `join` de 160.000 elementos tarda 143 ms.

### 3.5 Memoria [medido]

- Cada llamada filtra ~0,9 KB, y las closures y concatenaciones también retienen memoria (§1.5).
- Un programa que haga 10⁷ llamadas necesitaría ~9 GB.
- Para scripts largos de z-run, como servidores o bucles de trabajo, es **el riesgo más grave en uso real**.

### 3.6 P4: parser [medido]

- **1.383 tests de test262 no llegan a ejecutarse** por `SyntaxError` al parsear:

| Construcción | Tests |
|---|---|
| `import()` dinámico | 603 |
| `await` de nivel superior | 248 |
| plantillas etiquetadas | ~175 |
| `using` (explicit-resource-management) | 119 |
| `new.target` | 49 |

- **Nombres privados con escapes:** `#\u{6F}` no se normaliza a `#o` (los identificadores normales sí).
  - Verificado: `this.#o` lanza TypeError cuando el método se declaró como `#\u{6F}`.
  - **[hipótesis]** Ese mismo defecto, combinado con métodos `async` privados, produce los 65 TIMEOUT de `class/elements` (el caso reproducido acaba matado por memoria a los 32 s). No se trazó la cadena completa.

### 3.7 Errores [medido]

- `name` y `message` no son propiedades propias, y el descriptor de `message` da `undefined`.
- No existen `stack` ni `cause`, ni `Error.captureStackTrace`.
- La cadena de prototipos de los errores nativos no es correcta.
- En test262, 989 fallos son de "tipo de error incorrecto" (además, la mayoría de los 515 con `«[object Function]»` en `class` y `async-generator` son esta misma firma en formato asíncrono) y 2.034 de "debía lanzar y no lanzó".
  - Esas dos familias juntan causas variadas; **no se atribuyeron caso por caso [hipótesis]**.
  - Muestras: los constructores con contexto de `Promise` no lanzan cuando `newTarget`/`capability` fallan, y `return-abrupt-from-position` de `endsWith` no propaga la excepción.

### 3.8 Otras observaciones

- **Proxy**, 27,7%:
  - falta `Proxy.revocable` (45 fallos);
  - 73 casos "debía lanzar TypeError" por invariantes de trampas no comprobados [medido por firma].
- **Promise**, 27,6%: le faltan `allSettled`, `any` y `withResolvers`, además de subclases y species [medido por firma/feature].
- **Rendimiento de llamadas:** `fib(22)` tarda 80 ms (Node, 1 ms); 10⁵ llamadas a método tardan 172 ms [medido]. Es razonable para un tree-walker; no es una prioridad.

## 4. ¿Es correcto el flujo?

**Orden.** Es correcto para un tree-walker: parse → AST → evaluación directa, sin fase de compilación. No falta ningún paso obligatorio, pero hay tres decisiones con coste:

1. **No hay análisis de ámbitos en el parseo.** Las variables se buscan por nombre en hashmaps encadenados, y el hoisting se recalcula en cada entrada de ámbito. Lo segundo es un coste de rendimiento **[hipótesis no medida]**.
2. **Las excepciones viajan como error de Zig más un canal lateral.** Funciona, pero conviven `error.JsThrow`, que es capturable, con `error.NotImplemented` y los errores de asignación de memoria, que no lo son (§3.2).
3. **Siempre estricto**, por diseño: cuesta 2.532 tests, que se saltan.

**Acoplamiento.**

- La capa de objetos vive en z-value, y la unión depende de los tipos concretos de 15 bibliotecas.
- Por eso un cambio de semántica de objetos (por ejemplo, dar propiedades a Map) obliga a tocar z-value y z-map, o a añadir otra tabla lateral en el intérprete.
- Ese es el acoplamiento que genera P1.
- Dentro de `src/`, el ciclo de imports `interpreter` ↔ `builtins` está contenido y no es grave.

## 5. Priorización

Escala de impacto en test262: alto, más de 500 tests; medio, 100-500; bajo, menos de 100. El coste es estimado.

| Prioridad | Hueco | test262 | Uso real | Coste |
|---|---|---|---|---|
| 1 | **Memoria: entornos nunca liberados y `collectGarbage` nunca llamado** (§3.5) | ~0 | **Crítico**: crece sin límite en scripts largos | Medio. Llamar `collectGarbage` en puntos seguros es barato; hacer que los entornos cuenten referencias es caro |
| 2 | **`NotImplemented` → excepción JS** (§3.2) | Alto (781) | Alto: aborta sin traza | Bajo: convertir los 28 sitios en `TypeError` o en el comportamiento real |
| 3 | **Strings: caché de longitud y de índice** (§3.4, hueco 10) | ~0 | **Alto**: `for (i < s.length)` es cuadrático | Medio: una marca ASCII o la longitud UTF-16 cacheada en `ZString` (z-string/z-value) |
| 4 | **Arrays dispersos, huecos y `length` con `RangeError`** (§3.1) | Medio (81 CRASH y parte de Array) | Medio | Medio-alto (z-array) |
| 5 | **Coerción genérica: ToString/ToNumber siempre vía ToPrimitive para objetos** (hueco 1) | Bajo-medio | Medio | **Bajo**: quitar los atajos de `coercion.zig` para array, date y regex |
| 6 | **Grafo de intrínsecos: prototipos de iteradores y generadores, `NativeError`, species, accessors de prototipo** (P3, hueco 7) | Alto (Iterator 559, accessors 223, species 239, generadores) | Medio | Medio: es trabajo del intérprete y no toca z-value |
| 7 | **Modelo de objetos unificado: una bolsa de propiedades para toda etiqueta de objeto, ToObject, `[[Set]]` y `[[DefineOwnProperty]]` genéricos, Construct con `newTarget`** (P1, huecos 3-6) | **Muy alto**: transversal a Array, Object, Promise, Map y subclases (miles de tests) | Alto | **Alto**: rediseño en z-value (§6) |
| 8 | **Parser: `import()`, `await` de nivel superior, plantillas etiquetadas, `new.target`, escapes en nombres privados** (P4, hueco 8) | Alto (1.383) | Medio (las plantillas etiquetadas y `new.target` son comunes) | Medio (z-parser) |
| 9 | Globals ausentes: Weak*, `AggregateError`, `Iterator` y sus helpers, `Promise.allSettled/any`, `Proxy.revocable` | Alto en conjunto | Medio | Bajo-medio cada uno |
| 10 | Errores: `name`/`message` propios, `cause`, `stack` | Medio | Medio (`stack` para depurar) | Bajo-medio |
| 11 | Concatenación cuadrática | 0 | Medio | Medio (ropes o buffer de crecimiento) |
| — | Estáticos legacy de Annex B, IsRegExp en el constructor RegExp | Bajo | Bajo | Bajo |
| — | Temporal (2.530 fallos) | Alto | Bajo | Biblioteca aparte (z-temporal) |

## 6. Recomendación

**Por dónde empezar**, en orden; son cambios acotados con mucho retorno:

1. **Llamar `collectGarbage` en puntos seguros** (entre sentencias de nivel superior y al drenar la cola de microtareas) y medir el RSS de nuevo.
   - Es la única forma de que z-run sirva para procesos largos.
   - Antes hay que cerrar los dos riesgos latentes de §1.5: prototipos sin referencia y `array_props` por dirección. El mark-sweep los volvería reales.
2. **Convertir `NotImplemented` en `TypeError` capturable.** Son 28 sitios, el arreglo es mecánico y recupera parte de los 781 fallos. Sobre todo, el motor deja de abortar.
3. **Quitar los atajos de coerción** (`coercion.zig`). Es pequeño y cierra el hueco 1 en todos los tipos.
4. **Caché de longitud y marca ASCII en los strings.** Elimina la clase cuadrática (`s.length`, `s[i]`, `charCodeAt`, `exec` en bucle). Requiere coordinar con z-string y z-value.

**Para un segundo bloque** (más grande; conviene decidirlo con diseño previo):

5. **El grafo de intrínsecos** (P3): `%IteratorPrototype%` y sus derivados, la cadena `NativeError`, `@@species` en Array, Promise, Map y Set, y accessors reales en los prototipos.
6. **El modelo de objetos (P1).** Es la causa de más fallos, pero es la más cara: hay que decidir entre dos opciones.
   - **(a)** Que cada etiqueta de objeto de z-value lleve una bolsa `ZObject` opcional. Generaliza `RegexState.props` y elimina las tablas laterales.
   - **(b)** Convertir los tipos exóticos en `.object` con slots internos.
   - Cualquiera de las dos habilita subclases, `Object.assign`, `keys` y `propertyIsEnumerable` genéricos y propiedades en Map/Date/Error.
   - **Exige prototipo y medición antes de comprometerse.**
7. **Arrays dispersos** (z-array).

**Para después:** el parser (plantillas etiquetadas y `new.target` primero, por uso real; `import()` y `await` de nivel superior después), los globals ausentes, Temporal y Annex B.

## 7. Lo que no se puede determinar sin prototipo o sin medir

- El **coste real del rediseño del modelo de objetos** (opción a frente a b) y su impacto en rendimiento y memoria.
- **Cuántos fallos de test262 desaparecen al arreglar cada patrón.** Las cifras de §3 cuentan firmas de error, y un test puede fallar por varias causas a la vez. Las ganancias reales solo se sabrán midiendo después de cada arreglo.
- **El origen exacto de la memoria retenida** por concatenaciones y closures (§1.5): hace falta perfilar las asignaciones.
- **La cadena causal de los 185 TIMEOUT**, concentrados en `class`, `yield` y `AsyncFromSyncIterator`. Solo se reprodujo uno.
- **Los 42 CRASH** sin longitud ni índice enormes visibles en el fuente.
- **El coste del hoisting** recalculado en cada entrada de ámbito y de crear `arguments` en cada llamada.
- **El efecto de activar `collectGarbage`** en tiempo de ejecución y en la estabilidad (riesgos de §1.5).
- **Las causas detalladas** dentro de "debía lanzar y no lanzó" (2.034) y "valor distinto" (2.962): no se clasificaron test a test.
