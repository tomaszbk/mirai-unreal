package material

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import fx "project:plugins/unreal/editor/material/fixture"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/base"

// Synthetic packages: a material graph built expression by expression.

@(private="file")
Graph_Builder :: struct {p:fx.Package,material:i32}

@(private="file")
material_begin :: proc(name:string,core_version:i32=4) -> (b:Graph_Builder) {
    b.p=fx.package_make()
    b.p.core_version=core_version
    // The material is export 1; its data is set when it is finished.
    b.material=fx.export(&b.p,fx.class(&b.p,"/Script/Engine","Material"),0,name,nil)
    return
}

@(private="file")
expression :: proc(b:^Graph_Builder,class,name:string,w:^fx.Writer) -> i32 {
    module:="/Script/Engine"
    if strings.has_prefix(class,"Landscape") {module="/Script/Landscape"}
    return fx.export(&b.p,fx.class(&b.p,module,strings.concatenate({"MaterialExpression",class},context.temp_allocator)),b.material,name,fx.finish(w))
}

@(private="file")
texture_ref :: proc(b:^Graph_Builder,name:string) -> i32 {
    return fx.external(&b.p,strings.concatenate({"/Game/T/",name},context.temp_allocator),"/Script/Engine","Texture2D",name)
}

@(private="file")
sample_expression :: proc(b:^Graph_Builder,name,texture,sampler:string,uv:i32=0) -> i32 {
    w:=fx.writer(&b.p)
    fx.object_put(&w,"Texture",texture_ref(b,texture))
    if sampler!="" {fx.enum_put(&w,"SamplerType","EMaterialSamplerType",sampler)}
    if uv!=0 {fx.input_put(&w,"Coordinates","ExpressionInput",{expression=uv})}
    return expression(b,"TextureSample",name,&w)
}

@(private="file")
RGB :: [4]bool{true,true,true,false}

@(private="file")
library_with :: proc(lib:^Library,packages:..struct{name:string,bytes:[]u8}) {
    library_init(lib,nil)
    for item in packages {library_add(lib,item.name,item.bytes)}
}

@(private="file")
texture_bytes :: proc(name:string,settings:="TC_Default",srgb:=true) -> []u8 {
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    for &v,i in pixels {v=u8(i*13)}
    return fx.texture_package(strings.concatenate({"/Game/T/",name},context.temp_allocator),name,pixels,4,4,settings,srgb)
}

// Textures, a tint, roughness, metallic and occlusion of one ORM texture and
// a normal map at doubled coordinates: the standard model alone, every map
// a texture as it is.
@(private="file")
standard_material :: proc() -> []u8 {
    b:=material_begin("M_Test")
    uv:=fx.writer(&b.p)
    fx.float_put(&uv,"UTiling",2)
    fx.float_put(&uv,"VTiling",2)
    coordinates:=expression(&b,"TextureCoordinate","UV",&uv)
    albedo:=fx.writer(&b.p)
    fx.object_put(&albedo,"Texture",texture_ref(&b,"T_Albedo"))
    fx.name_property_put(&albedo,"ParameterName","Albedo")
    fx.input_put(&albedo,"Coordinates","ExpressionInput",{expression=coordinates})
    albedo_sample:=expression(&b,"TextureSampleParameter2D","Albedo",&albedo)
    tint:=fx.writer(&b.p)
    fx.name_property_put(&tint,"ParameterName","Tint")
    fx.color_put(&tint,"DefaultValue",{0.5,0.25,1,1})
    tint_parameter:=expression(&b,"VectorParameter","Tint",&tint)
    multiply:=fx.writer(&b.p)
    fx.input_put(&multiply,"A","ExpressionInput",{expression=albedo_sample,mask=RGB})
    fx.input_put(&multiply,"B","ExpressionInput",{expression=tint_parameter,mask=RGB})
    base:=expression(&b,"Multiply","Tinted",&multiply)
    orm:=sample_expression(&b,"ORM","T_ORM","SAMPLERTYPE_Masks",coordinates)
    normal:=sample_expression(&b,"Normal","T_Normal","SAMPLERTYPE_Normal",coordinates)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=base,mask=RGB})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=orm,mask={false,true,false,false}})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=orm,mask={false,false,true,false}})
    fx.input_put(&m,"AmbientOcclusion","ScalarMaterialInput",{expression=orm,mask={true,false,false,false}})
    fx.input_put(&m,"Normal","VectorMaterialInput",{expression=normal,mask=RGB})
    fx.input_put(&m,"Specular","ScalarMaterialInput",{use_constant=true,constant={0.25,0,0,0}})
    b.p.exports[0].data=fx.finish(&m)
    return fx.package_bytes(&b.p,"/Game/M/M_Test")
}

@(test)
a_graph_of_textures_and_constants_is_the_standard_model_with_its_textures_as_they_are :: proc(t:^testing.T) {
    lib:Library
    library_with(&lib,{"/Game/M/M_Test",standard_material()})
    defer library_destroy(&lib)
    material,found:=object_find(&lib,"/Game/M/M_Test.M_Test")
    if !testing.expect(t,found) {return}
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect(t,translated_is_standard(&translated))
    testing.expect_value(t,translated.vertex_colors,Vertex_Colors.Unused)
    info:=&translated.info
    testing.expect_value(t,info.base_color,[3]f32{0.5,0.25,1})
    testing.expect_value(t,info.roughness,f32(1))
    testing.expect_value(t,info.metallic,f32(1))
    // Specular 0.25 is F0 0.02: the IOR of 2%, the factor whole.
    testing.expect(t,abs(info.ior-1.3295)<0.001 && info.specular_factor==1)
    maps:=asset.material_maps(&info.maps)
    for kind in ([]asset.Material_Map_Kind{.Base_Color,.Metallic_Roughness,.Normal,.Occlusion}) {
        testing.expectf(t,maps[kind].scale==[2]f32{2,2} && maps[kind].uv_set==0,"%v placed at %v",kind,maps[kind])
    }
    g:=&translated.graph
    row,direct:=image_direct(g,translated.images[.Base_Color],{true,true,true,false})
    testing.expect(t,direct && g.textures[row].name=="T_Albedo" && g.textures[row].parameter=="Albedo")
    row,direct=image_direct(g,translated.images[.Metallic_Roughness],{true,true,true,false})
    testing.expect(t,direct && g.textures[row].name=="T_ORM" && g.textures[row].sampler==.Masks)
    testing.expect_value(t,translated.images[.Occlusion],translated.images[.Metallic_Roughness])
    row,direct=image_direct(g,translated.images[.Normal],{true,true,true,false})
    testing.expect(t,direct && g.textures[row].sampler==.Normal)
    testing.expect_value(t,len(translated.untranslated),0)
}

// The same graph read from inputs saved as tagged structs, before UE4 4.17.
@(test)
inputs_saved_as_tagged_structs_read_as_native_ones :: proc(t:^testing.T) {
    b:=material_begin("M_Old",0)
    value:=fx.writer(&b.p)
    fx.color_put(&value,"Constant",{0.2,0.4,0.6,1})
    color:=expression(&b,"Constant3Vector","Color",&value)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=color})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Old",fx.package_bytes(&b.p,"/Game/M/M_Old")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Old")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,translated.info.base_color,[3]f32{0.2,0.4,0.6})
}

@(private="file")
switch_material :: proc() -> []u8 {
    b:=material_begin("M_Switch")
    red:=fx.writer(&b.p)
    fx.color_put(&red,"Constant",{1,0,0,1})
    red_value:=expression(&b,"Constant3Vector","Red",&red)
    blue:=fx.writer(&b.p)
    fx.color_put(&blue,"Constant",{0,0,1,1})
    blue_value:=expression(&b,"Constant3Vector","Blue",&blue)
    choice:=fx.writer(&b.p)
    fx.name_property_put(&choice,"ParameterName","UseRed")
    fx.input_put(&choice,"A","ExpressionInput",{expression=red_value})
    fx.input_put(&choice,"B","ExpressionInput",{expression=blue_value})
    switched:=expression(&b,"StaticSwitchParameter","UseRed",&choice)
    rough:=fx.writer(&b.p)
    fx.name_property_put(&rough,"ParameterName","Rough")
    fx.float_put(&rough,"DefaultValue",0.3)
    rough_value:=expression(&b,"ScalarParameter","Rough",&rough)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=switched})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=rough_value})
    b.p.exports[0].data=fx.finish(&m)
    return fx.package_bytes(&b.p,"/Game/M/M_Switch")
}

