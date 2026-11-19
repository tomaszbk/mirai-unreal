package unreal_foliage_editor

import "core:math"
import "core:strings"
import "core:testing"
import "mirai:asset"
import volume "mirai:engine/volume"
import "project:plugins/unreal/editor/material"
import ufoliage "project:plugins/unreal/editor/foliage"
import "mirai:std/base"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"

@(test)
unreal_foliage_becomes_manual_instances_of_its_cells_with_their_ground :: proc(t:^testing.T) {
    types:=[]ufoliage.Foliage_Type{
        {name="Fern",density=2.5,scale={{0.5,2},{1,1},{1,1}},random_yaw=true,align_to_normal=true,cull={10,50},casts_shadow=true,ray_visible=true},
        {name="Rock",density=0.1,scale={{1,1},{1,1},{0.5,3}},scaling=.Free,collides=true,has_bounds=true,bounds={{0,0.5,0},{1,0.5,2}}},
    }
    turn:=mm.quat_axis_angle({0,1,0},1)
    instances:=[]ufoliage.Instance{
        {type=0,transform={position={1,2,3},rotation=turn,scale={2,2,2}},ground=-0.2,based=true,base=4},
        {type=1,transform={position={-40,0,70},rotation=1,scale={1,3,4}}},
        {type=1,transform={position={0,0,0},rotation=1,scale={0,1,1}}},
    }
    f:=ufoliage.Foliage{types=types,instances=instances}
    s:foliage.Source
    defer foliage.source_destroy(&s)
    result,ok:=foliage_source(&s,&f,{meshes={{1,2},{3,4}},winds={{wind=1.5},{}}})
    if !testing.expect(t,ok) {return}
    defer delete(result.types)
    testing.expect_value(t,len(s.types),2)
    testing.expect_value(t,result.averaged,1)
    testing.expect_value(t,result.dropped,1)
    fern:=s.types[0]
    testing.expect_value(t,fern.mesh,base.Asset_Id{1,2})
    testing.expect_value(t,fern.scale,[2]f32{0.5,2})
    testing.expect_value(t,fern.height,[2]f32{1,1})
    testing.expect_value(t,fern.cull_distance,f32(50))
    testing.expect_value(t,fern.fade_distance,f32(50)) // whole up to where it is gone, as Unreal draws it
    testing.expect_value(t,fern.wind,f32(1.5))
    testing.expect_value(t,fern.collision,foliage.Foliage_Collision.None)
    rock:=s.types[1]
    testing.expect_value(t,rock.wind,f32(0))
    testing.expect_value(t,rock.collision,foliage.Foliage_Collision.Box)
    testing.expect_value(t,rock.size,[3]f32{2,1,4})
    testing.expect_value(t,rock.height,[2]f32{0.5,3})
    testing.expect_value(t,len(s.cells),2)
    cell:=foliage.source_cell(&s,{0,0})
    if testing.expect(t,cell!=nil && len(cell.manual)==1) {
        b:=cell.manual[0]
        testing.expect_value(t,b.position,[3]f32{1,2,3})
        testing.expect_value(t,b.flags,foliage.INSTANCE_GROUNDED)
        testing.expect_value(t,b.ground,f32(-0.2))
        testing.expect_value(t,b.scale,[2]f32{2,2})
    }
    far:=foliage.source_cell(&s,{-2,2})
    if testing.expect(t,far!=nil && len(far.manual)==1) {
        testing.expect_value(t,far.manual[0].scale,[2]f32{2,3})
        testing.expect_value(t,far.manual[0].flags,u32(0))
    }
    asset_types:asset.Types;asset.types_init(&asset_types);defer asset.types_destroy(&asset_types)
    bytes,error:=foliage.source_bytes(&s,{7,7},&asset_types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    defer delete(bytes)
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None)
    defer asset.asset_close(&file)
    loaded:foliage.Source
    defer foliage.source_destroy(&loaded)
    _,read:=foliage.source_read(&loaded,&file,&asset_types)
    testing.expect(t,read,"the source is a valid .foliage")
}

