# Diseño: subclases de Temporal

**Estado:** propuesta, sin implementación.  
**Objetivo:** hacer que `class C extends Temporal.X` produzca una instancia con
el slot interno de `Temporal.X` y `C.prototype`, sin cambiar los retornos de los
métodos Temporal, que siempre deben ser instancias intrínsecas.

Los 44 fallos actuales se reducen a una causa: ocho `subclass.js`, 35
`subclassing-ignored.js` y `PlainYearMonth/equals/use-internal-slots.js` crean
una subclase antes de usarla. El objeto provisional de `constructValue` no tiene
un slot Temporal; el constructor base devuelve un valor `.temporal` que la ruta
de `super()` no adopta como `this`.

## 1. Representación

### 1.1 Proto por instancia

Usar una tabla lateral nueva, `temporal_protos`, en `Interpreter`, indexada por
la dirección de la caja `.temporal`. Cada entrada posee un `JSValue` que sólo
puede ser `.object` o `.null`.

No conviene añadirlo a `TemporalValue`: ese tipo pertenece a `z-value`, que debe
seguir siendo independiente del intérprete y no puede retener un `JSValue` del
runtime. Tampoco conviene reutilizar `object_slots`: describe slots internos de
objetos ordinarios y no tiene hoy el contrato de arista poseída ni la limpieza
por caja de Temporal. `temporal_props` ya demuestra que una tabla lateral es el
modelo apropiado para estado JS asociado a un valor Temporal nativo.

No reutilizar `proto_refs` literalmente. En esa tabla la ausencia equivale a que
un objeto ordinario conserva su puntero interno; para Temporal hay tres estados
que no se pueden colapsar:

| Entrada `temporal_protos` | `[[Prototype]]` efectivo |
| --- | --- |
| ausente | prototipo intrínseco según el tag Temporal |
| `.object` | ese prototipo de subclase o asignado por el usuario |
| `.null` | `null` asignado explícitamente |

Un único valor nullable por entrada es suficiente; la presencia en la tabla es
el segundo bit. Una instancia intrínseca no crea entrada. Una instancia de
subclase crea una entrada con `C.prototype`.

### 1.2 `Object.setPrototypeOf`

Añadir `setTemporalPrototype(value, prototype)` junto a los helpers de estado
lateral. Debe poseer la referencia, sustituir y liberar la anterior, y aceptar
`.object` o `.null`, igual que el alcance actual de `Object.setPrototypeOf` para
`.object`. No se debe intentar escribir un puntero `ZObject` en `TemporalValue`.

`Object.setPrototypeOf(temporal, p)` debe usar este helper. `Reflect.setPrototypeOf`
no está instalado actualmente; cuando se implemente debe delegar al mismo helper
y devolver su booleano. **Pendiente de prototipo:** decidir después si se amplía
el motor para permitir como prototipo cualquier exótico; este cambio no debe
ampliar ese contrato sólo para Temporal.

## 2. Lectura y reflexión

Crear un único helper conceptual `temporalPrototype(value)`:

```
si temporal_protos contiene la caja: devolver su valor (.object o .null)
si no: devolver Protos.temporalProtoFor(valor interno)
```

| Operación | Archivo y función | Cambio conceptual |
| --- | --- | --- |
| Lectura | `interpreter_props.zig`, `getProperty` `.temporal` | Tras las propiedades propias de `temporal_props`, recorrer `temporalPrototype`, no el intrínseco fijo. |
| Escritura heredada | `interpreter_props.zig`, `setPropertyOnValue` `.temporal` | Buscar setters en `temporalPrototype`; conserva la bolsa propia como almacenamiento. |
| `in` | `interpreter_expr.zig`, `evalIn` `.temporal` | Consultar la cadena del helper, para que métodos de `C.prototype` sean visibles. |
| `instanceof` | `interpreter_expr.zig`, rama `.temporal` | Empezar en `temporalPrototype`; así reconoce tanto `C` como `Temporal.X`. |
| Obtener proto | `object_builtins.zig`, `objectGetPrototypeOf` `.temporal` | Retornar la entrada o el intrínseco. |
| Fijar proto | `object_builtins.zig`, `objectSetPrototypeOf` | Admitir `.temporal` y llamar a `setTemporalPrototype`. |
| Descriptores | `object_builtins.zig`, `objectGetOwnPropertyDescriptor` | Sin cambio de semántica: sólo consulta propiedades propias de `temporal_props`; el proto nunca aparece como propiedad propia. |
| Nombres y símbolos propios | `object_builtins.zig`, `objectGetOwnPropertyNames` y `objectGetOwnPropertySymbols` | Sin cambio: continúan enumerando exclusivamente la bolsa propia. Revisar que no se materialice el proto como bolsa. |
| Definición | `object_builtins.zig`, `definePropertyOn` `.temporal` | Sin cambio de destino: definir en `temporal_props`; las comprobaciones de heredados pasan por la lectura/escritura anterior. |
| Reflect | `reflect_builtins.zig`, `reflectGetPrototypeOf`, `reflectOwnKeys`, `reflectDefineProperty` | Ya delegan en los helpers Object y deben heredar el cambio. Añadir `Reflect.setPrototypeOf` sólo como trabajo separado; hoy no existe. |

