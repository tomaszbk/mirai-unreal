package unreal

import "core:mem"

properties_open :: proc(p:^Package,span:Span,root:=false,allocator:=context.allocator) -> (list:Property_List,error:Error) {
    if p==nil || !span_valid(p.bytes,span) {return {},{.Malformed,span.offset,"property range"}}
    start,end:=int(span.offset),int(span.offset+span.size)
    count:=0
    for pass in 0..<2 {
        r:=Reader{bytes=p.bytes,at=start,end=end}
        if root && p.summary.version_ue5>=1011 {
            control:=u8_read(&r,"object serialization control")
            list.serialization_control=control
            if control&~u8(2)!=0 {bad(&r,.Unsupported_Extension,"object serialization control")}
            if control&2!=0 {_=u8_read(&r,"object override operation")}
        }
        index:=0
        for r.error.code==.None {
            property,done:=property_read(&r,p)
            if r.error.code!=.None {break}
            if done {break}
            if index>=int(p.limits.property_count) {bad(&r,.Limit,"property count");break}
            if pass==1 {
                if index>=len(list.items) {bad(&r,.Malformed,"property count changed");break}
                list.items[index]=property
            }
            index+=1
        }
        if r.error.code!=.None {properties_destroy(&list);return {},r.error}
        if pass==0 {
            count=index
            allocation_error:mem.Allocator_Error
            list.items,allocation_error=make([]Property,count,allocator)
            list.allocator=allocator
            if allocation_error!=nil {return {},{.Out_Of_Memory,span.offset,"property table"}}
        } else if index!=count {
            properties_destroy(&list)
            return {},{.Malformed,span.offset,"property count changed"}
        }
        list.source={span.offset,i64(r.at-start)}
        list.trailing={i64(r.at),i64(end-r.at)}
    }
    return
}

export_properties :: proc(p:^Package,index:int,allow_object_start:=false,allocator:=context.allocator) -> (list:Property_List,error:Error) {
    if p==nil || index<0 || index>=len(p.exports) {return {},{.Invalid_Reference,0,"export index"}}
    item:=p.exports[index]
    if p.summary.version_ue5>=1010 {
        if item.script_end<=item.script_start {return {},{.Missing_Property_Range,item.data.offset,"export has no recorded script property range"}}
        // One store per value until odin-lang/Odin#7937 (see PENDIENTES_ODIN).
        opened,open_error:=properties_open(p,{item.data.offset+item.script_start,item.script_end-item.script_start},true,allocator)
        list=opened
        error=open_error
        if error.code==.None {
            if list.trailing.size!=0 {properties_destroy(&list);return {},{.Malformed,item.data.offset+item.script_start,"script property range has trailing bytes"}}
            list.trailing={item.data.offset+item.script_end,item.data.size-item.script_end}
        }
        return
    }
    if !allow_object_start {return {},{.Missing_Property_Range,item.data.offset,"older schema needs a class-specific object serialization layout"}}
    return properties_open(p,item.data,true,allocator)
}

properties_destroy :: proc(list:^Property_List) {
    if list==nil || list.allocator.procedure==nil {return}
    delete(list.items,list.allocator)
    list^={}
}

// Object appends its optional lazy GUID before a subclass's native data.
object_native_payload :: proc(p:^Package,tail:Span) -> (payload:Span,error:Error) {
    if p==nil || !span_valid(p.bytes,tail) {return {},{.Malformed,tail.offset,"UObject native range"}}
    r:=Reader{bytes=p.bytes,at=int(tail.offset),end=int(tail.offset+tail.size)}
    if bool_read(&r,"UObject has lazy guid") {_=guid_read(&r,"UObject lazy guid")}
    if r.error.code!=.None {return {},r.error}
    return {i64(r.at),i64(r.end-r.at)},{}
}

property_find :: proc(p:^Package,list:^Property_List,name:string) -> ^Property {
    if p==nil || list==nil {return nil}
    for &item in list.items {if item.name.number==0 && name_plain(p,item.name)==name {return &item}}
    return nil
}

@(private)
property_type_add :: proc(r:^Reader,property:^Property,name:Name_Ref,children:i32) {
    if property.type_count>=MAX_TYPE_NODES {bad(r,.Limit,"property type node count");return}
    property.types[int(property.type_count)]={name,children}
    property.type_count+=1
}

@(private)
property_extensions_read :: proc(r:^Reader,property:^Property) {
    flags:=u8_read(r,"property extension flags")
    property.extension_flags=flags
    if flags&~u8(6)!=0 {bad(r,.Unsupported_Extension,"property extension flags");return}
    if flags&2!=0 {
        property.override_operation=u8_read(r,"property override operation")
        property.experimental_override=bool_read(r,"property experimental override")
    }
    if flags&4!=0 {property.experimental_external_objects=bool_read(r,"property experimental external objects")}
}

