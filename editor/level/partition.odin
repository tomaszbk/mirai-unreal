package level

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

// The cells of a World Partition map, as the streaming generation of Unreal
// makes them (WorldPartitionRuntimeHashSet, RuntimePartitionLHGrid): each
// spatially loaded actor goes to the cell of its grid that holds the center
// of its bounds, at the level of the loose hierarchy that fits their size; the
// others load with the map. A cell streams by its box, which the bounds
// method of its grid gives from what its actors show.
//
// The bounds of an actor are those of what its primitive components show,
// computed here: meshes by the bounds their package keeps, instances one by
// one, landscape components by their cached box, shape components by their
// size; an actor without any is the point where it is. Unreal takes the bounds
// its editor saved in the descriptor of each actor, which is not read: an
// actor near the border of a cell may fall in its neighbour. Actor sets
// (attachments across actors) and data layers do not split cells.

Grid_Kind :: enum u8 {Grid,Persistent}

// How the box of a cell of a grid is made (ERuntimePartitionCellBoundsMethod):
// from its actors, the cell itself, or the actors within the cell. Above
// level 0 a cell is always its actors.
Cell_Bounds :: enum u8 {Content,Cell,Content_In_Cell}

Grid :: struct {
    name:string,
    kind:Grid_Kind,
    cell_size:f64,     // centimetres, at level 0
    origin:[3]f64,     // centimetres, in Unreal's space
    flat:bool,         // a 2D grid: its cells hold every height
    loading_range:f64, // centimetres from a source to the box of a cell, within which it loads
    bounds:Cell_Bounds,
}

Cell :: struct {
    grid:int,
    level:int,
    coord:[3]i64,
    name:string,  // as Unreal names it: <grid>_L<level>_X<x>_Y<y>, and _Z<z> in 3D
    box:mm.Aabb,  // in Mirai's space: where it is, for its streaming
    actors:int,
}

Partition :: struct {
    hash:string,         // the class of the runtime hash; "" without World Partition
    grids:[dynamic]Grid,
    cells:[dynamic]Cell,
    actor_cells:[]int,   // by actor: its cell, or -1 when it loads with the map
    bounds:[]mm.Aabb,    // by actor, in Mirai's space
    spatial:[]bool,      // by actor: spatially loaded
    layered:int,         // actors that name data layers, which do not split their cells
    allocator:mem.Allocator,
}

// The defaults of a RuntimePartitionLHGrid.
GRID_CELL_SIZE :: 25600
GRID_LOADING_RANGE :: 25600

// Past this level a cell would be wider than any world Unreal places.
@(private)
LEVELS_MAX :: 40

partition_destroy :: proc(p:^Partition) {
    for g in p.grids {delete(g.name,p.allocator)}
    for c in p.cells {delete(c.name,p.allocator)}
    delete(p.grids);delete(p.cells)
    delete(p.actor_cells,p.allocator);delete(p.bounds,p.allocator);delete(p.spatial,p.allocator)
    p^={}
}

