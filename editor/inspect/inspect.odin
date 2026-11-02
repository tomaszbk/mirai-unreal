package inspect

import "core:fmt"
import "core:io"
import "core:math/linalg"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import img "mirai:cook/image"
import "mirai:cook/textures"
import "project:plugins/unreal/editor/kraken"
import unreal_mesh "project:plugins/unreal/editor/mesh"
import unreal "project:plugins/unreal/editor/package"
import "project:plugins/unreal/editor/texture"
import "mirai:std/serial"

// Reads uncooked Unreal packages without Unreal, for unreal.inspect, and
// writes what it read to w. It writes no assets; Textures with an out folder
// writes the pixels a .tex would be built from. False when something failed.

Mode :: enum u8 {
    Summary,   // versions, tables and exports of each package
    Objects,   // saved properties and native tail of each export
    Payloads,  // payloads of the trailer, decompressed and checked; written to out, when given
    Textures,  // decodes the textures and sums up formats and failures; PNGs to out, when given
    Materials, // translates materials and instances and sums up what was not translated; Slang to out, when given
    Meshes,    // the geometry of each StaticMesh against the bounds the package keeps
    Skeletal,  // each SkeletalMesh (bones, LOD 0, weights) and Skeleton against the bounds the package keeps
    Anims,     // each AnimSequence: bone tracks, curves, markers, additives and root motion
    Level,     // actors, components, transforms, cells of World Partition, landscapes and foliage of each .umap
}

Options :: struct {
    target:string,                // a package or a folder of them
    mode:Mode,
    out:string,
    mounts:[]unreal.Source_Mount, // folders of package prefixes; by default deduced from each package
    hi_res:bool,                  // Meshes: the high-resolution source model instead of LOD 0
}

run :: proc(w:io.Writer,o:Options) -> bool {
    target,mode,out,mounts,hi_res:=o.target,o.mode,o.out,o.mounts,o.hi_res
    // The packages work in an arena of their own, emptied after each: what the
    // caller keeps in its temporary allocator (the report, the options) stays.
    scratch:vmem.Arena
    defer vmem.arena_destroy(&scratch)
    context.temp_allocator=vmem.arena_allocator(&scratch)
    if out!="" && os.make_directory_all(out)!=nil && !os.is_dir(out) {fmt.wprintfln(w,"unreal.inspect: cannot create '%s'",out);return false}
    files:[dynamic]string
    defer {
        for file in files {delete(file)}
        delete(files)
    }
    if os.is_dir(target) {
        walker:=os.walker_create(target)
        defer os.walker_destroy(&walker)
        for info in os.walker_walk(&walker) {
            if info.type==.Regular && (strings.has_suffix(info.fullpath,".uasset") || strings.has_suffix(info.fullpath,".umap")) {append(&files,strings.clone(info.fullpath))}
        }
        slice.sort(files[:])
    } else if os.exists(target) {
        append(&files,strings.clone(target))
    } else {
        fmt.wprintfln(w,"unreal.inspect: '%s' does not exist",target)
        return false
    }
    if mode==.Materials {return inspect_materials(w,files[:],mounts,out)==0}
    decoder,decoder_error:=kraken.decoder_make()
    if decoder_error!=nil {fmt.wprintln(w,"unreal.inspect: out of memory for the decoder");return false}
    defer kraken.decoder_destroy(&decoder)
    report:Texture_Report
    meshes:Mesh_Report
    skeletal:Skeletal_Report
    anims:Anim_Report
    failed:=false
    for path in files {
        if mode==.Level {
            if strings.has_suffix(path,".umap") {failed|=!unreal_inspect_level(w,path,mounts)}
            free_all(context.temp_allocator)
            continue
        }
        limits:=mode==.Meshes || mode==.Skeletal?unreal_mesh.LIMITS:unreal.DEFAULT_LIMITS
        bytes,read_error:=serial.file_read(path,limit=i64(limits.source_bytes))
        if read_error!=.None {fmt.wprintfln(w,"%s: could not be read (%v)",path,read_error);failed=true;continue}
        defer delete(bytes)
        p,error:=unreal.package_open(bytes,limits=limits)
        if error.code!=.None {
            switch mode {
            case .Textures:report.packages_failed[error.code]+=1
            case .Meshes:meshes.packages_failed[error.code]+=1
            case .Skeletal:skeletal.packages_failed[error.code]+=1
            case .Anims:anims.packages_failed[error.code]+=1
            case .Summary,.Objects,.Payloads,.Materials,.Level:failed=true
            }
            fmt.wprintfln(w,"%s: package %v at 0x%x: %s",path,error.code,error.offset,error.field)
            continue
        }
        defer unreal.package_destroy(&p)
        switch mode {
        case .Summary:inspect_summary(w,path,&p)
        case .Objects:inspect_objects(w,path,&p)
        case .Payloads:failed|=!inspect_payloads(w,path,&p,&decoder,out)
        case .Textures:inspect_textures(w,path,&p,&decoder,out,&report)
        case .Meshes:inspect_meshes(w,path,&p,&decoder,hi_res,&meshes)
        case .Skeletal:inspect_skeletal(w,path,&p,&decoder,mounts,&skeletal)
        case .Anims:inspect_anims(w,path,&p,&anims)
        case .Materials,.Level:
        }
        free_all(context.temp_allocator)
    }
    if mode==.Textures {
        texture_report_print(w,&report,len(files))
        failed|=report.failed>0
    }
    if mode==.Meshes {
        mesh_report_print(w,&meshes,len(files))
        failed|=meshes.failed>0
    }
    if mode==.Skeletal {
        skeletal_report_print(w,&skeletal,len(files))
        failed|=skeletal.failed>0
    }
    if mode==.Anims {
        anim_report_print(w,&anims,len(files))
        failed|=anims.failed>0
    }
    return !failed
}

