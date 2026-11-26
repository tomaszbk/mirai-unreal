package unreal_vfx_editor

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import cooked "project:plugins/unreal/editor/cooked"

// A GPU emitter as a Vfx program. `ue5parse niagara --dxc` gives the compute shader the game
// simulates it with as the source of one function (dx_compute) and names what each of its
// constant buffer words, buffers and textures binds. Here the function runs once for each
// particle, as the game runs it once for each thread: in initialize as the thread of a
// particle it spawns, in update as that of a particle it updates. Its particle buffers are the
// words of the particle (a register each), its constant buffers what the engine sets them to
// each frame, the buffers and textures of its data interfaces their data. A particle the
// shader writes nothing of is one it kills. Its group-shared memory and atomics only number
// the particles it writes, which a program does not need.

// Register r of a particle buffer is at r times this, plus the particle.
@(private) GPU_STRIDE :: 65536
@(private) GPU_SPAWN_INFOS :: 8

// A spawn info of the emitter: the state words of its count, interpolation start, interval
// and spawn group (-1 for one its script does not write).
@(private)
Gpu_Spawn :: struct {count,start,interval,group:int}

@(private="file")
Gpu_Constant :: struct {name:string,buffer,offset,size:int}

@(private="file")
Gpu_Data :: struct {
    symbol:string,
    di:^Interface,
}

@(private="file")
Gpu :: struct {
    t:^Translation,
    sc:Scope,
    floats,ints,halves:[dynamic]string, // the attribute component of each register
    data:[dynamic]Gpu_Data,
    statics:[dynamic][3]int,            // of each curve read from the static buffer: its data, offset and length
    static_size:int,
}

@(private="file")
component :: proc(k:int) -> string {
    names:=[4]string{"x","y","z","w"}
    return names[clamp(k,0,3)]
}

// The registers of the particle the shader reads and writes, from the layout of the
// emitter's attributes, each the field of its attribute component.
@(private="file")
gpu_registers :: proc(g:^Gpu,emitter:json.Object) -> bool {
    attrs,_:=emitter["Attributes"].(json.Array)
    put :: proc(g:^Gpu,list:^[dynamic]string,layout:json.Value,name:string) -> bool {
        pair,is_pair:=layout.(json.Array)
        if !is_pair {return true}
        if len(pair)!=2 {return false}
        start,a:=whole(pair[0])
        n,b:=whole(pair[1])
        if !a||!b||start<0||n<1||n>4||start+n>256 {return false}
        for i64(len(list))<start+n {append(list,"")}
        for k in 0..<n {
            component:=n==1 ? name : fmt.tprintf("%s.%s",name,component(int(k)))
            list[start+k]=strings.clone(component,context.temp_allocator)
            field_of(g.t,component)
        }
        return true
    }
    for a in attrs {
        obj,ok:=a.(json.Object)
        if !ok {continue}
        name:=jstr(obj["Name"])
        if !put(g,&g.floats,obj["Float"],name)||!put(g,&g.ints,obj["Int32"],name)||!put(g,&g.halves,obj["Half"],name) {
            note(&g.t.notes,fmt.tprintf("the layout of the attribute %s",name))
            return false
        }
    }
    if len(g.floats)==0&&len(g.ints)==0 {
        note(&g.t.notes,"the layout of the particle's attributes (an older description: extract it again)")
        return false
    }
    return true
}

// The data interface a member of the parameter structure belongs to ("<symbol>_<member>"),
// and the member.
@(private="file")
gpu_member :: proc(g:^Gpu,name:string) -> (^Gpu_Data,string) {
    best:^Gpu_Data
    for &d in g.data {
        if strings.has_prefix(name,d.symbol)&&len(name)>len(d.symbol)&&name[len(d.symbol)]=='_' {
            if best==nil||len(d.symbol)>len(best.symbol) {best=&d}
        }
    }
    if best==nil {return nil,""}
    return best,name[len(best.symbol)+1:]
}

// The offset of a curve's table in the static buffer, which holds the tables of the curves
// the shader reads one after another.
@(private="file")
gpu_static :: proc(g:^Gpu,di:^Interface) -> (int,bool) {
    if !interface_data(g.t,di) {return 0,false}
    for s in g.statics {
        if s[0]==di.index {return s[1],true}
    }
    at:=g.static_size
    append(&g.statics,[3]int{di.index,at,di.count*di.width})
    g.static_size+=di.count*di.width
    return at,true
}

