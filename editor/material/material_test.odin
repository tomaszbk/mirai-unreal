package material

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "mirai:asset"
import shaders "mirai:cook/shaders"
import mirai_project "mirai:project"
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
// changes values shares the program of its parent. The program carries the
// derivatives of its coordinates, those finite differences of the graph
// give, takes none across a quad and compiles.
@(test)
moving_coordinates_are_a_program_with_the_parameters_of_the_material :: proc(t:^testing.T) {
    b:=material_begin("M_Flow")
    w:=fx.writer(&b.p)
    coordinates:=expression(&b,"TextureCoordinate","UV",&w)
    w=fx.writer(&b.p)
    fx.name_property_put(&w,"ParameterName","Tiling")
    fx.float_put(&w,"DefaultValue",3)
    tiling:=expression(&b,"ScalarParameter","Tiling",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"A","ExpressionInput",{expression=coordinates})
    fx.input_put(&w,"B","ExpressionInput",{expression=tiling})
    tiled:=expression(&b,"Multiply","Tiled",&w)
    pan:=fx.writer(&b.p)
    fx.float_put(&pan,"SpeedX",0.1)
    fx.float_put(&pan,"SpeedY",-0.05)
    fx.input_put(&pan,"Coordinate","ExpressionInput",{expression=tiled})
    panner:=expression(&b,"Panner","Pan",&pan)
    water:=sample_expression(&b,"Water","T_Water","",panner)
    gloss:=fx.writer(&b.p)
    fx.name_property_put(&gloss,"ParameterName","Gloss")
    fx.float_put(&gloss,"DefaultValue",0.2)
    gloss_value:=expression(&b,"ScalarParameter","Gloss",&gloss)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Value","ExpressionInput",{expression=panner})
    across:=expression(&b,"DDX","Across",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=water,mask=RGB})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=gloss_value})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=across,mask={true,false,false,false}})
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
    testing.expect(t,strings.contains(program.source,"\"default\":0.2}"))
    if testing.expect_value(t,len(program.parameters),3) {
        testing.expect(t,program.parameters[0].kind==.Texture && program.parameters[1].kind==.Float && program.parameters[2].kind==.Float)
    }
    for image in translated.images {testing.expect_value(t,image,MAP_NONE)}
    for implicit in ([]string{"ddx(","ddy(","fwidth(","ctx.lod"}) {
        testing.expectf(t,!strings.contains(program.source,implicit),"no derivative across a quad: %s",implicit)
    }
    testing.expect(t,strings.contains(program.source,".dx;"),"DDX reads the derivative the coordinates carry")
    // The derivatives the program gives the sample, against those of the
    // graph by finite differences of a uv that moves across the image.
    uv_of :: proc(at:[2]f32) -> [2]f32 {return {0.25+0.01*at.x-0.004*at.y,0.5+0.003*at.x+0.02*at.y}}
    jacobian:=[2][2]f32{{0.01,0.003},{-0.004,0.02}} // along x, along y
    TIME :: 1.5
    g:=&translated.graph
    uv:=NONE
    for node in g.nodes {if node.op==.Sample {uv=node.args[1]}}
    if !testing.expect(t,uv!=NONE) {return}
    plain :: proc(g:^Graph,root:u32,uv:[2]f32) -> [4]f32 {
        values:=make([][4]f32,len(g.nodes),context.temp_allocator)
        texel:Texel_Context
        for n in nodes_under(g,{root}) {
            node:=&g.nodes[n]
            #partial switch node.op {
            case .UV:values[n]={uv.x,uv.y,0,0}
            case .Time:values[n]={TIME,0,0,0}
            case:
                args:[3][4]f32
                for arg,i in node.args {if arg!=NONE {args[i]=values[arg]}}
                values[n]=node_compute(g,node,args,&texel)
            }
        }
        return values[root]
    }
    for at in ([][2]f32{{0,0},{120,40},{-30,75}}) {
        it:Dual_Interpreter
        it.time=TIME
        it.uv0={width=2,dual=true,value={uv_of(at).x,uv_of(at).y,0,0},dx={jacobian[0].x,jacobian[0].y,0,0},dy={jacobian[1].x,jacobian[1].y,0,0}}
        sampled,problem:=dual_interpret(&it,program^)
        if !testing.expectf(t,problem=="" && len(sampled)==1,"the program reads as duals: %s\n%s",problem,program.source) {return}
        H :: 0.5
        along:=[2][2]f32{{H,0},{0,H}}
        for axis in 0..<2 {
            forward,back:=plain(g,uv,uv_of(at+along[axis])),plain(g,uv,uv_of(at-along[axis]))
            given:=axis==0?sampled[0].dx:sampled[0].dy
            for c in 0..<2 {
                difference:=(forward[c]-back[c])/(2*H)
                testing.expectf(t,abs(given[c]-difference)<1e-4,"at %v the derivative %d of component %d is %v, not %v",at,axis,c,given[c],difference)
            }
        }
        testing.expectf(t,abs(sampled[0].value.x-plain(g,uv,uv_of(at)).x)<1e-5,"the value at %v",at)
    }
    program_compiles(t,program^)
}

// A value of a program read as the Slang of mirai_dual.slang computes it:
// with its derivatives along x and y of the image, or without (dual false).
@(private="file")
Dual_Value :: struct {width:int,dual:bool,value,dx,dy:[4]f32}

@(private="file")
Dual_Interpreter :: struct {
    src:shaders.Surface_Source,
    locals:map[string]Dual_Value,
    time:f32,
    uv0:Dual_Value,
    parameters:map[string]Dual_Value,
    sampled:[dynamic]Dual_Value, // the uv of each sample by derivatives
    failed:string,
}

// Runs the declarations of the evaluate of a program, the subset a program
// with moving coordinates is written in: the uv of its samples by derivatives.
@(private="file")
dual_interpret :: proc(it:^Dual_Interpreter,program:Program) -> (sampled:[]Dual_Value,problem:string) {
    it.src=shaders.surface_parse(program.source,context.temp_allocator)
    it.locals=make(map[string]Dual_Value,context.temp_allocator)
    it.parameters=make(map[string]Dual_Value,context.temp_allocator)
    it.sampled=make([dynamic]Dual_Value,context.temp_allocator)
    for p in program.parameters {it.parameters[p.name]={width=int(p.components),value=p.value}}
    for f in it.src.functions {
        if f.name!="evaluate" {continue}
        for s in f.body {
            stmt:=it.src.stmts[s]
            if stmt.kind==.Declare && stmt.value>=0 && stmt.type!="Mirai_Surface" {it.locals[stmt.name]=dual_eval(it,stmt.value)}
        }
        return it.sampled[:],it.failed
    }
    return nil,"the program has no evaluate"
}

