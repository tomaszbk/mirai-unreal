package material

import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"

// A Surface program written from the graph. Each node an output reads is a
// local, in the order of the table (an argument always comes first). Unreal
// works in centimetres with Z up; positions and normals of the context are
// taken to that space where the graph reads them. The program is named by
// what it computes: instances that only change parameter values share it.

@(private) MAX_PROGRAM_BYTES :: 256
@(private) MAX_PROGRAM_FIELDS :: 32

@(private)
Emitter :: struct {
    g:^Graph,
    body:strings.Builder,
    emitted:[]bool,
    fields:[]string,       // of each node that is a parameter or texture: its field
    parameters:[dynamic]Program_Parameter,
    folded:map[u32]bool,   // parameters left as constants, over the budget
    scopes:[]u32,          // of each node: SCOPE_OUTER, the weight of its branch, or NONE when unread
    failed:string,
}

@(private) SCOPE_OUTER :: NONE-1

@(private)
type_name :: proc(width:u8) -> string {
    switch width {
    case 1:return "float"
    case 2:return "float2"
    case 3:return "float3"
    case 4:return "float4"
    }
    return "uint"
}

@(private)
float_text :: proc(value:f32) -> string {
    if value!=value {return "0.0"}
    if value>3.4e38 {return "3.4e38"}
    if value< -3.4e38 {return "-3.4e38"}
    // The shortest text that reads back as the same float.
    text:=fmt.tprintf("%v",value)
    if !strings.contains_any(text,".eEni") {text=fmt.tprintf("%s.0",text)}
    return text
}

@(private)
literal :: proc(value:[4]f32,width:u8) -> string {
    if width==1 {return float_text(value.x)}
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"%s(",type_name(width))
    for i in 0..<int(width) {fmt.sbprintf(&b,"%s%s",i>0?",":"",float_text(value[i]))}
    strings.write_string(&b,")")
    return strings.to_string(b)
}

// The text of a node as an operand of width: a local, a constant or a field,
// with a scalar repeated where a vector is wanted.
@(private)
operand :: proc(m:^Emitter,n:u32,width:u8=0) -> string {
    node:=&m.g.nodes[n]
    text:string
    switch {
    case node.op==.Constant || node.op==.Fresnel:text=literal(node.value,node.width)
    case node.op==.Parameter && m.folded[n]:text=literal(m.g.parameters[node.index].value,node.width)
    case node.op==.Parameter || node.op==.Texture:text=fmt.tprintf("p.%s",m.fields[n])
    case:text=fmt.tprintf("v%d",n)
    }
    // A negative constant after an operator is not a decrement.
    if strings.has_prefix(text,"-") {text=fmt.tprintf("(%s)",text)}
    if width>1 && node.width==1 {return fmt.tprintf("%s(%s)",type_name(width),text)}
    // A wider value keeps its first components, as Unreal casts.
    if width>0 && width<node.width {
        letters:="xyzw"
        return fmt.tprintf("(%s).%s",text,letters[:width])
    }
    return text
}

// A node of the outer scope, after its arguments. A gate opens the branch
// of its weight, with every gate of that weight.
@(private)
emit :: proc(m:^Emitter,n:u32) {
    if n==NONE || m.failed!="" || m.emitted[n] {return}
    node:=m.g.nodes[n]
    if node.op==.Gate && m.scopes[n]==SCOPE_OUTER {
        branch_emit(m,node.args[0])
        return
    }
    m.emitted[n]=true
    for arg in node.args {if arg!=NONE {emit(m,arg)}}
    line_emit(m,n,"    ")
}

