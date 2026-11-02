# Plugin `unreal`: importar contenido de Unreal Engine

El plugin `unreal` lee paquetes de editor de Unreal (`.uasset` y `.umap` sin cookear, como los de
Fab) sin Unreal instalado y los traduce a los assets y conceptos de Mirai. Todo es de editor
(`parts: Editor, Shaders`): un juego no lleva código del plugin, solo los programas que sus
materiales importados incluyen (`shaders/unreal_noise.slang`). El motor no conoce Unreal: el plugin
se instala en un proyecto desde el catálogo de Mirai (`mirai plugin add unreal`), que lo deja en
`plugins/unreal` del proyecto con sus companions.

## Qué hay

- La raíz es el plugin `unreal`: los paquetes de lectura y traducción, el formato de modelos, el
  importador de mapas y el método de API `unreal.inspect`.
- `plugins/`: sus companions `unreal_terrain`, `unreal_foliage`, `unreal_physics`, `unreal_fog`,
  `unreal_navigation`, `unreal_vfx` y `unreal_fluids`, puentes automáticos (`automatic: true`,
  solo de editor). Cada uno depende de `unreal` y del plugin que traduce, y le da al importador el
  traductor de sus actores o las texturas que sus sistemas escriben.

Los paquetes de `editor/` se importan como `project:plugins/unreal/editor/<paquete>`:

- `package`: el paquete de editor (tablas, propiedades, payloads); `kraken`: el decodificador de
  Oodle; `texture`, `mesh`, `material` (con `write` y `fixture`), `level`, `landscape`, `foliage`.
- `model`: el formato de modelos `.uasset` (`FORMAT`), y `scene`: un mapa como escena de un
  proyecto (`level_import`).
- `inspect`: el diagnóstico detrás de `unreal.inspect`; `fixture`: paquetes sintéticos para las
  pruebas.
- `api.odin` y `unreal.odin`: los storages del plugin, abajo.

## Mapa

- Paquetes, payloads, Kraken, texturas, mallas, esqueletos, animaciones, materiales, niveles,
  Landscape, follaje y mapas como escena: [unreal.md](unreal.md).
- Qué traduce cada plugin puente (terreno, follaje, física, niebla, navegación, partículas) y el
  contrato de un traductor: [translators.md](translators.md).
- Por qué se decidió así y qué se descartó: [decisions.md](decisions.md).

## Importar en el editor

Los storages del plugin (`unreal.odin`, `api.odin`) son providers que el editor lee de la
biblioteca del proyecto:

- `Unreal_Format` es un `Import_Format_Provider` con el formato `.uasset` (`model.FORMAT`): un
  paquete se importa como los modelos del motor (File > Import, el botón Import del content
  browser o soltando el archivo en la ventana) a `models/<nombre sin prefijo>/`, con su malla,
  materiales, texturas y prefab, o sus clips y esqueleto. Su `prepare` le da las `reads` de los
  `Translator_Provider` de la biblioteca (`model.Options.reads`).
- `Unreal_Maps` es un `Import_Source_Provider` que reclama un `.umap` por su extensión y su
  firma. `prepare` (hilo del editor) junta los traductores y las `reads` de los
  `Translator_Provider` de todos los plugins de la biblioteca y `run` (hilo de la importación)
  llama a `scene.level_import`: la escena queda en `levels/<mapa>.scene`, con sus secciones por
  celda si el mapa es de World Partition, y lo que escriben los traductores en `levels/<mapa>/`.
- `Unreal_Api` registra `unreal.inspect` ([diagnóstico](unreal.md#diagnóstico-inspect)).
- Importar de nuevo da los mismos ids. Una importación que escribe programas Surface publica los
  programas del
  proyecto para que sus materiales se vean.
- `mirai import` y la CLI del motor no conocen Unreal: un mapa o un `.uasset` se importa en el
  editor, con `unreal` en los plugins del proyecto. Sin el puente de una clase de actor, el mapa
  la deja como un aviso que dice qué plugin activar.

## Invariantes

- **Engine-time.** Nada del plugin se importa desde runtime; un juego solo lleva el programa
  `unreal_noise.slang` si sus materiales importados lo incluyen.
- **Los conceptos de Unreal no salen del plugin.** Un traductor convierte a los de Mirai (unidades
  fotométricas, materiales del modelo estándar o un programa Surface, escenas, prefabs, follaje);
  los plugins del dominio (`terrain`, `foliage`...) no importan nada de Unreal, y el puente es el
  único que importa a los dos.
- **Una entrada válida no hace caer al motor.** Cada lector acota bytes, tablas y profundidad
  (`Limits`), rechaza un paquete dañado con `Error{code,offset,field}` y una versión que no
  conoce, y no lee ni escribe fuera de sus slices. Lo que no puede traducir es un aviso con
  cantidad, no un valor inventado.
- **Los mismos bytes dan los mismos assets.** Los ids de lo importado salen de la ruta del
  actor y del componente, no de una numeración, y reimportar conserva lo que escribió la
  importación anterior.
- **Sin Unreal instalado.** Lo que un paquete nombra de `/Engine` se lee si hay una instalación
  montada y, si no, lo reemplaza algo del motor con una advertencia
  ([decisión](decisions.md#engine-sin-unreal-sustitutos-propios-del-motor)).
- **Ningún asset real entra al repositorio.** Las pruebas usan paquetes sintéticos
  (`fixture`); el corpus real vive en proyectos aparte.

## Verificación

Con `mirai test` sobre el paquete tocado (los paquetes de `plugins:` se resuelven solos):

- `mirai test plugins/unreal/editor`: la integración con el editor (formato, mapas, programas
  publicados).
- `mirai test plugins/unreal/editor/<paquete>` con `package`, `kraken`, `texture`, `mesh`, `model`,
  `material`, `material/write`, `level`, `landscape`, `foliage` o `scene`; las pruebas focales
  de cada uno están en [unreal.md](unreal.md#verificación).
- `pruebas de plugins/unreal_<x>/editor` con `terrain`, `foliage`, `physics`, `fog`, `navigation` o
  `vfx`: [traductores](translators.md#verificación).
- Contra un corpus real, `unreal.inspect` y, en una sesión del editor, importar un mapa con los
  puentes que usa.
