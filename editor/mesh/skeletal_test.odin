package mesh

import "core:testing"
import fixture "project:plugins/unreal/editor/fixture/files"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"

@(private="file")
skinned :: proc(t:^testing.T,bytes:[]u8,loc:=#caller_location) -> (source:Skeletal_Mesh,mesh:Skinned_Mesh,ok:bool) {
    p,error:=unreal.package_open(bytes,limits=LIMITS)
    if !testing.expectf(t,error.code==.None,"package: %v",error,loc=loc) {return}
    defer unreal.package_destroy(&p)
    index:=-1
    for _,i in p.exports {if skeletal_mesh_is(&p,i) {index=i}}
    if !testing.expect(t,index>=0,"the package has a skeletal mesh",loc=loc) {return}
    source,error=skeletal_read(&p,index)
    if !testing.expectf(t,error.code==.None,"read: %v",error,loc=loc) {return}
    decoder,_:=kraken.decoder_make(context.temp_allocator)
    mesh,error=skeletal_decode(&p,&source,&decoder)
    if !testing.expectf(t,error.code==.None,"decode: %v",error,loc=loc) {skeletal_mesh_destroy(&source);return}
    return source,mesh,true
}

@(private="file")
near :: proc(a,b:f32) -> bool {return abs(a-b)<=1.0/255}

// The influences of a row of the positions, by bone.
@(private="file")
weight_of :: proc(m:^Skinned_Mesh,row,bone:int) -> (weight:f32) {
    for influence in m.influences[m.skin_first[row]:m.skin_first[row+1]] {if int(influence.bone)==bone {weight+=influence.weight}}
    return
}

