package unreal_scene

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import fixture "project:plugins/unreal/editor/fixture/files"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"

// A post process volume of Unreal is whole inside its brush and fades out
// over its blend radius beyond it; the volume it becomes keeps both borders,
// whatever the scale of the actor.
@(test)
a_post_process_volume_blends_beyond_its_brush_as_in_unreal :: proc(t:^testing.T) {
    pose:=mm.Transform{position={0,0,0},rotation=1,scale={2,1,1}}
    place,blend:=volume.box({1,3,3}),f32(1)
    place.extents=blend_beyond(place.extents,blend,pose.scale)
    testing.expect_value(t,volume.weight(place,pose,{2,0,0},blend),f32(1))
    testing.expect_value(t,volume.weight(place,pose,{2.5,0,0},blend),f32(0.5))
    testing.expect_value(t,volume.weight(place,pose,{3,0,0},blend),f32(0))
    testing.expect_value(t,volume.weight(place,pose,{0,3,0},blend),f32(1))
    testing.expect_value(t,volume.weight(place,pose,{0,4,0},blend),f32(0))
}

// The post process of a level is Unreal's defaults everywhere, under each
// volume with what it overrides over what the unbound volumes below it give:
// a bound volume that overrides only the contrast keeps the exposure and the
// saturation of the unbound one under it. Saturation and contrast are a
// ColorGrade layer; without the lens plugin's bridge, bloom and vignette are
// a warning that names that plugin, apart from what has no equivalent.
@(test)
a_post_process_volume_overrides_unreals_defaults_over_the_volumes_below_it :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-unreal-post-process-%d",directory,os.get_pid())
    os.remove_all(top)
    defer os.remove_all(top)
    root:=fmt.tprintf("%s/project",top)
    os.make_directory_all(root)
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    os.make_directory_all(fmt.tprintf("%s/assets/Unreal/Content/Maps",root))
    _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Levels.uproject",root),"{}")
    l:=fixture.level_begin("/Game/Maps/Cave")
    class:=fixture.engine_class(&l.w,"PostProcessVolume")
    brush:=fixture.engine_class(&l.w,"BrushComponent")
    global:=fixture.actor_add(&l,class,"PostProcessVolume_0","Global")
    settings:=fixture.bytes_make()
    for name in ([?]string{"AutoExposureBias","BloomIntensity","VignetteIntensity","ColorSaturation","BloomThreshold"}) {fixture.bool_property(&settings,&l.w,fmt.tprintf("bOverride_%s",name),true)}
    fixture.float_property(&settings,&l.w,"AutoExposureBias",-1)
    fixture.float_property(&settings,&l.w,"BloomIntensity",2)
    fixture.vector4_property(&settings,&l.w,"ColorSaturation",{1,0.5,0.5,0.5})
    props:=fixture.bytes_make()
    fixture.bool_property(&props,&l.w,"bUnbound",true)
    fixture.float_property(&props,&l.w,"Priority",1)
    fixture.struct_property(&props,&l.w,"Settings","PostProcessSettings",&settings)
    fixture.actor_set(&l,global,fixture.component_add(&l,global,brush,"BrushComponent0",fixture.bytes_make()),props)
    room:=fixture.actor_add(&l,class,"PostProcessVolume_1","Room")
    room_settings:=fixture.bytes_make()
    fixture.bool_property(&room_settings,&l.w,"bOverride_ColorContrast",true)
    fixture.vector4_property(&room_settings,&l.w,"ColorContrast",{1,1,1,2})
    room_props:=fixture.bytes_make()
    fixture.float_property(&room_props,&l.w,"Priority",2)
    fixture.struct_property(&room_props,&l.w,"Settings","PostProcessSettings",&room_settings)
    room_brush:=fixture.component_add(&l,room,brush,"BrushComponent0",fixture.bytes_make())
    fixture.component_add(&l,room,fixture.engine_class(&l.w,"CubeBuilder"),"CubeBuilder_0",fixture.bytes_make())
    fixture.actor_set(&l,room,room_brush,room_props)
    level:=fmt.tprintf("%s/assets/Unreal/Content/Maps/Cave.umap",root)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    report,error:=level_import(level,{root=root},{},"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer level_report_destroy(&report)
    named,unmatched:=false,false
    for w in report.imports.warnings {
        if strings.contains(w,"lens plugin") {named=strings.contains(w,"BloomIntensity") && strings.contains(w,"VignetteIntensity")}
        if strings.contains(w,"no equivalent") {unmatched=strings.contains(w,"BloomThreshold") && !strings.contains(w,"Color") && !strings.contains(w,"Intensity")}
    }
    testing.expect(t,named,"bloom and vignette name the lens plugin")
    testing.expect(t,unmatched,"the threshold of the bloom has no equivalent; saturation, bloom and vignette do")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    // The value of a parameter of the ColorGrade material of a layer.
    graded :: proc(t:^testing.T,report:^Level_Report,types:^asset.Types,id:base.Asset_Id,name:string) -> (value:[4]f64) {
        for w in report.imports.assets {
            if w.id!=id {continue}
            a:asset.Asset
            if !testing.expect_value(t,asset.asset_load(&a,w.path),asset.Error.None) {return}
            defer asset.asset_close(&a)
            view,error:=asset.material_view(&a,types)
            if !testing.expect_value(t,error,asset.Error.None) {return}
            testing.expect_value(t,base.text_get(view.info.program[:]),"ColorGrade")
            for &p in view.parameters {if base.text_get(p.name[:])==name {return p.value}}
        }
        testing.expectf(t,false,"no %s in the grade %v",name,id)
        return
    }
    looks:=make(map[string]render.View_Volume,context.temp_allocator)
    for row in 0..<asset.scene_entity_count(&scene) {
        e:=asset.scene_entity(&scene,row)
        if look,ok:=asset.scene_get(&scene,e.id,"View_Volume",render.View_Volume);ok {looks[e.name]=look}
    }
    base_look,based:=looks["Post process"]
    if !testing.expect(t,based,"the look where no volume is") {return}
    testing.expect_value(t,base_look.exposure.compensation,f32(1))
    testing.expect(t,base_look.layers[0].material=={},"Unreal's default grade leaves the image as it is")
    testing.expect(t,base_look.zone.priority<1,"under every volume")
    global_look:=looks["Global"]
    testing.expect_value(t,global_look.exposure.compensation,f32(-1))
    testing.expect_value(t,graded(t,&report,&types,global_look.layers[0].material,"saturation"),[4]f64{0.5,0.25,0.25,0})
    room_look,roomed:=looks["Room"]
    if !testing.expect(t,roomed,"the room is a View_Volume") {return}
    testing.expect_value(t,room_look.exposure.compensation,f32(-1))
    testing.expect_value(t,graded(t,&report,&types,room_look.layers[0].material,"saturation"),[4]f64{0.5,0.25,0.25,0})
    testing.expect_value(t,graded(t,&report,&types,room_look.layers[0].material,"contrast"),[4]f64{2,2,2,0})
}

