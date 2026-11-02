package unreal_vfx_editor

import "core:fmt"
import "core:slice"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal_scene "project:plugins/unreal/editor/scene"

// A Vfx program from the HLSL of Niagara's translator (decisions of
// mirai-imports): the code of the modules of an emitter's scripts stays as
// Niagara generated it, each stage in a namespace of its own, and the frame
// around it is the contract of Vfx programs. The scripts compute in the space
// of Unreal (niagara.slang); the particle of Mirai keeps the position and
// velocity of each, in the world, and the Attributes of the program the rest
// of what Niagara keeps of it. The program moves and ages its particles
// itself (`//! moves`): a particle dies when its script says it is no longer
// alive. Each data interface is a function of Mirai over the resources of the
// program (niagara_interfaces.odin).

// What a script is to the program: where its particles start, where they
// move each step, or a simulation stage.
Niagara_Role :: enum u8 {Spawn,Update,Stage}

// A preprocessed text of a script for one stage index, read.
Niagara_Part :: struct {
    role:Niagara_Role,
    stage:int,             // its index among the stages of the script; a stage of the program from 1
    items:[]Hlsl_Item,
    map_name:string,       // the field of FSimulationContext it runs on: MapSpawn, MapUpdate, Map, MapSimStage1_X
    entry:string,          // the function that runs it
    info:Niagara_Stage_Info,
    vm:bool,               // a script of the VM: its data interfaces take an instance first
}

// A program being written.
Niagara_Writer :: struct {
    d:^level.Document,
    name:string,                 // of the program and its namespace
    out:strings.Builder,
    interfaces:[dynamic]Niagara_Di,
    values:^Niagara_Values,      // the parameters the scripts keep, by name
    problems:[dynamic]string,
    local:bool,                  // the particles of the emitter are in the space of the system
    resources:[dynamic]string,   // the lines that declare them, in order
    stage_lines:[dynamic]string, // `//! stage` lines
    system:^Niagara_System,
    emitter:^Unreal_Emitter,
    state:map[string]Niagara_State, // each global of the parts the scripts of the system compute
    scene:^unreal_scene.Context, // what the import writes assets with
    spawns:[dynamic]string,      // the spawn infos of the emitter the scripts of the system compute
    kept:[dynamic]Niagara_Kept,  // what prepare keeps of the state, in its words
    channel_spawn:string,        // the data channel whose entries start its particles; "" none
    spawn_rules:[dynamic]Niagara_Spawn_Rule, // the SpawnConditional calls of the scripts of the system
}

// The parts of the scripts of an emitter: the spawn and update of one GPU
// script and each of its stages, or the spawn and update scripts of the VM.
@(private)
niagara_parts :: proc(w:^Niagara_Writer,src:^Niagara_Source) -> []Niagara_Part {
    parts:=make([dynamic]Niagara_Part,context.temp_allocator)
    if script,ok:=src.gpu.?;ok {
        count:=max(niagara_stage_count(script.hlsl),1)
        for k in 0..<count {
            info:Niagara_Stage_Info
            for each in script.stages {
                if niagara_stage_named(script.hlsl,k)==each.name {info=each}
            }
            dispatch:=i64(0)
            if k>0 && info.source==.Interface {dispatch=niagara_dispatch(w,info.over)}
            items:=hlsl_items(hlsl_preprocess(script.hlsl,niagara_defines(k,dispatch)))
            if k==0 {
                append(&parts,Niagara_Part{role=.Spawn,stage=0,items=items,map_name="MapSpawn",entry="SimulateMapSpawn",info=info})
                append(&parts,Niagara_Part{role=.Update,stage=0,items=items,map_name="MapUpdate",entry="SimulateMapUpdate",info=info})
            } else {
                entry:=""
                for item in items {
                    if item.kind==.Function && strings.has_prefix(item.name,fmt.tprintf("SimulateMapSimStage%d_",k)) {entry=item.name}
                }
                if entry=="" {continue}
                append(&parts,Niagara_Part{role=.Stage,stage=k,items=items,map_name=entry[len("Simulate"):],entry=entry,info=info})
            }
        }
        return parts[:]
    }
    for script,role in ([2]Maybe(Niagara_Compiled){src.spawn,src.update}) {
        compiled,ok:=script.?
        if !ok {continue}
        items:=hlsl_items(hlsl_preprocess(compiled.hlsl,niagara_defines(0,0)))
        if role==0 {
            append(&parts,Niagara_Part{role=.Spawn,items=items,map_name="MapSpawn",entry="SimulateMapSpawn",vm=true})
        } else {
            entry,map_name:="Simulate","Map"
            for item in items {
                if item.kind==.Function && item.name=="SimulateMapUpdate" {entry,map_name="SimulateMapUpdate","MapUpdate"}
            }
            append(&parts,Niagara_Part{role=.Update,items=items,map_name=map_name,entry=entry,vm=true})
        }
    }
    return parts[:]
}