@(test)
instanced_components_are_one_type_for_each_mesh_and_materials_with_instances_from_the_origin :: proc(t:^testing.T) {
    rock:=Instanced_Type{name="Rock",mesh={1,1},cull_distance=200,casts_shadow=true,ray_visible=true,size={2,1,2}}
    mossy:=rock
    mossy.materials[0]={9,9}
    mossy.name="Mossy rock"
    batches:=[]Instanced_Batch{
        {type=rock,instances={{position={10,0,10},rotation=1,scale={1,1,1}},{position={40,1,10},rotation=1,scale={2,3,4}}}},
        {type=rock,instances={{position={12,0,10},rotation=1,scale={1,1,1}}}},
        {type=mossy,instances={{position={10,0,10},rotation=1,scale={0,1,1}},{position={11,0,11},rotation=1,scale={1,1,1}}}},
    }
    s:foliage.Source
    defer foliage.source_destroy(&s)
    result:Foliage_Source
    instanced_add(&s,batches,{8,0,8},&result)
    if !testing.expect_value(t,len(s.types),2) {return}
    testing.expect(t,s.types[0].mesh==base.Asset_Id{1,1} && s.types[0].materials[0]=={},"the mesh's own materials")
    testing.expect_value(t,s.types[1].materials[0],base.Asset_Id{9,9})
    testing.expect_value(t,s.types[0].density,f32(0))
    testing.expect_value(t,s.types[0].cull_distance,f32(200))
    testing.expect_value(t,s.types[0].fade_distance,f32(200))
    testing.expect_value(t,s.types[0].collision,foliage.Foliage_Collision.Box)
    testing.expect_value(t,s.types[0].size,[3]f32{2,1,2})
    testing.expect_value(t,result.dropped,1)
    testing.expect_value(t,result.averaged,1)
    near:=foliage.source_cell(&s,{0,0})
    if testing.expect(t,near!=nil && len(near.manual)==3,"two rocks and a mossy one in the first cell, from the origin") {
        testing.expect_value(t,near.manual[0].position,[3]f32{2,0,2})
        testing.expect_value(t,near.manual[1].position,[3]f32{4,0,2})
        testing.expect_value(t,near.manual[2].type,s.types[1].id)
    }
    far:=foliage.source_cell(&s,{1,0})
    if testing.expect(t,far!=nil && len(far.manual)==1) {
        testing.expect_value(t,far.manual[0].scale,[2]f32{f32(math.sqrt(f64(8))),3})
    }
    testing.expect(t,foliage.source_valid(&s))
}

@(test)
a_reimported_level_keeps_the_ids_of_the_foliage_it_had :: proc(t:^testing.T) {
    turn:=mm.quat_axis_angle({0,1,0},0.5)
    import_of :: proc(types:[]ufoliage.Foliage_Type,meshes:[]base.Asset_Id,instances:[]ufoliage.Instance,s:^foliage.Source) -> bool {
        f:=ufoliage.Foliage{types=types,instances=instances}
        result,ok:=foliage_source(s,&f,{meshes=meshes})
        delete(result.types)
        return ok
    }
    id_at :: proc(s:^foliage.Source,position:[3]f32) -> u32 {
        coord,local:=foliage.cell_of(position)
        cell:=foliage.source_cell(s,coord)
        if cell==nil {return 0}
        for b in cell.manual {if abs(b.position.x-local.x)<1e-3 && abs(b.position.z-local.z)<1e-3 {return b.id}}
        return 0
    }
    before:foliage.Source
    defer foliage.source_destroy(&before)
    ok:=import_of(
        {{name="Fern",density=1,scale={{1,1},{1,1},{1,1}}},{name="Rock",density=1,scale={{1,1},{1,1},{1,1}}}},
        {{1,1},{2,2}},
        {
            {type=0,transform={position={1,0,1},rotation=turn,scale={1,1,1}}},
            {type=0,transform={position={1.5,0,1},rotation=turn,scale={1,1,1}}},
            {type=1,transform={position={10,0,10},rotation=1,scale={2,2,2}}},
            {type=1,transform={position={40,0,10},rotation=1,scale={1,1,1}}},
            {type=0,transform={position={1.2,0,1},rotation=1,scale={1,1,1}}},
        },&before)
    if !testing.expect(t,ok) {return}
    fern,rock,near_fern,moved,gone,far_rock:=before.types[0].id,before.types[1].id,id_at(&before,{1,0,1}),id_at(&before,{1.5,0,1}),id_at(&before,{1.2,0,1}),id_at(&before,{40,0,10})
    kept_rock:=id_at(&before,{10,0,10})

    // Unreal changed the level: the types in another order and one more, a
    // fern moved far, one taken out, a new rock, the others where they were
    // (within what an import rounds).
    after:foliage.Source
    defer foliage.source_destroy(&after)
    ok=import_of(
        {{name="Bush",density=1,scale={{1,1},{1,1},{1,1}}},{name="Rock",density=1,scale={{1,1},{1,1},{1,1}}},{name="Fern",density=2,scale={{1,1},{1,1},{1,1}}}},
        {{3,3},{2,2},{1,1}},
        {
            {type=1,transform={position={40,0,10},rotation=1,scale={1,1,1}}},
            {type=2,transform={position={1.5,0,9},rotation=turn,scale={1,1,1}}},
            {type=2,transform={position={1.001,0,1},rotation=turn,scale={1,1,1}}},
            {type=1,transform={position={10,0,10.01},rotation=1,scale={2,2,2}}},
            {type=1,transform={position={11,0,10},rotation=1,scale={1,1,1}}},
            {type=0,transform={position={3,0,3},rotation=1,scale={1,1,1}}},
        },&after)
    if !testing.expect(t,ok) {return}
    if !testing.expect(t,foliage_ids_keep(&after,&before)) {return}
    testing.expect(t,foliage.source_valid(&after),"the source with the ids kept is valid")
    testing.expect_value(t,after.types[2].id,fern)
    testing.expect_value(t,after.types[1].id,rock)
    testing.expect_value(t,after.types[0].id,before.info.next_type)
    testing.expect_value(t,after.info.next_type,before.info.next_type+1)
    testing.expect_value(t,id_at(&after,{1.001,0,1}),near_fern)
    testing.expect_value(t,id_at(&after,{10,0,10.01}),kept_rock)
    testing.expect_value(t,id_at(&after,{40,0,10}),far_rock)
    moved_now,new_rock,bush:=id_at(&after,{1.5,0,9}),id_at(&after,{11,0,10}),id_at(&after,{3,0,3})
    for id in ([]u32{moved_now,new_rock,bush}) {
        testing.expect(t,id>before.info.instances,"what the import before did not have takes an id it never gave")
        testing.expect(t,id!=gone && id!=moved,"an id taken out is not given again")
    }
    testing.expect(t,moved_now!=new_rock && new_rock!=bush && moved_now!=bush)
    testing.expect_value(t,after.info.instances,before.info.instances+3)
}

