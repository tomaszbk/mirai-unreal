package fixture

import "core:encoding/endian"
import unreal "project:plugins/unreal/editor/package"

// Synthetic Unreal editor packages for the tests of the readers of
// the unreal plugin: tables, tagged properties and native tails as UE4 (version
// 503 or later) saves them, held in a Package without a file summary.
// Everything lives in the temp allocator.

Builder :: struct {
    names:[dynamic]string,
    imports:[dynamic]unreal.Object_Import,
    exports:[dynamic]unreal.Object_Export,
    versions:[dynamic]unreal.Custom_Version,
    bytes:[dynamic]u8,
    version_ue4:i32,
    open:int, // the export being written, or -1
}

builder_make :: proc(version_ue4:i32=522) -> (b:Builder) {
    b.names.allocator=context.temp_allocator
    b.imports.allocator=context.temp_allocator
    b.exports.allocator=context.temp_allocator
    b.versions.allocator=context.temp_allocator
    b.bytes.allocator=context.temp_allocator
    b.version_ue4=version_ue4
    b.open=-1
    name(&b,"None")
    // Nothing of an export starts at offset zero.
    append(&b.bytes,0,0,0,0)
    return
}

name :: proc(b:^Builder,text:string) -> unreal.Name_Ref {
    for held,i in b.names {if held==text {return {i32(i),0}}}
    append(&b.names,text)
    return {i32(len(b.names)-1),0}
}

custom_version :: proc(b:^Builder,words:[4]u32,version:i32) {
    append(&b.versions,unreal.Custom_Version{guid=unreal.guid_from_words(words),version=version})
}

// A package that imports name from outside: /Script/Engine and the like.
package_import :: proc(b:^Builder,package_name:string) -> unreal.Object_Ref {
    for item,i in b.imports {
        if item.outer==0 && b.names[item.object_name.index]==package_name {return unreal.Object_Ref(-(i+1))}
    }
    append(&b.imports,unreal.Object_Import{class_package=name(b,"/Script/CoreUObject"),class_name=name(b,"Package"),object_name=name(b,package_name),package_name=name(b,"None")})
    return unreal.Object_Ref(-len(b.imports))
}

// An object of another package, under outer (an import).
object_import :: proc(b:^Builder,outer:unreal.Object_Ref,class_package,class,object:string) -> unreal.Object_Ref {
    for item,i in b.imports {
        if item.outer==outer && b.names[item.object_name.index]==object && b.names[item.class_name.index]==class {return unreal.Object_Ref(-(i+1))}
    }
    append(&b.imports,unreal.Object_Import{class_package=name(b,class_package),class_name=name(b,class),outer=outer,object_name=name(b,object),package_name=name(b,"None")})
    return unreal.Object_Ref(-len(b.imports))
}

// The class `class` of a script package such as /Script/Engine.
class_import :: proc(b:^Builder,package_name,class:string) -> unreal.Object_Ref {
    return object_import(b,package_import(b,package_name),"/Script/CoreUObject","Class",class)
}

// Starts an export; its tagged properties follow, then export_end.
export_begin :: proc(b:^Builder,class,outer:unreal.Object_Ref,object:string,template:unreal.Object_Ref=0,flags:u32=0) -> unreal.Object_Ref {
    assert(b.open<0)
    append(&b.exports,unreal.Object_Export{class=class,outer=outer,template=template,object_name=name(b,object),object_flags=flags})
    b.open=len(b.exports)-1
    b.exports[b.open].data.offset=i64(len(b.bytes))
    return unreal.Object_Ref(len(b.exports))
}

// Ends the tagged properties of the export; what follows is its native tail.
properties_end :: proc(b:^Builder) {put_name(b,"None")}

export_end :: proc(b:^Builder) {
    item:=&b.exports[b.open]
    item.data.size=i64(len(b.bytes))-item.data.offset
    b.open=-1
}

