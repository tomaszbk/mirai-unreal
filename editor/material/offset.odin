package material

import "core:math"
import "core:slice"
import "core:strings"

// What the WorldPositionOffset of a material does to its surface, which
// Mirai's materials do not move: an importer of foliage, whose types sway by
// the wind of their own, takes from it whether and how far a plant sways.
//
// The offset is wind when it moves with time and a material function, a
// parameter or a collection parameter that feeds it is named for the wind;
// it is another motion (a flag, a pulse) when it moves with time and nothing
// that feeds it says wind, and a shape when it does not move.
//
// How far it moves each vertex of a mesh is measured: the graph runs on the
// CPU at the vertex, with its uv and its color, its textures as the caller
// reads them (white, their brightest, where it does not) and its object
// standing on its pivot, over
// OFFSET_SECONDS and a field of places; what it gives each vertex is how far
// it sways and how far it flutters (Offset_Reach, the most of the places),
// and how many times a second the highest vertex given sways back and forth
// at the first place. What moves a vertex slower than OFFSET_SLOW is its
// sway, the length of its path along the line it sways along; what moves it
// faster about that is its flutter. A swing is what the wind moves:
// what an offset leans a vertex one way all the time is not in it.

Offset_Kind :: enum u8 {
    None,   // the surface stays where it is
    Shape,  // moved, but not with time
    Motion, // moved with time by what is not wind
    Wind,   // swayed in the wind
}

// What weighs the offset of each vertex.
Offset_Weight :: enum u8 {Vertex_Color,UV}

Offset :: struct {
    kind:Offset_Kind,
    direction:[2]f32, // along Unreal's X and Y, unit: the way it moves the vertices on the whole; zero where it sways both ways
    weights:bit_set[Offset_Weight],
    textured:bool,    // it reads a texture: gusts by an image
    frequency:f32,    // cycles per second the first vertex sways at; 0 where it does not cross its middle
    names:[]string,   // the material functions, collection parameters and parameters that feed it, each once
    why:string,       // why its reach could not be measured; "" when it was, or it is no motion
}

// A vertex of a mesh as an offset reads it: in the space of the mesh,
// Unreal's centimetres, with its uv sets (v from the top) and its color.
Offset_Vertex :: struct {
    position:[3]f32,
    uvs:[UNREAL_UV_SETS][2]f32,
    color:[4]f32,
}

// The texels of the texture at an object path, as Unreal's sampler reads
// them, for an offset that samples it; nil where they cannot be read.
Offset_Textures :: struct {
    read:proc(data:rawptr,path:string) -> ^Pixels,
    data:rawptr,
}

OFFSET_SECONDS :: 20     // of time over which the reach is measured
OFFSET_STEPS :: 400      // instants of those seconds: what sways up to ten times a second shows
OFFSET_PLACES :: 2       // places along each side of the field the reach is measured over
OFFSET_FIELD :: f32(1e4) // centimetres a side of that field
OFFSET_SLOW :: 1         // cycles a second: what moves a vertex slower sways it, what moves it faster flutters it

// What the offset of a material moves a vertex by, in centimetres.
Offset_Reach :: struct {
    sway:f32,    // the length of its slow path along the line it moves along
    flutter:f32, // how far it moves faster about that: the root mean square of the distance, times √2, the amplitude of a swing back and forth
}

// What the offset of material does to a mesh with the vertices given, its
// pivot at the origin of its space and its box from bounds[0] to bounds[1]:
// reach, as long as vertices, takes what it moves each, all -1 where that
// cannot be measured (why) and 0 for an offset that is not motion. names and
// why live in allocator.
offset_read :: proc(lib:^Library,material:Object,vertices:[]Offset_Vertex,bounds:[2][3]f32,reach:[]Offset_Reach,textures:=Offset_Textures{},allocator:=context.allocator) -> (o:Offset,error:Error) {
    if len(reach)<len(vertices) {return {},error_make(.Malformed,"reach holds %d vertices of %d",len(reach),len(vertices))}
    reach:=reach[:len(vertices)]
    slice.fill(reach,Offset_Reach{})
    if !object_valid(material) {return {},error_make(.Not_Found,"the material does not exist")}
    chain,chain_error:=chain_read(lib,material,context.temp_allocator)
    if chain_error.code!=.None {return {},chain_error}
    base_material:=chain.material
    g:Graph
    graph_init(&g,context.temp_allocator)
    e:Evaluator
    evaluator_init(&e,lib,&g,context.temp_allocator)
    e.overrides=chain.overrides
    e.stack=chain.stack
    e.ue5=base_material.pkg.p.summary.version_ue5>0
    inputs:=base_material
    if data,found:=object_child(base_material,"MaterialEditorOnlyData");found {inputs=data}
    roots,connected:=material_outputs(&e,base_material,inputs,{.World_Position_Offset},-1)
    if !connected[.World_Position_Offset] {return}
    root:=roots[.World_Position_Offset]

    names:=make([dynamic]string,allocator)
    seen:=make(map[string]struct{},context.temp_allocator)
    name_add :: proc(names:^[dynamic]string,seen:^map[string]struct{},name:string) {
        if name=="" || name in seen {return}
        seen[name]={}
        append(names,strings.clone(name,names.allocator))
    }
    for name in e.names {name_add(&names,&seen,name)}
    if root!=NONE {
        for n in nodes_under(&g,{root}) {
            if g.nodes[n].op==.Parameter {name_add(&names,&seen,g.parameters[g.nodes[n].index].name)}
        }
    }
    o.names=names[:]
    windy:=false
    for name in o.names {windy||=offset_name_is_wind(name)}

    if root==NONE {
        // What could not be translated is wind when its names say so.
        o.kind=windy?.Wind:.Motion
        slice.fill(reach,Offset_Reach{-1,-1})
        o.why=strings.clone(len(e.notes)>0?e.notes[0]:"it could not be translated",allocator)
        return
    }
    if value,constant:=evaluate_constant(&g,root);constant {
        o.kind=value.xyz=={}?.None:.Shape
        return
    }
    if !depends_on(&g,root,{.Time}) {
        o.kind=.Shape
        return
    }
    if depends_on(&g,root,{.Vertex_Color}) {o.weights+={.Vertex_Color}}
    if depends_on(&g,root,{.UV}) {o.weights+={.UV}}
    o.textured=depends_on(&g,root,{.Sample,.Sample_Grad,.Texture_Read})
    o.kind=windy?.Wind:.Motion
    direction,frequency,why:=offset_reach(&g,root,vertices,bounds,reach,textures)
    o.direction,o.frequency=direction,frequency
    if why!="" {
        slice.fill(reach,Offset_Reach{-1,-1})
        o.why=strings.clone(why,allocator)
    }
    return
}

