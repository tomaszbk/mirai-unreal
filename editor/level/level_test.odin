package level

import "core:math"
import "core:math/linalg"
import "core:testing"
import importer "mirai:cook/import"
import "project:plugins/unreal/editor/fixture"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

@(private="file")
close3 :: proc(a,b:[3]f32,tolerance:f32=1e-4) -> bool {return linalg.length(a-b)<=tolerance}

// FRotationMatrix of Unreal: rows are where X, Y and Z go (row vectors).
@(private="file")
rotator_matrix :: proc(pitch,yaw,roll:f64) -> (m:[3][3]f64) {
    sp,cp:=math.sincos(pitch*math.PI/180)
    sy,cy:=math.sincos(yaw*math.PI/180)
    sr,cr:=math.sincos(roll*math.PI/180)
    m[0]={cp*cy,cp*sy,sp}
    m[1]={sr*sp*cy-cr*sy,sr*sp*sy+cr*cy,-sr*cp}
    m[2]={-(cr*sp*cy+sr*sy),cy*sr-cr*sp*sy,cr*cp}
    return
}

@(test)
unreal_space_is_a_reflection_whose_rotations_turn_what_the_rotator_matrix_turns :: proc(t:^testing.T) {
    basis,ok:=importer.space_basis(SPACE)
    testing.expect(t,ok && basis.mirrored,"Unreal is left-handed: the change of basis reflects")
    moved,_:=transform_to_mirai({100,200,300},{0,0,0},{1,1,1})
    testing.expect(t,close3(moved.position,{-2,3,1}),"centimetres become metres, X forward is +Z, Y right is -X, Z up is +Y")
    turned,_:=transform_to_mirai({},{0,90,0},{1,1,1})
    testing.expect(t,close3(mm.quat_rotate(turned.rotation,{0,0,1}),{-1,0,0}),"a yaw of 90 turns forward to the right")
    rotators:=[?][3]f64{{0,0,0},{30,0,0},{0,45,0},{0,0,60},{20,-130,75},{-89,10,170},{400,-725,33}}
    vectors:=[?][3]f64{{1,0,0},{0,1,0},{0,0,1},{0.3,-2,5}}
    for r in rotators {
        m:=rotator_matrix(r.x,r.y,r.z)
        converted,error:=transform_to_mirai({},r,{1,1,1})
        testing.expect_value(t,error.code,unreal.Error_Code.None)
        for v in vectors {
            turned_ue:[3]f64
            for j in 0..<3 {turned_ue[j]=v.x*m[0][j]+v.y*m[1][j]+v.z*m[2][j]}
            expected:=point_to_mirai(turned_ue*100)
            got:=mm.quat_rotate(converted.rotation,point_to_mirai(v*100))
            testing.expectf(t,close3(got,expected),"rotator %v on %v: %v, expected %v",r,v,got,expected)
        }
    }
    scaled,_:=transform_to_mirai({},{},{2,3,4})
    testing.expect_value(t,scaled.scale,[3]f32{3,4,2})
    _,bad:=transform_to_mirai({math.nan_f64(),0,0},{},{1,1,1})
    testing.expect_value(t,bad.code,unreal.Error_Code.Malformed)
}

@(private="file")
Map_Fixture :: struct {map_package,blueprint:unreal.Package}

