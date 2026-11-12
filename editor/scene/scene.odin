package unreal_scene

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:asset"
import importer "mirai:cook/import"
import uasset "project:plugins/unreal/editor/model"
import "project:plugins/unreal/editor/kraken"
import "project:plugins/unreal/editor/level"
import material "project:plugins/unreal/editor/material"
import material_write "project:plugins/unreal/editor/material/write"
import unreal "project:plugins/unreal/editor/package"
import "mirai:core"
import render "mirai:engine/render"
import escene "mirai:engine/scene"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// An uncooked Unreal map (.umap) as a scene of a project: each actor that
// shows something is an entity with its label, and what its components show
// are entities under it with their place relative to it: meshes with the
// materials their slots override, lights in Mirai's units, cameras, and of
// the sky and the post process volumes what has a physical equivalent. Each
// StaticMesh the level names is imported once, as mirai import imports its
// package, all of them through one library of packages. The actors of the
// classes a plugin translates go to its Translator; the rest of what has no
// translation is a warning by class with its count.
//
// A map of World Partition is a scene for each cell of its runtime grids
// (level.partition_read) that holds something, referenced by the scene of
// the map as a Spatial section: what loads with the map, and what a plugin
// streams by itself, stays in the scene of the map.
//
// Importing the map again writes the scene to its file with its id, and each
// entity keeps its id: it is the hash of the path of its actor (and its
// component) in the map, which Unreal keeps while labels change.

LEVEL_VERSION :: 2 // of what the same map gives

TRANSLATOR_CLASSES :: 4
PROVIDER_TRANSLATORS :: 4
PROVIDER_READS :: 4

// What a plugin translates, through the procedures of Context, a scene at a
// time (c.section):
// - with translate, the actors of the scene whose native class is one of
//   classes (by name, of any /Script package: Landscape,
//   InstancedFoliageActor), all at once; it returns how many it translated
//   and warns of the others. root takes them all into the scene of the map,
//   whatever their cell: what it writes streams by itself (a terrain by its
//   pages). instanced also calls it with the instanced static mesh
//   components the actors of the scene show (c.instanced), after them;
// - with component, what it adds to each entity the scene made of a
//   component of one of classes (StaticMeshComponent): the component k of
//   actor a, and e, its entity. A component of a class the scene does not
//   translate (NiagaraComponent of a Blueprint) is an entity for it.
Translator :: struct {
    classes:[TRANSLATOR_CLASSES]string,
    translate:proc(c:^Context,actors:[]int) -> int,
    component:proc(c:^Context,a,k:int,e:base.Entity_Id),
    root:bool,
    instanced:bool,
}

// The components whose instances are batches of foliage of the translator
// that takes them, never an entity each.
INSTANCED_COMPONENTS :: []string{"InstancedStaticMeshComponent","HierarchicalInstancedStaticMeshComponent","FoliageInstancedStaticMeshComponent"}

// An instanced component the actors of a scene show: component k of actor a.
Instanced :: struct {actor,component:int}

// A scene the map writes: that of the map, or the section of a cell of its
// partition, which the scene of the map references where the box of the
// cell is. What a section holds is where it is from the center of that box.
Section :: struct {
    cell:int,          // of c.partition; -1 for the scene of the map
    name:string,       // of the cell: its scene is <name>.scene in the folder of the import
    origin:[3]f32,     // where its reference is in the world
    extents:[3]f32,    // half the box of the cell
    scene:asset.Scene,
    id:base.Asset_Id,
    path:string,
    open:bool,
    orders:map[base.Entity_Id]int, // the order of the next child of each parent
}

// The editor package of a plugin gives its translators with an Editor
// storage whose sole field is a Translator_Provider, filled by its default,
// and the textures its systems write as they run that materials read
// (material.Options.reads): for every import of Unreal content.
Translator_Provider :: struct {
    translators:[PROVIDER_TRANSLATORS]Translator,
    count:int,
    reads:[PROVIDER_READS]material.Texture_Read,
    read_count:int,
}

Class_Count :: struct {
    class:string,     // the class of the actors, as Unreal names it
    actors:int,
    translated:int,   // those translated: entities, or what the scene takes of them
}

Light_Note :: struct {
    name:string,     // the label of its actor
    kind:Light_Kind,
    units:string,    // of Unreal's intensity
    intensity:f32,
    value:f32,       // in Mirai
    unit:string,
    approximated:bit_set[Light_Approximation],
}

Camera_Note :: struct {
    name:string,
    entity:base.Entity_Id, // what mirai capture --camera-entity takes

    fov:f32,     // vertical, degrees
    cine:bool,
    focal:f32,   // mm, of a cine camera
    sensor:[2]f32,
}

Level_Report :: struct {
    imports:importer.Import_Report, // what was written, the meshes and materials included; the warnings
    scene:base.Asset_Id,
    scene_path:string,
    entities:int,
    classes:[dynamic]Class_Count,
    lights:[dynamic]Light_Note,
    cameras:[dynamic]Camera_Note,
    meshes:int,  // StaticMesh packages imported
    sections:int, // scenes of cells the scene of the map references
    seconds:f64,
    allocator:mem.Allocator,
}

level_report_destroy :: proc(report:^Level_Report) {
    importer.report_destroy(&report.imports)
    delete(report.scene_path,report.allocator)
    for c in report.classes {delete(c.class,report.allocator)}
    for l in report.lights {delete(l.name,report.allocator)}
    for c in report.cameras {delete(c.name,report.allocator)}
    delete(report.classes);delete(report.lights);delete(report.cameras)
    report^={}
}

Note :: enum u8 {IES,Light_Function,No_Shadows,Falloff,Source_Length,Cone_Clamped}

Sun_Candidate :: struct {entity:base.Entity_Id,section:int,brightness:f32}

// A StaticMesh imported for the level: its .mesh and, by row of its slots,
// the id of each slot (Unreal's index plus one) and its own material.
Mesh_Import :: struct {
    id:base.Asset_Id,
    slot_ids:[]u32,
    slot_materials:[]base.Asset_Id,
    ok:bool,
}

Clip_Import :: struct {
    id:base.Asset_Id,  // the .anim; zero when it could not be imported
    root_locked:bool,  // bForceRootLock of its AnimSequence
    rate:f64,          // its RateScale, which the times of the clip have in them
}

