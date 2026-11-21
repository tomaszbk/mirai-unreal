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
import render "mirai:engine/render"
import fog "plugins:fog/runtime"

// The ExponentialHeightFog of the crystal cave of Fab, a UE4 level whose sky
// reaches 838 m under the fog: a fog in the box of what the level shows, two
// actors at its corners, with Unreal's density at the height of the actor,
// its base, thinning over it by its falloff per metre in powers of e and
// holding under it. Without volumetric fog it glows with its inscattering
// color (the one it saved or the default of UE4), and without a sun nothing
// of the scene lights it. With `bEnableVolumetricFog` enabled it takes the
// volumetric albedo, scattering distribution, emissive and extinction scale
// (`volumetric_rate`). Its second fog is another in the same box, from the
// actor raised by its offset; of two height fogs, the first alone, as Unreal
// draws.
@(test)
the_height_fog_of_an_unreal_level_fills_its_box_with_its_density_and_glow :: proc(t:^testing.T) {
    Case :: struct {
        volumetric:bool,
        inscattering:[4]f32,
        albedo:[3]f32,
        emissive:[3]f32,
        distribution:f32,
        extinction_scale:f32,
        glow:[3]f32,
        color:[3]f32,
        anisotropy:f32,
    }
    cases:=[]Case{
        {
            volumetric=true,
            inscattering={0.171,0,1,1},
            albedo={1,1,1},
            emissive={0,0,0},
            distribution=0.2,
            extinction_scale=1.5,
            glow={0,0,0},
            color={1,1,1},
            anisotropy=0.2,
        },
        {
            volumetric=true,
            inscattering={0.171,0,1,1},
            albedo={0.8,0.6,0.4},
            emissive={0.1,0.05,0},
            distribution=0.5,
            extinction_scale=1,
            glow=volumetric_glow({0.1,0.05,0},volumetric_rate(0.028094999492168427,1)),
            color={0.8,0.6,0.4},
            anisotropy=0.5,
        },
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
        if test_case.volumetric {
            fixture.bool_property(&props,&l.w,"bEnableVolumetricFog",true)
            fixture.linear_color_property(&props,&l.w,"VolumetricFogAlbedo",{test_case.albedo.r,test_case.albedo.g,test_case.albedo.b,1})
            fixture.linear_color_property(&props,&l.w,"VolumetricFogEmissive",{test_case.emissive.r,test_case.emissive.g,test_case.emissive.b,1})
            fixture.float_property(&props,&l.w,"VolumetricFogScatteringDistribution",test_case.distribution)
            fixture.float_property(&props,&l.w,"VolumetricFogExtinctionScale",test_case.extinction_scale)
        }
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
        imports:=fixture.store_open(root)
        defer fixture.store_close(imports)
        report,error:=unreal_scene.level_import(level,fixture.into(root,imports),provider.translators[:provider.count],"-")
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
            expected_glow:=([3]f32{}) if (test_case.volumetric && e.name!="Mist") else test_case.glow
            testing.expectf(t,volume.glow==expected_glow && volume.color==test_case.color && abs(volume.anisotropy-test_case.anisotropy)<1e-6,"case %d (%s): glow %v (expected %v), color %v, anisotropy %v",n,e.name,volume.glow,expected_glow,volume.color,volume.anisotropy)
            if e.name=="Mist" {
                found=true
                transform,_:=asset.scene_get(&scene,e.id,"Transform",core.Transform)
                testing.expectf(t,abs(transform.position.y-199.66)<1e-2,"case %d: the box is centred at %v",n,transform.position)
                expected:=f32(volumetric_rate(0.028094999492168427,f64(test_case.extinction_scale)) if test_case.volumetric else 0.028094999492168427/10*math.LN2)
                testing.expectf(t,abs(volume.density-expected)<1e-6*expected,"case %d: density %v, not %v",n,volume.density,expected)
                testing.expectf(t,abs(volume.base-base)<1e-2,"case %d: base %v m over the bottom, not %v",n,volume.base,base)
                testing.expect(t,abs(volume.falloff-f32(0.02*math.LN2))<1e-6)
                continue
            }
            added=true
            testing.expectf(t,e.name=="Mist second fog","only the first height fog and its second: %s",e.name)
            testing.expect(t,volume.zone.mode==.Add,"the second fog adds to the first")
            expected:=f32(volumetric_rate(0.2,f64(test_case.extinction_scale)) if test_case.volumetric else 0.2/10*math.LN2)
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
// alone. Its lobe around the sun is the sun its fog scatters (lobe_scatter):
// without an atmosphere, its directional color times the luminance of the
// sun; under one, more, the sun through the air; with a black directional
// color and no atmosphere, none.
@(test)
under_a_sky_atmosphere_the_height_fog_glows_with_the_light_of_its_sky :: proc(t:^testing.T) {
    Case :: struct {atmosphere,volumetric:bool,sky:[3]f32,directional:[3]f32}
    lobe_color:=[3]f32{0.117158,0.107912,0.25}
    cases:=[]Case{
        {atmosphere=true,volumetric=true,sky={0.413,0.350,0.184},directional=lobe_color},
        {atmosphere=true,volumetric=false,sky={0.413,0.350,0.184},directional=lobe_color},
        {volumetric=true,directional=lobe_color},
        {},
    }
    exponent:=f32(12)
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
        d:=test_case.directional
        fixture.linear_color_property(&props,&l.w,"DirectionalInscatteringColor",{d.r,d.g,d.b,1})
        fixture.float_property(&props,&l.w,"DirectionalInscatteringExponent",exponent)
        if test_case.volumetric {fixture.bool_property(&props,&l.w,"bEnableVolumetricFog",true)}
        fixture.actor_set(&l,actor,fixture.component_add(&l,actor,fixture.engine_class(&l.w,"ExponentialHeightFogComponent"),"HeightFogComponent0",props))
        level:=fmt.tprintf("%s/assets/Unreal/Content/Maps/Cave.umap",root)
        _=os.write_entire_file(level,fixture.level_bytes(&l))
        provider:=fog_unreal_default().provider
        imports:=fixture.store_open(root)
        defer fixture.store_close(imports)
        report,error:=unreal_scene.level_import(level,fixture.into(root,imports),provider.translators[:provider.count],"-")
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        defer unreal_scene.level_report_destroy(&report)
        lobe,taken:=false,!test_case.volumetric
        for w in report.imports.warnings {
            lobe||=strings.contains(w,"glow around its sun") && strings.contains(w,"with shadows")
            taken||=strings.contains(w,"Unreal limits volumetric fog") && strings.contains(w,"albedo")
        }
        has_lobe:=!test_case.volumetric && test_case.directional!={}
        testing.expectf(t,lobe==has_lobe,"case %d: what remains of the glow around the sun is a warning",n)
        testing.expectf(t,taken,"case %d: the warning of its volumetric fog says what was taken",n)
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        scene:asset.Scene
        if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
        defer asset.scene_destroy(&scene)
        written:render.Sun
        imported:=false
        for row in 0..<asset.scene_entity_count(&scene) {
            if written,imported=asset.scene_get(&scene,asset.scene_entity(&scene,row).id,"Sun",render.Sun);imported {break}
        }
        if !testing.expectf(t,imported,"case %d: the sun is imported",n) {continue}
        light:=written.color*written.illuminance
        found:=false
        for row in 0..<asset.scene_entity_count(&scene) {
            e:=asset.scene_entity(&scene,row)
            volume,ok:=asset.scene_get(&scene,e.id,"Fog_Volume",fog.Fog_Volume)
            if !ok || e.name!="Mist" {continue}
            found=true
            if test_case.volumetric {
                testing.expectf(t,volume.color=={1,1,1} && abs(volume.anisotropy-0.2)<1e-6 && volume.glow=={},"case %d: volumetric fog uses albedo/anisotropy/emissive: %v %v %v",n,volume.color,volume.anisotropy,volume.glow)
                continue
            }
            sky:=volume.glow-inscattering
            for c in 0..<3 {testing.expectf(t,abs(sky[c]-test_case.sky[c])<=0.05*max(test_case.sky[c],0.01),"case %d: the sky adds %v to the glow, not %v",n,sky,test_case.sky)}
            if !has_lobe {
                testing.expectf(t,volume.color=={} && volume.anisotropy==0,"case %d: no lobe, no scattering: %v %v",n,volume.color,volume.anisotropy)
                continue
            }
            _,g,_:=lobe_scatter({1,1,1},light,f64(written.scattering),f64(exponent))
            testing.expectf(t,abs(volume.anisotropy-g)<1e-5,"case %d: anisotropy %v, not %v",n,volume.anisotropy,g)
            if test_case.atmosphere {
                // The sun through the air adds to the lobe.
                for c in 0..<3 {testing.expectf(t,volume.color[c]>0,"case %d: color %v",n,volume.color)}
                continue
            }
            // Unreal's lobe: its directional color times the luminance Unreal weighs the light of the sun by.
            luminance:=0.3*light.r+0.59*light.g+0.11*light.b
            expected,_,_:=lobe_scatter(test_case.directional*luminance,light,f64(written.scattering),f64(exponent))
            for c in 0..<3 {testing.expectf(t,expected[c]>0 && abs(volume.color[c]-expected[c])<1e-5,"case %d: color %v, not %v",n,volume.color,expected)}
        }
        testing.expectf(t,found,"case %d: the fog is an entity",n)
    }
}

// Unreal's lobe around the sun as the sun Mirai's fog scatters: the phase
// gathers its light toward the sun as the power of the cosine does, thick
// fog seen toward the sun shows the lobe's luminance and scatters as much in
// all as the lobe adds, each channel held in [0, 1]; no color where the sun
// gives the fog no light.
@(test)
the_lobe_around_the_sun_is_the_sun_the_fog_scatters :: proc(t:^testing.T) {
    Case :: struct {lobe,light:[3]f32,scattering,exponent:f64,held:bool}
    cases:=[]Case{
        {lobe={2.9,2.7,6.2},light={45.8,20.7,5.9},scattering=2,exponent=4},
        {lobe={0.5,0.5,0.5},light={10,10,10},scattering=1,exponent=1},
        {lobe={40,1,1},light={1,10,10},scattering=1,exponent=16,held=true},
        {lobe={1,1,1},light={10,10,10},scattering=0,exponent=4},
    }
    for c,n in cases {
        color,g,held:=lobe_scatter(c.lobe,c.light,c.scattering,c.exponent)
        testing.expectf(t,held==c.held,"case %d: held %v",n,held)
        phase :: proc(g,cosine:f64) -> f64 {return (1-g*g)/(4*math.PI*math.pow(1+g*g-2*g*cosine,1.5))}
        // The lobe over all it adds peaks at (n+1)/(2π); the phase, of a whole of 1, peaks as high.
        gathered:=(c.exponent+1)/(2*math.PI)
        testing.expectf(t,g>0 && abs(phase(f64(g),1)-gathered)<1e-4*gathered,"case %d: anisotropy %v gathers its light toward the sun otherwise than the lobe",n,g)
        for i in 0..<3 {
            given:=f64(c.light[i])*c.scattering*phase(f64(g),1)*f64(color[i])
            switch {
            case c.scattering==0:testing.expectf(t,color[i]==0,"case %d: no light, no color: %v",n,color)
            case color[i]==1:testing.expectf(t,c.held && given<=f64(c.lobe[i]),"case %d: channel %d held at 1",n,i)
            case:
                testing.expectf(t,abs(given-f64(c.lobe[i]))<1e-4*f64(c.lobe[i]),"case %d: channel %d gives %v nits, not %v",n,i,given,c.lobe[i])
                // As much light in all as the lobe adds, c.lobe[i]·2π/(n+1).
                whole:=f64(c.light[i])*c.scattering*f64(color[i])
                testing.expectf(t,abs(whole-f64(c.lobe[i])/gathered)<1e-4*whole,"case %d: channel %d scatters %v in all",n,i,whole)
            }
        }
    }
}
