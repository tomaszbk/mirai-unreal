package material

import "core:math"
import "core:slice"

// What a material computes, as a table of values: each node an operation on
// earlier nodes, with 1 to 4 float components. Equal nodes are one node, and
// operations on constants are folded where they are added, so two inputs
// that compute the same thing are the same row. The translation reads the
// table to fill a Material_Info, the writer bakes the parts that are images
// from it, and a program is written from it as Slang.

NONE :: max(u32)

Op :: enum u8 {
    Constant,
    Parameter, // a parameter of the material: index is its row
    Texture,   // a texture object: index is its row; it has no components
    Sample,    // args: texture and uv; four components
    // What the point being shaded gives; index is the uv set of UV. The
    // vertex normal, tangent and bitangent are the tangent frame in the world.
    // Places of the world are relative to the origin of the render, and
    // Origin is what it adds to them: a place of the world is one plus
    // Origin, so the difference of two is exact (binary). The object: the
    // centre of its bounds (Object_Position) and their radius, its pivot
    // (Actor_Position), its local axis index in the world, as long as its
    // scale along it, and the low (index 0) or high corner of its bounds in
    // its own space (Object_Bounds). Layer_Weight: that of layer index of the
    // terrain that shows the point. Screen_Position: the point in
    // the image of the view, 0 to 1; Screen_Size: that image in pixels;
    // Pixel_Depth: the distance of the point along the view; Scene_Depth:
    // that of the opaque surface behind it. Particle_Data: the data index
    // the particle that draws the point gives, or value where it gives none;
    // Particle_Random: its random value, 0 to 1; Particle_Radius: its radius.
    UV,Vertex_Color,Time,World_Position,Origin,Object_Position,Object_Radius,Actor_Position,Object_Axis,Object_Bounds,Layer_Weight,
    Vertex_Normal,Vertex_Tangent,Vertex_Bitangent,Pixel_Normal,
    Camera_Vector,Camera_Position,Screen_Position,Screen_Size,Per_Instance_Random,Two_Sided_Sign,Pixel_Depth,Scene_Depth,Particle_Data,Particle_Random,Particle_Radius,
    // Unreal's Fresnel node, whose value at normal incidence (value) it reads
    // as: Mirai's BSDF has the Fresnel of the surface already.
    Fresnel,
    // Of one argument.
    Abs,Floor,Ceil,Frac,Round,Trunc,Sqrt,Sin,Cos,Tan,Asin,Acos,Atan,Exp,Exp2,Log,Log2,Saturate,Sign,Length,Normalize,
    // Of two.
    Add,Sub,Mul,Div,Min,Max,Pow,Fmod,Step,Dot,Cross,Atan2,Less,Less_Equal,
    // Of three.
    Lerp,Clamp,Select,Smoothstep,
    Swizzle, // swizzle names the source component of each component
    Append,
    // args: a weight, a value and what it is without weight. The value where
    // the weight passes zero, else the other: a program computes what only
    // the value reads in a branch on the weight.
    Gate,
    // What only a program computes. Texture_Size: of the texture of args[0],
    // in texels. Noise and Vector_Noise: Unreal's noise (Graph.noises[index])
    // of the position args[0], Noise with the filter width args[1]. Custom:
    // the HLSL of a Custom expression (Graph.customs[index]) called with the
    // list of its inputs in args[0], its first output; Custom_Output: output
    // index of the call args[0]. Arguments: a list, a value (args[0]) and
    // the rest of it (args[1]), with no components. Texture_Read: the
    // texture of row index of Graph.textures, which a system of the project
    // writes as it runs (its read), at the uv args[0]; four components.
    Texture_Size,Noise,Vector_Noise,Custom,Custom_Output,Arguments,Texture_Read,
}

UNARY :: bit_set[Op]{.Abs,.Floor,.Ceil,.Frac,.Round,.Trunc,.Sqrt,.Sin,.Cos,.Tan,.Asin,.Acos,.Atan,.Exp,.Exp2,.Log,.Log2,.Saturate,.Sign,.Length,.Normalize}
CONTEXT :: bit_set[Op]{.UV,.Vertex_Color,.Time,.World_Position,.Origin,.Object_Position,.Object_Radius,.Actor_Position,.Object_Axis,.Object_Bounds,.Layer_Weight,.Vertex_Normal,.Vertex_Tangent,.Vertex_Bitangent,.Pixel_Normal,.Camera_Vector,.Camera_Position,.Screen_Position,.Screen_Size,.Per_Instance_Random,.Two_Sided_Sign,.Pixel_Depth,.Scene_Depth,.Particle_Data,.Particle_Random,.Particle_Radius}
// What the CPU does not evaluate: the context and what only a program computes.
PROGRAM :: CONTEXT+{.Texture_Size,.Noise,.Vector_Noise,.Custom,.Custom_Output,.Arguments,.Texture_Read}
// What makes a node vary over the surface: its context and the textures it reads.
VARYING :: PROGRAM+{.Sample,.Texture}

