package mesh

import "core:fmt"
import "core:mem"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// Static meshes of uncooked Unreal packages: the source model a mesh is built
// from, read as Unreal 5 loads it and turned into what its build draws.
// Unreal's names stay here; what leaves the package is triangles with their
// corners, sections and the material slots they use, in Unreal's space
// (centimeters, +Z up, +X forward, +Y right, left-handed, v from the top).
//
//   mesh_read     the properties of the export and where its payload is
//   mesh_decode   the payload: RawMesh of UE4 or MeshDescription

MAX_UVS :: 8

// What a package with a source model is opened with: the raw payload of a mesh
// of millions of triangles is larger than unreal.DEFAULT_LIMITS allows.
LIMITS :: unreal.Limits{
    source_bytes=2<<30,table_entries=unreal.DEFAULT_LIMITS.table_entries,text_bytes=unreal.DEFAULT_LIMITS.text_bytes,
    property_count=unreal.DEFAULT_LIMITS.property_count,outer_depth=unreal.DEFAULT_LIMITS.outer_depth,
}

Source_Model :: enum u8 {
    Lod0,   // the first of SourceModels: what Unreal draws without Nanite
    Hi_Res, // HiResSourceModel: what Nanite is built from, when the mesh has it
}

Layout :: enum u8 {Raw_Mesh,Mesh_Description}

// Where the source model is stored: an CompressedBuffer (UE5), or the raw
// bytes of UE4 bulk data, those optionally in zlib chunks.
Payload_Encoding :: enum u8 {Raw,Zlib,Compressed_Buffer}
Payload :: struct {span:unreal.Span,encoding:Payload_Encoding,raw_size:i64}

Material_Slot :: struct {
    name:string,          // MaterialSlotName
    imported_name:string, // ImportedMaterialSlotName: what the polygon groups name
    material:unreal.Object_Ref,
    path:string,          // object path of the material, "/Game/M/M_Rock.M_Rock"; "" without one
}

// The MeshBuildSettings of the source model that change what is drawn.
Build_Settings :: struct {
    scale:[3]f32,
    recompute_normals:bool,      // the normals of the source are replaced by smooth ones
    recompute_tangents:bool,     // MikkTSpace tangents instead of those of the source
    weighted_normals:bool,       // corners weigh by area and angle
    remove_degenerates:bool,     // corners closer than DEGENERATE_DISTANCE are one point
    legacy_tangent_scaling:bool, // tangents scale by the inverse of the build scale, as saves before the fix
}

Static_Mesh :: struct {
    object:unreal.Object_Ref,
    model:Source_Model,
    hi_res:bool,                   // the mesh has a hi-res source model
    layout:Layout,
    payload:Payload,
    build:Build_Settings,
    materials:[]Material_Slot,     // StaticMaterials
    // Of LOD 0, by section: the material of SectionInfoMap and of OriginalSectionInfoMap (the
    // one of the import), -1 where the map has none.
    section_materials,original_materials:[]i32,
    bounds_min,bounds_max:[3]f32,  // ExtendedBounds without the bounds extensions: what Unreal built
    has_bounds:bool,
    body_setup:unreal.Object_Ref,
    allocator:mem.Allocator,
}

static_mesh_destroy :: proc(mesh:^Static_Mesh) {
    if mesh==nil || mesh.allocator.procedure==nil {return}
    for slot in mesh.materials {
        delete(slot.name,mesh.allocator)
        delete(slot.imported_name,mesh.allocator)
        delete(slot.path,mesh.allocator)
    }
    delete(mesh.materials,mesh.allocator)
    delete(mesh.section_materials,mesh.allocator)
    delete(mesh.original_materials,mesh.allocator)
    mesh^={}
}

// Whether an export is a StaticMesh of /Script/Engine.
static_mesh_is :: proc(p:^unreal.Package,index:int) -> bool {return export_is(p,index,"StaticMesh")}

// Whether an export is of a class of /Script/Engine.
@(private)
export_is :: proc(p:^unreal.Package,index:int,class:string) -> bool {
    return p!=nil && index>=0 && export_of_class(p,unreal.Object_Ref(index+1),"/Script/Engine",class)
}