@(private="file")
gpu_field :: proc(t:^Translation,di:^Interface) -> (field:^Cooked_Field,texture:int) {
    props,_:=di.object["Properties"].(json.Object)
    path:=jstr(props["Field"])
    for &f in t.given_fields {
        if f.path==path&&f.size.x>0&&f.size.y>0&&f.size.z>0 {field=&f}
    }
    if field==nil {
        note(&t.notes,fmt.tprintf("the vector field %s, which is not extracted",path))
        return nil,-1
    }
    texture=-1
    for have,i in t.textures {
        if have==path {texture=i}
    }
    if texture<0 {
        append(&t.textures,path)
        texture=len(t.textures)-1
    }
    return
}

@(private="file")
gpu_tile :: proc(di:^Interface,k:int) -> bool {
    props,_:=di.object["Properties"].(json.Object)
    keys:=[3]string{"bTileX","bTileY","bTileZ"}
    on,_:=props[keys[clamp(k,0,2)]].(json.Boolean)
    return bool(on)
}

// The bits of word k of a member of a data interface's structure.
@(private="file")
gpu_interface_word :: proc(g:^Gpu,d:^Gpu_Data,member:string,k:int) -> (string,bool) {
    t:=g.t
    di:=d.di
    props,_:=di.object["Properties"].(json.Object)
    switch {
    case strings.contains(di.class,"Curve"):
        switch member {
        case "MinTime","MaxTime","InvTimeRange":
            key:=member=="InvTimeRange" ? "LUTInvTimeRange" : fmt.tprintf("LUT%s",member)
            v,has:=number(props[key])
            if !has {v=member=="InvTimeRange" ? 1 : 0}
            return float_bits(v),true
        case "CurveLUTNumMinusOne":
            if !interface_data(t,di) {return "",false}
            return fmt.tprintf("%du",max(di.count-1,0)),true
        case "LUTOffset":
            at,has:=gpu_static(g,di)
            if !has {return "",false}
            return fmt.tprintf("%du",at),true
        }
    case strings.contains(di.class,"Array"):
        if member=="ArrayBufferParams" {
            if !interface_data(t,di) {return "",false}
            return fmt.tprintf("%du",k==0 ? di.count : max(di.count-1,0)),true
        }
    case strings.contains(di.class,"VectorField"):
        field,_:=gpu_field(t,di)
        if field==nil||k>2 {return "",false}
        switch member {
        case "TilingAxes":return float_bits(gpu_tile(di,k) ? 1 : 0),true
        case "Dimensions":return float_bits(f64(field.size[k])),true
        case "MinBounds":return float_bits(f64(field.low[k])),true
        case "MaxBounds":return float_bits(f64(field.high[k])),true
        }
    case strings.contains(di.class,"SkeletalMesh"):
        // Where the bones are is not known to a program: each is where the emitter is.
        note(&t.limits,"where the bones of a skeletal mesh are: each is where the emitter is")
        bones,_:=props["FilteredBones"].(json.Array)
        sockets,_:=props["FilteredSockets"].(json.Array)
        switch member {
        case "NumBones":return fmt.tprintf("%du",max(len(bones),1)),true
        case "NumFilteredBones":return fmt.tprintf("%du",len(bones)),true
        case "NumUnfilteredBones","FilteredSocketBoneOffset":return "0u",true
        case "NumFilteredSockets":return fmt.tprintf("%du",len(sockets)),true
        case "RandomMaxBone":return fmt.tprintf("%du",max(len(bones)-1,0)),true
        case "ExcludeBoneIndex":return "0xffffffffu",true
        case "InstanceTransform","InstancePrevTransform":return fmt.tprintf("asuint(nv_owner_matrix(e, 0, %d))",k),true
        case "InstanceRotation","InstancePrevRotation":return fmt.tprintf("asuint(nv_turn_back(nv_emitter_turn(ctx))[%d])",k),true
        case "InstanceInvDeltaTime":return "nf(e.dt > 0.0 ? 1.0 / e.dt : 0.0)",true
        }
    }
    return "",false
}

