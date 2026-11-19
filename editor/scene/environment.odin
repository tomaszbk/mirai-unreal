package unreal_scene

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import material "project:plugins/unreal/editor/material"
import material_write "project:plugins/unreal/editor/material/write"
import unreal_mesh "project:plugins/unreal/editor/mesh"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"

// Cameras, the light of the sky and the sun: what of Unreal's has a
// physical equivalent in Mirai. A camera is its vertical field of view and
// its exposure; a sky light, Mirai's sky at its intensity, with the image of
// its cubemap when it names one; the post process, post_process.odin. The
// rest is a warning.

// The camera of a component on an entity under its actor that has the label
// of the actor, as mirai capture --camera-entity names it. Unreal's camera
// looks along +X with +Z up: Mirai's -Z and +Y.
@(private)
camera_add :: proc(c:^Context,a,k:int,cine:bool) -> bool {
    d:=c.d
    ref:=d.components[k].ref
    camera:=render.CAMERA_DEFAULT
    note:=Camera_Note{name=clone(c,d.actors[a].label),cine=cine}
    if cine {
        // The vertical field of view of the sensor and the lens; the aspect ratio of the view is that of the sensor.
        filmback:=struct_chain(d,ref,"Filmback","FilmbackSettings")
        width,_:=chain_real(&filmback,"SensorWidth",23.76)
        height,_:=chain_real(&filmback,"SensorHeight",13.365)
        focal,_:=level.real_of(d,ref,"CurrentFocalLength",35)
        if focal<=0 {focal=35}
        camera.fov=f32(2*math.atan(height/(2*focal)))
        note.focal,note.sensor=f32(focal),{f32(width),f32(height)}
    } else {
        horizontal,_:=level.real_of(d,ref,"FieldOfView",90)
        aspect,_:=level.real_of(d,ref,"AspectRatio",1.777778)
        if aspect<=0 {aspect=1.777778}
        camera.fov=f32(2*math.atan(math.tan(clamp(horizontal,1,179)*math.RAD_PER_DEG/2)/aspect))
        if mode,_:=level.enum_of(d,ref,"ProjectionMode","Perspective");mode=="Orthographic" {
            width,_:=level.real_of(d,ref,"OrthoWidth",512)
            camera.projection=.Orthographic
            camera.height=f32(width/aspect/100)
        }
    }
    activation,_:=level.enum_of(d,d.actors[a].ref,"AutoActivateForPlayer","Disabled")
    camera.active=activation!="Disabled"
    e:=component_entity(c,a,k,scale={1,1,1},name=d.actors[a].label) or_return
    if !component_set(c,e,"Camera",&camera) {return false}
    // What the camera overrides is over the unbound volumes, everywhere.
    weight,_:=level.real_of(d,ref,"PostProcessBlendWeight",1)
    settings:=post_settings(c,-1,struct_chain(d,ref,"PostProcessSettings"),weight)
    aperture:=f32(0)
    if cine {
        stop,_:=level.real_of(d,ref,"CurrentAperture",2.8)
        aperture=f32(stop)
    }
    if exposure,any:=exposure_from(c,&settings,aperture);any {
        if !component_set(c,e,"Exposure",&exposure) {return false}
    }
    note.fov=camera.fov*math.DEG_PER_RAD
    note.entity=e

    append(&c.report.cameras,note)
    return true
}

