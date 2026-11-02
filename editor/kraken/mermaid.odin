package kraken

// Mermaid chunks (Selkie writes the same ones): literals, commands, near
// offsets of 16 bits, far offsets of 24 bits or more in two streams, one for
// each 64 KiB half of the chunk, and lengths as bytes in what is left.

@(private) MERMAID_HALF :: 0x10000
// d.offsets holds the near offsets below it and the far ones from it.
@(private) FAR_START :: 0x10000

@(private)
mermaid_decode :: proc(d:^Decoder,src:[]u8,mode:int,destination:[]u8,start,count:int) -> Error {
    if mode>1 {return .Malformed}
    if len(src)<10 {return .Truncated}
    at,first:=0,start
    if start==0 {
        if count<8 {return .Malformed}
        copy(destination[:8],src[:8])
        at,first=8,8
    }
    n,literal_count:=bytes_decode(d,src,at,d.literals[:count]) or_return
    at+=n
    n2,command_count:=bytes_decode(d,src,at,d.commands[:count]) or_return
    at+=n2
    split:=command_count
    if count>MERMAID_HALF {
        if len(src)-at<2 {return .Truncated}
        split=int(src[at])|int(src[at+1])<<8
        at+=2
        if split>command_count {return .Malformed}
    }
    if len(src)-at<2 {return .Truncated}
    near_count:=int(src[at])|int(src[at+1])<<8
    at+=2
    near:=d.offsets[:FAR_START]
    if near_count==0xffff {
        // Entropy coded: the high bytes, then the low ones.
        n3,high:=bytes_decode(d,src,at,d.offset_codes[:count>>1]) or_return
        at+=n3
        n4,low:=bytes_decode(d,src,at,d.offset_low[:count>>1]) or_return
        at+=n4
        if high!=low {return .Malformed}
        near_count=high
        for i in 0..<near_count {near[i]=i32(d.offset_low[i])|i32(d.offset_codes[i])<<8}
    } else {
        if len(src)-at<2*near_count {return .Truncated}
        for i in 0..<near_count {near[i]=i32(src[at+2*i])|i32(src[at+2*i+1])<<8}
        at+=2*near_count
    }
    if len(src)-at<3 {return .Truncated}
    header:=int(src[at])|int(src[at+1])<<8|int(src[at+2])<<16
    at+=3
    far_counts:[2]int
    if header!=0 {
        far_counts={header>>12,header&0xfff}
        for &far_count in far_counts {
            if far_count==0xfff {
                if len(src)-at<2 {return .Truncated}
                far_count=int(src[at])|int(src[at+1])<<8
                at+=2
            }
        }
    }
    if far_counts[0]+far_counts[1]>len(d.offsets)-FAR_START {return .Malformed}
    far:=[2][]i32{d.offsets[FAR_START:][:far_counts[0]],d.offsets[FAR_START+far_counts[0]:][:far_counts[1]]}
    for half in 0..<2 {at=far_offsets_read(src,at,far[half],start+half*MERMAID_HALF) or_return}
    commands:=[2][]u8{d.commands[:split],d.commands[split:command_count]}
    return mermaid_runs(d,mode,src,at,destination,start,first,count,literal_count,near[:near_count],commands,far)
}

// Distances back from the start of a half, never before the stream: three
// bytes, and past 12 MiB one more for the bits above 22 when the first three
// reach 0xC00000.
@(private)
far_offsets_read :: proc(src:[]u8,at:int,out:[]i32,position:int) -> (next:int,error:Error) {
    next=at
    for &value in out {
        if len(src)-next<3 {return 0,.Truncated}
        v:=int(src[next])|int(src[next+1])<<8|int(src[next+2])<<16
        next+=3
        if position>=0xc00000-1 && v>=0xc00000 {
            if next>=len(src) {return 0,.Truncated}
            v+=int(src[next])<<22
            next+=1
        }
        if v>position {return 0,.Malformed}
        value=i32(v)
    }
    return
}

// Commands of 24 and up: three bits of literals, four of match length and a
// top bit that keeps the last offset instead of taking the next near one.
// 3 to 23 copy that plus 5 bytes from the next far offset; 0 is a run of
// literals, 1 a long match at a near offset and 2 one at a far offset, with
// their lengths in the length bytes.
@(private)
mermaid_runs :: proc(d:^Decoder,mode:int,src:[]u8,lengths_at:int,dst:[]u8,start,first,count,literal_count:int,near:[]i32,commands:[2][]u8,far:[2][]i32) -> Error #no_bounds_check {
    end:=start+count
    if end>len(dst) || literal_count>len(d.literals) {return .Malformed}
    literals:=d.literals[:literal_count]
    last:=-8
    o,literal,near_index,lengths:=first,0,0,lengths_at
    for half in 0..<2 {
        half_start:=start+half*MERMAID_HALF
        if half_start>=end {
            if len(commands[half])!=0 || len(far[half])!=0 {return .Malformed}
            continue
        }
        half_end:=min(half_start+MERMAID_HALF,end)
        far_index:=0
        for command in commands[half] {
            c:=int(command)
            if c>=24 {
                literal_length:=c&7
                if literal_length>half_end-o || literal_length>literal_count-literal || o+last<0 {return .Malformed}
                literals_put(dst,o,literals[literal:literal+literal_length],last,mode)
                o+=literal_length
                literal+=literal_length
                if c&0x80==0 {
                    if near_index>=len(near) {return .Malformed}
                    last= -int(near[near_index])
                    near_index+=1
                }
                match_length:=(c>>3)&0xf
                if match_length>half_end-o || last>=0 || o+last<0 {return .Malformed}
                match_copy(dst,o,o+last,match_length)
                o+=match_length
                continue
            }
            length:int
            if c<=2 {
                if lengths>=len(src) {return .Truncated}
                length=int(src[lengths])
                if length>251 {
                    if len(src)-lengths<3 {return .Truncated}
                    length+=(int(src[lengths+1])|int(src[lengths+2])<<8)*4
                    lengths+=2
                }
                lengths+=1
            }
            if c==0 {
                length+=64
                if length>half_end-o || length>literal_count-literal || o+last<0 {return .Malformed}
                literals_put(dst,o,literals[literal:literal+length],last,mode)
                o+=length
                literal+=length
                continue
            }
            from:int
            if c==1 {
                length+=91
                if near_index>=len(near) {return .Malformed}
                from=o-int(near[near_index])
                near_index+=1
            } else {
                length=length+29 if c==2 else c+5
                if far_index>=len(far[half]) {return .Malformed}
                from=half_start-int(far[half][far_index])
                far_index+=1
            }
            if from<0 || from>=o || length>half_end-o {return .Malformed}
            last=from-o
            match_copy(dst,o,from,length)
            o+=length
        }
        if far_index!=len(far[half]) {return .Malformed}
        rest:=half_end-o
        if rest>literal_count-literal || o+last<0 {return .Malformed}
        literals_put(dst,o,literals[literal:literal+rest],last,mode)
        o+=rest
        literal+=rest
    }
    if lengths!=len(src) || literal!=literal_count || near_index!=len(near) {return .Malformed}
    return .None
}

// Mode 0 adds the literals to the bytes at the last offset; mode 1 copies them.
@(private)
literals_put :: #force_inline proc(dst:[]u8,to:int,literals:[]u8,last,mode:int) {
    if mode==0 {literals_add(dst,to,literals,last)} else {copy(dst[to:to+len(literals)],literals)}
}