// A map with a StaticMeshActor (root mesh and a child with an absolute
// scale), an actor of a Blueprint whose component takes its location from
// the Blueprint's package, and a null slot; release picks the actor array.
@(private="file")
map_fixture :: proc(release:i32) -> (f:Map_Fixture) {
    bp:=fixture.builder_make()
    bp_root:=fixture.package_import(&bp,"/Script/Engine")
    native_scene:=fixture.object_import(&bp,bp_root,"/Script/Engine","SceneComponent","Default__SceneComponent")
    bp_class:=fixture.export_begin(&bp,fixture.class_import(&bp,"/Script/Engine","BlueprintGeneratedClass"),0,"BP_Lamp_C")
    fixture.properties_end(&bp);fixture.export_end(&bp)
    _=fixture.export_begin(&bp,bp_class,0,"Default__BP_Lamp_C",flags=0x10)
    fixture.properties_end(&bp);fixture.export_end(&bp)
    _=fixture.export_begin(&bp,fixture.class_import(&bp,"/Script/Engine","StaticMeshComponent"),bp_class,"Bulb_GEN_VARIABLE",native_scene)
    fixture.vector_property(&bp,"RelativeLocation","Vector",{0,0,250})
    fixture.properties_end(&bp);fixture.export_end(&bp)
    // UE4 records no template for the components a construction script makes: its SCS_Node names them.
    shade:=fixture.export_begin(&bp,fixture.class_import(&bp,"/Script/Engine","StaticMeshComponent"),bp_class,"Shade_GEN_VARIABLE")
    fixture.vector_property(&bp,"RelativeLocation","Vector",{0,0,300})
    fixture.properties_end(&bp);fixture.export_end(&bp)
    scs:=fixture.export_begin(&bp,fixture.class_import(&bp,"/Script/Engine","SimpleConstructionScript"),bp_class,"SimpleConstructionScript")
    fixture.properties_end(&bp);fixture.export_end(&bp)
    _=fixture.export_begin(&bp,fixture.class_import(&bp,"/Script/Engine","SCS_Node"),scs,"SCS_Node")
    fixture.object_property(&bp,"ComponentTemplate",shade)
    fixture.name_property(&bp,"InternalVariableName","Shade")
    fixture.properties_end(&bp);fixture.export_end(&bp)
    f.blueprint=fixture.package_of(&bp,"/Game/BP_Lamp")

    b:=fixture.builder_make()
    fixture.custom_version(&b,unreal.RELEASE_OBJECT_VERSION,release)
    world:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","World"),0,"Map")
    fixture.properties_end(&b);fixture.export_end(&b)
    level_class:=fixture.class_import(&b,"/Script/Engine","Level")
    actor_class:=fixture.class_import(&b,"/Script/Engine","StaticMeshActor")
    mesh_class:=fixture.class_import(&b,"/Script/Engine","StaticMeshComponent")
    lamp:=fixture.package_import(&b,"/Game/BP_Lamp")
    lamp_class:=fixture.object_import(&b,lamp,"/Script/Engine","BlueprintGeneratedClass","BP_Lamp_C")
    bulb_template:=fixture.object_import(&b,lamp_class,"/Script/Engine","StaticMeshComponent","Bulb_GEN_VARIABLE")
    level:=fixture.export_begin(&b,level_class,world,"PersistentLevel")
    fixture.properties_end(&b)
    fixture.put_u32(&b,0)
    if release<LEVEL_ACTORS_ARRAY {fixture.put_ref(&b,0)}
    fixture.put_u32(&b,3)
    actors_at:=len(b.bytes)
    fixture.put_u32(&b,0);fixture.put_u32(&b,0);fixture.put_u32(&b,0)
    fixture.export_end(&b)
    rock:=fixture.export_begin(&b,actor_class,level,"StaticMeshActor_3")
    root_at:=len(b.bytes)
    fixture.object_property(&b,"RootComponent",0)
    fixture.str_property(&b,"ActorLabel","Rock")
    fixture.properties_end(&b);fixture.export_end(&b)
    root:=fixture.export_begin(&b,mesh_class,rock,"StaticMeshComponent0")
    fixture.vector_property(&b,"RelativeLocation","Vector",{100,0,0})
    fixture.vector_property(&b,"RelativeRotation","Rotator",{0,90,0})
    fixture.vector_property(&b,"RelativeScale3D","Vector",{2,2,2})
    fixture.properties_end(&b);fixture.export_end(&b)
    _=fixture.export_begin(&b,mesh_class,rock,"Moss")
    fixture.object_property(&b,"AttachParent",root)
    fixture.vector_property(&b,"RelativeLocation","Vector",{10,0,0})
    fixture.bool_property(&b,"bAbsoluteScale",true)
    fixture.name_property(&b,"AttachSocketName","Top")
    fixture.properties_end(&b);fixture.export_end(&b)
    lamp_actor:=fixture.export_begin(&b,lamp_class,level,"BP_Lamp_2")
    lamp_root_at:=len(b.bytes)
    fixture.object_property(&b,"RootComponent",0)
    fixture.properties_end(&b);fixture.export_end(&b)
    lamp_root:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","SceneComponent"),lamp_actor,"DefaultSceneRoot")
    fixture.vector_property(&b,"RelativeLocation","Vector",{0,500,0})
    fixture.properties_end(&b);fixture.export_end(&b)
    _=fixture.export_begin(&b,mesh_class,lamp_actor,"Bulb",bulb_template)
    fixture.object_property(&b,"AttachParent",lamp_root)
    fixture.properties_end(&b);fixture.export_end(&b)
    _=fixture.export_begin(&b,mesh_class,lamp_actor,"Shade")
    fixture.object_property(&b,"AttachParent",lamp_root)
    fixture.properties_end(&b);fixture.export_end(&b)
    // The references the builder could only know now.
    fixture.patch_u32(&b,actors_at,u32(rock));fixture.patch_u32(&b,actors_at+8,u32(lamp_actor))
    fixture.patch_u32(&b,root_at+25,u32(root));fixture.patch_u32(&b,lamp_root_at+25,u32(lamp_root))
    f.map_package=fixture.package_of(&b,"/Game/Map")
    return
}

