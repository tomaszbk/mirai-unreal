package kraken

// Entropy-coded byte arrays: the literals, commands, offsets and lengths of
// an LZ chunk. A header gives the kind and both sizes; the kinds are stored
// bytes, tANS, Huffman with three or six interleaved streams, RLE and arrays
// built from other arrays.

@(private)
Huffman :: struct {
    lengths:[2048]u8, // by the next 11 bits, least significant first
    symbols:[2048]u8,
}

// Decodes one array at src[at:] into out; returns the bytes read and written.
@(private)
bytes_decode :: proc(d:^Decoder,src:[]u8,at:int,out:[]u8,depth:=0) -> (read,written:int,error:Error) {
    if depth>8 {return 0,0,.Malformed}
    remaining:=len(src)-at
    if at<0 || remaining<2 {return 0,0,.Truncated}
    b0:=int(src[at])
    kind:=(b0>>4)&7
    if kind==0 {
        size,header:int
        if b0>=0x80 {
            size,header=(b0<<8|int(src[at+1]))&0xfff,2
        } else {
            if remaining<3 {return 0,0,.Truncated}
            size,header=b0<<16|int(src[at+1])<<8|int(src[at+2]),3
            if size>0x3ffff {return 0,0,.Malformed}
        }
        if size>len(out) || size>remaining-header {return 0,0,.Malformed}
        copy(out[:size],src[at+header:at+header+size])
        return header+size,size,nil
    }
    packed,size,header:int
    if b0>=0x80 {
        if remaining<4 {return 0,0,.Truncated}
        value:=b0<<16|int(src[at+1])<<8|int(src[at+2])
        packed=value&0x3ff
        size=packed+((value>>10)&0x3ff)+1
        header=3
    } else {
        if remaining<5 {return 0,0,.Truncated}
        value:=int(src[at+1])<<24|int(src[at+2])<<16|int(src[at+3])<<8|int(src[at+4])
        packed=value&0x3ffff
        size=((value>>18)|(b0<<14))&0x3ffff+1
        header=5
        if packed>=size {return 0,0,.Malformed}
    }
    if packed>remaining-header || size>len(out) {return 0,0,.Malformed}
    body:=src[at+header:at+header+packed]
    used:int
    switch kind {
    case 1:used,error=tans_decode(d,body,out[:size])
    case 2,4:used,error=huffman_decode(d,body,out[:size],kind>>1)
    case 3:used,error=rle_decode(d,body,out[:size],depth)
    case 5:used,error=arrays_decode(d,body,out[:size],depth)
    case:return 0,0,.Malformed
    }
    if error!=nil {return 0,0,error}
    if used!=packed {return 0,0,.Malformed}
    return header+packed,size,nil
}

// The decoded size an array header at src[at:] gives, without decoding it.
@(private)
bytes_size :: proc(src:[]u8,at:int) -> (size:int,error:Error) {
    remaining:=len(src)-at
    if at<0 || remaining<2 {return 0,.Truncated}
    b0:=int(src[at])
    kind:=(b0>>4)&7
    if kind==0 {
        if b0>=0x80 {return (b0<<8|int(src[at+1]))&0xfff,nil}
        if remaining<3 {return 0,.Truncated}
        return b0<<16|int(src[at+1])<<8|int(src[at+2]),nil
    }
    if kind>5 {return 0,.Malformed}
    if b0>=0x80 {
        if remaining<3 {return 0,.Truncated}
        value:=b0<<16|int(src[at+1])<<8|int(src[at+2])
        return value&0x3ff+((value>>10)&0x3ff)+1,nil
    }
    if remaining<5 {return 0,.Truncated}
    value:=int(src[at+1])<<24|int(src[at+2])<<16|int(src[at+3])<<8|int(src[at+4])
    return ((value>>18)|(b0<<14))&0x3ffff+1,nil
}

// Decodes the array at src[at:] into the next free bytes of the scratch,
// which stay taken until the caller gives them back.
@(private)
bytes_decode_temp :: proc(d:^Decoder,src:[]u8,at,limit:int,depth:int) -> (read:int,out:[]u8,error:Error) {
    size:=bytes_size(src,at) or_return
    if size>limit || size>len(d.temp)-d.temp_used {return 0,nil,.Malformed}
    out=d.temp[d.temp_used:][:size]
    d.temp_used+=size
    n,w:=bytes_decode(d,src,at,out,depth+1) or_return
    if w!=size {return 0,nil,.Malformed}
    return n,out,nil
}

