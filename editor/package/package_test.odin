package unreal

import "base:runtime"
import "core:mem"
import "core:testing"

@(private)
Fixture_Writer :: struct {bytes:[]u8,at:int}

@(private)
put_u32 :: proc(w:^Fixture_Writer,value:u32) {
    for i in 0..<4 {w.bytes[w.at+i]=u8(value>>u32(i*8))}
    w.at+=4
}

@(private)
put_u64 :: proc(w:^Fixture_Writer,value:u64) {put_u32(w,u32(value));put_u32(w,u32(value>>32))}

@(private)
put_text :: proc(w:^Fixture_Writer,value:string) {
    put_u32(w,u32(len(value)+1))
    copy(w.bytes[w.at:],transmute([]u8)value)
    w.at+=len(value)+1
}

@(private)
patch_u32 :: proc(w:^Fixture_Writer,offset:int,value:u32) {
    at:=w.at
    w.at=offset
    put_u32(w,value)
    w.at=at
}

@(private)
put_name :: proc(w:^Fixture_Writer,index:u32) {put_u32(w,index);put_u32(w,0)}

@(private)
fixture_package :: proc(version:u32,wide_name:=false,tail:[]u8=nil) -> []u8 {
    w:=Fixture_Writer{bytes=make([]u8,4096,context.temp_allocator)}
    put_u32(&w,0x9e2a83c1)
    put_u32(&w,transmute(u32)i32(version>=1016?-9:version==0?-7:-8))
    put_u32(&w,864);put_u32(&w,522)
    if version!=0 {put_u32(&w,version)}
    put_u32(&w,0)
    header_patch:=0
    if version>=1016 {w.at+=20;header_patch=w.at;put_u32(&w,0)}
    put_u32(&w,0)
    if version<1016 {header_patch=w.at;put_u32(&w,0)}
    put_text(&w,"/Game/Fixture")
    put_u32(&w,0)
    names:=[15]string{"None","/Game/Fixture","Fixture","/Script/Niagara","Class","NiagaraSystem","Count","IntProperty","Title","StrProperty","Position","StructProperty","Vector","/Script/CoreUObject","Package"}
    put_u32(&w,u32(len(names)))
    name_patch:=w.at;put_u32(&w,0)
    if version>=1008 {w.at+=8}
    put_u32(&w,0);w.at+=8
    put_u32(&w,1);export_patch:=w.at;put_u32(&w,0)
    put_u32(&w,2);import_patch:=w.at;put_u32(&w,0)
    if version>=1015 {w.at+=16}
    if version>=1014 {w.at+=4}
    w.at+=20
    if version>=1018 {w.at+=8}
    if version<1016 {w.at+=16}
    w.at+=16
    put_u32(&w,0)
    for _ in 0..<2 {w.at+=10;put_u32(&w,0)}
    w.at+=12
    put_u32(&w,0)
    w.at+=16
    put_u32(&w,0)
    w.at+=8
    if version>=1001 {put_u32(&w,u32(len(names)))}
    if version>=1002 {w.at+=8}
    if version>=1009 {w.at+=4}
    patch_u32(&w,name_patch,u32(w.at))
    for name in names {
        if wide_name && name=="Fixture" {
            put_u32(&w,transmute(u32)i32(-len(name)-1))
            for byte,index in transmute([]u8)name {w.bytes[w.at+index*2]=byte}
            w.at+=(len(name)+1)*2
        } else {put_text(&w,name)}
        w.at+=4
    }
    patch_u32(&w,import_patch,u32(w.at))
    put_name(&w,13);put_name(&w,14);put_u32(&w,0);put_name(&w,3);put_name(&w,0)
    if version>=1003 {put_u32(&w,0)}
    put_name(&w,13);put_name(&w,4);put_u32(&w,0xffffffff);put_name(&w,5);put_name(&w,0)
    if version>=1003 {put_u32(&w,0)}
    patch_u32(&w,export_patch,u32(w.at))
    put_u32(&w,0xfffffffe);put_u32(&w,0);put_u32(&w,0);put_u32(&w,0)
    put_name(&w,2);put_u32(&w,0)
    data_size_patch:=w.at;put_u64(&w,0)
    data_offset_patch:=w.at;put_u64(&w,0)
    w.at+=12
    if version<1005 {w.at+=16}
    if version>=1006 {w.at+=4}
    w.at+=12
    if version>=1003 {w.at+=4}
    w.at+=20
    script_end_patch:=0
    if version>=1010 {w.at+=8;script_end_patch=w.at;w.at+=8}
    patch_u32(&w,header_patch,u32(w.at))
    patch_u32(&w,data_offset_patch,u32(w.at))
    data_start:=w.at
    if version>=1011 {w.at+=1}
    put_name(&w,6);put_name(&w,7)
    if version>=1012 {put_u32(&w,0)}
    put_u32(&w,4)
    if version<1012 {put_u32(&w,0)}
    w.at+=1
    put_u32(&w,42)
    put_name(&w,8);put_name(&w,9)
    if version>=1012 {put_u32(&w,0)}
    put_u32(&w,9)
    if version<1012 {put_u32(&w,0)}
    w.at+=1
    put_text(&w,"kept")
    put_name(&w,10);put_name(&w,11)
    vector_bytes:=u32(version<1004?12:24)
    if version>=1012 {
        put_u32(&w,1);put_name(&w,12);put_u32(&w,0);put_u32(&w,vector_bytes);w.at+=1
    } else {
        put_u32(&w,vector_bytes);put_u32(&w,0);put_name(&w,12);w.at+=17
    }
    for value in ([3]f64{1,2,3}) {if version<1004 {put_u32(&w,transmute(u32)f32(value))} else {put_u64(&w,transmute(u64)value)}}
    put_name(&w,0)
    if version>=1010 {patch_u32(&w,script_end_patch,u32(w.at-data_start))}
    put_u32(&w,0)
    copy(w.bytes[w.at:],tail)
    w.at+=len(tail)
    patch_u32(&w,data_size_patch,u32(w.at-data_start))
    return w.bytes[:w.at]
}

