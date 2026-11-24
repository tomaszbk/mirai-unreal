package unreal_vfx_editor

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:slice"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import stbi "vendor:stb/image"

// A script of the VM saved by Unreal 5.8 or later keeps no HLSL, only the
// bytecode of the VectorVM it compiled to. The bytecode is translated
// to text in the shape of Niagara's translator: a parameter map of the
// values it reads and writes (FParamMap0), SimulateMain with its data set
// reads and writes, and the instructions as statements over registers of 32
// bits, so the rest of the import takes it as it takes the HLSL of an older
// save. Each register is a uint holding the bits the VM holds; a bool is all
// ones or zero, as in the VM.

// The registers of the VM a component of a value lives in.
Niagara_Register :: enum u8 {Float,Int,Half}

// A component of a value of Niagara: how HLSL reaches it from the value
// (".x", ".Count", "[1][2]"), the registers it is in, whether it is a bool,
// and its byte in a table of constants.
Niagara_Component :: struct {
    suffix:string,
    register:Niagara_Register,
    boolean:bool,
    offset:int,
}

// A type of Niagara as HLSL writes it and as the VM lays it out.
Niagara_Type :: struct {
    name:string, // of its struct or enum
    hlsl:string,
    components:[]Niagara_Component,
    bytes:int,
    object:bool, // a data interface or another object: no value of the VM
}

// A variable a compilation keeps: its name, type and, of a literal, its bytes.
Niagara_Variable :: struct {
    name:string,
    type:Niagara_Type,
    data:[]u8,
}

// What a script is to the VM.
Niagara_Vm_Usage :: enum u8 {Spawn,Update,System}

// A function of a data interface the bytecode calls (FVMExternalFunctionBindingInfo).
Niagara_Vm_Function :: struct {
    name,owner:string,
    symbol:string,        // as HLSL names it: name, owner, specifiers
    inputs:int,           // registers it reads, the instance of its data interface first
    outputs:int,          // registers it writes
    params:[]Niagara_Variable, // inputs then outputs, of the signature its data interface registered
    ins:int,              // how many of params are inputs
    found:bool,           // its signature is known and matches its registers
    registered:string,    // the signatures of its name its compilation keeps, for a problem when none matches
}

// A remapped input register in a frozen VectorVM2 runtime context.
Niagara_Vm2_Input :: struct {
    data_set:int,
    register:Niagara_Register,
    index:int,
}

// A remapped output register in a frozen VectorVM2 runtime context.
Niagara_Vm2_Output :: struct {
    data_set:int,
    register:Niagara_Register,
    dst_reg:int, // 0xFFFF = unused
}

// External function metadata stored inside a frozen VectorVM2 context.
Niagara_Vm2_Ext_Fn :: struct {
    num_inputs,num_outputs:int,
}

// Frozen VectorVM2 runtime context parsed from ExperimentalContextData / OptimizedByteCode.
Niagara_Vm2 :: struct {
    bytecode:[]u8,
    num_temp_regs:int,
    const_remap:[]u16,
    inputs:[]Niagara_Vm2_Input,
    outputs:[]Niagara_Vm2_Output,
    ext_fns:[]Niagara_Vm2_Ext_Fn,
}

// Defensive caps rejecting hostile/corrupt frozen VectorVM2 headers before allocation.
MAX_VVM2_REGS :: 4096
MAX_VVM2_EXT_FNS :: 1024

// What the decompilation reads of a script.
Niagara_Vm :: struct {
    code:[]u8,
    vvm2:Maybe(Niagara_Vm2),
    usage:Niagara_Vm_Usage,
    interpolated:bool,              // its table of constants keeps those of the frame before after its own
    attributes:[]Niagara_Variable,  // of its data set 0, in the order of their registers
    instance:[]Niagara_Variable,    // of a script of the system: the parameters of its instance, data set 1
    parameters:[]Niagara_Variable,  // its external constants, in the order of their table
    literals:[]Niagara_Variable,    // its literals, with their bytes
    functions:[]Niagara_Vm_Function,
}

// Parses a frozen VectorVM2 ExperimentalContextData blob.
@(private)
niagara_vm2_parse :: proc(data:[]u8,allocator:=context.temp_allocator) -> (ctx:Niagara_Vm2,ok:bool) {
    if len(data)<64 {return}
    u16_at :: proc(d:[]u8,off:int) -> u16 {v,_:=endian.get_u16(d[off:],.Little);return v}
    u32_at :: proc(d:[]u8,off:int) -> u32 {v,_:=endian.get_u32(d[off:],.Little);return v}
    i32_at :: proc(d:[]u8,off:int) -> i32 {v,_:=endian.get_i32(d[off:],.Little);return v}
    align16 :: proc(n:int) -> int {return (n+15)&~15}

    num_bytecode:=int(u32_at(data,0))
    num_temp_regs:=int(u32_at(data,10))
    num_consts_remapped:=int(u16_at(data,14))
    num_inputs_remapped:=int(u16_at(data,16))
    num_input_datasets:=int(u16_at(data,20))
    num_outputs_remapped:=int(u16_at(data,22))
    num_ext_fns:=int(u32_at(data,26))
    if num_bytecode==0 || num_bytecode>len(data) {return}
    if num_temp_regs<0 || num_temp_regs>MAX_VVM2_REGS {return}
    if num_consts_remapped>MAX_VVM2_REGS || num_inputs_remapped>MAX_VVM2_REGS || num_outputs_remapped>MAX_VVM2_REGS {return}
    if num_input_datasets>256 || num_ext_fns<0 || num_ext_fns>MAX_VVM2_EXT_FNS {return}

    // sizeof(FRuntimeContextData) == 56 -> 16-byte aligned Bytecode starts at 64.
    at:=64
    if at+num_bytecode>len(data) {return}
    ctx.bytecode=data[at:at+num_bytecode]
    ctx.num_temp_regs=num_temp_regs
    at+=align16(num_bytecode)

    if num_consts_remapped>0 {
        need:=num_consts_remapped*2
        if at+need>len(data) {return}
        ctx.const_remap=make([]u16,num_consts_remapped,allocator)
        for i in 0..<num_consts_remapped {ctx.const_remap[i]=u16_at(data,at+i*2)}
        at+=align16(need)
    }

    input_remap:[]u16
    if num_inputs_remapped>0 {
        need:=num_inputs_remapped*2
        if at+need>len(data) {return}
        input_remap=make([]u16,num_inputs_remapped,context.temp_allocator)
        for i in 0..<num_inputs_remapped {input_remap[i]=u16_at(data,at+i*2)}
        at+=align16(need)
    }

    input_offsets:[]u16
    if num_input_datasets>0 {
        need:=num_input_datasets*8*2
        if at+need>len(data) {return}
        input_offsets=make([]u16,num_input_datasets*8,context.temp_allocator)
        for i in 0..<num_input_datasets*8 {input_offsets[i]=u16_at(data,at+i*2)}
        at+=align16(need)
    }

    if num_inputs_remapped>0 {
        ctx.inputs=make([]Niagara_Vm2_Input,num_inputs_remapped,allocator)
        for i in 0..<num_inputs_remapped {ctx.inputs[i]={index=int(input_remap[i])}}
        // Populate both regular (offsets[0..3]) and no-advance (offsets[3..6] when offsets[7] > 0)
        // inputs in the sequential order the runtime assigns input buffer slots.
        counter:=0
        reg_kinds:=[3]Niagara_Register{.Float,.Int,.Half}
        for ds in 0..<num_input_datasets {
            base:=ds*8
            for j in 0..<3 {
                start:=int(input_offsets[base+j])
                end:=int(input_offsets[base+j+1])
                for k in start..<min(end,num_inputs_remapped) {
                    if counter<num_inputs_remapped {
                        ctx.inputs[counter]={ds,reg_kinds[j],int(input_remap[k])}
                        counter+=1
                    }
                }
            }
            if input_offsets[base+7]>0 {
                for j in 0..<3 {
                    start:=int(input_offsets[base+3+j])
                    end:=int(input_offsets[base+4+j])
                    for k in start..<min(end,num_inputs_remapped) {
                        if counter<num_inputs_remapped {
                            ctx.inputs[counter]={ds,reg_kinds[j],int(input_remap[k])}
                            counter+=1
                        }
                    }
                }
            }
        }
    }

    out_ds:[]u8
    out_type:[]u16
    out_dst:[]u16
    if num_outputs_remapped>0 {
        if at+num_outputs_remapped>len(data) {return}
        out_ds=data[at:at+num_outputs_remapped]
        at+=align16(num_outputs_remapped)
        need:=num_outputs_remapped*2
        if at+need>len(data) {return}
        out_type=make([]u16,num_outputs_remapped,context.temp_allocator)
        for i in 0..<num_outputs_remapped {out_type[i]=u16_at(data,at+i*2)}
        at+=align16(need)
        if at+need>len(data) {return}
        out_dst=make([]u16,num_outputs_remapped,context.temp_allocator)
        for i in 0..<num_outputs_remapped {out_dst[i]=u16_at(data,at+i*2)}
        at+=align16(need)
        ctx.outputs=make([]Niagara_Vm2_Output,num_outputs_remapped,allocator)
        for i in 0..<num_outputs_remapped {
            reg:=Niagara_Register.Float
            if out_type[i]==1 {reg=.Int} else if out_type[i]==2 {reg=.Half}
            ctx.outputs[i]={data_set=int(out_ds[i]),register=reg,dst_reg=int(out_dst[i])}
        }
    }

    if num_ext_fns>0 {
        need:=num_ext_fns*16
        if at+need>len(data) {return}
        ctx.ext_fns=make([]Niagara_Vm2_Ext_Fn,num_ext_fns,allocator)
        for i in 0..<num_ext_fns {
            ctx.ext_fns[i]={
                num_inputs=int(i32_at(data,at+i*16+8)),
                num_outputs=int(i32_at(data,at+i*16+12)),
            }
        }
    }
    return ctx,true
}

// The type of a variable from the definition its tagged properties keep.
@(private)
niagara_type_of :: proc(p:^unreal.Package,definition:^unreal.Property_List) -> (type:Niagara_Type,ok:bool) {
    underlying,_:=level.value_real(p,unreal.property_find(p,definition,"UnderlyingType"),0)
    name:=""
    for field in ([2]string{"ClassStructOrEnum","Struct"}) {
        if object:=value_object(p,unreal.property_find(p,definition,field));object!=0 {
            if n,named:=unreal.reference_name(p,object);named {name=unreal.name_plain(p,n)}
            break
        }
    }
    // The underlying type: a class is an object, an enum an integer.
    if underlying==1 {return Niagara_Type{name=name,object=true},true}
    type,ok=niagara_type_named(underlying==3?"NiagaraInt32":name)
    type.name=name
    return
}

