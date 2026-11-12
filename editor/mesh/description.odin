package mesh

import "core:mem"
import unreal "project:plugins/unreal/editor/package"

// MeshDescription as its bulk data stores it, with names as Strings and
// with the versions of the package. Two layouts:
//
//   element map      UE5 (and the one release that wrote it early): a map of
//                    element type to containers, each a bit array of the ids in
//                    use and an attribute set; topology is index attributes
//   element arrays   UE4: vertices, vertex instances, edges, polygons and
//                    polygon groups as sparse arrays of structs, their
//                    attribute sets, and, since triangles were stored, those;
//                    before, the triangles are made from the polygons
//
// Attributes keep views of the payload; nothing is copied until the mesh is built.

// The attribute types of a mesh description, in the order the format numbers them.
@(private) Attribute_Type :: enum u32 {Vector4,Vector3,Vector2,Float,Int,Bool,Name,Transform}

@(private)
Channel :: struct {count:int,data:[]u8,names:[]string}

// ChunkSize of TAttributeArrayContainer (1 << ChunkBits): the elements of a chunk.
@(private) CHUNK_ELEMENTS :: 256

// A chunk of a TAttributeArrayContainer: the values of its elements, packed,
// with where each element starts and how many it has (i32 each).
@(private)
Chunk :: struct {values:[]u8,elements:int,starts,counts:[]u8}

@(private)
Attribute :: struct {
    name:string,
    type:Attribute_Type,
    extent:int,         // 0: an array of any length per element, in chunks
    channels:[]Channel,
    chunks:[]Chunk,     // extent 0, of channel 0
    default:[]u8,
}

// The ids in use of an element type and its attributes.
@(private)
Elements :: struct {words:[]u8,count:int,attributes:[]Attribute}

@(private)
Topology :: struct {
    vertices,instances,edges,groups:Elements,
    triangles:Elements,               // element map only: its index attributes
    instance_vertex:[]i32,            // element arrays: by instance id
    edge_vertices:[][2]i32,           // element arrays: by edge id
    triangle_corners:[][3]i32,        // element arrays: valid triangles, by triangle id
    triangle_polygon:[]i32,
    polygons:Elements,                // element arrays: the ids in use
    polygon_group:[]i32,              // element arrays: by polygon id
    polygon_instances:[][]u8,         // element arrays before triangles: the vertex instances of each polygon, i32 each
}

@(private)
element_size :: proc(v:Versions,type:Attribute_Type) -> int {
    switch type {
    case .Vector4:return 16
    case .Vector3:return 12
    case .Vector2:return 8
    case .Float,.Int:return 4
    case .Bool:return 1
    case .Name:return 0
    case .Transform:return v.ue5>=UE5_LARGE_WORLD_COORDINATES?80:40
    }
    return 0
}

@(private)
new_format :: proc(v:Versions) -> bool {return v.release==RELEASE_NEW_FORMAT || v.main>=MAIN_NEW_FORMAT}

@(private)
id_used :: #force_inline proc "contextless" (words:[]u8,count,index:int) -> bool {
    return index>=0 && index<count && index>>3<len(words) && words[index>>3]&(1<<uint(index&7))!=0
}

// A TBitArray: its bit count and the words that hold them.
@(private)
bits_read :: proc(r:^Reader,field:string) -> (words:[]u8,count:int) {
    count=count_read(r,0,field)
    if failed(r) {return}
    if count>1<<30 {bad(r,.Limit,field);return}
    words=take(r,(count+31)/32*4,field)
    if failed(r) {return nil,0}
    return
}

@(private)
description_read :: proc(bytes:[]u8,v:Versions,base:i64,scratch:mem.Allocator) -> (t:Topology,error:unreal.Error) {
    r:=reader_make(bytes,base)
    if new_format(v) {element_map_read(&r,v,&t,scratch)} else {element_arrays_read(&r,v,&t,scratch)}
    if failed(&r) {return {},r.error}
    if r.at!=len(bytes) {return {},{.Malformed,base+i64(r.at),"mesh description has trailing bytes"}}
    return t,{}
}

@(private)
element_map_read :: proc(r:^Reader,v:Versions,t:^Topology,scratch:mem.Allocator) {
    count:=count_read(r,12,"mesh element type count")
    for _ in 0..<count {
        name:=text_string(r,"mesh element type name",scratch)
        channels:=count_read(r,12,"mesh element channel count")
        for channel in 0..<channels {
            e:Elements
            e.words,e.count=bits_read(r,"mesh element ids")
            _=i32_read(r,"mesh element holes")
            e.attributes=attributes_read(r,v,scratch)
            if failed(r) {return}
            if channel>0 {continue}
            switch name {
            case "Vertices":t.vertices=e
            case "VertexInstances":t.instances=e
            case "Edges":t.edges=e
            case "Triangles":t.triangles=e
            case "PolygonGroups":t.groups=e
            }
        }
    }
}

