package level

import "core:mem"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// The levels of an uncooked Unreal map: the actors of each Level, the
// objects each actor owns (its components) and their properties, looked up
// through their archetypes. Unreal's names stay here; what leaves is classes
// by name, transforms in Mirai's space (transform.odin) and properties for
// the translators of each kind of object.

// An object of a package of the library: an export (object > 0).
Ref :: struct {pkg:i32,object:unreal.Object_Ref}

// The class of an object: its package (/Script/Engine, or /Game/... for a
// Blueprint) and its name (StaticMeshComponent, BP_Door_C).
Class :: struct {pkg,name:string}

Level :: struct {
    ref:Ref,
    first_actor,actor_count:int,
}

Actor :: struct {
    ref:Ref,
    level:int,
    class:Class,
    label:string,    // ActorLabel, or the object name
    root:int,        // its RootComponent among the components, or -1
    first_component,component_count:int,
    external:bool,   // saved in its own package (World Partition)
}

// An object whose outer is an actor: its components and whatever else it owns.
Component :: struct {
    ref:Ref,
    actor:int,
    class:Class,
    name:string,
    parent:int,      // the component of AttachParent, or -1
    socket:string,   // AttachSocketName, "" without one
}

Template :: struct {
    next:Ref,
    native:bool,
    error:unreal.Error,
}

Object_Properties :: struct {
    list:unreal.Property_List,
    error:unreal.Error,
}

// Indices into these arrays name levels, actors and components; the
// document owns them and the library owns the packages.
Document :: struct {
    library:^Library,
    levels:[dynamic]Level,
    actors:[dynamic]Actor,
    components:[dynamic]Component,
    properties:map[Ref]Object_Properties, // of every object opened, archetypes included
    by_ref:map[Ref]int,                   // the component of an export
    templates:map[Ref]Template,           // the archetype of every object asked for
    texts:[dynamic][]u8,                  // converted labels
    superseded:[dynamic]Superseded,       // external actor packages left out
    sockets:map[string]Mesh_Sockets,      // of each mesh a component is attached to by socket, by path
    allocator:mem.Allocator,
}

// An external actor package whose actor path another package also holds:
// Unreal loads one of the two and so does the reader.
Superseded :: struct {actor,left,kept:string}

// Where a property was found: on the object, on an archetype of it, or
// nowhere before a native class, whose defaults are those of its C++ constructor.
Origin :: enum u8 {Authored,Archetype,Native}

Found :: struct {
    property:^unreal.Property, // nil with Native
    pkg:^unreal.Package,   // of the property
    origin:Origin,
    owner:Ref,             // the object that holds it: references of its value are of its package
}

@(private) LEVEL_ACTORS_ARRAY :: 3
@(private) UE4_TEMPLATE_INDEX :: 508
@(private) OUTER_DEPTH :: 64
@(private) ACTOR_LABEL_IN_COOKED :: 4
@(private) RF_CLASS_DEFAULT_OBJECT :: 0x10
@(private) RF_INHERITABLE_COMPONENT_TEMPLATE :: 0x400000
@(private) ICH_SCENE_ROOT_PREFIX :: "ICH-" // the name prefix of an overridden default scene root

document_destroy :: proc(d:^Document) {
    for _,&held in d.properties {unreal.properties_destroy(&held.list)}
    for text in d.texts {delete(text,d.allocator)}
    for item in d.superseded {delete(item.actor,d.allocator);delete(item.left,d.allocator);delete(item.kept,d.allocator)}
    delete(d.superseded)
    for path,&s in d.sockets {delete(path,d.allocator);mesh_sockets_destroy(&s,d.allocator)}
    delete(d.sockets)
    delete(d.levels);delete(d.actors);delete(d.components)
    delete(d.properties);delete(d.by_ref);delete(d.templates);delete(d.texts)
    d^={}
}

