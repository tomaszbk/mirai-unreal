package unreal

import "core:strings"

// A soft object path of the table of the package: the package and asset of
// its top level object, and the path below it ("PersistentLevel.Actor_2").
Soft_Path :: struct {package_name,asset_name:Name_Ref,sub_path:string}

// The soft object path at index of the table, read from the package bytes.
soft_path :: proc(p:^Package,index:int,allocator:=context.temp_allocator) -> (path:Soft_Path,error:Error) {
    if p==nil || index<0 || index>=int(p.summary.soft_path_count) || p.summary.soft_path_offset<=0 {return {},{.Invalid_Reference,0,"soft object path index"}}
    r:=Reader{bytes=p.bytes,at=int(p.summary.soft_path_offset),end=len(p.bytes)}
    for i in 0..=index {
        path.package_name={i32_read(&r,"soft path package"),i32_read(&r,"soft path package number")}
        path.asset_name={i32_read(&r,"soft path asset"),i32_read(&r,"soft path asset number")}
        // The sub path: UTF-8 bytes after their count, without a terminator.
        count:=i32_read(&r,"soft path sub path length")
        if count<0 || u32(count)>p.limits.text_bytes {bad(&r,.Limit,"soft path sub path length")}
        bytes:=take(&r,int(max(count,0)),"soft path sub path")
        if r.error.code!=.None {return {},r.error}
        if i==index {path.sub_path=strings.clone(string(bytes),allocator)}
    }
    return
}

// The soft object path a SoftObjectProperty names, as Unreal prints it: /Game/Map.Map:PersistentLevel.Actor.
soft_path_property :: proc(p:^Package,property:^Property,allocator:=context.temp_allocator) -> (text:string,error:Error) {
    if p==nil || property==nil || !span_valid(p.bytes,property.data) || property.data.size<4 {return "",{.Malformed,0,"soft object property"}}
    index:=int((^i32le)(&p.bytes[property.data.offset])^)
    path,path_error:=soft_path(p,index,allocator)
    if path_error.code!=.None {return "",path_error}
    b:=strings.builder_make(allocator)
    strings.write_string(&b,name_plain(p,path.package_name))
    strings.write_byte(&b,'.')
    strings.write_string(&b,name_plain(p,path.asset_name))
    if path.sub_path!="" {
        strings.write_byte(&b,':')
        strings.write_string(&b,path.sub_path)
    }
    return strings.to_string(b),{}
}
