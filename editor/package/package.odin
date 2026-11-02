package unreal

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

package_open :: proc(bytes:[]u8,allocator:=context.allocator,limits:=DEFAULT_LIMITS,source_package:="") -> (p:Package,error:Error) {
    if source_package!="" && !long_package_name_valid(source_package) {return {},{.Invalid_Reference,0,"explicit source package identity"}}
    p={bytes=bytes,source_package=source_package,allocator=allocator,limits=limits}
    r:=Reader{bytes=bytes,end=len(bytes)}
    // One store per value until odin-lang/Odin#7937 (see PENDIENTES_ODIN).
    summary,text:=summary_read(&r,limits)
    p.summary=summary
    if r.error.code!=.None {return {},r.error}
    p.summary.stored_package_name,p.owned_package_name,error=text_decode(text,allocator)
    if error.code!=.None {package_destroy(&p);return {},error}
    allocation_error:mem.Allocator_Error
    p.names,allocation_error=make([]Name,int(p.summary.name_count),allocator)
    if allocation_error!=nil {package_destroy(&p);return {},{.Out_Of_Memory,0,"name table"}}
    p.imports,allocation_error=make([]Object_Import,int(p.summary.import_count),allocator)
    if allocation_error!=nil {package_destroy(&p);return {},{.Out_Of_Memory,0,"import table"}}
    p.exports,allocation_error=make([]Object_Export,int(p.summary.export_count),allocator)
    if allocation_error!=nil {package_destroy(&p);return {},{.Out_Of_Memory,0,"export table"}}
    p.custom_versions,allocation_error=make([]Custom_Version,int(p.summary.custom_version_count),allocator)
    if allocation_error!=nil {package_destroy(&p);return {},{.Out_Of_Memory,0,"custom versions"}}
    r={bytes=bytes,at=int(p.summary.custom_versions.offset),end=int(p.summary.custom_versions.offset+p.summary.custom_versions.size)}
    for &version in p.custom_versions {
        version.guid=guid_read(&r,"custom version guid")
        version.version=i32_read(&r,"custom version value")
        if p.summary.custom_versions_named {_=text_read(&r,limits.text_bytes,"custom version name")}
    }
    spans:[3]Span
    spans[0],error=names_read(&p)
    if error.code==.None {spans[1],error=imports_read(&p)}
    if error.code==.None {spans[2],error=exports_read(&p)}
    if error.code==.None {
        for a,i in spans {
            if a.size==0 {continue}
            for b in spans[:i] {
                if b.size>0 && a.offset<b.offset+b.size && b.offset<a.offset+a.size {
                    error={.Malformed,a.offset,"overlapping package tables"}
                    break
                }
            }
        }
    }
    if error.code==.None {error=export_ranges_check(&p)}
    if error.code==.None {error=outer_chains_check(&p)}
    if error.code!=.None {package_destroy(&p);return {},error}
    return
}

package_destroy :: proc(p:^Package) {
    if p==nil || p.allocator.procedure==nil {return}
    for name in p.names {delete(name.owned_text,p.allocator)}
    delete(p.owned_package_name,p.allocator)
    delete(p.names,p.allocator)
    delete(p.imports,p.allocator)
    delete(p.exports,p.allocator)
    delete(p.custom_versions,p.allocator)
    p^={}
}

name_valid :: proc(p:^Package,name:Name_Ref) -> bool {
    return p!=nil && name.index>=0 && int(name.index)<len(p.names) && name.number>=0
}

name_plain :: proc(p:^Package,name:Name_Ref) -> string {
    return name_valid(p,name)?p.names[int(name.index)].text:""
}

// A name with its number, as Unreal prints it ("Layer_2"), in allocator.
name_text :: proc(p:^Package,name:Name_Ref,allocator:=context.allocator) -> string {
    plain:=name_plain(p,name)
    if name.number<=0 {return strings.clone(plain,allocator)}
    return fmt.aprintf("%s_%d",plain,name.number-1,allocator=allocator)
}

names_equal :: proc(a:^Package,a_name:Name_Ref,b:^Package,b_name:Name_Ref) -> bool {
    return name_valid(a,a_name) && name_valid(b,b_name) && a_name.number==b_name.number && strings.equal_fold(name_plain(a,a_name),name_plain(b,b_name))
}

reference_valid :: proc(p:^Package,reference:Object_Ref) -> bool {
    if p==nil {return false}
    index:=i64(reference)
    return index>= -i64(len(p.imports)) && index<=i64(len(p.exports))
}

reference_name :: proc(p:^Package,reference:Object_Ref) -> (name:Name_Ref,ok:bool) {
    if !reference_valid(p,reference) || reference==0 {return {},false}
    if reference<0 {return p.imports[int(-i64(reference)-1)].object_name,true}
    return p.exports[int(reference)-1].object_name,true
}

reference_outer :: proc(p:^Package,reference:Object_Ref) -> (outer:Object_Ref,ok:bool) {
    if !reference_valid(p,reference) || reference==0 {return 0,false}
    if reference<0 {return p.imports[int(-i64(reference)-1)].outer,true}
    return p.exports[int(reference)-1].outer,true
}

