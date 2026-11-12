package unreal_vfx_editor

import "core:encoding/endian"
import "core:math"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import "plugins:vfx/runtime/effect"

// The emitters of a Niagara system, of its enabled handles: the values the
// editor keeps of the inputs of their modules (RapidIterationParameters of
// their scripts, by "Module.Input"), the curves their scripts sample
// (CachedDefaultDataInterfaces), what the static switches of their modules
// choose (the pins of the nodes of their graphs) and their renderers; a
// lightweight emitter, the properties of its modules. The dynamic inputs
// wired to an input and what the graphs of scratch pads compute are not read.
@(private)
niagara_system :: proc(c:^unreal_scene.Context,system:level.Ref,label,system_name:string) -> []Unreal_Emitter {
    d:=c.d
    out:=make([dynamic]Unreal_Emitter,context.temp_allocator)
    warmup:=real(d,system,"WarmupTime",0)
    user:Niagara_Values
    user.values=make([dynamic]Niagara_Value,context.temp_allocator)
    exposed:=struct_at(d,system,"ExposedParameters")
    niagara_store(&exposed,&user)
    f,error:=level.property(d,system,"EmitterHandles")
    if error.code!=.None || f.property==nil {return nil}
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None {return nil}
    handles,handles_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
    if handles_error.code!=.None {return nil}
    for &handle,index in handles.items {
        enabled:=value_flag(f.pkg,unreal.property_find(f.pkg,&handle,"bIsEnabled"),true)
        if !enabled {continue}
        handle_name:=""
        if property:=unreal.property_find(f.pkg,&handle,"Name");property!=nil {handle_name,_=level.value_enum(f.pkg,property,"")}
        if mode,_:=level.value_enum(f.pkg,unreal.property_find(f.pkg,&handle,"EmitterMode"),"");strings.has_suffix(mode,"Stateless") {
            emitter,ok:=object_resolve(d,system,value_object(f.pkg,unreal.property_find(f.pkg,&handle,"StatelessEmitter")))
            if !ok {continue}
            e:=Unreal_Emitter{name=strings.clone(handle_name,context.temp_allocator),info=UNREAL_PARTICLE_DEFAULTS}
            niagara_stateless(c,&e,emitter,&user,label)
            append(&out,e)
            continue
        }
        object:=unreal.Object_Ref(0)
        if instance:=unreal.property_find(f.pkg,&handle,"VersionedInstance");instance!=nil {
            list,list_error:=unreal.property_tagged_struct(f.pkg,instance,true,context.temp_allocator)
            if list_error.code==.None {object=value_object(f.pkg,unreal.property_find(f.pkg,&list,"Emitter"))}
        }
        if object==0 {object=value_object(f.pkg,unreal.property_find(f.pkg,&handle,"Instance"))}
        emitter,ok:=object_resolve(d,system,object)
        if !ok {continue}
        e:=Unreal_Emitter{name=strings.clone(handle_name,context.temp_allocator),info=UNREAL_PARTICLE_DEFAULTS,loop=true,handle=index}
        e.info.prewarm=warmup>0
        niagara_emitter(c,&e,emitter,label,&user,system_name)
        append(&out,e)
    }
    niagara_system_translate(c,system,out[:],&user,system_name,label)
    return out[:]
}

// A value of a parameter store: its numbers, an integer, a bool or an enum
// in the first one; full is the name of the parameter in the store.
@(private)
Niagara_Value :: struct {key,full:string,values:[16]f32,count:int}

@(private)
Niagara_Values :: struct {
    every:bool, // keep every parameter of the store, not only the inputs of modules and those of the system
    values:[dynamic]Niagara_Value,
    curves:[dynamic]Niagara_Curve,
    switches:[dynamic]Niagara_Switch,
}

// What a static switch of a module takes, by "Module.Switch": the name the
// editor shows of an entry of an enum, true or false, or a number.
@(private)
Niagara_Switch :: struct {key,value:string}

// Which of options a switch takes; -1 when the graph keeps no such switch or
// it takes another.
@(private)
niagara_mode :: proc(v:^Niagara_Values,key:string,options:..string) -> int {
    for each in v.switches {
        if each.key!=key {continue}
        for option,i in options {if each.value==option {return i}}
    }
    return -1
}

// A curve a module samples, as the editor bakes it: its samples evenly over
// its times, of `channels` values each.
@(private)
Niagara_Curve :: struct {key:string,samples:[]f32,channels:int,start,end:f32}

