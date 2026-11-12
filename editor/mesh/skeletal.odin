package mesh

import "core:math/linalg"
import "core:mem"
import unreal "project:plugins/unreal/editor/package"

// Skeletal meshes and skeletons of uncooked Unreal packages: the reference
// skeleton, the material slots and LOD 0 skinned to the bones, in Unreal's
// space as the static meshes are.
//
//   skeletal_read     the properties and the head of the native tail: bounds,
//                     materials, reference skeleton and where LOD 0 is
//   skeletal_decode   LOD 0: the SkeletalMeshLODModel the build of Unreal
//                     saved with the editor data, or the MeshDescription with
//                     skin weights a UE 5.4 mesh is built from
//   skeleton_read     the reference skeleton of a Skeleton

Skeletal_Layout :: enum u8 {
    Lod_Model,        // SkeletalMeshLODModel in the native tail: what the build of Unreal made of the source
    Mesh_Description, // MeshDescription in a SkeletalMeshDescriptionBulkData: the source since UE 5.4
}

// A bone of a reference skeleton with its pose at rest, relative to its parent.
Bone :: struct {
    name:string,
    parent:int,          // row of an earlier bone, -1 for the root
    rotation:[4]f32,     // x, y, z, w, unit length
    translation:[3]f32,
    scale:[3]f32,
}

Skeletal_Mesh :: struct {
    object:unreal.Object_Ref,
    layout:Skeletal_Layout,
    bones:[]Bone,                   // the reference skeleton of the mesh: its bind pose
    skeleton:string,                // object path of its Skeleton, "" without one
    materials:[]Material_Slot,      // SkeletalMaterial: what sections and components name by index
    section_materials:[]i32,        // LODMaterialMap of LOD 0: the material of each section, -1 to keep its own
    build:Build_Settings,           // of LOD 0: how a mesh description is built
    weld:Weld_Settings,             // of LOD 0: how the build welds its corners and limits their influences
    model:unreal.Span,              // SkeletalMeshModel in the native tail
    payload:Payload,                // the mesh description, with that layout
    morph_targets:[]unreal.Object_Ref, // MorphTargets: the MorphTarget exports of a LOD model
    sockets:[]Socket,               // its own; those of its Skeleton are in that package
    bounds_min,bounds_max:[3]f32,   // ImportedBounds: of the mesh at rest
    allocator:mem.Allocator,
}

Skeleton :: struct {
    object:unreal.Object_Ref,
    bones:[]Bone,
    sockets:[]Socket,
    morph_curves:[]string, // the curves its metadata marks as driving morph targets
    curves_known:bool,     // false when the save keeps that metadata where it is not read
    allocator:mem.Allocator,
}

// A SkeletalMeshSocket: a named place relative to a bone, in its space.
Socket :: struct {
    name,bone:string,
    location:[3]f64,
    rotation:[3]f64, // Rotator: pitch, yaw, roll in degrees
    scale:[3]f64,
}

// The SkeletalMeshBuildSettings that weld the corners of a mesh description
// into the vertices of its LOD model and limit their influences.
Weld_Settings :: struct {
    position,normal,uv:f32, // ThresholdPosition, ThresholdTangentNormal, ThresholdUV
    influences:int,         // BoneInfluenceLimit: 0 takes that of the project
}

// The thresholds of the normals and UVs: SkeletalMeshBuildSettings
// defaults, with the one of positions.
@(private) NORMALS_ARE_SAME :: 0.00002
@(private) UVS_ARE_SAME :: 1.0/1024
@(private) WELD_DEFAULTS :: Weld_Settings{position=DEGENERATE_DISTANCE,normal=NORMALS_ARE_SAME,uv=UVS_ARE_SAME}

// An influence of a bone on a vertex.
Influence :: struct {
    bone:u16,   // row of Skeletal_Mesh.bones
    weight:f32, // as Unreal keeps it: the weights of a vertex add to one
}