// A sky light lights from Mirai's sky. With a cubemap it is that image times
// its intensity and color, as Unreal lights from it, and black under the
// horizon where Unreal makes it so (bLowerHemisphereIsBlack, toward
// LowerHemisphereColor). What Unreal captures from what the scene shows far
// away has no equivalent: Mirai's sky at its intensity, whose luminance keeps
// to the sun of the level what Mirai's sky keeps to its sun
// (environment_finish), so a level lit in small numbers gets a sky in them too.
@(private)
sky_light_add :: proc(c:^Context,a,k:int) -> bool {
    d:=c.d
    ref:=d.components[k].ref
    label:=d.actors[a].label
    if c.sky_lit {
        warn(c,"%s: the scene has a sky light already; Mirai's sky is one",label)
        return false
    }
    intensity,_:=level.real_of(d,ref,"Intensity",1)
    color,_:=color_of(d,ref,"LightColor",{1,1,1})
    c.sky.luminance=color*f32(intensity)
    c.sky_lit=true
    if scale:=post_indirect(c);scale!=1 && light_mobility(c,k)!=.Movable {
        warn(c,"%s: in Unreal the IndirectLightingIntensity %.3g of the post process multiplies the bounce of this sky, which does not move; Mirai's sky has no such multiplier, so it is not taken",label,scale)
    }
    // Under the horizon what it lights from goes toward LowerHemisphereColor
    // by its alpha, captured or from a cube, unless bLowerHemisphereIsBlack is off.
    below:=[4]f32{0,0,0,1}
    if f,error:=level.property(d,ref,"LowerHemisphereColor");error.code==.None && f.property!=nil {
        if v,value_error:=unreal.property_value(f.pkg,f.property);value_error.code==.None && v.kind==.Real_Vector && v.vector_count==4 {
            below={f32(v.vector[0]),f32(v.vector[1]),f32(v.vector[2]),f32(v.vector[3])}
        }
    }
    if black,_:=level.bool_of(d,ref,"bLowerHemisphereIsBlack",true);!black {below.a=0}
    c.sky_below=below
    source,_:=level.enum_of(d,ref,"SourceType","SLS_CapturedScene")
    if source!="SLS_SpecifiedCubemap" {
        c.sky_captured=true
        return true
    }
    cubemap:=level.path_of(d,ref,"Cubemap")
    if cubemap=="" {
        warn(c,"%s: it lights from a cubemap it does not name; the sky is Mirai's gradient at %.3g times its luminance",label,intensity)
        return true
    }
    if c.sky.image,_=sky_image_write(c,cubemap,below);c.sky.image=={} {
        warn(c,"%s: the sky is Mirai's gradient at %.3g times its luminance",label,intensity)
        return true
    }
    // Unreal reads the cube at the direction turned by the angle about its
    // up (Unreal's +Z, Mirai's +Y), and Mirai's sky at the direction turned
    // back by its entity: the same turn about Mirai's up.
    angle,_:=level.real_of(d,ref,"SourceCubemapAngle",0)
    c.sky_turn=math.to_radians(f32(angle))
    return true
}

// Whether the component k of actor a is the dome of the level: a static
// mesh that casts no shadow, whose materials are all unlit and whose bounds
// hold everything the other actors show. It is the sky, which the Sky of the
// scene is in Mirai: it is not drawn.
@(private)
sky_dome :: proc(c:^Context,a,k:int) -> bool {
    d:=c.d
    ref:=d.components[k].ref
    if d.components[k].class.name!="StaticMeshComponent" || casts_shadows(d,ref) {return false}
    if c.boxes.allocator.procedure==nil {c.boxes.allocator=c.meshes.allocator}
    box:=level.component_bounds(d,k,&c.boxes) or_return
    if c.actor_boxes==nil {
        c.actor_boxes=make([]mm.Aabb,len(d.actors),c.meshes.allocator)
        for actor,i in d.actors {
            c.actor_boxes[i]=mm.AABB_EMPTY
            for other in actor.first_component..<actor.first_component+actor.component_count {
                if shown,ok:=level.component_bounds(d,other,&c.boxes);ok {c.actor_boxes[i]=mm.aabb_merge(c.actor_boxes[i],shown)}
            }
        }
    }
    rest:=mm.AABB_EMPTY
    for other,i in c.actor_boxes {
        if i!=a && !mm.aabb_is_empty(other) {rest=mm.aabb_merge(rest,other)}
    }
    if mm.aabb_is_empty(rest) || !mm.aabb_contains(box,rest) {return false}
    overrides:=level.paths_of(d,ref,"OverrideMaterials")
    own:=mesh_slot_paths(c,level.path_of(d,ref,"StaticMesh"),false)
    shown:=0
    for i in 0..<max(len(own),len(overrides)) {
        path:=i<len(overrides) && overrides[i]!="" ? overrides[i] : (i<len(own) ? own[i] : "")
        if path=="" {continue}
        if !material_unlit(c,path) {return false}
        shown+=1
    }
    return shown>0
}