@(private="file")
parameter_info :: proc(p:^fx.Package,name:string) -> []u8 {
    info:=fx.writer(p)
    fx.name_property_put(&info,"Name",name)
    fx.enum_put(&info,"Association","EMaterialParameterAssociation","GlobalParameter")
    fx.int_put(&info,"Index",-1)
    return fx.end(&info)
}

@(private="file")
instance_package :: proc(name,parent:string,rough:f32,red:bool) -> []u8 {
    p:=fx.package_make()
    instance:=fx.writer(&p)
    fx.object_put(&instance,"Parent",fx.external(&p,"/Game/M/M_Switch","/Script/Engine","Material",parent))
    scalar:=fx.writer(&p)
    fx.struct_put(&scalar,"ParameterInfo","MaterialParameterInfo",parameter_info(&p,"Rough"))
    fx.float_put(&scalar,"ParameterValue",rough)
    fx.structs_put(&instance,"ScalarParameterValues","ScalarParameterValue",{fx.end(&scalar)})
    switch_value:=fx.writer(&p)
    fx.struct_put(&switch_value,"ParameterInfo","MaterialParameterInfo",parameter_info(&p,"UseRed"))
    fx.bool_put(&switch_value,"Value",red)
    fx.bool_put(&switch_value,"bOverride",true)
    statics:=fx.writer(&p)
    fx.structs_put(&statics,"StaticSwitchParameters","StaticSwitchParameter",{fx.end(&switch_value)})
    fx.struct_put(&instance,"StaticParameters","StaticParameterSet",fx.end(&statics))
    fx.export(&p,fx.class(&p,"/Script/Engine","MaterialInstanceConstant"),0,name,fx.finish(&instance))
    return fx.package_bytes(&p,strings.concatenate({"/Game/M/",name},context.temp_allocator))
}

// An instance overrides values and static switches of its parent, and an
// instance of the instance overrides those again: the closest one wins.
@(test)
instances_override_their_parents_values_and_static_switches :: proc(t:^testing.T) {
    lib:Library
    library_with(&lib,
        {"/Game/M/M_Switch",switch_material()},
        {"/Game/M/MI_Red",instance_package("MI_Red","M_Switch",0.8,true)})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Switch")
    base,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&base)
    testing.expect_value(t,base.info.base_color,[3]f32{0,0,1})
    testing.expect_value(t,base.info.roughness,f32(0.3))
    instance,_:=object_find(&lib,"/Game/M/MI_Red")
    red,red_error:=translate(&lib,instance)
    if !testing.expect_value(t,red_error.code,Error_Code.None) {return}
    defer translated_destroy(&red)
    testing.expect_value(t,red.info.base_color,[3]f32{1,0,0})
    testing.expect_value(t,red.info.roughness,f32(0.8))
    testing.expect_value(t,red.material,"M_Switch")
}

@(private="file")
GUID_IN :: [16]u8{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16}
@(private="file")
GUID_OUT :: [16]u8{16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1}

// MF_Double: its input times two.
@(private="file")
function_package :: proc() -> []u8 {
    p:=fx.package_make()
    function:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialFunction"),0,"MF_Double",nil)
    input:=fx.writer(&p)
    fx.guid_put(&input,"Id",GUID_IN)
    fx.name_property_put(&input,"InputName","In")
    fx.enum_put(&input,"InputType","EFunctionInputType","FunctionInput_Scalar")
    input_expression:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionFunctionInput"),function,"MaterialExpressionFunctionInput_0",fx.finish(&input))
    double:=fx.writer(&p)
    fx.input_put(&double,"A","ExpressionInput",{expression=input_expression})
    fx.float_put(&double,"ConstB",2)
    product:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionMultiply"),function,"MaterialExpressionMultiply_0",fx.finish(&double))
    output:=fx.writer(&p)
    fx.guid_put(&output,"Id",GUID_OUT)
    fx.name_property_put(&output,"OutputName","Out")
    fx.input_put(&output,"A","ExpressionInput",{expression=product})
    fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionFunctionOutput"),function,"MaterialExpressionFunctionOutput_0",fx.finish(&output))
    w:=fx.writer(&p)
    p.exports[0].data=fx.finish(&w)
    return fx.package_bytes(&p,"/Game/F/MF_Double")
}

// A function is expanded where it is called, its inputs bound by their ids,
// once for each call.
@(test)
material_functions_are_expanded_where_they_are_called :: proc(t:^testing.T) {
    b:=material_begin("M_Call")
    quarter:=fx.writer(&b.p)
    fx.float_put(&quarter,"R",0.25)
    constant_value:=expression(&b,"Constant","Quarter",&quarter)
    calls:[2]i32
    function_ref:=fx.external(&b.p,"/Game/F/MF_Double","/Script/Engine","MaterialFunction","MF_Double")
    for &call,i in calls {
        argument:=fx.writer(&b.p)
        fx.guid_put(&argument,"ExpressionInputId",GUID_IN)
        fx.input_put(&argument,"Input","ExpressionInput",{expression=i==0?constant_value:calls[0]})
        result:=fx.writer(&b.p)
        fx.guid_put(&result,"ExpressionOutputId",GUID_OUT)
        w:=fx.writer(&b.p)
        fx.object_put(&w,"MaterialFunction",function_ref)
        fx.structs_put(&w,"FunctionInputs","FunctionExpressionInput",{fx.end(&argument)})
        fx.structs_put(&w,"FunctionOutputs","FunctionExpressionOutput",{fx.end(&result)})
        call=expression(&b,"MaterialFunctionCall",i==0?"Call":"Again",&w)
    }
    m:=fx.writer(&b.p)
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=calls[0]})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=calls[1]})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Call",fx.package_bytes(&b.p,"/Game/M/M_Call")},{"/Game/F/MF_Double",function_package()})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Call")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,translated.info.roughness,f32(0.5))
    testing.expect_value(t,translated.info.metallic,f32(1))
}

// Grass is a color and Rock a texture: each layer is a material of its own.
@(test)
the_layers_of_a_landscape_material_are_materials_of_their_own :: proc(t:^testing.T) {
    b:=material_begin("M_Landscape")
    green:=fx.writer(&b.p)
    fx.color_put(&green,"Constant",{0.1,0.6,0.1,1})
    grass:=expression(&b,"Constant3Vector","Grass",&green)
    rock:=sample_expression(&b,"Rock","T_Rock","")
    layers:=[2][]u8{}
    for &layer,i in layers {
        w:=fx.writer(&b.p)
        fx.name_property_put(&w,"LayerName",i==0?"Grass":"Rock")
        fx.enum_put(&w,"BlendType","ELandscapeLayerBlendType","LB_WeightBlend")
        fx.input_put(&w,"LayerInput","ExpressionInput",{expression=i==0?grass:rock,mask=i==0?{}:RGB})
        layer=fx.end(&w)
    }
    blend:=fx.writer(&b.p)
    fx.structs_put(&blend,"Layers","LayerBlendInput",layers[:])
    blended:=expression(&b,"LandscapeLayerBlend","Blend",&blend)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=blended})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Landscape",fx.package_bytes(&b.p,"/Game/M/M_Landscape")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Landscape")
    found,error:=landscape_layers(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer landscape_layers_destroy(found)
    if !testing.expect_value(t,len(found),2) {return}
    testing.expect_value(t,found[0].name,"Grass")
    testing.expect_value(t,found[0].material.info.base_color,[3]f32{0.1,0.6,0.1})
    testing.expect_value(t,found[0].material.images[.Base_Color],MAP_NONE)
    testing.expect_value(t,found[1].name,"Rock")
    testing.expect(t,found[1].material.images[.Base_Color]!=MAP_NONE)
    testing.expect_value(t,found[1].material.info.base_color,[3]f32{1,1,1})
    // A material without layer expressions has none.
    lib2:Library
    library_with(&lib2,{"/Game/M/M_Test",standard_material()})
    defer library_destroy(&lib2)
    plain,_:=object_find(&lib2,"/Game/M/M_Test")
    none,none_error:=landscape_layers(&lib2,plain)
    testing.expect(t,none_error.code==.None && len(none)==0)
}

