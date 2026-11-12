package unreal_vfx_editor

import "core:fmt"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"

// What a Niagara script keeps of its compilation (CachedScriptVM): the HLSL
// Niagara's translator generated from its graph, its data interfaces and,
// of a GPU script, its simulation stages. A script saved without compiling
// keeps no HLSL.
Niagara_Compiled :: struct {
    hlsl:string,
    decompiled:bool,   // hlsl is the bytecode of the VM decompiled (niagara_vm.odin)
    problems:[]string, // what the decompilation could not translate
    interfaces:[]Niagara_Interface,
    stages:[]Niagara_Stage_Info,
}

// A data interface a script calls: the name the parameter map gives it
// ("Emitter.Grid2DCollection"), its class (NiagaraDataInterfaceGrid2DCollection)
// and the object with its properties, when the script keeps one.
Niagara_Interface :: struct {
    name,class:string,
    object:level.Ref,
    found:bool,
}

Niagara_Iteration :: enum u8 {Particles,Interface,Direct}

// A simulation stage of a GPU script (SimulationStageMetaData).
Niagara_Stage_Info :: struct {
    name:string,
    source:Niagara_Iteration,
    over:string,          // the data interface it goes over
    iterations:int,
    writes_particles:bool,
    outputs:[]string,     // the data interfaces it writes
    reset_only:bool,      // it runs only when the simulation starts again
}