// A type of Niagara by the name of its struct.
@(private)
niagara_type_named :: proc(name:string) -> (type:Niagara_Type,ok:bool) {
    floats :: proc(hlsl:string,suffixes:[]string,register:Niagara_Register=.Float,size:=4) -> Niagara_Type {
        list:=make([]Niagara_Component,len(suffixes),context.temp_allocator)
        for s,i in suffixes {list[i]=Niagara_Component{s,register,false,i*size}}
        return Niagara_Type{hlsl=hlsl,components=list,bytes=len(suffixes)*size}
    }
    switch name {
    case "NiagaraFloat": return floats("float",{""}),true
    case "Vector2f","Vector2D","NiagaraVector2f": return floats("float2",{".x",".y"}),true
    case "Vector3f","Vector","NiagaraPosition": return floats("float3",{".x",".y",".z"}),true
    case "Vector4f","Vector4","LinearColor","Quat4f","Quat": return floats("float4",{".x",".y",".z",".w"}),true
    case "NiagaraHalf": return floats("float",{""},.Half,2),true
    case "NiagaraHalfVector2": return floats("float2",{".x",".y"},.Half,2),true
    case "NiagaraHalfVector3": return floats("float3",{".x",".y",".z"},.Half,2),true
    case "NiagaraHalfVector4": return floats("float4",{".x",".y",".z",".w"},.Half,2),true
    case "NiagaraMatrix","Matrix44f","Matrix":
        suffixes:=make([]string,16,context.temp_allocator)
        for i in 0..<16 {suffixes[i]=fmt.tprintf("[%d][%d]",i/4,i%4)}
        return floats("float4x4",suffixes),true
    case "NiagaraInt32": return Niagara_Type{hlsl="int",components=slice.clone([]Niagara_Component{{"",.Int,false,0}},context.temp_allocator),bytes=4},true
    case "NiagaraBool": return Niagara_Type{hlsl="bool",components=slice.clone([]Niagara_Component{{"",.Int,true,0}},context.temp_allocator),bytes=4},true
    case "NiagaraID": return Niagara_Type{hlsl="NiagaraID",components=slice.clone([]Niagara_Component{{".Index",.Int,false,0},{".AcquireTag",.Int,false,4}},context.temp_allocator),bytes=8},true
    case "NiagaraEmitterID": return Niagara_Type{hlsl="NiagaraEmitterID",components=slice.clone([]Niagara_Component{{".ID",.Int,false,0}},context.temp_allocator),bytes=4},true
    case "NiagaraSpawnInfo":
        return Niagara_Type{hlsl="NiagaraSpawnInfo",components=slice.clone([]Niagara_Component{{".Count",.Int,false,0},{".InterpStartDt",.Float,false,4},{".IntervalDt",.Float,false,8},{".SpawnGroup",.Int,false,12}},context.temp_allocator),bytes=16},true
    }
    return {},false
}

// The variables of an array of NiagaraVariableBase, or of NiagaraVariable
// with their bytes: natively a name, a type definition as tagged properties
// and, with data, the size of the bytes and the bytes. A variable of a type
// the VM does not know has no components; false for a malformed array.
@(private)
niagara_variables :: proc(p:^unreal.Package,property:^unreal.Property,with_data:bool) -> (list:[]Niagara_Variable,ok:bool) {
    if property==nil {return nil,true}
    view,view_error:=unreal.property_array(p,property)
    if view_error.code!=.None {return}
    raw,raw_error:=unreal.span_bytes(p,view.data)
    if raw_error.code!=.None {return}
    out:=make([dynamic]Niagara_Variable,context.temp_allocator)
    at:=0
    for _ in 0..<view.count {
        if at+8>len(raw) {return}
        index,_:=endian.get_i32(raw[at:],.Little)
        number,_:=endian.get_i32(raw[at+4:],.Little)
        at+=8
        definition,definition_error:=unreal.properties_open(p,{view.data.offset+i64(at),view.data.size-i64(at)},false,context.temp_allocator)
        if definition_error.code!=.None {return}
        at+=int(definition.source.size)
        v:=Niagara_Variable{name=unreal.name_text(p,{index,number},context.temp_allocator)}
        v.type,_=niagara_type_of(p,&definition)
        if with_data {
            if at+4>len(raw) {return}
            size,_:=endian.get_i32(raw[at:],.Little)
            at+=4
            if size<0 || at+int(size)>len(raw) {return}
            v.data=raw[at:at+int(size)]
            at+=int(size)
        }
        append(&out,v)
    }
    return out[:],true
}

// The variables of a NiagaraParameters (its Parameters).
@(private)
niagara_parameters_of :: proc(p:^unreal.Package,property:^unreal.Property) -> (list:[]Niagara_Variable,ok:bool) {
    if property==nil {return nil,true}
    fields,error:=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
    if error.code!=.None {return}
    return niagara_variables(p,unreal.property_find(p,&fields,"Parameters"),true)
}

// Reads a FNiagaraVMExecutableByteCode tagged struct ({Data, UncompressedSize}),
// inflating zlib when compressed.
@(private)
niagara_vm_bytecode_field :: proc(p:^unreal.Package,vm_fields:^Struct_Fields,name:string,problems:^[dynamic]string) -> (bytes:[]u8,ok:bool) {
    code:=struct_field(vm_fields,name)
    if code==nil {return}
    fields,fields_error:=unreal.property_tagged_struct(p,code,true,context.temp_allocator)
    if fields_error.code!=.None {return}
    data:=unreal.property_find(p,&fields,"Data")
    if data==nil {return}
    view,view_error:=unreal.property_array(p,data)
    if view_error.code!=.None {return}
    raw,bytes_error:=unreal.span_bytes(p,view.data)
    if bytes_error.code!=.None || len(raw)==0 {return}
    unpacked,_:=level.value_real(p,unreal.property_find(p,&fields,"UncompressedSize"),-1)
    if unpacked>0 {
        out:=make([]u8,int(unpacked),context.temp_allocator)
        if stbi.zlib_decode_buffer(raw_data(out),c.int(len(out)),raw_data(raw),c.int(len(raw)))!=c.int(len(out)) {
            append(problems,"its bytecode does not decompress: its script is not translated")
            return
        }
        raw=out
    }
    return raw,true
}

// Reads a raw u8 array field from CachedScriptVM (ExperimentalContextData / ScriptLiterals).
@(private)
niagara_vm_raw_bytes :: proc(p:^unreal.Package,vm_fields:^Struct_Fields,name:string) -> []u8 {
    prop:=struct_field(vm_fields,name)
    if prop==nil {return nil}
    view,view_error:=unreal.property_array(p,prop)
    if view_error.code!=.None {return nil}
    raw,raw_error:=unreal.span_bytes(p,view.data)
    if raw_error.code!=.None {return nil}
    return raw
}

// What the decompilation reads of a script, from its CachedScriptVM; false
// without bytecode. Supports legacy ByteCode (VectorVM1) and VectorVM2
// ExperimentalContextData / OptimizedByteCode.
@(private)
niagara_vm_read :: proc(d:^level.Document,script:level.Ref,vm_fields:^Struct_Fields,problems:^[dynamic]string) -> (vm:Niagara_Vm,ok:bool) {
    p:=vm_fields.p
    usage,_:=level.enum_of(d,script,"Usage","")
    usage=usage[strings.last_index_byte(usage,':')+1:]
    switch usage {
    case "ParticleSpawnScript","ParticleSpawnScriptInterpolated": vm.usage=.Spawn
    case "ParticleUpdateScript": vm.usage=.Update
    case "SystemSpawnScript","SystemUpdateScript": vm.usage=.System
    case: return
    }
    // Prefer ByteCode when present; fall back to VectorVM2 ExperimentalContextData
    // or OptimizedByteCode (UE5.4+/UE6 cooked builds strip ByteCode.Data).
    if bytes,has:=niagara_vm_bytecode_field(p,vm_fields,"ByteCode",problems);has {
        vm.code=bytes
    } else if exp:=niagara_vm_raw_bytes(p,vm_fields,"ExperimentalContextData");len(exp)>0 {
        if ctx,parsed:=niagara_vm2_parse(exp,context.temp_allocator);parsed {
            vm.vvm2=ctx
        } else {
            append(problems,"its VectorVM2 ExperimentalContextData is malformed: its script is not translated")
            return
        }
    } else if opt,has_opt:=niagara_vm_bytecode_field(p,vm_fields,"OptimizedByteCode",problems);has_opt {
        if ctx,parsed:=niagara_vm2_parse(opt,context.temp_allocator);parsed {
            vm.vvm2=ctx
        } else {
            append(problems,"its VectorVM2 OptimizedByteCode is malformed: its script is not translated")
            return
        }
    } else {
        return
    }
    // The table of constants of an interpolated spawn script keeps the values of the frame before
    // after those of this one.
    vm.interpolated=usage=="ParticleSpawnScriptInterpolated"
    read:bool
    if vm.attributes,read=niagara_variables(p,struct_field(vm_fields,"Attributes"),false);!read {
        append(problems,"its attributes do not read: its script is not translated")
        return
    }
    // The data set of a particle script is its particles: its compilation names them without their namespace.
    if vm.usage!=.System {
        for &a in vm.attributes {if !strings.has_prefix(a.name,"Particles.") {a.name=strings.concatenate({"Particles.",a.name},context.temp_allocator)}}
    }
    if vm.parameters,read=niagara_parameters_of(p,struct_field(vm_fields,"Parameters"));!read {
        append(problems,"its parameters do not read: its script is not translated")
        return
    }
    if vm.literals,read=niagara_parameters_of(p,struct_field(vm_fields,"InternalParameters"));!read {
        append(problems,"its literals do not read: its script is not translated")
        return
    }
    literal_bytes:=0
    for v in vm.literals {literal_bytes+=len(v.data)}
    if literal_bytes==0 {
        if raw:=niagara_vm_raw_bytes(p,vm_fields,"ScriptLiterals");len(raw)>0 {
            vm.literals=slice.clone([]Niagara_Variable{{name="ScriptLiterals",data=raw}},context.temp_allocator)
        }
    }
    // The parameters of the instance of the system its script reads as data set 1.
    if vm.usage==.System {
        if f:=struct_field(vm_fields,"DataSetToParameters");f!=nil {
            vm.instance=niagara_instance_parameters(p,f)
        }
    }
    vm.functions=niagara_vm_functions(p,vm_fields)
    return vm,true
}

// The parameters of the instance of the system a script of the system reads
// as its data set 1: the one entry of its DataSetToParameters, a map of a
// name to a NiagaraParameters.
@(private)
niagara_instance_parameters :: proc(p:^unreal.Package,property:^unreal.Property) -> []Niagara_Variable {
    raw,error:=unreal.span_bytes(p,property.data)
    if error.code!=.None || len(raw)<8 {return nil}
    removed,_:=endian.get_i32(raw,.Little)
    count,_:=endian.get_i32(raw[4:],.Little)
    if removed!=0 || count<1 {return nil}
    at:=8+8
    fields,fields_error:=unreal.properties_open(p,{property.data.offset+i64(at),property.data.size-i64(at)},false,context.temp_allocator)
    if fields_error.code!=.None {return nil}
    list,_:=niagara_variables(p,unreal.property_find(p,&fields,"Parameters"),true)
    return list
}

// The elements of an array of structs as tagged properties, also of a struct
// with a serializer of its own that writes them (FVMExternalFunctionBindingInfo).
@(private)
niagara_struct_items :: proc(p:^unreal.Package,property:^unreal.Property) -> []unreal.Property_List {
    if property==nil {return nil}
    view,view_error:=unreal.property_array(p,property)
    if view_error.code!=.None {return nil}
    if items,error:=unreal.array_tagged_structs(p,view,true,context.temp_allocator);error.code==.None {return items.items}
    out:=make([dynamic]unreal.Property_List,context.temp_allocator)
    at:=view.data.offset
    for _ in 0..<view.count {
        list,error:=unreal.properties_open(p,{at,view.data.offset+view.data.size-at},false,context.temp_allocator)
        if error.code!=.None || list.source.size<=0 {return nil}
        append(&out,list)
        at+=list.source.size
    }
    return out[:]
}

