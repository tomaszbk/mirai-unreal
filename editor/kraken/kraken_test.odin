package kraken

import "base:runtime"
import "core:testing"

// A small encoder of the parts of the format the decoder reads, enough to
// build streams whose output is known: stored and fill blocks, LZ chunks
// with stored arrays, new and recent offsets, long lengths, and Huffman and
// RLE arrays.

@(private)
Bit_Writer :: struct {bytes:[dynamic]u8,count:int}

@(private)
bits_put :: proc(w:^Bit_Writer,value:u32,n:int) {
    for i:=n-1;i>=0;i-=1 {
        if w.count%8==0 {append(&w.bytes,0)}
        if (value>>uint(i))&1!=0 {w.bytes[len(w.bytes)-1]|=u8(0x80>>uint(w.count%8))}
        w.count+=1
    }
}

@(private)
bit_length :: proc(value:u32) -> int {
    n:=0
    for v:=value;v!=0;v>>=1 {n+=1}
    return n
}

@(private)
array_stored :: proc(out:^[dynamic]u8,data:[]u8) {
    append(out,u8(len(data)>>16),u8(len(data)>>8),u8(len(data)))
    append(out,..data)
}

@(private)
Op :: struct {literals:[]u8,offset,length:int,recent:int} // recent 0..2 reuses an offset, 3 takes offset

// An LZ chunk producing expected[start:start+count] from what is before it.
@(private)
lz_chunk :: proc(expected:[]u8,start,count:int,ops:[]Op,mode:int) -> []u8 {
    body:[dynamic]u8
    body.allocator=context.temp_allocator
    o:=start
    if start==0 {append(&body,..expected[:8]);o=8}
    literals,commands,codes,lengths:[dynamic]u8
    literals.allocator,commands.allocator,codes.allocator,lengths.allocator=context.temp_allocator,context.temp_allocator,context.temp_allocator,context.temp_allocator
    longs:[dynamic]u32
    longs.allocator=context.temp_allocator
    last:=-8
    length_code :: proc(lengths:^[dynamic]u8,longs:^[dynamic]u32,value:int) {
        if value<255 {append(lengths,u8(value))} else {append(lengths,255);append(longs,u32(value-255))}
    }
    distances:[dynamic]int
    distances.allocator=context.temp_allocator
    for op in ops {
        for i in 0..<len(op.literals) {
            value:=expected[o+i]
            if mode==0 {value-=expected[o+i+last]}
            append(&literals,value)
        }
        command:=u8(op.recent)<<6
        if len(op.literals)<3 {command|=u8(len(op.literals))} else {command|=3;length_code(&lengths,&longs,len(op.literals)-3)}
        o+=len(op.literals)
        if op.length<=16 {command|=u8(op.length-2)<<2} else {command|=15<<2;length_code(&lengths,&longs,op.length-17)}
        append(&commands,command)
        if op.recent==3 {append(&distances,op.offset)}
        last= -op.offset
        o+=op.length
    }
    for i in o..<start+count {
        value:=expected[i]
        if mode==0 {value-=expected[i+last]}
        append(&literals,value)
    }
    a,b:Bit_Writer
    a.bytes.allocator,b.bytes.allocator=context.temp_allocator,context.temp_allocator
    gamma:=u32(len(longs)+1)
    bits_put(&b,0,bit_length(gamma)-1)
    bits_put(&b,gamma,bit_length(gamma))
    for distance,i in distances {
        w:=&a if i&1==0 else &b
        t:=u32(distance+248)
        high:=t>>4
        n:=bit_length(high)-1
        append(&codes,u8((n-4)<<4)|u8(t&15))
        bits_put(w,high-(1<<uint(n)),n)
    }
    for long,i in longs {
        w:=&a if i&1==0 else &b
        value:=long+64
        n:=bit_length(value)
        bits_put(w,0,n-7)
        bits_put(w,value,n)
    }
    array_stored(&body,literals[:])
    array_stored(&body,commands[:])
    array_stored(&body,codes[:])
    array_stored(&body,lengths[:])
    append(&body,..a.bytes[:])
    for i:=len(b.bytes)-1;i>=0;i-=1 {append(&body,b.bytes[i])}
    header:=0x800000|mode<<19|len(body)
    out:=make([dynamic]u8,context.temp_allocator)
    append(&out,u8(header>>16),u8(header>>8),u8(header))
    append(&out,..body[:])
    return out[:]
}

