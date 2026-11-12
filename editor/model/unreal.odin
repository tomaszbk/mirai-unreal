package uasset

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "mirai:asset"
import importer "mirai:cook/import"
import "project:plugins/unreal/editor/kraken"
import material "project:plugins/unreal/editor/material"
import material_write "project:plugins/unreal/editor/material/write"
import ulevel "project:plugins/unreal/editor/level"
import umesh "project:plugins/unreal/editor/mesh"
import utexture "project:plugins/unreal/editor/texture"
import upackage "project:plugins/unreal/editor/package"
import "mirai:std/base"
import mm "mirai:std/math"

// Uncooked Unreal packages (.uasset), read without Unreal: each StaticMesh of
// the package is a mesh with a node, from the source model that
// unreal/editor/mesh reads; each SkeletalMesh a skinned mesh with its reference
// skeleton and a node; each AnimSequence a clip bound to the bones of its
// skeleton; a package of a Skeleton alone, that skeleton; a package of
// textures alone, each one a texture (unreal/editor/texture). Unreal's space
// is centimeters, +Z up, +X forward and +Y right, left-handed, with v from
// the top of the image: the engine's +X is Unreal's +Y, its +Y Unreal's +Z
// and its -Z, the front of everything, Unreal's +X.

FORMAT :: importer.Format{
    name="Unreal",
    extensions={0=".uasset"},
    version=1,
    space=SPACE,
    sniff=sniff,
    read=read,
    folder=model_folder,
}

SPACE :: ulevel.SPACE

// What the Unreal format is given as Format.data.
Options :: struct {
    // The Content folder of an Unreal installation, mounted at /Engine. "":
    // UNREAL_ENGINE (an installation or its Engine folder), else the newest
    // installation in the place the Epic launcher puts them.
    engine_content:string,
    hi_res:bool, // the Nanite hi-res source model of a mesh that has one, instead of LOD 0
    // The packages the translations of materials read and the textures their
    // images are made from, shared by the imports of the meshes of a level:
    // each package is read and each texture decoded once. nil: their own for
    // each import, with the mounts of the package.
    library:^material.Library,
    images:^material_write.Builder, // over library
    // Held while library and images are used, when imports that share them
    // read in parallel; nil when nothing else uses them at once.
    lock:^sync.Mutex,
    // The textures systems of the project write as they run, which programs
    // read instead (material.Options.reads).
    reads:[]material.Texture_Read,
    // What writes the runtime virtual textures the materials read: the
    // landscapes of the level (material.Options.writers).
    writers:[]material.Virtual_Texture_Writer,
}

// FORMAT with options other than its defaults; options outlives the imports.
format :: proc(options:^Options) -> importer.Format {
    with:=FORMAT
    with.data=options
    return with
}

// The tag every package starts with, little-endian.
sniff :: proc(head:[]u8) -> importer.Sniff {
    if len(head)>=4 && head[0]==0xc1 && head[1]==0x83 && head[2]==0x2a && head[3]==0x9e {return .Content}
    return .No
}

// Takes the library and the images of c for the thread of its reader.
@(private)
library_lock :: proc(c:^Context) {
    if c.lock!=nil {
        importer.zone(c.r.options,"unreal.lock")
        sync.mutex_lock(c.lock)
    }
    c.library.worker=c.r.options.worker
}

@(private)
library_unlock :: proc(c:^Context) {
    if c.lock!=nil {sync.mutex_unlock(c.lock)}
}

// What reading one package keeps.
Context :: struct {
    r:^importer.Reader,
    p:^upackage.Package,
    materials:map[string]Slot_Material, // by the object path of the material
    library:^material.Library,          // the packages the translations read
    images:^material_write.Builder,     // the images of the materials, shared by them
    lock:^sync.Mutex,                   // of library and images, when they are shared
    decoder:^kraken.Decoder,            // of this read, made when first needed (decoder_need)
    decoder_made:^bool,
    reads:[]material.Texture_Read,      // of the options
    writers:[]material.Virtual_Texture_Writer, // of the options
}

// What the material of a slot is in the model.
Slot_Material :: struct {
    row:int,                 // of the model's materials, -1 for none
    vertex_colors:bool, // the material reads the vertex colors: its base color multiplied by them, or its program
}

