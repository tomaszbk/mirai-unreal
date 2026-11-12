package mesh

import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strings"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"

// SkeletalMeshLODModel of LOD 0, as the native tail of a SkeletalMesh keeps
// it with the editor data: the sections of the build of Unreal, each with its
// SoftSkinVertex rows and the map of its bone indices to the reference
// skeleton, and one index buffer over all of them.

// The influences of an SoftSkinVertex.
LOD_INFLUENCES :: 12
// The UV channels of an SoftSkinVertex.
LOD_UVS :: 4
// A weight of one in 16 bits.
RAW_WEIGHT_ONE :: 65535
// MAX_INFLUENCES_PER_STREAM and EXTRA_BONE_INFLUENCES: the influences of older saves.
@(private) INFLUENCES_PER_STREAM :: 4
@(private) EXTRA_INFLUENCES :: 8
// MeshToMeshVertData: three Vector4f, four uint16, a float and padding.
@(private) CLOTH_MAPPING_BYTES :: 3*16+4*2+4+4
// ClothingSectionData: the GUID of a clothing asset and the LOD of it.
@(private) CLOTHING_DATA_BYTES :: 16+4

// Where the parts of an SoftSkinVertex are, by the versions of the package.
@(private)
Soft_Vertex :: struct {
    size:int,
    bones,bone_count,bone_size:int,       // offset of InfluenceBones, how many and their bytes
    weights,weight_count,weight_size:int, // offset of InfluenceWeights, how many and their bytes
}

// Position, TangentX, TangentY, TangentZ (with the binormal sign in w), Vs and Color come first.
@(private) SOFT_TANGENT_X :: 12
@(private) SOFT_TANGENT_Z :: 36
@(private) SOFT_UVS :: 52
@(private) SOFT_COLOR :: SOFT_UVS+LOD_UVS*8
@(private) SOFT_INFLUENCES :: SOFT_COLOR+4

@(private)
soft_vertex_of :: proc(v:Versions) -> (s:Soft_Vertex) {
    s.bone_size=v.anim>=ANIM_BONE_INDEX_LIMIT_PER_CHUNK?2:1
    s.bone_count=INFLUENCES_PER_STREAM
    if v.ue4>=UE4_EIGHT_BONE_INFLUENCES {s.bone_count=EXTRA_INFLUENCES}
    if v.anim>=ANIM_UNLIMITED_BONE_INFLUENCES {s.bone_count=LOD_INFLUENCES}
    s.bones=SOFT_INFLUENCES
    s.weights=s.bones+s.bone_count*s.bone_size
    if v.main>=MAIN_SKIN_WEIGHT_PRECISION {
        s.weight_count,s.weight_size=LOD_INFLUENCES,2
    } else {
        s.weight_count,s.weight_size=s.bone_count,1
    }
    s.size=s.weights+s.weight_count*s.weight_size
    return
}

@(private)
Lod_Section :: struct {
    material:int,                // MaterialIndex
    first_index,triangles:int,
    first_vertex:int,
    vertices:[]u8,               // the soft vertices
    vertex_count:int,
    bone_map:[]u8,               // uint16 rows of the reference skeleton, by the bone index of a vertex
    disabled,cloth:bool,
}

@(private)
Lod_Model :: struct {
    sections:[]Lod_Section,
    disabled_sources:[]i32, // keys of UserSectionsData that are bDisabled: OriginalDataSectionIndex of the sections of the import
    indices:[]u8,  // uint32 rows of the vertices of every section
    index_count:int,
    uv_count:int,
    vertex:Soft_Vertex,
}

