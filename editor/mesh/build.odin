package mesh

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strings"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"
import mirai_base "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/jobs"
import mm "mirai:std/math"

// A source model as the build of Unreal draws it, in Unreal's space with the
// build scale applied. Three corners per triangle, in Unreal's order: seen
// from the front, cross(c2 - c0, c1 - c0) points out of the triangle.
Mesh :: struct {
    positions:[][3]f32,
    corner_vertex:[]u32,             // row of positions
    corner_normal:[][3]f32,          // unit length
    corner_tangent:[][4]f32,         // xyz along u, w the binormal sign; zero where Unreal makes a MikkTSpace one
    corner_color:[][4]u8,            // RGBA as the vertex buffer of Unreal holds it; empty when every corner is white
    corner_uvs:[MAX_UVS][][2]f32,    // the first uv_count, v from the top of the image
    uv_count:int,
    triangle_section:[]u32,
    sections:[]Section,              // one per polygon group, in the order of the build
    degenerate:int,                  // triangles the build leaves out: corners at one point or no area
    bounds_min,bounds_max:[3]f32,
    allocator:mem.Allocator,
}

Section :: struct {
    name:string,  // ImportedMaterialSlotName of its polygon group
    material:int, // row of Static_Mesh.materials, -1 for the default material
}

mesh_destroy :: proc(mesh:^Mesh) {
    if mesh==nil || mesh.allocator.procedure==nil {return}
    a:=mesh.allocator
    delete(mesh.positions,a);delete(mesh.corner_vertex,a);delete(mesh.corner_normal,a);delete(mesh.corner_tangent,a)
    delete(mesh.corner_color,a);delete(mesh.triangle_section,a)
    for uv in mesh.corner_uvs {delete(uv,a)}
    for section in mesh.sections {delete(section.name,a)}
    delete(mesh.sections,a)
    mesh^={}
}

// Corners closer than this are one point when the build removes degenerates.
DEGENERATE_DISTANCE :: 0.00002

// What a source model is being made of, rows growing in allocator; the
// smoothing data lives in scratch.
@(private)
Gather :: struct {
    allocator:mem.Allocator,
    positions:[dynamic][3]f32,
    corner_vertex:[dynamic]u32,
    corner_instance:[dynamic]u32, // MeshDescription: the vertex instance of each corner
    normal:[dynamic][3]f32,
    tangent:[dynamic][4]f32,
    color:[dynamic][4]u8,
    uvs:[MAX_UVS][dynamic][2]f32,
    uv_count:int,
    triangle_section:[dynamic]u32,
    sections:[dynamic]Section,
    group_ids:[dynamic]i32,  // of each section: the polygon group, the material of the build when no slot has its name
    smoothing:[]u32,         // RawMesh: the smoothing groups of each triangle
    hard:map[[2]u32]bool,    // MeshDescription: the hard edges, by their vertices
}

@(private)
gather_corners :: proc(g:^Gather,corners:int,colors:bool) {
    resize(&g.corner_vertex,corners)
    resize(&g.normal,corners)
    resize(&g.tangent,corners)
    if colors {resize(&g.color,corners)}
    for channel in 0..<g.uv_count {resize(&g.uvs[channel],corners)}
}

