package unreal_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:cook/import/sources"
import "mirai:editor"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"
import "project:plugins/unreal/editor/fab"
import unreal "project:plugins/unreal/editor/package"

// The library of the Fab account in the editor, under View > Fab and the
// unreal.fab.* methods: a listing comes in the Unreal format (the packages
// picked and what they read, or the whole build) or in another one (a file
// of FBX, glTF, OBJ), into a folder of the assets, and what it brings is
// imported as it lands. One job talks to Fab at a time; the panel and an
// agent see the same jobs.

FAB_STAGING :: ".mirai/tmp/fab" // of the project: the chunks while they download
FAB_ROWS :: 200                 // of a list the panel shows

@(storage)
Unreal_Fab :: struct {
    open:bool,
    job:^fab.Job,      // the one that runs
    library:^fab.Job,  // the last library read
    contents:^fab.Job, // the last contents read
    download:^fab.Job, // the last download
    signed:bool,       // as far as the last job knew
    name:[64]u8,
    message:[512]u8,
    failed:bool,       // the last job that ended failed: message says why
    imports:[dynamic]string, // absolute, waiting their turn of the importer
    queued:int,        // of the last download, the files it gave to import
    // The panel.
    filter:[128]u8,filter_length:int,
    folder:[256]u8,folder_length:int,
    listing:int,       // into the library; -1 none
    format:int,        // into the formats of the contents; -1 the Unreal build
    file:int,          // into the files of that format
    picked:[dynamic]bool, // by entry of the contents
    scroll:[2][2]f32,
}

unreal_fab_default :: proc() -> Unreal_Fab {return {listing=-1,format=-1}}

@(private)
fab_of :: proc(s:^editor.Session) -> ^Unreal_Fab {
    if s.info==nil || s.editor_world==nil {return nil}
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Unreal_Fab)
}

// Starts a job unless one runs; false with why in message otherwise.
@(private)
fab_start :: proc(s:^editor.Session,f:^Unreal_Fab,given:fab.Job_Given) -> bool {
    if f.job!=nil {base.text_set(f.message[:],"Fab is busy with another job");return false}
    given:=given
    given.staging=project.path(s.project_root,FAB_STAGING,allocator=context.temp_allocator)
    _=os.make_directory_all(given.staging)
    f.job=fab.job_start(given)
    base.text_set(f.message[:],"")
    return true
}

// The listing of the library the panel or a method names: an index, its
// identifier or the address of its page.
@(private)
fab_listing :: proc(f:^Unreal_Fab,text:string) -> (l:fab.Listing,found:bool) {
    if f.library==nil {return}
    uid:=fab.uid_from_text(text)
    for listing in f.library.listings {
        if fab.listing_uid(listing)==uid {return listing,true}
    }
    return
}

@(step="frame")
unreal_fab_poll :: proc(s:^editor.Session,f:^Unreal_Fab) {
    if f.job!=nil && fab.job_poll(f.job) {
        job:=f.job
        f.job=nil
        if job.name!="" {base.text_set(f.name[:],job.name)}
        if job.problem!="" {base.text_set(f.message[:],job.problem)}
        f.signed=job.kind!=.Sign_Out && (job.problem=="" || job.kind!=.Sign_In && !strings.contains(job.problem,"sign in"))
        f.failed=job.problem!=""
        slot:^^fab.Job
        switch job.kind {
        case .Sign_In,.Sign_Out:
        case .Library:  slot=&f.library
        case .Contents: slot=&f.contents
        case .Download: slot=&f.download
        }
        // A job that failed leaves what the last good one read.
        if slot==nil || f.failed {
            fab.job_destroy(job)
            return
        }
        fab.job_destroy(slot^)
        slot^=job
        switch job.kind {
        case .Sign_In,.Sign_Out,.Download:
        case .Library:  f.listing=-1
        case .Contents:
            f.format,f.file=-1,0
            clear(&f.picked)
            resize(&f.picked,len(job.contents))
        }
        if job.kind==.Download && !job.no_import {fab_imports_queue(s,f,job)}
    }
    // The imports of a download, one after the other.
    if len(f.imports)>0 && s.importer.running==nil {
        next:=pop_front(&f.imports)
        defer delete(next)
        if !editor.import_file(s,next) {base.text_set(f.message[:],string(s.importer.message[:s.importer.message_length]))}
    }
}

