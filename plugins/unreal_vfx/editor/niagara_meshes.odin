package unreal_vfx_editor

import "core:fmt"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"

// StaticMesh and SkeletalMesh: the triangles of what an entity draws, a
// surface resource of the program (mirai_vfx_surface_sample and _at) that
// the entity binds; a level binds the actor its component names
// (SoftSourceActor). A coordinate of Niagara is a triangle and the weights
// of its three corners; Mirai's keeps those of the second and third.

// The functions of the mesh data interfaces.
@(private)
niagara_mesh_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base_name:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    if di.resource=="" {return}
    ins,outs:=niagara_split(params)
    R:=di.resource
    b:=strings.builder_make(context.temp_allocator)
    switch base_name {
    case "RandomTriCoord","RandomTriangle","RandomTriCoordOnSection","RandomTriCoordUsingVertexColorFilter":
        if len(outs)<1 {return}
        coord:=outs[len(outs)-1].name
        fmt.sbprintf(&b,"    uint seed = asuint(rand(1.0f)) ^ (GLinearThreadId * 747796405u);\n    Mirai_Vfx_Surface s = mirai_vfx_surface_sample(niagara_ctx, %s, seed);\n",R)
        fmt.sbprintf(&b,"    %s.Tri = int(s.triangle);\n    %s.BaryCoord = float3(1.0 - s.barycentric.x - s.barycentric.y, s.barycentric);\n",coord,coord)
    case "GetSkinnedTriangleDataWS","GetSkinnedTriangleDataWSInterpolated","GetSkinnedTriangleData","GetSkinnedTriangleDataInterpolated","GetTriCoordPositionWS","GetTriCoordPosition":
        if len(ins)<1 {return}
        fmt.sbprintf(&b,"    Mirai_Vfx_Surface s = mirai_vfx_surface_at(niagara_ctx, %s, uint(max(%s.Tri, 0)), %s.BaryCoord.yz);\n",R,ins[0].name,ins[0].name)
        strings.write_string(&b,"    float3 n = niagara_direction(s.normal);\n    float3 t = normalize(abs(n.z) < 0.99 ? cross(float3(0.0, 0.0, 1.0), n) : cross(float3(1.0, 0.0, 0.0), n));\n")
        for out in outs {
            value:=""
            switch niagara_channel_parameter(out.name) {
            case "Position": value="niagara_point(s.position)"
            case "Velocity": value="niagara_vector(s.velocity)"
            case "Normal": value="n"
            case "Tangent": value="t"
            case "Binormal","Bitangent": value="cross(n, t)"
            case: value=fmt.tprintf("(%s)0",strings.trim_prefix(out.type,"out "))
            }
            fmt.sbprintf(&b,"    %s = %s;\n",out.name,value)
        }
    case "GetTriUV","GetTriCoordUV":
        if len(ins)<1 || len(outs)<1 {return}
        fmt.sbprintf(&b,"    Mirai_Vfx_Surface s = mirai_vfx_surface_at(niagara_ctx, %s, uint(max(%s.Tri, 0)), %s.BaryCoord.yz);\n    %s = s.uv;\n",R,ins[0].name,ins[0].name,outs[len(outs)-1].name)
    case "GetTriColor","GetTriCoordColor":
        // Mirai's surfaces keep no colors of their vertices.
        if len(outs)<1 {return}
        fmt.sbprintf(&b,"    %s = float4(1.0, 1.0, 1.0, 1.0);\n",outs[len(outs)-1].name)
    case "IsValidTriCoord","IsValid":
        if len(outs)<1 {return}
        fmt.sbprintf(&b,"    %s = true;\n",outs[0].name)
    case:
        return
    }
    return strings.to_string(b),true
}

// The actor the mesh data interfaces of a level component name: the label of
// the actor of the soft path of their SoftSourceActor; "" none.
@(private)
niagara_mesh_actor :: proc(d:^level.Document,component:level.Ref) -> string {
    p:=level.library_package(d.library,int(component.pkg))
    for export,i in p.exports {
        if export.outer!=component.object {continue}
        other:=level.Ref{component.pkg,unreal.Object_Ref(i+1)}
        class:=class_name(d,other)
        if class!="NiagaraDataInterfaceSkeletalMesh" && class!="NiagaraDataInterfaceStaticMesh" {continue}
        f,error:=level.property(d,other,"SoftSourceActor")
        if error.code!=.None || f.property==nil {continue}
        path,path_error:=unreal.soft_path_property(f.pkg,f.property)
        if path_error.code!=.None || path=="" {continue}
        return path[strings.last_index_byte(path,'.')+1:]
    }
    return ""
}

// MeshRendererInfo: the bounds of the first mesh of the mesh renderer it
// names, from the ExtendedBounds of the StaticMesh (centimetres); a sphere of
// a metre without them.
@(private)
niagara_renderer_bounds :: proc(d:^level.Document,di:^Niagara_Di) -> (low,high:[3]f32) {
    low,high={-50,-50,-50},{50,50,50}
    if !di.found {return}
    f,error:=level.property(d,di.object,"MeshRenderer")
    if error.code!=.None || f.property==nil {return}
    renderer,found:=object_resolve(d,di.object,value_object(f.pkg,f.property))
    if !found {return}
    m,m_error:=level.property(d,renderer,"Meshes")
    if m_error.code!=.None || m.property==nil {return}
    view,view_error:=unreal.property_array(m.pkg,m.property)
    if view_error.code!=.None {return}
    meshes,meshes_error:=unreal.array_tagged_structs(m.pkg,view,true,context.temp_allocator)
    if meshes_error.code!=.None || len(meshes.items)==0 {return}
    mesh,mesh_found:=object_resolve(d,renderer,value_object(m.pkg,unreal.property_find(m.pkg,&meshes.items[0],"Mesh")))
    if !mesh_found {return}
    bounds:=struct_at(d,mesh,"ExtendedBounds")
    origin,extent:[3]f32
    for name,i in ([2]string{"Origin","BoxExtent"}) {
        value,value_error:=unreal.property_value(bounds.p,struct_field(&bounds,name),context.temp_allocator)
        if value_error.code!=.None || value.kind!=.Real_Vector {return}
        for axis in 0..<3 {
            if i==0 {origin[axis]=f32(value.vector[axis])} else {extent[axis]=f32(value.vector[axis])}
        }
    }
    return origin-extent,origin+extent
}

@(private)
niagara_renderer_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base_name:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    if base_name!="GetMeshLocalBounds" {return}
    _,outs:=niagara_split(params)
    if len(outs)<2 {return}
    low,high:=niagara_renderer_bounds(w.d,di)
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"    %s = float3(%v, %v, %v);\n    %s = float3(%v, %v, %v);\n",outs[0].name,low.x,low.y,low.z,outs[1].name,high.x,high.y,high.z)
    if len(outs)>2 {fmt.sbprintf(&b,"    %s = float3(%v, %v, %v);\n",outs[2].name,high.x-low.x,high.y-low.y,high.z-low.z)}
    return strings.to_string(b),true
}
