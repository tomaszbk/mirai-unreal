package material

import "core:math"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// Landscape materials. Unreal blends the layers of a landscape in one
// material, by the weights painted on it. Translated per layer, the graph is
// evaluated once per layer with that layer's weight 1 and the others 0: what
// is left is the branch of that layer, a material like any other. Translated
// whole for a terrain (Options.landscape), the weights are those the terrain
// gives its program (Layer_Weights) and the coordinates of the landscape come
// from the place of the point in the world.

// How the layers and the coordinates of a landscape are those of the terrain
// that shows it.
Landscape_Mapping :: struct {
    layers:[4]string,         // the paint layer each layer of the terrain shows, in its order; "" none
    coordinates:[2][4]f32,    // the landscape coordinates (quads of Unreal from its actor) at a point p of the world in Unreal's centimetres: dot(row.xyz,p)+row.w
}

@(private)
layer_seen :: proc(e:^Evaluator,name:string) {
    if name=="" || name=="None" {return}
    for known in e.layers {if strings.equal_fold(known,name) {return}}
    append(&e.layers,strings.clone(name,e.layers.allocator))
}

// The weight of a layer in the branch being evaluated. Without a branch
// (layer ""), the first layer the graph names is the one shown.
@(private)
layer_weight :: proc(e:^Evaluator,name:string) -> f32 {
    if e.layer=="" {
        if len(e.layers)==0 {return 1}
        return strings.equal_fold(e.layers[0],name)?1:0
    }
    return strings.equal_fold(e.layer,name)?1:0
}

// The weight of a layer at the point: a constant in a branch; in a whole
// landscape, that of its layer of the terrain. found is false for a layer
// the point does not have, which Unreal leaves out as one a component does
// not paint.
@(private)
layer_weight_node :: proc(e:^Evaluator,name:string) -> (weight:u32,found:bool) {
    g:=e.g
    if e.landscape==nil {
        w:=layer_weight(e,name)
        return scalar(g,w),w>0
    }
    for layer,slot in e.landscape.layers {
        if layer!="" && strings.equal_fold(layer,name) {return component(g,context_value(g,.Layer_Weights,4),u8(slot)),true}
    }
    return scalar(g,0),false
}

// The coordinates of a set of uvs: where the coordinates are a landscape's,
// those of the landscape (quads of Unreal from its actor) at the place of
// the point in the world, whatever the set.
@(private)
uv_value :: proc(e:^Evaluator,set:u32) -> u32 {
    g:=e.g
    if e.coordinates==nil {return context_value(g,.UV,2,set)}
    p:=world_place(e,.World_Position)
    along :: proc(g:^Graph,p:u32,row:[4]f32) -> u32 {return binary(g,.Add,binary(g,.Dot,p,constant(g,{row.x,row.y,row.z,0},3)),scalar(g,row.w))}
    return append_values(g,along(g,p,e.coordinates[0]),along(g,p,e.coordinates[1]))
}