@(private) EDITOR_GUID :: [4]u32{0xE4B068ED,0xF49442E9,0xA231DA0B,0x2E46BB41}
@(private) ENTERPRISE_GUID :: [4]u32{0x9DFFBCD6,0x494F0158,0xE2211282,0x3C92A888}
@(private) RENDERING_GUID :: [4]u32{0x12F88B9F,0x88754AFC,0xA67CD90C,0x383ABD29}
@(private) ANIM_GUID :: [4]u32{0xAF43A65D,0x7FD34947,0x98733E8E,0xD9C1BB05}
@(private) MAIN_RELEASE_GUID :: [4]u32{0xD89B5E42,0x24BD4D46,0x8412ACA8,0xDF641779}
@(private) SKELETAL_GUID :: [4]u32{0xD78A4A00,0xE8584697,0xBAA819B5,0x487D46B4}
@(private) RECOMPUTE_TANGENT_GUID :: [4]u32{0x5579F886,0x933A4C1F,0x83BA087B,0x6361B92F}
@(private) OVERLAPPING_GUID :: [4]u32{0x612FBE52,0xDA53400B,0x910D4F91,0x9FB1857C}

// Versions where what this package reads changed; an absent custom version is -1.
@(private) UE4_NAV_COLLISION :: 216
@(private) UE4_THUMBNAIL_REMOVED :: 242
@(private) UE5_LARGE_WORLD_COORDINATES :: 1004
@(private) EDITOR_NEW_ATTRIBUTE_FORMAT :: 26
@(private) EDITOR_RAW_MESH_DEPRECATED :: 28
@(private) EDITOR_BULK_DATA_GUID :: 29
@(private) EDITOR_REMOVED_HOLES :: 30
@(private) EDITOR_TRIANGLES :: 35
@(private) RELEASE_NEW_SERIALIZATION :: 17
@(private) RELEASE_NEW_FORMAT :: 31
@(private) MAIN_NEW_FORMAT :: 4
@(private) MAIN_MESH_DESCRIPTION_OBJECT :: 25
@(private) MAIN_VIRTUALIZED :: 41
@(private) ENTERPRISE_GUID_IS_HASH :: 8
@(private) RENDERING_HI_RES_FIELDS_REMOVED :: 49
@(private) FORTNITE_TANGENT_TRANSFORM :: 127
@(private) FORTNITE_TRANSFORM_ATTRIBUTES :: 133
@(private) FORTNITE_NAME_TABLES :: 257

@(private)
Versions :: struct {
    ue4,ue5,editor,release,main,enterprise,rendering,fortnite:i32,
    anim,core,main_release,skeletal,recompute_tangent,overlapping:i32, // what skeletal meshes add
}

@(private)
versions_of :: proc(p:^unreal.Package) -> (v:Versions) {
    v.ue4,v.ue5=p.summary.version_ue4,p.summary.version_ue5
    v.editor,_=unreal.custom_version(p,EDITOR_GUID)
    v.release,_=unreal.custom_version(p,unreal.RELEASE_OBJECT_VERSION)
    v.main,_=unreal.custom_version(p,unreal.UE5_MAIN_STREAM_VERSION)
    v.enterprise,_=unreal.custom_version(p,ENTERPRISE_GUID)
    v.rendering,_=unreal.custom_version(p,RENDERING_GUID)
    v.fortnite,_=unreal.custom_version(p,unreal.FORTNITE_MAIN_VERSION)
    v.anim,_=unreal.custom_version(p,ANIM_GUID)
    v.core,_=unreal.custom_version(p,unreal.CORE_OBJECT_VERSION)
    v.main_release,_=unreal.custom_version(p,MAIN_RELEASE_GUID)
    v.skeletal,_=unreal.custom_version(p,SKELETAL_GUID)
    v.recompute_tangent,_=unreal.custom_version(p,RECOMPUTE_TANGENT_GUID)
    v.overlapping,_=unreal.custom_version(p,OVERLAPPING_GUID)
    return
}