@(private)
element_arrays_read :: proc(r:^Reader,v:Versions,t:^Topology,scratch:mem.Allocator) {
    legacy:=v.release<RELEASE_NEW_SERIALIZATION
    skip_ids :: proc(r:^Reader,field:string) {_=take(r,count_read(r,4,field)*4,field)}

    t.vertices.words,t.vertices.count=bits_read(r,"vertex ids")
    for id in 0..<t.vertices.count {
        if !id_used(t.vertices.words,t.vertices.count,id) {continue}
        if legacy {skip_ids(r,"vertex instances of a vertex");skip_ids(r,"edges of a vertex")}
        if failed(r) {return}
    }
    t.instances.words,t.instances.count=bits_read(r,"vertex instance ids")
    t.instance_vertex=make([]i32,t.instances.count,scratch)
    for id in 0..<t.instances.count {
        if !id_used(t.instances.words,t.instances.count,id) {continue}
        t.instance_vertex[id]=i32_read(r,"vertex of a vertex instance")
        if legacy {skip_ids(r,"polygons of a vertex instance")}
        if failed(r) {return}
    }
    t.edges.words,t.edges.count=bits_read(r,"edge ids")
    t.edge_vertices=make([][2]i32,t.edges.count,scratch)
    for id in 0..<t.edges.count {
        if !id_used(t.edges.words,t.edges.count,id) {continue}
        t.edge_vertices[id]={i32_read(r,"edge vertex"),i32_read(r,"edge vertex")}
        if legacy {skip_ids(r,"polygons of an edge")}
        if failed(r) {return}
    }
    t.polygons.words,t.polygons.count=bits_read(r,"polygon ids")
    t.polygon_group=make([]i32,t.polygons.count,scratch)
    t.polygon_instances=make([][]u8,t.polygons.count,scratch)
    for id in 0..<t.polygons.count {
        if failed(r) {return}
        if !id_used(t.polygons.words,t.polygons.count,id) {t.polygon_group[id]= -1;continue}
        t.polygon_instances[id]=take(r,count_read(r,4,"polygon vertex instances")*4,"polygon vertex instances")
        if v.editor<EDITOR_REMOVED_HOLES {
            holes:=count_read(r,4,"polygon hole count")
            for _ in 0..<holes {skip_ids(r,"polygon hole")}
        }
        if legacy {
            triangles:=count_read(r,12,"polygon triangle count")
            _=take(r,triangles*(v.editor>=EDITOR_TRIANGLES?16:12),"polygon triangles")
        }
        t.polygon_group[id]=i32_read(r,"polygon group of a polygon")
    }
    t.groups.words,t.groups.count=bits_read(r,"polygon group ids")
    for id in 0..<t.groups.count {
        if !id_used(t.groups.words,t.groups.count,id) {continue}
        if legacy {skip_ids(r,"polygons of a polygon group")}
        if failed(r) {return}
    }
    t.vertices.attributes=attributes_read(r,v,scratch)
    t.instances.attributes=attributes_read(r,v,scratch)
    t.edges.attributes=attributes_read(r,v,scratch)
    _=attributes_read(r,v,scratch)
    t.groups.attributes=attributes_read(r,v,scratch)
    if failed(r) {return}
    if v.editor<EDITOR_TRIANGLES {return}
    words,count:=bits_read(r,"triangle ids")
    triangles:=make([dynamic][3]i32,scratch)
    polygons:=make([dynamic]i32,scratch)
    for id in 0..<count {
        if !id_used(words,count,id) {continue}
        append(&triangles,[3]i32{i32_read(r,"triangle vertex instance"),i32_read(r,"triangle vertex instance"),i32_read(r,"triangle vertex instance")})
        append(&polygons,i32_read(r,"polygon of a triangle"))
        if failed(r) {return}
    }
    t.triangle_corners,t.triangle_polygon=triangles[:],polygons[:]
    _=attributes_read(r,v,scratch)
}