Node :: struct {
    op:Op,
    width:u8,
    swizzle:[4]u8,
    args:[3]u32,
    value:[4]f32,
    index:u32,
}

// How Unreal reads a texture (EMaterialSamplerType), in its order.
Sampler :: enum u8 {Color,Grayscale,Alpha,Normal,Masks,Distance_Field_Font,Linear_Color,Linear_Grayscale,Data,External}

Parameter :: struct {
    name:string, // as Unreal names it
    width:u8,
    value:[4]f32,   // the value of the material or instance being translated
    default:[4]f32, // the value of the material itself
}

// A texture a material reads: the object path of an Unreal texture.
Texture_Ref :: struct {
    path:string,
    name:string,      // of the texture
    parameter:string, // the parameter that chose it, if one did
    sampler:Sampler,
    read:Texture_Read, // what a program reads in its place; function "" none
}

// A texture that a system of the project writes as it runs (a render target
// a grid of particles writes, the buffers of a fluid), which a program reads
// by UV with function(name, uv), declared in include, instead of an image.
Texture_Read :: struct {
    texture:string,  // the object path of the texture, or the name of the parameter that chooses it
    include:string,
    function:string,
    name:string,     // what function reads: the grid that writes it
}

// The settings of a Noise or Vector_Noise node, as Unreal's expressions
// have them (MaterialExpressionNoise and MaterialExpressionVectorNoise).
// function is ENoiseFunction or EVectorNoiseFunction.
Noise_Settings :: struct {
    function,quality,levels:i32,
    scale,output_min,output_max,level_scale,repeat_size:f32,
    turbulence,tiling:bool,
    world:bool, // the position is of the world: Unreal mirrors and repeats it every NOISE_WORLD_TILE
}

// The HLSL of a Custom expression: its code, the names of its inputs in the
// order of the list of its node, and its outputs after the first.
Custom_Code :: struct {
    code:string,
    description:string,
    inputs:[]string,
    outputs:[]Custom_Output,
    width:u8, // of its first output
    unported:string, // why its code is not Slang as it is: the program keeps it as a note; "" none
}

Custom_Output :: struct {name:string,width:u8}

Graph :: struct {
    nodes:[dynamic]Node,
    lookup:map[Node]u32,
    parameters:[dynamic]Parameter,
    textures:[dynamic]Texture_Ref,
    noises:[dynamic]Noise_Settings,
    customs:[dynamic]Custom_Code,
}

graph_init :: proc(g:^Graph,allocator:=context.allocator) {
    g.nodes.allocator=allocator
    g.lookup.allocator=allocator
    g.parameters.allocator=allocator
    g.textures.allocator=allocator
    g.noises.allocator=allocator
    g.customs.allocator=allocator
}

node_get :: #force_inline proc(g:^Graph,n:u32) -> ^Node {return &g.nodes[n]}

width_of :: proc(g:^Graph,n:u32) -> u8 {return n==NONE?0:g.nodes[n].width}

@(private)
node_add :: proc(g:^Graph,node:Node) -> u32 {
    if row,found:=g.lookup[node];found {return row}
    append(&g.nodes,node)
    row:=u32(len(g.nodes)-1)
    g.lookup[node]=row
    return row
}

constant :: proc(g:^Graph,value:[4]f32,width:u8) -> u32 {
    clean:=value
    for i in int(width)..<4 {clean[i]=0}
    for &c in clean {if c==0 {c=0}} // one zero, not two
    return node_add(g,{op=.Constant,width=width,value=clean,args={NONE,NONE,NONE}})
}

scalar :: proc(g:^Graph,value:f32) -> u32 {return constant(g,{value,0,0,0},1)}

context_value :: proc(g:^Graph,op:Op,width:u8,index:u32=0) -> u32 {
    return node_add(g,{op=op,width=width,index=index,args={NONE,NONE,NONE}})
}

