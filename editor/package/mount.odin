package unreal

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "mirai:std/serial"

// A package prefix such as /Game or /Engine and the absolute folder of its
// content. Package names and file paths convert only through explicit mounts.
Source_Mount :: struct {package_prefix,directory:string}

long_package_name_valid :: proc(name:string) -> bool {
    if len(name)<2 || len(name)>1024 || name[0]!='/' || name[len(name)-1]=='/' {return false}
    segment:=1
    for byte,index in transmute([]u8)name {
        if index==0 {continue}
        if byte=='/' {
            if index==segment || source_device_name(name[segment:index]) {return false}
            segment=index+1
        } else if !(byte>='a' && byte<='z' || byte>='A' && byte<='Z' || byte>='0' && byte<='9' || byte=='_' || byte=='-') {return false}
    }
    return !source_device_name(name[segment:])
}

source_package_path :: proc(name:string,mounts:[]Source_Mount,allocator:=context.allocator,extension:=".uasset") -> (path:string,error:Error) {
    if !long_package_name_valid(name) {return "",{.Invalid_Reference,0,"canonical package name"}}
    if extension!=".uasset" && extension!=".umap" {return "",{.Unsupported_Value,0,"source package extension must be uasset or umap"}}
    selected:=-1
    for mount,index in mounts {
        if len(name)>len(mount.package_prefix) && package_prefix_matches(name,mount.package_prefix) && (selected<0 || len(mount.package_prefix)>len(mounts[selected].package_prefix)) {selected=index}
    }
    if selected<0 {return "",{.Invalid_Reference,0,"no explicit content mount for the referenced package"}}
    mount:=mounts[selected]
    if !long_package_name_valid(mount.package_prefix) || !source_file_path_valid(mount.directory) {return "",{.Invalid_Reference,0,"invalid explicit content mount"}}
    relative:=name[len(mount.package_prefix)+1:]
    joined,allocation_error:=filepath.join({mount.directory,relative},allocator)
    if allocation_error!=nil {return "",{.Out_Of_Memory,0,"source package path"}}
    defer delete(joined,allocator)
    bytes,extension_error:=make([]u8,len(joined)+len(extension),allocator)
    if extension_error!=nil {return "",{.Out_Of_Memory,0,"source package extension"}}
    copy(bytes,joined);copy(bytes[len(joined):],extension)
    return string(bytes),{}
}

source_package_name :: proc(path:string,mounts:[]Source_Mount,allocator:=context.allocator) -> (name:string,error:Error) {
    if !source_file_path_valid(path) {return "",{.Invalid_Reference,0,"absolute source package file path"}}
    selected,selected_offset:=-1,-1
    relative:string
    for mount,index in mounts {
        offset,matches:=source_mount_relative(path,mount.directory)
        if matches && offset>selected_offset {relative,selected,selected_offset=path[offset:],index,offset} else if matches && offset==selected_offset {return "",{.Invalid_Reference,0,"source path has ambiguous content mounts"}}
    }
    if selected<0 {return "",{.Invalid_Reference,0,"source file is outside the explicit content mounts"}}
    if !strings.has_suffix(relative,".uasset") && !strings.has_suffix(relative,".umap") {return "",{.Invalid_Reference,0,"source package extension must be uasset or umap"}}
    end:=strings.last_index_byte(relative,'.')
    prefix:=mounts[selected].package_prefix
    bytes,allocation_error:=make([]u8,len(prefix)+1+end,allocator)
    if allocation_error!=nil {return "",{.Out_Of_Memory,0,"source package mount identity"}}
    copy(bytes,prefix);bytes[len(prefix)]='/'
    for byte,index in transmute([]u8)relative[:end] {bytes[len(prefix)+1+index]=byte=='\\'?'/':byte}
    name=string(bytes)
    if !long_package_name_valid(name) {delete(name,allocator);return "",{.Invalid_Reference,0,"source mount path is not a canonical package name"}}
    return
}