// Reads the levels of package map_index of the library: the actors of each
// Level and, when it keeps them apart, its external actors.
document_open :: proc(d:^Document,lib:^Library,map_index:int,allocator:=context.allocator) -> (error:unreal.Error) {
    d^={library=lib,allocator=allocator}
    d.levels.allocator,d.actors.allocator,d.components.allocator,d.texts.allocator=allocator,allocator,allocator,allocator
    d.properties.allocator,d.by_ref.allocator,d.templates.allocator=allocator,allocator,allocator
    d.superseded.allocator,d.sockets.allocator=allocator,allocator
    defer if error.code!=.None {document_destroy(d)}
    p:=library_package(lib,map_index)
    for _,index in p.exports {
        ref:=Ref{i32(map_index),unreal.Object_Ref(index+1)}
        if !export_is(p,ref.object,"/Script/Engine","Level") {continue}
        if error=level_read(d,ref);error.code!=.None {return}
    }
    if len(d.levels)==0 {return {.Unsupported_Value,0,"package has no Level export; open a .umap"}}
    return components_resolve(d)
}

@(private)
level_read :: proc(d:^Document,ref:Ref) -> unreal.Error {
    p:=library_package(d.library,int(ref.pkg))
    held,error:=object_properties(d,ref)
    if error.code!=.None {return error}
    payload,payload_error:=unreal.object_native_payload(p,held.list.trailing)
    if payload_error.code!=.None {return payload_error}
    r:=payload
    release,_:=unreal.custom_version(p,unreal.RELEASE_OBJECT_VERSION)
    // Before the array conversion version the array carried its owner first.
    if release<LEVEL_ACTORS_ARRAY {r.offset+=4;r.size-=4}
    actors,actors_error:=refs_read(p,r)
    if actors_error.code!=.None {return actors_error}
    level_index:=len(d.levels)
    append(&d.levels,Level{ref=ref,first_actor=len(d.actors)})
    if error=actors_add(d,level_index,int(ref.pkg),actors,false);error.code!=.None {return error}
    external,_:=bool_of(d,ref,"bUseExternalActors",false)
    if external {if error=external_actors_read(d,level_index);error.code!=.None {return error}}
    d.levels[level_index].actor_count=len(d.actors)-d.levels[level_index].first_actor
    return {}
}

// The object references of an array saved natively: a count and the references.
@(private)
refs_read :: proc(p:^unreal.Package,span:unreal.Span) -> (refs:[]unreal.Object_Ref,error:unreal.Error) {
    bytes:[]u8
    bytes,error=unreal.span_bytes(p,span)
    if error.code!=.None {return}
    if len(bytes)<4 {return nil,{.Truncated,span.offset,"Level actor count"}}
    count:=i64(transmute(i32)(u32(bytes[0])|u32(bytes[1])<<8|u32(bytes[2])<<16|u32(bytes[3])<<24))
    if count<0 || u64(count)>u64(p.limits.table_entries) {return nil,{.Limit,span.offset,"Level actor count"}}
    if 4+count*4>i64(len(bytes)) {return nil,{.Truncated,span.offset,"Level actor references"}}
    refs=make([]unreal.Object_Ref,int(count),context.temp_allocator)
    for &ref,i in refs {
        at:=4+i*4
        ref=unreal.Object_Ref(transmute(i32)(u32(bytes[at])|u32(bytes[at+1])<<8|u32(bytes[at+2])<<16|u32(bytes[at+3])<<24))
        if !unreal.reference_valid(p,ref) {return nil,{.Invalid_Reference,span.offset+i64(at),"Level actor reference"}}
    }
    return
}

