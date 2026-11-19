package unreal_scene

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import importer "mirai:cook/import"
import uasset "project:plugins/unreal/editor/model"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/base"
import "mirai:std/serial"

// The packages of /Game a map reads, as files under mounts: those its
// imports and its soft references name and theirs, and the actors and
// objects World Partition keeps in packages of their own (packages_walk).
// A package a reference names that is not there is left out; the import
// says so when it needs it. Sorted, absolute, with forward slashes, in
// allocator.
level_packages :: proc(path:string,mounts:[]unreal.Source_Mount,allocator:=context.allocator) -> (files:[]string,error:importer.Error) {
    absolute,_:=filepath.abs(path,context.temp_allocator)
    name,name_error:=unreal.source_package_name(absolute,mounts,context.temp_allocator)
    if name_error.code!=.None {return nil,importer.error_make(.Unsupported,"%s is under no mount of its content: %s",path,name_error.field)}
    if !os.is_file(absolute) {return nil,importer.error_make(.Read,"%s is not an Unreal package that can be read",path)}
    disk:=Disk_Source{mounts}
    all,walk_error:=packages_walk({name},{data=&disk,files=disk_files,under=disk_under},context.temp_allocator)
    if walk_error.code!=.None {return nil,walk_error}
    out:=make([dynamic]string,0,len(all),allocator)
    root,_:=strings.replace_all(absolute,"\\","/",context.temp_allocator)
    for file in all {
        clean,_:=strings.replace_all(file,"\\","/",context.temp_allocator)
        if clean!=root {append(&out,strings.clone(clean,allocator))}
    }
    slice.sort(out[:])
    return out[:],{}
}

// Where packages_walk reads packages from. files gives the file of each name
// ("" for one that is not there), all of them at once; under, the files of
// the packages in a folder of names.
Package_Source :: struct {
    data:rawptr,
    files:proc(data:rawptr,names:[]string,allocator:mem.Allocator) -> (files:[]string,error:importer.Error),
    under:proc(data:rawptr,folder:string,allocator:mem.Allocator) -> (files:[]string,error:importer.Error),
}

// The files of the packages of /Game named in roots and of those they read:
// the packages their imports and soft references name, and those World
// Partition keeps of a map apart under /<mount>/__External*__/<path of the
// map>/. Not the build data of a map (lightmaps and the precomputed lighting
// of MapBuildDataRegistry): Mirai lights by GI. It asks source for each round
// of names at once, so that a source that downloads them fetches a round
// together. In allocator.
packages_walk :: proc(roots:[]string,source:Package_Source,allocator:=context.allocator) -> (files:[]string,error:importer.Error) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,context.allocator,context.allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&arena)
    scratch:=base.dynamic_arena_allocator(&arena)
    // Each package is read in this one, emptied once its references are taken.
    reading:mem.Dynamic_Arena
    mem.dynamic_arena_init(&reading,context.allocator,context.allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&reading)
    read:=base.dynamic_arena_allocator(&reading)
    seen:=make(map[string]bool,scratch)
    found:=make([dynamic]string,allocator)
    round:=make([dynamic]string,scratch)
    for name in roots {
        if seen[name] {continue}
        seen[strings.clone(name,scratch)]=true
        append(&round,strings.clone(name,scratch))
    }
    // The packages of the file, their references queued once each in next.
    take :: proc(file:string,seen:^map[string]bool,next:^[dynamic]string,scratch,read:mem.Allocator) {
        bytes,read_error:=serial.file_read(file,read,limit=i64(unreal.DEFAULT_LIMITS.source_bytes))
        if read_error!=.None {return}
        p,open_error:=unreal.package_open(bytes,read,unreal.DEFAULT_LIMITS)
        if open_error.code!=.None {return}
        for name in package_references(&p,read) {
            if seen[name] {continue}
            kept:=strings.clone(name,scratch)
            seen[kept]=true
            append(next,kept)
        }
    }
    for len(round)>0 {
        round_files,files_error:=source.files(source.data,round[:],scratch)
        if files_error.code!=.None {return found[:],files_error}
        next:=make([dynamic]string,scratch)
        for file,i in round_files {
            if file=="" {continue}
            append(&found,strings.clone(file,allocator))
            take(file,&seen,&next,scratch,read)
            mem.dynamic_arena_reset(&reading)
            if !strings.has_suffix(file,".umap") {continue}
            name:=round[i]
            slash:=strings.index_byte(name[1:],'/')+1
            for kind in ([2]string{"__ExternalActors__","__ExternalObjects__"}) {
                externals,under_error:=source.under(source.data,strings.concatenate({name[:slash],"/",kind,name[slash:]},scratch),scratch)
                if under_error.code!=.None {return found[:],under_error}
                for external in externals {
                    append(&found,strings.clone(external,allocator))
                    take(external,&seen,&next,scratch,read)
                    mem.dynamic_arena_reset(&reading)
                }
            }
        }
        round=next
    }
    return found[:],{}
}

// The packages of /Game p imports, but for the build data of a map, and those
// it names softly; in allocator.
package_references :: proc(p:^unreal.Package,allocator:=context.allocator) -> []string {
    out:=make([dynamic]string,allocator)
    for item,i in p.imports {
        if item.outer!=0 || build_data_only(p,i) {continue}
        if name:=unreal.name_text(p,item.object_name,allocator);strings.has_prefix(name,"/Game/") {append(&out,name)}
    }
    soft,_:=unreal.soft_packages(p,allocator)
    for name in soft {if strings.has_prefix(name,"/Game/") {append(&out,name)}}
    return out[:]
}

// Packages as files of the content under mounts.
@(private="file")
Disk_Source :: struct {mounts:[]unreal.Source_Mount}

@(private="file")
disk_files :: proc(data:rawptr,names:[]string,allocator:mem.Allocator) -> (files:[]string,error:importer.Error) {
    disk:=(^Disk_Source)(data)
    out:=make([]string,len(names),allocator)
    for name,i in names {
        for extension in ([2]string{".uasset",".umap"}) {
            candidate,path_error:=unreal.source_package_path(name,disk.mounts,allocator,extension)
            if path_error.code==.None && os.exists(candidate) {out[i]=candidate;break}
        }
    }
    return out,{}
}

@(private="file")
disk_under :: proc(data:rawptr,folder:string,allocator:mem.Allocator) -> (files:[]string,error:importer.Error) {
    disk:=(^Disk_Source)(data)
    path,path_error:=unreal.source_package_path(folder,disk.mounts,allocator)
    if path_error.code!=.None {return nil,{}}
    directory:=path[:len(path)-len(".uasset")]
    if !os.is_dir(directory) {return nil,{}}
    out:=make([dynamic]string,allocator)
    walker:=os.walker_create(directory)
    defer os.walker_destroy(&walker)
    for info in os.walker_walk(&walker) {
        if info.type==.Regular && strings.has_suffix(info.fullpath,".uasset") {append(&out,strings.clone(info.fullpath,allocator))}
    }
    slice.sort(out[:])
    return out[:],{}
}

// Whether all p imports from its package import at index is the build data
// of a map.
@(private="file")
build_data_only :: proc(p:^unreal.Package,index:int) -> bool {
    any:=false
    for item in p.imports {
        if int(-i64(item.outer)-1)!=index {continue}
        if unreal.name_plain(p,item.class_name)!="MapBuildDataRegistry" {return false}
        any=true
    }
    return any
}
