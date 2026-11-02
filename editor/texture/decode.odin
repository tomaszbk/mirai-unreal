package texture

import "base:intrinsics"
import "core:c"
import "core:encoding/endian"
import "core:math"
import "core:mem"
import stbi "vendor:stb/image"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/base"
import "mirai:std/jobs"

MAX_PIXELS :: 1<<28

// RGBA8 keeps the source encoding (sRGB for color, or a 2.2 curve with
// legacy_gamma); RGBA16 and RGBA32F hold linear values.
Pixel_Format :: enum u8 {RGBA8,RGBA16,RGBA32F}

pixel_bytes :: proc(format:Pixel_Format) -> int {
    switch format {
    case .RGBA8:return 4
    case .RGBA16:return 8
    case .RGBA32F:return 16
    }
    return 0
}

// One level of a block and layer; its slices follow each other from offset.
Level :: struct {block,layer,mip,width,height,slices,offset:int}

// Whether the raw source matches the hash Unreal keeps as its id.
Source_Check :: enum u8 {Unknown,Matches,Differs}

Decoded :: struct {
    format:Pixel_Format,
    check:Source_Check,
    levels:[]Level, // by block, then layer, then mip
    pixels:[]u8,
    allocator:mem.Allocator,
}

decoded_destroy :: proc(decoded:^Decoded) {
    if decoded==nil || decoded.allocator.procedure==nil {return}
    delete(decoded.levels,decoded.allocator)
    delete(decoded.pixels,decoded.allocator)
    decoded^={}
}

// Bytes of one slice of a level.
level_slice :: proc(decoded:^Decoded,level:Level,slice:int) -> []u8 {
    size:=level.width*level.height*pixel_bytes(decoded.format)
    return decoded.pixels[level.offset+slice*size:][:size]
}

