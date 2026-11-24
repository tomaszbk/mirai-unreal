package unreal_vfx_editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

// The emitters of a system whose scripts keep the HLSL of their compilation
// are translated together: the attributes of each and the attributes of the
// grids are laid out once for the system, so a program reads the particles
// of another emitter and a grid another emitter writes (a grid of the system
// or one a reader names) where they are.

// A grid an emitter's program reads, which the import places with the entity
// of the system (one for each key) and binds to its resource.
Unreal_Grid :: struct {
    resource:string,
    key:string,    // the grid of the system it is: one entity for each key of an actor
    cells:[3]u32,
    cell_size:f32, // metres
    layers:u32,
    user:string,   // of a render target: the parameter of the system whose texture it writes; "" none
}

NIAGARA_CAPACITY_MAX :: 65536 // particles of a translated emitter
NIAGARA_BIRTHS_ROOM :: f32(1024) // particles of an emitter whose program gives births its modules say nothing of

// The actor the mesh data interfaces of the component of the actor name.
Unreal_Binding :: struct {resource:string,level:bool}

// What an emitter's scripts keep of their compilation, read for its program.
Niagara_Source :: struct {
    gpu,spawn,update:Maybe(Niagara_Compiled),
    object:level.Ref,        // the emitter
    values:Niagara_Values,   // every parameter its scripts keep, by name
    interfaces:[dynamic]Niagara_Interface,
    parts:[]Niagara_Part,
    attributes:[]Hlsl_Field, // laid out for the system, one field a component
    interpolated:bool,       // its spawn script runs update for the rest of the frame (bInterpolatedSpawning)
    problems:[dynamic]string,// what the decompilation of its scripts could not translate
}

// What the emitters of a system share.
Niagara_System :: struct {
    emitters:map[string]^Unreal_Emitter, // by the name of their handles
    grids:map[string]^Niagara_Grid_Layout, // by key
    spawn,update:Maybe(Niagara_Compiled), // the scripts of the system (niagara_system.odin)
    problems:[dynamic]string,             // what the decompilation of those could not translate
    values:Niagara_Values,                // the parameters of the system and its scripts
    textures:map[string]Niagara_Texture,  // baked for its Texture data interfaces, by the path of the texture
}

// The floats of a cell of a grid of the system: the unnamed attributes, then those the scripts name.
Niagara_Grid_Layout :: struct {
    unnamed:int,
    named:[dynamic]Niagara_Attribute,
    floats:int,
}

