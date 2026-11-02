package material

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// Evaluating the expressions of an Unreal material into the Graph, as its
// translator (MaterialExpressionsToMIR) builds them: each expression class is
// one case, material functions are expanded where they are called, static
// switches and the static parameters of the instances are resolved, and what
// cannot be translated leaves NONE and is counted by its class.

// The outputs of a material (EMaterialProperty) that a translation reads.
Attribute :: enum u8 {
    Base_Color,Metallic,Specular,Roughness,Anisotropy,Emissive,Opacity,Opacity_Mask,Normal,Tangent,
    World_Position_Offset,Subsurface_Color,Clear_Coat,Clear_Coat_Roughness,Ambient_Occlusion,Refraction,
    Pixel_Depth_Offset,Displacement,
}

@(rodata)
ATTRIBUTE_NAMES := [Attribute]string{
    .Base_Color="BaseColor",.Metallic="Metallic",.Specular="Specular",.Roughness="Roughness",.Anisotropy="Anisotropy",
    .Emissive="EmissiveColor",.Opacity="Opacity",.Opacity_Mask="OpacityMask",.Normal="Normal",.Tangent="Tangent",
    .World_Position_Offset="WorldPositionOffset",.Subsurface_Color="SubsurfaceColor",.Clear_Coat="ClearCoat",
    .Clear_Coat_Roughness="ClearCoatRoughness",.Ambient_Occlusion="AmbientOcclusion",.Refraction="Refraction",
    .Pixel_Depth_Offset="PixelDepthOffset",.Displacement="Displacement",
}

// What each output is when nothing is connected (FMaterialAttributeDefinitionMap).
@(rodata)
ATTRIBUTE_DEFAULTS := [Attribute][4]f32{
    .Base_Color={0,0,0,0},.Metallic={},.Specular={0.5,0,0,0},.Roughness={0.5,0,0,0},.Anisotropy={},.Emissive={},
    .Opacity={1,0,0,0},.Opacity_Mask={1,0,0,0},.Normal={0,0,1,0},.Tangent={1,0,0,0},.World_Position_Offset={},
    .Subsurface_Color={1,1,1,0},.Clear_Coat={1,0,0,0},.Clear_Coat_Roughness={0.1,0,0,0},.Ambient_Occlusion={1,0,0,0},
    .Refraction={1,0,0,0},.Pixel_Depth_Offset={},.Displacement={0.5,0,0,0},
}

@(rodata)
ATTRIBUTE_WIDTHS := [Attribute]u8{
    .Base_Color=3,.Metallic=1,.Specular=1,.Roughness=1,.Anisotropy=1,.Emissive=3,.Opacity=1,.Opacity_Mask=1,.Normal=3,
    .Tangent=3,.World_Position_Offset=3,.Subsurface_Color=3,.Clear_Coat=1,.Clear_Coat_Roughness=1,.Ambient_Occlusion=1,
    .Refraction=1,.Pixel_Depth_Offset=1,.Displacement=1,
}

// The ids Unreal gives the outputs, as Get and Set Material Attributes name them.
@(private)
@(rodata)
ATTRIBUTE_GUIDS := [Attribute][4]u32{
    .Base_Color={0x69b8d336,0x16ed4d49,0x9aa49729,0x2f050f7a},.Metallic={0x57c3a161,0x7f064296,0xb00b24a5,0xa496f34c},
    .Specular={0x9fdab399,0x25564cc9,0x8cd2d572,0xc12c8fed},.Roughness={0xd1dd967c,0x4cad47d3,0x9e6346fb,0x08ecf210},
    .Anisotropy={0x55e2b4fb,0xc1c54db2,0x9f11875f,0x7231eb1e},.Emissive={0xb769b54d,0xd08d4440,0xabc21ba6,0xcd27d0e2},
    .Opacity={0xb8f50fba,0x2a754ec1,0x9ef672cf,0xeb27bf51},.Opacity_Mask={0x679ffb17,0x2bb5422c,0xad520483,0x166e0c75},
    .Normal={0x0fa2821a,0x200f4a4a,0xb719b789,0xc1259c64},.Tangent={0xd5f8e9cf,0xcdc3468d,0xb10e4465,0x596a7bba},
    .World_Position_Offset={0xf905f895,0xd5814314,0x916d2434,0x8c40ce9e},.Subsurface_Color={0x5b8fc679,0x51ce4082,0x9d777bee,0xf4f72c44},
    .Clear_Coat={0x9e502e69,0x3c8f48fa,0x94645cfd,0x28e5428d},.Clear_Coat_Roughness={0xbe4f2ffd,0x12fc4296,0xb0124eea,0x12c28d92},
    .Ambient_Occlusion={0xe8ebd0ad,0xb1654cbe,0xb079c3a8,0xb39b9f15},.Refraction={0xd0b0fa03,0x14d74455,0xa851bac5,0x81a0788b},
    .Pixel_Depth_Offset={0x0ac97ec3,0xe3d047ba,0xb610167d,0xc4d919ff},.Displacement={0x199a7166,0xc67041dc,0xa68ead0d,0x7017d0ad},
}

// A value an expression gives: a node, or the outputs of a material
// (material attributes), as a row of Evaluator.aggregates.
Value :: struct {node:u32,aggregate:i32}

NO_VALUE :: Value{NONE,-1}

Override_Kind :: enum u8 {Scalar,Vector,Texture,Switch,Mask}

// A parameter value that an instance of the chain sets, or a function
// instance that is a layer of the stack.
Override :: struct {
    name:string,
    kind:Override_Kind,
    value:[4]f32,
    texture:string, // object path
    layer:Layer_Ref,
}

// A function call being expanded: whose inputs its FunctionInput
// expressions read. A layer or blend of a stack of material layers has no
// call: its inputs of material attributes take bound, in their order.
@(private)
Scope :: struct {
    call:Object,     // the MaterialFunctionCall; none for a layer or blend
    parent:i32,      // the scope the call was evaluated in; -1 the material
    layer:Layer_Ref, // whose parameters those inside are
    function:Object, // of a layer or blend
    bound:[2]Value,
}

// A stack of material layers (FMaterialLayersFunctions): the functions of
// its layers and of the blends between them, of the package pkg, and which
// layers are on.
Layer_Stack :: struct {
    pkg:^Opened,
    layers,blends:[]unreal.Object_Ref,
    states:[]bool,
}

@(private)
Memo_Key :: struct {pkg:^Opened,export:i32,output:i32,scope:i32}

Evaluator :: struct {
    lib:^Library,
    g:^Graph,
    overrides:[dynamic]Override, // the closest instance first, then the function instances of the layers
    stack:Layer_Stack,           // that the closest instance sets; none: that of the material
    layer:string,         // the landscape layer whose branch is evaluated; "" none
    landscape:^Landscape_Mapping, // a whole landscape: the weights of its layers are those of a terrain
    layers:[dynamic]string, // the landscape layers the graph names
    scopes:[dynamic]Scope,
    aggregates:[dynamic][Attribute]u32,
    memo:map[Memo_Key]Value,
    visiting:map[Memo_Key]bool,
    untranslated:map[string]int, // by expression class: those that could not be translated
    counted:map[Object]struct{}, // the expressions untranslated has counted
    notes:[dynamic]string,       // why, and what was approximated
    missing:[dynamic]string,     // the object paths of what it reads that could not be read
    depth:int,
    ue5:bool,
    fuzz:[2]u32, // the color and weight of fibers over the surface a legacy function asks for; NONE: none
    exposure_relative:bool, // the graph undoes the exposure (EyeAdaptationInverse)
    diffuse_transmission:[2]u32, // the color and weight of the light a thin surface lets through; NONE: none
    custom_data:[]f32,      // of the instance: what PerInstanceCustomData reads
    reads_custom_data:bool, // PerInstanceCustomData was evaluated
    reads:[]Texture_Read,   // of the options
}

@(private) MAX_EVALUATION_DEPTH :: 400

// Mirai meshes keep the first two uv sets of Unreal; the sets after them
// hold per-vertex data of vertex animation, which moves the surface.
@(private)
UV_SETS_PAST :: "a uv set past the two Mirai meshes keep: those after them carry vertex animation data, which goes with WorldPositionOffset"

evaluator_init :: proc(e:^Evaluator,lib:^Library,g:^Graph,allocator:=context.allocator) {
    e.lib,e.g=lib,g
    e.fuzz={NONE,NONE}
    e.diffuse_transmission={NONE,NONE}
    e.scopes.allocator=allocator
    e.aggregates.allocator=allocator
    e.memo.allocator=allocator
    e.visiting.allocator=allocator
    e.untranslated.allocator=allocator
    e.counted.allocator=allocator
    e.notes.allocator=allocator
    e.missing.allocator=allocator
    e.layers.allocator=allocator
}

@(private)
note :: proc(e:^Evaluator,format:string,args:..any) {
    text:=fmt.aprintf(format,..args,allocator=e.notes.allocator)
    for existing in e.notes {if existing==text {return}}
    append(&e.notes,text)
}

// Counts an expression that could not be translated, once per object.
@(private)
untranslated :: proc(e:^Evaluator,o:Object,why:string) -> Value {
    if o in e.counted {return NO_VALUE}
    e.counted[o]={}
    class:=object_class(o)
    if class in e.untranslated {
        e.untranslated[class]+=1
    } else {
        e.untranslated[strings.clone(class,e.untranslated.allocator)]=1
    }
    note(e,"%s %s: %s",class,object_name(o),why)
    return NO_VALUE
}

// An expression whose object of another package could not be read, which
// it names.
@(private)
unread :: proc(e:^Evaluator,o:Object,reference:unreal.Object_Ref,what:string) -> Value {
    path,_:=unreal.reference_path(&o.pkg.p,reference,e.missing.allocator)
    if path!="" {append(&e.missing,path)}
    return untranslated(e,o,fmt.tprintf("its %s %s could not be read",what,path))
}

// The untranslated expression classes and their counts.
untranslated_counts :: proc(e:^Evaluator,out:^[dynamic]Untranslated) {
    for name,count in e.untranslated {append(out,Untranslated{strings.clone(name,out.allocator),count})}
}

Untranslated :: struct {class:string,count:int}

@(private)
override_find :: proc(e:^Evaluator,name:string,kind:Override_Kind,scope:i32) -> ^Override {
    layer:=scope_layer(e,scope)
    for &o in e.overrides {if o.kind==kind && o.layer==layer && strings.equal_fold(o.name,name) {return &o}}
    return nil
}