// The source pixels as RGBA rows from the top, every block, layer, mip and
// slice, in Mirai's conventions: normal maps keep +Y in green.
texture_decode :: proc(p:^unreal.Package,texture:^Texture,decoder:^kraken.Decoder,allocator:=context.allocator,worker:=jobs.Worker_Ref{}) -> (decoded:Decoded,error:unreal.Error) {
    if p==nil || texture==nil || len(texture.layers)==0 || len(texture.blocks)==0 {return {},{.Invalid_Reference,0,"texture to decode"}}
    at_payload:=texture.payload.span.offset
    if texture.payload.raw_size<=0 {return {},{.Unsupported_Value,at_payload,"texture source has no pixels"}}
    if u64(texture.payload.raw_size)>p.limits.source_bytes {return {},{.Limit,at_payload,"texture payload size"}}
    for block in texture.blocks {
        if block.width*block.height>MAX_PIXELS {return {},{.Limit,0,"texture source pixel count"}}
    }
    expected:=source_size(texture)
    if expected<=0 || expected>int(p.limits.source_bytes) {return {},{.Limit,0,"texture source size"}}
    payload:[]u8
    payload,error=unreal.span_bytes(p,texture.payload.span)
    if error.code!=.None {return}
    raw,raw_error:=make([]u8,int(texture.payload.raw_size),context.allocator)
    if raw_error!=nil {return {},{.Out_Of_Memory,0,"texture payload"}}
    defer delete(raw)
    payload_zone:=jobs.worker_zone_begin(worker,"unreal.payload")
    // The BLAKE3 of the raw payload, checked by the decode, when there is one.
    payload_hash:Maybe([32]u8)
    switch texture.payload.encoding {
    case .Compressed_Buffer:
        buffer:unreal.Compressed_Buffer
        buffer,error=unreal.compressed_buffer(payload,p.limits)
        if error.code!=.None {return}
        if buffer.raw_size!=u64(len(raw)) {return {},{.Malformed,at_payload,"compressed buffer size differs from the bulk data size"}}
        error=unreal.compressed_buffer_decode(buffer,raw,decoder)
        if error.code!=.None {return}
        payload_hash=buffer.raw_hash
    case .Raw:
        if len(payload)!=len(raw) {return {},{.Malformed,at_payload,"bulk data size"}}
        copy(raw,payload)
    case .Zlib:
        error=unreal.zlib_chunks_decode(payload,raw)
        if error.code!=.None {return}
    }

    base.profile_end(payload_zone)
    source:=raw
    switch texture.compression {
    case .None,.UEDELTA:
        if len(raw)!=expected || !layout_fits(texture,len(raw)) {return {},{.Malformed,at_payload,"texture payload size differs from its blocks, layers and mips"}}
        if texture.compression==.UEDELTA {
            for block,block_index in texture.blocks {
                for layer in 0..<len(texture.layers) {
                    bytes:=format_bytes(texture.layers[layer])
                    element:=bytes
                    #partial switch texture.layers[layer] {
                    case .BGRA8,.BGRE8:element=1
                    case .RGBA16,.RGBA16F:element=2
                    case .RGBA32F:element=4
                    }
                    for mip in 0..<block.mips {
                        width,height:=max(block.width>>uint(mip),1),max(block.height>>uint(mip),1)
                        at:=level_offset(texture,block_index,layer,mip)
                        for slice in 0..<level_slices(texture,block,mip) {
                            surface:=raw[at+slice*width*height*bytes:][:width*height*bytes]
                            delta_inverse_surface(surface,width,height,bytes,element)
                        }
                    }
                }
            }
        }
    case .PNG,.JPEG,.UEJPEG:
        block:=texture.blocks[0]
        if len(texture.blocks)!=1 || len(texture.layers)!=1 || block.slices!=1 || block.mips!=1 || block.offset!=0 {
            return {},{.Unsupported_Value,at_payload,"a PNG, JPEG or UE JPEG source holds a single 2D image"}
        }
        image_zone:=jobs.worker_zone_begin(worker,"image.decode")
        image,image_error:=image_decode(raw,texture.layers[0],texture.compression==.PNG,block.width,block.height,decoder)
        base.profile_end(image_zone)
        if image_error.code==.None {
            source=image
        } else if len(raw)!=expected {
            image_error.offset+=at_payload
            return {},image_error
        }
        // Otherwise a source marked compressed that holds its pixels as they are, as Unreal reads it.
    }
    defer if raw_data(source)!=raw_data(raw) {delete(source)}
    if texture.id_is_hash && raw_data(source)==raw_data(raw) && (texture.compression==.None || texture.compression==.UEDELTA) {
        // Without UEDELTA the source is the payload as it was hashed.
        hash,known:=payload_hash.?
        digest:=hash if known && texture.compression==.None else unreal.blake3(source)
        decoded.check=.Matches if string(digest[:16])==string(texture.id[:]) else .Differs
    }

    decoded.allocator=allocator
    decoded.format=.RGBA8
    for layer in texture.layers {
        #partial switch layer {
        case .RGBA16,.G16:if decoded.format==.RGBA8 {decoded.format=.RGBA16}
        case .BGRE8,.RGBA16F,.RGBA32F,.R16F,.R32F:decoded.format=.RGBA32F
        }
    }
    count:=0
    pixels:=0
    for block in texture.blocks {
        count+=block.mips*len(texture.layers)
        for _ in texture.layers {
            for mip in 0..<block.mips {pixels+=max(block.width>>uint(mip),1)*max(block.height>>uint(mip),1)*level_slices(texture,block,mip)}
        }
    }
    allocation_error:mem.Allocator_Error
    decoded.levels,allocation_error=make([]Level,count,allocator)
    if allocation_error!=nil {return {},{.Out_Of_Memory,0,"decoded texture levels"}}
    decoded.pixels,allocation_error=make([]u8,pixels*pixel_bytes(decoded.format),allocator)
    if allocation_error!=nil {decoded_destroy(&decoded);return {},{.Out_Of_Memory,0,"decoded texture pixels"}}
    invert_green:=(texture.usage==.Normal)!=texture.flip_green
    at,index:=0,0
    for block,block_index in texture.blocks {
        for layer in 0..<len(texture.layers) {
            for mip in 0..<block.mips {
                level:=Level{block=block_index,layer=layer,mip=mip,width=max(block.width>>uint(mip),1),height=max(block.height>>uint(mip),1),slices=level_slices(texture,block,mip),offset=at}
                decoded.levels[index]=level
                index+=1
                count:=level.width*level.height*level.slices
                from:=level_offset(texture,block_index,layer,mip)
                convert(source[from:][:count*format_bytes(texture.layers[layer])],texture.layers[layer],decoded.pixels[at:][:count*pixel_bytes(decoded.format)],decoded.format,invert_green)
                at+=count*pixel_bytes(decoded.format)
            }
        }
    }
    return
}

// Every level of every block and layer inside the source.
@(private="file")
layout_fits :: proc(texture:^Texture,size:int) -> bool {
    for block,index in texture.blocks {
        for layer in 0..<len(texture.layers) {
            start:=level_offset(texture,index,layer,0)
            if start<0 || layer_size(texture,block,layer)>size-start {return false}
        }
    }
    return true
}

