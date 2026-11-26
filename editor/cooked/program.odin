package cooked

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// A material as the program its own compiled shaders are: `ue5parse shader --program` gives
// the pixel shader that fills the surface targets and the vertex shader that feeds it, each
// as one function over dx_* calls, with what they read. Here those calls become Mirai's: the
// vertex function runs at the pixel on what the mesh gives there (position, frame, texture
// coordinates, colour, with their derivatives), its interpolants feed the pixel function, and
// the targets it writes are the surface. The engine's own uniform buffers (the view, the
// primitive, the vertex streams) are answered from the surface context, in Unreal's units and
// axes; the material's uniform buffer and textures are the parameters of the program, so the
// instances of one shader map share one program.

// One parameter of the program, in the order of its struct Parameters, with what the
// material gives it.
Cooked_Program_Parameter :: struct {
    name:string,
    is_texture:bool,
    texture:string, // object path of the texture, "" where the material binds none
    value:[4]f32,   // a register of the material's uniform buffer
}

Cooked_Shader_Program :: struct {
    name:string,   // Unreal_<shader map hash>: the same for every material of the map
    source:string, // the Slang surface program
    parameters:[]Cooked_Program_Parameter,
    notes:[]string, // what the program reads that is answered with zeros
}

cooked_shader_program_destroy :: proc(p:^Cooked_Shader_Program,allocator:=context.allocator) {
    delete(p.name,allocator)
    delete(p.source,allocator)
    for prm in p.parameters {
        delete(prm.name,allocator)
        delete(prm.texture,allocator)
    }
    delete(p.parameters,allocator)
    for n in p.notes {delete(n,allocator)}
    delete(p.notes,allocator)
    p^={}
}

// The layouts of the engine's uniform buffers this file answers, by the hash their shaders
// carry: a build of the engine that lays one out differently has another hash, and its
// materials are refused instead of read wrong.
@(private="file")
KNOWN_LAYOUTS :: [4][2]string{{"View","cfe9c681"},{"Scene","f7e1b302"},{"LocalVF","3aef5598"},{SKIN_PASS_THROUGH,"fc97ef48"}}

// The streams of a local vertex factory whose vertices a skin wrote: positions now and
// before, then tangents at rest and now. A mesh that is not skinned has its own in them.
@(private="file") SKIN_PASS_THROUGH :: "GPUSkinPassThroughVFLooseParameters"

// Resources of those buffers, by their index in the layout.
@(private="file") SCENE_INSTANCE_DATA :: 3
@(private="file") SCENE_PRIMITIVE_DATA :: 5
@(private="file") LOCALVF_TEXCOORDS :: 0
@(private="file") LOCALVF_POSITIONS :: 1
@(private="file") LOCALVF_PRESKIN_POSITIONS :: 2
@(private="file") LOCALVF_TANGENTS :: 3
@(private="file") LOCALVF_COLORS :: 4

@(private="file") PROGRAM_MAX_FIELDS :: 32
@(private="file") PROGRAM_MAX_BYTES :: 256

@(private="file")
Element :: struct {semantic:string,index,rows,base:int,integer,used:bool}

@(private="file")
Bind :: struct {kind,buffer:string,slot,resource:int}

@(private="file")
Stage :: struct {
    inputs,outputs:[]Element,
    buffers:[]string, // by constant buffer slot
    binds:[]Bind,
    registers:map[string][]int, // by buffer name: those read
    in_size,out_size:int,
}

@(private="file")
json_int :: proc(v:json.Value,fallback:=-1) -> int {
    #partial switch x in v {
    case json.Integer:return int(x)
    case json.Float:return int(x)
    }
    return fallback
}

@(private="file")
stage_parse :: proc(v:json.Value,known:^[dynamic][2]string) -> (s:Stage,problem:string) {
    elements :: proc(v:json.Value) -> (out:[]Element,size:int) {
        arr,_:=json_arr(v)
        out=make([]Element,len(arr),context.temp_allocator)
        for item,i in arr {
            sem,_:=json_get(item,"Semantic")
            index,_:=json_get(item,"Index")
            rows,_:=json_get(item,"Rows")
            integer,_:=json_get(item,"Integer")
            used,_:=json_get(item,"Used")
            out[i]={semantic=json_str(sem),index=json_int(index,0),rows=clamp(json_int(rows,1),1,16),base=size,integer=json_bool(integer),used=json_bool(used)}
            size+=out[i].rows*4
        }
        return
    }
    inputs,_:=json_get(v,"Inputs")
    outputs,_:=json_get(v,"Outputs")
    s.inputs,s.in_size=elements(inputs)
    s.outputs,s.out_size=elements(outputs)
    ubs,_:=json_get(v,"UniformBuffers")
    ub_arr,_:=json_arr(ubs)
    s.buffers=make([]string,len(ub_arr),context.temp_allocator)
    layouts:=make([]string,len(ub_arr),context.temp_allocator)
    for item,i in ub_arr {
        name,_:=json_get(item,"Name")
        layout,_:=json_get(item,"Layout")
        s.buffers[i],layouts[i]=json_str(name),json_str(layout)
    }
    s.registers=make(map[string][]int,allocator=context.temp_allocator)
    bindings,_:=json_get(v,"Bindings")
    b_arr,_:=json_arr(bindings)
    binds:=make([dynamic]Bind,context.temp_allocator)
    for item in b_arr {
        kind,_:=json_get(item,"Kind")
        buffer,_:=json_get(item,"Buffer")
        slot,_:=json_get(item,"Slot")
        resource,_:=json_get(item,"Resource")
        b:=Bind{kind=json_str(kind),buffer=json_str(buffer),slot=json_int(slot),resource=json_int(resource)}
        append(&binds,b)
        if b.kind=="Constant_Buffer" {
            regs,_:=json_get(item,"Registers")
            r_arr,_:=json_arr(regs)
            list:=make([]int,len(r_arr),context.temp_allocator)
            for r,i in r_arr {list[i]=json_int(r)}
            slice.sort(list)
            s.registers[b.buffer]=list
        }
        // What the shader reads of an engine buffer must be of the layout answered here.
        for layout in KNOWN_LAYOUTS {
            if layout[0]!=b.buffer {continue}
            for name,i in s.buffers {
                if name==b.buffer&&layouts[i]!=layout[1] {
                    return s,fmt.tprintf("its shaders read the uniform buffer %s with the layout %s; this importer answers %s",name,layouts[i],layout[1])
                }
            }
            seen:=false
            for k in known {seen||=k[0]==layout[0]}
            if !seen {append(known,layout)}
        }
    }
    s.binds=binds[:]
    return
}

