package unreal_vfx_editor

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import shaders "mirai:cook/shaders"

// A system of one emitter whose scripts use what a translation must answer: a temporary and a
// curve in the particle scripts, integers of 32 bits, a parameter of the user, and an emitter
// script that keeps its age and gives a burst.
@(private="file")
PROGRAM_SYSTEM :: `{
  "Schema": "ue5parse.niagara/2",
  "Name": "NS_Test",
  "UserParameters": [{"Name": "User.Variant", "Type": "NiagaraInt32", "Value": 1}, {"Name": "User.Offset", "Type": "Vector3f", "Value": [1.5, 0.0, 2.0]}],
  "Scripts": [{"Usage": "SystemUpdateScript", "Modules": [{"Name": "SystemState", "Temps": [{"Name": "t1", "Value": {"Op": "add", "Args": [{"Attribute": "System.Age", "DataSet": 0}, {"Parameter": "Engine.DeltaTime", "Source": "Engine"}]}}]}],
    "Outputs": [{"Attribute": "System.Age", "Value": {"Temp": "t1"}}]}],
  "Emitters": [{
    "Name": "Burst",
    "Settings": {"bLocalSpace": true, "RandomSeed": 7},
    "EmitterScripts": [{"Usage": "EmitterUpdateScript", "Modules": [{"Name": "EmitterState", "Temps": [
        {"Name": "t2", "Value": {"Op": "cmpeq", "Args": [{"Attribute": "Burst.Age", "DataSet": 0}, {"Literal": 0.0, "Type": "float"}]}}]}],
      "Outputs": [
        {"Attribute": "Burst.Age", "Value": {"Op": "add", "Args": [{"Attribute": "Burst.Age", "DataSet": 0}, {"Parameter": "Engine.DeltaTime", "Source": "Engine"}]}},
        {"Attribute": "Burst.Spawn.Count", "Value": {"Op": "select", "Args": [{"Op": "logic_and", "Args": [{"Temp": "t2"}, {"Op": "cmplt", "Args": [{"Attribute": "System.Age", "DataSet": 0}, {"Literal": 5.0, "Type": "float"}]}]}, {"Literal": 12, "Type": "int"}, {"Literal": 0, "Type": "bits", "AsInt": 0}]}},
        {"Attribute": "Burst.Spawn.InterpStartDt", "Value": {"Literal": 0.0, "Type": "float"}},
        {"Attribute": "Burst.ExecutionState", "Value": {"Op": "select", "Args": [{"Op": "cmpgt", "Args": [{"Attribute": "Burst.Age", "DataSet": 0}, {"Literal": 1.0, "Type": "float"}]}, {"Literal": 3, "Type": "int"}, {"Literal": 0, "Type": "int"}]}},
        {"Attribute": "Burst.Scale", "Value": {"Attribute": "Engine.Burst.SpawnCountScale", "DataSet": 1}}
      ]}],
    "Scripts": [
      {"Usage": "ParticleSpawnScriptInterpolated", "Target": "CPU",
       "Modules": [{"Name": "Main",
         "Temps": [{"Name": "t1", "Value": {"Op": "addi", "Args": [{"Op": "muli", "Args": [{"Op": "addi", "Args": [{"Parameter": "Engine.Emitter.TotalSpawnedParticles", "Source": "Engine"}, {"ExecIndex": true}]}, {"Literal": 1664525, "Type": "int"}]}, {"Literal": 246893252511773, "Type": "int"}]}}],
         "Calls": [{"Name": "t2", "DataInterface": "Burst.Colors", "Function": "Get", "Args": [{"Literal": 0, "Type": "bits", "AsInt": 0}, {"Parameter": "User.Variant", "Source": "User", "Value": 0, "Type": "int"}], "Outputs": 4}]}],
       "Outputs": [
         {"Attribute": "Lifetime", "Value": {"Literal": 0.5, "Type": "float"}},
         {"Attribute": "Position", "Components": {"x": {"Parameter": "User.Offset.x", "Source": "User", "Value": 0.0, "Type": "float"}, "y": {"Literal": 0.0, "Type": "float"},
           "z": {"Op": "div", "Args": [{"Op": "i2f", "Args": [{"Op": "bit_and", "Args": [{"Op": "bit_rshift", "Args": [{"Temp": "t1"}, {"Literal": 8, "Type": "int"}]}, {"Literal": 16777215, "Type": "int"}]}]}, {"Literal": 16777216.0, "Type": "float"}]}}},
         {"Attribute": "Color", "Components": {"x": {"Call": "t2", "Output": 0}, "y": {"Call": "t2", "Output": 1}, "z": {"Call": "t2", "Output": 2}, "w": {"Call": "t2", "Output": 3}}}
       ],
       "KeepConditions": []},
      {"Usage": "ParticleUpdateScript", "Target": "CPU",
       "Modules": [{"Name": "Scale", "Calls": [{"Name": "t3", "DataInterface": "Burst.Size", "Function": "SampleCurve", "Args": [{"Op": "div", "Args": [{"Attribute": "Age", "DataSet": 0}, {"Attribute": "Lifetime", "DataSet": 0}]}], "Outputs": 1}]}],
       "Outputs": [
         {"Attribute": "Age", "Value": {"Op": "add", "Args": [{"Attribute": "Age", "DataSet": 0}, {"Parameter": "Engine.DeltaTime", "Source": "Engine"}]}},
         {"Attribute": "SpriteSize", "Components": {"x": {"Op": "mul", "Args": [{"Call": "t3", "Output": 0}, {"Literal": 100.0, "Type": "float"}]}, "y": {"Literal": 50.0, "Type": "float"}}},
         {"Attribute": "Seen", "Value": {"Parameter": "Burst.Age", "Source": "ParameterStore", "Value": 0.0, "Type": "float"}}
       ],
       "KeepConditions": [{"Op": "cmplt", "Args": [{"Attribute": "Age", "DataSet": 0}, {"Attribute": "Lifetime", "DataSet": 0}]}]}
    ],
    "DataInterfaces": [
      {"Name": "Burst.Colors", "Class": "NiagaraDataInterfaceArrayColor", "Colors": [[1.0, 0.0, 0.0, 1.0], [0.0, 0.0, 1.0, 0.5]]},
      {"Name": "Burst.Size", "Class": "NiagaraDataInterfaceCurve", "Curve": {"Channels": ["Value"], "LUT": [0.0, 1.0, 0.25]}, "Properties": {"LUTNumSamplesMinusOne": 2.0}}
    ],
    "Renderers": [{"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties"}]
  }]
}`