// The functions of data interfaces the bytecode calls, in the order of their
// table, with the signatures their data interfaces registered.
@(private)
niagara_vm_functions :: proc(p:^unreal.Package,vm_fields:^Struct_Fields) -> []Niagara_Vm_Function {
    out:=make([dynamic]Niagara_Vm_Function,context.temp_allocator)
    items:=niagara_struct_items(p,struct_field(vm_fields,"CalledVMExternalFunctions"))
    // The signatures each data interface registered, by its name.
    Registered :: struct {owner:string,name:string,inputs:[]Niagara_Variable,outputs:[]Niagara_Variable}
    signatures:=make([dynamic]Registered,context.temp_allocator)
    for &di in niagara_struct_items(p,struct_field(vm_fields,"DataInterfaceInfo")) {
        owner,_:=level.value_enum(p,unreal.property_find(p,&di,"Name"),"")
        for &sig in niagara_struct_items(p,unreal.property_find(p,&di,"RegisteredFunctions")) {
            r:=Registered{owner=strings.clone(owner,context.temp_allocator)}
            name,_:=level.value_enum(p,unreal.property_find(p,&sig,"Name"),"")
            r.name=strings.clone(name,context.temp_allocator)
            r.inputs,_=niagara_variables(p,unreal.property_find(p,&sig,"Inputs"),true)
            r.outputs,_=niagara_variables(p,unreal.property_find(p,&sig,"Outputs"),false)
            append(&signatures,r)
        }
    }
    components :: proc(list:[]Niagara_Variable) -> (n:int) {
        for v in list {n+=len(v.type.components)}
        return
    }
    for &item in items {
        fn:Niagara_Vm_Function
        name,_:=level.value_enum(p,unreal.property_find(p,&item,"Name"),"")
        owner,_:=level.value_enum(p,unreal.property_find(p,&item,"OwnerName"),"")
        fn.name,fn.owner=strings.clone(name,context.temp_allocator),strings.clone(owner,context.temp_allocator)
        if locations:=unreal.property_find(p,&item,"InputParamLocations");locations!=nil {
            if l_view,l_error:=unreal.property_array(p,locations);l_error.code==.None {fn.inputs=int(l_view.count)}
        }
        outputs,_:=level.value_real(p,unreal.property_find(p,&item,"NumOutputs"),0)
        fn.outputs=int(outputs)
        // The symbol of the function as the translator names it (AppendFunctionSignatureSymbol).
        symbol:=strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&symbol,"%s_%s",name,owner)
        for &s in niagara_struct_items(p,unreal.property_find(p,&item,"FunctionSpecifiers")) {
            key,_:=level.value_enum(p,unreal.property_find(p,&s,"Key"),"")
            value,_:=level.value_enum(p,unreal.property_find(p,&s,"Value"),"")
            fmt.sbprintf(&symbol,"_%s%s",key,value)
        }
        variadic_in,_:=niagara_variables(p,unreal.property_find(p,&item,"VariadicInputs"),false)
        variadic_out,_:=niagara_variables(p,unreal.property_find(p,&item,"VariadicOutputs"),false)
        for v in variadic_in {fmt.sbprintf(&symbol,"_%s%s",v.name,v.type.name)}
        for v in variadic_out {fmt.sbprintf(&symbol,"_%s%s",v.name,v.type.name)}
        dotless,_:=strings.replace_all(strings.to_string(symbol),".","_",context.temp_allocator)
        fn.symbol=niagara_symbol(dotless)
        // Its parameters: the inputs of its signature without the data interface, then its outputs,
        // each with the variadic ones of the call unless the signature has them already.
        described:=strings.builder_make(context.temp_allocator)
        for r in signatures {
            if r.owner!=owner || r.name!=name {continue}
            fmt.sbprintf(&described,"%s(",r.name)
            for v,i in r.inputs {fmt.sbprintf(&described,"%s%s %s",i>0?", ":"",v.type.name,v.name)}
            strings.write_string(&described," -> ")
            for v,i in r.outputs {fmt.sbprintf(&described,"%s%s %s",i>0?", ":"",v.type.name,v.name)}
            strings.write_string(&described,") ")
            // The instance of the data interface is the first register; the data interface itself
            // and the pins of the parameter map have none.
            ins:=make([dynamic]Niagara_Variable,context.temp_allocator)
            for v in r.inputs {if len(v.type.components)>0 && v.name!="InstanceData" {append(&ins,v)}}
            outs:=make([dynamic]Niagara_Variable,context.temp_allocator)
            for v in r.outputs {if len(v.type.components)>0 {append(&outs,v)}}
            if components(ins[:])+1<fn.inputs {append(&ins,..variadic_in)}
            if components(outs[:])<fn.outputs {append(&outs,..variadic_out)}
            if components(ins[:])+1!=fn.inputs || components(outs[:])!=fn.outputs {continue}
            params:=make([dynamic]Niagara_Variable,context.temp_allocator)
            append(&params,..ins[:])
            append(&params,..outs[:])
            fn.params,fn.ins,fn.found=params[:],len(ins),true
            break
        }
        fn.registered=strings.to_string(described)
        append(&out,fn)
    }
    return out[:]
}

// A call to a function of a data interface: its inputs gathered from their
// registers into the values of its signature (the first, the instance of the
// data interface, aside), the call, and its outputs back into their registers.
@(private)
niagara_vm_call :: proc(w:^Niagara_Vm_Writer,fn:^Niagara_Vm_Function,operands:[]int) {
    if !fn.found {
        niagara_vm_problem(w,"%s.%s reads %d registers and writes %d, which no signature its compilation keeps matches (%s): it gives zero",fn.owner,fn.name,fn.inputs,fn.outputs,fn.registered==""?"none":strings.trim_space(fn.registered))
        for o,i in operands {if i>=fn.inputs && o!=0xFFFF {fmt.sbprintf(&w.body,"    v%d = 0u;\n",o)}}
        return
    }
    prototype:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&prototype,"void %s(",fn.symbol)
    // Its parameters named as the translator names them: In_X, Out_Value.
    named:=make([dynamic]string,context.temp_allocator)
    for p,i in fn.params {
        if i>0 {strings.write_string(&prototype,", ")}
        name:=strings.concatenate({i>=fn.ins?"Out_":"In_",niagara_symbol(p.name)},context.temp_allocator)
        if slice.contains(named[:],name) {name=fmt.tprintf("%s_%d",name,i)}
        append(&named,name)
        fmt.sbprintf(&prototype,"%s%s %s",i>=fn.ins?"out ":"",p.type.hlsl,name)
    }
    strings.write_string(&prototype,");")
    if text:=strings.to_string(prototype);!slice.contains(w.prototypes[:],text) {append(&w.prototypes,text)}
    strings.write_string(&w.body,"    {\n")
    k:=1
    for p,i in fn.params {
        fmt.sbprintf(&w.body,"        %s a%d = (%s)0;\n",p.type.hlsl,i,p.type.hlsl)
        if i>=fn.ins {continue}
        for c in p.type.components {
            o:=operands[k]
            k+=1
            bits:="0u"
            if o!=0xFFFF {bits=o&0x8000!=0?fmt.tprintf("v%d",o&0x7FFF):niagara_vm_constant(w,o)}
            fmt.sbprintf(&w.body,"        a%d%s = %s;\n",i,c.suffix,niagara_vm_value(bits,c))
        }
    }
    fmt.sbprintf(&w.body,"        %s(",fn.symbol)
    for _,i in fn.params {fmt.sbprintf(&w.body,"%sa%d",i>0?", ":"",i)}
    strings.write_string(&w.body,");\n")
    k=fn.inputs
    for p,i in fn.params[fn.ins:] {
        for c in p.type.components {
            o:=operands[k]
            k+=1
            if o!=0xFFFF {fmt.sbprintf(&w.body,"        v%d = %s;\n",o,niagara_vm_bits(fmt.tprintf("a%d%s",fn.ins+i,c.suffix),c))}
        }
    }
    strings.write_string(&w.body,"    }\n")
}

// A value of the engine in the table of constants of the VM: the structs
// NiagaraGlobalParameters, NiagaraSystemParameters, NiagaraOwnerParameters
// and NiagaraEmitterParameters, by their offsets.
@(private)
Niagara_Engine_Value :: struct {name,type:string,offset:int}

@(private)
NIAGARA_ENGINE_GLOBAL :: [?]Niagara_Engine_Value{
    {"Engine.WorldDeltaTime","NiagaraFloat",0},{"Engine.DeltaTime","NiagaraFloat",4},{"Engine.InverseDeltaTime","NiagaraFloat",8},
    {"Engine.Time","NiagaraFloat",12},{"Engine.RealTime","NiagaraFloat",16},{"Engine.QualityLevel","NiagaraInt32",20},
}
@(private)
NIAGARA_ENGINE_EMITTER :: [?]Niagara_Engine_Value{
    {"Engine.Owner.TimeSinceRendered","NiagaraFloat",32},{"Engine.Owner.LODDistance","NiagaraFloat",36},
    {"Engine.Owner.LODDistanceFraction","NiagaraFloat",40},{"Engine.System.Age","NiagaraFloat",44},
    {"Engine.Owner.ExecutionState","NiagaraInt32",48},{"Engine.System.TickCount","NiagaraInt32",52},
    {"Engine.System.NumEmitters","NiagaraInt32",56},{"Engine.System.NumEmittersAlive","NiagaraInt32",60},
    {"Engine.System.SignificanceIndex","NiagaraInt32",64},{"Engine.System.RandomSeed","NiagaraInt32",68},
    {"Engine.System.CurrentTimeStep","NiagaraInt32",72},{"Engine.System.NumTimeSteps","NiagaraInt32",76},
    {"Engine.System.TimeStepFraction","NiagaraFloat",80},{"Engine.System.NumParticles","NiagaraInt32",84},
    {"Engine.Owner.SystemLocalToWorld","NiagaraMatrix",96},{"Engine.Owner.SystemWorldToLocal","NiagaraMatrix",160},
    {"Engine.Owner.SystemLocalToWorldTransposed","NiagaraMatrix",224},{"Engine.Owner.SystemWorldToLocalTransposed","NiagaraMatrix",288},
    {"Engine.Owner.SystemLocalToWorldNoScale","NiagaraMatrix",352},{"Engine.Owner.SystemWorldToLocalNoScale","NiagaraMatrix",416},
    {"Engine.Owner.Rotation","Quat4f",480},{"Engine.Owner.Position","NiagaraPosition",496},{"Engine.Owner.Velocity","Vector3f",512},
    {"Engine.Owner.SystemXAxis","Vector3f",528},{"Engine.Owner.SystemYAxis","Vector3f",544},{"Engine.Owner.SystemZAxis","Vector3f",560},
    {"Engine.Owner.Scale","Vector3f",576},{"Engine.Owner.LWCTile","Vector4f",592},
    {"Engine.Emitter.NumParticles","NiagaraInt32",608},{"Engine.Emitter.TotalSpawnedParticles","NiagaraInt32",612},
    {"Engine.Emitter.SpawnCountScale","NiagaraFloat",616},{"Emitter.Age","NiagaraFloat",620},
    {"Emitter.RandomSeed","NiagaraInt32",624},{"Engine.Emitter.InstanceSeed","NiagaraInt32",628},
}
NIAGARA_ENGINE_GLOBAL_BYTES :: 32   // the bytes of NiagaraGlobalParameters
NIAGARA_ENGINE_EMITTER_BYTES :: 640 // the four structs the scripts of an emitter see

