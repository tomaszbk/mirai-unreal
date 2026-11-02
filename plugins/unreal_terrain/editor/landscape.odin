package unreal_terrain_editor

import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "project:plugins/unreal/editor/landscape"
import "project:plugins/unreal/editor/level"
import material "project:plugins/unreal/editor/material"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import terrain "plugins:terrain/runtime"

// A landscape of an Unreal level as a Heightfield source: its heights, its
// holes and up to LAYERS_MAX of its paint layers. A landscape with more
// layers keeps the ones of most weight and adds the weight of each other to
// the kept layer it blends with most (the one whose weights overlap its own
// the most), so every sample keeps its full weight and an edge between two
// layers stays an edge.

Landscape_Options :: struct {
    chunk_cells:int,           // 0: Unreal's subsections, within CHUNK_CELLS_MIN..CHUNK_CELLS_MAX
    materials:[]base.Asset_Id, // the .mat of each layer of the landscape, in its order; zero for none
}

Landscape_Terrain :: struct {
    transform:mm.Transform,          // of the entity that shows the source
    layers:[terrain.LAYERS_MAX]int,  // the layer of the landscape each layer of the source is, -1 unused
    folded:[]int,                    // for each layer of the landscape, the layer of the source its weight went to
}

// Writes the source of a landscape into dst; false when it does not fit a
// Heightfield (size, spacing) or memory runs out, dst unchanged.
landscape_terrain :: proc(dst:^terrain.Source,l:^landscape.Landscape,options:Landscape_Options,allocator:=context.allocator) -> (result:Landscape_Terrain,ok:bool) {
    if l.samples.x<2 || l.samples.y<2 || l.samples.x>terrain.HEIGHT_SAMPLES_MAX || l.samples.y>terrain.HEIGHT_SAMPLES_MAX {return}
    if !(l.spacing>0) || len(l.heights)!=l.samples.x*l.samples.y {return}
    chunk:=options.chunk_cells
    if chunk==0 {chunk=clamp(l.subsection_quads,terrain.CHUNK_CELLS_MIN,terrain.CHUNK_CELLS_MAX)}
    s:terrain.Source
    if !terrain.source_make(&s,.Heightfield,{l.samples.x,1,l.samples.y},l.spacing,chunk,allocator) {return}
    defer if !ok {terrain.source_destroy(&s)}
    for j in 0..<l.samples.y {for i in 0..<l.samples.x {
        h:=l.heights[i+l.samples.x*j]
        if !(abs(h)<=terrain.HEIGHT_LIMIT) {return}
        if !terrain.source_set(&s,{i,0,j},h) {return}
    }}
    cells:=[2]int{l.samples.x-1,l.samples.y-1}
    if len(l.holes)==cells.x*cells.y {
        if !terrain.grid_init(&s.holes,{cells.x,1,cells.y},0,allocator) {return}
        for j in 0..<cells.y {for i in 0..<cells.x {
            if l.holes[i+cells.x*j]!=0 && !terrain.grid_put(&s.holes,{i,0,j},u8(1),allocator) {return}
        }}
    }
    for &kept in result.layers {kept=-1}
    count:=l.samples.x*l.samples.y
    total:=len(l.layers)
    if total>0 && len(l.weights)==total*count {
        result.folded=make([]int,total,allocator)
        kept:=layers_choose(l,result.folded,&result.layers)
        for layer in 0..<kept {
            source_layer:=terrain.LAYER_DEFAULT
            at:=result.layers[layer]
            if at<len(options.materials) {source_layer.material=options.materials[at]}
            if !terrain.source_layer_set(&s,layer,source_layer) {delete(result.folded,allocator);return}
        }
        for j in 0..<l.samples.y {for i in 0..<l.samples.x {
            f:[4]f32
            for layer in 0..<total {f[result.folded[layer]]+=f32(l.weights[layer*count+i+l.samples.x*j])}
            if !terrain.grid_put(&s.weights,{i,0,j},terrain.weights_quantize(f,kept),allocator) {delete(result.folded,allocator);return}
        }}
    }
    result.transform=l.transform
    terrain.source_destroy(dst)
    dst^=s
    return result,true
}