// LOD 0 as Unreal draws it: a Mesh whose positions carry their influences.
Skinned_Mesh :: struct {
    using geometry:Mesh,
    skin_first:[]u32,        // by row of positions, and one past the last: its range of influences
    influences:[]Influence,
    left_out:int,            // sections Unreal does not draw (bDisabled)
    cloth:int,               // sections Unreal draws with a cloth simulation
    morphs:[]Morph_Target,   // of LOD 0
    corner_morph:[]u32,      // by corner, with morphs: its row of the deltas of each target
}

skeletal_mesh_destroy :: proc(mesh:^Skeletal_Mesh) {
    if mesh==nil || mesh.allocator.procedure==nil {return}
    a:=mesh.allocator
    bones_destroy(mesh.bones,a)
    for slot in mesh.materials {delete(slot.name,a);delete(slot.imported_name,a);delete(slot.path,a)}
    delete(mesh.materials,a)
    delete(mesh.section_materials,a)
    delete(mesh.morph_targets,a)
    sockets_destroy(mesh.sockets,a)
    delete(mesh.skeleton,a)
    mesh^={}
}

skeleton_destroy :: proc(skeleton:^Skeleton) {
    if skeleton==nil || skeleton.allocator.procedure==nil {return}
    bones_destroy(skeleton.bones,skeleton.allocator)
    sockets_destroy(skeleton.sockets,skeleton.allocator)
    for name in skeleton.morph_curves {delete(name,skeleton.allocator)}
    delete(skeleton.morph_curves,skeleton.allocator)
    skeleton^={}
}

skinned_mesh_destroy :: proc(mesh:^Skinned_Mesh) {
    if mesh==nil || mesh.allocator.procedure==nil {return}
    a:=mesh.allocator
    delete(mesh.skin_first,a)
    delete(mesh.influences,a)
    for target in mesh.morphs {delete(target.name,a);delete(target.positions,a);delete(target.normals,a)}
    delete(mesh.morphs,a)
    delete(mesh.corner_morph,a)
    mesh_destroy(&mesh.geometry)
    mesh^={}
}

@(private)
sockets_destroy :: proc(sockets:[]Socket,allocator:mem.Allocator) {
    for socket in sockets {delete(socket.name,allocator);delete(socket.bone,allocator)}
    delete(sockets,allocator)
}

@(private)
bones_destroy :: proc(bones:[]Bone,allocator:mem.Allocator) {
    for bone in bones {delete(bone.name,allocator)}
    delete(bones,allocator)
}

// Whether an export is a SkeletalMesh of /Script/Engine.
skeletal_mesh_is :: proc(p:^unreal.Package,index:int) -> bool {return export_is(p,index,"SkeletalMesh")}

// Whether an export is a Skeleton of /Script/Engine.
skeleton_is :: proc(p:^unreal.Package,index:int) -> bool {return export_is(p,index,"Skeleton")}

