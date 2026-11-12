package level

import "core:math/linalg"
import "core:testing"
import "project:plugins/unreal/editor/fixture"
import files "project:plugins/unreal/editor/fixture/files"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

// A map of one actor whose root shows mesh (an import of class
// mesh_class) and whose other components hang from sockets of it.
@(private="file")
Hanging :: struct {name,class,socket:string,location,rotation:[3]f32,properties:proc(b:^fixture.Builder)}

@(private="file")
socket_map :: proc(mesh_package,mesh_object,mesh_class,root_class:string,hanging:[]Hanging) -> unreal.Package {
    b:=fixture.builder_make()
    fixture.custom_version(&b,unreal.RELEASE_OBJECT_VERSION,3)
    world:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","World"),0,"Map")
    fixture.properties_end(&b);fixture.export_end(&b)
    level:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","Level"),world,"PersistentLevel")
    fixture.properties_end(&b)
    fixture.put_u32(&b,0);fixture.put_u32(&b,1)
    actors_at:=len(b.bytes)
    fixture.put_u32(&b,0)
    fixture.export_end(&b)
    mesh:=fixture.object_import(&b,fixture.package_import(&b,mesh_package),"/Script/Engine",mesh_class,mesh_object)
    actor:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","Actor"),level,"Actor_0")
    root_at:=len(b.bytes)
    fixture.object_property(&b,"RootComponent",0)
    fixture.properties_end(&b);fixture.export_end(&b)
    root:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine",root_class),actor,"Root")
    fixture.object_property(&b,mesh_class=="StaticMesh"?"StaticMesh":"SkeletalMesh",mesh)
    fixture.vector_property(&b,"RelativeLocation","Vector",{100,0,0})
    fixture.properties_end(&b);fixture.export_end(&b)
    for h in hanging {
        _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine",h.class),actor,h.name)
        fixture.object_property(&b,"AttachParent",root)
        if h.socket!="" {fixture.name_property(&b,"AttachSocketName",h.socket)}
        fixture.vector_property(&b,"RelativeLocation","Vector",h.location)
        fixture.vector_property(&b,"RelativeRotation","Rotator",h.rotation)
        if h.properties!=nil {h.properties(&b)}
        fixture.properties_end(&b);fixture.export_end(&b)
    }
    fixture.patch_u32(&b,actors_at,u32(actor));fixture.patch_u32(&b,root_at+25,u32(root))
    return fixture.package_of(&b,"/Game/Map")
}

@(private="file")
component_named :: proc(d:^Document,name:string) -> int {
    for c,i in d.components {if c.name==name {return i}}
    return -1
}

@(private="file")
near :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-4}

