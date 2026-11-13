package unreal_foliage_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import ufoliage "project:plugins/unreal/editor/foliage"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"

// The foliage of an Unreal level as a .foliage source for each scene the
// level is written to: a type for each foliage type of its
// InstancedFoliageActors, and for each mesh, materials and settings of the
// instanced static mesh components its actors show (those PCG and packed
// level actors bake too); each instance a manual one of the cell it falls
// in, in the space of an entity at the origin of the scene. Nothing is
// generated: Unreal's instances are the ones its artist or its graphs placed.
//
// - A Mirai instance has one scale across: one with different X and Y
//   scales takes their geometric mean (the same area).
// - An instance placed on something is INSTANCE_GROUNDED with its height
//   over that point as `ground`.
// - Unreal moves foliage with its materials, not its types: wind is 0.
// - Unreal fades an instance between its start and end cull distances only
//   in a material that reads PerInstanceFadeAmount: it draws whole up to the
//   end and is gone there, so the fade starts at the cull distance.
// - Collision is a box of the size of the mesh's bounds, standing on the instance.

Foliage_Options :: struct {
    meshes:[]base.Asset_Id, // the .mesh of each foliage type, in its order; zero for none
}

Foliage_Source :: struct {
    transform:mm.Transform, // of the entity that shows the source
    types:[]u32,            // the id of the source's type of each foliage type
    averaged:int,           // instances whose X and Y scales differed
    dropped:int,            // instances with a zero, negative or too large scale
    unplaced:int,           // instances of a type of actors whose actor the level does not keep
}

// Writes the source of the foliage into dst; false when it does not validate
// (source_valid) or memory runs out, dst unchanged.
foliage_source :: proc(dst:^foliage.Source,f:^ufoliage.Foliage,options:Foliage_Options,allocator:=context.allocator) -> (result:Foliage_Source,ok:bool) {
    context.allocator=allocator
    s:foliage.Source
    defer if !ok {foliage.source_destroy(&s);delete(result.types)}
    result,ok=foliage_add(&s,f,options,{})
    if !ok || !foliage.source_valid(&s) {ok=false;return}
    foliage.source_destroy(dst)
    dst^=s
    return result,true
}

// Adds the static mesh types of the foliage and their instances to s, its
// instances where they are from origin; false past TYPES_MAX. The actors a
// type of actors places are actors of the level, and the instanced
// components that draw a type of ISM actors (f.components) are instanced
// components of its actor: neither is a type here.
foliage_add :: proc(s:^foliage.Source,f:^ufoliage.Foliage,options:Foliage_Options,origin:[3]f32) -> (result:Foliage_Source,ok:bool) {
    result.transform=mm.TRANSFORM_IDENTITY
    meshes:=0
    for ut in f.types {if ut.kind==.Static_Mesh {meshes+=1}}
    if len(s.types)+meshes>foliage.TYPES_MAX {return}
    result.types=make([]u32,len(f.types))
    for ut,i in f.types {
        if ut.kind!=.Static_Mesh {continue}
        mesh:=i<len(options.meshes)?options.meshes[i]:base.Asset_Id{}
        t:=foliage.source_type_add(s,unreal.asset_name(ut.name),mesh)
        result.types[i]=t.id
        type_from(t,ut)
    }
    for instance in f.instances {
        if f.types[instance.type].kind!=.Static_Mesh {
            if f.types[instance.type].kind==.Actor && instance.actor<0 {result.unplaced+=1}
            continue
        }
        placed:=instance.transform
        placed.position-=origin
        if !instance_add(s,result.types[instance.type],placed,instance.based?foliage.INSTANCE_GROUNDED:0,instance.ground,&result) {continue}
    }
    return result,true
}

// A manual instance of type at placed: false, and dropped, when its scale is
// zero, negative or past what a source holds.
@(private)
instance_add :: proc(s:^foliage.Source,type:u32,placed:mm.Transform,flags:u32,ground:f32,result:^Foliage_Source) -> bool {
    x:=placed.scale
    across:=x.x==x.z?x.x:math.sqrt(abs(x.x*x.z))
    if !(x.x>0) || !(x.z>0) || !(x.y>0) || across>1000 || x.y>1000 {result.dropped+=1;return false}
    if x.x!=x.z {result.averaged+=1}
    foliage.source_instance_add(s,type,placed.position,u32(mm.quat_pack(placed.rotation)),{across,x.y},flags,ground)
    return true
}

