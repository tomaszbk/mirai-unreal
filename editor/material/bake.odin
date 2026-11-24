package material

import "core:math"
import "mirai:std/jobs"
import mm "mirai:std/math"

// The graph evaluated on the CPU: for constants, and for the images of maps,
// which are per-texel functions of textures that share their coordinates.
// An image is evaluated texel by texel over the coordinates of its map: each
// texture is read there with bilinear filtering and wrapping, and the nodes
// it needs run in the order of the table into one row of values per node.

// A texture as Unreal's sampler reads it: linear values, or a normal map
// unpacked to -1..1 with its Z rebuilt.
Pixels :: struct {
    width,height:int,
    texels:[][4]f32, // rows from the top
}

Texel_Context :: struct {
    uv:[2]f32,          // the coordinates of the map at the texel
    textures:[]^Pixels, // by row of graph.textures; nil: a texture that could not be read, read as white
}

@(private)
pixels_read :: proc(p:^Pixels,uv:[2]f32) -> [4]f32 {
    if p==nil || p.width==0 || p.height==0 {return {1,1,1,1}}
    x:=uv.x*f32(p.width)-0.5
    y:=uv.y*f32(p.height)-0.5
    x0,y0:=math.floor(x),math.floor(y)
    fx,fy:=x-x0,y-y0
    wrap :: proc(v,n:int) -> int {return ((v%n)+n)%n}
    ix,iy:=int(x0),int(y0)
    a:=p.texels[wrap(iy,p.height)*p.width+wrap(ix,p.width)]
    b:=p.texels[wrap(iy,p.height)*p.width+wrap(ix+1,p.width)]
    c:=p.texels[wrap(iy+1,p.height)*p.width+wrap(ix,p.width)]
    d:=p.texels[wrap(iy+1,p.height)*p.width+wrap(ix+1,p.width)]
    return (a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy
}

// One node from the values of its arguments.
@(private)
node_compute :: proc(g:^Graph,node:^Node,args:[3][4]f32,ctx:^Texel_Context) -> (out:[4]f32) {
    w:=int(node.width)
    // The arguments as wide as the node, a scalar repeated.
    wide :: proc(g:^Graph,node:^Node,i:int,args:[3][4]f32) -> [4]f32 {
        n:=node.args[i]
        if n==NONE {return {}}
        v:=args[i]
        if g.nodes[n].width==1 {return {v.x,v.x,v.x,v.x}}
        return v
    }
    a,b,c:=wide(g,node,0,args),wide(g,node,1,args),wide(g,node,2,args)
    #partial switch node.op {
    case .Constant:return node.value
    case .Fresnel:return node.args[0]!=NONE?args[0]:node.value
    case .Parameter:return g.parameters[node.index].value
    case .Sample:
        texture:=g.nodes[node.args[0]].index
        var:^Pixels
        if int(texture)<len(ctx.textures) {var=ctx.textures[texture]}
        return pixels_read(var,ctx.uv)
    case .UV:return {ctx.uv.x,ctx.uv.y,0,0}
    case .Length,.Normalize:
        length:f32
        source:=g.nodes[node.args[0]].width
        for i in 0..<int(source) {length+=args[0][i]*args[0][i]}
        length=math.sqrt(length)
        if node.op==.Length {return {length,0,0,0}}
        if length>0 {for i in 0..<w {out[i]=args[0][i]/length}}
        return
    case .Dot:
        width:=max(int(g.nodes[node.args[0]].width),int(g.nodes[node.args[1]].width))
        for i in 0..<width {out.x+=a[i]*b[i]}
        return
    case .Cross:
        x,y:=args[0],args[1]
        return {x[1]*y[2]-x[2]*y[1],x[2]*y[0]-x[0]*y[2],x[0]*y[1]-x[1]*y[0],0}
    case .Less:return {args[0].x<args[1].x?1:0,0,0,0}
    case .Less_Equal:return {args[0].x<=args[1].x?1:0,0,0,0}
    case .Select:
        if args[0].x!=0 {return b}
        return c
    case .Swizzle:
        for i in 0..<w {out[i]=args[0][node.swizzle[i]]}
        return
    case .Gate:return args[0].x>0?args[1]:c
    case .Append:
        first:=int(g.nodes[node.args[0]].width)
        for i in 0..<first {out[i]=args[0][i]}
        for i in first..<w {out[i]=args[1][i-first]}
        return
    }
    for i in 0..<w {
        x,y,z:=a[i],b[i],c[i]
        #partial switch node.op {
        case .Add:out[i]=x+y
        case .Sub:out[i]=x-y
        case .Mul:out[i]=x*y
        case .Div:out[i]=y!=0?x/y:0
        case .Min:out[i]=min(x,y)
        case .Max:out[i]=max(x,y)
        case .Pow:out[i]=x<=2.980233e-8?0:math.pow(x,y)
        case .Fmod:out[i]=y!=0?math.mod(x,y):0
        case .Step:out[i]=y>=x?1:0
        case .Atan2:out[i]=math.atan2(x,y)
        case .Lerp:out[i]=x+(y-x)*z
        case .Clamp:out[i]=clamp(x,y,z)
        case .Smoothstep:
            t:=clamp(y!=x?(z-x)/(y-x):0,0,1)
            out[i]=t*t*(3-2*t)
        case:out[i]=fold_unary(node.op,x)
        }
    }
    return
}

