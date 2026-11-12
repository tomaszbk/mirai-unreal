# Plugin `unreal`: importing Unreal Engine content

The `unreal` plugin reads Unreal editor packages (uncooked `.uasset` and `.umap`, like the ones on
Fab) without Unreal installed and translates them to Mirai assets and concepts. It is all
editor-side (`parts: Editor, Shaders`): a game carries no plugin code, only the programs its
imported materials include (`shaders/unreal_noise.slang`). The engine knows nothing about Unreal:
the plugin is installed into a project from the Mirai catalog (`mirai plugin add unreal`), which
puts it in the project's `plugins/unreal` with its companions.

## What is here

- The root is the `unreal` plugin: the reading and translation packages, the model format, the map
  importer and the API method `unreal.inspect`.
- `plugins/`: its companions `unreal_terrain`, `unreal_foliage`, `unreal_physics`, `unreal_fog`,
  `unreal_navigation`, `unreal_vfx` and `unreal_fluids`, automatic bridges (`automatic: true`,
  editor-only). Each depends on `unreal` and on the plugin it translates for, and gives the
  importer the translator for its actors or the textures its systems write.

The `editor/` packages are imported as `project:plugins/unreal/editor/<package>`:

- `package`: the editor package (tables, properties, payloads); `kraken`: the Oodle decoder;
  `texture`, `mesh`, `material` (with `write` and `fixture`), `level`, `landscape`, `foliage`.
- `model`: the `.uasset` model format (`FORMAT`), and `scene`: a map as a project scene
  (`level_import`).
- `inspect`: the diagnostic behind `unreal.inspect`; `fixture`: synthetic packages for tests.
- `api.odin` and `unreal.odin`: the plugin's storages, below.

## Map

- Packages, payloads, Kraken, textures, meshes, skeletons, animations, materials, levels,
  Landscape, foliage and maps as scenes: [unreal.md](unreal.md).
- What each bridge plugin translates (terrain, foliage, physics, fog, navigation, particles) and
  the translator contract: [translators.md](translators.md).

## Importing in the editor

The plugin's storages (`unreal.odin`, `api.odin`) are providers the editor reads from the project
library:

- `Unreal_Format` is an `Import_Format_Provider` for the `.uasset` format (`model.FORMAT`): a
  package in the assets is imported like the engine's models, into `<name without prefix>/` beside
  it, with its mesh, materials, textures and prefab, or its clips and skeleton; the packages its
  materials read are the inputs of its import. Its `prepare` gives it the `reads` of the library's
  `Translator_Provider`s (`model.Options.reads`).
- `Unreal_Maps` is an `Import_Source_Provider` that claims a `.umap` by its extension and
  signature. A map from outside the assets comes in with `bring` (`scene.level_bring`): the map and
  the packages of `/Game` it reads (`scene.level_packages`, never its build data) are copied into
  the folder of the browser, each at its path under `/Game`. `prepare` collects the translators and
  `reads` of the `Translator_Provider`s of the library's plugins, and `run` calls
  `scene.level_import`: one import that owns everything it writes, in `<map>/` beside the map.
  The build rebuilds what it keeps in the imported folder from the map and those packages, its
  inputs.
- `Unreal_Api` registers `unreal.inspect` ([diagnostic](unreal.md#diagnostics-inspect)).
- Importing again gives the same ids. An import that writes Surface programs publishes the
  project's programs so its materials render.
- `mirai import` and the engine CLI know nothing about Unreal: a map or a `.uasset` is imported in
  the editor, with `unreal` in the project's plugins. Without the bridge for an actor class, the
  map leaves it as a warning saying which plugin to enable.

## Invariants

- **Engine-time.** Nothing in the plugin is imported from runtime; a game carries only the
  `unreal_noise.slang` program, if its imported materials include it.
- **Unreal concepts do not leave the plugin.** A translator converts to Mirai's (photometric
  units, standard-model materials or a Surface program, scenes, prefabs, foliage); the domain
  plugins (`terrain`, `foliage`...) import nothing from Unreal, and the bridge is the only one that
  imports both.
- **A valid input does not crash the engine.** Each reader bounds bytes, tables and depth
  (`Limits`), rejects a damaged package with `Error{code,offset,field}` and a version it does not
  know, and never reads or writes outside its slices. What it cannot translate is a warning with a
  count, not an invented value.
- **The same bytes give the same assets.** The ids of an import are those its sidecar keeps;
  those of the entities of a scene come from the actor and component path, not from a numbering;
  reimporting keeps what the previous import wrote.
- **Without Unreal installed.** What a package names from `/Engine` is read if an installation is
  mounted and otherwise replaced by something from the engine with a warning.
- **No real asset enters the repository.** Tests use synthetic packages (`fixture`); the real
  corpus lives in separate projects.

## Verification

With `mirai test` on the touched package (`plugins:` packages resolve on their own):

- `mirai test plugins/unreal/editor`: the editor integration (format, maps, published programs).
- `mirai test plugins/unreal/editor/<package>` with `package`, `kraken`, `texture`, `mesh`,
  `model`, `material`, `material/write`, `level`, `landscape`, `foliage` or `scene`; each one's
  focal tests are in [unreal.md](unreal.md#verification).
- tests of `plugins/unreal_<x>/editor` with `terrain`, `foliage`, `physics`, `fog`, `navigation`
  or `vfx`: [translators](translators.md#verification).
- Against a real corpus, `unreal.inspect` and, in an editor session, importing a map with the
  bridges it uses.
