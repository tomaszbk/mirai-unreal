package unreal_vfx_editor

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"

// The data interfaces of Niagara as Mirai translates them: what each class
// is (a grid of the world, the particles of another emitter, a curve baked
// into the program...), the resource of the program it reads, and a body of
// Slang for each function of it the scripts call, over the functions of
// niagara_interfaces.slang. A function the translator has no body for gives
// zero, and the program says so.

Niagara_Di_Kind :: enum u8 {
    Unknown,
    Curve,        // Curve, ColorCurve, VectorCurve, Vector2DCurve, Vector4Curve: their LUT
    Grid,         // Grid2DCollection, Grid3DCollection and their readers
    Render_Target,// RenderTarget2D, RenderTargetVolume: a grid of one float4
    Neighbors,    // NeighborGrid3D: counts and particle indices by cell
    Raster,       // RasterizationGrid3D: integers splatted by particles
    Particles,    // ParticleRead: another emitter
    Noise,        // CurlNoise
    Texture,      // Texture: a grid its texels are baked into; VolumeTexture
    Collision,    // CollisionQuery, RigidMeshCollisionQuery, AsyncGpuTrace
    Camera,
    GBuffer,
    Mesh,         // StaticMesh, SkeletalMesh
    Channel_Read, // DataChannelRead
    Channel_Write,// DataChannelWrite
    Vector_Field, // VectorField: a grid its field is baked into
    Array,        // ArrayFloat, ArrayFloat3, ArrayInt32...: its values as constants
    Emitter_Info, // EmitterProperties, EmitterBinding, MeshRendererInfo, GPUParamInfo
}

// A data interface of a program.
Niagara_Di :: struct {
    name,symbol,class:string,
    object:level.Ref,
    found:bool,
    kind:Niagara_Di_Kind,
    resource:string,                // the resource of the program it reads; "" none
    cells:[3]int,                   // of a grid, a render target or the neighbors
    size:[3]f32,                    // of a grid: its box in Unreal's centimetres
    floats:int,                     // of a grid: floats of each cell (its attributes, then the named ones)
    named:[dynamic]Niagara_Attribute, // of a grid: the attributes the scripts name
    max_neighbors:int,              // of the neighbors: indices of each cell
    lut:[]f32,                      // of a curve: its samples
    channels:int,
    lut_start,lut_end:f32,
    three:bool,                     // a 3D grid or render target
    other:string,                   // of the particles of another emitter: the name of its handle
    channel:Niagara_Channel,        // of a data channel: its name and the layout of its entries
    field:Niagara_Field,            // of a vector field: its grid, texels and bounds
    tile:[3]bool,                   // of a vector field: the axes it repeats along
    user:string,                    // of a render target: the parameter of the system whose texture it writes; "" none
    texture:Niagara_Texture,        // of a texture: its grid and cells
}

// An attribute of a grid that a script names: where its floats start among those of a cell.
Niagara_Attribute :: struct {name:string,count,offset:int}

// The data interfaces of a script, added to those of the program once.
@(private)
niagara_interfaces_add :: proc(w:^Niagara_Writer,interfaces:[]Niagara_Interface) {
    for each in interfaces {
        known:=false
        for di in w.interfaces {known||=di.name==each.name}
        if known {continue}
        di:=Niagara_Di{name=each.name,symbol=niagara_symbol(each.name),class=strings.trim_prefix(each.class,"NiagaraDataInterface"),object=each.object,found=each.found}
        di.named=make([dynamic]Niagara_Attribute,context.temp_allocator)
        if !di.found && w.emitter!=nil && w.emitter.source!=nil {
            di.object,di.found=niagara_object_named(w.d,w.emitter.source.object.pkg,each.class,each.name)
        }
        switch di.class {
        case "Curve","ColorCurve","VectorCurve","Vector2DCurve","Vector4Curve": di.kind=.Curve
        case "Grid2DCollection","Grid2DCollectionReader": di.kind=.Grid
        case "Grid3DCollection","Grid3DCollectionReader": di.kind,di.three=.Grid,true
        case "RenderTarget2D": di.kind=.Render_Target
        case "RenderTargetVolume": di.kind,di.three=.Render_Target,true
        case "NeighborGrid3D": di.kind,di.three=.Neighbors,true
        case "RasterizationGrid3D": di.kind,di.three=.Raster,true
        case "ParticleRead": di.kind=.Particles
        case "CurlNoise": di.kind=.Noise
        case "Texture","VolumeTexture": di.kind=.Texture
        case "CollisionQuery","RigidMeshCollisionQuery","AsyncGpuTrace": di.kind=.Collision
        case "Camera": di.kind=.Camera
        case "GBuffer": di.kind=.GBuffer
        case "StaticMesh","SkeletalMesh": di.kind=.Mesh
        case "DataChannelRead": di.kind=.Channel_Read
        case "DataChannelWrite": di.kind=.Channel_Write
        case "VectorField": di.kind=.Vector_Field
        case "ArrayFloat","ArrayFloat2","ArrayFloat3","ArrayFloat4","ArrayColor","ArrayQuat","ArrayInt32": di.kind=.Array
        case "EmitterProperties","EmitterBinding","EmitterBindingMode","MeshRendererInfo","GPUParamInfo": di.kind=.Emitter_Info
        }
        append(&w.interfaces,di)
    }
}