// A variable at its offset in the table of constants of a script: the values
// of the engine and its external constants (twice when it interpolates, PREV_
// those of the frame before), then its literals.
@(private)
Niagara_Vm_Slot :: struct {start,size:int,variable:Niagara_Variable,prefix:string,literal:bool}

@(private)
niagara_vm_table :: proc(vm:^Niagara_Vm) -> []Niagara_Vm_Slot {
    slots:=make([dynamic]Niagara_Vm_Slot,context.temp_allocator)
    at:=0
    for copy in 0..<(vm.interpolated?2:1) {
        prefix:=copy==1?"PREV_":""
        for e in NIAGARA_ENGINE_GLOBAL {
            type,_:=niagara_type_named(e.type)
            append(&slots,Niagara_Vm_Slot{at+e.offset,type.bytes,{name=e.name,type=type},prefix,false})
        }
        if vm.usage!=.System {
            for e in NIAGARA_ENGINE_EMITTER {
                type,_:=niagara_type_named(e.type)
                append(&slots,Niagara_Vm_Slot{at+e.offset,type.bytes,{name=e.name,type=type},prefix,false})
            }
        }
        at+=vm.usage==.System?NIAGARA_ENGINE_GLOBAL_BYTES:NIAGARA_ENGINE_EMITTER_BYTES
        for v in vm.parameters {
            if v.type.object {continue}
            size:=len(v.data) if len(v.data)>0 else v.type.bytes
            append(&slots,Niagara_Vm_Slot{at,size,v,prefix,false})
            at+=(size+3)&~3
        }
    }
    for v in vm.literals {
        append(&slots,Niagara_Vm_Slot{at,len(v.data),v,"",true})
        at+=len(v.data)
    }
    return slots[:]
}

// A value of the parameter map: its path among the structs of the map and its type.
@(private)
Niagara_Vm_Path :: struct {path,type:string}

// A script being decompiled.
@(private)
Niagara_Vm_Writer :: struct {
    vm:^Niagara_Vm,
    M:string,                       // the field of FSimulationContext: Context.MapSpawn or Context.Map
    body:strings.Builder,           // the statements of its entry
    paths:[dynamic]Niagara_Vm_Path, // of the parameter map
    globals:[dynamic]Hlsl_Field,    // the constants it reads by name
    reads,writes:[dynamic]string,   // the lines of SimulateMain before and after its entry
    prototypes:[dynamic]string,
    problems:^[dynamic]string,
    table:[]Niagara_Vm_Slot,
    registers:int,
}

@(private)
niagara_vm_problem :: proc(w:^Niagara_Vm_Writer,format:string,args:..any) {
    text:=fmt.tprintf(format,..args)
    if !slice.contains(w.problems[:],text) {append(w.problems,text)}
}

// The field of the parameter map of a name of Niagara (Particles.Position: Context.Map.Particles.Position).
@(private)
niagara_vm_path :: proc(w:^Niagara_Vm_Writer,name,type:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    rest:=name
    for part in strings.split_iterator(&rest,".") {
        symbol:=niagara_symbol(part)
        if symbol=="" {continue}
        if strings.builder_len(b)>0 {strings.write_byte(&b,'.')}
        strings.write_string(&b,symbol)
    }
    path:=strings.to_string(b)
    known:=false
    for each in w.paths {known||=each.path==path}
    if !known {append(&w.paths,Niagara_Vm_Path{path,type})}
    return strings.concatenate({w.M,".",path},context.temp_allocator)
}

// A global the script reads a constant of the table by.
@(private)
niagara_vm_global :: proc(w:^Niagara_Vm_Writer,name,type:string) -> string {
    for g in w.globals {if g.name==name {return name}}
    append(&w.globals,Hlsl_Field{type,name})
    return name
}

// The bits of a value of a component, as its register holds them.
@(private)
niagara_vm_bits :: proc(value:string,c:Niagara_Component) -> string {
    if c.boolean {return fmt.tprintf("(%s ? 0xFFFFFFFFu : 0u)",value)}
    return fmt.tprintf("asuint(%s)",value)
}

// A value of a component from the bits of a register.
@(private)
niagara_vm_value :: proc(bits:string,c:Niagara_Component) -> string {
    switch {
    case c.boolean: return fmt.tprintf("(%s != 0u)",bits)
    case c.register==.Int: return fmt.tprintf("asint(%s)",bits)
    }
    return fmt.tprintf("asfloat(%s)",bits)
}

// The bits a constant of the table at an offset of bytes holds.
@(private)
niagara_vm_constant :: proc(w:^Niagara_Vm_Writer,offset:int) -> string {
    for &slot in w.table {
        if offset<slot.start || offset>=slot.start+max(slot.size,1) {continue}
        at:=offset-slot.start
        if slot.literal {
            if at+4>len(slot.variable.data) {break}
            bits,_:=endian.get_u32(slot.variable.data[at:],.Little)
            return fmt.tprintf("0x%08xu",bits)
        }
        v:=&slot.variable
        for c in v.type.components {
            if c.offset!=at {continue}
            // The engine gives its values to the parameter map, as SimulateMain does.
            if strings.has_prefix(v.name,"Engine.") && slot.prefix=="" {
                symbol:=niagara_vm_global(w,niagara_symbol(v.name),v.type.hlsl)
                field:=niagara_vm_path(w,v.name,v.type.hlsl)
                line:=fmt.tprintf("%s = %s;",field,symbol)
                if !slice.contains(w.reads[:],line) {append(&w.reads,line)}
                return niagara_vm_bits(strings.concatenate({field,c.suffix},context.temp_allocator),c)
            }
            symbol:=niagara_vm_global(w,strings.concatenate({slot.prefix,niagara_symbol(v.name)},context.temp_allocator),v.type.hlsl)
            return niagara_vm_bits(strings.concatenate({symbol,c.suffix},context.temp_allocator),c)
        }
        if len(v.type.components)==0 {
            niagara_vm_problem(w,"%s is of a type the translation does not know: it reads zero",v.name)
            return "0u"
        }
        break
    }
    niagara_vm_problem(w,"a constant at byte %d of its table is not one it lays out: it reads zero",offset)
    return "0u"
}

// The variable and component of a register of a data set.
@(private)
niagara_vm_component :: proc(list:[]Niagara_Variable,register:Niagara_Register,index:int) -> (v:^Niagara_Variable,c:Niagara_Component,ok:bool) {
    k:=0
    for &each in list {
        for comp in each.type.components {
            if comp.register!=register {continue}
            if k==index {return &each,comp,true}
            k+=1
        }
    }
    return
}

// What SimulateMain names the registers of a component: InputDataFloat, InputDataBool...
@(private)
niagara_vm_kind :: proc(c:Niagara_Component) -> string {
    if c.boolean {return "Bool"}
    switch c.register {
    case .Int: return "Int"
    case .Half: return "Half"
    case .Float:
    }
    return "Float"
}

// A register of a data set the script reads: the field of the map that holds it.
@(private)
niagara_vm_input :: proc(w:^Niagara_Vm_Writer,set,index:int,register:Niagara_Register) -> string {
    list:[]Niagara_Variable
    if set==0 {list=w.vm.attributes} else if set==1 && w.vm.usage==.System {list=w.vm.instance}
    v,c,found:=niagara_vm_component(list,register,index)
    if !found {
        if set>0 && w.vm.usage!=.System {
            niagara_vm_problem(w,"it reads the events of another emitter, which read zero; %s",NIAGARA_EVENTS_ALTERNATIVE)
        } else {
            niagara_vm_problem(w,"it reads register %d of its data set %d, which its compilation does not lay out: it reads zero",index,set)
        }
        return "0u"
    }
    field:=strings.concatenate({niagara_vm_path(w,v.name,v.type.hlsl),c.suffix},context.temp_allocator)
    kind:=niagara_vm_kind(c)
    line:=fmt.tprintf("%s = InputData%s(%d, %d);",field,kind,set,index)
    // A parameter of the instance of the system that is not of the engine is a constant of the script.
    if set==1 && !strings.has_prefix(v.name,"Engine.") {
        line=fmt.tprintf("%s = %s%s;",field,niagara_vm_global(w,niagara_symbol(v.name),v.type.hlsl),c.suffix)
    }
    if !slice.contains(w.reads[:],line) {append(&w.reads,line)}
    return niagara_vm_bits(field,c)
}

// A register of a data set the script writes.
@(private)
niagara_vm_output :: proc(w:^Niagara_Vm_Writer,set,index:int,register:Niagara_Register,bits:string) {
    // The events it writes: their WriteDataSets say which, and that they are not translated.
    if set>0 {return}
    v,c,found:=niagara_vm_component(w.vm.attributes,register,index)
    if !found {
        niagara_vm_problem(w,"it writes register %d of its data set, which its compilation does not lay out",index)
        return
    }
    field:=strings.concatenate({niagara_vm_path(w,v.name,v.type.hlsl),c.suffix},context.temp_allocator)
    fmt.sbprintf(&w.body,"    %s = %s;\n",field,niagara_vm_value(bits,c))
    kind:=niagara_vm_kind(c)
    line:=fmt.tprintf("OutputData%s(%d, %d, TmpWriteIndex, %s);",kind,set,index,field)
    if !slice.contains(w.writes[:],line) {append(&w.writes,line)}
}

// The operations of VectorVM1 (0..97) and VectorVM2 merged opcodes (98..178).
@(private)
Niagara_Op :: enum u8 {
    Done,Add,Sub,Mul,Div,Mad,Lerp,Rcp,Rsq,Sqrt,Neg,Abs,Exp,Exp2,Log,Log2,Sin,Cos,Tan,Asin,Acos,Atan,Atan2,
    Ceil,Floor,Fmod,Frac,Trunc,Clamp,Min,Max,Pow,Round,Sign,Step,Random,Noise,Cmplt,Cmple,Cmpgt,Cmpge,Cmpeq,
    Cmpneq,Select,Addi,Subi,Muli,Divi,Clampi,Mini,Maxi,Absi,Negi,Signi,Randomi,Cmplti,Cmplei,Cmpgti,Cmpgei,
    Cmpeqi,Cmpneqi,Bit_And,Bit_Or,Bit_Xor,Bit_Not,Bit_Lshift,Bit_Rshift,Logic_And,Logic_Or,Logic_Xor,
    Logic_Not,F2i,I2f,F2b,B2f,I2b,B2i,Input_Float,Input_Int,Input_Half,Input_Noadvance_Float,
    Input_Noadvance_Int,Input_Noadvance_Half,Output_Float,Output_Int,Output_Half,Acquire_Index,
    External_Call,Exec_Index,Noise2d,Noise3d,Enter_Stat_Scope,Exit_Stat_Scope,Update_Id,Acquire_Id,
    Half_To_Float,Fasi,Iasf,
    // Merged VectorVM2 / Fortnite opcodes (98..178).
    Exec_Indexf,Exec_Index_Addi,
    Cmplt_Select,Cmple_Select,Cmpeq_Select,Cmplti_Select,Cmplei_Select,Cmpeqi_Select,
    Cmplt_Logic_And,Cmple_Logic_And,Cmpgt_Logic_And,Cmpge_Logic_And,Cmpeq_Logic_And,Cmpne_Logic_And,
    Cmplti_Logic_And,Cmplei_Logic_And,Cmpgti_Logic_And,Cmpgei_Logic_And,Cmpeqi_Logic_And,Cmpnei_Logic_And,
    Cmplt_Logic_Or,Cmple_Logic_Or,Cmpgt_Logic_Or,Cmpge_Logic_Or,Cmpeq_Logic_Or,Cmpne_Logic_Or,
    Cmplti_Logic_Or,Cmplei_Logic_Or,Cmpgti_Logic_Or,Cmpgei_Logic_Or,Cmpeqi_Logic_Or,Cmpnei_Logic_Or,
    Mad_Add,Mad_Sub0,Mad_Sub1,Mad_Mul,Mad_Sqrt,Mad_Mad0,Mad_Mad1,
    Mul_Mad0,Mul_Mad1,Mul_Add,Mul_Sub0,Mul_Sub1,Mul_Mul,Mul_Max,Mul_2x,
    Add_Mad1,Add_Add,Sub_Cmplt1,Sub_Neg,Sub_Mul,Div_Mad0,Div_F2i,Div_Mul,
    Muli_Addi,Addi_Bit_Rshift,Addi_Muli,B2i_2x,
    I2f_Div0,I2f_Div1,I2f_Mul,I2f_Mad0,I2f_Mad1,
    F2i_Select1,F2i_Maxi,F2i_Addi,Fmod_Add,Bit_And_I2f,Bit_Rshift_Bit_And,
    Neg_Cmplt,Bit_Or_Muli,Bit_Lshift_Bit_Or,Random_Add,Random_2x,Max_F2i,
    Select_Mul,Select_Add,Sin_Cos,Output_Float_From_Half,Output_Half_From_Half,
}

