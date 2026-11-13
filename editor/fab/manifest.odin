package fab

import "core:compress/deflate"
import "core:crypto/legacy/sha1"
import "core:fmt"
import "core:mem"
import unreal "project:plugins/unreal/editor/package"

// A build manifest of the Epic content service: the files of a build of a
// listing, each made of parts of chunks that are downloaded on their own.
// Only the files that are wanted need their chunks.

MANIFEST_MAGIC :: 0x44BEC00C
CHUNK_MAGIC :: 0xB1FE3AA2
MANIFEST_BYTES_MAX :: 256<<20 // of a manifest once inflated
CHUNK_BYTES_MAX :: 64<<20     // of the data of one chunk
TEXT_MAX :: 4096              // characters of a name of the manifest

Manifest :: struct {
    version:u32, // of its features: it names the folder of the chunks
    chunks:[]Chunk_Info,
    files:[]File_Entry,
    parts:[]Chunk_Part,  // of all the files, each file a span of them
    fields:[]Field,
    allocator:mem.Allocator,
}

Chunk_Info :: struct {
    guid:unreal.Guid,
    hash:u64,     // rolling hash: part of the name of its file
    sha:[20]u8,   // of its data, zero when the manifest gives none
    group:u8,     // folder of its file
    window:u32,   // bytes of its data
    size:i64,     // bytes of its file
}

File_Entry :: struct {
    name:string,  // relative, with forward slashes
    sha:[20]u8,
    first,count:int, // into Manifest.parts
    size:i64,
}

Chunk_Part :: struct {
    chunk:int,        // into Manifest.chunks
    offset,size:u32,  // within the data of the chunk
    at:i64,           // where it goes in its file
}

Field :: struct {key,value:string}

// The manifest in bytes, binary as the service gives it, in allocator; the
// problem says what is wrong with it otherwise.
manifest_parse :: proc(bytes:[]u8,allocator:=context.allocator) -> (m:Manifest,problem:string) {
    r:=unreal.Reader{bytes=bytes,end=len(bytes)}
    if unreal.u32_read(&r,"magic")!=MANIFEST_MAGIC {return {},"it is not a binary build manifest"}
    header_size:=unreal.u32_read(&r,"header size")
    inflated_size:=unreal.u32_read(&r,"inflated size")
    deflated_size:=unreal.u32_read(&r,"deflated size")
    sha:=unreal.take(&r,20,"sha")
    stored:=unreal.u8_read(&r,"stored as")
    _=unreal.u32_read(&r,"version")
    if r.error.code!=.None {return {},"its header is cut short"}
    if stored&2!=0 {return {},"it is encrypted"}
    if inflated_size>MANIFEST_BYTES_MAX {return {},fmt.aprintf("it says it holds %d bytes, more than the %d a manifest may",inflated_size,MANIFEST_BYTES_MAX,allocator=allocator)}
    if u64(header_size)>u64(len(bytes)) {return {},"its header says it is longer than it is"}
    body:[]u8
    inflated:[dynamic]u8
    if stored&1!=0 {
        if u64(header_size)+u64(deflated_size)>u64(len(bytes)) {return {},"its data is cut short"}
        if deflate.inflate_zlib(&inflated,bytes[header_size:header_size+deflated_size],int(inflated_size),int(inflated_size),context.temp_allocator)!=nil || len(inflated)!=int(inflated_size) {
            return {},"its data does not inflate"
        }
        body=inflated[:]
    } else {
        if u64(header_size)+u64(inflated_size)>u64(len(bytes)) {return {},"its data is cut short"}
        body=bytes[header_size:header_size+inflated_size]
    }
    digest:[20]u8
    sha_of(body,digest[:])
    if mem.compare(digest[:],sha)!=0 {return {},"its data does not match its hash"}
    m.allocator=allocator
    problem=manifest_body(&m,body,allocator)
    if problem!="" {manifest_destroy(&m)}
    return
}

manifest_destroy :: proc(m:^Manifest) {
    for file in m.files {delete(file.name,m.allocator)}
    for field in m.fields {delete(field.key,m.allocator);delete(field.value,m.allocator)}
    delete(m.chunks,m.allocator)
    delete(m.files,m.allocator)
    delete(m.parts,m.allocator)
    delete(m.fields,m.allocator)
    m^={}
}

// The value of a custom field, "" when there is none.
manifest_field :: proc(m:^Manifest,key:string) -> string {
    for field in m.fields {if field.key==key {return field.value}}
    return ""
}

// The index of the file named name, -1 when there is none.
manifest_file :: proc(m:^Manifest,name:string) -> int {
    for file,i in m.files {if file.name==name {return i}}
    return -1
}

