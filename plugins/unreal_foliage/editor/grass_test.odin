package unreal_foliage_editor

import "core:testing"
import "project:plugins/unreal/editor/landscape"
import material "project:plugins/unreal/editor/material"
import "mirai:std/base"
import foliage "plugins:foliage/runtime"

// A landscape 80 by 40 metres whose two western columns of quads are
// painted Meadow, whose grass grows one variety (the other has no density):
// a generated type of its mesh on the layer of the material of Meadow, on
// the slopes and from the weight its input fits, as dense as Meadow weighs;
// only the cells over Meadow generate, and the
// painted type the source held before generates nothing. The same grass of
// another landscape of the material is the same type.
@(test)
landscape_grass_is_a_generated_type_on_its_layer_over_the_cells_where_it_is_painted :: proc(t:^testing.T) {
    l:landscape.Landscape
    l.samples={9,5}
    l.spacing=10
    l.transform={position={100,5,50},rotation=1,scale={1,1,1}}
    count:=l.samples.x*l.samples.y
    l.layers={{name="Meadow",coverage=0.25},{name="Rock",coverage=0.75}}
    weights:=make([]u8,2*count,context.temp_allocator)
    for k in 0..<count {weights[(k%l.samples.x<=1?0:1)*count+k]=255}
    l.weights=weights
    meadow:=material.Grass_Variety{mesh="/Game/G/SM_Blades.SM_Blades",density=1.5,scaling=.Free,scale={{0.8,1.2},{1,1},{0.8,1.3}},weights={0.2,1},random_rotation=true,align=true,cull={1,100},casts_shadow=true}
    bare:=meadow
    bare.density=0
    grass:=[]material.Landscape_Grass{{name="Meadow",type="/Game/G/GT_Meadow.GT_Meadow",layers={"Meadow"},fit={slope={0,1},weight=0.3,ok=true},varieties={meadow,bare}}}
    looks:=[][]Grass_Look{{{mesh={7,7}},{mesh={7,7}}}}
    each:=Grass_Landscape{&l,grass,{{1,1},{2,2}},looks}
    s:foliage.Source
    defer foliage.source_destroy(&s)
    foliage.source_type_add(&s,"Fern",{3,3}).density=2
    result,ok:=grass_add(&s,{each,each},{64,0,0})
    if !testing.expect(t,ok) || !testing.expect_value(t,len(s.types),2) {return}
    testing.expect_value(t,result.types,1)
    testing.expect_value(t,s.types[0].density,f32(0))
    g:=s.types[1]
    testing.expect_value(t,g.mesh,base.Asset_Id{7,7})
    testing.expect_value(t,g.density,f32(1.5))
    testing.expect(t,g.rule.enabled && g.rule.layers=={0={1,1}} && g.rule.weight==0.3 && g.rule.slope=={0,1},"it grows on Meadow up to the slope of its input, as dense as Meadow weighs from 0.3")
    testing.expect(t,g.scale=={0.8,1.2} && abs(g.height[0]-0.8/1.2)<1e-6 && abs(g.height[1]-1.3/0.8)<1e-6)
    testing.expect(t,g.yaw>0 && g.align==1 && g.cull_distance==100 && g.fade_distance==1 && g.casts_shadow && !g.ray_visible)
    // Meadow spans x -4 to 16 from the origin, z 30 to 70: cells -1 and 0 across, 0 to 2 down.
    testing.expect_value(t,result.cells,6)
    for z in i32(0)..=2 {for x in i32(-1)..=2 {
        cell:=foliage.source_cell(&s,{x,z})
        testing.expectf(t,(cell!=nil && cell.generate)==(x<=0),"cell %v",[2]i32{x,z})
    }}
    testing.expect(t,foliage.source_valid(&s))
}