@(private)
niagara_value :: proc(v:^Niagara_Values,key:string) -> (value:Niagara_Value,found:bool) {
    for &each in v.values {if each.key==key {return each,true}}
    return
}

@(private)
niagara_real :: proc(v:^Niagara_Values,key:string,default:f32) -> (value:f32,found:bool) {
    each,ok:=niagara_value(v,key)
    if !ok || each.count==0 {return default,false}
    return each.values[0],true
}

@(private)
niagara_vector :: proc(v:^Niagara_Values,key:string) -> (value:[4]f32,found:bool) {
    each,ok:=niagara_value(v,key)
    if !ok {return}
    for i in 0..<min(each.count,4) {value[i]=each.values[i]}
    return value,true
}

// The values of the scripts of an emitter version and its renderers.
@(private)
niagara_emitter :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,emitter:level.Ref,label:string,user:^Niagara_Values,system_name:string) {
    d:=c.d
    info:=&e.info
    // An emitter saved before versions keeps the properties of its version itself.
    version:^unreal.Property_List
    f,error:=level.property(d,emitter,"VersionData")
    if error.code==.None && f.property!=nil {
        view,view_error:=unreal.property_array(f.pkg,f.property)
        if view_error.code!=.None {return}
        versions,versions_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
        if versions_error.code!=.None || len(versions.items)==0 {return}
        version=&versions.items[len(versions.items)-1]
    } else {
        held,held_error:=level.object_properties(d,emitter)
        if held_error.code!=.None || held==nil {
            unreal_scene.warn(c,"%s, %s: its emitter keeps no properties this import reads",label,e.name)
            return
        }
        version=&held.list
        f=level.Found{pkg=level.library_package(d.library,int(emitter.pkg)),origin=.Authored}
    }
    info.local_space=value_flag(f.pkg,unreal.property_find(f.pkg,version,"bLocalSpace"),false)
    v:Niagara_Values
    v.values=make([dynamic]Niagara_Value,context.temp_allocator)
    v.curves=make([dynamic]Niagara_Curve,context.temp_allocator)
    v.switches=make([dynamic]Niagara_Switch,context.temp_allocator)
    if source,ok:=object_resolve(d,emitter,value_object(f.pkg,unreal.property_find(f.pkg,version,"GraphSource")));ok {
        if graph,found:=object_at(d,source,"NodeGraph");found {niagara_switches(d,graph,&v)}
    }
    for props in ([4]string{"EmitterUpdateScriptProps","SpawnScriptProps","UpdateScriptProps","EmitterSpawnScriptProps"}) {
        property:=unreal.property_find(f.pkg,version,props)
        if property==nil {continue}
        list,list_error:=unreal.property_tagged_struct(f.pkg,property,true,context.temp_allocator)
        if list_error.code!=.None {continue}
        if script,ok:=object_resolve(d,emitter,value_object(f.pkg,unreal.property_find(f.pkg,&list,"Script")));ok {niagara_script(d,script,&v)}
    }
    if script,ok:=object_resolve(d,emitter,value_object(f.pkg,unreal.property_find(f.pkg,version,"GPUComputeScript")));ok {niagara_script(d,script,&v)}
    niagara_values(c,e,&v,label)
    // The HLSL its scripts keep, when they do, says how its particles start and move.
    e.source=niagara_source(c,emitter,f,version,user,label,e.name)
    for problem in niagara_event_handlers(d,emitter,f,version) {unreal_scene.warn(c,"%s, %s: %s",label,e.name,problem)}
    if renderers:=unreal.property_find(f.pkg,version,"RendererProperties");renderers!=nil {
        if rv,rv_error:=unreal.property_array(f.pkg,renderers);rv_error.code==.None {
            if refs,refs_error:=unreal.array_object_refs(f.pkg,rv,context.temp_allocator);refs_error.code==.None {
                drawn:=false
                for object in refs {
                    if renderer,ok:=object_resolve(d,emitter,object);ok {drawn=niagara_renderer(c,info,renderer,drawn) || drawn}
                }
            }
        }
    }
}