// The branch on weight: what only its gates read, computed where the weight
// passes zero; each gate is its value there and the other value elsewhere.
@(private)
branch_emit :: proc(m:^Emitter,weight:u32) {
    g:=m.g
    emit(m,weight)
    inner:=make([dynamic]u32,context.temp_allocator)
    gates:=make([dynamic]u32,context.temp_allocator)
    for node,n in g.nodes {
        if m.scopes[n]==weight {append(&inner,u32(n))}
        if node.op==.Gate && node.args[0]==weight && m.scopes[n]==SCOPE_OUTER {append(&gates,u32(n))}
    }
    for n in inner {for arg in g.nodes[n].args {if arg!=NONE && m.scopes[arg]!=weight {emit(m,arg)}}}
    for n in gates {for arg in g.nodes[n].args[1:] {if m.scopes[arg]!=weight {emit(m,arg)}}}
    if m.failed!="" {return}
    for n in gates {
        m.emitted[n]=true
        w:=g.nodes[n].width
        fmt.sbprintf(&m.body,"    %s v%d=%s;\n",type_name(w),n,operand(m,g.nodes[n].args[2],w))
    }
    fmt.sbprintf(&m.body,"    if (%s>0.0) {{\n",operand(m,weight))
    for n in inner {
        m.emitted[n]=true
        line_emit(m,n,"        ")
    }
    for n in gates {fmt.sbprintf(&m.body,"        v%d=%s;\n",n,operand(m,g.nodes[n].args[1],g.nodes[n].width))}
    strings.write_string(&m.body,"    }\n")
}

// The scope each node the outputs read is computed in: the branch of the
// weight of the gates that alone read it, or the outer one.
@(private)
scopes_plan :: proc(g:^Graph,outputs:[]u32) -> []u32 {
    scopes:=make([]u32,len(g.nodes),context.temp_allocator)
    for &s in scopes {s=NONE}
    join :: proc(scopes:[]u32,n,scope:u32) {
        if scopes[n]==NONE {scopes[n]=scope} else if scopes[n]!=scope {scopes[n]=SCOPE_OUTER}
    }
    for n in outputs {if n!=NONE {join(scopes,n,SCOPE_OUTER)}}
    for n:=len(g.nodes)-1;n>=0;n-=1 {
        scope:=scopes[n]
        if scope==NONE {continue}
        node:=g.nodes[n]
        for arg,i in node.args {
            if arg==NONE {continue}
            join(scopes,arg,node.op==.Gate && i==1 && scope==SCOPE_OUTER?node.args[0]:scope)
        }
    }
    return scopes
}

