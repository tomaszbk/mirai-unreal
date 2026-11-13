package write

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "mirai:asset"
import importer "mirai:cook/import"
import "project:plugins/unreal/editor/kraken"
import material "project:plugins/unreal/editor/material"
import fx "project:plugins/unreal/editor/material/fixture"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
temp_folder :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    path:=fmt.tprintf("%s/mirai-unreal-material-%d-%s",directory,os.get_pid(),name)
    os.remove_all(path)
    os.make_directory_all(path)
    return path
}

@(private="file")
expression :: proc(p:^fx.Package,material_ref:i32,class,name:string,w:^fx.Writer) -> i32 {
    return fx.export(p,fx.class(p,"/Script/Engine",strings.concatenate({"MaterialExpression",class},context.temp_allocator)),material_ref,name,fx.finish(w))
}

@(private="file")
sample :: proc(p:^fx.Package,material_ref:i32,texture,sampler:string,uv:i32=0) -> i32 {
    w:=fx.writer(p)
    fx.object_put(&w,"Texture",fx.external(p,strings.concatenate({"/Game/T/",texture},context.temp_allocator),"/Script/Engine","Texture2D",texture))
    if sampler!="" {fx.enum_put(&w,"SamplerType","EMaterialSamplerType",sampler)}
    if uv!=0 {fx.input_put(&w,"Coordinates","ExpressionInput",{expression=uv})}
    return expression(p,material_ref,"TextureSample",texture,&w)
}

@(private="file")
RGB :: [4]bool{true,true,true,false}

// M_Still: an albedo texture as it is, roughness in the red of a mask
// texture (baked to green) and a normal map. M_Flow: the albedo moving, a
// program, with a roughness parameter.
@(private="file")
materials_package :: proc() -> []u8 {
    p:=fx.package_make()
    still:=fx.export(&p,fx.class(&p,"/Script/Engine","Material"),0,"M_Still",nil)
    albedo:=sample(&p,still,"T_Albedo","")
    mask:=sample(&p,still,"T_Mask","SAMPLERTYPE_Masks")
    normal:=sample(&p,still,"T_Normal","SAMPLERTYPE_Normal")
    w:=fx.writer(&p)
    fx.input_put(&w,"BaseColor","ColorMaterialInput",{expression=albedo,mask=RGB})
    fx.input_put(&w,"Roughness","ScalarMaterialInput",{expression=mask,mask={true,false,false,false}})
    fx.input_put(&w,"Normal","VectorMaterialInput",{expression=normal,mask=RGB})
    p.exports[0].data=fx.finish(&w)
    flow:=fx.export(&p,fx.class(&p,"/Script/Engine","Material"),0,"M_Flow",nil)
    pan:=fx.writer(&p)
    fx.float_put(&pan,"SpeedX",0.1)
    panner:=expression(&p,flow,"Panner","Pan",&pan)
    moving:=sample(&p,flow,"T_Albedo","",panner)
    gloss:=fx.writer(&p)
    fx.name_property_put(&gloss,"ParameterName","Gloss")
    fx.float_put(&gloss,"DefaultValue",0.2)
    gloss_value:=expression(&p,flow,"ScalarParameter","Gloss",&gloss)
    m:=fx.writer(&p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=moving,mask=RGB})
    fx.input_put(&m,"Roughness","ScalarMaterialInput",{expression=gloss_value})
    p.exports[flow-1].data=fx.finish(&m)
    return fx.package_bytes(&p,"/Game/M/M_Materials")
}

@(private="file")
texture_bytes :: proc(name,settings:string,srgb:bool) -> []u8 {
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    for &v,i in pixels {v=u8(i*13)}
    return fx.texture_package(strings.concatenate({"/Game/T/",name},context.temp_allocator),name,pixels,4,4,settings,srgb)
}

@(private="file")
mat_read :: proc(t:^testing.T,types:^asset.Types,path:string,file:^asset.Asset) -> (view:asset.Material_View,ok:bool) {
    if !testing.expect_value(t,asset.asset_load(file,path,context.temp_allocator),asset.Error.None) {return}
    error:asset.Error
    view,error=asset.material_view(file,types)
    return view,testing.expect_value(t,error,asset.Error.None)
}

// materials_write as the one write of an import of source, in the project at root.
@(private="file")
import_materials :: proc(lib:^material.Library,translated:[]material.Translated_Material,source,shaders,root:string) -> (report:importer.Import_Report,error:importer.Error) {
    bytes,_:=os.read_entire_file(source,context.temp_allocator)
    o:importer.Outputs
    if error=importer.outputs_begin(&o,source,"",u64(len(bytes)),base.hash64(bytes),importer.import_version(1),{root=root});error.code!=.None {return}
    if _,error=materials_write(lib,translated,&o,"",shaders,allocator=context.temp_allocator);error.code!=.None {
        importer.outputs_end(&o,true)
        return
    }
    return importer.outputs_end(&o,false),{}
}