// The partition of the levels of d: none (hash "") for a map that is not
// partitioned. A runtime hash other than WorldPartitionRuntimeHashSet (the
// RuntimeSpatialHash of UE 5.0 to 5.3) is Unsupported_Value, with hash set.
partition_read :: proc(d:^Document,allocator:=context.allocator) -> (p:Partition,error:unreal.Error) {
    p.allocator=allocator
    p.grids.allocator,p.cells.allocator=allocator,allocator
    defer if error.code!=.None && error.code!=.Unsupported_Value {partition_destroy(&p)}
    if len(d.levels)==0 {return}
    map_index:=d.levels[0].ref.pkg
    m:=library_package(d.library,int(map_index))
    partition:Ref
    for _,i in m.exports {
        if export_is(m,unreal.Object_Ref(i+1),"/Script/Engine","WorldPartition") {partition={map_index,unreal.Object_Ref(i+1)};break}
    }
    if partition.object==0 {return}
    object:unreal.Object_Ref
    if object,error=reference_property(d,partition,"RuntimeHash");error.code!=.None {return}
    if object==0 {return {},{.Invalid_Reference,0,"WorldPartition has no RuntimeHash"}}
    hash,native,resolve_error:=resolve(d,partition,object)
    if resolve_error.code!=.None || native {return {},resolve_error.code!=.None?resolve_error:unreal.Error{.Invalid_Reference,0,"RuntimeHash"}}
    hp:=library_package(d.library,int(hash.pkg))
    class:=class_of(hp,hp.exports[int(hash.object)-1].class)
    p.hash=class.name
    if !class_is(class,"/Script/Engine","WorldPartitionRuntimeHashSet") {
        return p,{.Unsupported_Value,0,"runtime hash other than WorldPartitionRuntimeHashSet"}
    }
    if error=grids_read(d,&p,hash);error.code!=.None {return}
    p.actor_cells=make([]int,len(d.actors),allocator)
    p.bounds=make([]mm.Aabb,len(d.actors),allocator)
    p.spatial=make([]bool,len(d.actors),allocator)
    meshes:=make(map[string]Mesh_Box,context.temp_allocator)
    keys:=make([]Cell_Key,len(d.actors),context.temp_allocator)
    for a in 0..<len(d.actors) {
        p.actor_cells[a]=-1
        p.bounds[a]=actor_bounds(d,a,&meshes)
        if f,f_error:=property(d,d.actors[a].ref,"DataLayerAssets");f_error.code==.None && f.property!=nil {p.layered+=1}
        p.spatial[a]=actor_spatial(d,a)
        grid:=actor_grid(d,&p,a)
        if !p.spatial[a] || grid<0 || p.grids[grid].kind!=.Grid {continue}
        level,coord:=cell_of(p.grids[grid],ue_box(p.bounds[a]))
        keys[a]=Cell_Key{grid,level,coord}
        p.actor_cells[a]=0
    }
    // In the order of grid, level and coordinates, so that the same map gives the same cells.
    held:=make([dynamic]Cell_Key,context.temp_allocator)
    for k,a in keys {if p.actor_cells[a]>=0 && !slice.contains(held[:],k) {append(&held,k)}}
    slice.sort_by(held[:],proc(x,y:Cell_Key) -> bool {
        if x.grid!=y.grid {return x.grid<y.grid}
        if x.level!=y.level {return x.level<y.level}
        if x.coord.x!=y.coord.x {return x.coord.x<y.coord.x}
        if x.coord.y!=y.coord.y {return x.coord.y<y.coord.y}
        return x.coord.z<y.coord.z
    })
    rank:=make(map[Cell_Key]int,len(held),context.temp_allocator)
    for k,i in held {
        rank[k]=i
        g:=p.grids[k.grid]
        name:=fmt.tprintf("%s_L%d_X%d_Y%d",g.name,k.level,k.coord.x,k.coord.y)
        if !g.flat {name=fmt.tprintf("%s_Z%d",name,k.coord.z)}
        append(&p.cells,Cell{grid=k.grid,level=k.level,coord=k.coord,name=strings.clone(name,allocator),box=mm.AABB_EMPTY})
    }
    for &c,a in p.actor_cells {if c>=0 {c=rank[keys[a]]}}
    for c,a in p.actor_cells {
        if c<0 {continue}
        p.cells[c].box=mm.aabb_merge(p.cells[c].box,p.bounds[a])
        p.cells[c].actors+=1
    }
    for &c in p.cells {c.box=cell_box(p.grids[c.grid],c,c.box)}
    return
}

@(private)
Cell_Key :: struct {grid,level:int,coord:[3]i64}

