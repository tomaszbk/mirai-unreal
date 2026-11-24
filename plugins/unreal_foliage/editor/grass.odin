package unreal_foliage_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "project:plugins/unreal/editor/landscape"
import "project:plugins/unreal/editor/level"
import material "project:plugins/unreal/editor/material"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"
import pcg "plugins:pcg/runtime"

// The grass of the landscapes of a level, as a .pcg source for the scene of
// the map: each variety of each grass type their materials name is a Scatter
// layer (Micro on the GPU when it casts no shadows, Meso on the CPU when it
// does), its ground rule on the layers of the terrain whose weight its input
// reads (by their materials), on the slopes and from the least weight of the
// rule closest to the input (material.Grass_Fit), bounded by a Volume over
// the quads where those layers are painted.

// What a variety shows.
Grass_Look :: struct {
    mesh:base.Asset_Id,
    materials:[render.MATERIAL_SLOTS]base.Asset_Id, // those its slots override; none: the mesh's
    wind,flutter:f32, // that its materials sway its mesh and flutter its leaves with (mesh_wind)
}

// A landscape and its grass, as its terrain shows it.
Grass_Landscape :: struct {
    landscape:^landscape.Landscape,
    grass:[]material.Landscape_Grass,
    layers:[]base.Asset_Id, // the material of each paint layer of the landscape on its terrain, in its order; zero for none
    looks:[][]Grass_Look,   // of each variety of each grass; one without a mesh is left out
}

Grass_Result :: struct {
    layers:int,       // generated layers added
    unlayered:int,    // varieties on layers its terrain shows without a material, left out
    folded:int,       // varieties on more layers than a rule names: they grow on those of most weight
    weighed:int,      // varieties whose input no rule fits: they grow as densely as its layers
    overridden:int,   // varieties with slot material overrides a .pcg mesh layer cannot carry
    shadows:bool,     // some added layer casts shadows (Meso tier)
    wind,flutter:f32, // density-weighted wind and flutter for the Foliage sink
    bounds:mm.Aabb,   // world bounds of the growing quads, relative to origin
    bounded:bool,     // whether bounds holds at least one growing quad
}

