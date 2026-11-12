package mesh

import "core:math/linalg"
import "core:mem"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"
import "mirai:std/base"

// Animation sequences of uncooked packages: the source animation Unreal keeps
// with the editor data, each bone track keyed at every frame of the
// sequence, its float curves and its sync markers, in Unreal's space (the
// local transform of each bone, in centimeters).
//
//   animation_read   the properties of an AnimSequence and its tracks, from
//                    wherever its save keeps them

Animation_Layout :: enum u8 {
    Raw_Tracks, // RawAnimationData in the native tail, named by AnimationTrackNames: UE4
    Data_Model, // the BoneAnimationTracks of its AnimDataModel export: UE 5.0 and 5.1
    Sequencer,  // the channels of the FK control rig section of its AnimationSequencerDataModel, evaluated at each frame: since UE 5.2
}

// EAdditiveAnimationType.
Additive_Type :: enum u8 {None,Local_Space,Mesh_Space}
// EAdditiveBasePoseType.
Additive_Base :: enum u8 {None,Ref_Pose,Anim_Scaled,Anim_Frame,Local_Anim_Frame}
// ERootMotionRootLock: where the root stays while its motion is taken out.
Root_Lock :: enum u8 {Ref_Pose,Anim_First_Frame,Zero}

// The local transform of a bone at each key of its animation, or one for
// all of them; without scales its scale is one.
Bone_Track :: struct {
    name:string,
    positions:[][3]f32,
    rotations:[][4]f32, // x, y, z, w, unit length
    scales:[][3]f32,
}

// ERichCurveInterpMode: how a key goes to the next one.
Curve_Interpolation :: enum u8 {Linear,Constant,Cubic,None}
// ERichCurveExtrapolation.
Curve_Extrapolation :: enum u8 {Cycle,Cycle_With_Offset,Oscillate,Linear,Constant,None}

// An RichCurveKey; the tangents are per second.
Curve_Key :: struct {
    time,value:f32,
    arrive,leave:f32,
    interpolation:Curve_Interpolation,
    weighted:bool, // its tangents have weights
}

Float_Curve :: struct {
    name:string,
    morph:bool,        // its flags say it drives a morph target, as saves before the skeleton kept that
    keys:[]Curve_Key,
    pre,post:Curve_Extrapolation,
    default_value:f32, // without keys, when has_default
    has_default:bool,
}

// AnimSyncMarker.
Sync_Marker :: struct {name:string,time:f32}

Animation :: struct {
    object:unreal.Object_Ref,
    layout:Animation_Layout,
    skeleton:string,      // object path of its Skeleton, "" without one
    keys:int,             // of each track that changes: one per frame, the first at 0 and the last at the length
    interval:f64,         // seconds from a key to the next
    tracks:[]Bone_Track,
    curves:[]Float_Curve,
    markers:[]Sync_Marker,
    step:bool,            // Interpolation Step: a key holds until the next one
    rate:f32,             // RateScale: how fast it plays
    root_motion:bool,     // bEnableRootMotion
    force_root_lock:bool, // bForceRootLock: the root stays even without root motion
    root_lock:Root_Lock,
    additive:Additive_Type,
    additive_base:Additive_Base,
    reference_frame:int,  // RefFrameIndex: the frame of the base an additive is made from
    reference:string,     // RefPoseSeq: object path of the animation of the base
    notifies:int,         // AnimNotify events: logic of Unreal, not read
    weighted:int,         // cubic segments of the channels of a sequencer whose tangents have weights, evaluated without them
    rest_first:bool,      // a pose asset whose frame 0 is the reference pose of its skeleton, which the importer puts
    arena:^mem.Dynamic_Arena,
    allocator:mem.Allocator,
}

animation_destroy :: proc(a:^Animation) {
    if a==nil || a.arena==nil {return}
    parent:=a.arena.block_allocator
    mem.dynamic_arena_destroy(a.arena)
    free(a.arena,parent)
    a^={}
}

// Whether an export is an AnimSequence of /Script/Engine.
animation_is :: proc(p:^unreal.Package,index:int) -> bool {return export_is(p,index,"AnimSequence")}

