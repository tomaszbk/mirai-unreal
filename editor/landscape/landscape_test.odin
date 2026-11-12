package landscape

import "core:math/linalg"
import "core:testing"
import "project:plugins/unreal/editor/fixture"
import "project:plugins/unreal/editor/kraken"
import level "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

@(test)
a_landscape_becomes_one_grid_of_heights_layers_and_holes_in_mirai_space :: proc(t:^testing.T) {
    p:=fixture.landscape_map()
    lib:level.Library
    level.library_init(&lib,nil)
    defer level.library_destroy(&lib)
    map_index,_:=level.library_add(&lib,"/Game/Map",&p)
    d:level.Document
    if !testing.expect_value(t,level.document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer level.document_destroy(&d)
    decoder,_:=kraken.decoder_make()
    defer kraken.decoder_destroy(&decoder)
    list,error:=landscapes_read(&d,&decoder)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None) {return}
    defer landscapes_destroy(&list)
    if !testing.expect_value(t,len(list),1) {return}
    l:=list[0]
    testing.expect_value(t,l.components,2)
    // Five vertices along X (Mirai's -z) and three along Y (Mirai's x).
    testing.expect_value(t,l.samples,[2]int{3,5})
    testing.expect_value(t,l.spacing,f32(1))
    testing.expect_value(t,l.material,"/Game/M_Ground.M_Ground")
    // Unreal's vertex (x,y) is Mirai's sample (y, 4-x); 0.5 m per local unit at a Z scale of 50.
    for y in 0..=2 {for x in 0..=4 {
        expected:=f32(x+10*y)*0.5
        got:=l.heights[y+3*(4-x)]
        testing.expectf(t,abs(got-expected)<1e-4,"vertex %d,%d: %v, expected %v",x,y,got,expected)
    }}
    testing.expect(t,linalg.length(l.transform.position-[3]f32{21,3,-12})<1e-4,"the centre of the grid in the world")
    if testing.expect_value(t,len(l.layers),1) {
        testing.expect_value(t,l.layers[0].name,"Grass_LayerInfo")
        testing.expect_value(t,l.layers[0].info,"/Game/Map_sharedassets/Grass_LayerInfo.Grass_LayerInfo")
        testing.expect_value(t,l.weights[1+3*(4-0)],u8(0))
        testing.expect_value(t,l.weights[1+3*(4-2)],u8(255))
    }
    if testing.expect_value(t,len(l.holes),2*4) {
        for cell,i in l.holes {testing.expectf(t,cell==(i==0?1:0),"cell %d",i)}
    }
}

// A landscape scaled three times more along Unreal's Y than along its X is
// the same square grid, every metre, on a transform stretched three times
// across: each vertex where Unreal puts it.
@(test)
a_landscape_scaled_differently_along_x_and_y_is_its_grid_stretched_across :: proc(t:^testing.T) {
    p:=fixture.landscape_map({100,300,50})
    lib:level.Library
    level.library_init(&lib,nil)
    defer level.library_destroy(&lib)
    map_index,_:=level.library_add(&lib,"/Game/Map",&p)
    d:level.Document
    if !testing.expect_value(t,level.document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer level.document_destroy(&d)
    decoder,_:=kraken.decoder_make()
    defer kraken.decoder_destroy(&decoder)
    list,error:=landscapes_read(&d,&decoder)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None) || !testing.expect_value(t,len(list),1) {return}
    defer landscapes_destroy(&list)
    l:=list[0]
    testing.expect_value(t,l.spacing,f32(1))
    testing.expect_value(t,l.transform.scale,[3]f32{3,1,1})
    for y in 0..=2 {for x in 0..=4 {
        i,j:=y,4-x
        local:=[3]f32{(f32(i)-f32(l.samples.x-1)*0.5)*l.spacing,l.heights[i+l.samples.x*j],(f32(j)-f32(l.samples.y-1)*0.5)*l.spacing}
        got:=mm.transform_point(l.transform,local)
        expected:=level.point_to_mirai({f64(1000+100*x),f64(2000+300*y),f64(300+50*(x+10*y))})
        testing.expectf(t,linalg.length(got-expected)<1e-3,"vertex %d,%d: %v, expected %v",x,y,got,expected)
    }}
}