@(private)
lod_model_read :: proc(p:^unreal.Package,v:Versions,span:unreal.Span,scratch:mem.Allocator) -> (m:Lod_Model,error:unreal.Error) {
    bytes,_:=unreal.span_bytes(p,span)
    r:=reader_make(bytes,span.offset)
    if v.fortnite>=FORTNITE_REDUCE_BASE_LOD {
        global:=u8_read(&r,"skeletal mesh model strip flags")
        _=u8_read(&r,"skeletal mesh model class strip flags")
        if global&STRIP_EDITOR!=0 {return {},{.Cooked,span.offset,"skeletal mesh model editor data was stripped when cooking"}}
    }
    lods:=count_read(&r,2,"LOD model count")
    if failed(&r) {return {},r.error}
    if lods==0 {return {},{.Unsupported_Value,span.offset,"skeletal mesh has no LOD model; build it in Unreal and save it"}}
    global:=u8_read(&r,"LOD model strip flags")
    _=u8_read(&r,"LOD model class strip flags")
    if global&(STRIP_EDITOR|STRIP_AUDIO_VISUAL)!=0 {return {},{.Cooked,span.offset,"LOD model was stripped when cooking"}}
    m.vertex=soft_vertex_of(v)
    count:=count_read(&r,16,"LOD model section count")
    if failed(&r) {return {},r.error}
    m.sections=make([]Lod_Section,count,scratch)
    for &section in m.sections {
        lod_section_read(&r,v,m.vertex,&section)
        if failed(&r) {return {},r.error}
    }
    if v.editor>=EDITOR_SKELETAL_MESH_BUILD_REFACTOR {
        // A map of int32 to SkelMeshSourceSectionUserData: the user's settings of each section.
        entries:=count_read(&r,4,"LOD model user section count")
        disabled:=make([dynamic]i32,scratch)
        for _ in 0..<entries {
            key:=i32_read(&r,"user section key")
            user:=u8_read(&r,"user section strip flags")
            _=u8_read(&r,"user section class strip flags")
            if user&STRIP_EDITOR!=0 {continue}
            _=bool_read(&r,"user section recompute tangent")
            if v.recompute_tangent>=RECOMPUTE_TANGENT_VERTEX_MASK {_=u8_read(&r,"user section recompute tangent mask")}
            _=bool_read(&r,"user section cast shadow")
            if v.main>=MAIN_RAY_TRACING_SECTION_FLAG {_=bool_read(&r,"user section visible in ray tracing")}
            if bool_read(&r,"user section disabled") {append(&disabled,key)}
            _=i32_read(&r,"user section generate up to LOD")
            _=take(&r,2,"user section cloth asset")
            _=take(&r,CLOTHING_DATA_BYTES,"user section clothing data")
            if failed(&r) {return {},r.error}
        }
        m.disabled_sources=disabled[:]
    }
    m.index_count=count_read(&r,4,"LOD model index count")
    m.indices=take(&r,m.index_count*4,"LOD model indices")
    if v.fortnite>=FORTNITE_POLYGON_WIREFRAME {array_skip(&r,4,"LOD model wireframe indices")}
    array_skip(&r,2,"LOD model active bones")
    if v.main>=MAIN_LOD_MODEL_MESH_INFO {array_skip(&r,16,"LOD model imported mesh infos")}
    _=u32_read(&r,"LOD model legacy size")
    _=u32_read(&r,"LOD model vertex count")
    array_skip(&r,2,"LOD model required bones")
    if failed(&r) {return {},r.error}
    if v.main_release<MAIN_RELEASE_REMOVE_LOD_BULK_DATA {
        if !bulk_skip(&r,p,4,"LOD model raw point indices") {return {},r.error}
    } else {
        array_skip(&r,4,"LOD model raw point indices")
    }
    if v.fortnite>=FORTNITE_NEW_SKELETAL_IMPORTER && v.editor<EDITOR_SKELETAL_SOURCE_DATA_PRIVATE_ASSET {
        // RawSkeletalMeshBulkData of the import, before it moved to its own object.
        if v.editor>=EDITOR_SKELETAL_MESH_BUILD_REFACTOR {_=take(&r,2,"raw skeletal mesh import versions")}
        if !bulk_skip(&r,p,1,"raw skeletal mesh bulk data") {return {},r.error}
        _=take(&r,16,"raw skeletal mesh guid")
        _=bool_read(&r,"raw skeletal mesh guid is hash")
    }
    if v.editor>=EDITOR_SKELETAL_SOURCE_DATA_PRIVATE_ASSET {
        text_skip(&r,"raw skeletal mesh id")
        _=bool_read(&r,"LOD model build data available")
        _=bool_read(&r,"LOD model raw data empty")
    }
    array_skip(&r,4,"LOD model mesh to import vertex map")
    _=i32_read(&r,"LOD model max import vertex")
    m.uv_count=int(u32_read(&r,"LOD model texture coordinate count"))
    if failed(&r) {return {},r.error}
    if m.uv_count>LOD_UVS {return {},{.Malformed,span.offset+i64(r.at),"LOD model texture coordinate count"}}
    m.uv_count=max(m.uv_count,1)
    return m,{}
}