// What of a download is imported: of the Unreal format, the maps and the
// packages of meshes picked, or every map of a whole build (its meshes when
// it has none); of another format, its models.
@(private)
fab_imports_queue :: proc(s:^editor.Session,f:^Unreal_Fab,job:^fab.Job) {
    unreal_format:=job.format==fab.FORMAT_UNREAL || job.format==""
    maps,models:=make([dynamic]string,context.temp_allocator),make([dynamic]string,context.temp_allocator)
    for written in job.written {
        path:=fab.path_join({job.folder,written},context.temp_allocator)
        if !unreal_format {
            if sources.source_kind(path)==.Model {append(&models,path)}
            continue
        }
        if len(job.picks)>0 && !fab_picked(job.picks,written) {continue}
        if strings.has_suffix(written,".umap") {append(&maps,path)} else if fab_package_model(path) {append(&models,path)}
    }
    queued:=models[:]
    if unreal_format && len(maps)>0 {queued=maps[:]}
    if unreal_format && len(job.picks)>0 {append(&maps,..models[:]);queued=maps[:]}
    for path in queued {append(&f.imports,strings.clone(path))}
    f.queued=len(queued)
    base.text_set(f.message[:],fmt.tprintf("%d files downloaded; %d to import",len(job.written),len(queued)))
}

// Whether written is a pick or under one.
@(private)
fab_picked :: proc(picks:[]string,written:string) -> bool {
    for pick in picks {
        clean:=strings.trim(pick,"/")
        if written==clean || strings.has_prefix(written,clean) && len(written)>len(clean) && written[len(clean)]=='/' {return true}
    }
    return false
}

// Whether the package at path holds a static or a skeletal mesh: what the
// Unreal format imports from a package of its own.
@(private)
fab_package_model :: proc(path:string) -> bool {
    bytes,read_error:=serial.file_read(path,context.temp_allocator,limit=i64(unreal.DEFAULT_LIMITS.source_bytes))
    if read_error!=.None {return false}
    p,open_error:=unreal.package_open(bytes,context.temp_allocator,unreal.DEFAULT_LIMITS)
    if open_error.code!=.None {return false}
    for export in p.exports {
        name,ok:=unreal.reference_name(&p,export.class)
        if !ok {continue}
        switch unreal.name_plain(&p,name) {
        case "StaticMesh","SkeletalMesh": return true
        }
    }
    return false
}

// The folder of the assets a download goes to, absolute, or why it cannot.
@(private)
fab_folder :: proc(s:^editor.Session,folder:string) -> (path,refusal:string) {
    a:=s.app.assets
    if a==nil || a.registry.root=="" {return "","the project has no asset folder to download into"}
    clean:string
    if clean,refusal=editor.asset_folder_clean(&a.registry,folder);refusal!="" {return}
    if clean=="" {return "","give a folder of the assets for the download: what it brings keeps its own folders inside it"}
    return asset.registry_file_path(&a.registry,clean,context.temp_allocator),""
}