// Decodes the payload mesh_read found and builds it as Unreal does: the
// polygon groups as sections with the materials of the section info, the
// degenerate triangles left out, smooth normals where the source asks for
// them or has none, the tangents Unreal keeps, the build scale. Oodle needs a
// decoder; one serves any number of meshes.
mesh_decode :: proc(p:^unreal.Package,mesh:^Static_Mesh,decoder:^kraken.Decoder=nil,allocator:=context.allocator,scratch:=context.temp_allocator,worker:=jobs.Worker_Ref{}) -> (out:Mesh,error:unreal.Error) {
    if p==nil || mesh==nil {return {},{.Invalid_Reference,0,"mesh decode"}}
    bytes,owned:[]u8
    payload_zone:=jobs.worker_zone_begin(worker,"unreal.payload")
    bytes,owned,error=payload_bytes(p,mesh.payload,decoder,allocator)
    mirai_base.profile_end(payload_zone)
    if error.code!=.None {return}
    defer delete(owned,allocator)
    v:=versions_of(p)
    g:=gather_make(allocator,scratch)
    defer if error.code!=.None {gather_destroy(&g)}
    base:=mesh.payload.span.offset
    read_zone:=jobs.worker_zone_begin(worker,"unreal.mesh.description")
    switch mesh.layout {
    case .Raw_Mesh:
        error=raw_mesh_read(bytes,base,mesh,&g,scratch)
    case .Mesh_Description:
        t:Topology
        t,error=description_read(bytes,v,base,scratch)
        if error.code==.None {error=description_gather(&t,v,&g,scratch,base)}
    }
    mirai_base.profile_end(read_zone)
    if error.code!=.None {return}
    normals_zone:=jobs.worker_zone_begin(worker,"unreal.mesh.normals")
    defer mirai_base.profile_end(normals_zone)
    out.degenerate=degenerates_remove(&g,mesh.build,scratch)
    if len(g.triangle_section)==0 {error={.Unsupported_Value,base,"the source model has no triangle with area"};return}
    normals_make(&g,mesh.build,scratch)
    build_scale(&g,mesh.build)
    sections_resolve(&g,mesh)
    gather_finish(&g,&out)
    return
}

@(private)
gather_make :: proc(allocator,scratch:mem.Allocator) -> (g:Gather) {
    g.allocator=allocator
    g.positions.allocator=allocator;g.corner_vertex.allocator=allocator;g.normal.allocator=allocator
    g.tangent.allocator=allocator;g.color.allocator=allocator;g.triangle_section.allocator=allocator
    g.sections.allocator=allocator;g.group_ids.allocator=scratch;g.hard.allocator=scratch;g.corner_instance.allocator=scratch
    for &uv in g.uvs {uv.allocator=allocator}
    return
}

// The mesh of what was gathered, which takes its rows; colors leave when every corner is white.
@(private)
gather_finish :: proc(g:^Gather,out:^Mesh) {
    white:=true
    for c in g.color {white&&=c=={255,255,255,255}}
    if white {delete(g.color);g.color={}}
    out.positions,out.corner_vertex,out.corner_normal,out.corner_tangent=g.positions[:],g.corner_vertex[:],g.normal[:],g.tangent[:]
    out.corner_color,out.triangle_section,out.sections=g.color[:],g.triangle_section[:],g.sections[:]
    for channel in 0..<g.uv_count {out.corner_uvs[channel]=g.uvs[channel][:]}
    out.uv_count=g.uv_count
    out.allocator=g.allocator
    bounds_of(out)
}

// The bounds of the corners of a mesh.
@(private)
bounds_of :: proc(m:^Mesh) {
    m.bounds_min,m.bounds_max={max(f32),max(f32),max(f32)},{min(f32),min(f32),min(f32)}
    for vertex in m.corner_vertex {
        m.bounds_min=linalg.min(m.bounds_min,m.positions[vertex])
        m.bounds_max=linalg.max(m.bounds_max,m.positions[vertex])
    }
}

@(private)
gather_destroy :: proc(g:^Gather) {
    delete(g.positions);delete(g.corner_vertex);delete(g.normal);delete(g.tangent);delete(g.color);delete(g.triangle_section)
    for uv in g.uvs {delete(uv)}
    for section in g.sections {delete(section.name,g.allocator)}
    delete(g.sections)
}