// What the scripts of an emitter keep of their compilation; nil without HLSL.
@(private)
niagara_source :: proc(c:^unreal_scene.Context,emitter:level.Ref,f:level.Found,version:^unreal.Property_List,user:^Niagara_Values,label,name:string) -> ^Niagara_Source {
    d:=c.d
    script_of :: proc(d:^level.Document,emitter:level.Ref,f:level.Found,version:^unreal.Property_List,props:string) -> (script:level.Ref,ok:bool) {
        property:=unreal.property_find(f.pkg,version,props)
        if property==nil {return}
        list,list_error:=unreal.property_tagged_struct(f.pkg,property,true,context.temp_allocator)
        if list_error.code!=.None {return}
        return object_resolve(d,emitter,value_object(f.pkg,unreal.property_find(f.pkg,&list,"Script")))
    }
    target,_:=level.value_enum(f.pkg,unreal.property_find(f.pkg,version,"SimTarget"),"CPUSim")
    s:=new(Niagara_Source,context.temp_allocator)
    s.object=emitter
    s.interpolated=value_flag(f.pkg,unreal.property_find(f.pkg,version,"bInterpolatedSpawning"),false)
    s.values.every=true
    s.values.values=make([dynamic]Niagara_Value,context.temp_allocator)
    s.interfaces=make([dynamic]Niagara_Interface,context.temp_allocator)
    s.problems=make([dynamic]string,context.temp_allocator)
    // A script it decompiles says what it could not translate; one it refuses, why.
    take :: proc(c:^unreal_scene.Context,s:^Niagara_Source,d:^level.Document,script:level.Ref,label,name:string) -> (compiled:Niagara_Compiled,ok:bool) {
        compiled,ok=niagara_compiled(d,script)
        for problem in compiled.problems {
            if ok {append(&s.problems,fmt.tprintf("%s: %s",object_name(d,script),problem));continue}
            unreal_scene.warn(c,"%s, %s: %s: %s",label,name,object_name(d,script),problem)
        }
        return
    }
    for each in user.values {append(&s.values.values,each)}
    for props in ([4]string{"SpawnScriptProps","UpdateScriptProps","EmitterSpawnScriptProps","EmitterUpdateScriptProps"}) {
        if script,ok:=script_of(d,emitter,f,version,props);ok {
            store:=struct_at(d,script,"RapidIterationParameters")
            niagara_store(&store,&s.values)
        }
    }
    if strings.has_suffix(target,"GPUComputeSim") {
        script,ok:=object_resolve(d,emitter,value_object(f.pkg,unreal.property_find(f.pkg,version,"GPUComputeScript")))
        if !ok {return nil}
        store:=struct_at(d,script,"RapidIterationParameters")
        niagara_store(&store,&s.values)
        niagara_parameters(d,script,&s.values)
        if compiled,has:=take(c,s,d,script,label,name);has {s.gpu=compiled}
    } else {
        if script,ok:=script_of(d,emitter,f,version,"SpawnScriptProps");ok {
            niagara_parameters(d,script,&s.values)
            if compiled,has:=take(c,s,d,script,label,name);has {s.spawn=compiled}
        }
        if script,ok:=script_of(d,emitter,f,version,"UpdateScriptProps");ok {
            niagara_parameters(d,script,&s.values)
            if compiled,has:=take(c,s,d,script,label,name);has {s.update=compiled}
        }
    }
    // A decompiled spawn script of an interpolated emitter runs its update too, as the VM does.
    if spawn,ok:=s.spawn.?;ok && spawn.decompiled {s.interpolated=false}
    _,has_gpu:=s.gpu.?
    _,has_spawn:=s.spawn.?
    _,has_update:=s.update.?
    if !has_gpu && !(has_spawn && has_update) {return nil}
    for script in ([3]Maybe(Niagara_Compiled){s.gpu,s.spawn,s.update}) {
        compiled,ok:=script.?
        if !ok {continue}
        for each in compiled.interfaces {
            known:=false
            for other in s.interfaces {known||=other.name==each.name}
            if !known {append(&s.interfaces,each)}
        }
    }
    return s
}

// The programs of the emitters of a system that keep their compilation:
// their parts and attributes first, the layouts of the grids of the system,
// then each program, stored with the map's build.
@(private)
niagara_system_translate :: proc(c:^unreal_scene.Context,system:level.Ref,emitters:[]Unreal_Emitter,user:^Niagara_Values,system_name,label:string) {
    sys:Niagara_System
    niagara_system_scripts(c.d,system,&sys,user)
    for problem in sys.problems {unreal_scene.warn(c,"%s: %s",label,problem)}
    sys.emitters=make(map[string]^Unreal_Emitter,allocator=context.temp_allocator)
    sys.grids=make(map[string]^Niagara_Grid_Layout,allocator=context.temp_allocator)
    sys.textures=make(map[string]Niagara_Texture,allocator=context.temp_allocator)
    for &e in emitters {
        if e.source==nil {continue}
        sys.emitters[e.name]=&e
        w:=niagara_writer(c,&sys,&e,system_name)
        e.source.parts=niagara_parts(&w,e.source)
        e.source.attributes=niagara_attributes(e.source.parts)
        // The named attributes of the grids it reads and writes, in the layouts of their keys.
        for &part in e.source.parts {
            for item in part.items {
                if item.kind!=.Prototype {continue}
                di,ok:=niagara_interface_of(&w,item.name)
                if !ok || di.kind!=.Grid {continue}
                layout:=niagara_grid_layout(&sys,niagara_grid_key(&w,&e,di))
                if !strings.has_suffix(di.class,"Reader") {layout.unnamed=max(layout.unnamed,int(niagara_di_real(&w,di,"NumAttributes",0)))}
                base_name,specifier:=niagara_function_parts(item.name,di)
                name:=niagara_attribute_named(specifier)
                if name=="" {continue}
                known:=false
                for a in layout.named {known||=a.name==name}
                if !known {append(&layout.named,Niagara_Attribute{name=strings.clone(name,context.temp_allocator),count=niagara_value_floats(base_name)})}
            }
        }
    }
    for _,layout in sys.grids {
        layout.floats=layout.unnamed
        for &a in layout.named {
            a.offset=layout.floats
            layout.floats+=a.count
        }
        layout.floats=max(layout.floats,1)
    }
    for &e in emitters {
        if e.source==nil || len(e.source.parts)==0 {continue}
        niagara_emitter_program(c,&sys,&e,system_name,label)
    }
}