// The properties of a StaticMesh export and where the payload of one of its
// source models is.
mesh_read :: proc(p:^unreal.Package,index:int,model:=Source_Model.Lod0,allocator:=context.allocator) -> (Static_Mesh,unreal.Error) {
    // Built in locals: results are copied out before deferred cleanup runs.
    mesh:Static_Mesh
    error:unreal.Error
    if !static_mesh_is(p,index) {return {},{.Invalid_Reference,0,"export is not a StaticMesh"}}
    mesh.allocator=allocator
    mesh.model=model
    mesh.object=unreal.Object_Ref(index+1)
    v:=versions_of(p)
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,allocator)
    if error.code!=.None {return {},error}
    defer unreal.properties_destroy(&properties)
    defer if error.code!=.None {static_mesh_destroy(&mesh)}
    e:=&error

    models:unreal.Struct_Array
    source_models:=unreal.property_find(p,&properties,"SourceModels")
    if source_models==nil {error={.Unsupported_Value,p.exports[index].data.offset,"static mesh keeps no SourceModels; it was cooked"};return {},error}
    view:unreal.Array_View
    view,error=unreal.property_array(p,source_models)
    if error.code!=.None {return {},error}
    models,error=unreal.array_tagged_structs(p,view,true,allocator)
    if error.code!=.None {return {},error}
    defer unreal.struct_array_destroy(&models)
    if len(models.items)==0 {error={.Unsupported_Value,source_models.data.offset,"static mesh has no source model"};return {},error}

    hi_res_struct:unreal.Property_List
    if property:=unreal.property_find(p,&properties,"HiResSourceModel");property!=nil {
        hi_res_struct,error=unreal.property_tagged_struct(p,property,true,allocator)
        if error.code!=.None {return {},error}
    }
    defer unreal.properties_destroy(&hi_res_struct)
    hi_res_bulk:=object_of(p,&hi_res_struct,"StaticMeshDescriptionBulkData",e)
    if error.code!=.None {return {},error}
    if hi_res_bulk>0 {
        hi_res_payload:Payload
        hi_res_payload,error=description_object_payload(p,v,hi_res_bulk,"StaticMeshDescriptionBulkData")
        if error.code!=.None {return {},error}
        mesh.hi_res=hi_res_payload.raw_size>0
        if model==.Hi_Res {mesh.payload=hi_res_payload}
    }
    chosen:=&models.items[0]
    if model==.Hi_Res {
        if !mesh.hi_res {error={.Unsupported_Value,source_models.data.offset,"static mesh has no hi-res source model; read LOD 0"};return {},error}
        chosen=&hi_res_struct
        mesh.layout=.Mesh_Description
    }
    error=build_settings_read(p,v,chosen,&mesh.build)
    if error.code!=.None {return {},error}

    tail:unreal.Span
    tail,error=unreal.object_native_payload(p,properties.trailing)
    if error.code!=.None {return {},error}
    mesh.body_setup,error=native_head(p,v,tail,len(models.items),model==.Lod0?&mesh:nil)
    if error.code!=.None {return {},error}
    if model==.Lod0 && v.editor>=EDITOR_RAW_MESH_DEPRECATED && v.main>=MAIN_MESH_DESCRIPTION_OBJECT {
        bulk:=object_of(p,chosen,"StaticMeshDescriptionBulkData",e)
        if error.code!=.None {return {},error}
        if bulk<=0 {error={.Unsupported_Value,source_models.data.offset,"LOD 0 has no mesh description; it is generated in Unreal"};return {},error}
        mesh.payload,error=description_object_payload(p,v,bulk,"StaticMeshDescriptionBulkData")
        if error.code!=.None {return {},error}
        mesh.layout=.Mesh_Description
    }
    if mesh.payload.raw_size==0 {error={.Unsupported_Value,source_models.data.offset,"the source model is empty; it is generated in Unreal"};return {},error}

    error=materials_read(p,&properties,&mesh)
    if error.code!=.None {return {},error}
    mesh.section_materials,error=section_materials_read(p,&properties,"SectionInfoMap",allocator)
    if error.code!=.None {return {},error}
    mesh.original_materials,error=section_materials_read(p,&properties,"OriginalSectionInfoMap",allocator)
    if error.code!=.None {return {},error}
    bounds_read(p,&properties,&mesh,e)
    if error.code!=.None {return {},error}
    return mesh,{}
}

