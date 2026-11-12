package level

import "core:testing"
import "project:plugins/unreal/editor/fixture"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

@(private="file")
close_box :: proc(a,b:mm.Aabb) -> bool {
    for axis in 0..<3 {
        if abs(a.min[axis]-b.min[axis])>1e-3 || abs(a.max[axis]-b.max[axis])>1e-3 {return false}
    }
    return true
}

@(test)
an_actor_goes_to_the_cell_of_its_center_at_the_level_its_size_asks :: proc(t:^testing.T) {
    g:=Grid{kind=.Grid,cell_size=25600,loading_range=51200}
    level,coord:=cell_of(g,{{100,100,100},{300,300,300}})
    testing.expect_value(t,level,0)
    testing.expect_value(t,coord,[3]i64{0,0,0})
    level,coord=cell_of(g,{{-300,100,-30000},{-100,300,-29000}})
    testing.expect_value(t,coord,[3]i64{-1,0,-2})
    // Past its cell by less than a quarter of it: it stays at level 0.
    level,coord=cell_of(g,{{1000,1000,1000},{31000,2000,2000}})
    testing.expect_value(t,level,0)
    testing.expect_value(t,coord,[3]i64{0,0,0})
    // Past it by more: the cell of level 1, twice as wide, that holds its center.
    level,coord=cell_of(g,{{0,0,0},{40000,100,100}})
    testing.expect_value(t,level,1)
    testing.expect_value(t,coord,[3]i64{0,0,0})
    level,_=cell_of(g,{{0,0,0},{25600*5,100,100}})
    testing.expect_value(t,level,3)
    // A 2D grid takes no height, and its origin moves its cells.
    flat:=Grid{kind=.Grid,cell_size=25600,flat=true,origin={12800,0,500}}
    level,coord=cell_of(flat,{{0,0,1e6},{100,100,1e6+40000}})
    testing.expect_value(t,level,0)
    testing.expect_value(t,coord,[3]i64{-1,0,0})
    low,high:=cell_bounds({-1,0,0},25600,0,{12800,0,0})
    testing.expect_value(t,low,[3]f64{-12800,0,0})
    testing.expect_value(t,high,[3]f64{12800,25600,25600})
    // Unreal's X is Mirai's -Z, its Y Mirai's X, its Z Mirai's Y.
    box:=mirai_box({{100,200,300},{400,600,900}})
    testing.expect_value(t,box,mm.Aabb{{2,3,-4},{6,9,-1}})
    back:=ue_box(box)
    testing.expect_value(t,back,[2][3]f64{{100,200,300},{400,600,900}})
}

// A map of World Partition: its WorldSettings keeps the WorldPartition,
// whose RuntimeHash is a WorldPartitionRuntimeHashSet with the loose grid
// MainGrid (cells of 256 m, loaded within 512 m, 3D). Its actors: two meshes
// near the origin and one 600 m forward, a box 400 m long, a sun (lights load
// with the map), a mesh that says it loads with the map and one of a grid
// that is persistent.
@(private="file")
partition_map :: proc() -> unreal.Package {
    b:=fixture.builder_make()
    fixture.custom_version(&b,unreal.RELEASE_OBJECT_VERSION,3)
    world:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","World"),0,"Map")
    fixture.properties_end(&b);fixture.export_end(&b)
    Placed :: struct {class,name,label:string,location:[3]f32,component:string,extent:[3]f32,flag:int,grid:string}
    placed:=[?]Placed{
        {"StaticMeshActor","StaticMeshActor_0","Rock",{100,100,0},"StaticMeshComponent",{},0,""},
        {"StaticMeshActor","StaticMeshActor_1","Pebble",{25000,25000,25000},"StaticMeshComponent",{},0,""},
        {"StaticMeshActor","StaticMeshActor_2","Far",{60000,-100,0},"StaticMeshComponent",{},0,""},
        {"Actor","Actor_0","Wall",{20000,0,0},"BoxComponent",{20000,50,50},0,""},
        {"DirectionalLight","DirectionalLight_0","Sun",{0,0,1000},"DirectionalLightComponent",{},0,""},
        {"StaticMeshActor","StaticMeshActor_3","Mountain",{0,0,0},"StaticMeshComponent",{},2,""},
        {"StaticMeshActor","StaticMeshActor_4","Always",{100,100,0},"StaticMeshComponent",{},0,"Always"},
    }
    level_class:=fixture.class_import(&b,"/Script/Engine","Level")
    level:=fixture.export_begin(&b,level_class,world,"PersistentLevel")
    fixture.properties_end(&b)
    fixture.put_u32(&b,0);fixture.put_u32(&b,u32(len(placed)))
    first_actor:=len(b.exports)+1
    for i in 0..<len(placed) {fixture.put_u32(&b,u32(first_actor+i*2))}
    fixture.export_end(&b)
    for p in placed {
        actor:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine",p.class),level,p.name)
        fixture.object_property(&b,"RootComponent",actor+1)
        fixture.str_property(&b,"ActorLabel",p.label)
        if p.flag==2 {fixture.bool_property(&b,"bIsSpatiallyLoaded",false)}
        if p.grid!="" {fixture.name_property(&b,"RuntimeGrid",p.grid)}
        fixture.properties_end(&b);fixture.export_end(&b)
        _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine",p.component),actor,"Root")
        fixture.vector_property(&b,"RelativeLocation","Vector",p.location)
        if p.extent!={} {fixture.vector_property(&b,"BoxExtent","Vector",p.extent)}
        fixture.properties_end(&b);fixture.export_end(&b)
    }
    settings:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","WorldSettings"),level,"WorldSettings")
    fixture.object_property(&b,"WorldPartition",settings+1)
    fixture.properties_end(&b);fixture.export_end(&b)
    partition:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","WorldPartition"),settings,"WorldPartition")
    fixture.object_property(&b,"RuntimeHash",partition+1)
    fixture.properties_end(&b);fixture.export_end(&b)
    hash:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","WorldPartitionRuntimeHashSet"),partition,"WorldPartitionRuntimeHashSet")
    descs:=fixture.structs_begin(&b,"RuntimePartitions","RuntimePartitionDesc",2)
    fixture.name_property(&b,"Name","MainGrid")
    fixture.object_property(&b,"MainLayer",hash+1)
    fixture.element_end(&b)
    fixture.name_property(&b,"Name","Always")
    fixture.object_property(&b,"MainLayer",hash+2)
    fixture.element_end(&b)
    fixture.structs_end(&b,descs)
    fixture.properties_end(&b);fixture.export_end(&b)
    _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","RuntimePartitionLHGrid"),hash,"RuntimePartitionLHGrid_0")
    fixture.int_property(&b,"LoadingRange",51200)
    fixture.properties_end(&b);fixture.export_end(&b)
    _=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","RuntimePartitionPersistent"),hash,"RuntimePartitionPersistent_0")
    fixture.properties_end(&b);fixture.export_end(&b)
    return fixture.package_of(&b,"/Game/Map")
}