@(private)
read :: proc(r:^importer.Reader,bytes:[]u8) -> bool {
    options:Options
    if r.data!=nil {options=(^Options)(r.data)^}
    open_zone:=importer.zone_begin(r.options,"unreal.package")
    p,open_error:=upackage.package_open(bytes,context.temp_allocator,umesh.LIMITS)
    base.profile_end(open_zone)
    if open_error.code!=.None {return failure(r,open_error,"the package")}
    defer upackage.package_destroy(&p)
    own:material.Library
    c:=Context{r=r,p=&p,library=options.library,reads=options.reads,writers=options.writers}
    if c.library!=nil {
        c.lock=options.lock
    } else {
        material.library_init(&own,mounts_find(r.path,options,&p,plugins=false),context.temp_allocator,plugins_pending=true)
        c.library=&own
    }
    defer if c.library==&own {material.library_destroy(&own)}
    defer if c.library==&own {files_note(r,&own)}
    c.materials.allocator=context.temp_allocator
    own_images:material_write.Builder
    c.images=options.images
    if c.images==nil || c.library!=options.library {
        material_write.builder_init(&own_images,c.library,context.temp_allocator)
        c.images=&own_images
    }
    defer if c.images==&own_images {material_write.builder_destroy(&own_images)}
    decoder:kraken.Decoder
    decoder_made:=false
    defer if decoder_made {kraken.decoder_destroy(&decoder)}
    c.decoder,c.decoder_made=&decoder,&decoder_made
    r.stem=upackage.asset_name(r.stem)
    found:=0
    skeletons:=make([dynamic]int,context.temp_allocator)
    textures:=make([dynamic]int,context.temp_allocator)
    for _,index in p.exports {
        if umesh.skeleton_is(&p,index) {append(&skeletons,index)}
        if _,is_texture:=utexture.texture_kind(&p,index);is_texture {append(&textures,index)}
        if umesh.animation_is(&p,index) {
            found+=1
            name:=upackage.asset_name(upackage.name_text(&p,p.exports[index].object_name,context.temp_allocator))
            a,error:=umesh.animation_read(&p,index,context.temp_allocator)
            if error.code!=.None {return failure(r,error,name)}
            defer umesh.animation_destroy(&a)
            if !animation_add(&c,name,&a) {return false}
            continue
        }
        if umesh.pose_asset_is(&p,index) {
            found+=1
            name:=upackage.asset_name(upackage.name_text(&p,p.exports[index].object_name,context.temp_allocator))
            a,error:=umesh.pose_asset_read(&p,index,context.temp_allocator)
            if error.code!=.None {return failure(r,error,name)}
            defer umesh.animation_destroy(&a)
            if !animation_add(&c,name,&a) {return false}
            continue
        }
        skeletal:=umesh.skeletal_mesh_is(&p,index)
        if !skeletal && !umesh.static_mesh_is(&p,index) {continue}
        found+=1
        name:=upackage.asset_name(upackage.name_text(&p,p.exports[index].object_name,context.temp_allocator))
        if skeletal {
            source,error:=umesh.skeletal_read(&p,index,context.temp_allocator)
            if error.code!=.None {return failure(r,error,name)}
            if source.layout==.Mesh_Description && !decoder_need(r,&decoder,&decoder_made) {return false}
            library_lock(&c)
            project:=umesh.skin_project_read(c.library.mounts)
            library_unlock(&c)
            geometry,decode_error:=umesh.skeletal_decode(&p,&source,&decoder,context.temp_allocator,context.temp_allocator,project)
            if decode_error.code!=.None {return failure(r,decode_error,name)}
            if !skeletal_add(&c,name,&source,&geometry) {return false}
            continue
        }
        model:umesh.Source_Model=.Hi_Res if options.hi_res else .Lod0
        read_zone:=importer.zone_begin(r.options,"unreal.mesh.read")
        source,error:=umesh.mesh_read(&p,index,model,context.temp_allocator)
        if error.code==.Unsupported_Value && model==.Hi_Res && !source.hi_res {source,error=umesh.mesh_read(&p,index,.Lod0,context.temp_allocator)}
        base.profile_end(read_zone)
        if error.code!=.None {return failure(r,error,name)}
        if source.payload.encoding==.Compressed_Buffer && !decoder_need(r,&decoder,&decoder_made) {return false}
        decode_zone:=importer.zone_begin(r.options,"unreal.mesh.decode")
        geometry,decode_error:=umesh.mesh_decode(&p,&source,&decoder,context.temp_allocator,context.temp_allocator,r.options.worker)
        base.profile_end(decode_zone)
        if decode_error.code!=.None {return failure(r,decode_error,name)}
        if !mesh_add(&c,name,&source,&geometry) {return false}
    }
    if found==0 {
        // A package of a Skeleton alone: what its animations are made for.
        for index in skeletons {
            name:=upackage.asset_name(upackage.name_text(&p,p.exports[index].object_name,context.temp_allocator))
            skeleton,error:=umesh.skeleton_read(&p,index,context.temp_allocator)
            if error.code!=.None {return failure(r,error,name)}
            if _,ok:=skeleton_append(r,name,skeleton.bones,skeleton.sockets);!ok {return false}
        }
        if len(skeletons)>0 {return true}
        // A package of textures alone: each one a texture.
        for index in textures {
            name:=upackage.asset_name(upackage.name_text(&p,p.exports[index].object_name,context.temp_allocator))
            if !texture_add(&c,index,name) {return false}
        }
        if len(textures)>0 {return true}
        return importer.fail(r,.Unsupported,"%s has no StaticMesh, SkeletalMesh, Skeleton, AnimSequence, PoseAsset or texture: the Unreal format reads the meshes, skeletons, animations, pose assets and textures of a package",r.file_name)
    }
    return true
}

