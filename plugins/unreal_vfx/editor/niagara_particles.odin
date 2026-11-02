package unreal_vfx_editor

import "core:fmt"
import "core:strings"

// The bodies of the functions that read the particles of another emitter
// (ParticleRead) and of the grids of neighbors (NeighborGrid3D).
//
// An index of another emitter is the slot of a particle in its range, and
// its number of particles the slots of the range, of which those not alive
// are not valid; an id is its slot and its seed. The attributes Mirai's
// particle keeps (Position, Velocity) come from it, the others from the
// words of the Attributes of the other program, laid out for the system.
//
// A cell of a grid of neighbors keeps how many there are in its first word
// and the index of each, plus one, in those after it: a cell at zero has none.

@(private)
niagara_read_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base,specifier:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    ins,outs:=niagara_split(params)
    R:=di.resource
    b:=strings.builder_make(context.temp_allocator)
    out_ :: proc(list:[]Hlsl_Field,i:int) -> string {return i<len(list)?list[i].name:"niagara_unused"}
    in_ :: proc(list:[]Hlsl_Field,i:int) -> string {return i<len(list)?list[i].name:"0"}
    // A slot from the input: an index, or an id whose tag is the seed of the particle.
    by_id:=len(ins)>0 && ins[0].type=="NiagaraID"
    slot:=by_id?fmt.tprintf("niagara_read_slot(%s, %s.Index, %s.AcquireTag)",R,in_(ins,0),in_(ins,0)):fmt.tprintf("niagara_read_slot(%s, %s, -1)",R,in_(ins,0))
    switch base {
    case "GetNumParticles":
        fmt.sbprintf(&b,"    %s = int(mirai_vfx_emitter_capacity(niagara_ctx, %s));\n",out_(outs,0),R)
        return strings.to_string(b),true
    case "GetNumSpawnedParticles":
        fmt.sbprintf(&b,"    %s = int(mirai_vfx_emitter_births(niagara_ctx, %s).y);\n",out_(outs,0),R)
        return strings.to_string(b),true
    case "GetParticleIndex","GetParticleIndexFromIDTable":
        fmt.sbprintf(&b,"    int slot = %s;\n",slot)
        if len(outs)>=2 {
            fmt.sbprintf(&b,"    %s = slot >= 0;\n    %s = slot;\n",outs[0].name,outs[1].name)
        } else {
            fmt.sbprintf(&b,"    %s = slot;\n",out_(outs,0))
        }
        return strings.to_string(b),true
    case "GetIDAtSpawnIndex","GetSpawnedIDAtIndex":
        // The id of a particle started this frame, which may not have started yet: its birth.
        fmt.sbprintf(&b,"    uint2 births = mirai_vfx_emitter_births(niagara_ctx, %s);\n    uint seed;\n",R)
        fmt.sbprintf(&b,"    %s = %s >= 0 && uint(%s) < births.y;\n",out_(outs,0),in_(ins,0),in_(ins,0))
        fmt.sbprintf(&b,"    mirai_vfx_emitter_birth(niagara_ctx, %s, births.x + uint(max(%s, 0)), seed);\n",R,in_(ins,0))
        fmt.sbprintf(&b,"    %s.Index = %s ? -2 - int(births.x + uint(%s)) : -1; %s.AcquireTag = int(seed);\n",out_(outs,1),out_(outs,0),in_(ins,0),out_(outs,1))
        return strings.to_string(b),true
    }
    if !strings.has_prefix(base,"Get") || (!strings.has_suffix(base,"ByIndex") && !strings.has_suffix(base,"ByID")) || len(outs)<2 {return}
    name:=niagara_attribute_named(specifier)
    target:=outs[1]
    type:=strings.trim_prefix(target.type,"out ")
    fmt.sbprintf(&b,"    int slot = %s;\n    %s = slot >= 0;\n",slot,outs[0].name)
    switch name {
    case "Position":
        fmt.sbprintf(&b,"    %s = niagara_read_position(%s, slot, %v);\n",target.name,R,w.local)
    case "Velocity":
        fmt.sbprintf(&b,"    %s = niagara_read_velocity(%s, slot, %v);\n",target.name,R,w.local)
    case "ID":
        fmt.sbprintf(&b,"    %s.Index = slot; %s.AcquireTag = niagara_read_seed(%s, slot);\n",target.name,target.name,R)
    case "UniqueID":
        fmt.sbprintf(&b,"    %s = niagara_read_seed(%s, slot);\n",target.name,R)
    case:
        other:=w.system.emitters[di.other] if di.other!="" else nil
        if other==nil || other.source==nil {
            fmt.sbprintf(&b,"    %s = (%s)0;\n",target.name,type)
            if di.other=="" {
                append(&w.problems,fmt.tprintf("%s reads %s of an emitter it does not name: it gives zero",di.name,name))
            } else {
                append(&w.problems,fmt.tprintf("%s reads %s of %s, which is not translated: it gives zero",di.name,name,di.other))
            }
            return strings.to_string(b),true
        }
        word,kind,found:=niagara_attr_word(other.source.attributes,name)
        if !found {
            fmt.sbprintf(&b,"    %s = (%s)0;\n",target.name,type)
            append(&w.problems,fmt.tprintf("%s reads %s, which %s does not keep: it gives zero",di.name,name,di.other))
            return strings.to_string(b),true
        }
        scalar,count:=niagara_components(kind)
        if type=="NiagaraID" {
            fmt.sbprintf(&b,"    %s.Index = asint(niagara_read_word(%s, slot, %d)); %s.AcquireTag = asint(niagara_read_word(%s, slot, %d));\n",target.name,R,word,target.name,R,word+1)
            break
        }
        value:=strings.builder_make(context.temp_allocator)
        if count>1 {fmt.sbprintf(&value,"%s(",kind)}
        for i in 0..<count {
            if i>0 {strings.write_string(&value,", ")}
            switch scalar {
            case "float": fmt.sbprintf(&value,"asfloat(niagara_read_word(%s, slot, %d))",R,word+i)
            case "int": fmt.sbprintf(&value,"asint(niagara_read_word(%s, slot, %d))",R,word+i)
            case "bool": fmt.sbprintf(&value,"(niagara_read_word(%s, slot, %d) != 0u)",R,word+i)
            case: fmt.sbprintf(&value,"niagara_read_word(%s, slot, %d)",R,word+i)
            }
        }
        if count>1 {strings.write_byte(&value,')')}
        fmt.sbprintf(&b,"    %s = (%s)(%s);\n",target.name,type,strings.to_string(value))
    }
    return strings.to_string(b),true
}

