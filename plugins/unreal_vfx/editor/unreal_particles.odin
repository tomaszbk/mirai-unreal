package unreal_vfx_editor

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "mirai:core"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

// The particle systems of an Unreal level, Cascade (Emitter actors) and
// Niagara (NiagaraActor): each emitter of a system is a .particle in
// levels/<map>/, written once for every actor that shows the system, and an
// actor is an entity with a Particle_Emitter, or a group with one entity for
// each emitter. What Mirai's effects say otherwise, or what the package keeps
// only in the graphs of Niagara's scripts, is a warning of the effect.
@(storage)
Vfx_Unreal :: struct {provider:unreal_scene.Translator_Provider}

vfx_unreal_default :: proc() -> (v:Vfx_Unreal) {
    v.provider.count=2
    v.provider.translators[0]={classes={0="Emitter",1="NiagaraActor"},translate=particles_translate}
    v.provider.translators[1]={classes={0="ParticleSystemComponent",1="NiagaraComponent"},component=particles_component}
    return
}

// An emitter of a system, read: the values of its .particle, those of its
// Vfx program and whether its cycle starts again.
Unreal_Emitter :: struct {
    name:string,
    info:effect.Particle_Info,
    parameters:[]effect.Particle_Parameter,
    loop:bool,
    grids:[]Unreal_Grid,       // that its program reads, placed with it
    bindings:[]Unreal_Binding, // the emitters of the system its program reads
    source:^Niagara_Source,    // the compilation its scripts keep; nil without one
    handle:int,                // of a Niagara emitter, its handle among those of its system: its Engine.Emitter.ID
}

UNREAL_EMITTERS_MAX :: 16 // of a system that are translated

// Unreal's centimetres in metres.
CENTIMETRE :: f32(0.01)

@(private)
particles_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"vfx.translate")
    d:=c.d
    written:=particles_import(c)
    if written==nil {return 0}
    translated:=0
    for a in actors {
        root:=d.actors[a].root
        if root<0 {continue}
        niagara:=level.actor_native_class(d,a).name=="NiagaraActor"
        if particles_place(c,a,root,niagara,0,&written.systems,&written.index) {translated+=1}
        if c.failed {break}
    }
    return translated
}

// A particle system component of another actor (a Blueprint): its emitters
// on the entity the scene made of it.
@(private)
particles_component :: proc(c:^unreal_scene.Context,a,k:int,e:base.Entity_Id) {
    unreal_scene.zone(c,"vfx.component")
    if written:=particles_import(c);written!=nil {
        particles_place(c,a,k,c.d.components[k].class.name=="NiagaraComponent",e,&written.systems,&written.index)
    }
}

// The systems an import wrote, by path, and the index of its next effect:
// one for the actors and the components of every Blueprint that show them.
@(private)
Particles_Import :: struct {systems:map[string]Particles_Written,index:int}

// The Particles_Import of the import of c; nil without memory for it.
@(private)
particles_import :: proc(c:^unreal_scene.Context) -> ^Particles_Import {
    if kept,found:=c.kept[PARTICLES_KEPT];found {return (^Particles_Import)(kept)}
    written:=new(Particles_Import,context.temp_allocator)
    if written==nil {return nil}
    written.systems=make(map[string]Particles_Written,context.temp_allocator)
    c.kept[PARTICLES_KEPT]=written
    return written
}

@(private)
PARTICLES_KEPT :: "vfx.particles"

// The effects of the emitters of a system, written once for every component that shows it.
@(private)
Particles_Written :: struct {
    ids:[UNREAL_EMITTERS_MAX]base.Asset_Id,loops:[UNREAL_EMITTERS_MAX]bool,names:[UNREAL_EMITTERS_MAX]string,count:int,
    grids:[UNREAL_EMITTERS_MAX][]Unreal_Grid,bindings:[UNREAL_EMITTERS_MAX][]Unreal_Binding,
}

