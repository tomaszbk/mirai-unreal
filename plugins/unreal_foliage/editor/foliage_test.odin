package unreal_foliage_editor

import "core:math"
import "core:testing"
import "mirai:asset"
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
    result,ok:=foliage_source(&s,&f,{meshes={{1,2},{3,4}}})
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
    testing.expect_value(t,fern.fade_distance,f32(10))
    testing.expect_value(t,fern.wind,f32(0))
    testing.expect_value(t,fern.collision,foliage.Foliage_Collision.None)
    rock:=s.types[1]
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
    rock:=Instanced_Type{name="Rock",mesh={1,1},fade_distance=100,cull_distance=200,casts_shadow=true,ray_visible=true,size={2,1,2}}
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
