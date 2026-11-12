package unreal_scene

import "core:testing"
import fixture "project:plugins/unreal/editor/fixture"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"

// A landscape that writes a runtime virtual texture is its writer: with its
// material and the coordinates of its quads in the world.
@(test)
a_landscape_writes_its_runtime_virtual_textures_with_its_material :: proc(t:^testing.T) {
    p:=fixture.landscape_map(virtual_textures={"/Game/RVT/RVT_Ground"})
    lib:level.Library
    level.library_init(&lib,nil)
    defer level.library_destroy(&lib)
    map_index,_:=level.library_add(&lib,"/Game/Map",&p)
    d:level.Document
    if !testing.expect_value(t,level.document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer level.document_destroy(&d)
    c:=Context{d=&d}
    writers:=virtual_texture_writers(&c)
    if !testing.expect_value(t,len(writers),1) {return}
    testing.expect_value(t,writers[0].texture,"/Game/RVT/RVT_Ground.RVT_Ground")
    testing.expect_value(t,writers[0].material,"/Game/M_Ground.M_Ground")
    // The actor is at (1000,2000,300) with 100 cm a quad.
    r:=writers[0].coordinates
    world:=[3]f32{1200,2100,300}
    testing.expect(t,abs(r[0].x*world.x+r[0].y*world.y+r[0].z*world.z+r[0].w-2)<1e-3 && abs(r[1].x*world.x+r[1].y*world.y+r[1].z*world.z+r[1].w-1)<1e-3,"quad (2,1)")
}