// The static switches of the modules of a graph, from the input pins of its
// function calls that are values of the graph itself (not connectable, not
// linked, with a persistent id), by the name the stack gives the module.
@(private)
niagara_switches :: proc(d:^level.Document,graph:level.Ref,v:^Niagara_Values) {
    for node in objects_at(d,graph,"Nodes") {
        if class_name(d,node)!="NiagaraNodeFunctionCall" {continue}
        f,error:=level.property(d,node,"FunctionDisplayName")
        if error.code!=.None || f.property==nil {continue}
        name,name_error:=unreal.property_value(f.pkg,f.property,context.temp_allocator)
        if name_error.code!=.None || name.kind!=.String {continue}
        p:=level.library_package(d.library,int(node.pkg))
        pins,pins_error:=unreal.graph_node_pins(p,int(node.object)-1,context.temp_allocator)
        if pins_error.code!=.None {continue}
        for pin in pins {
            if !pin.input || pin.links>0 || !pin.persistent || pin.bits&unreal.GRAPH_PIN_NOT_CONNECTABLE==0 {continue}
            if pin.bits&(unreal.GRAPH_PIN_ORPHANED|unreal.GRAPH_PIN_DEFAULT_IGNORED)!=0 {continue}
            value:=pin.default_value
            if unreal.name_plain(p,pin.category)=="Enum" {
                if e,ok:=object_resolve(d,node,pin.sub_object);ok {
                    q:=level.library_package(d.library,int(e.pkg))
                    if entries,entries_error:=unreal.user_enum_entries(q,int(e.object)-1,context.temp_allocator);entries_error.code==.None {
                        for entry in entries {if entry.name==value && entry.display!="" {value=entry.display}}
                    }
                }
            }
            append(&v.switches,Niagara_Switch{key=strings.concatenate({name.text,".",unreal.name_plain(p,pin.name)},context.temp_allocator),value=value})
        }
    }
}

// The values of the parameter store a script keeps for the editor, and the
// curves it samples.
@(private)
niagara_script :: proc(d:^level.Document,script:level.Ref,v:^Niagara_Values) {
    s:=struct_at(d,script,"RapidIterationParameters")
    niagara_store(&s,v)
    f,error:=level.property(d,script,"CachedDefaultDataInterfaces")
    if error.code!=.None || f.property==nil {return}
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None {return}
    interfaces,interfaces_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
    if interfaces_error.code!=.None {return}
    for &item in interfaces.items {
        name,_:=level.value_enum(f.pkg,unreal.property_find(f.pkg,&item,"Name"),"")
        target,ok:=object_resolve(d,script,value_object(f.pkg,unreal.property_find(f.pkg,&item,"DataInterface")))
        if !ok {continue}
        class:=class_name(d,target)
        channels:=4 if strings.has_suffix(class,"ColorCurve") else 3 if strings.has_suffix(class,"VectorCurve") else 2 if strings.has_suffix(class,"Vector2DCurve") else 1 if strings.has_suffix(class,"Curve") else 0
        if channels==0 {continue}
        lut:=struct_field_floats(d,target,"ShaderLUT")
        if len(lut)<channels {continue}
        key:=name[strings.index_byte(name,'.')+1:] if strings.index_byte(name,'.')>=0 else name
        append(&v.curves,Niagara_Curve{key=key,samples=lut,channels=channels,start=real(d,target,"LUTMinTime",0),end=real(d,target,"LUTMaxTime",1)})
    }
}

// The floats of an array property of an object.
@(private)
struct_field_floats :: proc(d:^level.Document,ref:level.Ref,name:string) -> []f32 {
    f,error:=level.property(d,ref,name)
    if error.code!=.None || f.property==nil {return nil}
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None || i64(view.count)*4!=view.data.size {return nil}
    bytes,bytes_error:=unreal.span_bytes(f.pkg,view.data)
    if bytes_error.code!=.None {return nil}
    out:=make([]f32,int(view.count),context.temp_allocator)
    for &value,i in out {value,_=endian.get_f32(bytes[i*4:],.Little)}
    return out
}

