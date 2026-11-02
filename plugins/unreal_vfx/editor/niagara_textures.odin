package unreal_vfx_editor

import "core:fmt"
import "core:strings"
import "mirai:cook/textures"
import "project:plugins/unreal/editor/level"
import unreal_scene "project:plugins/unreal/editor/scene"
import "project:plugins/unreal/editor/texture"
import "mirai:std/base"
import "plugins:vfx/runtime/gridfile"

// Texture: the texels of the Texture2D the data interface samples, as Unreal
// reads them (color as linear values), baked into a .grid flat along y of
// one cell a texel that a grid of the effect starts from; its program samples
// it between texels, repeating (niagara_texture_sample).

NIAGARA_TEXTURE_CELLS :: 512 // along the longest axis of a baked texture at most: a larger one is resampled

Niagara_Texture :: struct {
    id:base.Asset_Id,
    name:string,
    cells:[2]int,
}

// The texture a Texture data interface samples, written as a .grid; false
// for one this import does not read.
@(private)
niagara_texture :: proc(w:^Niagara_Writer,di:^Niagara_Di) -> (baked:Niagara_Texture,ok:bool) {
    if w.scene==nil {return}
    d:=w.d
    c:=w.scene
    holder,held:=niagara_di_holder(w,di,"Texture")
    if !held {return}
    object,found:=object_at(d,holder,"Texture")
    if !found {return}
    // Once for the system, whichever data interfaces sample it.
    key,key_error:=level.object_path(d,object,object.object,context.temp_allocator)
    if key_error.code!=.None {return}
    if known,seen:=w.system.textures[key];seen {return known,known.id!={}}
    defer w.system.textures[strings.clone(key,context.temp_allocator)]=baked
    name:=object_name(d,object)
    p:=level.library_package(d.library,int(object.pkg))
    read,read_error:=texture.texture_read(p,int(object.object)-1,context.temp_allocator)
    if read_error.code!=.None {return}
    decoder,has_decoder:=unreal_scene.decoder(c)
    if !has_decoder {return}
    decoded,decode_error:=texture.texture_decode(p,&read,decoder,context.temp_allocator)
    if decode_error.code!=.None {return}
    input,input_error:=texture.texture_build_input(&read,&decoded,context.temp_allocator)
    if input_error.code!=.None {return}
    cells,values,baked_ok:=niagara_texture_cells(input.source,input.options.srgb)
    if !baked_ok {return}
    info:=gridfile.Grid_Info{cells={u32(cells.x),1,u32(cells.y)},layers=1,cell_size=CENTIMETRE}
    id,path,source:=unreal_scene.asset_place(c,gridfile.KIND,name,0,gridfile.EXTENSION)
    bytes,bytes_error:=gridfile.grid_bytes(c.types,{id=id,info=info,cells=values,source=&source},context.temp_allocator)
    if bytes_error!=.None {
        unreal_scene.warn(c,"the texture %s could not be baked (%v)",name,bytes_error)
        return
    }
    if !unreal_scene.asset_write(c,id,gridfile.KIND,name,path,bytes,fmt.tprintf("%dx%d texels",cells.x,cells.y)) {return}
    return {id,strings.clone(name,context.temp_allocator),cells},true
}

// The cells of a texture baked into a grid flat along y: four floats a texel
// (rows from the top along z), resampled between texels when its longest
// axis passes NIAGARA_TEXTURE_CELLS. False for a cube or an array.
@(private)
niagara_texture_cells :: proc(source:textures.Source,srgb:bool) -> (cells:[2]int,values:[]f32,ok:bool) {
    if source.cube || source.layers>1 || source.width<1 || source.height<1 {return}
    scale:=max(f32(max(source.width,source.height))/NIAGARA_TEXTURE_CELLS,1)
    cells={max(int(f32(source.width)/scale),1),max(int(f32(source.height)/scale),1)}
    transfer:=textures.transfer_make(srgb && !textures.source_hdr(source.format))
    texel :: proc(source:textures.Source,x,y:int,transfer:^textures.Transfer) -> [4]f32 {
        return textures.texel_read(source.texels,source.format,clamp(y,0,source.height-1)*source.width+clamp(x,0,source.width-1),transfer)
    }
    values=make([]f32,cells.x*cells.y*4,context.temp_allocator)
    for y in 0..<cells.y {
        for x in 0..<cells.x {
            // The middle of the cell in the texture, between its texels.
            u:=(f32(x)+0.5)*f32(source.width)/f32(cells.x)-0.5
            v:=(f32(y)+0.5)*f32(source.height)/f32(cells.y)-0.5
            x0,y0:=int(u),int(v)
            if u<0 {x0=-1}
            if v<0 {y0=-1}
            fx,fy:=u-f32(x0),v-f32(y0)
            value:=(texel(source,x0,y0,&transfer)*(1-fx)+texel(source,x0+1,y0,&transfer)*fx)*(1-fy)+(texel(source,x0,y0+1,&transfer)*(1-fx)+texel(source,x0+1,y0+1,&transfer)*fx)*fy
            for k in 0..<4 {values[(y*cells.x+x)*4+k]=value[k]}
        }
    }
    return cells,values,true
}

// The functions of Texture.
@(private)
niagara_texture_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base_name:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    if di.resource=="" {return}
    ins,outs:=niagara_split(params)
    if len(outs)<1 {return}
    switch base_name {
    case "SampleTexture","SampleTexture2D":
        if len(ins)<1 {return}
        return fmt.tprintf("    %s = niagara_texture_sample(%s, %s);\n",outs[0].name,di.resource,ins[0].name),true
    case "GetTextureDimensions","TextureDimensions","GetTextureDimensions2D":
        return fmt.tprintf("    %s = float2(%d, %d);\n",outs[0].name,di.texture.cells.x,di.texture.cells.y),true
    case "GetNumMipLevels":
        return fmt.tprintf("    %s = 1;\n",outs[0].name),true
    }
    return
}
