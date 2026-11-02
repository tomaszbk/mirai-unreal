package uasset

import "core:strings"
import "mirai:asset"
import material "project:plugins/unreal/editor/material"

// What stands for the content of /Engine when no Unreal installation is
// mounted: a material of the engine, or one that reads a texture, function,
// collection or parent of the engine, is the grid of Mirai (the Grid program
// of the engine), as Unreal shows its own WorldGridMaterial when a material
// is missing. With /Engine mounted, the content of Unreal is read as it is.

ENGINE_PREFIX :: "/Engine/"
GRID_PROGRAM :: "Grid"

// Whether path names content of /Engine that no mount holds.
engine_missing :: proc(lib:^material.Library,path:string) -> bool {
    if !strings.has_prefix(path,ENGINE_PREFIX) {return false}
    _,found:=material.object_find(lib,path)
    return !found
}

// The content of /Engine that no mount holds that a translation reads: a
// texture, a function or a collection; "" when it reads none.
engine_missing_read :: proc(lib:^material.Library,t:^material.Translated_Material) -> string {
    for path in t.missing {if strings.has_prefix(path,ENGINE_PREFIX) {return path}}
    for ref in t.graph.textures {if engine_missing(lib,ref.path) {return ref.path}}
    return ""
}

// The content of /Engine that a failed translation needed and no mount
// holds, as its error names it (a parent); "" for another failure.
engine_missing_named :: proc(lib:^material.Library,message:string) -> string {
    at:=strings.index(message,ENGINE_PREFIX)
    if at<0 {return ""}
    path:=message[at:]
    if end:=strings.index_byte(path,' ');end>=0 {path=path[:end]}
    return path if engine_missing(lib,path) else ""
}

// The grid of the engine as the translation of the material at path: the
// standard model with the Grid program and its defaults.
engine_grid :: proc(path:string) -> (t:material.Translated_Material) {
    name:=path
    if dot:=strings.last_index_byte(name,'.');dot>=0 {name=name[dot+1:]}
    t.name,t.path,t.material=name,path,GRID_PROGRAM
    t.info=asset.MATERIAL_DEFAULTS
    asset.text_set(t.info.program[:],GRID_PROGRAM)
    for &image in t.images {image=material.MAP_NONE}
    return
}
