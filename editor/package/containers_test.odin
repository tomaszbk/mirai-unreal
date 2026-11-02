package unreal

import "core:testing"
import "core:slice"

@(private="file")
container_fixture :: proc(version:i32) -> (p:Package,property:Property) {
    w:=Fixture_Writer{bytes=make([]u8,4096,context.temp_allocator)}
    put_u32(&w,2)
    inner_size_patch:=0
    if version<1012 {
        put_name(&w,4);put_name(&w,2)
        inner_size_patch=w.at;put_u32(&w,0);put_u32(&w,0);put_name(&w,3);w.at+=17
    }
    values_start:=w.at
    for value in ([2]u32{7,11}) {
        put_name(&w,5);put_name(&w,6)
        if version>=1012 {put_u32(&w,0)}
        put_u32(&w,4)
        if version<1012 {put_u32(&w,0)}
        w.at+=1
        put_u32(&w,value);put_name(&w,0)
    }
    if inner_size_patch!=0 {patch_u32(&w,inner_size_patch,u32(w.at-values_start))}
    name_values:=[7]Name{{text="None"},{text="ArrayProperty"},{text="StructProperty"},{text="FixtureRow"},{text="Rows"},{text="Count"},{text="IntProperty"}}
    names,_:=slice.clone(name_values[:],context.temp_allocator)
    p=Package{
        bytes=w.bytes[:w.at],
        summary={version_ue4=522,version_ue5=version},
        names=names,
        limits=DEFAULT_LIMITS,
    }
    property.name={4,0}
    property.types[0]={{1,0},1}
    property.types[1]={{2,0},0}
    property.type_count=2
    if version>=1012 {property.types[1].children=1;property.types[2]={{3,0},0};property.type_count=3}
    property.data={0,i64(w.at)}
    return
}

@(test)
unreal_struct_arrays_keep_each_rows_saved_values_and_refuse_guessed_native_layouts :: proc(t:^testing.T) {
    for version in ([2]i32{1008,1018}) {
        p,property:=container_fixture(version)
        view,error:=property_array(&p,&property)
        if !testing.expect(t,error.code==.None) {continue}
        testing.expect_value(t,view.count,u32(2))
        if version<1012 {
            refused,refused_error:=array_tagged_structs(&p,view)
            testing.expect_value(t,refused_error.code,Error_Code.Unsupported_Value)
            struct_array_destroy(&refused)
        }
        array,array_error:=array_tagged_structs(&p,view,true)
        if !testing.expect(t,array_error.code==.None) {continue}
        defer struct_array_destroy(&array)
        testing.expect_value(t,len(array.items),2)
        for &row,index in array.items {
            saved:=property_find(&p,&row,"Count")
            value,value_error:=property_value(&p,saved)
            testing.expect_value(t,value_error.code,Error_Code.None)
            testing.expect_value(t,value.signed,i64(index==0?7:11))
            value_destroy(&value)
        }
        view.native=true
        refused,refused_error:=array_tagged_structs(&p,view,true)
        testing.expect_value(t,refused_error.code,Error_Code.Unsupported_Value)
        struct_array_destroy(&refused)
    }
}

@(test)
unreal_string_conversion_handles_utf16_and_malformed_surrogates :: proc(t:^testing.T) {
    bytes:=[8]u8{0x61,0,0x3d,0xd8,0x00,0xde,0xe9,0}
    value,error:=serialized_string_value({bytes=bytes[:],wide=true})
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,value.text,"a😀é")
    value_destroy(&value)
    for count in ([3]int{1,4,5}) {
        value,error=serialized_string_value({bytes=bytes[:count],wide=true})
        testing.expect_value(t,error.code,Error_Code.Malformed)
        value_destroy(&value)
    }
}
