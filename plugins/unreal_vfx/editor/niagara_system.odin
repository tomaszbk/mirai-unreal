package unreal_vfx_editor

import "core:fmt"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"

// The scripts of a system compute the state of the system and of each of its
// emitters (their ages, loops, and what their emitter scripts write: Emitter.*
// and System.* of the particle scripts). A program runs them in each thread,
// before its parts: the spawn script gives the state its first values, the
// clock of the effect gives the ages of the frame before, and the update
// script advances them a frame. Nothing is kept from one frame to the next.

// The scripts of a system that keep their compilation.
@(private)
niagara_system_scripts :: proc(d:^level.Document,system:level.Ref,sys:^Niagara_System,user:^Niagara_Values) {
    sys.values.every=true
    sys.values.values=make([dynamic]Niagara_Value,context.temp_allocator)
    sys.problems=make([dynamic]string,context.temp_allocator)
    for each in user.values {append(&sys.values.values,each)}
    for name,i in ([2]string{"SystemSpawnScript","SystemUpdateScript"}) {
        f,error:=level.property(d,system,name)
        if error.code!=.None || f.property==nil {continue}
        script,ok:=object_resolve(d,system,value_object(f.pkg,f.property))
        if !ok {continue}
        store:=struct_at(d,script,"RapidIterationParameters")
        niagara_store(&store,&sys.values)
        compiled,has:=niagara_compiled(d,script)
        for problem in compiled.problems {append(&sys.problems,fmt.tprintf("%s: %s",name,problem))}
        if !has {continue}
        if i==0 {sys.spawn=compiled} else {sys.update=compiled}
    }
}

// Writes the scripts of the system into the namespaces ss (spawn) and su
// (update), and gives the writer the values its parts read of them.
@(private)
niagara_system_write :: proc(w:^Niagara_Writer,out:^strings.Builder) {
    spawn_script,has_spawn:=w.system.spawn.?
    update_script,has_update:=w.system.update.?
    if !has_spawn || !has_update {
        append(&w.problems,"the scripts of its system keep no compilation: what they compute of the emitter is zero")
        return
    }
    defines:=niagara_defines(0,0)
    spawn:=Niagara_Part{role=.Spawn,items=hlsl_items(hlsl_preprocess(spawn_script.hlsl,defines)),map_name="Map",entry="Simulate",vm=true}
    update:=Niagara_Part{role=.Update,items=hlsl_items(hlsl_preprocess(update_script.hlsl,defines)),map_name="Map",entry="Simulate",vm=true}
    // The field of the parameter map that is this emitter.
    emitter:=niagara_symbol(w.emitter.name)
    found:=false
    for field in hlsl_fields(niagara_struct_body(&update,"FParamMap0")) {found||=field.name==emitter}
    if !found {
        append(&w.problems,fmt.tprintf("the scripts of its system do not compute %s: what they compute of the emitter is zero",emitter))
        return
    }
    values:=w.values
    w.values=&w.system.values
    niagara_part_write(w,out,&spawn,"ss",nil)
    niagara_part_write(w,out,&update,"su",nil)
    w.values=values
    // Where the spawn script writes each value of its data set.
    outputs:=make(map[string]string,context.temp_allocator)
    if main:=niagara_function(&spawn,"SimulateMain");main!=nil {
        rest:=main.body
        for line in strings.split_lines_iterator(&rest) {
            // OutputDataFloat(0, 2, TmpWriteIndex, Context.Map.Leader.CurrentLoopDuration);
            text:=strings.trim_space(line)
            if !strings.has_prefix(text,"OutputData") {continue}
            open:=strings.index_byte(text,'(')
            close:=strings.last_index_byte(text,')')
            if open<0 || close<open {continue}
            args:=strings.split(text[open+1:close],", ",context.temp_allocator)
            if len(args)!=4 || !strings.has_prefix(args[3],"Context.Map.") {continue}
            outputs[fmt.tprintf("%s %s %s",text[len("OutputData"):open],args[0],args[1])]=args[3][len("Context.Map."):]
        }
    }
    strings.write_string(out,"namespace ss {\nvoid niagara_run(Mirai_Vfx_Context ctx, inout FSimulationContext Context) {\n    niagara_setup(ctx);\n")
    niagara_main_write(out,&spawn,nil)
    strings.write_string(out,"}\n}\n")
    strings.write_string(out,"namespace su {\nstatic FSimulationContext niagara_state;\nvoid niagara_run(Mirai_Vfx_Context ctx) {\n")
    strings.write_string(out,"    ss::FSimulationContext S = (ss::FSimulationContext)0;\n    ss::niagara_run(ctx, S);\n    niagara_setup(ctx);\n    FSimulationContext Context = (FSimulationContext)0;\n")
    niagara_main_write(out,&update,&outputs)
    strings.write_string(out,"    niagara_state = Context;\n}\n}\n")
    // What the parts read of the state: Emitter.* of this emitter, System.* of the system.
    w.state=make(map[string]Niagara_State,context.temp_allocator)
    structs:=make(map[string]string,context.temp_allocator)
    for item in update.items {if item.kind==.Struct {structs[item.name]=item.body}}
    for field in hlsl_fields(structs["FParamMap0"]) {
        prefix:=""
        if field.name==emitter {prefix="Emitter"} else if field.name=="System" {prefix="System"} else {continue}
        niagara_state_paths(w,structs,field.type,prefix,fmt.tprintf("su::niagara_state.Map.%s",field.name),0)
    }
}