// A PNG, JPEG or UE JPEG source in the bytes of its source format. Like
// Unreal, the bytes say which format they are, not the compression the source
// names. PNG keeps 16 bit channels. Unreal saved BGRA8 sources into PNG as if
// they were RGBA, so a source named PNG keeps the bytes of its file as they are.
@(private="file")
image_decode :: proc(bytes:[]u8,format:Source_Format,png:bool,width,height:int,decoder:^kraken.Decoder) -> (out:[]u8,error:unreal.Error) {
    if len(bytes)==0 || len(bytes)>int(max(c.int)) {return nil,{.Malformed,0,"texture image payload"}}
    if len(bytes)>=len(UEJPEG_MAGIC) && string(bytes[:len(UEJPEG_MAGIC)])==UEJPEG_MAGIC {
        // Unreal decodes it to BGRA8 and converts that to G8 by keeping red.
        if format!=.BGRA8 && format!=.G8 {return nil,{.Unsupported_Value,0,"UE JPEG texture source in a format other than BGRA8 or G8"}}
        rgba:[]u8
        rgba,error=uejpeg_decode(bytes,width,height,decoder)
        if error.code!=.None {return}
        if format==.G8 {
            defer delete(rgba)
            allocation_error:mem.Allocator_Error
            out,allocation_error=make([]u8,width*height)
            if allocation_error!=nil {return nil,{.Out_Of_Memory,0,"texture image"}}
            for &value,i in out {value=rgba[i*4]}
            return
        }
        if !png {
            for i:=0;i<len(rgba);i+=4 {rgba[i],rgba[i+2]=rgba[i+2],rgba[i]}
        }
        return rgba,{}
    }
    x,y,components:c.int
    if stbi.info_from_memory(raw_data(bytes),c.int(len(bytes)),&x,&y,&components)==0 {return nil,{.Malformed,0,"texture source is not a PNG or JPEG image"}}
    if int(x)!=width || int(y)!=height {return nil,{.Malformed,0,"texture image size differs from its source size"}}
    channels:c.int
    #partial switch format {
    case .G8,.G16:channels=1
    case .BGRA8,.RGBA16:channels=4
    case:return nil,{.Unsupported_Value,0,"PNG or JPEG texture source in a float format"}
    }
    size:=width*height*format_bytes(format)
    allocation_error:mem.Allocator_Error
    out,allocation_error=make([]u8,size)
    if allocation_error!=nil {return nil,{.Out_Of_Memory,0,"texture image"}}
    if format==.G16 || format==.RGBA16 {
        if !png {delete(out);return nil,{.Unsupported_Value,0,"16 bit JPEG texture source"}}
        decoded:=stbi.load_16_from_memory(raw_data(bytes),c.int(len(bytes)),&x,&y,&components,channels)
        if decoded==nil {delete(out);return nil,{.Malformed,0,"texture PNG does not decode"}}
        defer stbi.image_free(decoded)
        for i in 0..<size/2 {endian.put_u16(out[i*2:],.Little,decoded[i])}
        return
    }
    decoded:=stbi.load_from_memory(raw_data(bytes),c.int(len(bytes)),&x,&y,&components,channels)
    if decoded==nil {delete(out);return nil,{.Malformed,0,"texture image does not decode"}}
    defer stbi.image_free(decoded)
    copy(out,decoded[:size])
    if !png && format==.BGRA8 {
        for i:=0;i<size;i+=4 {out[i],out[i+2]=out[i+2],out[i]}
    }
    return
}

// The exact value of a half, without the call a conversion of f16 makes where the CPU has none.
@(private)
half_to_f32 :: #force_inline proc "contextless" (bits:u16) -> f32 {
    sign:=u32(bits&0x8000)<<16
    exponent:=u32(bits>>10)&0x1f
    mantissa:=u32(bits&0x3ff)
    switch exponent {
    case 0:
        // Zero and subnormals: mantissa times 2^-24.
        value:=f32(mantissa)*(1.0/16777216.0)
        return -value if sign!=0 else value
    case 0x1f:return transmute(f32)(sign|0x7f800000|mantissa<<13)
    }
    return transmute(f32)(sign|(exponent+112)<<23|mantissa<<13)
}

