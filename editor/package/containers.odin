package unreal

import "core:mem"

Array_View :: struct {
    count:u32,
    element:Property,
    data:Span,
    native:bool,
    layout_recorded:bool,
}

Struct_Array :: struct {
    items:[]Property_List,
    allocator:mem.Allocator,
}

property_tagged_struct :: proc(p:^Package,property:^Property,allow_older_tagged_schema:=false,allocator:=context.allocator) -> (list:Property_List,error:Error) {
    if p==nil || property==nil || property.type_count<2 || !span_valid(p.bytes,property.data) {return {},{.Malformed,0,"struct property"}}
    if name_plain(p,property.types[0].name)!="StructProperty" || property.native || property.skipped || p.summary.version_ue5<1012 && !allow_older_tagged_schema {
        return {},{.Unsupported_Value,property.data.offset,"struct needs a known tagged schema; native layouts cannot be guessed"}
    }
    // One store per value until odin-lang/Odin#7937 (see PENDIENTES_ODIN).
    opened,open_error:=properties_open(p,property.data,false,allocator)
    list=opened
    error=open_error
    if error.code==.None && list.trailing.size!=0 {
        properties_destroy(&list)
        return {},{.Malformed,property.data.offset,"tagged struct has trailing bytes"}
    }
    return
}

property_array :: proc(p:^Package,property:^Property) -> (view:Array_View,error:Error) {
    if p==nil || property==nil || property.type_count<2 || property.type_count>MAX_TYPE_NODES || !span_valid(p.bytes,property.data) {return {},{.Malformed,0,"array property"}}
    if name_plain(p,property.types[0].name)!="ArrayProperty" {return {},{.Unsupported_Value,property.data.offset,"expected an ArrayProperty"}}
    if property.skipped || property.experimental_override || property.experimental_external_objects {return {},{.Unsupported_Value,property.data.offset,"array uses skipped, override or external-object serialization"}}
    r:=Reader{bytes=p.bytes,at=int(property.data.offset),end=int(property.data.offset+property.data.size)}
    count:=i32_read(&r,"array element count")
    if count<0 || u32(count)>p.limits.table_entries {return {},{.Limit,property.data.offset,"array element count"}}
    view.count=u32(count)
    view.element.name=property.name
    pending:=i64(1)
    for index:=1;pending>0;index+=1 {
        if index>=int(property.type_count) {return {},{.Malformed,property.data.offset,"array element type tree"}}
        node:=property.types[index]
        if node.children<0 || node.children>MAX_TYPE_NODES || pending+i64(node.children)>MAX_TYPE_NODES {return {},{.Malformed,property.data.offset,"array element type tree"}}
        view.element.types[int(view.element.type_count)]=node
        view.element.type_count+=1
        pending+=i64(node.children)-1
    }
    kind:=name_plain(p,view.element.types[0].name)
    if p.summary.version_ue5<1012 && p.summary.version_ue4>=UE4_INNER_ARRAY_TAG_INFO && kind=="StructProperty" {
        inner,done:=property_read(&r,p,false)
        if done || r.error.code!=.None {return {},r.error.code==.None?Error{.Malformed,i64(r.at),"array struct tag"}:r.error}
        if name_plain(p,inner.types[0].name)!="StructProperty" {return {},{.Malformed,i64(r.at),"array struct tag type"}}
        view.element=inner
    }
    if r.error.code!=.None {return {},r.error}
    view.native=property.native
    view.layout_recorded=p.summary.version_ue5>=1012
    view.data={i64(r.at),i64(r.end-r.at)}
    return
}

array_object_refs :: proc(p:^Package,view:Array_View,allocator:=context.allocator) -> (references:[]Object_Ref,error:Error) {
    if p==nil || !span_valid(p.bytes,view.data) || view.element.type_count==0 {return nil,{.Malformed,view.data.offset,"object array"}}
    kind:=name_plain(p,view.element.types[0].name)
    if kind!="ObjectProperty" && kind!="ClassProperty" {return nil,{.Unsupported_Value,view.data.offset,"array element is not an object reference"}}
    if i64(view.count)*4!=view.data.size {return nil,{.Malformed,view.data.offset,"object reference array size"}}
    allocation_error:mem.Allocator_Error
    references,allocation_error=make([]Object_Ref,int(view.count),allocator)
    if allocation_error!=nil {return nil,{.Out_Of_Memory,view.data.offset,"object reference array"}}
    r:=Reader{bytes=p.bytes,at=int(view.data.offset),end=int(view.data.offset+view.data.size)}
    for &reference in references {reference=reference_read(&r,p,"array object reference")}
    if r.error.code!=.None {delete(references,allocator);return nil,r.error}
    return
}

// Names, or enums that arrays keep by name (ByteProperty and EnumProperty elements of 8 bytes).
array_names :: proc(p:^Package,view:Array_View,allocator:=context.allocator) -> (names:[]Name_Ref,error:Error) {
    if p==nil || !span_valid(p.bytes,view.data) || view.element.type_count==0 {return nil,{.Malformed,view.data.offset,"name array"}}
    kind:=name_plain(p,view.element.types[0].name)
    if kind!="NameProperty" && kind!="EnumProperty" && kind!="ByteProperty" {return nil,{.Unsupported_Value,view.data.offset,"array element is not a name"}}
    if i64(view.count)*8!=view.data.size {return nil,{.Malformed,view.data.offset,"name array byte size"}}
    allocation_error:mem.Allocator_Error
    names,allocation_error=make([]Name_Ref,int(view.count),allocator)
    if allocation_error!=nil {return nil,{.Out_Of_Memory,view.data.offset,"name array"}}
    r:=Reader{bytes=p.bytes,at=int(view.data.offset),end=int(view.data.offset+view.data.size)}
    for &name in names {name=name_read(&r,p,"array name reference")}
    if r.error.code!=.None {delete(names,allocator);return nil,r.error}
    return
}

array_tagged_structs :: proc(p:^Package,view:Array_View,allow_older_tagged_schema:=false,allocator:=context.allocator) -> (array:Struct_Array,error:Error) {
    if p==nil || !span_valid(p.bytes,view.data) || view.element.type_count==0 {return {},{.Malformed,view.data.offset,"struct array"}}
    if name_plain(p,view.element.types[0].name)!="StructProperty" || view.native || !view.layout_recorded && !allow_older_tagged_schema {
        return {},{.Unsupported_Value,view.data.offset,"array needs a known tagged-struct schema; native layouts cannot be guessed"}
    }
    if i64(view.count)*8>view.data.size {return {},{.Malformed,view.data.offset,"tagged struct array count"}}
    array.allocator=allocator
    allocation_error:mem.Allocator_Error
    array.items,allocation_error=make([]Property_List,int(view.count),allocator)
    if allocation_error!=nil {return {},{.Out_Of_Memory,view.data.offset,"tagged struct array"}}
    at,end:=view.data.offset,view.data.offset+view.data.size
    for &item in array.items {
        // One store per value until odin-lang/Odin#7937 (see PENDIENTES_ODIN).
        opened,open_error:=properties_open(p,{at,end-at},false,allocator)
        item=opened
        error=open_error
        if error.code!=.None {struct_array_destroy(&array);return {},error}
        at+=item.source.size
        item.trailing={}
    }
    if at!=end {struct_array_destroy(&array);return {},{.Malformed,at,"tagged struct array has trailing bytes"}}
    return
}

struct_array_destroy :: proc(array:^Struct_Array) {
    if array==nil || array.allocator.procedure==nil {return}
    for &item in array.items {properties_destroy(&item)}
    delete(array.items,array.allocator)
    array^={}
}
