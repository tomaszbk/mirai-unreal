package unreal_terrain_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "project:plugins/unreal/editor/fixture"
import "project:plugins/unreal/editor/kraken"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import "project:plugins/unreal/editor/landscape"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"
import terrain "plugins:terrain/runtime"

@(test)
a_landscape_becomes_a_heightfield_that_keeps_four_layers_and_folds_the_rest :: proc(t:^testing.T) {
    l:landscape.Landscape
    l.samples={4,3}
    l.spacing=2
    l.subsection_quads=7
    l.transform={position={1,2,3},rotation=1,scale={1,1,1}}
    count:=l.samples.x*l.samples.y
    heights:=make([]f32,count,context.temp_allocator)
    for &h,i in heights {h=f32(i)*0.25-1}
    l.heights=heights
    holes:=make([]u8,3*2,context.temp_allocator)
    holes[1+3*1]=1
    l.holes=holes
    layers:=make([]landscape.Layer,6,context.temp_allocator)
    names:=[6]string{"A","B","C","D","E","F"}
    for &layer,i in layers {layer.name=names[i]}
    l.layers=layers
    // Sample k: A everywhere but the last row; B, C, D and E in a sample
    // each, E with some A; F, the lightest, only where D is.
    weights:=make([]u8,6*count,context.temp_allocator)
    for k in 0..<count {
        put :: proc(w:[]u8,count,layer,k:int,value:u8) {w[layer*count+k]=value}
        switch k {
        case 8:put(weights,count,1,k,255)
        case 9:put(weights,count,2,k,155)
        case 10:put(weights,count,3,k,255);put(weights,count,5,k,100)
        case 11:put(weights,count,4,k,200);put(weights,count,0,k,55)
        case:put(weights,count,0,k,255)
        }
    }
    l.weights=weights
    materials:=[]base.Asset_Id{{1,1},{2,2},{3,3},{4,4},{5,5},{6,6}}
    s:terrain.Source
    defer terrain.source_destroy(&s)
    result,ok:=landscape_terrain(&s,&l,{materials=materials})
    if !testing.expect(t,ok) {return}
    defer delete(result.folded)
    testing.expect_value(t,s.kind,terrain.Source_Kind.Heightfield)
    testing.expect_value(t,s.samples,[3]u32{4,1,3})
    testing.expect_value(t,s.cell,f32(2))
    testing.expect_value(t,s.chunk_cells,u32(7))
    testing.expect_value(t,result.transform.position,mm.Vec3{1,2,3})
    for k in 0..<count {testing.expect_value(t,terrain.source_value(&s,{k%4,0,k/4}),heights[k])}
    testing.expect(t,terrain.source_hole(&s,1,1) && !terrain.source_hole(&s,0,0),"the holes of the landscape")
    // By weight A, B and D (B first on the tie), E; C blends with none and goes to
    // the heaviest, F blends with D.
    testing.expect_value(t,s.layer_count,u32(4))
    testing.expect_value(t,result.layers,[4]int{0,1,3,4})
    testing.expect_value(t,result.folded[2],0)
    testing.expect_value(t,result.folded[5],2)
    testing.expect_value(t,terrain.grid_get(&s.weights,2,2),terrain.Weights{0,0,255,0})
    testing.expect_value(t,s.layers[1].material,materials[1])
    w9:=terrain.grid_get(&s.weights,1,2)
    testing.expect_value(t,int(w9[0])+int(w9[1])+int(w9[2])+int(w9[3]),terrain.WEIGHT_FULL)
    w11:=terrain.grid_get(&s.weights,3,2)
    testing.expect_value(t,w11,terrain.Weights{55,0,0,200})
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    bytes,error:=terrain.source_bytes(&s,{9,9},&types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    defer delete(bytes)
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None)
    defer asset.asset_close(&file)
    loaded:terrain.Source
    defer terrain.source_destroy(&loaded)
    _,read:=terrain.source_read(&loaded,&file,&types)
    testing.expect(t,read,"the source is a valid .terrain")
}