// FNiagaraParameterStore: its SortedParameterOffsets, natively a name, a
// type definition as tagged properties and an offset into ParameterData,
// where the value lies as its type lays it out. Only the inputs of modules
// ("Constants.<emitter>.<module>.<input>") are kept, as "<module>.<input>",
// and the parameters of the system ("User.<name>").
@(private)
niagara_store :: proc(s:^Struct_Fields,v:^Niagara_Values) {
    offsets,data:=struct_field(s,"SortedParameterOffsets"),struct_field(s,"ParameterData")
    if offsets==nil || data==nil {return}
    data_view,data_error:=unreal.property_array(s.p,data)
    if data_error.code!=.None {return}
    values,values_error:=unreal.span_bytes(s.p,data_view.data)
    if values_error.code!=.None {return}
    view,view_error:=unreal.property_array(s.p,offsets)
    if view_error.code!=.None {return}
    raw,raw_error:=unreal.span_bytes(s.p,view.data)
    if raw_error.code!=.None {return}
    at:=0
    for _ in 0..<view.count {
        if at+8>len(raw) {return}
        index,_:=endian.get_i32(raw[at:],.Little)
        number,_:=endian.get_i32(raw[at+4:],.Little)
        at+=8
        definition,definition_error:=unreal.properties_open(s.p,{view.data.offset+i64(at),view.data.size-i64(at)},false,context.temp_allocator)
        if definition_error.code!=.None {return}
        at+=int(definition.source.size)
        if at+4>len(raw) {return}
        offset,_:=endian.get_i32(raw[at:],.Little)
        at+=4
        name:=unreal.name_text(s.p,{index,number},context.temp_allocator)
        key:=name
        if strings.has_prefix(name,"Constants.") {
            rest:=name[len("Constants."):]
            dot:=strings.index_byte(rest,'.')
            if dot<0 && !v.every {continue}
            if dot>=0 {key=rest[dot+1:]}
        } else if !strings.has_prefix(name,"User.") && !v.every {continue}
        niagara_value_add(s.p,&definition,key,name,values,int(offset),v)
    }
}

// The compiled parameters of a script (CachedScriptVM.Parameters): natively a
// name, a type definition as tagged properties and the bytes of a default.
// They hold the defaults of the parameters no script writes, which the
// modules read by the name of their emitter (Sphere.AlphaScale).
@(private)
niagara_parameters :: proc(d:^level.Document,script:level.Ref,v:^Niagara_Values) {
    vm:=struct_at(d,script,"CachedScriptVM")
    parameters:=struct_field(&vm,"Parameters")
    if parameters==nil {return}
    list,list_error:=unreal.property_tagged_struct(vm.p,parameters,true,context.temp_allocator)
    if list_error.code!=.None {return}
    variables:=unreal.property_find(vm.p,&list,"Parameters")
    if variables==nil {return}
    view,view_error:=unreal.property_array(vm.p,variables)
    if view_error.code!=.None {return}
    raw,raw_error:=unreal.span_bytes(vm.p,view.data)
    if raw_error.code!=.None {return}
    at:=0
    for _ in 0..<view.count {
        if at+8>len(raw) {return}
        index,_:=endian.get_i32(raw[at:],.Little)
        number,_:=endian.get_i32(raw[at+4:],.Little)
        at+=8
        definition,definition_error:=unreal.properties_open(vm.p,{view.data.offset+i64(at),view.data.size-i64(at)},false,context.temp_allocator)
        if definition_error.code!=.None {return}
        at+=int(definition.source.size)
        if at+4>len(raw) {return}
        size,_:=endian.get_i32(raw[at:],.Little)
        at+=4
        if size<0 || at+int(size)>len(raw) {return}
        name:=unreal.name_text(vm.p,{index,number},context.temp_allocator)
        niagara_value_add(vm.p,&definition,name,name,raw[at:at+int(size)],0,v)
        at+=int(size)
    }
}

// A value of a type of Niagara at an offset of bytes, unless one of its name is known.
@(private)
niagara_value_add :: proc(p:^unreal.Package,definition:^unreal.Property_List,key,name:string,values:[]u8,offset:int,v:^Niagara_Values) {
    type:=""
    underlying,_:=level.value_real(p,unreal.property_find(p,definition,"UnderlyingType"),0)
    for field in ([2]string{"ClassStructOrEnum","Struct"}) {
        if object:=value_object(p,unreal.property_find(p,definition,field));object!=0 {
            if n,ok:=unreal.reference_name(p,object);ok {type=unreal.name_plain(p,n)}
            break
        }
    }
    count,integer:=0,false
    switch {
    case underlying==3 || type=="NiagaraInt32" || type=="NiagaraBool": count,integer=1,true
    case type=="NiagaraFloat": count=1
    case type=="Vector2f" || type=="Vector2D": count=2
    case type=="Vector3f" || type=="Vector" || type=="NiagaraPosition": count=3
    case type=="Vector4f" || type=="Vector4" || type=="LinearColor" || type=="Quat4f" || type=="Quat": count=4
    case type=="NiagaraMatrix": count=16
    }
    if count==0 || offset<0 || offset+count*4>len(values) {return}
    value:=Niagara_Value{key=key,full=name,count=count}
    for i in 0..<count {
        if integer {
            n,_:=endian.get_i32(values[offset+i*4:],.Little)
            value.values[i]=f32(n)
        } else {
            value.values[i],_=endian.get_f32(values[offset+i*4:],.Little)
        }
    }
    for each in v.values {
        if each.full==value.full {return}
    }
    append(&v.values,value)
}

