package landscape

import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strings"
import "project:plugins/unreal/editor/kraken"
import level "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import texture "project:plugins/unreal/editor/texture"
import mm "mirai:std/math"

// The landscapes of a level as a grid of heights in Mirai's space: Unreal's
// components, sections, subsections and textures stay here. A landscape is
// every Landscape and LandscapeProxy of one LandscapeGuid; their
// components tile one grid of quads.
//
// Mirai's x runs along Unreal's +Y and z along -X, so sample (i,j) of the
// grid is the vertex X=max.x-j, Y=min.y+i of Unreal, and each cell is split
// along the same diagonal Unreal splits its quad with (i00,i11).

// A paint layer: the LandscapeLayerInfoObject its weights belong to.
Layer :: struct {
    name:string,     // LayerName, or the object name of the layer info when its package is not at hand
    info:string,     // the object path of the layer info
    coverage:f32,    // its share of the weight of all samples
}

Landscape :: struct {
    guid:unreal.Guid,
    actor:int,              // in the level document: the ALandscape, or the first proxy
    samples:[2]int,         // along Mirai's x and z
    spacing:f32,            // metres between samples along z
    heights:[]f32,          // metres, x contiguous: heights[i+samples.x*j]
    transform:mm.Transform, // of the centre of the grid in Mirai's world; its scale x is how much farther apart samples are along x than along z
    local:mm.Transform,     // from the space of the landscape (its quads as level.point_to_mirai takes points) to Mirai's world
    layers:[]Layer,
    weights:[]u8,           // 0..255 per layer and sample, layer after layer, as Unreal paints them
    holes:[]u8,             // 1 for a cell without surface, (samples.x-1)*(samples.y-1); nil without any
    material:string,        // object path of the LandscapeMaterial, "" without one
    components:int,
    subsection_quads:int,
    missing_quads:int,      // quads of the rectangle no component covers, left as holes
    allocator:mem.Allocator,
}

// The coordinates of a landscape (its quads, from its actor) at a point p of
// the world in Unreal's centimetres, by the transform of the actor (local):
// dot(row.xyz,p)+row.w.
coordinates_of :: proc(local:mm.Transform) -> (rows:[2][4]f32) {
    axes:=[3][3]f32{level.point_to_mirai({1,0,0}),level.point_to_mirai({0,1,0}),level.point_to_mirai({0,0,1})}
    quads :: proc(axes:[3][3]f32,v:[3]f32) -> [2]f32 {
        return {linalg.dot(v,axes[0])/linalg.dot(axes[0],axes[0]),linalg.dot(v,axes[1])/linalg.dot(axes[1],axes[1])}
    }
    origin:=quads(axes,mm.transform_inverse_point(local,{}))
    along:[3][2]f32
    for axis,i in axes {along[i]=quads(axes,mm.transform_inverse_vector(local,axis))}
    for row in 0..<2 {rows[row]={along[0][row],along[1][row],along[2][row],origin[row]}}
    return
}

landscape_destroy :: proc(l:^Landscape) {
    for layer in l.layers {delete(layer.name,l.allocator);delete(layer.info,l.allocator)}
    delete(l.layers,l.allocator)
    delete(l.heights,l.allocator);delete(l.weights,l.allocator);delete(l.holes,l.allocator)
    delete(l.material,l.allocator)
    l^={}
}

landscapes_destroy :: proc(list:^[dynamic]Landscape) {
    for &l in list {landscape_destroy(&l)}
    delete(list^)
    list^=nil
}

// LANDSCAPE_ZSCALE: a height of the texture is (value-32768)/128 local units.
HEIGHT_MID :: 32768
HEIGHT_SCALE :: 1.0/128
// Collision and these grids take a quad as a hole where the visibility
// weight of its first vertex is above this (255*0.66).
HOLE_WEIGHT :: 170

@(private)
Allocation :: struct {layer,texture,channel:int}

