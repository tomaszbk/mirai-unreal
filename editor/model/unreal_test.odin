package uasset

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import fixture "project:plugins/unreal/editor/fixture/files"
import material_fixture "project:plugins/unreal/editor/material/fixture"
import upackage "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

@(private="file")
own :: proc(items:[]$T) -> []T {return slice.clone(items,context.temp_allocator)}

// A quad of 1 m in Unreal's XY plane, facing up, with a corner at +X (forward)
// and one at +Y (right), in two slots.
@(private="file")
quad :: proc(layout:fixture.Mesh_Layout) -> (f:fixture.Mesh_Fixture) {
    up:=[3]f32{0,0,1}
    f.layout=layout
    f.positions=own([][3]f32{{0,0,0},{100,0,0},{100,100,0},{0,100,0}})
    f.corners=own([]u32{0,2,1, 0,3,2})
    f.normals=own([][3]f32{up,up,up,up,up,up})
    f.uvs=own([][2]f32{{0,1},{1,0},{1,1},{0,1},{0,0},{1,0}})
    f.colors=own([][4]u8{{255,0,0,255},{255,0,0,255},{255,0,0,255},{0,0,255,255},{0,0,255,255},{0,0,255,255}})
    f.groups=own([]u32{0,1})
    f.group_names=own([]string{"Wood","Metal"})
    f.smoothing=own([]u32{1,1})
    f.slots=own([]fixture.Mesh_Slot{{name="Wood",imported_name="Wood",material="/Game/Materials/M_Wood"},{name="Metal",imported_name="Metal",material="/Game/Materials/M_Metal"}})
    f.recompute_tangents=true
    return
}

// <temp>/<name>/Project.uproject with the package in Content/Meshes.
@(private)
project_with :: proc(name:string,bytes:[]u8) -> (folder,path:string) {
    directory,_:=os.temp_directory(context.temp_allocator)
    folder=fmt.tprintf("%s/mirai-unreal-%d-%s",directory,os.get_pid(),name)
    os.remove_all(folder)
    os.make_directory_all(fmt.tprintf("%s/Content/Meshes",folder))
    _=os.write_entire_file(fmt.tprintf("%s/Project.uproject",folder),"{}")
    path=fmt.tprintf("%s/Content/Meshes/SM_Fixture.uasset",folder)
    _=os.write_entire_file(path,bytes)
    return
}

@(private,rodata)
FORMATS:=[1]importer.Format{FORMAT}

@(test)
a_static_mesh_is_a_mesh_in_meters_and_the_engine_axes_with_a_slot_per_material :: proc(t:^testing.T) {
    for layout in fixture.Mesh_Layout {
        folder,path:=project_with(fmt.tprintf("quad-%v",layout),fixture.static_mesh_package(quad(layout)))
        defer os.remove_all(folder)
        model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
        if !testing.expectf(t,error.code==.None,"%v: %s",layout,error.message) {continue}
        defer importer.model_destroy(&model)
        testing.expect_value(t,model.format,"Unreal")
        if !testing.expect_value(t,len(model.meshes),1) {continue}
        testing.expect_value(t,len(model.nodes),1)
        testing.expect_value(t,model.nodes[0].name,"Fixture")
        mesh:=&model.meshes[0]
        testing.expect_value(t,len(mesh.indices),6)
        // Unreal's slots by index, with the materials named after Unreal's.
        testing.expect_value(t,len(mesh.slots),2)
        testing.expect_value(t,mesh.slots[0].id,u32(1))
        testing.expect_value(t,mesh.slots[1].label,"Metal")
        testing.expect_value(t,model.materials[mesh.slots[0].material].name,"Wood")
        testing.expect_value(t,model.materials[mesh.slots[1].material].name,"Metal")
        // Forward (+X) is the engine's front (-Z), right (+Y) its +X, up (+Z) its +Y.
        testing.expect_value(t,mesh.bounds_min,[3]f32{0,0,-1})
        testing.expect_value(t,mesh.bounds_max,[3]f32{1,0,0})
        for i in 0..<len(mesh.indices)/3 {
            c:=importer.mesh_triangle(mesh,i)
            face:=linalg.cross(c[1].position-c[0].position,c[2].position-c[0].position)
            testing.expectf(t,face.y>0,"%v: triangle %d faces up and outward: %v",layout,i,face)
            for corner in c {
                testing.expect(t,linalg.length(mm.normal_unpack(corner.normal)-[3]f32{0,1,0})<1e-3)
                // Materials no mount holds take the defaults, which do not multiply by the vertex color.
                testing.expect_value(t,corner.color,importer.WHITE)
            }
        }
        testing.expect(t,.Has_Colors not_in mesh.flags)
        warned:=false
        for warning in model.warnings {warned||=strings.contains(warning,"/Game/Materials/M_Wood.M_Wood could not be read")}
        testing.expect(t,warned,"a material that cannot be read is named in a warning")
    }
}

