package unreal_vfx_editor

import "core:strings"
import "core:testing"
import fixture "project:plugins/unreal/editor/fixture/files"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import "mirai:cook/textures"

@(test)
niagara_names_are_the_symbols_its_translator_writes :: proc(t:^testing.T) {
    cases:=[?][2]string{
        {"Constants.Emitter.ShapeLocation.Box Size","Constants_Emitter_ShapeLocation_BoxSize"},
        {"Constants.Emitter.ShapeLocation.Yaw/Pitch/Roll","Constants_Emitter_ShapeLocation_YawASC47PitchASC47Roll"},
        {"Emitter.Attribute Reader","Emitter_AttributeReader"},
        {"User.2D Grid","User_INTEGER_2DGrid"},
        {"Emitter.My__Value","Emitter_MyASC95ASC95Value"},
    }
    for each in cases {testing.expect_value(t,niagara_symbol(each[0]),each[1])}
    testing.expect_value(t,niagara_emitter_alias("Constants.Grid_Read.ShapeLocation.Box Size"),"Constants.Emitter.ShapeLocation.Box Size")
    testing.expect_value(t,niagara_emitter_alias("User.Mesh"),"User.Mesh")
}

// A 2D render target is flat along y, as a texture of the world: its cell
// (x, y) is (x, 0, y) of the grid, and what the scripts read keeps the order
// of Niagara. A 3D one keeps its axes.
@(test)
a_2d_grid_is_flat_along_y :: proc(t:^testing.T) {
    w:Niagara_Writer
    flat:=Niagara_Di{kind=.Render_Target,resource="di_rt"}
    body,ok:=niagara_grid_body(&w,&flat,"SetRenderTargetValue","",{{"bool","Enabled"},{"int","X"},{"int","Y"},{"float4","Value"}})
    testing.expect(t,ok && strings.contains(body,"niagara_grid_write4(di_rt, int3(X, 0, Y), Value)"),body)
    body,ok=niagara_grid_body(&w,&flat,"GetRenderTargetSize","",{{"out int","Width"},{"out int","Height"}})
    testing.expect(t,ok && strings.contains(body,"Width = niagara_grid_cells(di_rt).xzy.x;") && strings.contains(body,"Height = niagara_grid_cells(di_rt).xzy.y;"),body)
    body,ok=niagara_grid_body(&w,&flat,"SampleRenderTarget","",{{"float2","UV"},{"out float4","Value"}})
    testing.expect(t,ok && strings.contains(body,"niagara_grid_sample(di_rt, float3((UV).x, 0.5, (UV).y), 0)"),body)
    volume:=Niagara_Di{kind=.Render_Target,resource="di_rt",three=true}
    body,ok=niagara_grid_body(&w,&volume,"SetRenderTargetValue","",{{"bool","Enabled"},{"int","X"},{"int","Y"},{"int","Z"},{"float4","Value"}})
    testing.expect(t,ok && strings.contains(body,"int3(X, Y, Z)"),body)
    // The scripts of an emitter name its grid Emitter. and those of the system by the emitter: one grid.
    e:=Unreal_Emitter{name="Sprites"}
    own:=Niagara_Di{name="Emitter.Render Target 2D",class="RenderTarget2D"}
    named:=Niagara_Di{name="Sprites.Render Target 2D",class="RenderTarget2D"}
    testing.expect_value(t,niagara_grid_key(&w,&e,&named),niagara_grid_key(&w,&e,&own))
}

