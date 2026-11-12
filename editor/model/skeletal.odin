package uasset

import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import material "project:plugins/unreal/editor/material"
import umesh "project:plugins/unreal/editor/mesh"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/base"
import mm "mirai:std/math"

// The influences a vertex of a .mesh keeps.
INFLUENCES :: len(asset.Skin_Vertex{}.weights)

// A SkeletalMesh: its reference skeleton as a skeleton of the model, named
// after its Skeleton; LOD 0 as a mesh in bind space with a joint per bone,
// whose inverse bind is that of the bone at rest; and a node. Bones and
// inverse binds stay in Unreal's space here: the import turns them with the
// geometry.
@(private)
skeletal_add :: proc(c:^Context,name:string,source:^umesh.Skeletal_Mesh,geometry:^umesh.Skinned_Mesh) -> bool {
    r:=c.r
    skeleton_name:=fmt.tprintf("%s skeleton",name)
    if source.skeleton!="" {_,skeleton_name=object_name_split(source.skeleton)}
    // The sockets of a skeletal mesh: its own, then those of its Skeleton it does not name.
    sockets:=make([dynamic]umesh.Socket,context.temp_allocator)
    append(&sockets,..source.sockets)
    if source.skeleton!="" {
        library_lock(c)
        defer library_unlock(c)
        if object,found:=material.object_find(c.library,source.skeleton);found {
            if skeleton,error:=umesh.skeleton_read(&object.pkg.p,object.export,context.temp_allocator);error.code==.None {
                append(&sockets,..skeleton.sockets)
            } else {
                importer.warn(r,"%s: %s: the sockets of its skeleton %s could not be read (%v: %s)",r.file_name,name,source.skeleton,error.code,error.field)
            }
        } else if len(source.sockets)==0 {
            importer.warn(r,"%s: %s: its skeleton %s is under no mount of the package; its sockets are not imported",r.file_name,name,source.skeleton)
        }
    }
    skeleton:=skeleton_append(r,skeleton_name,source.bones,sockets[:]) or_return
    joints:=make([]asset.Rig_Joint,len(source.bones),r.out)
    world:=make([]mm.Transform,len(source.bones),context.temp_allocator)
    for bone,i in source.bones {
        local:=bone_transform(bone)
        world[i]=local if bone.parent<0 else mm.transform_compose(world[bone.parent],local)
        inverse,ok:=mm.transform_inverse_matrix(world[i])
        if !ok {return importer.fail(r,.Malformed,"%s: %s: the bone %s has a scale of zero at rest",r.file_name,name,bone.name)}
        joints[i]={node=u32(i),inverse_bind=inverse}
    }
    if geometry.left_out>0 {importer.warn(r,"%s: %s: %d sections that Unreal does not draw are left out",r.file_name,name,geometry.left_out)}
    if geometry.cloth>0 {importer.warn(r,"%s: %s: %d sections are simulated as cloth in Unreal; Mirai skins them to their bones",r.file_name,name,geometry.cloth)}
    skin:=skin_vertices(r,name,geometry)
    built:=geometry_build(c,name,source.materials,&geometry.geometry,skin,geometry.morphs,geometry.corner_morph) or_return
    built.joints,built.skeleton=joints,skeleton
    row:=importer.mesh_add(r,built)
    append(&r.nodes,importer.Imported_Node{name=r.meshes[row].name,parent=-1,transform=mm.TRANSFORM_IDENTITY,mesh=row,visible=true})
    r.degenerate+=geometry.degenerate
    return true
}

