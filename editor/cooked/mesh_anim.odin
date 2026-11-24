package cooked

import "core:encoding/json"
import "core:math/linalg"
import "core:mem"
import "core:strings"

// Converts `ue5parse` cooked mesh/rig sockets (from glTF `extras.socket` /
// node extras or socket JSON) and cooked animation events (`ue5parse events`
// JSON: Notifies, NotifyStates, SyncMarkers, Sections) into Mirai-ready
// right-handed (+Y up, -Z forward, metres) structures.

Cooked_Socket :: struct {
    name:string,
    bone:string,
    position:[3]f32, // Mirai metres, +Y up, -Z forward
    rotation:quaternion128,
    scale:[3]f32,
}

Cooked_Anim_Notify :: struct {
    name:string,
    class:string,
    time:f32,     // seconds
    duration:f32, // 0 for point notifies, >0 for AnimNotifyState spans
    track:string,
}

Cooked_Anim_Sync :: struct {
    name:string,
    time:f32, // seconds
}

Cooked_Anim_Section :: struct {
    name:string,
    start:f32, // seconds
    next:string,
}

Cooked_Anim_Events :: struct {
    name:string,
    length:f32,     // seconds
    rate_scale:f32,
    notifies:[]Cooked_Anim_Notify,
    sync_markers:[]Cooked_Anim_Sync,
    sections:[]Cooked_Anim_Section,
}

// Parses sockets from either a glTF JSON document (reading `nodes[].extras.socket`
// or `nodes[].extras.unreal_socket`, already in glTF metres or UE cm) OR a
// standalone JSON array/object of Unreal sockets (`Name`, `BoneName`,
// `RelativeLocation`, `RelativeRotation`, `RelativeScale`).
cooked_sockets_parse :: proc(json_text:string,allocator:=context.allocator) -> (sockets:[]Cooked_Socket,err:Maybe(Error)) {
    root,perr:=parse_json(json_text,context.temp_allocator)
    if perr!=nil {return nil,perr}
    out:=make([dynamic]Cooked_Socket,allocator)

    // Form 1: glTF JSON with nodes[].
    if obj,ok:=json_obj(root);ok {
        if nodes,has_nodes:=json_arr(obj["nodes"]);has_nodes {
            // Map node index -> parent node name for bone resolution.
            parent_of:=make([]int,len(nodes),context.temp_allocator)
            for &p in parent_of {p=-1}
            for n,i in nodes {
                if nobj,nok:=json_obj(n);nok {
                    if children,has_c:=json_arr(nobj["children"]);has_c {
                        for ch in children {
                            if idx,iok:=json_f32(ch,-1);iok && int(idx)>=0 && int(idx)<len(nodes) {
                                parent_of[int(idx)]=i
                            }
                        }
                    }
                }
            }
            for n,i in nodes {
                nobj,nok:=json_obj(n)
                if !nok {continue}
                extras,has_ex:=json_obj(nobj["extras"])
                if !has_ex {continue}
                is_sock:=json_bool(extras["socket"],false) || json_bool(extras["unreal_socket"],false) || json_str(extras["SocketName"])!=""
                if !is_sock {continue}
                sock:=Cooked_Socket{
                    name=strings.clone(json_str(extras["SocketName"],json_str(nobj["name"])),allocator),
                    bone=strings.clone(json_str(extras["BoneName"],json_str(extras["bone"])),allocator),
                    rotation=quaternion128(1),
                    scale={1,1,1},
                }
                if sock.bone=="" && parent_of[i]>=0 {
                    if pobj,pok:=json_obj(nodes[parent_of[i]]);pok {
                        sock.bone=strings.clone(json_str(pobj["name"]),allocator)
                    }
                }
                // glTF node transforms are already right-handed +Y up metres.
                if t,has_t:=json_vec3(nobj["translation"]);has_t {sock.position=t}
                if r,has_r:=json_vec4(nobj["rotation"],{0,0,0,1});has_r {
                    sock.rotation=linalg.quaternion_normalize(quaternion(x=r.x,y=r.y,z=r.z,w=r.w))
                }
                if s,has_s:=json_vec3(nobj["scale"],{1,1,1});has_s {sock.scale=s}
                append(&out,sock)
            }
            return out[:],nil
        }
        if arr,has_socks:=json_arr(obj["Sockets"]);has_socks {
            parse_ue_socket_array(arr,&out,allocator)
            return out[:],nil
        }
    }
    // Form 2: direct JSON array of UE sockets.
    if arr,ok:=json_arr(root);ok {
        parse_ue_socket_array(arr,&out,allocator)
        return out[:],nil
    }
    return out[:],nil
}

