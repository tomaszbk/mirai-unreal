package fixture_files

import "core:math"

// A StaticMesh package with one source model, in each of the three ways
// Unreal saves it.
Mesh_Layout :: enum u8 {
    Raw_Mesh,           // UE4 before MeshDescription: RawMesh in bulk data
    Legacy_Description, // UE4: MeshDescription of element arrays, zlib chunks at the end of the file
    Description,        // UE5: MeshDescription of element maps in a StaticMeshDescriptionBulkData, in the trailer
}

Mesh_Slot :: struct {name,imported_name,material:string} // material: its package, "" for none

Mesh_Fixture :: struct {
    layout:Mesh_Layout,
    name:string,              // SM_Fixture when ""
    positions:[][3]f32,       // Unreal's space, centimeters
    corners:[]u32,            // vertex of each corner, three per triangle
    polygon_sizes:[]int,      // Legacy_Description: the corners of each polygon, saved before triangles were; empty: triangles
    normals:[][3]f32,         // per corner; empty: none
    tangents:[][4]f32,        // per corner, w the binormal sign; empty: none
    uvs,uvs1:[][2]f32,        // per corner; uvs1 empty: one channel
    colors:[][4]u8,           // per corner, RGBA as Unreal draws it; empty: none
    groups:[]u32,             // per triangle (per polygon with polygon_sizes): polygon group, or face material of a raw mesh
    group_names:[]string,     // ImportedMaterialSlotName of each polygon group
    smoothing:[]u32,          // raw mesh: per triangle
    hard:[][2]u32,            // descriptions: hard edges by their vertices
    slots:[]Mesh_Slot,
    section_materials:[]i32,  // SectionInfoMap of LOD 0; -1 leaves a section out
    recompute_normals,recompute_tangents:bool,
    scale:[3]f32,             // build scale; zero: none
    bounds_min,bounds_max:[3]f32,
    has_bounds:bool,
    fortnite:i32,             // FortniteMainBranchObjectVersion of a description: 0 is 80
    native_slots:bool,        // UE4: MaterialInterface only in the untagged StaticMaterial array
    body:Body_Fixture,        // the AggGeom of its BodySetup; no shapes and no trace: no BodySetup
}

// Unreal's space: centimeters and degrees of pitch, yaw and roll.
Body_Box :: struct {center:[3]f32,rotation:[3]f32,size:[3]f32}
Body_Sphere :: struct {center:[3]f32,radius:f32}
Body_Capsule :: struct {center:[3]f32,rotation:[3]f32,radius,length:f32}
Body_Fixture :: struct {
    boxes:[]Body_Box,
    spheres:[]Body_Sphere,
    capsules:[]Body_Capsule,
    convexes:[][][3]f32,
    trace:string, // ECollisionTraceFlag; "": the default
    profile:string,
}

@(private) EDITOR :: [4]u32{0xE4B068ED,0xF49442E9,0xA231DA0B,0x2E46BB41}
@(private) RELEASE :: [4]u32{0x9C54D522,0xA8264FBE,0x94210746,0x61B482D0}
@(private) MAIN :: [4]u32{0x697DD581,0xE64F41AB,0xAA4A51EC,0xBEB7B628}
@(private) ENTERPRISE :: [4]u32{0x9DFFBCD6,0x494F0158,0xE2211282,0x3C92A888}
@(private) RENDERING :: [4]u32{0x12F88B9F,0x88754AFC,0xA67CD90C,0x383ABD29}
@(private) FORTNITE :: [4]u32{0x601D1886,0xAC644F84,0xAA16D3DE,0x0DEAC7D6}

