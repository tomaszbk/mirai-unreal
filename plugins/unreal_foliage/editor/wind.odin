package unreal_foliage_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "project:plugins/unreal/editor/material"
import material_write "project:plugins/unreal/editor/material/write"
import umesh "project:plugins/unreal/editor/mesh"
import umodel "project:plugins/unreal/editor/model"
import unreal_scene "project:plugins/unreal/editor/scene"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"

// Unreal sways foliage with the WorldPositionOffset of its materials; Mirai
// with the wind of each type, where a Wind blows. A type whose materials
// sway in the wind (material.offset_read) gets the wind that leans it as
// they do:
//
// - Each material measures, at vertices of its sections of the mesh, how far
//   it sways each slower than a second, S, at the height h of the vertex
//   above the pivot, and how far it flutters each faster than that
//   (material.Offset_Reach): what the wind moves, not what it leans the
//   vertex one way all the time. Mirai bends the whole plant about where it
//   stands, so its swing is the one whose bend best matches the sways in
//   least squares: ΣS·h/Σh² of its height over the vertices of the mesh,
//   those that do not sway counting as still.
// - What flutters faster is the flutter of the leaves of Mirai, on top of the
//   bend, by the green of the vertices the mesh import gives the sections
//   whose material flutters (model/flutter.odin): the mean of their flutter is
//   what Mirai's leaves flutter on average, FLUTTER_MEAN of their flutter in
//   the peak of a gust, in a Wind of the speed Mirai gives one.
// - A plant of Mirai sways between SWAY_LEAST of its lean at the peak and
//   all of it (foliage_sway.slang), so the lean θ at the peak is the one whose
//   sine is that swing over 1-SWAY_LEAST; wind leans a plant by θ in a Wind
//   of the speed Mirai gives one (volume.WIND_DEFAULT): θ over that speed and
//   over the lean per m/s of a wind of 1 (foliage.sway_amount).
// - A material whose sway cannot be measured gives Mirai's default wind;
//   one that moves its vertices by something else than wind, or not with
//   time, sways nothing and is a warning.
//
// What says in the level that the air moves is those materials: Unreal's
// foliage sways by them whatever its actors are, and the parameters of the
// wind they read (a collection's or their own) are in what they measure.
// The scene of the map gets a Wind of the speed the winds are measured
// against, blowing the way most of the instances that sway are moved, with
// the gusts they sway at on average (a cycle per second each time their top
// sways back and forth); when the materials say neither a way nor a pace,
// no Wind is added and the import says so.

SWAY_LEAST :: 0.2   // of its lean at the peak, the least a plant of Mirai leans as it sways
FLUTTER_MEAN :: 0.6 // of its flutter in the peak of a gust, what a plant of Mirai flutters on average

// What the materials of a mesh do to it, summed over its vertices measured.
Sway :: struct {
    moved,tall:f64,   // Σ S·h and Σ h², cm²
    fluttered:[2]f64, // Σ of the flutter of the vertices of the sections that flutter, cm, and how many
    direction:[2]f64, // Unreal's X and Y: the way of each material that sways, by its reach
    frequency:[2]f64, // Σ cycles per second of each material that sways and is measured to, by its reach, and Σ of those reaches
    winds:int,        // materials that sway in the wind
    unmeasured:int,   // of those, ones whose reach could not be measured
}

// Adds a material of the mesh: its offset and the reach it gives each vertex.
sway_add :: proc(s:^Sway,o:material.Offset,vertices:[]material.Offset_Vertex,reach:[]material.Offset_Reach) {
    wind:=o.kind==.Wind
    if wind {s.winds+=1}
    if wind && o.why!="" {
        s.unmeasured+=1
        return
    }
    total:f64
    for v,i in vertices {
        h:=f64(max(v.position.z,0))
        s.tall+=h*h
        if wind && i<len(reach) && reach[i].sway>0 {
            s.moved+=f64(reach[i].sway)*h
            total+=f64(reach[i].sway)
        }
    }
    if wind && material.offset_flutters(reach[:min(len(reach),len(vertices))]) {
        for r in reach[:len(vertices)] {s.fluttered+={f64(max(r.flutter,0)),1}}
    }
    s.direction+=[2]f64{f64(o.direction.x),f64(o.direction.y)}*total
    if o.frequency>0 {s.frequency+={f64(o.frequency)*total,total}}
}

// Cycles per second the mesh sways at; 0 where no material says.
sway_frequency :: proc(s:Sway) -> f32 {return s.frequency.y>0?f32(s.frequency.x/s.frequency.y):0}

// The flutter of a type of the mesh, by the rule above.
sway_flutter :: proc(s:Sway) -> f32 {
    if !(s.fluttered.y>0) {return 0}
    unit:=foliage.FOLIAGE_TYPE_DEFAULT
    unit.flutter=1
    return f32(s.fluttered.x/s.fluttered.y*0.01/(FLUTTER_MEAN*f64(foliage.flutter_amount(unit))*f64(volume.WIND_DEFAULT.speed)))
}

