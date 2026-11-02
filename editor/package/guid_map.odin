package unreal

import "core:mem"
import "core:slice"

Guid_Pair :: struct {key,value:Guid,source:Span}
Guid_Map :: struct {removed:[]Guid,items:[]Guid_Pair,replace:bool,allocator:mem.Allocator}

property_guid_map :: proc(p:^Package,property:^Property,allow_older_guid_schema:=false,allocator:=context.allocator) -> (mapping:Guid_Map,error:Error) {
    if p==nil || property==nil || property.type_count<3 || property.type_count>MAX_TYPE_NODES || !span_valid(p.bytes,property.data) {return {},{.Malformed,0,"GUID mapping property"}}
    if name_plain(p,property.types[0].name)!="MapProperty" || property.skipped || property.experimental_override || property.experimental_external_objects {return {},{.Unsupported_Value,property.data.offset,"GUID mapping requires ordinary mapping serialization"}}
    if p.summary.version_ue5>=1012 {
        valid:=property.type_count==7 && property.types[0].children==2
        for index in ([2]int{1,4}) {
            valid=valid && property.types[index].children==1 && name_plain(p,property.types[index].name)=="StructProperty" && property.types[index+1].children==1 && name_plain(p,property.types[index+1].name)=="Guid" && property.types[index+2].children==0 && name_plain(p,property.types[index+2].name)=="/Script/CoreUObject"
        }
        for type in property.types[:property.type_count] {valid=valid && type.name.number==0}
        if !valid {return {},{.Unsupported_Value,property.data.offset,"GUID mapping key and value type identities"}}
    } else if !allow_older_guid_schema || name_plain(p,property.types[1].name)!="StructProperty" || name_plain(p,property.types[2].name)!="StructProperty" {return {},{.Unsupported_Value,property.data.offset,"older mapping requires an explicit GUID key/value schema"}}
    r:=Reader{bytes=p.bytes,at=int(property.data.offset),end=int(property.data.offset+property.data.size)}
    removed:=i32_read(&r,"mapping removed key count")
    if removed< -1 || removed>0 && (u32(removed)>p.limits.table_entries || i64(removed)*16>i64(r.end-r.at)) {return {},{.Limit,property.data.offset,"mapping removed key count"}}
    mapping.allocator,mapping.replace=allocator,removed== -1
    allocation_error:mem.Allocator_Error
    mapping.removed,allocation_error=make([]Guid,int(max(removed,0)),allocator)
    if allocation_error!=nil {return {},{.Out_Of_Memory,property.data.offset,"mapping removed GUIDs"}}
    for &key in mapping.removed {key=guid_read(&r,"mapping removed GUID")}
    count:=i32_read(&r,"mapping entry count")
    if r.error.code!=.None {guid_map_destroy(&mapping);return {},r.error}
    if count<0 || u32(count)>p.limits.table_entries || i64(count)*32!=i64(r.end-r.at) {guid_map_destroy(&mapping);return {},{.Malformed,i64(r.at),"GUID mapping entry count and byte size"}}
    mapping.items,allocation_error=make([]Guid_Pair,int(count),allocator)
    if allocation_error!=nil {guid_map_destroy(&mapping);return {},{.Out_Of_Memory,i64(r.at),"mapping GUID entries"}}
    for &pair in mapping.items {pair.source={i64(r.at),32};pair.key=guid_read(&r,"mapping GUID key");pair.value=guid_read(&r,"mapping GUID value")}
    if r.error.code!=.None {guid_map_destroy(&mapping);return {},r.error}
    slice.sort_by(mapping.items,proc(a,b:Guid_Pair)->bool {return guid_less(a.key,b.key)})
    for item,i in mapping.items {if i>0 && item.key==mapping.items[i-1].key {guid_map_destroy(&mapping);return {},{.Malformed,item.source.offset,"duplicate mapping GUID key"}}}
    return
}

guid_map_destroy :: proc(mapping:^Guid_Map) {
    if mapping==nil || mapping.allocator.procedure==nil {return}
    delete(mapping.removed,mapping.allocator);delete(mapping.items,mapping.allocator)
    mapping^={}
}

guid_from_words :: proc(words:[4]u32) -> (guid:Guid) {
    for word,i in words {for byte in 0..<4 {guid[i*4+byte]=u8(word>>u32(byte*8))}}
    return
}

custom_version :: proc(p:^Package,words:[4]u32) -> (version:i32,found:bool) {
    if p==nil {return -1,false}
    guid:=guid_from_words(words)
    for item in p.custom_versions {if item.guid==guid {return item.version,true}}
    return -1,false
}

// The custom versions that more than one reader asks for.
CORE_OBJECT_VERSION :: [4]u32{0x375ec13c,0x06e448fb,0xb50084f0,0x262a717e}
FRAMEWORK_OBJECT_VERSION :: [4]u32{0xcffc743f,0x43b04480,0x939114df,0x171d2073}
RELEASE_OBJECT_VERSION :: [4]u32{0x9c54d522,0xa8264fbe,0x94210746,0x61b482d0}
UE5_MAIN_STREAM_VERSION :: [4]u32{0x697dd581,0xe64f41ab,0xaa4a51ec,0xbeb7b628}
FORTNITE_MAIN_VERSION :: [4]u32{0x601d1886,0xac644f84,0xaa16d3de,0x0deac7d6}
UE5_SPECIAL_PROJECT_VERSION :: [4]u32{0x59da5d52,0x12324948,0xb8785978,0x70b8e98b}

@(private)
guid_less :: proc(a,b:Guid) -> bool {
    for byte,i in a {if byte!=b[i] {return byte<b[i]}}
    return false
}
