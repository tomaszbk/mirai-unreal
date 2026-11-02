package texture

import "core:mem"
import "core:strings"
import "mirai:asset"
import unreal "project:plugins/unreal/editor/package"

// Texture sources of uncooked Unreal packages. Unreal's names stay here: what
// leaves the package is pixels, their size and what Mirai uses them for
// (color stored as sRGB, linear data or a normal map).

Kind :: enum u8 {Texture_2D,Cube,Array,Cube_Array,Volume}

// ETextureSourceFormat, in Unreal's order.
Source_Format :: enum u8 {Invalid,G8,BGRA8,BGRE8,RGBA16,RGBA16F,RGBA8_Legacy,RGBE8_Legacy,G16,RGBA32F,R16F,R32F}
// ETextureSourceCompressionFormat, in Unreal's order.
Source_Compression :: enum u8 {None,PNG,JPEG,UEJPEG,UEDELTA}

Usage :: enum u8 {
    Color,  // stored as sRGB
    Data,   // linear values: masks, heights, HDR
    Normal, // tangent-space normal map
}

// Where the source pixels are stored in the package: an FCompressedBuffer
// (UE5) or the raw bytes of UE4 bulk data, those optionally in zlib chunks.
Payload_Encoding :: enum u8 {Compressed_Buffer,Raw,Zlib}
Payload :: struct {span:unreal.Span,encoding:Payload_Encoding,raw_size:i64}

// A rectangle of the source (a UDIM tile; one block for ordinary textures).
Block :: struct {x,y,width,height,slices,mips:int,offset:i64}

Texture :: struct {
    object:unreal.Object_Ref,
    kind:Kind,
    layers:[]Source_Format,
    blocks:[]Block,
    compression:Source_Compression,
    usage:Usage,
    keep_precision:bool, // its compression settings store 16 bits or floats as they are (textures.Build_Options)
    long_lat:bool,     // of a cube: each slice is a longitude-latitude image of a whole cube
    flip_green:bool,   // Unreal's bFlipGreenChannel
    legacy_gamma:bool, // sources saved with a 2.2 power curve instead of sRGB
    id:unreal.Guid,    // with id_is_hash, the first 16 bytes of the BLAKE3 of the raw source
    id_is_hash:bool,
    payload:Payload,
    allocator:mem.Allocator,
}

texture_destroy :: proc(texture:^Texture) {
    if texture==nil || texture.allocator.procedure==nil {return}
    delete(texture.layers,texture.allocator)
    delete(texture.blocks,texture.allocator)
    texture^={}
}

@(private)
SOURCE_FORMAT_NAMES :: [Source_Format]string{
    .Invalid="TSF_Invalid",.G8="TSF_G8",.BGRA8="TSF_BGRA8",.BGRE8="TSF_BGRE8",.RGBA16="TSF_RGBA16",.RGBA16F="TSF_RGBA16F",
    .RGBA8_Legacy="TSF_RGBA8_DEPRECATED",.RGBE8_Legacy="TSF_RGBE8_DEPRECATED",.G16="TSF_G16",.RGBA32F="TSF_RGBA32F",.R16F="TSF_R16F",.R32F="TSF_R32F",
}
@(private)
SOURCE_COMPRESSION_NAMES :: [Source_Compression]string{.None="TSCF_None",.PNG="TSCF_PNG",.JPEG="TSCF_JPEG",.UEJPEG="TSCF_UEJPEG",.UEDELTA="TSCF_UEDELTA"}

format_bytes :: proc(format:Source_Format) -> int {
    switch format {
    case .G8:return 1
    case .BGRA8,.BGRE8,.RGBA8_Legacy,.RGBE8_Legacy:return 4
    case .RGBA16,.RGBA16F:return 8
    case .G16,.R16F:return 2
    case .RGBA32F:return 16
    case .R32F:return 4
    case .Invalid:
    }
    return 0
}

// The texture class of an export, when it is one with source pixels.
texture_kind :: proc(p:^unreal.Package,index:int) -> (kind:Kind,ok:bool) {
    if p==nil || index<0 || index>=len(p.exports) {return}
    class:=p.exports[index].class
    switch {
    case unreal.reference_in_package(p,class,"/Script/Engine","Texture2D"),
         unreal.reference_in_package(p,class,"/Script/Engine","LightMapTexture2D"),
         unreal.reference_in_package(p,class,"/Script/Engine","ShadowMapTexture2D"),
         unreal.reference_in_package(p,class,"/Script/Engine","TextureLightProfile"):
        return .Texture_2D,true
    case unreal.reference_in_package(p,class,"/Script/Engine","TextureCube"):return .Cube,true
    case unreal.reference_in_package(p,class,"/Script/Engine","Texture2DArray"):return .Array,true
    case unreal.reference_in_package(p,class,"/Script/Engine","TextureCubeArray"):return .Cube_Array,true
    case unreal.reference_in_package(p,class,"/Script/Engine","VolumeTexture"):return .Volume,true
    }
    return
}

