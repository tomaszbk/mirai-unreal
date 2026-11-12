package write

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import "project:plugins/unreal/editor/kraken"
import material "project:plugins/unreal/editor/material"
import unreal "project:plugins/unreal/editor/package"
import texture "project:plugins/unreal/editor/texture"
import "mirai:std/base"
import "mirai:std/jobs"

import "mirai:std/serial"

// Turning translations into what the importer writes: the image of each map
// (an Unreal texture as it is, or baked from the graph), the values of the
// material and the parameters of its program. Images are named by what they
// hold, so materials that read the same texture the same way share it. Apart
// from unreal/editor/material so that reading and translating need no importer.

// An image a material needs: an Unreal texture with its layers and
// precision, or one baked in RGBA8 rows from the top.
Built_Image :: struct {
    key:string, // what it holds: equal keys, equal pixels
    name:string,
    made:textures.Source,
    srgb,normal_map,keep_precision:bool,
}

// A material as importer.Imported_Material holds it, its images by key.
Built_Material :: struct {
    name:string,
    info:asset.Material_Info,
    images:[asset.Material_Map_Kind]string, // "" none
    image_names:[asset.Material_Map_Kind]string, // of each image as this material names it: a baked one after the material, though another material baked the same pixels first
    parameters:[]asset.Material_Parameter,
    parameter_images:[]string, // by parameter; "" for one that is not a texture
}

// An image baked for a map of a material, and the scale its emission takes.
@(private)
Bake :: struct {key:string,scale:[4]f32}

// An Unreal texture, read once for every material that uses it.

@(private)
Source_Texture :: struct {
    ok:bool,
    pending:bool, // a user decodes it with the lock of the builder let go: the others wait for it
    note:string,  // what is said of it to each user: why it could not be read, or what it lost
    usage:texture.Usage,
    input:texture.Build_Input, // as a .tex is built from
    pixels:material.Pixels,    // as Unreal's sampler reads it
    pixels_ready:bool,
}

// What the images of a set of materials are made from. Everything it holds
// lives in an arena of its own over the allocator it is made with.
//
// A builder that imports read in parallel share has the lock its users
// hold while they use it and its library. A user that decodes a texture
// lets go of it meanwhile, with an Oodle decoder of its own and memory of
// its own, and takes it again to keep the pixels; a user that needs a
// texture another one decodes waits for it: each texture is decoded once,
// and the textures of different materials at once.
//
// With a floor, a user about to build materials lets go of everything the
// builder holds when the memory of the machine left is under it and nobody
// is outside (builder_room): the textures are decoded again when asked.
Builder :: struct {
    lib:^material.Library,
    images:[dynamic]Built_Image,
    keys:map[string]int,
    bakes:map[string]Bake, // by what a bake reads: its image, again for what reads the same
    sources:map[string]^Source_Texture,
    warnings:[dynamic]string,
    allocator:mem.Allocator, // of arena
    arena:mem.Dynamic_Arena,
    parent:mem.Allocator,
    floor:f64,             // the share of the memory of the machine its users leave free; 0 for none
    lock:^sync.Mutex,      // held by its users; nil for a builder of one user, which decodes holding nothing
    outside:int,           // users that let go of the lock inside the builder, decoding or waiting: nothing of it may be let go
    decoded:sync.Cond,     // a texture stopped being pending, or a user came back from outside
    settling:bool,         // builder_settle waits for those outside: textures are decoded holding the lock
}