@(private="file")
dual_eval :: proc(it:^Dual_Interpreter,e:int) -> (out:Dual_Value) {
    if it.failed!="" {return}
    expr:=it.src.exprs[e]
    fail :: proc(it:^Dual_Interpreter,expr:shaders.Expr) -> Dual_Value {
        it.failed=fmt.aprintf("%v %s at token %d",expr.kind,expr.text,expr.first,allocator=context.temp_allocator)
        return {}
    }
    wide :: proc(v:Dual_Value,width:int) -> Dual_Value {
        if v.width!=1 || width==1 {return v}
        return {width=width,dual=v.dual,value=v.value.x,dx=v.dx.x,dy=v.dy.x}
    }
    switch expr.kind {
    case .Number:
        value,_:=strconv.parse_f32(strings.trim_right(expr.text,"fF"))
        return {width=1,value={value,0,0,0}}
    case .Name:
        if local,found:=it.locals[expr.text];found {return local}
        return fail(it,expr)
    case .Member:
        base:=it.src.exprs[expr.kids[0]]
        if base.kind==.Name && base.text=="p" {
            if field,found:=it.parameters[expr.text];found {return field}
            return fail(it,expr)
        }
        if base.kind==.Name && base.text=="ctx" {
            if expr.text=="time" {return {width=1,value={it.time,0,0,0}}}
            return fail(it,expr)
        }
        v:=dual_eval(it,expr.kids[0])
        switch expr.text {
        case "value":return {width=v.width,value=v.value}
        case "dx":return {width=v.width,value=v.dx}
        case "dy":return {width=v.width,value=v.dy}
        }
        out={width=len(expr.text),dual=v.dual}
        for letter,i in expr.text {
            c:=strings.index_rune("xyzw",letter)
            if c<0 || c>=v.width || i>=4 {return fail(it,expr)}
            out.value[i],out.dx[i],out.dy[i]=v.value[c],v.dx[c],v.dy[c]
        }
        return
    case .Unary:
        v:=dual_eval(it,expr.kids[0])
        if expr.text!="-" {return fail(it,expr)}
        return {width=v.width,dual=v.dual,value=-v.value,dx=-v.dx,dy=-v.dy}
    case .Binary:
        a,b:=dual_eval(it,expr.kids[0]),dual_eval(it,expr.kids[1])
        width:=max(a.width,b.width)
        a,b=wide(a,width),wide(b,width)
        out={width=width,dual=a.dual || b.dual}
        switch expr.text {
        case "+":out.value,out.dx,out.dy=a.value+b.value,a.dx+b.dx,a.dy+b.dy
        case "-":out.value,out.dx,out.dy=a.value-b.value,a.dx-b.dx,a.dy-b.dy
        case "*":out.value,out.dx,out.dy=a.value*b.value,a.dx*b.value+a.value*b.dx,a.dy*b.value+a.value*b.dy
        case:return fail(it,expr)
        }
        return
    case .Call:
        callee:=it.src.exprs[expr.kids[0]]
        args:=expr.kids[1:]
        switch callee.text {
        case "float","float2","float3","float4":
            width:=callee.text=="float"?1:int(callee.text[5]-'0')
            if len(args)==1 {
                v:=dual_eval(it,args[0])
                if v.dual {return fail(it,expr)}
                return wide({width=1,value=v.value},width)
            }
            out.width=width
            at:=0
            for arg in args {
                v:=dual_eval(it,arg)
                if v.dual || at+v.width>4 {return fail(it,expr)}
                for i in 0..<v.width {out.value[at+i]=v.value[i]}
                at+=v.width
            }
            return
        case "mirai_dual":
            v:=dual_eval(it,args[0])
            out={width=v.width,dual=true,value=v.value}
            if len(args)==3 {out.dx,out.dy=dual_eval(it,args[1]).value,dual_eval(it,args[2]).value}
            return
        case "mirai_uv0":return it.uv0
        case "frac":
            v:=dual_eval(it,args[0])
            for i in 0..<4 {v.value[i]-=math.floor(v.value[i])}
            return v
        case "mirai_sample_texture":
            if len(args)!=3 {return fail(it,expr)}
            v:=dual_eval(it,args[2])
            if !v.dual {return fail(it,expr)}
            append(&it.sampled,v)
            return {width=4}
        }
        return fail(it,expr)
    case .Index,.Ternary,.List:
    }
    return fail(it,expr)
}

// Slang compiles a program where it runs, as `mirai shaders check` does,
// where it has the engine and its Slang.
@(private="file")
program_compiles :: proc(t:^testing.T,program:Program,loc:=#caller_location) {
    root:=mirai_project.engine_root_find("",context.temp_allocator)
    if root=="" {log.warn("no engine: the program is not compiled");return}
    made,made_error:=os.make_directory_temp("","mirai-unreal-program-*",context.temp_allocator)
    if !testing.expect(t,made_error==nil,loc=loc) {return}
    defer os.remove_all(made)
    folder,_:=strings.replace_all(made,"\\","/",context.temp_allocator)
    os.make_directory_all(fmt.tprintf("%s/shaders",folder))
    path:=fmt.tprintf("%s/shaders/%s.slang",folder,program.name)
    if !testing.expect(t,os.write_entire_file(path,transmute([]u8)program.source)==nil,loc=loc) {return}
    result:=shaders.program_check({root=root,project=folder,path=path},context.temp_allocator)
    if strings.contains(result.error,"slangc") {log.warnf("the program is not compiled: %s",result.error);return}
    testing.expectf(t,result.error=="" && result.errors==0 && result.compiled,"the program compiles: %s %v",result.error,result.diagnostics,loc=loc)
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

// What fakes the view sees the surface head on, from as far as the view sees
// it: the depth from the eye along the forward of the view is the depth of
// the point. What undoes the exposure leaves the emission relative to it.
@(test)
the_view_is_taken_head_on_and_eye_adaptation_makes_emission_relative :: proc(t:^testing.T) {
    b:=material_begin("M_Glow")
    w:=fx.writer(&b.p)
    view:=expression(&b,"CameraVectorWS","View",&w)
    w=fx.writer(&b.p)
    inverse:=expression(&b,"EyeAdaptationInverse","Inverse",&w)
    w=fx.writer(&b.p)
    world:=expression(&b,"WorldPosition","World",&w)
    w=fx.writer(&b.p)
    eye:=expression(&b,"CameraPositionWS","Eye",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"A","ExpressionInput",{expression=world})
    fx.input_put(&w,"B","ExpressionInput",{expression=eye})
    away:=expression(&b,"Subtract","Away",&w)
    w=fx.writer(&b.p)
    fx.color_put(&w,"Constant",{0,0,1,0})
    z:=expression(&b,"Constant3Vector","Z",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Input","ExpressionInput",{expression=z})
    fx.enum_put(&w,"TransformSourceType","EMaterialVectorCoordTransformSource","TRANSFORMSOURCE_View")
    forward:=expression(&b,"Transform","Forward",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"A","ExpressionInput",{expression=away})
    fx.input_put(&w,"B","ExpressionInput",{expression=forward})
    depth:=expression(&b,"DotProduct","Depth",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=view})
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=inverse})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=depth})
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
    testing.expect(t,strings.contains(translated.program.source,"ctx.depth"),"the eye as far as the view sees the point")
}

