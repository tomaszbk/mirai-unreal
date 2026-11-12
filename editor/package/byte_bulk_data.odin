package unreal

import "core:c"
import stbi "vendor:stb/image"

// UE4's bulk data (ByteBulkData): raw bytes inline after the struct or in the
// section that starts at Summary.bulk_data_start, optionally zlib chunks. A
// bulk data of other elements (IntBulkData) counts elements of element_size bytes.

BULK_AT_END_OF_FILE :: u32(1<<0)
BULK_ZLIB :: u32(1<<1)
BULK_UNUSED :: u32(1<<5)
BULK_SEPARATE_FILE :: u32(1<<8)
BULK_SIZE_64 :: u32(1<<13)
BULK_DUPLICATE :: u32(1<<14)
BULK_BAD_DATA_VERSION :: u32(1<<15)
BULK_NO_OFFSET_FIXUP :: u32(1<<16)
BULK_WORKSPACE_DOMAIN :: u32(1<<17)

@(private="file")
UE5_DATA_RESOURCES :: 1009

Byte_Bulk_Data :: struct {
    flags:u32,
    size:i64,     // raw bytes
    payload:Span, // what is stored: the raw bytes, or zlib chunks with BULK_ZLIB
    source:Span,  // the serialized struct, and the payload when it is inline
}

byte_bulk_data :: proc(p:^Package,span:Span,element_size:=1) -> (data:Byte_Bulk_Data,error:Error) {
    if p==nil || !span_valid(p.bytes,span) {return {},{.Malformed,span.offset,"bulk data range"}}
    if p.summary.version_ue5>=UE5_DATA_RESOURCES {return {},{.Unsupported_Value,span.offset,"bulk data of this version lives in the data resource table"}}
    r:=Reader{bytes=p.bytes,at=int(span.offset),end=int(span.offset+span.size)}
    data.flags=u32_read(&r,"bulk data flags")
    disk:i64
    offset:i64
    if data.flags&BULK_SIZE_64!=0 {
        data.size=i64_read(&r,"bulk data element count")
        disk=i64_read(&r,"bulk data size on disk")
    } else {
        data.size=i64(i32_read(&r,"bulk data element count"))
        disk=i64(i32_read(&r,"bulk data size on disk"))
    }
    offset=i64_read(&r,"bulk data offset")
    if data.flags&BULK_BAD_DATA_VERSION!=0 {_=u16_read(&r,"bulk data bad version")}
    if data.flags&BULK_DUPLICATE!=0 {return {},{.Unsupported_Value,span.offset,"duplicated bulk data belongs to cooked packages"}}
    if r.error.code!=.None {return {},r.error}
    if data.size<0 || disk<0 || element_size<1 || u64(data.size)>p.limits.source_bytes/u64(element_size) || u64(disk)>p.limits.source_bytes {return {},{.Limit,span.offset,"bulk data size"}}
    data.size*=i64(element_size)
    if data.flags&(BULK_SEPARATE_FILE|BULK_WORKSPACE_DOMAIN)!=0 {return {},{.Unsupported_Value,span.offset,"bulk data in a separate file; import the package that holds its payload"}}
    if data.flags&BULK_UNUSED!=0 || data.size==0 {data.source={span.offset,i64(r.at)-span.offset};return}
    if data.flags&BULK_ZLIB==0 && disk!=data.size {return {},{.Malformed,span.offset,"uncompressed bulk data size on disk"}}
    if data.flags&BULK_AT_END_OF_FILE!=0 {
        if data.flags&BULK_NO_OFFSET_FIXUP==0 {offset+=p.summary.bulk_data_start}
        data.payload={offset,disk}
        data.source={span.offset,i64(r.at)-span.offset}
    } else {
        data.payload={i64(r.at),disk}
        data.source={span.offset,i64(r.at)-span.offset+disk}
    }
    if !span_valid(p.bytes,data.payload) {return {},{.Malformed,span.offset,"bulk data payload extent"}}
    return
}

// Bulk data saved as zlib compressed chunks: a tag with the chunk
// size, the total sizes, the size of each chunk and the zlib streams.
zlib_chunks_decode :: proc(source,destination:[]u8) -> Error {
    r:=Reader{bytes=source,end=len(source)}
    tag:=i64_read(&r,"compressed chunks tag")
    chunk_size:=i64_read(&r,"compressed chunk size")
    compressed:=i64_read(&r,"compressed chunks size")
    raw:=i64_read(&r,"compressed chunks raw size")
    if r.error.code!=.None {return r.error}
    if tag!=0x9e2a83c1 {return {.Unsupported_Value,0,"compressed bulk data header; only zlib chunks of UE4 are read"}}
    if chunk_size==0x9e2a83c1 {chunk_size=128<<10}
    if chunk_size<=0 || chunk_size>=1<<31 || raw!=i64(len(destination)) || compressed<0 || compressed>i64(len(source)) {return {.Malformed,8,"compressed chunks sizes"}}
    count:=(raw+chunk_size-1)/chunk_size
    if count*16>i64(len(source)-r.at) {return {.Truncated,i64(r.at),"compressed chunk table"}}
    data_at:=i64(r.at)+count*16
    written,consumed:=i64(0),i64(0)
    for _ in 0..<count {
        size:=i64_read(&r,"compressed chunk size")
        unpacked:=i64_read(&r,"compressed chunk raw size")
        if r.error.code!=.None {return r.error}
        if size<=0 || unpacked<=0 || unpacked>chunk_size || size>i64(len(source))-data_at-consumed || unpacked>raw-written {return {.Malformed,i64(r.at-16),"compressed chunk extent"}}
        input:=source[data_at+consumed:][:size]
        output:=destination[written:][:unpacked]
        if stbi.zlib_decode_buffer(raw_data(output),c.int(unpacked),raw_data(input),c.int(size))!=c.int(unpacked) {return {.Malformed,data_at+consumed,"zlib chunk"}}
        written+=unpacked
        consumed+=size
    }
    if written!=raw || consumed!=compressed {return {.Malformed,8,"compressed chunks do not add up to their totals"}}
    return {}
}
