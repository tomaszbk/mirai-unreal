package unreal_scene

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import uasset "project:plugins/unreal/editor/model"
import material "project:plugins/unreal/editor/material"
import material_write "project:plugins/unreal/editor/material/write"
import unreal_mesh "project:plugins/unreal/editor/mesh"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import render "mirai:engine/render"
import "mirai:project"
import "mirai:std/base"

// The meshes and materials a level names, each imported once as the import
// of its own package: the same assets mirai import gives that package, kept
// where an earlier import of it put them.

// The mesh of a StaticMeshComponent or SkeletalMeshComponent, with the
// materials its slots override: OverrideMaterials by Unreal's index, which is
// the id of the slot less one. One for a slot the mesh does not draw is
// nothing, as in Unreal. A skeletal mesh is drawn at its bind pose by the
// entity of its component, as the prefab of its import draws it.
@(private)
mesh_add :: proc(c:^Context,a,k:int,skeletal:bool) -> bool {
    clear(&c.held)
    shown:=mesh_renderer(c,a,k,skeletal) or_return
    e:=component_entity(c,a,k) or_return
    if !component_set(c,e,"Mesh_Renderer",&shown) {return false}
    for h in c.held {append(&c.variant_uses,Variant_Use{e,c.section,h.row,h.path})}
    if skeletal {animation_play(c,a,k,e)}
    component_translate(c,a,k,e)
    return true
}

// What the plugins add to the entity of a component: the translators with a
// component hook for its class.
@(private)
component_translate :: proc(c:^Context,a,k:int,e:base.Entity_Id) {
    class:=c.d.components[k].class.name
    for t in c.translators {
        if t.component==nil {continue}
        for name in t.classes {
            if name!="" && name==class {t.component(c,a,k,e);break}
        }
    }
}

// A slot whose material is written at the end of the level: one the level
// keeps inside an actor.
Variant_Use :: struct {
    entity:base.Entity_Id,
    section:int,
    row:int,
    path:string,
}

// A slot of a mesh component that names a material the level keeps.
Held_Slot :: struct {
    row:int,
    path:string,
}

// The materials of the slots written at the end of the level, by the package
// that holds them: each package one import, which keeps an earlier material
// where it was and gives each other one a file of its own. A material the
// level keeps inside an actor is named after the objects that hold it. The
// slots take them.
@(private)
variants_finish :: proc(c:^Context) {
    by_file:=make(map[string][dynamic]int,context.temp_allocator)
    files:=make([dynamic]string,context.temp_allocator)
    for use,i in c.variant_uses {
        package_name,_:=object_split(use.path)
        file:=package_file(c,package_name)
        // The grid that stands for a material of the engine goes with what the level keeps.
        if file=="" && engine_missing(c,use.path) {file=c.source}
        if file=="" {continue}
        if !(file in by_file) {by_file[file]=make([dynamic]int,context.temp_allocator);append(&files,file)}
        append(&by_file[file],i)
    }
    previous:=c.section
    defer section_use(c,previous)
    for file in files {
        uses:=by_file[file][:]
        translated:=make([dynamic]material.Translated_Material,context.temp_allocator)
        defer for &t in translated {material.translated_destroy(&t)}
        rows:=make(map[string]int,context.temp_allocator) // row of translated; -1: none
        use_rows:=make([]int,len(uses),context.temp_allocator)
        for u,i in uses {
            use:=c.variant_uses[u]
            if row,seen:=rows[use.path];seen {use_rows[i]=row;continue}
            rows[use.path]=-1
            use_rows[i]=-1
            t,translated_ok:=translation_or_grid(c,use.path)
            if !translated_ok {continue}
            if held_name(use.path)!="" {t.name=held_name(use.path)}
            rows[use.path]=len(translated)
            use_rows[i]=len(translated)
            append(&translated,t)
        }
        if len(translated)==0 {continue}
        // Those the level keeps go with its other assets: maps keep ones of the same name.
        ids,written:=materials_write(c,file,translated[:])
        if !written {continue}
        for u,i in uses {
            if use_rows[i]<0 {continue}
            use:=c.variant_uses[u]
            section_use(c,use.section)
            shown,has:=asset.scene_get(c.scene,use.entity,"Mesh_Renderer",render.Mesh_Renderer)
            if !has {continue}
            shown.materials[use.row]=ids[use_rows[i]]
            component_set(c,use.entity,"Mesh_Renderer",&shown)
        }
    }
}