// The builder must not move once made: its allocator points into it.
builder_init :: proc(b:^Builder,lib:^material.Library,allocator:=context.allocator,lock:^sync.Mutex=nil,floor:=0.0) {
    b^={lib=lib,parent=allocator,lock=lock,floor=floor}
    mem.dynamic_arena_init(&b.arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    b.allocator=base.dynamic_arena_allocator(&b.arena)
    b.images.allocator=b.allocator
    b.keys.allocator=b.allocator
    b.bakes.allocator=b.allocator
    b.sources.allocator=b.allocator
    b.warnings.allocator=b.allocator
}

builder_destroy :: proc(b:^Builder) {
    mem.dynamic_arena_destroy(&b.arena)
    b^={}
}

// Lets go of everything the builder holds. Nobody may be outside, nor hold
// anything of it.
builder_trim :: proc(b:^Builder) {
    lib,parent,lock,floor:=b.lib,b.parent,b.lock,b.floor
    builder_destroy(b)
    builder_init(b,lib,parent,lock,floor)
}

// Called holding the lock before building materials, holding nothing of the
// builder: under the floor, it lets go of what it holds, unless a user is
// outside.
builder_room :: proc(b:^Builder) {
    if b.floor<=0 || b.outside>0 || len(b.sources)==0 && len(b.images)==0 {return}
    total,available,known:=base.memory_stats()
    if !known || f64(available)>=f64(total)*b.floor {return}
    jobs.worker_zone(b.lib.worker,"unreal.images.trim")
    builder_trim(b)
}

@(private)
warn :: proc(b:^Builder,format:string,args:..any) {
    text:=fmt.aprintf(format,..args,allocator=b.allocator)
    for existing in b.warnings {if existing==text {return}}
    append(&b.warnings,text)
}

// Waits, holding the lock of the builder, until no user decodes or waits
// inside it; meanwhile its users decode holding the lock, so the wait ends
// after the decodes that run. Then what the builder holds may be let go.
builder_settle :: proc(b:^Builder) {
    if b.lock==nil {return}
    b.settling=true
    for b.outside>0 {sync.cond_wait(&b.decoded,b.lock)}
    b.settling=false
}

// The texture at path, decoded once. decoder is the caller's own: with it, a
// builder with a lock decodes without holding it; nil decodes with the
// decoder of the library, holding everything.
@(private)
source_texture :: proc(b:^Builder,path:string,decoder:^kraken.Decoder) -> ^Source_Texture {
    if found,ok:=b.sources[path];ok {
        if found.pending {
            worker:=b.lib.worker
            jobs.worker_zone(worker,"unreal.texture.wait")
            b.outside+=1
            for found.pending {sync.cond_wait(&b.decoded,b.lock)}
            b.outside-=1
            sync.cond_broadcast(&b.decoded)
            b.lib.worker=worker
        }
        if found.note!="" {warn(b,"%s",found.note)}
        return found
    }
    source:=new(Source_Texture,b.allocator)
    b.sources[strings.clone(path,b.allocator)]=source
    object,found:=material.object_find(b.lib,path)
    if !found {
        texture_note(b,source,fmt.tprintf("texture %s is not under the mounts",path))
        return source
    }
    worker:=b.lib.worker
    jobs.worker_zone(worker,"unreal.texture")
    read,error:=texture.texture_read(&object.pkg.p,object.export,b.allocator)
    if error.code!=.None {
        texture_note(b,source,fmt.tprintf("texture %s: %v %s",path,error.code,error.field))
        return source
    }
    decoder:=decoder
    apart:=b.lock!=nil && decoder!=nil && !b.settling
    // Under the floor, users decode one after the other, holding the lock: what decoding takes
    // (the payload, its pixels and those of the image, reckoned as four times the payload) adds up once.
    if apart && b.floor>0 {
        total,available,known:=base.memory_stats()
        apart=!known || f64(available-4*read.payload.raw_size)>=f64(total)*b.floor
    }
    if decoder==nil {
        decoder_ok:bool
        decoder,decoder_ok=material.library_decoder(b.lib)
        if !decoder_ok {return source}
    }
    // What the package and the read texture hold does not change while the
    // lock is let go: the library adds packages, it moves none.
    own:=runtime.heap_allocator()
    if apart {
        source.pending=true
        b.outside+=1
        sync.mutex_unlock(b.lock)
    }
    decoded,decode_error:=texture.texture_decode(&object.pkg.p,&read,decoder,own,worker)
    input:texture.Build_Input
    input_error:unreal.Error
    if decode_error.code==.None {
        input,input_error=texture.texture_build_input(&read,&decoded,own)
        texture.decoded_destroy(&decoded)
    }
    if apart {
        sync.mutex_lock(b.lock)
        b.outside-=1
        b.lib.worker=worker
        source.pending=false
        sync.cond_broadcast(&b.decoded)
    }
    defer texture.build_input_destroy(&input)
    if decode_error.code!=.None {
        texture_note(b,source,fmt.tprintf("texture %s: %v %s",path,decode_error.code,decode_error.field))
        return source
    }
    if input_error.code!=.None {
        texture_note(b,source,fmt.tprintf("texture %s: %v %s",path,input_error.code,input_error.field))
        return source
    }
    if input.approximations!={} {texture_note(b,source,fmt.tprintf("texture %s: %v",path,input.approximations))}
    source.ok=true
    source.usage=read.usage
    source.input=input
    source.input.source.texels=slice.clone(input.source.texels,b.allocator)
    source.input.source.allocator=b.allocator
    return source
}

// Says text of a texture now and to each user that asks for it later: the
// builder may be filled ahead of the materials that report it.
@(private)
texture_note :: proc(b:^Builder,source:^Source_Texture,text:string) {
    source.note=strings.clone(text,b.allocator)
    warn(b,"%s",text)
}

// The texels of a texture as Unreal reads them: color as linear values, a
// normal map unpacked to -1..1 with its Z rebuilt, data as it is. None of a
// cube or an array, which a map of uv does not read.
@(private)
source_pixels :: proc(b:^Builder,source:^Source_Texture) -> ^material.Pixels {
    if !source.ok || source.input.source.cube || source.input.source.layers>1 {return nil}
    if source.pixels_ready {return &source.pixels}
    from:=&source.input.source
    count:=from.width*from.height
    source.pixels={from.width,from.height,make([][4]f32,count,b.allocator)}
    transfer:=textures.transfer_make(source.input.options.srgb && !textures.source_hdr(from.format))
    for i in 0..<count {
        texel:=textures.texel_read(from.texels,from.format,i,&transfer)
        switch source.usage {
        case .Color:
        case .Normal:
            xy:=texel.xy*2-1
            texel={xy.x,xy.y,math.sqrt(max(1-xy.x*xy.x-xy.y*xy.y,0)),1}
        case .Data:
        }
        source.pixels.texels[i]=texel
    }
    source.pixels_ready=true
    return &source.pixels
}

@(private)
image_add :: proc(b:^Builder,image:Built_Image) -> string {
    if _,found:=b.keys[image.key];found {return image.key}
    append(&b.images,image)
    b.keys[image.key]=len(b.images)-1
    return image.key
}

// The image of an Unreal texture as it is, with the use Unreal gives it.
@(private)
texture_image :: proc(b:^Builder,path,name:string,decoder:^kraken.Decoder) -> string {
    source:=source_texture(b,path,decoder)
    if !source.ok {return ""}
    key:=fmt.aprintf("texture:%s:%v",path,source.usage,allocator=b.allocator)
    return image_add(b,{key=key,name=strings.clone(unreal.asset_name(name),b.allocator),made=source.input.source,
        srgb=source.usage==.Color,normal_map=source.usage==.Normal,keep_precision=source.input.options.keep_precision})
}

@(private)
MAP_NAMES :: [asset.Material_Map_Kind]string{
    .Base_Color="BaseColor",.Metallic_Roughness="MetallicRoughness",.Normal="Normal",.Emission="Emission",.Occlusion="Occlusion",
    .Specular="Specular",.Specular_Color="SpecularColor",.Coat="Coat",.Coat_Roughness="CoatRoughness",.Coat_Normal="CoatNormal",
    .Fuzz_Color="FuzzColor",.Fuzz_Roughness="FuzzRoughness",.Anisotropy="Anisotropy",
    .Diffuse_Transmission="DiffuseTransmission",.Diffuse_Transmission_Color="DiffuseTransmissionColor",
}

// The material of a translation, with the images it needs added to b; the
// textures it decodes, with decoder (source_texture).
material_build :: proc(b:^Builder,t:^material.Translated_Material,decoder:^kraken.Decoder=nil) -> (m:Built_Material) {
    m.name=strings.clone(unreal.asset_name(t.name),b.allocator)
    m.info=t.info
    g:=&t.graph
    names:=MAP_NAMES
    for &image,kind in t.images {
        if image==material.MAP_NONE {continue}
        relevant:[4]bool
        encodings:[4]material.Channel_Encoding
        color:=false
        #partial switch kind {
        case .Base_Color:
            relevant={true,true,true,t.info.alpha_mode!=.Opaque && image.channels[3]!=material.NONE}
            encodings={.SRGB,.SRGB,.SRGB,.Linear}
            color=true
        case .Emission:
            relevant={true,true,true,false}
            encodings={.SRGB,.SRGB,.SRGB,.Linear}
            color=true
        case .Normal:
            relevant={true,true,true,false}
            encodings={.Normal,.Normal,.Normal,.Linear}
        case .Occlusion:relevant={true,false,false,false}
        case .Specular:relevant={false,false,false,true}
        case:for c in 0..<4 {relevant[c]=image.channels[c]!=material.NONE}
        }
        key:string
        // A texture read as it is keeps its pixels.
        if row,direct:=material.image_direct(g,image,relevant);direct {
            ref:=g.textures[row]
            source:=source_texture(b,ref.path,decoder)
            wanted:=texture.Usage.Data
            if color {wanted=.Color}
            if kind==.Normal {wanted=.Normal}
            if source.ok && source.usage==wanted {key=texture_image(b,ref.path,ref.name,decoder)}
        }
        if key=="" {
            // What the bake reads: the graph, the values of its parameters
            // (instances of one material share the graph), the map's
            // channels and the textures.
            what:=base.hash64(mem.slice_to_bytes(g.nodes[:]))
            for &p in g.parameters {what=base.hash_combine(what,base.hash64(mem.ptr_to_bytes(&p.value)))}
            what=base.hash_combine(what,base.hash64(mem.ptr_to_bytes(&image)))
            for ref in g.textures {what=base.hash_combine(what,base.name_hash(ref.path))}
            baked:=fmt.tprintf("%v:%016x",kind,what)

            done,again:=b.bakes[baked]
            if !again {
                pixels:=make([]^material.Pixels,len(g.textures),context.temp_allocator)
                for &ref,i in g.textures {pixels[i]=source_pixels(b,source_texture(b,ref.path,decoder))}
                data,width,height,scale:=material.image_bake(g,image,encodings,pixels,kind==.Emission,b.allocator)
                done.scale=scale
                done.key=fmt.aprintf("baked:%016x:%dx%d:%v",base.hash64(data),width,height,kind,allocator=b.allocator)
                done.key=image_add(b,{key=done.key,name=fmt.aprintf("%s_%s",unreal.asset_name(t.name),names[kind],allocator=b.allocator),
                    made=textures.rgba8(data,width,height),srgb=color,normal_map=kind==.Normal})
                b.bakes[strings.clone(baked,b.allocator)]=done
            }
            if kind==.Emission {m.info.emission*=done.scale.xyz}
            key=done.key
            m.image_names[kind]=fmt.aprintf("%s_%s",unreal.asset_name(t.name),names[kind],allocator=b.allocator)
        } else {
            m.image_names[kind]=b.images[b.keys[key]].name
        }
        m.images[kind]=key
    }
    parameters:=make([]asset.Material_Parameter,len(t.program.parameters),b.allocator)
    images:=make([]string,len(t.program.parameters),b.allocator)
    for &p,i in t.program.parameters {
        row:=&parameters[i]
        asset.text_set(row.name[:],p.name)
        row.kind,row.components=p.kind,p.components
        for c in 0..<4 {row.value[c]=f64(p.value[c])}
        if p.kind==.Texture {
            ref:=g.textures[p.texture]
            images[i]=texture_image(b,ref.path,ref.name,decoder)
        }
    }
    m.parameters,m.parameter_images=parameters,images
    return
}

