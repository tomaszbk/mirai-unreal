package material

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "mirai:asset"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/base"

// The translation of an Unreal material or material instance to Mirai's
// model. A graph whose outputs are constants, and per-texel functions of
// textures that share their coordinates, is a Material_Info with maps: the
// images of the maps are what those functions give (the writer bakes them
// when they are not a texture as it is). Anything else (moving or
// world-space coordinates, two coordinates in one output, normal blends) is
// a Surface program written from the graph, with the parameters of the
// material as its parameters.

Error_Code :: enum u8 {None,Not_Found,Unsupported,Malformed}

// message lives in the temp allocator of the caller.
Error :: struct {code:Error_Code,message:string}

@(private)
error_make :: proc(code:Error_Code,format:string,args:..any) -> Error {
    return {code,fmt.aprintf(format,..args,allocator=context.temp_allocator)}
}

Options :: struct {
    layer:string, // the landscape layer whose branch is translated; "" the material as it shows its first layer
    custom_data:[]f32, // of the instance it shows (PerInstanceSMCustomData); none: what PerInstanceCustomData gives by default
    landscape:^Landscape_Mapping, // a landscape material whole, for the terrain that shows it; nil: per layer
    reads:[]Texture_Read, // the textures systems of the project write as they run, which a program reads instead
    writers:[]Virtual_Texture_Writer, // what writes each runtime virtual texture the material may sample
}

// The uv sets of a Mirai mesh (uv0 and uv1), and those an Unreal mesh holds.
UV_SETS :: 2
UNREAL_UV_SETS :: 8

Unreal_UV_Sets :: bit_set[0..<UNREAL_UV_SETS;u8]

// How the vertex colors of a mesh enter its material.
Vertex_Colors :: enum u8 {
    Unused,              // the material does not read them: a mesh drops them
    Multiply_Base_Color, // the standard model multiplies its base color by them
    Program,             // its program reads them as data (ctx.vertex_color)
}

// The image of one map: for each channel, the node of the graph whose value
// per texel it holds (NONE: 1). Its coordinates are those of the map in info.
Map_Image :: struct {channels:[4]u32}

MAP_NONE :: Map_Image{{NONE,NONE,NONE,NONE}}

// A parameter of the program, in the order of its Parameters struct.
Program_Parameter :: struct {
    name:string,       // the field: a Slang identifier
    source:string,     // the Unreal parameter, or the texture, it is
    kind:asset.Parameter_Kind,
    components:u8,
    value:[4]f32,
    texture:int,       // Texture: row of graph.textures
    piece:bool,        // given by each piece of the terrain that shows the material, not by the material
}

Program :: struct {
    name:string,   // "" for a material without one
    source:string, // the .slang file
    parameters:[]Program_Parameter,
}

Translated_Material :: struct {
    name:string,     // of the Unreal object
    path:string,     // its object path
    material:string, // the name of the Material at the root of its chain
    info:asset.Material_Info, // the maps have no textures: those are images
    images:[asset.Material_Map_Kind]Map_Image,
    graph:Graph,
    program:Program,
    vertex_colors:Vertex_Colors,
    // The Unreal uv sets it reads, which the mesh holds in its own uv sets
    // lowest first (uv_set_sources): the graph reads them there.
    uv_sets:Unreal_UV_Sets,
    uv_sets_past:Unreal_UV_Sets, // those it reads past the UV_SETS of the mesh: not translated
    layers:[]string,             // the landscape layers the graph names
    untranslated:[]Untranslated, // expressions that could not be translated, by class
    notes:[]string,              // what was left out or approximated, and why
    missing:[]string,            // the object paths of functions and collections it reads that no mount holds
    reads_custom_data:bool,      // PerInstanceCustomData reaches an output: each instance can show another value
    arena:^mem.Dynamic_Arena,
    allocator:mem.Allocator,
}

translated_destroy :: proc(t:^Translated_Material) {
    if t.arena!=nil {
        arena,allocator:=t.arena,t.arena.block_allocator
        mem.dynamic_arena_destroy(arena)
        free(arena,allocator)
    }
    t^={}
}

// Whether the material is the standard model alone.
translated_is_standard :: proc(t:^Translated_Material) -> bool {return t.program.name==""}

@(private)
BLEND_NAMES :: []string{"BLEND_Opaque","BLEND_Masked","BLEND_Translucent","BLEND_Additive","BLEND_Modulate","BLEND_AlphaComposite","BLEND_AlphaHoldout","BLEND_TranslucentColoredTransmittance"}
@(private)
Blend :: enum u8 {Opaque,Masked,Translucent,Additive,Modulate,Alpha_Composite,Alpha_Holdout,Colored_Transmittance}
@(private)
SHADING_NAMES :: []string{
    "MSM_Unlit","MSM_DefaultLit","MSM_Subsurface","MSM_PreintegratedSkin","MSM_ClearCoat","MSM_SubsurfaceProfile",
    "MSM_TwoSidedFoliage","MSM_Hair","MSM_Cloth","MSM_Eye","MSM_SingleLayerWater","MSM_ThinTranslucent","MSM_Strata","MSM_FromMaterialExpression",
}
@(private)
Shading :: enum u8 {Unlit,Default_Lit,Subsurface,Preintegrated_Skin,Clear_Coat,Subsurface_Profile,Two_Sided_Foliage,Hair,Cloth,Eye,Single_Layer_Water,Thin_Translucent,Substrate,From_Expression}

@(private)
Base_Properties :: struct {
    blend:Blend,
    shading:Shading,
    clip:f32,
    two_sided:bool,
    blend_set,shading_set,clip_set,two_sided_set:bool,
}

@(private)
MAX_CHAIN :: 32