@(private)
type_from :: proc(t:^foliage.Foliage_Type,ut:ufoliage.Foliage_Type) {
    t.density=clamp(ut.density,0,1000)
    across:=ut.scale[0]
    height:=[2]f32{1,1}
    if ut.scaling!=.Uniform {
        // Along Z, times the scale across.
        z:=ut.scale[2]
        height={max(z[0],1e-3)/max(across[1],1e-3),max(z[1],1e-3)/max(across[0],1e-3)}
    }
    t.scale={clamp(across[0],1e-3,1000),clamp(max(across[1],across[0]),1e-3,1000)}
    t.height={clamp(height[0],1e-3,1000),clamp(max(height[1],height[0]),1e-3,1000)}
    t.yaw=ut.random_yaw?2*math.PI:0
    t.tilt=ut.random_pitch
    t.align=ut.align_to_normal?1:0
    t.fade_distance,t.cull_distance=0,0
    if ut.cull[1]>0 {t.fade_distance,t.cull_distance=ut.cull[1],ut.cull[1]}
    t.wind=0
    t.casts_shadow=ut.casts_shadow
    t.ray_visible=ut.ray_visible
    t.collision=.None
    t.size={}
    if ut.collides && ut.has_bounds {
        t.collision=.Box
        t.size=ut.bounds[1]*2
    }
    t.preset=0
}

// What makes the instances of an instanced component one type of foliage:
// what it shows and how, as the component says it.
Instanced_Type :: struct {
    name:string,
    mesh:base.Asset_Id,
    materials:[render.MATERIAL_SLOTS]base.Asset_Id, // those its slots override; none: the mesh's
    cull_distance:f32, // metres; 0 never culled
    casts_shadow,ray_visible:bool,
    size:[3]f32,       // of the box of its mesh, when it collides; zero for none
}

// The instances of instanced components with their types: those of a type
// share it, one type for each different Instanced_Type, past which (TYPES_MAX
// in all) they are dropped.
Instanced_Batch :: struct {
    type:Instanced_Type,
    instances:[]mm.Transform, // in the space of the scene
}

// Adds the batches to s as types and manual instances where they are from
// origin; the types of equal batches are one.
instanced_add :: proc(s:^foliage.Source,batches:[]Instanced_Batch,origin:[3]f32,result:^Foliage_Source) {
    ids:=make(map[Instanced_Type]u32,context.temp_allocator)
    for b in batches {
        key:=b.type
        key.name=""
        id,seen:=ids[key]
        if !seen {
            if len(s.types)>=foliage.TYPES_MAX {result.dropped+=len(b.instances);continue}
            t:=foliage.source_type_add(s,b.type.name,b.type.mesh)
            t.materials=b.type.materials
            t.density=0
            t.scale,t.height={1,1},{1,1}
            t.yaw,t.tilt,t.align,t.wind=0,0,0,0
            t.fade_distance,t.cull_distance=b.type.cull_distance,b.type.cull_distance
            t.casts_shadow,t.ray_visible=b.type.casts_shadow,b.type.ray_visible
            t.collision=b.type.size=={}?foliage.Foliage_Collision.None:foliage.Foliage_Collision.Box
            t.size=b.type.size
            t.preset=0
            id=t.id
            ids[key]=id
        }
        for placed in b.instances {
            at:=placed
            at.position-=origin
            instance_add(s,id,at,0,0,result)
        }
    }
}

KEEP_DISTANCE :: f32(0.1)          // metres an instance moved and still keeps its id
KEEP_TURN :: f32(2*math.PI/180)    // radians it turned and still keeps it
KEEP_SCALE :: f32(0.02)            // of its scale, that it changed and still keeps it

