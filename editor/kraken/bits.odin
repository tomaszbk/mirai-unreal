package kraken

import "base:intrinsics"

// Bit readers. Reading past the bytes of a stream gives zeros: a valid stream
// never needs them, and the checks at the end of each stream reject one that
// did, so no read leaves the slice.

// Most significant bit first, at least 24 bits loaded after a refill. Forward
// streams read bytes up from at; backward streams read down from at.
@(private)
Msb_Bits :: struct {
    data:[]u8,
    at,limit:int, // forward: next byte and end; backward: one past the next byte and start
    bits:u32,
    bitpos:int,   // where the next byte lands; 24 minus the bits loaded
    backward:bool,
}

@(private)
msb_forward :: proc(data:[]u8,start,end:int) -> (r:Msb_Bits) {
    r={data=data,at=start,limit=min(end,len(data)),bitpos=24}
    msb_refill(&r)
    return
}

@(private)
msb_backward :: proc(data:[]u8,start,end:int) -> (r:Msb_Bits) {
    r={data=data,at=min(end,len(data)),limit=max(start,0),bitpos=24,backward=true}
    msb_refill(&r)
    return
}

// The limits are inside data (the constructors clamp them), so a byte between them can be read.
@(private)
msb_refill :: #force_inline proc(r:^Msb_Bits) #no_bounds_check {
    if r.bitpos<=0 {return}
    // Four bytes at once inside the stream; the bits of a byte past the ones it counts land
    // where that byte goes, and the next refill puts them there again.
    if r.backward {
        if r.at-4>=r.limit {
            r.bits|=u32(intrinsics.unaligned_load((^u32le)(&r.data[r.at-4])))>>uint(24-r.bitpos)
            n:=(r.bitpos+7)>>3
            r.at-=n
            r.bitpos-=8*n
            return
        }
    } else if r.at>=0 && r.at+4<=r.limit {
        r.bits|=u32(intrinsics.unaligned_load((^u32be)(&r.data[r.at])))>>uint(24-r.bitpos)
        n:=(r.bitpos+7)>>3
        r.at+=n
        r.bitpos-=8*n
        return
    }
    for r.bitpos>0 {
        value:u8
        if r.backward {
            r.at-=1
            if r.at>=r.limit {value=r.data[r.at]}
        } else {
            if r.at<r.limit && r.at>=0 {value=r.data[r.at]}
            r.at+=1
        }
        r.bits|=u32(value)<<uint(r.bitpos)
        r.bitpos-=8
    }
}

// n from 0 to 32; at most what is loaded.
@(private)
msb_take :: #force_inline proc(r:^Msb_Bits,n:int) -> u32 {
    value:=r.bits>>uint(32-n) if n>0 else 0
    r.bits=r.bits<<uint(n) if n<32 else 0
    r.bitpos+=n
    return value
}

@(private)
msb_bit :: #force_inline proc(r:^Msb_Bits) -> u32 {
    msb_refill(r)
    return msb_take(r,1)
}

@(private)
leading_zeros :: #force_inline proc(value:u32) -> int {
    return int(intrinsics.count_leading_zeros(value))
}

// Where the stream stops: the byte after the last one a bit was read from.
@(private)
msb_position :: proc(r:^Msb_Bits) -> int {
    unread:=(24-r.bitpos)>>3
    return r.at+unread if r.backward else r.at-unread
}

// Least significant bit first, for the Huffman and tANS streams.
@(private)
Lsb_Bits :: struct {
    data:[]u8,
    at,limit:int,
    bits:u64,
    count:int,  // bits loaded and not read
    loaded:int, // bits loaded since the start
    backward:bool,
}

// Loads whole bytes until more than 56 bits are loaded.
@(private)
lsb_refill :: #force_inline proc(r:^Lsb_Bits) #no_bounds_check {
    if r.count>56 {return}
    if r.backward {
        if r.at-8>=r.limit && r.at<=len(r.data) && r.limit>=0 {
            value:=u64(intrinsics.unaligned_load((^u64be)(&r.data[r.at-8])))
            r.bits|=value<<uint(r.count)
            n:=(63-r.count)>>3
            r.at-=n
            r.count+=n*8
            r.loaded+=n*8
            return
        }
    } else if r.at>=0 && r.at+8<=r.limit && r.limit<=len(r.data) {
        value:=u64(intrinsics.unaligned_load((^u64le)(&r.data[r.at])))
        r.bits|=value<<uint(r.count)
        n:=(63-r.count)>>3
        r.at+=n
        r.count+=n*8
        r.loaded+=n*8
        return
    }
    for r.count<=56 {
        value:u8
        if r.backward {
            r.at-=1
            if r.at>=r.limit && r.at>=0 && r.at<len(r.data) {value=r.data[r.at]}
        } else {
            if r.at<r.limit && r.at>=0 && r.at<len(r.data) {value=r.data[r.at]}
            r.at+=1
        }
        r.bits|=u64(value)<<uint(r.count)
        r.count+=8
        r.loaded+=8
    }
}

// n bits, at most what is loaded.
@(private)
lsb_take :: #force_inline proc(r:^Lsb_Bits,n:int) -> u32 {
    value:=u32(r.bits&((u64(1)<<uint(n))-1))
    r.bits>>=uint(n)
    r.count-=n
    return value
}

// Where the stream stops: the byte after the last one a bit was read from.
@(private)
lsb_position :: proc(r:^Lsb_Bits,start:int) -> int {
    consumed:=r.loaded-r.count
    return start-(consumed+7)/8 if r.backward else start+(consumed+7)/8
}
