package unreal_foliage_editor

import "core:math"
import "core:strings"
import "core:testing"
import volume "mirai:engine/volume"
import "project:plugins/unreal/editor/material"
import ufoliage "project:plugins/unreal/editor/foliage"
import "mirai:std/base"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"

@(test)
unreal_foliage_collects_placed_static_mesh_instances_with_exact_scale_and_bounds :: proc(t:^testing.T) {
    types:=[]ufoliage.Foliage_Type{
        {name="Fern",density=2.5,scale={{0.5,2},{1,1},{1,1}},casts_shadow=true},
        {name="Rock",density=0.1,collides=true,has_bounds=true,bounds={{0,0.5,0},{1,0.5,2}}},
    }
    turn:=mm.quat_axis_angle({0,1,0},1)
    instances:=[]ufoliage.Instance{
        {type=0,transform={position={1,2,3},rotation=turn,scale={2,2,2}},ground=-0.2,based=true,base=4},
        {type=1,transform={position={-40,0,70},rotation=1,scale={1,3,4}}},
        {type=1,transform={position={0,0,0},rotation=1,scale={0,1,1}}},
    }
    f:=ufoliage.Foliage{types=types,instances=instances}
    result:Foliage_Result
    defer foliage_result_destroy(&result)
    foliage_collect(&result,&f,{meshes={{1,2},{3,4}},winds={{wind=1.5,flutter=0.4},{}}},{})
    testing.expect_value(t,len(result.placed),2)
    testing.expect_value(t,result.dropped,1)
    fern:=result.placed[0]
    testing.expect_value(t,fern.mesh,base.Asset_Id{1,2})
    testing.expect_value(t,fern.transform.position,[3]f32{1,2,3})
    testing.expect_value(t,fern.transform.scale,[3]f32{2,2,2})
    testing.expect_value(t,fern.wind,f32(1.5))
    testing.expect_value(t,fern.flutter,f32(0.4))
    testing.expect(t,fern.casts_shadow && !fern.collides)
    rock:=result.placed[1]
    testing.expect_value(t,rock.mesh,base.Asset_Id{3,4})
    testing.expect_value(t,rock.transform.position,[3]f32{-40,0,70})
    testing.expect_value(t,rock.transform.scale,[3]f32{1,3,4})
    testing.expect(t,rock.collides && rock.box_center=={0,0.5,0} && rock.box_half=={1,0.5,2})
}

@(test)
instanced_components_collect_materials_bounds_and_transforms_from_origin :: proc(t:^testing.T) {
    rock:=Instanced_Type{name="Rock",mesh={1,1},casts_shadow=true,box_center={0,0.5,0},box_half={1,0.5,1}}
    mossy:=rock
    mossy.materials[0]={9,9}
    mossy.name="Mossy rock"
    batches:=[]Instanced_Batch{
        {type=rock,instances={{position={10,0,10},rotation=1,scale={1,1,1}},{position={40,1,10},rotation=1,scale={2,3,4}}}},
        {type=rock,instances={{position={12,0,10},rotation=1,scale={1,1,1}}}},
        {type=mossy,instances={{position={10,0,10},rotation=1,scale={0,1,1}},{position={11,0,11},rotation=1,scale={1,1,1}}}},
    }
    result:Foliage_Result
    defer foliage_result_destroy(&result)
    instanced_collect(&result,batches,{8,0,8})
    if !testing.expect_value(t,len(result.placed),4) {return}
    testing.expect_value(t,result.dropped,1)
    testing.expect_value(t,result.placed[0].transform.position,[3]f32{2,0,2})
    testing.expect(t,result.placed[0].materials[0]=={} && result.placed[0].collides && result.placed[0].box_half=={1,0.5,1})
    testing.expect_value(t,result.placed[1].transform.scale,[3]f32{2,3,4})
    testing.expect_value(t,result.placed[2].transform.position,[3]f32{4,0,2})
    testing.expect_value(t,result.placed[3].materials[0],base.Asset_Id{9,9})
    testing.expect_value(t,result.placed[3].transform.position,[3]f32{3,0,3})
}

// Types of actors and of ISM actors are not collected as static mesh foliage:
// their actors are actors of the level and their meshes instanced components;
// an instance of actors without its actor is told.
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
    result:Foliage_Result
    defer foliage_result_destroy(&result)
    foliage_collect(&result,&f,{meshes={{1,2},{},{}}},{})
    testing.expect_value(t,len(result.placed),1)
    testing.expect_value(t,result.unplaced,1)
    testing.expect_value(t,result.placed[0].mesh,base.Asset_Id{1,2})
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
        expected:=c.sine<0?f64(foliage.FOLIAGE_DEFAULT.wind):math.asin(c.sine/(1-SWAY_LEAST))/per_wind
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
