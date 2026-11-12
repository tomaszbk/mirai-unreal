package material_fixture

import "core:encoding/endian"
import "core:mem"

// Synthetic UE4 editor packages (UE4 522, Core 4 and Framework 37 custom
// versions, so material inputs are native) for the tests of the material
// translation. Names are added as they are used; refs follow Unreal: an
// import is -(row+1), an export row+1.

Import :: struct {class_package,class,object:string,outer:i32}

Export :: struct {class,outer:i32,name:string,data:[]u8}

Package :: struct {
    names:[dynamic]string,
    imports:[dynamic]Import,
    exports:[dynamic]Export,
    core_version:i32, // 0 leaves material inputs tagged, as before UE4 4.17
    allocator:mem.Allocator,
}

package_make :: proc(allocator:=context.temp_allocator) -> (p:Package) {
    p.allocator=allocator
    p.names.allocator=allocator
    p.imports.allocator=allocator
    p.exports.allocator=allocator
    p.core_version=4
    name(&p,"None")
    return
}

name :: proc(p:^Package,text:string) -> u32 {
    for existing,i in p.names {if existing==text {return u32(i)}}
    append(&p.names,text)
    return u32(len(p.names)-1)
}

// The class of /Script/<module> named class, as an import.
class :: proc(p:^Package,module,class:string) -> i32 {
    script:=-1
    for item,i in p.imports {if item.object==module && item.class=="Package" {script=i;break}}
    if script<0 {
        append(&p.imports,Import{"/Script/CoreUObject","Package",module,0})
        script=len(p.imports)-1
    }
    for item,i in p.imports {if item.object==class && item.outer==-i32(script+1) {return -i32(i+1)}}
    append(&p.imports,Import{"/Script/CoreUObject","Class",class,-i32(script+1)})
    return -i32(len(p.imports))
}

// An object of another package: its package import and the object in it.
external :: proc(p:^Package,package_name,class_package,class,object:string) -> i32 {
    outer:=-1
    for item,i in p.imports {if item.object==package_name && item.class=="Package" {outer=i;break}}
    if outer<0 {
        append(&p.imports,Import{"/Script/CoreUObject","Package",package_name,0})
        outer=len(p.imports)-1
    }
    append(&p.imports,Import{class_package,class,object,-i32(outer+1)})
    return -i32(len(p.imports))
}

export :: proc(p:^Package,class:i32,outer:i32,object:string,properties:[]u8) -> i32 {
    append(&p.exports,Export{class,outer,object,properties})
    return i32(len(p.exports))
}

Writer :: struct {p:^Package,bytes:[dynamic]u8}

writer :: proc(p:^Package) -> Writer {return {p,make([dynamic]u8,p.allocator)}}

u32_put :: proc(w:^Writer,value:u32) {for i in 0..<4 {append(&w.bytes,u8(value>>uint(i*8)))}}
i32_put :: proc(w:^Writer,value:i32) {u32_put(w,transmute(u32)value)}
f32_put :: proc(w:^Writer,value:f32) {u32_put(w,transmute(u32)value)}
u64_put :: proc(w:^Writer,value:u64) {u32_put(w,u32(value));u32_put(w,u32(value>>32))}
name_put :: proc(w:^Writer,text:string) {u32_put(w,name(w.p,text));u32_put(w,0)}
text_put :: proc(w:^Writer,text:string) {u32_put(w,u32(len(text)+1));append(&w.bytes,..transmute([]u8)text);append(&w.bytes,0)}

// A UE4 property tag; extra is the struct, enum or inner type.
tag_put :: proc(w:^Writer,property,type:string,size:int,extra:="",bool_value:=false) {
    name_put(w,property)
    name_put(w,type)
    u32_put(w,u32(size))
    u32_put(w,0)
    switch type {
    case "StructProperty":name_put(w,extra);for _ in 0..<16 {append(&w.bytes,0)}
    case "ByteProperty","EnumProperty":name_put(w,extra==""?"None":extra)
    case "ArrayProperty":name_put(w,extra)
    case "BoolProperty":append(&w.bytes,bool_value?1:0)
    }
    append(&w.bytes,0)
}