@(private)
niagara_grid_layout :: proc(sys:^Niagara_System,key:string) -> ^Niagara_Grid_Layout {
    if found,ok:=sys.grids[key];ok {return found}
    layout:=new(Niagara_Grid_Layout,context.temp_allocator)
    layout.named=make([dynamic]Niagara_Attribute,context.temp_allocator)
    sys.grids[key]=layout
    return layout
}

// The key of the grid a data interface is: one of the system is shared by its
// emitters, a reader names the emitter and data interface it reads, and
// another is of its emitter, which its scripts name Emitter. and those of the
// system by the name of the emitter: one grid.
@(private)
niagara_grid_key :: proc(w:^Niagara_Writer,e:^Unreal_Emitter,di:^Niagara_Di) -> string {
    if strings.has_suffix(di.class,"Reader") && di.found {
        emitter,_:=level.enum_of(w.d,di.object,"EmitterName","")
        name,_:=level.enum_of(w.d,di.object,"DIName","")
        if emitter=="" {emitter=niagara_string(w.d,di.object,"EmitterName")}
        if name=="" {name=niagara_string(w.d,di.object,"DIName")}
        if emitter!="" && name!="" {return fmt.tprintf("%s.Emitter.%s",emitter,name)}
    }
    if strings.has_prefix(di.name,"System.") || strings.has_prefix(di.name,"User.") {return di.name}
    if own:=strings.concatenate({e.name,"."},context.temp_allocator);strings.has_prefix(di.name,own) {return fmt.tprintf("%s.Emitter.%s",e.name,di.name[len(own):])}
    return fmt.tprintf("%s.%s",e.name,di.name)
}

// A string property of an object; "" without one.
@(private)
niagara_string :: proc(d:^level.Document,ref:level.Ref,name:string) -> string {
    f,error:=level.property(d,ref,name)
    if error.code!=.None || f.property==nil {return ""}
    value,value_error:=unreal.property_value(f.pkg,f.property,context.temp_allocator)
    if value_error.code!=.None || value.kind!=.String {return ""}
    return strings.clone(value.text,context.temp_allocator)
}

@(private)
niagara_writer :: proc(c:^unreal_scene.Context,sys:^Niagara_System,e:^Unreal_Emitter,system_name:string) -> Niagara_Writer {
    w:=Niagara_Writer{scene=c,d=c.d,name=niagara_program_name(system_name,e.name),values=&e.source.values,local=e.info.local_space,system=sys,emitter=e}
    w.out=strings.builder_make(context.temp_allocator)
    w.interfaces=make([dynamic]Niagara_Di,context.temp_allocator)
    w.problems=make([dynamic]string,context.temp_allocator)
    w.resources=make([dynamic]string,context.temp_allocator)
    w.tex_params=make([dynamic]Niagara_Tex_Param,context.temp_allocator)
    w.stage_lines=make([dynamic]string,context.temp_allocator)
    w.spawns=make([dynamic]string,context.temp_allocator)
    w.kept=make([dynamic]Niagara_Kept,context.temp_allocator)
    niagara_interfaces_add(&w,e.source.interfaces[:])
    return w
}

