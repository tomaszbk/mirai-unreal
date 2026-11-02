package unreal_vfx_editor

import "core:fmt"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"

// Niagara's data channels as the data channels of Vfx (`//! resource name
// data words`): the channel of the world named after the asset, and an
// entry of the variables of the channel in the order the asset lists them,
// the words of each its components. The values are those of Unreal, in its
// space: what writes and what reads them is translated from Niagara.

Niagara_Channel :: struct {
    name:string,            // of the asset: the name of the data channel of the world
    variables:[]Niagara_Channel_Variable,
    words:int,
}

Niagara_Channel_Variable :: struct {name,type:string,offset,count:int}

// The channel the Channel of a DataChannelRead or DataChannelWrite names.
@(private)
niagara_channel :: proc(d:^level.Document,object:level.Ref) -> (channel:Niagara_Channel) {
    f,error:=level.property(d,object,"Channel")
    if error.code!=.None || f.property==nil {return}
    asset,ok:=object_resolve(d,object,value_object(f.pkg,f.property))
    if !ok {return}
    name:=object_name(d,asset)
    held,held_error:=level.property(d,asset,"DataChannel")
    if held_error.code!=.None || held.property==nil {return}
    inner,found:=object_resolve(d,asset,value_object(held.pkg,held.property))
    if !found {return}
    v,v_error:=level.property(d,inner,"ChannelVariables")
    if v_error.code!=.None || v.property==nil {return}
    view,view_error:=unreal.property_array(v.pkg,v.property)
    if view_error.code!=.None {return}
    // Each variable: its name, then the tagged fields of its type until None.
    p:=v.pkg
    variables:=make([dynamic]Niagara_Channel_Variable,context.temp_allocator)
    at,end:=view.data.offset,view.data.offset+view.data.size
    words:=0
    for _ in 0..<view.count {
        if at+8>end {break}
        index:=(^i32le)(&p.bytes[at])^
        variable:=unreal.name_plain(p,unreal.Name_Ref{i32(index),0})
        list,list_error:=unreal.properties_open(p,{at+8,end-(at+8)},false,context.temp_allocator)
        if list_error.code!=.None {break}
        type:=""
        if class:=value_object(p,unreal.property_find(p,&list,"ClassStructOrEnum"));class!=0 {
            if n,named:=unreal.reference_name(p,class);named {type=strings.clone(unreal.name_plain(p,n),context.temp_allocator)}
        }
        if type=="" {
            // A type without a struct is one of the numbers its UnderlyingType says; Niagara keeps floats.
            type="NiagaraFloat"
        }
        count:=niagara_channel_words(type)
        append(&variables,Niagara_Channel_Variable{strings.clone(variable,context.temp_allocator),type,words,count})
        words+=count
        at=list.trailing.offset
    }
    if words==0 {return}
    return {strings.clone(name,context.temp_allocator),variables[:],words}
}

// The words of a value of a type of Niagara.
@(private)
niagara_channel_words :: proc(type:string) -> int {
    switch type {
    case "NiagaraPosition","Vector3f","Vector","Vector3d","NiagaraVector3": return 3
    case "LinearColor","Vector4f","Vector4","Quat4f","Quat","NiagaraVector4": return 4
    case "Vector2f","Vector2D","NiagaraVector2": return 2
    case "NiagaraID": return 2
    }
    return 1
}

@(private)
niagara_channel_variable :: proc(c:^Niagara_Channel,name:string) -> (variable:Niagara_Channel_Variable,ok:bool) {
    for each in c.variables {if each.name==name {return each,true}}
    return
}

// A value of the type of a parameter from the words of an entry, or into them.
@(private)
niagara_channel_load :: proc(b:^strings.Builder,R,entry,target,type:string,variable:Niagara_Channel_Variable) {
    scalar,count:=niagara_components(type)
    value:=strings.builder_make(context.temp_allocator)
    if count>1 {fmt.sbprintf(&value,"%s(",type)}
    for i in 0..<count {
        if i>0 {strings.write_string(&value,", ")}
        word:=fmt.tprintf("mirai_vfx_data_word(niagara_ctx, %s, uint(%s), %du)",R,entry,variable.offset+min(i,variable.count-1))
        switch scalar {
        case "int": fmt.sbprintf(&value,"asint(%s)",word)
        case "uint": fmt.sbprintf(&value,"%s",word)
        case "bool": fmt.sbprintf(&value,"(%s != 0u)",word)
        case: fmt.sbprintf(&value,"asfloat(%s)",word)
        }
    }
    if count>1 {strings.write_byte(&value,')')}
    fmt.sbprintf(b,"    %s = %s;\n",target,strings.to_string(value))
}

