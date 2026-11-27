package unreal_vfx_editor

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import shaders "mirai:cook/shaders"

// A GPU emitter as `ue5parse niagara --dxc` describes it: its particle attributes with the
// registers they live at, an emitter script that gives a burst, and the simulation shader of
// its compute script, a function that reads its thread, the instance count, constant buffer
// words, the particle, a colour of an array, a curve of the static buffer and a vector field,
// and writes the particle back.
@(private="file")
GPU_SYSTEM :: `{
  "Schema": "ue5parse.niagara/2",
  "Name": "NS_Gpu",
  "UserParameters": [{"Name": "User.Variant", "Type": "NiagaraInt32", "Value": 1}],
  "Emitters": [{
    "Name": "Sparks",
    "Target": "GPU",
    "Settings": {"bLocalSpace": false, "RandomSeed": 3},
    "Attributes": [
      {"Name": "Age", "Type": "NiagaraFloat", "Float": [0, 1]},
      {"Name": "Color", "Type": "LinearColor", "Float": [1, 4]},
      {"Name": "Position", "Type": "NiagaraPosition", "Float": [5, 3]},
      {"Name": "SpriteSize", "Type": "Vector2f", "Float": [8, 2]},
      {"Name": "UniqueID", "Type": "NiagaraInt32", "Int32": [0, 1]}
    ],
    "EmitterScripts": [{"Usage": "EmitterUpdateScript", "Modules": [], "Outputs": [
        {"Attribute": "Sparks.Age", "Value": {"Op": "add", "Args": [{"Attribute": "Sparks.Age", "DataSet": 0}, {"Parameter": "Engine.DeltaTime", "Source": "Engine"}]}},
        {"Attribute": "Sparks.Burst.Count", "Value": {"Literal": 8, "Type": "int"}},
        {"Attribute": "Sparks.Burst.InterpStartDt", "Value": {"Literal": 0.0, "Type": "float"}},
        {"Attribute": "Sparks.Burst.IntervalDt", "Value": {"Literal": 0.0, "Type": "float"}},
        {"Attribute": "Sparks.Burst.SpawnGroup", "Value": {"Literal": 0, "Type": "int"}},
        {"Attribute": "Sparks.Rate", "Value": {"Literal": 2.5, "Type": "float"}}
      ]}],
    "Scripts": [
      {"Usage": "ParticleSpawnScriptInterpolated", "Target": "GPU", "Modules": []},
      {"Usage": "ParticleUpdateScript", "Target": "GPU", "Modules": []},
      {"Usage": "ParticleGPUComputeScript", "Target": "GPU",
       "ShaderDataInterfaces": [
         {"Symbol": "Emitter_Colors", "Class": "NiagaraDataInterfaceArrayColor", "DataInterface": "Sparks.Colors"},
         {"Symbol": "Emitter_Size", "Class": "NiagaraDataInterfaceCurve", "DataInterface": "Sparks.Size"},
         {"Symbol": "Emitter_Curl", "Class": "NiagaraDataInterfaceVectorField", "DataInterface": "Sparks.Curl"}],
       "Shader": {
         "Platform": "PCD3D_SM6", "CodeHash": "00000000000000ab", "Threads": [64, 1, 1], "Function": "dx_compute",
         "Source": "void dx_compute(inout Dx_Env e) {\nint v1=dx_thread(e,0);\nint4 v2=dx_uav_i(e,2,0);\nint4 v3=dx_cb_i(e,0,11);\nfloat4 v4=dx_cb(e,0,12);\nint4 v5=dx_cb_i(e,1,0);\nfloat4 v6=dx_cb(e,0,53);\nD4 v7=dx_buffer(e,0,v1);\nD4 v8=dx_buffer(e,3,v5.x);\nD4 v9=dx_buffer(e,2,1);\nfloat4 v10=dx_sample_level3(e,5,0,d_c(0.5),d_c(0.5),d_c(v6.x),0.0);\nint4 v11=dx_buffer_i(e,1,v1);\nif (v1<v2.x) {\ndx_uav_store(e,1,v1,d_add(v7.x,d_c(v4.z)));\ndx_uav_store_i(e,0,v1,v11.x);\n} else if (v1<v2.x+v3.x) {\ndx_uav_store(e,1,v1,d_c(0.0));\ndx_uav_store(e,1,65536+v1,v8.x);\ndx_uav_store(e,1,5*65536+v1,d_c(v10[0]));\ndx_uav_store(e,1,8*65536+v1,d_mul(v9.x,d_c(100.0)));\ndx_uav_store_i(e,0,v1,v1);\n}\n}\n",
         "Constants": [
           {"Name": "EmitterTickCounter", "Buffer": 0, "Offset": 12, "Size": 4},
           {"Name": "NumSpawnedInstances", "Buffer": 0, "Offset": 176, "Size": 4},
           {"Name": "ComponentBufferSizeRead", "Buffer": 0, "Offset": 180, "Size": 4},
           {"Name": "ReadInstanceCountOffset", "Buffer": 0, "Offset": 188, "Size": 4},
           {"Name": "Engine_DeltaTime", "Buffer": 0, "Offset": 200, "Size": 4},
           {"Name": "Emitter_Colors_ArrayBufferParams", "Buffer": 0, "Offset": 800, "Size": 8},
           {"Name": "Emitter_Size_LUTOffset", "Buffer": 0, "Offset": 816, "Size": 4},
           {"Name": "Emitter_Curl_MinBounds", "Buffer": 0, "Offset": 848, "Size": 12}],
         "Resources": [
           {"Name": "InputFloat", "Class": "SRV", "Slot": 0}, {"Name": "InputInt", "Class": "SRV", "Slot": 1},
           {"Name": "StaticInputFloat", "Class": "SRV", "Slot": 2}, {"Name": "RWOutputFloat", "Class": "UAV", "Slot": 1},
           {"Name": "RWOutputInt", "Class": "UAV", "Slot": 0}, {"Name": "RWInstanceCounts", "Class": "UAV", "Slot": 2},
           {"Name": "Emitter_Colors_ArrayReadBuffer", "Class": "SRV", "Slot": 3},
           {"Name": "Emitter_Curl_Texture", "Class": "Texture", "Slot": 5}, {"Name": "Emitter_Curl_Sampler", "Class": "Sampler", "Slot": 0}],
         "Buffers": [{"Slot": 0, "Type": "hostlayout.$Globals", "Size": 864}, {"Slot": 1, "Type": "FNiagaraExternalParameters", "Size": 8}],
         "ExternalSize": 8,
         "External": [
           {"Name": "User.Variant", "Type": "NiagaraInt32", "Offset": 0, "Bits": [0]},
           {"Name": "Sparks.Rate", "Type": "NiagaraFloat", "Offset": 4, "Bits": [0]},
           {"Name": "PREV_User.Variant", "Type": "NiagaraInt32", "Offset": 8, "Bits": [0]}]
       }}
    ],
    "DataInterfaces": [
      {"Name": "Sparks.Colors", "Class": "NiagaraDataInterfaceArrayColor", "Colors": [[1.0, 0.0, 0.0, 1.0], [0.0, 0.0, 1.0, 0.5]]},
      {"Name": "Sparks.Size", "Class": "NiagaraDataInterfaceCurve", "Curve": {"Channels": ["Value"], "LUT": [0.0, 1.0, 0.25]}, "Properties": {"LUTMinTime": 0.0, "LUTInvTimeRange": 1.0}},
      {"Name": "Sparks.Curl", "Class": "NiagaraDataInterfaceVectorField", "Properties": {"Field": "/Game/Fields/Curl.Curl", "bTileX": true}}
    ],
    "Renderers": [{"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties"}]
  }]
}`

