package unreal_vfx_editor

import "core:encoding/endian"
import "core:math"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import "plugins:vfx/runtime/effect"

// A lightweight emitter of Niagara (UNiagaraStatelessEmitter): its cycle, its
// spawns and its modules keep their values as properties of their own, with
// no scripts. Each module becomes fields of the effect, or a Vfx program for
// what the fields do not say; what has no meaning in Mirai is a warning.
@(private)
niagara_stateless :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,emitter:level.Ref,u:^Niagara_Values,label:string) {
    d:=c.d
    info:=&e.info
    // A lightweight emitter draws its particles where its system is.
    info.local_space=true
    state:=struct_at(d,emitter,"EmitterState")
    loop,_:=level.value_enum(state.p,struct_field(&state,"LoopBehavior"),"Infinite")
    e.loop=loop!="Once"
    if loop=="Multiple" {
        count,_:=level.value_real(state.p,struct_field(&state,"LoopCount"),1)
        unreal_scene.warn(c,"%s, %s: its cycle repeats %d times; the effect repeats it while it is active",label,e.name,int(count))
    }
    duration:=niagara_dist(u,state.p,struct_field(&state,"LoopDuration"),{1,1,1,1},1)
    info.duration=max((duration.min.x+duration.max.x)*0.5,0)
    if state.ok && value_flag(state.p,struct_field(&state,"bLoopDelayEnabled"),false) {
        unreal_scene.warn(c,"%s, %s: the delay before its cycles is not translated: an effect starts its cycle at once",label,e.name)
    }
    niagara_spawns(u,d,info,emitter)
    if renderers:=objects_at(d,emitter,"RendererProperties");renderers!=nil {
        drawn:=false
        for renderer in renderers {drawn=niagara_renderer(c,info,renderer,drawn) || drawn}
    }
    for module in objects_at(d,emitter,"Modules") {
        if enabled,_:=level.bool_of(d,module,"bModuleEnabled",true);!enabled {continue}
        niagara_stateless_module(c,e,module,u,label)
    }
}

// The rates and bursts of the spawns of a lightweight emitter.
@(private)
niagara_spawns :: proc(u:^Niagara_Values,d:^level.Document,info:^effect.Particle_Info,emitter:level.Ref) {
    info.rate=0
    f,error:=level.property(d,emitter,"SpawnInfos")
    if error.code!=.None || f.property==nil {return}
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None {return}
    spawns,spawns_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
    if spawns_error.code!=.None {return}
    bursts:=0
    for &item in spawns.items {
        s:=Struct_Fields{item,f.pkg,true}
        if !value_flag(f.pkg,struct_field(&s,"bEnabled"),true) {continue}
        if kind,_:=level.value_enum(f.pkg,struct_field(&s,"Type"),"Burst");kind=="Rate" {
            rate:=niagara_dist(u,f.pkg,struct_field(&s,"Rate"),{60,60,60,60},1)
            info.rate+=max((rate.min.x+rate.max.x)*0.5,0)
            continue
        }
        if bursts==effect.PARTICLE_BURSTS {continue}
        time,_:=level.value_real(f.pkg,struct_field(&s,"SpawnTime"),0)
        amount:=niagara_dist(u,f.pkg,struct_field(&s,"Amount"),{1,1,1,1},1)
        info.bursts[bursts]={time=max(f32(time),0),count=u32(max(math.round((amount.min.x+amount.max.x)*0.5),0)),cycles=1}
        bursts+=1
    }
}

// A distribution of a property of a lightweight module (FNiagaraDistribution*):
// a range a particle takes its value from when it starts, or values over its
// life (curve: sampled evenly over its time range). What the package leaves
// out is that of the constructor of the module, default.
@(private)
Niagara_Dist :: struct {
    min,max:[4]f32,
    curve:Niagara_Curve,
    bound:bool, // an expression, or a parameter the system keeps no value of, gives it: the import keeps the value stored with it
}