// The layers of the source: the LAYERS_MAX heaviest, and where each layer
// of the landscape goes. How many there are.
@(private)
layers_choose :: proc(l:^landscape.Landscape,folded:[]int,layers:^[terrain.LAYERS_MAX]int) -> int {
    count:=l.samples.x*l.samples.y
    total:=len(l.layers)
    weight:=make([]u64,total,context.temp_allocator)
    for layer in 0..<total {for w in l.weights[layer*count:][:count] {weight[layer]+=u64(w)}}
    order:=make([]int,total,context.temp_allocator)
    for &o,i in order {o=i}
    // Heaviest first; the earlier layer on a tie.
    for i in 1..<total {
        for k:=i;k>0 && weight[order[k]]>weight[order[k-1]];k-=1 {order[k],order[k-1]=order[k-1],order[k]}
    }
    kept:=min(total,terrain.LAYERS_MAX)
    for slot in 0..<kept {layers[slot]=order[slot];folded[order[slot]]=slot}
    for dropped in order[kept:] {
        best,best_overlap:=0,u64(0)
        for slot in 0..<kept {
            overlap:=u64(0)
            a,b:=l.weights[dropped*count:][:count],l.weights[layers[slot]*count:][:count]
            for w,i in a {overlap+=u64(min(w,b[i]))}
            if overlap>best_overlap {best,best_overlap=slot,overlap}
        }
        folded[dropped]=best
    }
    return kept
}

// How the material of a landscape, translated whole, sees the terrain: the
// paint layer of each layer of the source, and the affine map from a point of
// the world (Unreal's centimetres) to the coordinates of the landscape.
landscape_mapping :: proc(l:^landscape.Landscape,result:^Landscape_Terrain) -> (mapping:material.Landscape_Mapping) {
    for at,slot in result.layers {if at>=0 {mapping.layers[slot]=l.layers[at].name}}
    axes:=[3][3]f32{level.point_to_mirai({1,0,0}),level.point_to_mirai({0,1,0}),level.point_to_mirai({0,0,1})}
    quads :: proc(axes:[3][3]f32,local:[3]f32) -> [2]f32 {
        return {linalg.dot(local,axes[0])/linalg.dot(axes[0],axes[0]),linalg.dot(local,axes[1])/linalg.dot(axes[1],axes[1])}
    }
    origin:=quads(axes,mm.transform_inverse_point(l.local,{}))
    along:[3][2]f32
    for axis,i in axes {along[i]=quads(axes,mm.transform_inverse_vector(l.local,axis))}
    for row in 0..<2 {mapping.coordinates[row]={along[0][row],along[1][row],along[2][row],origin[row]}}
    return
}

// The landscapes of an Unreal level imported by the editor: Landscape and
// its proxies of one LandscapeGuid are one Heightfield source in
// levels/<map>/ with an entity that shows it. Its layers take the
// materials of the layers of its material; a material without layers (that
// blends its own splat maps) is the material of the source. Its proxies are
// of the scene of the map whatever their cell of World Partition: the terrain
// streams its pages by itself.
@(storage)
Terrain_Unreal :: struct {provider:unreal_scene.Translator_Provider}

terrain_unreal_default :: proc() -> (t:Terrain_Unreal) {
    t.provider.count=1
    t.provider.translators[0]={classes={"Landscape","LandscapeProxy","LandscapeStreamingProxy",""},translate=landscapes_translate,root=true}
    return
}

