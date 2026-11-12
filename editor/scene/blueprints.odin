package unreal_scene

import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import unreal "project:plugins/unreal/editor/package"
import "mirai:core"
import "mirai:std/base"

// The actors of a Blueprint class as instances of one prefab: the entities
// its first actor gives, its root at the origin, which every actor of the
// class follows except in what it shows apart (the meshes its construction
// script chose, its own transforms), which it holds as overrides.

@(private)
blueprints_prefab :: proc(c:^Context) {
    d:=c.d
    classes:=make(map[string][dynamic]int,context.temp_allocator)
    order:=make([dynamic]string,context.temp_allocator)
    for actor,a in d.actors {
        if c.actor_entities[a]==0 || strings.has_prefix(actor.class.pkg,"/Script/") {continue}
        key:=fmt.tprintf("%s.%s",actor.class.pkg,actor.class.name)
        if !(key in classes) {
            classes[key]=make([dynamic]int,context.temp_allocator)
            append(&order,key)
        }
        append(&classes[key],a)
    }
    // Adopting instances leaves the hierarchy of each scene as it is.
    children:=make(map[int]Children,context.temp_allocator)
    previous:=c.section
    defer section_use(c,previous)
    for key,index in order {
        if !blueprint_prefab(c,key,classes[key][:],index,&children) {return}
    }
}

// The hierarchy of the scene of a section, read once.
@(private)
section_children :: proc(c:^Context,children:^map[int]Children,s:int) -> ^Children {
    if !(s in children) {children[s]=children_of(&c.sections[s].scene)}
    return &children[s]
}

// The prefab of a class from its first actor, and every actor an instance
// of it in the scene of its section.
@(private)
blueprint_prefab :: proc(c:^Context,class:string,actors:[]int,index:int,children:^map[int]Children) -> bool {
    first_section:=c.actor_sections[actors[0]]
    scene:=&c.sections[first_section].scene
    name:=unreal.asset_name(strings.trim_suffix(class[strings.last_index_byte(class,'.')+1:],"_C"))
    first:=c.actor_entities[actors[0]]
    id,path,info:=asset_place(c,asset.KIND_SCENE,name,index,".scene")
    prefab:asset.Scene
    if error:=asset.scene_init(&prefab,c.types,id,context.temp_allocator);error!=.None {return fail_write(c,"the prefab of %s (%v creating it)",name,error)}
    defer asset.scene_destroy(&prefab)
    remap:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    for e,place in subtree_places(scene,section_children(c,children,first_section),first) {remap[e]=base.Entity_Id(base.name_hash(fmt.tprintf("%s|%s",class,place)))}
    if error:=asset.scene_copy(&prefab,scene,&remap);error!=.None {return fail_write(c,"the prefab of %s (%v copying its entities)",name,error)}
    root:=remap[first]
    if error:=asset.scene_entity_rename(&prefab,root,name);error!=.None {return fail_write(c,"the prefab of %s (%v naming its root)",name,error)}
    if placed,has:=asset.scene_get(&prefab,root,"Transform",core.Transform);has {
        placed.position,placed.rotation=0,1
        asset.scene_set(&prefab,root,"Transform",&placed)
    }
    if error:=asset.import_put(&prefab.doc,c.types,&info);error!=.None {return fail_write(c,"the prefab of %s (%v recording its import)",name,error)}
    bytes,error:=asset.scene_bytes(&prefab,context.temp_allocator)
    if error!=.None {return fail_write(c,"the prefab of %s (%v encoding it)",name,error)}
    if !asset_write(c,id,asset.KIND_SCENE,name,path,bytes,fmt.tprintf("%d instances",len(actors))) {return true}
    sources:=make(map[string]base.Entity_Id,context.temp_allocator)
    prefab_children:=children_of(&prefab)
    for e,place in subtree_places(&prefab,&prefab_children,root) {sources[place]=e}
    for a in actors {
        s:=c.actor_sections[a]
        section_use(c,s)
        members:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
        matched:=true
        places:=subtree_places(c.scene,section_children(c,children,s),c.actor_entities[a])
        for e,place in places {
            source,found:=sources[place]
            if !found {matched=false;break}
            members[source]=e
        }
        if matched && len(places)==len(sources) {
            if _,adopt_error:=asset.scene_instance_adopt(c.scene,&prefab,id,&members);adopt_error==.None {continue}
        }
        warn(c,"%s: its components are not those of the first %s; it stays apart from the prefab",c.d.actors[a].label,name)
    }
    return true
}

// The rows of the children of each entity of a scene.
@(private)
Children :: map[base.Entity_Id][dynamic]int

@(private)
children_of :: proc(scene:^asset.Scene) -> (children:Children) {
    children=make(Children,context.temp_allocator)
    for row in 0..<asset.scene_entity_count(scene) {
        parent:=asset.scene_entity(scene,row).parent
        if !(parent in children) {children[parent]=make([dynamic]int,context.temp_allocator)}
        append(&children[parent],row)
    }
    return
}

// The entities of the subtree of root, each by the names of the path to it
// from root: "" for root. Siblings that share a name are told apart by their
// turn among them in the order of their parent: "Wall", "Wall#1", ...
@(private)
subtree_places :: proc(scene:^asset.Scene,children:^Children,root:base.Entity_Id) -> map[base.Entity_Id]string {
    places:=make(map[base.Entity_Id]string,context.temp_allocator)
    places[root]=""
    pending:=make([dynamic]base.Entity_Id,context.temp_allocator)
    append(&pending,root)
    seen:=make(map[string]int,context.temp_allocator)
    for len(pending)>0 {
        e:=pop(&pending)
        rows:=children[e] // a local: ranging over the map index of a missing key faults (PENDIENTES_ODIN)
        siblings:=make([dynamic][2]int,0,len(rows),context.temp_allocator)
        for row in rows {append(&siblings,[2]int{int(asset.scene_entity(scene,row).order),row})}
        slice.sort_by(siblings[:],proc(a,b:[2]int) -> bool {return a[0]<b[0] || a[0]==b[0] && a[1]<b[1]})
        clear(&seen)
        for sibling in siblings {
            record:=asset.scene_entity(scene,sibling[1])
            if record.id in places {continue}
            name:=record.name
            if turn:=seen[name];turn>0 {name=fmt.tprintf("%s#%d",record.name,turn)}
            seen[record.name]+=1
            places[record.id]=places[e]==""?name:fmt.tprintf("%s/%s",places[e],name)
            append(&pending,record.id)
        }
    }
    return places
}