// What one channel of a map image is stored as.
Channel_Encoding :: enum u8 {Linear,SRGB,Normal}

// The image of a map, as RGBA8 rows from the top: each channel the value
// of its node over the coordinates of the map, at the size of the largest
// texture it reads. With fit, color brighter than 1 (an emission) is divided
// to fit, and scale is what it was divided by: the factor of the map takes it.
// With a worker of a job system, its rows are evaluated on the jobs.
image_bake :: proc(g:^Graph,image:Map_Image,encodings:[4]Channel_Encoding,textures:[]^Pixels,fit:bool,allocator:=context.allocator,worker:=jobs.Worker_Ref{}) -> (pixels:[]u8,width,height:int,scale:[4]f32) {
    roots:=image.channels
    order:=nodes_under(g,roots[:])
    width,height=1,1
    for n in order {
        node:=&g.nodes[n]
        if node.op!=.Sample {continue}
        row:=g.nodes[node.args[0]].index
        if int(row)<len(textures) && textures[row]!=nil {
            width=max(width,textures[row].width)
            height=max(height,textures[row].height)
        }
    }
    plan:=bake_plan(g,roots,textures,width,height)
    plan.encodings,plan.scale=encodings,{1,1,1,1}
    plan.pixels=make([]u8,width*height*4,allocator)
    // An emission is stored once its scale is known.
    plan.evaluate,plan.store=true,!fit || encodings[0]==.Normal
    if !plan.store {plan.out=make([][4]f32,width*height,context.temp_allocator)}
    bake_run(&plan,worker)
    if !plan.store {
        peak:[4]f32
        for texel in plan.out {for c in 0..<4 {peak[c]=max(peak[c],texel[c])}}
        for c in 0..<4 {if peak[c]>1 && encodings[c]==.SRGB {plan.scale[c]=peak[c]}}
        // The color channels keep their ratios: one scale for the three.
        common:=max(plan.scale.x,plan.scale.y,plan.scale.z)
        if common>1 {plan.scale.xyz=common}
        plan.evaluate,plan.store=false,true
        bake_run(&plan,worker)
    }
    return plan.pixels,width,height,plan.scale
}

// Rows of an image a job evaluates at once.
@(private="file")
BAKE_ROWS :: 8

// A node of an image that changes over the map, evaluated a row at a time
// into its own row of values. A node that does not change is evaluated once,
// and a node only the coordinates of a sample read is not: a sample reads
// its texture at the coordinates of the map.
@(private="file")
Bake_Step :: struct {
    node:^Node,
    width:int,
    rows:[3]int,     // of each argument: of a step, the row of zeros or that of a constant (Bake_Plan.constants)
    splat:[3]bool,   // the argument has one component, which a node as wide as it takes for each
    first:int,       // of an Append: the components of its first argument
    texture:^Pixels, // of a Sample; nil reads white
    generic:bool,    // evaluated by node_compute
}