// Coordinates that move with time are a program; an instance that only
// changes values shares the program of its parent.
@(test)
moving_coordinates_are_a_program_with_the_parameters_of_the_material :: proc(t:^testing.T) {
    b:=material_begin("M_Flow")
    pan:=fx.writer(&b.p)
    fx.float_put(&pan,"SpeedX",0.1)
    panner:=expression(&b,"Panner","Pan",&pan)
    water:=sample_expression(&b,"Water","T_Water","",panner)
    gloss:=fx.writer(&b.p)
    fx.name_property_put(&gloss,"ParameterName","Gloss")
    fx.float_put(&gloss,"DefaultValue",0.2)
    gloss_value:=expression(&b,"ScalarParameter","Gloss",&gloss)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=water,mask=RGB})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=gloss_value})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Flow",fx.package_bytes(&b.p,"/Game/M/M_Flow")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Flow")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect(t,!translated_is_standard(&translated))
    program:=&translated.program
    testing.expect(t,strings.has_prefix(program.name,"Unreal_M_Flow_"))
    testing.expect_value(t,base.text_get(translated.info.program[:]),program.name)
    testing.expect(t,strings.contains(program.source,"ctx.time") && strings.contains(program.source,"mirai_sample_texture"))
    testing.expect(t,strings.contains(program.source,"//! parameter p0_Gloss {\"default\":0.2}"))
    if testing.expect_value(t,len(program.parameters),2) {
        testing.expect(t,program.parameters[0].kind==.Texture && program.parameters[1].value.x==0.2)
    }
    for image in translated.images {testing.expect_value(t,image,MAP_NONE)}
}

// A value of the context Mirai programs do not have is counted by its class.
@(test)
what_cannot_be_translated_is_counted_by_its_expression_class :: proc(t:^testing.T) {
    b:=material_begin("M_Rim")
    w:=fx.writer(&b.p)
    rim:=expression(&b,"SceneColor","Rim",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=rim})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Rim",fx.package_bytes(&b.p,"/Game/M/M_Rim")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Rim")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    if testing.expect_value(t,len(translated.untranslated),1) {
        testing.expect_value(t,translated.untranslated[0],Untranslated{"MaterialExpressionSceneColor",1})
    }
    testing.expect(t,translated_is_standard(&translated) && translated.info.emission==[3]f32{})
}

// What fakes the view sees the surface head on, and what undoes the exposure
// leaves the emission relative to it.
@(test)
the_view_is_taken_head_on_and_eye_adaptation_makes_emission_relative :: proc(t:^testing.T) {
    b:=material_begin("M_Glow")
    w:=fx.writer(&b.p)
    view:=expression(&b,"CameraVectorWS","View",&w)
    w=fx.writer(&b.p)
    inverse:=expression(&b,"EyeAdaptationInverse","Inverse",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=view})
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=inverse})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Glow",fx.package_bytes(&b.p,"/Game/M/M_Glow")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Glow")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    testing.expect_value(t,translated.info.emission_mode,asset.Emission_Mode.Relative)
    testing.expect(t,!translated_is_standard(&translated),"a base color of the normal needs a program")
}

// A two-sided Subsurface material reflects its base color and sends its
// SubsurfaceColor through: a diffuse transmission that splits the light
// between the two, here half each. One-sided, the scattered light is part of
// the reflection.
@(test)
subsurface_on_a_thin_surface_is_diffuse_transmission :: proc(t:^testing.T) {
    leaf :: proc(two_sided:bool) -> []u8 {
        b:=material_begin("M_Leaf")
        m:=fx.writer(&b.p)
        fx.enum_put(&m,"ShadingModel","EMaterialShadingModel","MSM_Subsurface")
        fx.bool_put(&m,"TwoSided",two_sided)
        fx.input_put(&m,"BaseColor","ColorMaterialInput",{use_constant=true,constant={0.5,0.5,0.5,1}})
        fx.input_put(&m,"SubsurfaceColor","ColorMaterialInput",{use_constant=true,constant={0.25,0.5,0.25,1}})
        b.p.exports[0].data=fx.finish(&m)
        return fx.package_bytes(&b.p,"/Game/M/M_Leaf")
    }
    for two_sided in ([]bool{true,false}) {
        lib:Library
        library_with(&lib,{"/Game/M/M_Leaf",leaf(two_sided)})
        defer library_destroy(&lib)
        material,_:=object_find(&lib,"/Game/M/M_Leaf")
        translated,error:=translate(&lib,material)
        if !testing.expect_value(t,error.code,Error_Code.None) {return}
        defer translated_destroy(&translated)
        transmission:=translated.info.diffuse_transmission
        if two_sided {
            testing.expectf(t,abs(transmission.weight-0.5)<1e-5,"weight %v",transmission.weight)
            testing.expectf(t,abs(transmission.color.x-0.5)<1e-5 && abs(transmission.color.y-1)<1e-5,"color %v",transmission.color)
            testing.expectf(t,abs(translated.info.base_color.x-1)<1e-5,"base color %v",translated.info.base_color)
        } else {
            testing.expect_value(t,transmission.weight,f32(0))
        }
    }
}

// Unreal's Specular at its default is IOR 1.5; above 0.25 an IOR alone,
// below it the IOR of 2% with a factor.
@(test)
unreal_specular_is_an_ior_and_below_two_percent_a_factor :: proc(t:^testing.T) {
    ior,factor:=specular_ior(0.5)
    testing.expect(t,abs(ior-1.5)<1e-5 && factor==1)
    ior,factor=specular_ior(1)
    testing.expect(t,abs(ior-SPECULAR_FULL_IOR)<1e-4 && factor==1)
    ior,factor=specular_ior(0.125)
    f0:=math.pow((ior-1)/(ior+1),2)*factor
    testing.expect(t,abs(f0-0.01)<1e-5 && abs(factor-0.5)<1e-5)
}

// An image is the value of its nodes at each texel: here one minus a channel
// and a constant.
@(test)
images_are_baked_texel_by_texel_from_the_graph :: proc(t:^testing.T) {
    g:Graph
    graph_init(&g,context.temp_allocator)
    tex:=texture(&g,{path="/Game/T/T.T",name="T"})
    uv:=context_value(&g,.UV,2,0)
    s:=sample(&g,tex,uv)
    rough:=binary(&g,.Sub,scalar(&g,1),component(&g,s,0))
    pixels:=Pixels{2,1,{{0.25,0,0,1},{1,0,0,1}}}
    image:=MAP_NONE
    image.channels[1]=rough
    image.channels[2]=scalar(&g,0.5)
    sources:=[]^Pixels{&pixels}
    data,width,height,_:=image_bake(&g,image,{},sources,false,context.temp_allocator)
    testing.expect(t,width==2 && height==1)
    // Texel centers read between the two texels, wrapping.
    testing.expect_value(t,data[1],u8(math.round(f32(0.75*255))))
    testing.expect_value(t,data[2],u8(128))
    testing.expect_value(t,data[0],u8(255))
}

// A damaged material package translates or is refused, never a crash.
@(test)
damaged_material_packages_translate_or_are_refused :: proc(t:^testing.T) {
    bytes:=slice.clone(standard_material())
    defer delete(bytes)
    free_all(context.temp_allocator)
    attempt :: proc(bytes:[]u8) -> bool {
        lib:Library
        library_init(&lib,nil)
        defer library_destroy(&lib)
        library_add(&lib,"/Game/M/M_Test",bytes)
        material,found:=object_find(&lib,"/Game/M/M_Test.M_Test")
        if !found {return false}
        translated,error:=translate(&lib,material)
        defer translated_destroy(&translated)
        return error.code==.None
    }
    testing.expect(t,attempt(bytes))
    damaged:=make([]u8,len(bytes))
    defer delete(damaged)
    for length:=0;length<len(bytes);length+=7 {
        attempt(bytes[:length])
        free_all(context.temp_allocator)
    }
    for position in 0..<len(bytes) {
        for value in ([2]u8{0xff,bytes[position]+1}) {
            copy(damaged,bytes)
            damaged[position]=value
            attempt(damaged)
        }
        free_all(context.temp_allocator)
    }
}