// Several arrays one after another that fill the output, or with the top
// bit of the count, one array built from intervals of others.
@(private)
arrays_decode :: proc(d:^Decoder,src:[]u8,out:[]u8,depth:int) -> (read:int,error:Error) {
    if len(src)<6 {return 0,.Truncated}
    count:=int(src[0]&0x7f)
    if count<2 {return 0,.Malformed}
    if src[0]&0x80!=0 {
        arrays:[1][]u8
        n,w:=multi_arrays_decode(d,src,out,arrays[:],depth) or_return
        if w!=len(out) {return 0,.Malformed}
        return n,nil
    }
    at,written:=1,0
    for _ in 0..<count {
        n,w:=bytes_decode(d,src,at,out[written:],depth+1) or_return
        at+=n
        written+=w
    }
    if written!=len(out) {return 0,.Malformed}
    return at,nil
}

// len(arrays) arrays laid one after another in out. Either they follow as
// they are, or a list of intervals cuts them from other arrays: an index
// picks an array (zero ends the output array) and a length of variable bits
// says how many of its next bytes to take. The lengths alternate between a
// stream read forward and one read backward from the end of their section.
@(private)
multi_arrays_decode :: proc(d:^Decoder,src:[]u8,out:[]u8,arrays:[][]u8,depth:int) -> (read,written:int,error:Error) {
    if depth>8 {return 0,0,.Malformed}
    if len(src)<4 {return 0,0,.Truncated}
    if src[0]&0x80==0 {return 0,0,.Malformed}
    sources:=int(src[0]&0x3f)
    at:=1
    if sources==0 {
        for &array in arrays {
            n,w:=bytes_decode(d,src,at,out[written:],depth+1) or_return
            array=out[written:written+w]
            at+=n
            written+=w
        }
        return at,written,nil
    }
    mark:=d.temp_used
    defer d.temp_used=mark
    parts:[63][]u8
    total:=0
    for i in 0..<sources {
        n:int
        n,parts[i]=bytes_decode_temp(d,src,at,len(out)-total,depth) or_return
        at+=n
        total+=len(parts[i])
    }
    if len(src)-at<3 {return 0,0,.Truncated}
    q:=int(src[at])|int(src[at+1])<<8
    at+=2
    // With the top bit of q each index byte carries its length size in the
    // high nibble, the ends included; without it the sizes are an array of
    // their own, one for each index that is not an end.
    combined:=q&0x8000!=0
    n:int
    indexes,sizes:[]u8
    n,indexes=bytes_decode_temp(d,src,at,total,depth) or_return
    at+=n
    lengths:=len(indexes)-len(arrays)
    if lengths<1 {return 0,0,.Malformed}
    if combined {
        lengths=len(indexes)
    } else {
        n,sizes=bytes_decode_temp(d,src,at,lengths,depth) or_return
        at+=n
        if len(sizes)!=lengths {return 0,0,.Malformed}
        for size in sizes {if size>16 {return 0,0,.Malformed}}
    }
    section:=q&0x3fff
    if len(src)-at<section {return 0,0,.Truncated}
    if indexes[len(indexes)-1]&(0xf if combined else 0xff)!=0 {return 0,0,.Malformed}
    streams:=[2]Msb_Bits{msb_forward(src,at,at+section),msb_backward(src,at,at+section)}
    next,length:=0,0
    for &array in arrays {
        start:=written
        for {
            if next>=len(indexes) {return 0,0,.Malformed}
            index:=int(indexes[next])
            next+=1
            source:=index&0xf if combined else index
            if source==0 {break}
            if source>sources || length>=lengths {return 0,0,.Malformed}
            size:=index>>4 if combined else int(sizes[length])
            count:=int(interval_read(&streams[length&1],size))
            length+=1
            part:=&parts[source-1]
            if count>len(part^) || count>len(out)-written {return 0,0,.Malformed}
            copy(out[written:written+count],part^[:count])
            part^=part^[count:]
            written+=count
        }
        if combined {
            // The size an end carries still has its bits.
            if length>=lengths {return 0,0,.Malformed}
            _=interval_read(&streams[length&1],int(indexes[next-1]>>4))
            length+=1
        }
        array=out[start:written]
    }
    if next!=len(indexes) || length!=lengths {return 0,0,.Malformed}
    for part in parts[:sources] {if len(part)!=0 {return 0,0,.Malformed}}
    if msb_position(&streams[0])>msb_position(&streams[1]) {return 0,0,.Malformed}
    return at+section,written,nil
}

