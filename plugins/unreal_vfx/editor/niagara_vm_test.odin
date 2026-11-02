package unreal_vfx_editor

import "core:encoding/endian"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// Bytecode of the VectorVM written by hand: an operation and its operands of 16 bits.
@(private="file")
Code :: struct {bytes:[dynamic]u8}

@(private="file")
op :: proc(c:^Code,o:Niagara_Op,operands:..int) {
    append(&c.bytes,u8(o))
    for v in operands {
        b:[2]u8
        endian.put_u16(b[:],.Little,u16(v))
        append(&c.bytes,b[0],b[1])
    }
}

// An operation over registers: its flags of constant inputs, then its operands.
@(private="file")
calc :: proc(c:^Code,o:Niagara_Op,flags:u8,operands:..int) {
    append(&c.bytes,u8(o),flags)
    for v in operands {
        b:[2]u8
        endian.put_u16(b[:],.Little,u16(v))
        append(&c.bytes,b[0],b[1])
    }
}

// A data set operation: the byte of its operand (0 register, 1 constant), then its operands.
@(private="file")
data :: proc(c:^Code,o:Niagara_Op,constant:u8,operands:..int) {
    append(&c.bytes,u8(o),constant)
    for v in operands {
        b:[2]u8
        endian.put_u16(b[:],.Little,u16(v))
        append(&c.bytes,b[0],b[1])
    }
}

@(private="file")
variable :: proc(name,type:string,value:f32=0) -> Niagara_Variable {
    t,_:=niagara_type_named(type)
    t.name=type
    bytes:=make([]u8,t.bytes,context.temp_allocator)
    if t.bytes==4 {endian.put_f32(bytes,.Little,value)}
    return Niagara_Variable{name=name,type=t,data=bytes}
}

// An update script: Age += DeltaTime, a particle lives while its age is below
// a literal, its id, a constant of a module, and a curve it samples.
@(private="file")
update_fixture :: proc(call:bool) -> Niagara_Vm {
    vm:Niagara_Vm
    vm.usage=.Update
    vm.attributes=slice.clone([]Niagara_Variable{variable("Particles.Position","Vector3f"),variable("Particles.Age","NiagaraFloat"),variable("Particles.Color","LinearColor"),variable("Particles.ID","NiagaraID")},context.temp_allocator)
    // The table: the engine (640 bytes), the drag of a module at 640, the literal 2.0 at 644.
    vm.parameters=slice.clone([]Niagara_Variable{variable("Constants.Emitter.Drag.Drag","NiagaraFloat",0.5)},context.temp_allocator)
    vm.literals=slice.clone([]Niagara_Variable{variable("Literal","NiagaraFloat",2)},context.temp_allocator)
    c:=Code{bytes=make([dynamic]u8,context.temp_allocator)}
    op(&c,.Input_Float,0,3,0)
    calc(&c,.Add,0b10,0,4,1)
    data(&c,.Output_Float,0,0,9,1,3)
    calc(&c,.Mul,0b10,1,640,2)
    calc(&c,.Cmplt,0b10,1,644,3)
    data(&c,.Acquire_Index,0,0,3,9)
    op(&c,.Acquire_Id,0,4,5)
    data(&c,.Output_Int,0,0,9,4,0)
    if call {
        x,_:=niagara_type_named("NiagaraFloat")
        value,_:=niagara_type_named("LinearColor")
        params:=slice.clone([]Niagara_Variable{{name="X",type=x},{name="Value",type=value}},context.temp_allocator)
        vm.functions=slice.clone([]Niagara_Vm_Function{{name="SampleColorCurve",owner="Emitter.ColorCurve",symbol="SampleColorCurve_Emitter_ColorCurve",inputs=2,outputs=4,
            params=params,ins=1,found=true}},context.temp_allocator)
        append(&c.bytes,u8(Niagara_Op.External_Call),0)
        for v in ([]int{644,0x8000|2,6,7,8,0xFFFF}) {
            b:[2]u8
            endian.put_u16(b[:],.Little,u16(v))
            append(&c.bytes,b[0],b[1])
        }
    }
    op(&c,.Done)
    vm.code=c.bytes[:]
    return vm
}

