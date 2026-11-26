package unreal_vfx_editor

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// A cooked Niagara emitter as the Vfx program that runs its scripts. `ue5parse niagara` gives
// each script as the values it writes, expression trees over the operations of Niagara's VM
// with their temporaries and data interface calls; here every value is the 32 bits the VM
// holds (a float, an integer or a mask of all ones), so the integer arithmetic Niagara draws
// its random numbers from and the selects over masks come out as in the game. The spawn script
// is initialize, the update script update, and the emitter's own script, which the system
// script runs, is prepare and births: the state of the emitter and of the system lives in the
// words of the program. Lengths and axes are Unreal's inside the scripts.
//
// What a script reads that has no answer here is a note: a program with notes is not the
// emitter of the game and is not to be used. What its particles show that a Vfx program
// cannot is a limit.

Cooked_Vfx_Program :: struct {
    source:string,
    notes:[]string,
    limits:[]string,
    births:bool, // the program gives the births of its emitter
}

@(private="file")
Interface :: struct {
    name:string,   // of the data interface, as the calls name it
    class:string,
    object:json.Object,
    index:int,     // of its data in the program, -1 until a call needs it
    width:int,     // values of each of its entries
    count:int,     // entries
}

@(private="file")
Translation :: struct {
    emitter:string,
    random_seed:i64,
    local:bool,
    user:json.Array,
    interfaces:[dynamic]Interface,
    fields:[dynamic]string,              // of a particle, as the scripts name them ("Color.x")
    words:[dynamic]string,               // of the state: what the emitter and the system keep
    state_outputs:map[string]json.Value, // what their scripts write, by the same names
    notes,limits:[dynamic]string,
    data:strings.Builder,                // the data of the interfaces and the functions that read them
}

@(private="file")
Scope :: struct {
    t:^Translation,
    out:strings.Builder,
    defs:map[string]json.Object, // temporaries and calls by name
    done:map[string]bool,
    system:bool,                 // the scripts of the system and the emitter: their attributes are words of the state
    pending:[dynamic]string,     // of the system: outputs read that are still to be computed
}

@(private="file") MAX_DEPTH :: 200
@(private="file") STATE_WORDS :: 128
@(private="file") ATTRIBUTE_BYTES :: 1024
// The first words of the state: whether the emitter has run a frame, and where it was then.
@(private="file") RESERVED_WORDS :: 4

@(private="file")
note :: proc(list:^[dynamic]string,text:string) {
    for n in list {
        if n==text {return}
    }
    append(list,strings.clone(text,context.temp_allocator))
}

@(private="file")
ident :: proc(prefix,name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,prefix)
    for c in transmute([]u8)name {
        ok:=(c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')
        strings.write_byte(&b,ok ? c : '_')
    }
    return strings.to_string(b)
}

@(private="file")
field_of :: proc(t:^Translation,name:string) -> string {
    for f in t.fields {
        if f==name {return ident("f_",name)}
    }
    append(&t.fields,strings.clone(name,context.temp_allocator))
    return ident("f_",name)
}

@(private="file")
has_field :: proc(t:^Translation,name:string) -> bool {
    for f in t.fields {
        if f==name {return true}
    }
    return false
}

@(private="file")
word_of :: proc(t:^Translation,name:string) -> int {
    for w,i in t.words {
        if w==name {return i}
    }
    append(&t.words,strings.clone(name,context.temp_allocator))
    return len(t.words)-1
}

@(private="file")
float_bits :: proc(v:f64) -> string {
    return fmt.tprintf("0x%08xu",transmute(u32)f32(v))
}

@(private="file")
int_bits :: proc(v:i64) -> string {
    return fmt.tprintf("0x%08xu",u32(u64(v)&0xffffffff))
}

@(private="file")
number :: proc(v:json.Value) -> (f64,bool) {
    #partial switch x in v {
    case json.Float:return f64(x),true
    case json.Integer:return f64(x),true
    case json.Boolean:return x ? 1 : 0,true
    }
    return 0,false
}

@(private="file")
whole :: proc(v:json.Value) -> (i64,bool) {
    #partial switch x in v {
    case json.Integer:return i64(x),true
    case json.Float:
        if x>=-9.2e18&&x<=9.2e18 {return i64(x),true}
    case json.Boolean:return x ? 1 : 0,true
    }
    return 0,false
}

// A value the cooked data holds, as the bits of its type.
@(private="file")
typed_bits :: proc(value:json.Value,type:string) -> (string,bool) {
    low:=strings.to_lower(type,context.temp_allocator)
    switch {
    case strings.contains(low,"bool"):
        n,ok:=number(value)
        return n!=0 ? "0xffffffffu" : "0x00000000u",ok
    case strings.contains(low,"int")||low=="bits":
        n,ok:=whole(value)
        return int_bits(n),ok
    }
    n,ok:=number(value)
    return float_bits(n),ok
}

// A parameter of the user, by its name and the component the scripts read of it.
@(private="file")
user_bits :: proc(t:^Translation,name:string) -> (string,bool) {
    plain:=strings.trim_prefix(name,"PREV_")
    for item in t.user {
        obj,ok:=item.(json.Object)
        if !ok {continue}
        own:=jstr(obj["Name"])
        type:=jstr(obj["Type"])
        if own==plain {
            if _,is_list:=obj["Value"].(json.Array);is_list {continue}
            return typed_bits(obj["Value"],type)
        }
        if strings.has_prefix(plain,own)&&len(plain)==len(own)+2&&plain[len(own)]=='.' {
            list,is_list:=obj["Value"].(json.Array)
            at:=strings.index_byte("xyzw",plain[len(plain)-1])
            if at<0 {at=strings.index_byte("rgba",plain[len(plain)-1])}
            if !is_list||at<0||at>=len(list) {continue}
            return typed_bits(list[at],"float")
        }
    }
    return "",false
}

@(private="file")
interface_find :: proc(t:^Translation,name:string) -> ^Interface {
    for &i in t.interfaces {
        if i.name==name {return &i}
    }
    return nil
}

