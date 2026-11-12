package mesh

import "core:math"
import "core:mem"
import unreal "project:plugins/unreal/editor/package"

// MovieSceneFloatChannel of the sequencer, as it is serialized and
// evaluated: keys at frames of its tick resolution, each
// going to the next as its interpolation says, and the extrapolations before
// and after them.

@(private)
Float_Key :: struct {
    value,arrive,leave:f32,       // tangents per frame
    interpolation:Curve_Interpolation,
    weighted:bool,                // its tangents have weights (ERichCurveTangentWeightMode other than WeightedNone)
}

@(private)
Float_Channel :: struct {
    pre,post:Curve_Extrapolation,
    times:[]i32,
    values:[]Float_Key,
    default_value:f32,
    has_default:bool,
}

// The size of MovieSceneFloatValue: Value, MovieSceneTangentData (four floats,
// the weight mode and three bytes of padding), InterpMode, TangentMode and
// a padding byte, aligned to four. A channel of values of this size keeps
// them as their memory.
@(private) FLOAT_VALUE_BYTES :: 28
// MovieSceneFloatValue one by one: the value, four
// floats of tangents and four bytes.
@(private) FLOAT_VALUE_SERIALIZED_BYTES :: 24
@(private) FRAME_NUMBER_BYTES :: 4

// The channel of a struct property of MovieSceneFloatChannel.
@(private)
float_channel_read :: proc(p:^unreal.Package,v:Versions,property:^unreal.Property,allocator:mem.Allocator) -> (c:Float_Channel,error:unreal.Error) {
    bytes,_:=unreal.span_bytes(p,property.data)
    r:=reader_make(bytes,property.data.offset)
    pre,post:=u8_read(&r,"channel pre-infinity extrapolation"),u8_read(&r,"channel post-infinity extrapolation")
    if failed(&r) {return {},r.error}
    if pre>u8(max(Curve_Extrapolation)) || post>u8(max(Curve_Extrapolation)) {return {},{.Malformed,property.data.offset,"channel extrapolation"}}
    c.pre,c.post=Curve_Extrapolation(pre),Curve_Extrapolation(post)
    if i32_read(&r,"channel time size")!=FRAME_NUMBER_BYTES && !failed(&r) {return {},{.Malformed,property.data.offset,"channel times are not frame numbers"}}
    count:=count_read(&r,FRAME_NUMBER_BYTES,"channel time count")
    times:=take(&r,count*FRAME_NUMBER_BYTES,"channel times")
    size:=int(i32_read(&r,"channel value size"))
    values:=count_read(&r,FLOAT_VALUE_SERIALIZED_BYTES,"channel value count")
    if failed(&r) {return {},r.error}
    if values!=count {return {},{.Malformed,property.data.offset,"channel has another number of values than of times"}}
    stride:=size==FLOAT_VALUE_BYTES?FLOAT_VALUE_BYTES:FLOAT_VALUE_SERIALIZED_BYTES
    data:=take(&r,count*stride,"channel values")
    c.default_value=f32_read(&r,"channel default value")
    c.has_default=bool_read(&r,"channel has a default value")
    _=take(&r,8,"channel tick resolution")
    if v.fortnite>=FORTNITE_CHANNEL_SHOW_CURVE {_=bool_read(&r,"channel shows its curve")}
    if failed(&r) {return {},r.error}
    if r.at!=len(bytes) {return {},{.Malformed,property.data.offset+i64(r.at),"channel has trailing bytes"}}
    c.times=make([]i32,count,allocator)
    c.values=make([]Float_Key,count,allocator)
    for i in 0..<count {
        c.times[i]=transmute(i32)u32_at(times,i*4)
        if i>0 && c.times[i]<c.times[i-1] {return {},{.Malformed,property.data.offset,"channel times are not in order"}}
        k:=data[i*stride:][:stride]
        out:=&c.values[i]
        out.value,out.arrive,out.leave=f32_at(k,0),f32_at(k,4),f32_at(k,8)
        mode,interpolation:u8
        if stride==FLOAT_VALUE_BYTES {mode,interpolation=k[20],k[24]} else {mode,interpolation=k[20],k[21]}
        if interpolation>u8(max(Curve_Interpolation)) {return {},{.Malformed,property.data.offset,"channel key interpolation"}}
        out.interpolation=Curve_Interpolation(interpolation)
        out.weighted=mode!=0
        if !(out.value-out.value==0) {return {},{.Malformed,property.data.offset,"channel key value is not finite"}}
        // Tangents that are not numbers, on keys that do not use them.
        if !(out.arrive-out.arrive==0) {out.arrive=0}
        if !(out.leave-out.leave==0) {out.leave=0}
    }
    if !(c.default_value-c.default_value==0) {return {},{.Malformed,property.data.offset,"channel default value is not finite"}}
    return
}