// The layer whose parameters those of a scope are.
@(private)
scope_layer :: proc(e:^Evaluator,scope:i32) -> Layer_Ref {return scope>=0?e.scopes[scope].layer:{}}

// The name of a parameter in the graph: in a layer or blend, with it.
@(private)
parameter_name :: proc(e:^Evaluator,name:string,scope:i32) -> string {
    layer:=scope_layer(e,scope)
    if layer.association==.Global {return name}
    return fmt.aprintf("%s%d.%s",layer.association==.Layer?"Layer":"Blend",layer.index,name,allocator=e.g.parameters.allocator)
}

// The value an input of o computes; NO_VALUE when it is not connected.
input_value :: proc(e:^Evaluator,o:Object,input:Input,scope:i32) -> Value {
    if input.expression==0 {return NO_VALUE}
    target,found:=object_resolve(e.lib,o.pkg,input.expression)
    if !found {return NO_VALUE}
    value:=expression(e,target,input.output,scope)
    if input.masked && value.node!=NONE {
        components:[4]u8
        count:u8
        width:=width_of(e.g,value.node)
        for keep,c in input.channels {
            if !keep {continue}
            components[count]=width==1?0:u8(c)
            count+=1
        }
        if count>0 && !(width==1 && count==1) {value.node=swizzle(e.g,value.node,components,count)}
    }
    return value
}

// The node a pin of o computes: (NONE,false) when nothing is connected.
@(private)
pin :: proc(e:^Evaluator,o:Object,name:string,scope:i32) -> (node:u32,connected:bool) {
    input,ok:=prop_input(o,name)
    if !ok || input.expression==0 {return NONE,false}
    return input_value(e,o,input,scope).node,true
}

// A pin, or a scalar constant property of o while nothing is connected.
@(private)
pin_or :: proc(e:^Evaluator,o:Object,name,constant_name:string,default:f32,scope:i32) -> u32 {
    node,connected:=pin(e,o,name,scope)
    if connected {return node}
    return scalar(e.g,constant_name==""?default:prop_float(o,constant_name,default))
}

// The value of an output of an expression in a scope.
expression :: proc(e:^Evaluator,o:Object,output:i32,scope:i32) -> Value {
    if !object_valid(o) {return NO_VALUE}
    key:=Memo_Key{o.pkg,i32(o.export),output,scope}
    if value,found:=e.memo[key];found {return value}
    if e.visiting[key] || e.depth>=MAX_EVALUATION_DEPTH {
        note(e,"%s: the graph loops or is deeper than %d expressions",object_name(o),MAX_EVALUATION_DEPTH)
        return NO_VALUE
    }
    e.visiting[key]=true
    e.depth+=1
    value:=expression_build(e,o,output,scope)
    e.depth-=1
    e.visiting[key]=false
    e.memo[key]=value
    return value
}

@(private)
nodes :: proc(n:u32) -> Value {return {n,-1}}