// The fields of an effect from the inputs of the modules of Niagara that
// Mirai has fields for, by the names Niagara's modules give them.
@(private)
niagara_values :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,v:^Niagara_Values,label:string) {
    info:=&e.info
    if rate,ok:=niagara_real(v,"SpawnRate.SpawnRate",0);ok {info.rate=max(rate,0)}
    if duration,ok:=niagara_real(v,"EmitterState.Loop Duration",1);ok {info.duration=max(duration,0)}
    bursts:=0
    for value in v.values {
        if !strings.has_prefix(value.key,"SpawnBurst_Instantaneous") || !strings.has_suffix(value.key,".Spawn Count") || bursts==effect.PARTICLE_BURSTS {continue}
        module:=value.key[:strings.index_byte(value.key,'.')]
        time,_:=niagara_real(v,strings.concatenate({module,".Spawn Time"},context.temp_allocator),0)
        info.bursts[bursts]={time=max(time,0),count=u32(max(value.values[0],0)),cycles=1}
        bursts+=1
    }
    switch niagara_mode(v,"EmitterState.Loop Behavior","Infinite","Once","Multiple") {
    case 1:e.loop=false
    case 2:
        count,_:=niagara_real(v,"EmitterState.Loop Count",1)
        unreal_scene.warn(c,"%s, %s: its cycle repeats %d times; the effect repeats it while it is active",label,e.name,int(count))
    }
    // A module whose graph keeps no switch (one saved before the module had
    // it) takes what its values say, the range before the single value.
    switched:=make([dynamic]string,context.temp_allocator)
    low,has_low:=niagara_real(v,"InitializeParticle.Lifetime Min",1)
    high,has_high:=niagara_real(v,"InitializeParticle.Lifetime Max",1)
    single,has_single:=niagara_real(v,"InitializeParticle.Lifetime",1)
    lifetime:=niagara_mode(v,"InitializeParticle.Lifetime Mode","Direct Set","Random")
    if lifetime<0 && has_low && has_single {append(&switched,"Lifetime")}
    switch {
    case lifetime==0 && has_single:info.lifetime={max(single,0),max(single,0)}
    case lifetime!=0 && has_low && has_high:info.lifetime={max(low,0),max(high,0)}
    case has_single:info.lifetime={max(single,0),max(single,0)}
    }
    switch niagara_mode(v,"InitializeParticle.Color Mode","Unset","Direct Set","Random Range") {
    case 0:
    case 2:
        lo,has_lo:=niagara_vector(v,"InitializeParticle.Color Minimum")
        hi,has_hi:=niagara_vector(v,"InitializeParticle.Color Maximum")
        if has_lo && has_hi {colors_set(info,lo,hi)}
    case:
        if color,ok:=niagara_vector(v,"InitializeParticle.Color");ok {colors_set(info,color,color)}
    }
    niagara_size(v,info,"Sprite Size","Uniform Sprite Size","Sprite Size",1,&switched)
    niagara_size(v,info,"Mesh Scale","Mesh Uniform Scale","Mesh Scale",100,&switched)
    switch niagara_mode(v,"InitializeParticle.Sprite Rotation Mode","Unset","Random","Direct Angle (Degrees)","Direct Normalized Angle (0-1)") {
    case 0:
    case 1:info.rotation={0,2*math.PI}
    case 3:
        if turn,ok:=niagara_real(v,"InitializeParticle.Sprite Rotation Angle",0);ok {info.rotation={turn,turn}*2*math.PI}
    case:
        if rotation,ok:=niagara_real(v,"InitializeParticle.Sprite Rotation Angle",0);ok {info.rotation={rotation,rotation}*math.RAD_PER_DEG}
    }
    if rate,ok:=niagara_real(v,"SpriteRotationRate.Rotation Rate",0);ok {info.spin={rate,rate}*math.RAD_PER_DEG}
    velocity_mode:=niagara_mode(v,"AddVelocity.Velocity Mode","Linear","From Point","In Cone")
    if velocity,ok:=niagara_vector(v,"AddVelocity.Velocity");ok && velocity_mode<=0 {
        scale,_:=niagara_real(v,"AddVelocity.Velocity Speed Scale",1)
        mirai:=to_mirai(velocity.xyz*scale)
        info.velocity={mirai,mirai}
    }
    if speed,ok:=niagara_real(v,"AddVelocity.Velocity Speed",0);ok && velocity_mode!=0 {info.speed={speed,speed}*CENTIMETRE}
    if velocity_mode==2 {
        angle,_:=niagara_real(v,"AddVelocity.Cone Angle",0)
        info.shape_angle=angle*math.RAD_PER_DEG
        if info.shape==.Point {info.shape=.Cone}
    }
    if strength,ok:=niagara_real(v,"AddVelocityInCone.Velocity Strength",0);ok {
        angle,_:=niagara_real(v,"AddVelocityInCone.Cone Angle",0)
        info.speed,info.shape_angle={strength,strength}*CENTIMETRE,angle*math.RAD_PER_DEG
        if info.shape==.Point {info.shape=.Cone}
    }
    if radius,ok:=niagara_real(v,"SphereLocation.Sphere Radius",0);ok {info.shape,info.shape_size.x=.Sphere,max(radius,0)*CENTIMETRE}
    if box,ok:=niagara_vector(v,"BoxLocation.Box Size");ok {
        a,b:=range_to_mirai(-box.xyz*0.5,box.xyz*0.5)
        info.shape,info.shape_size=.Box,(b-a)*0.5
    }
    if radius,ok:=niagara_real(v,"CylinderLocation.Cylinder Radius",0);ok {info.shape,info.shape_size.x=.Circle,max(radius,0)*CENTIMETRE}
    niagara_shape(c,e,v,&switched,label)
    if gravity,ok:=niagara_vector(v,"GravityForce.Gravity");ok {info.acceleration+=to_mirai(gravity.xyz)}
    if acceleration,ok:=niagara_vector(v,"AccelerationForce.Acceleration");ok {info.acceleration+=to_mirai(acceleration.xyz)}
    if drag,ok:=niagara_real(v,"Drag.Drag",0);ok {info.drag=max(drag,0)}
    if noise,ok:=niagara_real(v,"CurlNoiseForce.Noise Strength",0);ok {
        frequency,_:=niagara_real(v,"CurlNoiseForce.Noise Frequency",50)
        info.noise,info.noise_frequency=noise*CENTIMETRE,max(frequency,0)/100
    }
    if strength,ok:=niagara_real(v,"PointAttractionForce.Attraction Strength",0);ok {
        info.attractor_strength=strength*CENTIMETRE
        if offset,found:=niagara_vector(v,"PointAttractionForce.Attractor Position Offset");found {info.attractor=to_mirai(offset.xyz)}
    }
    for curve in v.curves {
        switch {
        case strings.has_prefix(curve.key,"ScaleSpriteSize.") || strings.has_prefix(curve.key,"ScaleMeshSize."):
            info.size_over_life=niagara_curve_of(curve,0)
        case strings.has_prefix(curve.key,"ScaleColor.") && curve.channels==4:
            info.color_over_life=niagara_gradient_of(curve,info)
        }
    }
    if len(switched)>0 {unreal_scene.warn(c,"%s, %s: its modules keep more than one mode of %s, which only their graphs choose; the import takes the range",label,e.name,strings.join(switched[:],", ",context.temp_allocator))}
}

