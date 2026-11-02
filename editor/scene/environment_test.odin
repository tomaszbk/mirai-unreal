package unreal_scene

import "core:testing"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

// A post process volume of Unreal is whole inside its brush and fades out
// over its blend radius beyond it; the volume it becomes keeps both borders,
// whatever the scale of the actor.
@(test)
a_post_process_volume_blends_beyond_its_brush_as_in_unreal :: proc(t:^testing.T) {
    pose:=mm.Transform{position={0,0,0},rotation=1,scale={2,1,1}}
    place:=volume.Volume{shape=.Box,extents={1,3,3},blend=1}
    place.extents=blend_beyond(place.extents,place.blend,pose.scale)
    testing.expect_value(t,volume.weight(place,pose,{2,0,0}),f32(1))
    testing.expect_value(t,volume.weight(place,pose,{2.5,0,0}),f32(0.5))
    testing.expect_value(t,volume.weight(place,pose,{3,0,0}),f32(0))
    testing.expect_value(t,volume.weight(place,pose,{0,3,0}),f32(1))
    testing.expect_value(t,volume.weight(place,pose,{0,4,0}),f32(0))
}