@(private="file")
TEXTURE_SOURCE_VIRTUALIZATION :: 42
@(private="file")
PNG_FLAG_FIXED :: 60
@(private="file")
UE4_TEXTURE_LEGACY_GAMMA :: 465

// Reads what an export says about its source pixels and where they are.
texture_read :: proc(p:^unreal.Package,index:int,allocator:=context.allocator) -> (Texture,unreal.Error) {
    // Built in locals: results are copied out before deferred cleanup runs.
    texture:Texture
    error:unreal.Error
    kind,is_texture:=texture_kind(p,index)
    if !is_texture {return {},{.Invalid_Reference,0,"export is not a texture with source pixels"}}
    texture.kind=kind
    texture.allocator=allocator
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,allocator)
    if error.code!=.None {return {},error}
    defer unreal.properties_destroy(&properties)
    source_property:=unreal.property_find(p,&properties,"Source")
    if source_property==nil {return {},{.Unsupported_Value,p.exports[index].data.offset,"texture keeps no Source; it was cooked or never imported"}}
    source:unreal.Property_List
    source,error=unreal.property_tagged_struct(p,source_property,true,allocator)
    if error.code!=.None {return {},error}
    defer unreal.properties_destroy(&source)
    defer if error.code!=.None {texture_destroy(&texture)}

    e:=&error
    block0:=Block{
        x=int(int_of(p,&source,"BaseBlockX",0,e)),y=int(int_of(p,&source,"BaseBlockY",0,e)),
        width=int(int_of(p,&source,"SizeX",0,e)),height=int(int_of(p,&source,"SizeY",0,e)),
        slices=int(int_of(p,&source,"NumSlices",0,e)),mips=int(int_of(p,&source,"NumMips",0,e)),
    }
    layer_count:=int(int_of(p,&source,"NumLayers",1,e))
    format:=enum_of(p,&source,"Format",SOURCE_FORMAT_NAMES,Source_Format.Invalid,e)
    texture.compression=enum_of(p,&source,"CompressionFormat",SOURCE_COMPRESSION_NAMES,Source_Compression.None,e)
    png:=bool_of(p,&source,"bPNGCompressed",false,e)
    long_lat:=bool_of(p,&source,"bLongLatCubemap",false,e)
    texture.id_is_hash=bool_of(p,&source,"bGuidIsHash",false,e)
    if property:=unreal.property_find(p,&source,"Id");property!=nil && error.code==.None {
        id,id_error:=unreal.property_value(p,property)
        if id_error.code==.None && id.kind==.Guid {texture.id=id.guid} else {texture.id_is_hash=false}
        unreal.value_destroy(&id)
    }
    version,_:=unreal.custom_version(p,unreal.UE5_MAIN_STREAM_VERSION)
    // Older saves mark some uncompressed sources as PNG; Unreal trusts bPNGCompressed for those.
    if version<PNG_FLAG_FIXED && !png && texture.compression==.PNG {texture.compression=.None}
    if png && texture.compression==.None {texture.compression=.PNG}
    if error.code!=.None {return {},error}
    if layer_count<1 || layer_count>16 {error={.Unsupported_Value,source_property.data.offset,"texture source layer count"};return {},error}

    allocation_error:mem.Allocator_Error
    texture.layers,allocation_error=make([]Source_Format,layer_count,allocator)
    if allocation_error!=nil {error={.Out_Of_Memory,0,"texture layers"};return {},error}
    for &layer in texture.layers {layer=format}
    if property:=unreal.property_find(p,&source,"LayerFormat");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return {},error}
        if int(view.count)!=layer_count {error={.Malformed,property.data.offset,"texture LayerFormat count differs from NumLayers"};return {},error}
        bytes:[]u8
        bytes,error=unreal.span_bytes(p,view.data)
        if error.code!=.None {return {},error}
        switch {
        case len(bytes)==layer_count:
            for &layer,i in texture.layers {
                if int(bytes[i])>=len(Source_Format) {error={.Malformed,view.data.offset,"texture LayerFormat value"};return {},error}
                layer=Source_Format(bytes[i])
            }
        case len(bytes)==layer_count*8:
            names:[]unreal.Name_Ref
            names,error=unreal.array_names(p,view,context.temp_allocator)
            if error.code!=.None {return {},error}
            for &layer,i in texture.layers {layer=enum_from_name(p,names[i],SOURCE_FORMAT_NAMES,Source_Format.Invalid,e)}
            if error.code!=.None {return {},error}
        case:error={.Malformed,view.data.offset,"texture LayerFormat element size"};return {},error
        }
    }
    for &layer in texture.layers {
        // Unreal reads these two as their channel-swapped formats without swapping the pixels.
        if layer==.RGBA8_Legacy {layer=.BGRA8}
        if layer==.RGBE8_Legacy {layer=.BGRE8}
        if layer==.Invalid {error={.Unsupported_Value,source_property.data.offset,"texture source has no pixel format"};return {},error}
    }

    extra:unreal.Struct_Array
    if property:=unreal.property_find(p,&source,"Blocks");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return {},error}
        extra,error=unreal.array_tagged_structs(p,view,true,allocator)
        if error.code!=.None {return {},error}
    }
    defer unreal.struct_array_destroy(&extra)
    texture.blocks,allocation_error=make([]Block,1+len(extra.items),allocator)
    if allocation_error!=nil {error={.Out_Of_Memory,0,"texture blocks"};return {},error}
    texture.blocks[0]=block0
    for &item,i in extra.items {
        texture.blocks[i+1]={
            x=int(int_of(p,&item,"BlockX",0,e)),y=int(int_of(p,&item,"BlockY",0,e)),
            width=int(int_of(p,&item,"SizeX",0,e)),height=int(int_of(p,&item,"SizeY",0,e)),
            slices=int(int_of(p,&item,"NumSlices",0,e)),mips=int(int_of(p,&item,"NumMips",0,e)),
        }
    }
    if error.code!=.None {return {},error}
    for block in texture.blocks {
        if block.width<1 || block.height<1 || block.slices<1 || block.mips<1 || block.width>1<<16 || block.height>1<<16 || block.slices>1<<16 || block.mips>32 {
            error={.Malformed,source_property.data.offset,"texture source block size"}
            return {},error
        }
    }
    if property:=unreal.property_find(p,&source,"BlockDataOffsets");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return {},error}
        if int(view.count)!=len(texture.blocks) || view.data.size!=i64(view.count)*8 {error={.Malformed,property.data.offset,"texture BlockDataOffsets count"};return {},error}
        bytes:[]u8
        bytes,error=unreal.span_bytes(p,view.data)
        if error.code!=.None {return {},error}
        for &block,i in texture.blocks {
            for byte,shift in bytes[i*8:i*8+8] {block.offset|=i64(byte)<<uint(shift*8)}
            if block.offset<0 {error={.Malformed,view.data.offset,"texture block offset"};return {},error}
        }
    } else {
        // Older saves store the blocks one after another.
        at:=i64(0)
        for &block in texture.blocks {
            block.offset=at
            for layer in 0..<layer_count {at+=i64(layer_size(&texture,block,layer))}
        }
    }

    srgb:=bool_of(p,&properties,"SRGB",true,e)
    texture.flip_green=bool_of(p,&properties,"bFlipGreenChannel",false,e)
    // Unreal reads sources saved before UE4 465 with the 2.2 curve.
    texture.legacy_gamma=bool_of(p,&properties,"bUseLegacyGamma",p.summary.version_ue4<UE4_TEXTURE_LEGACY_GAMMA,e)
    settings:=name_of(p,&properties,"CompressionSettings","TC_Default",e)
    if error.code!=.None {return {},error}
    switch {
    case settings=="TC_Normalmap":texture.usage=.Normal
    case !srgb,settings=="TC_Masks",settings=="TC_Alpha",strings.has_prefix(settings,"TC_HDR"),
         settings=="TC_HalfFloat",settings=="TC_SingleFloat",settings=="TC_EncodedReflectionCapture":
        texture.usage=.Data
    case:texture.usage=.Color
    }
    switch settings {
    case "TC_Grayscale","TC_Displacementmap","TC_HalfFloat","TC_SingleFloat","TC_HDR_F32":texture.keep_precision=true
    }
    // Unreal takes a cube whose slices are not whole cubes as longitude-latitude images too.
    texture.long_lat=(kind==.Cube || kind==.Cube_Array) && (long_lat || block0.slices%asset.TEXTURE_CUBE_FACES!=0)

    tail:unreal.Span
    tail,error=unreal.object_native_payload(p,properties.trailing)
    if error.code!=.None {return {},error}
    if tail.size<2 {error={.Truncated,tail.offset,"texture strip flags"};return {},error}
    if p.bytes[tail.offset]&1!=0 {error={.Cooked,tail.offset,"texture editor data was stripped when cooking"};return {},error}
    bulk_span:=unreal.Span{tail.offset+2,tail.size-2}
    if version<TEXTURE_SOURCE_VIRTUALIZATION {
        bulk:unreal.Byte_Bulk_Data
        bulk,error=unreal.byte_bulk_data(p,bulk_span)
        if error.code!=.None {return {},error}
        texture.payload={bulk.payload,bulk.flags&unreal.BULK_ZLIB!=0?.Zlib:.Raw,bulk.size}
    } else {
        bulk:unreal.Editor_Bulk_Data
        bulk,error=unreal.editor_bulk_data(p,bulk_span)
        if error.code!=.None {return {},error}
        texture.payload={bulk.payload,.Compressed_Buffer,bulk.raw_size}
    }
    texture.object=unreal.Object_Ref(index+1)
    return texture,{}
}

