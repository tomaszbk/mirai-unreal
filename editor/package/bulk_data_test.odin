package unreal

import "core:testing"

@(private="file")
zlib_stored :: proc(w:^Fixture_Writer,data:[]u8) {
    a,b:=u32(1),u32(0)
    for value in data {a=(a+u32(value))%65521;b=(b+a)%65521}
    adler:=b<<16|a
    w.bytes[w.at],w.bytes[w.at+1],w.bytes[w.at+2]=0x78,0x01,0x01
    w.at+=3
    n:=u16(len(data))
    w.bytes[w.at],w.bytes[w.at+1],w.bytes[w.at+2],w.bytes[w.at+3]=u8(n),u8(n>>8),u8(~n),u8(~n>>8)
    w.at+=4
    w.at+=copy(w.bytes[w.at:],data)
    for shift in ([4]u32{24,16,8,0}) {w.bytes[w.at]=u8(adler>>shift);w.at+=1}
}

@(test)
unreal_editor_bulk_data_finds_its_payload_in_the_trailer_or_after_the_exports :: proc(t:^testing.T) {
    // The struct, then the trailer of trailer_test with "payload" for identity 42.
    w:=Fixture_Writer{bytes=make([]u8,256,context.temp_allocator)}
    put_u32(&w,EDITOR_BULK_IN_TRAILER)
    w.at+=16
    w.bytes[w.at]=42;w.at+=20
    put_u64(&w,100)
    struct_end:=w.at
    trailer_at:=w.at
    put_u64(&w,TRAILER_HEADER_TAG);put_u32(&w,2);put_u32(&w,77);put_u64(&w,7);put_u32(&w,1)
    w.bytes[w.at]=42;w.at+=20
    put_u64(&w,0);put_u64(&w,7);put_u64(&w,100);put_u32(&w,0);w.at+=1
    copy(w.bytes[w.at:],"payload");w.at+=7
    put_u64(&w,TRAILER_FOOTER_TAG);put_u64(&w,u64(w.at+12-trailer_at));put_u32(&w,0x9e2a83c1)
    p:=Package{bytes=w.bytes[:w.at],limits=DEFAULT_LIMITS}
    data,error:=editor_bulk_data(&p,{0,i64(struct_end)})
    if !testing.expectf(t,error.code==.None,"%v",error) {return}
    testing.expect_value(t,data.raw_size,i64(100))
    payload,_:=span_bytes(&p,data.payload)
    testing.expect_value(t,string(payload),"payload")
    testing.expect_value(t,data.source,Span{0,48})
    p.bytes[40]=99
    _,size_error:=editor_bulk_data(&p,{0,i64(struct_end)})
    testing.expect_value(t,size_error.code,Error_Code.Malformed)
    p.bytes[40]=100
    p.bytes[0]=u8(EDITOR_BULK_VIRTUALIZED)
    _,virtualized:=editor_bulk_data(&p,{0,i64(struct_end)})
    testing.expect_value(t,virtualized.code,Error_Code.Unsupported_Value)
    for length in 0..<struct_end {
        _,truncated:=editor_bulk_data(&p,{0,i64(length)})
        testing.expect(t,truncated.code!=.None)
    }

    // Saved after the exports: the offset names an CompressedBuffer, whose header has its size.
    w2:=Fixture_Writer{bytes=make([]u8,256,context.temp_allocator)}
    put_u32(&w2,0)
    w2.at+=36
    put_u64(&w2,4)
    put_u64(&w2,100)
    w2.at=100
    w2.bytes[100+31]=68
    p2:=Package{bytes=w2.bytes[:168],limits=DEFAULT_LIMITS}
    legacy,legacy_error:=editor_bulk_data(&p2,{0,56})
    testing.expect_value(t,legacy_error.code,Error_Code.None)
    testing.expect_value(t,legacy.payload,Span{100,68})
    w2.bytes[100+31]=69
    _,beyond:=editor_bulk_data(&p2,{0,56})
    testing.expect_value(t,beyond.code,Error_Code.Malformed)
}