// The grids of a WorldPartitionRuntimeHashSet: its RuntimePartitions, each
// with its name and the object of its main layer. HLOD layers are not read.
@(private)
grids_read :: proc(d:^Document,p:^Partition,hash:Ref) -> unreal.Error {
    f,error:=property(d,hash,"RuntimePartitions")
    if error.code!=.None {return error}
    if f.property==nil {return {}}
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None {return view_error}
    descs,descs_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
    if descs_error.code!=.None {return descs_error}
    for &desc in descs.items {
        name:=""
        if item:=unreal.property_find(f.pkg,&desc,"Name");item!=nil {
            if v,v_error:=unreal.property_value(f.pkg,item);v_error.code==.None && v.kind==.Name {name=unreal.name_plain(f.pkg,v.name)}
        }
        item:=unreal.property_find(f.pkg,&desc,"MainLayer")
        if item==nil {continue}
        v,v_error:=unreal.property_value(f.pkg,item)
        if v_error.code!=.None || v.kind!=.Object || v.object==0 {continue}
        layer,native,layer_error:=resolve(d,hash,v.object)
        if layer_error.code!=.None {return layer_error}
        if native {continue}
        lp:=library_package(d.library,int(layer.pkg))
        class:=class_of(lp,lp.exports[int(layer.object)-1].class)
        g:=Grid{kind=.Persistent,cell_size=GRID_CELL_SIZE,loading_range=GRID_LOADING_RANGE,bounds=.Content_In_Cell}
        if name=="" || name=="None" {
            if own,own_found:=name_of(d,layer,"Name");own_found {name=own}
        }
        g.loading_range,_=real_of(d,layer,"LoadingRange",GRID_LOADING_RANGE)
        method,_:=enum_of(d,layer,"BoundsMethod","UseMinContentCellBounds")
        switch method {
        case "UseContent":g.bounds=.Content
        case "UseCellBounds":g.bounds=.Cell
        }
        if class_is(class,"/Script/Engine","RuntimePartitionLHGrid") {
            g.kind=.Grid
            g.cell_size,_=real_of(d,layer,"CellSize",GRID_CELL_SIZE)
            g.origin,_=vector_of(d,layer,"Origin",{})
            g.flat,_=bool_of(d,layer,"bIs2D",false)
            if !(g.cell_size>0) {return {.Malformed,0,"RuntimePartitionLHGrid CellSize"}}
        }
        g.name=strings.clone(name,p.allocator)
        append(&p.grids,g)
    }
    return {}
}

// The grid of an actor: the partition its RuntimeGrid names, else the first.
@(private)
actor_grid :: proc(d:^Document,p:^Partition,a:int) -> int {
    if len(p.grids)==0 {return -1}
    if name,found:=name_of(d,d.actors[a].ref,"RuntimeGrid");found && name!="None" {
        for g,i in p.grids {if g.name==name {return i}}
    }
    return 0
}

// The native classes whose constructor leaves an actor out of spatial loading
// (bIsSpatiallyLoaded false): lights, AInfo and the classes that set it.
@(private)
NON_SPATIAL_CLASSES :: []string{
    "DirectionalLight","PointLight","SpotLight","RectLight","Light",
    "WorldSettings","SkyLight","SkyAtmosphere","ExponentialHeightFog","VolumetricCloud","AtmosphericFog","LocalFogVolume",
    "WorldDataLayers","WorldPartitionMiniMap","GPULightmassSettingsActor","WindDirectionalSource","HeterogeneousVolume",
    "SparseVolumeTextureViewer","GeoReferencingSystem","SpatialHashRuntimeGridInfo","AmbientLightingVolume",
    "Landscape","LevelBounds","LocationVolume","PlayerStart","PostProcessVolume","RuntimeVirtualTextureVolume",
    "WorldPartitionMiniMapVolume","WorldPartitionVolume","LandscapeBlueprintBrushBase","PCGWorldActor","PCGBuilderVolume",
}

// Whether an actor loads by where it is: bIsSpatiallyLoaded, through its
// archetypes, or the default of its native class.
actor_spatial :: proc(d:^Document,a:int) -> bool {
    native:=actor_native_class(d,a)
    spatial,_:=bool_of(d,d.actors[a].ref,"bIsSpatiallyLoaded",!slice.contains(NON_SPATIAL_CLASSES,native.name))
    return spatial
}

// The level and coordinates of the cell of grid g that holds box (Unreal's
// space). A 2D grid takes no height.
cell_of :: proc(g:Grid,box:[2][3]f64) -> (level:int,coord:[3]i64) {
    box:=box
    origin:=g.origin
    if g.flat {box[0].z,box[1].z,origin.z=0,0,0}
    size:=box[1]-box[0]
    longest:=max(size.x,size.y,size.z)
    level=0
    if longest>0 {level=min(int(math.ceil(max(math.log2(longest/g.cell_size),0))),LEVELS_MAX)}
    center:=(box[0]+box[1])*0.5
    if level>0 {
        below:=cell_coords(center,g.cell_size,level-1,origin)
        low,high:=cell_bounds(below,g.cell_size,level-1,origin)
        under:=[3]f64{}
        for axis in 0..<3 {under[axis]=max(low[axis]-box[0][axis],box[1][axis]-high[axis],0)}
        // An actor that passes a cell by less than a quarter of it stays in that level.
        if max(under.x,under.y,under.z)<g.cell_size/4 {level-=1}
    }
    coord=cell_coords(center,g.cell_size,level,origin)
    return
}