Las operaciones de propiedad propia no deben mezclar la bolsa con el proto:
`Object.getOwnPropertyNames`, símbolos, descriptor, `defineProperty` y
`Reflect.ownKeys` siguen usando únicamente `temporal_props`.

## 3. Construcción

### 3.1 Estado de construcción

Extender el estado temporal de construcción del intérprete para conservar el
`newTarget` efectivo y el resultado de `GetPrototypeFromConstructor`. Debe ser
una pila restaurable, como `construct_target`, para que `new` anidado y `super()`
no filtren el contexto del constructor exterior.

Cambiar conceptualmente `constructValue` (`interpreter_expr.zig`) a:

1. recibir `target` y `newTarget` por separado; `new X()` usa `X` para ambos;
   `Reflect.construct(target, args, newTarget)` conserva los dos;
2. obtener una vez `newTarget.prototype`, con fallback intrínseco si no es
   objeto, y guardar el contexto durante la llamada;
3. mantener el objeto ordinario provisional para constructores JS existentes;
4. devolver los retornos objeto como hoy, sin alterar un retorno explícito de un
   constructor JS.

El último punto es deliberado. Aplicar la regla propuesta de cambiar el proto de
*todo* retorno exótico de un constructor JS rompería `class C { constructor(){
return []; } }`: ECMAScript conserva `Array.prototype`, no `C.prototype`. La
adopción de `newTarget` debe estar marcada por el constructor nativo Temporal,
no inferirse sólo del tag del valor devuelto.

### 3.2 Constructores Temporal y `super()`

Cada constructor nativo Temporal, al crear su `.temporal`, consulta el contexto
de construcción actual. Si el `newTarget` no es el constructor intrínseco,
registra `newTarget.prototype` con `setTemporalPrototype` antes de devolver. Si
no hay contexto de construcción, conserva el TypeError actual de llamada sin
`new`.

En `evalCall` (`interpreter_expr.zig`, rama `super()`), si el constructor padre
devuelve ese resultado adoptable, sustituir el `this_value` del entorno del
constructor derivado por el valor Temporal y ejecutar campos de instancia contra
ese valor. El `super()` como expresión devuelve también ese valor.

El constructor derivado implícito (`interpreter_class.zig`) debe conservar y
devolver el valor del padre, en vez de descartarlo. Su flujo es:

```
resultado = llamar super(...args) con el newTarget exterior
si resultado es el resultado adoptable: this = resultado
inicializar campos de la clase derivada sobre this
retornar this
```

**Pendiente de prototipo:** los campos y marcas privadas están modelados hoy
para `.object` (`runInstanceFields` sale temprano con un exótico). Antes de
anunciar soporte general para clases Temporal con campos públicos o privados,
hay que decidir si `runInstanceFields` usará la bolsa Temporal y cómo se marca
la identidad privada. Los 44 tests objetivo no requieren campos.

## 4. GC y ciclo de vida

1. `traceValueChildren` en `interpreter_gc.zig`, rama `.temporal`, debe marcar
   tanto `temporal_props` como `temporal_protos`. El proto es una arista del
   objeto hacia una caja JS, no una raíz global.
2. La destrucción normal por caja (`gcOnBoxDestroyed`) debe hacer
   `fetchRemove` de `temporal_protos` y liberar el valor cuando no esté en
   teardown. El barrido de `.temporal` debe entregar esa arista al `Sweeper`.
3. D0 ya limpia tablas por dirección para evitar que una caja nueva herede
   estado de una dirección reciclada. La nueva tabla debe participar en ambos
   caminos: destrucción por refcount y barrido GC. Omitir uno deja una fuga o un
   proto fantasma.
4. `temporal_props` (la bolsa de propiedades añadida en `6e42500`) permanece
   independiente. Ambas tablas se marcan, se barren y se eliminan en paralelo;
   no deben compartir una entrada porque una instancia puede tener sólo proto,
   sólo propiedades, ambos o ninguno.
5. `deinit` y el barrido de raíces deben liberar/marcar los valores almacenados
   en `temporal_protos`, igual que ya hacen para `temporal_props`.

## 5. Riesgos y controles

