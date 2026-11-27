package unreal_vfx_editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"

// A Mirai Vfx resource a generated program declares (`//! resource <name> <kind>`),
// which the emitter binds via Particle_Binding.
Cooked_Vfx_Resource :: struct {
    name:string, // Mirai resource name (e.g. "skeleton", "skeleton_transform")
    kind:string, // Mirai resource kind ("bones", "transform")
}

// One bone of a target Mirai skeleton, in the index order of its `bones` resource.
Cooked_Bone :: struct {
    name:string,
    index:int,
}

// One socket on a target Mirai skeleton, relative to its parent bone in Mirai axes and metres.
// `rotation` is the xyzw unit quaternion taking the Mirai bone frame to the Unreal-axes-as-Mirai
// socket frame (i.e. rig_turn * unreal_rotator_to_mirai(socket_rot)).
Cooked_Socket :: struct {
    name:string,
    bone:int,
    position:[3]f32,
    rotation:[4]f32,
    scale:[3]f32,
}

// Target Mirai skeleton metadata for resolving NiagaraDataInterfaceSkeletalMesh bone and socket
// queries against live Mirai `bones` and `transform` VFX resources.
Cooked_Skeleton :: struct {
    bones:[]Cooked_Bone,
    sockets:[]Cooked_Socket,
    // xyzw unit quaternion taking a Mirai bone frame to Unreal-axes-as-Mirai (rig_turn;
    // zero defaults to identity {0, 0, 0, 1}).
    bone_turn:[4]f32,
}

@(private)
Skel_Di :: struct {
    di_name:string,
    id:int,
    filtered_bones:[dynamic]int,
    unfiltered_bones:[dynamic]int,
    filtered_sockets:[dynamic]Cooked_Socket,
    exclude_bone:int,
    num_bones:int,
    needs_transform:bool,
    needs_unfiltered:bool,
    needs_sockets:bool,
}

@(private)
resource_need :: proc(t:^Translation,name,kind:string) {
    for r in t.resources {
        if r.name==name {return}
    }
    append(&t.resources,Cooked_Vfx_Resource{name,kind})
}

@(private="file")
skel_norm_quat :: proc(q:[4]f32) -> [4]f32 {
    l:=math.sqrt(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w)
    if l<=1e-12 {return {0,0,0,1}}
    return {q.x/l,q.y/l,q.z/l,q.w/l}
}

@(private="file")
skel_bone_turn :: proc(sk:Cooked_Skeleton) -> [4]f32 {
    return skel_norm_quat(sk.bone_turn)
}

@(private="file")
skel_find_bone :: proc(sk:Cooked_Skeleton,name:string) -> (int,bool) {
    for b in sk.bones {
        if strings.equal_fold(b.name,name) {return b.index,true}
    }
    return 0,false
}

@(private="file")
skel_find_socket :: proc(sk:Cooked_Skeleton,name:string) -> (Cooked_Socket,bool) {
    for s in sk.sockets {
        if strings.equal_fold(s.name,name) {
            out:=s
            out.rotation=skel_norm_quat(out.rotation)
            if out.scale=={} {out.scale={1,1,1}}
            return out,true
        }
    }
    if idx,ok:=skel_find_bone(sk,name);ok {
        return Cooked_Socket{name=name,bone=idx,rotation=skel_bone_turn(sk),scale={1,1,1}},true
    }
    return {},false
}