@(private)
description_gather :: proc(t:^Topology,v:Versions,g:^Gather,scratch:mem.Allocator,base:i64) -> unreal.Error {
    positions:=attribute_find(&t.vertices,.Vector3,"Position ","Position")
    if positions==nil || positions.extent!=1 {return {.Malformed,base,"mesh description has no vertex positions"}}
    resize(&g.positions,t.vertices.count)
    for &p,id in g.positions {p=attribute_floats(positions,v,0,id,3)}
    for p in g.positions {if !finite(p) {return {.Malformed,base,"mesh description has a position that is not finite"}}}

    normals:=attribute_find(&t.instances,.Vector3,"Normal")
    tangents:=attribute_find(&t.instances,.Vector3,"Tangent")
    signs:=attribute_find(&t.instances,.Float,"BinormalSign")
    colors:=attribute_find(&t.instances,.Vector4,"Color")
    uvs:=attribute_find(&t.instances,.Vector2,"TextureCoordinate")
    instance_vertex:=attribute_find(&t.instances,.Int,"VertexIndex")
    if uvs!=nil {g.uv_count=min(len(uvs.channels),MAX_UVS)}

    // Polygon groups in the order of their ids: the sections of the build.
    names:=attribute_find(&t.groups,.Name,"ImportedMaterialSlotName")
    section_of:=make([]i32,t.groups.count,scratch)
    for id in 0..<t.groups.count {
        section_of[id]= -1
        if !id_used(t.groups.words,t.groups.count,id) {continue}
        section_of[id]=i32(len(g.sections))
        append(&g.sections,Section{name=clone(attribute_name(names,id),g.allocator)})
        append(&g.group_ids,i32(id))
    }

    triangles:[dynamic][3]i32
    triangles.allocator=scratch
    triangle_groups:[dynamic]i32
    triangle_groups.allocator=scratch
    if new_format(v) {
        corners:=attribute_find(&t.triangles,.Int,"VertexInstanceIndex")
        groups:=attribute_find(&t.triangles,.Int,"PolygonGroupIndex")
        if corners==nil || corners.extent!=3 || groups==nil {return {.Malformed,base,"mesh description has no triangle topology"}}
        for id in 0..<t.triangles.count {
            if !id_used(t.triangles.words,t.triangles.count,id) {continue}
            append(&triangles,[3]i32{attribute_int(corners,v,id,0),attribute_int(corners,v,id,1),attribute_int(corners,v,id,2)})
            append(&triangle_groups,attribute_int(groups,v,id))
        }
    } else if v.editor<EDITOR_TRIANGLES {
        for instances,polygon in t.polygon_instances {
            if !id_used(t.polygons.words,t.polygons.count,polygon) {continue}
            if len(instances)<3*4 {return {.Malformed,base,"mesh description polygon has fewer than three corners"}}
            polygon_fan(instances,t.polygon_group[polygon],&triangles,&triangle_groups)
        }
    } else {
        for polygon,i in t.triangle_polygon {
            if polygon<0 || int(polygon)>=len(t.polygon_group) {return {.Malformed,base,"mesh description triangle names a polygon it does not have"}}
            append(&triangles,t.triangle_corners[i])
            append(&triangle_groups,t.polygon_group[polygon])
        }
    }

    gather_corners(g,len(triangles)*3,colors!=nil)
    resize(&g.corner_instance,len(triangles)*3)
    resize(&g.triangle_section,len(triangles))
    for corners,triangle in triangles {
        group:=triangle_groups[triangle]
        if group<0 || int(group)>=len(section_of) || section_of[group]<0 {return {.Malformed,base,"mesh description triangle names a polygon group it does not have"}}
        g.triangle_section[triangle]=u32(section_of[group])
        for instance,k in corners {
            corner:=triangle*3+k
            id:=int(instance)
            if !id_used(t.instances.words,t.instances.count,id) {return {.Malformed,base,"mesh description triangle names a vertex instance it does not have"}}
            vertex:=new_format(v)?attribute_int(instance_vertex,v,id):t.instance_vertex[id]
            if !id_used(t.vertices.words,t.vertices.count,int(vertex)) {return {.Malformed,base,"mesh description vertex instance names a vertex it does not have"}}
            g.corner_vertex[corner],g.corner_instance[corner]=u32(vertex),u32(id)
            g.normal[corner]=attribute_floats(normals,v,0,id,3)
            tangent:=attribute_floats(tangents,v,0,id,3)
            g.tangent[corner]={tangent.x,tangent.y,tangent.z,attribute_floats(signs,v,0,id,1)[0]}
            if colors!=nil {g.color[corner]=color_srgb(attribute_floats(colors,v,0,id,4))}
            for channel in 0..<g.uv_count {g.uvs[channel][corner]=attribute_floats(uvs,v,channel,id,2)}
        }
    }

    hard:=attribute_find(&t.edges,.Bool,"IsHard")
    edge_vertices:=attribute_find(&t.edges,.Int,"VertexIndex")
    for id in 0..<t.edges.count {
        if !id_used(t.edges.words,t.edges.count,id) || !attribute_bool(hard,v,id) {continue}
        pair:[2]i32
        if new_format(v) {pair={attribute_int(edge_vertices,v,id,0),attribute_int(edge_vertices,v,id,1)}} else {pair=t.edge_vertices[id]}
        g.hard[edge_key(u32(pair[0]),u32(pair[1]))]=true
    }
    return {}
}

