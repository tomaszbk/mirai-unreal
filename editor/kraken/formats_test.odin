package kraken

import "core:testing"

// Encoders of tANS arrays, multi-arrays and Mermaid and Leviathan chunks for
// the tests: the smallest choices that reach every case of the decoder.

@(private="file")
Lsb_Writer :: struct {bytes:[dynamic]u8,count:int}

@(private="file")
lsb_put :: proc(w:^Lsb_Writer,value:u32,n:int) {
    for i in 0..<n {
        if w.count%8==0 {append(&w.bytes,0)}
        if (value>>uint(i))&1!=0 {w.bytes[len(w.bytes)-1]|=u8(1)<<uint(w.count%8)}
        w.count+=1
    }
}

@(private="file")
writer :: proc() -> Bit_Writer {
    w:Bit_Writer
    w.bytes.allocator=context.temp_allocator
    return w
}

@(private="file")
lsb_writer :: proc() -> Lsb_Writer {
    w:Lsb_Writer
    w.bytes.allocator=context.temp_allocator
    return w
}

@(private="file")
bytes :: proc() -> [dynamic]u8 {return make([dynamic]u8,context.temp_allocator)}

// Weights proportional to the counts of data that sum to 2^l_bits.
@(private="file")
tans_normalize :: proc(data:[]u8,l_bits:int) -> (weights:[256]int) {
    counts:[256]int
    for value in data {counts[value]+=1}
    total:=1<<uint(l_bits)
    sum,largest:=0,0
    for count,symbol in counts {
        if count==0 {continue}
        weights[symbol]=max(1,count*total/len(data))
        sum+=weights[symbol]
        if weights[symbol]>weights[largest] {largest=symbol}
    }
    weights[largest]+=total-sum
    return
}

// One weight in the Golomb-Rice form: its value and the bits that follow the values.
@(private="file")
Rice_Weight :: struct {rice:u8,extra,bits:int}

@(private="file")
rice_weights :: proc(weights:[]int,q:int) -> []Rice_Weight {
    out:=make([]Rice_Weight,len(weights),context.temp_allocator)
    average:=6
    for weight,i in weights {
        t:=weight-1
        quarter:=average>>2
        limit:=2*quarter
        v:=t
        if t<=limit {
            delta:=t-quarter
            v=2*delta if delta>=0 else -2*delta-1
        }
        extra:=bit_length(u32(v+(1<<uint(q))))-1
        out[i]={rice=u8(extra-q),extra=extra,bits=v+(1<<uint(q))-(1<<uint(extra))}
        average+=min(limit,t)-quarter
    }
    return out
}

@(private="file")
rice_put :: proc(w:^Bit_Writer,value:int) {
    bits_put(w,0,value)
    bits_put(w,1,1)
}

// The truncated binary count of values after the symbol values.
@(private="file")
fluff_put :: proc(w:^Bit_Writer,count,fluff:int) {
    if count==256 {return}
    x:=min(257-count,count)*2
    y:=bit_length(u32(x-1))
    z:=(1<<uint(y))-x
    if fluff<z {bits_put(w,u32(fluff),y-1)} else {bits_put(w,u32(fluff+z),y)}
}