// A bulk data of elements of element_size bytes in the reader, skipped.
@(private)
bulk_skip :: proc(r:^Reader,p:^unreal.Package,element_size:int,field:string) -> bool {
    if failed(r) {return false}
    at:=r.base+i64(r.at)
    bulk,error:=unreal.byte_bulk_data(p,{at,i64(len(r.bytes)-r.at)},element_size)
    if error.code!=.None {r.error=error;return false}
    _=take(r,int(bulk.source.size),field)
    return !failed(r)
}

// SkelMeshSection, for saves since SplitModelAndRenderData.
@(private)
lod_section_read :: proc(r:^Reader,v:Versions,layout:Soft_Vertex,s:^Lod_Section) {
    global:=u8_read(r,"section strip flags")
    _=u8_read(r,"section class strip flags")
    if global&(STRIP_EDITOR|STRIP_AUDIO_VISUAL)!=0 {bad(r,.Cooked,"section was stripped when cooking");return}
    s.material=int(u16_read(r,"section material"))
    s.first_index=int(u32_read(r,"section first index"))
    s.triangles=int(u32_read(r,"section triangle count"))
    if v.fortnite>=FORTNITE_POLYGON_WIREFRAME {_=take(r,8,"section wireframe range")}
    if v.skeletal<SKELETAL_REMOVE_TRIANGLE_SORTING {_=u8_read(r,"section triangle sorting")}
    if v.ue4>=UE4_APEX_CLOTH {
        if v.skeletal<SKELETAL_DEPRECATE_SECTION_DISABLED {_=bool_read(r,"section legacy clothing")}
        if v.skeletal<SKELETAL_REMOVE_DUPLICATED_CLOTHING {_=take(r,2,"section cloth section")}
    }
    if v.ue4>=UE4_APEX_CLOTH_LOD && v.skeletal<SKELETAL_REMOVE_ENABLE_CLOTH_LOD {_=u8_read(r,"section cloth LOD")}
    if v.recompute_tangent>=RECOMPUTE_TANGENT_RUNTIME {_=bool_read(r,"section recompute tangent")}
    if v.recompute_tangent>=RECOMPUTE_TANGENT_VERTEX_MASK {_=u8_read(r,"section recompute tangent mask")}
    if v.editor>=EDITOR_REFACTOR_MESH_EDITOR_MATERIALS {_=bool_read(r,"section cast shadow")}
    if v.main>=MAIN_RAY_TRACING_SECTION_FLAG {_=bool_read(r,"section visible in ray tracing")}
    s.first_vertex=int(u32_read(r,"section first vertex"))
    s.vertex_count=count_read(r,layout.size,"section soft vertex count")
    s.vertices=take(r,s.vertex_count*layout.size,"section soft vertices")
    if v.anim>=ANIM_BONE_INDEX_LIMIT_PER_CHUNK {_=bool_read(r,"section 16-bit bone indices")}
    bones:=count_read(r,2,"section bone map count")
    s.bone_map=take(r,bones*2,"section bone map")
    if int(i32_read(r,"section vertex count"))!=s.vertex_count && !failed(r) {bad(r,.Malformed,"section vertex count disagrees with its soft vertices");return}
    _=i32_read(r,"section max bone influences")
    if v.main_release<MAIN_RELEASE_CLOTH_LOD_BIAS {
        array_skip(r,CLOTH_MAPPING_BYTES,"section cloth mapping")
    } else {
        lods:=count_read(r,4,"section cloth mapping LOD count")
        for _ in 0..<lods {array_skip(r,CLOTH_MAPPING_BYTES,"section cloth mapping");if failed(r) {return}}
    }
    if v.skeletal<SKELETAL_REMOVE_DUPLICATED_CLOTHING {
        vector:=v.ue5>=UE5_LARGE_WORLD_COORDINATES?24:12
        array_skip(r,vector,"section cloth positions")
        array_skip(r,vector,"section cloth normals")
    }
    _=take(r,2,"section cloth asset")
    clothing:=take(r,CLOTHING_DATA_BYTES,"section clothing data")
    if len(clothing)==CLOTHING_DATA_BYTES {
        guid:=false
        for b in clothing[:16] {guid||=b!=0}
        s.cloth=guid && transmute(i32)u32_at(clothing,16)!= -1
    }
    if v.overlapping>=OVERLAPPING_DETECT {
        entries:=count_read(r,8,"section overlapping vertex count")
        for _ in 0..<entries {
            _=i32_read(r,"section overlapping vertex")
            array_skip(r,4,"section overlapping vertices")
            if failed(r) {return}
        }
    }
    if v.release>=RELEASE_SECTION_DISABLE {s.disabled=bool_read(r,"section disabled")}
    if v.skeletal>=SKELETAL_SECTION_IGNORE_BY_REDUCE {_=i32_read(r,"section generate up to LOD")}
    if v.editor>=EDITOR_SKELETAL_MESH_BUILD_REFACTOR {_=take(r,8,"section original and parent sections")}
}