static_mesh_package :: proc(f:Mesh_Fixture,allocator:=context.temp_allocator) -> []u8 {
    fortnite:=f.fortnite if f.fortnite!=0 else 80
    versions:[]Version
    ue5:i32
    switch f.layout {
    case .Raw_Mesh:versions={{EDITOR,17},{RENDERING,15}}
    case .Legacy_Description:
        // The editor version that added mesh description triangles is 35.
        editor:=i32(len(f.polygon_sizes)>0?34:40)
        versions={{EDITOR,editor},{RELEASE,43},{ENTERPRISE,10},{RENDERING,45},{FORTNITE,47}}
    case .Description:ue5=1008;versions={{EDITOR,40},{RELEASE,44},{MAIN,88},{ENTERPRISE,10},{RENDERING,45},{FORTNITE,fortnite}}
    }
    mesh_name:=f.name if f.name!="" else "SM_Fixture"
    w:=writer_make({ue5=ue5,versions=versions,package_name="/Game/Meshes/SM_Fixture"},allocator)
    class:=engine_class(&w,"StaticMesh")
    materials:=make([]i32,len(f.slots),allocator)
    for slot,i in f.slots {if slot.material!="" {materials[i]=material_import(&w,slot.material)}}

    payload:=f.layout==.Raw_Mesh?raw_mesh_bytes(f,allocator):description_bytes(&w,f,f.layout==.Description,fortnite,allocator)
    description_object:=i32(0)
    if f.layout==.Description {description_object=2}

    b:=bytes_make(allocator)
    model:=bytes_make(allocator)
    settings:=bytes_make(allocator)
    if !f.recompute_normals {bool_property(&settings,&w,"bRecomputeNormals",false)}
    if !f.recompute_tangents {bool_property(&settings,&w,"bRecomputeTangents",false)}
    if f.scale!={} {vector_property(&settings,&w,"BuildScale3D",{f64(f.scale.x),f64(f.scale.y),f64(f.scale.z)})}
    struct_property(&model,&w,"BuildSettings","MeshBuildSettings",&settings)
    if description_object!=0 {object_property(&model,&w,"StaticMeshDescriptionBulkData",description_object)}
    struct_array_property(&b,&w,"SourceModels","StaticMeshSourceModel",{model})
    if len(f.section_materials)>0 {
        entries:=bytes_make(allocator)
        count:=0
        for material,section in f.section_materials {
            if material<0 {continue}
            count+=1
            put_u32(&entries,u32(section))
            int_property(&entries,&w,"MaterialIndex",material)
            none(&entries,&w)
        }
        info:=bytes_make(allocator)
        tag(&info,&w,"Map","MapProperty",8+len(entries.data),{inner="UInt32Property",value="StructProperty"})
        put_u32(&info,0);put_u32(&info,u32(count))
        put_bytes(&info,entries.data[:])
        struct_property(&b,&w,"SectionInfoMap","MeshSectionInfoMap",&info)
    }
    slots:=make([]Bytes,len(f.slots),allocator)
    for slot,i in f.slots {
        slots[i]=bytes_make(allocator)
        if materials[i]!=0 && !f.native_slots {object_property(&slots[i],&w,"MaterialInterface",materials[i])}
        name_property(&slots[i],&w,"MaterialSlotName",slot.name)
        name_property(&slots[i],&w,"ImportedMaterialSlotName",slot.imported_name)
    }
    if len(slots)>0 {struct_array_property(&b,&w,"StaticMaterials","StaticMaterial",slots)}
    if f.has_bounds {
        bounds:=bytes_make(allocator)
        center,extent:=(f.bounds_min+f.bounds_max)/2,(f.bounds_max-f.bounds_min)/2
        vector_property(&bounds,&w,"Origin",{f64(center.x),f64(center.y),f64(center.z)})
        vector_property(&bounds,&w,"BoxExtent",{f64(extent.x),f64(extent.y),f64(extent.z)})
        struct_property(&b,&w,"ExtendedBounds","BoxSphereBounds",&bounds)
    }
    none(&b,&w)
    // The native tail of a StaticMesh.
    body_setup:=i32(0)
    if len(f.body.boxes)+len(f.body.spheres)+len(f.body.capsules)+len(f.body.convexes)>0 || f.body.trace!="" {body_setup=description_object!=0?3:2}
    put_u32(&b,0)
    put_u8(&b,0);put_u8(&b,0)
    put_u32(&b,0)
    put_i32(&b,body_setup)
    put_u32(&b,0)
    put_u32(&b,0);put_u32(&b,0)
    put_zeros(&b,16)
    put_u32(&b,0)
    switch f.layout {
    case .Raw_Mesh:
        byte_bulk_data(&b,&w,len(payload),payload,false)
        put_zeros(&b,20)
    case .Legacy_Description:
        put_u32(&b,1)
        byte_bulk_data(&b,&w,len(payload),zlib_chunks(payload,allocator),true)
        put_zeros(&b,20)
    case .Description:
    }
    put_u32(&b,0)
    if f.native_slots {
        put_u32(&b,u32(len(f.slots)))
        for slot,i in f.slots {
            put_u32(&b,transmute(u32)materials[i])
            put_name(&b,&w,slot.name)
            put_name(&b,&w,slot.imported_name)
            put_u32(&b,1);put_u32(&b,0)
            put_zeros(&b,16)
        }
    } else {
        put_u32(&b,0)
    }
    export_add(&w,{class=class,outer=0,name=mesh_name,data=b.data[:]})
    if description_object!=0 {
        data:=bytes_make(allocator)
        none(&data,&w)
        put_u32(&data,0)
        editor_bulk_data(&data,&w,payload)
        put_zeros(&data,20)
        export_add(&w,{class=engine_class(&w,"StaticMeshDescriptionBulkData"),outer=1,name="StaticMeshDescriptionBulkData",data=data.data[:]})
    }
    if body_setup!=0 {export_add(&w,{class=engine_class(&w,"BodySetup"),outer=1,name="BodySetup_0",data=body_setup_bytes(&w,f.body,allocator)})}
    return package_bytes(&w)
}

