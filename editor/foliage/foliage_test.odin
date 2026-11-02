package unreal_foliage

import "core:math/linalg"
import "core:testing"
import "project:plugins/unreal/editor/fixture"
import level "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

@(private="file")
RELEASE :: [4]u32{0x9c54d522,0xa8264fbe,0x94210746,0x61b482d0}

@(private="file")
Placed :: struct {location,rotation:[3]f32,scale:[3]f32,z_offset:f32,base:i32}

// A level with a landscape component to stand on and an
// InstancedFoliageActor of one type with two instances, saved at foliage
// version `version`, and the instanced component that draws them. With
// kinds, saved since AActor writes whether it was cooked, and with a type of
// actors that placed two actors of the level and a type of ISM actors drawn
// by an instanced component of the InstancedFoliageActor.
@(private="file")
foliage_fixture :: proc(version:i32,placed:[]Placed,kinds:=false) -> unreal.Package {
    b:=fixture.builder_make()
    fixture.custom_version(&b,RELEASE,3)
    fixture.custom_version(&b,FOLIAGE_VERSION,version)
    if kinds {fixture.custom_version(&b,unreal.UE5_SPECIAL_PROJECT_VERSION,4)}
    world:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","World"),0,"Map")
    fixture.properties_end(&b);fixture.export_end(&b)
    level_ref:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","Level"),world,"PersistentLevel")
    fixture.properties_end(&b)
    fixture.put_u32(&b,0);fixture.put_u32(&b,kinds?4:2)
    actors_at:=len(b.bytes)
    for _ in 0..<(kinds?4:2) {fixture.put_u32(&b,0)}
    fixture.export_end(&b)
    ground:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","StaticMeshActor"),level_ref,"Ground")
    fixture.properties_end(&b);fixture.export_end(&b)
    ground_guid:=unreal.Guid{9,8,7,6,5,4,3,2,1,0,1,2,3,4,5,6}
    _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","StaticMeshComponent"),ground,"StaticMeshComponent0")
    fixture.properties_end(&b)
    fixture.put_u32(&b,1);fixture.put_guid(&b,ground_guid)
    fixture.export_end(&b)
    mesh_package:=fixture.package_import(&b,"/Game/SM_Fern")
    mesh:=fixture.object_import(&b,mesh_package,"/Script/Engine","StaticMesh","SM_Fern")
    ifa_class:=fixture.class_import(&b,"/Script/Foliage","InstancedFoliageActor")
    // The actor first, so the type and the component can name it as their outer.
    ifa:=unreal.Object_Ref(len(b.exports)+1)
    type_ref:=ifa+1
    component_ref:=ifa+2
    actor_type,bush_type,bush_component:=ifa+3,ifa+4,ifa+5
    trees:=[2]unreal.Object_Ref{ifa+6,ifa+7}
    tree_class:=fixture.object_import(&b,fixture.package_import(&b,"/Game/BP_Tree"),"/Script/Engine","BlueprintGeneratedClass","BP_Tree_C")
    bush_class:=fixture.object_import(&b,fixture.package_import(&b,"/Game/BP_Bush"),"/Script/Engine","BlueprintGeneratedClass","BP_Bush_C")
    _=fixture.export_begin(&b,ifa_class,level_ref,"InstancedFoliageActor")
    if kinds {
        descriptors:=fixture.structs_begin(&b,"DescriptorComponents","ISMComponentData",1)
        fixture.object_property(&b,"Component",bush_component)
        fixture.element_end(&b)
        fixture.structs_end(&b,descriptors)
    }
    fixture.properties_end(&b)
    fixture.put_u32(&b,0)
    if kinds {fixture.put_u32(&b,0)} // not cooked
    // The base cache: one base.
    fixture.put_i32(&b,2)
    fixture.put_u32(&b,1)
    fixture.put_i32(&b,1);fixture.put_guid(&b,ground_guid)
    for _ in 0..<9 {fixture.put_f32(&b,0)}
    fixture.put_u32(&b,0)
    instance :: proc(b:^fixture.Builder,i:Placed) {
        fixture.put_vec3(b,i.location);fixture.put_vec3(b,i.rotation);fixture.put_vec3(b,i.scale)
        fixture.put_vec3(b,{})
        fixture.put_guid(b,{})
        fixture.put_u32(b,0)
        fixture.put_f32(b,i.z_offset)
        fixture.put_i32(b,i.base)
    }
    // One type with its component and instances.
    fixture.put_u32(&b,kinds?3:1)
    fixture.put_ref(&b,type_ref)
    if version>=FOLIAGE_ACTOR_SUPPORT {fixture.put_u8(&b,1)}
    fixture.put_ref(&b,component_ref)
    fixture.put_u32(&b,u32(len(placed)))
    for i in placed {instance(&b,i)}
    fixture.put_guid(&b,{})
    if kinds {
        // A type of actors: an actor of the level at each of its instances.
        fixture.put_ref(&b,actor_type)
        fixture.put_u8(&b,2)
        fixture.put_u32(&b,2);fixture.put_ref(&b,trees[0]);fixture.put_ref(&b,trees[1])
        fixture.put_ref(&b,tree_class)
        fixture.put_u32(&b,2)
        instance(&b,{location={1000,0,0},scale={1,1,1},base=-1})
        instance(&b,{location={2000,0,0},scale={1,1,1},base=-1})
        fixture.put_guid(&b,{})
        // A type of ISM actors: its guid, its handle, a transform for descriptor 0, its class.
        fixture.put_ref(&b,bush_type)
        fixture.put_u8(&b,3)
        fixture.put_guid(&b,{});fixture.put_i32(&b,0);fixture.put_guid(&b,{})
        fixture.put_u32(&b,1)
        fixture.put_i32(&b,0)
        fixture.put_u32(&b,1)
        for value in ([10]f32{0,0,0,1, 0,0,0, 1,1,1}) {fixture.put_f32(&b,value)}
        fixture.put_ref(&b,bush_class)
        fixture.put_u32(&b,1)
        instance(&b,{location={0,3000,0},scale={1,1,1},base=-1})
        fixture.put_guid(&b,{})
    }
    fixture.export_end(&b)
    _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Foliage","FoliageType_InstancedStaticMesh"),ifa,"FoliageType_InstancedStaticMesh_0")
    fixture.object_property(&b,"Mesh",mesh)
    fixture.float_property(&b,"Density",250)
    scale:=fixture.struct_begin(&b,"ScaleX","FloatInterval")
    fixture.float_property(&b,"Min",0.5);fixture.float_property(&b,"Max",2)
    fixture.struct_end(&b,scale)
    cull:=fixture.struct_begin(&b,"CullDistance","Int32Interval")
    fixture.int_property(&b,"Max",5000)
    fixture.struct_end(&b,cull)
    fixture.bool_property(&b,"CastShadow",false)
    body:=fixture.struct_begin(&b,"BodyInstance","BodyInstance")
    fixture.name_property(&b,"CollisionProfileName","BlockAll")
    fixture.struct_end(&b,body)
    fixture.properties_end(&b);fixture.export_end(&b)
    _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Foliage","FoliageInstancedStaticMeshComponent"),ifa,"FoliageInstancedStaticMeshComponent_0")
    fixture.object_property(&b,"StaticMesh",mesh)
    fixture.properties_end(&b)
    fixture.put_u32(&b,0)
    fixture.put_u32(&b,0) // bCooked
    fixture.put_u32(&b,64);fixture.put_u32(&b,u32(len(placed)))
    for i in placed {
        m:=unreal_matrix({location={f64(i.location.x),f64(i.location.y),f64(i.location.z)},rotation={f64(i.rotation.x),f64(i.rotation.y),f64(i.rotation.z)},scale=i.scale})
        for row in m {for value in row {fixture.put_f32(&b,f32(value))}}
    }
    fixture.export_end(&b)
    fixture.patch_u32(&b,actors_at,u32(ground));fixture.patch_u32(&b,actors_at+4,u32(ifa))
    if kinds {
        actor_type_class:=fixture.class_import(&b,"/Script/Foliage","FoliageType_Actor")
        _=fixture.export_begin(&b,actor_type_class,ifa,"FoliageType_Actor_0")
        fixture.object_property(&b,"ActorClass",tree_class)
        fixture.properties_end(&b);fixture.export_end(&b)
        _=fixture.export_begin(&b,actor_type_class,ifa,"FoliageType_Actor_1")
        fixture.object_property(&b,"ActorClass",bush_class)
        fixture.bool_property(&b,"bStaticMeshOnly",true)
        fixture.properties_end(&b);fixture.export_end(&b)
        _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","InstancedStaticMeshComponent"),ifa,"InstancedStaticMeshComponent_0")
        fixture.properties_end(&b);fixture.export_end(&b)
        for tree,i in trees {
            _=fixture.export_begin(&b,tree_class,level_ref,i==0?"BP_Tree_C_0":"BP_Tree_C_1")
            fixture.str_property(&b,"ActorLabel",i==0?"Tree 1":"Tree 2")
            fixture.properties_end(&b);fixture.export_end(&b)
            fixture.patch_u32(&b,actors_at+8+4*i,u32(tree))
        }
    }
    return fixture.package_of(&b,"/Game/Map")
}

