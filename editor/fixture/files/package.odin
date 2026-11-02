package fixture_files

import "core:hash"
import unreal "project:plugins/unreal/editor/package"

// The whole package: summary, names, imports, exports, their data, the bulk
// data at the end of the file and, when it has payloads, the trailer.
package_bytes :: proc(w:^Writer) -> []u8 {
    ue5:=w.desc.ue5
    b:=bytes_make(w.allocator)
    put_u32(&b,0x9e2a83c1)
    put_i32(&b,ue5==0?-7:-8)
    put_u32(&b,864)
    put_u32(&b,522)
    if ue5!=0 {put_i32(&b,ue5)}
    put_u32(&b,0)
    put_u32(&b,u32(len(w.desc.versions)))
    for version in w.desc.versions {
        for word in version.guid {put_u32(&b,word)}
        put_i32(&b,version.value)
    }
    header_at:=len(b.data);put_u32(&b,0)
    put_text(&b,w.desc.package_name)
    put_u32(&b,0)
    // The names of the tables are known once every export was added.
    for item in w.imports {name(w,item.class_package);name(w,item.class_name);name(w,item.name)}
    names_at:=len(b.data);put_u32(&b,0);put_u32(&b,0)
    if ue5>=1008 {put_zeros(&b,8)}
    put_u32(&b,0)
    put_zeros(&b,8)
    put_u32(&b,u32(len(w.exports)));exports_at:=len(b.data);put_u32(&b,0)
    put_u32(&b,u32(len(w.imports)));imports_at:=len(b.data);put_u32(&b,0)
    put_zeros(&b,20)
    put_zeros(&b,16)
    put_zeros(&b,16)
    put_u32(&b,0)
    for _ in 0..<2 {put_zeros(&b,10);put_u32(&b,0)}
    put_zeros(&b,12)
    put_u32(&b,0)
    put_zeros(&b,4)
    bulk_at:=len(b.data);put_u64(&b,0)
    put_zeros(&b,4)
    put_u32(&b,0)
    put_zeros(&b,8)
    if ue5>=1001 {put_u32(&b,0)}
    if ue5>=1002 {put_zeros(&b,8)}
    if ue5>=1009 {put_u32(&b,0)}
    patch_u32(&b,names_at,u32(len(w.names)))
    patch_u32(&b,names_at+4,u32(len(b.data)))
    for text in w.names {put_text(&b,text);put_u32(&b,0)}
    patch_u32(&b,imports_at,u32(len(b.data)))
    for item in w.imports {
        put_name(&b,w,item.class_package);put_name(&b,w,item.class_name);put_i32(&b,item.outer);put_name(&b,w,item.name);put_name(&b,w,"None")
        if ue5>=1003 {put_u32(&b,0)}
    }
    patch_u32(&b,exports_at,u32(len(b.data)))
    sizes:=make([]int,len(w.exports),w.allocator)
    for item,i in w.exports {
        put_i32(&b,item.class);put_i32(&b,0);put_i32(&b,0);put_i32(&b,item.outer)
        put_name(&b,w,item.name)
        put_u32(&b,item.outer==0?0xb:0x8)
        sizes[i]=len(b.data)
        put_u64(&b,0);put_u64(&b,0)
        put_zeros(&b,12)
        if ue5<1005 {put_zeros(&b,16)}
        if ue5>=1006 {put_u32(&b,0)}
        put_u32(&b,0);put_u32(&b,0);put_u32(&b,item.outer==0?1:0)
        if ue5>=1003 {put_u32(&b,0)}
        put_zeros(&b,20)
        if ue5>=1010 {put_u64(&b,0);put_u64(&b,u64(item.script_end))}
    }
    patch_u32(&b,header_at,u32(len(b.data)))
    for item,i in w.exports {
        patch_u64(&b,sizes[i],u64(len(item.data)))
        patch_u64(&b,sizes[i]+8,u64(len(b.data)))
        put_bytes(&b,item.data)
    }
    patch_u64(&b,bulk_at,u64(len(b.data)))
    put_bytes(&b,w.tail[:])
    if len(w.trailer_entries)>0 {
        start:=len(b.data)
        header:=28+len(w.trailer_entries)*49
        put_u64(&b,0xd1c43b2e80a5f697)
        put_u32(&b,2)
        put_u32(&b,u32(header))
        put_u64(&b,u64(len(w.trailer)))
        put_u32(&b,u32(len(w.trailer_entries)))
        for &entry in w.trailer_entries {
            put_bytes(&b,entry.id[:])
            put_u64(&b,entry.offset);put_u64(&b,entry.size);put_u64(&b,entry.raw)
            put_u16(&b,0);put_u16(&b,0);put_u8(&b,0)
        }
        put_bytes(&b,w.trailer[:])
        put_u64(&b,0x29bfca045138de76)
        put_u64(&b,u64(len(b.data)+12-start))
        put_u32(&b,0x9e2a83c1)
    }
    return b.data[:]
}

// An FCompressedBuffer that stores its bytes as they are.
compressed_buffer_none :: proc(raw:[]u8,allocator:=context.temp_allocator) -> []u8 {
    out:=make([]u8,64+len(raw),allocator)
    be32 :: proc(out:[]u8,at:int,value:u32) {for i in 0..<4 {out[at+i]=u8(value>>uint(24-i*8))}}
    be32(out,0,0xb7756362)
    be32(out,12,1)
    be32(out,16,u32(u64(len(raw))>>32));be32(out,20,u32(len(raw)))
    be32(out,24,u32(u64(len(out))>>32));be32(out,28,u32(len(out)))
    digest:=unreal.blake3(raw)
    copy(out[32:64],digest[:])
    be32(out,4,hash.crc32(out[8:64]))
    copy(out[64:],raw)
    return out
}

// Bytes as zlib compressed chunks of an archive: one chunk,
// as stored blocks.
zlib_chunks :: proc(raw:[]u8,allocator:=context.temp_allocator) -> []u8 {
    stream:=bytes_make(allocator)
    put_u8(&stream,0x78);put_u8(&stream,0x01)
    for at:=0;;at+=65535 {
        part:=raw[at:min(at+65535,len(raw))]
        last:=at+65535>=len(raw)
        put_u8(&stream,last?1:0)
        put_u16(&stream,u16(len(part)));put_u16(&stream,~u16(len(part)))
        put_bytes(&stream,part)
        if last {break}
    }
    adler:=hash.adler32(raw)
    for shift in ([4]u32{24,16,8,0}) {put_u8(&stream,u8(adler>>shift))}
    out:=bytes_make(allocator)
    put_u64(&out,0x9e2a83c1)
    put_u64(&out,max(u64(len(raw)),1))
    put_u64(&out,u64(len(stream.data)))
    put_u64(&out,u64(len(raw)))
    put_u64(&out,u64(len(stream.data)))
    put_u64(&out,u64(len(raw)))
    put_bytes(&out,stream.data[:])
    return out.data[:]
}