// The bytecode of a script becomes the parameter map it reads and writes,
// its statements over registers and SimulateMain, in the shape of the
// translator's HLSL for the VM.
@(test)
niagara_bytecode_decompiles_to_the_shape_of_the_translator :: proc(t:^testing.T) {
    vm:=update_fixture(true)
    problems:=make([dynamic]string,context.temp_allocator)
    text,ok:=niagara_vm_hlsl(&vm,&problems)
    testing.expect(t,ok && len(problems)==0,"the fixture decompiles without problems")
    for line in ([]string{
        "    v0 = asuint(Context.Map.Particles.Age);",
        "    v1 = asuint(asfloat(v0) + asfloat(asuint(Context.Map.Engine.DeltaTime)));",
        "    Context.Map.Particles.Age = asfloat(v1);",
        "    v2 = asuint(asfloat(v1) * asfloat(asuint(Constants_Emitter_Drag_Drag)));",
        "    v3 = ((asfloat(v1) < asfloat(0x40000000u)) ? 0xFFFFFFFFu : 0u);",
        "    Context.Map.DataInstance.Alive = (v3 != 0u);",
        "    v4 = asuint(niagara_id.x);",
        "    Context.Map.Particles.ID.Index = asint(v4);",
        "void SampleColorCurve_Emitter_ColorCurve(float In_X, out float4 Out_Value);",
        "        a0 = asfloat(v2);",
        "        SampleColorCurve_Emitter_ColorCurve(a0, a1);",
        "        v8 = asuint(a1.z);",
        "    Context.Map.Engine.DeltaTime = Engine_DeltaTime;",
        "    Context.Map.Particles.Age = InputDataFloat(0, 3);",
        "    OutputDataFloat(0, 3, TmpWriteIndex, Context.Map.Particles.Age);",
        "float Constants_Emitter_Drag_Drag;",
    }) {
        testing.expectf(t,strings.contains(text,line),"the decompiled text has %q:\n%s",line,text)
    }
    // The unused fourth output of the curve is not written.
    testing.expect(t,!strings.contains(text,"a1.w"))
    items:=hlsl_items(hlsl_preprocess(text,niagara_defines(0,0)))
    kinds:=make(map[string]Hlsl_Kind,context.temp_allocator)
    bodies:=make(map[string]string,context.temp_allocator)
    for item in items {kinds[item.name]=item.kind;bodies[item.name]=item.body}
    testing.expect(t,kinds["Simulate"]==.Function && kinds["SimulateMain"]==.Function)
    testing.expect(t,kinds["SampleColorCurve_Emitter_ColorCurve"]==.Prototype)
    testing.expect(t,kinds["Constants_Emitter_Drag_Drag"]==.Variable)
    names:=make([dynamic]string,context.temp_allocator)
    for f in hlsl_fields(bodies["FParamMap0_Particles"]) {append(&names,f.name)}
    testing.expectf(t,strings.join(names[:],",",context.temp_allocator)=="Age,ID",
        "the particles of the map are those the script reads and writes: %v",names[:])
    testing.expect(t,strings.contains(bodies["FParamMap0"],"FParamMap0_DataInstance DataInstance;"))
}

// Bytecode the translation cannot read refuses the script and says why.
@(test)
niagara_bytecode_it_cannot_read_is_refused :: proc(t:^testing.T) {
    vm:=update_fixture(false)
    vm.code=[]u8{u8(Niagara_Op.Add),0,1,0}
    problems:=make([dynamic]string,context.temp_allocator)
    _,ok:=niagara_vm_hlsl(&vm,&problems)
    testing.expect(t,!ok && len(problems)==1 && strings.contains(problems[0],"ends inside an operation"))
    vm.code=[]u8{200}
    clear(&problems)
    _,ok=niagara_vm_hlsl(&vm,&problems)
    testing.expect(t,!ok && len(problems)==1 && strings.contains(problems[0],"operation 200"))
    // A constant out of its table reads zero, and says so.
    c:=Code{bytes=make([dynamic]u8,context.temp_allocator)}
    calc(&c,.Add,0b01,4000,0,1)
    vm.code=c.bytes[:]
    clear(&problems)
    text,read:=niagara_vm_hlsl(&vm,&problems)
    testing.expect(t,read && strings.contains(text,"asfloat(0u)") && len(problems)==1)
}