parameter :: proc(g:^Graph,name:string,width:u8,value,default:[4]f32) -> u32 {
    row:=-1
    for &p,i in g.parameters {if p.name==name && p.width==width {row=i;break}}
    if row<0 {
        append(&g.parameters,Parameter{name,width,value,default})
        row=len(g.parameters)-1
    }
    return node_add(g,{op=.Parameter,width=width,index=u32(row),args={NONE,NONE,NONE}})
}

texture :: proc(g:^Graph,ref:Texture_Ref) -> u32 {
    row:=-1
    for &t,i in g.textures {if t.path==ref.path && t.sampler==ref.sampler && t.parameter==ref.parameter {row=i;break}}
    if row<0 {
        append(&g.textures,ref)
        row=len(g.textures)-1
    }
    return node_add(g,{op=.Texture,width=0,index=u32(row),args={NONE,NONE,NONE}})
}

sample :: proc(g:^Graph,texture,uv:u32) -> u32 {
    if texture==NONE || uv==NONE || g.nodes[texture].op!=.Texture || g.nodes[uv].width!=2 {return NONE}
    row:=g.nodes[texture].index
    if g.textures[row].read.function!="" {return node_add(g,{op=.Texture_Read,width=4,index=row,args={uv,NONE,NONE}})}
    return node_add(g,{op=.Sample,width=4,args={texture,uv,NONE}})
}

texture_size :: proc(g:^Graph,texture:u32) -> u32 {
    if texture==NONE || g.nodes[texture].op!=.Texture {return NONE}
    return node_add(g,{op=.Texture_Size,width=2,args={texture,NONE,NONE}})
}

// Unreal's scalar noise of a position (three values) with a filter width
// (one), or its vector noise (filter NONE), as wide as Unreal gives it.
noise :: proc(g:^Graph,settings:Noise_Settings,position,filter:u32,vector:bool) -> u32 {
    if position==NONE || g.nodes[position].width!=3 || !vector && (filter==NONE || g.nodes[filter].width!=1) {return NONE}
    row:=-1
    for &s,i in g.noises {if s==settings {row=i;break}}
    if row<0 {
        append(&g.noises,settings)
        row=len(g.noises)-1
    }
    if vector {
        // Gradient and Voronoi give a fourth value (VectorNoise of HLSLMaterialTranslator).
        width:u8=settings.function==VECTOR_NOISE_GRADIENT || settings.function==VECTOR_NOISE_VORONOI?4:3
        return node_add(g,{op=.Vector_Noise,width=width,index=u32(row),args={position,NONE,NONE}})
    }
    return node_add(g,{op=.Noise,width=1,index=u32(row),args={position,filter,NONE}})
}

// EVectorNoiseFunction values with a fourth component.
VECTOR_NOISE_GRADIENT :: 2
VECTOR_NOISE_VORONOI :: 4

// A call of the HLSL of a Custom expression with its inputs (each a value
// or a texture): its first output. The call is one node per expression and
// inputs; its outputs after the first are custom_output of it.
custom :: proc(g:^Graph,code:Custom_Code,inputs:[]u32) -> u32 {
    for n in inputs {if n==NONE {return NONE}}
    append(&g.customs,code)
    list:=NONE
    for i:=len(inputs)-1;i>=0;i-=1 {list=node_add(g,{op=.Arguments,args={inputs[i],list,NONE}})}
    return node_add(g,{op=.Custom,width=code.width,index=u32(len(g.customs)-1),args={list,NONE,NONE}})
}

custom_output :: proc(g:^Graph,call:u32,output:u32,width:u8) -> u32 {
    if call==NONE || g.nodes[call].op!=.Custom {return NONE}
    return node_add(g,{op=.Custom_Output,width=width,index=output,args={call,NONE,NONE}})
}

is_constant :: proc(g:^Graph,n:u32) -> bool {return n!=NONE && g.nodes[n].op==.Constant}

// The components of n as width components: a scalar is repeated; a wider
// value keeps its first ones and a narrower one ends in zeros, as Unreal
// casts between float vectors.
convert :: proc(g:^Graph,n:u32,width:u8) -> u32 {
    if n==NONE || width==0 {return NONE}
    from:=g.nodes[n].width
    if from==width || from==0 {return from==0?NONE:n}
    if from==1 {return swizzle(g,n,{0,0,0,0},width)}
    if from>width {return swizzle(g,n,{0,1,2,3},width)}
    rest:=constant(g,{},width-from)
    return append_values(g,n,rest)
}