@(private="file")
Bake_Plan :: struct {
    g:^Graph,
    steps:[]Bake_Step,
    constants:[][4]f32, // each in a row after the row of zeros, which follows those of the steps
    roots:[4]int,       // the step of each channel; -1 for one of root_values
    root_values:[4]f32, // of each channel that does not change over the map
    width,height:int,
    encodings:[4]Channel_Encoding,
    scale:[4]f32,
    evaluate,store:bool, // what a pass over the rows does: evaluate them into out or pixels, and store out into pixels
    out:[][4]f32,        // the image before it is stored; nil when it is stored as it is evaluated
    pixels:[]u8,
}

@(private="file")
bake_plan :: proc(g:^Graph,roots:[4]u32,textures:[]^Pixels,width,height:int) -> (plan:Bake_Plan) {
    plan={g=g,width=width,height=height,roots={-1,-1,-1,-1},root_values={1,1,1,1}}
    read:=make([]bool,len(g.nodes),context.temp_allocator)
    stack:=make([dynamic]u32,context.temp_allocator)
    for r in roots {if r!=NONE {append(&stack,r)}}
    for len(stack)>0 {
        n:=pop(&stack)
        if read[n] {continue}
        read[n]=true
        if g.nodes[n].op==.Sample {continue}
        for arg in g.nodes[n].args {if arg!=NONE {append(&stack,arg)}}
    }
    ZERO :: -1 // a constant c is -2-c until the steps are counted
    step_of:=make([]int,len(g.nodes),context.temp_allocator)
    values:=make([][4]f32,len(g.nodes),context.temp_allocator)
    steps:=make([dynamic]Bake_Step,context.temp_allocator)
    constants:=make([dynamic][4]f32,context.temp_allocator)
    constant:Texel_Context
    // The arguments of a node come before it in the table.
    for n in 0..<len(g.nodes) {
        step_of[n]=-1
        if !read[n] {continue}
        node:=&g.nodes[n]
        if node.op==.Texture {continue}
        varying:=node.op==.Sample || node.op==.UV
        if node.op!=.Sample {
            for arg in node.args {varying||=arg!=NONE && step_of[arg]>=0}
        }
        if !varying {
            args:[3][4]f32
            for arg,k in node.args {if arg!=NONE {args[k]=values[arg]}}
            values[n]=node_compute(g,node,args,&constant)
            continue
        }
        s:=Bake_Step{node=node,width=int(node.width),rows={ZERO,ZERO,ZERO}}
        if node.op==.Sample {
            texture:=g.nodes[node.args[0]].index
            if int(texture)<len(textures) {s.texture=textures[texture]}
        } else {
            for arg,k in node.args {
                if arg==NONE {continue}
                s.splat[k]=g.nodes[arg].width==1
                if step_of[arg]>=0 {
                    s.rows[k]=step_of[arg]
                } else {
                    s.rows[k]=-2-len(constants)
                    append(&constants,values[arg])
                }
            }
            if node.op==.Append {s.first=int(g.nodes[node.args[0]].width)}
        }
        // What is not of four components is node_compute's to refuse.
        s.generic=s.width>4 || s.first>4
        for i in 0..<4 {s.generic||=node.op==.Swizzle && node.swizzle[i]>3}
        step_of[n]=len(steps)
        append(&steps,s)
    }
    for &s in steps {
        for &r in s.rows {
            if r==ZERO {r=len(steps)} else if r<ZERO {r=len(steps)+1+(-2-r)}
        }
    }
    for root,c in roots {
        if root==NONE {continue}
        if step_of[root]>=0 {plan.roots[c]=step_of[root]} else {plan.root_values[c]=values[root].x}
    }
    plan.steps,plan.constants=steps[:],constants[:]
    return
}

@(private="file")
bake_run :: proc(plan:^Bake_Plan,worker:jobs.Worker_Ref) {
    if worker.system!=nil && plan.height>BAKE_ROWS {
        jobs.parallel_for(worker.system,worker.worker,plan.height,BAKE_ROWS,bake_rows,plan)
    } else {
        bake_rows(plan,0,plan.height,worker.worker)
    }
}