// Types of actors and of ISM actors are not types of the source: their
// actors are actors of the level and their meshes instanced components; an
// instance of actors without its actor is told.
@(test)
unreal_foliage_of_actors_adds_only_its_static_mesh_types :: proc(t:^testing.T) {
    types:=[]ufoliage.Foliage_Type{
        {name="Fern",density=1,scale={{1,1},{1,1},{1,1}}},
        {name="Tree",kind=.Actor,actor_class="/Game/BP_Tree.BP_Tree_C"},
        {name="Bush",kind=.ISM_Actor,actor_class="/Game/BP_Bush.BP_Bush_C"},
    }
    instances:=[]ufoliage.Instance{
        {type=0,transform={position={1,0,1},rotation=1,scale={1,1,1}},actor=-1},
        {type=1,transform={position={2,0,2},rotation=1,scale={1,1,1}},actor=4},
        {type=1,transform={position={3,0,3},rotation=1,scale={1,1,1}},actor=-1},
        {type=2,transform={position={4,0,4},rotation=1,scale={1,1,1}},actor=-1},
    }
    f:=ufoliage.Foliage{types=types,instances=instances}
    s:foliage.Source
    defer foliage.source_destroy(&s)
    result,ok:=foliage_source(&s,&f,{meshes={{1,2},{},{}}})
    if !testing.expect(t,ok) {return}
    defer delete(result.types)
    testing.expect_value(t,len(s.types),1)
    testing.expect_value(t,result.types[1],u32(0))
    testing.expect_value(t,result.unplaced,1)
    cell:=foliage.source_cell(&s,{0,0})
    testing.expect(t,cell!=nil && len(cell.manual)==1,"only the instance of the fern")
}