@(private)
niagara_neighbors_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base,specifier:string,params:[]Hlsl_Field,written:bool) -> (body:string,ok:bool) {
    ins,outs:=niagara_split(params)
    R:=di.resource
    b:=strings.builder_make(context.temp_allocator)
    out_ :: proc(list:[]Hlsl_Field,i:int) -> string {return i<len(list)?list[i].name:"niagara_unused"}
    in_ :: proc(list:[]Hlsl_Field,i:int) -> string {return i<len(list)?list[i].name:"0"}
    M:=di.max_neighbors
    switch base {
    case "MaxNeighborsPerCell":
        fmt.sbprintf(&b,"    %s = %d;\n",out_(outs,0),M)
    case "SimulationToUnit":
        fmt.sbprintf(&b,"    %s = mul(float4(%s, 1.0), %s).xyz;\n",out_(outs,0),in_(ins,0),in_(ins,1))
    case "UnitToSimulation":
        fmt.sbprintf(&b,"    %s = mul(float4(%s, 1.0), %s).xyz;\n",out_(outs,0),in_(ins,0),in_(ins,1))
    case "NeighborGridIndexToLinear":
        fmt.sbprintf(&b,"    int3 n = niagara_grid_cells(%s);\n    %s = %s + %d * (%s + n.x * (%s + n.y * %s));\n",R,out_(outs,0),in_(ins,3),M,in_(ins,0),in_(ins,1),in_(ins,2))
    case "GetParticleNeighbor":
        if len(ins)>=4 {
            // Of a cell and an index among its neighbors: the particle and its tag (none: -1).
            fmt.sbprintf(&b,"    int3 n = niagara_grid_cells(%s);\n    int at = %s + n.x * (%s + n.y * %s);\n",R,in_(ins,0),in_(ins,1),in_(ins,2))
            fmt.sbprintf(&b,"    %s = int(niagara_cell_word(%s, at, 1 + %s, %v)) - 1;\n",out_(outs,0),R,in_(ins,3),written)
            if len(outs)>1 {fmt.sbprintf(&b,"    %s = 0;\n",outs[1].name)}
        } else {
            fmt.sbprintf(&b,"    %s = int(niagara_cell_word(%s, %s / %d, 1 + %s %% %d, %v)) - 1;\n",out_(outs,0),R,in_(ins,0),M,in_(ins,0),M,written)
        }
    case "SetParticleNeighbor":
        fmt.sbprintf(&b,"    niagara_cell_store(%s, %s / %d, 1 + %s %% %d, uint(%s + 1));\n",R,in_(ins,0),M,in_(ins,0),M,in_(ins,1))
        if len(outs)>0 {fmt.sbprintf(&b,"    %s = (%s)0;\n",outs[0].name,strings.trim_prefix(outs[0].type,"out "))}
    case "GetParticleNeighborCount":
        if len(ins)>=3 {
            fmt.sbprintf(&b,"    int3 n = niagara_grid_cells(%s);\n    %s = int(niagara_cell_word(%s, %s + n.x * (%s + n.y * %s), 0, %v));\n",R,out_(outs,0),R,in_(ins,0),in_(ins,1),in_(ins,2),written)
        } else {
            fmt.sbprintf(&b,"    %s = int(niagara_cell_word(%s, %s, 0, %v));\n",out_(outs,0),R,in_(ins,0),written)
        }
    case "SetParticleNeighborCount":
        fmt.sbprintf(&b,"    %s = int(niagara_cell_add(%s, %s, 0, uint(%s)));\n",out_(outs,0),R,in_(ins,0),in_(ins,1))
    case "AddParticle":
        cell:=""
        enabled:="true"
        index:=""
        if len(ins)>=4 && ins[0].type=="bool" {
            // Enabled, a position in index space, the particle and its tag.
            enabled=in_(ins,0)
            cell=fmt.tprintf("int3(floor(%s))",in_(ins,1))
            index=in_(ins,2)
        } else {
            cell=fmt.tprintf("int3(%s, %s, %s)",in_(ins,0),in_(ins,1),in_(ins,2))
            index=in_(ins,3)
        }
        fmt.sbprintf(&b,"    int3 n = niagara_grid_cells(%s);\n    int3 c = %s;\n    bool inside = %s && all(c >= int3(0)) && all(c < n);\n",R,cell,enabled)
        fmt.sbprintf(&b,"    int at = c.x + n.x * (c.y + n.y * c.z);\n    uint before = inside ? niagara_cell_add(%s, at, 0, 1u) : 0xFFFFFFFFu;\n",R)
        fmt.sbprintf(&b,"    bool room = inside && before < %du;\n    if (room) niagara_cell_store(%s, at, 1 + int(before), uint(%s + 1));\n",M,R,index)
        fmt.sbprintf(&b,"    %s = room;\n",out_(outs,0))
    case:
        // What a grid of neighbors shares with the other grids: cells, units and indices.
        return niagara_grid_body(w,di,base,specifier,params)
    }
    return strings.to_string(b),true
}

