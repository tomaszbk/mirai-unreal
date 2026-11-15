package unreal_vfx_editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import "plugins:vfx/runtime/effect"

// The emitters of a Cascade ParticleSystem: of each, its first LOD level,
// which holds its RequiredModule, SpawnModule, TypeDataModule and Modules.
// Distributions give their range, and a curve its keys over the life of a
// particle. Modules Mirai has no field for are a warning, once each.
@(private)
cascade_system :: proc(c:^unreal_scene.Context,system:level.Ref,label:string) -> []Unreal_Emitter {
    d:=c.d
    out:=make([dynamic]Unreal_Emitter,context.temp_allocator)
    warmup:=real(d,system,"WarmupTime",0)
    for emitter in objects_at(d,system,"Emitters") {
        lods:=objects_at(d,emitter,"LODLevels")
        if len(lods)==0 {continue}
        lod:=lods[0]
        if enabled,_:=level.bool_of(d,lod,"bEnabled",true);!enabled {continue}
        name,_:=level.enum_of(d,emitter,"EmitterName","Particle Emitter")
        e:=Unreal_Emitter{name=strings.clone(name,context.temp_allocator),info=UNREAL_PARTICLE_DEFAULTS,loop=true}
        info:=&e.info
        info.prewarm=warmup>0
        left:=make([dynamic]string,context.temp_allocator)
        life:=Cascade_Life{who=fmt.tprintf("%s, %s",label,e.name)}
        life.scales.allocator,life.sizes.allocator=context.temp_allocator,context.temp_allocator
        if required,ok:=object_at(d,lod,"RequiredModule");ok {cascade_required(c,&e,required,&life)}
        if spawn,ok:=object_at(d,lod,"SpawnModule");ok {cascade_spawn(c,&e,spawn,&life)}
        if data,ok:=object_at(d,lod,"TypeDataModule");ok {
            switch class:=class_name(d,data);class {
            case "ParticleModuleTypeDataRibbon":info.render=.Ribbon
            case "ParticleModuleTypeDataMesh":
                info.render=.Mesh
                if path:=level.path_of(d,data,"Mesh");path!="" {
                    if m,imported:=unreal_scene.mesh_import(c,path);imported {info.meshes[0]=m.id}
                }
            case "ParticleModuleTypeDataGpu":
            case:append(&left,class)
            }
        }
        for module in objects_at(d,lod,"Modules") {
            if enabled,_:=level.bool_of(d,module,"bEnabled",true);!enabled {continue}
            class:=strings.trim_suffix(class_name(d,module),"_Seeded")
            if !cascade_module(c,&e,module,class,&life) {append(&left,class)}
        }
        cascade_life_set(c,&e,&life)
        if len(left)>0 {unreal_scene.warn(c,"%s: Mirai's effects have nothing for %s",life.who,strings.join(left[:],", ",context.temp_allocator))}
        append(&out,e)
    }
    return out[:]
}

// What the modules of an emitter say about its particles over their life,
// put together once all are read: each step Unreal starts a particle again
// from the size and color it was born with and runs its modules in order, so
// a color over life replaces the color it started with, and the factors of
// the scales multiply.
@(private)
Cascade_Life :: struct {
    who:string,               // the actor and the emitter, as warnings name them
    color,alpha:Dist,         // ColorOverLife
    color_set:bool,
    scales:[dynamic][2]Dist,  // ColorScaleOverLife: color and alpha
    sizes:[dynamic]Dist,      // SizeMultiplyLife and SizeScale: their x
    light:level.Ref,          // ParticleModuleLight
    lit:bool,
    sub_uv:Dist,              // SubImageIndex of ParticleModuleSubUV
    sub_uv_set:bool,
    sub_uv_movie:bool,
    method:string,            // InterpolationMethod of the RequiredModule
}

