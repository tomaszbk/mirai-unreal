package fixture_files

import "core:math"
import unreal "project:plugins/unreal/editor/package"

// An AnimSequence package in each of the places Unreal keeps its source
// animation.
Animation_Layout :: enum u8 {
    UE4,         // RawAnimationData in the native tail, AnimationTrackNames and RawCurveData
    Data_Model,  // UE 5.0: an AnimDataModel export with tagged bone tracks and CurveData
    Bulk_Tracks, // UE 5.1: the bone tracks of the AnimDataModel with their keys bulk serialized
    Sequencer,   // UE 5.2 on: an AnimationSequencerDataModel, its movie scene and the FK control rig section, with the tags of 1012
}

Animation_Track :: struct {
    name:string,
    positions:[][3]f32, // centimeters, one per key or one for all
    rotations:[][3]f32, // degrees of roll about X, pitch about Y and yaw about Z; one per key or one
    scales:[][3]f32,    // none: a scale of one
}

// An FRichCurveKey; interpolation is ERichCurveInterpMode.
Animation_Curve_Key :: struct {time,value,arrive,leave:f32,interpolation:u8}

Animation_Fixture :: struct {
    layout:Animation_Layout,
    name:string,      // MM_Fixture when ""
    skeleton:string,  // package of its USkeleton, "" for none
    keys,fps:int,
    tracks:[]Animation_Track,
    curve:string,
    curve_keys:[]Animation_Curve_Key,
    marker:string,
    marker_time:f32,
    root_motion:bool,
    rate_scale:f32,   // 0: one
    additive:string,  // a value of EAdditiveAnimationType, "" for none
    // Sequencer: the X of the second track keyed at its first and last frame
    // alone, cubic, leaving the first at sparse_slope per frame and arriving flat.
    sparse:bool,
    sparse_slope:f32,
}

@(private) SEQUENCER :: [4]u32{0x7B5AE74C,0xD2704C10,0xA9585798,0x0B212A5A}

// The rotation of a track as the layouts that keep quaternions keep it.
animation_quaternion :: proc(euler:[3]f32) -> [4]f32 {
    q:=unreal.rotator_quaternion(f64(euler.y),f64(euler.z),f64(euler.x))
    length:=math.sqrt(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w)
    return {f32(q.x/length),f32(q.y/length),f32(q.z/length),f32(q.w/length)}
}