// The table of a tANS array: explicit lists the weights (at most nine
// symbols, increasing weights with the largest last), else Golomb-Rice
// values over ranges of the symbols.
@(private="file")
tans_table_put :: proc(w:^Bit_Writer,weights:[256]int,l_bits:int,explicit:bool) {
    bits_put(w,0,1)
    bits_put(w,u32(l_bits-8),2)
    symbols:[dynamic]int
    symbols.allocator=context.temp_allocator
    for weight,symbol in weights {if weight>0 {append(&symbols,symbol)}}
    if explicit {
        bits_put(w,0,1)
        last:=symbols[0]
        for s in symbols {if weights[s]>weights[last] {last=s}}
        listed:[dynamic]int
        listed.allocator=context.temp_allocator
        for s in symbols {if s!=last {append(&listed,s)}}
        for i in 1..<len(listed) {
            for j:=i;j>0 && weights[listed[j-1]]>weights[listed[j]];j-=1 {listed[j-1],listed[j]=listed[j],listed[j-1]}
        }
        bits_put(w,u32(len(listed)-1),3)
        step_bits:=bit_length(u32(l_bits))
        bits_put(w,3,step_bits)
        previous:=0
        for s in listed {
            bits_put(w,u32(s),8)
            bits_put(w,u32(weights[s]-previous),3)
            previous=weights[s]
        }
        bits_put(w,u32(last),8)
        return
    }
    bits_put(w,1,1)
    q:=2
    bits_put(w,u32(q),3)
    count:=len(symbols)
    bits_put(w,u32(count-1),8)
    // Ranges: a start when the first symbol is not 0, then each range but the last and its gap.
    extras:[dynamic]int
    extras.allocator=context.temp_allocator
    range_bits:=writer()
    if symbols[0]>0 {
        v:=bit_length(u32(symbols[0]+1))-2
        append(&extras,v)
        bits_put(&range_bits,u32(symbols[0]+1-(1<<uint(v+1))),v+1)
    }
    run_start:=0
    for i in 1..<count {
        if symbols[i]==symbols[i-1]+1 {continue}
        n:=i-run_start
        space:=symbols[i]-symbols[i-1]-1
        vn:=bit_length(u32(n))-1
        vs:=bit_length(u32(space+1))-2
        append(&extras,vn,vs)
        bits_put(&range_bits,u32(n-(1<<uint(vn))),vn)
        bits_put(&range_bits,u32(space+1-(1<<uint(vs+1))),vs+1)
        run_start=i
    }
    fluff_put(w,count,len(extras))
    listed:=make([]int,count,context.temp_allocator)
    for s,i in symbols {listed[i]=weights[s]}
    rice:=rice_weights(listed,q)
    for r in rice {rice_put(w,int(r.rice))}
    for e in extras {rice_put(w,e)}
    for i in 0..<range_bits.count {bits_put(w,u32(range_bits.bytes[i/8]>>uint(7-i%8))&1,1)}
    for r in rice {bits_put(w,u32(r.bits),r.extra)}
}

// A tANS array of data, the table built as the decoder builds it and the
// symbols coded backward from the last five bytes.
@(private="file")
tans_array :: proc(out:^[dynamic]u8,data:[]u8,l_bits:int,explicit:bool) {
    n:=len(data)-5
    weights:=tans_normalize(data[:n],l_bits)
    if explicit {
        // Weights of 1, 3 and 5, and the rest for the common symbol.
        weights={}
        weights['x'],weights['w'],weights['y']=1,3,5
        weights['a']=(1<<uint(l_bits))-9
    }
    table:=writer()
    tans_table_put(&table,weights,l_bits,explicit)
    lut:[TANS_MAX]Tans_Entry
    listed:Tans_Weights
    for weight,symbol in weights {if weight>0 {tans_weight_add(&listed,symbol,weight)}}
    tans_table(&lut,l_bits,&listed)
    states:[5]int
    for k in 0..<5 {states[k]=int(data[n+k])}
    Pending :: struct {value,bits:int}
    pending:=make([]Pending,n,context.temp_allocator)
    for i:=n-1;i>=0;i-=1 {
        k:=i%5
        found:=false
        for e,slot in lut[:1<<uint(l_bits)] {
            if e.symbol==data[i] && int(e.w)<=states[k] && states[k]<int(e.w)+(1<<uint(e.bits)) {
                pending[i]={states[k]-int(e.w),int(e.bits)}
                states[k]=slot
                found=true
                break
            }
        }
        assert(found)
    }
    f,b:=lsb_writer(),lsb_writer()
    lsb_put(&f,u32(states[0]),l_bits)
    lsb_put(&b,u32(states[1]),l_bits)
    lsb_put(&f,u32(states[2]),l_bits)
    lsb_put(&b,u32(states[3]),l_bits)
    lsb_put(&f,u32(states[4]),l_bits)
    for p,i in pending {lsb_put(&f if (i/5)%2==0 else &b,u32(p.value),p.bits)}
    body:=bytes()
    append(&body,..table.bytes[:])
    append(&body,..f.bytes[:])
    for i:=len(b.bytes)-1;i>=0;i-=1 {append(&body,b.bytes[i])}
    array_header(out,1,len(data),len(body))
    append(out,..body[:])
}

