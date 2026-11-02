# Unreal: paquetes de editor, Kraken, texturas, mallas, materiales y niveles

Los paquetes de `editor/` (importados como `project:plugins/unreal/editor/<paquete>`) leen
paquetes de editor de Unreal (`.uasset`/`.umap` sin cookear, como los de Fab) sin Unreal
instalado. Son engine-time: viven en la parte editor del plugin `unreal` y ningún juego los
contiene. `package` se importa como `unreal`; `foliage` y `scene` se llaman `unreal_foliage` y
`unreal_scene` (los nombres de paquete son únicos). Solo `material/write` y `scene` escriben
assets: mallas, esqueletos, animaciones y texturas llegan al editor por el formato `model`
([modelos](#formato-de-modelos-model)) y los mapas, como [escenas](#niveles-a-escena-scene).
`fixture` arma los paquetes sintéticos de las pruebas y `fixture/files` los escribe como archivos
completos. Cómo se importan en el editor: [README](README.md#importar-en-el-editor).

## Paquetes (`package`)

`package_open` es una vista sobre bytes del llamador, que deben vivir hasta `package_destroy`; los
nombres UTF16 se convierten y son del paquete. `Error` es `{code,offset,field}`, con `field`
constante (vale aunque falte memoria). `Limits` acota bytes, tablas, textos, propiedades y
profundidad de outers.

- **Versiones.** UE4 desde 214 y UE5 hasta las que conoce el lector, licenciatario cero; en los
  más nuevos los bits altos del campo de versión legacy guardan el offset de la tabla de offsets.
  Cada campo sigue las compuertas de versión de Unreal.
- **Rechazos.** Versión desconocida (`Unsupported_Version`), sin versiones o con
  `PKG_UnversionedProperties` (`Unversioned`), `PKG_Cooked` (`Cooked`) y compresión de paquete
  (`Compressed`).
- **Tablas.** Se comprueban límites, solapamientos, referencias y ciclos de outers. `Object_Ref`
  conserva el índice de Unreal (cero nulo, negativo import, positivo export).
- **Propiedades.** `property_value` interpreta los tipos comunes; contenedores, FText y structs
  nativos dan `Unsupported_Value` y se leen con los ayudantes de arrays y structs tagged.
  `class_default_object` busca el CDO por clase y flag, no por nombre.
- **Mounts.** `Source_Mount` asocia un prefijo (`/Game`, `/Engine`) a una carpeta `Content`;
  `source_package_path` y `source_package_name` convierten entre paquete y archivo y rechazan
  traversal, dispositivos y prefijos ambiguos. Cómo se eligen:
  [montajes](#formato-de-modelos-model).

### Payloads

- Solo se leen los payloads locales: `editor_bulk_data` ubica un `FEditorBulkData` en el trailer
  o en su offset absoluto y `byte_bulk_data`, el bulk data de UE4 inline, al final del archivo o en
  chunks zlib. Virtualizado, sidecar, workspace, legacy o en un archivo aparte es
  `Unsupported_Value`.
- `compressed_buffer_decode` admite None, LZ4 (`std/serial`) y Oodle con un `kraken.Decoder`, y
  compara el resultado con el BLAKE3 del buffer: uno que no coincide es `Malformed`. El tamaño
  crudo de un payload también lo acotan los `Limits` del paquete.

## Kraken (`kraken`)

`decoder_make` reserva una vez lo que un chunk necesita y `decode` decodifica un stream Oodle cuyo
tamaño crudo es `len(destination)` sin asignar.

- Compresores: Kraken, Mermaid y Selkie (un mismo formato) y Leviathan, que comparten bloques,
  quanta y chunks y difieren en el LZ de cada chunk (`lz_decode`, `mermaid_decode`,
  `leviathan_decode`). Arrays: guardados, tANS, Huffman, RLE, secuencias y multi-arrays (arrays
  cortados por intervalos de otros, con largos de bits variables leídos desde ambos extremos).
- `Unsupported`: LZNA, BitKnit y el byte de flag de 0x80 al comienzo de un chunk LZ de Kraken (bytes
  de exceso), que ninguna descripción abierta del formato lee: esos modos no se leen y ningún
  corpus los usa.
- Ningún corpus usa tANS, multi-arrays, Mermaid, Selkie ni Leviathan: los valida solo el encoder de
  las pruebas, escrito desde la misma descripción del formato
  ([decisión](decisions.md#formatos-de-oodle-sin-corpus)).
- Un stream dañado da `Truncated` o `Malformed` sin leer ni escribir fuera de los slices; cada
  stream (literales, offsets, largos, arrays de intervalos) debe consumirse entero. La corrección
  se mide con el BLAKE3 de cada `FCompressedBuffer`.
- Las copias de un match escriben palabras de 8 bytes y pueden pisar hasta 7 bytes después del
  match dentro del destino: son salida que todavía no se escribió.

## Texturas (`texture`)

- `texture_kind` reconoce las clases de textura de `/Script/Engine` (2D y sus variantes de lightmap
  y perfil de luz, cube, arrays y volumen). `texture_read` lee el struct `Source` y ubica el
  payload (`FEditorBulkData` desde la virtualización de UE5, bulk data antes) con las reglas de
  carga de Unreal para saves viejos.
- **Uso.** `TC_Normalmap` es `Normal`; `SRGB` falso, `TC_Masks`, `TC_Alpha` y los HDR son `Data`; el
  resto, `Color`. `TC_Grayscale`, `TC_Displacementmap`, `TC_HalfFloat`, `TC_SingleFloat` y
  `TC_HDR_F32` piden `keep_precision`: un origen de 16 bits o float se guarda sin comprimir. Los
  demás ajustes de compresión de Unreal no cuentan: el formato lo decide el
  uso (`cook/textures` del motor)
  ([decisión](decisions.md#texturas-de-unreal-el-uso-decide-el-formato-no-sus-ajustes-de-compresión)).
- `texture_decode` da todos los bloques, capas, mips y slices, filas desde arriba, en RGBA8,
  RGBA16 o RGBA32F lineal según el formato de origen, desde None, UEDELTA, PNG, JPEG o UEJPEG.
  PNG, JPEG y UEJPEG son una sola imagen 2D y, como en Unreal, el formato lo dicen sus bytes y no
  la compresión que nombra el origen: PNG y JPEG con stb, `OOJPEG` con `uejpeg_decode`. Un origen
  que se llama PNG y es `BGRA8` guarda los bytes tal cual (Unreal los escribió como RGBA); si la
  imagen no decodifica y el payload mide lo que el origen sin comprimir, se lee así, como Unreal.
- **UEJPEG** (`uejpeg.odin`): los coeficientes cuantizados de un JPEG baseline
  sin Huffman, en bandas horizontales (splits) guardadas o comprimidas con Oodle (se decodifican
  con `kraken`). Da los píxeles que da Unreal en x64: la IDCT rápida entera como la calcula su
  camino SSE2, y el upsampling y el YCbCr en punto fijo por SSE2
  ([decisión](decisions.md#uejpeg-los-píxeles-de-unreal-en-x64)). El origen es `BGRA8`, o `G8`, que
  guarda el rojo como `ImageCore`; 16 bits o float es `Unsupported_Value`. Se rechaza lo que
  Unreal no valida y lo haría leer fuera de sus planos o dejar coeficientes sin escribir: bloques
  fuera de la imagen o un split Oodle vacío.
- Las normal maps salen en la convención de Mirai (+Y): el verde se invierte salvo que
  `bFlipGreenChannel` ya lo invirtiera.
- `check`: con `bGuidIsHash` el `Id` es el BLAKE3 del origen crudo, y `Matches`, `Differs` o
  `Unknown` comparan contra lo decodificado.
- `texture_build_input` da a `cook/textures.build` del motor el nivel 0 del primer bloque y capa con
  su
  precisión y sus `Build_Options`: 8 bits como están (la curva 2.2 legacy pasa a sRGB), 16 bits
  lineales que el color lleva a la curva sRGB, y floats como son, HDR por encima de 1 incluido.
  - Un array conserva sus slices como capas.
  - Un cubo da sus caras en el orden y los ejes de Mirai: cada texel de una cara de Mirai es el de
    Unreal que se muestrea con la misma dirección del mundo (`cube_faces`, una permutación exacta).
    Uno de longitud y latitud (`bLongLatCubemap`, o slices que no son cubos enteros) se vuelve seis
    caras como lo hace el build de Unreal (`cube_long_lat`): lado la potencia de dos de la mitad
    del ancho o menos, al menos 32, y cada texel lee la imagen bilineal en su longitud y latitud.
  - `approximations` dice lo que un `.tex` no guarda: la profundidad de un volumen después de su
    primer slice, las capas de Unreal (varias imágenes por textura, de las texturas virtuales)
    después de la primera, los bloques UDIM después del primero y los mips de autor (la cadena la
    rehace `cook/textures` del motor). Mirai no tiene consumidor de volúmenes, capas ni UDIM.
- Un paquete con solo texturas se importa como esas texturas
  ([importación](#formato-de-modelos-model)); el resto llega por los materiales que las leen. Un
  cubo o un
  array no se hornea en un mapa de uv (`source_pixels`): solo entra como textura.

## Mallas estáticas (`mesh`)

`mesh_read` lee una `StaticMesh` y ubica el payload de un source model; `mesh_decode` lo construye
como el build de Unreal: un `Mesh` de esquinas en el espacio de Unreal, con la escala de build. Un
paquete con mallas se abre con `LIMITS`: el payload de una malla de millones de triángulos supera
`DEFAULT_LIMITS`.

- **Modelo.** `Lod0` (lo que Unreal dibuja sin Nanite) o `Hi_Res` (`HiResSourceModel`, del que se
  construye Nanite) ([decisión](decisions.md#mallas-de-unreal-lod-0-y-no-el-hi-res-de-nanite)). Los
  LOD 1+ no se leen: los niveles de Mirai salen de LOD 0.
- **Payload**, según las versiones del paquete: un `FRawMesh` o un `FMeshDescription` (en el
  formato de mapa de elementos o en el de arreglos de UE4). Una descripción guardada antes de
  `MeshDescriptionTriangles` trae solo polígonos: sus triángulos son los que UE5 hace al cargarla,
  el abanico sobre la segunda esquina, también en un polígono cóncavo
  ([decisión](decisions.md#polígonos-sin-triángulos-el-abanico-que-dibuja-ue5)).
- **Lo que hace el build** (`Mesh`):
  - Las secciones son los grupos de polígonos, con el material que Unreal les da (-1 si ese slot
    no existe).
  - Un triángulo degenerado (esquinas a menos de `DEGENERATE_DISTANCE`, exactas sin
    `bRemoveDegenerates`) o sin área se descarta.
  - Normales, donde se recomputan, faltan o no son finitas: la suma de las de los triángulos unidos
    por aristas suaves. Tangentes: las de la fuente salvo que se recomputen; en cero, quien importa
    hace MikkTSpace.
  - `BuildScale3D` escala posiciones y tangentes y la inversa a las normales; una escala que refleja
    da vuelta los triángulos.
  - Color: los bytes del vertex buffer de Unreal; vacío si todos son blancos.
  - Triángulos en el orden de Unreal: visto de frente, `cross(c2-c0,c1-c0)` sale de la cara.
- `Static_Mesh` trae además los slots, `ExtendedBounds` y el `BodySetup`, que `body_read` lee: las
  formas de su `AggGeom` en el espacio de Unreal y de la malla (los puntos de un convexo con su
  `Transform` aplicado; los elementos con `CollisionEnabled` en `NoCollision` quedan afuera), el
  `CollisionTraceFlag` y el perfil de su `DefaultInstance`. Algunos saves de UE4
  guardan el material de un slot solo al final de la serialización de la malla: se toma de ahí.

## Mallas con esqueleto (`mesh`)

`skeletal_read` lee una `SkeletalMesh` (propiedades, materiales, `FReferenceSkeleton` y dónde está
LOD 0); `skeletal_decode` da un `Skinned_Mesh`, el `Mesh` de las estáticas con las influencias de
cada posición y los morph targets de LOD 0. `skeleton_read` da el esqueleto de referencia de un
`Skeleton` y sus sockets.

- **Esqueleto.** El de referencia de la malla, el de su pose de bind: nombres, padres (siempre un
  hueso anterior, una sola raíz) y la pose de cada hueso relativa a su padre; `Skeleton` es la ruta
  de su `USkeleton`, que no se abre.
- **Sockets**: los `USkeletalMeshSocket` de la malla o del `Skeleton`, con su hueso y su lugar.
- **Curvas de morph targets** (`Skeleton.morph_curves`): las que la metadata de curvas del
  `Skeleton` marca con `bMorphtarget`, leídas según la versión; si no se pudo leer la metadata,
  `curves_known` es falso.
- **Dónde está LOD 0**: hasta UE 5.3, el `FSkeletalMeshLODModel` que el build guarda con los datos
  de editor, lo que Unreal dibuja, sin reconstruir nada; después, el `FMeshDescription` del source
  model con sus `SkinWeights`. Saves anteriores a `SplitModelAndRenderData` o a
  `IncreaseNormalPrecision` son `Unsupported_Value`: hay que guardarlos de nuevo en Unreal.
- **Build de una descripción** (`skin.odin`), lo que el build esquelético de Unreal guardaría en
  el modelo LOD:
  - Normales como en una malla estática; solo salen los triángulos sin área, porque el build
    esquelético no quita degenerados (`bRemoveDegenerates` no lo cambia).
  - Color sin sRGB (`ToFColor(false)`), blanco si ninguna esquina tiene otro color que negro.
  - Influencias: las primeras que el build guarda, de huesos que existen, ordenadas y
    renormalizadas como en Unreal (el resto de cada peso pasa al siguiente, con el orden de Unreal
    en los empates); sin ninguna, la raíz. Cuántas: el
    `BoneInfluenceLimit` del asset, si no el `DefaultBoneInfluenceLimit` del proyecto, nunca más
    de doce, y ocho salvo `r.GPUSkin.UnlimitedBoneInfluences` por encima de su umbral. El proyecto
    sale del `Config/DefaultEngine.ini` del montaje `/Game` (`skin_project_read`); sin él, los
    defaults del motor. El valor `PerPlatform` del límite no se lee.
  - Soldadura: en el orden de las caras, una esquina pasa a ser el
    primer vértice ya hecho en su chunk (el material de su sección) cuya esquina se superpone y
    es igual dentro de los umbrales de `FSkeletalMeshBuildSettings` (posición, uv, base tangente)
    con el mismo color e influencias; un triángulo con dos esquinas en un vértice sale
    (`degenerate`). Se compara la tangente de la fuente; la que la importación hace después con
    MikkTSpace no está todavía. Las normales de una descripción no son las de
    `Skeletal_ComputeTangents`, y las influencias de `SK_DinoDragon` y `SKM_Quinn` (ContentExamples
    5.8) difieren de su modelo LOD guardado (11/10 contra 8): no se compararon con Unreal.
- **Secciones.** Un índice que sale de su sección es `Malformed`. El material sale de
  `LODMaterialMap` de LOD 0 (en una descripción, del nombre del grupo como
  `AdjustImportDataFaceMaterialIndex`); las secciones `bDisabled` quedan afuera (`left_out`) y las
  de tela se cuentan (`cloth`) y se dibujan con su skin.
- **Morph targets** (`morphs`, con la fila de deltas de cada esquina): de un modelo LOD, el
  `FMorphTargetLODModel` de LOD 0 de cada `UMorphTarget`; de una descripción, los atributos
  `Morph-<nombre>`. Un target cocinado es `Cooked`.

## Animaciones (`mesh`)

`animation_read` lee una `AnimSequence`: la transform local de cada hueso por clave (sin escalas,
escala uno), curvas float, marcadores de sync y cómo se reproduce (`RateScale`, `Interpolation`,
root motion, aditivo, notifies), con claves cada `interval` segundos desde 0 hasta la duración.

- **Dónde está**, según el save (`layout`): `Raw_Tracks` en UE4 (`RawAnimationData` o
  `SourceRawAnimationData`, con las claves que Unreal corrige al cargarla), `Data_Model` en
  UE 5.0 y 5.1 (el `AnimDataModel`) y `Sequencer` desde 5.2: cada hueso es un control
  `<hueso>_CONTROL` del control rig de la sección, cuyos canales se evalúan en cada frame como en
  Unreal y la rotación por `FQuat::MakeFromEuler`.
- Una pista de menos claves conserva la última, como Unreal acota la clave que muestrea; las de más
  se recortan. Las tangentes que no son números son cero.
- Aproximación: un segmento cúbico con tangentes de peso se evalúa sin el peso (`weighted` cuenta
  los frames afectados; ninguno en los corpus). Una animación cocinada es `Cooked`.

## Formato de modelos (`model`)

El paquete `model` (`uasset`) es el formato `.uasset` de modelos del editor: importa cada
`StaticMesh` de un paquete de editor como una malla con su nodo
([lectura](#mallas-estáticas-mesh)), cada `SkeletalMesh` como una malla con
esqueleto ([lectura](#mallas-con-esqueleto-mesh)) y cada
`AnimSequence` como un clip ([lectura](#animaciones-mesh)). Un paquete con solo
un `Skeleton` es ese esqueleto; uno con solo texturas, cada una un `.tex` con sus capas, sus caras
y la precisión de su origen ([lectura](#texturas-texture)); uno sin nada de eso
es `Unsupported`. Lo que el paquete rechaza llega con su causa y su offset.

- **Espacio.** Centímetros, +Z arriba, +X adelante, +Y derecha y zurdo, con V desde arriba: el +X
  del motor es el -Y de Unreal, su +Y el +Z y su frente el +X. Es un espejo: los triángulos de
  Unreal, que corren al revés de sus ejes, entran al builder con las esquinas invertidas y el
  espejo los vuelve a girar.
- **Slots.** Uno por slot de `StaticMaterials` que use una sección: su id es el índice del slot
  más uno (lo que un componente de Unreal sobrescribe por índice) y su etiqueta el nombre del
  slot; una sección sin material válido va al slot 0, sin material.
- **Materiales.** `slot_material(&contexto,slot)` hace el material de un slot, uno por ruta de
  objeto en la importación: lo traduce
  [`material`](#materiales-material) a través de los montajes
  (una `Library` y un `write.Builder` por importación, o los de `Options.library` e `images`, que
  un nivel comparte entre todas sus mallas) y lo agrega con sus imágenes con
  `write.reader_material`. Un

  material que no se encuentra o no se traduce toma los valores de `.mat` con su nombre y deja
  una advertencia. Uno que necesita un programa Surface lo escribe en `<root>/shaders`; sin
  `root`, conserva sus valores del modelo estándar y deja una advertencia: leer una fuente no
  escribe fuera de una carpeta de proyecto.
- **Color de vértice.** Unreal solo lo usa si el grafo del material lo lee; el modelo estándar de
  Mirai lo multiplica siempre y un programa lo lee como dato. Las esquinas llevan el color solo en
  los slots cuyo material traducido lo multiplica por su color base o cuyo programa lo lee
  (`Vertex_Colors.Multiply_Base_Color`, `.Program`)
  ([decisión](decisions.md#color-de-vértice-de-unreal-solo-si-el-material-lo-usa)).
- **UV.** Las dos primeras; si hay más, una advertencia.
- **Montajes.** `/Game` es la carpeta `Content` del proyecto del paquete: de las carpetas
  `Content` que lo contienen, la primera junto a un `.uproject` o, sin ninguna, la más cercana
  (solo se listan las carpetas que tienen una `Content`). Un paquete fuera de toda carpeta
  `Content` (un pack copiado sin su proyecto) monta lo que da `source_mount_guess` del nombre que
  guarda de sí mismo o, si lo renombraron, `source_mount_near` de un paquete que importa;
  `/Engine`, `Options.engine_content` o,
  sin él, `UNREAL_ENGINE` (una instalación o su carpeta `Engine`) o la instalación `UE_<versión>`
  más nueva donde las deja el launcher de Epic. Cada plugin del motor con contenido monta el suyo
  (`/Niagara` es `Engine/Plugins/FX/Niagara/Content`, `engine_plugin_mounts`). Recorrerlos lee
  cientos de carpetas: la importación de un paquete suelto los monta recién cuando lee un paquete
  que solo un plugin puede tener (`library_plugins_mount`); la de un nivel, al empezar.
- **`/Engine` sin Unreal** (`engine.odin`): un material de `/Engine` que ningún montaje tiene, o uno
  que lee una textura, función, colección o padre de `/Engine` que falta, es la grilla del motor
  (`engine_grid`: el modelo estándar con el programa `Grid` de `shaders/materials`, líneas cada
  metro del mundo y más oscuras cada diez), con una advertencia que nombra la referencia original
  ([decisión](decisions.md#engine-sin-unreal-sustitutos-propios-del-motor)). Con `/Engine`
  montado se lee el original.
- **Modelo.** LOD 0; con `Options.hi_res`, el hi-res de Nanite de las mallas que lo tienen.
- **Esqueleto.** El de referencia de la malla, con el nombre de su `USkeleton`; la ruta de un hueso
  son los nombres desde la raíz. Un joint por hueso, cuyo inverse bind es el del hueso en reposo:
  la pose de bind dibuja la malla como está. Huesos e inverse binds pasan al espacio del motor con
  la geometría. Sus sockets son los de la malla y los de su `USkeleton` (que se abre por los
  montajes) que la malla no nombra, como en Unreal; uno de un hueso que el esqueleto
  no tiene, o de escala cero, queda afuera con una advertencia.
- **Pesos.** Cada vértice conserva sus ocho influencias mayores, cuantizadas a bytes que suman 255,
  y una advertencia cuenta los que tenían más; uno sin influencias sigue a la raíz, como en
  Unreal. Las secciones que Unreal no dibuja quedan afuera y las de tela se pegan a sus huesos, con
  una advertencia cada una.
- **Morph targets.** Los de LOD 0, en peso cero, como los morph targets de la
  malla: los deltas de posición y de normal de la fila de cada esquina; las tangentes que hace
  MikkTSpace siguen a la forma.
- **Animaciones.** El clip de una `AnimSequence` lleva su nombre y está en el `.anim` del paquete;
  importar una malla no pide sus animaciones.
  - Las pistas se ligan por la ruta de cada hueso en el `USkeleton` de la animación (sin él,
    `Not_Found`), comparando nombres sin mayúsculas como Unreal; una pista de un hueso que no existe
    queda afuera con una advertencia.
  - Una clave por frame, lineal. Con `Interpolation` Step cada clave empieza a la mitad del frame
    anterior, como Unreal toma el frame más cercano. Sin escalas un hueso es de escala uno, como en
    Unreal, aunque su reposo sea otra.
  - Las curvas son tracks `Float` de su nombre y, las que el esqueleto marca de morph target,
    también de `/@morph/<nombre>`
    (pesos de morph de `animation`). La interpolación de una
    clave de Unreal (cómo va a la siguiente) es la de llegada de la siguiente en Mirai: constante es
    `Step` y cúbica, `Cubic_Spline`. Tangentes de peso y extrapolaciones no constantes son
    advertencias.
  - Los marcadores de sync son marcadores. `RateScale` se hornea en tiempos y pendientes; uno que no
    es positivo se rechaza.
  - Con root motion o `bForceRootLock`, el hueso raíz es la raíz del clip; un `RootMotionRootLock`
    que no es la pose de referencia es una advertencia, porque Mirai deja la raíz en su reposo.
  - Una animación aditiva se rechaza con la razón
    ([decisión](decisions.md#animaciones-aditivas-de-unreal-se-rechazan)); los notifies son lógica
    de Unreal: una advertencia.
- **Colisión.** El `AggGeom` del `BodySetup` (`umesh.body_read`) son los colliders de la malla:
  cajas, esferas y cápsulas tal cual y cada convexo como un casco de sus puntos; las cápsulas
  ahusadas y los level sets son una advertencia. Con `CTF_UseComplexAsSimple` no hay colliders de
  la fuente: la colisión son sus triángulos (la colisión del motor).

## Materiales (`material`)

`Library` abre una vez cada paquete por nombre, por sus `Source_Mount` o con los bytes de
`library_add`; `object_find` y `object_resolve` dan un `Object` (un import lleva al export que
nombra). Todo vive en el arena de la biblioteca.

- `translate` traduce un `Material` o una instancia a un `Translated_Material`; `landscape_layers`
  da las capas de un material de Landscape. Lo traducido trae el `Material_Info` sin texturas, de
  qué está hecha la imagen de cada mapa, la tabla de valores, el programa si hace falta, el uso del
  color de vértice, las expresiones sin traducir por clase y `notes` (lo que se aproximó o quedó
  afuera, y por qué).

### Lectura

- **Cadena.** De la instancia al `Material` por `Parent`: valores escalares, vectoriales y de
  textura, switches y máscaras estáticas con `bOverride` y `BasePropertyOverrides`. Gana la
  instancia más cercana. Un parámetro es del material o de una capa o blend de su pila de capas
  (`Layer_Ref`, la asociación e índice de su `ParameterInfo`).
- **Capas de material** (`MaterialAttributeLayers`): la pila de la instancia más cercana que la
  cambia, o la del nodo (`DefaultLayers`). Cada capa encendida es su función en un scope con los
  parámetros de esa capa, la primera sobre la entrada del nodo, y cada siguiente va sobre lo de
  abajo por su blend (`Bottom` y `Top`, o sus dos primeras entradas de material attributes); sin
  blend, la cubre. Una función de capa instanciada aporta sus valores a esa capa, detrás de los de
  las instancias del material.
- **Entradas.** Las del material o, en UE5, las de su `MaterialEditorOnlyData`, nativas o tagged
  según la versión; una propiedad que no se guardó vale lo que el constructor de la clase.
- **Expresiones.** Cada clase es un caso de `expression_build`, con la semántica de
  `MaterialExpressionsToMIR` de Unreal: el valor entero, y la máscara de la entrada elige los
  canales. Las funciones se expanden donde se llaman; las colecciones de parámetros dan su default;
  reroutes y switches de calidad y de nivel de features toman su entrada por defecto, y los de
  texturas virtuales, la rama sin ellas; los material attributes son filas de atributos, y
  `SetMaterialAttributes` cambia las suyas sobre las de `Inputs[0]`. Un alfa de `Lerp` de otro
  ancho que sus extremos vale su primer componente, como en Unreal.
- **Tabla de valores** (`Graph`): un nodo por operación sobre nodos anteriores, de uno a cuatro
  componentes; nodos iguales son uno y las constantes se pliegan al agregarse. Los valores del
  contexto son UV, tiempo, posición y normales del mundo, el marco tangente, colores de vértice, el
  objeto (centro, radio y esquinas de sus bounds, pivote y ejes con su escala), el punto en la
  imagen de la vista y su profundidad, y la de la escena detrás: `Transform` entre tangente, objeto
  (o instancia) y mundo y `TransformPosition` entre objeto y mundo son un programa con ese marco y
  esos ejes; `LocalPosition` es el punto en el espacio del objeto, `ObjectOrientation` su Z local
  y `ObjectScale`, el largo de sus ejes;
  `ObjectBounds`, `Bounds` y `ObjectLocalBounds` salen de las esquinas y los ejes.
- **El mundo desde su centro.** Un lugar del mundo (`WorldPosition`, el centro y el pivote del
  objeto, las coordenadas de una Landscape entera) es el relativo al origen del render más el
  origen (`Origin`), y restar dos lugares quita el origen que comparten
  ([decisión](decisions.md#materiales-de-unreal-lo-que-el-programa-ve-de-la-pantalla-el-mundo-y-el-hlsl)):
  no salta cuando el origen se mueve.
- **Pantalla y profundidad.** `ScreenPosition` (UV de la vista y píxeles), `ViewSize`,
  `SceneTexelSize`, `PixelDepth`, `SceneDepth` en su punto y `DepthFade`; la escena detrás la ven
  las pasadas de vidrio y translúcidos.
- **Lo que solo calcula un programa** (`PROGRAM` del grafo): `Noise` y `VectorNoise`, que llaman a
  `shaders/include/unreal_noise.slang` (las funciones de ruido de Unreal una vez, con las de tabla
  sobre gradientes por hash); `TextureProperty`, el tamaño de la textura en la GPU; y `Custom`, su
  HLSL como función del programa con sus entradas y sus salidas extra. El HLSL que lee lo que un
  programa no tiene (`View.`, `Primitive.`, `Parameters.`, derivadas, `discard`, includes, una
  función de los shaders de Unreal que no define ni es de HLSL o de su ruido) queda
  en el programa como comentario con lo que lee, para que el agente lo porte a Slang; su función da
  cero y la expresión se cuenta sin traducir.
- **Lo que no se traduce** deja `NONE`, se cuenta por clase en `untranslated` y la salida que lo
  usa toma el valor de Unreal sin conectar: lo que un programa de Mirai no ve (cámara, la imagen
  detrás, partículas, campos de distancia: `SceneColor`, `SceneTexture`, `ViewProperty` y
  `SceneDepth` con coordenadas propias), sets de UV después del segundo (datos de animación de
  vértices) y dominios que no son superficies (`Error`). Las salidas que la traducción no lee
  (posición, tangente, subsurface, profundidad) no se evalúan, y `WorldPositionOffset` tampoco:
  un material de Mirai no mueve sus vértices (el motor deforma superficies con tres mecanismos
  fijos).
- **Aproximaciones** (en `notes`): `ActorPositionWS` es el pivote del objeto; `PerInstanceRandom`
  es 0,5; `VertexInterpolator` pasa su entrada, calculada por píxel; `TwoSidedSign` es 1 (Mirai da
  vuelta el marco de una cara de atrás); `Fresnel` vale su reflexión en incidencia normal, y la
  vista
  (`CameraVectorWS`, `ReflectionVectorWS`, la dirección a `CameraPositionWS`) es la normal: Mirai
  refleja por la vista y lo que la imita ve la superficie de frente; `EyeAdaptationInverse` es 1
  y deja la emisión relativa a la exposición (`Relative`); los modos
  de mip de una muestra se dejan a Mirai; blend aditivo es una capa que no cubre.
- **Lo legacy se adapta.** El relieve por la vista (`BumpOffset` y la función
  `ParallaxOcclusionMapping` de `/Engine`) es la superficie sin relieve: sus UV son las que recibe,
  sin desplazamiento de profundidad ni sombra propia. `FuzzyShading`, que aclara los bordes de una
  tela por la vista, es su núcleo como color y sus bordes como `fuzz` de ese color, con
  `EdgeBrightness` de peso.

### Traducción

- **Modelo estándar.** Cada salida es un factor constante por una parte por texel cuyas muestras
  leen la misma coordenada, afín en un set de UV
  ([decisión](decisions.md#materiales-de-unreal-el-modelo-estándar-primero-un-programa-para-lo-demás)):
  el factor es el valor del material y la parte, la imagen del mapa, con la escala y el
  desplazamiento de la coordenada. Color y opacidad comparten el mapa de color; roughness (verde),
  metallic (azul) y oclusión (rojo, si lee las mismas coordenadas) comparten una imagen.
- **Unidades.** Base color y emisión son lineales; la emisión es luminancia en nits. Specular `s`
  es F0 = 0,08·s: un IOR desde F0 2 % y, debajo, el IOR de 2 % con `specular_factor`; un specular
  con textura es el mapa de specular sobre el IOR de F0 0,08.
- **Normal.** Una normal map leída tal cual o la función por texel horneada; un `lerp` desde la
  normal plana es `normal_scale`.
- **Shading models.** Unlit es `unlit` con su emisión; clear coat, un coat de IOR 1,5; cloth, fuzz
  (`SubsurfaceColor` el color, `ClearCoat` el peso). `TwoSidedFoliage`, y `Subsurface` o
  `PreintegratedSkin` en un material `TwoSided` (una lámina), son transmisión difusa: Unreal
  refleja el base color `b` y suma lo que `SubsurfaceColor` `s` deja pasar desde atrás, y Mirai
  reparte la misma luz con peso `max(s) / (max(s) + max(b))` y los dos colores divididos por su
  parte, escalados a lo que la superficie recibe si suman más (`diffuse_transmission_split`). Sobre
  un sólido, `Subsurface` y `PreintegratedSkin` se iluminan opacos con la luz que dispersan sumada
  al base color (`SUBSURFACE_BACKSCATTER`); `SubsurfaceProfile` se ilumina opaco: el renderer no
  tiene subsurface. Translúcido con
  refracción mayor que 1 es vidrio con ese IOR.
- **Colores de vértice.** Un base color del modelo estándar multiplicado por ellos los saca
  (`Multiply_Base_Color`), porque ese modelo los multiplica siempre; un programa los lee como dato
  (`ctx.vertex_color`) con su base color entero (`Program`); `Unused` dice que una malla los puede
  descartar.
- **Partículas.** `DynamicParameter` (de índice `ParameterIndex`) lee lo que da la partícula del
  sprite que dibuja el punto (`ctx.particle_data`), y su `DefaultValue` donde no lo da, como
  `GetDynamicParameter` de Unreal; el puente `unreal_vfx` lo pasa desde los atributos de Niagara.
  `ParticleRandom` es el valor al azar de la partícula (`ctx.particle_random`) y `ParticleRadius`
  la mitad de su sprite (`ctx.particle_radius`).
  `ParticleColor` es el color de la partícula, que el sprite da a su programa como
  `ctx.vertex_color` y no multiplica, como Unreal.
- **Programa.** Si una salida no cabe, el material entero es un programa Surface escrito de la
  tabla (`slang.odin`): texturas y parámetros de Unreal son sus parámetros (los que pasan del límite
  quedan constantes), posición y normales pasan a centímetros y Z arriba, las normal maps se
  desempaquetan y la normal tangente va al mundo con el marco de MikkTSpace. Su nombre es el
  material base y un hash de lo que calcula: las instancias que solo cambian valores comparten
  programa.
- **Texturas que se escriben mientras corre el juego.** Un render target que escribe una grilla, o
  un parámetro de textura que Unreal llena en ejecución (los buffers de FluidNinja), no tiene
  imagen: `Options.reads` nombra cada uno por su ruta de objeto o por el nombre del parámetro, con
  la función que lo lee por UV y su include, que da el plugin que lo escribe
  (`vfx_world_texture_uv` de su grilla). El programa llama esa función donde Unreal muestrea; la
  textura no es un parámetro del programa. Sin una lectura, el parámetro vacío no se traduce.
- **Landscape.** `landscape_layers` evalúa el grafo una vez por capa
  ([decisión](decisions.md#materiales-de-unreal-el-modelo-estándar-primero-un-programa-para-lo-demás));
  `LandscapeLayerCoords` es el UV 0 de la Landscape con su escala, giro y desplazamiento, y
  `LandscapeVisibilityMask` es 1: los agujeros son del terreno. Sin capa, `translate` muestra la
  primera.
- **Landscape entero** (`Options.landscape`, un `Landscape_Mapping`): el programa que el terreno
  muestra con sus capas. Cada capa pesa lo que la capa del terreno que la muestra (`uv0` y `uv1`
  del terreno, `Layer_Weights`) y una que el terreno no tiene queda afuera, como una que un
  componente no pinta; `LandscapeLayerBlend` suma las de peso y de altura sobre su suma cuando pasa
  de 1 y pone encima las de alfa, como Unreal sin
  `landscape.UseLegacyLayerBlendMaterialExpressionBehavior`. Las coordenadas de la Landscape (todo
  set de
  UV) salen de la posición en el mundo por la transformada del actor, y el marco tangente sigue sus
  ejes sobre la normal, no las tangentes del terreno.
  Lo que solo lee una capa (su entrada y su altura) se calcula donde la capa está pintada: un nodo
  `Gate` del grafo, que el programa escribe como una rama sobre el peso que junta todo lo de esa
  capa. Sin peso, la entrada es cero (o el default de cada atributo) y la altura cero: lo que Unreal
  suma de una capa sin pintar, salvo el peso mínimo (`0.0001`) de una de altura.

### Escritura (`material/write`)

- `Builder` lee cada textura de Unreal una vez y arma las imágenes por clave: una textura leída tal
  cual con el uso de su mapa se comparte entre materiales; si no, `image_bake` evalúa la tabla en
  cada texel al tamaño de la textura más grande que lee, bilineal y repitiendo, y una emisión mayor
  que 1 pasa al factor. Una imagen horneada lleva el nombre del material que la usa y el corte de
  alfa de su base color es el del material: lo que escribe un paquete no depende de qué paquete
  del nivel compartió antes el `Builder`.
- `reader_material` agrega el material y sus imágenes al `Reader` de un formato (para los slots de
  una malla); las notas son advertencias del modelo. `materials_write` escribe `.mat` y `.tex` con
  `importer.import_write`, como una importación de la fuente, y cada programa en `shaders` sin
  reescribir uno igual.

## Niveles (`level`)

Contrato compartido del importador de niveles: qué hay en un `.umap` y dónde está, en el espacio de
Mirai. Los nombres de Unreal (clases, propiedades) quedan en los traductores de cada tipo.

- **Biblioteca.** `Library` abre paquetes por nombre largo a través de `Source_Mount`, una vez; un
  paquete que falla guarda su error. Hace falta para los arquetipos de Blueprints y los actores
  externos.
- **Documento.** `document_open` lee cada `ULevel` (también el array viejo de actores), los actores
  y los objetos cuyo outer es cada actor, contiguos por actor, con `AttachParent` y
  `AttachSocketName`. Todo se nombra por índices; un objeto es un `Ref{pkg,object}`.
- **Actores externos.** Con `bUseExternalActors` (World Partition) se suman los paquetes de
  `__ExternalActors__/<ruta del mapa>/` cuyo outer es su `PersistentLevel`; sin el mount de su
  contenido, un error lo pide. Dos paquetes con un actor de la misma ruta (uno que quedó al mover
  el actor o al copiar contenido encima) son uno solo, como en el registro de assets de Unreal: el
  que se llama por el hash de esa ruta (MD5 de la ruta en minúsculas, en base 36, partido 1/2/22 o
  2/2/21) o, si ninguno, el primero por nombre; los demás quedan en `superseded` y la importación
  lo avisa.
- **Propiedades por arquetipo.** `property` busca en el objeto y después en sus arquetipos, también
  de otros paquetes, y dice el origen: `Authored`, `Archetype` o `Native` (los defaults de la clase
  nativa, que aplica quien lee). Sin template guardado, como en la mayoría de los subobjetos de
  UE4, el arquetipo es el que busca Unreal
  ([decisión](decisions.md#niveles-landscapes-y-follaje-de-unreal)): el objeto de su nombre bajo el
  arquetipo de su outer y, si no, lo que se encuentra subiendo por la clase Blueprint
  y sus super clases Blueprint: la plantilla del `SCS_Node` de esa variable; si la clase no tiene
  ese nodo, la que su `InheritableComponentHandler` guarda para un componente heredado que cambia
  (el registro cuyo `FComponentKey` nombra la variable, o cuya plantilla se llama así); si no, un
  objeto de ese nombre bajo la clase. Una de esas plantillas heredadas tiene por arquetipo el objeto
  de su nombre en la super clase más cercana que lo tenga (la de una `DefaultSceneRoot`, sin su
  prefijo `ICH-`).
- **Transforms.** `SPACE` es el espacio de Unreal para el importador del motor. `component_relative`
  da los
  valores de Unreal con los defaults de `USceneComponent` o del constructor nativo del actor
  (`NATIVE_RELATIVES`: luces direccionales y spot, decals y la malla de `DefaultPawn`; ninguna otra
  clase nativa de ContentExamples mueve un subobjeto que no es del editor); `component_local` y
  `component_world` los dan en Mirai, el segundo compuesto por `AttachParent` con las partes
  absolutas tal cual.
- **Sockets** (`sockets.odin`). Un componente con `AttachSocketName` es relativo a donde está ese
  socket de su padre (`component_socket`, como en Unreal): de una static mesh, su
  `StaticMeshSocket`; de una skeletal mesh, su socket o el de su esqueleto (primero el de la malla)
  sobre su hueso, o el hueso de ese nombre, en la pose de bind de la malla; del
  `SpringArmComponent`,
  `SpringEndpoint`: el brazo en reposo, sin el retraso ni el barrido de colisión que hace un juego,
  y con la rotación del actor si sigue la del pawn. Los nombres se comparan sin mayúsculas; uno que
  el padre no tiene es el padre, como en Unreal. Las mallas y esqueletos se leen una vez por
  documento; uno que no se lee, un socket de una spline mesh (que se curva con ella) y un brazo que
  no hereda pitch, yaw o roll son errores del lugar del componente.
- `resolve` da el export de una referencia, abriendo su paquete si es un import;
  `actor_native_class`, la clase nativa de la que deriva un actor a través de sus Blueprints.
- **World Partition** (`partition.odin`). `partition_read` da las celdas de las grillas de un
  `WorldPartitionRuntimeHashSet` (UE 5.4 en adelante; el `RuntimeSpatialHash` anterior es
  `Unsupported_Value`): por cada `RuntimePartitionLHGrid`, su tamaño de celda, origen, 2D o 3D,
  rango de carga y método de la caja; una `RuntimePartitionPersistent` carga con el mapa. Un actor
  con `bIsSpatiallyLoaded` (por su arquetipo o el default de su clase nativa: luces, `AInfo` y las
  que lo apagan en su constructor) va a la celda de su grilla (`RuntimeGrid`, o la primera) que
  tiene el centro de sus bounds, en el nivel de la jerarquía suelta que pide su tamaño, y se
  nombra como en Unreal
  (`<grilla>_L<nivel>_X<x>_Y<y>_Z<z>`). La caja de una celda en el nivel 0 es lo que tiene dentro de
  la celda (o la celda, o lo que tiene, según su grilla); arriba, lo que tiene.
- Los bounds de un actor son los de sus componentes primitivos que no son del editor: la malla por
  los bounds que guarda su paquete (`ExtendedBounds`), cada instancia de uno instanciado, un spline
  mesh por el casco de su curva, un componente de Landscape por su `CachedLocalBox` y las formas
  por su tamaño; sin ninguno, el punto donde está. Unreal usa los que su editor guardó en el
  descriptor del actor, que no se lee: un actor junto al borde puede caer en la celda vecina. Los
  data layers y los conjuntos de actores no separan celdas.
- Aproximaciones: la composición con escalas negativas se hace por partes; los niveles de streaming
  son otros mapas.

## Landscape (`landscape`)

`landscapes_read` da un `Landscape` por `LandscapeGuid`: los proxies de esa guía y sus componentes,
en una grilla.

- **Grilla.** El rectángulo de los `SectionBase`. La x de Mirai corre por la -Y de Unreal y la z por
  su X, y cada celda de un Heightfield se parte por la misma diagonal que Unreal usa en su quad.
- **Alturas.** De `HeightmapTexture` (16 bits en R y G) con su offset y sus subsecciones, que
  repiten los vértices del borde, en metros por la escala Z del actor; una textura compartida se
  decodifica una vez.
- **Espaciado.** `spacing` es la escala X del actor (a lo largo de la z de Mirai) y `transform`,
  el centro de la grilla en el mundo: la grilla es de celdas cuadradas, y una escala Y distinta la
  estira a lo ancho, en la escala x de `transform` (Y sobre X;
  [decisión](decisions.md#niveles-landscapes-y-follaje-de-unreal)).
- **Capas.** El peso de cada `LandscapeLayerInfoObject` por muestra, como Unreal los pinta (sin
  normalizar), con su cobertura; el nombre es su `LayerName` si la layer info está bajo un mount y,
  si no, el del objeto.
- **Agujeros.** La capa de visibilidad no es una capa: un quad es agujero cuando su primer vértice
  pesa más que el umbral de la colisión de Unreal, y también los del rectángulo sin componente.
- Rechazos: componentes de tamaños distintos, subsecciones inválidas, heightmap ausente, escalas X o
  Y nulas o negativas. Las capas de edición se leen ya combinadas, como Unreal las guarda; el
  material es la ruta de `LandscapeMaterial` del proxy.
- `landscape_terrain` (plugin `unreal_terrain`) lo convierte a una fuente Heightfield:
  [terreno](translators.md#terreno-unreal_terrain).

## Follaje (`foliage`)

`foliage_read` da un `Foliage` por `InstancedFoliageActor`: sus tipos y sus instancias en el
espacio de Mirai.

- **Datos nativos.** Los del actor van después de lo que guarda `AActor`, que desde
  `SerializeActorLabelInCookedBuilds` dice si se cocinó (`level.actor_native_payload`; uno cocinado
  se rechaza).
- **Instancias.** Del registro que el editor guarda de cada tipo (`FoliageInfos` o, en versiones
  viejas, `FoliageMeshes`): transform de mundo, si se puso sobre algo, el componente sobre el que se
  puso y su altura sobre ese punto (`ZOffset` por su escala, a lo largo de su arriba). Las borradas
  no salen.
- **Clases de tipo** (`Foliage_Kind`, el `EFoliageImplType` de cada uno). `Static_Mesh` nombra el
  componente que lo dibuja. `Actor` (`FoliageType_Actor`) puso en cada instancia un actor de su
  clase, que el nivel guarda entre sus actores: `Instance.actor` lo nombra (-1 si no está, y el
  editor de Unreal lo pone de nuevo). `ISM_Actor` (el mismo tipo con `bStaticMeshOnly`) dibuja las
  static meshes de su clase con componentes instanciados del `InstancedFoliageActor`, uno por malla
  y ajustes, compartidos por esos tipos: `Foliage.components` son los de sus `DescriptorComponents`.
  Los tipos de actores se nombran por la clase que ponen.
- **Comprobación.** Cada instancia de static mesh se compara con la matriz del componente que la
  dibuja, en el mismo orden (`compared`, `mismatched`, `max_difference`; `uncompared` si el
  componente no está en el origen o su formato es desconocido).
- **Tipos.** De `FoliageType_InstancedStaticMesh` o `FoliageType_Actor`, del actor o de otro
  paquete, con los defaults del constructor de `UFoliageType`. Las bases con `TSoftObjectPtr` se
  saltan según su versión; sin un corpus que lo use, ese camino no está comprobado, como los tipos
  de actores y de ISM actors (ContentExamples no los tiene).
- `foliage_source` (plugin `unreal_foliage`) lo convierte a una fuente `.foliage`:
  [follaje](translators.md#follaje-unreal_foliage).

## Niveles a escena (`scene`)

`level_import` (paquete `unreal_scene`) escribe un `.umap` como una escena del proyecto en
`opciones.root`, que tiene que ser un proyecto (`project.mirai`); `document_import` hace lo mismo
con un `level.Document` abierto. `Level_Report` trae lo escrito, los actores por clase (cuántos y
cuántos se tradujeron), las luces con su valor de Unreal y el de Mirai, las cámaras con su entidad,
las mallas importadas y el tiempo.

- **Montajes.** Los de [`model`](#formato-de-modelos-model): `/Game` del `.uproject` (o del
  nombre que el mapa guarda de sí mismo), `/Engine` de la instalación de Unreal y los plugins de
  esa instalación. Sin `/Engine` montado (`engine.odin`), una forma básica de Unreal es la
  primitiva de Mirai de su `Mesh_Renderer` y un material de `/Engine` que falta, la grilla del
  motor, escrita con los materiales que el nivel guarda en `levels/<mapa>/`
  ([decisión](decisions.md#engine-sin-unreal-sustitutos-propios-del-motor)).
- **Nombres.** Lo que se importa de Unreal se nombra sin el prefijo que sus convenciones dan a cada
  tipo (`SM_`, `SK_`, `M_`, `MI_`, `T_`, `BP_`…): `asset_name` es el único lugar que los conoce.
  `SM_Rock.uasset` escribe `Rock.mesh` y `Rock.prefab` en `models/Rock/` (`model_folder`),
  y un material `MI_Rock`, `Rock.mat`; dos que quedan iguales en una carpeta toman `(2)`. Lo que
  se busca dentro de un paquete sigue usando el nombre de Unreal.
- **Archivos.** La escena en `levels/<mapa>.scene` de los assets; cada `StaticMesh` que el nivel
  nombra es la importación de su paquete, como la da el formato `model` (malla, materiales de sus
  slots, texturas y prefab, en `models/<paquete sin prefijo>/`); los materiales que un componente
  sobrescribe, la importación de su paquete en `materials/`; lo que escriben los plugins, en
  `levels/<mapa>/`. Una sola `material.Library` y un solo `write.Builder` sirven a todo el nivel:
  cada paquete se abre y cada textura se decodifica una vez, mientras la memoria alcance. Los
  paquetes de las mallas y los materiales sobrescritos se leen adelantados
  ([lectura adelantada](#lectura-adelantada)).
- **Identidad.** La escena es la raíz de la importación del mapa (`importer.output_root`) y las
  secciones y lo que escriben los plugins, sus partes por nombre (`importer.output_part`). Las
  secciones toman archivo e id al escribirse, solo las que tienen algo y todas a la vez
  (`importer.output_parts`): cada una encuentra primero la anterior de su nombre. El id de
  cada entidad es el hash de la ruta de su actor en el mapa (con su paquete si es externo: dos
  paquetes de World Partition pueden tener actores del mismo nombre) y del nombre de su
  componente, que Unreal conserva aunque cambie el label: reimportar da la misma escena con los
  mismos ids ([decisión](decisions.md#niveles-de-unreal-a-escenas-de-mirai)).
- **Secciones.** Un mapa de World Partition es la escena del mapa y una escena por celda
  ([partición](#niveles-level)) en `levels/<mapa>/<celda>.scene`, cada una referenciada
  desde la escena del mapa por una entidad con el nombre de la celda, en el centro de su caja, con
  un `Scene_Reference` `Spatial` de esa caja: el plugin `streaming` la carga por dónde están los
  jugadores. Lo que está en la raíz de una sección está donde está desde ese centro. Lo que carga
  con el mapa, lo que el nivel da una vez (cielo, exposición) y lo de los traductores con `root`
  (el terreno, que carga sus páginas solo) queda en la escena del mapa; una celda que no da nada no
  se escribe. El rango de carga de cada grilla es un aviso: Mirai carga las secciones dentro de las
  distancias de `Streaming_Settings` del proyecto
  ([decisión](decisions.md#world-partition-una-sección-por-celda)).
- **Entidades.** Un actor que muestra algo es una entidad con su label donde está su
  `RootComponent`, y lo que muestra cada componente, una entidad hija con su lugar relativo al actor
  (`transform_relative`, exacto para la composición de Mirai). Un actor de un solo componente es
  esa entidad, sin un grupo encima. Los actores van a la raíz de la escena.
- **Blueprints.** Los actores de una clase Blueprint son instancias de un prefab de la clase en
  `levels/<mapa>/`, hecho de las entidades del primero con la raíz en el origen y el nombre de la
  clase. Lo que cada actor muestra distinto (lo que eligió su construction script, sus
  transforms, su label) son overrides de su instancia, y editar el prefab cambia todos. Un actor
  cuyos componentes no son los del primero queda aparte, con una advertencia.
- **Mallas.** `StaticMeshComponent` es `Mesh_Renderer` con la malla importada y, por fila de slot,
  el material de `OverrideMaterials[índice]` (el id del slot es el índice de Unreal más uno); uno
  igual al de la malla, o de un slot que la malla no dibuja, no cuenta.
  Un material que el nivel guarda dentro de un actor (la `MaterialInstanceDynamic` de un
  construction script) se traduce de su `.umap`, se nombra por los objetos que lo contienen y va a
  `levels/<mapa>/`, junto con los demás del nivel en una sola importación al terminarlo, después
  de los traductores: lee por UV las texturas que ellos agregaron (`texture_read_add`, el render
  target que un componente de Niagara da a su sistema).
  Los componentes instanciados (`InstancedStaticMeshComponent`, el jerárquico y el de follaje, y
  los que hornean PCG y los packed level actors) nunca son una entidad por instancia: los toma el
  traductor con `instanced` de su escena, el de `foliage`, como lotes de follaje
  ([follaje](translators.md#follaje-unreal_foliage)); sin él, su
  actor es un aviso que dice cómo importarlo. Los ocultos en el juego quedan afuera, con un aviso.
  Las matrices de sus instancias salen del arreglo `PerInstanceSMData` de su payload nativo, que va
  después de lo que guarda `UStaticMeshComponent` (LODs y vértices pintados, de largo variable
  según el save): se lo encuentra por el tamaño, la cantidad y una primera matriz de vectores fila
  (`level.instances_read`, que también usa la comprobación del follaje). Un
  `SplineMeshComponent` no se traduce: es un aviso
  ([decisión](decisions.md#world-partition-una-sección-por-celda)).
  `SkeletalMeshComponent` (de un `SkeletalMeshActor` o de cualquier Blueprint, como un personaje)
  es lo mismo con la malla con skin (`SkeletalMesh`, que gana como en Unreal, o `SkinnedAsset`),
  dibujada en su pose de bind como la dibuja
  el prefab de su importación. En
  `AnimationSingleNode` reproduce el clip de la `AnimSequence` de su `AnimationData` (la
  importación de su paquete en `models/<paquete>/`): `Animation` con `bSavedLooping`,
  `bSavedPlaying`, `SavedPlayRate` como `speed` y `bUpdateAnimationInEditor` como `preview`, y
  `SavedPosition` como su `Animation_Progress` (sobre el `RateScale` que tienen los tiempos del
  clip). La instancia de un solo nodo no saca root motion de una secuencia: una que fuerza su
  `bForceRootLock` queda en el lugar (`In_Place`). Un Animation Blueprint (`AnimClass`) es lógica:
  una advertencia y la pose de bind. `bVisible` falso o `bHiddenInGame` son `Hidden`; `bHidden`
  del actor, `Hidden` en su entidad.
- **Luces** (`lights.odin`). Unreal alumbra con una
  intensidad por 100²; Mirai guarda candelas en una puntual o spot, la luminancia de la cara en un
  rectángulo y lux en el sol, y divide por π donde su renderer lo pide:
  - candelas tal cual; lúmenes de una puntual sobre 4π y de una spot sobre su cono, 2π(1−cos θ),
    con θ el medio ángulo exterior acotado como en Unreal; sin unidad, ×16/100²; EV100,
    2^EV; nits de una puntual por el área de su cápsula (`SourceRadius`, `SourceLength`);
  - un rectángulo: nits tal cual y lo demás sobre su área (`SourceWidth`×`SourceHeight`), que es
    la escala de su entidad; un rectángulo guardado con EV antes de
    `RectLightFixedEVUnitConversion` conserva la cuenta vieja de Unreal;
  - el color es `LightColor` en lineal por `ColorTemperatureToLinear` con `bUseTemperature`; un
    canal mayor que uno pasa a la intensidad. `AttenuationRadius` es `range` y `SourceRadius`,
    `radius`. Unreal alumbra hacia +X del componente y Mirai hacia -Z: la entidad gira media
    vuelta en Y y tiene escala uno. `bAffectsWorld` falso deja el componente apagado.
  - Se avisa, con cantidad: sin caída cuadrática (las candelas que dan lo mismo a la mitad del
    radio), `SourceLength`, IES, light functions, sin sombras y conos fuera de 1° a 89°.
  - Mirai alumbra con un sol: con varios direccionales queda encendido el más brillante.
- **Cámaras.** `CameraComponent` y `CineCameraComponent` son `Camera` en una entidad con el label
  del actor (`Camera_Note.entity` es lo que toma `mirai capture --camera-entity`). Fov vertical:
  de una cine, el de la altura del sensor (`Filmback`) y `CurrentFocalLength`; de otra, el de
  `FieldOfView` horizontal y `AspectRatio`. `active` si el actor se activa para un jugador. Lo que
  sus `PostProcessSettings` sobrescriben de exposición es su `Exposure`.
- **Cielo y exposición.** El nivel da una entidad `Sky`. Sin `SkyLight` no alumbra, como en Unreal;
  con uno, alumbra por su `Intensity` y su color con la proporción entre cielo y sol del `Sky` de
  Mirai, tomada del sol más brillante del nivel, y un aviso: lo que Unreal captura de la escena no
  tiene equivalente. Con `SLS_SpecifiedCubemap`, la imagen del `Sky` es su `Cubemap` vuelto en la
  importación una imagen de longitud y latitud (`sky_of_cube`, un `.tex` junto a los materiales,
  importación del paquete del cubo), y su entidad gira por `SourceCubemapAngle` alrededor de
  arriba, como Unreal gira el cubo. Detrás de la escena se ve el cielo si el nivel lo dibuja
  (`SkyAtmosphere`, `AtmosphericFog` o la esfera de cielo del motor), y si no, negro; con una
  atmósfera, el `Sky` es el aire que alumbra el sol (`atmosphere`), salvo que el `SkyLight` nombre
  un cubo: el `Sky` de Mirai dibuja la imagen o el aire, y gana el cubo, con un aviso. `VolumetricCloud` es un aviso: Mirai no dibuja nubes.
  Un `PostProcessVolume` sin límites (el de más prioridad) da la exposición del `Sky`: método
  (manual o automático), compensación, velocidad de adaptación, la cámara física (f, obturador e
  ISO) y el brillo mínimo y máximo, que Unreal lleva a blanco y Mirai a gris medio: el EV100 que da
  blanco esa luminancia
  (EV100 de Unreal sobre `LuminanceMax` si el proyecto extiende el rango, luminancia como UE4 si
  no). El resto de lo que sobrescribe y un volumen con límites son avisos; las `ReflectionCapture`,
  que la GI reemplaza, lo que solo usa el editor de Unreal, el HLOD de World Partition (el de Mirai
  se hace por celda), los minimapas, `GPULightmass`, los volúmenes de texturas virtuales (sus capas
  son las del terreno), los componentes Nanite y proxy de un Landscape, el grafo de PCG y el nivel
  de un packed level actor (sus instancias lo muestran) se omiten sin aviso.
- **Textos.** `TextRenderComponent` es un `World_Widget` fijo en la entidad del componente, que
  mira hacia donde mira el texto en Unreal (su +X, el +Z de Mirai), con un `.ui` propio en
  `levels/<mapa>/`: una línea mide `WorldSize` por `YScale`, en su color, alineado como lo alinea
  Unreal y con `<br>` como salto de línea; los textos iguales comparten el `.ui`. `TextProperty`
  se lee como el texto que muestra en la cultura de origen (historias `None` y `Base`).
- **Traductores de plugins.** Un `Translator` toma los actores de sus clases nativas, una escena
  a la vez, y lo da un plugin puente `unreal_*` ([traductores](translators.md)): terreno, follaje,
  física, niebla, partículas, navegación y las texturas de los fluidos. Sin el puente de una
  clase, sus actores son avisos que dicen qué plugin activar, y las mallas quedan sin colisión.
- **Lo que no se traduce** es un aviso por clase con su cantidad: sonidos, BSP,
  Blueprints que no muestran nada que Mirai traduzca, y los componentes sin traducción de actores
  traducidos. Los avisos repetidos por las importaciones
  de las mallas se dan una vez.

### Lectura adelantada

Con un job system en `Import_Options.worker`, los paquetes de las mallas que el nivel nombra
(`reads.odin`) se leen y se construyen (`importer.model_cook`) en jobs mientras el nivel se traduce,
en el orden en que la traducción los pide: de cada escena, las mallas de sus actores y después los
componentes instanciados, si un traductor los toma. Tras la malla de un componente van los
materiales de otros paquetes que sobrescribe: un job los traduce y arma sus imágenes en el
`Builder` del nivel, donde la traducción encuentra sus texturas decodificadas. La traducción
escribe cada uno, con sus ids, cuando llega a él, uno tras otro: lo escrito es lo mismo que sin leer
adelantado.

- **Piso de memoria.** La importación de un nivel deja libre `MEMORY_FLOOR` de la memoria de la
  máquina, medida al momento (`base.memory_stats`). Una lectura empieza si la memoria disponible,
  menos lo que se estima que tomarán todavía las que corren (`READ_COST` bytes por byte de
  paquete), queda sobre el piso, y no corren más que workers; un paquete que no empieza lo lee la
  traducción cuando llega a él, después de escribir y soltar los anteriores y, bajo el piso,
  después de soltar las imágenes y de que terminen las lecturas que corren. Con la memoria bajo
  el piso, el `Builder` suelta sus imágenes antes de armar materiales si nadie está afuera
  (`builder_room`), y el nivel, entre importaciones, después de los jobs que decodifican
  (`builder_settle`); las texturas se decodifican de nuevo, de a una mientras falte memoria. Nunca
  falla por memoria: va más lento. Si el sistema no dice cuánta hay, no hay piso.
- Un paquete pedido antes de su turno se lee en el acto. Los empezados antes del pedido, que la
  traducción pasó de largo, dejan de ocupar un worker: si no, la lectura adelantada se para. No se
  leen los paquetes de lo que la traducción no pide (actores silenciosos o solo de editor,
  instanciados ocultos).
- La traducción espera un paquete sin correr otros jobs: uno largo la demoraría.
- `c.lib` y `c.images` son de todos: quien los usa toma `c.library_lock`, nunca mientras espera un
  job. Los traductores tienen su propio decodificador de Oodle (`decoder(c)`).
- Una textura se decodifica sin el lock: el `Builder` lo suelta mientras la decodifica con el
  decodificador y la memoria de quien la pide, y lo toma de nuevo para guardar sus píxeles; quien
  pide una que otro decodifica espera por ella, y cada textura se decodifica una vez; lo que el
  `Builder` dice de una textura se lo dice a cada material que la usa. Mientras `builder_settle`
  espera, las texturas se decodifican con el lock. Sin lock (la importación de un paquete solo)
  decodifica igual, sin soltar nada.

## Diagnóstico (`inspect`)

El método de API `unreal.inspect` (plugin `unreal`, `api.odin`; paquete `inspect`) recorre
`.uasset` y `.umap` o una carpeta de ellos sin escribir assets y deja su informe en
`.mirai/tmp/unreal-inspect.txt` del proyecto. Sus parámetros están en `engine.describe`.

- `Summary`: versiones, tablas y exports; `Objects`, propiedades y cola nativa; `Payloads`, los
  payloads comprobados con BLAKE3.
- `Textures`, `Meshes`, `Skeletal`, `Anims` y `Materials` leen o construyen cada objeto de su tipo,
  con una línea por objeto y un resumen de aproximaciones y fallos por causa, y comparan lo que se
  puede comprobar: bounds contra `ExtendedBounds` o `ImportedBounds` (que el importador FBX de UE4
  guardaba agrandados), la descripción de una malla contra su modelo LOD, el `Id` de una textura.
  `out` (bajo `.mirai/tmp/`) recibe las PNG de `Textures` y los programas Slang de `Materials`,
  para `mirai shaders check`.
- `mounts` (`/Prefijo=carpeta`, varios): sin uno de `/Game` se deduce el más votado de los primeros
  paquetes, y sin uno de `/Engine`, la instalación que encuentra el importador
  (`engine_content_find`), para expandir sus funciones como él.
- `Level`: por cada `.umap`, actores y componentes por clase, transforms que fallan, de dónde sale
  cada `RelativeLocation`, la partición de World Partition (grillas, celdas por nivel, lo que carga
  con el mapa por clase y, por celda, sus actores, componentes instanciados, instancias y tipos de
  follaje por malla y materiales, sin el HLOD de Unreal), cada landscape y cada follaje con su
  comparación.
- `hi_res`: en `Meshes`, el modelo de alta resolución en lugar de LOD 0.

`ok` falso dice que algo falló; el informe dice qué.

## Verificación

Todas con `mirai test` sobre la carpeta del paquete dentro de un proyecto con el plugin
instalado.

- `editor/package`, `kraken` y `texture`: paquetes UE4/UE5 sintéticos, trailer, bulk
  data, zlib, un encoder mínimo de cada formato de Oodle (`kraken_test.odin`,
  `formats_test.odin`) y texturas UE4; el daño recorta y cambia bytes y cada intento decodifica o
  se rechaza.
- `editor/mesh`: los tres lugares del source model con secciones, materiales,
  colores, UV, normales por aristas suaves y duras, escala de build y daño; polígonos sin
  triángulos
  (`a_description_saved_before_triangles_takes_the_triangles_unreal_5_makes_of_its_polygons`);
  influencias y soldadura de una descripción con esqueleto
  (`a_description_keeps_the_influences_the_build_and_the_project_allow`,
  `a_description_welds_corners_within_the_thresholds_of_its_build`); mallas con esqueleto
  de cada layout (`skeletal_meshes_of_every_layout_read_their_skeleton_materials_and_lod_0`,
  `a_skeleton_reads_its_reference_skeleton_and_sockets`,
  `damaged_skeletal_meshes_are_read_or_refused`); animaciones de cada layout
  (`animations_of_every_layout_read_their_bone_tracks_curves_and_markers`,
  `additive_and_rate_scaled_animations_say_so`, `damaged_animations_are_read_or_refused`).
- `editor/model`: espacio, slots, materiales, montajes, esqueletos e inverse binds,
  morph targets y sockets, colisión de la fuente, el `/Engine` sin Unreal y clips de cada formato
  muestreados contra su fuente, `RateScale` y aditivos.
- `editor/material` y `material/write`: paquetes UE4 sintéticos
  (`material/fixture`) con un grafo estándar, entradas tagged, instancias con switches
  estáticos, funciones, capas de Landscape y de material, un programa, pantalla, profundidad,
  bounds, el mundo con su origen, `Custom`, ruido, clases sin traducir y bytes dañados; la
  escritura lee de vuelta `.mat` y `.tex` y reimporta sobre un parámetro cambiado.
- `editor/level`, `landscape` y `foliage`: espacio de Unreal
  contra `FRotationMatrix`, arquetipos de otro paquete y por SCS, plantillas heredadas
  (`an_inherited_component_a_blueprint_changes_takes_its_override_template`),
  defaults de constructores nativos, sockets (`sockets_test.odin`: de una static mesh, de una
  skeletal mesh y su esqueleto o un hueso, el fin de un spring arm), celdas de una grilla suelta
  (`an_actor_goes_to_the_cell_of_its_center_at_the_level_its_size_asks`,
  `a_map_of_world_partition_is_the_cells_of_its_grid_and_what_loads_with_it`), actores externos
  repetidos (`of_two_external_packages_with_the_same_actor_one_is_read`), grilla,
  subsecciones, capas, agujeros, escalas X e Y distintas
  (`a_landscape_scaled_differently_along_x_and_y_is_its_grid_stretched_across`), bases, tipos,
  follaje de actores y de ISM actors
  (`foliage_of_actors_and_of_ism_actors_names_the_actors_and_components_that_show_it`) y
  comparación del follaje.
- `editor/scene`: mapas sintéticos (`fixture/files.level_begin`) con malla y
  override, spot en lúmenes, cine camera, niebla de plugin, sonido, `Character` y
  `SkeletalMeshActor`
  (`a_skeletal_mesh_of_a_level_is_the_skinned_mesh_of_its_import_with_its_overrides`) y uno de World
  Partition (`a_map_of_world_partition_is_a_scene_that_references_a_section_for_each_cell`): la
  escena escrita, sus secciones, un traductor de prueba con los componentes instanciados de cada
  escena, reimportar con los mismos ids y las conversiones de luz.
- `editor`: la integración con el editor, con los formatos del plugin como los
  halla el editor (`Unreal_Format`, `Unreal_Maps`): una static mesh y una skeletal mesh como sus
  assets y prefab, paquetes dañados importados o rechazados, un mapa como escena del proyecto
  (`an_unreal_map_imports_as_a_scene_of_its_project`) y los programas Surface que una importación
  publica. Los traductores de los puentes: [traductores](translators.md#verificación).
- Corpus, sobre los proyectos de prueba: `unreal.inspect` con `Meshes`, `Skeletal` y `Anims` sin
  fallos salvo lo cocinado o lo que no dibuja nada y con los bounds coincidiendo; con `Skeletal`,
  cada descripción contra el modelo LOD que guardó (triángulos, bounds e influencias; un modelo LOD
  guardado en un proyecto con otros ajustes de influencias difiere en ellas); `Materials` con `out`
  y `mirai shaders check` de cada programa sin errores ni avisos; `Textures` con una build
  `-o:speed`, sin fallos ni `Differs` inesperados, comparando las PNG de `out` contra una
  exportación PNG de Unreal con `mirai image diff` (con el verde invertido de las normal maps);
  `Level` sin fallas de transforms, de la partición ni instancias de follaje distintas de su
  componente.
- Contra la verdad, Unreal en modo comando (`UnrealEditor-Cmd -run=pythonscript`) sobre una copia
  del proyecto exporta transforms, alturas e instancias; nunca es un camino de importación.
- `MIRAI_UNREAL_MAP` y `MIRAI_UNREAL_PROJECT` hacen que
  `an_unreal_map_of_the_environment_imports` (`editor`, con `--release`) importe un
  mapa del corpus con el importador de mapas, sin traductores; sin ellas no corre. Los traductores
  de los puentes se prueban sobre el corpus en una sesión del editor.
- Ningún asset real entra al repositorio; las fixtures son sintéticas.
