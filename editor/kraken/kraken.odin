package kraken

import "base:intrinsics"
import "core:mem"

// Decoder of the Oodle LZ streams Unreal writes: Kraken, the compressor of
// editor payloads, Mermaid and Selkie (one format) and Leviathan. A stream is
// a run of 256 KiB blocks; each block is split into 128 KiB chunks of
// entropy-coded literals and LZ matches whose offsets may reach back into
// earlier blocks of the same stream.

Error :: enum u8 {
    None,
    Truncated,   // the stream ends before its output does
    Malformed,   // a header, table or match that no encoder writes
    Unsupported, // LZNA, BitKnit, or the excess stream of a Kraken chunk
}

@(private) BLOCK_SIZE :: 0x40000
@(private) CHUNK_SIZE :: 0x20000
// Arrays nested in others: the parts of a multi-array and the entropy-coded front of an RLE array.
@(private) TEMP_SIZE :: 0x80000

@(private) KRAKEN :: 6
@(private) MERMAID :: 10 // Selkie too
@(private) LEVIATHAN :: 12

// Every buffer a chunk needs, allocated once: decoding never allocates.
Decoder :: struct {
    literals:[]u8,
    commands:[]u8,
    offset_codes:[]u8,
    offset_low:[]u8,
    length_codes:[]u8,
    offsets:[]i32,
    lengths:[]i32,
    temp:[]u8, // for arrays nested inside others
    temp_used:int,
    huffman:Huffman,
    tans:[TANS_MAX]Tans_Entry,
    allocator:mem.Allocator,
}

decoder_make :: proc(allocator:=context.allocator) -> (Decoder,mem.Allocator_Error) {
    d:=Decoder{allocator=allocator}
    errors:[8]mem.Allocator_Error
    d.literals,errors[0]=make([]u8,CHUNK_SIZE,allocator)
    d.commands,errors[1]=make([]u8,CHUNK_SIZE,allocator)
    d.offset_codes,errors[2]=make([]u8,CHUNK_SIZE,allocator)
    d.offset_low,errors[3]=make([]u8,CHUNK_SIZE,allocator)
    d.length_codes,errors[4]=make([]u8,CHUNK_SIZE/4,allocator)
    d.offsets,errors[5]=make([]i32,CHUNK_SIZE,allocator)
    d.lengths,errors[6]=make([]i32,CHUNK_SIZE/4,allocator)
    d.temp,errors[7]=make([]u8,TEMP_SIZE,allocator)
    for error in errors {
        if error!=nil {decoder_destroy(&d);return {},error}
    }
    return d,nil
}

decoder_destroy :: proc(decoder:^Decoder) {
    if decoder==nil || decoder.allocator.procedure==nil {return}
    delete(decoder.literals,decoder.allocator)
    delete(decoder.commands,decoder.allocator)
    delete(decoder.offset_codes,decoder.allocator)
    delete(decoder.offset_low,decoder.allocator)
    delete(decoder.length_codes,decoder.allocator)
    delete(decoder.offsets,decoder.allocator)
    delete(decoder.lengths,decoder.allocator)
    delete(decoder.temp,decoder.allocator)
    decoder^={}
}

// Decodes one Oodle stream whose raw size is exactly len(destination).
decode :: proc(decoder:^Decoder,source,destination:[]u8) -> Error {
    if decoder==nil || len(decoder.literals)!=CHUNK_SIZE {return .Malformed}
    at,o:=0,0
    for o<len(destination) {
        // Each block starts with two bytes: 0xC in the low nibble, flags, and the compressor.
        if len(source)-at<2 {return .Truncated}
        b0,b1:=source[at],source[at+1]
        if b0&0xf!=0xc || (b0>>4)&3!=0 {return .Malformed}
        stored:=b0&0x40!=0
        checksums:=b1&0x80!=0
        compressor:=b1&0x7f
        at+=2
        switch compressor {
        case KRAKEN,MERMAID,LEVIATHAN:
        case 5,11:return .Unsupported // LZNA and BitKnit
        case:return .Malformed
        }
        size:=min(BLOCK_SIZE,len(destination)-o)
        block:=destination[o:o+size]
        if stored {
            if len(source)-at<size {return .Truncated}
            copy(block,source[at:at+size])
            at+=size
            o+=size
            continue
        }
        // Quantum header: 18 bits of compressed size minus one, or all ones and
        // a kind: 0 repeats earlier output, 1 fills with a byte, 2 is stored.
        if len(source)-at<3 {return .Truncated}
        header:=int(source[at])<<16|int(source[at+1])<<8|int(source[at+2])
        packed:=header&0x3ffff
        at+=3
        if packed==0x3ffff {
            switch header>>18 {
            case 0:
                distance:=whole_match_distance(source,&at) or_return
                if distance<=1 || distance>o {return .Malformed}
                for i in 0..<size {block[i]=destination[o-distance+i]}
            case 1:
                if len(source)-at<1 {return .Truncated}
                for &value in block {value=source[at]}
                at+=1
            case 2:
                if checksums {at+=3}
                if len(source)-at<size {return .Truncated}
                copy(block,source[at:at+size])
                at+=size
            case:
                return .Malformed
            }
            o+=size
            continue
        }
        packed+=1
        if checksums {
            if len(source)-at<3 {return .Truncated}
            at+=3
        }
        if len(source)-at<packed {return .Truncated}
        if packed>size {return .Malformed}
        body:=source[at:at+packed]
        if packed==size {
            copy(block,body)
        } else {
            used:=quantum_decode(decoder,body,destination,o,size,int(compressor)) or_return
            if used!=packed {return .Malformed}
        }
        at+=packed
        o+=size
    }
    if at!=len(source) {return .Malformed}
    return .None
}