// SkeletalMeshCustomVersion::SplitModelAndRenderData: the oldest skeletal
// mesh read; before it the LOD model kept render buffers of an older format.
@(private) SKELETAL_SPLIT_MODEL :: 12
@(private) SKELETAL_REMOVE_TRIANGLE_SORTING :: 13
@(private) SKELETAL_REMOVE_DUPLICATED_CLOTHING :: 14
@(private) SKELETAL_DEPRECATE_SECTION_DISABLED :: 15
@(private) SKELETAL_SECTION_IGNORE_BY_REDUCE :: 16
@(private) SKELETAL_REMOVE_ENABLE_CLOTH_LOD :: 18
@(private) UE4_APEX_CLOTH :: 254
@(private) UE4_APEX_CLOTH_LOD :: 280
@(private) UE4_MOVE_SKELETALMESH_SHADOWCASTING :: 302
@(private) UE4_REFERENCE_SKELETON_REFACTOR :: 310
@(private) UE4_FIXUP_ROOTBONE_PARENT :: 312
@(private) UE4_EIGHT_BONE_INFLUENCES :: 332  // VER_UE4_SUPPORT_8_BONE_INFLUENCES_SKELETAL_MESHES
@(private) UE4_STORE_BONE_EXPORT_NAMES :: 370
@(private) ANIM_BONE_INDEX_LIMIT_PER_CHUNK :: 4 // bone indices of 16 bits
@(private) ANIM_UNLIMITED_BONE_INFLUENCES :: 5
@(private) RENDERING_TEXTURE_STREAMING_UV_DATA :: 10
@(private) RENDERING_INCREASE_NORMAL_PRECISION :: 26
@(private) EDITOR_REFACTOR_MESH_EDITOR_MATERIALS :: 8
@(private) EDITOR_SKELETAL_MESH_BUILD_REFACTOR :: 37
@(private) EDITOR_SKELETAL_SOURCE_DATA_PRIVATE_ASSET :: 38 // SkeletalMeshMoveEditorSourceDataToPrivateAsset
@(private) CORE_SKELETAL_MATERIAL_EDITOR_DATA_STRIPPING :: 3
@(private) RELEASE_SECTION_DISABLE :: 12      // AddSkeletalMeshSectionDisable
@(private) MAIN_RAY_TRACING_SECTION_FLAG :: 54 // SkelMeshSectionVisibleInRayTracingFlagAdded
@(private) MAIN_LOD_MODEL_MESH_INFO :: 58
@(private) MAIN_SKIN_WEIGHT_PRECISION :: 90   // IncreasedSkinWeightPrecision: weights of 16 bits
@(private) MAIN_RELEASE_CLOTH_LOD_BIAS :: 15  // AddClothMappingLODBias
@(private) MAIN_RELEASE_REMOVE_LOD_BULK_DATA :: 22 // RemoveSkeletalMeshLODModelBulkDatas
@(private) FORTNITE_NEW_SKELETAL_IMPORTER :: 14 // NewSkeletalMeshImporterWorkflow
@(private) FORTNITE_REDUCE_BASE_LOD :: 22     // AllowSkeletalMeshToReduceTheBaseLOD
@(private) FORTNITE_SKELETAL_DESCRIPTION :: 133 // MeshDescriptionForSkeletalMesh
@(private) FORTNITE_OVERLAY_MATERIAL :: 196   // MeshMaterialSlotOverlayMaterialAdded
@(private) FORTNITE_POLYGON_WIREFRAME :: 273  // SkeletalMeshPolygonWireframe
@(private) RECOMPUTE_TANGENT_RUNTIME :: 1
@(private) RECOMPUTE_TANGENT_VERTEX_MASK :: 2
@(private) OVERLAPPING_DETECT :: 1

// StripDataFlags::Editor and ::AudioVisual.
@(private) STRIP_EDITOR :: 1
@(private) STRIP_AUDIO_VISUAL :: 2

// MeshUVChannelInfo: two bools of four bytes and four densities.
@(private) UV_CHANNEL_INFO_BYTES :: 2*4+4*4

// The bones of ReferenceSkeleton are BoneIndexType, 16 bits.
MAX_BONES :: 1<<16