@(test)
the_unreal_space_turns_axes_and_mirrors :: proc(t:^testing.T) {
    basis,ok:=importer.space_basis(SPACE)
    testing.expect(t,ok && basis.mirrored)
    testing.expect_value(t,SPACE.axes,[3]importer.Axis{.Y,.Z,.Negative_X})
}

@(test)
the_project_of_a_package_mounts_game_and_finds_its_materials :: proc(t:^testing.T) {
    folder,path:=project_with("mounts",fixture.static_mesh_package(quad(.Raw_Mesh)))
    defer os.remove_all(folder)
    os.make_directory_all(fmt.tprintf("%s/Content/Materials",folder))
    material:=fmt.tprintf("%s/Content/Materials/M_Wood.uasset",folder)
    _=os.write_entire_file(material,"material")
    mounts:=mounts_find(path,{engine_content=folder})
    if !testing.expect_value(t,len(mounts),2) {return}
    testing.expect_value(t,mounts[0].package_prefix,"/Game")
    file,error:=upackage.source_package_path("/Game/Materials/M_Wood",mounts,context.temp_allocator)
    contents,_:=os.read_entire_file(file,context.temp_allocator)
    testing.expectf(t,error.code==.None && string(contents)=="material","%s",file)
    missing,_:=upackage.source_package_path("/Game/Materials/M_Metal",mounts,context.temp_allocator)
    testing.expect(t,!os.exists(missing))
}

@(test)
a_package_is_known_by_its_tag :: proc(t:^testing.T) {
    testing.expect_value(t,sniff({0xc1,0x83,0x2a,0x9e,0,0}),importer.Sniff.Content)
    testing.expect_value(t,sniff({0x9e,0x2a,0x83,0xc1}),importer.Sniff.No)
    testing.expect_value(t,sniff({}),importer.Sniff.No)
}

@(test)
a_package_without_meshes_or_skeletons_is_refused_by_name :: proc(t:^testing.T) {
    w:=fixture.writer_make({package_name="/Game/Empty"})
    data:=fixture.bytes_make()
    fixture.none(&data,&w)
    fixture.put_u32(&data,0)
    fixture.export_add(&w,{class=fixture.engine_class(&w,"Texture2D"),name="T_Empty",data=data.data[:]})
    folder,path:=project_with("empty",fixture.package_bytes(&w))
    defer os.remove_all(folder)
    _,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
    testing.expect_value(t,error.code,importer.Error_Code.Unsupported)
}