// Where the file of chunk is under the folder of the build.
chunk_path :: proc(m:^Manifest,chunk:Chunk_Info,allocator:=context.allocator) -> string {
    folder:="ChunksV4" if m.version>=15 else "ChunksV3" if m.version>=6 else "ChunksV2" if m.version>=3 else "Chunks"
    words:[4]u32
    for &word,i in words {word=u32(chunk.guid[i*4]) | u32(chunk.guid[i*4+1])<<8 | u32(chunk.guid[i*4+2])<<16 | u32(chunk.guid[i*4+3])<<24}
    return fmt.aprintf("%s/%02d/%016X_%08X%08X%08X%08X.chunk",folder,chunk.group,chunk.hash,words[0],words[1],words[2],words[3],allocator=allocator)
}

// The data of the chunk in bytes (a chunk file) into out, which holds its
// window; how many bytes it has, or the problem.
chunk_decode :: proc(bytes:[]u8,chunk:Chunk_Info,out:[]u8) -> (size:int,problem:string) {
    r:=unreal.Reader{bytes=bytes,end=len(bytes)}
    if unreal.u32_read(&r,"magic")!=CHUNK_MAGIC {return 0,"it is not a chunk"}
    version:=unreal.u32_read(&r,"version")
    header_size:=unreal.u32_read(&r,"header size")
    stored_size:=unreal.u32_read(&r,"stored size")
    guid:=unreal.guid_read(&r,"guid")
    _=unreal.i64_read(&r,"hash")
    stored:=unreal.u8_read(&r,"stored as")
    data_size:=chunk.window
    if version>=2 {_=unreal.take(&r,21,"sha")}
    if version>=3 {data_size=unreal.u32_read(&r,"data size")}
    if r.error.code!=.None {return 0,"its header is cut short"}
    if guid!=chunk.guid {return 0,"it is another chunk"}
    if stored&2!=0 {return 0,"it is encrypted"}
    if data_size>CHUNK_BYTES_MAX || int(data_size)>len(out) {return 0,"it is larger than its window"}
    if u64(header_size)+u64(stored_size)>u64(len(bytes)) {return 0,"it is cut short"}
    stored_bytes:=bytes[header_size:header_size+stored_size]
    if stored&1!=0 {
        inflated:=make([dynamic]u8,0,int(data_size))
        defer delete(inflated)
        if deflate.inflate_zlib(&inflated,stored_bytes,int(data_size),int(data_size))!=nil || len(inflated)!=int(data_size) {return 0,"its data does not inflate"}
        copy(out,inflated[:])
    } else {
        if len(stored_bytes)!=int(data_size) {return 0,"its data is not its size"}
        copy(out,stored_bytes)
    }
    if chunk.sha!={} {
        digest:[20]u8
        sha_of(out[:data_size],digest[:])
        if digest!=chunk.sha {return 0,"its data does not match its hash"}
    }
    return int(data_size),""
}

sha_of :: proc(data:[]u8,digest:[]u8) {
    ctx:sha1.Context
    sha1.init(&ctx)
    sha1.update(&ctx,data)
    sha1.final(&ctx,digest)
}

