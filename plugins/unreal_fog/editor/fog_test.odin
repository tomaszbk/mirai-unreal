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

// The ExponentialHeightFog of the crystal cave of Fab, a UE4 level whose sky
// reaches 838 m under the fog: a fog in the box of what the level shows, two
// actors at its corners, with Unreal's density at the height of the actor,
// its base, thinning over it by its falloff per metre in powers of e and
// holding under it; it glows with its inscattering color, the one it saved or
// the default of UE4. Its volumetric fog lights it with its albedo and stops
// half of FogDensity in powers of e; without it, no light of the scene
// reaches it and it stops FogDensity in powers of two. Its second fog is
// another in the same box, from the actor raised by its offset; of two
// height fogs, the first alone, as Unreal draws.
@(test)
the_height_fog_of_an_unreal_level_fills_its_box_with_its_density_and_glow :: proc(t:^testing.T) {
    Case :: struct {volumetric:bool,inscattering:[4]f32,glow,color:[3]f32,stops:f64}
    cases:=[]Case{
        {volumetric=true,inscattering={0.171,0,1,1},glow={0.171,0,1},color={1,1,1},stops=0.5},
        {glow={0.447,0.638,1},color={0,0,0},stops=math.LN2},
    }
    directory,_:=os.temp_directory(context.temp_allocator)
    for test_case,n in cases {
        top:=fmt.tprintf("%s/mirai-fog-unreal-%d-%d",directory,os.get_pid(),n)
        os.remove_all(top)
        defer os.remove_all(top)
        root:=fmt.tprintf("%s/project",top)
        os.make_directory_all(root)
        m:=project.manifest_default("Levels")
        project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
        os.make_directory_all(fmt.tprintf("%s/assets/Unreal/Content/Maps",root))
        _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Levels.uproject",root),"{}")
        l:=fixture.level_begin("/Game/Maps/Mist")
        // Unreal's x, y and z in centimetres are Mirai's -z, x and y in metres: the box is 2048 m a side, from y -824.34.
        for corner,i in ([2][3]f64{{-110562,-64038,-82434},{94238,140762,122366}}) {
            marker:=fixture.actor_add(&l,fixture.engine_class(&l.w,"Actor"),fmt.tprintf("Actor_%d",i),fmt.tprintf("Corner %d",i))
            placed:=fixture.bytes_make()
            fixture.vector_property(&placed,&l.w,"RelativeLocation",corner)
            fixture.actor_set(&l,marker,fixture.component_add(&l,marker,fixture.engine_class(&l.w,"SceneComponent"),"DefaultSceneRoot",placed))
        }
        actor:=fixture.actor_add(&l,fixture.engine_class(&l.w,"ExponentialHeightFog"),"ExponentialHeightFog_0","Mist")
        props:=fixture.bytes_make()
        fixture.vector_property(&props,&l.w,"RelativeLocation",{-420,-269.994140625,1352})
        fixture.float_property(&props,&l.w,"FogDensity",0.028094999492168427)
        if test_case.inscattering!={} {fixture.linear_color_property(&props,&l.w,"FogInscatteringColor",test_case.inscattering)}
        if test_case.volumetric {fixture.bool_property(&props,&l.w,"bEnableVolumetricFog",true)}
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
        base:=f32(13.52+824.34)
        found,added:=false,false
        for row in 0..<asset.scene_entity_count(&scene) {
            e:=asset.scene_entity(&scene,row)
            volume,ok:=asset.scene_get(&scene,e.id,"Fog_Volume",fog.Fog_Volume)
            if !ok {continue}
            place,bounded:=asset.scene_get(&scene,e.id,"Volume",evolume.Volume)
            testing.expectf(t,bounded && place.shape==.Box && abs(place.extents.x-1024)<1e-2 && abs(place.extents.y-1024)<1e-2 && abs(place.extents.z-1024)<1e-2,"case %d: the box of the level: %v",n,place)
            testing.expectf(t,volume.glow==test_case.glow && volume.color==test_case.color,"case %d: glow %v, color %v",n,volume.glow,volume.color)
            if e.name=="Mist" {
                found=true
                transform,_:=asset.scene_get(&scene,e.id,"Transform",core.Transform)
                testing.expectf(t,abs(transform.position.y-199.66)<1e-2,"case %d: the box is centred at %v",n,transform.position)
                // About 0.0014 per metre with the volumetric fog.
                expected:=f32(0.028094999492168427/10*test_case.stops)
                testing.expectf(t,abs(volume.density-expected)<1e-6*expected,"case %d: density %v, not %v",n,volume.density,expected)
                testing.expectf(t,abs(volume.base-base)<1e-2,"case %d: base %v m over the bottom, not %v",n,volume.base,base)
                testing.expect(t,abs(volume.falloff-f32(0.02*math.LN2))<1e-6)
                continue
            }
            added=true
            testing.expectf(t,e.name=="Mist second fog","only the first height fog and its second: %s",e.name)
            testing.expect(t,volume.zone.mode==.Add,"the second fog adds to the first")
            expected:=f32(0.2/10*test_case.stops)
            testing.expectf(t,abs(volume.density-expected)<1e-6*expected,"case %d: second density %v, not %v",n,volume.density,expected)
            testing.expectf(t,abs(volume.base-(base+3))<1e-2,"case %d: second base %v",n,volume.base)
            testing.expect(t,abs(volume.falloff-f32(0.01*math.LN2))<1e-6)
        }
        testing.expectf(t,found,"case %d: the fog is an entity with the label of its actor",n)
        testing.expectf(t,added,"case %d: its second fog is another",n)
    }
}
