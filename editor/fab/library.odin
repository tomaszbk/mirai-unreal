package fab

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

// The library of the account on Fab: the listings it owns in the Unreal
// format, each with its builds by engine version, and the files of any
// listing in the other formats (FBX, glTF, OBJ), which Fab gives in builds
// of their own.

LIBRARY_PAGES_MAX :: 1000 // of 100 listings

Listing :: struct {
    title:string `json:"title"`,
    url:string `json:"url"`,
    asset_id:string `json:"assetId"`,
    namespace:string `json:"assetNamespace"`,
    attributes:[]map[string]string `json:"customAttributes"`,
    versions:[]Version `json:"projectVersions"`,
}

Version :: struct {
    artifact:string `json:"artifactId"`,
    engines:[]string `json:"engineVersions"`,
    platforms:[]string `json:"targetPlatforms"`,
}

// The identifier of a listing on Fab: the last part of the address of its
// page.
listing_uid :: proc(l:Listing) -> string {
    for attributes in l.attributes {if uid,found:=attributes["ListingIdentifier"];found {return uid}}
    if at:=strings.last_index_byte(l.url,'/');at>=0 {return l.url[at+1:]}
    return ""
}

// The listings of the library of the account, in allocator, which holds
// everything they point to: free them with free_all or an arena.
library_read :: proc(s:Session,allocator:mem.Allocator) -> (listings:[]Listing,problem:string) {
    Page :: struct {
        cursors:struct {next:string `json:"next"`} `json:"cursors"`,
        results:[]Listing `json:"results"`,
    }
    out:=make([dynamic]Listing,allocator)
    cursor:=""
    for _ in 0..<LIBRARY_PAGES_MAX {
        url:=fmt.tprintf("https://www.fab.com/e/accounts/%s/ue/library?count=100",s.account_id)
        if cursor!="" {url=fmt.tprintf("%s&cursor=%s",url,url_encode(cursor,context.temp_allocator))}
        response,send_problem:=http_send({url=url,authorization=session_authorization(s)},context.temp_allocator)
        if send_problem!="" {return out[:],strings.clone(send_problem,allocator)}
        if response.status==401 {return out[:],strings.clone("Epic does not take the session any more: sign in again",allocator)}
        if response.status!=200 {return out[:],fmt.aprintf("Fab did not give the library (%d): %s",response.status,text_head(response.body),allocator=allocator)}
        page:Page
        if json.unmarshal(response.body,&page,allocator=allocator)!=nil {return out[:],strings.clone("Fab gave a library this plugin cannot read",allocator)}
        append(&out,..page.results)
        if page.cursors.next=="" {break}
        cursor=strings.clone(page.cursors.next,context.temp_allocator)
    }
    return out[:],""
}

Format :: struct {
    type:struct {
        code:string `json:"code"`,
        name:string `json:"name"`,
        extensions:[]string `json:"extensions"`,
    } `json:"assetFormatType"`,
    files:[]Format_File `json:"files"`,
}

Format_File :: struct {
    uid:string `json:"uid"`,
    name:string `json:"name"`,
    size:i64 `json:"fileSize"`,
}

// The formats a listing comes in and the files of each, in allocator as
// library_read.
listing_formats :: proc(uid:string,allocator:mem.Allocator) -> (formats:[]Format,problem:string) {
    if !uid_valid(uid) {return nil,fmt.aprintf("%q is not the identifier of a listing: give the last part of the address of its page on Fab",uid,allocator=allocator)}
    response,send_problem:=http_send({url=fmt.tprintf("https://www.fab.com/i/listings/%s/asset-formats",uid)},context.temp_allocator)
    if send_problem!="" {return nil,strings.clone(send_problem,allocator)}
    if response.status==404 {return nil,fmt.aprintf("Fab has no listing %s",uid,allocator=allocator)}
    if response.status!=200 {return nil,fmt.aprintf("Fab did not give the formats of %s (%d)",uid,response.status,allocator=allocator)}
    if json.unmarshal(response.body,&formats,allocator=allocator)!=nil {return nil,strings.clone("Fab gave formats this plugin cannot read",allocator)}
    return formats,""
}

// Where a build is: the addresses of its manifest, signed for a while.
Download_Info :: struct {
    points:[]struct {
        manifest:string `json:"manifestUrl"`,
        expires:string `json:"signatureExpiration"`,
    } `json:"distributionPoints"`,
}

// The manifest of the build of artifact of the listing in the Unreal format,
// for platform ("" for Windows), and the address of the folder its chunks are
// under; in allocator.
unreal_build :: proc(s:Session,l:Listing,artifact,platform:string,allocator:=context.allocator) -> (m:Manifest,base:string,problem:string) {
    Answer :: struct {infos:[]Download_Info `json:"downloadInfo"`}
    body,_:=json.marshal(struct {item_id,namespace,platform:string}{l.asset_id,l.namespace,platform if platform!="" else "Windows"},{},context.temp_allocator)
    response,send_problem:=http_send({url=fmt.tprintf("https://www.fab.com/e/artifacts/%s/manifest",url_encode(artifact,context.temp_allocator)),post=true,authorization=session_authorization(s),json=string(body)},context.temp_allocator)
    if send_problem!="" {return {},"",strings.clone(send_problem,allocator)}
    if response.status==403 {return {},"",strings.clone("Fab refused the build: the account does not own the listing, or Fab took too long; try again",allocator)}
    if response.status!=200 {return {},"",fmt.aprintf("Fab did not give the build (%d): %s",response.status,text_head(response.body),allocator=allocator)}
    answer:Answer
    if json.unmarshal(response.body,&answer,allocator=context.temp_allocator)!=nil || len(answer.infos)==0 {return {},"",strings.clone("Fab gave no build of the listing",allocator)}
    return build_fetch(answer.infos[0],allocator)
}