@(private)
cell_coords :: proc(position:[3]f64,cell_size:f64,level:int,origin:[3]f64) -> (coord:[3]i64) {
    size:=cell_size*f64(i64(1)<<uint(level))
    for axis in 0..<3 {coord[axis]=i64(math.floor((position[axis]-origin[axis])/size))}
    return
}

// The corners of a cell in Unreal's space.
cell_bounds :: proc(coord:[3]i64,cell_size:f64,level:int,origin:[3]f64) -> (low,high:[3]f64) {
    size:=cell_size*f64(i64(1)<<uint(level))
    for axis in 0..<3 {
        low[axis]=origin[axis]+f64(coord[axis])*size
        high[axis]=low[axis]+size
    }
    return
}

// The box of a cell in Mirai's space, from content, the box of what its
// actors show: at level 0 the cell, or the content within it, as the grid
// says; above, the content. A 2D cell keeps the heights of its content.
@(private)
cell_box :: proc(g:Grid,c:Cell,content:mm.Aabb) -> mm.Aabb {
    if c.level>0 || g.bounds==.Content {return content}
    origin:=g.origin
    if g.flat {origin.z=0}
    low,high:=cell_bounds(c.coord,g.cell_size,c.level,origin)
    cell:=mirai_box({low,high})
    if g.flat {cell.min.y,cell.max.y=content.min.y,content.max.y}
    if g.bounds==.Cell {return cell}
    within:=mm.Aabb{mm.vec3_max(cell.min,content.min),mm.vec3_min(cell.max,content.max)}
    if within.min.x>within.max.x || within.min.y>within.max.y || within.min.z>within.max.z {return cell}
    return within
}

// A box of Mirai (metres) in Unreal's space (centimetres): Unreal's X is
// Mirai's -Z, its Y Mirai's X and its Z Mirai's Y.
ue_box :: proc "contextless" (box:mm.Aabb) -> (b:[2][3]f64) {
    b[0]={-f64(box.max.z)*100,f64(box.min.x)*100,f64(box.min.y)*100}
    b[1]={-f64(box.min.z)*100,f64(box.max.x)*100,f64(box.max.y)*100}
    return
}

// A box of Unreal (centimetres) in Mirai's space (metres).
mirai_box :: proc "contextless" (b:[2][3]f64) -> mm.Aabb {
    return {
        {f32(b[0].y/100),f32(b[0].z/100),f32(-b[1].x/100)},
        {f32(b[1].y/100),f32(b[1].z/100),f32(-b[0].x/100)},
    }
}

// The box of a mesh in its own space (Mirai's), from the bounds its package keeps.
Mesh_Box :: struct {box:mm.Aabb,ok:bool}

// The components whose mesh is their bounds.
@(private)
MESH_COMPONENTS :: []string{
    "StaticMeshComponent","InstancedStaticMeshComponent","HierarchicalInstancedStaticMeshComponent",
    "FoliageInstancedStaticMeshComponent","SplineMeshComponent","SkeletalMeshComponent",
}

// The bounds of what an actor shows, in Mirai's space: the union of those of
// its primitive components that are not editor-only, or the point where it
// is without any (streaming bounds of AActor). meshes keeps the box of each
// mesh by its path.
actor_bounds :: proc(d:^Document,a:int,meshes:^map[string]Mesh_Box) -> mm.Aabb {
    box:=mm.AABB_EMPTY
    actor:=d.actors[a]
    for k in actor.first_component..<actor.first_component+actor.component_count {
        if b,ok:=component_bounds(d,k,meshes);ok {box=mm.aabb_merge(box,b)}
    }
    if !mm.aabb_is_empty(box) {return box}
    world,_,_:=actor_world(d,a)
    return {world.position,world.position}
}