// The compilation of a script; false without HLSL or bytecode it translates,
// with the problems that say why in c.problems.
@(private)
niagara_compiled :: proc(d:^level.Document,script:level.Ref) -> (c:Niagara_Compiled,ok:bool) {
    vm:=struct_at(d,script,"CachedScriptVM")
    if !vm.ok {return}
    // A script of the GPU keeps its text in the one of the GPU, one of the VM (a system's) in the other.
    for name in ([2]string{"LastHlslTranslationGPU","LastHlslTranslation"}) {
        text:=struct_field(&vm,name)
        if text==nil {continue}
        value,error:=unreal.property_value(vm.p,text,context.temp_allocator)
        if error.code==.None && value.kind==.String && value.text!="" {
            c.hlsl=value.text
            break
        }
    }
    // A save of 5.8 or later keeps only the bytecode of a script of the VM: its text is decompiled.
    if c.hlsl=="" {
        problems:=make([dynamic]string,context.temp_allocator)
        bytecode,read:=niagara_vm_read(d,script,&vm,&problems)
        if read {c.hlsl,read=niagara_vm_hlsl(&bytecode,&problems)}
        c.problems=problems[:]
        if !read {return}
        c.decompiled=true
    }
    interfaces:=make([dynamic]Niagara_Interface,context.temp_allocator)
    if info:=struct_field(&vm,"DataInterfaceInfo");info!=nil {
        if view,view_error:=unreal.property_array(vm.p,info);view_error.code==.None {
            if items,items_error:=unreal.array_tagged_structs(vm.p,view,true,context.temp_allocator);items_error.code==.None {
                for &item in items.items {
                    name,_:=level.value_enum(vm.p,unreal.property_find(vm.p,&item,"Name"),"")
                    class:=""
                    if type:=unreal.property_find(vm.p,&item,"Type");type!=nil {
                        if fields,fields_error:=unreal.property_tagged_struct(vm.p,type,true,context.temp_allocator);fields_error.code==.None {
                            if object:=value_object(vm.p,unreal.property_find(vm.p,&fields,"ClassStructOrEnum"));object!=0 {
                                if n,named:=unreal.reference_name(vm.p,object);named {class=strings.clone(unreal.name_plain(vm.p,n),context.temp_allocator)}
                            }
                        }
                    }
                    append(&interfaces,Niagara_Interface{name=strings.clone(name,context.temp_allocator),class=class})
                }
            }
        }
    }
    // The objects of the data interfaces, by their names.
    if f,f_error:=level.property(d,script,"CachedDefaultDataInterfaces");f_error.code==.None && f.property!=nil {
        if view,view_error:=unreal.property_array(f.pkg,f.property);view_error.code==.None {
            if items,items_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator);items_error.code==.None {
                for &item in items.items {
                    name,_:=level.value_enum(f.pkg,unreal.property_find(f.pkg,&item,"Name"),"")
                    target,found:=object_resolve(d,script,value_object(f.pkg,unreal.property_find(f.pkg,&item,"DataInterface")))
                    if !found {continue}
                    for &each in interfaces {
                        // A newer save names the emitter where the compilation says Emitter.
                        if each.name!=name && !(strings.has_prefix(each.name,"Emitter.") && strings.index_byte(name,'.')>=0 && each.name[len("Emitter"):]==name[strings.index_byte(name,'.'):]) {continue}
                        each.object,each.found=target,true
                        // A newer save keeps the type natively: the class is that of the object.
                        if each.class=="" {each.class=class_name(d,target)}
                    }
                }
            }
        }
    }
    // The objects the emitter resolves its data interfaces to, which a newer save keeps
    // complete where the defaults leave their fields at the class's (a channel unset).
    if f,error:=level.property(d,script,"ResolvedDataInterfaces");error.code==.None && f.property!=nil {
        if view,view_error:=unreal.property_array(f.pkg,f.property);view_error.code==.None {
            if items,items_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator);items_error.code==.None {
                for &item in items.items {
                    name,_:=level.value_enum(f.pkg,unreal.property_find(f.pkg,&item,"CompileName"),"")
                    target,found:=object_resolve(d,script,value_object(f.pkg,unreal.property_find(f.pkg,&item,"ResolvedDataInterface")))
                    if !found || name=="" {continue}
                    for &each in interfaces {
                        if each.name!=name {continue}
                        each.object,each.found=target,true
                        if each.class=="" {each.class=class_name(d,target)}
                    }
                }
            }
        }
    }
    c.interfaces=interfaces[:]
    stages:=make([dynamic]Niagara_Stage_Info,context.temp_allocator)
    if meta:=struct_field(&vm,"SimulationStageMetaData");meta!=nil {
        if view,view_error:=unreal.property_array(vm.p,meta);view_error.code==.None {
            if items,items_error:=unreal.array_tagged_structs(vm.p,view,true,context.temp_allocator);items_error.code==.None {
                for &item in items.items {
                    stage:Niagara_Stage_Info
                    name,_:=level.value_enum(vm.p,unreal.property_find(vm.p,&item,"SimulationStageName"),"")
                    stage.name=strings.clone(name,context.temp_allocator)
                    source,_:=level.value_enum(vm.p,unreal.property_find(vm.p,&item,"IterationSourceType"),"Particles")
                    switch source {
                    case "DataInterface": stage.source=.Interface
                    case "DirectSet": stage.source=.Direct
                    case: stage.source=.Particles
                    }
                    over,_:=level.value_enum(vm.p,unreal.property_find(vm.p,&item,"IterationDataInterface"),"")
                    stage.over=strings.clone(over,context.temp_allocator)
                    iterations,_:=level.value_real(vm.p,unreal.property_find(vm.p,&item,"NumIterations"),1)
                    stage.iterations=max(int(iterations),1)
                    writes:=value_flag(vm.p,unreal.property_find(vm.p,&item,"bWritesParticles"),false)
                    stage.writes_particles=writes
                    behavior,_:=level.value_enum(vm.p,unreal.property_find(vm.p,&item,"ExecuteBehavior"),"Always")
                    stage.reset_only=behavior=="OnSimulationReset"
                    outputs:=make([dynamic]string,context.temp_allocator)
                    if list:=unreal.property_find(vm.p,&item,"OutputDestinations");list!=nil {
                        if names_view,names_error:=unreal.property_array(vm.p,list);names_error.code==.None {
                            if names,read_error:=unreal.array_names(vm.p,names_view,context.temp_allocator);read_error.code==.None {
                                for n in names {append(&outputs,unreal.name_text(vm.p,n,context.temp_allocator))}
                            }
                        }
                    }
                    stage.outputs=outputs[:]
                    append(&stages,stage)
                }
            }
        }
    }
    c.stages=stages[:]
    // The events it writes for the event handlers of other emitters.
    problems:=make([dynamic]string,context.temp_allocator)
    append(&problems,..c.problems)
    for &item in niagara_struct_items(vm.p,struct_field(&vm,"WriteDataSets")) {
        name:=""
        if id:=unreal.property_find(vm.p,&item,"ID");id!=nil {
            if fields,error:=unreal.property_tagged_struct(vm.p,id,true,context.temp_allocator);error.code==.None {
                name,_=level.value_enum(vm.p,unreal.property_find(vm.p,&fields,"Name"),"")
            }
        }
        append(&problems,fmt.tprintf("it writes the event %s, which is not translated; %s",name,NIAGARA_EVENTS_ALTERNATIVE))
    }
    c.problems=problems[:]
    return c,true
}

// What a script that writes or handles an event of Niagara uses in Mirai instead.
NIAGARA_EVENTS_ALTERNATIVE :: "Mirai has no events between emitters: carry what the event carries in a Niagara Data Channel (DataChannelWrite where it is generated, SpawnConditional and GetNDCSpawnData where it is handled), or read the particles of the other emitter with a Particle Attribute Reader"

// The event handlers of an emitter, which Mirai does not translate: a problem
// for each that names its script, its event and what to use instead.
@(private)
niagara_event_handlers :: proc(d:^level.Document,emitter:level.Ref,f:level.Found,version:^unreal.Property_List) -> []string {
    out:=make([dynamic]string,context.temp_allocator)
    for &item in niagara_struct_items(f.pkg,unreal.property_find(f.pkg,version,"EventHandlerScriptProps")) {
        script:="its script"
        if target,ok:=object_resolve(d,emitter,value_object(f.pkg,unreal.property_find(f.pkg,&item,"Script")));ok {script=object_name(d,target)}
        event,_:=level.value_enum(f.pkg,unreal.property_find(f.pkg,&item,"SourceEventName"),"")
        append(&out,fmt.tprintf("its event handler %s (of the event %s) is not translated; %s",script,event,NIAGARA_EVENTS_ALTERNATIVE))
    }
    return out[:]
}