@(private)
raw_mesh_bytes :: proc(f:Mesh_Fixture,allocator:=context.temp_allocator) -> []u8 {
    b:=bytes_make(allocator)
    put_u32(&b,1);put_u32(&b,0)
    faces:=len(f.corners)/3
    put_u32(&b,u32(faces));for group in f.groups {put_u32(&b,group)}
    put_u32(&b,u32(faces));for face in 0..<faces {put_u32(&b,len(f.smoothing)>0?f.smoothing[face]:1)}
    vectors :: proc(b:^Bytes,values:[][3]f32) {put_u32(b,u32(len(values)));for v in values {for x in v {put_f32(b,x)}}}
    vectors(&b,f.positions)
    put_u32(&b,u32(len(f.corners)));for vertex in f.corners {put_u32(&b,vertex)}
    tangent_x,tangent_y:=make([][3]f32,len(f.tangents),allocator),make([][3]f32,len(f.tangents),allocator)
    for tangent,i in f.tangents {
        n:=f.normals[i]
        tangent_x[i]=tangent.xyz
        // RawMesh keeps the binormal, Unreal's cross product times the sign.
        tangent_y[i]=[3]f32{n.y*tangent.z-n.z*tangent.y,n.z*tangent.x-n.x*tangent.z,n.x*tangent.y-n.y*tangent.x}*tangent.w
    }
    vectors(&b,tangent_x);vectors(&b,tangent_y);vectors(&b,f.normals)
    for channel in 0..<8 {
        uvs:=channel==0?f.uvs:channel==1?f.uvs1:nil
        put_u32(&b,u32(len(uvs)))
        for uv in uvs {put_f32(&b,uv.x);put_f32(&b,uv.y)}
    }
    put_u32(&b,u32(len(f.colors)))
    for c in f.colors {put_u8(&b,c[2]);put_u8(&b,c[1]);put_u8(&b,c[0]);put_u8(&b,c[3])}
    put_u32(&b,0)
    return b.data[:]
}