@(private="file")
bind_find :: proc(s:^Stage,kinds:[]string,slot:int) -> (Bind,bool) {
    for b in s.binds {
        if b.slot!=slot {continue}
        for k in kinds {
            if b.kind==k {return b,true}
        }
    }
    return {},false
}

@(private="file")
note_add :: proc(notes:^[dynamic]string,text:string) {
    for n in notes {
        if n==text {return}
    }
    append(notes,strings.clone(text,context.temp_allocator))
}

// The arguments of the call that opens at text[open], and where it closes.
@(private="file")
call_args :: proc(text:string,open:int) -> (args:[]string,close:int) {
    out:=make([dynamic]string,context.temp_allocator)
    depth,start:=0,open+1
    for i:=open;i<len(text);i+=1 {
        switch text[i] {
        case '(':depth+=1
        case ')':
            depth-=1
            if depth==0 {
                append(&out,strings.trim_space(text[start:i]))
                return out[:],i
            }
        case ',':
            if depth==1 {
                append(&out,strings.trim_space(text[start:i]))
                start=i+1
            }
        }
    }
    return nil,-1
}

@(private="file")
literal :: proc(text:string) -> (int,bool) {
    return strconv.parse_int(strings.trim(text,"()"))
}

// One function with its dx_* calls as what answers them. feeds is the stage the outputs of
// this one go to (the pixel stage for the vertex function), nil for the last.
@(private="file")
stage_rewrite :: proc(w:^strings.Builder,source:string,s:^Stage,feeds:^Stage,is_vertex:bool,textures:map[int]int,notes:^[dynamic]string) -> (problem:string) {
    in_array:=is_vertex ? "vin" : "pin"
    rest:=source
    for {
        at:=strings.index(rest,"dx_")
        if at<0 {strings.write_string(w,rest);break}
        // A name that only ends in dx_ (none today) is not a call.
        if at>0&&(rest[at-1]=='_'||rest[at-1]>='a'&&rest[at-1]<='z'||rest[at-1]>='0'&&rest[at-1]<='9') {
            strings.write_string(w,rest[:at+3])
            rest=rest[at+3:]
            continue
        }
        open:=strings.index_byte(rest[at:],'(')
        if open<0 {strings.write_string(w,rest);break}
        name:=rest[at:at+open]
        strings.write_string(w,rest[:at])
        if name=="dx_pixel"||name=="dx_vertex"||name=="dx_bfe"||name=="dx_sdiv"||name=="dx_srem" {
            strings.write_string(w,name)
            rest=rest[at+open:]
            continue
        }
        args,close:=call_args(rest,at+open)
        if close<0 {return fmt.tprintf("a call of %s that does not close",name)}
        rest=rest[close+1:]
        needs:=1
        switch name {
        case "dx_input","dx_input_i":needs=4
        case "dx_output","dx_output_i":needs=5
        case "dx_cb","dx_cb_i","dx_buffer","dx_buffer_i","dx_raw","dx_raw_i":needs=3
        case "dx_sample","dx_sample_level":needs=6
        case "dx_sample_grad":needs=7
        case "dx_load":needs=4
        }
        if len(args)<needs {return fmt.tprintf("a call of %s with %d arguments",name,len(args))}
        switch name {
        case "dx_input","dx_input_i":
            sig,a:=literal(args[1])
            row,b:=literal(args[2])
            col,c:=literal(args[3])
            if !a||!b||!c||sig<0||sig>=len(s.inputs)||row<0||row>=s.inputs[sig].rows||col<0||col>3 {return fmt.tprintf("an input read by a computed index: %s of %s",name,args[1])}
            k:=s.inputs[sig].base+row*4+col
            if name=="dx_input" {fmt.sbprintf(w,"e.%s[%d]",in_array,k)} else {fmt.sbprintf(w,"int(e.%s[%d].v)",in_array,k)}
        case "dx_output","dx_output_i":
            sig,a:=literal(args[1])
            row,b:=literal(args[2])
            col,c:=literal(args[3])
            if !a||!b||!c||sig<0||sig>=len(s.outputs)||row<0||row>=s.outputs[sig].rows||col<0||col>3 {return fmt.tprintf("an output written by a computed index: %s of %s",name,args[1])}
            value:=name=="dx_output" ? args[4] : fmt.tprintf("d_c(float(%s))",args[4])
            if feeds==nil {
                fmt.sbprintf(w,"e.pout[%d]=%s",s.outputs[sig].base+row*4+col,value)
            } else {
                to:=-1
                for e,i in feeds.inputs {
                    if e.semantic==s.outputs[sig].semantic&&e.index==s.outputs[sig].index {to=i}
                }
                if to<0||row>=feeds.inputs[to].rows {return fmt.tprintf("the vertex shader writes %s%d, which the pixel shader does not read",s.outputs[sig].semantic,s.outputs[sig].index)}
                fmt.sbprintf(w,"e.pin[%d]=%s",feeds.inputs[to].base+row*4+col,value)
            }
        case "dx_cb","dx_cb_i":
            slot,_:=literal(args[1])
            buffer:=slot>=0&&slot<len(s.buffers) ? s.buffers[slot] : ""
            integer:=name=="dx_cb_i"
            switch buffer {
            case "Material":
                reg,is_literal:=literal(args[2])
                if !is_literal {return "a register of the material's uniform buffer read by a computed index"}
                fmt.sbprintf(w,integer ? "asint(e.p.m%d)" : "e.p.m%d",reg)
            case "View":
                fmt.sbprintf(w,integer ? "asint(dx_view(e,%s))" : "dx_view(e,%s)",args[2])
            case "LocalVF":
                fmt.sbprintf(w,integer ? "dx_localvf(%s)" : "asfloat(dx_localvf(%s))",args[2])
            case "Scene":
                // Of the scene only how instances index their data is read: one primitive, at zero.
                strings.write_string(w,integer ? "int4(0)" : "float4(0.0)")
            case:
                note_add(notes,fmt.tprintf("the uniform buffer %s",buffer))
                strings.write_string(w,integer ? "int4(0)" : "float4(0.0)")
            }
        case "dx_sample","dx_sample_level","dx_sample_grad","dx_load":
            slot,_:=literal(args[1])
            b,_:=bind_find(s,{"Texture"},slot)
            k,bound:=textures[b.resource]
            if b.buffer!="Material"||!bound {
                note_add(notes,fmt.tprintf("a texture of %s",b.buffer!="" ? b.buffer : "no uniform buffer"))
                strings.write_string(w,"float4(0.0)")
                continue
            }
            switch name {
            case "dx_sample":fmt.sbprintf(w,"dx_tex_sample(e.p.t%d,%s,%s,%s)",k,args[3],args[4],args[5])
            case "dx_sample_level":fmt.sbprintf(w,"dx_tex_level(e.p.t%d,%s,%s,%s)",k,args[3],args[4],args[5])
            case "dx_sample_grad":fmt.sbprintf(w,"dx_tex_grad(e.p.t%d,%s,%s,%s,%s)",k,args[3],args[4],args[5],args[6])
            case "dx_load":fmt.sbprintf(w,"dx_tex_load(e.p.t%d,%s,%s)",k,args[2],args[3])
            }
        case "dx_raw","dx_raw_i":
            slot,_:=literal(args[1])
            b,_:=bind_find(s,{"Raw_Buffer"},slot)
            integer:=name=="dx_raw_i"
            switch {
            case b.buffer=="Scene"&&b.resource==SCENE_PRIMITIVE_DATA:
                fmt.sbprintf(w,integer ? "asint(dx_primitive(e,%s))" : "dx_primitive(e,%s)",args[2])
            case b.buffer=="Scene"&&b.resource==SCENE_INSTANCE_DATA:
                strings.write_string(w,integer ? "int4(0)" : "float4(0.0)")
            case:
                note_add(notes,fmt.tprintf("the buffer %d of %s",b.resource,b.buffer))
                strings.write_string(w,integer ? "int4(0)" : "float4(0.0)")
            }
        case "dx_buffer","dx_buffer_i":
            slot,_:=literal(args[1])
            b,_:=bind_find(s,{"Buffer"},slot)
            if name=="dx_buffer_i" {
                note_add(notes,fmt.tprintf("the integer buffer %d of %s",b.resource,b.buffer))
                strings.write_string(w,"int4(0)")
                continue
            }
            fetch:=""
            switch b.buffer {
            case "LocalVF":
                switch b.resource {
                case LOCALVF_TEXCOORDS:fetch="dx_fetch_uv"
                case LOCALVF_POSITIONS,LOCALVF_PRESKIN_POSITIONS:fetch="dx_fetch_position"
                case LOCALVF_TANGENTS:fetch="dx_fetch_tangent"
                case LOCALVF_COLORS:fetch="dx_fetch_color"
                }
            case SKIN_PASS_THROUGH:
                switch b.resource {
                case 0,1:fetch="dx_fetch_position"
                case 2,3:fetch="dx_fetch_tangent"
                }
            }
            if fetch=="" {
                note_add(notes,fmt.tprintf("the vertex stream %d of %s",b.resource,b.buffer))
                strings.write_string(w,"(D4)0")
            } else {
                fmt.sbprintf(w,"%s(e,%s)",fetch,args[2])
            }
        case "dx_discard":
            strings.write_string(w,"e.discarded=true")
        case:
            return fmt.tprintf("the call %s has no answer here",name)
        }
    }
    return ""
}