// The program of an emitter goes into the build, and its bindings go with the emitter.
@(private)
niagara_emitter_program :: proc(c:^unreal_scene.Context,sys:^Niagara_System,e:^Unreal_Emitter,system_name,label:string) {
    w:=niagara_writer(c,sys,e,system_name)
    if !niagara_program(&w,e.source) {return}
    address,error:=importer.output_program(&c.outputs,strings.to_string(w.out))
    if error.code!=.None {
        unreal_scene.warn(c,"%s, %s: its Vfx program could not be stored: %s",
            label,e.name,error.message)
        return
    }
    base.text_set(e.info.program[:],asset.generated_program_id(address,context.temp_allocator))
    if len(w.tex_params)>0 {
        params:=make([dynamic]effect.Particle_Parameter,context.temp_allocator)
        append(&params,..e.parameters)
        for tp in w.tex_params {
            p:=effect.Particle_Parameter{kind=.Texture,components=1,texture=tp.id}
            base.text_set(p.name[:],tp.name)
            append(&params,p)
        }
        e.parameters=params[:]
    }
    // The program says when a particle dies: the effect keeps room for what its births and the
    // lifetime of its modules need, and a lifetime its clock never sees end.
    births:=f32(0)
    for burst in e.info.bursts {births+=f32(burst.count)*f32(max(burst.cycles,1))}
    births+=e.info.rate*max(e.info.lifetime[1],1)*1.25
    // The births a program gives are known only as it runs: room for those of its modules, or NIAGARA_BIRTHS_ROOM.
    if len(w.spawns)>0 && births<1 {births=NIAGARA_BIRTHS_ROOM}
    e.info.max_particles=u32(clamp(births+16,16,NIAGARA_CAPACITY_MAX))
    e.info.lifetime={UNENDING_SECONDS,UNENDING_SECONDS}
    // The scripts of the system loop the emitter: the clock of the effect only counts its seconds,
    // and a cycle of its own that ended would start its particles again.
    if len(w.spawns)>0 {e.info.duration=UNENDING_SECONDS}
    for problem in e.source.problems {unreal_scene.warn(c,"%s, %s: %s",label,e.name,problem)}
    for problem in w.problems {unreal_scene.warn(c,"%s, %s: %s",label,e.name,problem)}
    grids:=make([dynamic]Unreal_Grid,context.temp_allocator)
    bindings:=make([dynamic]Unreal_Binding,context.temp_allocator)
    for &di in w.interfaces {
        if di.resource=="" {continue}
        switch di.kind {
        case .Grid,.Render_Target,.Neighbors,.Raster:
            cell:=max(di.size.x/f32(max(di.cells.x,1)),1e-3)*CENTIMETRE
            // A 2D one is flat along y (niagara_grids.odin).
            cells:=di.three?[3]u32{u32(di.cells.x),u32(di.cells.y),u32(di.cells.z)}:[3]u32{u32(di.cells.x),1,u32(di.cells.y)}
            append(&grids,Unreal_Grid{resource=di.resource,key=niagara_grid_key(&w,e,&di),cells=cells,cell_size=cell,layers=u32(max(niagara_di_layers(&di),1)),user=di.user})
        case .Mesh:
            append(&bindings,Unreal_Binding{resource=di.resource,level=true})
        case .Unknown,.Curve,.Noise,.Collision,.Camera,.GBuffer,.Particles,.Channel_Read,.Channel_Write,.Vector_Field,.Texture,.Emitter_Info,.Array:
        }
    }
    e.grids,e.bindings=grids[:],bindings[:]
}

// The name of the program of an emitter of a system: an identifier.
@(private)
niagara_program_name :: proc(system,emitter:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"Niagara_")
    for part in ([2]string{system,emitter}) {
        for i in 0..<len(part) {
            ch:=part[i]
            strings.write_byte(&b,is_ident(ch)?ch:'_')
        }
        strings.write_byte(&b,'_')
    }
    name:=strings.to_string(b)
    name=name[:len(name)-1]
    // The name of a program fits the 64 bytes an effect keeps of it.
    if len(name)>48 {name=fmt.tprintf("%s_%08x",name[:39],u32(base.name_hash(name)))}
    return name
}

// The object of a data interface of a class in the stack of an emitter: it
// is named after its parameter, with or without its namespace
// (Emitter.Color.ColorCurve: Color_ColorCurve).
@(private)
niagara_object_named :: proc(d:^level.Document,pkg:i32,class,name:string) -> (object:level.Ref,found:bool) {
    p:=level.library_package(d.library,int(pkg))
    wanted:=niagara_identifier(name)
    short:=niagara_identifier(name[strings.index_byte(name,'.')+1:])
    // A module used twice numbers its parameters (Array001) and not always its objects.
    plain:=strings.trim_right(short,"0123456789")
    // Else the copies the scripts keep, named after their class: the first of them.
    candidate,copy:=level.Ref{},level.Ref{}
    for i in 0..<len(p.exports) {
        other:=level.Ref{pkg,unreal.Object_Ref(i+1)}
        if class_name(d,other)!=class {continue}
        named:=object_name(d,other)
        if named==wanted || named==short {return other,true}
        if named==plain && candidate.object==0 {candidate=other}
        if named==class && copy.object==0 {copy=other}
    }
    if candidate.object==0 {candidate=copy}
    return candidate,candidate.object!=0
}
