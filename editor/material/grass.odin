package material

import "core:math"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// Landscape grass. The grass output of a landscape material
// (LandscapeGrassOutput) names a grass type (LandscapeGrassType) for each of
// its inputs: where the landscape is drawn, the varieties of that type grow
// as densely as the input weighs there. Read here: the paint layers each
// input reads, as the material evaluates it, and the varieties of its type.

Grass_Scaling :: enum u8 {Uniform,Free,Lock_XY}

Grass_Variety :: struct {
    mesh:string,          // object path of its StaticMesh, "" without one
    materials:[]string,   // object paths of the materials it puts in the slots of its mesh, by slot; "" keeps the mesh's
    density:f32,          // instances per square metre where the input weighs 1
    scaling:Grass_Scaling,
    scale:[3][2]f32,      // along Unreal's X, Y and Z: lowest and highest
    weights:[2]f32,       // of the input where it grows: above the lowest, up to the highest
    random_rotation:bool, // about up
    align:bool,           // to the normal of the landscape
    cull:[2]f32,          // metres from the eye where it starts to fade and where it is gone
    casts_shadow:bool,
}

Landscape_Grass :: struct {
    name:string,               // of the input
    type:string,               // object path of its grass type
    layers:[]string,           // the paint layers the input reads
    fit:Grass_Fit,
    varieties:[]Grass_Variety, // none when its grass type could not be read
}

// What a foliage rule takes of an input: the slopes of the ground it grows
// on and the weight its layers need there, past which it is as dense as they
// weigh; the pair closest to the density the input gives, at every weight of
// its layers and every slope, a texture it reads taken at each of its values
// alike.
Grass_Fit :: struct {
    slope:[2]f32, // radians from horizontal: lowest and highest
    weight:f32,   // of its layers, at least
    error:f32,    // the mean difference of the two densities, as a share of the input's mean density
    ok:bool,      // false: the input reads what a rule does not see (time, the camera, noise), or never grows
}

// The grass of a landscape material (a Material or an instance of one), in
// the order of the inputs of its grass outputs; an input that names no grass
// type is left out. Everything in allocator.
landscape_grass :: proc(lib:^Library,material:Object,allocator:=context.allocator) -> (grass:[]Landscape_Grass,error:Error) {
    if !object_valid(material) {return nil,error_make(.Not_Found,"the material does not exist")}
    chain:Chain
    chain,error=chain_read(lib,material,context.temp_allocator)
    if error.code!=.None {return}
    base:=chain.material
    g:Graph
    graph_init(&g,context.temp_allocator)
    e:Evaluator
    evaluator_init(&e,lib,&g,context.temp_allocator)
    e.overrides,e.stack=chain.overrides,chain.stack
    e.material=object_path(material)
    e.ue5=base.pkg.p.summary.version_ue5>0
    out:=make([dynamic]Landscape_Grass,allocator)
    p:=&base.pkg.p
    for &item,index in p.exports {
        o:=Object{base.pkg,index}
        if item.outer!=unreal.Object_Ref(base.export+1) && !is_editor_data_of(base,item.outer) {continue}
        if object_class(o)!="MaterialExpressionLandscapeGrassOutput" {continue}
        for &entry in prop_structs(o,"GrassTypes") {
            type_ref:=list_object(p,&entry,"GrassType")
            found:=unreal.property_find(p,&entry,"Input")
            if type_ref==0 || found==nil {continue}
            input,ok:=input_read(p,found)
            if !ok {continue}
            // The layers the input names, as it is evaluated and along its
            // pins (past a function that cannot be read), then its value with
            // those layers as the weights of a terrain: whether it is one of
            // them alone.
            clear(&e.layers)
            clear(&e.memo)
            e.landscape,e.coordinates=nil,nil
            input_value(&e,o,input,-1)
            visited:=make(map[Object]struct{},context.temp_allocator)
            layers_named(&e,o,input,&visited)
            layers:=make([]string,len(e.layers),allocator)
            for name,i in e.layers {layers[i]=strings.clone(name,allocator)}
            mapping:=Landscape_Mapping{layers=layers}
            e.landscape,e.coordinates=&mapping,&mapping.coordinates
            clear(&e.memo)
            value:=input_value(&e,o,input,-1)
            path,_:=unreal.reference_path(p,type_ref,allocator)
            read:=Landscape_Grass{name=strings.clone(list_name(p,&entry,"Name"),allocator),type=path,layers=layers}
            read.fit=grass_fit(&g,value.node)
            if grass_type,resolved:=object_resolve(lib,o.pkg,type_ref);resolved && object_valid(grass_type) {
                read.varieties=varieties_read(grass_type,allocator)
            }
            append(&out,read)
        }
    }
    return out[:],{}
}