@(private) SEQUENCER_GUID :: [4]u32{0x7B5AE74C,0xD2704C10,0xA9585798,0x0B212A5A}
@(private) UE4_NONUNIFORM_SCALE_ANIMATION :: 335 // VER_UE4_ANIM_SUPPORT_NONUNIFORM_SCALE_ANIMATION
@(private) UE4_SKELETON_GUID :: 338              // VER_UE4_SKELETON_GUID_SERIALIZATION
@(private) UE4_RICH_CURVE_KEY :: 366             // VER_UE4_SERIALIZE_RICH_CURVE_KEY
@(private) UE4_TRACK_CURVES :: 417               // VER_UE4_ANIMATION_ADD_TRACKCURVES
@(private) MAIN_REMOVE_SOURCE_ANIMATION :: 3     // UE5MainStreamObjectVersion::RemovingSourceAnimationData
@(private) RELEASE_RAW_TRACK_SERIALIZER :: 39   // UE5ReleaseStreamObjectVersion::RawAnimSequenceTrackSerializer
@(private) SEQUENCER_FLOAT_CHANNEL :: 12         // SequencerObjectVersion::SerializeFloatChannelCompletely
@(private) FORTNITE_CHANNEL_SHOW_CURVE :: 53     // FortniteMainBranchObjectVersion::SerializeFloatChannelShowCurve

// EAnimAssetCurveFlags::AACF_DriveMorphTarget_DEPRECATED: the curve drives a morph target.
@(private) AACF_DRIVE_MORPH_TARGET :: 1
// The default FrameRate: what a frame rate that keeps no numerator or denominator has.
@(private) FRAME_RATE_DEFAULT :: [2]i64{60000,1}
// RichCurveKey: three enums of a byte and six floats.
@(private) RICH_CURVE_KEY_BYTES :: 3+6*4
// The control of a bone in an FK control rig is its name in lower case and this.
@(private) FK_CONTROL_SUFFIX :: "_CONTROL"
// ERangeBoundTypes::Inclusive.
@(private) RANGE_INCLUSIVE :: 1

// The properties of an AnimSequence export and its bone tracks, curves and
// sync markers, from the native tail (UE4), the AnimDataModel (UE 5.0) or the
// channels of the sequencer model (since UE 5.2), which it evaluates at each
// frame as Unreal does.
animation_read :: proc(p:^unreal.Package,index:int,allocator:=context.allocator) -> (Animation,unreal.Error) {
    a:Animation
    error:unreal.Error
    if !animation_is(p,index) {return {},{.Invalid_Reference,0,"export is not an AnimSequence"}}
    at:=p.exports[index].data.offset
    arena,arena_error:=new(mem.Dynamic_Arena,allocator)
    if arena_error!=nil {return {},{.Out_Of_Memory,at,"animation"}}
    mem.dynamic_arena_init(arena,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    a.arena,a.allocator=arena,base.dynamic_arena_allocator(arena)
    defer if error.code!=.None {animation_destroy(&a)}
    a.object=unreal.Object_Ref(index+1)
    error=animation_fill(p,index,&a)
    if error.code!=.None {return {},error}
    return a,{}
}

@(private)
animation_fill :: proc(p:^unreal.Package,index:int,a:^Animation) -> (error:unreal.Error) {
    allocator:=a.allocator
    at:=p.exports[index].data.offset
    v:=versions_of(p)
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&properties)
    e:=&error
    if skeleton:=object_of(p,&properties,"Skeleton",e);skeleton!=0 && error.code==.None {
        a.skeleton,error=unreal.reference_path(p,skeleton,allocator)
    }
    a.rate=f32(real_of(p,&properties,"RateScale",1,e))
    a.root_motion=bool_of(p,&properties,"bEnableRootMotion",false,e)
    a.force_root_lock=bool_of(p,&properties,"bForceRootLock",false,e)
    a.root_lock=Root_Lock(enum_of(p,&properties,"RootMotionRootLock",{"RefPose","AnimFirstFrame","Zero"},0,e))
    a.additive=Additive_Type(enum_of(p,&properties,"AdditiveAnimType",{"AAT_None","AAT_LocalSpaceBase","AAT_RotationOffsetMeshSpace"},0,e))
    a.additive_base=Additive_Base(enum_of(p,&properties,"RefPoseType",{"ABPT_None","ABPT_RefPose","ABPT_AnimScaled","ABPT_AnimFrame","ABPT_LocalAnimFrame"},0,e))
    a.reference_frame=int(int_of(p,&properties,"RefFrameIndex",0,e))
    a.step=enum_of(p,&properties,"Interpolation",{"Linear","Step"},0,e)==1
    if reference:=object_of(p,&properties,"RefPoseSeq",e);reference!=0 && error.code==.None {
        // Only to name it: a base in the package itself has a path only with its mount.
        a.reference,_=unreal.reference_path(p,reference,allocator)
    }
    if error.code!=.None {return}
    if !(a.rate-a.rate==0) {return {.Malformed,at,"animation rate scale is not finite"}}
    if property:=unreal.property_find(p,&properties,"Notifies");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return}
        a.notifies=int(view.count)
    }
    a.markers,error=sync_markers_read(p,&properties,allocator)
    if error.code!=.None {return}

    model:=object_of(p,&properties,"DataModel",e)
    if error.code!=.None {return}
    if model==0 {
        model,error=interface_of(p,&properties,"DataModelInterface")
        if error.code!=.None {return}
    }
    if model==0 {
        a.layout=.Raw_Tracks
        return raw_tracks_read(p,v,&properties,a)
    }
    model_index:=int(model)-1
    if model<0 || model_index>=len(p.exports) {return {.Unsupported_Value,at,"animation data model is not an export of its package"}}
    class:=p.exports[model_index].class
    switch {
    case unreal.reference_in_package(p,class,"/Script/Engine","AnimDataModel"):
        a.layout=.Data_Model
        return data_model_read(p,model_index,a)
    case unreal.reference_in_package(p,class,"/Script/AnimationData","AnimationSequencerDataModel"):
        a.layout=.Sequencer
        return sequencer_read(p,model_index,a)
    }
    return {.Unsupported_Value,p.exports[model_index].data.offset,"animation data model of an unknown class"}
}