// The box of what a component shows, in Mirai's space.
component_bounds :: proc(d:^Document,k:int,meshes:^map[string]Mesh_Box) -> (box:mm.Aabb,ok:bool) {
    component:=d.components[k]
    ref:=component.ref
    if editor_only,_:=bool_of(d,ref,"bIsEditorOnly",false);editor_only {return}
    local:mm.Aabb
    class:=component.class.name
    switch {
    case slice.contains(MESH_COMPONENTS,class):
        path:=""
        if class=="SkeletalMeshComponent" {
            path=path_of(d,ref,"SkeletalMesh")
            if path=="" {path=path_of(d,ref,"SkinnedAsset")}
        } else {
            path=path_of(d,ref,"StaticMesh")
        }
        if path=="" {return}
        m:=mesh_box(d,path,meshes)
        if !m.ok {return}
        local=m.box
        switch class {
        case "SplineMeshComponent":local=spline_box(d,ref,local) or_return
        case "InstancedStaticMeshComponent","HierarchicalInstancedStaticMeshComponent","FoliageInstancedStaticMeshComponent":
            return instances_box(d,k,local)
        }
    case class=="LandscapeComponent":
        local=box_of(d,ref,"CachedLocalBox") or_return
    case class=="BoxComponent":
        extent,_:=vector_of(d,ref,"BoxExtent",{32,32,32})
        local=mirai_box({-extent,extent})
    case class=="SphereComponent":
        radius,_:=real_of(d,ref,"SphereRadius",32)
        local=mirai_box({{-radius,-radius,-radius},{radius,radius,radius}})
    case class=="CapsuleComponent":
        radius,_:=real_of(d,ref,"CapsuleRadius",22)
        half,_:=real_of(d,ref,"CapsuleHalfHeight",44)
        local=mirai_box({{-radius,-radius,-half},{radius,radius,half}})
    case:
        return
    }
    world,error:=component_world(d,k)
    if error.code!=.None {return}
    return mm.aabb_transform(local,mm.transform_matrix(world)),true
}

// The bounds of every instance of an instanced component.
@(private)
instances_box :: proc(d:^Document,k:int,mesh:mm.Aabb) -> (box:mm.Aabb,ok:bool) {
    world,error:=component_world(d,k)
    if error.code!=.None {return}
    instances,instances_error:=component_instances(d,k,context.temp_allocator)
    if instances_error.code!=.None {return}
    box=mm.AABB_EMPTY
    for m in instances.matrices {
        local,local_error:=matrix_to_mirai(m)
        if local_error.code!=.None {continue}
        box=mm.aabb_merge(box,mm.aabb_transform(mesh,mm.transform_matrix(mm.transform_compose(world,local))))
    }
    return box,!mm.aabb_is_empty(box)
}

// The box of a spline mesh in the space of its component: the hull of the
// Bézier points of its spline, grown by the widest the mesh is across it at
// the larger of its two scales.
@(private)
spline_box :: proc(d:^Document,ref:Ref,mesh:mm.Aabb) -> (box:mm.Aabb,ok:bool) {
    f,error:=property(d,ref,"SplineParams")
    if error.code!=.None || f.property==nil {return}
    params,params_error:=unreal.property_tagged_struct(f.pkg,f.property,true,context.temp_allocator)
    if params_error.code!=.None {return}
    field :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:[3]f64) -> [3]f64 {
        item:=unreal.property_find(p,list,name)
        if item==nil {return default}
        v,error:=unreal.property_value(p,item)
        if error.code!=.None || v.kind!=.Real_Vector {return default}
        out:=default
        for axis in 0..<min(int(v.vector_count),3) {out[axis]=v.vector[axis]}
        return out
    }
    start:=field(f.pkg,&params,"StartPos",{})
    end:=field(f.pkg,&params,"EndPos",{100,0,0})
    start_tangent:=field(f.pkg,&params,"StartTangent",{100,0,0})
    end_tangent:=field(f.pkg,&params,"EndTangent",{100,0,0})
    start_scale:=field(f.pkg,&params,"StartScale",{1,1,0})
    end_scale:=field(f.pkg,&params,"EndScale",{1,1,0})
    points:=[4][3]f32{point_to_mirai(start),point_to_mirai(start+start_tangent/3),point_to_mirai(end-end_tangent/3),point_to_mirai(end)}
    box=mm.aabb_from_points(points[:])
    half:=mm.aabb_half(mesh)
    across:=max(abs(mesh.min.x),abs(mesh.max.x),abs(mesh.min.y),abs(mesh.max.y),abs(mesh.min.z),abs(mesh.max.z),half.x,half.y,half.z)
    scale:=f32(max(abs(start_scale.x),abs(start_scale.y),abs(end_scale.x),abs(end_scale.y),1))
    return mm.aabb_expand(box,across*scale),true
}