// A dome of the level that may give the Sky its image (dome_add): one
// texture it lays by latitude and longitude, or what its material shows by
// direction.
Sky_Dome :: struct {
    name:string,      // its actor and component
    texture:string,   // the object path of the texture its material shows; "": its material is shaded per direction
    material:string,  // the object path of that material
    component:int,    // of the level
    luminance:[3]f32, // what its material multiplies the texture by, nits; 1 for a material shaded per direction
    turn:f32,         // of the Sky about up for its image to lie as on the dome, radians
    found:bool,
}

// How far, in uv units, the uv of a corner of a dome may be from where a
// latitude-longitude image puts its direction.
@(private) DOME_UV_TOLERANCE :: 0.01
// Corners whose direction is closer to a pole than this sine say nothing by
// their u.
@(private) DOME_POLE_SINE :: 0.05
// Texels across the image of a dome whose material samples no texture: what
// gradients and glows need. One that samples textures is as wide as the
// widest, within DOME_TEXTURED_WIDTH and DOME_MAX_WIDTH.
@(private) DOME_SMOOTH_WIDTH :: 512
@(private) DOME_TEXTURED_WIDTH :: 1024
@(private) DOME_MAX_WIDTH :: 2048
// Directions shaded along each side of a texel of the image of a dome, averaged.
@(private) DOME_SAMPLES :: 2

// The dome k of actor a, which is not drawn: the Sky stands for it. Its image
// is the Sky's: the texture its material shows as it is
// (translated_plain_emission) when its mesh lays it over the sphere by
// latitude and longitude, as the Sky lays its image, turned about up at
// most; else what its material shows in each direction from its centre,
// when that runs on the CPU (material.sky_graph). environment_finish takes
// the first such dome. Any other is a warning.
@(private)
dome_add :: proc(c:^Context,a,k:int) {
    d:=c.d
    name:=fmt.tprintf("%s: %s",d.actors[a].label,d.components[k].name)
    dome,reason:=dome_image(c,k)
    switch {
    case reason!="":warn(c,"%s encloses the level as its sky and is not drawn: %s, so the Sky of the scene is Mirai's sky",name,reason)
    case c.dome.found:warn(c,"%s encloses the level as its sky and is not drawn: the image of the Sky is that of %s",name,c.dome.name)
    case:
        dome.name=name
        c.dome=dome
    }
}

// What the dome k gives the Sky, or why it gives nothing.
@(private)
dome_image :: proc(c:^Context,k:int) -> (dome:Sky_Dome,reason:string) {
    d:=c.d
    ref:=d.components[k].ref
    overrides:=level.paths_of(d,ref,"OverrideMaterials")
    own:=mesh_slot_paths(c,level.path_of(d,ref,"StaticMesh"),false)
    path:=""
    for i in 0..<max(len(own),len(overrides)) {
        slot:=i<len(overrides) && overrides[i]!="" ? overrides[i] : (i<len(own) ? own[i] : "")
        if slot=="" {continue}
        if path!="" && slot!=path {return {},"its slots show different materials"}
        path=slot
    }
    library_lock(c)
    defer library_unlock(c)
    object,found:=material.object_find(c.lib,path)
    if !found {return {},"its material could not be read"}
    t,error:=material.translate(c.lib,object,{reads=c.texture_reads[:],writers=c.writers},context.temp_allocator)
    if error.code!=.None {return {},"its material could not be translated"}
    defer material.translated_destroy(&t)
    geometry,world,why:=dome_mesh(c,k)
    if why!="" {return {},why}
    if texture,set,luminance,plain:=material.translated_plain_emission(&t);plain {
        if turn,lat_long:=lat_long_turn(&geometry,set,world);lat_long {
            return {texture=strings.clone(texture,context.temp_allocator),luminance=luminance,turn=turn,found=true},""
        }
    }
    s,graph_error:=material.sky_graph(c.lib,object,{},context.temp_allocator)
    if graph_error.code!=.None {return {},"its material could not be translated"}
    if s.why!="" {return {},s.why}
    return {material=strings.clone(path,context.temp_allocator),component=k,luminance={1,1,1},found=true},""
}