// Adds the grass of the landscapes to s as Scatter layers, and computes the
// bounding box of the quads where their driving layers weigh from origin.
// False past pcg.LAYERS_MAX.
grass_add :: proc(s:^pcg.Pcg_Source,landscapes:[]Grass_Landscape,origin:[3]f32) -> (result:Grass_Result,ok:bool) {
    if s.info.next_layer==0 {pcg.source_init(s)}
    held:=len(s.layers)
    Candidate :: struct {material:base.Asset_Id,coverage:f32,layer:int}
    wind_sum,flutter_sum,weight_sum:f64
    result.bounds={min={max(f32),max(f32),max(f32)},max={-max(f32),-max(f32),-max(f32)}}
    for gl in landscapes {
        l:=gl.landscape
        // The layers of the landscape whose weight some grass reads; all of it when one reads none.
        driving:=make([]bool,len(l.layers),context.temp_allocator)
        everywhere:=false
        for g,i in gl.grass {
            for v,j in g.varieties {
                look:=i<len(gl.looks) && j<len(gl.looks[i])?gl.looks[i][j]:Grass_Look{}
                // Unreal grows none of a variety without a mesh, a density or a reach.
                if look.mesh=={} || !(v.density>0) || !(v.cull[1]>0) {continue}
                candidates:=make([dynamic]Candidate,context.temp_allocator)
                painted:=false
                for wanted in g.layers {
                    for layer,k in l.layers {
                        if !strings.equal_fold(layer.name,wanted) {continue}
                        painted=true
                        if k<len(gl.layers) && gl.layers[k]!={} {append(&candidates,Candidate{gl.layers[k],layer.coverage,k})}
                    }
                }
                if len(g.layers)>0 && len(candidates)==0 {
                    if painted {result.unlayered+=1}
                    continue
                }
                slice.sort_by(candidates[:],proc(a,b:Candidate) -> bool {return a.coverage>b.coverage})
                params:=grass_layer_params(v,look.mesh)
                params.ground_rule.weight=clamp(v.weights[0],0,1)
                if g.fit.ok {
                    lo:=clamp(g.fit.slope[0],0,math.PI/2)
                    hi:=clamp(max(g.fit.slope[1],lo),lo,math.PI/2)
                    params.ground_rule.slope={lo,hi}
                    params.ground_rule.weight=max(params.ground_rule.weight,clamp(g.fit.weight,0,1))
                }
                params.ground_rule.enabled=len(candidates)>0 || params.ground_rule.slope!=pcg.PCG_LAYER_DEFAULT.ground_rule.slope
                kept:=0
                for candidate in candidates {
                    if slice.contains(params.ground_rule.layers[:kept],candidate.material) {driving[candidate.layer]=true;continue}
                    if kept==pcg.GROUND_RULE_LAYERS {continue}
                    params.ground_rule.layers[kept]=candidate.material
                    kept+=1
                    driving[candidate.layer]=true
                }
                for candidate in candidates {if !slice.contains(params.ground_rule.layers[:kept],candidate.material) {result.folded+=1;break}}
                everywhere||=len(candidates)==0
                if !g.fit.ok {result.weighed+=1}
                if look.materials!={} {result.overridden+=1}
                // Equal varieties of the landscapes of one material are one layer.
                same:=false
                for existing in s.layers[held:] {
                    alike:=params
                    alike.id=existing.id
                    if alike==existing.params {same=true;break}
                }
                if same {continue}
                if len(s.layers)>=pcg.LAYERS_MAX {return}
                added:=pcg.source_layer_add(s,.Scatter,params.tier)
                if added==nil {return}
                params.id=added.id
                added.params=params
                result.layers+=1
                result.shadows||=v.casts_shadow
                w:=f64(params.density)
                wind_sum+=f64(look.wind)*w
                flutter_sum+=f64(look.flutter)*w
                weight_sum+=w
            }
        }
        grass_bounds_grow(&result.bounds,&result.bounded,l,driving,everywhere,origin)
    }
    if weight_sum>0 {
        result.wind=f32(wind_sum/weight_sum)
        result.flutter=f32(flutter_sum/weight_sum)
    }
    return result,true
}

@(private)
grass_layer_params :: proc(v:material.Grass_Variety,mesh:base.Asset_Id) -> (p:pcg.Pcg_Layer_Params) {
    p=pcg.PCG_LAYER_DEFAULT
    p.tier=v.casts_shadow?.Meso:.Micro
    p.kind=.Scatter
    p.asset=mesh
    p.density=clamp(v.density,0,pcg.DENSITY_MAX)
    p.radius=0
    across:=v.scale[0]
    height:=[2]f32{1,1}
    if v.scaling!=.Uniform {
        z:=v.scale[2]
        height={max(z[0],1e-3)/max(across[1],1e-3),max(z[1],1e-3)/max(across[0],1e-3)}
    }
    p.scale={clamp(across[0],1e-3,1000),clamp(max(across[1],across[0]),1e-3,1000)}
    p.height={clamp(height[0],1e-3,1000),clamp(max(height[1],height[0]),1e-3,1000)}
    p.yaw=v.random_rotation?2*math.PI:0
    p.tilt=0
    p.align=v.align?1:0
    p.fade_distance,p.cull_distance=v.cull[1],v.cull[1]
    p.filler=true
    p.collides=false
    return
}