// A vertex interpolator between a constant color and the base color: the
// color, computed per pixel.
@(test)
a_vertex_interpolator_passes_its_input_through :: proc(t:^testing.T) {
    b:=material_begin("M_Interpolated")
    color:=fx.writer(&b.p)
    fx.color_put(&color,"Constant",{0.2,0.4,0.6,1})
    constant:=expression(&b,"Constant3Vector","Color",&color)
    interpolate:=fx.writer(&b.p)
    fx.input_put(&interpolate,"Input","ExpressionInput",{expression=constant,mask=RGB})
    interpolated:=expression(&b,"VertexInterpolator","Interpolated",&interpolate)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=interpolated,mask=RGB})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Interpolated",fx.package_bytes(&b.p,"/Game/M/M_Interpolated")})
    defer library_destroy(&lib)
    material,found:=object_find(&lib,"/Game/M/M_Interpolated.M_Interpolated")
    if !testing.expect(t,found) {return}
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect(t,abs(translated.info.base_color.g-0.4)<1e-4,"the color it interpolates")
    testing.expect_value(t,len(translated.untranslated),0)
}

// A base color from the custom data of an instance: its floats with them,
// the default without them, and the material says it reads them.
@(test)
per_instance_custom_data_is_the_value_of_the_instance_or_its_default :: proc(t:^testing.T) {
    b:=material_begin("M_Custom")
    data:=fx.writer(&b.p)
    fx.int_put(&data,"DataIndex",1)
    fx.color_put(&data,"ConstDefaultValue",{0.9,0.8,0.7,1})
    custom:=expression(&b,"PerInstanceCustomData3Vector","Custom",&data)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=custom,mask=RGB})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Custom",fx.package_bytes(&b.p,"/Game/M/M_Custom")})
    defer library_destroy(&lib)
    material,found:=object_find(&lib,"/Game/M/M_Custom.M_Custom")
    if !testing.expect(t,found) {return}
    with,error:=translate(&lib,material,{custom_data={0,0.1,0.2,0.3}})
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&with)
    testing.expect(t,with.reads_custom_data)
    testing.expect(t,abs(with.info.base_color.r-0.1)<1e-4 && abs(with.info.base_color.b-0.3)<1e-4,"the floats from DataIndex on")
    without,_:=translate(&lib,material)
    defer translated_destroy(&without)
    testing.expect(t,abs(without.info.base_color.g-0.8)<1e-4,"its default")
}

// The texts a TextRenderComponent keeps: a localized one (base history) and
// a culture invariant one read as the string they show.
@(test)
text_properties_read_as_the_string_they_show :: proc(t:^testing.T) {
    b:=material_begin("M_Text")
    m:=fx.writer(&b.p)
    localized:=fx.writer(&b.p)
    fx.u32_put(&localized,0)          // flags
    append(&localized.bytes,0)        // history: base
    fx.text_put(&localized,"Namespace")
    fx.text_put(&localized,"Key")
    fx.text_put(&localized,"User and System Bindings")
    fx.tag_put(&m,"Title","TextProperty",len(localized.bytes))
    append(&m.bytes,..localized.bytes[:])
    invariant:=fx.writer(&b.p)
    fx.u32_put(&invariant,0)
    append(&invariant.bytes,0xff)     // history: none
    fx.u32_put(&invariant,1)          // it has a culture invariant string
    fx.text_put(&invariant,"Niagara")
    fx.tag_put(&m,"Label","TextProperty",len(invariant.bytes))
    append(&m.bytes,..invariant.bytes[:])
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Text",fx.package_bytes(&b.p,"/Game/M/M_Text")})
    defer library_destroy(&lib)
    object,found:=object_find(&lib,"/Game/M/M_Text.M_Text")
    if !testing.expect(t,found) {return}
    list,error:=object_properties(object)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None) {return}
    for expected in ([2][2]string{{"Title","User and System Bindings"},{"Label","Niagara"}}) {
        property:=unreal.property_find(&object.pkg.p,list,expected[0])
        if !testing.expectf(t,property!=nil,"%s is there",expected[0]) {continue}
        value,value_error:=unreal.property_value(&object.pkg.p,property,context.temp_allocator)
        testing.expect_value(t,value_error.code,unreal.Error_Code.None)
        testing.expect_value(t,value.text,expected[1])
    }
}

// An offset of minus the world position takes every point to the origin:
// the surface is masked out whole, and the offset counts as translated.
@(test)
an_offset_that_collapses_the_surface_hides_it :: proc(t:^testing.T) {
    b:=material_begin("M_Hide")
    w:=fx.writer(&b.p)
    position:=expression(&b,"WorldPosition","Position",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"A","ExpressionInput",{expression=position})
    fx.float_put(&w,"ConstB",-1)
    collapse:=expression(&b,"Multiply","Collapse",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"WorldPositionOffset","VectorMaterialInput",{expression=collapse})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Hide",fx.package_bytes(&b.p,"/Game/M/M_Hide")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Hide")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect(t,translated_is_standard(&translated),"a hidden surface is the standard model")
    testing.expect_value(t,translated.info.alpha_mode,asset.Alpha_Mode.Mask)
    testing.expect_value(t,translated.info.opacity,0)
    for text in translated.notes {testing.expectf(t,!strings.contains(text,"is not translated"),"note: %s",text)}
}

@(private="file")
attribute_guids_put :: proc(w:^fx.Writer,property:string,attributes:[]Attribute) {
    bodies:=make([][]u8,len(attributes),context.temp_allocator)
    for attribute,i in attributes {
        guid:=unreal.guid_from_words(ATTRIBUTE_GUIDS[attribute])
        bodies[i]=slice.clone(guid[:],context.temp_allocator)
    }
    fx.structs_put(w,property,"Guid",bodies)
}

@(private="file")
inputs_put :: proc(w:^fx.Writer,property:string,inputs:[]fx.Input) {
    bodies:=make([][]u8,len(inputs),context.temp_allocator)
    for input,i in inputs {
        body:=fx.writer(w.p)
        fx.i32_put(&body,input.expression)
        fx.i32_put(&body,input.output)
        fx.name_put(&body,"None")
        for _ in 0..<5 {fx.u32_put(&body,0)}
        bodies[i]=body.bytes[:]
    }
    fx.structs_put(w,property,"ExpressionInput",bodies)
}

// Material attributes made, set on and broken: what SetMaterialAttributes
// does not set is what its attributes in (Inputs[0]) give, and the outputs
// of BreakMaterialAttributes past the customized UVs are the attributes
// they name.
@(test)
set_material_attributes_keeps_the_attributes_it_does_not_set :: proc(t:^testing.T) {
    b:=material_begin("M_Attributes")
    albedo:=sample_expression(&b,"Albedo","T_Albedo","")
    w:=fx.writer(&b.p)
    fx.input_put(&w,"BaseColor","ExpressionInput",{expression=albedo,mask=RGB})
    made:=expression(&b,"MakeMaterialAttributes","Made",&w)
    w=fx.writer(&b.p)
    fx.float_put(&w,"R",0.7)
    seven:=expression(&b,"Constant","Seven",&w)
    w=fx.writer(&b.p)
    fx.float_put(&w,"R",0.25)
    quarter:=expression(&b,"Constant","Quarter",&w)
    w=fx.writer(&b.p)
    inputs_put(&w,"Inputs",{{expression=made},{expression=quarter}})
    attribute_guids_put(&w,"AttributeSetTypes",{.Roughness})
    set:=expression(&b,"SetMaterialAttributes","Set",&w)
    // Displacement, output 26, of attributes whose displacement is 0.7.
    w=fx.writer(&b.p)
    fx.input_put(&w,"Displacement","ExpressionInput",{expression=seven})
    displaced:=expression(&b,"MakeMaterialAttributes","Displaced",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"MaterialAttributes","MaterialAttributesInput",{expression=displaced})
    broken:=expression(&b,"BreakMaterialAttributes","Broken",&w)
    w=fx.writer(&b.p)
    inputs_put(&w,"Inputs",{{expression=set},{expression=broken,output=26}})
    attribute_guids_put(&w,"AttributeSetTypes",{.Metallic})
    last:=expression(&b,"SetMaterialAttributes","Last",&w)
    m:=fx.writer(&b.p)
    fx.bool_put(&m,"bUseMaterialAttributes",true)
    fx.input_put(&m,"MaterialAttributes","MaterialAttributesInput",{expression=last})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Attributes",fx.package_bytes(&b.p,"/Game/M/M_Attributes")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Attributes")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    testing.expect(t,translated_is_standard(&translated))
    g:=&translated.graph
    row,direct:=image_direct(g,translated.images[.Base_Color],{true,true,true,false})
    testing.expect(t,direct && g.textures[row].name=="T_Albedo","the base color of the attributes it sets on")
    testing.expect_value(t,translated.info.base_color,[3]f32{1,1,1})
    testing.expect_value(t,translated.info.roughness,f32(0.25))
    testing.expect(t,abs(translated.info.metallic-0.7)<1e-6,"the displacement Break gives")
}