// What a translation reads and writes. Its memory lives until the import ends.
Context :: struct {
    d:^level.Document,           // the level and the packages of its archetypes
    lib:^material.Library,       // the packages of meshes, materials and textures, shared by the whole level
    images:material_write.Builder, // the textures decoded for the materials of the level, while the memory is over MEMORY_FLOOR
    scene:^asset.Scene,          // that of c.section
    partition:level.Partition,
    sections:[]Section,          // the scene of the map, then one for each cell of the partition
    section:int,                 // the one being written
    actor_sections:[]int,        // by actor
    instanced:[dynamic]Instanced, // of the actors of the section, for the translator that takes them
    instanced_hidden:int,        // instanced components hidden in game, left out
    takes_instanced:bool,        // a translator takes the instanced components
    tallies:map[string]int,      // what translators say of each scene, counted (tally)
    types:^asset.Types,
    options:importer.Import_Options, // root is the project
    report:^Level_Report,
    assets,shaders:string,       // the assets and shaders folders of the project
    source:string,               // the file of the map
    outputs:importer.Outputs,
    formats:[1]importer.Format,
    format_options:uasset.Options,
    translators:[]Translator,
    texture_reads:[dynamic]material.Texture_Read, // those of the plugins, then those translators add (texture_read_add)
    meshes:map[string]Mesh_Import,     // by object path
    bodies:map[string]Mesh_Body,       // by object path
    clips:map[string]Clip_Import,      // by object path
    materials:map[string]base.Asset_Id, // by object path; a variant (instanced_material) by its name
    slot_paths:map[string][]string,     // the materials of the slots of each mesh, by Unreal's index
    custom_reads:map[string]bool,       // whether a material reads PerInstanceCustomData, by object path
    prefixes:map[string]string,         // the folder of the parts of each package the level writes, by file ("" for the map)
    variant_uses:[dynamic]Variant_Use,  // the slots whose material is written at the end of the level
    held:[dynamic]Held_Slot,            // of the component being translated: its slots that name a material the level keeps
    texts:map[u64]base.Asset_Id,        // the .ui of each text, by its text, size, color and alignment
    layers:map[string]Layered_Entry,    // by object path
    actor_entities:[]base.Entity_Id,
    actor_flat:[]bool, // the actor shows one component: its entity is that of the component, without a group
    suns:[dynamic]Sun_Candidate,
    sky:render.Sky,           // of the entity of the sky, when the level has a sky light
    sky_lit:bool,             // by a sky light of the level
    sky_turn:f32,             // of the image of the sky about up, radians
    sky_drawn:bool,           // the level draws a sky behind the scene: an atmosphere or the engine's sky sphere
    sky_atmosphere:bool,      // by an atmosphere (SkyAtmosphere, or AtmosphericFog of UE4)
    notes:[Note]int,
    left:map[string]int, // components that were not translated, by class
    reads:Reads,                // the packages of meshes read ahead (reads.odin)
    library_lock:sync.Mutex,    // held while lib and images are used
    decoder:kraken.Decoder,     // of the translators, made when first asked for
    decoder_ready:bool,
    extended_luminance:bool, // the auto exposure of the project is in EV100 (ExtendDefaultLuminanceRange)
    luminance_max:f64,       // the luminance of its EV100 0
    failed:bool,
    error:importer.Error,
}

// The materials of a landscape material: one for each of its layers, in the
// order of names, or one when it has none.
Layered :: struct {ids:[]base.Asset_Id,names:[]string,ok:bool,whole:base.Asset_Id}

// A landscape material translated whole for the terrain of a landscape.
Landscape_Whole :: struct {label:string,mapping:material.Landscape_Mapping}

// The materials written of a landscape material, and the wholes in its import.
Layered_Entry :: struct {layered:Layered,wholes:[dynamic]Landscape_Whole,done:bool}

// Imports the map at path, a source in the assets of the project at
// options.root, as one import that owns everything it writes: the scene, and
// as its parts the meshes, materials, textures and clips of the packages it
// reads (each under the folder of its package) and what plugins write, in
// the folder of the import (<map>/ beside it, or what its sidecar says).
// The packages it reads are its inputs (level_packages). translators are those
// of the plugins of the project; without them, their actors are warnings that
// say how to import them. reads are the textures the plugins' systems write
// as they run (Translator_Provider).
level_import :: proc(path:string,options:importer.Import_Options,translators:[]Translator={},engine_content:="",reads:[]material.Texture_Read={},allocator:=context.allocator) -> (report:Level_Report,error:importer.Error) {
    caller:=context.temp_allocator
    started:=time.tick_now()
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&arena)
    context.temp_allocator=base.dynamic_arena_allocator(&arena)
    scratch:=context.temp_allocator
    if importer.unsafe_path(path) || !os.exists(path) {return {},importer.error_make(.Not_Found,"%s does not exist",path,allocator=caller)}
    open_zone:=importer.zone_begin(options,"level.open")
    bytes,read_error:=serial.file_read(path,scratch,limit=i64(unreal.DEFAULT_LIMITS.source_bytes))
    if read_error!=.None {return {},importer.error_make(.Read,"%s could not be read: %v",path,read_error,allocator=caller)}
    p,open_error:=unreal.package_open(bytes,scratch,unreal.DEFAULT_LIMITS)
    if open_error.code!=.None {return {},importer.error_make(.Unsupported,"%s: %v at 0x%x: %s",path,open_error.code,open_error.offset,open_error.field,allocator=caller)}
    absolute,_:=filepath.abs(path,scratch)
    mounts:=uasset.mounts_find(absolute,{engine_content=engine_content},&p,scratch)
    name,name_error:=unreal.source_package_name(absolute,mounts,scratch)
    if name_error.code!=.None {return {},importer.error_make(.Unsupported,"%s is under no Content folder of a project and does not name its package where it is: %s",path,name_error.field,allocator=caller)}
    p.source_package=name
    lib:level.Library
    level.library_init(&lib,mounts,scratch)
    defer level.library_destroy(&lib)
    map_index,_:=level.library_add(&lib,name,&p)
    d:level.Document
    if document_error:=level.document_open(&d,&lib,map_index,scratch);document_error.code!=.None {
        return {},importer.error_make(.Unsupported,"%s: %v at 0x%x: %s",path,document_error.code,document_error.offset,document_error.field,allocator=caller)
    }
    defer level.document_destroy(&d)
    inputs,inputs_error:=level_packages(absolute,mounts,scratch)
    if inputs_error.code!=.None {return {},importer.error_make(inputs_error.code,"%s",inputs_error.message,allocator=caller)}
    base.profile_end(open_zone)
    context.temp_allocator=caller
    report,error=document_import(&d,path,u64(len(bytes)),base.hash64(bytes),options,translators,reads,inputs,allocator)
    if error.code==.None {report.seconds=time.duration_seconds(time.tick_since(started))}
    return
}

