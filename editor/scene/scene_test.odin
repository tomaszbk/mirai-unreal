package unreal_scene

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import fixture "project:plugins/unreal/editor/fixture/files"
import fx "project:plugins/unreal/editor/material/fixture"
import "project:plugins/unreal/editor/level"
import uasset "project:plugins/unreal/editor/model"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(private="file")
close3 :: proc(a,b:[3]f32,tolerance:f32=1e-4) -> bool {return linalg.length(a-b)<=tolerance}

@(private="file")
close :: proc(a,b:f32,tolerance:f32=1e-3) -> bool {return abs(a-b)<=tolerance*max(1,abs(b))}

// A quad of a StaticMesh in one slot whose material is M_Wood.
@(private="file")
quad_package :: proc() -> []u8 {
    up:=[3]f32{0,0,1}
    f:fixture.Mesh_Fixture
    f.layout=.Raw_Mesh
    f.positions=slice.clone([][3]f32{{0,0,0},{100,0,0},{100,100,0},{0,100,0}},context.temp_allocator)
    f.corners=slice.clone([]u32{0,2,1, 0,3,2},context.temp_allocator)
    f.normals=slice.clone([][3]f32{up,up,up,up,up,up},context.temp_allocator)
    f.uvs=slice.clone([][2]f32{{0,1},{1,0},{1,1},{0,1},{0,0},{1,0}},context.temp_allocator)
    f.groups=slice.clone([]u32{0,0},context.temp_allocator)
    f.smoothing=slice.clone([]u32{1,1},context.temp_allocator)
    f.slots=slice.clone([]fixture.Mesh_Slot{{name="Wood",imported_name="Wood",material="/Game/Materials/M_Wood"}},context.temp_allocator)
    return fixture.static_mesh_package(f)
}

// M_Red: a red base color.
@(private="file")
red_package :: proc() -> []u8 {
    p:=fx.package_make()
    red:=fx.export(&p,fx.class(&p,"/Script/Engine","Material"),0,"M_Red",nil)
    constant:=fx.writer(&p)
    fx.color_put(&constant,"Constant",{1,0,0,1})
    value:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionConstant3Vector"),red,"Red",fx.finish(&constant))
    w:=fx.writer(&p)
    fx.input_put(&w,"BaseColor","ColorMaterialInput",{expression=value,mask={true,true,true,false}})
    p.exports[0].data=fx.finish(&w)
    return fx.package_bytes(&p,"/Game/Materials/M_Red")
}

// A map with a rock (a StaticMeshActor whose root shows the quad with M_Red
// over its slot and whose second mesh is hidden in game), a spot light of
// 1000 lumens, a cine camera, an ExponentialHeightFog (a plugin's), a
// sound and two lamps of a Blueprint, a base with a shade over it, the
// second's shade hidden.
@(private="file")
map_package :: proc() -> []u8 {
    l:=fixture.level_begin("/Game/Maps/Map")
    w:=&l.w
    mesh:=fixture.package_object(w,"/Game/Meshes/SM_Fixture","/Script/Engine","StaticMesh","SM_Fixture")
    red:=fixture.package_object(w,"/Game/Materials/M_Red","/Script/Engine","Material","M_Red")
    mesh_class:=fixture.engine_class(w,"StaticMeshComponent")

    rock:=fixture.actor_add(&l,fixture.engine_class(w,"StaticMeshActor"),"StaticMeshActor_3","Rock")
    root_props:=fixture.bytes_make()
    fixture.object_property(&root_props,w,"StaticMesh",mesh)
    fixture.objects_property(&root_props,w,"OverrideMaterials",{red})
    fixture.vector_property(&root_props,w,"RelativeLocation",{100,200,300})
    fixture.rotator_property(&root_props,w,"RelativeRotation",{0,90,0})
    fixture.vector_property(&root_props,w,"RelativeScale3D",{2,2,2})
    root:=fixture.component_add(&l,rock,mesh_class,"StaticMeshComponent0",root_props)
    moss_props:=fixture.bytes_make()
    fixture.object_property(&moss_props,w,"StaticMesh",mesh)
    fixture.object_property(&moss_props,w,"AttachParent",root)
    fixture.vector_property(&moss_props,w,"RelativeLocation",{10,0,0})
    fixture.bool_property(&moss_props,w,"bHiddenInGame",true)
    fixture.component_add(&l,rock,mesh_class,"Moss",moss_props)
    fixture.actor_set(&l,rock,root)

    spot:=fixture.actor_add(&l,fixture.engine_class(w,"SpotLight"),"SpotLight_1","Spot")
    light_props:=fixture.bytes_make()
    fixture.vector_property(&light_props,w,"RelativeLocation",{0,0,400})
    fixture.float_property(&light_props,w,"Intensity",1000)
    fixture.enum_property(&light_props,w,"IntensityUnits","ELightUnits","ELightUnits::Lumens")
    fixture.float_property(&light_props,w,"OuterConeAngle",30)
    fixture.float_property(&light_props,w,"AttenuationRadius",2000)
    fixture.float_property(&light_props,w,"SourceRadius",5)
    fixture.color_property(&light_props,w,"LightColor",{255,128,0,255})
    light:=fixture.component_add(&l,spot,fixture.engine_class(w,"SpotLightComponent"),"LightComponent0",light_props)
    fixture.actor_set(&l,spot,light)

    camera:=fixture.actor_add(&l,fixture.script_class(w,"/Script/CinematicCamera","CineCameraActor"),"CineCameraActor_0","Shot")
    camera_props:=fixture.bytes_make()
    fixture.vector_property(&camera_props,w,"RelativeLocation",{-500,0,150})
    filmback:=fixture.bytes_make()
    fixture.float_property(&filmback,w,"SensorWidth",36)
    fixture.float_property(&filmback,w,"SensorHeight",24)
    fixture.struct_property(&camera_props,w,"Filmback","CameraFilmbackSettings",&filmback)
    fixture.float_property(&camera_props,w,"CurrentFocalLength",50)
    lens:=fixture.component_add(&l,camera,fixture.script_class(w,"/Script/CinematicCamera","CineCameraComponent"),"CameraComponent",camera_props)
    fixture.actor_set(&l,camera,lens)

    fog:=fixture.actor_add(&l,fixture.engine_class(w,"ExponentialHeightFog"),"ExponentialHeightFog_0","Fog")
    fog_props:=fixture.bytes_make()
    fixture.vector_property(&fog_props,w,"RelativeLocation",{0,0,-100})
    fixture.float_property(&fog_props,w,"FogDensity",0.05)
    fog_root:=fixture.component_add(&l,fog,fixture.engine_class(w,"ExponentialHeightFogComponent"),"HeightFogComponent0",fog_props)
    fixture.actor_set(&l,fog,fog_root)

    sound:=fixture.actor_add(&l,fixture.engine_class(w,"AmbientSound"),"AmbientSound_0","Birds")
    audio:=fixture.component_add(&l,sound,fixture.engine_class(w,"AudioComponent"),"AudioComponent0",{})
    fixture.actor_set(&l,sound,audio)

    lamp_class:=fixture.package_object(w,"/Game/Blueprints/BP_Lamp","/Script/Engine","BlueprintGeneratedClass","BP_Lamp_C")
    for label,i in ([2]string{"Lamp","Lamp2"}) {
        lamp:=fixture.actor_add(&l,lamp_class,fmt.tprintf("BP_Lamp_C_%d",i),label)
        base_props:=fixture.bytes_make()
        fixture.object_property(&base_props,w,"StaticMesh",mesh)
        fixture.vector_property(&base_props,w,"RelativeLocation",{f64(300*i),-300,0})
        lamp_base:=fixture.component_add(&l,lamp,mesh_class,"Base",base_props)
        shade_props:=fixture.bytes_make()
        fixture.object_property(&shade_props,w,"StaticMesh",mesh)
        fixture.object_property(&shade_props,w,"AttachParent",lamp_base)
        fixture.vector_property(&shade_props,w,"RelativeLocation",{0,0,150})
        if i==1 {fixture.bool_property(&shade_props,w,"bHiddenInGame",true)}
        fixture.component_add(&l,lamp,mesh_class,"Shade",shade_props)
        fixture.actor_set(&l,lamp,lamp_base)
    }
    return fixture.level_bytes(&l)
}