// The inputs of an operation over registers.
@(private)
niagara_op_inputs :: proc(op:Niagara_Op) -> int {
    #partial switch op {
    case .Rcp,.Rsq,.Sqrt,.Neg,.Abs,.Exp,.Exp2,.Log,.Log2,.Sin,.Cos,.Tan,.Asin,.Acos,.Atan,.Ceil,.Floor,.Frac,.Trunc,
         .Round,.Sign,.Random,.Noise,.Absi,.Negi,.Signi,.Randomi,.Bit_Not,.Logic_Not,.F2i,.I2f,.F2b,.B2f,.I2b,.B2i,
         .Half_To_Float,.Fasi,.Iasf,.Exec_Index_Addi,.B2i_2x,.Random_2x,.Sin_Cos:
        return 1
    case .Add,.Sub,.Mul,.Div,.Atan2,.Fmod,.Min,.Max,.Pow,.Step,.Cmplt,.Cmple,.Cmpgt,.Cmpge,.Cmpeq,.Cmpneq,.Addi,.Subi,
         .Muli,.Divi,.Mini,.Maxi,.Cmplti,.Cmplei,.Cmpgti,.Cmpgei,.Cmpeqi,.Cmpneqi,.Bit_And,.Bit_Or,.Bit_Xor,.Bit_Lshift,
         .Bit_Rshift,.Logic_And,.Logic_Or,.Logic_Xor,.Noise2d,
         .Mul_2x,.Sub_Neg,.Div_F2i,.I2f_Div0,.I2f_Div1,.I2f_Mul,.F2i_Maxi,.F2i_Addi,.Bit_And_I2f,.Neg_Cmplt,.Random_Add,.Max_F2i:
        return 2
    case .Mad,.Lerp,.Clamp,.Select,.Clampi,.Noise3d,
         .Cmplt_Logic_And,.Cmple_Logic_And,.Cmpgt_Logic_And,.Cmpge_Logic_And,.Cmpeq_Logic_And,.Cmpne_Logic_And,
         .Cmplti_Logic_And,.Cmplei_Logic_And,.Cmpgti_Logic_And,.Cmpgei_Logic_And,.Cmpeqi_Logic_And,.Cmpnei_Logic_And,
         .Cmplt_Logic_Or,.Cmple_Logic_Or,.Cmpgt_Logic_Or,.Cmpge_Logic_Or,.Cmpeq_Logic_Or,.Cmpne_Logic_Or,
         .Cmplti_Logic_Or,.Cmplei_Logic_Or,.Cmpgti_Logic_Or,.Cmpgei_Logic_Or,.Cmpeqi_Logic_Or,.Cmpnei_Logic_Or,
         .Mad_Sqrt,.Mul_Add,.Mul_Sub0,.Mul_Sub1,.Mul_Mul,.Mul_Max,.Add_Add,.Sub_Cmplt1,.Sub_Mul,.Div_Mul,
         .Muli_Addi,.Addi_Bit_Rshift,.Addi_Muli,.I2f_Mad0,.I2f_Mad1,.F2i_Select1,.Fmod_Add,
         .Bit_Rshift_Bit_And,.Bit_Or_Muli,.Bit_Lshift_Bit_Or:
        return 3
    case .Cmplt_Select,.Cmple_Select,.Cmpeq_Select,.Cmplti_Select,.Cmplei_Select,.Cmpeqi_Select,
         .Mad_Add,.Mad_Sub0,.Mad_Sub1,.Mad_Mul,.Mul_Mad0,.Mul_Mad1,.Add_Mad1,.Div_Mad0,.Select_Mul,.Select_Add:
        return 4
    case .Mad_Mad0,.Mad_Mad1:
        return 5
    }
    return 0
}

// Register outputs of an operation (2 for paired VectorVM2 merged ops).
@(private)
niagara_op_outputs :: proc(op:Niagara_Op) -> int {
    #partial switch op {
    case .Mul_2x,.B2i_2x,.Random_2x,.Sin_Cos: return 2
    }
    return niagara_op_inputs(op)>0 ? 1 : 0
}