// The landscape of a level imported with the translator of the plugin: a
// .terrain of the level with the record of its import, shown by an entity
// with its label, and the same file and id when imported again.
@(test)
the_landscape_of_an_unreal_level_is_a_terrain_of_its_scene :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-unreal-%d",directory,os.get_pid())
    os.remove_all(root)
    defer os.remove_all(root)
    os.make_directory_all(root)
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    p:=fixture.landscape_map()
    lib:level.Library
    level.library_init(&lib,nil)
    defer level.library_destroy(&lib)
    map_index,_:=level.library_add(&lib,"/Game/Map",&p)
    d:level.Document
    if !testing.expect_value(t,level.document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer level.document_destroy(&d)
    provider:=terrain_unreal_default().provider
    os.make_directory_all(fmt.tprintf("%s/assets",root))
    source:=fmt.tprintf("%s/assets/Map.umap",root)
    _=os.write_entire_file(source,"map")
    ids:[2]base.Asset_Id
    for pass in 0..<2 {
        report,error:=unreal_scene.document_import(&d,source,100,7,{root=root},provider.translators[:provider.count])
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        defer unreal_scene.level_report_destroy(&report)
        written:importer.Written
        for a in report.imports.assets {if a.kind==terrain.KIND {written=a}}
        testing.expect(t,strings.has_suffix(written.path,"/assets/Map/Landscape.terrain"),written.path)
        ids[pass]=written.id
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        _,info,imported,peek_error:=asset.import_peek(written.path,&types)
        testing.expect(t,peek_error==.None && imported && base.text_get(info.name[:])=="Landscape","the terrain records its import")
        scene:asset.Scene
        if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
        defer asset.scene_destroy(&scene)
        shown:=false
        for row in 0..<asset.scene_entity_count(&scene) {
            e:=asset.scene_entity(&scene,row)
            if owner,ok:=asset.scene_get(&scene,e.id,"Terrain",terrain.Terrain);ok {shown=e.name=="Landscape" && owner.source==written.id}
        }
        testing.expect(t,shown,"an entity with the label of the landscape shows it")
    }
    testing.expect(t,ids[0]!={} && ids[0]==ids[1],"importing again writes the same terrain")
}

// The material of a landscape translated whole sees the paint layer of each
// layer of the terrain, and maps a point of the world (Unreal's centimetres)
// to the coordinates of the landscape: quads from its actor.
@(test)
a_landscape_maps_the_world_to_its_coordinates_and_its_layers_to_those_of_the_terrain :: proc(t:^testing.T) {
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
    list,error:=landscape.landscapes_read(&d,&decoder)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None) || !testing.expect_value(t,len(list),1) {return}
    defer landscape.landscapes_destroy(&list)
    s:terrain.Source
    defer terrain.source_destroy(&s)
    result,ok:=landscape_terrain(&s,&list[0],{})
    if !testing.expect(t,ok) {return}
    defer delete(result.folded)
    mapping:=landscape_mapping(&list[0],&result)
    testing.expect_value(t,mapping.layers[0],list[0].layers[0].name)
    testing.expect_value(t,mapping.layers[1],"")
    // The actor is at (1000,2000,300) with 100 cm a quad.
    for q in ([][2]f32{{0,0},{2,1},{4,2}}) {
        world:=[3]f32{1000+100*q.x,2000+100*q.y,300}
        for row in 0..<2 {
            r:=mapping.coordinates[row]
            got:=r.x*world.x+r.y*world.y+r.z*world.z+r.w
            testing.expectf(t,abs(got-q[row])<1e-3,"quad %v: %v along %d",q,got,row)
        }
    }
}

// A landscape scaled three times more along Unreal's Y than along its X is a
// Heightfield of square cells on an entity stretched three times across:
// each sample where Unreal puts its vertex, and the material still maps the
// world to the quads of the landscape.
@(test)
a_landscape_of_unequal_scales_is_a_square_heightfield_on_a_stretched_entity :: proc(t:^testing.T) {
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
    list,error:=landscape.landscapes_read(&d,&decoder)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None) || !testing.expect_value(t,len(list),1) {return}
    defer landscape.landscapes_destroy(&list)
    s:terrain.Source
    defer terrain.source_destroy(&s)
    result,ok:=landscape_terrain(&s,&list[0],{})
    if !testing.expect(t,ok) {return}
    defer delete(result.folded)
    testing.expect_value(t,s.cell,f32(1))
    testing.expect_value(t,result.transform.scale,[3]f32{3,1,1})
    for y in 0..=2 {for x in 0..=4 {
        got:=mm.transform_point(result.transform,terrain.source_point(&s,{y,0,4-x}))
        expected:=level.point_to_mirai({f64(1000+100*x),f64(2000+300*y),f64(300+50*(x+10*y))})
        testing.expectf(t,abs(got.x-expected.x)<1e-3 && abs(got.y-expected.y)<1e-3 && abs(got.z-expected.z)<1e-3,"vertex %d,%d: %v, expected %v",x,y,got,expected)
    }}
    mapping:=landscape_mapping(&list[0],&result)
    for q in ([][2]f32{{0,0},{2,1},{4,2}}) {
        world:=[3]f32{1000+100*q.x,2000+300*q.y,300}
        for row in 0..<2 {
            r:=mapping.coordinates[row]
            got:=r.x*world.x+r.y*world.y+r.z*world.z+r.w
            testing.expectf(t,abs(got-q[row])<1e-3,"quad %v: %v along %d",q,got,row)
        }
    }
}