// One block: header, quantum header and its chunks.
@(private)
block_put :: proc(out:^[dynamic]u8,chunks:[]u8) {
    append(out,0x8c,0x06)
    packed:=len(chunks)-1
    append(out,u8(packed>>16),u8(packed>>8),u8(packed))
    append(out,..chunks)
}

// Huffman array of two symbols with one-bit codes, kind 1.
@(private)
huffman_array :: proc(out:^[dynamic]u8,data:[]u8,zero,one:u8) {
    header:Bit_Writer
    header.bytes.allocator=context.temp_allocator
    bits_put(&header,0,1)
    bits_put(&header,0,1)
    bits_put(&header,2,8)
    bits_put(&header,0,3)
    bits_put(&header,u32(zero),8)
    bits_put(&header,u32(one),8)
    streams:[3][dynamic]u8
    counts:[3]int
    for &s in streams {s.allocator=context.temp_allocator}
    for value,i in data {
        s:=i%3
        if counts[s]%8==0 {append(&streams[s],0)}
        if value==one {streams[s][len(streams[s])-1]|=u8(1)<<uint(counts[s]%8)}
        counts[s]+=1
    }
    body:[dynamic]u8
    body.allocator=context.temp_allocator
    append(&body,..header.bytes[:])
    append(&body,u8(len(streams[0])),u8(len(streams[0])>>8))
    append(&body,..streams[0][:])
    append(&body,..streams[2][:])
    for i:=len(streams[1])-1;i>=0;i-=1 {append(&body,streams[1][i])}
    array_header(out,2,len(data),len(body))
    append(out,..body[:])
}

@(private)
pattern :: proc(size:int,seed:u32) -> []u8 {
    out:=make([]u8,size,context.temp_allocator)
    state:=seed
    for &value,i in out {
        state=state*1664525+1013904223
        value=u8(state>>24) if (i/64)%3==0 else u8(i/7)
    }
    return out
}

@(private)
check :: proc(t:^testing.T,stream,expected:[]u8,loc:=#caller_location) {
    decoder,_:=decoder_make()
    defer decoder_destroy(&decoder)
    out:=make([]u8,len(expected),context.temp_allocator)
    error:=decode(&decoder,stream,out)
    testing.expect_value(t,error,Error.None,loc=loc)
    testing.expect(t,string(out)==string(expected),"decoded bytes match",loc=loc)
}

@(test)
kraken_stored_fill_and_raw_chunks :: proc(t:^testing.T) {
    expected:=pattern(300,1)
    stream:[dynamic]u8
    stream.allocator=context.temp_allocator
    append(&stream,0x4c,0x06)
    append(&stream,..expected)
    check(t,stream[:],expected)
    clear(&stream)
    fill:=make([]u8,1000,context.temp_allocator)
    for &value in fill {value=0x5a}
    append(&stream,0x0c,0x86,0x07,0xff,0xff,0x5a)
    check(t,stream[:],fill)
    // A stored chunk next to one Huffman array of a single symbol.
    clear(&stream)
    mixed:=make([]u8,2*CHUNK_SIZE,context.temp_allocator)
    copy(mixed,pattern(CHUNK_SIZE,5))
    for &value in mixed[CHUNK_SIZE:] {value=0x33}
    chunk:[dynamic]u8
    chunk.allocator=context.temp_allocator
    append(&chunk,0x82,0x00,0x00) // stored LZ chunk of CHUNK_SIZE bytes
    append(&chunk,..mixed[:CHUNK_SIZE])
    array_header(&chunk,2,CHUNK_SIZE,3)
    append(&chunk,0x00,0x4c,0xc0) // old sparse lengths: one symbol, 0x33
    block_put(&stream,chunk[:])
    check(t,stream[:],mixed)
}