// A value of 1 to 2^(size+1)-1: a one bit above size bits.
@(private)
interval_read :: #force_inline proc(r:^Msb_Bits,size:int) -> u32 {
    msb_refill(r)
    value:=msb_take(r,size)|u32(1)<<uint(size)
    msb_refill(r)
    return value
}

// Runs of a byte and copies from a command stream that is read from both
// ends: copies from the front, commands from the back.
@(private)
rle_decode :: proc(d:^Decoder,src:[]u8,out:[]u8,depth:int) -> (read:int,error:Error) {
    if len(src)<=1 {
        if len(src)!=1 {return 0,.Truncated}
        for &value in out {value=src[0]}
        return 1,nil
    }
    commands:=src[1:]
    mark:=d.temp_used
    defer d.temp_used=mark
    if src[0]!=0 {
        // The front of the command stream is itself entropy coded.
        size:=bytes_size(src,0) or_return
        n:int
        prefix:[]u8
        n,prefix=bytes_decode_temp(d,src,0,len(d.temp),depth) or_return
        if n<=0 || len(src)-n>len(d.temp)-d.temp_used {return 0,.Malformed}
        rest:=d.temp[d.temp_used:][:len(src)-n]
        copy(rest,src[n:])
        commands=d.temp[d.temp_used-size:][:size+len(rest)]
        d.temp_used+=len(rest)
    }
    front,back,o:=0,len(commands),0
    run:u8
    for front<back {
        command:=int(commands[back-1])
        if command==0 || command-1>=0x2f {
            back-=1
            copies:=(-1-command)&0xf
            runs:=command>>4
            if len(out)-o<copies+runs || back-front<copies {return 0,.Malformed}
            copy(out[o:o+copies],commands[front:front+copies])
            front+=copies
            o+=copies
            fill(out[o:o+runs],run)
            o+=runs
        } else if command>=0x10 {
            if back-front<2 {return 0,.Malformed}
            value:=(int(commands[back-2])|int(commands[back-1])<<8)-4096
            back-=2
            copies:=value&0x3f
            runs:=value>>6
            if value<0 || len(out)-o<copies+runs || back-front<copies {return 0,.Malformed}
            copy(out[o:o+copies],commands[front:front+copies])
            front+=copies
            o+=copies
            fill(out[o:o+runs],run)
            o+=runs
        } else if command==1 {
            if back-front<2 {return 0,.Malformed}
            run=commands[front]
            front+=1
            back-=1
        } else if command>=9 {
            if back-front<2 {return 0,.Malformed}
            runs:=((int(commands[back-2])|int(commands[back-1])<<8)-0x8ff)*128
            back-=2
            if runs<0 || len(out)-o<runs {return 0,.Malformed}
            fill(out[o:o+runs],run)
            o+=runs
        } else {
            if back-front<2 {return 0,.Malformed}
            copies:=((int(commands[back-2])|int(commands[back-1])<<8)-511)*64
            back-=2
            if copies<0 || back-front<copies || len(out)-o<copies {return 0,.Malformed}
            copy(out[o:o+copies],commands[front:front+copies])
            front+=copies
            o+=copies
        }
    }
    if front!=back || o!=len(out) {return 0,.Malformed}
    return len(src),nil
}

@(private)
fill :: #force_inline proc(out:[]u8,value:u8) {
    if len(out)>0 {
        out[0]=value
        for n:=1;n<len(out);n*=2 {copy(out[n:],out[:n])}
    }
}

