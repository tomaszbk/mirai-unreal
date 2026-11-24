package unreal_foliage_editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import fixture "project:plugins/unreal/editor/fixture/files"
import fx "project:plugins/unreal/editor/material/fixture"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:project"
import "mirai:std/base"
import foliage "plugins:foliage/runtime"

// M_Wind: an offset that sways with time by the parameter Wind Intensity,
// a turn every five seconds.
@(private="file")
wind_package :: proc() -> []u8 {
    p:=fx.package_make()
    wind:=fx.export(&p,fx.class(&p,"/Script/Engine","Material"),0,"M_Wind",nil)
    expression :: proc(p:^fx.Package,outer:i32,class,name:string,w:^fx.Writer) -> i32 {
        return fx.export(p,fx.class(p,"/Script/Engine",strings.concatenate({"MaterialExpression",class},context.temp_allocator)),outer,name,fx.finish(w))
    }
    w:=fx.writer(&p)
    time:=expression(&p,wind,"Time","Time",&w)
    w=fx.writer(&p)
    fx.input_put(&w,"Input","ExpressionInput",{expression=time})
    fx.float_put(&w,"Period",5)
    sine:=expression(&p,wind,"Sine","Sine",&w)
    w=fx.writer(&p)
    fx.name_property_put(&w,"ParameterName","Wind Intensity")
    fx.float_put(&w,"DefaultValue",5)
    intensity:=expression(&p,wind,"ScalarParameter","Intensity",&w)
    w=fx.writer(&p)
    fx.input_put(&w,"A","ExpressionInput",{expression=sine})
    fx.input_put(&w,"B","ExpressionInput",{expression=intensity})
    sway:=expression(&p,wind,"Multiply","Sway",&w)
    w=fx.writer(&p)
    fx.input_put(&w,"WorldPositionOffset","VectorMaterialInput",{expression=sway})
    p.exports[0].data=fx.finish(&w)
    return fx.package_bytes(&p,"/Game/Materials/M_Wind")
}

// A quad standing a metre tall, in the slot of material, with body as its collision.
@(private="file")
plant_package :: proc(name,material:string,body:fixture.Body_Fixture) -> []u8 {
    out:=[3]f32{0,-1,0}
    f:fixture.Mesh_Fixture
    f.layout=.Raw_Mesh
    f.name=name
    f.positions=slice.clone([][3]f32{{0,0,0},{100,0,0},{100,0,100},{0,0,100}},context.temp_allocator)
    f.corners=slice.clone([]u32{0,2,1, 0,3,2},context.temp_allocator)
    f.normals=slice.clone([][3]f32{out,out,out,out,out,out},context.temp_allocator)
    f.uvs=slice.clone([][2]f32{{0,1},{1,0},{1,1},{0,1},{0,0},{1,0}},context.temp_allocator)
    f.groups=slice.clone([]u32{0,0},context.temp_allocator)
    f.smoothing=slice.clone([]u32{1,1},context.temp_allocator)
    f.slots=slice.clone([]fixture.Mesh_Slot{{name="Leaves",imported_name="Leaves",material=material}},context.temp_allocator)
    f.body=body
    return fixture.static_mesh_package(f)
}