// One texture of the package as an image of the model, with its layers and
// the precision of its source; what the .tex does not keep is a warning.
@(private="file")
texture_add :: proc(c:^Context,index:int,name:string) -> bool {
    r:=c.r
    source,error:=utexture.texture_read(c.p,index,context.temp_allocator)
    if error.code!=.None {return failure(r,error,name)}
    defer utexture.texture_destroy(&source)
    if source.payload.encoding==.Compressed_Buffer && !decoder_need(r,c.decoder,c.decoder_made) {return false}
    decode_zone:=importer.zone_begin(r.options,"unreal.texture")
    decoded,decode_error:=utexture.texture_decode(c.p,&source,c.decoder,context.temp_allocator,r.options.worker)
    base.profile_end(decode_zone)
    if decode_error.code!=.None {return failure(r,decode_error,name)}
    defer utexture.decoded_destroy(&decoded)
    input,input_error:=utexture.texture_build_input(&source,&decoded,context.temp_allocator)
    if input_error.code!=.None {return failure(r,input_error,name)}
    defer utexture.build_input_destroy(&input)
    if input.approximations!={} {importer.warn(r,"%s: texture %s: %v",r.file_name,name,input.approximations)}
    importer.image_pixels(r,fmt.tprintf("%s#%s",r.path,name),name,input.source,input.options.srgb,input.options.normal_map,input.options.keep_precision)
    return true
}

// The decoder the textures of the materials of a read are decoded with,
// without holding the library they share; nil, when there is no memory for
// it, decodes them with the decoder of the library.
@(private)
texture_decoder :: proc(c:^Context) -> ^kraken.Decoder {
    if !c.decoder_made^ {
        made,error:=kraken.decoder_make(context.temp_allocator)
        if error!=nil {return nil}
        c.decoder^=made
        c.decoder_made^=true
    }
    return c.decoder
}

// The Oodle decoder of a read, made the first time a payload needs it.
@(private)
decoder_need :: proc(r:^importer.Reader,decoder:^kraken.Decoder,made:^bool) -> bool {
    if made^ {return true}
    made_decoder,allocation_error:=kraken.decoder_make(context.temp_allocator)
    if allocation_error!=nil {return importer.fail(r,.Limit,"%s: no memory for the Oodle decoder",r.file_name)}
    decoder^=made_decoder
    made^=true
    return true
}

@(private)
failure :: proc(r:^importer.Reader,error:upackage.Error,what:string) -> bool {
    code:importer.Error_Code=.Malformed
    #partial switch error.code {
    case .Unsupported_Version,.Unversioned,.Cooked,.Compressed,.Unsupported_Extension,.Unsupported_Value:code=.Unsupported
    case .Limit,.Out_Of_Memory:code=.Limit
    }
    return importer.fail(r,code,"%s: %s: %v at 0x%x: %s",r.file_name,what,error.code,error.offset,error.field)
}

@(private="file",rodata)
REVERSED:=[3]int{0,2,1}