put_u8 :: proc(b:^Builder,value:u8) {append(&b.bytes,value)}
put_u32 :: proc(b:^Builder,value:u32) {for i in 0..<4 {append(&b.bytes,u8(value>>uint(i*8)))}}
put_i32 :: proc(b:^Builder,value:i32) {put_u32(b,transmute(u32)value)}
put_u64 :: proc(b:^Builder,value:u64) {put_u32(b,u32(value));put_u32(b,u32(value>>32))}
put_f32 :: proc(b:^Builder,value:f32) {put_u32(b,transmute(u32)value)}
put_f64 :: proc(b:^Builder,value:f64) {put_u64(b,transmute(u64)value)}
put_guid :: proc(b:^Builder,guid:unreal.Guid) {g:=guid;append(&b.bytes,..g[:])}
put_name :: proc(b:^Builder,text:string) {n:=name(b,text);put_i32(b,n.index);put_i32(b,n.number)}
put_ref :: proc(b:^Builder,ref:unreal.Object_Ref) {put_i32(b,i32(ref))}
put_text :: proc(b:^Builder,text:string) {
    if text=="" {put_u32(b,0);return}
    put_u32(b,u32(len(text)+1))
    append(&b.bytes,..transmute([]u8)text)
    append(&b.bytes,0)
}
put_vec3 :: proc(b:^Builder,v:[3]f32) {for c in v {put_f32(b,c)}}

patch_u32 :: proc(b:^Builder,at:int,value:u32) {endian.put_u32(b.bytes[at:],.Little,value)}

// A property tag; the size is patched by tag_end. extra is the struct, enum
// or inner type name, or "true" for a true BoolProperty.
tag_begin :: proc(b:^Builder,property,type:string,extra:="") -> (size_at:int) {
    put_name(b,property)
    put_name(b,type)
    size_at=len(b.bytes)
    put_u32(b,0)
    put_u32(b,0)
    switch type {
    case "StructProperty":put_name(b,extra);put_guid(b,{})
    case "BoolProperty":put_u8(b,extra=="true"?1:0)
    case "ByteProperty","EnumProperty","ArrayProperty":put_name(b,extra=="" ? "None" : extra)
    }
    put_u8(b,0)
    return
}

tag_end :: proc(b:^Builder,size_at:int) {patch_u32(b,size_at,u32(len(b.bytes)-size_at-8-tag_extra(b,size_at)))}

@(private)
tag_extra :: proc(b:^Builder,size_at:int) -> int {
    type:=b.names[endian.unchecked_get_u32le(b.bytes[size_at-8:])]
    switch type {
    case "StructProperty":return 8+16+1
    case "BoolProperty":return 1+1
    case "ByteProperty","EnumProperty","ArrayProperty":return 8+1
    }
    return 1
}

int_property :: proc(b:^Builder,property:string,value:i32) {at:=tag_begin(b,property,"IntProperty");put_i32(b,value);tag_end(b,at)}
float_property :: proc(b:^Builder,property:string,value:f32) {at:=tag_begin(b,property,"FloatProperty");put_f32(b,value);tag_end(b,at)}
bool_property :: proc(b:^Builder,property:string,value:bool) {at:=tag_begin(b,property,"BoolProperty",value?"true":"false");tag_end(b,at)}
object_property :: proc(b:^Builder,property:string,value:unreal.Object_Ref) {at:=tag_begin(b,property,"ObjectProperty");put_ref(b,value);tag_end(b,at)}
name_property :: proc(b:^Builder,property,value:string) {at:=tag_begin(b,property,"NameProperty");put_name(b,value);tag_end(b,at)}
str_property :: proc(b:^Builder,property,value:string) {at:=tag_begin(b,property,"StrProperty");put_text(b,value);tag_end(b,at)}
byte_property :: proc(b:^Builder,property:string,value:u8) {at:=tag_begin(b,property,"ByteProperty");put_u8(b,value);tag_end(b,at)}
enum_property :: proc(b:^Builder,property,enum_name,value:string) {at:=tag_begin(b,property,"ByteProperty",enum_name);put_name(b,value);tag_end(b,at)}
guid_property :: proc(b:^Builder,property:string,value:unreal.Guid) {at:=tag_begin(b,property,"StructProperty","Guid");put_guid(b,value);tag_end(b,at)}
// Vector, Rotator (pitch, yaw, roll) or another struct of three floats.
vector_property :: proc(b:^Builder,property,struct_name:string,value:[3]f32) {at:=tag_begin(b,property,"StructProperty",struct_name);put_vec3(b,value);tag_end(b,at)}
vector4_property :: proc(b:^Builder,property:string,value:[4]f32) {at:=tag_begin(b,property,"StructProperty","Vector4");for c in value {put_f32(b,c)};tag_end(b,at)}