@(private)
niagara_dist :: proc(u:^Niagara_Values,p:^unreal.Package,property:^unreal.Property,default:[4]f32,channels:int) -> (out:Niagara_Dist) {
    out.min,out.max=default,default
    if property==nil {return}
    list,error:=unreal.property_tagged_struct(p,property,true,context.temp_allocator)
    if error.code!=.None {return}
    fields:=Struct_Fields{list,p,true}
    mode:=""
    if m:=struct_field(&fields,"Mode");m!=nil {mode,_=level.value_enum(p,m,"")}
    if mode=="Binding" {
        // A parameter of the system gives it: the value the system keeps of it.
        out.bound=true
        binding:=struct_field(&fields,"ParameterBinding")
        if binding==nil {return}
        bound,bound_error:=unreal.property_tagged_struct(p,binding,true,context.temp_allocator)
        if bound_error.code!=.None {return}
        b:=Struct_Fields{bound,p,true}
        name:=struct_field(&b,"Name")
        if name==nil {return}
        value,value_error:=unreal.property_value(p,name,context.temp_allocator)
        if value_error.code!=.None || value.kind!=.Name {return}
        if v,found:=niagara_vector(u,unreal.name_text(p,value.name,context.temp_allocator));found {out.min,out.max,out.bound=v,v,false}
        return
    }
    out.bound=mode=="Expression"
    if v,ok:=niagara_field(&fields,"Min",channels);ok {out.min=v}
    if v,ok:=niagara_field(&fields,"Max",channels);ok {out.max=v}
    // A constant keeps its value in Min; a range from the constructor is a constant.
    if mode=="" || strings.has_suffix(mode,"Constant") {out.max=out.min}
    values:=property_floats(p,struct_field(&fields,"Values"))
    if len(values)<channels {return}
    if strings.has_suffix(mode,"Curve") || mode=="ColorGradient" {
        start,end:=f32(0),f32(1)
        if range,ok:=value_vector(p,struct_field(&fields,"ValuesTimeRange"));ok {start,end=range.x,range.y}
        out.curve={samples=values,channels=channels,start=start,end=end}
    }
    for i in 0..<channels {out.min[i],out.max[i]=values[i],values[i]}
    for at:=channels;at+channels<=len(values);at+=channels {
        for i in 0..<channels {out.min[i],out.max[i]=min(out.min[i],values[at+i]),max(out.max[i],values[at+i])}
    }
    return
}

// A distribution of a property of a module, through its archetypes.
@(private)
module_dist :: proc(u:^Niagara_Values,d:^level.Document,module:level.Ref,name:string,default:[4]f32,channels:int) -> Niagara_Dist {
    f,error:=level.property(d,module,name)
    if error.code!=.None {return {min=default,max=default}}
    return niagara_dist(u,f.pkg,f.property,default,channels)
}

// A number, an integer, a vector or a color of a struct as four floats.
@(private)
niagara_field :: proc(s:^Struct_Fields,name:string,channels:int) -> (v:[4]f32,ok:bool) {
    property:=struct_field(s,name)
    if property==nil {return}
    if channels==4 {return value_color(s.p,property)}
    three:[3]f32
    three,ok=value_vector(s.p,property)
    return {three.x,three.y,three.z,0},ok
}

// The floats of an array of numbers, vectors or colors.
@(private)
property_floats :: proc(p:^unreal.Package,property:^unreal.Property) -> []f32 {
    if property==nil {return nil}
    view,error:=unreal.property_array(p,property)
    if error.code!=.None || view.count==0 || view.data.size%(i64(view.count)*4)!=0 {return nil}
    bytes,bytes_error:=unreal.span_bytes(p,view.data)
    if bytes_error.code!=.None {return nil}
    out:=make([]f32,len(bytes)/4,context.temp_allocator)
    for &value,i in out {value,_=endian.get_f32(bytes[i*4:],.Little)}
    return out
}

@(private)
niagara_mean :: proc(d:Niagara_Dist) -> [4]f32 {return (d.min+d.max)*0.5}

