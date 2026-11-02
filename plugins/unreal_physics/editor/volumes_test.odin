package unreal_physics_editor

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import fixture "project:plugins/unreal/editor/fixture/files"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:project"
import phys "plugins:physics/runtime"

// A BlockingVolume of a CubeBuilder: a box collider of its half sizes, in
// Mirai's axes, that its scale stretches.
@(test)
a_blocking_volume_of_an_unreal_level_is_a_static_box :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-physics-unreal-%d",directory,os.get_pid())
    os.remove_all(top)
    defer os.remove_all(top)
    root:=fmt.tprintf("%s/project",top)
    os.make_directory_all(root)
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    os.make_directory_all(fmt.tprintf("%s/Unreal/Content/Maps",top))
    _=os.write_entire_file(fmt.tprintf("%s/Unreal/Levels.uproject",top),"{}")
    l:=fixture.level_begin("/Game/Maps/Walls")
    actor:=fixture.actor_add(&l,fixture.engine_class(&l.w,"BlockingVolume"),"BlockingVolume_0","Wall")
    props:=fixture.bytes_make()
    fixture.vector_property(&props,&l.w,"RelativeScale3D",{1,2,3})
    brush:=fixture.component_add(&l,actor,fixture.engine_class(&l.w,"BrushComponent"),"BrushComponent0",props)
    cube:=fixture.bytes_make()
    fixture.float_property(&cube,&l.w,"X",400)
    fixture.component_add(&l,actor,fixture.script_class(&l.w,"/Script/UnrealEd","CubeBuilder"),"CubeBuilder_0",cube)
    fixture.actor_set(&l,actor,brush)
    level:=fmt.tprintf("%s/Unreal/Content/Maps/Walls.umap",top)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    provider:=physics_unreal_default().provider
    report,error:=unreal_scene.level_import(level,{root=root},provider.translators[:provider.count],"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer unreal_scene.level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    found:=false
    for row in 0..<asset.scene_entity_count(&scene) {
        e:=asset.scene_entity(&scene,row)
        collider,ok:=asset.scene_get(&scene,e.id,"Collider",phys.Collider)
        if !ok {continue}
        found=e.name=="Wall"
        testing.expect_value(t,collider.kind,phys.Collider_Kind.Box)
        // 200 cm by default along Unreal's Y and Z, 400 along its X: Mirai's x, y and z.
        testing.expect_value(t,collider.size,[3]f32{1,1,2})
    }
    testing.expect(t,found,"the volume is an entity with the label of its actor")
}