// The box of the mesh at an object path, in its own space, from the
// ExtendedBounds (or ImportedBounds) its package keeps, read once.
mesh_box :: proc(d:^Document,path:string,meshes:^map[string]Mesh_Box) -> Mesh_Box {
    if found,seen:=meshes[path];seen {return found}
    m:Mesh_Box
    defer meshes[strings.clone(path,context.temp_allocator)]=m
    dot:=strings.index_byte(path,'.')
    if dot<0 {return m}
    package_name,object:=path[:dot],path[dot+1:]
    index,error:=library_find(d.library,package_name)
    if error.code!=.None {return m}
    p:=library_package(d.library,index)
    for item,i in p.exports {
        if item.outer!=0 || unreal.name_plain(p,item.object_name)!=object {continue}
        ref:=Ref{i32(index),unreal.Object_Ref(i+1)}
        for name in ([2]string{"ExtendedBounds","ImportedBounds"}) {
            f,f_error:=property(d,ref,name)
            if f_error.code!=.None || f.property==nil {continue}
            bounds,bounds_error:=unreal.property_tagged_struct(f.pkg,f.property,true,context.temp_allocator)
            if bounds_error.code!=.None {continue}
            origin,extent:[3]f64
            for field,j in ([2]string{"Origin","BoxExtent"}) {
                item:=unreal.property_find(f.pkg,&bounds,field)
                if item==nil {continue}
                v,v_error:=unreal.property_value(f.pkg,item)
                if v_error.code!=.None || v.kind!=.Real_Vector {continue}
                value:=[3]f64{v.vector[0],v.vector[1],v.vector[2]}
                if j==0 {origin=value} else {extent=value}
            }
            m={mirai_box({origin-extent,origin+extent}),true}
            return m
        }
        break
    }
    return m
}

// A vector property through the archetypes (Vector, Vector2D's two).
vector_of :: proc(d:^Document,ref:Ref,name:string,default:[3]f64) -> (value:[3]f64,found:bool) {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return default,false}
    v,value_error:=unreal.property_value(f.pkg,f.property)
    if value_error.code!=.None || v.kind!=.Real_Vector {return default,false}
    value=default
    for axis in 0..<min(int(v.vector_count),3) {value[axis]=v.vector[axis]}
    return value,true
}

// A name property through the archetypes.
name_of :: proc(d:^Document,ref:Ref,name:string) -> (value:string,found:bool) {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return "",false}
    v,value_error:=unreal.property_value(f.pkg,f.property)
    if value_error.code!=.None || v.kind!=.Name {return "",false}
    return unreal.name_plain(f.pkg,v.name),true
}

// An FBox property (Min, Max and IsValid, saved natively: doubles from UE5,
// floats before) in Mirai's space; false when it is not valid.
box_of :: proc(d:^Document,ref:Ref,name:string) -> (box:mm.Aabb,ok:bool) {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return}
    bytes,bytes_error:=unreal.span_bytes(f.pkg,f.property.data)
    if bytes_error.code!=.None {return}
    corners:[2][3]f64
    switch len(bytes) {
    case 49:
        for i in 0..<6 {corners[i/3][i%3],_=endian.get_f64(bytes[i*8:],.Little)}
    case 25:
        for i in 0..<6 {
            value,_:=endian.get_f32(bytes[i*4:],.Little)
            corners[i/3][i%3]=f64(value)
        }
    case:
        return
    }
    if bytes[len(bytes)-1]==0 {return}
    for axis in 0..<3 {
        if !(corners[0][axis]<=corners[1][axis]) {return}
    }
    return mirai_box(corners),true
}