// Adds a translated material and its images to the model a format reads,
// and returns its row: what the slots of the meshes name.
reader_material :: proc(r:^importer.Reader,b:^Builder,t:^material.Translated_Material,index:int,decoder:^kraken.Decoder=nil) -> int {
    b.lib.worker=r.options.worker
    builder_room(b)
    m:=material_build(b,t,decoder)
    rows:[asset.Material_Map_Kind]int
    for key,kind in m.images {rows[kind]=reader_image(r,b,key,m.image_names[kind],material_cutoff(&m,kind))}
    row:=importer.material_add(r,m.name,index,m.info,rows)
    imported:=&r.materials[row]
    imported.parameters=importer.own_slice(r,m.parameters)
    images:=make([]int,len(m.parameter_images),r.out)
    for key,i in m.parameter_images {images[i]=reader_image(r,b,key,"",-1)}
    imported.parameter_images=images
    for w in b.warnings {importer.warn(r,"%s",w)}
    clear(&b.warnings)
    for n in t.notes {importer.warn(r,"material %s: %s",t.name,n)}
    return row
}

// The row of the image of key in the model of r; name "" is the image's own.
// cutoff, when not negative, is the alpha cutoff the image takes.
@(private)
reader_image :: proc(r:^importer.Reader,b:^Builder,key,name:string,cutoff:f32) -> int {
    if key=="" {return -1}
    image:=&b.images[b.keys[key]]
    row:=importer.image_pixels(r,image.key,name!=""?name:image.name,image.made,image.srgb,image.normal_map,image.keep_precision)
    if row>=0 && cutoff>=0 {r.images[row].alpha_cutoff=cutoff}
    return row
}

