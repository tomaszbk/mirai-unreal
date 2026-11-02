package material

import "core:encoding/endian"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// Reading the properties of material objects. A property that is not saved
// has the value of the class default, which the callers pass.

// An FExpressionInput: the output of another expression of the same package
// that a pin reads, the channels it keeps, and for the inputs of a material
// the constant used while nothing is connected.
Input :: struct {
    expression:unreal.Object_Ref, // 0: not connected
    output:i32,
    masked:bool,
    channels:[4]bool,
    use_constant:bool,
    constant:[4]f32,
    constant_width:u8,
    name:string, // InputName: of an input of a function call, the name of the input of the function
}

// FCoreObjectVersion::MaterialInputNativeSerialize: inputs are saved natively; before, as tagged structs.
@(private) CORE_MATERIAL_INPUT_NATIVE :: 1
// FFrameworkObjectVersion::PinsStoreFName: InputName is an FName.
@(private) FRAMEWORK_PINS_STORE_FNAME :: 31
// FFortniteMainBranchObjectVersion::MaterialInputUsesLinearColor: the constant of a color input is an FLinearColor, before an FColor.
@(private) FORTNITE_MATERIAL_INPUT_LINEAR_COLOR :: 171

// The tagged properties of o; nil when they cannot be read, which gives
// every property its default.
@(private)
props :: proc(o:Object) -> (p:^unreal.Package,list:^unreal.Property_List) {
    found,error:=object_properties(o)
    if error.code!=.None {return nil,nil}
    return &o.pkg.p,found
}

property :: proc(o:Object,name:string) -> ^unreal.Property {
    p,list:=props(o)
    return unreal.property_find(p,list,name)
}

prop_float :: proc(o:Object,name:string,default:f32) -> f32 {p,list:=props(o);return list_float(p,list,name,default)}
prop_int :: proc(o:Object,name:string,default:int) -> int {p,list:=props(o);return list_int(p,list,name,default)}
prop_bool :: proc(o:Object,name:string,default:bool) -> bool {p,list:=props(o);return list_bool(p,list,name,default)}
prop_object :: proc(o:Object,name:string) -> unreal.Object_Ref {p,list:=props(o);return list_object(p,list,name)}
prop_guid :: proc(o:Object,name:string) -> (unreal.Guid,bool) {p,list:=props(o);return list_guid(p,list,name)}
// A vector or color struct (LinearColor, Vector, Vector4, Vector2D, Color).
prop_vector :: proc(o:Object,name:string,default:[4]f32) -> [4]f32 {p,list:=props(o);return list_vector(p,list,name,default)}

// A name, or an enum saved by name without its type ("BLEND_Masked").
prop_name :: proc(o:Object,name:string,default:string) -> string {
    p,list:=props(o)
    value,ok:=value_of(p,list,name)
    if !ok || value.kind!=.Name {return default}
    return enum_value(unreal.name_text(p,value.name,context.temp_allocator))
}

// An enum saved by name or by its number; names lists the enum in order.
prop_enum :: proc(o:Object,name:string,names:[]string,default:int) -> int {
    p,list:=props(o)
    value,ok:=value_of(p,list,name)
    if !ok {return default}
    #partial switch value.kind {
    case .Name:
        text:=enum_value(unreal.name_text(p,value.name,context.temp_allocator))
        for candidate,index in names {if strings.equal_fold(candidate,text) {return index}}
    case .Unsigned:if value.unsigned<u64(len(names)) {return int(value.unsigned)}
    case .Signed:if value.signed>=0 && value.signed<i64(len(names)) {return int(value.signed)}
    }
    return default
}

@(private)
enum_value :: proc(text:string) -> string {
    if at:=strings.last_index(text,"::");at>=0 {return text[at+2:]}
    return text
}

@(private)
struct_vector :: proc(p:^unreal.Package,found:^unreal.Property,default:[4]f32) -> [4]f32 {
    if found.type_count>=2 && unreal.name_plain(p,found.types[1].name)=="Color" && found.data.size==4 {
        bytes,_:=unreal.span_bytes(p,found.data)
        return {f32(bytes[2])/255,f32(bytes[1])/255,f32(bytes[0])/255,f32(bytes[3])/255}
    }
    value,error:=unreal.property_value(p,found,context.temp_allocator)
    if error.code!=.None {return default}
    #partial switch value.kind {
    case .Real_Vector:
        out:=default
        for i in 0..<int(value.vector_count) {out[i]=f32(value.vector[i])}
        return out
    case .Real:
        return {f32(value.real),default.y,default.z,default.w}
    }
    return default
}