// Whether a name of what feeds an offset calls it wind.
offset_name_is_wind :: proc(name:string) -> bool {
    return strings.contains(strings.to_lower(name,context.temp_allocator),"wind")
}

// The reach of an offset at each vertex, as offset_read measures it, the
// way it moves them on the whole and the frequency of the first; why it
// cannot run on the CPU.
@(private)
offset_reach :: proc(g:^Graph,root:u32,vertices:[]Offset_Vertex,bounds:[2][3]f32,reach:[]Offset_Reach,textures:Offset_Textures) -> (direction:[2]f32,frequency:f32,why:string) {
    order:=nodes_under(g,{root})
    for n in order {
        #partial switch g.nodes[n].op {
        case .Noise,.Vector_Noise,.Custom,.Custom_Output,.Arguments,.Texture_Read:
            return {},0,"it reads noise or HLSL that only a program computes"
        }
    }
    low,high:=bounds[0],bounds[1]
    centre:=(low+high)*0.5
    size:=high-low
    radius:=math.sqrt(size.x*size.x+size.y*size.y+size.z*size.z)*0.5
    values:=make([][4]f32,len(g.nodes),context.temp_allocator)
    pixels:=make([]^Pixels,len(g.textures),context.temp_allocator)
    if textures.read!=nil {
        for n in order {
            node:=&g.nodes[n]
            if node.op==.Texture && int(node.index)<len(pixels) {pixels[node.index]=textures.read(textures.data,g.textures[node.index].path)}
        }
    }
    texel:Texel_Context
    sum:[2]f32
    across:f32
    paths:[OFFSET_PLACES*OFFSET_PLACES][OFFSET_STEPS][2]f32 // what the vertex moves at each place
    first:[OFFSET_STEPS][2]f32 // what the first vertex moves at the first place
    for vertex,i in vertices {
        for step in 0..<OFFSET_STEPS {
            time:=f32(step)*OFFSET_SECONDS/OFFSET_STEPS
            for k in 0..<OFFSET_PLACES*OFFSET_PLACES {
                place:=[3]f32{f32(k%OFFSET_PLACES),f32(k/OFFSET_PLACES),0}*(OFFSET_FIELD/OFFSET_PLACES)
                for n in order {
                    node:=&g.nodes[n]
                    v:[4]f32
                    #partial switch node.op {
                    case .Time:v.x=time
                    case .World_Position:v.xyz=place+vertex.position
                    case .Actor_Position:v.xyz=place
                    case .Object_Position:v.xyz=place+centre
                    case .Object_Axis:v[min(node.index,2)]=1
                    case .Object_Radius:v.x=radius
                    case .Object_Bounds:v.xyz=node.index==0?low:high
                    case .Vertex_Color:v=vertex.color
                    case .UV:v.xy=vertex.uvs[min(node.index,UNREAL_UV_SETS-1)]
                    case .Vertex_Normal,.Pixel_Normal:v.z=1
                    case .Vertex_Tangent:v.x=1
                    case .Vertex_Bitangent:v.y=1
                    case .Two_Sided_Sign:v.x=1
                    case .Per_Instance_Random,.Particle_Random:v.x=0.5
                    // At the coordinates it computes, which move with time and place.
                    case .Sample,.Sample_Grad:
                        index:=g.nodes[node.args[0]].index
                        v=pixels_read(int(index)<len(pixels)?pixels[index]:nil,values[node.args[1]].xy)
                    case:
                        if node.op in CONTEXT {break}
                        args:[3][4]f32
                        for arg,j in node.args {if arg!=NONE {args[j]=values[arg]}}
                        v=node_compute(g,node,args,&texel)
                    }
                    values[n]=v
                }
                moved:=values[root].xy
                length:=math.sqrt(moved.x*moved.x+moved.y*moved.y)
                if !(length<1e30) {return {},0,"it moves the surface by what is not a number"}
                paths[k][step]=moved
                sum+=moved
                across+=length
            }
        }
        for &path,k in paths {
            slow:=offset_slow(path[:])
            reach[i].sway=max(reach[i].sway,offset_swing(slow[:]))
            reach[i].flutter=max(reach[i].flutter,offset_flutter(path[:],slow[:]))
            if i==0 && k==0 {first=slow}
        }
    }
    mean:=math.sqrt(sum.x*sum.x+sum.y*sum.y)
    // Mostly one way: half of how far it moves on average is along its mean.
    if across>0 && mean>across*0.5 {direction=sum/mean}
    frequency=offset_frequency(first[:])
    return
}