@(private)
Component :: struct {
    ref:level.Ref,
    base:[2]int,
    size_quads,subsection_quads,subsections:int,
    heightmap:level.Ref,
    bias:[4]f64,
    weightmaps:[]level.Ref,
    allocations:[]Allocation,
}

@(private)
Layer_Key :: struct {info:string,visibility:bool}

@(private)
Reader :: struct {
    d:^level.Document,
    decoder:^kraken.Decoder,
    textures:map[level.Ref]texture.Decoded,
    layers:[dynamic]Layer_Key,
    allocator:mem.Allocator,
}

// Every landscape of the level, grids built.
landscapes_read :: proc(d:^level.Document,decoder:^kraken.Decoder,allocator:=context.allocator) -> (list:[dynamic]Landscape,error:unreal.Error) {
    list.allocator=allocator
    r:=Reader{d=d,decoder=decoder,allocator=allocator}
    r.textures.allocator=context.temp_allocator
    r.layers.allocator=context.temp_allocator
    defer for _,&decoded in r.textures {texture.decoded_destroy(&decoded)}
    for actor in landscape_actors(d) {
        l:Landscape
        l,error=landscape_read(&r,actor)
        if error.code!=.None {landscapes_destroy(&list);return}
        append(&list,l)
    }
    return
}

// The actor that stands for each landscape of the level, in the order its
// LandscapeGuid first appears: its Landscape, or else its first proxy.
landscape_actors :: proc(d:^level.Document,allocator:=context.temp_allocator) -> []int {
    guids:=make([dynamic]unreal.Guid,context.temp_allocator)
    actors:=make([dynamic]int,allocator)
    for actor,i in d.actors {
        if !is_proxy(actor.class) {continue}
        guid:=guid_property(d,actor.ref,"LandscapeGuid")
        at,found:=slice.linear_search(guids[:],guid)
        if !found {
            append(&guids,guid)
            append(&actors,i)
        } else if actor.class.name=="Landscape" && d.actors[actors[at]].class.name!="Landscape" {
            actors[at]=i
        }
    }
    return actors[:]
}

@(private)
is_proxy :: proc(c:level.Class) -> bool {
    return c.pkg=="/Script/Landscape" && (c.name=="Landscape" || c.name=="LandscapeStreamingProxy" || c.name=="LandscapeProxy")
}

@(private)
guid_property :: proc(d:^level.Document,ref:level.Ref,name:string) -> (guid:unreal.Guid) {
    f,error:=level.property(d,ref,name)
    if error.code!=.None || f.property==nil {return}
    v,value_error:=unreal.property_value(f.pkg,f.property)
    if value_error.code==.None && v.kind==.Guid {guid=v.guid}
    return
}

@(private)
int_property :: proc(d:^level.Document,ref:level.Ref,name:string,default:int) -> (value:int,error:unreal.Error) {
    f:level.Found
    f,error=level.property(d,ref,name)
    if error.code!=.None || f.property==nil {return default,error}
    v:unreal.Value
    v,error=unreal.property_value(f.pkg,f.property)
    if error.code!=.None {return}
    if v.kind!=.Signed {return 0,{.Unsupported_Value,f.property.data.offset,"expected an integer property"}}
    return int(v.signed),{}
}

@(private)
vector4_property :: proc(d:^level.Document,ref:level.Ref,name:string,default:[4]f64) -> (value:[4]f64,error:unreal.Error) {
    f:level.Found
    f,error=level.property(d,ref,name)
    if error.code!=.None || f.property==nil {return default,error}
    v:unreal.Value
    v,error=unreal.property_value(f.pkg,f.property)
    if error.code!=.None {return}
    if v.kind!=.Real_Vector || v.vector_count!=4 {return {},{.Unsupported_Value,f.property.data.offset,"expected a Vector4 property"}}
    return v.vector,{}
}

// The export an object property of ref names, or false when it has none.
@(private)
object_ref :: proc(d:^level.Document,ref:level.Ref,name:string) -> (target:level.Ref,found:bool,error:unreal.Error) {
    f:level.Found
    f,error=level.property(d,ref,name)
    if error.code!=.None || f.property==nil || f.origin!=.Authored {return}
    v:unreal.Value
    v,error=unreal.property_value(f.pkg,f.property)
    if error.code!=.None || v.kind!=.Object || v.object==0 {return}
    native:bool
    target,native,error=level.resolve(d,ref,v.object)
    return target,error.code==.None && !native,error
}

