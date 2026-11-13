package unreal_editor

import "core:strings"
import csync "core:sync"
import "core:time"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import "project:plugins/unreal/editor/fab"

FAB_SECONDS :: 600 // a method waits for its job by default
FAB_FILES_MAX :: 5000 // entries an answer lists

Fab_Sign_In_Params :: struct {
    seconds:int `mirai:"optional,min=1,max=7200,unit=s,label=How long it waits for the user to sign in at the Epic page; past that it answers working and the sign in goes on"`,
}

Fab_Status :: struct {
    signed_in:bool `mirai:"label=The account is signed in, as far as the last job knew"`,
    name:string `mirai:"label=Of the account"`,
    working:string `mirai:"label=What the job that runs does; empty when none runs"`,
    message:string `mirai:"label=What the last job said"`,
    url:string `mirai:"label=The Epic page a sign in that runs waits at, which it opened in the browser"`,
}

Fab_Library_Params :: struct {
    filter:[128]u8 `mirai:"text,optional,label=Only the listings whose title has it"`,
    refresh:bool `mirai:"optional,label=Reads the library again; otherwise the last one read, or a new read when there is none"`,
    seconds:int `mirai:"optional,min=1,max=7200,unit=s,label=How long it waits"`,
}

Fab_Listing_Row :: struct {
    listing:string `mirai:"label=Its identifier on Fab, the last part of the address of its page"`,
    title:string,
    engines:[]string `mirai:"label=The engine versions of its builds in the Unreal format"`,
}

Fab_Library_Result :: struct {
    using status:Fab_Status,
    listings:[]Fab_Listing_Row,
}

Fab_Contents_Params :: struct {
    listing:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The identifier of a listing or the address of its page on Fab"`,
    version:[64]u8 `mirai:"text,optional,label=Of the Unreal format: an engine version (5.4) or an artifact; empty is the build of the newest engine"`,
    filter:[128]u8 `mirai:"text,optional,label=Only the files whose path has it"`,
    seconds:int `mirai:"optional,min=1,max=7200,unit=s,label=How long it waits"`,
}

Fab_Format_File :: struct {file,name:string,size:i64 `mirai:"unit=B"`}
Fab_Format_Row :: struct {format,name:string,files:[]Fab_Format_File}

Fab_Contents_Result :: struct {
    using status:Fab_Status,
    engines:[]string `mirai:"label=Of the build of the Unreal format the files are of"`,
    files:[]string `mirai:"label=The files of its build of the Unreal format, under its Content folder: what picks names"`,
    more:int `mirai:"label=Files the filter took that the answer leaves out"`,
    formats:[]Fab_Format_Row `mirai:"label=Its other formats and their files"`,
}

Fab_Download_Params :: struct {
    listing:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The identifier of a listing or the address of its page on Fab"`,
    folder:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The folder of the assets it goes to; an Unreal build keeps its folders under /Game inside it"`,
    version:[64]u8 `mirai:"text,optional,label=Of the Unreal format: an engine version (5.4) or an artifact; empty is the build of the newest engine"`,
    picks:[]string `mirai:"optional,label=Of the Unreal format: files or folders under its Content folder, as unreal.fab.contents lists them; each comes with the packages it reads. Empty: the whole build"`,
    format:[64]u8 `mirai:"text,optional,label=Another format, by its code as unreal.fab.contents gives it (fbx, converted-files); empty: the Unreal format"`,
    file:[64]u8 `mirai:"text,optional,label=With format: the file of it to download"`,
    no_import:bool `mirai:"optional,label=Only downloads; otherwise the maps and meshes picked (the maps of a whole build, or its meshes when it has none) and the models of another format are imported as they land"`,
    seconds:int `mirai:"optional,min=1,max=7200,unit=s,label=How long it waits"`,
}

