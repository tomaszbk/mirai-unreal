package fab

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import csync "core:sync"
import "core:thread"

// What talks to Fab runs in a thread of its own, one job at a time: the
// editor starts it and polls it between frames.

Job_Kind :: enum u8 {Sign_In,Sign_Out,Library,Contents,Download}

FORMAT_UNREAL :: "unreal-engine" // the code Fab gives the Unreal format

Job_Given :: struct {
    kind:Job_Kind,
    listing:Listing, // Contents and Download in the Unreal format: from the library
    uid:string,      // the listing
    version:string,  // an engine version or an artifact; "" the latest
    format:string,   // FORMAT_UNREAL or the code of another format
    file:string,     // of another format: the uid of its file
    picks:[]string,  // Download in the Unreal format: what to bring, "" for all
    folder:string,   // Download: where the files go
    staging:string,  // Download: a folder for the chunks, removed after
    no_import:bool,  // Download: what lands is left unimported
}

Job :: struct {
    arena:virtual.Arena,
    using given:Job_Given,
    worker:^thread.Thread,
    done:bool,
    progress:Progress,
    // Once done:
    problem:string,
    name:string,          // of the account
    url:string,           // Sign_In: the Epic page it waits at, once url_ready
    url_ready:bool,
    listings:[]Listing,   // Library
    formats:[]Format,     // Contents
    contents:[]string,    // Contents in the Unreal format: the files under its Content folder
    picked:Version,       // Contents and Download in the Unreal format
    written:[]string,     // Download: relative to folder
}

// Starts a job with given, which it copies, and returns at once.
job_start :: proc(given:Job_Given,allocator:=context.allocator) -> ^Job {
    job:=new(Job,allocator)
    _=virtual.arena_init_growing(&job.arena)
    a:=virtual.arena_allocator(&job.arena)
    job.given=given
    job.uid,job.version=strings.clone(given.uid,a),strings.clone(given.version,a)
    job.format,job.file,job.folder,job.staging=strings.clone(given.format,a),strings.clone(given.file,a),strings.clone(given.folder,a),strings.clone(given.staging,a)
    job.picks=make([]string,len(given.picks),a)
    for pick,i in given.picks {job.picks[i]=strings.clone(pick,a)}
    job.listing=listing_clone(given.listing,a)
    job.worker=thread.create_and_start_with_poly_data(job,job_work)
    if job.worker==nil {
        job.problem="the thread of Fab could not be started"
        csync.atomic_store(&job.done,true)
    }
    return job
}

job_poll :: proc(job:^Job) -> bool {
    if !csync.atomic_load(&job.done) {return false}
    if job.worker!=nil {
        thread.join(job.worker)
        thread.destroy(job.worker)
        job.worker=nil
    }
    return true
}

// Asks the job to stop at its next fetch.
job_cancel :: proc(job:^Job) {csync.atomic_store(&job.progress.cancel,true)}

// Waits for the job and frees it.
job_destroy :: proc(job:^Job) {
    if job==nil {return}
    for !job_poll(job) {thread.yield()}
    virtual.arena_destroy(&job.arena)
    free(job)
}

// The version of the listing that wanted names, an engine version (5.4) or an
// artifact; the one of the latest engine when it is "".
version_pick :: proc(l:Listing,wanted:string) -> (v:Version,problem:string) {
    if len(l.versions)==0 {return {},"the listing has no build in the Unreal format: use one of its other formats"}
    best:=-1
    for version,i in l.versions {
        if wanted!="" {
            if version.artifact==wanted || slice.contains(version.engines,wanted) || slice.contains(version.engines,strings.concatenate({"UE_",wanted},context.temp_allocator)) {return version,""}
            continue
        }
        if best<0 || engine_newest(version)>engine_newest(l.versions[best]) {best=i}
    }
    if wanted!="" {
        engines:=make([dynamic]string,context.temp_allocator)
        for version in l.versions {append(&engines,..version.engines)}
        return {},fmt.tprintf("the listing has no build for %q: it has %s",wanted,strings.join(engines[:],", ",context.temp_allocator))
    }
    return l.versions[best],""
}

