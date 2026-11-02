package uasset

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import importer "mirai:cook/import"
import fixture "project:plugins/unreal/editor/fixture/files"
import mm "mirai:std/math"

@(private="file")
near3 :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<=1e-4}

@(private="file")
vertex_at :: proc(mesh:^importer.Imported_Mesh,position:[3]f32) -> int {
    for vertex,i in mesh.vertices {if near3(vertex.position,position) {return i}}
    return -1
}

@(private="file")
has_warning :: proc(model:^importer.Imported_Model,part:string) -> bool {
    for warning in model.warnings {if strings.contains(warning,part) {return true}}
    return false
}

@(test)
a_skeletal_mesh_is_a_skinned_mesh_of_its_reference_skeleton_in_the_engine_space :: proc(t:^testing.T) {
    for layout in fixture.Skeletal_Layout {
        folder,path:=project_with(fmt.tprintf("skeletal-%v",layout),fixture.skeletal_mesh_package(fixture.skeletal_figure(layout)))
        defer os.remove_all(folder)
        model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
        if !testing.expectf(t,error.code==.None,"%v: %s",layout,error.message) {continue}
        defer importer.model_destroy(&model)
        if !testing.expect_value(t,len(model.skeletons),1) || !testing.expect_value(t,len(model.meshes),1) {continue}
        skeleton:=&model.skeletons[0]
        testing.expect_value(t,skeleton.name,"SK_Fixture_Skeleton")
        testing.expect_value(t,len(skeleton.bones),12)
        testing.expect_value(t,base.text_get(skeleton.bones[2].path[:]),"root/spine/hand")
        testing.expect_value(t,base.text_get(skeleton.bones[11].name[:]),"finger_9")
        // 100 cm up is 1 m along +Y; a quarter about Unreal's Z is one about the engine's Y, the other way: a mirror.
        spine:=skeleton.bones[1]
        testing.expect(t,near3(spine.translation,{0,1,0}),"the spine in meters and the engine's axes")
        q:=spine.rotation
        testing.expectf(t,abs(q.x)<1e-5 && abs(q.z)<1e-5 && abs(q.y+0.70710677)<1e-5 && abs(q.w-0.70710677)<1e-5,"the spine turned about the engine's Y: %v",q)
        testing.expect(t,near3(skeleton.bones[2].translation,{0,0,0.5}),"50 cm along Unreal's X is the engine's front")
        if !testing.expect_value(t,len(model.nodes),1) {continue}
        testing.expect_value(t,model.nodes[0].mesh,0)
        mesh:=&model.meshes[0]
        testing.expect_value(t,mesh.skeleton,0)
        testing.expect_value(t,len(mesh.skin),len(mesh.vertices))
        if !testing.expect_value(t,len(mesh.joints),12) {continue}
        // Each inverse bind undoes its bone at rest: the bind pose draws the mesh as it is.
        world:[12]mm.Transform
        for bone,i in skeleton.bones {
            local:=mm.Transform{bone.translation,bone.rotation,bone.scale}
            world[i]=local if bone.parent<0 else mm.transform_compose(world[bone.parent],local)
        }
        for joint in mesh.joints {
            product:=joint.inverse_bind*mm.transform_matrix(world[joint.node])
            worst:f32
            for row in 0..<4 {for column in 0..<4 {worst=max(worst,abs(product[row,column]-(row==column?1:0)))}}
            testing.expectf(t,worst<1e-5,"%v: joint %d: the inverse bind undoes its bone (%v)",layout,joint.node,worst)
        }
        // Unreal (100,0,100) is the engine's (0,1,1): half on the spine, half on the hand.
        half:=vertex_at(mesh,{0,1,1})
        if testing.expect(t,half>=0,"the vertex between spine and hand") {
            skin:=mesh.skin[half]
            weights:map[u16]f32
            weights.allocator=context.temp_allocator
            for joint,k in skin.joints {weights[joint]+=f32(skin.weights[k])/255}
            testing.expectf(t,abs(weights[1]-0.5)<0.01 && abs(weights[2]-0.5)<0.01,"%v",skin)
        }
        // Unreal (0,100,100): the eight largest of its influences, weighing 255 together.
        many:=vertex_at(mesh,{-1,1,0})
        if testing.expect(t,many>=0,"the vertex of many influences") {
            skin:=mesh.skin[many]
            total:int
            for weight in skin.weights {total+=int(weight)}
            testing.expect_value(t,total,255)
            testing.expect_value(t,skin.joints[0],u16(2))
            testing.expect(t,skin.weights[7]>0 && skin.weights[0]>skin.weights[7],"largest first")
        }
        // The LOD model of UE5 kept ten; a description builds the eight of a project without unlimited influences.
        testing.expect_value(t,has_warning(&model,"have up to 10 influences"),layout==.UE5)
        testing.expect(t,has_warning(&model,"1 sections that Unreal does not draw are left out"))
        if layout==.Description {
            // Both groups left take the slot of their name, Body.
            if testing.expect_value(t,len(mesh.slots),1) {testing.expect_value(t,mesh.slots[0].id,u32(2))}
        } else {
            // The slots of Unreal's materials by index: the quad of material 1, the triangle of 0.
            if testing.expect_value(t,len(mesh.slots),2) {
                testing.expect_value(t,mesh.slots[0].id,u32(2))
                testing.expect_value(t,mesh.slots[0].label,"Body")
                testing.expect_value(t,mesh.slots[1].id,u32(1))
            }
        }
    }
}

@(test)
a_package_of_a_skeleton_alone_is_that_skeleton :: proc(t:^testing.T) {
    figure:=fixture.skeletal_figure(.UE5)
    folder,path:=project_with("skeleton",fixture.skeleton_package(.UE5,"/Game/Characters/SK_Fixture_Skeleton",figure.bones))
    defer os.remove_all(folder)
    model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),0)
    testing.expect_value(t,len(model.nodes),0)
    if testing.expect_value(t,len(model.skeletons),1) {
        testing.expect_value(t,model.skeletons[0].name,"Fixture_Skeleton")
        testing.expect_value(t,len(model.skeletons[0].bones),12)
    }
}