animation_package :: proc(f:Animation_Fixture,allocator:=context.temp_allocator) -> []u8 {
    versions:[]Version
    ue5:i32
    switch f.layout {
    case .UE4:
    case .Data_Model:ue5=1004;versions=clone([]Version{{MAIN,10}},allocator)
    case .Bulk_Tracks:ue5=1009;versions=clone([]Version{{MAIN,40},{MAIN_RELEASE,39}},allocator)
    case .Sequencer:ue5=1012;versions=clone([]Version{{MAIN,60},{MAIN_RELEASE,50},{FORTNITE,60},{SEQUENCER,13}},allocator)
    }
    name:=f.name if f.name!="" else "MM_Fixture"
    w:=writer_make({ue5=ue5,versions=versions,package_name="/Game/Animations/MM_Fixture"},allocator)
    skeleton:=i32(0)
    if f.skeleton!="" {skeleton=package_object(&w,f.skeleton,"/Script/Engine","Skeleton",last_part(f.skeleton))}
    if f.layout==.Sequencer {return sequencer_package(&w,f,name,skeleton,allocator)}

    class:=engine_class(&w,"AnimSequence")
    b:=bytes_make(allocator)
    if skeleton!=0 {object_property(&b,&w,"Skeleton",skeleton)}
    length:=f32(f.keys-1)/f32(f.fps)
    float_property(&b,&w,"SequenceLength",length)
    if f.rate_scale!=0 {float_property(&b,&w,"RateScale",f.rate_scale)}
    if f.root_motion {bool_property(&b,&w,"bEnableRootMotion",true)}
    if f.additive!="" {enum_property(&b,&w,"AdditiveAnimType","EAdditiveAnimationType",f.additive)}
    if f.marker!="" {
        marker:=bytes_make(allocator)
        name_property(&marker,&w,"MarkerName",f.marker)
        float_property(&marker,&w,"Time",f.marker_time)
        struct_array_property(&b,&w,"AuthoredSyncMarkers","AnimSyncMarker",{marker})
    }
    if f.layout==.UE4 {
        int_property(&b,&w,"NumFrames",i32(f.keys))
        tag(&b,&w,"AnimationTrackNames","ArrayProperty",4+8*len(f.tracks),{inner="NameProperty"})
        put_u32(&b,u32(len(f.tracks)))
        for track in f.tracks {put_name(&b,&w,track.name)}
        if f.curve!="" {
            raw:=bytes_make(allocator)
            curves_property(&raw,&w,f)
            struct_property(&b,&w,"RawCurveData","RawCurveTracks",&raw)
        }
    } else {
        object_property(&b,&w,"DataModel",2)
    }
    none(&b,&w)
    // UAnimationAsset: no object guid, the skeleton guid; UAnimSequence: strip flags.
    put_u32(&b,0)
    put_zeros(&b,16)
    put_u8(&b,0);put_u8(&b,0)
    if f.layout==.UE4 {
        put_u32(&b,u32(len(f.tracks)))
        for track in f.tracks {raw_track(&b,track)}
        put_u32(&b,0) // SourceRawAnimationData
    } else {
        put_u32(&b,0)
    }
    put_u32(&b,0)
    export_add(&w,{class=class,outer=0,name=name,data=b.data[:]})
    if f.layout==.UE4 {return package_bytes(&w)}

    m:=bytes_make(allocator)
    items:=make([]Bytes,len(f.tracks),allocator)
    for track,i in f.tracks {
        items[i]=bytes_make(allocator)
        name_property(&items[i],&w,"Name",track.name)
        if f.layout==.Bulk_Tracks {
            data:=bytes_make(allocator)
            raw_track(&data,track)
            tag(&items[i],&w,"InternalTrackData","StructProperty",len(data.data),{struct_name="RawAnimSequenceTrack"})
            put_bytes(&items[i],data.data[:])
        } else {
            keys:=bytes_make(allocator)
            vectors_property(&keys,&w,"PosKeys","Vector3f",track.positions)
            rotations:=make([][4]f32,len(track.rotations),allocator)
            for euler,k in track.rotations {rotations[k]=animation_quaternion(euler)}
            quats_property(&keys,&w,"RotKeys",rotations)
            vectors_property(&keys,&w,"ScaleKeys","Vector3f",track.scales)
            struct_property(&items[i],&w,"InternalTrackData","RawAnimSequenceTrack",&keys)
        }
    }
    struct_array_property(&m,&w,"BoneAnimationTracks","BoneAnimationTrack",items)
    rate:=bytes_make(allocator)
    int_property(&rate,&w,"Numerator",i32(f.fps))
    struct_property(&m,&w,"FrameRate","FrameRate",&rate)
    int_property(&m,&w,"NumberOfKeys",i32(f.keys))
    if f.curve!="" {
        data:=bytes_make(allocator)
        curves_property(&data,&w,f)
        struct_property(&m,&w,"CurveData","AnimationCurveData",&data)
    }
    none(&m,&w)
    put_u32(&m,0)
    export_add(&w,{class=engine_class(&w,"AnimDataModel"),outer=1,name="AnimationDataModel",data=m.data[:]})
    return package_bytes(&w)
}

// FRawAnimSequenceTrack as operator<< writes it: each array bulk serialized.
@(private="file")
raw_track :: proc(b:^Bytes,track:Animation_Track) {
    put_u32(b,12);put_u32(b,u32(len(track.positions)))
    for p in track.positions {for x in p {put_f32(b,x)}}
    put_u32(b,16);put_u32(b,u32(len(track.rotations)))
    for euler in track.rotations {for x in animation_quaternion(euler) {put_f32(b,x)}}
    put_u32(b,12);put_u32(b,u32(len(track.scales)))
    for s in track.scales {for x in s {put_f32(b,x)}}
}

// An array of native structs (Vector3f, Quat4f, RichCurveKey) as tags before 1012 write it.
@(private="file")
native_array_property :: proc(b:^Bytes,w:^Writer,property,struct_name:string,count:int,elements:[]u8) {
    inner:=bytes_make()
    tag(&inner,w,property,"StructProperty",len(elements),{struct_name=struct_name})
    tag(b,w,property,"ArrayProperty",4+len(inner.data)+len(elements),{inner="StructProperty"})
    put_u32(b,u32(count))
    put_bytes(b,inner.data[:])
    put_bytes(b,elements)
}

@(private="file")
vectors_property :: proc(b:^Bytes,w:^Writer,property,struct_name:string,values:[][3]f32) {
    if len(values)==0 {return}
    data:=bytes_make()
    for v in values {for x in v {put_f32(&data,x)}}
    native_array_property(b,w,property,struct_name,len(values),data.data[:])
}