@(test)
cooked_emitter_runs_its_scripts_as_a_program :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)

    sys,err:=cooked_niagara_build(PROGRAM_SYSTEM,alloc)
    _,bad:=err.?
    if !testing.expect(t,!bad)||!testing.expect_value(t,len(sys.emitters),1) {return}
    if !testing.expect_value(t,len(sys.emitters[0].layers),1) {return}
    em:=sys.emitters[0].layers[0]
    testing.expect_value(t,len(em.notes),0)
    testing.expect_value(t,em.program_name,"Cooked_NS_Test_Burst")
    src:=em.program_source
    wants:=[]string{
        "//! mirai vfx Cooked_NS_Test_Burst\n//! moves\n//! prepare\n//! births\n",
        "static const bool NV_LOCAL = true;",
        // An integer past 32 bits wraps; the parameter of the user is the system's, not the script's default.
        "uint t1 = (((e.born + e.exec) * 0x0019660du) + 0x509d081du);",
        "{ int nv_i = clamp(int(0x00000001u), 0, 1);",
        "uint o1 = 0x3fc00000u;",
        "nf(float(int(((t1 >> (0x00000008u & 31u)) & 0x00ffffffu))))",
        "static const float NV_DATA",
        "nf(lerp(NV_DATA",
        // What the emitter's script keeps is read from the state by its particles.
        "mirai_vfx_state_load(ctx, ",
        "keep = keep && (nb(fv(a.f_Age) < fv(a.f_Lifetime))) != 0u;",
        "float2 sides = float2(abs(fv(a.f_SpriteSize_x)), abs(fv(a.f_SpriteSize_y)));",
        "void prepare(Mirai_Vfx_Context ctx, Parameters p) {",
        "uint births(Mirai_Vfx_Context ctx, Parameters p) {",
        // An emitter that is no longer active starts nothing.
        ") != 0u) return 0u;",
    }
    for want in wants {
        testing.expectf(t,strings.contains(src,want),"the program has %q",want)
    }
    // A temporary is written before what reads it, in each function.
    spawn_at:=strings.index(src,"void initialize(")
    testing.expect(t,spawn_at>0&&strings.index(src[spawn_at:],"uint t1 = ")>0&&strings.index(src[spawn_at:],"uint t1 = ")<strings.index(src[spawn_at:],"uint o3 = "))
    prepare_at:=strings.index(src,"void prepare(")
    if testing.expect(t,prepare_at>0) {
        body:=src[prepare_at:]
        testing.expect(t,strings.index(body,"uint t2 = ")>0&&strings.index(body,"uint t2 = ")<strings.index(body,"uint n1 = "))
        testing.expect(t,strings.contains(body,"uint t1 = nf(fv(s"),"the system's own temporary, read through what the emitter reads of it")
    }
    testing.expect_value(t,len(em.limits),0)
    testing.expect(t,strings.contains(src,"visual.scale = float3(sides / largest, 1.0);"))

    folder:=".mirai/tmp/cooked-vfx-program"
    _=os.make_directory_all(folder)
    shader_path,_:=filepath.join({folder,"Cooked_NS_Test_Burst.slang"},context.temp_allocator)
    _=os.write_entire_file(shader_path,transmute([]u8)src)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)
    if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
        vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
        sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
        res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
        testing.expectf(t,res.error=="" && res.errors==0,"the program does not compile: %s %v",res.error,res.diagnostics)
        if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"its stages did not compile: %v",res.diagnostics)}
    }

    // What has no answer is said, and the emitter takes no program.
    unanswered,_:=strings.replace_all(PROGRAM_SYSTEM,`"Function": "SampleCurve"`,`"Function": "SampleField"`,context.temp_allocator)
    unanswered,_=strings.replace_all(unanswered,`"Parameter": "Engine.Emitter.TotalSpawnedParticles"`,`"Parameter": "Engine.Unheard"`,context.temp_allocator)
    other,other_err:=cooked_niagara_build(unanswered,alloc)
    _,bad=other_err.?
    if testing.expect(t,!bad&&len(other.emitters)==1) {
        if testing.expect_value(t,len(other.emitters[0].layers),1) {
            testing.expect_value(t,other.emitters[0].layers[0].program_name,"")
            testing.expect_value(t,len(other.emitters[0].layers[0].notes),2)
        }
    }
}

