package cooked

import "core:encoding/json"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"

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

// Mirrors Mirai's anim.Animation_Event_Kind for clip markers and duration spans
// consumed by vfx_animation.Particle_Animation_Span and abilities.Ability_Window.span.
Cooked_Anim_Event_Kind :: enum u8 {
    Marker,
    Span_Begin,
    Span_End,
}

Cooked_Clip_Event :: struct {
    kind:Cooked_Anim_Event_Kind,
    name:string,
    time:f32, // seconds
    class:string,
    track:string,
}

// Paired start/end point markers (e.g. FortMeleeAnimTrails_On / _Off) mapped
// directly onto vfx_animation.Particle_Animation_Span (span + end_marker).
Cooked_Paired_Span :: struct {
    base_name:string,
    start_marker:string,
    end_marker:string,
    start_time:f32,
    end_time:f32,
}

// Emits native Mirai asset.Animation_Marker_Desc entries compatible with
// vfx_animation.Particle_Animation_Span and abilities.Ability_Window.span:
//   - point notifies & sync markers -> duration == 0 (.Marker)
//   - notify states & montage sections -> duration > 0 (.Span_Begin / .Span_End)
cooked_anim_markers :: proc(ev:^Cooked_Anim_Events,allocator:=context.allocator) -> []asset.Animation_Marker_Desc {
    out:=make([dynamic]asset.Animation_Marker_Desc,allocator)
    for n in ev.notifies {
        if n.name=="" {continue}
        append(&out,asset.Animation_Marker_Desc{
            time=n.time,
            name=strings.clone(n.name,allocator),
            duration=n.duration,
        })
    }
    for sm in ev.sync_markers {
        if sm.name=="" {continue}
        append(&out,asset.Animation_Marker_Desc{
            time=sm.time,
            name=strings.clone(sm.name,allocator),
            duration=0,
        })
    }
    for sec,i in ev.sections {
        if sec.name=="" {continue}
        end_t:=ev.length
        if i+1<len(ev.sections) && ev.sections[i+1].start>sec.start {
            end_t=ev.sections[i+1].start
        }
        dur:=end_t>sec.start ? end_t-sec.start : 0
        append(&out,asset.Animation_Marker_Desc{
            time=sec.start,
            name=strings.clone(sec.name,allocator),
            duration=dur,
        })
    }
    slice.sort_by(out[:],proc(a,b:asset.Animation_Marker_Desc) -> bool {
        if a.time!=b.time {return a.time<b.time}
        return a.name<b.name
    })
    return out[:]
}

// Expands cooked animation events into chronological .Marker / .Span_Begin / .Span_End
// events matching Mirai's Animation_Events stream.
cooked_anim_timeline_events :: proc(ev:^Cooked_Anim_Events,allocator:=context.allocator) -> []Cooked_Clip_Event {
    out:=make([dynamic]Cooked_Clip_Event,allocator)
    for n in ev.notifies {
        if n.name=="" {continue}
        if n.duration>0 {
            append(&out,Cooked_Clip_Event{
                kind=.Span_Begin,
                name=strings.clone(n.name,allocator),
                time=n.time,
                class=strings.clone(n.class,allocator),
                track=strings.clone(n.track,allocator),
            })
            append(&out,Cooked_Clip_Event{
                kind=.Span_End,
                name=strings.clone(n.name,allocator),
                time=n.time+n.duration,
                class=strings.clone(n.class,allocator),
                track=strings.clone(n.track,allocator),
            })
        } else {
            append(&out,Cooked_Clip_Event{
                kind=.Marker,
                name=strings.clone(n.name,allocator),
                time=n.time,
                class=strings.clone(n.class,allocator),
                track=strings.clone(n.track,allocator),
            })
        }
    }
    for sm in ev.sync_markers {
        if sm.name=="" {continue}
        append(&out,Cooked_Clip_Event{
            kind=.Marker,
            name=strings.clone(sm.name,allocator),
            time=sm.time,
            class=strings.clone("SyncMarker",allocator),
        })
    }
    slice.sort_by(out[:],proc(a,b:Cooked_Clip_Event) -> bool {
        if a.time!=b.time {return a.time<b.time}
        if a.kind!=b.kind {return a.kind<b.kind}
        return a.name<b.name
    })
    return out[:]
}

