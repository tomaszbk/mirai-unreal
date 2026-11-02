package uasset

import "core:fmt"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import material "project:plugins/unreal/editor/material"
import umesh "project:plugins/unreal/editor/mesh"
import anim "mirai:std/anim"
import mm "mirai:std/math"

// An AnimSequence: a clip of the .anim of its package, named after it. Each
// bone track of its USkeleton is a track of the path of that bone, as the
// skeletons of the import name them, keyed at every frame and in Unreal's
// space (the import turns them with the bones); a track that never changes
// is one key. Its curves are Float tracks of their names, also of the morph
// target they drive when the skeleton says so, and its sync markers are
// markers. RateScale is baked into the times, and root motion
// or a forced root lock make the root bone the root of the clip.
@(private)
animation_add :: proc(c:^Context,name:string,a:^umesh.Animation) -> bool {
    r:=c.r
    if a.additive!=.None {
        return importer.fail(r,.Unsupported,"%s: %s is additive in Unreal (%v over %v): Mirai's additive layers turn a bone after the pose below them and add to its scale, Unreal's turn it before and multiply it, so they have no equivalent; set its Additive Anim Type to No additive in Unreal and save it to import its pose",r.file_name,name,a.additive,a.additive_base)
    }
    if !(a.rate>0) {
        return importer.fail(r,.Unsupported,"%s: %s plays at a rate scale of %g in Unreal; Mirai plays a clip forwards from its keys: give it a positive rate scale",r.file_name,name,a.rate)
    }
    if a.skeleton=="" {return importer.fail(r,.Unsupported,"%s: %s names no skeleton: its tracks are bound to the bones of one",r.file_name,name)}
    library_lock(c)
    object,found:=material.object_find(c.library,a.skeleton)
    if !found {library_unlock(c);return importer.fail(r,.Not_Found,"%s: %s: its skeleton %s is under no mount of the package: its tracks are bound to its bones",r.file_name,name,a.skeleton)}
    skeleton,error:=umesh.skeleton_read(&object.pkg.p,object.export,context.temp_allocator)
    library_unlock(c)
    if error.code!=.None {return failure(r,error,a.skeleton)}
    paths:=bone_paths(r,skeleton.bones) or_return
    if len(name)>=asset.ANIMATION_NAME_CAPACITY {return importer.fail(r,.Limit,"%s: the name of the animation %s exceeds %d bytes",r.file_name,name,asset.ANIMATION_NAME_CAPACITY-1)}

    // RateScale: the clip runs that much faster, its slopes that much steeper.
    rate:=f64(a.rate)
    time_of :: proc(seconds,rate:f64) -> f32 {return f32(seconds/rate)}
    tracks:=make([dynamic]asset.Animation_Track_Desc,r.out)
    unknown,first_unknown:=0,""
    for &track in a.tracks {
        bone:=-1
        for b,i in skeleton.bones {if b.name==track.name {bone=i;break}}
        // The sequencer names its controls in lower case; Unreal's names are without case.
        if bone<0 {for b,i in skeleton.bones {if strings.equal_fold(b.name,track.name) {bone=i;break}}}
        if bone<0 {
            if unknown==0 {first_unknown=track.name}
            unknown+=1
            continue
        }
        target:=importer.own(r,paths[bone])
        positions:=make([]mm.Vec4,len(track.positions),context.temp_allocator)
        for p,i in track.positions {positions[i]={p.x,p.y,p.z,0}}
        rotations:=make([]mm.Vec4,len(track.rotations),context.temp_allocator)
        for q,i in track.rotations {
            rotations[i]=mm.Vec4(q)
            // Each key on the side of the one before, as Unreal blends them.
            if i>0 && rotations[i].x*rotations[i-1].x+rotations[i].y*rotations[i-1].y+rotations[i].z*rotations[i-1].z+rotations[i].w*rotations[i-1].w<0 {rotations[i]=-rotations[i]}
        }
        scales:=make([]mm.Vec4,len(track.scales),context.temp_allocator)
        for s,i in track.scales {scales[i]={s.x,s.y,s.z,0}}
        // Without scales Unreal scales by one: a bone whose rest is another scale keeps one.
        if len(scales)==0 {
            rest:=skeleton.bones[bone].scale
            if rest!={1,1,1} {scales=[]mm.Vec4{{1,1,1,0}}}
        }
        if len(positions)>0 {append(&tracks,asset.Animation_Track_Desc{target=target,property=.Position,keys=bone_keys(r,a,positions,rate)})}
        if len(rotations)>0 {append(&tracks,asset.Animation_Track_Desc{target=target,property=.Rotation,keys=bone_keys(r,a,rotations,rate)})}
        if len(scales)>0 {append(&tracks,asset.Animation_Track_Desc{target=target,property=.Scale,keys=bone_keys(r,a,scales,rate)})}
    }
    if unknown>0 {importer.warn(r,"%s: %s: %d tracks name bones its skeleton %s does not have (%s); they are left out",r.file_name,name,unknown,a.skeleton,first_unknown)}

    weighted,extrapolated:=0,0
    for &curve in a.curves {
        if curve.name=="" || len(curve.name)>=asset.NODE_PATH_CAPACITY {
            importer.warn(r,"%s: %s: a curve named %q is left out: a track is named by 1 to %d bytes",r.file_name,name,curve.name,asset.NODE_PATH_CAPACITY-1)
            continue
        }
        keys:=make([dynamic]anim.Keyframe,r.out)
        if len(curve.keys)==0 {
            if !curve.has_default {continue}
            append(&keys,anim.Keyframe{value={curve.default_value,0,0,0}})
        }
        for key,i in curve.keys {
            out:=anim.Keyframe{time=time_of(f64(key.time),rate),value={key.value,0,0,0},tangents=true}
            out.in_slope.x,out.out_slope.x=f32(f64(key.arrive)*rate),f32(f64(key.leave)*rate)
            // Unreal's key says how it goes to the next one, Mirai's how it arrives from the one before.
            if i>0 {
                from:=curve.keys[i-1]
                switch from.interpolation {
                case .Linear:out.interpolation=.Linear
                case .Constant,.None:out.interpolation=.Step
                case .Cubic:
                    out.interpolation=.Cubic_Spline
                    if from.weighted || key.weighted {weighted+=1}
                }
            }
            if out.time<0 {out.time=0}
            append(&keys,out)
        }
        if len(curve.keys)>1 && (curve.pre!=.Constant && curve.pre!=.None || curve.post!=.Constant && curve.post!=.None) {extrapolated+=1}
        append(&tracks,asset.Animation_Track_Desc{target=importer.own(r,curve.name),property=.Float,keys=keys[:]})
        // A curve of a morph target also moves the target of that name of the mesh the clip plays on.
        morph:=curve.morph
        for other in skeleton.morph_curves {morph||=strings.equal_fold(other,curve.name)}
        if morph {
            target:=fmt.tprintf("%s%s",asset.ANIMATION_MORPH_PATH,curve.name)
            if len(target)<asset.NODE_PATH_CAPACITY {append(&tracks,asset.Animation_Track_Desc{target=importer.own(r,target),property=.Float,keys=keys[:]})}
        }
    }
    if len(a.curves)>0 && !skeleton.curves_known {importer.warn(r,"%s: %s: the metadata of the curves of its skeleton %s is not read: its curves move no morph target",r.file_name,name,a.skeleton)}
    if weighted>0 {importer.warn(r,"%s: %s: %d cubic segments of its curves have weighted tangents; Mirai keeps their slopes without the weights",r.file_name,name,weighted)}
    if extrapolated>0 {importer.warn(r,"%s: %s: %d curves go on past their keys (linear or cycling); Mirai holds their first and last values",r.file_name,name,extrapolated)}
    if a.weighted>0 {importer.warn(r,"%s: %s: %d frames come from cubic segments of its channels with weighted tangents, evaluated without the weights",r.file_name,name,a.weighted)}
    if a.notifies>0 {importer.warn(r,"%s: %s: its %d notifies are logic of Unreal and are not imported",r.file_name,name,a.notifies)}

    markers:=make([dynamic]asset.Animation_Marker_Desc,r.out)
    for marker in a.markers {
        if marker.name=="" || len(marker.name)>=asset.ANIMATION_NAME_CAPACITY || marker.time<0 {
            importer.warn(r,"%s: %s: the sync marker %q at %gs is left out: a marker is named by 1 to %d bytes and is not before the start",r.file_name,name,marker.name,marker.time,asset.ANIMATION_NAME_CAPACITY-1)
            continue
        }
        append(&markers,asset.Animation_Marker_Desc{time=time_of(f64(marker.time),rate),name=importer.own(r,marker.name)})
    }

    clip:=asset.Animation_Clip_Desc{name=importer.own(r,name),tracks=tracks[:],markers=markers[:]}
    // The root that Unreal takes the motion of, or holds where its lock says.
    if a.root_motion || a.force_root_lock {
        asset.text_set(clip.root.bone[:],paths[0])
        clip.root.translation,clip.root.rotation=true,true
        if a.root_lock!=.Ref_Pose {importer.warn(r,"%s: %s locks its root at %v in Unreal; Mirai holds a root in place at its pose at rest",r.file_name,name,a.root_lock)}
    }
    append(&r.animations,clip)
    return true
}

