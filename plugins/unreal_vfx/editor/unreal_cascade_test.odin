package unreal_vfx_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import fixture "project:plugins/unreal/editor/fixture/files"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:project"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

// A Cascade system of a level, its distributions as the tables the package
// bakes, placed by an Emitter: the modules give what Unreal evaluates (bursts
// at their seconds, a color over life that replaces the start color times the
// scales, sizes that multiply, the speed a sphere gives by distance, the cone
// of its integer angles) and a module Mirai has no field for, or the lights of
// its particles, is a warning that names it.
@(test)
a_cascade_system_gives_its_effect_what_unreal_evaluates :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-cascade-%d",directory,os.get_pid())
    os.remove_all(top)
    defer os.remove_all(top)
    root:=fmt.tprintf("%s/project",top)
    os.make_directory_all(fmt.tprintf("%s/assets/Unreal/Content/Maps",root))
    os.make_directory_all(fmt.tprintf("%s/assets/Unreal/Content/FX",root))
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Levels.uproject",root),"{}")
    _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Content/FX/P_Torch.uasset",root),cascade_fixture())
    l:=fixture.level_begin("/Game/Maps/Cave")
    system:=fixture.package_object(&l.w,"/Game/FX/P_Torch","/Script/Engine","ParticleSystem","P_Torch")
    actor:=fixture.actor_add(&l,fixture.engine_class(&l.w,"Emitter"),"Emitter_0","Torch")
    props:=fixture.bytes_make()
    fixture.object_property(&props,&l.w,"Template",system)
    fixture.actor_set(&l,actor,fixture.component_add(&l,actor,fixture.engine_class(&l.w,"ParticleSystemComponent"),"ParticleSystemComponent0",props))
    map_path:=fmt.tprintf("%s/assets/Unreal/Content/Maps/Cave.umap",root)
    _=os.write_entire_file(map_path,fixture.level_bytes(&l))
    provider:=vfx_unreal_default().provider
    report,error:=unreal_scene.level_import(map_path,{root=root},provider.translators[:provider.count],"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer unreal_scene.level_report_destroy(&report)
    written:importer.Written
    for a in report.imports.assets {if a.kind==effect.PARTICLE_KIND {written=a}}
    if !testing.expectf(t,written.id!={},"the system is an effect: %v",report.imports.warnings) {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&a,written.path),asset.Error.None) {return}
    defer asset.asset_close(&a)
    desc,view_error:=effect.particle_view(&a,&types)
    if !testing.expect_value(t,view_error,asset.Error.None) {return}
    info:=desc.info
    near :: proc(a,b:f32) -> bool {return abs(a-b)<=1e-4*max(abs(b),1)}
    testing.expectf(t,near(info.rate,20) && info.duration==2,"rate times its scale, the cycle: %v %v",info.rate,info.duration)
    testing.expectf(t,info.bursts[0]=={time=0.5,count=5,cycles=1},"a burst at its seconds, the middle of its counts times its scale, up: %v",info.bursts[0])
    testing.expectf(t,info.lifetime=={1,3},"a random lifetime between both of its table: %v",info.lifetime)
    testing.expectf(t,near(info.size[0],0.2) && near(info.size[1],0.2),"%v",info.size)
    // ColorOverLife (2,1,0.5) to (4,2,1) with alpha 1 to 0, times ColorScaleOverLife 0.5: its peak, 2, is the intensity.
    testing.expectf(t,near(info.intensity,2) && info.colors[0]=={1,1,1,1},"%v %v",info.intensity,info.colors)
    g:=info.color_over_life
    testing.expectf(t,g.times[0]==0 && g.times[1]==1 && g.colors[0]=={0.5,0.25,0.125,1} && g.colors[1]=={1,0.5,0.25,0},"%v",g)
    // SizeMultiplyLife from 1 to 3 times SizeScale 2.
    s:=info.size_over_life
    testing.expectf(t,s.times[0]==0 && s.times[1]==1 && near(s.values[0],2) && near(s.values[1],6),"%v",s)
    // A surface of 50 cm that sends its particles off at twice their distance from the center.
    testing.expectf(t,info.shape==.Sphere && near(info.shape_size.x,0.5) && info.shell==1 && near(info.speed[0],1) && near(info.speed[1],1),"%v %v %v %v",info.shape,info.shape_size,info.shell,info.speed)
    // Four sub-images from the first to the last over the life.
    testing.expectf(t,info.flipbook=={2,2} && info.flipbook_speed==0,"%v %v",info.flipbook,info.flipbook_speed)
    warned :: proc(report:^unreal_scene.Level_Report,parts:..string) -> bool {
        next: for w in report.imports.warnings {
            for part in parts {if !strings.contains(w,part) {continue next}}
            return true
        }
        return false
    }
    testing.expectf(t,warned(&report,"Torch, Flame","nothing for ParticleModuleKillBox"),"a module without a field is named: %v",report.imports.warnings)
    testing.expectf(t,warned(&report,"Torch, Flame","ParticleModuleLight","is not a light"),"the lights of its particles are named: %v",report.imports.warnings)
    testing.expectf(t,!warned(&report,"ParticleModuleSubUV"),"%v",report.imports.warnings)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    placed:=false
    for row in 0..<asset.scene_entity_count(&scene) {
        e:=asset.scene_entity(&scene,row)
        if shown,found:=asset.scene_get(&scene,e.id,"Particle_Emitter",vfx.Particle_Emitter);found && e.name=="Torch" {placed=shown.particle==written.id && shown.active}
    }
    testing.expect(t,placed,"the Emitter is an entity that shows the effect")
    // A cone of Angle 0.25 is a quarter turn of integer units read as degrees.
    testing.expect(t,abs(math.trunc(0.25*math.RAD_PER_DEG*CASCADE_ROTATOR_UNITS)-45)<1e-6)
}

