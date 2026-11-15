package unreal_fog_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
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
// the default of UE4. No light of the scene reaches it, with or without its
// volumetric fog, and it stops FogDensity in powers of two. Its second fog is
// another in the same box, from the actor raised by its offset; of two
// height fogs, the first alone, as Unreal draws.
@(test)
the_height_fog_of_an_unreal_level_fills_its_box_with_its_density_and_glow :: proc(t:^testing.T) {
    Case :: struct {volumetric:bool,inscattering:[4]f32,glow:[3]f32}
    cases:=[]Case{
        {volumetric=true,inscattering={0.171,0,1,1},glow={0.171,0,1}},
        {glow={0.447,0.638,1}},
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
            testing.expectf(t,volume.glow==test_case.glow && volume.color=={},"case %d: glow %v, color %v",n,volume.glow,volume.color)
            if e.name=="Mist" {
                found=true
                transform,_:=asset.scene_get(&scene,e.id,"Transform",core.Transform)
                testing.expectf(t,abs(transform.position.y-199.66)<1e-2,"case %d: the box is centred at %v",n,transform.position)
                expected:=f32(0.028094999492168427/10*math.LN2)
                testing.expectf(t,abs(volume.density-expected)<1e-6*expected,"case %d: density %v, not %v",n,volume.density,expected)
                testing.expectf(t,abs(volume.base-base)<1e-2,"case %d: base %v m over the bottom, not %v",n,volume.base,base)
                testing.expect(t,abs(volume.falloff-f32(0.02*math.LN2))<1e-6)
                continue
            }
            added=true
            testing.expectf(t,e.name=="Mist second fog","only the first height fog and its second: %s",e.name)
            testing.expect(t,volume.zone.mode==.Add,"the second fog adds to the first")
            expected:=f32(0.2/10*math.LN2)
            testing.expectf(t,abs(volume.density-expected)<1e-6*expected,"case %d: second density %v, not %v",n,volume.density,expected)
            testing.expectf(t,abs(volume.base-(base+3))<1e-2,"case %d: second base %v",n,volume.base)
            testing.expect(t,abs(volume.falloff-f32(0.01*math.LN2))<1e-6)
        }
        testing.expectf(t,found,"case %d: the fog is an entity with the label of its actor",n)
        testing.expectf(t,added,"case %d: its second fog is another",n)
    }
}