// A material the level keeps inside an actor is named after the objects that
// hold it; "" for one of a package.
@(private)
held_name :: proc(path:string) -> string {
    colon:=strings.index_byte(path,':')
    if colon<0 {return ""}
    name,_:=strings.replace_all(strings.trim_prefix(path[colon+1:],"PersistentLevel."),".","_",context.temp_allocator)
    return name
}

// The object path of the material of each slot (by row of the slots of the
// mesh) that an instanced component draws: the one it overrides, or the mesh's.
slot_material_paths :: proc(c:^Context,k:int) -> []string {
    d:=c.d
    ref:=d.components[k].ref
    mesh_path:=level.path_of(d,ref,"StaticMesh")
    m,_:=mesh_import(c,mesh_path)
    own,seen:=c.slot_paths[mesh_path]
    if !seen {
        library_lock(c)
        if object,found:=material.object_find(c.lib,mesh_path);found {
            if list,list_error:=material.object_properties(object);list_error.code==.None && list!=nil {
                own,_=unreal_mesh.static_material_paths(&object.pkg.p,list,context.temp_allocator)
            }
        }
        library_unlock(c)
        c.slot_paths[strings.clone(mesh_path,context.temp_allocator)]=own
    }
    overrides:=level.paths_of(d,ref,"OverrideMaterials")
    paths:=make([]string,min(len(m.slot_ids),render.MATERIAL_SLOTS),context.temp_allocator)
    for &path,row in paths {
        index:=int(m.slot_ids[row])-1
        if index>=0 && index<len(overrides) && overrides[index]!="" {path=overrides[index]} else if index>=0 && index<len(own) {path=own[index]}
    }
    return paths
}

// The material a slot of instances shows when its entity-less instances
// cannot take it at the end of the level, written now: one the level keeps
// inside an actor, and the variant of a material that reads the custom
// data of the instances (custom, their PerInstanceSMCustomData) for those
// values. ok is false for any other: the slot shows what mesh_renderer gave it.
instanced_material :: proc(c:^Context,path:string,custom:[]f32) -> (id:base.Asset_Id,ok:bool) {
    if path=="" {return}
    custom:=custom
    if len(custom)>0 && !custom_reads(c,path) {custom=nil}
    name:=held_name(path)
    held:=name!="" || engine_missing(c,path)
    if !held && len(custom)==0 {return}
    hash:=base.name_hash(path)
    for value in custom {hash=base.hash_combine(hash,u64(transmute(u32)value))}
    key:=fmt.tprintf("%s|%x",path,hash)
    if found,seen:=c.materials[key];seen {return found,found!={}}
    defer c.materials[key]=id
    package_name,_:=object_split(path)
    file:=package_file(c,package_name)
    if file=="" && engine_missing(c,path) {file=c.source}
    if file=="" {return}
    t:=translation_or_grid(c,path,custom) or_return
    defer material.translated_destroy(&t)
    if name!="" {t.name=name}
    if len(custom)>0 {t.name=fmt.tprintf("%s_%08x",t.name,u32(hash))}
    ids:=materials_write(c,file,{t}) or_return
    return ids[0],true
}

// Whether the material at path reads PerInstanceCustomData: then each set of
// custom data of the instances shows another variant of it.
@(private)
custom_reads :: proc(c:^Context,path:string) -> bool {
    if reads,seen:=c.custom_reads[path];seen {return reads}
    reads:=false
    defer c.custom_reads[strings.clone(path,context.temp_allocator)]=reads
    if engine_missing(c,path) {return false}
    t:=translation_or_grid(c,path) or_return
    defer material.translated_destroy(&t)
    reads=t.reads_custom_data
    return reads
}