@(step="ui",after="editor_panels")
unreal_fab_panel :: proc(s:^editor.Session,f:^Unreal_Fab) {
    g:=s.gui
    if !g.begun || editor.playing(s) || !f.open {return}
    ctx:=g.ctx
    id:=ui.id_derive(ctx,ui.Id(0x66616221),"panel")
    small:=ui.metric(ctx,"font_small")
    control:=ui.metric(ctx,"control")
    if !ui.panel(ctx,id,{width=ui.fixed(clamp(ctx.size.x*0.4,420,640)),height=ui.FIT,padding=ui.padding_all(12),gap=8,anchor=.Center,pivot=.Center}) {return}
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    busy:=f.job!=nil
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center}) {
        ui.label(ctx,"Fab",ui.metric(ctx,"font"),ui.tone(ctx,"text_label"))
        ui.spacer(ctx)
        if f.signed {ui.label(ctx,base.text_get(f.name[:]),small,ui.tone(ctx,"text_faint"))}
        if ui.icon_button(ctx,ui.id(ctx,"close"),.Cross,16).clicked {f.open=false}
    }
    if !f.signed {
        if ui.button(ctx,ui.id(ctx,"sign_in"),{label="Sign in with Epic",variant="accent",width=-1,height=control,center=true,disabled=busy}).clicked {
            fab_start(s,f,{kind=.Sign_In})
        }
    } else if ui.box(ctx,{width=ui.GROW,height=ui.fixed(control),gap=6,align_y=.Center}) {
        ui.text_field(ctx,ui.id(ctx,"filter"),f.filter[:],&f.filter_length,{icon=.Filter,live=true,height=control})
        if ui.icon_button(ctx,ui.id(ctx,"refresh"),.Refresh,18,tip="Read the library",disabled=busy).clicked {fab_start(s,f,{kind=.Library})}
        if ui.button(ctx,ui.id(ctx,"sign_out"),{label="Sign out",variant="field",height=control,disabled=busy}).clicked {
            fab_start(s,f,{kind=.Sign_Out})
        }
    }
    filter:=strings.trim_space(string(f.filter[:f.filter_length]))
    if f.signed && f.library!=nil {
        ui.scroll_begin(ctx,ui.id(ctx,"listings"),&f.scroll[0],{width=ui.GROW,height=ui.FIT,max_height=200})
        shown:=0
        for l,i in f.library.listings {
            if filter!="" && !base.contains_fold(l.title,filter) {continue}
            if shown>=FAB_ROWS {break}
            shown+=1
            engines:=""
            if len(l.versions)>0 {engines=strings.join(l.versions[len(l.versions)-1].engines,", ",context.temp_allocator)}
            if ui.row(ctx,ui.id(ctx,"listing",i+1),{label=l.title,detail=engines,accent=f.listing==i,height=ui.metric(ctx,"row")}).clicked && !busy {
                f.listing=i
                fab_start(s,f,{kind=.Contents,listing=l,uid=fab.listing_uid(l)})
            }
        }
        ui.scroll_end(ctx,ui.id(ctx,"listings"),&f.scroll[0])
    }
    if c:=f.contents;f.signed && c!=nil && f.library!=nil && f.listing>=0 {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(control),gap=6,align_y=.Center}) {
            if len(c.contents)>0 && ui.button(ctx,ui.id(ctx,"unreal"),{label="Unreal",variant="field",active=f.format<0,height=control}).clicked {f.format=-1}
            for format,i in c.formats {
                if format.type.code==fab.FORMAT_UNREAL || len(format.files)==0 {continue}
                if ui.button(ctx,ui.id(ctx,"format",i+1),{label=format.type.name,variant="field",active=f.format==i,height=control}).clicked {f.format,f.file=i,0}
            }
        }
        ui.scroll_begin(ctx,ui.id(ctx,"files"),&f.scroll[1],{width=ui.GROW,height=ui.FIT,max_height=240})
        if f.format<0 {
            shown:=0
            for entry,i in c.contents {
                if !strings.has_suffix(entry,".uasset") && !strings.has_suffix(entry,".umap") {continue}
                if filter!="" && !base.contains_fold(entry,filter) {continue}
                if shown>=FAB_ROWS {break}
                shown+=1
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center}) {
                    if i<len(f.picked) {ui.checkbox(ctx,ui.id(ctx,"pick",i+1),&f.picked[i])}
                    ui.label(ctx,entry,small,ui.tone(ctx,"text"))
                }
            }
        } else if f.format<len(c.formats) {
            for file,i in c.formats[f.format].files {
                if ui.row(ctx,ui.id(ctx,"format_file",i+1),{label=file.name,detail=fmt.tprintf("%.1f MB",f64(file.size)/(1<<20)),accent=f.file==i,height=ui.metric(ctx,"row")}).clicked {f.file=i}
            }
        }
        ui.scroll_end(ctx,ui.id(ctx,"files"),&f.scroll[1])
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(control),gap=6,align_y=.Center}) {
            if f.folder_length==0 {base.text_set(f.folder[:],fab_folder_default(f.library.listings[f.listing].title));f.folder_length=len(base.text_get(f.folder[:]))}
            ui.text_field(ctx,ui.id(ctx,"folder"),f.folder[:],&f.folder_length,{label="Folder",live=true,height=control})
            if ui.button(ctx,ui.id(ctx,"download"),{label="Download",variant="accent",height=control,disabled=busy}).clicked {
                fab_panel_download(s,f)
            }
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,align_y=.Center}) {
        if j:=f.job;j!=nil {
            text:=fab_doing(j)
            ui.label(ctx,text,small,ui.tone(ctx,"text_faint"))
            ui.spacer(ctx)
            if (j.kind==.Download || j.kind==.Sign_In) && ui.button(ctx,ui.id(ctx,"stop"),{label="Stop",variant="field"}).clicked {fab.job_cancel(j)}
        } else if message:=base.text_get(f.message[:]);message!="" {
            ui.label(ctx,message,small,ui.tone(ctx,"text_faint"),width=-1)
        }
    }
}