@(private="file")
skewed :: proc(size:int,seed:u32) -> []u8 {
    out:=make([]u8,size,context.temp_allocator)
    state:=seed
    alphabet:=[]u8{'e','e','e','e','e','e','t','t','t','a','a','o','i','n','s','h','r','z',0,255}
    for &value in out {
        state=state*1664525+1013904223
        value=alphabet[int(state>>24)%len(alphabet)]
    }
    return out
}

@(test)
kraken_tans_arrays :: proc(t:^testing.T) {
    for explicit in ([2]bool{false,true}) {
        for l_bits in 8..=11 {
            data:=skewed(3000,u32(l_bits))
            // Rare symbols for weights of 1 to 4; without symbol 0 the ranges start further on.
            data[10]='Q'
            for i in 0..<3 {data[20+i*100]='K'}
            for i in 0..<6 {data[30+i*100]='J'}
            if l_bits&1!=0 {for &value in data {if value==0 {value='b'}}}
            if explicit {
                for &value in data {value='a'}
                data[100],data[200],data[300],data[400]='x','w','y','y'
            }
            chunk:=bytes()
            tans_array(&chunk,data,l_bits,explicit)
            stream:=bytes()
            block_put(&stream,chunk[:])
            check(t,stream[:],data)
        }
    }
}

// A multi-array that cuts its output from two arrays by intervals, with
// the length sizes in the index bytes or in an array of their own: one array
// is a run of a byte, the other stored bytes.
@(private="file")
multi_array :: proc(out:^[dynamic]u8,combined:bool) -> (data:[]u8) {
    Interval :: struct {source,length:int}
    intervals:=[]Interval{{1,5},{2,1},{1,300},{2,77},{1,1},{2,40},{1,2}}
    stored:=pattern(118,21)
    data=make([]u8,426,context.temp_allocator)
    at,taken:=0,0
    for interval in intervals {
        for i in 0..<interval.length {
            if interval.source==1 {data[at+i]='r'} else {data[at+i]=stored[taken];taken+=1}
        }
        at+=interval.length
    }
    assert(at==len(data) && taken==len(stored))
    body:=bytes()
    append(&body,0x80|2)
    array_header(&body,3,308,1)
    append(&body,'r')
    array_stored(&body,stored)
    indexes,sizes:=bytes(),bytes()
    f,b:=writer(),writer()
    values:[dynamic]int
    values.allocator=context.temp_allocator
    for interval in intervals {append(&values,interval.length)}
    if combined {append(&values,1)}
    for value,i in values {
        size:=bit_length(u32(value))-1
        bits_put(&f if i&1==0 else &b,u32(value-(1<<uint(size))),size)
        if !combined {append(&sizes,u8(size))}
        if i<len(intervals) {append(&indexes,u8(intervals[i].source)|(u8(size)<<4 if combined else 0))}
    }
    append(&indexes,0)
    section:=bytes()
    append(&section,..f.bytes[:])
    for i:=len(b.bytes)-1;i>=0;i-=1 {append(&section,b.bytes[i])}
    q:=len(section)|(0x8000 if combined else 0)
    append(&body,u8(q),u8(q>>8))
    array_stored(&body,indexes[:])
    if !combined {array_stored(&body,sizes[:])}
    append(&body,..section[:])
    array_header(out,5,len(data),len(body))
    append(out,..body[:])
    return
}

@(test)
kraken_multi_arrays :: proc(t:^testing.T) {
    for combined in ([2]bool{false,true}) {
        chunk:=bytes()
        data:=multi_array(&chunk,combined)
        stream:=bytes()
        block_put(&stream,chunk[:])
        check(t,stream[:],data)
    }
}

@(private="file")
Mermaid_Kind :: enum {Near,Recent,Far,Literals,Near_Long,Far_Long}

// literals bytes, then a match: Near takes a new 16 bit offset, Recent keeps
// the last one, Far takes a far one; the long forms take their length from
// the length bytes. Literals is a run of literals alone.
@(private="file")
Mermaid_Op :: struct {literals:int,kind:Mermaid_Kind,length,distance:int}

