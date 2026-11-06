package kraken

// Leviathan chunks: offsets and lengths packed as in Kraken, literals in one
// or several arrays by the mode of the chunk, and commands in one array or
// eight, picked by the output position.

@(private)
Literal_Mode :: enum {
    Sub,      // one array, added to the byte at the last offset
    Raw,      // one array as it is
    Lam_Sub,  // the first literal after a match in a second array; all added
    Sub_And3, // four arrays by the output position, added
    O1,       // sixteen arrays by the high nibble of the byte before, as they are
    Sub_AndF, // sixteen arrays by the output position, added
}

@(private) LITERAL_ARRAYS :: [Literal_Mode]int{.Sub=1,.Raw=1,.Lam_Sub=2,.Sub_And3=4,.O1=16,.Sub_AndF=16}
@(private) COMMAND_ARRAYS :: 8

@(private)
leviathan_decode :: proc(d:^Decoder,src:[]u8,mode:int,destination:[]u8,start,count:int) -> Error {
    if mode>5 {return .Malformed}
    literal_mode:=Literal_Mode(mode)
    if len(src)<13 {return .Truncated}
    at,first:=0,start
    if start==0 {
        if count<8 {return .Malformed}
        copy(destination[:8],src[:8])
        at,first=8,8
    }
    scale:=0
    if src[at]&0x80!=0 {
        // Offsets times scale minus low bits from an array of their own.
        scale=int(src[at])-127
        at+=1
    }
    n,offset_count:=bytes_decode(d,src,at,d.offset_codes[:count/3]) or_return
    at+=n
    if scale!=0 && scale!=1 {
        n2,low_count:=bytes_decode(d,src,at,d.offset_low[:count/3]) or_return
        if low_count!=offset_count {return .Malformed}
        at+=n2
    }
    n3,length_count:=bytes_decode(d,src,at,d.length_codes[:count/5]) or_return
    at+=n3
    literals:[16][]u8
    arrays:=LITERAL_ARRAYS
    if arrays[literal_mode]==1 {
        n4,written:=bytes_decode(d,src,at,d.literals[:count]) or_return
        literals[0]=d.literals[:written]
        at+=n4
    } else {
        n4,_:=multi_arrays_decode(d,src[at:],d.literals[:count],literals[:arrays[literal_mode]],0) or_return
        at+=n4
    }
    if at>=len(src) {return .Truncated}
    commands:[COMMAND_ARRAYS][]u8
    command_arrays:=1
    if src[at]&0x80==0 {
        n5,written:=bytes_decode(d,src,at,d.commands[:count]) or_return
        commands[0]=d.commands[:written]
        at+=n5
    } else {
        if src[at]!=0x83 {return .Malformed}
        at+=1
        n5,_:=multi_arrays_decode(d,src[at:],d.commands[:count],commands[:],0) or_return
        at+=n5
        command_arrays=COMMAND_ARRAYS
    }
    if len(src)-at<3 {return .Truncated}
    offsets_unpack(d,src,at,offset_count,scale,length_count) or_return
    return leviathan_runs(d,literal_mode,destination,start,first,start+count,literals,commands[:command_arrays],offset_count,length_count)
}

// Commands: three bits of match length (7 takes a length from the back of
// the lengths), two of literal count (3 takes one from the front) and three
// that pick one of seven recent offsets, moved to the front, or the next new
// one. Literals before a match add to the byte at the offset of the match
// before.
@(private)
leviathan_runs :: proc(d:^Decoder,literal_mode:Literal_Mode,dst:[]u8,start,first,end:int,literals:[16][]u8,commands:[][]u8,offset_count,length_count:int) -> Error #no_bounds_check {
    if end>len(dst) || offset_count>len(d.offsets) || length_count>len(d.lengths) {return .Malformed}
    s:=Literal_Streams{arrays=literals,mode=literal_mode,start=start}
    recent:=[8]i32{-8,-8,-8,-8,-8,-8,-8,0}
    last:=-8
    o,offset_index,front,back:=first,0,0,length_count
    streams:[COMMAND_ARRAYS][]u8
    copy(streams[:],commands)
    total:=0
    for c in commands {total+=len(c)}
    for _ in 0..<total {
        // With eight arrays the position picks the array of the next command.
        stream:=&streams[0]
        if len(commands)>1 {stream=&streams[(o-start)&7]}
        if len(stream^)==0 {return .Malformed}
        command:=int(stream^[0])
        stream^=stream^[1:]
        literal_length:=(command>>3)&3
        if literal_length==3 {
            if front>=back {return .Malformed}
            literal_length=int(d.lengths[front])
            front+=1
        }
        if literal_length>end-o {return .Malformed}
        literals_take(&s,dst,o,literal_length,last) or_return
        o+=literal_length
        pick:=command>>5
        if pick==7 {
            if offset_index>=offset_count {return .Malformed}
            recent[7]=d.offsets[offset_index]
            offset_index+=1
        }
        offset:=recent[pick]
        for j:=pick;j>0;j-=1 {recent[j]=recent[j-1]}
        recent[0]=offset
        last=int(offset)
        if offset>=0 || -int(offset)>o {return .Malformed}
        match_length:=(command&7)+2
        if match_length==9 {
            if back<=front {return .Malformed}
            back-=1
            match_length=int(d.lengths[back])+6
        }
        if match_length>end-o {return .Malformed}
        match_copy(dst,o,o+last,match_length)
        o+=match_length
    }
    if offset_index!=offset_count || front!=back {return .Malformed}
    literals_take(&s,dst,o,end-o,last) or_return
    for array in s.arrays {if len(array)!=0 {return .Malformed}}
    return .None
}

@(private)
Literal_Streams :: struct {
    arrays:[16][]u8,
    mode:Literal_Mode,
    start:int, // the chunk, whose position picks the array
}

// count literals at dst[o:]. A run that starts after a match, or the run at
// the end, takes its first literal from the second array in Lam_Sub.
@(private)
literals_take :: proc(s:^Literal_Streams,dst:[]u8,o,count,last:int) -> Error #no_bounds_check {
    if count==0 {return nil}
    if s.mode!=.Raw && s.mode!=.O1 && o+last<0 {return .Malformed}
    switch s.mode {
    case .Raw,.Sub:
        if count>len(s.arrays[0]) {return .Malformed}
        literals_put(dst,o,s.arrays[0][:count],last,1 if s.mode==.Raw else 0)
        s.arrays[0]=s.arrays[0][count:]
    case .Lam_Sub:
        if len(s.arrays[1])==0 || count-1>len(s.arrays[0]) {return .Malformed}
        dst[o]=s.arrays[1][0]+dst[o+last]
        s.arrays[1]=s.arrays[1][1:]
        literals_add(dst,o+1,s.arrays[0][:count-1],last)
        s.arrays[0]=s.arrays[0][count-1:]
    case .Sub_And3,.Sub_AndF:
        mask:=3 if s.mode==.Sub_And3 else 15
        for p in o..<o+count {
            array:=&s.arrays[(p-s.start)&mask]
            if len(array^)==0 {return .Malformed}
            dst[p]=array^[0]+dst[p+last]
            array^=array^[1:]
        }
    case .O1:
        if o<1 {return .Malformed}
        for p in o..<o+count {
            array:=&s.arrays[dst[p-1]>>4]
            if len(array^)==0 {return .Malformed}
            dst[p]=array^[0]
            array^=array^[1:]
        }
    }
    return nil
}
