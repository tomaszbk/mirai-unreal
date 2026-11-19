package material

import "core:math"
import "core:slice"
import "core:strings"

// What an unlit material shows on the inside of a dome, seen from the centre
// of the dome: the emission of its graph run on the CPU at the points where
// directions from that centre meet the dome, for an importer that turns a
// dome into the image of a sky. The view of each point is the direction it
// is seen along, time is 0 and its textures are read as the caller reads
// them (white where it does not).

// A point of a dome as the sky reads it, in the world: Unreal's axes and
// centimetres, with its uv sets (v from the top) and its color.
Sky_Point :: struct {
    position:[3]f32,
    normal:[3]f32, // of the surface, unit
    uvs:[UNREAL_UV_SETS][2]f32,
    color:[4]f32,
}

// The dome as its graph sees it, in the world.
Sky_View :: struct {
    eye:[3]f32,       // where it is seen from: the centre of its bounds
    radius:f32,       // of its bounds
    pivot:[3]f32,
    axes:[3][3]f32,   // its local axes, as long as its scale along each
    bounds:[2][3]f32, // low and high corners of its box in its own space
}

// The emission of a material ready to run at the points of a dome.
Sky_Graph :: struct {
    g:Graph,
    root:u32,
    order:[]u32,       // the nodes the emission needs, in the order they run
    pixels:[]^Pixels,  // by row of g.textures
    widest:int,        // texels across the widest texture it samples; 0: none
    moving:bool,       // it changes with time: what it shows at 0
    instance:[]string, // the parameters it reads that an instance of the chain sets, each once
    why:string,        // why it cannot run on the CPU; "" when it can
}

// The emission of material as sky_shade runs it, with the textures it
// samples read through textures. Its slices and why live in allocator.
sky_graph :: proc(lib:^Library,material:Object,textures:=Offset_Textures{},allocator:=context.allocator) -> (s:Sky_Graph,error:Error) {
    if !object_valid(material) {return {},error_make(.Not_Found,"the material does not exist")}
    chain,chain_error:=chain_read(lib,material,allocator)
    if chain_error.code!=.None {return {},chain_error}
    base_material:=chain.material
    graph_init(&s.g,allocator)
    e:Evaluator
    evaluator_init(&e,lib,&s.g,allocator)
    e.overrides=chain.overrides
    e.stack=chain.stack
    e.ue5=base_material.pkg.p.summary.version_ue5>0
    e.seen_from_eye=true
    inputs:=base_material
    if data,found:=object_child(base_material,"MaterialEditorOnlyData");found {inputs=data}
    roots,_:=material_outputs(&e,base_material,inputs,{.Emissive},-1)
    s.root=roots[.Emissive]
    if s.root==NONE {
        s.why=strings.clone(len(e.notes)>0?e.notes[0]:"its emission could not be translated",allocator)
        return
    }
    if e.exposure_relative {
        s.why="its emission is relative to the exposure"
        return
    }
    s.order=slice.clone(nodes_under(&s.g,{s.root}),allocator)
    for n in s.order {
        #partial switch s.g.nodes[n].op {
        case .Noise,.Vector_Noise,.Custom,.Custom_Output,.Arguments,.Texture_Read,.Ddx,.Ddy,.Sample_Grad,.Texture_Size:
            s.why="it reads noise, HLSL or derivatives that only a program computes"
            return
        case .Screen_Position,.Screen_Size,.Scene_Depth,.Layer_Weight,.Particle_Data,.Particle_Radius:
            s.why="it reads the image of the view or what only a terrain or a particle gives"
            return
        }
    }
    s.moving=depends_on(&s.g,s.root,{.Time})
    s.pixels=make([]^Pixels,len(s.g.textures),allocator)
    for n in s.order {
        node:=&s.g.nodes[n]
        if node.op!=.Texture || int(node.index)>=len(s.pixels) {continue}
        if textures.read!=nil {s.pixels[node.index]=textures.read(textures.data,s.g.textures[node.index].path)}
        if p:=s.pixels[node.index];p!=nil {s.widest=max(s.widest,p.width)}
    }
    names:=make([dynamic]string,allocator)
    for n in s.order {
        node:=&s.g.nodes[n]
        if node.op!=.Parameter {continue}
        name:=s.g.parameters[node.index].name
        set:=false
        for o in chain.overrides {set||=strings.equal_fold(o.name,name)}
        if set && !slice.contains(names[:],name) {append(&names,strings.clone(name,allocator))}
    }
    slice.sort(names[:])
    s.instance=names[:]
    return
}

// The emission of s at each point of dome, into out (as long as points), at
// time 0, each seen from the eye of the dome.
sky_shade :: proc(s:^Sky_Graph,dome:Sky_View,points:[]Sky_Point,out:[][3]f32) {
    if s.why!="" || s.root==NONE {return}
    g:=&s.g
    values:=make([][4]f32,len(g.nodes),context.temp_allocator)
    texel:Texel_Context
    for point,i in points {
        if i>=len(out) {break}
        along:=point.position-dome.eye
        depth:=math.sqrt(along.x*along.x+along.y*along.y+along.z*along.z)
        view:[3]f32
        if depth>0 {view=-along/depth}
        for n in s.order {
            node:=&g.nodes[n]
            v:[4]f32
            #partial switch node.op {
            case .Time,.Origin:
            case .World_Position:v.xyz=point.position
            case .Actor_Position:v.xyz=dome.pivot
            case .Object_Position:v.xyz=dome.eye
            case .Object_Radius:v.x=dome.radius
            case .Object_Axis:v.xyz=dome.axes[min(node.index,2)]
            case .Object_Bounds:v.xyz=dome.bounds[node.index==0?0:1]
            case .Camera_Position:v.xyz=dome.eye
            case .Camera_Vector:v.xyz=view
            case .Pixel_Depth:v.x=depth
            case .Vertex_Color:v=point.color
            case .UV:v.xy=point.uvs[min(node.index,UNREAL_UV_SETS-1)]
            case .Vertex_Normal,.Pixel_Normal:v.xyz=point.normal
            case .Vertex_Tangent:v.x=1
            case .Vertex_Bitangent:v.y=1
            case .Two_Sided_Sign:v.x=1
            case .Per_Instance_Random,.Particle_Random:v.x=0.5
            case .Texture:
            case .Sample:
                index:=g.nodes[node.args[0]].index
                v=pixels_read(int(index)<len(s.pixels)?s.pixels[index]:nil,values[node.args[1]].xy)
            case:
                args:[3][4]f32
                for arg,j in node.args {if arg!=NONE {args[j]=values[arg]}}
                v=node_compute(g,node,args,&texel)
            }
            values[n]=v
        }
        emitted:=values[s.root]
        if g.nodes[s.root].width==1 {emitted.yz=emitted.x}
        for c in 0..<3 {out[i][c]=emitted[c]<1e30 && emitted[c]>0?emitted[c]:0}
    }
}