@(test)
cooked_program_survives_what_is_no_system :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    alloc:=mem.tracking_allocator(&tracking)
    // The system with each of its quotes, brackets and digits changed in turn: an error or a system, never a crash or a leak.
    text:=PROGRAM_SYSTEM
    swaps:=[][2]u8{{'"','7'},{'{','['},{'[','{'},{':',','},{'1','"'},{'t','n'}}
    for swap in swaps {
        seen:=0
        for i in 0..<len(text) {
            if text[i]!=swap[0] {continue}
            seen+=1
            if seen%7!=0 {continue}
            changed:=make([]u8,len(text),context.temp_allocator)
            copy(changed,text)
            changed[i]=swap[1]
            sys,_:=cooked_niagara_build(string(changed),alloc)
            cooked_vfx_system_destroy(&sys,alloc)
        }
    }
    // Values of the wrong kind where a script expects a tree, a name or a list.
    for wrong in ([]string{`7`,`"x"`,`[]`,`{"Op": 3, "Args": 5}`,`{"Temp": 1}`,`{"Call": "t9", "Output": "x"}`,`{"Literal": "a", "Type": 4}`,`{"Parameter": []}`}) {
        doc,_:=strings.replace_all(PROGRAM_SYSTEM,`{"Literal": 0.5, "Type": "float"}`,wrong,context.temp_allocator)
        doc,_=strings.replace_all(doc,`"Modules": [{"Name": "Main",`,strings.concatenate({`"Modules": [`,wrong,`, {"Name": "Main",`},context.temp_allocator),context.temp_allocator)
        sys,_:=cooked_niagara_build(doc,alloc)
        cooked_vfx_system_destroy(&sys,alloc)
    }
    testing.expect_value(t,len(tracking.allocation_map),0)
}