// The object of a data interface that saves property: the one its scripts
// keep, or the one of the stack of the emitter named after it (Emitter.Texture
// Sample: Emitter_Texture_Sample) when their copy keeps only its defaults.
@(private)
niagara_di_holder :: proc(w:^Niagara_Writer,di:^Niagara_Di,property:string) -> (holder:level.Ref,ok:bool) {
    if !di.found {return}
    saves :: proc(d:^level.Document,ref:level.Ref,property:string) -> bool {
        f,error:=level.property(d,ref,property)
        return error.code==.None && f.property!=nil && f.origin==.Authored
    }
    if saves(w.d,di.object,property) {return di.object,true}
    named,found:=niagara_object_named(w.d,di.object.pkg,strings.concatenate({"NiagaraDataInterface",di.class},context.temp_allocator),di.name)
    if found && named!=di.object && saves(w.d,named,property) {return named,true}
    return
}

// The parameter of the system a binding of a data interface names
// (NiagaraUserParameterBinding: User.Texture); "" none. Its variable is saved
// natively, its name first.
@(private)
niagara_user_binding :: proc(d:^level.Document,ref:level.Ref,name:string) -> string {
    binding:=struct_at(d,ref,name)
    parameter:=struct_field(&binding,"Parameter")
    if parameter==nil {return ""}
    raw,error:=unreal.span_bytes(binding.p,parameter.data)
    if error.code!=.None || len(raw)<8 {return ""}
    return niagara_name_at(binding.p,raw)
}

// A name saved natively at the start of raw: its index and its number.
@(private)
niagara_name_at :: proc(p:^unreal.Package,raw:[]u8) -> string {
    index,_:=endian.get_i32(raw,.Little)
    number,_:=endian.get_i32(raw[4:],.Little)
    if !unreal.name_valid(p,{index,number}) {return ""}
    return unreal.name_text(p,{index,number},context.temp_allocator)
}

// The data interface a function of the scripts belongs to, by the symbol in its name.
@(private)
niagara_interface_of :: proc(w:^Niagara_Writer,function:string) -> (di:^Niagara_Di,ok:bool) {
    best:=-1
    for &each,at in w.interfaces {
        // Its functions name it after their own (SampleGrid_Emitter_Grid), its helpers before (Emitter_Mesh_PackTangent).
        if each.symbol=="" {continue}
        if !strings.contains(function,strings.concatenate({"_",each.symbol},context.temp_allocator)) && !strings.has_prefix(function,strings.concatenate({each.symbol,"_"},context.temp_allocator)) {continue}
        if best<0 || len(each.symbol)>len(w.interfaces[best].symbol) {best=at}
    }
    if best<0 {return nil,false}
    return &w.interfaces[best],true
}

@(private)
niagara_interface_named :: proc(w:^Niagara_Writer,name:string) -> (di:^Niagara_Di,ok:bool) {
    for &each in w.interfaces {if each.name==name {return &each,true}}
    return nil,false
}

// The dispatch of a stage over a data interface: 2D or 3D.
@(private)
niagara_dispatch :: proc(w:^Niagara_Writer,name:string) -> i64 {
    if di,ok:=niagara_interface_named(w,name);ok && di.three {return 2}
    return 1
}

// The base name of a function of a data interface (SetVector4Value), and
// what follows its symbol (_AttributeRGBA), without _UEImpureCall.
@(private)
niagara_function_parts :: proc(function:string,di:^Niagara_Di) -> (base,specifier:string) {
    plain,_:=strings.replace_all(function,"_UEImpureCall","",context.temp_allocator)
    at:=strings.index(plain,strings.concatenate({"_",di.symbol},context.temp_allocator))
    if at<0 {return plain,""}
    return plain[:at],plain[at+1+len(di.symbol):]
}