// Translates a material or material instance (an export of class Material
// or MaterialInstanceConstant).
translate :: proc(lib:^Library,material:Object,options:Options={},allocator:=context.allocator) -> (t:Translated_Material,error:Error) {
    if !object_valid(material) {return {},error_make(.Not_Found,"the material does not exist")}
    arena:=new(mem.Dynamic_Arena,allocator)
    mem.dynamic_arena_init(arena,allocator,allocator,block_size=1<<16,out_band_size=1<<16)
    t.arena=arena
    t.allocator=base.dynamic_arena_allocator(arena)
    out:=t.allocator
    t.name=strings.clone(object_name(material),out)
    t.path=strings.clone(object_path(material),out)
    t.info=asset.MATERIAL_DEFAULTS
    for &image in t.images {image=MAP_NONE}
    graph_init(&t.graph,out)

    chain,chain_error:=chain_read(lib,material,out)
    if chain_error.code!=.None {
        translated_destroy(&t)
        return {},chain_error
    }
    base,base_material:=chain.base,chain.material
    t.material=strings.clone(object_name(base_material),out)
    domain:=prop_name(base_material,"MaterialDomain","MD_Surface")
    if domain!="MD_Surface" {
        translated_destroy(&t)
        return {},error_make(.Unsupported,"%s: the domain %s is not a surface; Mirai surface materials only",object_path(base_material),domain)
    }
    blend:=base.blend_set?base.blend:Blend(prop_enum(base_material,"BlendMode",BLEND_NAMES,0))
    shading:=base.shading_set?base.shading:Shading(prop_enum(base_material,"ShadingModel",SHADING_NAMES,1))
    clip:=base.clip_set?base.clip:prop_float(base_material,"OpacityMaskClipValue",0.3333)
    // A two-sided material is drawn on single sheets: a thin surface.
    thin:=base.two_sided_set?base.two_sided:prop_bool(base_material,"TwoSided",false)

    e:Evaluator
    evaluator_init(&e,lib,&t.graph,out)
    e.overrides=chain.overrides
    e.stack=chain.stack
    e.layer=options.layer
    e.custom_data=options.custom_data
    e.landscape=options.landscape
    if options.landscape!=nil {e.coordinates=&options.landscape.coordinates}
    e.reads=options.reads
    e.writers=options.writers
    e.material=t.path
    e.ue5=base_material.pkg.p.summary.version_ue5>0

    // The inputs: on the material in UE4, on its editor-only data in UE5.
    inputs:=base_material
    if data,found:=object_child(base_material,"MaterialEditorOnlyData");found {inputs=data}
    roots:[Attribute]u32
    connected:[Attribute]bool
    // Two passes: the first finds the landscape layers, so that without a
    // branch the first layer is the one shown.
    for pass in 0..<2 {
        if pass==1 {
            if len(e.layers)==0 {break}
            clear(&e.memo)
            clear(&e.aggregates)
        }
        roots,connected=material_outputs(&e,base_material,inputs,outputs_read(blend,shading),-1)
    }
    t.layers=e.layers[:]
    if options.layer!="" {
        known:=false
        for name in e.layers {known||=strings.equal_fold(name,options.layer)}
        if !known {
            translated_destroy(&t)
            return {},error_make(.Not_Found,"%s has no landscape layer %s",object_path(material),options.layer)
        }
    } else if len(e.layers)>0 && options.landscape==nil {
        note(&e,"landscape material shown as its layer %s; each layer is a material of its own (landscape_layers)",e.layers[0])
    }

    uv_sets_place(&t,&e,roots)
    translate_values(&t,&e,roots,connected,blend,shading,clip,thin)
    untranslated:=make([dynamic]Untranslated,out)
    untranslated_counts(&e,&untranslated)
    t.untranslated=untranslated[:]
    t.notes=e.notes[:]
    t.missing=e.missing[:]
    t.reads_custom_data=e.reads_custom_data
    return t,{}
}

// The Unreal uv set of each uv set of the mesh, as uv_sets holds them:
// lowest first; -1 for one that holds none.
uv_set_sources :: proc(sets:Unreal_UV_Sets) -> (sources:[UV_SETS]i32) {
    sources={-1,-1}
    slot:=0
    for set in 0..<UNREAL_UV_SETS {
        if set not_in sets {continue}
        sources[slot]=i32(set)
        slot+=1
    }
    return
}

// Moves the Unreal uv sets the outputs read to the uv sets of the mesh that
// hold them: the graph reads uv0 and uv1 from here on.
@(private)
uv_sets_place :: proc(t:^Translated_Material,e:^Evaluator,roots:[Attribute]u32) {
    g:=&t.graph
    read:=make([dynamic]u32,context.temp_allocator)
    for root in roots {append(&read,root)}
    append(&read,..e.fuzz[:])
    append(&read,..e.diffuse_transmission[:])
    for n in nodes_under(g,read[:]) {
        if g.nodes[n].op==.UV && int(g.nodes[n].index) in e.uv_sets {t.uv_sets+={int(g.nodes[n].index)}}
    }
    t.uv_sets_past=e.uv_sets_past
    sources:=uv_set_sources(t.uv_sets)
    for &node in g.nodes {
        if node.op!=.UV {continue}
        for source,slot in sources {
            if source==i32(node.index) {node.index=u32(slot);break}
        }
    }
    clear(&g.lookup)
    for node,row in g.nodes {
        if node not_in g.lookup {g.lookup[node]=u32(row)}
    }
}

// The chain of instances down to the material: the values the closest
// instance sets first, and the material at its root.
@(private)
Chain :: struct {overrides:[dynamic]Override,base:Base_Properties,stack:Layer_Stack,material:Object}