// Source pixels of one format to RGBA of another, count pixels. The
// common pairs move whole pixels; the others go channel by channel.
@(private="file")
convert :: proc(from:[]u8,format:Source_Format,to:[]u8,out:Pixel_Format,invert_green:bool) #no_bounds_check {
    count:=len(from)/format_bytes(format)
    if len(to)<count*pixel_bytes(out) {return}
    switch {
    case out==.RGBA8 && format==.BGRA8:
        flip:=u32(0xff00) if invert_green else 0
        for i in 0..<count {
            v:=u32(intrinsics.unaligned_load((^u32le)(&from[i*4])))
            v=(v&0xff00ff00)|((v>>16)&0xff)|((v&0xff)<<16)
            intrinsics.unaligned_store((^u32le)(&to[i*4]),u32le(v~flip))
        }
    case out==.RGBA8 && format==.G8:
        flip:=u32(0xff00) if invert_green else 0
        for i in 0..<count {
            g:=u32(from[i])
            intrinsics.unaligned_store((^u32le)(&to[i*4]),u32le((g|g<<8|g<<16|0xff000000)~flip))
        }
    case out==.RGBA16 && format==.RGBA16:
        copy(to[:count*8],from[:count*8])
        if invert_green {
            for i in 0..<count {
                green:=(^u16le)(&to[i*8+2])
                intrinsics.unaligned_store(green,~intrinsics.unaligned_load(green))
            }
        }
    case out==.RGBA32F && format==.RGBA16F:
        for i in 0..<count {
            half:=intrinsics.unaligned_load((^[4]u16le)(&from[i*8]))
            rgba:=[4]f32le{f32le(half_to_f32(u16(half[0]))),f32le(half_to_f32(u16(half[1]))),f32le(half_to_f32(u16(half[2]))),f32le(half_to_f32(u16(half[3])))}
            if invert_green {rgba[1]=1-rgba[1]}
            intrinsics.unaligned_store((^[4]f32le)(&to[i*16]),rgba)
        }
    case out==.RGBA32F && format==.RGBA32F:
        copy(to[:count*16],from[:count*16])
        if invert_green {
            for i in 0..<count {
                green:=(^f32le)(&to[i*16+4])
                intrinsics.unaligned_store(green,1-intrinsics.unaligned_load(green))
            }
        }
    case:
        for i in 0..<count {convert_pixel(from,format,to,out,invert_green,i)}
    }
}

@(private="file")
convert_pixel :: #force_inline proc(from:[]u8,format:Source_Format,to:[]u8,out:Pixel_Format,invert_green:bool,i:int) #no_bounds_check {
    rgba:[4]f32
    // 8 and 16 bit channels move without floats when the output keeps them.
    switch out {
    case .RGBA8:
        px:=to[i*4:][:4]
        #partial switch format {
        case .G8:g:=from[i];px[0],px[1],px[2],px[3]=g,g,g,255
        case .BGRA8:s:=from[i*4:][:4];px[0],px[1],px[2],px[3]=s[2],s[1],s[0],s[3]
        }
        if invert_green {px[1]=255-px[1]}
        return
    case .RGBA16:
        value:[4]u16
        #partial switch format {
        case .G8:g:=u16(from[i])*257;value={g,g,g,65535}
        case .BGRA8:s:=from[i*4:][:4];value={u16(s[2])*257,u16(s[1])*257,u16(s[0])*257,u16(s[3])*257}
        case .G16:g,_:=endian.get_u16(from[i*2:],.Little);value={g,g,g,65535}
        case .RGBA16:for c in 0..<4 {value[c],_=endian.get_u16(from[i*8+c*2:],.Little)}
        }
        if invert_green {value[1]=65535-value[1]}
        for c in 0..<4 {endian.put_u16(to[i*8+c*2:],.Little,value[c])}
        return
    case .RGBA32F:
    }
    switch format {
    case .G8:g:=f32(from[i])/255;rgba={g,g,g,1}
    case .BGRA8,.RGBA8_Legacy:s:=from[i*4:][:4];rgba={f32(s[2])/255,f32(s[1])/255,f32(s[0])/255,f32(s[3])/255}
    case .BGRE8,.RGBE8_Legacy:
        s:=from[i*4:][:4]
        if s[3]==0 {rgba={0,0,0,1}} else {
            scale:=math.ldexp_f32(1,int(s[3])-136)
            rgba={(f32(s[2])+0.5)*scale,(f32(s[1])+0.5)*scale,(f32(s[0])+0.5)*scale,1}
        }
    case .G16:g,_:=endian.get_u16(from[i*2:],.Little);v:=f32(g)/65535;rgba={v,v,v,1}
    case .RGBA16:for c in 0..<4 {v,_:=endian.get_u16(from[i*8+c*2:],.Little);rgba[c]=f32(v)/65535}
    case .RGBA16F:for c in 0..<4 {v,_:=endian.get_u16(from[i*8+c*2:],.Little);rgba[c]=half_to_f32(v)}
    case .RGBA32F:for c in 0..<4 {rgba[c],_=endian.get_f32(from[i*16+c*4:],.Little)}
    case .R16F:v,_:=endian.get_u16(from[i*2:],.Little);rgba={half_to_f32(v),0,0,1}
    case .R32F:v,_:=endian.get_f32(from[i*4:],.Little);rgba={v,0,0,1}
    case .Invalid:
    }
    if invert_green {rgba[1]=1-rgba[1]}
    for c in 0..<4 {endian.put_f32(to[i*16+c*4:],.Little,rgba[c])}
}