@(test)
cooked_gpu_emitter_runs_its_simulation_shader :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)
    fields:=[]Cooked_Field{{path="/Game/Fields/Curl.Curl",size={16,16,16},low={-50,-50,-50},high={50,50,50},value_low=-1,value_high=1}}
    sys,err:=cooked_niagara_build(GPU_SYSTEM,alloc,nil,fields)
    _,bad:=err.?
    if !testing.expect(t,!bad)||!testing.expect(t,len(sys.emitters)==1&&len(sys.emitters[0].layers)==1) {return}
    layer:=sys.emitters[0].layers[0]
    testing.expectf(t,len(layer.notes)==0,"notes: %v",layer.notes)
    testing.expect_value(t,layer.program_name,"Cooked_NS_Gpu_Sparks")
    testing.expect(t,len(layer.textures)==1&&layer.textures[0]=="/Game/Fields/Curl.Curl")
    src:=layer.program_source
    for want in ([]string{
        "//! prepare\n//! births\n",
        // The registers of the particle, by the layout of its attributes.
        "case 0: return a.f_Age;","case 5: a.f_Position_x = v; break;","case 0: return a.f_UniqueID;",
        // The words of the constant buffers: the spawn count, the stride of a register, the frame.
        "case 11: return uint4(uint(x.spawned), 65536u, 0u, 0u);",
        "case 12: return uint4(0u, 0u, nf(e.dt), 0u);",
        // The array's length, the curve's place in the static buffer, the box of the field.
        "case 50: return uint4(2u, 1u, 0u, 0u);","case 51: return uint4(0u, 0u, 0u, 0u);","case 53: return uint4(0xc2480000u, 0xc2480000u, 0xc2480000u, 0u);",
        // The user's value, and what the emitter's script writes, in the external buffer.
        "case 0: return uint4(0x00000001u, mirai_vfx_state_load(ctx, ",
        "if (i >= 0 && i < 3) return NV_DATA",
        "nv_field_unit(x.p.field0, float3(16.0, 16.0, 16.0), float3(1.0, 0.0, 0.0)",
        "nv_float_set(x.a, i / NV_STRIDE, asuint(v.v)); x.wrote = true;",
        "x.thread = nv_channel_birth ? 0 : int(ctx.birth - ctx.born); x.start = 0; x.spawned = nv_channel_birth ? 1 : int(ctx.spawned);",
        "x.thread = int(ctx.particle); x.start = x.thread + 1; x.spawned = 0;",
        "bool keep = x.wrote;",
        "void dx_compute(inout Dx_Env e) {",
    }) {
        testing.expectf(t,strings.contains(src,want),"the program has %q",want)
    }

    folder:=".mirai/tmp/cooked-vfx-gpu"
    _=os.make_directory_all(folder)
    shader_path,_:=filepath.join({folder,"Cooked_NS_Gpu_Sparks.slang"},context.temp_allocator)
    _=os.write_entire_file(shader_path,transmute([]u8)src)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)
    if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
        vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
        sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
        res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
        testing.expectf(t,res.error=="" && res.errors==0,"the program does not compile: %s %v",res.error,res.diagnostics)
        if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"its stages did not compile: %v",res.diagnostics)}
    }

    // Without its shader a GPU emitter is a note and takes no program; so is one whose shader
    // reads a parameter that has no answer.
    for change in ([][2]string{{`"Shader": {`,`"Unread": {`},{`"Name": "Engine_DeltaTime"`,`"Name": "Engine_Unheard"`}}) {
        doc,_:=strings.replace_all(GPU_SYSTEM,change[0],change[1],context.temp_allocator)
        other,other_err:=cooked_niagara_build(doc,alloc,nil,fields)
        _,failed:=other_err.?
        if testing.expect(t,!failed&&len(other.emitters)==1&&len(other.emitters[0].layers)==1) {
            testing.expect_value(t,other.emitters[0].layers[0].program_name,"")
            testing.expect(t,len(other.emitters[0].layers[0].notes)>0)
        }
    }
}

