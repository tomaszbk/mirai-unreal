package unreal_scene

import "base:intrinsics"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import importer "mirai:cook/import"
import "project:plugins/unreal/editor/kraken"
import "project:plugins/unreal/editor/level"
import material "project:plugins/unreal/editor/material"
import material_write "project:plugins/unreal/editor/material/write"
import "mirai:std/base"
import "mirai:std/jobs"

// The packages of the meshes a level names are read and built ahead, each a
// job of the job system of the import, while the level is translated in the
// order it always is: what is written, and the ids it takes, are decided
// there, one package after the other, and are the same as when nothing is
// read ahead. So are the materials of other packages its components
// override (Read.materials): a job translates them and builds their images
// into the builder of the level, where the translation finds their textures
// decoded; it writes them when it gets to them.
//
// Reading ahead leaves MEMORY_FLOOR of the memory of the machine free, as
// the system counts it when a read would start, less what the reads that run
// are reckoned to take still (READ_COST bytes for each byte of a package).
// No more run than workers. A package that does not start is read by the
// translation when it gets to it, once the models before it were written and
// let go; under the floor, after the images of the level are let go and the
// reads that run end. The import goes slower, it does not fail. A package asked for
// before its turn is read then. The reads started before the one asked for, which the translation
// passed by, stop holding a worker: they would keep the next ones from
// starting.
//
// The translation waits for a package without running other jobs: one that
// took a long read would keep it from the package it waits for.
//
// The jobs share the packages of materials and textures of the level (c.lib)
// and its images (c.images) with the translation: whoever uses them holds
// c.library_lock, and never while it waits for a job.

// The share of the memory of the machine a level import leaves free: reading
// ahead waits for it, and the images of the level are let go (images_trim).
MEMORY_FLOOR :: 0.15
READ_COST :: 34 // a 69 MB StaticMesh of Nanite (Jungle_HollowTree1) reads and builds within 2.3 GB

// Passed: started, and the translation asked for a later package first.
@(private)
Read_State :: enum u8 {Waiting,Started,Passed,Taken}

// A package read ahead: its model, or why it could not be read. With
// materials, the materials of other packages built ahead instead.
@(private)
Read :: struct {
    file:string,
    materials:[dynamic]string, // object paths
    c:^Context,                // whose lib and images the materials are built into, holding its library_lock
    index:int,                 // in Reads.order
    cost:int,
    state:Read_State,
    running:bool,              // atomic: started and not done
    formats:[]importer.Format,
    options:importer.Import_Options,
    done:sync.Sema,
    model:importer.Imported_Model,
    error:importer.Error, // its message in the memory of the job system
}

@(private)
Reads :: struct {
    by_file:map[string]^Read,
    order:[dynamic]^Read, // as the translation is expected to ask for them
    next:int,             // the first of order not started
    passed:int,           // those of order before it were passed by the translation (reads_pass)
    started:int,          // started and neither taken nor passed: those that hold a worker
    materials:map[string]bool, // object paths read ahead
}