// UE4: RawAnimationData in the native tail of an AnimSequence, after the
// skeleton guid of AnimationAsset and the strip flags; SourceRawAnimationData,
// in saves that have it, wins when it has tracks. Their names are
// AnimationTrackNames and their keys NumFrames, or as many as the longest
// track has, as Unreal corrects them on load.
@(private)
raw_tracks_read :: proc(p:^unreal.Package,v:Versions,properties:^unreal.Property_List,a:^Animation) -> (error:unreal.Error) {
    allocator:=a.allocator
    e:=&error
    keys:=int(int_of(p,properties,"NumFrames",0,e))
    keys=int(int_of(p,properties,"NumberOfKeys",i64(keys),e))
    length:=real_of(p,properties,"SequenceLength",0,e)
    if error.code!=.None {return}
    names:[]unreal.Name_Ref
    if property:=unreal.property_find(p,properties,"AnimationTrackNames");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return}
        names,error=unreal.array_names(p,view,context.temp_allocator)
        if error.code!=.None {return}
    }
    tail:unreal.Span
    tail,error=unreal.object_native_payload(p,properties.trailing)
    if error.code!=.None {return}
    bytes,_:=unreal.span_bytes(p,tail)
    r:=reader_make(bytes,tail.offset)
    if v.ue4>=UE4_SKELETON_GUID {_=take(&r,16,"animation skeleton guid")}
    global:=u8_read(&r,"animation strip flags")
    _=u8_read(&r,"animation class strip flags")
    if failed(&r) {return r.error}
    if global&STRIP_EDITOR!=0 {return {.Cooked,tail.offset,"animation editor data was stripped when cooking"}}
    tracks:=raw_track_array_read(&r,v,allocator)
    if v.ue4>=UE4_TRACK_CURVES && v.main<MAIN_REMOVE_SOURCE_ANIMATION {
        source:=raw_track_array_read(&r,v,allocator)
        if len(source)>0 {tracks=source}
    }
    if failed(&r) {return r.error}
    if len(tracks)!=len(names) {return {.Malformed,tail.offset,"animation has another number of raw tracks than of track names"}}
    most:=0
    for &track,i in tracks {
        track.name=unreal.name_text(p,names[i],allocator)
        most=max(most,len(track.positions),len(track.rotations),len(track.scales))
    }
    if most>keys || most>1 && most<keys {keys=most}
    a.keys=max(keys,1)
    a.interval=length/f64(max(a.keys-1,1))
    a.tracks=tracks
    if error=tracks_check(a,tail.offset);error.code!=.None {return}
    if property:=unreal.property_find(p,properties,"RawCurveData");property!=nil {
        raw:unreal.Property_List
        raw,error=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
        if error.code!=.None {return}
        defer unreal.properties_destroy(&raw)
        a.curves,error=float_curves_read(p,v,&raw,allocator)
    }
    return
}