// A script that samples a static vector field reads it from a texture of the program, with
// the box, the cells and the values of the field as it is extracted; one that is not extracted
// is a note.
@(test)
cooked_emitter_samples_a_vector_field :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)
    doc:=`{
  "Schema": "ue5parse.niagara/2", "Name": "NS_Field",
  "Emitters": [{
    "Name": "Curl",
    "Scripts": [
      {"Usage": "ParticleSpawnScript", "Target": "CPU",
       "Modules": [{"Name": "Main", "Calls": [{"Name": "t1", "DataInterface": "Curl.Field", "Function": "SampleField", "Outputs": 3,
          "Args": [{"Literal": 10.0, "Type": "float"}, {"Literal": 20.0, "Type": "float"}, {"Literal": 30.0, "Type": "float"}]}]}],
       "Outputs": [
         {"Attribute": "Lifetime", "Value": {"Literal": 1.0, "Type": "float"}},
         {"Attribute": "Velocity", "Components": {"x": {"Call": "t1", "Output": 0}, "y": {"Call": "t1", "Output": 1}, "z": {"Call": "t1", "Output": 2}}}
       ]}
    ],
    "DataInterfaces": [{"Name": "Curl.Field", "Class": "NiagaraDataInterfaceVectorField",
      "Properties": {"Field": "/Game/Fields/Curl.Curl", "bTileX": true, "bTileY": false, "bTileZ": true}}],
    "Renderers": [{"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties"}]
  }]
}`
    fields:=[]Cooked_Field{{path="/Game/Fields/Curl.Curl",size={16,8,4},low={-500,-500,0},high={500,500,1000},value_low=-1,value_high=1}}
    sys,err:=cooked_niagara_build(doc,alloc,nil,fields)
    _,bad:=err.?
    if !testing.expect(t,!bad)||!testing.expect(t,len(sys.emitters)==1&&len(sys.emitters[0].layers)==1) {return}
    layer:=sys.emitters[0].layers[0]
    testing.expect_value(t,len(layer.notes),0)
    if testing.expect_value(t,len(layer.textures),1) {testing.expect_value(t,layer.textures[0],"/Game/Fields/Curl.Curl")}
    src:=layer.program_source
    testing.expect(t,strings.contains(src,"//! parameter field0 {\"kind\":\"texture\"}"))
    testing.expect(t,strings.contains(src,"uint field0;"))
    testing.expect(t,strings.contains(src,"nv_field(p.field0, float3(16.0, 8.0, 4.0), float3(-500.0, -500.0, 0.0), float3(500.0, 500.0, 1000.0), float3(1.0, 0.0, 1.0), -1.0, 1.0,"))
    folder:=".mirai/tmp/cooked-vfx-field"
    _=os.make_directory_all(folder)
    shader_path,_:=filepath.join({folder,strings.concatenate({layer.program_name,".slang"},context.temp_allocator)},context.temp_allocator)
    _=os.write_entire_file(shader_path,transmute([]u8)src)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)
    if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
        vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
        sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
        res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
        testing.expectf(t,res.error==""&&res.errors==0,"the program does not compile: %s %v",res.error,res.diagnostics)
    }
    // Without the field: a note, and no program.
    other,_:=cooked_niagara_build(doc,alloc)
    if testing.expect(t,len(other.emitters)==1&&len(other.emitters[0].layers)==1) {
        testing.expect_value(t,other.emitters[0].layers[0].program_name,"")
        testing.expect(t,len(other.emitters[0].layers[0].notes)==1&&strings.contains(other.emitters[0].layers[0].notes[0],"not extracted"))
    }
    // A field of no cells is not sampled.
    empty:=[]Cooked_Field{{path="/Game/Fields/Curl.Curl"}}
    none,_:=cooked_niagara_build(doc,alloc,nil,empty)
    testing.expect(t,len(none.emitters)==1&&none.emitters[0].layers[0].program_name=="")
}