// The keys of a bone property: one for a track that never changes, else one
// per frame, linear, or with Interpolation Step each from halfway to the one
// before, as Unreal takes the nearest frame.
@(private="file")
bone_keys :: proc(r:^importer.Reader,a:^umesh.Animation,values:[]mm.Vec4,rate:f64) -> []anim.Keyframe {
    constant:=true
    for value in values[1:] {constant&&=value==values[0]}
    if constant {
        keys:=make([]anim.Keyframe,1,r.out)
        keys[0]={value=values[0]}
        return keys
    }
    keys:=make([]anim.Keyframe,len(values),r.out)
    for value,k in values {
        seconds:=f64(k)*a.interval
        if a.step && k>0 {seconds-=a.interval/2}
        keys[k]={time=f32(seconds/rate),value=value,interpolation=.Step if a.step else .Linear}
    }
    return keys
}

// The path of each bone of a reference skeleton: the names from the root,
// with % and / escaped, as clips name them.
@(private)
bone_paths :: proc(r:^importer.Reader,bones:[]umesh.Bone) -> (paths:[]string,ok:bool) {
    paths=make([]string,len(bones),context.temp_allocator)
    for bone,i in bones {
        label:=importer.target_segment(bone.name)
        paths[i]=label if bone.parent<0 else fmt.tprintf("%s/%s",paths[bone.parent],label)
        if len(paths[i])>=asset.NODE_PATH_CAPACITY {return nil,importer.fail(r,.Limit,"%s: the path of the bone %s exceeds %d bytes",r.file_name,paths[i],asset.NODE_PATH_CAPACITY-1)}
    }
    return paths,true
}