// The name a specifier gives a named attribute (_AttributeRGBA: RGBA), the
// last of the specifier: _AttributePrevious_Position is Previous_Position,
// as the attributes of an emitter are flattened.
@(private)
niagara_attribute_named :: proc(specifier:string) -> string {
    at:=strings.index(specifier,"_Attribute")
    if strings.has_prefix(specifier,"Attribute") {at=-1} else if at<0 {return ""}
    return specifier[at+len("_Attribute"):]
}

// The floats of the value a function of a grid reads or writes, by its name.
@(private)
niagara_value_floats :: proc(base:string) -> int {
    switch {
    case strings.contains(base,"Vector4"): return 4
    case strings.contains(base,"Vector3") || strings.contains(base,"VectorValue") || strings.contains(base,"VectorAt") || strings.has_suffix(base,"Vector"): return 3
    case strings.contains(base,"Vector2"): return 2
    }
    return 1
}

// A number of the object of a data interface; default when it keeps none.
@(private)
niagara_di_real :: proc(w:^Niagara_Writer,di:^Niagara_Di,name:string,default:f64) -> f64 {
    if !di.found {return default}
    value,_:=level.real_of(w.d,di.object,name,default)
    return value
}

// The integers of a struct (IntPoint, IntVector) of the object of a data
// interface, X, Y and Z; defaults where it keeps none.
@(private)
niagara_di_ints :: proc(w:^Niagara_Writer,di:^Niagara_Di,name:string,defaults:[3]int) -> (v:[3]int) {
    v=defaults
    if !di.found {return}
    f,error:=level.property(w.d,di.object,name)
    if error.code!=.None || f.property==nil {return}
    fields,fields_error:=unreal.property_tagged_struct(f.pkg,f.property,true,context.temp_allocator)
    if fields_error.code!=.None {return}
    for axis,i in ([3]string{"X","Y","Z"}) {
        if found,ok:=level.value_real(f.pkg,unreal.property_find(f.pkg,&fields,axis),f64(defaults[i]));ok {v[i]=int(found)}
    }
    return
}

// The floats of a vector of the object of a data interface.
@(private)
niagara_di_vector :: proc(w:^Niagara_Writer,di:^Niagara_Di,name:string,defaults:[3]f32) -> (v:[3]f32) {
    v=defaults
    if !di.found {return}
    f,error:=level.property(w.d,di.object,name)
    if error.code!=.None || f.property==nil {return}
    value,value_error:=unreal.property_value(f.pkg,f.property,context.temp_allocator)
    if value_error.code!=.None || value.kind!=.Real_Vector {return}
    for i in 0..<min(int(value.vector_count),3) {v[i]=f32(value.vector[i])}
    return
}

