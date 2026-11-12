package unreal_editor

import "core:mem"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import importer "mirai:cook/import"
import "mirai:editor"
import material "project:plugins/unreal/editor/material"
import uasset "project:plugins/unreal/editor/model"
import unreal_scene "project:plugins/unreal/editor/scene"

// Unreal content in the editor: a package (.uasset) is a format of models,
// and a map (.umap) a source imported whole: a scene of the project with the
// assets it names and the actors the translators of the plugins write
// (unreal_scene.Translator_Provider, given by the automatic unreal_* plugins).
// Both read, in their materials, the textures the systems of those plugins
// write as they run (Translator_Provider.reads). A map from outside the
// assets comes in with the packages it reads (unreal_scene.level_bring),
// which are the inputs of its import.

@(storage)
Unreal_Format :: struct {provider:editor.Import_Format_Provider}

unreal_format_default :: proc() -> Unreal_Format {
    return {provider={format=uasset.FORMAT,prepare=format_prepare,release=format_release}}
}

@(storage)
Unreal_Maps :: struct {provider:editor.Import_Source_Provider}

unreal_maps_default :: proc() -> Unreal_Maps {
    return {provider={source={name="Unreal maps",extensions={0=".umap"},claims=map_claims,prepare=map_prepare,run=map_run,release=map_release,bring=map_bring}}}
}

// What an import of a map is given of the session.
@(private)
Map_State :: struct {
    translators:[]unreal_scene.Translator,
    reads:[]material.Texture_Read,
}

@(private)
map_claims :: proc(path:string,head:[]u8) -> bool {
    return strings.equal_fold(filepath.ext(path),".umap") && uasset.sniff(head)==.Content
}

// The textures the systems of the plugins of the library of info write as
// they run, which the materials of Unreal read instead.
@(private)
reads_gather :: proc(info:^core.World_Info,allocator:mem.Allocator) -> []material.Texture_Read {
    found:[editor.PROVIDER_CAPACITY]unreal_scene.Translator_Provider
    out:=make([dynamic]material.Texture_Read,allocator)
    if info==nil {return out[:]}
    for &provider in found[:editor.provided_in(info,found[:])] {
        for read in provider.reads[:clamp(provider.read_count,0,len(provider.reads))] {
            append(&out,material.Texture_Read{strings.clone(read.texture,allocator),strings.clone(read.include,allocator),strings.clone(read.function,allocator),strings.clone(read.name,allocator)})
        }
    }
    return out[:]
}

@(private)
reads_free :: proc(reads:[]material.Texture_Read,allocator:mem.Allocator) {
    for read in reads {delete(read.texture,allocator);delete(read.include,allocator);delete(read.function,allocator);delete(read.name,allocator)}
    delete(reads,allocator)
}

@(private)
format_prepare :: proc(assets:^asset.Registry,info:^core.World_Info,allocator:mem.Allocator) -> rawptr {
    options:=new(uasset.Options,allocator)
    options.reads=reads_gather(info,allocator)
    return options
}

@(private)
format_release :: proc(data:rawptr,allocator:mem.Allocator) {
    options:=(^uasset.Options)(data)
    if options==nil {return}
    reads_free(options.reads,allocator)
    free(options,allocator)
}

// The translators and the reads the plugins of the library of info give.
@(private)
map_prepare :: proc(assets:^asset.Registry,info:^core.World_Info,allocator:mem.Allocator) -> rawptr {
    found:[editor.PROVIDER_CAPACITY]unreal_scene.Translator_Provider
    translators:=make([dynamic]unreal_scene.Translator,allocator)
    if info!=nil {
        for &provider in found[:editor.provided_in(info,found[:])] {
            append(&translators,..provider.translators[:clamp(provider.count,0,len(provider.translators))])
        }
    }
    state:=new(Map_State,allocator)
    state^={translators=translators[:],reads=reads_gather(info,allocator)}
    return state
}

@(private)
map_bring :: proc(source,folder:string,allocator:mem.Allocator) -> (brought:string,error:importer.Error) {
    return unreal_scene.level_bring(source,folder,allocator=allocator)
}

@(private)
map_run :: proc(state:rawptr,source:string,options:importer.Import_Options,allocator:mem.Allocator) -> (report:importer.Import_Report,scene:string,error:importer.Error) {
    state:=(^Map_State)(state)
    level,level_error:=unreal_scene.level_import(source,options,state.translators,reads=state.reads,allocator=allocator)
    if level_error.code!=.None {return {},"",level_error}
    report=level.imports
    level.imports={}
    scene=strings.clone(level.scene_path,allocator)
    unreal_scene.level_report_destroy(&level)
    return
}

@(private)
map_release :: proc(state:rawptr,allocator:mem.Allocator) {
    state:=(^Map_State)(state)
    delete(state.translators,allocator)
    reads_free(state.reads,allocator)
    free(state,allocator)
}