@(test)
skeletal_meshes_of_every_layout_read_their_skeleton_materials_and_lod_0 :: proc(t:^testing.T) {
    for layout in fixture.Skeletal_Layout {
        source,mesh,ok:=skinned(t,fixture.skeletal_mesh_package(fixture.skeletal_figure(layout)))
        if !ok {continue}
        defer skeletal_mesh_destroy(&source)
        defer skinned_mesh_destroy(&mesh)
        testing.expect_value(t,source.layout,layout==.Description?Skeletal_Layout.Mesh_Description:Skeletal_Layout.Lod_Model)
        testing.expect_value(t,source.skeleton,"/Game/Characters/SK_Fixture_Skeleton.SK_Fixture_Skeleton")
        if !testing.expect_value(t,len(source.bones),12) {continue}
        testing.expect_value(t,source.bones[2].name,"hand")
        testing.expect_value(t,source.bones[2].parent,1)
        testing.expect_value(t,source.bones[1].translation,[3]f32{0,0,100})
        testing.expect(t,near(source.bones[1].rotation.z,0.70710677) && near(source.bones[1].rotation.w,0.70710677),"the pose of the spine")
        testing.expect_value(t,source.bones[11].name,"finger_9")
        if testing.expect_value(t,len(source.materials),2) {
            testing.expect_value(t,source.materials[1].path,"/Game/Materials/M_Body.M_Body")
            testing.expect_value(t,source.materials[0].imported_name,"Head")
        }
        testing.expect_value(t,source.bounds_max,[3]f32{100,100,100})
        testing.expect_value(t,mesh.uv_count,1)
        testing.expect_value(t,len(mesh.positions),10)
        if layout==.Description {
            // One section per polygon group, each taking the slot of its name; the group of the
            // section the user disabled (by the rank of its material) is left out.
            testing.expect_value(t,mesh.left_out,1)
            if !testing.expect_value(t,len(mesh.sections),2) {continue}
            testing.expect_value(t,mesh.sections[0].material,1)
            testing.expect_value(t,mesh.sections[1].material,1)
            testing.expect_value(t,len(mesh.triangle_section),3)
        } else {
            // The disabled section is left out; LODMaterialMap gives the triangle material 0.
            testing.expect_value(t,mesh.left_out,1)
            if !testing.expect_value(t,len(mesh.sections),2) {continue}
            testing.expect_value(t,mesh.sections[0].material,1)
            testing.expect_value(t,mesh.sections[0].name,"Body")
            testing.expect_value(t,mesh.sections[1].material,0)
            testing.expect_value(t,mesh.sections[1].name,"Head")
            testing.expect_value(t,len(mesh.triangle_section),3)
            testing.expect_value(t,mesh.triangle_section[2],u32(1))
        }
        testing.expect_value(t,mesh.positions[mesh.corner_vertex[1]],[3]f32{100,100,100})
        testing.expect_value(t,mesh.corner_normal[0],[3]f32{0,0,1})
        testing.expect_value(t,mesh.corner_tangent[0],[4]f32{1,0,0,1})
        testing.expect_value(t,mesh.corner_uvs[0][1],[2]f32{1,0})
        testing.expect_value(t,mesh.bounds_max,[3]f32{100,100,100})
        // Influences by the bone map of each section, to the reference skeleton.
        testing.expect(t,near(weight_of(&mesh,0,0),1),"vertex 0 on the root")
        testing.expect(t,near(weight_of(&mesh,1,1),0.5) && near(weight_of(&mesh,1,2),0.5),"vertex 1 between spine and hand")
        testing.expect(t,near(weight_of(&mesh,4,2),1),"the first bone of the map of section 1 is the hand")
        testing.expect(t,near(weight_of(&mesh,6,1),0.75) && near(weight_of(&mesh,6,2),0.25),"vertex 6 through the map of its section")
        // UE4 kept eight; a description keeps the eight of a project without unlimited influences.
        many:=int(mesh.skin_first[4]-mesh.skin_first[3])
        testing.expect_value(t,many,layout==.UE5?10:8)
        total:f32
        for influence in mesh.influences[mesh.skin_first[3]:mesh.skin_first[4]] {total+=influence.weight}
        testing.expect(t,abs(total-1)<=0.01,"the weights of a vertex add to one")
        // Smile raises vertices 1 and 2 and turns the normal of 1, whichever row each corner moves.
        if testing.expect_value(t,len(mesh.morphs),1) && testing.expect_value(t,len(mesh.corner_morph),len(mesh.corner_vertex)) {
            smile:=mesh.morphs[0]
            testing.expect_value(t,smile.name,"Smile")
            for vertex,corner in mesh.corner_vertex {
                row:=mesh.corner_morph[corner]
                expected:=[3]f32{}
                if vertex==1 {expected={0,0,10}} else if vertex==2 {expected={0,0,20}}
                testing.expectf(t,smile.positions[row]==expected,"%v: corner %d of vertex %d: %v",layout,corner,vertex,smile.positions[row])
                if vertex==1 {testing.expect_value(t,smile.normals[row],[3]f32{0,0.5,0})}
            }
        }
        if testing.expect_value(t,len(source.sockets),1) {
            socket:=source.sockets[0]
            testing.expect_value(t,socket.name,"hand_socket")
            testing.expect_value(t,socket.bone,"hand")
            testing.expect_value(t,socket.location,[3]f64{5,0,0})
            testing.expect_value(t,socket.rotation,[3]f64{0,90,0})
        }
    }
}

// The raw weights of a row of the positions, by bone; zero for none.
@(private="file")
raw_of :: proc(m:^Skinned_Mesh,row,bone:int) -> int {return int(weight_of(m,row,bone)*RAW_WEIGHT_ONE+0.5)}

