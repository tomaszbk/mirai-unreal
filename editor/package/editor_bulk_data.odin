package unreal

// The source payload of an asset (EditorBulkData): the raw bytes kept as an
// CompressedBuffer in the package trailer or, in older saves, after the exports.

EDITOR_BULK_VIRTUALIZED :: u32(1<<0)
EDITOR_BULK_SIDECAR :: u32(1<<1)
EDITOR_BULK_LEGACY_FILE :: u32(1<<2)
EDITOR_BULK_LEGACY_ZLIB :: u32(1<<3)
EDITOR_BULK_WORKSPACE_DOMAIN :: u32(1<<8)
EDITOR_BULK_IN_TRAILER :: u32(1<<9)
EDITOR_BULK_COOKED :: u32(1<<10)

Editor_Bulk_Data :: struct {
    flags:u32,
    id:Guid,
    content_id:Payload_Id, // first 20 bytes of the BLAKE3 of the raw payload
    raw_size:i64,
    payload:Span,          // the CompressedBuffer; empty when raw_size is zero
    source:Span,           // the serialized struct in the export
}

// Reads the EditorBulkData that starts at span.offset and locates its payload.
editor_bulk_data :: proc(p:^Package,span:Span) -> (data:Editor_Bulk_Data,error:Error) {
    if p==nil || !span_valid(p.bytes,span) {return {},{.Malformed,span.offset,"editor bulk data range"}}
    r:=Reader{bytes=p.bytes,at=int(span.offset),end=int(span.offset+span.size)}
    data.flags=u32_read(&r,"editor bulk data flags")
    data.id=guid_read(&r,"editor bulk data id")
    copy(data.content_id[:],take(&r,20,"editor bulk data content hash"))
    data.raw_size=i64_read(&r,"editor bulk data raw size")
    if r.error.code!=.None {return {},r.error}
    if data.raw_size<0 || u64(data.raw_size)>p.limits.source_bytes {return {},{.Limit,i64(r.at-8),"editor bulk data raw size"}}
    flags:=data.flags
    switch {
    case flags&EDITOR_BULK_COOKED!=0:return {},{.Cooked,span.offset,"cooked bulk data keeps no editor source payload"}
    case flags&EDITOR_BULK_VIRTUALIZED!=0:return {},{.Unsupported_Value,span.offset,"payload is virtualized; rehydrate the package in Unreal before importing"}
    case flags&(EDITOR_BULK_SIDECAR|EDITOR_BULK_WORKSPACE_DOMAIN|EDITOR_BULK_LEGACY_FILE)!=0:return {},{.Unsupported_Value,span.offset,"payload lives in a sidecar, workspace or legacy bulk file; resave the package in Unreal"}
    }
    if flags&EDITOR_BULK_IN_TRAILER!=0 {
        trailer,trailer_error:=package_trailer(p.bytes,p.limits)
        if trailer_error.code!=.None {return {},trailer_error}
        entry,bytes,payload_error:=trailer_payload(trailer,data.content_id)
        if data.raw_size==0 {data.source={span.offset,i64(r.at)-span.offset};return}
        if payload_error.code!=.None {return {},payload_error}
        if entry.raw_size!=u64(data.raw_size) {return {},{.Malformed,span.offset,"trailer and bulk data disagree on the raw size"}}
        data.payload={trailer.payloads.offset+entry.offset,i64(len(bytes))}
    } else {
        offset:=i64_read(&r,"editor bulk data offset in file")
        if r.error.code!=.None {return {},r.error}
        if data.raw_size>0 {
            if offset<0 || offset>i64(len(p.bytes))-64 {return {},{.Malformed,i64(r.at-8),"editor bulk data offset in file"}}
            total:=i64(0)
            for byte in p.bytes[offset+24:offset+32] {total=total<<8|i64(byte)}
            data.payload={offset,total}
            if !span_valid(p.bytes,data.payload) {return {},{.Malformed,offset,"editor bulk data payload extent"}}
        }
    }
    data.source={span.offset,i64(r.at)-span.offset}
    return
}