@(private)
chain_read :: proc(lib:^Library,material:Object,out:mem.Allocator) -> (c:Chain,error:Error) {
    c.overrides=make([dynamic]Override,out)
    current:=material
    for depth:=0;;depth+=1 {
        class:=object_class(current)
        if class=="Material" {break}
        if !strings.has_prefix(class,"MaterialInstance") {
            return c,error_make(.Unsupported,"%s is a %s, not a material",object_path(current),class)
        }
        if depth>=MAX_CHAIN {
            return c,error_make(.Malformed,"%s: the chain of parents is longer than %d",object_path(material),MAX_CHAIN)
        }
        instance_overrides(current,&c.overrides,&c.base,&c.stack,out)
        reference:=prop_object(current,"Parent")
        parent,found:=object_resolve(lib,current.pkg,reference)
        if !found {
            parent_path,_:=unreal.reference_path(&current.pkg.p,reference,context.temp_allocator)
            return c,error_make(.Not_Found,"%s: its parent %s could not be read",object_path(current),parent_path)
        }
        current=parent
    }
    c.material=current
    return
}

@(private)
instance_overrides :: proc(o:Object,overrides:^[dynamic]Override,base:^Base_Properties,stack:^Layer_Stack,out:mem.Allocator) {
    p:=&o.pkg.p
    parameter_values(o,overrides,nil,out)
    statics:=[2]Object{o,{}}
    if data,found:=object_child(o,"MaterialInstanceEditorOnlyData");found {statics[1]=data}
    for owner in statics {
        if owner.pkg==nil {continue}
        for set_name in ([]string{"StaticParameters","StaticParametersRuntime","StaticParameters_DEPRECATED"}) {
            set,found:=prop_struct(owner,set_name)
            if !found {continue}
            q:=&owner.pkg.p
            static_entries(q,&set,"StaticSwitchParameters",.Switch,overrides,out)
            static_entries(q,&set,"StaticSwitchParameters_DEPRECATED",.Switch,overrides,out)
            static_entries(q,&set,"StaticComponentMaskParameters",.Mask,overrides,out)
            // The stack of material layers the closest instance sets.
            if stack.pkg==nil {
                if layers:=unreal.property_find(q,&set,"MaterialLayers");layers!=nil {
                    if list,error:=unreal.property_tagged_struct(q,layers,true,context.temp_allocator);error.code==.None {
                        if read,ok:=layer_stack_read(owner.pkg,&list,out);ok {stack^=read}
                    }
                }
            }
        }
    }
    if overrides_set,found:=prop_struct(o,"BasePropertyOverrides");found {
        if !base.blend_set && list_bool(p,&overrides_set,"bOverride_BlendMode",false) {
            base.blend_set=true
            base.blend=Blend(list_enum(p,&overrides_set,"BlendMode",BLEND_NAMES))
        }
        if !base.shading_set && list_bool(p,&overrides_set,"bOverride_ShadingModel",false) {
            base.shading_set=true
            base.shading=Shading(list_enum(p,&overrides_set,"ShadingModel",SHADING_NAMES))
        }
        if !base.clip_set && list_bool(p,&overrides_set,"bOverride_OpacityMaskClipValue",false) {
            base.clip_set=true
            base.clip=list_float(p,&overrides_set,"OpacityMaskClipValue",0.3333)
        }
        if !base.two_sided_set && list_bool(p,&overrides_set,"bOverride_TwoSided",false) {
            base.two_sided_set=true
            base.two_sided=list_bool(p,&overrides_set,"TwoSided",false)
        }
    }
}

@(private)
list_enum :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,names:[]string) -> int {
    text:=list_name(p,list,name)
    for candidate,index in names {if strings.equal_fold(candidate,text) {return index}}
    if found:=unreal.property_find(p,list,name);found!=nil {
        value,error:=unreal.property_value(p,found,context.temp_allocator)
        if error.code==.None && value.kind==.Unsigned && value.unsigned<u64(len(names)) {return int(value.unsigned)}
    }
    return 0
}

// The scalar, vector and texture parameter values of an instance, of a
// material or of a function; those of a function instance used as a layer
// or blend are of that layer (forced).
@(private)
parameter_values :: proc(o:Object,overrides:^[dynamic]Override,forced:^Layer_Ref,out:mem.Allocator) {
    p:=&o.pkg.p
    // A vector of doubles is a vector parameter as floats.
    arrays:=[5]string{"ScalarParameterValues","VectorParameterValues","TextureParameterValues","DoubleVectorParameterValues","RuntimeVirtualTextureParameterValues"}
    kinds:=[5]Override_Kind{.Scalar,.Vector,.Texture,.Vector,.Texture}
    for array,i in arrays {
        for &item in prop_structs(o,array) {
            name,layer,ok:=list_parameter(p,&item)
            if !ok || name=="" {continue}
            if forced!=nil {layer=forced^}
            entry:=Override{name=strings.clone(name,out),kind=kinds[i],layer=layer}
            switch entry.kind {
            case .Scalar:entry.value={list_float(p,&item,"ParameterValue",0),0,0,0}
            case .Vector:entry.value=list_vector(p,&item,"ParameterValue",{})
            case .Texture:
                reference:=list_object(p,&item,"ParameterValue")
                if reference==0 {continue}
                path,error:=unreal.reference_path(p,reference,out)
                if error.code!=.None {continue}
                entry.texture=path
            case .Switch,.Mask:
            }
            append(overrides,entry)
        }
    }
}