// A pass over the rows first..<last of the image of plan.
@(private="file")
bake_rows :: proc(plan:^Bake_Plan,first,last:int,worker:int) {
    width:=plan.width
    rows:[][4]f32
    texels:[][4]f32
    if plan.evaluate {
        rows=make([][4]f32,(len(plan.steps)+1+len(plan.constants))*width,context.temp_allocator)
        for value,i in plan.constants {
            for &texel in rows[(len(plan.steps)+1+i)*width:][:width] {texel=value}
        }
        if plan.out==nil {texels=make([][4]f32,width,context.temp_allocator)}
    }
    for y in first..<last {
        if plan.out!=nil {texels=plan.out[y*width:][:width]}
        if plan.evaluate {
            v:=(f32(y)+0.5)/f32(plan.height)
            for &s,i in plan.steps {step_row(plan.g,&s,rows,rows[i*width:][:width],width,v)}
            for &texel in texels {texel=plan.root_values}
            for step,c in plan.roots {
                if step<0 {continue}
                #no_bounds_check for value,x in rows[step*width:][:width] {texels[x][c]=value.x}
            }
            // A normal is stored normalized.
            if plan.encodings[0]==.Normal {
                for &texel in texels {
                    n:=texel.xyz
                    length:=math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
                    texel.xyz=length>0?n/length:{0,0,1}
                }
            }
        }
        if !plan.store {continue}
        out:=plan.pixels[y*width*4:][:width*4]
        #no_bounds_check for texel,x in texels {
            for c in 0..<4 {
                v:=texel[c]/plan.scale[c]
                switch plan.encodings[c] {
                case .Linear:v=clamp(v,0,1)
                case .SRGB:v=mm.linear_to_srgb(clamp(v,0,1))
                case .Normal:v=clamp(v*0.5+0.5,0,1)
                }
                out[x*4+c]=u8(v*255+0.5)
            }
        }
    }
}

// The row of a step at the coordinate v of the map, from the rows before
// it, as node_compute gives each texel.
@(private="file")
step_row :: proc(g:^Graph,s:^Bake_Step,rows,out:[][4]f32,width:int,v:f32) {
    a,b,c:=rows[s.rows[0]*width:][:width],rows[s.rows[1]*width:][:width],rows[s.rows[2]*width:][:width]
    if s.generic {
        ctx:Texel_Context
        for &o,x in out {
            ctx.uv={(f32(x)+0.5)/f32(width),v}
            o=node_compute(g,s.node,{a[x],b[x],c[x]},&ctx)
        }
        return
    }
    // The arguments as wide as the node, a scalar repeated.
    wide :: #force_inline proc(s:^Bake_Step,k:int,v:[4]f32) -> [4]f32 {return v.xxxx if s.splat[k] else v}
    // Of the ops whose components do not mix, each of four at once and those past the width zero.
    lanes :: proc(s:^Bake_Step,a,b,c,out:[][4]f32,$op:Op) #no_bounds_check {
        for &o,column in out {
            x:=column
            r:[4]f32
            when op==.Add {r=wide(s,0,a[x])+wide(s,1,b[x])}
            else when op==.Sub {r=wide(s,0,a[x])-wide(s,1,b[x])}
            else when op==.Mul {r=wide(s,0,a[x])*wide(s,1,b[x])}
            else when op==.Lerp {
                p,q,t:=wide(s,0,a[x]),wide(s,1,b[x]),wide(s,2,c[x])
                r=p+(q-p)*t
            } else {
                p,q,t:=wide(s,0,a[x]),wide(s,1,b[x]),wide(s,2,c[x])
                for i in 0..<4 {
                    e,f,h:=p[i],q[i],t[i]
                    when op==.Div {r[i]=f!=0?e/f:0}
                    else when op==.Min {r[i]=min(e,f)}
                    else when op==.Max {r[i]=max(e,f)}
                    else when op==.Pow {r[i]=e<=2.980233e-8?0:math.pow(e,f)}
                    else when op==.Clamp {r[i]=clamp(e,f,h)}
                    else {r[i]=fold_unary(s.node.op,e)}
                }
            }
            for i in s.width..<4 {r[i]=0}
            o=r
        }
    }
    #partial switch s.node.op {
    case .Sample:sample_row(s.texture,out,width,v)
    case .UV:for &o,x in out {o={(f32(x)+0.5)/f32(width),v,0,0}}
    case .Swizzle:
        // Its components were checked to be of four (bake_plan).
        swizzle:=s.node.swizzle
        if s.width==1 {
            #no_bounds_check for &o,x in out {o={a[x][swizzle[0]],0,0,0}}
        } else {
            #no_bounds_check for &o,x in out {
                t:=a[x]
                r:=[4]f32{t[swizzle[0]],t[swizzle[1]],t[swizzle[2]],t[swizzle[3]]}
                for i in s.width..<4 {r[i]=0}
                o=r
            }
        }
    case .Append:
        for &o,x in out {
            r:[4]f32
            for i in 0..<s.first {r[i]=a[x][i]}
            for i in s.first..<s.width {r[i]=b[x][i-s.first]}
            o=r
        }
    case .Add:lanes(s,a,b,c,out,.Add)
    case .Sub:lanes(s,a,b,c,out,.Sub)
    case .Mul:lanes(s,a,b,c,out,.Mul)
    case .Div:lanes(s,a,b,c,out,.Div)
    case .Min:lanes(s,a,b,c,out,.Min)
    case .Max:lanes(s,a,b,c,out,.Max)
    case .Pow:lanes(s,a,b,c,out,.Pow)
    case .Lerp:lanes(s,a,b,c,out,.Lerp)
    case .Clamp:lanes(s,a,b,c,out,.Clamp)
    case .Abs,.Floor,.Ceil,.Frac,.Round,.Trunc,.Sqrt,.Sin,.Cos,.Tan,.Asin,.Acos,.Atan,.Exp,.Exp2,.Log,.Log2,.Saturate,.Sign:lanes(s,a,b,c,out,.Abs)
    case:
        ctx:Texel_Context
        for &o,x in out {
            ctx.uv={(f32(x)+0.5)/f32(width),v}
            o=node_compute(g,s.node,{a[x],b[x],c[x]},&ctx)
        }
    }
}

