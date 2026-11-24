package cooked

import "core:encoding/json"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"

// Cooked -> Native Mirai Bridge: consumes `ue5parse` cooked JSON / IR outputs
// (materials, glTF mesh/rig sockets, animation notify/sync events) and converts
// them directly into native Mirai v6 assets and right-handed (+Y up, -Z forward,
// metres) engine data.

Error :: struct {
    what:string,
    detail:string,
}

// UE centimetres left-handed Z-up (+X forward, +Y right, +Z up) ->
// Mirai metres right-handed +Y up -Z forward (+X right, +Y up, -Z forward).
UNREAL_TO_MIRAI_SCALE :: f32(0.01)

unreal_position_to_mirai :: proc(p:[3]f32) -> [3]f32 {
    return {p.y*UNREAL_TO_MIRAI_SCALE,p.z*UNREAL_TO_MIRAI_SCALE,-p.x*UNREAL_TO_MIRAI_SCALE}
}

unreal_direction_to_mirai :: proc(v:[3]f32) -> [3]f32 {
    return {v.y,v.z,-v.x}
}

// Converts an Unreal scale (X forward, Y right, Z up) to Mirai (+X right, +Y up, -Z forward).
unreal_scale_to_mirai :: proc(s:[3]f32) -> [3]f32 {
    return {s.y,s.z,s.x}
}

// Converts an Unreal quaternion (X,Y,Z,W) in left-handed Z-up to a Mirai
// right-handed +Y up -Z forward quaternion.
unreal_quat_to_mirai :: proc(q:[4]f32) -> quaternion128 {
    // Similarity transform M = [0 1 0; 0 0 1; -1 0 0] (det = +1) maps axis (x,y,z) -> (y,z,-x);
    // handedness flip negates angle for left->right, giving (-qy, -qz, qx, qw) or axis map;
    // match mirai-unreal's scene/mesh convention: axis (y, z, -x) with negated handedness.
    m:=quaternion(x=-q.y,y=-q.z,z=q.x,w=q.w)
    return linalg.quaternion_normalize(m)
}

// Converts Unreal Euler degrees (Pitch=Y, Yaw=Z, Roll=X) to a Mirai quaternion.
unreal_rotator_to_mirai :: proc(pitch_deg,yaw_deg,roll_deg:f32) -> quaternion128 {
    deg:=f32(math.PI/180.0)
    // UE FRotator::Quaternion() convention (half angles):
    sp,cp:=math.sin(pitch_deg*deg*0.5),math.cos(pitch_deg*deg*0.5)
    sy,cy:=math.sin(yaw_deg*deg*0.5),math.cos(yaw_deg*deg*0.5)
    sr,cr:=math.sin(roll_deg*deg*0.5),math.cos(roll_deg*deg*0.5)
    qx:=cr*sp*sy-sr*cp*cy
    qy:=-cr*sp*cy-sr*cp*sy
    qz:=cr*cp*sy-sr*sp*cy
    qw:=cr*cp*cy+sr*sp*sy
    return unreal_quat_to_mirai({qx,qy,qz,qw})
}

// ---- JSON helpers (safe on hostile / partial inputs) --------------------------------

@(private)
json_obj :: proc(v:json.Value) -> (json.Object,bool) {
    if obj,ok:=v.(json.Object);ok {return obj,true}
    return nil,false
}

@(private)
json_arr :: proc(v:json.Value) -> (json.Array,bool) {
    if arr,ok:=v.(json.Array);ok {return arr,true}
    return nil,false
}

@(private)
json_get :: proc(v:json.Value,key:string) -> (json.Value,bool) {
    obj,ok:=v.(json.Object)
    if !ok {return nil,false}
    val,found:=obj[key]
    return val,found
}

@(private)
json_str :: proc(v:json.Value,fallback:="") -> string {
    if s,ok:=v.(json.String);ok {return s}
    return fallback
}

@(private)
json_bool :: proc(v:json.Value,fallback:=false) -> bool {
    if b,ok:=v.(json.Boolean);ok {return b}
    if n,ok:=json_f32(v);ok {return n!=0}
    return fallback
}

@(private)
json_f32 :: proc(v:json.Value,fallback:f32=0) -> (f32,bool) {
    #partial switch x in v {
    case json.Float:
        if math.is_nan(x) || math.is_inf(x) {return fallback,false}
        return f32(x),true
    case json.Integer:
        return f32(x),true
    }
    return fallback,false
}

@(private)
json_vec3 :: proc(v:json.Value,fallback:[3]f32={}) -> ([3]f32,bool) {
    if arr,ok:=v.(json.Array);ok && len(arr)>=3 {
        x,_:=json_f32(arr[0],fallback.x)
        y,_:=json_f32(arr[1],fallback.y)
        z,_:=json_f32(arr[2],fallback.z)
        return {x,y,z},true
    }
    if obj,ok:=v.(json.Object);ok {
        out:=fallback
        found:=false
        if a,ok0:=obj["X"];ok0 {out.x,_=json_f32(a,fallback.x);found=true}
        if a,ok0:=obj["x"];ok0 {out.x,_=json_f32(a,fallback.x);found=true}
        if a,ok0:=obj["Y"];ok0 {out.y,_=json_f32(a,fallback.y);found=true}
        if a,ok0:=obj["y"];ok0 {out.y,_=json_f32(a,fallback.y);found=true}
        if a,ok0:=obj["Z"];ok0 {out.z,_=json_f32(a,fallback.z);found=true}
        if a,ok0:=obj["z"];ok0 {out.z,_=json_f32(a,fallback.z);found=true}
        return out,found
    }
    return fallback,false
}

@(private)
json_vec4 :: proc(v:json.Value,fallback:[4]f32={0,0,0,1}) -> ([4]f32,bool) {
    if arr,ok:=v.(json.Array);ok && len(arr)>=3 {
        x,_:=json_f32(arr[0],fallback.x)
        y,_:=json_f32(arr[1],fallback.y)
        z,_:=json_f32(arr[2],fallback.z)
        w:=fallback.w
        if len(arr)>=4 {w,_=json_f32(arr[3],fallback.w)}
        return {x,y,z,w},true
    }
    if obj,ok:=v.(json.Object);ok {
        out:=fallback
        found:=false
        for k,idx in ([4][2]string{{"R","X"},{"G","Y"},{"B","Z"},{"A","W"}}) {
            if a,ok0:=obj[k[0]];ok0 {out[idx],_=json_f32(a,fallback[idx]);found=true}
            if a,ok0:=obj[k[1]];ok0 {out[idx],_=json_f32(a,fallback[idx]);found=true}
            if a,ok0:=obj[strings.to_lower(k[0],context.temp_allocator)];ok0 {out[idx],_=json_f32(a,fallback[idx]);found=true}
            if a,ok0:=obj[strings.to_lower(k[1],context.temp_allocator)];ok0 {out[idx],_=json_f32(a,fallback[idx]);found=true}
        }
        return out,found
    }
    return fallback,false
}

@(private)
parse_json :: proc(text:string,allocator:mem.Allocator) -> (json.Value,Maybe(Error)) {
    if len(text)==0 {return nil,Error{"json","empty input"}}
    v,err:=json.parse_string(text,allocator=allocator)
    if err!=.None {return nil,Error{"json","malformed JSON"}}
    return v,nil
}