// A two-sided Subsurface material is seen from both sides, reflects its base
// color and sends its SubsurfaceColor through: a diffuse transmission that
// splits the light between the two, here half each. One-sided, it has a back
// that is not drawn and the scattered light is part of the reflection. An
// instance whose BasePropertyOverrides set TwoSided overrides its parent.
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
    // An instance of the leaf that sets TwoSided to the opposite.
    flipped :: proc(two_sided:bool) -> []u8 {
        p:=fx.package_make()
        instance:=fx.writer(&p)
        fx.object_put(&instance,"Parent",fx.external(&p,"/Game/M/M_Leaf","/Script/Engine","Material","M_Leaf"))
        overrides:=fx.writer(&p)
        fx.bool_put(&overrides,"bOverride_TwoSided",true)
        fx.bool_put(&overrides,"TwoSided",two_sided)
        fx.struct_put(&instance,"BasePropertyOverrides","MaterialInstanceBasePropertyOverrides",fx.end(&overrides))
        fx.export(&p,fx.class(&p,"/Script/Engine","MaterialInstanceConstant"),0,"MI_Leaf",fx.finish(&instance))
        return fx.package_bytes(&p,"/Game/M/MI_Leaf")
    }
    for two_sided in ([]bool{true,false}) {
        lib:Library
        library_with(&lib,{"/Game/M/M_Leaf",leaf(two_sided)},{"/Game/M/MI_Leaf",flipped(!two_sided)})
        defer library_destroy(&lib)
        material,_:=object_find(&lib,"/Game/M/M_Leaf")
        translated,error:=translate(&lib,material)
        if !testing.expect_value(t,error.code,Error_Code.None) {return}
        defer translated_destroy(&translated)
        testing.expect_value(t,translated.info.two_sided,two_sided)
        instance,_:=object_find(&lib,"/Game/M/MI_Leaf")
        overridden,instance_error:=translate(&lib,instance)
        if !testing.expect_value(t,instance_error.code,Error_Code.None) {return}
        defer translated_destroy(&overridden)
        testing.expect_value(t,overridden.info.two_sided,!two_sided)
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

// A blended layer lit through a volume of light has no highlight, whatever
// its Specular; one shaded per pixel keeps it, as an opaque surface does.
// Lit by the volume without its direction, it is lit alike from both sides:
// it lets half of what it scatters through.
@(test)
a_translucent_layer_has_a_highlight_only_when_shaded_per_pixel :: proc(t:^testing.T) {
    Case :: struct {blend,lighting:string,highlight,through:bool}
    cases:=[]Case{
        {"BLEND_Translucent","",false,true},
        {"BLEND_Translucent","TLM_VolumetricPerVertexNonDirectional",false,true},
        {"BLEND_Translucent","TLM_VolumetricDirectional",false,false},
        {"BLEND_Translucent","TLM_Surface",false,false},
        {"BLEND_Additive","",false,true},
        {"BLEND_Translucent","TLM_SurfacePerPixelLighting",true,false},
        {"BLEND_Opaque","",true,false},
    }
    for c in cases {
        b:=material_begin("M_Layer")
        m:=fx.writer(&b.p)
        fx.enum_put(&m,"BlendMode","EBlendMode",c.blend)
        if c.lighting!="" {fx.enum_put(&m,"TranslucencyLightingMode","ETranslucencyLightingMode",c.lighting)}
        b.p.exports[0].data=fx.finish(&m)
        lib:Library
        library_with(&lib,{"/Game/M/M_Layer",fx.package_bytes(&b.p,"/Game/M/M_Layer")})
        translated,ok:=translate_one(t,&lib,"/Game/M/M_Layer")
        if ok {
            testing.expectf(t,(translated.info.specular_factor>0)==c.highlight,"%s %s: specular factor %v",c.blend,c.lighting,translated.info.specular_factor)
            through:=translated.info.diffuse_transmission
            testing.expectf(t,c.through?through.weight==0.5 && through.color==translated.info.base_color:through.weight==0,"%s %s: diffuse transmission %v",c.blend,c.lighting,through)
            translated_destroy(&translated)
        }
        library_destroy(&lib)
    }
}

// The opacity of a translucent layer is how much of it is there; that of
// glass, a layer that refracts or of the thin translucent model, is what it
// stops of the light behind it: the glass is there whole and lets the rest through.
@(test)
the_opacity_of_glass_is_what_it_does_not_let_through :: proc(t:^testing.T) {
    Case :: struct {shading:string,refraction,opacity,transmission:f32}
    cases:=[]Case{
        {"",0,0.3,0},
        {"",1.5,1,0.7},
        {"MSM_ThinTranslucent",0,1,0.7},
    }
    for c in cases {
        b:=material_begin("M_Pane")
        m:=fx.writer(&b.p)
        fx.enum_put(&m,"BlendMode","EBlendMode","BLEND_Translucent")
        if c.shading!="" {fx.enum_put(&m,"ShadingModel","EMaterialShadingModel",c.shading)}
        fx.input_put(&m,"Opacity","ScalarMaterialInput",{use_constant=true,constant={0.3,0,0,0}})
        if c.refraction>0 {fx.input_put(&m,"Refraction","ScalarMaterialInput",{use_constant=true,constant={c.refraction,0,0,0}})}
        b.p.exports[0].data=fx.finish(&m)
        lib:Library
        library_with(&lib,{"/Game/M/M_Pane",fx.package_bytes(&b.p,"/Game/M/M_Pane")})
        translated,ok:=translate_one(t,&lib,"/Game/M/M_Pane")
        if ok {
            info:=translated.info
            testing.expectf(t,info.alpha_mode==.Blend && abs(info.opacity-c.opacity)<1e-5 && abs(info.transmission-c.transmission)<1e-5,
                "%s refraction %v: opacity %v, transmission %v",c.shading,c.refraction,info.opacity,info.transmission)
            if c.refraction>0 {testing.expectf(t,abs(info.ior-c.refraction)<1e-5,"the glass refracts with its IOR: %v",info.ior)}
            translated_destroy(&translated)
        }
        library_destroy(&lib)
    }
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

// An offset that moves with time is wind when what feeds it is named for
// the wind, another motion when it is not, and a shape when it does not move;
// how far it sways each vertex is measured where the vertex is, by what
// weighs it there (its color, its place in the mesh before skinning), and
// what it leans the vertex one way all the time is no swing.
@(test)
an_offset_is_wind_another_motion_or_a_shape_with_its_reach_at_each_vertex :: proc(t:^testing.T) {
    Case :: struct {
        name,parameter,weight:string, // weight: the expression that weighs it per vertex
        timed,connected:bool,
        lean:f32, // the gust is the sine plus it: the vertex leans one way all the time
        kind:Offset_Kind,
        weights:bit_set[Offset_Weight],
        reach:f32, // at the top vertex; the one at the pivot does not move
    }
    cases:=[]Case{
        {"M_Grass","Wind Intensity","VertexColor",true,true,0,.Wind,{.Vertex_Color},10},
        {"M_Tree","Wind Sway","PreSkinnedPosition",true,true,0,.Wind,{},10},
        {"M_Leaning","Wind Intensity","VertexColor",true,true,2,.Wind,{.Vertex_Color},10},
        {"M_Flag","Flutter","VertexColor",true,true,0,.Motion,{.Vertex_Color},10},
        {"M_Bulge","Wind Intensity","VertexColor",false,true,0,.Shape,{},0},
        {"M_Still","","",false,false,0,.None,{},0},
    }
    // White at the top, a metre above the pivot; black at the pivot.
    vertices:=[]Offset_Vertex{{position={0,0,100},color={1,1,1,1}},{color={0,0,0,1}}}
    bounds:=[2][3]f32{{-10,-10,0},{10,10,100}}
    for c in cases {
        b:=material_begin(c.name)
        m:=fx.writer(&b.p)
        if c.connected {
            w:=fx.writer(&b.p)
            fx.name_property_put(&w,"ParameterName",c.parameter)
            fx.float_put(&w,"DefaultValue",5)
            amount:=expression(&b,"ScalarParameter","Amount",&w)
            if c.timed {
                w=fx.writer(&b.p)
                time:=expression(&b,"Time","Time",&w)
                w=fx.writer(&b.p)
                fx.input_put(&w,"Input","ExpressionInput",{expression=time})
                sine:=expression(&b,"Sine","Sine",&w)
                if c.lean>0 {
                    w=fx.writer(&b.p)
                    fx.input_put(&w,"A","ExpressionInput",{expression=sine})
                    fx.float_put(&w,"ConstB",c.lean)
                    sine=expression(&b,"Add","Lean",&w)
                }
                w=fx.writer(&b.p)
                fx.input_put(&w,"A","ExpressionInput",{expression=sine})
                fx.input_put(&w,"B","ExpressionInput",{expression=amount})
                amount=expression(&b,"Multiply","Gust",&w)
            }
            w=fx.writer(&b.p)
            weight:=expression(&b,c.weight,"Weight",&w)
            mask:=c.weight=="VertexColor"?[4]bool{true,false,false,false}:[4]bool{false,false,true,false}
            w=fx.writer(&b.p)
            fx.input_put(&w,"A","ExpressionInput",{expression=weight,mask=mask})
            fx.float_put(&w,"ConstB",c.weight=="VertexColor"?1:0.01)
            weighed:=expression(&b,"Multiply","Weighed",&w)
            w=fx.writer(&b.p)
            fx.input_put(&w,"A","ExpressionInput",{expression=amount})
            fx.input_put(&w,"B","ExpressionInput",{expression=weighed})
            swayed:=expression(&b,"Multiply","Swayed",&w)
            w=fx.writer(&b.p)
            fx.color_put(&w,"Constant",{1,0,0,0})
            across:=expression(&b,"Constant3Vector","Across",&w)
            w=fx.writer(&b.p)
            fx.input_put(&w,"A","ExpressionInput",{expression=swayed})
            fx.input_put(&w,"B","ExpressionInput",{expression=across})
            offset:=expression(&b,"Multiply","Offset",&w)
            fx.input_put(&m,"WorldPositionOffset","VectorMaterialInput",{expression=offset})
        }
        b.p.exports[0].data=fx.finish(&m)
        name:=fmt.tprintf("/Game/M/%s",c.name)
        lib:Library
        library_with(&lib,{name,fx.package_bytes(&b.p,name)})
        defer library_destroy(&lib)
        material,_:=object_find(&lib,name)
        reach:[2]f32
        o,error:=offset_read(&lib,material,vertices,bounds,reach[:],allocator=context.temp_allocator)
        if !testing.expect_value(t,error.code,Error_Code.None) {continue}
        testing.expectf(t,o.kind==c.kind,"%s: %v, not %v",c.name,o.kind,c.kind)
        testing.expectf(t,o.weights==c.weights,"%s: weighed by %v, not %v",c.name,o.weights,c.weights)
        testing.expectf(t,o.why=="","%s: measured (%s)",c.name,o.why)
        // A sine of Unreal turns once a second: in twentieths of a second it reaches both peaks.
        testing.expectf(t,abs(reach[0]-c.reach)<=c.reach*1e-3,"%s: the top sways %v, not %v",c.name,reach[0],c.reach)
        testing.expectf(t,reach[1]==0,"%s: the pivot moves %v",c.name,reach[1])
        direction:=c.lean>0?[2]f32{1,0}:[2]f32{}
        testing.expectf(t,o.direction==direction,"%s: sways the way %v, not %v",c.name,o.direction,direction)
        frequency:=f32(c.timed?1:0)
        testing.expectf(t,abs(o.frequency-frequency)<0.05,"%s: sways %v times a second, not %v",c.name,o.frequency,frequency)
        if c.connected {
            found:=false
            for n in o.names {found||=n==c.parameter}
            testing.expectf(t,found,"%s: %v names %s",c.name,o.names,c.parameter)
        }
    }
}

// A masked material whose mask keeps every point, unconnected or a constant
// that reaches the cutoff, is opaque; a mask of a texture or one below the
// cutoff stays a mask.
@(test)
a_mask_that_keeps_every_point_is_opaque :: proc(t:^testing.T) {
    Case :: struct {name:string,mask:enum {None,Constant,Texture},value:f32,mode:asset.Alpha_Mode}
    cases:=[]Case{
        {"M_Unconnected",.None,0,.Opaque},
        {"M_Whole",.Constant,1,.Opaque},
        {"M_Below",.Constant,0.2,.Mask},
        {"M_Texture",.Texture,0,.Mask},
    }
    for c in cases {
        b:=material_begin(c.name)
        albedo:=sample_expression(&b,"Albedo","T_Albedo","")
        m:=fx.writer(&b.p)
        fx.enum_put(&m,"BlendMode","EBlendMode","BLEND_Masked")
        fx.float_put(&m,"OpacityMaskClipValue",0.5)
        fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=albedo,mask=RGB})
        switch c.mask {
        case .None:
        case .Constant:
            w:=fx.writer(&b.p)
            fx.float_put(&w,"R",c.value)
            fx.input_put(&m,"OpacityMask","ScalarMaterialInput",{expression=expression(&b,"Constant","Mask",&w)})
        case .Texture:
            fx.input_put(&m,"OpacityMask","ScalarMaterialInput",{expression=albedo,mask={false,false,false,true}})
        }
        b.p.exports[0].data=fx.finish(&m)
        path:=strings.concatenate({"/Game/M/",c.name},context.temp_allocator)
        lib:Library
        library_with(&lib,{path,fx.package_bytes(&b.p,path)},{"/Game/T/T_Albedo",texture_bytes("T_Albedo")})
        defer library_destroy(&lib)
        material,_:=object_find(&lib,path)
        translated,error:=translate(&lib,material)
        if !testing.expectf(t,error.code==.None,"%s: %v",c.name,error) {continue}
        testing.expectf(t,translated.info.alpha_mode==c.mode,"%s is %v",c.name,translated.info.alpha_mode)
        translated_destroy(&translated)
    }
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
// of BreakMaterialAttributes past the customized Vs are the attributes
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

// A channel mask is the channel of its input its parameter picks, red when
// it keeps no value.
@(test)
a_channel_mask_is_the_channel_its_parameter_picks :: proc(t:^testing.T) {
    b:=material_begin("M_Channels")
    w:=fx.writer(&b.p)
    fx.color_put(&w,"Constant",{0.2,0.4,0.6,0.8})
    channels:=expression(&b,"Constant4Vector","Channels",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Input","ExpressionInput",{expression=channels})
    fx.name_property_put(&w,"ParameterName","Rough")
    fx.color_put(&w,"DefaultValue",{0,0,1,0})
    blue:=expression(&b,"ChannelMaskParameter","Blue",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Input","ExpressionInput",{expression=channels})
    fx.name_property_put(&w,"ParameterName","Metal")
    red:=expression(&b,"ChannelMaskParameter","Red",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=blue})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=red})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Channels",fx.package_bytes(&b.p,"/Game/M/M_Channels")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Channels")
    translated,error:=translate(&lib,material)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    testing.expect(t,abs(translated.info.roughness-0.6)<1e-6 && abs(translated.info.metallic-0.2)<1e-6,"blue, then red by default")
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