// Frees all allocations owned by a Cooked_Socket slice produced with `allocator`.
cooked_sockets_destroy :: proc(sockets:[]Cooked_Socket,allocator:=context.allocator) {
    for s in sockets {
        delete(s.name,allocator)
        delete(s.bone,allocator)
    }
    delete(sockets,allocator)
}

// Frees all allocations owned by a Cooked_Anim_Events produced with `allocator`.
cooked_anim_events_destroy :: proc(ev:^Cooked_Anim_Events,allocator:=context.allocator) {
    delete(ev.name,allocator)
    for n in ev.notifies {
        delete(n.name,allocator)
        delete(n.class,allocator)
        delete(n.track,allocator)
    }
    delete(ev.notifies,allocator)
    for sm in ev.sync_markers {delete(sm.name,allocator)}
    delete(ev.sync_markers,allocator)
    for sec in ev.sections {
        delete(sec.name,allocator)
        delete(sec.next,allocator)
    }
    delete(ev.sections,allocator)
    ev^={}
}

// Frees all allocations owned by a Animation_Marker_Desc slice produced by cooked_anim_markers.
cooked_anim_markers_destroy :: proc(markers:[]asset.Animation_Marker_Desc,allocator:=context.allocator) {
    for m in markers {delete(m.name,allocator)}
    delete(markers,allocator)
}

// Frees all allocations owned by a Cooked_Clip_Event slice produced by cooked_anim_timeline_events.
cooked_anim_timeline_events_destroy :: proc(events:[]Cooked_Clip_Event,allocator:=context.allocator) {
    for e in events {
        delete(e.name,allocator)
        delete(e.class,allocator)
        delete(e.track,allocator)
    }
    delete(events,allocator)
}

// Frees all allocations owned by a Cooked_Paired_Span slice produced by cooked_anim_paired_spans.
cooked_anim_paired_spans_destroy :: proc(spans:[]Cooked_Paired_Span,allocator:=context.allocator) {
    for s in spans {
        delete(s.base_name,allocator)
        delete(s.start_marker,allocator)
        delete(s.end_marker,allocator)
    }
    delete(spans,allocator)
}

// Detects paired start/end point markers (e.g. *_On / *_Off, *_Begin / *_End,
// *_Start / *_Stop) so callers can bind vfx_animation.Particle_Animation_Span
// (span = start_marker, end_marker = end_marker). Pairs each start marker with
// the nearest later unpaired matching end marker regardless of input order.
cooked_anim_paired_spans :: proc(ev:^Cooked_Anim_Events,allocator:=context.allocator) -> []Cooked_Paired_Span {
    PAIRS :: [3][2]string{{"_On","_Off"},{"_Begin","_End"},{"_Start","_Stop"}}
    // Sort candidate indices chronologically so earlier starts claim the nearest later end first.
    Entry :: struct {idx:int,time:f32}
    entries:=make([]Entry,len(ev.notifies),context.temp_allocator)
    for n,i in ev.notifies {entries[i]={i,n.time}}
    slice.sort_by(entries,proc(a,b:Entry) -> bool {
        if a.time!=b.time {return a.time<b.time}
        return a.idx<b.idx
    })
    used_end:=make([]bool,len(ev.notifies),context.temp_allocator)
    out:=make([dynamic]Cooked_Paired_Span,allocator)
    for ea in entries {
        i:=ea.idx
        a:=ev.notifies[i]
        if a.duration>0 || a.name=="" {continue}
        for pair in PAIRS {
            if !strings.has_suffix(a.name,pair[0]) {continue}
            base:=a.name[:len(a.name)-len(pair[0])]
            want_end:=strings.concatenate({base,pair[1]},context.temp_allocator)
            best_j:=-1
            best_time:f32=0
            for eb in entries {
                j:=eb.idx
                if j==i || used_end[j] {continue}
                b:=ev.notifies[j]
                if b.duration>0 || b.time<a.time || b.name!=want_end {continue}
                if best_j<0 || b.time<best_time {
                    best_j=j
                    best_time=b.time
                }
            }
            if best_j>=0 {
                used_end[best_j]=true
                b:=ev.notifies[best_j]
                append(&out,Cooked_Paired_Span{
                    base_name=strings.clone(base,allocator),
                    start_marker=strings.clone(a.name,allocator),
                    end_marker=strings.clone(b.name,allocator),
                    start_time=a.time,
                    end_time=b.time,
                })
            }
        }
    }
    return out[:]
}
