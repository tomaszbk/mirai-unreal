package unreal_foliage_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import render "mirai:engine/render"
import ufoliage "project:plugins/unreal/editor/foliage"
import "project:plugins/unreal/editor/landscape"
import "project:plugins/unreal/editor/level"
import material "project:plugins/unreal/editor/material"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"

// The grass of the landscapes of a level, in the source of the scene of the
// map: each variety of each grass type their materials name is a type the
// generator scatters, its rule on the layers of the terrain whose weight its
// input reads (by their materials) and as dense as they weigh there, and the
// cells where those layers are painted generate. An input that weighs more
// than its layers (a contrast, the slope, a texture) grows as densely as
// they do alone.

// What a variety shows.
Grass_Look :: struct {
    mesh:base.Asset_Id,
    materials:[render.MATERIAL_SLOTS]base.Asset_Id, // those its slots override; none: the mesh's
}

// A landscape and its grass, as its terrain shows it.
Grass_Landscape :: struct {
    landscape:^landscape.Landscape,
    grass:[]material.Landscape_Grass,
    layers:[]base.Asset_Id, // the material of each paint layer of the landscape on its terrain, in its order; zero for none
    looks:[][]Grass_Look,   // of each variety of each grass; one without a mesh is left out
}

Grass_Result :: struct {
    types:int,     // generated types added
    cells:int,     // cells that came to generate
    unlayered:int, // varieties on layers its terrain shows without a material, left out
    folded:int,    // varieties on more layers than a rule names: they grow on those of most weight
    weighed:int,   // varieties whose input weighs more than its layers
}

// Adds the grass of the landscapes to s, where they are from origin. Once a
// cell generates, the types s held before have density 0: what Unreal placed
// of them is all there is. False past TYPES_MAX or CELLS_MAX.
grass_add :: proc(s:^foliage.Source,landscapes:[]Grass_Landscape,origin:[3]f32) -> (result:Grass_Result,ok:bool) {
    held:=len(s.types)
    Candidate :: struct {material:base.Asset_Id,coverage:f32,layer:int}
    for gl in landscapes {
        l:=gl.landscape
        // The layers of the landscape whose weight some grass reads; all of it when one reads none.
        driving:=make([]bool,len(l.layers),context.temp_allocator)
        everywhere:=false
        for g,i in gl.grass {
            _,object:=unreal_scene.object_split(g.type)
            name:=unreal.asset_name(object)
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
                t:=foliage.FOLIAGE_TYPE_DEFAULT
                t.mesh,t.materials=look.mesh,look.materials
                scaling:=ufoliage.Scaling.Uniform
                switch v.scaling {
                case .Uniform:
                case .Free:scaling=.Free
                case .Lock_XY:scaling=.Lock_XY
                }
                type_from(&t,{density=v.density,scale=v.scale,scaling=scaling,random_yaw=v.random_rotation,align_to_normal=v.align,cull=v.cull,casts_shadow=v.casts_shadow})
                t.rule.enabled=len(candidates)>0
                t.rule.weight=clamp(v.weights[0],0,1)
                kept:=0
                for candidate in candidates {
                    if slice.contains(t.rule.layers[:kept],candidate.material) {driving[candidate.layer]=true;continue}
                    if kept==foliage.RULE_LAYERS {continue}
                    t.rule.layers[kept]=candidate.material
                    kept+=1
                    driving[candidate.layer]=true
                }
                for candidate in candidates {if !slice.contains(t.rule.layers[:kept],candidate.material) {result.folded+=1;break}}
                everywhere||=len(candidates)==0
                if !g.plain {result.weighed+=1}
                // Equal varieties of the landscapes of one material are one type.
                same:=false
                for existing in s.types[held:] {
                    alike:=t
                    alike.id,alike.name=existing.id,existing.name
                    if alike==existing {same=true;break}
                }
                if same {continue}
                if len(s.types)>=foliage.TYPES_MAX {return}
                added:=foliage.source_type_add(s,len(g.varieties)>1?fmt.tprintf("%s_%d",name,j+1):name,t.mesh)
                if added==nil {return}
                t.id,t.name=added.id,added.name
                added^=t
                result.types+=1
            }
        }
        cells:=grass_cells(s,l,driving,everywhere,origin) or_return
        result.cells+=cells
    }
    if result.cells>0 {for &t in s.types[:held] {t.density=0}}
    return result,true
}