// The packages of the meshes the components of the level show, in the order
// the translation takes them: of each scene, the meshes of the actors it
// translates, then the instanced components the translators take. natives
// is the native class of each actor, owners its translator or -1. Reading
// starts.
@(private)
reads_begin :: proc(c:^Context,natives:[]level.Class,owners:[]int,sections:[][dynamic]int) {
    r:=&c.reads
    r.by_file.allocator=context.temp_allocator
    r.order.allocator=context.temp_allocator
    r.materials.allocator=context.temp_allocator
    if c.options.worker.system==nil {return}
    d:=c.d
    add :: proc(c:^Context,path:string) {
        if path=="" {return}
        package_name,_:=object_split(path)
        file:=package_file(c,package_name)
        if file=="" || file in c.reads.by_file {return}
        info,error:=os.stat(file,context.temp_allocator)
        if error!=nil {return}
        read:=new(Read,context.temp_allocator)
        read^={file=strings.clone(file,context.temp_allocator),index=len(c.reads.order),cost=int(info.size)*READ_COST,formats=c.formats[:],options=c.options}
        c.reads.by_file[read.file]=read
        append(&c.reads.order,read)
    }
    // The materials of other packages a component overrides, as mesh_renderer
    // imports them, after its mesh: one read for those of the component.
    overrides :: proc(c:^Context,ref:level.Ref) {
        read:^Read
        for path in level.paths_of(c.d,ref,"OverrideMaterials") {
            if path=="" || strings.index_byte(path,':')>=0 || path in c.reads.materials {continue}
            c.reads.materials[strings.clone(path,context.temp_allocator)]=true
            if read==nil {
                read=new(Read,context.temp_allocator)
                read^={c=c,index=len(c.reads.order),options=c.options}
                read.materials.allocator=context.temp_allocator
                append(&c.reads.order,read)
            }
            append(&read.materials,strings.clone(path,context.temp_allocator))
        }
    }
    for members in sections {
        for instanced_pass in ([2]bool{false,true}) {
            if instanced_pass && !c.takes_instanced {break}
            for a in members {
                if !instanced_pass && owners[a]>=0 {continue}
                if owners[a]<0 && actor_silent(c,a,natives[a]) {continue}
                actor:=d.actors[a]
                for k in actor.first_component..<actor.first_component+actor.component_count {
                    component:=d.components[k]
                    class:=component.class.name
                    if slice.contains(INSTANCED_COMPONENTS,class)!=instanced_pass {continue}
                    ref:=component.ref
                    if editor_only,_:=level.bool_of(d,ref,"bIsEditorOnly",false);editor_only {continue}
                    if instanced_pass && owners[a]<0 && !instanced_shown(c,a,k) {continue}
                    switch {
                    case class=="StaticMeshComponent" || instanced_pass:
                        add(c,level.path_of(d,ref,"StaticMesh"))
                        overrides(c,ref)
                    case class=="SkeletalMeshComponent":
                        path:=level.path_of(d,ref,"SkeletalMesh")
                        if path=="" {path=level.path_of(d,ref,"SkinnedAsset")}
                        add(c,path)
                        overrides(c,ref)
                    }
                }
            }
        }
    }
    reads_fill(c)
}

// Starts reading the next packages while a worker is free and the memory
// over the floor holds them.
@(private)
reads_fill :: proc(c:^Context) {
    r:=&c.reads
    js:=c.options.worker.system
    if js==nil {return}
    for r.next<len(r.order) {
        read:=r.order[r.next]
        if read.state!=.Waiting {r.next+=1;continue}
        if r.started>=jobs.worker_count(js) {break}
        // What the reads that run will still take is not in the memory the system counts yet.
        running:=read.cost
        for other in r.order[:r.next] {
            if intrinsics.atomic_load(&other.running) {running+=other.cost}
        }
        if memory_short(running) {break}
        read.state=.Started
        intrinsics.atomic_store(&read.running,true)
        r.started+=1
        r.next+=1
        if len(read.materials)>0 {jobs.run(js,c.options.worker.worker,.Background,materials_run,read)} else {jobs.run(js,c.options.worker.worker,.Background,read_run,read)}
    }
}

// Whether taking bytes more would leave less than MEMORY_FLOOR of the memory
// of the machine available; false when the system does not say.
@(private)
memory_short :: proc(bytes:int) -> bool {
    total,available,known:=base.memory_stats()
    return known && available-i64(bytes)<i64(f64(total)*MEMORY_FLOOR)
}

// Reads a package and builds its meshes and textures, on worker.
@(private)
read_run :: proc(read:^Read,worker:int) {
    options:=read.options
    options.worker=jobs.worker_ref_at(options.worker,worker)
    allocator:=options.worker.system.allocator
    context.allocator=allocator
    zone:=jobs.worker_zone_begin(options.worker,"level.read")
    defer base.profile_end(zone)
    defer sync.sema_post(&read.done)
    defer intrinsics.atomic_store(&read.running,false)
    model,error:=importer.import_model(read.file,read.formats,options,allocator)
    if error.code!=.None {
        read.error={error.code,strings.clone(error.message,allocator)}
        return
    }
    importer.model_cook(&model,options)
    read.model=model
}