// The properties of a SkeletalMesh export, its reference skeleton and
// materials from the native tail, and where LOD 0 is.
skeletal_read :: proc(p:^unreal.Package,index:int,allocator:=context.allocator) -> (Skeletal_Mesh,unreal.Error) {
    // Built in locals: results are copied out before deferred cleanup runs.
    mesh:Skeletal_Mesh
    error:unreal.Error
    if !skeletal_mesh_is(p,index) {return {},{.Invalid_Reference,0,"export is not a SkeletalMesh"}}
    at:=p.exports[index].data.offset
    v:=versions_of(p)
    if v.skeletal<SKELETAL_SPLIT_MODEL || v.rendering<RENDERING_INCREASE_NORMAL_PRECISION {
        return {},{.Unsupported_Value,at,"skeletal mesh saved before its LOD model was kept apart from its render data; resave it in Unreal"}
    }
    mesh.allocator=allocator
    mesh.object=unreal.Object_Ref(index+1)
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,allocator)
    if error.code!=.None {return {},error}
    defer unreal.properties_destroy(&properties)
    defer if error.code!=.None {skeletal_mesh_destroy(&mesh)}
    e:=&error

    if skeleton:=object_of(p,&properties,"Skeleton",e);skeleton!=0 && error.code==.None {
        mesh.skeleton,error=unreal.reference_path(p,skeleton,allocator)
    }
    if error.code!=.None {return {},error}
    mesh.sockets,error=sockets_read(p,&properties,allocator)
    if error.code!=.None {return {},error}
    if property:=unreal.property_find(p,&properties,"MorphTargets");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return {},error}
        mesh.morph_targets,error=unreal.array_object_refs(p,view,allocator)
        if error.code!=.None {return {},error}
    }
    mesh.build={scale={1,1,1},recompute_normals=true,recompute_tangents=true,remove_degenerates=true}
    mesh.weld=WELD_DEFAULTS
    if property:=unreal.property_find(p,&properties,"LODInfo");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return {},error}
        lods:unreal.Struct_Array
        lods,error=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
        if error.code!=.None {return {},error}
        defer unreal.struct_array_destroy(&lods)
        if len(lods.items)>0 {
            error=build_settings_read(p,v,&lods.items[0],&mesh.build)
            if error.code!=.None {return {},error}
            error=weld_settings_read(p,&lods.items[0],&mesh.weld)
            if error.code!=.None {return {},error}
            mesh.section_materials,error=int_array_of(p,&lods.items[0],"LODMaterialMap",allocator)
            if error.code!=.None {return {},error}
        }
    }
    if v.fortnite>=FORTNITE_SKELETAL_DESCRIPTION {
        source_models:=unreal.property_find(p,&properties,"SourceModels")
        if source_models==nil {return {},{.Unsupported_Value,at,"skeletal mesh keeps no SourceModels; it was cooked"}}
        view:unreal.Array_View
        view,error=unreal.property_array(p,source_models)
        if error.code!=.None {return {},error}
        models:unreal.Struct_Array
        models,error=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
        if error.code!=.None {return {},error}
        defer unreal.struct_array_destroy(&models)
        if len(models.items)==0 {error={.Unsupported_Value,source_models.data.offset,"skeletal mesh has no source model"};return {},error}
        bulk:=object_of(p,&models.items[0],"MeshDescriptionBulkData",e)
        if error.code!=.None {return {},error}
        if bulk>0 {
            mesh.payload,error=description_object_payload(p,v,bulk,"SkeletalMeshDescriptionBulkData")
            if error.code!=.None {return {},error}
            if mesh.payload.raw_size>0 {mesh.layout=.Mesh_Description}
        }
    }

    tail:unreal.Span
    tail,error=unreal.object_native_payload(p,properties.trailing)
    if error.code!=.None {return {},error}
    bytes,_:=unreal.span_bytes(p,tail)
    r:=reader_make(bytes,tail.offset)
    global:=u8_read(&r,"skeletal mesh strip flags")
    _=u8_read(&r,"skeletal mesh class strip flags")
    if global&STRIP_EDITOR!=0 {error={.Cooked,tail.offset,"skeletal mesh editor data was stripped when cooking"};return {},error}
    origin,extent:[3]f32
    for &x in origin {x=f32(real_read(&r,v,"skeletal mesh imported bounds"))}
    for &x in extent {x=f32(real_read(&r,v,"skeletal mesh imported bounds"))}
    _=real_read(&r,v,"skeletal mesh imported bounds radius")
    mesh.bounds_min,mesh.bounds_max=origin-extent,origin+extent
    mesh.materials=skeletal_materials_read(&r,p,v,allocator)
    mesh.bones=reference_skeleton_read(&r,p,v,allocator)
    if failed(&r) {error=r.error;return {},error}
    mesh.model={tail.offset+i64(r.at),tail.size-i64(r.at)}
    return mesh,{}
}