// An AttributesSetBase: its attribute arrays by name.
@(private)
attributes_read :: proc(r:^Reader,v:Versions,scratch:mem.Allocator) -> []Attribute {
    list:=make([dynamic]Attribute,scratch)
    if v.editor<EDITOR_NEW_ATTRIBUTE_FORMAT {
        if i32_read(r,"attribute type count")!=7 {bad(r,.Unsupported_Value,"attribute type count of an old mesh description");return nil}
        for type in Attribute_Type.Vector4..=Attribute_Type.Name {
            _=i32_read(r,"attribute element count")
            count:=count_read(r,8,"attribute count")
            for _ in 0..<count {
                name:=text_string(r,"attribute name",scratch)
                attribute:=attribute_set_read(r,v,type,1,scratch)
                attribute.name=name
                if failed(r) {return nil}
                append(&list,attribute)
            }
        }
        return list[:]
    }
    _=i32_read(r,"attribute element count")
    count:=count_read(r,8,"attribute count")
    for _ in 0..<count {
        name:=text_string(r,"attribute name",scratch)
        type:=u32_read(r,"attribute type")
        extent:=1
        if new_format(v) {extent=int(u32_read(r,"attribute extent"))}
        if failed(r) {return nil}
        if type>u32(max(Attribute_Type)) {bad(r,.Unsupported_Value,"mesh attribute type");return nil}
        if extent>64 {bad(r,.Limit,"mesh attribute extent");return nil}
        attribute:=attribute_set_read(r,v,Attribute_Type(type),extent,scratch)
        attribute.name=name
        if failed(r) {return nil}
        append(&list,attribute)
    }
    return list[:]
}

// A TMeshAttributeArraySet (extent above zero) or TMeshUnboundedAttributeArraySet.
@(private)
attribute_set_read :: proc(r:^Reader,v:Versions,type:Attribute_Type,extent:int,scratch:mem.Allocator) -> (a:Attribute) {
    a.type,a.extent=type,extent
    _=i32_read(r,"attribute element count")
    channels:=count_read(r,4,"attribute channel count")
    if channels>MAX_UVS*4 {bad(r,.Limit,"attribute channel count");return}
    if extent==0 {
        // Arrays of any length per element (the skin weights of a skeletal
        // mesh): the chunks of the first channel of a fixed-size type are kept.
        for channel in 0..<channels {
            count:=count_read(r,8,"attribute chunk count")
            kept:=channel==0 && type!=.Name && type!=.Transform
            if kept {a.chunks=make([]Chunk,count,scratch)}
            for at in 0..<count {
                values:=count_read(r,0,"attribute chunk value count")
                start:=r.at
                values_skip(r,v,type,values)
                elements:=count_read(r,12,"attribute chunk element count")
                if elements>CHUNK_ELEMENTS {bad(r,.Malformed,"attribute chunk element count");return}
                ranges:=take(r,elements*12,"attribute chunk ranges")
                if failed(r) {return}
                if kept {a.chunks[at]={r.bytes[start:start+values*element_size(v,type)],elements,ranges[:elements*4],ranges[elements*4:elements*8]}}
            }
            _=i32_read(r,"attribute element count")
            values_skip(r,v,type,1)
            if failed(r) {return}
        }
    } else {
        a.channels=make([]Channel,channels,scratch)
        for &channel in a.channels {
            channel=channel_read(r,v,type,scratch)
            if failed(r) {return}
            if channel.count%extent!=0 {bad(r,.Malformed,"attribute value count is not a multiple of its extent");return}
            channel.count/=extent
        }
    }
    if type==.Name {
        bytes,_:=text_read(r,"attribute default")
        a.default=bytes
    } else {
        a.default=take(r,type==.Bool?4:element_size(v,type),"attribute default")
    }
    _=u32_read(r,"attribute flags")
    return
}