@(private)
source_file_path_valid :: proc(path:string) -> bool {
    if !filepath.is_abs(path) || len(path)>32768 {return false}
    if strings.has_prefix(path,"\\\\") || strings.has_prefix(path,"//") {return false}
    segment:=0
    for byte,index in transmute([]u8)path {
        if byte<32 || byte==127 || byte=='*' || byte=='?' || byte=='|' || byte=='<' || byte=='>' || byte==':' && index!=1 {return false}
        if byte=='/' || byte=='\\' {
            part:=path[segment:index]
            if part=="." || part==".." || source_device_name(part) {return false}
            segment=index+1
        }
    }
    part:=path[segment:]
    return part!="." && part!=".." && !source_device_name(part)
}

@(private)
source_mount_relative :: proc(path,directory:string) -> (offset:int,matches:bool) {
    if !source_file_path_valid(directory) {return}
    end:=len(directory)
    for end>0 && (directory[end-1]=='/' || directory[end-1]=='\\') {end-=1}
    if len(path)<=end+1 {return}
    for index in 0..<end {
        a,b:=path[index],directory[index]
        if a=='\\' {a='/'}
        if b=='\\' {b='/'}
        when ODIN_OS==.Windows {
            if a>='A' && a<='Z' {a+=32}
            if b>='A' && b<='Z' {b+=32}
        }
        if a!=b {return}
    }
    if path[end]!='/' && path[end]!='\\' {return}
    return end+1,true
}

@(private)
source_device_name :: proc(input:string) -> bool {
    name:=input
    end:=strings.index_byte(name,'.')
    if end>=0 {name=name[:end]}
    if len(name)<3 || len(name)>4 {return false}
    upper:[4]u8
    for byte,index in transmute([]u8)name {upper[index]=byte>='a' && byte<='z'?byte-32:byte}
    value:=string(upper[:len(name)])
    return value=="CON" || value=="PRN" || value=="AUX" || value=="NUL" || len(name)==4 && (value[:3]=="COM" || value[:3]=="LPT") && upper[3]>='1' && upper[3]<='9'
}

// The mount of a package that is not under a Content folder, from the name it
// keeps of itself among its names: the longest tail of its file path that
// ends that name gives the rest of the name as the prefix, the rest of the
// path as its folder. Both are in allocator.
source_mount_guess :: proc(path:string,p:^Package,allocator:=context.allocator) -> (mount:Source_Mount,ok:bool) {
    absolute,_:=filepath.abs(path,context.temp_allocator)
    slashed,_:=strings.replace_all(absolute,"\\","/",context.temp_allocator)
    stem:=slashed[:len(slashed)-len(filepath.ext(slashed))]
    own:=strings.concatenate({"/",filepath.base(stem)},context.temp_allocator)
    for &entry in p.names {
        name:=entry.text
        if !long_package_name_valid(name) || !strings.has_suffix(name,own) {continue}
        parts:=strings.split(name,"/",context.temp_allocator)
        for first in 2..<len(parts) {
            tail:=strings.join(parts[first:],"/",context.temp_allocator)
            if strings.has_suffix(stem,strings.concatenate({"/",tail},context.temp_allocator)) {
                prefix:=strings.join(parts[:first],"/",context.temp_allocator)
                return {strings.clone(prefix,allocator),strings.clone(stem[:len(stem)-len(tail)-1],allocator)},true
            }
        }
    }
    return
}

// The mount under which the package named package_name is a file in one of
// the folders above path: a package copied apart from its own name still
// finds the packages it references. Both are in allocator.
source_mount_near :: proc(path,package_name:string,allocator:=context.allocator) -> (mount:Source_Mount,ok:bool) {
    if !long_package_name_valid(package_name) {return}
    absolute,_:=filepath.abs(path,context.temp_allocator)
    parts:=strings.split(package_name,"/",context.temp_allocator)
    folder:=filepath.dir(absolute)
    for _ in 0..<16 {
        for first in 2..<len(parts) {
            tail:=strings.join(parts[first:],"/",context.temp_allocator)
            for extension in ([2]string{".uasset",".umap"}) {
                file,_:=filepath.join({folder,strings.concatenate({tail,extension},context.temp_allocator)},context.temp_allocator)
                if os.exists(file) {return {strings.join(parts[:first],"/",allocator),strings.clone(folder,allocator)},true}
            }
        }
        parent:=filepath.dir(folder)
        if parent==folder || parent=="" || parent=="." {break}
        folder=parent
    }
    return
}