@(private="file")
inspect_summary :: proc(w:io.Writer,path:string,p:^unreal.Package) {
    s:=p.summary
    fmt.wprintfln(w,"%s: UE4=%d UE5=%d names=%d imports=%d exports=%d",path,s.version_ue4,s.version_ue5,len(p.names),len(p.imports),len(p.exports))
    for item,index in p.exports {
        class,_:=unreal.reference_path(p,item.class,context.temp_allocator)
        fmt.wprintfln(w,"  [%d] %s %s data=%d",index+1,unreal.name_plain(p,item.object_name),class,item.data.size)
    }
}

@(private="file")
inspect_objects :: proc(w:io.Writer,path:string,p:^unreal.Package) {
    fmt.wprintfln(w,"%s: UE4=%d UE5=%d exports=%d",path,p.summary.version_ue4,p.summary.version_ue5,len(p.exports))
    for version in p.custom_versions {fmt.wprintfln(w,"  version %x=%d",version.guid,version.version)}
    for item,index in p.exports {
        class,_:=unreal.reference_path(p,item.class,context.temp_allocator)
        template,_:=unreal.reference_path(p,item.template,context.temp_allocator)
        fmt.wprintfln(w,"[%d] %s class=%s outer=%d template=%s flags=0x%x data=0x%x+%d",index+1,unreal.name_plain(p,item.object_name),class,item.outer,template,item.object_flags,item.data.offset,item.data.size)
        properties,error:=unreal.export_properties(p,index,true)
        defer unreal.properties_destroy(&properties)
        if error.code!=.None {fmt.wprintfln(w,"  properties: %v at 0x%x: %s",error.code,error.offset,error.field);continue}
        for &property in properties.items {
            fmt.wprintf(w,"  %s ",unreal.name_plain(p,property.name))
            for node,at in property.types[:property.type_count] {fmt.wprintf(w,"%s%s",at==0?"":"/",unreal.name_plain(p,node.name))}
            fmt.wprintf(w," 0x%x+%d",property.data.offset,property.data.size)
            value,value_error:=unreal.property_value(p,&property)
            defer unreal.value_destroy(&value)
            if value_error.code==.None {
                switch value.kind {
                case .Boolean:fmt.wprintf(w," = %v",value.boolean)
                case .Signed:fmt.wprintf(w," = %d",value.signed)
                case .Unsigned:fmt.wprintf(w," = %d",value.unsigned)
                case .Real:fmt.wprintf(w," = %g",value.real)
                case .Real_Vector:fmt.wprintf(w," = %v",value.vector[:value.vector_count])
                case .Name:fmt.wprintf(w," = %s",unreal.name_plain(p,value.name))
                case .Object:fmt.wprintf(w," = object %d",value.object)
                case .String:fmt.wprintf(w," = %q",value.text[:min(len(value.text),160)])
                case .Guid:fmt.wprintf(w," = %x",value.guid)
                }
            }
            fmt.wprintln(w,)
        }
        fmt.wprintf(w,"  native 0x%x+%d",properties.trailing.offset,properties.trailing.size)
        if properties.trailing.size>0 {
            start:=int(properties.trailing.offset)
            fmt.wprintf(w," %x",p.bytes[start:start+int(min(properties.trailing.size,64))])
        }
        fmt.wprintln(w,)
    }
}