// The class of the lamps: no components of its own, which its actors hold.
@(private="file")
blueprint_package :: proc() -> []u8 {
    w:=fixture.writer_make({package_name="/Game/Blueprints/BP_Lamp"})
    empty:=fixture.bytes_make()
    fixture.none(&empty,&w)
    fixture.put_u32(&empty,0)
    class:=fixture.export_add(&w,{class=fixture.engine_class(&w,"BlueprintGeneratedClass"),name="BP_Lamp_C",data=empty.data[:]})
    fixture.export_add(&w,{class=class,name="Default__BP_Lamp_C",data=empty.data[:]})
    return fixture.package_bytes(&w)
}

// A project of Mirai and, apart, the Unreal project of the map.
@(private="file")
Fixture_Folders :: struct {mirai,unreal,map_path:string}

@(private="file")
folders_make :: proc(name:string) -> (f:Fixture_Folders) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-unreal-scene-%d-%s",directory,os.get_pid(),name)
    os.remove_all(top)
    f.mirai=fmt.tprintf("%s/project",top)
    f.unreal=fmt.tprintf("%s/assets/Unreal",f.mirai)
    os.make_directory_all(f.mirai)
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(f.mirai,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    for folder in ([?]string{"Meshes","Materials","Maps","Blueprints"}) {os.make_directory_all(fmt.tprintf("%s/Content/%s",f.unreal,folder))}
    _=os.write_entire_file(fmt.tprintf("%s/Levels.uproject",f.unreal),"{}")
    _=os.write_entire_file(fmt.tprintf("%s/Content/Meshes/SM_Fixture.uasset",f.unreal),quad_package())
    _=os.write_entire_file(fmt.tprintf("%s/Content/Materials/M_Red.uasset",f.unreal),red_package())
    _=os.write_entire_file(fmt.tprintf("%s/Content/Blueprints/BP_Lamp.uasset",f.unreal),blueprint_package())
    f.map_path=fmt.tprintf("%s/Content/Maps/Map.umap",f.unreal)
    _=os.write_entire_file(f.map_path,map_package())
    return
}

@(private="file")
folders_remove :: proc(f:Fixture_Folders) {os.remove_all(f.mirai[:len(f.mirai)-len("/project")])}

@(private="file")
entity_named :: proc(scene:^asset.Scene,name:string) -> (id:base.Entity_Id,parent:base.Entity_Id,found:bool) {
    for row in 0..<asset.scene_entity_count(scene) {
        e:=asset.scene_entity(scene,row)
        if e.name==name {return e.id,e.parent,true}
    }
    return
}

@(private="file")
has_warning :: proc(report:^Level_Report,parts:..string) -> bool {
    next: for w in report.imports.warnings {
        for part in parts {if !strings.contains(w,part) {continue next}}
        return true
    }
    return false
}