// What a job that runs is doing, as the panel and unreal.fab.status say it.
@(private)
fab_doing :: proc(j:^fab.Job) -> string {
    switch j.kind {
    case .Sign_In:  return "Waiting for the sign in at the Epic page in the browser"
    case .Sign_Out: return "Ending the session"
    case .Library:  return "Reading the library"
    case .Contents: return "Reading the listing"
    case .Download:
        total:=j.progress.total
        if total==0 {return "Downloading"}
        return fmt.tprintf("Downloading: %.1f of %.1f MB, %d files",f64(j.progress.bytes)/(1<<20),f64(total)/(1<<20),j.progress.files)
    }
    return ""
}

// The folder a listing goes to by default: its title, as a folder may name it.
@(private)
fab_folder_default :: proc(title:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for c in transmute([]u8)title {
        switch {
        case c>='A' && c<='Z' || c>='a' && c<='z' || c>='0' && c<='9' || c=='-' || c=='_': strings.write_byte(&b,c)
        case c==' ' && strings.builder_len(b)>0: strings.write_byte(&b,'_')
        }
    }
    return strings.to_string(b) if strings.builder_len(b)>0 else "Fab"
}

@(private)
fab_panel_download :: proc(s:^editor.Session,f:^Unreal_Fab) {
    c:=f.contents
    l:=f.library.listings[f.listing]
    folder,refusal:=fab_folder(s,string(f.folder[:f.folder_length]))
    if refusal!="" {base.text_set(f.message[:],refusal);return}
    given:=fab.Job_Given{kind=.Download,listing=l,uid=fab.listing_uid(l),version=c.picked.artifact,folder=folder,format=fab.FORMAT_UNREAL}
    if f.format>=0 {
        format:=c.formats[f.format]
        if f.file>=len(format.files) {return}
        given.format,given.file=format.type.code,format.files[f.file].uid
    } else {
        picks:=make([dynamic]string,context.temp_allocator)
        for on,i in f.picked {if on {append(&picks,c.contents[i])}}
        given.picks=picks[:]
    }
    fab_start(s,f,given)
}