// The tagged structs of an array property; empty when absent.
prop_structs :: proc(o:Object,name:string) -> []unreal.Property_List {
    found:=property(o,name)
    if found==nil {return nil}
    view,error:=unreal.property_array(&o.pkg.p,found)
    if error.code!=.None {return nil}
    array,array_error:=unreal.array_tagged_structs(&o.pkg.p,view,true,o.pkg.properties.allocator)
    if array_error.code!=.None {return nil}
    return array.items
}

prop_struct :: proc(o:Object,name:string) -> (list:unreal.Property_List,ok:bool) {
    found:=property(o,name)
    if found==nil {return}
    opened,error:=unreal.property_tagged_struct(&o.pkg.p,found,true,o.pkg.properties.allocator)
    return opened,error.code==.None
}

// Values inside a tagged struct, read with the same defaults rule.
@(private)
value_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string) -> (value:unreal.Value,ok:bool) {
    found:=unreal.property_find(p,list,name)
    if found==nil {return}
    read,error:=unreal.property_value(p,found,context.temp_allocator)
    return read,error.code==.None
}

list_float :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:f32) -> f32 {
    value,ok:=value_of(p,list,name)
    if !ok {return default}
    #partial switch value.kind {
    case .Real:return f32(value.real)
    case .Signed:return f32(value.signed)
    case .Unsigned:return f32(value.unsigned)
    }
    return default
}

list_int :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:int) -> int {
    value,ok:=value_of(p,list,name)
    if !ok {return default}
    #partial switch value.kind {
    case .Signed:return int(value.signed)
    case .Unsigned:return int(value.unsigned)
    case .Real:return int(value.real)
    }
    return default
}

list_bool :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:bool) -> bool {
    value,ok:=value_of(p,list,name)
    if !ok {return default}
    #partial switch value.kind {
    case .Boolean:return value.boolean
    case .Signed:return value.signed!=0
    case .Unsigned:return value.unsigned!=0
    }
    return default
}

// A string property, cloned with allocator; "" when it is not saved.
list_string :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,allocator:=context.temp_allocator) -> string {
    value,ok:=value_of(p,list,name)
    if !ok || value.kind!=.String {return ""}
    return strings.clone(value.text,allocator)
}

prop_string :: proc(o:Object,name:string,allocator:=context.temp_allocator) -> string {p,list:=props(o);return list_string(p,list,name,allocator)}

list_name :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string) -> string {
    value,ok:=value_of(p,list,name)
    if !ok || value.kind!=.Name {return ""}
    return enum_value(unreal.name_text(p,value.name,context.temp_allocator))
}

list_object :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string) -> unreal.Object_Ref {
    value,ok:=value_of(p,list,name)
    if !ok || value.kind!=.Object {return 0}
    return value.object
}

list_guid :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string) -> (unreal.Guid,bool) {
    value,ok:=value_of(p,list,name)
    if !ok || value.kind!=.Guid {return {},false}
    return value.guid,true
}

list_vector :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:[4]f32) -> [4]f32 {
    found:=unreal.property_find(p,list,name)
    if found==nil {return default}
    return struct_vector(p,found,default)
}

// Whose a parameter is (EMaterialParameterAssociation): the material's
// own, or of the layer or blend index of its stack of material layers.
Association :: enum u8 {Global,Layer,Blend}

Layer_Ref :: struct {association:Association,index:i32}

// The name of a parameter in a struct: ParameterInfo.Name, or ParameterName
// in saves from before FMaterialParameterInfo, and the layer it is of.
list_parameter :: proc(p:^unreal.Package,list:^unreal.Property_List) -> (name:string,layer:Layer_Ref,ok:bool) {
    if info:=unreal.property_find(p,list,"ParameterInfo");info!=nil {
        inner,error:=unreal.property_tagged_struct(p,info,true,context.temp_allocator)
        if error.code!=.None {return "",{},false}
        switch list_name(p,&inner,"Association") {
        case "LayerParameter":layer={.Layer,i32(list_int(p,&inner,"Index",-1))}
        case "BlendParameter":layer={.Blend,i32(list_int(p,&inner,"Index",-1))}
        }
        return list_name(p,&inner,"Name"),layer,true
    }
    return list_name(p,list,"ParameterName"),{},true
}

// The input a property of o holds; ok is false when o has no such property.
prop_input :: proc(o:Object,name:string) -> (input:Input,ok:bool) {
    found:=property(o,name)
    if found==nil {return}
    return input_read(&o.pkg.p,found)
}

