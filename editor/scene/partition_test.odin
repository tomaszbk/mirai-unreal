package unreal_scene

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import fixture "project:plugins/unreal/editor/fixture/files"
import "mirai:core"
import escene "mirai:engine/scene"
import "mirai:project"
import "mirai:std/base"

// A quad of 1 m in one slot.
@(private="file")
quad :: proc() -> []u8 {
    up:=[3]f32{0,0,1}
    f:fixture.Mesh_Fixture
    f.layout=.Raw_Mesh
    f.positions=slice.clone([][3]f32{{0,0,0},{100,0,0},{100,100,0},{0,100,0}},context.temp_allocator)
    f.corners=slice.clone([]u32{0,2,1, 0,3,2},context.temp_allocator)
    f.normals=slice.clone([][3]f32{up,up,up,up,up,up},context.temp_allocator)
    f.uvs=slice.clone([][2]f32{{0,1},{1,0},{1,1},{0,1},{0,0},{1,0}},context.temp_allocator)
    f.groups=slice.clone([]u32{0,0},context.temp_allocator)
    f.smoothing=slice.clone([]u32{1,1},context.temp_allocator)
    f.slots=slice.clone([]fixture.Mesh_Slot{{name="Wood",imported_name="Wood"}},context.temp_allocator)
    return fixture.static_mesh_package(f)
}

// A map of World Partition with the loose grid MainGrid (cells of 256 m): a
// rock and a field of grass (two instances of an instanced component) in
// the cell at the origin, another rock 600 m forward, a sun that loads with
// the map and a rock that says it loads with it.
@(private="file")
partition_map :: proc() -> []u8 {
    l:=fixture.level_begin("/Game/Maps/World")
    w:=&l.w
    mesh:=fixture.package_object(w,"/Game/Meshes/SM_Quad","/Script/Engine","StaticMesh","SM_Quad")
    mesh_class:=fixture.engine_class(w,"StaticMeshComponent")
    Rock :: struct {name,label:string,at:[3]f64,always:bool}
    for r in ([?]Rock{{"StaticMeshActor_0","Rock",{100,200,300},false},{"StaticMeshActor_1","Far",{60000,0,0},false},{"StaticMeshActor_2","Always",{0,0,0},true}}) {
        actor:=fixture.actor_add(&l,fixture.engine_class(w,"StaticMeshActor"),r.name,r.label)
        props:=fixture.bytes_make()
        fixture.object_property(&props,w,"StaticMesh",mesh)
        fixture.vector_property(&props,w,"RelativeLocation",r.at)
        root:=fixture.component_add(&l,actor,mesh_class,"StaticMeshComponent0",props)
        actor_props:=fixture.bytes_make()
        if r.always {fixture.bool_property(&actor_props,w,"bIsSpatiallyLoaded",false)}
        fixture.actor_set(&l,actor,root,actor_props)
    }
    sun:=fixture.actor_add(&l,fixture.engine_class(w,"DirectionalLight"),"DirectionalLight_0","Sun")
    light:=fixture.component_add(&l,sun,fixture.engine_class(w,"DirectionalLightComponent"),"LightComponent0",{})
    fixture.actor_set(&l,sun,light)
    grass:=fixture.actor_add(&l,fixture.engine_class(w,"Actor"),"Actor_0","Grass")
    props:=fixture.bytes_make()
    fixture.object_property(&props,w,"StaticMesh",mesh)
    fixture.vector_property(&props,w,"RelativeLocation",{1000,1000,0})
    fixture.none(&props,w)
    fixture.put_u32(&props,0)
    // PerInstanceSMData: two matrices of floats, a metre apart along X.
    fixture.put_u32(&props,64);fixture.put_u32(&props,2)
    for x in ([2]f32{0,100}) {
        for row in ([4][4]f32{{1,0,0,0},{0,1,0,0},{0,0,1,0},{x,0,0,1}}) {for v in row {fixture.put_f32(&props,v)}}
    }
    fixture.put_u32(&props,4);fixture.put_u32(&props,0)
    field:=fixture.export_add(w,{class=fixture.engine_class(w,"InstancedStaticMeshComponent"),outer=grass,name="Blades",data=props.data[:]})
    fixture.actor_set(&l,grass,field)

    settings_props:=fixture.bytes_make()
    settings:=i32(len(w.exports)+1)
    fixture.object_property(&settings_props,w,"WorldPartition",settings+1)
    fixture.none(&settings_props,w);fixture.put_u32(&settings_props,0)
    fixture.export_add(w,{class=fixture.engine_class(w,"WorldSettings"),outer=l.level,name="WorldSettings",data=settings_props.data[:]})
    partition_props:=fixture.bytes_make()
    fixture.object_property(&partition_props,w,"RuntimeHash",settings+2)
    fixture.none(&partition_props,w);fixture.put_u32(&partition_props,0)
    fixture.export_add(w,{class=fixture.engine_class(w,"WorldPartition"),outer=settings,name="WorldPartition",data=partition_props.data[:]})
    desc:=fixture.bytes_make()
    fixture.name_property(&desc,w,"Name","MainGrid")
    fixture.object_property(&desc,w,"MainLayer",settings+3)
    hash_props:=fixture.bytes_make()
    fixture.struct_array_property(&hash_props,w,"RuntimePartitions","RuntimePartitionDesc",{desc})
    fixture.none(&hash_props,w);fixture.put_u32(&hash_props,0)
    fixture.export_add(w,{class=fixture.engine_class(w,"WorldPartitionRuntimeHashSet"),outer=settings+1,name="WorldPartitionRuntimeHashSet",data=hash_props.data[:]})
    grid_props:=fixture.bytes_make()
    fixture.int_property(&grid_props,w,"LoadingRange",51200)
    fixture.none(&grid_props,w);fixture.put_u32(&grid_props,0)
    fixture.export_add(w,{class=fixture.engine_class(w,"RuntimePartitionLHGrid"),outer=settings+2,name="RuntimePartitionLHGrid_0",data=grid_props.data[:]})
    return fixture.level_bytes(&l)
}