// The decompiled scripts of a CPU emitter become a program like the HLSL of
// an older save: the particle loads and stores its attributes, spawn starts
// them, update moves them and kills them, and render gives the material its
// Dynamic Parameters. The program is written to .mirai/tmp/vfx-vm-test for
// `mirai shaders check`.
@(test)
niagara_decompiled_scripts_make_a_program :: proc(t:^testing.T) {
    update:=update_fixture(false)
    spawn:Niagara_Vm
    spawn.usage=.Spawn
    spawn.attributes=update.attributes
    c:=Code{bytes=make([dynamic]u8,context.temp_allocator)}
    op(&c,.Exec_Index,0)
    calc(&c,.I2f,0,0,1)
    data(&c,.Output_Float,0,0,9,1,3)
    data(&c,.Output_Float,1,0,9,4,0)
    op(&c,.Done)
    spawn.code=c.bytes[:]
    problems:=make([dynamic]string,context.temp_allocator)
    spawn_text,spawn_ok:=niagara_vm_hlsl(&spawn,&problems)
    update_text,update_ok:=niagara_vm_hlsl(&update,&problems)
    testing.expect(t,spawn_ok && update_ok && len(problems)==0)
    testing.expect(t,strings.contains(spawn_text,"Context.MapSpawn.Particles.Position.x = asfloat(asuint(Context.MapSpawn.Engine.DeltaTime));"))
    src:=new(Niagara_Source,context.temp_allocator)
    src.spawn=Niagara_Compiled{hlsl=spawn_text,decompiled=true}
    src.update=Niagara_Compiled{hlsl=update_text,decompiled=true}
    src.values.values=make([dynamic]Niagara_Value,context.temp_allocator)
    append(&src.values.values,Niagara_Value{key="Drag.Drag",full="Constants.Emitter.Drag.Drag",values={0=0.5},count=1})
    src.interfaces=make([dynamic]Niagara_Interface,context.temp_allocator)
    e:=Unreal_Emitter{name="Ring",info=UNREAL_PARTICLE_DEFAULTS,source=src}
    sys:Niagara_System
    w:=Niagara_Writer{name="Niagara_Test_Ring",values=&src.values,system=&sys,emitter=&e}
    w.out=strings.builder_make(context.temp_allocator)
    w.interfaces=make([dynamic]Niagara_Di,context.temp_allocator)
    w.problems=make([dynamic]string,context.temp_allocator)
    w.resources=make([dynamic]string,context.temp_allocator)
    w.stage_lines=make([dynamic]string,context.temp_allocator)
    w.spawns=make([dynamic]string,context.temp_allocator)
    w.kept=make([dynamic]Niagara_Kept,context.temp_allocator)
    src.parts=niagara_parts(&w,src)
    // A particle that keeps its second Dynamic Parameter gives it to its material.
    attributes:=make([dynamic]Hlsl_Field,context.temp_allocator)
    append(&attributes,..niagara_attributes(src.parts))
    append(&attributes,Hlsl_Field{"float4","DynamicMaterialParameter1"})
    src.attributes=attributes[:]
    testing.expect(t,len(src.parts)==2 && src.parts[0].entry=="SimulateMapSpawn" && src.parts[1].entry=="Simulate")
    testing.expect(t,niagara_program(&w,src))
    program:=strings.to_string(w.out)
    for line in ([]string{
        "    float Age;",
        "static float Constants_Emitter_Drag_Drag = 0.5;",
        "    p0::niagara_main_before(Context);",
        "    Context.MapSpawn.Engine.DeltaTime = Engine_DeltaTime;",
        "    p1::Simulate(Context);",
        "    if (!Context.Map.DataInstance.Alive) particle.age = 1.0;",
        "    a.Age = Context.Map.Particles.Age;",
        "    visual.data[1] = float4(a.DynamicMaterialParameter1__0, a.DynamicMaterialParameter1__1, a.DynamicMaterialParameter1__2, a.DynamicMaterialParameter1__3);",
        "    visual.given |= 2u;",
    }) {
        testing.expectf(t,strings.contains(program,line),"the program has %q:\n%s",line,program)
    }
    folder:=".mirai/tmp/vfx-vm-test"
    _=os.make_directory_all(folder)
    _=os.write_entire_file(strings.concatenate({folder,"/Niagara_Test_Ring.slang"},context.temp_allocator),transmute([]u8)program)
}