// A value the scripts of the system compute: where it is in their state, and its type.
@(private)
Niagara_State :: struct {value,type:string}

@(private)
niagara_state_paths :: proc(w:^Niagara_Writer,structs:map[string]string,type,flat,path:string,depth:int) {
    body,found:=structs[type]
    if !found || depth>4 {return}
    for field in hlsl_fields(body) {
        name:=fmt.tprintf("%s_%s",flat,field.name)
        at:=fmt.tprintf("%s.%s",path,field.name)
        // The births of the emitter, from the spawn infos of its modules.
        if field.type=="NiagaraSpawnInfo" && strings.has_prefix(flat,"Emitter") {append(&w.spawns,at)}
        if _,nested:=structs[field.type];nested {
            niagara_state_paths(w,structs,field.type,name,at,depth+1)
            continue
        }
        if (niagara_attribute_type(field.type)=="" && field.type!="float4x4") || field.type=="NiagaraID" {continue}
        w.state[name]=Niagara_State{at,field.type}
    }
}

// The body of SimulateMain until it writes its data sets, run on Context:
// each value it reads of the data set of the instance comes from what the
// spawn script wrote there (outputs; none: zero), each of the engine from the
// effect, and the ages of the frame before precede the update.
@(private)
niagara_main_write :: proc(out:^strings.Builder,part:^Niagara_Part,outputs:^map[string]string) {
    main:=niagara_function(part,"SimulateMain")
    if main==nil {
        fmt.sbprintf(out,"    %s(Context);\n",part.entry)
        return
    }
    rest:=main.body
    for line in strings.split_lines_iterator(&rest) {
        text:=strings.trim_space(line)
        if strings.has_prefix(text,"FSimulationContext Context") || strings.has_prefix(text,"EnterStatScope") || strings.has_prefix(text,"ExitStatScope") {continue}
        if strings.has_prefix(text,"WriteDataSets") || text=="{" {break}
        // The first frame decides the durations of the loops, and runs to the frame before: what
        // a rate leaves over is what it left there. The clock then gives the ages.
        if strings.has_prefix(text,"Simulate(") && outputs!=nil {
            strings.write_string(out,"    Context.Map.Engine.DeltaTime = max(ctx.emitter_age - ctx.delta_time, 0.0);\n")
            fmt.sbprintf(out,"    %s\n",text)
            strings.write_string(out,"    Context.Map.Engine.DeltaTime = ctx.delta_time;\n")
            niagara_clocks_write(out,part)
        }
        // Context.Map.Leader.Age = InputDataFloat(0, 0);
        input:=strings.index(text," = InputData")
        open:=strings.index_byte(text,'(')
        close:=strings.last_index_byte(text,')')
        if !strings.has_prefix(text,"Context.Map.") || input<0 || open<input || close<open {
            fmt.sbprintf(out,"    %s\n",text)
            continue
        }
        path,type:=text[len("Context.Map."):input],text[input+len(" = InputData"):open]
        args:=strings.split(text[open+1:close],", ",context.temp_allocator)
        value:=niagara_engine_value(path,type)
        if outputs!=nil && len(args)==2 && !strings.has_prefix(path,"Engine.") {
            if from,ok:=outputs[fmt.tprintf("%s %s %s",type,args[0],args[1])];ok {value=fmt.tprintf("S.Map.%s",from)}
        }
        fmt.sbprintf(out,"    Context.Map.%s = %s;\n",path,value)
    }
}

