package unreal_foliage_editor

import "core:testing"
import "mirai:asset"
import "project:plugins/unreal/editor/landscape"
import material "project:plugins/unreal/editor/material"
import "mirai:std/base"
import pcg "plugins:pcg/runtime"

// A landscape 80 by 40 metres whose two western columns of quads are painted
// Meadow, whose grass grows a shadowing variety (Meso) and a non-shadowing
// variety (Micro, scattered on the GPU); the zero-density variety is skipped.
// Equal varieties across landscapes of one material deduplicate into one layer,
// and bounds wrap only the Meadow quads.
@(test)
landscape_grass_is_a_pcg_layer_on_its_terrain_layer_with_tight_bounds :: proc(t:^testing.T) {
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
    tuft:=meadow
    tuft.casts_shadow=false
    tuft.density=3
    bare:=meadow
    bare.density=0
    grass:=[]material.Landscape_Grass{{name="Meadow",type="/Game/G/GT_Meadow.GT_Meadow",layers={"Meadow"},fit={slope={0,1},weight=0.3,ok=true},varieties={meadow,tuft,bare}}}
    looks:=[][]Grass_Look{{{mesh={7,7},wind=1.2,flutter=0.3},{mesh={8,8},wind=1.2,flutter=0.3},{mesh={7,7}}}}
    each:=Grass_Landscape{&l,grass,{{1,1},{2,2}},looks}
    s:pcg.Pcg_Source
    pcg.source_init(&s)
    defer pcg.source_destroy(&s)
    result,ok:=grass_add(&s,{each,each},{64,0,0})
    if !testing.expect(t,ok) || !testing.expect_value(t,len(s.layers),2) {return}
    testing.expect_value(t,result.layers,2)
    testing.expect(t,result.shadows && result.bounded)
    testing.expect(t,abs(result.wind-1.2)<1e-5 && abs(result.flutter-0.3)<1e-5)
    g:=s.layers[0]
    testing.expect_value(t,g.tier,pcg.Pcg_Tier.Meso)
    testing.expect_value(t,g.asset,base.Asset_Id{7,7})
    testing.expect_value(t,g.density,f32(1.5))
    testing.expect(t,g.ground_rule.enabled && g.ground_rule.layers=={0={1,1}} && g.ground_rule.weight==0.3 && g.ground_rule.slope=={0,1})
    testing.expect(t,g.scale=={0.8,1.2} && abs(g.height[0]-0.8/1.2)<1e-6 && abs(g.height[1]-1.3/0.8)<1e-6)
    testing.expect(t,g.yaw>0 && g.align==1 && g.cull_distance==100 && g.fade_distance==100 && g.filler && !g.collides)
    micro:=s.layers[1]
    testing.expect_value(t,micro.tier,pcg.Pcg_Tier.Micro)
    testing.expect_value(t,micro.asset,base.Asset_Id{8,8})
    // Meadow spans x -4 to 16 from the origin, z 30 to 70.
    testing.expect_value(t,result.bounds.min.x,f32(-4))
    testing.expect_value(t,result.bounds.max.x,f32(16))
    testing.expect_value(t,result.bounds.min.z,f32(30))
    testing.expect_value(t,result.bounds.max.z,f32(70))
    testing.expect(t,pcg.source_valid(&s))
    asset_types:asset.Types;asset.types_init(&asset_types);defer asset.types_destroy(&asset_types)
    bytes,err:=pcg.source_bytes(&s,{7,7},&asset_types)
    if !testing.expect_value(t,err,asset.Error.None) {return}
    defer delete(bytes)
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None)
    defer asset.asset_close(&file)
    loaded:pcg.Pcg_Source
    defer pcg.source_destroy(&loaded)
    _,issue:=pcg.source_read(&loaded,&file,&asset_types)
    testing.expect_value(t,issue.kind,pcg.Pcg_Issue_Kind.None)
}