// The triangles UE5 makes of a polygon of a description saved before it kept
// them. Loading such a description triangulates each polygon by ear
// clipping before the vertex positions are in: no ear
// passes its tests and every one is forced, which leaves the fan about the
// second corner; a polygon of three corners stays as it is. instances holds
// the vertex instance of each corner, i32 each.
@(private)
polygon_fan :: proc(instances:[]u8,group:i32,triangles:^[dynamic][3]i32,groups:^[dynamic]i32) {
    corner :: proc(instances:[]u8,at:int) -> i32 {return transmute(i32)u32_at(instances,at*4)}
    count:=len(instances)/4
    if count==3 {
        append(triangles,[3]i32{corner(instances,0),corner(instances,1),corner(instances,2)})
        append(groups,group)
        return
    }
    append(triangles,[3]i32{corner(instances,count-1),corner(instances,0),corner(instances,1)})
    append(groups,group)
    for ear:=count-1;ear>=3;ear-=1 {
        append(triangles,[3]i32{corner(instances,ear-1),corner(instances,ear),corner(instances,1)})
        append(groups,group)
    }
}

// A color quantized to sRGB: what the build writes into the vertex buffer.
@(private)
color_srgb :: proc(c:[4]f32) -> (out:[4]u8) {
    for i in 0..<3 {
        x:=c[i]
        if !(x>0) {x=0}
        out[i]=u8(mm.linear_to_srgb_scalar(min(x,1))*255+0.5)
    }
    a:=c[3]
    if !(a>0) {a=0}
    out[3]=u8(min(a,1)*255+0.5)
    return
}

@(private)
edge_key :: #force_inline proc "contextless" (a,b:u32) -> [2]u32 {return {min(a,b),max(a,b)}}

@(private)
finite :: #force_inline proc "contextless" (v:[3]f32) -> bool {return v.x-v.x==0 && v.y-v.y==0 && v.z-v.z==0}

// Unreal's triangle normal: its winding runs the other way of its left-handed axes.
@(private)
face_normal :: #force_inline proc "contextless" (a,b,c:[3]f32) -> [3]f32 {return linalg.cross(c-a,b-a)}

// Triangles whose corners are one point, or that have no area, leave the
// build; the rows of the others move down.
@(private)
degenerates_remove :: proc(g:^Gather,build:Build_Settings,scratch:mem.Allocator) -> int {
    threshold:f32=build.remove_degenerates?DEGENERATE_DISTANCE:0
    same :: proc(a,b:[3]f32,threshold:f32) -> bool {return abs(a.x-b.x)<=threshold && abs(a.y-b.y)<=threshold && abs(a.z-b.z)<=threshold}
    keep:=make([]bool,len(g.triangle_section),scratch)
    for &kept,triangle in keep {
        p0,p1,p2:=g.positions[g.corner_vertex[triangle*3]],g.positions[g.corner_vertex[triangle*3+1]],g.positions[g.corner_vertex[triangle*3+2]]
        n:=face_normal(p0,p1,p2)
        kept=!(same(p0,p1,threshold) || same(p0,p2,threshold) || same(p1,p2,threshold) || !(linalg.dot(n,n)>1e-30))
    }
    return triangles_keep(g,keep)
}

// Leaves the triangles keep does not mark out; the rows of the others move
// down. Returns how many left.
@(private)
triangles_keep :: proc(g:^Gather,keep:[]bool) -> int {
    kept:=0
    for triangle in 0..<len(g.triangle_section) {
        if !keep[triangle] {continue}
        if kept!=triangle {
            for k in 0..<3 {
                from,to:=triangle*3+k,kept*3+k
                g.corner_vertex[to],g.normal[to],g.tangent[to]=g.corner_vertex[from],g.normal[from],g.tangent[from]
                if len(g.color)>0 {g.color[to]=g.color[from]}
                if len(g.corner_instance)>0 {g.corner_instance[to]=g.corner_instance[from]}
                for channel in 0..<g.uv_count {g.uvs[channel][to]=g.uvs[channel][from]}
            }
            g.triangle_section[kept]=g.triangle_section[triangle]
            if len(g.smoothing)>0 {g.smoothing[kept]=g.smoothing[triangle]}
        }
        kept+=1
    }
    removed:=len(g.triangle_section)-kept
    resize(&g.triangle_section,kept)
    resize(&g.corner_vertex,kept*3);resize(&g.normal,kept*3);resize(&g.tangent,kept*3)
    if len(g.color)>0 {resize(&g.color,kept*3)}
    if len(g.corner_instance)>0 {resize(&g.corner_instance,kept*3)}
    for channel in 0..<g.uv_count {resize(&g.uvs[channel],kept*3)}
    if len(g.smoothing)>0 {g.smoothing=g.smoothing[:kept]}
    return removed
}

