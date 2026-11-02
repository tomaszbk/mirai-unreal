package fixture_files

import "core:mem"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// Synthetic uncooked Unreal packages for tests: a summary, the tables, the
// exports with tagged properties and their native tails, and payloads in
// bulk data or the trailer. Only what the readers of the unreal plugin need; no
// real asset is in the repository.

Version :: struct {guid:[4]u32,value:i32}

Import :: struct {class_package,class_name,name:string,outer:i32}

// script_end: since UE5 1010, the end of the tagged properties in data, which start it.
Export :: struct {class,outer:i32,name:string,data:[]u8,script_end:int}

Package_Desc :: struct {
    ue5:i32,             // 0: UE4 522 alone
    versions:[]Version,
    package_name:string, // /Game/Meshes/SM_Fixture
}

// Bytes appended after the exports: bulk data at the end of the file, then the trailer.
Writer :: struct {
    desc:Package_Desc,
    names:[dynamic]string,
    name_rows:map[string]int,
    imports:[dynamic]Import,
    exports:[dynamic]Export,
    tail:[dynamic]u8,       // bulk data at the end of the file, offsets relative to its start
    trailer:[dynamic]u8,    // the payloads of the trailer
    trailer_entries:[dynamic]Trailer_Entry,
    allocator:mem.Allocator,
}

Trailer_Entry :: struct {id:[20]u8,offset,size,raw:u64}

writer_make :: proc(desc:Package_Desc,allocator:=context.temp_allocator) -> Writer {
    w:=Writer{desc=desc,allocator=allocator}
    w.names.allocator=allocator;w.name_rows.allocator=allocator;w.imports.allocator=allocator
    w.exports.allocator=allocator;w.tail.allocator=allocator;w.trailer.allocator=allocator
    w.trailer_entries.allocator=allocator
    name(&w,"None")
    return w
}

// The row of a name, added the first time.
name :: proc(w:^Writer,text:string) -> u32 {
    if row,found:=w.name_rows[text];found {return u32(row)}
    w.name_rows[strings.clone(text,w.allocator)]=len(w.names)
    append(&w.names,text)
    return u32(len(w.names)-1)
}

// The object reference of a new import: negative.
import_add :: proc(w:^Writer,item:Import) -> i32 {
    name(w,item.class_package);name(w,item.class_name);name(w,item.name)
    append(&w.imports,item)
    return -i32(len(w.imports))
}

// The object reference of a new export: positive.
export_add :: proc(w:^Writer,item:Export) -> i32 {
    name(w,item.name)
    append(&w.exports,item)
    return i32(len(w.exports))
}

// The class /Script/Engine.<class>, imported once.
engine_class :: proc(w:^Writer,class:string) -> i32 {
    engine:=i32(0)
    for item,i in w.imports {
        if item.name=="/Script/Engine" && item.outer==0 {engine= -i32(i+1)}
        if item.name==class && item.class_name=="Class" {return -i32(i+1)}
    }
    if engine==0 {engine=import_add(w,{"/Script/CoreUObject","Package","/Script/Engine",0})}
    return import_add(w,{"/Script/CoreUObject","Class",class,engine})
}

// A material in its own package: /Game/Materials/M_Rock is the object M_Rock of that package.
material_import :: proc(w:^Writer,package_name:string) -> i32 {
    object:=package_name[strings.last_index_byte(package_name,'/')+1:]
    outer:=import_add(w,{"/Script/CoreUObject","Package",package_name,0})
    return import_add(w,{"/Script/Engine","Material",object,outer})
}

Bytes :: struct {data:[dynamic]u8}

bytes_make :: proc(allocator:=context.temp_allocator) -> Bytes {return {make([dynamic]u8,allocator)}}

put_u8 :: proc(b:^Bytes,value:u8) {append(&b.data,value)}
put_u16 :: proc(b:^Bytes,value:u16) {append(&b.data,u8(value),u8(value>>8))}
put_u32 :: proc(b:^Bytes,value:u32) {for i in 0..<4 {append(&b.data,u8(value>>uint(i*8)))}}
put_i32 :: proc(b:^Bytes,value:i32) {put_u32(b,transmute(u32)value)}
put_u64 :: proc(b:^Bytes,value:u64) {put_u32(b,u32(value));put_u32(b,u32(value>>32))}
put_f32 :: proc(b:^Bytes,value:f32) {put_u32(b,transmute(u32)value)}
put_f64 :: proc(b:^Bytes,value:f64) {put_u64(b,transmute(u64)value)}
put_zeros :: proc(b:^Bytes,count:int) {for _ in 0..<count {append(&b.data,0)}}
put_bytes :: proc(b:^Bytes,bytes:[]u8) {append(&b.data,..bytes)}
put_text :: proc(b:^Bytes,text:string) {
    if text=="" {put_u32(b,0);return}
    put_u32(b,u32(len(text)+1))
    append(&b.data,..transmute([]u8)text)
    append(&b.data,0)
}
put_name :: proc(b:^Bytes,w:^Writer,text:string) {put_u32(b,name(w,text));put_u32(b,0)}
patch_u32 :: proc(b:^Bytes,at:int,value:u32) {for i in 0..<4 {b.data[at+i]=u8(value>>uint(i*8))}}
patch_u64 :: proc(b:^Bytes,at:int,value:u64) {patch_u32(b,at,u32(value));patch_u32(b,at+4,u32(value>>32))}

