package mesh

import "core:math/linalg"
import "core:testing"
import fixture "project:plugins/unreal/editor/fixture/files"
import unreal "project:plugins/unreal/editor/package"

@(private="file")
sequence_of :: proc(t:^testing.T,bytes:[]u8,loc:=#caller_location) -> (a:Animation,error:unreal.Error,opened:bool) {
    p,open_error:=unreal.package_open(bytes,limits=LIMITS)
    if !testing.expectf(t,open_error.code==.None,"package: %v",open_error,loc=loc) {return}
    defer unreal.package_destroy(&p)
    index:=-1
    for _,i in p.exports {if animation_is(&p,i) {index=i}}
    if !testing.expect(t,index>=0,"the package has an AnimSequence",loc=loc) {return}
    a,error=animation_read(&p,index)
    return a,error,true
}

@(private="file")
near_vector :: proc(a,b:[$N]f32) -> bool {return linalg.length(a-b)<=1e-4}

@(test)
animations_of_every_layout_read_their_bone_tracks_curves_and_markers :: proc(t:^testing.T) {
    for layout in fixture.Animation_Layout {
        f:=fixture.animation_figure(layout)
        a,error,opened:=sequence_of(t,fixture.animation_package(f))
        if !opened || !testing.expectf(t,error.code==.None,"%v: %v",layout,error) {continue}
        defer animation_destroy(&a)
        want:=[fixture.Animation_Layout]Animation_Layout{.UE4=.Raw_Tracks,.Data_Model=.Data_Model,.Bulk_Tracks=.Data_Model,.Sequencer=.Sequencer}
        testing.expect_value(t,a.layout,want[layout])
        testing.expect_value(t,a.skeleton,"/Game/Characters/SK_Fixture_Skeleton.SK_Fixture_Skeleton")
        testing.expect_value(t,a.keys,3)
        testing.expectf(t,abs(a.interval-1.0/30)<1e-6,"%v: %v",layout,a.interval)
        testing.expect(t,a.root_motion)
        testing.expect_value(t,a.additive,Additive_Type.None)
        if testing.expect_value(t,len(a.markers),1) {
            testing.expect_value(t,a.markers[0].name,"Step")
            testing.expect(t,abs(a.markers[0].time-1.0/30)<1e-6)
        }
        if !testing.expect_value(t,len(a.tracks),3) {continue}
        // The sequencer names its controls in lower case, as UFKControlRig does.
        testing.expect_value(t,a.tracks[1].name,"spine")
        spine,hand:=&a.tracks[1],&a.tracks[2]
        source:=f.tracks[1]
        for frame in 0..<3 {
            expected:=source.positions[frame]
            if layout==.Sequencer && frame==1 {expected.x=0.5} // the cubic segment, f.sparse_slope*2 frames/8 above the middle
            testing.expectf(t,near_vector(spine.positions[frame],expected),"%v: frame %d: %v",layout,frame,spine.positions[frame])
            q:=fixture.animation_quaternion(source.rotations[frame])
            r:=spine.rotations[frame]
            testing.expectf(t,abs(abs(linalg.dot(r,q))-1)<1e-5,"%v: frame %d: %v against %v",layout,frame,r,q)
        }
        testing.expect(t,near_vector(hand.scales[2],[3]f32{2,2,2}))
        // A track without scales is one: the sequencer keys it at one.
        if layout==.Sequencer {testing.expect(t,near_vector(spine.scales[1],[3]f32{1,1,1}))} else {testing.expect_value(t,len(spine.scales),0)}
        // The root that never moves keeps one key, or one per frame in the sequencer.
        testing.expect_value(t,len(a.tracks[0].positions),layout==.Sequencer?3:1)
        if testing.expect_value(t,len(a.curves),1) {
            curve:=a.curves[0]
            testing.expect_value(t,curve.name,"Speed")
            if testing.expect_value(t,len(curve.keys),2) {
                testing.expect_value(t,curve.keys[0].interpolation,Curve_Interpolation.Cubic)
                testing.expect_value(t,curve.keys[0].leave,f32(3))
                testing.expect_value(t,curve.keys[1].arrive,f32(-1))
                testing.expect_value(t,curve.keys[1].value,f32(2))
            }
        }
    }
}

@(test)
additive_and_rate_scaled_animations_say_so :: proc(t:^testing.T) {
    f:=fixture.animation_figure(.Data_Model)
    f.additive="AAT_RotationOffsetMeshSpace"
    f.rate_scale=2
    a,error,opened:=sequence_of(t,fixture.animation_package(f))
    if !opened || !testing.expectf(t,error.code==.None,"%v",error) {return}
    defer animation_destroy(&a)
    testing.expect_value(t,a.additive,Additive_Type.Mesh_Space)
    testing.expect_value(t,a.rate,f32(2))
}

// Every cut and changed byte of each layout is read or refused, without a crash or a leak.
@(test)
damaged_animations_are_read_or_refused :: proc(t:^testing.T) {
    for layout in fixture.Animation_Layout {
        bytes:=fixture.animation_package(fixture.animation_figure(layout))
        for cut:=0;cut<len(bytes);cut+=max(1,len(bytes)/97) {
            p,error:=unreal.package_open(bytes[:cut],limits=LIMITS)
            if error.code!=.None {continue}
            for _,i in p.exports {
                if !animation_is(&p,i) {continue}
                a,_:=animation_read(&p,i)
                animation_destroy(&a)
            }
            unreal.package_destroy(&p)
        }
        changed:=make([]u8,len(bytes),context.temp_allocator)
        for at:=0;at<len(bytes);at+=max(1,len(bytes)/211) {
            copy(changed,bytes)
            changed[at]~=0xa5
            p,error:=unreal.package_open(changed,limits=LIMITS)
            if error.code!=.None {continue}
            for _,i in p.exports {
                if !animation_is(&p,i) {continue}
                a,_:=animation_read(&p,i)
                animation_destroy(&a)
            }
            unreal.package_destroy(&p)
        }
    }
}