// What a lightweight module gives the effect, by its class.
@(private)
niagara_stateless_module :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,module:level.Ref,u:^Niagara_Values,label:string) {
    d:=c.d
    info:=&e.info
    class:=class_name(d,module)
    switch strings.trim_prefix(class,"NiagaraStatelessModule_") {
    case "InitializeParticle":
        lifetime:=module_dist(u,d,module,"LifetimeDistribution",{1,1,1,1},1)
        info.lifetime={max(lifetime.min.x,0),max(lifetime.max.x,0)}
        color:=module_dist(u,d,module,"ColorDistribution",{1,1,1,1},4)
        colors_set(info,color.min,color.max)
        switch info.render {
        case .Mesh:
            scale:=module_dist(u,d,module,"MeshScaleDistribution",{1,1,1,1},3)
            info.size={max(axes_mean(scale.min),0),max(axes_mean(scale.max),0)}
        case .Ribbon:
            if write,_:=level.bool_of(d,module,"bWriteRibbonWidth",false);write {
                width:=module_dist(u,d,module,"RibbonWidthDistribution",{10,10,10,10},1)
                info.size={max(width.min.x,0),max(width.max.x,0)}*CENTIMETRE
            }
        case .Billboard,.Velocity,.Horizontal:
            size:=module_dist(u,d,module,"SpriteSizeDistribution",{10,10,10,10},2)
            info.size={max(size.min.x,0),max(size.max.x,0)}*CENTIMETRE
        }
        rotation:=module_dist(u,d,module,"SpriteRotationDistribution",{},1)
        info.rotation={rotation.min.x,rotation.max.x}*math.RAD_PER_DEG
    case "ShapeLocation":
        niagara_stateless_shape(u,d,info,module)
    case "AddVelocity":
        kind,_:=level.enum_of(d,module,"VelocityType","Linear")
        switch kind {
        case "FromPoint":
            speed:=module_dist(u,d,module,"PointVelocityDistribution",{100,100,100,100},1)
            scale:=niagara_mean(module_dist(u,d,module,"PointVelocityScale",{1,1,1,1},1)).x
            info.speed={speed.min.x,speed.max.x}*scale*CENTIMETRE
        case "InCone":
            speed:=module_dist(u,d,module,"ConeVelocityDistribution",{500,500,500,500},1)
            scale:=niagara_mean(module_dist(u,d,module,"ConeVelocityScale",{1,1,1,1},1)).x
            info.speed={speed.min.x,speed.max.x}*scale*CENTIMETRE
            info.shape_angle=real(d,module,"ConeAngle",45)*math.RAD_PER_DEG
            if info.shape==.Point {info.shape=.Cone}
        case:
            velocity:=module_dist(u,d,module,"LinearVelocityDistribution",{0,0,100,0},3)
            scale:=niagara_mean(module_dist(u,d,module,"LinearVelocityScale",{1,1,1,1},1)).x
            a,b:=range_to_mirai(velocity.min.xyz*scale,velocity.max.xyz*scale)
            info.velocity={a,b}
        }
    case "GravityForce":
        info.acceleration+=to_mirai(niagara_mean(module_dist(u,d,module,"GravityDistribution",{0,0,-980,0},3)).xyz)
    case "AccelerationForce":
        info.acceleration+=to_mirai(niagara_mean(module_dist(u,d,module,"AccelerationDistribution",{},3)).xyz)
    case "Drag":
        info.drag=max(niagara_mean(module_dist(u,d,module,"DragDistribution",{1,1,1,1},1)).x,0)
    case "CurlNoiseForce":
        info.noise=real(d,module,"NoiseStrength",10)*CENTIMETRE
        info.noise_frequency=max(real(d,module,"NoiseFrequency",50),0)/100
    case "ScaleColor":
        scale:=module_dist(u,d,module,"ScaleDistribution",{1,1,1,1},4)
        if len(scale.curve.samples)>4 {
            info.color_over_life=niagara_gradient_of(scale.curve,info)
        } else {
            colors_set(info,info.colors[0]*scale.min*{info.intensity,info.intensity,info.intensity,1},info.colors[1]*scale.min*{info.intensity,info.intensity,info.intensity,1})
        }
    case "ScaleSpriteSize","ScaleMeshSize","ScaleRibbonWidth":
        channels:=2 if strings.has_suffix(class,"SpriteSize") else 3 if strings.has_suffix(class,"MeshSize") else 1
        scale:=module_dist(u,d,module,"ScaleDistribution",{1,1,1,1},channels)
        if len(scale.curve.samples)>channels {
            info.size_over_life=niagara_curve_of(scale.curve,0)
        } else {
            info.size*=max(scale.min.x,0)
        }
    case "SpriteRotationRate":
        rate:=module_dist(u,d,module,"RotationRateDistribution",{},1)
        info.spin={rate.min.x,rate.max.x}*math.RAD_PER_DEG
    case "MeshRotationRate":
        rate:=niagara_mean(module_dist(u,d,module,"RotationRateDistribution",{},3)).xyz
        axes:=int(rate.x!=0)+int(rate.y!=0)+int(rate.z!=0)
        spin:=math.sqrt(rate.x*rate.x+rate.y*rate.y+rate.z*rate.z)*math.RAD_PER_DEG
        info.spin={spin,spin}
        if axes>1 {unreal_scene.warn(c,"%s, %s: its meshes turn about more than one axis; Mirai's turn about one, as fast",label,e.name)}
    case "InitialMeshOrientation":
        switch mode,_:=level.enum_of(d,module,"MeshOrientationMode","None");mode {
        case "None":
        case "Random":info.rotation={0,2*math.PI}
        case:unreal_scene.warn(c,"%s, %s: its meshes start oriented by %s; Mirai's start turned about one axis",label,e.name,mode)
        }
    case "SubUVAnimation":
        switch mode,_:=level.enum_of(d,module,"AnimationMode","Linear");mode {
        case "Linear":info.flipbook_speed=0
        case "InfiniteLoop":
            frames:=real(d,module,"NumFrames",16)
            info.flipbook_speed=max(real(d,module,"LoopsPerSecond",1)*frames,0)
        case:unreal_scene.warn(c,"%s, %s: its flipbook frames are chosen %s; the effect plays them over the life",label,e.name,"directly" if mode=="DirectSet" else "at random")
        }
    case "LightAttributes":
        if apply,_:=level.bool_of(d,module,"bApplyRadius",false);apply {
            radius:=module_dist(u,d,module,"Radius",{100,100,100,100},1)
            info.light_range=max(niagara_mean(radius).x,0)*CENTIMETRE
        }
    case "MeshIndex":
        index:=module_dist(u,d,module,"MeshIndex",{},1)
        if index.max.x>0 {unreal_scene.warn(c,"%s, %s: its particles pick other meshes than the first; Mirai's draw one",label,e.name)}
    case "RotateAroundPoint":
        rate:=niagara_mean(module_dist(u,d,module,"Rate",{360,360,360,360},1)).x
        radius:=module_dist(u,d,module,"Radius",{100,100,100,100},1)
        axis:=niagara_mean(module_dist(u,d,module,"RotationAxis",{},3)).xyz
        center:=niagara_mean(module_dist(u,d,module,"Center",{},3)).xyz
        if program_set(c,e,"Orbit",label,{program_value("speed",rate*math.RAD_PER_DEG)}) {
            info.shape,info.shell,info.shape_size.x=.Circle,1,max(radius.max.x,0)*CENTIMETRE
            if axis.x!=0 || axis.y!=0 || center!={} {unreal_scene.warn(c,"%s, %s: its particles turn about the up axis of the effect, not about another axis or center",label,e.name)}
        }
    case "ScaleSpriteSizeBySpeed","ScaleMeshSizeBySpeed":
        channels:=2 if strings.has_prefix(class,"NiagaraStatelessModule_ScaleSprite") else 3
        threshold:=niagara_mean(module_dist(u,d,module,"VelocityThreshold",{1000,1000,1000,1000},1)).x
        least:=niagara_mean(module_dist(u,d,module,"MinScaleFactor",{1,1,1,1},channels)).x
        most:=niagara_mean(module_dist(u,d,module,"MaxScaleFactor",{2,2,2,2},channels)).x
        program_set(c,e,"Speed_Size",label,{program_value("speed",max(threshold,0)*CENTIMETRE),program_value("least",max(least,0)),program_value("most",max(most,0))})
    case "CameraOffset":
        unreal_scene.warn(c,"%s, %s: its particles are drawn moved toward the camera; Mirai draws them where they are",label,e.name)
    case "DynamicMaterialParameters":
        unreal_scene.warn(c,"%s, %s: it gives its material values for each particle; Mirai's particle materials read none",label,e.name)
    case "DecalAttributes":
        unreal_scene.warn(c,"%s, %s: it sets attributes of decals; Mirai's particles draw no decals",label,e.name)
    case "ApplyOwnerScaleToAttributes":
        unreal_scene.warn(c,"%s, %s: it scales its particles by the scale of its system; Mirai's effects do not",label,e.name)
    case "SolveVelocitiesAndForces","CalculateAccurateVelocity","SpriteFacingAndAlignment":
        // Mirai integrates the velocity and the forces of each particle every
        // step, and its renderer faces the sprites.
    case:
        unreal_scene.warn(c,"%s, %s: Mirai's effects have nothing for the lightweight module %s",label,e.name,class)
    }
}