@(private="file")
inspect_payloads :: proc(w:io.Writer,path:string,p:^unreal.Package,decoder:^kraken.Decoder,out:string) -> bool {
    trailer,error:=unreal.package_trailer(p.bytes,p.limits)
    if error.code!=.None {fmt.wprintfln(w,"%s: trailer %v: %s",path,error.code,error.field);return error.code==.Unsupported_Value}
    fmt.wprintfln(w,"%s: trailer 0x%x+%d, %d payloads",path,trailer.source.offset,trailer.source.size,trailer.count)
    ok:=true
    for index in 0..<trailer.count {
        entry,entry_error:=unreal.trailer_payload_at(trailer,index)
        if entry_error.code!=.None {fmt.wprintfln(w,"  [%d] %v: %s",index,entry_error.code,entry_error.field);ok=false;continue}
        if entry.access!=.Local {fmt.wprintfln(w,"  [%d] %x %v raw=%d",index,entry.id,entry.access,entry.raw_size);continue}
        _,bytes,_:=unreal.trailer_payload(trailer,entry.id)
        buffer,buffer_error:=unreal.compressed_buffer(bytes,p.limits)
        if buffer_error.code!=.None {fmt.wprintfln(w,"  [%d] %v: %s",index,buffer_error.code,buffer_error.field);ok=false;continue}
        raw:=make([]u8,int(buffer.raw_size))
        defer delete(raw)
        decode_error:=unreal.compressed_buffer_decode(buffer,raw,decoder)
        fmt.wprintf(w,"  [%d] %x %v compressor=%d blocks=%d %d -> %d",index,entry.id,buffer.method,buffer.compressor,buffer.block_count,len(bytes),len(raw))
        if decode_error.code!=.None {fmt.wprintfln(w," %v: %s",decode_error.code,decode_error.field);ok=false;continue}
        fmt.wprintln(w," BLAKE3 ok")
        if out!="" {
            name:=fmt.tprintf("%s-%d.bin",filepath.stem(path),index)
            file,_:=filepath.join({out,name},context.temp_allocator)
            if serial.file_write_atomic(file,raw)!=.None {fmt.wprintfln(w,"  could not write %s",name);ok=false}
        }
    }
    return ok
}

@(private="file")
Texture_Report :: struct {
    textures,decoded,failed:int,
    formats:[texture.Source_Format]int,
    compressions:[texture.Source_Compression]int,
    kinds:[texture.Kind]int,
    usages:[texture.Usage]int,
    approximations:[texture.Approximation]int,
    checks:[texture.Source_Check]int,
    failures:map[string]int,
    written:map[string]int, // PNG names already used, so a repeated texture name gets a suffix
    packages_failed:[unreal.Error_Code]int,
}