// Expands bounds to cover the quads of l where a driving layer weighs at a
// corner (or every quad when everywhere), holes left out, relative to origin.
@(private)
grass_bounds_grow :: proc(bounds:^mm.Aabb,bounded:^bool,l:^landscape.Landscape,driving:[]bool,everywhere:bool,origin:[3]f32) {
    n:=l.samples
    count:=n.x*n.y
    if n.x<2 || n.y<2 || !(l.spacing>0) || !everywhere && !slice.contains(driving,true) {return}
    weighed:=make([]bool,count,context.temp_allocator)
    for &w,k in weighed {
        w=everywhere
        for on,layer in driving {
            if w {break}
            w=on && layer*count+k<len(l.weights) && l.weights[layer*count+k]>0
        }
    }
    quads:=[2]int{n.x-1,n.y-1}
    half:=[2]f32{f32(quads.x),f32(quads.y)}*0.5
    has_heights:=len(l.heights)==count
    for j in 0..<quads.y {for i in 0..<quads.x {
        q:=i+quads.x*j
        if len(l.holes)==quads.x*quads.y && l.holes[q]!=0 {continue}
        k:=i+n.x*j
        if !(weighed[k] || weighed[k+1] || weighed[k+n.x] || weighed[k+n.x+1]) {continue}
        for c in ([4][2]int{{i,j},{i+1,j},{i,j+1},{i+1,j+1}}) {
            h:=has_heights?l.heights[c.x+n.x*c.y]:0
            local:=[3]f32{(f32(c.x)-half.x)*l.spacing,h,(f32(c.y)-half.y)*l.spacing}
            p:=mm.transform_point(l.transform,local)-origin
            bounds.min=linalg.min(bounds.min,p)
            bounds.max=linalg.max(bounds.max,p)
            if !has_heights {
                bounds.min.y=min(bounds.min.y,p.y-500)
                bounds.max.y=max(bounds.max.y,p.y+500)
            }
            bounded^=true
        }
    }}
}

FIT_NOTED :: f32(0.01) // of the density, a fit off by more than which the import tells