@(private)
expression_build :: proc(e:^Evaluator,o:Object,output:i32,scope:i32) -> Value {
    g:=e.g
    class:=object_class(o)
    if !strings.has_prefix(class,"MaterialExpression") {return untranslated(e,o,"not a material expression")}
    kind:=class[len("MaterialExpression"):]
    switch kind {
    case "Constant":return nodes(scalar(g,prop_float(o,"R",0)))
    case "Constant2Vector":return nodes(constant(g,{prop_float(o,"R",0),prop_float(o,"G",0),0,0},2))
    case "Constant3Vector":return nodes(constant(g,prop_vector(o,"Constant",{}),3))
    case "Constant4Vector":return nodes(constant(g,prop_vector(o,"Constant",{}),4))
    case "ConstantBiasScale":
        input,_:=pin(e,o,"Input",scope)
        return nodes(binary(g,.Mul,binary(g,.Add,scalar(g,prop_float(o,"Bias",1)),input),scalar(g,prop_float(o,"Scale",0.5))))
    case "StaticBool":return nodes(scalar(g,prop_bool(o,"Value",false)?1:0))
    case "ScalarParameter":
        name:=prop_name(o,"ParameterName","")
        default:=prop_float(o,"DefaultValue",0)
        value:=default
        if found:=override_find(e,name,.Scalar,scope);found!=nil {value=found.value.x}
        return nodes(parameter(g,parameter_name(e,name,scope),1,{value,0,0,0},{default,0,0,0}))
    case "VectorParameter","DoubleVectorParameter":
        name:=prop_name(o,"ParameterName","")
        default:=prop_vector(o,"DefaultValue",{})
        value:=default
        if found:=override_find(e,name,.Vector,scope);found!=nil {value=found.value}
        return nodes(parameter(g,parameter_name(e,name,scope),4,value,default))
    case "StaticBoolParameter":
        return nodes(scalar(g,static_switch(e,o,scope)?1:0))
    case "StaticSwitchParameter":
        return pin_value(e,o,static_switch(e,o,scope)?"A":"B",scope)
    case "StaticSwitch":
        condition,connected:=pin(e,o,"Value",scope)
        on:=prop_bool(o,"DefaultValue",false)
        if connected {
            value,ok:=evaluate_constant(g,condition)
            if !ok {return untranslated(e,o,"its value is not static")}
            on=value.x!=0
        }
        return pin_value(e,o,on?"A":"B",scope)
    case "StaticComponentMaskParameter":
        name:=prop_name(o,"ParameterName","")
        mask:=[4]bool{prop_bool(o,"DefaultR",false),prop_bool(o,"DefaultG",false),prop_bool(o,"DefaultB",false),prop_bool(o,"DefaultA",false)}
        if found:=override_find(e,name,.Mask,scope);found!=nil {mask={found.value.x!=0,found.value.y!=0,found.value.z!=0,found.value.w!=0}}
        input,_:=pin(e,o,"Input",scope)
        return nodes(mask_apply(g,input,mask))
    case "ComponentMask":
        input,_:=pin(e,o,"Input",scope)
        return nodes(mask_apply(g,input,{prop_bool(o,"R",false),prop_bool(o,"G",false),prop_bool(o,"B",false),prop_bool(o,"A",false)}))
    case "AppendVector":
        a,_:=pin(e,o,"A",scope)
        b,b_connected:=pin(e,o,"B",scope)
        if !b_connected {return nodes(a)}
        return nodes(append_values(g,a,b))
    case "Add":return nodes(binary(g,.Add,pin_or(e,o,"A","ConstA",0,scope),pin_or(e,o,"B","ConstB",1,scope)))
    case "Subtract":return nodes(binary(g,.Sub,pin_or(e,o,"A","ConstA",1,scope),pin_or(e,o,"B","ConstB",1,scope)))
    case "Multiply":return nodes(binary(g,.Mul,pin_or(e,o,"A","ConstA",0,scope),pin_or(e,o,"B","ConstB",1,scope)))
    case "Divide":return nodes(binary(g,.Div,pin_or(e,o,"A","ConstA",1,scope),pin_or(e,o,"B","ConstB",2,scope)))
    case "Min":return nodes(binary(g,.Min,pin_or(e,o,"A","ConstA",0,scope),pin_or(e,o,"B","ConstB",1,scope)))
    case "Max":return nodes(binary(g,.Max,pin_or(e,o,"A","ConstA",0,scope),pin_or(e,o,"B","ConstB",1,scope)))
    case "Fmod":
        a,_:=pin(e,o,"A",scope)
        b,_:=pin(e,o,"B",scope)
        return nodes(binary(g,.Fmod,a,b))
    case "Step":return nodes(binary(g,.Step,pin_or(e,o,"Y","ConstY",0,scope),pin_or(e,o,"X","ConstX",1,scope)))
    case "DotProduct","CrossProduct","Distance":
        a,_:=pin(e,o,"A",scope)
        b,_:=pin(e,o,"B",scope)
        if kind=="Distance" {return nodes(unary(g,.Length,binary(g,.Sub,a,b)))}
        return nodes(binary(g,kind=="DotProduct"?.Dot:.Cross,a,b))
    case "Power":
        base,_:=pin(e,o,"Base",scope)
        return nodes(binary(g,.Pow,base,pin_or(e,o,"Exponent","ConstExponent",2,scope)))
    case "LinearInterpolate":
        return nodes(ternary(g,.Lerp,pin_or(e,o,"A","ConstA",0,scope),pin_or(e,o,"B","ConstB",1,scope),pin_or(e,o,"Alpha","ConstAlpha",0.5,scope)))
    case "SmoothStep":
        return nodes(ternary(g,.Smoothstep,pin_or(e,o,"Min","ConstMin",0,scope),pin_or(e,o,"Max","ConstMax",1,scope),pin_or(e,o,"Value","ConstValue",0,scope)))
    case "InverseLinearInterpolate":
        a:=pin_or(e,o,"A","ConstA",0,scope)
        b:=pin_or(e,o,"B","ConstB",1,scope)
        value:=pin_or(e,o,"Value","ConstValue",0,scope)
        result:=binary(g,.Div,binary(g,.Sub,value,a),binary(g,.Sub,b,a))
        if prop_bool(o,"bClampResult",false) {result=unary(g,.Saturate,result)}
        return nodes(result)
    case "Clamp":
        input,_:=pin(e,o,"Input",scope)
        low:=pin_or(e,o,"Min","MinDefault",0,scope)
        high:=pin_or(e,o,"Max","MaxDefault",1,scope)
        switch prop_name(o,"ClampMode","CMODE_Clamp") {
        case "CMODE_ClampMin":return nodes(binary(g,.Max,input,low))
        case "CMODE_ClampMax":return nodes(binary(g,.Min,input,high))
        }
        return nodes(ternary(g,.Clamp,input,low,high))
    case "OneMinus":
        input:=pin_or(e,o,"Input","",0,scope)
        return nodes(binary(g,.Sub,scalar(g,1),input))
    case "Abs","Floor","Ceil","Frac","Round","Truncate","SquareRoot","Saturate","Sign","Length","Exponential","Exponential2",
         "Logarithm","Logarithm2","Arcsine","Arccosine","Arctangent","ArcsineFast","ArccosineFast","ArctangentFast":
        input,_:=pin(e,o,"Input",scope)
        if kind=="Logarithm2" {input,_=pin(e,o,"X",scope)}
        op:Op
        switch kind {
        case "Abs":op=.Abs
        case "Floor":op=.Floor
        case "Ceil":op=.Ceil
        case "Frac":op=.Frac
        case "Round":op=.Round
        case "Truncate":op=.Trunc
        case "SquareRoot":op=.Sqrt
        case "Saturate":op=.Saturate
        case "Sign":op=.Sign
        case "Length":op=.Length
        case "Exponential":op=.Exp
        case "Exponential2":op=.Exp2
        case "Logarithm":op=.Log
        case "Logarithm2":op=.Log2
        case "Arcsine","ArcsineFast":op=.Asin
        case "Arccosine","ArccosineFast":op=.Acos
        case "Arctangent","ArctangentFast":op=.Atan
        }
        return nodes(unary(g,op,input))
    case "Normalize":
        input,_:=pin(e,o,"VectorInput",scope)
        return nodes(unary(g,.Normalize,input))
    case "Sine","Cosine","Tangent":
        input,_:=pin(e,o,"Input",scope)
        period:=prop_float(o,"Period",1)
        if period>0 {input=binary(g,.Mul,input,scalar(g,2*math.PI/period))}
        return nodes(unary(g,kind=="Sine"?.Sin:kind=="Cosine"?.Cos:.Tan,input))
    case "Arctangent2","Arctangent2Fast":
        y,_:=pin(e,o,"Y",scope)
        x,_:=pin(e,o,"X",scope)
        return nodes(binary(g,.Atan2,y,x))
    case "Desaturation":
        color,_:=pin(e,o,"Input",scope)
        color=convert(g,color,3)
        factors:=[4]f32{0.3,0.59,0.11,0} if !e.ue5 else [4]f32{0.2126,0.7152,0.0722,0}
        factors=prop_vector(o,"LuminanceFactors",factors)
        grey:=binary(g,.Dot,color,constant(g,factors,3))
        fraction,connected:=pin(e,o,"Fraction",scope)
        if !connected {return nodes(grey)}
        return nodes(ternary(g,.Lerp,color,grey,fraction))
    case "If":
        a:=pin_or(e,o,"A","",0,scope)
        b:=pin_or(e,o,"B","ConstB",0,scope)
        greater:=pin_or(e,o,"AGreaterThanB","",0,scope)
        less:=pin_or(e,o,"ALessThanB","",0,scope)
        result:=ternary(g,.Select,binary(g,.Less,a,b),less,greater)
        if equal,connected:=pin(e,o,"AEqualsB",scope);connected {
            close:=binary(g,.Less_Equal,unary(g,.Abs,binary(g,.Sub,a,b)),scalar(g,prop_float(o,"EqualsThreshold",0.00001)))
            result=ternary(g,.Select,close,equal,result)
        }
        return nodes(result)
    case "TextureCoordinate":
        if prop_bool(o,"UnMirrorU",false) || prop_bool(o,"UnMirrorV",false) {return untranslated(e,o,"unmirrored coordinates")}
        index:=prop_int(o,"CoordinateIndex",0)
        if (index<0 || index>1) && e.landscape==nil {return untranslated(e,o,UV_SETS_PAST)}
        uv:=uv_value(e,u32(index))
        return nodes(binary(g,.Mul,uv,constant(g,{prop_float(o,"UTiling",1),prop_float(o,"VTiling",1),0,0},2)))
    case "BumpOffset":
        // The coordinates without the offset by the view: see legacy_adapted.
        uv,uv_connected:=pin(e,o,"Coordinate",scope)
        if !uv_connected {uv=uv_value(e,u32(prop_int(o,"ConstCoordinate",0)))}
        note(e,"bump offset: the surface is shaded where it is, without the relief")
        return nodes(uv)
    case "Panner":
        time,connected:=pin(e,o,"Time",scope)
        if !connected {time=context_value(g,.Time,1)}
        speed,speed_connected:=pin(e,o,"Speed",scope)
        if !speed_connected {speed=constant(g,{prop_float(o,"SpeedX",0),prop_float(o,"SpeedY",0),0,0},2)}
        offset:=binary(g,.Mul,convert(g,time,1),convert(g,speed,2))
        if prop_bool(o,"bFractionalPart",false) {offset=unary(g,.Frac,offset)}
        uv,uv_connected:=pin(e,o,"Coordinate",scope)
        if !uv_connected {uv=uv_value(e,u32(prop_int(o,"ConstCoordinate",0)))}
        return nodes(binary(g,.Add,offset,uv))
    case "RotateAboutAxis":
        // The offset from Position to it turned about the axis through the pivot.
        angle,_:=pin(e,o,"RotationAngle",scope)
        axis,_:=pin(e,o,"NormalizedRotationAxis",scope)
        pivot,_:=pin(e,o,"PivotPoint",scope)
        position,_:=pin(e,o,"Position",scope)
        angle=binary(g,.Mul,component(g,angle,0),scalar(g,2*math.PI/prop_float(o,"Period",1)))
        axis=convert(g,axis,3)
        offset:=convert(g,binary(g,.Sub,position,pivot),3)
        u:=binary(g,.Sub,offset,binary(g,.Mul,axis,binary(g,.Dot,axis,offset)))
        v:=binary(g,.Cross,axis,u)
        r:=binary(g,.Add,binary(g,.Mul,u,unary(g,.Cos,angle)),binary(g,.Mul,v,unary(g,.Sin,angle)))
        return nodes(binary(g,.Sub,r,u))
    case "SphereMask":
        a,_:=pin(e,o,"A",scope)
        b,_:=pin(e,o,"B",scope)
        radius:=binary(g,.Max,scalar(g,0.00001),pin_or(e,o,"Radius","AttenuationRadius",256,scope))
        hardness:=binary(g,.Max,scalar(g,0.00001),binary(g,.Sub,scalar(g,1),pin_or(e,o,"Hardness","",prop_float(o,"HardnessPercent",100)*0.01,scope)))
        distance:=binary(g,.Div,unary(g,.Length,binary(g,.Sub,a,b)),radius)
        return nodes(unary(g,.Saturate,binary(g,.Div,binary(g,.Sub,scalar(g,1),distance),hardness)))
    case "TwoSidedSign":
        // Unreal leaves the frame of a back face as it is and the graph turns
        // it with this sign; Mirai turns the frame of a back face itself.
        note(e,"TwoSidedSign is 1: Mirai turns the tangent frame of back faces itself")
        return nodes(scalar(g,1))
    case "Rotator":
        time,connected:=pin(e,o,"Time",scope)
        if !connected {time=context_value(g,.Time,1)}
        time=binary(g,.Mul,time,scalar(g,prop_float(o,"Speed",0.25)))
        uv,uv_connected:=pin(e,o,"Coordinate",scope)
        if !uv_connected {uv=uv_value(e,u32(prop_int(o,"ConstCoordinate",0)))}
        center:=constant(g,{prop_float(o,"CenterX",0.5),prop_float(o,"CenterY",0.5),0,0},2)
        uv=binary(g,.Sub,convert(g,uv,2),center)
        c,s:=unary(g,.Cos,time),unary(g,.Sin,time)
        x,y:=component(g,uv,0),component(g,uv,1)
        turned:=append_values(g,binary(g,.Sub,binary(g,.Mul,c,x),binary(g,.Mul,s,y)),binary(g,.Add,binary(g,.Mul,s,x),binary(g,.Mul,c,y)))
        return nodes(binary(g,.Add,turned,center))
    case "Time":
        time:=context_value(g,.Time,1)
        if prop_bool(o,"bOverride_Period",false) {
            period:=prop_float(o,"Period",0)
            if period==0 {return nodes(scalar(g,0))}
            return nodes(binary(g,.Fmod,time,scalar(g,period)))
        }
        return nodes(time)
    case "VertexColor":return nodes(context_value(g,.Vertex_Color,4))
    // The point in the space of its object.
    case "LocalPosition":return nodes(object_point(e,world_place(e,.World_Position)))
    case "WorldPosition":
        if strings.contains(prop_name(o,"WorldPositionShaderOffset",""),"CameraRelative") {return untranslated(e,o,"Mirai programs see positions of the world, not those of the camera")}
        return nodes(world_place(e,.World_Position))
    case "VertexNormalWS":return nodes(context_value(g,.Vertex_Normal,3))
    case "PixelNormalWS":return nodes(context_value(g,.Pixel_Normal,3))
    case "PerInstanceRandom":
        note(e,"PerInstanceRandom is taken as 0.5, its mean: Mirai programs have no per instance value")
        return nodes(scalar(g,0.5))
    case "Reroute":
        return pin_value(e,o,"Input",scope)
    // Computes its input per vertex and interpolates it: the same value, which Mirai computes per pixel.
    case "VertexInterpolator":
        return pin_value(e,o,"Input",scope)
    // The floats an instance of an instanced mesh carries, from DataIndex on.
    case "PerInstanceCustomData":
        e.reads_custom_data=true
        index:=prop_int(o,"DataIndex",0)
        if index>=0 && index<len(e.custom_data) {return nodes(scalar(g,e.custom_data[index]))}
        return nodes(pin_or(e,o,"DefaultValue","ConstDefaultValue",0,scope))
    case "PerInstanceCustomData3Vector":
        e.reads_custom_data=true
        index:=prop_int(o,"DataIndex",0)
        if index>=0 && index+3<=len(e.custom_data) {
            d:=e.custom_data[index:]
            return nodes(constant(g,{d[0],d[1],d[2],0},3))
        }
        if node,connected:=pin(e,o,"DefaultValue",scope);connected {return nodes(node)}
        return nodes(constant(g,prop_vector(o,"ConstDefaultValue",{}),3))
    case "NamedRerouteDeclaration":
        return pin_value(e,o,"Input",scope)
    case "NamedRerouteUsage":
        declaration,found:=object_resolve(e.lib,o.pkg,prop_object(o,"Declaration"))
        if !found {return untranslated(e,o,"its declaration is missing")}
        return expression(e,declaration,0,scope)
    case "FeatureLevelSwitch","QualitySwitch","ShadingPathSwitch":
        return pin_value(e,o,"Default",scope)
    // Mirai has no virtual textures: the branches Unreal takes on a platform without them.
    case "VirtualTextureFeatureSwitch":
        return pin_value(e,o,"No",scope)
    case "RuntimeVirtualTextureReplace":
        return pin_value(e,o,"Default",scope)
    case "TextureObject","TextureObjectParameter":
        return nodes(texture_object(e,o,scope))
    case "TextureSample","TextureSampleParameter2D":
        return texture_sample(e,o,scope)
    // The texels of a texture across and down, or the size of one texel in its coordinates.
    case "TextureProperty":
        tex,connected:=pin(e,o,"TextureObject",scope)
        if !connected {return untranslated(e,o,"it names no texture")}
        // What failed upstream was counted there.
        size:=texture_size(g,tex)
        if size==NONE {return NO_VALUE}
        if prop_name(o,"Property","TMTM_TextureSize")=="TMTM_TexelSize" {return nodes(binary(g,.Div,scalar(g,1),size))}
        return nodes(size)
    case "CollectionParameter":
        return collection_parameter(e,o)
    case "MaterialFunctionCall":
        return function_call(e,o,output,scope)
    case "FunctionInput":
        return function_input(e,o,scope)
    case "FunctionOutput","MaterialLayerOutput":
        return pin_value(e,o,"A",scope)
    case "MakeMaterialAttributes":
        row:[Attribute]u32
        for name,attribute in ATTRIBUTE_NAMES {
            node,connected:=pin(e,o,name,scope)
            if !connected {node=constant(g,ATTRIBUTE_DEFAULTS[attribute],ATTRIBUTE_WIDTHS[attribute])}
            row[attribute]=node
        }
        append(&e.aggregates,row)
        return {NONE,i32(len(e.aggregates)-1)}
    case "BreakMaterialAttributes":
        aggregate:=pin_value(e,o,"MaterialAttributes",scope)
        attribute,known:=break_output(e,o,output)
        if aggregate.aggregate<0 || !known {return untranslated(e,o,"an output Mirai has no value for")}
        return nodes(e.aggregates[aggregate.aggregate][attribute])
    case "GetMaterialAttributes":
        return get_attributes(e,o,output,scope)
    case "SetMaterialAttributes":
        return set_attributes(e,o,scope)
    case "BlendMaterialAttributes":
        a:=pin_value(e,o,"A",scope)
        b:=pin_value(e,o,"B",scope)
        alpha,_:=pin(e,o,"Alpha",scope)
        if a.aggregate<0 || b.aggregate<0 {return untranslated(e,o,"it blends values that are not material attributes")}
        row:[Attribute]u32
        for attribute in Attribute {row[attribute]=ternary(g,.Lerp,e.aggregates[a.aggregate][attribute],e.aggregates[b.aggregate][attribute],alpha)}
        append(&e.aggregates,row)
        return {NONE,i32(len(e.aggregates)-1)}
    case "MaterialAttributeLayers":return material_layers(e,o,scope)
    case "LandscapeLayerBlend":return landscape_blend(e,o,scope)
    case "LandscapeLayerWeight":return landscape_weight(e,o,scope)
    case "LandscapeLayerSample":
        name:=prop_name(o,"ParameterName","")
        layer_seen(e,name)
        weight,_:=layer_weight_node(e,name)
        return nodes(weight)
    case "LandscapeLayerSwitch":
        name:=prop_name(o,"ParameterName","")
        layer_seen(e,name)
        _,used:=layer_weight_node(e,name)
        return pin_value(e,o,used?"LayerUsed":"LayerNotUsed",scope)
    case "LandscapeLayerCoords":return nodes(landscape_coords(e,o))
    // The holes of a Landscape are holes of its terrain: what is drawn is visible.
    case "LandscapeVisibilityMask":return nodes(scalar(g,1))
    case "Comment":return NO_VALUE
    }
    switch kind {
    case "Fresnel":
        base,connected:=pin(e,o,"BaseReflectFractionIn",scope)
        if !connected {base=scalar(g,prop_float(o,"BaseReflectFraction",0.04))}
        value,ok:=evaluate_constant(g,base)
        if !ok {return untranslated(e,o,"its base reflection is not constant")}
        note(e,"Fresnel %s is taken at normal incidence (%g): Mirai's surfaces reflect with their own Fresnel",object_name(o),value.x)
        return nodes(node_add(g,{op=.Fresnel,width=1,value={value.x,0,0,0},args={NONE,NONE,NONE}}))
    // The view, like Fresnel, at normal incidence: Mirai's surfaces reflect by
    // the view themselves, so what fakes it by the view sees the surface head on.
    case "CameraVectorWS","ReflectionVectorWS":
        note(e,"%s is taken at normal incidence: the surface seen head on",object_name(o))
        return nodes(context_value(g,.Pixel_Normal,3))
    case "CameraPositionWS":
        // A point along the normal, whose direction from the surface is that view.
        note(e,"%s is taken at normal incidence: the surface seen head on",object_name(o))
        return nodes(binary(g,.Add,world_place(e,.World_Position),context_value(g,.Pixel_Normal,3)))
    case "EyeAdaptationInverse":
        // LightValue·Exposure^-Alpha (EyeAdaptationInverseLookup): with Alpha 1
        // its light value is relative to the exposure, with 0 physical.
        light,has_light:=pin(e,o,"LightValueInput",scope)
        if !has_light {light=constant(g,{1,1,1,0},3)}
        alpha:=f32(1)
        if node,has_alpha:=pin(e,o,"AlphaInput",scope);has_alpha {
            value,constant_ok:=evaluate_constant(g,node)
            if !constant_ok || value.x!=0 && value.x!=1 {return untranslated(e,o,"an exposure undone in part: Mirai's emission is physical or relative to the exposure")}
            alpha=value.x
        }
        if alpha==1 {
            e.exposure_relative=true
            note(e,"%s: the emission is relative to the exposure",object_name(o))
        }
        return nodes(light)
    // The point in the image of the view (ViewportUV) and in its pixels (PixelPosition).
    case "ScreenPosition":
        uv:=context_value(g,.Screen_Position,2)
        if output==1 {return nodes(binary(g,.Mul,uv,context_value(g,.Screen_Size,2)))}
        return nodes(uv)
    case "ViewSize":return nodes(context_value(g,.Screen_Size,2))
    case "SceneTexelSize":return nodes(binary(g,.Div,scalar(g,1),context_value(g,.Screen_Size,2)))
    case "PixelDepth":return nodes(context_value(g,.Pixel_Depth,1))
    case "SceneDepth":
        if _,connected:=pin(e,o,"Input",scope);connected {return untranslated(e,o,"it reads the depth at another point of the image: Mirai programs see the depth behind their own point")}
        return nodes(context_value(g,.Scene_Depth,1))
    // Opacity faded by the depth between the point and the opaque surface behind it.
    case "DepthFade":
        opacity:=pin_or(e,o,"InOpacity","OpacityDefault",1,scope)
        fade:=binary(g,.Max,pin_or(e,o,"FadeDistance","FadeDistanceDefault",100,scope),scalar(g,0.00001))
        between:=binary(g,.Sub,context_value(g,.Scene_Depth,1),context_value(g,.Pixel_Depth,1))
        return nodes(binary(g,.Mul,opacity,unary(g,.Saturate,binary(g,.Div,between,fade))))
    case "SceneColor","SceneTexture":
        return untranslated(e,o,"Mirai surface programs do not see the image behind them; a postprocess program does")
    case "DistanceToNearestSurface","DistanceFieldGradient","DistanceFieldApproxAO":
        return untranslated(e,o,"Mirai's renderer keeps no distance field of the scene")
    case "Transform":return transform_vector(e,o,scope)
    case "TransformPosition":return transform_position(e,o,scope)
    case "ObjectPositionWS","ActorPositionWS":
        if strings.contains(prop_name(o,"OriginType",""),"CameraRelative") {return untranslated(e,o,"Mirai programs see positions of the world, not those of the camera")}
        if kind=="ActorPositionWS" {
            note(e,"ActorPositionWS is the pivot of the object: Mirai programs do not see the actor of a component")
            return nodes(world_place(e,.Actor_Position))
        }
        return nodes(world_place(e,.Object_Position))
    case "ObjectRadius":return nodes(context_value(g,.Object_Radius,1))
    // The up of the object in the world: its local Z.
    case "ObjectOrientation":return nodes(unary(g,.Normalize,object_axis(e,2)))
    // Half the size of the box around the object along each axis of the world.
    case "ObjectBounds":
        half:=binary(g,.Mul,binary(g,.Sub,context_value(g,.Object_Bounds,3,1),context_value(g,.Object_Bounds,3,0)),scalar(g,0.5))
        along :: proc(e:^Evaluator,half:u32,i:u8) -> u32 {return binary(e.g,.Mul,unary(e.g,.Abs,object_axis(e,u32(i))),component(e.g,half,i))}
        return nodes(binary(g,.Add,binary(g,.Add,along(e,half,0),along(e,half,1)),along(e,half,2)))
    // The bounds of the mesh in its own space, of the object, an instance or
    // before skinning alike: half and whole their size, their low and high
    // corners.
    case "ObjectLocalBounds","PreSkinnedLocalBounds","Bounds":
        low,high:=context_value(g,.Object_Bounds,3,0),context_value(g,.Object_Bounds,3,1)
        size:=binary(g,.Sub,high,low)
        switch output {
        case 1:return nodes(size)
        case 2:return nodes(low)
        case 3:return nodes(high)
        }
        return nodes(binary(g,.Mul,size,scalar(g,0.5)))
    // The color of the particle: a sprite gives its program as the color of its vertices.
    case "ParticleColor":return nodes(context_value(g,.Vertex_Color,4))
    // What the particle gives the material as its program says (Mirai_Vfx_Visual.data), the
    // default where it gives none; RGB and RGBA after its four components.
    case "DynamicParameter":
        index:=u32(clamp(prop_int(o,"ParameterIndex",0),0,3))
        data:=node_add(g,{op=.Particle_Data,width=4,index=index,value=prop_vector(o,"DefaultValue",{1,1,1,1}),args={NONE,NONE,NONE}})
        switch output {
        case 0..=3:return nodes(component(g,data,u8(output)))
        case 4:return nodes(swizzle(g,data,{0,1,2,0},3))
        }
        return nodes(data)
    // The random value of the particle, as its program gives it (Mirai_Vfx_Visual.random),
    // and its radius: half the narrower side of its sprite.
    case "ParticleRandom":return nodes(context_value(g,.Particle_Random,1))
    case "ParticleRadius":return nodes(context_value(g,.Particle_Radius,1))
    case "ParticleSubUV","ParticlePositionWS","ParticleRelativeTime":
        return untranslated(e,o,"particle values belong to .particle programs")
    case "Custom":return custom_expression(e,o,output,scope)
    case "Noise","VectorNoise":
        vector:=kind=="VectorNoise"
        position,connected:=pin(e,o,"Position",scope)
        if !connected {position=world_place(e,.World_Position)}
        position=convert(g,position,3)
        // What failed upstream was counted there.
        if position==NONE {return NO_VALUE}
        s:=Noise_Settings{quality=i32(prop_int(o,"Quality",1)),tiling=prop_bool(o,"bTiling",false)}
        filter:=NONE
        if vector {
            s.function=i32(prop_enum(o,"NoiseFunction",VECTOR_NOISE_FUNCTIONS,0))
            s.repeat_size=f32(prop_int(o,"TileSize",300))
        } else {
            s.function=i32(prop_enum(o,"NoiseFunction",NOISE_FUNCTIONS,0))
            s.scale=prop_float(o,"Scale",1)
            s.levels=i32(clamp(prop_int(o,"Levels",6),1,10))
            s.output_min,s.output_max=prop_float(o,"OutputMin",-1),prop_float(o,"OutputMax",1)
            s.level_scale=prop_float(o,"LevelScale",2)
            s.turbulence=prop_bool(o,"bTurbulence",true)
            s.repeat_size=f32(prop_int(o,"RepeatSize",512))
            // Unreal mirrors and repeats a position of the world before its scalar noise.
            s.world=depends_on(g,position,{.Origin})
            filter=pin_or(e,o,"FilterWidth","",0,scope)
        }
        return nodes(noise(g,s,position,convert(g,filter,1),vector))
    }
    return untranslated(e,o,"not translated")
}