@(private="file")
quats_property :: proc(b:^Bytes,w:^Writer,property:string,values:[][4]f32) {
    data:=bytes_make()
    for v in values {for x in v {put_f32(&data,x)}}
    native_array_property(b,w,property,"Quat4f",len(values),data.data[:])
}

// FRichCurveKey keys, serialized natively.
@(private="file")
rich_keys :: proc(keys:[]Animation_Curve_Key) -> []u8 {
    data:=bytes_make()
    for key in keys {
        put_u8(&data,key.interpolation);put_u8(&data,0);put_u8(&data,0)
        put_f32(&data,key.time);put_f32(&data,key.value)
        put_f32(&data,key.arrive);put_f32(&data,0);put_f32(&data,key.leave);put_f32(&data,0)
    }
    return data.data[:]
}

// FloatCurves of one FFloatCurve, named by its FSmartName (the DisplayName first).
@(private="file")
curves_property :: proc(b:^Bytes,w:^Writer,f:Animation_Fixture) {
    item:=bytes_make()
    tag(&item,w,"Name","StructProperty",8,{struct_name="SmartName"})
    put_name(&item,w,f.curve)
    rich:=bytes_make()
    native_array_property(&rich,w,"Keys","RichCurveKey",len(f.curve_keys),rich_keys(f.curve_keys))
    struct_property(&item,w,"FloatCurve","RichCurve",&rich)
    struct_array_property(b,w,"FloatCurves","FloatCurve",{item})
}

// Tags of UE 5.1 (1012) on: the complete type of the property, its size and its flags.
@(private="file")
Type_Part :: struct {name:string,children:i32}

@(private="file")
complete_tag :: proc(b:^Bytes,w:^Writer,property:string,types:[]Type_Part,size:int,flags:u8=0,index:i32=0) {
    put_name(b,w,property)
    for t in types {put_name(b,w,t.name);put_i32(b,t.children)}
    put_u32(b,u32(size))
    put_u8(b,flags|(index!=0?1:0))
    if index!=0 {put_i32(b,index)}
}

// The struct of an engine module, as a complete type.
@(private="file")
struct_type :: proc(name,module:string) -> []Type_Part {
    return clone([]Type_Part{{"StructProperty",1},{name,1},{module,0}})
}

@(private="file")
struct_array_type :: proc(name,module:string) -> []Type_Part {
    return clone([]Type_Part{{"ArrayProperty",1},{"StructProperty",1},{name,1},{module,0}})
}

// HasBinaryOrNativeSerialize: a struct that declares a native serializer, which the tag records.
@(private="file") TAG_NATIVE :: 8
// The value of a BoolProperty.
@(private="file") TAG_TRUE :: 0x10

// Tags of the properties of an export of 1012: the serialization control byte first, None last.
@(private="file")
export_complete :: proc(w:^Writer,class,outer:i32,name:string,properties:^Bytes) {
    b:=bytes_make()
    put_u8(&b,0)
    put_bytes(&b,properties.data[:])
    put_name(&b,w,"None")
    end:=len(b.data)
    put_u32(&b,0)
    export_add(w,{class=class,outer=outer,name=name,data=b.data[:],script_end=end})
}

// FMovieSceneFloatChannel: its keys as their memory (FMovieSceneFloatValue of 28 bytes).
@(private="file")
float_channel :: proc(times:[]i32,values:[]f32,interpolation:u8,leave:[]f32=nil,fps:int) -> []u8 {
    b:=bytes_make()
    put_u8(&b,4);put_u8(&b,4) // RCCE_Constant before and after
    put_u32(&b,4);put_u32(&b,u32(len(times)))
    for t in times {put_i32(&b,t)}
    put_u32(&b,28);put_u32(&b,u32(len(values)))
    for value,i in values {
        put_f32(&b,value)
        put_f32(&b,0);put_f32(&b,leave!=nil?leave[i]:0);put_f32(&b,0);put_f32(&b,0)
        put_u8(&b,0);put_zeros(&b,3)
        put_u8(&b,interpolation);put_u8(&b,0);put_u8(&b,0);put_u8(&b,0)
    }
    put_f32(&b,0);put_u32(&b,0)
    put_i32(&b,i32(fps));put_i32(&b,1)
    put_u32(&b,1)
    return b.data[:]
}