@(test)
unreal_ue4_bulk_data_reads_inline_end_of_file_and_zlib_payloads :: proc(t:^testing.T) {
    w:=Fixture_Writer{bytes=make([]u8,512,context.temp_allocator)}
    // Inline: flags, count, size on disk, offset, bytes.
    put_u32(&w,0);put_u32(&w,5);put_u32(&w,5);put_u64(&w,20)
    copy(w.bytes[w.at:],"hello");w.at+=5
    p:=Package{bytes=w.bytes[:],limits=DEFAULT_LIMITS}
    p.summary.version_ue4=522
    p.summary.bulk_data_start=300
    inline,error:=byte_bulk_data(&p,{0,64})
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,inline.payload,Span{20,5})
    testing.expect_value(t,inline.source,Span{0,25})
    // At the end of the file, relative to the bulk data section, with 64 bit sizes.
    w.at=64
    put_u32(&w,BULK_AT_END_OF_FILE|BULK_SIZE_64);put_u64(&w,5);put_u64(&w,5);put_u64(&w,10)
    copy(w.bytes[310:],"world")
    late,late_error:=byte_bulk_data(&p,{64,64})
    testing.expect_value(t,late_error.code,Error_Code.None)
    testing.expect_value(t,late.payload,Span{310,5})
    w.at=64
    put_u32(&w,BULK_AT_END_OF_FILE|BULK_SIZE_64|BULK_NO_OFFSET_FIXUP)
    absolute,_:=byte_bulk_data(&p,{64,64})
    testing.expect_value(t,absolute.payload,Span{10,5})
    w.at=64
    put_u32(&w,BULK_SEPARATE_FILE|BULK_AT_END_OF_FILE)
    _,separate:=byte_bulk_data(&p,{64,64})
    testing.expect_value(t,separate.code,Error_Code.Unsupported_Value)
    // An IntBulkData counts elements of four bytes.
    w.at=128
    put_u32(&w,0);put_u32(&w,2);put_u32(&w,8);put_u64(&w,148)
    w.at+=8
    ints,ints_error:=byte_bulk_data(&p,{128,64},4)
    testing.expect_value(t,ints_error.code,Error_Code.None)
    testing.expect_value(t,ints.size,i64(8))
    testing.expect_value(t,ints.source,Span{128,28})
    _,as_bytes:=byte_bulk_data(&p,{128,64})
    testing.expect_value(t,as_bytes.code,Error_Code.Malformed)

    // Zlib compressed chunks, decoded into the raw size.
    raw:="compressed bulk data of a texture source"
    z:=Fixture_Writer{bytes=make([]u8,256,context.temp_allocator)}
    put_u64(&z,0x9e2a83c1);put_u64(&z,1<<17)
    sizes_at:=z.at
    z.at+=16
    put_u64(&z,0);put_u64(&z,u64(len(raw)))
    stream_at:=z.at
    zlib_stored(&z,transmute([]u8)raw)
    packed:=z.at-stream_at
    at:=z.at
    z.at=sizes_at;put_u64(&z,u64(packed));put_u64(&z,u64(len(raw)))
    z.at=sizes_at+16;put_u64(&z,u64(packed))
    z.at=at
    out:=make([]u8,len(raw),context.temp_allocator)
    testing.expect_value(t,zlib_chunks_decode(z.bytes[:z.at],out).code,Error_Code.None)
    testing.expect_value(t,string(out),raw)
    testing.expect(t,zlib_chunks_decode(z.bytes[:z.at],out[:len(out)-1]).code!=.None)
    for length in 0..<z.at {testing.expect(t,zlib_chunks_decode(z.bytes[:length],out).code!=.None)}
    damaged:=make([]u8,z.at,context.temp_allocator)
    for position in 0..<z.at {
        copy(damaged,z.bytes[:z.at])
        damaged[position]~=0xff
        _=zlib_chunks_decode(damaged,out)
    }
}
