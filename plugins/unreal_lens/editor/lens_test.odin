package unreal_lens_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import fixture "project:plugins/unreal/editor/fixture/files"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:project"
import render "mirai:engine/render"
import evolume "mirai:engine/volume"
import lens "plugins:lens/runtime"

// The post process of a level through the lens: where no volume is, the
// bloom and vignette of Unreal's defaults; an unbound volume that overrides
// its exposure, bloom and vignette is a View_Volume and a Lens_Volume of the
// whole world on one entity, by its priority; a bound one that overrides
// only its vignette, over it, a Lens_Volume alone in its box with the bloom
// of the unbound one below it. Unreal's bloom adds k of the light, which is k/(1+k)
// of its image; its vignette darkens the corners of its default view as much
// as the share of the natural falloff does there. What has no equivalent is
// a warning; bloom and vignette are not.
@(test)
the_bloom_and_vignette_of_an_unreal_post_process_volume_are_a_lens_volume :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-lens-unreal-%d",directory,os.get_pid())
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
    for name in ([?]string{"AutoExposureBias","BloomIntensity","VignetteIntensity","BloomThreshold"}) {fixture.bool_property(&settings,&l.w,fmt.tprintf("bOverride_%s",name),true)}
    fixture.float_property(&settings,&l.w,"AutoExposureBias",1)
    fixture.float_property(&settings,&l.w,"BloomIntensity",2)
    fixture.float_property(&settings,&l.w,"VignetteIntensity",0.5)
    props:=fixture.bytes_make()
    fixture.bool_property(&props,&l.w,"bUnbound",true)
    fixture.float_property(&props,&l.w,"Priority",2)
    fixture.struct_property(&props,&l.w,"Settings","PostProcessSettings",&settings)
    fixture.actor_set(&l,global,fixture.component_add(&l,global,brush,"BrushComponent0",fixture.bytes_make()),props)

    room:=fixture.actor_add(&l,class,"PostProcessVolume_1","Room")
    room_settings:=fixture.bytes_make()
    fixture.bool_property(&room_settings,&l.w,"bOverride_VignetteIntensity",true)
    fixture.float_property(&room_settings,&l.w,"VignetteIntensity",0)
    room_props:=fixture.bytes_make()
    fixture.float_property(&room_props,&l.w,"BlendRadius",0)
    fixture.float_property(&room_props,&l.w,"Priority",3)
    fixture.struct_property(&room_props,&l.w,"Settings","PostProcessSettings",&room_settings)
    room_brush:=fixture.component_add(&l,room,brush,"BrushComponent0",fixture.bytes_make())
    box:=fixture.bytes_make()
    fixture.float_property(&box,&l.w,"X",400)
    fixture.float_property(&box,&l.w,"Y",200)
    fixture.float_property(&box,&l.w,"Z",100)
    fixture.component_add(&l,room,fixture.engine_class(&l.w,"CubeBuilder"),"CubeBuilder_0",box)
    fixture.actor_set(&l,room,room_brush,room_props)

    level:=fmt.tprintf("%s/assets/Unreal/Content/Maps/Cave.umap",root)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    provider:=lens_unreal_default().provider
    report,error:=unreal_scene.level_import(level,{root=root},provider.translators[:provider.count],"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer unreal_scene.level_report_destroy(&report)
    no_equivalent:=false
    for w in report.imports.warnings {
        if !strings.contains(w,"no equivalent") {continue}
        no_equivalent=true
        testing.expectf(t,strings.contains(w,"BloomThreshold") && !strings.contains(w,"Intensity"),"only what has no equivalent: %s",w)
    }
    testing.expect(t,no_equivalent,"the threshold of the bloom is a warning")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    found:=0
    // k/(1+k) of a bloom that adds intensity × (0.3465 + 0.138 + 0.1176 + 0.066 + 0.066 + 0.061) / 6.
    share :: proc(intensity:f32) -> f32 {k:=intensity*0.7951/6;return k/(1+k)}
    // 1 - share + share/(1 + 1 + (9/16)²)² at the corners is Unreal's 1/(1 + 2·intensity²)².
    corner :: proc(vignette:f32) -> f32 {return 1-vignette+vignette/((2+81.0/256)*(2+81.0/256))}
    for row in 0..<asset.scene_entity_count(&scene) {
        e:=asset.scene_entity(&scene,row)
        look,lensed:=asset.scene_get(&scene,e.id,"Lens_Volume",lens.Lens_Volume)
        if !lensed {continue}
        view,viewed:=asset.scene_get(&scene,e.id,"View_Volume",render.View_Volume)
        place,bounded:=asset.scene_get(&scene,e.id,"Volume",evolume.Volume)
        switch e.name {
        case "Post process":
            found+=1
            testing.expect(t,!bounded && viewed && look.zone.priority<2,"the defaults are under every volume, everywhere")
            testing.expectf(t,abs(look.lens.bloom-share(0.675))<1e-5,"the default bloom %v",look.lens.bloom)
            testing.expectf(t,abs(corner(look.lens.vignette)-1/(1.32*1.32))<1e-5,"the default vignette %v",look.lens.vignette)
        case "Global":
            found+=1
            testing.expect(t,viewed && view.exposure.compensation==1,"its exposure is the View_Volume of the same entity")
            testing.expect(t,!bounded,"unbound: the whole world")
            testing.expect_value(t,look.zone.priority,i32(2))
            testing.expectf(t,abs(look.lens.bloom-share(2))<1e-5,"bloom %v",look.lens.bloom)
            testing.expectf(t,abs(corner(look.lens.vignette)-1/(1.5*1.5))<1e-5,"vignette %v",look.lens.vignette)
        case "Room":
            found+=1
            testing.expect(t,!viewed,"it overrides nothing of the View_Volume")
            testing.expect(t,bounded && place.shape==.Box,"its box")
            testing.expect_value(t,look.lens.vignette,f32(0))
            testing.expectf(t,abs(look.lens.bloom-share(2))<1e-5,"the bloom of the volume below: %v",look.lens.bloom)
        }
    }
    testing.expect_value(t,found,3)
}
