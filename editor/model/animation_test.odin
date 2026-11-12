package uasset

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import fixture "project:plugins/unreal/editor/fixture/files"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// <temp>/<name>/Project.uproject with the skeleton of the figure in
// Content/Characters and the animation in Content/Animations.
@(private="file")
animation_project :: proc(name:string,bytes:[]u8,with_skeleton:=true) -> (folder,path:string) {
    folder,path=project_with(name,bytes)
    os.make_directory_all(fmt.tprintf("%s/Content/Characters",folder))
    os.make_directory_all(fmt.tprintf("%s/Content/Animations",folder))
    moved:=fmt.tprintf("%s/Content/Animations/MM_Fixture.uasset",folder)
    _=os.rename(path,moved)
    if with_skeleton {
        figure:=fixture.skeletal_figure(.UE5)
        _=os.write_entire_file(fmt.tprintf("%s/Content/Characters/SK_Fixture_Skeleton.uasset",folder),fixture.skeleton_package(.UE5,"/Game/Characters/SK_Fixture_Skeleton",figure.bones,morph_curves={"Speed"}))
    }
    return folder,moved
}

@(private="file")
track_of :: proc(clip:asset.Animation_Clip_Desc,target:string,property:anim.Property) -> (asset.Animation_Track_Desc,bool) {
    for track in clip.tracks {if track.target==target && track.property==property {return track,true}}
    return {},false
}

// The library of the clips of a model, as the runtime samples them.
@(private="file")
clips_library :: proc(t:^testing.T,model:^importer.Imported_Model,lib:^anim.Library,types:^asset.Types,file:^asset.Asset) -> anim.Clip {
    doc:asset.Document
    if !testing.expect_value(t,asset.animation_document(&doc,types,{id={1,2},clips=model.animations},context.temp_allocator),asset.Error.None) {return 0}
    bytes,_:=asset.document_bytes(&doc,context.temp_allocator)
    asset.document_destroy(&doc)
    if !testing.expect_value(t,asset.asset_open(file,bytes,context.temp_allocator),asset.Error.None) {return 0}
    view,error:=asset.animation_view(file,types)
    if !testing.expect_value(t,error,asset.Error.None) {return 0}
    desc:=asset.animation_library_desc(view)
    desc.allocator=context.temp_allocator
    anim.library_init(lib,desc)
    return asset.animation_clips_add(view,lib)
}

