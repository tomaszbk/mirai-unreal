package unreal_foliage_editor

import "core:fmt"
import "core:slice"
import ufoliage "project:plugins/unreal/editor/foliage"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"
import physics "plugins:physics/runtime"

// The foliage of an Unreal level imported by the editor:
// - Placed instances from InstancedFoliageActors (static mesh types) and
//   instanced static mesh components (ISM, HISM, FISM, including those baked
//   by PCG and packed level actors) become entities under a Foliage group at
//   the origin of each scene, preserving exact 3D transforms, slot material
//   overrides, custom-data variants, Foliage_Sway wind/flutter, and box
//   colliders when colliding.
// - Landscape grass in the map's scene becomes a procedural .pcg asset with
//   Pcg_Graph, Volume, and Foliage (grass.odin), using GPU Micro scattering
//   for non-shadowing grass and CPU Meso batches for shadowing grass.
// - A StaticMeshComponent whose materials sway in the wind stays its entity
//   and gets a Foliage_Sway (mesh_sway).

Foliage_Options :: struct {
    meshes:[]base.Asset_Id, // the .mesh of each foliage type, in its order; zero for none
    winds:[]Mesh_Wind,      // the wind and flutter of each foliage type (mesh_wind), in its order; none: still
}

// One placed instance of an InstancedFoliageActor or instanced component.
Placed_Instance :: struct {
    name:string,
    mesh:base.Asset_Id,
    materials:[render.MATERIAL_SLOTS]base.Asset_Id, // those its slots override; none: the mesh's
    transform:mm.Transform, // in the space of the scene (relative to origin)
    wind,flutter:f32,
    casts_shadow:bool,
    collides:bool,
    box_center,box_half:[3]f32, // of the mesh bounds, when collides
}

Foliage_Result :: struct {
    placed:[dynamic]Placed_Instance,
    dropped:int,  // instances with a zero, negative, non-finite or too large scale
    unplaced:int, // instances of a type of actors whose actor the level does not keep
}

foliage_result_destroy :: proc(r:^Foliage_Result) {
    delete(r.placed)
    r^={}
}

// Collects the placed static-mesh instances of an InstancedFoliageActor,
// relative to origin. Actor and ISM_Actor types are not collected here:
// their actors belong to the level and their ISM components to c.instanced.
foliage_collect :: proc(out:^Foliage_Result,f:^ufoliage.Foliage,options:Foliage_Options,origin:[3]f32) {
    for instance in f.instances {
        ut:=f.types[instance.type]
        if ut.kind!=.Static_Mesh {
            if ut.kind==.Actor && instance.actor<0 {out.unplaced+=1}
            continue
        }
        placed:=instance.transform
        placed.position-=origin
        if !scale_valid(placed.scale) {out.dropped+=1;continue}
        mesh:=instance.type<len(options.meshes)?options.meshes[instance.type]:base.Asset_Id{}
        sway:=instance.type<len(options.winds)?options.winds[instance.type]:Mesh_Wind{}
        box_center,box_half:=ut.bounds[0],ut.bounds[1]
        collides:=ut.collides && ut.has_bounds && box_half!={}
        append(&out.placed,Placed_Instance{
            name=unreal.asset_name(ut.name),
            mesh=mesh,
            transform=placed,
            wind=sway.wind,
            flutter=sway.flutter,
            casts_shadow=ut.casts_shadow,
            collides=collides,
            box_center=box_center,
            box_half=box_half,
        })
    }
}

@(private)
scale_valid :: proc "contextless" (s:[3]f32) -> bool {
    return s.x>0 && s.y>0 && s.z>0 && s.x<=1000 && s.y<=1000 && s.z<=1000
}

// What makes the instances of an instanced component one batch: what it shows
// and how, as the component says it.
Instanced_Type :: struct {
    name:string,
    mesh:base.Asset_Id,
    materials:[render.MATERIAL_SLOTS]base.Asset_Id, // those its slots override; none: the mesh's
    wind,flutter:f32, // that its materials sway its mesh and flutter its leaves with (mesh_wind)
    casts_shadow:bool,
    box_center,box_half:[3]f32, // of the box of its mesh, when it collides; zero half for none
}

Instanced_Batch :: struct {
    type:Instanced_Type,
    instances:[]mm.Transform, // in the space of the world
}

// Collects the valid instances of batches relative to origin.
instanced_collect :: proc(out:^Foliage_Result,batches:[]Instanced_Batch,origin:[3]f32) {
    for b in batches {
        collides:=b.type.box_half!={}
        for placed in b.instances {
            at:=placed
            at.position-=origin
            if !scale_valid(at.scale) {out.dropped+=1;continue}
            append(&out.placed,Placed_Instance{
                name=b.type.name,
                mesh=b.type.mesh,
                materials=b.type.materials,
                transform=at,
                wind=b.type.wind,
                flutter=b.type.flutter,
                casts_shadow=b.type.casts_shadow,
                collides=collides,
                box_center=b.type.box_center,
                box_half=b.type.box_half,
            })
        }
    }
}

@(storage)
Foliage_Unreal :: struct {provider:unreal_scene.Translator_Provider}

foliage_unreal_default :: proc() -> (f:Foliage_Unreal) {
    f.provider.count=2
    f.provider.translators[0]={classes={0="InstancedFoliageActor"},translate=foliages_translate,instanced=true,map_scene=true}
    f.provider.translators[1]={classes={0="StaticMeshComponent"},component=mesh_sway}
    return
}