// What the native tail of a StaticMesh keeps before its materials: the body setup and,
// before the mesh description became an object of its own, the payload of
// each source model. mesh, when given, takes the payload of LOD 0 from there.
@(private)
native_head :: proc(p:^unreal.Package,v:Versions,tail:unreal.Span,models:int,mesh:^Static_Mesh) -> (body_setup:unreal.Object_Ref,error:unreal.Error) {
    bytes,_:=unreal.span_bytes(p,tail)
    r:=reader_make(bytes,tail.offset)
    global:=u8_read(&r,"static mesh strip flags")
    _=u8_read(&r,"static mesh class strip flags")
    if global&1!=0 {return 0,{.Cooked,tail.offset,"static mesh editor data was stripped when cooking"}}
    if bool_read(&r,"static mesh cooked") {return 0,{.Cooked,tail.offset,"static mesh was saved cooked"}}
    body_setup=unreal.Object_Ref(i32_read(&r,"static mesh body setup"))
    if v.ue4>=UE4_NAV_COLLISION {_=take(&r,4,"static mesh navigation collision")}
    if v.ue4<UE4_THUMBNAIL_REMOVED {_=take(&r,16,"static mesh thumbnail angle and distance")}
    if v.rendering<RENDERING_HI_RES_FIELDS_REMOVED {
        text_skip(&r,"static mesh high-res source name")
        _=take(&r,4,"static mesh high-res source CRC")
    }
    _=take(&r,16,"static mesh lighting guid")
    sockets:=count_read(&r,4,"static mesh socket count")
    _=take(&r,sockets*4,"static mesh sockets")
    if failed(&r) {return 0,r.error}
    if !unreal.reference_valid(p,body_setup) {return 0,{.Invalid_Reference,tail.offset,"static mesh body setup"}}
    if mesh==nil || v.editor>=EDITOR_RAW_MESH_DEPRECATED && v.main>=MAIN_MESH_DESCRIPTION_OBJECT {return}
    for model in 0..<models {
        at:=unreal.Span{tail.offset+i64(r.at),tail.size-i64(r.at)}
        payload:Payload
        layout:Layout
        if v.editor<EDITOR_RAW_MESH_DEPRECATED {
            layout=.Raw_Mesh
            bulk:unreal.Byte_Bulk_Data
            bulk,error=unreal.byte_bulk_data(p,at)
            if error.code!=.None {return}
            payload=byte_payload(bulk)
            r.at+=int(bulk.source.size)
            _=take(&r,20,"raw mesh guid")
        } else {
            layout=.Mesh_Description
            if bool_read(&r,"mesh description is valid") {
                at=unreal.Span{tail.offset+i64(r.at),tail.size-i64(r.at)}
                size:i64
                payload,size,error=description_bulk_payload(p,v,at)
                if error.code!=.None {return}
                r.at+=int(size)
            }
        }
        if failed(&r) {return 0,r.error}
        if model==0 {mesh.payload,mesh.layout=payload,layout}
    }
    return
}