// The queries of the scene of CollisionQuery: the depth of the view, the
// distance field from traced rays (niagara.slang), and the traces of the CPU
// as a ray through the traced scene, answered in the same frame. Each takes
// its values out of locals, so an out bool or int of the script takes them alike.
@(private)
niagara_collision_body :: proc(base:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    ins,outs:=niagara_split(params)
    if len(ins)<1 {return}
    b:=strings.builder_make(context.temp_allocator)
    out_type :: proc(f:Hlsl_Field) -> string {return strings.trim_prefix(f.type,"out ")}
    switch base {
    case "QuerySceneDepthGPU","QueryCustomDepthGPU","QueryScenePartialDepthGPU":
        if len(outs)<5 {return}
        fmt.sbprintf(&b,"    float depth; float3 camera; bool inside; float3 world; float3 normal;\n    niagara_query_scene_depth(%s, depth, camera, inside, world, normal);\n",ins[0].name)
        values:=[5]string{"depth","camera","inside","world","normal"}
        for v,i in values {fmt.sbprintf(&b,"    %s = (%s)(%s);\n",outs[i].name,out_type(outs[i]),v)}
    case "QueryMeshDistanceFieldGPU":
        if len(outs)<3 {return}
        fmt.sbprintf(&b,"    float distance; float3 gradient; bool valid;\n    niagara_query_distance(%s, distance, gradient, valid);\n",ins[0].name)
        values:=[3]string{"distance","gradient","valid"}
        for v,i in values {fmt.sbprintf(&b,"    %s = (%s)(%s);\n",outs[i].name,out_type(outs[i]),v)}
    case "PerformCollisionQuerySyncCPU","PerformCollisionQueryAsyncCPU":
        named :: proc(fields:[]Hlsl_Field,name:string) -> string {
            for f in fields {if f.name==name {return f.name}}
            return ""
        }
        start,end,skip:=named(ins,"In_TraceStartWorld"),named(ins,"In_TraceEndWorld"),named(ins,"In_SkipTrace")
        if start=="" || end=="" {return}
        fmt.sbprintf(&b,"    float3 from = mirai_point(%s);\n    float3 along = mirai_point(%s) - from;\n    Mirai_Vfx_Hit h = (Mirai_Vfx_Hit)0;\n",start,end)
        fmt.sbprintf(&b,"    if (%s) h = mirai_vfx_trace(niagara_ctx, from, along, length(along));\n",skip=="" ? "true" : fmt.tprintf("!bool(%s)",skip))
        // The friction and restitution of Unreal's default physical material:
        // Mirai's surfaces keep none of their own.
        VALUES :: [?][2]string{
            {"Out_CollisionValid","h.hit"},{"Out_IsTraceInsideMesh","h.hit && h.inside"},
            {"Out_CollisionPosWorld","niagara_point(from + normalize(along) * h.distance)"},{"Out_CollisionNormal","niagara_direction(h.normal)"},
            {"Out_CollisionMaterialFriction","0.7"},{"Out_CollisionMaterialRestitution","0.3"},
        }
        outer: for o in outs {
            for v in VALUES {
                if o.name!=v[0] {continue}
                fmt.sbprintf(&b,"    %s = (%s)(%s);\n",o.name,out_type(o),v[1])
                continue outer
            }
            fmt.sbprintf(&b,"    %s = (%s)0;\n",o.name,out_type(o))
        }
    case:
        return
    }
    return strings.to_string(b),true
}