// Ensures a NiagaraDataInterfaceSkeletalMesh has resolved bone/socket tables and registers the
// Mirai `bones` (and optionally `transform`) resource declarations.
@(private)
skel_di_prepare :: proc(t:^Translation,di:^Interface,need_transform:bool,need_unfiltered:=false,need_sockets:=false) -> ^Skel_Di {
    resource_need(t,"skeleton","bones")
    if need_transform {resource_need(t,"skeleton_transform","transform")}
    for &sd in t.skel_dis {
        if sd.di_name==di.name {
            if need_transform {sd.needs_transform=true}
            if need_unfiltered {sd.needs_unfiltered=true}
            if need_sockets {sd.needs_sockets=true}
            return &sd
        }
    }
    sk:=t.skeleton
    props,_:=di.object["Properties"].(json.Object)
    sd:=Skel_Di{
        di_name=di.name,
        id=len(t.skel_dis),
        filtered_bones=make([dynamic]int,context.temp_allocator),
        unfiltered_bones=make([dynamic]int,context.temp_allocator),
        filtered_sockets=make([dynamic]Cooked_Socket,context.temp_allocator),
        exclude_bone=-1,
        num_bones=len(sk.bones),
        needs_transform=need_transform,
        needs_unfiltered=need_unfiltered,
        needs_sockets=need_sockets,
    }
    if jbool(props["bExcludeBone"],false) {
        if ex:=jstr(props["ExcludeBoneName"]);ex!="" {
            if idx,ok:=skel_find_bone(sk,ex);ok {sd.exclude_bone=idx}
        }
    }
    fb_set:=make(map[int]bool,allocator=context.temp_allocator)
    if arr,ok:=props["FilteredBones"].(json.Array);ok {
        for item in arr {
            bname:=jstr(item)
            if idx,found:=skel_find_bone(sk,bname);found {
                append(&sd.filtered_bones,idx)
                fb_set[idx]=true
            } else {
                append(&sd.filtered_bones,0)
            }
        }
    }
    for b in sk.bones {
        if b.index==sd.exclude_bone || fb_set[b.index] {continue}
        append(&sd.unfiltered_bones,b.index)
    }
    if arr,ok:=props["FilteredSockets"].(json.Array);ok {
        for item in arr {
            sname:=jstr(item)
            if sock,found:=skel_find_socket(sk,sname);found {
                append(&sd.filtered_sockets,sock)
            } else {
                append(&sd.filtered_sockets,Cooked_Socket{name=sname,bone=0,rotation=skel_bone_turn(sk),scale={1,1,1}})
            }
        }
    }
    append(&t.skel_dis,sd)
    return &t.skel_dis[len(t.skel_dis)-1]
}