// Without virtual textures, Unreal takes the branch of a platform that has
// none; a Landscape draws where its terrain has no holes.
@(test)
virtual_texture_switches_take_the_branch_without_virtual_textures :: proc(t:^testing.T) {
    b:=material_begin("M_Virtual")
    w:=fx.writer(&b.p)
    radius:=expression(&b,"ObjectRadius","Radius",&w)
    albedo:=sample_expression(&b,"Albedo","T_Albedo","")
    w=fx.writer(&b.p)
    fx.input_put(&w,"No","ExpressionInput",{expression=albedo,mask=RGB})
    fx.input_put(&w,"Yes","ExpressionInput",{expression=radius})
    feature:=expression(&b,"VirtualTextureFeatureSwitch","Feature",&w)
    w=fx.writer(&b.p)
    fx.float_put(&w,"R",0.3)
    rough:=expression(&b,"Constant","Rough",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Default","ExpressionInput",{expression=rough})
    fx.input_put(&w,"VirtualTextureOutput","ExpressionInput",{expression=radius})
    replace:=expression(&b,"RuntimeVirtualTextureReplace","Replace",&w)
    w=fx.writer(&b.p)
    visible:=expression(&b,"LandscapeVisibilityMask","Visible",&w)
    m:=fx.writer(&b.p)
    fx.enum_put(&m,"BlendMode","EBlendMode","BLEND_Masked")
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=feature})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=replace})
    fx.input_put(&m,"OpacityMask","ScalarMaterialInput",{expression=visible})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Virtual",fx.package_bytes(&b.p,"/Game/M/M_Virtual")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Virtual")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    testing.expect(t,translated_is_standard(&translated))
    g:=&translated.graph
    row,direct:=image_direct(g,translated.images[.Base_Color],{true,true,true,false})
    testing.expect(t,direct && g.textures[row].name=="T_Albedo")
    testing.expect(t,abs(translated.info.roughness-0.3)<1e-6)
    testing.expect_value(t,translated.info.opacity,f32(1))
}

// A vector goes between tangent, object and world space by the tangent
// frame and the axes of the object a program sees.
@(test)
vectors_go_between_tangent_object_and_world_space_in_a_program :: proc(t:^testing.T) {
    b:=material_begin("M_Frame")
    normal:=sample_expression(&b,"Normal","T_Normal","SAMPLERTYPE_Normal")
    w:=fx.writer(&b.p)
    fx.input_put(&w,"Input","ExpressionInput",{expression=normal,mask=RGB})
    to_world:=expression(&b,"Transform","ToWorld",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Input","ExpressionInput",{expression=to_world})
    fx.enum_put(&w,"TransformSourceType","EMaterialVectorCoordTransformSource","TRANSFORMSOURCE_World")
    fx.enum_put(&w,"TransformType","EMaterialVectorCoordTransform","TRANSFORM_Tangent")
    back:=expression(&b,"Transform","Back",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Input","ExpressionInput",{expression=to_world})
    fx.enum_put(&w,"TransformSourceType","EMaterialVectorCoordTransformSource","TRANSFORMSOURCE_Local")
    local:=expression(&b,"Transform","Local",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=to_world})
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=back})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=local,mask={true,false,false,false}})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Frame",fx.package_bytes(&b.p,"/Game/M/M_Frame")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Frame")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    testing.expect(t,!translated_is_standard(&translated))
    source:=translated.program.source
    testing.expect(t,strings.contains(source,"unreal_bitangent(ctx)") && strings.contains(source,"ctx.tangent.z"),"the tangent frame")
    testing.expect(t,strings.contains(source,"dot("),"world to tangent")
    testing.expect(t,strings.contains(source,"unreal_object_axis(ctx,0)") && strings.contains(source,"unreal_object_axis(ctx,2)"),"the axes of the object")
}

// An alpha of another width than the ends lerps by its first component, as Unreal.
@(test)
a_lerp_alpha_of_another_width_is_its_first_component :: proc(t:^testing.T) {
    g:Graph
    graph_init(&g,context.temp_allocator)
    a:=context_value(&g,.Vertex_Color,4)
    alpha:=constant(&g,{0.25,0.5,0.75,0},3)
    n:=ternary(&g,.Lerp,constant(&g,{},4),a,alpha)
    if !testing.expect(t,n!=NONE) {return}
    testing.expect_value(t,width_of(&g,n),4)
    value,ok:=evaluate_constant(&g,g.nodes[n].args[2])
    testing.expect(t,ok && value.x==0.25 && width_of(&g,g.nodes[n].args[2])==1)
}

// The object of the point: the centre and radius of its bounds, its pivot
// and positions between its space and the world.
@(test)
the_object_and_its_positions_are_seen_by_a_program :: proc(t:^testing.T) {
    b:=material_begin("M_Object")
    w:=fx.writer(&b.p)
    fx.color_put(&w,"Constant",{100,0,0,1})
    forward:=expression(&b,"Constant3Vector","Forward",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Input","ExpressionInput",{expression=forward})
    fx.enum_put(&w,"TransformType","EMaterialPositionTransformSource","TRANSFORMPOSSOURCE_World")
    ahead:=expression(&b,"TransformPosition","Ahead",&w)
    w=fx.writer(&b.p)
    world:=expression(&b,"WorldPosition","World",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Input","ExpressionInput",{expression=world})
    fx.enum_put(&w,"TransformSourceType","EMaterialPositionTransformSource","TRANSFORMPOSSOURCE_World")
    local:=expression(&b,"TransformPosition","Local",&w)
    w=fx.writer(&b.p)
    center:=expression(&b,"ObjectPositionWS","Center",&w)
    w=fx.writer(&b.p)
    radius:=expression(&b,"ObjectRadius","Radius",&w)
    w=fx.writer(&b.p)
    pivot:=expression(&b,"ActorPositionWS","Pivot",&w)
    w=fx.writer(&b.p)
    up:=expression(&b,"ObjectOrientation","Up",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=ahead})
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=center})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=radius})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=local,mask={true,false,false,false}})
    fx.input_put(&m,"Specular","ScalarMaterialInput",{expression=pivot,mask={false,true,false,false}})
    fx.input_put(&m,"Normal","VectorMaterialInput",{expression=up})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Object",fx.package_bytes(&b.p,"/Game/M/M_Object")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Object")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    if !testing.expect(t,!translated_is_standard(&translated)) {return}
    source:=translated.program.source
    testing.expect(t,strings.contains(source,"unreal_point(ctx.object_center)"),"ObjectPositionWS is the centre of the bounds")
    testing.expect(t,strings.contains(source,"ctx.object_radius*100.0"),"ObjectRadius in centimetres")
    testing.expect(t,strings.contains(source,"unreal_point(ctx.object_position)"),"the pivot")
    for axis in 0..<3 {testing.expect(t,strings.contains(source,fmt.tprintf("unreal_object_axis(ctx,%d)",axis)),"the axes of the object")}
    testing.expect(t,strings.contains(source,"ctx.world_position"),"the world position into the object")
}