// The alpha cutoff a material gives the image of its map kind: that of a
// masked material to its base color; -1 for none. A material decides it for
// the images of its own import, whatever other materials that share the
// builder gave the same image.
@(private)
material_cutoff :: proc(m:^Built_Material,kind:asset.Material_Map_Kind) -> f32 {
    return m.info.alpha_cutoff if kind==.Base_Color && m.info.alpha_mode==.Mask else -1
}

// The program of a translation as a file of the shaders of a project,
// written when it is not there with the same text. "" when it has none.
program_write :: proc(t:^material.Translated_Material,shaders:string) -> (path:string,error:importer.Error) {
    if t.program.name=="" {return}
    if os.make_directory_all(shaders)!=nil && !os.is_dir(shaders) {return "",importer.error_make(.Write,"the folder %s could not be created",shaders)}
    path,_=filepath.join({shaders,strings.concatenate({t.program.name,".slang"},context.temp_allocator)},context.temp_allocator)
    if existing,read_error:=serial.file_read(path,context.temp_allocator);read_error==.None && string(existing)==t.program.source {return}
    if serial.file_write_atomic(path,transmute([]u8)t.program.source)!=.None {return "",importer.error_make(.Write,"%s could not be written",path)}
    return
}

// The memory a builder holds in textures and images, in bytes.
builder_bytes :: proc(b:^Builder) -> int {
    total:=0
    for _,source in b.sources {total+=len(source.input.source.texels)+len(source.pixels.texels)*size_of([4]f32)}
    for image in b.images {total+=len(image.made.texels)}
    return total
}