// The material of slot index of count from the StaticMaterial array that a
// StaticMesh of UE4 writes last in its native tail, untagged: some UE4 saves keep
// MaterialInterface only there. Each entry is the material, its slot name and
// imported slot name, and MeshUVChannelInfo (two bools and four densities).
// 0 when the end of the export is not that array.
@(private)
native_material :: proc(p:^unreal.Package,properties:^unreal.Property_List,index,count:int) -> unreal.Object_Ref {
    ENTRY :: size_of(i32)+2*size_of(u64)+2*size_of(b32)+4*size_of(f32)
    if p.summary.version_ue5>0 {return 0}
    tail,error:=unreal.object_native_payload(p,properties.trailing)
    if error.code!=.None {return 0}
    bytes,_:=unreal.span_bytes(p,tail)
    start:=len(bytes)-size_of(i32)-count*ENTRY
    if start<0 {return 0}
    r:=reader_make(bytes[start:],tail.offset+i64(start))
    if int(i32_read(&r,"static mesh native material count"))!=count {return 0}
    r.at+=index*ENTRY
    material:=unreal.Object_Ref(i32_read(&r,"static mesh native material"))
    if failed(&r) || !unreal.reference_valid(p,material) {return 0}
    return material
}

@(private)
byte_payload :: proc(bulk:unreal.Byte_Bulk_Data) -> Payload {
    return {bulk.payload,bulk.flags&unreal.BULK_ZLIB!=0?.Zlib:.Raw,bulk.size}
}

// An MeshDescriptionBulkData at span: the payload and how many bytes the struct takes.
@(private)
description_bulk_payload :: proc(p:^unreal.Package,v:Versions,span:unreal.Span) -> (payload:Payload,size:i64,error:unreal.Error) {
    if v.main<MAIN_VIRTUALIZED {
        bulk:unreal.Byte_Bulk_Data
        bulk,error=unreal.byte_bulk_data(p,span)
        if error.code!=.None {return}
        payload,size=byte_payload(bulk),bulk.source.size
    } else {
        bulk:unreal.Editor_Bulk_Data
        bulk,error=unreal.editor_bulk_data(p,span)
        if error.code!=.None {return}
        payload,size={bulk.payload,.Compressed_Buffer,bulk.raw_size},bulk.source.size
    }
    if v.editor>=EDITOR_BULK_DATA_GUID {size+=16}
    if v.enterprise>=ENTERPRISE_GUID_IS_HASH {size+=4}
    if size>span.size {return {},0,{.Truncated,span.offset,"mesh description bulk data guid"}}
    return
}

// The payload of an export of class, a MeshDescriptionBaseBulkData:
// StaticMeshDescriptionBulkData or SkeletalMeshDescriptionBulkData.
@(private)
description_object_payload :: proc(p:^unreal.Package,v:Versions,object:unreal.Object_Ref,class:string) -> (payload:Payload,error:unreal.Error) {
    if !export_of_class(p,object,"/Script/Engine",class) {
        return {},{.Invalid_Reference,0,"source model mesh description is not an export of its bulk data class"}
    }
    index:=int(object)-1
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&properties)
    tail:unreal.Span
    tail,error=unreal.object_native_payload(p,properties.trailing)
    if error.code!=.None {return}
    payload,_,error=description_bulk_payload(p,v,tail)
    return
}

@(private)
build_settings_read :: proc(p:^unreal.Package,v:Versions,model:^unreal.Property_List,out:^Build_Settings) -> (error:unreal.Error) {
    // MeshBuildSettings defaults: what a tagged struct leaves out.
    out^={scale={1,1,1},recompute_normals=true,recompute_tangents=true,remove_degenerates=true}
    property:=unreal.property_find(p,model,"BuildSettings")
    if property==nil {return}
    settings:unreal.Property_List
    settings,error=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&settings)
    e:=&error
    out.recompute_normals=bool_of(p,&settings,"bRecomputeNormals",true,e)
    out.recompute_tangents=bool_of(p,&settings,"bRecomputeTangents",true,e)
    out.weighted_normals=bool_of(p,&settings,"bComputeWeightedNormals",false,e)
    out.remove_degenerates=bool_of(p,&settings,"bRemoveDegenerates",true,e)
    if scale,found:=vector_of(p,&settings,"BuildScale3D",e);found {out.scale={f32(scale.x),f32(scale.y),f32(scale.z)}}
    if error.code!=.None {return}
    for axis in out.scale {
        if !(abs(axis)>1e-8) || axis-axis!=0 {return {.Unsupported_Value,property.data.offset,"source model build scale is zero or not finite"}}
    }
    nonuniform:=out.scale.x!=out.scale.y || out.scale.y!=out.scale.z
    out.legacy_tangent_scaling=nonuniform && v.fortnite>=0 && v.fortnite<FORTNITE_TANGENT_TRANSFORM
    return
}