// A level without post process volumes looks as Unreal's defaults for its
// project do: here without auto exposure, so a luminance of one is white.
@(test)
a_level_without_post_process_volumes_has_unreals_default_look :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-unreal-post-default-%d",directory,os.get_pid())
    os.remove_all(top)
    defer os.remove_all(top)
    root:=fmt.tprintf("%s/project",top)
    os.make_directory_all(root)
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    os.make_directory_all(fmt.tprintf("%s/assets/Unreal/Content/Maps",root))
    os.make_directory_all(fmt.tprintf("%s/assets/Unreal/Config",root))
    _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Levels.uproject",root),"{}")
    _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Config/DefaultEngine.ini",root),"[/Script/Engine.RendererSettings]\nr.DefaultFeature.AutoExposure=False\nr.DefaultFeature.AutoExposure.Bias=0.5\n")
    l:=fixture.level_begin("/Game/Maps/Plain")
    level:=fmt.tprintf("%s/assets/Unreal/Content/Maps/Plain.umap",root)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    report,error:=level_import(level,{root=root},{},"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    found:=false
    for row in 0..<asset.scene_entity_count(&scene) {
        e:=asset.scene_entity(&scene,row)
        look,ok:=asset.scene_get(&scene,e.id,"View_Volume",render.View_Volume)
        if !ok {continue}
        found=true
        testing.expect_value(t,e.name,"Post process")
        testing.expect_value(t,look.exposure.compensation,f32(0.5))
        white:=render.ev100_white(1)
        testing.expectf(t,look.exposure.min_ev100==white && look.exposure.max_ev100==white,"a fixed exposure: %v",look.exposure)
    }
    testing.expect(t,found,"the defaults are a View_Volume of the whole world")
}