@(private="file")
Partition_Folders :: struct {top,mirai,map_path:string}

@(private="file")
partition_folders :: proc(name:string) -> (f:Partition_Folders) {
    directory,_:=os.temp_directory(context.temp_allocator)
    f.top=fmt.tprintf("%s/mirai-unreal-partition-%d-%s",directory,os.get_pid(),name)
    os.remove_all(f.top)
    f.mirai=fmt.tprintf("%s/project",f.top)
    os.make_directory_all(f.mirai)
    m:=project.manifest_default("Partition")
    project.manifest_write(project.path(f.mirai,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    unreal:=fmt.tprintf("%s/assets/Unreal",f.mirai)
    for folder in ([?]string{"Meshes","Maps"}) {os.make_directory_all(fmt.tprintf("%s/Content/%s",unreal,folder))}
    _=os.write_entire_file(fmt.tprintf("%s/Partition.uproject",unreal),"{}")
    _=os.write_entire_file(fmt.tprintf("%s/Content/Meshes/SM_Quad.uasset",unreal),quad())
    f.map_path=fmt.tprintf("%s/Content/Maps/World.umap",unreal)
    _=os.write_entire_file(f.map_path,partition_map())
    return
}

// A translator that takes the instanced components of each scene: an entity
// in the scene, named after what it was given.
@(private="file")
batches_mark :: proc(c:^Context,actors:[]int) -> int {
    origin,section:=section_origin(c)
    name:=fmt.tprintf("Batch %d",len(c.instanced))
    entity_make(c,0,fmt.tprintf("%s|batch",section),name,{origin,1,{1,1,1}})
    return len(actors)
}

@(private="file")
named :: proc(scene:^asset.Scene,name:string) -> (id:base.Entity_Id,found:bool) {
    for row in 0..<asset.scene_entity_count(scene) {
        if e:=asset.scene_entity(scene,row);e.name==name {return e.id,true}
    }
    return
}

@(test)
a_map_of_world_partition_is_a_scene_that_references_a_section_for_each_cell :: proc(t:^testing.T) {
    f:=partition_folders("sections")
    defer os.remove_all(f.top)
    translators:=[]Translator{{classes={0="InstancedFoliageActor"},translate=batches_mark,instanced=true}}
    report,error:=level_import(f.map_path,{root=f.mirai},translators,"-")
    if !testing.expectf(t,error.code==.None,"%v: %s",error.code,error.message) {return}
    defer level_report_destroy(&report)
    testing.expect_value(t,report.sections,2)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    _,sun:=named(&scene,"Sun")
    _,always:=named(&scene,"Always")
    _,rock_at_root:=named(&scene,"Rock")
    testing.expect(t,sun && always && !rock_at_root,"what loads with the map stays in its scene; what streams is in a section")

    // The section of the cell at the origin: a reference where its box is.
    reference_id,referenced:=named(&scene,"MainGrid_L0_X0_Y0_Z0")
    if !testing.expect(t,referenced) {return}
    reference,has:=asset.scene_get(&scene,reference_id,"Scene_Reference",escene.Scene_Reference)
    testing.expect(t,has && reference.rule==.Spatial && reference.scene!={})
    placed,_:=asset.scene_get(&scene,reference_id,"Transform",core.Transform)
    section_path:=""
    for a in report.imports.assets {if a.id==reference.scene {section_path=a.path}}
    testing.expect(t,strings.has_suffix(section_path,"/World/MainGrid_L0_X0_Y0_Z0.scene"),section_path)
    section:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&section,&types,section_path),asset.Error.None) {return}
    defer asset.scene_destroy(&section)
    rock,found:=named(&section,"Rock")
    if testing.expect(t,found) {
        local,_:=asset.scene_get(&section,rock,"Transform",core.Transform)
        world:=local.position+placed.position
        testing.expectf(t,linalg.length(world-[3]f32{2,3,-1})<1e-3,"the rock is where it is in the world through its section: %v",world)
        // The box of the cell holds the rock and the instances of the grass.
        testing.expect(t,abs(local.position.x)<=reference.extents.x+1e-3 && abs(local.position.z)<=reference.extents.z+1e-3)
    }
    _,batch:=named(&section,"Batch 1")
    testing.expect(t,batch,"the translator took the instanced component of the section, once")
    _,_,far:=entity_named_in(&types,report,"MainGrid_L0_X2_Y0_Z0","Far")
    testing.expect(t,far,"the rock 600 m forward is in the section of its cell")

    // Again: the same scenes, the same ids.
    again,again_error:=level_import(f.map_path,{root=f.mirai},translators,"-")
    if !testing.expectf(t,again_error.code==.None,"%s",again_error.message) {return}
    defer level_report_destroy(&again)
    second:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&second,&types,again.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&second)
    again_id,_:=named(&second,"MainGrid_L0_X0_Y0_Z0")
    again_reference,_:=asset.scene_get(&second,again_id,"Scene_Reference",escene.Scene_Reference)
    testing.expect_value(t,again_id,reference_id)
    testing.expect_value(t,again_reference.scene,reference.scene)

    // Without the translator, the instances are a warning that says how to import them.
    alone,alone_error:=level_import(f.map_path,{root=f.mirai},{},"-")
    if !testing.expectf(t,alone_error.code==.None,"%s",alone_error.message) {return}
    defer level_report_destroy(&alone)
    warned:=false
    for w in alone.imports.warnings {warned||=strings.contains(w,"Actor") && strings.contains(w,"batches of foliage")}
    testing.expect(t,warned,"instances without the foliage plugin")
}

// An entity of the scene a section of the import references.
@(private="file")
entity_named_in :: proc(types:^asset.Types,report:Level_Report,section,name:string) -> (id:base.Entity_Id,path:string,found:bool) {
    for a in report.imports.assets {
        if a.kind!=asset.KIND_SCENE || !strings.has_suffix(a.path,fmt.tprintf("/%s.scene",section)) {continue}
        scene:asset.Scene
        if asset.scene_load(&scene,types,a.path)!=.None {return}
        defer asset.scene_destroy(&scene)
        id,found=named(&scene,name)
        return id,a.path,found
    }
    return
}