// The values of one channel: count is the number of values, extent times the elements.
@(private)
channel_read :: proc(r:^Reader,v:Versions,type:Attribute_Type,scratch:mem.Allocator) -> (c:Channel) {
    size:=element_size(v,type)
    if type==.Name && v.fortnite>=FORTNITE_NAME_TABLES {
        // The names once and an index of each value into them.
        _=u32_read(r,"name attribute extent")
        count:=int(u32_read(r,"name attribute count"))
        if failed(r) || count==0 {return}
        if count>len(r.bytes) {bad(r,.Truncated,"name attribute count");return}
        unique_count:=int(u32_read(r,"name attribute unique count"))
        if unique_count==0 || unique_count>count {bad(r,.Malformed,"name attribute unique count");return}
        unique:=make([]string,unique_count,scratch)
        for &name in unique {name=text_string(r,"name attribute value",scratch)}
        c.count=count
        c.names=make([]string,count,scratch)
        if unique_count==1 || unique_count==count {
            for &name,i in c.names {name=unique[unique_count==1?0:i]}
            return
        }
        index_size:=u8_read(r,"name attribute index size")
        if index_size>2 {bad(r,.Malformed,"name attribute index size");return}
        for &name in c.names {
            at:int
            switch index_size {
            case 0:at=int(u8_read(r,"name attribute index"))
            case 1:at=int(u16_read(r,"name attribute index"))
            case:at=int(u32_read(r,"name attribute index"))
            }
            if failed(r) {return}
            if at>=unique_count {bad(r,.Malformed,"name attribute index");return}
            name=unique[at]
        }
        return
    }
    if new_format(v) {_=u32_read(r,"attribute extent")}
    if type==.Name {
        c.count=count_read(r,4,"name attribute count")
        c.names=make([]string,c.count,scratch)
        for &name in c.names {name=text_string(r,"name attribute value",scratch)}
        return
    }
    bulk:=v.release>=RELEASE_NEW_SERIALIZATION && type!=.Transform || type==.Transform && v.fortnite>=0 && v.fortnite<FORTNITE_TRANSFORM_ATTRIBUTES
    if bulk {
        stored:=i32_read(r,"attribute element size")
        if failed(r) {return}
        if type==.Transform {
            if count_read(r,0,"transform attribute count")!=0 {bad(r,.Unsupported_Value,"transform attributes stored in bulk")}
            return
        }
        if int(stored)!=size {bad(r,.Malformed,"attribute element size");return}
    }
    c.count=count_read(r,size,"attribute value count")
    c.data=take(r,c.count*size,"attribute values")
    return
}

// Values of an array, skipped.
@(private)
values_skip :: proc(r:^Reader,v:Versions,type:Attribute_Type,count:int) {
    if type==.Name {
        for _ in 0..<count {text_skip(r,"attribute value");if failed(r) {return}}
        return
    }
    _=take(r,count*element_size(v,type),"attribute values")
}

@(private)
attribute_find :: proc(e:^Elements,type:Attribute_Type,names:..string) -> ^Attribute {
    for &a in e.attributes {
        if a.type!=type {continue}
        for name in names {if a.name==name {return &a}}
    }
    return nil
}

// The value of an element as raw bytes: from its channel, or the default.
@(private)
attribute_bytes :: proc(a:^Attribute,v:Versions,channel,element,component:int) -> []u8 {
    size:=a.type==.Bool?1:element_size(v,a.type)
    if channel<len(a.channels) {
        c:=a.channels[channel]
        if element>=0 && element<c.count {
            at:=(element*a.extent+component)*size
            return c.data[at:at+size]
        }
    }
    return a.default
}

// The values of an element of an attribute of arrays, as raw bytes; nil for
// none, ok false when its range leaves its chunk.
@(private)
attribute_array :: proc(a:^Attribute,v:Versions,element:int) -> (values:[]u8,ok:bool) {
    if a==nil || element<0 {return nil,true}
    chunk:=element/CHUNK_ELEMENTS
    if chunk>=len(a.chunks) {return nil,true}
    c:=a.chunks[chunk]
    at:=element%CHUNK_ELEMENTS
    if at>=c.elements {return nil,true}
    start,count:=int(transmute(i32)u32_at(c.starts,at*4)),int(transmute(i32)u32_at(c.counts,at*4))
    size:=element_size(v,a.type)
    if start<0 || count<0 || (start+count)*size>len(c.values) {return nil,false}
    return c.values[start*size:(start+count)*size],true
}

@(private)
attribute_int :: proc(a:^Attribute,v:Versions,element:int,component:=0) -> i32 {
    if a==nil {return -1}
    bytes:=attribute_bytes(a,v,0,element,component)
    if len(bytes)<4 {return -1}
    return transmute(i32)u32_at(bytes,0)
}

@(private)
attribute_floats :: proc(a:^Attribute,v:Versions,channel,element:int,$N:int) -> (out:[N]f32) {
    if a==nil {return}
    bytes:=attribute_bytes(a,v,channel,element,0)
    if len(bytes)<N*4 {return}
    for i in 0..<N {out[i]=f32_at(bytes,i*4)}
    return
}

@(private)
attribute_bool :: proc(a:^Attribute,v:Versions,element:int) -> bool {
    if a==nil {return false}
    bytes:=attribute_bytes(a,v,0,element,0)
    return len(bytes)>0 && bytes[0]!=0
}

@(private)
attribute_name :: proc(a:^Attribute,element:int) -> string {
    if a==nil || len(a.channels)==0 {return ""}
    c:=a.channels[0]
    if element>=0 && element<len(c.names) {return c.names[element]}
    return string(a.default)
}