// A landscape material that writes RVT_Ground with its layers Grass and
// Rock, a roughness of what it writes apart from what it shows
// (RuntimeVirtualTextureReplace) and its parameter Wet, and that reads its
// virtual texture back.
@(private="file")
ground_material :: proc() -> []u8 {
    b:=material_begin("M_Ground")
    w:=fx.writer(&b.p)
    fx.color_put(&w,"Constant",{0.1,0.6,0.1,1})
    grass:=expression(&b,"Constant3Vector","Grass",&w)
    w=fx.writer(&b.p)
    fx.color_put(&w,"Constant",{0.4,0.4,0.4,1})
    rock:=expression(&b,"Constant3Vector","Rock",&w)
    layers:=[2][]u8{}
    for &layer,i in layers {
        l:=fx.writer(&b.p)
        fx.name_property_put(&l,"LayerName",i==0?"Grass":"Rock")
        fx.enum_put(&l,"BlendType","ELandscapeLayerBlendType","LB_WeightBlend")
        fx.input_put(&l,"LayerInput","ExpressionInput",{expression=i==0?grass:rock})
        layer=fx.end(&l)
    }
    w=fx.writer(&b.p)
    fx.structs_put(&w,"Layers","LayerBlendInput",layers[:])
    blended:=expression(&b,"LandscapeLayerBlend","Blend",&w)
    w=fx.writer(&b.p)
    fx.name_property_put(&w,"ParameterName","Wet")
    fx.float_put(&w,"DefaultValue",0.3)
    wet:=expression(&b,"ScalarParameter","Wet",&w)
    w=fx.writer(&b.p)
    fx.float_put(&w,"R",0.8)
    dry:=expression(&b,"Constant","Dry",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Default","ExpressionInput",{expression=dry})
    fx.input_put(&w,"VirtualTextureOutput","ExpressionInput",{expression=wet})
    replace:=expression(&b,"RuntimeVirtualTextureReplace","Replace",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"BaseColor","ExpressionInput",{expression=blended})
    fx.input_put(&w,"Roughness","ExpressionInput",{expression=replace})
    expression(&b,"RuntimeVirtualTextureOutput","Output",&w)
    read:=virtual_sample(&b,"Read","BaseColor_Normal_Specular")
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=read})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=read,output=2})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=replace})
    b.p.exports[0].data=fx.finish(&m)
    return fx.package_bytes(&b.p,"/Game/M/M_Ground")
}