@(private)
property_read :: proc(r:^Reader,p:^Package,consume:=true) -> (property:Property,done:bool) {
    start:=r.at
    property.name=name_read(r,p,"property name")
    if r.error.code!=.None {return}
    if name_plain(p,property.name)=="None" && property.name.number==0 {return {},true}
    size:i32
    if p.summary.version_ue5>=1012 {
        pending:=i64(1)
        for pending>0 && r.error.code==.None {
            name:=name_read(r,p,"complete property type name")
            children:=i32_read(r,"complete property type parameter count")
            if children<0 || children>MAX_TYPE_NODES || pending+i64(children)>MAX_TYPE_NODES {
                bad(r,.Limit,"complete property type parameter count")
                break
            }
            property_type_add(r,&property,name,children)
            pending+=i64(children)-1
        }
        size=i32_read(r,"property size")
        flags:=u8_read(r,"property flags")
        if flags&~u8(0x3f)!=0 {bad(r,.Unsupported_Extension,"property tag flags")}
        property.bool_value=flags&0x10!=0
        property.native=flags&8!=0
        property.skipped=flags&0x20!=0
        if flags&1!=0 {property.array_index=i32_read(r,"property array index")}
        if flags&2!=0 {property.has_property_guid=true;property.property_guid=guid_read(r,"property guid")}
        if flags&4!=0 {property_extensions_read(r,&property)}
    } else {
        property_type_add(r,&property,name_read(r,p,"property type"),0)
        size=i32_read(r,"property size")
        property.array_index=i32_read(r,"property array index")
        ue4:=p.summary.version_ue4
        kind:=name_plain(p,property.types[0].name)
        switch kind {
        case "StructProperty":
            property.types[0].children=1
            property_type_add(r,&property,name_read(r,p,"property struct name"),0)
            if ue4>=UE4_STRUCT_GUID_IN_PROPERTY_TAG {
                property.struct_guid=guid_read(r,"property struct guid")
                property.has_struct_guid=true
            }
        case "BoolProperty":
            value:=u8_read(r,"property boolean")
            if value>1 {bad(r,.Malformed,"property boolean")}
            property.bool_value=value==1
        case "ByteProperty","EnumProperty":
            property.types[0].children=1
            property_type_add(r,&property,name_read(r,p,"property enum name"),0)
        case "ArrayProperty":
            if ue4>=UE4_ARRAY_PROPERTY_INNER_TAGS {
                property.types[0].children=1
                property_type_add(r,&property,name_read(r,p,"property inner type"),0)
            }
        case "SetProperty":
            if ue4>=UE4_SET_MAP_PROPERTY_TAGS {
                property.types[0].children=1
                property_type_add(r,&property,name_read(r,p,"property inner type"),0)
            }
        case "MapProperty":
            if ue4>=UE4_SET_MAP_PROPERTY_TAGS {
                property.types[0].children=2
                property_type_add(r,&property,name_read(r,p,"property map key type"),0)
                property_type_add(r,&property,name_read(r,p,"property map value type"),0)
            }
        }
        if ue4>=UE4_PROPERTY_GUID_IN_PROPERTY_TAG {
            has_guid:=u8_read(r,"property has guid")
            if has_guid>1 {bad(r,.Malformed,"property has guid")}
            property.has_property_guid=has_guid==1
            if property.has_property_guid {property.property_guid=guid_read(r,"property guid")}
        }
        if p.summary.version_ue5>=1011 {property_extensions_read(r,&property)}
    }
    if size<0 || property.array_index<0 {bad(r,.Malformed,"property size or array index");return}
    property.data={i64(r.at),i64(size)}
    if consume {_=take(r,int(size),"property payload")} else if int(size)>r.end-r.at {bad(r,.Truncated,"property payload")}
    property.source={i64(start),i64(r.at-start)}
    return
}