// Bytes of one level of a block and layer: its slices one after another.
level_size :: proc(texture:^Texture,block:Block,layer,mip:int) -> int {
    width:=max(block.width>>uint(mip),1)
    height:=max(block.height>>uint(mip),1)
    return width*height*level_slices(texture,block,mip)*format_bytes(texture.layers[layer])
}

level_slices :: proc(texture:^Texture,block:Block,mip:int) -> int {
    if texture.kind==.Volume {return max(block.slices>>uint(mip),1)}
    return block.slices
}

layer_size :: proc(texture:^Texture,block:Block,layer:int) -> (size:int) {
    for mip in 0..<block.mips {size+=level_size(texture,block,layer,mip)}
    return
}

// Where a level starts in the uncompressed source.
level_offset :: proc(texture:^Texture,block_index,layer,mip:int) -> int {
    block:=texture.blocks[block_index]
    offset:=int(block.offset)
    for before in 0..<layer {offset+=layer_size(texture,block,before)}
    for before in 0..<mip {offset+=level_size(texture,block,layer,before)}
    return offset
}

source_size :: proc(texture:^Texture) -> (size:int) {
    for block in texture.blocks {for layer in 0..<len(texture.layers) {size+=layer_size(texture,block,layer)}}
    return
}

@(private="file")
int_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:i64,error:^unreal.Error) -> i64 {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return default}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return default}
    #partial switch read.kind {
    case .Signed:return read.signed
    case .Unsigned:if read.unsigned<=u64(max(i64)) {return i64(read.unsigned)}
    }
    error^={.Malformed,property.data.offset,"texture source integer"}
    return default
}