// A row of a texture read as pixels_read reads it, at the coordinate v of
// the map and the u of each of the width texels of out.
@(private="file")
sample_row :: proc(p:^Pixels,out:[][4]f32,width:int,v:f32) {
    if p==nil || p.width==0 || p.height==0 {
        for &o in out {o={1,1,1,1}}
        return
    }
    wrap :: #force_inline proc(v,n:int) -> int {
        if v>=0 && v<n {return v}
        return ((v%n)+n)%n
    }
    y:=v*f32(p.height)-0.5
    y0:=math.floor(y)
    fy:=y-y0
    iy:=int(y0)
    above:=p.texels[wrap(iy,p.height)*p.width:][:p.width]
    below:=p.texels[wrap(iy+1,p.height)*p.width:][:p.width]
    #no_bounds_check for &o,column in out {
        x:=((f32(column)+0.5)/f32(width))*f32(p.width)-0.5
        x0:=math.floor(x)
        fx:=x-x0
        ix:=int(x0)
        left,right:=wrap(ix,p.width),wrap(ix+1,p.width)
        a,b,c,d:=above[left],above[right],below[left],below[right]
        o=(a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy
    }
}

// Whether a map image is a texture read as it is: each channel that matters
// the same channel of one sample. The texture and its coordinates are given.
image_direct :: proc(g:^Graph,image:Map_Image,relevant:[4]bool) -> (texture:int,ok:bool) {
    texture=-1
    for root,c in image.channels {
        if !relevant[c] {continue}
        if root==NONE {return -1,false}
        node:=g.nodes[root]
        if node.op!=.Swizzle || node.width!=1 || int(node.swizzle[0])!=c {return -1,false}
        source:=g.nodes[node.args[0]]
        if source.op!=.Sample {return -1,false}
        row:=int(g.nodes[source.args[0]].index)
        if texture>=0 && row!=texture {return -1,false}
        texture=row
    }
    return texture,texture>=0
}