@(private)
static_entries :: proc(p:^unreal.Package,set:^unreal.Property_List,name:string,kind:Override_Kind,overrides:^[dynamic]Override,out:mem.Allocator) {
    found:=unreal.property_find(p,set,name)
    if found==nil {return}
    view,error:=unreal.property_array(p,found)
    if error.code!=.None {return}
    array,array_error:=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
    if array_error.code!=.None {return}
    for &item in array.items {
        if !list_bool(p,&item,"bOverride",false) {continue}
        parameter,layer,ok:=list_parameter(p,&item)
        if !ok || parameter=="" {continue}
        value:[4]f32
        if kind==.Switch {
            value.x=list_bool(p,&item,"Value",false)?1:0
        } else {
            value={list_bool(p,&item,"R",false)?1:0,list_bool(p,&item,"G",false)?1:0,list_bool(p,&item,"B",false)?1:0,list_bool(p,&item,"A",false)?1:0}
        }
        append(overrides,Override{name=strings.clone(parameter,out),kind=kind,value=value,layer=layer})
    }
}

// The outputs a translation reads for a blend mode and shading model: what
// is not read is not evaluated, nor counted when it cannot be translated.
@(private)
outputs_read :: proc(blend:Blend,shading:Shading) -> (wanted:bit_set[Attribute]) {
    wanted={.Base_Color,.Emissive}
    if shading!=.Unlit {wanted+={.Metallic,.Specular,.Roughness,.Normal,.Ambient_Occlusion}}
    #partial switch blend {
    case .Masked:wanted+={.Opacity_Mask}
    case .Translucent,.Alpha_Composite,.Colored_Transmittance,.Modulate,.Alpha_Holdout:wanted+={.Opacity,.Refraction}
    }
    #partial switch shading {
    case .Clear_Coat:wanted+={.Clear_Coat,.Clear_Coat_Roughness}
    case .Cloth:wanted+={.Clear_Coat,.Subsurface_Color}
    case .Subsurface,.Preintegrated_Skin,.Two_Sided_Foliage:wanted+={.Subsurface_Color}
    }
    return
}

// Whether an offset Mirai does not translate is minus the world position:
// WorldPosition times -1.
@(private)
offset_collapses :: proc(e:^Evaluator,o:Object,input:Input) -> bool {
    target,found:=object_resolve(e.lib,o.pkg,input.expression)
    if !found || object_class(target)!="MaterialExpressionMultiply" {return false}
    for side in ([2][2]string{{"A","ConstB"},{"B","ConstA"}}) {
        position,connected:=prop_input(target,side[0])
        if !connected || position.expression==0 {continue}
        source,resolved:=object_resolve(e.lib,target.pkg,position.expression)
        if !resolved || object_class(source)!="MaterialExpressionWorldPosition" {continue}
        other,other_connected:=prop_input(target,side[0]=="A"?"B":"A")
        if other_connected && other.expression!=0 {continue}
        return prop_float(target,side[1],1)==-1
    }
    return false
}

// The node of each output of the material and whether it is connected.
@(private)
material_outputs :: proc(e:^Evaluator,material,inputs:Object,wanted:bit_set[Attribute],scope:i32) -> (roots:[Attribute]u32,connected:[Attribute]bool) {
    g:=e.g
    for &root,attribute in roots {root=constant(g,ATTRIBUTE_DEFAULTS[attribute],ATTRIBUTE_WIDTHS[attribute])}
    if prop_bool(material,"bUseMaterialAttributes",false) {
        value:=pin_value(e,inputs,"MaterialAttributes",scope)
        if value.aggregate<0 {
            note(e,"its material attributes could not be translated")
            for &c in connected {c=true}
            for &root in roots {root=NONE}
            return
        }
        for attribute in Attribute {
            roots[attribute]=e.aggregates[value.aggregate][attribute]
            connected[attribute]=true
        }
        return
    }
    for name,attribute in ATTRIBUTE_NAMES {
        input,found:=prop_input(inputs,name)
        if !found {continue}
        width:=ATTRIBUTE_WIDTHS[attribute]
        if input.expression!=0 {
            connected[attribute]=true
            if attribute in wanted {roots[attribute]=convert(g,input_value(e,inputs,input,scope).node,width)}
            if attribute==.World_Position_Offset && offset_collapses(e,inputs,input) {
                roots[attribute]=binary(g,.Mul,context_value(g,.World_Position,3),scalar(g,-1))
            }
        } else if input.use_constant {
            roots[attribute]=constant(g,input.constant,width)
        }
    }
    return
}

// What a map of the standard model is made of: a constant factor, and the
// per-texel part, all of whose samples read one coordinate node.
@(private)
Map_Form :: struct {
    factor:[4]f32,
    image:u32,   // NONE: the factor alone
    uv:u32,      // the coordinates the samples of image read
}

// The forms of the outputs of the standard model, or false when an output
// needs a program.
@(private)
map_form :: proc(g:^Graph,n:u32) -> (form:Map_Form,ok:bool) {
    if n==NONE {return}
    if value,constant_ok:=evaluate_constant(g,n);constant_ok {
        return {factor=value,image=NONE,uv=NONE},true
    }
    uv:=NONE
    if !samples_share_uv(g,n,&uv) {return}
    factor,rest:=split_factor(g,n)
    return {factor=factor,image=rest,uv=uv},true
}

// Whether every context value under n is the coordinates of a sample, all
// samples read the same coordinates and nothing under n needs a program.
@(private)
samples_share_uv :: proc(g:^Graph,n:u32,uv:^u32) -> bool {
    for m in nodes_under(g,{n},{.Sample}) {
        node:=&g.nodes[m]
        if node.op==.Sample {
            if uv^==NONE {uv^=node.args[1]}
            if uv^!=node.args[1] {return false}
        } else if node.op in PROGRAM {
            return false
        }
    }
    return true
}

