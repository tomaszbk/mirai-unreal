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

// M_Wind: an offset that sways with time by the parameter Wind Intensity.
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

// A quad standing a metre tall, in the slot of M_Wind, with body as its collision.
@(private="file")
plant_package :: proc(name:string,body:fixture.Body_Fixture) -> []u8 {
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
    f.slots=slice.clone([]fixture.Mesh_Slot{{name="Leaves",imported_name="Leaves",material="/Game/Materials/M_Wind"}},context.temp_allocator)
    f.body=body
    return fixture.static_mesh_package(f)
}

// A placed mesh whose material sways in the wind is an instance of foliage
// that collides as its entity did: by the hulls its mesh stores, or not at
// all.
@(test)
a_placed_mesh_that_sways_collides_as_foliage_as_its_entity_did :: proc(t:^testing.T) {
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
    Plant :: struct {label,mesh:string,body:fixture.Body_Fixture,collision:foliage.Foliage_Collision}
    hull:=[][3]f32{{0,-5,0},{10,-5,0},{0,5,0},{0,-5,100},{10,5,100}}
    plants:=[]Plant{
        {"Tree","SM_Tree",{convexes={hull}},.Hull},
        {"Reed","SM_Reed",{profile="NoCollision",trace="CTF_UseComplexAsSimple"},.None},
    }
    l:=fixture.level_begin("/Game/Maps/Grove")
    w:=&l.w
    for p,i in plants {
        _=os.write_entire_file(fmt.tprintf("%s/Meshes/%s.uasset",content,p.mesh),plant_package(p.mesh,p.body))
        mesh:=fixture.package_object(w,fmt.tprintf("/Game/Meshes/%s",p.mesh),"/Script/Engine","StaticMesh",p.mesh)
        actor:=fixture.actor_add(&l,fixture.engine_class(w,"StaticMeshActor"),fmt.tprintf("StaticMeshActor_%d",i),p.label)
        props:=fixture.bytes_make()
        fixture.object_property(&props,w,"StaticMesh",mesh)
        fixture.vector_property(&props,w,"RelativeLocation",{f64(300*i),0,0})
        fixture.bool_property(&props,w,"bUseDefaultCollision",true)
        fixture.actor_set(&l,actor,fixture.component_add(&l,actor,fixture.engine_class(w,"StaticMeshComponent"),"StaticMeshComponent0",props))
    }
    level:=fmt.tprintf("%s/Maps/Grove.umap",content)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    provider:=foliage_unreal_default().provider
    report,error:=unreal_scene.level_import(level,{root=root},provider.translators[:provider.count],"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer unreal_scene.level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    s:foliage.Source
    defer foliage.source_destroy(&s)
    meshes:=make(map[base.Asset_Id]string,context.temp_allocator)
    for a in report.imports.assets {
        if a.kind==asset.KIND_MESH {meshes[a.id]=a.path}
        if a.kind!=foliage.FOLIAGE_KIND {continue}
        file:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&file,a.path),asset.Error.None) {return}
        defer asset.asset_close(&file)
        _,read:=foliage.source_read(&s,&file,&types)
        testing.expect(t,read,"the .foliage reads")
    }
    for p in plants {
        entity:=false
        for row in 0..<asset.scene_entity_count(&scene) {entity||=asset.scene_entity(&scene,row).name==p.label}
        kind:Maybe(foliage.Foliage_Collision)
        mesh:base.Asset_Id
        for &type in s.types {if strings.truncate_to_byte(string(type.name[:]),0)==p.label {kind,mesh=type.collision,type.mesh}}
        testing.expectf(t,!entity && kind==p.collision,"%s: an entity %v, collides as foliage as %v, not %v",p.label,entity,kind,p.collision)
        if p.collision!=.Hull {continue}
        // The hulls a collider of its entity took: those its mesh stores.
        file:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&file,meshes[mesh]),asset.Error.None) {continue}
        defer asset.asset_close(&file)
        view,view_error:=asset.mesh_view(&file,&types)
        testing.expectf(t,view_error==.None && len(view.colliders)==1 && view.colliders[0].kind==.Hull,"%s: its mesh stores its hull: %v",p.label,view.colliders)
    }
}