// The middle of a path and the unit line through it that it moves most
// along; false for one that stands still.
@(private)
offset_axis :: proc(path:[][2]f32) -> (middle,axis:[2]f32,moves:bool) {
    if len(path)<2 {return}
    for p in path {middle+=p}
    middle/=f32(len(path))
    xx,yy,xy:f32
    for p in path {
        d:=p-middle
        xx+=d.x*d.x;yy+=d.y*d.y;xy+=d.x*d.y
    }
    // What moves less than a hundredth of a millimetre stands still.
    if !(xx+yy>1e-6*f32(len(path))) {return}
    angle:=0.5*math.atan2(2*xy,xx-yy)
    return middle,{math.cos(angle),math.sin(angle)},true
}

OFFSET_FLUTTER_LEAST :: f32(0.5) // centimetres the vertices of a section flutter on average, at or below which they do not

// Whether the vertices of a section, by what an offset moves them, flutter.
offset_flutters :: proc(reach:[]Offset_Reach) -> bool {
    sum:f32
    for r in reach {sum+=max(r.flutter,0)}
    return len(reach)>0 && sum/f32(len(reach))>OFFSET_FLUTTER_LEAST
}

// A path of OFFSET_STEPS instants as it moves slower than OFFSET_SLOW: the
// cycles of OFFSET_SECONDS slower than it, by their Fourier series.
@(private)
offset_slow :: proc(path:[]([2]f32)) -> (slow:[OFFSET_STEPS][2]f32) {
    N :: OFFSET_STEPS
    if len(path)!=N {return}
    turn:[N][2]f32 // cosine and sine of each nth of a turn
    for n in 0..<N {turn[n]={math.cos(2*math.PI*f32(n)/N),math.sin(2*math.PI*f32(n)/N)}}
    for k in 0..<OFFSET_SECONDS*OFFSET_SLOW {
        re,im:[2]f32
        for p,n in path {
            w:=turn[(k*n)%N]
            re+=p*w.x
            im-=p*w.y
        }
        scale:=f32(k==0?1:2)/N
        for &q,n in slow {
            w:=turn[(k*n)%N]
            q+=(re*w.x-im*w.y)*scale
        }
    }
    return
}

// How far a path moves about its slow path: the root mean square of the
// distance, times √2, the amplitude of a swing back and forth.
@(private)
offset_flutter :: proc(path,slow:[]([2]f32)) -> f32 {
    if len(path)==0 {return 0}
    sum:f32
    for p,k in path {
        d:=p-slow[k]
        sum+=d.x*d.x+d.y*d.y
    }
    return math.sqrt(2*sum/f32(len(path)))
}

// How far what moves along a path goes along the line it moves most along.
@(private)
offset_swing :: proc(path:[][2]f32) -> f32 {
    middle,axis,moves:=offset_axis(path)
    if !moves {return 0}
    low,high:=f32(0),f32(0)
    for p in path {
        along:=(p.x-middle.x)*axis.x+(p.y-middle.y)*axis.y
        low,high=min(low,along),max(high,along)
    }
    return high-low
}

// Cycles per second of what moves along a path over OFFSET_SECONDS: half
// the times it crosses its middle along the line it moves most along.
@(private)
offset_frequency :: proc(path:[][2]f32) -> f32 {
    middle,axis,moves:=offset_axis(path)
    if !moves {return 0}
    side :: proc(p,middle,axis:[2]f32) -> bool {return (p.x-middle.x)*axis.x+(p.y-middle.y)*axis.y<0}
    crossings:=0
    for k in 1..<len(path) {
        if side(path[k-1],middle,axis)!=side(path[k],middle,axis) {crossings+=1}
    }
    return f32(crossings)*0.5/OFFSET_SECONDS
}

// The names of an offset that call it wind, in order.
offset_wind_names :: proc(o:Offset,allocator:=context.temp_allocator) -> []string {
    out:=make([dynamic]string,allocator)
    for name in o.names {if offset_name_is_wind(name) {append(&out,name)}}
    slice.sort(out[:])
    return out[:]
}