// The data of an interface a call needs, written once: its values in one array.
@(private="file")
interface_data :: proc(t:^Translation,di:^Interface) -> bool {
    if di.index>=0 {return di.count>0}
    values:=make([dynamic]f64,context.temp_allocator)
    rows:json.Array
    switch {
    case strings.contains(di.class,"Curve"):
        curve,_:=di.object["Curve"].(json.Object)
        rows,_=curve["LUT"].(json.Array)
    case strings.contains(di.class,"ArrayColor"):
        rows,_=di.object["Colors"].(json.Array)
    case strings.contains(di.class,"ArrayFloat3"):
        props,_:=di.object["Properties"].(json.Object)
        rows,_=props["InternalFloatData"].(json.Array)
    case strings.contains(di.class,"ArrayFloat"):
        props,_:=di.object["Properties"].(json.Object)
        rows,_=props["FloatData"].(json.Array)
    case:
        return false
    }
    width:=0
    for row in rows {
        before:=len(values)
        #partial switch x in row {
        case json.Array:
            for c in x {
                n,_:=number(c)
                append(&values,n)
            }
        case json.Object:
            for key in ([]string{"X","Y","Z","W"}) {
                if c,has:=x[key];has {
                    n,_:=number(c)
                    append(&values,n)
                }
            }
        case:
            n,_:=number(row)
            append(&values,n)
        }
        if width==0 {width=len(values)-before}
        if len(values)-before!=width||width==0 {return false}
    }
    if len(rows)==0 {return false}
    di.index=0
    for other in t.interfaces {
        if other.index>=di.index&&other.name!=di.name {di.index=other.index+1}
    }
    di.width,di.count=width,len(rows)
    fmt.sbprintf(&t.data,"static const float NV_DATA%d[%d] = {{",di.index,len(values))
    for v,i in values {
        if i>0 {strings.write_string(&t.data,",")}
        if i%16==0 {strings.write_string(&t.data,"\n    ")}
        text:=fmt.tprintf("%.9g",f32(v))
        if strings.contains_any(text,"nNiI") {text="0.0"}
        if !strings.contains_any(text,".e") {text=fmt.tprintf("%s.0",text)}
        strings.write_string(&t.data,text)
    }
    strings.write_string(&t.data,"\n};\n")
    return true
}

// The statements of a call, which leave its outputs in <name>_0, <name>_1...
@(private="file")
call_write :: proc(sc:^Scope,name:string,def:json.Object,depth:int) {
    t:=sc.t
    outputs:=0
    if n,ok:=whole(def["Outputs"]);ok {outputs=int(clamp(n,0,64))}
    args,_:=def["Args"].(json.Array)
    function:=jstr(def["Function"])
    di:=interface_find(t,jstr(def["DataInterface"]))
    exprs:=make([]string,len(args),context.temp_allocator)
    for a,i in args {exprs[i]=expr(sc,a,depth+1)}
    for k in 0..<outputs {fmt.sbprintf(&sc.out,"    uint %s_%d = 0u;\n",name,k)}
    answered:=false
    if di!=nil&&len(exprs)>0 {
        switch function {
        case "SampleCurve","SampleVector2DCurve","SampleVectorCurve","SampleColorCurve":
            if strings.contains(di.class,"Curve")&&interface_data(t,di)&&di.width>=outputs {
                // The table of the curve between its first and last times, as the game samples it.
                props,_:=di.object["Properties"].(json.Object)
                first,_:=number(props["LUTMinTime"])
                inverse,has_inverse:=number(props["LUTInvTimeRange"])
                if !has_inverse {inverse=1}
                last:=f64(di.count-1)
                fmt.sbprintf(&sc.out,"    {{ float nv_x = saturate((fv(%s) - asfloat(%s)) * asfloat(%s)) * asfloat(%s); float nv_a = floor(nv_x); float nv_b = nv_a < asfloat(%s) ? nv_a + 1.0 : nv_a; float nv_t = nv_x - nv_a;",
                    exprs[len(exprs)-1],float_bits(first),float_bits(inverse),float_bits(last),float_bits(last))
                for k in 0..<outputs {
                    fmt.sbprintf(&sc.out," %s_%d = nf(lerp(NV_DATA%d[int(nv_a) * %d + %d], NV_DATA%d[int(nv_b) * %d + %d], nv_t));",name,k,di.index,di.width,k,di.index,di.width,k)
                }
                strings.write_string(&sc.out," }\n")
                answered=true
            }
        case "Get":
            if strings.contains(di.class,"Array")&&interface_data(t,di)&&di.width>=outputs {
                fmt.sbprintf(&sc.out,"    {{ int nv_i = clamp(int(%s), 0, %d);",exprs[len(exprs)-1],di.count-1)
                for k in 0..<outputs {fmt.sbprintf(&sc.out," %s_%d = nf(NV_DATA%d[nv_i * %d + %d]);",name,k,di.index,di.width,k)}
                strings.write_string(&sc.out," }\n")
                answered=true
            }
        case "Length":
            if strings.contains(di.class,"Array")&&outputs==1 {
                interface_data(t,di)
                fmt.sbprintf(&sc.out,"    %s_0 = %du;\n",name,di.count)
                answered=true
            }
        }
    }
    if !answered {
        class:=di!=nil ? di.class : "an unknown data interface"
        note(&t.notes,fmt.tprintf("%s of %s",function,strings.trim_prefix(class,"NiagaraDataInterface")))
    }
}

// Writes the temporary or call of that name before what reads it.
@(private="file")
need :: proc(sc:^Scope,name:string,depth:int) {
    if sc.done[name] {return}
    sc.done[name]=true
    def,has:=sc.defs[name]
    if !has {
        note(&sc.t.notes,fmt.tprintf("the temporary %s, which no module computes",name))
        fmt.sbprintf(&sc.out,"    uint %s = 0u;\n",name)
        return
    }
    if _,is_call:=def["Function"];is_call {
        call_write(sc,name,def,depth)
        return
    }
    value:=expr(sc,def["Value"],depth+1)
    fmt.sbprintf(&sc.out,"    uint %s = %s;\n",name,value)
}

