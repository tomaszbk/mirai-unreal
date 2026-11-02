package unreal

import "core:hash"
import "project:plugins/unreal/editor/kraken"
import "mirai:std/serial"

Compressed_Method :: enum u8 {None=0,Oodle=3,LZ4=4}
Compressed_Buffer :: struct {
    bytes:[]u8,
    method:Compressed_Method,
    compressor:u8, // Oodle: 1 Selkie, 2 Mermaid, 3 Kraken, 4 Leviathan
    raw_size:u64,
    raw_hash:[32]u8, // BLAKE3 of the raw bytes
    block_count:u32,
    block_exponent:u8,
    header_size:int,
}

@(private="file")
be32 :: proc(bytes:[]u8) -> u32 {return u32(bytes[0])<<24 | u32(bytes[1])<<16 | u32(bytes[2])<<8 | u32(bytes[3])}
@(private="file")
be64 :: proc(bytes:[]u8) -> u64 {return u64(be32(bytes[:4]))<<32 | u64(be32(bytes[4:8]))}

compressed_buffer :: proc(bytes:[]u8,limits:=DEFAULT_LIMITS) -> (out:Compressed_Buffer,error:Error) {
    if len(bytes)<64 {return {},{.Truncated,0,"compressed buffer header"}}
    if u64(len(bytes))>limits.source_bytes {return {},{.Limit,0,"compressed buffer bytes"}}
    if be32(bytes[:4])!=0xb7756362 {return {},{.Malformed,0,"compressed buffer magic"}}
    method:=bytes[8]
    if method!=0 && method!=3 && method!=4 {return {},{.Unsupported_Value,8,"compressed buffer method"}}
    out={bytes=bytes,method=Compressed_Method(method),compressor=bytes[9],block_count=be32(bytes[12:16]),block_exponent=bytes[11],raw_size=be64(bytes[16:24]),header_size=64}
    copy(out.raw_hash[:],bytes[32:64])
    if out.raw_size>limits.source_bytes || out.raw_size>u64(max(int)) || out.block_count>limits.table_entries {return {},{.Limit,12,"compressed buffer raw bytes or block count"}}
    if be64(bytes[24:32])!=u64(len(bytes)) {return {},{.Malformed,24,"compressed buffer total byte count"}}
    if out.method==.None {
        if out.block_count!=1 || out.raw_size!=u64(len(bytes)-64) {return {},{.Malformed,12,"uncompressed buffer extent"}}
    } else {
        if out.block_exponent>=32 || out.raw_size==0 {return {},{.Malformed,11,"compressed buffer block size"}}
        block_size:=u64(1)<<out.block_exponent
        if u64(out.block_count)!=(out.raw_size-1)/block_size+1 {return {},{.Malformed,12,"compressed buffer block count"}}
        metadata_size:=u64(out.block_count)*4
        if metadata_size>u64(len(bytes)-64) {return {},{.Truncated,64,"compressed buffer block sizes"}}
        out.header_size+=int(metadata_size)
        at:=out.header_size
        for block in 0..<out.block_count {
            size:=u64(be32(bytes[64+int(block)*4:68+int(block)*4]))
            raw_size:=min(block_size,out.raw_size-u64(block)*block_size)
            if size==0 || size>raw_size || size>u64(len(bytes)-at) {return {},{.Malformed,i64(64+int(block)*4),"compressed buffer block extent"}}
            at+=int(size)
        }
        if at!=len(bytes) {return {},{.Malformed,i64(at),"compressed buffer trailing data"}}
    }
    if hash.crc32(bytes[8:out.header_size])!=be32(bytes[4:8]) {return {},{.Malformed,4,"compressed buffer header CRC32"}}
    return
}

// Decodes every block into destination, which holds exactly the raw size, and
// checks the result against the BLAKE3 the buffer stores. Oodle blocks need a
// decoder; one serves any number of buffers.
compressed_buffer_decode :: proc(buffer:Compressed_Buffer,destination:[]u8,decoder:^kraken.Decoder=nil,limits:=DEFAULT_LIMITS) -> Error {
    checked,error:=compressed_buffer(buffer.bytes,limits)
    if error.code!=.None {return error}
    if checked.raw_size!=u64(len(destination)) {return {.Limit,16,"compressed buffer destination size"}}
    if checked.method==.None {copy(destination,checked.bytes[64:])} else {
        source_at,destination_at:=checked.header_size,0
        for block in 0..<checked.block_count {
            size:=int(be32(checked.bytes[64+int(block)*4:68+int(block)*4]))
            raw_size:=min(int(u64(1)<<checked.block_exponent),len(destination)-destination_at)
            source:=checked.bytes[source_at:source_at+size]
            target:=destination[destination_at:destination_at+raw_size]
            if size==raw_size {copy(target,source)} else {
                switch checked.method {
                case .LZ4:
                    written,ok:=serial.lz4_decompress(source,target)
                    if !ok || written!=raw_size {return {.Malformed,i64(source_at),"LZ4 compressed buffer block"}}
                case .Oodle:
                    if decoder==nil {return {.Compressed,i64(source_at),"Oodle blocks need a kraken.Decoder"}}
                    switch kraken.decode(decoder,source,target) {
                    case .None:
                    case .Unsupported:return {.Unsupported_Value,i64(source_at),"Oodle block uses LZNA, BitKnit or the excess stream of Kraken"}
                    case .Truncated,.Malformed:return {.Malformed,i64(source_at),"Oodle compressed buffer block"}
                    }
                case .None:return {.Unsupported_Value,8,"compressed buffer method"}
                }
            }
            source_at+=size
            destination_at+=raw_size
        }
    }
    if blake3(destination)!=checked.raw_hash {return {.Malformed,32,"decoded payload does not match its BLAKE3 hash"}}
    return {}
}