// The scripts ask a skeletal mesh where one of its sockets is: the layer says which, for
// whoever lays the effect to put its emitter there, and the program reads its emitter.
@(test)
cooked_emitter_follows_a_socket_of_a_skeletal_mesh :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)
    Case :: struct {function,index:string, follows:string, socket:bool, note:string}
    cases:=[]Case{
        {"GetFilteredSocket",`{"Literal": 1, "Type": "int"}`,"Tip",true,""},
        {"GetFilteredBone",`{"Literal": 0, "Type": "int"}`,"spine_01",false,""},
        // Hostile: a number past the list, a negative one, one the scripts compute.
        {"GetFilteredSocket",`{"Literal": 7, "Type": "int"}`,"",false,"a number the scripts compute"},
        {"GetFilteredSocket",`{"Literal": -1, "Type": "int"}`,"",false,"a number the scripts compute"},
        {"GetFilteredBone",`{"Call": "t9", "Output": 0}`,"",false,"a number the scripts compute"},
    }
    for c in cases {
        template:=`{
  "Schema": "ue5parse.niagara/2", "Name": "NS_Follow",
  "Emitters": [{
    "Name": "Tip",
    "Scripts": [
      {"Usage": "ParticleSpawnScript", "Target": "CPU",
       "Modules": [{"Name": "Main", "Calls": [
         {"Name": "t0", "DataInterface": "Tip.Mesh", "Function": "FUNCTION", "Outputs": 1, "Args": [INDEX]},
         {"Name": "t1", "DataInterface": "Tip.Mesh", "Function": "GetSkinnedBoneDataWS", "Outputs": 13, "Args": [{"Call": "t0", "Output": 0}]}]}],
       "Outputs": [
         {"Attribute": "Lifetime", "Value": {"Literal": 1.0, "Type": "float"}},
         {"Attribute": "Position", "Components": {"x": {"Call": "t1", "Output": 0}, "y": {"Call": "t1", "Output": 1}, "z": {"Call": "t1", "Output": 2}}}
       ]}
    ],
    "DataInterfaces": [{"Name": "Tip.Mesh", "Class": "NiagaraDataInterfaceSkeletalMesh",
      "Properties": {"FilteredSockets": ["Hilt", "Tip"], "FilteredBones": ["spine_01"]}}],
    "Renderers": [{"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties"}]
  }]
}`
        doc,_:=strings.replace_all(template,"FUNCTION",c.function,context.temp_allocator)
        doc,_=strings.replace_all(doc,"INDEX",c.index,context.temp_allocator)
        sys,err:=cooked_niagara_build(doc,alloc)
        e,bad:=err.?
        if !testing.expectf(t,!bad,"%s %s: the build fails: %v",c.function,c.index,e)||!testing.expect(t,len(sys.emitters)==1&&len(sys.emitters[0].layers)==1) {continue}
        layer:=sys.emitters[0].layers[0]
        testing.expectf(t,layer.follows==c.follows&&layer.follows_socket==c.socket,"%s %s follows %q (socket %v)",c.function,c.index,layer.follows,layer.follows_socket)
        if c.note!="" {
            found:=false
            for n in layer.notes {found|=strings.contains(n,c.note)}
            testing.expectf(t,found,"%s %s: no note of it in %v",c.function,c.index,layer.notes)
            testing.expect_value(t,layer.program_name,"")
            continue
        }
        testing.expectf(t,len(layer.notes)==0,"%s %s: %v",c.function,c.index,layer.notes)
        src:=layer.program_source
        testing.expect(t,strings.contains(src,"nv_turn_back(nv_emitter_turn(ctx))")&&strings.contains(src,"nf(e.owner.x)"))
        folder:=".mirai/tmp/cooked-vfx-follow"
        _=os.make_directory_all(folder)
        shader_path,_:=filepath.join({folder,strings.concatenate({layer.program_name,".slang"},context.temp_allocator)},context.temp_allocator)
        _=os.write_entire_file(shader_path,transmute([]u8)src)
        root,cwd_err:=os.get_working_directory(context.temp_allocator)
        if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
            vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
            sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
            res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
            testing.expectf(t,res.error==""&&res.errors==0,"the program does not compile: %s %v",res.error,res.diagnostics)
        }
    }
}