// The object paths of the materials of the slots of a StaticMesh, by Unreal's
// index; "" for a slot without one.
static_material_paths :: proc(p:^unreal.Package,properties:^unreal.Property_List,allocator:=context.allocator) -> (paths:[]string,error:unreal.Error) {
    mesh:Static_Mesh
    mesh.allocator=allocator
    if error=materials_read(p,properties,&mesh);error.code!=.None {return}
    paths=make([]string,len(mesh.materials),allocator)
    for slot,i in mesh.materials {paths[i]=slot.path}
    return
}

@(private)
materials_read :: proc(p:^unreal.Package,properties:^unreal.Property_List,mesh:^Static_Mesh) -> (error:unreal.Error) {
    allocator:=mesh.allocator
    e:=&error
    if property:=unreal.property_find(p,properties,"StaticMaterials");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return}
        items:unreal.Struct_Array
        items,error=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
        if error.code!=.None {return}
        defer unreal.struct_array_destroy(&items)
        allocation_error:mem.Allocator_Error
        mesh.materials,allocation_error=make([]Material_Slot,len(items.items),allocator)
        if allocation_error!=nil {return {.Out_Of_Memory,property.data.offset,"static mesh materials"}}
        for &item,i in items.items {
            slot:=&mesh.materials[i]
            slot.material=object_of(p,&item,"MaterialInterface",e)
            slot.name=name_of(p,&item,"MaterialSlotName",allocator,e)
            slot.imported_name=name_of(p,&item,"ImportedMaterialSlotName",allocator,e)
            if error.code!=.None {return}
            if slot.material==0 {slot.material=native_material(p,properties,i,len(items.items))}
            if slot.material!=0 {slot.path,error=unreal.reference_path(p,slot.material,allocator)}
            if error.code!=.None {return}
        }
        return
    }
    // Saves before StaticMaterial: one slot per material, named after it.
    property:=unreal.property_find(p,properties,"Materials")
    if property==nil {return}
    view:unreal.Array_View
    view,error=unreal.property_array(p,property)
    if error.code!=.None {return}
    references:[]unreal.Object_Ref
    references,error=unreal.array_object_refs(p,view,context.temp_allocator)
    if error.code!=.None {return}
    allocation_error:mem.Allocator_Error
    mesh.materials,allocation_error=make([]Material_Slot,len(references),allocator)
    if allocation_error!=nil {return {.Out_Of_Memory,property.data.offset,"static mesh materials"}}
    for reference,i in references {
        slot:=&mesh.materials[i]
        slot.material=reference
        if reference==0 {continue}
        slot.path,error=unreal.reference_path(p,reference,allocator)
        if error.code!=.None {return}
        name,_:=unreal.reference_name(p,reference)
        base:=unreal.name_text(p,name,context.temp_allocator)
        text:=base
        for repeat:=1;;repeat+=1 {
            used:=false
            for other in mesh.materials[:i] {used||=other.name==text}
            if !used {break}
            text=fmt.tprintf("%s_%d",base,repeat)
        }
        slot.name=strings.clone(text,allocator)
        slot.imported_name=strings.clone(text,allocator)
    }
    return
}