// The mesh of the dome k, decoded, and its place; why it cannot be read.
// The library is taken.
@(private)
dome_mesh :: proc(c:^Context,k:int) -> (geometry:unreal_mesh.Mesh,world:mm.Transform,why:string) {
    d:=c.d
    mesh_object,mesh_found:=material.object_find(c.lib,level.path_of(d,d.components[k].ref,"StaticMesh"))
    if !mesh_found {return {},{},"its mesh could not be read"}
    source,read_error:=unreal_mesh.mesh_read(&mesh_object.pkg.p,mesh_object.export,.Lod0,context.temp_allocator)
    if read_error.code!=.None {return {},{},"its mesh could not be read"}
    textures,_:=decoder(c)
    decode_error:unreal.Error
    geometry,decode_error=unreal_mesh.mesh_decode(&mesh_object.pkg.p,&source,textures,context.temp_allocator,context.temp_allocator)
    if decode_error.code!=.None {return {},{},"its mesh could not be read"}
    world_error:unreal.Error
    world,world_error=level.component_world(d,k)
    if world_error.code!=.None {return {},{},"its place could not be read"}
    return
}

// The turn about up of a Sky whose image lies over the sphere as the uv set
// of mesh m placed at world lays it: the v of each corner is the angle of its
// direction from up over π, and its u the angle about up over 2π (as the Sky
// reads its image) plus that turn over 2π, within DOME_UV_TOLERANCE. The
// directions are from the centre of its bounds.
@(private)
lat_long_turn :: proc(m:^unreal_mesh.Mesh,set:int,world:mm.Transform) -> (turn:f32,ok:bool) {
    if set<0 || set>=m.uv_count || len(m.corner_uvs[set])!=len(m.corner_vertex) {return}
    // Unreal's x, y and z in centimetres are Mirai's -z, x and y in metres.
    placed :: proc(world:mm.Transform,p:[3]f32) -> [3]f32 {return mm.transform_point(world,[3]f32{p.y,p.z,-p.x}/100)}
    centre:=placed(world,(m.bounds_min+m.bounds_max)/2)
    directions:=make([][3]f32,len(m.positions),context.temp_allocator)
    for p,i in m.positions {
        directions[i]=linalg.normalize0(placed(world,p)-centre)
        if directions[i]=={} {return}
    }
    around :: proc(d:[3]f32) -> f64 {return math.atan2(f64(d.z),f64(d.x))/(2*math.PI)+0.5}
    uvs:=m.corner_uvs[set]
    sum:[2]f64
    for vertex,i in m.corner_vertex {
        d:=directions[vertex]
        if abs(f64(uvs[i].y)-math.acos(clamp(f64(d.y),-1,1))/math.PI)>DOME_UV_TOLERANCE {return}
        if 1-d.y*d.y<DOME_POLE_SINE*DOME_POLE_SINE {continue}
        angle:=2*math.PI*(f64(uvs[i].x)-around(d))
        sum+={math.cos(angle),math.sin(angle)}
    }
    if sum=={} {return}
    turned:=math.atan2(sum.y,sum.x)
    for vertex,i in m.corner_vertex {
        d:=directions[vertex]
        if 1-d.y*d.y<DOME_POLE_SINE*DOME_POLE_SINE {continue}
        gap:=f64(uvs[i].x)-around(d)-turned/(2*math.PI)
        if abs(gap-math.round(gap))>DOME_UV_TOLERANCE {return}
    }
    return f32(turned),true
}