@(test)
a_map_becomes_a_scene_of_entities_meshes_lights_and_cameras_in_the_units_of_mirai :: proc(t:^testing.T) {
    f:=folders_make("scene")
    defer folders_remove(f)
    report,error:=level_import(f.map_path,{root=f.mirai},engine_content="-")
    if !testing.expectf(t,error.code==.None,"%v: %s",error.code,error.message) {return}
    defer level_report_destroy(&report)
    testing.expect(t,strings.has_suffix(report.scene_path,"/Maps/Map/Map.scene"),report.scene_path)
    testing.expect_value(t,report.meshes,1)

    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    testing.expect_value(t,scene.doc.id,report.scene)

    // The rock: the actor at its root's place, its root's mesh under it with no offset.
    rock,rock_parent,found:=entity_named(&scene,"Rock")
    if !testing.expect(t,found && rock_parent==0,"the actor is an entity with its label") {return}
    rock_t,_:=asset.scene_get(&scene,rock,"Transform",core.Transform)
    testing.expect(t,close3(rock_t.position,{2,3,-1}),"centimetres to metres in Mirai's axes")
    testing.expect_value(t,rock_t.scale,[3]f32{2,2,2})
    shown,shown_parent,shown_found:=entity_named(&scene,"StaticMeshComponent0")
    testing.expect(t,shown_found && shown_parent==rock)
    local,_:=asset.scene_get(&scene,shown,"Transform",core.Transform)
    testing.expect(t,close3(local.position,{}) && local.scale==[3]f32{1,1,1},"the root's mesh sits on its actor")
    renderer,has_renderer:=asset.scene_get(&scene,shown,"Mesh_Renderer",render.Mesh_Renderer)
    testing.expect(t,has_renderer && renderer.mesh!={})
    red_id:base.Asset_Id
    for a in report.imports.assets {if a.kind==asset.KIND_MATERIAL && a.name=="Red/Red" {red_id=a.id}}
    testing.expect(t,red_id!={} && renderer.materials[0]==red_id,"OverrideMaterials[0] is the material of slot 1, the first")
    moss,moss_parent,_:=entity_named(&scene,"Moss")
    testing.expect_value(t,moss_parent,rock)
    moss_local,_:=asset.scene_get(&scene,moss,"Transform",core.Transform)
    testing.expect(t,close3(moss_local.position,{0,0,-0.1}),"10 cm forward of its parent, in the frame of its actor")

    _,moss_hidden:=asset.scene_get(&scene,moss,"Hidden",render.Hidden)
    testing.expect(t,moss_hidden,"bHiddenInGame hides")

    // The spot: 1000 lm over its cone of 30°, pointing down as SpotLight's
    // constructor turns it. Its light is all it shows: the entity of its actor.
    spot,spot_parent,_:=entity_named(&scene,"Spot")
    testing.expect_value(t,spot_parent,0)
    _,_,grouped:=entity_named(&scene,"LightComponent0")
    testing.expect(t,!grouped,"an actor that shows one component is one entity")
    light,has_light:=asset.scene_get(&scene,spot,"Spot_Light",render.Spot_Light)
    if testing.expect(t,has_light) {
        expected:=f32(1000/(2*math.PI*(1-math.cos(f64(30)*math.RAD_PER_DEG))))
        testing.expectf(t,close(light.intensity,expected),"%v cd, expected %v",light.intensity,expected)
        testing.expect(t,close(light.range,20) && close(light.radius,0.05) && close(light.angle,30*math.RAD_PER_DEG))
        testing.expect(t,close3(light.color,{1,mm.srgb_to_linear(f32(128)/255),0}),"the color of the light, linear")
    }
    light_t,_:=asset.scene_get(&scene,spot,"Transform",core.Transform)
    testing.expect(t,close3(mm.quat_rotate(light_t.rotation,{0,0,-1}),{0,-1,0}),"it shines down along -Z of its entity")
    testing.expect(t,close3(light_t.position,{0,4,0}),"where its component is")

    // The camera: its entity has the label of the actor and the field of view of its sensor.
    shot,_,shot_found:=entity_named(&scene,"Shot")
    if testing.expect(t,shot_found) {
        cameras:=0
        for row in 0..<asset.scene_entity_count(&scene) {
            if c,ok:=asset.scene_get(&scene,asset.scene_entity(&scene,row).id,"Camera",render.Camera);ok {
                cameras+=1
                testing.expect(t,close(c.fov,f32(2*math.atan(24.0/100))),"vertical field of view of 24 mm under a 50 mm lens")
                testing.expect_value(t,asset.scene_entity(&scene,row).name,"Shot")
            }
        }
        testing.expect_value(t,cameras,1)
    }
    // The lamps: instances of the prefab of their Blueprint, the second with
    // its shade hidden on its own.
    lamp,_,lamp_found:=entity_named(&scene,"Lamp")
    lamp2,_,lamp2_found:=entity_named(&scene,"Lamp2")
    first_lamp,first_found:=asset.scene_instance(&scene,lamp)
    second_lamp,second_found:=asset.scene_instance(&scene,lamp2)
    if testing.expect(t,lamp_found && lamp2_found && first_found && second_found && len(asset.scene_instance_roots(&scene))==2,"each lamp is an instance") {
        prefab_id:=first_lamp.prefab
        testing.expect(t,prefab_id!={} && second_lamp.prefab==prefab_id,"of one prefab")
        members,_:=asset.scene_instance_members(&scene,lamp)
        of_first :: proc(members:[]asset.Placed,e:base.Entity_Id) -> bool {
            for m in members {if m.entity==e {return true}}
            return false
        }
        hidden_hash:=base.name_hash("Hidden")
        overrides:=[2]int{}
        for &o in scene.overrides {
            testing.expectf(t,o.component!=base.name_hash("Transform") || o.entity!=lamp && o.entity!=lamp2,"the placement of a root is its own, not an override")
            in_first:=o.entity==lamp || of_first(members,o.entity)
            overrides[in_first?0:1]+=1
            name:=base.text_get(o.path[:])
            testing.expect(t,o.component==0 && name=="name" && (o.entity==lamp || o.entity==lamp2) || o.component==hidden_hash && o.kind==.Added && !in_first,"each root keeps its label, the second shade its Hidden")
        }
        // The first lamp is labeled as its prefab is named: only the second renames its root.
        testing.expect_value(t,overrides,[2]int{0,2})
        prefab_path:=""
        for a in report.imports.assets {if a.id==prefab_id {prefab_path=a.path}}
        testing.expect(t,strings.has_suffix(prefab_path,"/Maps/Map/Lamp.scene"),prefab_path)
        prefab:asset.Scene
        if testing.expect_value(t,asset.scene_load(&prefab,&types,prefab_path),asset.Error.None) {
            defer asset.scene_destroy(&prefab)
            testing.expect_value(t,asset.scene_entity_count(&prefab),3)
            root,_:=asset.prefab_root(&prefab)
            row,_:=asset.scene_entity_find(&prefab,root)
            testing.expect_value(t,asset.scene_entity(&prefab,row).name,"Lamp")
            placed,_:=asset.scene_get(&prefab,root,"Transform",core.Transform)
            testing.expect(t,close3(placed.position,{}),"the root of the prefab at the origin")
        }
    }

    _,has_sky:=sky_of(report.scene_path,&types)
    testing.expect(t,!has_sky,"no sky light: no Sky, so no light from the sky and black behind the scene, as Unreal draws it")

    testing.expect(t,has_warning(&report,"ExponentialHeightFog","editor session"),"a plugin's actor says how to import it")
    testing.expect(t,has_warning(&report,"AmbientSound","sounds"),"a sound is a warning by class")
    classes:=0
    for c in report.classes {if c.class=="/Script/Engine.StaticMeshActor" {classes+=1;testing.expect(t,c.actors==1 && c.translated==1)}}
    testing.expect_value(t,classes,1)
    testing.expect_value(t,len(report.lights),1)
    testing.expect_value(t,len(report.cameras),1)

    // Importing again writes the same file with the same ids.
    again,again_error:=level_import(f.map_path,{root=f.mirai},engine_content="-")
    if !testing.expectf(t,again_error.code==.None,"%s",again_error.message) {return}
    defer level_report_destroy(&again)
    testing.expect_value(t,again.scene,report.scene)
    testing.expect_value(t,again.scene_path,report.scene_path)
    second:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&second,&types,again.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&second)
    again_rock,_,_:=entity_named(&second,"Rock")
    testing.expect_value(t,again_rock,rock)
    again_shown,_,_:=entity_named(&second,"StaticMeshComponent0")
    again_renderer,_:=asset.scene_get(&second,again_shown,"Mesh_Renderer",render.Mesh_Renderer)
    testing.expect_value(t,again_renderer.mesh,renderer.mesh)
    testing.expect_value(t,again_renderer.materials[0],renderer.materials[0])
}

@(private="file")
sky_of :: proc(path:string,types:^asset.Types) -> (sky:render.Sky,found:bool) {
    a:asset.Asset
    if asset.asset_load(&a,path,context.temp_allocator)!=.None {return}
    defer asset.asset_close(&a)
    view,error:=asset.scene_view(&a,types)
    if error!=.None {return}
    index,known:=asset.types_index(types,render.Sky)
    if !known {return}
    for &component in view.components {
        if component.name!="Sky" || len(component.entities)==0 {continue}
        values:=make([]render.Sky,len(component.entities),context.temp_allocator)
        found=asset.scene_component_read(&a,&component,&types.schema,index,mem.slice_to_bytes(values))==.None
        if found {sky=values[0]}
    }
    return
}

// A translator of a plugin: the fog actor becomes an entity of its own with
// a component the plugin knows.
@(private="file")
fog_translate :: proc(c:^Context,actors:[]int) -> int {
    for a in actors {
        e,ok:=actor_entity(c,a)
        if !ok {return 0}
        density,_:=level.real_of(c.d,c.d.components[c.d.actors[a].root].ref,"FogDensity",0.02)
        marker:=render.Material_Values{color={f32(density),0,0,1}}
        if !component_set(c,e,"Material_Values",&marker) {return 0}
        id,path,info:=asset_place(c,asset.KIND_TEXTURE,c.d.actors[a].label,0,".tex")
        _=info
        if !asset_write(c,id,asset.KIND_TEXTURE,c.d.actors[a].label,path,{1,2,3}) {return 0}
    }
    return len(actors)
}