@(private)
landscape_read :: proc(r:^Reader,stand:int) -> (l:Landscape,error:unreal.Error) {
    d:=r.d
    guid:=guid_property(d,d.actors[stand].ref,"LandscapeGuid")
    l.guid=guid
    l.actor=stand
    l.allocator=r.allocator
    defer if error.code!=.None {landscape_destroy(&l)}
    components:[dynamic]Component
    components.allocator=context.temp_allocator
    clear(&r.layers)
    for actor in d.actors {
        if !is_proxy(actor.class) || guid_property(d,actor.ref,"LandscapeGuid")!=guid {continue}
        for c in actor.first_component..<actor.first_component+actor.component_count {
            item:=d.components[c]
            if !level.class_is(item.class,"/Script/Landscape","LandscapeComponent") {continue}
            component:Component
            component,error=component_read(r,item.ref)
            if error.code!=.None {return}
            append(&components,component)
        }
    }
    if len(components)==0 {return}
    proxy:=d.actors[l.actor].ref
    if material:=level.path_of(d,proxy,"LandscapeMaterial");material!="" {l.material=strings.clone(material,l.allocator)}
    low,high:=components[0].base,components[0].base
    quads:=components[0].size_quads
    l.subsection_quads=components[0].subsection_quads
    for c in components {
        if c.size_quads!=quads {return l,{.Malformed,0,"landscape components of different sizes"}}
        low={min(low.x,c.base.x),min(low.y,c.base.y)}
        high={max(high.x,c.base.x+c.size_quads),max(high.y,c.base.y+c.size_quads)}
    }
    vertices:=[2]int{high.x-low.x+1,high.y-low.y+1}
    // Mirai x along Unreal's Y, z along -X.
    l.samples={vertices.y,vertices.x}
    if l.samples.x>1<<16 || l.samples.y>1<<16 {return l,{.Limit,0,"landscape grid size"}}
    l.components=len(components)
    world,_,world_error:=level.actor_world(d,l.actor)
    if world_error.code!=.None {return l,world_error}
    // Mirai's scale of the actor: x along Unreal's Y, y its Z, z its X.
    if !(world.scale.x>0) || !(world.scale.z>0) {
        return l,{.Unsupported_Value,0,"landscape needs a positive scale along X and Y"}
    }
    l.spacing=world.scale.z*0.01
    height_scale:=f32(f64(world.scale.y)*HEIGHT_SCALE*0.01)
    center:=level.point_to_mirai({f64(low.x+high.x)*0.5,f64(low.y+high.y)*0.5,0})
    // The grid is square, spacing apart; a scale along Unreal's Y other than along its X stretches it.
    stretch:=abs(world.scale.x-world.scale.z)<=1e-6*world.scale.z?1:world.scale.x/world.scale.z
    l.transform={position=mm.transform_point(world,center),rotation=world.rotation,scale={stretch,1,1}}
    l.local=world
    count:=l.samples.x*l.samples.y
    allocation_error:mem.Allocator_Error
    l.heights,allocation_error=make([]f32,count,l.allocator)
    if allocation_error!=nil {return l,{.Out_Of_Memory,0,"landscape heights"}}
    covered:=make([]bool,(vertices.x-1)*(vertices.y-1),context.temp_allocator)
    visibility:=make([]u8,count,context.temp_allocator)
    for c in components {
        if error=component_heights(r,&l,c,low,high,height_scale,covered);error.code!=.None {return}
    }
    // Layers, without the visibility layer, which becomes holes.
    kept:=0
    for key in r.layers {if !key.visibility {kept+=1}}
    if kept>0 {
        l.layers,allocation_error=make([]Layer,kept,l.allocator)
        if allocation_error==nil {l.weights,allocation_error=make([]u8,kept*count,l.allocator)}
        if allocation_error!=nil {return l,{.Out_Of_Memory,0,"landscape layers"}}
        at:=0
        for key in r.layers {
            if key.visibility {continue}
            l.layers[at].info=strings.clone(key.info,l.allocator)
            l.layers[at].name=strings.clone(layer_name(d,key.info),l.allocator)
            at+=1
        }
    }
    for c in components {
        if error=component_weights(r,&l,c,low,high,visibility);error.code!=.None {return}
    }
    if kept>0 {
        sum:=0
        for w in l.weights {sum+=int(w)}
        for &layer,i in l.layers {
            total:=0
            for w in l.weights[i*count:][:count] {total+=int(w)}
            layer.coverage=sum>0?f32(f64(total)/f64(sum)):0
        }
    }
    holes:=0
    cells:=[2]int{l.samples.x-1,l.samples.y-1}
    hole_of :: proc(covered:[]bool,visibility:[]u8,vertices:[2]int,l:^Landscape,qx,qy:int) -> bool {
        if !covered[qx+(vertices.x-1)*qy] {return true}
        // The weight of the first vertex of the quad: Unreal's (qx,qy) is Mirai's (qy, max.x-qx).
        i,j:=qy,vertices.x-1-qx
        return visibility[i+l.samples.x*j]>HOLE_WEIGHT
    }
    for qy in 0..<vertices.y-1 {for qx in 0..<vertices.x-1 {
        if hole_of(covered,visibility,vertices,&l,qx,qy) {holes+=1}
        if !covered[qx+(vertices.x-1)*qy] {l.missing_quads+=1}
    }}
    if holes>0 {
        l.holes,allocation_error=make([]u8,cells.x*cells.y,l.allocator)
        if allocation_error!=nil {return l,{.Out_Of_Memory,0,"landscape holes"}}
        for qy in 0..<vertices.y-1 {for qx in 0..<vertices.x-1 {
            if !hole_of(covered,visibility,vertices,&l,qx,qy) {continue}
            // Quad (qx,qy) spans Mirai's j from max.x-qx-1 to max.x-qx.
            l.holes[qy+cells.x*(vertices.x-2-qx)]=1
        }}
    }
    return
}