@(private="file")
written_find :: proc(report:^importer.Import_Report,name:string,kind:asset.Fourcc) -> ^importer.Written {
    for &w in report.assets {if w.name==name && w.kind==kind {return &w}}
    return nil
}

// Materials are written as .mat with their images as .tex; a texture read
// as it is is one .tex for every material that reads it, and a program goes
// to the shaders of the project with its parameters in the .mat. Importing
// again keeps a parameter value changed after the import.
@(test)
translated_materials_are_written_with_their_images_and_programs :: proc(t:^testing.T) {
    folder:=temp_folder("write")
    defer os.remove_all(folder)
    m:=project.manifest_default("Materials")
    project.manifest_write(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    os.make_directory_all(fmt.tprintf("%s/assets",folder))
    source,_:=filepath.join({folder,"assets","M_Materials.uasset"},context.temp_allocator)
    bytes:=materials_package()
    testing.expect_value(t,serial.file_write_atomic(source,bytes),serial.File_Error.None)
    lib:material.Library
    material.library_init(&lib,nil)
    defer material.library_destroy(&lib)
    material.library_add(&lib,"/Game/M/M_Materials",bytes)
    material.library_add(&lib,"/Game/T/T_Albedo",texture_bytes("T_Albedo","TC_Default",true))
    material.library_add(&lib,"/Game/T/T_Mask",texture_bytes("T_Mask","TC_Masks",false))
    material.library_add(&lib,"/Game/T/T_Normal",texture_bytes("T_Normal","TC_Normalmap",false))
    translated:[2]material.Translated_Material
    for name,i in ([2]string{"M_Still","M_Flow"}) {
        object,found:=material.object_find(&lib,strings.concatenate({"/Game/M/M_Materials.",name},context.temp_allocator))
        if !testing.expect(t,found) {return}
        error:material.Error
        translated[i],error=material.translate(&lib,object)
        if !testing.expect_value(t,error.code,material.Error_Code.None) {return}
    }
    defer for &tr in translated {material.translated_destroy(&tr)}
    testing.expect(t,material.translated_is_standard(&translated[0]) && !material.translated_is_standard(&translated[1]))
    shaders,_:=filepath.join({folder,"shaders"},context.temp_allocator)
    report,error:=import_materials(&lib,translated[:],source,shaders,folder)
    if !testing.expect_value(t,error.code,importer.Error_Code.None) {return}
    defer importer.report_destroy(&report)
    albedo:=written_find(&report,"Albedo",asset.KIND_TEXTURE)
    baked:=written_find(&report,"Still_MetallicRoughness",asset.KIND_TEXTURE)
    normal:=written_find(&report,"Normal",asset.KIND_TEXTURE)
    if !testing.expect(t,albedo!=nil && baked!=nil && normal!=nil) {return}
    textures:=0
    for w in report.assets {if w.kind==asset.KIND_TEXTURE {textures+=1}}
    testing.expect_value(t,textures,3)
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    still_file,flow_file:asset.Asset
    still,still_ok:=mat_read(t,&types,written_find(&report,"Still",asset.KIND_MATERIAL).path,&still_file)
    if !still_ok {return}
    maps:=asset.material_maps(&still.info.maps)
    testing.expect_value(t,maps[.Base_Color].texture,albedo.id)
    testing.expect_value(t,maps[.Metallic_Roughness].texture,baked.id)
    testing.expect_value(t,maps[.Normal].texture,normal.id)
    flow,flow_ok:=mat_read(t,&types,written_find(&report,"Flow",asset.KIND_MATERIAL).path,&flow_file)
    if !flow_ok {return}
    program:=base.text_get(flow.info.program[:])
    testing.expect_value(t,program,translated[1].program.name)
    program_path,_:=filepath.join({shaders,strings.concatenate({program,".slang"},context.temp_allocator)},context.temp_allocator)
    written_source,read_error:=serial.file_read(program_path,context.temp_allocator)
    testing.expect(t,read_error==.None && string(written_source)==translated[1].program.source)
    if !testing.expect_value(t,len(flow.parameters),2) {return}
    testing.expect(t,flow.parameters[0].kind==.Texture && flow.parameters[0].texture==albedo.id)
    testing.expect_value(t,flow.parameters[1].value[0],f64(f32(0.2)))
    testing.expect_value(t,len(flow.imported_parameters),2)

    // A person changes Gloss after the import; importing again keeps it.
    changed:=make([]asset.Material_Parameter,len(flow.parameters),context.temp_allocator)
    copy(changed,flow.parameters)
    changed[1].value[0]=0.9
    flow_path:=written_find(&report,"Flow",asset.KIND_MATERIAL).path
    info:=flow.info^
    imported:=flow.imported^
    imported_parameters:=make([]asset.Material_Parameter,len(flow.imported_parameters),context.temp_allocator)
    copy(imported_parameters,flow.imported_parameters)
    desc:=asset.Material_Desc{id=flow_file.blob.header.id,owner=flow_file.blob.header.owner,info=info,imported=&imported,
        parameters=changed,imported_parameters=imported_parameters,source=flow.source}
    asset.asset_close(&flow_file)
    asset.asset_close(&still_file)
    testing.expect_value(t,asset.material_save(flow_path,&types,desc),asset.Error.None)
    again,again_error:=import_materials(&lib,translated[:],source,shaders,folder)
    if !testing.expect_value(t,again_error.code,importer.Error_Code.None) {return}
    defer importer.report_destroy(&again)
    reread,reread_ok:=mat_read(t,&types,flow_path,&flow_file)
    if !reread_ok {return}
    defer asset.asset_close(&flow_file)
    testing.expect_value(t,len(reread.parameters),2)
    testing.expect_value(t,reread.parameters[1].value[0],0.9)
    testing.expect_value(t,reread.imported_parameters[1].value[0],f64(f32(0.2)))
}

// A map baked from the graph is made when its texture is built, from its
// recipe: building the material decodes no texture, and the texels are those
// of baking it from the decoded textures.
@(test)
a_baked_map_is_made_from_its_recipe_with_the_texels_of_the_bake :: proc(t:^testing.T) {
    lib:material.Library
    material.library_init(&lib,nil)
    defer material.library_destroy(&lib)
    material.library_add(&lib,"/Game/M/M_Materials",materials_package())
    material.library_add(&lib,"/Game/T/T_Albedo",texture_bytes("T_Albedo","TC_Default",true))
    material.library_add(&lib,"/Game/T/T_Mask",texture_bytes("T_Mask","TC_Masks",false))
    material.library_add(&lib,"/Game/T/T_Normal",texture_bytes("T_Normal","TC_Normalmap",false))
    object,found:=material.object_find(&lib,"/Game/M/M_Materials.M_Still")
    if !testing.expect(t,found) {return}
    translated,error:=material.translate(&lib,object)
    if !testing.expect_value(t,error.code,material.Error_Code.None) {return}
    defer material.translated_destroy(&translated)
    b:Builder
    builder_init(&b,&lib)
    defer builder_destroy(&b)
    built:=material_build(&b,&translated)
    image:=b.images[b.keys[built.images[.Metallic_Roughness]]]
    if !testing.expect(t,image.make==bake_made && len(image.data)>0 && image.made.width==0,"the bake is a recipe") {return}
    for _,source in b.sources {testing.expect(t,!source.decoded,"no texture is decoded to build the material")}
    made,ok:=bake_made(image.data,context.temp_allocator)
    if !testing.expect(t,ok) {return}
    pixels:=make([]^material.Pixels,len(translated.graph.textures),context.temp_allocator)
    for &ref,i in translated.graph.textures {pixels[i]=source_pixels(&b,ref.path,nil)}
    texels,width,height,_:=material.image_bake(&translated.graph,translated.images[.Metallic_Roughness],{},pixels,false,context.temp_allocator)
    testing.expect(t,made.width==width && made.height==height && string(made.texels)==string(texels),"the texels of the bake")
    _,refused:=bake_made(image.data[:len(image.data)-1],context.temp_allocator)
    testing.expect(t,!refused,"a recipe cut short is no recipe")
}

// Users of a builder with a lock build their materials on threads of their
// own, decoding textures without holding it: each texture is decoded once,
// and the images are those of a builder of one user.
@(test)
a_builder_shared_by_threads_decodes_each_texture_once_and_gives_the_images_of_one_user :: proc(t:^testing.T) {
    lib:material.Library
    material.library_init(&lib,nil)
    defer material.library_destroy(&lib)
    material.library_add(&lib,"/Game/M/M_Materials",materials_package())
    material.library_add(&lib,"/Game/T/T_Albedo",texture_bytes("T_Albedo","TC_Default",true))
    material.library_add(&lib,"/Game/T/T_Mask",texture_bytes("T_Mask","TC_Masks",false))
    material.library_add(&lib,"/Game/T/T_Normal",texture_bytes("T_Normal","TC_Normalmap",false))
    translated:[2]material.Translated_Material
    for name,i in ([2]string{"M_Still","M_Flow"}) {
        object,found:=material.object_find(&lib,strings.concatenate({"/Game/M/M_Materials.",name},context.temp_allocator))
        if !testing.expect(t,found) {return}
        error:material.Error
        translated[i],error=material.translate(&lib,object)
        if !testing.expect_value(t,error.code,material.Error_Code.None) {return}
    }
    defer for &tr in translated {material.translated_destroy(&tr)}

    alone_arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&alone_arena)
    defer mem.dynamic_arena_destroy(&alone_arena)
    alone:Builder
    builder_init(&alone,&lib,mem.dynamic_arena_allocator(&alone_arena))
    expected:[2]Built_Material
    for &tr,i in translated {expected[i]=material_build(&alone,&tr)}

    shared_arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&shared_arena)
    defer mem.dynamic_arena_destroy(&shared_arena)
    lock:sync.Mutex
    shared:Builder
    builder_init(&shared,&lib,mem.dynamic_arena_allocator(&shared_arena),&lock)
    User :: struct {b:^Builder,lock:^sync.Mutex,t:^material.Translated_Material,built:Built_Material}
    users:[8]User
    threads:[8]^thread.Thread
    for &u,i in users {
        u={b=&shared,lock=&lock,t=&translated[i%2]}
        threads[i]=thread.create_and_start_with_poly_data(&u,proc(u:^User) {
            decoder,_:=kraken.decoder_make()
            defer kraken.decoder_destroy(&decoder)
            sync.mutex_lock(u.lock)
            u.built=material_build(u.b,u.t,&decoder)
            sync.mutex_unlock(u.lock)
        })
    }
    // What the builder holds may be let go while they run, once nobody is outside.
    sync.mutex_lock(&lock)
    builder_settle(&shared)
    testing.expect_value(t,shared.outside,0)
    sync.mutex_unlock(&lock)
    for th in threads {thread.join(th);thread.destroy(th)}
    testing.expect_value(t,len(shared.sources),len(alone.sources))
    testing.expect_value(t,shared.outside,0)
    for _,source in shared.sources {testing.expect(t,source.ok && !source.pending)}
    for u,i in users {
        want:=expected[i%2]
        for key,kind in want.images {
            testing.expectf(t,u.built.images[kind]==key && u.built.image_names[kind]==want.image_names[kind],"%v: %s %s",kind,u.built.images[kind],key)
            if key=="" {continue}
            a,b:=alone.images[alone.keys[key]],shared.images[shared.keys[key]]
            testing.expect(t,string(a.made.texels)==string(b.made.texels) && string(a.data)==string(b.data))
        }
    }
}

