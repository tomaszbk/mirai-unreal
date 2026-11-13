package fab

import "core:crypto/legacy/sha1"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import importer "mirai:cook/import"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:std/base"

// Downloads files of a build: the chunks of only those files, fetched
// together, put together into the files and checked against their hashes.
// Packages of the Unreal format bring the packages they read, round by
// round (unreal_scene.packages_walk), so that one asset of a pack comes with
// its meshes, materials and textures and nothing else.

CHUNKS_PER_FETCH :: 64 // a fetch says how far it went once each of these

// How far a download went, read by another thread while it runs.
Progress :: struct {
    bytes,total:i64, // of the chunks fetched and to fetch
    files:i64,       // put together
    cancel:bool,     // set to stop it at the next fetch
}

Build :: struct {
    manifest:Manifest,
    base:string,    // address of the folder its chunks are under
    staging:string, // folder of the download, removed once it ends
    progress:^Progress,
    fetched:[]bool, // by file
    held:[]bool,    // by chunk: its file is in the staging folder
}

// The file the manifest of an Unreal build keeps the package of /Game named
// name in, -1 when it has none: under the Content folder of the build.
build_package :: proc(b:^Build,name:string) -> int {
    root:=content_root(&b.manifest)
    if !strings.has_prefix(name,"/Game/") {return -1}
    for extension in ([2]string{".uasset",".umap"}) {
        if at:=manifest_file(&b.manifest,strings.concatenate({root,name[len("/Game/"):],extension},context.temp_allocator));at>=0 {return at}
    }
    return -1
}

// The folder of the manifest that is /Game: the one above the first package,
// named Content.
content_root :: proc(m:^Manifest) -> string {
    for file in m.files {
        if !strings.has_suffix(file.name,".uasset") && !strings.has_suffix(file.name,".umap") {continue}
        if strings.has_prefix(file.name,"Content/") {return "Content/"}
        if at:=strings.index(file.name,"/Content/");at>=0 {return file.name[:at+len("/Content/")]}
    }
    return "Content/"
}

// Where file of the build is in the staging folder.
build_staged :: proc(b:^Build,file:int,allocator:=context.allocator) -> string {
    return path_join({b.staging,"files",b.manifest.files[file].name},allocator)
}

// Downloads the files of the build marked in wanted that were not yet.
build_fetch_files :: proc(b:^Build,wanted:[]int) -> (problem:string) {
    if b.fetched==nil {
        b.fetched=make([]bool,len(b.manifest.files))
        b.held=make([]bool,len(b.manifest.chunks))
    }
    files:=make([dynamic]int,context.temp_allocator)
    for f in wanted {if f>=0 && f<len(b.fetched) && !b.fetched[f] {b.fetched[f]=true;append(&files,f)}}
    if len(files)==0 {return ""}
    m:=&b.manifest
    chunks:=make([dynamic]int,context.temp_allocator)
    seen:=make([]bool,len(m.chunks),context.temp_allocator)
    window:u32
    for f in files {
        for part in m.parts[m.files[f].first:][:m.files[f].count] {
            window=max(window,m.chunks[part.chunk].window)
            if seen[part.chunk] || b.held[part.chunk] {continue}
            seen[part.chunk]=true
            append(&chunks,part.chunk)
            sync.atomic_add(&b.progress.total,m.chunks[part.chunk].size)
        }
    }
    if window>CHUNK_BYTES_MAX {return fmt.tprintf("the build has chunks of %d bytes, more than the %d this reads",window,CHUNK_BYTES_MAX)}
    for start:=0;start<len(chunks);start+=CHUNKS_PER_FETCH {
        if sync.atomic_load(&b.progress.cancel) {return "the download was stopped"}
        batch:=chunks[start:min(start+CHUNKS_PER_FETCH,len(chunks))]
        fetches:=make([]Fetch,len(batch),context.temp_allocator)
        for c,i in batch {
            fetches[i]={strings.concatenate({b.base,"/",chunk_path(m,m.chunks[c],context.temp_allocator)},context.temp_allocator),chunk_staged(b,c)}
        }
        if problem=http_fetch(fetches,context.temp_allocator);problem!="" {return}
        for c in batch {
            b.held[c]=true
            sync.atomic_add(&b.progress.bytes,m.chunks[c].size)
        }
    }
    // Each file is written once, part after part, and hashed as it is
    // written; a chunk is decoded again only when the part before was of
    // another one.
    data,data_error:=make([]u8,int(window))
    if data_error!=nil {return "there is no memory for a chunk"}
    defer delete(data)
    current:=-1
    for f in files {
        path:=build_staged(b,f,context.temp_allocator)
        if made:=os.make_directory_all(filepath.dir(path));made!=nil && !os.is_dir(filepath.dir(path)) {return fmt.tprintf("%s cannot be made: %v",filepath.dir(path),made)}
        file,error:=os.open(path,{.Write,.Create,.Trunc})
        if error!=nil {return fmt.tprintf("%s cannot be written: %v",path,error)}
        ctx:sha1.Context
        sha1.init(&ctx)
        problem=""
        for part in m.parts[m.files[f].first:][:m.files[f].count] {
            if part.chunk!=current {
                // Each chunk is held only while it is decoded.
                bytes,read_error:=os.read_entire_file(chunk_staged(b,part.chunk),context.allocator)
                if read_error!=nil {problem=fmt.tprintf("a chunk of the build cannot be read: %v",read_error);break}
                _,decode_problem:=chunk_decode(bytes,m.chunks[part.chunk],data)
                delete(bytes)
                if decode_problem!="" {problem=fmt.tprintf("a chunk of the build is wrong: %s",decode_problem);current=-1;break}
                current=part.chunk
            }
            piece:=data[part.offset:][:part.size]
            sha1.update(&ctx,piece)
            if written,write_error:=os.write(file,piece);write_error!=nil || written!=len(piece) {problem=fmt.tprintf("%s cannot be written: %v",path,write_error);break}
        }
        os.close(file)
        if problem!="" {return}
        digest:[20]u8
        sha1.final(&ctx,digest[:])
        if m.files[f].sha!={} && digest!=m.files[f].sha {return fmt.tprintf("%s does not match its hash",m.files[f].name)}
        sync.atomic_add(&b.progress.files,1)
    }
    return ""
}