@(test)
a_map_of_world_partition_is_the_cells_of_its_grid_and_what_loads_with_it :: proc(t:^testing.T) {
    p:=partition_map()
    lib:Library
    library_init(&lib,nil)
    defer library_destroy(&lib)
    map_index,_:=library_add(&lib,"/Game/Map",&p)
    d:Document
    if !testing.expect_value(t,document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer document_destroy(&d)
    partition,error:=partition_read(&d)
    if !testing.expect_value(t,error.code,unreal.Error_Code.None) {return}
    defer partition_destroy(&partition)
    testing.expect_value(t,partition.hash,"WorldPartitionRuntimeHashSet")
    if !testing.expect_value(t,len(partition.grids),2) {return}
    grid:=partition.grids[0]
    testing.expect_value(t,grid.name,"MainGrid")
    testing.expect_value(t,grid.kind,Grid_Kind.Grid)
    testing.expect_value(t,grid.cell_size,f64(GRID_CELL_SIZE))
    testing.expect_value(t,grid.loading_range,f64(51200))
    testing.expect(t,!grid.flat && grid.bounds==.Content_In_Cell,"the defaults of RuntimePartitionLHGrid")
    testing.expect_value(t,partition.grids[1].kind,Grid_Kind.Persistent)
    // In the order of level and coordinates.
    if testing.expect_value(t,len(partition.cells),3) {
        testing.expect_value(t,partition.cells[0].name,"MainGrid_L0_X0_Y0_Z0")
        testing.expect_value(t,partition.cells[1].name,"MainGrid_L0_X2_Y-1_Z0")
        testing.expect_value(t,partition.cells[2].name,"MainGrid_L1_X0_Y0_Z0")
    }
    cell_named :: proc(p:^Partition,name:string) -> int {
        for c,i in p.cells {if c.name==name {return i}}
        return -1
    }
    rock:=cell_named(&partition,"MainGrid_L0_X0_Y0_Z0")
    testing.expect_value(t,partition.actor_cells[0],rock)
    testing.expect_value(t,partition.actor_cells[1],rock)
    testing.expect_value(t,partition.cells[rock].actors,2)
    testing.expect(t,close_box(partition.cells[rock].box,{{1,0,-250},{250,250,-1}}),"two points, within the cell")
    testing.expect_value(t,partition.actor_cells[2],cell_named(&partition,"MainGrid_L0_X2_Y-1_Z0"))
    wall:=cell_named(&partition,"MainGrid_L1_X0_Y0_Z0")
    testing.expect_value(t,partition.actor_cells[3],wall)
    testing.expect(t,close_box(partition.cells[wall].box,{{-0.5,-0.5,-400},{0.5,0.5,0}}),"above level 0 a cell is what it holds")
    testing.expect_value(t,partition.actor_cells[4],-1)
    testing.expect(t,!partition.spatial[4],"a light loads with the map, as its constructor says")
    testing.expect_value(t,partition.actor_cells[5],-1)
    testing.expect_value(t,partition.actor_cells[6],-1)
    testing.expect(t,partition.spatial[6],"an actor of a persistent grid loads with the map")
}