// The reference skeleton of a Skeleton export: what its animations name.
skeleton_read :: proc(p:^unreal.Package,index:int,allocator:=context.allocator) -> (skeleton:Skeleton,error:unreal.Error) {
    if !skeleton_is(p,index) {return {},{.Invalid_Reference,0,"export is not a Skeleton"}}
    v:=versions_of(p)
    if v.ue4<UE4_REFERENCE_SKELETON_REFACTOR {return {},{.Unsupported_Value,p.exports[index].data.offset,"skeleton saved before its reference skeleton was kept; resave it in Unreal"}}
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&properties)
    tail:unreal.Span
    tail,error=unreal.object_native_payload(p,properties.trailing)
    if error.code!=.None {return}
    bytes,_:=unreal.span_bytes(p,tail)
    r:=reader_make(bytes,tail.offset)
    bones:=reference_skeleton_read(&r,p,v,allocator)
    if failed(&r) {bones_destroy(bones,allocator);return {},r.error}
    sockets:[]Socket
    sockets,error=sockets_read(p,&properties,allocator)
    if error.code!=.None {bones_destroy(bones,allocator);return}
    curves,known:=morph_curves_read(&r,p,v,index,allocator)
    return {object=unreal.Object_Ref(index+1),bones=bones,sockets=sockets,morph_curves=curves,curves_known=known,allocator=allocator},{}
}

// The thresholds and influence limit of the BuildSettings of an SkeletalMeshLODInfo.
@(private)
weld_settings_read :: proc(p:^unreal.Package,lod:^unreal.Property_List,out:^Weld_Settings) -> (error:unreal.Error) {
    property:=unreal.property_find(p,lod,"BuildSettings")
    if property==nil {return}
    settings:unreal.Property_List
    settings,error=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&settings)
    e:=&error
    out.position=f32_of(p,&settings,"ThresholdPosition",out.position,e)
    out.normal=f32_of(p,&settings,"ThresholdTangentNormal",out.normal,e)
    out.uv=f32_of(p,&settings,"ThresholdUV",out.uv,e)
    limit:=int_of(p,&settings,"BoneInfluenceLimit",0,e)
    if error.code!=.None {return}
    if !(out.position>=0) || !(out.normal>=0) || !(out.uv>=0) {return {.Malformed,property.data.offset,"skeletal mesh build threshold is negative or not a number"}}
    out.influences=int(clamp(limit,0,LOD_INFLUENCES))
    return
}

@(private)
f32_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:f32,error:^unreal.Error) -> f32 {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return default}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return default}
    if read.kind!=.Real {error^={.Malformed,property.data.offset,"skeletal mesh float"};return default}
    return f32(read.real)
}

// The SkeletalMeshSocket exports of the Sockets of a SkeletalMesh or Skeleton.
@(private)
sockets_read :: proc(p:^unreal.Package,properties:^unreal.Property_List,allocator:mem.Allocator) -> (sockets:[]Socket,error:unreal.Error) {
    property:=unreal.property_find(p,properties,"Sockets")
    if property==nil {return}
    view:unreal.Array_View
    view,error=unreal.property_array(p,property)
    if error.code!=.None {return}
    objects:[]unreal.Object_Ref
    objects,error=unreal.array_object_refs(p,view,context.temp_allocator)
    if error.code!=.None {return}
    out:=make([dynamic]Socket,allocator)
    defer if error.code!=.None {sockets_destroy(out[:],allocator)}
    for object in objects {
        if !export_of_class(p,object,"/Script/Engine","SkeletalMeshSocket") {continue}
        index:=int(object)-1
        list:unreal.Property_List
        list,error=unreal.export_properties(p,index,true,context.temp_allocator)
        if error.code!=.None {return}
        defer unreal.properties_destroy(&list)
        e:=&error
        // SkeletalMeshSocket's defaults: at its bone, unscaled.
        socket:=Socket{scale={1,1,1}}
        socket.name=name_of(p,&list,"SocketName",allocator,e)
        socket.bone=name_of(p,&list,"BoneName",allocator,e)
        if location,found:=vector_of(p,&list,"RelativeLocation",e);found {socket.location=location}
        if rotation,found:=vector_of(p,&list,"RelativeRotation",e);found {socket.rotation=rotation}
        if scale,found:=vector_of(p,&list,"RelativeScale",e);found {socket.scale=scale}
        append(&out,socket)
        if error.code!=.None {return}
    }
    return out[:],{}
}

