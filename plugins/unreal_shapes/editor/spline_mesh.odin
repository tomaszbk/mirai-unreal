package unreal_shapes_editor

import "core:math/linalg"
import "project:plugins/unreal/editor/level"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:std/base"
import phys "plugins:physics/runtime"
import shapes "plugins:shapes/runtime"

// The spline meshes of an Unreal level imported by the editor: the entity
// the importer makes of a SplineMeshComponent shows its static mesh, and
// this bridge bends it with a Bend of the same curve. The axes of the import
// (level.SPACE) are a reflection, and both the mesh and its curve go through
// them: the forward axis of the mesh and the one along the up of the curve
// become the axes of Mirai they turn into, the curve, its tangents, its
// offsets and the boundaries of the mesh go from centimetres to metres, and
// roll and scale stay. It collides where its BodyInstance does (a spline mesh
// does not by default), with the collision of its mesh bent.
@(storage)
Shapes_Unreal :: struct {provider:unreal_scene.Translator_Provider}

shapes_unreal_default :: proc() -> (s:Shapes_Unreal) {
    s.provider.count=1
    s.provider.translators[0]={classes={0="SplineMeshComponent"},component=spline_mesh_bend}
    return
}

// Of each ForwardAxis of Unreal (X, Y, Z): the axis of the mesh in Mirai
// along the curve, and the one along the up of the curve (Z, X and Y of the
// mesh in Unreal's space).
@(private)
BEND_AXES :: [3][2]shapes.Bend_Axis{{.Negative_Z,.Y},{.X,.Negative_Z},{.Y,.X}}

// The Bend of a spline mesh of Unreal: its SplineParams, ForwardAxis
// ("X", "Y" or "Z"), SplineUpDir, bSmoothInterpRollScale and
// SplineBoundaryMin and Max. False for another forward axis.
spline_bend :: proc(s:level.Spline_Mesh,forward:string,up:[3]f64,smooth:bool,boundary:[2]f64) -> (b:shapes.Bend,ok:bool) {
    axis:int
    switch forward {
    case "X": axis=0
    case "Y": axis=1
    case "Z": axis=2
    case: return
    }
    axes:=BEND_AXES
    b.forward,b.mesh_up=axes[axis][0],axes[axis][1]
    b.start,b.start_tangent=level.point_to_mirai(s.start),level.point_to_mirai(s.start_tangent)
    b.end,b.end_tangent=level.point_to_mirai(s.end),level.point_to_mirai(s.end_tangent)
    b.up=linalg.normalize0(level.point_to_mirai(up))
    b.start_roll,b.end_roll=f32(s.start_roll),f32(s.end_roll)
    b.start_scale,b.end_scale={f32(s.start_scale.x),f32(s.start_scale.y)},{f32(s.end_scale.x),f32(s.end_scale.y)}
    b.start_offset,b.end_offset={f32(s.start_offset.x/100),f32(s.start_offset.y/100)},{f32(s.end_offset.x/100),f32(s.end_offset.y/100)}
    b.smooth=smooth
    if abs(boundary.y-boundary.x)>1e-8 {b.range={f32(boundary.x/100),f32(boundary.y/100)}}
    return b,true
}

spline_mesh_bend :: proc(c:^unreal_scene.Context,a,k:int,e:base.Entity_Id) {
    unreal_scene.zone(c,"shapes.spline_mesh")
    d:=c.d
    ref:=d.components[k].ref
    s,read:=level.spline_mesh_of(d,ref)
    forward,_:=level.enum_of(d,ref,"ForwardAxis","X")
    up,_:=level.vector_of(d,ref,"SplineUpDir",{0,0,1})
    smooth,_:=level.bool_of(d,ref,"bSmoothInterpRollScale",false)
    low,_:=level.real_of(d,ref,"SplineBoundaryMin",0)
    high,_:=level.real_of(d,ref,"SplineBoundaryMax",0)
    bend,made:=spline_bend(s,forward,up,smooth,{low,high})
    if !read || !made || !shapes.bend_valid(bend) {
        unreal_scene.warn(c,"%s: the spline of %s could not be read or is out of range; its mesh is drawn straight",d.actors[a].label,d.components[k].name)
        return
    }
    if !unreal_scene.component_set(c,e,"Bend",&bend) {return}
    profile,enabled,_:=level.component_collision(d,ref,"NoCollision")
    if use,_:=level.bool_of(d,ref,"bUseDefaultCollision",false);use {
        if body,has:=unreal_scene.mesh_body(c,level.path_of(d,ref,"StaticMesh"));has && body.profile!="" {profile=body.profile}
    }
    if !level.profile_collides(profile,enabled) {return}
    collider:=phys.COLLIDER_DEFAULT
    collider.kind=.External
    unreal_scene.component_set(c,e,"Collider",&collider)
}