// With a target skeleton, CPU emitters sample live bones and sockets through Mirai's `bones`
// resource across dynamic SpawnGroup indices and split RibbonID streams per ribbon.
@(test)
cooked_emitter_samples_bones_resource_with_multi_spawn_ribbons :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    alloc:=mem.tracking_allocator(&tracking)
    doc:=`{
  "Schema": "ue5parse.niagara/2", "Name": "NS_SkelRibbon",
  "Emitters": [{
    "Name": "Trail",
    "EmitterScripts": [{"Usage": "EmitterUpdateScript", "Modules": [], "Outputs": [
      {"Attribute": "Trail.S0.Count", "Value": {"Literal": 2, "Type": "int"}},
      {"Attribute": "Trail.S0.InterpStartDt", "Value": {"Literal": 0.0, "Type": "float"}},
      {"Attribute": "Trail.S0.IntervalDt", "Value": {"Literal": 0.008, "Type": "float"}},
      {"Attribute": "Trail.S0.SpawnGroup", "Value": {"Literal": 0, "Type": "int"}},
      {"Attribute": "Trail.S1.Count", "Value": {"Literal": 2, "Type": "int"}},
      {"Attribute": "Trail.S1.InterpStartDt", "Value": {"Literal": 0.0, "Type": "float"}},
      {"Attribute": "Trail.S1.IntervalDt", "Value": {"Literal": 0.008, "Type": "float"}},
      {"Attribute": "Trail.S1.SpawnGroup", "Value": {"Literal": 1, "Type": "int"}}
    ]}],
    "Scripts": [
      {"Usage": "ParticleSpawnScriptInterpolated", "Target": "CPU",
       "Modules": [{"Name": "Main", "Calls": [
         {"Name": "t0", "DataInterface": "Trail.Mesh", "Function": "GetFilteredSocket", "Outputs": 1,
          "Args": [{"Literal": 1, "Type": "int"}, {"Parameter": "Trail.SpawnGroup", "Source": "ParameterStore", "Type": "int", "Value": 0}]},
         {"Name": "t1", "DataInterface": "Trail.Mesh", "Function": "GetSkinnedBoneDataWSInterpolated", "Outputs": 13,
          "Args": [{"Literal": 1, "Type": "int"}, {"Call": "t0", "Output": 0},
                   {"Op": "mul", "Args": [{"Op": "mad", "Args": [{"Parameter": "Trail.SpawnInterval", "Type": "float"}, {"Op": "i2f", "Args": [{"ExecIndex": true}]}, {"Parameter": "Trail.InterpSpawnStartDt", "Type": "float"}]}, {"Parameter": "Engine.InverseDeltaTime", "Source": "Engine"}]}]}
       ]}],
       "Outputs": [
         {"Attribute": "Lifetime", "Value": {"Literal": 0.4, "Type": "float"}},
         {"Attribute": "RibbonWidth", "Value": {"Literal": 10.0, "Type": "float"}},
         {"Attribute": "RibbonID", "Components": {"Index": {"Call": "t0", "Output": 0}, "AcquireTag": {"Literal": 0, "Type": "int"}}},
         {"Attribute": "Position", "Components": {"x": {"Call": "t1", "Output": 0}, "y": {"Call": "t1", "Output": 1}, "z": {"Call": "t1", "Output": 2}}}
       ]}
    ],
    "DataInterfaces": [{"Name": "Trail.Mesh", "Class": "NiagaraDataInterfaceSkeletalMesh",
      "Properties": {"FilteredSockets": ["Hilt", "Tip"], "FilteredBones": ["spine_01"]}}],
    "Renderers": [{"Kind": "ribbon", "Class": "NiagaraRibbonRendererProperties"}]
  }]
}`
    skel:=Cooked_Skeleton{
        bones=[]Cooked_Bone{{"root",0},{"spine_01",1},{"hand_r",2}},
        sockets=[]Cooked_Socket{
            {"Hilt",2,{0,0,0},{0,0,0,1},{1,1,1}},
            {"Tip",2,{0,0.9,0},{0,0,0,1},{1,1,1}},
        },
        bone_turn={0,0,0,1},
    }
    sys,err:=cooked_niagara_build(doc,alloc,nil,nil,skel)
    defer cooked_vfx_system_destroy(&sys,alloc)
    e,bad:=err.?
    if !testing.expectf(t,!bad,"build failed: %v",e)||!testing.expect(t,len(sys.emitters)==1&&len(sys.emitters[0].layers)==1) {return}
    layer:=sys.emitters[0].layers[0]
    testing.expectf(t,len(layer.notes)==0,"notes: %v",layer.notes)
    testing.expect_value(t,layer.follows,"")
    testing.expect_value(t,len(layer.resources),1)
    if len(layer.resources)==1 {
        testing.expect_value(t,layer.resources[0].name,"skeleton")
        testing.expect_value(t,layer.resources[0].kind,"bones")
    }
    src:=layer.program_source
    for want in ([]string{
        "//! resource skeleton bones",
        "mirai_vfx_bone(ctx, skeleton,",
        "nv_skel_sample_0(ctx, e,",
        "e.spawn_group =",
        "particle.ribbon =",
        "mirai_vfx_state_store(ctx, 4u, nf(ctx.delta_time))",
    }) {
        testing.expectf(t,strings.contains(src,want),"program missing %q",want)
    }
    folder:=".mirai/tmp/cooked-vfx-skel-ribbon"
    _=os.make_directory_all(folder)
    shader_path,_:=filepath.join({folder,"Cooked_NS_SkelRibbon_Trail.slang"},context.temp_allocator)
    _=os.write_entire_file(shader_path,transmute([]u8)src)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)
    if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
        vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
        sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
        res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
        testing.expectf(t,res.error=="" && res.errors==0,"shader did not compile: %s %v",res.error,res.diagnostics)
        if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"stages did not compile: %v",res.diagnostics)}
    }
    cooked_vfx_system_destroy(&sys,alloc)
    testing.expect_value(t,len(tracking.allocation_map),0)
}