// The newest engine of a version as a number that orders them: 5.4 is 5004.
@(private="file")
engine_newest :: proc(v:Version) -> int {
    newest:=0
    for engine in v.engines {
        text:=strings.trim_prefix(engine,"UE_")
        dot:=strings.index_byte(text,'.')
        if dot<0 {continue}
        major,major_ok:=strconv.parse_int(text[:dot])
        minor,minor_ok:=strconv.parse_int(text[dot+1:])
        if major_ok && minor_ok {newest=max(newest,major*1000+minor)}
    }
    return newest
}

@(private="file")
listing_clone :: proc(l:Listing,a:mem.Allocator) -> Listing {
    strings_clone :: proc(list:[]string,a:mem.Allocator) -> []string {
        out:=make([]string,len(list),a)
        for s,i in list {out[i]=strings.clone(s,a)}
        return out
    }
    out:=Listing{title=strings.clone(l.title,a),url=strings.clone(l.url,a),asset_id=strings.clone(l.asset_id,a),namespace=strings.clone(l.namespace,a)}
    out.versions=make([]Version,len(l.versions),a)
    for v,i in l.versions {out.versions[i]={strings.clone(v.artifact,a),strings_clone(v.engines,a),strings_clone(v.platforms,a)}}
    return out
}

@(private="file")
job_work :: proc(job:^Job) {
    a:=virtual.arena_allocator(&job.arena)
    defer csync.atomic_store(&job.done,true)
    if job.kind==.Sign_In {
        d,problem:=sign_in_begin(a)
        if problem!="" {job.problem=problem;return}
        job.url=d.url
        csync.atomic_store(&job.url_ready,true)
        browser_open(d.url)
        s:Session
        s,job.problem=sign_in_wait(d,&job.progress.cancel,a)
        job.name=s.display_name
        return
    }
    if job.kind==.Sign_Out {
        job.problem=session_logout(a)
        return
    }
    s,found,problem:=session_load(a)
    if problem!="" {job.problem=problem;return}
    if !found {job.problem="the account is not signed in to Fab: sign in first";return}
    job.name=s.display_name
    switch job.kind {
    case .Sign_In,.Sign_Out:
    case .Library:
        job.listings,job.problem=library_read(s,a)
    case .Contents:
        job.formats,job.problem=listing_formats(job.uid,a)
        if job.problem!="" || len(job.listing.versions)==0 {return}
        if job.picked,job.problem=version_pick(job.listing,job.version);job.problem!="" {job.problem=strings.clone(job.problem,a);return}
        m,_,build_problem:=unreal_build(s,job.listing,job.picked.artifact,"",a)
        if build_problem!="" {job.problem=build_problem;return}
        root:=content_root(&m)
        list:=make([dynamic]string,a)
        for file in m.files {if strings.has_prefix(file.name,root) {append(&list,file.name[len(root):])}}
        slice.sort(list[:])
        job.contents=list[:]
    case .Download:
        staging,staging_error:=os.make_directory_temp(job.staging,"download-*",a)
        if staging_error!=nil {job.problem=fmt.aprintf("%s cannot hold the download: %v",job.staging,staging_error,allocator=a);return}
        b:=Build{staging=staging,progress=&job.progress}
        defer build_destroy(&b)
        if job.format==FORMAT_UNREAL || job.format=="" {
            if job.picked,job.problem=version_pick(job.listing,job.version);job.problem!="" {job.problem=strings.clone(job.problem,a);return}
            if b.manifest,b.base,job.problem=unreal_build(s,job.listing,job.picked.artifact,"",a);job.problem!="" {return}
            job.written,job.problem=unreal_download(&b,job.picks,job.folder,a)
        } else {
            direct:string
            if b.manifest,b.base,direct,job.problem=format_build(s,job.uid,job.format,job.file,staging,a);job.problem!="" {return}
            job.written,job.problem=format_download(&b,direct,job.folder,a)
        }
    }
}