// What the objects of the data interfaces say: the cells and box of grids,
// render targets and neighbors, the LUT of curves; and the resource each
// one is of the program.
@(private)
niagara_interfaces_resolve :: proc(w:^Niagara_Writer) {
    for &di in w.interfaces {
        switch di.kind {
        case .Curve:
            channels:=4 if strings.has_suffix(di.class,"ColorCurve") || strings.has_suffix(di.class,"Vector4Curve") else 3 if strings.has_suffix(di.class,"VectorCurve") else 2 if strings.has_suffix(di.class,"Vector2DCurve") else 1
            di.channels=channels
            if di.found {
                di.lut=struct_field_floats(w.d,di.object,"ShaderLUT")
                di.lut_start=real(w.d,di.object,"LUTMinTime",0)
                di.lut_end=real(w.d,di.object,"LUTMaxTime",1)
            }
        case .Particles:
            di.other=niagara_bound_emitter(w.d,di.found?di.object:level.Ref{w.emitter.source.object.pkg,0},di.found,di.name)
            // A reader named after the emitter it reads (Emitter.SortParticles_ParticleReader).
            if di.other=="" {
                short:=di.name[strings.index_byte(di.name,'.')+1:]
                for name in w.system.emitters {
                    if strings.has_prefix(short,strings.concatenate({name,"_"},context.temp_allocator)) && len(name)>len(di.other) {di.other=name}
                }
            }
        case .Grid,.Neighbors,.Raster:
            if di.kind==.Grid {
                layout:=niagara_grid_layout(w.system,niagara_grid_key(w,w.emitter,&di))
                di.floats=max(layout.floats,1)
                clear(&di.named)
                append(&di.named,..layout.named[:])
            }
            if di.three {
                di.size=niagara_di_vector(w,&di,"WorldBBoxSize",{100,100,100})
                cells:=niagara_di_ints(w,&di,"NumCells",{3,3,3})
                method:=""
                if di.found {method,_=level.enum_of(w.d,di.object,"SetResolutionMethod","Independent")}
                switch method {
                case "MaxAxis":
                    longest:=max(di.size.x,max(di.size.y,di.size.z))
                    axis:=int(niagara_di_real(w,&di,"NumCellsMaxAxis",10))
                    for i in 0..<3 {cells[i]=max(int(math.round(f64(axis)*f64(di.size[i])/f64(max(longest,1e-3)))),1)}
                case "CellSize":
                    size:=niagara_di_real(w,&di,"CellSize",1)
                    for i in 0..<3 {cells[i]=max(int(math.ceil(f64(di.size[i])/max(size,1e-3))),1)}
                }
                di.cells=cells
            } else {
                box:=niagara_di_vector(w,&di,"WorldBBoxSize",{100,100,0})
                di.size={box.x,box.y,1}
                di.cells={int(niagara_di_real(w,&di,"NumCellsX",3)),int(niagara_di_real(w,&di,"NumCellsY",3)),1}
                if niagara_di_real(w,&di,"SetGridFromMaxAxis",0)!=0 {
                    axis:=f64(niagara_di_real(w,&di,"NumCellsMaxAxis",3))
                    longest:=max(box.x,box.y)
                    di.cells.x=max(int(math.round(axis*f64(box.x)/f64(max(longest,1e-3)))),1)
                    di.cells.y=max(int(math.round(axis*f64(box.y)/f64(max(longest,1e-3)))),1)
                }
            }
            if di.kind==.Neighbors {di.max_neighbors=max(int(niagara_di_real(w,&di,"MaxNeighborsPerCell",8)),1)}
        case .Render_Target:
            if di.three {
                di.cells=niagara_di_ints(w,&di,"Size",{64,64,64})
            } else {
                size:=niagara_di_ints(w,&di,"Size",{128,128,1})
                di.cells={size.x,size.y,1}
            }
            if holder,held:=niagara_di_holder(w,&di,"RenderTargetUserParameter");held {di.user=niagara_user_binding(w.d,holder,"RenderTargetUserParameter")}
            di.size={f32(di.cells.x),f32(di.cells.y),f32(di.cells.z)}
        case .Vector_Field:
            field,read:=niagara_vector_field(w,&di)
            if !read {
                append(&w.problems,fmt.tprintf("%s names no vector field this import reads: it samples zero",di.name))
                continue
            }
            di.field=field
            for axis,i in ([3]string{"bTileX","bTileY","bTileZ"}) {
                if f,error:=level.property(w.d,di.object,axis);error.code==.None && f.property!=nil {di.tile[i]=value_flag(f.pkg,f.property,false)}
            }
            di.resource=strings.concatenate({"di_",di.symbol},context.temp_allocator)
            append(&w.resources,fmt.tprintf("//! resource %s grid",di.resource))
            continue
        case .Texture:
            if di.class!="Texture" {continue}
            baked,read:=niagara_texture(w,&di)
            if !read {
                append(&w.problems,fmt.tprintf("%s names no texture this import reads: it samples zero",di.name))
                continue
            }
            di.texture=baked
            di.resource=strings.concatenate({"di_",di.symbol},context.temp_allocator)
            append(&w.resources,fmt.tprintf("//! resource %s grid",di.resource))
            continue
        case .Channel_Read,.Channel_Write:
            if di.found {di.channel=niagara_channel(w.d,di.object)}
            if di.channel.name=="" {
                append(&w.problems,fmt.tprintf("%s names no data channel this import reads: it reads and writes nothing",di.name))
                continue
            }
            // The data channel of the world of the name of the asset: one resource for each.
            di.resource=di.channel.name
            known:=false
            for line in w.resources {known||=strings.has_prefix(line,fmt.tprintf("//! resource %s ",di.resource))}
            if !known {append(&w.resources,fmt.tprintf("//! resource %s data %d",di.resource,max(di.channel.words,1)))}
            continue
        case .Unknown,.Noise,.Collision,.Camera,.GBuffer,.Mesh,.Emitter_Info,.Array:
        }
        for i in 0..<3 {di.cells[i]=clamp(di.cells[i],1,512)}
        kind:=""
        #partial switch di.kind {
        case .Grid,.Render_Target: kind="grid"
        case .Neighbors,.Raster: kind="grid cleared"
        case .Particles: kind="emitter"
        case .Mesh: kind="surface"
        }
        if kind=="" {continue}
        di.resource=strings.concatenate({"di_",di.symbol},context.temp_allocator)
        append(&w.resources,fmt.tprintf("//! resource %s %s",di.resource,kind))
    }
}