@(test)
a_description_keeps_the_influences_the_build_and_the_project_allow :: proc(t:^testing.T) {
    decode :: proc(t:^testing.T,f:fixture.Skeletal_Fixture,project:Skin_Project,loc:=#caller_location) -> (mesh:Skinned_Mesh,ok:bool) {
        p,error:=unreal.package_open(fixture.skeletal_mesh_package(f),limits=LIMITS)
        if !testing.expectf(t,error.code==.None,"package: %v",error,loc=loc) {return}
        defer unreal.package_destroy(&p)
        source,read_error:=skeletal_read(&p,0)
        if !testing.expectf(t,read_error.code==.None,"read: %v",read_error,loc=loc) {return}
        defer skeletal_mesh_destroy(&source)
        decoder,_:=kraken.decoder_make(context.temp_allocator)
        decode_error:unreal.Error
        mesh,decode_error=skeletal_decode(&p,&source,&decoder,project=project)
        return mesh,testing.expectf(t,decode_error.code==.None,"decode: %v",decode_error,loc=loc)
    }
    f:=fixture.skeletal_figure(.Description)
    // The eight heaviest of the ten of vertex 3 renormalize, the remainders
    // carried down; a 0.5 and 0.5 that add past one lose the remainder on the
    // bone the sort puts first.
    mesh,ok:=decode(t,f,SKIN_PROJECT_DEFAULTS)
    if ok {
        testing.expect_value(t,int(mesh.skin_first[4]-mesh.skin_first[3]),8)
        total:=0
        for influence in mesh.influences[mesh.skin_first[3]:mesh.skin_first[4]] {total+=int(influence.weight*RAW_WEIGHT_ONE+0.5)}
        testing.expect_value(t,total,RAW_WEIGHT_ONE)
        testing.expect_value(t,raw_of(&mesh,3,10),0)
        testing.expect_value(t,raw_of(&mesh,1,1),32768)
        testing.expect_value(t,raw_of(&mesh,1,2),32767)
        skinned_mesh_destroy(&mesh)
    }
    // With unlimited influences, all ten.
    mesh,ok=decode(t,f,skin_project_parse("[/Script/Engine.RendererSettings]\nr.GPUSkin.UnlimitedBoneInfluences=True\n"))
    if ok {
        testing.expect_value(t,int(mesh.skin_first[4]-mesh.skin_first[3]),10)
        skinned_mesh_destroy(&mesh)
    }
    // The limit of the asset over that of the project.
    project:=skin_project_parse("DefaultBoneInfluenceLimit=(Default=4,PerPlatform=())\nr.GPUSkin.UnlimitedBoneInfluences=1")
    testing.expect_value(t,project,Skin_Project{unlimited=true,unlimited_threshold=8,influence_limit=4})
    mesh,ok=decode(t,f,project)
    if ok {
        testing.expect_value(t,int(mesh.skin_first[4]-mesh.skin_first[3]),4)
        skinned_mesh_destroy(&mesh)
    }
    f.influence_limit=1
    mesh,ok=decode(t,f,project)
    if ok {
        testing.expect_value(t,int(mesh.skin_first[2]-mesh.skin_first[1]),1)
        testing.expect_value(t,raw_of(&mesh,1,1),RAW_WEIGHT_ONE)
        testing.expect_value(t,raw_of(&mesh,3,2),RAW_WEIGHT_ONE)
        skinned_mesh_destroy(&mesh)
    }
}

@(test)
a_description_welds_corners_within_the_thresholds_of_its_build :: proc(t:^testing.T) {
    // Vertex 10 is a hundredth of a micron from vertex 0, with its normal, uv
    // and skin; vertex 11 is there too with another uv. A triangle of 0 and 10
    // becomes two corners of one vertex and leaves; a corner of 10 is vertex 0.
    f:=fixture.skeletal_figure(.Description)
    near_zero:=f.positions[0]+{0,0.00001,0}
    f.positions=append_elements(f.positions,near_zero,near_zero)
    f.normals=append_elements(f.normals,f.normals[0],f.normals[0])
    f.tangents=append_elements(f.tangents,f.tangents[0],f.tangents[0])
    f.uvs=append_elements(f.uvs,f.uvs[0],[2]f32{0.5,0.5})
    f.influences=append_elements(f.influences,f.influences[0],f.influences[0])
    f.sections[0].corners=[]u32{0,2,1, 0,3,2, 0,10,1, 10,3,2, 11,3,2}
    for welded in ([2]bool{true,false}) {
        if !welded {f.thresholds=[3]f32{0,0,0}}
        p,error:=unreal.package_open(fixture.skeletal_mesh_package(f),limits=LIMITS)
        if !testing.expectf(t,error.code==.None,"package: %v",error) {return}
        defer unreal.package_destroy(&p)
        source,read_error:=skeletal_read(&p,0)
        if !testing.expectf(t,read_error.code==.None,"read: %v",read_error) {return}
        defer skeletal_mesh_destroy(&source)
        mesh,decode_error:=skeletal_decode(&p,&source)
        if !testing.expectf(t,decode_error.code==.None,"decode: %v",decode_error) {return}
        defer skinned_mesh_destroy(&mesh)
        if welded {
            testing.expect_value(t,len(mesh.triangle_section),5)
            testing.expect_value(t,mesh.degenerate,1)
            testing.expect_value(t,mesh.corner_vertex[6],u32(0))
            testing.expect_value(t,mesh.corner_vertex[9],u32(11))
        } else {
            testing.expect_value(t,len(mesh.triangle_section),6)
            testing.expect_value(t,mesh.corner_vertex[7],u32(10))
        }
    }
}