@(test)
unreal_packages_keep_tables_tagged_values_and_native_tails :: proc(t:^testing.T) {
    for version in ([3]u32{0,1008,1018}) {
        bytes:=fixture_package(version)
        p,error:=package_open(bytes,source_package="/Game/Fixture")
        if !testing.expect(t,error.code==.None) {continue}
        defer package_destroy(&p)
        testing.expect_value(t,p.summary.version_ue5,i32(version))
        testing.expect_value(t,p.summary.stored_package_name,"/Game/Fixture")
        testing.expect_value(t,len(p.imports),2)
        testing.expect_value(t,len(p.exports),1)
        path,path_error:=reference_path(&p,1)
        testing.expect_value(t,path_error.code,Error_Code.None)
        testing.expect_value(t,path,"/Game/Fixture.Fixture")
        delete(path)
        list,property_error:=export_properties(&p,0,true)
        if !testing.expect(t,property_error.code==.None) {continue}
        defer properties_destroy(&list)
        testing.expect_value(t,len(list.items),3)
        testing.expect_value(t,list.trailing.size,i64(4))
        count:=property_find(&p,&list,"Count")
        value,value_error:=property_value(&p,count)
        testing.expect_value(t,value_error.code,Error_Code.None)
        testing.expect_value(t,value.signed,i64(42))
        value_destroy(&value)
        title:=property_find(&p,&list,"Title")
        value,value_error=property_value(&p,title)
        testing.expect_value(t,value_error.code,Error_Code.None)
        testing.expect_value(t,value.text,"kept")
        value_destroy(&value)
        position:=property_find(&p,&list,"Position")
        value,value_error=property_value(&p,position)
        testing.expect_value(t,value_error.code,Error_Code.None)
        testing.expect_value(t,value.vector,([4]f64{1,2,3,0}))
        value_destroy(&value)
        testing.expect(t,property_find(&p,&list,"NotAuthored")==nil,"missing serialized values remain absent")
    }
}