// Adds the actors of package ref.pkg that refs name, then their
// components: the exports each one is the outer of, contiguous by actor.
@(private)
actors_add :: proc(d:^Document,level,package_index:int,refs:[]unreal.Object_Ref,external:bool) -> unreal.Error {
    p:=library_package(d.library,package_index)
    first:=len(d.actors)
    owner:=make(map[unreal.Object_Ref]int,len(refs),context.temp_allocator)
    for object in refs {
        if object<=0 || object in owner {continue}
        ref:=Ref{i32(package_index),object}
        item:=p.exports[int(object)-1]
        actor:=Actor{ref=ref,level=level,class=class_of(p,item.class),root=-1,external=external}
        actor.label=named(d,p,item.object_name)
        if found,error:=property(d,ref,"ActorLabel");error.code==.None && found.origin==.Authored {
            value,value_error:=unreal.property_value(found.pkg,found.property,d.allocator)
            if value_error.code==.None && value.kind==.String {
                actor.label=value.text
                if value.owned_text!=nil {append(&d.texts,value.owned_text)}
            } else {unreal.value_destroy(&value)}
        } else if error.code==.Out_Of_Memory {return error}
        owner[object]=len(d.actors)
        append(&d.actors,actor)
    }
    counts:=make([]int,len(d.actors)-first,context.temp_allocator)
    for item in p.exports {if at,ok:=owner[item.outer];ok {counts[at-first]+=1}}
    at:=len(d.components)
    for &actor,i in d.actors[first:] {actor.first_component=at;actor.component_count=0;at+=counts[i]}
    resize(&d.components,at)
    for item,index in p.exports {
        actor_index,ok:=owner[item.outer]
        if !ok {continue}
        actor:=&d.actors[actor_index]
        slot:=actor.first_component+actor.component_count
        actor.component_count+=1
        component:=Component{ref={i32(package_index),unreal.Object_Ref(index+1)},actor=actor_index,class=class_of(p,item.class),name=named(d,p,item.object_name),parent=-1}
        d.components[slot]=component
        d.by_ref[component.ref]=slot
    }
    for &actor in d.actors[first:] {
        root,error:=reference_property(d,actor.ref,"RootComponent")
        if error.code==.Out_Of_Memory {return error}
        if error.code==.None && root>0 {
            if slot,found:=d.by_ref[{actor.ref.pkg,root}];found {actor.root=slot}
        }
    }
    return {}
}

// A name of p with its number, as Unreal tells objects apart ("Mesh_3"),
// held by d.
@(private)
named :: proc(d:^Document,p:^unreal.Package,name:unreal.Name_Ref) -> string {
    if name.number<=0 {return unreal.name_plain(p,name)}
    text:=unreal.name_text(p,name,d.allocator)
    append(&d.texts,transmute([]u8)text)
    return text
}

// The AttachParent and socket of every component, once all are known.
@(private)
components_resolve :: proc(d:^Document) -> unreal.Error {
    for &component,index in d.components {
        found,error:=property(d,component.ref,"AttachParent")
        if error.code==.Out_Of_Memory {return error}
        if error.code==.None && found.property!=nil {
            value,value_error:=unreal.property_value(found.pkg,found.property)
            if value_error.code==.None && value.kind==.Object && value.object>0 {
                if found.origin==.Authored {
                    if at,ok:=d.by_ref[{component.ref.pkg,value.object}];ok {component.parent=at}
                } else {
                    component.parent=sibling_of_template(d,index,found.pkg,value.object)
                }
            }
        }
        if socket,socket_error:=property(d,component.ref,"AttachSocketName");socket_error.code==.None && socket.property!=nil {
            value,value_error:=unreal.property_value(socket.pkg,socket.property)
            if value_error.code==.None && value.kind==.Name {
                text:=unreal.name_plain(socket.pkg,value.name)
                if value.name.number>0 {
                    text=unreal.name_text(socket.pkg,value.name,d.allocator)
                    append(&d.texts,transmute([]u8)text)
                }
                if text!="None" {component.socket=text}
            }
        }
    }
    return {}
}

// The component of the same actor whose archetype is object of package q:
// an AttachParent kept by an archetype names the archetype of the parent.
@(private)
sibling_of_template :: proc(d:^Document,index:int,q:^unreal.Package,object:unreal.Object_Ref) -> int {
    actor:=d.actors[d.components[index].actor]
    for sibling in actor.first_component..<actor.first_component+actor.component_count {
        current:=d.components[sibling].ref
        for _ in 0..<OUTER_DEPTH {
            next,native,error:=template_of(d,current)
            if error.code!=.None || native {break}
            if library_package(d.library,int(next.pkg))==q && next.object==object {return sibling}
            current=next
        }
    }
    return -1
}

// The properties of an object, read once.
object_properties :: proc(d:^Document,ref:Ref) -> (held:^Object_Properties,error:unreal.Error) {
    if found,ok:=&d.properties[ref];ok {return found,found.error}
    p:=library_package(d.library,int(ref.pkg))
    if ref.object<=0 || int(ref.object)>len(p.exports) {return nil,{.Invalid_Reference,0,"level object"}}
    list,list_error:=unreal.export_properties(p,int(ref.object)-1,true,d.allocator)
    if list_error.code==.Out_Of_Memory {return nil,list_error}
    d.properties[ref]=Object_Properties{list=list,error=list_error}
    held=&d.properties[ref]
    return held,held.error
}

