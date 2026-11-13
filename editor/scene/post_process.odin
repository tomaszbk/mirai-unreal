package unreal_scene

import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:std/base"

// The post process of a level as Unreal blends it: the defaults of its
// project everywhere, and over them each enabled volume by its priority with
// what it overrides, by its blend weight. The look where no volume is, those
// defaults, is a View_Volume of the whole world under every other (and the
// Lens_Volume of the lens bridge on its entity); a volume is a View_Volume
// where its box is, or everywhere when it is unbound, holding what it
// overrides over what the unbound volumes below it and the defaults give.
// Its exposure is the Exposure of the view and its saturation and contrast,
// a layer of the engine's ColorGrade. What has no equivalent is a warning.

// What the project of the level makes the defaults of its post process
// (DefaultEngine.ini), which Unreal applies with or without a volume.
Post_Defaults :: struct {
    extended:bool,      // the auto exposure reads EV100 (ExtendDefaultLuminanceRange)
    luminance_max:f64,  // the luminance of its EV100 0 (from LensAttenuation)
    bloom:bool,         // r.DefaultFeature.Bloom
    auto_exposure:bool, // r.DefaultFeature.AutoExposure
    basic:bool,         // r.DefaultFeature.AutoExposure.Method is 1: AEM_Basic
    bias:f64,           // r.DefaultFeature.AutoExposure.Bias
}

// The default of r.EyeAdaptation.LensAttenuation, at which Unreal's LuminanceMax is 1.
@(private)
UNREAL_LENS_ATTENUATION :: 0.78

// The defaults of the post process of the project of the level: UE5
// projects turn on the extended range of the auto exposure, UE4 ones leave
// it off, unless DefaultEngine.ini says otherwise.
post_defaults_read :: proc(mounts:[]unreal.Source_Mount,p:^unreal.Package) -> (defaults:Post_Defaults) {
    defaults={extended=p.summary.version_ue5>0,bloom=true,auto_exposure=true,bias=1}
    attenuation:=f64(UNREAL_LENS_ATTENUATION)
    if text:=unreal.project_config_read(mounts,"DefaultEngine.ini");text!="" {
        for line in strings.split_lines(text,context.temp_allocator) {
            equal:=strings.index_byte(line,'=')
            if equal<0 {continue}
            key:=strings.trim_space(line[:equal])
            value:=strings.to_lower(strings.trim_space(line[equal+1:]),context.temp_allocator)
            on:=value=="true" || value=="1"
            switch key {
            case "r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange":defaults.extended=on
            case "r.DefaultFeature.Bloom":defaults.bloom=on
            case "r.DefaultFeature.AutoExposure":defaults.auto_exposure=on
            case "r.DefaultFeature.AutoExposure.Method":defaults.basic=value=="1"
            case "r.DefaultFeature.AutoExposure.Bias":
                if v,ok:=strconv.parse_f64(value);ok {defaults.bias=v}
            case "r.EyeAdaptation.LensAttenuation":
                if v,ok:=strconv.parse_f64(value);ok && v>0 {attenuation=v}
            }
        }
    }
    defaults.luminance_max=f64(UNREAL_LENS_ATTENUATION)/attenuation
    return
}