// What the entity of a mesh component draws: its mesh, imported once, and the
// materials its slots override. A material the level keeps inside an actor
// is written at its end: the slots that name one are in c.held.
mesh_renderer :: proc(c:^Context,a,k:int,skeletal:bool) -> (shown:render.Mesh_Renderer,ok:bool) {
    d:=c.d
    ref:=d.components[k].ref
    path:string
    if skeletal {
        // SkeletalMesh, deprecated, wins over SkinnedAsset, as in Unreal.
        path=level.path_of(d,ref,"SkeletalMesh")
        if path=="" {path=level.path_of(d,ref,"SkinnedAsset")}
    } else {
        path=level.path_of(d,ref,"StaticMesh")
    }
    if path=="" {return}
    m:Mesh_Import
    if shape,substitute:=engine_shape(c,path);substitute && !skeletal {
        tally(c,fmt.tprintf("components show %s of Unreal's engine, which is not mounted (no Unreal installation): the %v of Mirai stands for it",path,shape),1)
        shown.shape=shape
        m.slot_ids=[]u32{1}
    } else {
        imported_mesh:bool
        m,imported_mesh=mesh_import(c,path)
        if !imported_mesh {return}
        shown.mesh=m.id
    }
    overridden:[render.MATERIAL_SLOTS]bool
    for override,index in level.paths_of(d,ref,"OverrideMaterials") {
        if override=="" {continue}
        row,found:=slice.linear_search(m.slot_ids,u32(index+1))
        if !found {continue}

        if row>=render.MATERIAL_SLOTS {
            warn(c,"%s: %s overrides the material of slot %d, past the %d a Mesh_Renderer holds",d.actors[a].label,d.components[k].name,index,render.MATERIAL_SLOTS)
            continue
        }
        // One the level keeps inside an actor, and the grid that stands for one of the engine
        // that is not mounted, are written with the others of the level, at its end.
        if strings.index_byte(override,':')>=0 || engine_missing(c,override) {
            append(&c.held,Held_Slot{row,override})
            overridden[row]=true
            continue
        }
        id,imported:=material_import(c,override)
        if !imported || row<len(m.slot_materials) && id==m.slot_materials[row] {continue}
        shown.materials[row]=id
        overridden[row]=true
    }
    if shown.shape!=.None && !overridden[0] {append(&c.held,Held_Slot{0,BASIC_SHAPE_MATERIAL})}
    return shown,true
}

// What a SkeletalMeshComponent plays: in AnimationSingleNode, the clip of
// the AnimSequence of its AnimationData (AnimToPlay of saves before it),
// looping and playing as it says and at its rate, as the Animation of the
// entity of the component, and where it starts as its Animation_Progress. The single node instance takes no root motion
// out of a sequence, so a sequence that forces its root lock stays in place.
// An Animation Blueprint is logic: a warning, and the bind pose.
@(private)
animation_play :: proc(c:^Context,a,k:int,e:base.Entity_Id) {
    d:=c.d
    ref:=d.components[k].ref
    label:=fmt.tprintf("%s: %s",d.actors[a].label,d.components[k].name)
    mode,_:=level.enum_of(d,ref,"AnimationMode","AnimationBlueprint")
    switch mode {
    case "AnimationSingleNode":
    case "AnimationBlueprint":
        if class:=level.path_of(d,ref,"AnimClass");class!="" {warn(c,"%s plays the Animation Blueprint %s, which is logic of Unreal: it stands at its bind pose",label,class)}
        return
    case:
        warn(c,"%s animates in the mode %s, which Mirai does not translate: it stands at its bind pose",label,mode)
        return
    }
    chain:=struct_chain(d,ref,"AnimationData")
    path:=""
    if item,p:=chain_find(&chain,"AnimToPlay");item!=nil {
        if v,error:=unreal.property_value(p,item);error.code==.None && v.kind==.Object && v.object!=0 {path,_=unreal.reference_path(p,v.object,context.temp_allocator)}
    }
    if path=="" {path=level.path_of(d,ref,"AnimToPlay")}
    if path=="" {return}
    // SingleAnimationPlayData's defaults: looping and playing, at the start, at rate one.
    looping,playing:=true,true
    if item,_:=chain_find(&chain,"bSavedLooping");item!=nil {looping=chain_bool(&chain,"bSavedLooping")}
    if item,_:=chain_find(&chain,"bSavedPlaying");item!=nil {playing=chain_bool(&chain,"bSavedPlaying")}
    rate,_:=chain_real(&chain,"SavedPlayRate",1)
    position,_:=chain_real(&chain,"SavedPosition",0)
    clip,ok:=clip_import(c,path)
    if !ok {return}
    animation:=Animation{asset=clip.id,speed=f32(rate),loop=looping,playing=playing,weight=1,fade=ANIMATION_FADE}
    animation.preview,_=level.bool_of(d,ref,"bUpdateAnimationInEditor",false)
    if clip.root_locked {animation.root_motion=.In_Place}
    if !component_set(c,e,"Animation",&animation) {return}
    // Where the clip starts: the times of the clip have its RateScale in them.
    if position!=0 {
        progress:=Animation_Progress{time=f32(position/clip.rate)}
        component_set(c,e,"Animation_Progress",&progress)
    }
}