@(test)
an_animation_of_every_layout_is_a_clip_of_the_bone_paths_of_its_skeleton_in_the_engine_space :: proc(t:^testing.T) {
    basis,_:=importer.space_basis(SPACE)
    for layout in fixture.Animation_Layout {
        f:=fixture.animation_figure(layout)
        folder,path:=animation_project(fmt.tprintf("anim-%v",layout),fixture.animation_package(f))
        defer os.remove_all(folder)
        model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
        if !testing.expectf(t,error.code==.None,"%v: %s",layout,error.message) {continue}
        defer importer.model_destroy(&model)
        testing.expect_value(t,len(model.meshes),0)
        testing.expect_value(t,len(model.nodes),0)
        if !testing.expect_value(t,len(model.animations),1) {continue}
        clip:=model.animations[0]
        testing.expect_value(t,clip.name,"MM_Fixture")
        // Root motion: the root bone, both channels.
        testing.expect_value(t,base.text_get(clip.root.bone[:]),"root")
        testing.expect(t,clip.root.translation && clip.root.rotation)
        if testing.expect_value(t,len(clip.markers),1) {
            testing.expect_value(t,clip.markers[0].name,"Step")
            testing.expect(t,abs(clip.markers[0].time-1.0/30)<1e-6)
        }
        spine,found:=track_of(clip,"root/spine",.Position)
        if testing.expectf(t,found,"%v: the spine moves",layout) && testing.expect_value(t,len(spine.keys),3) {
            // 110 cm up is 1.1 m along +Y.
            testing.expectf(t,linalg.length(spine.keys[1].value.xyz-importer.space_point(basis,f.tracks[1].positions[1]))<1e-5 || layout==.Sequencer,"%v: %v",layout,spine.keys[1].value)
            testing.expect(t,abs(spine.keys[2].time-2.0/30)<1e-6)
            testing.expect_value(t,spine.keys[1].interpolation,anim.Interpolation.Linear)
        }
        // The root that never moves is one key; so is the hand that does not turn.
        if root,root_found:=track_of(clip,"root",.Position);testing.expect(t,root_found) {testing.expect_value(t,len(root.keys),1)}
        if hand,hand_found:=track_of(clip,"root/spine/hand",.Rotation);testing.expect(t,hand_found) {testing.expect_value(t,len(hand.keys),1)}
        _,spine_scaled:=track_of(clip,"root/spine",.Scale)
        testing.expectf(t,spine_scaled==(layout==.Sequencer),"%v: only the sequencer keys the scale of one of the spine",layout)
        // The curve: Unreal's key says how it leaves, Mirai's how it arrives.
        if curve,curve_found:=track_of(clip,"Speed",.Float);testing.expect(t,curve_found) && testing.expect_value(t,len(curve.keys),2) {
            testing.expect_value(t,curve.keys[1].interpolation,anim.Interpolation.Cubic_Spline)
            testing.expect_value(t,curve.keys[0].out_slope.x,f32(3))
            testing.expect_value(t,curve.keys[1].in_slope.x,f32(-1))
            testing.expect_value(t,curve.keys[1].value.x,f32(2))
        }
        // The skeleton marks Speed as a morph target curve: it also moves the target of that name.
        if morph,morph_found:=track_of(clip,"/@morph/Speed",.Float);testing.expect(t,morph_found) {testing.expect_value(t,len(morph.keys),2)}
        // Sampled as the runtime samples it, each frame is the source turned to the engine's space.
        types:asset.Types
        asset.types_init(&types)
        defer asset.types_destroy(&types)
        lib:anim.Library
        file:asset.Asset
        playing:=clips_library(t,&model,&lib,&types,&file)
        if !testing.expect(t,playing!=0) {continue}
        for frame in 0..<3 {
            time:=f32(frame)/30
            for track in anim.clip_tracks(&lib,playing) {
                if track.target!=base.name_hash("root/spine") {continue}
                value:=anim.clip_evaluate(&lib,track,time)
                #partial switch track.property {
                case .Position:
                    source:=f.tracks[1].positions[frame]
                    if layout==.Sequencer && frame==1 {source.x=0.5}
                    testing.expectf(t,linalg.length(value.xyz-importer.space_point(basis,source))<1e-5,"%v: frame %d: position %v",layout,frame,value)
                case .Rotation:
                    q:=fixture.animation_quaternion(f.tracks[1].rotations[frame])
                    expected:=importer.space_rotation(basis,quaternion(w=q.w,x=q.x,y=q.y,z=q.z))
                    d:=abs(value.x*expected.x+value.y*expected.y+value.z*expected.z+value.w*expected.w)
                    testing.expectf(t,abs(d-1)<1e-5,"%v: frame %d: rotation %v against %v",layout,frame,value,expected)
                }
            }
        }
    }
}

@(test)
the_rate_scale_of_an_animation_is_baked_into_its_times_and_slopes :: proc(t:^testing.T) {
    f:=fixture.animation_figure(.Data_Model)
    f.rate_scale=2
    folder,path:=animation_project("anim-rate",fixture.animation_package(f))
    defer os.remove_all(folder)
    model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.model_destroy(&model)
    clip:=model.animations[0]
    if spine,found:=track_of(clip,"root/spine",.Position);testing.expect(t,found) {testing.expect(t,abs(spine.keys[2].time-1.0/30)<1e-6)}
    if curve,found:=track_of(clip,"Speed",.Float);testing.expect(t,found) {
        testing.expect_value(t,curve.keys[0].out_slope.x,f32(6))
        testing.expect(t,abs(curve.keys[1].time-1.0/30)<1e-6)
    }
    testing.expect(t,abs(clip.markers[0].time-0.5/30)<1e-6)
}