Fab_Download_Result :: struct {
    using status:Fab_Status,
    written:[]string `mirai:"label=The files it wrote, under folder"`,
    imports:int `mirai:"label=Files it gave to import, one after the other"`,
    importing:bool `mirai:"label=Some are still importing once the time ran out: asset.import_status says how the one that runs goes"`,
}

@(private)
fab_api_register :: proc(s:^editor.Session) {
    editor.command_bind(s,{name="unreal_fab",label="Fab",icon=.Import,menu=.View,group=editor.MENU_GROUP_PLUGINS,state=fab_panel_state,
        view=proc(s:^editor.Session) {if f:=fab_of(s);f!=nil {f.open=!f.open}},
    })
    sign_in:=Fab_Sign_In_Params{seconds=FAB_SECONDS}
    library:=Fab_Library_Params{seconds=FAB_SECONDS}
    contents:=Fab_Contents_Params{seconds=FAB_SECONDS}
    download:=Fab_Download_Params{seconds=FAB_SECONDS}
    editor.api_method_register(s,{name="unreal.fab.sign_in",summary="Signs the editor in to the Fab account of the user: opens an Epic page in the browser and waits until the user signs in there and accepts. The session stays in the configuration folder of the user, not in the project.",params=type_info_of(Fab_Sign_In_Params),result=type_info_of(Fab_Status),defaults=&sign_in,run=fab_api_sign_in})
    editor.api_method_register(s,{name="unreal.fab.sign_out",summary="Ends the Fab session of the user at Epic, so that its tokens stop working wherever they are, and forgets it.",result=type_info_of(Fab_Status),run=fab_api_sign_out})
    editor.api_method_register(s,{name="unreal.fab.status",summary="Whether the Fab account is signed in, what the job that runs does and what the last one said.",result=type_info_of(Fab_Status),flags={.Read_Only},run=fab_api_status})
    editor.api_method_register(s,{name="unreal.fab.library",summary="The listings of the Fab library of the account that come in the Unreal format.",params=type_info_of(Fab_Library_Params),result=type_info_of(Fab_Library_Result),defaults=&library,flags={.Read_Only},run=fab_api_library})
    editor.api_method_register(s,{name="unreal.fab.contents",summary="What a Fab listing has: the files of its build in the Unreal format, which unreal.fab.download picks from, and its other formats with their files.",params=type_info_of(Fab_Contents_Params),result=type_info_of(Fab_Contents_Result),defaults=&contents,flags={.Read_Only},run=fab_api_contents})
    editor.api_method_register(s,{name="unreal.fab.download",summary="Downloads a Fab listing into a folder of the assets and imports it: of the Unreal format the packages picked with those they read, or the whole build; or a file of another format, unpacked. Only the chunks of what it brings are fetched.",params=type_info_of(Fab_Download_Params),result=type_info_of(Fab_Download_Result),defaults=&download,run=fab_api_download})
}

@(private)
fab_panel_state :: proc(s:^editor.Session,b:^editor.Binding) -> editor.Command_State {
    f:=fab_of(s)
    return {checked=f!=nil && f.open,disabled=f==nil}
}

// Waits for the job that runs; false when it still runs. The wait takes the
// job itself once it ends: a manual editor runs no frames while it waits.
@(private)
fab_wait :: proc(s:^editor.Session,seconds:int) -> bool {
    running :: proc(s:^editor.Session,user:rawptr) -> bool {
        f:=fab_of(s)
        if f==nil {return false}
        unreal_fab_poll(s,f)
        return f.job!=nil
    }
    return editor.api_wait(s,f64(seconds),nil,running,"talking to Fab")
}

@(private)
fab_status_fill :: proc(f:^Unreal_Fab,out:^Fab_Status,call:^api.Call) {
    out.signed_in=f.signed
    out.name=strings.clone(base.text_get(f.name[:]),call.allocator)
    out.message=strings.clone(base.text_get(f.message[:]),call.allocator)
    if f.job!=nil {out.working=strings.clone(fab_doing(f.job),call.allocator)}
    if f.job!=nil && f.job.kind==.Sign_In && csync.atomic_load(&f.job.url_ready) {out.url=strings.clone(f.job.url,call.allocator)}
}