landscape_grass_destroy :: proc(grass:[]Landscape_Grass,allocator:=context.allocator) {
    for g in grass {
        delete(g.name,allocator);delete(g.type,allocator)
        for layer in g.layers {delete(layer,allocator)}
        delete(g.layers,allocator)
        for v in g.varieties {
            delete(v.mesh,allocator)
            for m in v.materials {delete(m,allocator)}
            delete(v.materials,allocator)
        }
        delete(g.varieties,allocator)
    }
    delete(grass,allocator)
}

@(private) FIT_WEIGHTS :: 20 // of the layers, at the middle of 20 equal steps
@(private) FIT_DEGREES :: 90 // slopes, a degree apart
@(private) FIT_TEXELS :: 8  // values a texture read takes

// The rule closest to the density the input root gives (Grass_Fit), with
// its layers all at each weight, the normal at each slope, and every texture
// at each value.
@(private)
grass_fit :: proc(g:^Graph,root:u32) -> (fit:Grass_Fit) {
    if root==NONE {return}
    order:=nodes_under(g,{root})
    SEEN :: bit_set[Op]{.Layer_Weight,.Pixel_Normal,.Vertex_Normal,.World_Position,.Origin,.UV,.Sample,.Texture}
    for n in order {if op:=g.nodes[n].op;op in VARYING && op not_in SEEN {return}}
    values:=make([][4]f32,len(g.nodes),context.temp_allocator)
    density:=make([]f32,(FIT_DEGREES+1)*FIT_WEIGHTS,context.temp_allocator)
    texel:Texel_Context
    total:f32
    for degree in 0..=FIT_DEGREES {
        angle:=f32(degree)*math.PI/180
        // Unreal's normal, Z up.
        normal:=[4]f32{math.sin(angle),0,math.cos(angle),0}
        for k in 0..<FIT_WEIGHTS {
            weight:=(f32(k)+0.5)/FIT_WEIGHTS
            sum:f32
            for j in 0..<FIT_TEXELS {
                read:=(f32(j)+0.5)/FIT_TEXELS
                for n in order {
                    node:=&g.nodes[n]
                    #partial switch node.op {
                    case .Layer_Weight:values[n]={weight,0,0,0}
                    case .Pixel_Normal,.Vertex_Normal:values[n]=normal
                    case .World_Position,.Origin,.UV,.Texture:values[n]={}
                    case .Sample:values[n]={read,read,read,read}
                    case:
                        args:[3][4]f32
                        for arg,i in node.args {if arg!=NONE {args[i]=values[arg]}}
                        values[n]=node_compute(g,node,args,&texel)
                    }
                }
                sum+=clamp(values[root].x,0,1)
            }
            density[degree*FIT_WEIGHTS+k]=sum/FIT_TEXELS
            total+=sum/FIT_TEXELS
        }
    }
    if !(total>0) {return}
    // For each least weight, the slopes where the rule is closer than no
    // grass: the run of most gain.
    gains:[FIT_DEGREES+1]f32
    best:=max(f32)
    for step in 0..=FIT_WEIGHTS {
        least:=f32(step)/FIT_WEIGHTS
        for &gain,degree in gains {
            gain=0
            for k in 0..<FIT_WEIGHTS {
                weight:=(f32(k)+0.5)/FIT_WEIGHTS
                d:=density[degree*FIT_WEIGHTS+k]
                gain+=d-abs(d-(weight>=least?weight:0))
            }
        }
        run,start:=f32(0),0
        most,low,high:=-max(f32),0,0
        for gain,degree in gains {
            if run<=0 {run,start=0,degree}
            run+=gain
            if run>most {most,low,high=run,start,degree}
        }
        if total-most<best-1e-6 {
            best=total-most
            fit.weight=least
            fit.slope={low==0?0:(f32(low)-0.5)*math.PI/180,high==FIT_DEGREES?math.PI/2:(f32(high)+0.5)*math.PI/180}
        }
    }
    fit.error=max(best,0)/total
    fit.ok=true
    return
}