@(private="file")
inspect_textures :: proc(w:io.Writer,path:string,p:^unreal.Package,decoder:^kraken.Decoder,out:string,report:^Texture_Report) {
    for _,index in p.exports {
        if _,is_texture:=texture.texture_kind(p,index);!is_texture {continue}
        report.textures+=1
        name:=unreal.name_plain(p,p.exports[index].object_name)
        source,error:=texture.texture_read(p,index)
        defer texture.texture_destroy(&source)
        if error.code!=.None {inspect_failed(w,&report.failed,&report.failures,path,name,error);continue}
        report.formats[source.layers[0]]+=1
        report.compressions[source.compression]+=1
        report.kinds[source.kind]+=1
        report.usages[source.usage]+=1
        decoded,decode_error:=texture.texture_decode(p,&source,decoder)
        defer texture.decoded_destroy(&decoded)
        if decode_error.code!=.None {inspect_failed(w,&report.failed,&report.failures,path,name,decode_error);continue}
        input,input_error:=texture.texture_build_input(&source,&decoded)
        defer texture.build_input_destroy(&input)
        if input_error.code!=.None {inspect_failed(w,&report.failed,&report.failures,path,name,input_error);continue}
        report.decoded+=1
        report.checks[decoded.check]+=1
        for approximation in input.approximations {report.approximations[approximation]+=1}
        block:=source.blocks[0]
        built:=input.source
        fmt.wprintfln(w,"ok %s %s %v %dx%d slices=%d mips=%d layers=%d %v %v %v id=%v builds %v %dx%d images=%d cube=%v %v",path,name,source.kind,block.width,block.height,block.slices,block.mips,len(source.layers),source.layers[0],source.compression,source.usage,decoded.check,built.format,built.width,built.height,max(built.layers,1),built.cube,input.approximations)
        if out!="" {
            file_name:=fmt.tprintf("%s.png",name)
            if count,used:=report.written[name];used {file_name=fmt.tprintf("%s (%d).png",name,count+1)}
            if name not_in report.written {report.written[strings.clone(name)]=0}
            report.written[name]+=1
            file,_:=filepath.join({out,file_name},context.temp_allocator)
            pixels,_:=textures.source_image_rgba8(built,0,input.options.srgb,context.temp_allocator)
            if img.image_write(file,{pixels=pixels,width=built.width,height=built.height})!=.None {fmt.wprintfln(w,"  could not write %s",file)}
        }
    }
}

// Counts a failure of a reader by its reason and prints it.
@(private="file")
inspect_failed :: proc(w:io.Writer,failed:^int,failures:^map[string]int,path,name:string,error:unreal.Error) {
    failed^+=1
    reason:=fmt.aprintf("%v: %s",error.code,error.field)
    if reason in failures {failures[reason]+=1;delete(reason)} else {failures[reason]=1}
    fmt.wprintfln(w,"FAIL %s %s %v at 0x%x: %s",path,name,error.code,error.offset,error.field)
}

@(private="file")
texture_report_print :: proc(w:io.Writer,report:^Texture_Report,packages:int) {
    fmt.wprintfln(w,"%d packages, %d textures, %d decoded, %d failed",packages,report.textures,report.decoded,report.failed)
    for count,code in report.packages_failed {if count>0 {fmt.wprintfln(w,"  packages not opened %v: %d",code,count)}}
    for count,format in report.formats {if count>0 {fmt.wprintfln(w,"  format %v: %d",format,count)}}
    for count,compression in report.compressions {if count>0 {fmt.wprintfln(w,"  compression %v: %d",compression,count)}}
    for count,kind in report.kinds {if count>0 {fmt.wprintfln(w,"  kind %v: %d",kind,count)}}
    for count,usage in report.usages {if count>0 {fmt.wprintfln(w,"  usage %v: %d",usage,count)}}
    for count,check in report.checks {if count>0 {fmt.wprintfln(w,"  source id %v: %d",check,count)}}
    for count,approximation in report.approximations {if count>0 {fmt.wprintfln(w,"  approximation %v: %d",approximation,count)}}
    for reason,count in report.failures {fmt.wprintfln(w,"  failure %s: %d",reason,count)}
}

@(private="file")
Mesh_Report :: struct {
    meshes,decoded,failed,triangles,degenerate,bounds_match,bounds_differ,bounds_absent,hi_res:int,
    layouts:[unreal_mesh.Layout]int,
    failures:map[string]int,
    packages_failed:[unreal.Error_Code]int,
}