// The program of an emitter from the parts of its scripts.
@(private)
niagara_program :: proc(w:^Niagara_Writer,src:^Niagara_Source) -> bool {
    parts:=src.parts
    if len(parts)==0 {return false}
    for script in ([2]Maybe(Niagara_Compiled){w.system.spawn,w.system.update}) {
        if compiled,ok:=script.?;ok {niagara_interfaces_add(w,compiled.interfaces)}
    }
    niagara_interfaces_resolve(w)
    niagara_stages_declare(w,parts)
    body:=strings.builder_make(context.temp_allocator)
    niagara_system_write(w,&body)
    for &part,index in parts {
        // Spawn and update of a GPU script share its text: one namespace, that of the spawn.
        if niagara_shares(parts,index) {continue}
        shared:=index+1<len(parts) && niagara_shares(parts,index+1)
        niagara_part_write(w,&body,&part,fmt.tprintf("p%d",index),shared?&parts[index+1]:nil)
    }
    // What decides the particles of each entry of its data channel, through words prepare keeps.
    spawning:=strings.builder_make(context.temp_allocator)
    niagara_spawn_write(w,&spawning)
    s:=&w.out
    fmt.sbprintf(s,"//! mirai vfx %s\n//! moves\n",w.name)
    if len(w.spawns)>0 || w.channel_spawn!="" {strings.write_string(s,"//! births\n")}
    if len(w.kept)>0 {strings.write_string(s,"//! prepare\n")}
    for line in w.resources {fmt.sbprintf(s,"%s\n",line)}
    for line in w.stage_lines {fmt.sbprintf(s,"%s\n",line)}
    fmt.sbprintf(s,"// Translated from the HLSL Niagara generated for an emitter (unreal_vfx/editor, niagara_program.odin).\n#include \"niagara.slang\"\nnamespace %s {{\nstruct Parameters {{float unused;}};\n",w.name)
    // One field a component: another program finds an attribute by its word.
    strings.write_string(s,"struct Attributes {\n")
    if len(src.attributes)==0 {strings.write_string(s,"    uint unused;\n")}
    for attribute in src.attributes {
        scalar,count:=niagara_components(attribute.type)
        if count==1 {fmt.sbprintf(s,"    %s %s;\n",scalar,attribute.name);continue}
        for i in 0..<count {fmt.sbprintf(s,"    %s %s__%d;\n",scalar,attribute.name,i)}
    }
    strings.write_string(s,"};\n")
    strings.write_string(s,strings.to_string(spawning))
    strings.write_string(s,strings.to_string(body))
    niagara_entries_write(w,s,parts)
    // The scripts of the system once a frame for each emitter, and what the parts read of them.
    if len(w.kept)>0 {
        strings.write_string(s,"void prepare(Mirai_Vfx_Context ctx, Parameters p) {\n    niagara_begin(ctx, 0u, uint3(0u));\n    su::niagara_run(ctx);\n")
        for k in w.kept {
            scalar,count:=niagara_components(k.type)
            axes:="xyzw"
            for i in 0..<count {
                part:=k.value if count==1 else fmt.tprintf("%s.%c",k.value,axes[i]) if count<=4 else fmt.tprintf("%s[%d][%d]",k.value,i/4,i%4)
                word:=fmt.tprintf("asuint(%s)",part)
                if scalar=="bool" {word=fmt.tprintf("(%s ? 1u : 0u)",part)}
                if scalar=="uint" {word=part}
                fmt.sbprintf(s,"    mirai_vfx_state_store(ctx, %du, %s);\n",k.word+i,word)
            }
        }
        strings.write_string(s,"}\n")
    }
    if len(w.spawns)>0 || w.channel_spawn!="" {
        strings.write_string(s,"uint births(Mirai_Vfx_Context ctx, Parameters p) {\n    niagara_begin(ctx, 0u, uint3(0u));\n    int count = 0;\n")
        // prepare ran the scripts of the system in this thread just before.
        if len(w.spawns)>0 && len(w.kept)==0 {strings.write_string(s,"    su::niagara_run(ctx);\n")}
        if execution,known:=w.state["Emitter_ExecutionState"];known && len(w.spawns)>0 {fmt.sbprintf(s,"    if (%s != 0) return 0u;\n",execution.value)}
        for at in w.spawns {fmt.sbprintf(s,"    count += max(%s.Count, 0);\n",at)}
        // A program that spawns from a data channel: its particles for each entry of the frame.
        if w.channel_spawn!="" {fmt.sbprintf(s,"    count += int(mirai_vfx_data_count(ctx, %s)) * niagara_spawn_per(ctx);\n",w.channel_spawn)}
        strings.write_string(s,"    return uint(count);\n}\n")
    }
    strings.write_string(s,"}\n")
    return true
}

// The scalar type and components of a type an attribute keeps.
@(private)
niagara_components :: proc(type:string) -> (scalar:string,count:int) {
    if type=="float4x4" {return "float",16}
    last:=type[len(type)-1]
    if last>='2' && last<='4' {return type[:len(type)-1],int(last-'0')}
    return type,1
}

// An attribute as a value of its type, from its fields.
@(private)
niagara_attr_get :: proc(prefix,name,type:string) -> string {
    scalar,count:=niagara_components(type)
    if count==1 {return fmt.tprintf("%s.%s",prefix,name)}
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"%s(",type)
    for i in 0..<count {fmt.sbprintf(&b,"%s%s.%s__%d",i>0?", ":"",prefix,name,i)}
    strings.write_byte(&b,')')
    _=scalar
    return strings.to_string(b)
}

// Stores a value of the type of an attribute into its fields.
@(private)
niagara_attr_set :: proc(out:^strings.Builder,prefix,name,type,value:string) {
    _,count:=niagara_components(type)
    if count==1 {fmt.sbprintf(out,"    %s.%s = %s;\n",prefix,name,value);return}
    axes:="xyzw"
    for i in 0..<count {fmt.sbprintf(out,"    %s.%s__%d = (%s).%c;\n",prefix,name,i,value,axes[i])}
}

// The word of the Attributes of an emitter where an attribute starts, and its type.
@(private)
niagara_attr_word :: proc(attributes:[]Hlsl_Field,name:string) -> (word:int,type:string,ok:bool) {
    for a in attributes {
        _,count:=niagara_components(a.type)
        if a.name==name {return word,a.type,true}
        word+=count
    }
    return 0,"",false
}

// The `//! stage` lines of the simulation stages: over the grid a stage
// iterates, or over the particles, writing the grids it outputs to.
@(private)
niagara_stages_declare :: proc(w:^Niagara_Writer,parts:[]Niagara_Part) {
    for &part in parts {
        if part.role!=.Stage {continue}
        line:=strings.builder_make(context.temp_allocator)
        over:=""
        if part.info.source==.Interface {
            if di,ok:=niagara_interface_named(w,part.info.over);ok && di.resource!="" && (di.kind==.Grid || di.kind==.Render_Target || di.kind==.Neighbors || di.kind==.Raster) {over=di.resource}
            if over=="" {
                append(&w.problems,fmt.tprintf("the stage %s goes over %s, which is not a grid of Mirai: it goes over the particles",part.info.name,part.info.over))
                part.info.source=.Particles
            }
        } else if part.info.source==.Direct {
            append(&w.problems,fmt.tprintf("the stage %s sets its own count of threads: it goes over the particles",part.info.name))
            part.info.source=.Particles
        }
        fmt.sbprintf(&line,"//! stage s%d over %s",part.stage,over!=""?over:"particles")
        if part.info.iterations>1 {fmt.sbprintf(&line," iterations %d",min(part.info.iterations,64))}
        writes:=make([dynamic]string,context.temp_allocator)
        for output in part.info.outputs {
            if output==part.info.over {continue}
            if di,ok:=niagara_interface_named(w,output);ok && di.resource!="" && di.kind!=.Particles {append(&writes,di.resource)}
        }
        if len(writes)>0 {fmt.sbprintf(&line," writes %s",strings.join(writes[:],",",context.temp_allocator))}
        append(&w.stage_lines,strings.to_string(line))
    }
}