@(test)
level_actors_components_and_transforms_follow_attachment_and_archetypes :: proc(t:^testing.T) {
    for release in ([2]i32{2,3}) {
        f:=map_fixture(release)
        lib:Library
        library_init(&lib,nil)
        defer library_destroy(&lib)
        map_index,_:=library_add(&lib,"/Game/Map",&f.map_package)
        library_add(&lib,"/Game/BP_Lamp",&f.blueprint)
        d:Document
        error:=document_open(&d,&lib,map_index)
        if !testing.expect_value(t,error.code,unreal.Error_Code.None) {continue}
        defer document_destroy(&d)
        testing.expect_value(t,len(d.levels),1)
        testing.expect_value(t,len(d.actors),2)
        rock:=d.actors[0]
        testing.expect_value(t,rock.label,"Rock")
        testing.expect(t,class_is(rock.class,"/Script/Engine","StaticMeshActor"))
        testing.expect_value(t,rock.component_count,2)
        testing.expect_value(t,d.components[rock.root].name,"StaticMeshComponent0")
        moss:=rock.first_component+1
        testing.expect_value(t,d.components[moss].parent,rock.root)
        testing.expect_value(t,d.components[moss].socket,"Top")
        world,placed,world_error:=actor_world(&d,0)
        testing.expect(t,placed && world_error.code==.None)
        testing.expect(t,close3(world.position,{0,0,1}))
        moss_world,_:=component_world(&d,moss)
        // 10 cm forward of a root turned to the right and scaled twice: 20 cm to the right.
        testing.expect(t,close3(moss_world.position,{-0.2,0,1}),"the child goes through the turn and scale of its parent")
        testing.expect_value(t,moss_world.scale,[3]f32{1,1,1})
        lamp:=d.actors[1]
        testing.expect_value(t,lamp.label,"BP_Lamp_2")
        testing.expect(t,class_is(lamp.class,"/Game/BP_Lamp","BP_Lamp_C"))
        bulb:=lamp.first_component+1
        r,relative_error:=component_relative(&d,bulb)
        testing.expect_value(t,relative_error.code,unreal.Error_Code.None)
        testing.expect_value(t,r.location,[3]f64{0,0,250})
        testing.expect_value(t,r.scale,[3]f64{1,1,1})
        found,_:=property(&d,d.components[bulb].ref,"RelativeLocation")
        testing.expect_value(t,found.origin,Origin.Archetype)
        native,_:=property(&d,d.components[bulb].ref,"RelativeRotation")
        testing.expect_value(t,native.origin,Origin.Native)
        bulb_world,_:=component_world(&d,bulb)
        testing.expect(t,close3(bulb_world.position,{-5,2.5,0}),"the Blueprint's location of the bulb over the lamp's root")
        shade_relative,shade_error:=component_relative(&d,lamp.first_component+2)
        testing.expect_value(t,shade_error.code,unreal.Error_Code.None)
        testing.expect_value(t,shade_relative.location,[3]f64{0,0,300})
    }
}

