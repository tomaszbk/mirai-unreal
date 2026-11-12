package mesh

import "core:mem"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/base"

// Pose assets of uncooked packages as animations: a frame per pose, which the
// editor turns into the curve poses of a .pose profile (pose.profile.poses).
//
//   pose_asset_read   the source poses of a PoseAsset, its pose names and its
//                     curves, as an Animation of a key per frame

// Seconds from a frame of a pose asset to the next.
POSE_ASSET_INTERVAL :: 1.0/30

// Whether an export is a PoseAsset of /Script/Engine.
pose_asset_is :: proc(p:^unreal.Package,index:int) -> bool {return export_is(p,index,"PoseAsset")}

// A PoseAsset as an animation that holds each key: frame 0 is the base of its
// poses and frame k+1 its pose k, which a sync marker of the pose's name
// marks. The base of an additive asset is the pose BasePoseIndex names; that
// of another (or of an additive without one) is the reference pose of its
// skeleton, which rest_first asks the importer to put. The poses are the
// source ones, whole, that Unreal keeps with the editor data before making
// them additive. Each curve of the asset is a float curve with the value of
// each pose at its frame and zero at the base.
pose_asset_read :: proc(p:^unreal.Package,index:int,allocator:=context.allocator) -> (Animation,unreal.Error) {
    a:Animation
    error:unreal.Error
    if !pose_asset_is(p,index) {return {},{.Invalid_Reference,0,"export is not a PoseAsset"}}
    at:=p.exports[index].data.offset
    arena,arena_error:=new(mem.Dynamic_Arena,allocator)
    if arena_error!=nil {return {},{.Out_Of_Memory,at,"pose asset"}}
    mem.dynamic_arena_init(arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    a.arena,a.allocator=arena,base.dynamic_arena_allocator(arena)
    defer if error.code!=.None {animation_destroy(&a)}
    a.object=unreal.Object_Ref(index+1)
    error=pose_asset_fill(p,index,&a)
    if error.code!=.None {return {},error}
    return a,{}
}

@(private)
pose_asset_fill :: proc(p:^unreal.Package,index:int,a:^Animation) -> (error:unreal.Error) {
    allocator:=a.allocator
    at:=p.exports[index].data.offset
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&properties)
    e:=&error
    if skeleton:=object_of(p,&properties,"Skeleton",e);skeleton!=0 && error.code==.None {
        a.skeleton,error=unreal.reference_path(p,skeleton,allocator)
    }
    additive:=bool_of(p,&properties,"bAdditivePose",false,e)
    base_pose:=int(int_of(p,&properties,"BasePoseIndex",-1,e))
    if error.code!=.None {return}
    holder:=unreal.property_find(p,&properties,"PoseContainer")
    if holder==nil {return {.Unsupported_Value,at,"pose asset has no PoseContainer"}}
    container:unreal.Property_List
    container,error=unreal.property_tagged_struct(p,holder,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&container)

    names:=pose_names_read(p,&container,e)
    tracks:=names_of(p,&container,"Tracks",e)
    curves:=pose_curve_names_read(p,&container,e)
    if error.code!=.None {return}
    poses:unreal.Struct_Array
    if property:=unreal.property_find(p,&container,"Poses");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return}
        poses,error=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
        if error.code!=.None {return}
    }
    defer unreal.struct_array_destroy(&poses)
    if len(poses.items)!=len(names) {return {.Malformed,at,"pose asset has another count of poses than of names"}}
    if len(names)==0 {return {.Unsupported_Value,at,"pose asset has no poses"}}
    frames:=len(names)+1
    a.rate,a.step,a.interval,a.keys=1,true,POSE_ASSET_INTERVAL,frames
    if !additive || base_pose<0 || base_pose>=len(names) {a.rest_first=true}

    a.tracks=make([]Bone_Track,len(tracks),allocator)
    for name,t in tracks {
        a.tracks[t]={name=unreal.name_text(p,name,allocator),positions=make([][3]f32,frames,allocator),rotations=make([][4]f32,frames,allocator),scales=make([][3]f32,frames,allocator)}
        a.tracks[t].rotations[0]={0,0,0,1};a.tracks[t].scales[0]={1,1,1}
    }
    a.curves=make([]Float_Curve,len(curves),allocator)
    for name,c in curves {
        a.curves[c]={name=strings.clone(name,allocator),keys=make([]Curve_Key,frames,allocator),pre=.Constant,post=.Constant}
        for &key,k in a.curves[c].keys {key={time=f32(f64(k)*POSE_ASSET_INTERVAL),interpolation=.Constant}}
    }
    a.markers=make([]Sync_Marker,len(names),allocator)
    for &pose,i in poses.items {
        frame:=i+1
        a.markers[i]={name=unreal.name_text(p,names[i],allocator),time=f32(f64(frame)*POSE_ASSET_INTERVAL)}
        // The source pose, whole; a save without one keeps only the pose Unreal plays.
        source:=unreal.property_find(p,&pose,"SourceLocalSpacePose")
        if source==nil {return {.Unsupported_Value,at,"pose asset keeps no source poses; resave it in an editor of Unreal 5"}}
        transforms:=transforms_of(p,source,e)
        if error.code!=.None {return}
        if len(transforms)!=len(tracks) {return {.Malformed,source.data.offset,"source pose has another count of bones than the tracks"}}
        for transform,t in transforms {
            a.tracks[t].positions[frame],a.tracks[t].rotations[frame],a.tracks[t].scales[frame]=transform.position,transform.rotation,transform.scale
            if !a.rest_first && i==base_pose {a.tracks[t].positions[0],a.tracks[t].rotations[0],a.tracks[t].scales[0]=transform.position,transform.rotation,transform.scale}
        }
        values:=reals_of(p,&pose,"SourceCurveData",e)
        if error.code!=.None {return}
        if len(values)!=0 && len(values)!=len(curves) {return {.Malformed,at,"pose has another count of curve values than the asset has curves"}}
        for value,c in values {a.curves[c].keys[frame].value=value}
    }
    return
}