// Whether a part is the update of a GPU script whose spawn is the part before.
@(private)
niagara_shares :: proc(parts:[]Niagara_Part,index:int) -> bool {
    part:=parts[index]
    return part.role==.Update && !part.vm && index>0 && parts[index-1].role==.Spawn && parts[index-1].stage==part.stage
}

// The defines a stage of a script is preprocessed with.
@(private)
niagara_defines :: proc(stage:int,dispatch:i64) -> map[string]i64 {
    defines:=make(map[string]i64,context.temp_allocator)
    defines["SimulationStageIndex"]=i64(stage)
    defines["GPU_SIMULATION"]=1
    defines["NIAGARA_DISPATCH_TYPE_ONE_D"]=0
    defines["NIAGARA_DISPATCH_TYPE_TWO_D"]=1
    defines["NIAGARA_DISPATCH_TYPE_THREE_D"]=2
    defines["NIAGARA_DISPATCH_TYPE_CUSTOM"]=3
    defines["NIAGARA_DISPATCH_TYPE"]=dispatch
    return defines
}

// How many stages the header of a GPU script lists (// SimStage[k] = Name).
@(private)
niagara_stage_count :: proc(hlsl:string) -> int {
    count:=0
    rest:=hlsl
    for line in strings.split_lines_iterator(&rest) {
        if !strings.has_prefix(line,"// SimStage[") {
            if count>0 && !strings.has_prefix(line,"//") {break}
            continue
        }
        count+=1
    }
    return count
}

@(private)
niagara_stage_named :: proc(hlsl:string,k:int) -> string {
    prefix:=fmt.tprintf("// SimStage[%d] = ",k)
    rest:=hlsl
    for line in strings.split_lines_iterator(&rest) {
        if strings.has_prefix(line,prefix) {return strings.trim_space(line[len(prefix):])}
        if !strings.has_prefix(line,"//") && line!="" {break}
    }
    return ""
}

// Mirai's particle keeps these attributes of Niagara: the rest are Attributes.
@(private)
NIAGARA_OWN :: [?]string{"Position","Velocity","ID","UniqueID"}

// The attributes the parts of an emitter read or write, flattened
// (Previous.Position: Previous_Position), once each, in the order they come.
@(private)
niagara_attributes :: proc(parts:[]Niagara_Part) -> []Hlsl_Field {
    list:=make([dynamic]Hlsl_Field,context.temp_allocator)
    for &part in parts {
        structs:=make(map[string]string,context.temp_allocator)
        for item in part.items {if item.kind==.Struct {structs[item.name]=item.body}}
        niagara_flatten(&list,structs,"FParamMap0_Particles","",0)
    }
    return list[:]
}

@(private)
niagara_flatten :: proc(list:^[dynamic]Hlsl_Field,structs:map[string]string,type,prefix:string,depth:int) {
    body,found:=structs[type]
    if !found || depth>4 {return}
    for field in hlsl_fields(body) {
        name:=prefix==""?field.name:strings.concatenate({prefix,"_",field.name},context.temp_allocator)
        if prefix=="" {
            own:=false
            for o in NIAGARA_OWN {own||=field.name==o}
            if own {continue}
        }
        if _,nested:=structs[field.type];nested {
            niagara_flatten(list,structs,field.type,name,depth+1)
            continue
        }
        kind:=niagara_attribute_type(field.type)
        if kind=="" {continue}
        known:=false
        for a in list {known||=a.name==name}
        if !known {append(list,Hlsl_Field{type=kind,name=strings.clone(name,context.temp_allocator)})}
    }
}

// The type an attribute keeps a value of a type of Niagara's HLSL in; "" for
// one it does not keep.
@(private)
niagara_attribute_type :: proc(type:string) -> string {
    switch type {
    case "float","float2","float3","float4","int","int2","int3","int4","uint","uint2","uint3","uint4","bool": return type
    case "half": return "float"
    case "half2","half3","half4": return strings.concatenate({"float",type[4:]},context.temp_allocator)
    case "NiagaraID": return "int2"
    }
    return ""
}