// Puts prefix before the name of every part of a model, and of the model:
// the parts of several packages written by one import stay apart, each
// under the folder of its package.
names_prefix :: proc(model:^importer.Imported_Model,prefix:string,allocator:mem.Allocator) {
    if prefix=="" {return}
    named :: proc(prefix,name:string,allocator:mem.Allocator) -> string {return strings.concatenate({prefix,name},allocator)}
    model.name=named(prefix,model.name,allocator)
    for &m in model.meshes {m.name=named(prefix,m.name,allocator)}
    for &m in model.materials {m.name=named(prefix,m.name,allocator)}
    for &m in model.images {m.name=named(prefix,m.name,allocator)}
    for &m in model.skeletons {m.name=named(prefix,m.name,allocator)}
    for &m in model.animations {m.name=named(prefix,m.name,allocator)}
}

// Writes the sky of the Unreal cube texture at path as one .tex of the
// import of outputs, named prefix and the texture: the image of a Sky
// (texture.sky_of_cube). shared, lock and decoder as materials_write.
sky_write :: proc(lib:^material.Library,path:string,outputs:^importer.Outputs,prefix:string,options:importer.Import_Options={},allocator:=context.allocator,shared:^Builder=nil,lock:^sync.Mutex=nil,decoder:^kraken.Decoder=nil) -> (id:base.Asset_Id,error:importer.Error) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&arena)
    scratch:=base.dynamic_arena_allocator(&arena)
    own:Builder
    b:=shared
    if b==nil {
        builder_init(&own,lib,scratch)
        b=&own
    }
    defer if b==&own {builder_destroy(&own)}
    model:importer.Imported_Model
    image:importer.Imported_Image
    {
        if lock!=nil {sync.mutex_lock(lock)}
        defer if lock!=nil {sync.mutex_unlock(lock)}
        lib.worker=options.worker
        builder_room(b)
        cube:=source_texture(b,path,decoder)
        notes:=make([]string,len(b.warnings),scratch)
        for w,i in b.warnings {notes[i]=strings.clone(w,scratch)}
        clear(&b.warnings)
        if !cube.ok {return {},importer.error_make(.Read,"texture %s could not be read: %s",path,strings.join(notes,"; ",context.temp_allocator))}
        sky,sky_error:=texture.sky_of_cube(cube.input.source,cube.usage==.Color,scratch)
        if sky_error.code!=.None {return {},importer.error_make(.Unsupported,"texture %s is not a cube: the sky is drawn from a cube",path)}
        name:=strings.concatenate({unreal.asset_name(path[strings.last_index_any(path,"./")+1:]),"_Sky"},scratch)
        image={name=name,made=sky,srgb=cube.usage==.Color,keep_precision=cube.input.options.keep_precision}
        model.warnings=notes
    }
    model.images=slice.clone([]importer.Imported_Image{image},scratch)
    names_prefix(&model,prefix,scratch)
    report:importer.Import_Report
    report,error=importer.output_model(outputs,&model,scratch)
    if error.code==.None && len(report.image_ids)>0 {id=report.image_ids[0]}
    return
}