@(test)
additive_animations_and_animations_without_their_skeleton_are_refused_with_the_reason :: proc(t:^testing.T) {
    f:=fixture.animation_figure(.UE4)
    f.additive="AAT_LocalSpaceBase"
    folder,path:=animation_project("anim-additive",fixture.animation_package(f))
    defer os.remove_all(folder)
    _,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
    testing.expect_value(t,error.code,importer.Error_Code.Unsupported)
    testing.expectf(t,strings.contains(error.message,"additive") && strings.contains(error.message,"No additive"),"%s",error.message)

    alone,alone_path:=animation_project("anim-alone",fixture.animation_package(fixture.animation_figure(.UE4)),false)
    defer os.remove_all(alone)
    _,missing:=importer.import_model(alone_path,FORMATS[:],{ignore_stored=true})
    testing.expect_value(t,missing.code,importer.Error_Code.Not_Found)
    testing.expectf(t,strings.contains(missing.message,"SK_Fixture_Skeleton"),"%s",missing.message)
}

@(test)
a_skeletal_mesh_imports_its_morph_targets_and_the_sockets_of_its_mesh_and_skeleton :: proc(t:^testing.T) {
    basis,_:=importer.space_basis(SPACE)
    for layout in fixture.Skeletal_Layout {
        figure:=fixture.skeletal_figure(layout)
        folder,path:=project_with(fmt.tprintf("morph-%v",layout),fixture.skeletal_mesh_package(figure))
        defer os.remove_all(folder)
        os.make_directory_all(fmt.tprintf("%s/Content/Characters",folder))
        _=os.write_entire_file(fmt.tprintf("%s/Content/Characters/SK_Fixture_Skeleton.uasset",folder),fixture.skeleton_package(layout,"/Game/Characters/SK_Fixture_Skeleton",figure.bones,sockets=fixture.skeletal_figure_sockets()))
        model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
        if !testing.expectf(t,error.code==.None,"%v: %s",layout,error.message) {continue}
        defer importer.model_destroy(&model)
        mesh:=&model.meshes[0]
        if testing.expect_value(t,len(mesh.morphs),1) {
            testing.expect_value(t,base.text_get(mesh.morphs[0].name[:]),"Smile")
            testing.expect_value(t,mesh.morphs[0].weight,f32(0))
            // Vertex 1 of Unreal (100,0,100), raised 10 cm, is the engine's (0,1,-1) moved 0.1 m along +Y.
            raised:=false
            for delta in mesh.morph_deltas[mesh.morphs[0].first:][:mesh.morphs[0].count] {
                vertex:=mesh.vertices[delta.vertex]
                if linalg.length(vertex.position-[3]f32{0,1,-1})<1e-4 {
                    raised=linalg.length(delta.position-importer.space_point(basis,{0,0,10}))<1e-5
                    testing.expectf(t,linalg.length(delta.normal-importer.space_direction(basis,{0,0.5,0}))<1e-5,"%v: the turned normal %v",layout,delta.normal)
                }
            }
            testing.expectf(t,raised,"%v: Smile raises vertex 1",layout)
        }
        skeleton:=&model.skeletons[0]
        if testing.expect_value(t,len(skeleton.sockets),2) {
            // The mesh's socket replaces the skeleton's of its name; 5 cm along Unreal's X is the engine's front.
            hand:=skeleton.sockets[0]
            testing.expect_value(t,base.text_get(hand.name[:]),"hand_socket")
            testing.expect_value(t,base.text_get(hand.bone[:]),"root/spine/hand")
            testing.expect(t,linalg.length(hand.offset.position-[3]f32{0,0,-0.05})<1e-6)
            q:=hand.offset.rotation
            turned:=mm.quat_rotate(q,{0,0,-1})
            testing.expectf(t,linalg.length(turned-importer.space_direction(basis,{0,1,0}))<1e-5,"a yaw of 90 turns Unreal's X to its Y: %v",turned)
            head:=skeleton.sockets[1]
            testing.expect_value(t,base.text_get(head.name[:]),"head_socket")
            testing.expect_value(t,head.offset.scale,[3]f32{2,2,2})
        }
    }
}