// n as a constant factor times the rest: the factors of products are
// taken out, a scalar one repeated in each component.
@(private)
split_factor :: proc(g:^Graph,n:u32) -> (factor:[4]f32,rest:u32) {
    node:=g.nodes[n]
    if value,ok:=evaluate_constant(g,n);ok {
        if node.width==1 {return {value.x,value.x,value.x,value.x},NONE}
        return value,NONE
    }
    if node.op==.Mul {
        fa,ra:=split_factor(g,node.args[0])
        fb,rb:=split_factor(g,node.args[1])
        factor=fa*fb
        switch {
        case ra==NONE:rest=rb
        case rb==NONE:rest=ra
        case:rest=binary(g,.Mul,ra,rb)
        }
        if rest!=NONE && g.nodes[rest].width<node.width {rest=convert(g,rest,node.width)}
        return
    }
    return {1,1,1,1},n
}

// The coordinates of a map from a node: an affine function of a uv set,
// uv·scale + offset, whatever order its products and sums come in.
@(private)
uv_transform :: proc(g:^Graph,n:u32) -> (m:asset.Material_Map,ok:bool) {
    m=asset.MATERIAL_MAP_DEFAULT
    scale,offset,set,affine:=uv_affine(g,n)
    if !affine {return}
    m.scale,m.offset,m.uv_set=scale,offset,set
    return m,true
}

@(private)
uv_affine :: proc(g:^Graph,n:u32) -> (scale,offset:[2]f32,set:u32,ok:bool) {
    if n==NONE {return}
    node:=g.nodes[n]
    #partial switch node.op {
    case .UV:return {1,1},{0,0},node.index,true
    case .Add,.Mul,.Sub:
        for side in 0..<2 {
            value,constant_ok:=evaluate_constant(g,node.args[1-side])
            if !constant_ok {continue}
            if node.op==.Sub && side==1 {return}
            c:=width_of(g,node.args[1-side])==1?[2]f32{value.x,value.x}:value.xy
            scale,offset,set,ok=uv_affine(g,node.args[side])
            if !ok {return}
            #partial switch node.op {
            case .Add:offset+=c
            case .Sub:offset-=c
            case .Mul:scale*=c;offset*=c
            }
            return
        }
    }
    return
}

@(private)
translate_values :: proc(t:^Translated_Material,e:^Evaluator,roots:[Attribute]u32,connected:[Attribute]bool,blend:Blend,shading:Shading,clip:f32,thin:bool) {
    g:=&t.graph
    info:=&t.info
    if e.exposure_relative {info.emission_mode=.Relative}
    switch blend {
    case .Opaque:
    case .Masked:info.alpha_mode=.Mask;info.alpha_cutoff=clamp(clip,0,1)
    case .Translucent,.Alpha_Composite,.Colored_Transmittance:info.alpha_mode=.Blend
    case .Additive:
        info.alpha_mode=.Blend
        note(e,"additive blending is taken as a layer that covers nothing and adds its light")
    case .Modulate,.Alpha_Holdout:
        info.alpha_mode=.Blend
        note(e,"blend mode %v has no Mirai equivalent; it is drawn as a blended layer",blend)
    }
    // An offset of minus the world position takes every point to the origin:
    // Unreal draws nothing of the surface, which still makes distance fields.
    collapsed:=false
    if connected[.World_Position_Offset] && roots[.World_Position_Offset]!=NONE {
        factor,rest:=split_factor(g,roots[.World_Position_Offset])
        collapsed=rest!=NONE && g.nodes[rest].op==.World_Position && factor.xyz==[3]f32{-1,-1,-1}
    }
    if collapsed {
        info.alpha_mode,info.alpha_cutoff=.Mask,0.5
        note(e,"WorldPositionOffset takes every point to the origin: the surface is not drawn")
    }
    for attribute in ([]Attribute{.World_Position_Offset,.Pixel_Depth_Offset,.Tangent,.Displacement}) {
        if connected[attribute] && !(collapsed && attribute==.World_Position_Offset) {note(e,"%s is not translated: Mirai materials do not move or deform the surface",ATTRIBUTE_NAMES[attribute])}
    }
    switch shading {
    case .Default_Lit,.Unlit,.Clear_Coat,.Cloth:
    case .Subsurface,.Preintegrated_Skin,.Two_Sided_Foliage:
        if thin || shading==.Two_Sided_Foliage {
            note(e,"shading model %v on a thin surface: the light it scatters through is diffuse transmission",shading)
        } else {
            note(e,"shading model %v: Mirai has no volume scattering; the surface is lit as opaque, with the light it scatters as diffuse reflection",shading)
        }
    case .Subsurface_Profile:
        note(e,"shading model %v: Mirai has no volume scattering; the surface is lit as opaque",shading)
    case .Hair,.Eye,.Single_Layer_Water,.Thin_Translucent,.Substrate,.From_Expression:
        note(e,"shading model %v is lit as the standard model",shading)
    }

    scattered:=roots[.Subsurface_Color]
    roots:=roots
    for &root,a in roots {
        if connected[a] && root==NONE {
            note(e,"%s could not be translated; it keeps the value Unreal gives it unconnected",ATTRIBUTE_NAMES[a])
            root=constant(g,ATTRIBUTE_DEFAULTS[a],ATTRIBUTE_WIDTHS[a])
        }
    }

    // The standard model multiplies the base color by the vertex colors, so
    // those that multiply it are taken out of it; a program reads them as
    // data, so its base color keeps them.
    stripped,colors:=strip_vertex_color(g,roots[.Base_Color])
    base_color:=base_color_lit(e,stripped,scattered,roots,shading,thin)
    with_colors:=base_color
    if colors==.Multiply_Base_Color {with_colors=NONE}

    alpha_root:=NONE
    if info.alpha_mode==.Mask {alpha_root=roots[.Opacity_Mask]}
    if info.alpha_mode==.Blend {alpha_root=roots[.Opacity]}
    if blend==.Additive || collapsed {alpha_root=scalar(g,0)}

    emissive:=roots[.Emissive]
    metallic,roughness,specular,occlusion,normal:=roots[.Metallic],roots[.Roughness],roots[.Specular],roots[.Ambient_Occlusion],roots[.Normal]
    if shading==.Unlit {
        metallic,roughness,specular,occlusion,normal=NONE,NONE,NONE,NONE,NONE
        info.unlit=true
    }
    if standard_model(t,e,base_color,alpha_root,metallic,roughness,specular,occlusion,emissive,normal,roots,shading) {
        t.vertex_colors=colors
        return
    }
    if with_colors==NONE {with_colors=base_color_lit(e,roots[.Base_Color],scattered,roots,shading,thin)}
    program_build(t,e,with_colors,alpha_root,metallic,roughness,specular,occlusion,emissive,normal,roots,shading)
}