@(private)
Pose_Transform :: struct {position:[3]f32,rotation:[4]f32,scale:[3]f32}

// The tagged Transforms of an array property.
@(private)
transforms_of :: proc(p:^unreal.Package,property:^unreal.Property,error:^unreal.Error) -> []Pose_Transform {
    view,view_error:=unreal.property_array(p,property)
    if view_error.code!=.None {error^=view_error;return nil}
    items,items_error:=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
    if items_error.code!=.None {error^=items_error;return nil}
    out:=make([]Pose_Transform,len(items.items),context.temp_allocator)
    for &item,i in items.items {
        rotation:=quaternion_of(p,&item,"Rotation",error)
        translation,_:=vector_of(p,&item,"Translation",error)
        scale,scaled:=vector_of(p,&item,"Scale3D",error)
        if !scaled {scale={1,1,1}}
        if error.code!=.None {return nil}
        out[i]={position={f32(translation.x),f32(translation.y),f32(translation.z)},rotation={rotation.x,rotation.y,rotation.z,rotation.w},scale={f32(scale.x),f32(scale.y),f32(scale.z)}}
    }
    return out
}

// The floats of an array property.
@(private)
reals_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,error:^unreal.Error) -> []f32 {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return nil}
    view,view_error:=unreal.property_array(p,property)
    if view_error.code!=.None {error^=view_error;return nil}
    if i64(view.count)*4!=view.data.size {error^={.Malformed,property.data.offset,"float array size"};return nil}
    bytes,_:=unreal.span_bytes(p,view.data)
    out:=make([]f32,view.count,context.temp_allocator)
    for &value,i in out {
        value=f32_at(bytes,i*4)
        if !(value-value==0) {error^={.Malformed,property.data.offset,"curve value is not finite"};return nil}
    }
    return out
}

// The names of an array of Name.
@(private)
names_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,error:^unreal.Error) -> []unreal.Name_Ref {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return nil}
    view,view_error:=unreal.property_array(p,property)
    if view_error.code!=.None {error^=view_error;return nil}
    names,names_error:=unreal.array_names(p,view,context.temp_allocator)
    if names_error.code!=.None {error^=names_error;return nil}
    return names
}

// The names of the poses: PoseFNames, or the SmartNames of PoseNames, which
// keep their DisplayName alone.
@(private)
pose_names_read :: proc(p:^unreal.Package,list:^unreal.Property_List,error:^unreal.Error) -> []unreal.Name_Ref {
    if unreal.property_find(p,list,"PoseFNames")!=nil {return names_of(p,list,"PoseFNames",error)}
    property:=unreal.property_find(p,list,"PoseNames")
    if property==nil || error.code!=.None {return nil}
    view,view_error:=unreal.property_array(p,property)
    if view_error.code!=.None {error^=view_error;return nil}
    if i64(view.count)*8!=view.data.size {error^={.Unsupported_Value,property.data.offset,"pose names saved with a layout of FSmartName that is not read; resave the pose asset in Unreal 5"};return nil}
    bytes,_:=unreal.span_bytes(p,view.data)
    out:=make([]unreal.Name_Ref,view.count,context.temp_allocator)
    for &name,i in out {
        r:=reader_make(bytes[i*8:][:8],view.data.offset+i64(i*8))
        name=name_read(&r,p,"pose name")
        if failed(&r) {error^=r.error;return nil}
    }
    return out
}

// The names of the curves of a pose asset: the CurveName of each AnimCurveBase, or its smart Name.
@(private)
pose_curve_names_read :: proc(p:^unreal.Package,list:^unreal.Property_List,error:^unreal.Error) -> []string {
    property:=unreal.property_find(p,list,"Curves")
    if property==nil || error.code!=.None {return nil}
    view,view_error:=unreal.property_array(p,property)
    if view_error.code!=.None {error^=view_error;return nil}
    view.native=false
    items,items_error:=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
    if items_error.code!=.None {error^=items_error;return nil}
    out:=make([]string,len(items.items),context.temp_allocator)
    for &item,i in items.items {
        out[i]=name_of(p,&item,"CurveName",context.temp_allocator,error)
        if out[i]=="" && error.code==.None {
            if smart:=unreal.property_find(p,&item,"Name");smart!=nil {
                bytes,_:=unreal.span_bytes(p,smart.data)
                r:=reader_make(bytes,smart.data.offset)
                name:=name_read(&r,p,"curve name")
                if failed(&r) {error^=r.error;return nil}
                out[i]=unreal.name_text(p,name,context.temp_allocator)
            }
        }
        if error.code!=.None {return nil}
    }
    return out
}