@(private)
line_emit :: proc(m:^Emitter,n:u32,indent:string) {
    if m.failed!="" {return}
    node:=m.g.nodes[n]
    if node.op==.Constant || node.op==.Parameter || node.op==.Texture || node.op==.Arguments {return}
    w:=node.width
    a,b,c:=node.args[0],node.args[1],node.args[2]
    code:string
    #partial switch node.op {
    case .Noise:
        s:=m.g.noises[node.index]
        code=fmt.tprintf("MaterialExpressionNoise%s(%s,%s,%d,%d,%v,%d,%s,%s,%s,%s,%v,%s)",s.world?"World":"",operand(m,a),float_text(s.scale),
            s.quality,s.function,s.turbulence,s.levels,float_text(s.output_min),float_text(s.output_max),float_text(s.level_scale),
            operand(m,b),s.tiling,float_text(s.repeat_size))
    case .Vector_Noise:
        s:=m.g.noises[node.index]
        code=fmt.tprintf("MaterialExpressionVectorNoise(%s,%d,%d,%v,%s)%s",operand(m,a),s.quality,s.function,s.tiling,float_text(s.repeat_size),w==3?".xyz":"")
    case .Custom:
        call:=strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&call,"unreal_custom_%d(ctx",node.index)
        for list:=a;list!=NONE;list=m.g.nodes[list].args[1] {
            value:=m.g.nodes[list].args[0]
            fmt.sbprintf(&call,",%s",operand(m,value))
            if m.g.nodes[value].op==.Texture {strings.write_string(&call,",0u")}
        }
        for out,k in m.g.customs[node.index].outputs {
            fmt.sbprintf(&m.body,"%s%s v%d_%d=%s;\n",indent,type_name(out.width),n,k+1,literal({},out.width))
            fmt.sbprintf(&call,",v%d_%d",n,k+1)
        }
        strings.write_string(&call,")")
        code=strings.to_string(call)
    case .Custom_Output:code=fmt.tprintf("v%d_%d",a,node.index)
    case .Sample:
        uv_set:=uv_set_of(m.g,b)
        lod:=uv_set==1?"ctx.lod1":"ctx.lod"
        sampled:=fmt.tprintf("mirai_sample_texture(ctx,%s,%s,%s)",operand(m,a),operand(m,b),lod)
        if m.g.textures[m.g.nodes[a].index].sampler==.Normal {sampled=fmt.tprintf("unreal_normal(%s)",sampled)}
        code=sampled
    case .UV:code=node.index==1?"ctx.uv1":"ctx.uv0"
    case .Time:code="ctx.time"
    case .World_Position:code="unreal_point(ctx.world_position)"
    case .Origin:code="unreal_origin(ctx)"
    case .Object_Bounds:code=fmt.tprintf("unreal_object_bounds(ctx,%d)",node.index)
    case .Screen_Position:code="ctx.screen"
    case .Screen_Size:code="ctx.screen_size"
    case .Pixel_Depth:code="ctx.depth*100.0"
    case .Scene_Depth:code="ctx.scene_depth*100.0"
    case .Particle_Data:code=fmt.tprintf("(((ctx.particle_given>>%du)&1u)!=0u?ctx.particle_data[%d]:%s)",node.index,node.index,literal(node.value,4))
    case .Texture_Size:code=fmt.tprintf("mirai_texture_size(%s)",operand(m,a))
    case .Texture_Read:
        read:=m.g.textures[node.index].read
        code=fmt.tprintf("%s(\"%s\",%s)",read.function,read.name,operand(m,a))
    case .Vertex_Normal:code="float3(ctx.vertex_normal.z,-ctx.vertex_normal.x,ctx.vertex_normal.y)"
    case .Vertex_Tangent:code="float3(ctx.tangent.z,-ctx.tangent.x,ctx.tangent.y)"
    case .Vertex_Bitangent:code="unreal_bitangent(ctx)"
    case .Pixel_Normal:code="float3(ctx.normal.z,-ctx.normal.x,ctx.normal.y)"
    case .Vertex_Color:code="ctx.vertex_color"
    case .Object_Position:code="unreal_point(ctx.object_center)"
    case .Actor_Position:code="unreal_point(ctx.object_position)"
    case .Object_Radius:code="ctx.object_radius*100.0"
    case .Object_Axis:code=fmt.tprintf("unreal_object_axis(ctx,%d)",node.index)
    case .Layer_Weights:code="float4(ctx.uv0,ctx.uv1)"
    case .Abs,.Floor,.Ceil,.Frac,.Round,.Trunc,.Sin,.Cos,.Tan,.Asin,.Acos,.Atan,.Exp,.Exp2,.Log,.Log2,.Saturate,.Sign,.Length,.Normalize:
        names:=#partial [Op]string{.Abs="abs",.Floor="floor",.Ceil="ceil",.Frac="frac",.Round="round",.Trunc="trunc",.Sin="sin",.Cos="cos",
            .Tan="tan",.Asin="asin",.Acos="acos",.Atan="atan",.Exp="exp",.Exp2="exp2",.Log="log",.Log2="log2",.Saturate="saturate",
            .Sign="sign",.Length="length",.Normalize="normalize"}
        code=fmt.tprintf("%s(%s)",names[node.op],operand(m,a))
    case .Sqrt:code=fmt.tprintf("sqrt(max(%s,0.0))",operand(m,a))
    case .Add,.Sub,.Mul,.Div:
        symbol:=#partial [Op]string{.Add="+",.Sub="-",.Mul="*",.Div="/"}
        code=fmt.tprintf("%s%s%s",operand(m,a,w),symbol[node.op],operand(m,b,w))
    case .Min,.Max,.Fmod,.Step,.Atan2:
        names:=#partial [Op]string{.Min="min",.Max="max",.Fmod="fmod",.Step="step",.Atan2="atan2"}
        code=fmt.tprintf("%s(%s,%s)",names[node.op],operand(m,a,w),operand(m,b,w))
    case .Pow:
        edge:=fmt.tprintf("%s(2.980233e-8)",type_name(w))
        code=fmt.tprintf("pow(max(%s,%s),%s)*step(%s,%s)",operand(m,a,w),edge,operand(m,b,w),edge,operand(m,a,w))
    case .Dot:
        width:=max(m.g.nodes[a].width,m.g.nodes[b].width)
        code=fmt.tprintf("dot(%s,%s)",operand(m,a,width),operand(m,b,width))
    case .Cross:code=fmt.tprintf("cross(%s,%s)",operand(m,a),operand(m,b))
    case .Less:code=fmt.tprintf("(%s<%s?1.0:0.0)",operand(m,a),operand(m,b))
    case .Less_Equal:code=fmt.tprintf("(%s<=%s?1.0:0.0)",operand(m,a),operand(m,b))
    case .Lerp:code=fmt.tprintf("lerp(%s,%s,%s)",operand(m,a,w),operand(m,b,w),operand(m,c,w))
    case .Clamp:code=fmt.tprintf("clamp(%s,%s,%s)",operand(m,a,w),operand(m,b,w),operand(m,c,w))
    case .Smoothstep:code=fmt.tprintf("smoothstep(%s,%s,%s)",operand(m,a,w),operand(m,b,w),operand(m,c,w))
    case .Select:code=fmt.tprintf("(%s!=0.0?%s:%s)",operand(m,a),operand(m,b,w),operand(m,c,w))
    case .Swizzle:
        source:=m.g.nodes[a]
        if source.width==1 {
            code=w==1?operand(m,a):fmt.tprintf("%s(%s)",type_name(w),operand(m,a))
        } else {
            letters:="xyzw"
            mask:=strings.builder_make(context.temp_allocator)
            for i in 0..<int(w) {strings.write_byte(&mask,letters[node.swizzle[i]])}
            code=fmt.tprintf("(%s).%s",operand(m,a),strings.to_string(mask))
        }
    case .Append:code=fmt.tprintf("%s(%s,%s)",type_name(w),operand(m,a),operand(m,b))
    // A gate inside the branch of another weight is its value.
    case .Gate:code=operand(m,b,w)
    case:
        m.failed=fmt.tprintf("%v: Mirai programs have no value for it",node.op)
        return
    }
    fmt.sbprintf(&m.body,"%s%s v%d=%s;\n",indent,type_name(w),n,code)
}