// The native data a class of actor saves after AActor's: AActor writes
// whether the save was cooked (and then the label) since
// SerializeActorLabelInCookedBuilds.
actor_native_payload :: proc(d:^Document,ref:Ref) -> (payload:unreal.Span,error:unreal.Error) {
    held:^Object_Properties
    held,error=object_properties(d,ref)
    if error.code!=.None {return}
    p:=library_package(d.library,int(ref.pkg))
    payload,error=unreal.object_native_payload(p,held.list.trailing)
    if error.code!=.None {return}
    if special,_:=unreal.custom_version(p,unreal.UE5_SPECIAL_PROJECT_VERSION);special>=ACTOR_LABEL_IN_COOKED {
        bytes,_:=unreal.span_bytes(p,payload)
        if len(bytes)<4 {return {},{.Truncated,payload.offset,"actor cooked flag"}}
        if bytes[0]|bytes[1]|bytes[2]|bytes[3]!=0 {return {},{.Cooked,payload.offset,"the actor was saved cooked"}}
        payload.offset+=4
        payload.size-=4
    }
    return
}

// A property of an object, from the object or else from its archetypes,
// which may live in other packages of the library.
property :: proc(d:^Document,ref:Ref,name:string) -> (found:Found,error:unreal.Error) {
    current:=ref
    for depth in 0..<OUTER_DEPTH {
        held,held_error:=object_properties(d,current)
        if held_error.code!=.None {return {},held_error}
        p:=library_package(d.library,int(current.pkg))
        if item:=unreal.property_find(p,&held.list,name);item!=nil {
            return {item,p,depth==0?.Authored:.Archetype,current},{}
        }
        next,native,next_error:=template_of(d,current)
        if next_error.code!=.None {return {},next_error}
        if native {return {nil,p,.Native,current},{}}
        current=next
    }
    return {},{.Limit,0,"archetype chain depth"}
}

// The archetype of an object. Saves record it as the template of the
// export; where they do not (UE4 keeps none for most subobjects) it is found
// as Unreal finds it: the object of the same name
// under the archetype of its outer, else the component template a Blueprint
// class keeps for it (SCS), else the default object of its class. native:
// the chain reaches a class of a script package, whose defaults live in no
// package. Found once per object.
template_of :: proc(d:^Document,ref:Ref) -> (next:Ref,native:bool,error:unreal.Error) {
    if known,ok:=d.templates[ref];ok {return known.next,known.native,known.error}
    next,native,error=archetype_of(d,ref,0)
    if error.code!=.Out_Of_Memory {d.templates[ref]=Template{next,native,error}}
    return
}