@(private="file")
parameter :: proc(sc:^Scope,obj:json.Object) -> string {
    t:=sc.t
    name:=jstr(obj["Parameter"])
    source:=jstr(obj["Source"])
    plain:=strings.trim_prefix(name,"PREV_")
    switch plain {
    case "Engine.DeltaTime","Engine.WorldDeltaTime":return "nf(e.dt)"
    case "Engine.InverseDeltaTime":return "nf(e.dt > 0.0 ? 1.0 / e.dt : 0.0)"
    case "Engine.Time","Engine.RealTime":return "nf(e.time)"
    case "Engine.Emitter.TotalSpawnedParticles":return "e.born"
    case "Engine.Emitter.InstanceSeed":return "e.instance"
    case "Engine.ExecutionCount":return "e.count"
    case "Engine.System.TickCount":return "e.tick"
    case "Emitter.RandomSeed":return int_bits(t.random_seed)
    case "Emitter.Age":
        // What the emitter's own script keeps, where it runs here; else the age of the emitter.
        if _,kept:=t.state_outputs[fmt.tprintf("%s.Age",t.emitter)];kept&&!sc.system {
            return fmt.tprintf("mirai_vfx_state_load(ctx, %du)",word_of(t,fmt.tprintf("%s.Age",t.emitter)))
        }
        return "nf(e.age)"
    case "Engine.Owner.Position.x":return "nf(e.owner.x)"
    case "Engine.Owner.Position.y":return "nf(e.owner.y)"
    case "Engine.Owner.Position.z":return "nf(e.owner.z)"
    case "Engine.Owner.Scale.x":return "nf(e.scale.x)"
    case "Engine.Owner.Scale.y":return "nf(e.scale.y)"
    case "Engine.Owner.Scale.z":return "nf(e.scale.z)"
    case "Engine.Owner.LWCTile.x","Engine.Owner.LWCTile.y","Engine.Owner.LWCTile.z","Engine.Owner.LWCTile.w":return "0u"
    }
    for prefix,inverse in ([2]string{"Engine.Owner.LocalToWorldNoScale[","Engine.Owner.WorldToLocalNoScale["}) {
        if !strings.has_prefix(plain,prefix)||!strings.has_suffix(plain,"]") {continue}
        at:=0
        for ch in plain[len(prefix):len(plain)-1] {
            if ch<'0'||ch>'9' {at=99;break}
            at=at*10+int(ch-'0')
        }
        if at>15 {break}
        return fmt.tprintf("nf(e.%s[%d])",inverse==1 ? "w2l" : "l2w",at)
    }
    if source=="User"||strings.has_prefix(plain,"User.") {
        if bits,ok:=user_bits(t,name);ok {return bits}
    }
    // What the emitter's script writes each frame, read by its particles.
    if _,kept:=t.state_outputs[plain];kept {
        if sc.system {return fmt.tprintf("s%d",word_of(t,plain))}
        return fmt.tprintf("mirai_vfx_state_load(ctx, %du)",word_of(t,plain))
    }
    if value,has:=obj["Value"];has {
        if bits,ok:=typed_bits(value,jstr(obj["Type"],"float"));ok {return bits}
    }
    note(&t.notes,fmt.tprintf("the parameter %s",name))
    return "0u"
}

// What the engine gives the scripts of the system each frame.
@(private="file")
engine_attribute :: proc(sc:^Scope,name:string) -> string {
    t:=sc.t
    switch name {
    case "Engine.Owner.Velocity.x":return "nf(e.velocity.x)"
    case "Engine.Owner.Velocity.y":return "nf(e.velocity.y)"
    case "Engine.Owner.Velocity.z":return "nf(e.velocity.z)"
    case "Engine.Owner.ExecutionState":return "0u" // active
    case "Engine.Owner.LODDistance","Engine.Owner.LODDistanceFraction","Engine.Owner.TimeSinceRendered":return "nf(0.0)"
    }
    if strings.has_prefix(name,"Engine.") {
        switch {
        case strings.has_suffix(name,".SpawnCountScale"):return "nf(1.0)"
        case strings.has_suffix(name,".InstanceSeed"):
            // A seed of each emitter of the system: that of this one, apart by the name.
            h:=u32(2166136261)
            for ch in transmute([]u8)name {h=(h~u32(ch))*16777619}
            return fmt.tprintf("(e.instance + 0x%08xu)",h)
        case strings.has_suffix(name,".TotalSpawnedParticles"):return "e.born"
        // How many are alive is not known to a program: none, so an emitter that waits for its last particle ends at once.
        case strings.has_suffix(name,".NumParticles"):return "0u"
        }
    }
    if bits,ok:=user_bits(t,name);ok {return bits}
    note(&t.notes,fmt.tprintf("the value %s of the engine",name))
    return "0u"
}