@(private)
cascade_required :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,required:level.Ref,life:^Cascade_Life) {
    d:=c.d
    info:=&e.info
    material_set(c,info,required,"Material")
    duration:=max(real(d,required,"EmitterDuration",1),0)
    if ranged,_:=level.bool_of(d,required,"bEmitterDurationUseRange",false);ranged {
        low:=max(real(d,required,"EmitterDurationLow",0),0)
        unreal_scene.warn(c,"%s: ParticleModuleRequired: its cycle lasts from %.3g to %.3g s in Unreal; Mirai's lasts %.3g s",life.who,low,duration,(low+duration)*0.5)
        duration=(low+duration)*0.5
    }
    info.duration=duration
    if delay:=real(d,required,"EmitterDelay",0);delay>0 {
        unreal_scene.warn(c,"%s: ParticleModuleRequired: it waits %.3g s before each cycle in Unreal; Mirai's effect starts at once",life.who,delay)
    }
    if origin,ok:=vector_of(d,required,"EmitterOrigin");ok && origin!={} {
        unreal_scene.warn(c,"%s: ParticleModuleRequired: its particles start %v m from the emitter in Unreal; in Mirai, at it",life.who,to_mirai(origin))
    }
    loops:=real(d,required,"EmitterLoops",0)
    e.loop=loops==0
    if loops>1 {unreal_scene.warn(c,"%s: it loops %d times in Unreal; Mirai's effect plays once",life.who,int(loops))}
    info.local_space,_=level.bool_of(d,required,"bUseLocalSpace",false)
    if alignment,_:=level.enum_of(d,required,"ScreenAlignment","PSA_Square");alignment=="PSA_Velocity" {info.render=.Velocity}
    if axis,_:=level.enum_of(d,required,"LockAxisFlags","EPAL_NONE");axis=="EPAL_Z" || axis=="EPAL_NEGATIVE_Z" {info.render=.Horizontal}
    info.flipbook={u32(max(real(d,required,"SubImages_Horizontal",1),1)),u32(max(real(d,required,"SubImages_Vertical",1),1))}
    life.method,_=level.enum_of(d,required,"InterpolationMethod","PSUVIM_None")
    sort,_:=level.enum_of(d,required,"SortMode","PSORTMODE_None")
    info.sort=sort!="PSORTMODE_None"
}

// The rate of the SpawnModule times its RateScale, and its bursts: at Time
// seconds of the cycle, between CountLow and Count particles (Count alone
// without CountLow) times BurstScale, rounded up.
@(private)
cascade_spawn :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,spawn:level.Ref,life:^Cascade_Life) {
    d:=c.d
    info:=&e.info
    rate:=cascade_dist(d,spawn,"Rate")
    scale:=cascade_dist(d,spawn,"RateScale")
    info.rate=max(dist_mean(rate).x*(dist_mean(scale).x if scale.found else 1),0)
    if rate.key_count>1 && rate.min.x!=rate.max.x || scale.key_count>1 && scale.min.x!=scale.max.x {
        unreal_scene.warn(c,"%s: ParticleModuleSpawn: its rate changes along its cycle in Unreal; Mirai's is %.3g per second",life.who,info.rate)
    }
    burst_scale:=cascade_dist(d,spawn,"BurstScale")
    factor:=dist_mean(burst_scale).x if burst_scale.found else 1
    f,error:=level.property(d,spawn,"BurstList")
    if error.code!=.None || f.property==nil {return}
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None {return}
    bursts,bursts_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
    if bursts_error.code!=.None {return}
    if len(bursts.items)>effect.PARTICLE_BURSTS {unreal_scene.warn(c,"%s: ParticleModuleSpawn: only its first %d bursts are translated",life.who,effect.PARTICLE_BURSTS)}
    for &burst,i in bursts.items[:min(len(bursts.items),effect.PARTICLE_BURSTS)] {
        count,_:=level.value_real(f.pkg,unreal.property_find(f.pkg,&burst,"Count"),0)
        low,_:=level.value_real(f.pkg,unreal.property_find(f.pkg,&burst,"CountLow"),-1)
        time,_:=level.value_real(f.pkg,unreal.property_find(f.pkg,&burst,"Time"),0)
        if low>=0 {count=(count+low)*0.5}
        info.bursts[i]={time=max(f32(time),0),count=u32(max(math.ceil(f32(count)*factor),0)),cycles=1}
    }
}