input_read :: proc(p:^unreal.Package,found:^unreal.Property) -> (input:Input,ok:bool) {
    if found.type_count<2 || unreal.name_plain(p,found.types[0].name)!="StructProperty" {return}
    kind:=unreal.name_plain(p,found.types[1].name)
    width:u8
    switch kind {
    case "ExpressionInput","MaterialAttributesInput":
    case "ColorMaterialInput":width=4
    case "ScalarMaterialInput","ShadingModelMaterialInput","SubstrateMaterialInput":width=1
    case "VectorMaterialInput":width=3
    case "Vector2MaterialInput":width=2
    case:return
    }
    core,_:=unreal.custom_version(p,unreal.CORE_OBJECT_VERSION)
    if core>=CORE_MATERIAL_INPUT_NATIVE {return input_native(p,found,kind,width)}
    list,error:=unreal.property_tagged_struct(p,found,true,context.temp_allocator)
    if error.code!=.None {return}
    input.expression=list_object(p,&list,"Expression")
    input.output=i32(list_float(p,&list,"OutputIndex",0))
    input.name=list_name(p,&list,"InputName")
    input_mask(&input,
        i32(list_float(p,&list,"Mask",0)),i32(list_float(p,&list,"MaskR",0)),i32(list_float(p,&list,"MaskG",0)),
        i32(list_float(p,&list,"MaskB",0)),i32(list_float(p,&list,"MaskA",0)))
    if width>0 {
        input.use_constant=list_bool(p,&list,"UseConstant",false)
        input.constant_width=width
        switch kind {
        case "ScalarMaterialInput":input.constant.x=list_float(p,&list,"Constant",0)
        case "Vector2MaterialInput":input.constant.xy={list_float(p,&list,"ConstantX",0),list_float(p,&list,"ConstantY",0)}
        case:input.constant=list_vector(p,&list,"Constant",{})
        }
    }
    return input,true
}

@(private)
input_mask :: proc(input:^Input,mask,r,g,b,a:i32) {
    input.masked=mask!=0
    input.channels={r!=0,g!=0,b!=0,a!=0}
}

@(private)
input_native :: proc(p:^unreal.Package,found:^unreal.Property,kind:string,width:u8) -> (input:Input,ok:bool) {
    bytes,error:=unreal.span_bytes(p,found.data)
    if error.code!=.None {return}
    at:=0
    word :: proc(bytes:[]u8,at:^int) -> (u32,bool) {
        if at^+4>len(bytes) {return 0,false}
        value,_:=endian.get_u32(bytes[at^:],.Little)
        at^+=4
        return value,true
    }
    reference,r_ok:=word(bytes,&at)
    output,o_ok:=word(bytes,&at)
    if !r_ok || !o_ok {return}
    input.expression=unreal.Object_Ref(transmute(i32)reference)
    input.output=transmute(i32)output
    framework,_:=unreal.custom_version(p,unreal.FRAMEWORK_OBJECT_VERSION)
    if framework>=FRAMEWORK_PINS_STORE_FNAME {
        index,i_ok:=word(bytes,&at)
        number,n_ok:=word(bytes,&at)
        if !i_ok || !n_ok {return}
        input.name=unreal.name_plain(p,{transmute(i32)index,transmute(i32)number})
    } else {
        count,c_ok:=word(bytes,&at)
        if !c_ok {return}
        length:=int(transmute(i32)count)
        // An ANSI text ends in its NUL; a UTF-16 one (negative length) is not a name an input has.
        if length>0 && at+length<=len(bytes) {input.name=string(bytes[at:at+length-1])}
        if length<0 {length= -length*2}
        at+=length
    }
    masks:[5]u32
    for &mask in masks {
        value,m_ok:=word(bytes,&at)
        if !m_ok {return}
        mask=value
    }
    input_mask(&input,i32(masks[0]),i32(masks[1]),i32(masks[2]),i32(masks[3]),i32(masks[4]))
    if width>0 {
        use,u_ok:=word(bytes,&at)
        if !u_ok {return}
        input.use_constant=use!=0
        input.constant_width=width
        fortnite,_:=unreal.custom_version(p,unreal.FORTNITE_MAIN_VERSION)
        switch {
        case kind=="ColorMaterialInput" && fortnite<FORTNITE_MATERIAL_INPUT_LINEAR_COLOR:
            if at+4>len(bytes) {return}
            input.constant={f32(bytes[at+2])/255,f32(bytes[at+1])/255,f32(bytes[at])/255,f32(bytes[at+3])/255}
            at+=4
        case kind=="ShadingModelMaterialInput" || kind=="SubstrateMaterialInput":
            at+=4
        case:
            count:=kind=="ColorMaterialInput"?4:int(width)
            for i in 0..<count {
                value,v_ok:=word(bytes,&at)
                if !v_ok {return}
                input.constant[i]=transmute(f32)value
            }
        }
    }
    if at!=len(bytes) || !unreal.reference_valid(p,input.expression) {return {},false}
    return input,true
}