@(private)
archetype_of :: proc(d:^Document,ref:Ref,depth:int) -> (next:Ref,native:bool,error:unreal.Error) {
    if depth>OUTER_DEPTH {return {},false,{.Limit,0,"archetype outer depth"}}
    p:=library_package(d.library,int(ref.pkg))
    item:=p.exports[int(ref.object)-1]
    if p.summary.version_ue4>=UE4_TEMPLATE_INDEX && item.template!=0 {
        if item.template>0 {return {ref.pkg,item.template},false,{}}
        return import_target(d,p,item.template,false)
    }
    if item.object_flags&RF_INHERITABLE_COMPONENT_TEMPLATE!=0 && item.outer>0 {
        // The template a Blueprint keeps for a component it inherits and changes
        // (a record of its InheritableComponentHandler): the object of its name
        // under the nearest super class that has one; the override of a
        // DefaultSceneRoot is named apart.
        name:=strings.trim_prefix(unreal.name_plain(p,item.object_name),ICH_SCENE_ROOT_PREFIX)
        class:=Ref{ref.pkg,item.outer}
        for _ in 0..<OUTER_DEPTH {
            super,blueprint,super_error:=super_class(d,class)
            if super_error.code!=.None {return {},false,super_error}
            if !blueprint {break}
            if found,ok:=object_under(d,super,name);ok {return found,false,{}}
            class=super
        }
    } else if item.object_flags&RF_CLASS_DEFAULT_OBJECT!=0 {
        // A class default object: that of the super class.
        if item.class<=0 {return {},true,{}}
        super:=p.exports[int(item.class)-1].super
        if super>0 {
            cdo,cdo_error:=unreal.class_default_object(p,super)
            return {ref.pkg,cdo},false,cdo_error
        }
        if class_of(p,super).pkg=="" || strings.has_prefix(class_of(p,super).pkg,"/Script/") {return {},true,{}}
        return import_target(d,p,super,true)
    } else if item.outer>0 {
        outer:=Ref{ref.pkg,item.outer}
        search,search_native,search_error:=archetype_of(d,outer,depth+1)
        if search_error.code!=.None {return {},false,search_error}
        name:=unreal.name_plain(p,item.object_name)
        if !search_native {
            q:=library_package(d.library,int(search.pkg))
            for candidate,i in q.exports {
                if candidate.outer==search.object && candidate.object_name.number==item.object_name.number && unreal.name_plain(q,candidate.object_name)==name {
                    return {search.pkg,unreal.Object_Ref(i+1)},false,{}
                }
            }
        }
        if found,ok,find_error:=blueprint_template(d,outer,name);find_error.code!=.None {return {},false,find_error} else if ok {return found,false,{}}
    }
    if item.class>0 {
        cdo,cdo_error:=unreal.class_default_object(p,item.class)
        return {ref.pkg,cdo},false,cdo_error
    }
    class:=class_of(p,item.class)
    if strings.has_prefix(class.pkg,"/Script/") || class.pkg=="" {return {},true,{}}
    return import_target(d,p,item.class,true)
}

// The component template of the Blueprint class of outer for a component
// named name, as Unreal finds it, from the
// class up its Blueprint super classes: the ComponentTemplate of the SCS_Node
// of that variable; else, when the class has no such node, the template its
// InheritableComponentHandler keeps for that variable (an inherited component
// it changes, ComponentKey) or of that name; else an object of that name
// under the class.
@(private)
blueprint_template :: proc(d:^Document,outer:Ref,name:string) -> (template:Ref,found:bool,error:unreal.Error) {
    p:=library_package(d.library,int(outer.pkg))
    class_ref:=p.exports[int(outer.object)-1].class
    class:=class_of(p,class_ref)
    if class.pkg=="" || strings.has_prefix(class.pkg,"/Script/") {return}
    owner:Ref
    if class_ref>0 {
        owner={outer.pkg,class_ref}
    } else {
        owner,_,error=import_target(d,p,class_ref,false)
        if error.code!=.None {return}
    }
    for _ in 0..<OUTER_DEPTH {
        node:bool
        template,found,node=scs_template(d,owner,name)
        if found {return}
        if !node {
            if template,found=override_template(d,owner,name);found {return}
        }
        if template,found=object_under(d,owner,name);found {return}
        blueprint:bool
        owner,blueprint,error=super_class(d,owner)
        if error.code!=.None || !blueprint {return {},false,error}
    }
    return
}

// The ComponentTemplate of the SCS_Node of the variable name of class;
// node: the class has that node, with a template or without.
@(private)
scs_template :: proc(d:^Document,class:Ref,name:string) -> (template:Ref,found,node:bool) {
    q:=library_package(d.library,int(class.pkg))
    for candidate,i in q.exports {
        if candidate.outer<=0 || !export_is(q,unreal.Object_Ref(i+1),"/Script/Engine","SCS_Node") {continue}
        if q.exports[int(candidate.outer)-1].outer!=class.object {continue}
        held,held_error:=object_properties(d,{class.pkg,unreal.Object_Ref(i+1)})
        if held_error.code!=.None {continue}
        variable:=unreal.property_find(q,&held.list,"InternalVariableName")
        if variable==nil {continue}
        v,v_error:=unreal.property_value(q,variable)
        if v_error.code!=.None || v.kind!=.Name || unreal.name_plain(q,v.name)!=name {continue}
        component:=unreal.property_find(q,&held.list,"ComponentTemplate")
        if component==nil {return {},false,true}
        c,c_error:=unreal.property_value(q,component)
        if c_error.code!=.None || c.kind!=.Object || c.object<=0 {return {},false,true}
        return {class.pkg,c.object},true,true
    }
    return
}