@(private="file")
length_byte_put :: proc(out:^[dynamic]u8,value:int) {
    if value<=251 {append(out,u8(value));return}
    b:=252+(value-252)%4
    rest:=(value-b)/4
    append(out,u8(b),u8(rest),u8(rest>>8))
}

// Applies the matches of ops to expected from start; the literals keep their bytes.
@(private="file")
mermaid_apply :: proc(expected:[]u8,start:int,ops:[]Mermaid_Op) -> (end:int) {
    o:=start+(8 if start==0 else 0)
    distance:=8
    for op in ops {
        o+=op.literals
        if op.kind==.Literals {continue}
        if op.kind!=.Recent {distance=op.distance}
        lz_copy(expected,o,o-distance,op.length)
        o+=op.length
    }
    return o
}

@(private="file")
Mermaid_Writer :: struct {
    expected:[]u8,
    start,o,last,mode:int,
    literals,lengths:[dynamic]u8,
    commands:[2][dynamic]u8,
    near:[dynamic]int,
    far:[2][dynamic]int,
}

@(private="file")
mermaid_literals :: proc(w:^Mermaid_Writer,count:int) {
    for i in 0..<count {append(&w.literals,w.expected[w.o+i]-(w.expected[w.o+i+w.last] if w.mode==0 else 0))}
    w.o+=count
}

// Literals with commands of their own: a run from 64, else up to seven with an empty match.
@(private="file")
mermaid_literal_commands :: proc(w:^Mermaid_Writer,half,count:int) {
    if count>=64 {
        append(&w.commands[half],0)
        length_byte_put(&w.lengths,count-64)
        mermaid_literals(w,count)
        return
    }
    for left:=count;left>0; {
        n:=min(left,7)
        append(&w.commands[half],u8(0x80|n))
        mermaid_literals(w,n)
        left-=n
    }
}

// A Mermaid chunk producing expected[start:start+count]. Literals before the
// half an op is in end the previous half; far distances count from the start
// of the half.
@(private="file")
mermaid_chunk :: proc(expected:[]u8,start,count:int,ops:[]Mermaid_Op,mode:int,near_coded:bool) -> []u8 {
    body:=bytes()
    w:=Mermaid_Writer{expected=expected,start=start,o=start,last=-8,mode=mode}
    w.literals,w.lengths=bytes(),bytes()
    for half in 0..<2 {w.commands[half]=bytes();w.far[half]=make([dynamic]int,context.temp_allocator)}
    w.near=make([dynamic]int,context.temp_allocator)
    if start==0 {append(&body,..expected[:8]);w.o=8}
    for op in ops {
        at:=w.o+op.literals if op.kind!=.Literals else w.o
        half:=(at-start)/MERMAID_HALF
        half_start:=start+half*MERMAID_HALF
        literals:=op.literals
        if w.o<half_start {
            literals-=half_start-w.o
            mermaid_literals(&w,half_start-w.o)
        }
        if op.kind==.Literals {
            mermaid_literal_commands(&w,half,literals)
            continue
        }
        inline:=(op.kind==.Near || op.kind==.Recent) && literals<8
        if !inline {mermaid_literal_commands(&w,half,literals);literals=0}
        mermaid_literals(&w,literals)
        switch op.kind {
        case .Near:
            append(&w.commands[half],u8(literals|op.length<<3))
            append(&w.near,op.distance)
            w.last= -op.distance
        case .Recent:
            append(&w.commands[half],u8(0x80|literals|op.length<<3))
        case .Far,.Far_Long:
            if op.kind==.Far {append(&w.commands[half],u8(op.length-5))} else {
                append(&w.commands[half],2)
                length_byte_put(&w.lengths,op.length-29)
            }
            append(&w.far[half],half_start-(w.o-op.distance))
            w.last= -op.distance
        case .Near_Long:
            append(&w.commands[half],1)
            length_byte_put(&w.lengths,op.length-91)
            append(&w.near,op.distance)
            w.last= -op.distance
        case .Literals:
        }
        w.o+=op.length
        assert((w.o-1-start)/MERMAID_HALF==half,"an op crosses a half")
    }
    mermaid_literals(&w,start+count-w.o)
    array_stored(&body,w.literals[:])
    all:=bytes()
    append(&all,..w.commands[0][:])
    append(&all,..w.commands[1][:])
    array_stored(&body,all[:])
    if count>MERMAID_HALF {append(&body,u8(len(w.commands[0])),u8(len(w.commands[0])>>8))}
    if near_coded {
        append(&body,0xff,0xff)
        high,low:=bytes(),bytes()
        for n in w.near {append(&high,u8(n>>8));append(&low,u8(n))}
        array_stored(&body,high[:])
        array_stored(&body,low[:])
    } else {
        append(&body,u8(len(w.near)),u8(len(w.near)>>8))
        for n in w.near {append(&body,u8(n),u8(n>>8))}
    }
    header:=len(w.far[0])<<12|len(w.far[1])
    append(&body,u8(header),u8(header>>8),u8(header>>16))
    for half in 0..<2 {
        for value in w.far[half] {
            append(&body,u8(value),u8(value>>8),u8(value>>16))
            if start+half*MERMAID_HALF>=0xc00000-1 && value>=0xc00000 {
                top:=(value-0xc00000)>>22
                low:=value-top<<22
                body[len(body)-3],body[len(body)-2],body[len(body)-1]=u8(low),u8(low>>8),u8(low>>16)
                append(&body,u8(top))
            }
        }
    }
    append(&body,..w.lengths[:])
    header=0x800000|mode<<19|len(body)
    out:=bytes()
    append(&out,u8(header>>16),u8(header>>8),u8(header))
    append(&out,..body[:])
    return out[:]
}