@(private="file")
bool_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:bool,error:^unreal.Error) -> bool {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return default}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return default}
    if read.kind!=.Boolean {error^={.Malformed,property.data.offset,"texture boolean"};return default}
    return read.boolean
}

@(private="file")
name_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:string,error:^unreal.Error) -> string {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return default}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return default}
    if read.kind!=.Name {error^={.Unsupported_Value,property.data.offset,"texture enum stored as a number"};return default}
    return enum_value_name(unreal.name_plain(p,read.name))
}

// Enum names are saved with their type ("TextureCompressionSettings::TC_Masks") or without it.
@(private="file")
enum_value_name :: proc(name:string) -> string {
    if at:=strings.last_index(name,"::");at>=0 {return name[at+2:]}
    return name
}

@(private="file")
enum_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,names:[$E]string,default:E,error:^unreal.Error) -> E {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return default}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return default}
    #partial switch read.kind {
    case .Name:return enum_from_name(p,read.name,names,default,error)
    case .Unsigned:if read.unsigned<u64(len(E)) {return E(read.unsigned)}
    }
    error^={.Malformed,property.data.offset,"texture source enum"}
    return default
}

@(private="file")
enum_from_name :: proc(p:^unreal.Package,reference:unreal.Name_Ref,names:[$E]string,default:E,error:^unreal.Error) -> E {
    text:=enum_value_name(unreal.name_plain(p,reference))
    for candidate,item in names {if candidate==text {return item}}
    if error.code==.None {error^={.Unsupported_Value,0,"texture source enum value is unknown"}}
    return default
}