// Distance minus one: a big-endian word of 15 bits when its top bit is set,
// else its low bits under a series of bytes of 7 bits each.
@(private)
whole_match_distance :: proc(source:[]u8,at:^int) -> (distance:int,error:Error) {
    if len(source)-at^<2 {return 0,.Truncated}
    word:=u64(source[at^])<<8|u64(source[at^+1])
    at^+=2
    value:u64
    if word>=1<<15 {
        value=word-(1<<15)
    } else {
        top,shift:=u64(0),uint(0)
        for {
            if at^>=len(source) || shift>56 {return 0,.Malformed}
            byte:=u64(source[at^])
            at^+=1
            if byte>=128 {top+=(byte-128)<<shift;break}
            top+=(byte+128)<<shift
            shift+=7
        }
        value=(top<<15)+word+(1<<15)
    }
    if value>1<<30 {return 0,.Malformed}
    return int(value)+1,nil
}

// One block of output at destination[start:start+size] in chunks of 128 KiB.
@(private)
quantum_decode :: proc(d:^Decoder,src:[]u8,destination:[]u8,start,size,compressor:int) -> (read:int,error:Error) {
    at,o:=0,start
    end:=start+size
    for o<end {
        count:=min(CHUNK_SIZE,end-o)
        if len(src)-at<4 {return 0,.Truncated}
        header:=int(src[at])<<16|int(src[at+1])<<8|int(src[at+2])
        out:=destination[o:o+count]
        if header&0x800000==0 {
            // Only literals, entropy coded.
            d.temp_used=0
            n,w:=bytes_decode(d,src,at,out) or_return
            if w!=count {return 0,.Malformed}
            at+=n
        } else {
            at+=3
            packed:=header&0x7ffff
            mode:=(header>>19)&0xf
            if len(src)-at<packed {return 0,.Truncated}
            if packed<count {
                chunk:=src[at:at+packed]
                d.temp_used=0
                switch compressor {
                case KRAKEN:lz_decode(d,chunk,mode,destination,o,count) or_return
                case MERMAID:mermaid_decode(d,chunk,mode,destination,o,count) or_return
                case LEVIATHAN:leviathan_decode(d,chunk,mode,destination,o,count) or_return
                }
            } else if packed>count || mode!=0 {
                return 0,.Malformed
            } else {
                copy(out,src[at:at+count])
            }
            at+=packed
        }
        o+=count
    }
    return at,nil
}