// The package of a Cascade system: one emitter whose modules keep the
// tables their distributions bake.
@(private="file")
cascade_fixture :: proc() -> []u8 {
    w:=fixture.writer_make({package_name="/Game/FX/P_Torch"})
    end :: proc(w:^fixture.Writer,class,outer:i32,name:string,props:^fixture.Bytes) -> i32 {
        fixture.none(props,w)
        fixture.put_u32(props,0)
        return fixture.export_add(w,{class=class,outer=outer,name=name,data=props.data[:]})
    }
    // A table: Op 1 keeps a value an entry, 2 the least and the most.
    table :: proc(w:^fixture.Writer,b:^fixture.Bytes,property,raw:string,op,count,stride:int,values:[]f32) {
        t:=fixture.bytes_make()
        fixture.float_property(&t,w,"TimeScale",f32(max(count-1,0)))
        fixture.tag(&t,w,"Values","ArrayProperty",4+4*len(values),{inner="FloatProperty"})
        fixture.put_u32(&t,u32(len(values)))
        for v in values {fixture.put_f32(&t,v)}
        for field in ([4]struct{name:string,value:int}{{"Op",op},{"EntryCount",count},{"EntryStride",stride},{"SubEntryStride",op==1?0:stride/2}}) {
            if field.value==0 {continue}
            fixture.tag(&t,w,field.name,"ByteProperty",1)
            fixture.put_u8(&t,u8(field.value))
        }
        distribution:=fixture.bytes_make()
        fixture.struct_property(&distribution,w,"Table","DistributionLookupTable",&t)
        fixture.struct_property(b,w,property,raw,&distribution)
    }
    float :: proc(w:^fixture.Writer,b:^fixture.Bytes,property:string,values:..f32) {
        table(w,b,property,"RawDistributionFloat",1,len(values),1,values)
    }
    vector :: proc(w:^fixture.Writer,b:^fixture.Bytes,property:string,values:..f32) {
        table(w,b,property,"RawDistributionVector",1,len(values)/3,3,values)
    }
    system_class:=fixture.engine_class(&w,"ParticleSystem")
    system:=fixture.export_add(&w,{class=system_class,name="P_Torch"})
    emitter:=fixture.export_add(&w,{class=fixture.engine_class(&w,"ParticleSpriteEmitter"),outer=system,name="ParticleSpriteEmitter_0"})
    lod:=fixture.export_add(&w,{class=fixture.engine_class(&w,"ParticleLODLevel"),outer=emitter,name="ParticleLODLevel_0"})
    required:=fixture.bytes_make()
    fixture.float_property(&required,&w,"EmitterDuration",2)
    fixture.int_property(&required,&w,"SubImages_Horizontal",2)
    fixture.int_property(&required,&w,"SubImages_Vertical",2)
    fixture.enum_property(&required,&w,"InterpolationMethod","EParticleSubUVInterpMethod","PSUVIM_Linear")
    required_ref:=end(&w,fixture.engine_class(&w,"ParticleModuleRequired"),system,"ParticleModuleRequired_0",&required)
    spawn:=fixture.bytes_make()
    float(&w,&spawn,"Rate",10)
    float(&w,&spawn,"RateScale",2)
    float(&w,&spawn,"BurstScale",1.5)
    burst:=fixture.bytes_make()
    fixture.int_property(&burst,&w,"Count",4)
    fixture.int_property(&burst,&w,"CountLow",2)
    fixture.float_property(&burst,&w,"Time",0.5)
    fixture.struct_array_property(&spawn,&w,"BurstList","ParticleBurst",{burst})
    spawn_ref:=end(&w,fixture.engine_class(&w,"ParticleModuleSpawn"),system,"ParticleModuleSpawn_0",&spawn)
    modules:=make([dynamic]i32,context.temp_allocator)
    module :: proc(w:^fixture.Writer,modules:^[dynamic]i32,system:i32,class:string,props:^fixture.Bytes) {
        append(modules,end(w,fixture.engine_class(w,class),system,fmt.tprintf("%s_0",class),props))
    }
    lifetime:=fixture.bytes_make()
    table(&w,&lifetime,"Lifetime","RawDistributionFloat",2,1,2,{1,3})
    module(&w,&modules,system,"ParticleModuleLifetime",&lifetime)
    size:=fixture.bytes_make()
    vector(&w,&size,"StartSize",20,20,20)
    module(&w,&modules,system,"ParticleModuleSize",&size)
    scale:=fixture.bytes_make()
    vector(&w,&scale,"ColorScaleOverLife",0.5,0.5,0.5)
    float(&w,&scale,"AlphaScaleOverLife",1)
    module(&w,&modules,system,"ParticleModuleColorScaleOverLife",&scale)
    over:=fixture.bytes_make()
    vector(&w,&over,"ColorOverLife",2,1,0.5,4,2,1)
    float(&w,&over,"AlphaOverLife",1,0)
    module(&w,&modules,system,"ParticleModuleColorOverLife",&over)
    module(&w,&modules,system,"ParticleModuleColorScaleOverLife",&scale)
    multiply:=fixture.bytes_make()
    vector(&w,&multiply,"LifeMultiplier",1,1,1,3,3,3)
    module(&w,&modules,system,"ParticleModuleSizeMultiplyLife",&multiply)
    size_scale:=fixture.bytes_make()
    vector(&w,&size_scale,"SizeScale",2,2,2)
    module(&w,&modules,system,"ParticleModuleSizeScale",&size_scale)
    sphere:=fixture.bytes_make()
    float(&w,&sphere,"StartRadius",50)
    fixture.bool_property(&sphere,&w,"SurfaceOnly",true)
    fixture.bool_property(&sphere,&w,"Velocity",true)
    float(&w,&sphere,"VelocityScale",2)
    module(&w,&modules,system,"ParticleModuleLocationPrimitiveSphere",&sphere)
    light:=fixture.bytes_make()
    float(&w,&light,"BrightnessOverLife",2000)
    vector(&w,&light,"ColorScaleOverLife",1,1,1)
    float(&w,&light,"RadiusScale",3)
    fixture.float_property(&light,&w,"SpawnFraction",0.5)
    module(&w,&modules,system,"ParticleModuleLight",&light)
    sub_uv:=fixture.bytes_make()
    float(&w,&sub_uv,"SubImageIndex",0,3)
    module(&w,&modules,system,"ParticleModuleSubUV",&sub_uv)
    kill:=fixture.bytes_make()
    module(&w,&modules,system,"ParticleModuleKillBox",&kill)
    level_props:=fixture.bytes_make()
    fixture.object_property(&level_props,&w,"RequiredModule",required_ref)
    fixture.object_property(&level_props,&w,"SpawnModule",spawn_ref)
    fixture.objects_property(&level_props,&w,"Modules",modules[:])
    fixture.none(&level_props,&w);fixture.put_u32(&level_props,0)
    w.exports[lod-1].data=level_props.data[:]
    emitter_props:=fixture.bytes_make()
    fixture.name_property(&emitter_props,&w,"EmitterName","Flame")
    fixture.objects_property(&emitter_props,&w,"LODLevels",{lod})
    fixture.none(&emitter_props,&w);fixture.put_u32(&emitter_props,0)
    w.exports[emitter-1].data=emitter_props.data[:]
    system_props:=fixture.bytes_make()
    fixture.objects_property(&system_props,&w,"Emitters",{emitter})
    fixture.none(&system_props,&w);fixture.put_u32(&system_props,0)
    w.exports[system-1].data=system_props.data[:]
    return fixture.package_bytes(&w)
}
