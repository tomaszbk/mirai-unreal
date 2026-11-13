package fab

import "core:fmt"
import "core:hash"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import fixture "project:plugins/unreal/editor/fixture/files"
import "mirai:std/base"

// A build as the content service lays it out, served from a folder with
// file:// so that a download runs without the network: a manifest and its
// chunks. Every file is a chunk of its own but the two smallest, which share
// one, and the first chunk is deflated.
@(private="file")
Build_File :: struct {name:string,data:[]u8}

@(private="file")
HELLO_ZLIB :: [?]u8{0x78,0x9c,0xcb,0x48,0xcd,0xc9,0xc9,0x07,0x00,0x06,0x2c,0x02,0x15}

@(private="file")
put32 :: proc(b:^[dynamic]u8,v:u32) {append(b,u8(v),u8(v>>8),u8(v>>16),u8(v>>24))}
@(private="file")
put64 :: proc(b:^[dynamic]u8,v:u64) {put32(b,u32(v));put32(b,u32(v>>32))}
@(private="file")
put_text :: proc(b:^[dynamic]u8,s:string) {
    if s=="" {put32(b,0);return}
    put32(b,u32(len(s)+1));append(b,..transmute([]u8)s);append(b,0)
}
@(private="file")
section_end :: proc(b:^[dynamic]u8,start:int) {
    size:=u32(len(b)-start)
    b[start],b[start+1],b[start+2],b[start+3]=u8(size),u8(size>>8),u8(size>>16),u8(size>>24)
}

// Writes the build of files under folder: its manifest at build.manifest and
// its chunks; the first file is "hello" so that its chunk can be deflated.
@(private="file")
build_write :: proc(folder:string,files:[]Build_File) -> []u8 {
    Chunk :: struct {data:[]u8,stored:[]u8,deflated:bool}
    context.allocator=context.temp_allocator
    chunks:=make([dynamic]Chunk,context.temp_allocator)
    Part :: struct {chunk,offset,size:int}
    parts:=make([][]Part,len(files),context.temp_allocator)
    shared:[dynamic]u8
    shared_at:=-1
    for f,i in files {
        if i==0 {
            hello:=HELLO_ZLIB
            append(&chunks,Chunk{f.data,slice.clone(hello[:],context.temp_allocator),true})
            parts[i]=slice.clone([]Part{{len(chunks)-1,0,len(f.data)}},context.temp_allocator)
            continue
        }
        if len(f.data)<64 {
            if shared_at<0 {append(&chunks,Chunk{});shared_at=len(chunks)-1}
            parts[i]=slice.clone([]Part{{shared_at,len(shared),len(f.data)}},context.temp_allocator)
            append(&shared,..f.data)
            continue
        }
        append(&chunks,Chunk{f.data,f.data,false})
        parts[i]=slice.clone([]Part{{len(chunks)-1,0,len(f.data)}},context.temp_allocator)
    }
    if shared_at>=0 {chunks[shared_at]={shared[:],shared[:],false}}
    body:[dynamic]u8
    start:=len(body);put32(&body,0);append(&body,0);put32(&body,18);section_end(&body,start)
    start=len(body);put32(&body,0);append(&body,0);put32(&body,u32(len(chunks)))
    guid :: proc(i:int) -> [16]u8 {g:[16]u8;g[0]=u8(i+1);g[15]=0xab;return g}
    for _,i in chunks {g:=guid(i);append(&body,..g[:])}
    for _,i in chunks {put64(&body,u64(0x1000+i))}
    for c in chunks {d:[20]u8;sha_of(c.data,d[:]);append(&body,..d[:])}
    for _,i in chunks {append(&body,u8(i%3))}
    for c in chunks {put32(&body,u32(len(c.data)))}
    for c in chunks {put64(&body,u64(len(c.stored)+66))}
    section_end(&body,start)
    start=len(body);put32(&body,0);append(&body,0);put32(&body,u32(len(files)))
    for f in files {put_text(&body,f.name)}
    for _ in files {put_text(&body,"")}
    for f in files {d:[20]u8;sha_of(f.data,d[:]);append(&body,..d[:])}
    for _ in files {append(&body,0)}
    for _ in files {put32(&body,0)}
    for ps in parts {
        put32(&body,u32(len(ps)))
        for p in ps {put32(&body,28);g:=guid(p.chunk);append(&body,..g[:]);put32(&body,u32(p.offset));put32(&body,u32(p.size))}
    }
    section_end(&body,start)
    start=len(body);put32(&body,0);append(&body,0);put32(&body,1);put_text(&body,"BuildLabel");put_text(&body,"Test");section_end(&body,start)
    manifest:[dynamic]u8
    put32(&manifest,MANIFEST_MAGIC);put32(&manifest,41);put32(&manifest,u32(len(body)));put32(&manifest,u32(len(body)))
    d:[20]u8;sha_of(body[:],d[:]);append(&manifest,..d[:])
    append(&manifest,0);put32(&manifest,0)
    append(&manifest,..body[:])
    m,problem:=manifest_parse(manifest[:],context.temp_allocator)
    assert(problem=="",problem)
    for c,i in chunks {
        file:[dynamic]u8
        put32(&file,CHUNK_MAGIC);put32(&file,3);put32(&file,66);put32(&file,u32(len(c.stored)))
        g:=guid(i);append(&file,..g[:]);put64(&file,u64(0x1000+i));append(&file,1 if c.deflated else 0)
        cd:[20]u8;sha_of(c.data,cd[:]);append(&file,..cd[:]);append(&file,2)
        put32(&file,u32(len(c.data)))
        append(&file,..c.stored)
        path:=path_join({folder,chunk_path(&m,m.chunks[i],context.temp_allocator)},context.temp_allocator)
        _=os.make_directory_all(filepath.dir(path))
        _=os.write_entire_file(path,file[:])
    }
    return manifest[:]
}

