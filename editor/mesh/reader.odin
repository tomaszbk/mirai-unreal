package mesh

import "core:mem"
import "core:unicode/utf8"
import unreal "project:plugins/unreal/editor/package"

// Little-endian reads of a payload that never go past its end: the first
// failure is kept and every later read gives zero.
@(private)
Reader :: struct {bytes:[]u8,at:int,error:unreal.Error,base:i64}

@(private)
reader_make :: proc(bytes:[]u8,base:i64=0) -> Reader {return {bytes=bytes,base=base}}

@(private)
bad :: proc(r:^Reader,code:unreal.Error_Code,field:string) {
    if r.error.code==.None {r.error={code,r.base+i64(r.at),field}}
}

@(private)
failed :: #force_inline proc(r:^Reader) -> bool {return r.error.code!=.None}

@(private)
take :: proc(r:^Reader,count:int,field:string) -> []u8 {
    if r.error.code!=.None {return nil}
    if count<0 || count>len(r.bytes)-r.at {bad(r,.Truncated,field);return nil}
    out:=r.bytes[r.at:r.at+count]
    r.at+=count
    return out
}

@(private)
u8_read :: proc(r:^Reader,field:string) -> u8 {
    bytes:=take(r,1,field)
    return len(bytes)==1?bytes[0]:0
}

@(private)
u16_read :: proc(r:^Reader,field:string) -> u16 {
    bytes:=take(r,2,field)
    if len(bytes)!=2 {return 0}
    return u16(bytes[0])|u16(bytes[1])<<8
}

@(private)
u32_read :: proc(r:^Reader,field:string) -> u32 {
    bytes:=take(r,4,field)
    if len(bytes)!=4 {return 0}
    return u32_at(bytes,0)
}

@(private)
i32_read :: proc(r:^Reader,field:string) -> i32 {return transmute(i32)u32_read(r,field)}

@(private)
bool_read :: proc(r:^Reader,field:string) -> bool {
    value:=u32_read(r,field)
    if value>1 {bad(r,.Malformed,field)}
    return value==1
}

// A count of elements that each take at least `least` bytes: never more than what is left.
@(private)
count_read :: proc(r:^Reader,least:int,field:string) -> int {
    count:=i32_read(r,field)
    if failed(r) {return 0}
    if count<0 {bad(r,.Malformed,field);return 0}
    if least>0 && i64(count)*i64(least)>i64(len(r.bytes)-r.at) {bad(r,.Truncated,field);return 0}
    return int(count)
}

// A String, skipped: its bytes stay in the payload.
@(private)
text_skip :: proc(r:^Reader,field:string) {_,_=text_read(r,field)}

// A String as its bytes without the terminator, and whether they are UTF-16.
@(private)
text_read :: proc(r:^Reader,field:string) -> (bytes:[]u8,wide:bool) {
    count:=i32_read(r,field)
    if failed(r) {return}
    length:=i64(count)
    wide=count<0
    if wide {length= -length}
    if length>1<<20 {bad(r,.Limit,field);return}
    data:=take(r,int(length*(wide?2:1)),field)
    if failed(r) || length==0 {return nil,wide}
    if data[len(data)-1]!=0 || wide && data[len(data)-2]!=0 {bad(r,.Malformed,field);return nil,wide}
    return data[:len(data)-(wide?2:1)],wide
}

// A String as UTF-8 in allocator.
@(private)
text_string :: proc(r:^Reader,field:string,allocator:mem.Allocator) -> string {
    bytes,wide:=text_read(r,field)
    if failed(r) {return ""}
    if !wide {
        // Unreal writes a narrow String only when it is ASCII.
        for b in bytes {if b==0 || b>=128 {bad(r,.Malformed,field);return ""}}
        clone,error:=make([]u8,len(bytes),allocator)
        if error!=nil {bad(r,.Out_Of_Memory,field);return ""}
        copy(clone,bytes)
        return string(clone)
    }
    out,error:=make([]u8,len(bytes)/2*4,allocator)
    if error!=nil {bad(r,.Out_Of_Memory,field);return ""}
    written:=0
    for at:=0;at+1<len(bytes);at+=2 {
        point:=rune(u16(bytes[at])|u16(bytes[at+1])<<8)
        if point>=0xd800 && point<=0xdbff && at+3<len(bytes) {
            low:=rune(u16(bytes[at+2])|u16(bytes[at+3])<<8)
            if low>=0xdc00 && low<=0xdfff {point=0x10000+(point-0xd800)*0x400+(low-0xdc00);at+=2}
        }
        if point==0 || point>=0xd800 && point<=0xdfff {bad(r,.Malformed,field);return ""}
        encoded,size:=utf8.encode_rune(point)
        written+=copy(out[written:],encoded[:size])
    }
    return string(out[:written])
}

@(private)
u32_at :: #force_inline proc "contextless" (bytes:[]u8,at:int) -> u32 {
    return u32(bytes[at])|u32(bytes[at+1])<<8|u32(bytes[at+2])<<16|u32(bytes[at+3])<<24
}

@(private)
f32_at :: #force_inline proc "contextless" (bytes:[]u8,at:int) -> f32 {return transmute(f32)u32_at(bytes,at)}

@(private)
f64_at :: #force_inline proc "contextless" (bytes:[]u8,at:int) -> f64 {
    return transmute(f64)(u64(u32_at(bytes,at))|u64(u32_at(bytes,at+4))<<32)
}