swizzle :: proc(g:^Graph,n:u32,components:[4]u8,width:u8) -> u32 {
    if n==NONE || width<1 || width>4 {return NONE}
    components:=components
    source:=&g.nodes[n]
    for c in components[:width] {if c>=source.width {return NONE}}
    if source.width==width {
        identity:=true
        for c,i in components[:width] {identity&&=int(c)==i}
        if identity {return n}
    }
    if source.op==.Constant {
        out:[4]f32
        for c,i in components[:width] {out[i]=source.value[c]}
        return constant(g,out,width)
    }
    if source.op==.Swizzle {
        inner:[4]u8
        for c,i in components[:width] {inner[i]=source.swizzle[c]}
        return swizzle(g,source.args[0],inner,width)
    }
    node:=Node{op=.Swizzle,width=width,args={n,NONE,NONE}}
    for c,i in components[:width] {node.swizzle[i]=c}
    return node_add(g,node)
}

component :: proc(g:^Graph,n:u32,index:u8) -> u32 {return swizzle(g,n,{index,0,0,0},1)}

append_values :: proc(g:^Graph,a,b:u32) -> u32 {
    if a==NONE || b==NONE {return NONE}
    wa,wb:=g.nodes[a].width,g.nodes[b].width
    if wa==0 || wb==0 || wa+wb>4 {return NONE}
    if is_constant(g,a) && is_constant(g,b) {
        out:[4]f32
        for i in 0..<wa {out[i]=g.nodes[a].value[i]}
        for i in 0..<wb {out[wa+i]=g.nodes[b].value[i]}
        return constant(g,out,wa+wb)
    }
    return node_add(g,{op=.Append,width=wa+wb,args={a,b,NONE}})
}

// value where weight (a scalar) passes zero, else otherwise, as wide as value.
gate :: proc(g:^Graph,weight,value,otherwise:u32) -> u32 {
    if weight==NONE || value==NONE || otherwise==NONE || g.nodes[weight].width!=1 {return value}
    width:=g.nodes[value].width
    otherwise:=convert(g,otherwise,width)
    if is_constant(g,weight) {return g.nodes[weight].value[0]>0?value:otherwise}
    if is_constant(g,value) || value==otherwise {return value}
    return node_add(g,{op=.Gate,width=width,args={weight,value,otherwise}})
}

// The width two operands of an arithmetic operation have together: equal,
// or one of them a scalar; 0 when they do not go together.
common_width :: proc(a,b:u8) -> u8 {
    if a==0 || b==0 {return 0}
    if a==b || b==1 {return a}
    if a==1 {return b}
    return 0
}

unary :: proc(g:^Graph,op:Op,a:u32) -> u32 {
    if a==NONE || g.nodes[a].width==0 {return NONE}
    width:=g.nodes[a].width
    if op==.Length {width=1}
    if op==.Normalize && width==1 {return scalar(g,1)}
    if op==.Saturate {
        if source:=&g.nodes[a];source.op==.Saturate {return a}
    }
    if is_constant(g,a) {
        v:=g.nodes[a].value
        out:[4]f32
        if op==.Length || op==.Normalize {
            length:f32
            for i in 0..<int(g.nodes[a].width) {length+=v[i]*v[i]}
            length=math.sqrt(length)
            if op==.Length {return scalar(g,length)}
            if length>0 {for i in 0..<int(width) {out[i]=v[i]/length}}
            return constant(g,out,width)
        }
        for i in 0..<int(width) {out[i]=fold_unary(op,v[i])}
        return constant(g,out,width)
    }
    return node_add(g,{op=op,width=width,args={a,NONE,NONE}})
}

@(private)
fold_unary :: proc(op:Op,x:f32) -> f32 {
    #partial switch op {
    case .Abs:return abs(x)
    case .Floor:return math.floor(x)
    case .Ceil:return math.ceil(x)
    case .Frac:return x-math.floor(x)
    case .Round:return math.round(x)
    case .Trunc:return math.trunc(x)
    case .Sqrt:return math.sqrt(max(x,0))
    case .Sin:return math.sin(x)
    case .Cos:return math.cos(x)
    case .Tan:return math.tan(x)
    case .Asin:return math.asin(clamp(x,-1,1))
    case .Acos:return math.acos(clamp(x,-1,1))
    case .Atan:return math.atan(x)
    case .Exp:return math.exp(x)
    case .Exp2:return math.pow(2,x)
    case .Log:return x>0?math.ln(x):0
    case .Log2:return x>0?math.log2(x):0
    case .Saturate:return clamp(x,0,1)
    case .Sign:return x>0?1:x<0?-1:0
    }
    return x
}