// The wind of a type of the mesh, by the rule above.
sway_wind :: proc(s:Sway) -> f32 {
    if s.winds==0 {return 0}
    if s.winds==s.unmeasured {return foliage.FOLIAGE_TYPE_DEFAULT.wind}
    if !(s.tall>0) || !(s.moved>0) {return 0}
    lean:=math.asin(min(s.moved/s.tall/(1-SWAY_LEAST),1))
    unit:=foliage.FOLIAGE_TYPE_DEFAULT
    unit.wind=1
    return f32(lean)/(foliage.sway_amount(unit)*volume.WIND_DEFAULT.speed)
}

// Unit, along Unreal's X and Y; zero where it sways both ways.
sway_direction :: proc(s:Sway) -> [2]f32 {
    length:=math.sqrt(s.direction.x*s.direction.x+s.direction.y*s.direction.y)
    if !(length>0) {return {}}
    return {f32(s.direction.x/length),f32(s.direction.y/length)}
}

// What the import says of a material of the foliage type owner, by what its
// offset does; none for one that sways as Mirai's foliage does.
offset_warnings :: proc(owner,path:string,o:material.Offset,allocator:=context.temp_allocator) -> []string {
    out:=make([dynamic]string,allocator)
    switch o.kind {
    case .None:
    case .Shape:
        append(&out,fmt.aprintf("%s: its material %s offsets its vertices without time, which Mirai's materials do not do: it stands as its mesh is",owner,path,allocator=allocator))
    case .Motion:
        moved:="its own expressions"
        if len(o.names)>0 {moved=strings.join(o.names,", ",allocator)}
        append(&out,fmt.aprintf("%s: its material %s moves its vertices with time by %s, which is not wind: Mirai's foliage moves only in the wind, and it stands still",owner,path,moved,allocator=allocator))
    case .Wind:
        if o.why!="" {
            append(&out,fmt.aprintf("%s: how far its material %s sways in the wind could not be measured (%s): it sways by Mirai's default wind",owner,path,o.why,allocator=allocator))
        }
        if o.weights!={} {
            by:=o.weights=={.Vertex_Color,.UV}?"vertex colors and uv":.Vertex_Color in o.weights?"vertex colors":"uv"
            append(&out,fmt.aprintf("%s: its material %s weighs its sway per vertex by its %s; Mirai bends the whole plant about where it stands, the more the higher",owner,path,by,allocator=allocator))
        }
        if o.textured {
            append(&out,fmt.aprintf("%s: its material %s sways in gusts a texture draws; Mirai's gusts are a wave across the world",owner,path,allocator=allocator))
        }
    }
    return out[:]
}

// The wind of the foliage of an import and of its placed meshes that sway:
// what each mesh gives, the materials warned of, and the way the instances
// that sway are moved.
Winds :: struct {
    meshes:map[string]Mesh_Wind, // by mesh and the materials of its slots
    materials:map[string]bool,   // whether a material sways in the wind, by object path
    warned:map[string]struct{},  // materials
    blown:[2]f64,                // Unreal's X and Y: the way of each type that sways, by its instances
    paced:[2]f64,                // Σ cycles per second of each type that sways at a pace, by its instances, and Σ of those instances
    ways:[dynamic][2]f32,        // of the types that sway one way
    swaying:bool,                // some material sways in the wind
}

Mesh_Wind :: struct {wind,flutter:f32,direction:[2]f32,frequency:f32}

winds_make :: proc() -> (w:Winds) {
    w.meshes=make(map[string]Mesh_Wind,context.temp_allocator)
    w.materials=make(map[string]bool,context.temp_allocator)
    w.warned=make(map[string]struct{},context.temp_allocator)
    w.ways=make([dynamic][2]f32,context.temp_allocator)
    return
}

WINDS_KEPT :: "foliage|winds"

// The winds of the import, which its translators and its components share.
winds_kept :: proc(c:^unreal_scene.Context) -> ^Winds {
    if kept,found:=c.kept[WINDS_KEPT];found {return (^Winds)(kept)}
    w:=new(Winds,context.temp_allocator)
    w^=winds_make()
    c.kept[WINDS_KEPT]=w
    return w
}

// Whether a material of paths sways in the wind (material.offset_read).
materials_sway :: proc(c:^unreal_scene.Context,w:^Winds,paths:[]string) -> bool {
    for path in paths {
        if path=="" {continue}
        sways,known:=w.materials[path]
        if !known {
            unreal_scene.library_lock(c)
            if m,found:=material.object_find(c.lib,path);found {
                o,error:=material.offset_read(c.lib,m,nil,{},nil,allocator=context.temp_allocator)
                sways=error.code==.None && o.kind==.Wind
            }
            unreal_scene.library_unlock(c)
            w.materials[strings.clone(path,context.temp_allocator)]=sways
        }
        if sways {return true}
    }
    return false
}

// A type that sways, with its instances, counts toward the way and the
// gusts of the Wind.
winds_count :: proc(w:^Winds,sway:Mesh_Wind,instances:int) {
    if sway.wind<=0 {return}
    if sway.frequency>0 {w.paced+={f64(sway.frequency)*f64(instances),f64(instances)}}
    if sway.direction=={} {return}
    append(&w.ways,sway.direction)
    w.blown+=[2]f64{f64(sway.direction.x),f64(sway.direction.y)}*f64(instances)
}

