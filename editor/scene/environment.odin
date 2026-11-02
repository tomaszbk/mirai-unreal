package unreal_scene

import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import material_write "project:plugins/unreal/editor/material/write"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import gpu "mirai:render"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"

// Cameras, the light of the sky, the sun and the exposure: what of Unreal's
// has a physical equivalent in Mirai. A camera is its vertical field of view
// and its exposure; a sky light, Mirai's sky at its intensity, with the image
// of its cubemap when it names one; a post process
// volume, a View_Volume with its exposure where its box is, or everywhere
// when it is unbound. The rest is a warning.

// The camera of a component on an entity under its actor that has the label
// of the actor, as mirai capture --camera-entity names it. Unreal's camera
// looks along +X with +Z up; Mirai's along -Z with +Y up.
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
    e:=component_entity(c,a,k,FACING,{1,1,1},d.actors[a].label) or_return
    if !component_set(c,e,"Camera",&camera) {return false}
    settings:=struct_chain(d,ref,"PostProcessSettings")
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

// The exposure of post process settings, from what they override; any is
// false when they override none of it. aperture, when not zero, is that of
// the lens of a cine camera, which Unreal takes as the f-number.
@(private)
exposure_from :: proc(c:^Context,s:^Struct_Chain,aperture:f32) -> (e:render.Exposure,any:bool) {
    e=render.EXPOSURE_DEFAULT
    overridden :: proc(s:^Struct_Chain,name:string) -> bool {return chain_bool(s,strings.concatenate({"bOverride_",name},context.temp_allocator))}
    if overridden(s,"AutoExposureMethod") {
        any=true
        if chain_enum(s,"AutoExposureMethod","AEM_Histogram")=="AEM_Manual" {e.mode=.Manual}
    }
    if overridden(s,"AutoExposureBias") {
        any=true
        bias,_:=chain_real(s,"AutoExposureBias",1)
        e.compensation=f32(bias)
    }
    // Unreal exposes so that this brightness is white (1), where Mirai's meter
    // puts middle gray: the EV100 that gives that luminance white. It is an
    // EV100 of Unreal's when the project has the extended range (luminance
    // luminance_max·2^EV100), else a luminance.
    ev100 :: proc(c:^Context,value:f64) -> f32 {
        white:=c.extended_luminance?c.luminance_max*math.pow(2,value):value
        return f32(math.log2(max(white,1e-6)*f64(gpu.MIDDLE_GRAY)*100/f64(gpu.LIGHT_METER_K)))
    }
    if overridden(s,"AutoExposureMinBrightness") {
        any=true
        v,_:=chain_real(s,"AutoExposureMinBrightness",0)
        e.min_ev100=ev100(c,v)
    }
    if overridden(s,"AutoExposureMaxBrightness") {
        any=true
        v,_:=chain_real(s,"AutoExposureMaxBrightness",0)
        e.max_ev100=ev100(c,v)
    }
    if overridden(s,"AutoExposureSpeedDown") {
        any=true
        // Unreal changes as many EV a second, three times faster toward more light.
        speed,_:=chain_real(s,"AutoExposureSpeedDown",1)
        e.adaptation_mode=.Speed
        e.adaptation=f32(1/max(speed,1e-3))
    }
    // A manual exposure is that of a physical camera: f-number, shutter and ISO.
    stop,_:=chain_real(s,"DepthOfFieldFstop",4)
    if aperture>0 && !overridden(s,"DepthOfFieldFstop") {stop=f64(aperture)}
    shutter,_:=chain_real(s,"CameraShutterSpeed",60)
    iso,_:=chain_real(s,"CameraISO",100)
    e.aperture,e.shutter,e.iso=f32(max(stop,0.1)),f32(1/max(shutter,1e-3)),f32(max(iso,1))
    if overridden(s,"AutoExposureApplyPhysicalCameraExposure") && !chain_bool(s,"AutoExposureApplyPhysicalCameraExposure") {
        // EV100 zero: the bias alone.
        e.aperture,e.shutter,e.iso=1,1,100
    }
    if e.mode==.Manual && (overridden(s,"DepthOfFieldFstop") || overridden(s,"CameraShutterSpeed") || overridden(s,"CameraISO")) {any=true}
    return
}

// The settings of a post process volume that Mirai has an equivalent for.
@(private)
EXPOSURE_SETTINGS :: []string{
    "AutoExposureMethod","AutoExposureBias","AutoExposureMinBrightness","AutoExposureMaxBrightness","AutoExposureSpeedUp",
    "AutoExposureSpeedDown","AutoExposureApplyPhysicalCameraExposure","CameraShutterSpeed","CameraISO","DepthOfFieldFstop",
}