// The size of InitializeParticle by its mode of what (Sprite Size, Mesh
// Scale): uniform, one value; else the first axis of a vector; each a
// constant or a range. scale: centimetres in one of the value.
@(private)
niagara_size :: proc(v:^Niagara_Values,info:^effect.Particle_Info,what,uniform,vector:string,scale:f32,switched:^[dynamic]string) {
    key :: proc(parts:..string) -> string {return strings.concatenate(parts,context.temp_allocator)}
    one,has_one:=niagara_real(v,key("InitializeParticle.",uniform),1)
    low,has_low:=niagara_real(v,key("InitializeParticle.",uniform," Min"),1)
    high,has_high:=niagara_real(v,key("InitializeParticle.",uniform," Max"),1)
    axes,has_axes:=niagara_vector(v,key("InitializeParticle.",vector))
    axes_low,has_axes_low:=niagara_vector(v,key("InitializeParticle.",vector," Min"))
    axes_high,has_axes_high:=niagara_vector(v,key("InitializeParticle.",vector," Max"))
    size:[2]f32
    switch niagara_mode(v,key("InitializeParticle.",what," Mode"),"Unset","Uniform","Random Uniform","Non-Uniform","Random Non-Uniform") {
    case 0:return
    case 1:
        if !has_one {return}
        size={one,one}
    case 2:
        if !has_low || !has_high {return}
        size={low,high}
    case 3:
        if !has_axes {return}
        size={axes.x,axes.x}
    case 4:
        if !has_axes_low || !has_axes_high {return}
        size={axes_low.x,axes_high.x}
    case:
        // A graph without the switch: only the sprite size, as before modes.
        if what!="Sprite Size" {return}
        switch {
        case has_low && has_high:size={low,high}
        case has_one:size={one,one}
        case has_axes:size={axes.x,axes.x}
        case:return
        }
        if has_low && has_one {append(switched,what)}
    }
    info.size={max(size[0],0),max(size[1],0)}*scale*CENTIMETRE
}