// The values of a module; false for one Mirai's effects have nothing for.
@(private)
cascade_module :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,module:level.Ref,class:string,life:^Cascade_Life) -> bool {
    d:=c.d
    info:=&e.info
    switch class {
    case "ParticleModuleLifetime":
        lifetime:=cascade_dist(d,module,"Lifetime")
        info.lifetime={max(lifetime.min.x,0),max(lifetime.max.x,0)}
    case "ParticleModuleSize":
        size:=cascade_dist(d,module,"StartSize")
        info.size={max(size.min.x,0)*CENTIMETRE,max(size.max.x,0)*CENTIMETRE}
    case "ParticleModuleColor":
        color:=cascade_dist(d,module,"StartColor")
        alpha:=cascade_dist(d,module,"StartAlpha")
        a:=[2]f32{1,1}
        if alpha.found {a={alpha.min.x,alpha.max.x}}
        colors_set(info,{color.min.r,color.min.g,color.min.b,a[0]},{color.max.r,color.max.g,color.max.b,a[1]})
    case "ParticleModuleColorOverLife":
        life.color,life.alpha,life.color_set=cascade_dist(d,module,"ColorOverLife"),cascade_dist(d,module,"AlphaOverLife"),true
        // A scale before it acts on a color it replaces.
        clear(&life.scales)
    case "ParticleModuleColorScaleOverLife":
        if emitter_time,_:=level.bool_of(d,module,"bEmitterTime",false);emitter_time {
            unreal_scene.warn(c,"%s: %s: it scales the color along the cycle of the emitter in Unreal; in Mirai, along the life of each particle",life.who,class)
        }
        append(&life.scales,[2]Dist{cascade_dist(d,module,"ColorScaleOverLife"),cascade_dist(d,module,"AlphaScaleOverLife")})
    case "ParticleModuleSizeMultiplyLife":
        if multiplies,_:=level.bool_of(d,module,"MultiplyX",true);multiplies {append(&life.sizes,cascade_dist(d,module,"LifeMultiplier"))}
    case "ParticleModuleSizeScale":
        append(&life.sizes,cascade_dist(d,module,"SizeScale"))
    case "ParticleModuleVelocity":
        velocity:=cascade_dist(d,module,"StartVelocity")
        lo,hi:=range_to_mirai(velocity.min,velocity.max)
        info.velocity={lo,hi}
        if world,_:=level.bool_of(d,module,"bInWorldSpace",false);world && (lo!={} || hi!={}) {
            unreal_scene.warn(c,"%s: %s: its velocity is in the world in Unreal; in Mirai, in the space of the emitter",life.who,class)
        }
        radial:=cascade_dist(d,module,"StartVelocityRadial")
        // Outwards from the emitter: a sphere of no size, of which they leave along the normal.
        if radial.found && (radial.min.x!=0 || radial.max.x!=0) {
            info.speed={radial.min.x*CENTIMETRE,radial.max.x*CENTIMETRE}
            if info.shape==.Point {info.shape,info.shape_size,info.shell=.Sphere,{},1}
        }
    case "ParticleModuleVelocityCone":
        // Unreal turns the angle (1 is half a turn) into its integer angle
        // units, CASCADE_ROTATOR_UNITS a radian, and reads them as degrees.
        angle:=cascade_dist(d,module,"Angle")
        speed:=cascade_dist(d,module,"Velocity")
        info.shape,info.shape_angle=.Cone,clamp(math.trunc(max(angle.max.x,0)*math.RAD_PER_DEG*CASCADE_ROTATOR_UNITS)*math.RAD_PER_DEG,0,math.PI)
        info.speed={speed.min.x*CENTIMETRE,speed.max.x*CENTIMETRE}
        if direction,ok:=vector_of(d,module,"Direction");ok && direction!={} && direction.xy!={} {
            unreal_scene.warn(c,"%s: %s: its cone opens along %v in Unreal; in Mirai, along the up of the emitter",life.who,class,to_mirai(direction))
        }
    case "ParticleModuleAcceleration","ParticleModuleAccelerationConstant":
        acceleration:=cascade_dist(d,module,"Acceleration")
        if acceleration.found {
            info.acceleration+=to_mirai(dist_mean(acceleration))
        } else if v,ok:=vector_of(d,module,"Acceleration");ok {
            info.acceleration+=to_mirai(v)
        }
    case "ParticleModuleAccelerationDrag":
        drag:=cascade_dist(d,module,"DragCoefficientRaw")
        info.drag=max(dist_mean(drag).x,0)
    case "ParticleModuleLocation":
        location:=cascade_dist(d,module,"StartLocation")
        lo,hi:=range_to_mirai(location.min,location.max)
        if hi!=lo {info.shape,info.shape_size,info.shell=.Box,(hi-lo)*0.5,0}
        if (hi+lo)*0.5!={} {unreal_scene.warn(c,"%s: %s: its locations around %v m are around the emitter in Mirai",life.who,class,(hi+lo)*0.5)}
    case "ParticleModuleLocationPrimitiveSphere":
        radius:=cascade_dist(d,module,"StartRadius")
        info.shape,info.shape_size.x=.Sphere,max(radius.max.x,0)*CENTIMETRE
        surface,_:=level.bool_of(d,module,"SurfaceOnly",false)
        if surface {info.shell=1}
        up,_:=level.bool_of(d,module,"Positive_Z",true)
        down,_:=level.bool_of(d,module,"Negative_Z",true)
        if up && !down {info.shape=.Hemisphere}
        cascade_primitive_velocity(c,e,module,class,info.shape_size.x,surface,life)
    case "ParticleModuleLocationPrimitiveCylinder":
        radius:=cascade_dist(d,module,"StartRadius")
        info.shape,info.shape_size.x=.Circle,max(radius.max.x,0)*CENTIMETRE
        surface,_:=level.bool_of(d,module,"SurfaceOnly",false)
        if surface {info.shell=1}
        unreal_scene.warn(c,"%s: %s: it starts particles on a circle in Mirai: its height is left out",life.who,class)
        cascade_primitive_velocity(c,e,module,class,info.shape_size.x,surface,life)
    case "ParticleModuleRotation","ParticleModuleMeshRotation":
        rotation:=cascade_dist(d,module,"StartRotation")
        info.rotation={rotation.min.x,rotation.max.x}*2*math.PI
    case "ParticleModuleRotationRate","ParticleModuleMeshRotationRate":
        rate:=cascade_dist(d,module,"StartRotationRate")
        info.spin={rate.min.x,rate.max.x}*2*math.PI
    case "ParticleModuleSubUV":
        life.sub_uv,life.sub_uv_set=cascade_dist(d,module,"SubImageIndex"),true
    case "ParticleModuleSubUVMovie":
        life.sub_uv_movie=true
        rate:=cascade_dist(d,module,"FrameRate")
        info.flipbook_speed=max(dist_mean(rate).x,0) if rate.found else 30
        if emitter_time,_:=level.bool_of(d,module,"bUseEmitterTime",false);emitter_time {
            unreal_scene.warn(c,"%s: %s: its frames follow the cycle of the emitter in Unreal; in Mirai, the life of each particle",life.who,class)
        }
        if start:=real(d,module,"StartingFrame",1);start!=1 {
            unreal_scene.warn(c,"%s: %s: it starts at frame %d (0: one at random) in Unreal; in Mirai, at the first",life.who,class,int(start))
        }
    case "ParticleModuleLight":
        life.light,life.lit=module,true
    case "ParticleModuleCollision":
        info.collision=.World
        damping:=cascade_dist(d,module,"DampingFactor")
        mean:=dist_mean(damping)
        info.bounce,info.friction=clamp(mean.z,0,1),clamp(1-mean.x,0,1)
        if completion,_:=level.enum_of(d,module,"CollisionCompletionOption","EPCC_Kill");completion=="EPCC_Kill" {info.collision_life=1}
    case "ParticleModuleAttractorPoint":
        position:=cascade_dist(d,module,"Position")
        strength:=cascade_dist(d,module,"Strength")
        info.attractor=to_mirai(dist_mean(position))
        info.attractor_strength=dist_mean(strength).x*CENTIMETRE
    case "ParticleModuleSpawnPerUnit":
        per:=cascade_dist(d,module,"SpawnPerUnit")
        unit:=real(d,module,"UnitScalar",50)
        info.rate_over_distance=max(dist_mean(per).x,0)/max(unit*CENTIMETRE,1e-4)
    case "ParticleModuleVelocityInheritParent":
        scale:=cascade_dist(d,module,"Scale")
        info.inherit_velocity=dist_mean(scale).x if scale.found else 1
    case:
        return false
    }
    return true
}