reference_in_package :: proc(p:^Package,reference:Object_Ref,package_name,object_name:string) -> bool {
    if reference>=0 || !reference_valid(p,reference) {return false}
    item:=p.imports[int(-i64(reference)-1)]
    if item.object_name.number!=0 || !strings.equal_fold(name_plain(p,item.object_name),object_name) {return false}
    if item.outer==0 {return item.package_name.number==0 && strings.equal_fold(name_plain(p,item.package_name),package_name)}
    if item.outer>=0 || !reference_valid(p,item.outer) {return false}
    outer:=p.imports[int(-i64(item.outer)-1)]
    return outer.outer==0 && outer.object_name.number==0 && strings.equal_fold(name_plain(p,outer.object_name),package_name)
}

reference_path :: proc(p:^Package,reference:Object_Ref,allocator:=context.allocator) -> (path:string,error:Error) {
    if !reference_valid(p,reference) {return "",{.Invalid_Reference,0,"object path"}}
    if reference==0 {return "",{}}
    chain:[256]Name_Ref
    depth:=0
    root_reference:=reference
    current:=reference
    for current!=0 {
        if depth>=len(chain) {return "",{.Limit,0,"object path outer depth"}}
        name,valid:=reference_name(p,current)
        if !valid {return "",{.Invalid_Reference,0,"object path name"}}
        chain[depth]=name
        depth+=1
        root_reference=current
        current,_=reference_outer(p,current)
    }
    prefix:=""
    if root_reference>0 {
        if p.source_package=="" {return "",{.Invalid_Reference,0,"export paths require an explicit source package mount identity"}}
        prefix=p.source_package
    }
    if root_reference<0 && len(name_plain(p,chain[depth-1]))>0 && name_plain(p,chain[depth-1])[0]!='/' {
        owner:=p.imports[int(-i64(root_reference)-1)].package_name
        if p.summary.version_ue4>=UE4_NON_OUTER_PACKAGE_IMPORT && name_plain(p,owner)!="None" && owner.number==0 {prefix=name_plain(p,owner)}
        if prefix=="" {return "",{.Unsupported_Value,0,"import path has no package root"}}
    }
    size:=len(prefix)
    if prefix!="" {size+=1}
    for index in 0..<depth {
        name:=chain[index]
        size+=len(name_plain(p,name))
        if name.number>0 {size+=1+decimal_digits(u32(name.number-1))}
        if index>0 {size+=1}
    }
    bytes,allocation_error:=make([]u8,size,allocator)
    if allocation_error!=nil {return "",{.Out_Of_Memory,0,"object path"}}
    written:=copy(bytes,transmute([]u8)prefix)
    if prefix!="" {bytes[written]='.';written+=1}
    for index:=depth-1;index>=0;index-=1 {
        if index!=depth-1 {
            first_child:=index==depth-2
            bytes[written]=first_child && prefix!=""?':':'.'
            if prefix=="" && index==depth-3 {bytes[written]=':'}
            written+=1
        }
        name:=chain[index]
        text:=name_plain(p,name)
        written+=copy(bytes[written:],transmute([]u8)text)
        if name.number>0 {
            bytes[written]='_';written+=1
            number:=u32(name.number-1)
            digits:=decimal_digits(number)
            for digit in 0..<digits {
                bytes[written+digits-digit-1]=u8(number%10)+'0'
                number/=10
            }
            written+=digits
        }
    }
    return string(bytes),{}
}

@(private)
decimal_digits :: proc(value:u32) -> int {
    count:=1
    remaining:=value
    for remaining>=10 {remaining/=10;count+=1}
    return count
}

@(private)
name_read :: proc(r:^Reader,p:^Package,field:string) -> (name:Name_Ref) {
    name={i32_read(r,field),i32_read(r,field)}
    if !name_valid(p,name) {bad(r,.Invalid_Reference,field)}
    return
}

@(private)
reference_read :: proc(r:^Reader,p:^Package,field:string) -> Object_Ref {
    reference:=Object_Ref(i32_read(r,field))
    if !reference_valid(p,reference) {bad(r,.Invalid_Reference,field)}
    return reference
}

@(private)
names_read :: proc(p:^Package) -> (span:Span,error:Error) {
    start:=int(p.summary.name_offset)
    r:=Reader{bytes=p.bytes,at=start,end=int(p.summary.total_header_size)}
    for &name in p.names {
        text:=text_read(&r,p.limits.text_bytes,"name table FString")
        if r.error.code!=.None {return {},r.error}
        name.text,name.owned_text,error=text_decode(text,p.allocator)
        if error.code!=.None {return {},error}
        name.source=text.source
        if p.summary.version_ue4>=UE4_NAME_HASHES {
            name.non_case_hash=u16_read(&r,"name case-insensitive hash")
            name.case_hash=u16_read(&r,"name case-sensitive hash")
        }
    }
    return {i64(start),i64(r.at-start)},r.error
}