// Gives s, the source of an import, the ids previous (the source of the import
// it replaces) gave the same types and instances, so that what a saved game
// took out of them stays out: a type takes the id of an equal one, else of
// one with its name, mesh, prefab and materials; a manual instance, that of
// the nearest one of its type in its cell within KEEP_DISTANCE, KEEP_TURN and
// KEEP_SCALE, each once. The rest take ids previous never gave. False, and s
// unchanged, when the ids run out.
foliage_ids_keep :: proc(s:^foliage.Source,previous:^foliage.Source) -> bool {
    manual,widest:=0,0
    for cell in s.cells {manual+=len(cell.manual)}
    for cell in previous.cells {widest=max(widest,len(cell.manual))}
    if u64(previous.info.next_type)+u64(len(s.types))>u64(max(u32)) || u64(previous.info.instances)+u64(manual)>u64(max(u32)) {return false}

    remap:=make(map[u32]u32,len(s.types),context.temp_allocator)
    taken:=make([]bool,len(previous.types),context.temp_allocator)
    for pass in 0..<2 {
        for t in s.types {
            if t.id in remap {continue}
            for p,j in previous.types {
                if taken[j] {continue}
                alike:=t
                alike.id=p.id
                if pass==1 {
                    alike=p
                    alike.name,alike.mesh,alike.prefab,alike.materials=t.name,t.mesh,t.prefab,t.materials
                }
                if alike!=p {continue}
                remap[t.id]=p.id
                taken[j]=true
                break
            }
        }
    }
    next:=previous.info.next_type
    for &t in s.types {
        if kept,ok:=remap[t.id];ok {t.id=kept;continue}
        remap[t.id]=next
        t.id=next
        next+=1
    }
    s.info.next_type=next

    // The instances of a cell before, by type and then x: those within reach
    // of an instance are a range.
    Before :: struct {type:u32,x:f32,index:int,used:bool}
    order:=make([]Before,widest,context.temp_allocator)
    fresh:=previous.info.instances
    for &cell in s.cells {
        before:=foliage.source_cell(previous,cell.coord)
        count:=before!=nil?len(before.manual):0
        for k in 0..<count {order[k]={type=before.manual[k].type,x=before.manual[k].position.x,index=k}}
        slice.sort_by(order[:count],proc(a,b:Before) -> bool {return a.type<b.type || a.type==b.type && a.x<b.x})
        for &b in cell.manual {
            b.type=remap[b.type]
            low,high:=0,count
            for low<high {
                mid:=(low+high)/2
                if order[mid].type<b.type || order[mid].type==b.type && order[mid].x<b.position.x-KEEP_DISTANCE {low=mid+1} else {high=mid}
            }
            best,nearest:=-1,KEEP_DISTANCE
            turn:=mm.quat_unpack(u64(b.rotation))
            for k in low..<count {
                if order[k].type!=b.type || order[k].x>b.position.x+KEEP_DISTANCE {break}
                if order[k].used {continue}
                p:=before.manual[order[k].index]
                d:=linalg.length(p.position-b.position)
                if d>nearest {continue}
                if abs(p.scale[0]-b.scale[0])>KEEP_SCALE*b.scale[0] || abs(p.scale[1]-b.scale[1])>KEEP_SCALE*b.scale[1] {continue}
                if mm.quat_angle(mm.quat_unpack(u64(p.rotation)),turn)>KEEP_TURN {continue}
                best,nearest=k,d
            }
            if best>=0 {
                order[best].used=true
                b.id=before.manual[order[best].index].id
            } else {
                fresh+=1
                b.id=fresh
            }
        }
        for &o in cell.overrides {
            o.type=remap[o.type]
            if o.kind==.Replaced {o.instance.type=remap[o.instance.type]}
        }
        slice.sort_by(cell.overrides[:],proc(a,b:foliage.Foliage_Override) -> bool {return a.type<b.type || a.type==b.type && a.point<b.point})
    }
    s.info.instances=fresh
    return true
}

// The foliage of an Unreal level imported by the editor: for each scene, its
// InstancedFoliageActors and the instanced components of its actors, and for
// the scene of the map the grass of the landscapes, are a .foliage in
// levels/<map>/, named after the cell of the scene ("Foliage" for the scene
// of the map), shown by an entity at the origin of the scene, its types with
// the meshes and materials the level imports.
@(storage)
Foliage_Unreal :: struct {provider:unreal_scene.Translator_Provider}

foliage_unreal_default :: proc() -> (f:Foliage_Unreal) {
    f.provider.count=1
    f.provider.translators[0]={classes={0="InstancedFoliageActor"},translate=foliages_translate,instanced=true,map_scene=true}
    return
}