// A part of the program: its stage of the script in a namespace, with the
// parameters of the engine as values of the thread, its data interfaces as
// functions over Mirai's resources, and how its particles load from and
// store into Mirai's.
@(private)
niagara_part_write :: proc(w:^Niagara_Writer,out:^strings.Builder,part:^Niagara_Part,ns:string,update:^Niagara_Part) {
    fmt.sbprintf(out,"namespace %s {{\n",ns)
    structs:=make(map[string]string,context.temp_allocator)
    for item in part.items {if item.kind==.Struct {structs[item.name]=item.body}}
    // What the frame calls of the script, and the names its SimulateMain uses where the frame
    // copies its statements (a script of the VM): what they do not reach is not written.
    roots:=make([dynamic]string,context.temp_allocator)
    append(&roots,"FSimulationContext","InitConstants","InitSpawnVariables","ConditionalInterpolateParameters","ReadDataSets","WriteDataSets")
    for each in ([2]^Niagara_Part{part,update}) {
        if each==nil {continue}
        append(&roots,each.entry,strings.concatenate({"SetupFromIterationSource_",each.map_name},context.temp_allocator),strings.concatenate({"TeardownFromIterationSource_",each.map_name},context.temp_allocator))
    }
    if main:=niagara_function(part,"SimulateMain");main!=nil && part.vm {
        append(&roots,..hlsl_words(main.body))
    }
    used:=hlsl_reached(part.items,roots[:])
    // The parameters of the engine and the system the script reads: values of the thread that
    // niagara_setup gives.
    globals:=make([dynamic]Hlsl_Field,context.temp_allocator)
    for item in part.items {
        // Those of a GPU script are in cbuffers; a script of the VM declares them as globals.
        switch item.kind {
        case .Cbuffer:
            for field in hlsl_fields(item.body) {
                // An array keeps its size in its name.
                bracket:=strings.index_byte(field.name,'[')
                if (bracket<0?field.name:field.name[:bracket]) in used {append(&globals,field)}
            }
        case .Variable:
            text:=strings.trim_space(item.text)
            if strings.has_prefix(text,"static") || strings.contains(text,"=") || strings.contains(text,"[") {continue}
            for field in hlsl_fields(text) {
                if field.name not_in used {continue}
                if niagara_attribute_type(field.type)!="" || field.type=="float4x4" || field.type=="float3x3" {append(&globals,field)}
            }
        case .Other,.Struct,.Function,.Prototype:
        }
    }
    for field in globals {
        value,baked:=niagara_constant(w,field)
        if baked {
            fmt.sbprintf(out,"static %s %s = %s;\n",field.type,field.name,value)
        } else {
            fmt.sbprintf(out,"static %s %s;\n",field.type,field.name)
        }
    }
    // The declarations of the script, without its frame and its data interfaces.
    dropped:=[?]string{"SimulateMainComputeCS","SimulateMain","LoadUpdateVariables","StoreUpdateVariables","CopyInstance"}
    calls:=make([dynamic]Hlsl_Item,context.temp_allocator)
    for item in part.items {
        reached:=item.name in used
        switch item.kind {
        case .Struct:
            // The context a data channel of Unreal reads its buffers through is of the channel.
            if strings.has_prefix(item.name,"FNDCAccessContext_") || !reached {continue}
            fmt.sbprintf(out,"%s\n",item.text)
        case .Cbuffer,.Other:
        case .Variable:
            if reached && strings.has_prefix(strings.trim_space(item.text),"static") && item.name!="RandomCounterDeterministic" {fmt.sbprintf(out,"%s\n",item.text)}
        case .Prototype:
            if _,is_interface:=niagara_interface_of(w,item.name);is_interface {append(&calls,item)}
        case .Function:
            if slice.contains(dropped[:],item.name) || !reached {continue}
            if _,is_interface:=niagara_interface_of(w,item.name);is_interface {continue}
            fmt.sbprintf(out,"%s\n",niagara_casts(item))
        }
    }
    // The data interfaces it calls. One nothing calls is still translated: what it says of the
    // program (the data channel its births come from) holds.
    unused:=strings.builder_make(context.temp_allocator)
    for call in calls {niagara_call_write(w,call.name in used?out:&unused,part,call)}
    if part.vm {niagara_main_globals_write(out,part)}
    niagara_setup_write(w,out,globals[:])
    niagara_moves_write(w,out,structs,part)
    if update!=nil {niagara_moves_write(w,out,structs,update)}
    strings.write_string(out,"}\n")
}

// A parameter of the system or a module that the scripts keep: its value,
// written in the type of the field; false for one of the engine.
@(private)
niagara_constant :: proc(w:^Niagara_Writer,field:Hlsl_Field) -> (value:string,ok:bool) {
    name:=field.name
    if strings.has_prefix(name,"PREV_") {name=name[len("PREV_"):]}
    if strings.has_prefix(name,"Engine_") || name=="Emitter_Age" {return}
    for &each in w.values.values {
        // A script of the GPU names the constants of its emitter after Emitter, the store after the emitter.
        if niagara_symbol(each.full)!=name && niagara_symbol(niagara_emitter_alias(each.full))!=name {continue}
        return niagara_literal(field.type,each.values[:each.count]),true
    }
    // A parameter of the emitter no script writes (Emitter.AlphaScale): the default its scripts
    // compiled after the name of its handle.
    if strings.has_prefix(name,"Emitter_") && w.emitter!=nil {
        own:=strings.concatenate({niagara_symbol(w.emitter.name),name[len("Emitter"):]},context.temp_allocator)
        for &each in w.values.values {
            if niagara_symbol(each.full)==own {return niagara_literal(field.type,each.values[:each.count]),true}
        }
    }
    return niagara_literal(field.type,nil),true
}

// A value of a type of HLSL from its numbers; zero without them.
@(private)
niagara_literal :: proc(type:string,values:[]f32) -> string {
    count:=1
    switch type {
    case "float2","int2","uint2","bool2": count=2
    case "float3","int3","uint3","bool3": count=3
    case "float4","int4","uint4","bool4": count=4
    case "float4x4": count=16
    }
    scalar:=strings.trim_right(type,"234x")
    // A struct of the scripts starts at zero.
    if scalar!="float" && scalar!="int" && scalar!="uint" && scalar!="bool" && scalar!="half" {return fmt.tprintf("(%s)0",type)}
    b:=strings.builder_make(context.temp_allocator)
    if count>1 {fmt.sbprintf(&b,"%s(",type)}
    for i in 0..<count {
        if i>0 {strings.write_string(&b,", ")}
        v:=i<len(values)?values[i]:0
        switch scalar {
        case "int","uint": fmt.sbprintf(&b,"%d",i64(v))
        case "bool": strings.write_string(&b,v!=0?"true":"false")
        case: fmt.sbprintf(&b,"%v",v)
        }
    }
    if count>1 {strings.write_byte(&b,')')}
    return strings.to_string(b)
}