@(private)
imports_read :: proc(p:^Package) -> (span:Span,error:Error) {
    start:=int(p.summary.import_offset)
    r:=Reader{bytes=p.bytes,at=start,end=int(p.summary.total_header_size)}
    for &item in p.imports {
        at:=r.at
        item.class_package=name_read(&r,p,"import class package")
        item.class_name=name_read(&r,p,"import class name")
        item.outer=reference_read(&r,p,"import outer")
        item.object_name=name_read(&r,p,"import object name")
        if p.summary.version_ue4>=UE4_NON_OUTER_PACKAGE_IMPORT {item.package_name=name_read(&r,p,"import package name")}
        if p.summary.version_ue5>=1003 {item.optional=bool_read(&r,"import optional")}
        item.source={i64(at),i64(r.at-at)}
    }
    return {i64(start),i64(r.at-start)},r.error
}

@(private)
exports_read :: proc(p:^Package) -> (span:Span,error:Error) {
    start:=int(p.summary.export_offset)
    r:=Reader{bytes=p.bytes,at=start,end=int(p.summary.total_header_size)}
    version,ue4:=p.summary.version_ue5,p.summary.version_ue4
    for &item in p.exports {
        at:=r.at
        item.class=reference_read(&r,p,"export class")
        item.super=reference_read(&r,p,"export super")
        if ue4>=UE4_TEMPLATE_INDEX {item.template=reference_read(&r,p,"export template")}
        item.outer=reference_read(&r,p,"export outer")
        item.object_name=name_read(&r,p,"export object name")
        item.object_flags=u32_read(&r,"export object flags")
        if ue4>=UE4_64BIT_EXPORT_SIZES {
            item.data.size=i64_read(&r,"export serial size")
            item.data.offset=i64_read(&r,"export serial offset")
        } else {
            item.data.size=i64(i32_read(&r,"export serial size"))
            item.data.offset=i64(i32_read(&r,"export serial offset"))
        }
        item.forced=bool_read(&r,"export forced")
        item.not_for_client=bool_read(&r,"export not for client")
        item.not_for_server=bool_read(&r,"export not for server")
        if version<1005 {_=guid_read(&r,"export package guid")}
        if version>=1006 {item.inherited=bool_read(&r,"export inherited")}
        item.package_flags=u32_read(&r,"export package flags")
        if ue4>=UE4_LOAD_FOR_EDITOR_GAME {item.not_always_loaded_for_editor_game=bool_read(&r,"export not always loaded for editor game")}
        if ue4>=UE4_COOKED_ASSETS_IN_EDITOR {item.is_asset=bool_read(&r,"export is asset")}
        if version>=1003 {item.generate_public_hash=bool_read(&r,"export generate public hash")}
        if ue4>=UE4_PRELOAD_DEPENDENCIES {_=take(&r,20,"export preload dependencies")}
        if version>=1010 {
            item.script_start=i64_read(&r,"export script serialization start")
            item.script_end=i64_read(&r,"export script serialization end")
        }
        item.source={i64(at),i64(r.at-at)}
        if r.error.code!=.None {return {},r.error}
        if !span_valid(p.bytes,item.data) || item.data.size>0 && item.data.offset<i64(p.summary.total_header_size) {
            return {},{.Malformed,i64(at),"export serial range"}
        }
        if item.script_start<0 || item.script_end<item.script_start || item.script_end>item.data.size {
            return {},{.Malformed,i64(at),"export script serialization range"}
        }
    }
    return {i64(start),i64(r.at-start)},r.error
}

@(private)
export_ranges_check :: proc(p:^Package) -> Error {
    ranges,allocation_error:=make([]Span,len(p.exports),p.allocator)
    if allocation_error!=nil {return {.Out_Of_Memory,0,"export serial range validation"}}
    defer delete(ranges,p.allocator)
    count:=0
    for item in p.exports {
        if item.data.size==0 {continue}
        ranges[count]=item.data
        count+=1
    }
    slice.sort_by(ranges[:count],proc(a,b:Span) -> bool {return a.offset<b.offset})
    for index in 1..<count {
        previous,current:=ranges[index-1],ranges[index]
        if current.offset<previous.offset+previous.size {return {.Malformed,current.offset,"overlapping export serial ranges"}}
    }
    return {}
}

@(private)
outer_chains_check :: proc(p:^Package) -> Error {
    count:=len(p.imports)+len(p.exports)
    for index in -len(p.imports)..=len(p.exports) {
        reference:=Object_Ref(index)
        for depth:=0;reference!=0;depth+=1 {
            if depth>count {return {.Cyclic_Outer,0,"object outer chain"}}
            if depth>int(p.limits.outer_depth) {return {.Limit,0,"object outer depth"}}
            next,ok:=reference_outer(p,reference)
            if !ok {return {.Invalid_Reference,0,"object outer chain"}}
            if next==Object_Ref(index) {return {.Cyclic_Outer,0,"object outer chain"}}
            reference=next
        }
    }
    return {}
}