// Units of Unreal's integer angles in a radian: 65536 a turn.
@(private)
CASCADE_ROTATOR_UNITS :: 10430

// The velocity a location primitive gives with Velocity: its offset from the
// center times VelocityScale, along the normal of the shape in Mirai: from
// none to the radius inside it, the radius on its surface.
@(private)
cascade_primitive_velocity :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,module:level.Ref,class:string,radius:f32,surface:bool,life:^Cascade_Life) {
    d:=c.d
    if start:=cascade_dist(d,module,"StartLocation");start.found && (start.min!={} || start.max!={}) {
        unreal_scene.warn(c,"%s: %s: its shape is %v m from the emitter in Unreal; in Mirai, around it",life.who,class,to_mirai(dist_mean(start)))
    }
    if moves,_:=level.bool_of(d,module,"Velocity",false);!moves {return}
    scale:=dist_mean(cascade_dist(d,module,"VelocityScale")).x
    e.info.speed={0 if !surface else radius*scale,radius*scale}
}

// The curves of the life of a particle and the lights, sub-images and colors
// that depend on what every module said.
@(private)
cascade_life_set :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,life:^Cascade_Life) {
    info:=&e.info
    if len(life.sizes)>0 {info.size_over_life=life_curve(life.sizes[:])}
    if life.color_set || len(life.scales)>0 {
        // A color over life replaces the start color: the particle starts white.
        if life.color_set {colors_set(info,{1,1,1,1},{1,1,1,1})}
        info.color_over_life=life_gradient(life,info)
    }
    frames:=info.flipbook.x*info.flipbook.y
    if frames>1 && !life.sub_uv_movie {
        switch {
        case life.method=="PSUVIM_Random" || life.method=="PSUVIM_Random_Blend":
            unreal_scene.warn(c,"%s: ParticleModuleSubUV: each particle shows sub-images at random in Unreal; in Mirai, all %d over its life",life.who,frames)
        case life.method=="PSUVIM_None" || !life.sub_uv_set:
            unreal_scene.warn(c,"%s: ParticleModuleRequired: it shows the first of its %d sub-images in Unreal; Mirai shows all of them over the life",life.who,frames)
        case !cascade_sub_uv_whole(life.sub_uv,frames):
            unreal_scene.warn(c,"%s: ParticleModuleSubUV: its sub-images follow a curve of %d keys from %.3g to %.3g in Unreal; Mirai shows all %d evenly over the life",life.who,life.sub_uv.key_count,life.sub_uv.min.x,life.sub_uv.max.x,frames)
        }
        info.flipbook_speed=0
    }
    if life.lit {cascade_light(c,e,life.light,life)}
}