// Emits Slang helpers and lookup tables for every SkeletalMesh data interface used by the program.
@(private)
skel_emit_code :: proc(t:^Translation,w:^strings.Builder) {
    if len(t.skel_dis)==0 {return}
    bt:=skel_bone_turn(t.skeleton)
    any_transform:=false
    for sd in t.skel_dis {any_transform||=sd.needs_transform}

    fmt.sbprintf(w,"static const float4 NV_SKEL_BONE_TURN = float4(%s, %s, %s, %s);\n",
        slang_f32(bt.x),slang_f32(bt.y),slang_f32(bt.z),slang_f32(bt.w))
    strings.write_string(w,`void nv_skel_bone_mirai(Mirai_Vfx_Context ctx, Nv e, int bone_idx, out float3 pos, out float4 rot, out float3 scl, out float3 vel, out int parent) {
    Mirai_Vfx_Bone b = mirai_vfx_bone(ctx, skeleton, uint(max(bone_idx, 0)));
    if (b.valid) {
        pos = b.position;
        rot = nv_qmul(b.rotation, NV_SKEL_BONE_TURN);
        scl = b.scale;
        vel = b.velocity;
        parent = b.parent == 0xFFFFFFFFu ? -1 : int(b.parent);
    } else {
        pos = ctx.origin;
        rot = nv_emitter_turn(ctx);
        scl = float3(e.scale.y, e.scale.z, e.scale.x);
        vel = nv_mirai(e.velocity) * 0.01;
        parent = -1;
    }
}
`)
    if any_transform {
        strings.write_string(w,`void nv_trs_rows(float3 pos, float4 rot, float3 scl, out float4 r0, out float4 r1, out float4 r2, out float4 r3) {
    r0 = float4(nv_qrot(rot, float3(scl.x, 0.0, 0.0)), 0.0);
    r1 = float4(nv_qrot(rot, float3(0.0, scl.y, 0.0)), 0.0);
    r2 = float4(nv_qrot(rot, float3(0.0, 0.0, scl.z)), 0.0);
    r3 = float4(pos, 1.0);
}
`)
    }

    for sd in t.skel_dis {
        id:=sd.id
        nfb:=len(sd.filtered_bones)
        nub:=len(sd.unfiltered_bones)
        nfs:=sd.needs_sockets ? len(sd.filtered_sockets) : 0
        nb:=max(sd.num_bones,1)

        if nfb>0 {
            fmt.sbprintf(w,"static const int NV_SKEL_FB_%d[%d] = {{",id,nfb)
            for b,i in sd.filtered_bones {
                if i>0 {strings.write_string(w,", ")}
                fmt.sbprintf(w,"%d",b)
            }
            strings.write_string(w,"};\n")
        }

        if sd.needs_unfiltered&&nub>0 {
            fmt.sbprintf(w,"static const int NV_SKEL_UB_%d[%d] = {{",id,nub)
            for b,i in sd.unfiltered_bones {
                if i>0 {strings.write_string(w,", ")}
                if i%32==0&&i>0 {strings.write_string(w,"\n    ")}
                fmt.sbprintf(w,"%d",b)
            }
            strings.write_string(w,"};\n")
        }

        fmt.sbprintf(w,"int nv_skel_filtered_index_%d(int i) {{\n",id)
        if nfb>0 {
            if sd.needs_unfiltered&&nub>0 {
                fmt.sbprintf(w,"    if (i < %d) return NV_SKEL_FB_%d[clamp(i, 0, %d)];\n",nfb,id,nfb-1)
                fmt.sbprintf(w,"    return NV_SKEL_UB_%d[clamp(i - %d, 0, %d)];\n",id,nfb,nub-1)
            } else {
                fmt.sbprintf(w,"    return NV_SKEL_FB_%d[clamp(i, 0, %d)];\n",id,nfb-1)
            }
        } else if sd.needs_unfiltered&&nub>0 {
            fmt.sbprintf(w,"    return NV_SKEL_UB_%d[clamp(i, 0, %d)];\n",id,nub-1)
        } else {
            fmt.sbprintf(w,"    return clamp(i, 0, %d);\n",nb-1)
        }
        strings.write_string(w,"}\n")

        if nfs>0 {
            fmt.sbprintf(w,"static const int NV_SKEL_FS_BONE_%d[%d] = {{",id,nfs)
            for s,i in sd.filtered_sockets {
                if i>0 {strings.write_string(w,", ")}
                fmt.sbprintf(w,"%d",s.bone)
            }
            strings.write_string(w,"};\n")
            fmt.sbprintf(w,"static const float3 NV_SKEL_FS_POS_%d[%d] = {{",id,nfs)
            for s,i in sd.filtered_sockets {
                if i>0 {strings.write_string(w,", ")}
                fmt.sbprintf(w,"float3(%s, %s, %s)",slang_f32(s.position.x),slang_f32(s.position.y),slang_f32(s.position.z))
            }
            strings.write_string(w,"};\n")
            fmt.sbprintf(w,"static const float4 NV_SKEL_FS_ROT_%d[%d] = {{",id,nfs)
            for s,i in sd.filtered_sockets {
                if i>0 {strings.write_string(w,", ")}
                fmt.sbprintf(w,"float4(%s, %s, %s, %s)",slang_f32(s.rotation.x),slang_f32(s.rotation.y),slang_f32(s.rotation.z),slang_f32(s.rotation.w))
            }
            strings.write_string(w,"};\n")
            fmt.sbprintf(w,"static const float3 NV_SKEL_FS_SCL_%d[%d] = {{",id,nfs)
            for s,i in sd.filtered_sockets {
                if i>0 {strings.write_string(w,", ")}
                fmt.sbprintf(w,"float3(%s, %s, %s)",slang_f32(s.scale.x),slang_f32(s.scale.y),slang_f32(s.scale.z))
            }
            strings.write_string(w,"};\n")
        }

        fmt.sbprintf(w,"void nv_skel_world_%d(Mirai_Vfx_Context ctx, Nv e, int bone_id, out float3 pos_m, out float4 rot_m, out float3 scl_m, out float3 vel_m, out int parent) {{\n",id)
        if nfs>0 {
            fmt.sbprintf(w,`    if (bone_id >= %d) {{
        int si = clamp(bone_id - %d, 0, %d);
        int bi = NV_SKEL_FS_BONE_%d[si];
        Mirai_Vfx_Bone b = mirai_vfx_bone(ctx, skeleton, uint(max(bi, 0)));
        if (b.valid) {{
            pos_m = b.position + nv_qrot(b.rotation, NV_SKEL_FS_POS_%d[si] * b.scale);
            rot_m = nv_qmul(b.rotation, NV_SKEL_FS_ROT_%d[si]);
            scl_m = b.scale * NV_SKEL_FS_SCL_%d[si];
            vel_m = b.velocity;
            parent = bi;
            return;
        }}
    }}
`,sd.num_bones,sd.num_bones,nfs-1,id,id,id,id)
        }
        fmt.sbprintf(w,"    nv_skel_bone_mirai(ctx, e, clamp(bone_id, 0, %d), pos_m, rot_m, scl_m, vel_m, parent);\n}}\n",nb-1)

        fmt.sbprintf(w,`void nv_skel_sample_%d(Mirai_Vfx_Context ctx, Nv e, int bone_id, float interp, bool ws, out float3 pos_ue, out float4 rot_ue, out float3 scl_ue, out float3 vel_ue) {{
    float3 wpos, wscl, wvel; float4 wrot; int parent;
    nv_skel_world_%d(ctx, e, bone_id, wpos, wrot, wscl, wvel, parent);
    float u = saturate(interp);
    float3 p_m = lerp(wpos - wvel * e.dt, wpos, u);
`,id,id)
        if sd.needs_transform {
            strings.write_string(w,`    if (!ws) {
        Mirai_Vfx_Transform tr = mirai_vfx_transform_at(ctx, skeleton_transform, u);
        float3 ipos = tr.valid ? tr.position : lerp(nv_mirai(e.prev_owner) * 0.01, ctx.origin, u);
        float4 irot = tr.valid ? tr.rotation : nv_emitter_turn(ctx);
        float3 iscl = tr.valid ? tr.scale : float3(e.scale.y, e.scale.z, e.scale.x);
        float4 inv_q = nv_qconj(irot);
        float3 inv_s = float3(1.0) / max(abs(iscl), float3(1e-6));
        pos_ue = nv_unreal(nv_qrot(inv_q, p_m - ipos) * inv_s) * 100.0;
        rot_ue = nv_turn_back(nv_qmul(inv_q, wrot));
        scl_ue = nv_scale_unreal(wscl * inv_s);
        vel_ue = nv_unreal(nv_qrot(inv_q, wvel) * inv_s) * 100.0;
        return;
    }
`)
        }
        strings.write_string(w,`    pos_ue = nv_unreal(p_m) * 100.0;
    rot_ue = nv_turn_back(wrot);
    scl_ue = nv_scale_unreal(wscl);
    vel_ue = nv_unreal(wvel) * 100.0;
}
`)
        if sd.needs_transform {
            fmt.sbprintf(w,`float4 nv_skel_gpu_bone_%d(Mirai_Vfx_Context ctx, Nv e, int slot, bool prev, float3 ipos, float4 inv_q, float3 inv_s) {{
    int bone_id = max(slot, 0) / 3;
    int comp = max(slot, 0) %% 3;
    float3 wpos, wscl, wvel; float4 wrot; int parent;
    nv_skel_world_%d(ctx, e, bone_id, wpos, wrot, wscl, wvel, parent);
    float3 p_m = prev ? (wpos - wvel * e.dt) : wpos;
    if (comp == 0) return float4(nv_unreal(nv_qrot(inv_q, p_m - ipos) * inv_s) * 100.0, 0.0);
    if (comp == 1) return nv_turn_back(nv_qmul(inv_q, wrot));
    return float4(nv_scale_unreal(wscl * inv_s), asfloat(parent));
}}
`,id,id)
        }
    }
}