// Normals as Unreal's static mesh build makes them: the normal of a corner is
// the sum of the triangle normals around its point that meet it through
// soft edges (all of them with bRecomputeNormals, else those without one).
// Corners at the same point blend, as Unreal blends overlapping corners. A
// corner whose normal is made takes a MikkTSpace tangent too, as all do
// when the build makes its tangents.
@(private)
normals_make :: proc(g:^Gather,build:Build_Settings,scratch:mem.Allocator) {
    corners:=len(g.corner_vertex)
    made:=make([]bool,corners,scratch)
    any_made:=false
    for &n,corner in g.normal {
        length:=linalg.length(n)
        made[corner]=build.recompute_normals || !(length>1e-4) || !finite(n)
        if !made[corner] {n/=length}
        any_made||=made[corner]
    }
    if any_made {
        // Points by position: the welded vertex of every corner.
        point_of:=make([]u32,len(g.positions),scratch)
        geom.positions_weld(g.positions[:],0,point_of)
        // Corners joined across soft edges: union-find over the corners.
        parent:=make([]u32,corners,scratch)
        for &value,i in parent {value=u32(i)}
        find :: proc(parent:[]u32,i:u32) -> u32 {
            root:=i
            for parent[root]!=root {root=parent[root]}
            for at:=i;parent[at]!=root; {next:=parent[at];parent[at]=root;at=next}
            return root
        }
        Half_Edge :: struct {key:[2]u32,corner:u32}
        edges:=make([]Half_Edge,corners,scratch)
        for corner in 0..<corners {
            next:=corner-corner%3+(corner%3+1)%3
            edges[corner]={edge_key(point_of[g.corner_vertex[corner]],point_of[g.corner_vertex[next]]),u32(corner)}
        }
        slice.sort_by(edges,proc(a,b:Half_Edge) -> bool {return a.key[0]<b.key[0] || a.key[0]==b.key[0] && (a.key[1]<b.key[1] || a.key[1]==b.key[1] && a.corner<b.corner)})
        for first:=0;first<len(edges); {
            last:=first+1
            for last<len(edges) && edges[last].key==edges[first].key {last+=1}
            for i in first..<last {
                for j in i+1..<last {
                    a,b:=edges[i].corner,edges[j].corner
                    if !soft(g,a,b) {continue}
                    // Each half-edge runs from its corner to the next; join the corners at each end point.
                    for end in 0..<2 {
                        ca:=end==0?a:a-a%3+(a%3+1)%3
                        point:=point_of[g.corner_vertex[ca]]
                        cb:=b
                        if point_of[g.corner_vertex[cb]]!=point {cb=b-b%3+(b%3+1)%3}
                        ra,rb:=find(parent,ca),find(parent,cb)
                        if ra!=rb {parent[ra]=rb}
                    }
                }
            }
            first=last
        }
        sums:=make([][3]f32,corners,scratch)
        for triangle in 0..<len(g.triangle_section) {
            p:[3][3]f32
            for k in 0..<3 {p[k]=g.positions[g.corner_vertex[triangle*3+k]]}
            face:=face_normal(p[0],p[1],p[2])
            area:=linalg.length(face)*0.5
            n:=face/(2*area)
            for k in 0..<3 {
                weight:f32=1
                if build.weighted_normals {weight=area*linalg.angle_between(p[(k+1)%3]-p[k],p[(k+2)%3]-p[k])}
                root:=find(parent,u32(triangle*3+k))
                sums[root]+=n*weight
            }
        }
        for corner in 0..<corners {
            if !made[corner] {continue}
            sum:=sums[find(parent,u32(corner))]
            length:=linalg.length(sum)
            if length>1e-12 {g.normal[corner]=sum/length} else {
                p0,p1,p2:=g.positions[g.corner_vertex[corner-corner%3]],g.positions[g.corner_vertex[corner-corner%3+1]],g.positions[g.corner_vertex[corner-corner%3+2]]
                g.normal[corner]=linalg.normalize(face_normal(p0,p1,p2))
            }
        }
    }
    for &tangent,corner in g.tangent {
        t:=tangent.xyz
        length:=linalg.length(t)
        if build.recompute_tangents || build.recompute_normals || made[corner] || !(length>1e-4) || !finite(t) || tangent.w==0 {
            tangent={}
            continue
        }
        tangent={t.x/length,t.y/length,t.z/length,tangent.w<0?-1:1}
    }
}