// ECustomMaterialOutputType, in its order: the widths of its float types.
@(private)
CUSTOM_OUTPUT_TYPES :: []string{"CMOT_Float1","CMOT_Float2","CMOT_Float3","CMOT_Float4","CMOT_MaterialAttributes"}

// What custom HLSL reads that a Mirai program does not have: Unreal's view,
// primitive and pixel parameters, its other shader files, the image and
// derivatives, which a Surface program cannot take (it also runs in rays).
@(private)
CUSTOM_UNPORTED :: []string{"View.","ResolvedView","Primitive.","GetPrimitiveData","Parameters.","Material.","MaterialCollection",
    "LWC","DFDemote","DFFrac","SceneTexture","GetScreenPosition","SvPosition","ddx","ddy","DDX","DDY","fwidth","clip(","discard",
    "tex2D","GetDimensions",".Sample",".Load(","#include","(const "}

// The Custom expression: its code as a function of the program, called with
// its inputs as Unreal declares them. Output 0 is what the code returns,
// the others its additional outputs. Code that reads what a Mirai program
// does not have is kept in the program as a note to port it, and gives
// zero until then.
@(private)
custom_expression :: proc(e:^Evaluator,o:Object,output,scope:i32) -> Value {
    g:=e.g
    if output>0 {
        call:=expression(e,o,0,scope).node
        outputs:=prop_structs(o,"AdditionalOutputs")
        if call==NONE || int(output)>len(outputs) {return NO_VALUE}
        type:=list_enum(&o.pkg.p,&outputs[output-1],"OutputType",CUSTOM_OUTPUT_TYPES)
        if type>3 {return untranslated(e,o,"an output of material attributes")}
        return nodes(custom_output(g,call,u32(output),u8(type+1)))
    }
    type:=prop_enum(o,"OutputType",CUSTOM_OUTPUT_TYPES,2)
    if type>3 {return untranslated(e,o,"it gives material attributes")}
    p:=&o.pkg.p
    out:=g.customs.allocator
    code:Custom_Code
    code.width=u8(type+1)
    code.description=prop_string(o,"Description",out)
    text,_:=strings.replace_all(prop_string(o,"Code"),"\r\n","\n",context.temp_allocator)
    if !strings.contains(text,"return") {text=strings.concatenate({"return ",text,";"},context.temp_allocator)}
    defines:=strings.builder_make(context.temp_allocator)
    for &item in prop_structs(o,"AdditionalDefines") {
        name:=list_string(p,&item,"DefineName")
        if name!="" {fmt.sbprintf(&defines,"#ifndef %s\n#define %s %s\n#endif\n",name,name,list_string(p,&item,"DefineValue"))}
    }
    code.code=strings.concatenate({strings.to_string(defines),text},out)
    inputs:=make([dynamic]u32,context.temp_allocator)
    names:=make([dynamic]string,out)
    for &item in prop_structs(o,"Inputs") {
        name:=list_name(p,&item,"InputName")
        if name=="" || name=="None" {continue}
        found:=unreal.property_find(p,&item,"Input")
        input,ok:=Input{},false
        if found!=nil {input,ok=input_read(p,found)}
        if !ok || input.expression==0 {return untranslated(e,o,fmt.tprintf("its input %s is not connected",name))}
        value:=input_value(e,o,input,scope)
        if value.aggregate>=0 {return untranslated(e,o,fmt.tprintf("its input %s is material attributes",name))}
        // What failed upstream was counted there.
        if value.node==NONE {return NO_VALUE}
        append(&inputs,value.node)
        append(&names,strings.clone(name,out))
    }
    code.inputs=names[:]
    extra:=make([dynamic]Custom_Output,out)
    for &item in prop_structs(o,"AdditionalOutputs") {
        name:=list_name(p,&item,"OutputName")
        type:=list_enum(p,&item,"OutputType",CUSTOM_OUTPUT_TYPES)
        if type>3 {return untranslated(e,o,"an output of material attributes")}
        append(&extra,Custom_Output{strings.clone(name,out),u8(type+1)})
    }
    code.outputs=extra[:]
    reads:=make([dynamic]string,context.temp_allocator)
    for token in CUSTOM_UNPORTED {if strings.contains(code.code,token) || token=="#include" && property(o,"IncludeFilePaths")!=nil {append(&reads,token)}}
    custom_foreign_calls(code.code,&reads)
    if len(reads)>0 {
        code.unported=strings.join(reads[:],", ",out)
        untranslated(e,o,fmt.tprintf("its HLSL reads %s: the program keeps it as a note to port to Slang, and it gives zero until then",code.unported))
    }
    return nodes(custom(g,code,inputs[:]))
}