build_destroy :: proc(b:^Build) {
    if b.staging!="" {base.remove_all(b.staging)}
    manifest_destroy(&b.manifest)
    delete(b.fetched)
    delete(b.held)
}

@(private="file")
chunk_staged :: proc(b:^Build,chunk:int) -> string {
    return path_join({b.staging,"chunks",fmt.tprintf("%d.chunk",chunk)},context.temp_allocator)
}

// The files of an Unreal build that are picked, as packages_walk reads them:
// each round of names is downloaded together.
@(private="file")
walk_files :: proc(data:rawptr,names:[]string,allocator:mem.Allocator) -> (files:[]string,error:importer.Error) {
    b:=(^Build)(data)
    indices:=make([]int,len(names),context.temp_allocator)
    for name,i in names {indices[i]=build_package(b,name)}
    if problem:=build_fetch_files(b,indices);problem!="" {return nil,importer.error_make(.Read,"%s",problem)}
    out:=make([]string,len(names),allocator)
    for f,i in indices {if f>=0 {out[i]=build_staged(b,f,allocator)}}
    return out,{}
}

@(private="file")
walk_under :: proc(data:rawptr,folder:string,allocator:mem.Allocator) -> (files:[]string,error:importer.Error) {
    b:=(^Build)(data)
    prefix:=strings.concatenate({content_root(&b.manifest),folder[len("/Game/"):] if strings.has_prefix(folder,"/Game/") else "","/"},context.temp_allocator)
    if !strings.has_prefix(folder,"/Game/") {return nil,{}}
    indices:=make([dynamic]int,context.temp_allocator)
    for file,i in b.manifest.files {if strings.has_prefix(file.name,prefix) && strings.has_suffix(file.name,".uasset") {append(&indices,i)}}
    if problem:=build_fetch_files(b,indices[:]);problem!="" {return nil,importer.error_make(.Read,"%s",problem)}
    out:=make([]string,len(indices),allocator)
    for f,i in indices {out[i]=build_staged(b,f,allocator)}
    return out,{}
}

