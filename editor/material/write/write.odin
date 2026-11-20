package write

import "base:runtime"
import "core:fmt"
import "core:hash"
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
    // What make makes its texels of: an Unreal texture (texture.texture_made)
    // or the recipe of a bake (bake_made).
    data:[]u8,
    make:importer.Image_Make,
    made:textures.Source, // of a bake made already: one that scales its emission
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

// An Unreal texture, read once for every material that uses it: what its
// texture is made from, and its texels once something reads them.

@(private)
Source_Texture :: struct {
    ok:bool,
    pending:bool, // a user decodes it with the lock of the builder let go: the others wait for it
    note:string,  // what is said of it to each user: why it could not be read, or what it lost
    usage:texture.Usage,
    keep_precision:bool,
    data:[]u8,                 // what texture.texture_made makes its texels of
    decoded:bool,              // its texels were made, or could not be
    input:texture.Build_Input, // as a .tex is built from, once decoded; width 0 when it could not be
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

// The texture at path, read once: its properties and what its texture is
// made from, which is not decoded (source_decoded).
@(private)
source_texture :: proc(b:^Builder,path:string) -> ^Source_Texture {
    if found,ok:=b.sources[path];ok {
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
    read,error:=texture.texture_read(&object.pkg.p,object.export,context.temp_allocator)
    if error.code==.None {source.data,error=texture.texture_pack(&object.pkg.p,&read,b.allocator)}
    if error.code!=.None {
        texture_note(b,source,fmt.tprintf("texture %s: %v %s",path,error.code,error.field))
        return source
    }
    if approximations:=texture.texture_approximations(&read);approximations!={} {texture_note(b,source,fmt.tprintf("texture %s: %v",path,approximations))}
    source.ok=true
    source.usage=read.usage
    source.keep_precision=read.keep_precision
    return source
}

// The texels of the texture at path, decoded once; false when they cannot be
// (a note says why). decoder is the caller's own: with it, a builder with a
// lock decodes without holding it; nil decodes with the decoder of the
// library, holding everything.
@(private)
source_decoded :: proc(b:^Builder,path:string,source:^Source_Texture,decoder:^kraken.Decoder) -> bool {
    if !source.ok {return false}
    if source.pending {
        worker:=b.lib.worker
        jobs.worker_zone(worker,"unreal.texture.wait")
        b.outside+=1
        for source.pending {sync.cond_wait(&b.decoded,b.lock)}
        b.outside-=1
        sync.cond_broadcast(&b.decoded)
        b.lib.worker=worker
    }
    if source.decoded {return source.input.source.width>0}
    worker:=b.lib.worker
    jobs.worker_zone(worker,"unreal.texture")
    decoder:=decoder
    apart:=b.lock!=nil && decoder!=nil && !b.settling
    // Under the floor, users decode one after the other, holding the lock: what decoding takes
    // (the payload, its pixels and those of the image, reckoned as four times the payload) adds up once.
    if apart && b.floor>0 {
        total,available,known:=base.memory_stats()
        apart=!known || f64(available-4*i64(len(source.data)))>=f64(total)*b.floor
    }
    if decoder==nil {
        decoder_ok:bool
        decoder,decoder_ok=material.library_decoder(b.lib)
        if !decoder_ok {return false}
    }
    // What the builder holds of the texture does not change while the lock is let go.
    own:=runtime.heap_allocator()
    if apart {
        source.pending=true
        b.outside+=1
        sync.mutex_unlock(b.lock)
    }
    made,_,error:=texture.made_decode(source.data,decoder,own)
    if apart {
        sync.mutex_lock(b.lock)
        b.outside-=1
        b.lib.worker=worker
        source.pending=false
        sync.cond_broadcast(&b.decoded)
    }
    source.decoded=true
    if error.code!=.None {
        texture_note(b,source,fmt.tprintf("texture %s: %v %s",path,error.code,error.field))
        return false
    }
    defer textures.source_destroy(&made)
    source.input={source=made,options={srgb=source.usage==.Color,normal_map=source.usage==.Normal,keep_precision=source.keep_precision}}
    source.input.source.texels=slice.clone(made.texels,b.allocator)
    source.input.source.allocator=b.allocator
    return true
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
source_pixels :: proc(b:^Builder,path:string,decoder:^kraken.Decoder) -> ^material.Pixels {
    source:=source_texture(b,path)
    if !source_decoded(b,path,source,decoder) || source.input.source.cube || source.input.source.layers>1 {return nil}
    if source.pixels_ready {return &source.pixels}
    source.pixels=pixels_of(&source.input.source,source.usage,b.allocator)
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
texture_image :: proc(b:^Builder,path,name:string) -> string {
    source:=source_texture(b,path)
    if !source.ok {return ""}
    key:=fmt.aprintf("texture:%s:%v",path,source.usage,allocator=b.allocator)
    return image_add(b,{key=key,name=strings.clone(unreal.asset_name(name),b.allocator),data=source.data,make=texture.texture_made,
        srgb=source.usage==.Color,normal_map=source.usage==.Normal,keep_precision=source.keep_precision})
}

@(private)
MAP_NAMES :: [asset.Material_Map_Kind]string{
    .Base_Color="BaseColor",.Metallic_Roughness="MetallicRoughness",.Normal="Normal",.Emission="Emission",.Occlusion="Occlusion",
    .Specular="Specular",.Specular_Color="SpecularColor",.Coat="Coat",.Coat_Roughness="CoatRoughness",.Coat_Normal="CoatNormal",
    .Fuzz_Color="FuzzColor",.Fuzz_Roughness="FuzzRoughness",.Anisotropy="Anisotropy",
    .Diffuse_Transmission="DiffuseTransmission",.Diffuse_Transmission_Color="DiffuseTransmissionColor",
    .Mask="Mask",
}

// The material of a translation, with the images it needs added to b; the
// textures it decodes, with decoder (source_texture).
material_build :: proc(b:^Builder,t:^material.Translated_Material,decoder:^kraken.Decoder=nil) -> (m:Built_Material) {
    m.name=strings.clone(unreal.asset_name(t.name),b.allocator)
    m.info=t.info
    g:=&t.graph
    names:=MAP_NAMES
    for image,kind in t.images {
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
        case .Specular,.Mask:relevant={false,false,false,true}
        case:for c in 0..<4 {relevant[c]=image.channels[c]!=material.NONE}
        }
        wanted:=bit_set[texture.Usage]{.Data}
        if color {wanted={.Color}}
        if kind==.Normal {wanted={.Normal}}
        // A mask is the alpha of any texture as it is but a normal map.
        if kind==.Mask {wanted={.Color,.Data}}
        scale:[4]f32
        m.images[kind],m.image_names[kind],scale=image_build(b,t,image,names[kind],relevant,encodings,wanted,color,kind==.Normal,kind==.Emission,decoder)
        // The scale of an emission is the factor of the material.
        if kind==.Emission {m.info.emission*=scale.xyz}
    }
    // What a terrain gives each piece the material holds no value of.
    held:=0
    for p in t.program.parameters {if !p.piece {held+=1}}
    parameters:=make([]asset.Material_Parameter,held,b.allocator)
    images:=make([]string,held,b.allocator)
    i:=0
    for &p in t.program.parameters {
        if p.piece {continue}
        row:=&parameters[i]
        asset.text_set(row.name[:],p.name)
        row.kind,row.components=p.kind,p.components
        for c in 0..<4 {row.value[c]=f64(p.value[c])}
        if p.kind==.Texture {
            ref:=g.textures[p.texture]
            images[i]=texture_image(b,ref.path,ref.name)
        }
        i+=1
    }
    m.parameters,m.parameter_images=parameters,images
    return
}

// The key in b of an image of a translation, and its name as the material
// names it: a texture read as it is, of one of usages, keeps its pixels;
// anything else is baked from the graph, named after the material and label.
// With fit it is baked now and its scale is what it was divided by (image_bake).
@(private)
image_build :: proc(b:^Builder,t:^material.Translated_Material,image:material.Map_Image,label:string,relevant:[4]bool,encodings:[4]material.Channel_Encoding,usages:bit_set[texture.Usage],color,normal_map,fit:bool,decoder:^kraken.Decoder) -> (key,name:string,scale:[4]f32) {
    g:=&t.graph
    scale={1,1,1,1}
    if row,direct:=material.image_direct(g,image,relevant);direct {
        ref:=g.textures[row]
        source:=source_texture(b,ref.path)
        if source.ok && source.usage in usages {
            key=texture_image(b,ref.path,ref.name)
            return key,b.images[b.keys[key]].name,scale
        }
    }
    // What the bake reads: the graph, the values of its parameters
    // (instances of one material share the graph), the image's channels and
    // the textures.
    what:=base.hash64(mem.slice_to_bytes(g.nodes[:]))
    for &p in g.parameters {what=base.hash_combine(what,base.hash64(mem.ptr_to_bytes(&p.value)))}
    image:=image
    what=base.hash_combine(what,base.hash64(mem.ptr_to_bytes(&image)))
    for ref in g.textures {what=base.hash_combine(what,base.name_hash(ref.path))}
    baked:=fmt.tprintf("%s:%016x",label,what)
    name=fmt.aprintf("%s_%s",unreal.asset_name(t.name),label,allocator=b.allocator)
    done,again:=b.bakes[baked]
    if !again {
        if fit {
            pixels:=make([]^material.Pixels,len(g.textures),context.temp_allocator)
            for &ref,i in g.textures {pixels[i]=source_pixels(b,ref.path,decoder)}
            data,width,height,fitted:=material.image_bake(g,image,encodings,pixels,true,b.allocator)
            done.scale=fitted
            done.key=fmt.aprintf("baked:%016x:%dx%d:%s",base.hash64(data),width,height,label,allocator=b.allocator)
            done.key=image_add(b,{key=done.key,name=name,made=textures.rgba8(data,width,height),srgb=color})
        } else {
            // Baked when its texture is built, and only when the texture cache does not keep it.
            recipe:=bake_pack(b,g,image,encodings,b.allocator)
            done.scale={1,1,1,1}
            done.key=fmt.aprintf("baked:%016x:%s",base.hash64(recipe),label,allocator=b.allocator)
            done.key=image_add(b,{key=done.key,name=name,data=recipe,make=bake_made,srgb=color,normal_map=normal_map})
        }
        b.bakes[strings.clone(baked,b.allocator)]=done
    }
    return done.key,name,done.scale
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
    row:int
    if image.data!=nil {
        row=importer.image_made(r,image.key,name!=""?name:image.name,image.data,image.make,image.srgb,image.normal_map,image.keep_precision)
    } else {
        row=importer.image_pixels(r,image.key,name!=""?name:image.name,image.made,image.srgb,image.normal_map,image.keep_precision)
    }
    if row>=0 && cutoff>=0 {r.images[row].alpha_cutoff=cutoff}
    return row
}

// The alpha cutoff a material gives the image of its map kind: that of a
// masked material to the image of its mask, or to its base color without
// one; -1 for none. A material decides it for the images of its own import,
// whatever other materials that share the builder gave the same image.
@(private)
material_cutoff :: proc(m:^Built_Material,kind:asset.Material_Map_Kind) -> f32 {
    if m.info.alpha_mode!=.Mask {return -1}
    masked:=m.images[.Mask]!="" ? asset.Material_Map_Kind.Mask : .Base_Color
    return m.info.alpha_cutoff if kind==masked else -1
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

// Binds a generated Surface from the build being written.
program_store :: proc(
    outputs:^importer.Outputs,source:string,info:^asset.Material_Info,
) -> importer.Error {
    address,error:=importer.output_program(outputs,source)
    if error.code!=.None {return error}
    base.text_set(info.program[:],asset.generated_program_id(address,context.temp_allocator))
    return {}
}

// The memory a builder holds in textures and images, in bytes.
builder_bytes :: proc(b:^Builder) -> int {
    total:=0
    for _,source in b.sources {total+=len(source.data)+len(source.input.source.texels)+len(source.pixels.texels)*size_of([4]f32)}
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

// Writes the sky of the Unreal texture at path as one .tex of the import of
// outputs, named prefix and the texture: the image of a Sky. A cube turns
// into one (texture.sky_of_cube), a plain texture is a latitude-longitude
// image already; the lower half of either goes toward below by its alpha
// (texture.sky_lower). One whose lower half is not as it is by default
// (black for a cube, as Unreal's sky light makes it; the texture's own for a
// plain one) is named apart. shared, lock and decoder as materials_write.
sky_write :: proc(lib:^material.Library,path:string,below:[4]f32,outputs:^importer.Outputs,prefix:string,options:importer.Import_Options={},allocator:=context.allocator,shared:^Builder=nil,lock:^sync.Mutex=nil,decoder:^kraken.Decoder=nil) -> (id:base.Asset_Id,error:importer.Error) {
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
        cube:=source_texture(b,path)
        decoded:=source_decoded(b,path,cube,decoder)
        notes:=make([]string,len(b.warnings),scratch)
        for w,i in b.warnings {notes[i]=strings.clone(w,scratch)}
        clear(&b.warnings)
        if !decoded {return {},importer.error_make(.Read,"texture %s could not be read: %s",path,strings.join(notes,"; ",context.temp_allocator))}
        source:=cube.input.source
        sky:textures.Source
        switch {
        case source.cube:
            sky_error:unreal.Error
            if sky,sky_error=texture.sky_of_cube(source,cube.usage==.Color,below,scratch);sky_error.code!=.None {
                return {},importer.error_make(.Unsupported,"texture %s: the faces of its cube are not square",path)
            }
        case source.layers<=1:
            sky=source
            clone_error:mem.Allocator_Error
            if sky.texels,clone_error=slice.clone(source.texels,scratch);clone_error!=nil {return {},importer.error_make(.Write,"texture %s: out of memory",path)}
            sky.allocator=scratch
            texture.sky_lower(sky,cube.usage==.Color,below)
        case:
            return {},importer.error_make(.Unsupported,"texture %s holds %d images: a sky is one",path,source.layers)
        }
        name:=strings.concatenate({unreal.asset_name(path[strings.last_index_any(path,"./")+1:]),"_Sky"},scratch)
        if source.cube ? below!={0,0,0,1} : below.a>0 {
            lower:=below
            name=fmt.aprintf("%s_%08x",name,hash.fnv32a(mem.ptr_to_bytes(&lower)),allocator=scratch)
        }
        image={name=name,made=sky,srgb=cube.usage==.Color,keep_precision=cube.keep_precision}
        model.warnings=notes
    }
    return image_output(outputs,&model,image,prefix,scratch)
}

// Writes the image of a sky made on import, a latitude-longitude image of
// linear values (sky, which it does not own), as one .tex of the import of
// outputs named prefix and name.
sky_made_write :: proc(name:string,sky:textures.Source,outputs:^importer.Outputs,prefix:string,allocator:=context.allocator) -> (id:base.Asset_Id,error:importer.Error) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&arena)
    scratch:=base.dynamic_arena_allocator(&arena)
    model:importer.Imported_Model
    return image_output(outputs,&model,{name=strings.clone(name,scratch),made=sky},prefix,scratch)
}

// The model of one image, written as the import of outputs: the id of its .tex.
@(private)
image_output :: proc(outputs:^importer.Outputs,model:^importer.Imported_Model,image:importer.Imported_Image,prefix:string,scratch:mem.Allocator) -> (id:base.Asset_Id,error:importer.Error) {
    model.images=slice.clone([]importer.Imported_Image{image},scratch)
    names_prefix(model,prefix,scratch)
    report:importer.Import_Report
    report,error=importer.output_model(outputs,model,scratch)
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
materials_write :: proc(
    lib:^material.Library,translated:[]material.Translated_Material,outputs:^importer.Outputs,
    prefix:string,options:importer.Import_Options={},allocator:=context.allocator,
    shared:^Builder=nil,lock:^sync.Mutex=nil,decoder:^kraken.Decoder=nil,
) -> (report:importer.Import_Report,error:importer.Error) {
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
    // The images of the builder stay where they are while the materials are written.
    if lock!=nil {sync.mutex_lock(lock)}
    lib.worker=options.worker
    held:=lock
    defer if held!=nil {sync.mutex_unlock(held)}
    builder_room(b)
    for &t,i in translated {
        built[i]=material_build(b,&t,decoder)
        if t.program.name!="" {
            if error:=program_store(outputs,t.program.source,&built[i].info);error.code!=.None {
                return {},error
            }
        }
    }
    // The images these materials name: a shared builder holds those of others too.
    images:=make([dynamic]importer.Imported_Image,scratch)
    rows_of:=make(map[string]int,scratch)
    row_of :: proc(b:^Builder,images:^[dynamic]importer.Imported_Image,rows_of:^map[string]int,key,name:string,cutoff:f32) -> int {
        if key=="" {return -1}
        row,seen:=rows_of[key]
        if !seen {
            image:=b.images[b.keys[key]]
            append(images,importer.Imported_Image{name=name!=""?name:image.name,data=image.data,make=image.make,made=image.made,srgb=image.srgb,normal_map=image.normal_map,keep_precision=image.keep_precision})
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