// A type of actors is the actors of the level it placed, and one of ISM
// actors the instanced components that draw it; a save that says whether
// the actor was cooked is read past that.
@(test)
foliage_of_actors_and_of_ism_actors_names_the_actors_and_components_that_show_it :: proc(t:^testing.T) {
    placed:=[]Placed{{location={100,200,300},scale={1,1,1},base=-1}}
    p:=foliage_fixture(15,placed,true)
    lib:level.Library
    level.library_init(&lib,nil)
    defer level.library_destroy(&lib)
    map_index,_:=level.library_add(&lib,"/Game/Map",&p)
    d:level.Document
    if !testing.expect_value(t,level.document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer level.document_destroy(&d)
    list,error:=foliage_read(&d)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None) || !testing.expect_value(t,len(list),1) {return}
    defer foliages_destroy(&list)
    f:=list[0]
    if !testing.expect_value(t,len(f.types),3) {return}
    testing.expect_value(t,f.types[0].kind,Foliage_Kind.Static_Mesh)
    testing.expect_value(t,f.compared,1)
    trees:=f.types[1]
    testing.expect_value(t,trees.kind,Foliage_Kind.Actor)
    testing.expect_value(t,trees.actor_class,"/Game/BP_Tree.BP_Tree_C")
    testing.expect_value(t,trees.name,"BP_Tree")
    if testing.expect_value(t,trees.instance_count,2) {
        for i in 0..<2 {
            a:=f.instances[trees.first_instance+i].actor
            testing.expectf(t,a>=0 && d.actors[a].label==(i==0?"Tree 1":"Tree 2"),"instance %d is the actor it placed",i)
        }
    }
    bushes:=f.types[2]
    testing.expect_value(t,bushes.kind,Foliage_Kind.ISM_Actor)
    testing.expect_value(t,bushes.actor_class,"/Game/BP_Bush.BP_Bush_C")
    testing.expect_value(t,bushes.instance_count,1)
    testing.expect_value(t,f.instances[bushes.first_instance].actor,-1)
    if testing.expect_value(t,len(f.components),1) {
        testing.expect_value(t,d.components[f.components[0]].name,"InstancedStaticMeshComponent_0")
    }
}

