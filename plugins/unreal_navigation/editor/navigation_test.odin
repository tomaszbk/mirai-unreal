package unreal_navigation_editor

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:testing"
import "mirai:asset"
import fixture "project:plugins/unreal/editor/fixture/files"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:project"
import nav "plugins:navigation/runtime"

// The bounds, a modifier volume and a link proxy of an Unreal level: a
// Nav_Bounds and a blocked Nav_Area of the sizes of their CubeBuilders in
// Mirai's axes, and the point link a proxy makes by default, both ways.
@(test)
the_navigation_actors_of_an_unreal_level_are_bounds_areas_and_links :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-navigation-unreal-%d",directory,os.get_pid())
    os.remove_all(top)
    defer os.remove_all(top)
    root:=fmt.tprintf("%s/project",top)
    os.make_directory_all(root)
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    os.make_directory_all(fmt.tprintf("%s/Unreal/Content/Maps",top))
    _=os.write_entire_file(fmt.tprintf("%s/Unreal/Levels.uproject",top),"{}")
    l:=fixture.level_begin("/Game/Maps/Navigation")
    brush :: proc(l:^fixture.Level_Writer,class,name,label:string,size:f32,scale:[3]f64) {
        actor:=fixture.actor_add(l,fixture.script_class(&l.w,"/Script/NavigationSystem",class),name,label)
        props:=fixture.bytes_make()
        fixture.vector_property(&props,&l.w,"RelativeScale3D",scale)
        component:=fixture.component_add(l,actor,fixture.engine_class(&l.w,"BrushComponent"),"BrushComponent0",props)
        cube:=fixture.bytes_make()
        fixture.float_property(&cube,&l.w,"X",size)
        fixture.component_add(l,actor,fixture.script_class(&l.w,"/Script/UnrealEd","CubeBuilder"),"CubeBuilder_0",cube)
        fixture.actor_set(l,actor,component)
    }
    brush(&l,"NavMeshBoundsVolume","NavMeshBoundsVolume_0","Bounds",4000,{1,1,1})
    brush(&l,"NavModifierVolume","NavModifierVolume_0","Pit",400,{1,2,3})
    proxy:=fixture.actor_add(&l,fixture.script_class(&l.w,"/Script/AIModule","NavLinkProxy"),"NavLinkProxy_0","Gap")
    position:=fixture.bytes_make()
    fixture.vector_property(&position,&l.w,"RelativeLocation",{100,0,0})
    scene:=fixture.component_add(&l,proxy,fixture.engine_class(&l.w,"SceneComponent"),"PositionComponent",position)
    fixture.actor_set(&l,proxy,scene)
    level:=fmt.tprintf("%s/Unreal/Content/Maps/Navigation.umap",top)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    provider:=navigation_unreal_default().provider
    report,error:=unreal_scene.level_import(level,{root=root},provider.translators[:provider.count],"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer unreal_scene.level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    s:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&s,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&s)
    found:[3]bool
    for row in 0..<asset.scene_entity_count(&s) {
        e:=asset.scene_entity(&s,row)
        if bounds,ok:=asset.scene_get(&s,e.id,"Nav_Bounds",nav.Nav_Bounds);ok {
            found[0]=e.name=="Bounds"
            // 200 cm by default along Unreal's Y and Z, 4000 along its X: Mirai's x, y and z.
            testing.expect_value(t,bounds.half,[3]f32{1,1,20})
            testing.expect(t,!bounds.air)
        }
        if area,ok:=asset.scene_get(&s,e.id,"Nav_Area",nav.Nav_Area);ok {
            found[1]=e.name=="Pit"
            // An area that names no class is NavArea_Null: nothing walks there.
            testing.expect_value(t,area.area,nav.AREA_BLOCKED)
            testing.expect_value(t,area.half,[3]f32{1,1,2})
        }
        if link,ok:=asset.scene_get(&s,e.id,"Nav_Link",nav.Nav_Link);ok {
            found[2]=e.name=="Gap"
            // From (0,-50,0) to (0,50,0) cm of the proxy: one metre along Mirai's x, both ways.
            testing.expectf(t,linalg.length(link.end)>0.99 && linalg.length(link.end)<1.01 && abs(link.end.y)<1e-4,"end %v",link.end)
            testing.expect(t,link.two_way && link.kind==nav.LINK_JUMP)
        }
    }
    testing.expectf(t,found==[3]bool{true,true,true},"bounds, area and link found: %v",found)
}