landscapes_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"terrain.translate")
    decoder,ready:=unreal_scene.decoder(c)
    if !ready {unreal_scene.warn(c,"no memory for the Oodle decoder: the landscapes are left out");return 0}
    read_zone:=unreal_scene.zone_begin(c,"terrain.read")
    list,error:=landscape.landscapes_read(c.d,decoder,context.temp_allocator)
    unreal_scene.zone_end(read_zone)
    if error.code!=.None {
        unreal_scene.warn(c,"the landscapes could not be read (%v at 0x%x: %s); they are left out",error.code,error.offset,error.field)
        return 0
    }
    defer landscape.landscapes_destroy(&list)
    translated:=0
    for &l,index in list {
        if landscape_translate(c,&l,index) {translated+=1}
    }
    return translated==len(list)?len(actors):translated
}

@(private)
landscape_translate :: proc(c:^unreal_scene.Context,l:^landscape.Landscape,index:int) -> bool {
    label:=c.d.actors[l.actor].label
    materials:=make([]base.Asset_Id,len(l.layers),context.temp_allocator)
    whole:base.Asset_Id
    layered:unreal_scene.Layered
    materials_zone:=unreal_scene.zone_begin(c,"terrain.materials")
    if l.material!="" {
        layered=unreal_scene.layer_materials(c,l.material)
        switch {
        case !layered.ok:
        case len(layered.names)==0 || len(l.layers)==0:
            whole=layered.ids[0]
        case:
            for layer,i in l.layers {
                at,found:=slice.linear_search(layered.names,layer.name)
                if found {materials[i]=layered.ids[at]} else {unreal_scene.warn(c,"%s: its material has no layer %s; that layer takes none",label,layer.name)}
            }
        }
    }
    unreal_scene.zone_end(materials_zone)
    s:terrain.Source
    defer terrain.source_destroy(&s)
    source_zone:=unreal_scene.zone_begin(c,"terrain.source")
    result,ok:=landscape_terrain(&s,l,{materials=materials})
    unreal_scene.zone_end(source_zone)
    if !ok {
        unreal_scene.warn(c,"%s: %dx%d samples every %.3g m do not fit a Heightfield; it is left out",label,l.samples.x,l.samples.y,l.spacing)
        return false
    }
    defer delete(result.folded)
    s.materials[0]=whole
    // The material whole blends the layers of the source its layers are.
    if s.layer_count>0 && layered.ok && len(layered.names)>0 {
        mapping:=landscape_mapping(l,&result)
        shown:=false
        for &name in mapping.layers {
            if _,found:=slice.linear_search(layered.names,name);!found {name=""}
            shown||=name!=""
        }
        if shown {
            unreal_scene.zone(c,"terrain.materials")
            s.layers_material=unreal_scene.layer_materials(c,l.material,label,&mapping).whole
        }
    }
    if len(l.layers)>terrain.LAYERS_MAX {unreal_scene.warn(c,"%s: %d paint layers; the %d of most weight are kept and the others fold into them",label,len(l.layers),terrain.LAYERS_MAX)}
    s.revision=1
    unreal_scene.zone(c,"terrain.write")
    id,path,info:=unreal_scene.asset_place(c,terrain.KIND,label,index,terrain.EXTENSION)
    types:=c.types
    bytes,bytes_error:=terrain.source_bytes(&s,id,types,context.allocator,&info)
    if bytes_error!=.None {
        unreal_scene.warn(c,"%s: its terrain could not be written (%v)",label,bytes_error)
        return false
    }
    defer delete(bytes)
    detail:=fmt.tprintf("%dx%d samples every %.3g m, %d layers",l.samples.x,l.samples.y,l.spacing,s.layer_count)
    if !unreal_scene.asset_write(c,id,terrain.KIND,label,path,bytes,detail) {return false}
    e,made:=unreal_scene.entity_make(c,0,unreal_scene.actor_key(c,l.actor),label,result.transform)
    if !made {return false}
    owner:=terrain.Terrain{source=id,revision=1,solid=true}
    return unreal_scene.component_set(c,e,"Terrain",&owner)
}