@(private)
Animation_Progress :: struct {time:f32}

// The fields of the Animation of the animation plugin that a level sets, by
// their names; the others keep their defaults.
@(private)
Animation :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    speed:f32,
    loop,playing,preview:bool,
    weight,fade:f32,
    root_motion:Root_Motion_Policy,
}
@(private)
Root_Motion_Policy :: enum u8 {None,Extract,In_Place}
// ANIMATION_DEFAULT.fade of the animation plugin.
@(private="file")
ANIMATION_FADE :: 0.2

// The .anim of an AnimSequence by its object path, the import of its
// package; whether it forces its root lock. One that cannot be imported is a
// warning, once.
@(private)
clip_import :: proc(c:^Context,path:string) -> (clip:Clip_Import,ok:bool) {
    if found,seen:=c.clips[path];seen {return found,found.id!={}}
    defer c.clips[strings.clone(path,context.temp_allocator)]=clip
    package_name,_:=object_split(path)
    file:=package_file(c,package_name)
    if file=="" {
        warn(c,"the animation %s is not under a mount of the level; what plays it stands at its bind pose",path)
        return
    }
    model,error:=importer.import_model(file,c.formats[:],c.options,context.temp_allocator)
    defer importer.model_destroy(&model)
    report:importer.Import_Report
    if error.code==.None {report,error=model_parts_write(c,&model,file)}
    if error.code!=.None {
        warn(c,"the animation %s could not be imported: %s; what plays it stands at its bind pose",path,error.message)
        return
    }
    if report.animation_id=={} {
        warn(c,"%s has no AnimSequence; what plays it stands at its bind pose",path)
        return
    }
    clip.id=report.animation_id
    clip.rate=1
    library_lock(c)
    defer library_unlock(c)
    if object,found:=material.object_find(c.lib,path);found {
        if list,list_error:=material.object_properties(object);list_error.code==.None {
            if item:=unreal.property_find(&object.pkg.p,list,"bForceRootLock");item!=nil {
                v,_:=unreal.property_value(&object.pkg.p,item)
                clip.root_locked=v.kind==.Boolean && v.boolean
            }
            if item:=unreal.property_find(&object.pkg.p,list,"RateScale");item!=nil {
                if v,_:=unreal.property_value(&object.pkg.p,item);v.kind==.Real && v.real>0 {clip.rate=v.real}
            }
        }
    }
    return clip,true
}

// The .mesh of a StaticMesh or SkeletalMesh by its object path: the import of its package,
// through the library of the level. A mesh that cannot be imported is a
// warning, once.
mesh_import :: proc(c:^Context,path:string) -> (m:Mesh_Import,ok:bool) {
    if found,seen:=c.meshes[path];seen {return found,found.ok}
    key:=strings.clone(path,context.temp_allocator)
    defer c.meshes[key]=m
    package_name,object:=object_split(path)
    file:=package_file(c,package_name)
    if file=="" {
        warn(c,"the mesh %s is not under a mount of the level; what shows it is left out",path)
        return
    }
    model,error:=reads_take(c,file)
    defer importer.model_destroy(&model)
    defer images_trim(c)
    row:=-1
    for mesh,i in model.meshes {
        if mesh.name==unreal.asset_name(object) {row=i;break}
    }
    if row<0 && len(model.meshes)==1 {row=0}
    report:importer.Import_Report
    if error.code==.None {
        import_zone:=importer.zone_begin(c.options,"level.mesh_import")
        report,error=model_parts_write(c,&model,file)
        base.profile_end(import_zone)
    }
    if error.code!=.None {
        warn(c,"the mesh %s could not be imported: %s",path,error.message)
        return
    }
    c.report.meshes+=1
    if row<0 || row>=len(report.mesh_ids) {
        warn(c,"%s has no mesh named %s",file,object)
        return
    }
    m.id=report.mesh_ids[row]
    slots:=model.meshes[row].slots
    m.slot_ids=make([]u32,len(slots),context.temp_allocator)
    m.slot_materials=make([]base.Asset_Id,len(slots),context.temp_allocator)
    for slot,i in slots {
        m.slot_ids[i]=slot.id
        if slot.material>=0 && slot.material<len(report.material_ids) {m.slot_materials[i]=report.material_ids[slot.material]}
    }
    m.ok=true
    return m,true
}

