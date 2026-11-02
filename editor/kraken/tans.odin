package kraken

// tANS arrays: a table of symbol weights that sum to 2^L, L from 8 to 11,
// then five interleaved states over two streams, least significant bit first:
// one read forward after the table and one backward from the end. Symbols
// take the states in turn, five from the forward stream and five from the
// backward one; the last five bytes are the final states.

@(private) TANS_MAX :: 1<<11

// A state gives its symbol and the next state: w plus the next bits.
@(private)
Tans_Entry :: struct {
    w:u16,
    bits,symbol:u8,
}

@(private)
Tans_Weights :: struct {
    ones:[256]u8,   // symbols of weight 1
    others:[256]u32, // symbol<<16 | weight, weights of 2 and more
    one_count,other_count:int,
}

@(private)
tans_decode :: proc(d:^Decoder,src:[]u8,out:[]u8) -> (read:int,error:Error) #no_bounds_check {
    if len(src)<8 || len(out)<5 {return 0,.Malformed}
    r:=msb_forward(src,0,len(src))
    if msb_take(&r,1)!=0 {return 0,.Malformed}
    l_bits:=int(msb_take(&r,2))+8
    weights:Tans_Weights
    tans_weights(&r,l_bits,&weights) or_return
    at:=msb_position(&r)
    if at>=len(src) {return 0,.Malformed}
    tans_table(&d.tans,l_bits,&weights)
    f:=Lsb_Bits{data=src,at=at,limit=len(src)}
    b:=Lsb_Bits{data=src,at=len(src),limit=at,backward=true}
    states:[5]u32
    lsb_refill(&f)
    lsb_refill(&b)
    states[0]=lsb_take(&f,l_bits)
    states[1]=lsb_take(&b,l_bits)
    states[2]=lsb_take(&f,l_bits)
    states[3]=lsb_take(&b,l_bits)
    lsb_refill(&f)
    states[4]=lsb_take(&f,l_bits)
    n:=len(out)-5
    lut:=&d.tans
    i:=0
    // Ten symbols a round; a refill leaves at least 56 bits, five states take at most 55.
    for n-i>=10 {
        lsb_refill(&f)
        for k in 0..<5 {
            e:=lut[states[k]]
            out[i+k]=e.symbol
            states[k]=u32(e.w)+lsb_take(&f,int(e.bits))
        }
        lsb_refill(&b)
        for k in 0..<5 {
            e:=lut[states[k]]
            out[i+5+k]=e.symbol
            states[k]=u32(e.w)+lsb_take(&b,int(e.bits))
        }
        i+=10
    }
    lsb_refill(&f)
    lsb_refill(&b)
    for k in 0..<n-i {
        e:=lut[states[k%5]]
        out[i+k]=e.symbol
        states[k%5]=u32(e.w)+lsb_take(&f if k<5 else &b,int(e.bits))
    }
    if lsb_position(&f,at)!=lsb_position(&b,len(src)) {return 0,.Malformed}
    for state,k in states {
        if state>0xff {return 0,.Malformed}
        out[n+k]=u8(state)
    }
    return len(src),nil
}