@(private="file")
mermaid_block :: proc(out:^[dynamic]u8,chunks:[]u8) {
    append(out,0x8c,MERMAID)
    packed:=len(chunks)-1
    append(out,u8(packed>>16),u8(packed>>8),u8(packed))
    append(out,..chunks)
}

@(test)
kraken_mermaid_chunks :: proc(t:^testing.T) {
    // One chunk over both halves, every command form, near offsets raw and coded, both literal modes.
    size:=CHUNK_SIZE
    for mode in 0..=1 {
        for near_coded in ([2]bool{false,true}) {
            expected:=pattern(size,31)
            ops:=make([dynamic]Mermaid_Op,context.temp_allocator)
            append(&ops,
                Mermaid_Op{literals=70,kind=.Literals},
                Mermaid_Op{literals=3,kind=.Near,length=9,distance=40},
                Mermaid_Op{literals=2,kind=.Recent,length=4},
                Mermaid_Op{kind=.Recent,length=0},
                Mermaid_Op{literals=1,kind=.Near_Long,length=400,distance=13},
                Mermaid_Op{literals=12,kind=.Near,length=15,distance=9},
                Mermaid_Op{literals=1300,kind=.Literals},
            )
            // The rest of the first half is literals; then matches behind the second half.
            o:=mermaid_apply(expected,0,ops[:])
            append(&ops,
                Mermaid_Op{literals=MERMAID_HALF+100-o,kind=.Far,length=8,distance=60000},
                Mermaid_Op{literals=0,kind=.Far_Long,length=1500,distance=3000},
                Mermaid_Op{literals=7,kind=.Near_Long,length=95,distance=1000},
                Mermaid_Op{literals=1,kind=.Far_Long,length=31,distance=MERMAID_HALF+500},
                Mermaid_Op{literals=6,kind=.Recent,length=3},
                Mermaid_Op{literals=9,kind=.Far,length=20,distance=8000},
            )
            expected=pattern(size,31)
            mermaid_apply(expected,0,ops[:])
            stream:=bytes()
            mermaid_block(&stream,mermaid_chunk(expected,0,size,ops[:],mode,near_coded))
            check(t,stream[:],expected)
        }
    }
    // A chunk after a stored block whose far offsets reach back into it.
    size=BLOCK_SIZE+2000
    expected:=pattern(size,33)
    ops:=[]Mermaid_Op{{literals=10,kind=.Far_Long,length=500,distance=BLOCK_SIZE-100},{literals=4,kind=.Near,length=12,distance=50000}}
    mermaid_apply(expected,BLOCK_SIZE,ops)
    stream:=bytes()
    append(&stream,0x4c,MERMAID)
    append(&stream,..expected[:BLOCK_SIZE])
    mermaid_block(&stream,mermaid_chunk(expected,BLOCK_SIZE,2000,ops,0,false))
    check(t,stream[:],expected)
}