// The system component k of actor a shows: its emitters on entity e, or on
// an entity of the actor made where it is when e is 0.
@(private)
particles_place :: proc(c:^unreal_scene.Context,a,k:int,niagara:bool,e:base.Entity_Id,systems:^map[string]Particles_Written,index:^int) -> bool {
    d:=c.d
    e:=e
    label:=d.actors[a].label
    ref:=d.components[k].ref
    property:="Asset" if niagara else "Template"
    path:=level.path_of(d,ref,property)
    system,found:=object_at(d,ref,property)
    if !found {
        unreal_scene.warn(c,"%s: it shows no particle system",label)
        return false
    }
    written,seen:=systems[path]
    if !seen {
        name:=unreal.asset_name(path[strings.last_index_byte(path,'.')+1:])
        emitters:=niagara_system(c,system,label,name) if niagara else cascade_system(c,system,label)
        for &emitter in emitters {
            if written.count==UNREAL_EMITTERS_MAX {
                unreal_scene.warn(c,"%s: only its first %d emitters are translated",name,UNREAL_EMITTERS_MAX)
                break
            }
            part:=name if len(emitters)==1 else fmt.tprintf("%s %s",name,emitter.name)
            id,file,info:=unreal_scene.asset_place(c,effect.PARTICLE_KIND,part,index^,effect.PARTICLE_EXTENSION)
            index^+=1
            bytes,error:=effect.particle_bytes(c.types,{id=id,info=emitter.info,parameters=emitter.parameters,source=&info})
            if error!=.None {
                unreal_scene.warn(c,"%s: its effect does not validate (%v): %s",part,error,effect.particle_validate({info=emitter.info}).message)
                continue
            }
            defer delete(bytes)
            if !unreal_scene.asset_write(c,id,effect.PARTICLE_KIND,part,file,bytes) {continue}
            written.ids[written.count],written.loops[written.count],written.names[written.count]=id,emitter.loop,emitter.name
            written.grids[written.count],written.bindings[written.count]=emitter.grids,emitter.bindings
            written.count+=1
        }
        systems[path]=written
    }
    if written.count==0 {return false}
    active,_:=level.bool_of(d,ref,"bAutoActivate",true)
    key:=unreal_scene.actor_key(c,a)
    if e!=0 {
        key=fmt.tprintf("%s|%s",key,d.components[k].name)
    } else {
        world,_,world_error:=level.actor_world(d,a)
        if world_error.code!=.None {return false}
        made:bool
        e,made=unreal_scene.entity_make(c,0,key,label,world)
        if !made {return false}
    }
    targets:[UNREAL_EMITTERS_MAX]base.Entity_Id
    for i in 0..<written.count {
        shown:=vfx.Particle_Emitter{particle=written.ids[i],active=active,loop=written.loops[i],preview=true}
        target:=e
        if written.count>1 {
            child,child_made:=unreal_scene.entity_make(c,e,fmt.tprintf("%s/%d",key,i),written.names[i],mm.TRANSFORM_IDENTITY)
            if !child_made {return false}
            target=child
        }
        targets[i]=target
        if !unreal_scene.component_set(c,target,"Particle_Emitter",&shown) {return false}
    }
    // The render targets the component gives the parameters of its system: a
    // grid that writes one is a texture of the world, which materials read by UV.
    textures:map[string]string
    if niagara {textures=niagara_component_textures(d,ref)}
    // The grids each program reads, one entity for each key of the actor (a grid of the system
    // or one an emitter writes and another reads), and the emitters it reads.
    keyed:=make(map[string]base.Entity_Id,allocator=context.temp_allocator)
    for i in 0..<written.count {
        if len(written.grids[i])==0 && len(written.bindings[i])==0 {continue}
        bound:vfx.Particle_Bindings
        sources:=0
        for grid in written.grids[i] {
            child,known:=keyed[grid.key]
            if !known {
                child_made:bool
                child,child_made=unreal_scene.entity_make(c,targets[i],fmt.tprintf("%s/%s",key,grid.key),grid.key,mm.TRANSFORM_IDENTITY)
                if !child_made {return false}
                keyed[grid.key]=child
                g:=vfx.Particle_Grid{cells=grid.cells,cell_size=grid.cell_size,layers=min(grid.layers,vfx.GRID_LAYERS),cached=grid.cached}
                // Each grid of the world has a name of its own: the program finds it by the binding.
                unique:=fmt.tprintf("%08x_%s",u32(base.name_hash(fmt.tprintf("%s/%s",key,grid.key))),grid.resource)
                unique=unique[:min(len(unique),vfx.GRID_NAME_BYTES-1)]
                base.text_set(g.name[:],unique)
                if !unreal_scene.component_set(c,child,"Particle_Grid",&g) {return false}
                if target,given:=textures[grid.user];grid.user!="" && given {
                    texture:=vfx.Particle_World_Texture{}
                    if !unreal_scene.component_set(c,child,"Particle_World_Texture",&texture) {return false}
                    unreal_scene.texture_read_add(c,{texture=target,include="vfx_world_texture.slang",function="vfx_world_texture_uv",name=unique})
                }
            }
            if sources<len(bound.sources) {
                base.text_set(bound.sources[sources].resource[:],grid.resource)
                bound.sources[sources].entity=core.Entity(child)
                sources+=1
            }
        }
        for binding in written.bindings[i] {
            if binding.level {
                // The actor of the level the component names, by the name of its object
                // with its number (Statue_2).
                named:=niagara_mesh_actor(d,ref)
                for actor,other in d.actors {
                    if named=="" || sources>=len(bound.sources) || object_numbered_name(d,actor.ref)!=named {continue}
                    if entity,placed:=unreal_scene.actor_entity(c,other);placed {
                        base.text_set(bound.sources[sources].resource[:],binding.resource)
                        bound.sources[sources].entity=core.Entity(entity)
                        sources+=1
                    }
                }
                if named=="" {unreal_scene.warn(c,"%s: %s reads the mesh of no actor of the level",label,binding.resource)}
                continue
            }
            for j in 0..<written.count {
                if written.names[j]!=binding.emitter || sources>=len(bound.sources) {continue}
                base.text_set(bound.sources[sources].resource[:],binding.resource)
                bound.sources[sources].entity=core.Entity(targets[j])
                sources+=1
            }
        }
        if !unreal_scene.component_set(c,targets[i],"Particle_Bindings",&bound) {return false}
    }
    return true
}

