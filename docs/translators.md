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
  (`c.instanced`), even with no actors: their instances are never one entity each. With
  `map_scene` it is called for the map's scene even without actors of its classes there, for what
  it makes of those of others (the grass of a landscape). `tally` counts what it says about each
  scene and the level warns once.
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
  `DefaultInstance`), `layer_materials` (layers of a Landscape material), `landscape_grass` (its
  grass), `asset_place` and `asset_write` (the id, file and `Import_Info` of a level asset, in the
  folder of the map's import), `entity_make` (at the root of a section, where the world transform
  puts it), `actor_entity`, `actor_key` and `component_set` (the scene), and `warn`.
- A bridge is declared like any editor plugin: a storage with the provider and its default
  (`Terrain_Unreal`, `Foliage_Unreal`, `Physics_Unreal`, `Shapes_Unreal`, `Fog_Unreal`,
  `Lens_Unreal`, `Navigation_Unreal`, `Vfx_Unreal`, `Fluids_Unreal`). Without the bridge for a
  class, its actors are warnings saying which plugin to enable.

## Terrain (`unreal_terrain`)

Landscape, LandscapeProxy and LandscapeStreamingProxy, in the map's scene (`root`).
`landscape_terrain` (`landscape.odin`) writes into a Heightfield source what
[`landscape`](unreal.md#landscape-landscape) gives and returns the transform of the entity that
shows it.

- Heights, spacing and holes pass through unchanged; `chunk_cells` is the Unreal subsection unless
  the options say otherwise. Cells are square: a landscape scaled differently in X than in Y is the
  grid of its X scale on an entity stretched sideways (the transform's x scale), which drawing,
  collision and residency already compose.
- The layers are every paint layer, in the landscape's order, up to `LAYERS_MAX`; past it, those
  with the most total weight. Each of the others adds its weight to
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
  type, with the `.mesh` and the wind the caller gives per type, and collision is a box of the
  mesh bounds. Each instance is manual in the cell where it
  falls, `INSTANCE_GROUNDED` if placed on something. An actor type is not a type: its actors are
  level actors, which the scene translates like the others (an instance without its actor is a
  warning). An ISM actors type is not one either: the actor's instanced components that draw it
  (`Foliage.components`) are batches like those below.
- **Instanced components** (`instanced_add`): `InstancedStaticMeshComponent`, the hierarchical one
  and the foliage one, also those baked by PCG and by packed level actors. One type per mesh,
  materials of its slots, cull distance (`InstanceEndCullDistance`), shadows, rays and collision:
  a box of the mesh bounds if the component collides, nothing if not. No generator; instances are
  manual, where they are. A `StaticMeshComponent` whose materials sway in the wind is a batch of
  one instance where it stands, not an entity (`mesh_sways`): Mirai sways foliage alone. It keeps
  what its entity had: never culled, seen by rays, and its collision, by the hulls its mesh
  stores (`Hull`) or none; one that collides otherwise (its triangles, boxes, spheres or capsules,
  a body that moves) stays an entity that stands still, and the import says so.
- **Wind** (`wind.odin`). Unreal sways foliage with the `WorldPositionOffset` of its materials,
  Mirai with the wind of each type where a `Wind` blows. `material.offset_read` tells wind (it
  moves with time and a function or parameter that feeds it is named for the wind) from another
  motion and from a shape, and measures how far it sways vertices of each section of the mesh:
  the length of each one's path along the line it moves along, so what it leans a vertex one way
  all the time is no sway. The type sways by the rigid bend whose swing best matches those in
  least squares (`sum(S*h)/sum(h*h)`, `h` the height above the pivot), and its wind is what sways
  it that far, from its least lean to its peak, in a `Wind` of `volume.WIND_DEFAULT`. Those
  materials are what says the air moves (Unreal sways foliage by them, with the wind parameters they read):
  the scene of the map gets a `Wind` of that speed, the way most swaying instances are moved and
  the pace they sway at on average; when they say neither way nor pace, no `Wind` is added and
  the import says so. A sway that cannot be measured is Mirai's default wind. Warnings: an offset
  that is not wind (it stands still), per-vertex weights (vertex colors, uv: Mirai bends the whole
  plant by height), gusts drawn by a texture, and the way and pace of each material (Mirai's wind
  has one of each where it blows).
- **Cull distances.** Unreal fades an instance between its start and end cull distances only in
  a material that reads `PerInstanceFadeAmount`; otherwise it draws whole up to the end and is
  gone there. Every type of foliage starts its fade at its cull distance.
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
- **Landscape grass** (`grass_add`, `grass.odin`): in the map's scene, each variety of each grass
  type of a landscape material ([grass](unreal.md#translation)) is a generated type of its mesh, its
  rule on the terrain layers (by material) whose paint layers its input reads, at most `RULE_LAYERS`
  of most coverage, on the slopes and from the least weight the input fits, and as dense as they
  weigh, as Unreal keeps a point where a chance is under the weight. A fit more than `FIT_NOTED` off
  is a warning with its slopes, weight and error; an input that reads what a rule does not see
  (time, the camera, noise) grows as densely as its layers alone. The cells over quads where those
  layers weigh, holes left out, generate, and then the other types of the source have density 0:
  what Unreal placed of them is all there is. Equal varieties of landscapes of one material are one
  type.
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
  - With a convex, or without simple shapes, or with `CTF_UseComplexAsSimple`: an `Auto` collider,
    which takes the colliders the imported mesh stores, each shape as authored; a mesh that stores
    none collides with its triangles, or with convex pieces of them when it simulates.
  - `bSimulatePhysics` gives a dynamic `Rigid_Body`.

## Spline meshes (`unreal_shapes`)

A `SplineMeshComponent` is the entity of a `StaticMeshComponent` (its mesh and the materials of
its slots) with a `Bend` of `shapes` (`spline_bend`), which draws the same shape: the curve of its
`SplineParams` (`level.spline_mesh_of`) and its `SplineUpDir` in Mirai's space, positions,
tangents, offsets and `SplineBoundaryMin` and `Max` in metres, roll and scale as they are,
`bSmoothInterpRollScale` as `smooth`. Its `ForwardAxis` gives the axis of the mesh along the curve
and the one along its up, both as the import turns Unreal's: X is -Z and Y, Y is X and -Z, Z is Y
and X. It collides where its `BodyInstance` does, as above but with `NoCollision` when it stores
none (the profile of a spline mesh), with an `External` collider: the child of the `Bend`
collides with the collision of its mesh bent. Without the bridge a spline mesh is left out with a
warning that names `shapes`, never drawn straight.

## Fog (`unreal_fog`)

`ExponentialHeightFog` is a fog in the box of what the level shows (the bounds of its actors),
since a Mirai fog fills a bounded `Volume` and the haze past it is the air of the `Sky`. Its
`base` is the actor's height, where it has Unreal's density: over it it thins by its falloff,
under it it holds (Unreal's grows without end, a warning). Its `SecondFogData` is another one in
the same box with its base raised by the offset. Unreal draws only
the first of a scene, and the others are a warning.

- Its inscattering luminance, which Unreal shows where the fog is thick whatever lights it, is the
  `glow`; a package from before the luminance takes the color it saved, with its old default.
- Under a `SkyAtmosphere` the `glow` also has the light Unreal adds from the sky of the atmosphere,
  unshadowed: its distant sky light (the air lit by the brightest sun of the atmosphere, marched
  with Unreal's transmittance and multiple-scattering tables and its directions over the sphere)
  times `HeightFogContribution` and `SkyAtmosphereAmbientContributionColorScale`
  (`unreal_scene.fog_sky`, worked out on import).
- The density is `FogDensity` in powers of two, the height fog Unreal draws at every quality and
  to the horizon; its volumetric fog, drawn only near the eye and at high scalability, is not
  taken.
- The lobe it adds around the sun without shadows (`DirectionalInscatteringLuminance` times the
  luminance of the sun, plus the sun through the atmosphere over 4π, times the power
  `DirectionalInscatteringExponent` of the cosine) is the sun Mirai's fog scatters, with shadows
  (`lobe_scatter`): the `anisotropy` whose phase gathers its light toward the sun as the lobe
  does (same peak over the whole), and the `color` with which thick fog seen toward the sun shows
  the lobe's luminance under the `Sun` as imported (its illuminance, its `scattering` and the
  phase at 0°), each channel held in [0, 1]. No sun, no lobe or a sun that scatters nothing: a
  black `color`.
- What Mirai does not draw is a warning: the distance where Unreal's volumetric fog ends and its
  glow starts, with its albedo and scattering distribution and what the import took instead;
  that Mirai's scattered sun is shadowed, starts at the eye and also scatters the light around
  by its `color`; its cubemap colors and what depends on the eye (`StartDistance`,
  `EndDistance`, `FogCutoffDistance`, `FogMaxOpacity`).

## Lens (`unreal_lens`)

It takes `PostProcessVolume` and the scene of the map (`map_scene`): the importer's
`post_process_add` makes each volume the entity of its `View_Volume` with its zone and `Volume`
(`lens`: also when it overrides only `LENS_SETTINGS`), and `post_process_base` the entity of the
look where no volume is. The bridge adds there a `Lens_Volume` of the same zone, for a volume when
it overrides some of the lens: its settings as Unreal blends them (`post_real`, `post_vector`), what
it overrides over the unbound volumes below it and the project's defaults (`BloomIntensity` 0.675
unless `r.DefaultFeature.Bloom` is off, `VignetteIntensity` 0.4).

- Bloom: Unreal's standard bloom adds to the image each of its six levels by its tint and a sixth
  of `BloomIntensity` × `BloomGaussianIntensity`, k of the light in all; the lens's `bloom` is the
  share of the image that is its blur, k/(1+k). A tint counts by its luminance and a colored one
  is a warning; the convolution bloom (`BM_FFT`) is a warning and is not translated.
- Vignette: Unreal darkens by cos⁴ of an angle whose tangent is `VignetteIntensity` times the
  distance from the center, the same at the corners of any view; the lens takes a share of the cos⁴
  falloff of the angles of its view. The share darkens the corners of Unreal's default view (90°
  across, 16:9) as Unreal does, at most the whole falloff, with a warning beyond.
- Threshold, sizes, dirt mask and the rest of the lens settings have no equivalent and are in the
  importer's warning.

## Navigation (`unreal_navigation`)

- `NavMeshBoundsVolume` is a `Nav_Bounds` in a box `Volume` of the size of its `CubeBuilder`.
- `NavModifierVolume` is a `Nav_Area` in a box `Volume` of that size: `NavArea_Null` (the one
  that names no area), `NavArea_Obstacle` and `NavArea_LowHeight` block, `NavArea_Default` walks,
  and any other area walks with a warning to declare it.
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
- **Cascade** (`unreal_cascade.odin`). The modules of the first LOD. A distribution is the table
  the package baked from it, which is what Unreal samples as particles run (a value, a range, or
  entries over the time it is sampled at), else its object (constant, uniform or curve).
  Centimeters and Z up become meters and Y up; a color above one gives its peak to `intensity`;
  `EmitterLoops` other than zero is an effect that does not repeat; a burst fires at its `Time` in
  seconds. A particle without a lifetime module, or whose lifetime is 0, never dies in Unreal: it
  takes `UNENDING_SECONDS` and the effect keeps room for every birth of its cycle (a cycle that
  repeats is a warning). Each step Unreal starts a particle again from the size and color it was
  born with and runs its modules in order: a color over life replaces the start color, and the
  color and size scales multiply, at the keys of all. What an effect cannot hold (a delay or
  origin, a duration range, a rate that changes along the cycle, sub-images at random or held on
  the first, a cone along another axis, an orbit) is a warning that names the module.
- **Niagara** (`unreal_niagara.odin`). What the editor stores of the modules' inputs
  (`RapidIterationParameters` of their scripts, by `Module.Input`), the baked curves of their data
  interfaces and their renderers (sprite, ribbon and mesh). The modes (`Lifetime Mode`,
  `Sprite Size Mode`, `Shape Primitive`, `Velocity Mode`, `Loop Behavior`...) are static switches:
  the value of each is in the input pins of its function node in the emitter graph
  (`unreal.graph_node_pins`), and a `/Niagara` enum gives the name the editor shows
  (`unreal.user_enum_entries`), which is what selects: the `NewEnumeratorN` are not values. The
  stored values of the other branches do not count. Only a module whose graph lacks the switch
  (saved before the module had it) takes the range and warns. What dynamic inputs wire is not read.
- **Lightweight emitters** (`NiagaraStatelessEmitter`, `unreal_niagara_stateless.odin`): their
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
- A particle of Mirai glows by its emission and is not a light: a Cascade light module, a Niagara
  light renderer and a lightweight `LightAttributes` are warnings of the emitter.
- **Compiled Niagara.** An emitter whose scripts store the HLSL Niagara generated is a Vfx program
  written in the project's `shaders/`, which the import publishes: `niagara_program.odin` builds the
  frame and `niagara.slang` is its prelude (Unreal space, random numbers, ids). The system scripts
  give each emitter's state and its births (`//! births`); each data interface is a body over the
  Vfx resources (`niagara_interfaces.odin`, `niagara_grids.odin`, `niagara_particles.odin`,
  `niagara_channels.odin`). A data interface is the symbol the HLSL calls it by: its name with the
  dots as `_`, or without them in a save before UE5. What a function does not translate gives zero
  and a warning that names it; an interface the scripts never call warns of nothing. A 2D grid or
  render target is flat along y, like a world texture: its cell (x, y) is the grid's (x, 0, y), and
  the bodies and thread of its stages give the script Niagara's order. A `Texture`'s texture is
  baked into a `.grid` flat along y, one cell per texel as Unreal reads it (up to
  `NIAGARA_TEXTURE_CELLS` per axis, resampled), from which an effect grid starts: `SampleTexture2D`
  samples it between texels, repeating (`niagara_textures.odin`). Each part writes only what its
  frame reaches from the functions it calls (functions, structs, statics, data interfaces and engine
  parameters its code reads, `hlsl_reached`); a data interface nobody calls is still translated for
  what it says about the program (the channel of its births). The translated channels keep the
  asset's variables in its order, with Unreal's values.
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
  `a_landscape_becomes_a_heightfield_with_every_layer_up_to_the_most_a_source_holds`,
  `the_landscape_of_an_unreal_level_is_a_terrain_of_its_scene`,
  `a_landscape_maps_the_world_to_its_coordinates_and_its_layers_to_those_of_the_terrain` and
  `a_landscape_of_unequal_scales_is_a_square_heightfield_on_a_stretched_entity`.
- Tests of `plugins/unreal_foliage/editor`:
  `unreal_foliage_becomes_manual_instances_of_its_cells_with_their_ground`,
  `instanced_components_are_one_type_for_each_mesh_and_materials_with_instances_from_the_origin`,
  `a_reimported_level_keeps_the_ids_of_the_foliage_it_had`,
  `unreal_foliage_of_actors_adds_only_its_static_mesh_types` and
  `landscape_grass_is_a_generated_type_on_its_layer_over_the_cells_where_it_is_painted`; the
  grass of a material, `a_grass_output_gives_each_grass_type_its_layers_rule_and_varieties` of
  `editor/material`.
- Tests of `plugins/unreal_physics/editor`:
  `a_blocking_volume_of_an_unreal_level_is_a_static_box`.
- Tests of `plugins/unreal_shapes/editor`:
  `a_spline_mesh_of_unreal_bends_its_mesh_where_unreal_does` (against Unreal's definition of the
  curve, for each forward axis) and `the_spline_meshes_of_an_unreal_level_bend_their_meshes`.
- Tests of `plugins/unreal_fog/editor`:
  `the_height_fog_of_an_unreal_level_fills_its_box_with_its_density_and_glow`,
  `under_a_sky_atmosphere_the_height_fog_glows_with_the_light_of_its_sky` and
  `the_lobe_around_the_sun_is_the_sun_the_fog_scatters`.
- Tests of `plugins/unreal_lens/editor`:
  `the_bloom_and_vignette_of_an_unreal_post_process_volume_are_a_lens_volume`; the importer's
  part and the warning without the bridge,
  `a_post_process_volume_overrides_unreals_defaults_over_the_volumes_below_it` and
  `a_level_without_post_process_volumes_has_unreals_default_look` and
  `the_post_process_of_a_level_without_its_project_takes_the_defaults_of_a_new_unreal_project` of
  `editor/scene`.
- Tests of `plugins/unreal_navigation/editor`:
  `the_navigation_actors_of_an_unreal_level_are_bounds_areas_and_links`.
- Tests of `plugins/unreal_vfx/editor`: the names the Niagara translator writes and the VM bytecode
  decompilation over bytecode written in the test (`niagara_vm_test.odin`: the parameter map, the
  constant table, the data interface calls, the rejection of what it cannot read, the program of a
  CPU emitter and that of one born from a data channel with a system `SpawnConditional`, which stay
  in `.mirai/tmp/vfx-vm-test` for `mirai shaders check <program> --project demo`), the Niagara
  translation (`niagara_test.odin`: `niagara_data_interfaces_are_named_as_their_hlsl_calls_them`)
  and a Cascade system of a level against what Unreal evaluates
  (`a_cascade_system_gives_its_effect_what_unreal_evaluates` and
  `a_cascade_particle_without_an_end_lives_on`, `unreal_cascade_test.odin`). The
  warning that names the plugin of a class without it:
  `a_translator_of_a_plugin_takes_the_actors_of_its_class_and_places_its_assets` of `editor/scene`.
- Tests of `plugins/unreal_fluids/editor`: a FluidNinja output material reads the fluid by UV.
- The translators run in full in an editor session: import a corpus map with the bridge plugins it
  uses, and check the per-class actor report.