float_put :: proc(w:^Writer,property:string,value:f32) {tag_put(w,property,"FloatProperty",4);f32_put(w,value)}
int_put :: proc(w:^Writer,property:string,value:i32) {tag_put(w,property,"IntProperty",4);i32_put(w,value)}
bool_put :: proc(w:^Writer,property:string,value:bool) {tag_put(w,property,"BoolProperty",0,bool_value=value)}
name_property_put :: proc(w:^Writer,property,value:string) {tag_put(w,property,"NameProperty",8);name_put(w,value)}
enum_put :: proc(w:^Writer,property,enum_type,value:string) {tag_put(w,property,"ByteProperty",8,enum_type);name_put(w,value)}
object_put :: proc(w:^Writer,property:string,reference:i32) {tag_put(w,property,"ObjectProperty",4);i32_put(w,reference)}
string_put :: proc(w:^Writer,property,value:string) {tag_put(w,property,"StrProperty",len(value)+5);text_put(w,value)}
objects_put :: proc(w:^Writer,property:string,references:[]i32) {
    tag_put(w,property,"ArrayProperty",4+4*len(references),"ObjectProperty")
    i32_put(w,i32(len(references)))
    for r in references {i32_put(w,r)}
}
color_put :: proc(w:^Writer,property:string,value:[4]f32) {
    tag_put(w,property,"StructProperty",16,"LinearColor")
    for c in value {f32_put(w,c)}
}
guid_put :: proc(w:^Writer,property:string,value:[16]u8) {
    tag_put(w,property,"StructProperty",16,"Guid")
    value:=value
    append(&w.bytes,..value[:])
}

// A native ExpressionInput, or a material input with its constant (UE4:
// a Color for a color input).
Input :: struct {expression,output:i32,mask:[4]bool,use_constant:bool,constant:[4]f32}

input_put :: proc(w:^Writer,property,kind:string,input:Input) {
    body:=writer(w.p)
    i32_put(&body,input.expression)
    i32_put(&body,input.output)
    name_put(&body,"None")
    masked:=input.mask!={}
    u32_put(&body,masked?1:0)
    for m in input.mask {u32_put(&body,m?1:0)}
    switch kind {
    case "ColorMaterialInput":
        u32_put(&body,input.use_constant?1:0)
        for c in ([4]int{2,1,0,3}) {append(&body.bytes,u8(clamp(input.constant[c],0,1)*255+0.5))}
    case "ScalarMaterialInput":
        u32_put(&body,input.use_constant?1:0)
        f32_put(&body,input.constant.x)
    case "VectorMaterialInput":
        u32_put(&body,input.use_constant?1:0)
        for c in 0..<3 {f32_put(&body,input.constant[c])}
    }
    if w.p.core_version==0 {
        // Before native inputs: a tagged struct.
        tagged:=writer(w.p)
        object_put(&tagged,"Expression",input.expression)
        if input.output!=0 {int_put(&tagged,"OutputIndex",input.output)}
        if masked {
            int_put(&tagged,"Mask",1)
            names:=[4]string{"MaskR","MaskG","MaskB","MaskA"}
            for m,c in input.mask {if m {int_put(&tagged,names[c],1)}}
        }
        name_put(&tagged,"None")
        tag_put(w,property,"StructProperty",len(tagged.bytes),kind)
        append(&w.bytes,..tagged.bytes[:])
        return
    }
    tag_put(w,property,"StructProperty",len(body.bytes),kind)
    append(&w.bytes,..body.bytes[:])
}

// A tagged struct as a property; body ends with its None.
struct_put :: proc(w:^Writer,property,struct_name:string,body:[]u8) {
    tag_put(w,property,"StructProperty",len(body),struct_name)
    append(&w.bytes,..body)
}

// An array of tagged structs, each body ending with its None.
structs_put :: proc(w:^Writer,property,struct_name:string,bodies:[][]u8) {
    inner:=writer(w.p)
    i32_put(&inner,i32(len(bodies)))
    elements:=0
    for b in bodies {elements+=len(b)}
    tag_put(&inner,property,"StructProperty",elements,struct_name)
    for b in bodies {append(&inner.bytes,..b)}
    tag_put(w,property,"ArrayProperty",len(inner.bytes),"StructProperty")
    append(&w.bytes,..inner.bytes[:])
}

// The properties of an export: what w holds, its None, and no lazy guid.
finish :: proc(w:^Writer) -> []u8 {
    name_put(w,"None")
    u32_put(w,0)
    return w.bytes[:]
}

// The end of the tagged properties of a struct.
end :: proc(w:^Writer) -> []u8 {
    name_put(w,"None")
    return w.bytes[:]
}

@(private)
CORE_GUID :: [4]u32{0x375ec13c,0x06e448fb,0xb50084f0,0x262a717e}
@(private)
FRAMEWORK_GUID :: [4]u32{0xcffc743f,0x43b04480,0x939114df,0x171d2073}