@(private)
uv_set_of :: proc(g:^Graph,n:u32) -> u32 {
    if n==NONE {return 0}
    node:=g.nodes[n]
    if node.op==.UV {return node.index}
    for arg in node.args {
        if arg!=NONE {
            if depends_on(g,arg,{.UV}) {return uv_set_of(g,arg)}
        }
    }
    return 0
}

@(private)
identifier :: proc(text:string,prefix:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,prefix)
    for c in transmute([]u8)text {
        ok:=c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9'
        strings.write_byte(&b,ok?c:'_')
    }
    return strings.to_string(b)
}

// The parameters a program reads, in an order that packs them in rows of 16
// bytes: textures and four-component values, a three-component value with a
// scalar, two-component values in pairs. Those that do not fit stay constants.
@(private)
fields_plan :: proc(m:^Emitter,used:[]u32) -> bool {
    g:=m.g
    widths:=[]u8{0,4,3,2,1}
    bytes,count:=0,0
    texture_index,parameter_index:=0,0
    taken:=make([]bool,len(used),context.temp_allocator)
    // Textures first: they cannot be folded.
    for n,i in used {
        node:=g.nodes[n]
        if node.op!=.Texture {continue}
        taken[i]=true
        ref:=g.textures[node.index]
        name:=identifier(ref.parameter!=""?ref.parameter:ref.name,fmt.tprintf("t%d_",texture_index))
        texture_index+=1
        m.fields[n]=strings.clone(name,m.parameters.allocator)
        append(&m.parameters,Program_Parameter{name=m.fields[n],source=ref.path,kind=.Texture,components=1,texture=int(node.index)})
        bytes+=4
        count+=1
    }
    if bytes>MAX_PROGRAM_BYTES || count>MAX_PROGRAM_FIELDS {return false}
    for width in widths[1:] {
        for n,i in used {
            if taken[i] || g.nodes[n].width!=width {continue}
            taken[i]=true
            node:=g.nodes[n]
            size:=int(width)*4
            // A field does not cross a row of 16 bytes.
            start:=bytes
            if start/16!=(start+size-1)/16 {start=(start+15)/16*16}
            if start+size>MAX_PROGRAM_BYTES || count+1>MAX_PROGRAM_FIELDS {
                m.folded[n]=true
                continue
            }
            bytes=start+size
            count+=1
            p:=g.parameters[node.index]
            name:=identifier(p.name,fmt.tprintf("p%d_",parameter_index))
            parameter_index+=1
            m.fields[n]=strings.clone(name,m.parameters.allocator)
            append(&m.parameters,Program_Parameter{name=m.fields[n],source=strings.clone(p.name,m.parameters.allocator),kind=.Float,components=width,value=p.value,texture=-1})
        }
    }
    return true
}