// The array of SkeletalMaterial of the native tail of a SkeletalMesh.
@(private)
skeletal_materials_read :: proc(r:^Reader,p:^unreal.Package,v:Versions,allocator:mem.Allocator) -> []Material_Slot {
    count:=count_read(r,4,"skeletal mesh material count")
    if failed(r) {return nil}
    slots,allocation_error:=make([]Material_Slot,count,allocator)
    if allocation_error!=nil {bad(r,.Out_Of_Memory,"skeletal mesh materials");return nil}
    for &slot in slots {
        slot.material=unreal.Object_Ref(i32_read(r,"skeletal material"))
        if v.editor>=EDITOR_REFACTOR_MESH_EDITOR_MATERIALS {
            slot.name=slot_name_read(r,p,"skeletal material slot name",allocator)
            imported:=true
            if v.core>=CORE_SKELETAL_MATERIAL_EDITOR_DATA_STRIPPING {imported=bool_read(r,"skeletal material keeps its imported slot name")}
            if imported {slot.imported_name=slot_name_read(r,p,"skeletal material imported slot name",allocator)}
        } else {
            if v.ue4>=UE4_MOVE_SKELETALMESH_SHADOWCASTING {_=bool_read(r,"skeletal material shadow casting")}
            if v.recompute_tangent>=RECOMPUTE_TANGENT_RUNTIME {_=bool_read(r,"skeletal material recompute tangent")}
        }
        if v.rendering>=RENDERING_TEXTURE_STREAMING_UV_DATA {_=take(r,UV_CHANNEL_INFO_BYTES,"skeletal material uv channel data")}
        if v.fortnite>=FORTNITE_OVERLAY_MATERIAL {_=i32_read(r,"skeletal material overlay")}
        if failed(r) {return slots}
        if !unreal.reference_valid(p,slot.material) {bad(r,.Invalid_Reference,"skeletal material");return slots}
        if slot.material!=0 {
            path,error:=unreal.reference_path(p,slot.material,allocator)
            if error.code!=.None {r.error=error;return slots}
            slot.path=path
        }
    }
    return slots
}

// A slot name: "" for None.
@(private)
slot_name_read :: proc(r:^Reader,p:^unreal.Package,field:string,allocator:mem.Allocator) -> string {
    name:=name_read(r,p,field)
    if failed(r) || unreal.name_plain(p,name)=="None" && name.number==0 {return ""}
    return unreal.name_text(p,name,allocator)
}