// A material that multiplies its base color by the vertex colors is the
// standard model, which multiplies by them; one that blends by them is a
// program that reads them, its base color not multiplied.
@(test)
vertex_colors_as_data_are_read_by_a_program :: proc(t:^testing.T) {
    for blends in ([]bool{false,true}) {
        b:=material_begin("M_Painted")
        w:=fx.writer(&b.p)
        colors:=expression(&b,"VertexColor","Colors",&w)
        w=fx.writer(&b.p)
        fx.color_put(&w,"Constant",{0.2,0.4,0.6,1})
        tint:=expression(&b,"Constant3Vector","Tint",&w)
        w=fx.writer(&b.p)
        fx.input_put(&w,"A","ExpressionInput",{expression=tint})
        fx.input_put(&w,"B","ExpressionInput",{expression=colors,mask=RGB})
        if blends {fx.input_put(&w,"Alpha","ExpressionInput",{expression=colors,mask={false,false,false,true}})}
        mixed:=expression(&b,blends?"LinearInterpolate":"Multiply","Mixed",&w)
        m:=fx.writer(&b.p)
        fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=mixed})
        b.p.exports[0].data=fx.finish(&m)
        lib:Library
        library_with(&lib,{"/Game/M/M_Painted",fx.package_bytes(&b.p,"/Game/M/M_Painted")})
        defer library_destroy(&lib)
        material,_:=object_find(&lib,"/Game/M/M_Painted")
        translated,error:=translate(&lib,material)
        if !testing.expect_value(t,error.code,Error_Code.None) {return}
        defer translated_destroy(&translated)
        if !blends {
            testing.expect(t,translated_is_standard(&translated))
            testing.expect_value(t,translated.vertex_colors,Vertex_Colors.Multiply_Base_Color)
            testing.expect(t,abs(translated.info.base_color.g-0.4)<1e-6)
            continue
        }
        if !testing.expect(t,!translated_is_standard(&translated)) {continue}
        testing.expect_value(t,translated.vertex_colors,Vertex_Colors.Program)
        testing.expect(t,strings.contains(translated.program.source,"ctx.vertex_color"))
    }
}

// Translated whole for a terrain, a landscape material weighs each of its
// layers by the weight of the layer of the terrain that shows it, and its
// coordinates come from the place of the point in the world.
@(test)
a_landscape_material_whole_reads_the_weights_of_its_terrain :: proc(t:^testing.T) {
    b:=material_begin("M_Landscape")
    green:=fx.writer(&b.p)
    fx.color_put(&green,"Constant",{0.1,0.6,0.1,1})
    grass:=expression(&b,"Constant3Vector","Grass",&green)
    coords:=fx.writer(&b.p)
    fx.float_put(&coords,"MappingScale",4)
    layer_coords:=expression(&b,"LandscapeLayerCoords","Coords",&coords)
    rock:=sample_expression(&b,"Rock","T_Rock","",layer_coords)
    layers:=[3][]u8{}
    names:=[3]string{"Grass","Rock","Sand"}
    for &layer,i in layers {
        w:=fx.writer(&b.p)
        fx.name_property_put(&w,"LayerName",names[i])
        fx.enum_put(&w,"BlendType","ELandscapeLayerBlendType",i==1?"LB_HeightBlend":"LB_WeightBlend")
        if i<2 {fx.input_put(&w,"LayerInput","ExpressionInput",{expression=i==0?grass:rock,mask=i==0?{}:RGB})}
        layer=fx.end(&w)
    }
    blend:=fx.writer(&b.p)
    fx.structs_put(&blend,"Layers","LayerBlendInput",layers[:])
    blended:=expression(&b,"LandscapeLayerBlend","Blend",&blend)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=blended})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Landscape",fx.package_bytes(&b.p,"/Game/M/M_Landscape")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Landscape")
    // The terrain shows Rock in its first layer and Grass in its second; Sand it does not have.
    mapping:=Landscape_Mapping{layers={"Rock","Grass","",""},coordinates={{0.01,0,0,8},{0,-0.01,0,16}}}
    translated,error:=translate(&lib,material,{landscape=&mapping})
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    if !testing.expect(t,!translated_is_standard(&translated)) {return}
    source:=translated.program.source
    testing.expect(t,strings.contains(source,"float4(ctx.uv0,ctx.uv1)"),"the weights of the terrain")
    testing.expect(t,strings.contains(source,").x") && strings.contains(source,").y"),"each layer by the weight of its layer of the terrain")
    testing.expect(t,!strings.contains(source,"ctx.uv0;"),"no uv set is the coordinates of the landscape")
    testing.expect(t,strings.contains(source,"ctx.world_position"),"its coordinates from the world")
    branch:=strings.index(source,"if (")
    sampled:=strings.index(source,"mirai_sample_texture(ctx,")
    testing.expect(t,branch>=0 && sampled>branch && sampled<strings.index(source[branch:],"    }\n")+branch,"Rock is read only where its layer is painted")
    for n in translated.notes {testing.expect(t,!strings.contains(n,"shown as its layer"),n)}
}

// The plugins of the engine are walked only for a package that only a plugin can hold.
@(test)
engine_plugins_mount_when_a_package_needs_them :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-material-plugins-%d",directory,os.get_pid())
    os.remove_all(root)
    defer os.remove_all(root)
    plugin:=fmt.tprintf("%s/Engine/Plugins/FX/Spark",root)
    os.make_directory_all(fmt.tprintf("%s/Content",plugin))
    os.make_directory_all(fmt.tprintf("%s/Engine/Content",root))
    _=os.write_entire_file(fmt.tprintf("%s/Spark.uplugin",plugin),"{}")
    _=os.write_entire_file(fmt.tprintf("%s/Content/M_Spark.uasset",plugin),"package")
    lib:Library
    library_init(&lib,[]unreal.Source_Mount{{"/Engine",fmt.tprintf("%s/Engine/Content",root)}},plugins_pending=true)
    defer library_destroy(&lib)
    testing.expect(t,library_open(&lib,"/Engine/M_Missing")==nil && library_open(&lib,"/Game/M_Missing")==nil && len(lib.mounts)==1 && lib.plugins_pending)
    opened:=library_open(&lib,"/Spark/M_Spark")
    testing.expect(t,opened!=nil && opened.error.code!=.None && len(lib.mounts)==2 && lib.mounts[1].package_prefix=="/Spark")
    testing.expect(t,library_open(&lib,"/Other/M_Other")==nil && len(lib.mounts)==2)
}

@(private="file")
translate_one :: proc(t:^testing.T,lib:^Library,path:string) -> (translated:Translated_Material,ok:bool) {
    material,_:=object_find(lib,path)
    error:Error
    translated,error=translate(lib,material)
    return translated,testing.expect_value(t,error.code,Error_Code.None)
}

// Where the point is in the image and how deep, the opaque scene behind it,
// the size of the box around the object and the data a particle gives (its
// Dynamic Parameter, or the default where it gives none), its random value and
// its radius are seen by a program.
@(test)
the_screen_the_depth_and_the_bounds_are_seen_by_a_program :: proc(t:^testing.T) {
    b:=material_begin("M_Screen")
    w:=fx.writer(&b.p)
    screen:=expression(&b,"ScreenPosition","Screen",&w)
    w=fx.writer(&b.p)
    depth:=expression(&b,"PixelDepth","Depth",&w)
    w=fx.writer(&b.p)
    fx.float_put(&w,"FadeDistanceDefault",50)
    fade:=expression(&b,"DepthFade","Fade",&w)
    w=fx.writer(&b.p)
    bounds:=expression(&b,"ObjectBounds","Bounds",&w)
    w=fx.writer(&b.p)
    fx.int_put(&w,"ParameterIndex",2)
    fx.color_put(&w,"DefaultValue",{0.25,0.5,0.75,1})
    particle:=expression(&b,"DynamicParameter","Particle",&w)
    w=fx.writer(&b.p)
    random:=expression(&b,"ParticleRandom","Random",&w)
    w=fx.writer(&b.p)
    radius:=expression(&b,"ParticleRadius","Radius",&w)
    m:=fx.writer(&b.p)
    fx.enum_put(&m,"BlendMode","EBlendMode","BLEND_Translucent")
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=particle,output=1})
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=bounds})
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=screen,output=1})
    fx.input_put(&m,"Opacity","ScalarMaterialInput",{expression=fade})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=depth})
    fx.input_put(&m,"Specular","ScalarMaterialInput",{expression=random})
    fx.input_put(&m,"AmbientOcclusion","ScalarMaterialInput",{expression=radius})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Screen",fx.package_bytes(&b.p,"/Game/M/M_Screen")})
    defer library_destroy(&lib)
    translated,ok:=translate_one(t,&lib,"/Game/M/M_Screen")
    if !ok {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    if !testing.expect(t,!translated_is_standard(&translated)) {return}
    source:=translated.program.source
    for code in ([]string{"ctx.screen","ctx.screen_size","ctx.depth*100.0","ctx.scene_depth*100.0","unreal_object_bounds(ctx,1)","unreal_object_axis(ctx,2)","((ctx.particle_given>>2u)&1u)!=0u?ctx.particle_data[2]:float4(0.25,0.5,0.75,1","ctx.particle_random","ctx.particle_radius*100.0"}) {
        testing.expectf(t,strings.contains(source,code),"the program reads %s",code)
    }
}