// Unreal's default of a setting in the project of the level: a number, a
// vector (xyzw) or the name of an enum value.
setting_default :: proc(c:^Context,name:string) -> (value:[4]f64,text:string) {
    p:=c.post
    switch name {
    case "AutoExposureMethod":return {},p.basic?"AEM_Basic":"AEM_Histogram"
    case "AutoExposureBias":return {p.bias,0,0,0},""
    case "AutoExposureMinBrightness","AutoExposureMaxBrightness":
        // Without auto exposure both are a luminance of one, which the extended range reads as EV100 of 1.2.
        if !p.auto_exposure {return {p.extended?math.log2(1/1.2):1,0,0,0},""}
        if name=="AutoExposureMinBrightness" {return {p.extended?-10:0.03,0,0,0},""}
        return {p.extended?20:8,0,0,0},""
    case "AutoExposureSpeedUp":return {3,0,0,0},""
    case "AutoExposureSpeedDown":return {1,0,0,0},""
    case "AutoExposureApplyPhysicalCameraExposure":return {1,0,0,0},""
    case "CameraShutterSpeed":return {60,0,0,0},""
    case "CameraISO":return {100,0,0,0},""
    case "DepthOfFieldFstop":return {4,0,0,0},""
    case "BloomMethod":return {},"BM_SOG"
    case "BloomIntensity":return {p.bloom?0.675:0,0,0,0},""
    case "BloomGaussianIntensity":return {1,0,0,0},""
    case "Bloom1Tint":return {0.3465,0.3465,0.3465,1},""
    case "Bloom2Tint":return {0.138,0.138,0.138,1},""
    case "Bloom3Tint":return {0.1176,0.1176,0.1176,1},""
    case "Bloom4Tint","Bloom5Tint":return {0.066,0.066,0.066,1},""
    case "Bloom6Tint":return {0.061,0.061,0.061,1},""
    case "VignetteIntensity":return {0.4,0,0,0},""
    case "ColorCorrectionShadowsMax":return {0.09,0,0,0},""
    case "ColorCorrectionHighlightsMin":return {0.5,0,0,0},""
    case "ColorCorrectionHighlightsMax":return {1,0,0,0},""
    }
    if strings.has_prefix(name,"ColorSaturation") || strings.has_prefix(name,"ColorContrast") {return {1,1,1,1},""}
    return
}

// The settings Mirai has an equivalent for, apart from those of the lens.
@(private)
EXPOSURE_SETTINGS :: []string{
    "AutoExposureMethod","AutoExposureBias","AutoExposureMinBrightness","AutoExposureMaxBrightness","AutoExposureSpeedUp",
    "AutoExposureSpeedDown","AutoExposureApplyPhysicalCameraExposure","CameraShutterSpeed","CameraISO","DepthOfFieldFstop",
}

// The parameters of ColorGrade and the settings that give them: the xyz of
// a Vector4 times its w, or a number.
@(private)
GRADE_PARAMETERS :: [?][2]string{
    {"saturation","ColorSaturation"},{"contrast","ColorContrast"},
    {"shadows_saturation","ColorSaturationShadows"},{"shadows_contrast","ColorContrastShadows"},{"shadows_end","ColorCorrectionShadowsMax"},
    {"midtones_saturation","ColorSaturationMidtones"},{"midtones_contrast","ColorContrastMidtones"},
    {"highlights_saturation","ColorSaturationHighlights"},{"highlights_contrast","ColorContrastHighlights"},
    {"highlights_start","ColorCorrectionHighlightsMin"},{"highlights_end","ColorCorrectionHighlightsMax"},
}

// Those the lens plugin translates, through its bridge (unreal_lens): the
// light the bloom scatters and the vignette.
LENS_SETTINGS :: []string{
    "BloomIntensity","BloomGaussianIntensity","Bloom1Tint","Bloom2Tint","Bloom3Tint","Bloom4Tint","Bloom5Tint","Bloom6Tint",
    "VignetteIntensity",
}

// Whether post process settings override a setting.
setting_overridden :: proc(s:^Struct_Chain,name:string) -> bool {
    return chain_bool(s,strings.concatenate({"bOverride_",name},context.temp_allocator))
}

POST_LAYERS :: 8

// Post process settings by their weight, bottom first.
Post_Layer :: struct {settings:Struct_Chain,weight:f64}

// The settings at a place as Unreal blends them: the unbound volumes below
// and, last, the volume or camera they are of; what none overrides is the
// default of the project. A base has no layer.
Post_Settings :: struct {layers:[POST_LAYERS]Post_Layer,count:int}

// An enabled unbound volume of the level.
@(private)
Post_Volume :: struct {actor:int,priority:f64,layer:Post_Layer}

// The enabled unbound volumes of the level by priority, read once.
@(private)
post_unbound :: proc(c:^Context) -> []Post_Volume {
    if c.post_read {return c.post_volumes[:]}
    c.post_read=true
    d:=c.d
    for a in 0..<len(d.actors) {
        if level.actor_native_class(d,a).name!="PostProcessVolume" {continue}
        ref:=d.actors[a].ref
        unbound,_:=level.bool_of(d,ref,"bUnbound",false)
        enabled,_:=level.bool_of(d,ref,"bEnabled",true)
        if !unbound || !enabled {continue}
        priority,_:=level.real_of(d,ref,"Priority",0)
        weight,_:=level.real_of(d,ref,"BlendWeight",1)
        append(&c.post_volumes,Post_Volume{a,priority,{struct_chain(d,ref,"Settings"),clamp(weight,0,1)}})
    }
    slice.stable_sort_by(c.post_volumes[:],proc(x,y:Post_Volume) -> bool {return x.priority<y.priority})
    return c.post_volumes[:]
}

