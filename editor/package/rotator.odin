package unreal

import "core:math"

// The rotation of a Rotator in Unreal's axes: degrees of pitch about Y, yaw about Z and roll about X.
rotator_quaternion :: proc "contextless" (pitch,yaw,roll:f64) -> quaternion256 {
    half:=math.PI/360
    sp,cp:=math.sincos(math.mod(pitch,360)*half)
    sy,cy:=math.sincos(math.mod(yaw,360)*half)
    sr,cr:=math.sincos(math.mod(roll,360)*half)
    return quaternion(w=cr*cp*cy+sr*sp*sy,x=cr*sp*sy-sr*cp*cy,y=-cr*sp*cy-sr*cp*sy,z=cr*cp*sy-sr*sp*cy)
}
