package unreal_vfx_editor

import "core:fmt"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal_scene "project:plugins/unreal/editor/scene"
import "plugins:vfx/runtime/gridfile"
import "mirai:std/base"

// VectorField: the texels of a VectorFieldStatic, half floats inline after
// the export, baked into a .grid of one cell a texel that a grid of the
// effect starts from; its program samples it between texels over the
// bounds of the field (niagara_field_sample).

Niagara_Field :: struct {
    id:base.Asset_Id,
    name:string,
    cells:[3]int,
    low,high:[3]f32, // its bounds, in Unreal's centimetres
}

// The field a VectorField data interface samples, written as a .grid; false
// for one this import does not read.
@(private)
niagara_vector_field :: proc(w:^Niagara_Writer,di:^Niagara_Di) -> (field:Niagara_Field,ok:bool) {
    if !di.found || w.scene==nil {return}
    d:=w.d
    f,error:=level.property(d,di.object,"Field")
    if error.code!=.None || f.property==nil {return}
    object,found:=object_resolve(d,di.object,value_object(f.pkg,f.property))
    if !found {return}
    field.name=object_name(d,object)
    for axis,i in ([3]string{"SizeX","SizeY","SizeZ"}) {field.cells[i]=int(real(d,object,axis,0))}
    if field.cells.x<1 || field.cells.y<1 || field.cells.z<1 || field.cells.x*field.cells.y*field.cells.z>256*256*256 {return}
    // Bounds: an FBox of two vectors of floats and whether it is valid.
    p:=level.library_package(d.library,int(object.pkg))
    if b,b_error:=level.property(d,object,"Bounds");b_error.code==.None && b.property!=nil && b.property.data.size>=24 {
        at:=b.property.data.offset
        for i in 0..<3 {
            field.low[i]=f32((^f32le)(&b.pkg.bytes[at+i64(i)*4])^)
            field.high[i]=f32((^f32le)(&b.pkg.bytes[at+12+i64(i)*4])^)
        }
    }
    // The texels follow the export: a bulk header of 24 bytes, then RGBA halves of each, x fastest.
    export:=p.exports[int(object.object)-1]
    count:=field.cells.x*field.cells.y*field.cells.z
    start:=export.data.offset+export.data.size
    if start+i64(count)*8>i64(len(p.bytes)) {return}
    cells:=make([]f32,count*4,context.temp_allocator)
    for i in 0..<count {
        for c in 0..<3 {
            half:=(^u16le)(&p.bytes[start+i64(i)*8+i64(c)*2])^
            cells[i*4+c]=f32(transmute(f16)u16(half))
        }
    }
    c:=w.scene
    span:=max(field.high.x-field.low.x,1e-3)
    info:=gridfile.Grid_Info{cells={u32(field.cells.x),u32(field.cells.y),u32(field.cells.z)},layers=1,cell_size=span/f32(field.cells.x)*CENTIMETRE}
    id,path,source:=unreal_scene.asset_place(c,gridfile.GRID_KIND,field.name,0,gridfile.GRID_EXTENSION)
    bytes,bytes_error:=gridfile.grid_bytes(c.types,{id=id,info=info,cells=cells,source=&source},context.temp_allocator)
    if bytes_error!=.None {
        unreal_scene.warn(c,"the vector field %s could not be baked (%v)",field.name,bytes_error)
        return
    }
    if !unreal_scene.asset_write(c,id,gridfile.GRID_KIND,field.name,path,bytes,fmt.tprintf("%dx%dx%d texels",field.cells.x,field.cells.y,field.cells.z)) {return}
    field.id=id
    field.name=strings.clone(field.name,context.temp_allocator)
    return field,true
}

// The functions of VectorField.
@(private)
niagara_vector_field_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base_name:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    if di.resource=="" {return}
    ins,outs:=niagara_split(params)
    b:=strings.builder_make(context.temp_allocator)
    f:=&di.field
    tile:=fmt.tprintf("bool3(%v, %v, %v)",di.tile[0],di.tile[1],di.tile[2])
    switch base_name {
    case "SampleField","SampleVectorField":
        if len(ins)<1 || len(outs)<1 {return}
        fmt.sbprintf(&b,"    %s = niagara_field_sample(%s, %s, float3(%v, %v, %v), float3(%v, %v, %v), %s);\n",outs[0].name,di.resource,ins[0].name,f.low.x,f.low.y,f.low.z,f.high.x,f.high.y,f.high.z,tile)
    case "GetVectorFieldDimensions":
        if len(outs)<1 {return}
        fmt.sbprintf(&b,"    %s = float3(%d, %d, %d);\n",outs[0].name,f.cells.x,f.cells.y,f.cells.z)
    case "GetVectorFieldBounds":
        if len(outs)<2 {return}
        fmt.sbprintf(&b,"    %s = float3(%v, %v, %v);\n    %s = float3(%v, %v, %v);\n",outs[0].name,f.low.x,f.low.y,f.low.z,outs[1].name,f.high.x,f.high.y,f.high.z)
    case "GetVectorFieldTilingAxes":
        if len(outs)<1 {return}
        fmt.sbprintf(&b,"    %s = float3(%d, %d, %d);\n",outs[0].name,int(di.tile[0]),int(di.tile[1]),int(di.tile[2]))
    case:
        return
    }
    return strings.to_string(b),true
}

