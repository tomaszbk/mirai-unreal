package unreal

import "base:runtime"
import "core:testing"

@(private="file")
guid_map_fixture :: proc() -> (p:Package,property:Property) {
    names:=[5]string{"None","MapProperty","StructProperty","Guid","/Script/CoreUObject"}
    p.names=make([]Name,len(names),context.temp_allocator)
    for name,i in names {p.names[i].text=name}
    p.limits=DEFAULT_LIMITS
    p.summary.version_ue5=1018
    w:=Fixture_Writer{bytes=make([]u8,128,context.temp_allocator)}
    put_u32(&w,0);put_u32(&w,2)
    for id in ([4]u32{1,2,3,4}) {put_u32(&w,id);w.at+=12}
    p.bytes=w.bytes[:w.at]
    property={type_count=7,data={0,i64(w.at)},native=true}
    property.types[0]={{1,0},2};property.types[1]={{2,0},1};property.types[2]={{3,0},1};property.types[3]={{4,0},0}
    property.types[4]={{2,0},1};property.types[5]={{3,0},1};property.types[6]={{4,0},0}
    return
}

@(test)
unreal_guid_maps_keep_persistent_identifiers_and_reject_duplicate_or_truncated_pairs :: proc(t:^testing.T) {
    p,property:=guid_map_fixture()
    mapping,error:=property_guid_map(&p,&property)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    testing.expect_value(t,len(mapping.items),2)
    testing.expect_value(t,mapping.items[0].value,guid_from_words({2,0,0,0}))
    testing.expect(t,!mapping.replace)
    guid_map_destroy(&mapping)
    for length in 0..<int(property.data.size) {
        damaged:=property;damaged.data.size=i64(length)
        failed,failed_error:=property_guid_map(&p,&damaged)
        testing.expect(t,failed_error.code!=.None)
        guid_map_destroy(&failed)
    }
    p.bytes[40]=1
    failed,failed_error:=property_guid_map(&p,&property)
    testing.expect_value(t,failed_error.code,Error_Code.Malformed)
    guid_map_destroy(&failed)
    p.bytes[40]=3
    p.names[4].text="/Script/Foreign"
    other_package,foreign_error:=property_guid_map(&p,&property)
    testing.expect_value(t,foreign_error.code,Error_Code.Unsupported_Value)
    guid_map_destroy(&other_package)
    p.names[4].text="/Script/CoreUObject"
    for allocations in 0..<3 {
        failure:=Unreal_Allocation_Failure{owner=context.allocator,remaining=allocations}
        allocator:=runtime.Allocator{unreal_failure_allocator,&failure}
        failed,failed_error:=property_guid_map(&p,&property,allocator=allocator)
        testing.expect(t,failed_error.code==.None || failed_error.code==.Out_Of_Memory)
        guid_map_destroy(&failed)
    }
}