@(private="file")
sequencer_package :: proc(w:^Writer,f:Animation_Fixture,name:string,skeleton:i32,allocator:=context.temp_allocator) -> []u8 {
    // Exports: 1 the sequence, 2 its model, 3 the movie scene, 4 its track, 5 the section, 6 its FK control rig.
    b:=bytes_make(allocator)
    if skeleton!=0 {complete_tag(&b,w,"Skeleton",{{"ObjectProperty",0}},4);put_i32(&b,skeleton)}
    complete_tag(&b,w,"SequenceLength",{{"FloatProperty",0}},4);put_f32(&b,f32(f.keys-1)/f32(f.fps))
    if f.root_motion {complete_tag(&b,w,"bEnableRootMotion",{{"BoolProperty",0}},0,TAG_TRUE)}
    if f.rate_scale!=0 {complete_tag(&b,w,"RateScale",{{"FloatProperty",0}},4);put_f32(&b,f.rate_scale)}
    if f.marker!="" {
        marker:=bytes_make(allocator)
        complete_tag(&marker,w,"MarkerName",{{"NameProperty",0}},8);put_name(&marker,w,f.marker)
        complete_tag(&marker,w,"Time",{{"FloatProperty",0}},4);put_f32(&marker,f.marker_time)
        put_name(&marker,w,"None")
        complete_tag(&b,w,"AuthoredSyncMarkers",struct_array_type("AnimSyncMarker","/Script/Engine"),4+len(marker.data),TAG_NATIVE)
        put_u32(&b,1);put_bytes(&b,marker.data[:])
    }
    complete_tag(&b,w,"DataModelInterface",{{"InterfaceProperty",0}},4);put_i32(&b,2)
    export_complete(w,engine_class(w,"AnimSequence"),0,name,&b)

    model:=bytes_make(allocator)
    if f.curve!="" {
        item:=bytes_make(allocator)
        complete_tag(&item,w,"CurveName",{{"NameProperty",0}},8);put_name(&item,w,f.curve)
        keys:=rich_keys(f.curve_keys)
        rich:=bytes_make(allocator)
        complete_tag(&rich,w,"Keys",struct_array_type("RichCurveKey","/Script/Engine"),4+len(keys),TAG_NATIVE)
        put_u32(&rich,u32(len(f.curve_keys)));put_bytes(&rich,keys)
        put_name(&rich,w,"None")
        complete_tag(&item,w,"FloatCurve",struct_type("RichCurve","/Script/Engine"),len(rich.data))
        put_bytes(&item,rich.data[:])
        put_name(&item,w,"None")
        curves:=bytes_make(allocator)
        complete_tag(&curves,w,"FloatCurves",struct_array_type("FloatCurve","/Script/Engine"),4+len(item.data),TAG_NATIVE)
        put_u32(&curves,1);put_bytes(&curves,item.data[:])
        put_name(&curves,w,"None")
        complete_tag(&model,w,"LegacyCurveData",struct_type("AnimationCurveData","/Script/Engine"),len(curves.data))
        put_bytes(&model,curves.data[:])
    }
    complete_tag(&model,w,"MovieScene",{{"ObjectProperty",0}},4);put_i32(&model,3)
    export_complete(w,script_class(w,"/Script/AnimationData","AnimationSequencerDataModel"),1,"AnimationSequencerDataModel",&model)

    scene:=bytes_make(allocator)
    complete_tag(&scene,w,"Tracks",{{"ArrayProperty",1},{"ObjectProperty",0}},8);put_u32(&scene,1);put_i32(&scene,4)
    // TRange<FFrameNumber>: [0, keys) as UMovieScene keeps the playback range.
    complete_tag(&scene,w,"PlaybackRange",struct_type("MovieSceneFrameRange","/Script/MovieScene"),10,TAG_NATIVE)
    put_u8(&scene,1);put_i32(&scene,0);put_u8(&scene,0);put_i32(&scene,i32(f.keys))
    rate:=bytes_make(allocator)
    complete_tag(&rate,w,"Numerator",{{"IntProperty",0}},4);put_i32(&rate,i32(f.fps))
    put_name(&rate,w,"None")
    complete_tag(&scene,w,"DisplayRate",struct_type("FrameRate","/Script/CoreUObject"),len(rate.data))
    put_bytes(&scene,rate.data[:])
    export_complete(w,script_class(w,"/Script/MovieScene","MovieScene"),2,"MovieScene",&scene)

    track:=bytes_make(allocator)
    complete_tag(&track,w,"Sections",{{"ArrayProperty",1},{"ObjectProperty",0}},8);put_u32(&track,1);put_i32(&track,5)
    export_complete(w,script_class(w,"/Script/ControlRig","MovieSceneControlRigParameterTrack"),3,"MovieSceneControlRigParameterTrack",&track)

    section:=bytes_make(allocator)
    complete_tag(&section,w,"ControlRig",{{"ObjectProperty",0}},4);put_i32(&section,6)
    items:=bytes_make(allocator)
    every:=make([]i32,f.keys,allocator)
    for &t,i in every {t=i32(i)}
    for track,i in f.tracks {
        item:=bytes_make(allocator)
        control:=bytes_make(allocator)
        for c in track.name {put_u8(&control,u8(c>='A' && c<='Z'?c+32:c))}
        complete_tag(&item,w,"ParameterName",{{"NameProperty",0}},8)
        put_name(&item,w,concat(string(control.data[:]),"_CONTROL"))
        groups:=[3][][3]f32{track.positions,track.rotations,track.scales}
        group_names:=[3]string{"Translation","Rotation","Scale"}
        for values,g in groups {
            for axis in 0..<3 {
                channel:[]u8
                if g==0 && axis==0 && f.sparse && i==1 {
                    channel=float_channel({0,i32(f.keys-1)},{values[0][0],values[len(values)-1][0]},2,{f.sparse_slope,0},f.fps)
                } else if len(values)==0 {
                    channel=float_channel(nil,nil,0,nil,f.fps)
                } else {
                    picked:=make([]f32,f.keys,allocator)
                    for &value,k in picked {value=values[min(k,len(values)-1)][axis]}
                    channel=float_channel(every,picked,0,nil,f.fps)
                }
                complete_tag(&item,w,group_names[g],struct_type("MovieSceneFloatChannel","/Script/MovieScene"),len(channel),TAG_NATIVE,i32(axis))
                put_bytes(&item,channel)
            }
        }
        put_name(&item,w,"None")
        put_bytes(&items,item.data[:])
    }
    complete_tag(&section,w,"TransformParameterNamesAndCurves",struct_array_type("TransformParameterNameAndCurves","/Script/MovieSceneTracks"),4+len(items.data))
    put_u32(&section,u32(len(f.tracks)));put_bytes(&section,items.data[:])
    export_complete(w,script_class(w,"/Script/ControlRig","MovieSceneControlRigParameterSection"),4,"MovieSceneControlRigParameterSection",&section)
    rig:=bytes_make(allocator)
    export_complete(w,script_class(w,"/Script/ControlRig","FKControlRig"),5,"FKControlRig",&rig)
    return package_bytes(w)
}