// Element arrays (UE4) or element maps (UE5) of one vertex instance per corner;
// the SkinWeights of a skeletal mesh when skin has the influences of each vertex.
@(private)
description_bytes :: proc(w:^Writer,f:Mesh_Fixture,element_map:bool,fortnite:i32,allocator:=context.temp_allocator,skin:[][]Skeletal_Influence=nil,morphs:[]Skeletal_Morph=nil) -> []u8 {
    b:=bytes_make(allocator)
    corners:=len(f.corners)
    triangles:=corners/3
    groups:=len(f.group_names)
    // The polygons: those of polygon_sizes, else the triangles.
    loops:=make([dynamic]int,allocator)
    if len(f.polygon_sizes)>0 {append(&loops,..f.polygon_sizes)} else {for _ in 0..<triangles {append(&loops,3)}}
    edges:=make([dynamic][2]u32,allocator)
    first:=0
    for size in loops {
        defer first+=size
        for k in 0..<size {
            a,c:=f.corners[first+k],f.corners[first+(k+1)%size]
            pair:=[2]u32{min(a,c),max(a,c)}
            known:=false
            for edge in edges {known||=edge==pair}
            if !known {append(&edges,pair)}
        }
    }
    bits :: proc(b:^Bytes,count:int) {
        put_u32(b,u32(count))
        words:=(count+31)/32
        for word in 0..<words {
            value:u32
            for bit in 0..<32 {if word*32+bit<count {value|=1<<uint(bit)}}
            put_u32(b,value)
        }
    }
    // An attribute entry of the map: its name, type, extent (element maps), elements, channels of
    // values; raw, when it has it, is the whole attribute set after its extent.
    Attribute :: struct {name:string,type:u32,extent:int,size:int,channels:[][]u8,default:[]u8,names:[]string,raw:[]u8}
    attributes :: proc(b:^Bytes,w:^Writer,element_map:bool,fortnite:i32,count:int,list:[]Attribute) {
        put_u32(b,u32(count))
        put_u32(b,u32(len(list)))
        for a in list {
            put_text(b,a.name)
            put_u32(b,a.type)
            if element_map {put_u32(b,u32(a.extent))}
            if a.raw!=nil {put_bytes(b,a.raw);continue}
            put_u32(b,u32(count))
            put_u32(b,u32(max(len(a.channels),a.type==6?1:0)))
            if a.type==6 {
                if fortnite>=257 {
                    put_u32(b,1)
                    put_u32(b,u32(len(a.names)))
                    put_u32(b,u32(len(a.names)))
                    for text in a.names {put_text(b,text)}
                } else {
                    if element_map {put_u32(b,1)}
                    put_u32(b,u32(len(a.names)))
                    for text in a.names {put_text(b,text)}
                }
                put_text(b,"")
            } else {
                for values in a.channels {
                    if element_map {put_u32(b,u32(a.extent))}
                    put_u32(b,u32(a.size))
                    put_u32(b,u32(len(values)/a.size))
                    put_bytes(b,values)
                }
                put_bytes(b,a.default)
            }
            put_u32(b,0)
        }
    }
    floats :: proc(allocator:=context.temp_allocator,values:..f32) -> []u8 {
        out:=bytes_make(allocator)
        for value in values {put_f32(&out,value)}
        return out.data[:]
    }
    ints :: proc(values:[]u32,allocator:=context.temp_allocator) -> []u8 {
        out:=bytes_make(allocator)
        for value in values {put_u32(&out,value)}
        return out.data[:]
    }
    positions:=bytes_make(allocator)
    for p in f.positions {for x in p {put_f32(&positions,x)}}
    normals,tangents,signs,colors,uv0,uv1:=bytes_make(allocator),bytes_make(allocator),bytes_make(allocator),bytes_make(allocator),bytes_make(allocator),bytes_make(allocator)
    for corner in 0..<corners {
        n:=len(f.normals)>0?f.normals[corner]:{}
        t:=len(f.tangents)>0?f.tangents[corner]:{}
        for x in n {put_f32(&normals,x)}
        for x in t.xyz {put_f32(&tangents,x)}
        put_f32(&signs,t.w)
        c:=len(f.colors)>0?f.colors[corner]:{255,255,255,255}
        for channel in 0..<3 {put_f32(&colors,linear(c[channel]))}
        put_f32(&colors,f32(c[3])/255)
        put_f32(&uv0,f.uvs[corner].x);put_f32(&uv0,f.uvs[corner].y)
        if len(f.uvs1)>0 {put_f32(&uv1,f.uvs1[corner].x);put_f32(&uv1,f.uvs1[corner].y)}
    }
    uv_channels:=len(f.uvs1)>0?[][]u8{uv0.data[:],uv1.data[:]}:[][]u8{uv0.data[:]}
    instance_attributes:=make([dynamic]Attribute,allocator)
    append(&instance_attributes,
        Attribute{name="Normal",type=1,extent=1,size=12,channels={normals.data[:]},default=floats(allocator,0,0,0)},
        Attribute{name="Tangent",type=1,extent=1,size=12,channels={tangents.data[:]},default=floats(allocator,0,0,0)},
        Attribute{name="BinormalSign",type=3,extent=1,size=4,channels={signs.data[:]},default=floats(allocator,0)},
        Attribute{name="Color",type=0,extent=1,size=16,channels={colors.data[:]},default=floats(allocator,1,1,1,1)},
        Attribute{name="TextureCoordinate",type=2,extent=1,size=8,channels=uv_channels,default=floats(allocator,0,0)},
    )
    hard:=bytes_make(allocator)
    for edge in edges {
        is_hard:=false
        for pair in f.hard {is_hard||=[2]u32{min(pair[0],pair[1]),max(pair[0],pair[1])}==edge}
        put_u8(&hard,is_hard?1:0)
    }
    position_attribute:=Attribute{name="Position ",type=1,extent=1,size=12,channels={positions.data[:]},default=floats(allocator,0,0,0)}
    hard_attribute:=Attribute{name="IsHard",type=5,extent=1,size=1,channels={hard.data[:]},default={0,0,0,0}}
    name_attribute:=Attribute{name="ImportedMaterialSlotName",type=6,extent=1,names=f.group_names}
    vertices:=make([dynamic]Attribute,allocator)
    append(&vertices,position_attribute)
    if skin!=nil {append(&vertices,Attribute{name="SkinWeights",type=4,extent=0,raw=skin_weights(skin,allocator)})}
    // SkeletalMeshAttributes: a morph target moves vertices and turns the normals of their instances.
    for morph in morphs {
        moved:=make([][3]f32,len(f.positions),allocator)
        turned:=make([][3]f32,len(f.positions),allocator)
        for d in morph.deltas {moved[d.vertex]=d.position;turned[d.vertex]=d.normal}
        by_vertex,by_corner:=bytes_make(allocator),bytes_make(allocator)
        for p in moved {for x in p {put_f32(&by_vertex,x)}}
        for vertex in f.corners {for x in turned[vertex] {put_f32(&by_corner,x)}}
        attribute_name:=concat("Morph-",morph.name)
        append(&vertices,Attribute{name=attribute_name,type=1,extent=1,size=12,channels={by_vertex.data[:]},default=floats(allocator,0,0,0)})
        append(&instance_attributes,Attribute{name=attribute_name,type=1,extent=1,size=12,channels={by_corner.data[:]},default=floats(allocator,0,0,0)})
    }
    vertex_attributes:=vertices[:]
    if element_map {
        instance_vertex:=ints(f.corners,allocator)
        identity:=make([]u32,corners,allocator)
        for &value,i in identity {value=u32(i)}
        edge_vertices:=make([]u32,len(edges)*2,allocator)
        for edge,i in edges {edge_vertices[i*2],edge_vertices[i*2+1]=edge[0],edge[1]}
        polygons:=make([]u32,triangles,allocator)
        for &value,i in polygons {value=u32(i)}
        append(&instance_attributes,Attribute{name="VertexIndex",type=4,extent=1,size=4,channels={instance_vertex},default=ints({0xffffffff},allocator)})
        put_u32(&b,6)
        Element :: struct {name:string,count:int,attributes:[]Attribute}
        elements:=[6]Element{
            {"Vertices",len(f.positions),vertex_attributes},
            {"VertexInstances",corners,instance_attributes[:]},
            {"UVs",0,nil},
            {"Edges",len(edges),{{name="VertexIndex",type=4,extent=2,size=4,channels={ints(edge_vertices,allocator)},default=ints({0xffffffff},allocator)},hard_attribute}},
            {"Triangles",triangles,{
                {name="VertexInstanceIndex",type=4,extent=3,size=4,channels={ints(identity,allocator)},default=ints({0xffffffff},allocator)},
                {name="PolygonGroupIndex",type=4,extent=1,size=4,channels={ints(f.groups,allocator)},default=ints({0xffffffff},allocator)},
                {name="PolygonIndex",type=4,extent=1,size=4,channels={ints(polygons,allocator)},default=ints({0xffffffff},allocator)},
            }},
            {"PolygonGroups",groups,{name_attribute}},
        }
        for e in elements {
            put_text(&b,e.name)
            put_u32(&b,1)
            bits(&b,e.count)
            put_u32(&b,0)
            attributes(&b,w,true,fortnite,e.count,e.attributes)
        }
        return b.data[:]
    }
    bits(&b,len(f.positions))
    bits(&b,corners)
    for vertex in f.corners {put_u32(&b,vertex)}
    bits(&b,len(edges))
    for edge in edges {put_u32(&b,edge[0]);put_u32(&b,edge[1])}
    bits(&b,len(loops))
    first=0
    for size,polygon in loops {
        put_u32(&b,u32(size))
        for k in 0..<size {put_u32(&b,u32(first+k))}
        put_u32(&b,f.groups[polygon])
        first+=size
    }
    bits(&b,groups)
    attributes(&b,w,false,fortnite,len(f.positions),{position_attribute})
    attributes(&b,w,false,fortnite,corners,instance_attributes[:])
    attributes(&b,w,false,fortnite,len(edges),{hard_attribute})
    attributes(&b,w,false,fortnite,len(loops),nil)
    attributes(&b,w,false,fortnite,groups,{name_attribute})
    if len(f.polygon_sizes)>0 {return b.data[:]}
    bits(&b,triangles)
    for triangle in 0..<triangles {
        for k in 0..<3 {put_u32(&b,u32(triangle*3+k))}
        put_u32(&b,u32(triangle))
    }
    attributes(&b,w,false,fortnite,triangles,nil)
    return b.data[:]
}