@(private)
collect_leaves :: proc(g:^Graph,n:u32,seen:[]bool,out:^[dynamic]u32) {
    if n==NONE || seen[n] {return}
    seen[n]=true
    node:=g.nodes[n]
    if node.op==.Parameter || node.op==.Texture {append(out,n)}
    for arg in node.args {collect_leaves(g,arg,seen,out)}
}

// Writes the program of a material whose outputs the standard model cannot
// hold; on failure the material keeps its standard values and a note says why.
@(private)
program_build :: proc(t:^Translated_Material,e:^Evaluator,base_color,alpha,metallic,roughness,specular,occlusion,emissive,normal:u32,roots:[Attribute]u32,shading:Shading) {
    g:=&t.graph
    out:=t.allocator
    // A normal the standard model holds as a map stays one; the program sees it in ctx.normal.
    map_normal:=normal==NONE || is_constant(g,normal) && g.nodes[normal].value.x==0 && g.nodes[normal].value.y==0
    // A landscape turns its normal by its own frame, not by the tangents of
    // the terrain: the normal is in the world, in Unreal's axes.
    landscape:=e.landscape!=nil
    normal:=normal
    if landscape {
        for &image in t.images {image=MAP_NONE}
        if !map_normal {
            tangent,bitangent,vertex_normal:=tangent_frame(e)
            normal=frame_vector(g,convert(g,normal,3),tangent,bitangent,vertex_normal)
        }
    } else if !map_normal && normal_map(t,e,normal) {map_normal=true}
    outputs:=[?]u32{base_color,alpha,metallic,roughness,specular,occlusion,emissive,map_normal?NONE:normal,
        shading==.Clear_Coat?roots[.Clear_Coat]:NONE,shading==.Clear_Coat?roots[.Clear_Coat_Roughness]:NONE,
        shading!=.Cloth?e.fuzz[0]:NONE,shading!=.Cloth?e.fuzz[1]:NONE,e.diffuse_transmission[0],e.diffuse_transmission[1]}
    m:=Emitter{g=g}
    m.scopes=scopes_plan(g,outputs[:])
    m.emitted=make([]bool,len(g.nodes),context.temp_allocator)
    m.fields=make([]string,len(g.nodes),context.temp_allocator)
    m.parameters.allocator=out
    m.folded.allocator=context.temp_allocator
    strings.builder_init(&m.body,context.temp_allocator)
    seen:=make([]bool,len(g.nodes),context.temp_allocator)
    leaves:=make([dynamic]u32,context.temp_allocator)
    for n in outputs {collect_leaves(g,n,seen,&leaves)}
    planned:=fields_plan(&m,leaves[:])
    if planned {for n in outputs {emit(&m,n)}}
    if !planned || m.failed!="" {
        if !planned {
            note(e,"the program needs more than %d bytes of textures; the material keeps its constant values",MAX_PROGRAM_BYTES)
        } else {
            note(e,"no program could be written (%s); the material keeps its constant values",m.failed)
        }
        // The maps the standard model set before it gave up are partial.
        for &image in t.images {image=MAP_NONE}
        t.info.maps=asset.MATERIAL_DEFAULTS.maps
        return
    }
    b:=&m.body
    set :: proc(b:^strings.Builder,m:^Emitter,field:string,n:u32,width:u8) {
        if n==NONE {return}
        fmt.sbprintf(b,"    s.%s=%s;\n",field,operand(m,n,width))
    }
    if shading==.Unlit {
        strings.write_string(b,"    s.unlit=true;\n")
        set(b,&m,"emission",emissive,3)
        set(b,&m,"base_color",base_color,3)
    } else {
        set(b,&m,"base_color",base_color,3)
        set(b,&m,"metallic",metallic,1)
        set(b,&m,"roughness",roughness,1)
        set(b,&m,"occlusion",occlusion,1)
        set(b,&m,"emission",emissive,3)
        if specular!=NONE {fmt.sbprintf(b,"    unreal_specular(s,%s);\n",operand(&m,specular,1))}
        if !map_normal && landscape {
            fmt.sbprintf(b,"    s.normal=normalize(unreal_to_mirai(%s));\n",operand(&m,normal,3))
        } else if !map_normal {
            fmt.sbprintf(b,"    s.normal=normalize(unreal_tangent_to_world(ctx,%s));\n",operand(&m,normal,3))
        }
        if shading==.Clear_Coat {
            set(b,&m,"coat_weight",outputs[8],1)
            set(b,&m,"coat_roughness",outputs[9],1)
            strings.write_string(b,"    s.coat_ior=1.5;s.coat_normal=normalize(s.normal);\n")
        }
        set(b,&m,"fuzz_color",outputs[10],3)
        set(b,&m,"fuzz_weight",outputs[11],1)
        set(b,&m,"diffuse_transmission_color",outputs[12],3)
        set(b,&m,"diffuse_transmission_weight",outputs[13],1)
    }
    if alpha!=NONE {set(b,&m,"alpha",alpha,1)}
    body:=strings.to_string(m.body)
    // Unreal's noise and the functions of its custom HLSL.
    functions:=strings.builder_make(context.temp_allocator)
    unreal_shared:=false
    customs:=false
    includes:=make([dynamic]string,context.temp_allocator)
    for emitted,n in m.emitted {
        if !emitted {continue}
        #partial switch g.nodes[n].op {
        case .Vertex_Color:t.vertex_colors=.Program
        case .Noise,.Vector_Noise:unreal_shared=true
        case .Texture_Read:
            include:=g.textures[g.nodes[n].index].read.include
            if include!="" && !slice.contains(includes[:],include) {append(&includes,include)}
        case .Custom:
            unreal_shared,customs=true,true
            custom_function(&functions,&m,u32(n))
        }
    }

    // The name of the program: the material and what the program computes.
    signature:=strings.builder_make(context.temp_allocator)
    for p in m.parameters {fmt.sbprintf(&signature,"%s:%v:%d;",p.name,p.kind,p.components)}
    strings.write_string(&signature,strings.to_string(functions))
    strings.write_string(&signature,body)
    hash:=base.hash64(transmute([]u8)strings.to_string(signature))
    name:=fmt.aprintf("%s_%08x",identifier(t.material,"Unreal_"),u32(hash),allocator=out)

    source:=strings.builder_make(out)
    fmt.sbprintf(&source,"//! mirai surface %s\n",name)
    for p in m.parameters {
        if p.kind==.Texture {
            ref:=g.textures[p.texture]
            fmt.sbprintf(&source,"//! parameter %s {{\"kind\":\"texture\",\"srgb\":%v,\"normal\":%v}}\n",p.name,ref.sampler==.Color,ref.sampler==.Normal)
            continue
        }
        node_default:=[4]f32{}
        for &q in g.parameters {if identifier_matches(p,q) {node_default=q.default;break}}
        fmt.sbprintf(&source,"//! parameter %s {{\"default\":",p.name)
        if p.components==1 {
            strings.write_string(&source,float_text(node_default.x))
        } else {
            strings.write_string(&source,"[")
            for i in 0..<int(p.components) {fmt.sbprintf(&source,"%s%s",i>0?",":"",float_text(node_default[i]))}
            strings.write_string(&source,"]")
        }
        strings.write_string(&source,"}\n")
    }
    fmt.sbprintf(&source,"// Translated from the Unreal material %s.\n",t.material)
    if unreal_shared {strings.write_string(&source,"#include \"unreal_noise.slang\"\n")}
    for include in includes {fmt.sbprintf(&source,"#include \"%s\"\n",include)}
    if customs {strings.write_string(&source,CUSTOM_PRELUDE)}
    fmt.sbprintf(&source,"namespace %s {{\nstruct Parameters {{",name)
    for p in m.parameters {fmt.sbprintf(&source,"%s %s;",p.kind==.Texture?"uint":type_name(p.components),p.name)}
    strings.write_string(&source,"};\n")
    strings.write_string(&source,PROGRAM_HELPERS)
    strings.write_string(&source,strings.to_string(functions))
    strings.write_string(&source,"Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {\n    Mirai_Surface s=mirai_surface_default(ctx);\n")
    strings.write_string(&source,body)
    strings.write_string(&source,"    return s;\n}\n}\n")
    t.program={name=name,source=strings.to_string(source),parameters=m.parameters[:]}
    asset.text_set(t.info.program[:],name)
    // A program replaces the maps of the standard model but the normal map.
    for &image,kind in t.images {if kind!=.Normal {image=MAP_NONE}}
    normal_transform:=asset.material_maps(&t.info.maps)[.Normal]
    t.info.maps=asset.MATERIAL_DEFAULTS.maps
    asset.material_maps(&t.info.maps)[.Normal]=normal_transform
}