// Where ShapeLocation starts the particles, by its Shape Primitive.
@(private)
niagara_shape :: proc(c:^unreal_scene.Context,e:^Unreal_Emitter,v:^Niagara_Values,switched:^[dynamic]string,label:string) {
    info:=&e.info
    primitive:=niagara_mode(v,"ShapeLocation.Shape Primitive","Sphere","Cylinder","Box / Plane","Torus","Ring / Disc","Cone")
    radius,has_radius:=niagara_real(v,"ShapeLocation.Sphere Radius",0)
    switch primitive {
    case 0:
        if has_radius {info.shape,info.shape_size.x=.Sphere,max(radius,0)*CENTIMETRE}
    case 1:
        if r,ok:=niagara_real(v,"ShapeLocation.Cylinder Radius",0);ok {info.shape,info.shape_size.x=.Circle,max(r,0)*CENTIMETRE}
    case 2:
        if box,ok:=niagara_vector(v,"ShapeLocation.Box Size");ok {
            a,b:=range_to_mirai(-box.xyz*0.5,box.xyz*0.5)
            info.shape,info.shape_size=.Box,(b-a)*0.5
        }
    case 3,4:
        r,_:=niagara_real(v,"ShapeLocation.Ring Radius" if primitive==4 else "ShapeLocation.Large Radius",100)
        info.shape,info.shape_size.x,info.shell=.Circle,max(r,0)*CENTIMETRE,1
        if primitive==3 {unreal_scene.warn(c,"%s, %s: its torus is taken as a ring",label,e.name)}
    case 5:
        info.shape=.Cone
        if angle,ok:=niagara_real(v,"ShapeLocation.Cone Angle",0);ok {info.shape_angle=angle*math.RAD_PER_DEG}
    case:
        if has_radius && info.shape==.Point {
            info.shape,info.shape_size.x=.Sphere,max(radius,0)*CENTIMETRE
            append(switched,"Shape Primitive")
        }
    }
}

// A curve of an effect from the samples of a channel of a curve of Niagara,
// at evenly spread times of its life.
@(private)
niagara_curve_of :: proc(curve:Niagara_Curve,channel:int) -> (out:effect.Particle_Curve) {
    samples:=len(curve.samples)/curve.channels
    keys:=effect.PARTICLE_CURVE_KEYS
    for i in 0..<keys {
        t:=f32(i)/f32(keys-1)
        out.times[i]=t
        out.values[i]=max(niagara_curve_at(curve,channel,samples,t),0)
    }
    return
}

@(private)
niagara_curve_at :: proc(curve:Niagara_Curve,channel,samples:int,t:f32) -> f32 {
    if samples<=1 {return curve.samples[channel]}
    at:=clamp((t-curve.start)/max(curve.end-curve.start,1e-6),0,1)*f32(samples-1)
    i:=min(int(at),samples-2)
    return math.lerp(curve.samples[i*curve.channels+channel],curve.samples[(i+1)*curve.channels+channel],at-f32(i))
}