// What custom HLSL may call: HLSL's intrinsics and types, the names the
// program gives Unreal's (CUSTOM_PRELUDE) and Unreal's noise
// (unreal_noise.slang). A call of anything else that the code does not
// define is of Unreal's shader library.
@(private)
CUSTOM_CALLABLE :: []string{
    "abs","acos","all","any","asin","asint","asuint","asfloat","atan","atan2","ceil","clamp","cos","cosh","countbits","cross","degrees",
    "determinant","distance","dot","exp","exp2","f16tof32","f32tof16","faceforward","firstbithigh","firstbitlow","floor","fma","fmod",
    "frac","frexp","isfinite","isinf","isnan","ldexp","length","lerp","log","log10","log2","mad","max","min","modf","mul","normalize",
    "pow","radians","rcp","reflect","refract","reversebits","round","rsqrt","saturate","select","sign","sin","sincos","sinh","smoothstep",
    "sqrt","step","tan","tanh","transpose","trunc",
    "if","for","while","switch","return","sizeof",
    "Texture2DSample","Texture2DSampleLevel","Texture2DSampleBias","Texture2DSampleGrad",
    "Rand3DPCG16","Rand3DPCG32","PseudoRandom","RandBBSfloat","NoiseTileWrap","PerlinRamp","GradientNoise3D_ALU","ValueNoise3D_ALU",
    "JacobianSimplex_ALU","GradientNoise3D_TEX","FastGradientPerlinNoise3D_TEX","SimplexNoise3D_TEX","VoronoiNoise3D_ALU",
    "MaterialExpressionNoise","MaterialExpressionVectorNoise",
}