| Riesgo | Tests/rutas a vigilar | Señal en sweep | Acotamiento |
| --- | --- | --- | --- |
| Retorno exótico explícito de clase JS | `test/language/statements/class/definition/*return*` | Regresión de prototipo/`instanceof` fuera de Temporal | Marcar sólo el retorno de constructor nativo Temporal. |
| Subclases Temporal básicas | `Temporal/*/subclass.js` | Desaparece TypeError pero falla `Object.getPrototypeOf` | Hacer primero `temporalPrototype` y `instanceof`. |
| Métodos que deben ignorar subclase | `Temporal/*/prototype/*/subclassing-ignored.js` | El TypeError cambia por retorno con proto incorrecto | No modificar `gcNewTemporal` de métodos; sólo constructores. |
| `Reflect.construct` con `newTarget` distinto | `built-ins/Reflect/construct/*`, Temporal `get-prototype-*` | Getter no observado o proto de target usado | Separar `target` de `newTarget`, preservar Get observable. |
| `Object.setPrototypeOf` de Temporal | `built-ins/Object/setPrototypeOf/*`, Temporal propios | TypeError inesperado, ciclo o proto intrínseco persistente | Limitar a `.object`/`.null`, como el contrato existente. |
| Lectores/getters heredados | Temporal `prototype/*`, `language/expressions/property-accessors/*` | Getter recibe receptor incorrecto o no se ve | Reusar `getFromProto` con receptor Temporal y probar getter en `C.prototype`. |
| Escritura contra setter heredado | `language/expressions/assignment/*`, Temporal propiedades | Se crea propiedad propia en vez de invocar setter | Cambiar también `setPropertyOnValue`, no sólo `getProperty`. |
| GC y reutilización de dirección | pruebas locales de GC, `Object.defineProperty` sobre Temporal | Fugas, proto de objeto viejo o crash | Añadir tabla a traza, sweep y D0 antes de construcción. |
| `bind` y clases derivadas | `built-ins/Function/prototype/bind/*`, `language/statements/class/*` | `isConstructor` o proto incorrecto | No alterar constructibilidad/bound en este bloque; probar `newTarget` separado. |
| Campos públicos/privados en subclase Temporal | `language/statements/class/fields/*`, futuros Temporal | Campos omitidos o marcas privadas inválidas | Declarar fuera del primer bloque; detener si aparece en los objetivos. |

También vigilar instancias creadas antes de modificar un prototipo intrínseco,
`prototype = null`, proxies como `newTarget`, y subclases de Array. Ninguno debe
cambiar por el primer bloque: la tabla y el contexto se aplican sólo a `.temporal`.

## 6. Plan de implementación

### Commit 1 — prototipo por instancia

Archivos: `interpreter.zig`, `interpreter_gc.zig`, `interpreter_support.zig`
(o un helper nuevo), `interpreter_props.zig`, `interpreter_expr.zig`,
`object_builtins.zig`, y posiblemente `reflect_builtins.zig` sólo por delegación.

Añadir la tabla, los helpers, traza, limpieza D0 y todas las lecturas del proto.
Medir: tests aislados de `Object.getPrototypeOf`, `instanceof`, herencia de
métodos y GC; luego revisar regresiones en Object/Reflect.

### Commit 2 — `newTarget` y constructores Temporal

Archivos: `interpreter_expr.zig`, `reflect_builtins.zig`,
`temporal_builtins.zig`. Separar `target/newTarget`, mantener el contexto, y
aplicar el proto sólo al valor creado por un constructor Temporal nativo.

Medir: los ocho `Temporal/*/subclass.js`, `Reflect.construct` y constructores
Temporal ordinarios. Parar si una clase JS que devuelve un array/función cambia
su proto.

### Commit 3 — adopción por `super()`

Archivos: `interpreter_expr.zig`, `interpreter_class.zig`, y `environment.zig`
si necesita un helper seguro para sustituir el `this` poseído del entorno.

Actualizar `super()` y el constructor derivado implícito; no tocar `gcChildEnv`.
Medir: los 35 `subclassing-ignored.js`, el caso `PlainYearMonth.equals`, y una
muestra de definición de clases normal que ya pasaba. Parar ante pérdida de
campos, privados, retornos explícitos o errores de ownership.

## 7. Estimación y recomendación

Estimación: **180–300 líneas** repartidas en 7–9 archivos, más pruebas locales
específicas. Tiempo: **1 a 2 días** de implementación y diagnóstico, más el
sweep del usuario. Riesgo: **5/5**, porque toca la representación de prototipos,
GC y construcción a la vez.

Conviene arrancarlo ahora, pero sólo en los tres commits anteriores y con punto
de parada tras cada uno. Los 44 fallos comparten una raíz real y el diseño evita
la alternativa peligrosa de cambiar los retornos de todos los métodos Temporal.