@(private)
niagara_gradient_of :: proc(curve:Niagara_Curve,info:^effect.Particle_Info) -> (g:effect.Particle_Gradient) {
    samples:=len(curve.samples)/curve.channels
    keys:=effect.PARTICLE_CURVE_KEYS
    for i in 0..<keys {
        t:=f32(i)/f32(keys-1)
        g.times[i]=t
        for channel in 0..<4 {g.colors[i][channel]=max(niagara_curve_at(curve,channel,samples,t),0)}
        g.colors[i].a=clamp(g.colors[i].a,0,1)
    }
    gradient_peak_set(&g,info)
    return
}

// What a renderer of an emitter draws; drawn: an earlier one already gave
// how the particles are drawn. True for one that draws them.
@(private)
niagara_renderer :: proc(c:^unreal_scene.Context,info:^effect.Particle_Info,renderer:level.Ref,drawn:bool) -> bool {
    d:=c.d
    if enabled,_:=level.bool_of(d,renderer,"bIsEnabled",true);!enabled {return false}
    switch class:=class_name(d,renderer);class {
    case "NiagaraSpriteRendererProperties":
        if drawn {return false}
        material_set(c,info,renderer,"Material")
        if alignment,_:=level.enum_of(d,renderer,"Alignment","Unaligned");alignment=="VelocityAligned" {info.render=.Velocity}
        if images,ok:=vector_of(d,renderer,"SubImageSize");ok {info.flipbook={u32(max(images.x,1)),u32(max(images.y,1))}}
        sort,_:=level.enum_of(d,renderer,"SortMode","None")
        info.sort=sort!="None"
    case "NiagaraRibbonRendererProperties":
        if drawn {return false}
        material_set(c,info,renderer,"Material")
        info.render=.Ribbon
    case "NiagaraMeshRendererProperties":
        if drawn {return false}
        info.render=.Mesh
        f,error:=level.property(d,renderer,"Meshes")
        if error.code==.None && f.property!=nil {
            if view,view_error:=unreal.property_array(f.pkg,f.property);view_error.code==.None {
                if meshes,meshes_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator);meshes_error.code==.None && len(meshes.items)>0 {
                    if object:=value_object(f.pkg,unreal.property_find(f.pkg,&meshes.items[0],"Mesh"));object!=0 {
                        if path,path_error:=level.object_path(d,renderer,object,context.temp_allocator);path_error.code==.None {
                            if m,imported:=unreal_scene.mesh_import(c,path);imported {info.meshes[0]=m.id}
                        }
                    }
                }
            }
        }
        // The material that takes the place of those of the mesh: the first override.
        if overrides,_:=level.bool_of(d,renderer,"bOverrideMaterials",false);overrides {
            f,error=level.property(d,renderer,"OverrideMaterials")
            if error.code==.None && f.property!=nil {
                if view,view_error:=unreal.property_array(f.pkg,f.property);view_error.code==.None {
                    if items,items_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator);items_error.code==.None && len(items.items)>0 {
                        if object:=value_object(f.pkg,unreal.property_find(f.pkg,&items.items[0],"ExplicitMat"));object!=0 {
                            if path,path_error:=level.object_path(d,renderer,object,context.temp_allocator);path_error.code==.None {
                                if id,ok:=unreal_scene.material_import(c,path);ok {info.material=id}
                            }
                            if material,ok:=object_resolve(d,renderer,object);ok {info.blend,info.lit=material_look(d,material)}
                        }
                    }
                }
            }
        }
    case "NiagaraLightRendererProperties":
        // A light on each particle: Mirai lights a number of them, as far as
        // RadiusScale times their size.
        count:=info.rate*info.lifetime[1]
        for burst in info.bursts {count+=f32(burst.count)}
        info.lights=u32(clamp(math.ceil(count),1,64))
        info.light_range=max(real(d,renderer,"RadiusScale",1),0)*(info.size[0]+info.size[1])*0.5
        info.light_intensity=max(info.light_intensity,16)
        // Niagara casts shadows of the lights MegaLights takes alone.
        mega,_:=level.bool_of(d,renderer,"bAllowMegaLights",false)
        shadows,_:=level.bool_of(d,renderer,"bMegaLightsCastShadows",false)
        info.light_shadows=mega && shadows
        unreal_scene.warn(c,"its particle lights are approximated: %d of them, %.3g cd, %.3g m of range",info.lights,info.light_intensity,info.light_range)
        return false
    case:
        unreal_scene.warn(c,"Mirai's effects have nothing for the renderer %s",class)
        return false
    }
    return true
}