// A literal of the table of constants, its bits.
@(private="file")
literal :: proc(type:string,bits:u32) -> Niagara_Variable {
    t,_:=niagara_type_named(type)
    t.name=type
    bytes:=make([]u8,4,context.temp_allocator)
    endian.put_u32(bytes,.Little,bits)
    return Niagara_Variable{name="Literal",type=t,data=bytes}
}

// A SpawnConditional of the scripts of the system decides the particles each
// entry of a data channel starts in the emitter it names: the program keeps
// its call in words of prepare, gives births the most it asks for each entry
// and ends in initialize those of an entry that fails its condition (100 >
// Height) or of an entry that asked for fewer. The program is written to
// .mirai/tmp/vfx-vm-test for `mirai shaders check`.
@(test)
niagara_spawn_conditional_decides_the_particles_of_each_entry :: proc(t:^testing.T) {
    params :: proc(list:[][2]string) -> []Niagara_Variable {
        out:=make([]Niagara_Variable,len(list),context.temp_allocator)
        for each,i in list {
            type,_:=niagara_type_named(each[1])
            type.name=each[1]
            out[i]={name=each[0],type=type}
        }
        return out
    }
    // The system keeps the age of Ring and, in its update, SpawnConditional(true, Ring, Override,
    // GreaterThan, 1, 3, 100.0) of the literals at 32 and after.
    system:=Niagara_Vm{usage=.System}
    system.attributes=slice.clone([]Niagara_Variable{variable("Ring.Age","NiagaraFloat")},context.temp_allocator)
    system.literals=slice.clone([]Niagara_Variable{
        literal("NiagaraBool",0xFFFFFFFF),literal("NiagaraInt32",2),literal("NiagaraInt32",0),literal("NiagaraInt32",4),
        literal("NiagaraInt32",1),literal("NiagaraInt32",3),literal("NiagaraFloat",transmute(u32)f32(100)),
    },context.temp_allocator)
    system.functions=slice.clone([]Niagara_Vm_Function{{name="SpawnConditional",owner="Ring.SpawnDataChannel",
        symbol="SpawnConditional_Ring_SpawnDataChannel_HeightNiagaraFloat",inputs=8,outputs=0,ins=7,found=true,
        params=params({{"Enable","NiagaraBool"},{"Emitter ID","NiagaraEmitterID"},{"Mode","NiagaraInt32"},{"Operator","NiagaraInt32"},
            {"Min Spawn Count","NiagaraInt32"},{"Max Spawn Count","NiagaraInt32"},{"Height","NiagaraFloat"}})}},context.temp_allocator)
    c:=Code{bytes=make([dynamic]u8,context.temp_allocator)}
    op(&c,.Input_Float,0,0,0)
    data(&c,.Output_Float,0,0,9,0,0)
    op(&c,.Done)
    spawn_code:=slice.clone(c.bytes[:],context.temp_allocator)
    clear(&c.bytes)
    op(&c,.Input_Float,0,0,0)
    data(&c,.Output_Float,0,0,9,0,0)
    append(&c.bytes,u8(Niagara_Op.External_Call),0)
    for v in ([]int{0,32,36,40,44,48,52,56}) {
        b:[2]u8
        endian.put_u16(b[:],.Little,u16(v))
        append(&c.bytes,b[0],b[1])
    }
    op(&c,.Done)
    problems:=make([dynamic]string,context.temp_allocator)
    system.code=spawn_code
    system_spawn,spawn_ok:=niagara_vm_hlsl(&system,&problems)
    system.code=c.bytes[:]
    system_update,update_ok:=niagara_vm_hlsl(&system,&problems)
    // The particles start where GetNDCSpawnData of the emitter puts their exec index.
    spawn:=Niagara_Vm{usage=.Spawn}
    spawn.attributes=update_fixture(false).attributes
    spawn.literals=slice.clone([]Niagara_Variable{literal("NiagaraInt32",2)},context.temp_allocator)
    spawn.functions=slice.clone([]Niagara_Vm_Function{{name="GetNDCSpawnData",owner="Emitter.SpawnDataChannel",
        symbol="GetNDCSpawnData_Emitter_SpawnDataChannel",inputs=3,outputs=3,ins=2,found=true,
        params=params({{"Emitter ID","NiagaraEmitterID"},{"Spawned Particle Exec Index","NiagaraInt32"},
            {"NDC Index","NiagaraInt32"},{"NDC Spawn Index","NiagaraInt32"},{"NDC Spawn Count","NiagaraInt32"}})}},context.temp_allocator)
    clear(&c.bytes)
    op(&c,.Exec_Index,0)
    append(&c.bytes,u8(Niagara_Op.External_Call),0)
    for v in ([]int{0,640,0x8000,1,2,3}) {
        b:[2]u8
        endian.put_u16(b[:],.Little,u16(v))
        append(&c.bytes,b[0],b[1])
    }
    op(&c,.Done)
    spawn.code=c.bytes[:]
    spawn_text,particle_ok:=niagara_vm_hlsl(&spawn,&problems)
    update:=update_fixture(false)
    update_text,_:=niagara_vm_hlsl(&update,&problems)
    if !testing.expectf(t,spawn_ok && update_ok && particle_ok && len(problems)==0,"the fixture decompiles: %v",problems[:]) {return}

    src:=new(Niagara_Source,context.temp_allocator)
    src.spawn=Niagara_Compiled{hlsl=spawn_text,decompiled=true}
    src.update=Niagara_Compiled{hlsl=update_text,decompiled=true}
    src.values.values=make([dynamic]Niagara_Value,context.temp_allocator)
    src.interfaces=make([dynamic]Niagara_Interface,context.temp_allocator)
    e:=Unreal_Emitter{name="Ring",info=UNREAL_PARTICLE_DEFAULTS,source=src,handle=2}
    sys:Niagara_System
    sys.spawn=Niagara_Compiled{hlsl=system_spawn,decompiled=true}
    sys.update=Niagara_Compiled{hlsl=system_update,decompiled=true}
    w:=Niagara_Writer{name="Niagara_Test_Spawner",values=&src.values,system=&sys,emitter=&e}
    w.out=strings.builder_make(context.temp_allocator)
    w.interfaces=make([dynamic]Niagara_Di,context.temp_allocator)
    w.problems=make([dynamic]string,context.temp_allocator)
    w.resources=make([dynamic]string,context.temp_allocator)
    w.stage_lines=make([dynamic]string,context.temp_allocator)
    w.spawns=make([dynamic]string,context.temp_allocator)
    w.kept=make([dynamic]Niagara_Kept,context.temp_allocator)
    w.spawn_rules=make([dynamic]Niagara_Spawn_Rule,context.temp_allocator)
    // The channel of both data interfaces: its first variable, Height.
    channel:=Niagara_Channel{name="NDC_Test",words=2,variables=slice.clone([]Niagara_Channel_Variable{{"Size","NiagaraFloat",0,1},{"Height","NiagaraFloat",1,1}},context.temp_allocator)}
    for name in ([2]string{"Ring.SpawnDataChannel","Emitter.SpawnDataChannel"}) {
        append(&w.interfaces,Niagara_Di{name=name,symbol=niagara_symbol(name),class="DataChannelRead",kind=.Channel_Read,channel=channel})
    }
    src.parts=niagara_parts(&w,src)
    src.attributes=niagara_attributes(src.parts)
    testing.expect(t,niagara_program(&w,src))
    for problem in w.problems {testing.expectf(t,!strings.contains(problem,"SpawnDataChannel"),"the data channel translates: %s",problem)}
    program:=strings.to_string(w.out)
    for line in ([]string{
        "//! prepare",
        "    if (In_EmitterID.ID != 2) return;",
        "    niagara_rule0[2] = uint(In_Operator);",
        "    niagara_rule0[5] = asuint(In_Height);",
        "mirai_vfx_data_word(ctx, NDC_Test, uint(entry), 1u)",
        "    count += int(mirai_vfx_data_count(ctx, NDC_Test)) * niagara_spawn_per(ctx);",
        "niagara_spawn_count(niagara_ctx, Out_NDCIndex);",
        "    if (niagara_spawn_dropped) particle.age = 1.0;",
        "    if (particle.age >= particle.lifetime) return;",
    }) {
        testing.expectf(t,strings.contains(program,line),"the program has %q:\n%s",line,program)
    }
    testing.expect(t,strings.contains(program,"mirai_vfx_state_store(ctx, ") && strings.contains(program,", niagara_rule0[5]);"),"prepare keeps the words of the call")
    folder:=".mirai/tmp/vfx-vm-test"
    _=os.make_directory_all(folder)
    _=os.write_entire_file(strings.concatenate({folder,"/Niagara_Test_Spawner.slang"},context.temp_allocator),transmute([]u8)program)
}