@(private)
concat :: proc(a,b:string) -> string {
    out:=make([]u8,len(a)+len(b),context.temp_allocator)
    copy(out,a);copy(out[len(a):],b)
    return string(out)
}

// A skeleton's three bones keyed at three frames of 30 fps: the root still,
// the spine turning about Z and rising, the hand moving out with a scale.
// A cubic curve, a sync marker on the middle frame and root motion.
animation_figure :: proc(layout:Animation_Layout,allocator:=context.temp_allocator) -> (f:Animation_Fixture) {
    f.layout=layout
    f.skeleton="/Game/Characters/SK_Fixture_Skeleton"
    f.keys,f.fps=3,30
    f.tracks=clone([]Animation_Track{
        {name="root",positions=clone([][3]f32{{0,0,0}},allocator),rotations=clone([][3]f32{{0,0,0}},allocator)},
        {name="spine",positions=clone([][3]f32{{0,0,100},{0,0,110},{0,0,130}},allocator),rotations=clone([][3]f32{{0,0,90},{0,0,100},{10,20,120}},allocator)},
        {name="hand",positions=clone([][3]f32{{50,0,0},{60,0,0},{70,5,0}},allocator),rotations=clone([][3]f32{{0,0,0}},allocator),scales=clone([][3]f32{{1,1,1},{1.5,1,1},{2,2,2}},allocator)},
    },allocator)
    f.curve="Speed"
    f.curve_keys=clone([]Animation_Curve_Key{{time=0,value=1,leave=3,interpolation=2},{time=f32(2)/30,value=2,arrive=-1,interpolation=0}},allocator)
    f.marker,f.marker_time="Step",f32(1)/30
    f.root_motion=true
    if layout==.Sequencer {f.sparse,f.sparse_slope=true,2}
    return
}