// A file of a listing in another format: Fab gives either the file itself,
// fetched into staging (direct), or the manifest of a build of it.
format_build :: proc(s:Session,uid,format,file,staging:string,allocator:=context.allocator) -> (m:Manifest,base,direct:string,problem:string) {
    url:=fmt.tprintf("https://www.fab.com/p/egl/listings/%s/asset-formats/%s/files/%s/download-info",url_encode(uid,context.temp_allocator),url_encode(format,context.temp_allocator),url_encode(file,context.temp_allocator))
    response,send_problem:=http_send({url=url,authorization=session_authorization(s)},context.temp_allocator)
    if send_problem!="" {return {},"","",strings.clone(send_problem,allocator)}
    if response.status==403 || response.status==401 {return {},"","",strings.clone("Fab refused the file: the account does not own the listing; claim it on Fab first",allocator)}
    if response.status!=200 {return {},"","",fmt.aprintf("Fab did not give the file (%d): %s",response.status,text_head(response.body),allocator=allocator)}
    Answer :: struct {
        infos:[]struct {
            url:string `json:"downloadUrl"`,
            using info:Download_Info,
        } `json:"downloadInfo"`,
    }
    answer:Answer
    if json.unmarshal(response.body,&answer,allocator=context.temp_allocator)!=nil || len(answer.infos)==0 {return {},"","",fmt.aprintf("Fab gave a file this plugin cannot read: %s",text_head(response.body),allocator=allocator)}
    given:=answer.infos[0]
    if given.url=="" {
        m,base,problem=build_fetch(given.info,allocator)
        return
    }
    address:=url_shown(given.url)
    name:=address[strings.last_index_byte(address,'/')+1:]
    if !name_safe(name) {return {},"","",fmt.aprintf("Fab named the file %q, which is not a file name",name,allocator=allocator)}
    path:=path_join({staging,name},allocator)
    if problem=http_fetch({{given.url,path}},allocator);problem!="" {return}
    // What the address gives may be the manifest of a build of the file.
    head:[4]u8
    if file,open_error:=os.open(path);open_error==nil {
        _,_=os.read(file,head[:])
        os.close(file)
    }
    if le32(head[:],0)!=MANIFEST_MAGIC {return {},"",path,""}
    bytes,read_error:=os.read_entire_file(path,context.temp_allocator)
    if read_error!=nil {return {},"","",fmt.aprintf("%s cannot be read: %v",path,read_error,allocator=allocator)}
    if m,problem=manifest_parse(bytes,allocator);problem!="" {return}
    return m,strings.clone(address[:strings.last_index_byte(address,'/')],allocator),"",""
}

@(private="file")
build_fetch :: proc(info:Download_Info,allocator:=context.allocator) -> (m:Manifest,base:string,problem:string) {
    tried:=""
    for point in info.points {
        if at,consumed:=time.rfc3339_to_time_utc(point.expires);consumed>0 && time.diff(time.now(),at)<0 {continue}
        response,send_problem:=http_send({url=point.manifest},context.temp_allocator)
        if send_problem!="" || response.status!=200 {tried=send_problem if send_problem!="" else fmt.tprintf("status %d",response.status);continue}
        if m,problem=manifest_parse(response.body,allocator);problem!="" {return}
        // The chunks are under the folder of the manifest.
        address:=url_shown(point.manifest)
        slash:=strings.last_index_byte(address,'/')
        if slash<0 {manifest_destroy(&m);return {},"",fmt.aprintf("the build is at %q, which is not an address",address,allocator=allocator)}
        return m,strings.clone(address[:slash],allocator),""
    }
    if tried=="" {return {},"",strings.clone("the build has no address that has not expired: ask for it again",allocator)}
    return {},"",fmt.aprintf("the manifest of the build could not be fetched: %s",tried,allocator=allocator)
}

// The identifier of a listing in what a user gives: the identifier or the
// address of its page.
uid_from_text :: proc(text:string) -> string {
    uid:=strings.trim_space(text)
    if at:=strings.index_byte(uid,'?');at>=0 {uid=uid[:at]}
    uid=strings.trim_right(uid,"/")
    if at:=strings.last_index_byte(uid,'/');at>=0 {uid=uid[at+1:]}
    return uid
}

uid_valid :: proc(uid:string) -> bool {
    if uid=="" || len(uid)>64 {return false}
    for c in transmute([]u8)uid {if !(c>='0' && c<='9' || c>='a' && c<='f' || c>='A' && c<='F' || c=='-') {return false}}
    return true
}

// The start of a body, for a message.
@(private)
text_head :: proc(body:[]u8) -> string {return strings.trim_space(string(body[:min(len(body),200)]))}