// A tree as an expression of the 32 bits it leaves.
@(private="file")
expr :: proc(sc:^Scope,v:json.Value,depth:int) -> string {
    t:=sc.t
    obj,ok:=v.(json.Object)
    if !ok||depth>MAX_DEPTH {
        if depth>MAX_DEPTH {note(&t.notes,"an expression deeper than a program takes")}
        return "0u"
    }
    if lit,has:=obj["Literal"];has {
        switch jstr(obj["Type"]) {
        case "float":
            n,_:=number(lit)
            return float_bits(n)
        case "int":
            n,_:=whole(lit)
            return int_bits(n)
        }
        if n,exact:=whole(obj["AsInt"]);exact {return int_bits(n)}
        // Without a type, as its number reads.
        if n,is_whole:=lit.(json.Integer);is_whole {return int_bits(i64(n))}
        n,_:=number(lit)
        return float_bits(n)
    }
    if _,has:=obj["ExecIndex"];has {return "e.exec"}
    if name_v,has:=obj["Temp"];has {
        name:=ident("",jstr(name_v))
        need(sc,name,depth)
        return name
    }
    if name_v,has:=obj["Call"];has {
        name:=ident("",jstr(name_v))
        need(sc,name,depth)
        k,_:=whole(obj["Output"])
        return fmt.tprintf("%s_%d",name,clamp(k,0,63))
    }
    if name_v,has:=obj["Attribute"];has {
        name:=jstr(name_v)
        set,_:=whole(obj["DataSet"])
        if sc.system {
            if set==1 {return engine_attribute(sc,name)}
            if _,written:=t.state_outputs[name];written {
                listed:=false
                for p in sc.pending {listed||=p==name}
                if !listed {append(&sc.pending,name)}
            }
            return fmt.tprintf("s%d",word_of(t,name))
        }
        if set!=0 {
            note(&t.notes,fmt.tprintf("the attribute %s of data set %d",name,set))
            return "0u"
        }
        return fmt.tprintf("a.%s",field_of(t,name))
    }
    if _,has:=obj["Parameter"];has {return parameter(sc,obj)}
    op:=jstr(obj["Op"])
    if op=="" {
        note(&t.notes,fmt.tprintf("a value the decompiler did not recover (%s)",jstr(obj["Unknown"],"unknown")))
        return "0u"
    }
    list,_:=obj["Args"].(json.Array)
    args:[3]string={"0u","0u","0u"}
    for a,i in list {
        if i<3 {args[i]=expr(sc,a,depth+1)}
    }
    a,b,c:=args[0],args[1],args[2]
    switch op {
    case "add":return fmt.tprintf("nf(fv(%s) + fv(%s))",a,b)
    case "sub":return fmt.tprintf("nf(fv(%s) - fv(%s))",a,b)
    case "mul":return fmt.tprintf("nf(fv(%s) * fv(%s))",a,b)
    case "div":return fmt.tprintf("nf(fv(%s) / fv(%s))",a,b)
    case "mad":return fmt.tprintf("nf(fv(%s) * fv(%s) + fv(%s))",a,b,c)
    case "lerp":return fmt.tprintf("nf(lerp(fv(%s), fv(%s), fv(%s)))",a,b,c)
    case "rcp":return fmt.tprintf("nf(1.0 / fv(%s))",a)
    case "rsq":return fmt.tprintf("nf(rsqrt(fv(%s)))",a)
    case "sqrt":return fmt.tprintf("nf(sqrt(fv(%s)))",a)
    case "neg":return fmt.tprintf("nf(-fv(%s))",a)
    case "abs":return fmt.tprintf("nf(abs(fv(%s)))",a)
    case "exp":return fmt.tprintf("nf(exp(fv(%s)))",a)
    case "exp2":return fmt.tprintf("nf(exp2(fv(%s)))",a)
    case "log":return fmt.tprintf("nf(log(fv(%s)))",a)
    case "log2":return fmt.tprintf("nf(log2(fv(%s)))",a)
    case "sin":return fmt.tprintf("nf(sin(fv(%s)))",a)
    case "cos":return fmt.tprintf("nf(cos(fv(%s)))",a)
    case "tan":return fmt.tprintf("nf(tan(fv(%s)))",a)
    case "asin":return fmt.tprintf("nf(asin(fv(%s)))",a)
    case "acos":return fmt.tprintf("nf(acos(fv(%s)))",a)
    case "atan":return fmt.tprintf("nf(atan(fv(%s)))",a)
    case "atan2":return fmt.tprintf("nf(atan2(fv(%s), fv(%s)))",a,b)
    case "ceil":return fmt.tprintf("nf(ceil(fv(%s)))",a)
    case "floor":return fmt.tprintf("nf(floor(fv(%s)))",a)
    case "round":return fmt.tprintf("nf(round(fv(%s)))",a)
    case "trunc":return fmt.tprintf("nf(trunc(fv(%s)))",a)
    case "frac":return fmt.tprintf("nf(frac(fv(%s)))",a)
    case "fmod":return fmt.tprintf("nf(fmod(fv(%s), fv(%s)))",a,b)
    case "min":return fmt.tprintf("nf(min(fv(%s), fv(%s)))",a,b)
    case "max":return fmt.tprintf("nf(max(fv(%s), fv(%s)))",a,b)
    case "pow":return fmt.tprintf("nf(pow(fv(%s), fv(%s)))",a,b)
    case "sign":return fmt.tprintf("nf(sign(fv(%s)))",a)
    case "step":return fmt.tprintf("nf(step(fv(%s), fv(%s)))",a,b)
    case "clamp":return fmt.tprintf("nf(clamp(fv(%s), fv(%s), fv(%s)))",a,b,c)
    case "random":return fmt.tprintf("nf(mirai_vfx_random(e.rng) * fv(%s))",a)
    case "cmplt":return fmt.tprintf("nb(fv(%s) < fv(%s))",a,b)
    case "cmple":return fmt.tprintf("nb(fv(%s) <= fv(%s))",a,b)
    case "cmpgt":return fmt.tprintf("nb(fv(%s) > fv(%s))",a,b)
    case "cmpge":return fmt.tprintf("nb(fv(%s) >= fv(%s))",a,b)
    case "cmpeq":return fmt.tprintf("nb(fv(%s) == fv(%s))",a,b)
    case "cmpneq":return fmt.tprintf("nb(fv(%s) != fv(%s))",a,b)
    case "select":return fmt.tprintf("(%s != 0u ? %s : %s)",a,b,c)
    case "addi":return fmt.tprintf("(%s + %s)",a,b)
    case "subi":return fmt.tprintf("(%s - %s)",a,b)
    case "muli":return fmt.tprintf("(%s * %s)",a,b)
    case "divi":return fmt.tprintf("nv_divi(%s, %s)",a,b)
    case "clampi":return fmt.tprintf("uint(clamp(int(%s), int(%s), int(%s)))",a,b,c)
    case "mini":return fmt.tprintf("uint(min(int(%s), int(%s)))",a,b)
    case "maxi":return fmt.tprintf("uint(max(int(%s), int(%s)))",a,b)
    case "absi":return fmt.tprintf("uint(abs(int(%s)))",a)
    case "negi":return fmt.tprintf("(0u - %s)",a)
    case "signi":return fmt.tprintf("uint(sign(int(%s)))",a)
    case "randomi":return fmt.tprintf("uint(int(mirai_vfx_random(e.rng) * float(int(%s))))",a)
    case "cmplti":return fmt.tprintf("nb(int(%s) < int(%s))",a,b)
    case "cmplei":return fmt.tprintf("nb(int(%s) <= int(%s))",a,b)
    case "cmpgti":return fmt.tprintf("nb(int(%s) > int(%s))",a,b)
    case "cmpgei":return fmt.tprintf("nb(int(%s) >= int(%s))",a,b)
    case "cmpeqi":return fmt.tprintf("nb(%s == %s)",a,b)
    case "cmpneqi":return fmt.tprintf("nb(%s != %s)",a,b)
    case "bit_and","logic_and":return fmt.tprintf("(%s & %s)",a,b)
    case "bit_or","logic_or":return fmt.tprintf("(%s | %s)",a,b)
    case "bit_xor","logic_xor":return fmt.tprintf("(%s ^ %s)",a,b)
    case "bit_not","logic_not":return fmt.tprintf("(~%s)",a)
    case "bit_lshift":return fmt.tprintf("(%s << (%s & 31u))",a,b)
    case "bit_rshift":return fmt.tprintf("(%s >> (%s & 31u))",a,b)
    case "f2i":return fmt.tprintf("uint(int(fv(%s)))",a)
    case "i2f":return fmt.tprintf("nf(float(int(%s)))",a)
    case "f2b":return fmt.tprintf("nb(fv(%s) != 0.0)",a)
    case "b2f":return fmt.tprintf("(%s != 0u ? 0x3f800000u : 0u)",a)
    case "b2i":return fmt.tprintf("(%s != 0u ? 1u : 0u)",a)
    case "i2b":return fmt.tprintf("nb(%s != 0u)",a)
    case "fasi","iasf","half_to_float":return a
    }
    note(&t.notes,fmt.tprintf("the operation %s",op))
    return "0u"
}