// Whether an MovieSceneFloatChannel has keys or a default.
@(private)
float_channel_has_data :: proc(c:^Float_Channel) -> bool {return len(c.times)>0 || c.has_default}

// The value of a channel at a frame, as Unreal evaluates it, and whether it came from a cubic segment with weighted tangents,
// which is evaluated without its weights; ok is false where the channel has
// no value.
@(private)
float_channel_evaluate :: proc(c:^Float_Channel,frame:int) -> (value:f64,weighted,ok:bool) {
    count:=len(c.times)
    if count==0 {return f64(c.default_value),false,c.has_default}
    if count==1 {return f64(c.values[0].value),false,true}
    first,last:=int(c.times[0]),int(c.times[count-1])
    time:=frame
    offset:f64
    if frame<first || frame>last {
        mode:=c.pre if frame<first else c.post
        key:=0 if frame<first else count-1
        k:=c.values[key]
        #partial switch mode {
        case .None:return 0,false,false
        case .Constant:return f64(k.value),false,true
        case .Linear:
            slope:f64
            switch k.interpolation {
            case .Constant,.None:
            case .Cubic:slope=f64(k.arrive if frame<first else k.leave)
            case .Linear:
                other:=1 if frame<first else count-2
                span:=f64(c.times[max(key,other)]-c.times[min(key,other)])
                if span!=0 {slope=f64(c.values[max(key,other)].value-c.values[min(key,other)].value)/span}
            }
            return f64(k.value)+slope*f64(frame-int(c.times[key])),false,true
        }
        // A cycle: the time in the range of the keys, and for an offset cycle what each turn adds.
        duration:=last-first
        if duration==0 {return f64(k.value),false,true}
        turns:=int(math.floor(f64(frame-first)/f64(duration)))
        time=frame-turns*duration
        if mode==.Cycle_With_Offset {offset=f64(turns)*f64(c.values[count-1].value-c.values[0].value)}
        if mode==.Oscillate && turns%2!=0 {time=first+last-time}
    }
    // The segment from key i to the next that holds the time: the last key
    // before the final one that is not after it.
    i,high:=0,count-2
    for i<high {
        middle:=(i+high+1)/2
        if int(c.times[middle])<=time {i=middle} else {high=middle-1}
    }
    if time==int(c.times[i]) {return offset+f64(c.values[i].value),false,true}
    if time>=int(c.times[i+1]) {return offset+f64(c.values[i+1].value),false,true}
    a,b:=c.values[i],c.values[i+1]
    dx:=f64(c.times[i+1]-c.times[i])
    t:=f64(time-int(c.times[i]))/dx
    interpolation:=a.interpolation
    // GSequencerLinearCubicInterpolation: a linear key before a cubic one is cubic.
    if interpolation==.Linear && b.interpolation==.Cubic {interpolation=.Cubic}
    v1,v2:=f64(a.value),f64(b.value)
    switch interpolation {
    case .Linear:return offset+v1+(v2-v1)*t,false,true
    case .Cubic:
        // CubicBezierInterpolation: the controls a third of the segment along the tangents.
        p1,p2:=v1+f64(a.leave)*dx/3,v2-f64(b.arrive)*dx/3
        s:=1-t
        return offset+s*s*s*v1+3*s*s*t*p1+3*s*t*t*p2+t*t*t*v2,a.weighted || b.weighted,true
    case .Constant,.None:
    }
    return offset+v1,false,true
}