// A skeleton of the model from a reference skeleton: each bone with its pose
// at rest and the path of its names from the root, which clips bind to, and
// its sockets, the first of each name. A socket of a bone the skeleton does
// not have, or with a scale of zero, is left out with a warning.
@(private)
skeleton_append :: proc(r:^importer.Reader,name:string,bones:[]umesh.Bone,sockets:[]umesh.Socket) -> (row:int,ok:bool) {
    out:=make([]asset.Skeleton_Bone,len(bones),r.out)
    paths:=bone_paths(r,bones) or_return
    for bone,i in bones {
        t:=bone_transform(bone)
        out[i]={parent=i32(bone.parent),target=base.name_hash(paths[i]),translation=t.position,rotation=t.rotation,scale=t.scale}
        asset.text_set(out[i].name[:],bone.name)
        asset.text_set(out[i].path[:],paths[i])
    }
    placed:=make([dynamic]asset.Skeleton_Socket,r.out)
    for socket in sockets {
        bone:=-1
        for b,i in bones {if strings.equal_fold(b.name,socket.bone) {bone=i;break}}
        taken:=false
        for &other in placed {taken||=base.text_get(other.name[:])==socket.name}
        if taken {continue}
        if socket.name=="" || len(socket.name)>=len(asset.Skeleton_Socket{}.name) || bone<0 || socket.scale.x*socket.scale.y*socket.scale.z==0 || !importer.finite3({f32(socket.location.x),f32(socket.location.y),f32(socket.location.z)}) {
            importer.warn(r,"%s: %s: the socket %q on %q is left out: a socket is named by 1 to %d bytes, on a bone of the skeleton, with a scale on every axis",r.file_name,name,socket.name,socket.bone,len(asset.Skeleton_Socket{}.name)-1)
            continue
        }
        q:=unreal.rotator_quaternion(socket.rotation.x,socket.rotation.y,socket.rotation.z)
        out:=asset.Skeleton_Socket{offset={
            position={f32(socket.location.x),f32(socket.location.y),f32(socket.location.z)},
            rotation=quaternion(w=f32(q.w),x=f32(q.x),y=f32(q.y),z=f32(q.z)),
            scale={f32(socket.scale.x),f32(socket.scale.y),f32(socket.scale.z)},
        }}
        asset.text_set(out.name[:],socket.name)
        asset.text_set(out.bone[:],paths[bone])
        append(&placed,out)
    }
    unique:=name
    for at:=2;;at+=1 {
        taken:=false
        for skeleton in r.skeletons {taken||=skeleton.name==unique}
        if !taken {break}
        unique=fmt.tprintf("%s (%d)",name,at)
    }
    append(&r.skeletons,importer.Imported_Skeleton{name=importer.own(r,unique),bones=out,sockets=placed[:]})
    return len(r.skeletons)-1,true
}

@(private)
bone_transform :: proc(bone:umesh.Bone) -> mm.Transform {
    q:=bone.rotation
    return {position=bone.translation,rotation=quaternion(x=q.x,y=q.y,z=q.z,w=q.w),scale=bone.scale}
}

// The skin of each row of the positions: its INFLUENCES largest influences,
// quantized to weigh 255 together (asset.skin_weights_quantize). A vertex with more is warned of; one without any
// follows the root, as Unreal gives it.
@(private)
skin_vertices :: proc(r:^importer.Reader,name:string,geometry:^umesh.Skinned_Mesh) -> []asset.Skin_Vertex {
    skin:=make([]asset.Skin_Vertex,len(geometry.positions),context.temp_allocator)
    over,most,unweighted:=0,0,0
    sorted:=make([dynamic]umesh.Influence,context.temp_allocator)
    for &vertex,row in skin {
        clear(&sorted)
        append(&sorted,..geometry.influences[geometry.skin_first[row]:geometry.skin_first[row+1]])
        influences:=sorted[:]
        slice.sort_by(influences,proc(a,b:umesh.Influence) -> bool {return a.weight>b.weight || a.weight==b.weight && a.bone<b.bone})
        if len(influences)>INFLUENCES {over+=1;most=max(most,len(influences))}
        weights:[INFLUENCES]f32
        total:f32
        for influence,k in influences[:min(len(influences),INFLUENCES)] {
            vertex.joints[k],weights[k]=influence.bone,influence.weight
            total+=influence.weight
        }
        if !(total>0) {
            vertex={}
            unweighted+=1
        }
        vertex.weights=asset.skin_weights_quantize(weights)
        for weight,k in vertex.weights {
            if weight==0 {vertex.joints[k]=0}
        }
    }
    if over>0 {importer.warn(r,"%s: %s: %d vertices have up to %d influences; each keeps its %d largest, weighing one together",r.file_name,name,over,most,INFLUENCES)}
    if unweighted>0 {importer.warn(r,"%s: %s: %d vertices have no influence; they follow the root bone",r.file_name,name,unweighted)}
    return skin
}

// "/Game/M/SK_A.SK_A": its package and its object.
@(private)
object_name_split :: proc(path:string) -> (package_name,object:string) {
    package_name=path
    if dot:=strings.last_index_byte(path,'.');dot>=0 {package_name,object=path[:dot],path[dot+1:]}
    if object=="" {object=package_name[strings.last_index_byte(package_name,'/')+1:]}
    return
}
