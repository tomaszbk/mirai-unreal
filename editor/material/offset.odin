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
// CPU at the vertex, with its uv and its color, its textures read as white
// (their brightest) and its object standing on its pivot, over
// OFFSET_SECONDS and a field of places; what it gives is the most it moves
// the vertex across.

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

OFFSET_SECONDS :: 60     // of time over which the reach is measured
OFFSET_STEPS :: 120      // instants of those seconds
OFFSET_PLACES :: 2       // places along each side of the field the reach is measured over
OFFSET_FIELD :: f32(1e4) // centimetres a side of that field

// What the offset of material does to a mesh with the vertices given, its
// pivot at the origin of its space and its box from bounds[0] to bounds[1]:
// reach, as long as vertices, takes the centimetres it moves each across at
// most, all -1 where that cannot be measured (why) and 0 for an offset that
// is not motion. names and why live in allocator.
offset_read :: proc(lib:^Library,material:Object,vertices:[]Offset_Vertex,bounds:[2][3]f32,reach:[]f32,allocator:=context.allocator) -> (o:Offset,error:Error) {
    if len(reach)<len(vertices) {return {},error_make(.Malformed,"reach holds %d vertices of %d",len(reach),len(vertices))}
    reach:=reach[:len(vertices)]
    slice.fill(reach,0)
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
        slice.fill(reach,-1)
        o.why=strings.clone(len(e.notes)>0?e.notes[0]:"it could not be translated",allocator)
        return
    }
    if value,constant:=evaluate_constant(&g,root);constant {
        o.kind=value.xyz=={}?.None:.Shape
        return
    }
    if depends_on(&g,root,{.Vertex_Color}) {o.weights+={.Vertex_Color}}
    if depends_on(&g,root,{.UV}) {o.weights+={.UV}}
    o.textured=depends_on(&g,root,{.Sample,.Sample_Grad,.Texture_Read})
    if !depends_on(&g,root,{.Time}) {
        o.kind=.Shape
        return
    }
    o.kind=windy?.Wind:.Motion
    direction,why:=offset_reach(&g,root,vertices,bounds,reach)
    o.direction=direction
    if why!="" {
        slice.fill(reach,-1)
        o.why=strings.clone(why,allocator)
    }
    return
}

// Whether a name of what feeds an offset calls it wind.
offset_name_is_wind :: proc(name:string) -> bool {
    return strings.contains(strings.to_lower(name,context.temp_allocator),"wind")
}

// The reach of an offset at each vertex, as offset_read measures it, and
// the way it moves them on the whole; why it cannot run on the CPU.
@(private)
offset_reach :: proc(g:^Graph,root:u32,vertices:[]Offset_Vertex,bounds:[2][3]f32,reach:[]f32) -> (direction:[2]f32,why:string) {
    order:=nodes_under(g,{root})
    for n in order {
        #partial switch g.nodes[n].op {
        case .Noise,.Vector_Noise,.Custom,.Custom_Output,.Arguments,.Texture_Read:
            return {},"it reads noise or HLSL that only a program computes"
        }
    }
    low,high:=bounds[0],bounds[1]
    centre:=(low+high)*0.5
    size:=high-low
    radius:=math.sqrt(size.x*size.x+size.y*size.y+size.z*size.z)*0.5
    values:=make([][4]f32,len(g.nodes),context.temp_allocator)
    texel:Texel_Context
    sum:[2]f32
    across:f32
    for vertex,i in vertices {
        texel.uv=vertex.uvs[0]
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
                if !(length<1e30) {return {},"it moves the surface by what is not a number"}
                reach[i]=max(reach[i],length)
                sum+=moved
                across+=length
            }
        }
    }
    mean:=math.sqrt(sum.x*sum.x+sum.y*sum.y)
    // Mostly one way: half of how far it moves on average is along its mean.
    if across>0 && mean>across*0.5 {direction=sum/mean}
    return
}

// The names of an offset that call it wind, in order.
offset_wind_names :: proc(o:Offset,allocator:=context.temp_allocator) -> []string {
    out:=make([dynamic]string,allocator)
    for name in o.names {if offset_name_is_wind(name) {append(&out,name)}}
    slice.sort(out[:])
    return out[:]
}
