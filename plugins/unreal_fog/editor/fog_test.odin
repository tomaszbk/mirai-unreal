package unreal_fog_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import fixture "project:plugins/unreal/editor/fixture/files"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:project"
import evolume "mirai:engine/volume"
import fog "plugins:fog/runtime"

// An ExponentialHeightFog of a level: a fog that fills the world from where
// the actor stands, its density and falloff per metre in powers of e, which
// scatters what the albedo of its volumetric fog says; its second fog,
// another added to it from where the actor stands raised by its offset; of
// two, the first alone, as Unreal draws.
@(test)
the_height_fog_of_an_unreal_level_is_a_fog_of_the_whole_world :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-fog-unreal-%d",directory,os.get_pid())
    os.remove_all(top)
    defer os.remove_all(top)
    root:=fmt.tprintf("%s/project",top)
    os.make_directory_all(root)
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    os.make_directory_all(fmt.tprintf("%s/assets/Unreal/Content/Maps",root))
    _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Levels.uproject",root),"{}")
    l:=fixture.level_begin("/Game/Maps/Mist")
    actor:=fixture.actor_add(&l,fixture.engine_class(&l.w,"ExponentialHeightFog"),"ExponentialHeightFog_0","Mist")
    props:=fixture.bytes_make()
    fixture.vector_property(&props,&l.w,"RelativeLocation",{0,0,-200})
    fixture.float_property(&props,&l.w,"FogDensity",0.05)
    fixture.float_property(&props,&l.w,"FogHeightFalloff",0.5)
    second:=fixture.bytes_make()
    fixture.float_property(&second,&l.w,"FogDensity",0.2)
    fixture.float_property(&second,&l.w,"FogHeightFalloff",0.1)
    fixture.float_property(&second,&l.w,"FogHeightOffset",300)
    fixture.struct_property(&props,&l.w,"SecondFogData","ExponentialHeightFogData",&second)
    component:=fixture.component_add(&l,actor,fixture.engine_class(&l.w,"ExponentialHeightFogComponent"),"HeightFogComponent0",props)
    fixture.actor_set(&l,actor,component)
    // Unreal draws the first height fog of a scene alone.
    copy:=fixture.actor_add(&l,fixture.engine_class(&l.w,"ExponentialHeightFog"),"ExponentialHeightFog_1","Mist copy")
    copied:=fixture.bytes_make()
    fixture.float_property(&copied,&l.w,"FogDensity",0.5)
    fixture.actor_set(&l,copy,fixture.component_add(&l,copy,fixture.engine_class(&l.w,"ExponentialHeightFogComponent"),"HeightFogComponent0",copied))
    level:=fmt.tprintf("%s/assets/Unreal/Content/Maps/Mist.umap",root)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    provider:=fog_unreal_default().provider
    report,error:=unreal_scene.level_import(level,{root=root},provider.translators[:provider.count],"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer unreal_scene.level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    found,added:=false,false
    for row in 0..<asset.scene_entity_count(&scene) {
        e:=asset.scene_entity(&scene,row)
        volume,ok:=asset.scene_get(&scene,e.id,"Fog_Volume",fog.Fog_Volume)
        if !ok {continue}
        place,bounded:=asset.scene_get(&scene,e.id,"Volume",evolume.Volume)
        testing.expect_value(t,volume.color,[3]f32{1,1,1})
        if e.name=="Mist" {
            found=true
            testing.expect(t,!bounded,"it fills the world: no Volume")
            testing.expect(t,abs(volume.density-f32(0.005*math.LN2))<1e-6,"0.05 per thousand centimetres, base two")
            testing.expect(t,abs(volume.falloff-f32(0.05*math.LN2))<1e-6)
            continue
        }
        added=true
        testing.expectf(t,e.name=="Mist second fog","only the first height fog and its second: %s",e.name)
        testing.expect(t,bounded && place.shape==.Unbounded && volume.zone.mode==.Add,"the second fog fills the world over the first")
        testing.expect(t,abs(volume.density-f32(0.02*math.LN2))<1e-6)
        testing.expect(t,abs(volume.falloff-f32(0.01*math.LN2))<1e-6)
        transform,_:=asset.scene_get(&scene,e.id,"Transform",core.Transform)
        testing.expect_value(t,transform.position,[3]f32{0,3,0})
    }
    testing.expect(t,found,"the fog is an entity with the label of its actor")
    testing.expect(t,added,"its second fog is another")
}
