package unreal_shapes_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import render "mirai:engine/render"
import fixture "project:plugins/unreal/editor/fixture/files"
import "project:plugins/unreal/editor/level"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:project"
import "mirai:std/base"
import phys "plugins:physics/runtime"
import shapes "plugins:shapes/runtime"

// A spline mesh as Unreal keeps it, and where Unreal puts a point of its mesh:
// the slice of the curve at the share of the mesh the point is at along its
// forward axis, with that coordinate of the point taken out.
@(private="file")
Unreal_Spline :: struct {
    s:level.Spline_Mesh,
    axis:int,
    up:[3]f64,
    smooth:bool,
    boundary:[2]f64,
}

@(private="file")
unreal_tangent :: proc(s:level.Spline_Mesh,a:f64) -> [3]f64 {
    c:=6*s.start+3*s.start_tangent+3*s.end_tangent-6*s.end
    d:=-6*s.start-4*s.start_tangent-2*s.end_tangent+6*s.end
    return c*(a*a)+d*a+s.start_tangent
}

@(private="file")
unreal_point :: proc(s:level.Spline_Mesh,a:f64) -> [3]f64 {
    a2:=a*a
    a3:=a2*a
    return (2*a3-3*a2+1)*s.start+(a3-2*a2+a)*s.start_tangent+(a3-a2)*s.end_tangent+(3*a2-2*a3)*s.end
}

@(private="file")
unreal_place :: proc(u:Unreal_Spline,bounds:[2][3]f64,p:[3]f64) -> [3]f64 {
    s:=u.s
    low,high:=bounds[0][u.axis],bounds[1][u.axis]
    alpha,first,last:=f64(0),f64(0),f64(1)
    if span:=u.boundary.y-u.boundary.x;abs(span)>1e-8 {
        alpha=(p[u.axis]-u.boundary.x)/span
        first,last=max(-4,(low-u.boundary.x)/span),min((high-u.boundary.x)/span,4)
    } else if high-low>1e-8 {
        alpha=(p[u.axis]-low)/(high-low)
    }
    eased:=alpha
    if u.smooth {eased=alpha<0?0:alpha>=1?1:alpha*alpha*(3-2*alpha)}
    position,direction:[3]f64
    switch {
    case alpha<first:
        direction=unreal_tangent(s,first)
        position=unreal_point(s,first)+direction*(alpha-first)
    case alpha>last:
        direction=unreal_tangent(s,last)
        position=unreal_point(s,last)+direction*(alpha-last)
    case:
        direction=unreal_tangent(s,alpha)
        position=unreal_point(s,alpha)
    }
    direction=linalg.normalize0(direction)
    x:=linalg.normalize0(linalg.cross(u.up,direction))
    y:=linalg.normalize0(linalg.cross(direction,x))
    offset:=linalg.lerp(s.start_offset,s.end_offset,eased)
    position+=offset.x*x+offset.y*y
    roll:=math.lerp(s.start_roll,s.end_roll,eased)
    rolled_x:=math.cos(roll)*x-math.sin(roll)*y
    rolled_y:=math.cos(roll)*y+math.sin(roll)*x
    scale:=linalg.lerp(s.start_scale,s.end_scale,eased)
    switch u.axis {
    case 0: return position+rolled_x*(scale.x*p.y)+rolled_y*(scale.y*p.z)
    case 1: return position+rolled_y*(scale.y*p.x)+rolled_x*(scale.x*p.z)
    case: return position+rolled_x*(scale.x*p.x)+rolled_y*(scale.y*p.y)
    }
}