@(private)
identifier_matches :: proc(p:Program_Parameter,q:Parameter) -> bool {return p.source==q.name && p.components==q.width}

// The function of the Custom node n, as Unreal declares it: its inputs, a
// texture with its sampler, and its outputs after the first as inout. Code
// that reads what a Mirai program does not have is a note to port it, and
// the function gives zero.
@(private)
custom_function :: proc(b:^strings.Builder,m:^Emitter,n:u32) {
    g:=m.g
    node:=g.nodes[n]
    code:=g.customs[node.index]
    params:=strings.builder_make(context.temp_allocator)
    strings.write_string(&params,"Mirai_Surface_Context ctx")
    i:=0
    for list:=node.args[0];list!=NONE;list=g.nodes[list].args[1] {
        value:=g.nodes[g.nodes[list].args[0]]
        name:=code.inputs[i]
        i+=1
        if value.op==.Texture {
            fmt.sbprintf(&params,", uint %s, uint %sSampler",name,name)
        } else {
            fmt.sbprintf(&params,", %s %s",type_name(value.width),name)
        }
    }
    for out in code.outputs {fmt.sbprintf(&params,", inout %s %s",type_name(out.width),out.name)}
    title:=code.description!=""?fmt.tprintf(" %s",code.description):""
    if code.unported=="" {
        fmt.sbprintf(b,"// The Custom expression%s of Unreal.\n%s unreal_custom_%d(%s) {{\n",title,type_name(code.width),node.index,strings.to_string(params))
        for line in strings.split_lines(code.code,context.temp_allocator) {fmt.sbprintf(b,"    %s\n",line)}
        strings.write_string(b,"}\n")
        return
    }
    fmt.sbprintf(b,"// To port to Slang: the HLSL of the Custom expression%s of Unreal reads %s, which a Mirai program does not have.\n",title,code.unported)
    strings.write_string(b,"// Until it is ported the function gives zero. The HLSL:\n")
    for line in strings.split_lines(code.code,context.temp_allocator) {fmt.sbprintf(b,"//     %s\n",line)}
    fmt.sbprintf(b,"%s unreal_custom_%d(%s) {{return %s;}}\n",type_name(code.width),node.index,strings.to_string(params),literal({},code.width))
}