// The base color as Mirai lights it: lit as opaque, the light Unreal
// scatters back from under the surface by SubsurfaceColor is diffuse
// reflection, the albedo that reflects as much toward a light at normal
// incidence added to the base color; a thin surface lets it through.
@(private)
base_color_lit :: proc(e:^Evaluator,base,scattered:u32,roots:[Attribute]u32,shading:Shading,thin:bool) -> u32 {
    g:=e.g
    base_color:=base
    transmits:=shading==.Two_Sided_Foliage || thin && (shading==.Subsurface || shading==.Preintegrated_Skin)
    if !transmits && (shading==.Subsurface || shading==.Preintegrated_Skin) && scattered!=NONE {
        if base_color==NONE {base_color=constant(g,ATTRIBUTE_DEFAULTS[.Base_Color],3)}
        albedo:=convert(g,scattered,3)
        if shading==.Subsurface {albedo=binary(g,.Mul,albedo,scalar(g,SUBSURFACE_BACKSCATTER))}
        base_color=unary(g,.Saturate,binary(g,.Add,convert(g,base_color,3),albedo))
    }
    if transmits {
        if base_color==NONE {base_color=constant(g,ATTRIBUTE_DEFAULTS[.Base_Color],3)}
        // Unreal reflects the base color and adds the light SubsurfaceColor
        // (its default where it is not connected) sends through from behind.
        base_color=diffuse_transmission_split(e,convert(g,base_color,3),convert(g,roots[.Subsurface_Color],3))
    }
    return base_color
}

// base * vertex color, as base and whether the vertex colors were there.
@(private)
strip_vertex_color :: proc(g:^Graph,n:u32) -> (rest:u32,colors:Vertex_Colors) {
    if n==NONE {return}
    node:=g.nodes[n]
    is_color :: proc(g:^Graph,n:u32) -> bool {
        node:=g.nodes[n]
        if node.op==.Vertex_Color {return true}
        if node.op==.Swizzle && g.nodes[node.args[0]].op==.Vertex_Color {return node.swizzle[0]==0 && node.swizzle[1]==1 && node.swizzle[2]==2}
        return false
    }
    if node.op==.Mul {
        if is_color(g,node.args[0]) {return convert(g,node.args[1],3),.Multiply_Base_Color}
        if is_color(g,node.args[1]) {return convert(g,node.args[0],3),.Multiply_Base_Color}
    }
    if is_color(g,n) {return constant(g,{1,1,1,0},3),.Multiply_Base_Color}
    return n,.Unused
}

// Unreal's Specular s gives F0 = 0.08·s and F90 = min(1, 50·F0): an IOR
// with the same F0 while F0 reaches 2%, and below it the IOR of 2% with a
// specular factor that scales F0 and F90 down together.
specular_ior :: proc(s:f32) -> (ior,factor:f32) {
    f0:=0.08*clamp(s,0,1)
    if f0>=0.02 {
        r:=math.sqrt(f0)
        return (1+r)/(1-r),1
    }
    r:=math.sqrt(f32(0.02))
    return (1+r)/(1-r),f0/0.02
}

// Why the standard model cannot hold the material, for its notes.
@(private)
refuse :: proc(e:^Evaluator,what:string) -> bool {
    note(e,"needs a program: the standard model cannot hold %s",what)
    return false
}

// Of a base color b that Unreal reflects and a color s it sends through, the
// diffuse transmission of the same light: the weight is the share of s of
// the two, max(s) / (max(s) + max(b)), the base reflects b and the
// transmission lets s through out of what each keeps of the weight, and both
// scale down to the light the surface gets where Unreal adds up to more.
// The base color that reflects b.
@(private)
diffuse_transmission_split :: proc(e:^Evaluator,b,s:u32) -> u32 {
    g:=e.g
    brightest :: proc(g:^Graph,c:u32) -> u32 {return binary(g,.Max,binary(g,.Max,component(g,c,0),component(g,c,1)),component(g,c,2))}
    mb,ms:=brightest(g,b),brightest(g,s)
    total:=binary(g,.Add,mb,ms)
    weight:=binary(g,.Div,ms,binary(g,.Max,total,scalar(g,MIN_SHARE)))
    scale:=binary(g,.Div,scalar(g,1),binary(g,.Max,total,scalar(g,1)))
    reflected:=binary(g,.Mul,b,binary(g,.Div,scale,binary(g,.Max,binary(g,.Sub,scalar(g,1),weight),scalar(g,MIN_SHARE))))
    through:=binary(g,.Mul,s,binary(g,.Div,scale,binary(g,.Max,weight,scalar(g,MIN_SHARE))))
    e.diffuse_transmission={unary(g,.Saturate,through),weight}
    return unary(g,.Saturate,reflected)
}

// Below this share a division above has nothing to scale: the other part is all there is.
@(private)
MIN_SHARE :: f32(1e-6)