// The .tex of what the material of dome shows in each direction from the
// centre of its bounds (material.sky_shade), a latitude-longitude image as
// the Sky reads it without a turn; zero, with a warning, when it cannot be
// written. What changes with time is shown at time 0, and the values a
// Blueprint gave a dynamic instance as the level was built stay as saved:
// both are warnings.
@(private)
dome_sky_write :: proc(c:^Context,dome:^Sky_Dome) -> (id:base.Asset_Id) {
    defer images_trim(c)
    library_lock(c)
    defer library_unlock(c)
    object,found:=material.object_find(c.lib,dome.material)
    geometry,world,why:=dome_mesh(c,dome.component)
    if !found || why!="" {
        warn(c,"%s: its sky could not be read again",dome.name)
        return
    }
    s,error:=material.sky_graph(c.lib,object,{dome_pixels,c},context.temp_allocator)
    if error.code!=.None || s.why!="" {
        warn(c,"%s: its sky could not be shaded",dome.name)
        return
    }
    width:=DOME_SMOOTH_WIDTH
    if s.widest>0 {
        width=DOME_TEXTURED_WIDTH
        for width<s.widest && width<DOME_MAX_WIDTH {width*=2}
    }
    texels:=dome_shade(&geometry,world,&s,width)
    // Under the horizon, toward the lower hemisphere of the sky light, as a cube of it.
    below:=c.sky_below
    height:=width/2
    for row in height/2..<height {
        for &texel in texels[row*width:][:width] {texel.rgb+=(below.rgb-texel.rgb)*below.a}
    }
    source:=textures.Source{texels=mem.slice_to_bytes(texels),width=width,height=height,layers=1,format=.RGBA32F}
    owner:=c.d.actors[c.d.components[dome.component].actor].label
    write_error:importer.Error
    id,write_error=material_write.sky_made_write(fmt.tprintf("%s_Sky",unreal.asset_name(owner)),source,&c.outputs,"",context.temp_allocator)
    if write_error.code!=.None {
        warn(c,"%s: its sky could not be written: %s",dome.name,write_error.message)
        return {}
    }
    if s.moving {warn(c,"%s: its material changes with time; the image of the Sky is what it shows at time 0",dome.name)}
    if material.object_class(object)=="MaterialInstanceDynamic" && len(s.instance)>0 {
        warn(c,"%s: a Blueprint gave its dynamic material %s as the level was built; the image of the Sky keeps them as saved and does not follow what changes them as the game runs",dome.name,strings.join(s.instance,", ",context.temp_allocator))
    }
    return
}

// The texels of a texture the material of a dome samples, from the textures
// of the level (with its library taken).
@(private)
dome_pixels :: proc(data:rawptr,path:string) -> ^material.Pixels {
    c:=(^Context)(data)
    textures,ready:=decoder(c)
    if !ready {return nil}
    return material_write.source_pixels(&c.images,path,textures)
}

