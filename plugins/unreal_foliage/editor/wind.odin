package unreal_foliage_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "project:plugins/unreal/editor/material"
import umesh "project:plugins/unreal/editor/mesh"
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
// - Each material measures, at vertices of its sections of the mesh, the
//   most it moves each across, R, at the height h of the vertex above the
//   pivot. Mirai bends the whole plant about where it stands, so the lean θ
//   is the one whose bend best matches those reaches in least squares:
//   sin θ = ΣR·h/Σh² over the vertices of the mesh, those that do not sway
//   counting as still.
// - wind leans a plant by θ at the peak of its sway in a Wind of the speed
//   Mirai gives one (volume.WIND_DEFAULT): θ over that speed and over the
//   lean per m/s of a wind of 1 (foliage.sway_amount).
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

WIND_VERTICES :: 32 // of each material of a mesh, at most, its reach is measured at

// What the materials of a mesh do to it, summed over its vertices measured.
Sway :: struct {
    moved,tall:f64,   // Σ R·h and Σ h², cm²
    direction:[2]f64, // Unreal's X and Y: the way of each material that sways, by its reach
    frequency:[2]f64, // Σ cycles per second of each material that sways and is measured to, by its reach, and Σ of those reaches
    winds:int,        // materials that sway in the wind
    unmeasured:int,   // of those, ones whose reach could not be measured
}

// Adds a material of the mesh: its offset and the reach it gives each vertex.
sway_add :: proc(s:^Sway,o:material.Offset,vertices:[]material.Offset_Vertex,reach:[]f32) {
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
        if wind && i<len(reach) && reach[i]>0 {
            s.moved+=f64(reach[i])*h
            total+=f64(reach[i])
        }
    }
    s.direction+=[2]f64{f64(o.direction.x),f64(o.direction.y)}*total
    if o.frequency>0 {s.frequency+={f64(o.frequency)*total,total}}
}

// Cycles per second the mesh sways at; 0 where no material says.
sway_frequency :: proc(s:Sway) -> f32 {return s.frequency.y>0?f32(s.frequency.x/s.frequency.y):0}

// The wind of a type of the mesh, by the rule above.
sway_wind :: proc(s:Sway) -> f32 {
    if s.winds==0 {return 0}
    if s.winds==s.unmeasured {return foliage.FOLIAGE_TYPE_DEFAULT.wind}
    if !(s.tall>0) || !(s.moved>0) {return 0}
    lean:=math.asin(min(s.moved/s.tall,1))
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

// The wind of the foliage of a scene: what each mesh gives, the materials
// warned of, and the way the instances that sway are moved.
Winds :: struct {
    meshes:map[string]Mesh_Wind, // by mesh and the materials of its slots
    warned:map[string]struct{},  // materials
    blown:[2]f64,                // Unreal's X and Y: the way of each type that sways, by its instances
    paced:[2]f64,                // Σ cycles per second of each type that sways at a pace, by its instances, and Σ of those instances
    ways:[dynamic][2]f32,        // of the types that sway one way
    swaying:bool,                // some material sways in the wind
}

Mesh_Wind :: struct {wind:f32,direction:[2]f32,frequency:f32}

winds_make :: proc() -> (w:Winds) {
    w.meshes=make(map[string]Mesh_Wind,context.temp_allocator)
    w.warned=make(map[string]struct{},context.temp_allocator)
    w.ways=make([dynamic][2]f32,context.temp_allocator)
    return
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
        vertices:=section_vertices(&geometry,index)
        if len(vertices)==0 {continue}
        m,known:=material.object_find(c.lib,path)
        if !known {continue}
        reach:=make([]f32,len(vertices),context.temp_allocator)
        o,offset_error:=material.offset_read(c.lib,m,vertices,{geometry.bounds_min,geometry.bounds_max},reach,context.temp_allocator)
        if offset_error.code!=.None {continue}
        sway_add(&s,o,vertices,reach)
        w.swaying||=o.kind==.Wind
        if path in w.warned {continue}
        w.warned[strings.clone(path,context.temp_allocator)]={}
        for text in offset_warnings(owner,path,o) {unreal_scene.warn(c,"%s",text)}
    }
    return {sway_wind(s),sway_direction(s),sway_frequency(s)}
}

// Up to WIND_VERTICES vertices of the sections of the mesh that show the
// material of a slot, spread over them, the highest among them.
@(private)
section_vertices :: proc(m:^umesh.Mesh,slot:int) -> []material.Offset_Vertex {
    corners:=make([dynamic]int,context.temp_allocator)
    highest:=-1
    for section,triangle in m.triangle_section {
        if int(section)>=len(m.sections) || m.sections[section].material!=slot {continue}
        for k in 0..<3 {
            corner:=triangle*3+k
            append(&corners,corner)
            if highest<0 || m.positions[m.corner_vertex[corner]].z>m.positions[m.corner_vertex[highest]].z {highest=corner}
        }
    }
    if len(corners)==0 {return nil}
    count:=min(len(corners),WIND_VERTICES)
    out:=make([]material.Offset_Vertex,count,context.temp_allocator)
    for &v,i in out {
        corner:=i==0?highest:corners[i*len(corners)/count]
        v.position=m.positions[m.corner_vertex[corner]]
        for set in 0..<min(m.uv_count,material.UNREAL_UV_SETS) {v.uvs[set]=m.corner_uvs[set][corner]}
        v.color={1,1,1,1}
        if len(m.corner_color)>0 {
            rgba:=m.corner_color[corner]
            v.color={f32(rgba[0]),f32(rgba[1]),f32(rgba[2]),f32(rgba[3])}/255
        }
    }
    return out
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