@(private)
niagara_channel_store :: proc(b:^strings.Builder,R,source,type:string,variable:Niagara_Channel_Variable) {
    scalar,count:=niagara_components(type)
    axes:="xyzw"
    for i in 0..<min(count,variable.count) {
        part:=source if count==1 else fmt.tprintf("%s.%c",source,axes[i])
        value:=fmt.tprintf("asuint(%s)",part)
        if scalar=="bool" {value=fmt.tprintf("(%s ? 1u : 0u)",part)}
        if scalar=="uint" {value=part}
        fmt.sbprintf(b,"        mirai_vfx_data_store(niagara_ctx, %s, entry, %du, %s);\n",R,variable.offset+i,value)
    }
}

// The name of the variable a parameter carries: In_Position, Out_Color, bOutSuccess.
@(private)
niagara_channel_parameter :: proc(name:string) -> string {
    plain:=name
    for prefix in ([4]string{"In_","Out_","In","Out"}) {
        if strings.has_prefix(plain,prefix) && len(plain)>len(prefix) {plain=plain[len(prefix):];break}
    }
    return plain
}

// The functions of DataChannelRead and DataChannelWrite.
@(private)
niagara_channel_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base,specifier:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    if di.resource=="" {return}
    ins,outs:=niagara_split(params)
    R:=di.resource
    c:=&di.channel
    b:=strings.builder_make(context.temp_allocator)
    switch base {
    case "Num":
        if len(outs)<1 {return}
        fmt.sbprintf(&b,"    %s = int(mirai_vfx_data_count(niagara_ctx, %s));\n",outs[0].name,R)
    case "Read","ReadNDC":
        // The index of an entry, then whether it is one and its variables.
        if len(ins)<1 || len(outs)<1 {return}
        fmt.sbprintf(&b,"    bool found = %s >= 0 && uint(%s) < mirai_vfx_data_count(niagara_ctx, %s);\n",ins[0].name,ins[0].name,R)
        fmt.sbprintf(&b,"    %s = (%s)found;\n",outs[0].name,strings.trim_prefix(outs[0].type,"out "))
        for out in outs[1:] {
            type:=strings.trim_prefix(out.type,"out ")
            variable,known:=niagara_channel_variable(c,niagara_channel_parameter(out.name))
            if !known {fmt.sbprintf(&b,"    %s = (%s)0;\n",out.name,type);continue}
            niagara_channel_load(&b,R,ins[0].name,out.name,type,variable)
        }
    case "Write","Append":
        // Whether to write, then the variables; whether it was written.
        if len(ins)<1 {return}
        fmt.sbprintf(&b,"    uint entry = 0u;\n    bool written = (%s) && mirai_vfx_data_append(niagara_ctx, %s, entry);\n    if (written) {{\n",ins[0].name,R)
        for value in ins[1:] {
            variable,known:=niagara_channel_variable(c,niagara_channel_parameter(value.name))
            if !known {continue}
            niagara_channel_store(&b,R,value.name,value.type,variable)
        }
        strings.write_string(&b,"    }\n")
        if len(outs)>0 {fmt.sbprintf(&b,"    %s = (%s)written;\n",outs[0].name,strings.trim_prefix(outs[0].type,"out "))}
    case "GetNDCSpawnData":
        // The entry a spawning particle starts from: each entry has the births the most its rules
        // ask (niagara_spawn_write), and those its rules do not ask for end in initialize.
        if len(ins)<2 || len(outs)<3 {return}
        w.channel_spawn=R
        fmt.sbprintf(&b,"    int per = max(niagara_spawn_per(niagara_ctx), 1);\n    %s = %s / per;\n    %s = %s %% per;\n",outs[0].name,ins[1].name,outs[1].name,ins[1].name)
        fmt.sbprintf(&b,"    %s = niagara_spawn_count(niagara_ctx, %s);\n",outs[2].name,outs[0].name)
        fmt.sbprintf(&b,"    if (%s >= %s) niagara_spawn_dropped = true;\n",outs[1].name,outs[2].name)
    case "SpawnConditional":
        return niagara_spawn_rule_body(w,di,specifier,ins)
    case:
        return
    }
    return strings.to_string(b),true
}