// Turns on the generator of the cells over the quads of the landscape where
// a driving layer weighs at a corner, or of every quad when everywhere,
// holes left out. How many came to generate; false past CELLS_MAX.
@(private)
grass_cells :: proc(s:^foliage.Source,l:^landscape.Landscape,driving:[]bool,everywhere:bool,origin:[3]f32) -> (cells:int,ok:bool) {
    n:=l.samples
    count:=n.x*n.y
    if n.x<2 || n.y<2 || !(l.spacing>0) || !everywhere && !slice.contains(driving,true) {return 0,true}
    weighed:=make([]bool,count,context.temp_allocator)
    for &w,k in weighed {
        w=everywhere
        for on,layer in driving {
            if w {break}
            w=on && layer*count+k<len(l.weights) && l.weights[layer*count+k]>0
        }
    }
    quads:=[2]int{n.x-1,n.y-1}
    grows:=make([]bool,quads.x*quads.y,context.temp_allocator)
    for j in 0..<quads.y {for i in 0..<quads.x {
        q:=i+quads.x*j
        if len(l.holes)==len(grows) && l.holes[q]!=0 {continue}
        k:=i+n.x*j
        grows[q]=weighed[k] || weighed[k+1] || weighed[k+n.x] || weighed[k+n.x+1]
    }}
    // Samples are spacing apart about the place of the landscape, as its terrain lays them.
    half:=[2]f32{f32(quads.x),f32(quads.y)}*0.5
    low,high:=[3]f32{max(f32),0,max(f32)},[3]f32{-max(f32),0,-max(f32)}
    for corner in ([4][2]f32{{0,0},{1,0},{0,1},{1,1}}) {
        local:=[3]f32{(corner.x*f32(quads.x)-half.x)*l.spacing,0,(corner.y*f32(quads.y)-half.y)*l.spacing}
        p:=mm.transform_point(l.transform,local)-origin
        low,high=linalg.min(low,p),linalg.max(high,p)
    }
    if !(low.x>=-foliage.POSITION_MAX && high.x<=foliage.POSITION_MAX && low.z>=-foliage.POSITION_MAX && high.z<=foliage.POSITION_MAX) {return}
    first,_:=foliage.cell_of(low)
    last,_:=foliage.cell_of(high)
    if i64(last.x-first.x+1)*i64(last.y-first.y+1)>i64(foliage.CELLS_MAX) {return}
    for z in first.y..=last.y {for x in first.x..=last.x {
        // The quads under the cell: those between its corners in the coordinates of the landscape.
        at:=foliage.cell_corner({x,z})+origin
        at.y=l.transform.position.y
        u_low,u_high:=[2]f32{max(f32),max(f32)},[2]f32{-max(f32),-max(f32)}
        for corner in ([4][2]f32{{0,0},{1,0},{0,1},{1,1}}) {
            local:=mm.transform_inverse_point(l.transform,at+{corner.x,0,corner.y}*foliage.CELL_SIZE)
            u:=[2]f32{local.x/l.spacing,local.z/l.spacing}+half
            u_low,u_high=linalg.min(u_low,u),linalg.max(u_high,u)
        }
        i0,i1:=max(int(math.floor(u_low.x)),0),min(int(math.ceil(u_high.x)),quads.x)
        j0,j1:=max(int(math.floor(u_low.y)),0),min(int(math.ceil(u_high.y)),quads.y)
        found:=false
        for j in j0..<j1 {
            if found {break}
            for i in i0..<i1 {if grows[i+quads.x*j] {found=true;break}}
        }
        if found && foliage.source_cell_generate(s,{x,z},true) {cells+=1}
    }}
    return cells,true
}

// The grass of the landscapes of the level into s, the source of the scene
// of the map, where they are from origin; their meshes and the materials of
// their slots imported as the other meshes of the level.
@(private)
grass_translate :: proc(c:^unreal_scene.Context,s:^foliage.Source,origin:[3]f32) -> (result:Grass_Result) {
    d:=c.d
    by_material:=make(map[string][]material.Landscape_Grass,context.temp_allocator)
    some:=false
    for a in landscape.landscape_actors(d) {
        path:=level.path_of(d,d.actors[a].ref,"LandscapeMaterial")
        if path=="" || path in by_material {continue}
        grass:=unreal_scene.landscape_grass(c,path)
        by_material[strings.clone(path,context.temp_allocator)]=grass
        for g in grass {
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
            for v,j in g.varieties {looks[i][j]=grass_look(c,v)}
        }
        append(&inputs,Grass_Landscape{&l,grass,layers,looks})
    }
    ok:bool
    result,ok=grass_add(s,inputs[:],origin)
    if !ok {unreal_scene.warn(c,"the grass of the landscapes does not fit in a .foliage (%d types, %d cells at most); some is left out",foliage.TYPES_MAX,foliage.CELLS_MAX)}
    unreal_scene.tally(c,"varieties of landscape grass grow on paint layers whose terrain layer has no material, and are left out",result.unlayered)
    unreal_scene.tally(c,fmt.tprintf("varieties of landscape grass read more paint layers than the %d a foliage rule names, and grow on those of most weight",foliage.RULE_LAYERS),result.folded)
    unreal_scene.tally(c,"varieties of landscape grass weigh more than their paint layers (a contrast, the slope, a texture), and grow as densely as those layers alone",result.weighed)
    return
}

// The mesh of a variety and the materials it puts in its slots, imported once.
@(private)
grass_look :: proc(c:^unreal_scene.Context,v:material.Grass_Variety) -> (look:Grass_Look) {
    if v.mesh=="" {return}
    m,ok:=unreal_scene.mesh_import(c,v.mesh)
    if !ok {return}
    look.mesh=m.id
    for path,index in v.materials {
        if path=="" {continue}
        row,found:=slice.linear_search(m.slot_ids,u32(index+1))
        if !found || row>=render.MATERIAL_SLOTS {continue}
        if id,imported:=unreal_scene.material_import(c,path);imported && (row>=len(m.slot_materials) || id!=m.slot_materials[row]) {look.materials[row]=id}
    }
    return
}