@(test)
cooked_gpu_emitter_survives_what_is_no_shader :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    alloc:=mem.tracking_allocator(&tracking)
    text:=GPU_SYSTEM
    swaps:=[][2]u8{{'"','7'},{'{','['},{'[','{'},{':',','},{'1','"'},{'5','9'}}
    for swap in swaps {
        seen:=0
        for i in 0..<len(text) {
            if text[i]!=swap[0] {continue}
            seen+=1
            if seen%5!=0 {continue}
            changed:=make([]u8,len(text),context.temp_allocator)
            copy(changed,text)
            changed[i]=swap[1]
            sys,_:=cooked_niagara_build(string(changed),alloc)
            cooked_vfx_system_destroy(&sys,alloc)
        }
    }
    testing.expect_value(t,len(tracking.allocation_map),0)
}

// A GPU emitter reading NiagaraDataInterfaceSkeletalMesh with a target skeleton binds Mirai's
// `bones` and `transform` resources and resolves bones and sockets without placeholder limits.
@(test)
cooked_gpu_emitter_samples_skeletal_mesh_resources :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    alloc:=mem.tracking_allocator(&tracking)
    doc:=`{
  "Schema": "ue5parse.niagara/2", "Name": "NS_GpuSkel",
  "Emitters": [{
    "Name": "Streaks", "Target": "GPU",
    "Settings": {"bLocalSpace": false, "RandomSeed": 1},
    "Attributes": [
      {"Name": "Age", "Type": "NiagaraFloat", "Float": [0, 1]},
      {"Name": "Position", "Type": "NiagaraPosition", "Float": [1, 3]},
      {"Name": "UniqueID", "Type": "NiagaraInt32", "Int32": [0, 1]}
    ],
    "EmitterScripts": [{"Usage": "EmitterUpdateScript", "Modules": [], "Outputs": [
      {"Attribute": "Streaks.Burst.Count", "Value": {"Literal": 4, "Type": "int"}},
      {"Attribute": "Streaks.Burst.InterpStartDt", "Value": {"Literal": 0.0, "Type": "float"}},
      {"Attribute": "Streaks.Burst.IntervalDt", "Value": {"Literal": 0.0, "Type": "float"}},
      {"Attribute": "Streaks.Burst.SpawnGroup", "Value": {"Literal": 0, "Type": "int"}}
    ]}],
    "Scripts": [
      {"Usage": "ParticleGPUComputeScript", "Target": "GPU",
       "ShaderDataInterfaces": [
         {"Symbol": "System_SkeletalMesh", "Class": "NiagaraDataInterfaceSkeletalMesh", "DataInterface": "System.Skeletal Mesh"}
       ],
       "Shader": {
         "Platform": "PCD3D_SM6", "CodeHash": "00000000000000cd", "Threads": [64, 1, 1], "Function": "dx_compute",
         "Source": "void dx_compute(inout Dx_Env e) {\nint v1=dx_thread(e,0);\nint4 v2=dx_uav_i(e,1,0);\nint4 v3=dx_cb_i(e,0,11);\nint4 v4=dx_buffer_i(e,5,0);\nD4 v5=dx_buffer(e,3,v4.x*3);\nD4 v6=dx_buffer(e,4,v4.x*3);\nfloat4 v7=dx_cb(e,0,52);\nif (v1>=v2.x && v1<v2.x+v3.x) {\ndx_uav_store(e,0,v1,d_c(0.0));\ndx_uav_store(e,0,65536+v1,d_add(v5.x,d_sub(v6.x,d_c(v7.x))));\n}\n}\n",
         "Constants": [
           {"Name": "NumSpawnedInstances", "Buffer": 0, "Offset": 176, "Size": 4},
           {"Name": "System_SkeletalMesh_NumBones", "Buffer": 0, "Offset": 800, "Size": 4},
           {"Name": "System_SkeletalMesh_NumFilteredBones", "Buffer": 0, "Offset": 804, "Size": 4},
           {"Name": "System_SkeletalMesh_FilteredSocketBoneOffset", "Buffer": 0, "Offset": 808, "Size": 4},
           {"Name": "System_SkeletalMesh_InstanceTransform", "Buffer": 0, "Offset": 832, "Size": 64},
           {"Name": "System_SkeletalMesh_InstancePrevTransform", "Buffer": 0, "Offset": 896, "Size": 64},
           {"Name": "System_SkeletalMesh_InstanceRotation", "Buffer": 0, "Offset": 960, "Size": 16},
           {"Name": "System_SkeletalMesh_InstancePrevRotation", "Buffer": 0, "Offset": 976, "Size": 16},
           {"Name": "System_SkeletalMesh_InstanceInvDeltaTime", "Buffer": 0, "Offset": 992, "Size": 4}
         ],
         "Resources": [
           {"Name": "InputFloat", "Class": "SRV", "Slot": 0},
           {"Name": "RWOutputFloat", "Class": "UAV", "Slot": 0},
           {"Name": "RWInstanceCounts", "Class": "UAV", "Slot": 1},
           {"Name": "System_SkeletalMesh_MeshCurrSamplingBonesBuffer", "Class": "SRV", "Slot": 3},
           {"Name": "System_SkeletalMesh_MeshPrevSamplingBonesBuffer", "Class": "SRV", "Slot": 4},
           {"Name": "System_SkeletalMesh_FilteredAndUnfilteredBones", "Class": "SRV", "Slot": 5}
         ],
         "Buffers": [{"Slot": 0, "Type": "hostlayout.$Globals"}]
       }}
    ],
    "DataInterfaces": [{"Name": "System.Skeletal Mesh", "Class": "NiagaraDataInterfaceSkeletalMesh",
      "Properties": {"FilteredBones": ["head", "hand_r"], "FilteredSockets": ["Tip"]}}],
    "Renderers": [{"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties"}]
  }]
}`
    skel:=Cooked_Skeleton{
        bones=[]Cooked_Bone{{"root",0},{"head",1},{"hand_r",2}},
        sockets=[]Cooked_Socket{{"Tip",2,{0,0.8,0},{0,0,0,1},{1,1,1}}},
        bone_turn={0,0,0,1},
    }
    sys,err:=cooked_niagara_build(doc,alloc,nil,nil,skel)
    defer cooked_vfx_system_destroy(&sys,alloc)
    e,bad:=err.?
    if !testing.expectf(t,!bad,"build failed: %v",e)||!testing.expect(t,len(sys.emitters)==1&&len(sys.emitters[0].layers)==1) {return}
    layer:=sys.emitters[0].layers[0]
    testing.expectf(t,len(layer.notes)==0,"notes: %v",layer.notes)
    testing.expectf(t,len(layer.limits)==0,"limits: %v",layer.limits)
    testing.expect_value(t,len(layer.resources),2)
    src:=layer.program_source
    for want in ([]string{
        "//! resource skeleton bones",
        "//! resource skeleton_transform transform",
        "mirai_vfx_bone(ctx, skeleton,",
        "mirai_vfx_transform(ctx, skeleton_transform)",
        "nv_skel_filtered_index_0(i)",
        "nv_skel_gpu_bone_0(x.ctx, x.n, i, false, x.skel_ipos, x.skel_inv_q, x.skel_inv_s)",
        "nv_skel_gpu_bone_0(x.ctx, x.n, i, true, x.skel_ppos, x.skel_pinv_q, x.skel_pinv_s)",
        "asuint(x.skel_curr[",
        "asuint(x.skel_prev[",
        // A socket away from its bone moves as the bone turns too.
        "vel_m = b.velocity + cross(b.angular_velocity, offset);",
    }) {
        testing.expectf(t,strings.contains(src,want),"GPU skeletal program missing %q",want)
    }
    folder:=".mirai/tmp/cooked-vfx-gpu-skel"
    _=os.make_directory_all(folder)
    shader_path,_:=filepath.join({folder,"Cooked_NS_GpuSkel_Streaks.slang"},context.temp_allocator)
    _=os.write_entire_file(shader_path,transmute([]u8)src)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)
    if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
        vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
        sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
        res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
        testing.expectf(t,res.error=="" && res.errors==0,"GPU skeletal shader failed: %s %v",res.error,res.diagnostics)
        if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"GPU skeletal stages failed: %v",res.diagnostics)}
    }
    cooked_vfx_system_destroy(&sys,alloc)
    testing.expect_value(t,len(tracking.allocation_map),0)
}