@(test)
a_spline_mesh_of_unreal_bends_its_mesh_where_unreal_does :: proc(t:^testing.T) {
    curved:=level.Spline_Mesh{
        start={0,0,0},start_tangent={300,0,100},end={200,150,50},end_tangent={0,300,0},
        start_scale={1,1},end_scale={1.5,0.6},start_offset={10,-5},end_offset={-20,8},start_roll=0.3,end_roll=1.1,
    }
    mirrored:=curved
    mirrored.start_scale,mirrored.end_scale={-1,1},{-1.2,0.8}
    upward:=curved
    upward.end,upward.start_tangent,upward.end_tangent={50,-30,250},{0,0,300},{100,0,200}
    Case :: struct {name:string,unreal:Unreal_Spline}
    cases:=[]Case{
        {"default",{s=level.SPLINE_MESH_DEFAULT,axis=0,up={0,0,1}}},
        {"curved along X",{s=curved,axis=0,up={0,0,1}}},
        {"curved along X, smooth",{s=curved,axis=0,up={0,0,1},smooth=true}},
        {"curved along X, mirrored",{s=mirrored,axis=0,up={0,0,1}}},
        {"curved along X, boundaries wider than the mesh",{s=curved,axis=0,up={0,0,1},boundary={-80,120}}},
        {"curved along Y, up tilted",{s=curved,axis=1,up={0.2,0.1,1}}},
        {"upward along Z, up along X",{s=upward,axis=2,up={1,0,0}}},
    }
    axes:=[3]string{"X","Y","Z"}
    bounds:=[2][3]f64{{-50,-20,-10},{50,30,15}}
    points:=[][3]f64{{-50,-20,-10},{50,30,15},{10,-5,7},{-25,30,-10},{0,0,0},{50,-20,15}}
    for c in cases {
        bend,ok:=spline_bend(c.unreal.s,axes[c.unreal.axis],c.unreal.up,c.unreal.smooth,c.unreal.boundary)
        if !testing.expectf(t,ok && shapes.bend_valid(bend),"%s: a valid Bend",c.name) {continue}
        for p in points {
            want:=level.point_to_mirai(unreal_place(c.unreal,bounds,p))
            got:=shapes.bend_place(bend,level.mirai_box(bounds),level.point_to_mirai(p))
            testing.expectf(t,linalg.length(got-want)<1e-4,"%s: %v goes to %v, not %v",c.name,p,got,want)
        }
    }
}

// A quad of a StaticMesh 100 units along X.
@(private="file")
quad_package :: proc() -> []u8 {
    up:=[3]f32{0,0,1}
    f:fixture.Mesh_Fixture
    f.layout=.Raw_Mesh
    f.positions=slice.clone([][3]f32{{0,0,0},{100,0,0},{100,20,0},{0,20,0}},context.temp_allocator)
    f.corners=slice.clone([]u32{0,2,1, 0,3,2},context.temp_allocator)
    f.normals=slice.clone([][3]f32{up,up,up,up,up,up},context.temp_allocator)
    f.uvs=slice.clone([][2]f32{{0,1},{1,0},{1,1},{0,1},{0,0},{1,0}},context.temp_allocator)
    f.groups=slice.clone([]u32{0,0},context.temp_allocator)
    f.smoothing=slice.clone([]u32{1,1},context.temp_allocator)
    f.slots=slice.clone([]fixture.Mesh_Slot{{name="Iron",imported_name="Iron",material="/Game/Materials/M_Iron"}},context.temp_allocator)
    return fixture.static_mesh_package(f)
}