// A placed mesh whose material sways in the wind stays an entity with
// Foliage_Sway matching the instanced tree entity placed under Foliage; one
// whose material stands still has no sway.
@(test)
a_placed_mesh_that_sways_stays_an_entity_with_the_wind_of_its_mesh :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-foliage-placed-%d",directory,os.get_pid())
    os.remove_all(top)
    defer os.remove_all(top)
    root:=fmt.tprintf("%s/project",top)
    content:=fmt.tprintf("%s/assets/Unreal/Content",root)
    for folder in ([?]string{"Maps","Meshes","Materials"}) {os.make_directory_all(fmt.tprintf("%s/%s",content,folder))}
    m:=project.manifest_default("Grove")
    project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Grove.uproject",root),"{}")
    _=os.write_entire_file(fmt.tprintf("%s/Materials/M_Wind.uasset",content),wind_package())
    hull:=[][3]f32{{0,-5,0},{10,-5,0},{0,5,0},{0,-5,100},{10,5,100}}
    _=os.write_entire_file(fmt.tprintf("%s/Meshes/SM_Tree.uasset",content),plant_package("SM_Tree","/Game/Materials/M_Wind",{convexes={hull}}))
    _=os.write_entire_file(fmt.tprintf("%s/Meshes/SM_Stone.uasset",content),plant_package("SM_Stone","/Game/Materials/M_Red",{convexes={hull}}))
    l:=fixture.level_begin("/Game/Maps/Grove")
    w:=&l.w
    Plant :: struct {label,mesh:string,sways:bool}
    plants:=[]Plant{{"Tree","SM_Tree",true},{"Stone","SM_Stone",false}}
    for p,i in plants {
        mesh:=fixture.package_object(w,fmt.tprintf("/Game/Meshes/%s",p.mesh),"/Script/Engine","StaticMesh",p.mesh)
        actor:=fixture.actor_add(&l,fixture.engine_class(w,"StaticMeshActor"),fmt.tprintf("StaticMeshActor_%d",i),p.label)
        props:=fixture.bytes_make()
        fixture.object_property(&props,w,"StaticMesh",mesh)
        fixture.vector_property(&props,w,"RelativeLocation",{f64(300*i),0,0})
        fixture.bool_property(&props,w,"bUseDefaultCollision",true)
        fixture.actor_set(&l,actor,fixture.component_add(&l,actor,fixture.engine_class(w,"StaticMeshComponent"),"StaticMeshComponent0",props))
    }
    // The same tree as foliage: an instanced component of one instance.
    tree:=fixture.package_object(w,"/Game/Meshes/SM_Tree","/Script/Engine","StaticMesh","SM_Tree")
    grove:=fixture.actor_add(&l,fixture.engine_class(w,"Actor"),"Actor_2","Grove")
    props:=fixture.bytes_make()
    fixture.object_property(&props,w,"StaticMesh",tree)
    fixture.none(&props,w)
    fixture.put_u32(&props,0)
    fixture.put_u32(&props,64);fixture.put_u32(&props,1)
    for row in ([4][4]f32{{1,0,0,0},{0,1,0,0},{0,0,1,0},{0,900,0,1}}) {for v in row {fixture.put_f32(&props,v)}}
    fixture.put_u32(&props,4);fixture.put_u32(&props,0)
    fixture.actor_set(&l,grove,fixture.export_add(w,{class=fixture.engine_class(w,"InstancedStaticMeshComponent"),outer=grove,name="Trees",data=props.data[:]}))
    level:=fmt.tprintf("%s/Maps/Grove.umap",content)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    provider:=foliage_unreal_default().provider
    imports:=fixture.store_open(root)
    defer fixture.store_close(imports)
    report,error:=unreal_scene.level_import(level,fixture.into(root,imports),provider.translators[:provider.count],"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer unreal_scene.level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    foliage_group:base.Entity_Id
    instanced_tree:base.Entity_Id
    for row in 0..<asset.scene_entity_count(&scene) {
        e:=asset.scene_entity(&scene,row)
        if e.name=="Foliage" {foliage_group=e.id}
    }
    if !testing.expect(t,foliage_group!=0,"Foliage group entity exists") {return}
    for row in 0..<asset.scene_entity_count(&scene) {
        e:=asset.scene_entity(&scene,row)
        if e.parent==foliage_group {instanced_tree=e.id}
    }
    if !testing.expect(t,instanced_tree!=0,"instanced tree entity exists under Foliage") {return}
    instanced_sway,instanced_swaying:=asset.scene_get(&scene,instanced_tree,"Foliage_Sway",foliage.Foliage_Sway)
    if !testing.expect(t,instanced_swaying && instanced_sway.wind>0,"the instanced tree sways") {return}
    for p in plants {
        id:base.Entity_Id
        for row in 0..<asset.scene_entity_count(&scene) {if e:=asset.scene_entity(&scene,row);e.name==p.label {id=e.id}}
        if !testing.expectf(t,id!=0,"%s stays an entity",p.label) {continue}
        given,swaying:=asset.scene_get(&scene,id,"Foliage_Sway",foliage.Foliage_Sway)
        if !p.sways {
            testing.expectf(t,!swaying,"%s stands still: %v",p.label,given)
            continue
        }
        testing.expectf(t,swaying && abs(given.wind-instanced_sway.wind)<=1e-6*instanced_sway.wind && given.flutter==instanced_sway.flutter,"%s sways with the wind and flutter of its mesh as foliage, %v: %v",p.label,instanced_sway,given)
    }
}