// Tagged properties as UE4 and UE5 before 1012 write them.
Tag_Extra :: struct {struct_name,inner,value:string,bool_value:bool}

tag :: proc(b:^Bytes,w:^Writer,property,type:string,size:int,extra:Tag_Extra={}) {
    put_name(b,w,property)
    put_name(b,w,type)
    put_u32(b,u32(size))
    put_u32(b,0)
    switch type {
    case "StructProperty":put_name(b,w,extra.struct_name);put_zeros(b,16)
    case "BoolProperty":put_u8(b,extra.bool_value?1:0)
    case "ByteProperty","EnumProperty":put_name(b,w,extra.inner if extra.inner!="" else "None")
    case "ArrayProperty","SetProperty":put_name(b,w,extra.inner)
    case "MapProperty":put_name(b,w,extra.inner);put_name(b,w,extra.value)
    }
    put_u8(b,0)
}

none :: proc(b:^Bytes,w:^Writer) {put_name(b,w,"None")}

int_property :: proc(b:^Bytes,w:^Writer,property:string,value:i32) {tag(b,w,property,"IntProperty",4);put_i32(b,value)}
bool_property :: proc(b:^Bytes,w:^Writer,property:string,value:bool) {tag(b,w,property,"BoolProperty",0,{bool_value=value})}
object_property :: proc(b:^Bytes,w:^Writer,property:string,value:i32) {tag(b,w,property,"ObjectProperty",4);put_i32(b,value)}
name_property :: proc(b:^Bytes,w:^Writer,property,value:string) {tag(b,w,property,"NameProperty",8);put_name(b,w,value)}

vector_property :: proc(b:^Bytes,w:^Writer,property:string,value:[3]f64) {
    wide:=w.desc.ue5>=1004
    tag(b,w,property,"StructProperty",wide?24:12,{struct_name="Vector"})
    for x in value {if wide {put_f64(b,x)} else {put_f32(b,f32(x))}}
}

// A struct property whose fields `inner` holds, ended by None.
struct_property :: proc(b:^Bytes,w:^Writer,property,struct_name:string,inner:^Bytes) {
    none(inner,w)
    tag(b,w,property,"StructProperty",len(inner.data),{struct_name=struct_name})
    put_bytes(b,inner.data[:])
}

// An array of tagged structs, each of `items` ended by None.
struct_array_property :: proc(b:^Bytes,w:^Writer,property,struct_name:string,items:[]Bytes) {
    elements:=bytes_make()
    for &item in items {
        none(&item,w)
        put_bytes(&elements,item.data[:])
    }
    inner:=bytes_make()
    tag(&inner,w,property,"StructProperty",len(elements.data),{struct_name=struct_name})
    tag(b,w,property,"ArrayProperty",4+len(inner.data)+len(elements.data),{inner="StructProperty"})
    put_u32(b,u32(len(items)))
    put_bytes(b,inner.data[:])
    put_bytes(b,elements.data[:])
}

// FByteBulkData of UE4 with its bytes at the end of the file; zlib with zlib_chunks.
byte_bulk_data :: proc(b:^Bytes,w:^Writer,raw_size:int,stored:[]u8,zlib:bool) {
    put_u32(b,1|(zlib?2:0))
    put_i32(b,i32(raw_size))
    put_i32(b,i32(len(stored)))
    put_u64(b,u64(len(w.tail)))
    append(&w.tail,..stored)
}

// FEditorBulkData in the trailer, raw: an FCompressedBuffer without compression.
editor_bulk_data :: proc(b:^Bytes,w:^Writer,raw:[]u8) {
    buffer:=compressed_buffer_none(raw)
    hash:=unreal.blake3(raw)
    put_u32(b,1<<9)
    put_zeros(b,16)
    put_bytes(b,hash[:20])
    put_u64(b,u64(len(raw)))
    if len(raw)==0 {return}
    entry:=Trailer_Entry{offset=u64(len(w.trailer)),size=u64(len(buffer)),raw=u64(len(raw))}
    copy(entry.id[:],hash[:20])
    append(&w.trailer_entries,entry)
    append(&w.trailer,..buffer)
}
