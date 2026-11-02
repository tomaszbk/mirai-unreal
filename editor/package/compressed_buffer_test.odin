package unreal

import "core:hash"
import "core:testing"
import "project:plugins/unreal/editor/kraken"
import "mirai:std/serial"

@(private="file")
compressed_test_be :: proc(bytes:[]u8,value:u64) {for i in 0..<len(bytes) {bytes[i]=u8(value>>u64((len(bytes)-i-1)*8))}}

@(private="file")
compressed_fixture :: proc(source:[]u8,method:Compressed_Method) -> []u8 {
    bytes:=make([]u8,64+len(source)+16,context.temp_allocator)
    compressed_test_be(bytes[:4],0xb7756362)
    bytes[8]=u8(method)
    compressed_test_be(bytes[12:16],1)
    compressed_test_be(bytes[16:24],u64(len(source)))
    digest:=blake3(source)
    copy(bytes[32:64],digest[:])
    length:=64+len(source)
    if method==.None {copy(bytes[64:],source)} else {
        bytes[11]=16
        size,_:=serial.lz4_compress(source,bytes[68:])
        compressed_test_be(bytes[64:68],u64(size))
        length=68+size
    }
    compressed_test_be(bytes[24:32],u64(length))
    compressed_test_be(bytes[4:8],u64(hash.crc32(bytes[8:method==.None?64:68])))
    return bytes[:length]
}

@(test)
unreal_compressed_buffer_decodes_uncompressed_and_lz4_blocks :: proc(t:^testing.T) {
    source:=make([]u8,4096,context.temp_allocator)
    for &value,index in source {value=u8(index%7)}
    output:=make([]u8,len(source),context.temp_allocator)
    for method in ([2]Compressed_Method{.None,.LZ4}) {
        buffer,error:=compressed_buffer(compressed_fixture(source,method))
        if !testing.expect_value(t,error.code,Error_Code.None) {continue}
        decode_error:=compressed_buffer_decode(buffer,output)
        testing.expect_value(t,decode_error.code,Error_Code.None)
        testing.expect_value(t,string(output),string(source))
        size_error:=compressed_buffer_decode(buffer,output[:len(output)-1])
        testing.expect_value(t,size_error.code,Error_Code.Limit)
    }
    empty,error:=compressed_buffer(compressed_fixture(nil,.None))
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,compressed_buffer_decode(empty,nil).code,Error_Code.None)
}

@(test)
unreal_compressed_buffer_rejects_bad_headers_blocks_and_missing_decoders :: proc(t:^testing.T) {
    source:=make([]u8,4096,context.temp_allocator)
    bytes:=compressed_fixture(source,.LZ4)
    for length in 0..<len(bytes) {
        _,error:=compressed_buffer(bytes[:length])
        testing.expect(t,error.code!=.None)
    }
    for offset in ([8]int{0,4,8,11,12,16,24,64}) {
        before:=bytes[offset]
        bytes[offset]=0xff
        _,error:=compressed_buffer(bytes)
        testing.expect(t,error.code!=.None)
        bytes[offset]=before
    }
    bytes[8]=3
    compressed_test_be(bytes[4:8],u64(hash.crc32(bytes[8:68])))
    buffer,error:=compressed_buffer(bytes)
    testing.expect_value(t,error.code,Error_Code.None)
    output:=make([]u8,len(source),context.temp_allocator)
    testing.expect_value(t,compressed_buffer_decode(buffer,output).code,Error_Code.Compressed)
    decoder,_:=kraken.decoder_make(context.temp_allocator)
    testing.expect_value(t,compressed_buffer_decode(buffer,output,&decoder).code,Error_Code.Malformed)
}

@(test)
unreal_blake3_matches_the_reference_vectors :: proc(t:^testing.T) {
    // Inputs of the official test vectors: byte i is i%251.
    input:=make([]u8,102400,context.temp_allocator)
    for &value,index in input {value=u8(index%251)}
    cases:=[?]struct{length:int,hex:string}{
        {0,"af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"},
        {1,"2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"},
        {1023,"10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"},
        {1024,"42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"},
        {1025,"d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"},
        {2048,"e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"},
        {3072,"b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"},
        {102400,"bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085"},
    }
    for item in cases {
        digest:=blake3(input[:item.length])
        hex:[64]u8
        digits:="0123456789abcdef"
        for byte,i in digest {hex[i*2]=digits[byte>>4];hex[i*2+1]=digits[byte&15]}
        testing.expectf(t,string(hex[:])==item.hex,"BLAKE3 of %d bytes",item.length)
    }
}