// What every program starts with, inside its namespace after struct Parameters and the sizes
// of the arrays of Dx_Env. Lengths are Unreal's (cm) and axes Unreal's (x forward, y right, z
// up), so the functions read what they were compiled against; dx_to_unreal and dx_to_mirai
// turn directions, and a length takes 100.
@(private="file")
PROGRAM_PRELUDE :: `
// A value and how it changes to the next pixel along x and along y.
struct D { float v; float2 d; };
struct D4 { D x; D y; D z; D w; };
D d_c(float v) { D r; r.v = v; r.d = float2(0.0); return r; }
D d_make(float v, float dx, float dy) { D r; r.v = v; r.d = float2(dx, dy); return r; }
D d_add(D a, D b) { D r; r.v = a.v + b.v; r.d = a.d + b.d; return r; }
D d_sub(D a, D b) { D r; r.v = a.v - b.v; r.d = a.d - b.d; return r; }
D d_mul(D a, D b) { D r; r.v = a.v * b.v; r.d = a.d * b.v + b.d * a.v; return r; }
D d_div(D a, D b) { D r; r.v = a.v / b.v; r.d = (a.d * b.v - b.d * a.v) / (b.v * b.v); return r; }
D d_rem(D a, D b) { D r; r.v = fmod(a.v, b.v); r.d = a.d - b.d * trunc(a.v / b.v); return r; }
D d_sel(bool c, D a, D b) { if (c) return a; return b; }
D d_abs(D a) { D r; r.v = abs(a.v); r.d = a.v < 0.0 ? -a.d : a.d; return r; }
D d_saturate(D a) { D r; r.v = saturate(a.v); r.d = (a.v > 0.0 && a.v < 1.0) ? a.d : float2(0.0); return r; }
D d_cos(D a) { D r; r.v = cos(a.v); r.d = -sin(a.v) * a.d; return r; }
D d_sin(D a) { D r; r.v = sin(a.v); r.d = cos(a.v) * a.d; return r; }
D d_tan(D a) { D r; r.v = tan(a.v); float c = cos(a.v); r.d = a.d / (c * c); return r; }
D d_acos(D a) { D r; r.v = acos(a.v); r.d = -a.d / sqrt(max(1.0 - a.v * a.v, 1e-12)); return r; }
D d_asin(D a) { D r; r.v = asin(a.v); r.d = a.d / sqrt(max(1.0 - a.v * a.v, 1e-12)); return r; }
D d_atan(D a) { D r; r.v = atan(a.v); r.d = a.d / (1.0 + a.v * a.v); return r; }
D d_cosh(D a) { D r; r.v = cosh(a.v); r.d = sinh(a.v) * a.d; return r; }
D d_sinh(D a) { D r; r.v = sinh(a.v); r.d = cosh(a.v) * a.d; return r; }
D d_tanh(D a) { D r; r.v = tanh(a.v); r.d = (1.0 - r.v * r.v) * a.d; return r; }
// DXIL's Exp and Log are of base two.
D d_exp(D a) { D r; r.v = exp2(a.v); r.d = 0.69314718 * r.v * a.d; return r; }
D d_log(D a) { D r; r.v = log2(a.v); r.d = a.d / (a.v * 0.69314718); return r; }
D d_frac(D a) { D r; r.v = frac(a.v); r.d = a.d; return r; }
D d_sqrt(D a) { D r; r.v = sqrt(a.v); r.d = a.d * (0.5 / max(r.v, 1e-12)); return r; }
D d_rsqrt(D a) { D r; r.v = rsqrt(a.v); r.d = a.d * (-0.5 * r.v / max(a.v, 1e-12)); return r; }
D d_round(D a) { return d_c(round(a.v)); }
D d_floor(D a) { return d_c(floor(a.v)); }
D d_ceil(D a) { return d_c(ceil(a.v)); }
D d_trunc(D a) { return d_c(trunc(a.v)); }
D d_max(D a, D b) { if (a.v >= b.v) return a; return b; }
D d_min(D a, D b) { if (a.v <= b.v) return a; return b; }
D4 d4_c(float4 v) { D4 r; r.x = d_c(v.x); r.y = d_c(v.y); r.z = d_c(v.z); r.w = d_c(v.w); return r; }
int dx_bfe(bool is_signed, int width, int offset, int value) {
    int w = width & 31;
    int o = offset & 31;
    if (w == 0) return 0;
    if (w + o < 32) {
        int up = value << (32 - w - o);
        if (is_signed) return up >> (32 - w);
        return int(uint(up) >> uint(32 - w));
    }
    if (is_signed) return value >> o;
    return int(uint(value) >> uint(o));
}
int dx_sdiv(int a, int b) { return b == 0 ? 0 : a / b; }
int dx_srem(int a, int b) { return b == 0 ? 0 : a % b; }

float3 dx_to_unreal(float3 v) { return float3(-v.z, v.x, v.y); }
float3 dx_to_mirai(float3 v) { return float3(v.y, v.z, -v.x); }

// What the functions read and write, with the surface as Unreal has it.
struct Dx_Env {
    Parameters p;
    float time;
    float2 pixel;        // the point in the image, pixels
    float2 image;        // the image, pixels
    float depth;         // of the point along the view
    float3 position;     // of the point in the world, from the origin of the render
    float3 position_dx;
    float3 position_dy;
    float3 normal;       // of the mesh at the point, in the world
    float3 tangent;
    float side;          // of the bitangent: cross(normal, tangent) times it
    float3 axis_x;       // the object's axes in the world, as long as its scale
    float3 axis_y;
    float3 axis_z;
    float3 origin;       // the object's pivot
    float3 center;       // of its bounds, and their radius
    float radius;
    float3 low;          // the corners of the bounds of its mesh in its own space
    float3 high;
    D local[3];          // the point in the object's own space
    float3 local_normal;
    float3 local_tangent;
    D uv[4];             // the first two texture coordinates of the mesh
    float4 color;        // of the mesh at the point
    bool discarded;
    D vin[DX_VERTEX_INPUTS];
    D pin[DX_PIXEL_INPUTS];
    D pout[DX_PIXEL_OUTPUTS];
};

void dx_env_fill(inout Dx_Env e, Mirai_Surface_Context ctx) {
    e.time = ctx.time;
    e.image = ctx.screen_size;
    e.pixel = ctx.screen * ctx.screen_size;
    e.depth = ctx.depth * 100.0;
    e.position = dx_to_unreal(ctx.world_position) * 100.0;
    e.position_dx = dx_to_unreal(ctx.position_dx) * 100.0;
    e.position_dy = dx_to_unreal(ctx.position_dy) * 100.0;
    e.normal = dx_to_unreal(ctx.vertex_normal);
    e.tangent = dx_to_unreal(ctx.tangent.xyz);
    e.side = ctx.tangent.w < 0.0 ? -1.0 : 1.0;
    // Unreal's own x is Mirai's -z, its y Mirai's x, its z Mirai's y.
    e.axis_x = -dx_to_unreal(ctx.object_z);
    e.axis_y = dx_to_unreal(ctx.object_x);
    e.axis_z = dx_to_unreal(ctx.object_y);
    e.origin = dx_to_unreal(ctx.object_position) * 100.0;
    e.center = dx_to_unreal(ctx.object_center) * 100.0;
    e.radius = ctx.object_radius * 100.0;
    e.low = float3(-ctx.object_high.z, ctx.object_low.x, ctx.object_low.y) * 100.0;
    e.high = float3(-ctx.object_low.z, ctx.object_high.x, ctx.object_high.y) * 100.0;
    float3 scale2 = max(float3(dot(e.axis_x, e.axis_x), dot(e.axis_y, e.axis_y), dot(e.axis_z, e.axis_z)), float3(1e-30));
    float3 from = e.position - e.origin;
    float3 at = float3(dot(from, e.axis_x), dot(from, e.axis_y), dot(from, e.axis_z)) / scale2;
    float3 at_dx = float3(dot(e.position_dx, e.axis_x), dot(e.position_dx, e.axis_y), dot(e.position_dx, e.axis_z)) / scale2;
    float3 at_dy = float3(dot(e.position_dy, e.axis_x), dot(e.position_dy, e.axis_y), dot(e.position_dy, e.axis_z)) / scale2;
    e.local[0] = d_make(at.x, at_dx.x, at_dy.x);
    e.local[1] = d_make(at.y, at_dx.y, at_dy.y);
    e.local[2] = d_make(at.z, at_dx.z, at_dy.z);
    float3 n = float3(dot(e.normal, e.axis_x), dot(e.normal, e.axis_y), dot(e.normal, e.axis_z));
    e.local_normal = n / max(length(n), 1e-30);
    float3 t = float3(dot(e.tangent, e.axis_x), dot(e.tangent, e.axis_y), dot(e.tangent, e.axis_z)) / scale2;
    e.local_tangent = t / max(length(t), 1e-30);
    Mirai_Dual2 uv0 = mirai_uv0(ctx);
    Mirai_Dual2 uv1 = mirai_uv1(ctx);
    e.uv[0] = d_make(uv0.value.x, uv0.dx.x, uv0.dy.x);
    e.uv[1] = d_make(uv0.value.y, uv0.dx.y, uv0.dy.y);
    e.uv[2] = d_make(uv1.value.x, uv1.dx.x, uv1.dy.x);
    e.uv[3] = d_make(uv1.value.y, uv1.dx.y, uv1.dy.y);
    e.color = ctx.vertex_color;
    e.discarded = false;
    for (int i = 0; i < DX_VERTEX_INPUTS; i++) e.vin[i] = d_c(0.0);
    for (int i = 0; i < DX_PIXEL_INPUTS; i++) e.pin[i] = d_c(0.0);
    for (int i = 0; i < DX_PIXEL_OUTPUTS; i++) e.pout[i] = d_c(0.0);
}

// The view's uniform buffer, by register. The world it speaks of is the render's: no
// translation, no tile. A program has no eye, so the camera is where the point faces it
// from, as far as the point is deep. The point's place in the image and its place in the
// world are tied by SVPositionToTranslatedWorld (44 to 47), which here takes the pixel of
// the point to the point with the derivatives of the surface.
float4 dx_view(inout Dx_Env e, int reg) {
    switch (reg) {
    case 44: return float4(e.position_dx, 0.0);
    case 45: return float4(e.position_dy, 0.0);
    case 46: return float4(0.0);
    case 47: return float4(e.position - e.position_dx * e.pixel.x - e.position_dy * e.pixel.y, 1.0);
    case 77: return float4(-e.normal, 0.0);                           // ViewForward
    case 84: return float4(e.position + e.normal * e.depth, 0.0);     // ViewOriginLow
    case 85: return float4(e.position + e.normal * e.depth, 0.0);     // TranslatedWorldCameraOrigin
    case 87: return float4(e.position + e.normal * e.depth, 0.0);     // WorldViewOriginLow
    case 156: return float4(e.image, 1.0 / max(e.image, float2(1.0))); // ViewSizeAndInvSize
    case 159: return float4(e.image, 1.0 / max(e.image, float2(1.0))); // BufferSizeAndInvSize
    case 163: return float4(asfloat(1), 1.0, 1.0, 1.0);               // samples, depth thickness, PreExposure and its inverse
    case 164: return float4(0.0, 0.0, 0.0, 1.0);                      // DiffuseOverrideParameter: add, times
    case 165: return float4(0.0, 0.0, 0.0, 1.0);                      // SpecularOverrideParameter
    case 166: return float4(0.0, 0.0, 0.0, 1.0);                      // NormalOverrideParameter
    case 167: return float4(0.0, 1.0, 0.0, 1.0);                      // roughness and occlusion overrides: add, times
    case 168: return float4(e.time, e.time, 0.0, 0.0);                // previous times, OutOfBoundsMask
    case 169: return float4(0.0, 0.0, 0.0, 1.0);                      // camera movement, CullingSign
    case 170: return float4(10.0, 0.0, e.time, e.time);               // NearPlane, OrthoFarPlane, GameTime, RealTime
    case 171: return float4(1.0 / 60.0, 0.0, 1.0, 0.0);               // DeltaTime, mip bias, derivative multiply, Random
    case 361: return float4(0.0, 0.0, 1e30, 0.0);                     // MaterialMaxEmissiveValue in z
    default: return float4(0.0);
    }
}

// The rows of the primitive the point is of, as the scene's primitive buffer has them.
float4 dx_primitive(inout Dx_Env e, int row) {
    float3 scale = float3(length(e.axis_x), length(e.axis_y), length(e.axis_z));
    float3 inverse = 1.0 / max(scale, float3(1e-30));
    float3 extent = 0.5 * (e.high - e.low) * scale;
    switch (row) {
    case 2: case 8: return float4(e.axis_x.x, e.axis_y.x, e.axis_z.x, e.origin.x);       // LocalToWorld, by column
    case 3: case 9: return float4(e.axis_x.y, e.axis_y.y, e.axis_z.y, e.origin.y);
    case 4: case 10: return float4(e.axis_x.z, e.axis_y.z, e.axis_z.z, e.origin.z);
    case 5: case 11: return float4(e.axis_x * inverse.x * inverse.x, -dot(e.origin, e.axis_x) * inverse.x * inverse.x); // WorldToLocal
    case 6: case 12: return float4(e.axis_y * inverse.y * inverse.y, -dot(e.origin, e.axis_y) * inverse.y * inverse.y);
    case 7: case 13: return float4(e.axis_z * inverse.z * inverse.z, -dot(e.origin, e.axis_z) * inverse.z * inverse.z);
    case 14: return float4(1.0, 0.0, 0.0, 0.0);                                         // WorldToPreviousWorld
    case 15: return float4(0.0, 1.0, 0.0, 0.0);
    case 16: return float4(0.0, 0.0, 1.0, 0.0);
    case 17: return float4(inverse, extent.x);                                          // InvNonUniformScale, ObjectBoundsX
    case 18: return float4(0.0, 0.0, 0.0, e.radius);                                    // ObjectWorldPosition high, ObjectRadius
    case 19: return float4(e.center, 0.0);                                              // ObjectWorldPosition low
    case 21: return float4(e.origin, 0.0);                                              // ActorWorldPosition low
    case 22: return float4(e.axis_z * inverse.z, 0.0);                                  // ObjectOrientation
    case 23: return float4(scale, max(scale.x, max(scale.y, scale.z)));                 // NonUniformScale
    case 24: case 26: return float4(e.low, row == 26 ? extent.y : 0.0);                 // local bounds low, ObjectBoundsY
    case 25: case 27: return float4(e.high, row == 27 ? extent.z : 0.0);                // local bounds high, ObjectBoundsZ
    case 28: return float4(0.5 * (e.low + e.high), 0.0);                                // InstanceLocalBoundsCenter
    case 29: return float4(0.5 * (e.high - e.low), 0.0);                                // InstanceLocalBoundsExtent
    default: return float4(0.0);                                                        // flags, ids and the custom data: none
    }
}

// The local vertex factory's parameters: no colour mask, two texture coordinates, vertex zero.
int4 dx_localvf(int reg) { return reg == 0 ? int4(0, 2, 0, 0) : int4(0); }
// Its vertex streams, as the vertex function indexes them for vertex zero.
D4 dx_fetch_uv(inout Dx_Env e, int index) {
    D4 r = (D4)0;
    if (index <= 0) { r.x = e.uv[0]; r.y = e.uv[1]; } else { r.x = e.uv[2]; r.y = e.uv[3]; }
    return r;
}
D4 dx_fetch_position(inout Dx_Env e, int index) {
    D4 r = (D4)0;
    r.x = e.local[clamp(index, 0, 2)];
    return r;
}
D4 dx_fetch_tangent(inout Dx_Env e, int index) {
    if ((index & 1) == 0) return d4_c(float4(e.local_tangent, 0.0));
    return d4_c(float4(e.local_normal, e.side));
}
D4 dx_fetch_color(inout Dx_Env e, int index) { return d4_c(e.color.bgra); }

float4 dx_tex_sample(uint texture, D u, D v, float bias) {
    if (texture == 0xffffffffu) return float4(0.0);
    float s = exp2(bias);
    return mirai_sample_texture_grad(texture, float2(u.v, v.v), float2(u.d.x, v.d.x) * s, float2(u.d.y, v.d.y) * s);
}
float4 dx_tex_level(uint texture, D u, D v, float level) {
    if (texture == 0xffffffffu) return float4(0.0);
    return mirai_sample_texture_level(texture, float2(u.v, v.v), level);
}
float4 dx_tex_grad(uint texture, D u, D v, float2 dx, float2 dy) {
    if (texture == 0xffffffffu) return float4(0.0);
    return mirai_sample_texture_grad(texture, float2(u.v, v.v), dx, dy);
}
float4 dx_tex_load(uint texture, int x, int y) {
    if (texture == 0xffffffffu) return float4(0.0);
    return mirai_load_texture(texture, int2(x, y));
}
`