@(test)
an_archetype_whose_package_is_missing_is_an_error_of_the_lookup :: proc(t:^testing.T) {
    f:=map_fixture(3)
    lib:Library
    library_init(&lib,nil)
    defer library_destroy(&lib)
    map_index,_:=library_add(&lib,"/Game/Map",&f.map_package)
    d:Document
    if !testing.expect_value(t,document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer document_destroy(&d)
    bulb:=d.actors[1].first_component+1
    _,error:=component_relative(&d,bulb)
    testing.expect_value(t,error.code,unreal.Error_Code.Invalid_Reference)
    testing.expect_value(t,d.components[bulb].parent,d.actors[1].root)
}

@(test)
a_component_that_keeps_what_its_native_actor_constructor_sets_takes_it :: proc(t:^testing.T) {
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
    spot:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","SpotLight"),level,"SpotLight_1")
    root_at:=len(b.bytes)
    fixture.object_property(&b,"RootComponent",0)
    fixture.properties_end(&b);fixture.export_end(&b)
    light:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","SpotLightComponent"),spot,"LightComponent0")
    fixture.vector_property(&b,"RelativeLocation","Vector",{0,0,300})
    fixture.properties_end(&b);fixture.export_end(&b)
    fixture.patch_u32(&b,actors_at,u32(spot));fixture.patch_u32(&b,root_at+25,u32(light))
    p:=fixture.package_of(&b,"/Game/Map")
    lib:Library
    library_init(&lib,nil)
    defer library_destroy(&lib)
    map_index,_:=library_add(&lib,"/Game/Map",&p)
    d:Document
    if !testing.expect_value(t,document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer document_destroy(&d)
    r,_:=component_relative(&d,d.actors[0].root)
    testing.expect_value(t,r.rotation,[3]f64{-90,0,0})
    world_t,_,_:=actor_world(&d,0)
    testing.expect(t,close3(mm.quat_rotate(world_t.rotation,{0,0,1}),{0,-1,0}),"a spot light points down")
}

// A Blueprint that changes a component it inherits keeps a template for it
// in its InheritableComponentHandler: without templates in the save (UE4),
// that template is the archetype of the component of each actor, and the
// template of the parent's SimpleConstructionScript is its archetype; a
// component the child does not change takes the parent's template.
@(test)
an_inherited_component_a_blueprint_changes_takes_its_override_template :: proc(t:^testing.T) {
    parent:=fixture.builder_make()
    parent_class:=fixture.export_begin(&parent,fixture.class_import(&parent,"/Script/Engine","BlueprintGeneratedClass"),0,"BP_Parent_C")
    fixture.properties_end(&parent);fixture.export_end(&parent)
    _=fixture.export_begin(&parent,parent_class,0,"Default__BP_Parent_C",flags=0x10)
    fixture.properties_end(&parent);fixture.export_end(&parent)
    mesh_class:=fixture.class_import(&parent,"/Script/Engine","StaticMeshComponent")
    templates:[2]unreal.Object_Ref
    for i in 0..<2 {
        templates[i]=fixture.export_begin(&parent,mesh_class,parent_class,i==0?"Mesh_GEN_VARIABLE":"Base_GEN_VARIABLE")
        fixture.vector_property(&parent,"RelativeLocation","Vector",{0,0,i==0?100:7})
        fixture.properties_end(&parent);fixture.export_end(&parent)
    }
    scs:=fixture.export_begin(&parent,fixture.class_import(&parent,"/Script/Engine","SimpleConstructionScript"),parent_class,"SimpleConstructionScript")
    fixture.properties_end(&parent);fixture.export_end(&parent)
    for name,i in ([2]string{"Mesh","Base"}) {
        _=fixture.export_begin(&parent,fixture.class_import(&parent,"/Script/Engine","SCS_Node"),scs,i==0?"SCS_Node":"SCS_Node_1")
        fixture.object_property(&parent,"ComponentTemplate",templates[i])
        fixture.name_property(&parent,"InternalVariableName",name)
        fixture.properties_end(&parent);fixture.export_end(&parent)
    }
    parent_package:=fixture.package_of(&parent,"/Game/BP_Parent")

    child:=fixture.builder_make()
    inherited:=fixture.object_import(&child,fixture.package_import(&child,"/Game/BP_Parent"),"/Script/Engine","BlueprintGeneratedClass","BP_Parent_C")
    child_class:=fixture.export_begin(&child,fixture.class_import(&child,"/Script/Engine","BlueprintGeneratedClass"),0,"BP_Child_C")
    fixture.properties_end(&child);fixture.export_end(&child)
    child.exports[int(child_class)-1].super=inherited
    _=fixture.export_begin(&child,child_class,0,"Default__BP_Child_C",flags=0x10)
    fixture.properties_end(&child);fixture.export_end(&child)
    child_mesh_class:=fixture.class_import(&child,"/Script/Engine","StaticMeshComponent")
    handler:=fixture.export_begin(&child,fixture.class_import(&child,"/Script/Engine","InheritableComponentHandler"),child_class,"InheritableComponentHandler")
    records:=fixture.structs_begin(&child,"Records","ComponentOverrideRecord",1)
    fixture.object_property(&child,"ComponentClass",child_mesh_class)
    fixture.object_property(&child,"ComponentTemplate",handler+1)
    key:=fixture.struct_begin(&child,"ComponentKey","ComponentKey")
    fixture.object_property(&child,"OwnerClass",inherited)
    fixture.name_property(&child,"SCSVariableName","Mesh")
    fixture.guid_property(&child,"AssociatedGuid",{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16})
    fixture.struct_end(&child,key)
    fixture.element_end(&child)
    fixture.structs_end(&child,records)
    fixture.properties_end(&child);fixture.export_end(&child)
    // RF_Public, RF_ArchetypeObject and RF_InheritableComponentTemplate.
    _=fixture.export_begin(&child,child_mesh_class,child_class,"Mesh_GEN_VARIABLE",flags=0x1|0x20|0x400000)
    fixture.vector_property(&child,"RelativeScale3D","Vector",{2,2,2})
    fixture.properties_end(&child);fixture.export_end(&child)
    child_package:=fixture.package_of(&child,"/Game/BP_Child")

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
    actor_class:=fixture.object_import(&b,fixture.package_import(&b,"/Game/BP_Child"),"/Script/Engine","BlueprintGeneratedClass","BP_Child_C")
    actor:=fixture.export_begin(&b,actor_class,level,"BP_Child_C_1")
    root_at:=len(b.bytes)
    fixture.object_property(&b,"RootComponent",0)
    fixture.properties_end(&b);fixture.export_end(&b)
    map_mesh_class:=fixture.class_import(&b,"/Script/Engine","StaticMeshComponent")
    mesh:=fixture.export_begin(&b,map_mesh_class,actor,"Mesh")
    fixture.properties_end(&b);fixture.export_end(&b)
    _=fixture.export_begin(&b,map_mesh_class,actor,"Base")
    fixture.object_property(&b,"AttachParent",mesh)
    fixture.properties_end(&b);fixture.export_end(&b)
    fixture.patch_u32(&b,actors_at,u32(actor));fixture.patch_u32(&b,root_at+25,u32(mesh))
    map_package:=fixture.package_of(&b,"/Game/Map")

    lib:Library
    library_init(&lib,nil)
    defer library_destroy(&lib)
    map_index,_:=library_add(&lib,"/Game/Map",&map_package)
    library_add(&lib,"/Game/BP_Parent",&parent_package)
    library_add(&lib,"/Game/BP_Child",&child_package)
    d:Document
    if !testing.expect_value(t,document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer document_destroy(&d)
    a:=d.actors[0]
    if !testing.expect(t,a.root>=0 && d.components[a.root].name=="Mesh") {return}
    next,native,error:=template_of(&d,d.components[a.root].ref)
    testing.expect(t,error.code==.None && !native)
    testing.expect_value(t,library_package(&lib,int(next.pkg)).source_package,"/Game/BP_Child")
    r,relative_error:=component_relative(&d,a.root)
    testing.expect_value(t,relative_error.code,unreal.Error_Code.None)
    testing.expect_value(t,r.scale,[3]f64{2,2,2})
    testing.expect_value(t,r.location,[3]f64{0,0,100})
    base,_:=component_relative(&d,a.first_component+1)
    testing.expect_value(t,base.location,[3]f64{0,0,7})
    testing.expect_value(t,base.scale,[3]f64{1,1,1})
    // What a template saves names objects of the package of the template: the one that holds it.
    held,held_error:=property(&d,d.components[a.root].ref,"RelativeLocation")
    testing.expect(t,held_error.code==.None && held.origin==.Archetype)
    testing.expect_value(t,library_package(&lib,int(held.owner.pkg)).source_package,"/Game/BP_Parent")
    testing.expect_value(t,held.pkg,library_package(&lib,int(held.owner.pkg)))
}