// What the custom HLSL of Unreal names that Slang does not: its types, and
// its texture reads, by the ctx of the function they are in.
@(private)
CUSTOM_PRELUDE :: `#ifndef MIRAI_UNREAL_CUSTOM_HLSL
#define MIRAI_UNREAL_CUSTOM_HLSL
#define MaterialFloat float
#define MaterialFloat2 float2
#define MaterialFloat3 float3
#define MaterialFloat4 float4
#define MaterialFloat3x3 float3x3
#define MaterialFloat4x4 float4x4
#define Texture2DSample(t, s, uv) mirai_sample_texture(ctx, t, uv, ctx.lod)
#define Texture2DSampleLevel(t, s, uv, level) mirai_sample_texture_level(t, uv, level)
#define Texture2DSampleBias(t, s, uv, bias) mirai_sample_texture(ctx, t, uv, ctx.lod + (bias))
#define Texture2DSampleGrad(t, s, uv, dx, dy) mirai_sample_texture_grad(t, uv, dx, dy)
#ifndef PI
#define PI 3.14159265358979
#endif
#endif
`

// What the programs translated from Unreal call: Unreal's normal maps and
// its tangent-space normals, and its Specular (see specular_ior).
@(private)
PROGRAM_HELPERS :: `float4 unreal_normal(float4 texel) {
    float2 xy=texel.xy*2.0-1.0;
    return float4(xy,sqrt(saturate(1.0-dot(xy,xy))),1.0);
}
float3 mirai_bitangent(Mirai_Surface_Context ctx) {return ctx.tangent.w*cross(ctx.vertex_normal,ctx.tangent.xyz);}
float3 unreal_bitangent(Mirai_Surface_Context ctx) {
    float3 b=mirai_bitangent(ctx);
    return float3(b.z,-b.x,b.y);
}
float3 unreal_tangent_to_world(Mirai_Surface_Context ctx, float3 n) {
    return ctx.tangent.xyz*n.x+mirai_bitangent(ctx)*n.y+ctx.vertex_normal*n.z;
}
float3 unreal_point(float3 p) {return float3(p.z,-p.x,p.y)*100.0;}
float3 unreal_vector(float3 v) {return float3(v.z,-v.x,v.y);}
float3 unreal_to_mirai(float3 v) {return float3(-v.y,v.z,v.x);}
// What the origin of the render adds to a place of the world.
float3 unreal_origin(Mirai_Surface_Context ctx) {return unreal_point(float3(ctx.origin)*ORIGIN_STEP);}
// Axis i of the object in Unreal's axes: its local X, Y and Z.
float3 unreal_object_axis(Mirai_Surface_Context ctx, int i) {return unreal_vector(i==0?ctx.object_z:i==1?-ctx.object_x:ctx.object_y);}
// The low (0) or high corner of the bounds of the object in its own space, in Unreal's axes.
float3 unreal_object_bounds(Mirai_Surface_Context ctx, int i) {
    float3 low=ctx.object_low, high=ctx.object_high;
    return i==0?float3(low.z,-high.x,low.y)*100.0:float3(high.z,-low.x,high.y)*100.0;
}
void unreal_specular(inout Mirai_Surface s, float specular) {
    float f0=0.08*saturate(specular);
    float r=sqrt(max(f0,0.02));
    s.specular_ior=(1.0+r)/(1.0-r);
    s.specular_factor=min(f0/0.02,1.0);
}
`