// The render targets a Niagara component gives the parameters of its system,
// by parameter: their object paths. InstanceParameterOverrides maps each
// variable, saved natively as its name and then its type, to a variant whose
// Object is the texture.
@(private)
niagara_component_textures :: proc(d:^level.Document,ref:level.Ref) -> map[string]string {
    out:=make(map[string]string,allocator=context.temp_allocator)
    f,error:=level.property(d,ref,"InstanceParameterOverrides")
    if error.code!=.None || f.property==nil || f.origin!=.Authored {return out}
    data:=f.property.data
    raw,raw_error:=unreal.span_bytes(f.pkg,data)
    if raw_error.code!=.None || len(raw)<8 {return out}
    count,_:=endian.get_i32(raw[4:],.Little)
    at,end:=data.offset+8,data.offset+data.size
    for _ in 0..<count {
        if at+8>end {break}
        name:=niagara_name_at(f.pkg,raw[at-data.offset:])
        at+=8
        kind,kind_error:=unreal.properties_open(f.pkg,{at,end-at},false,context.temp_allocator)
        if kind_error.code!=.None {break}
        at=kind.source.offset+kind.source.size
        variant,variant_error:=unreal.properties_open(f.pkg,{at,end-at},false,context.temp_allocator)
        if variant_error.code!=.None {break}
        at=variant.source.offset+variant.source.size
        object:=value_object(f.pkg,unreal.property_find(f.pkg,&variant,"Object"))
        target,resolved:=object_resolve(d,ref,object)
        if name=="" || !resolved || class_name(d,target)!="TextureRenderTarget2D" {continue}
        if path,path_error:=level.object_path(d,ref,object,context.temp_allocator);path_error.code==.None {out[name]=path}
    }
    return out
}

// What an effect starts from before the modules or parameters of Unreal say
// otherwise: what an emitter of Unreal does with none of them. The color of
// an unlit particle is what the exposed image shows, as the emissive of the
// particle materials of Unreal looks under the exposure of its levels.
@(private)
UNREAL_PARTICLE_DEFAULTS :: effect.Particle_Info{
    duration=1,shape=.Point,
    lifetime={1,1},size={0.01,0.01},colors={{1,1,1,1},{1,1,1,1}},intensity=1,emission_mode=.Relative,
    blend=.Alpha,lit=true,flipbook={1,1},light_range=1,
    size_over_life=effect.PARTICLE_CURVE_ONE,
    color_over_life={colors={0..<effect.PARTICLE_CURVE_KEYS={1,1,1,1}},times={0,1,1,1,1,1,1,1}},
}