// Gives the parameters of the engine the values of Mirai's context.
@(private)
niagara_setup_write :: proc(w:^Niagara_Writer,out:^strings.Builder,globals:[]Hlsl_Field) {
    strings.write_string(out,"void niagara_setup(Mirai_Vfx_Context ctx) {\n")
    strings.write_string(out,"    float4x4 local = niagara_local_to_world(ctx.world);\n    float dt = ctx.delta_time;\n")
    // A value of a vector of four given to a global of three takes its first three.
    assign :: proc(out:^strings.Builder,globals:[]Hlsl_Field,name,value:string) {
        for field in globals {
            target:=field.name
            if target!=name && target!=strings.concatenate({"PREV_",name},context.temp_allocator) {continue}
            converted:=value
            if (field.type=="float3" || field.type=="int3") && strings.has_prefix(value,"float4(") {converted=fmt.tprintf("(%s).xyz",value)}
            fmt.sbprintf(out,"    %s = %s;\n",target,converted)
        }
    }
    assign(out,globals,"Engine_DeltaTime","dt")
    assign(out,globals,"Engine_InverseDeltaTime","dt > 0.0 ? 1.0 / dt : 0.0")
    assign(out,globals,"Engine_Time","ctx.time")
    assign(out,globals,"Engine_RealTime","ctx.time")
    assign(out,globals,"Engine_QualityLevel","3")
    assign(out,globals,"Engine_System_Age","ctx.emitter_age")
    assign(out,globals,"Emitter_Age","ctx.emitter_age")
    assign(out,globals,"Engine_System_TickCount","int(ctx.time * 60.0)")
    assign(out,globals,"Engine_System_NumEmitters","1")
    assign(out,globals,"Engine_System_NumEmittersAlive","1")
    assign(out,globals,"Engine_Emitter_TotalSpawnedParticles","int(ctx.born)")
    assign(out,globals,"Engine_Emitter_SpawnCountScale","1.0")
    assign(out,globals,"Engine_Emitter_InstanceSeed","int(ctx.emitter)")
    assign(out,globals,"Engine_Owner_SystemLocalToWorld","local")
    assign(out,globals,"Engine_Owner_SystemWorldToLocal","niagara_inverse(local)")
    assign(out,globals,"Engine_Owner_SystemLocalToWorldTransposed","transpose(local)")
    assign(out,globals,"Engine_Owner_SystemWorldToLocalTransposed","transpose(niagara_inverse(local))")
    assign(out,globals,"Engine_Owner_SystemLocalToWorldNoScale","local")
    assign(out,globals,"Engine_Owner_SystemWorldToLocalNoScale","niagara_inverse(local)")
    assign(out,globals,"Engine_Owner_Rotation","niagara_quaternion((float3x3)local)")
    assign(out,globals,"Engine_Owner_Position","float4(local[3].xyz, 0.0)")
    assign(out,globals,"Engine_Owner_Velocity","float4(0.0)")
    assign(out,globals,"Engine_Owner_SystemXAxis","float4(normalize(local[0].xyz), 0.0)")
    assign(out,globals,"Engine_Owner_SystemYAxis","float4(normalize(local[1].xyz), 0.0)")
    assign(out,globals,"Engine_Owner_SystemZAxis","float4(normalize(local[2].xyz), 0.0)")
    assign(out,globals,"Engine_Owner_Scale","float4(1.0, 1.0, 1.0, 0.0)")
    assign(out,globals,"Engine_Owner_LWCTile","float4(0.0)")
    assign(out,globals,"Engine_Owner_ExecutionState","0")
    assign(out,globals,"Engine_Owner_LODDistance","1000.0")
    assign(out,globals,"Engine_Owner_LODDistanceFraction","0.0")
    if w.state!=nil {
        // What the scripts of the system computed, as prepare kept it; what does not fit, computed here.
        lines:=strings.builder_make(context.temp_allocator)
        run:=false
        for field in globals {
            // The value of the frame before is the same: nothing of the state is kept.
            name:=strings.trim_prefix(field.name,"PREV_")
            state,ok:=w.state[name]
            if !ok {continue}
            value,kept:=niagara_state_kept(w,name,state)
            if !kept {value,run=state.value,true}
            // A global of the parts keeps a vector of three as one of four.
            if field.type=="float4" && state.type=="float3" {value=fmt.tprintf("float4(%s, 0.0)",value)}
            if field.type=="float3" && state.type=="float4" {value=fmt.tprintf("(%s).xyz",value)}
            fmt.sbprintf(&lines,"    %s = %s;\n",field.name,value)
        }
        if run {strings.write_string(out,"    su::niagara_run(ctx);\n")}
        strings.write_string(out,strings.to_string(lines))
    }
    strings.write_string(out,"}\n")
}