@(test)
foliage_instances_and_types_come_out_in_mirai_space_and_match_their_component :: proc(t:^testing.T) {
    placed:=[]Placed{
        {location={100,200,300},rotation={0,90,0},scale={2,2,2},z_offset=-10,base=1},
        {location={-500,0,0},rotation={10,20,30},scale={1,1,1.5},base=-1},
    }
    for version in ([2]i32{11,15}) {
        p:=foliage_fixture(version,placed)
        lib:level.Library
        level.library_init(&lib,nil)
        defer level.library_destroy(&lib)
        map_index,_:=level.library_add(&lib,"/Game/Map",&p)
        d:level.Document
        if !testing.expect_value(t,level.document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {continue}
        defer level.document_destroy(&d)
        list,error:=foliage_read(&d)
        if !testing.expect_value(t,error.code,unreal.Error_Code.None) {continue}
        defer foliages_destroy(&list)
        if !testing.expect_value(t,len(list),1) {continue}
        f:=list[0]
        testing.expect_value(t,len(f.types),1)
        testing.expect_value(t,len(f.instances),2)
        testing.expect_value(t,f.compared,2)
        testing.expect_value(t,f.mismatched,0)
        type:=f.types[0]
        testing.expect_value(t,type.name,"SM_Fern")
        testing.expect_value(t,type.mesh,"/Game/SM_Fern.SM_Fern")
        testing.expect_value(t,type.density,f32(2.5))
        testing.expect_value(t,type.scale[0],[2]f32{0.5,2})
        testing.expect_value(t,type.scale[2],[2]f32{1,1})
        testing.expect_value(t,type.cull,[2]f32{0,50})
        testing.expect(t,!type.casts_shadow && type.collides && type.random_yaw && type.align_to_normal)
        first:=f.instances[0]
        testing.expect(t,linalg.length(first.transform.position-[3]f32{-2,3,1})<1e-4)
        testing.expect(t,linalg.length(mm.quat_rotate(first.transform.rotation,{0,0,1})-[3]f32{-1,0,0})<1e-4,"a yaw of 90 turns forward to the right")
        testing.expect(t,first.based && first.base>=0 && d.components[first.base].name=="StaticMeshComponent0")
        // 10 cm under its base along its up, twice its size: 0.2 m.
        testing.expect(t,abs(first.ground-(-0.2))<1e-5)
        testing.expect(t,!f.instances[1].based && f.instances[1].base==-1)
        testing.expect_value(t,f.instances[1].transform.scale,[3]f32{1,1.5,1})
    }
}