@(test)
kraken_lz_chunks_with_both_literal_modes :: proc(t:^testing.T) {
    expected:=pattern(4096,7)
    // Matches the decoder must reproduce: new offsets, a repeated one and long copies.
    lz_copy(expected,100,20,40)
    lz_copy(expected,150,140,250)
    lz_copy(expected,420,340,30)
    ops:=[]Op{
        {literals=expected[8:100],offset=80,length=40,recent=3},
        {literals=expected[140:150],offset=10,length=250,recent=3},
        {literals=expected[400:420],offset=80,length=30,recent=1},
    }
    for mode in 0..=1 {
        stream:[dynamic]u8
        stream.allocator=context.temp_allocator
        block_put(&stream,lz_chunk(expected,0,len(expected),ops,mode))
        check(t,stream[:],expected)
    }
}

@(test)
kraken_matches_reach_back_into_earlier_blocks :: proc(t:^testing.T) {
    size:=BLOCK_SIZE+5000
    expected:=pattern(size,3)
    lz_copy(expected,BLOCK_SIZE+100,1000,1000)
    stream:[dynamic]u8
    stream.allocator=context.temp_allocator
    append(&stream,0x4c,0x06)
    append(&stream,..expected[:BLOCK_SIZE])
    ops:=[]Op{{literals=expected[BLOCK_SIZE:BLOCK_SIZE+100],offset=BLOCK_SIZE+100-1000,length=1000,recent=3}}
    block_put(&stream,lz_chunk(expected,BLOCK_SIZE,5000,ops,0))
    check(t,stream[:],expected)
}

@(test)
kraken_huffman_and_rle_arrays :: proc(t:^testing.T) {
    expected:=make([]u8,2000,context.temp_allocator)
    for &value,i in expected {value='a' if (i*7)%11<5 else 'b'}
    chunk:[dynamic]u8
    chunk.allocator=context.temp_allocator
    huffman_array(&chunk,expected,'a','b')
    stream:[dynamic]u8
    stream.allocator=context.temp_allocator
    block_put(&stream,chunk[:])
    check(t,stream[:],expected)

    run:=make([]u8,107,context.temp_allocator)
    for &value in run {value='r'}
    run[3]='x'
    rle:=[]u8{0x00,'r','x',0x00,0x29,0x3e,0x3f,0x01}
    clear(&chunk)
    array_header(&chunk,3,len(run),len(rle))
    append(&chunk,..rle)
    clear(&stream)
    block_put(&stream,chunk[:])
    check(t,stream[:],run)
}

@(test)
kraken_rejects_other_compressors_and_damaged_headers :: proc(t:^testing.T) {
    decoder,_:=decoder_make()
    defer decoder_destroy(&decoder)
    out:=make([]u8,64,context.temp_allocator)
    testing.expect_value(t,decode(&decoder,{0x0c,0x0b,0,0,0},out),Error.Unsupported)
    testing.expect_value(t,decode(&decoder,{0x0d,0x06,0,0,0},out),Error.Malformed)
    testing.expect_value(t,decode(&decoder,{0x0c},out),Error.Truncated)
    testing.expect_value(t,decode(nil,{0x0c,0x06},out),Error.Malformed)
}