// An array of RawAnimSequenceTrack: each key array bulk serialized, with the
// size of its element first.
@(private)
raw_track_array_read :: proc(r:^Reader,v:Versions,allocator:mem.Allocator) -> []Bone_Track {
    count:=count_read(r,16,"raw animation track count")
    if failed(r) {return nil}
    tracks:=make([]Bone_Track,count,allocator)
    for &track in tracks {
        track.positions=bulk_vectors_read(r,3,"raw animation positions",allocator)
        track.rotations=bulk_vectors_read(r,4,"raw animation rotations",allocator)
        if v.ue4>=UE4_NONUNIFORM_SCALE_ANIMATION {track.scales=bulk_vectors_read(r,3,"raw animation scales",allocator)}
        if failed(r) {return nil}
    }
    return tracks
}

// An array of float vectors, bulk serialized: the size of an element, the count and the elements.
@(private)
bulk_vectors_read :: proc(r:^Reader,$N:int,field:string,allocator:mem.Allocator) -> [][N]f32 {
    size:=i32_read(r,field)
    count:=count_read(r,N*4,field)
    if failed(r) {return nil}
    if int(size)!=N*4 {bad(r,.Malformed,field);return nil}
    bytes:=take(r,count*N*4,field)
    if failed(r) {return nil}
    out:=make([][N]f32,count,allocator)
    for &vector,i in out {for &x,k in vector {x=f32_at(bytes,(i*N+k)*4)}}
    return out
}

// AnimDataModel: BoneAnimationTracks of tagged BoneAnimationTrack, each
// with its RawAnimSequenceTrack of float vectors; the keys of NumberOfKeys
// at FrameRate; CurveData.
@(private)
data_model_read :: proc(p:^unreal.Package,index:int,a:^Animation) -> (error:unreal.Error) {
    allocator:=a.allocator
    v:=versions_of(p)
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&properties)
    e:=&error
    frames:=int_of(p,&properties,"NumberOfFrames",0,e)
    a.keys=int(int_of(p,&properties,"NumberOfKeys",frames+1,e))
    rate:[2]i64
    rate,error=frame_rate_of(p,&properties,"FrameRate")
    if error.code!=.None {return}
    a.interval=f64(rate[1])/f64(rate[0])
    if property:=unreal.property_find(p,&properties,"BoneAnimationTracks");property!=nil {
        view:unreal.Array_View
        view,error=unreal.property_array(p,property)
        if error.code!=.None {return}
        items:unreal.Struct_Array
        items,error=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
        if error.code!=.None {return}
        defer unreal.struct_array_destroy(&items)
        a.tracks=make([]Bone_Track,len(items.items),allocator)
        for &item,i in items.items {
            track:=&a.tracks[i]
            track.name=name_of(p,&item,"Name",allocator,e)
            if error.code!=.None {return}
            data:=unreal.property_find(p,&item,"InternalTrackData")
            if data==nil {continue}
            if v.main_release>=RELEASE_RAW_TRACK_SERIALIZER {
                // Each track with its keys bulk serialized, as in the tail of UE4.
                bytes,_:=unreal.span_bytes(p,data.data)
                r:=reader_make(bytes,data.data.offset)
                track.positions=bulk_vectors_read(&r,3,"bone track positions",allocator)
                track.rotations=bulk_vectors_read(&r,4,"bone track rotations",allocator)
                track.scales=bulk_vectors_read(&r,3,"bone track scales",allocator)
                if failed(&r) {return r.error}
                if r.at!=len(bytes) {return {.Malformed,data.data.offset+i64(r.at),"bone track has trailing bytes"}}
                continue
            }
            keys:unreal.Property_List
            keys,error=unreal.property_tagged_struct(p,data,true,context.temp_allocator)
            if error.code!=.None {return}
            defer unreal.properties_destroy(&keys)
            track.positions,error=vector_array_of(p,&keys,"PosKeys",3,allocator)
            if error.code==.None {track.rotations,error=vector_array_of(p,&keys,"RotKeys",4,allocator)}
            if error.code==.None {track.scales,error=vector_array_of(p,&keys,"ScaleKeys",3,allocator)}
            if error.code!=.None {return}
        }
    }
    if error=tracks_check(a,p.exports[index].data.offset);error.code!=.None {return}
    if property:=unreal.property_find(p,&properties,"CurveData");property!=nil {
        data:unreal.Property_List
        data,error=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
        if error.code!=.None {return}
        defer unreal.properties_destroy(&data)
        a.curves,error=float_curves_read(p,v,&data,allocator)
    }
    return
}

