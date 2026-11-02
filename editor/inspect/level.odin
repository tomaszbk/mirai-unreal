package inspect

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import uasset "project:plugins/unreal/editor/model"
import ufoliage "project:plugins/unreal/editor/foliage"
import "project:plugins/unreal/editor/kraken"
import "project:plugins/unreal/editor/landscape"
import level "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/serial"

// unreal.inspect <mapa> --level: actors and components of each class,
// transforms that could not be read, the cells of World Partition, and what
// the landscapes and foliage give.

@(private="file")
Count :: struct {name:string,count:int}

@(private="file")
counts_print :: proc(w:io.Writer,title:string,counts:map[string]int) {
    sorted:=make([dynamic]Count,context.temp_allocator)
    for name,count in counts {append(&sorted,Count{name,count})}
    slice.sort_by(sorted[:],proc(a,b:Count) -> bool {return a.count>b.count || a.count==b.count && a.name<b.name})
    fmt.wprintfln(w,"  %s:",title)
    for c in sorted {fmt.wprintfln(w,"    %d %s",c.count,c.name)}
}

unreal_inspect_level :: proc(w:io.Writer,path:string,mounts_given:[]unreal.Source_Mount) -> bool {
    bytes,read_error:=serial.file_read(path,limit=i64(unreal.DEFAULT_LIMITS.source_bytes))
    if read_error!=.None {fmt.wprintfln(w,"%s: could not be read (%v)",path,read_error);return false}
    defer delete(bytes)
    p,error:=unreal.package_open(bytes)
    if error.code!=.None {fmt.wprintfln(w,"%s: package %v at 0x%x: %s",path,error.code,error.offset,error.field);return false}
    defer unreal.package_destroy(&p)
    // The mounts mirai import finds for the map, after those given.
    mounts:=make([dynamic]unreal.Source_Mount,context.temp_allocator)
    append(&mounts,..mounts_given)
    append(&mounts,..uasset.mounts_find(path,{},&p))
    absolute,_:=filepath.abs(path,context.temp_allocator)
    name,name_error:=unreal.source_package_name(absolute,mounts[:],context.temp_allocator)
    if name_error.code!=.None {
        fmt.wprintfln(w,"%s: is not under a Content folder nor under a --mount; pass --mount /Prefix=folder (%s)",path,name_error.field)
        return false
    }
    p.source_package=name
    lib:level.Library
    level.library_init(&lib,mounts[:])
    defer level.library_destroy(&lib)
    map_index,_:=level.library_add(&lib,name,&p)
    d:level.Document
    error=level.document_open(&d,&lib,map_index)
    if error.code!=.None {fmt.wprintfln(w,"%s: level %v at 0x%x: %s",path,error.code,error.offset,error.field);return false}
    defer level.document_destroy(&d)
    external:=0
    for actor in d.actors {if actor.external {external+=1}}
    fmt.wprintfln(w,"%s (%s): UE4=%d UE5=%d levels=%d actors=%d external=%d components=%d packages=%d",path,name,p.summary.version_ue4,p.summary.version_ue5,len(d.levels),len(d.actors),external,len(d.components),len(lib.packages))
    actors:=make(map[string]int,context.temp_allocator)
    components:=make(map[string]int,context.temp_allocator)
    failures:=make(map[string]int,context.temp_allocator)
    placed,unplaced,failed:=0,0,0
    for actor,i in d.actors {
        actors[fmt.tprintf("%s.%s",actor.class.pkg,actor.class.name)]+=1
        _,has_place,transform_error:=level.actor_world(&d,i)
        switch {
        case transform_error.code!=.None:
            failed+=1
            failures[fmt.tprintf("%v: %s",transform_error.code,transform_error.field)]+=1
        case has_place:placed+=1
        case:unplaced+=1
        }
    }
    component_failed:=0
    origins:[level.Origin]int
    for component,i in d.components {
        if found,found_error:=level.property(&d,component.ref,"RelativeLocation");found_error.code==.None {origins[found.origin]+=1}
        components[fmt.tprintf("%s.%s",component.class.pkg,component.class.name)]+=1
        if _,transform_error:=level.component_relative(&d,i);transform_error.code!=.None {
            component_failed+=1
            failures[fmt.tprintf("component %v: %s",transform_error.code,transform_error.field)]+=1
        }
    }
    counts_print(w,"actors by class",actors)
    counts_print(w,"components by class",components)
    fmt.wprintfln(w,"  transforms: %d actors placed, %d without RootComponent, %d failed; %d components failed",placed,unplaced,failed,component_failed)
    fmt.wprintfln(w,"  RelativeLocation of components: %d authored, %d from archetypes, %d from native classes",origins[.Authored],origins[.Archetype],origins[.Native])
    for reason,count in failures {fmt.wprintfln(w,"    failure %s: %d",reason,count)}
    if len(d.superseded)>0 {
        fmt.wprintfln(w,"  %d external actor packages left out: another package holds their actor, which Unreal loads once",len(d.superseded))
        for item,i in d.superseded {
            if i==8 {fmt.wprintfln(w,"    ...");break}
            fmt.wprintfln(w,"    %s: %s, not %s",item.actor[strings.last_index_byte(item.actor,'.')+1:],item.kept,item.left)
        }
    }
    ok:=failed==0 && component_failed==0
    ok&=inspect_partition(w,&d)
    ok&=inspect_landscapes(w,&d)
    ok&=inspect_foliage(w,&d)
    return ok
}