// The template the InheritableComponentHandler of class keeps for an
// inherited component: the record whose key names the variable name, or
// whose template is named name.
@(private)
override_template :: proc(d:^Document,class:Ref,name:string) -> (template:Ref,found:bool) {
    q:=library_package(d.library,int(class.pkg))
    for candidate,i in q.exports {
        if candidate.outer!=class.object || !export_is(q,unreal.Object_Ref(i+1),"/Script/Engine","InheritableComponentHandler") {continue}
        held,held_error:=object_properties(d,{class.pkg,unreal.Object_Ref(i+1)})
        if held_error.code!=.None {return}
        records:=unreal.property_find(q,&held.list,"Records")
        if records==nil {return}
        view,view_error:=unreal.property_array(q,records)
        if view_error.code!=.None {return}
        items,items_error:=unreal.array_tagged_structs(q,view,true,context.temp_allocator)
        if items_error.code!=.None {return}
        for &record in items.items {
            object:unreal.Object_Ref
            if field:=unreal.property_find(q,&record,"ComponentTemplate");field!=nil {
                if v,v_error:=unreal.property_value(q,field);v_error.code==.None && v.kind==.Object {object=v.object}
            }
            if object<=0 {continue}
            variable:=""
            if field:=unreal.property_find(q,&record,"ComponentKey");field!=nil {
                key,key_error:=unreal.property_tagged_struct(q,field,true,context.temp_allocator)
                if key_error.code==.None {
                    if item:=unreal.property_find(q,&key,"SCSVariableName");item!=nil {
                        if v,v_error:=unreal.property_value(q,item);v_error.code==.None && v.kind==.Name {variable=unreal.name_plain(q,v.name)}
                    }
                }
            }
            if variable==name || unreal.name_plain(q,q.exports[int(object)-1].object_name)==name {return {class.pkg,object},true}
        }
        return
    }
    return
}

// The object named name (without a number) whose outer is class.
@(private)
object_under :: proc(d:^Document,class:Ref,name:string) -> (object:Ref,found:bool) {
    q:=library_package(d.library,int(class.pkg))
    for candidate,i in q.exports {
        if candidate.outer==class.object && candidate.object_name.number==0 && unreal.name_plain(q,candidate.object_name)==name {
            return {class.pkg,unreal.Object_Ref(i+1)},true
        }
    }
    return
}

// The super class of a class export, opened from its package; blueprint:
// it is a class of a Blueprint, not of a script package.
@(private)
super_class :: proc(d:^Document,class:Ref) -> (super:Ref,blueprint:bool,error:unreal.Error) {
    p:=library_package(d.library,int(class.pkg))
    ref:=p.exports[int(class.object)-1].super
    if ref>0 {return {class.pkg,ref},true,{}}
    if ref==0 {return}
    native:bool
    super,native,error=import_target(d,p,ref,false)
    return super,error.code==.None && !native,error
}

