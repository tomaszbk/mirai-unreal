package unreal_physics_editor

import "core:fmt"
import "project:plugins/unreal/editor/level"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:std/base"
import phys "plugins:physics/runtime"

// The collision of an Unreal level imported by the editor.
// - Blocking volumes: a box collider on a static body of its own where the
//   volume is, of the size of its CubeBuilder. A volume built otherwise, or
//   whose brush was reshaped by hand, is a warning: its BSP brush is not read.
// - Static meshes: the collision of the BodySetup of the mesh, where the
//   BodyInstance of the component collides (the instances of an instanced
//   one are foliage, which collides by its types). Boxes, spheres and
//   capsules alone are colliders of child entities where they lie in the
//   mesh. With a convex, the entity collides with the colliders its imported
//   mesh stores: the hull of the convex when it is the only shape, and the
//   hulls of all its shapes as triangles otherwise (the hull of all of them
//   for a body that simulates). A mesh without
//   simple shapes, or that uses its complex collision as simple, collides
//   with its triangles: Unreal answers traces with them, and characters walk
//   on them. A component that simulates is a dynamic body.
@(storage)
Physics_Unreal :: struct {provider:unreal_scene.Translator_Provider}

physics_unreal_default :: proc() -> (p:Physics_Unreal) {
    p.provider.count=2
    p.provider.translators[0]={classes={0="BlockingVolume"},translate=volumes_translate}
    p.provider.translators[1]={classes={0="StaticMeshComponent"},component=mesh_collision}
    return
}

volumes_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"physics.volumes")
    d:=c.d
    translated,other:=0,0
    for a in actors {
        builder:=-1
        for k in d.actors[a].first_component..<d.actors[a].first_component+d.actors[a].component_count {
            if d.components[k].class.name=="CubeBuilder" {builder=k;break}
        }
        if builder<0 || d.actors[a].root<0 {other+=1;continue}
        ref:=d.components[builder].ref
        // Unreal's X, Y and Z are Mirai's Z, X and Y.
        x,_:=level.real_of(d,ref,"X",200)
        y,_:=level.real_of(d,ref,"Y",200)
        z,_:=level.real_of(d,ref,"Z",200)
        world,_,error:=level.actor_world(d,a)
        if error.code!=.None {other+=1;continue}
        e,made:=unreal_scene.entity_make(c,0,unreal_scene.actor_key(c,a),d.actors[a].label,world)
        if !made {return translated}
        collider:=phys.collider_box({f32(y)/200,f32(z)/200,f32(x)/200})
        if !unreal_scene.component_set(c,e,"Collider",&collider) {return translated}
        translated+=1
    }
    if other>0 {unreal_scene.warn(c,"%d blocking volumes are not boxes of a CubeBuilder; their brushes are not read",other)}
    return translated
}

mesh_collision :: proc(c:^unreal_scene.Context,a,k:int,e:base.Entity_Id) {
    unreal_scene.zone(c,"physics.collision")
    d:=c.d
    ref:=d.components[k].ref
    profile,enabled,simulate:=level.component_collision(d,ref)
    body,ok:=unreal_scene.mesh_body(c,level.path_of(d,ref,"StaticMesh"))
    if !ok {return}
    if use,_:=level.bool_of(d,ref,"bUseDefaultCollision",false);use && body.profile!="" {profile=body.profile}
    if !level.profile_collides(profile,enabled) {return}
    convexes:=0
    for shape in body.shapes {if shape.kind==.Convex {convexes+=1}}
    whole:=phys.Collider_Kind.Hull if simulate else .Mesh
    if body.trace==.Complex_As_Simple || len(body.shapes)==0 {
        // The triangles of what the mesh draws: a mesh asset without colliders gives them.
        collider:=phys.collider_mesh() if whole==.Mesh else phys.collider_hull()
        if !unreal_scene.component_set(c,e,"Collider",&collider) {return}
    } else if convexes>0 {
        collider:=phys.collider_hull() if len(body.shapes)==1 || simulate else phys.collider_mesh()
        if !unreal_scene.component_set(c,e,"Collider",&collider) {return}
    } else {
        for shape,i in body.shapes {
            collider:phys.Collider
            switch shape.kind {
            case .Convex: continue
            case .Box: collider=phys.collider_box(shape.size)
            case .Sphere: collider=phys.collider_sphere(shape.size.x)
            case .Capsule: collider=phys.collider_capsule(shape.size.x,shape.size.y)
            }
            child,made:=unreal_scene.entity_make(c,e,fmt.tprintf("%x|collision %d",u64(e),i),fmt.tprintf("Collision %d",i),shape.place)
            if !made || !unreal_scene.component_set(c,child,"Collider",&collider) {return}
        }
    }
    if simulate {
        rigid:=phys.RIGID_BODY_DYNAMIC
        unreal_scene.component_set(c,e,"Rigid_Body",&rigid)
    }
}