// The temporaries and calls of the modules of a script, by name.
@(private="file")
defs_add :: proc(defs:^map[string]json.Object,script:json.Object) {
    modules,_:=script["Modules"].(json.Array)
    for m in modules {
        mobj,ok:=m.(json.Object)
        if !ok {continue}
        for key in ([]string{"Temps","Calls"}) {
            list,_:=mobj[key].(json.Array)
            for item in list {
                def,is_def:=item.(json.Object)
                if !is_def {continue}
                if name:=jstr(def["Name"]);name!="" {defs[ident("",name)]=def}
            }
        }
    }
}

// Every scalar a script writes: its attribute with the component, and the tree.
@(private="file")
Written :: struct {name:string,value:json.Value}

@(private="file")
outputs_of :: proc(t:^Translation,script:json.Object,particles:bool) -> []Written {
    out:=make([dynamic]Written,context.temp_allocator)
    list,_:=script["Outputs"].(json.Array)
    for item in list {
        obj,ok:=item.(json.Object)
        if !ok {continue}
        name:=jstr(obj["Attribute"])
        if name=="" {continue}
        if set,_:=whole(obj["DataSet"]);set!=0 {
            if particles {note(&t.limits,fmt.tprintf("what the script writes to data set %d (%s)",set,name))}
            continue
        }
        if value,has:=obj["Value"];has {
            append(&out,Written{name,value})
            continue
        }
        components,_:=obj["Components"].(json.Object)
        for key in ([]string{"x","y","z","w","r","g","b","a"}) {
            if value,has:=components[key];has {append(&out,Written{fmt.tprintf("%s.%s",name,key),value})}
        }
        for key,value in components {
            known:=false
            for k in ([]string{"x","y","z","w","r","g","b","a"}) {known||=k==key}
            if !known {append(&out,Written{fmt.tprintf("%s.%s",name,key),value})}
        }
    }
    return out[:]
}

// The body of initialize or update: the script's values, then its attributes, and whether the particle stays.
@(private="file")
particle_script :: proc(t:^Translation,script:json.Object) -> string {
    sc:=Scope{t=t,defs=make(map[string]json.Object,allocator=context.temp_allocator),done=make(map[string]bool,allocator=context.temp_allocator)}
    sc.out=strings.builder_make(context.temp_allocator)
    defs_add(&sc.defs,script)
    written:=outputs_of(t,script,true)
    for w,i in written {
        value:=expr(&sc,w.value,0)
        fmt.sbprintf(&sc.out,"    uint o%d = %s;\n",i,value)
    }
    strings.write_string(&sc.out,"    bool keep = true;\n")
    keeps,_:=script["KeepConditions"].(json.Array)
    for k in keeps {
        value:=expr(&sc,k,0)
        fmt.sbprintf(&sc.out,"    keep = keep && (%s) != 0u;\n",value)
    }
    for w,i in written {fmt.sbprintf(&sc.out,"    a.%s = o%d;\n",field_of(t,w.name),i)}
    return strings.to_string(sc.out)
}

@(private="file")
PROGRAM_PRELUDE :: `
// The bits of a float, a float of bits, and the mask of a comparison.
uint nf(float v) { return asuint(v); }
float fv(uint b) { return asfloat(b); }
uint nb(bool b) { return b ? 0xFFFFFFFFu : 0u; }
uint nv_divi(uint a, uint b) { return int(b) == 0 ? 0u : uint(int(a) / int(b)); }
float3 nv_unreal(float3 v) { return float3(-v.z, v.x, v.y); }
float3 nv_mirai(float3 v) { return float3(v.y, v.z, -v.x); }
// What the scripts read of the frame, in Unreal's centimetres and axes.
struct Nv {
    float dt;
    float time;
    float age;       // of the emitter
    uint born;       // particles the emitter started before the frame
    uint exec;       // which instance of this execution
    uint count;      // instances of this execution
    uint instance;   // a seed of the emitter
    uint tick;
    float3 owner;    // where the emitter is
    float3 velocity; // how fast it moves
    float3 scale;
    float l2w[16];   // its transform without scale, a row an axis
    float w2l[16];
    uint rng;
};
Nv nv_frame(Mirai_Vfx_Context ctx, float dt, uint seed) {
    Nv e;
    e.dt = dt; e.time = ctx.time; e.age = ctx.emitter_age; e.born = ctx.born; e.exec = 0u; e.count = ctx.spawned;
    e.instance = ctx.emitter * 747796405u + 2891336453u;
    e.tick = uint(ctx.time * 60.0);
    e.owner = nv_unreal(ctx.origin) * 100.0;
    e.velocity = float3(0.0);
    // Unreal's x is Mirai's -z, its y Mirai's x, its z Mirai's y.
    float3 x = -nv_unreal(float3(ctx.world[0].z, ctx.world[1].z, ctx.world[2].z));
    float3 y = nv_unreal(float3(ctx.world[0].x, ctx.world[1].x, ctx.world[2].x));
    float3 z = nv_unreal(float3(ctx.world[0].y, ctx.world[1].y, ctx.world[2].y));
    e.scale = float3(length(x), length(y), length(z));
    x /= max(e.scale.x, 1e-20); y /= max(e.scale.y, 1e-20); z /= max(e.scale.z, 1e-20);
    for (int i = 0; i < 16; i++) { e.l2w[i] = 0.0; e.w2l[i] = 0.0; }
    e.l2w[0] = x.x; e.l2w[1] = x.y; e.l2w[2] = x.z;
    e.l2w[4] = y.x; e.l2w[5] = y.y; e.l2w[6] = y.z;
    e.l2w[8] = z.x; e.l2w[9] = z.y; e.l2w[10] = z.z;
    e.l2w[12] = e.owner.x; e.l2w[13] = e.owner.y; e.l2w[14] = e.owner.z; e.l2w[15] = 1.0;
    e.w2l[0] = x.x; e.w2l[1] = y.x; e.w2l[2] = z.x;
    e.w2l[4] = x.y; e.w2l[5] = y.y; e.w2l[6] = z.y;
    e.w2l[8] = x.z; e.w2l[9] = y.z; e.w2l[10] = z.z;
    e.w2l[12] = -dot(e.owner, x); e.w2l[13] = -dot(e.owner, y); e.w2l[14] = -dot(e.owner, z); e.w2l[15] = 1.0;
    e.rng = seed;
    return e;
}
// A place and a direction of the scripts as the particle keeps them, and back: those of an
// emitter of local space are in the space of the emitter.
float3 nv_place(Mirai_Vfx_Context ctx, float3 p, bool local) {
    float3 m = nv_mirai(p) * 0.01;
    if (!local) return m;
    return float3(dot(ctx.world[0].xyz, m) + ctx.world[0].w, dot(ctx.world[1].xyz, m) + ctx.world[1].w, dot(ctx.world[2].xyz, m) + ctx.world[2].w);
}
float3 nv_way(Mirai_Vfx_Context ctx, float3 v, bool local) {
    float3 m = nv_mirai(v) * 0.01;
    if (!local) return m;
    return float3(dot(ctx.world[0].xyz, m), dot(ctx.world[1].xyz, m), dot(ctx.world[2].xyz, m));
}
float3 nv_way_back(Mirai_Vfx_Context ctx, float3 v, bool local) {
    if (!local) return nv_unreal(v) * 100.0;
    float3 x = float3(ctx.world[0].x, ctx.world[1].x, ctx.world[2].x);
    float3 y = float3(ctx.world[0].y, ctx.world[1].y, ctx.world[2].y);
    float3 z = float3(ctx.world[0].z, ctx.world[1].z, ctx.world[2].z);
    float3 m = float3(dot(v, x) / max(dot(x, x), 1e-20), dot(v, y) / max(dot(y, y), 1e-20), dot(v, z) / max(dot(z, z), 1e-20));
    return nv_unreal(m) * 100.0;
}
float3 nv_place_back(Mirai_Vfx_Context ctx, float3 p, bool local) {
    if (!local) return nv_unreal(p) * 100.0;
    return nv_way_back(ctx, p - float3(ctx.world[0].w, ctx.world[1].w, ctx.world[2].w), true);
}
`

