package material

import "core:fmt"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// Runtime virtual textures. Unreal renders what some primitives write into
// one, and materials read it back where they are; Mirai has none. A sample is
// what the material that writes the texture gives at the point of the
// sample: that material's graph, evaluated there. The landscape material
// that reads back what it writes is evaluated with its own weights; another
// surface (grass over the ground) evaluates the landscape's material as it
// shows without a terrain, its first layer, at its own place in the world.

// What writes a runtime virtual texture: the material of a landscape that
// draws into it, and where the landscape is.
Virtual_Texture_Writer :: struct {
    texture:string,        // object path of the RuntimeVirtualTexture
    material:string,       // object path of the material or instance that writes it
    coordinates:[2][4]f32, // of its landscape from the world, as Landscape_Mapping
}

// ERuntimeVirtualTextureMaterialType, in its order.
@(private)
VIRTUAL_TEXTURE_TYPES :: []string{"BaseColor","Mask4","BaseColor_Normal_Roughness","BaseColor_Normal_Specular",
    "BaseColor_Normal_Specular_YCoCg","BaseColor_Normal_Specular_Mask_YCoCg","WorldHeight","Displacement"}

// The outputs of a sample, which are the inputs of the output a material
// writes by: the one of each name.
@(private)
Virtual_Output :: enum u8 {Base_Color,Specular,Roughness,Normal,World_Height,Mask,Displacement,Mask4}

@(private)
@(rodata)
VIRTUAL_OUTPUT_NAMES := [Virtual_Output]string{
    .Base_Color="BaseColor",.Specular="Specular",.Roughness="Roughness",.Normal="Normal",.World_Height="WorldHeight",
    .Mask="Mask",.Displacement="Displacement",.Mask4="Mask4",
}

// What a sample gives of an output its texture does not hold, and what a
// material writes of an input it leaves unconnected.
@(private)
@(rodata)
VIRTUAL_OUTPUT_DEFAULTS := [Virtual_Output][4]f32{
    .Base_Color={},.Specular={0.5,0,0,0},.Roughness={0.5,0,0,0},.Normal={0,0,1,0},.World_Height={},.Mask={1,0,0,0},
    .Displacement={},.Mask4={},
}

@(private)
@(rodata)
VIRTUAL_OUTPUT_WIDTHS := [Virtual_Output]u8{
    .Base_Color=3,.Specular=1,.Roughness=1,.Normal=3,.World_Height=1,.Mask=1,.Displacement=1,.Mask4=4,
}

// The outputs a texture of each content type holds.
@(private)
VIRTUAL_TEXTURE_HOLDS :: [8]bit_set[Virtual_Output]{
    {.Base_Color},
    {.Mask4},
    {.Base_Color,.Normal,.Roughness},
    {.Base_Color,.Normal,.Roughness,.Specular},
    {.Base_Color,.Normal,.Roughness,.Specular},
    {.Base_Color,.Normal,.Roughness,.Specular,.Mask},
    {.World_Height},
    {.Displacement},
}

// A sample of a runtime virtual texture: what its writer gives at the point,
// as the texture keeps it (colors and masks from 0 to 1, a unit normal).
@(private)
virtual_texture_sample :: proc(e:^Evaluator,o:Object,output:i32,scope:i32) -> Value {
    g:=e.g
    if output<0 || output>=len(Virtual_Output) {return untranslated(e,o,"the output it is read from does not exist")}
    slot:=Virtual_Output(output)
    kind:=prop_enum(o,"MaterialType",VIRTUAL_TEXTURE_TYPES,0)
    default:=nodes(constant(g,VIRTUAL_OUTPUT_DEFAULTS[slot],VIRTUAL_OUTPUT_WIDTHS[slot]))
    path:=""
    parameter:=strings.has_suffix(object_class(o),"Parameter")
    if parameter {
        if found:=override_find(e,prop_name(o,"ParameterName",""),.Texture,scope);found!=nil {path=found.texture}
    }
    if path=="" {
        if reference:=prop_object(o,"VirtualTexture");reference!=0 {path,_=unreal.reference_path(&o.pkg.p,reference,context.temp_allocator)}
    }
    if path=="" {
        if parameter {return untranslated(e,o,"it names no virtual texture")}
        return default
    }
    holds:=VIRTUAL_TEXTURE_HOLDS
    if slot not_in holds[kind] {return default}
    for name in ([]string{"Coordinates","WorldPosition"}) {
        if input,ok:=prop_input(o,name);ok && input.expression!=0 {return untranslated(e,o,"it samples at another place than its own")}
    }
    if e.writing {return untranslated(e,o,"it reads a virtual texture in what a material writes to one")}
    writer:^Virtual_Texture_Writer
    for &w in e.writers {if strings.equal_fold(w.texture,path) {writer=&w;break}}
    if writer==nil {return untranslated(e,o,fmt.tprintf("no landscape of the import writes %s",path))}
    value:=writer_value(e,o,writer,slot)
    if value.node==NONE {return NO_VALUE}
    n:=convert(g,value.node,VIRTUAL_OUTPUT_WIDTHS[slot])
    #partial switch slot {
    case .Normal:
        n=unary(g,.Normalize,n)
        // Two channels of it: the normal faces up.
        BASE_COLOR_NORMAL_ROUGHNESS :: 2
        if kind==BASE_COLOR_NORMAL_ROUGHNESS {n=append_values(g,swizzle(g,n,{0,1,0,0},2),unary(g,.Abs,component(g,n,2)))}
    case .World_Height:
    case:n=unary(g,.Saturate,n)
    }
    return nodes(n)
}

