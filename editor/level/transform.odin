package level

import "core:math"
import "core:math/linalg"
import "core:strings"
import importer "mirai:cook/import"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

// Unreal's space: centimetres, +X forward, +Y right, +Z up, left-handed; v
// from the top of the image. Mirai's -Z (the front of everything) is Unreal's
// +X, +X (the right) is +Y and +Y is up: a reflection, baked as cook/import
// bakes every space.
SPACE :: importer.Source_Space{meters_per_unit=0.01,axes={.Y,.Z,.Negative_X},v_origin=.Top}

// The relative transform of a scene component as Unreal keeps it:
// centimetres, degrees of Pitch, Yaw and Roll, and which parts are absolute.
Relative :: struct {
    location:[3]f64,
    rotation:[3]f64,
    scale:[3]f64,
    absolute:[3]bool, // location, rotation, scale
}

// USceneComponent's defaults.
RELATIVE_DEFAULT :: Relative{scale={1,1,1}}

// A transform of Unreal in Mirai's space.
transform_to_mirai :: proc(location,rotation,scale:[3]f64) -> (t:mm.Transform,error:unreal.Error) {
    for value in ([9]f64{location.x,location.y,location.z,rotation.x,rotation.y,rotation.z,scale.x,scale.y,scale.z}) {
        if value-value!=0 || abs(value)>1e12 {return {},{.Malformed,0,"transform must be finite"}}
    }
    basis,_:=importer.space_basis(SPACE)
    q:=unreal.rotator_quaternion(rotation.x,rotation.y,rotation.z)
    unreal_t:=mm.Transform{
        position={f32(location.x),f32(location.y),f32(location.z)},
        rotation=quaternion(w=f32(q.w),x=f32(q.x),y=f32(q.y),z=f32(q.z)),
        scale={f32(scale.x),f32(scale.y),f32(scale.z)},
    }
    return importer.space_transform(basis,unreal_t),{}
}

// A matrix of Unreal (row vectors: the axes it turns X, Y and Z into, scaled,
// and the location) in Mirai's space. A mirroring matrix flips its X; a
// matrix with an axis of zero has no rotation to take.
matrix_to_mirai :: proc(m:[4][4]f64) -> (t:mm.Transform,error:unreal.Error) {
    scale:[3]f64
    for row in 0..<3 {
        scale[row]=linalg.length([3]f64{m[row][0],m[row][1],m[row][2]})
        if !(scale[row]>1e-12) {return {},{.Malformed,0,"instance scale has an axis of zero"}}
    }
    rotation:matrix[3,3]f64
    for row in 0..<3 {for column in 0..<3 {rotation[column,row]=m[row][column]/scale[row]}}
    if linalg.determinant(rotation)<0 {
        scale.x=-scale.x
        for column in 0..<3 {rotation[column,0]=-rotation[column,0]}
    }
    q:=linalg.quaternion_from_matrix3(rotation)
    location:=[3]f64{m[3][0],m[3][1],m[3][2]}
    for value in ([6]f64{location.x,location.y,location.z,scale.x,scale.y,scale.z}) {
        if value-value!=0 || abs(value)>1e12 {return {},{.Malformed,0,"transform must be finite"}}
    }
    basis,_:=importer.space_basis(SPACE)
    unreal_t:=mm.Transform{
        position={f32(location.x),f32(location.y),f32(location.z)},
        rotation=quaternion(w=f32(q.w),x=f32(q.x),y=f32(q.y),z=f32(q.z)),
        scale={f32(scale.x),f32(scale.y),f32(scale.z)},
    }
    return importer.space_transform(basis,unreal_t),{}
}

// A point of Unreal (centimetres) in Mirai's space (metres).
point_to_mirai :: proc "contextless" (p:[3]f64) -> [3]f32 {
    basis,_:=importer.space_basis(SPACE)
    return importer.space_point(basis,{f32(p.x),f32(p.y),f32(p.z)})
}

// What Unreal's native actors (lights, spot lights, decals, the default
// pawn) set on a default subobject when they are made: the archetype
// of every instance, which keeps nothing when it does not change them. Of
// the native actors of ContentExamples, no other moves a subobject that is
// not of the editor.
@(private)
Native_Relative :: struct {actor,component:string,set:[3]bool,value:[3][3]f64}

@(private)
NATIVE_RELATIVES :: [?]Native_Relative{
    {"DirectionalLight","LightComponent0",{false,true,true},{{},{-46,0,0},{2.5,2.5,2.5}}},
    {"SpotLight","LightComponent0",{false,true,false},{{},{-90,0,0},{}}},
    {"DecalActor","NewDecalComponent",{false,true,false},{{},{-90,0,0},{}}},
    // The sphere of the engine, 160 units across, to the 35 of its collision.
    {"DefaultPawn","MeshComponent0",{false,false,true},{{},{},{35.0/160,35.0/160,35.0/160}}},
}

