package unreal_vfx_editor

import "core:fmt"
import "core:strings"

// The bodies of the functions of grids, render targets and curves.
//
// A grid of Niagara is a resource grid of the program, as many cells as the
// data interface says, and its floats in the words of each cell: the unnamed
// attributes first, then those the scripts name. A render target keeps one
// float4 a cell. Unit coordinates go from 0 to 1 over the cells, whose
// middles are at (i + 0.5) / cells. A 2D one is flat along y, as a texture of
// the world is (vfx.Particle_World_Texture): its cell (x, y) is the cell
// (x, 0, y) of the grid, and the bodies take what they read and give back to
// the order of Niagara.

// The inputs and the outputs of a function, in order.
@(private)
niagara_split :: proc(params:[]Hlsl_Field) -> (ins,outs:[]Hlsl_Field) {
    a,b:=make([dynamic]Hlsl_Field,context.temp_allocator),make([dynamic]Hlsl_Field,context.temp_allocator)
    for p in params {
        if strings.has_prefix(p.type,"out ") || strings.has_prefix(p.type,"inout ") {append(&b,p)} else {append(&a,p)}
    }
    return a[:],b[:]
}

@(private)
niagara_grid_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base,specifier:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    ins,outs:=niagara_split(params)
    R:=di.resource
    three:=di.three
    b:=strings.builder_make(context.temp_allocator)
    in_ :: proc(list:[]Hlsl_Field,i:int) -> string {return i<len(list)?list[i].name:"0"}
    // The cell of the first inputs: X, Y (and Z of a 3D grid).
    index:=three?fmt.tprintf("int3(%s, %s, %s)",in_(ins,0),in_(ins,1),in_(ins,2)):fmt.tprintf("int3(%s, 0, %s)",in_(ins,0),in_(ins,1))
    after:=three?3:2 // inputs after those of the cell
    cells:=three?fmt.tprintf("niagara_grid_cells(%s)",R):fmt.tprintf("niagara_grid_cells(%s).xzy",R)
    named:=niagara_attribute_named(specifier)
    offset,count:=-1,niagara_value_floats(base)
    for a in di.named {if a.name==named {offset,count=a.offset,a.count}}
    // Writes count floats of value at the float first of a cell.
    write_floats :: proc(b:^strings.Builder,R,cell,first,value:string,count:int) {
        axes:="xyzw"
        if count==1 {fmt.sbprintf(b,"    niagara_grid_store(%s, %s, %s, %s);\n",R,cell,first,value);return}
        for i in 0..<count {fmt.sbprintf(b,"    niagara_grid_store(%s, %s, (%s) + %d, %s.%c);\n",R,cell,first,i,value,axes[i])}
    }
    read_floats :: proc(b:^strings.Builder,R,cell,first,target:string,count:int,written:bool) {
        axes:="xyzw"
        if count==1 {fmt.sbprintf(b,"    %s = niagara_grid_load(%s, %s, %s, %v);\n",target,R,cell,first,written);return}
        for i in 0..<count {fmt.sbprintf(b,"    %s.%c = niagara_grid_load(%s, %s, (%s) + %d, %v);\n",target,axes[i],R,cell,first,i,written)}
    }
    sample_floats :: proc(b:^strings.Builder,R,unit,first,target:string,count:int) {
        axes:="xyzw"
        if count==1 {fmt.sbprintf(b,"    %s = niagara_grid_sample(%s, %s, %s);\n",target,R,unit,first);return}
        for i in 0..<count {fmt.sbprintf(b,"    %s.%c = niagara_grid_sample(%s, %s, (%s) + %d);\n",target,axes[i],R,unit,first,i)}
    }
    unit3 :: proc(three:bool,value:string) -> string {return three?value:fmt.tprintf("float3((%s).x, 0.5, (%s).y)",value,value)}
    out_ :: proc(list:[]Hlsl_Field,i:int) -> string {return i<len(list)?list[i].name:"niagara_unused"}
    dims:=three?"xyz":"xy"
    switch base {
    case "GetNumCells","GetRenderTargetSize","GetTextureSize":
        for i in 0..<len(outs) {fmt.sbprintf(&b,"    %s = %s.%c;\n",outs[i].name,cells,dims[min(i,len(dims)-1)])}
    case "GetCellSize":
        fmt.sbprintf(&b,"    %s = float3(%v, %v, %v).%s / float3(%s).%s;\n",out_(outs,0),di.size.x,di.size.y,di.size.z,dims,cells,dims)
    case "GetWorldBBoxSize":
        fmt.sbprintf(&b,"    %s = float3(%v, %v, %v).%s;\n",out_(outs,0),di.size.x,di.size.y,di.size.z,dims)
    case "ExecutionIndexToGridIndex","ExecToIndex":
        for i in 0..<len(outs) {fmt.sbprintf(&b,"    %s = int(GDispatchThreadId.%c);\n",outs[i].name,dims[min(i,len(dims)-1)])}
    case "ExecutionIndexToUnit","ExecToUnit":
        fmt.sbprintf(&b,"    %s = (float3(GDispatchThreadId).%s + 0.5) / float3(%s).%s;\n",out_(outs,0),dims,cells,dims)
    case "IndexToUnit":
        idx:=three?fmt.tprintf("float3(%s, %s, %s)",in_(ins,0),in_(ins,1),in_(ins,2)):fmt.tprintf("float3(%s, %s, 0.0)",in_(ins,0),in_(ins,1))
        fmt.sbprintf(&b,"    %s = (%s.%s + 0.5) / float3(%s).%s;\n",out_(outs,0),idx,dims,cells,dims)
    case "UnitToIndex":
        for i in 0..<len(outs) {fmt.sbprintf(&b,"    %s = int(floor(%s.%c * float(%s.%c)));\n",outs[i].name,in_(ins,0),dims[min(i,len(dims)-1)],cells,dims[min(i,len(dims)-1)])}
    case "UnitToFloatIndex":
        fmt.sbprintf(&b,"    %s = %s * float3(%s).%s - 0.5;\n",out_(outs,0),in_(ins,0),cells,dims)
    case "UnitToCellCornerFloatIndex":
        fmt.sbprintf(&b,"    %s = %s * float3(%s).%s;\n",out_(outs,0),in_(ins,0),cells,dims)
    case "IndexToLinear":
        if three {
            fmt.sbprintf(&b,"    %s = %s + %s.x * (%s + %s.y * %s);\n",out_(outs,0),in_(ins,0),cells,in_(ins,1),cells,in_(ins,2))
        } else {
            fmt.sbprintf(&b,"    %s = %s + %s.x * %s;\n",out_(outs,0),in_(ins,0),cells,in_(ins,1))
        }
    case "LinearToIndex":
        fmt.sbprintf(&b,"    int3 n = %s;\n    %s = %s %% n.x;\n    %s = (%s / n.x) %% n.y;\n",cells,out_(outs,0),in_(ins,0),out_(outs,1),in_(ins,0))
        if three {fmt.sbprintf(&b,"    %s = %s / (n.x * n.y);\n",out_(outs,2),in_(ins,0))}
    case "CopyPreviousToCurrentForCell","SetNumCells","ClearCell":
    case "GetFloatAttributeIndex","GetVector2DAttributeIndex","GetVectorAttributeIndex","GetVector4AttributeIndex","GetVector3AttributeIndex","GetVector2AttributeIndex":
        fmt.sbprintf(&b,"    %s = %d;\n",out_(outs,0),max(offset,0))
    case "SetRenderTargetValue":
        // bool enabled, X, Y[, Z], float4 value
        cell:=three?fmt.tprintf("int3(%s, %s, %s)",in_(ins,1),in_(ins,2),in_(ins,3)):fmt.tprintf("int3(%s, 0, %s)",in_(ins,1),in_(ins,2))
        fmt.sbprintf(&b,"    if (%s) niagara_grid_write4(%s, %s, %s);\n",in_(ins,0),R,cell,in_(ins,len(ins)-1))
    case "GetRenderTargetValue","LoadRenderTargetValue":
        fmt.sbprintf(&b,"    %s = niagara_grid_load4(%s, %s, false);\n",out_(outs,0),R,index)
    case "SampleRenderTargetValue","SampleRenderTarget":
        fmt.sbprintf(&b,"    %s = float4(niagara_grid_sample(%s, %s, 0), niagara_grid_sample(%s, %s, 1), niagara_grid_sample(%s, %s, 2), niagara_grid_sample(%s, %s, 3));\n",out_(outs,0),R,unit3(three,in_(ins,0)),R,unit3(three,in_(ins,0)),R,unit3(three,in_(ins,0)),R,unit3(three,in_(ins,0)))
    case:
        // The functions of named attributes and of attributes by index.
        switch {
        case offset>=0 && strings.has_prefix(base,"Set") && !strings.contains(base,"AtIndex"):
            write_floats(&b,R,index,fmt.tprintf("%d",offset),in_(ins,after),count)
        case offset>=0 && strings.has_prefix(base,"GetOutput"):
            read_floats(&b,R,index,fmt.tprintf("%d",offset),out_(outs,0),count,true)
        case offset>=0 && strings.has_prefix(base,"Get") && !strings.contains(base,"AtIndex"):
            read_floats(&b,R,index,fmt.tprintf("%d",offset),out_(outs,0),count,false)
        case offset>=0 && strings.has_prefix(base,"Sample"):
            sample_floats(&b,R,unit3(three,in_(ins,0)),fmt.tprintf("%d",offset),out_(outs,0),count)
        case strings.contains(base,"AtIndex") && strings.has_prefix(base,"Set"), base=="SetGridValue", base=="SetFloatGridValue":
            write_floats(&b,R,index,in_(ins,after),in_(ins,after+1),count)
        case strings.contains(base,"AtIndex") && strings.has_prefix(base,"Get"), base=="GetGridValue", base=="GetFloatGridValue":
            read_floats(&b,R,index,in_(ins,after),out_(outs,0),count,false)
        case strings.contains(base,"AtIndex") && strings.has_prefix(base,"Sample"), base=="SampleGrid":
            sample_floats(&b,R,unit3(three,in_(ins,0)),in_(ins,1),out_(outs,0),count)
        case:
            return "",false
        }
    }
    return strings.to_string(b),true
}