// The program of the material `ue5parse shader --program` wrote: description is its
// program.json, pixel and vertex the two functions beside it. The detail of an error lives
// in the temporary allocator.
cooked_shader_program :: proc(description,pixel,vertex:string,allocator:=context.allocator) -> (p:Cooked_Shader_Program,err:Maybe(Error)) {
    root,perr:=parse_json(description,context.temp_allocator)
    if e,bad:=perr.?;bad {return {},e}
    hash_v,_:=json_get(root,"CodeHash")
    hash:=json_str(hash_v)
    if len(hash)==0 {return {},Error{"program","the description has no CodeHash: is it the program.json of ue5parse shader --program?"}}
    for ch in hash {
        if !(ch>='0'&&ch<='9'||ch>='a'&&ch<='f') {return {},Error{"program","CodeHash is not a hash"}}
    }
    pixel_v,_:=json_get(root,"Pixel")
    vertex_v,_:=json_get(root,"Vertex")
    known:=make([dynamic][2]string,context.temp_allocator)
    ps,ps_problem:=stage_parse(pixel_v,&known)
    if ps_problem!="" {return {},Error{"program",ps_problem}}
    vs,vs_problem:=stage_parse(vertex_v,&known)
    if vs_problem!="" {return {},Error{"program",vs_problem}}
    if ps.in_size==0||ps.out_size==0 {return {},Error{"program","the pixel shader has no inputs or no outputs"}}

    // The parameters: the textures of the material's uniform buffer the shaders sample, then
    // the registers they read.
    params,_:=json_get(root,"Parameters")
    evaluated,_:=json_get(params,"Evaluated")
    ub_v,_:=json_get(evaluated,"UniformBuffer")
    ub,_:=json_arr(ub_v)
    tb_v,_:=json_get(evaluated,"TextureBindings")
    tb,_:=json_arr(tb_v)
    // A texture is the resource before its sampler: resource 2i is the i-th binding.
    textures:=make(map[int]int,allocator=context.temp_allocator) // resource -> binding
    slots:=make([dynamic]int,context.temp_allocator)
    for stage in ([2]^Stage{&ps,&vs}) {
        for b in stage.binds {
            if b.kind!="Texture"||b.buffer!="Material"||b.resource<0||b.resource%2!=0||b.resource/2>=len(tb) {continue}
            textures[b.resource]=b.resource/2
            if !slice.contains(slots[:],b.resource/2) {append(&slots,b.resource/2)}
        }
    }
    slice.sort(slots[:])
    registers:=make([dynamic]int,context.temp_allocator)
    for stage in ([2]^Stage{&ps,&vs}) {
        for r in stage.registers["Material"] {
            if r>=0&&!slice.contains(registers[:],r) {append(&registers,r)}
        }
    }
    slice.sort(registers[:])
    bytes:=(len(slots)*4+15)/16*16+len(registers)*16
    if len(slots)+len(registers)>PROGRAM_MAX_FIELDS||bytes>PROGRAM_MAX_BYTES {
        return {},Error{"program",fmt.tprintf("its shaders read %d textures and %d registers of the material: more than a program's parameters hold (%d fields, %d bytes)",
            len(slots),len(registers),PROGRAM_MAX_FIELDS,PROGRAM_MAX_BYTES)}
    }

    notes:=make([dynamic]string,context.temp_allocator)
    name:=fmt.tprintf("Unreal_%s",hash)
    w:=strings.builder_make(allocator)
    fmt.sbprintfln(&w,"//! mirai surface %s",name)
    for k in slots {fmt.sbprintfln(&w,"//! parameter t%d {{\"kind\":\"texture\"}}",k)}
    for r in registers {fmt.sbprintfln(&w,"//! parameter m%d {{\"default\":[0.0,0.0,0.0,0.0],\"min\":-1000000.0,\"max\":1000000.0}}",r)}
    strings.write_string(&w,"// The compiled shaders of an Unreal material as one surface program: generated, not written.\n")
    fmt.sbprintfln(&w,"namespace %s {{",name)
    strings.write_string(&w,"struct Parameters {\n")
    for k in slots {fmt.sbprintfln(&w,"    uint t%d;",k)}
    for r in registers {fmt.sbprintfln(&w,"    float4 m%d;",r)}
    if len(slots)+len(registers)==0 {strings.write_string(&w,"    float unused;\n")}
    strings.write_string(&w,"};\n")
    fmt.sbprintfln(&w,"static const int DX_VERTEX_INPUTS = %d;",max(vs.in_size,1))
    fmt.sbprintfln(&w,"static const int DX_PIXEL_INPUTS = %d;",ps.in_size)
    fmt.sbprintfln(&w,"static const int DX_PIXEL_OUTPUTS = %d;",ps.out_size)
    strings.write_string(&w,PROGRAM_PRELUDE)
    if problem:=stage_rewrite(&w,vertex,&vs,&ps,true,textures,&notes);problem!="" {
        strings.builder_destroy(&w)
        return {},Error{"program",problem}
    }
    if problem:=stage_rewrite(&w,pixel,&ps,nil,false,textures,&notes);problem!="" {
        strings.builder_destroy(&w)
        return {},Error{"program",problem}
    }

    // What the mesh gives each stage, by semantic.
    strings.write_string(&w,"Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {\n    Dx_Env e;\n    e.p = p;\n    dx_env_fill(e, ctx);\n")
    set :: proc(w:^strings.Builder,array:string,at:int,value:string) {
        fmt.sbprintfln(w,"    e.%s[%d] = %s;",array,at,value)
    }
    for in_ in vs.inputs {
        if !in_.used {continue}
        switch {
        case in_.semantic=="ATTRIBUTE"&&in_.index==0:
            for i in 0..<3 {set(&w,"vin",in_.base+i,fmt.tprintf("e.local[%d]",i))}
            set(&w,"vin",in_.base+3,"d_c(1.0)")
        case in_.semantic=="ATTRIBUTE"&&in_.index==1:
            for i in 0..<3 {set(&w,"vin",in_.base+i,fmt.tprintf("d_c(e.local_tangent[%d])",i))}
        case in_.semantic=="ATTRIBUTE"&&in_.index==2:
            for i in 0..<3 {set(&w,"vin",in_.base+i,fmt.tprintf("d_c(e.local_normal[%d])",i))}
            set(&w,"vin",in_.base+3,"d_c(e.side)")
        case in_.semantic=="ATTRIBUTE"&&in_.index==3:
            for i in 0..<4 {set(&w,"vin",in_.base+i,fmt.tprintf("d_c(e.color.bgra[%d])",i))}
        case strings.has_prefix(in_.semantic,"SV_"):
            // vertex and instance zero
        case:
            note_add(&notes,fmt.tprintf("the vertex input %s%d",in_.semantic,in_.index))
        }
    }
    strings.write_string(&w,"    dx_vertex(e);\n")
    for in_ in ps.inputs {
        if !in_.used {continue}
        from_vertex:=false
        for o in vs.outputs {from_vertex||=o.used&&o.semantic==in_.semantic&&o.index==in_.index}
        if from_vertex {continue}
        switch {
        case in_.semantic=="TEXCOORD10_centroid"||in_.semantic=="TEXCOORD10":
            for i in 0..<3 {set(&w,"pin",in_.base+i,fmt.tprintf("d_c(e.tangent[%d])",i))}
        case in_.semantic=="TEXCOORD11_centroid"||in_.semantic=="TEXCOORD11":
            for i in 0..<3 {set(&w,"pin",in_.base+i,fmt.tprintf("d_c(e.normal[%d])",i))}
            set(&w,"pin",in_.base+3,"d_c(e.side)")
        case in_.semantic=="TEXCOORD"&&in_.index==9:
            for i in 0..<3 {set(&w,"pin",in_.base+i,fmt.tprintf("d_make(e.position[%d], e.position_dx[%d], e.position_dy[%d])",i,i,i))}
        case in_.semantic=="SV_Position":
            set(&w,"pin",in_.base,"d_make(e.pixel.x, 1.0, 0.0)")
            set(&w,"pin",in_.base+1,"d_make(e.pixel.y, 0.0, 1.0)")
            set(&w,"pin",in_.base+2,"d_c(0.5)")
            set(&w,"pin",in_.base+3,"d_c(e.depth)")
        case in_.semantic=="SV_IsFrontFace":
            set(&w,"pin",in_.base,"d_c(1.0)")
        case in_.semantic=="INSTANCE_ID"||in_.semantic=="PRIMITIVE_ID":
            // instance zero
        case:
            note_add(&notes,fmt.tprintf("the interpolant %s%d",in_.semantic,in_.index))
        }
    }
    strings.write_string(&w,"    dx_pixel(e);\n")
    target:=[4]int{-1,-1,-1,-1}
    for o in ps.outputs {
        if o.semantic=="SV_Target"&&o.index>=0&&o.index<4&&o.used {target[o.index]=o.base}
    }
    strings.write_string(&w,"    Mirai_Surface s = mirai_surface_default(ctx);\n")
    strings.write_string(&w,"    s.alpha = e.discarded ? 0.0 : 1.0;\n")
    if target[0]>=0 {fmt.sbprintfln(&w,"    float3 scene = float3(e.pout[%d].v, e.pout[%d].v, e.pout[%d].v);",target[0],target[0]+1,target[0]+2)}
    if target[1]>=0&&target[2]>=0&&target[3]>=0 {
        // Unreal's surface targets: the normal as half of it plus a half; metallic, specular
        // (a half is the default reflectance), roughness and the shading model; base colour
        // and occlusion.
        fmt.sbprintfln(&w,"    float3 n = float3(e.pout[%d].v, e.pout[%d].v, e.pout[%d].v) * 2.0 - 1.0;",target[1],target[1]+1,target[1]+2)
        strings.write_string(&w,"    if (dot(n, n) > 1e-6) s.normal = normalize(dx_to_mirai(n));\n")
        fmt.sbprintfln(&w,"    s.metallic = saturate(e.pout[%d].v);",target[2])
        fmt.sbprintfln(&w,"    s.specular_factor = saturate(e.pout[%d].v) * 2.0;",target[2]+1)
        fmt.sbprintfln(&w,"    s.roughness = saturate(e.pout[%d].v);",target[2]+2)
        fmt.sbprintfln(&w,"    s.base_color = saturate(float3(e.pout[%d].v, e.pout[%d].v, e.pout[%d].v));",target[3],target[3]+1,target[3]+2)
        fmt.sbprintfln(&w,"    s.occlusion = saturate(e.pout[%d].v);",target[3]+3)
        if target[0]>=0 {strings.write_string(&w,"    s.emission = max(scene, float3(0.0));\n")}
        // The shading model in the low four bits of the last channel: zero is unlit.
        fmt.sbprintfln(&w,"    if ((int(e.pout[%d].v * 255.0 + 0.5) & 15) == 0) {{ s.unlit = true; s.base_color = float3(0.0); }}",target[2]+3)
    } else if target[0]>=0 {
        // One target: the colour it shows, and how much of it.
        strings.write_string(&w,"    s.unlit = true;\n    s.base_color = float3(0.0);\n    s.emission = max(scene, float3(0.0));\n")
        fmt.sbprintfln(&w,"    if (!e.discarded) s.alpha = saturate(e.pout[%d].v);",target[0]+3)
    } else {
        strings.builder_destroy(&w)
        return {},Error{"program","the pixel shader writes no target this importer reads"}
    }
    strings.write_string(&w,"    return s;\n}\n}\n")

    p.name=strings.clone(name,allocator)
    p.source=strings.to_string(w)
    p.parameters=make([]Cooked_Program_Parameter,len(slots)+len(registers),allocator)
    for k,i in slots {
        tex_v,_:=json_get(tb[k],"Texture")
        p.parameters[i]={name=fmt.aprintf("t%d",k,allocator=allocator),is_texture=true,texture=strings.clone(json_str(tex_v),allocator)}
    }
    for r,i in registers {
        prm:=Cooked_Program_Parameter{name=fmt.aprintf("m%d",r,allocator=allocator)}
        if r<len(ub) {
            row,_:=json_arr(ub[r])
            for c in 0..<min(len(row),4) {prm.value[c],_=json_f32(row[c])}
        }
        p.parameters[len(slots)+i]=prm
    }
    // View registers the shaders read that dx_view does not answer.
    answered:=[?]int{44,45,46,47,77,84,85,87,125,128,148,155,156,159,163,164,165,166,167,168,169,170,171,172,173,174,212,361}
    for stage in ([2]^Stage{&ps,&vs}) {
        for r in stage.registers["View"] {
            if !slice.contains(answered[:],r) {note_add(&notes,fmt.tprintf("the register %d of the view",r))}
        }
    }
    p.notes=make([]string,len(notes),allocator)
    for n,i in notes {p.notes[i]=strings.clone(n,allocator)}
    return p,nil
}