binary :: proc(g:^Graph,op:Op,a,b:u32) -> u32 {
    if a==NONE || b==NONE {return NONE}
    wa,wb:=g.nodes[a].width,g.nodes[b].width
    width:=common_width(wa,wb)
    if op==.Cross {
        if wa!=3 || wb!=3 {return NONE}
        width=3
    }
    if width==0 {return NONE}
    if op==.Dot {
        if wa!=wb && wa!=1 && wb!=1 {return NONE}
    }
    ca,cb:=is_constant(g,a),is_constant(g,b)
    if ca && cb {return fold_binary(g,op,a,b,width)}
    // Identities that keep the table small and the images direct.
    #partial switch op {
    case .Mul:
        if ca && all_equal(g,a,1) && wb==width {return b}
        if cb && all_equal(g,b,1) && wa==width {return a}
        if ca && all_equal(g,a,0) || cb && all_equal(g,b,0) {return constant(g,{},width)}
    case .Add:
        if ca && all_equal(g,a,0) && wb==width {return b}
        if cb && all_equal(g,b,0) && wa==width {return a}
    case .Sub:
        if cb && all_equal(g,b,0) && wa==width {return a}
    case .Div:
        if cb && all_equal(g,b,1) && wa==width {return a}
    }
    // (x+o)-(y+o) is x-y: two places of the world are exact relative to each
    // other, without the origin both add.
    if op==.Sub && g.nodes[a].op==.Add && g.nodes[b].op==.Add {
        na,nb:=g.nodes[a],g.nodes[b]
        for i in 0..<2 {
            for j in 0..<2 {
                x,y:=na.args[1-i],nb.args[1-j]
                if na.args[i]==nb.args[j] && width_of(g,x)==width && width_of(g,y)==width {return binary(g,.Sub,x,y)}
            }
        }
    }
    // One order for operands that commute, so a*b and b*a are one node.
    first,second:=a,b
    if (op==.Add || op==.Mul || op==.Min || op==.Max || op==.Dot) && a>b {first,second=b,a}
    return node_add(g,{op=op,width=op==.Dot || op==.Less || op==.Less_Equal?1:width,args={first,second,NONE}})
}

@(private)
all_equal :: proc(g:^Graph,n:u32,value:f32) -> bool {
    node:=&g.nodes[n]
    for i in 0..<int(node.width) {if node.value[i]!=value {return false}}
    return true
}

@(private)
fold_binary :: proc(g:^Graph,op:Op,a,b:u32,width:u8) -> u32 {
    na,nb:=g.nodes[a],g.nodes[b]
    get :: proc(n:Node,i:int) -> f32 {return n.width==1?n.value[0]:n.value[i]}
    out:[4]f32
    #partial switch op {
    case .Dot:
        sum:f32
        for i in 0..<int(width) {sum+=get(na,i)*get(nb,i)}
        return scalar(g,sum)
    case .Cross:
        x,y:=na.value,nb.value
        return constant(g,{x[1]*y[2]-x[2]*y[1],x[2]*y[0]-x[0]*y[2],x[0]*y[1]-x[1]*y[0],0},3)
    case .Less,.Less_Equal:
        x,y:=na.value[0],nb.value[0]
        return scalar(g,(op==.Less?x<y:x<=y)?1:0)
    case:
    }
    for i in 0..<int(width) {
        x,y:=get(na,i),get(nb,i)
        #partial switch op {
        case .Add:out[i]=x+y
        case .Sub:out[i]=x-y
        case .Mul:out[i]=x*y
        case .Div:out[i]=y!=0?x/y:0
        case .Min:out[i]=min(x,y)
        case .Max:out[i]=max(x,y)
        case .Pow:out[i]=x<=2.980233e-8?0:math.pow(x,y)
        case .Fmod:out[i]=y!=0?math.mod(x,y):0
        case .Step:out[i]=y>=x?1:0 // step(edge, x), as HLSL
        case .Atan2:out[i]=math.atan2(x,y)
        }
    }
    return constant(g,out,width)
}