@(private)
component_read :: proc(r:^Reader,ref:level.Ref) -> (c:Component,error:unreal.Error) {
    d:=r.d
    c.ref=ref
    c.base.x,error=int_property(d,ref,"SectionBaseX",0);if error.code!=.None {return}
    c.base.y,error=int_property(d,ref,"SectionBaseY",0);if error.code!=.None {return}
    c.size_quads,error=int_property(d,ref,"ComponentSizeQuads",0);if error.code!=.None {return}
    c.subsection_quads,error=int_property(d,ref,"SubsectionSizeQuads",0);if error.code!=.None {return}
    c.subsections,error=int_property(d,ref,"NumSubsections",0);if error.code!=.None {return}
    // LandscapeComponent's default.
    c.bias,error=vector4_property(d,ref,"HeightmapScaleBias",{0,0,0,1});if error.code!=.None {return}
    if c.subsections<1 || c.subsections>2 || c.subsection_quads<1 || c.size_quads!=c.subsection_quads*c.subsections || c.size_quads>4096 {
        return c,{.Malformed,0,"landscape component sizes"}
    }
    found:bool
    c.heightmap,found,error=object_ref(d,ref,"HeightmapTexture")
    if error.code!=.None {return}
    if !found {return c,{.Unsupported_Value,0,"landscape component has no HeightmapTexture"}}
    p:=level.library_package(d.library,int(ref.pkg))
    if f,f_error:=level.property(d,ref,"WeightmapTextures");f_error.code==.None && f.property!=nil && f.origin==.Authored {
        view:unreal.Array_View
        view,error=unreal.property_array(f.pkg,f.property)
        if error.code!=.None {return}
        refs:[]unreal.Object_Ref
        refs,error=unreal.array_object_refs(f.pkg,view,context.temp_allocator)
        if error.code!=.None {return}
        c.weightmaps=make([]level.Ref,len(refs),context.temp_allocator)
        for object,i in refs {
            native:bool
            c.weightmaps[i],native,error=level.resolve(d,ref,object)
            if error.code!=.None {return}
            if native {return c,{.Invalid_Reference,0,"weightmap texture"}}
        }
    }
    if f,f_error:=level.property(d,ref,"WeightmapLayerAllocations");f_error.code==.None && f.property!=nil && f.origin==.Authored {
        view:unreal.Array_View
        view,error=unreal.property_array(f.pkg,f.property)
        if error.code!=.None {return}
        structs:unreal.Struct_Array
        structs,error=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
        if error.code!=.None {return}
        c.allocations=make([]Allocation,len(structs.items),context.temp_allocator)
        for &item,i in structs.items {
            info:=unreal.property_find(f.pkg,&item,"LayerInfo")
            if info==nil {return c,{.Malformed,0,"weightmap allocation without LayerInfo"}}
            v:unreal.Value
            v,error=unreal.property_value(f.pkg,info)
            if error.code!=.None {return}
            if v.kind!=.Object || v.object==0 {return c,{.Malformed,info.data.offset,"weightmap allocation LayerInfo"}}
            c.allocations[i].layer,error=layer_index(r,p,v.object)
            if error.code!=.None {return}
            for field,k in ([2]string{"WeightmapTextureIndex","WeightmapTextureChannel"}) {
                value:=0
                if property:=unreal.property_find(f.pkg,&item,field);property!=nil {
                    n:unreal.Value
                    n,error=unreal.property_value(f.pkg,property)
                    if error.code!=.None {return}
                    value=int(n.unsigned)
                }
                if k==0 {c.allocations[i].texture=value} else {c.allocations[i].channel=value}
            }
            if c.allocations[i].texture>=len(c.weightmaps) || c.allocations[i].channel>3 {return c,{.Malformed,info.data.offset,"weightmap allocation texture or channel"}}
        }
    }
    return
}