@(test)
unreal_ue4_521_blueprint_source_uses_the_same_authoring_table_schema :: proc(t:^testing.T) {
    bytes:=fixture_package(0)
    writer:=Fixture_Writer{bytes=bytes}
    patch_u32(&writer,12,521)
    p,error:=package_open(bytes,source_package="/Game/Fixture")
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer package_destroy(&p)
    testing.expect_value(t,p.summary.version_ue4,i32(521))
    testing.expect_value(t,p.summary.version_ue5,i32(0))
    testing.expect_value(t,len(p.imports),2)
    testing.expect_value(t,len(p.exports),1)
    properties,property_error:=export_properties(&p,0,true)
    if !testing.expect_value(t,property_error.code,Error_Code.None) {return}
    defer properties_destroy(&properties)
    testing.expect_value(t,len(properties.items),3)
    value,value_error:=property_value(&p,property_find(&p,&properties,"Count"))
    defer value_destroy(&value)
    testing.expect_value(t,value_error.code,Error_Code.None)
    testing.expect_value(t,value.signed,i64(42))
    patch_u32(&writer,12,213)
    unsupported,unsupported_error:=package_open(bytes)
    package_destroy(&unsupported)
    testing.expect_value(t,unsupported_error.code,Error_Code.Unsupported_Version)
}

@(test)
unreal_import_identity_requires_the_native_package_name :: proc(t:^testing.T) {
    p,error:=package_open(fixture_package(1018),source_package="/Game/Fixture")
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer package_destroy(&p)
    testing.expect(t,reference_in_package(&p,-2,"/Script/Niagara","NiagaraSystem"))
    p.names[3].text="/Script/Foreign"
    testing.expect(t,!reference_in_package(&p,-2,"/Script/Niagara","NiagaraSystem"))
}

@(test)
unreal_packages_reject_truncation_offsets_unversioned_and_cycles :: proc(t:^testing.T) {
    good:=fixture_package(1018)
    for size in 0..<len(good) {
        p,error:=package_open(good[:size])
        testing.expect(t,error.code!=.None,"each truncated package must fail before exposing spans")
        package_destroy(&p)
    }
    damaged:=make([]u8,len(good),context.temp_allocator)
    copy(damaged,good)
    for i in 12..<24 {damaged[i]=0}
    p,error:=package_open(damaged)
    testing.expect_value(t,error.code,Error_Code.Unversioned)
    package_destroy(&p)
    copy(damaged,good)
    base,base_error:=package_open(good)
    if !testing.expect(t,base_error.code==.None) {return}
    defer package_destroy(&base)
    at:=int(base.exports[0].source.offset)+12
    damaged[at]=1
    p,error=package_open(damaged)
    testing.expect_value(t,error.code,Error_Code.Cyclic_Outer)
    package_destroy(&p)
    copy(damaged,good)
    at=int(base.exports[0].source.offset)+36
    for i in 0..<8 {damaged[at+i]=0xff}
    p,error=package_open(damaged)
    testing.expect_value(t,error.code,Error_Code.Malformed)
    package_destroy(&p)
}

@(private)
Unreal_Allocation_Failure :: struct {owner:runtime.Allocator,remaining:int}

@(private)
unreal_failure_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Unreal_Allocation_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
unreal_packages_release_partial_allocations :: proc(t:^testing.T) {
    bytes:=fixture_package(1018,true)
    failure:=Unreal_Allocation_Failure{owner=context.allocator}
    allocator:=runtime.Allocator{unreal_failure_allocator,&failure}
    completed:=false
    for budget in 0..<8 {
        failure.remaining=budget
        p,error:=package_open(bytes,allocator)
        if error.code!=.None {testing.expect_value(t,error.code,Error_Code.Out_Of_Memory);continue}
        testing.expect_value(t,p.names[2].text,"Fixture")
        testing.expect(t,len(p.names[2].owned_text)>0,"wide names are converted once and released with the package")
        failure.remaining=0
        list,list_error:=export_properties(&p,0,true,allocator)
        testing.expect_value(t,list_error.code,Error_Code.Out_Of_Memory)
        properties_destroy(&list)
        package_destroy(&p)
        completed=true
        break
    }
    testing.expect(t,completed)
}