ternary :: proc(g:^Graph,op:Op,a,b,c:u32) -> u32 {
    if a==NONE || b==NONE || c==NONE {return NONE}
    wa,wb,wc:=g.nodes[a].width,g.nodes[b].width,g.nodes[c].width
    width:u8
    #partial switch op {
    case .Lerp:
        width=common_width(wa,wb)
        if width==0 {return NONE}
        // As Unreal, an alpha of another width does not widen the ends: its first component is the alpha.
        if wc!=width && wc!=1 {return ternary(g,op,a,b,component(g,c,0))}
        if is_constant(g,c) && all_equal(g,c,0) {return convert(g,a,width)}
        if is_constant(g,c) && all_equal(g,c,1) {return convert(g,b,width)}
        if a==b {return convert(g,a,width)}
    case .Clamp,.Smoothstep:
        width=common_width(common_width(wa,wb),wc)
        if op==.Clamp {width=wa}
        if width==0 || wb!=1 && wb!=width || wc!=1 && wc!=width {return NONE}
        if op==.Clamp && is_constant(g,b) && is_constant(g,c) && all_equal(g,b,0) && all_equal(g,c,1) {return unary(g,.Saturate,a)}
    case .Select:
        width=common_width(wb,wc)
        if wa!=1 || width==0 {return NONE}
        if is_constant(g,a) {return convert(g,g.nodes[a].value[0]!=0?b:c,width)}
    case:
        return NONE
    }
    if is_constant(g,a) && is_constant(g,b) && is_constant(g,c) {
        get :: proc(n:Node,i:int) -> f32 {return n.width==1?n.value[0]:n.value[i]}
        na,nb,nc:=g.nodes[a],g.nodes[b],g.nodes[c]
        out:[4]f32
        for i in 0..<int(width) {
            x,y,z:=get(na,i),get(nb,i),get(nc,i)
            #partial switch op {
            case .Lerp:out[i]=x+(y-x)*z
            case .Clamp:out[i]=clamp(x,y,z)
            case .Smoothstep:
                t:=clamp(y!=x?(z-x)/(y-x):0,0,1)
                out[i]=t*t*(3-2*t)
            }
        }
        return constant(g,out,width)
    }
    return node_add(g,{op=op,width=width,args={a,b,c}})
}

// The nodes under roots, each once and after its arguments (the order of the
// table: a node is added after its arguments), without going past the
// arguments of a node whose op is in stop.
nodes_under :: proc(g:^Graph,roots:[]u32,stop:bit_set[Op]={},allocator:=context.temp_allocator) -> []u32 {
    seen:=make(map[u32]struct{},allocator=context.temp_allocator)
    stack:=make([dynamic]u32,context.temp_allocator)
    order:=make([dynamic]u32,allocator)
    for r in roots {if r!=NONE {append(&stack,r)}}
    for len(stack)>0 {
        n:=pop(&stack)
        if n in seen {continue}
        seen[n]={}
        append(&order,n)
        if g.nodes[n].op in stop {continue}
        for arg in g.nodes[n].args {if arg!=NONE {append(&stack,arg)}}
    }
    slice.sort(order[:])
    return order[:]
}

// Whether n depends on any node of the ops in kinds.
depends_on :: proc(g:^Graph,n:u32,kinds:bit_set[Op]) -> bool {
    if n==NONE {return false}
    for m in nodes_under(g,{n}) {if g.nodes[m].op in kinds {return true}}
    return false
}

// The value of n when it depends on constants and parameters alone.
evaluate_constant :: proc(g:^Graph,n:u32) -> (value:[4]f32,ok:bool) {
    if n==NONE {return}
    node:=&g.nodes[n]
    #partial switch node.op {
    case .Constant:return node.value,true
    case .Parameter:return g.parameters[node.index].value,true
    }
    order:=nodes_under(g,{n})
    for m in order {if g.nodes[m].op in VARYING {return}}
    values:=make(map[u32][4]f32,len(order),context.temp_allocator)
    texel:Texel_Context
    for m in order {
        args:[3][4]f32
        for arg,i in g.nodes[m].args {if arg!=NONE {args[i]=values[arg]}}
        values[m]=node_compute(g,&g.nodes[m],args,&texel)
    }
    return values[n],true
}