// A rail of a level (a SplineMeshActor whose spline mesh blocks) and the
// chain attached to it, which keeps the collision a spline mesh is made with:
// none.
@(test)
the_spline_meshes_of_an_unreal_level_bend_their_meshes :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-shapes-unreal-%d",directory,os.get_pid())
    os.remove_all(top)
    defer os.remove_all(top)
    root:=fmt.tprintf("%s/project",top)
    os.make_directory_all(root)
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    for folder in ([?]string{"Maps","Meshes"}) {os.make_directory_all(fmt.tprintf("%s/assets/Unreal/Content/%s",root,folder))}
    _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Levels.uproject",root),"{}")
    _=os.write_entire_file(fmt.tprintf("%s/assets/Unreal/Content/Meshes/SM_Rail.uasset",root),quad_package())
    l:=fixture.level_begin("/Game/Maps/Mine")
    w:=&l.w
    mesh:=fixture.package_object(w,"/Game/Meshes/SM_Rail","/Script/Engine","StaticMesh","SM_Rail")
    class:=fixture.engine_class(w,"SplineMeshComponent")
    actor:=fixture.actor_add(&l,fixture.engine_class(w,"SplineMeshActor"),"SplineMeshActor_0","Track")
    params:=fixture.bytes_make()
    fixture.vector_property(&params,w,"StartTangent",{0,300,0})
    fixture.vector_property(&params,w,"EndPos",{200,200,0})
    fixture.vector_property(&params,w,"EndTangent",{300,0,0})
    fixture.vector2_property(&params,w,"EndScale",{2,0.5})
    fixture.float_property(&params,w,"EndRoll",0.5)
    props:=fixture.bytes_make()
    fixture.object_property(&props,w,"StaticMesh",mesh)
    fixture.struct_property(&props,w,"SplineParams","SplineMeshParams",&params)
    fixture.enum_property(&props,w,"ForwardAxis","ESplineMeshAxis","ESplineMeshAxis::Y")
    fixture.bool_property(&props,w,"bSmoothInterpRollScale",true)
    body:=fixture.bytes_make()
    fixture.name_property(&body,w,"CollisionProfileName","BlockAll")
    fixture.struct_property(&props,w,"BodyInstance","BodyInstance",&body)
    rail:=fixture.component_add(&l,actor,class,"Rail",props)
    chain_props:=fixture.bytes_make()
    fixture.object_property(&chain_props,w,"StaticMesh",mesh)
    fixture.object_property(&chain_props,w,"AttachParent",rail)
    fixture.component_add(&l,actor,class,"Chain",chain_props)
    fixture.actor_set(&l,actor,rail)
    level_path:=fmt.tprintf("%s/assets/Unreal/Content/Maps/Mine.umap",root)
    _=os.write_entire_file(level_path,fixture.level_bytes(&l))

    provider:=shapes_unreal_default().provider
    report,error:=unreal_scene.level_import(level_path,{root=root},provider.translators[:provider.count],"-")
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer unreal_scene.level_report_destroy(&report)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,report.scene_path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    named :: proc(scene:^asset.Scene,name:string) -> (base.Entity_Id,bool) {
        for row in 0..<asset.scene_entity_count(scene) {
            if e:=asset.scene_entity(scene,row);e.name==name {return e.id,true}
        }
        return 0,false
    }
    s:=level.SPLINE_MESH_DEFAULT
    s.start_tangent,s.end,s.end_tangent,s.end_scale,s.end_roll={0,300,0},{200,200,0},{300,0,0},{2,0.5},0.5
    want,_:=spline_bend(s,"Y",{0,0,1},true,{})
    Case :: struct {name:string,bend:shapes.Bend,collides:bool}
    for c in ([]Case{{"Rail",want,true},{"Chain",spline_bend(level.SPLINE_MESH_DEFAULT,"X",{0,0,1},false,{}) or_else {},false}}) {
        e,found:=named(&scene,c.name)
        if !testing.expectf(t,found,"%s: an entity",c.name) {continue}
        _,shown:=asset.scene_get(&scene,e,"Mesh_Renderer",render.Mesh_Renderer)
        bend,bent:=asset.scene_get(&scene,e,"Bend",shapes.Bend)
        testing.expectf(t,shown && bent && bend==c.bend,"%s: its mesh with its Bend: %v",c.name,bend)
        collider,collides:=asset.scene_get(&scene,e,"Collider",phys.Collider)
        testing.expectf(t,collides==c.collides && (!collides || collider.kind==.External),"%s: collides %v",c.name,collides)
    }
}