// The scene of a level read already, as level_import writes it: source is
// the map it names, of size and hash, whose packages d reads through the
// mounts of its library; inputs, the files of those packages.
document_import :: proc(d:^level.Document,source:string,size,hash:u64,options:importer.Import_Options,translators:[]Translator={},reads:[]material.Texture_Read={},inputs:[]string={},allocator:=context.allocator) -> (report:Level_Report,error:importer.Error) {
    caller:=context.temp_allocator
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&arena)
    context.temp_allocator=base.dynamic_arena_allocator(&arena)
    scratch:=context.temp_allocator
    report.allocator=allocator
    report.classes.allocator,report.lights.allocator,report.cameras.allocator=allocator,allocator,allocator
    fail :: proc(caller:mem.Allocator,code:importer.Error_Code,format:string,args:..any) -> importer.Error {
        return importer.error_make(code,format,..args,allocator=caller)
    }
    root:=options.root
    if root=="" || !os.exists(project.path(root,project.PROJECT_FILE,allocator=scratch)) {
        return {},fail(caller,.Not_Found,"a level is imported into a project: give the folder with %s (--project in mirai import)",project.PROJECT_FILE)
    }
    mounts:=d.library.mounts
    materials:material.Library
    material.library_init(&materials,mounts,allocator)
    defer material.library_destroy(&materials)

    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    c:=Context{d=d,lib=&materials,types=&types,options=options,report=&report}
    c.meshes.allocator,c.materials.allocator,c.layers.allocator,c.left.allocator=scratch,scratch,scratch,scratch
    c.clips.allocator,c.bodies.allocator,c.slot_paths.allocator,c.custom_reads.allocator=scratch,scratch,scratch,scratch
    c.prefixes.allocator=scratch
    c.variant_uses.allocator,c.texts.allocator,c.held.allocator=scratch,scratch,scratch
    c.translators=translators
    c.texture_reads.allocator=scratch
    append(&c.texture_reads,..reads)
    c.suns.allocator=scratch
    c.sky=render.SKY_DEFAULT
    c.assets=project.folder_path(root,.Assets,scratch)
    stem:=filepath.stem(source)
    c.source=source
    c.shaders=project.folder_path(root,.Shaders,scratch)
    engine:=""
    for mount in mounts {if mount.package_prefix=="/Engine" {engine=mount.directory}}
    material_write.builder_init(&c.images,c.lib,c.report.allocator,&c.library_lock,MEMORY_FLOOR)
    defer material_write.builder_destroy(&c.images)
    defer if c.decoder_ready {kraken.decoder_destroy(&c.decoder)}
    c.format_options={engine_content=engine,library=&materials,images=&c.images,lock=&c.library_lock,reads=reads}

    c.formats[0]=uasset.format(&c.format_options)
    // The packages the level imports find their documents in one scan of the assets.
    registry:asset.Registry
    if options.registry==nil {
        asset.registry_init(&registry,c.assets,"",scratch,project.imported_path(root,scratch))
        asset.registry_scan(&registry)
        c.options.registry=&registry
    }
    defer if options.registry==nil {asset.registry_destroy(&registry)}
    c.extended_luminance,c.luminance_max=luminance_range(mounts,level.library_package(d.library,int(d.levels[0].ref.pkg)))

    outputs_zone:=importer.zone_begin(options,"level.outputs")
    if begin_error:=importer.outputs_begin(&c.outputs,source,asset.safe_name(stem),size,hash,importer.import_version(LEVEL_VERSION),c.options,allocator);begin_error.code!=.None {
        return {},fail(caller,begin_error.code,"%s",begin_error.message)
    }
    for file in inputs {importer.output_input(&c.outputs,file)}
    scene_id,scene_path,root_error:=importer.output_root(&c.outputs,asset.KIND_SCENE,stem,".scene")
    if root_error.code!=.None {
        message:=fail(caller,root_error.code,"%s",root_error.message)
        importer.outputs_end(&c.outputs,true)
        return {},message
    }
    base.profile_end(outputs_zone)
    partition_zone:=importer.zone_begin(options,"level.partition")
    partition,partition_error:=level.partition_read(d,scratch)
    base.profile_end(partition_zone)
    switch {
    case partition_error.code==.Unsupported_Value && partition.hash!="":
        importer.output_warn(&c.outputs,"%s: its %s is not read (only the WorldPartitionRuntimeHashSet of UE 5.4 on); everything loads with its scene",source,partition.hash)
        partition={}
    case partition_error.code!=.None:
        importer.output_warn(&c.outputs,"%s: its World Partition could not be read (%v at 0x%x: %s); everything loads with its scene",source,partition_error.code,partition_error.offset,partition_error.field)
        partition={}
    }
    c.partition=partition
    if n:=len(d.superseded);n>0 {
        importer.output_warn(&c.outputs,"%d external actor packages are left out: another package holds the same actor (%s), which Unreal loads from one package; delete the stale ones in Unreal",n,d.superseded[0].actor)
    }
    c.sections=make([]Section,1+len(partition.cells),scratch)
    c.sections[0]={cell=-1,id=scene_id,path=scene_path,open=true,orders=make(map[base.Entity_Id]int,scratch)}
    if asset.scene_init(&c.sections[0].scene,&types,scene_id,scratch)!=.None {
        importer.outputs_end(&c.outputs,true)
        return {},fail(caller,.Write,"no memory for the scene of %s",source)
    }
    for cell,i in partition.cells {
        c.sections[i+1]={cell=i,name=cell.name,origin=mm.aabb_center(cell.box),extents=mm.aabb_half(cell.box)}
    }
    defer for &s in c.sections {if s.open {asset.scene_destroy(&s.scene)}}
    c.scene=&c.sections[0].scene
    scene:=c.scene
    c.actor_entities=make([]base.Entity_Id,len(d.actors),scratch)
    c.actor_flat=make([]bool,len(d.actors),scratch)
    c.actor_sections=make([]int,len(d.actors),scratch)
    c.instanced.allocator=scratch
    c.tallies=make(map[string]int,scratch)

    translate_zone:=importer.zone_begin(options,"level.translate")
    level_translate(&c,translators)
    reads_end(&c)
    base.profile_end(translate_zone)
    variants_zone:=importer.zone_begin(options,"level.variants")
    if !c.failed {variants_finish(&c)}
    base.profile_end(variants_zone)
    section_use(&c,0)
    environment_zone:=importer.zone_begin(options,"level.environment")
    environment_finish(&c)
    if !c.failed {blueprints_prefab(&c)}
    base.profile_end(environment_zone)
    sections_zone:=importer.zone_begin(options,"level.sections")
    if !c.failed {sections_finish(&c)}
    base.profile_end(sections_zone)

    scene_zone:=importer.zone_begin(options,"level.scene_write")
    if !c.failed {
        section_use(&c,0)
        info:=importer.output_info(&c.outputs,stem,0)
        existed:=os.exists(scene_path)
        os.make_directory_all(filepath.dir(scene_path))
        if asset.import_put(&scene.doc,&types,&info)!=.None {
            c.failed,c.error=true,{.Write,fmt.tprintf("the scene of %s could not be built",source)}
        } else if save_error:=asset.scene_save(scene,scene_path);save_error!=.None {
            c.failed,c.error=true,{.Write,fmt.tprintf("%s could not be written: %v",scene_path,save_error)}
        } else {
            report.entities+=asset.scene_entity_count(scene)
            importer.output_written(&c.outputs,scene_id,asset.KIND_SCENE,stem,scene_path,existed,fmt.tprintf("%d entities",asset.scene_entity_count(scene)))
        }
    }
    base.profile_end(scene_zone)
    if c.failed {
        message:=fail(caller,c.error.code,"%s",c.error.message)
        importer.outputs_end(&c.outputs,true)
        level_report_destroy(&report)
        return {},message
    }
    end_zone:=importer.zone_begin(options,"level.end")
    notes_warn(&c)
    report.imports=importer.outputs_end(&c.outputs,false)
    warnings_unique(&report.imports)
    base.profile_end(end_zone)

    report.scene=scene_id
    report.scene_path=strings.clone(scene_path,allocator)
    return report,{}
}