// The vectors of an array of Vector3f or Quat4f; nil without it.
@(private)
vector_array_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,$N:int,allocator:mem.Allocator) -> (values:[][N]f32,error:unreal.Error) {
    property:=unreal.property_find(p,list,name)
    if property==nil {return}
    view:unreal.Array_View
    view,error=unreal.property_array(p,property)
    if error.code!=.None {return}
    if i64(view.count)*i64(N*4)!=view.data.size {return nil,{.Malformed,property.data.offset,"animation key array has another size than its vectors of floats"}}
    bytes,_:=unreal.span_bytes(p,view.data)
    values=make([][N]f32,int(view.count),allocator)
    for &vector,i in values {for &x,k in vector {x=f32_at(bytes,(i*N+k)*4)}}
    return
}

// AnimationSequencerDataModel: its MovieScene holds a control rig track whose
// section of an FK control rig keeps one transform control per bone, as
// float channels of translation, rotation (Euler degrees) and scale. Each
// frame is the channels evaluated at it, the rotation made from the Euler
// angles (X roll, Y pitch, Z yaw). The keys are the frames of
// the playback range at the display rate, and the curves its LegacyCurveData.
@(private)
sequencer_read :: proc(p:^unreal.Package,index:int,a:^Animation) -> (error:unreal.Error) {
    allocator:=a.allocator
    v:=versions_of(p)
    sequencer,_:=unreal.custom_version(p,SEQUENCER_GUID)
    at:=p.exports[index].data.offset
    if sequencer<SEQUENCER_FLOAT_CHANNEL && v.fortnite<FORTNITE_CHANNEL_SHOW_CURVE {return {.Unsupported_Value,at,"sequencer animation saved before its float channels were serialized whole; resave it in Unreal"}}
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,index,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&properties)
    e:=&error
    if property:=unreal.property_find(p,&properties,"LegacyCurveData");property!=nil {
        data:unreal.Property_List
        data,error=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
        if error.code!=.None {return}
        defer unreal.properties_destroy(&data)
        a.curves,error=float_curves_read(p,v,&data,allocator)
        if error.code!=.None {return}
    }
    scene:=object_of(p,&properties,"MovieScene",e)
    if error.code!=.None {return}
    if !export_of_class(p,scene,"/Script/MovieScene","MovieScene") {return {.Unsupported_Value,at,"sequencer animation has no movie scene of its own"}}
    scene_properties:unreal.Property_List
    scene_properties,error=unreal.export_properties(p,int(scene)-1,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&scene_properties)
    rate:[2]i64
    rate,error=frame_rate_of(p,&scene_properties,"DisplayRate")
    if error.code!=.None {return}
    a.interval=f64(rate[1])/f64(rate[0])
    frames:=1
    if range:=unreal.property_find(p,&scene_properties,"PlaybackRange");range!=nil {
        // A range of frame numbers: each bound its ERangeBoundTypes and its frame.
        bytes,_:=unreal.span_bytes(p,range.data)
        r:=reader_make(bytes,range.data.offset)
        _=u8_read(&r,"playback range lower bound")
        _=i32_read(&r,"playback range lower frame")
        upper:=u8_read(&r,"playback range upper bound")
        last:=int(i32_read(&r,"playback range upper frame"))
        if failed(&r) {return r.error}
        frames=last if upper==RANGE_INCLUSIVE else max(last-1,1)
    }
    if frames<0 || frames>MAX_ANIMATION_KEYS {return {.Limit,at,"sequencer animation frame count"}}
    a.keys=frames+1
    section:unreal.Object_Ref
    section,error=fk_section_find(p,&scene_properties)
    if error.code!=.None || section==0 {return}
    section_properties:unreal.Property_List
    section_properties,error=unreal.export_properties(p,int(section)-1,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&section_properties)
    property:=unreal.property_find(p,&section_properties,"TransformParameterNamesAndCurves")
    if property==nil {return}
    view:unreal.Array_View
    view,error=unreal.property_array(p,property)
    if error.code!=.None {return}
    items:unreal.Struct_Array
    items,error=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.struct_array_destroy(&items)
    tracks:=make([dynamic]Bone_Track,allocator)
    for &item in items.items {
        control:=name_of(p,&item,"ParameterName",context.temp_allocator,e)
        if error.code!=.None {return}
        if !strings.has_suffix(control,FK_CONTROL_SUFFIX) {continue}
        channels:[9]Float_Channel
        for &property in item.items {
            group:=-1
            switch unreal.name_plain(p,property.name) {
            case "Translation":group=0
            case "Rotation":group=1
            case "Scale":group=2
            }
            if group<0 || property.array_index<0 || property.array_index>2 {continue}
            channels[group*3+int(property.array_index)],error=float_channel_read(p,v,&property,context.temp_allocator)
            if error.code!=.None {return}
        }
        any:=false
        for &channel in channels {any||=float_channel_has_data(&channel)}
        if !any {continue}
        track:=Bone_Track{name=strings.clone(control[:len(control)-len(FK_CONTROL_SUFFIX)],allocator)}
        track.positions=make([][3]f32,a.keys,allocator)
        track.rotations=make([][4]f32,a.keys,allocator)
        track.scales=make([][3]f32,a.keys,allocator)
        // The values a channel without one keeps, as in IterateTransformControlCurve.
        location,euler,scale:=[3]f64{},[3]f64{},[3]f64{1,1,1}
        for frame in 0..<a.keys {
            for axis in 0..<3 {
                if value,weighted,ok:=float_channel_evaluate(&channels[axis],frame);ok {location[axis]=value;a.weighted+=int(weighted)}
                if value,weighted,ok:=float_channel_evaluate(&channels[3+axis],frame);ok {euler[axis]=value;a.weighted+=int(weighted)}
                if value,weighted,ok:=float_channel_evaluate(&channels[6+axis],frame);ok {scale[axis]=value;a.weighted+=int(weighted)}
            }
            // X roll, Y pitch, Z yaw.
            q:=unreal.rotator_quaternion(euler.y,euler.z,euler.x)
            rotation:=[4]f64{q.x,q.y,q.z,q.w}
            rotation/=linalg.length(rotation)
            track.positions[frame]={f32(location.x),f32(location.y),f32(location.z)}
            track.rotations[frame]={f32(rotation.x),f32(rotation.y),f32(rotation.z),f32(rotation.w)}
            track.scales[frame]={f32(scale.x),f32(scale.y),f32(scale.z)}
        }
        append(&tracks,track)
    }
    a.tracks=tracks[:]
    return tracks_check(a,at)
}

