package level

import "core:encoding/endian"
import "core:math/linalg"
import "core:testing"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

// The matrix of Unreal's transform of Rotation, Location and Scale, scale included: row vectors.
@(private="file")
instance_matrix :: proc(location,rotation,scale:[3]f64) -> (m:[4][4]f64) {
    turn:=linalg.matrix3_from_quaternion(unreal.rotator_quaternion(rotation.x,rotation.y,rotation.z))
    for row in 0..<3 {for column in 0..<3 {m[row][column]=turn[column,row]*scale[row]}}
    m[3]={location.x,location.y,location.z,1}
    return
}

@(private="file")
same_points :: proc(a,b:mm.Transform) -> bool {
    for p in ([4][3]f32{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}) {
        if linalg.length(mm.transform_point(a,p)-mm.transform_point(b,p))>1e-4 {return false}
    }
    return true
}

@(test)
instance_matrices_are_the_transforms_their_parts_give :: proc(t:^testing.T) {
    cases:=[?][3][3]f64{
        {{120,-40,15},{10,30,-20},{2,3,0.5}},
        {{0,0,0},{0,90,0},{1,1,1}},
        {{-300,25,0},{-45,0,170},{-1,1,1}}, // mirrored in X
    }
    for c in cases {
        from_matrix,error:=matrix_to_mirai(instance_matrix(c[0],c[1],c[2]))
        if !testing.expect_value(t,error.code,unreal.Error_Code.None) {continue}
        from_parts,_:=transform_to_mirai(c[0],c[1],c[2])
        testing.expectf(t,same_points(from_matrix,from_parts),"%v: %v against %v",c,from_matrix,from_parts)
    }
    _,error:=matrix_to_mirai(instance_matrix({0,0,0},{0,0,0},{1,0,1}))
    testing.expect(t,error.code!=.None,"an axis of zero has no rotation")
}

@(test)
per_instance_data_is_found_after_what_the_component_keeps_before_it :: proc(t:^testing.T) {
    word :: proc(bytes:^[dynamic]u8,value:u32) {
        b:[4]u8
        endian.put_u32(b[:],.Little,value)
        append(bytes,..b[:])
    }
    // Nothing before the array, the two flags, and what a static mesh component keeps before them.
    prefixes:=[?][]u8{{},{0,0,0,0,1,0,0,0},{0,0,0,0,1,0,0,0,0,0,9,131,196,89,57,69,116,76,184,13,100,93,149,91,234,1,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0}}
    for prefix in prefixes {
        for wide in ([2]bool{false,true}) {
            bytes:[dynamic]u8
            defer delete(bytes)
            append(&bytes,..prefix)
            word(&bytes,wide?128:64)
            word(&bytes,2)
            for i in 0..<2 {
                m:=instance_matrix({f64(i)*100,20,-30},{0,f64(i)*90,0},{1,2,1})
                for row in 0..<4 {
                    for column in 0..<4 {
                        b:[8]u8
                        if wide {endian.put_f64(b[:],.Little,m[row][column]);append(&bytes,..b[:])} else {endian.put_f32(b[:4],.Little,f32(m[row][column]));append(&bytes,..b[:4])}
                    }
                }
            }
            // Three custom floats for each instance.
            word(&bytes,4)
            word(&bytes,6)
            for value in ([6]f32{0.1,0.2,0.3,0.4,0.5,0.6}) {
                b:[4]u8
                endian.put_f32(b[:],.Little,value)
                append(&bytes,..b[:])
            }
            instances:=instances_read(bytes[:],context.temp_allocator)
            matrices:=instances.matrices
            if !testing.expectf(t,len(matrices)==2,"%d bytes before, wide %v: %d instances",len(prefix),wide,len(matrices)) {continue}
            testing.expect(t,abs(matrices[1][3][0]-100)<1e-4,"the place of the second")
            testing.expect(t,abs(matrices[0][1][1]-2)<1e-4,"the scale of the first")
            testing.expect_value(t,instances.per_instance,3)
            testing.expect_value(t,instance_custom(instances,1)[2],f32(0.6))
        }
    }
    testing.expect_value(t,len(instances_read([]u8{64,0,0,0,9,0,0,0},context.temp_allocator).matrices),0)
}