// Each actor to its translator, or translated here, a scene at a time, and
// what was not, by class.
@(private)
level_translate :: proc(c:^Context,translators:[]Translator) {
    d:=c.d
    natives:=make([]level.Class,len(d.actors),context.temp_allocator)
    for &n,i in natives {n=level.actor_native_class(d,i)}
    owners:=make([]int,len(d.actors),context.temp_allocator) // the translator that takes each actor, or -1
    for &o in owners {o=-1}
    for translator,t in translators {
        if translator.translate==nil {continue}
        for n,i in natives {
            if owners[i]>=0 {continue}
            for class in translator.classes {
                if class!="" && n.name==class {owners[i]=t;break}
            }
        }
    }
    members:=make([][dynamic]int,len(c.sections),context.temp_allocator)
    for &m in members {m.allocator=context.temp_allocator}
    for a in 0..<len(d.actors) {
        cell:=len(c.partition.actor_cells)>0?c.partition.actor_cells[a]:-1
        if owners[a]>=0 && translators[owners[a]].root {cell=-1}
        c.actor_sections[a]=cell+1
        append(&members[cell+1],a)
    }
    c.takes_instanced=false
    for translator in translators {c.takes_instanced||=translator.translate!=nil && translator.instanced}
    reads_zone:=importer.zone_begin(c.options,"level.reads")
    reads_begin(c,natives,owners,members)
    base.profile_end(reads_zone)
    rows:=make(map[string]int,context.temp_allocator)
    row_of :: proc(c:^Context,rows:^map[string]int,class:level.Class) -> ^Class_Count {
        key:=fmt.tprintf("%s.%s",class.pkg,class.name)
        if at,ok:=rows[key];ok {return &c.report.classes[at]}
        rows[key]=len(c.report.classes)
        append(&c.report.classes,Class_Count{class=strings.clone(key,c.report.allocator)})
        return &c.report.classes[len(c.report.classes)-1]
    }
    untranslated:=make(map[string]int,context.temp_allocator)
    for section,s in members {
        if len(section)==0 {continue}
        section_use(c,s)
        if c.failed {return}
        clear(&c.instanced)
        actors_zone:=importer.zone_begin(c.options,"level.actors")
        for a in section {
            if owners[a]>=0 {continue}
            row_of(c,&rows,d.actors[a].class).actors+=1
            translated,silent:=actor_translate(c,a,natives[a])
            if c.failed {base.profile_end(actors_zone);return}
            if translated {row_of(c,&rows,d.actors[a].class).translated+=1} else if !silent {
                reason:=untranslated_reason(c,a,natives[a],len(translators)>0)
                untranslated[fmt.tprintf("%s|%s",d.actors[a].class.name,reason)]+=1
            }
        }
        base.profile_end(actors_zone)
        for translator,t in translators {
            if translator.translate==nil {continue}
            actors:=make([dynamic]int,context.temp_allocator)
            for a in section {if owners[a]==t {append(&actors,a)}}
            if len(actors)==0 && !(translator.instanced && len(c.instanced)>0) {continue}
            translated:=translator.translate(c,actors[:])
            if c.failed {return}
            if len(actors)==0 {continue}
            // The count goes to the class of the first actor; a translator takes classes of one kind.
            for a in actors {row_of(c,&rows,d.actors[a].class).actors+=1}
            row_of(c,&rows,d.actors[actors[0]].class).translated+=translated
        }
    }
    if c.instanced_hidden>0 {warn(c,"%d instanced static mesh components hidden in game are left out",c.instanced_hidden)}
    keys:=make([dynamic]string,context.temp_allocator)
    for key in untranslated {append(&keys,key)}
    slice.sort(keys[:])
    for key in keys {
        bar:=strings.index_byte(key,'|')
        n:=untranslated[key]
        importer.output_warn(&c.outputs,"%d %s %s not translated: %s",n,key[:bar],n==1?"actor was":"actors were",key[bar+1:])
    }
    left:=make([dynamic]string,context.temp_allocator)
    for class in c.left {append(&left,class)}
    slice.sort(left[:])
    for class in left {
        n:=c.left[class]
        importer.output_warn(&c.outputs,"%d %s %s of translated actors %s left out: Mirai has no translation for it",n,class,n==1?"component":"components",n==1?"was":"were")
    }
    said:=make([dynamic]string,context.temp_allocator)
    for what in c.tallies {append(&said,what)}
    slice.sort(said[:])
    for what in said {importer.output_warn(&c.outputs,"%d %s",c.tallies[what],what)}
}