// The settings of what actor a overrides (own, by weight) over the unbound
// volumes Unreal puts below it: those of a lower priority, or before it at
// its own. a is -1 for a camera, over all of them.
post_settings :: proc(c:^Context,a:int,own:Struct_Chain,weight:f64) -> (s:Post_Settings) {
    below:=post_unbound(c)
    if a>=0 {
        priority,_:=level.real_of(c.d,c.d.actors[a].ref,"Priority",0)
        count:=0
        for v in below {
            if v.actor==a || v.priority>priority {break}
            count+=1
        }
        below=below[:count]
    }
    if len(below)>POST_LAYERS-1 {
        warn(c,"%d unbound post process volumes under one place: the %d of the highest priority are kept",len(below),POST_LAYERS-1)
        below=below[len(below)-(POST_LAYERS-1):]
    }
    for v in below {s.layers[s.count]=v.layer;s.count+=1}
    s.layers[s.count]={own,clamp(weight,0,1)}
    s.count+=1
    return
}

// Whether the volume or camera of the settings overrides a setting itself.
post_own :: proc(s:^Post_Settings,name:string) -> bool {
    return s.count>0 && setting_overridden(&s.layers[s.count-1].settings,name)
}

// A number of the settings, as their layers blend it over the default.
post_real :: proc(c:^Context,s:^Post_Settings,name:string) -> f64 {
    v:=post_vector(c,s,name)
    return v[0]
}

// A vector (Vector4, LinearColor) or number of the settings, xyzw.
post_vector :: proc(c:^Context,s:^Post_Settings,name:string) -> (v:[4]f64) {
    v,_=setting_default(c,name)
    for i in 0..<s.count {
        l:=&s.layers[i]
        if !setting_overridden(&l.settings,name) {continue}
        own,found:=chain_vector(&l.settings,name,v)
        if !found {continue}
        v+=(own-v)*l.weight
    }
    return
}

// An enum value of the settings: a layer replaces it past half its weight.
post_enum :: proc(c:^Context,s:^Post_Settings,name:string) -> string {
    _,v:=setting_default(c,name)
    for i in 0..<s.count {
        l:=&s.layers[i]
        if l.weight>=0.5 && setting_overridden(&l.settings,name) {v=chain_enum(&l.settings,name,v)}
    }
    return v
}

// A switch of the settings: a layer replaces it past half its weight.
@(private)
post_bool :: proc(c:^Context,s:^Post_Settings,name:string) -> bool {
    d,_:=setting_default(c,name)
    v:=d[0]!=0
    for i in 0..<s.count {
        l:=&s.layers[i]
        if l.weight>=0.5 && setting_overridden(&l.settings,name) {v=chain_bool(&l.settings,name)}
    }
    return v
}