// Mesh renderer PivotOffset is applied in simulation/world space without reporting a limit.
@(test)
cooked_mesh_emitter_applies_pivot_offset :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)
    for space in ([]string{"ENiagaraMeshPivotOffsetSpace::Mesh","ENiagaraMeshPivotOffsetSpace::World","ENiagaraMeshPivotOffsetSpace::Local","ENiagaraMeshPivotOffsetSpace::Simulation"}) {
        template:=`{
  "Schema": "ue5parse.niagara/2", "Name": "NS_Pivot",
  "Emitters": [{
    "Name": "Cone",
    "Scripts": [
      {"Usage": "ParticleSpawnScript", "Target": "CPU", "Modules": [],
       "Outputs": [
         {"Attribute": "Lifetime", "Value": {"Literal": 0.5, "Type": "float"}},
         {"Attribute": "Position", "Components": {"x": {"Literal": 0.0, "Type": "float"}, "y": {"Literal": 0.0, "Type": "float"}, "z": {"Literal": 0.0, "Type": "float"}}},
         {"Attribute": "Scale", "Components": {"x": {"Literal": 1.0, "Type": "float"}, "y": {"Literal": 1.0, "Type": "float"}, "z": {"Literal": 1.0, "Type": "float"}}}
       ]}
    ],
    "Renderers": [{"Kind": "mesh", "Class": "NiagaraMeshRendererProperties",
      "Meshes": [{"Mesh": "/Game/SM_Cone.SM_Cone", "Scale": {"X": 1.0, "Y": 1.0, "Z": 1.0}, "Rotation": {"Pitch": 0.0, "Yaw": 30.0, "Roll": 0.0}, "PivotOffset": {"X": 10.0, "Y": 0.0, "Z": -2.0}, "PivotOffsetSpace": "SPACE"}]}]
  }]
}`
        doc,_:=strings.replace_all(template,"SPACE",space,context.temp_allocator)
        sys,err:=cooked_niagara_build(doc,alloc)
        _,bad:=err.?
        if !testing.expectf(t,!bad,"%s: build failed",space)||!testing.expect(t,len(sys.emitters)==1&&len(sys.emitters[0].layers)==1) {continue}
        layer:=sys.emitters[0].layers[0]
        testing.expectf(t,len(layer.notes)==0,"%s: notes %v",space,layer.notes)
        for lim in layer.limits {
            testing.expectf(t,!strings.contains(lim,"pivot"),"%s: unexpected pivot limit %q",space,lim)
        }
        src:=layer.program_source
        testing.expectf(t,strings.contains(src,"float3 nv_mesh_pivot("),"%s: missing nv_mesh_pivot",space)
        testing.expectf(t,strings.contains(src,"+ nv_mesh_pivot(ctx, a)"),"%s: missing leave pivot",space)
        testing.expectf(t,strings.contains(src,"- nv_mesh_pivot(ctx, a)"),"%s: missing enter pivot",space)
        if space=="ENiagaraMeshPivotOffsetSpace::Mesh" {
            folder:=".mirai/tmp/cooked-vfx-pivot"
            _=os.make_directory_all(folder)
            shader_path,_:=filepath.join({folder,"Cooked_NS_Pivot_Cone.slang"},context.temp_allocator)
            _=os.write_entire_file(shader_path,transmute([]u8)src)
            root,cwd_err:=os.get_working_directory(context.temp_allocator)
            if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
                vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
                sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
                res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
                testing.expectf(t,res.error=="" && res.errors==0,"pivot shader failed: %s %v",res.error,res.diagnostics)
                if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"pivot stages failed: %v",res.diagnostics)}
            }
        }
    }
}

