package unreal_scene

import "core:math"
import importer "mirai:cook/import"
import material_write "project:plugins/unreal/editor/material/write"
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
    source,_:=level.enum_of(d,ref,"SourceType","SLS_CapturedScene")
    if source!="SLS_SpecifiedCubemap" {
        warn(c,"%s: Unreal captures the light of the sky from the scene; Mirai's sky gives it at %.3g times its luminance",label,intensity)
        return true
    }
    cubemap:=level.path_of(d,ref,"Cubemap")
    if cubemap=="" {
        warn(c,"%s: it lights from a cubemap it does not name; the sky is Mirai's gradient at %.3g times its luminance",label,intensity)
        return true
    }
    below:=[4]f32{0,0,0,1}
    if f,error:=level.property(d,ref,"LowerHemisphereColor");error.code==.None && f.property!=nil {
        if v,value_error:=unreal.property_value(f.pkg,f.property);value_error.code==.None && v.kind==.Real_Vector && v.vector_count==4 {
            below={f32(v.vector[0]),f32(v.vector[1]),f32(v.vector[2]),f32(v.vector[3])}
        }
    }
    if black,_:=level.bool_of(d,ref,"bLowerHemisphereIsBlack",true);!black {below.a=0}
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

// The .tex of the sky of the Unreal cube texture at path, its lower half
// toward below, with the images of the materials; zero, with a warning,
// when it cannot be written.
@(private)
sky_image_write :: proc(c:^Context,path:string,below:[4]f32) -> (id:base.Asset_Id,ok:bool) {
    package_name,_:=object_split(path)
    file:=package_file(c,package_name)
    if file=="" {
        warn(c,"its cubemap %s is not under the mounts of the level",path)
        return
    }
    textures,_:=decoder(c)
    error:importer.Error
    id,error=material_write.sky_write(c.lib,path,below,&c.outputs,package_prefix(c,file),c.options,context.temp_allocator,&c.images,&c.library_lock,textures)
    defer images_trim(c)
    if error.code!=.None {
        warn(c,"the sky of the cubemap %s could not be written: %s",path,error.message)
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
    if c.sky_atmosphere && !c.sky.atmosphere {warn(c,"the sky lights from the image of the cube of its sky light: Mirai's sky draws one or the other, so the atmosphere of the level is not drawn")}
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