// A place of the world is the one relative to the origin of the render plus
// the origin; two places differ without it.
@(test)
places_of_the_world_add_the_origin_and_their_differences_do_not :: proc(t:^testing.T) {
    b:=material_begin("M_World")
    w:=fx.writer(&b.p)
    world:=expression(&b,"WorldPosition","World",&w)
    w=fx.writer(&b.p)
    center:=expression(&b,"ObjectPositionWS","Center",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"A","ExpressionInput",{expression=world})
    fx.input_put(&w,"B","ExpressionInput",{expression=center})
    offset:=expression(&b,"Subtract","Offset",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=world})
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=offset})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_World",fx.package_bytes(&b.p,"/Game/M/M_World")})
    defer library_destroy(&lib)
    translated,ok:=translate_one(t,&lib,"/Game/M/M_World")
    if !ok {return}
    defer translated_destroy(&translated)
    if !testing.expect(t,!translated_is_standard(&translated)) {return}
    testing.expect(t,strings.contains(translated.program.source,"unreal_origin(ctx)"),"the world position adds the origin")
    g:=&translated.graph
    exact:=false
    for node in g.nodes {
        if node.op==.Sub && g.nodes[node.args[0]].op==.World_Position && g.nodes[node.args[1]].op==.Object_Position {exact=true}
    }
    testing.expect(t,exact,"the offset from the object is between the places relative to the origin")
}

// A uv set past the two of Mirai's meshes is vertex animation data: not translated.
@(test)
a_uv_set_past_the_second_is_not_translated :: proc(t:^testing.T) {
    b:=material_begin("M_Pivot")
    w:=fx.writer(&b.p)
    fx.int_put(&w,"CoordinateIndex",2)
    uv:=expression(&b,"TextureCoordinate","Pivot",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=uv})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Pivot",fx.package_bytes(&b.p,"/Game/M/M_Pivot")})
    defer library_destroy(&lib)
    translated,ok:=translate_one(t,&lib,"/Game/M/M_Pivot")
    if !ok {return}
    defer translated_destroy(&translated)
    if testing.expect_value(t,len(translated.untranslated),1) {
        testing.expect_value(t,translated.untranslated[0],Untranslated{"MaterialExpressionTextureCoordinate",1})
    }
    noted:=false
    for n in translated.notes {noted||=strings.contains(n,"vertex animation")}
    testing.expect(t,noted,"the note says why")
}

// The HLSL of a Custom expression is a function of the program with its
// inputs and its additional outputs; HLSL that reads Unreal's view stays a
// note to port, and its function gives zero.
@(test)
custom_hlsl_is_a_function_of_the_program_or_a_note_to_port :: proc(t:^testing.T) {
    b:=material_begin("M_Custom")
    w:=fx.writer(&b.p)
    fx.name_property_put(&w,"ParameterName","Gain")
    fx.float_put(&w,"DefaultValue",2)
    gain:=expression(&b,"ScalarParameter","Gain",&w)
    input:=fx.writer(&b.p)
    fx.name_property_put(&input,"InputName","A")
    fx.input_put(&input,"Input","ExpressionInput",{expression=gain})
    extra:=fx.writer(&b.p)
    fx.name_property_put(&extra,"OutputName","Extra")
    fx.enum_put(&extra,"OutputType","ECustomMaterialOutputType","CMOT_Float1")
    w=fx.writer(&b.p)
    fx.string_put(&w,"Code","Extra = A * 3.0;\r\nreturn MaterialFloat3(A, A, A);")
    fx.string_put(&w,"Description","Gained")
    fx.structs_put(&w,"Inputs","CustomInput",{fx.end(&input)})
    fx.structs_put(&w,"AdditionalOutputs","CustomOutput",{fx.end(&extra)})
    ported:=expression(&b,"Custom","Ported",&w)
    w=fx.writer(&b.p)
    fx.string_put(&w,"Code","return View.ViewSizeAndInvSize.x;")
    fx.enum_put(&w,"OutputType","ECustomMaterialOutputType","CMOT_Float1")
    viewed:=expression(&b,"Custom","Viewed",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=ported})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=ported,output=1})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=viewed})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Custom",fx.package_bytes(&b.p,"/Game/M/M_Custom")})
    defer library_destroy(&lib)
    translated,ok:=translate_one(t,&lib,"/Game/M/M_Custom")
    if !ok {return}
    defer translated_destroy(&translated)
    if testing.expect_value(t,len(translated.untranslated),1) {
        testing.expect_value(t,translated.untranslated[0],Untranslated{"MaterialExpressionCustom",1})
    }
    if !testing.expect(t,!translated_is_standard(&translated)) {return}
    source:=translated.program.source
    testing.expect(t,strings.contains(source,"// The Custom expression Gained of Unreal."))
    testing.expect(t,strings.contains(source,"(Mirai_Surface_Context ctx, float A, inout float Extra) {\n    Extra = A * 3.0;\n    return MaterialFloat3(A, A, A);\n}"),"the function of the code")
    testing.expect(t,strings.contains(source,"#define MaterialFloat3 float3"),"the names of Unreal's HLSL")
    testing.expect(t,strings.contains(source,"To port to Slang") && strings.contains(source,"//     return View.ViewSizeAndInvSize.x;"),"the code to port is a note")
    testing.expect(t,strings.contains(source,"(Mirai_Surface_Context ctx) {return 0.0;}"),"which gives zero")
    testing.expect(t,strings.contains(source,"_1=0.0;\n") && strings.contains(source,"_1);\n"),"the additional output is a local the call fills")
}

// Custom HLSL that calls a function of Unreal's shaders, which it does not
// define, cannot be ported as it is.
@(test)
custom_hlsl_that_calls_unreal_shader_functions_is_to_port :: proc(t:^testing.T) {
    reads:=make([dynamic]string,context.temp_allocator)
    code:="struct F {float2 Hit(float3 o) {return o.xy;}};\nF f;\n// Commented(A)\nreturn float3(f.Hit(A), RayIntersectSphere(A, B).x) + saturate(Rand3DPCG16(int3(1, 2, 3)).x) + MaterialFloat(1.0);"
    custom_foreign_calls(code,&reads)
    if testing.expect_value(t,len(reads),1) {testing.expect_value(t,reads[0],"RayIntersectSphere()")}
}

// Unreal's noise is a call to its functions in Slang, the size of a texture
// is read on the GPU.
@(test)
noise_and_the_size_of_a_texture_are_computed_by_a_program :: proc(t:^testing.T) {
    b:=material_begin("M_Noise")
    w:=fx.writer(&b.p)
    fx.int_put(&w,"Levels",2)
    scalar_noise:=expression(&b,"Noise","Noise",&w)
    w=fx.writer(&b.p)
    world:=expression(&b,"WorldPosition","World",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Position","ExpressionInput",{expression=world})
    fx.enum_put(&w,"NoiseFunction","EVectorNoiseFunction","VNF_GradientALU")
    vector_noise:=expression(&b,"VectorNoise","Vector",&w)
    w=fx.writer(&b.p)
    fx.object_put(&w,"Texture",texture_ref(&b,"T_Albedo"))
    texture_object:=expression(&b,"TextureObject","Albedo",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"TextureObject","ExpressionInput",{expression=texture_object})
    fx.enum_put(&w,"Property","EMaterialExposedTextureProperty","TMTM_TexelSize")
    texel:=expression(&b,"TextureProperty","Texel",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=scalar_noise})
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=vector_noise,mask=RGB})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=texel,mask={true,false,false,false}})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Noise",fx.package_bytes(&b.p,"/Game/M/M_Noise")})
    defer library_destroy(&lib)
    translated,ok:=translate_one(t,&lib,"/Game/M/M_Noise")
    if !ok {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    if !testing.expect(t,!translated_is_standard(&translated)) {return}
    source:=translated.program.source
    testing.expect(t,strings.contains(source,"#include \"unreal_noise.slang\"\nnamespace"),"the noise of Unreal, before the namespace")
    testing.expect(t,strings.contains(source,"MaterialExpressionNoiseWorld(") && strings.contains(source,",1,0,true,2,-1.0,1.0,2.0,"),"the scalar noise of the world, with its settings")
    testing.expect(t,strings.contains(source,"MaterialExpressionVectorNoise(") && strings.contains(source,",1,2,false,300.0)"),"the gradient noise")
    testing.expect(t,strings.contains(source,"mirai_texture_size(p.t0_"),"the size of the texture")
}