// Actors that hold nothing a game shows, what the editor of Unreal alone
// uses, or what Mirai makes otherwise: the HLOD of World Partition (Mirai's
// is made by cell), the minimap, lightmass and the volumes of runtime virtual
// textures, whose landscape layers the terrain translates.
@(private)
SILENT_ACTORS :: []string{
    "WorldSettings","LevelScriptActor","GroupActor","SphereReflectionCapture","BoxReflectionCapture","PlaneReflectionCapture",
    "LightmassImportanceVolume","LightmassCharacterIndirectDetailVolume","PrecomputedVisibilityVolume","NavMeshBoundsVolume",
    "RecastNavMesh","AbstractNavData","NavigationData","LandscapeGizmoActiveActor","WorldDataLayers","WorldPartitionMiniMap",
    "DefaultPhysicsVolume","Note","LevelBounds","DocumentationActor","LevelInstanceEditorInstanceActor",
    "WorldPartitionHLOD","WorldPartitionMiniMapVolume","GPULightmassSettingsActor","RuntimeVirtualTextureVolume","LocationVolume",
    "PCGWorldActor",
}

// Components that are an entity of their own.
@(private)
ENTITY_COMPONENTS :: []string{
    "StaticMeshComponent","SkeletalMeshComponent","PointLightComponent","SpotLightComponent","RectLightComponent",
    "DirectionalLightComponent","CameraComponent","CineCameraComponent","TextRenderComponent",
}

// Components that show nothing in a game, that the editor of Unreal alone
// draws, or what another component of their actor shows: the graph of PCG
// and the level of a packed level actor (their instances), the Nanite and
// proxy meshes of a landscape (its terrain), the materials of slots.
@(private)
SILENT_COMPONENTS :: []string{
    "SceneComponent","ArrowComponent","BillboardComponent","DrawSphereComponent","DrawFrustumComponent","BrushComponent","Model",
    "CubeBuilder","CylinderBuilder","ConeBuilder","CurvedStairBuilder","LinearStairBuilder","SpiralStairBuilder","TetrahedronBuilder",
    "SheetBuilder","VolumetricBuilder","TimelineComponent","NavigationSystemModuleConfig","SphereReflectionCaptureComponent",
    "BoxReflectionCaptureComponent","PlaneReflectionCaptureComponent","InputComponent","LandscapeGizmoRenderComponent",
    "SplineComponent","MaterialBillboardComponent","TextRenderComponent_Editor","PostProcessComponent","LineBatchComponent",
    "ActorTextureStreamingBuildDataComponent","LandscapeNaniteComponent","LandscapeMeshProxyComponent","RuntimeVirtualTextureComponent",
    "PCGComponent","LevelInstanceComponent","MaterialInstanceDynamic","WorldPartitionHLODSourceActorsFromCell",
}

// The classes plugins of Mirai translate in an editor session.
@(private)
PLUGIN_CLASSES :: []string{"Landscape","LandscapeProxy","LandscapeStreamingProxy","InstancedFoliageActor","BlockingVolume","ExponentialHeightFog"}

@(private)
untranslated_reason :: proc(c:^Context,a:int,native:level.Class,with_translators:bool) -> string {
    if slice.contains(PLUGIN_CLASSES,native.name) {
        if with_translators {return "the plugin that translates it is not in the project"}
        return "a plugin translates it in an editor session: import the level there (mirai session start, then mirai rpc asset.import with its path)"
    }
    switch native.name {
    case "AmbientSound":return "Mirai imports no sounds of Unreal"
    case "Emitter":return "a Cascade particle system"
    case "Brush":return "BSP geometry"
    case "PlayerStart":return "a spawn point: place a Spawn_Point (plugin spawn)"
    case "DecalActor":return "a decal"
    case "TextRenderActor":return "text"
    case "VolumetricCloud":return "Mirai draws no volumetric clouds"
    }
    if a>=0 && !c.takes_instanced && instanced_count(c,a)>0 {
        if with_translators {return "its instances are batches of foliage, and the foliage plugin is not in the project"}
        return "its instances are batches of foliage that the foliage plugin makes in an editor session: import the level there (mirai session start, then mirai rpc asset.import with its path)"
    }
    if a>=0 && !strings.has_prefix(c.d.actors[a].class.pkg,"/Script/") {return "Blueprint logic, or a Blueprint that shows nothing Mirai translates"}
    return "it shows nothing Mirai translates"
}

