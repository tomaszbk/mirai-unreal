# Mirai Unreal importer

A plugin for the Mirai engine editor that reads uncooked Unreal editor packages (`.uasset` and
`.umap`, such as Fab content) without Unreal installed and turns them into Mirai assets and
scenes: static and skeletal meshes, materials, textures, animations, landscapes, foliage, volumes,
fog, navigation, particles and fluids.

Everything runs in the editor; a game only carries the shader programs its imported materials
include.

## Install

From the catalog, in the folder of a Mirai project:

```sh
mirai plugin add unreal
```

or from the Catalog of the Plugins page in the project settings of the editor. The companion
plugins in `plugins/` (`unreal_terrain`, `unreal_foliage`, `unreal_physics`, `unreal_fog`,
`unreal_navigation`, `unreal_vfx`, `unreal_fluids`) install with it and turn on by themselves
when the project also has the plugin each one bridges. The plugin that `unreal_fluids` bridges,
`fluids`, is not in the engine: it installs from the catalog too (`mirai plugin add fluids`).

## Documentation

[`docs/`](docs/README.md) describes what the importer reads and how it maps it to Mirai.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