// The layer of a layer info, added the first time it is seen.
@(private)
layer_index :: proc(r:^Reader,p:^unreal.Package,info:unreal.Object_Ref) -> (index:int,error:unreal.Error) {
    path:string
    path,error=unreal.reference_path(p,info,context.temp_allocator)
    if error.code!=.None {return}
    for key,i in r.layers {if key.info==path {return i,{}}}
    name,_:=unreal.reference_name(p,info)
    text:=unreal.name_plain(p,name)
    // The visibility layer of every landscape (/Engine; DataLayer in UE4 saves).
    visibility:=strings.has_prefix(path,"/Engine/") && (text=="LandscapeVisibilityLayerInfo" || text=="DataLayer")
    append(&r.layers,Layer_Key{info=path,visibility=visibility})
    return len(r.layers)-1,{}
}

// The LayerName of a layer info when its package is at hand, else its object name.
@(private)
layer_name :: proc(d:^level.Document,info:string) -> string {
    dot:=strings.last_index_any(info,".:")
    fallback:=dot>=0?info[dot+1:]:info
    package_name:=info
    if at:=strings.index_byte(info,'.');at>=0 {package_name=info[:at]}
    index,error:=level.library_find(d.library,package_name)
    if error.code!=.None {return fallback}
    p:=level.library_package(d.library,index)
    for item,i in p.exports {
        if item.outer!=0 || unreal.name_plain(p,item.object_name)!=fallback {continue}
        f,f_error:=level.property(d,{i32(index),unreal.Object_Ref(i+1)},"LayerName")
        if f_error.code!=.None || f.property==nil {return fallback}
        v,v_error:=unreal.property_value(f.pkg,f.property)
        if v_error.code==.None && v.kind==.Name {return unreal.name_plain(f.pkg,v.name)}
    }
    return fallback
}

