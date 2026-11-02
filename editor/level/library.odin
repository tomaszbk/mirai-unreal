package level

import "core:mem"
import "core:os"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/serial"

// The packages a level reads besides itself: those that hold the archetypes
// of its objects (Blueprints) and its external actors. They are opened once,
// by long package name, through explicit mounts; a package that fails keeps
// its error and is not read again.
Library :: struct {
    mounts:[]unreal.Source_Mount,
    packages:[dynamic]^Library_Package,
    by_name:map[string]int, // by the lowercase long name of each package
    limits:unreal.Limits,
    allocator:mem.Allocator,
}

Library_Package :: struct {
    name:string,
    bytes:[]u8,
    pkg:unreal.Package,
    error:unreal.Error,
    owned:bool, // read and opened by the library, which releases it
}

library_init :: proc(lib:^Library,mounts:[]unreal.Source_Mount,allocator:=context.allocator,limits:=unreal.DEFAULT_LIMITS) {
    lib^={mounts=mounts,limits=limits,allocator=allocator}
    lib.packages.allocator=allocator
    lib.by_name.allocator=allocator
}

library_destroy :: proc(lib:^Library) {
    for entry in lib.packages {
        if entry.owned {
            unreal.package_destroy(&entry.pkg)
            delete(entry.bytes,lib.allocator)
        }
        delete(entry.name,lib.allocator)
        free(entry,lib.allocator)
    }
    for key in lib.by_name {delete(key,lib.allocator)}
    delete(lib.packages)
    delete(lib.by_name)
    lib^={}
}

// Adds a package the caller opened and keeps; its index.
library_add :: proc(lib:^Library,name:string,p:^unreal.Package) -> (index:int,error:unreal.Error) {
    entry,allocation_error:=new(Library_Package,lib.allocator)
    if allocation_error!=nil {return -1,{.Out_Of_Memory,0,"library package"}}
    entry^={name=strings.clone(name,lib.allocator),pkg=p^}
    return library_append(lib,entry),{}
}

library_package :: proc(lib:^Library,index:int) -> ^unreal.Package {return &lib.packages[index].pkg}

// The package of a long name, opened from its mount if it was not already.
library_find :: proc(lib:^Library,name:string) -> (index:int,error:unreal.Error) {
    if at,found:=lib.by_name[strings.to_lower(name,context.temp_allocator)];found {return at,lib.packages[at].error}
    entry,allocation_error:=new(Library_Package,lib.allocator)
    if allocation_error!=nil {return -1,{.Out_Of_Memory,0,"library package"}}
    entry.name=strings.clone(name,lib.allocator)
    entry.owned=true
    index=library_append(lib,entry)
    entry.error=library_read(lib,entry)
    return index,entry.error
}

@(private)
library_append :: proc(lib:^Library,entry:^Library_Package) -> int {
    index:=len(lib.packages)
    append(&lib.packages,entry)
    key:=strings.to_lower(entry.name,lib.allocator)
    if key in lib.by_name {delete(key,lib.allocator)} else {lib.by_name[key]=index}
    return index
}

@(private)
library_read :: proc(lib:^Library,entry:^Library_Package) -> unreal.Error {
    path:string
    for extension in ([2]string{".uasset",".umap"}) {
        candidate,error:=unreal.source_package_path(entry.name,lib.mounts,context.temp_allocator,extension)
        if error.code!=.None {return error}
        if os.exists(candidate) {path=candidate;break}
    }
    if path=="" {return {.Invalid_Reference,0,"the package of an archetype or external actor is not under its mount"}}
    bytes,read_error:=serial.file_read(path,lib.allocator,limit=i64(lib.limits.source_bytes))
    if read_error!=.None {return {.Truncated,0,"the package of an archetype or external actor cannot be read"}}
    p,error:=unreal.package_open(bytes,lib.allocator,lib.limits,entry.name)
    if error.code!=.None {delete(bytes,lib.allocator);return error}
    entry.bytes=bytes
    entry.pkg=p
    return {}
}
