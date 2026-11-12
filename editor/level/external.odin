package level

import "core:crypto/legacy/md5"
import "core:encoding/endian"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf16"
import unreal "project:plugins/unreal/editor/package"

// A level with bUseExternalActors keeps each actor in a package of its own
// under /<mount>/__ExternalActors__/<path of the map>/, whose actor has the
// level (an import named PersistentLevel) as its outer. Two packages can hold
// an actor of the same path (one left behind when an actor moved between
// packages); Unreal loads one: the package named by the hash of that path
// or, when neither is, the first by name.
@(private)
external_actors_read :: proc(d:^Document,level:int) -> unreal.Error {
    map_name:=d.library.packages[int(d.levels[level].ref.pkg)].name
    if len(d.library.mounts)==0 {return {.Unsupported_Value,0,"the level keeps its actors in __ExternalActors__ packages; give the library the mount of its content"}}
    slash:=strings.index_byte(map_name[1:],'/')
    if slash<0 {return {.Invalid_Reference,0,"map package name"}}
    root,rest:=map_name[:slash+1],map_name[slash+1:]
    external_name:=strings.concatenate({root,"/__ExternalActors__",rest},context.temp_allocator)
    file,error:=unreal.source_package_path(external_name,d.library.mounts,context.temp_allocator)
    if error.code!=.None {return error}
    directory:=file[:len(file)-len(".uasset")]
    if !os.is_dir(directory) {return {}}
    files:[dynamic]string
    files.allocator=context.temp_allocator
    walker:=os.walker_create(directory)
    defer os.walker_destroy(&walker)
    for info in os.walker_walk(&walker) {
        if info.type==.Regular && strings.has_suffix(info.fullpath,".uasset") {append(&files,strings.clone(info.fullpath,context.temp_allocator))}
    }
    slice.sort(files[:])
    External :: struct {index:int,name:string,actors:[]unreal.Object_Ref,left:bool}
    packages:=make([dynamic]External,0,len(files),context.temp_allocator)
    by_path:=make(map[string]int,len(files),context.temp_allocator)
    for path in files {
        name,name_error:=unreal.source_package_name(path,d.library.mounts,context.temp_allocator)
        if name_error.code!=.None {return name_error}
        index,find_error:=library_find(d.library,name)
        if find_error.code!=.None {return find_error}
        p:=library_package(d.library,index)
        actors:[dynamic]unreal.Object_Ref
        actors.allocator=context.temp_allocator
        for item,i in p.exports {
            if item.outer>=0 || !unreal.reference_valid(p,item.outer) {continue}
            outer:=p.imports[int(-i64(item.outer)-1)]
            if unreal.name_plain(p,outer.object_name)=="PersistentLevel" {append(&actors,unreal.Object_Ref(i+1))}
        }
        at:=len(packages)
        append(&packages,External{index=index,name=name,actors=actors[:]})
        for actor in actors {
            object_path,path_error:=actor_path(p,actor)
            if path_error.code!=.None {return path_error}
            key:=strings.to_lower(object_path,context.temp_allocator)
            other,found:=by_path[key]
            if !found {by_path[key]=at;continue}
            keep,left:=other,at
            if external_preferred(packages[at].name,packages[other].name,object_path) {keep,left=at,other}
            packages[left].left=true
            by_path[key]=keep
            append(&d.superseded,Superseded{
                actor=strings.clone(object_path,d.allocator),
                left=strings.clone(packages[left].name,d.allocator),
                kept=strings.clone(packages[keep].name,d.allocator),
            })
        }
    }
    for e in packages {
        if e.left {continue}
        if error:=actors_add(d,level,e.index,e.actors,true);error.code!=.None {return error}
    }
    return {}
}

// /Game/Maps/World.World:PersistentLevel.Actor_0
@(private)
actor_path :: proc(p:^unreal.Package,actor:unreal.Object_Ref) -> (path:string,error:unreal.Error) {
    level_path:string
    level_path,error=unreal.reference_path(p,p.exports[int(actor)-1].outer,context.temp_allocator)
    if error.code!=.None {return}
    return strings.concatenate({level_path,".",unreal.name_text(p,p.exports[int(actor)-1].object_name,context.temp_allocator)},context.temp_allocator),{}
}

// Whether package a, rather than b, is the one loaded for the actor at object_path.
@(private)
external_preferred :: proc(a,b,object_path:string) -> bool {
    hash_a,hash_b:=external_name_matches(a,object_path),external_name_matches(b,object_path)
    if hash_a!=hash_b {return hash_a}
    return strings.compare(strings.to_lower(a,context.temp_allocator),strings.to_lower(b,context.temp_allocator))<0
}

// Whether package_name ends as Unreal names the package of a new actor at
// object_path: the 25 base-36 digits of the MD5 of the lowercase path, as an
// String is saved, split 1/2/22 or 2/2/21.
@(private)
external_name_matches :: proc(package_name,object_path:string) -> bool {
    digits:=actor_package_digits(object_path)
    for first in 1..=2 {
        suffix:=strings.concatenate({"/",digits[:first],"/",digits[first:first+2],"/",digits[first+2:]},context.temp_allocator)
        if len(package_name)>=len(suffix) && strings.equal_fold(package_name[len(package_name)-len(suffix):],suffix) {return true}
    }
    return false
}

@(private)
actor_package_digits :: proc(object_path:string) -> string {
    lower:=strings.to_lower(object_path,context.temp_allocator)
    ascii:=true
    for c in transmute([]u8)lower {if c>=0x80 {ascii=false;break}}
    bytes:[dynamic]u8
    bytes.allocator=context.temp_allocator
    count:[4]u8
    if ascii {
        endian.put_i32(count[:],.Little,i32(len(lower)+1))
        append(&bytes,..count[:])
        append(&bytes,..transmute([]u8)lower)
        append(&bytes,0)
    } else {
        units:=make([]u16,len(lower)*2,context.temp_allocator)
        n:=utf16.encode_string(units,lower)
        endian.put_i32(count[:],.Little,-i32(n+1))
        append(&bytes,..count[:])
        for unit in units[:n] {append(&bytes,u8(unit),u8(unit>>8))}
        append(&bytes,0,0)
    }
    ctx:md5.Context
    md5.init(&ctx)
    md5.update(&ctx,bytes[:])
    digest:[md5.DIGEST_SIZE]u8
    md5.final(&ctx,digest[:])
    value:u128
    for word in 0..<4 {
        part,_:=endian.get_u32(digest[word*4:],.Little)
        value=value<<32|u128(part)
    }
    alphabet:="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    out:=make([]u8,25,context.temp_allocator)
    for i:=24;i>=0;i-=1 {out[i]=alphabet[value%36];value/=36}
    return string(out)
}