// A render target a grid writes, by its path, and a parameter Unreal fills as
// the game runs, by its name: the program reads each by UV with the function
// its read names, and neither is a texture parameter.
@(test)
textures_written_as_the_game_runs_are_read_by_uv :: proc(t:^testing.T) {
    b:=material_begin("M_Target")
    w:=fx.writer(&b.p)
    coordinates:=expression(&b,"TextureCoordinate","UV",&w)
    w=fx.writer(&b.p)
    fx.object_put(&w,"Texture",fx.external(&b.p,"/Game/T/RT_Grid","/Script/Engine","TextureRenderTarget2D","RT_Grid"))
    fx.name_property_put(&w,"ParameterName","NiagaraRT")
    fx.input_put(&w,"Coordinates","ExpressionInput",{expression=coordinates})
    target:=expression(&b,"TextureSampleParameter2D","NiagaraRT",&w)
    w=fx.writer(&b.p)
    fx.name_property_put(&w,"ParameterName","VelocityDensityBuffer")
    buffer:=expression(&b,"TextureObjectParameter","VelocityDensityBuffer",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"TextureObject","ExpressionInput",{expression=buffer})
    fx.input_put(&w,"Coordinates","ExpressionInput",{expression=coordinates})
    fluid:=expression(&b,"TextureSample","Fluid",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=fluid,mask=RGB})
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=target,mask=RGB})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Target",fx.package_bytes(&b.p,"/Game/M/M_Target")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Target.M_Target")
    reads:=[]Texture_Read{
        {texture="/Game/T/RT_Grid.RT_Grid",include="vfx_world_texture.slang",function="vfx_world_texture_uv",name="grid_a"},
        {texture="VelocityDensityBuffer",include="vfx_world_texture.slang",function="vfx_world_texture_uv",name="fluid"},
    }
    translated,error:=translate(&lib,material,{reads=reads})
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    if !testing.expect(t,!translated_is_standard(&translated)) {return}
    source:=translated.program.source
    testing.expect_value(t,strings.count(source,"#include \"vfx_world_texture.slang\""),1)
    testing.expect(t,strings.contains(source,"vfx_world_texture_uv(\"grid_a\","),"the render target, by uv")
    testing.expect(t,strings.contains(source,"vfx_world_texture_uv(\"fluid\","),"the parameter, by uv")
    for p in translated.program.parameters {testing.expectf(t,p.kind!=.Texture,"%s is no texture parameter",p.name)}
}

@(private="file")
layer_function :: proc(p:^fx.Package,class,name:string) -> i32 {
    return fx.export(p,fx.class(p,"/Script/Engine",class),0,name,nil)
}

// ML_Rough: a layer whose roughness is its parameter Rough.
@(private="file")
layer_package :: proc() -> []u8 {
    p:=fx.package_make()
    function:=layer_function(&p,"MaterialFunctionMaterialLayer","ML_Rough")
    w:=fx.writer(&p)
    fx.name_property_put(&w,"ParameterName","Rough")
    fx.float_put(&w,"DefaultValue",0.2)
    rough:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionScalarParameter"),function,"Rough",fx.finish(&w))
    w=fx.writer(&p)
    fx.input_put(&w,"Roughness","ExpressionInput",{expression=rough})
    made:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionMakeMaterialAttributes"),function,"Make",fx.finish(&w))
    w=fx.writer(&p)
    fx.input_put(&w,"A","ExpressionInput",{expression=made})
    fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionFunctionOutput"),function,"Out",fx.finish(&w))
    w=fx.writer(&p)
    p.exports[0].data=fx.finish(&w)
    return fx.package_bytes(&p,"/Game/F/ML_Rough")
}

// MLB_Half: the layer half over what is below it.
@(private="file")
blend_package :: proc() -> []u8 {
    p:=fx.package_make()
    function:=layer_function(&p,"MaterialFunctionMaterialLayerBlend","MLB_Half")
    inputs:[2]i32
    for &input,i in inputs {
        w:=fx.writer(&p)
        fx.name_property_put(&w,"InputName",i==0?"Bottom":"Top")
        fx.enum_put(&w,"InputType","EFunctionInputType","FunctionInput_MaterialAttributes")
        fx.int_put(&w,"SortPriority",i32(i))
        input=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionFunctionInput"),function,i==0?"Bottom":"Top",fx.finish(&w))
    }
    w:=fx.writer(&p)
    fx.float_put(&w,"R",0.5)
    half:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionConstant"),function,"Half",fx.finish(&w))
    w=fx.writer(&p)
    fx.input_put(&w,"A","MaterialAttributesInput",{expression=inputs[0]})
    fx.input_put(&w,"B","MaterialAttributesInput",{expression=inputs[1]})
    fx.input_put(&w,"Alpha","ExpressionInput",{expression=half})
    blended:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionBlendMaterialAttributes"),function,"Blend",fx.finish(&w))
    w=fx.writer(&p)
    fx.input_put(&w,"A","ExpressionInput",{expression=blended})
    fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionFunctionOutput"),function,"Out",fx.finish(&w))
    w=fx.writer(&p)
    p.exports[0].data=fx.finish(&w)
    return fx.package_bytes(&p,"/Game/F/MLB_Half")
}

// A stack of two layers of ML_Rough blended by MLB_Half: each layer has its
// parameters, which an instance sets by layer.
@(test)
material_layers_are_their_functions_with_the_parameters_of_each_layer :: proc(t:^testing.T) {
    b:=material_begin("M_Layers")
    layer:=fx.external(&b.p,"/Game/F/ML_Rough","/Script/Engine","MaterialFunctionMaterialLayer","ML_Rough")
    blend:=fx.external(&b.p,"/Game/F/MLB_Half","/Script/Engine","MaterialFunctionMaterialLayerBlend","MLB_Half")
    stack:=fx.writer(&b.p)
    fx.objects_put(&stack,"Layers",{layer,layer})
    fx.objects_put(&stack,"Blends",{blend})
    w:=fx.writer(&b.p)
    fx.struct_put(&w,"DefaultLayers","MaterialLayersFunctions",fx.end(&stack))
    layers:=expression(&b,"MaterialAttributeLayers","Layers",&w)
    m:=fx.writer(&b.p)
    fx.bool_put(&m,"bUseMaterialAttributes",true)
    fx.input_put(&m,"MaterialAttributes","MaterialAttributesInput",{expression=layers})
    b.p.exports[0].data=fx.finish(&m)
    p:=fx.package_make()
    instance:=fx.writer(&p)
    fx.object_put(&instance,"Parent",fx.external(&p,"/Game/M/M_Layers","/Script/Engine","Material","M_Layers"))
    info:=fx.writer(&p)
    fx.name_property_put(&info,"Name","Rough")
    fx.enum_put(&info,"Association","EMaterialParameterAssociation","LayerParameter")
    fx.int_put(&info,"Index",1)
    value:=fx.writer(&p)
    fx.struct_put(&value,"ParameterInfo","MaterialParameterInfo",fx.end(&info))
    fx.float_put(&value,"ParameterValue",0.8)
    fx.structs_put(&instance,"ScalarParameterValues","ScalarParameterValue",{fx.end(&value)})
    fx.export(&p,fx.class(&p,"/Script/Engine","MaterialInstanceConstant"),0,"MI_Layers",fx.finish(&instance))
    lib:Library
    library_with(&lib,{"/Game/M/M_Layers",fx.package_bytes(&b.p,"/Game/M/M_Layers")},{"/Game/M/MI_Layers",fx.package_bytes(&p,"/Game/M/MI_Layers")},
        {"/Game/F/ML_Rough",layer_package()},{"/Game/F/MLB_Half",blend_package()})
    defer library_destroy(&lib)
    for path,i in ([]string{"/Game/M/M_Layers","/Game/M/MI_Layers"}) {
        expected:=[]f32{0.2,0.5}
        translated,ok:=translate_one(t,&lib,path)
        if !ok {continue}
        testing.expect_value(t,len(translated.untranslated),0)
        testing.expectf(t,translated_is_standard(&translated) && abs(translated.info.roughness-expected[i])<1e-6,"%s: roughness %v, not %v",path,translated.info.roughness,expected[i])
        translated_destroy(&translated)
    }
}