// Any damage to a stream is decoded or refused, never a crash or a read or
// write outside the slices.
@(test)
kraken_damaged_streams_are_decoded_or_refused :: proc(t:^testing.T) {
    expected:=pattern(4096,11)
    lz_copy(expected,100,20,40)
    lz_copy(expected,300,100,300)
    ops:=[]Op{{literals=expected[8:100],offset=80,length=40,recent=3},{literals=expected[140:300],offset=200,length=300,recent=3}}
    streams:[3][dynamic]u8
    for &s in streams {s.allocator=context.temp_allocator}
    block_put(&streams[0],lz_chunk(expected,0,len(expected),ops,0))
    huffman:=make([]u8,len(expected),context.temp_allocator)
    for &value,i in huffman {value='a' if (i*13)%17<9 else 'b'}
    chunk:[dynamic]u8
    chunk.allocator=context.temp_allocator
    huffman_array(&chunk,huffman,'a','b')
    block_put(&streams[1],chunk[:])
    append(&streams[2],0x0c,0x86,0x07,0xff,0xff,0x5a)
    decoder,_:=decoder_make()
    defer decoder_destroy(&decoder)
    out:=make([]u8,len(expected),context.temp_allocator)
    refused:=0
    state:=u32(0x9e3779b9)
    for s in streams {
        source:=s[:]
        for length in 0..<len(source) {if decode(&decoder,source[:length],out)!=.None {refused+=1}}
        damaged:=make([]u8,len(source),context.temp_allocator)
        for position in 0..<len(source) {
            for value in ([3]u8{0,0xff,source[position]~0x55}) {
                copy(damaged,source)
                damaged[position]=value
                if decode(&decoder,damaged,out)!=.None {refused+=1}
            }
        }
        for _ in 0..<2000 {
            copy(damaged,source)
            for _ in 0..<4 {
                state=state*1664525+1013904223
                damaged[int(state>>8)%len(damaged)]=u8(state>>24)
            }
            if decode(&decoder,damaged,out)!=.None {refused+=1}
        }
    }
    for _ in 0..<2000 {
        noise:=make([]u8,64,context.temp_allocator)
        for &value in noise {state=state*1664525+1013904223;value=u8(state>>24)}
        noise[0]=0x0c
        noise[1]=0x06
        if decode(&decoder,noise,out)!=.None {refused+=1}
    }
    testing.expect(t,refused>0)
}

// Copies as LZ does: a byte at a time, so an overlap repeats the bytes just written.
@(private)
lz_copy :: proc(data:[]u8,to,from,count:int) {
    for i in 0..<count {data[to+i]=data[from+i]}
}

@(private)
array_header :: proc(out:^[dynamic]u8,kind,size,packed:int) {
    s:=size-1
    value:=(s&0x3fff)<<18|packed
    append(out,u8(kind<<4|s>>14),u8(value>>24),u8(value>>16),u8(value>>8),u8(value))
}

@(private)
Failing :: struct {owner:runtime.Allocator,remaining:int}

@(private)
failing_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Failing)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
kraken_decoder_make_releases_what_it_reserved_when_memory_runs_out :: proc(t:^testing.T) {
    for budget in 0..<8 {
        state:=Failing{owner=context.allocator,remaining=budget}
        decoder,error:=decoder_make(runtime.Allocator{failing_allocator,&state})
        testing.expect_value(t,error,runtime.Allocator_Error.Out_Of_Memory)
        testing.expect(t,decoder.literals==nil)
    }
    decoder,error:=decoder_make()
    testing.expect_value(t,error,runtime.Allocator_Error.None)
    decoder_destroy(&decoder)
}

// A quantum that repeats earlier output at a distance, and one stored after
// its checksum.
@(test)
kraken_whole_match_and_stored_quanta :: proc(t:^testing.T) {
    expected:=make([]u8,BLOCK_SIZE*2+1000,context.temp_allocator)
    copy(expected,pattern(BLOCK_SIZE,13))
    copy(expected[BLOCK_SIZE:],expected[:BLOCK_SIZE])
    copy(expected[2*BLOCK_SIZE:],pattern(1000,17))
    stream:[dynamic]u8
    stream.allocator=context.temp_allocator
    append(&stream,0x4c,0x06)
    append(&stream,..expected[:BLOCK_SIZE])
    // Distance BLOCK_SIZE: a word below 0x8000 and one byte of the 7 bit series.
    append(&stream,0x0c,0x06,0x03,0xff,0xff,0x7f,0xff,0x86)
    append(&stream,0x0c,0x86,0x0b,0xff,0xff,0,0,0)
    append(&stream,..expected[2*BLOCK_SIZE:])
    check(t,stream[:],expected)
    // A distance that reaches before the stream.
    decoder,_:=decoder_make()
    defer decoder_destroy(&decoder)
    out:=make([]u8,BLOCK_SIZE,context.temp_allocator)
    testing.expect_value(t,decode(&decoder,{0x0c,0x06,0x03,0xff,0xff,0x80,0x05},out),Error.Malformed)
}