// The share of SubsurfaceColor that SubsurfaceBxDF scatters back at normal
// incidence, as an albedo: its back scatter, 1/(2π), against a Lambert's 1/π.
// PreintegratedSkinBxDF returns from its table at least what a white Lambert
// does there, so its SubsurfaceColor adds whole, up to white.
SUBSURFACE_BACKSCATTER :: f32(0.5)

// The IOR whose F0 is 0.08, Unreal's Specular 1: a textured specular is a
// map that scales it.
@(private)
SPECULAR_FULL_IOR :: 1.7888544

@(private)
standard_model :: proc(t:^Translated_Material,e:^Evaluator,base_color,alpha,metallic,roughness,specular,occlusion,emissive,normal:u32,roots:[Attribute]u32,shading:Shading) -> bool {
    g:=&t.graph
    info:=&t.info
    maps:=asset.material_maps(&info.maps)
    base,base_ok:=map_form(g,base_color)
    if !base_ok {return refuse(e,"the base color")}
    alpha_form:=Map_Form{factor={1,1,1,1},image=NONE,uv=NONE}
    if alpha!=NONE {
        ok:bool
        alpha_form,ok=map_form(g,alpha)
        if !ok {return refuse(e,"the opacity")}
    }
    // Color and opacity share the base color map.
    if base.image!=NONE || alpha_form.image!=NONE {
        uv:=base.image!=NONE?base.uv:alpha_form.uv
        if base.image!=NONE && alpha_form.image!=NONE && base.uv!=alpha_form.uv {return refuse(e,"color and opacity read different coordinates")}
        transform,ok:=uv_transform(g,uv)
        if !ok {return refuse(e,"the coordinates of the base color")}
        maps[.Base_Color]=transform
        image:=MAP_NONE
        if base.image!=NONE {
            for c in 0..<3 {image.channels[c]=component(g,convert(g,base.image,3),u8(c))}
        }
        if alpha_form.image!=NONE {image.channels[3]=convert(g,alpha_form.image,1)}
        t.images[.Base_Color]=image
    }
    info.base_color={max(base.factor.x,0),max(base.factor.y,0),max(base.factor.z,0)}
    if alpha!=NONE {info.opacity=clamp(alpha_form.factor.x,0,1)}

    // Metallic, roughness and occlusion share an image where they share coordinates.
    forms:[3]Map_Form
    roots_mro:=[3]u32{occlusion,roughness,metallic}
    for root,i in roots_mro {
        if root==NONE {forms[i]={factor={1,1,1,1},image=NONE,uv=NONE};continue}
        ok:bool
        forms[i],ok=map_form(g,root)
        if !ok {return refuse(e,"metallic, roughness or occlusion")}
    }
    if forms[1].image!=NONE && forms[2].image!=NONE && forms[1].uv!=forms[2].uv {return refuse(e,"metallic and roughness read different coordinates")}
    mr_uv:=forms[1].image!=NONE?forms[1].uv:forms[2].uv
    if roughness!=NONE {info.roughness=clamp(forms[1].factor.x,0,1)}
    if metallic!=NONE {info.metallic=clamp(forms[2].factor.x,0,1)}
    if occlusion!=NONE {info.occlusion_strength=1}
    if mr_uv!=NONE {
        transform,ok:=uv_transform(g,mr_uv)
        if !ok {return refuse(e,"the coordinates of metallic and roughness")}
        maps[.Metallic_Roughness]=transform
        image:=MAP_NONE
        image.channels[1]=forms[1].image
        image.channels[2]=forms[2].image
        if forms[0].image!=NONE && forms[0].uv==mr_uv {image.channels[0]=forms[0].image}
        t.images[.Metallic_Roughness]=image
    }
    if forms[0].image!=NONE {
        transform,ok:=uv_transform(g,forms[0].uv)
        if !ok {return refuse(e,"the coordinates of occlusion")}
        maps[.Occlusion]=transform
        if forms[0].uv==mr_uv {
            t.images[.Occlusion]=t.images[.Metallic_Roughness]
        } else {
            image:=MAP_NONE
            image.channels[0]=forms[0].image
            t.images[.Occlusion]=image
        }
        // A constant factor of occlusion darkens it: Mirai has none, so it goes in the image.
        if forms[0].factor.x!=1 {
            factor:=scalar(g,forms[0].factor.x)
            if forms[0].uv==mr_uv {
                t.images[.Metallic_Roughness].channels[0]=binary(g,.Mul,forms[0].image,factor)
                t.images[.Occlusion]=t.images[.Metallic_Roughness]
            } else {
                t.images[.Occlusion].channels[0]=binary(g,.Mul,forms[0].image,factor)
            }
        }
    } else if occlusion!=NONE && forms[0].factor.x<1 {
        // A constant occlusion is an image of one texel.
        image:=MAP_NONE
        image.channels[0]=scalar(g,clamp(forms[0].factor.x,0,1))
        t.images[.Occlusion]=image
    }

    if specular!=NONE {
        form,ok:=map_form(g,specular)
        if !ok {return refuse(e,"the specular")}
        if form.image==NONE {
            info.ior,info.specular_factor=specular_ior(form.factor.x)
        } else {
            transform,uv_ok:=uv_transform(g,form.uv)
            if !uv_ok {return refuse(e,"the coordinates of the specular")}
            maps[.Specular]=transform
            image:=MAP_NONE
            image.channels[3]=form.image
            t.images[.Specular]=image
            info.ior=SPECULAR_FULL_IOR
            info.specular_factor=clamp(form.factor.x,0,1)
        }
    }

    if emissive!=NONE {
        form,ok:=map_form(g,emissive)
        if !ok {return refuse(e,"the emission")}
        info.emission={max(form.factor.x,0),max(form.factor.y,0),max(form.factor.z,0)}
        if form.image!=NONE {
            transform,uv_ok:=uv_transform(g,form.uv)
            if !uv_ok {return refuse(e,"the coordinates of the emission")}
            maps[.Emission]=transform
            image:=MAP_NONE
            for c in 0..<3 {image.channels[c]=component(g,convert(g,form.image,3),u8(c))}
            t.images[.Emission]=image
        }
    }

    if normal!=NONE {
        if !normal_map(t,e,normal) {return refuse(e,"the normal")}
    }

    if e.diffuse_transmission[0]!=NONE {
        color,ok:=map_form(g,e.diffuse_transmission[0])
        weight,weight_ok:=map_form(g,e.diffuse_transmission[1])
        if !ok || !weight_ok || weight.image!=NONE {return refuse(e,"the diffuse transmission")}
        info.diffuse_transmission.weight=clamp(weight.factor.x,0,1)
        info.diffuse_transmission.color={clamp(color.factor.x,0,1),clamp(color.factor.y,0,1),clamp(color.factor.z,0,1)}
        if color.image!=NONE {
            transform,uv_ok:=uv_transform(g,color.uv)
            if !uv_ok {return refuse(e,"the coordinates of the diffuse transmission")}
            maps[.Diffuse_Transmission_Color]=transform
            image:=MAP_NONE
            for c in 0..<3 {image.channels[c]=component(g,convert(g,color.image,3),u8(c))}
            t.images[.Diffuse_Transmission_Color]=image
        }
    }
    if e.fuzz[0]!=NONE && shading!=.Cloth {
        color,ok:=map_form(g,e.fuzz[0])
        weight,weight_ok:=map_form(g,e.fuzz[1])
        if !ok || !weight_ok || weight.image!=NONE {return refuse(e,"the fuzz")}
        info.fuzz.weight=clamp(weight.factor.x,0,1)
        info.fuzz.color={clamp(color.factor.x,0,1),clamp(color.factor.y,0,1),clamp(color.factor.z,0,1)}
        if color.image!=NONE {
            transform,uv_ok:=uv_transform(g,color.uv)
            if !uv_ok {return refuse(e,"the coordinates of the fuzz")}
            maps[.Fuzz_Color]=transform
            image:=MAP_NONE
            for c in 0..<3 {image.channels[c]=component(g,convert(g,color.image,3),u8(c))}
            t.images[.Fuzz_Color]=image
        }
    }

    if shading==.Clear_Coat {
        coat,ok:=map_form(g,roots[.Clear_Coat])
        coat_roughness,rough_ok:=map_form(g,roots[.Clear_Coat_Roughness])
        if !ok || !rough_ok || coat.image!=NONE || coat_roughness.image!=NONE {return refuse(e,"the clear coat")}
        info.coat.weight=clamp(coat.factor.x,0,1)
        info.coat.roughness=clamp(coat_roughness.factor.x,0,1)
        info.coat.ior=1.5
    }
    if shading==.Cloth {
        fuzz,ok:=map_form(g,convert(g,roots[.Subsurface_Color],3))
        weight,weight_ok:=map_form(g,roots[.Clear_Coat])
        if !ok || !weight_ok || fuzz.image!=NONE || weight.image!=NONE {return refuse(e,"the cloth")}
        info.fuzz.weight=clamp(weight.factor.x,0,1)
        info.fuzz.color={clamp(fuzz.factor.x,0,1),clamp(fuzz.factor.y,0,1),clamp(fuzz.factor.z,0,1)}
    }
    refraction:=roots[.Refraction]
    // Unreal's glass refracts by lerp(air, IOR, Fresnel): its IOR is the one
    // a Mirai glass refracts and reflects with.
    if refraction!=NONE {
        if node:=g.nodes[refraction];node.op==.Lerp && g.nodes[node.args[2]].op==.Fresnel {refraction=node.args[1]}
    }
    if info.alpha_mode==.Blend && refraction!=NONE && !(is_constant(g,refraction) && g.nodes[refraction].value.x==1) {
        form,ok:=map_form(g,refraction)
        if !ok || form.image!=NONE {return refuse(e,"the refraction")}
        if form.factor.x>1 {
            info.transmission=1
            info.ior=form.factor.x
        }
    }
    return true
}