// sRGB bytes as the linear color MeshDescription keeps.
@(private)
linear :: proc(c:u8) -> f32 {
    x:=f32(c)/255
    return x<=0.04045?x/12.92:math.pow((x+0.055)/1.055,2.4)
}

// BodySetup: its AggGeom, trace flag and default instance, and its native
// tail without cooked data.
@(private)
body_setup_bytes :: proc(w:^Writer,f:Body_Fixture,allocator:=context.temp_allocator) -> []u8 {
    wide:=w.desc.ue5>=1004
    b:=bytes_make(allocator)
    geometry:=bytes_make(allocator)
    boxes:=make([]Bytes,len(f.boxes),allocator)
    for box,i in f.boxes {
        boxes[i]=bytes_make(allocator)
        vector_property(&boxes[i],w,"Center",{f64(box.center.x),f64(box.center.y),f64(box.center.z)})
        rotator_property(&boxes[i],w,"Rotation",box.rotation)
        float_property(&boxes[i],w,"X",box.size.x);float_property(&boxes[i],w,"Y",box.size.y);float_property(&boxes[i],w,"Z",box.size.z)
    }
    if len(boxes)>0 {struct_array_property(&geometry,w,"BoxElems","KBoxElem",boxes)}
    spheres:=make([]Bytes,len(f.spheres),allocator)
    for sphere,i in f.spheres {
        spheres[i]=bytes_make(allocator)
        vector_property(&spheres[i],w,"Center",{f64(sphere.center.x),f64(sphere.center.y),f64(sphere.center.z)})
        float_property(&spheres[i],w,"Radius",sphere.radius)
    }
    if len(spheres)>0 {struct_array_property(&geometry,w,"SphereElems","KSphereElem",spheres)}
    capsules:=make([]Bytes,len(f.capsules),allocator)
    for capsule,i in f.capsules {
        capsules[i]=bytes_make(allocator)
        vector_property(&capsules[i],w,"Center",{f64(capsule.center.x),f64(capsule.center.y),f64(capsule.center.z)})
        rotator_property(&capsules[i],w,"Rotation",capsule.rotation)
        float_property(&capsules[i],w,"Radius",capsule.radius);float_property(&capsules[i],w,"Length",capsule.length)
    }
    if len(capsules)>0 {struct_array_property(&geometry,w,"SphylElems","KSphylElem",capsules)}
    convexes:=make([]Bytes,len(f.convexes),allocator)
    for points,i in f.convexes {
        convexes[i]=bytes_make(allocator)
        data:=bytes_make(allocator)
        for point in points {for x in point {if wide {put_f64(&data,f64(x))} else {put_f32(&data,x)}}}
        inner:=bytes_make(allocator)
        tag(&inner,w,"VertexData","StructProperty",len(data.data),{struct_name="Vector"})
        tag(&convexes[i],w,"VertexData","ArrayProperty",4+len(inner.data)+len(data.data),{inner="StructProperty"})
        put_u32(&convexes[i],u32(len(points)))
        put_bytes(&convexes[i],inner.data[:])
        put_bytes(&convexes[i],data.data[:])
    }
    if len(convexes)>0 {struct_array_property(&geometry,w,"ConvexElems","KConvexElem",convexes)}
    struct_property(&b,w,"AggGeom","KAggregateGeom",&geometry)
    if f.trace!="" {enum_property(&b,w,"CollisionTraceFlag","ECollisionTraceFlag",f.trace)}
    if f.profile!="" {
        instance:=bytes_make(allocator)
        name_property(&instance,w,"CollisionProfileName",f.profile)
        struct_property(&b,w,"DefaultInstance","BodyInstance",&instance)
    }
    none(&b,w)
    put_u32(&b,0)
    return b.data[:]
}