// What s shows in each direction from the centre of the bounds of mesh m
// placed at world: a latitude-longitude image width texels across, rows from
// up, of linear RGBA. Each texel averages DOME_SAMPLES² directions; one whose
// directions all miss the mesh (below an open dome) takes the nearest texel
// of its column that one meets.
@(private)
dome_shade :: proc(m:^unreal_mesh.Mesh,world:mm.Transform,s:^material.Sky_Graph,width:int) -> [][4]f32 {
    height:=width/2
    columns,rows:=width*DOME_SAMPLES,height*DOME_SAMPLES
    // Unreal's x, y and z in centimetres are Mirai's -z, x and y in metres.
    placed :: proc(world:mm.Transform,p:[3]f32) -> [3]f32 {return mm.transform_point(world,[3]f32{p.y,p.z,-p.x}/100)}
    unreal_of :: proc(p:[3]f32) -> [3]f32 {return [3]f32{-p.z,p.x,p.y}*100}
    centre:=placed(world,(m.bounds_min+m.bounds_max)/2)
    corners:=make([][3]f32,len(m.positions),context.temp_allocator)
    radius:f32
    for p,i in m.positions {
        corners[i]=placed(world,p)-centre
        radius=max(radius,linalg.length(corners[i]))
    }
    view:=material.Sky_View{eye=unreal_of(centre),radius=radius*100,pivot=unreal_of(world.position),bounds={m.bounds_min,m.bounds_max}}
    // Unreal's local axes in the world, each as long as the scale along it.
    for axis in 0..<3 {
        local:[3]f32
        local[axis]=1
        mirai:=[3]f32{local.y,local.z,-local.x}*world.scale
        view.axes[axis]=unreal_of(mm.quat_rotate(world.rotation,mirai))/100
    }
    direction :: proc(column,row,columns,rows:int) -> [3]f32 {
        theta:=(f32(row)+0.5)/f32(rows)*math.PI
        phi:=((f32(column)+0.5)/f32(columns)-0.5)*2*math.PI
        return {math.sin(theta)*math.cos(phi),math.cos(theta),math.sin(theta)*math.sin(phi)}
    }
    texel_of :: proc(d:[3]f32,columns,rows:int) -> [2]f32 {
        return {(math.atan2(d.z,d.x)/(2*math.PI)+0.5)*f32(columns),math.acos(clamp(d.y,-1,1))/math.PI*f32(rows)}
    }
    // Each triangle by the rows of texels its directions may cross, and the
    // columns of directions they may cross.
    triangles:=len(m.corner_vertex)/3
    bands:=make([][dynamic]i32,height,context.temp_allocator)
    for &band in bands {band.allocator=context.temp_allocator}
    spans:=make([][2]f32,triangles,context.temp_allocator)
    for triangle in 0..<triangles {
        v:[3][3]f32
        for k in 0..<3 {v[k]=corners[m.corner_vertex[3*triangle+k]]}
        at:[3][2]f32
        for k in 0..<3 {at[k]=texel_of(linalg.normalize0(v[k]),columns,rows)}
        low,high:=min(at[0].y,at[1].y,at[2].y),max(at[0].y,at[1].y,at[2].y)
        left,right:=min(at[0].x,at[1].x,at[2].x),max(at[0].x,at[1].x,at[2].x)
        // Across the seam behind, its columns wrap.
        if right-left>f32(columns)/2 {
            for &p in at {if p.x<f32(columns)/2 {p.x+=f32(columns)}}
            left,right=min(at[0].x,at[1].x,at[2].x),max(at[0].x,at[1].x,at[2].x)
        }
        // Its edges bow toward a pole between the corners; around one it spans every column.
        pad:=(high-low)*0.25+2
        low,high=low-pad,high+pad
        across:=(right-left)*0.25+2
        left,right=left-across,right+across
        for pole in ([2][3]f32{{0,1,0},{0,-1,0}}) {
            if _,_,hit:=ray_triangle(pole,v[0],v[1],v[2]);hit {
                left,right=0,f32(columns)
                if pole.y>0 {low=0} else {high=f32(rows)}
            }
        }
        if right-left>f32(columns) {left,right=0,f32(columns)}
        spans[triangle]={left,right}
        for band in max(int(low)/DOME_SAMPLES,0)..=min(int(high)/DOME_SAMPLES,height-1) {append(&bands[band],i32(triangle))}
    }
    out:=make([][4]f32,width*height,context.temp_allocator)
    met:=make([]bool,width*height,context.temp_allocator)
    Hit :: struct {triangle:i32,b:[2]f32,t:f32}
    hits:=make([]Hit,columns*DOME_SAMPLES,context.temp_allocator)
    points:=make([dynamic]material.Sky_Point,0,len(hits),context.temp_allocator)
    shaded:=make([][3]f32,len(hits),context.temp_allocator)
    for band in 0..<height {
        for &h in hits {h={triangle=-1,t=max(f32)}}
        for triangle in bands[band] {
            v:[3][3]f32
            for k in 0..<3 {v[k]=corners[m.corner_vertex[3*int(triangle)+k]]}
            span:=spans[triangle]
            for row in 0..<DOME_SAMPLES {
                for at in int(math.floor(span.x))..<int(math.ceil(span.y)) {
                    column:=((at%columns)+columns)%columns
                    h:=&hits[row*columns+column]
                    t,b,hit:=ray_triangle(direction(column,band*DOME_SAMPLES+row,columns,rows),v[0],v[1],v[2])
                    if hit && t<h.t {h^={triangle,b,t}}
                }
            }
        }
        clear(&points)
        for h in hits {
            if h.triangle<0 {continue}
            weights:=[3]f32{1-h.b.x-h.b.y,h.b.x,h.b.y}
            point:material.Sky_Point
            normal:[3]f32
            point.color={1,1,1,1}
            if len(m.corner_color)>0 {point.color={}}
            for k in 0..<3 {
                corner:=3*int(h.triangle)+k
                w:=weights[k]
                point.position+=(corners[m.corner_vertex[corner]]+centre)*w
                if corner<len(m.corner_normal) {normal+=m.corner_normal[corner]*w}
                for set in 0..<min(m.uv_count,material.UNREAL_UV_SETS) {
                    if corner<len(m.corner_uvs[set]) {point.uvs[set]+=m.corner_uvs[set][corner]*w}
                }
                if corner<len(m.corner_color) {
                    rgba:=m.corner_color[corner]
                    point.color+=[4]f32{f32(rgba.r),f32(rgba.g),f32(rgba.b),f32(rgba.a)}/255*w
                }
            }
            point.position=unreal_of(point.position)
            point.normal=linalg.normalize0(unreal_of(mm.quat_rotate(world.rotation,[3]f32{normal.y,normal.z,-normal.x})))
            append(&points,point)
        }
        material.sky_shade(s,view,points[:],shaded)
        next:=0
        for h,i in hits {
            if h.triangle<0 {continue}
            texel:=band*width+(i%columns)/DOME_SAMPLES
            out[texel]+=[4]f32{shaded[next].r,shaded[next].g,shaded[next].b,1}
            met[texel]=true
            next+=1
        }
    }
    for &texel in out {if texel.a>0 {texel=[4]f32{texel.r/texel.a,texel.g/texel.a,texel.b/texel.a,1}}}
    for column in 0..<width {
        for row in 0..<height {
            if met[row*width+column] {continue}
            for gap in 1..<height {
                if above:=row-gap;above>=0 && met[above*width+column] {out[row*width+column]=out[above*width+column];break}
                if below:=row+gap;below<height && met[below*width+column] {out[row*width+column]=out[below*width+column];break}
            }
        }
    }
    return out
}

