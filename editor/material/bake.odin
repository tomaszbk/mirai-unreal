package material

import "core:math"
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
    case .Constant,.Fresnel:return node.value
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
image_bake :: proc(g:^Graph,image:Map_Image,encodings:[4]Channel_Encoding,textures:[]^Pixels,fit:bool,allocator:=context.allocator) -> (pixels:[]u8,width,height:int,scale:[4]f32) {
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
    slot:=make([]int,len(g.nodes),context.temp_allocator)
    for n,i in order {slot[n]=i}
    values:=make([][4]f32,len(order),context.temp_allocator)
    out:=make([][4]f32,width*height,context.temp_allocator)
    ctx:=Texel_Context{textures=textures}
    for y in 0..<height {
        for x in 0..<width {
            ctx.uv={(f32(x)+0.5)/f32(width),(f32(y)+0.5)/f32(height)}
            for n,i in order {
                node:=&g.nodes[n]
                if node.op==.Texture {continue}
                args:[3][4]f32
                for arg,k in node.args {if arg!=NONE {args[k]=values[slot[arg]]}}
                values[i]=node_compute(g,node,args,&ctx)
            }
            texel:[4]f32={1,1,1,1}
            for root,c in roots {if root!=NONE {texel[c]=values[slot[root]].x}}
            out[y*width+x]=texel
        }
    }
    // A normal is stored normalized; values above 1 are scaled into range.
    scale={1,1,1,1}
    if encodings[0]==.Normal {
        for &texel in out {
            n:=texel.xyz
            length:=math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
            texel.xyz=length>0?n/length:{0,0,1}
        }
    } else if fit {
        peak:[4]f32
        for texel in out {for c in 0..<4 {peak[c]=max(peak[c],texel[c])}}
        for c in 0..<4 {if peak[c]>1 && encodings[c]==.SRGB {scale[c]=peak[c]}}
        // The color channels keep their ratios: one scale for the three.
        common:=max(scale.x,scale.y,scale.z)
        if common>1 {scale.xyz=common}
    }
    pixels=make([]u8,width*height*4,allocator)
    for texel,i in out {
        for c in 0..<4 {
            v:=texel[c]/scale[c]
            switch encodings[c] {
            case .Linear:v=clamp(v,0,1)
            case .SRGB:v=mm.linear_to_srgb(clamp(v,0,1))
            case .Normal:v=clamp(v*0.5+0.5,0,1)
            }
            pixels[i*4+c]=u8(v*255+0.5)
        }
    }
    return
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