// Writes translated materials as .mat files, with the .tex of their images,
// as parts of the import of outputs, named prefix and their names; their
// programs go to shaders, the shaders folder of the project. Importing the
// same source again updates the same files and keeps what was changed in
// them. shared, a builder over lib, keeps the textures it decodes for the
// next; lock, when given, is held while lib and the builder are used. The
// report gives the ids by row, in allocator.
materials_write :: proc(lib:^material.Library,translated:[]material.Translated_Material,outputs:^importer.Outputs,prefix,shaders:string,options:importer.Import_Options={},allocator:=context.allocator,shared:^Builder=nil,lock:^sync.Mutex=nil,decoder:^kraken.Decoder=nil) -> (report:importer.Import_Report,error:importer.Error) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&arena)
    scratch:=base.dynamic_arena_allocator(&arena)
    own:Builder
    b:=shared
    if b==nil {
        builder_init(&own,lib,scratch)
        b=&own
    }
    defer if b==&own {builder_destroy(&own)}

    model:importer.Imported_Model
    built:=make([]Built_Material,len(translated),scratch)
    programs:=make([dynamic]string,scratch)
    // The images of the builder stay where they are while the materials are written.
    if lock!=nil {sync.mutex_lock(lock)}
    lib.worker=options.worker
    held:=lock
    defer if held!=nil {sync.mutex_unlock(held)}
    builder_room(b)
    for &t,i in translated {
        built[i]=material_build(b,&t,decoder)
        program,program_error:=program_write(&t,shaders)
        if program_error.code!=.None {return {},program_error}
        if program!="" {append(&programs,strings.clone(program,scratch))}
    }
    // The images these materials name: a shared builder holds those of others too.
    images:=make([dynamic]importer.Imported_Image,scratch)
    rows_of:=make(map[string]int,scratch)
    row_of :: proc(b:^Builder,images:^[dynamic]importer.Imported_Image,rows_of:^map[string]int,key,name:string,cutoff:f32) -> int {
        if key=="" {return -1}
        row,seen:=rows_of[key]
        if !seen {
            image:=b.images[b.keys[key]]
            append(images,importer.Imported_Image{name=name!=""?name:image.name,made=image.made,srgb=image.srgb,normal_map=image.normal_map,keep_precision=image.keep_precision})
            row=len(images)-1
            rows_of[key]=row
        }
        if cutoff>=0 {images[row].alpha_cutoff=cutoff}
        return row
    }
    materials:=make([]importer.Imported_Material,len(built),scratch)
    for &m,i in built {
        rows:[asset.Material_Map_Kind]int
        for key,kind in m.images {rows[kind]=row_of(b,&images,&rows_of,key,m.image_names[kind],material_cutoff(&m,kind))}
        parameter_images:=make([]int,len(m.parameter_images),scratch)
        for key,j in m.parameter_images {parameter_images[j]=row_of(b,&images,&rows_of,key,"",-1)}
        materials[i]={name=m.name,info=m.info,images=rows,parameters=m.parameters,parameter_images=parameter_images}
    }
    model.images=images[:]
    model.materials=materials
    warnings:=make([dynamic]string,scratch)
    append(&warnings,..b.warnings[:])
    clear(&b.warnings)
    for &t in translated {
        for n in t.notes {append(&warnings,fmt.aprintf("material %s: %s",t.name,n,allocator=scratch))}
    }
    model.warnings=warnings[:]
    model.programs=programs[:]
    names_prefix(&model,prefix,scratch)
    if held==nil {return importer.output_model(outputs,&model,allocator)}
    // The images are written from the builder without its lock: what it holds stays.
    b.outside+=1
    sync.mutex_unlock(held)
    held=nil
    report,error=importer.output_model(outputs,&model,allocator)
    sync.mutex_lock(lock)
    b.outside-=1
    sync.cond_broadcast(&b.decoded)
    sync.mutex_unlock(lock)
    return
}
