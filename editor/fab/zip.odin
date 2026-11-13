package fab

import "core:compress/deflate"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The zip archives Fab gives the files of other formats in (FBX, glTF, OBJ),
// stored or deflated, with or without zip64.

ZIP_ENTRY_MAX :: 4<<30 // bytes of one file once unpacked
ZIP_ENTRIES_MAX :: 1<<20

Zip_Entry :: struct {
    name:string,
    method:u16, // 0 stored, 8 deflated
    crc:u32,
    packed,size:u64,
    local:u64, // offset of its local header
}

// Unpacks the archive at path into folder and gives the files it wrote,
// relative to folder with forward slashes, in allocator.
zip_extract :: proc(path,folder:string,allocator:=context.allocator) -> (written:[]string,problem:string) {
    file,open_error:=os.open(path)
    if open_error!=nil {return nil,fmt.aprintf("%s cannot be opened: %v",path,open_error,allocator=allocator)}
    defer os.close(file)
    length,size_error:=os.file_size(file)
    if size_error!=nil {return nil,fmt.aprintf("%s cannot be read: %v",path,size_error,allocator=allocator)}
    entries:[]Zip_Entry
    if entries,problem=zip_entries(file,length,context.temp_allocator);problem!="" {return nil,fmt.aprintf("%s: %s",path,problem,allocator=allocator)}
    out:=make([dynamic]string,0,len(entries),allocator)
    for e in entries {
        if strings.has_suffix(e.name,"/") {continue}
        if !name_safe(e.name) {return out[:],fmt.aprintf("%s: its file %q goes out of the folder it is unpacked to",path,e.name,allocator=allocator)}
        if e.method!=0 && e.method!=8 {return out[:],fmt.aprintf("%s: its file %q is packed with method %d; only stored and deflated files are read",path,e.name,e.method,allocator=allocator)}
        if e.size>ZIP_ENTRY_MAX {return out[:],fmt.aprintf("%s: its file %q is larger than %d bytes",path,e.name,ZIP_ENTRY_MAX,allocator=allocator)}
        local:[30]u8
        if read,error:=os.read_at(file,local[:],i64(e.local));error!=nil || read!=30 || le32(local[:],0)!=0x04034b50 {
            return out[:],fmt.aprintf("%s: the header of %q is not where its directory says",path,e.name,allocator=allocator)
        }
        start:=e.local+30+u64(le16(local[:],26))+u64(le16(local[:],28))
        if start+e.packed>u64(length) {return out[:],fmt.aprintf("%s: %q is cut short",path,e.name,allocator=allocator)}
        // Each file is held only while it is written.
        packed,packed_error:=make([]u8,int(e.packed))
        if packed_error!=nil {return out[:],fmt.aprintf("%s: there is no memory for %q",path,e.name,allocator=allocator)}
        defer delete(packed)
        if read,error:=os.read_at(file,packed,i64(start));error!=nil || u64(read)!=e.packed {return out[:],fmt.aprintf("%s: %q cannot be read",path,e.name,allocator=allocator)}
        data:=packed
        inflated:[dynamic]u8
        defer delete(inflated)
        if e.method==8 {
            if deflate.inflate_raw_from_bytes(&inflated,packed,int(e.size),int(e.size))!=nil || u64(len(inflated))!=e.size {
                return out[:],fmt.aprintf("%s: %q does not inflate",path,e.name,allocator=allocator)
            }
            data=inflated[:]
        }
        if u64(len(data))!=e.size || hash.crc32(data)!=e.crc {return out[:],fmt.aprintf("%s: %q does not match its checksum",path,e.name,allocator=allocator)}
        target:=path_join({folder,e.name},context.temp_allocator)
        if made:=os.make_directory_all(filepath.dir(target));made!=nil && !os.is_dir(filepath.dir(target)) {
            return out[:],fmt.aprintf("%s cannot be made: %v",filepath.dir(target),made,allocator=allocator)
        }
        if error:=os.write_entire_file(target,data);error!=nil {return out[:],fmt.aprintf("%s cannot be written: %v",target,error,allocator=allocator)}
        append(&out,strings.clone(e.name,allocator))
    }
    return out[:],""
}

