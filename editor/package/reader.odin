package unreal

import "core:mem"
import "core:unicode/utf8"

@(private)
Reader :: struct {bytes:[]u8,at,end:int,error:Error}

@(private)
bad :: proc(r:^Reader,code:Error_Code,field:string) {
    if r.error.code==.None {r.error={code,i64(r.at),field}}
}

@(private)
take :: proc(r:^Reader,count:int,field:string) -> []u8 {
    if r.error.code!=.None {return nil}
    if count<0 || r.at<0 || r.end>len(r.bytes) || r.at>r.end || count>r.end-r.at {
        bad(r,.Truncated,field)
        return nil
    }
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
    return u16(bytes[0]) | u16(bytes[1])<<8
}

@(private)
u32_read :: proc(r:^Reader,field:string) -> u32 {
    bytes:=take(r,4,field)
    if len(bytes)!=4 {return 0}
    return u32(bytes[0]) | u32(bytes[1])<<8 | u32(bytes[2])<<16 | u32(bytes[3])<<24
}

@(private)
i32_read :: proc(r:^Reader,field:string) -> i32 {return transmute(i32)u32_read(r,field)}

@(private)
i64_read :: proc(r:^Reader,field:string) -> i64 {
    low:=u32_read(r,field)
    high:=u32_read(r,field)
    return transmute(i64)(u64(low) | u64(high)<<32)
}

@(private)
bool_read :: proc(r:^Reader,field:string) -> bool {
    value:=u32_read(r,field)
    if value>1 {bad(r,.Malformed,field)}
    return value==1
}

@(private)
guid_read :: proc(r:^Reader,field:string) -> (out:Guid) {
    bytes:=take(r,16,field)
    copy(out[:],bytes)
    return
}

Serialized_String :: struct {bytes:[]u8,wide:bool,source:Span}

@(private)
text_read :: proc(r:^Reader,limit:u32,field:string) -> (out:Serialized_String) {
    start:=r.at
    count:=i32_read(r,field)
    if r.error.code!=.None {return}
    wide:=count<0
    length:=i64(count)
    if wide {length= -length}
    if u64(length)>u64(limit) {bad(r,.Limit,field);return}
    byte_count:=length*(wide?2:1)
    bytes:=take(r,int(byte_count),field)
    if r.error.code!=.None {return}
    if length==0 {return Serialized_String{source={i64(start),4}}}
    if bytes[len(bytes)-1]!=0 || wide && bytes[len(bytes)-2]!=0 {bad(r,.Malformed,field);return}
    out={bytes=bytes[:len(bytes)-(wide?2:1)],wide=wide,source={i64(start),i64(r.at-start)}}
    return
}

@(private)
text_decode :: proc(text:Serialized_String,allocator:mem.Allocator) -> (value:string,owned:[]u8,error:Error) {
    if text.wide && len(text.bytes)%2!=0 {return "",nil,{.Malformed,text.source.offset,"FString UTF16 byte count"}}
    if len(text.bytes)>max(int)/2 {return "",nil,{.Limit,text.source.offset,"FString conversion byte count"}}
    if !text.wide {
        for byte in text.bytes {if byte>=128 || byte==0 {return "",nil,{.Malformed,text.source.offset,"FString ASCII encoding"}}}
        return string(text.bytes),nil,{}
    }
    if len(text.bytes)==0 {return "",nil,{}}
    buffer,allocation_error:=make([]u8,len(text.bytes)*2,allocator)
    if allocation_error!=nil {return "",nil,{.Out_Of_Memory,text.source.offset,"FString UTF16"}}
    written:=0
    for at:=0;at<len(text.bytes);at+=2 {
        point:=u32(text.bytes[at]) | u32(text.bytes[at+1])<<8
        if point>=0xd800 && point<=0xdbff {
            if at+3>=len(text.bytes) {delete(buffer,allocator);return "",nil,{.Malformed,text.source.offset+i64(at),"FString UTF16 surrogate"}}
            low:=u32(text.bytes[at+2]) | u32(text.bytes[at+3])<<8
            if low<0xdc00 || low>0xdfff {delete(buffer,allocator);return "",nil,{.Malformed,text.source.offset+i64(at),"FString UTF16 surrogate"}}
            point=0x10000+(point-0xd800)*0x400+(low-0xdc00)
            at+=2
        } else if point==0 || point>=0xdc00 && point<=0xdfff {
            delete(buffer,allocator)
            return "",nil,{.Malformed,text.source.offset+i64(at),"FString UTF16 codepoint"}
        }
        encoded,size:=utf8.encode_rune(rune(point))
        copy(buffer[written:],encoded[:size])
        written+=size
    }
    return string(buffer[:written]),buffer,{}
}

serialized_string_value :: proc(text:Serialized_String,allocator:=context.allocator) -> (value:Value,error:Error) {
    value.kind=.String
    value.allocator=allocator
    value.text,value.owned_text,error=text_decode(text,allocator)
    return
}

span_valid :: proc(bytes:[]u8,span:Span) -> bool {
    return span.offset>=0 && span.size>=0 && span.offset<=i64(len(bytes)) && span.size<=i64(len(bytes))-span.offset
}

span_bytes :: proc(p:^Package,span:Span) -> (bytes:[]u8,error:Error) {
    if p==nil || !span_valid(p.bytes,span) {return nil,{.Malformed,span.offset,"span"}}
    return p.bytes[int(span.offset):int(span.offset+span.size)],{}
}