// The entities of an actor and what its components show. translated: it
// became an entity; silent: there was nothing to tell of it.
@(private)
actor_translate :: proc(c:^Context,a:int,native:level.Class) -> (translated,silent:bool) {
    d:=c.d
    actor:=d.actors[a]
    if actor_silent(c,a,native) {return false,true}
    if actor.class.pkg=="/Engine/EngineSky/BP_Sky_Sphere" {
        importer.output_warn(&c.outputs,"%s: the sky sphere of Unreal's engine is not drawn: the Sky of the scene is Mirai's sky",actor.label)
        c.sky_drawn=true
        return false,true
    }
    switch native.name {
    case "PostProcessVolume":
        post_process_add(c,a)
        return true,false
    case "SkyAtmosphere","AtmosphericFog":
        // The Sky of the scene draws the air the sun lights.
        c.sky_drawn,c.sky_atmosphere=true,true
        if native.name=="SkyAtmosphere" && actor.root>=0 {c.sky.air=atmosphere_air(d,d.components[actor.root].ref)}
        return true,false
    }
    components:=d.components[actor.first_component:][:actor.component_count]
    editor_only:=make([]bool,len(components),context.temp_allocator)
    shown:=0
    for component,i in components {
        editor_only[i],_=level.bool_of(d,component.ref,"bIsEditorOnly",false)
        if !editor_only[i] && (slice.contains(ENTITY_COMPONENTS,component.class.name) || component_claimed(c,component.class.name)) {shown+=1}
    }
    c.actor_flat[a]=shown==1
    count:=0
    left:=make([dynamic]string,context.temp_allocator)
    for component,i in components {
        if editor_only[i] {continue}
        k:=actor.first_component+i
        ok:=false
        switch component.class.name {
        case "StaticMeshComponent":ok=mesh_add(c,a,k,false)
        case "TextRenderComponent":ok=text_add(c,a,k)
        case "InstancedStaticMeshComponent","HierarchicalInstancedStaticMeshComponent","FoliageInstancedStaticMeshComponent":ok=instanced_take(c,a,k)
        case "SkeletalMeshComponent":ok=mesh_add(c,a,k,true)
        case "PointLightComponent":ok=light_add(c,a,k,.Point)
        case "SpotLightComponent":ok=light_add(c,a,k,.Spot)
        case "RectLightComponent":ok=light_add(c,a,k,.Rect)
        case "DirectionalLightComponent":ok=light_add(c,a,k,.Directional)
        case "CameraComponent":ok=camera_add(c,a,k,false)
        case "CineCameraComponent":ok=camera_add(c,a,k,true)
        case "SkyLightComponent":ok=sky_light_add(c,a,k)
        case:
            if !component_claimed(c,component.class.name) {
                if !slice.contains(SILENT_COMPONENTS,component.class.name) {append(&left,component.class.name)}
                continue
            }
            e,made:=component_entity(c,a,k)
            if made {component_translate(c,a,k,e)}
            ok=made
        }
        if c.failed {return}
        if ok {count+=1}
    }
    if count==0 {return false,false}
    for class in left {c.left[class]+=1}
    if hidden,_:=level.bool_of(d,actor.ref,"bHidden",false);hidden {
        if e,ok:=actor_entity(c,a);ok {hidden_set(c,e)}
    }
    return true,false
}

// Whether a translator adds what a component of class shows to its entity.
@(private)
component_claimed :: proc(c:^Context,class:string) -> bool {
    for t in c.translators {
        if t.component==nil {continue}
        for name in t.classes {if name!="" && name==class {return true}}
    }
    return false
}

// A texture a system a translator places writes as it runs, which the
// materials the level keeps read instead (variants_finish).
texture_read_add :: proc(c:^Context,read:material.Texture_Read) {
    a:=c.texture_reads.allocator
    append(&c.texture_reads,material.Texture_Read{strings.clone(read.texture,a),strings.clone(read.include,a),strings.clone(read.function,a),strings.clone(read.name,a)})
}

// The path of an actor in the map, which Unreal keeps while its label
// changes: what the id of its entity is made from. An actor of World
// Partition is that of its own package too: two packages can hold actors of
// the same name.
actor_key :: proc(c:^Context,a:int) -> string {
    actor:=c.d.actors[a]
    ref:=actor.ref
    path,error:=level.object_path(c.d,ref,ref.object,context.temp_allocator)
    if error.code!=.None {return fmt.tprintf("%s#%d",actor.label,a)}
    if actor.external {return fmt.tprintf("%s|%s",c.d.library.packages[int(ref.pkg)].name,path)}
    return path
}

// An entity of the scene of c.section under parent (0 for none), with the
// id that key gives: the same in every import of the map. One at the root
// of a section is where transform puts it from the origin of the section.
entity_make :: proc(c:^Context,parent:base.Entity_Id,key,name:string,transform:mm.Transform) -> (e:base.Entity_Id,ok:bool) {
    e=base.Entity_Id(base.name_hash(key))
    if e==0 || e in c.scene.index {
        importer.output_warn(&c.outputs,"%s: two objects of the map give the same entity id; this one gets a new one",key)
        e=asset.scene_new_id(c.scene)
    }
    label:core.Name
    base.text_set(label.text[:],name)
    section:=&c.sections[c.section]
    if _,error:=asset.scene_entity_add(c.scene,e,parent,base.text_get(label.text[:]),section.orders[parent]);error!=.None {return 0,fail_write(c,"the entity %s",name)}
    section.orders[parent]+=1
    t:=core.Transform(transform)
    if parent==0 {t.position-=section.origin}
    if asset.scene_set(c.scene,e,"Transform",&t)!=.None {return 0,fail_write(c,"the transform of %s",name)}
    return e,true
}

// Makes section s the one written, its scene made the first time. The one
// written before.
section_use :: proc(c:^Context,s:int) -> (previous:int) {
    previous=c.section
    section:=&c.sections[s]
    if !section.open {
        section.orders=make(map[base.Entity_Id]int,context.temp_allocator)
        if asset.scene_init(&section.scene,c.types,{},context.temp_allocator)!=.None {
            fail_write(c,"the scene of the section %s",section.name)
            return
        }
        section.open=true
    }
    c.section=s
    c.scene=&section.scene
    return
}

// Where the scene of the section being written is in the world, and its
// name; "" for the scene of the map.
section_origin :: proc(c:^Context) -> (origin:[3]f32,name:string) {
    section:=c.sections[c.section]
    return section.origin,section.name
}