// A sample of the virtual texture /Game/RVT/<texture> ("": none) that holds content.
@(private="file")
virtual_sample :: proc(b:^Graph_Builder,name,content:string,texture:="RVT_Ground") -> i32 {
    w:=fx.writer(&b.p)
    if texture!="" {
        fx.object_put(&w,"VirtualTexture",fx.external(&b.p,strings.concatenate({"/Game/RVT/",texture},context.temp_allocator),"/Script/Engine","RuntimeVirtualTexture",texture))
    }
    fx.enum_put(&w,"MaterialType","ERuntimeVirtualTextureMaterialType",strings.concatenate({"ERuntimeVirtualTextureMaterialType::",content},context.temp_allocator))
    return expression(b,"RuntimeVirtualTextureSample",name,&w)
}

@(private="file")
ground_writers :: proc() -> []Virtual_Texture_Writer {
    return slice.clone([]Virtual_Texture_Writer{{texture="/Game/RVT/RVT_Ground.RVT_Ground",material="/Game/M/M_Ground.M_Ground"}},context.temp_allocator)
}

// A landscape material that reads back the virtual texture it writes reads
// what its own branch writes: RuntimeVirtualTextureReplace takes what it
// writes there, and its default where the material shows itself.
@(test)
a_landscape_material_reads_back_what_it_writes :: proc(t:^testing.T) {
    lib:Library
    library_with(&lib,{"/Game/M/M_Ground",ground_material()})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Ground")
    translated,error:=translate(&lib,material,{layer="Rock",writers=ground_writers()})
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    testing.expect_value(t,translated.info.base_color,[3]f32{0.4,0.4,0.4})
    testing.expect(t,abs(translated.info.metallic-0.3)<1e-6,"the roughness it writes")
    testing.expect(t,abs(translated.info.roughness-0.8)<1e-6,"the roughness it shows")
}