objects_property :: proc(b:^Builder,property:string,values:[]unreal.Object_Ref) {
    at:=tag_begin(b,property,"ArrayProperty","ObjectProperty")
    put_u32(b,u32(len(values)))
    for v in values {put_ref(b,v)}
    tag_end(b,at)
}

// A tagged struct: its fields follow, then struct_end.
struct_begin :: proc(b:^Builder,property,struct_name:string) -> int {return tag_begin(b,property,"StructProperty",struct_name)}
struct_end :: proc(b:^Builder,at:int) {put_name(b,"None");tag_end(b,at)}

Struct_Array :: struct {tag,inner:int}

// An array of count tagged structs: each element is its fields and element_end.
structs_begin :: proc(b:^Builder,property,struct_name:string,count:int) -> (s:Struct_Array) {
    s.tag=tag_begin(b,property,"ArrayProperty","StructProperty")
    put_u32(b,u32(count))
    s.inner=tag_begin(b,property,"StructProperty",struct_name)
    return
}
element_end :: proc(b:^Builder) {put_name(b,"None")}
structs_end :: proc(b:^Builder,s:Struct_Array) {tag_end(b,s.inner);tag_end(b,s.tag)}

// A Texture2D whose source is width by height BGRA8 pixels (B,G,R,A bytes),
// stored inline as UE4 bulk data.
texture_export :: proc(b:^Builder,outer:unreal.Object_Ref,object:string,width,height:int,bgra:[]u8) -> unreal.Object_Ref {
    assert(len(bgra)==width*height*4)
    ref:=export_begin(b,class_import(b,"/Script/Engine","Texture2D"),outer,object)
    source:=struct_begin(b,"Source","TextureSource")
    int_property(b,"SizeX",i32(width))
    int_property(b,"SizeY",i32(height))
    int_property(b,"NumSlices",1)
    int_property(b,"NumMips",1)
    enum_property(b,"Format","ETextureSourceFormat","TSF_BGRA8")
    struct_end(b,source)
    bool_property(b,"SRGB",false)
    properties_end(b)
    put_u32(b,0)       // no lazy guid
    put_u8(b,0);put_u8(b,0) // strip flags
    put_u32(b,0);put_u32(b,u32(len(bgra)));put_u32(b,u32(len(bgra)))
    put_u64(b,u64(len(b.bytes)+8))
    append(&b.bytes,..bgra)
    export_end(b)
    return ref
}

// The package the builder holds, named source_package.
package_of :: proc(b:^Builder,source_package:string) -> unreal.Package {
    names:=make([]unreal.Name,len(b.names),context.temp_allocator)
    for text,i in b.names {names[i].text=text}
    return unreal.Package{
        bytes=b.bytes[:],
        source_package=source_package,
        summary={version_ue4=b.version_ue4,bulk_data_start=i64(len(b.bytes)),total_header_size=0},
        names=names,
        imports=b.imports[:],
        exports=b.exports[:],
        custom_versions=b.versions[:],
        allocator=context.temp_allocator,
        limits=unreal.DEFAULT_LIMITS,
    }
}