// Past 12 MiB a far offset of 0xC00000 or more takes a fourth byte for its bits from 22.
@(test)
kraken_mermaid_far_offsets_past_12_mib_take_a_fourth_byte :: proc(t:^testing.T) {
    start:=0x1000000+BLOCK_SIZE
    size:=start+3000
    expected:=make([]u8,size,context.temp_allocator)
    for at:=0;at<start;at+=BLOCK_SIZE {copy(expected[at:],pattern(BLOCK_SIZE,u32(at/BLOCK_SIZE)))}
    copy(expected[start:],pattern(3000,99))
    ops:=[]Mermaid_Op{{literals=0,kind=.Far_Long,length=100,distance=0x1000000+77},{literals=3,kind=.Far,length=8,distance=5000}}
    mermaid_apply(expected,start,ops)
    stream:=make([dynamic]u8,context.temp_allocator)
    for at:=0;at<start;at+=BLOCK_SIZE {
        append(&stream,0x4c,MERMAID)
        append(&stream,..expected[at:at+BLOCK_SIZE])
    }
    mermaid_block(&stream,mermaid_chunk(expected,start,3000,ops,1,false))
    check(t,stream[:],expected)
}

@(private="file")
Leviathan_Op :: struct {literals,pick,distance,length:int} // pick 0..6 reuses a recent offset, 7 takes distance

// Applies ops to expected and returns the distance of each match.
@(private="file")
leviathan_apply :: proc(expected:[]u8,start:int,ops:[]Leviathan_Op) -> []int {
    distances:=make([]int,len(ops),context.temp_allocator)
    recent:=[8]int{8,8,8,8,8,8,8,0}
    o:=start+(8 if start==0 else 0)
    for op,i in ops {
        o+=op.literals
        recent[7]=op.distance
        distance:=recent[op.pick]
        for j:=op.pick;j>0;j-=1 {recent[j]=recent[j-1]}
        recent[0]=distance
        distances[i]=distance
        lz_copy(expected,o,o-distance,op.length)
        o+=op.length
    }
    return distances
}