// A MeshSectionInfoMap: a map of (LOD << 16 | section) to MeshSectionInfo; only the material of LOD 0 matters here.
@(private)
section_materials_read :: proc(p:^unreal.Package,properties:^unreal.Property_List,name:string,allocator:mem.Allocator) -> (materials:[]i32,error:unreal.Error) {
    property:=unreal.property_find(p,properties,name)
    if property==nil {return}
    info:unreal.Property_List
    info,error=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&info)
    entries:=unreal.property_find(p,&info,"Map")
    if entries==nil {return}
    bytes,_:=unreal.span_bytes(p,entries.data)
    r:=reader_make(bytes,entries.data.offset)
    removed:=count_read(&r,4,"section info removed key count")
    _=take(&r,removed*4,"section info removed keys")
    count:=count_read(&r,12,"section info count")
    if failed(&r) {return nil,r.error}
    sections:=make([dynamic]i32,allocator)
    defer if error.code!=.None {delete(sections)}
    for _ in 0..<count {
        key:=u32_read(&r,"section info key")
        if failed(&r) {return nil,r.error}
        value:unreal.Property_List
        value,error=unreal.properties_open(p,{entries.data.offset+i64(r.at),i64(len(bytes)-r.at)},false,context.temp_allocator)
        if error.code!=.None {return}
        r.at+=int(value.source.size)
        e:=&error
        material:=int_of(p,&value,"MaterialIndex",0,e)
        unreal.properties_destroy(&value)
        if error.code!=.None {return}
        lod,section:=key>>16,key&0xffff
        if lod!=0 {continue}
        if material<0 || material>1<<16 {error={.Malformed,entries.data.offset+i64(r.at),"section info material index"};return}
        for len(sections)<=int(section) {append(&sections,-1)}
        sections[section]=i32(material)
    }
    if r.at!=len(bytes) {error={.Malformed,entries.data.offset+i64(r.at),"section info map has trailing bytes"};return}
    return sections[:],{}
}

@(private)
bounds_read :: proc(p:^unreal.Package,properties:^unreal.Property_List,mesh:^Static_Mesh,error:^unreal.Error) {
    property:=unreal.property_find(p,properties,"ExtendedBounds")
    if property==nil {return}
    bounds,open_error:=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
    if open_error.code!=.None {return}
    defer unreal.properties_destroy(&bounds)
    origin,has_origin:=vector_of(p,&bounds,"Origin",error)
    extent,has_extent:=vector_of(p,&bounds,"BoxExtent",error)
    positive,_:=vector_of(p,properties,"PositiveBoundsExtension",error)
    negative,_:=vector_of(p,properties,"NegativeBoundsExtension",error)
    if error.code!=.None || !has_origin && !has_extent {return}
    for i in 0..<3 {
        mesh.bounds_min[i]=f32(origin[i]-extent[i]+negative[i])
        mesh.bounds_max[i]=f32(origin[i]+extent[i]-positive[i])
    }
    mesh.has_bounds=true
}

@(private)
int_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:i64,error:^unreal.Error) -> i64 {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return default}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return default}
    #partial switch read.kind {
    case .Signed:return read.signed
    case .Unsigned:if read.unsigned<=u64(max(i64)) {return i64(read.unsigned)}
    }
    error^={.Malformed,property.data.offset,"static mesh integer"}
    return default
}

@(private)
bool_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:bool,error:^unreal.Error) -> bool {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return default}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return default}
    if read.kind!=.Boolean {error^={.Malformed,property.data.offset,"static mesh boolean"};return default}
    return read.boolean
}

@(private)
object_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,error:^unreal.Error) -> unreal.Object_Ref {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return 0}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return 0}
    if read.kind!=.Object {error^={.Malformed,property.data.offset,"static mesh object reference"};return 0}
    return read.object
}

@(private)
name_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,allocator:mem.Allocator,error:^unreal.Error) -> string {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return ""}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return ""}
    if read.kind!=.Name {error^={.Malformed,property.data.offset,"static mesh name"};return ""}
    if unreal.name_plain(p,read.name)=="None" && read.name.number==0 {return ""}
    return unreal.name_text(p,read.name,allocator)
}

@(private)
vector_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,error:^unreal.Error) -> (vector:[3]f64,found:bool) {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return}
    if read.kind!=.Real_Vector || read.vector_count!=3 {error^={.Malformed,property.data.offset,"static mesh vector"};return}
    for i in 0..<3 {
        if read.vector[i]-read.vector[i]!=0 {error^={.Malformed,property.data.offset,"static mesh vector is not finite"};return}
        vector[i]=read.vector[i]
    }
    return vector,true
}