// Code lengths, then one set (kind 1) or two halves (kind 2) of three
// interleaved streams: forward, backward from the end and forward from the middle.
@(private)
huffman_decode :: proc(d:^Decoder,src:[]u8,out:[]u8,kind:int) -> (read:int,error:Error) {
    syms:[1280]u8
    prefix:=CODE_PREFIX
    r:=msb_forward(src,0,len(src))
    count:int
    if msb_take(&r,1)==0 {
        count=code_lengths_old(&r,syms[:],&prefix) or_return
    } else if msb_take(&r,1)==0 {
        count=code_lengths_new(&r,syms[:],&prefix) or_return
    } else {
        return 0,.Malformed
    }
    at:=msb_position(&r)
    if at>len(src) {return 0,.Truncated}
    if count==1 {
        fill(out,syms[0])
        return at,nil
    }
    huffman_table(&d.huffman,&prefix,syms[:]) or_return
    if kind==1 {
        if at+3>len(src) {return 0,.Truncated}
        split:=int(src[at])|int(src[at+1])<<8
        at+=2
        if len(src)-at<split+2 {return 0,.Malformed}
        streams_decode(&d.huffman,src,at,at+split,len(src),out) or_return
        return len(src),nil
    }
    if at+6>len(src) {return 0,.Truncated}
    half:=(len(out)+1)>>1
    split:=int(src[at])|int(src[at+1])<<8|int(src[at+2])<<16
    at+=3
    if split>len(src)-at {return 0,.Malformed}
    middle:=at+split
    left:=int(src[at])|int(src[at+1])<<8
    at+=2
    if middle-at<left+2 || len(src)-middle<3 {return 0,.Malformed}
    right:=int(src[middle])|int(src[middle+1])<<8
    if len(src)-(middle+2)<right+2 {return 0,.Malformed}
    streams_decode(&d.huffman,src,at,at+left,middle,out[:half]) or_return
    streams_decode(&d.huffman,src,middle+2,middle+2+right,len(src),out[half:]) or_return
    return len(src),nil
}

// Where the symbols of each code length start in the symbol list.
@(private)
CODE_PREFIX :: [12]u32{0,0,0x2,0x6,0xe,0x1e,0x3e,0x7e,0xfe,0x1fe,0x2fe,0x3fe}

@(private)
code_lengths_old :: proc(r:^Msb_Bits,syms:[]u8,prefix:^[12]u32) -> (count:int,error:Error) {
    if msb_take(r,1)!=0 {
        average:=32
        forced:=int(msb_take(r,2))
        threshold:=u32(1)<<uint(31-(20>>uint(forced)))
        skip_zeros:=msb_bit(r)==1
        symbol:=0
        for {
            if !skip_zeros {
                if r.bits&0xff000000==0 {return 0,.Malformed}
                symbol+=int(msb_take(r,2*(leading_zeros(r.bits)+1)))-2+1
                if symbol>=256 {break}
            }
            skip_zeros=false
            msb_refill(r)
            if r.bits&0xff000000==0 {return 0,.Malformed}
            n:=int(msb_take(r,2*(leading_zeros(r.bits)+1)))-2+1
            if symbol+n>256 {return 0,.Malformed}
            msb_refill(r)
            count+=n
            for _ in 0..<n {
                if r.bits<threshold {return 0,.Malformed}
                zeros:=leading_zeros(r.bits)
                v:=int(msb_take(r,zeros+forced+1))+((zeros-1)<<uint(forced))
                length:=(-(v&1)~(v>>1))+((average+2)>>2)
                if length<1 || length>11 {return 0,.Malformed}
                average=length+((3*average+2)>>2)
                msb_refill(r)
                if prefix[length]>=u32(len(syms)) {return 0,.Malformed}
                syms[prefix[length]]=u8(symbol)
                prefix[length]+=1
                symbol+=1
            }
            if symbol==256 {break}
        }
        if symbol!=256 || count<2 {return 0,.Malformed}
        return count,nil
    }
    // A short list of symbols, each with its length.
    count=int(msb_take(r,8))
    if count==0 {return 0,.Malformed}
    if count==1 {
        syms[0]=u8(msb_take(r,8))
        return 1,nil
    }
    length_bits:=int(msb_take(r,3))
    if length_bits>4 {return 0,.Malformed}
    for _ in 0..<count {
        msb_refill(r)
        symbol:=u8(msb_take(r,8))
        length:=int(msb_take(r,length_bits))+1
        if length>11 || prefix[length]>=u32(len(syms)) {return 0,.Malformed}
        syms[prefix[length]]=symbol
        prefix[length]+=1
    }
    return count,nil
}

