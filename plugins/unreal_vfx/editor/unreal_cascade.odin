package unreal_vfx_editor

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
        if required,ok:=object_at(d,lod,"RequiredModule");ok {cascade_required(c,&e,required)}
        if spawn,ok:=object_at(d,lod,"SpawnModule");ok {cascade_spawn(d,info,spawn)}
        if data,ok:=object_at(d,lod,"TypeDataModule");ok {
            switch class:=class_name(d,data);class {
            case "ParticleModuleTypeDataRibbon":info.render=.Ribbon
            case "ParticleModuleTypeDataMesh":
                info.render=.Mesh
                if path:=level.path_of(d,data,"Mesh");path!="" {
                    if m,imported:=unreal_scene.mesh_import(c,path);imported {info.mesh=m.id}
                }
            case "ParticleModuleTypeDataGpu":
            case:append(&left,class)
            }
        }
        for module in objects_at(d,lod,"Modules") {
            if enabled,_:=level.bool_of(d,module,"bEnabled",true);!enabled {continue}
            class:=strings.trim_suffix(class_name(d,module),"_Seeded")
            if !cascade_module(c,info,module,class) {append(&left,class)}
        }
        if len(left)>0 {unreal_scene.warn(c,"%s, %s: Mirai's effects have nothing for %s",label,e.name,strings.join(left[:],", ",context.temp_allocator))}
        append(&out,e)
    }
    return out[:]
}

@(private)
cascade_required :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,required:level.Ref) {
    d:=c.d
    info:=&e.info
    material_set(c,info,required,"Material")
    info.duration=max(real(d,required,"EmitterDuration",1),0)
    loops:=real(d,required,"EmitterLoops",0)
    e.loop=loops==0
    if loops>1 {unreal_scene.warn(c,"%s: it loops %d times in Unreal; Mirai's effect plays once",e.name,int(loops))}
    info.local_space,_=level.bool_of(d,required,"bUseLocalSpace",false)
    if alignment,_:=level.enum_of(d,required,"ScreenAlignment","PSA_Square");alignment=="PSA_Velocity" {info.render=.Velocity}
    if axis,_:=level.enum_of(d,required,"LockAxisFlags","EPAL_NONE");axis=="EPAL_Z" || axis=="EPAL_NEGATIVE_Z" {info.render=.Horizontal}
    info.flipbook={u32(max(real(d,required,"SubImages_Horizontal",1),1)),u32(max(real(d,required,"SubImages_Vertical",1),1))}
    sort,_:=level.enum_of(d,required,"SortMode","PSORTMODE_None")
    info.sort=sort!="PSORTMODE_None"
}

@(private)
cascade_spawn :: proc(d:^level.Document,info:^effect.Particle_Info,spawn:level.Ref) {
    rate:=cascade_dist(d,spawn,"Rate")
    scale:=cascade_dist(d,spawn,"RateScale")
    info.rate=max(dist_mean(rate).x*(dist_mean(scale).x if scale.found else 1),0)
    f,error:=level.property(d,spawn,"BurstList")
    if error.code!=.None || f.property==nil {return}
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None {return}
    bursts,bursts_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
    if bursts_error.code!=.None {return}
    for &burst,i in bursts.items[:min(len(bursts.items),effect.PARTICLE_BURSTS)] {
        count,_:=level.value_real(f.pkg,unreal.property_find(f.pkg,&burst,"Count"),0)
        low,_:=level.value_real(f.pkg,unreal.property_find(f.pkg,&burst,"CountLow"),-1)
        time,_:=level.value_real(f.pkg,unreal.property_find(f.pkg,&burst,"Time"),0)
        if low>=0 {count=(count+low)*0.5}
        info.bursts[i]={time=f32(time)*info.duration,count=u32(max(count,0)),cycles=1}
    }
}