// The .mat of a material or material instance by its object path: its
// translation, written as an import of its package into materials/.
material_import :: proc(c:^Context,path:string) -> (id:base.Asset_Id,ok:bool) {
    if found,seen:=c.materials[path];seen {return found,found!={}}
    defer c.materials[strings.clone(path,context.temp_allocator)]=id
    library_lock(c)
    _,found:=material.object_find(c.lib,path)
    library_unlock(c)
    package_name,_:=object_split(path)
    file:=package_file(c,package_name)
    if !found || file=="" {
        warn(c,"the material %s is not under a mount of the level; its slot keeps the material of its mesh",path)
        return
    }
    translate_zone:=importer.zone_begin(c.options,"material.translate")
    t,translated:=translation_or_grid(c,path)
    base.profile_end(translate_zone)
    if !translated {return}
    defer material.translated_destroy(&t)
    ids:=materials_write(c,file,{t}) or_return
    return ids[0],true
}

// The materials of a landscape material by its object path: one for each
// of its layers, or one for a material without layers (that blends with its
// own splat maps). With a mapping, also the material whole as the program
// that blends the layers of the terrain of the landscape label
// (layered.whole; zero, with a warning, when it is not a program). They are
// one import of its package into materials/: the wholes of the landscapes
// seen before stay in it.
layer_materials :: proc(c:^Context,path:string,label:="",mapping:^material.Landscape_Mapping=nil) -> (layered:Layered) {
    entry:=c.layers[path]
    if entry.done && mapping==nil {return entry.layered}
    defer {
        entry.done=true
        if entry.wholes.allocator.procedure==nil {entry.wholes.allocator=context.temp_allocator}
        c.layers[strings.clone(path,context.temp_allocator)]=entry
    }
    library_lock(c)
    locked:=true
    defer if locked {library_unlock(c)}
    object,found:=material.object_find(c.lib,path)
    package_name,_:=object_split(path)
    file:=package_file(c,package_name)
    if !found || file=="" {
        warn(c,"the landscape material %s is not under a mount of the level",path)
        return
    }
    layers,error:=material.landscape_layers(c.lib,object,{},context.temp_allocator)
    if error.code!=.None {
        warn(c,"the landscape material %s could not be translated (%s)",path,error.message)
        return
    }
    defer material.landscape_layers_destroy(layers,context.temp_allocator)
    if len(layers)==0 {
        t,whole_error:=material.translate(c.lib,object,{reads=c.texture_reads[:]},context.temp_allocator)
        if whole_error.code!=.None {
            warn(c,"the landscape material %s could not be translated (%s)",path,whole_error.message)
            return
        }
        defer material.translated_destroy(&t)
        library_unlock(c)
        locked=false
        ids,ok:=materials_write(c,file,{t})
        if !ok {return}
        layered.ids,layered.ok=slice.clone(ids,context.temp_allocator),true
        entry.layered=layered
        return
    }
    if mapping!=nil {
        kept:=mapping^
        for &name in kept.layers {name=strings.clone(name,context.temp_allocator)}
        if entry.wholes.allocator.procedure==nil {entry.wholes.allocator=context.temp_allocator}
        append(&entry.wholes,Landscape_Whole{label=strings.clone(label,context.temp_allocator),mapping=kept})
    }
    translated:=make([dynamic]material.Translated_Material,context.temp_allocator)
    layered.names=make([]string,len(layers),context.temp_allocator)
    for layer,i in layers {
        append(&translated,layer.material)
        layered.names[i]=strings.clone(layer.name,context.temp_allocator)
    }
    // Each whole after the layers, those that give a program.
    programs:=make([]int,len(entry.wholes),context.temp_allocator)
    for &whole,i in entry.wholes {
        programs[i]=-1
        t,whole_error:=material.translate(c.lib,object,{landscape=&whole.mapping,reads=c.texture_reads[:]},context.temp_allocator)
        if whole_error.code!=.None {
            if i==len(entry.wholes)-1 {warn(c,"%s: its landscape material %s could not be translated whole (%s); its layers blend their own materials",whole.label,path,whole_error.message)}
            continue
        }
        if material.translated_is_standard(&t) {
            why:=len(t.notes)>0?t.notes[len(t.notes)-1]:"no program"
            if i==len(entry.wholes)-1 {warn(c,"%s: its landscape material %s gives no program (%s); its layers blend their own materials",whole.label,path,why)}
            material.translated_destroy(&t)
            continue
        }
        t.name=strings.concatenate({t.name,"_",whole.label},t.allocator)
        programs[i]=len(translated)
        append(&translated,t)
    }
    defer for &t in translated[len(layers):] {material.translated_destroy(&t)}
    library_unlock(c)
    locked=false
    ids,ok:=materials_write(c,file,translated[:])
    if !ok {return}
    layered.ids,layered.ok=slice.clone(ids[:len(layers)],context.temp_allocator),true
    if mapping!=nil && programs[len(programs)-1]>=0 {layered.whole=ids[programs[len(programs)-1]]}
    entry.layered=layered
    entry.layered.whole={}
    return
}