// Whether the sub-image of a particle goes from the first to the last over its life, evenly.
@(private)
cascade_sub_uv_whole :: proc(index:Dist,frames:u32) -> bool {
    if index.key_count!=2 {return false}
    first,last:=index.values[0].x,index.values[1].x
    return index.times[0]<=0.01 && index.times[1]>=0.99 && abs(first)<0.5 && last>=f32(frames)-1.5 && last<=f32(frames)+0.5
}

// The lights of a ParticleModuleLight: a share SpawnFraction of the particles
// lights as far as RadiusScale times its size. Its color is that of the
// particle times BrightnessOverLife and ColorScaleOverLife, in the units
// of Unreal's lights of particles, UNREAL_PARTICLE_LIGHT_CANDELA each.
@(private)
cascade_light :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,module:level.Ref,life:^Cascade_Life) {
    d:=c.d
    info:=&e.info
    fraction:=clamp(real(d,module,"SpawnFraction",1),0,1)
    count:=info.rate*info.lifetime[1]
    for burst in info.bursts {count+=f32(burst.count)}
    info.lights=u32(max(math.ceil(count*fraction),1))
    brightness:=dist_mean(cascade_dist(d,module,"BrightnessOverLife")).x
    tint:=[3]f32{1,1,1}
    if scale:=cascade_dist(d,module,"ColorScaleOverLife");scale.found {tint=dist_mean(scale)}
    peak:=max(tint.r,tint.g,tint.b,0)
    if peak>0 && (tint.r!=tint.g || tint.g!=tint.b) {
        unreal_scene.warn(c,"%s: ParticleModuleLight: its lights are tinted %v in Unreal; in Mirai, of the color of the particle",life.who,tint/peak)
    }
    info.light_intensity=max(brightness*peak,0)*UNREAL_PARTICLE_LIGHT_CANDELA
    radius:=cascade_dist(d,module,"RadiusScale")
    info.light_range=max(dist_mean(radius).x,0)*(info.size[0]+info.size[1])*0.5
    if squared,_:=level.bool_of(d,module,"bUseInverseSquaredFalloff",true);!squared {
        unreal_scene.warn(c,"%s: ParticleModuleLight: its lights fade by an exponent in Unreal; Mirai's by the square of the distance",life.who)
    }
    // Cascade casts shadows of the lights it makes high quality alone.
    high,_:=level.bool_of(d,module,"bHighQualityLights",false)
    shadows,_:=level.bool_of(d,module,"bShadowCastingLights",false)
    info.light_shadows=high && shadows
}