@(private)
code_lengths_new :: proc(r:^Msb_Bits,syms:[]u8,prefix:^[12]u32) -> (count:int,error:Error) {
    forced:=int(msb_take(r,2))
    count=int(msb_take(r,8))+1
    fluff:=fluff_read(r,count)
    lengths:[512+16]u8
    if count+fluff>512 {return 0,.Malformed}
    c:=cursor_of(r)
    rice_read(r.data,&c,lengths[:count+fluff]) or_return
    if forced>0 {
        for i in 0..<count {
            value:=int(lengths[i])
            for _ in 0..<forced {value=value<<1|int(cursor_bit(r.data,&c) or_return)}
            lengths[i]=u8(value)
        }
    }
    msb_seat(r,c)
    sum:=u32(0x1e)
    for i in 0..<count {
        v:=int(lengths[i])
        v=-(v&1)~(v>>1)
        length:=v+int(sum>>2)+1
        if length<1 || length>11 {return 0,.Malformed}
        lengths[i]=u8(length)
        sum=u32(i64(sum)+i64(v))
    }
    symbols:Symbol_Ranges
    ranges_read(r,lengths[count:count+fluff],count,&symbols) or_return
    next:=0
    for i in 0..<symbols.count {
        for s in symbols.starts[i]..<symbols.starts[i]+symbols.sizes[i] {
            length:=lengths[next]
            next+=1
            if prefix[length]>=u32(len(syms)) {return 0,.Malformed}
            syms[prefix[length]]=u8(s)
            prefix[length]+=1
        }
    }
    return count,nil
}

// How many values follow the count of symbols: a truncated binary number
// below twice the smaller of count and 257-count.
@(private)
fluff_read :: proc(r:^Msb_Bits,count:int) -> int {
    if count==256 {return 0}
    msb_refill(r)
    x:=min(257-count,count)*2
    y:=32-leading_zeros(u32(x-1))
    v:=int(r.bits>>uint(32-y))
    z:=(1<<uint(y))-x
    if v>>1>=z {
        _=msb_take(r,y)
        return v-z
    }
    _=msb_take(r,y-1)
    return v>>1
}

// A bit position for reads one bit at a time.
@(private)
Bit_Cursor :: struct {at,bit:int}

// The next unread bit of r.
@(private)
cursor_of :: proc(r:^Msb_Bits) -> Bit_Cursor {
    at:=msb_position(r)
    bit:=(r.bitpos-24)&7
    if bit!=0 {at-=1}
    return {at,bit}
}

@(private)
cursor_bit :: #force_inline proc(data:[]u8,c:^Bit_Cursor) -> (bit:u32,error:Error) {
    if c.at>=len(data) {return 0,.Truncated}
    bit=u32(data[c.at]>>uint(7-c.bit))&1
    c.bit+=1
    if c.bit==8 {c.bit=0;c.at+=1}
    return
}

// Golomb-Rice values, most significant bit first: zeros up to a one.
@(private)
rice_read :: proc(data:[]u8,c:^Bit_Cursor,values:[]u8) -> Error {
    for &value in values {
        zeros:=0
        for {
            bit:=cursor_bit(data,c) or_return
            if bit!=0 {break}
            zeros+=1
            if zeros>255 {return .Malformed}
        }
        value=u8(zeros)
    }
    return nil
}

// r reads on from the cursor.
@(private)
msb_seat :: proc(r:^Msb_Bits,c:Bit_Cursor) {
    r^=msb_forward(r.data,c.at,r.limit)
    _=msb_take(r,c.bit)
    msb_refill(r)
}

// The symbols of a code: ranges separated by gaps, whose sizes and gaps
// come from the values after the code lengths; the last range takes the
// symbols left.
@(private)
Symbol_Ranges :: struct {
    starts,sizes:[129]int,
    count:int,
}

