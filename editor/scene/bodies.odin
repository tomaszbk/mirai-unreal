package unreal_scene

import "core:strings"
import importer "mirai:cook/import"
import uasset "project:plugins/unreal/editor/model"
import "project:plugins/unreal/editor/level"
import material "project:plugins/unreal/editor/material"
import umesh "project:plugins/unreal/editor/mesh"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/base"
import mm "mirai:std/math"

// The collision a StaticMesh keeps in its BodySetup, for the plugins that
// translate the collision of the components that show it: its simple shapes
// (AggGeom) in the space of the imported mesh, as its import stores them, how
// the complex collision is used (CollisionTraceFlag) and the collision
// profile of its DefaultInstance.

Body_Shape_Kind :: enum u8 {Box,Sphere,Capsule,Convex}

// A simple shape: where it is in the mesh, and its size. A box: its half
// sizes. A sphere: its radius in x. A capsule: its radius in x and the half
// length of its segment in y, along y. A convex keeps no size: it is a hull
// of the colliders of the imported mesh.
Body_Shape :: struct {
    kind:Body_Shape_Kind,
    place:mm.Transform,
    size:[3]f32,
}

Mesh_Body :: struct {
    mesh:base.Asset_Id,  // the import of the StaticMesh
    shapes:[]Body_Shape,
    trace:umesh.Body_Trace,
    profile:string,      // CollisionProfileName of its DefaultInstance; "" when it does not say
    ok:bool,
}

// The collision of the StaticMesh at an object path, read once.
mesh_body :: proc(c:^Context,path:string) -> (body:Mesh_Body,ok:bool) {
    if found,seen:=c.bodies[path];seen {return found,found.ok}
    defer c.bodies[strings.clone(path,context.temp_allocator)]=body
    // The primitive that stands for a basic shape of the engine collides as
    // Unreal's does: a box, a sphere, or the shape it shows.
    if shape,substitute:=engine_shape(c,path);substitute {
        #partial switch shape {
        case .Cube: body.shapes=make([]Body_Shape,1,context.temp_allocator);body.shapes[0]={kind=.Box,place=mm.TRANSFORM_IDENTITY,size=0.5}
        case .Sphere: body.shapes=make([]Body_Shape,1,context.temp_allocator);body.shapes[0]={kind=.Sphere,place=mm.TRANSFORM_IDENTITY,size={0.5,0,0}}
        }
        body.ok=true
        return body,true
    }
    imported:Mesh_Import
    imported,ok=mesh_import(c,path)
    if !ok {return}
    body.mesh=imported.id
    library_lock(c)
    defer library_unlock(c)
    object,found:=material.object_find(c.lib,path)
    if !found {return body,true}
    body.ok=true
    setup,has:=material.object_child(object,"BodySetup")
    if !has {return body,true}
    read,error:=umesh.body_read(&setup.pkg.p,unreal.Object_Ref(setup.export+1),context.temp_allocator)
    if error.code!=.None {return body,true}
    body.trace,body.profile=read.trace,read.profile
    collision:=uasset.body_collision(read,context.temp_allocator)
    basis,_:=importer.space_basis(level.SPACE)
    importer.space_collision(basis,&collision)
    shapes:=make([]Body_Shape,len(collision.colliders),context.temp_allocator)
    for collider,i in collision.colliders {
        kind:Body_Shape_Kind
        switch collider.kind {
        case .Box: kind=.Box
        case .Sphere: kind=.Sphere
        case .Capsule: kind=.Capsule
        case .Hull,.Mesh: kind=.Convex
        }
        shapes[i]={kind=kind,place={position=collider.center,rotation=collider.rotation,scale=1},size=collider.size}
    }
    body.shapes=shapes
    return body,true
}
