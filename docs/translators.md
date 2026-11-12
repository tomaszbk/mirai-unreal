# Unreal level translators

When importing a `.umap`, the map importer of the `unreal` plugin (`Unreal_Maps`) writes the scene
with what Mirai translates itself (meshes, lights, cameras, sky, text;
[levels to scenes](unreal.md#levels-to-scene-scene)) and leaves the actors of optional domains to
the translators of `unreal_*` bridge plugins. Each bridge is automatic (`automatic: true`),
editor-only, and depends on `unreal` and on the plugin it translates to: a project that has both
gets it without declaring it.

## The contract

`unreal_scene.Translator_Provider` is an Editor storage whose only field gives the translators its
plugin can write; when importing a map, `map_prepare` collects those of all plugins in the current
library (`editor.provided_all`).

- A `Translator` names native classes (from any `/Script` package, such as `Landscape` or
  `InstancedFoliageActor`), and its `translate(c, actors)` receives their actors one scene at a
  time: the map's and the section of each World Partition cell (`c.section`, `section_origin`). It
  returns how many it translated and warns about the rest. The importer does not translate the
  actors a translator takes. With `root`, those of all cells go to the map's scene, because what it
  writes loads only by distance (terrain, by pages). With `instanced` it also receives, after the
  actors, the instanced components (`ISM`, `HISM`, foliage) shown by the scene's actors
  (`c.instanced`), even with no actors: their instances are never one entity each. `tally` counts
  what it says about each scene and the level warns once.
- One with `component` instead of `translate` names component classes: `component(c, a, k, e)`
  adds to the entity `e` that the importer made from component `k` of actor `a`. For a class the
  importer translates (`StaticMeshComponent`), the importer still writes what it shows and the
  plugin adds what it knows (collision); for one it does not (the `NiagaraComponent` of a
  Blueprint), the entity belongs to the plugin alone.
- A texture that a plugin system writes at runtime is read by materials by UV instead of an image
  ([materials](unreal.md#translation)): the translator adds it with `texture_read_add` (the render
  target a component gives) for the materials the level stores, and the provider gives the fixed
  ones in `reads` (a texture parameter by name); the `unreal` plugin passes them to every Unreal
  import: a map's and a package's, such as a model.
- The `Context` gives the level document (`c.d`), the level's package and texture library (`c.lib`,
  `decoder`), `mesh_import`, `material_import` and `mesh_renderer` (the mesh and the materials of a
  component's slots) by Unreal object path, `mesh_body` (the collision of a `StaticMesh`'s
  `BodySetup`: simple shapes in imported-mesh space, `CollisionTraceFlag` and the profile of its
  `DefaultInstance`), `layer_materials` (layers of a Landscape material), `asset_place` and
  `asset_write` (the id, file and `Import_Info` of a level asset, in the folder of the map's
  import), `entity_make` (at the root of a section, where the world transform puts it),
  `actor_entity`, `actor_key` and `component_set` (the scene), and `warn`.
- A bridge is declared like any editor plugin: a storage with the provider and its default
  (`Terrain_Unreal`, `Foliage_Unreal`, `Physics_Unreal`, `Fog_Unreal`, `Navigation_Unreal`,
  `Vfx_Unreal`, `Fluids_Unreal`). Without the bridge for a class, its actors are warnings saying
  which plugin to enable.

## Terrain (`unreal_terrain`)

Landscape, LandscapeProxy and LandscapeStreamingProxy, in the map's scene (`root`).
`landscape_terrain` (`landscape.odin`) writes into a Heightfield source what
[`landscape`](unreal.md#landscape-landscape) gives and returns the transform of the entity that
shows it.

- Heights, spacing and holes pass through unchanged; `chunk_cells` is the Unreal subsection unless
  the options say otherwise. Cells are square: a landscape scaled differently in X than in Y is the
  grid of its X scale on an entity stretched sideways (the transform's x scale), which drawing,
  collision and residency already compose.
- The layers are the `LAYERS_MAX` with the most total weight. Each of the others adds its weight to
  the kept layer it overlaps most (the sum of the minimums of their per-sample weights; with no
  overlap, the one with the most weight): an edge between two layers stays an edge and each sample
  keeps its whole weight. A sample with no weight goes to the first layer.
- Each layer's material is the `.mat` the caller gives per Unreal layer; `folded` says which layer
  each one went to.
- **When importing a level**, the `Terrain_Unreal` translator writes each landscape (the actor and
  its proxies of one `LandscapeGuid`) as a `.terrain` in the folder of the map's import with its
  `Import_Info`, shown by an entity labeled with the actor. The layers take the materials of the
  landscape material's layers, by name; a material without layers, which blends with its own splat
  maps, is slot 0. The whole material, translated as the program that blends the source's layers
  (`landscape_mapping`: each one's Unreal layer and the landscape coordinates from the world), is
  its `layers_material`; if it gives no program, the layers blend their materials with a warning.
  The layers and whole materials of each landscape are a single import of the material's package
  (`layer_materials`).

## Foliage (`unreal_foliage`)

InstancedFoliageActor, with the components that draw its ISM actor types, and the instanced
components of each scene. `foliage.odin` writes into a source what
[`foliage`](unreal.md#foliage-foliage) gives and the instances of a level's instanced components,
in the space of an entity at the scene origin.

- **InstancedFoliageActor** (`foliage_source`, `foliage_add`): one type per Unreal static mesh
  type, with the `.mesh` the caller gives per type; wind is 0, because in Unreal its materials move
  it, and collision is a box of the mesh bounds. Each instance is manual in the cell where it
  falls, `INSTANCE_GROUNDED` if placed on something. An actor type is not a type: its actors are
  level actors, which the scene translates like the others (an instance without its actor is a
  warning). An ISM actors type is not one either: the actor's instanced components that draw it
  (`Foliage.components`) are batches like those below.
- **Instanced components** (`instanced_add`): `InstancedStaticMeshComponent`, the hierarchical one
  and the foliage one, also those baked by PCG and by packed level actors. One type per mesh,
  materials of its slots, cull distances (`InstanceStart/EndCullDistance`), shadows, rays and
  collision: a box of the mesh bounds if the component collides, nothing if not. No generator or
  wind; instances are manual, where they are.
- **Reimporting** keeps the ids: the translator reads the `.foliage` it replaces and
  `foliage_ids_keep` gives each type the id of the equal one or of the one with its name, mesh,
  prefab and materials, and each manual instance the id of the nearest of its type in its cell
  within `KEEP_DISTANCE`, `KEEP_TURN` and `KEEP_SCALE`, one to one; the rest take ids the previous
  file never gave, so a save with tombstones does not bring back others. If the previous file
  cannot be read, the import warns and numbers from 1.
- With different X and Y scales an instance takes their geometric mean (`averaged`); a zero,
  negative or out-of-range scale drops it (`dropped`). A material the level stores inside an actor
  is written on request (`instanced_material`), because no entity takes it when the level ends;
  the instances of each set of per-instance floats (`PerInstanceSMCustomData`) are a batch showing
  the variant, with those values, of the materials that read them (the wall color of a blueprint).
- **When importing a level**, the `Foliage_Unreal` translator writes per scene a `.foliage` in the
  folder of the map's import with its `Import_Info`, named after the World Partition cell (`Foliage`
  in the map's scene), and a `Foliage` entity at its origin.

## Physics (`unreal_physics`)

- `BlockingVolume` of a `CubeBuilder`: a static box of its size.
- Each `StaticMeshComponent`: the collision of its mesh's `BodySetup` (`mesh_body`), if its
  `BodyInstance` collides (`level.component_collision`): except with the `NoCollision` profile, an
  overlap one (`Overlap*`, `Trigger`, `UI`) or `CollisionEnabled` set to `NoCollision`; with no
  stored `BodyInstance`, Unreal's `BlockAllDynamic`, and with `bUseDefaultCollision`, the mesh's
  profile. The instances of an instanced component are foliage, which collides by its types
  ([foliage](#foliage-unreal_foliage)).
  - Only boxes, spheres and capsules of `AggGeom`: colliders of child entities where they are in
    the mesh.
  - With a convex, the entity collides with the colliders stored by the imported mesh: the convex's
    `Hull` when it is the only shape; if there are more, the hulls of all as triangles (`Mesh`), or
    the `Hull` of all in a simulating body.
  - Without simple shapes, or with `CTF_UseComplexAsSimple`: the triangles (`Hull` if it simulates).
  - `bSimulatePhysics` gives a dynamic `Rigid_Body`.

## Fog (`unreal_fog`)

`ExponentialHeightFog` is the whole-world fog with the albedo of its volumetric fog, and its
`SecondFogData` is another one added to it from its height plus the offset; Unreal draws only the
first of a scene, and the others are a warning. Its `FogInscatteringLuminance` and its directional
light are radiance that Unreal adds, not an albedo: with a `SkyAtmosphere` Unreal lights the fog
with the sky and sun, as Mirai always does, and they are omitted; the scale of non-white sky light
and what depends on the eye, `StartDistance`, `FogCutoffDistance` and `FogMaxOpacity`, are
warnings.

## Navigation (`unreal_navigation`)

- `NavMeshBoundsVolume` is a `Nav_Bounds` of the size of its `CubeBuilder`.
- `NavModifierVolume` is a `Nav_Area` of that size: `NavArea_Null` (the one that names no area),
  `NavArea_Obstacle` and `NavArea_LowHeight` block, `NavArea_Default` walks, and any other area
  walks with a warning to declare it.
- `NavLinkProxy` gives a `Jump` `Nav_Link` per point link, from `Left` to `Right` in the actor's
  frame, two-way or one-way; its smart link, if relevant, gives a `Door` one that the game crosses.
  What it requires comes from its geometry, like any manual link.
- `RecastNavMesh` is a warning with its agent: meshes come from collision, for the classes of
  `Navigation_Settings`.

## Particles (`unreal_vfx`)

Translates `Emitter` (Cascade) and `NiagaraActor` actors, and the `ParticleSystemComponent` and
`NiagaraComponent` of other actors (a Blueprint), into `.particle` effects of the `vfx` plugin.
Its Editor and Shaders parts bring `shaders/niagara.slang`, the prelude of the translated programs,
which uses `shaders/unreal_noise.slang`.

- Each emitter of a system is a `.particle` in the folder of the map's import, written once per
  system; an actor (or component) is an entity with a `Particle_Emitter` (`bAutoActivate` is
  `active`), or a group with one per emitter.
- **Cascade** (`unreal_cascade.odin`). The modules of the first LOD and their distributions:
  constant, uniform or curve (its keys), or the values the package baked from it. Centimeters and
  Z up become meters and Y up; a color above one gives its peak to `intensity`; `EmitterLoops`
  other than zero is an effect that does not repeat.
- **Niagara** (`unreal_niagara.odin`). What the editor stores of the modules' inputs
  (`RapidIterationParameters` of their scripts, by `Module.Input`), the baked curves of their data
  interfaces and their renderers (sprite, ribbon, mesh and lights). The modes (`Lifetime Mode`,
  `Sprite Size Mode`, `Shape Primitive`, `Velocity Mode`, `Loop Behavior`...) are static switches:
  the value of each is in the input pins of its function node in the emitter graph
  (`unreal.graph_node_pins`), and a `/Niagara` enum gives the name the editor shows
  (`unreal.user_enum_entries`), which is what selects: the `NewEnumeratorN` are not values. The
  stored values of the other branches do not count. Only a module whose graph lacks the switch
  (saved before the module had it) takes the range and warns. What dynamic inputs wire is not read.
- **Lightweight emitters** (`UNiagaraStatelessEmitter`, `unreal_niagara_stateless.odin`): their
  cycle, spawns and module properties, without scripts. A distribution is a constant or a range
  (`Min`, `Max`), or values along the lifetime (`Values` over `ValuesTimeRange`); what the package
  omits is the module constructor's; one bound to a `User.` parameter takes the value the system
  stores (`ExposedParameters`). Each module is effect fields; `RotateAroundPoint` runs `Orbit` and
  `Scale*SizeBySpeed`, `Speed_Size`, and an effect runs a single program: the second is a warning.
  Those that make no sense in Mirai (offset toward the camera, per-particle material parameters,
  decals, owner scale) are warned per class with the reason.
- The emitter's material is the translation of Unreal's (its `BlendMode` gives `blend` and the
  `Unlit` model, `lit`); what Mirai lacks (modules, renderers, approximated lights) is an emitter
  warning. The `DynamicMaterialParameter` (and `1` to `3`) stored by the particles of a compiled
  emitter are the data `render` gives the material of its sprites, the index of each being that of
  the `DynamicParameter` that reads them; its `MaterialRandom` is the random value `ParticleRandom`
  reads, 0 if the emitter does not store it, as in Unreal.
- A mesh data interface (`StaticMesh`, `SkeletalMesh`) that the component points at a level actor
  (`SoftSourceActor`, also that of a `User.` parameter) is the surface of that actor's entity, by
  the name of its object with its number (`Statue_2`): the posed skin of a skeleton moved by its
  `Animation`.
- Particle lights cast shadows if Unreal's do: in Cascade, the high-quality ones with
  `bShadowCastingLights`; in Niagara, those MegaLights takes with `bMegaLightsCastShadows`.
- **Compiled Niagara.** An emitter whose scripts store the HLSL Niagara generated is a Vfx program
  written in the project's `shaders/`, which the import publishes: `niagara_program.odin` builds the
  frame and `niagara.slang` is its prelude (Unreal space, random numbers, ids). The system scripts
  give each emitter's state and its births (`//! births`); each data interface is a body over the
  Vfx resources (`niagara_interfaces.odin`, `niagara_grids.odin`, `niagara_particles.odin`,
  `niagara_channels.odin`). What a function does not translate gives zero and a warning that names
  it. A 2D grid or render target is flat along y, like a world texture: its cell (x, y) is the
  grid's (x, 0, y), and the bodies and thread of its stages give the script Niagara's order. A
  `Texture`'s texture is baked into a `.grid` flat along y, one cell per texel as Unreal reads it
  (up to `NIAGARA_TEXTURE_CELLS` per axis, resampled), from which an effect grid starts:
  `SampleTexture2D` samples it between texels, repeating (`niagara_textures.odin`). Each part writes
  only what its frame reaches from the functions it calls (functions, structs, statics, data
  interfaces and engine parameters its code reads, `hlsl_reached`); a data interface nobody calls is
  still translated for what it says about the program (the channel of its births). The translated
  channels keep the asset's variables in its order, with Unreal's values.
- **Births from a data channel.** Each `SpawnConditional` of the system scripts that names the
  emitter (its `Emitter ID` is the index of its handle) leaves in `prepare` words whether it ran,
  its mode, its operator, its counts and the values of its conditions. `births` gives each channel
  entry the most they ask for; `GetNDCSpawnData` distributes the particles per entry, and those of
  an entry that fails the conditions (the value against the variable of its name) or that asked for
  fewer end in `initialize`, before their first step. Without `SpawnConditional`, each entry
  initiates what `SpawnFromNDC` asks for.
- **Events between emitters.** Mirai has none and they are not translated: a script that writes an
  event (its `WriteDataSets`) and each event handler of an emitter are a warning naming the script
  and event and asking to carry what the event carries through a data channel (`DataChannelWrite`
  where it is generated, `SpawnConditional` and `GetNDCSpawnData` where it is handled) or to read
  the other emitter's particles with a Particle Attribute Reader.
- **Component render targets.** A 2D render target whose `RenderTargetUserParameter` names a
  parameter to which the component gives a `TextureRenderTarget2D` (`InstanceParameterOverrides`)
  is a grid with `Particle_World_Texture`: the materials the level stores that sample that texture
  read it by UV (Vfx's world textures), with `texture_read_add`.
- **VM bytecode.** A CPU or system script from a 5.8 or later save stores only VectorVM bytecode:
  `niagara_vm.odin` decompiles it to the text the translator writes for the VM and the rest takes
  it as the HLSL of an earlier save. The registers of a data set are the components of its
  variables (`Attributes`; in a system script, data set 1 is its instance's parameters), in order
  and by register type; a constant is a byte of its table: the engine parameter structs, its
  external parameters (twice, `PREV_`, if the emitter interpolates the spawn) and its literals,
  which stay as bits. A data interface function takes the signature its compilation registered. The
  decompiled spawn of an interpolating emitter already runs its update, as in the VM: update does
  not run on that step's newborns. An operation it does not know rejects the script with a warning;
  what it cannot place (events from other emitters, a constant outside the table) reads zero and
  warns.

## Fluids (`unreal_fluids`)

It bridges `unreal` with the `fluids` plugin of the catalog, which the project installs apart
(`project:plugins/fluids`). It translates no actors: its provider gives only `reads`. FluidNinja's
output materials (`M_NinjaOutput_*` and their instances) are imported as programs that read the
fluid: the `VelocityDensityBuffer` that their Blueprints give them at runtime is layer 0 of the
`fluids.GRID` grid read by UV (`fluids_unreal_default`). FluidNinja lays out its simulation along
Unreal's X and Y: `fluid_ninja_buffer` (the bridge's `shaders/fluid_ninja.slang`) reads the rotated
texture, u along Mirai's -z and v along its x, and gives the velocity in u and v. With
`ForceLocalSpace` at 0 the material computes its UV from `TraceMeshPosDouble` and `TraceMeshSize`,
the area the Blueprint simulates; at 1, those of the mesh. `PressureDivergenceBuffer` and
`PaintBuffer` have no read: a world texture is a single layer.

## Verification

- Tests of `plugins/unreal_terrain/editor`:
  `a_landscape_becomes_a_heightfield_that_keeps_four_layers_and_folds_the_rest`,
  `the_landscape_of_an_unreal_level_is_a_terrain_of_its_scene`,
  `a_landscape_maps_the_world_to_its_coordinates_and_its_layers_to_those_of_the_terrain` and
  `a_landscape_of_unequal_scales_is_a_square_heightfield_on_a_stretched_entity`.
- Tests of `plugins/unreal_foliage/editor`:
  `unreal_foliage_becomes_manual_instances_of_its_cells_with_their_ground`,
  `instanced_components_are_one_type_for_each_mesh_and_materials_with_instances_from_the_origin`,
  `a_reimported_level_keeps_the_ids_of_the_foliage_it_had` and
  `unreal_foliage_of_actors_adds_only_its_static_mesh_types`.
- Tests of `plugins/unreal_physics/editor`:
  `a_blocking_volume_of_an_unreal_level_is_a_static_box`.
- Tests of `plugins/unreal_fog/editor`:
  `the_height_fog_of_an_unreal_level_is_a_fog_of_the_whole_world`.
- Tests of `plugins/unreal_navigation/editor`:
  `the_navigation_actors_of_an_unreal_level_are_bounds_areas_and_links`.
- Tests of `plugins/unreal_vfx/editor`: the names the Niagara translator writes and the VM bytecode
  decompilation over bytecode written in the test (`niagara_vm_test.odin`: the parameter map, the
  constant table, the data interface calls, the rejection of what it cannot read, the program of a
  CPU emitter and that of one born from a data channel with a system `SpawnConditional`, which stay
  in `.mirai/tmp/vfx-vm-test` for `mirai shaders check <program> --project demo`) and the Cascade
  and Niagara translation (`unreal_particles_test.odin`, `niagara_test.odin`).
- Tests of `plugins/unreal_fluids/editor`: a FluidNinja output material reads the fluid by UV.
- The translators run in full in an editor session: import a corpus map with the bridge plugins it
  uses, and check the per-class actor report.