@(private="file")
append_elements :: proc(items:[]$T,more:..T) -> []T {
    out:=make([]T,len(items)+len(more),context.temp_allocator)
    copy(out,items)
    copy(out[len(items):],more)
    return out
}

@(test)
a_skeleton_reads_its_reference_skeleton_and_sockets :: proc(t:^testing.T) {
    figure:=fixture.skeletal_figure(.UE5)
    for layout in ([2]fixture.Skeletal_Layout{.UE4,.UE5}) {
        p,error:=unreal.package_open(fixture.skeleton_package(layout,"/Game/Characters/SK_Fixture_Skeleton",figure.bones,sockets=fixture.skeletal_figure_sockets(),morph_curves={"Smile"}))
        if !testing.expectf(t,error.code==.None,"%v",error) {continue}
        defer unreal.package_destroy(&p)
        testing.expect(t,skeleton_is(&p,0))
        skeleton,read_error:=skeleton_read(&p,0)
        if !testing.expectf(t,read_error.code==.None,"%v",read_error) {continue}
        defer skeleton_destroy(&skeleton)
        testing.expect_value(t,len(skeleton.bones),12)
        testing.expect_value(t,skeleton.bones[2].translation,[3]f32{50,0,0})
        testing.expect_value(t,skeleton.bones[11].parent,2)
        testing.expect(t,skeleton.curves_known)
        if testing.expect_value(t,len(skeleton.morph_curves),1) {testing.expect_value(t,skeleton.morph_curves[0],"Smile")}
        if testing.expect_value(t,len(skeleton.sockets),2) {
            testing.expect_value(t,skeleton.sockets[1].name,"head_socket")
            testing.expect_value(t,skeleton.sockets[1].scale,[3]f64{2,2,2})
        }
    }
}

// Every truncation and changed byte of each layout is read or refused.
@(test)
damaged_skeletal_meshes_are_read_or_refused :: proc(t:^testing.T) {
    for layout in fixture.Skeletal_Layout {
        bytes:=fixture.skeletal_mesh_package(fixture.skeletal_figure(layout))
        damaged:=make([]u8,len(bytes),context.temp_allocator)
        for at:=0;at<len(bytes);at+=7 {
            copy(damaged,bytes)
            damaged[at]~=0x5a
            skeletal_try(damaged)
            skeletal_try(bytes[:at])
        }
    }
}

@(private="file")
skeletal_try :: proc(bytes:[]u8) {
    p,error:=unreal.package_open(bytes,context.temp_allocator,LIMITS)
    if error.code!=.None {return}
    defer unreal.package_destroy(&p)
    for _,index in p.exports {
        if !skeletal_mesh_is(&p,index) {continue}
        source,read_error:=skeletal_read(&p,index,context.temp_allocator)
        if read_error.code!=.None {continue}
        defer skeletal_mesh_destroy(&source)
        mesh,decode_error:=skeletal_decode(&p,&source,nil,context.temp_allocator)
        if decode_error.code==.None {skinned_mesh_destroy(&mesh)}
    }
}