// ---------------------------------------------------------------- reading

// The object an object property of ref names, opened from its package or
// another; false for none, a null one or a class of a script package. One
// ref does not save is that of its archetype (the template of a component a
// Blueprint adds), named from the package of the archetype.
@(private)
object_at :: proc(d:^level.Document,ref:level.Ref,name:string) -> (target:level.Ref,ok:bool) {
    f,error:=level.property(d,ref,name)
    if error.code!=.None || f.property==nil {return}
    return object_resolve(d,f.owner,value_object(f.pkg,f.property))
}

@(private)
object_resolve :: proc(d:^level.Document,ref:level.Ref,object:unreal.Object_Ref) -> (target:level.Ref,ok:bool) {
    if object==0 {return}
    resolved,native,error:=level.resolve(d,ref,object)
    return resolved,error.code==.None && !native
}

// The objects an array property of ref names, in order; those that do not
// open are left out.
@(private)
objects_at :: proc(d:^level.Document,ref:level.Ref,name:string) -> []level.Ref {
    f,error:=level.property(d,ref,name)
    if error.code!=.None || f.property==nil || f.origin!=.Authored {return nil}
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None {return nil}
    refs,refs_error:=unreal.array_object_refs(f.pkg,view,context.temp_allocator)
    if refs_error.code!=.None {return nil}
    out:=make([dynamic]level.Ref,context.temp_allocator)
    for object in refs {
        if target,ok:=object_resolve(d,ref,object);ok {append(&out,target)}
    }
    return out[:]
}

// The class of an object, without its package: "ParticleModuleSize".
@(private)
class_name :: proc(d:^level.Document,ref:level.Ref) -> string {
    p:=level.library_package(d.library,int(ref.pkg))
    if ref.object<=0 || int(ref.object)>len(p.exports) {return ""}
    return level.class_of(p,p.exports[int(ref.object)-1].class).name
}

// The name of an object of its package.
@(private)
object_name :: proc(d:^level.Document,ref:level.Ref) -> string {
    p:=level.library_package(d.library,int(ref.pkg))
    name,ok:=unreal.reference_name(p,ref.object)
    return unreal.name_plain(p,name) if ok else ""
}

// The name of the object as its paths say it: with the number of its name.
@(private)
object_numbered_name :: proc(d:^level.Document,ref:level.Ref) -> string {
    p:=level.library_package(d.library,int(ref.pkg))
    name,ok:=unreal.reference_name(p,ref.object)
    return unreal.name_text(p,name,context.temp_allocator) if ok else ""
}

// The fields of a struct property of ref, older tagged layouts too.
@(private)
Struct_Fields :: struct {list:unreal.Property_List,p:^unreal.Package,ok:bool}

@(private)
struct_at :: proc(d:^level.Document,ref:level.Ref,name:string) -> (s:Struct_Fields) {
    f,error:=level.property(d,ref,name)
    if error.code!=.None || f.property==nil {return}
    list,list_error:=unreal.property_tagged_struct(f.pkg,f.property,true,context.temp_allocator)
    if list_error.code!=.None {return}
    return {list,f.pkg,true}
}

@(private)
struct_field :: proc(s:^Struct_Fields,name:string) -> ^unreal.Property {
    if !s.ok {return nil}
    return unreal.property_find(s.p,&s.list,name)
}

// A number or a vector of a property as three floats: a number in all three.
@(private)
value_vector :: proc(p:^unreal.Package,property:^unreal.Property) -> (v:[3]f32,ok:bool) {
    if property==nil {return}
    value,error:=unreal.property_value(p,property,context.temp_allocator)
    if error.code!=.None {return}
    #partial switch value.kind {
    case .Real:     return {f32(value.real),f32(value.real),f32(value.real)},true
    case .Signed:   return {f32(value.signed),f32(value.signed),f32(value.signed)},true
    case .Unsigned: return {f32(value.unsigned),f32(value.unsigned),f32(value.unsigned)},true
    case .Real_Vector:
        for i in 0..<min(int(value.vector_count),3) {v[i]=f32(value.vector[i])}
        return v,true
    }
    return
}