// Candelas of a value of 1 of the color of a light of Unreal's particles:
// such lights give their color to the lighting as it is, whose units are
// those of a point light without units times 16, of which 10000 are a
// candela at a metre (lights.odin of the importer).
UNREAL_PARTICLE_LIGHT_CANDELA :: f32(1.0/10000)

// The times a curve of the life of a particle keeps: those of the keys of
// all the distributions when they fit, else spread evenly.
@(private)
life_times :: proc(dists:[]Dist) -> (times:[effect.PARTICLE_CURVE_KEYS]f32,count:int) {
    all:=make([dynamic]f32,context.temp_allocator)
    for each in dists {
        each_times:=each.times
        append(&all,..each_times[:each.key_count])
    }
    slice.sort(all[:])
    unique:=slice.unique(all[:])
    keys:=effect.PARTICLE_CURVE_KEYS
    if len(unique)==0 {return {},1}
    if len(unique)<=keys {
        for t,i in unique {times[i]=clamp(t,0,1)}
        return times,len(unique)
    }
    for i in 0..<keys {times[i]=f32(i)/f32(keys-1)}
    return times,keys
}

// A curve of an effect that multiplies the first axis of each distribution
// along the life of a particle.
@(private)
life_curve :: proc(dists:[]Dist) -> (c:effect.Particle_Curve) {
    times,count:=life_times(dists)
    for i in 0..<effect.PARTICLE_CURVE_KEYS {
        k:=min(i,count-1)
        c.times[i]=times[k] if i<count else 1
        value:=f32(1)
        for each in dists {value*=dist_at(each,times[k]).x}
        c.values[i]=max(value,0)
    }
    if count==1 {c.times[0]=0}
    return
}

// The gradient of the color of a particle along its life: that of the color
// over life, or white, times each scale; colors above 1 go to the intensity
// of the effect.
@(private)
life_gradient :: proc(life:^Cascade_Life,info:^effect.Particle_Info) -> (g:effect.Particle_Gradient) {
    dists:=make([dynamic]Dist,context.temp_allocator)
    if life.color_set {append(&dists,life.color,life.alpha)}
    for scale in life.scales {append(&dists,scale[0],scale[1])}
    times,count:=life_times(dists[:])
    for i in 0..<effect.PARTICLE_CURVE_KEYS {
        k:=min(i,count-1)
        t:=times[k]
        color:=[4]f32{1,1,1,1}
        if life.color_set {
            if life.color.found {color.rgb=dist_at(life.color,t)}
            if life.alpha.found {color.a=dist_at(life.alpha,t).x}
        }
        for scale in life.scales {
            if scale[0].found {color.rgb*=dist_at(scale[0],t)}
            if scale[1].found {color.a*=dist_at(scale[1],t).x}
        }
        g.colors[i]={max(color.r,0),max(color.g,0),max(color.b,0),clamp(color.a,0,1)}
        g.times[i]=t if i<count else 1
    }
    if count==1 {g.times[0]=0}
    gradient_peak_set(&g,info)
    return
}