// The components whose instances import as batches of foliage.
@(private="file")
INSTANCED :: []string{"InstancedStaticMeshComponent","HierarchicalInstancedStaticMeshComponent","FoliageInstancedStaticMeshComponent"}

// What is in a section: the actors of a cell, or those that load with the map.
@(private="file")
Section_Count :: struct {actors,instanced,instances,types,failed:int}

// The cells of the runtime grids of a World Partition map and what each
// would hold: its actors, its instanced components and their instances, and
// the types of foliage they make (one for each mesh and materials), besides
// what loads with the map. The instances of the HLOD of Unreal, which is not
// imported, are not counted.
@(private="file")
inspect_partition :: proc(w:io.Writer,d:^level.Document) -> bool {
    p,error:=level.partition_read(d,context.temp_allocator)
    if error.code==.Unsupported_Value && p.hash!="" {
        fmt.wprintfln(w,"  partition: %s is not read (%s); everything loads with the map",p.hash,error.field)
        return true
    }
    if error.code!=.None {fmt.wprintfln(w,"  partition %v at 0x%x: %s",error.code,error.offset,error.field);return false}
    if p.hash=="" {return true}
    fmt.wprintfln(w,"  partition: %s, %d grids, %d cells; %d actors name data layers, which do not split cells",p.hash,len(p.grids),len(p.cells),p.layered)
    for g in p.grids {
        if g.kind==.Persistent {fmt.wprintfln(w,"    grid %s: persistent, loads with the map",g.name);continue}
        fmt.wprintfln(w,"    grid %s: cells of %.0f m in %s from %v, loaded within %.0f m, boxes from %v",g.name,g.cell_size/100,g.flat?"2D":"3D",g.origin/100,g.loading_range/100,g.bounds)
    }
    counts:=make([]Section_Count,len(p.cells)+1,context.temp_allocator)
    types:=make([]map[string]bool,len(p.cells)+1,context.temp_allocator)
    for &t in types {t=make(map[string]bool,context.temp_allocator)}
    root_classes:=make(map[string]int,context.temp_allocator)
    for actor,a in d.actors {
        s:=p.actor_cells[a]+1
        counts[s].actors+=1
        if s==0 {root_classes[actor.class.name]+=1}
        // The foliage registry of an InstancedFoliageActor is read apart; the HLOD of Unreal is not imported.
        if native:=level.actor_native_class(d,a).name;native=="InstancedFoliageActor" || native=="WorldPartitionHLOD" {continue}
        for k in actor.first_component..<actor.first_component+actor.component_count {
            if !slice.contains(INSTANCED,d.components[k].class.name) {continue}
            ref:=d.components[k].ref
            instances,instances_error:=level.component_instances(d,k,context.temp_allocator)
            if instances_error.code!=.None {counts[s].failed+=1;continue}
            if len(instances.matrices)==0 {continue}
            counts[s].instanced+=1
            counts[s].instances+=len(instances.matrices)
            key:=level.path_of(d,ref,"StaticMesh")
            for material in level.paths_of(d,ref,"OverrideMaterials") {key=fmt.tprintf("%s|%s",key,material)}
            types[s][key]=true
        }
    }
    total:Section_Count
    by_level:=make(map[int]int,context.temp_allocator)
    for &c,s in counts {
        c.types=len(types[s])
        total.actors+=c.actors;total.instanced+=c.instanced;total.instances+=c.instances;total.failed+=c.failed;total.types+=c.types
        if s>0 {by_level[p.cells[s-1].level]+=1}
    }
    fmt.wprintfln(w,"    with the map: %d actors, %d instanced components, %d instances, %d types of foliage",counts[0].actors,counts[0].instanced,counts[0].instances,counts[0].types)
    counts_print(w,"actors that load with the map",root_classes)
    levels:=make([dynamic]int,context.temp_allocator)
    for l in by_level {append(&levels,l)}
    slice.sort(levels[:])
    for l in levels {fmt.wprintfln(w,"    level %d: %d cells",l,by_level[l])}
    for c,i in p.cells {
        n:=counts[i+1]
        size:=c.box.max-c.box.min
        fmt.wprintfln(w,"    cell %s: %d actors, %d instanced components, %d instances, %d types; box of %.0fx%.0fx%.0f m at %.0f",c.name,n.actors,n.instanced,n.instances,n.types,size.x,size.y,size.z,(c.box.min+c.box.max)*0.5)
    }
    fmt.wprintfln(w,"    in all: %d sections and the map, %d instanced components (%d unread), %d instances, %d types of foliage summed over the sections",len(p.cells),total.instanced,total.failed,total.instances,total.types)
    return total.failed==0
}