// The export an import of p names, opened from its package; with
// class_default, the default object of the class it names.
@(private)
import_target :: proc(d:^Document,p:^unreal.Package,ref:unreal.Object_Ref,class_default:bool) -> (next:Ref,native:bool,error:unreal.Error) {
    // A name of the chain with its number: objects of one name tell apart by it ("Sky_0", "Sky_1").
    Link :: struct {plain:string,number:i32}
    same :: proc(q:^unreal.Package,name:unreal.Name_Ref,link:Link) -> bool {return name.number==link.number && unreal.name_plain(q,name)==link.plain}
    chain:[OUTER_DEPTH]Link
    depth:=0
    current:=ref
    package_name:=""
    for current<0 {
        item:=p.imports[int(-i64(current)-1)]
        if item.outer==0 {package_name=unreal.name_text(p,item.object_name,context.temp_allocator);break}
        if depth>=len(chain) {return {},false,{.Limit,0,"archetype outer depth"}}
        chain[depth]={unreal.name_plain(p,item.object_name),item.object_name.number}
        depth+=1
        current=item.outer
    }
    if package_name=="" || depth==0 {return {},false,{.Invalid_Reference,0,"archetype import has no package"}}
    if strings.has_prefix(package_name,"/Script/") {return {},true,{}}
    if class_default {chain[0].plain=strings.concatenate({"Default__",chain[0].plain},context.temp_allocator)}
    index:int
    index,error=library_find(d.library,package_name)
    if error.code!=.None {return}
    q:=library_package(d.library,index)
    for candidate,i in q.exports {
        if !same(q,candidate.object_name,chain[0]) {continue}
        outer:=candidate.outer
        matched:=true
        for level in 1..<depth {
            if outer<=0 {matched=false;break}
            o:=q.exports[int(outer)-1]
            if !same(q,o.object_name,chain[level]) {matched=false;break}
            outer=o.outer
        }
        if matched && outer==0 {return {i32(index),unreal.Object_Ref(i+1)},false,{}}
    }
    return {},false,{.Invalid_Reference,0,"archetype is not in its package"}
}

// The class of a class reference of p.
class_of :: proc(p:^unreal.Package,class:unreal.Object_Ref) -> (c:Class) {
    if class>0 {
        return {p.source_package,unreal.name_plain(p,p.exports[int(class)-1].object_name)}
    }
    if class==0 || !unreal.reference_valid(p,class) {return}
    item:=p.imports[int(-i64(class)-1)]
    c.name=unreal.name_plain(p,item.object_name)
    outer:=item.outer
    for _ in 0..<OUTER_DEPTH {
        if outer>=0 {break}
        o:=p.imports[int(-i64(outer)-1)]
        if o.outer==0 {c.pkg=unreal.name_plain(p,o.object_name);break}
        outer=o.outer
    }
    return
}

class_is :: proc(c:Class,package_name,name:string) -> bool {return c.pkg==package_name && c.name==name}

@(private)
export_is :: proc(p:^unreal.Package,object:unreal.Object_Ref,package_name,class:string) -> bool {
    if object<=0 || int(object)>len(p.exports) {return false}
    return class_is(class_of(p,p.exports[int(object)-1].class),package_name,class)
}

// Typed reads of a property through the archetypes. found is false when
// nothing up to a native class has it: the value is then default, that of
// the C++ constructor.
bool_of :: proc(d:^Document,ref:Ref,name:string,default:bool) -> (value:bool,found:bool) {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return default,false}
    v,value_error:=unreal.property_value(f.pkg,f.property)
    if value_error.code!=.None || v.kind!=.Boolean {return default,false}
    return v.boolean,true
}

real_of :: proc(d:^Document,ref:Ref,name:string,default:f64) -> (value:f64,found:bool) {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return default,false}
    return value_real(f.pkg,f.property,default)
}

// The value of an enum property without its type: "Lumens" of "ELightUnits::Lumens".
enum_of :: proc(d:^Document,ref:Ref,name:string,default:string) -> (value:string,found:bool) {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return default,false}
    return value_enum(f.pkg,f.property,default)
}

// The string of a string or text property; "" for none.
string_of :: proc(d:^Document,ref:Ref,name:string,allocator:=context.temp_allocator) -> (value:string,found:bool) {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return "",false}
    v,value_error:=unreal.property_value(f.pkg,f.property,allocator)
    if value_error.code!=.None || v.kind!=.String {return "",false}
    return v.text,true
}

// The object path a reference property names, from the package it was found
// in; "" for null or none.
path_of :: proc(d:^Document,ref:Ref,name:string,allocator:=context.temp_allocator) -> string {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return ""}
    v,value_error:=unreal.property_value(f.pkg,f.property)
    if value_error.code!=.None || v.kind!=.Object || v.object==0 {return ""}
    path,path_error:=unreal.reference_path(f.pkg,v.object,allocator)
    if path_error.code!=.None {return ""}
    return path
}

value_real :: proc(p:^unreal.Package,property:^unreal.Property,default:f64) -> (value:f64,found:bool) {
    v,error:=unreal.property_value(p,property)
    if error.code!=.None {return default,false}
    #partial switch v.kind {
    case .Real:return v.real,true
    case .Signed:return f64(v.signed),true
    case .Unsigned:return f64(v.unsigned),true
    }
    return default,false
}