@(private="file")
file_url :: proc(folder:string) -> string {
    clean,_:=strings.replace_all(folder,"\\","/",context.temp_allocator)
    return fmt.tprintf("file:///%s",strings.trim_left(clean,"/"))
}

@(private="file")
temp_folder :: proc(name:string) -> string {
    folder,_:=os.make_directory_temp("",fmt.tprintf("mirai-fab-%s-*",name),context.temp_allocator)
    return folder
}

// A pick of a map brings the packages it reads and nothing else: the round
// of names of the walk is what is downloaded, checked against its hashes.
@(test)
a_picked_map_downloads_only_itself_and_what_it_reads :: proc(t:^testing.T) {
    l:=fixture.level_begin("/Game/Maps/Demo")
    append(&l.w.soft_packages,"/Game/Meshes/SM_Soft")
    fixture.package_object(&l.w,"/Game/Meshes/SM_Rock","/Script/Engine","StaticMesh","SM_Rock")
    fixture.package_object(&l.w,"/Game/Maps/Demo_BuiltData","/Script/Engine","MapBuildDataRegistry","Demo_BuiltData")
    other:=fixture.level_begin("/Game/Meshes/SM_Rock")
    soft:=fixture.level_begin("/Game/Meshes/SM_Soft")
    unused:=fixture.level_begin("/Game/Meshes/SM_Unused")
    files:=[]Build_File{
        {"Pack/readme.txt",transmute([]u8)string("hello")},
        {"Pack/Content/Maps/Demo.umap",fixture.level_bytes(&l)},
        {"Pack/Content/Meshes/SM_Rock.uasset",fixture.level_bytes(&other)},
        {"Pack/Content/Meshes/SM_Soft.uasset",fixture.level_bytes(&soft)},
        {"Pack/Content/Meshes/SM_Unused.uasset",fixture.level_bytes(&unused)},
        {"Pack/Content/Maps/Demo_BuiltData.uasset",fixture.level_bytes(&unused)},
        {"Pack/Content/Notes/tiny.txt",transmute([]u8)string("a")},
        {"Pack/Content/Notes/small.txt",transmute([]u8)string("bc")},
    }
    served:=temp_folder("served")
    defer base.remove_all(served)
    target:=temp_folder("target")
    defer base.remove_all(target)
    bytes:=build_write(served,files)
    progress:Progress
    b:=Build{base=file_url(served),staging=temp_folder("staging"),progress=&progress}
    problem:string
    b.manifest,problem=manifest_parse(bytes)
    if !testing.expect_value(t,problem,"") {return}
    defer build_destroy(&b)
    testing.expect_value(t,content_root(&b.manifest),"Pack/Content/")
    testing.expect_value(t,manifest_field(&b.manifest,"BuildLabel"),"Test")
    written,download_problem:=unreal_download(&b,{"Maps/Demo.umap"},target,context.temp_allocator)
    if !testing.expectf(t,download_problem=="","%s",download_problem) {return}
    slice.sort(written)
    testing.expect(t,slice.equal(written,[]string{"Maps/Demo.umap","Meshes/SM_Rock.uasset","Meshes/SM_Soft.uasset"}),fmt.tprint(written))
    for f in written {
        got,_:=os.read_entire_file(path_join({target,f},context.temp_allocator),context.temp_allocator)
        want:[]u8
        for file in files {if file.name==strings.concatenate({"Pack/Content/",f},context.temp_allocator) {want=file.data}}
        testing.expectf(t,slice.equal(got,want),"%s is the file of the build",f)
    }
    testing.expect_value(t,progress.files,3)

    // The whole build, with what is not a package and the files of a shared
    // chunk; the files moved out are put together again from the chunks it
    // holds, which are not fetched again.
    all,all_problem:=unreal_download(&b,{},target,context.temp_allocator)
    if !testing.expectf(t,all_problem=="","%s",all_problem) {return}
    testing.expect_value(t,len(all),len(files)-1)
    tiny,_:=os.read_entire_file(path_join({target,"Notes/small.txt"},context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(tiny),"bc")
    testing.expect_value(t,progress.files,i64(3+len(files)-1))
    chunks:i64
    for c,i in b.manifest.chunks {if i>0 {chunks+=c.size}}
    testing.expect_value(t,progress.total,chunks)

    missing,missing_problem:=unreal_download(&b,{"Maps/Nothing.umap"},target,context.temp_allocator)
    testing.expect(t,missing==nil && strings.contains(missing_problem,"no package"),missing_problem)
    _,escape_problem:=unreal_download(&b,{"../Maps/Demo.umap"},target,context.temp_allocator)
    testing.expect(t,strings.contains(escape_problem,"not a path inside"),escape_problem)
}

// The deflated chunk inflates, a chunk of another guid or cut short is
// refused, and a manifest of random bytes or cut anywhere is refused without
// a crash.
@(test)
a_manifest_or_a_chunk_that_is_wrong_is_refused :: proc(t:^testing.T) {
    served:=temp_folder("hostile")
    defer base.remove_all(served)
    bytes:=build_write(served,{{"Content/a.txt",transmute([]u8)string("hello")},{"Content/b.txt",transmute([]u8)string("bye")}})
    m,problem:=manifest_parse(bytes,context.temp_allocator)
    if !testing.expect_value(t,problem,"") {return}
    chunk,_:=os.read_entire_file(path_join({served,chunk_path(&m,m.chunks[0],context.temp_allocator)},context.temp_allocator),context.temp_allocator)
    out:[16]u8
    size,decode_problem:=chunk_decode(chunk,m.chunks[0],out[:])
    testing.expect(t,decode_problem=="" && string(out[:size])=="hello",decode_problem)
    _,other:=chunk_decode(chunk,m.chunks[1],out[:])
    testing.expect_value(t,other,"it is another chunk")
    for cut in 0..<len(chunk) {
        _,cut_problem:=chunk_decode(chunk[:cut],m.chunks[0],out[:])
        testing.expectf(t,cut_problem!="","a chunk cut at %d is refused",cut)
    }
    for cut in 0..<len(bytes) {
        _,cut_problem:=manifest_parse(bytes[:cut],context.temp_allocator)
        testing.expectf(t,cut_problem!="","a manifest cut at %d is refused",cut)
    }
    noise:=make([]u8,len(bytes),context.temp_allocator)
    for round in 0..<200 {
        copy(noise,bytes)
        for _ in 0..<1+round%8 {noise[rand.int_max(len(noise))]=u8(rand.uint32())}
        if n,noise_problem:=manifest_parse(noise,context.temp_allocator);noise_problem=="" {
            for file in n.files {testing.expect(t,name_safe(file.name))}
        }
    }
}

// Names that leave the folder they are written to are refused.
@(test)
a_name_out_of_its_folder_is_not_safe :: proc(t:^testing.T) {
    cases:=[?]struct {name:string,safe:bool}{
        {"Content/A.uasset",true},{"a/b/c",true},{"",false},{"/abs",false},{"../up",false},
        {"a/../b",false},{"a//b",false},{"a/./b",false},{"C:/x",false},{"a\\b",false},{"a/",false},
    }
    for c in cases {testing.expectf(t,name_safe(c.name)==c.safe,"%q",c.name)}
}

// An archive of a stored and a deflated file unpacks into its folder; one
// whose names go out of it, or whose checksum is wrong, is refused.
@(test)
a_zip_unpacks_stored_and_deflated_files :: proc(t:^testing.T) {
    Entry :: struct {name:string,data,packed:[]u8,method:u16}
    zip :: proc(entries:[]Entry) -> []u8 {
        out:=make([dynamic]u8,context.temp_allocator)
        locals:=make([]int,len(entries),context.temp_allocator)
        put16 :: proc(b:^[dynamic]u8,v:u16) {append(b,u8(v),u8(v>>8))}
        for e,i in entries {
            locals[i]=len(out)
            put32(&out,0x04034b50);put16(&out,20);put16(&out,0);put16(&out,e.method);put32(&out,0)
            put32(&out,hash.crc32(e.data));put32(&out,u32(len(e.packed)));put32(&out,u32(len(e.data)))
            put16(&out,u16(len(e.name)));put16(&out,0);append(&out,..transmute([]u8)e.name);append(&out,..e.packed)
        }
        directory:=len(out)
        for e,i in entries {
            put32(&out,0x02014b50);put16(&out,20);put16(&out,20);put16(&out,0);put16(&out,e.method);put32(&out,0)
            put32(&out,hash.crc32(e.data));put32(&out,u32(len(e.packed)));put32(&out,u32(len(e.data)))
            put16(&out,u16(len(e.name)));put16(&out,0);put16(&out,0);put16(&out,0);put16(&out,0);put32(&out,0);put32(&out,u32(locals[i]))
            append(&out,..transmute([]u8)e.name)
        }
        size:=len(out)-directory
        put32(&out,0x06054b50);put16(&out,0);put16(&out,0);put16(&out,u16(len(entries)));put16(&out,u16(len(entries)))
        put32(&out,u32(size));put32(&out,u32(directory));put16(&out,0)
        return out[:]
    }
    hello:=transmute([]u8)string("hello")
    raw:=HELLO_ZLIB
    folder:=temp_folder("zip")
    defer base.remove_all(folder)
    archive:=path_join({folder,"a.zip"},context.temp_allocator)
    out:=path_join({folder,"out"},context.temp_allocator)
    _=os.write_entire_file(archive,zip({{"model/rock.glb",hello,hello,0},{"model/textures/",nil,nil,0},{"model/rock.txt",hello,raw[2:len(raw)-4],8}}))
    written,problem:=zip_extract(archive,out,context.temp_allocator)
    testing.expectf(t,problem=="" && len(written)==2,"%s %v",problem,written)
    for name in written {
        got,_:=os.read_entire_file(path_join({out,name},context.temp_allocator),context.temp_allocator)
        testing.expect_value(t,string(got),"hello")
    }
    _=os.write_entire_file(archive,zip({{"../evil.txt",hello,hello,0}}))
    _,evil:=zip_extract(archive,out,context.temp_allocator)
    testing.expect(t,strings.contains(evil,"goes out of"),evil)
    testing.expect(t,!os.exists(path_join({folder,"evil.txt"},context.temp_allocator)))
    wrong:=zip({{"bad.txt",hello,transmute([]u8)string("jello"),0}})
    _=os.write_entire_file(archive,wrong)
    _,bad:=zip_extract(archive,out,context.temp_allocator)
    testing.expect(t,strings.contains(bad,"checksum"),bad)
    for cut in 0..<len(wrong) {
        _=os.write_entire_file(archive,wrong[:cut])
        _,cut_problem:=zip_extract(archive,out,context.temp_allocator)
        testing.expectf(t,cut_problem!="","an archive cut at %d is refused",cut)
    }
}

// The identifier of a listing is taken from its address.
@(test)
a_listing_is_named_by_its_address_or_identifier :: proc(t:^testing.T) {
    testing.expect_value(t,uid_from_text(" https://www.fab.com/listings/66f241e5-43fa-47c0-a475-07b2d1391f7e?x=1 "),"66f241e5-43fa-47c0-a475-07b2d1391f7e")
    testing.expect_value(t,uid_from_text("66f241e5-43fa-47c0-a475-07b2d1391f7e"),"66f241e5-43fa-47c0-a475-07b2d1391f7e")
    testing.expect(t,!uid_valid("../x"))
}