foliages_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"foliage.translate")
    origin,section:=unreal_scene.section_origin(c)
    s:foliage.Source
    defer foliage.source_destroy(&s)
    result:Foliage_Source
    translated,instances:=0,0
    if len(actors)>0 {
        read_zone:=unreal_scene.zone_begin(c,"foliage.read")
        list,error:=ufoliage.foliage_read(c.d,context.temp_allocator,actors)
        unreal_scene.zone_end(read_zone)
        if error.code!=.None {
            unreal_scene.warn(c,"the foliage could not be read (%v at 0x%x: %s); it is left out",error.code,error.offset,error.field)
        } else {
            defer ufoliage.foliages_destroy(&list)
            for &f in list {
                if !slice.contains(actors,f.actor) {continue}
                meshes:=make([]base.Asset_Id,len(f.types),context.temp_allocator)
                meshes_zone:=unreal_scene.zone_begin(c,"foliage.meshes")
                for t,i in f.types {
                    if t.mesh=="" {continue}
                    if m,ok:=unreal_scene.mesh_import(c,t.mesh);ok {meshes[i]=m.id}
                }
                unreal_scene.zone_end(meshes_zone)
                add_zone:=unreal_scene.zone_begin(c,"foliage.add")
                added,ok:=foliage_add(&s,&f,{meshes=meshes},origin)
                unreal_scene.zone_end(add_zone)
                if !ok {
                    unreal_scene.warn(c,"%s: its %d types do not fit in a .foliage; it is left out",c.d.actors[f.actor].label,len(f.types))
                    continue
                }
                delete(added.types)
                result.averaged+=added.averaged
                result.dropped+=added.dropped
                result.unplaced+=added.unplaced
                for t in f.types {if t.kind==.Static_Mesh {instances+=t.instance_count}}
                instances-=added.dropped
                // Its types of ISM actors show as the instanced components that draw them.
                for k in f.components {append(&c.instanced,unreal_scene.Instanced{f.actor,k})}
                translated+=1
            }
        }
    }
    if len(c.instanced)>0 {
        batches_zone:=unreal_scene.zone_begin(c,"foliage.instanced")
        batches:=instanced_batches(c)
        unreal_scene.zone_end(batches_zone)
        add_zone:=unreal_scene.zone_begin(c,"foliage.add")
        instanced_add(&s,batches,origin,&result)
        unreal_scene.zone_end(add_zone)
        for b in batches {instances+=len(b.instances)}
    }
    grass:Grass_Result
    if c.section==0 {
        grass_zone:=unreal_scene.zone_begin(c,"foliage.grass")
        grass=grass_translate(c,&s,origin)
        unreal_scene.zone_end(grass_zone)
    }
    unreal_scene.tally(c,"instances of foliage scaled differently along X and Y take the mean of both",result.averaged)
    unreal_scene.tally(c,"instances of foliage with a zero, negative or too large scale, or past the types a .foliage holds, are left out",result.dropped)
    unreal_scene.tally(c,"instances of foliage of actors have no actor in the level, which the editor of Unreal places again, and are left out",result.unplaced)
    if len(s.types)==0 {return translated}
    name:=section!=""?section:"Foliage"
    unreal_scene.zone(c,"foliage.write")
    if !foliage.source_valid(&s) {
        unreal_scene.warn(c,"%s: %d types and %d instances do not make a valid .foliage; it is left out",name,len(s.types),instances)
        return translated
    }
    id,path,info:=unreal_scene.asset_place(c,foliage.FOLIAGE_KIND,name,0,foliage.FOLIAGE_EXTENSION)
    previous_keep(c,&s,name,path)
    bytes,bytes_error:=foliage.source_bytes(&s,id,c.types,context.allocator,&info)
    if bytes_error!=.None {
        unreal_scene.warn(c,"%s: its foliage could not be written (%v)",name,bytes_error)
        return translated
    }
    defer delete(bytes)
    detail:=fmt.tprintf("%d types, %d instances, %d cells of grass",len(s.types),instances-result.dropped,grass.cells)
    if !unreal_scene.asset_write(c,id,foliage.FOLIAGE_KIND,name,path,bytes,detail) {return translated}
    e,made:=unreal_scene.entity_make(c,0,fmt.tprintf("%s|foliage",name),"Foliage",{origin,1,{1,1,1}})
    if !made {return translated}
    shown:=foliage.Foliage{source=id}
    unreal_scene.component_set(c,e,"Foliage",&shown)
    return translated
}

// The ids of the .foliage at path, which this import replaces, for the same
// types and instances of s (foliage_ids_keep).
@(private)
previous_keep :: proc(c:^unreal_scene.Context,s:^foliage.Source,name,path:string) {
    file:asset.Asset
    #partial switch asset.asset_load(&file,path) {
    case .None:
    case .Not_Found: return
    case:
        unreal_scene.warn(c,"%s: the .foliage it replaces could not be read; its instances take new ids, and saved games may take out others",name)
        return
    }
    defer asset.asset_close(&file)
    previous:foliage.Source
    defer foliage.source_destroy(&previous)
    if _,ok:=foliage.source_read(&previous,&file,c.types);!ok || !foliage_ids_keep(s,&previous) {
        unreal_scene.warn(c,"%s: the .foliage it replaces is not valid or holds no more ids; its instances take new ids, and saved games may take out others",name)
    }
}