// The normal of the standard model: a normal map sampled as it is, or the
// tangent-space normal any per-texel function of textures gives, baked.
// Lerp from the flat normal to a map is taken as its normal_scale.
@(private)
normal_map :: proc(t:^Translated_Material,e:^Evaluator,normal:u32) -> bool {
    g:=&t.graph
    info:=&t.info
    if value,ok:=evaluate_constant(g,normal);ok {
        if value.x==0 && value.y==0 && value.z>0 {return true}
        return false
    }
    n:=normal
    scale:f32=1
    node:=g.nodes[n]
    if node.op==.Lerp {
        flat,flat_ok:=evaluate_constant(g,node.args[0])
        amount,amount_ok:=evaluate_constant(g,node.args[2])
        if flat_ok && amount_ok && flat.x==0 && flat.y==0 && flat.z==1 && width_of(g,node.args[2])==1 {
            n=node.args[1]
            scale=amount.x
            note(e,"a normal lerped toward the flat normal by %g is a normal map with normal_scale %g",amount.x,amount.x)
        }
    }
    uv:=NONE
    if !samples_share_uv(g,n,&uv) || uv==NONE {return false}
    transform,ok:=uv_transform(g,uv)
    if !ok {return false}
    asset.material_maps(&info.maps)[.Normal]=transform
    info.normal_scale=scale
    image:=MAP_NONE
    for c in 0..<3 {image.channels[c]=component(g,convert(g,n,3),u8(c))}
    t.images[.Normal]=image
    return true
}
