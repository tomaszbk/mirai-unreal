# Traductores de niveles de Unreal

Al importar un `.umap`, el importador de mapas del plugin `unreal` (`Unreal_Maps`) escribe la escena
con lo que Mirai traduce por sí mismo (mallas, luces, cámaras, cielo, textos;
[niveles a escena](unreal.md#niveles-a-escena-scene)) y deja los actores de dominios opcionales a
los traductores de plugins puente `unreal_*`. Cada puente es automático (`automatic: true`), solo
de editor, y depende de `unreal` y del plugin que traduce: un proyecto que tiene los dos lo recibe
sin declararlo ([decisión](decisions.md#niveles-de-unreal-a-escenas-de-mirai)).

## El contrato

`unreal_scene.Translator_Provider` es un storage de Editor cuyo único campo da los traductores que
su plugin sabe escribir; al importar un mapa, `map_prepare` junta los de todos los plugins de la
biblioteca vigente (`editor.provided_all`).

- Un `Translator` nombra clases nativas (de cualquier paquete `/Script`, como `Landscape` o
  `InstancedFoliageActor`) y su `translate(c, actores)` recibe los actores de ellas una escena a la
  vez: la del mapa y la sección de cada celda de World Partition (`c.section`, `section_origin`);
  devuelve cuántos tradujo y avisa de los demás. Los actores que un traductor toma no los traduce
  el importador. Con `root`, los de todas las celdas van a la escena del mapa, porque lo que escribe
  se carga solo por distancia (el terreno, por páginas). Con `instanced` recibe además, después de
  los actores, los componentes instanciados (`ISM`, `HISM`, follaje) que muestran los actores de
  la escena (`c.instanced`), aunque no tenga actores: sus instancias nunca son una entidad cada una.
  Lo que dice de cada escena lo cuenta `tally` y el nivel lo avisa una vez.
- Uno con `component` en lugar de `translate` nombra clases de componentes: `component(c, a, k, e)`
  agrega a la entidad `e` que el importador hizo del componente `k` del actor `a`. De una clase
  que el importador traduce (`StaticMeshComponent`), el importador sigue escribiendo lo que
  muestra y el plugin agrega lo que sabe (la colisión); de una que no (el `NiagaraComponent` de un
  Blueprint), la entidad es solo del plugin.
- Una textura que un sistema del plugin escribe mientras corre la leen los materiales por UV en
  lugar de una imagen ([materiales](unreal.md#traducción)): el traductor la agrega con
  `texture_read_add` (el render target que da un componente) para los materiales que el nivel
  guarda, y el provider da en `reads` las fijas (un parámetro de textura por su nombre), que el
  plugin `unreal` pasa a toda importación de Unreal: la de un mapa y la de un paquete como modelo.
- El `Context` da el documento del nivel (`c.d`), la biblioteca de paquetes y texturas del nivel
  (`c.lib`, `decoder`), `mesh_import`, `material_import` y `mesh_renderer` (la malla y los
  materiales de los slots de un componente) por ruta de objeto de Unreal, `mesh_body` (la colisión
  del `BodySetup` de una `StaticMesh`: formas simples en el espacio de la malla importada,
  `CollisionTraceFlag` y el perfil de su `DefaultInstance`), `layer_materials` (capas de un
  material de Landscape), `asset_place` y `asset_write` (el id, el archivo y el `Import_Info` de un
  asset del nivel, en `levels/<mapa>/`), `entity_make` (en la raíz de una sección, donde la pone el
  transform del mundo), `actor_entity`, `actor_key` y `component_set` (la escena), y `warn`.
- Un puente se declara como cualquier plugin de editor: un storage con el provider y su default
  (`Terrain_Unreal`, `Foliage_Unreal`, `Physics_Unreal`, `Fog_Unreal`, `Navigation_Unreal`,
  `Vfx_Unreal`, `Fluids_Unreal`). Sin el puente de una clase, sus actores son avisos que dicen qué
  plugin activar.

## Terreno (`unreal_terrain`)

Landscape, LandscapeProxy y LandscapeStreamingProxy, en la escena del mapa (`root`).
`landscape_terrain` (`landscape.odin`) escribe en una fuente Heightfield lo que da
[`landscape`](unreal.md#landscape-landscape) y devuelve el transform de la entidad que la muestra.

- Alturas, separación y agujeros pasan tal cual; `chunk_cells` es la subsección de Unreal salvo
  que las opciones digan otro. Las celdas son cuadradas: un landscape escalado distinto en X que
  en Y es la grilla de su escala X sobre una entidad estirada a lo ancho (la escala x del
  transform), que el dibujo, la colisión y la residencia ya componen.
- Las capas son las `LAYERS_MAX` de más peso total. Cada una de las demás suma su peso a la
  conservada con la que más se solapa (la suma de los mínimos de sus pesos por muestra; sin
  solape, la de más peso): un borde entre dos capas sigue siendo un borde y cada muestra conserva
  su peso entero. Una muestra sin peso queda en la primera capa.
- El material de cada capa es el `.mat` que el llamador da por capa de Unreal; `folded` dice a
  qué capa fue cada una.
- **Al importar un nivel**, el traductor de `Terrain_Unreal` escribe cada landscape (el actor y
  sus proxies de una `LandscapeGuid`) como un `.terrain` de `levels/<mapa>/` con su `Import_Info`,
  mostrado por una entidad con el label del actor. Las capas toman los materiales de las capas
  del material del landscape, por nombre; un material sin capas, que mezcla con sus propias splat
  maps, es el slot 0. El material entero, traducido como el programa que mezcla las capas de la
  fuente (`landscape_mapping`: la capa de Unreal de cada una y las coordenadas del landscape desde
  el mundo), es su `layers_material`; si no da un programa, las capas mezclan sus materiales con
  una advertencia. Capas y materiales enteros de cada landscape son una sola importación del
  paquete del material (`layer_materials`).

## Follaje (`unreal_foliage`)

InstancedFoliageActor, con los componentes que dibujan sus tipos de ISM actors, y los componentes
instanciados de cada escena. `foliage.odin` escribe en una fuente lo que da
[`foliage`](unreal.md#follaje-foliage) y las instancias de los componentes instanciados de un
nivel, en el espacio de una entidad en el origen de la escena.

- **InstancedFoliageActor** (`foliage_source`, `foliage_add`): un tipo por tipo de static mesh de
  Unreal, con el `.mesh` que el llamador da por tipo; el viento es 0, porque en Unreal lo mueven sus
  materiales, y la colisión, una caja de los bounds de la malla. Cada instancia es manual en la
  celda en que cae, `INSTANCE_GROUNDED` si está puesta sobre algo. Un tipo de actores no es un
  tipo: sus actores son actores del nivel, que la escena traduce como a los demás (una instancia
  sin su actor es un aviso). Uno de ISM actors tampoco: los componentes instanciados del actor que
  lo dibujan (`Foliage.components`) son lotes como los de abajo.
- **Componentes instanciados** (`instanced_add`): `InstancedStaticMeshComponent`, el jerárquico y
  el de follaje, también los que hornean PCG y los packed level actors. Un tipo por malla,
  materiales de sus slots, distancias de recorte (`InstanceStart/EndCullDistance`), sombras, rayos
  y colisión: la caja de los bounds de la malla si el componente colisiona, nada si no. Sin
  generador ni viento; las instancias son manuales, donde están.
- **Reimportar** conserva los ids: el traductor lee el `.foliage` que reemplaza y
  `foliage_ids_keep` da a cada tipo el id del igual o del de su nombre, malla, prefab y materiales,
  y a cada instancia manual el de la más cercana de su tipo en su celda dentro de `KEEP_DISTANCE`,
  `KEEP_TURN` y `KEEP_SCALE`, una a una; las demás toman ids que la anterior nunca dio, así una
  partida con lápidas no saca otras
  ([decisión](decisions.md#follaje-de-unreal-reimportar-conserva-los-ids)). Si el archivo anterior
  no se lee, la importación lo avisa y numera desde 1.
- Con escalas X e Y distintas una instancia toma su media geométrica (`averaged`); una escala nula,
  negativa o fuera de rango la descarta (`dropped`). Los floats propios de cada instancia
  (`PerInstanceSMCustomData`) y un material que el nivel guarda dentro de un actor no tienen lugar
  en un tipo: se avisan y se muestran los de la malla.
- **Al importar un nivel**, el traductor de `Foliage_Unreal` escribe por escena un `.foliage` de
  `levels/<mapa>/` con su `Import_Info`, con el nombre de la celda de World Partition (`Foliage`
  en la escena del mapa), y una entidad `Foliage` en su origen.

## Física (`unreal_physics`)

- `BlockingVolume` de un `CubeBuilder`: una caja estática de su tamaño.
- Cada `StaticMeshComponent`: la colisión del `BodySetup` de su malla (`mesh_body`), si su
  `BodyInstance` colisiona (`level.component_collision`): salvo con el perfil `NoCollision`, uno
  de solapamiento (`Overlap*`, `Trigger`, `UI`) o `CollisionEnabled` en `NoCollision`; sin
  `BodyInstance` guardado, el `BlockAllDynamic` de Unreal, y con `bUseDefaultCollision`, el perfil
  de la malla. Las instancias de uno instanciado son follaje, que colisiona por sus tipos
  ([follaje](#follaje-unreal_foliage)).
  - Solo cajas, esferas y cápsulas de `AggGeom`: colliders de entidades hijas donde están en la
    malla.
  - Con un convexo, la entidad colisiona con los colliders que guarda la malla importada: el
    `Hull` del convexo cuando es la única forma; si hay más, los cascos de todas como
    triángulos (`Mesh`), o el `Hull` de todas en un cuerpo que simula
    ([decisión](decisions.md#unreal-convexos-como-casco-o-triángulos-de-la-malla)).
  - Sin formas simples, o con `CTF_UseComplexAsSimple`: los triángulos (`Hull` si simula).
  - `bSimulatePhysics` da un `Rigid_Body` dinámico.

## Niebla (`unreal_fog`)

`ExponentialHeightFog` es la niebla del mundo entero con el albedo de su niebla volumétrica, y su
`SecondFogData`, otra que se le suma desde su altura más el offset; Unreal dibuja solo la primera
de una escena, y las otras son un aviso. Su `FogInscatteringLuminance` y su luz direccional son
radiancia que Unreal suma, no un albedo: con una `SkyAtmosphere` Unreal ilumina la niebla con el
cielo y el sol, como Mirai siempre, y se omiten; la escala de la luz del cielo que no es blanca y lo
que depende del ojo, `StartDistance`, `FogCutoffDistance` y `FogMaxOpacity`, son avisos.

## Navegación (`unreal_navigation`)

- `NavMeshBoundsVolume` es un `Nav_Bounds` del tamaño de su `CubeBuilder`.
- `NavModifierVolume` es un `Nav_Area` de ese tamaño: `NavArea_Null` (el que no nombra área),
  `NavArea_Obstacle` y `NavArea_LowHeight` bloquean, `NavArea_Default` camina, y otra área camina
  con un aviso para declararla.
- `NavLinkProxy` da un `Nav_Link` de tipo `Jump` por link de punto, de `Left` a `Right` en el
  marco del actor, en los dos sentidos o en uno; su smart link, si es relevante, uno `Door` que
  cruza el juego. Lo que exige sale de su geometría, como cualquier link manual.
- `RecastNavMesh` es un aviso con su agente: los meshes salen de la colisión, para las clases de
  `Navigation_Settings`.

## Partículas (`unreal_vfx`)

Traduce los actores `Emitter` (Cascade) y `NiagaraActor`, y los `ParticleSystemComponent` y
`NiagaraComponent` de otros actores (un Blueprint), a efectos `.particle` del plugin `vfx`. Sus
partes Editor y Shaders traen `shaders/niagara.slang`, el preludio de los programas traducidos,
que usa `shaders/unreal_noise.slang`.

- Cada emisor de un sistema es un `.particle` en `levels/<mapa>/`, escrito una vez por sistema;
  un actor (o el componente) es una entidad con un `Particle_Emitter` (`bAutoActivate` es
  `active`), o un grupo con una por emisor.
- **Cascade** (`unreal_cascade.odin`). Los módulos del primer LOD y sus distribuciones: constante,
  uniforme o curva (sus claves), o los valores que el paquete horneó con ella. Centímetros y Z
  arriba pasan a metros e Y arriba; un color mayor que uno da su pico a `intensity`; `EmitterLoops`
  distinto de cero es un efecto que no se repite.
- **Niagara** (`unreal_niagara.odin`). Lo que el editor guarda de las entradas de los módulos
  (`RapidIterationParameters` de sus scripts, por `Módulo.Entrada`), las curvas horneadas de sus
  data interfaces y sus renderers (sprite, ribbon, malla y luces). Los modos (`Lifetime Mode`,
  `Sprite Size Mode`, `Shape Primitive`, `Velocity Mode`, `Loop Behavior`…) son static switches:
  el valor de cada uno está en los pines de entrada de su nodo de función en el grafo del emisor
  (`unreal.graph_node_pins`), y un enum de `/Niagara` da el nombre que muestra el editor
  (`unreal.user_enum_entries`), con el que se elige: los `NewEnumeratorN` no son valores. Los
  valores guardados de las otras ramas no cuentan. Solo un módulo cuyo grafo no tiene el switch
  (guardado antes de que el módulo lo tuviera) toma el rango y lo avisa. Lo que cablean las
  entradas dinámicas no se lee.
- **Emisores livianos** (`UNiagaraStatelessEmitter`, `unreal_niagara_stateless.odin`): su ciclo,
  sus spawns y las propiedades de sus módulos, sin scripts. Una distribución es una constante o un
  rango (`Min`, `Max`), o valores a lo largo de la vida (`Values` sobre `ValuesTimeRange`); lo que
  el paquete omite es lo del constructor del módulo; una ligada a un parámetro `User.` toma el
  valor que guarda el sistema (`ExposedParameters`). Cada módulo es campos del efecto;
  `RotateAroundPoint` corre `Orbit` y `Scale*SizeBySpeed`, `Speed_Size`, y un efecto corre un solo
  programa: el segundo es un aviso. Los que no tienen sentido en Mirai (desplazar hacia la cámara,
  parámetros de material por partícula, decals, escala del dueño) se avisan por clase con la
  razón.
- El material del emisor es la traducción del de Unreal (su `BlendMode` da `blend` y el modelo
  `Unlit`, `lit`); lo que Mirai no tiene (módulos, renderers, luces aproximadas) es un aviso del
  emisor. Los `DynamicMaterialParameter` (y `1` a `3`) que guardan las partículas de un emisor
  compilado son los datos que `render` da al material de sus sprites, el índice de cada uno el
  del `DynamicParameter` que los lee.
- Un data interface de malla (`StaticMesh`, `SkeletalMesh`) que el componente apunta a un actor
  del nivel (`SoftSourceActor`, también el de un parámetro `User.`) es la superficie de la entidad
  de ese actor, por el nombre de su objeto con su número (`Statue_2`): la piel posada de un
  esqueleto que su `Animation` mueve.
- Las luces de partículas hacen sombra si las de Unreal la hacen: en Cascade, las de alta calidad
  con `bShadowCastingLights`; en Niagara, las que toma MegaLights con `bMegaLightsCastShadows`.
- **Niagara compilado.** Un emisor cuyos scripts guardan el HLSL que generó Niagara es un
  programa Vfx escrito en los `shaders/` del proyecto, que la importación publica
  ([decisión](decisions.md#niagara-el-hlsl-que-compiló-unreal)): `niagara_program.odin` arma el
  marco y `niagara.slang` es su preludio (espacio de Unreal, aleatorios, ids). Los scripts del
  sistema dan el estado de cada emisor y sus nacimientos (`//! births`); cada data interface es un
  cuerpo sobre los recursos de Vfx (`niagara_interfaces.odin`, `niagara_grids.odin`,
  `niagara_particles.odin`, `niagara_channels.odin`). Lo que una función no traduce da cero y es un
  aviso que la nombra. Una grilla o un render target 2D es plano a lo largo de y, como una textura
  del mundo: su celda (x, y) es la (x, 0, y) de la grilla, y los cuerpos y el hilo de sus etapas
  le dan al script el orden de Niagara. La textura de un `Texture` se hornea en un `.grid` plano a
  lo largo de y, una celda por texel como Unreal la lee (hasta `NIAGARA_TEXTURE_CELLS` por eje,
  remuestreada), del que arranca una grilla del efecto: `SampleTexture2D` la muestrea entre
  texels, repitiéndose (`niagara_textures.odin`). Cada parte escribe solo lo que su marco alcanza
  desde las funciones que llama (funciones, structs, statics, data interfaces y parámetros del
  motor que su código lee, `hlsl_reached`); un data interface que nadie llama se traduce igual por
  lo que dice del programa (el canal de sus nacimientos). Los canales traducidos guardan las
  variables del asset en su orden, con los valores de Unreal.
- **Nacimientos desde un canal de datos.** Cada `SpawnConditional` de los scripts del sistema que
  nombra al emisor (su `Emitter ID` es el índice de su handle) deja en palabras de `prepare` si
  corrió, su modo, su operador, sus cuentas y los valores de sus condiciones. `births` da a cada
  entrada del canal lo más que piden; `GetNDCSpawnData` reparte las partículas por entrada, y las
  de una entrada que no pasa las condiciones (el valor contra la variable de su nombre) o que
  pidió menos terminan en `initialize`, antes de su primer paso. Sin `SpawnConditional`, cada
  entrada inicia lo que pide `SpawnFromNDC`.
- **Eventos entre emisores.** Mirai no los tiene y no se traducen: un script que escribe un evento
  (sus `WriteDataSets`) y cada event handler de un emisor son un aviso que nombra el script y el
  evento y pide llevar lo que el evento lleva a un canal de datos (`DataChannelWrite` donde se
  genera, `SpawnConditional` y `GetNDCSpawnData` donde se maneja) o leer las partículas del otro
  emisor con un Particle Attribute Reader.
- **Render targets de un componente.** Un render target 2D cuyo `RenderTargetUserParameter` nombra
  un parámetro al que el componente da un `TextureRenderTarget2D` (`InstanceParameterOverrides`)
  es una grilla con `Particle_World_Texture`: los materiales que el nivel guarda y muestrean esa
  textura la leen por UV (las texturas del mundo de Vfx), con `texture_read_add`.
- **Bytecode de la VM.** Un script de CPU o de sistema de un save 5.8 o posterior guarda solo el
  bytecode de la VectorVM: `niagara_vm.odin` lo decompila al texto que el traductor escribe para la
  VM y el resto lo toma como el HLSL de un save anterior. Los registros de un data set son las
  componentes de sus variables (`Attributes`; en un script de sistema, el data set 1 son los
  parámetros de su instancia), en orden y por tipo de registro; una constante es un byte de su
  tabla: los structs de parámetros del motor, sus parámetros externos (dos veces, `PREV_`, si el
  emisor interpola el spawn) y sus literales, que quedan como bits. Una función de un data
  interface toma la firma que su compilación registró. El spawn decompilado de un emisor que
  interpola ya corre su update, como en la VM: update no corre sobre sus nacidos de ese paso.
  Una operación que no conoce rechaza el script con un aviso; lo que no sabe ubicar (eventos de
  otros emisores, una constante fuera de la tabla) lee cero y se avisa.

## Fluidos (`unreal_fluids`)

No traduce actores: su provider da solo `reads`. Los materiales de salida de FluidNinja
(`M_NinjaOutput_*` y sus instancias) se importan como programas que leen el fluido: el
`VelocityDensityBuffer` que sus Blueprints les dan en ejecución es la capa 0 de la grilla
`fluids.GRID` leída por UV (`fluids_unreal_default`). FluidNinja tiende su simulación a lo largo de
X e Y de Unreal: `fluid_ninja_buffer` (`shaders/fluid_ninja.slang` del puente) lee la textura
girada, u a lo largo de la z de Mirai y v de su -x, y da la velocidad en u y v. Con
`ForceLocalSpace` en 0 el material calcula sus UV desde `TraceMeshPosDouble` y `TraceMeshSize`, el
área que el Blueprint simula; en 1, son las de la malla. `PressureDivergenceBuffer` y `PaintBuffer`
no tienen lectura: una textura del mundo es una sola capa.

## Verificación

- Pruebas de `plugins/unreal_terrain/editor`:
  `a_landscape_becomes_a_heightfield_that_keeps_four_layers_and_folds_the_rest`,
  `the_landscape_of_an_unreal_level_is_a_terrain_of_its_scene`,
  `a_landscape_maps_the_world_to_its_coordinates_and_its_layers_to_those_of_the_terrain` y
  `a_landscape_of_unequal_scales_is_a_square_heightfield_on_a_stretched_entity`.
- Pruebas de `plugins/unreal_foliage/editor`:
  `unreal_foliage_becomes_manual_instances_of_its_cells_with_their_ground`,
  `instanced_components_are_one_type_for_each_mesh_and_materials_with_instances_from_the_origin`,
  `a_reimported_level_keeps_the_ids_of_the_foliage_it_had` y
  `unreal_foliage_of_actors_adds_only_its_static_mesh_types`.
- Pruebas de `plugins/unreal_physics/editor`:
  `a_blocking_volume_of_an_unreal_level_is_a_static_box`.
- Pruebas de `plugins/unreal_fog/editor`:
  `the_height_fog_of_an_unreal_level_is_a_fog_of_the_whole_world`.
- Pruebas de `plugins/unreal_navigation/editor`:
  `the_navigation_actors_of_an_unreal_level_are_bounds_areas_and_links`.
- Pruebas de `plugins/unreal_vfx/editor`: los nombres que escribe el traductor de Niagara y la
  decompilación del bytecode de la VM sobre bytecode escrito en la prueba (`niagara_vm_test.odin`:
  el mapa de parámetros, la tabla de constantes, las llamadas a data interfaces, el rechazo de lo
  que no lee, el programa de un emisor de CPU y el de uno que nace de un canal de datos con un
  `SpawnConditional` del sistema, que quedan en `.mirai/tmp/vfx-vm-test` para
  `mirai shaders check <programa> --project demo`) y la traducción de Cascade y Niagara
  (`unreal_particles_test.odin`, `niagara_test.odin`).
- Pruebas de `plugins/unreal_fluids/editor`: un material de salida de FluidNinja lee el fluido por
  UV.
- Los traductores corren completos en una sesión del editor: importar un mapa del corpus con los
  plugins de los puentes que usa, y comprobar el informe de actores por clase.
