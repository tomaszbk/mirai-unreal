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

// Without the lens plugin's bridge, the bloom and vignette a post process
// volume overrides are a warning that names that plugin, apart from what has
// no equivalent in Mirai; its exposure is still a View_Volume.
@(test)
the_bloom_of_a_post_process_volume_without_its_bridge_names_the_lens_plugin :: proc(t:^testing.T) {
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
    actor:=fixture.actor_add(&l,fixture.engine_class(&l.w,"PostProcessVolume"),"PostProcessVolume_0","Global")
    settings:=fixture.bytes_make()
    for name in ([?]string{"AutoExposureBias","BloomIntensity","VignetteIntensity","ColorContrast"}) {fixture.bool_property(&settings,&l.w,fmt.tprintf("bOverride_%s",name),true)}
    fixture.float_property(&settings,&l.w,"AutoExposureBias",-1)
    fixture.float_property(&settings,&l.w,"BloomIntensity",2)
    props:=fixture.bytes_make()
    fixture.bool_property(&props,&l.w,"bUnbound",true)
    fixture.struct_property(&props,&l.w,"Settings","PostProcessSettings",&settings)
    fixture.actor_set(&l,actor,fixture.component_add(&l,actor,fixture.engine_class(&l.w,"BrushComponent"),"BrushComponent0",fixture.bytes_make()),props)
    level:=fmt.tprintf("%s/assets/Unreal/Content/Maps/Cave.umap",root)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    report,error:=level_import(level,{root=root},{},"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer level_report_destroy(&report)
    named,unmatched:=false,false
    for w in report.imports.warnings {
        if strings.contains(w,"lens plugin") {named=strings.contains(w,"BloomIntensity") && strings.contains(w,"VignetteIntensity")}
        if strings.contains(w,"no equivalent") {unmatched=strings.contains(w,"ColorContrast") && !strings.contains(w,"Bloom") && !strings.contains(w,"Vignette")}
    }
    testing.expect(t,named,"bloom and vignette name the lens plugin")
    testing.expect(t,unmatched,"the contrast has no equivalent, bloom and vignette do")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    exposed:=false
    for row in 0..<asset.scene_entity_count(&scene) {
        e:=asset.scene_entity(&scene,row)
        if look,ok:=asset.scene_get(&scene,e.id,"View_Volume",render.View_Volume);ok {exposed=e.name=="Global" && look.exposure.compensation==-1}
    }
    testing.expect(t,exposed,"its exposure is a View_Volume")
}
