# Unreal: editor packages, Kraken, textures, meshes, materials and levels

The packages under `editor/` (imported as `project:plugins/unreal/editor/<package>`) read Unreal
editor packages (uncooked `.uasset`/`.umap`, such as Fab's) without Unreal installed. They are
engine-time: they live in the editor part of the `unreal` plugin and no game contains them.
`package` is imported as `unreal`; `foliage`, `scene` and `texture` are called `unreal_foliage`,
`unreal_scene` and `unreal_texture` (package names are unique, also against the engine's). Only
`material/write` and `scene` write assets: meshes, skeletons, animations and textures reach the
editor through the `model` format
([models](#model-format-model)) and maps as [scenes](#levels-to-scene-scene).
`fixture` builds the synthetic packages of the tests and `fixture/files` writes them as complete
files. How they are imported in the editor: [README](README.md#importing-in-the-editor).

## Packages (`package`)

`package_open` is a view over caller-owned bytes, which must live until `package_destroy`; UTF16
names are converted and belong to the package. `Error` is `{code,offset,field}`, with a constant
`field` (valid even when memory runs out). `Limits` bounds bytes, tables, strings, properties and
outer depth.

- **Versions.** UE4 from 214 and UE5 up to what the reader knows, licensee zero; in the newest ones
  the high bits of the legacy version field hold the offset of the offsets table. Each field
  follows Unreal's version gates.
- **Rejections.** Unknown version (`Unsupported_Version`), no versions or
  `PKG_UnversionedProperties` (`Unversioned`), `PKG_Cooked` (`Cooked`) and package compression
  (`Compressed`).
- **Tables.** Limits, overlaps, references and outer cycles are checked. `Object_Ref` keeps
  Unreal's index (zero null, negative import, positive export).
- **Properties.** `property_value` interprets the common types; containers, `Text` and native
  structs give `Unsupported_Value` and are read with the tagged array and struct helpers.
  `class_default_object` finds the CDO by class and flag, not by name.
- **Mounts.** `Source_Mount` maps a prefix (`/Game`, `/Engine`) to a `Content` folder;
  `source_package_path` and `source_package_name` convert between package and file and reject
  traversal, devices and ambiguous prefixes. How they are chosen:
  [mounts](#model-format-model).

### Payloads

- Only local payloads are read: `editor_bulk_data` locates an `EditorBulkData` in the trailer or
  at its absolute offset and `byte_bulk_data` the UE4 bulk data inline, at the end of the file or
  in zlib chunks. Virtualized, sidecar, workspace, legacy or in a separate file is
  `Unsupported_Value`.
- `compressed_buffer_decode` supports None, LZ4 (its own block decoder) and Oodle with a
  `kraken.Decoder`,
  and compares the result with the buffer's BLAKE3: a mismatch is `Malformed`. The raw size of a
  payload is also bounded by the package `Limits`.

## Kraken (`kraken`)

`decoder_make` allocates once what a chunk needs and `decode` decodes an Oodle stream whose raw
size is `len(destination)` without allocating.

- Compressors: Kraken, Mermaid and Selkie (one format) and Leviathan, which share blocks, quanta
  and chunks and differ in each chunk's LZ (`lz_decode`, `mermaid_decode`, `leviathan_decode`).
  Arrays: stored, tANS, Huffman, RLE, sequences and multi-arrays (arrays cut by intervals of
  others, with variable bit lengths read from both ends).
- `Unsupported`: LZNA, BitKnit and the 0x80 flag byte at the start of a Kraken LZ chunk (excess
  bytes), which no open description of the format reads: those modes are not read and no corpus
  uses them.
- No corpus uses tANS, multi-arrays, Mermaid, Selkie or Leviathan: only the tests' encoder,
  written from the same format description, validates them.
- A damaged stream gives `Truncated` or `Malformed` without reading or writing outside the slices;
  each stream (literals, offsets, lengths, interval arrays) must be fully consumed. Correctness is
  measured with the BLAKE3 of each `CompressedBuffer`.
- Match copies write 8-byte words and may overwrite up to 7 bytes after the match inside the
  destination: that is output not yet written.

## Textures (`texture`)

- `texture_kind` recognizes the `/Script/Engine` texture classes (2D and its lightmap and light
  profile variants, cube, arrays and volume). `texture_read` reads the `Source` struct and locates
  the payload (`EditorBulkData` since UE5 virtualization, bulk data before) with Unreal's load
  rules for old saves.
- **Usage.** `TC_Normalmap` is `Normal`; false `SRGB`, `TC_Masks`, `TC_Alpha` and HDR are `Data`;
  the rest, `Color`. `TC_Grayscale`, `TC_Displacementmap`, `TC_HalfFloat`, `TC_SingleFloat` and
  `TC_HDR_F32` ask for `keep_precision`: a 16-bit or float source is stored uncompressed. Unreal's
  other compression settings do not count: the usage decides the format (the engine's
  `cook/textures`).
- `texture_decode` gives all blocks, layers, mips and slices, rows from the top, as RGBA8, RGBA16
  or linear RGBA32F depending on the source format, from None, UEDELTA, PNG, JPEG or UEJPEG. PNG,
  JPEG and UEJPEG are a single 2D image and, as in Unreal, the format is told by their bytes and
  not by the compression the source names: PNG and JPEG with stb, `OOJPEG` with `uejpeg_decode`. A
  source called PNG that is `BGRA8` stores the bytes as they are (Unreal wrote them as RGBA); if
  the image does not decode and the payload is the size of the uncompressed source, it is read
  that way, as Unreal does.
- **UEJPEG** (`uejpeg.odin`): the quantized coefficients of a baseline JPEG without Huffman, in
  horizontal bands (splits) stored or Oodle-compressed (decoded with `kraken`). It gives the pixels
  Unreal gives on x64: the integer fast IDCT, and fixed-point upsampling and YCbCr.
  The source is `BGRA8`, or `G8`,
  which stores red in the one channel; 16 bits or float is `Unsupported_Value`. What Unreal does
  not validate and would make it read outside its planes or leave coefficients unwritten is
  rejected: blocks outside the image or an empty Oodle split.
- Normal maps come out in Mirai's convention (+Y): green is inverted unless `bFlipGreenChannel`
  already inverted it.
- `check`: with `bGuidIsHash` the `Id` is the BLAKE3 of the raw source, and `Matches`, `Differs`
  or `Unknown` compare against the decoded data.
- `texture_build_input` gives the engine's `cook/textures.build` level 0 of the first block and
  layer with its precision and its `Build_Options`: 8 bits as they are (the legacy 2.2 curve
  becomes sRGB), linear 16 bits that color takes to the sRGB curve, and floats as they are, HDR
  above 1 included.
  - An array keeps its slices as layers.
  - A cube gives its faces in Mirai's order and axes: each texel of a Mirai face is the Unreal one
    sampled with the same world direction (`cube_faces`, an exact permutation). A long-lat cube
    (`bLongLatCubemap`, or slices that are not whole cubes) becomes six faces as Unreal's build
    does (`cube_long_lat`): side the power of two of half the width or less, at least 32, and each
    texel reads the image bilinearly at its longitude and latitude.
  - `approximations` says what a `.tex` does not store: a volume's depth after its first slice,
    Unreal layers (several images per texture, from virtual textures) after the first, UDIM blocks
    after the first and authored mips (the engine's `cook/textures` rebuilds the chain). Mirai has
    no consumer for volumes, layers or UDIM.
- A package with only textures is imported as those textures ([import](#model-format-model));
  the rest arrives through the materials that read them. A cube or an array is not baked into a uv
  map (`source_pixels`): it only enters as a texture.

## Static meshes (`mesh`)

`mesh_read` reads a `StaticMesh` and locates a source model's payload; `mesh_decode` builds it as
Unreal's build does: a corner `Mesh` in Unreal space, with the build scale. A package with meshes
is opened with `LIMITS`: the payload of a mesh of millions of triangles exceeds `DEFAULT_LIMITS`.

- **Model.** `Lod0` (what Unreal draws without Nanite) or `Hi_Res` (`HiResSourceModel`, from which
  Nanite is built). LOD 1+ are not
  read: Mirai's levels come from LOD 0.
- **Payload**, depending on the package versions: a `RawMesh` or a `MeshDescription` (in the
  element-map format or the UE4 array format). A description saved before
  `MeshDescriptionTriangles` has only polygons: its triangles are the ones UE5 makes on load, a
  fan on the second corner, also for a concave polygon.
- **What the build does** (`Mesh`):
  - Sections are the polygon groups, with the material Unreal gives them (-1 if that slot does
    not exist).
  - A degenerate triangle (corners closer than `DEGENERATE_DISTANCE`, exact without
    `bRemoveDegenerates`) or without area is dropped.
  - Normals, where recomputed, missing or not finite: the sum of those of the triangles joined by
    soft edges. Tangents: the source's unless recomputed; zero, and the importer runs MikkTSpace.
  - `BuildScale3D` scales positions and tangents and its inverse scales normals; a mirroring
    scale flips the triangles.
  - Color: the bytes of Unreal's vertex buffer; empty if all are white.
  - Triangles in Unreal's order: seen from the front, `cross(c2-c0,c1-c0)` points out of the face.
- `Static_Mesh` also brings the slots, `ExtendedBounds` and the `BodySetup`, which `body_read`
  reads: the shapes of its `AggGeom` in Unreal and mesh space (a convex's points with its
  `Transform` applied; elements with `CollisionEnabled` set to `NoCollision` are left out), the
  `CollisionTraceFlag` and the profile of its `DefaultInstance`. Some UE4 saves store a slot's
  material only at the end of the mesh serialization: it is taken from there.

## Skeletal meshes (`mesh`)

`skeletal_read` reads a `SkeletalMesh` (properties, materials, `ReferenceSkeleton` and where
LOD 0 is); `skeletal_decode` gives a `Skinned_Mesh`, the static `Mesh` with the influences of each
position and LOD 0's morph targets. `skeleton_read` gives the reference skeleton of a `Skeleton`
and its sockets.

- **Skeleton.** The mesh's reference skeleton, its bind pose: names, parents (always an earlier
  bone, a single root) and each bone's pose relative to its parent; `Skeleton` is the path of its
  `Skeleton`, which is not opened.
- **Sockets**: the `SkeletalMeshSocket`s of the mesh or of the `Skeleton`, with their bone and
  placement.
- **Morph target curves** (`Skeleton.morph_curves`): those the `Skeleton`'s curve metadata marks
  with `bMorphtarget`, read per version; if the metadata could not be read, `curves_known` is
  false.
- **Where LOD 0 is**: up to UE 5.3, the `SkeletalMeshLODModel` the build saves with the editor
  data, what Unreal draws, rebuilding nothing; after that, the source model's `MeshDescription`
  with its `SkinWeights`. Saves before `SplitModelAndRenderData` or `IncreaseNormalPrecision` are
  `Unsupported_Value`: they must be saved again in Unreal.
- **Building a description** (`skin.odin`), what Unreal's skeletal build would store in the LOD
  model:
  - Normals as in a static mesh; only triangles without area are dropped, because the skeletal
    build does not remove degenerates (`bRemoveDegenerates` does not change that).
  - Color without sRGB (`ToFColor(false)`), white if no corner has a color other than black.
  - Influences: the first ones the build stores, from bones that exist, sorted and renormalized as
    in Unreal (the remainder of each weight goes to the next, with Unreal's order on ties); with
    none, the root. How many: the asset's `BoneInfluenceLimit`, else the project's
    `DefaultBoneInfluenceLimit`, never more than twelve, and eight unless
    `r.GPUSkin.UnlimitedBoneInfluences` is above its threshold. The project comes from the
    `Config/DefaultEngine.ini` of the `/Game` mount (`skin_project_read`); without it, the engine
    defaults. The limit's `PerPlatform` value is not read.
  - Welding: in face order, a corner becomes the first vertex already made in its chunk (its
    section's material) whose corner overlaps and is equal within the `SkeletalMeshBuildSettings`
    thresholds (position, uv, tangent basis) with the same color and influences; a triangle with
    two corners on one vertex is dropped (`degenerate`). The source's tangent is compared; the one
    the import makes later with MikkTSpace is not there yet. A description's normals are not those
    of `Skeletal_ComputeTangents`, and the influences of `SK_DinoDragon` and `SKM_Quinn`
    (ContentExamples 5.8) differ from their saved LOD model (11/10 against 8): not compared with
    Unreal.
- **Sections.** An index that leaves its section is `Malformed`. The material comes from LOD 0's
  `LODMaterialMap` (in a description, from the group name as `AdjustImportDataFaceMaterialIndex`
  does); `bDisabled` sections are left out (`left_out`) and cloth ones are counted (`cloth`) and
  drawn with their skin.
- **Morph targets** (`morphs`, with each corner's delta row): from a LOD model, the
  `MorphTargetLODModel` of LOD 0 of each `MorphTarget`; from a description, the
  `Morph-<name>` attributes. A cooked target is `Cooked`.

## Animations (`mesh`)

`animation_read` reads an `AnimSequence`: each bone's local transform per key (without scales,
scale one), float curves, sync markers and how it plays (`RateScale`, `Interpolation`, root
motion, additive, notifies), with a key every `interval` seconds from 0 to the duration.

- **Where it is**, depending on the save (`layout`): `Raw_Tracks` in UE4 (`RawAnimationData` or
  `SourceRawAnimationData`, with the keys Unreal fixes on load), `Data_Model` in UE 5.0 and 5.1
  (the `AnimDataModel`) and `Sequencer` since 5.2: each bone is a `<bone>_CONTROL` control of the
  section's control rig, whose channels are evaluated at each frame as in Unreal, and rotation by
  quaternions from Euler angles.
- A track with fewer keys keeps the last one, as Unreal clamps the key it samples; those with more
  are trimmed. Tangents that are not numbers are zero.
- Approximation: a cubic segment with weighted tangents is evaluated without the weight
  (`weighted` counts the affected frames; none in the corpora). A cooked animation is `Cooked`.

## Pose assets (`mesh`)

`pose_asset_read` reads a `PoseAsset` as an animation of a key per frame that holds each key, which
the editor turns into the curve poses and drives of a `.pose` (`pose.profile.poses` without a
list).

- Frame 0 is the base: the pose `BasePoseIndex` names in an additive asset; in another, or one
  without a base, the reference pose of its skeleton, which the importer puts (`rest_first`).
  Frame `k+1` is pose `k`, marked by a sync marker of its name, every `POSE_ASSET_INTERVAL`.
- The poses are the source ones (`SourceLocalSpacePose`), whole, which Unreal keeps with the
  editor data before making them additive: measured from the base they are its additive poses. A
  save without them is `Unsupported_Value`.
- Names come from `PoseFNames` or from the `SmartName`s of `PoseNames`; each curve of `Curves` is
  a float curve with the value of each pose (`SourceCurveData`) at its frame and zero at the base.
- A count of poses, bones or curve values that does not match is `Malformed`.

## Model format (`model`)

The `model` package (`uasset`) is the editor's `.uasset` model format: it imports each
`StaticMesh` of an editor package as a mesh with its node ([reading](#static-meshes-mesh)), each
`SkeletalMesh` as a skinned mesh ([reading](#skeletal-meshes-mesh)) and each `AnimSequence` as a
clip ([reading](#animations-mesh)). A package with only a `Skeleton` is that skeleton; one with
only textures, each a `.tex` with its layers, faces and the precision of its source
([reading](#textures-texture)); each `PoseAsset`, a clip of a frame per pose
([reading](#pose-assets-mesh)); one with none of that is `Unsupported`. What the package rejects
arrives with its cause and offset.

- **Space.** Centimeters, +Z up, +X forward, +Y right and left-handed, with V from the top: the
  engine's +X is Unreal's +Y, its +Y is +Z and its -Z, the front of everything, is +X. It is a
  mirror: Unreal's triangles, which run opposite to its axes, enter the builder with inverted
  corners and the mirror turns them again.
- **Slots.** One per `StaticMaterials` slot that a section uses: its id is the slot index plus one
  (what an Unreal component overrides by index) and its label the slot name; a section without a
  valid material goes to slot 0, without material.
- **Materials.** `slot_material(&context,slot)` makes a slot's material, one per object path in
  the import: [`material`](#materials-material) translates it through the mounts (a `Library` and
  a `write.Builder` per import, or those of `Options.library` and `images`, which a level shares
  among all its meshes) and adds it with its images via `write.reader_material`. A material that
  is not found or not translated takes the `.mat` values with its name and leaves a warning. One
  that needs a Surface program writes it to `<root>/shaders`; without `root`, it keeps its
  standard-model values and leaves a warning: reading a source does not write outside a project
  folder.
- **Vertex color.** Unreal only uses it if the material graph reads it; Mirai's standard model
  always multiplies it and a program reads it as data. Corners carry the color only in slots whose
  translated material multiplies it by its base color or whose program reads it
  (`Vertex_Colors.Multiply_Base_Color`, `.Program`).
- **UV.** The first two; if there are more, a warning.
- **Mounts.** `/Game` is the `Content` folder of the package's project: of the `Content` folders
  that contain it, the first next to a `.uproject` or, with none, the closest (only folders that
  have a `Content` are listed). A package outside any `Content` folder (a pack copied without its
  project) mounts what `source_mount_guess` gives from the name it stores of itself or, if it was
  renamed, `source_mount_near` of a package it imports; `/Engine`, `Options.engine_content` or,
  without it, `UNREAL_ENGINE` (an install or its `Engine` folder) or the newest `UE_<version>`
  install where Epic's launcher leaves them. Each engine plugin with content mounts its own
  (`/Niagara` is `Engine/Plugins/FX/Niagara/Content`, `engine_plugin_mounts`). Walking them reads
  hundreds of folders: importing a single package mounts them only when it reads a package that
  only a plugin can have (`library_plugins_mount`); importing a level, at the start.
- **`/Engine` without Unreal** (`engine.odin`): a `/Engine` material that no mount has, or one
  that reads a missing `/Engine` texture, function, collection or parent, is the engine grid
  (`engine_grid`: the standard model with the `Grid` program of `shaders/materials`, lines every
  world meter and darker every ten), with a warning naming the original reference. With `/Engine`
  mounted, the original is read.
- **Model.** LOD 0; with `Options.hi_res`, the Nanite hi-res of the meshes that have it.
- **Skeleton.** The mesh's reference skeleton, with the name of its `Skeleton`; a bone's path is
  the names from the root. One joint per bone, whose inverse bind is the bone's at rest: the bind
  pose draws the mesh as it is. Bones and inverse binds go to engine space with the geometry. Its
  sockets are the mesh's and those of its `Skeleton` (opened through the mounts) that the mesh
  does not name, as in Unreal; one on a bone the skeleton lacks, or of zero scale, is left out
  with a warning.
- **Weights.** Each vertex keeps its eight largest influences, quantized to bytes that sum to 255,
  and a warning counts those that had more; one without influences follows the root, as in
  Unreal. Sections Unreal does not draw are left out and cloth ones are attached to their bones,
  with one warning each.
- **Morph targets.** LOD 0's, at weight zero, as the mesh's morph targets: the position and
  normal deltas of each corner's row; the tangents MikkTSpace makes follow the shape.
- **Animations.** An `AnimSequence`'s clip carries its name and is in the package's `.anim`;
  importing a mesh does not ask for its animations.
  - Tracks are bound by each bone's path in the animation's `Skeleton` (without it,
    `Not_Found`), comparing names case-insensitively as Unreal does; a track of a bone that does
    not exist is left out with a warning.
  - One key per frame, linear. With `Interpolation` Step each key starts halfway through the
    previous frame, as Unreal takes the nearest frame. Without scales a bone has scale one, as in
    Unreal, even if its rest differs.
  - Curves are `Float` tracks of their name and, those the skeleton marks as morph target, also of
    `/@morph/<name>` (`animation` morph weights). An Unreal key's interpolation (how it goes to
    the next) is the next key's arrival interpolation in Mirai: constant is `Step` and cubic,
    `Cubic_Spline`. Weighted tangents and non-constant extrapolations are warnings.
  - Sync markers are markers. `RateScale` is baked into times and slopes; a non-positive one is
    rejected.
  - With root motion or `bForceRootLock`, the root bone is the clip's root; a `RootMotionRootLock`
    that is not the reference pose is a warning, because Mirai leaves the root at rest.
  - An additive animation is rejected with the reason; notifies are Unreal
    logic: a warning.
- **Collision.** The `BodySetup`'s `AggGeom` (`umesh.body_read`) are the mesh's colliders: boxes,
  spheres and capsules as they are and each convex as a hull of its points; tapered capsules and
  level sets are a warning. With `CTF_UseComplexAsSimple` there are no source colliders: the
  collision is its triangles (the engine's collision).

## Materials (`material`)

`Library` opens each package once by name, through its `Source_Mount`s or with the bytes of
`library_add`; `object_find` and `object_resolve` give an `Object` (an import leads to the export
it names). Everything lives in the library's arena.

- `translate` translates a `Material` or an instance into a `Translated_Material`;
  `landscape_layers` gives the layers of a Landscape material. The result brings the
  `Material_Info` without textures, what each map's image is made of, the value table, the program
  if needed, the vertex color usage, the untranslated expressions per class and `notes` (what was
  approximated or left out, and why).

### Reading

- **Chain.** From the instance to the `Material` through `Parent`: scalar, vector and texture
  values, static switches and masks with `bOverride` and `BasePropertyOverrides`. The closest
  instance wins. A parameter belongs to the material or to a layer or blend of its layer stack
  (`Layer_Ref`, the association and index of its `ParameterInfo`).
- **Material layers** (`MaterialAttributeLayers`): the stack of the closest instance that changes
  it, or the node's (`DefaultLayers`). Each enabled layer is its function in a scope with that
  layer's parameters, the first over the node's input, and each next one over what is below by its
  blend (`Bottom` and `Top`, or its first two material attributes inputs); without a blend, it
  covers it. An instanced layer function contributes its values to that layer, behind those of the
  material's instances.
- **Inputs.** The material's or, in UE5, those of its `MaterialEditorOnlyData`, native or tagged
  depending on the version; a property that was not saved has the class constructor's value.
- **Expressions.** Each class is a case of `expression_build`, with the semantics of Unreal's
  `MaterialExpressionsToMIR`: the whole value, and the input's mask picks the channels. Functions
  are expanded where called; parameter collections give their default; reroutes and quality and
  feature-level switches take their default input, and virtual-texture ones, the branch without
  them; material attributes are attribute rows, and `SetMaterialAttributes` changes its own over
  those of `Inputs[0]`. A `Lerp` alpha of a different width than its ends is its first component,
  as in Unreal.
- **Value table** (`Graph`): one node per operation over earlier nodes, of one to four components;
  equal nodes are one and constants are folded when added. The context values are UV, time, world
  position and normals, the tangent frame, vertex colors, the object (center, radius and corners
  of its bounds, pivot and axes with their scale), the point in the view image and its depth, and
  the scene's behind it: `Transform` between tangent, object (or instance) and world and
  `TransformPosition` between object and world are a program with that frame and those axes;
  `LocalPosition` is the point in object space, `ObjectOrientation` its local Z and
  `ObjectScale`, the length of its axes; `ObjectBounds`, `Bounds` and `ObjectLocalBounds` come
  from the corners and axes.
- **The world from its center.** A world location (`WorldPosition`, the object's center and pivot,
  the coordinates of a whole Landscape) is the one relative to the render origin plus the origin
  (`Origin`), and subtracting two locations removes the origin they share:
  it does not jump when the origin moves.
- **Screen and depth.** `ScreenPosition` (view UV and pixels), `ViewSize`, `SceneTexelSize`,
  `PixelDepth`, `SceneDepth` at its point and `DepthFade`; the scene behind is seen by the glass
  and translucent passes.
- **What only a program computes** (the graph's `PROGRAM`): `Noise` and `VectorNoise`, which call
  `shaders/include/unreal_noise.slang` (the noise functions once, the table-based ones over
  hashed gradients); `TextureProperty`, the texture size on the GPU; and `Custom`, its HLSL as a
  program function with its inputs and extra outputs. HLSL that reads what a program does not have
  (`View.`, `Primitive.`, `Parameters.`, derivatives, `discard`, includes, an Unreal shader
  function that is neither defined there nor HLSL nor its noise) stays in the program as a comment
  with what it reads, for the agent to port to Slang; its function gives zero and the expression
  is counted as untranslated.
- **What is not translated** leaves `NONE`, is counted per class in `untranslated` and the output
  that uses it takes Unreal's value unconnected: what a Mirai program does not see (camera, the
  image behind, particles, distance fields: `SceneColor`, `SceneTexture`, `ViewProperty` and
  `SceneDepth` with own coordinates), UV sets after the second (vertex animation data) and domains
  that are not surfaces (`Error`). Outputs the translation does not read (position, tangent,
  subsurface, depth) are not evaluated, nor is `WorldPositionOffset`: a Mirai material does not
  move its vertices (the engine deforms surfaces with three fixed mechanisms).
- **Approximations** (in `notes`): `ActorPositionWS` is the object's pivot; `PerInstanceRandom` is
  0.5; `VertexInterpolator` passes its input, computed per pixel; `TwoSidedSign` is 1 (Mirai flips
  a back face's frame); `Fresnel` is its reflectance at normal incidence, and the view
  (`CameraVectorWS`, `ReflectionVectorWS`, the direction to `CameraPositionWS`) is the normal:
  Mirai reflects by the view and what imitates it sees the surface head-on;
  `EyeAdaptationInverse` is 1 and leaves emission relative to exposure (`Relative`); a sample's mip
  modes are left to Mirai; additive blend is a layer that does not cover.
- **Legacy is adapted.** View-dependent relief (`BumpOffset` and the `/Engine`
  `ParallaxOcclusionMapping` function) is the surface without relief: its UVs are the ones it
  receives, without depth displacement or self-shadow. `FuzzyShading`, which lightens a cloth's
  edges by the view, is its core as color and its edges as that color's `fuzz`, with
  `EdgeBrightness` as weight.

### Translation

- **Standard model.** Each output is a constant factor times a per-texel part whose samples read
  the same coordinate, affine in a UV set:
  the factor is the material's value and the part, the map's image, with the coordinate's scale
  and offset. Color and opacity share the color map; roughness (green), metallic (blue) and
  occlusion (red, if it reads the same coordinates) share one image.
- **Units.** Base color and emission are linear; emission is luminance in nits. Specular `s` is
  F0 = 0.08·s: an IOR from F0 2% and, below that, the 2% IOR with `specular_factor`; a textured
  specular is the specular map over the IOR of F0 0.08.
- **Normal.** A normal map read as is or the per-texel function baked; a `lerp` from the flat
  normal is `normal_scale`.
- **Shading models.** Unlit is `unlit` with its emission; clear coat, a coat of IOR 1.5; cloth,
  fuzz (`SubsurfaceColor` the color, `ClearCoat` the weight). `TwoSidedFoliage`, and `Subsurface`
  or `PreintegratedSkin` in a `TwoSided` material (a sheet), are diffuse transmission: Unreal
  reflects the base color `b` and adds what `SubsurfaceColor` `s` lets through from behind, and
  Mirai splits the same light with weight `max(s) / (max(s) + max(b))` and both colors divided by
  their part, scaled to what the surface receives if they sum more (`diffuse_transmission_split`).
  On a solid, `Subsurface` and `PreintegratedSkin` are lit opaque with the light they scatter
  added to the base color (`SUBSURFACE_BACKSCATTER`); `SubsurfaceProfile` is lit opaque: the
  renderer has no subsurface. Translucent with refraction above 1 is glass with that IOR.
- **Vertex colors.** A standard-model base color multiplied by them drops them
  (`Multiply_Base_Color`), because that model always multiplies them; a program reads them as data
  (`ctx.vertex_color`) with its whole base color (`Program`); `Unused` says a mesh may discard
  them.
- **Particles.** `DynamicParameter` (of index `ParameterIndex`) reads what the particle of the
  sprite that draws the point gives (`ctx.particle_data`), and its `DefaultValue` where it does
  not, as a dynamic parameter does; the `unreal_vfx` bridge passes it from Niagara
  attributes. `ParticleRandom` is the particle's random value (`ctx.particle_random`) and
  `ParticleRadius` half its sprite (`ctx.particle_radius`). `ParticleColor` is the particle's
  color, which the sprite gives its program as `ctx.vertex_color` and does not multiply, as in
  Unreal.
- **Program.** If an output does not fit, the whole material is a Surface program written from the
  table (`slang.odin`): Unreal textures and parameters are its parameters (those past the limit
  stay constant), position and normals go to centimeters and Z up, normal maps are unpacked and
  the tangent normal goes to the world with the MikkTSpace frame. Its name is the base material
  and a hash of what it computes: instances that only change values share a program.
- **Textures written while the game runs.** A render target that writes a grid, or a texture
  parameter Unreal fills at runtime (FluidNinja's buffers), has no image: `Options.reads` names
  each by its object path or parameter name, with the function that reads it by UV and its
  include, which the plugin that writes it gives (`vfx_world_texture_uv` of its grid). The program
  calls that function where Unreal samples; the texture is not a program parameter. Without a
  read, the empty parameter is not translated.
- **Landscape.** `landscape_layers` evaluates the graph once per layer;
  `LandscapeLayerCoords` is the Landscape's UV 0 with its scale, rotation and offset, and
  `LandscapeVisibilityMask` is 1: holes belong to the terrain. Without a layer, `translate` shows
  the first.
- **Whole Landscape** (`Options.landscape`, a `Landscape_Mapping`): the program the terrain shows
  with its layers. Each layer weighs what the terrain layer that shows it does (the terrain's
  `uv0` and `uv1`, `Layer_Weights`) and one the terrain lacks is left out, like one a component
  does not paint; `LandscapeLayerBlend` sums the weight and height ones over their sum when it
  exceeds 1 and puts the alpha ones on top, as Unreal does without
  `landscape.UseLegacyLayerBlendMaterialExpressionBehavior`. The Landscape's coordinates (every UV
  set) come from the world position through the actor's transform, and the tangent frame follows
  its axes over the normal, not the terrain's tangents. What only a layer reads (its input and
  height) is computed where the layer is painted: a `Gate` graph node, which the program writes as
  a branch on the weight that gathers everything of that layer. Without weight, the input is zero
  (or each attribute's default) and the height zero: what Unreal sums from an unpainted layer,
  except the minimum weight (`0.0001`) of a height one.

### Writing (`material/write`)

- `Builder` reads each Unreal texture once and builds the images by key: a texture read as is with
  its map's usage is shared among materials; otherwise `image_bake` evaluates the table at each
  texel at the size of the largest texture it reads, bilinear and repeating, and an emission above
  1 goes to the factor. A baked image carries the name of the material that uses it and the alpha
  cutoff of its base color is the material's: what a package writes does not depend on which
  package of the level shared the `Builder` before.
- `reader_material` adds the material and its images to a format's `Reader` (for a mesh's slots);
  the notes are model warnings. `materials_write` writes `.mat` and `.tex` as parts of an
  `importer.Outputs` (`importer.output_model`), under a prefix of their names, and each program into
  `shaders` without rewriting an identical one.

## Levels (`level`)

Shared contract of the level importer: what is in a `.umap` and where, in Mirai space. Unreal
names (classes, properties) stay in each type's translators.

- **Library.** `Library` opens packages by long name through `Source_Mount`, once; a package that
  fails stores its error. Needed for Blueprint archetypes and external actors.
- **Document.** `document_open` reads each `Level` (also the old actor array), the actors and the
  objects whose outer is each actor, contiguous per actor, with `AttachParent` and
  `AttachSocketName`. Everything is named by indices; an object is a `Ref{pkg,object}`.
- **External actors.** With `bUseExternalActors` (World Partition) the packages under
  `__ExternalActors__/<map path>/` whose outer is its `PersistentLevel` are added; without the
  mount of their content, an error asks for it. Two packages with an actor of the same path (one
  left over from moving the actor or copying content on top) are one, as in Unreal's asset
  registry: the one named by the hash of that path (MD5 of the lowercase path, in base 36, split
  1/2/22 or 2/2/21) or, if none, the first by name; the others go to `superseded` and the import
  reports it.
- **Properties by archetype.** `property` searches the object and then its archetypes, also from
  other packages, and says the origin: `Authored`, `Archetype` or `Native` (the native class's
  defaults, which the reader applies). Without a saved template, as in most UE4 subobjects, the
  archetype is the one Unreal looks for: the object of its name under
  its outer's archetype and, if none, what is found going up the Blueprint class and its Blueprint
  super classes: the `SCS_Node` template of that variable; if the class has no such node, the one
  its `InheritableComponentHandler` stores for an inherited component it changes (the record whose
  `ComponentKey` names the variable, or whose template is so named); otherwise, an object of that
  name under the class. One of those inherited templates has as archetype the object of its name
  in the closest super class that has it (that of a `DefaultSceneRoot`, without its `ICH-` prefix).
- **Transforms.** `SPACE` is Unreal's space for the engine importer. `component_relative` gives
  Unreal's values with the defaults of `SceneComponent` or of the actor's native constructor
  (`NATIVE_RELATIVES`: directional and spot lights, decals and `DefaultPawn`'s mesh; no other
  native ContentExamples class moves a subobject that is not editor-only); `component_local` and
  `component_world` give them in Mirai, the second composed through `AttachParent` with the
  absolute parts as they are.
- **Sockets** (`sockets.odin`). A component with `AttachSocketName` is relative to where that
  socket of its parent is (`component_socket`, as in Unreal): for a static mesh, its
  `StaticMeshSocket`; for a skeletal mesh, its socket or its skeleton's (the mesh's first) on its
  bone, or the bone of that name, in the mesh's bind pose; for the `SpringArmComponent`,
  `SpringEndpoint`: the arm at rest, without the lag or the collision sweep a game does, and with
  the actor's rotation if it follows the pawn's. Names are compared case-insensitively; one the
  parent lacks is the parent, as in Unreal. Meshes and skeletons are read once per document; one
  that cannot be read, a spline mesh socket (which curves with it) and an arm that does not
  inherit pitch, yaw or roll are errors of the component's placement.
- `resolve` gives a reference's export, opening its package if it is an import;
  `actor_native_class`, the native class an actor derives from through its Blueprints.
- **World Partition** (`partition.odin`). `partition_read` gives the cells of the grids of a
  `WorldPartitionRuntimeHashSet` (UE 5.4 onward; the earlier `RuntimeSpatialHash` is
  `Unsupported_Value`): for each `RuntimePartitionLHGrid`, its cell size, origin, 2D or 3D, loading
  range and box method; a `RuntimePartitionPersistent` loads with the map. An actor with
  `bIsSpatiallyLoaded` (by its archetype or its native class default: lights, `Info` and those
  that turn it off in their constructor) goes to the cell of its grid (`RuntimeGrid`, or the
  first) that holds its bounds' center, at the loose hierarchy level its size asks for, and is
  named as in Unreal (`<grid>_L<level>_X<x>_Y<y>_Z<z>`). A level 0 cell's box is what it holds
  inside the cell (or the cell, or what it holds, depending on its grid); above, what it holds.
- An actor's bounds are those of its non-editor primitive components: the mesh by the bounds its
  package stores (`ExtendedBounds`), each instance of an instanced one, a spline mesh by its
  curve's hull, a Landscape component by its `CachedLocalBox` and shapes by their size; with none,
  the point where it is. Unreal uses the ones its editor stored in the actor descriptor, which is
  not read: an actor next to an edge may fall in the neighboring cell. Data layers and actor sets
  do not separate cells.
- Approximations: composition with negative scales is done by parts; streaming levels are other
  maps.

## Landscape (`landscape`)

`landscapes_read` gives a `Landscape` per `LandscapeGuid`: that guid's proxies and their
components, in a grid.

- **Grid.** The rectangle of the `SectionBase`s. Mirai's x runs along Unreal's +Y and z along its
  -X, and each Heightfield cell is split along the same diagonal Unreal uses in its quad.
- **Heights.** From `HeightmapTexture` (16 bits in R and G) with its offset and subsections, which
  repeat the edge vertices, in meters by the actor's Z scale; a shared texture is decoded once.
- **Spacing.** `spacing` is the actor's X scale (along Mirai's z) and `transform`, the grid's
  center in the world: the grid is of square cells, and a different Y scale stretches it across,
  in `transform`'s x scale (Y over X).
- **Layers.** Each `LandscapeLayerInfoObject`'s weight per sample, as Unreal paints them
  (unnormalized), with its coverage; the name is its `LayerName` if the layer info is under a
  mount and, otherwise, the object's.
- **Holes.** The visibility layer is not a layer: a quad is a hole when its first vertex weighs
  more than Unreal's collision threshold, and so are those of the rectangle without a component.
- Rejections: components of different sizes, invalid subsections, missing heightmap, null or
  negative X or Y scales. Edit layers are read already combined, as Unreal stores them; the
  material is the proxy's `LandscapeMaterial` path.
- `landscape_terrain` (plugin `unreal_terrain`) converts it to a Heightfield source:
  [terrain](translators.md#terrain-unreal_terrain).

## Foliage (`foliage`)

`foliage_read` gives a `Foliage` per `InstancedFoliageActor`: its types and their instances in
Mirai space.

- **Native data.** The actor's comes after what `Actor` stores, which since
  `SerializeActorLabelInCookedBuilds` says whether it was cooked (`level.actor_native_payload`; a
  cooked one is rejected).
- **Instances.** From the record the editor stores per type (`FoliageInfos` or, in old versions,
  `FoliageMeshes`): world transform, whether it was placed on something, the component it was
  placed on and its height over that point (`ZOffset` by its scale, along its up). Deleted ones
  are not output.
- **Type classes** (`Foliage_Kind`, each one's `FoliageImplType`). `Static_Mesh` names the
  component that draws it. `Actor` (`FoliageType_Actor`) placed an actor of its class on each
  instance, which the level stores among its actors: `Instance.actor` names it (-1 if absent, and
  Unreal's editor places it again). `ISM_Actor` (the same type with `bStaticMeshOnly`) draws the
  static meshes of its class with instanced components of the `InstancedFoliageActor`, one per mesh
  and settings, shared by those types: `Foliage.components` are those of its
  `DescriptorComponents`. Actor types are named by the class they place.
- **Check.** Each static mesh instance is compared with the matrix of the component that draws it,
  in the same order (`compared`, `mismatched`, `max_difference`; `uncompared` if the component is
  not at the origin or its format is unknown).
- **Types.** From `FoliageType_InstancedStaticMesh` or `FoliageType_Actor`, from the actor or
  another package, with the defaults of `FoliageType`'s constructor. Bases with `SoftObjectPtr`
  are skipped depending on their version; with no corpus that uses it, that path is not verified,
  like actor and ISM actor types (ContentExamples has none).
- `foliage_source` (plugin `unreal_foliage`) converts it to a `.foliage` source:
  [foliage](translators.md#foliage-unreal_foliage).

## Levels to scene (`scene`)

`level_import` (package `unreal_scene`) writes a `.umap` as a project scene in `options.root`,
which must be a project (`project.mirai`); `document_import` does the same with an open
`level.Document`. `Level_Report` brings what was written, the actors per class (how many and how
many were translated), the lights with their Unreal and Mirai values, the cameras with their
entity, the imported meshes and the time.

- **Mounts.** Those of [`model`](#model-format-model): `/Game` of the `.uproject` (or of the name
  the map stores of itself), `/Engine` of the Unreal install and that install's plugins. Without
  `/Engine` mounted (`engine.odin`), an Unreal basic shape is the Mirai primitive of its
  `Mesh_Renderer` and a missing `/Engine` material, the engine grid, written with the materials
  the level stores. What is read from `/Engine` is not an input of the import.
- **Names.** What is imported from Unreal is named without the prefix its conventions give each
  type (`SM_`, `SK_`, `M_`, `MI_`, `T_`, `BP_`...): `asset_name` is the only place that knows them.
  `SM_Rock.uasset` writes `Rock.mesh` in `Rock/` (`model_folder`), and a material `MI_Rock`,
  `Rock.mat`; two packages of the same name take `Rock (2)/`. What is looked up inside a package
  keeps using the Unreal name.
- **Sources.** The map is a source in the assets, and the packages of `/Game` it reads
  (`level_packages`: what its imports and soft references name and theirs, and the World Partition
  packages of its actors and objects, never its build data) sit at their paths under `/Game` with
  it: `level_bring` copies them there from outside. They are the inputs of its import
  (`importer.output_input`), so a changed package or a clone without the imported folder makes the
  build import the map again.
- **Files.** One import owns everything the map makes, in the folder of its import (`<map>/`
  beside it, or what its sidecar says): the scene, and as parts named `<package>/<name>` (under
  `<package>/`) what each package the level names gives as the `model` format reads it (meshes,
  slot materials, textures, clips; no prefab: the scene places the meshes), the materials
  components override and the sky, and at the root what the level stores and plugins write.
  A single `material.Library` and a single `write.Builder` serve the whole level: each package is
  opened and each texture decoded once, while memory allows. The packages of meshes and overridden
  materials are read ahead ([read-ahead](#read-ahead)).
- **Identity.** The scene is the root of the map's import (`importer.output_root`) and the sections
  and what plugins write, its parts by name (`importer.output_part`, `importer.output_model`).
  Sections take file and id when written, only those with something and all at once
  (`importer.output_parts`): each first finds the previous one of its name. Each entity's id is the
  hash of its actor's path in the map (with its package if external: two World Partition packages
  can have actors of the same name) and of its component's name, which Unreal keeps even if the
  label changes: reimporting gives the same scene with the same ids.
- **Sections.** A World Partition map is the map's scene and one scene per cell
  ([partition](#levels-level)) in `<cell>.scene` of the folder of the import, each referenced from
  the map's scene by an entity named after the cell, at the center of its box, with a `Spatial`
  `Scene_Reference` of that box: the `streaming` plugin loads it by where the players are. What is
  at a section's root is where it is from that center. What loads with the map, what the level gives
  once (sky, exposure) and what translators with `root` write (terrain, which loads its pages
  itself) stays in the map's scene; a cell that gives nothing is not written. Each grid's loading
  range is a warning: Mirai loads sections within the project's `Streaming_Settings` distances.
- **Entities.** An actor that shows something is an entity with its label where its
  `RootComponent` is, and what each component shows, a child entity with its placement relative to
  the actor (`transform_relative`, exact for Mirai's composition). A single-component actor is
  that entity, without a group on top. Actors go to the scene root.
- **Blueprints.** Actors of a Blueprint class are instances of a class prefab of the import,
  made of the first one's entities with the root at the origin and the class name. What each actor
  shows differently (what its construction script chose, its transforms, its label) are overrides
  of its instance, and editing the prefab changes all. An actor whose components differ from the
  first's stays apart, with a warning.
- **Meshes.** `StaticMeshComponent` is `Mesh_Renderer` with the imported mesh and, per slot row, the
  material of `OverrideMaterials[index]` (the slot id is Unreal's index plus one); one equal to the
  mesh's, or of a slot the mesh does not draw, does not count. A material the level stores inside an
  actor (a construction script's `MaterialInstanceDynamic`) is translated from its `.umap`, named by
  the objects that contain it and goes to the root of the import, together with the level's others
  in a single import at the end, after the translators: it reads by UV the textures they added
  (`texture_read_add`, the render target a Niagara component gives its system). Writes of one
  package in an import number their materials after the previous ones (`material_index`): the
  importer pairs by index a material it does not recognize by name. Instanced components
  (`InstancedStaticMeshComponent`, the hierarchical one and the foliage one, and those PCG and
  packed level actors bake) are never one entity per instance: the translator with `instanced` in
  its scene takes them, the `foliage` one, as foliage batches
  ([foliage](translators.md#foliage-unreal_foliage)); without it, their actor is a warning saying
  how to import it. Those hidden in game are left out, with a warning. Their instance matrices come
  from the `PerInstanceSMData` array of their native payload, which follows what
  `StaticMeshComponent` stores (LODs and painted vertices, of variable length depending on the
  save): it is found by size, count and a first matrix of row vectors (`level.instances_read`, which
  the foliage check also uses). A `SplineMeshComponent` is not translated: it is a warning.
  `SkeletalMeshComponent` (of a `SkeletalMeshActor` or any Blueprint, such as a character) is the
  same with the skinned mesh (`SkeletalMesh`, which wins as in Unreal, or `SkinnedAsset`), drawn in
  its bind pose as its import's prefab draws it. In `AnimationSingleNode` it plays the clip of the
  `AnimSequence` of its `AnimationData` (its package's parts in `<package>/`): `Animation` with
  `bSavedLooping`, `bSavedPlaying`, `SavedPlayRate` as `speed` and `bUpdateAnimationInEditor` as
  `preview`, and `SavedPosition` as its `Animation_Progress` (over the `RateScale` the clip's times
  have). The single-node instance takes no root motion from a sequence: one that forces its
  `bForceRootLock` stays in place (`In_Place`). An Animation Blueprint (`AnimClass`) is logic: a
  warning and the bind pose. False `bVisible` or `bHiddenInGame` are `Hidden`; the actor's
  `bHidden`, `Hidden` on its entity.
- **Lights** (`lights.odin`). Unreal lights with an intensity times 100²; Mirai stores candelas in
  a point or spot light, the face's luminance in a rectangle and lux in the sun, and divides by π
  where its renderer asks:
  - candelas as they are; lumens of a point light over 4π and of a spot over its cone,
    2π(1−cos θ), with θ the outer half angle clamped as in Unreal; no unit, ×16/100²; EV100, 2^EV;
    nits of a point light by the area of its capsule (`SourceRadius`, `SourceLength`);
  - a rectangle: nits as they are and the rest over its area (`SourceWidth`×`SourceHeight`), which
    is its entity's scale; a rectangle saved with EV before `RectLightFixedEVUnitConversion` keeps
    Unreal's old computation;
  - the color is linear `LightColor` times `ColorTemperatureToLinear` with `bUseTemperature`; a
    channel above one goes to the intensity. `AttenuationRadius` is `range` and `SourceRadius`,
    `radius`. Unreal lights toward the component's +X, Mirai's -Z, and the entity has scale one.
    False `bAffectsWorld` leaves the component off.
  - Warned, with count: no inverse-square falloff (candelas that give the same at half the radius),
    `SourceLength`, IES, light functions, no shadows and cones outside 1° to 89°.
  - Mirai lights with one sun: with several directionals the brightest stays on.
- **Cameras.** `CameraComponent` and `CineCameraComponent` are `Camera` on an entity with the
  actor's label (`Camera_Note.entity` is what `mirai capture --camera-entity` takes). Vertical fov:
  for a cine camera, from the sensor height (`Filmback`) and `CurrentFocalLength`; for another,
  from horizontal `FieldOfView` and `AspectRatio`. `active` if the actor is activated for a
  player. What its `PostProcessSettings` override of exposure is its `Exposure`.
- **Sky and exposure.** The level gives a `Sky` entity. Without a `SkyLight` it does not light, as
  in Unreal; with one, it lights by its `Intensity` and color with the sky-to-sun ratio of Mirai's
  `Sky`, taken from the level's brightest sun, and a warning: what Unreal captures from the scene
  has no equivalent. With `SLS_SpecifiedCubemap`, the `Sky`'s image is its `Cubemap` turned on
  import into a long-lat image (`sky_of_cube`, a `.tex` next to the materials, import of the cube's
  package), and its entity rotates by `SourceCubemapAngle` around up, as Unreal rotates the cube.
  Behind the scene the sky shows if the level draws it (`SkyAtmosphere`, `AtmosphericFog` or the
  engine's sky sphere), and otherwise black; with an atmosphere, the `Sky` is the air the sun lights
  (`atmosphere`), unless the `SkyLight` names a cube: Mirai's `Sky` draws the image or the air, and
  the cube wins, with a warning. `VolumetricCloud` is a warning: Mirai draws no clouds.
  An unbounded `PostProcessVolume` (the highest priority) gives the `Sky`'s exposure: method
  (manual or automatic), compensation, adaptation speed, the physical camera (f, shutter and ISO)
  and the minimum and maximum brightness, which Unreal takes to white and Mirai to mid gray: the
  EV100 that makes that luminance white (Unreal's EV100 over `LuminanceMax` if the project extends
  the range, luminance as UE4 if not). The rest of what it overrides and a bounded volume are
  warnings; `ReflectionCapture`s, which GI replaces, what only Unreal's editor uses, World
  Partition's HLOD (Mirai's is per cell), minimaps, `GPULightmass`, virtual texture volumes (their
  layers are the terrain's), a Landscape's Nanite and proxy components, the PCG graph and a packed
  level actor's level (its instances show it) are omitted without a warning.
- **Texts.** `TextRenderComponent` is a fixed `World_Widget` on the component's entity, facing
  where the text faces in Unreal (its +X, Mirai's -Z), with its own `.ui` in the import: a
  line measures `WorldSize` times `YScale`, in its color, aligned as Unreal aligns it and with
  `<br>` as line break; equal texts share the `.ui`. `TextProperty` is read as the text it shows
  in the source culture (`None` and `Base` histories).
- **Plugin translators.** A `Translator` takes the actors of its native classes, one scene at a
  time, and is provided by an `unreal_*` bridge plugin ([translators](translators.md)): terrain,
  foliage, physics, fog, particles, navigation and the fluids' textures. Without a class's bridge,
  its actors are warnings saying which plugin to enable, and the meshes have no collision.
- **What is not translated** is a warning per class with its count: sounds, BSP, Blueprints that
  show nothing Mirai translates, and the untranslated components of translated actors. Warnings
  repeated by the meshes' imports are given once.

### Read-ahead

With a job system in `Import_Options.worker`, the packages of the meshes the level names
(`reads.odin`) are read and built (`importer.model_cook`) in jobs while the level is translated,
in the order the translation asks for them: of each scene, its actors' meshes and then the
instanced components, if a translator takes them. After a component's mesh go the materials from
other packages that it overrides: a job translates them and builds their images in the level's
`Builder`, where the translation finds their textures decoded. The translation writes each one,
with its ids, when it reaches it, one after another: what is written is the same as without
read-ahead.

- **Memory floor.** A level import leaves `MEMORY_FLOOR` of the machine's memory free, measured at
  that moment (`base.memory_stats`). A read starts if the available memory, minus what the running
  ones are estimated to still take (`READ_COST` bytes per package byte), stays above the floor, and
  no more run than workers; a package that does not start is read by the translation when it
  reaches it, after writing and releasing the previous ones and, under the floor, after releasing
  the images and after the running reads finish. With memory under the floor, the `Builder`
  releases its images before building materials if nobody is outside (`builder_room`), and the
  level, between imports, after the decoding jobs (`builder_settle`); textures are decoded again,
  one at a time while memory is short. It never fails for memory: it goes slower. If the system
  does not say how much there is, there is no floor.
- A package requested before its turn is read at once. Those started before the request, which the
  translation passed over, stop occupying a worker: otherwise read-ahead stalls. Packages of what
  the translation does not ask for (silent or editor-only actors, hidden instanced ones) are not
  read.
- The translation waits for a package without running other jobs: a long one would delay it.
- `c.lib` and `c.images` are shared: whoever uses them takes `c.library_lock`, never while waiting
  for a job. Translators have their own Oodle decoder (`decoder(c)`).
- A texture is decoded without the lock: the `Builder` releases it while decoding with the
  requester's decoder and memory, and takes it again to store the pixels; whoever asks for one
  another decodes waits for it, and each texture is decoded once; what the `Builder` says about a
  texture it says to each material that uses it. While `builder_settle` waits, textures are decoded
  with the lock. Without a lock (importing a single package) it decodes the same, releasing
  nothing.

## Diagnostics (`inspect`)

The API method `unreal.inspect` (plugin `unreal`, `api.odin`; package `inspect`) walks `.uasset`
and `.umap` files or a folder of them without writing assets and leaves its report in the
project's `.mirai/tmp/unreal-inspect.txt`. Its parameters are in `engine.describe`.

- `Summary`: versions, tables and exports; `Objects`, properties and native tail; `Payloads`, the
  payloads checked with BLAKE3.
- `Textures`, `Meshes`, `Skeletal`, `Anims` and `Materials` read or build each object of their
  type, with one line per object and a summary of approximations and failures by cause, and
  compare what can be checked: bounds against `ExtendedBounds` or `ImportedBounds` (which UE4's
  FBX importer stored enlarged), a mesh's description against its LOD model, a texture's `Id`.
  `out` (under `.mirai/tmp/`) receives the PNGs of `Textures` and the Slang programs of
  `Materials`, for `mirai shaders check`.
- `mounts` (`/Prefix=folder`, several): without a `/Game` one, the most voted of the first
  packages is deduced, and without a `/Engine` one, the install the importer finds
  (`engine_content_find`), to expand its functions like it does.
- `Level`: per `.umap`, actors and components by class, failing transforms, where each
  `RelativeLocation` comes from, the World Partition partition (grids, cells per level, what loads
  with the map by class and, per cell, its actors, instanced components, instances and foliage
  types by mesh and materials, without Unreal's HLOD), each landscape and each foliage with its
  comparison.
- `hi_res`: in `Meshes`, the high-resolution model instead of LOD 0.

False `ok` says something failed; the report says what.

## Verification

All with `mirai test` on the package folder inside a project with the plugin installed.

- `editor/package`, `kraken` and `texture`: synthetic UE4/UE5 packages, trailer, bulk data, zlib,
  a minimal encoder of each Oodle format (`kraken_test.odin`, `formats_test.odin`) and UE4
  textures; damage trims and changes bytes and each attempt decodes or is rejected.
- `editor/mesh`: the three places of the source model with sections, materials, colors, UVs,
  normals by soft and hard edges, build scale and damage; polygons without triangles
  (`a_description_saved_before_triangles_takes_the_triangles_unreal_5_makes_of_its_polygons`);
  influences and welding of a description with skeleton
  (`a_description_keeps_the_influences_the_build_and_the_project_allow`,
  `a_description_welds_corners_within_the_thresholds_of_its_build`); skeletal meshes of every
  layout (`skeletal_meshes_of_every_layout_read_their_skeleton_materials_and_lod_0`,
  `a_skeleton_reads_its_reference_skeleton_and_sockets`,
  `damaged_skeletal_meshes_are_read_or_refused`); animations of every layout
  (`animations_of_every_layout_read_their_bone_tracks_curves_and_markers`,
  `additive_and_rate_scaled_animations_say_so`, `damaged_animations_are_read_or_refused`); pose
  assets (`a_pose_asset_is_a_frame_per_pose_after_its_base_with_its_names_and_curves`,
  `pose_assets_that_do_not_add_up_or_are_damaged_are_refused`).
- `editor/model`: space, slots, materials, mounts, skeletons and inverse binds, morph targets and
  sockets, source collision, `/Engine` without Unreal and clips of each format sampled against
  their source, `RateScale` and additives.
- `editor/material` and `material/write`: synthetic UE4 packages (`material/fixture`) with a
  standard graph, tagged inputs, instances with static switches, functions, Landscape and material
  layers, a program, screen, depth, bounds, the world with its origin, `Custom`, noise,
  untranslated classes and damaged bytes; writing reads back `.mat` and `.tex` and reimports over a
  changed parameter.
- `editor/level`, `landscape` and `foliage`: Unreal space against rotation matrices, archetypes
  from another package and by SCS, inherited templates
  (`an_inherited_component_a_blueprint_changes_takes_its_override_template`), native constructor
  defaults, sockets (`sockets_test.odin`: of a static mesh, of a skeletal mesh and its skeleton or
  a bone, a spring arm's end), cells of a loose grid
  (`an_actor_goes_to_the_cell_of_its_center_at_the_level_its_size_asks`,
  `a_map_of_world_partition_is_the_cells_of_its_grid_and_what_loads_with_it`), repeated external
  actors (`of_two_external_packages_with_the_same_actor_one_is_read`), grid, subsections, layers,
  holes, different X and Y scales
  (`a_landscape_scaled_differently_along_x_and_y_is_its_grid_stretched_across`), bases, types,
  foliage of actors and of ISM actors
  (`foliage_of_actors_and_of_ism_actors_names_the_actors_and_components_that_show_it`) and the
  foliage check.
- `editor/scene`: synthetic maps (`fixture/files.level_begin`) with mesh and override, spot in
  lumens, cine camera, plugin fog, sound, `Character` and `SkeletalMeshActor`
  (`a_skeletal_mesh_of_a_level_is_the_skinned_mesh_of_its_import_with_its_overrides`) and a World
  Partition one (`a_map_of_world_partition_is_a_scene_that_references_a_section_for_each_cell`):
  the written scene, its sections, a test translator with each scene's instanced components,
  reimporting with the same ids and light conversions.
- `editor`: the editor integration, with the plugin's formats as the editor finds them
  (`Unreal_Format`, `Unreal_Maps`): a static mesh and a skeletal mesh as their assets and prefab,
  damaged packages imported or rejected, a map as a project scene
  (`an_unreal_map_imports_as_a_scene_of_its_project`) and the Surface programs an import
  publishes. The bridges' translators: [translators](translators.md#verification).
- Corpus, on the test projects: `unreal.inspect` with `Meshes`, `Skeletal` and `Anims` without
  failures except cooked ones or ones that draw nothing and with matching bounds; with `Skeletal`,
  each description against the LOD model it stored (triangles, bounds and influences; a LOD model
  saved in a project with other influence settings differs in them); `Materials` with `out` and
  `mirai shaders check` of each program without errors or warnings; `Textures` with an `-o:speed`
  build, without failures or unexpected `Differs`, comparing the `out` PNGs against an Unreal PNG
  export with `mirai image diff` (with normal maps' green inverted); `Level` without transform or
  partition failures nor foliage instances different from their component.
- Against the ground truth, Unreal in command mode (`UnrealEditor-Cmd -run=pythonscript`) on a
  copy of the project exports transforms, heights and instances; it is never an import path.
- `MIRAI_UNREAL_MAP` and `MIRAI_UNREAL_PROJECT` make
  `an_unreal_map_of_the_environment_imports` (`editor`, with `--release`) import a corpus map with
  the map importer, without translators; without them it does not run. The bridges' translators
  are tested on the corpus in an editor session.
- No real asset enters the repository; fixtures are synthetic.