// The exposure of post process settings; any is false when the volume or
// camera they are of overrides none of it. aperture, when not zero, is that
// of the lens of a cine camera, which Unreal takes as the f-number.
@(private)
exposure_from :: proc(c:^Context,s:^Post_Settings,aperture:f32) -> (e:render.Exposure,any:bool) {
    e=render.EXPOSURE_DEFAULT
    // The physical camera counts when the exposure is manual.
    for setting in EXPOSURE_SETTINGS {
        if setting!="CameraShutterSpeed" && setting!="CameraISO" && setting!="DepthOfFieldFstop" {any||=post_own(s,setting)}
    }
    if post_enum(c,s,"AutoExposureMethod")=="AEM_Manual" {e.mode=.Manual}
    e.compensation=f32(post_real(c,s,"AutoExposureBias"))
    // Unreal exposes so that this brightness is white (1), where Mirai's meter
    // puts middle gray: the EV100 that gives that luminance white. It is an
    // EV100 of Unreal's when the project has the extended range (luminance
    // luminance_max·2^EV100), else a luminance.
    ev100 :: proc(c:^Context,value:f64) -> f32 {
        white:=c.post.extended?c.post.luminance_max*math.pow(2,value):value
        return render.ev100_white(f32(white))
    }
    e.min_ev100=ev100(c,post_real(c,s,"AutoExposureMinBrightness"))
    e.max_ev100=ev100(c,post_real(c,s,"AutoExposureMaxBrightness"))
    // Unreal changes as many EV a second, three times faster toward more light.
    e.adaptation_mode=.Speed
    e.adaptation=f32(1/max(post_real(c,s,"AutoExposureSpeedDown"),1e-3))
    // A manual exposure is that of a physical camera: f-number, shutter and ISO.
    stop:=post_real(c,s,"DepthOfFieldFstop")
    if aperture>0 && !post_own(s,"DepthOfFieldFstop") {stop=f64(aperture)}
    shutter:=post_real(c,s,"CameraShutterSpeed")
    iso:=post_real(c,s,"CameraISO")
    e.aperture,e.shutter,e.iso=f32(max(stop,0.1)),f32(1/max(shutter,1e-3)),f32(max(iso,1))
    // EV100 zero: the bias alone.
    if !post_bool(c,s,"AutoExposureApplyPhysicalCameraExposure") {e.aperture,e.shutter,e.iso=1,1,100}
    if e.mode==.Manual && (post_own(s,"DepthOfFieldFstop") || post_own(s,"CameraShutterSpeed") || post_own(s,"CameraISO")) {any=true}
    return
}

// The layer of ColorGrade of the settings: none when it leaves the image as
// it is; any is false when the volume they are of overrides none of it.
@(private)
grade_from :: proc(c:^Context,s:^Post_Settings) -> (layer:render.Post_Process_Layer,any:bool) {
    parameters:[len(GRADE_PARAMETERS)]asset.Material_Parameter
    identity:=true
    for g,i in GRADE_PARAMETERS {
        any||=post_own(s,g[1])
        p:=&parameters[i]
        base.text_set(p.name[:],g[0])
        p.kind=.Float
        v:=post_vector(c,s,g[1])
        if strings.has_prefix(g[1],"ColorCorrection") {
            p.components,p.value=1,{v[0],0,0,0}
            continue
        }
        p.components,p.value=3,{v.x*v.w,v.y*v.w,v.z*v.w,0}
        identity&&=p.value=={1,1,1,0}
    }
    if identity {return}
    for &known in c.grades {
        if slice.equal(known.parameters[:],parameters[:]) {return {material=known.id,enabled=true},any}
    }
    id,path,info:=asset_place(c,asset.KIND_MATERIAL,"Grade",len(c.grades),".mat")
    m:=asset.MATERIAL_DEFAULTS
    base.text_set(m.program[:],"ColorGrade")
    bytes,error:=asset.material_bytes(c.types,{id=id,info=m,parameters=parameters[:],source=&info},context.temp_allocator)
    if error!=.None {
        warn(c,"the color grade could not be written (%v)",error)
        return
    }
    if !asset_write(c,id,asset.KIND_MATERIAL,"Grade",path,bytes,"ColorGrade") {return}
    append(&c.grades,Grade_Material{parameters,id})
    return {material=id,enabled=true},any
}

// A ColorGrade material the level wrote, by its parameters.
@(private)
Grade_Material :: struct {parameters:[len(GRADE_PARAMETERS)]asset.Material_Parameter,id:base.Asset_Id}

// The entity a post process volume became, its zone and its settings, for
// what a bridge adds to it over the same zone and Volume.
Post_Process :: struct {
    entity:base.Entity_Id,
    zone:volume.Zone,
    settings:Post_Settings,
}