// Decodes LOD 0 of a mesh skeletal_read found: the LOD model of the native
// tail, or the mesh description built as Unreal builds it, with the normals
// it makes and the materials it gives each section, keeping the influences
// the project allows (skin_project_read). Oodle needs a decoder.
skeletal_decode :: proc(p:^unreal.Package,mesh:^Skeletal_Mesh,decoder:^kraken.Decoder=nil,allocator:=context.allocator,scratch:=context.temp_allocator,project:=SKIN_PROJECT_DEFAULTS) -> (out:Skinned_Mesh,error:unreal.Error) {
    if p==nil || mesh==nil {return {},{.Invalid_Reference,0,"skeletal decode"}}
    v:=versions_of(p)
    switch mesh.layout {
    case .Lod_Model:
        m:Lod_Model
        m,error=lod_model_read(p,v,mesh.model,scratch)
        if error.code!=.None {return}
        error=lod_model_build(&m,mesh,mesh.model.offset,&out,allocator,scratch)
        if error.code!=.None || len(mesh.morph_targets)==0 {return}
        // The targets move rows of the vertices of the LOD model, which are the positions.
        out.morphs=make([]Morph_Target,len(mesh.morph_targets),allocator)
        for object,i in mesh.morph_targets {
            out.morphs[i],error=morph_target_read(p,v,object,len(out.positions),allocator)
            if error.code!=.None {skinned_mesh_destroy(&out);return}
        }
        out.corner_morph=slice.clone(out.corner_vertex,allocator)
    case .Mesh_Description:
        error=skeletal_description_build(p,v,mesh,project,decoder,&out,allocator,scratch)
    }
    return
}

