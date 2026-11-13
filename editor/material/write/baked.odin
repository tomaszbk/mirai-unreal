package write

import "core:encoding/endian"
import "core:math"
import "core:mem"
import "mirai:cook/textures"
import "mirai:std/base"
import "project:plugins/unreal/editor/kraken"
import material "project:plugins/unreal/editor/material"
import texture "project:plugins/unreal/editor/texture"

// What the image of a map that is baked from the graph is made from, as one
// block of bytes: the nodes it evaluates, with the values of the parameters
// they read, and what each texture they sample is made from
// (texture.texture_pack), behind BAKE_VERSION. The importer keys its texture
// by these bytes (importer.image_made), so a texture the texture cache keeps
// is taken without decoding a texture or evaluating a texel; bake_made bakes
// it when it is not, on the job that builds the texture.

// Raise it when bake_made gives other texels for the same bytes.
BAKE_VERSION :: u32(1)

@(private="file")
BAKE_TAG :: u32(0x6b627475) // "utbk"

@(private="file")
NODE_BYTES :: 1+1+4+3*4+4*4+4

// The recipe of image, which encodings stores, in allocator: only the nodes
// under its channels, in the order of the graph, a parameter as its value.
// A texture that cannot be read is held empty, and is read as white.
@(private)
bake_pack :: proc(b:^Builder,g:^material.Graph,image:material.Map_Image,encodings:[4]material.Channel_Encoding,allocator:mem.Allocator) -> []u8 {
    roots:=image.channels
    order:=material.nodes_under(g,roots[:])
    row:=make(map[u32]u32,context.temp_allocator) // of each node of the graph that is kept
    for n,i in order {row[n]=u32(i)}
    sampled:=make([dynamic]u32,context.temp_allocator) // the rows of g.textures read, in their new order
    texture_row:=make(map[u32]u32,context.temp_allocator)
    for n in order {
        node:=g.nodes[n]
        if node.op!=.Texture || node.index in texture_row {continue}
        texture_row[node.index]=u32(len(sampled))
        append(&sampled,node.index)
    }
    datas:=make([][]u8,len(sampled),context.temp_allocator)
    size:=4+4+4*4+4+4+len(order)*NODE_BYTES+4
    for t,i in sampled {
        if int(t)<len(g.textures) {
            if source:=source_texture(b,g.textures[t].path);source.ok {datas[i]=source.data}
        }
        size+=4+len(datas[i])
    }
    out:=make([]u8,size,allocator)
    at:=0
    put :: proc(out:[]u8,at:^int,value:u32) {endian.put_u32(out[at^:],.Little,value);at^+=4}
    put(out,&at,BAKE_TAG)
    put(out,&at,BAKE_VERSION)
    for channel in image.channels {put(out,&at,channel==material.NONE?material.NONE:row[channel])}
    for encoding in encodings {out[at]=u8(encoding);at+=1}
    put(out,&at,u32(len(order)))
    for n in order {
        node:=g.nodes[n]
        if node.op==.Parameter {node={op=.Constant,width=node.width,value=g.parameters[node.index].value,args={material.NONE,material.NONE,material.NONE}}}
        if node.op==.Texture {node.index=texture_row[node.index]}
        out[at],out[at+1]=u8(node.op),node.width
        at+=2
        for s in node.swizzle {out[at]=s;at+=1}
        for arg in node.args {put(out,&at,arg==material.NONE?material.NONE:row[arg])}
        for v in node.value {put(out,&at,transmute(u32)v)}
        put(out,&at,node.index)
    }
    put(out,&at,u32(len(sampled)))
    for data in datas {
        put(out,&at,u32(len(data)))
        copy(out[at:],data)
        at+=len(data)
    }
    return out
}

// The texels of what bake_pack gave, in allocator: an importer.Image_Make.
// False for bytes that are not that.
bake_made :: proc(data:[]u8,allocator:mem.Allocator) -> (made:textures.Source,ok:bool) {
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)
    at:=0
    get :: proc(data:[]u8,at:^int) -> (value:u32,ok:bool) {
        if at^+4>len(data) {return}
        value,ok=endian.get_u32(data[at^:],.Little)
        at^+=4
        return
    }
    if tag,_:=get(data,&at);tag!=BAKE_TAG {return}
    if version,_:=get(data,&at);version!=BAKE_VERSION {return}
    image:material.Map_Image
    for &channel in image.channels {channel=get(data,&at) or_return}
    if at+4>len(data) {return}
    encodings:[4]material.Channel_Encoding
    for &encoding in encodings {
        if data[at]>u8(max(material.Channel_Encoding)) {return}
        encoding=material.Channel_Encoding(data[at])
        at+=1
    }
    count:=get(data,&at) or_return
    if int(count)>(len(data)-at)/NODE_BYTES {return}
    g:material.Graph
    material.graph_init(&g,context.temp_allocator)
    for _ in 0..<count {
        node:material.Node
        if data[at]>u8(max(material.Op)) {return}
        node.op,node.width=material.Op(data[at]),data[at+1]
        at+=2
        for &s in node.swizzle {s=data[at];at+=1}
        for &arg in node.args {
            arg=get(data,&at) or_return
            if arg!=material.NONE && arg>=count {return}
        }
        for &v in node.value {v=transmute(f32)(get(data,&at) or_return)}
        node.index=get(data,&at) or_return
        append(&g.nodes,node)
    }
    for channel in image.channels {if channel!=material.NONE && channel>=count {return}}
    sampled:=get(data,&at) or_return
    if int(sampled)>(len(data)-at)/4 {return}
    for node in g.nodes {if node.op==.Texture && node.index>=sampled {return}}
    pixels:=make([]^material.Pixels,sampled,context.temp_allocator)
    decoder:kraken.Decoder
    decoder_made:=false
    defer if decoder_made {kraken.decoder_destroy(&decoder)}
    for &p in pixels {
        size:=int(get(data,&at) or_return)
        if size>len(data)-at {return}
        packed:=data[at:][:size]
        at+=size
        if size==0 {continue}
        if !decoder_made {
            error:mem.Allocator_Error
            if decoder,error=kraken.decoder_make(context.temp_allocator);error!=nil {return}
            decoder_made=true
        }
        source,usage,error:=texture.made_decode(packed,&decoder,context.temp_allocator)
        if error.code!=.None || source.cube || source.layers>1 {continue}
        p=new(material.Pixels,context.temp_allocator)
        p^=pixels_of(&source,usage,context.temp_allocator)
    }
    texels,width,height,_:=material.image_bake(&g,image,encodings,pixels,false,allocator)
    return textures.rgba8(texels,width,height),true
}

// A texture as Unreal's sampler reads it, from its texels and the use Unreal
// gives it: linear values, or a normal map unpacked to -1..1 with its Z rebuilt.
@(private)
pixels_of :: proc(from:^textures.Source,usage:texture.Usage,allocator:mem.Allocator) -> material.Pixels {
    count:=from.width*from.height
    pixels:=material.Pixels{from.width,from.height,make([][4]f32,count,allocator)}
    transfer:=textures.transfer_make(usage==.Color && !textures.source_hdr(from.format))
    for i in 0..<count {
        texel:=textures.texel_read(from.texels,from.format,i,&transfer)
        switch usage {
        case .Color:
        case .Normal:
            xy:=texel.xy*2-1
            texel={xy.x,xy.y,math.sqrt(max(1-xy.x*xy.x-xy.y*xy.y,0)),1}
        case .Data:
        }
        pixels.texels[i]=texel
    }
    return pixels
}
