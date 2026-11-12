package unreal

import "base:intrinsics"
import "core:encoding/endian"

// BLAKE3 of a whole buffer: the content hash Unreal keeps for raw payloads
// (CompressedBuffer stores all 32 bytes, an IoHash the first 20). Whole
// chunks go four at a time, one in each lane of a vector: each operation does
// the work of four, which is what keeps the hash fast without the optimizer.

@(private="file") BLAKE3_IV :: [8]u32{0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
@(private="file") CHUNK_START :: u32(1)
@(private="file") CHUNK_END :: u32(2)
@(private="file") PARENT :: u32(4)
@(private="file") ROOT :: u32(8)
@(private="file") CHUNK_BYTES :: 1024
@(private="file") LANES :: 4

@(private="file")
Lanes :: #simd[LANES]u32

@(private="file")
rotate_right :: #force_inline proc "contextless" (x:$T,$N:uint) -> T {
    when intrinsics.type_is_simd_vector(T) {
        return intrinsics.simd_shr(x,T(N))|intrinsics.simd_shl(x,T(32-N))
    } else {
        return x>>N|x<<(32-N)
    }
}

@(private="file")
blake3_g :: #force_inline proc "contextless" (a,b,c,d,x,y:$T) -> (T,T,T,T) {
    a,b,c,d:=a,b,c,d
    a=a+b+x;d=rotate_right(d~a,16)
    c=c+d;b=rotate_right(b~c,12)
    a=a+b+y;d=rotate_right(d~a,8)
    c=c+d;b=rotate_right(b~c,7)
    return a,b,c,d
}

// The state stays in sixteen locals and each round reads the message words
// in its own order. T is u32 for one block, Lanes for one block of each lane.
@(private="file")
blake3_compress :: proc "contextless" (cv:[8]$T,m:[16]T,counter_low,counter_high,length,flags:T) -> (out:[16]T) #no_bounds_check {
    iv:=BLAKE3_IV
    s0,s1,s2,s3,s4,s5,s6,s7:=cv[0],cv[1],cv[2],cv[3],cv[4],cv[5],cv[6],cv[7]
    s8,s9,s10,s11:=T(iv[0]),T(iv[1]),T(iv[2]),T(iv[3])
    s12,s13,s14,s15:=counter_low,counter_high,length,flags
    m:=m
    #unroll for round in 0..<7 {
        s0,s4,s8,s12=blake3_g(s0,s4,s8,s12,m[0],m[1])
        s1,s5,s9,s13=blake3_g(s1,s5,s9,s13,m[2],m[3])
        s2,s6,s10,s14=blake3_g(s2,s6,s10,s14,m[4],m[5])
        s3,s7,s11,s15=blake3_g(s3,s7,s11,s15,m[6],m[7])
        s0,s5,s10,s15=blake3_g(s0,s5,s10,s15,m[8],m[9])
        s1,s6,s11,s12=blake3_g(s1,s6,s11,s12,m[10],m[11])
        s2,s7,s8,s13=blake3_g(s2,s7,s8,s13,m[12],m[13])
        s3,s4,s9,s14=blake3_g(s3,s4,s9,s14,m[14],m[15])
        if round<6 {
            m={m[2],m[6],m[3],m[10],m[7],m[0],m[4],m[13],m[1],m[11],m[12],m[5],m[9],m[14],m[15],m[8]}
        }
    }
    return {
        s0~s8,s1~s9,s2~s10,s3~s11,s4~s12,s5~s13,s6~s14,s7~s15,
        s8~cv[0],s9~cv[1],s10~cv[2],s11~cv[3],s12~cv[4],s13~cv[5],s14~cv[6],s15~cv[7],
    }
}

// A block of up to 64 bytes as little-endian words, zero padded.
@(private="file")
blake3_words :: #force_inline proc "contextless" (bytes:[]u8) -> (block:[16]u32) #no_bounds_check {
    if len(bytes)>=64 {
        words:=intrinsics.unaligned_load((^[16]u32le)(raw_data(bytes)))
        #unroll for i in 0..<16 {block[i]=u32(words[i])}
        return
    }
    padded:[64]u8
    copy(padded[:],bytes)
    for &word,i in block {word,_=endian.get_u32(padded[i*4:],.Little)}
    return
}

@(private="file")
blake3_first :: #force_inline proc "contextless" (words:[16]$T) -> [8]T {
    return {words[0],words[1],words[2],words[3],words[4],words[5],words[6],words[7]}
}

@(private="file")
blake3_parent :: proc "contextless" (left,right:[8]u32) -> (block:[16]u32) {
    for i in 0..<8 {block[i]=left[i];block[i+8]=right[i]}
    return
}