// Where the ray from the origin along d meets the triangle a, b, c: its
// distance along d and the weights of b and c there.
@(private)
ray_triangle :: proc(d,a,b,c:[3]f32) -> (t:f32,weights:[2]f32,hit:bool) {
    ab,ac:=b-a,c-a
    p:=linalg.cross(d,ac)
    det:=linalg.dot(ab,p)
    if abs(det)<1e-12 {return}
    inverse:=1/det
    s:=-a
    u:=linalg.dot(s,p)*inverse
    if u<0 || u>1 {return}
    q:=linalg.cross(s,ab)
    v:=linalg.dot(d,q)*inverse
    if v<0 || u+v>1 {return}
    t=linalg.dot(ac,q)*inverse
    return t,{u,v},t>0
}

// The .tex of the sky of the Unreal texture at path (material_write.sky_write),
// with the images of the materials; zero, with a warning, when it cannot be
// written.
@(private)
sky_image_write :: proc(c:^Context,path:string,below:[4]f32) -> (id:base.Asset_Id,ok:bool) {
    package_name,_:=object_split(path)
    file:=package_file(c,package_name)
    if file=="" {
        warn(c,"the texture %s of the sky is not under the mounts of the level",path)
        return
    }
    textures,_:=decoder(c)
    error:importer.Error
    id,error=material_write.sky_write(c.lib,path,below,&c.outputs,package_prefix(c,file),c.options,context.temp_allocator,&c.images,&c.library_lock,textures)
    defer images_trim(c)
    if error.code!=.None {
        warn(c,"the sky of the texture %s could not be written: %s",path,error.message)
        return
    }
    return id,id!={}
}