// The scenes of the cells that hold something, written with their import,
// and in the scene of the map an entity that references each where the box
// of its cell is: a Spatial section, which the plugin streaming loads by
// where the players are. The scene of a cell is a part of the import of the
// map: those written take the files and ids of the earlier
// import by the names of their cells, before any takes one by index.
@(private)
sections_finish :: proc(c:^Context) {
    written:=make([dynamic]int,context.temp_allocator)
    names:=make([dynamic]string,context.temp_allocator)
    for &section,s in c.sections {
        if s==0 || !section.open || asset.scene_entity_count(&section.scene)==0 {continue}
        append(&written,s)
        append(&names,section.name)
    }
    ids,paths:=importer.output_parts(&c.outputs,asset.KIND_SCENE,names[:],0,".scene")
    for s,i in written {
        section:=&c.sections[s]
        section.id,section.path=ids[i],paths[i]
        section.scene.doc.id=section.id
        info:=importer.output_info(&c.outputs,section.name,0)
        existed:=os.exists(section.path)
        os.make_directory_all(filepath.dir(section.path))
        if asset.import_put(&section.scene.doc,c.types,&info)!=.None {fail_write(c,"the import of the section %s",section.name);return}
        if error:=asset.scene_save(&section.scene,section.path);error!=.None {
            c.failed,c.error=true,{.Write,fmt.tprintf("%s could not be written: %v",section.path,error)}
            return
        }
        entities:=asset.scene_entity_count(&section.scene)
        c.report.entities+=entities
        importer.output_written(&c.outputs,section.id,asset.KIND_SCENE,section.name,section.path,existed,fmt.tprintf("%d entities",entities))
        section_use(c,0)
        e,made:=entity_make(c,0,fmt.tprintf("section|%s",section.name),section.name,{section.origin,1,{1,1,1}})
        if !made {return}
        reference:=escene.Scene_Reference{scene=section.id,extents=section.extents,rule=.Spatial}
        if !component_set(c,e,"Scene_Reference",&reference) {return}
        c.report.sections+=1
    }
    if c.report.sections==0 {return}
    for g in c.partition.grids {
        if g.kind!=.Grid {continue}
        warn(c,"the cells of %s load within %.0f m in Unreal: Spatial sections load within the load and active distances of the Streaming_Settings of the project (plugin streaming)",g.name,g.loading_range/100)
    }
}

// The instanced components of an actor that show something.
@(private)
instanced_count :: proc(c:^Context,a:int) -> (count:int) {
    actor:=c.d.actors[a]
    for k in actor.first_component..<actor.first_component+actor.component_count {
        if slice.contains(INSTANCED_COMPONENTS,c.d.components[k].class.name) {count+=1}
    }
    return
}

// An instanced static mesh component to the translator that takes them: its
// instances are batches of foliage of the scene of its actor, never an entity
// each. One hidden in game is left out.
@(private)
instanced_take :: proc(c:^Context,a,k:int) -> bool {
    if !c.takes_instanced {return false}
    if !instanced_shown(c,a,k) {c.instanced_hidden+=1;return false}
    append(&c.instanced,Instanced{a,k})
    return true
}

// Whether instanced component k of actor a shows in game.
@(private)
instanced_shown :: proc(c:^Context,a,k:int) -> bool {
    ref:=c.d.components[k].ref
    visible,_:=level.bool_of(c.d,ref,"bVisible",true)
    hidden,_:=level.bool_of(c.d,ref,"bHiddenInGame",false)
    actor_hidden,_:=level.bool_of(c.d,c.d.actors[a].ref,"bHidden",false)
    return visible && !hidden && !actor_hidden
}

// Whether actor_translate leaves actor a out without a word: what shows
// nothing a game shows (SILENT_ACTORS) and what only the editor of Unreal has.
@(private)
actor_silent :: proc(c:^Context,a:int,native:level.Class) -> bool {
    if slice.contains(SILENT_ACTORS,native.name) {return true}
    editor_only,_:=level.bool_of(c.d,c.d.actors[a].ref,"bIsEditorOnlyActor",false)
    return editor_only
}

// The entity of an actor: its label, where its root component is, in the
// scene of its section. Made the first time.
actor_entity :: proc(c:^Context,a:int) -> (e:base.Entity_Id,ok:bool) {
    if c.actor_entities[a]!=0 {return c.actor_entities[a],true}
    previous:=section_use(c,c.actor_sections[a])
    defer section_use(c,previous)
    world,_,error:=level.actor_world(c.d,a)
    if error.code!=.None {
        importer.output_warn(&c.outputs,"%s: its place could not be read (%v: %s); it stands at the origin",c.d.actors[a].label,error.code,error.field)
        world=mm.TRANSFORM_IDENTITY
    }
    e=entity_make(c,0,actor_key(c,a),c.d.actors[a].label,world) or_return
    c.actor_entities[a]=e
    return e,true
}

// The entity of what a component shows, under that of its actor: where the
// component is, turned by turn and, when scale is not zero, with that scale
// in the world instead of the component's. name "" is the component's name.
// The only component an actor shows is the entity of the actor, with its label.
component_entity :: proc(c:^Context,a,k:int,turn:=mm.Quat(1),scale:=[3]f32{},name:="") -> (e:base.Entity_Id,ok:bool) {
    previous:=section_use(c,c.actor_sections[a])
    defer section_use(c,previous)
    world,error:=level.component_world(c.d,k)
    if error.code!=.None {
        importer.output_warn(&c.outputs,"%s: the place of %s could not be read (%v: %s); it is left out",c.d.actors[a].label,c.d.components[k].name,error.code,error.field)
        return 0,false
    }
    world.rotation=world.rotation*turn
    if scale!={} {world.scale=scale}
    flat:=c.actor_flat[a] && c.actor_entities[a]==0
    if flat {
        e=entity_make(c,0,actor_key(c,a),name!=""?name:c.d.actors[a].label,world) or_return
        c.actor_entities[a]=e
    } else {
        e=component_child(c,a,k,world,name) or_return
    }
    ref:=c.d.components[k].ref
    visible,_:=level.bool_of(c.d,ref,"bVisible",true)
    hidden,_:=level.bool_of(c.d,ref,"bHiddenInGame",false)
    if !visible || hidden {hidden_set(c,e)}
    return e,true
}

