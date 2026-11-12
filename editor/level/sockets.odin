package level

import "core:strings"
import importer "mirai:cook/import"
import umesh "project:plugins/unreal/editor/mesh"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

// The places a component gives what is attached to it by name
// (AttachSocketName), as Unreal's components give them: the sockets of a static mesh; the sockets of a
// skeletal mesh and then of its skeleton, on their bones, and then its bones,
// in its bind pose; the end of a spring arm. A name a component does not have
// is the component itself.

// The named places of a mesh, in the space of the component that shows it
// (Mirai's), the first of a name first.
Mesh_Sockets :: struct {
    names:[]string,
    places:[]mm.Transform,
    error:unreal.Error,
}

SPRING_ARM_SOCKET :: "SpringEndpoint" // the socket at the end of a SpringArmComponent

@(private)
mesh_sockets_destroy :: proc(s:^Mesh_Sockets,allocator:=context.allocator) {
    for name in s.names {delete(name,allocator)}
    delete(s.names,allocator)
    delete(s.places,allocator)
}

// Where socket name of component k is in the world, world being where k is.
component_socket :: proc(d:^Document,k:int,world:mm.Transform,name:string) -> (t:mm.Transform,error:unreal.Error) {
    component:=d.components[k]
    path:string
    switch component.class.name {
    case "StaticMeshComponent","InstancedStaticMeshComponent","HierarchicalInstancedStaticMeshComponent","FoliageInstancedStaticMeshComponent":
        path=path_of(d,component.ref,"StaticMesh")
    case "SkeletalMeshComponent","PoseableMeshComponent":
        path=path_of(d,component.ref,"SkeletalMesh")
        if path=="" {path=path_of(d,component.ref,"SkinnedAsset")}
    case "SplineMeshComponent":
        return {},{.Unsupported_Value,0,"a socket of a spline mesh bends with its spline"}
    case "SpringArmComponent":
        if strings.equal_fold(name,SPRING_ARM_SOCKET) {return spring_arm_end(d,k,world)}
        return world,{}
    case:
        return world,{}
    }
    if path=="" {return world,{}}
    s:=mesh_sockets(d,path)
    if s.error.code!=.None {return {},s.error}
    // Names of Unreal compare without case.
    for n,i in s.names {
        if strings.equal_fold(n,name) {return mm.transform_compose(world,s.places[i]),{}}
    }
    return world,{}
}

// The named places of the mesh at path, read once.
mesh_sockets :: proc(d:^Document,path:string) -> Mesh_Sockets {
    if found,ok:=d.sockets[path];ok {return found}
    s:=mesh_sockets_read(d,path)
    d.sockets[strings.clone(path,d.allocator)]=s
    return s
}

@(private)
mesh_sockets_read :: proc(d:^Document,path:string) -> (s:Mesh_Sockets) {
    dot:=strings.index_byte(path,'.')
    if dot<0 {s.error={.Invalid_Reference,0,"the mesh of a socket"};return}
    package_name,object:=path[:dot],path[dot+1:]
    index,error:=library_find(d.library,package_name)
    if error.code!=.None {s.error=error;return}
    p:=library_package(d.library,index)
    at:=-1
    for item,i in p.exports {
        if item.outer==0 && unreal.name_plain(p,item.object_name)==object {at=i;break}
    }
    if at<0 {s.error={.Invalid_Reference,0,"the mesh of a socket is not in its package"};return}
    names:=make([dynamic]string,context.temp_allocator)
    places:=make([dynamic]mm.Transform,context.temp_allocator)
    switch {
    case export_is(p,unreal.Object_Ref(at+1),"/Script/Engine","StaticMesh"):
        // StaticMeshSocket: relative to the component.
        f,f_error:=property(d,{i32(index),unreal.Object_Ref(at+1)},"Sockets")
        if f_error.code!=.None {s.error=f_error;return}
        if f.property==nil {break}
        view,view_error:=unreal.property_array(f.pkg,f.property)
        if view_error.code!=.None {s.error=view_error;return}
        refs,refs_error:=unreal.array_object_refs(f.pkg,view,context.temp_allocator)
        if refs_error.code!=.None {s.error=refs_error;return}
        for object in refs {
            if object<=0 || library_package(d.library,index)!=f.pkg {continue}
            socket:=Ref{i32(index),object}
            name:=name_full_of(d,socket,"SocketName")
            if name=="" {continue}
            location,_:=vector_of(d,socket,"RelativeLocation",{})
            rotation,_:=vector_of(d,socket,"RelativeRotation",{})
            scale,_:=vector_of(d,socket,"RelativeScale",{1,1,1})
            place,place_error:=transform_to_mirai(location,rotation,scale)
            if place_error.code!=.None {s.error=place_error;return}
            append(&names,name)
            append(&places,place)
        }
    case export_is(p,unreal.Object_Ref(at+1),"/Script/Engine","SkeletalMesh"):
        mesh,mesh_error:=umesh.skeletal_read(p,at,context.temp_allocator)
        if mesh_error.code!=.None {s.error=mesh_error;return}
        // The bones in the space of the component: the reference pose composed from the root.
        basis,_:=importer.space_basis(SPACE)
        bones:=make([]mm.Transform,len(mesh.bones),context.temp_allocator)
        for b,i in mesh.bones {
            local:=importer.space_transform(basis,{
                position=b.translation,
                rotation=quaternion(w=b.rotation[3],x=b.rotation[0],y=b.rotation[1],z=b.rotation[2]),
                scale=b.scale,
            })
            bones[i]=b.parent>=0?mm.transform_compose(bones[b.parent],local):local
        }
        sockets:=make([dynamic]umesh.Socket,context.temp_allocator)
        append(&sockets,..mesh.sockets)
        if mesh.skeleton!="" {
            skeleton,skeleton_error:=skeleton_of(d,mesh.skeleton)
            if skeleton_error.code!=.None {s.error=skeleton_error;return}
            append(&sockets,..skeleton.sockets)
        }
        for socket in sockets {
            bone:=-1
            for b,i in mesh.bones {if strings.equal_fold(b.name,socket.bone) {bone=i;break}}
            if bone<0 {continue}
            local,local_error:=transform_to_mirai(socket.location,socket.rotation,socket.scale)
            if local_error.code!=.None {s.error=local_error;return}
            append(&names,socket.name)
            append(&places,mm.transform_compose(bones[bone],local))
        }
        for b,i in mesh.bones {
            append(&names,b.name)
            append(&places,bones[i])
        }
    case:
        s.error={.Unsupported_Value,0,"the mesh of a socket is neither a StaticMesh nor a SkeletalMesh"}
        return
    }
    s.names=make([]string,len(names),d.allocator)
    for name,i in names {s.names[i]=strings.clone(name,d.allocator)}
    s.places=make([]mm.Transform,len(places),d.allocator)
    copy(s.places,places[:])
    return
}