// A type sways, in a Wind of Mirai's speed, from its least lean to its peak
// by the swing whose bend best matches, in least squares over the vertices
// of its mesh, how far its materials sway them slower than a second; what
// they move faster is the flutter of its leaves, which bends nothing. A
// material that moves its vertices by other than wind sways nothing and is a
// warning; one whose sway cannot be measured sways by Mirai's default wind.
@(test)
a_type_sways_as_its_materials_sway_its_mesh :: proc(t:^testing.T) {
    Part :: struct {offset:material.Offset,heights:[]f32,reach:[]material.Offset_Reach}
    Case :: struct {
        name:string,
        parts:[]Part,
        sine:f64,        // of the swing of the lean the rule gives; -1: Mirai's default wind
        flutter:f64,     // centimetres its leaves flutter on average
        warned:[]string, // what the warnings of its materials say
    }
    gusts:=material.Offset{kind=.Wind,names={"MF_FoliageWind_Sway","Wind Intensity"},weights={.Vertex_Color},textured=true}
    wind:=material.Offset{kind=.Wind}
    cases:=[]Case{
        {"grass",{{gusts,{100,0},{{3.2,0},{}}}},0.032,0,{"vertex colors","texture"}},
        {"tree",{{wind,{100},{{3.2,0}}},{{},{50},{{}}}},0.0256,0,nil},
        // A trunk that sways and leaves that sway with it and flutter 5 cm on top.
        {"leafy tree",{{wind,{1000,0},{{32,0},{}}},{wind,{1000,800},{{32,5},{25.6,5}}}},0.032,5,nil},
        {"rock",{{{},{100},{{}}}},0,0,nil},
        {"flag",{{material.Offset{kind=.Motion,names={"MF_FlagWave"}},{100},{{3.2,0}}}},0,0,{"MF_FlagWave","not wind"}},
        {"pulse",{{material.Offset{kind=.Shape},{100},{{}}}},0,0,{"without time"}},
        {"custom",{{material.Offset{kind=.Wind,why="it reads noise"},{100},{{-1,-1}}}},-1,0,{"could not be measured"}},
    }
    per_wind:=f64(foliage.FOLIAGE_SWAY)*0.1*f64(volume.WIND_DEFAULT.speed) // radians of lean per wind at its peak
    per_flutter:=FLUTTER_MEAN*f64(foliage.FOLIAGE_FLUTTER)*f64(volume.WIND_DEFAULT.speed)*100 // centimetres a leaf flutters on average per flutter
    for c in cases {
        s:Sway
        warnings:=make([dynamic]string,context.temp_allocator)
        for part in c.parts {
            vertices:=make([]material.Offset_Vertex,len(part.heights),context.temp_allocator)
            for &v,i in vertices {v.position.z=part.heights[i]}
            sway_add(&s,part.offset,vertices,part.reach)
            append(&warnings,..offset_warnings(c.name,"/Game/M/M_Part",part.offset))
        }
        wind:=sway_wind(s)
        expected:=c.sine<0?f64(foliage.FOLIAGE_TYPE_DEFAULT.wind):math.asin(c.sine/(1-SWAY_LEAST))/per_wind
        testing.expectf(t,abs(f64(wind)-expected)<=1e-5*max(expected,1),"%s: wind %v, not %v",c.name,wind,expected)
        flutter:=sway_flutter(s)
        testing.expectf(t,abs(f64(flutter)-c.flutter/per_flutter)<=1e-5,"%s: flutter %v, not %v",c.name,flutter,c.flutter/per_flutter)
        testing.expectf(t,(len(c.warned)==0)==(len(warnings)==0),"%s: warnings %v",c.name,warnings[:])
        for text in c.warned {
            found:=false
            for w in warnings {found||=strings.contains(w,text)}
            testing.expectf(t,found,"%s: a warning says %q: %v",c.name,text,warnings[:])
        }
    }
}

// The Wind blows the way and at the pace of the foliage that moves most of
// the air: each type by its instances times how much it is moved, so a
// forest leads the many tufts of grass that sway another way.
@(test)
the_wind_blows_the_way_the_foliage_that_moves_most_is_moved :: proc(t:^testing.T) {
    w:=winds_make()
    winds_count(&w,{wind=1.5,direction={1,0},frequency=0.18,moved=38000},400)
    winds_count(&w,{wind=12,direction={-0.7071,-0.7071},frequency=0.2,moved=600},11000)
    winds_count(&w,{wind=0,direction={0,1},frequency=1,moved=1e6},1000)
    length:=math.sqrt(w.blown.x*w.blown.x+w.blown.y*w.blown.y)
    way:=w.blown/length
    tree,grass:=400*38000.0,11000*600.0
    expected:=[2]f64{tree-grass*0.7071,-grass*0.7071}
    expected/=math.sqrt(expected.x*expected.x+expected.y*expected.y)
    testing.expectf(t,abs(way.x-expected.x)<1e-4 && abs(way.y-expected.y)<1e-4 && way.x>0.9,"the wind blows %v, not %v",way,expected)
    pace:=w.paced.x/w.paced.y
    testing.expectf(t,abs(pace-(0.18*tree+0.2*grass)/(tree+grass))<1e-6,"the gusts are %v a second",pace)
}