// Adds to reads the functions code calls that it neither defines nor may
// call (CUSTOM_CALLABLE), as name().
@(private)
custom_foreign_calls :: proc(code:string,reads:^[dynamic]string) {
    is_word :: proc(c:u8) -> bool {return c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' || c=='_'}
    Token :: struct {word:string,call,defines:bool}
    tokens:=make([dynamic]Token,context.temp_allocator)
    // The word before, when only spaces are between: the type of a definition.
    previous:=""
    for i:=0;i<len(code); {
        c:=code[i]
        if !is_word(c) {
            // A comment is not code.
            if c=='/' && i+1<len(code) && code[i+1]=='/' {for i<len(code) && code[i]!='\n' {i+=1};continue}
            if c!=' ' && c!='\t' && c!='\n' && c!='\r' {previous=""}
            i+=1
            continue
        }
        start:=i
        for i<len(code) && is_word(code[i]) {i+=1}
        word:=code[start:i]
        j:=i
        for j<len(code) && (code[j]==' ' || code[j]=='\t') {j+=1}
        call:=j<len(code) && code[j]=='(' && !(word[0]>='0' && word[0]<='9') && !(start>0 && code[start-1]=='.')
        append(&tokens,Token{word,call,call && previous!="" && previous!="return" && previous!="else"})
        previous=word
    }
    defined:=make(map[string]bool,allocator=context.temp_allocator)
    for token in tokens {if token.defines {defined[token.word]=true}}
    callable :: proc(word:string) -> bool {
        for name in CUSTOM_CALLABLE {if word==name {return true}}
        for prefix in ([]string{"float","half","int","uint","bool","double","MaterialFloat"}) {
            if strings.has_prefix(word,prefix) {
                rest:=word[len(prefix):]
                if rest=="" || len(rest)==1 && rest[0]>='1' && rest[0]<='4' || len(rest)==3 && rest[1]=='x' {return true}
            }
        }
        return false
    }
    for token in tokens {
        if !token.call || token.defines || defined[token.word] || callable(token.word) {continue}
        name:=fmt.tprintf("%s()",token.word)
        known:=false
        for r in reads {known||=r==name}
        if !known {append(reads,name)}
    }
}

// ENoiseFunction and EVectorNoiseFunction, in their order.
@(private)
NOISE_FUNCTIONS :: []string{"NOISEFUNCTION_SimplexTex","NOISEFUNCTION_GradientTex","NOISEFUNCTION_GradientTex3D","NOISEFUNCTION_GradientALU",
    "NOISEFUNCTION_ValueALU","NOISEFUNCTION_VoronoiALU"}
@(private)
VECTOR_NOISE_FUNCTIONS :: []string{"VNF_CellnoiseALU","VNF_VectorALU","VNF_GradientALU","VNF_CurlALU","VNF_VoronoiALU"}

// EMaterialVectorCoordTransformSource and EMaterialVectorCoordTransform, in their order.
@(private)
TRANSFORM_SOURCES :: []string{"TRANSFORMSOURCE_Tangent","TRANSFORMSOURCE_Local","TRANSFORMSOURCE_World","TRANSFORMSOURCE_View",
    "TRANSFORMSOURCE_Camera","TRANSFORMSOURCE_ParticleWorld","TRANSFORMSOURCE_Instance"}
@(private)
TRANSFORM_TARGETS :: []string{"TRANSFORM_Tangent","TRANSFORM_Local","TRANSFORM_World","TRANSFORM_View","TRANSFORM_Camera",
    "TRANSFORM_ParticleWorld","TRANSFORM_Instance"}

// A vector from one space to another, as EmitTransformVector: through the
// world, by the tangent frame of the surface or the axes of its object.
@(private)
transform_vector :: proc(e:^Evaluator,o:Object,scope:i32) -> Value {
    g:=e.g
    TANGENT,LOCAL,WORLD,INSTANCE :: 0,1,2,6
    source:=prop_enum(o,"TransformSourceType",TRANSFORM_SOURCES,TANGENT)
    target:=prop_enum(o,"TransformType",TRANSFORM_TARGETS,WORLD)
    v,connected:=pin(e,o,"Input",scope)
    if !connected {v=constant(g,{},3)}
    if v==NONE {return NO_VALUE}
    // A scalar in tangent space is a height along the normal.
    if source==TANGENT && width_of(g,v)==1 {v=append_values(g,constant(g,{},2),v)}
    v=convert(g,v,3)
    if source==target {return nodes(v)}
    known :: proc(space:int) -> bool {return space==TANGENT || space==LOCAL || space==WORLD || space==INSTANCE}
    if !known(source) || !known(target) {return untranslated(e,o,"Mirai programs see the tangent frame, the object and the world, not the view or particles")}
    t,b,n:=tangent_frame(e)
    world:=v
    switch source {
    case TANGENT:world=frame_vector(g,v,t,b,n)
    case LOCAL,INSTANCE:world=frame_vector(g,v,object_axis(e,0),object_axis(e,1),object_axis(e,2))
    }
    switch target {
    case TANGENT:return nodes(append_values(g,append_values(g,binary(g,.Dot,world,t),binary(g,.Dot,world,b)),binary(g,.Dot,world,n)))
    case LOCAL,INSTANCE:return nodes(object_vector(e,world))
    }
    return nodes(world)
}

// EMaterialPositionTransformSource as a saved name gives it.
@(private)
POSITION_SPACES :: []string{"TRANSFORMPOSSOURCE_Local","TRANSFORMPOSSOURCE_World","TRANSFORMPOSSOURCE_Instance","TRANSFORMPOSSOURCE_PeriodicWorld",
    "TRANSFORMPOSSOURCE_TranslatedWorld","TRANSFORMPOSSOURCE_View","TRANSFORMPOSSOURCE_Camera","TRANSFORMPOSSOURCE_Particle",
    "TRANSFORMPOSSOURCE_FirstPersonTranslatedWorld"}

// A position from one space to another (TransformPosition): between the
// object and the world.
@(private)
transform_position :: proc(e:^Evaluator,o:Object,scope:i32) -> Value {
    g:=e.g
    LOCAL,WORLD,INSTANCE :: 0,1,2
    source:=prop_enum(o,"TransformSourceType",POSITION_SPACES,LOCAL)
    target:=prop_enum(o,"TransformType",POSITION_SPACES,LOCAL)
    v,connected:=pin(e,o,"Input",scope)
    if !connected {v=constant(g,{},3)}
    if v==NONE {return NO_VALUE}
    v=convert(g,v,3)
    local :: proc(space:int) -> bool {return space==LOCAL || space==INSTANCE}
    switch {
    case source==target || local(source) && local(target):return nodes(v)
    case local(source) && target==WORLD:return nodes(world_point(e,v))
    case source==WORLD && local(target):return nodes(object_point(e,v))
    }
    return untranslated(e,o,"Mirai programs see positions of the object and the world, not those of the camera, the view or particles")
}

// a·x + b·y + c·z for the components of v.
@(private)
frame_vector :: proc(g:^Graph,v,x,y,z:u32) -> u32 {
    along:=binary(g,.Add,binary(g,.Mul,component(g,v,0),x),binary(g,.Mul,component(g,v,1),y))
    return binary(g,.Add,along,binary(g,.Mul,component(g,v,2),z))
}

// Axis i of the object in the world, in Unreal's axes and as long as the
// scale of the object along it.
@(private)
object_axis :: proc(e:^Evaluator,i:u32) -> u32 {return context_value(e.g,.Object_Axis,3,i)}

// A vector of the world in the space of the object: along each axis, over
// its length squared (the axes are square to each other).
@(private)
object_vector :: proc(e:^Evaluator,v:u32) -> u32 {
    g:=e.g
    along :: proc(g:^Graph,v,axis:u32) -> u32 {return binary(g,.Div,binary(g,.Dot,v,axis),binary(g,.Max,binary(g,.Dot,axis,axis),scalar(g,1e-30)))}
    return append_values(g,append_values(g,along(g,v,object_axis(e,0)),along(g,v,object_axis(e,1))),along(g,v,object_axis(e,2)))
}

@(private)
object_point :: proc(e:^Evaluator,p:u32) -> u32 {return object_vector(e,binary(e.g,.Sub,p,world_place(e,.Actor_Position)))}

@(private)
world_point :: proc(e:^Evaluator,p:u32) -> u32 {
    g:=e.g
    return binary(g,.Add,world_place(e,.Actor_Position),frame_vector(g,p,object_axis(e,0),object_axis(e,1),object_axis(e,2)))
}

// A place of the world as Unreal gives it, from the centre of the world: the
// place relative to the origin of the render plus the origin, so what is
// projected from the world does not jump when the origin moves.
@(private)
world_place :: proc(e:^Evaluator,op:Op) -> u32 {
    g:=e.g
    return binary(g,.Add,context_value(g,op,3),context_value(g,.Origin,3))
}

// The tangent frame of the surface in the world: that of the mesh or, in a
// whole landscape, Unreal's, along the axes of the landscape across its
// normal.
@(private)
tangent_frame :: proc(e:^Evaluator) -> (t,b,n:u32) {
    g:=e.g
    n=context_value(g,.Vertex_Normal,3)
    if e.landscape==nil {return context_value(g,.Vertex_Tangent,3),context_value(g,.Vertex_Bitangent,3),n}
    across :: proc(g:^Graph,axis,n:u32) -> u32 {return unary(g,.Normalize,binary(g,.Sub,axis,binary(g,.Mul,n,binary(g,.Dot,axis,n))))}
    return across(g,object_axis(e,0),n),across(g,object_axis(e,1),n),n
}

@(private)
pin_value :: proc(e:^Evaluator,o:Object,name:string,scope:i32) -> Value {
    input,ok:=prop_input(o,name)
    if !ok || input.expression==0 {return NO_VALUE}
    return input_value(e,o,input,scope)
}

@(private)
mask_apply :: proc(g:^Graph,n:u32,mask:[4]bool) -> u32 {
    components:[4]u8
    count:u8
    for keep,c in mask {
        if keep {components[count]=u8(c);count+=1}
    }
    if count==0 {return NONE}
    return swizzle(g,n,components,count)
}

// The value of a static switch or bool parameter: the instance's, else the default.
@(private)
static_switch :: proc(e:^Evaluator,o:Object,scope:i32) -> bool {
    name:=prop_name(o,"ParameterName","")
    if found:=override_find(e,name,.Switch,scope);found!=nil {return found.value.x!=0}
    return prop_bool(o,"DefaultValue",false)
}

@(private)
SAMPLER_NAMES :: []string{
    "SAMPLERTYPE_Color","SAMPLERTYPE_Grayscale","SAMPLERTYPE_Alpha","SAMPLERTYPE_Normal","SAMPLERTYPE_Masks",
    "SAMPLERTYPE_DistanceFieldFont","SAMPLERTYPE_LinearColor","SAMPLERTYPE_LinearGrayscale","SAMPLERTYPE_Data","SAMPLERTYPE_External",
}

@(private)
texture_object :: proc(e:^Evaluator,o:Object,scope:i32) -> u32 {
    ref:Texture_Ref
    ref.sampler=Sampler(prop_enum(o,"SamplerType",SAMPLER_NAMES,0))
    reference:=prop_object(o,"Texture")
    if class:=object_class(o);strings.has_suffix(class,"Parameter") || strings.has_suffix(class,"Parameter2D") {
        ref.parameter=prop_name(o,"ParameterName","")
        if found:=override_find(e,ref.parameter,.Texture,scope);found!=nil {
            ref.path=found.texture
        }
    }
    if ref.path=="" && reference!=0 {
        path,error:=unreal.reference_path(&o.pkg.p,reference,e.g.textures.allocator)
        if error.code!=.None {return NONE}
        ref.path=path
    }
    // A texture a system writes as it runs, by its path or by its parameter (one Unreal fills then).
    for read in e.reads {
        if read.function=="" || read.texture=="" || read.texture!=ref.path && read.texture!=ref.parameter {continue}
        a:=e.g.textures.allocator
        ref.read={strings.clone(read.texture,a),strings.clone(read.include,a),strings.clone(read.function,a),strings.clone(read.name,a)}
        break
    }
    if ref.path=="" && ref.read.function=="" {return NONE}
    ref.name=ref.path[strings.last_index_any(ref.path,"./:")+1:]
    return texture(e.g,ref)
}

@(private)
texture_sample :: proc(e:^Evaluator,o:Object,scope:i32) -> Value {
    g:=e.g
    tex,connected:=pin(e,o,"TextureObject",scope)
    if !connected {tex=texture_object(e,o,scope)}
    if tex==NONE {return untranslated(e,o,"it names no texture")}
    if mode:=prop_name(o,"MipValueMode","TMVM_None");mode!="TMVM_None" {
        note(e,"%s %s: its mip selection (%s) is left to Mirai's",object_class(o),object_name(o),mode)
    }
    uv,uv_connected:=pin(e,o,"Coordinates",scope)
    if !uv_connected {
        index:=prop_int(o,"ConstCoordinate",0)
        if index>1 {return untranslated(e,o,UV_SETS_PAST)}
        uv=uv_value(e,u32(index))
    }
    // Coordinates that failed upstream were counted there.
    if uv==NONE {return NO_VALUE}
    uv=convert(g,uv,2)
    // The sampler of the sample is that of this expression, also for a texture object input.
    if connected {
        ref:=g.textures[g.nodes[tex].index]
        ref.sampler=Sampler(prop_enum(o,"SamplerType",SAMPLER_NAMES,int(ref.sampler)))
        tex=texture(g,ref)
    }
    result:=sample(g,tex,uv)
    if result==NONE {return untranslated(e,o,"its coordinates are not two values")}
    return nodes(result)
}

// A scalar or vector of a Material Parameter Collection: its default value.
@(private)
collection_parameter :: proc(e:^Evaluator,o:Object) -> Value {
    reference:=prop_object(o,"Collection")
    collection,found:=object_resolve(e.lib,o.pkg,reference)
    if !found {return unread(e,o,reference,"collection")}
    name:=prop_name(o,"ParameterName","")
    p:=&collection.pkg.p
    for &item in prop_structs(collection,"ScalarParameters") {
        if strings.equal_fold(list_name(p,&item,"ParameterName"),name) {
            note(e,"collection parameter %s takes its default value",name)
            return nodes(scalar(e.g,list_float(p,&item,"DefaultValue",0)))
        }
    }
    for &item in prop_structs(collection,"VectorParameters") {
        if strings.equal_fold(list_name(p,&item,"ParameterName"),name) {
            note(e,"collection parameter %s takes its default value",name)
            return nodes(constant(e.g,list_vector(p,&item,"DefaultValue",{}),4))
        }
    }
    return untranslated(e,o,"its parameter is not in the collection")
}

@(private)
function_call :: proc(e:^Evaluator,o:Object,output:i32,scope:i32) -> Value {
    reference:=prop_object(o,"MaterialFunction")
    function,found:=object_resolve(e.lib,o.pkg,reference)
    if !found {return unread(e,o,reference,"function")}
    outputs:=prop_structs(o,"FunctionOutputs")
    if output<0 || int(output)>=len(outputs) {return untranslated(e,o,"the output it is read from does not exist")}
    p:=&o.pkg.p
    wanted,has_id:=list_guid(p,&outputs[output],"ExpressionOutputId")
    target:Object
    if has_id {
        for &item,index in function.pkg.p.exports {
            candidate:=Object{function.pkg,index}
            if item.outer!=unreal.Object_Ref(function.export+1) && !is_editor_data_of(function,item.outer) {continue}
            if !is_function_output(candidate) {continue}
            if id,ok:=prop_guid(candidate,"Id");ok && id==wanted {target=candidate;break}
        }
    }
    if target.pkg==nil {
        resolved,ok:=object_resolve(e.lib,o.pkg,list_object(p,&outputs[output],"ExpressionOutput"))
        if !ok {return untranslated(e,o,"the output of its function is missing")}
        target=resolved
    }
    // A function in a layer has the parameters of the layer.
    append(&e.scopes,Scope{call=o,parent=scope,layer=scope_layer(e,scope)})
    inner:=i32(len(e.scopes)-1)
    if value,adapted:=legacy_adapted(e,function,target,inner);adapted {return value}
    // A function called twice from the same place gives the same nodes.
    for &s,i in e.scopes[:inner] {
        if s.call==o && s.parent==scope {
            pop(&e.scopes)
            inner=i32(i)
            break
        }
    }
    return expression(e,target,0,inner)
}

// The outputs of a function: a layer has its own class of them.
@(private)
FUNCTION_OUTPUTS :: []string{"MaterialExpressionFunctionOutput","MaterialExpressionMaterialLayerOutput"}

@(private)
is_function_output :: proc(o:Object) -> bool {
    class:=object_class(o)
    for output in FUNCTION_OUTPUTS {if class==output {return true}}
    return false
}

// The expressions of a function of some classes (its inputs, its outputs),
// in the order Unreal gives them (SortPriority).
@(private)
function_expressions :: proc(function:Object,classes:[]string) -> []Object {
    found:=make([dynamic]Object,context.temp_allocator)
    for &item,index in function.pkg.p.exports {
        candidate:=Object{function.pkg,index}
        if item.outer!=unreal.Object_Ref(function.export+1) && !is_editor_data_of(function,item.outer) {continue}
        class:=object_class(candidate)
        for wanted in classes {if class==wanted {append(&found,candidate)}}
    }
    slice.stable_sort_by(found[:],proc(a,b:Object) -> bool {return prop_int(a,"SortPriority",0)<prop_int(b,"SortPriority",0)})
    return found[:]
}

// FMaterialLayersFunctions from its tagged struct: the layers, the blends
// and which layers are on (in UE5 in its editor-only data).
@(private)
layer_stack_read :: proc(pkg:^Opened,list:^unreal.Property_List,allocator:mem.Allocator) -> (stack:Layer_Stack,ok:bool) {
    p:=&pkg.p
    refs :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,allocator:mem.Allocator) -> []unreal.Object_Ref {
        found:=unreal.property_find(p,list,name)
        if found==nil {return nil}
        view,error:=unreal.property_array(p,found)
        if error.code!=.None {return nil}
        read,read_error:=unreal.array_object_refs(p,view,allocator)
        return read if read_error.code==.None else nil
    }
    states :: proc(p:^unreal.Package,list:^unreal.Property_List,allocator:mem.Allocator) -> []bool {
        found:=unreal.property_find(p,list,"LayerStates")
        if found==nil {return nil}
        view,error:=unreal.property_array(p,found)
        if error.code!=.None || i64(view.count)!=view.data.size {return nil}
        bytes,_:=unreal.span_bytes(p,view.data)
        out:=make([]bool,len(bytes),allocator)
        for b,i in bytes {out[i]=b!=0}
        return out
    }
    stack.pkg=pkg
    stack.layers=refs(p,list,"Layers",allocator)
    if stack.layers==nil {return}
    stack.blends=refs(p,list,"Blends",allocator)
    stack.states=states(p,list,allocator)
    if stack.states==nil {
        if editor:=unreal.property_find(p,list,"EditorOnly");editor!=nil {
            if inner,error:=unreal.property_tagged_struct(p,editor,true,context.temp_allocator);error.code==.None {stack.states=states(p,&inner,allocator)}
        }
    }
    return stack,true
}