// A SpawnConditional of the scripts of the system: the particles each entry
// of a data channel starts in an emitter, those whose variables pass its
// conditions. Its call leaves its words in niagara_rule<k> (whether it ran
// for this emitter, its mode and operator, the least and most particles,
// then the components of each condition), which prepare keeps.
Niagara_Spawn_Rule :: struct {
    key,resource:string,
    conditions:[]Niagara_Spawn_Condition,
    words:int,
}

// A condition of a rule: the variable of the channel it compares, its type
// and its first word among those of the rule; known false for a variable the
// channel does not have, which no entry passes.
Niagara_Spawn_Condition :: struct {variable:Niagara_Channel_Variable,type:string,word:int,known:bool}

NIAGARA_RULE_WORDS :: 5 // of a rule before its conditions: on, mode, operator, least and most
NIAGARA_RULES :: 8      // of a program

// The body of SpawnConditional: Enable, the emitter it spawns into (Emitter ID,
// since its version 1), Mode, Operator, Min and Max Spawn Count, then the
// values of its conditions, each compared with the variable of its name.
@(private)
niagara_spawn_rule_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,specifier:string,ins:[]Hlsl_Field) -> (body:string,ok:bool) {
    first:=1
    emitter:=""
    if len(ins)>1 && strings.contains(ins[1].type,"EmitterID") {emitter,first=ins[1].name,2}
    if len(ins)<first+4 {return}
    key:=fmt.tprintf("%s %s",di.name,specifier)
    k:=-1
    for rule,i in w.spawn_rules {if rule.key==key {k=i}}
    if k<0 {
        if len(w.spawn_rules)>=NIAGARA_RULES {
            append(&w.problems,fmt.tprintf("%s.SpawnConditional: the program keeps %d rules of spawning; this one spawns nothing",di.name,NIAGARA_RULES))
            return "",true
        }
        conditions:=make([]Niagara_Spawn_Condition,len(ins)-first-4,context.temp_allocator)
        words:=NIAGARA_RULE_WORDS
        for value,i in ins[first+4:] {
            _,count:=niagara_components(value.type)
            variable,known:=niagara_channel_variable(&di.channel,niagara_channel_parameter(value.name))
            conditions[i]={variable,value.type,words,known}
            words+=count
        }
        append(&w.spawn_rules,Niagara_Spawn_Rule{strings.clone(key,context.temp_allocator),di.resource,conditions,words})
        k=len(w.spawn_rules)-1
    }
    rule:=w.spawn_rules[k]
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"    if (!(%s)) return;\n",ins[0].name)
    if emitter!="" {fmt.sbprintf(&b,"    if (%s.ID != %d) return;\n",emitter,w.emitter.handle)}
    // ENDIDataChannelSpawnMode: Override, Accumulate, None.
    mode,op,least,most:=ins[first].name,ins[first+1].name,ins[first+2].name,ins[first+3].name
    fmt.sbprintf(&b,"    if (%s < 0 || %s > 1) return;\n",mode,mode)
    fmt.sbprintf(&b,"    niagara_rule%d[0] = 1u;\n    niagara_rule%d[1] = uint(%s);\n    niagara_rule%d[2] = uint(%s);\n",k,k,mode,k,op)
    fmt.sbprintf(&b,"    niagara_rule%d[3] = uint(max(%s, 0));\n    niagara_rule%d[4] = uint(max(%s, max(%s, 0)));\n",k,least,k,most,least)
    axes:="xyzw"
    for c,i in rule.conditions {
        value:=ins[first+4+i].name
        scalar,count:=niagara_components(c.type)
        for j in 0..<count {
            part:=value if count==1 else fmt.tprintf("%s.%c",value,axes[j])
            bits:=fmt.tprintf("asuint(%s)",part)
            if scalar=="bool" {bits=fmt.tprintf("(%s ? 1u : 0u)",part)}
            fmt.sbprintf(&b,"    niagara_rule%d[%d] = %s;\n",k,c.word+j,bits)
        }
    }
    return strings.to_string(b),true
}