// How the particles of a part load from Mirai's and store back: the position
// and velocity of the particle in the space of Unreal (that of the system
// when the emitter is local), the attributes of Niagara from the Attributes,
// the id from the slot and seed of the particle.
@(private)
niagara_moves_write :: proc(w:^Niagara_Writer,out:^strings.Builder,structs:map[string]string,part:^Niagara_Part) {
    body,found:=structs["FParamMap0_Particles"]
    if !found {
        fmt.sbprintf(out,"void niagara_load_%s(Mirai_Vfx_Context ctx, inout FSimulationContext Context, Mirai_Vfx_Particle particle, Attributes a) {{}}\n",part.map_name)
        fmt.sbprintf(out,"void niagara_store_%s(Mirai_Vfx_Context ctx, FSimulationContext Context, inout Mirai_Vfx_Particle particle, inout Attributes a) {{}}\n",part.map_name)
        return
    }
    load,store:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    P:=fmt.tprintf("Context.%s.Particles",part.map_name)
    walk :: proc(w:^Niagara_Writer,load,store:^strings.Builder,structs:map[string]string,body,path,flat:string,depth:int) {
        for field in hlsl_fields(body) {
            name:=flat==""?field.name:strings.concatenate({flat,"_",field.name},context.temp_allocator)
            at:=strings.concatenate({path,".",field.name},context.temp_allocator)
            if flat=="" {
                switch field.name {
                case "Position":
                    fmt.sbprintf(load,"    %s = w.local ? mul(float4(niagara_point(particle.position), 1.0), w.to_local).xyz : niagara_point(particle.position);\n",at)
                    fmt.sbprintf(store,"    particle.position = mirai_point(w.local ? mul(float4(%s, 1.0), w.to_world).xyz : %s);\n",at,at)
                    continue
                case "Velocity":
                    fmt.sbprintf(load,"    %s = w.local ? mul(float4(niagara_vector(particle.velocity), 0.0), w.to_local).xyz : niagara_vector(particle.velocity);\n",at)
                    fmt.sbprintf(store,"    particle.velocity = mirai_vector(w.local ? mul(float4(%s, 0.0), w.to_world).xyz : %s);\n",at,at)
                    continue
                case "ID":
                    fmt.sbprintf(load,"    %s.Index = niagara_id.x; %s.AcquireTag = niagara_id.y;\n",at,at)
                    continue
                case "UniqueID":
                    fmt.sbprintf(load,"    %s = int(particle.seed);\n",at)
                    continue
                }
            }
            if nested,is_struct:=structs[field.type];is_struct {
                if depth<4 {walk(w,load,store,structs,nested,at,name,depth+1)}
                continue
            }
            kind:=niagara_attribute_type(field.type)
            if kind=="" {continue}
            if field.type=="NiagaraID" {
                fmt.sbprintf(load,"    %s.Index = a.%s__0; %s.AcquireTag = a.%s__1;\n",at,name,at,name)
                fmt.sbprintf(store,"    a.%s__0 = %s.Index; a.%s__1 = %s.AcquireTag;\n",name,at,name,at)
                continue
            }
            fmt.sbprintf(load,"    %s = %s;\n",at,niagara_attr_get("a",name,kind))
            niagara_attr_set(store,"a",name,kind,at)
        }
    }
    walk(w,&load,&store,structs,body,P,"",0)
    // Update starts each previous value (Particles.Previous.Position) at the value the frame before left.
    if part.role==.Update {
        own:=make(map[string]bool,context.temp_allocator)
        for field in hlsl_fields(body) {own[field.name]=true}
        for field in hlsl_fields(body) {
            if field.name!="Previous" {continue}
            for previous in hlsl_fields(structs[field.type]) {
                if own[previous.name] {fmt.sbprintf(&load,"    %s.Previous.%s = %s.%s;\n",P,previous.name,P,previous.name)}
            }
        }
    }
    fmt.sbprintf(out,"void niagara_load_%s(Mirai_Vfx_Context ctx, inout FSimulationContext Context, Mirai_Vfx_Particle particle, Attributes a) {{\n    Niagara_Space w = niagara_space(ctx, %v);\n%s}}\n",part.map_name,w.local,strings.to_string(load))
    fmt.sbprintf(out,"void niagara_store_%s(Mirai_Vfx_Context ctx, FSimulationContext Context, inout Mirai_Vfx_Particle particle, inout Attributes a) {{\n    Niagara_Space w = niagara_space(ctx, %v);\n%s}}\n",part.map_name,w.local,strings.to_string(store))
}