@(private)
value_color :: proc(p:^unreal.Package,property:^unreal.Property) -> (v:[4]f32,ok:bool) {
    if property==nil {return}
    value,error:=unreal.property_value(p,property,context.temp_allocator)
    if error.code!=.None || value.kind!=.Real_Vector || value.vector_count<3 {return}
    v={f32(value.vector[0]),f32(value.vector[1]),f32(value.vector[2]),1}
    if value.vector_count>3 {v[3]=f32(value.vector[3])}
    return v,true
}

// A bool property, or a number as one; default without it.
@(private)
value_flag :: proc(p:^unreal.Package,property:^unreal.Property,default:bool) -> bool {
    if property==nil {return default}
    v,error:=unreal.property_value(p,property)
    if error.code!=.None {return default}
    #partial switch v.kind {
    case .Boolean: return v.boolean
    case .Signed: return v.signed!=0
    case .Unsigned: return v.unsigned!=0
    case .Real: return v.real!=0
    }
    return default
}

@(private)
value_object :: proc(p:^unreal.Package,property:^unreal.Property) -> unreal.Object_Ref {
    if property==nil {return 0}
    value,error:=unreal.property_value(p,property,context.temp_allocator)
    if error.code!=.None || value.kind!=.Object {return 0}
    return value.object
}

@(private)
vector_of :: proc(d:^level.Document,ref:level.Ref,name:string) -> (v:[3]f32,ok:bool) {
    f,error:=level.property(d,ref,name)
    if error.code!=.None || f.property==nil {return}
    return value_vector(f.pkg,f.property)
}

@(private)
real :: proc(d:^level.Document,ref:level.Ref,name:string,default:f32) -> f32 {
    value,_:=level.real_of(d,ref,name,f64(default))
    return f32(value)
}

// ---------------------------------------------------------------- values over time

DIST_KEYS :: 32

// A value a module gives a particle: between min and max at its start, or
// along keys over a time from 0 to 1 (of its life, or of the cycle). A
// number is in x.
Dist :: struct {
    min,max:[3]f32,
    times:[DIST_KEYS]f32,
    values:[DIST_KEYS][3]f32,
    key_count:int,
    found:bool,
}

dist_mean :: proc(d:Dist) -> [3]f32 {return (d.min+d.max)*0.5}

// The value of a curve at a time, between its keys.
dist_at :: proc(d:Dist,time:f32) -> [3]f32 {
    if d.key_count==0 {return dist_mean(d)}
    times,values:=d.times,d.values
    return vfx.keys_at(times[:d.key_count],values[:d.key_count],time)
}

// A curve of an effect from a value over the life of a particle: its keys
// when they fit, else the value at evenly spread times. scale: what it is
// taken as one of.
dist_curve :: proc(d:Dist,axis:int,scale:f32=1) -> (c:effect.Particle_Curve) {
    c=effect.PARTICLE_CURVE_ONE
    if d.key_count==0 {return}
    count:=min(d.key_count,effect.PARTICLE_CURVE_KEYS)
    for i in 0..<effect.PARTICLE_CURVE_KEYS {
        if i>=count {c.values[i],c.times[i]=c.values[count-1],1;continue}
        t:=d.times[i] if d.key_count<=effect.PARTICLE_CURVE_KEYS else f32(i)/f32(count-1)
        c.times[i]=clamp(t,i>0?c.times[i-1]:0,1)
        c.values[i]=max(dist_at(d,t)[axis]/scale,0)
    }
    return
}