// The value a blend of layers gives, as Unreal's LandscapeLayerBlend: the
// weighted layers (height-blended ones with their weight moved by their
// height) added by their weights over their sum where it passes 1, then each
// alpha-blended layer over them. A branch takes the input of its layer.
@(private)
landscape_blend :: proc(e:^Evaluator,o:Object,scope:i32) -> Value {
    g:=e.g
    p:=&o.pkg.p
    layers:=prop_structs(o,"Layers")
    for &layer in layers {layer_seen(e,list_name(p,&layer,"LayerName"))}
    layer_input :: proc(e:^Evaluator,o:Object,p:^unreal.Package,layer:^unreal.Property_List,scope:i32) -> Value {
        if found:=unreal.property_find(p,layer,"LayerInput");found!=nil {
            if input,ok:=input_read(p,found);ok && input.expression!=0 {return input_value(e,o,input,scope)}
        }
        return nodes(constant(e.g,list_vector(p,layer,"ConstLayerInput",{}),3))
    }
    if e.landscape==nil {
        for &layer in layers {
            if layer_weight(e,list_name(p,&layer,"LayerName"))==0 {continue}
            return layer_input(e,o,p,&layer,scope)
        }
        // The branch's layer is not in this blend: every weight is 0.
        return nodes(constant(g,{},3))
    }
    weights:=make([]u32,len(layers),context.temp_allocator)
    painted:=make([]u32,len(layers),context.temp_allocator)
    alpha:=make([]bool,len(layers),context.temp_allocator)
    sum:=scalar(g,0)
    for &layer,i in layers {
        w,found:=layer_weight_node(e,list_name(p,&layer,"LayerName"))
        weights[i]=NONE
        if !found {continue}
        painted[i]=w
        switch list_name(p,&layer,"BlendType") {
        case "LB_AlphaBlend":
            weights[i],alpha[i]=w,true
            continue
        case "LB_HeightBlend":
            height:=NONE
            if found_height:=unreal.property_find(p,&layer,"HeightInput");found_height!=nil {
                if input,ok:=input_read(p,found_height);ok && input.expression!=0 {height=convert(g,input_value(e,o,input,scope).node,1)}
            }
            if height==NONE {height=scalar(g,list_float(p,&layer,"ConstHeightInput",0))}
            // Unpainted, a layer weighs the least whatever its height (up to 1).
            height=gate(g,w,height,scalar(g,0))
            w=ternary(g,.Clamp,binary(g,.Add,ternary(g,.Lerp,scalar(g,-1),scalar(g,1),w),height),scalar(g,0.0001),scalar(g,1))
        }
        weights[i]=w
        sum=binary(g,.Add,sum,w)
    }
    share:=binary(g,.Div,scalar(g,1),binary(g,.Max,sum,scalar(g,1)))
    out:=NO_VALUE
    for &layer,i in layers {
        if weights[i]==NONE || alpha[i] {continue}
        out=value_blend(e,out,value_gate(e,layer_input(e,o,p,&layer,scope),painted[i]),binary(g,.Mul,weights[i],share),false)
    }
    for &layer,i in layers {
        if weights[i]==NONE || !alpha[i] {continue}
        out=value_blend(e,out,value_gate(e,layer_input(e,o,p,&layer,scope),painted[i]),weights[i],true)
    }
    if out.node==NONE && out.aggregate<0 {return nodes(constant(g,{},3))}
    return out
}

// A layer computed only where it is painted: elsewhere a value is zero and
// material attributes are their defaults, which its weight adds nothing to.
@(private)
value_gate :: proc(e:^Evaluator,value:Value,weight:u32) -> Value {
    g:=e.g
    if value.aggregate>=0 {
        row:=e.aggregates[value.aggregate]
        for &n,attribute in row {
            if n!=NONE {n=gate(g,weight,n,constant(g,ATTRIBUTE_DEFAULTS[attribute],ATTRIBUTE_WIDTHS[attribute]))}
        }
        append(&e.aggregates,row)
        return {NONE,i32(len(e.aggregates)-1)}
    }
    if value.node==NONE {return value}
    return nodes(gate(g,weight,value.node,scalar(g,0)))
}

// out with value added by weight or, over, laid over it by weight. Values
// start from zero; material attributes add what each differs from its
// default, as Unreal blends them.
@(private)
value_blend :: proc(e:^Evaluator,out,value:Value,weight:u32,over:bool) -> Value {
    g:=e.g
    if value.aggregate>=0 {
        if out.node!=NONE {return out}
        row:[Attribute]u32
        for attribute in Attribute {
            default:=constant(g,ATTRIBUTE_DEFAULTS[attribute],ATTRIBUTE_WIDTHS[attribute])
            from:=out.aggregate>=0?e.aggregates[out.aggregate][attribute]:default
            to:=e.aggregates[value.aggregate][attribute]
            if to==NONE {to=default}
            if from==NONE {from=default}
            row[attribute]=over?ternary(g,.Lerp,from,to,weight):binary(g,.Add,from,binary(g,.Mul,binary(g,.Sub,to,default),weight))
        }
        append(&e.aggregates,row)
        return {NONE,i32(len(e.aggregates)-1)}
    }
    if value.node==NONE || out.aggregate>=0 {return out}
    if out.node==NONE {return nodes(binary(g,.Mul,value.node,weight))}
    width:=common_width(width_of(g,out.node),width_of(g,value.node))
    a,b:=convert(g,out.node,width),convert(g,value.node,width)
    if over {return nodes(ternary(g,.Lerp,a,b,weight))}
    return nodes(binary(g,.Add,a,binary(g,.Mul,b,weight)))
}

