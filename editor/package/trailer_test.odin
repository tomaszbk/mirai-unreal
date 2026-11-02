package unreal

import "core:testing"

@(private="file")
trailer_fixture :: proc(access:Payload_Access=.Local) -> []u8 {
    w:=Fixture_Writer{bytes=make([]u8,111,context.temp_allocator),at=7}
    put_u64(&w,TRAILER_HEADER_TAG)
    put_u32(&w,2)
    put_u32(&w,77)
    put_u64(&w,7)
    put_u32(&w,1)
    w.bytes[w.at]=42;w.at+=20
    put_u64(&w,0)
    put_u64(&w,7)
    put_u64(&w,100)
    put_u32(&w,0)
    w.bytes[w.at]=u8(access);w.at+=1
    copy(w.bytes[w.at:],"payload");w.at+=7
    put_u64(&w,TRAILER_FOOTER_TAG)
    put_u64(&w,104)
    put_u32(&w,0x9e2a83c1)
    return w.bytes[:w.at]
}

@(test)
unreal_trailer_resolves_local_identity_and_preserves_external_storage :: proc(t:^testing.T) {
    bytes:=trailer_fixture()
    trailer,error:=package_trailer(bytes)
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    testing.expect_value(t,trailer.source,Span{7,104})
    testing.expect_value(t,trailer.payloads,Span{84,7})
    entry,payload,payload_error:=trailer_payload(trailer,{0=42})
    testing.expect_value(t,payload_error.code,Error_Code.None)
    testing.expect_value(t,entry.raw_size,u64(100))
    testing.expect_value(t,string(payload),"payload")
    _,_,missing:=trailer_payload(trailer,{0=43})
    testing.expect_value(t,missing.code,Error_Code.Invalid_Reference)
    for access in ([2]Payload_Access{.Referenced,.Virtualized}) {
        external,external_error:=package_trailer(trailer_fixture(access))
        testing.expect_value(t,external_error.code,Error_Code.None)
        _,_,unsupported:=trailer_payload(external,{0=42})
        testing.expect_value(t,unsupported.code,Error_Code.Unsupported_Value)
    }
}

@(test)
unreal_trailer_rejects_truncation_versions_limits_and_corrupt_extents :: proc(t:^testing.T) {
    bytes:=trailer_fixture()
    for length in 0..<len(bytes) {
        _,error:=package_trailer(bytes[:length])
        testing.expect(t,error.code!=.None)
    }
    _,limit:=package_trailer(bytes,Limits{source_bytes=1024,table_entries=0})
    testing.expect_value(t,limit.code,Error_Code.Limit)
    for offset in ([7]int{7,15,19,23,63,83,107}) {
        before:=bytes[offset]
        bytes[offset]=0xff
        _,error:=package_trailer(bytes)
        testing.expect(t,error.code!=.None)
        bytes[offset]=before
    }
    bytes[15]=3
    _,version:=package_trailer(bytes)
    testing.expect_value(t,version.code,Error_Code.Unsupported_Version)
}