// A stack of material layers (MaterialAttributeLayers): each layer that is
// on is its function with the parameters of that layer, the first one over
// the input of the expression, and each next one goes over what is below it
// by its blend; a layer without a blend covers it.
@(private)
material_layers :: proc(e:^Evaluator,o:Object,scope:i32) -> Value {
    stack:=e.stack
    if stack.pkg==nil {
        list,found:=prop_struct(o,"DefaultLayers")
        read,ok:=Layer_Stack{},false
        if found {read,ok=layer_stack_read(o.pkg,&list,e.overrides.allocator)}
        if !ok {return untranslated(e,o,"its layers could not be read")}
        stack=read
    }
    input:=pin_value(e,o,"Input",scope)
    result:=NO_VALUE
    for ref,i in stack.layers {
        if ref==0 || i<len(stack.states) && !stack.states[i] {continue}
        layer,ok:=layer_call(e,o,stack.pkg,ref,scope,{.Layer,i32(i)},{input,NO_VALUE})
        if !ok {return NO_VALUE}
        if result==NO_VALUE || i-1>=len(stack.blends) || stack.blends[i-1]==0 {
            result=layer
            continue
        }
        if result,ok=layer_call(e,o,stack.pkg,stack.blends[i-1],scope,{.Blend,i32(i-1)},{result,layer});!ok {return NO_VALUE}
    }
    if result==NO_VALUE {return input}
    return result
}

// The output of a layer or blend function (or function instance, whose
// values are those of the layer) in a scope of its own.
@(private)
layer_call :: proc(e:^Evaluator,o:Object,pkg:^Opened,ref:unreal.Object_Ref,scope:i32,layer:Layer_Ref,bound:[2]Value) -> (value:Value,ok:bool) {
    function,found:=object_resolve(e.lib,pkg,ref)
    for depth:=0;found && strings.contains(object_class(function),"Instance");depth+=1 {
        if depth>=MAX_CHAIN {break}
        forced:=layer
        parameter_values(function,&e.overrides,&forced,e.overrides.allocator)
        function,found=object_resolve(e.lib,function.pkg,prop_object(function,"Parent"))
    }
    if !found || strings.contains(object_class(function),"Instance") {return untranslated(e,o,"a function of its layers could not be read"),false}
    outputs:=function_expressions(function,FUNCTION_OUTPUTS)
    if len(outputs)==0 {return untranslated(e,o,"a function of its layers has no output"),false}
    append(&e.scopes,Scope{parent=scope,layer=layer,function=function,bound=bound})
    return expression(e,outputs[0],0,i32(len(e.scopes)-1)),true
}

// Engine functions that fake by the view what Mirai shades: their outputs
// as the modern equivalent gives them.
// - Parallax occlusion mapping offsets the coordinates to fake relief over a
//   flat surface: Mirai shades the surface it draws, at the coordinates it
//   is given, with no depth offset and no self-shadow.
// - Fuzzy shading darkens the core and brightens the edges of a cloth by the
//   view: the core is the color, and the edges are fibers over it (fuzz) of
//   that color and of the edge brightness as weight.
@(private)
legacy_adapted :: proc(e:^Evaluator,function,output:Object,scope:i32) -> (value:Value,adapted:bool) {
    g:=e.g
    switch object_path(function) {
    case "/Engine/Functions/Engine_MaterialFunctions01/Texturing/ParallaxOcclusionMapping.ParallaxOcclusionMapping",
         "/Engine/Functions/Engine_MaterialFunctions01/Texturing/ParallaxOcclusionMapping_BoundedUVs.ParallaxOcclusionMapping_BoundedUVs":
        switch prop_name(output,"OutputName","") {
        case "Parallax UVs":
            note(e,"parallax occlusion mapping: the surface is shaded where it is, without the relief")
            if uv,found:=function_input_named(e,function,"UVs",scope);found {return uv,true}
            return nodes(uv_value(e,0)),true
        case "Pixel Depth Offset":return nodes(scalar(g,0)),true
        case "Shadow":return nodes(scalar(g,1)),true
        case "World Position":return nodes(world_place(e,.World_Position)),true
        }
    case "/Engine/Functions/Engine_MaterialFunctions01/Shading/FuzzyShading.FuzzyShading":
        color,has_color:=function_input_named(e,function,"BaseColor",scope)
        core,has_core:=function_input_named(e,function,"CoreDarkness",scope)
        edge,has_edge:=function_input_named(e,function,"EdgeBrightness",scope)
        if !has_color || !has_core || !has_edge || color.node==NONE || core.node==NONE || edge.node==NONE {return}
        color.node=convert(g,color.node,3)
        e.fuzz={color.node,unary(g,.Saturate,convert(g,edge.node,1))}
        note(e,"fuzzy shading: its edges are fuzz over the surface")
        return nodes(binary(g,.Mul,color.node,binary(g,.Sub,scalar(g,1),convert(g,core.node,1)))),true
    }
    return
}