// A builder with a floor lets go of what it holds when the memory left is
// under it and nobody is outside; one without, never.
@(test)
a_builder_lets_go_of_its_images_under_its_floor_when_nobody_is_outside :: proc(t:^testing.T) {
    lib:material.Library
    material.library_init(&lib,nil)
    defer material.library_destroy(&lib)
    material.library_add(&lib,"/Game/M/M_Materials",materials_package())
    material.library_add(&lib,"/Game/T/T_Albedo",texture_bytes("T_Albedo","TC_Default",true))
    material.library_add(&lib,"/Game/T/T_Mask",texture_bytes("T_Mask","TC_Masks",false))
    material.library_add(&lib,"/Game/T/T_Normal",texture_bytes("T_Normal","TC_Normalmap",false))
    object,found:=material.object_find(&lib,"/Game/M/M_Materials.M_Still")
    if !testing.expect(t,found) {return}
    translated,error:=material.translate(&lib,object)
    if !testing.expect_value(t,error.code,material.Error_Code.None) {return}
    defer material.translated_destroy(&translated)
    for floor in ([2]f64{0,1}) {
        lock:sync.Mutex
        b:Builder
        builder_init(&b,&lib,context.allocator,&lock,floor)
        defer builder_destroy(&b)
        sync.mutex_lock(&lock)
        _=material_build(&b,&translated)
        if !testing.expect(t,len(b.sources)>0) {sync.mutex_unlock(&lock);return}
        b.outside=1
        builder_room(&b)
        testing.expect(t,len(b.sources)>0,"what users outside hold stays")
        b.outside=0
        builder_room(&b)
        testing.expectf(t,(len(b.sources)==0)==(floor==1),"floor %v",floor)
        sync.mutex_unlock(&lock)
    }
}