// The entity of a component under that of its actor, where world places it.
@(private)
component_child :: proc(c:^Context,a,k:int,world:mm.Transform,name:string) -> (e:base.Entity_Id,ok:bool) {
    parent:=actor_entity(c,a) or_return
    actor_world,_,_:=level.actor_world(c.d,a)
    if c.d.actors[a].root<0 {actor_world=mm.TRANSFORM_IDENTITY}
    local,relative:=mm.transform_relative(world,actor_world)
    if !relative {
        importer.output_warn(&c.outputs,"%s: its scale has an axis of zero; %s is left out",c.d.actors[a].label,c.d.components[k].name)
        return 0,false
    }
    key:=fmt.tprintf("%s|%s",actor_key(c,a),c.d.components[k].name)
    return entity_make(c,parent,key,name!=""?name:c.d.components[k].name,local)
}

component_set :: proc(c:^Context,e:base.Entity_Id,name:string,value:^$T) -> bool {
    if asset.scene_set(c.scene,e,name,value)!=.None {return fail_write(c,"the component %s",name)}
    return true
}

// A component of an entity that the world loads turned off.
component_off :: proc(c:^Context,e:base.Entity_Id,name:string) {
    asset.scene_component_turn(c.scene,e,base.name_hash(name),true)
}

hidden_set :: proc(c:^Context,e:base.Entity_Id) {
    hidden:=render.Hidden{}
    component_set(c,e,"Hidden",&hidden)
}

warn :: proc(c:^Context,format:string,args:..any) {importer.output_warn(&c.outputs,format,..args)}

// A zone of the import until the end of the enclosing block, as translators
// time their parts; name lives as long as the import.
@(deferred_out=base.profile_end)
zone :: #force_inline proc "contextless" (c:^Context,name:string) -> base.Profile_Scope {return importer.zone_begin(c.options,name)}

// A zone of the import that zone_end ends.
zone_begin :: #force_inline proc "contextless" (c:^Context,name:string) -> base.Profile_Scope {return importer.zone_begin(c.options,name)}
zone_end :: base.profile_end

// Counts n of what a translator says of every scene it is called for: the
// level warns once, "<count> <what>", when it ends.
tally :: proc(c:^Context,what:string,n:int) {
    if n<=0 {return}
    if !(what in c.tallies) {c.tallies[strings.clone(what,context.temp_allocator)]=0}
    c.tallies[what]+=n
}

// A decoder of Oodle for the translators.
decoder :: proc(c:^Context) -> (^kraken.Decoder,bool) {
    if !c.decoder_ready {
        made,error:=kraken.decoder_make(c.report.allocator)
        if error!=nil {return nil,false}
        c.decoder=made
        c.decoder_ready=true
    }
    return &c.decoder,true
}

// Takes lib and images for the translation, from the jobs that read ahead.
@(private)
library_lock :: proc(c:^Context) {
    lock_zone:=importer.zone_begin(c.options,"level.lock")
    sync.mutex_lock(&c.library_lock)
    base.profile_end(lock_zone)
    c.lib.worker=c.options.worker
}

@(private)
library_unlock :: proc(c:^Context) {sync.mutex_unlock(&c.library_lock)}

@(private)
fail_write :: proc(c:^Context,format:string,args:..any) -> bool {
    if !c.failed {c.failed,c.error=true,{.Write,fmt.tprintf("%s could not be written into the scene",fmt.tprintf(format,..args))}}
    return false
}

@(private)
clone :: proc(c:^Context,text:string) -> string {return strings.clone(text,c.report.allocator)}

// The id, file and Import_Info of an asset of the level other than its
// scene (a .terrain, a .foliage): those an earlier import of the map gave it
// under that name, else new ones in the folder of its import.
asset_place :: proc(c:^Context,kind:asset.Fourcc,name:string,index:int,extension:string) -> (id:base.Asset_Id,path:string,info:asset.Import_Info) {
    id,path=importer.output_part(&c.outputs,kind,name,index,extension)
    info=importer.output_info(&c.outputs,name,index)
    return
}

// Writes an asset asset_place placed; the report lists it.
asset_write :: proc(c:^Context,id:base.Asset_Id,kind:asset.Fourcc,name,path:string,bytes:[]u8,detail:="") -> bool {
    existed:=os.exists(path)
    os.make_directory_all(filepath.dir(path))
    if serial.file_write_atomic(path,bytes)!=.None {
        warn(c,"%s could not be written",path)
        return false
    }
    importer.output_written(&c.outputs,id,kind,name,path,existed,detail)
    return true
}

@(private)
notes_warn :: proc(c:^Context) {
    if n:=c.notes[.Falloff];n>0 {warn(c,"%d lights without inverse squared falloff: their candelas give what they gave where they reach half their radius",n)}
    if n:=c.notes[.Source_Length];n>0 {warn(c,"%d lights have a source length: Mirai draws a tube from the scale of its entity, which they keep at one",n)}
    if n:=c.notes[.IES];n>0 {warn(c,"%d lights have an IES profile, which Mirai does not read",n)}
    if n:=c.notes[.Light_Function];n>0 {warn(c,"%d lights have a light function, which Mirai does not read",n)}
    if n:=c.notes[.No_Shadows];n>0 {warn(c,"%d lights cast no shadows in Unreal; Mirai's cast them",n)}
    if n:=c.notes[.Cone_Clamped];n>0 {warn(c,"%d spot lights have a cone outside 1° to 89°: they were given the nearest",n)}
}

// The imports of the meshes and materials of a level say the same of a
// material each time: once is enough.
@(private)
warnings_unique :: proc(report:^importer.Import_Report) {
    seen:=make(map[string]bool,context.temp_allocator)
    kept:=0
    for w in report.warnings {
        if seen[w] {delete(w,report.allocator);continue}
        seen[w]=true
        report.warnings[kept]=w
        kept+=1
    }
    resize(&report.warnings,kept)
}


// Called between imports: when the memory left, less bytes, is under
// MEMORY_FLOOR, the images of the level are let go, after the jobs that decode them, which
// hold pointers into them; the next materials decode their textures again.
@(private)
images_trim :: proc(c:^Context,bytes:=0) {
    if !memory_short(bytes) {return}
    library_lock(c)
    defer library_unlock(c)
    if material_write.builder_bytes(&c.images)==0 {return}
    importer.zone(c.options,"level.images_trim")
    material_write.builder_settle(&c.images)
    material_write.builder_trim(&c.images)
}
