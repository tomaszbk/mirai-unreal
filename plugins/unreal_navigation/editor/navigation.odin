package unreal_navigation_editor

import "core:fmt"
import "core:strings"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"

// The navigation of an Unreal level imported by the editor. Mirai builds its
// meshes from the collision, so what the level gives is where and how:
// - NavMeshBoundsVolume: a Nav_Bounds of the size of its CubeBuilder.
// - NavModifierVolume: a Nav_Area of that size, of the area its AreaClass
//   names: NavArea_Null blocks, NavArea_Default walks, Obstacle and LowHeight
//   block (Unreal makes them dear or low; Mirai has no such area of its own).
// - NavLinkProxy: a Nav_Link per point link, from Left to Right in the frame
//   of the actor, both ways or one; its smart link, when relevant, a Door that
//   the game crosses.
// - RecastNavMesh: nothing to write; its agent is a note, the classes are
//   those of Navigation_Settings.
@(storage)
Navigation_Unreal :: struct {provider:unreal_scene.Translator_Provider}

navigation_unreal_default :: proc() -> (p:Navigation_Unreal) {
    p.provider.count=4
    p.provider.translators[0]={classes={0="NavMeshBoundsVolume"},translate=bounds_translate}
    p.provider.translators[1]={classes={0="NavModifierVolume"},translate=modifiers_translate}
    p.provider.translators[2]={classes={0="NavLinkProxy"},translate=links_translate}
    p.provider.translators[3]={classes={0="RecastNavMesh"},translate=recast_translate}
    return
}

// The half sizes of the CubeBuilder of a brush actor, in metres along Mirai's axes; false without one.
@(private)
brush_half :: proc(d:^level.Document,a:int) -> (half:[3]f32,ok:bool) {
    for k in d.actors[a].first_component..<d.actors[a].first_component+d.actors[a].component_count {
        if d.components[k].class.name!="CubeBuilder" {continue}
        ref:=d.components[k].ref
        // Unreal's X, Y and Z are Mirai's Z, X and Y; 200 cm across by default.
        x,_:=level.real_of(d,ref,"X",200)
        y,_:=level.real_of(d,ref,"Y",200)
        z,_:=level.real_of(d,ref,"Z",200)
        return {f32(y)/200,f32(z)/200,f32(x)/200},true
    }
    return
}

// An entity where a brush actor is, with the box of its CubeBuilder.
@(private)
brush_entity :: proc(c:^unreal_scene.Context,a:int) -> (e:base.Entity_Id,half:[3]f32,placed:bool) {
    d:=c.d
    found:bool
    if half,found=brush_half(d,a);!found || d.actors[a].root<0 {return}
    world,_,error:=level.actor_world(d,a)
    if error.code!=.None {return}
    e,placed=unreal_scene.entity_make(c,0,unreal_scene.actor_key(c,a),d.actors[a].label,world)
    return
}

bounds_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"navigation.translate")
    translated,other:=0,0
    for a in actors {
        e,half,placed:=brush_entity(c,a)
        if !placed {other+=1;continue}
        bounds:=nav.Nav_Bounds{half=half}
        if !unreal_scene.component_set(c,e,"Nav_Bounds",&bounds) {return translated}
        translated+=1
    }
    if other>0 {unreal_scene.warn(c,"%d NavMeshBoundsVolumes are not boxes of a CubeBuilder; their brushes are not read",other)}
    return translated
}

modifiers_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"navigation.translate")
    d:=c.d
    translated,other:=0,0
    unknown:=make(map[string]int,context.temp_allocator)
    for a in actors {
        e,half,placed:=brush_entity(c,a)
        if !placed {other+=1;continue}
        // The class of the area, by its name: NavArea_Null when it is not set.
        path:=level.path_of(d,d.actors[a].ref,"AreaClass")
        name:="NavArea_Null" if path=="" else path[strings.last_index_any(path,"./")+1:]
        name=strings.trim_suffix(name,"_C")
        area:=nav.Nav_Area{half=half,area=nav.AREA_BLOCKED}
        switch name {
        case "NavArea_Null","NavArea_Obstacle","NavArea_LowHeight":
        case "NavArea_Default":
            area.area=nav.AREA_WALKABLE
        case:
            area.area=nav.AREA_WALKABLE
            unknown[name]+=1
        }
        if !unreal_scene.component_set(c,e,"Nav_Area",&area) {return translated}
        translated+=1
    }
    for name,count in unknown {
        unreal_scene.warn(c,"%d NavModifierVolumes of area %s walk as AREA_WALKABLE: declare a Nav_Area_Kind for it and set it on their Nav_Area",count,name)
    }
    if other>0 {unreal_scene.warn(c,"%d NavModifierVolumes are not boxes of a CubeBuilder; their brushes are not read",other)}
    return translated
}

// A point link of Unreal: two points in the frame of its actor, in centimetres.
@(private)
Point_Link :: struct {left,right:[3]f64,direction:string}