// A mesh placed in the level whose materials sway in the wind stays its
// entity, with its transform and collision, and sways as foliage of the
// wind they give (mesh_wind) with a Foliage_Sway.
mesh_sway :: proc(c:^unreal_scene.Context,a,k:int,e:base.Entity_Id) {
    unreal_scene.zone(c,"foliage.sway")
    winds:=winds_kept(c)
    if !materials_sway(c,winds,unreal_scene.slot_material_paths(c,k)) {return}
    d:=c.d
    ref:=d.components[k].ref
    path:=level.path_of(d,ref,"StaticMesh")
    _,object:=unreal_scene.object_split(path)
    sway:=mesh_wind(c,winds,unreal.asset_name(object),path,level.paths_of(d,ref,"OverrideMaterials"))
    if sway.wind<=0 {return}
    winds_count(winds,sway,1)
    shown:=foliage.Foliage_Sway{wind=sway.wind,flutter=sway.flutter}
    unreal_scene.component_set(c,e,"Foliage_Sway",&shown)
}

foliages_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"foliage.translate")
    origin,section:=unreal_scene.section_origin(c)
    result:=Foliage_Result{placed=make([dynamic]Placed_Instance,context.temp_allocator)}
    winds:=winds_kept(c)
    translated:=0
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
                wind_zone:=unreal_scene.zone_begin(c,"foliage.wind")
                type_winds:=make([]Mesh_Wind,len(f.types),context.temp_allocator)
                for t,i in f.types {
                    if t.kind!=.Static_Mesh {continue}
                    sway:=mesh_wind(c,winds,unreal.asset_name(t.name),t.mesh,nil)
                    type_winds[i]=sway
                    winds_count(winds,sway,t.instance_count)
                }
                unreal_scene.zone_end(wind_zone)
                add_zone:=unreal_scene.zone_begin(c,"foliage.add")
                foliage_collect(&result,&f,{meshes=meshes,winds=type_winds},origin)
                unreal_scene.zone_end(add_zone)
                // Its types of ISM actors show as the instanced components that draw them.
                for k in f.components {append(&c.instanced,unreal_scene.Instanced{f.actor,k})}
                translated+=1
            }
        }
    }
    if len(c.instanced)>0 {
        batches_zone:=unreal_scene.zone_begin(c,"foliage.instanced")
        batches:=instanced_batches(c,winds)
        unreal_scene.zone_end(batches_zone)
        add_zone:=unreal_scene.zone_begin(c,"foliage.add")
        instanced_collect(&result,batches,origin)
        unreal_scene.zone_end(add_zone)
    }
    if c.section==0 {
        grass_zone:=unreal_scene.zone_begin(c,"foliage.grass")
        grass_translate(c,origin,winds)
        unreal_scene.zone_end(grass_zone)
    }
    unreal_scene.tally(c,"instances of foliage with a zero, negative or too large scale are left out",result.dropped)
    unreal_scene.tally(c,"instances of foliage of actors have no actor in the level, which the editor of Unreal places again, and are left out",result.unplaced)
    wind_write(c,winds)
    if len(result.placed)==0 {return translated}
    name:=section!=""?section:"Foliage"
    unreal_scene.zone(c,"foliage.write")
    group,made:=unreal_scene.entity_make(c,0,fmt.tprintf("%s|foliage",name),"Foliage",{origin,1,{1,1,1}})
    if !made {return translated}
    for p,i in result.placed {
        if p.mesh=={} {continue}
        e,ok:=unreal_scene.entity_make(c,group,fmt.tprintf("%s|foliage|%d",name,i),p.name,p.transform)
        if !ok {return translated}
        shown:=render.MESH_RENDERER_DEFAULT
        shown.mesh,shown.materials,shown.shadows=p.mesh,p.materials,p.casts_shadow
        unreal_scene.component_set(c,e,"Mesh_Renderer",&shown)
        if p.wind>0 || p.flutter>0 {
            sway:=foliage.Foliage_Sway{wind=p.wind,flutter=p.flutter}
            unreal_scene.component_set(c,e,"Foliage_Sway",&sway)
        }
        if p.collides {
            col:=physics.collider_box(p.box_half)
            col.center=p.box_center
            unreal_scene.component_set(c,e,"Collider",&col)
        }
    }
    return translated
}

// The batches of the instanced components of the scene (c.instanced): each
// its mesh and the materials its slots override, its shadows and the box of
// its mesh when it collides; its instances where they are in the world. A
// material the level keeps inside an actor is written now, and the instances
// of each set of custom data (PerInstanceSMCustomData) are a batch that shows
// the variants of the materials that read it. Each takes the wind its
// materials sway its mesh with.
@(private)
instanced_batches :: proc(c:^unreal_scene.Context,winds:^Winds) -> []Instanced_Batch {
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
        t:=Instanced_Type{name=unreal.asset_name(object),mesh=shown.mesh,materials=shown.materials,casts_shadow=shown.shadows}
        sway:=mesh_wind(c,winds,t.name,path,level.paths_of(d,ref,"OverrideMaterials"))
        t.wind,t.flutter=sway.wind,sway.flutter
        winds_count(winds,sway,len(instances.matrices))
        if profile,enabled,_:=level.component_collision(d,ref);level.profile_collides(profile,enabled) {
            if box:=level.mesh_box(d,path,&boxes);box.ok {
                t.box_center=mm.aabb_center(box.box)
                t.box_half=mm.aabb_size(box.box)*0.5
            }
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