// The storage of a call, with the job that ended taken, or nil once it failed.
@(private)
fab_call :: proc(s:^editor.Session,call:^api.Call) -> ^Unreal_Fab {
    f:=fab_of(s)
    if f==nil {api.call_fail(call,api.SERVER_ERROR,"There is no editor world for Fab");return nil}
    // A manual editor runs no frames between calls: what ended is taken here.
    unreal_fab_poll(s,f)
    return f
}

// Fails the call with what its job said when it failed; false then.
@(private)
fab_call_ended :: proc(f:^Unreal_Fab,call:^api.Call) -> bool {
    if !f.failed {return true}
    api.call_fail(call,api.INVALID_PARAMS,base.text_get(f.message[:]))
    return false
}

// Starts a job for a call, or fails it.
@(private)
fab_call_start :: proc(s:^editor.Session,f:^Unreal_Fab,call:^api.Call,given:fab.Job_Given) -> bool {
    if f.job!=nil {api.call_not_now(call,"Fab is busy with another job","wait for it with unreal.fab.status");return false}
    if !s.has_project {api.call_fail(call,api.SERVER_ERROR,"There is no project: Fab downloads into its assets");return false}
    return fab_start(s,f,given)
}

@(private)
fab_api_status :: proc(s:^editor.Session,call:^api.Call) {
    f:=fab_call(s,call)
    if f==nil {return}
    fab_status_fill(f,api.call_result(call,Fab_Status),call)
}

@(private)
fab_api_sign_out :: proc(s:^editor.Session,call:^api.Call) {
    f:=fab_call(s,call)
    if f==nil {return}
    if !fab_call_start(s,f,call,{kind=.Sign_Out}) {return}
    if fab_wait(s,FAB_SECONDS) && !fab_call_ended(f,call) {return}
    fab_status_fill(f,api.call_result(call,Fab_Status),call)
}

@(private)
fab_api_sign_in :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Fab_Sign_In_Params)
    f:=fab_call(s,call)
    if f==nil {return}
    if !fab_call_start(s,f,call,{kind=.Sign_In}) {return}
    if fab_wait(s,p.seconds) && !fab_call_ended(f,call) {return}
    fab_status_fill(f,api.call_result(call,Fab_Status),call)
}

@(private)
fab_api_library :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Fab_Library_Params)
    f:=fab_call(s,call)
    if f==nil {return}
    if p.refresh || f.library==nil {
        if !fab_call_start(s,f,call,{kind=.Library}) {return}
        if !fab_wait(s,p.seconds) {fab_status_fill(f,api.call_result(call,Fab_Library_Result),call);return}
        if !fab_call_ended(f,call) {return}
    }
    out:=api.call_result(call,Fab_Library_Result)
    fab_status_fill(f,&out.status,call)
    if f.library==nil {return}
    filter:=base.text_get(p.filter[:])
    rows:=make([dynamic]Fab_Listing_Row,call.allocator)
    for l in f.library.listings {
        if filter!="" && !base.contains_fold(l.title,filter) {continue}
        engines:=make([dynamic]string,call.allocator)
        for v in l.versions {for e in v.engines {append(&engines,strings.clone(e,call.allocator))}}
        append(&rows,Fab_Listing_Row{strings.clone(fab.listing_uid(l),call.allocator),strings.clone(l.title,call.allocator),engines[:]})
    }
    out.listings=rows[:]
}

