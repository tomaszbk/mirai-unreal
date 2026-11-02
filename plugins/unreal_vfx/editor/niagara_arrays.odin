package unreal_vfx_editor

import "core:fmt"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"

// The Array data interfaces (ArrayFloat, ArrayFloat3, ArrayInt32...): the
// values their object keeps, as a constant of the program. Of a vector, the
// array of floats it keeps for the GPU (Internal*Data), else the one of the
// editor; each element the floats of its type, back to back at the end of the
// array.

// The floats of each element of an Array data interface of a class; 0 for one it does not read.
@(private)
niagara_array_width :: proc(class:string) -> (width:int,property:string,integer:bool) {
    switch class {
    case "ArrayFloat": return 1,"FloatData",false
    case "ArrayFloat2": return 2,"InternalFloatData",false
    case "ArrayFloat3": return 3,"InternalFloatData",false
    case "ArrayFloat4","ArrayColor","ArrayQuat": return 4,"InternalFloatData",false
    case "ArrayInt32": return 1,"IntData",true
    }
    return
}

// The values of an Array data interface; nil without its object.
@(private)
niagara_array_values :: proc(d:^level.Document,di:^Niagara_Di) -> (values:[]f32,width:int) {
    if !di.found {return}
    property:string
    integer:bool
    width,property,integer=niagara_array_width(di.class)
    if width==0 {return}
    for name in ([2]string{property,"FloatData"}) {
        f,error:=level.property(d,di.object,name)
        if error.code!=.None || f.property==nil {continue}
        view,view_error:=unreal.property_array(f.pkg,f.property)
        if view_error.code!=.None || view.count==0 {continue}
        bytes:=i64(view.count)*i64(width)*4
        if name=="FloatData" && width>1 {bytes*=2} // the editor keeps doubles
        if view.data.size<bytes {continue}
        at:=view.data.offset+view.data.size-bytes
        out:=make([]f32,int(view.count)*width,context.temp_allocator)
        for i in 0..<len(out) {
            switch {
            case integer: out[i]=f32((^i32le)(&f.pkg.bytes[at+i64(i)*4])^)
            case name=="FloatData" && width>1: out[i]=f32((^f64le)(&f.pkg.bytes[at+i64(i)*8])^)
            case: out[i]=f32((^f32le)(&f.pkg.bytes[at+i64(i)*4])^)
            }
        }
        return out,width
    }
    return
}

// The functions of the Array data interfaces that read.
@(private)
niagara_array_body :: proc(w:^Niagara_Writer,di:^Niagara_Di,base_name:string,params:[]Hlsl_Field) -> (body:string,ok:bool) {
    values,width:=niagara_array_values(w.d,di)
    ins,outs:=niagara_split(params)
    count:=len(values)/max(width,1)
    b:=strings.builder_make(context.temp_allocator)
    switch base_name {
    case "Length","GetNum","Num":
        if len(outs)<1 {return}
        fmt.sbprintf(&b,"    %s = %d;\n",outs[0].name,count)
    case "Get","GetValue","GetValueByIndex":
        if len(ins)<1 || len(outs)<1 {return}
        out:=outs[len(outs)-1]
        type:=strings.trim_prefix(out.type,"out ")
        if count==0 {
            fmt.sbprintf(&b,"    %s = (%s)0;\n",out.name,type)
            break
        }
        fmt.sbprintf(&b,"    static const float values[%d] = {{",len(values))
        for v,i in values {fmt.sbprintf(&b,"%s%v",i>0?",":"",v)}
        fmt.sbprintf(&b,"}};\n    int at = clamp(%s, 0, %d) * %d;\n",ins[0].name,count-1,width)
        if width==1 {
            fmt.sbprintf(&b,"    %s = (%s)values[at];\n",out.name,type)
        } else {
            fmt.sbprintf(&b,"    %s = (%s)float%d(",out.name,type,width)
            for i in 0..<width {fmt.sbprintf(&b,"%svalues[at + %d]",i>0?", ":"",i)}
            strings.write_string(&b,");\n")
        }
        if len(outs)>1 {fmt.sbprintf(&b,"    %s = (%s)true;\n",outs[0].name,strings.trim_prefix(outs[0].type,"out "))}
    case:
        return
    }
    return strings.to_string(b),true
}