@(test)
the_simple_collision_of_a_mesh_is_its_colliders_as_authored :: proc(t:^testing.T) {
    f:=quad(.Description)
    f.body={
        boxes=own([]fixture.Body_Box{{center={100,0,0},size={200,100,50}}}),
        spheres=own([]fixture.Body_Sphere{{center={0,0,50},radius=30}}),
        capsules=own([]fixture.Body_Capsule{{center={0,0,0},radius=10,length=40}}),
        convexes=own([][][3]f32{own([][3]f32{{0,0,0},{0,100,0},{100,0,0},{0,0,100}})}),
    }
    folder,path:=project_with("body",fixture.static_mesh_package(f))
    defer os.remove_all(folder)
    model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.model_destroy(&model)
    collision:=model.meshes[0].collision
    if !testing.expect_value(t,len(collision.colliders),4) {return}
    near :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-5}
    // Unreal's +X is the engine's -Z, its +Y the engine's +X and its +Z the engine's +Y.
    box:=collision.colliders[0]
    testing.expect_value(t,box.kind,asset.Collider_Kind.Box)
    testing.expect(t,near(box.center,{0,0,-1}),"the box is 1 m forward")
    testing.expect(t,near(box.size,{0.5,0.25,1}),"its half sizes follow the axes they become")
    testing.expect(t,near(mm.quat_rotate(box.rotation,{1,0,0}),{1,0,0}),"a box without rotation keeps the engine's axes")
    sphere:=collision.colliders[1]
    testing.expect(t,sphere.kind==.Sphere && near(sphere.center,{0,0.5,0}) && abs(sphere.size.x-0.3)<1e-6,"the sphere is 50 cm up, of 30 cm")
    capsule:=collision.colliders[2]
    testing.expect(t,capsule.kind==.Capsule && abs(capsule.size.x-0.1)<1e-6 && abs(capsule.size.y-0.2)<1e-6,"the capsule keeps its radius and half its length")
    axis:=mm.quat_rotate(capsule.rotation,{0,1,0})
    testing.expectf(t,near(axis,{0,1,0}) || near(axis,{0,-1,0}),"the capsule of Unreal's Z lies along the engine's Y: %v",axis)
    hull:=collision.colliders[3]
    testing.expect(t,hull.kind==.Hull && hull.point_count==4,"a convex is a hull of its points")
    testing.expect(t,near(collision.points[hull.first_point+1],{1,0,0}),"Unreal's +Y is the engine's +X")

    cooked:importer.Cooked_Mesh
    importer.mesh_cook(&model.meshes[0],{},{},&cooked,context.allocator)
    testing.expect(t,len(cooked.collision.colliders)==4 && cooked.collision.colliders[3].kind==.Hull,"the colliders of the source are those of the mesh, as authored")
    mem.dynamic_arena_destroy(&cooked.arena)
}

@(test)
a_material_of_an_unmounted_engine_is_the_grid_of_mirai :: proc(t:^testing.T) {
    f:=quad(.Description)
    f.slots=own([]fixture.Mesh_Slot{{name="Wood",imported_name="Wood",material="/Engine/EngineMaterials/M_Paint"},{name="Metal",imported_name="Metal",material="/Game/Materials/M_Metal"}})
    folder,path:=project_with("engine",fixture.static_mesh_package(f))
    defer os.remove_all(folder)
    options:=Options{engine_content="-"}
    formats:=[1]importer.Format{format(&options)}
    model,error:=importer.import_model(path,formats[:],{ignore_stored=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.model_destroy(&model)
    if !testing.expect_value(t,len(model.materials),2) {return}
    program :: proc(m:importer.Imported_Material) -> string {m:=m;return strings.clone(strings.truncate_to_byte(string(m.info.program[:]),0),context.temp_allocator)}
    testing.expect_value(t,program(model.materials[0]),GRID_PROGRAM)
    testing.expect_value(t,program(model.materials[1]),"")
    named:=false
    for w in model.warnings {if strings.contains(w,"/Engine/EngineMaterials/M_Paint") && strings.contains(w,"grid of Mirai") {named=true}}
    testing.expect(t,named,"the substitute names the material it stands for")
}

@(test)
a_package_of_a_texture_is_that_texture :: proc(t:^testing.T) {
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    for &v,i in pixels {v=u8(i*13)}
    folder,path:=project_with("texture",material_fixture.texture_package("/Game/Meshes/SM_Fixture","T_Rock",pixels,4,4))
    defer os.remove_all(folder)
    model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.model_destroy(&model)
    if !testing.expect_value(t,len(model.images),1) {return}
    image:=model.images[0]
    testing.expect(t,len(model.meshes)==0 && image.srgb && image.made.width==4 && image.made.height==4 && image.made.format==.RGBA8)
    testing.expect(t,image.made.texels[0]==pixels[2] && image.made.texels[2]==pixels[0],"BGRA becomes RGBA")
}
