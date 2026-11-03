package unreal_fluids_editor

import "core:strings"
import "core:testing"
import material "project:plugins/unreal/editor/material"
import fx "project:plugins/unreal/editor/material/fixture"
import fluids "project:plugins/fluids/runtime"

// An output material of FluidNinja samples VelocityDensityBuffer, which its
// Blueprints fill as the game runs: with the reads of the plugin its program
// reads the fluid by UV, turned to Unreal's axes, and the buffer is no texture
// of the material.
@(test)
fluidninja_output_materials_read_the_fluid :: proc(t:^testing.T) {
    p:=fx.package_make()
    engine :: "/Script/Engine"
    m:=fx.export(&p,fx.class(&p,engine,"Material"),0,"M_NinjaOutput",nil)
    w:=fx.writer(&p)
    coordinates:=fx.export(&p,fx.class(&p,engine,"MaterialExpressionTextureCoordinate"),m,"UV",fx.finish(&w))
    w=fx.writer(&p)
    fx.name_property_put(&w,"ParameterName","VelocityDensityBuffer")
    buffer:=fx.export(&p,fx.class(&p,engine,"MaterialExpressionTextureObjectParameter"),m,"Buffer",fx.finish(&w))
    w=fx.writer(&p)
    fx.input_put(&w,"TextureObject","ExpressionInput",{expression=buffer})
    fx.input_put(&w,"Coordinates","ExpressionInput",{expression=coordinates})
    sample:=fx.export(&p,fx.class(&p,engine,"MaterialExpressionTextureSample"),m,"Sample",fx.finish(&w))
    w=fx.writer(&p)
    fx.input_put(&w,"BaseColor","ColorMaterialInput",{expression=sample,mask={true,true,true,false}})
    p.exports[0].data=fx.finish(&w)
    lib:material.Library
    material.library_init(&lib,nil)
    defer material.library_destroy(&lib)
    material.library_add(&lib,"/Game/M/M_NinjaOutput",fx.package_bytes(&p,"/Game/M/M_NinjaOutput"))
    object,found:=material.object_find(&lib,"/Game/M/M_NinjaOutput.M_NinjaOutput")
    if !testing.expect(t,found) {return}
    provider:=fluids_unreal_default().provider
    translated,error:=material.translate(&lib,object,{reads=provider.reads[:provider.read_count]})
    if !testing.expect_value(t,error.code,material.Error_Code.None) {return}
    defer material.translated_destroy(&translated)
    if !testing.expect(t,!material.translated_is_standard(&translated)) {return}
    source:=translated.program.source
    // Turned to the axes of Unreal, along which FluidNinja lays its simulation.
    testing.expect(t,strings.contains(source,"#include \"fluid_ninja.slang\""),source)
    testing.expect(t,strings.contains(source,"fluid_ninja_buffer(\"" + fluids.GRID + "\","),source)
    testing.expect_value(t,len(translated.program.parameters),0)
}