// The section of the first control rig track of a movie scene whose control
// rig is an FK control rig; 0 for none.
@(private)
fk_section_find :: proc(p:^unreal.Package,scene:^unreal.Property_List) -> (section:unreal.Object_Ref,error:unreal.Error) {
    for list in ([2]string{"Tracks","MasterTracks"}) {
        tracks:[]unreal.Object_Ref
        tracks,error=object_array_of(p,scene,list)
        if error.code!=.None {return}
        for track in tracks {
            if !export_of_class(p,track,"/Script/ControlRig","MovieSceneControlRigParameterTrack") {continue}
            track_properties:unreal.Property_List
            track_properties,error=unreal.export_properties(p,int(track)-1,true,context.temp_allocator)
            if error.code!=.None {return}
            defer unreal.properties_destroy(&track_properties)
            sections:[]unreal.Object_Ref
            sections,error=object_array_of(p,&track_properties,"Sections")
            if error.code!=.None {return}
            for candidate in sections {
                if !export_of_class(p,candidate,"/Script/ControlRig","MovieSceneControlRigParameterSection") {continue}
                section_properties:unreal.Property_List
                section_properties,error=unreal.export_properties(p,int(candidate)-1,true,context.temp_allocator)
                if error.code!=.None {return}
                e:=&error
                rig:=object_of(p,&section_properties,"ControlRig",e)
                unreal.properties_destroy(&section_properties)
                if error.code!=.None {return}
                if export_of_class(p,rig,"/Script/ControlRig","FKControlRig") {return candidate,{}}
            }
        }
    }
    return
}

// MAX_KEYS of a .anim, which is what an animation can hold.
MAX_ANIMATION_KEYS :: 1<<24

// The keys of every track are finite and its rotations have length. A
// track of fewer keys than its animation holds its last one, as Unreal
// clamps the key it samples; keys past the animation are left out.
@(private)
tracks_check :: proc(a:^Animation,at:i64) -> unreal.Error {
    if a.keys<1 || a.keys>MAX_ANIMATION_KEYS {return {.Limit,at,"animation key count"}}
    if !(a.interval>0) || a.interval-a.interval!=0 {return {.Malformed,at,"animation frame rate is not positive and finite"}}
    for &track in a.tracks {
        track.positions=track.positions[:min(len(track.positions),a.keys)]
        track.rotations=track.rotations[:min(len(track.rotations),a.keys)]
        track.scales=track.scales[:min(len(track.scales),a.keys)]
        for x in track.positions {if !finite(x) {return {.Malformed,at,"bone track position is not finite"}}}
        for x in track.scales {if !finite(x) {return {.Malformed,at,"bone track scale is not finite"}}}
        for &q in track.rotations {
            length:=linalg.length(q)
            if !(length>1e-6) || length-length!=0 {return {.Malformed,at,"bone track rotation is not finite or has no length"}}
            q/=length
        }
    }
    return {}
}