@(test)
a_translator_of_a_plugin_takes_the_actors_of_its_class_and_places_its_assets :: proc(t:^testing.T) {
    f:=folders_make("translator")
    defer folders_remove(f)
    translators:=[]Translator{{classes={0="ExponentialHeightFog"},translate=fog_translate}}
    report,error:=level_import(f.map_path,{root=f.mirai},translators,"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer level_report_destroy(&report)
    testing.expect(t,!has_warning(&report,"ExponentialHeightFog"),"its actors are not warnings")
    placed:importer.Written
    for a in report.imports.assets {if a.name=="Fog" {placed=a}}
    testing.expect(t,placed.id!={} && placed.kind==asset.KIND_TEXTURE,"the fog writes its texture as a part of the map")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    fog,_,found:=entity_named(&scene,"Fog")
    marker,marked:=asset.scene_get(&scene,fog,"Material_Values",render.Material_Values)
    testing.expect(t,found && marked && close(marker.color.r,0.05))
}

// A component hook of a plugin: what it adds to the entity of each mesh
// component, with the collision of the mesh read once.
@(private="file")
mesh_mark :: proc(c:^Context,a,k:int,e:base.Entity_Id) {
    body,ok:=mesh_body(c,level.path_of(c.d,c.d.components[k].ref,"StaticMesh"))
    if !ok {return}
    marker:=render.Material_Values{color={f32(len(body.shapes)),f32(body.trace),1,1}}
    component_set(c,e,"Material_Values",&marker)
    if shown,found:=asset.scene_get(c.scene,e,"Mesh_Renderer",render.Mesh_Renderer);found && shown.mesh==body.mesh {
        marker.color.b=0
        component_set(c,e,"Material_Values",&marker)
    }
}

@(test)
a_component_hook_of_a_plugin_adds_to_the_entity_of_each_mesh :: proc(t:^testing.T) {
    f:=folders_make("component")
    defer folders_remove(f)
    translators:=[]Translator{{classes={0="StaticMeshComponent"},component=mesh_mark}}
    report,error:=level_import(f.map_path,{root=f.mirai},translators,"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    shown,_,found:=entity_named(&scene,"StaticMeshComponent0")
    marker,marked:=asset.scene_get(&scene,shown,"Material_Values",render.Material_Values)
    // The mesh of the fixture keeps no BodySetup: no simple shapes, the default trace, and the mesh it shows.
    testing.expect(t,found && marked && marker.color==render.Material_Values{color={0,0,0,1}}.color)
}

@(test)
lights_convert_each_unit_of_unreal_to_mirai :: proc(t:^testing.T) {
    point:=Unreal_Light{kind=.Point,intensity=100,units=.Candelas,color={1,1,1},attenuation_radius=1000,source_radius=10,inverse_squared=true,temperature=6500}
    m,_:=light_convert(point)
    testing.expect(t,close(m.value,100) && close(m.range,10) && close(m.radius,0.1),"candelas as they are")
    point.units=.Lumens
    m,_=light_convert(point)
    testing.expect(t,close(m.value,100/(4*math.PI)),"lumens of a point over the sphere")
    point.units=.Unitless
    point.intensity=5000
    m,_=light_convert(point)
    testing.expect(t,close(m.value,8),"unitless times 16 over 100²")
    point.units=.EV
    point.intensity=3
    m,_=light_convert(point)
    testing.expect(t,close(m.value,8),"EV100 as 2^EV")
    point.units=.Nits
    point.intensity=1000
    m,_=light_convert(point)
    testing.expect(t,close(m.value,1000*4*math.PI*0.01),"nits over the area of the sphere")
    rect:=Unreal_Light{kind=.Rect,intensity=200,units=.Candelas,color={1,1,1},source_width=200,source_height=50,attenuation_radius=500}
    m,_=light_convert(rect)
    testing.expect(t,close(m.value,200) && m.size==[2]f32{2,0.5},"a rectangle's candelas over its area of 1 m²")
    rect.units=.Nits
    m,_=light_convert(rect)
    testing.expect(t,close(m.value,200),"nits as they are")
    warm:=point
    warm.units=.Candelas
    warm.intensity=10
    warm.use_temperature=true
    warm.temperature=2000
    m,_=light_convert(warm)
    testing.expect(t,max(m.color.r,m.color.g,m.color.b)<=1 && m.color.r>m.color.b,"a warm light, no channel above one")
    testing.expect(t,m.value>10,"what was above one went to the intensity")
    white:=mm.blackbody_linear(6500)
    testing.expect(t,abs(white.r-1)<0.05 && abs(white.g-1)<0.05 && abs(white.b-1)<0.05,"6500 K is about white")
    flat:=point
    flat.units=.Candelas
    flat.inverse_squared=false
    _,approximated:=light_convert(flat)
    testing.expect(t,.Falloff in approximated)
}

// A map with a Character (a capsule at its root, a SkeletalMeshComponent
// under it with M_Red over its slot 1 and an Animation Blueprint, a spring
// arm and a camera) and a SkeletalMeshActor whose component names its mesh
// as SkinnedAsset, as UE 5.1 saves it, and plays MM_Fixture once at 1.5.
// Both show the figure of the fixture package.
@(private="file")
character_map :: proc() -> []u8 {
    l:=fixture.level_begin("/Game/Maps/Characters")
    w:=&l.w
    figure:=fixture.package_object(w,"/Game/Characters/SK_Fixture","/Script/Engine","SkeletalMesh","SK_Fixture")
    red:=fixture.package_object(w,"/Game/Materials/M_Red","/Script/Engine","Material","M_Red")
    skeletal:=fixture.engine_class(w,"SkeletalMeshComponent")

    hero:=fixture.actor_add(&l,fixture.engine_class(w,"Character"),"Character_0","Hero")
    capsule_props:=fixture.bytes_make()
    fixture.vector_property(&capsule_props,w,"RelativeLocation",{0,0,90})
    capsule:=fixture.component_add(&l,hero,fixture.engine_class(w,"CapsuleComponent"),"CollisionCylinder",capsule_props)
    mesh_props:=fixture.bytes_make()
    fixture.object_property(&mesh_props,w,"SkeletalMesh",figure)
    fixture.objects_property(&mesh_props,w,"OverrideMaterials",{red})
    fixture.object_property(&mesh_props,w,"AttachParent",capsule)
    fixture.vector_property(&mesh_props,w,"RelativeLocation",{0,0,-90})
    fixture.rotator_property(&mesh_props,w,"RelativeRotation",{0,-90,0})
    fixture.object_property(&mesh_props,w,"AnimClass",fixture.package_object(w,"/Game/Characters/ABP_Hero","/Script/Engine","AnimBlueprintGeneratedClass","ABP_Hero_C"))
    fixture.component_add(&l,hero,skeletal,"CharacterMesh0",mesh_props)
    arm_props:=fixture.bytes_make()
    fixture.object_property(&arm_props,w,"AttachParent",capsule)
    arm:=fixture.component_add(&l,hero,fixture.script_class(w,"/Script/Engine","SpringArmComponent"),"CameraBoom",arm_props)
    camera_props:=fixture.bytes_make()
    fixture.object_property(&camera_props,w,"AttachParent",arm)
    fixture.vector_property(&camera_props,w,"RelativeLocation",{-300,0,0})
    fixture.component_add(&l,hero,fixture.engine_class(w,"CameraComponent"),"FollowCamera",camera_props)
    fixture.actor_set(&l,hero,capsule)

    statue:=fixture.actor_add(&l,fixture.engine_class(w,"SkeletalMeshActor"),"SkeletalMeshActor_0","Statue")
    statue_props:=fixture.bytes_make()
    fixture.object_property(&statue_props,w,"SkinnedAsset",figure)
    fixture.vector_property(&statue_props,w,"RelativeLocation",{500,0,0})
    fixture.enum_property(&statue_props,w,"AnimationMode","EAnimationMode::Type","EAnimationMode::AnimationSingleNode")
    play:=fixture.bytes_make()
    fixture.object_property(&play,w,"AnimToPlay",fixture.package_object(w,"/Game/Animations/MM_Fixture","/Script/Engine","AnimSequence","MM_Fixture"))
    fixture.bool_property(&play,w,"bSavedLooping",false)
    fixture.float_property(&play,w,"SavedPlayRate",1.5)
    fixture.float_property(&play,w,"SavedPosition",0.05)
    fixture.struct_property(&statue_props,w,"AnimationData","SingleAnimationPlayData",&play)
    statue_root:=fixture.component_add(&l,statue,skeletal,"SkeletalMeshComponent0",statue_props)
    fixture.actor_set(&l,statue,statue_root)
    return fixture.level_bytes(&l)
}

@(test)
a_skeletal_mesh_of_a_level_is_the_skinned_mesh_of_its_import_with_its_overrides :: proc(t:^testing.T) {
    f:=folders_make("characters")
    defer folders_remove(f)
    os.make_directory_all(fmt.tprintf("%s/Content/Characters",f.unreal))
    _=os.write_entire_file(fmt.tprintf("%s/Content/Characters/SK_Fixture.uasset",f.unreal),fixture.skeletal_mesh_package(fixture.skeletal_figure(.UE5)))
    figure:=fixture.skeletal_figure(.UE5)
    _=os.write_entire_file(fmt.tprintf("%s/Content/Characters/SK_Fixture_Skeleton.uasset",f.unreal),fixture.skeleton_package(.UE5,"/Game/Characters/SK_Fixture_Skeleton",figure.bones))
    os.make_directory_all(fmt.tprintf("%s/Content/Animations",f.unreal))
    _=os.write_entire_file(fmt.tprintf("%s/Content/Animations/MM_Fixture.uasset",f.unreal),fixture.animation_package(fixture.animation_figure(.Data_Model)))
    level:=fmt.tprintf("%s/Content/Maps/Characters.umap",f.unreal)
    _=os.write_entire_file(level,character_map())
    report,error:=level_import(level,{root=f.mirai},engine_content="-")
    if !testing.expectf(t,error.code==.None,"%v: %s",error.code,error.message) {return}
    defer level_report_destroy(&report)
    testing.expect_value(t,report.meshes,1)
    mesh_id,skeleton_id,red_id:base.Asset_Id
    for a in report.imports.assets {
        switch {
        case a.kind==asset.KIND_MESH && a.name=="Fixture/Fixture":mesh_id=a.id
        case a.kind==asset.KIND_SKELETON:skeleton_id=a.id
        case a.kind==asset.KIND_MATERIAL && a.name=="Red/Red":red_id=a.id
        }
    }
    testing.expect(t,mesh_id!={} && skeleton_id!={} && red_id!={},"the mesh, its skeleton and the override are imported")

    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    hero,_,hero_found:=entity_named(&scene,"Hero")
    shown,shown_parent,found:=entity_named(&scene,"CharacterMesh0")
    if !testing.expect(t,hero_found && found && shown_parent==hero,"the mesh of the character is an entity of its actor") {return}
    renderer,has_renderer:=asset.scene_get(&scene,shown,"Mesh_Renderer",render.Mesh_Renderer)
    testing.expect(t,has_renderer && renderer.mesh==mesh_id,"it draws the skinned mesh")
    // Slot 1 (OverrideMaterials[0]) is the second row of the mesh: its first is the quad's, of material 1.
    testing.expect_value(t,renderer.materials[1],red_id)
    testing.expect_value(t,renderer.materials[0],base.Asset_Id{})
    local,_:=asset.scene_get(&scene,shown,"Transform",core.Transform)
    testing.expect(t,close3(local.position,{0,-0.9,0}),"90 cm under the capsule, where its actor is")
    cameras:=0
    for row in 0..<asset.scene_entity_count(&scene) {
        if _,ok:=asset.scene_get(&scene,asset.scene_entity(&scene,row).id,"Camera",render.Camera);ok {cameras+=1}
    }
    testing.expect_value(t,cameras,1)
    testing.expect(t,has_warning(&report,"CapsuleComponent"),"the capsule is a component left out")
    statue,_,statue_found:=entity_named(&scene,"Statue")
    statue_renderer,statue_shown:=asset.scene_get(&scene,statue,"Mesh_Renderer",render.Mesh_Renderer)
    testing.expect(t,statue_found && statue_shown && statue_renderer.mesh==mesh_id,"SkinnedAsset names the mesh too")
    // The single node plays the clip of its sequence once, at its rate; the blueprint is a warning.
    clip_id:base.Asset_Id
    for a in report.imports.assets {if a.kind==asset.KIND_ANIMATION {clip_id=a.id}}
    animation,animated:=asset.scene_get(&scene,statue,"Animation",Animation)
    if testing.expect(t,animated && clip_id!={},"the statue plays the imported clip") {
        testing.expect_value(t,animation.asset,clip_id)
        testing.expect_value(t,animation.speed,f32(1.5))
        testing.expect(t,!animation.loop && animation.playing)
        testing.expect_value(t,animation.root_motion,Root_Motion_Policy.None)
        progress,started:=asset.scene_get(&scene,statue,"Animation_Progress",Animation_Progress)
        testing.expect(t,started && abs(progress.time-0.05)<1e-6,"it starts where Unreal saved it")
    }
    _,hero_animated:=asset.scene_get(&scene,shown,"Animation",Animation)
    testing.expect(t,!hero_animated,"the hero is driven by its blueprint")
    testing.expect(t,has_warning(&report,"CharacterMesh0","Animation Blueprint","ABP_Hero"))
    for c in report.classes {
        if c.class=="/Script/Engine.SkeletalMeshActor" || c.class=="/Script/Engine.Character" {testing.expectf(t,c.translated==1,"%s",c.class)}
    }
}

// Reading the packages ahead in jobs and building in them writes what one
// thread writes, byte for byte.
@(test)
a_map_imported_on_a_job_system_writes_the_bytes_one_thread_writes :: proc(t:^testing.T) {
    f:=folders_make("jobs")
    defer folders_remove(f)
    first,error:=level_import(f.map_path,{root=f.mirai},engine_content="-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    level_report_destroy(&first)
    written:=make(map[string]string,context.temp_allocator)
    walker:=os.walker_create(f.mirai)
    for info in os.walker_walk(&walker) {
        if info.type!=.Regular {continue}
        data,_:=os.read_entire_file(info.fullpath,context.temp_allocator)
        written[strings.clone(info.fullpath,context.temp_allocator)]=string(data)
    }
    os.walker_destroy(&walker)
    testing.expect(t,len(written)>3)

    js:jobs.Job_System
    if !testing.expect(t,jobs.system_init(&js,{threads=3,allocator=runtime.heap_allocator()})) {return}
    defer jobs.system_destroy(&js)
    again,again_error:=level_import(f.map_path,{root=f.mirai,rebuild=true,worker={system=&js}},engine_content="-")
    if !testing.expectf(t,again_error.code==.None,"%s",again_error.message) {return}
    level_report_destroy(&again)
    for path,bytes in written {
        now,_:=os.read_entire_file(path,context.temp_allocator)
        testing.expectf(t,string(now)==bytes,"%s is written again the same",path)
    }
}

// A map lit from the sky under an atmosphere whose air is thinner than the
// Earth's and of a smaller planet.
@(private="file")
atmosphere_map :: proc() -> []u8 {
    l:=fixture.level_begin("/Game/Maps/Map")
    w:=&l.w
    sky:=fixture.actor_add(&l,fixture.engine_class(w,"SkyLight"),"SkyLight_0","Sky light")
    light:=fixture.component_add(&l,sky,fixture.engine_class(w,"SkyLightComponent"),"SkyLightComponent0",fixture.bytes_make())
    fixture.actor_set(&l,sky,light)
    air:=fixture.actor_add(&l,fixture.engine_class(w,"SkyAtmosphere"),"SkyAtmosphere_0","Air")
    props:=fixture.bytes_make()
    fixture.float_property(&props,w,"BottomRadius",3000)
    fixture.float_property(&props,w,"AtmosphereHeight",80)
    fixture.float_property(&props,w,"RayleighScatteringScale",0.02)
    fixture.float_property(&props,w,"MieAnisotropy",0.6)
    root:=fixture.component_add(&l,air,fixture.engine_class(w,"SkyAtmosphereComponent"),"SkyAtmosphereComponent0",props)
    fixture.actor_set(&l,air,root)
    return fixture.level_bytes(&l)
}

@(test)
an_atmosphere_of_unreal_is_the_air_of_the_sky :: proc(t:^testing.T) {
    f:=folders_make("atmosphere")
    defer folders_remove(f)
    _=os.write_entire_file(f.map_path,atmosphere_map())
    report,error:=level_import(f.map_path,{root=f.mirai},engine_content="-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    sky,found:=sky_of(report.scene_path,&types)
    if !testing.expect(t,found,"a sky light makes the Sky") {return}
    testing.expect(t,sky.atmosphere,"which draws the air")
    testing.expect(t,close(sky.air.planet_radius,3000) && close(sky.air.thickness,80),"of the planet of the atmosphere")
    testing.expect(t,close(sky.air.rayleigh.z,0.02) && close(sky.air.rayleigh.x,0.175287*0.02),"its Rayleigh scattering is its color times its scale")
    testing.expect(t,close(sky.air.mie_anisotropy,0.6) && close(sky.air.mie.x,0.003996),"what it does not set is Unreal's default")
}

// A map lit from the sky by a cube of Unreal's, turned a quarter about its up,
// with an atmosphere when air.
@(private="file")
cubemap_map :: proc(air:=false) -> []u8 {
    l:=fixture.level_begin("/Game/Maps/Map")
    w:=&l.w
    cube:=fixture.package_object(w,"/Game/Textures/T_Sky","/Script/Engine","TextureCube","T_Sky")
    sky:=fixture.actor_add(&l,fixture.engine_class(w,"SkyLight"),"SkyLight_0","Sky light")
    props:=fixture.bytes_make()
    fixture.enum_property(&props,w,"SourceType","ESkyLightSourceType","ESkyLightSourceType::SLS_SpecifiedCubemap")
    fixture.object_property(&props,w,"Cubemap",cube)
    fixture.float_property(&props,w,"SourceCubemapAngle",90)
    light:=fixture.component_add(&l,sky,fixture.engine_class(w,"SkyLightComponent"),"SkyLightComponent0",props)
    fixture.actor_set(&l,sky,light)
    if air {
        atmosphere:=fixture.actor_add(&l,fixture.engine_class(w,"SkyAtmosphere"),"SkyAtmosphere_0","Air")
        fixture.actor_set(&l,atmosphere,fixture.component_add(&l,atmosphere,fixture.engine_class(w,"SkyAtmosphereComponent"),"SkyAtmosphereComponent0",fixture.bytes_make()))
    }
    return fixture.level_bytes(&l)
}

@(test)
a_sky_light_of_a_cubemap_lights_from_its_image_turned_as_unreal_turns_it :: proc(t:^testing.T) {
    f:=folders_make("cubemap")
    defer folders_remove(f)
    os.make_directory_all(fmt.tprintf("%s/Content/Textures",f.unreal))
    faces:=make([]u8,6*4*4*4,context.temp_allocator)
    for &v,i in faces {v=u8(i/64*40)}
    _=os.write_entire_file(fmt.tprintf("%s/Content/Textures/T_Sky.uasset",f.unreal),fx.texture_package("/Game/Textures/T_Sky","T_Sky",faces,4,4,texture_class="TextureCube",slices=6))
    // With an atmosphere too, the sky still lights from the cube Unreal's sky light names.
    for air in ([2]bool{false,true}) {
        _=os.write_entire_file(f.map_path,cubemap_map(air))
        report,error:=level_import(f.map_path,{root=f.mirai},engine_content="-")
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        defer level_report_destroy(&report)
        testing.expect(t,!has_warning(&report,"cubemap"),"the cubemap is translated")
        testing.expect_value(t,has_warning(&report,"atmosphere"),air)
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        scene:asset.Scene
        if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
        defer asset.scene_destroy(&scene)
        e,_,found:=entity_named(&scene,"Sky")
        sky,has_sky:=asset.scene_get(&scene,e,"Sky",render.Sky)
        if !testing.expect(t,found && has_sky && sky.image!={},"the Sky draws an image") {return}
        image:=""
        for a in report.imports.assets {if a.id==sky.image && a.kind==asset.KIND_TEXTURE {image=a.path}}
        file:asset.Asset
        if !testing.expect(t,image!="" && asset.asset_load(&file,image,context.temp_allocator)==.None,"the image is a .tex of the import") {return}
        defer asset.asset_close(&file)
        view,view_error:=asset.texture_view(&file,&types)
        testing.expect(t,view_error==.None && view.info.width==2*view.info.height && view.info.layers==1 && .Cube not_in view.info.flags,"a longitude-latitude image of the whole sky")
        // Looking along Unreal's +X, Unreal shows what its cube has at +Y once turned 90°: Mirai's +X.
        place,_:=asset.scene_get(&scene,e,"Transform",core.Transform)
        testing.expect(t,close3(mm.quat_rotate(mm.quat_inverse(place.rotation),{0,0,-1}),{1,0,0}),"the image turns with the entity of the sky")
        testing.expect(t,!sky.atmosphere,"the atmosphere does not replace the image")
    }
}

// A map that shows a cube and a sphere of Unreal's engine, the sphere with a
// material of the engine over its own.
@(private="file")
engine_shapes_map :: proc() -> []u8 {
    l:=fixture.level_begin("/Game/Maps/Shapes")
    w:=&l.w
    cube:=fixture.package_object(w,"/Engine/BasicShapes/Cube","/Script/Engine","StaticMesh","Cube")
    sphere:=fixture.package_object(w,"/Engine/BasicShapes/Sphere","/Script/Engine","StaticMesh","Sphere")
    paint:=fixture.package_object(w,"/Engine/EngineMaterials/M_Paint","/Script/Engine","Material","M_Paint")
    mesh_class:=fixture.engine_class(w,"StaticMeshComponent")
    actor_class:=fixture.engine_class(w,"StaticMeshActor")
    box:=fixture.actor_add(&l,actor_class,"StaticMeshActor_0","Box")
    box_props:=fixture.bytes_make()
    fixture.object_property(&box_props,w,"StaticMesh",cube)
    fixture.actor_set(&l,box,fixture.component_add(&l,box,mesh_class,"StaticMeshComponent0",box_props))
    ball:=fixture.actor_add(&l,actor_class,"StaticMeshActor_1","Ball")
    ball_props:=fixture.bytes_make()
    fixture.object_property(&ball_props,w,"StaticMesh",sphere)
    fixture.objects_property(&ball_props,w,"OverrideMaterials",{paint})
    fixture.actor_set(&l,ball,fixture.component_add(&l,ball,mesh_class,"StaticMeshComponent0",ball_props))
    return fixture.level_bytes(&l)
}

@(test)
the_basic_shapes_and_materials_of_an_unmounted_engine_are_primitives_with_the_grid :: proc(t:^testing.T) {
    f:=folders_make("engine")
    defer folders_remove(f)
    path:=fmt.tprintf("%s/Content/Maps/Shapes.umap",f.unreal)
    _=os.write_entire_file(path,engine_shapes_map())
    report,error:=level_import(path,{root=f.mirai},engine_content="-")
    if !testing.expectf(t,error.code==.None,"%v: %s",error.code,error.message) {return}
    defer level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    materials:=make(map[base.Asset_Id]string,context.temp_allocator)
    for a in report.imports.assets {if a.kind==asset.KIND_MATERIAL {materials[a.id]=a.path}}
    grid :: proc(t:^testing.T,types:^asset.Types,materials:map[base.Asset_Id]string,id:base.Asset_Id) -> bool {
        path,found:=materials[id]
        if !found {return false}
        file:asset.Asset
        if asset.asset_load(&file,path,context.temp_allocator)!=.None {return false}
        defer asset.asset_close(&file)
        view,view_error:=asset.material_view(&file,types)
        return view_error==.None && strings.truncate_to_byte(string(view.info.program[:]),0)==uasset.GRID_PROGRAM
    }
    for shape,i in ([2]render.Shape{.Cube,.Sphere}) {
        e,_,found:=entity_named(&scene,i==0?"Box":"Ball")
        if !testing.expectf(t,found,"the actor of the %v is an entity",shape) {continue}
        shown,_:=asset.scene_get(&scene,e,"Mesh_Renderer",render.Mesh_Renderer)
        testing.expectf(t,shown.mesh=={} && shown.shape==shape,"the %v of Unreal's engine is the primitive of Mirai: %v",shape,shown)
        testing.expectf(t,grid(t,&types,materials,shown.materials[0]),"the %v is drawn with the grid",shape)
    }
    testing.expect(t,has_warning(&report,"/Engine/BasicShapes/Cube.Cube","not mounted","Cube"),"the substitute names the shape it stands for")
    testing.expect(t,has_warning(&report,"/Engine/EngineMaterials/M_Paint.M_Paint","grid of Mirai"),"and the material")
}

// M_Tint: the base color of the custom data of an instance, gray without it.
@(private="file")
tint_package :: proc() -> []u8 {
    p:=fx.package_make()
    tint:=fx.export(&p,fx.class(&p,"/Script/Engine","Material"),0,"M_Tint",nil)
    data:=fx.writer(&p)
    fx.color_put(&data,"ConstDefaultValue",{0.5,0.5,0.5,1})
    custom:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionPerInstanceCustomData3Vector"),tint,"Custom",fx.finish(&data))
    w:=fx.writer(&p)
    fx.input_put(&w,"BaseColor","ColorMaterialInput",{expression=custom,mask={true,true,true,false}})
    p.exports[0].data=fx.finish(&w)
    return fx.package_bytes(&p,"/Game/Materials/M_Tint")
}

// A map with an actor of two instanced components of the quad: Plain, with
// one instance and over its slot a MaterialInstanceDynamic of M_Tint the
// actor keeps, and Tinted, M_Tint with the custom data of its three
// instances, red, red and blue.
@(private="file")
instanced_map :: proc() -> []u8 {
    l:=fixture.level_begin("/Game/Maps/Tiles")
    w:=&l.w
    mesh:=fixture.package_object(w,"/Game/Meshes/SM_Fixture","/Script/Engine","StaticMesh","SM_Fixture")
    tint:=fixture.package_object(w,"/Game/Materials/M_Tint","/Script/Engine","Material","M_Tint")
    actor:=fixture.actor_add(&l,fixture.engine_class(w,"Actor"),"Actor_0","Tiles")
    dynamic_props:=fixture.bytes_make()
    fixture.object_property(&dynamic_props,w,"Parent",tint)
    fixture.none(&dynamic_props,w)
    fixture.put_u32(&dynamic_props,0)
    held:=fixture.export_add(w,{class=fixture.engine_class(w,"MaterialInstanceDynamic"),outer=actor,name="MID_M_Tint",data=dynamic_props.data[:]})
    component :: proc(l:^fixture.Level_Writer,actor,mesh,material:i32,name:string,count:int,colors:[][3]f32) -> i32 {
        w:=&l.w
        props:=fixture.bytes_make()
        fixture.object_property(&props,w,"StaticMesh",mesh)
        fixture.objects_property(&props,w,"OverrideMaterials",{material})
        fixture.none(&props,w)
        fixture.put_u32(&props,0)
        fixture.put_u32(&props,64);fixture.put_u32(&props,u32(count))
        for i in 0..<count {
            for row in ([4][4]f32{{1,0,0,0},{0,1,0,0},{0,0,1,0},{f32(i)*100,0,0,1}}) {for v in row {fixture.put_f32(&props,v)}}
        }
        fixture.put_u32(&props,4);fixture.put_u32(&props,u32(len(colors)*3))
        for color in colors {for v in color {fixture.put_f32(&props,v)}}
        return fixture.export_add(w,{class=fixture.engine_class(w,"InstancedStaticMeshComponent"),outer=actor,name=name,data=props.data[:]})
    }
    root:=component(&l,actor,mesh,held,"Plain",1,{})
    component(&l,actor,mesh,tint,"Tinted",3,{{1,0,0},{1,0,0},{0,0,1}})
    fixture.actor_set(&l,actor,root)
    return fixture.level_bytes(&l)
}

// A translator of instanced components that marks, for each instance, the
// material instanced_material gives the first slot: an entity named after
// the component and the instance, which shows it.
@(private="file")
instanced_mark :: proc(c:^Context,actors:[]int) -> int {
    for item in c.instanced {
        instances,error:=level.component_instances(c.d,item.component,context.temp_allocator)
        if error.code!=.None {continue}
        paths:=slot_material_paths(c,item.component)
        if len(paths)==0 {continue}
        for _,i in instances.matrices {
            name:=fmt.tprintf("%s %d",c.d.components[item.component].name,i)
            e,made:=entity_make(c,0,fmt.tprintf("%s|mark",name),name,{{},1,{1,1,1}})
            if !made {continue}
            shown:render.Mesh_Renderer
            shown.materials[0],_=instanced_material(c,paths[0],level.instance_custom(instances,i))
            component_set(c,e,"Mesh_Renderer",&shown)
        }
    }
    return len(actors)
}

// The material of an instanced component the level keeps inside an actor is
// written for it, and a material that reads the custom data of the instances
// has a variant for each set of it, with its values.
@(test)
instanced_components_show_the_materials_the_level_keeps_and_the_variants_of_their_custom_data :: proc(t:^testing.T) {
    f:=folders_make("instanced")
    defer folders_remove(f)
    _=os.write_entire_file(fmt.tprintf("%s/Content/Materials/M_Tint.uasset",f.unreal),tint_package())
    path:=fmt.tprintf("%s/Content/Maps/Tiles.umap",f.unreal)
    _=os.write_entire_file(path,instanced_map())
    translators:=[]Translator{{classes={0="InstancedFoliageActor"},translate=instanced_mark,instanced=true}}
    report,error:=level_import(path,{root=f.mirai},translators,"-")
    if !testing.expectf(t,error.code==.None,"%v: %s",error.code,error.message) {return}
    defer level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    materials:=make(map[base.Asset_Id]string,context.temp_allocator)
    for a in report.imports.assets {if a.kind==asset.KIND_MATERIAL {materials[a.id]=a.path}}
    shown :: proc(scene:^asset.Scene,name:string) -> base.Asset_Id {
        e,_,found:=entity_named(scene,name)
        if !found {return {}}
        renderer,_:=asset.scene_get(scene,e,"Mesh_Renderer",render.Mesh_Renderer)
        return renderer.materials[0]
    }
    color :: proc(types:^asset.Types,materials:map[base.Asset_Id]string,id:base.Asset_Id) -> (base_color:[3]f32,ok:bool) {
        path:=materials[id] or_return
        file:asset.Asset
        if asset.asset_load(&file,path,context.temp_allocator)!=.None {return}
        defer asset.asset_close(&file)
        view,view_error:=asset.material_view(&file,types)
        return view.info.base_color,view_error==.None
    }
    held:=shown(&scene,"Plain 0")
    testing.expectf(t,held!={} && strings.contains(materials[held],"/Tiles/") && strings.contains(materials[held],"MID_M_Tint"),"the instance dynamic the actor keeps goes with the map, named after it: %s",materials[held])
    gray,_:=color(&types,materials,held)
    testing.expectf(t,close3(gray,{0.5,0.5,0.5}),"the instance without custom data shows the default: %v",gray)
    red,blue:=shown(&scene,"Tinted 0"),shown(&scene,"Tinted 2")
    testing.expect(t,red!={} && red==shown(&scene,"Tinted 1"),"instances with the same custom data share a variant")
    testing.expect(t,blue!={} && blue!=red,"other custom data, another variant")
    red_color,_:=color(&types,materials,red)
    blue_color,_:=color(&types,materials,blue)
    testing.expectf(t,close3(red_color,{1,0,0}) && close3(blue_color,{0,0,1}),"each variant the color of its data: %v %v",red_color,blue_color)
}

// The packages of a map are those its imports and its soft references name,
// and theirs, a name with its number as Unreal keeps it, never its build data.
@(test)
the_packages_of_a_map_follow_its_soft_references_but_not_its_build_data :: proc(t:^testing.T) {
    f:=folders_make("packages")
    defer folders_remove(f)
    _=os.write_entire_file(fmt.tprintf("%s/Content/Meshes/SM_Soft.uasset",f.unreal),quad_package())
    _=os.write_entire_file(fmt.tprintf("%s/Content/Meshes/SM_Wall_10.uasset",f.unreal),quad_package())
    _=os.write_entire_file(fmt.tprintf("%s/Content/Maps/Map_BuiltData.uasset",f.unreal),quad_package())
    l:=fixture.level_begin("/Game/Maps/Map")
    append(&l.w.soft_packages,"/Game/Meshes/SM_Soft")
    fixture.package_object(&l.w,"/Game/Meshes/SM_Wall_10","/Script/Engine","StaticMesh","SM_Wall_10")
    fixture.package_object(&l.w,"/Game/Maps/Map_BuiltData","/Script/Engine","MapBuildDataRegistry","Map_BuiltData")
    _=os.write_entire_file(f.map_path,fixture.level_bytes(&l))
    content,_:=strings.replace_all(fmt.tprintf("%s/Content",f.unreal),"\\","/",context.temp_allocator)
    files,error:=level_packages(f.map_path,{{"/Game",content}},context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    soft,numbered,built:=false,false,false
    for file in files {
        soft||=strings.has_suffix(file,"/Meshes/SM_Soft.uasset")
        numbered||=strings.has_suffix(file,"/Meshes/SM_Wall_10.uasset")
        built||=strings.has_suffix(file,"_BuiltData.uasset")
    }
    testing.expectf(t,soft && numbered && !built,"the soft reference, the package of a numbered name and not the build data: %v",files)
}

// Components that only their number tells apart, as those a construction
// script adds, are entities of their own with ids of their own.
@(test)
components_of_one_name_and_another_number_are_entities_apart :: proc(t:^testing.T) {
    f:=folders_make("numbers")
    defer folders_remove(f)
    l:=fixture.level_begin("/Game/Maps/Map")
    w:=&l.w
    mesh:=fixture.package_object(w,"/Game/Meshes/SM_Fixture","/Script/Engine","StaticMesh","SM_Fixture")
    mesh_class:=fixture.engine_class(w,"StaticMeshComponent")
    actor:=fixture.actor_add(&l,fixture.engine_class(w,"Actor"),"Actor_0","Pieces")
    root:Maybe(i32)
    for name,i in ([2]string{"Piece_1","Piece_2"}) {
        props:=fixture.bytes_make()
        fixture.object_property(&props,w,"StaticMesh",mesh)
        fixture.vector_property(&props,w,"RelativeLocation",{f64(i)*100,0,0})
        added:=fixture.component_add(&l,actor,mesh_class,name,props)
        if root==nil {root=added}
    }
    fixture.actor_set(&l,actor,root.?)
    _=os.write_entire_file(f.map_path,fixture.level_bytes(&l))
    report,error:=level_import(f.map_path,{root=f.mirai},engine_content="-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer level_report_destroy(&report)
    testing.expect(t,!has_warning(&report,"same entity id"),"no two components give one id")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    first,_,first_found:=entity_named(&scene,"Piece_1")
    second,_,second_found:=entity_named(&scene,"Piece_2")
    testing.expect(t,first_found && second_found && first!=second,"each keeps its name and an id of its own")
}

// An override that reads other uv sets than the mesh holds for its own
// material says so: M_Light samples set 1 where the quad holds set 0, and
// M_Red reads none.
@(test)
an_override_that_reads_other_uv_sets_than_the_mesh_holds_is_a_warning :: proc(t:^testing.T) {
    f:=folders_make("uv-sets")
    defer folders_remove(f)
    os.make_directory_all(fmt.tprintf("%s/Content/Textures",f.unreal))
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    _=os.write_entire_file(fmt.tprintf("%s/Content/Textures/T_Light.uasset",f.unreal),fx.texture_package("/Game/Textures/T_Light","T_Light",pixels,4,4))
    p:=fx.package_make()
    light:=fx.export(&p,fx.class(&p,"/Script/Engine","Material"),0,"M_Light",nil)
    sample:=fx.writer(&p)
    fx.object_put(&sample,"Texture",fx.external(&p,"/Game/Textures/T_Light","/Script/Engine","Texture2D","T_Light"))
    fx.int_put(&sample,"ConstCoordinate",1)
    baked:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionTextureSample"),light,"Baked",fx.finish(&sample))
    m:=fx.writer(&p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=baked,mask={true,true,true,false}})
    p.exports[light-1].data=fx.finish(&m)
    _=os.write_entire_file(fmt.tprintf("%s/Content/Materials/M_Light.uasset",f.unreal),fx.package_bytes(&p,"/Game/Materials/M_Light"))
    l:=fixture.level_begin("/Game/Maps/Map")
    w:=&l.w
    mesh:=fixture.package_object(w,"/Game/Meshes/SM_Fixture","/Script/Engine","StaticMesh","SM_Fixture")
    mesh_class:=fixture.engine_class(w,"StaticMeshComponent")
    for material,i in ([2]string{"M_Red","M_Light"}) {
        override:=fixture.package_object(w,fmt.tprintf("/Game/Materials/%s",material),"/Script/Engine","Material",material)
        actor:=fixture.actor_add(&l,fixture.engine_class(w,"StaticMeshActor"),fmt.tprintf("StaticMeshActor_%d",i),material)
        props:=fixture.bytes_make()
        fixture.object_property(&props,w,"StaticMesh",mesh)
        fixture.objects_property(&props,w,"OverrideMaterials",{override})
        fixture.actor_set(&l,actor,fixture.component_add(&l,actor,mesh_class,"StaticMeshComponent0",props))
    }
    _=os.write_entire_file(f.map_path,fixture.level_bytes(&l))
    report,error:=level_import(f.map_path,{root=f.mirai},engine_content="-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer level_report_destroy(&report)
    testing.expectf(t,has_warning(&report,"/Game/Materials/M_Light.M_Light","UV sets"),"the override that reads set 1 is named: %v",report.imports.warnings)
    testing.expect(t,!has_warning(&report,"M_Red","UV sets"),"one that reads none is not")
}