// Whether the triangles of two corners whose half-edges share a pair of points
// are smooth across it.
@(private)
soft :: proc(g:^Gather,a,b:u32) -> bool {
    ta,tb:=a/3,b/3
    if ta==tb {return false}
    if len(g.smoothing)>0 {return g.smoothing[ta]&g.smoothing[tb]!=0}
    next:=a-a%3+(a%3+1)%3
    return !g.hard[edge_key(g.corner_vertex[a],g.corner_vertex[next])]
}

// ScaleStaticMeshVertex: positions and tangents scale, normals take the
// inverse; a scale that mirrors turns the triangles.
@(private)
build_scale :: proc(g:^Gather,build:Build_Settings) {
    s:=build.scale
    if s=={1,1,1} {return}
    for &p in g.positions {p*=s}
    for corner in 0..<len(g.corner_vertex) {
        n:=linalg.normalize(g.normal[corner]/s)
        tangent:=g.tangent[corner]
        if tangent.xyz!={} {
            bitangent:=linalg.cross(g.normal[corner],tangent.xyz)*tangent.w
            t,b:=tangent.xyz*s,bitangent*s
            if build.legacy_tangent_scaling {t,b=tangent.xyz/s,bitangent/s}
            t,b=linalg.normalize(t),linalg.normalize(b)
            g.tangent[corner]={t.x,t.y,t.z,linalg.dot(linalg.cross(n,t),b)<0?-1:1}
        }
        g.normal[corner]=n
    }
    if s.x*s.y*s.z<0 {
        for triangle in 0..<len(g.triangle_section) {
            a,b:=triangle*3+1,triangle*3+2
            g.corner_vertex[a],g.corner_vertex[b]=g.corner_vertex[b],g.corner_vertex[a]
            g.normal[a],g.normal[b]=g.normal[b],g.normal[a]
            g.tangent[a],g.tangent[b]=g.tangent[b],g.tangent[a]
            if len(g.color)>0 {g.color[a],g.color[b]=g.color[b],g.color[a]}
            for channel in 0..<g.uv_count {g.uvs[channel][a],g.uvs[channel][b]=g.uvs[channel][b],g.uvs[channel][a]}
        }
    }
}

// The material of a section is that of
// its section info, else that of its section info at import, else the slot
// whose imported name is that of its polygon group (or the slot numbered as
// the group), as long as the slot exists; else the slot numbered as the section.
@(private)
sections_resolve :: proc(g:^Gather,mesh:^Static_Mesh) {
    valid :: proc(mesh:^Static_Mesh,material:int) -> bool {return material>=0 && material<len(mesh.materials)}
    for &section,i in g.sections {
        section.material= -1
        switch {
        case i<len(mesh.section_materials) && valid(mesh,int(mesh.section_materials[i])):section.material=int(mesh.section_materials[i])
        case i<len(mesh.original_materials) && valid(mesh,int(mesh.original_materials[i])):section.material=int(mesh.original_materials[i])
        case:
            built:=int(g.group_ids[i])
            if section.name!="" {
                for slot,row in mesh.materials {
                    if slot.imported_name==section.name {built=row;break}
                }
            }
            if valid(mesh,built) {section.material=built} else if valid(mesh,i) {section.material=i}
        }
    }
}

@(private)
clone :: proc(text:string,allocator:mem.Allocator) -> string {
    if text=="" {return ""}
    return strings.clone(text,allocator)
}

@(private)
name_slot :: proc(index:int,allocator:mem.Allocator) -> string {
    return fmt.aprintf("MaterialSlot_%d",index,allocator=allocator)
}
