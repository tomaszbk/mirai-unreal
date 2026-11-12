package unreal_editor

import "core:os"
import "core:strings"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "project:plugins/unreal/editor/inspect"
import unreal "project:plugins/unreal/editor/package"

@(storage)
Unreal_Api :: struct {provider:editor.Api_Provider}

UNREAL_API_DEFAULT :: Unreal_Api{provider={register=unreal_api_register}}

INSPECT_MOUNTS :: 8
INSPECT_REPORT :: ".mirai/tmp/unreal-inspect.txt"

Inspect_Params :: struct {
    path:[editor.API_PATH_BYTES]u8 `mirai:"text,label=An uncooked Unreal package (.uasset or .umap) or a folder of them anywhere on disk; nothing is written into it"`,
    mode:inspect.Mode `mirai:"optional,label=Summary: versions and tables and exports; Objects: properties and native tail of each export; Payloads: the payloads of the trailer; Textures: decodes them; Materials: translates them; Meshes or Skeletal or Anims: reads them against the bounds the package keeps; Level: actors and cells and landscapes and foliage of a map"`,
    mounts:[INSPECT_MOUNTS][editor.API_PATH_BYTES]u8 `mirai:"text,optional,label=/Prefix=folder for a prefix of packages as /Game=C:/Game/Content; by default each package finds its own"`,
    out:[editor.API_PATH_BYTES]u8 `mirai:"text,optional,label=A folder under .mirai/tmp/ of the project for the payloads or the PNGs of Textures or the Slang of Materials"`,
    hi_res:bool `mirai:"optional,label=Meshes: the high-resolution source model instead of LOD 0"`,
}

Inspect_Result :: struct {
    ok:bool `mirai:"label=Everything was read; the report says what failed otherwise"`,
    report:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The file with the report under .mirai/tmp/ of the project"`,
}

@(private)
unreal_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="unreal.inspect",summary="Reads uncooked Unreal packages without Unreal and writes a report of what it read, to diagnose an import: tables, properties, payloads, textures, materials, meshes, animations or the actors of a map. Writes no assets.",params=type_info_of(Inspect_Params),result=type_info_of(Inspect_Result),flags={.Read_Only},run=unreal_api_inspect})
}

@(private)
unreal_api_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Inspect_Params)
    if !s.has_project {api.call_fail(call,api.SERVER_ERROR,"There is no project: the report goes to .mirai/tmp/ of the project");return}
    o:=inspect.Options{target=base.text_get(p.path[:]),mode=p.mode,hi_res=p.hi_res}
    if !os.exists(o.target) {api.call_failf(call,api.INVALID_PARAMS,"path %q does not exist: give a .uasset, a .umap or a folder of them",o.target);return}
    temporary:=project.path(s.project_root,".mirai/tmp",allocator=context.temp_allocator)
    if out:=base.text_get(p.out[:]);out!="" {
        o.out=project.path(s.project_root,out,allocator=context.temp_allocator)
        if !strings.has_prefix(o.out,temporary) {api.call_failf(call,api.INVALID_PARAMS,"out %q is not inside .mirai/tmp/ of the project: what inspect writes goes there",out);return}
    }
    mounts:=make([dynamic]unreal.Source_Mount,context.temp_allocator)
    for &text,at in p.mounts {
        given:=base.text_get(text[:])
        if given=="" {continue}
        mount,ok:=inspect.mount_parse(given)
        if !ok {api.call_failf(call,api.INVALID_PARAMS,"mounts[%d] %q is not /Prefix=folder with a folder that exists",at,given);return}
        append(&mounts,mount)
    }
    o.mounts=mounts[:]
    report:=strings.builder_make(context.temp_allocator)
    ok:=inspect.run(strings.to_writer(&report),o)
    path:=project.path(s.project_root,INSPECT_REPORT,allocator=context.temp_allocator)
    os.make_directory_all(temporary)
    if os.write_entire_file(path,transmute([]u8)strings.to_string(report))!=nil {api.call_failf(call,api.SERVER_ERROR,"The report could not be written to %s",path);return}
    out:=api.call_result(call,Inspect_Result)
    out.ok=ok
    base.text_set(out.report[:],INSPECT_REPORT)
}