// The functions of the contract: initialize runs the spawn script, update
// the update script, and each simulation stage a stage of the program.
@(private)
niagara_entries_write :: proc(w:^Niagara_Writer,s:^strings.Builder,parts:[]Niagara_Part) {
    has :: proc(part:^Niagara_Part,name:string) -> bool {
        for item in part.items {if item.kind==.Function && item.name==name {return true}}
        return false
    }
    alive :: proc(part:^Niagara_Part) -> bool {
        return strings.contains(niagara_struct_body(part,"FParamMap0"),"DataInstance")
    }
    for &part,index in parts {
        ns:=fmt.tprintf("p%d",niagara_shares(parts,index)?index-1:index)
        M:=part.map_name
        switch part.role {
        case .Spawn:
            fmt.sbprintf(s,"void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {{\n    float lead = min(particle.age, 0.0);\n")
            fmt.sbprintf(s,"    niagara_begin(ctx, niagara_exec_index(ctx), uint3(niagara_exec_index(ctx), 0u, 0u));\n    niagara_id.y = int(particle.seed);\n    %s::niagara_setup(ctx);\n",ns)
            fmt.sbprintf(s,"    %s::FSimulationContext Context = (%s::FSimulationContext)0;\n",ns,ns)
            if has(&part,"InitConstants") {fmt.sbprintf(s,"    %s::InitConstants(Context);\n",ns)}
            if has(&part,"InitSpawnVariables") {fmt.sbprintf(s,"    %s::InitSpawnVariables(Context);\n",ns)}
            if part.vm {fmt.sbprintf(s,"    %s::niagara_main_before(Context);\n",ns)}
            fmt.sbprintf(s,"    %s::niagara_load_%s(ctx, Context, particle, a);\n",ns,M)
            if part.vm {fmt.sbprintf(s,"    %s::niagara_main_after(Context);\n",ns)}
            if alive(&part) {fmt.sbprintf(s,"    Context.%s.DataInstance.Alive = true;\n",M)}
            if has(&part,"ConditionalInterpolateParameters") {fmt.sbprintf(s,"    %s::ConditionalInterpolateParameters(Context);\n",ns)}
            fmt.sbprintf(s,"    %s::%s(Context);\n",ns,part.entry)
            fmt.sbprintf(s,"    %s::niagara_store_%s(ctx, Context, particle, a);\n",ns,M)
            // Interpolated, a particle born within the step keeps the part of it before its birth (a
            // negative age): the step moves it less. Otherwise update leaves it as spawn did, as Niagara
            // runs one or the other on a particle in a frame: an age just below zero marks it, and the
            // step still runs update on it.
            if w.emitter.source.interpolated {
                strings.write_string(s,"    particle.age = lead;\n    particle.lifetime = 1.0;\n")
            } else {
                strings.write_string(s,"    particle.age = -1e-6;\n    particle.lifetime = 1.0;\n")
            }
            if alive(&part) {fmt.sbprintf(s,"    if (!Context.%s.DataInstance.Alive) particle.age = 1.0;\n",M)}
            if w.channel_spawn!="" {strings.write_string(s,"    if (niagara_spawn_dropped) particle.age = 1.0;\n")}
            strings.write_string(s,"}\n")
        case .Update:
            fmt.sbprintf(s,"void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {{\n")
            // One that initialize ended dies before this step runs its scripts.
            strings.write_string(s,"    if (particle.age >= particle.lifetime) return;\n")
            if !w.emitter.source.interpolated {strings.write_string(s,"    if (particle.age < 0.0) {\n        particle.age = 0.0;\n        return;\n    }\n")}
            fmt.sbprintf(s,"    niagara_begin(ctx, ctx.particle, uint3(ctx.particle, 0u, 0u));\n    %s::niagara_setup(ctx);\n",ns)
            fmt.sbprintf(s,"    %s::FSimulationContext Context = (%s::FSimulationContext)0;\n",ns,ns)
            if has(&part,"InitConstants") {fmt.sbprintf(s,"    %s::InitConstants(Context);\n",ns)}
            if part.vm {fmt.sbprintf(s,"    %s::niagara_main_before(Context);\n",ns)}
            fmt.sbprintf(s,"    %s::niagara_load_%s(ctx, Context, particle, a);\n",ns,M)
            if part.vm {fmt.sbprintf(s,"    %s::niagara_main_after(Context);\n",ns)}
            if alive(&part) {fmt.sbprintf(s,"    Context.%s.DataInstance.Alive = true;\n",M)}
            if has(&part,"ReadDataSets") {fmt.sbprintf(s,"    %s::ReadDataSets(Context);\n",ns)}
            fmt.sbprintf(s,"    %s::%s(Context);\n",ns,part.entry)
            if has(&part,"WriteDataSets") {fmt.sbprintf(s,"    %s::WriteDataSets(Context);\n",ns)}
            fmt.sbprintf(s,"    %s::niagara_store_%s(ctx, Context, particle, a);\n",ns,M)
            strings.write_string(s,"    particle.age = 0.0;\n    particle.lifetime = 1.0;\n")
            if alive(&part) {fmt.sbprintf(s,"    if (!Context.%s.DataInstance.Alive) particle.age = 1.0;\n",M)}
            strings.write_string(s,"}\n")
        case .Stage:
            setup:=strings.concatenate({"SetupFromIterationSource_",M},context.temp_allocator)
            teardown:=strings.concatenate({"TeardownFromIterationSource_",M},context.temp_allocator)
            gate:=part.info.reset_only?"    if (ctx.emitter_age > 2.0 * max(ctx.delta_time, 1e-3)) return;\n":""
            if part.info.source==.Interface {
                di,_:=niagara_interface_named(w,part.info.over)
                fmt.sbprintf(s,"void s%d(Mirai_Vfx_Cell cell, Parameters p) {{\n    Mirai_Vfx_Context ctx = cell.ctx;\n%s",part.stage,gate)
                fmt.sbprintf(s,"    Mirai_Vfx_Grid g = mirai_vfx_grid(ctx, %s);\n    uint3 along = uint3(cell.index - g.first);\n",di!=nil?di.resource:"0u")
                // The thread of a 2D grid, flat along y, in the order of Niagara.
                thread:=di!=nil && !di.three?"along.xzy":"along"
                fmt.sbprintf(s,"    niagara_begin(ctx, along.x + uint(g.cells.x) * (along.y + uint(g.cells.y) * along.z), %s);\n",thread)
                fmt.sbprintf(s,"    niagara_stage_iteration = ctx.iteration; niagara_stage_iterations = %du;\n",part.info.iterations)
                fmt.sbprintf(s,"    %s::niagara_setup(ctx);\n    %s::FSimulationContext Context = (%s::FSimulationContext)0;\n",ns,ns,ns)
                if has(&part,"InitConstants") {fmt.sbprintf(s,"    %s::InitConstants(Context);\n",ns)}
                if has(&part,setup) {fmt.sbprintf(s,"    %s::%s(Context);\n",ns,setup)}
                fmt.sbprintf(s,"    %s::%s(Context);\n",ns,part.entry)
                if has(&part,teardown) {fmt.sbprintf(s,"    %s::%s(Context);\n",ns,teardown)}
                strings.write_string(s,"}\n")
            } else {
                fmt.sbprintf(s,"void s%d(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {{\n%s",part.stage,gate)
                fmt.sbprintf(s,"    niagara_begin(ctx, ctx.particle, uint3(ctx.particle, 0u, 0u));\n")
                fmt.sbprintf(s,"    niagara_stage_iteration = ctx.iteration; niagara_stage_iterations = %du;\n",part.info.iterations)
                fmt.sbprintf(s,"    %s::niagara_setup(ctx);\n    %s::FSimulationContext Context = (%s::FSimulationContext)0;\n",ns,ns,ns)
                if has(&part,"InitConstants") {fmt.sbprintf(s,"    %s::InitConstants(Context);\n",ns)}
                fmt.sbprintf(s,"    %s::niagara_load_%s(ctx, Context, particle, a);\n",ns,M)
                if alive(&part) {fmt.sbprintf(s,"    Context.%s.DataInstance.Alive = true;\n",M)}
                fmt.sbprintf(s,"    %s::%s(Context);\n",ns,part.entry)
                if part.info.writes_particles {
                    fmt.sbprintf(s,"    %s::niagara_store_%s(ctx, Context, particle, a);\n",ns,M)
                    if alive(&part) {fmt.sbprintf(s,"    if (!Context.%s.DataInstance.Alive) particle.age = 1.0;\n",M)}
                }
                strings.write_string(s,"}\n")
            }
        }
    }
    niagara_render_write(w,s)
}

// The attributes the renderers of Niagara give the Dynamic Parameter of
// index i of their material.
@(private)
NIAGARA_DYNAMIC_PARAMETERS :: [4]string{"DynamicMaterialParameter","DynamicMaterialParameter1","DynamicMaterialParameter2","DynamicMaterialParameter3"}