// One mesh and its node.
@(private="file")
mesh_add :: proc(c:^Context,name:string,source:^umesh.Static_Mesh,geometry:^umesh.Mesh) -> bool {
    r:=c.r
    r.degenerate+=geometry.degenerate
    built:=geometry_build(c,name,source.materials,geometry,nil) or_return
    body,error:=umesh.body_read(c.p,source.body_setup,context.temp_allocator)
    if error.code!=.None {return failure(r,error,name)}
    if body.left_out>0 {importer.warn(r,"%s: %s has %d tapered capsules or level sets in its collision, which Mirai has no shape for; they are left out",r.file_name,name,body.left_out)}
    built.collision=body_collision(body,r.out)
    row:=importer.mesh_add(r,built)
    append(&r.nodes,importer.Imported_Node{name=r.meshes[row].name,parent=-1,transform=mm.TRANSFORM_IDENTITY,mesh=row,visible=true})
    return true
}

// The simple collision of a mesh as colliders of the source, in Unreal's
// space: a capsule of Unreal lies along its Z, one of Mirai along its Y. A
// mesh that uses its triangles as simple collision gives none: its triangles
// are what a collider of the mesh takes.
body_collision :: proc(body:umesh.Body,allocator:=context.allocator) -> (collision:importer.Mesh_Collision) {
    if len(body.shapes)==0 || body.trace==.Complex_As_Simple {return}
    colliders:=make([dynamic]asset.Collider,allocator)
    points:=make([dynamic][3]f32,allocator)
    UP_TO_Z :: quaternion128(quaternion(w=0.70710678,x=0.70710678,y=0,z=0))
    for shape in body.shapes {
        collider:=asset.Collider{center=shape.center,rotation=shape.rotation,size=shape.size}
        switch shape.kind {
        case .Box: collider.kind=.Box
        case .Sphere: collider.kind=.Sphere
        case .Capsule: collider.kind,collider.rotation=.Capsule,shape.rotation*UP_TO_Z
        case .Convex:
            collider.kind,collider.rotation,collider.size=.Hull,1,{}
            collider.first_point,collider.point_count=u32(len(points)),u32(len(shape.points))
            append(&points,..shape.points)
        }
        append(&colliders,collider)
    }
    return {colliders[:],points[:],nil}
}

// The mesh of what unreal/editor/mesh decoded, in the slots of the materials of
// Unreal, skinned when skin has the influences of each row of its positions,
// with the morph targets that move the morph vertex of each corner.
// Unreal's triangles run the other way of its axes: the builder takes their
// corners reversed, and its mirror turns them back.
@(private)
geometry_build :: proc(c:^Context,name:string,materials:[]umesh.Material_Slot,geometry:^umesh.Mesh,skin:[]asset.Skin_Vertex,morphs:[]umesh.Morph_Target=nil,corner_morph:[]u32=nil) -> (built:importer.Imported_Mesh,ok:bool) {
    r:=c.r
    if geometry.uv_count>2 {importer.warn(r,"%s: %s has %d UV channels; the mesh keeps the first two",r.file_name,name,geometry.uv_count)}
    builder:importer.Mesh_Builder
    importer.builder_init(&builder,r,skin!=nil)
    builder.has_uv1=geometry.uv_count>1
    slots:=make([]int,len(geometry.sections),context.temp_allocator)
    tints:=make([]bool,len(geometry.sections),context.temp_allocator)
    for section,i in geometry.sections {
        // The slot is the material slot of Unreal: what a component overrides by index.
        id,label,material:=u32(0),"",-1
        if section.material>=0 {
            slot:=materials[section.material]
            id,label=u32(section.material+1),slot.name
            made:=slot_material(c,slot)
            material,tints[i]=made.row,made.vertex_colors
        }
        slots[i]=importer.builder_slot(&builder,id,label,material) or_return
    }
    corners_zone:=importer.zone_begin(r.options,"import.mesh.corners")
    for section,triangle in geometry.triangle_section {
        corners:[3]importer.Corner
        weights:[3]asset.Skin_Vertex
        for k in 0..<3 {
            corner:=triangle*3+REVERSED[k]
            if skin!=nil {weights[k]=skin[geometry.corner_vertex[corner]]}
            out:=&corners[k]
            out.position=geometry.positions[geometry.corner_vertex[corner]]
            out.normal=geometry.corner_normal[corner]
            if geometry.uv_count>0 {out.uv,out.has_uv=geometry.corner_uvs[0][corner],true}
            if geometry.uv_count>1 {out.uv1,out.has_uv1=geometry.corner_uvs[1][corner],true}
            out.color=importer.WHITE
            if tints[section] && len(geometry.corner_color)>0 {
                rgba:=geometry.corner_color[corner]
                out.color=u32(rgba[0])|u32(rgba[1])<<8|u32(rgba[2])<<16|u32(rgba[3])<<24
            }
            if tangent:=geometry.corner_tangent[corner];tangent.xyz!={} {out.tangent,out.has_tangent=tangent,true}
            if len(morphs)>0 {out.morph=corner_morph[corner]+1}
        }
        importer.builder_triangle(&builder,slots[section],corners,weights)
    }
    base.profile_end(corners_zone)
    if importer.failed(r) {return}
    finish_zone:=importer.zone_begin(r.options,"import.mesh.finish")
    built=importer.builder_finish(&builder,name)
    base.profile_end(finish_zone)
    for target in morphs {
        if !importer.builder_morph(&builder,&built,{name=target.name,positions=target.positions,normals=target.normals}) {return}
    }
    return built,!importer.failed(r)
}