@(private="file")
parse_ue_socket_array :: proc(arr:json.Array,out:^[dynamic]Cooked_Socket,allocator:mem.Allocator) {
    for item in arr {
        obj,ok:=json_obj(item)
        if !ok {continue}
        name:=json_str(obj["SocketName"],json_str(obj["Name"]))
        if name=="" {continue}
        bone:=json_str(obj["BoneName"],json_str(obj["Bone"]))
        loc,_:=json_vec3(obj["RelativeLocation"],{})
        scl,_:=json_vec3(obj["RelativeScale"],{1,1,1})
        rot:=quaternion128(1)
        if r_obj,has_r:=json_obj(obj["RelativeRotation"]);has_r {
            if _,has_w:=r_obj["W"];has_w {
                q,_:=json_vec4(obj["RelativeRotation"],{0,0,0,1})
                rot=unreal_quat_to_mirai(q)
            } else {
                pitch,_:=json_f32(r_obj["Pitch"],0)
                yaw,_:=json_f32(r_obj["Yaw"],0)
                roll,_:=json_f32(r_obj["Roll"],0)
                rot=unreal_rotator_to_mirai(pitch,yaw,roll)
            }
        }
        append(out,Cooked_Socket{
            name=strings.clone(name,allocator),
            bone=strings.clone(bone,allocator),
            position=unreal_position_to_mirai(loc),
            rotation=rot,
            scale=unreal_scale_to_mirai(scl),
        })
    }
}

// Parses `ue5parse events` JSON (Notifies, NotifyStates, SyncMarkers, Sections).
cooked_anim_events_parse :: proc(json_text:string,allocator:=context.allocator) -> (ev:Cooked_Anim_Events,err:Maybe(Error)) {
    root,perr:=parse_json(json_text,context.temp_allocator)
    if perr!=nil {return {},perr}
    obj,ok:=json_obj(root)
    if !ok {return {},Error{"anim_events","root JSON value must be an object"}}

    ev.name=strings.clone(json_str(obj["Name"]),allocator)
    ev.length,_=json_f32(obj["SequenceLength"],0)
    if ev.length==0 {ev.length,_=json_f32(obj["Length"],0)}
    ev.rate_scale,_=json_f32(obj["RateScale"],1)

    notifies:=make([dynamic]Cooked_Anim_Notify,allocator)
    if arr,has:=json_arr(obj["Notifies"]);has {
        for item in arr {
            nobj,nok:=json_obj(item)
            if !nok {continue}
            t,_:=json_f32(nobj["Time"],0)
            if t==0 {t,_=json_f32(nobj["TriggerTime"],0)}
            dur,_:=json_f32(nobj["Duration"],0)
            append(&notifies,Cooked_Anim_Notify{
                name=strings.clone(json_str(nobj["Name"],json_str(nobj["NotifyName"])),allocator),
                class=strings.clone(json_str(nobj["Class"],json_str(nobj["Type"])),allocator),
                time=max(t,0),
                duration=max(dur,0),
                track=strings.clone(json_str(nobj["Track"]),allocator),
            })
        }
    }
    if arr,has:=json_arr(obj["NotifyStates"]);has {
        for item in arr {
            nobj,nok:=json_obj(item)
            if !nok {continue}
            t,_:=json_f32(nobj["Start"],0)
            if t==0 {t,_=json_f32(nobj["Time"],0)}
            dur,_:=json_f32(nobj["Duration"],0)
            if dur==0 {
                if end,has_end:=json_f32(nobj["End"],0);has_end && end>t {dur=end-t}
            }
            append(&notifies,Cooked_Anim_Notify{
                name=strings.clone(json_str(nobj["Name"],json_str(nobj["NotifyName"])),allocator),
                class=strings.clone(json_str(nobj["Class"],json_str(nobj["Type"])),allocator),
                time=max(t,0),
                duration=max(dur,0),
                track=strings.clone(json_str(nobj["Track"]),allocator),
            })
        }
    }

    syncs:=make([dynamic]Cooked_Anim_Sync,allocator)
    if arr,has:=json_arr(obj["SyncMarkers"]);has {
        for item in arr {
            sobj,sok:=json_obj(item)
            if !sok {continue}
            t,_:=json_f32(sobj["Time"],0)
            append(&syncs,Cooked_Anim_Sync{
                name=strings.clone(json_str(sobj["Name"],json_str(sobj["MarkerName"])),allocator),
                time=max(t,0),
            })
        }
    }

    sections:=make([dynamic]Cooked_Anim_Section,allocator)
    if arr,has:=json_arr(obj["Sections"]);has {
        for item in arr {
            sobj,sok:=json_obj(item)
            if !sok {continue}
            t,_:=json_f32(sobj["Start"],0)
            if t==0 {t,_=json_f32(sobj["Time"],0)}
            append(&sections,Cooked_Anim_Section{
                name=strings.clone(json_str(sobj["Name"],json_str(sobj["SectionName"])),allocator),
                start=max(t,0),
                next=strings.clone(json_str(sobj["NextSectionName"],json_str(sobj["Next"])),allocator),
            })
        }
    }

    ev.notifies=notifies[:]
    ev.sync_markers=syncs[:]
    ev.sections=sections[:]
    return ev,nil
}