// The bits of word k of a member of the parameter structure, as the engine sets it each frame.
@(private="file")
gpu_word :: proc(g:^Gpu,name:string,k:int) -> (string,bool) {
    t:=g.t
    plain:=strings.trim_prefix(name,"PREV_")
    if strings.contains(plain,"_Pad") {return "0u",true}
    vector :: proc(sc:^Scope,base:string,k:int) -> string {
        if k>3 {return "0u"}
        obj:=make(json.Object,context.temp_allocator)
        obj["Parameter"]=json.String(fmt.tprintf("%s.%s",base,component(int(k))))
        if strings.has_suffix(base,"Velocity") {return engine_attribute(sc,fmt.tprintf("%s.%s",base,component(int(k))))}
        return parameter(sc,obj)
    }
    named :: proc(sc:^Scope,parameter_name:string) -> string {
        obj:=make(json.Object,context.temp_allocator)
        obj["Parameter"]=json.String(parameter_name)
        return parameter(sc,obj)
    }
    switch plain {
    case "ComponentBufferSizeRead","ComponentBufferSizeWrite":return fmt.tprintf("%du",GPU_STRIDE),true
    case "SimStart":return "(ctx.emitter_age <= ctx.delta_time + 1e-5 ? 1u : 0u)",true
    case "ReadInstanceCountOffset","IndirectDispatchArgsOffset":return "0u",true
    case "WriteInstanceCountOffset":return "1u",true
    case "EmitterTickCounter":return "e.tick",true
    case "EmitterSpawnInfoOffsets":return k<GPU_SPAWN_INFOS ? fmt.tprintf("uint(x.offsets[%d])",k) : "0u",true
    case "EmitterSpawnInfoParams":return k<GPU_SPAWN_INFOS*4 ? fmt.tprintf("asuint(x.infos[%d][%d])",k/4,k%4) : "0u",true
    case "NumSpawnedInstances":return "uint(x.spawned)",true
    case "DispatchThreadIdBounds":return k==0 ? "0x7fffffffu" : "1u",true
    case "DispatchThreadIdToLinear":return k==0 ? "1u" : "0u",true
    case "SimulationStageIterationInfo":
        // No count buffer, no instances, one iteration of one loop.
        words:=[4]string{"0xffffffffu","0u","0x00010000u","0x00010000u"}
        return words[clamp(k,0,3)],true
    case "ParticleIterationStateInfo":return k==0 ? "0xffffffffu" : "0u",true
    case "Engine_WorldDeltaTime","Engine_DeltaTime":return named(&g.sc,"Engine.DeltaTime"),true
    case "Engine_InverseDeltaTime":return named(&g.sc,"Engine.InverseDeltaTime"),true
    case "Engine_Time","Engine_RealTime":return named(&g.sc,"Engine.Time"),true
    case "Engine_QualityLevel":return "3u",true // Epic, what the PC plays at
    case "Engine_Owner_TimeSinceRendered","Engine_Owner_LODDistance","Engine_Owner_LODDistanceFraction":return "nf(0.0)",true
    case "Engine_Owner_ExecutionState","Engine_System_SignificanceIndex","Engine_System_RandomSeed","Engine_System_CurrentTimeStep","Engine_System_NumParticles":return "0u",true
    case "Engine_System_Age":return "nf(e.age)",true
    case "Engine_System_TickCount":return "e.tick",true
    case "Engine_System_NumEmitters","Engine_System_NumEmittersAlive","Engine_System_NumTimeSteps":return "1u",true
    case "Engine_System_TimeStepFraction","Engine_Emitter_SpawnCountScale":return "nf(1.0)",true
    case "Engine_Owner_Position":return vector(&g.sc,"Engine.Owner.Position",k),true
    case "Engine_Owner_Velocity":return vector(&g.sc,"Engine.Owner.Velocity",k),true
    case "Engine_Owner_Scale":return vector(&g.sc,"Engine.Owner.Scale",k),true
    case "Engine_Owner_LWCTile":return "0u",true
    case "Engine_Owner_Rotation":return fmt.tprintf("asuint(nv_turn_back(nv_emitter_turn(ctx))[%d])",min(k,3)),true
    case "Engine_Owner_SystemXAxis","Engine_Owner_SystemYAxis","Engine_Owner_SystemZAxis":
        row:=plain=="Engine_Owner_SystemXAxis" ? 0 : plain=="Engine_Owner_SystemYAxis" ? 1 : 2
        return fmt.tprintf("nf(e.l2w[%d])",row*4+min(k,2)),true
    case "Engine_Emitter_NumParticles":return engine_attribute(&g.sc,"Engine.Emitter.NumParticles"),true
    case "Engine_Emitter_TotalSpawnedParticles":return "e.born",true
    case "Emitter_Age":return named(&g.sc,"Emitter.Age"),true
    case "Emitter_RandomSeed":return named(&g.sc,"Emitter.RandomSeed"),true
    case "Engine_Emitter_InstanceSeed":return named(&g.sc,"Engine.Emitter.InstanceSeed"),true
    }
    matrices:=[6]string{"Engine_Owner_SystemLocalToWorld","Engine_Owner_SystemWorldToLocal","Engine_Owner_SystemLocalToWorldTransposed",
        "Engine_Owner_SystemWorldToLocalTransposed","Engine_Owner_SystemLocalToWorldNoScale","Engine_Owner_SystemWorldToLocalNoScale"}
    for m,which in matrices {
        if plain==m {return fmt.tprintf("asuint(nv_owner_matrix(e, %d, %d))",which,min(k,15)),true}
    }
    if d,member:=gpu_member(g,plain);d!=nil&&d.di!=nil {return gpu_interface_word(g,d,member,k)}
    _=t
    return "",false
}

