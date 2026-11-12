package mesh

import "core:mem"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// Morph targets of LOD 0 of a skeletal mesh: the MorphTarget exports its
// MorphTargets names, whose MorphTargetLODModel moves rows of the vertices of
// the LOD model, or the "Morph-" attributes of a UE 5.4 mesh description,
// which move its vertices and turn the normals of its vertex instances.

// What weight one of a target adds, in Unreal's space, to each morph vertex
// (Skinned_Mesh.corner_morph).
Morph_Target :: struct {
    name:string,
    positions:[][3]f32,
    normals:[][3]f32, // none when the target turns no normal
}

@(private) UE4_MORPH_TANGENT_Z_DELTA :: 348
@(private) EDITOR_MORPH_SECTION_INDICES :: 23
@(private) FORTNITE_MORPH_GENERATED_BY_ENGINE :: 6
@(private) FORTNITE_MORPH_CUSTOM_IMPORT :: 158
@(private) FORTNITE_MORPH_COOKED_COMPRESSED :: 211
@(private) SPECIAL_MORPH_STRIP_SOURCE :: 8
// MorphTargetDelta: PositionDelta and TangentZDelta of three floats and SourceIdx; before
// UE4_MORPH_TANGENT_Z_DELTA the tangent was an DeprecatedSerializedPackedNormal of four bytes.
@(private) MORPH_DELTA_BYTES :: 12+12+4
@(private) MORPH_DELTA_PACKED_BYTES :: 12+4+4
// The prefix of the morph target attributes of a mesh description.
@(private) MORPH_ATTRIBUTE_PREFIX :: "Morph-"

// The deltas of LOD 0 of a MorphTarget export, over vertices rows of the LOD model.
@(private)
morph_target_read :: proc(p:^unreal.Package,v:Versions,object:unreal.Object_Ref,vertices:int,allocator:mem.Allocator) -> (target:Morph_Target,error:unreal.Error) {
    if !export_of_class(p,object,"/Script/Engine","MorphTarget") {
        return {},{.Invalid_Reference,0,"morph target is not a MorphTarget export of its mesh"}
    }
    index:=int(object)-1
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&properties)
    tail:unreal.Span
    tail,error=unreal.object_native_payload(p,properties.trailing)
    if error.code!=.None {return}
    bytes,_:=unreal.span_bytes(p,tail)
    r:=reader_make(bytes,tail.offset)
    global:=u8_read(&r,"morph target strip flags")
    _=u8_read(&r,"morph target class strip flags")
    if failed(&r) {return {},r.error}
    if global&STRIP_AUDIO_VISUAL!=0 {return {},{.Cooked,tail.offset,"morph target was stripped when cooking"}}
    if v.fortnite>=FORTNITE_MORPH_COOKED_COMPRESSED && bool_read(&r,"morph target is cooked") {return {},{.Cooked,tail.offset,"morph target keeps cooked data"}}
    lods:=count_read(&r,4,"morph target LOD count")
    if failed(&r) {return {},r.error}
    deltas:[]u8
    count,size:=0,MORPH_DELTA_BYTES
    if lods>0 {
        special,_:=unreal.custom_version(p,unreal.UE5_SPECIAL_PROJECT_VERSION)
        // MorphTargetLODModel of LOD 0: Vertices first.
        if v.editor>=EDITOR_MORPH_SECTION_INDICES && v.fortnite>=FORTNITE_MORPH_GENERATED_BY_ENGINE && special>=SPECIAL_MORPH_STRIP_SOURCE {
            if bool_read(&r,"morph target vertices stripped") {return {},{.Cooked,tail.offset,"morph target vertices were stripped when cooking"}}
        }
        if v.ue4<UE4_MORPH_TANGENT_Z_DELTA {size=MORPH_DELTA_PACKED_BYTES}
        count=count_read(&r,size,"morph target delta count")
        deltas=take(&r,count*size,"morph target deltas")
        if failed(&r) {return {},r.error}
        for at in 0..<count {
            d:=deltas[at*size:][:size]
            if int(u32_at(d,size-4))>=vertices {return {},{.Malformed,tail.offset,"morph target moves a vertex its LOD model does not have"}}
            if !finite({f32_at(d,0),f32_at(d,4),f32_at(d,8)}) || size==MORPH_DELTA_BYTES && !finite({f32_at(d,12),f32_at(d,16),f32_at(d,20)}) {
                return {},{.Malformed,tail.offset,"morph target delta is not finite"}
            }
        }
    }
    target.name=unreal.name_text(p,p.exports[index].object_name,allocator)
    target.positions=make([][3]f32,vertices,allocator)
    if size==MORPH_DELTA_BYTES {target.normals=make([][3]f32,vertices,allocator)}
    for at in 0..<count {
        d:=deltas[at*size:][:size]
        row:=int(u32_at(d,size-4))
        target.positions[row]+={f32_at(d,0),f32_at(d,4),f32_at(d,8)}
        if size==MORPH_DELTA_BYTES {target.normals[row]+={f32_at(d,12),f32_at(d,16),f32_at(d,20)}}
    }
    return
}

// The morph targets of a UE 5.4 mesh description, by vertex instance: the
// delta of the position of its vertex and that of its own normal.
@(private)
description_morphs :: proc(t:^Topology,v:Versions,corner_instance:[]u32,allocator:mem.Allocator) -> (targets:[]Morph_Target) {
    out:=make([dynamic]Morph_Target,allocator)
    instance_vertex:=attribute_find(&t.instances,.Int,"VertexIndex")
    for &attribute in t.vertices.attributes {
        if attribute.type!=.Vector3 || attribute.extent!=1 || !strings.has_prefix(attribute.name,MORPH_ATTRIBUTE_PREFIX) {continue}
        normals:=attribute_find(&t.instances,.Vector3,attribute.name)
        target:=Morph_Target{name=strings.clone(attribute.name[len(MORPH_ATTRIBUTE_PREFIX):],allocator)}
        target.positions=make([][3]f32,t.instances.count,allocator)
        if normals!=nil {target.normals=make([][3]f32,t.instances.count,allocator)}
        for instance in corner_instance {
            id:=int(instance)
            vertex:=new_format(v)?int(attribute_int(instance_vertex,v,id)):int(t.instance_vertex[id])
            target.positions[id]=attribute_floats(&attribute,v,0,vertex,3)
            if normals!=nil {target.normals[id]=attribute_floats(normals,v,0,id,3)}
        }
        append(&out,target)
    }
    return out[:]
}
