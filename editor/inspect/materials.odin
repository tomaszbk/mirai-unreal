package inspect

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import uasset "project:plugins/unreal/editor/model"
import "project:plugins/unreal/editor/material"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/serial"

// unreal.inspect --materials: translates every Material and
// MaterialInstanceConstant to Mirai's model and reports how: the standard
// model alone, a program, or a failure, and the expressions that could not
// be translated. --slang writes the programs, to check them with
// `mirai shaders check`.

@(private="file")
Material_Report :: struct {
    standard,program,failed,layers:int,
    untranslated:map[string]int,
    programs:map[string]bool,
    failures:map[string]int,
}

inspect_materials :: proc(w:io.Writer,files:[]string,given:[]unreal.Source_Mount,slang:string) -> int {
    mounts:=make([dynamic]unreal.Source_Mount)
    append(&mounts,..given)
    lib:material.Library
    engine:=""
    for m in given {if m.package_prefix=="/Engine" {engine=m.directory}}
    engine_found:=engine==""
    if engine_found {engine=unreal.engine_content_find(context.allocator)}
    // Mounts are known before the library opens anything: of those mirai
    // import finds, the one most packages agree on, since a package renamed in
    // its project keeps the old name among its names.
    votes:=make(map[string]int)
    directories:=make(map[string]string)
    guess:=true
    for m in given {guess&&=!strings.has_prefix(m.package_prefix,"/Game")}
    for path,i in files {
        if !guess || i>=64 {break}
        bytes,read_error:=serial.file_read(path,limit=i64(unreal.DEFAULT_LIMITS.source_bytes))
        if read_error!=.None {continue}
        defer delete(bytes)
        p,error:=unreal.package_open(bytes,context.temp_allocator)
        if error.code!=.None {continue}
        found:=uasset.mounts_find(path,{engine_content=engine},&p,context.temp_allocator)
        if len(found)>0 && found[0].package_prefix!="/Engine" {
            mount:=found[0]
            key:=strings.concatenate({mount.package_prefix,"=",mount.directory})
            if key in votes {delete(key)} else {directories[key]=strings.clone(mount.directory)}
            votes[key]+=1
        }
        free_all(context.temp_allocator)
    }
    best:=""
    for key,count in votes {if best=="" || count>votes[best] {best=key}}
    if best!="" {append(&mounts,unreal.Source_Mount{best[:strings.index_byte(best,'=')],directories[best]})}
    if engine_found && engine!="" {append(&mounts,unreal.Source_Mount{"/Engine",engine})}
    for m in mounts {fmt.wprintfln(w,"mount %s = %s",m.package_prefix,m.directory)}
    material.library_init(&lib,mounts[:])
    defer material.library_destroy(&lib)
    report:Material_Report
    for path in files {
        name,name_error:=unreal.source_package_name(path,mounts[:],context.temp_allocator)
        if name_error.code!=.None {continue}
        opened:=material.library_open(&lib,name)
        if opened==nil || opened.error.code!=.None {continue}
        for &item,index in opened.p.exports {
            if item.outer!=0 {continue}
            object:=material.Object{opened,index}
            class:=material.object_class(object)
            if class!="Material" && class!="MaterialInstanceConstant" {continue}
            material_inspect(w,&lib,object,slang,&report)
        }
        free_all(context.temp_allocator)
    }
    fmt.wprintfln(w,"%d materials: %d with the standard model, %d with a program (%d programs), %d failed; %d landscape layers",
        report.standard+report.program+report.failed,report.standard,report.program,len(report.programs),report.failed,report.layers)
    classes:=make([dynamic]string)
    for class in report.untranslated {append(&classes,class)}
    slice.sort_by(classes[:],proc(a,b:string) -> bool {return a<b})
    for class in classes {fmt.wprintfln(w,"  untranslated %s: %d",class,report.untranslated[class])}
    for reason,count in report.failures {fmt.wprintfln(w,"  failure %s: %d",reason,count)}
    return report.failed>0?1:0
}

@(private="file")
material_inspect :: proc(w:io.Writer,lib:^material.Library,object:material.Object,slang:string,report:^Material_Report) {
    t,error:=material.translate(lib,object)
    if error.code!=.None {
        report.failed+=1
        reason:=strings.clone(error.message)
        if reason in report.failures {report.failures[reason]+=1;delete(reason)} else {report.failures[reason]=1}
        fmt.wprintfln(w,"FAIL %s: %s",material.object_path(object),error.message)
        return
    }
    defer material.translated_destroy(&t)
    material_line(w,&t,"",slang,report)
    if len(t.layers)>0 {
        layers,layers_error:=material.landscape_layers(lib,object)
        if layers_error.code!=.None {
            fmt.wprintfln(w,"  layers: %s",layers_error.message)
            return
        }
        defer material.landscape_layers_destroy(layers)
        for &layer in layers {
            report.layers+=1
            material_line(w,&layer.material,layer.name,slang,nil)
        }
    }
}

@(private="file")
material_line :: proc(w:io.Writer,t:^material.Translated_Material,layer,slang:string,report:^Material_Report) {
    kind:="standard"
    if !material.translated_is_standard(t) {kind=fmt.tprintf("program %s",t.program.name)}
    if layer!="" {
        fmt.wprintfln(w,"  layer %s: %s",layer,kind)
    } else {
        fmt.wprintfln(w,"%s %s",kind,t.path)
    }
    maps:=strings.builder_make(context.temp_allocator)
    for image,map_kind in t.images {if image!=material.MAP_NONE {fmt.sbprintf(&maps," %v",map_kind)}}
    if len(maps.buf)>0 {fmt.wprintfln(w,"    maps:%s",strings.to_string(maps))}
    for note in t.notes {fmt.wprintfln(w,"    %s",note)}
    if report!=nil {
        if material.translated_is_standard(t) {report.standard+=1} else {report.program+=1}
        for u in t.untranslated {
            if u.class in report.untranslated {report.untranslated[u.class]+=u.count} else {report.untranslated[strings.clone(u.class)]=u.count}
        }
    }
    if t.program.name!="" {
        if report!=nil && t.program.name not_in report.programs {report.programs[strings.clone(t.program.name)]=true}
        if slang!="" {
            os.make_directory_all(slang)
            file,_:=filepath.join({slang,fmt.tprintf("%s.slang",t.program.name)},context.temp_allocator)
            if serial.file_write_atomic(file,transmute([]u8)t.program.source)!=.None {fmt.wprintfln(w,"    could not write %s",file)}
        }
    }
}