// The source of a uint4 function of a constant buffer: the words of each register as cases.
@(private="file")
gpu_buffer_function :: proc(w:^strings.Builder,name:string,words:map[int]string) {
    fmt.sbprintf(w,"uint4 %s(Dx_Env x, int r) {{\n    Nv e = x.n; Mirai_Vfx_Context ctx = x.ctx;\n    switch (r) {{\n",name)
    registers:=make([dynamic]int,context.temp_allocator)
    for word in words {
        r:=word/4
        seen:=false
        for have in registers {seen||=have==r}
        if !seen {append(&registers,r)}
    }
    for i in 1..<len(registers) {
        for j:=i;j>0&&registers[j]<registers[j-1];j-=1 {registers[j],registers[j-1]=registers[j-1],registers[j]}
    }
    for r in registers {
        parts:[4]string
        for c in 0..<4 {parts[c]=words[r*4+c] or_else "0u"}
        fmt.sbprintf(w,"    case %d: return uint4(%s, %s, %s, %s);\n",r,parts[0],parts[1],parts[2],parts[3])
    }
    strings.write_string(w,"    default: return uint4(0u);\n    }\n}\n")
}

@(private="file")
gpu_register_functions :: proc(w:^strings.Builder,kind:string,list:[]string) {
    fmt.sbprintf(w,"uint nv_%s(Attributes a, int r) {{\n    switch (r) {{\n",kind)
    for f,r in list {
        if f!="" {fmt.sbprintf(w,"    case %d: return a.%s;\n",r,ident("f_",f))}
    }
    strings.write_string(w,"    default: return 0u;\n    }\n}\n")
    fmt.sbprintf(w,"void nv_%s_set(inout Attributes a, int r, uint v) {{\n    switch (r) {{\n",kind)
    for f,r in list {
        if f!="" {fmt.sbprintf(w,"    case %d: a.%s = v; break;\n",r,ident("f_",f))}
    }
    strings.write_string(w,"    default: break;\n    }\n}\n")
}

@(private="file")
GPU_HOST_PRELUDE :: `
// The engine's transforms of the emitter for the shader, rows as Unreal multiplies a row by
// them: 0 local to world, 1 world to local, 2 and 3 those transposed, 4 and 5 those without
// scale.
float nv_owner_matrix(Nv e, int which, int k) {
    float m[16];
    bool scaled = which < 4;
    bool inverse = which == 1 || which == 3 || which == 5;
    bool transposed = which == 2 || which == 3;
    for (int i = 0; i < 16; i++) m[i] = inverse ? e.w2l[i] : e.l2w[i];
    if (scaled) {
        float3 s = e.scale;
        if (!inverse) {
            for (int c = 0; c < 3; c++) { m[c] *= s.x; m[4 + c] *= s.y; m[8 + c] *= s.z; }
        } else {
            float3 inv = float3(1.0) / max(s, float3(1e-20));
            for (int r = 0; r < 4; r++) { m[r * 4] *= inv.x; m[r * 4 + 1] *= inv.y; m[r * 4 + 2] *= inv.z; }
        }
    }
    int at = transposed ? (k % 4) * 4 + k / 4 : k;
    return m[clamp(at, 0, 15)];
}
// A volume texture of a vector field at a point of its unit cube, as a bilinear sampler reads
// it: the axes that tile wrap, the others keep their edge.
float3 nv_field_unit(uint image, float3 size, float3 tile, float value_low, float value_high, float3 uvw) {
    float3 at = uvw * size - 0.5;
    float3 base = floor(at);
    float3 f = at - base;
    float3 v = float3(0.0);
    for (int i = 0; i < 8; i++) {
        float3 corner = float3(float(i & 1), float((i >> 1) & 1), float((i >> 2) & 1));
        float3 weight = lerp(1.0 - f, f, corner);
        v += nv_field_cell(image, size, base + corner, tile) * (weight.x * weight.y * weight.z);
    }
    return value_low + v * (value_high - value_low);
}
`