// A mesh that samples the virtual texture a landscape writes shows what the
// material of the landscape gives where the mesh is, as that material shows
// without a terrain (its first layer), with its parameters apart from those
// of the mesh. Without a landscape that writes it, the sample is not
// translated.
@(test)
a_mesh_reads_what_the_landscape_writes_where_it_is :: proc(t:^testing.T) {
    b:=material_begin("M_Grass")
    read:=virtual_sample(&b,"Ground","BaseColor_Normal_Specular")
    w:=fx.writer(&b.p)
    fx.name_property_put(&w,"ParameterName","Wet")
    fx.float_put(&w,"DefaultValue",0.9)
    wet:=expression(&b,"ScalarParameter","Wet",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=read})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=read,output=2})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=wet})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Grass",fx.package_bytes(&b.p,"/Game/M/M_Grass")},{"/Game/M/M_Ground",ground_material()})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Grass")
    translated,error:=translate(&lib,material,{writers=ground_writers()})
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    testing.expect_value(t,len(translated.layers),0)
    testing.expect_value(t,translated.info.base_color,[3]f32{0.1,0.6,0.1})
    testing.expect(t,abs(translated.info.metallic-0.3)<1e-6,"the Wet of the landscape")
    testing.expect(t,abs(translated.info.roughness-0.9)<1e-6,"its own Wet")
    alone,alone_error:=translate(&lib,material)
    if !testing.expect_value(t,alone_error.code,Error_Code.None) {return}
    defer translated_destroy(&alone)
    if testing.expect_value(t,len(alone.untranslated),1) {
        testing.expect_value(t,alone.untranslated[0],Untranslated{"MaterialExpressionRuntimeVirtualTextureSample",1})
    }
}