@(private="file")
inspect_landscapes :: proc(w:io.Writer,d:^level.Document) -> bool {
    decoder,decoder_error:=kraken.decoder_make()
    if decoder_error!=nil {fmt.wprintln(w,"  out of memory for the decoder");return false}
    defer kraken.decoder_destroy(&decoder)
    list,error:=landscape.landscapes_read(d,&decoder)
    if error.code!=.None {fmt.wprintfln(w,"  landscape %v at 0x%x: %s",error.code,error.offset,error.field);return false}
    defer landscape.landscapes_destroy(&list)
    for l in list {
        low,high:=f32(max(f32)),f32(min(f32))
        for h in l.heights {low,high=min(low,h),max(high,h)}
        holes:=0
        for h in l.holes {holes+=int(h)}
        across:=l.spacing*l.transform.scale.x
        fmt.wprintfln(w,"  landscape '%s': %d components, subsections of %d quads, grid of %dx%d samples every %.3f m across and %.3f m along (%.1f x %.1f m)",d.actors[l.actor].label,l.components,l.subsection_quads,l.samples.x,l.samples.y,across,l.spacing,f32(l.samples.x-1)*across,f32(l.samples.y-1)*l.spacing)
        sorted:=slice.clone(l.heights,context.temp_allocator)
        slice.sort(sorted)
        fmt.wprintfln(w,"    heights %.3f to %.3f m (percentiles 1, 50 and 99: %.3f, %.3f, %.3f); center %v, rotation %v",low,high,sorted[len(sorted)/100],sorted[len(sorted)/2],sorted[len(sorted)*99/100],l.transform.position,l.transform.rotation)
        fmt.wprintfln(w,"    holes %d cells (%d quads without a component); material %s",holes,l.missing_quads,l.material)
        for layer in l.layers {fmt.wprintfln(w,"    layer %s (%s): %.1f%%",layer.name,layer.info,layer.coverage*100)}
        if len(l.layers)==0 {fmt.wprintln(w,"    no painted layers")}
    }
    return true
}

@(private="file")
inspect_foliage :: proc(w:io.Writer,d:^level.Document) -> bool {
    list,error:=ufoliage.foliage_read(d)
    if error.code!=.None {fmt.wprintfln(w,"  foliage %v at 0x%x: %s",error.code,error.offset,error.field);return false}
    defer ufoliage.foliages_destroy(&list)
    ok:=true
    for f in list {
        grounded:=0
        for i in f.instances {if i.base>=0 {grounded+=1}}
        fmt.wprintfln(w,"  foliage '%s': %d types, %d instances (%d on a known component); compared with their component %d, different %d, largest difference %.4f, types not compared %d",d.actors[f.actor].label,len(f.types),len(f.instances),grounded,f.compared,f.mismatched,f.max_difference,f.uncompared)
        for t in f.types {
            switch t.kind {
            case .Static_Mesh:
                fmt.wprintfln(w,"    %d %s: mesh %s, density %.3f/m2, scale %v, cull %v m, shadow %v, collision %s",t.instance_count,t.name,t.mesh,t.density,t.scale,t.cull,t.casts_shadow,t.collision_profile)
            case .Actor,.ISM_Actor:
                placed:=0
                for i in f.instances[t.first_instance:][:t.instance_count] {if i.actor>=0 {placed+=1}}
                fmt.wprintfln(w,"    %d %s: %s of %s, %d with their actor in the level",t.instance_count,t.name,t.kind==.Actor?"actors":"static meshes of the actors",t.actor_class,placed)
            }
        }
        if len(f.components)>0 {fmt.wprintfln(w,"    %d instanced components draw its ISM actors",len(f.components))}
        ok&=f.mismatched==0
    }
    return ok
}

// "/Game/Package=folder": the folder of a prefix of packages, which exists.
mount_parse :: proc(text:string) -> (mount:unreal.Source_Mount,ok:bool) {
    at:=strings.index_byte(text,'=')
    if at<=0 {return}
    directory,_:=filepath.abs(text[at+1:])
    if !os.is_dir(directory) {return}
    return {text[:at],directory},true
}