// Where a ShapeLocation starts the particles.
@(private)
niagara_stateless_shape :: proc(u:^Niagara_Values,d:^level.Document,info:^effect.Particle_Info,module:level.Ref) {
    surface :: proc(d:^level.Document,module:level.Ref,name:string) -> f32 {
        on,_:=level.bool_of(d,module,name,false)
        return 1 if on else 0
    }
    switch primitive,_:=level.enum_of(d,module,"ShapePrimitive","Sphere");primitive {
    case "Box":
        size:=niagara_mean(module_dist(u,d,module,"BoxSize",{100,100,100,100},3)).xyz
        a,b:=range_to_mirai(-size*0.5,size*0.5)
        info.shape,info.shape_size,info.shell=.Box,(b-a)*0.5,surface(d,module,"bBoxSurfaceOnly")
    case "Plane":
        size:=niagara_mean(module_dist(u,d,module,"PlaneSize",{100,100,100,100},2))
        a,b:=range_to_mirai({-size.x,-size.y,0}*0.5,{size.x,size.y,0}*0.5)
        info.shape,info.shape_size,info.shell=.Box,(b-a)*0.5,0
    case "Cylinder":
        radius:=module_dist(u,d,module,"CylinderRadius",{100,100,100,100},1)
        info.shape,info.shape_size.x,info.shell=.Circle,max(radius.max.x,0)*CENTIMETRE,surface(d,module,"bCylinderSurfaceOnly")
    case "Ring":
        radius:=module_dist(u,d,module,"RingRadius",{100,100,100,100},1)
        info.shape,info.shape_size.x,info.shell=.Circle,max(radius.max.x,0)*CENTIMETRE,1
    case:
        radius:=module_dist(u,d,module,"SphereRadius",{100,100,100,100},1)
        info.shape,info.shape_size.x=.Sphere,max(radius.max.x,0)*CENTIMETRE
        info.shell=1 if radius.min.x==radius.max.x && radius.max.x>0 else 0
    }
}

@(private)
axes_mean :: proc(v:[4]f32) -> f32 {return (v.x+v.y+v.z)/3}

@(private)
program_value :: proc(name:string,value:f32) -> (p:effect.Particle_Parameter) {
    copy(p.name[:],name)
    p.kind,p.components,p.value=.Float,1,{f64(value),0,0,0}
    return
}

// The Vfx program of an effect and its parameters: an effect runs one, so a
// second one is a warning and the first stays.
@(private)
program_set :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,program:string,label:string,parameters:[]effect.Particle_Parameter) -> bool {
    current:=string(cstring(raw_data(e.info.program[:])))
    if current!="" && current!=program {
        unreal_scene.warn(c,"%s, %s: an effect runs one Vfx program: it keeps %s, not %s",label,e.name,current,program)
        return false
    }
    e.info.program={}
    copy(e.info.program[:],program)
    all:=make([dynamic]effect.Particle_Parameter,context.temp_allocator)
    append(&all,..e.parameters)
    append(&all,..parameters)
    e.parameters=all[:]
    return true
}
