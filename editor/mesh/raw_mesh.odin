package mesh

import "core:mem"
import "core:slice"
import unreal "project:plugins/unreal/editor/package"

// RawMesh, the source model of saves before MeshDescription: arrays by face,
// by vertex and by wedge (a corner of a face), with smoothing groups.

@(private) RAW_MESH_COMPACTED :: 1

@(private)
Raw_Array :: struct {count:int,data:[]u8}

@(private)
raw_array_read :: proc(r:^Reader,size:int,field:string) -> (a:Raw_Array) {
    a.count=count_read(r,size,field)
    a.data=take(r,a.count*size,field)
    return
}

@(private)
raw_mesh_read :: proc(bytes:[]u8,base:i64,mesh:^Static_Mesh,g:^Gather,scratch:mem.Allocator) -> unreal.Error {
    r:=reader_make(bytes,base)
    version:=i32_read(&r,"raw mesh version")
    _=i32_read(&r,"raw mesh licensee version")
    materials:=raw_array_read(&r,4,"raw mesh face materials")
    smoothing:=raw_array_read(&r,4,"raw mesh smoothing masks")
    positions:=raw_array_read(&r,12,"raw mesh positions")
    wedges:=raw_array_read(&r,4,"raw mesh wedge indices")
    tangent_x:=raw_array_read(&r,12,"raw mesh tangents")
    tangent_y:=raw_array_read(&r,12,"raw mesh binormals")
    tangent_z:=raw_array_read(&r,12,"raw mesh normals")
    uvs:[MAX_UVS]Raw_Array
    for &uv in uvs {uv=raw_array_read(&r,8,"raw mesh texture coordinates")}
    colors:=raw_array_read(&r,4,"raw mesh colors")
    if version>=RAW_MESH_COMPACTED {_=raw_array_read(&r,4,"raw mesh material import indices")}
    if failed(&r) {return r.error}
    if r.at!=len(bytes) {return {.Malformed,base+i64(r.at),"raw mesh has trailing bytes"}}

    corners:=wedges.count
    faces:=corners/3
    sized :: proc(a:Raw_Array,count:int) -> bool {return a.count==0 || a.count==count}
    // A valid raw mesh: every face with its material and smoothing, every wedge with UV 0.
    if corners==0 || corners%3!=0 || positions.count==0 || materials.count!=faces || smoothing.count!=faces || uvs[0].count!=corners ||
       !sized(tangent_x,corners) || !sized(tangent_y,corners) || !sized(tangent_z,corners) || !sized(colors,corners) {
        return {.Malformed,base,"raw mesh arrays do not match its faces and wedges"}
    }
    for uv in uvs[1:] {if !sized(uv,corners) {return {.Malformed,base,"raw mesh texture coordinates do not match its wedges"}}}

    face_material:=make([]i32,faces,scratch)
    for &material,face in face_material {material=transmute(i32)u32_at(materials.data,face*4)}
    if version<RAW_MESH_COMPACTED {
        // The materials faces use, in order, numbered from 0.
        used:=slice.clone(face_material,scratch)
        slice.sort(used)
        unique:=slice.unique(used)
        for &material in face_material {
            at,_:=slice.binary_search(unique,material)
            material=i32(at)
        }
    }

    g.smoothing=make([]u32,faces,scratch)
    for &mask,face in g.smoothing {mask=u32_at(smoothing.data,face*4)}
    resize(&g.positions,positions.count)
    for &p,i in g.positions {p=vector3_at(positions.data,i)}
    g.uv_count=0
    for uv in uvs {if uv.count==corners {g.uv_count+=1}}
    gather_corners(g,corners,colors.count>0)

    // One polygon group per material, in the order faces first use them, named as Unreal names them.
    group_of:=make(map[i32]u32,scratch)
    for material in face_material {
        if material in group_of {continue}
        group_of[material]=u32(len(g.sections))
        name:string
        if material>=0 && int(material)<len(mesh.materials) {name=mesh.materials[material].imported_name}
        if name=="" {name=name_slot(int(material),g.allocator)} else {name=clone(name,g.allocator)}
        append(&g.group_ids,i32(len(g.sections)))
        append(&g.sections,Section{name=name})
    }
    resize(&g.triangle_section,faces)
    for material,face in face_material {g.triangle_section[face]=group_of[material]}
    for corner in 0..<corners {
        vertex:=u32_at(wedges.data,corner*4)
        if int(vertex)>=positions.count {return {.Malformed,base,"raw mesh wedge names a vertex it does not have"}}
        g.corner_vertex[corner]=vertex
        if tangent_z.count>0 {g.normal[corner]=vector3_at(tangent_z.data,corner)}
        if tangent_x.count>0 && tangent_y.count>0 {
            x,y,z:=vector3_at(tangent_x.data,corner),vector3_at(tangent_y.data,corner),g.normal[corner]
            // The sign of the determinant of the basis.
            determinant:=x.x*(y.y*z.z-y.z*z.y)-x.y*(y.x*z.z-y.z*z.x)+x.z*(y.x*z.y-y.y*z.x)
            g.tangent[corner]={x.x,x.y,x.z,determinant<0?-1:1}
        }
        if colors.count>0 {
            bgra:=colors.data[corner*4:][:4]
            g.color[corner]={bgra[2],bgra[1],bgra[0],bgra[3]}
        }
        channel:=0
        for uv in uvs {
            if uv.count!=corners {continue}
            g.uvs[channel][corner]={f32_at(uv.data,corner*8),f32_at(uv.data,corner*8+4)}
            channel+=1
        }
    }
    return {}
}

@(private)
vector3_at :: #force_inline proc "contextless" (data:[]u8,index:int) -> [3]f32 {
    return {f32_at(data,index*12),f32_at(data,index*12+4),f32_at(data,index*12+8)}
}