@(private)
vector_value :: proc(p:^unreal.Package,property:^unreal.Property,default:[3]f64) -> [3]f64 {
    if property==nil {return default}
    v,error:=unreal.property_value(p,property,context.temp_allocator)
    if error.code!=.None || v.kind!=.Real_Vector || v.vector_count<3 {return default}
    return {v.vector[0],v.vector[1],v.vector[2]}
}

// The point links of a NavLinkProxy: those it saved, or the one its constructor makes.
@(private)
point_links :: proc(c:^unreal_scene.Context,a:int) -> (links:[dynamic]Point_Link,ok:bool) {
    d:=c.d
    links=make([dynamic]Point_Link,context.temp_allocator)
    f,error:=level.property(d,d.actors[a].ref,"PointLinks")
    if error.code!=.None || f.property==nil {
        append(&links,Point_Link{left={0,-50,0},right={0,50,0},direction="BothWays"})
        return links,true
    }
    view,view_error:=unreal.property_array(f.pkg,f.property)
    if view_error.code!=.None {return}
    items,items_error:=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
    if items_error.code!=.None {return}
    for &item in items.items {
        link:=Point_Link{left=vector_value(f.pkg,unreal.property_find(f.pkg,&item,"Left"),{0,-50,0}),right=vector_value(f.pkg,unreal.property_find(f.pkg,&item,"Right"),{0,50,0}),direction="BothWays"}
        if property:=unreal.property_find(f.pkg,&item,"Direction");property!=nil {link.direction,_=level.value_enum(f.pkg,property,"BothWays")}
        append(&links,link)
    }
    return links,true
}

// A link of a NavLinkProxy as an entity at its start, with its end in the frame of the actor.
@(private)
link_entity :: proc(c:^unreal_scene.Context,a:int,key:string,link:Point_Link,kind:nav.Nav_Link_Kind,world:mm.Transform) -> bool {
    left,right:=link.left,link.right
    if link.direction=="RightToLeft" {left,right=right,left}
    start,end:=level.point_to_mirai(left),level.point_to_mirai(right)
    t:=world
    t.position=mm.transform_point(world,start)
    id,made:=unreal_scene.entity_make(c,0,key,c.d.actors[a].label,t)
    if !made {return false}
    value:=nav.Nav_Link{end=end-start,kind=kind,two_way=link.direction!="LeftToRight" && link.direction!="RightToLeft",area=nav.AREA_WALKABLE}
    return unreal_scene.component_set(c,id,"Nav_Link",&value)
}

links_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"navigation.translate")
    d:=c.d
    translated,smart,unread:=0,0,0
    for a in actors {
        world,_,error:=level.actor_world(d,a)
        links,ok:=point_links(c,a)
        if error.code!=.None || !ok {unread+=1;continue}
        key:=unreal_scene.actor_key(c,a)
        for link,i in links {
            if !link_entity(c,a,fmt.tprintf("%s#link%d",key,i),link,nav.LINK_JUMP,world) {return translated}
        }
        if relevant,_:=level.bool_of(d,d.actors[a].ref,"bSmartLinkIsRelevant",false);relevant {
            for k in d.actors[a].first_component..<d.actors[a].first_component+d.actors[a].component_count {
                if d.components[k].class.name!="NavLinkCustomComponent" {continue}
                ref:=d.components[k].ref
                start:=[3]f64{70,0,0}
                end:=[3]f64{-70,0,0}
                if f,f_error:=level.property(d,ref,"LinkRelativeStart");f_error.code==.None {start=vector_value(f.pkg,f.property,start)}
                if f,f_error:=level.property(d,ref,"LinkRelativeEnd");f_error.code==.None {end=vector_value(f.pkg,f.property,end)}
                direction,_:=level.enum_of(d,ref,"LinkDirection","BothWays")
                if !link_entity(c,a,fmt.tprintf("%s#smart",key),{start,end,direction},nav.LINK_DOOR,world) {return translated}
                smart+=1
                break
            }
        }
        translated+=1
    }
    if smart>0 {unreal_scene.warn(c,"%d smart links of NavLinkProxies are Door links: the game crosses them (nav_crossing_done), as Unreal leaves them to the game",smart)}
    if unread>0 {unreal_scene.warn(c,"%d NavLinkProxies could not be read: their place or their point links",unread)}
    return translated
}

recast_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"navigation.translate")
    d:=c.d
    for a in actors {
        ref:=d.actors[a].ref
        radius,_:=level.real_of(d,ref,"AgentRadius",34)
        height,_:=level.real_of(d,ref,"AgentHeight",144)
        unreal_scene.warn(c,"%s: Mirai builds its navigation meshes from the collision, for the classes of Navigation_Settings; the agent of this one was %.2f m across and %.2f m high",d.actors[a].label,radius/50,height/100)
    }
    return len(actors)
}