@(private)
fab_api_contents :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Fab_Contents_Params)
    f:=fab_call(s,call)
    if f==nil {return}
    uid:=fab.uid_from_text(base.text_get(p.listing[:]))
    l,_:=fab_listing(f,uid)
    if !fab_call_start(s,f,call,{kind=.Contents,listing=l,uid=uid,version=base.text_get(p.version[:])}) {return}
    out:=api.call_result(call,Fab_Contents_Result)
    if !fab_wait(s,p.seconds) {fab_status_fill(f,&out.status,call);return}
    if !fab_call_ended(f,call) {return}
    c:=f.contents
    fab_status_fill(f,&out.status,call)
    out.engines=make([]string,len(c.picked.engines),call.allocator)
    for &e,i in out.engines {e=strings.clone(c.picked.engines[i],call.allocator)}
    filter:=base.text_get(p.filter[:])
    files:=make([dynamic]string,call.allocator)
    for entry in c.contents {
        if filter!="" && !base.contains_fold(entry,filter) {continue}
        if len(files)>=FAB_FILES_MAX {out.more+=1;continue}
        append(&files,strings.clone(entry,call.allocator))
    }
    out.files=files[:]
    formats:=make([dynamic]Fab_Format_Row,call.allocator)
    for format in c.formats {
        if format.type.code==fab.FORMAT_UNREAL || len(format.files)==0 {continue}
        row:=Fab_Format_Row{format=strings.clone(format.type.code,call.allocator),name=strings.clone(format.type.name,call.allocator),files=make([]Fab_Format_File,len(format.files),call.allocator)}
        for file,i in format.files {row.files[i]={strings.clone(file.uid,call.allocator),strings.clone(file.name,call.allocator),file.size}}
        append(&formats,row)
    }
    out.formats=formats[:]
    if l.asset_id=="" && len(c.formats)>0 && f.library==nil {
        base.text_set(f.message[:],"the Unreal format of a listing is read from the library: call unreal.fab.library first")
        out.message=strings.clone(base.text_get(f.message[:]),call.allocator)
    }
}

@(private)
fab_api_download :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Fab_Download_Params)
    f:=fab_call(s,call)
    if f==nil {return}
    uid:=fab.uid_from_text(base.text_get(p.listing[:]))
    format:=base.text_get(p.format[:])
    given:=fab.Job_Given{kind=.Download,uid=uid,version=base.text_get(p.version[:]),format=format,file=base.text_get(p.file[:]),picks=p.picks,no_import=p.no_import}
    if format=="" || format==fab.FORMAT_UNREAL {
        found:bool
        if given.listing,found=fab_listing(f,uid);!found {
            api.call_failf(call,api.INVALID_PARAMS,"listing %q is not in the library read: call unreal.fab.library, or give format and file for another format",uid)
            return
        }
    } else if given.file=="" {
        api.call_fail(call,api.INVALID_PARAMS,"format needs file: the uid of one of its files, as unreal.fab.contents lists them")
        return
    }
    refusal:string
    if given.folder,refusal=fab_folder(s,base.text_get(p.folder[:]));refusal!="" {api.call_failf(call,api.INVALID_PARAMS,"folder: %s",refusal);return}
    started:=time.tick_now()
    if !fab_call_start(s,f,call,given) {return}
    f.queued=0
    out:=api.call_result(call,Fab_Download_Result)
    if !fab_wait(s,p.seconds) {fab_status_fill(f,&out.status,call);return}
    if !fab_call_ended(f,call) {return}
    // Then the imports of what it brought, in the time left.
    importing :: proc(s:^editor.Session,user:rawptr) -> bool {
        f:=fab_of(s)
        if f==nil {return false}
        unreal_fab_poll(s,f)
        return len(f.imports)>0 || s.importer.running!=nil
    }
    left:=f64(p.seconds)-time.duration_seconds(time.tick_since(started))
    out.importing=left>0 && !editor.api_wait(s,left,nil,importing,"importing what Fab brought") || len(f.imports)>0 || s.importer.running!=nil
    d:=f.download
    fab_status_fill(f,&out.status,call)
    out.written=make([]string,min(len(d.written),FAB_FILES_MAX),call.allocator)
    for &w,i in out.written {w=strings.clone(d.written[i],call.allocator)}
    out.imports=f.queued
}