// The values of a module; false for one Mirai's effects have nothing for.
@(private)
cascade_module :: proc(c:^unreal_scene.Context,info:^effect.Particle_Info,module:level.Ref,class:string) -> bool {
    d:=c.d
    switch class {
    case "ParticleModuleLifetime":
        life:=cascade_dist(d,module,"Lifetime")
        info.lifetime={max(life.min.x,0),max(life.max.x,0)}
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
        color:=cascade_dist(d,module,"ColorOverLife")
        alpha:=cascade_dist(d,module,"AlphaOverLife")
        // It sets the color of a particle along its life: the start color is white.
        colors_set(info,{1,1,1,1},{1,1,1,1})
        info.color_over_life=gradient_of(color,alpha,info)
    case "ParticleModuleSizeMultiplyLife":
        info.size_over_life=dist_curve(cascade_dist(d,module,"LifeMultiplier"),0)
    case "ParticleModuleVelocity":
        velocity:=cascade_dist(d,module,"StartVelocity")
        lo,hi:=range_to_mirai(velocity.min,velocity.max)
        info.velocity={lo,hi}
        radial:=cascade_dist(d,module,"StartVelocityRadial")
        // Outwards from the emitter: a sphere of no size, of which they leave along the normal.
        if radial.found && (radial.min.x!=0 || radial.max.x!=0) {
            info.speed={radial.min.x*CENTIMETRE,radial.max.x*CENTIMETRE}
            if info.shape==.Point {info.shape,info.shape_size,info.shell=.Sphere,{},1}
        }
    case "ParticleModuleVelocityCone":
        angle:=cascade_dist(d,module,"Angle")
        speed:=cascade_dist(d,module,"Velocity")
        info.shape,info.shape_angle=.Cone,clamp(dist_mean(angle).x,0,1)*math.PI
        info.speed={speed.min.x*CENTIMETRE,speed.max.x*CENTIMETRE}
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
        if (hi+lo)*0.5!={} {unreal_scene.warn(c,"its locations around %v m are around the emitter in Mirai",(hi+lo)*0.5)}
    case "ParticleModuleLocationPrimitiveSphere":
        radius:=cascade_dist(d,module,"StartRadius")
        info.shape,info.shape_size.x=.Sphere,max(radius.max.x,0)*CENTIMETRE
        if surface,_:=level.bool_of(d,module,"SurfaceOnly",false);surface {info.shell=1}
        up,_:=level.bool_of(d,module,"Positive_Z",true)
        down,_:=level.bool_of(d,module,"Negative_Z",true)
        if up && !down {info.shape=.Hemisphere}
    case "ParticleModuleLocationPrimitiveCylinder":
        radius:=cascade_dist(d,module,"StartRadius")
        info.shape,info.shape_size.x=.Circle,max(radius.max.x,0)*CENTIMETRE
        unreal_scene.warn(c,"a cylinder of locations starts particles on a circle in Mirai: its height is left out")
    case "ParticleModuleRotation","ParticleModuleMeshRotation":
        rotation:=cascade_dist(d,module,"StartRotation")
        info.rotation={rotation.min.x,rotation.max.x}*2*math.PI
    case "ParticleModuleRotationRate","ParticleModuleMeshRotationRate":
        rate:=cascade_dist(d,module,"StartRotationRate")
        info.spin={rate.min.x,rate.max.x}*2*math.PI
    case "ParticleModuleSubUV":
        info.flipbook_speed=0
    case "ParticleModuleSubUVMovie":
        info.flipbook_speed=max(real(d,module,"FrameRate",30),0)
    case "ParticleModuleLight":
        // A share of the particles light: Mirai lights a number of them.
        fraction:=real(d,module,"SpawnFraction",1)
        count:=info.rate*info.lifetime[1]
        for burst in info.bursts {count+=f32(burst.count)}
        info.lights=u32(clamp(math.ceil(count*fraction),1,64))
        brightness:=cascade_dist(d,module,"BrightnessOverLife")
        radius:=cascade_dist(d,module,"RadiusScale")
        info.light_intensity=max(dist_mean(brightness).x,0)*16
        info.light_range=max(dist_mean(radius).x,0)*(info.size[0]+info.size[1])*0.5
        // Cascade casts shadows of the lights it makes high quality alone.
        high,_:=level.bool_of(d,module,"bHighQualityLights",false)
        shadows,_:=level.bool_of(d,module,"bShadowCastingLights",false)
        info.light_shadows=high && shadows
        unreal_scene.warn(c,"its particle lights are approximated: %d of them, %.3g cd, %.3g m of range",info.lights,info.light_intensity,info.light_range)
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

// A color and an alpha over the life of a particle as a gradient of eight
// keys: its colors above 1 go to the intensity of the effect.
@(private)
gradient_of :: proc(color,alpha:Dist,info:^effect.Particle_Info) -> (g:effect.Particle_Gradient) {
    times:[DIST_KEYS*2]f32
    color_times,alpha_times:=color.times,alpha.times
    count:=copy(times[:],color_times[:color.key_count])
    count+=copy(times[count:],alpha_times[:alpha.key_count])
    keys:=effect.PARTICLE_CURVE_KEYS
    // The keys of both when they fit, else evenly spread times.
    sorted:=times[:count]
    fits:=count>0 && count<=keys
    if fits {slice.sort(sorted)}
    for i in 0..<keys {
        t:=f32(i)/f32(keys-1)
        if fits {t=sorted[min(i,count-1)]}
        rgb:=dist_at(color,t) if color.found else [3]f32{1,1,1}
        a:=dist_at(alpha,t).x if alpha.found else 1
        g.colors[i]={rgb.r,rgb.g,rgb.b,clamp(a,0,1)}
        g.times[i]=clamp(t,i>0?g.times[i-1]:0,1)
    }
    gradient_peak_set(&g,info)
    return
}