@(private)
materials_write :: proc(c:^Context,file:string,translated:[]material.Translated_Material) -> (ids:[]base.Asset_Id,ok:bool) {
    write_zone:=importer.zone_begin(c.options,"level.materials")
    textures,_:=decoder(c)
    report,error:=material_write.materials_write(c.lib,translated,&c.outputs,package_prefix(c,file),c.shaders,c.options,context.temp_allocator,&c.images,&c.library_lock,textures)
    base.profile_end(write_zone)
    defer images_trim(c)
    if error.code!=.None {
        warn(c,"the materials of %s could not be written: %s",file,error.message)
        return
    }
    ids=report.material_ids[:]
    return ids,len(ids)==len(translated)
}

// The folder of the parts of the package in file among those of the level:
// its name without the prefix of its type, apart from another package of
// the same name; "" for the map, whose own parts are at the root of its import.
package_prefix :: proc(c:^Context,file:string) -> string {
    if file==c.source {return ""}
    if prefix,seen:=c.prefixes[file];seen {return prefix}
    name:=uasset.model_folder(file)
    prefix:=fmt.tprintf("%s/",name)
    for at:=2;;at+=1 {
        taken:=false
        for _,other in c.prefixes {taken||=other==prefix}
        if !taken {break}
        prefix=fmt.tprintf("%s (%d)/",name,at)
    }
    c.prefixes[strings.clone(file,context.temp_allocator)]=prefix
    return prefix
}

// Writes the model of the package in file as parts of the level: its
// meshes, materials, textures, skeletons and clips under the folder of the
// package. The scene places the meshes itself: the package gives no prefab.
// The report gives their ids by row, in the temp allocator.
model_parts_write :: proc(c:^Context,model:^importer.Imported_Model,file:string) -> (report:importer.Import_Report,error:importer.Error) {
    material_write.names_prefix(model,package_prefix(c,file),context.temp_allocator)
    model.nodes=nil
    return importer.output_model(&c.outputs,model,context.temp_allocator)
}

// The file of a package under the mounts of the level, a map's too; "" when
// none holds it.
@(private)
package_file :: proc(c:^Context,package_name:string) -> string {
    for extension in ([2]string{".uasset",".umap"}) {
        file,error:=unreal.source_package_path(package_name,c.lib.mounts,context.temp_allocator,extension)
        if error.code==.None && os.exists(file) {return file}
    }
    return ""
}

// "/Game/M/SM_Rock.SM_Rock": its package and its object, the last part of the package without one.
object_split :: proc(path:string) -> (package_name,object:string) {
    package_name=path
    if dot:=strings.index_byte(path,'.');dot>=0 {package_name,object=path[:dot],path[dot+1:]}
    if colon:=strings.index_byte(object,':');colon>=0 {object=object[:colon]}
    if object=="" {object=package_name[strings.last_index_byte(package_name,'/')+1:]}
    return
}