// The class of /Script/Engine an actor's class derives from; "" for another.
@(private)
native_actor_class :: proc(d:^Document,actor:int) -> string {
    c:=actor_native_class(d,actor)
    return c.pkg=="/Script/Engine"?c.name:""
}

// The native class (of a /Script package) an actor's class is or derives
// from, through the super classes of its Blueprints; none when the chain
// leaves the library.
actor_native_class :: proc(d:^Document,actor:int) -> Class {
    ref:=d.actors[actor].ref
    p:=library_package(d.library,int(ref.pkg))
    class:=p.exports[int(ref.object)-1].class
    for _ in 0..<OUTER_DEPTH {
        c:=class_of(p,class)
        if strings.has_prefix(c.pkg,"/Script/") {return c}
        if c.pkg=="" {return {}}
        owner:Ref
        if class>0 {
            owner={ref.pkg,class}
        } else {
            target,native,error:=import_target(d,p,class,false)
            if error.code!=.None || native {return {}}
            owner=target
        }
        ref=owner
        p=library_package(d.library,int(owner.pkg))
        class=p.exports[int(owner.object)-1].super
    }
    return {}
}

// The relative transform of a component, from it or its archetypes, with the
// defaults of USceneComponent, or of the constructor of its actor's native
// class, where none has a value.
component_relative :: proc(d:^Document,component:int) -> (r:Relative,error:unreal.Error) {
    r=RELATIVE_DEFAULT
    ref:=d.components[component].ref
    natives:=NATIVE_RELATIVES
    native_class:=""
    VECTORS :: [3]string{"RelativeLocation","RelativeRotation","RelativeScale3D"}
    for name,i in VECTORS {
        f:Found
        f,error=property(d,ref,name)
        if error.code!=.None {return}
        if f.property==nil {
            if native_class=="" {native_class=native_actor_class(d,d.components[component].actor)}
            for n in natives {
                if n.set[i] && n.actor==native_class && n.component==d.components[component].name {
                    switch i {
                    case 0:r.location=n.value[i]
                    case 1:r.rotation=n.value[i]
                    case 2:r.scale=n.value[i]
                    }
                }
            }
            continue
        }
        v:unreal.Value
        v,error=unreal.property_value(f.pkg,f.property)
        if error.code!=.None {return}
        if v.kind!=.Real_Vector || v.vector_count!=3 {return {},{.Unsupported_Value,f.property.data.offset,"relative transform requires a vector or rotator"}}
        value:=[3]f64{v.vector[0],v.vector[1],v.vector[2]}
        switch i {
        case 0:r.location=value
        case 1:r.rotation=value
        case 2:r.scale=value
        }
    }
    FLAGS :: [3]string{"bAbsoluteLocation","bAbsoluteRotation","bAbsoluteScale"}
    for name,i in FLAGS {
        r.absolute[i],_=bool_of(d,ref,name,false)
    }
    return
}

// The transform of a component relative to its parent, in Mirai's space.
component_local :: proc(d:^Document,component:int) -> (t:mm.Transform,error:unreal.Error) {
    r:Relative
    r,error=component_relative(d,component)
    if error.code!=.None {return}
    return transform_to_mirai(r.location,r.rotation,r.scale)
}

// Where a component is in the world, in Mirai's space: its relative
// transform through AttachParent, the absolute parts taken as they are. One
// attached to a socket (AttachSocketName) is relative to where the socket of
// its parent is (component_socket).
component_world :: proc(d:^Document,component:int) -> (t:mm.Transform,error:unreal.Error) {
    chain:[OUTER_DEPTH]int
    depth:=0
    for at:=component;at>=0;at=d.components[at].parent {
        if depth>=len(chain) {return {},{.Cyclic_Outer,0,"AttachParent chain"}}
        chain[depth]=at
        depth+=1
    }
    t=mm.TRANSFORM_IDENTITY
    for i:=depth-1;i>=0;i-=1 {
        r:Relative
        r,error=component_relative(d,chain[i])
        if error.code!=.None {return}
        local:mm.Transform
        local,error=transform_to_mirai(r.location,r.rotation,r.scale)
        if error.code!=.None {return}
        if i==depth-1 {t=local;continue}
        if socket:=d.components[chain[i]].socket;socket!="" {
            t,error=component_socket(d,chain[i+1],t,socket)
            if error.code!=.None {return}
        }
        world:=mm.transform_compose(t,local)
        if r.absolute[0] {world.position=local.position}
        if r.absolute[1] {world.rotation=local.rotation}
        if r.absolute[2] {world.scale=local.scale}
        t=world
    }
    return
}

// The world transform of an actor: that of its root component; false
// without one (an actor with no place, such as WorldSettings).
actor_world :: proc(d:^Document,actor:int) -> (t:mm.Transform,placed:bool,error:unreal.Error) {
    root:=d.actors[actor].root
    if root<0 {return mm.TRANSFORM_IDENTITY,false,{}}
    t,error=component_world(d,root)
    return t,error.code==.None,error
}