// The one place where the material of a slot is made: the translation of its
// Unreal material (unreal/editor/material), read through the mounts, with its
// images. A material that cannot be read or translated is one with the
// defaults of .mat and its name, and a warning; one that needs a Surface
// program keeps its standard values when the import has no project to write
// the program to. The same material serves every slot that names it.
slot_material :: proc(c:^Context,slot:umesh.Material_Slot) -> Slot_Material {
    if slot.path=="" {return {row=-1}}
    if made,found:=c.materials[slot.path];found {return made}
    r:=c.r
    library_lock(c)
    defer library_unlock(c)
    made:Slot_Material
    defer c.materials[strings.clone(slot.path,context.temp_allocator)]=made
    name:=slot.path
    if dot:=strings.last_index_byte(name,'.');dot>=0 {name=name[dot+1:]}
    name=upackage.asset_name(name)
    find_zone:=importer.zone_begin(r.options,"material.find")
    object,found:=material.object_find(c.library,slot.path)
    base.profile_end(find_zone)
    if !found {
        if engine_missing(c.library,slot.path) {
            importer.warn(r,"%s: the material %s is of Unreal's engine, which is not mounted (no Unreal installation): the grid of Mirai stands for it",r.file_name,slot.path)
            made.row=grid_add(c,slot.path)
            return made
        }
        importer.warn(r,"%s: the material %s could not be read: no mount holds its package; it takes the defaults",r.file_name,slot.path)
        made.row=defaults_add(r,name)
        return made
    }
    translate_zone:=importer.zone_begin(r.options,"material.translate")
    t,error:=material.translate(c.library,object,{reads=c.reads,writers=c.writers},context.temp_allocator)
    base.profile_end(translate_zone)
    if error.code!=.None {
        if missing:=engine_missing_named(c.library,error.message);missing!="" {
            importer.warn(r,"%s: the material %s reads %s of Unreal's engine, which is not mounted (no Unreal installation): the grid of Mirai stands for it",r.file_name,slot.path,missing)
            made.row=grid_add(c,slot.path)
            return made
        }
        importer.warn(r,"%s: the material %s could not be translated (%s); it takes the defaults",r.file_name,slot.path,error.message)
        made.row=defaults_add(r,name)
        return made
    }
    defer material.translated_destroy(&t)
    if missing:=engine_missing_read(c.library,&t);missing!="" {
        importer.warn(r,"%s: the material %s reads %s of Unreal's engine, which is not mounted (no Unreal installation): the grid of Mirai stands for it",r.file_name,slot.path,missing)
        made.row=grid_add(c,slot.path)
        return made
    }
    if !material.translated_is_standard(&t) {
        shaders:string
        if r.options.root!="" {shaders,_=filepath.join({r.options.root,"shaders"},context.temp_allocator)}
        written:=false
        if shaders!="" {
            program,program_error:=material_write.program_write(&t,shaders)
            written=program_error.code==.None
            if program!="" {append(&r.programs,importer.own(r,program))}

        }
        if !written {
            importer.warn(r,"%s: the material %s needs the Surface program %s, which is written into the shaders of a project; it keeps its standard values",r.file_name,t.name,t.program.name)
            t.program={}
            t.info.program={}
        }
    }
    images_zone:=importer.zone_begin(r.options,"material.images")
    made.row=material_write.reader_material(r,c.images,&t,len(r.materials),texture_decoder(c))
    base.profile_end(images_zone)

    made.vertex_colors=t.vertex_colors==.Multiply_Base_Color || t.vertex_colors==.Program && t.program.name!=""
    return made
}