// What a particle shows: the color, size, sub image and material data of
// Niagara's attributes, where the emitter keeps them.
@(private)
niagara_render_write :: proc(w:^Niagara_Writer,s:^strings.Builder) {
    has :: proc(w:^Niagara_Writer,name,type:string) -> bool {
        for a in w.emitter.source.attributes {if a.name==name && a.type==type {return true}}
        return false
    }
    strings.write_string(s,"void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {\n")
    if has(w,"Color","float4") {fmt.sbprintf(s,"    visual.color = %s;\n",niagara_attr_get("a","Color","float4"))}
    switch {
    // A mesh takes Scale as a factor of its size; a sprite, SpriteSize in centimetres.
    case w.emitter.info.render==.Mesh && has(w,"Scale","float3"): strings.write_string(s,"    visual.size = max(a.Scale__0, max(a.Scale__1, a.Scale__2));\n")
    case has(w,"SpriteSize","float2"): strings.write_string(s,"    visual.size = max(a.SpriteSize__0, a.SpriteSize__1) * 0.01;\n")
    case has(w,"Scale","float3"): strings.write_string(s,"    visual.size = max(a.Scale__0, max(a.Scale__1, a.Scale__2)) * 0.01;\n")
    }
    if has(w,"SubImageIndex","float") {strings.write_string(s,"    visual.frame = a.SubImageIndex;\n")}
    // The Dynamic Parameters of the material: what the renderers bind by default.
    for name,i in NIAGARA_DYNAMIC_PARAMETERS {
        if has(w,name,"float4") {fmt.sbprintf(s,"    visual.data[%d] = %s;\n    visual.given |= %du;\n",i,niagara_attr_get("a",name,"float4"),u32(1)<<uint(i))}
    }
    strings.write_string(s,"}\n")
}

@(private)
niagara_struct_body :: proc(part:^Niagara_Part,name:string) -> string {
    for item in part.items {if item.kind==.Struct && item.name==name {return item.body}}
    return ""
}

// What SimulateMain of a script of the VM gives the parameter map from the
// globals of the engine, before the particle loads, and what it copies of
// the particle (Previous.Position), after: the frame of the translator drops it.
@(private)
niagara_main_globals_write :: proc(out:^strings.Builder,part:^Niagara_Part) {
    before,after:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    for item in part.items {
        if item.kind!=.Function || item.name!="SimulateMain" {continue}
        rest:=item.body
        for line in strings.split_lines_iterator(&rest) {
            text:=strings.trim_space(line)
            if strings.has_prefix(text,"ReadDataSets") {break}
            at:=strings.index(text," = ")
            if !strings.has_prefix(text,"Context.") || at<0 || strings.contains(text,"InputData") || strings.contains(text,".Array.") || strings.contains(text,".Particles.ID.") {continue}
            value:=strings.trim_space(text[at+3:])
            fmt.sbprintf(strings.has_prefix(value,"Context.")?&after:&before,"    %s = %s\n",text[:at],value)
        }
    }
    fmt.sbprintf(out,"void niagara_main_before(inout FSimulationContext Context) {{\n%s}}\n",strings.to_string(before))
    fmt.sbprintf(out,"void niagara_main_after(inout FSimulationContext Context) {{\n%s}}\n",strings.to_string(after))
}

// A function whose statements give a vector out parameter a vector of
// another size: HLSL takes its first components, Slang asks for the cast.
@(private)
niagara_casts :: proc(item:Hlsl_Item) -> string {
    outs:=make(map[string]string,context.temp_allocator)
    for p in hlsl_params(item.params) {
        if !strings.has_prefix(p.type,"out ") && !strings.has_prefix(p.type,"inout ") {continue}
        type:=strings.trim_prefix(strings.trim_prefix(p.type,"out "),"inout ")
        if _,count:=niagara_components(type);count>1 && niagara_attribute_type(type)!="" {outs[p.name]=type}
    }
    if len(outs)==0 {return item.text}
    b:=strings.builder_make(context.temp_allocator)
    rest:=item.text
    for line in strings.split_lines_after_iterator(&rest) {
        text:=strings.trim_space(line)
        at:=strings.index(text," = ")
        if at>0 && strings.has_suffix(text,";") {
            if type,found:=outs[text[:at]];found {
                indent:=line[:strings.index(line,text)]
                fmt.sbprintf(&b,"%s%s = (%s)(%s);\n",indent,text[:at],type,text[at+3:len(text)-1])
                continue
            }
        }
        strings.write_string(&b,line)
    }
    return strings.to_string(b)
}

// Constants.<emitter>.Module.Input as Constants.Emitter.Module.Input.
@(private)
niagara_emitter_alias :: proc(full:string) -> string {
    if !strings.has_prefix(full,"Constants.") {return full}
    rest:=full[len("Constants."):]
    dot:=strings.index_byte(rest,'.')
    if dot<0 {return full}
    return strings.concatenate({"Constants.Emitter",rest[dot:]},context.temp_allocator)
}

// A value of the state of the system that prepare keeps: its first word and type.
@(private)
Niagara_Kept :: struct {name,value,type:string,word:int}

STATE_WORDS :: 128 // that prepare keeps of an emitter: vfx.STATE_BYTES/4

// How the parts read a value of the state of the system that prepare keeps;
// false for one that does not fit, which they compute themselves.
@(private)
niagara_state_kept :: proc(w:^Niagara_Writer,name:string,state:Niagara_State) -> (value:string,ok:bool) {
    k:Niagara_Kept
    found:=false
    for each in w.kept {
        if each.name==name {k,found=each,true}
    }
    scalar,count:=niagara_components(state.type)
    if !found {
        used:=0
        for each in w.kept {_,c:=niagara_components(each.type);used=max(used,each.word+c)}
        if used+count>STATE_WORDS {return}
        k=Niagara_Kept{strings.clone(name,context.temp_allocator),state.value,state.type,used}
        append(&w.kept,k)
    }
    b:=strings.builder_make(context.temp_allocator)
    if count>1 {fmt.sbprintf(&b,"%s(",state.type)}
    for i in 0..<count {
        if i>0 {strings.write_string(&b,", ")}
        load:=fmt.tprintf("mirai_vfx_state_load(ctx, %du)",k.word+i)
        switch scalar {
        case "int": fmt.sbprintf(&b,"asint(%s)",load)
        case "uint": strings.write_string(&b,load)
        case "bool": fmt.sbprintf(&b,"(%s != 0u)",load)
        case: fmt.sbprintf(&b,"asfloat(%s)",load)
        }
    }
    if count>1 {strings.write_byte(&b,')')}
    return strings.to_string(b),true
}