// A Cascade distribution of a module (FRawDistributionFloat or
// FRawDistributionVector): the object it names (constant, uniform or a
// curve), else the values the package baked with it.
@(private)
cascade_dist :: proc(d:^level.Document,module:level.Ref,name:string) -> (out:Dist) {
    s:=struct_at(d,module,name)
    if !s.ok {return}
    out.found=true
    if v,ok:=value_vector(s.p,struct_field(&s,"MinValueVec"));ok {out.min=v} else if v,ok=value_vector(s.p,struct_field(&s,"MinValue"));ok {out.min=v}
    if v,ok:=value_vector(s.p,struct_field(&s,"MaxValueVec"));ok {out.max=v} else if v,ok=value_vector(s.p,struct_field(&s,"MaxValue"));ok {out.max=v}
    distribution,ok:=object_resolve(d,module,value_object(s.p,struct_field(&s,"Distribution")))
    if !ok {return}
    class:=class_name(d,distribution)
    switch {
    case strings.has_suffix(class,"Constant"):
        v,_:=vector_of(d,distribution,"Constant")
        out.min,out.max=v,v
    case strings.has_suffix(class,"Uniform"):
        out.min,_=vector_of(d,distribution,"Min")
        out.max,_=vector_of(d,distribution,"Max")
    case strings.has_suffix(class,"ConstantCurve"):
        curve:=struct_at(d,distribution,"ConstantCurve")
        points:=struct_field(&curve,"Points")
        if points==nil {return}
        view,view_error:=unreal.property_array(curve.p,points)
        if view_error.code!=.None {return}
        array,array_error:=unreal.array_tagged_structs(curve.p,view,true,context.temp_allocator)
        if array_error.code!=.None {return}
        out.min,out.max={max(f32),max(f32),max(f32)},{-max(f32),-max(f32),-max(f32)}
        for &point in array.items[:min(len(array.items),DIST_KEYS)] {
            t,_:=value_vector(curve.p,unreal.property_find(curve.p,&point,"InVal"))
            v,_:=value_vector(curve.p,unreal.property_find(curve.p,&point,"OutVal"))
            out.times[out.key_count],out.values[out.key_count]=t.x,v
            out.key_count+=1
            out.min,out.max=linalg.min(out.min,v),linalg.max(out.max,v)
        }
        if out.key_count==0 {out.min,out.max={},{}}
    }
    return
}

// A vector of Unreal (centimetres, Z up) in Mirai's space, metres.
@(private)
to_mirai :: proc(v:[3]f32) -> [3]f32 {return level.point_to_mirai({f64(v.x),f64(v.y),f64(v.z)})}

// A range of vectors of Unreal in Mirai's space, each axis from its least to its most.
@(private)
range_to_mirai :: proc(lo,hi:[3]f32) -> (a,b:[3]f32) {
    p,q:=to_mirai(lo),to_mirai(hi)
    return linalg.min(p,q),linalg.max(p,q)
}

// A gradient of Unreal: colors above 1 give their peak to the intensity of the effect.
@(private)
gradient_peak_set :: proc(g:^effect.Particle_Gradient,info:^effect.Particle_Info) {
    peak:=f32(1)
    for key in g.colors {peak=max(peak,key.r,key.g,key.b)}
    for &key in g.colors {key.rgb/=peak}
    info.intensity*=peak
}

// A color of Unreal: one above 1 gives its peak to the intensity of the effect.
@(private)
colors_set :: proc(info:^effect.Particle_Info,lo,hi:[4]f32) {
    peak:=max(lo.r,lo.g,lo.b,hi.r,hi.g,hi.b,1)
    info.intensity=peak
    info.colors={{lo.r/peak,lo.g/peak,lo.b/peak,clamp(lo.a,0,1)},{hi.r/peak,hi.g/peak,hi.b/peak,clamp(hi.a,0,1)}}
}

// How a material of Unreal blends and whether light falls on it: its
// BlendMode and ShadingModel, or those of its parents.
@(private)
material_look :: proc(d:^level.Document,material:level.Ref) -> (blend:effect.Particle_Blend,lit:bool) {
    blend,lit=.Alpha,true
    current:=material
    for _ in 0..<8 {
        mode,found:=level.enum_of(d,current,"BlendMode","")
        if !found {
            overrides:=struct_at(d,current,"BasePropertyOverrides")
            if property:=struct_field(&overrides,"BlendMode");property!=nil {mode,found=level.value_enum(overrides.p,property,"")}
        }
        shading,shaded:=level.enum_of(d,current,"ShadingModel","")
        if shaded {lit=shading!="MSM_Unlit"}
        if found {
            blend=.Additive if mode=="BLEND_Additive" else .Alpha
            return
        }
        parent,ok:=object_at(d,current,"Parent")
        if !ok {return}
        current=parent
    }
    return
}

// The material of a particle system as Mirai's, with how it blends and is lit.
@(private)
material_set :: proc(c:^unreal_scene.Context,info:^effect.Particle_Info,owner:level.Ref,name:string) {
    path:=level.path_of(c.d,owner,name)
    if path=="" {return}
    if id,ok:=unreal_scene.material_import(c,path);ok {info.material=id}
    if material,ok:=object_at(c.d,owner,name);ok {info.blend,info.lit=material_look(c.d,material)}
}