// The value of the engine a script of the system reads: from the effect and
// its transform, one for a scale and the count of particles (an emitter is
// never empty of them to its script), zero for the rest.
@(private)
niagara_engine_value :: proc(path,type:string) -> string {
    switch {
    case path=="Engine.DeltaTime": return "ctx.delta_time"
    case path=="Engine.Time" || path=="Engine.RealTime": return "ctx.time"
    case path=="Engine.Emitter.InstanceSeed": return "int(ctx.emitter)"
    case path=="Engine.Emitter.TotalSpawnedParticles": return "int(ctx.born)"
    case strings.has_suffix(path,".NumParticles"): return "1"
    case strings.has_suffix(path,"SpawnCountScale"): return "1.0"
    case strings.has_prefix(path,"Engine.Owner."):
        // Of the transform of the effect, as the parts see it: a component of a vector, quaternion or matrix.
        rest:=path[len("Engine.Owner."):]
        end:=len(rest)
        for c,i in rest {if c=='.' || c=='[' {end=i;break}}
        L:="niagara_local_to_world(ctx.world)"
        value:=""
        switch rest[:end] {
        case "Position": value=fmt.tprintf("%s[3].xyz",L)
        case "Rotation": value=fmt.tprintf("niagara_quaternion((float3x3)%s)",L)
        case "Scale": value="float3(1.0, 1.0, 1.0)"
        case "SystemLocalToWorld","SystemLocalToWorldNoScale": value=L
        case "SystemWorldToLocal","SystemWorldToLocalNoScale": value=fmt.tprintf("niagara_inverse(%s)",L)
        case "SystemLocalToWorldTransposed": value=fmt.tprintf("transpose(%s)",L)
        case "SystemWorldToLocalTransposed": value=fmt.tprintf("transpose(niagara_inverse(%s))",L)
        case "SystemXAxis": value=fmt.tprintf("normalize(%s[0].xyz)",L)
        case "SystemYAxis": value=fmt.tprintf("normalize(%s[1].xyz)",L)
        case "SystemZAxis": value=fmt.tprintf("normalize(%s[2].xyz)",L)
        }
        if value!="" {return fmt.tprintf("(%s)%s",value,rest[end:])}
    }
    switch type {
    case "Bool": return "false"
    case "Int": return "0"
    }
    return "0.0"
}

// The ages of the system and of each emitter at the frame before, from the
// clock of the effect and the duration of their loop.
@(private)
niagara_clocks_write :: proc(out:^strings.Builder,part:^Niagara_Part) {
    structs:=make(map[string]string,context.temp_allocator)
    for item in part.items {if item.kind==.Struct {structs[item.name]=item.body}}
    for field in hlsl_fields(structs["FParamMap0"]) {
        body,found:=structs[field.type]
        if !found {continue}
        names:=make(map[string]bool,context.temp_allocator)
        for each in hlsl_fields(body) {names[each.name]=true}
        if !names["Age"] || !names["LoopedAge"] || !names["LoopCount"] || !names["CurrentLoopDuration"] {continue}
        M:=fmt.tprintf("Context.Map.%s",field.name)
        fmt.sbprintf(out,"    {{\n        float age = max(ctx.emitter_age - ctx.delta_time, 0.0);\n        float loop = max(%s.CurrentLoopDuration, 1e-4);\n",M)
        fmt.sbprintf(out,"        %s.Age = age;\n        %s.LoopCount = int(floor(age / loop));\n        %s.LoopedAge = age - float(%s.LoopCount) * loop;\n",M,M,M,M)
        if names["NormalizedLoopAge"] {fmt.sbprintf(out,"        %s.NormalizedLoopAge = %s.LoopedAge / loop;\n",M,M)}
        strings.write_string(out,"    }\n")
    }
}

@(private)
niagara_function :: proc(part:^Niagara_Part,name:string) -> ^Hlsl_Item {
    for &item in part.items {if item.kind==.Function && item.name==name {return &item}}
    return nil
}

// A name as Niagara's translator writes it in HLSL: its characters that are
// not of an identifier as '_'.
@(private)
niagara_identifier :: proc(name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for i in 0..<len(name) {strings.write_byte(&b,is_ident(name[i])?name[i]:'_')}
    return strings.to_string(b)
}