@(test)
cooked_channel_birth_uses_birth_position :: proc(t:^testing.T) {
    // A Niagara emitter driven by a Mirai channel birth (ctx.birth == 0xFFFFFFFFu) must place its
    // origin at particle.position for both world-space and local-space emitters and compile cleanly.
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)
    for local in ([2]bool{false,true}) {
        template:=`{
  "Schema": "ue5parse.niagara/2", "Name": "NS_ChannelTest",
  "Emitters": [{
    "Name": "Burst", "Settings": {"bLocalSpace": LOCAL},
    "Scripts": [
      {"Usage": "ParticleSpawnScript", "Target": "CPU", "Modules": [],
       "Outputs": [
         {"Attribute": "Lifetime", "Value": {"Literal": 0.5, "Type": "float"}},
         {"Attribute": "Position", "Components": {
           "x": {"Parameter": "Engine.Owner.Position.x", "Source": "Engine"},
           "y": {"Parameter": "Engine.Owner.Position.y", "Source": "Engine"},
           "z": {"Parameter": "Engine.Owner.Position.z", "Source": "Engine"}
         }}
       ]}
    ],
    "Renderers": [{"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties"}]
  }]
}`
        doc,_:=strings.replace_all(template,"LOCAL",local ? "true" : "false",context.temp_allocator)
        sys,err:=cooked_niagara_build(doc,alloc)
        if e,bad:=err.?; !testing.expectf(t,!bad,"local=%v: build failed: %v",local,e) {continue}
        if !testing.expect(t,len(sys.emitters)==1&&len(sys.emitters[0].layers)==1) {continue}
        src:=sys.emitters[0].layers[0].program_source
        testing.expectf(t,strings.contains(src,"ctx.birth == 0xFFFFFFFFu"),"local=%v: missing channel birth check",local)
        testing.expectf(t,strings.contains(src,"NV_LOCAL && nv_channel_birth"),"local=%v: missing local channel birth offset",local)
        folder:=".mirai/tmp/cooked-vfx-channel"
        _=os.make_directory_all(folder)
        shader_path,_:=filepath.join({folder,local ? "Cooked_Channel_Local.slang" : "Cooked_Channel_World.slang"},context.temp_allocator)
        _=os.write_entire_file(shader_path,transmute([]u8)src)
        root,cwd_err:=os.get_working_directory(context.temp_allocator)
        if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
            vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
            sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
            res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
            testing.expectf(t,res.error=="" && res.errors==0,"local=%v shader failed: %s %v",local,res.error,res.diagnostics)
            if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"local=%v stages failed: %v",local,res.diagnostics)}
        }
    }
}