// The sections Unreal draws, their triangles over the soft vertices and the
// influences of each vertex through the bone map of its section.
@(private)
lod_model_build :: proc(m:^Lod_Model,mesh:^Skeletal_Mesh,base:i64,out:^Skinned_Mesh,allocator,scratch:mem.Allocator) -> (error:unreal.Error) {
    s:=m.vertex
    total:=0
    for section in m.sections {
        if section.first_vertex!=total {return {.Malformed,base,"LOD model sections do not follow each other in its vertices"}}
        total+=section.vertex_count
    }
    // Rows of the vertices in scratch; what leaves is made at the end, in allocator.
    positions:=make([][3]f32,total,scratch)
    normals:=make([][3]f32,total,scratch)
    tangents:=make([][4]f32,total,scratch)
    uvs:=make([][LOD_UVS][2]f32,total,scratch)
    colors:=make([][4]u8,total,scratch)
    skin_first:=make([]u32,total+1,scratch)
    influences:=make([dynamic]Influence,scratch)
    white:=true
    for section in m.sections {
        bones:=len(section.bone_map)/2
        for local in 0..<section.vertex_count {
            row:=section.first_vertex+local
            data:=section.vertices[local*s.size:][:s.size]
            positions[row]={f32_at(data,0),f32_at(data,4),f32_at(data,8)}
            x:=[3]f32{f32_at(data,SOFT_TANGENT_X),f32_at(data,SOFT_TANGENT_X+4),f32_at(data,SOFT_TANGENT_X+8)}
            y:=[3]f32{f32_at(data,SOFT_TANGENT_X+12),f32_at(data,SOFT_TANGENT_X+16),f32_at(data,SOFT_TANGENT_X+20)}
            z:=[4]f32{f32_at(data,SOFT_TANGENT_Z),f32_at(data,SOFT_TANGENT_Z+4),f32_at(data,SOFT_TANGENT_Z+8),f32_at(data,SOFT_TANGENT_Z+12)}
            if !finite(positions[row]) {return {.Malformed,base,"LOD model has a position that is not finite"}}
            normals[row]=z.xyz
            // TangentZ.W is the sign of the binormal; a zero one is that of the basis.
            sign:=z.w
            if sign==0 {sign=linalg.dot(linalg.cross(z.xyz,x),y)}
            tangents[row]={x.x,x.y,x.z,sign<0?-1:1}
            for channel in 0..<LOD_UVS {uvs[row][channel]={f32_at(data,SOFT_UVS+channel*8),f32_at(data,SOFT_UVS+channel*8+4)}}
            bgra:=data[SOFT_COLOR:][:4]
            colors[row]={bgra[2],bgra[1],bgra[0],bgra[3]}
            white&&=colors[row]=={255,255,255,255}
            skin_first[row]=u32(len(influences))
            for k in 0..<min(s.bone_count,s.weight_count) {
                raw:u32
                // A weight of 8 bits scales to 16 as SoftSkinVertex loads it.
                if s.weight_size==2 {raw=u32(data[s.weights+k*2])|u32(data[s.weights+k*2+1])<<8} else {raw=u32(data[s.weights+k])*0x101}
                if raw==0 {continue}
                local_bone:=int(data[s.bones+k*s.bone_size])
                if s.bone_size==2 {local_bone|=int(data[s.bones+k*2+1])<<8}
                if local_bone>=bones {return {.Malformed,base,"LOD model vertex names a bone its section does not map"}}
                bone:=int(section.bone_map[local_bone*2])|int(section.bone_map[local_bone*2+1])<<8
                if bone>=len(mesh.bones) {return {.Malformed,base,"LOD model section maps a bone the reference skeleton does not have"}}
                append(&influences,Influence{u16(bone),f32(raw)/RAW_WEIGHT_ONE})
            }
        }
    }
    skin_first[total]=u32(len(influences))

    corners:=make([dynamic]u32,scratch)
    triangle_section:=make([dynamic]u32,scratch)
    sections:=make([dynamic]Section,scratch)
    left_out,cloth:=0,0
    for section,i in m.sections {
        if section.disabled {left_out+=1;continue}
        if section.cloth {cloth+=1}
        if section.triangles==0 {continue}
        material:=section.material
        if i<len(mesh.section_materials) && mesh.section_materials[i]>=0 {material=int(mesh.section_materials[i])}
        if material>=len(mesh.materials) {material= -1}
        name:=""
        if material>=0 {name=mesh.materials[material].imported_name}
        append(&sections,Section{name=name,material=material})
        if section.first_index+section.triangles*3>m.index_count {return {.Malformed,base,"LOD model section reads past its index buffer"}}
        for at in section.first_index..<section.first_index+section.triangles*3 {
            vertex:=int(u32_at(m.indices,at*4))
            if vertex<section.first_vertex || vertex>=section.first_vertex+section.vertex_count {return {.Malformed,base,"LOD model section names a vertex of another section"}}
            append(&corners,u32(vertex))
        }
        for _ in 0..<section.triangles {append(&triangle_section,u32(len(sections)-1))}
    }
    if len(triangle_section)==0 {return {.Unsupported_Value,base,"LOD 0 draws no triangle"}}

    out^={}
    out.allocator=allocator
    out.left_out,out.cloth=left_out,cloth
    out.positions=slice.clone(positions,allocator)
    out.skin_first=slice.clone(skin_first,allocator)
    out.influences=slice.clone(influences[:],allocator)
    out.corner_vertex=slice.clone(corners[:],allocator)
    out.triangle_section=slice.clone(triangle_section[:],allocator)
    out.sections=make([]Section,len(sections),allocator)
    for section,i in sections {out.sections[i]={clone(section.name,allocator),section.material}}
    count:=len(corners)
    out.corner_normal=make([][3]f32,count,allocator)
    out.corner_tangent=make([][4]f32,count,allocator)
    out.uv_count=m.uv_count
    for channel in 0..<out.uv_count {out.corner_uvs[channel]=make([][2]f32,count,allocator)}
    if !white {out.corner_color=make([][4]u8,count,allocator)}
    for vertex,corner in corners {
        n:=normals[vertex]
        length:=linalg.length(n)
        if length>1e-4 && finite(n) {n/=length} else {
            first:=corner-corner%3
            n=linalg.normalize(face_normal(positions[corners[first]],positions[corners[first+1]],positions[corners[first+2]]))
            if !finite(n) {n={0,0,1}}
        }
        out.corner_normal[corner]=n
        t:=tangents[vertex]
        t_length:=linalg.length(t.xyz)
        if t_length>1e-4 && finite(t.xyz) {out.corner_tangent[corner]={t.x/t_length,t.y/t_length,t.z/t_length,t.w}}
        for channel in 0..<out.uv_count {out.corner_uvs[channel][corner]=uvs[vertex][channel]}
        if !white {out.corner_color[corner]=colors[vertex]}
    }
    bounds_of(&out.geometry)
    return
}