// The entries of the central directory of the archive in file.
zip_entries :: proc(file:^os.File,length:i64,allocator:=context.allocator) -> (entries:[]Zip_Entry,problem:string) {
    // The end record is in the last 64 KiB and 22 bytes, after its comment.
    tail_size:=min(length,65535+22)
    tail:=make([]u8,int(tail_size),context.temp_allocator)
    if read,error:=os.read_at(file,tail,length-tail_size);error!=nil || i64(read)!=tail_size {return nil,"it cannot be read"}
    end:=-1
    for i:=len(tail)-22;i>=0;i-=1 {if le32(tail,i)==0x06054b50 {end=i;break}}
    if end<0 {return nil,"it is not a zip archive"}
    count:=u64(le16(tail,end+10))
    directory_size:=u64(le32(tail,end+12))
    directory:=u64(le32(tail,end+16))
    if count==0xffff || directory_size==0xffffffff || directory==0xffffffff {
        // zip64: its locator is right before the end record.
        if end<20 || le32(tail,end-20)!=0x07064b50 {return nil,"its zip64 locator is missing"}
        record:=le64(tail,end-20+8)
        head:[56]u8
        if read,error:=os.read_at(file,head[:],i64(record));error!=nil || read!=56 || le32(head[:],0)!=0x06064b50 {return nil,"its zip64 end record is missing"}
        count,directory_size,directory=le64(head[:],32),le64(head[:],40),le64(head[:],48)
    }
    if count>ZIP_ENTRIES_MAX || directory+directory_size>u64(length) || count*46>directory_size {return nil,"its directory does not fit in it"}
    bytes:=make([]u8,int(directory_size),context.temp_allocator)
    if read,error:=os.read_at(file,bytes,i64(directory));error!=nil || u64(read)!=directory_size {return nil,"its directory cannot be read"}
    out:=make([]Zip_Entry,int(count),allocator)
    at:=0
    for &e in out {
        if at+46>len(bytes) || le32(bytes,at)!=0x02014b50 {return nil,"its directory is malformed"}
        e.method,e.crc=le16(bytes,at+10),le32(bytes,at+16)
        e.packed,e.size,e.local=u64(le32(bytes,at+20)),u64(le32(bytes,at+24)),u64(le32(bytes,at+42))
        name_length,extra_length,comment_length:=int(le16(bytes,at+28)),int(le16(bytes,at+30)),int(le16(bytes,at+32))
        if at+46+name_length+extra_length+comment_length>len(bytes) {return nil,"its directory is malformed"}
        e.name=string(bytes[at+46:][:name_length])
        if le16(bytes,at+8)&1!=0 {return nil,fmt.aprintf("its file %q is encrypted",e.name,allocator=allocator)}
        // The zip64 extra field holds, in this order, those that are full.
        extra:=bytes[at+46+name_length:][:extra_length]
        for x:=0;x+4<=len(extra); {
            id,size:=le16(extra,x),int(le16(extra,x+2))
            if x+4+size>len(extra) {break}
            if id==0x0001 {
                field:=extra[x+4:][:size]
                y:=0
                take :: proc(field:[]u8,y:^int,value:^u64,full:u64) {
                    if value^!=full || y^+8>len(field) {return}
                    value^=le64(field,y^)
                    y^+=8
                }
                take(field,&y,&e.size,0xffffffff)
                take(field,&y,&e.packed,0xffffffff)
                take(field,&y,&e.local,0xffffffff)
            }
            x+=4+size
        }
        at+=46+name_length+extra_length+comment_length
    }
    return out,""
}

@(private)
le16 :: proc(b:[]u8,at:int) -> u16 {return u16(b[at]) | u16(b[at+1])<<8}
@(private)
le32 :: proc(b:[]u8,at:int) -> u32 {return u32(b[at]) | u32(b[at+1])<<8 | u32(b[at+2])<<16 | u32(b[at+3])<<24}
@(private)
le64 :: proc(b:[]u8,at:int) -> u64 {return u64(le32(b,at)) | u64(le32(b,at+4))<<32}
