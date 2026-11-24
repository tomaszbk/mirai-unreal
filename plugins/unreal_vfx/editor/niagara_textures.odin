package unreal_vfx_editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:cook/textures"
import "project:plugins/unreal/editor/level"
import unreal_scene "project:plugins/unreal/editor/scene"
import texture "project:plugins/unreal/editor/texture"
import "mirai:std/base"

// Texture: the Texture2D the data interface samples, built as a .tex and
// bound to a texture parameter of the Vfx program (`//! parameter ...
// {"kind":"texture"}`), sampled with mirai_vfx_texture.

Niagara_Texture :: struct {
    id:base.Asset_Id,
    name:string,
    cells:[2]int,
    mips:int,
    srgb:bool,
}

// The texture a Texture data interface samples, written as a .tex; false
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
    if input.source.cube || input.source.layers>1 || input.source.width<1 || input.source.height<1 {return}
    options:=input.options
    options.encoding=.Uncompressed
    built,build_error:=textures.build(input.source,options,context.temp_allocator)
    if build_error!=.None {
        unreal_scene.warn(c,"the texture %s could not be built (%v)",name,build_error)
        return
    }
    id,path,source:=unreal_scene.asset_place(c,asset.KIND_TEXTURE,name,0,".tex")
    doc:asset.Document
    doc_error:=asset.texture_document(&doc,c.types,textures.built_desc(&built,id,&source),context.temp_allocator)
    if doc_error!=.None {
        unreal_scene.warn(c,"the texture %s could not be written (%v)",name,doc_error)
        return
    }
    defer asset.document_destroy(&doc)
    bytes,bytes_error:=asset.document_bytes(&doc,context.temp_allocator)
    if bytes_error!=.None {
        unreal_scene.warn(c,"the texture %s could not be written (%v)",name,bytes_error)
        return
    }
    if !unreal_scene.asset_write(c,id,name,path,bytes,fmt.tprintf("%dx%d texels",built.width,built.height)) {return}
    return {id,strings.clone(name,context.temp_allocator),{built.width,built.height},len(built.mips),options.srgb},true
}

// The functions of Texture.
@(private)
niagara_texture_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base_name:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    if di.param=="" {return}
    ins,outs:=niagara_split(params)
    if len(outs)<1 {return}
    switch base_name {
    case "SampleTexture","SampleTexture2D":
        if len(ins)<1 {return}
        return fmt.tprintf("    %s = niagara_texture_sample(%s, %s);\n",outs[0].name,di.param,ins[0].name),true
    case "GetTextureDimensions","TextureDimensions","GetTextureDimensions2D":
        return fmt.tprintf("    %s = float2(%d, %d);\n",outs[0].name,di.texture.cells.x,di.texture.cells.y),true
    case "GetNumMipLevels":
        return fmt.tprintf("    %s = %d;\n",outs[0].name,max(di.texture.mips,1)),true
    }
    return
}