// The streams of an LZ chunk, then its commands.
@(private)
lz_decode :: proc(d:^Decoder,src:[]u8,mode:int,destination:[]u8,start,count:int) -> Error {
    if mode>1 {return .Malformed}
    if len(src)<13 {return .Truncated}
    at,first:=0,start
    if start==0 {
        if count<8 {return .Malformed}
        // The stream starts with eight stored bytes.
        copy(destination[:8],src[:8])
        at,first=8,8
    }
    // A flag byte announces a stream of excess bytes, which is not read.
    if src[at]&0x80!=0 {return .Unsupported if src[at]&0xc0==0x80 else .Malformed}
    n,literal_count:=bytes_decode(d,src,at,d.literals[:count]) or_return
    at+=n
    n2,command_count:=bytes_decode(d,src,at,d.commands[:count]) or_return
    at+=n2
    if len(src)-at<3 {return .Truncated}
    scale:=0
    offset_count,low_count:int
    if src[at]&0x80!=0 {
        scale=int(src[at])-127
        at+=1
        n3:int
        n3,offset_count=bytes_decode(d,src,at,d.offset_codes[:command_count]) or_return
        at+=n3
        if scale!=1 {
            n4:int
            n4,low_count=bytes_decode(d,src,at,d.offset_low[:offset_count]) or_return
            if low_count!=offset_count {return .Malformed}
            at+=n4
        }
    } else {
        n3:int
        n3,offset_count=bytes_decode(d,src,at,d.offset_codes[:command_count]) or_return
        at+=n3
    }
    n5,length_count:=bytes_decode(d,src,at,d.length_codes[:count>>2]) or_return
    at+=n5
    offsets_unpack(d,src,at,offset_count,scale,length_count) or_return
    return runs_decode(d,mode,destination,first,start+count,literal_count,command_count,offset_count,length_count)
}

// Offsets and long lengths are bit fields read from both ends of what is left
// of the chunk: a forward stream and a backward one take turns.
@(private)
offsets_unpack :: proc(d:^Decoder,src:[]u8,at,offset_count,scale,length_count:int) -> Error {
    a:=msb_forward(src,at,len(src))
    b:=msb_backward(src,at,len(src))
    if b.bits<0x2000 {return .Malformed}
    zeros:=leading_zeros(b.bits)
    _=msb_take(&b,zeros)
    msb_refill(&b)
    long_count:=int(msb_take(&b,zeros+1))-1
    msb_refill(&b)
    if long_count>512 || long_count<0 {return .Malformed}
    codes:=d.offset_codes[:offset_count]
    for code,i in codes {
        r:=&a if i&1==0 else &b
        if scale==0 {
            // 0xfe and 0xff would need 30 or more bits: past the largest offset.
            if code>=0xfe {return .Malformed}
            d.offsets[i]= -i32(distance_read(r,u32(code)))
        } else {
            shift:=int(code>>3)
            if shift>26 {return .Malformed}
            value:=u32(8+int(code&7))<<uint(shift)|bits_read(r,shift)
            d.offsets[i]=8-i32(value)
        }
    }
    if scale>1 {
        for i in 0..<offset_count {
            // Within 32 bits: a larger distance is past any window.
            value:=i64(scale)*i64(d.offsets[i])-i64(d.offset_low[i])
            if value< -i64(max(i32)) || value>i64(max(i32)) {return .Malformed}
            d.offsets[i]=i32(value)
        }
    }
    long:[512]u32
    for i in 0..<long_count {
        r:=&a if i&1==0 else &b
        long[i]=length_read(r) or_return
    }
    if msb_position(&a)!=msb_position(&b) {return .Malformed}
    next:=0
    for code,i in d.length_codes[:length_count] {
        value:=u32(code)
        if value==255 {
            if next>=long_count {return .Malformed}
            value=long[next]+255
            next+=1
        }
        d.lengths[i]=i32(value)+3
    }
    if next!=long_count {return .Malformed}
    return .None
}

@(private)
distance_read :: proc(r:^Msb_Bits,code:u32) -> u32 {
    value:u32
    if code<0xf0 {
        n:=uint(code>>4)+4
        w:=rotate_left(r.bits|1,n)
        r.bitpos+=int(n)
        m:=(u32(2)<<n)-1
        r.bits=w&~m
        value=((w&m)<<4)+(code&0xf)-248
    } else {
        n:=uint(code-0xf0)+4
        w:=rotate_left(r.bits|1,n)
        r.bitpos+=int(n)
        m:=(u32(2)<<n)-1
        r.bits=w&~m
        value=8322816+((w&m)<<12)
        msb_refill(r)
        value+=r.bits>>20
        _=msb_take(r,12)
    }
    msb_refill(r)
    return value
}

@(private)
rotate_left :: #force_inline proc "contextless" (x:u32,n:uint) -> u32 {return x<<(n&31)|x>>((32-n)&31)}

@(private)
bits_read :: proc(r:^Msb_Bits,n:int) -> u32 {
    value:u32
    if n<=24 {
        value=msb_take(r,n)
    } else {
        value=msb_take(r,24)<<uint(n-24)
        msb_refill(r)
        value+=msb_take(r,n-24)
    }
    msb_refill(r)
    return value
}

@(private)
length_read :: proc(r:^Msb_Bits) -> (value:u32,error:Error) {
    zeros:=leading_zeros(r.bits)
    if zeros>12 {return 0,.Malformed}
    _=msb_take(r,zeros)
    msb_refill(r)
    value=msb_take(r,zeros+7)-64
    msb_refill(r)
    return
}