// The value of the input of a function named name, where it is called.
@(private)
function_input_named :: proc(e:^Evaluator,function:Object,name:string,scope:i32) -> (value:Value,found:bool) {
    for &item,index in function.pkg.p.exports {
        candidate:=Object{function.pkg,index}
        if item.outer!=unreal.Object_Ref(function.export+1) && !is_editor_data_of(function,item.outer) {continue}
        if object_class(candidate)=="MaterialExpressionFunctionInput" && prop_name(candidate,"InputName","")==name {
            return function_input(e,candidate,scope),true
        }
    }
    return
}

// Whether outer is the editor-only data of a function or material, which
// also owns expressions in UE5.
@(private)
is_editor_data_of :: proc(owner:Object,outer:unreal.Object_Ref) -> bool {
    if outer<=0 {return false}
    data:=Object{owner.pkg,int(outer)-1}
    return owner.pkg.p.exports[data.export].outer==unreal.Object_Ref(owner.export+1) && strings.has_suffix(object_class(data),"EditorOnlyData")
}

@(private)
FUNCTION_INPUT_TYPES :: []string{
    "FunctionInput_Scalar","FunctionInput_Vector2","FunctionInput_Vector3","FunctionInput_Vector4","FunctionInput_Texture2D",
    "FunctionInput_TextureCube","FunctionInput_Texture2DArray","FunctionInput_VolumeTexture","FunctionInput_StaticBool",
    "FunctionInput_MaterialAttributes","FunctionInput_TextureExternal","FunctionInput_Bool","FunctionInput_Substrate",
}

@(private)
function_input :: proc(e:^Evaluator,o:Object,scope:i32) -> Value {
    g:=e.g
    kind:=prop_enum(o,"InputType",FUNCTION_INPUT_TYPES,2)
    widths:=[13]u8{1,2,3,4,0,0,0,0,1,0,0,1,0}
    width:=widths[kind]
    MATERIAL_ATTRIBUTES :: 9
    // A layer takes the input of the stack in its first input of material
    // attributes; a blend, what is below in its Bottom and the layer in its
    // Top, or in its first two.
    if scope>=0 && e.scopes[scope].call.pkg==nil {
        s:=e.scopes[scope]
        if kind==MATERIAL_ATTRIBUTES {
            slot:=-1
            for candidate in function_expressions(s.function,[]string{"MaterialExpressionFunctionInput"}) {
                if prop_enum(candidate,"InputType",FUNCTION_INPUT_TYPES,2)!=MATERIAL_ATTRIBUTES {continue}
                slot+=1
                if candidate==o {break}
            }
            if s.layer.association==.Blend {
                switch prop_name(o,"BlendInputRelevance","") {
                case "Bottom":slot=0
                case "Top":slot=1
                }
            }
            if slot>=0 && slot<len(s.bound) && (s.bound[slot].node!=NONE || s.bound[slot].aggregate>=0) {return s.bound[slot]}
            // Nothing below the first layer, and no preview: the attributes as Unreal leaves them unconnected.
            if preview,connected:=prop_input(o,"Preview");!connected || preview.expression==0 {
                row:[Attribute]u32
                for &n,attribute in row {n=constant(g,ATTRIBUTE_DEFAULTS[attribute],ATTRIBUTE_WIDTHS[attribute])}
                append(&e.aggregates,row)
                return {NONE,i32(len(e.aggregates)-1)}
            }
        }
    } else if scope>=0 {
        s:=e.scopes[scope]
        id,has_id:=prop_guid(o,"Id")
        own_name:=prop_name(o,"InputName","")
        p:=&s.call.pkg.p
        items:=prop_structs(s.call,"FunctionInputs")
        // By the id of the input, the input itself, or else, for a call saved
        // against another version of the function, its name.
        chosen:=-1
        for pass in 0..<2 {
            for &item,index in items {
                if pass==0 {
                    if candidate,ok:=list_guid(p,&item,"ExpressionInputId");ok && has_id && candidate==id {chosen=index}
                    if chosen<0 {
                        resolved,ok:=object_resolve(e.lib,s.call.pkg,list_object(p,&item,"ExpressionInput"))
                        if ok && resolved==o {chosen=index}
                    }
                } else if found:=unreal.property_find(p,&item,"Input");found!=nil && own_name!="" {
                    if input,ok:=input_read(p,found);ok && input.name==own_name {chosen=index}
                }
                if chosen>=0 {break}
            }
            if chosen>=0 {break}
        }
        if chosen>=0 {
            if found:=unreal.property_find(p,&items[chosen],"Input");found!=nil {
                input,ok:=input_read(p,found)
                if ok && input.expression!=0 {
                    value:=input_value(e,s.call,input,s.parent)
                    if width>0 && value.node!=NONE {value.node=convert(g,value.node,width)}
                    return value
                }
            }
        }
    }
    // Not connected where it is called: its preview, or its preview value.
    if preview,connected:=prop_input(o,"Preview");connected && preview.expression!=0 {
        value:=input_value(e,o,preview,scope)
        if width>0 && value.node!=NONE {value.node=convert(g,value.node,width)}
        return value
    }
    if width==0 {return untranslated(e,o,"a texture or attributes input with nothing connected")}
    value:=prop_vector(o,"PreviewValue",{})
    if kind==8 || kind==11 {return nodes(scalar(g,value.x!=0?1:0))}
    return nodes(constant(g,value,width))
}

@(private)
break_output :: proc(e:^Evaluator,o:Object,output:i32) -> (Attribute,bool) {
    // The outputs of BreakMaterialAttributes, in its order; saves before
    // anisotropy (UE4 518) have neither Anisotropy nor Tangent. X: the
    // eight customized UVs and the shading model, which have no attribute.
    X :: Attribute(255)
    modern:=[]Attribute{.Base_Color,.Metallic,.Specular,.Roughness,.Anisotropy,.Emissive,.Opacity,.Opacity_Mask,.Normal,.Tangent,
        .World_Position_Offset,.Subsurface_Color,.Clear_Coat,.Clear_Coat_Roughness,.Ambient_Occlusion,.Refraction,
        X,X,X,X,X,X,X,X,.Pixel_Depth_Offset,X,.Displacement}
    older:=[]Attribute{.Base_Color,.Metallic,.Specular,.Roughness,.Emissive,.Opacity,.Opacity_Mask,.Normal,
        .World_Position_Offset,.Displacement,.Displacement,.Subsurface_Color,.Clear_Coat,.Clear_Coat_Roughness,.Ambient_Occlusion,.Refraction}
    order:=e.ue5 || o.pkg.p.summary.version_ue4>=518?modern:older
    if output<0 || int(output)>=len(order) || order[output]==X {return {},false}
    return order[output],true
}

@(private)
attribute_of :: proc(guid:unreal.Guid) -> (Attribute,bool) {
    for words,attribute in ATTRIBUTE_GUIDS {
        if unreal.guid_from_words(words)==guid {return attribute,true}
    }
    return {},false
}

@(private)
get_attributes :: proc(e:^Evaluator,o:Object,output:i32,scope:i32) -> Value {
    aggregate:=pin_value(e,o,"MaterialAttributes",scope)
    if output==0 {return aggregate}
    if aggregate.aggregate<0 {return untranslated(e,o,"its input is not material attributes")}
    p:=&o.pkg.p
    found:=property(o,"AttributeGetTypes")
    if found==nil {return untranslated(e,o,"it names no attributes")}
    view,error:=unreal.property_array(p,found)
    if error.code!=.None || i64(view.count)*16!=view.data.size || int(output)>int(view.count) {return untranslated(e,o,"its attributes could not be read")}
    bytes,_:=unreal.span_bytes(p,view.data)
    guid:unreal.Guid
    copy(guid[:],bytes[(int(output)-1)*16:])
    attribute,known:=attribute_of(guid)
    if !known {return untranslated(e,o,"an attribute Mirai has no value for")}
    return nodes(e.aggregates[aggregate.aggregate][attribute])
}

@(private)
set_attributes :: proc(e:^Evaluator,o:Object,scope:i32) -> Value {
    g:=e.g
    p:=&o.pkg.p
    // Inputs[0] is the attributes in; Inputs[i+1] sets AttributeSetTypes[i].
    elements:[]Input
    if inputs:=property(o,"Inputs");inputs!=nil {
        if view,error:=unreal.property_array(p,inputs);error.code==.None {elements=inputs_elements(p,view)}
    }
    row:[Attribute]u32
    for attribute in Attribute {row[attribute]=constant(g,ATTRIBUTE_DEFAULTS[attribute],ATTRIBUTE_WIDTHS[attribute])}
    if len(elements)>0 && elements[0].expression!=0 {
        base:=input_value(e,o,elements[0],scope)
        switch {
        case base.aggregate>=0:row=e.aggregates[base.aggregate]
        // A plain value is the base color, as Unreal's compatibility profile takes it.
        case base.node!=NONE:row[.Base_Color]=convert(g,base.node,3)
        // What failed upstream was counted there.
        case:return NO_VALUE
        }
    }
    if found:=property(o,"AttributeSetTypes");found!=nil {
        view,error:=unreal.property_array(p,found)
        if error.code==.None && i64(view.count)*16==view.data.size {
            bytes,_:=unreal.span_bytes(p,view.data)
            for i in 0..<int(view.count) {
                guid:unreal.Guid
                copy(guid[:],bytes[i*16:])
                attribute,known:=attribute_of(guid)
                if !known || i+1>=len(elements) {continue}
                if elements[i+1].expression==0 {continue}
                value:=input_value(e,o,elements[i+1],scope)
                row[attribute]=convert(g,value.node,ATTRIBUTE_WIDTHS[attribute])
            }
        }
    }
    append(&e.aggregates,row)
    return {NONE,i32(len(e.aggregates)-1)}
}

// The inputs of an array of FExpressionInput saved natively.
@(private)
inputs_elements :: proc(p:^unreal.Package,view:unreal.Array_View) -> []Input {
    out:=make([dynamic]Input,context.temp_allocator)
    at:=view.data.offset
    end:=view.data.offset+view.data.size
    for _ in 0..<view.count {
        element:=view.element
        // The size of a native element is not saved: the first size whose
        // input reads whole. One that reads at no size ends the array, so
        // the inputs before it keep their places.
        read:=false
        for size in ([]i64{36,32,40,44}) {
            if at+size>end {continue}
            element.data={at,size}
            if input,ok:=input_read(p,&element);ok {
                append(&out,input)
                at+=size
                read=true
                break
            }
        }
        if !read {break}
    }
    return out[:]
}