// What a writer gives an output at the point of the sample o, in a scope of
// its own: the material it writes by (RuntimeVirtualTextureReplace takes its
// VirtualTextureOutput there) with its own parameters, under its name.
@(private)
writer_value :: proc(e:^Evaluator,o:Object,w:^Virtual_Texture_Writer,slot:Virtual_Output) -> Value {
    material,found:=object_find(e.lib,w.material)
    if !found {return untranslated(e,o,fmt.tprintf("%s, the material that writes it, could not be read",w.material))}
    out:=e.overrides.allocator
    chain,chain_error:=chain_read(e.lib,material,out)
    if chain_error.code!=.None {return untranslated(e,o,chain_error.message)}
    base:=chain.material
    inputs:=base
    if data,has_data:=object_child(base,"MaterialEditorOnlyData");has_data {inputs=data}
    // The material translated writes what it reads back with its own values and layers.
    own:=strings.equal_fold(w.material,e.material)
    saved_overrides,saved_stack,saved_layer,saved_layers:=e.overrides,e.stack,e.layer,e.layers
    saved_landscape,saved_coordinates,saved_ue5,saved_prefix,saved_writing:=e.landscape,e.coordinates,e.ue5,e.prefix,e.writing
    defer {
        e.writing=saved_writing
        if !own {
            e.overrides,e.stack,e.layer,e.layers=saved_overrides,saved_stack,saved_layer,saved_layers
            e.landscape,e.coordinates,e.ue5,e.prefix=saved_landscape,saved_coordinates,saved_ue5,saved_prefix
        }
    }
    if !own {
        e.overrides,e.stack,e.layer=chain.overrides,chain.stack,""
        e.layers=make([dynamic]string,out)
        e.landscape,e.coordinates=nil,&w.coordinates
        e.ue5=base.pkg.p.summary.version_ue5>0
        e.prefix=fmt.aprintf("%s.",object_name(material),allocator=out)
    }
    e.writing=true
    // As a translation, twice when it has layers: the first finds them, the
    // second shows the first.
    value:=NO_VALUE
    for pass in 0..<(own?1:2) {
        if pass==1 && len(e.layers)==0 {break}
        append(&e.scopes,Scope{parent=-1})
        value=writer_output(e,base,inputs,slot,i32(len(e.scopes)-1))
    }
    if !own && len(e.layers)>0 {
        note(e,"%s is what %s writes as its layer %s: a program of a mesh does not see the layers painted under it",w.texture,object_name(material),e.layers[0])
    }
    return value
}

// An output of what a material writes to a virtual texture: an input of its
// RuntimeVirtualTextureOutput or, without one, what it shows (its base color,
// specular and roughness, its normal in the world and the height of the point).
@(private)
writer_output :: proc(e:^Evaluator,base,inputs:Object,slot:Virtual_Output,scope:i32) -> Value {
    g:=e.g
    for &item,index in base.pkg.p.exports {
        candidate:=Object{base.pkg,index}
        if item.outer!=unreal.Object_Ref(base.export+1) && !is_editor_data_of(base,item.outer) {continue}
        if object_class(candidate)!="MaterialExpressionRuntimeVirtualTextureOutput" {continue}
        if opacity,ok:=prop_input(candidate,"Opacity");ok && opacity.expression!=0 {
            note(e,"%s writes its virtual texture whole: its opacity is not read",object_name(base))
        }
        node,connected:=pin(e,candidate,VIRTUAL_OUTPUT_NAMES[slot],scope)
        if !connected {node=constant(g,VIRTUAL_OUTPUT_DEFAULTS[slot],VIRTUAL_OUTPUT_WIDTHS[slot])}
        return nodes(node)
    }
    #partial switch slot {
    case .Base_Color,.Specular,.Roughness,.Normal:
        shown:=[4]Attribute{.Base_Color,.Specular,.Roughness,.Normal}
        attribute:=shown[int(slot)]
        roots,_:=material_outputs(e,base,inputs,{attribute},scope)
        n:=roots[attribute]
        if slot!=.Normal || n==NONE {return nodes(n)}
        if !prop_bool(base,"bTangentSpaceNormal",true) {return nodes(n)}
        t,b,v:=tangent_frame(e)
        return nodes(frame_vector(g,convert(g,n,3),t,b,v))
    case .World_Height:
        return nodes(component(g,world_place(e,.World_Position),2))
    }
    return nodes(constant(g,{},VIRTUAL_OUTPUT_WIDTHS[slot]))
}