property_value :: proc(p:^Package,property:^Property,allocator:=context.allocator) -> (value:Value,error:Error) {
    if p==nil || property==nil || property.type_count==0 || !span_valid(p.bytes,property.data) {return {},{.Malformed,0,"property value"}}
    if property.skipped {return {},{.Unsupported_Value,property.data.offset,"skipped property has no authored value"}}
    r:=Reader{bytes=p.bytes,at=int(property.data.offset),end=int(property.data.offset+property.data.size)}
    kind:=name_plain(p,property.types[0].name)
    value.allocator=allocator
    switch kind {
    case "BoolProperty":value.kind=.Boolean;value.boolean=property.bool_value
    case "Int8Property":value.kind=.Signed;value.signed=i64(transmute(i8)u8_read(&r,"int8 value"))
    case "Int16Property":value.kind=.Signed;value.signed=i64(transmute(i16)u16_read(&r,"int16 value"))
    case "IntProperty":value.kind=.Signed;value.signed=i64(i32_read(&r,"int32 value"))
    case "Int64Property":value.kind=.Signed;value.signed=i64_read(&r,"int64 value")
    case "UInt16Property":value.kind=.Unsigned;value.unsigned=u64(u16_read(&r,"uint16 value"))
    case "UInt32Property":value.kind=.Unsigned;value.unsigned=u64(u32_read(&r,"uint32 value"))
    case "UInt64Property":value.kind=.Unsigned;value.unsigned=transmute(u64)i64_read(&r,"uint64 value")
    case "FloatProperty":value.kind=.Real;value.real=f64(transmute(f32)u32_read(&r,"float32 value"))
    case "DoubleProperty":value.kind=.Real;value.real=transmute(f64)i64_read(&r,"float64 value")
    case "ByteProperty":
        if property.data.size==1 {value.kind=.Unsigned;value.unsigned=u64(u8_read(&r,"byte value"))} else {value.kind=.Name;value.name=name_read(&r,p,"enum name value")}
    case "NameProperty","EnumProperty":value.kind=.Name;value.name=name_read(&r,p,"name or enum value")
    case "ObjectProperty","ClassProperty":value.kind=.Object;value.object=reference_read(&r,p,"object value")
    case "StrProperty":
        text:=text_read(&r,p.limits.text_bytes,"string value")
        if r.error.code==.None {value.kind=.String;value.text,value.owned_text,error=text_decode(text,allocator)}
    // A Text: flags, the kind of its history and what it keeps;
    // its string is the one it shows in the source culture.
    case "TextProperty":
        _=u32_read(&r,"text flags")
        history:=transmute(i8)u8_read(&r,"text history")
        text:Serialized_String
        switch history {
        case -1: // None: a culture invariant string, when it has one
            if bool_read(&r,"text has invariant string") {text=text_read(&r,p.limits.text_bytes,"text invariant string")}
        case 0: // Base: namespace, key and the source string
            _=text_read(&r,p.limits.text_bytes,"text namespace")
            _=text_read(&r,p.limits.text_bytes,"text key")
            text=text_read(&r,p.limits.text_bytes,"text source string")
        case:
            return {},{.Unsupported_Value,property.data.offset,"text history other than none or base"}
        }
        if r.error.code==.None {value.kind=.String;value.text,value.owned_text,error=text_decode(text,allocator)}
    case "StructProperty":
        if property.type_count<2 {return {},{.Unsupported_Value,property.data.offset,"struct type is unavailable"}}
        struct_name:=name_plain(p,property.types[1].name)
        components:=0
        wide:=false
        switch struct_name {
        case "Vector":components=3;wide=p.summary.version_ue5>=1004
        case "Vector3d":components=3;wide=true
        case "Vector3f":components=3
        case "Vector2D":components=2;wide=p.summary.version_ue5>=1004
        case "Vector2d":components=2;wide=true
        case "Vector2f":components=2
        case "Vector4","Quat":components=4;wide=p.summary.version_ue5>=1004
        case "Vector4d","Quat4d":components=4;wide=true
        case "Vector4f","Quat4f","LinearColor":components=4
        case "Rotator":components=3;wide=p.summary.version_ue5>=1004
        case "Rotator3d":components=3;wide=true
        case "Rotator3f":components=3
        }
        if struct_name=="Guid" {
            value.kind=.Guid
            value.guid=guid_read(&r,"guid value")
        } else {
            if components==0 {return {},{.Unsupported_Value,property.data.offset,"struct requires its serialization schema"}}
            value.kind=.Real_Vector
            value.vector_count=u8(components)
            for i in 0..<components {
                value.vector[i]=wide?(transmute(f64)i64_read(&r,"vector component")):f64(transmute(f32)u32_read(&r,"vector component"))
            }
        }
    case:
        return {},{.Unsupported_Value,property.data.offset,"property requires a container, enum, text, native or struct schema"}
    }
    if error.code!=.None {value_destroy(&value);return {},error}
    if r.error.code!=.None {value_destroy(&value);return {},r.error}
    if r.at!=r.end {value_destroy(&value);return {},{.Malformed,i64(r.at),"typed value does not consume its payload"}}
    return
}

value_destroy :: proc(value:^Value) {
    if value==nil || value.allocator.procedure==nil {return}
    delete(value.owned_text,value.allocator)
    value^={}
}