// A Leviathan chunk of expected[start:start+count] with the literal arrays of mode.
@(private="file")
leviathan_chunk :: proc(expected:[]u8,start,count:int,ops:[]Leviathan_Op,mode:Literal_Mode,command_arrays:int) -> []u8 {
    distances:=leviathan_apply(expected,start,ops)
    arrays:=LITERAL_ARRAYS
    literals:[16][dynamic]u8
    for &l in literals {l.allocator=context.temp_allocator}
    put :: proc(literals:^[16][dynamic]u8,expected:[]u8,mode:Literal_Mode,start,o,count,last:int) {
        for p in o..<o+count {
            sub:=expected[p]-expected[p+last]
            switch mode {
            case .Sub:append(&literals[0],sub)
            case .Raw:append(&literals[0],expected[p])
            case .Lam_Sub:append(&literals[1 if p==o else 0],sub)
            case .Sub_And3:append(&literals[(p-start)&3],sub)
            case .Sub_AndF:append(&literals[(p-start)&15],sub)
            case .O1:append(&literals[expected[p-1]>>4],expected[p])
            }
        }
    }
    body:=bytes()
    o:=start
    if start==0 {append(&body,..expected[:8]);o=8}
    commands:[8][dynamic]u8
    for &c in commands {c.allocator=context.temp_allocator}
    codes,front,back:=bytes(),make([dynamic]int,context.temp_allocator),make([dynamic]int,context.temp_allocator)
    new_offsets:=make([dynamic]int,context.temp_allocator)
    last:=-8
    for op,i in ops {
        put(&literals,expected,mode,start,o,op.literals,last)
        literal_code:=op.literals
        if op.literals>=3 {literal_code=3;append(&front,op.literals)}
        match_code:=op.length-2
        if op.length>=9 {match_code=7;append(&back,op.length-6)}
        array:=(o-start)&7 if command_arrays>1 else 0
        append(&commands[array],u8(op.pick<<5|literal_code<<3|match_code))
        if op.pick==7 {append(&new_offsets,distances[i])}
        o+=op.literals+op.length
        last= -distances[i]
    }
    put(&literals,expected,mode,start,o,start+count-o,last)
    values:=make([dynamic]int,context.temp_allocator)
    append(&values,..front[:])
    for i:=len(back)-1;i>=0;i-=1 {append(&values,back[i])}
    longs:=make([dynamic]u32,context.temp_allocator)
    lengths:=bytes()
    for v in values {
        code:=v-3
        if code<255 {append(&lengths,u8(code))} else {append(&lengths,255);append(&longs,u32(code-255))}
    }
    a,b:=writer(),writer()
    gamma:=u32(len(longs)+1)
    bits_put(&b,0,bit_length(gamma)-1)
    bits_put(&b,gamma,bit_length(gamma))
    for distance,i in new_offsets {
        w:=&a if i&1==0 else &b
        v:=u32(distance+248)
        high:=v>>4
        n:=bit_length(high)-1
        append(&codes,u8((n-4)<<4)|u8(v&15))
        bits_put(w,high-(1<<uint(n)),n)
    }
    for long,i in longs {
        w:=&a if i&1==0 else &b
        value:=long+64
        n:=bit_length(value)
        bits_put(w,0,n-7)
        bits_put(w,value,n)
    }
    array_stored(&body,codes[:])
    array_stored(&body,lengths[:])
    if arrays[mode]==1 {
        array_stored(&body,literals[0][:])
    } else {
        append(&body,0x80)
        for l in literals[:arrays[mode]] {array_stored(&body,l[:])}
    }
    if command_arrays==1 {
        array_stored(&body,commands[0][:])
    } else {
        append(&body,0x83,0x80)
        for c in commands {array_stored(&body,c[:])}
    }
    append(&body,..a.bytes[:])
    for i:=len(b.bytes)-1;i>=0;i-=1 {append(&body,b.bytes[i])}
    header:=0x800000|int(mode)<<19|len(body)
    out:=bytes()
    append(&out,u8(header>>16),u8(header>>8),u8(header))
    append(&out,..body[:])
    return out[:]
}

@(private="file")
leviathan_block :: proc(out:^[dynamic]u8,chunks:[]u8) {
    append(out,0x8c,LEVIATHAN)
    packed:=len(chunks)-1
    append(out,u8(packed>>16),u8(packed>>8),u8(packed))
    append(out,..chunks)
}

@(private="file")
LEVIATHAN_OPS :: []Leviathan_Op{
    {literals=400,pick=7,distance=30,length=12},
    {literals=1,pick=7,distance=200,length=4},
    {literals=2,pick=1,length=9},
    {literals=0,pick=7,distance=9,length=300},
    {literals=5,pick=2,length=2},
    {literals=300,pick=7,distance=1000,length=8},
    {literals=3,pick=0,length=6},
    {literals=1,pick=7,distance=17,length=40},
    {literals=2,pick=4,length=3},
}

@(test)
kraken_leviathan_chunks :: proc(t:^testing.T) {
    for mode in Literal_Mode {
        for command_arrays in ([2]int{1,8}) {
            expected:=pattern(6000,41+u32(mode))
            stream:=bytes()
            leviathan_block(&stream,leviathan_chunk(expected,0,len(expected),LEVIATHAN_OPS,mode,command_arrays))
            testing.expectf(t,decode_matches(stream[:],expected),"mode %v with %d command arrays",mode,command_arrays)
        }
    }
    // A chunk after a stored block, whose matches reach into it.
    size:=BLOCK_SIZE+3000
    expected:=pattern(size,43)
    ops:=[]Leviathan_Op{{literals=5,pick=7,distance=BLOCK_SIZE-10,length=700},{literals=9,pick=7,distance=20,length=30}}
    stream:=bytes()
    append(&stream,0x4c,LEVIATHAN)
    append(&stream,..expected[:BLOCK_SIZE])
    leviathan_block(&stream,leviathan_chunk(expected,BLOCK_SIZE,3000,ops,.Sub_AndF,8))
    check(t,stream[:],expected)
}