// The look of the level where no volume is, the sky of the scene, what is
// behind it, and one sun: the brightest, the others turned off.
@(private)
environment_finish :: proc(c:^Context) {
    if c.failed {return}
    post_process_base(c)
    if len(c.suns)>1 {
        brightest:=0
        for sun,i in c.suns {if sun.brightness>c.suns[brightest].brightness {brightest=i}}
        previous:=c.section
        for sun,i in c.suns {
            if i==brightest {continue}
            section_use(c,sun.section)
            component_off(c,sun.entity,"Sun")
        }
        section_use(c,previous)
        warn(c,"%d directional lights: Mirai lights with one sun, the brightest; the others are turned off",len(c.suns))
    }
    // A sky light that captures the scene lights by the dome of the level
    // times its LightColor and Intensity: the Sky is the image of the dome at
    // that luminance. A cube it names wins over the dome.
    if c.dome.found {
        switch {
        case !c.sky_lit:warn(c,"%s encloses the level as its sky and is not drawn: without a sky light Unreal's sky gives no light, and Mirai's Sky lights by what it shows",c.dome.name)
        case c.sky.image!={}:warn(c,"%s encloses the level as its sky and is not drawn: the Sky lights from the cube of the sky light, as Unreal does, and shows it",c.dome.name)
        case:
            image:base.Asset_Id
            if c.dome.texture!="" {image,_=sky_image_write(c,c.dome.texture,{})} else {image=dome_sky_write(c,&c.dome)}
            if image=={} {
                warn(c,"%s encloses the level as its sky and is not drawn: its image could not be written",c.dome.name)
                break
            }
            c.sky.image=image
            if c.sky.luminance!={1,1,1} {warn(c,"%s: Mirai's Sky shows what it lights by, so behind the scene the dome shows at %v times what Unreal draws: the LightColor times Intensity of the sky light, by which Unreal lights from it",c.dome.name,c.sky.luminance)}
            c.sky.luminance*=c.dome.luminance
            c.sky_turn=c.dome.turn
            warn(c,"%s encloses the level as its sky and is not drawn: its image is the Sky's, which shows it behind the scene",c.dome.name)
        }
    }
    if c.sky_captured && c.sky.image=={} {warn(c,"Unreal captures the light of the sky from the scene; Mirai's sky gives it at %.3g times its luminance",max(c.sky.luminance.r,c.sky.luminance.g,c.sky.luminance.b))}
    if c.sky_lit && c.sky.image=={} {
        sun:=render.SUN_DEFAULT.illuminance
        if len(c.suns)>0 {
            sun=0
            for candidate in c.suns {sun=max(sun,candidate.brightness)}
        }
        c.sky.luminance*=render.SKY_DEFAULT.luminance/render.SUN_DEFAULT.illuminance*sun
    }
    // Without a sky light no light comes from the sky: the scene has no Sky,
    // and behind it is black, as Unreal draws it without an atmosphere.
    if !c.sky_lit {
        if c.sky_atmosphere {warn(c,"the level draws an atmosphere without a sky light: Mirai's Sky lights from the air it draws, so the scene has no Sky")}
        return
    }
    // Behind the scene Unreal draws the sky of its atmosphere, or black; an
    // atmosphere is Mirai's, lit by the sun.
    c.sky.use_background=!c.sky_drawn
    c.sky.background={}
    // Unreal lights from the cube its sky light names over its atmosphere; Mirai's
    // atmosphere replaces the image, so the cube wins.
    c.sky.atmosphere=c.sky_atmosphere && c.sky.image=={}
    if c.sky_atmosphere && !c.sky.atmosphere {warn(c,"the sky lights from an image: Mirai's sky draws an image or the air, so the atmosphere of the level is not drawn")}
    place:=mm.TRANSFORM_IDENTITY
    place.rotation=mm.quat_axis_angle({0,1,0},c.sky_turn)
    if e,ok:=entity_make(c,0,"Sky","Sky",place);ok {component_set(c,e,"Sky",&c.sky)}
}

// The air of a SkyAtmosphereComponent, whose coefficients are 1/km as
// Mirai's: each color times its scale. Its ozone layer is that of the Earth.
@(private)
atmosphere_air :: proc(d:^level.Document,ref:level.Ref) -> render.Air {
    air:=render.AIR_DEFAULT
    real :: proc(d:^level.Document,ref:level.Ref,name:string,default:f32) -> f32 {
        value,_:=level.real_of(d,ref,name,f64(default))
        return f32(value)
    }
    scaled :: proc(d:^level.Document,ref:level.Ref,color,scale:string,default_color:[3]f32,default_scale:f32) -> [3]f32 {
        tint,_:=color_of(d,ref,color,default_color)
        return tint*real(d,ref,scale,default_scale)
    }
    air.planet_radius=real(d,ref,"BottomRadius",6360)
    air.thickness=real(d,ref,"AtmosphereHeight",60)
    air.ground_albedo,_=color_of(d,ref,"GroundAlbedo",mm.srgb_to_linear([3]f32{170,170,170}/255))
    air.rayleigh=scaled(d,ref,"RayleighScattering","RayleighScatteringScale",{0.175287,0.409607,1},0.0331)
    air.rayleigh_height=real(d,ref,"RayleighExponentialDistribution",8)
    air.mie=scaled(d,ref,"MieScattering","MieScatteringScale",{1,1,1},0.003996)
    air.mie_absorption=scaled(d,ref,"MieAbsorption","MieAbsorptionScale",{1,1,1},0.000444)
    air.mie_anisotropy=real(d,ref,"MieAnisotropy",0.8)
    air.mie_height=real(d,ref,"MieExponentialDistribution",1.2)
    air.ozone=scaled(d,ref,"OtherAbsorption","OtherAbsorptionScale",{0.345561,1,0.045189},0.001881)
    return air
}