// A component attached to a socket of a static mesh is relative to the
// socket, which the mesh keeps relative to the component that shows it; a
// name the mesh does not have is the component.
@(test)
a_component_on_a_socket_of_a_static_mesh_hangs_from_the_socket :: proc(t:^testing.T) {
    b:=fixture.builder_make()
    socket_class:=fixture.class_import(&b,"/Script/Engine","StaticMeshSocket")
    mesh:=unreal.Object_Ref(1)
    _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","StaticMesh"),0,"SM_Lamp")
    fixture.objects_property(&b,"Sockets",{mesh+1})
    fixture.properties_end(&b);fixture.export_end(&b)
    _=fixture.export_begin(&b,socket_class,mesh,"StaticMeshSocket_0")
    fixture.name_property(&b,"SocketName","Top")
    fixture.vector_property(&b,"RelativeLocation","Vector",{0,0,50})
    fixture.vector_property(&b,"RelativeRotation","Rotator",{0,90,0})
    fixture.properties_end(&b);fixture.export_end(&b)
    lamp:=fixture.package_of(&b,"/Game/SM_Lamp")
    p:=socket_map("/Game/SM_Lamp","SM_Lamp","StaticMesh","StaticMeshComponent",{
        {name="Bulb",class="StaticMeshComponent",socket="top",location={10,0,0}},
        {name="Shade",class="StaticMeshComponent",socket="Bottom",location={10,0,0}},
    })
    lib:Library
    library_init(&lib,nil)
    defer library_destroy(&lib)
    map_index,_:=library_add(&lib,"/Game/Map",&p)
    library_add(&lib,"/Game/SM_Lamp",&lamp)
    d:Document
    if !testing.expect_value(t,document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer document_destroy(&d)
    bulb,error:=component_world(&d,component_named(&d,"Bulb"))
    testing.expect_value(t,error.code,unreal.Error_Code.None)
    // The socket 50 cm over the root at X 100, turned right: 10 cm along it is Y 10.
    testing.expectf(t,near(bulb.position,point_to_mirai({100,10,50})),"on the socket: %v",bulb.position)
    testing.expect(t,near(mm.quat_rotate(bulb.rotation,{0,0,-1}),{1,0,0}),"turned with the socket")
    shade,_:=component_world(&d,component_named(&d,"Shade"))
    testing.expectf(t,near(shade.position,point_to_mirai({110,0,0})),"a socket the mesh does not have is the component: %v",shade.position)
}

// A component attached to a skeletal mesh hangs from a socket of the mesh,
// one of its skeleton, or a bone, in the bind pose of the mesh.
@(test)
a_component_on_a_socket_or_bone_of_a_skeletal_mesh_hangs_from_it_in_its_bind_pose :: proc(t:^testing.T) {
    figure:=files.skeletal_figure(.UE5)
    mesh_bytes:=files.skeletal_mesh_package(figure)
    skeleton_bytes:=files.skeleton_package(.UE5,"/Game/Characters/SK_Fixture_Skeleton",figure.bones,sockets=files.skeletal_figure_sockets())
    mesh,mesh_error:=unreal.package_open(mesh_bytes,context.temp_allocator,source_package="/Game/Characters/SK_Fixture")
    skeleton,skeleton_error:=unreal.package_open(skeleton_bytes,context.temp_allocator,source_package="/Game/Characters/SK_Fixture_Skeleton")
    if !testing.expect(t,mesh_error.code==.None && skeleton_error.code==.None) {return}
    p:=socket_map("/Game/Characters/SK_Fixture","SK_Fixture","SkeletalMesh","SkeletalMeshComponent",{
        {name="Sword",class="StaticMeshComponent",socket="hand_socket",location={10,0,0}},
        {name="Hat",class="StaticMeshComponent",socket="head_socket"},
        {name="Ring",class="StaticMeshComponent",socket="finger_1"},
    })
    lib:Library
    library_init(&lib,nil)
    defer library_destroy(&lib)
    map_index,_:=library_add(&lib,"/Game/Map",&p)
    library_add(&lib,"/Game/Characters/SK_Fixture",&mesh)
    library_add(&lib,"/Game/Characters/SK_Fixture_Skeleton",&skeleton)
    d:Document
    if !testing.expect_value(t,document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer document_destroy(&d)
    // The spine at 100 cm turned left a quarter, the hand 50 cm along it, at Y 50.
    sword,error:=component_world(&d,component_named(&d,"Sword"))
    testing.expect_value(t,error.code,unreal.Error_Code.None)
    // The socket of the mesh (not that of its skeleton) 5 cm along the hand, turned a quarter
    // more: facing -X, the sword 10 cm along it.
    testing.expectf(t,near(sword.position,point_to_mirai({90,55,100})),"on the socket of the mesh: %v",sword.position)
    hat,_:=component_world(&d,component_named(&d,"Hat"))
    testing.expectf(t,near(hat.position,point_to_mirai({100,0,130})),"on the socket of the skeleton: %v",hat.position)
    testing.expect(t,near(hat.scale,{2,2,2}),"scaled by its socket")
    ring,_:=component_world(&d,component_named(&d,"Ring"))
    testing.expectf(t,near(ring.position,point_to_mirai({100,60,100})),"on a bone: %v",ring.position)
}

// The end of a spring arm is its length back along its rotation, then its
// socket offset along it.
@(test)
a_component_on_the_end_of_a_spring_arm_is_where_the_arm_ends_at_rest :: proc(t:^testing.T) {
    b:=fixture.builder_make()
    _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","StaticMesh"),0,"SM_Body")
    fixture.properties_end(&b);fixture.export_end(&b)
    body:=fixture.package_of(&b,"/Game/SM_Body")
    arm_properties :: proc(b:^fixture.Builder) {
        fixture.float_property(b,"TargetArmLength",200)
        fixture.vector_property(b,"SocketOffset","Vector",{0,0,50})
    }
    p:=socket_map("/Game/SM_Body","SM_Body","StaticMesh","StaticMeshComponent",{
        {name="Arm",class="SpringArmComponent",rotation={0,90,0},properties=arm_properties},
    })
    lib:Library
    library_init(&lib,nil)
    defer library_destroy(&lib)
    map_index,_:=library_add(&lib,"/Game/Map",&p)
    library_add(&lib,"/Game/SM_Body",&body)
    d:Document
    if !testing.expect_value(t,document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer document_destroy(&d)
    arm:=component_named(&d,"Arm")
    world,_:=component_world(&d,arm)
    end,error:=component_socket(&d,arm,world,"SpringEndpoint")
    testing.expect_value(t,error.code,unreal.Error_Code.None)
    // Turned right, 200 cm back along it is Y -200, 50 cm up.
    testing.expectf(t,near(end.position,point_to_mirai({100,-200,50})),"%v",end.position)
    testing.expect(t,near(mm.quat_rotate(end.rotation,{0,0,-1}),{1,0,0}),"looking along the arm")
}