// The wind of a type that shows the StaticMesh at mesh (an object path)
// with the materials of slots, by Unreal's index of its slot ("" or past
// them: the mesh's), and the way its materials move it. owner names the
// type in the warnings.
mesh_wind :: proc(c:^unreal_scene.Context,w:^Winds,owner,mesh:string,slots:[]string) -> (sway:Mesh_Wind) {
    if mesh=="" {return}
    key:=strings.join({mesh,strings.join(slots,"|",context.temp_allocator)},"|",context.temp_allocator)
    if found,seen:=w.meshes[key];seen {return found}
    defer w.meshes[key]=sway
    decoder,ready:=unreal_scene.decoder(c)
    if !ready {return}
    unreal_scene.library_lock(c)
    defer unreal_scene.library_unlock(c)
    object,found:=material.object_find(c.lib,mesh)
    if !found {return}
    source,error:=umesh.mesh_read(&object.pkg.p,object.export,.Lod0,context.temp_allocator)
    if error.code!=.None {return}
    geometry,decode_error:=umesh.mesh_decode(&object.pkg.p,&source,decoder,context.temp_allocator,context.temp_allocator,c.options.worker)
    if decode_error.code!=.None {return}
    s:Sway
    for slot,index in source.materials {
        path:=index<len(slots) && slots[index]!=""?slots[index]:slot.path
        if path=="" {continue}
        vertices:=umodel.offset_vertices(&geometry,index)
        if len(vertices)==0 {continue}
        m,known:=material.object_find(c.lib,path)
        if !known {continue}
        reach:=make([]material.Offset_Reach,len(vertices),context.temp_allocator)
        o,offset_error:=material.offset_read(c.lib,m,vertices,{geometry.bounds_min,geometry.bounds_max},reach,{texture_pixels,c},context.temp_allocator)
        if offset_error.code!=.None {continue}
        sway_add(&s,o,vertices,reach)
        w.swaying||=o.kind==.Wind
        if path in w.warned {continue}
        w.warned[strings.clone(path,context.temp_allocator)]={}
        for text in offset_warnings(owner,path,o) {unreal_scene.warn(c,"%s",text)}
    }
    return {sway_wind(s),sway_flutter(s),sway_direction(s),sway_frequency(s)}
}

// The texels of a texture an offset samples, from the textures of the level
// (with its library taken).
@(private)
texture_pixels :: proc(data:rawptr,path:string) -> ^material.Pixels {
    c:=(^unreal_scene.Context)(data)
    decoder,ready:=unreal_scene.decoder(c)
    if !ready {return nil}
    return material_write.source_pixels(&c.images,path,decoder)
}

// The Wind the foliage of the level sways in, in the scene of the map, once:
// of the speed the wind of its types is measured against, blowing the way
// most of the instances that sway are moved. What it cannot keep of the
// materials is a warning.
wind_write :: proc(c:^unreal_scene.Context,w:^Winds) {
    if !w.swaying {return}
    length:=math.sqrt(w.blown.x*w.blown.x+w.blown.y*w.blown.y)
    if !(length>0) && !(w.paced.y>0) {
        unreal_scene.warn(c,"its foliage sways in the wind by its materials, but they say neither the way nor the pace of the wind: no Wind is added, and the foliage stands still until one blows")
        return
    }
    wind:=volume.WIND_DEFAULT
    if w.paced.y>0 {
        wind.gusts=f32(w.paced.x/w.paced.y)
    } else {
        unreal_scene.warn(c,"the materials of its foliage do not say the pace of the wind: the Wind gusts at %g cycles a second, Mirai's default",wind.gusts)
    }
    way:=[2]f32{1,0}
    if length>0 {
        way={f32(w.blown.x/length),f32(w.blown.y/length)}
    } else {
        unreal_scene.warn(c,"the materials of its foliage sway it both ways alike: the Wind blows along the X of Unreal")
    }
    apart:=0
    for d in w.ways {if d.x*way.x+d.y*way.y<WAY_ALIKE {apart+=1}}
    if apart>0 {
        unreal_scene.warn(c,"%d types of foliage sway another way than the most of them; Mirai's wind blows one way where it is, the way of most of the instances",apart)
    }
    unreal_scene.warn(c,"the materials of the foliage sway each at a pace of their own; Mirai's foliage sways at the gusts of the Wind where it stands")
    previous:=unreal_scene.section_use(c,0)
    defer unreal_scene.section_use(c,previous)
    key:="foliage|wind"
    if base.Entity_Id(base.name_hash(key)) in c.scene.index {return}
    // Unreal's X and Y are Mirai's -Z and X; a Wind blows along its forward.
    forward:=[3]f32{way.y,0,-way.x}
    e,made:=unreal_scene.entity_make(c,0,key,"Wind",{0,mm.quat_look(forward,{0,1,0}),{1,1,1}})
    if !made {return}
    unreal_scene.component_set(c,e,"Wind",&wind)
}

WAY_ALIKE :: f32(0.99) // the cosine past which two ways are one