// A post process volume is a View_Volume with the exposure and color grade
// it gives, by its priority, over its blend radius: in its box when it is
// bound, which a CubeBuilder gives, and everywhere otherwise; it holds them
// when it overrides some of them. lens: the caller translates LENS_SETTINGS
// on the entity, which is made for them too; without it they are a warning
// that names the lens plugin. The rest is a warning.
post_process_add :: proc(c:^Context,a:int,lens:=false) -> (p:Post_Process,made:bool) {
    d:=c.d
    ref:=d.actors[a].ref
    label:=d.actors[a].label
    if enabled,_:=level.bool_of(d,ref,"bEnabled",true);!enabled {return}
    unbound,_:=level.bool_of(d,ref,"bUnbound",false)
    priority,_:=level.real_of(d,ref,"Priority",0)
    blend,_:=level.real_of(d,ref,"BlendRadius",100)
    weight,_:=level.real_of(d,ref,"BlendWeight",1)
    look:=render.VIEW_VOLUME_DEFAULT
    look.zone.priority,look.zone.blend=i32(math.round(priority)),max(f32(blend)/100,0)
    place:=volume.world()
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
        place=volume.box({f32(y)/200,f32(z)/200,f32(x)/200})
    }
    own:=struct_chain(d,ref,"Settings")
    others:=make([dynamic]string,context.temp_allocator)
    lensed:=make([dynamic]string,context.temp_allocator)
    for i in 0..<own.count {
        pkg:=own.packages[i]
        for &item in own.lists[i].items {
            name:=unreal.name_plain(pkg,item.name)
            if !strings.has_prefix(name,"bOverride_") {continue}
            v,error:=unreal.property_value(pkg,&item)
            if error.code!=.None || v.kind!=.Boolean || !v.boolean {continue}
            setting:=name[len("bOverride_"):]
            if slice.contains(EXPOSURE_SETTINGS,setting) || grade_setting(setting) {continue}
            into:=slice.contains(LENS_SETTINGS,setting)?&lensed:&others
            if !slice.contains(into[:],setting) {append(into,setting)}
        }
    }
    if len(others)>0 {
        shown:=others[:min(len(others),8)]
        warn(c,"%s: %d post process settings have no equivalent in Mirai: %s%s",label,len(others),strings.join(shown,", ",context.temp_allocator),len(others)>8?", ...":"")
    }
    if len(lensed)>0 && !lens {
        missing:=len(c.translators)>0?"the lens plugin is not in the project":"the lens plugin translates them in an editor session: import the level there (mirai session start, then mirai rpc asset.import with its path)"
        warn(c,"%s: its bloom and vignette (%s) are not translated: %s",label,strings.join(lensed[:],", ",context.temp_allocator),missing)
    }
    p.settings=post_settings(c,a,own,weight)
    exposure,exposed:=exposure_from(c,&p.settings,0)
    grade,graded:=grade_from(c,&p.settings)
    if !exposed && !graded && !(lens && len(lensed)>0) {return}
    world,_,error:=level.actor_world(d,a)
    if error.code!=.None {return}
    if place.shape==.Box {place.extents=blend_beyond(place.extents,look.zone.blend,world.scale)}
    e,entity_made:=entity_make(c,0,actor_key(c,a),label,world)
    if !entity_made {return}
    if exposed || graded {
        look.exposure,look.layers[0]=exposure,grade
        if !component_set(c,e,"View_Volume",&look) {return}
    }
    if place.shape!=.Unbounded && !component_set(c,e,"Volume",&place) {return}
    p.entity,p.zone=e,look.zone
    return p,true
}

@(private)
grade_setting :: proc(setting:string) -> bool {
    for g in GRADE_PARAMETERS {if g[1]==setting {return true}}
    return false
}

// The look of the level where no volume is: Unreal's defaults for its
// project, in the scene of the map, everywhere under every volume. Made
// once; bridges add theirs to its entity.
post_process_base :: proc(c:^Context) -> (p:Post_Process,made:bool) {
    lowest:=i32(0)
    for v in post_unbound(c) {lowest=min(lowest,i32(math.round(v.priority)))}
    for a in 0..<len(c.d.actors) {
        if level.actor_native_class(c.d,a).name!="PostProcessVolume" {continue}
        priority,_:=level.real_of(c.d,c.d.actors[a].ref,"Priority",0)
        lowest=min(lowest,i32(math.round(priority)))
    }
    look:=render.VIEW_VOLUME_DEFAULT
    look.zone.priority=lowest-1
    p.zone=look.zone
    if c.post_base!=0 {return {entity=c.post_base,zone=p.zone},true}
    previous:=section_use(c,0)
    defer section_use(c,previous)
    e,entity_made:=entity_make(c,0,"Post process","Post process",{rotation=1,scale=1})
    if !entity_made {return}
    look.exposure,_=exposure_from(c,&p.settings,0)
    look.layers[0],_=grade_from(c,&p.settings)
    if !component_set(c,e,"View_Volume",&look) {return}
    c.post_base,p.entity=e,e
    return p,true
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