// ReferenceSkeleton: the bones, their poses and the map of their names. A
// parent always comes before its children.
@(private)
reference_skeleton_read :: proc(r:^Reader,p:^unreal.Package,v:Versions,allocator:mem.Allocator) -> []Bone {
    count:=count_read(r,12,"bone count")
    if failed(r) {return nil}
    if count==0 {bad(r,.Malformed,"reference skeleton has no bones");return nil}
    if count>MAX_BONES {bad(r,.Limit,"bone count");return nil}
    bones,allocation_error:=make([]Bone,count,allocator)
    if allocation_error!=nil {bad(r,.Out_Of_Memory,"bones");return nil}
    for &bone in bones {
        name:=name_read(r,p,"bone name")
        bone.parent=int(i32_read(r,"bone parent"))
        if v.ue4<UE4_REFERENCE_SKELETON_REFACTOR {_=take(r,4,"bone color")}
        if v.ue4>=UE4_STORE_BONE_EXPORT_NAMES {text_skip(r,"bone export name")}
        if failed(r) {return bones}
        bone.name=unreal.name_text(p,name,allocator)
    }
    real_size:=v.ue5>=UE5_LARGE_WORLD_COORDINATES?8:4
    if count_read(r,10*real_size,"bone pose count")!=count && !failed(r) {bad(r,.Malformed,"reference skeleton has another number of poses than of bones");return bones}
    for &bone in bones {
        for &x in bone.rotation {x=f32(real_read(r,v,"bone rotation"))}
        for &x in bone.translation {x=f32(real_read(r,v,"bone translation"))}
        for &x in bone.scale {x=f32(real_read(r,v,"bone scale"))}
    }
    if v.ue4>=UE4_REFERENCE_SKELETON_REFACTOR {_=take(r,count_read(r,12,"bone name map count")*12,"bone name map")}
    if failed(r) {return bones}
    if v.ue4<UE4_FIXUP_ROOTBONE_PARENT {bones[0].parent= -1}
    for &bone,i in bones {
        if i==0 && bone.parent!= -1 || i>0 && (bone.parent<0 || bone.parent>=i) {bad(r,.Malformed,"bone parent must be an earlier bone, and only the first is the root");return bones}
        q:=bone.rotation
        length:=linalg.length(q)
        if !(length>1e-6) || !finite(bone.translation) || !finite(bone.scale) || length-length!=0 {bad(r,.Malformed,"bone pose is not finite or its rotation has no length");return bones}
        bone.rotation=q/length
    }
    return bones
}

// The ints of an IntProperty array in a property list; nil without it.
@(private)
int_array_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,allocator:mem.Allocator) -> (values:[]i32,error:unreal.Error) {
    property:=unreal.property_find(p,list,name)
    if property==nil {return}
    view:unreal.Array_View
    view,error=unreal.property_array(p,property)
    if error.code!=.None {return}
    if view.element.type_count==0 || unreal.name_plain(p,view.element.types[0].name)!="IntProperty" || i64(view.count)*4!=view.data.size {
        return nil,{.Malformed,property.data.offset,"expected an array of IntProperty"}
    }
    bytes,_:=unreal.span_bytes(p,view.data)
    allocation_error:mem.Allocator_Error
    values,allocation_error=make([]i32,view.count,allocator)
    if allocation_error!=nil {return nil,{.Out_Of_Memory,property.data.offset,name}}
    for &value,i in values {value=transmute(i32)u32_at(bytes,i*4)}
    return
}

@(private)
f32_read :: proc(r:^Reader,field:string) -> f32 {return transmute(f32)u32_read(r,field)}

// A component of an Vector or Quat: a double since large world coordinates, a float before.
@(private)
real_read :: proc(r:^Reader,v:Versions,field:string) -> f64 {
    if v.ue5<UE5_LARGE_WORLD_COORDINATES {return f64(f32_read(r,field))}
    bytes:=take(r,8,field)
    if len(bytes)!=8 {return 0}
    return f64_at(bytes,0)
}

// A Name: its row in the name table and its number.
@(private)
name_read :: proc(r:^Reader,p:^unreal.Package,field:string) -> unreal.Name_Ref {
    name:=unreal.Name_Ref{i32_read(r,field),i32_read(r,field)}
    if !failed(r) && !unreal.name_valid(p,name) {bad(r,.Malformed,field)}
    return name
}

// An array of elements of size bytes, skipped.
@(private)
array_skip :: proc(r:^Reader,size:int,field:string) {_=take(r,count_read(r,size,field)*size,field)}