@(private="file")
inspect_meshes :: proc(w:io.Writer,path:string,p:^unreal.Package,decoder:^kraken.Decoder,hi_res:bool,report:^Mesh_Report) {
    for _,index in p.exports {
        if !unreal_mesh.static_mesh_is(p,index) {continue}
        report.meshes+=1
        name:=unreal.name_plain(p,p.exports[index].object_name)
        source,error:=unreal_mesh.mesh_read(p,index,hi_res?.Hi_Res:.Lod0)
        defer unreal_mesh.static_mesh_destroy(&source)
        if error.code!=.None {inspect_failed(w,&report.failed,&report.failures,path,name,error);continue}
        if source.hi_res {report.hi_res+=1}
        decoded,decode_error:=unreal_mesh.mesh_decode(p,&source,decoder)
        defer unreal_mesh.mesh_destroy(&decoded)
        if decode_error.code!=.None {inspect_failed(w,&report.failed,&report.failures,path,name,decode_error);continue}
        report.decoded+=1
        report.layouts[source.layout]+=1
        triangles:=len(decoded.triangle_section)
        report.triangles+=triangles
        report.degenerate+=decoded.degenerate
        bounds:="no bounds"
        if source.has_bounds {
            difference,size:=bounds_gap(decoded.bounds_min,decoded.bounds_max,source.bounds_min,source.bounds_max)
            if difference<=bounds_tolerance(size) {report.bounds_match+=1;bounds="bounds ok"} else {
                report.bounds_differ+=1
                bounds=fmt.tprintf("bounds differ by %.3f cm: %v..%v against %v..%v",difference,decoded.bounds_min,decoded.bounds_max,source.bounds_min,source.bounds_max)
            }
        } else {report.bounds_absent+=1}
        fmt.wprintfln(w,"ok %s %s %v triangles=%d degenerate=%d sections=%d uv=%d colors=%v %s",path,name,source.layout,triangles,decoded.degenerate,len(decoded.sections),decoded.uv_count,len(decoded.corner_color)>0,bounds)
    }
}

// The largest distance between the faces of two boxes, in cm, and the
// largest side of the second.
@(private="file")
bounds_gap :: proc(low,high,expected_low,expected_high:[3]f32) -> (gap,size:f32) {
    for i in 0..<3 {
        gap=max(gap,abs(low[i]-expected_low[i]),abs(high[i]-expected_high[i]))
        size=max(size,expected_high[i]-expected_low[i])
    }
    return
}

// How far bounds of that size may be from those a package keeps: 0.1 mm
// and a ten-thousandth of the size.
@(private="file")
bounds_tolerance :: proc(size:f32) -> f32 {return 0.01+size*1e-4}

@(private="file")
mesh_report_print :: proc(w:io.Writer,report:^Mesh_Report,packages:int) {
    fmt.wprintfln(w,"%d packages, %d meshes, %d read, %d failed, %d triangles, %d degenerate removed",packages,report.meshes,report.decoded,report.failed,report.triangles,report.degenerate)
    fmt.wprintfln(w,"  bounds: %d match, %d differ, %d without bounds; %d with hi-res",report.bounds_match,report.bounds_differ,report.bounds_absent,report.hi_res)
    for count,code in report.packages_failed {if count>0 {fmt.wprintfln(w,"  packages not opened %v: %d",code,count)}}
    for count,layout in report.layouts {if count>0 {fmt.wprintfln(w,"  format %v: %d",layout,count)}}
    for reason,count in report.failures {fmt.wprintfln(w,"  failure %s: %d",reason,count)}
}

@(private="file")
Skeletal_Report :: struct {
    meshes,decoded,failed,skeletons,triangles,vertices,over_influences,bounds_match,bounds_expanded,bounds_differ,facing_away,left_out,cloth,morphs,morph_deltas,sockets,morph_curves,curves_unknown:int,
    layouts:[unreal_mesh.Skeletal_Layout]int,
    compared,compared_differ:int, // meshes with both layouts, and those whose LOD model and description disagree
    failures:map[string]int,
    packages_failed:[unreal.Error_Code]int,
}

