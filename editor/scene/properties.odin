package unreal_scene

import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

// An FColor (B, G, R, A bytes) as linear RGB: Unreal reads it as sRGB.
color_of :: proc(d:^level.Document,ref:level.Ref,name:string,default:[3]f32) -> (value:[3]f32,found:bool) {
    f,error:=level.property(d,ref,name)
    if error.code!=.None || f.property==nil {return default,false}
    if f.property.type_count<2 || unreal.name_plain(f.pkg,f.property.types[1].name)!="Color" {
        // A LinearColor.
        v,value_error:=unreal.property_value(f.pkg,f.property)
        if value_error.code!=.None || v.kind!=.Real_Vector || v.vector_count<3 {return default,false}
        return {f32(v.vector[0]),f32(v.vector[1]),f32(v.vector[2])},true
    }
    bytes,bytes_error:=unreal.span_bytes(f.pkg,f.property.data)
    if bytes_error.code!=.None || len(bytes)!=4 {return default,false}
    return mm.srgb_to_linear([3]f32{f32(bytes[2]),f32(bytes[1]),f32(bytes[0])}/255),true
}

// The fields of a struct property (FPostProcessSettings, a filmback) of an
// object and its archetypes, the nearest first: a field missing from one is
// that of the next.
Struct_Chain :: struct {
    lists:[8]unreal.Property_List,
    packages:[8]^unreal.Package,
    count:int,
}

struct_chain :: proc(d:^level.Document,ref:level.Ref,names:..string) -> (chain:Struct_Chain) {
    current:=ref
    for _ in 0..<len(chain.lists)*4 {
        if chain.count>=len(chain.lists) {break}
        held,error:=level.object_properties(d,current)
        if error.code!=.None {break}
        p:=level.library_package(d.library,int(current.pkg))
        for name in names {
            if item:=unreal.property_find(p,&held.list,name);item!=nil {
                list,list_error:=unreal.property_tagged_struct(p,item,true,context.temp_allocator)
                if list_error.code==.None {
                    chain.lists[chain.count]=list
                    chain.packages[chain.count]=p
                    chain.count+=1
                }
                break
            }
        }
        next,native,next_error:=level.template_of(d,current)
        if next_error.code!=.None || native {break}
        current=next
    }
    return
}

chain_find :: proc(chain:^Struct_Chain,name:string) -> (property:^unreal.Property,p:^unreal.Package) {
    for i in 0..<chain.count {
        if item:=unreal.property_find(chain.packages[i],&chain.lists[i],name);item!=nil {return item,chain.packages[i]}
    }
    return nil,nil
}

chain_real :: proc(chain:^Struct_Chain,name:string,default:f64) -> (value:f64,found:bool) {
    item,p:=chain_find(chain,name)
    if item==nil {return default,false}
    return level.value_real(p,item,default)
}

chain_bool :: proc(chain:^Struct_Chain,name:string) -> bool {
    item,p:=chain_find(chain,name)
    if item==nil {return false}
    v,error:=unreal.property_value(p,item)
    return error.code==.None && v.kind==.Boolean && v.boolean
}

chain_enum :: proc(chain:^Struct_Chain,name:string,default:string) -> string {
    item,p:=chain_find(chain,name)
    if item==nil {return default}
    value,_:=level.value_enum(p,item,default)
    return value
}