// A curve: the samples of its LUT over its times, linearly between them.
@(private)
niagara_curve_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    if base!="SampleCurve" && base!="SampleColorCurve" && base!="SampleVectorCurve" && base!="SampleVector2DCurve" && base!="SampleVector4Curve" {return}
    ins,outs:=niagara_split(params)
    if len(ins)<1 || len(outs)<1 {return}
    channels:=max(di.channels,1)
    samples:=len(di.lut)/channels
    if samples<1 {return}
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"    static const float lut[%d] = {{",samples*channels)
    for v,i in di.lut[:samples*channels] {
        if i>0 {strings.write_string(&b,",")}
        fmt.sbprintf(&b,"%v",v)
    }
    strings.write_string(&b,"};\n")
    span:=di.lut_end-di.lut_start
    fmt.sbprintf(&b,"    float t = saturate((%s - %v) / %v) * %d.0;\n",ins[0].name,di.lut_start,span!=0?span:1,samples-1)
    fmt.sbprintf(&b,"    int i0 = min(int(t), %d); int i1 = min(i0 + 1, %d); float f = t - float(i0);\n",samples-1,samples-1)
    axes:="xyzw"
    out:=outs[0].name
    if channels==1 {
        fmt.sbprintf(&b,"    %s = lerp(lut[i0], lut[i1], f);\n",out)
    } else {
        for c in 0..<channels {fmt.sbprintf(&b,"    %s.%c = lerp(lut[i0 * %d + %d], lut[i1 * %d + %d], f);\n",out,axes[c],channels,c,channels,c)}
    }
    return strings.to_string(b),true
}