// A UE 5.4 source model: the MeshDescription with its SkinWeights, built as
// Unreal's skeletal build makes its LOD model: the normals of a static mesh
// description, the colors without sRGB, the influences limited and
// renormalized, the corners welded within the thresholds of the build
// settings, and the sections of the build: one per polygon group, the
// material whose imported slot name is that of the group, LODMaterialMap
// over it.
// Only triangles without area leave before the welding: the skeletal build
// keeps the rest, bRemoveDegenerates or not.
@(private)
skeletal_description_build :: proc(p:^unreal.Package,v:Versions,mesh:^Skeletal_Mesh,project:Skin_Project,decoder:^kraken.Decoder,out:^Skinned_Mesh,allocator,scratch:mem.Allocator) -> (error:unreal.Error) {
    bytes,owned:[]u8
    bytes,owned,error=payload_bytes(p,mesh.payload,decoder,allocator)
    if error.code!=.None {return}
    defer delete(owned,allocator)
    base:=mesh.payload.span.offset
    t:Topology
    t,error=description_read(bytes,v,base,scratch)
    if error.code!=.None {return}
    weights:=attribute_find(&t.vertices,.Int,"SkinWeights")
    if weights==nil || weights.extent!=0 {return {.Malformed,base,"skeletal mesh description has no skin weights"}}
    g:=gather_make(allocator,scratch)
    defer if error.code!=.None {gather_destroy(&g)}
    error=description_gather(&t,v,&g,scratch,base)
    if error.code!=.None {return}

    skin_colors(&t,v,&g)
    skin,inside:=skin_rows_make(weights,v,len(g.positions),len(mesh.bones),mesh.weld,project,scratch)
    if !inside {return {.Malformed,base,"skin weights of a vertex leave their chunk"}}

    degenerate:=degenerates_remove(&g,{},scratch)
    if len(g.triangle_section)==0 {return {.Unsupported_Value,base,"the source model has no triangle with area"}}
    normals_make(&g,mesh.build,scratch)
    // The material of each polygon group by its imported slot name; when the
    // first group names none, the groups keep their own numbers, as in Unreal.
    groups:=len(g.sections)
    remap:=make([]int,groups,scratch)
    for &value,i in remap {value=i}
    if !(len(mesh.materials)<=1 && groups<=1) {
        found:=false
        apply:=true
        for section,i in g.sections {
            for slot,m in mesh.materials {
                if section.name!="" && strings.equal_fold(slot.imported_name,section.name) {remap[i]=m;found=true;break}
            }
            if !found {apply=false;break}
        }
        if !apply {for &value,i in remap {value=i}}
    }
    degenerate+=corners_weld(&g,remap,&skin,mesh.weld,scratch)
    if len(g.triangle_section)==0 {return {.Unsupported_Value,base,"the source model has no triangle with area"}}
    // Sections of the build follow their materials: LODMaterialMap is by that order.
    order:=slice.clone(remap,scratch)
    slice.sort(order)
    order=slice.unique(order)
    // The sections the user disabled, by their index in the import: the rank of their material.
    lod,lod_error:=lod_model_read(p,v,mesh.model,scratch)
    disabled:=make([]bool,len(g.sections),scratch)
    for &section,i in g.sections {
        material:=remap[i]
        rank,_:=slice.binary_search(order,material)
        if lod_error.code==.None {disabled[i]=slice.contains(lod.disabled_sources,i32(rank))}
        if rank<len(mesh.section_materials) && mesh.section_materials[rank]>=0 {material=int(mesh.section_materials[rank])}
        section.material=material<len(mesh.materials)?material:-1
    }
    left_out:=0
    for value in disabled {if value {left_out+=1}}
    if left_out>0 {
        keep:=make([]bool,len(g.triangle_section),scratch)
        for &kept,triangle in keep {kept=!disabled[g.triangle_section[triangle]]}
        triangles_keep(&g,keep)
        if len(g.triangle_section)==0 {return {.Unsupported_Value,base,"LOD 0 draws no triangle"}}
        // The sections left, in their order, as the LOD model has them.
        row:=make([]u32,len(g.sections),scratch)
        kept:=0
        for section,i in g.sections {
            if disabled[i] {delete(section.name,g.allocator);continue}
            row[i]=u32(kept)
            g.sections[kept]=section
            kept+=1
        }
        resize(&g.sections,kept)
        for &section in g.triangle_section {section=row[section]}
    }
    out^={}
    out.degenerate=degenerate
    out.left_out=left_out
    out.morphs=description_morphs(&t,v,g.corner_instance[:],allocator)
    if len(out.morphs)>0 {out.corner_morph=slice.clone(g.corner_instance[:],allocator)}
    gather_finish(&g,&out.geometry)
    out.skin_first,out.influences=skin_rows_influences(&skin,len(out.positions),allocator)
    return
}