// The program of one emitter of a system `ue5parse niagara` described, as one of its renderers
// draws it: renderer is that renderer of the description, whose Bindings name the attribute
// each thing a particle shows comes from (its place, colour, size, rotation, frame and what it
// gives its material).
cooked_vfx_program :: proc(name:string,system,emitter,renderer:json.Object,allocator:=context.allocator) -> (p:Cooked_Vfx_Program) {
    bindings,_:=renderer["Bindings"].(json.Object)
    kind:=jstr(renderer["Kind"])
    bound :: proc(bindings:json.Object,key,fallback:string) -> string {
        if name:=jstr(bindings[key]);name!="" {return strings.trim_prefix(name,"Particles.")}
        return fallback
    }
    size_attribute:=bound(bindings,"SpriteSizeBinding","SpriteSize")
    switch kind {
    case "mesh":size_attribute=bound(bindings,"ScaleBinding","Scale")
    case "ribbon":size_attribute=bound(bindings,"RibbonWidthBinding","RibbonWidth")
    }
    position_attribute:=bound(bindings,"PositionBinding","Position")
    color_attribute:=bound(bindings,"ColorBinding","Color")
    rotation_attribute:=bound(bindings,"SpriteRotationBinding","SpriteRotation")
    frame_attribute:=bound(bindings,"SubImageIndexBinding","SubImageIndex")
    random_attribute:=bound(bindings,"MaterialRandomBinding","MaterialRandom")
    t:=Translation{
        emitter=jstr(emitter["Name"]),
        interfaces=make([dynamic]Interface,context.temp_allocator),
        fields=make([dynamic]string,context.temp_allocator),
        words=make([dynamic]string,context.temp_allocator),
        state_outputs=make(map[string]json.Value,allocator=context.temp_allocator),
        notes=make([dynamic]string,context.temp_allocator),
        limits=make([dynamic]string,context.temp_allocator),
    }
    t.data=strings.builder_make(context.temp_allocator)
    t.user,_=system["UserParameters"].(json.Array)
    if settings,has:=emitter["Settings"].(json.Object);has {
        t.local=jbool(settings["bLocalSpace"])
        t.random_seed,_=whole(settings["RandomSeed"])
    }
    for list in ([2]json.Value{emitter["DataInterfaces"],system["DataInterfaces"]}) {
        items,_:=list.(json.Array)
        for item in items {
            obj,ok:=item.(json.Object)
            if !ok {continue}
            append(&t.interfaces,Interface{name=jstr(obj["Name"]),class=jstr(obj["Class"]),object=obj,index=-1})
        }
    }
    for w in ([RESERVED_WORDS]string{"nv.started","nv.origin.x","nv.origin.y","nv.origin.z"}) {word_of(&t,w)}

    spawn,update:json.Object
    has_spawn,has_update,gpu:=false,false,false
    scripts,_:=emitter["Scripts"].(json.Array)
    for s in scripts {
        obj,ok:=s.(json.Object)
        if !ok {continue}
        usage:=jstr(obj["Usage"])
        switch {
        case strings.contains(usage,"GPUCompute"):gpu=true
        case strings.contains(usage,"Spawn"):spawn,has_spawn=obj,true
        case strings.contains(usage,"Update"):update,has_update=obj,true
        }
    }
    if gpu {note(&t.notes,"scripts the game compiled for the GPU and keeps as shaders")}
    if !has_spawn&&!has_update {note(&t.notes,"no particle script")}

    // The scripts of the system and the emitter: what they write is the state.
    system_scope:=Scope{t=&t,system=true,defs=make(map[string]json.Object,allocator=context.temp_allocator),done=make(map[string]bool,allocator=context.temp_allocator),
        pending=make([dynamic]string,context.temp_allocator)}
    system_scope.out=strings.builder_make(context.temp_allocator)
    emitter_outputs:=make([dynamic]Written,context.temp_allocator)
    system_scripts,_:=system["Scripts"].(json.Array)
    for s in system_scripts {
        obj,ok:=s.(json.Object)
        if !ok||!strings.contains(jstr(obj["Usage"]),"Update") {continue}
        defs_add(&system_scope.defs,obj)
        for w in outputs_of(&t,obj,false) {t.state_outputs[w.name]=w.value}
    }
    // The system script runs every emitter's: a temporary one computes, another may read.
    every,_:=system["Emitters"].(json.Array)
    for other in every {
        other_obj,_:=other.(json.Object)
        others,_:=other_obj["EmitterScripts"].(json.Array)
        for s in others {
            obj,ok:=s.(json.Object)
            if ok&&strings.contains(jstr(obj["Usage"]),"Update") {defs_add(&system_scope.defs,obj)}
        }
    }
    emitter_scripts,_:=emitter["EmitterScripts"].(json.Array)
    for s in emitter_scripts {
        obj,ok:=s.(json.Object)
        if !ok||!strings.contains(jstr(obj["Usage"]),"Update") {continue}
        defs_add(&system_scope.defs,obj)
        for w in outputs_of(&t,obj,false) {
            t.state_outputs[w.name]=w.value
            append(&emitter_outputs,w)
        }
    }

    spawn_body,update_body:string
    if has_spawn {spawn_body=particle_script(&t,spawn)}
    if has_update {update_body=particle_script(&t,update)}

    // prepare: every output of the emitter's script, and those of the system's they read.
    counts:=make([dynamic]int,context.temp_allocator)
    computed:=make([dynamic]string,context.temp_allocator)
    for w in emitter_outputs {append(&system_scope.pending,w.name)}
    for at:=0;at<len(system_scope.pending);at+=1 {
        output:=system_scope.pending[at]
        value:=expr(&system_scope,t.state_outputs[output],0)
        fmt.sbprintf(&system_scope.out,"    uint n%d = %s;\n",at,value)
        append(&computed,output)
    }
    for w in emitter_outputs {
        // The spawn infos of the emitter: how many particles each starts this frame.
        if !strings.has_suffix(w.name,".Count") {continue}
        base:=strings.trim_suffix(w.name,".Count")
        if _,info:=t.state_outputs[fmt.tprintf("%s.InterpStartDt",base)];info {append(&counts,word_of(&t,w.name))}
    }
    p.births=len(emitter_outputs)>0&&len(counts)>0
    if len(t.words)>STATE_WORDS {note(&t.notes,fmt.tprintf("%d values of the emitter and the system, more than the state of a program holds",len(t.words)))}
    if len(t.fields)*4>ATTRIBUTE_BYTES {note(&t.notes,fmt.tprintf("%d values of each particle, more than a program keeps",len(t.fields)))}

    w:=strings.builder_make(allocator)
    fmt.sbprintf(&w,"//! mirai vfx %s\n//! moves\n",name)
    if p.births {strings.write_string(&w,"//! prepare\n//! births\n")}
    strings.write_string(&w,"//! parameter scale {\"default\":1,\"min\":0,\"max\":100}\n")
    strings.write_string(&w,"// The scripts of a Niagara emitter as one Vfx program: generated, not written.\n")
    fmt.sbprintf(&w,"namespace %s {{\nstruct Parameters {{ float scale; }};\nstruct Attributes {{\n",name)
    for f in t.fields {fmt.sbprintf(&w,"    uint %s;\n",ident("f_",f))}
    if len(t.fields)==0 {strings.write_string(&w,"    uint unused;\n")}
    strings.write_string(&w,"};\n")
    strings.write_string(&w,PROGRAM_PRELUDE)
    strings.write_string(&w,strings.to_string(t.data))
    fmt.sbprintf(&w,"static const bool NV_LOCAL = %s;\n",t.local ? "true" : "false")

    vector :: proc(t:^Translation,name:string) -> (string,bool) {
        if !has_field(t,fmt.tprintf("%s.x",name)) {return "",false}
        parts:[3]string
        for c,i in ([3]string{"x","y","z"}) {
            parts[i]=has_field(t,fmt.tprintf("%s.%s",name,c)) ? fmt.tprintf("fv(a.%s)",ident("f_",fmt.tprintf("%s.%s",name,c))) : "0.0"
        }
        return fmt.tprintf("float3(%s, %s, %s)",parts[0],parts[1],parts[2]),true
    }
    position,has_position:=vector(&t,"Position")
    velocity,has_velocity:=vector(&t,"Velocity")
    // Where the renderer draws the particle, when that is not where its scripts move it.
    shown,has_shown:=vector(&t,position_attribute)
    drawn_apart:=position_attribute!="Position"&&has_shown

    // What the particle of Mirai takes of its attributes after a script.
    strings.write_string(&w,"void nv_leave(Mirai_Vfx_Context ctx, inout Mirai_Vfx_Particle particle, Attributes a) {\n")
    switch {
    case drawn_apart:fmt.sbprintf(&w,"    particle.position = nv_place(ctx, %s, NV_LOCAL);\n",shown)
    case has_position:fmt.sbprintf(&w,"    particle.position = nv_place(ctx, %s, NV_LOCAL);\n",position)
    }
    if has_velocity {fmt.sbprintf(&w,"    particle.velocity = nv_way(ctx, %s, NV_LOCAL);\n",velocity)}
    if has_field(&t,"Lifetime") {strings.write_string(&w,"    particle.lifetime = max(fv(a.f_Lifetime), 1e-4);\n")}
    if has_field(&t,"Age") {strings.write_string(&w,"    particle.age = max(fv(a.f_Age), 0.0);\n")}
    if kind=="sprite"&&has_field(&t,rotation_attribute) {fmt.sbprintf(&w,"    particle.rotation = radians(fv(a.%s));\n",ident("f_",rotation_attribute))}
    strings.write_string(&w,"}\n")
    // And what its attributes take of it before one: where the pool has it.
    strings.write_string(&w,"void nv_enter(Mirai_Vfx_Context ctx, Mirai_Vfx_Particle particle, inout Attributes a) {\n")
    if has_position&&!drawn_apart {
        strings.write_string(&w,"    float3 at = nv_place_back(ctx, particle.position, NV_LOCAL);\n")
        for c in ([3]string{"x","y","z"}) {
            if has_field(&t,fmt.tprintf("Position.%s",c)) {fmt.sbprintf(&w,"    a.f_Position_%s = nf(at.%s);\n",c,c)}
        }
    }
    if has_velocity {
        strings.write_string(&w,"    float3 moving = nv_way_back(ctx, particle.velocity, NV_LOCAL);\n")
        for c in ([3]string{"x","y","z"}) {
            if has_field(&t,fmt.tprintf("Velocity.%s",c)) {fmt.sbprintf(&w,"    a.f_Velocity_%s = nf(moving.%s);\n",c,c)}
        }
    }
    strings.write_string(&w,"}\n")

    strings.write_string(&w,"void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {\n")
    strings.write_string(&w,"    Nv e = nv_frame(ctx, 0.0, particle.seed);\n    e.exec = ctx.birth - ctx.born;\n    nv_enter(ctx, particle, a);\n")
    if has_spawn {
        strings.write_string(&w,spawn_body)
    } else {
        strings.write_string(&w,"    bool keep = true;\n")
    }
    // A particle its spawn script does not keep dies at its first step.
    strings.write_string(&w,"    nv_leave(ctx, particle, a);\n    if (!keep) { particle.age = 1.0; particle.lifetime = 1.0; }\n}\n")

    strings.write_string(&w,"void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {\n")
    strings.write_string(&w,"    Nv e = nv_frame(ctx, ctx.delta_time, particle.seed ^ (uint(ctx.time * 1000.0) * 2654435761u));\n    e.exec = ctx.particle;\n    nv_enter(ctx, particle, a);\n")
    if has_update {
        strings.write_string(&w,update_body)
    } else {
        strings.write_string(&w,"    bool keep = true;\n")
    }
    strings.write_string(&w,"    nv_leave(ctx, particle, a);\n    if (!keep) particle.age = particle.lifetime;\n}\n")

    strings.write_string(&w,"void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {\n")
    if color,has_color:=vector(&t,color_attribute);has_color {
        alpha:=has_field(&t,fmt.tprintf("%s.w",color_attribute)) ? fmt.tprintf("saturate(fv(a.%s))",ident("f_",fmt.tprintf("%s.w",color_attribute))) : "1.0"
        fmt.sbprintf(&w,"    visual.color = float4(max(%s, float3(0.0)), %s);\n",color,alpha)
    }
    switch {
    case kind=="light":
        // A light renderer draws no particle.
        strings.write_string(&w,"    visual.color = float4(0.0);\n    visual.size = 0.0;\n")
    case has_field(&t,fmt.tprintf("%s.x",size_attribute)):
        parts:=make([dynamic]string,context.temp_allocator)
        for c in ([3]string{"x","y","z"}) {
            if has_field(&t,fmt.tprintf("%s.%s",size_attribute,c)) {append(&parts,fmt.tprintf("abs(fv(a.%s))",ident("f_",fmt.tprintf("%s.%s",size_attribute,c))))}
        }
        largest:=parts[0]
        for part in parts[1:] {largest=fmt.tprintf("max(%s, %s)",largest,part)}
        // A mesh takes its size as how many times its own; a sprite as metres across.
        fmt.sbprintf(&w,"    visual.size = %s * %s * max(p.scale, 0.0);\n",largest,kind=="mesh" ? "1.0" : "0.01")
        if len(parts)>1 {note(&t.limits,fmt.tprintf("%s of each axis: a particle takes the largest",size_attribute))}
    case has_field(&t,size_attribute):
        fmt.sbprintf(&w,"    visual.size = abs(fv(a.%s)) * 0.01 * max(p.scale, 0.0);\n",ident("f_",size_attribute))
    }
    if has_field(&t,frame_attribute) {fmt.sbprintf(&w,"    visual.frame = fv(a.%s);\n",ident("f_",frame_attribute))}
    if has_field(&t,random_attribute) {fmt.sbprintf(&w,"    visual.random = fv(a.%s);\n",ident("f_",random_attribute))}
    for slot in 0..<4 {
        base:=bound(bindings,slot==0 ? "DynamicMaterialBinding" : fmt.tprintf("DynamicMaterial%dBinding",slot),slot==0 ? "DynamicMaterialParameter" : fmt.tprintf("DynamicMaterialParameter%d",slot))
        if !has_field(&t,fmt.tprintf("%s.x",base)) {continue}
        parts:[4]string
        for c,i in ([4]string{"x","y","z","w"}) {
            parts[i]=has_field(&t,fmt.tprintf("%s.%s",base,c)) ? fmt.tprintf("fv(a.%s)",ident("f_",fmt.tprintf("%s.%s",base,c))) : "0.0"
        }
        fmt.sbprintf(&w,"    visual.data[%d] = float4(%s, %s, %s, %s); visual.given |= %du;\n",slot,parts[0],parts[1],parts[2],parts[3],1<<uint(slot))
    }
    strings.write_string(&w,"}\n")
    for unseen in ([]string{"MeshOrientation","CameraOffset","SpriteFacing","SpriteAlignment","PivotOffset"}) {
        if has_field(&t,unseen)||has_field(&t,fmt.tprintf("%s.x",unseen)) {note(&t.limits,fmt.tprintf("%s of each particle",unseen))}
    }

    if p.births {
        strings.write_string(&w,"void prepare(Mirai_Vfx_Context ctx, Parameters p) {\n")
        for i in 0..<len(t.words) {fmt.sbprintf(&w,"    uint s%d = mirai_vfx_state_load(ctx, %du);\n",i,i)}
        // An emitter that starts again starts from nothing: the words keep what its last run left.
        strings.write_string(&w,"    if (ctx.emitter_age <= ctx.delta_time + 1e-5) {")
        for i in 0..<len(t.words) {fmt.sbprintf(&w," s%d = 0u;",i)}
        strings.write_string(&w," }\n")
        strings.write_string(&w,"    Nv e = nv_frame(ctx, ctx.delta_time, ctx.emitter * 2246822519u + uint(ctx.time * 1000.0));\n")
        // How fast the emitter moves: from where it was the frame before.
        strings.write_string(&w,"    if (s0 != 0u && ctx.delta_time > 0.0) e.velocity = (e.owner - float3(fv(s1), fv(s2), fv(s3))) / ctx.delta_time;\n")
        strings.write_string(&w,strings.to_string(system_scope.out))
        strings.write_string(&w,"    mirai_vfx_state_store(ctx, 0u, 1u);\n    mirai_vfx_state_store(ctx, 1u, nf(e.owner.x));\n    mirai_vfx_state_store(ctx, 2u, nf(e.owner.y));\n    mirai_vfx_state_store(ctx, 3u, nf(e.owner.z));\n")
        for output,i in computed {fmt.sbprintf(&w,"    mirai_vfx_state_store(ctx, %du, n%d);\n",word_of(&t,output),i)}
        strings.write_string(&w,"}\n")
        strings.write_string(&w,"uint births(Mirai_Vfx_Context ctx, Parameters p) {\n    uint n = 0u;\n")
        // An emitter that is no longer active starts nothing, whatever its script goes on computing.
        if execution:=fmt.tprintf("%s.ExecutionState",t.emitter);execution in t.state_outputs {
            fmt.sbprintf(&w,"    if (mirai_vfx_state_load(ctx, %du) != 0u) return 0u;\n",word_of(&t,execution))
        }
        for word in counts {fmt.sbprintf(&w,"    n += uint(max(int(mirai_vfx_state_load(ctx, %du)), 0));\n",word)}
        strings.write_string(&w,"    return n;\n}\n")
    }
    strings.write_string(&w,"}\n")

    p.source=strings.to_string(w)
    p.notes=make([]string,len(t.notes),allocator)
    for n,i in t.notes {p.notes[i]=strings.clone(n,allocator)}
    p.limits=make([]string,len(t.limits),allocator)
    for n,i in t.limits {p.limits[i]=strings.clone(n,allocator)}
    return
}

cooked_vfx_program_destroy :: proc(p:^Cooked_Vfx_Program,allocator:=context.allocator) {
    delete(p.source,allocator)
    for n in p.notes {delete(n,allocator)}
    delete(p.notes,allocator)
    for n in p.limits {delete(n,allocator)}
    delete(p.limits,allocator)
    p^={}
}