// Translates materials of other packages and builds their images into the
// builder of the level, on worker, as the translation will: it finds their
// textures decoded. What the builder says of a texture, it says again to the
// translation.
@(private)
materials_run :: proc(read:^Read,worker:int) {
    c:=read.c
    ref:=jobs.worker_ref_at(read.options.worker,worker)
    heap:=ref.system.allocator
    zone:=jobs.worker_zone_begin(ref,"level.read.materials")
    defer base.profile_end(zone)
    defer sync.sema_post(&read.done)
    defer intrinsics.atomic_store(&read.running,false)
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,heap,heap)
    defer mem.dynamic_arena_destroy(&arena)
    context.allocator=heap
    context.temp_allocator=base.dynamic_arena_allocator(&arena)
    decoder,decoder_error:=kraken.decoder_make(heap)
    if decoder_error!=nil {return}
    defer kraken.decoder_destroy(&decoder)
    for path in read.materials {
        sync.mutex_lock(&c.library_lock)
        c.lib.worker=ref
        if object,found:=material.object_find(c.lib,path);found {
            if t,error:=material.translate(c.lib,object,{reads=c.format_options.reads,writers=c.writers},context.temp_allocator);error.code==.None {
                material_write.builder_room(&c.images)
                material_write.material_build(&c.images,&t,&decoder)
                material.translated_destroy(&t)
            }
        }
        sync.mutex_unlock(&c.library_lock)
        mem.dynamic_arena_reset(&arena)
    }
}

// The model of the package in file, read ahead or now; its caller destroys
// it. error.message lives in the temp allocator.
@(private)
reads_take :: proc(c:^Context,file:string) -> (model:importer.Imported_Model,error:importer.Error) {
    read:=c.reads.by_file[file]
    if read!=nil {reads_pass(c,read.index)}
    if read==nil || read.state!=.Started && read.state!=.Passed {
        // Not read ahead, or taken already by a mesh of the same package: read here, as when nothing is.
        if read!=nil {
            read.state=.Taken
            // Under the floor, it waits for the images of the level to go and for the reads that run to end.
            if memory_short(read.cost) {
                images_trim(c,read.cost)
                reads_drain(c,read.cost)
            }
            // It counts with the reads that run: those after it start while it is read, in the memory it leaves.
            intrinsics.atomic_store(&read.running,true)
        }
        defer if read!=nil {intrinsics.atomic_store(&read.running,false)}
        reads_fill(c)
        importer.zone(c.options,"level.read")
        model,error=importer.import_model(file,c.formats[:],c.options,c.report.allocator)
        if error.code==.None {importer.model_cook(&model,c.options)}
        return
    }
    wait_zone:=importer.zone_begin(c.options,"level.wait")
    sync.sema_wait(&read.done)
    base.profile_end(wait_zone)
    if read.state==.Started {c.reads.started-=1}
    read.state=.Taken
    model,error=read.model,read.error
    read.model={}
    if error.code!=.None {
        error.message=strings.clone(error.message,context.temp_allocator)
        delete(read.error.message,c.options.worker.system.allocator)
        read.error={}
    }
    reads_fill(c)
    return
}

// The packages started before the one at index in the order, which the
// translation passed by: they stop counting against the reads that can start,
// and are taken if asked for later.
@(private="file")
reads_pass :: proc(c:^Context,index:int) {
    r:=&c.reads
    for r.passed<index {
        read:=r.order[r.passed]
        r.passed+=1
        if read.state!=.Started {continue}
        read.state=.Passed
        r.started-=1
    }
}

// Waits for the reads that run to end, one after the other in their order,
// while bytes more do not fit over the floor.
@(private="file")
reads_drain :: proc(c:^Context,bytes:int) {
    importer.zone(c.options,"level.memory")
    for other in c.reads.order[:c.reads.next] {
        if !memory_short(bytes) {return}
        if !intrinsics.atomic_load(&other.running) {continue}
        sync.sema_wait(&other.done)
        sync.sema_post(&other.done)
    }
}

// Waits for what is still being read and lets it go: what is asked for
// later is read then.
@(private)
reads_end :: proc(c:^Context) {
    for read in c.reads.order {
        if read.state!=.Started && read.state!=.Passed {continue}
        sync.sema_wait(&read.done)
        importer.model_destroy(&read.model)
        delete(read.error.message,c.options.worker.system.allocator)
        read.state,read.error=.Waiting,{}
    }
    c.reads.started,c.reads.next,c.reads.passed=0,len(c.reads.order),len(c.reads.order)
}