@(private="file")
decode_matches :: proc(stream,expected:[]u8) -> bool {
    decoder,_:=decoder_make()
    defer decoder_destroy(&decoder)
    out:=make([]u8,len(expected),context.temp_allocator)
    return decode(&decoder,stream,out)==.None && string(out)==string(expected)
}

@(test)
kraken_rejects_the_excess_stream_and_other_compressors :: proc(t:^testing.T) {
    decoder,_:=decoder_make()
    defer decoder_destroy(&decoder)
    out:=make([]u8,64,context.temp_allocator)
    for compressor in ([]u8{5,11}) {
        testing.expect_value(t,decode(&decoder,{0x0c,compressor,0,0,0},out),Error.Unsupported)
    }
    chunk:=make([dynamic]u8,context.temp_allocator)
    append(&chunk,0x80,0x00,0x14)
    for i in 0..<8 {append(&chunk,u8(i))}
    append(&chunk,0x80)
    for _ in 0..<11 {append(&chunk,0)}
    stream:=bytes()
    block_put(&stream,chunk[:])
    testing.expect_value(t,decode(&decoder,stream[:],out),Error.Unsupported)
    stream[len(stream)-12]=0xc0
    testing.expect_value(t,decode(&decoder,stream[:],out),Error.Malformed)
}

// Every damaged form of these streams is decoded or refused without a read
// or write outside the slices.
@(test)
kraken_damaged_formats_are_decoded_or_refused :: proc(t:^testing.T) {
    streams:[dynamic][]u8
    streams.allocator=context.temp_allocator
    sizes:[dynamic]int
    sizes.allocator=context.temp_allocator
    {
        data:=skewed(800,7)
        chunk:=bytes()
        tans_array(&chunk,data,9,false)
        stream:=bytes()
        block_put(&stream,chunk[:])
        append(&streams,stream[:]);append(&sizes,len(data))
    }
    {
        chunk:=bytes()
        data:=multi_array(&chunk,true)
        stream:=bytes()
        block_put(&stream,chunk[:])
        append(&streams,stream[:]);append(&sizes,len(data))
    }
    {
        expected:=pattern(3000,37)
        ops:=[]Mermaid_Op{{literals=3,kind=.Near,length=9,distance=10},{literals=70,kind=.Literals},{literals=2,kind=.Far_Long,length=200,distance=92},{literals=1,kind=.Near_Long,length=100,distance=20}}
        mermaid_apply(expected,0,ops)
        stream:=bytes()
        mermaid_block(&stream,mermaid_chunk(expected,0,len(expected),ops,0,true))
        append(&streams,stream[:]);append(&sizes,len(expected))
    }
    for mode in ([]Literal_Mode{.Lam_Sub,.O1}) {
        expected:=pattern(2500,47)
        stream:=bytes()
        ops:=LEVIATHAN_OPS
        leviathan_block(&stream,leviathan_chunk(expected,0,len(expected),ops[:5],mode,8))
        append(&streams,stream[:]);append(&sizes,len(expected))
    }
    decoder,_:=decoder_make()
    defer decoder_destroy(&decoder)
    state:=u32(0x2545f491)
    for source,index in streams {
        out:=make([]u8,sizes[index],context.temp_allocator)
        testing.expect_value(t,decode(&decoder,source,out),Error.None)
        for length in 0..<len(source) {_=decode(&decoder,source[:length],out)}
        damaged:=make([]u8,len(source),context.temp_allocator)
        for position in 0..<len(source) {
            for value in ([3]u8{0,0xff,source[position]~0x55}) {
                copy(damaged,source)
                damaged[position]=value
                _=decode(&decoder,damaged,out)
            }
        }
        for _ in 0..<1000 {
            copy(damaged,source)
            for _ in 0..<4 {
                state=state*1664525+1013904223
                damaged[int(state>>8)%len(damaged)]=u8(state>>24)
            }
            _=decode(&decoder,damaged,out)
        }
    }
}