// The crystal cave of Fab under its SkyAtmosphere: Unreal adds to the glow of
// its height fog the light of the sky of the atmosphere far away, lit by its
// warm sun of 25 lux 38° over the horizon, which takes the violet of its
// inscattering color toward beige; with no atmosphere the glow is that color
// alone. The fog takes no light of the scene, also under an atmosphere.
// Unreal's lobe around the sun is a warning.
@(test)
under_a_sky_atmosphere_the_height_fog_glows_with_the_light_of_its_sky :: proc(t:^testing.T) {
    Case :: struct {atmosphere,volumetric:bool,sky:[3]f32}
    cases:=[]Case{
        {atmosphere=true,volumetric=true,sky={0.413,0.350,0.184}},
        {atmosphere=true,volumetric=false,sky={0.413,0.350,0.184}},
        {volumetric=true},
    }
    inscattering:=[3]f32{0.171429,0,1}
    directory,_:=os.temp_directory(context.temp_allocator)
    for test_case,n in cases {
        top:=fmt.tprintf("%s/mirai-fog-sky-%d-%d",directory,os.get_pid(),n)
        os.remove_all(top)
        defer os.remove_all(top)
        root:=fmt.tprintf("%s/project",top)
        os.make_directory_all(root)
        m:=project.manifest_default("Levels")
        project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
        os.make_directory_all(fmt.tprintf("%s/assets/Unreal/Content/Maps",root))
        l:=fixture.level_begin("/Game/Maps/Cave")
        for corner,i in ([2][3]f64{{-5000,-5000,-1000},{5000,5000,3000}}) {
            marker:=fixture.actor_add(&l,fixture.engine_class(&l.w,"Actor"),fmt.tprintf("Actor_%d",i),fmt.tprintf("Corner %d",i))
            placed:=fixture.bytes_make()
            fixture.vector_property(&placed,&l.w,"RelativeLocation",corner)
            fixture.actor_set(&l,marker,fixture.component_add(&l,marker,fixture.engine_class(&l.w,"SceneComponent"),"DefaultSceneRoot",placed))
        }
        sun:=fixture.actor_add(&l,fixture.engine_class(&l.w,"DirectionalLight"),"DirectionalLight_0","Sun")
        lit:=fixture.bytes_make()
        fixture.bool_property(&lit,&l.w,"bUsedAsAtmosphereSunLight",true)
        fixture.float_property(&lit,&l.w,"Temperature",2877.143)
        fixture.bool_property(&lit,&l.w,"bUseTemperature",true)
        fixture.float_property(&lit,&l.w,"Intensity",25)
        fixture.rotator_property(&lit,&l.w,"RelativeRotation",{-38.3139,608.7966,-25.9657})
        fixture.actor_set(&l,sun,fixture.component_add(&l,sun,fixture.engine_class(&l.w,"DirectionalLightComponent"),"LightComponent0",lit))
        if test_case.atmosphere {
            air:=fixture.actor_add(&l,fixture.engine_class(&l.w,"SkyAtmosphere"),"SkyAtmosphere_0","SkyAtmosphere")
            props:=fixture.bytes_make()
            fixture.linear_color_property(&props,&l.w,"RayleighScattering",{0.175287,0.409607,1,30.211479})
            fixture.actor_set(&l,air,fixture.component_add(&l,air,fixture.engine_class(&l.w,"SkyAtmosphereComponent"),"SkyAtmosphereComponent0",props))
        }
        actor:=fixture.actor_add(&l,fixture.engine_class(&l.w,"ExponentialHeightFog"),"ExponentialHeightFog_0","Mist")
        props:=fixture.bytes_make()
        fixture.vector_property(&props,&l.w,"RelativeLocation",{-420,-269.994140625,1352})
        fixture.float_property(&props,&l.w,"FogDensity",0.028094999492168427)
        fixture.linear_color_property(&props,&l.w,"FogInscatteringColor",{inscattering.r,inscattering.g,inscattering.b,1})
        fixture.linear_color_property(&props,&l.w,"DirectionalInscatteringColor",{0.117158,0.107912,0.25,1})
        if test_case.volumetric {fixture.bool_property(&props,&l.w,"bEnableVolumetricFog",true)}
        fixture.actor_set(&l,actor,fixture.component_add(&l,actor,fixture.engine_class(&l.w,"ExponentialHeightFogComponent"),"HeightFogComponent0",props))
        level:=fmt.tprintf("%s/assets/Unreal/Content/Maps/Cave.umap",root)
        _=os.write_entire_file(level,fixture.level_bytes(&l))
        provider:=fog_unreal_default().provider
        report,error:=unreal_scene.level_import(level,{root=root},provider.translators[:provider.count],"-")
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        defer unreal_scene.level_report_destroy(&report)
        lobe:=false
        for w in report.imports.warnings {lobe||=strings.contains(w,"glow around its sun")}
        testing.expectf(t,lobe,"case %d: the glow around the sun is a warning",n)
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        scene:asset.Scene
        if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
        defer asset.scene_destroy(&scene)
        found:=false
        for row in 0..<asset.scene_entity_count(&scene) {
            e:=asset.scene_entity(&scene,row)
            volume,ok:=asset.scene_get(&scene,e.id,"Fog_Volume",fog.Fog_Volume)
            if !ok || e.name!="Mist" {continue}
            found=true
            sky:=volume.glow-inscattering
            for c in 0..<3 {testing.expectf(t,abs(sky[c]-test_case.sky[c])<=0.05*max(test_case.sky[c],0.01),"case %d: the sky adds %v to the glow, not %v",n,sky,test_case.sky)}
            testing.expectf(t,volume.color=={},"case %d: color %v",n,volume.color)
        }
        testing.expectf(t,found,"case %d: the fog is an entity",n)
    }
}