value_enum :: proc(p:^unreal.Package,property:^unreal.Property,default:string) -> (value:string,found:bool) {
    v,error:=unreal.property_value(p,property)
    if error.code!=.None || v.kind!=.Name {return default,false}
    text:=unreal.name_plain(p,v.name)
    if at:=strings.last_index(text,"::");at>=0 {text=text[at+2:]}
    return text,true
}

// An object reference of the property, as a reference of the package of the object
// when it is authored; zero for null, for one found on an archetype or for none.
reference_property :: proc(d:^Document,ref:Ref,name:string) -> (object:unreal.Object_Ref,error:unreal.Error) {
    f:Found
    f,error=property(d,ref,name)
    if error.code!=.None || f.property==nil || f.origin!=.Authored {return}
    v:unreal.Value
    v,error=unreal.property_value(f.pkg,f.property)
    if error.code!=.None {return}
    if v.kind!=.Object {return 0,{.Unsupported_Value,f.property.data.offset,"expected an object property"}}
    return v.object,{}
}

// The object path of a reference of the package of ref ("" for null).
object_path :: proc(d:^Document,ref:Ref,object:unreal.Object_Ref,allocator:=context.allocator) -> (path:string,error:unreal.Error) {
    return unreal.reference_path(library_package(d.library,int(ref.pkg)),object,allocator)
}

// The export an object reference of the package of ref names: in that
// package, or opened from its own through the library. native: an object of
// a script package, which no package holds.
resolve :: proc(d:^Document,ref:Ref,object:unreal.Object_Ref) -> (target:Ref,native:bool,error:unreal.Error) {
    if object>0 {return {ref.pkg,object},false,{}}
    if object==0 {return {},false,{.Invalid_Reference,0,"null object reference"}}
    return import_target(d,library_package(d.library,int(ref.pkg)),object,false)
}

// The object paths of an array of references, by index; "" for a null one.
paths_of :: proc(d:^Document,ref:Ref,name:string,allocator:=context.temp_allocator) -> []string {
    f,error:=property(d,ref,name)
    if error.code!=.None || f.property==nil {return nil}
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None {return nil}
    refs,refs_error:=unreal.array_object_refs(f.pkg,view,context.temp_allocator)
    if refs_error.code!=.None {return nil}
    out:=make([]string,len(refs),allocator)
    for object,i in refs {
        if object==0 {continue}
        out[i],_=unreal.reference_path(f.pkg,object,allocator)
    }
    return out
}

// How a primitive component collides, from its BodyInstance: its collision
// profile, what it enables when the profile is Custom ("" when it does not
// say) and whether it simulates. StaticMeshComponent's defaults:
// BlockAllDynamic, queries and physics, not simulated.
component_collision :: proc(d:^Document,ref:Ref) -> (profile,enabled:string,simulate:bool) {
    profile="BlockAllDynamic"
    f,error:=property(d,ref,"BodyInstance")
    if error.code!=.None || f.property==nil {return}
    list,list_error:=unreal.property_tagged_struct(f.pkg,f.property,true,context.temp_allocator)
    if list_error.code!=.None {return}
    if item:=unreal.property_find(f.pkg,&list,"CollisionProfileName");item!=nil {
        if v,v_error:=unreal.property_value(f.pkg,item);v_error.code==.None && v.kind==.Name {profile=unreal.name_plain(f.pkg,v.name)}
    }
    if item:=unreal.property_find(f.pkg,&list,"CollisionEnabled");item!=nil {enabled,_=value_enum(f.pkg,item,"")}
    if item:=unreal.property_find(f.pkg,&list,"bSimulatePhysics");item!=nil {simulate=item.bool_value}
    return
}

// Whether a component collides: by its collision profile, or by what it enables when its profile is Custom.
profile_collides :: proc(profile,enabled:string) -> bool {
    if enabled=="NoCollision" {return false}
    switch {
    case profile=="NoCollision": return false
    case strings.has_prefix(profile,"Overlap"),profile=="Trigger",profile=="UI": return false
    }
    return true
}