// The functions of GBuffer: the depth, normal and roughness of the first view
// of the window at a point of the screen; its base color and metallic are not
// in the passes of the particles.
@(private)
niagara_gbuffer_body :: proc(base:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    ins,outs:=niagara_split(params)
    if len(ins)<1 || len(outs)<2 {return}
    value:=""
    switch base {
    case "DecodeDepth","DecodeSceneDepth": value=fmt.tprintf("mirai_vfx_scene_depth(%s) * 100.0",ins[0].name)
    case "DecodeWorldNormal": value=fmt.tprintf("niagara_direction(mirai_vfx_scene_normal(%s))",ins[0].name)
    case "DecodeRoughness": value=fmt.tprintf("mirai_vfx_scene_roughness(%s)",ins[0].name)
    case: return
    }
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"    bool valid = all(%s >= float2(0.0)) && all(%s < float2(1.0)) && mirai_vfx_scene_depth(%s) > 0.0;\n",ins[0].name,ins[0].name,ins[0].name)
    fmt.sbprintf(&b,"    %s = (%s)valid;\n    %s = (%s)(%s);\n",outs[0].name,strings.trim_prefix(outs[0].type,"out "),outs[1].name,strings.trim_prefix(outs[1].type,"out "),value)
    return strings.to_string(b),true
}