// Where a sample has nothing to read, Unreal gives constants: a sample that
// names no virtual texture, and an output its texture does not hold. A
// feature switch takes the branch without virtual textures, also where a
// landscape writes the one its other branch reads.
@(test)
a_sample_with_nothing_to_read_gives_the_constants_of_unreal :: proc(t:^testing.T) {
    b:=material_begin("M_Patch")
    unnamed:=virtual_sample(&b,"Unnamed","BaseColor",texture="")
    color:=virtual_sample(&b,"Color","BaseColor")
    w:=fx.writer(&b.p)
    fx.color_put(&w,"Constant",{0.2,0.3,0.4,1})
    own:=expression(&b,"Constant3Vector","Own",&w)
    w=fx.writer(&b.p)
    fx.input_put(&w,"Yes","ExpressionInput",{expression=color})
    fx.input_put(&w,"No","ExpressionInput",{expression=own})
    feature:=expression(&b,"VirtualTextureFeatureSwitch","Feature",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=feature})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=unnamed,output=5})
    fx.input_put(&m,"Specular","ScalarMaterialInput",{expression=color,output=4})
    b.p.exports[0].data=fx.finish(&m)
    lib:Library
    library_with(&lib,{"/Game/M/M_Patch",fx.package_bytes(&b.p,"/Game/M/M_Patch")},{"/Game/M/M_Ground",ground_material()})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Patch")
    translated,error:=translate(&lib,material,{writers=ground_writers()})
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    testing.expect_value(t,len(translated.untranslated),0)
    testing.expect_value(t,translated.info.base_color,[3]f32{0.2,0.3,0.4})
    testing.expect_value(t,translated.info.metallic,f32(1))
    testing.expect_value(t,translated.info.specular_factor,f32(0))
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
// layers by the weight of the layer of the terrain that shows it, read from
// the maps each piece of the terrain gives, whichever of up to LAYERS_MAX it
// is; its coordinates come from the place of the point in the world.
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
    // The terrain shows Rock in its fifth layer and Grass in its sixth; Sand it does not have.
    mapping:=Landscape_Mapping{layers={"Dirt","Snow","Mud","Gravel","Rock","Grass"},coordinates={{0.01,0,0,8},{0,-0.01,0,16}}}
    translated,error:=translate(&lib,material,{landscape=&mapping})
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer translated_destroy(&translated)
    if !testing.expect(t,!translated_is_standard(&translated)) {return}
    source:=translated.program.source
    testing.expect(t,strings.contains(source,"#include \"terrain_surface.slang\"") && strings.contains(source,"terrain_weights_at(control,"),"the weights of the maps of the terrain")
    testing.expect(t,strings.contains(source,"//! parameter control {\"kind\":\"texture\"}") && strings.contains(source,"struct Parameters {uint control;uint normal;uint paint;"),"the maps each piece gives")
    testing.expect(t,strings.contains(source,"unreal_layer_weight(landscape,4u)") && strings.contains(source,"unreal_layer_weight(landscape,5u)"),"each layer by the weight of its layer of the terrain")
    for p in translated.program.parameters {testing.expect(t,p.piece==(p.name=="control" || p.name=="normal" || p.name=="paint" || p.name=="piece" || p.name=="palette"),p.name)}
    testing.expect(t,!strings.contains(source,"ctx.uv0;"),"no uv set is the coordinates of the landscape")
    testing.expect(t,strings.contains(source,"unreal_point(mirai_world_position(ctx))") && !strings.contains(source,"ctx.lod"),"its coordinates from the world, with their derivatives")
    body:=source[max(strings.index(source,"Mirai_Surface evaluate("),0):]
    branch:=strings.index(body,"if (")
    sampled:=strings.index(body,"mirai_sample_texture(ctx,")
    testing.expect(t,branch>=0 && sampled>branch && sampled<strings.index(body[branch:],"    }\n")+branch,"Rock is read only where its layer is painted")
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
// Dynamic Parameter, or the default where it gives none), its random value, its
// radius and its color are seen by a program.
@(test)
the_screen_the_depth_and_the_bounds_are_seen_by_a_program :: proc(t:^testing.T) {
    b:=material_begin("M_Screen")
    w:=fx.writer(&b.p)
    screen:=expression(&b,"ScreenPosition","Screen",&w)
    w=fx.writer(&b.p)
    depth:=expression(&b,"PixelDepth","Depth",&w)
    w=fx.writer(&b.p)
    tint:=expression(&b,"ParticleColor","Tint",&w)
    w=fx.writer(&b.p)
    fx.float_put(&w,"FadeDistanceDefault",50)
    fx.input_put(&w,"InOpacity","ExpressionInput",{expression=tint,mask={false,false,false,true}})
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
    fx.enum_put(&m,"TranslucencyLightingMode","ETranslucencyLightingMode","TLM_SurfacePerPixelLighting")
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
    for code in ([]string{"ctx.screen","ctx.screen_size","ctx.depth*100.0","ctx.scene_depth*100.0","unreal_object_bounds(ctx,1)","unreal_object_axis(ctx,2)","((ctx.particle_given>>2u)&1u)!=0u?ctx.particle_data[2]:float4(0.25,0.5,0.75,1","ctx.particle_random","ctx.particle_radius*100.0","ctx.vertex_color"}) {
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

// The Unreal uv sets a material reads are the uv sets of the mesh, lowest
// first, wherever they are; one past the two a mesh holds, or that no Unreal
// mesh has, is not translated.
@(test)
the_uv_sets_a_material_reads_are_those_of_the_mesh_lowest_first :: proc(t:^testing.T) {
    Case :: struct {
        name:string,
        reads:[3]i32, // the set the base color, emission and normal sample; -1: none
        uv_sets,past:Unreal_UV_Sets,
        slots:[3]u32, // the uv set of the mesh each map reads
        untranslated:int,
    }
    cases:=[]Case{
        {"M_Third",{2,-1,-1},{2},{},{0,0,0},0},
        {"M_Apart",{3,1,-1},{1,3},{},{1,0,0},0},
        {"M_Three",{0,1,2},{0,1},{2},{0,1,0},1},
        {"M_None",{9,-1,-1},{},{},{0,0,0},1},
    }
    for c in cases {
        b:=material_begin(c.name)
        m:=fx.writer(&b.p)
        outputs:=[3]struct{input,kind,sampler:string}{{"BaseColor","ColorMaterialInput",""},{"EmissiveColor","ColorMaterialInput",""},{"Normal","VectorMaterialInput","SAMPLERTYPE_Normal"}}
        for output,i in outputs {
            if c.reads[i]<0 {continue}
            w:=fx.writer(&b.p)
            fx.object_put(&w,"Texture",texture_ref(&b,output.input))
            if output.sampler!="" {fx.enum_put(&w,"SamplerType","EMaterialSamplerType",output.sampler)}
            fx.int_put(&w,"ConstCoordinate",c.reads[i])
            sample:=expression(&b,"TextureSample",output.input,&w)
            fx.input_put(&m,output.input,output.kind,{expression=sample,mask=RGB})
        }
        b.p.exports[0].data=fx.finish(&m)
        path:=fmt.tprintf("/Game/M/%s",c.name)
        lib:Library
        library_with(&lib,{path,fx.package_bytes(&b.p,path)})
        defer library_destroy(&lib)
        translated,ok:=translate_one(t,&lib,path)
        if !ok {continue}
        defer translated_destroy(&translated)
        testing.expectf(t,translated.uv_sets==c.uv_sets && translated.uv_sets_past==c.past,"%s reads %v and past them %v",c.name,translated.uv_sets,translated.uv_sets_past)
        untranslated:=0
        for u in translated.untranslated {untranslated+=u.count}
        testing.expectf(t,untranslated==c.untranslated,"%s: %v",c.name,translated.untranslated)
        if !testing.expectf(t,translated_is_standard(&translated),"%s is the standard model",c.name) {continue}
        maps:=asset.material_maps(&translated.info.maps)
        for kind,i in ([3]asset.Material_Map_Kind{.Base_Color,.Emission,.Normal}) {
            if c.reads[i]<0 || i==2 && c.past!={} {continue}
            testing.expectf(t,maps[kind].uv_set==c.slots[i],"%s: the %v map reads uv %d: %v",c.name,kind,c.slots[i],maps[kind])
        }
    }
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
    // A sample at what custom HLSL computes: the program cannot carry its derivatives.
    w=fx.writer(&b.p)
    fx.object_put(&w,"Texture",texture_ref(&b,"T_Glow"))
    fx.input_put(&w,"Coordinates","ExpressionInput",{expression=ported,mask={true,true,false,false}})
    glow:=expression(&b,"TextureSample","Glow",&w)
    m:=fx.writer(&b.p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=ported})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=ported,output=1})
    fx.input_put(&m,"Metallic","ScalarMaterialInput",{expression=viewed})
    fx.input_put(&m,"EmissiveColor","ColorMaterialInput",{expression=glow,mask=RGB})
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
    // The whole program takes the derivatives of the quad, and the import says why.
    testing.expect(t,strings.contains(source,",ctx.lod)") && !strings.contains(source,"mirai_uv0(ctx)"),"the sample takes the derivatives of the quad")
    warned:=false
    for n in translated.notes {warned||=strings.contains(n,"keeps the derivatives of the quad") && strings.contains(n,"Custom expression Ported")}
    testing.expectf(t,warned,"a note names the custom expression: %v",translated.notes)
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