@(private)
landscape_weight :: proc(e:^Evaluator,o:Object,scope:i32) -> Value {
    g:=e.g
    name:=prop_name(o,"ParameterName","")
    layer_seen(e,name)
    base:=pin_value(e,o,"Base",scope)
    if base.node==NONE && base.aggregate<0 {base=nodes(constant(g,prop_vector(o,"ConstBase",{}),3))}
    weight,found:=layer_weight_node(e,name)
    if !found {return base}
    layer:=value_gate(e,pin_value(e,o,"Layer",scope),weight)
    if base.aggregate>=0 || layer.aggregate>=0 {
        if base.aggregate<0 || layer.aggregate<0 {return untranslated(e,o,"it adds material attributes to a value")}
        row:[Attribute]u32
        for attribute in Attribute {row[attribute]=binary(g,.Add,e.aggregates[base.aggregate][attribute],binary(g,.Mul,e.aggregates[layer.aggregate][attribute],weight))}
        append(&e.aggregates,row)
        return {NONE,i32(len(e.aggregates)-1)}
    }
    width:=common_width(width_of(g,base.node),width_of(g,layer.node))
    return nodes(binary(g,.Add,convert(g,base.node,width),binary(g,.Mul,convert(g,layer.node,width),weight)))
}

// The coordinates of a layer: the landscape's own (one unit per quad),
// turned, scaled and moved as the expression says.
@(private)
landscape_coords :: proc(e:^Evaluator,o:Object) -> u32 {
    g:=e.g
    mapping_type:=prop_name(o,"MappingType","TCMT_Auto")
    if prop_name(o,"CustomUVType","LCCT_None")!="LCCT_None" || mapping_type!="TCMT_Auto" && mapping_type!="TCMT_XY" {
        untranslated(e,o,"a mapping other than the landscape's XY")
        return NONE
    }
    mapping:=prop_float(o,"MappingScale",0)
    scale:f32=mapping==0?1:1/mapping
    angle:=prop_float(o,"MappingRotation",0)*math.PI/180
    uv:=uv_value(e,0)
    turned:u32
    if angle==0 {
        turned=binary(g,.Mul,uv,constant(g,{scale,scale,0,0},2))
    } else {
        x,y:=math.cos(angle)*scale,math.sin(angle)*scale
        turned=append_values(g,binary(g,.Dot,uv,constant(g,{x,y,0,0},2)),binary(g,.Dot,uv,constant(g,{-y,x,0,0},2)))
    }
    return binary(g,.Add,turned,constant(g,{prop_float(o,"MappingPanU",0),prop_float(o,"MappingPanV",0),0,0},2))
}

// One layer of a landscape material: its name and the material of its branch.
Landscape_Layer :: struct {
    name:string,
    material:Translated_Material,
}

// The layers of a landscape material, each translated as its own material,
// in the order the graph names them. None for a material without layer
// expressions (LandscapeLayerBlend, LandscapeLayerWeight, LandscapeLayerSample
// or LandscapeLayerSwitch).
landscape_layers :: proc(lib:^Library,material:Object,options:Options={},allocator:=context.allocator) -> (layers:[]Landscape_Layer,error:Error) {
    whole:Translated_Material
    whole,error=translate(lib,material,options,allocator)
    if error.code!=.None {return}
    names:=whole.layers
    if len(names)==0 {
        translated_destroy(&whole)
        return
    }
    out:=make([dynamic]Landscape_Layer,allocator)
    for name in names {
        branch:=options
        branch.layer=name
        translated:Translated_Material
        translated,error=translate(lib,material,branch,allocator)
        if error.code!=.None {
            landscape_layers_destroy(out[:],allocator)
            translated_destroy(&whole)
            return nil,error
        }
        translated.name=strings.concatenate({whole.name,"_",name},translated.allocator)
        append(&out,Landscape_Layer{strings.clone(name,allocator),translated})
    }
    translated_destroy(&whole)
    return out[:],{}
}

landscape_layers_destroy :: proc(layers:[]Landscape_Layer,allocator:=context.allocator) {
    for &layer in layers {
        delete(layer.name,allocator)
        translated_destroy(&layer.material)
    }
    delete(layers,allocator)
}