// The bits an operation over registers leaves, as the VM computes them.
// Returns expr0 and, for 2-output merged ops, expr1.
@(private)
niagara_op_expressions :: proc(op:Niagara_Op,args:[]string) -> (e0,e1:string) {
    a:=len(args)>0?args[0]:"0u"
    b:=len(args)>1?args[1]:"0u"
    c:=len(args)>2?args[2]:"0u"
    d:=len(args)>3?args[3]:"0u"
    e:=len(args)>4?args[4]:"0u"
    F :: proc(x:string) -> string {return fmt.tprintf("asfloat(%s)",x)}
    I :: proc(x:string) -> string {return fmt.tprintf("asint(%s)",x)}
    f :: proc(format:string,vals:..any) -> string {return fmt.tprintf("asuint(%s)",fmt.tprintf(format,..vals))}
    mask :: proc(format:string,vals:..any) -> string {return fmt.tprintf("((%s) ? 0xFFFFFFFFu : 0u)",fmt.tprintf(format,..vals))}
    sel :: proc(cond,t_val,f_val:string) -> string {return fmt.tprintf("((%s & %s) | (~%s & %s))",cond,t_val,cond,f_val)}
    divf :: proc(x,y:string) -> string {return fmt.tprintf("(abs(%s) > 1e-8 ? %s / %s : 0.0)",y,x,y)}
    #partial switch op {
    case .Add: return f("%s + %s",F(a),F(b)),""
    case .Sub: return f("%s - %s",F(a),F(b)),""
    case .Mul: return f("%s * %s",F(a),F(b)),""
    case .Div: return f("abs(%s) > 1e-8 ? %s / %s : 0.0",F(b),F(a),F(b)),""
    case .Mad: return f("%s * %s + %s",F(a),F(b),F(c)),""
    case .Lerp: return f("%s + (%s - %s) * %s",F(a),F(b),F(a),F(c)),""
    case .Rcp: return f("abs(%s) > 1e-8 ? 1.0 / %s : 0.0",F(a),F(a)),""
    case .Rsq: return f("%s > 1e-8 ? rsqrt(%s) : 0.0",F(a),F(a)),""
    case .Sqrt: return f("%s > 1e-8 ? sqrt(%s) : 0.0",F(a),F(a)),""
    case .Neg: return f("-%s",F(a)),""
    case .Abs: return f("abs(%s)",F(a)),""
    case .Exp: return f("exp(%s)",F(a)),""
    case .Exp2: return f("exp2(%s)",F(a)),""
    case .Log: return f("%s > 0.0 ? log(%s) : 0.0",F(a),F(a)),""
    case .Log2: return f("log2(%s)",F(a)),""
    case .Sin: return f("sin(%s)",F(a)),""
    case .Cos: return f("cos(%s)",F(a)),""
    case .Tan: return f("tan(%s)",F(a)),""
    case .Asin: return f("asin(clamp(%s, -1.0, 1.0))",F(a)),""
    case .Acos: return f("acos(clamp(%s, -1.0, 1.0))",F(a)),""
    case .Atan: return f("atan(%s)",F(a)),""
    case .Atan2: return f("atan2(%s, %s)",F(a),F(b)),""
    case .Ceil: return f("ceil(%s)",F(a)),""
    case .Floor: return f("floor(%s)",F(a)),""
    case .Fmod: return f("fmod(%s, %s)",F(a),F(b)),""
    case .Frac: return f("%s - trunc(%s)",F(a),F(a)),""
    case .Trunc: return f("trunc(%s)",F(a)),""
    case .Clamp: return f("min(max(%s, %s), %s)",F(a),F(b),F(c)),""
    case .Min: return f("min(%s, %s)",F(a),F(b)),""
    case .Max: return f("max(%s, %s)",F(a),F(b)),""
    case .Pow: return f("%s > 1e-8 ? pow(%s, %s) : 0.0",F(a),F(a),F(b)),""
    case .Round: return f("round(%s)",F(a)),""
    case .Sign: return f("%s >= 0.0 ? 1.0 : -1.0",F(a)),""
    case .Step: return f("%s - %s >= 0.0 ? 1.0 : 0.0",F(b),F(a)),""
    case .Random: return f("rand(%s)",F(a)),""
    case .Noise,.Noise2d,.Noise3d: return "0u",""
    case .Cmplt: return mask("%s < %s",F(a),F(b)),""
    case .Cmple: return mask("%s <= %s",F(a),F(b)),""
    case .Cmpgt: return mask("%s > %s",F(a),F(b)),""
    case .Cmpge: return mask("%s >= %s",F(a),F(b)),""
    case .Cmpeq: return mask("%s == %s",F(a),F(b)),""
    case .Cmpneq: return mask("%s != %s",F(a),F(b)),""
    case .Select: return fmt.tprintf("(%s & %s) | (~%s & %s)",a,b,a,c),""
    case .Addi: return f("%s + %s",I(a),I(b)),""
    case .Subi: return f("%s - %s",I(a),I(b)),""
    case .Muli: return f("%s * %s",I(a),I(b)),""
    case .Divi: return f("niagara_vm_divi(%s, %s)",I(a),I(b)),""
    case .Clampi: return f("min(max(%s, %s), %s)",I(a),I(b),I(c)),""
    case .Mini: return f("min(%s, %s)",I(a),I(b)),""
    case .Maxi: return f("max(%s, %s)",I(a),I(b)),""
    case .Absi: return f("abs(%s)",I(a)),""
    case .Negi: return f("-%s",I(a)),""
    case .Signi: return f("%s >= 0 ? 1 : -1",I(a)),""
    case .Randomi: return f("int(rand(float(%s)))",I(a)),""
    case .Cmplti: return mask("%s < %s",I(a),I(b)),""
    case .Cmplei: return mask("%s <= %s",I(a),I(b)),""
    case .Cmpgti: return mask("%s > %s",I(a),I(b)),""
    case .Cmpgei: return mask("%s >= %s",I(a),I(b)),""
    case .Cmpeqi: return mask("%s == %s",I(a),I(b)),""
    case .Cmpneqi: return mask("%s != %s",I(a),I(b)),""
    case .Bit_And,.Logic_And: return fmt.tprintf("%s & %s",a,b),""
    case .Bit_Or,.Logic_Or: return fmt.tprintf("%s | %s",a,b),""
    case .Bit_Xor,.Logic_Xor: return fmt.tprintf("%s ^ %s",a,b),""
    case .Bit_Not,.Logic_Not: return fmt.tprintf("~%s",a),""
    case .Bit_Lshift: return fmt.tprintf("%s << %s",a,b),""
    case .Bit_Rshift: return fmt.tprintf("%s >> %s",a,b),""
    case .F2i: return f("int(%s)",F(a)),""
    case .I2f: return f("float(%s)",I(a)),""
    case .F2b: return mask("%s > 0.0",F(a)),""
    case .B2f: return fmt.tprintf("%s & 0x3f800000u",a),""
    case .I2b: return mask("%s > 0",I(a)),""
    case .B2i: return fmt.tprintf("%s & 1u",a),""
    case .Half_To_Float,.Fasi,.Iasf: return a,""
    // Merged VectorVM2 opcodes (99..176; 98 is exec_indexf and 177..178 are half outputs).
    case .Exec_Index_Addi: return f("ExecIndex() + %s",I(a)),""
    case .Cmplt_Select: return sel(mask("%s < %s",F(a),F(b)),c,d),""
    case .Cmple_Select: return sel(mask("%s <= %s",F(a),F(b)),c,d),""
    case .Cmpeq_Select: return sel(mask("%s == %s",F(a),F(b)),c,d),""
    case .Cmplti_Select: return sel(mask("%s < %s",I(a),I(b)),c,d),""
    case .Cmplei_Select: return sel(mask("%s <= %s",I(a),I(b)),c,d),""
    case .Cmpeqi_Select: return sel(mask("%s == %s",I(a),I(b)),c,d),""
    case .Cmplt_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s < %s",F(a),F(b)),c),""
    case .Cmple_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s <= %s",F(a),F(b)),c),""
    case .Cmpgt_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s > %s",F(a),F(b)),c),""
    case .Cmpge_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s >= %s",F(a),F(b)),c),""
    case .Cmpeq_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s == %s",F(a),F(b)),c),""
    case .Cmpne_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s != %s",F(a),F(b)),c),""
    case .Cmplti_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s < %s",I(a),I(b)),c),""
    case .Cmplei_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s <= %s",I(a),I(b)),c),""
    case .Cmpgti_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s > %s",I(a),I(b)),c),""
    case .Cmpgei_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s >= %s",I(a),I(b)),c),""
    case .Cmpeqi_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s == %s",I(a),I(b)),c),""
    case .Cmpnei_Logic_And: return fmt.tprintf("(%s & %s)",mask("%s != %s",I(a),I(b)),c),""
    case .Cmplt_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s < %s",F(a),F(b)),c),""
    case .Cmple_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s <= %s",F(a),F(b)),c),""
    case .Cmpgt_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s > %s",F(a),F(b)),c),""
    case .Cmpge_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s >= %s",F(a),F(b)),c),""
    case .Cmpeq_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s == %s",F(a),F(b)),c),""
    case .Cmpne_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s != %s",F(a),F(b)),c),""
    case .Cmplti_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s < %s",I(a),I(b)),c),""
    case .Cmplei_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s <= %s",I(a),I(b)),c),""
    case .Cmpgti_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s > %s",I(a),I(b)),c),""
    case .Cmpgei_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s >= %s",I(a),I(b)),c),""
    case .Cmpeqi_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s == %s",I(a),I(b)),c),""
    case .Cmpnei_Logic_Or: return fmt.tprintf("(%s | %s)",mask("%s != %s",I(a),I(b)),c),""
    case .Mad_Add: return f("(%s * %s + %s) + %s",F(a),F(b),F(c),F(d)),""
    case .Mad_Sub0: return f("(%s * %s + %s) - %s",F(a),F(b),F(c),F(d)),""
    case .Mad_Sub1: return f("%s - (%s * %s + %s)",F(d),F(a),F(b),F(c)),""
    case .Mad_Mul: return f("(%s * %s + %s) * %s",F(a),F(b),F(c),F(d)),""
    case .Mad_Sqrt: return f("(%s * %s + %s) > 1e-8 ? sqrt(%s * %s + %s) : 0.0",F(a),F(b),F(c),F(a),F(b),F(c)),""
    case .Mad_Mad0: return f("%s * %s + (%s * %s + %s)",F(d),F(e),F(a),F(b),F(c)),""
    case .Mad_Mad1: return f("(%s * %s + %s) * %s + %s",F(a),F(b),F(c),F(d),F(e)),""
    case .Mul_Mad0: return f("(%s * %s) * %s + %s",F(a),F(b),F(c),F(d)),""
    case .Mul_Mad1: return f("%s * %s + (%s * %s)",F(c),F(d),F(a),F(b)),""
    case .Mul_Add: return f("%s * %s + %s",F(a),F(b),F(c)),""
    case .Mul_Sub0: return f("%s * %s - %s",F(a),F(b),F(c)),""
    case .Mul_Sub1: return f("%s - %s * %s",F(c),F(a),F(b)),""
    case .Mul_Mul: return f("(%s * %s) * %s",F(a),F(b),F(c)),""
    case .Mul_Max: return f("max(%s * %s, %s)",F(a),F(b),F(c)),""
    case .Mul_2x:
        m:=f("%s * %s",F(a),F(b))
        return m,m
    case .Add_Mad1: return f("%s * %s + (%s + %s)",F(c),F(d),F(a),F(b)),""
    case .Add_Add: return f("(%s + %s) + %s",F(a),F(b),F(c)),""
    case .Sub_Cmplt1: return mask("%s < (%s - %s)",F(c),F(a),F(b)),""
    case .Sub_Neg: return f("-(%s - %s)",F(a),F(b)),""
    case .Sub_Mul: return f("(%s - %s) * %s",F(a),F(b),F(c)),""
    case .Div_Mad0: return f("%s * %s + %s",divf(F(a),F(b)),F(c),F(d)),""
    case .Div_F2i: return f("int(%s)",divf(F(a),F(b))),""
    case .Div_Mul: return f("%s * %s",divf(F(a),F(b)),F(c)),""
    case .Muli_Addi: return f("%s * %s + %s",I(a),I(b),I(c)),""
    // UE6 VVMIntRShift performs unsigned logical right shift (uint32 >> uint32);
    // Bit_Rshift, Addi_Bit_Rshift, and Bit_Rshift_Bit_And all match that exact shift.
    case .Addi_Bit_Rshift: return fmt.tprintf("(asuint(%s + %s) >> %s)",I(a),I(b),c),""
    case .Addi_Muli: return f("(%s + %s) * %s",I(a),I(b),I(c)),""
    case .B2i_2x:
        v:=fmt.tprintf("(%s & 1u)",a)
        return v,v
    case .I2f_Div0: return f("%s",divf(fmt.tprintf("float(%s)",I(a)),F(b))),""
    case .I2f_Div1: return f("%s",divf(F(b),fmt.tprintf("float(%s)",I(a)))),""
    case .I2f_Mul: return f("float(%s) * %s",I(a),F(b)),""
    case .I2f_Mad0: return f("float(%s) * %s + %s",I(a),F(b),F(c)),""
    case .I2f_Mad1: return f("%s * %s + float(%s)",F(a),F(b),I(c)),""
    case .F2i_Select1: return sel(a,f("int(%s)",F(b)),c),""
    case .F2i_Maxi: return f("max(int(%s), %s)",F(a),I(b)),""
    case .F2i_Addi: return f("int(%s) + %s",F(a),I(b)),""
    case .Fmod_Add: return f("fmod(%s, %s) + %s",F(a),F(b),F(c)),""
    case .Bit_And_I2f: return f("float(asint(%s & %s))",a,b),""
    case .Bit_Rshift_Bit_And: return fmt.tprintf("((%s >> %s) & %s)",a,b,c),""
    case .Neg_Cmplt: return mask("(-%s) < %s",F(a),F(b)),""
    case .Bit_Or_Muli: return f("asint(%s | %s) * %s",a,b,I(c)),""
    case .Bit_Lshift_Bit_Or: return fmt.tprintf("((%s << %s) | %s)",a,b,c),""
    case .Random_Add: return f("rand(%s) + %s",F(a),F(b)),""
    case .Random_2x: return f("rand(%s)",F(a)),f("rand(%s)",F(a))
    case .Max_F2i: return f("int(max(%s, %s))",F(a),F(b)),""
    case .Select_Mul: return f("asfloat(%s) * %s",sel(a,b,c),F(d)),""
    case .Select_Add: return f("asfloat(%s) + %s",sel(a,b,c),F(d)),""
    case .Sin_Cos: return f("sin(%s)",F(a)),f("cos(%s)",F(a))
    }
    return "0u",""
}

// Emits a VectorVM2 call whose arguments use unified register indices.
@(private)
niagara_vm2_call :: proc(w:^Niagara_Vm_Writer,fn:^Niagara_Vm_Function,in_exprs:[]string,out_regs:[]int) {
    if !fn.found {
        niagara_vm_problem(w,"%s.%s reads %d registers and writes %d, which no signature its compilation keeps matches (%s): it gives zero",fn.owner,fn.name,fn.inputs,fn.outputs,fn.registered==""?"none":strings.trim_space(fn.registered))
        for o in out_regs {if o!=0xFFFF {fmt.sbprintf(&w.body,"    v%d = 0u;\n",o)}}
        return
    }
    prototype:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&prototype,"void %s(",fn.symbol)
    named:=make([dynamic]string,context.temp_allocator)
    for p,i in fn.params {
        if i>0 {strings.write_string(&prototype,", ")}
        name:=strings.concatenate({i>=fn.ins?"Out_":"In_",niagara_symbol(p.name)},context.temp_allocator)
        if slice.contains(named[:],name) {name=fmt.tprintf("%s_%d",name,i)}
        append(&named,name)
        fmt.sbprintf(&prototype,"%s%s %s",i>=fn.ins?"out ":"",p.type.hlsl,name)
    }
    strings.write_string(&prototype,");")
    if text:=strings.to_string(prototype);!slice.contains(w.prototypes[:],text) {append(&w.prototypes,text)}
    strings.write_string(&w.body,"    {\n")
    in_components:=0
    for p in fn.params[:fn.ins] {in_components+=len(p.type.components)}
    if len(in_exprs)<in_components {
        niagara_vm_problem(w,"%s.%s receives %d input registers, fewer than its %d signature components: missing inputs read zero",fn.owner,fn.name,len(in_exprs),in_components)
    }
    // Skip leading data-interface instance register(s) when present before parameter components.
    k:=len(in_exprs)>in_components ? len(in_exprs)-in_components : 0
    for p,i in fn.params {
        fmt.sbprintf(&w.body,"        %s a%d = (%s)0;\n",p.type.hlsl,i,p.type.hlsl)
        if i>=fn.ins {continue}
        for c in p.type.components {
            bits:=k<len(in_exprs)?in_exprs[k]:"0u"
            k+=1
            fmt.sbprintf(&w.body,"        a%d%s = %s;\n",i,c.suffix,niagara_vm_value(bits,c))
        }
    }
    fmt.sbprintf(&w.body,"        %s(",fn.symbol)
    for _,i in fn.params {fmt.sbprintf(&w.body,"%sa%d",i>0?", ":"",i)}
    strings.write_string(&w.body,");\n")
    k=0
    for p,i in fn.params[fn.ins:] {
        for c in p.type.components {
            o:=k<len(out_regs)?out_regs[k]:0xFFFF
            k+=1
            if o!=0xFFFF {fmt.sbprintf(&w.body,"        v%d = %s;\n",o,niagara_vm_bits(fmt.tprintf("a%d%s",fn.ins+i,c.suffix),c))}
        }
    }
    strings.write_string(&w.body,"    }\n")
}