// Commands: two bits of literal count, four of match length and two that pick
// one of three recent offsets or the next new one. Mode 0 adds each literal
// to the byte at the last match offset; mode 1 copies literals as they are.
@(private)
runs_decode :: proc(d:^Decoder,mode:int,dst:[]u8,first,end,literal_count,command_count,offset_count,length_count:int) -> Error #no_bounds_check {
    if end>len(dst) || literal_count>len(d.literals) || command_count>len(d.commands) || offset_count>len(d.offsets) || length_count>len(d.lengths) {return .Malformed}
    recent:=[7]i32{0,0,0,-8,-8,-8,0}
    last:=-8
    o,literal,length,offset_index:=first,0,0,0
    literals:=d.literals[:literal_count]
    for command in d.commands[:command_count] {
        literal_length:=int(command&3)
        match_code:=int((command>>2)&0xf)
        pick:=int(command>>6)
        if literal_length==3 {
            if length>=length_count {return .Malformed}
            literal_length=int(d.lengths[length])
            length+=1
        }
        if literal_length>end-o || literal_length>literal_count-literal {return .Malformed}
        if mode==0 {
            if o+last<0 {return .Malformed}
            literals_add(dst,o,literals[literal:literal+literal_length],last)
        } else {
            copy(dst[o:o+literal_length],literals[literal:literal+literal_length])
        }
        o+=literal_length
        literal+=literal_length
        if pick==3 {
            if offset_index>=offset_count {return .Malformed}
            recent[6]=d.offsets[offset_index]
            offset_index+=1
        }
        offset:=recent[pick+3]
        recent[pick+3]=recent[pick+2]
        recent[pick+2]=recent[pick+1]
        recent[pick+1]=recent[pick]
        recent[3]=offset
        last=int(offset)
        if offset>=0 || -int(offset)>o {return .Malformed}
        match_length:int
        if match_code!=15 {
            match_length=match_code+2
        } else {
            if length>=length_count {return .Malformed}
            match_length=14+int(d.lengths[length])
            length+=1
        }
        if match_length>end-o {return .Malformed}
        match_copy(dst,o,o+last,match_length)
        o+=match_length
    }
    if offset_index!=offset_count || length!=length_count {return .Malformed}
    rest:=end-o
    if rest!=literal_count-literal {return .Malformed}
    if mode==0 {
        if rest>0 && o+last<0 {return .Malformed}
        literals_add(dst,o,literals[literal:],last)
    } else {
        copy(dst[o:end],literals[literal:])
    }
    return .None
}

// An LZ match: count bytes from dst[from:] to dst[to:], from below to and
// to+count inside dst, a byte at a time as far as the result goes, so an
// overlap repeats what was just written.
@(private)
match_copy :: #force_inline proc(dst:[]u8,to,from,count:int) #no_bounds_check {
    distance:=to-from
    if distance>=8 && len(dst)-to>=count+8 {
        // Whole words; the last one may write up to 7 bytes past the match, which come later.
        for i:=0;i<count;i+=8 {
            intrinsics.unaligned_store((^u64)(&dst[to+i]),intrinsics.unaligned_load((^u64)(&dst[from+i])))
        }
        return
    }
    if distance>=count {
        copy(dst[to:to+count],dst[from:from+count])
        return
    }
    for i in 0..<count {dst[to+i]=dst[from+i]}
}

// Literals added to the bytes at offset last before them: dst[to+i]=literals[i]+dst[to+i+last].
@(private)
literals_add :: #force_inline proc(dst:[]u8,to:int,literals:[]u8,last:int) #no_bounds_check {
    count:=len(literals)
    i:=0
    if last<= -8 {
        for ;i+8<=count;i+=8 {
            a:=intrinsics.unaligned_load((^u64)(&literals[i]))
            b:=intrinsics.unaligned_load((^u64)(&dst[to+i+last]))
            intrinsics.unaligned_store((^u64)(&dst[to+i]),bytes_add(a,b))
        }
    }
    for ;i<count;i+=1 {dst[to+i]=literals[i]+dst[to+i+last]}
}

// The eight bytes of a and b added one by one, without carries between them.
@(private)
bytes_add :: #force_inline proc "contextless" (a,b:u64) -> u64 {
    LOW :: 0x7f7f7f7f7f7f7f7f
    return ((a&LOW)+(b&LOW))~((a~b)&~u64(LOW))
}