// The Skeleton at path, read in the temp allocator.
@(private)
skeleton_of :: proc(d:^Document,path:string) -> (skeleton:umesh.Skeleton,error:unreal.Error) {
    dot:=strings.index_byte(path,'.')
    if dot<0 {return {},{.Invalid_Reference,0,"the skeleton of a skeletal mesh"}}
    index:int
    index,error=library_find(d.library,path[:dot])
    if error.code!=.None {return}
    p:=library_package(d.library,index)
    for item,i in p.exports {
        if item.outer==0 && unreal.name_plain(p,item.object_name)==path[dot+1:] {
            return umesh.skeleton_read(p,i,context.temp_allocator)
        }
    }
    return {},{.Invalid_Reference,0,"the skeleton of a skeletal mesh is not in its package"}
}

// Where the end of spring arm k is, at rest, world being where k is
// (without the lag and the sweep a game does): TargetArmLength back along its rotation from its
// place moved by TargetOffset, then SocketOffset along its rotation; the
// rotation of the actor with bUsePawnControlRotation, the view of a pawn
// that no controller turned.
@(private)
spring_arm_end :: proc(d:^Document,k:int,world:mm.Transform) -> (t:mm.Transform,error:unreal.Error) {
    ref:=d.components[k].ref
    rotation:=world.rotation
    if pawn,_:=bool_of(d,ref,"bUsePawnControlRotation",false);pawn {
        actor:mm.Transform
        placed:bool
        actor,placed,error=actor_world(d,d.components[k].actor)
        if error.code!=.None {return}
        if placed {rotation=actor.rotation}
    }
    if absolute,_:=bool_of(d,ref,"bAbsoluteRotation",false);!absolute {
        for flag in ([3]string{"bInheritPitch","bInheritYaw","bInheritRoll"}) {
            if inherit,_:=bool_of(d,ref,flag,true);!inherit {
                return {},{.Unsupported_Value,0,"a spring arm that does not inherit the pitch, yaw or roll of its rotation"}
            }
        }
    }
    length,_:=real_of(d,ref,"TargetArmLength",300)
    target,_:=vector_of(d,ref,"TargetOffset",{})
    offset,_:=vector_of(d,ref,"SocketOffset",{})
    t=world
    t.rotation=rotation
    t.position=world.position+point_to_mirai(target)+mm.quat_rotate(rotation,point_to_mirai(offset-{length,0,0}))
    return
}

// The text of a name property through the archetypes, with its number; "" for none.
@(private)
name_full_of :: proc(d:^Document,ref:Ref,name:string) -> string {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return ""}
    v,value_error:=unreal.property_value(f.pkg,f.property)
    if value_error.code!=.None || v.kind!=.Name {return ""}
    if unreal.name_plain(f.pkg,v.name)=="None" && v.name.number==0 {return ""}
    return unreal.name_text(f.pkg,v.name,context.temp_allocator)
}
