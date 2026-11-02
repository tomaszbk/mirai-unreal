package material

import "core:fmt"
import "core:mem"
import "core:strings"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"

// The packages a translation reads, each opened once by name: a material,
// the parents of an instance, the functions and collections it calls and
// the textures it samples. Packages are files under the mounts or bytes the
// caller gives (library_add). Everything lives in the arena of the library.
Library :: struct {
    mounts:[]unreal.Source_Mount,
    plugins_pending:bool, // the plugins of the engine of the /Engine mount are mounted by library_plugins_mount
    packages:map[string]^Opened, // by package name in lower case
    decoder:kraken.Decoder,
    decoder_ready:bool,
    arena:mem.Dynamic_Arena,
    allocator:mem.Allocator,
    limits:unreal.Limits,
    worker:jobs.Worker_Ref, // that uses the library
}

Opened :: struct {
    name:string,
    bytes:[]u8,
    p:unreal.Package,
    error:unreal.Error, // why it could not be opened; the package is empty then
    properties:map[int]^Cached_Properties,
}

Cached_Properties :: struct {list:unreal.Property_List,error:unreal.Error}

// An export of an opened package.
Object :: struct {pkg:^Opened,export:int}

library_init :: proc(lib:^Library,mounts:[]unreal.Source_Mount,allocator:=context.allocator,limits:=unreal.DEFAULT_LIMITS,plugins_pending:=false) {
    lib^={limits=limits,plugins_pending=plugins_pending}
    mem.dynamic_arena_init(&lib.arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    lib.allocator=base.dynamic_arena_allocator(&lib.arena)
    lib.mounts=make([]unreal.Source_Mount,len(mounts),lib.allocator)
    for mount,i in mounts {lib.mounts[i]={strings.clone(mount.package_prefix,lib.allocator),strings.clone(mount.directory,lib.allocator)}}
    lib.packages.allocator=lib.allocator
}

library_destroy :: proc(lib:^Library) {
    if lib.decoder_ready {kraken.decoder_destroy(&lib.decoder)}
    mem.dynamic_arena_destroy(&lib.arena)
    lib^={}
}

// Gives the bytes of a package by name instead of its file; they are copied.
library_add :: proc(lib:^Library,name:string,bytes:[]u8) -> ^Opened {
    key:=strings.to_lower(name,lib.allocator)
    opened:=new(Opened,lib.allocator)
    opened.name=strings.clone(name,lib.allocator)
    opened.bytes=make([]u8,len(bytes),lib.allocator)
    copy(opened.bytes,bytes)
    opened.properties.allocator=lib.allocator
    p,error:=unreal.package_open(opened.bytes,lib.allocator,lib.limits,opened.name)
    opened.p=p
    opened.error=error
    lib.packages[key]=opened
    return opened
}

// The package of that name, opened from its file under the mounts the first
// time. nil when no mount has it; one that does not open keeps its error.
library_open :: proc(lib:^Library,name:string) -> ^Opened {
    key:=strings.to_lower(name,context.temp_allocator)
    if opened,found:=lib.packages[key];found {return opened}
    path,path_error:=unreal.source_package_path(name,lib.mounts,context.temp_allocator)
    if path_error.code!=.None && library_plugins_mount(lib,name) {path,path_error=unreal.source_package_path(name,lib.mounts,context.temp_allocator)}
    if path_error.code!=.None {return nil}
    jobs.worker_zone(lib.worker,"unreal.package")
    bytes,read_error:=serial.file_read(path,lib.allocator,limit=i64(lib.limits.source_bytes))
    if read_error!=.None {
        // A map is a package too.
        map_path,_:=unreal.source_package_path(name,lib.mounts,context.temp_allocator,".umap")
        bytes,read_error=serial.file_read(map_path,lib.allocator,limit=i64(lib.limits.source_bytes))
        if read_error!=.None {return nil}
    }
    opened:=new(Opened,lib.allocator)
    opened.name=strings.clone(name,lib.allocator)
    opened.bytes=bytes
    opened.properties.allocator=lib.allocator
    p,error:=unreal.package_open(opened.bytes,lib.allocator,lib.limits,opened.name)
    opened.p=p
    opened.error=error
    lib.packages[strings.clone(key,lib.allocator)]=opened
    return opened
}

// Walking the plugins of an engine reads hundreds of folders: a library mounts
// them once, when it first reads a package that only a plugin can hold.
@(private)
library_plugins_mount :: proc(lib:^Library,name:string) -> bool {
    if !lib.plugins_pending || !unreal.long_package_name_valid(name) {return false}
    slash:=strings.index_byte(name[1:],'/')
    if slash<0 || strings.equal_fold(name[:slash+1],"/Game") || strings.equal_fold(name[:slash+1],"/Engine") {return false}
    lib.plugins_pending=false
    engine:=""
    for mount in lib.mounts {if mount.package_prefix=="/Engine" {engine=mount.directory}}
    if engine=="" {return false}
    plugins:=unreal.engine_plugin_mounts(engine,context.temp_allocator)
    if len(plugins)==0 {return false}
    mounts:=make([]unreal.Source_Mount,len(lib.mounts)+len(plugins),lib.allocator)
    copy(mounts,lib.mounts)
    for mount,i in plugins {mounts[len(lib.mounts)+i]={strings.clone(mount.package_prefix,lib.allocator),strings.clone(mount.directory,lib.allocator)}}
    lib.mounts=mounts
    return true
}

library_decoder :: proc(lib:^Library) -> (^kraken.Decoder,bool) {
    if !lib.decoder_ready {
        decoder,error:=kraken.decoder_make(lib.allocator)
        if error!=nil {return nil,false}
        lib.decoder=decoder
        lib.decoder_ready=true
    }
    return &lib.decoder,true
}

object_valid :: proc(o:Object) -> bool {
    return o.pkg!=nil && o.pkg.error.code==.None && o.export>=0 && o.export<len(o.pkg.p.exports)
}

// The name of the class of an export, as Unreal names it ("Material").
object_class :: proc(o:Object) -> string {
    if !object_valid(o) {return ""}
    p:=&o.pkg.p
    name,ok:=unreal.reference_name(p,p.exports[o.export].class)
    return ok?unreal.name_plain(p,name):""
}

object_name :: proc(o:Object) -> string {
    if !object_valid(o) {return ""}
    return unreal.name_text(&o.pkg.p,o.pkg.p.exports[o.export].object_name,context.temp_allocator)
}

// "/Game/Materials/M_Wall.M_Wall": how Unreal names an object.
object_path :: proc(o:Object,allocator:=context.temp_allocator) -> string {
    if !object_valid(o) {return ""}
    path,error:=unreal.reference_path(&o.pkg.p,unreal.Object_Ref(o.export+1),allocator)
    return error.code==.None?path:object_name(o)
}

// The export a reference of o's package names: an export of the same
// package, or the export of another package that an import names, which the
// library opens. False for a null reference or one it cannot reach.
object_resolve :: proc(lib:^Library,from:^Opened,reference:unreal.Object_Ref) -> (Object,bool) {
    if from==nil || from.error.code!=.None || reference==0 || !unreal.reference_valid(&from.p,reference) {return {},false}
    if reference>0 {return {from,int(reference)-1},true}
    p:=&from.p
    chain:[32]unreal.Name_Ref
    depth:=0
    package_name:string
    current:=reference
    for {
        if current>=0 || depth>=len(chain) {return {},false}
        item:=p.imports[int(-i64(current)-1)]
        class:=unreal.name_plain(p,item.class_name)
        if item.outer==0 {
            if class=="Package" {
                package_name=unreal.name_text(p,item.object_name,context.temp_allocator)
            } else {
                chain[depth]=item.object_name
                depth+=1
                package_name=unreal.name_text(p,item.package_name,context.temp_allocator)
            }
            break
        }
        chain[depth]=item.object_name
        depth+=1
        current=item.outer
    }
    if depth==0 || package_name=="" || package_name=="None" {return {},false}
    target:=library_open(lib,package_name)
    if target==nil || target.error.code!=.None {return {},false}
    q:=&target.p
    outer:=unreal.Object_Ref(0)
    for level:=depth-1;level>=0;level-=1 {
        found:=-1
        for &item,index in q.exports {
            if item.outer==outer && unreal.names_equal(q,item.object_name,p,chain[level]) {found=index;break}
        }
        if found<0 {return {},false}
        outer=unreal.Object_Ref(found+1)
    }
    return {target,int(outer)-1},true
}

// The object of a full path ("/Game/M/M_Wall.M_Wall" or the package alone,
// "/Game/M/M_Wall", for its asset of the same name).
object_find :: proc(lib:^Library,path:string) -> (Object,bool) {
    package_name:=path
    object:=""
    if dot:=strings.index_byte(path,'.');dot>=0 {package_name,object=path[:dot],path[dot+1:]}
    if object=="" {object=package_name[strings.last_index_byte(package_name,'/')+1:]}
    target:=library_open(lib,package_name)
    if target==nil || target.error.code!=.None {return {},false}
    q:=&target.p
    outer:=unreal.Object_Ref(0)
    rest:=object
    for rest!="" {
        part:=rest
        next:=strings.index_any(rest,".:")
        if next>=0 {part,rest=rest[:next],rest[next+1:]} else {rest=""}
        found:=-1
        for &item,index in q.exports {
            if item.outer==outer && strings.equal_fold(unreal.name_text(q,item.object_name,context.temp_allocator),part) {found=index;break}
        }
        if found<0 {return {},false}
        outer=unreal.Object_Ref(found+1)
    }
    return {target,int(outer)-1},true
}

// The tagged properties of an export, read once.
object_properties :: proc(o:Object) -> (^unreal.Property_List,unreal.Error) {
    if !object_valid(o) {return nil,{.Invalid_Reference,0,"object"}}
    if cached,found:=o.pkg.properties[o.export];found {return &cached.list,cached.error}
    cached:=new(Cached_Properties,o.pkg.properties.allocator)
    cached.list,cached.error=unreal.export_properties(&o.pkg.p,o.export,true,o.pkg.properties.allocator)
    o.pkg.properties[o.export]=cached
    return &cached.list,cached.error
}

// The export of class whose outer is o (the editor-only data of a material).
object_child :: proc(o:Object,class:string) -> (Object,bool) {
    if !object_valid(o) {return {},false}
    for &item,index in o.pkg.p.exports {
        child:=Object{o.pkg,index}
        if item.outer==unreal.Object_Ref(o.export+1) && object_class(child)==class {return child,true}
    }
    return {},false
}