@(private)
ranges_read :: proc(r:^Msb_Bits,extra:[]u8,count:int,out:^Symbol_Ranges) -> Error {
    extra:=extra
    ranges:=len(extra)>>1
    symbol,used:=0,0
    if len(extra)&1!=0 {
        msb_refill(r)
        v:=int(extra[0])
        extra=extra[1:]
        if v>=8 {return .Malformed}
        symbol=int(msb_take(r,v+1))+(1<<uint(v+1))-1
    }
    if ranges>128 {return .Malformed}
    for i in 0..<ranges {
        msb_refill(r)
        v:=int(extra[0])
        if v>=9 {return .Malformed}
        n:=int(msb_take(r,v))+(1<<uint(v))
        v=int(extra[1])
        if v>=8 {return .Malformed}
        space:=int(msb_take(r,v+1))+(1<<uint(v+1))-1
        out.starts[i],out.sizes[i]=symbol,n
        used+=n
        symbol+=n+space
        extra=extra[2:]
    }
    if symbol>=256 || used>=count || symbol+count-used>256 {return .Malformed}
    out.starts[ranges],out.sizes[ranges]=symbol,count-used
    out.count=ranges+1
    msb_refill(r)
    return nil
}

// Canonical codes by length, shortest first, in the order of the symbol list.
@(private)
huffman_table :: proc(h:^Huffman,prefix:^[12]u32,syms:[]u8) -> Error {
    origin:=CODE_PREFIX
    slot:=u32(0)
    for length in 1..=11 {
        start:=origin[length]
        count:=prefix[length]-start
        if count==0 {continue}
        step:=u32(1)<<uint(11-length)
        if slot+count*step>2048 || start+count>u32(len(syms)) {return .Malformed}
        // Every code of this length fills the slots whose low bits are its bits reversed.
        for j in 0..<count {
            code:=bit_reverse_11(slot+j*step)
            for k in 0..<step {
                index:=code|k<<uint(length)
                h.lengths[index]=u8(length)
                h.symbols[index]=syms[start+j]
            }
        }
        slot+=count*step
    }
    if slot!=2048 {return .Malformed}
    return nil
}

@(private)
bit_reverse_11 :: #force_inline proc(value:u32) -> u32 {
    reversed:=u32(0)
    for b in 0..<u32(11) {reversed|=((value>>b)&1)<<(10-b)}
    return reversed
}

// Symbols alternate between the three streams: a reads [start,middle)
// forward, b reads [middle,end) backward and c reads it forward. a must end
// at middle and b and c must meet.
@(private)
streams_decode :: proc(h:^Huffman,src:[]u8,start,middle,end:int,out:[]u8) -> Error #no_bounds_check {
    if start>middle || middle>end || end>len(src) || start<0 {return .Malformed}
    a:=Lsb_Bits{data=src,at=start,limit=middle}
    b:=Lsb_Bits{data=src,at=end,limit=middle,backward=true}
    c:=Lsb_Bits{data=src,at=middle,limit=end}
    n:=len(out)
    i:=0
    // A symbol takes at most 11 bits; a refill leaves more than 56, enough for five rounds.
    for n-i>=15 {
        lsb_refill(&a)
        lsb_refill(&b)
        lsb_refill(&c)
        #unroll for k in 0..<5 {
            out[i+3*k]=huffman_symbol(h,&a)
            out[i+3*k+1]=huffman_symbol(h,&b)
            out[i+3*k+2]=huffman_symbol(h,&c)
        }
        i+=15
    }
    readers:=[3]^Lsb_Bits{&a,&b,&c}
    for k in 0..<n-i {
        lsb_refill(readers[k%3])
        out[i+k]=huffman_symbol(h,readers[k%3])
    }
    a_end:=lsb_position(&a,start)
    b_end:=lsb_position(&b,end)
    c_end:=lsb_position(&c,middle)
    if a_end!=middle || b_end!=c_end {return .Malformed}
    return nil
}

@(private)
huffman_symbol :: #force_inline proc(h:^Huffman,r:^Lsb_Bits) -> u8 #no_bounds_check {
    index:=r.bits&0x7ff
    length:=uint(h.lengths[index])
    r.bits>>=length
    r.count-=int(length)
    return h.symbols[index]
}