// Each SkeletalMesh: LOD 0 decoded, its bounds against ImportedBounds, the
// vertices with more influences than a Mirai vertex holds (8), and the
// triangles whose front, in Unreal's order, faces away from their normals.
// A mesh with a mesh description is also decoded from its LOD model, and the
// two are compared. The influences a description keeps are those the project
// of the mounts (or of the package's own) allows.
@(private="file")
inspect_skeletal :: proc(w:io.Writer,path:string,p:^unreal.Package,decoder:^kraken.Decoder,mounts:[]unreal.Source_Mount,report:^Skeletal_Report) {
    for _,index in p.exports {
        name:=unreal.name_plain(p,p.exports[index].object_name)
        if unreal_mesh.skeleton_is(p,index) {
            skeleton,error:=unreal_mesh.skeleton_read(p,index)
            defer unreal_mesh.skeleton_destroy(&skeleton)
            if error.code!=.None {inspect_failed(w,&report.failed,&report.failures,path,name,error);continue}
            report.skeletons+=1
            report.sockets+=len(skeleton.sockets)
            report.morph_curves+=len(skeleton.morph_curves)
            if !skeleton.curves_known {report.curves_unknown+=1}
            fmt.wprintfln(w,"ok %s %s Skeleton bones=%d sockets=%d morph curves=%d%s",path,name,len(skeleton.bones),len(skeleton.sockets),len(skeleton.morph_curves),skeleton.curves_known?"":" (curve metadata not read)")
            continue
        }
        if !unreal_mesh.skeletal_mesh_is(p,index) {continue}
        report.meshes+=1
        source,error:=unreal_mesh.skeletal_read(p,index)
        defer unreal_mesh.skeletal_mesh_destroy(&source)
        if error.code!=.None {inspect_failed(w,&report.failed,&report.failures,path,name,error);continue}
        project:=unreal_mesh.SKIN_PROJECT_DEFAULTS
        if len(mounts)>0 {project=unreal_mesh.skin_project_read(mounts)} else if mount,found:=unreal.source_mount_guess(path,p,context.temp_allocator);found {
            project=unreal_mesh.skin_project_read({mount})
        }
        decoded,decode_error:=unreal_mesh.skeletal_decode(p,&source,decoder,project=project)
        defer unreal_mesh.skinned_mesh_destroy(&decoded)
        if decode_error.code!=.None {inspect_failed(w,&report.failed,&report.failures,path,name,decode_error);continue}
        report.decoded+=1
        report.layouts[source.layout]+=1
        triangles:=len(decoded.triangle_section)
        report.triangles+=triangles
        report.vertices+=len(decoded.positions)
        report.left_out+=decoded.left_out
        report.cloth+=decoded.cloth
        report.morphs+=len(decoded.morphs)
        report.sockets+=len(source.sockets)
        moved:=0
        for target in decoded.morphs {for delta in target.positions {if delta!={} {moved+=1}}}
        report.morph_deltas+=moved
        over:=0
        most:=0
        for row in 0..<len(decoded.positions) {
            count:=int(decoded.skin_first[row+1]-decoded.skin_first[row])
            most=max(most,count)
            if count>8 {over+=1}
        }
        report.over_influences+=over
        away:=0
        for triangle in 0..<triangles {
            c:=decoded.corner_vertex[triangle*3:][:3]
            a,b,d:=decoded.positions[c[0]],decoded.positions[c[1]],decoded.positions[c[2]]
            front:=linalg.cross(d-a,b-a)
            normal:=decoded.corner_normal[triangle*3]+decoded.corner_normal[triangle*3+1]+decoded.corner_normal[triangle*3+2]
            if linalg.dot(front,normal)<0 {away+=1}
        }
        report.facing_away+=away
        difference,size:=bounds_gap(decoded.bounds_min,decoded.bounds_max,source.bounds_min,source.bounds_max)
        // The FBX importer of UE4 kept ImportedBounds twice the size of the
        // mesh about its middle, with the bottom tucked up to a tenth.
        expanded:f32
        for i in 0..<3 {
            middle:=(decoded.bounds_min[i]+decoded.bounds_max[i])/2
            low:=decoded.bounds_min[i]+(decoded.bounds_min[i]-middle)*(i==2?0.1:1)
            high:=decoded.bounds_max[i]+(decoded.bounds_max[i]-middle)
            expanded=max(expanded,abs(low-source.bounds_min[i]),abs(high-source.bounds_max[i]))
        }
        bounds:="bounds ok"
        if difference<=bounds_tolerance(size) {report.bounds_match+=1} else if expanded<=bounds_tolerance(size) {
            report.bounds_expanded+=1
            bounds="bounds ok (enlarged by the FBX importer of UE4)"
        } else {
            report.bounds_differ+=1
            bounds=fmt.tprintf("bounds differ by %.3f cm: %v..%v against %v..%v",difference,decoded.bounds_min,decoded.bounds_max,source.bounds_min,source.bounds_max)
        }
        compared:=""
        if source.layout==.Mesh_Description {
            source.layout=.Lod_Model
            lod,lod_error:=unreal_mesh.skeletal_decode(p,&source,decoder)
            defer unreal_mesh.skinned_mesh_destroy(&lod)
            source.layout=.Mesh_Description
            report.compared+=1
            if lod_error.code!=.None {
                compared=fmt.tprintf(" LOD model %v: %s",lod_error.code,lod_error.field)
                report.compared_differ+=1
            } else {
                gap,_:=bounds_gap(lod.bounds_min,lod.bounds_max,decoded.bounds_min,decoded.bounds_max)
                lod_most:=0
                for row in 0..<len(lod.positions) {lod_most=max(lod_most,int(lod.skin_first[row+1]-lod.skin_first[row]))}
                if len(lod.triangle_section)!=triangles || gap>bounds_tolerance(size) || lod_most!=most {report.compared_differ+=1}
                compared=fmt.tprintf(" LOD model triangles=%d vertices=%d influences<=%d bounds at %.3f cm",len(lod.triangle_section),len(lod.positions),lod_most,gap)
            }
        }
        fmt.wprintfln(w,"ok %s %s %v bones=%d skeleton=%s triangles=%d vertices=%d sections=%d not drawn=%d cloth=%d uv=%d colors=%v influences<=%d over 8=%d facing away=%d morphs=%d (%d vertices moved) sockets=%d %s%s",
            path,name,source.layout,len(source.bones),source.skeleton,triangles,len(decoded.positions),len(decoded.sections),decoded.left_out,decoded.cloth,decoded.uv_count,len(decoded.corner_color)>0,most,over,away,len(decoded.morphs),moved,len(source.sockets),bounds,compared)
    }
}

