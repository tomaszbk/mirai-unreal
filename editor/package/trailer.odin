package unreal

Payload_Id :: [20]u8
Payload_Access :: enum u8 {Local,Referenced,Virtualized}
Trailer_Payload :: struct {
    id:Payload_Id,
    offset:i64,
    compressed_size,raw_size:u64,
    filter_flags:u16,
    access:Payload_Access,
}

Package_Trailer :: struct {
    bytes:[]u8,
    source,payloads:Span,
    count:u32,
}

@(private) TRAILER_HEADER_TAG :: u64(0xd1c43b2e80a5f697)
@(private) TRAILER_FOOTER_TAG :: u64(0x29bfca045138de76)

@(private)
trailer_entry_read :: proc(r:^Reader) -> (out:Trailer_Payload) {
    copy(out.id[:],take(r,20,"trailer payload identity"))
    out.offset=i64_read(r,"trailer payload offset")
    out.compressed_size=transmute(u64)i64_read(r,"trailer payload compressed size")
    out.raw_size=transmute(u64)i64_read(r,"trailer payload raw size")
    flags:=u16_read(r,"trailer payload flags")
    out.filter_flags=u16_read(r,"trailer payload filter flags")
    access:=u8_read(r,"trailer payload access")
    if flags!=0 {bad(r,.Unsupported_Value,"trailer payload flags")}
    if access>u8(Payload_Access.Virtualized) {bad(r,.Malformed,"trailer payload access")}
    out.access=Payload_Access(access)
    return
}

package_trailer :: proc(bytes:[]u8,limits:=DEFAULT_LIMITS) -> (out:Package_Trailer,error:Error) {
    if u64(len(bytes))>limits.source_bytes {return {},{.Limit,0,"package trailer source bytes"}}
    if len(bytes)<20 {return {},{.Truncated,0,"package trailer footer"}}
    r:=Reader{bytes=bytes,at=len(bytes)-20,end=len(bytes)}
    if transmute(u64)i64_read(&r,"trailer footer tag")!=TRAILER_FOOTER_TAG {return {},{.Unsupported_Value,i64(r.at-8),"package has no supported payload trailer"}}
    length:=transmute(u64)i64_read(&r,"trailer length")
    tag:=u32_read(&r,"trailer package tag")
    if tag!=0x9e2a83c1 || length<48 || length>u64(len(bytes)) {return {},{.Malformed,i64(len(bytes)-20),"package trailer extent"}}
    start:=len(bytes)-int(length)
    r.at,r.end=start,len(bytes)-20
    if transmute(u64)i64_read(&r,"trailer header tag")!=TRAILER_HEADER_TAG {return {},{.Malformed,i64(start),"package trailer header tag"}}
    version:=u32_read(&r,"trailer version")
    if version!=2 {return {},{.Unsupported_Version,i64(start+8),"package trailer version (requires 2)"}}
    header_size:=u32_read(&r,"trailer header size")
    payload_size:=transmute(u64)i64_read(&r,"trailer payload segment size")
    count:=i32_read(&r,"trailer payload count")
    if r.error.code!=.None {return {},r.error}
    if count<0 {return {},{.Malformed,i64(r.at-4),"trailer payload count"}}
    if u32(count)>limits.table_entries {return {},{.Limit,i64(r.at-4),"trailer payload count"}}
    if u64(header_size)!=28+u64(count)*49 || u64(header_size)>length-20 || payload_size!=length-20-u64(header_size) {return {},{.Malformed,i64(start+12),"trailer header and payload extents"}}
    out={bytes=bytes,source={i64(start),i64(length)},payloads={i64(start)+i64(header_size),i64(payload_size)},count=u32(count)}
    for _ in 0..<count {
        entry:=trailer_entry_read(&r)
        if r.error.code!=.None {return {},r.error}
        if entry.id=={} {return {},{.Malformed,i64(r.at-49),"trailer payload has no identity"}}
        if entry.raw_size>limits.source_bytes {return {},{.Limit,i64(r.at-21),"trailer payload raw size"}}
        if entry.access==.Virtualized {continue}
        if entry.offset<0 {return {},{.Malformed,i64(r.at-29),"trailer payload offset"}}
        if entry.access==.Local && (u64(entry.offset)>payload_size || entry.compressed_size>payload_size-u64(entry.offset)) {return {},{.Malformed,i64(r.at-29),"trailer local payload extent"}}
    }
    return
}

@(private)
trailer_valid :: proc(trailer:Package_Trailer) -> bool {
    return span_valid(trailer.bytes,trailer.source) && span_valid(trailer.bytes,trailer.payloads) && trailer.source.size>=48 && trailer.payloads.offset==trailer.source.offset+28+i64(trailer.count)*49
}

trailer_payload_at :: proc(trailer:Package_Trailer,index:u32) -> (out:Trailer_Payload,error:Error) {
    if !trailer_valid(trailer) || index>=trailer.count {return {},{.Invalid_Reference,0,"trailer payload index"}}
    r:=Reader{bytes=trailer.bytes,at=int(trailer.source.offset)+28+int(index)*49,end=int(trailer.payloads.offset)}
    out=trailer_entry_read(&r)
    return out,r.error
}

trailer_payload :: proc(trailer:Package_Trailer,id:Payload_Id) -> (out:Trailer_Payload,bytes:[]u8,error:Error) {
    if id=={} || !trailer_valid(trailer) {return {},nil,{.Invalid_Reference,0,"trailer payload lookup"}}
    r:=Reader{bytes=trailer.bytes,at=int(trailer.source.offset)+28,end=int(trailer.payloads.offset)}
    found:=false
    for _ in 0..<trailer.count {
        entry:=trailer_entry_read(&r)
        if r.error.code!=.None {return {},nil,r.error}
        if entry.id!=id {continue}
        if found {return {},nil,{.Malformed,i64(r.at-49),"duplicate trailer payload identity"}}
        out,found=entry,true
    }
    if !found {return {},nil,{.Invalid_Reference,trailer.source.offset,"payload identity is absent from package trailer"}}
    if out.access!=.Local {return {},nil,{.Unsupported_Value,trailer.source.offset,"payload is referenced or virtualized; provide a package with local source payloads"}}
    if out.offset<0 || out.offset>trailer.payloads.size || out.compressed_size>u64(trailer.payloads.size-out.offset) {return {},nil,{.Malformed,trailer.payloads.offset,"trailer payload extent"}}
    start:=int(trailer.payloads.offset+out.offset)
    return out,trailer.bytes[start:start+int(out.compressed_size)],{}
}