// The batches of the instanced components of the scene (c.instanced): each
// its mesh and the materials its slots override, the cull distances of its
// instances, its shadows and rays, and the box of its mesh when it collides;
// its instances where they are in the world. A material the level keeps
// inside an actor is written now, since no entity takes it at the end of the
// level, and the instances of each set of custom data (PerInstanceSMCustomData)
// are a batch that shows the variants of the materials that read it.
@(private)
instanced_batches :: proc(c:^unreal_scene.Context) -> []Instanced_Batch {
    d:=c.d
    batches:=make([dynamic]Instanced_Batch,context.temp_allocator)
    boxes:=make(map[string]level.Mesh_Box,context.temp_allocator)
    unread,held:=0,0
    for item in c.instanced {
        a,k:=item.actor,item.component
        ref:=d.components[k].ref
        clear(&c.held)
        renderer_zone:=unreal_scene.zone_begin(c,"foliage.renderer")
        shown,ok:=unreal_scene.mesh_renderer(c,a,k,false)
        unreal_scene.zone_end(renderer_zone)
        if !ok {unread+=1;continue}
        missing:=false
        for h in c.held {
            if id,found:=unreal_scene.instanced_material(c,h.path,nil);found {shown.materials[h.row]=id} else {missing=true}
        }
        if missing {held+=1}
        instances_zone:=unreal_scene.zone_begin(c,"foliage.instances")
        world,world_error:=level.component_world(d,k)
        instances,instances_error:=level.component_instances(d,k,context.temp_allocator)
        unreal_scene.zone_end(instances_zone)
        if world_error.code!=.None || instances_error.code!=.None {unread+=1;continue}
        if len(instances.matrices)==0 {continue}
        path:=level.path_of(d,ref,"StaticMesh")
        _,object:=unreal_scene.object_split(path)
        t:=Instanced_Type{name=unreal.asset_name(object),mesh=shown.mesh,materials=shown.materials}
        end,_:=level.real_of(d,ref,"InstanceEndCullDistance",0)
        if end>0 {t.cull_distance=f32(end)/100}
        t.casts_shadow,_=level.bool_of(d,ref,"CastShadow",true)
        t.ray_visible,_=level.bool_of(d,ref,"bVisibleInRayTracing",true)
        if profile,enabled,_:=level.component_collision(d,ref);level.profile_collides(profile,enabled) {
            if box:=level.mesh_box(d,path,&boxes);box.ok {t.size=mm.aabb_size(box.box)}
        }
        place_zone:=unreal_scene.zone_begin(c,"foliage.place")
        defer unreal_scene.zone_end(place_zone)
        paths:=instances.per_instance>0?unreal_scene.slot_material_paths(c,k):nil
        types:=make([dynamic]Instanced_Type,context.temp_allocator)
        placed:=make([dynamic][dynamic]mm.Transform,context.temp_allocator)
        sets:=make(map[u64]int,context.temp_allocator) // the batch of each set of custom data
        for m,i in instances.matrices {
            local,local_error:=level.matrix_to_mirai(m)
            if local_error.code!=.None {unread+=1;continue}
            custom:=level.instance_custom(instances,i)
            key:=u64(0)
            for value in custom {key=base.hash_combine(key,u64(transmute(u32)value))}
            at,seen:=sets[key]
            if !seen {
                variant:=t
                for material_path,row in paths {
                    if id,found:=unreal_scene.instanced_material(c,material_path,custom);found {variant.materials[row]=id}
                }
                at=len(types)
                sets[key]=at
                append(&types,variant)
                append(&placed,make([dynamic]mm.Transform,context.temp_allocator))
            }
            append(&placed[at],mm.transform_compose(world,local))
        }
        for variant,i in types {append(&batches,Instanced_Batch{type=variant,instances=placed[i][:]})}
    }
    unreal_scene.tally(c,"instanced components or instances could not be read and are left out",unread)
    unreal_scene.tally(c,"instanced components name a material the level keeps inside an actor that could not be written: their foliage shows the material of the mesh",held)
    return batches[:]
}