// Decompiles a frozen VectorVM2 script (ExperimentalContextData / OptimizedByteCode)
// into the same HLSL shape as niagara_vm_hlsl.
@(private)
niagara_vm2_hlsl :: proc(w:^Niagara_Vm_Writer,ctx:^Niagara_Vm2,entry,map_name:string,problems:^[dynamic]string) -> (text:string,ok:bool) {
    if ctx.num_temp_regs<0 || ctx.num_temp_regs>MAX_VVM2_REGS {
        append(problems,"its VectorVM2 temp register count is out of range: its script is not translated")
        return
    }
    code:=ctx.bytecode
    at:=0
    // VectorVM2 unified RegPtrTable layout:
    //   [0 .. const_base)               : temp registers (VVM_RT_TEMPREG)
    //   [const_base .. input_base)      : remapped constants (VVM_RT_CONST)
    //   [input_base .. input_base+N_in) : active per-chunk input pointers (VVM_RT_INPUT)
    //   [input_base+N_in .. output_base): runtime-only base input pointers (never in bytecode)
    //   [output_base .. output_base+N_o): output buffer pointers (VVM_RT_OUTPUT), which the
    //                                     optimizer may also alias as scratch temp registers.
    const_base:=ctx.num_temp_regs
    input_base:=const_base+len(ctx.const_remap)
    output_base:=input_base+len(ctx.inputs)*2

    u16_at :: proc(code:[]u8,at:int,bad:^bool) -> int {
        if at+2>len(code) {bad^=true;return 0}
        v,_:=endian.get_u16(code[at:],.Little)
        return int(v)
    }
    // Maps a temp register or an optimizer-aliased output register to a local vN slot.
    slot_of :: proc(ctx:^Niagara_Vm2,output_base,index:int) -> (slot:int,valid:bool) {
        if index>=0 && index<ctx.num_temp_regs {return index,true}
        if s:=index-output_base;s>=0 && s<len(ctx.outputs) {return ctx.num_temp_regs+s,true}
        return 0,false
    }
    write_reg :: proc(w:^Niagara_Vm_Writer,ctx:^Niagara_Vm2,output_base,index:int,bad_reg:^bool) -> string {
        slot,valid:=slot_of(ctx,output_base,index)
        if !valid {
            bad_reg^=true
            return "v0"
        }
        w.registers=max(w.registers,slot+1)
        return fmt.tprintf("v%d",slot)
    }
    read_reg :: proc(w:^Niagara_Vm_Writer,ctx:^Niagara_Vm2,const_base,input_base,output_base,r:int,bad_reg:^bool) -> string {
        if r==0xFFFF {return "0u"}
        if r>=0 && r<ctx.num_temp_regs {
            w.registers=max(w.registers,r+1)
            return fmt.tprintf("v%d",r)
        }
        if r>=const_base && r<const_base+len(ctx.const_remap) {
            return niagara_vm_constant(w,int(ctx.const_remap[r-const_base])*4)
        }
        if r>=input_base && r<input_base+len(ctx.inputs) {
            inp:=ctx.inputs[r-input_base]
            return niagara_vm_input(w,inp.data_set,inp.index,inp.register)
        }
        if s:=r-output_base;s>=0 && s<len(ctx.outputs) {
            slot:=ctx.num_temp_regs+s
            w.registers=max(w.registers,slot+1)
            return fmt.tprintf("v%d",slot)
        }
        bad_reg^=true
        return "0u"
    }

    decode: for at<len(code) {
        if code[at]>u8(Niagara_Op.Output_Half_From_Half) {
            append(problems,fmt.tprintf("its bytecode has an operation %d at byte %d the translation does not know: its script is not translated",code[at],at))
            return
        }
        op:=Niagara_Op(code[at])
        at+=1
        bad:=false
        bad_reg:=false
        #partial switch op {
        case .Done:
            break decode
        case .Enter_Stat_Scope:
            if at+2>len(code) {bad=true;break}
            at+=2
        case .Exit_Stat_Scope:
            // Stat scopes have no effect on value semantics.
        case .Fasi,.Iasf:
            // The VectorVM2 optimizer always removes fasi/iasf casts during SSA remapping;
            // their presence in frozen VectorVM2 bytecode indicates malformed/unoptimized input.
            append(problems,fmt.tprintf("its VectorVM2 bytecode has an unstripped cast operation %v at byte %d: its script is not translated",op,at-1))
            return
        case .Exec_Index:
            dst:=u16_at(code,at,&bad)
            at+=2
            if bad {break}
            fmt.sbprintf(&w.body,"    %s = asuint(ExecIndex());\n",write_reg(w,ctx,output_base,dst,&bad_reg))
        case .Exec_Indexf:
            dst:=u16_at(code,at,&bad)
            at+=2
            if bad {break}
            fmt.sbprintf(&w.body,"    %s = asuint(float(ExecIndex()));\n",write_reg(w,ctx,output_base,dst,&bad_reg))
        case .Output_Float,.Output_Int,.Output_Half,.Output_Float_From_Half,.Output_Half_From_Half:
            if at+2>len(code) {bad=true;break}
            num_loops:=int(code[at])
            at+=2
            if at+num_loops*4>len(code) {bad=true;break}
            srcs:=make([]int,num_loops,context.temp_allocator)
            dsts:=make([]int,num_loops,context.temp_allocator)
            for j in 0..<num_loops {srcs[j]=u16_at(code,at+j*2,&bad)}
            at+=num_loops*2
            for j in 0..<num_loops {dsts[j]=u16_at(code,at+j*2,&bad)}
            at+=num_loops*2
            if bad {break}
            for j in 0..<num_loops {
                serial:=dsts[j]-output_base
                if serial<0 || serial>=len(ctx.outputs) {
                    niagara_vm_problem(w,"its VectorVM2 output register %d is outside the output remap table: skipped",dsts[j])
                    continue
                }
                o:=ctx.outputs[serial]
                if o.dst_reg==0xFFFF {continue}
                src_expr:=read_reg(w,ctx,const_base,input_base,output_base,srcs[j],&bad_reg)
                if bad_reg {break}
                niagara_vm_output(w,o.data_set,o.dst_reg,o.register,src_expr)
            }
        case .Acquire_Index:
            in_reg:=u16_at(code,at,&bad)
            if at+3>len(code) {bad=true;break}
            ds:=int(code[at+2])
            at+=3
            if bad {break}
            if ds==0 && w.vm.usage!=.System {
                fmt.sbprintf(&w.body,"    %s = (%s != 0u);\n",niagara_vm_path(w,"DataInstance.Alive","bool"),read_reg(w,ctx,const_base,input_base,output_base,in_reg,&bad_reg))
            }
        case .Update_Id,.Acquire_Id:
            r0,r1:=u16_at(code,at,&bad),u16_at(code,at+2,&bad)
            if at+5>len(code) {bad=true;break}
            at+=5
            if bad {break}
            if op==.Acquire_Id {
                fmt.sbprintf(&w.body,"    %s = asuint(niagara_id.x);\n    %s = asuint(niagara_id.y);\n",write_reg(w,ctx,output_base,r0,&bad_reg),write_reg(w,ctx,output_base,r1,&bad_reg))
            }
        case .External_Call:
            fi:=u16_at(code,at,&bad)
            at+=2
            if bad {break}
            if fi>=len(w.vm.functions) {
                append(problems,fmt.tprintf("its bytecode calls a function %d its compilation does not list: its script is not translated",fi))
                return
            }
            fn:=&w.vm.functions[fi]
            n_in,n_out:=fn.inputs,fn.outputs
            if fi<len(ctx.ext_fns) {n_in,n_out=ctx.ext_fns[fi].num_inputs,ctx.ext_fns[fi].num_outputs}
            if n_in<0 || n_out<0 || at+2*(n_in+n_out)>len(code) {bad=true;break}
            in_exprs:=make([]string,n_in,context.temp_allocator)
            for k in 0..<n_in {in_exprs[k]=read_reg(w,ctx,const_base,input_base,output_base,u16_at(code,at+2*k,&bad),&bad_reg)}
            at+=2*n_in
            out_regs:=make([]int,n_out,context.temp_allocator)
            for k in 0..<n_out {
                r:=u16_at(code,at+2*k,&bad)
                if r!=0xFFFF {
                    slot,valid:=slot_of(ctx,output_base,r)
                    if !valid {bad_reg=true;break}
                    w.registers=max(w.registers,slot+1)
                    out_regs[k]=slot
                } else {
                    out_regs[k]=0xFFFF
                }
            }
            at+=2*n_out
            if bad || bad_reg {break}
            niagara_vm2_call(w,fn,in_exprs,out_regs)
        case:
            inputs:=niagara_op_inputs(op)
            outputs:=niagara_op_outputs(op)
            if inputs==0 {
                append(problems,fmt.tprintf("its bytecode has the operation %v at byte %d, which a compilation does not write: its script is not translated",op,at-1))
                return
            }
            args:[5]string
            for i in 0..<inputs {args[i]=read_reg(w,ctx,const_base,input_base,output_base,u16_at(code,at+2*i,&bad),&bad_reg)}
            dst0:=u16_at(code,at+2*inputs,&bad)
            dst1:=outputs==2 ? u16_at(code,at+2*(inputs+1),&bad) : 0xFFFF
            at+=2*(inputs+outputs)
            if bad {break}
            e0,e1:=niagara_op_expressions(op,args[:inputs])
            if outputs==2 {
                // Snapshot both results into temporaries before writing dst0/dst1 so in-place
                // register aliasing (dst0 == input) cannot corrupt the second result.
                // Mul_2x and B2i_2x compute one shared value copied to both outputs; Random_2x
                // and Sin_Cos compute two distinct outputs.
                d0:=dst0!=0xFFFF ? write_reg(w,ctx,output_base,dst0,&bad_reg) : ""
                d1:=dst1!=0xFFFF ? write_reg(w,ctx,output_base,dst1,&bad_reg) : ""
                if op==.Mul_2x || op==.B2i_2x {
                    fmt.sbprintf(&w.body,"    {{ uint _t = %s;",e0)
                    if d0!="" {fmt.sbprintf(&w.body," %s = _t;",d0)}
                    if d1!="" {fmt.sbprintf(&w.body," %s = _t;",d1)}
                    strings.write_string(&w.body," }\n")
                } else {
                    fmt.sbprintf(&w.body,"    {{ uint _t0 = %s; uint _t1 = %s;",e0,e1)
                    if d0!="" {fmt.sbprintf(&w.body," %s = _t0;",d0)}
                    if d1!="" {fmt.sbprintf(&w.body," %s = _t1;",d1)}
                    strings.write_string(&w.body," }\n")
                }
            } else {
                fmt.sbprintf(&w.body,"    %s = %s;\n",write_reg(w,ctx,output_base,dst0,&bad_reg),e0)
            }
        }
        if bad_reg {
            append(problems,fmt.tprintf("its VectorVM2 bytecode references an out-of-range register near byte %d: its script is not translated",at))
            return
        }
        if bad {
            append(problems,fmt.tprintf("its bytecode ends inside an operation at byte %d: its script is not translated",at))
            return
        }
    }
    return niagara_vm_text(w,entry,map_name),true
}