// The host of the shader of a GPU compute script and the bodies of initialize and update.
// ok is false (with notes) where the shader reads something that has no answer here.
@(private)
gpu_program :: proc(t:^Translation,emitter,script:json.Object,spawns:[]Gpu_Spawn) -> (host,initialize,update:string,ok:bool) {
    shader,_:=script["Shader"].(json.Object)
    g:=Gpu{t=t,floats=make([dynamic]string,context.temp_allocator),ints=make([dynamic]string,context.temp_allocator),
        halves=make([dynamic]string,context.temp_allocator),data=make([dynamic]Gpu_Data,context.temp_allocator),
        statics=make([dynamic][3]int,context.temp_allocator)}
    g.sc=Scope{t=t,defs=make(map[string]json.Object,allocator=context.temp_allocator),done=make(map[string]bool,allocator=context.temp_allocator)}
    if !gpu_registers(&g,emitter) {return}
    infos,_:=script["ShaderDataInterfaces"].(json.Array)
    for item in infos {
        obj,is_obj:=item.(json.Object)
        if !is_obj {continue}
        append(&g.data,Gpu_Data{jstr(obj["Symbol"]),interface_find(t,jstr(obj["DataInterface"]))})
    }
    source:=jstr(shader["Source"])
    if !strings.contains(source,"void dx_compute(") {note(&t.notes,"the shader of the GPU script (no dx_compute in its source)");return}

    // What each constant buffer, buffer and texture is.
    globals,external,previous:=-1,-1,-1
    buffers,_:=shader["Buffers"].(json.Array)
    for item in buffers {
        obj,_:=item.(json.Object)
        slot,_:=whole(obj["Slot"])
        switch jstr(obj["Type"]) {
        case "hostlayout.$Globals":globals=int(slot)
        case "FNiagaraExternalParameters":external=int(slot)
        case "PREV_FNiagaraExternalParameters":previous=int(slot)
        }
    }
    global_words:=make(map[int]string,allocator=context.temp_allocator)
    constants,_:=shader["Constants"].(json.Array)
    for item in constants {
        obj,_:=item.(json.Object)
        name:=jstr(obj["Name"])
        buffer,_:=whole(obj["Buffer"])
        offset,_:=whole(obj["Offset"])
        size,_:=whole(obj["Size"])
        if int(buffer)!=globals||offset<0||size<4||offset%4!=0||size>512 {
            note(&t.notes,fmt.tprintf("the GPU parameter %s in the constant buffer %d",name,buffer))
            continue
        }
        for k in 0..<int(size)/4 {
            word,known:=gpu_word(&g,name,k)
            if !known {
                note(&t.notes,fmt.tprintf("the GPU parameter %s",name))
                break
            }
            global_words[int(offset)/4+k]=word
        }
    }
    external_size:=0
    if n,has:=whole(shader["ExternalSize"]);has {external_size=int(n)}
    external_words,previous_words:=make(map[int]string,allocator=context.temp_allocator),make(map[int]string,allocator=context.temp_allocator)
    externals,_:=shader["External"].(json.Array)
    for item in externals {
        obj,_:=item.(json.Object)
        name:=jstr(obj["Name"])
        type:=jstr(obj["Type"])
        offset,_:=whole(obj["Offset"])
        bits,_:=obj["Bits"].(json.Array)
        is_previous:=strings.has_prefix(name,"PREV_")
        words:=is_previous ? &previous_words : &external_words
        base:=int(offset)-(is_previous ? external_size : 0)
        if base<0||base%4!=0 {continue}
        n:=type_words(type)
        if n==0 {n=max(len(bits),1)}
        for k in 0..<n {
            component:=n==1 ? name : fmt.tprintf("%s.%s",name,component(k))
            p:=make(json.Object,context.temp_allocator)
            p["Parameter"]=json.String(component)
            p["Type"]=json.String(type)
            if strings.contains(strings.trim_prefix(name,"PREV_"),"User.") {p["Source"]=json.String("User")}
            if k<len(bits) {
                // The stored bits answer what neither the user nor the emitter gives.
                v,_:=whole(bits[k])
                p["Value"]=json.Integer(v)
                p["Type"]=json.String("bits")
            }
            words[base/4+k]=parameter(&g.sc,p)
        }
    }

    resources,_:=shader["Resources"].(json.Array)
    Resource :: struct {name,class:string,slot:int}
    list:=make([dynamic]Resource,context.temp_allocator)
    for item in resources {
        obj,_:=item.(json.Object)
        slot,_:=whole(obj["Slot"])
        append(&list,Resource{jstr(obj["Name"]),jstr(obj["Class"]),int(slot)})
    }

    w:=strings.builder_make(context.temp_allocator)
    strings.write_string(&w,cooked.DX_DUAL_PRELUDE)
    strings.write_string(&w,GPU_HOST_PRELUDE)
    fmt.sbprintf(&w,"static const int NV_STRIDE = %d;\n",GPU_STRIDE)
    fmt.sbprintf(&w,`// What the shader reads and writes: the frame, the particle as it was (i) and as the shader
// writes it (a), which thread it runs as, and the spawn infos of the frame.
struct Dx_Env {{
    Mirai_Vfx_Context ctx;
    Parameters p;
    Nv n;
    Attributes i;
    Attributes a;
    bool wrote;
    int thread;
    int start;
    int spawned;
    int offsets[%d];
    float4 infos[%d];
}};
`,GPU_SPAWN_INFOS,GPU_SPAWN_INFOS)
    gpu_register_functions(&w,"float",g.floats[:])
    gpu_register_functions(&w,"int",g.ints[:])
    gpu_register_functions(&w,"half",g.halves[:])
    gpu_buffer_function(&w,"nv_cb_globals",global_words)
    gpu_buffer_function(&w,"nv_cb_external",external_words)
    gpu_buffer_function(&w,"nv_cb_previous",previous_words)
    strings.write_string(&w,"uint4 nv_cb(Dx_Env x, int slot, int r) {\n")
    if globals>=0 {fmt.sbprintf(&w,"    if (slot == %d) return nv_cb_globals(x, r);\n",globals)}
    if external>=0 {fmt.sbprintf(&w,"    if (slot == %d) return nv_cb_external(x, r);\n",external)}
    if previous>=0 {fmt.sbprintf(&w,"    if (slot == %d) return nv_cb_previous(x, r);\n",previous)}
    strings.write_string(&w,"    return uint4(0u);\n}\n")
    strings.write_string(&w,"float4 dx_cb(Dx_Env x, int slot, int r) { return asfloat(nv_cb(x, slot, r)); }\n")
    strings.write_string(&w,"int4 dx_cb_i(Dx_Env x, int slot, int r) { return int4(nv_cb(x, slot, r)); }\n")

    // Buffers: the particle, the static buffer of the curves, the data of the interfaces.
    loads:=strings.builder_make(context.temp_allocator)
    for r in list {
        if r.class!="SRV" {continue}
        value:=""
        switch r.name {
        case "InputFloat":value="float4(fv(nv_float(x.i, i / NV_STRIDE)), 0.0, 0.0, 0.0)"
        case "InputInt":value="asfloat(int4(int(nv_int(x.i, i / NV_STRIDE)), 0, 0, 0))"
        case "InputHalf":value="float4(fv(nv_half(x.i, i / NV_STRIDE)), 0.0, 0.0, 0.0)"
        case "StaticInputFloat":value="float4(nv_static(i), 0.0, 0.0, 0.0)"
        // Free IDs: the particle's own number among those the emitter started.
        case "FreeIDList":value="asfloat(int4(int(x.ctx.born) + i, 0, 0, 0))"
        case:
            d,member:=gpu_member(&g,r.name)
            if d==nil||d.di==nil {break}
            di:=d.di
            switch {
            case member=="ArrayReadBuffer"&&interface_data(t,di):
                parts:[4]string
                for c in 0..<4 {parts[c]=c<di.width ? fmt.tprintf("NV_DATA%d[clamp(i, 0, %d) * %d + %d]",di.index,max(di.count-1,0),di.width,c) : "0.0"}
                value=fmt.tprintf("float4(%s, %s, %s, %s)",parts[0],parts[1],parts[2],parts[3])
            case member=="CurveLUT":
                if at,has:=gpu_static(&g,di);has {value=fmt.tprintf("float4(nv_static(%d + i), 0.0, 0.0, 0.0)",at)}
            case member=="FilteredAndUnfilteredBones":
                value="asfloat(int4(i, 0, 0, 0))"
            case member=="MeshCurrSamplingBonesBuffer"||member=="MeshPrevSamplingBonesBuffer":
                // Each bone at the place of the skeletal mesh, unturned and of scale one.
                value="(i % 3 == 1 ? float4(0.0, 0.0, 0.0, 1.0) : i % 3 == 2 ? float4(1.0, 1.0, 1.0, asfloat(-1)) : float4(0.0))"
            }
        }
        if value=="" {
            if strings.contains(source,fmt.tprintf("dx_buffer(e,%d,",r.slot))||strings.contains(source,fmt.tprintf("dx_buffer_i(e,%d,",r.slot)) {
                note(&t.notes,fmt.tprintf("the GPU buffer %s",r.name))
            }
            continue
        }
        fmt.sbprintf(&loads,"    if (slot == %d) return %s;\n",r.slot,value)
    }
    // The static buffer: the tables of the curves one after another.
    strings.write_string(&w,"float nv_static(int i) {\n")
    for s in g.statics {fmt.sbprintf(&w,"    if (i >= %d && i < %d) return NV_DATA%d[i - %d];\n",s[1],s[1]+s[2],s[0],s[1])}
    strings.write_string(&w,"    return 0.0;\n}\n")
    fmt.sbprintf(&w,"float4 nv_buffer(Dx_Env x, int slot, int i) {{\n%s    return float4(0.0);\n}}\n",strings.to_string(loads))
    strings.write_string(&w,"D4 dx_buffer(Dx_Env x, int slot, int i) { return d4_c(nv_buffer(x, slot, i)); }\n")
    strings.write_string(&w,"int4 dx_buffer_i(Dx_Env x, int slot, int i) { return asint(nv_buffer(x, slot, i)); }\n")

    // Unordered access views: the particle written, and the count of instances read.
    stores,stores_i:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    counts:=-1
    for r in list {
        if r.class!="UAV" {continue}
        switch r.name {
        case "RWOutputFloat":fmt.sbprintf(&stores,"    if (slot == %d) {{ nv_float_set(x.a, i / NV_STRIDE, asuint(v.v)); x.wrote = true; }}\n",r.slot)
        case "RWOutputHalf":fmt.sbprintf(&stores,"    if (slot == %d) {{ nv_half_set(x.a, i / NV_STRIDE, asuint(v.v)); x.wrote = true; }}\n",r.slot)
        case "RWOutputInt":fmt.sbprintf(&stores_i,"    if (slot == %d) {{ nv_int_set(x.a, i / NV_STRIDE, uint(v)); x.wrote = true; }}\n",r.slot)
        case "RWInstanceCounts":counts=r.slot
        }
    }
    fmt.sbprintf(&w,"void dx_uav_store(inout Dx_Env x, int slot, int i, D v) {{\n%s}}\n",strings.to_string(stores))
    fmt.sbprintf(&w,"void dx_uav_store_i(inout Dx_Env x, int slot, int i, int v) {{\n%s}}\n",strings.to_string(stores_i))
    // The instance count the shader reads is where its spawned particles start: those before
    // are particles it updates.
    fmt.sbprintf(&w,"int4 dx_uav_i(Dx_Env x, int slot, int i) {{ return slot == %d ? int4(x.start, 0, 0, 0) : int4(0); }}\n",counts)
    strings.write_string(&w,"D4 dx_uav(Dx_Env x, int slot, int i) { return d4_c(asfloat(dx_uav_i(x, slot, i))); }\n")

    // Textures: the volumes of vector fields.
    samples:=strings.builder_make(context.temp_allocator)
    for r in list {
        if r.class!="Texture" {continue}
        d,member:=gpu_member(&g,r.name)
        if d==nil||d.di==nil||member!="Texture"||!strings.contains(d.di.class,"VectorField") {
            if strings.contains(source,fmt.tprintf("(e,%d,",r.slot)) {note(&t.notes,fmt.tprintf("the GPU texture %s",r.name))}
            continue
        }
        field,texture:=gpu_field(t,d.di)
        if field==nil {continue}
        fmt.sbprintf(&samples,"    if (t == %d) return d4_c(float4(nv_field_unit(x.p.field%d, float3(%d.0, %d.0, %d.0), float3(%d.0, %d.0, %d.0), %s, %s, float3(u.v, v.v, w.v)), 0.0));\n",
            r.slot,texture,field.size.x,field.size.y,field.size.z,int(gpu_tile(d.di,0)),int(gpu_tile(d.di,1)),int(gpu_tile(d.di,2)),
            slang_f32(field.value_low),slang_f32(field.value_high))
    }
    fmt.sbprintf(&w,"D4 dx_sample_level3(Dx_Env x, int t, int s, D u, D v, D w, float lod) {{\n%s    return d4_c(float4(0.0));\n}}\n",strings.to_string(samples))
    for unread in ([]string{"dx_sample_level(","dx_sample(","dx_sample_grad(","dx_load(","dx_raw(","dx_raw_i(","dx_input","dx_output","dx_discard("}) {
        if strings.contains(source,unread) {note(&t.notes,fmt.tprintf("what the GPU shader reads by %s",strings.trim_suffix(unread,"(")))}
    }
    // The thread: one of a line of groups of the threads the shader declares.
    group:=64
    if threads,has:=shader["Threads"].(json.Array);has&&len(threads)>0 {
        if n,known:=whole(threads[0]);known&&n>0&&n<=1024 {group=int(n)}
    }
    strings.write_string(&w,"int dx_thread(Dx_Env x, int c) { return c == 0 ? x.thread : 0; }\n")
    fmt.sbprintf(&w,"int dx_group(Dx_Env x, int c) {{ return c == 0 ? x.thread / %d : 0; }}\n",group)
    fmt.sbprintf(&w,"int dx_thread_in_group(Dx_Env x, int c) {{ return c == 0 ? x.thread %% %d : 0; }}\n",group)
    fmt.sbprintf(&w,"int dx_thread_flat(Dx_Env x) {{ return x.thread %% %d; }}\n",group)

    // The spawn infos of the frame, as the engine passes those with particles: where each
    // starts among the spawned particles, its interval, interpolation start and group.
    strings.write_string(&w,"void nv_spawn_infos(inout Dx_Env x) {\n    Mirai_Vfx_Context ctx = x.ctx;\n    int used = 0; int total = 0;\n")
    for s in spawns {
        word :: proc(n:int,float:bool) -> string {
            if n<0 {return float ? "0.0" : "0"}
            return float ? fmt.tprintf("asfloat(mirai_vfx_state_load(ctx, %du))",n) : fmt.tprintf("int(mirai_vfx_state_load(ctx, %du))",n)
        }
        fmt.sbprintf(&w,"    {{ int count = %s; if (count > 0 && used < %d) {{ x.infos[used] = float4(%s, %s, asfloat(%s), asfloat(total)); total += count; x.offsets[used] = total; used++; }} }}\n",
            word(s.count,false),GPU_SPAWN_INFOS,word(s.interval,true),word(s.start,true),word(s.group,false))
    }
    fmt.sbprintf(&w,"    for (int k = used; k < %d; k++) {{ x.infos[k] = float4(0.0, 0.0, asfloat(0), asfloat(total)); x.offsets[k] = 0x7fffffff; }}\n}}\n",GPU_SPAWN_INFOS)
    strings.write_string(&w,`Dx_Env nv_dx(Mirai_Vfx_Context ctx, Parameters p, Nv n, Attributes a) {
    Dx_Env x;
    x.ctx = ctx; x.p = p; x.n = n; x.i = a; x.a = a; x.wrote = false;
    x.thread = 0; x.start = 0; x.spawned = 0;
    for (int k = 0; k < 8; k++) { x.offsets[k] = 0x7fffffff; x.infos[k] = float4(0.0); }
    return x;
}
`)
    strings.write_string(&w,source)
    host=strings.to_string(w)
    initialize="    Dx_Env x = nv_dx(ctx, p, e, a);\n    x.thread = int(ctx.birth - ctx.born); x.start = 0; x.spawned = int(ctx.spawned);\n    nv_spawn_infos(x);\n    dx_compute(x);\n    a = x.a;\n    bool keep = x.wrote;\n"
    update="    Dx_Env x = nv_dx(ctx, p, e, a);\n    x.thread = int(ctx.particle); x.start = x.thread + 1; x.spawned = 0;\n    dx_compute(x);\n    a = x.a;\n    bool keep = x.wrote;\n"
    ok=true
    return
}

// The words of a value of a Niagara type, 0 for a type not known here.
@(private="file")
type_words :: proc(type:string) -> int {
    switch {
    case strings.contains(type,"Float"),strings.contains(type,"Int32"),strings.contains(type,"Bool"):return 1
    case strings.contains(type,"Vector2"):return 2
    case strings.contains(type,"Vector3"),strings.contains(type,"Position"):return 3
    case strings.contains(type,"Vector4"),strings.contains(type,"Color"),strings.contains(type,"Quat"):return 4
    }
    return 0
}