// FloatCurves of an RawCurveTracks or AnimationCurveData: each FloatCurve
// named by CurveName (since UE 5.3) or by the DisplayName of its SmartName,
// with the keys of its RichCurve.
@(private)
float_curves_read :: proc(p:^unreal.Package,v:Versions,list:^unreal.Property_List,allocator:mem.Allocator) -> (curves:[]Float_Curve,error:unreal.Error) {
    property:=unreal.property_find(p,list,"FloatCurves")
    if property==nil {return}
    view:unreal.Array_View
    view,error=unreal.property_array(p,property)
    if error.code!=.None {return}
    // FloatCurve declares a native Serialize, which the tag records, but it
    // defers to the tagged properties.
    view.native=false
    items:unreal.Struct_Array
    items,error=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.struct_array_destroy(&items)
    curves=make([]Float_Curve,len(items.items),allocator)
    framework,_:=unreal.custom_version(p,unreal.FRAMEWORK_OBJECT_VERSION)
    e:=&error
    for &item,i in items.items {
        curve:=&curves[i]
        curve.name=name_of(p,&item,"CurveName",allocator,e)
        if curve.name=="" && error.code==.None {
            // An SmartName keeps its DisplayName first.
            if smart:=unreal.property_find(p,&item,"Name");smart!=nil {
                bytes,_:=unreal.span_bytes(p,smart.data)
                r:=reader_make(bytes,smart.data.offset)
                name:=name_read(&r,p,"curve name")
                if failed(&r) {return nil,r.error}
                curve.name=unreal.name_text(p,name,allocator)
            }
        }
        if framework<FRAMEWORK_CURVE_TYPES_ON_SKELETON {curve.morph=int_of(p,&item,"CurveTypeFlags",0,e)&AACF_DRIVE_MORPH_TARGET!=0}
        if error.code!=.None {return}
        if rich:=unreal.property_find(p,&item,"FloatCurve");rich!=nil {
            error=rich_curve_read(p,v,rich,curve,allocator)
            if error.code!=.None {return}
        }
    }
    return
}

// RichCurve: its keys, serialized natively,
// its default value and how it goes on before and after them.
@(private)
rich_curve_read :: proc(p:^unreal.Package,v:Versions,property:^unreal.Property,curve:^Float_Curve,allocator:mem.Allocator) -> (error:unreal.Error) {
    list:unreal.Property_List
    list,error=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&list)
    e:=&error
    EXTRAPOLATIONS :: []string{"RCCE_Cycle","RCCE_CycleWithOffset","RCCE_Oscillate","RCCE_Linear","RCCE_Constant","RCCE_None"}
    curve.pre=Curve_Extrapolation(enum_of(p,&list,"PreInfinityExtrap",EXTRAPOLATIONS,int(Curve_Extrapolation.Constant),e))
    curve.post=Curve_Extrapolation(enum_of(p,&list,"PostInfinityExtrap",EXTRAPOLATIONS,int(Curve_Extrapolation.Constant),e))
    // RealCurve: MAX_flt is a curve without a default value.
    curve.default_value=f32(real_of(p,&list,"DefaultValue",f64(max(f32)),e))
    curve.has_default=curve.default_value!=max(f32)
    if error.code!=.None {return}
    keys:=unreal.property_find(p,&list,"Keys")
    if keys==nil {return}
    if v.ue4<UE4_RICH_CURVE_KEY {return {.Unsupported_Value,keys.data.offset,"curve keys saved before they were serialized natively; resave the animation in Unreal"}}
    view:unreal.Array_View
    view,error=unreal.property_array(p,keys)
    if error.code!=.None {return}
    if i64(view.count)*RICH_CURVE_KEY_BYTES!=view.data.size {return {.Malformed,keys.data.offset,"curve keys have another size than FRichCurveKey"}}
    bytes,_:=unreal.span_bytes(p,view.data)
    curve.keys=make([]Curve_Key,view.count,allocator)
    previous:=min(f32)
    for &key,i in curve.keys {
        k:=bytes[i*RICH_CURVE_KEY_BYTES:][:RICH_CURVE_KEY_BYTES]
        if k[0]>u8(max(Curve_Interpolation)) {return {.Malformed,keys.data.offset,"curve key interpolation"}}
        key={interpolation=Curve_Interpolation(k[0]),weighted=k[2]!=0,time=f32_at(k,3),value=f32_at(k,7),arrive=f32_at(k,11),leave=f32_at(k,19)}
        if !finite({key.time,key.value,0}) {return {.Malformed,keys.data.offset,"curve key time or value is not finite"}}
        // Saves keep tangents that are not numbers on keys that do not use them.
        if !(key.arrive-key.arrive==0) {key.arrive=0}
        if !(key.leave-key.leave==0) {key.leave=0}
        if key.time<previous {return {.Malformed,keys.data.offset,"curve keys are not in time order"}}
        previous=key.time
    }
    return
}