// The text of a script decompiled from its bytecode, in the shape the
// translator writes for the VM; false for bytecode it cannot read, with a
// problem that says why.
@(private)
niagara_vm_hlsl :: proc(vm:^Niagara_Vm,problems:^[dynamic]string) -> (text:string,ok:bool) {
    w:=Niagara_Vm_Writer{vm=vm,problems=problems}
    entry,map_name:="Simulate","Map"
    if vm.usage==.Spawn {entry,map_name="SimulateMapSpawn","MapSpawn"}
    w.M=strings.concatenate({"Context.",map_name},context.temp_allocator)
    w.body=strings.builder_make(context.temp_allocator)
    w.paths=make([dynamic]Niagara_Vm_Path,context.temp_allocator)
    w.globals=make([dynamic]Hlsl_Field,context.temp_allocator)
    w.reads=make([dynamic]string,context.temp_allocator)
    w.writes=make([dynamic]string,context.temp_allocator)
    w.prototypes=make([dynamic]string,context.temp_allocator)
    w.table=niagara_vm_table(vm)
    // The first frame of the scripts of the system runs with a step of its own (niagara_main_write).
    if vm.usage==.System {_=niagara_vm_constant(&w,4)}
    if ctx,has_vvm2:=vm.vvm2.?;has_vvm2 {
        return niagara_vm2_hlsl(&w,&ctx,entry,map_name,problems)
    }
    code:=vm.code
    at:=0
    // The u16 of the operation at an offset of bytes from its first operand.
    u :: proc(code:[]u8,at:int,bad:^bool) -> int {
        if at+2>len(code) {bad^=true;return 0}
        v,_:=endian.get_u16(code[at:],.Little)
        return int(v)
    }
    reg :: proc(w:^Niagara_Vm_Writer,index:int) -> string {
        w.registers=max(w.registers,index+1)
        return fmt.tprintf("v%d",index)
    }
    decode: for at<len(code) {
        if code[at]>u8(Niagara_Op.Output_Half_From_Half) {
            append(problems,fmt.tprintf("its bytecode has an operation %d at byte %d the translation does not know: its script is not translated",code[at],at))
            return
        }
        op:=Niagara_Op(code[at])
        at+=1
        bad:=false
        #partial switch op {
        case .Done:
            break decode
        case .Input_Float,.Input_Int,.Input_Half,.Input_Noadvance_Float,.Input_Noadvance_Int,.Input_Noadvance_Half:
            set,index,dst:=u(code,at,&bad),u(code,at+2,&bad),u(code,at+4,&bad)
            at+=6
            if bad {break}
            register:=Niagara_Register.Float
            #partial switch op {
            case .Input_Int,.Input_Noadvance_Int: register=.Int
            case .Input_Half,.Input_Noadvance_Half: register=.Half
            }
            fmt.sbprintf(&w.body,"    %s = %s;\n",reg(&w,dst),niagara_vm_input(&w,set,index,register))
        case .Output_Float,.Output_Int,.Output_Half,.Output_Float_From_Half,.Output_Half_From_Half:
            // [op][operand: register 0, constant 1][set][index register][source][register of the set]
            if at>=len(code) {bad=true;break}
            constant:=code[at]&1!=0
            set,source,dst:=u(code,at+1,&bad),u(code,at+5,&bad),u(code,at+7,&bad)
            at+=9
            if bad {break}
            register:=Niagara_Register.Float
            if op==.Output_Int {register=.Int} else if op==.Output_Half || op==.Output_Half_From_Half {register=.Half}
            niagara_vm_output(&w,set,dst,register,constant?niagara_vm_constant(&w,source):reg(&w,source))
        case .Acquire_Index:
            // [op][operand of the condition][set][condition][index]: whether the instance stays.
            if at>=len(code) {bad=true;break}
            constant:=code[at]&1!=0
            set,keep,dst:=u(code,at+1,&bad),u(code,at+3,&bad),u(code,at+5,&bad)
            at+=7
            if bad {break}
            if set==0 && vm.usage!=.System {
                fmt.sbprintf(&w.body,"    %s = (%s != 0u);\n",niagara_vm_path(&w,"DataInstance.Alive","bool"),constant?niagara_vm_constant(&w,keep):reg(&w,keep))
            }
            fmt.sbprintf(&w.body,"    %s = 0u;\n",reg(&w,dst))
        case .Exec_Index:
            dst:=u(code,at,&bad)
            at+=2
            if bad {break}
            fmt.sbprintf(&w.body,"    %s = asuint(ExecIndex());\n",reg(&w,dst))
        case .Exec_Indexf:
            dst:=u(code,at,&bad)
            at+=2
            if bad {break}
            fmt.sbprintf(&w.body,"    %s = asuint(float(ExecIndex()));\n",reg(&w,dst))
        case .Enter_Stat_Scope:
            at+=2
        case .Exit_Stat_Scope:
        case .Update_Id,.Acquire_Id:
            _,index,tag:=u(code,at,&bad),u(code,at+2,&bad),u(code,at+4,&bad)
            at+=6
            if bad {break}
            // The id of a particle is its slot and its seed (niagara_id).
            if op==.Acquire_Id {fmt.sbprintf(&w.body,"    %s = asuint(niagara_id.x);\n    %s = asuint(niagara_id.y);\n",reg(&w,index),reg(&w,tag))}
        case .External_Call:
            // A save of 5.8 writes the index of the function in one byte.
            if at>=len(code) {bad=true;break}
            index:=int(code[at])
            at+=1
            if index>=len(vm.functions) {
                append(problems,fmt.tprintf("its bytecode calls a function %d its compilation does not list: its script is not translated",index))
                return
            }
            fn:=&vm.functions[index]
            operands:=make([]int,fn.inputs+fn.outputs,context.temp_allocator)
            for &o,i in operands {o=u(code,at+2*i,&bad)}
            at+=2*len(operands)
            if bad {break}
            for o,i in operands {
                if i>=fn.inputs && o!=0xFFFF {_=reg(&w,o)}
                if i<fn.inputs && o!=0xFFFF && o&0x8000!=0 {_=reg(&w,o&0x7FFF)}
            }
            niagara_vm_call(&w,fn,operands)
        case:
            inputs:=niagara_op_inputs(op)
            outputs:=niagara_op_outputs(op)
            if inputs==0 {
                append(problems,fmt.tprintf("its bytecode has the operation %v at byte %d, which a compilation does not write: its script is not translated",op,at-1))
                return
            }
            if at>=len(code) {bad=true;break}
            flags:=code[at]
            args:[5]string
            for i in 0..<inputs {
                v:=u(code,at+1+2*i,&bad)
                args[i]=flags&(1<<uint(i))!=0?niagara_vm_constant(&w,v):reg(&w,v)
            }
            dst0:=u(code,at+1+2*inputs,&bad)
            dst1:=outputs==2 ? u(code,at+1+2*(inputs+1),&bad) : 0xFFFF
            at+=1+2*(inputs+outputs)
            if bad {break}
            e0,e1:=niagara_op_expressions(op,args[:inputs])
            fmt.sbprintf(&w.body,"    %s = %s;\n",reg(&w,dst0),e0)
            if outputs==2 && dst1!=0xFFFF {fmt.sbprintf(&w.body,"    %s = %s;\n",reg(&w,dst1),e1)}
        }
        if bad {
            append(problems,fmt.tprintf("its bytecode ends inside an operation at byte %d: its script is not translated",at))
            return
        }
    }
    return niagara_vm_text(&w,entry,map_name),true
}

// The text around the statements: the structs of the parameter map, the
// constants, the prototypes of the functions of data interfaces, the entry
// and SimulateMain.
@(private)
niagara_vm_text :: proc(w:^Niagara_Vm_Writer,entry,map_name:string) -> string {
    s:=strings.builder_make(context.temp_allocator)
    strings.write_string(&s,"// Decompiled from the bytecode of the VectorVM (unreal_vfx/editor, niagara_vm.odin).\n")
    strings.write_string(&s,"struct NiagaraID {\n    int Index;\n    int AcquireTag;\n};\n")
    strings.write_string(&s,"struct NiagaraEmitterID {\n    int ID;\n};\n")
    strings.write_string(&s,"struct NiagaraSpawnInfo {\n    int Count;\n    float InterpStartDt;\n    float IntervalDt;\n    int SpawnGroup;\n};\n")
    // The structs of the map, the deepest first: FParamMap0_Particles_Previous before FParamMap0_Particles.
    Field :: struct {name,type:string}
    Node :: struct {prefix:string,depth:int,fields:[dynamic]Field}
    nodes:=make([dynamic]Node,context.temp_allocator)
    node :: proc(nodes:^[dynamic]Node,prefix:string,depth:int) -> ^Node {
        for &n in nodes {if n.prefix==prefix {return &n}}
        append(nodes,Node{prefix,depth,make([dynamic]Field,context.temp_allocator)})
        return &nodes[len(nodes)-1]
    }
    add :: proc(n:^Node,name,type:string) {
        for f in n.fields {if f.name==name {return}}
        append(&n.fields,Field{name,type})
    }
    _=node(&nodes,"",0)
    for p in w.paths {
        parts:=strings.split(p.path,".",context.temp_allocator)
        for i in 0..<len(parts) {
            prefix:=strings.join(parts[:i],"_",context.temp_allocator)
            type:=p.type
            if i<len(parts)-1 {type=strings.concatenate({"FParamMap0_",strings.join(parts[:i+1],"_",context.temp_allocator)},context.temp_allocator)}
            add(node(&nodes,prefix,i),parts[i],type)
        }
    }
    slice.sort_by(nodes[:],proc(a,b:Node) -> bool {return a.depth>b.depth})
    for n in nodes {
        fmt.sbprintf(&s,"struct FParamMap0%s%s {{\n",n.prefix==""?"":"_",n.prefix)
        if len(n.fields)==0 {strings.write_string(&s,"    int Unused;\n")}
        for f in n.fields {fmt.sbprintf(&s,"    %s %s;\n",f.type,f.name)}
        strings.write_string(&s,"};\n")
    }
    fmt.sbprintf(&s,"struct FSimulationContext {{\n    FParamMap0 %s;\n}};\n",map_name)
    for g in w.globals {fmt.sbprintf(&s,"%s %s;\n",g.type,g.name)}
    for p in w.prototypes {fmt.sbprintf(&s,"%s\n",p)}
    fmt.sbprintf(&s,"void %s(inout FSimulationContext Context) {{\n",entry)
    for i in 0..<w.registers {fmt.sbprintf(&s,"    uint v%d = 0u;\n",i)}
    strings.write_string(&s,strings.to_string(w.body))
    strings.write_string(&s,"}\n")
    strings.write_string(&s,"void SimulateMain() {\n    FSimulationContext Context = (FSimulationContext)0;\n")
    for line in w.reads {fmt.sbprintf(&s,"    %s\n",line)}
    fmt.sbprintf(&s,"    %s(Context);\n    WriteDataSets(Context);\n",entry)
    for line in w.writes {fmt.sbprintf(&s,"    %s\n",line)}
    strings.write_string(&s,"}\n")
    return strings.to_string(s)
}