@(private)
package_prefix_matches :: proc(name,prefix:string) -> bool {
    return len(name)>=len(prefix) && strings.equal_fold(name[:len(prefix)],prefix) && (len(name)==len(prefix) || name[len(prefix)]=='/')
}

// The Content folder of the engine: UNREAL_ENGINE (an installation or its
// Engine folder), else the newest UE_<version> where the Epic launcher
// installs them. "" when there is none.
engine_content_find :: proc(allocator:=context.temp_allocator) -> string {
    if value,exists:=os.lookup_env("UNREAL_ENGINE",context.temp_allocator);exists && value!="" {
        for candidate in ([2][]string{{value,"Content"},{value,"Engine","Content"}}) {
            joined,_:=filepath.join(candidate,context.temp_allocator)
            if os.is_dir(joined) {return strings.clone(joined,allocator)}
        }
        return ""
    }
    launcher:string
    when ODIN_OS==.Windows {
        files,exists:=os.lookup_env("ProgramFiles",context.temp_allocator)
        if !exists {return ""}
        launcher,_=filepath.join({files,"Epic Games"},context.temp_allocator)
    } else when ODIN_OS==.Darwin {
        launcher="/Users/Shared/Epic Games"
    } else {
        return ""
    }
    entries,error:=os.read_all_directory_by_path(launcher,context.temp_allocator)
    if error!=nil {return ""}
    best:string
    best_version:[2]int
    for entry in entries {
        if entry.type!=.Directory || !strings.has_prefix(entry.name,"UE_") {continue}
        parts:=strings.split(entry.name[3:],".",context.temp_allocator)
        version:[2]int
        for part,i in parts[:min(len(parts),2)] {version[i],_=strconv.parse_int(part)}
        content,_:=filepath.join({entry.fullpath,"Engine","Content"},context.temp_allocator)
        if !os.is_dir(content) {continue}
        if best=="" || version[0]>best_version[0] || version[0]==best_version[0] && version[1]>best_version[1] {best,best_version=content,version}
    }
    if best=="" {return ""}
    return strings.clone(best,allocator)
}

// The mounts of the plugins of the engine whose Content folder is engine:
// /<Plugin> for each folder of Engine/Plugins, up to ENGINE_PLUGIN_DEPTH
// below it, that holds a <Plugin>.uplugin and a Content folder (/Niagara for
// Engine/Plugins/FX/Niagara/Content).
engine_plugin_mounts :: proc(engine:string,allocator:=context.temp_allocator) -> []Source_Mount {
    mounts:=make([dynamic]Source_Mount,allocator)
    plugins,_:=filepath.join({filepath.dir(engine),"Plugins"},context.temp_allocator)
    engine_plugins_walk(plugins,ENGINE_PLUGIN_DEPTH,&mounts,allocator)
    return mounts[:]
}

ENGINE_PLUGIN_DEPTH :: 4

@(private="file")
engine_plugins_walk :: proc(folder:string,depth:int,mounts:^[dynamic]Source_Mount,allocator:=context.temp_allocator) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        if entry.type==.Directory || !strings.equal_fold(filepath.ext(entry.name),".uplugin") {continue}
        content,_:=filepath.join({folder,"Content"},context.temp_allocator)
        if os.is_dir(content) {
            append(mounts,Source_Mount{strings.concatenate({"/",filepath.stem(entry.name)},allocator),strings.clone(content,allocator)})
        }
        return
    }
    if depth==0 {return}
    for entry in entries {
        if entry.type==.Directory {engine_plugins_walk(entry.fullpath,depth-1,mounts,allocator)}
    }
}

// PROJECT_CONFIG_LIMIT: the largest config file of a project that is read.
@(private) PROJECT_CONFIG_LIMIT :: 1<<20

// The text of a file of the Config folder of the project whose content is
// /Game, such as DefaultEngine.ini; "" without a /Game mount or the file.
project_config_read :: proc(mounts:[]Source_Mount,name:string,allocator:=context.temp_allocator) -> string {
    for mount in mounts {
        if mount.package_prefix!="/Game" {continue}
        path,_:=filepath.join({filepath.dir(mount.directory),"Config",name},context.temp_allocator)
        text,error:=serial.file_read(path,allocator,limit=PROJECT_CONFIG_LIMIT)
        if error!=.None {return ""}
        return string(text)
    }
    return ""
}
