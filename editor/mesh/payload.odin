package mesh

import "core:mem"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"

// The raw bytes of a payload: a view of the package when they are stored as
// they are, else decompressed into allocator (owned is that buffer).
@(private)
payload_bytes :: proc(p:^unreal.Package,payload:Payload,decoder:^kraken.Decoder,allocator:mem.Allocator) -> (bytes,owned:[]u8,error:unreal.Error) {
    stored:[]u8
    stored,error=unreal.span_bytes(p,payload.span)
    if error.code!=.None {return}
    if payload.raw_size<0 || u64(payload.raw_size)>p.limits.source_bytes {return nil,nil,{.Limit,payload.span.offset,"source model raw size"}}
    switch payload.encoding {
    case .Raw:
        if i64(len(stored))!=payload.raw_size {return nil,nil,{.Malformed,payload.span.offset,"source model size"}}
        return stored,nil,{}
    case .Zlib,.Compressed_Buffer:
        buffer,allocation_error:=make([]u8,int(payload.raw_size),allocator)
        if allocation_error!=nil {return nil,nil,{.Out_Of_Memory,payload.span.offset,"source model payload"}}
        if payload.encoding==.Zlib {
            error=unreal.zlib_chunks_decode(stored,buffer)
        } else {
            compressed:unreal.Compressed_Buffer
            compressed,error=unreal.compressed_buffer(stored,p.limits)
            if error.code==.None && compressed.raw_size!=u64(payload.raw_size) {error={.Malformed,payload.span.offset,"compressed buffer and bulk data disagree on the raw size"}}
            if error.code==.None {error=unreal.compressed_buffer_decode(compressed,buffer,decoder,p.limits)}
        }
        if error.code!=.None {
            delete(buffer,allocator)
            error.offset+=payload.span.offset
            return nil,nil,error
        }
        return buffer,buffer,{}
    }
    return
}