// The layers of four floats the grid of a data interface keeps in each cell.
@(private)
niagara_di_layers :: proc(di:^Niagara_Di) -> int {
    #partial switch di.kind {
    case .Grid: return (di.floats+3)/4
    case .Render_Target: return 1
    case .Neighbors: return (di.max_neighbors+1+3)/4
    case .Raster: return (max(di.floats,1)+3)/4
    }
    return 0
}

// The body of a function of a data interface the scripts call.
@(private)
niagara_call_write :: proc(w:^Niagara_Writer,out:^strings.Builder,part:^Niagara_Part,item:Hlsl_Item) {
    di,_:=niagara_interface_of(w,item.name)
    params:=hlsl_params(item.params)
    // A function of the VM takes the instance of its data interface first.
    if part.vm && len(params)>0 && strings.contains(params[0].name,"InstanceData") {params=params[1:]}
    base,specifier:=niagara_function_parts(item.name,di)
    // A stage that writes the grid reads what it leaves; the others what the stage before left.
    written:=part.info.over==di.name
    for output in part.info.outputs {written||=output==di.name}
    body,ok:=niagara_body(w,di,base,specifier,params,written)
    fmt.sbprintf(out,"%s %s(%s) {{\n",item.result,item.name,item.params)
    if ok {
        strings.write_string(out,body)
    } else {
        problem:=fmt.tprintf("%s.%s (%s) is not translated: it gives zero",di.name,base,di.class)
        known:=false
        for p in w.problems {known||=p==problem}
        if !known {append(&w.problems,problem)}
        for p in params {
            if strings.has_prefix(p.type,"out ") {fmt.sbprintf(out,"    %s = (%s)0;\n",p.name,strings.trim_prefix(p.type,"out "))}
        }
        if item.result!="void" {fmt.sbprintf(out,"    return (%s)0;\n",item.result)}
    }
    strings.write_string(out,"}\n")
    // HLSL converts an int a script passes to an out bool; Slang takes it through an overload.
    all:=hlsl_params(item.params)
    has_bool:=false
    for p in all {has_bool||=p.type=="out bool"}
    if !has_bool || item.result!="void" {return}
    declared,call,after:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    for p,i in all {
        if i>0 {strings.write_string(&declared,", ");strings.write_string(&call,", ")}
        if p.type=="out bool" {
            fmt.sbprintf(&declared,"out int %s",p.name)
            fmt.sbprintf(&call,"%s_bool",p.name)
            fmt.sbprintf(&after,"    %s = %s_bool ? 1 : 0;\n",p.name,p.name)
        } else {
            fmt.sbprintf(&declared,"%s %s",p.type,p.name)
            strings.write_string(&call,p.name)
        }
    }
    fmt.sbprintf(out,"void %s(%s) {{\n",item.name,strings.to_string(declared))
    for p in all {if p.type=="out bool" {fmt.sbprintf(out,"    bool %s_bool;\n",p.name)}}
    fmt.sbprintf(out,"    %s(%s);\n%s}}\n",item.name,strings.to_string(call),strings.to_string(after))
}

// The Slang of a function of a data interface; false for one the translator does not know.
@(private)
niagara_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base,specifier:string,params:[]Hlsl_Field,written:bool) -> (body:string,ok:bool) {
    a :: proc(params:[]Hlsl_Field,i:int) -> string {return i<len(params)?params[i].name:"0"}
    switch di.kind {
    case .Unknown,.Camera,.Raster:
        return
    case .Texture:
        return niagara_texture_body(w,di,base,params)
    case .Emitter_Info:
        if di.class=="MeshRendererInfo" {return niagara_renderer_body(w,di,base,params)}
        return
    case .GBuffer:
        return niagara_gbuffer_body(base,params)
    case .Mesh:
        return niagara_mesh_body(w,di,base,params)
    case .Channel_Read,.Channel_Write:
        return niagara_channel_body(w,di,base,specifier,params)
    case .Vector_Field:
        return niagara_vector_field_body(w,di,base,params)
    case .Array:
        return niagara_array_body(w,di,base,params)
    case .Collision:
        return niagara_collision_body(base,params)
    case .Particles:
        return niagara_read_body(w,di,base,specifier,params)
    case .Neighbors:
        return niagara_neighbors_body(w,di,base,specifier,params,written)
    case .Noise:
        if base=="SampleNoiseField" {return fmt.tprintf("    %s = niagara_curl_noise(%s);\n",a(params,1),a(params,0)),true}
    case .Curve:
        return niagara_curve_body(w,di,base,params)
    case .Grid,.Render_Target:
        return niagara_grid_body(w,di,base,specifier,params)
    }
    return
}