// The chaining values of LANES whole chunks from data[first*CHUNK_BYTES:].
@(private="file")
blake3_chunks :: proc "contextless" (data:[]u8,first:int) -> (cvs:[LANES][8]u32) #no_bounds_check {
    iv:=BLAKE3_IV
    cv:[8]Lanes
    #unroll for i in 0..<8 {cv[i]=Lanes(iv[i])}
    counter_low,counter_high:Lanes
    #unroll for lane in 0..<LANES {
        counter:=u64(first+lane)
        counter_low=intrinsics.simd_replace(counter_low,lane,u32(counter))
        counter_high=intrinsics.simd_replace(counter_high,lane,u32(counter>>32))
    }
    for block in 0..<CHUNK_BYTES/64 {
        words:[LANES][16]u32le
        #unroll for lane in 0..<LANES {
            words[lane]=intrinsics.unaligned_load((^[16]u32le)(&data[(first+lane)*CHUNK_BYTES+block*64]))
        }
        m:[16]Lanes
        #unroll for i in 0..<16 {
            #unroll for lane in 0..<LANES {m[i]=intrinsics.simd_replace(m[i],lane,u32(words[lane][i]))}
        }
        flags:=(block==0?CHUNK_START:0)|(block==CHUNK_BYTES/64-1?CHUNK_END:0)
        cv=blake3_first(blake3_compress(cv,m,counter_low,counter_high,Lanes(64),Lanes(flags)))
    }
    #unroll for i in 0..<8 {
        #unroll for lane in 0..<LANES {cvs[lane][i]=intrinsics.simd_extract(cv[i],lane)}
    }
    return
}

// One whole chunk that is not the last, alone.
@(private="file")
blake3_chunk :: proc "contextless" (data:[]u8,chunk:int) -> [8]u32 #no_bounds_check {
    cv:=BLAKE3_IV
    bytes:=data[chunk*CHUNK_BYTES:][:CHUNK_BYTES]
    for index in 0..<CHUNK_BYTES/64 {
        flags:=(index==0?CHUNK_START:0)|(index==CHUNK_BYTES/64-1?CHUNK_END:0)
        cv=blake3_first(blake3_compress(cv,blake3_words(bytes[index*64:][:64]),u32(chunk),u32(u64(chunk)>>32),64,flags))
    }
    return cv
}

// The chaining value of chunk, merged with the subtrees it completes.
@(private="file")
blake3_push :: #force_inline proc "contextless" (stack:^[54][8]u32,depth:^int,chunk:int,cv:[8]u32) #no_bounds_check {
    chunk_cv:=cv
    total:=chunk+1
    for total&1==0 {
        depth^-=1
        chunk_cv=blake3_first(blake3_compress(BLAKE3_IV,blake3_parent(stack[depth^],chunk_cv),0,0,64,PARENT))
        total>>=1
    }
    stack[depth^]=chunk_cv
    depth^+=1
}

blake3 :: proc "contextless" (data:[]u8) -> (digest:[32]u8) {
    stack:[54][8]u32
    depth:=0
    chunk_count:=max((len(data)+CHUNK_BYTES-1)/CHUNK_BYTES,1)
    // Every chunk but the last is whole; the last may close the root.
    chunk:=0
    for ;chunk+LANES<=chunk_count-1;chunk+=LANES {
        cvs:=blake3_chunks(data,chunk)
        for cv,lane in cvs {blake3_push(&stack,&depth,chunk+lane,cv)}
    }
    for ;chunk<chunk_count-1;chunk+=1 {blake3_push(&stack,&depth,chunk,blake3_chunk(data,chunk))}
    bytes:=data[min(chunk*CHUNK_BYTES,len(data)):]
    cv:=BLAKE3_IV
    blocks:=max((len(bytes)+63)/64,1)
    for index in 0..<blocks-1 {
        flags:=index==0?CHUNK_START:0
        cv=blake3_first(blake3_compress(cv,blake3_words(bytes[index*64:index*64+64]),u32(chunk),u32(u64(chunk)>>32),64,flags))
    }
    tail:=bytes[(blocks-1)*64:]
    last_cv,last_block,last_length,last_flags:=cv,blake3_words(tail),u32(len(tail)),(blocks==1?CHUNK_START:0)|CHUNK_END
    for depth>0 {
        depth-=1
        counter:=u64(chunk) if last_flags&PARENT==0 else 0
        right:=blake3_first(blake3_compress(last_cv,last_block,u32(counter),u32(counter>>32),last_length,last_flags))
        last_cv,last_block,last_length,last_flags=BLAKE3_IV,blake3_parent(stack[depth],right),64,PARENT
    }
    counter:=u64(chunk) if last_flags&PARENT==0 else 0
    words:=blake3_compress(last_cv,last_block,u32(counter),u32(counter>>32),last_length,last_flags|ROOT)
    for i in 0..<8 {endian.put_u32(digest[i*4:],.Little,words[i])}
    return
}