// The words of the rules, niagara_spawn_per (the most particles an entry of
// the data channel of its births starts, what births gives each entry) and
// niagara_spawn_count (those an entry starts: each rule that ran and whose
// conditions it passes gives the least to the most, by the entry, in place of
// those before with Override and added to them with Accumulate). The rules
// reach them through words prepare keeps; without a rule, each entry starts
// the most its SpawnFromNDC module asks.
@(private)
niagara_spawn_write :: proc(w:^Niagara_Writer,s:^strings.Builder) {
    for rule,k in w.spawn_rules {fmt.sbprintf(s,"static uint niagara_rule%d[%d];\n",k,rule.words)}
    R:=w.channel_spawn
    if R=="" {return}
    per:=strings.builder_make(context.temp_allocator)
    count:=strings.builder_make(context.temp_allocator)
    rules:=0
    for rule,k in w.spawn_rules {
        if rule.resource!=R {continue}
        load:=make([]string,rule.words,context.temp_allocator)
        kept:=true
        for i in 0..<rule.words {
            value,ok:=niagara_state_kept(w,fmt.tprintf("niagara_rule%d_%d",k,i),{fmt.tprintf("niagara_rule%d[%d]",k,i),"uint"})
            if !ok {kept=false;break}
            load[i]=value
        }
        if !kept {
            append(&w.problems,fmt.tprintf("a rule of spawning from %s does not fit in what prepare keeps: it spawns nothing",R))
            continue
        }
        rules+=1
        fmt.sbprintf(&per,"    if (%s != 0u) per += int(%s);\n",load[0],load[4])
        fmt.sbprintf(&count,"    if (%s != 0u) {{\n        uint op = %s;\n        bool pass = true;\n",load[0],load[2])
        for c in rule.conditions {
            if !c.known {
                strings.write_string(&count,"        pass = false;\n")
                continue
            }
            scalar,n:=niagara_components(c.type)
            for j in 0..<n {
                entry:=fmt.tprintf("mirai_vfx_data_word(ctx, %s, uint(entry), %du)",R,c.variable.offset+min(j,c.variable.count-1))
                a,e:=fmt.tprintf("asfloat(%s)",load[c.word+j]),fmt.tprintf("asfloat(%s)",entry)
                switch scalar {
                case "int","uint": a,e=fmt.tprintf("asint(%s)",load[c.word+j]),fmt.tprintf("asint(%s)",entry)
                case "bool": a,e=fmt.tprintf("int(%s != 0u)",load[c.word+j]),fmt.tprintf("int(%s != 0u)",entry)
                }
                fmt.sbprintf(&count,"        pass = pass && niagara_compare(op, %s, %s);\n",a,e)
            }
        }
        fmt.sbprintf(&count,"        if (pass) {{\n            int least = int(%s);\n            int most = max(int(%s), least);\n",load[3],load[4])
        fmt.sbprintf(&count,"            int n = least + int(uint(hash(entry, %d)) %% uint(most - least + 1));\n",k)
        fmt.sbprintf(&count,"            count = %s == 0u ? n : count + n;\n        }}\n    }}\n",load[1])
    }
    strings.write_string(s,"int niagara_spawn_per(Mirai_Vfx_Context ctx) {\n")
    if rules==0 {
        most:=1
        for each in w.values.values {
            if strings.has_suffix(each.full,"SpawnFromNDC.Max Spawn Count") && each.count>0 {most=max(most,int(each.values[0]))}
        }
        fmt.sbprintf(s,"    return %d;\n}}\n",most)
        fmt.sbprintf(s,"int niagara_spawn_count(Mirai_Vfx_Context ctx, int entry) {{\n    return %d;\n}}\n",most)
        return
    }
    fmt.sbprintf(s,"    int per = 0;\n%s    return per;\n}}\n",strings.to_string(per))
    fmt.sbprintf(s,"int niagara_spawn_count(Mirai_Vfx_Context ctx, int entry) {{\n    int count = 0;\n%s    return count;\n}}\n",strings.to_string(count))
}