@(private)
decoded_of :: proc(r:^Reader,ref:level.Ref) -> (decoded:^texture.Decoded,width,height:int,error:unreal.Error) {
    p:=level.library_package(r.d.library,int(ref.pkg))
    if held,ok:=&r.textures[ref];ok {
        level0:=held.levels[0]
        return held,level0.width,level0.height,{}
    }
    source:texture.Texture
    source,error=texture.texture_read(p,int(ref.object)-1,context.temp_allocator)
    if error.code!=.None {return}
    defer texture.texture_destroy(&source)
    pixels:texture.Decoded
    pixels,error=texture.texture_decode(p,&source,r.decoder,context.temp_allocator)
    if error.code!=.None {return}
    if pixels.format!=.RGBA8 || len(pixels.levels)==0 {texture.decoded_destroy(&pixels);return nil,0,0,{.Unsupported_Value,0,"landscape textures are BGRA8"}}
    r.textures[ref]=pixels
    held:=&r.textures[ref]
    return held,held.levels[0].width,held.levels[0].height,{}
}

// The texel of vertex v of a component, as Unreal numbers them: each
// subsection repeats the vertices of its edges.
@(private)
texel_of :: proc "contextless" (c:Component,v:int) -> int {
    if v==0 {return 0}
    sub:=(v-1)/c.subsection_quads
    return sub*(c.subsection_quads+1)+(v-1)%c.subsection_quads+1
}

@(private)
component_heights :: proc(r:^Reader,l:^Landscape,c:Component,low,high:[2]int,height_scale:f32,covered:[]bool) -> unreal.Error {
    decoded,width,height,error:=decoded_of(r,c.heightmap)
    if error.code!=.None {return error}
    level0:=decoded.levels[0]
    pixels:=decoded.pixels[level0.offset:]
    offset:=[2]int{int(f64(width)*c.bias.z+0.5),int(f64(height)*c.bias.w+0.5)}
    span:=c.subsections*(c.subsection_quads+1)
    if offset.x<0 || offset.y<0 || offset.x+span>width || offset.y+span>height {return {.Malformed,0,"landscape heightmap region"}}
    vertices_x:=high.x-low.x+1
    for vy in 0..=c.size_quads {for vx in 0..=c.size_quads {
        tx,ty:=offset.x+texel_of(c,vx),offset.y+texel_of(c,vy)
        texel:=pixels[(tx+ty*width)*4:]
        value:=int(texel[0])<<8|int(texel[1])
        x,y:=c.base.x+vx-low.x,c.base.y+vy-low.y
        i,j:=y,(high.x-low.x)-x
        l.heights[i+l.samples.x*j]=f32(value-HEIGHT_MID)*height_scale
    }}
    for qy in 0..<c.size_quads {for qx in 0..<c.size_quads {
        covered[(c.base.x+qx-low.x)+(vertices_x-1)*(c.base.y+qy-low.y)]=true
    }}
    return {}
}

@(private)
component_weights :: proc(r:^Reader,l:^Landscape,c:Component,low,high:[2]int,visibility:[]u8) -> unreal.Error {
    count:=l.samples.x*l.samples.y
    for a in c.allocations {
        decoded,width,height,error:=decoded_of(r,c.weightmaps[a.texture])
        if error.code!=.None {return error}
        span:=c.subsections*(c.subsection_quads+1)
        if span>width || span>height {return {.Malformed,0,"landscape weightmap size"}}
        level0:=decoded.levels[0]
        pixels:=decoded.pixels[level0.offset:]
        key:=r.layers[a.layer]
        target:=-1
        if !key.visibility {
            target=0
            for other in r.layers[:a.layer] {if !other.visibility {target+=1}}
        }
        for vy in 0..=c.size_quads {for vx in 0..=c.size_quads {
            w:=pixels[(texel_of(c,vx)+texel_of(c,vy)*width)*4+a.channel]
            x,y:=c.base.x+vx-low.x,c.base.y+vy-low.y
            at:=y+l.samples.x*((high.x-low.x)-x)
            if target<0 {visibility[at]=w} else if len(l.weights)>0 {l.weights[target*count+at]=w}
        }}
    }
    return {}
}