@(private="file")
skeletal_report_print :: proc(w:io.Writer,report:^Skeletal_Report,packages:int) {
    fmt.wprintfln(w,"%d packages, %d skeletal meshes, %d read, %d failed, %d skeletons; %d triangles, %d vertices",packages,report.meshes,report.decoded,report.failed,report.skeletons,report.triangles,report.vertices)
    fmt.wprintfln(w,"  bounds: %d match, %d enlarged by the FBX importer of UE4, %d differ; %d vertices with more than 8 influences, %d triangles facing away from their normals",report.bounds_match,report.bounds_expanded,report.bounds_differ,report.over_influences,report.facing_away)
    fmt.wprintfln(w,"  %d sections not drawn, %d of cloth, %d morph targets (%d vertices moved), %d sockets",report.left_out,report.cloth,report.morphs,report.morph_deltas,report.sockets)
    fmt.wprintfln(w,"  %d curves that move morph targets in the skeletons; %d skeletons whose curve metadata was not read",report.morph_curves,report.curves_unknown)
    if report.compared>0 {fmt.wprintfln(w,"  description against LOD model: %d compared, %d differ",report.compared,report.compared_differ)}
    for count,code in report.packages_failed {if count>0 {fmt.wprintfln(w,"  packages not opened %v: %d",code,count)}}
    for count,layout in report.layouts {if count>0 {fmt.wprintfln(w,"  format %v: %d",layout,count)}}
    for reason,count in report.failures {fmt.wprintfln(w,"  failure %s: %d",reason,count)}
}