// The AuthoredSyncMarkers of an animation.
@(private)
sync_markers_read :: proc(p:^unreal.Package,list:^unreal.Property_List,allocator:mem.Allocator) -> (markers:[]Sync_Marker,error:unreal.Error) {
    property:=unreal.property_find(p,list,"AuthoredSyncMarkers")
    if property==nil {return}
    view:unreal.Array_View
    view,error=unreal.property_array(p,property)
    if error.code!=.None {return}
    // An AnimSyncMarker keeps its tagged properties, but the tag records it as native.
    view.native=false
    items:unreal.Struct_Array
    items,error=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.struct_array_destroy(&items)
    markers=make([]Sync_Marker,len(items.items),allocator)
    e:=&error
    for &item,i in items.items {
        markers[i]={name=name_of(p,&item,"MarkerName",allocator,e),time=f32(real_of(p,&item,"Time",0,e))}
        if error.code!=.None {return}
        if !(markers[i].time-markers[i].time==0) {return nil,{.Malformed,property.data.offset,"sync marker time is not finite"}}
    }
    return
}

// An FrameRate property: numerator and denominator, positive.
@(private)
frame_rate_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string) -> (rate:[2]i64,error:unreal.Error) {
    rate=FRAME_RATE_DEFAULT
    property:=unreal.property_find(p,list,name)
    if property==nil {return}
    fields:unreal.Property_List
    fields,error=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&fields)
    e:=&error
    rate={int_of(p,&fields,"Numerator",FRAME_RATE_DEFAULT[0],e),int_of(p,&fields,"Denominator",FRAME_RATE_DEFAULT[1],e)}
    if error.code==.None && (rate[0]<=0 || rate[1]<=0) {error={.Malformed,property.data.offset,"frame rate is not positive"}}
    return
}

// The value of an enum property by the names of its values in order (with
// or without the prefix of its enum), or by its byte; default without it.
@(private)
enum_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,values:[]string,default:int,error:^unreal.Error) -> int {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return default}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return default}
    #partial switch read.kind {
    case .Unsigned:
        if int(read.unsigned)<len(values) {return int(read.unsigned)}
    case .Name:
        text:=unreal.name_plain(p,read.name)
        if colons:=strings.last_index(text,"::");colons>=0 {text=text[colons+2:]}
        for value,i in values {if value==text {return i}}
    }
    error^={.Unsupported_Value,property.data.offset,"enum value is not one Mirai knows"}
    return default
}

@(private)
real_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,default:f64,error:^unreal.Error) -> f64 {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return default}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return default}
    if read.kind!=.Real {error^={.Malformed,property.data.offset,"expected a float"};return default}
    return read.real
}

// An InterfaceProperty: the object it names.
@(private)
interface_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string) -> (object:unreal.Object_Ref,error:unreal.Error) {
    property:=unreal.property_find(p,list,name)
    if property==nil {return}
    bytes,_:=unreal.span_bytes(p,property.data)
    if len(bytes)!=4 {return 0,{.Malformed,property.data.offset,"interface property is not an object reference"}}
    object=unreal.Object_Ref(transmute(i32)u32_at(bytes,0))
    if !unreal.reference_valid(p,object) {return 0,{.Invalid_Reference,property.data.offset,name}}
    return
}

// The objects of an array of object references; nil without it.
@(private)
object_array_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string) -> (objects:[]unreal.Object_Ref,error:unreal.Error) {
    property:=unreal.property_find(p,list,name)
    if property==nil {return}
    view:unreal.Array_View
    view,error=unreal.property_array(p,property)
    if error.code!=.None {return}
    return unreal.array_object_refs(p,view,context.temp_allocator)
}

// Whether a reference is an export of a class of a script package.
@(private)
export_of_class :: proc(p:^unreal.Package,object:unreal.Object_Ref,script,class:string) -> bool {
    index:=int(object)-1
    return object>0 && index<len(p.exports) && unreal.reference_in_package(p,p.exports[index].class,script,class)
}