// A grass output whose Meadow grass reads the weight of the layer Meadow as
// it is, whose Rock grass reads Rock's where the normal is steeper than 0.7
// (about 44 degrees) and whose Tall grass a contrast of 7 over Meadow: each
// names the layers its input reads, the slopes and least weight of the
// foliage rule closest to it, and the varieties of its grass type, read with
// the defaults of a variety for what they do not save; an input without a
// grass type grows nothing.
@(test)
a_grass_output_gives_each_grass_type_its_layers_rule_and_varieties :: proc(t:^testing.T) {
    b:=material_begin("M_Ground")
    samples:[2]i32
    for &sample,i in samples {
        w:=fx.writer(&b.p)
        fx.name_property_put(&w,"ParameterName",i==0?"Meadow":"Rock")
        sample=expression(&b,"LandscapeLayerSample",i==0?"Meadow":"Rock",&w)
    }
    normal_writer:=fx.writer(&b.p)
    normal:=expression(&b,"PixelNormalWS","Normal",&normal_writer)
    up:=fx.writer(&b.p)
    fx.input_put(&up,"Input","ExpressionInput",{expression=normal})
    fx.bool_put(&up,"B",true)
    vertical:=expression(&b,"ComponentMask","Up",&up)
    below:=fx.writer(&b.p)
    fx.input_put(&below,"A","ExpressionInput",{expression=vertical})
    fx.float_put(&below,"ConstB",0.7)
    flat:=expression(&b,"Subtract","Flat",&below)
    sharp:=fx.writer(&b.p)
    fx.input_put(&sharp,"A","ExpressionInput",{expression=flat})
    fx.float_put(&sharp,"ConstB",20)
    sharpened:=expression(&b,"Multiply","Sharp",&sharp)
    clamp_writer:=fx.writer(&b.p)
    fx.input_put(&clamp_writer,"Input","ExpressionInput",{expression=sharpened})
    mask:=expression(&b,"Saturate","Mask",&clamp_writer)
    masked:=fx.writer(&b.p)
    fx.input_put(&masked,"A","ExpressionInput",{expression=samples[1]})
    fx.input_put(&masked,"B","ExpressionInput",{expression=mask})
    rock:=expression(&b,"Multiply","Rocky",&masked)
    contrast:=fx.writer(&b.p)
    fx.float_put(&contrast,"ConstA",-7)
    fx.float_put(&contrast,"ConstB",8)
    fx.input_put(&contrast,"Alpha","ExpressionInput",{expression=samples[0]})
    stretched:=expression(&b,"LinearInterpolate","Contrast",&contrast)
    tall_writer:=fx.writer(&b.p)
    fx.input_put(&tall_writer,"Input","ExpressionInput",{expression=stretched})
    tall_input:=expression(&b,"Saturate","Tall",&tall_writer)
    grass_type:=fx.external(&b.p,"/Game/G/GT_Meadow","/Script/Landscape","LandscapeGrassType","GT_Meadow")
    entries:=[4][]u8{}
    names:=[4]string{"Meadow","Rock","Tall","Bare"}
    inputs:=[4]i32{samples[0],rock,tall_input,samples[0]}
    for &entry,i in entries {
        w:=fx.writer(&b.p)
        fx.name_property_put(&w,"Name",names[i])
        if i<3 {fx.object_put(&w,"GrassType",grass_type)}
        fx.input_put(&w,"Input","ExpressionInput",{expression=inputs[i]})
        entry=fx.end(&w)
    }
    output:=fx.writer(&b.p)
    fx.structs_put(&output,"GrassTypes","GrassInput",entries[:])
    expression(&b,"LandscapeGrassOutput","Grass",&output)
    m:=fx.writer(&b.p)
    b.p.exports[0].data=fx.finish(&m)

    g:=fx.package_make()
    platform_put :: proc(w:^fx.Writer,property,kind:string,bits:u32) {
        body:=fx.writer(w.p)
        fx.u32_put(&body,0)
        fx.u32_put(&body,bits)
        fx.u32_put(&body,0)
        fx.struct_put(w,property,kind,body.bytes[:])
    }
    mesh:=fx.external(&g,"/Game/G/SM_Blades","/Script/Engine","StaticMesh","SM_Blades")
    tall:=fx.writer(&g)
    fx.object_put(&tall,"GrassMesh",mesh)
    platform_put(&tall,"GrassDensity","PerPlatformFloat",transmute(u32)f32(150))
    platform_put(&tall,"EndCullDistance","PerPlatformInt",5000)
    fx.enum_put(&tall,"Scaling","EGrassScaling","EGrassScaling::Free")
    scale_z:=fx.writer(&g)
    fx.float_put(&scale_z,"Min",0.8)
    fx.float_put(&scale_z,"Max",1.3)
    fx.struct_put(&tall,"ScaleZ","FloatInterval",fx.end(&scale_z))
    fx.bool_put(&tall,"bCastDynamicShadow",false)
    plain:=fx.writer(&g)
    fx.object_put(&plain,"GrassMesh",mesh)
    varieties:=fx.writer(&g)
    fx.structs_put(&varieties,"GrassVarieties","GrassVariety",{fx.end(&tall),fx.end(&plain)})
    fx.export(&g,fx.class(&g,"/Script/Landscape","LandscapeGrassType"),0,"GT_Meadow",fx.finish(&varieties))

    lib:Library
    library_with(&lib,{"/Game/M/M_Ground",fx.package_bytes(&b.p,"/Game/M/M_Ground")},{"/Game/G/GT_Meadow",fx.package_bytes(&g,"/Game/G/GT_Meadow")})
    defer library_destroy(&lib)
    material,_:=object_find(&lib,"/Game/M/M_Ground")
    grass,error:=landscape_grass(&lib,material,context.temp_allocator)
    if !testing.expect_value(t,error.code,Error_Code.None) || !testing.expect_value(t,len(grass),3) {return}
    meadow,stones,steep:=grass[0],grass[1],grass[2]
    testing.expect(t,meadow.name=="Meadow" && meadow.type=="/Game/G/GT_Meadow.GT_Meadow")
    testing.expect(t,len(meadow.layers)==1 && meadow.layers[0]=="Meadow")
    testing.expectf(t,meadow.fit.ok && meadow.fit.slope=={0,math.PI/2} && meadow.fit.weight==0 && meadow.fit.error<1e-6,"Meadow grows as its layer weighs: %v",meadow.fit)
    degrees:=stones.fit.slope*180/math.PI
    testing.expect(t,len(stones.layers)==1 && stones.layers[0]=="Rock")
    testing.expectf(t,stones.fit.ok && degrees[0]==0 && degrees[1]>42 && degrees[1]<46 && stones.fit.weight==0 && stones.fit.error<0.05,"Rock grows up to the slope of its mask: %v",stones.fit)
    testing.expectf(t,steep.fit.ok && steep.fit.slope=={0,math.PI/2} && steep.fit.weight>=0.4 && steep.fit.weight<=0.55,"Tall grows past the middle of its contrast: %v",steep.fit)
    if !testing.expect_value(t,len(meadow.varieties),2) {return}
    v:=meadow.varieties[0]
    testing.expect_value(t,v.mesh,"/Game/G/SM_Blades.SM_Blades")
    testing.expect_value(t,v.density,f32(1.5))
    testing.expect_value(t,v.cull,[2]f32{100,50})
    testing.expect_value(t,v.scaling,Grass_Scaling.Free)
    testing.expect_value(t,v.scale,[3][2]f32{{1,1},{1,1},{0.8,1.3}})
    testing.expect(t,!v.casts_shadow && v.random_rotation && v.align)
    d:=meadow.varieties[1]
    testing.expect(t,d.density==4 && d.cull=={100,100} && d.weights=={0,1} && d.scaling==.Uniform && d.casts_shadow,"the defaults of a variety")
}