@(private="file")
Anim_Report :: struct {
    sequences,read,failed,keys,tracks,curves,curve_keys,markers,notifies,weighted,root_motion,root_lock:int,
    layouts:[unreal_mesh.Animation_Layout]int,
    additive:[unreal_mesh.Additive_Type][unreal_mesh.Additive_Base]int,
    others:map[string]int, // animation assets of other classes, by class
    failures:map[string]int,
    packages_failed:[unreal.Error_Code]int,
}

// Each AnimSequence: its layout, keys, frame rate, tracks, curves and sync
// markers, how it is additive and its root motion. Other animation assets
// (montages, blend spaces, composites) are counted by class.
@(private="file")
inspect_anims :: proc(w:io.Writer,path:string,p:^unreal.Package,report:^Anim_Report) {
    for _,index in p.exports {
        name:=unreal.name_plain(p,p.exports[index].object_name)
        if !unreal_mesh.animation_is(p,index) {
            class,ok:=unreal.reference_name(p,p.exports[index].class)
            if !ok || p.exports[index].outer!=0 {continue}
            text:=unreal.name_plain(p,class)
            switch text {
            case "AnimMontage","AnimComposite","BlendSpace","BlendSpace1D","AimOffsetBlendSpace","AimOffsetBlendSpace1D","PoseAsset","AnimBlueprint","AnimStreamable":
                if text in report.others {report.others[text]+=1} else {report.others[strings.clone(text)]=1}
            }
            continue
        }
        report.sequences+=1
        a,error:=unreal_mesh.animation_read(p,index)
        defer unreal_mesh.animation_destroy(&a)
        if error.code!=.None {
            inspect_failed(w,&report.failed,&report.failures,path,name,error)
            continue
        }
        report.read+=1
        report.layouts[a.layout]+=1
        report.keys+=a.keys
        report.tracks+=len(a.tracks)
        report.curves+=len(a.curves)
        for curve in a.curves {report.curve_keys+=len(curve.keys)}
        report.markers+=len(a.markers)
        report.notifies+=a.notifies
        report.weighted+=a.weighted
        report.additive[a.additive][a.additive_base]+=1
        if a.root_motion {report.root_motion+=1}
        if a.force_root_lock {report.root_lock+=1}
        fmt.wprintfln(w,"ok %s %s %v keys=%d fps=%.3f duration=%.3f tracks=%d curves=%d markers=%d notifies=%d additive=%v/%v root_motion=%v root_lock=%v/%v skeleton=%s",
            path,name,a.layout,a.keys,1/a.interval,f64(a.keys-1)*a.interval,len(a.tracks),len(a.curves),len(a.markers),a.notifies,a.additive,a.additive_base,a.root_motion,a.force_root_lock,a.root_lock,a.skeleton)
    }
}

@(private="file")
anim_report_print :: proc(w:io.Writer,report:^Anim_Report,packages:int) {
    fmt.wprintfln(w,"%d packages, %d AnimSequence, %d read, %d failed; %d keys, %d tracks, %d curves (%d keys), %d markers, %d notifies not read",packages,report.sequences,report.read,report.failed,report.keys,report.tracks,report.curves,report.curve_keys,report.markers,report.notifies)
    fmt.wprintfln(w,"  root motion: %d; root lock: %d; segments with weighted tangents evaluated without weight: %d",report.root_motion,report.root_lock,report.weighted)
    for row,kind in report.additive {for count,base in row {if count>0 {fmt.wprintfln(w,"  additive %v/%v: %d",kind,base,count)}}}
    for count,code in report.packages_failed {if count>0 {fmt.wprintfln(w,"  packages not opened %v: %d",code,count)}}
    for count,layout in report.layouts {if count>0 {fmt.wprintfln(w,"  format %v: %d",layout,count)}}
    for class,count in report.others {fmt.wprintfln(w,"  %s (not read): %d",class,count)}
    for reason,count in report.failures {fmt.wprintfln(w,"  failure %s: %d",reason,count)}
}
