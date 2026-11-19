package uasset

import material "project:plugins/unreal/editor/material"
import umesh "project:plugins/unreal/editor/mesh"

// Mirai's foliage flutters its leaves by the green of their vertex colors.
// Unreal flutters them by the offset of the material of their section, so a
// mesh whose sections flutter apart (leaves over a trunk) carries the green
// of each: those whose material does not flutter take none. Only a section
// shown by a program does, which reads its colors as data: the base color of
// the others is multiplied by them.

OFFSET_VERTICES :: 32 // of each section of a mesh, at most, an offset is measured at

// Up to OFFSET_VERTICES vertices of the sections of a mesh that show the
// material of a slot, spread over them, the highest among them: where the
// offset of its material is measured (material.offset_read).
offset_vertices :: proc(m:^umesh.Mesh,slot:int,allocator:=context.temp_allocator) -> []material.Offset_Vertex {
    corners:=make([dynamic]int,context.temp_allocator)
    highest:=-1
    for section,triangle in m.triangle_section {
        if int(section)>=len(m.sections) || m.sections[section].material!=slot {continue}
        for k in 0..<3 {
            corner:=triangle*3+k
            append(&corners,corner)
            if highest<0 || m.positions[m.corner_vertex[corner]].z>m.positions[m.corner_vertex[highest]].z {highest=corner}
        }
    }
    if len(corners)==0 {return nil}
    count:=min(len(corners),OFFSET_VERTICES)
    out:=make([]material.Offset_Vertex,count,allocator)
    for &v,i in out {
        corner:=i==0?highest:corners[i*len(corners)/count]
        v.position=m.positions[m.corner_vertex[corner]]
        for set in 0..<min(m.uv_count,material.UNREAL_UV_SETS) {v.uvs[set]=m.corner_uvs[set][corner]}
        v.color={1,1,1,1}
        if len(m.corner_color)>0 {
            rgba:=m.corner_color[corner]
            v.color={f32(rgba[0]),f32(rgba[1]),f32(rgba[2]),f32(rgba[3])}/255
        }
    }
    return out
}

// Whether the leaves of each section of a mesh flutter in the wind by the
// offset of the material of its slot, with the library taken.
@(private)
sections_flutter :: proc(c:^Context,materials:[]umesh.Material_Slot,geometry:^umesh.Mesh) -> []bool {
    flutters:=make([]bool,len(geometry.sections),context.temp_allocator)
    for section,i in geometry.sections {
        if section.material<0 || section.material>=len(materials) {continue}
        object,found:=material.object_find(c.library,materials[section.material].path)
        if !found {continue}
        vertices:=offset_vertices(geometry,section.material)
        reach:=make([]material.Offset_Reach,len(vertices),context.temp_allocator)
        o,error:=material.offset_read(c.library,object,vertices,{geometry.bounds_min,geometry.bounds_max},reach,allocator=context.temp_allocator)
        flutters[i]=error.code==.None && o.kind==.Wind && material.offset_flutters(reach)
    }
    return flutters
}