// The weights, in one of two forms: Golomb-Rice values that adapt to their
// running average over ranges of symbols, or a short list of symbols with
// increasing weights and one more that takes what is left.
@(private)
tans_weights :: proc(r:^Msb_Bits,l_bits:int,out:^Tans_Weights) -> Error {
    total:=1<<uint(l_bits)
    msb_refill(r)
    if msb_take(r,1)!=0 {
        q:=int(msb_take(r,3))
        count:=int(msb_take(r,8))+1
        if count<2 {return .Malformed}
        fluff:=fluff_read(r,count)
        if count+fluff>512 {return .Malformed}
        values:[512+16]u8
        c:=cursor_of(r)
        rice_read(r.data,&c,values[:count+fluff]) or_return
        msb_seat(r,c)
        symbols:Symbol_Ranges
        ranges_read(r,values[count:count+fluff],count,&symbols) or_return
        average,sum,next:=6,0,0
        for range in 0..<symbols.count {
            for symbol in symbols.starts[range]..<symbols.starts[range]+symbols.sizes[range] {
                msb_refill(r)
                extra:=q+int(values[next])
                next+=1
                if extra>15 {return .Malformed}
                v:=int(msb_take(r,extra))+(1<<uint(extra))-(1<<uint(q))
                quarter:=average>>2
                limit:=2*quarter
                if v<=limit {v=quarter+(-(v&1)~(v>>1))}
                limit=min(limit,v)
                weight:=v+1
                average+=limit-quarter
                tans_weight_add(out,symbol,weight)
                sum+=weight
                if sum>total {return .Malformed}
            }
        }
        if sum!=total {return .Malformed}
        return nil
    }
    seen:[256]bool
    count:=int(msb_take(r,3))+1
    // Bits of the largest step: the bit length of l_bits.
    max_step:=int(msb_take(r,32-leading_zeros(u32(l_bits))))
    if max_step==0 || max_step>l_bits {return .Malformed}
    weight,sum:=0,0
    for _ in 0..<count {
        msb_refill(r)
        symbol:=int(msb_take(r,8))
        if seen[symbol] {return .Malformed}
        weight+=int(msb_take(r,max_step))
        if weight==0 {return .Malformed}
        seen[symbol]=true
        tans_weight_add(out,symbol,weight)
        sum+=weight
    }
    msb_refill(r)
    symbol:=int(msb_take(r,8))
    if seen[symbol] {return .Malformed}
    rest:=total-sum
    if rest<weight || rest<=1 {return .Malformed}
    tans_weight_add(out,symbol,rest)
    // The list gives weights in increasing order; the table wants symbols in increasing order.
    for i in 1..<out.one_count {
        for j:=i;j>0 && out.ones[j-1]>out.ones[j];j-=1 {out.ones[j-1],out.ones[j]=out.ones[j],out.ones[j-1]}
    }
    for i in 1..<out.other_count {
        for j:=i;j>0 && out.others[j-1]>out.others[j];j-=1 {out.others[j-1],out.others[j]=out.others[j],out.others[j-1]}
    }
    return nil
}

@(private)
tans_weight_add :: #force_inline proc(out:^Tans_Weights,symbol,weight:int) {
    if weight==1 {
        out.ones[out.one_count]=u8(symbol)
        out.one_count+=1
    } else {
        out.others[out.other_count]=u32(symbol)<<16|u32(weight)
        out.other_count+=1
    }
}

// The states of a symbol of weight w are w to 2w-1, the next state of each
// takes the bits that bring it back to [2^L,2^(L+1)). Weights of 1 take the
// last states; the others are spread over four quarters of the rest in turn,
// starting where the previous symbol stopped.
@(private)
tans_table :: proc(lut:^[TANS_MAX]Tans_Entry,l_bits:int,weights:^Tans_Weights) {
    total:=1<<uint(l_bits)
    rest:=total-weights.one_count
    quarters:[4]int
    at:=0
    for j in 0..<4 {
        quarters[j]=at
        at+=rest>>2+(1 if rest&3>j else 0)
    }
    for symbol,i in weights.ones[:weights.one_count] {
        lut[rest+i]={w=0,bits=u8(l_bits),symbol=symbol}
    }
    sum:=0
    for packed in weights.others[:weights.other_count] {
        weight:=int(packed&0xffff)
        symbol:=u8(packed>>16)
        // Quarter j takes the turns t in [sum,sum+weight) with t%4==j, states in quarter order.
        state:=weight
        for j in 0..<4 {
            for _ in 0..<(weight+((sum-j-1)&3))>>2 {
                tans_entry(lut,&quarters[j],state,l_bits,symbol)
                state+=1
            }
        }
        sum+=weight
    }
}

@(private)
tans_entry :: #force_inline proc(lut:^[TANS_MAX]Tans_Entry,at:^int,state,l_bits:int,symbol:u8) {
    shift:=l_bits-(31-leading_zeros(u32(state)))
    total:=1<<uint(l_bits)
    lut[at^]={w=u16((state<<uint(shift))&(total-1)),bits=u8(shift),symbol=symbol}
    at^+=1
}