// The grass of the landscapes of the level as a .pcg source in the scene of
// the map, shown by an entity with Pcg_Graph, Foliage and its bounding Volume.
@(private)
grass_translate :: proc(c:^unreal_scene.Context,origin:[3]f32,winds:^Winds) -> (result:Grass_Result) {
    d:=c.d
    by_material:=make(map[string][]material.Landscape_Grass,context.temp_allocator)
    some:=false
    for a in landscape.landscape_actors(d) {
        path:=level.path_of(d,d.actors[a].ref,"LandscapeMaterial")
        if path=="" || path in by_material {continue}
        grass:=unreal_scene.landscape_grass(c,path)
        by_material[strings.clone(path,context.temp_allocator)]=grass
        for g in grass {
            if len(g.varieties)>0 && g.fit.ok && g.fit.error>FIT_NOTED {
                unreal_scene.warn(c,"%s: its grass %s grows on slopes of %.0f to %.0f degrees where its layers weigh %.2f or more, as dense as they weigh: %.0f%% off the density its material gives",
                    path,g.name,g.fit.slope[0]*180/math.PI,g.fit.slope[1]*180/math.PI,g.fit.weight,g.fit.error*100)
            }
            if len(g.varieties)>0 {some=true;continue}
            unreal_scene.warn(c,"%s: its grass %s names the grass type %s, which could not be read or has no varieties; it is left out",path,g.name,g.type)
        }
    }
    if !some {return}
    decoder,ready:=unreal_scene.decoder(c)
    if !ready {unreal_scene.warn(c,"no memory for the Oodle decoder: the grass of the landscapes is left out");return}
    read_zone:=unreal_scene.zone_begin(c,"foliage.grass_read")
    list,error:=landscape.landscapes_read(d,decoder,context.temp_allocator)
    unreal_scene.zone_end(read_zone)
    if error.code!=.None {
        unreal_scene.warn(c,"the landscapes could not be read (%v at 0x%x: %s); their grass is left out",error.code,error.offset,error.field)
        return
    }
    defer landscape.landscapes_destroy(&list)
    inputs:=make([dynamic]Grass_Landscape,context.temp_allocator)
    for &l in list {
        grass:=by_material[l.material]
        if len(grass)==0 {continue}
        layered:=unreal_scene.layer_materials(c,l.material)
        layers:=make([]base.Asset_Id,len(l.layers),context.temp_allocator)
        for layer,k in l.layers {
            if at,found:=slice.linear_search(layered.names,layer.name);found {layers[k]=layered.ids[at]}
        }
        looks:=make([][]Grass_Look,len(grass),context.temp_allocator)
        for g,i in grass {
            looks[i]=make([]Grass_Look,len(g.varieties),context.temp_allocator)
            for v,j in g.varieties {looks[i][j]=grass_look(c,v,winds)}
        }
        append(&inputs,Grass_Landscape{&l,grass,layers,looks})
    }
    s:pcg.Pcg_Source
    pcg.source_init(&s)
    defer pcg.source_destroy(&s)
    ok:bool
    result,ok=grass_add(&s,inputs[:],origin)
    if !ok {unreal_scene.warn(c,"the grass of the landscapes does not fit in a .pcg (%d layers at most); some is left out",pcg.LAYERS_MAX)}
    unreal_scene.tally(c,"varieties of landscape grass grow on paint layers whose terrain layer has no material, and are left out",result.unlayered)
    unreal_scene.tally(c,fmt.tprintf("varieties of landscape grass read more paint layers than the %d a ground rule names, and grow on those of most weight",pcg.GROUND_RULE_LAYERS),result.folded)
    unreal_scene.tally(c,"varieties of landscape grass read what a ground rule does not see (time, the camera, noise), and grow as densely as their paint layers alone",result.weighed)
    unreal_scene.tally(c,"varieties of landscape grass override materials on their mesh: a .pcg mesh layer draws the mesh's own materials",result.overridden)
    if len(s.layers)==0 {return}
    unreal_scene.zone(c,"foliage.grass_write")
    if !pcg.source_valid(&s) {
        unreal_scene.warn(c,"Grass: %d layers do not make a valid .pcg; landscape grass is left out",len(s.layers))
        return
    }
    id,path,info:=unreal_scene.asset_place(c,pcg.PCG_KIND,"Grass",0,pcg.PCG_EXTENSION)
    bytes,bytes_error:=pcg.source_bytes(&s,id,c.types,context.allocator,&info)
    if bytes_error!=.None {
        unreal_scene.warn(c,"Grass: its .pcg could not be written (%v)",bytes_error)
        return
    }
    defer delete(bytes)
    if !unreal_scene.asset_write(c,id,"Grass",path,bytes,fmt.tprintf("%d layers of grass",len(s.layers))) {return}
    place:=origin
    if result.bounded {place=(result.bounds.min+result.bounds.max)*0.5+origin}
    e,made:=unreal_scene.entity_make(c,0,"foliage|grass","Grass",{place,1,{1,1,1}})
    if !made {return}
    graph:=pcg.Pcg_Graph{source=id,world_anchored=true}
    unreal_scene.component_set(c,e,"Pcg_Graph",&graph)
    if result.bounded {
        half:=linalg.max((result.bounds.max-result.bounds.min)*0.5+1,[3]f32{1,1,1})
        box:=volume.box(half)
        unreal_scene.component_set(c,e,"Volume",&box)
    }
    shown:=foliage.Foliage{wind=result.wind,flutter=result.flutter,shadows=result.shadows,rays=false}
    unreal_scene.component_set(c,e,"Foliage",&shown)
    return
}

// The mesh of a variety, the materials it puts in its slots and the wind
// they sway it with, imported once.
@(private)
grass_look :: proc(c:^unreal_scene.Context,v:material.Grass_Variety,winds:^Winds) -> (look:Grass_Look) {
    if v.mesh=="" {return}
    m,ok:=unreal_scene.mesh_import(c,v.mesh)
    if !ok {return}
    look.mesh=m.id
    _,object:=unreal_scene.object_split(v.mesh)
    sway:=mesh_wind(c,winds,unreal.asset_name(object),v.mesh,v.materials)
    look.wind,look.flutter=sway.wind,sway.flutter
    if sway.wind>0 {winds_count(winds,sway,1)}
    for path,index in v.materials {
        if path=="" {continue}
        row,found:=slice.linear_search(m.slot_ids,u32(index+1))
        if !found || row>=render.MATERIAL_SLOTS {continue}
        if id,imported:=unreal_scene.material_import(c,path);imported && (row>=len(m.slot_materials) || id!=m.slot_materials[row]) {look.materials[row]=id}
    }
    return
}