@(private="file")
manifest_body :: proc(m:^Manifest,body:[]u8,allocator:mem.Allocator) -> string {
    r:=unreal.Reader{bytes=body,end=len(body)}
    // Each section says its size: what a later version adds is skipped.
    section :: proc(r:^unreal.Reader,name:string) -> (end:int,version:u8,ok:bool) {
        start:=r.at
        size:=unreal.u32_read(r,name)
        version=unreal.u8_read(r,name)
        if r.error.code!=.None || u64(start)+u64(size)>u64(len(r.bytes)) || int(size)<5 {return}
        return start+int(size),version,true
    }
    // A count of entries of at least least bytes each that fit in what is left.
    count_read :: proc(r:^unreal.Reader,least:int,name:string) -> (count:int,ok:bool) {
        value:=unreal.u32_read(r,name)
        if r.error.code!=.None || u64(value)*u64(least)>u64(r.end-r.at) {return}
        return int(value),true
    }
    text :: proc(r:^unreal.Reader,allocator:mem.Allocator,name:string) -> (out:string,ok:bool) {
        s:=unreal.text_read(r,TEXT_MAX,name)
        if r.error.code!=.None {return}
        decoded,owned,error:=unreal.text_decode(s,allocator)
        if error.code!=.None {return}
        if owned==nil {decoded,_=clone(decoded,allocator)}
        return decoded,true
    }

    end,_,ok:=section(&r,"meta")
    if !ok {return "its meta section is cut short"}
    m.version=unreal.u32_read(&r,"feature level")
    r.at=end

    end,_,ok=section(&r,"chunks")
    if !ok {return "its chunk list is cut short"}
    count:int
    if count,ok=count_read(&r,16+8+20+1+4+8,"chunk count");!ok {return "its chunk count does not fit in it"}
    chunks,chunks_error:=make([]Chunk_Info,count,allocator)
    if chunks_error!=nil {return "there is no memory for its chunks"}
    m.chunks=chunks
    for &c in chunks {c.guid=unreal.guid_read(&r,"chunk guid")}
    for &c in chunks {c.hash=u64(unreal.i64_read(&r,"chunk hash"))}
    for &c in chunks {copy(c.sha[:],unreal.take(&r,20,"chunk sha"))}
    for &c in chunks {c.group=unreal.u8_read(&r,"chunk group")}
    for &c in chunks {c.window=unreal.u32_read(&r,"chunk window")}
    for &c in chunks {c.size=unreal.i64_read(&r,"chunk size")}
    if r.error.code!=.None {return "its chunk list is cut short"}
    r.at=end
    index:=make(map[unreal.Guid]int,len(chunks),context.temp_allocator)
    for c,i in chunks {index[c.guid]=i}

    end,_,ok=section(&r,"files")
    if !ok {return "its file list is cut short"}
    if count,ok=count_read(&r,4+4+20+1+4+4,"file count");!ok {return "its file count does not fit in it"}
    files,files_error:=make([]File_Entry,count,allocator)
    if files_error!=nil {return "there is no memory for its files"}
    m.files=files
    for &f in files {
        if f.name,ok=text(&r,allocator,"file name");!ok {return "a file name of it cannot be read"}
        if !name_safe(f.name) {return fmt.aprintf("its file %q goes out of the folder of the build",f.name,allocator=allocator)}
    }
    for _ in files {_=unreal.text_read(&r,TEXT_MAX,"symlink")}
    for &f in files {copy(f.sha[:],unreal.take(&r,20,"file sha"))}
    for _ in files {_=unreal.u8_read(&r,"file flags")}
    for _ in files {
        tags:int
        if tags,ok=count_read(&r,4,"tag count");!ok {return "its install tags are cut short"}
        for _ in 0..<tags {_=unreal.text_read(&r,TEXT_MAX,"tag")}
    }
    if r.error.code!=.None {return "its file list is cut short"}
    parts:=make([dynamic]Chunk_Part,allocator)
    for &f in files {
        n:int
        if n,ok=count_read(&r,28,"part count");!ok {return "the parts of a file are cut short"}
        f.first=len(parts)
        f.count=n
        for _ in 0..<n {
            start:=r.at
            size:=unreal.u32_read(&r,"part size")
            guid:=unreal.guid_read(&r,"part guid")
            p:=Chunk_Part{offset=unreal.u32_read(&r,"part offset"),size=unreal.u32_read(&r,"part size"),at=f.size}
            if r.error.code!=.None || size<28 || u64(start)+u64(size)>u64(end) {return "the parts of a file are cut short"}
            r.at=start+int(size)
            found:bool
            if p.chunk,found=index[guid];!found {return fmt.aprintf("its file %q names a chunk it does not list",f.name,allocator=allocator)}
            if u64(p.offset)+u64(p.size)>u64(chunks[p.chunk].window) {return fmt.aprintf("its file %q takes more of a chunk than the chunk holds",f.name,allocator=allocator)}
            if _,append_error:=append(&parts,p);append_error!=nil {return "there is no memory for its parts"}
            f.size+=i64(p.size)
        }
    }
    m.parts=parts[:]
    r.at=end

    if r.at>=len(body) {return ""}
    end,_,ok=section(&r,"custom fields")
    if !ok {return "its custom fields are cut short"}
    if count,ok=count_read(&r,8,"field count");!ok {return "its field count does not fit in it"}
    fields,fields_error:=make([]Field,count,allocator)
    if fields_error!=nil {return "there is no memory for its fields"}
    m.fields=fields
    for &f in fields {if f.key,ok=text(&r,allocator,"field key");!ok {return "a field of it cannot be read"}}
    for &f in fields {if f.value,ok=text(&r,allocator,"field value");!ok {return "a field of it cannot be read"}}
    return ""
}

// Whether name stays inside the folder it is written to: relative, without
// empty, . or .. parts, and without a drive or backslashes.
name_safe :: proc(name:string) -> bool {
    if name=="" || name[0]=='/' {return false}
    start:=0
    for i in 0..=len(name) {
        if i<len(name) && name[i]!='/' {
            if name[i]=='\\' || name[i]==':' || name[i]==0 {return false}
            continue
        }
        part:=name[start:i]
        if part=="" || part=="." || part==".." {return false}
        start=i+1
    }
    return true
}

@(private)
clone :: proc(s:string,allocator:mem.Allocator) -> (string,mem.Allocator_Error) {
    bytes,error:=make([]u8,len(s),allocator)
    if error!=nil {return "",error}
    copy(bytes,s)
    return string(bytes),nil
}