// The packages of an Unreal build named in picks, files or folders relative
// to its Content folder, and those they read; with no picks, every file of
// the build. Each goes to the folder of the assets at its path under /Game,
// as a map that is brought does. The files written, relative to folder; the
// picks are first.
unreal_download :: proc(b:^Build,picks:[]string,folder:string,allocator:=context.allocator) -> (written:[]string,problem:string) {
    m:=&b.manifest
    root:=content_root(m)
    staged:[]string
    if len(picks)==0 {
        all:=make([dynamic]int,context.temp_allocator)
        for file,i in m.files {if strings.has_prefix(file.name,root) {append(&all,i)}}
        if problem=build_fetch_files(b,all[:]);problem!="" {return}
        list:=make([dynamic]string,context.temp_allocator)
        for f in all {append(&list,build_staged(b,f,context.temp_allocator))}
        staged=list[:]
    } else {
        names:=make([dynamic]string,context.temp_allocator)
        for pick in picks {
            clean:=strings.trim(pick,"/")
            if !name_safe(clean) {return nil,fmt.aprintf("pick %q is not a path inside the Content folder of the build",pick,allocator=allocator)}
            exact:=-1
            for file,i in m.files {if file.name==strings.concatenate({root,clean},context.temp_allocator) {exact=i;break}}
            under:=strings.concatenate({root,clean,"/"},context.temp_allocator)
            matched:=false
            for file,i in m.files {
                if i!=exact && !strings.has_prefix(file.name,under) {continue}
                extension:=filepath.ext(file.name)
                if extension!=".uasset" && extension!=".umap" {continue}
                append(&names,strings.concatenate({"/Game/",file.name[len(root):len(file.name)-len(extension)]},context.temp_allocator))
                matched=true
            }
            if !matched {return nil,fmt.aprintf("the build has no package %q under its Content folder: list its files to see what it has",pick,allocator=allocator)}
        }
        files,walk_error:=unreal_scene.packages_walk(names[:],{data=b,files=walk_files,under=walk_under},context.temp_allocator)
        if walk_error.code!=.None {return nil,strings.clone(walk_error.message,allocator)}
        staged=files
    }
    out:=make([dynamic]string,0,len(staged),allocator)
    prefix:=path_join({b.staging,"files",root},context.temp_allocator)
    for path in staged {
        relative:=strings.trim_left(path[len(prefix):],"/\\")
        clean,_:=strings.replace_all(relative,"\\","/",context.temp_allocator)
        target:=path_join({folder,clean},context.temp_allocator)
        if problem=file_place(path,target);problem!="" {return out[:],strings.clone(problem,allocator)}
        // Moved away, it is put together again from its chunks if asked again.
        if f:=manifest_file(m,strings.concatenate({root,clean},context.temp_allocator));f>=0 {b.fetched[f]=false}
        append(&out,strings.clone(clean,allocator))
    }
    return out[:],""
}

// A file of another format into folder, unpacked when it is a zip archive:
// the file direct that format_build fetched, or else every file of the build
// of b. The files written, relative to folder.
format_download :: proc(b:^Build,direct,folder:string,allocator:=context.allocator) -> (written:[]string,problem:string) {
    out:=make([dynamic]string,allocator)
    place :: proc(path,name,folder:string,out:^[dynamic]string,allocator:mem.Allocator) -> string {
        if strings.equal_fold(filepath.ext(name),".zip") {
            unpacked,zip_problem:=zip_extract(path,folder,allocator)
            append(out,..unpacked)
            return zip_problem
        }
        if problem:=file_place(path,path_join({folder,name},context.temp_allocator));problem!="" {return strings.clone(problem,allocator)}
        append(out,strings.clone(name,allocator))
        return ""
    }
    if direct!="" {
        problem=place(direct,filepath.base(direct),folder,&out,allocator)
        return out[:],problem
    }
    all:=make([]int,len(b.manifest.files),context.temp_allocator)
    for &f,i in all {f=i}
    if problem=build_fetch_files(b,all);problem!="" {return}
    for f in all {
        if problem=place(build_staged(b,f,context.temp_allocator),b.manifest.files[f].name,folder,&out,allocator);problem!="" {return out[:],problem}
        b.fetched[f]=false
    }
    return out[:],""
}

// Moves the file at path to target, over what was there.
@(private="file")
file_place :: proc(path,target:string) -> string {
    if made:=os.make_directory_all(filepath.dir(target));made!=nil && !os.is_dir(filepath.dir(target)) {return fmt.tprintf("%s cannot be made: %v",filepath.dir(target),made)}
    if os.exists(target) {_=os.remove(target)}
    renamed:=os.rename(path,target)
    if renamed==nil {return ""}
    if error:=os.copy_file(target,path);error!=nil {return fmt.tprintf("%s cannot be written: %v",target,error)}
    return ""
}
