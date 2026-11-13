package unreal_texture

import "core:encoding/endian"
import "core:mem"
import "mirai:cook/textures"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"

// What a texture of a package is made from, as one block of bytes: the
// properties that shape its texels and its payload as the package stores it,
// behind MADE_VERSION. The importer keys the texture of an image by these
// bytes (importer.image_made), so a texture the texture cache keeps is taken
// without decoding the payload; texture_made decodes it when it is not.

// Raise it when texture_made gives other texels for the same bytes.
MADE_VERSION :: u32(1)

@(private="file")
MADE_TAG :: u32(0x6d787475) // "utxm"

// The bytes texture_made makes the texels of texture of p from, in allocator.
texture_pack :: proc(p:^unreal.Package,texture:^Texture,allocator:=context.allocator) -> (data:[]u8,error:unreal.Error) {
    payload:[]u8
    payload,error=unreal.span_bytes(p,texture.payload.span)
    if error.code!=.None {return}
    head:=8+6+8+4+len(texture.layers)+4+len(texture.blocks)*(6*4+8)
    allocation_error:mem.Allocator_Error
    if data,allocation_error=make([]u8,head+len(payload),allocator);allocation_error!=nil {return nil,{.Out_Of_Memory,0,"texture data"}}
    at:=0
    u32_put :: proc(data:[]u8,at:^int,value:u32) {endian.put_u32(data[at^:],.Little,value);at^+=4}
    i64_put :: proc(data:[]u8,at:^int,value:i64) {endian.put_i64(data[at^:],.Little,value);at^+=8}
    u32_put(data,&at,MADE_TAG)
    u32_put(data,&at,MADE_VERSION)
    data[at],data[at+1],data[at+2],data[at+3]=u8(texture.kind),u8(texture.compression),u8(texture.usage),u8(texture.payload.encoding)
    data[at+4]=u8(texture.keep_precision)|u8(texture.long_lat)<<1|u8(texture.flip_green)<<2|u8(texture.legacy_gamma)<<3
    at+=6
    i64_put(data,&at,texture.payload.raw_size)
    u32_put(data,&at,u32(len(texture.layers)))
    for layer in texture.layers {data[at]=u8(layer);at+=1}
    u32_put(data,&at,u32(len(texture.blocks)))
    for block in texture.blocks {
        for value in ([6]int{block.x,block.y,block.width,block.height,block.slices,block.mips}) {u32_put(data,&at,u32(i32(value)))}
        i64_put(data,&at,block.offset)
    }
    copy(data[at:],payload)
    return
}

// The texels of what texture_pack gave, as texture_build_input makes them,
// in allocator: an importer.Image_Make. False for bytes that are not that,
// or that do not decode.
texture_made :: proc(data:[]u8,allocator:mem.Allocator) -> (made:textures.Source,ok:bool) {
    decoder,decoder_error:=kraken.decoder_make(context.temp_allocator)
    if decoder_error!=nil {return}
    defer kraken.decoder_destroy(&decoder)
    error:unreal.Error
    made,_,error=made_decode(data,&decoder,allocator)
    return made,error.code==.None
}

// texture_made with the decoder of the caller, with the use Unreal gives
// the texture, saying what failed.
made_decode :: proc(data:[]u8,decoder:^kraken.Decoder,allocator:mem.Allocator) -> (made:textures.Source,usage:Usage,error:unreal.Error) {
    MALFORMED :: unreal.Error{.Malformed,0,"texture data"}
    at:=0
    u32_get :: proc(data:[]u8,at:^int) -> (value:u32,ok:bool) {
        if at^+4>len(data) {return}
        value,ok=endian.get_u32(data[at^:],.Little)
        at^+=4
        return
    }
    i64_get :: proc(data:[]u8,at:^int) -> (value:i64,ok:bool) {
        if at^+8>len(data) {return}
        value,ok=endian.get_i64(data[at^:],.Little)
        at^+=8
        return
    }
    tag,tag_ok:=u32_get(data,&at)
    version,version_ok:=u32_get(data,&at)
    if !tag_ok || !version_ok || tag!=MADE_TAG || version!=MADE_VERSION || at+6>len(data) {return {},{},MALFORMED}
    t:Texture
    if data[at]>u8(max(Kind)) || data[at+1]>u8(max(Source_Compression)) || data[at+2]>u8(max(Usage)) || data[at+3]>u8(max(Payload_Encoding)) {return {},{},MALFORMED}
    t.kind,t.compression,t.usage,t.payload.encoding=Kind(data[at]),Source_Compression(data[at+1]),Usage(data[at+2]),Payload_Encoding(data[at+3])
    flags:=data[at+4]
    t.keep_precision,t.long_lat,t.flip_green,t.legacy_gamma=flags&1!=0,flags&2!=0,flags&4!=0,flags&8!=0
    at+=6
    ok:bool
    if t.payload.raw_size,ok=i64_get(data,&at);!ok {return {},{},MALFORMED}
    count:u32
    if count,ok=u32_get(data,&at);!ok || int(count)>len(data)-at {return {},{},MALFORMED}
    t.layers=make([]Source_Format,count,context.temp_allocator)
    for &layer in t.layers {
        if data[at]>u8(max(Source_Format)) {return {},{},MALFORMED}
        layer=Source_Format(data[at])
        at+=1
    }
    if count,ok=u32_get(data,&at);!ok || int(count)>(len(data)-at)/(6*4+8) {return {},{},MALFORMED}
    t.blocks=make([]Block,count,context.temp_allocator)
    for &block in t.blocks {
        values:[6]int
        for &value in values {
            word,_:=u32_get(data,&at)
            value=int(i32(word))
        }
        offset,_:=i64_get(data,&at)
        block={values[0],values[1],values[2],values[3],values[4],values[5],offset}
    }
    payload:=data[at:]
    t.payload.span={0,i64(len(payload))}
    decoded:Decoded
    decoded,error=payload_decode(payload,unreal.DEFAULT_LIMITS,&t,decoder,context.temp_allocator)
    if error.code!=.None {return}
    defer decoded_destroy(&decoded)
    input:Build_Input
    input,error=texture_build_input(&t,&decoded,allocator)
    return input.source,t.usage,error
}