// The bytes of the package, named package_name.
package_bytes :: proc(p:^Package,package_name:string) -> []u8 {
    name(p,package_name)
    for item in p.imports {name(p,item.class_package);name(p,item.class);name(p,item.object)}
    for item in p.exports {name(p,item.name)}
    w:=writer(p)
    u32_put(&w,0x9e2a83c1)
    i32_put(&w,-7)
    u32_put(&w,864);u32_put(&w,522);u32_put(&w,0)
    versions:=0 if p.core_version==0 else 2
    u32_put(&w,u32(versions))
    if versions>0 {
        for word in CORE_GUID {u32_put(&w,word)}
        i32_put(&w,p.core_version)
        for word in FRAMEWORK_GUID {u32_put(&w,word)}
        i32_put(&w,37)
    }
    header_at:=len(w.bytes);u32_put(&w,0)
    text_put(&w,package_name)
    u32_put(&w,0)
    u32_put(&w,u32(len(p.names)));name_at:=len(w.bytes);u32_put(&w,0)
    text_put(&w,"")
    u64_put(&w,0)
    u32_put(&w,u32(len(p.exports)));export_at:=len(w.bytes);u32_put(&w,0)
    u32_put(&w,u32(len(p.imports)));import_at:=len(w.bytes);u32_put(&w,0)
    u32_put(&w,0);u64_put(&w,0);u32_put(&w,0);u32_put(&w,0)
    for _ in 0..<32 {append(&w.bytes,0)}
    u32_put(&w,0)
    for _ in 0..<2 {for _ in 0..<10 {append(&w.bytes,0)};text_put(&w,"")}
    u32_put(&w,0);u32_put(&w,0);u32_put(&w,0);u32_put(&w,0)
    u32_put(&w,0);bulk_at:=len(w.bytes);u64_put(&w,0);u32_put(&w,0)
    u32_put(&w,0);u64_put(&w,0)
    endian.put_u32(w.bytes[name_at:],.Little,u32(len(w.bytes)))
    for n in p.names {text_put(&w,n);u32_put(&w,0)}
    endian.put_u32(w.bytes[import_at:],.Little,u32(len(w.bytes)))
    for item in p.imports {
        name_put(&w,item.class_package);name_put(&w,item.class);i32_put(&w,item.outer);name_put(&w,item.object);name_put(&w,"None")
    }
    endian.put_u32(w.bytes[export_at:],.Little,u32(len(w.bytes)))
    size_at:=make([]int,len(p.exports),p.allocator)
    for item,i in p.exports {
        i32_put(&w,item.class);i32_put(&w,0);i32_put(&w,0);i32_put(&w,item.outer)
        name_put(&w,item.name);u32_put(&w,0)
        size_at[i]=len(w.bytes);u64_put(&w,0);u64_put(&w,0)
        for _ in 0..<12 {append(&w.bytes,0)}
        for _ in 0..<16 {append(&w.bytes,0)}
        u32_put(&w,0);u32_put(&w,0);u32_put(&w,item.outer==0?1:0)
        for _ in 0..<20 {append(&w.bytes,0)}
    }
    endian.put_u32(w.bytes[header_at:],.Little,u32(len(w.bytes)))
    for item,i in p.exports {
        endian.put_u64(w.bytes[size_at[i]:],.Little,u64(len(item.data)))
        endian.put_u64(w.bytes[size_at[i]+8:],.Little,u64(len(w.bytes)))
        append(&w.bytes,..item.data)
    }
    endian.put_u64(w.bytes[bulk_at:],.Little,u64(len(w.bytes)))
    return w.bytes[:]
}

// The properties of a texture whose source is slices of pixels in BGRA8, inline.
texture_data :: proc(p:^Package,pixels:[]u8,width,height:int,settings:string,srgb:bool,package_offset:int,slices:=1) -> []u8 {
    w:=writer(p)
    source:=writer(p)
    for field,i in ([4]string{"SizeX","SizeY","NumSlices","NumMips"}) {
        int_put(&source,field,i32(i==0?width:i==1?height:i==2?slices:1))
    }
    enum_put(&source,"Format","ETextureSourceFormat","TSF_BGRA8")
    enum_put(&source,"CompressionFormat","ETextureSourceCompressionFormat","TSCF_None")
    struct_put(&w,"Source","TextureSource",end(&source))
    enum_put(&w,"CompressionSettings","TextureCompressionSettings",settings)
    bool_put(&w,"SRGB",srgb)
    name_put(&w,"None")
    u32_put(&w,0)
    append(&w.bytes,0,0)
    u32_put(&w,0);u32_put(&w,u32(len(pixels)));u32_put(&w,u32(len(pixels)))
    // The payload follows inline; its offset is absolute in the package.
    u64_put(&w,u64(package_offset+len(w.bytes)+8))
    append(&w.bytes,..pixels)
    return w.bytes[:]
}

// A package with one texture of a class (a TextureCube of six slices, its
// faces), its pixels BGRA8 rows from the top.
texture_package :: proc(package_name,object:string,pixels:[]u8,width,height:int,settings:="TC_Default",srgb:=true,allocator:=context.temp_allocator,texture_class:="Texture2D",slices:=1) -> []u8 {
    p:=package_make(allocator)
    p.core_version=0
    class_ref:=class(&p,"/Script/Engine",texture_class)
    export(&p,class_ref,0,object,texture_data(&p,pixels,width,height,settings,srgb,0,slices))
    return package_bytes(&p,package_name)
}