@(private="file")
defaults_add :: proc(r:^importer.Reader,name:string) -> int {
    images:[asset.Material_Map_Kind]int
    for &image in images {image=-1}
    return importer.material_add(r,name,len(r.materials),asset.MATERIAL_DEFAULTS,images)
}

// The packages of /Game the read opened besides its own, which its assets
// are made from: the inputs of its import.
@(private="file")
files_note :: proc(r:^importer.Reader,lib:^material.Library) {
    for _,opened in lib.packages {
        if opened.error.code!=.None || !strings.has_prefix(opened.name,"/Game/") {continue}
        for extension in ([2]string{".uasset",".umap"}) {
            file,error:=upackage.source_package_path(opened.name,lib.mounts,context.temp_allocator,extension)
            if error.code!=.None || !os.exists(file) {continue}
            own,_:=filepath.clean(r.path,context.temp_allocator)
            other,_:=filepath.clean(file,context.temp_allocator)
            if !strings.equal_fold(own,other) {append(&r.files,file)}
            break
        }
    }
}

// The folder of models/ the import of a package goes to: its name without
// the prefix of its type, as the assets it holds.
model_folder :: proc(file:string) -> string {
    return upackage.asset_name(filepath.stem(filepath.base(file)))
}

// /Game is the Content folder of the project of the package: of the folders
// named Content above it, the first next to a .uproject or, without one, the
// nearest. Only the folders that hold a Content folder are listed. A package
// under no Content folder (a pack copied without its project) mounts what
// upackage.source_mount_guess finds from the name it keeps of itself, or else
// the one under which a package it imports is a file (source_mount_near). /Engine
// is Options.engine_content or the one upackage.engine_content_find gives, and
// with plugins each plugin of the engine mounts its content (engine_plugin_mounts).
mounts_find :: proc(path:string,options:Options,p:^upackage.Package=nil,allocator:=context.temp_allocator,plugins:=true) -> []upackage.Source_Mount {
    mounts:=make([dynamic]upackage.Source_Mount,allocator)
    absolute,_:=filepath.abs(path,context.temp_allocator)
    content:string
    for folder:=filepath.dir(absolute);;folder=filepath.dir(folder) {
        parent:=filepath.dir(folder)
        if strings.equal_fold(filepath.base(folder),"Content") {
            if content=="" {content=folder}
            if project_file(parent) {content=folder;break}
        }
        if parent==folder || parent=="" || parent=="." {break}
    }
    if content!="" {content=strings.clone(content,allocator)}
    if content!="" {
        append(&mounts,upackage.Source_Mount{"/Game",content})
    } else if p!=nil {
        if guessed,ok:=upackage.source_mount_guess(path,p,allocator);ok {
            append(&mounts,guessed)
        } else {
            // A package renamed apart from its file: the packages it imports find the mount.
            for item in p.imports {
                name:=upackage.name_text(p,item.object_name,context.temp_allocator)
                if item.outer!=0 || !strings.has_prefix(name,"/Game/") {continue}
                if near,found:=upackage.source_mount_near(path,name,allocator);found {append(&mounts,near);break}
            }
        }
    }
    engine:=options.engine_content
    if engine=="" {engine=upackage.engine_content_find(allocator)}
    if engine!="" {
        append(&mounts,upackage.Source_Mount{"/Engine",engine})
        if plugins {append(&mounts,..upackage.engine_plugin_mounts(engine,allocator))}
    }
    return mounts[:]
}

@(private="file")
project_file :: proc(folder:string) -> bool {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return false}
    for entry in entries {
        if entry.type!=.Directory && strings.equal_fold(filepath.ext(entry.name),".uproject") {return true}
    }
    return false
}

// The grid of the engine standing for the material at path, with the images it needs.
@(private="file")
grid_add :: proc(c:^Context,path:string) -> int {
    t:=engine_grid(path)
    return material_write.reader_material(c.r,c.images,&t,len(c.r.materials),texture_decoder(c))
}