// The landscape layers the expressions an input reads name, along the pins
// of the expressions and the inputs of the function calls among them, into
// e.layers.
@(private)
layers_named :: proc(e:^Evaluator,o:Object,input:Input,visited:^map[Object]struct{}) {
    if input.expression==0 {return}
    target,found:=object_resolve(e.lib,o.pkg,input.expression)
    if !found || !object_valid(target) || target in visited {return}
    visited[target]={}
    p,list:=props(target)
    if list==nil {return}
    switch object_class(target) {
    case "MaterialExpressionLandscapeLayerSample","MaterialExpressionLandscapeLayerWeight","MaterialExpressionLandscapeLayerSwitch":
        layer_seen(e,list_name(p,list,"ParameterName"))
    case "MaterialExpressionLandscapeLayerBlend":
        for &layer in prop_structs(target,"Layers") {layer_seen(e,list_name(p,&layer,"LayerName"))}
    case "MaterialExpressionMaterialFunctionCall":
        for &call_input in prop_structs(target,"FunctionInputs") {
            if pin:=unreal.property_find(p,&call_input,"Input");pin!=nil {
                if inner,ok:=input_read(p,pin);ok {layers_named(e,target,inner,visited)}
            }
        }
    }
    for &item in list.items {
        if inner,ok:=input_read(p,&item);ok {layers_named(e,target,inner,visited)}
    }
}

// The GrassVarieties of a LandscapeGrassType, with the defaults of a variety
// for what it does not save.
@(private)
varieties_read :: proc(o:Object,allocator:=context.allocator) -> []Grass_Variety {
    p:=&o.pkg.p
    items:=prop_structs(o,"GrassVarieties")
    out:=make([]Grass_Variety,len(items),allocator)
    for &item,i in items {
        v:=&out[i]
        if mesh:=list_object(p,&item,"GrassMesh");mesh!=0 {v.mesh,_=unreal.reference_path(p,mesh,allocator)}
        if found:=unreal.property_find(p,&item,"OverrideMaterials");found!=nil {
            if view,view_error:=unreal.property_array(p,found);view_error.code==.None {
                if refs,refs_error:=unreal.array_object_refs(p,view,context.temp_allocator);refs_error.code==.None {
                    v.materials=make([]string,len(refs),allocator)
                    for r,k in refs {if r!=0 {v.materials[k],_=unreal.reference_path(p,r,allocator)}}
                }
            }
        }
        // Unreal counts instances on 10 by 10 metres, and distances in centimetres.
        v.density=per_platform(p,&item,"GrassDensity",400,false)/100
        v.cull={per_platform(p,&item,"StartCullDistance",10000,true)/100,per_platform(p,&item,"EndCullDistance",10000,true)/100}
        switch list_name(p,&item,"Scaling") {
        case "Free":v.scaling=.Free
        case "LockXY":v.scaling=.Lock_XY
        }
        for axis,k in ([3]string{"ScaleX","ScaleY","ScaleZ"}) {v.scale[k]=interval(p,&item,axis,{1,1})}
        v.weights=interval(p,&item,"AllowedDensityRange",{0,1})
        v.random_rotation=list_bool(p,&item,"RandomRotation",true)
        v.align=list_bool(p,&item,"AlignToSurface",true)
        v.casts_shadow=list_bool(p,&item,"bCastDynamicShadow",true)
    }
    return out
}

// The Default of a PerPlatformFloat or PerPlatformInt, saved after the
// 32-bit bool that says whether it was cooked.
@(private)
per_platform :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:f32,integer:bool) -> f32 {
    found:=unreal.property_find(p,list,name)
    if found==nil {return default}
    bytes,error:=unreal.span_bytes(p,found.data)
    if error.code!=.None || len(bytes)<8 {return default}
    bits:=u32(bytes[4])|u32(bytes[5])<<8|u32(bytes[6])<<16|u32(bytes[7])<<24
    value:=integer?f32(transmute(i32)bits):transmute(f32)bits
    return value-value==0?value:default
}

// The Min and Max of a FloatInterval.
@(private)
interval :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:[2]f32) -> [2]f32 {
    found:=unreal.property_find(p,list,name)
    if found==nil {return default}
    inner,error:=unreal.property_tagged_struct(p,found,true,context.temp_allocator)
    if error.code!=.None {return default}
    return {list_float(p,&inner,"Min",default[0]),list_float(p,&inner,"Max",default[1])}
}
