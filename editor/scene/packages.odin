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
// objects World Partition keeps in packages of their own. Its build data
// (lightmaps and the precomputed lighting of MapBuildDataRegistry) is not:
// Mirai lights by GI. A package a reference names that is not there is left
// out; the import says so when it needs it. Sorted, absolute, with forward
// slashes, in allocator.
level_packages :: proc(path:string,mounts:[]unreal.Source_Mount,allocator:=context.allocator) -> (files:[]string,error:importer.Error) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,context.allocator,context.allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&arena)
    scratch:=base.dynamic_arena_allocator(&arena)
    // Each package is read in this one, emptied once its imports are taken.
    reading:mem.Dynamic_Arena
    mem.dynamic_arena_init(&reading,context.allocator,context.allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&reading)
    read:=base.dynamic_arena_allocator(&reading)
    seen:=make(map[string]bool,scratch)
    queue:=make([dynamic]string,scratch)
    found:=make([dynamic]string,scratch)
    // The packages p imports and those it names softly, queued once each.
    scan :: proc(p:^unreal.Package,seen:^map[string]bool,queue:^[dynamic]string,allocator:mem.Allocator) {
        queue_one :: proc(name:string,seen:^map[string]bool,queue:^[dynamic]string,allocator:mem.Allocator) {
            if !strings.has_prefix(name,"/Game/") || seen[name] {return}
            kept:=strings.clone(name,allocator)
            seen[kept]=true
            append(queue,kept)
        }
        for item,i in p.imports {
            if item.outer!=0 || build_data_only(p,i) {continue}
            queue_one(unreal.name_text(p,item.object_name,context.temp_allocator),seen,queue,allocator)
        }
        soft,_:=unreal.soft_packages(p,context.temp_allocator)
        for name in soft {queue_one(name,seen,queue,allocator)}
    }
    // The package in file, opened in scratch; false when it cannot be read.
    open :: proc(file:string,scratch:mem.Allocator) -> (p:unreal.Package,ok:bool) {
        bytes,read_error:=serial.file_read(file,scratch,limit=i64(unreal.DEFAULT_LIMITS.source_bytes))
        if read_error!=.None {return}
        opened,open_error:=unreal.package_open(bytes,scratch,unreal.DEFAULT_LIMITS)
        return opened,open_error.code==.None
    }
    absolute,_:=filepath.abs(path,scratch)
    p,ok:=open(path,read)
    if !ok {return nil,importer.error_make(.Read,"%s is not an Unreal package that can be read",path)}
    name,name_error:=unreal.source_package_name(absolute,mounts,scratch)
    if name_error.code!=.None {return nil,importer.error_make(.Unsupported,"%s is under no mount of its content: %s",path,name_error.field)}
    seen[name]=true
    scan(&p,&seen,&queue,scratch)
    mem.dynamic_arena_reset(&reading)
    // The packages World Partition keeps apart, under /<mount>/__External*__/<path of the map>/.
    slash:=strings.index_byte(name[1:],'/')+1
    for kind in ([2]string{"__ExternalActors__","__ExternalObjects__"}) {
        external,path_error:=unreal.source_package_path(strings.concatenate({name[:slash],"/",kind,name[slash:]},scratch),mounts,scratch)
        if path_error.code!=.None {continue}
        directory:=external[:len(external)-len(".uasset")]
        if !os.is_dir(directory) {continue}
        walker:=os.walker_create(directory)
        for info in os.walker_walk(&walker) {
            if info.type!=.Regular || !strings.has_suffix(info.fullpath,".uasset") {continue}
            file:=strings.clone(info.fullpath,scratch)
            append(&found,file)
            if q,opened:=open(file,read);opened {scan(&q,&seen,&queue,scratch)}
            mem.dynamic_arena_reset(&reading)
        }
        os.walker_destroy(&walker)
    }
    for next:=0;next<len(queue);next+=1 {
        file:=""
        for extension in ([2]string{".uasset",".umap"}) {
            candidate,path_error:=unreal.source_package_path(queue[next],mounts,scratch,extension)
            if path_error.code==.None && os.exists(candidate) {file=candidate;break}
        }
        if file=="" {continue}
        append(&found,file)
        if q,opened:=open(file,read);opened {scan(&q,&seen,&queue,scratch)}
        mem.dynamic_arena_reset(&reading)
    }
    out:=make([]string,len(found),allocator)
    for file,i in found {out[i],_=strings.replace_all(file,"\\","/",allocator)}
    slice.sort(out)
    return out,{}
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

// Copies the map at source, outside the assets, with the packages it reads
// (level_packages) into folder of the assets, where /Game is: each at its
// path under /Game, so the copies find each other as Unreal does. Where the
// map is now, in allocator.
level_bring :: proc(source,folder:string,engine_content:="",allocator:=context.allocator) -> (brought:string,error:importer.Error) {
    bytes,read_error:=serial.file_read(source,context.temp_allocator,limit=i64(unreal.DEFAULT_LIMITS.source_bytes))
    if read_error!=.None {return "",importer.error_make(.Read,"%s could not be read: %v",source,read_error)}
    p,open_error:=unreal.package_open(bytes,context.temp_allocator,unreal.DEFAULT_LIMITS)
    if open_error.code!=.None {return "",importer.error_make(.Unsupported,"%s: %v at 0x%x: %s",source,open_error.code,open_error.offset,open_error.field)}
    absolute,_:=filepath.abs(source,context.temp_allocator)
    mounts:=uasset.mounts_find(absolute,{engine_content=engine_content},&p,context.temp_allocator,plugins=false)
    files,files_error:=level_packages(absolute,mounts,context.temp_allocator)
    if files_error.code!=.None {return "",files_error}
    all:=make([dynamic]string,0,len(files)+1,context.temp_allocator)
    append(&all,absolute)
    append(&all,..files)
    for file,i in all {
        name,name_error:=unreal.source_package_name(file,mounts,context.temp_allocator)
        if name_error.code!=.None || !strings.has_prefix(name,"/Game/") {continue}
        target:=strings.concatenate({strings.trim_right(folder,"/\\"),name[len("/Game"):],filepath.ext(file)},context.temp_allocator)
        if i==0 {brought=strings.clone(target,allocator)}
        if same_file(file,target) {continue}
        if made:=os.make_directory_all(filepath.dir(target));made!=nil && !os.is_dir(filepath.dir(target)) {
            return "",importer.error_make(.Write,"%s could not be made: %v",filepath.dir(target),made)
        }
        if copy_error:=os.copy_file(target,file);copy_error!=nil {return "",importer.error_make(.Write,"%s could not be copied to %s: %v",file,target,copy_error)}
    }
    if brought=="" {return "",importer.error_make(.Unsupported,"%s is not under /Game: only the content of a project is brought into the assets",source)}
    return
}

// Whether target already holds the bytes of file.
@(private="file")
same_file :: proc(file,target:string) -> bool {
    a,a_error:=os.stat(file,context.temp_allocator)
    b,b_error:=os.stat(target,context.temp_allocator)
    if a_error!=nil || b_error!=nil || a.size!=b.size {return false}
    x,_:=serial.file_read(file,context.temp_allocator)
    y,_:=serial.file_read(target,context.temp_allocator)
    defer {delete(x,context.temp_allocator);delete(y,context.temp_allocator)}
    return slice.equal(x,y)
}