// A texture is a grid flat along y of one cell a texel, resampled down to
// NIAGARA_TEXTURE_CELLS, that SampleTexture2D samples by its uv.
@(test)
a_texture_is_baked_into_a_grid_its_program_samples :: proc(t:^testing.T) {
    small:=[]u8{0,0,0,255, 255,0,0,255, 0,255,0,255, 0,0,255,255}
    cells,values,ok:=niagara_texture_cells(textures.rgba8(small,2,2),false)
    testing.expect(t,ok && cells==[2]int{2,2})
    testing.expect_value(t,values[1*4+0],f32(1)) // the second texel of the first row: red
    testing.expect_value(t,values[2*4+1],f32(1)) // the first of the second row: green
    wide:=make([]u8,(NIAGARA_TEXTURE_CELLS*2)*4*4,context.temp_allocator)
    for i in 0..<NIAGARA_TEXTURE_CELLS*2*4 {wide[i*4]=u8(255*(i%2))}
    cells,values,ok=niagara_texture_cells(textures.rgba8(wide,NIAGARA_TEXTURE_CELLS*2,4),false)
    testing.expect(t,ok && cells==[2]int{NIAGARA_TEXTURE_CELLS,2})
    testing.expect(t,abs(values[0]-0.5)<1e-4,"two texels in a cell are their average")
    w:Niagara_Writer
    di:=Niagara_Di{kind=.Texture,resource="di_logo",texture={cells={64,32}}}
    body,sampled:=niagara_texture_body(&w,&di,"SampleTexture2D",{{"float2","UV"},{"out float4","Value"}})
    testing.expect(t,sampled && strings.contains(body,"Value = niagara_texture_sample(di_logo, UV);"),body)
    body,sampled=niagara_texture_body(&w,&di,"GetTextureDimensions",{{"int","Mip"},{"out float2","Size"}})
    testing.expect(t,sampled && strings.contains(body,"Size = float2(64, 32);"),body)
}

@(test)
niagara_attributes_a_specifier_names_are_the_last_of_it :: proc(t:^testing.T) {
    testing.expect_value(t,niagara_attribute_named("_AttributePrevious_Position"),"Previous_Position")
    testing.expect_value(t,niagara_attribute_named("_AttributeRGBA"),"RGBA")
    testing.expect_value(t,niagara_attribute_named("_NoAttribute"),"")
}

// An event handler of an emitter is not translated: its problem names its
// script and its event, and what to use instead.
@(test)
niagara_event_handlers_say_what_to_use_instead :: proc(t:^testing.T) {
    w:=fixture.writer_make({package_name="/Game/FX/NS_Events"})
    empty:=fixture.bytes_make()
    fixture.none(&empty,&w)
    fixture.put_u32(&empty,0)
    script:=fixture.export_add(&w,{class=fixture.script_class(&w,"/Script/Niagara","NiagaraScript"),name="EventHandler_Location",data=empty.data[:]})
    handler:=fixture.bytes_make()
    fixture.object_property(&handler,&w,"Script",script)
    fixture.name_property(&handler,&w,"SourceEventName","LocationEvent")
    props:=fixture.bytes_make()
    fixture.struct_array_property(&props,&w,"EventHandlerScriptProps","NiagaraEventScriptProperties",{handler})
    fixture.none(&props,&w)
    fixture.put_u32(&props,0)
    emitter:=fixture.export_add(&w,{class=fixture.script_class(&w,"/Script/Niagara","NiagaraEmitter"),name="Sparks",data=props.data[:]})
    p,error:=unreal.package_open(fixture.package_bytes(&w),context.temp_allocator)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None) {return}
    lib:level.Library
    level.library_init(&lib,nil,context.temp_allocator)
    index,_:=level.library_add(&lib,"/Game/FX/NS_Events",&p)
    d:=level.Document{library=&lib,allocator=context.temp_allocator}
    d.properties.allocator,d.templates.allocator,d.by_ref.allocator=context.temp_allocator,context.temp_allocator,context.temp_allocator
    ref:=level.Ref{i32(index),unreal.Object_Ref(emitter)}
    held,held_error:=level.object_properties(&d,ref)
    if !testing.expect(t,held_error.code==.None && held!=nil) {return}
    f:=level.Found{pkg=level.library_package(&lib,index),origin=.Authored}
    problems:=niagara_event_handlers(&d,ref,f,&held.list)
    if !testing.expect_value(t,len(problems),1) {return}
    for part in ([]string{"EventHandler_Location","LocationEvent","Data Channel","Particle Attribute Reader"}) {
        testing.expectf(t,strings.contains(problems[0],part),"the problem names %s: %s",part,problems[0])
    }
}