// A post process volume is a View_Volume with the exposure it overrides, by
// its priority, over its blend radius: in its box when it is bound, which a
// CubeBuilder gives, and everywhere otherwise. What is not exposure is a
// warning.
@(private)
post_process_add :: proc(c:^Context,a:int) {
    d:=c.d
    ref:=d.actors[a].ref
    label:=d.actors[a].label
    unbound,_:=level.bool_of(d,ref,"bUnbound",false)
    priority,_:=level.real_of(d,ref,"Priority",0)
    blend,_:=level.real_of(d,ref,"BlendRadius",100)
    place:=volume.Volume{priority=i32(math.round(priority)),blend=max(f32(blend)/100,0)}
    if !unbound {
        builder:=-1
        for k in d.actors[a].first_component..<d.actors[a].first_component+d.actors[a].component_count {
            if d.components[k].class.name=="CubeBuilder" {builder=k;break}
        }
        if builder<0 {
            warn(c,"%s: a post process volume whose brush is not the box of a CubeBuilder; its brush is not read",label)
            return
        }
        // Unreal's X, Y and Z are Mirai's Z, X and Y.
        x,_:=level.real_of(d,d.components[builder].ref,"X",200)
        y,_:=level.real_of(d,d.components[builder].ref,"Y",200)
        z,_:=level.real_of(d,d.components[builder].ref,"Z",200)
        place.shape,place.extents=.Box,{f32(y)/200,f32(z)/200,f32(x)/200}
    }
    settings:=struct_chain(d,ref,"Settings")
    others:=make([dynamic]string,context.temp_allocator)
    for i in 0..<settings.count {
        p:=settings.packages[i]
        for &item in settings.lists[i].items {
            name:=unreal.name_plain(p,item.name)
            if !strings.has_prefix(name,"bOverride_") {continue}
            v,error:=unreal.property_value(p,&item)
            if error.code!=.None || v.kind!=.Boolean || !v.boolean {continue}
            setting:=name[len("bOverride_"):]
            if !slice.contains(EXPOSURE_SETTINGS,setting) && !slice.contains(others[:],setting) {append(&others,setting)}
        }
    }
    if len(others)>0 {
        shown:=others[:min(len(others),8)]
        warn(c,"%s: %d post process settings have no equivalent in Mirai: %s%s",label,len(others),strings.join(shown,", ",context.temp_allocator),len(others)>8?", ...":"")
    }
    exposure,any:=exposure_from(c,&settings,0)
    if !any {return}
    look:=render.View_Volume{exposure=exposure,tint={1,1,1}}
    world,_,error:=level.actor_world(d,a)
    if error.code!=.None {return}
    if place.shape==.Box {place.extents=blend_beyond(place.extents,place.blend,world.scale)}
    e,made:=entity_make(c,0,actor_key(c,a),label,world)
    if !made || !component_set(c,e,"View_Volume",&look) {return}
    if place.shape!=.Unbounded || place.priority!=0 {component_set(c,e,"Volume",&place)}
}

// Unreal blends a bound volume over its blend radius beyond its brush, and
// Mirai over its blend inside its border: the box grows by the radius, in
// metres of the world whatever the scale of the actor, so the look ends
// where Unreal's ends and is whole inside the brush.
@(private)
blend_beyond :: proc "contextless" (extents:[3]f32,blend:f32,scale:[3]f32) -> (grown:[3]f32) {
    for axis in 0..<3 {
        grown[axis]=extents[axis]
        if s:=abs(scale[axis]);s>0 {grown[axis]+=blend/s}
    }
    return
}

// A sky light lights from Mirai's sky at its intensity: Unreal captures it
// from what the scene shows far away, which has no equivalent. Its luminance
// keeps to the sun of the level what Mirai's sky keeps to its sun
// (environment_finish): a level lit in small numbers gets a sky in them too.
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
    if c.sky.image,_=sky_image_write(c,cubemap);c.sky.image=={} {
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

// The .tex of the sky of the Unreal cube texture at path, with the images
// of the materials; zero, with a warning, when it cannot be written.
@(private)
sky_image_write :: proc(c:^Context,path:string) -> (id:base.Asset_Id,ok:bool) {
    package_name,_:=object_split(path)
    file:=package_file(c,package_name)
    if file=="" {
        warn(c,"its cubemap %s is not under the mounts of the level",path)
        return
    }
    folder:=project.path(c.assets,"materials",allocator=context.temp_allocator)
    textures,_:=decoder(c)
    report:importer.Import_Report
    error:importer.Error
    id,report,error=material_write.sky_write(c.lib,path,file,folder,c.options,c.report.allocator,&c.images,&c.library_lock,textures)
    defer images_trim(c)
    if error.code!=.None {
        warn(c,"the sky of the cubemap %s could not be written: %s",path,error.message)
        return
    }
    importer.report_take(&c.outputs.report,&report)
    return id,id!={}
}

// The sky of the scene, what is behind it, and one sun: the brightest, the
// others turned off.
@(private)
environment_finish :: proc(c:^Context) {
    if c.failed {return}
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
    if c.sky_lit {
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

// The default of r.EyeAdaptation.LensAttenuation, at which Unreal's LuminanceMax is 1.
@(private)
UNREAL_LENS_ATTENUATION :: 0.78

// How the auto exposure of the project of the level reads its brightness:
// in EV100 when r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange is
// on, which UE5 projects turn on and UE4 ones leave off, with the luminance
// of EV100 0 (LuminanceMax, from r.EyeAdaptation.LensAttenuation).
luminance_range :: proc(mounts:[]unreal.Source_Mount,p:^unreal.Package) -> (extended:bool,luminance_max:f64) {
    extended=p.summary.version_ue5>0
    attenuation:=f64(UNREAL_LENS_ATTENUATION)
    if text:=unreal.project_config_read(mounts,"DefaultEngine.ini");text!="" {
        for line in strings.split_lines(text,context.temp_allocator) {
            trimmed:=strings.trim_space(line)
            EXTENDED :: "r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange="
            ATTENUATION :: "r.EyeAdaptation.LensAttenuation="
            if strings.has_prefix(trimmed,EXTENDED) {
                value:=strings.to_lower(strings.trim_space(trimmed[len(EXTENDED):]),context.temp_allocator)
                extended=value=="true" || value=="1"
            } else if strings.has_prefix(trimmed,ATTENUATION) {
                if value,ok:=strconv.parse_f64(strings.trim_space(trimmed[len(ATTENUATION):]));ok && value>0 {attenuation=value}
            }
        }
    }
    luminance_max=f64(UNREAL_LENS_ATTENUATION)/attenuation
    return
}

