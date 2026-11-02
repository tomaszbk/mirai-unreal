package unreal_scene

import "core:math"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import render "mirai:engine/render"
import mm "mirai:std/math"

// Unreal's lights in Mirai's units, as Unreal converts them for its
// renderer: what Unreal draws with is a luminous intensity times 100²
// (centimetres), which a point or spot light of Mirai holds in candelas, a
// rectangle as the luminance of its face (nits) and a sun as illuminance
// (lux). Mirai divides by π where its renderer needs it.

Light_Kind :: enum u8 {Point,Spot,Rect,Directional}
Light_Units :: enum u8 {Unitless,Candelas,Lumens,EV,Nits}

// A light as Unreal keeps it: centimetres and degrees.
Unreal_Light :: struct {
    kind:Light_Kind,
    units:Light_Units,
    intensity:f32,
    color:[3]f32, // linear
    use_temperature:bool,
    temperature:f32, // K
    attenuation_radius:f32,
    source_radius,source_length:f32,
    inverse_squared:bool,
    falloff_exponent:f32,
    inner_cone,outer_cone:f32, // half angles
    source_width,source_height:f32,
    broken_ev:bool, // a rectangle saved before RectLightFixedEVUnitConversion with EV units
}

// What Mirai takes of it.
Converted_Light :: struct {
    color:[3]f32,   // linear, no channel above one
    value:f32,      // cd for a point or spot, nits for a rectangle, lux for a sun
    range:f32,      // m
    radius:f32,     // m
    angle:f32,      // of a spot: its half angle, radians
    size:[2]f32,    // of a rectangle, m
}

Light_Approximation :: enum u8 {
    Falloff,       // no inverse squared falloff: matched where it reaches half its radius
    Source_Length, // a point or spot drawn out into a tube
    Inner_Cone,    // Mirai fades over the outer fifth of the cone
    Cone_Clamped,  // outside 1° to 89°
}

LIGHT_UNIT_NAMES :: [Light_Units]string{.Unitless="unitless",.Candelas="cd",.Lumens="lm",.EV="EV",.Nits="nit"}

light_units_parse :: proc(text:string) -> Light_Units {
    switch text {
    case "Candelas":return .Candelas
    case "Lumens":return .Lumens
    case "EV":return .EV
    case "Nits":return .Nits
    }
    return .Unitless
}

// What a light gives in Mirai's units.
light_convert :: proc(u:Unreal_Light) -> (m:Converted_Light,approximated:bit_set[Light_Approximation]) {
    m.range=max(u.attenuation_radius,0)/100
    m.radius=max(u.source_radius,0)/100
    cos_cone:=f32(1)
    if u.kind==.Spot {
        // The outer half angle as Unreal clamps it: a hair wider than the inner one, up to 88.9°.
        inner:=clamp(u.inner_cone,0,88.9)*math.RAD_PER_DEG
        outer:=clamp(u.outer_cone*math.RAD_PER_DEG,inner+0.001,88.9*math.RAD_PER_DEG+0.001)
        m.angle=clamp(outer,render.SPOT_MIN,render.SPOT_MAX)
        if m.angle!=outer {approximated+={.Cone_Clamped}}
        if inner>0 {approximated+={.Inner_Cone}}
        cos_cone=math.cos(outer)
    }
    if u.kind!=.Directional && u.kind!=.Rect && u.source_length>0 {approximated+={.Source_Length}}
    value:f32
    switch u.kind {
    case .Directional:
        value=u.intensity
    case .Point,.Spot:
        if !u.inverse_squared {
            // Unreal lights by intensity times its window alone: the candelas that give as much where it reaches half its radius.
            half:=m.range/2
            value=u.intensity*math.pow(1-0.25,max(u.falloff_exponent,0))*half*half
            approximated+={.Falloff}
            break
        }
        switch u.units {
        case .Candelas:value=u.intensity
        case .Lumens:
            if u.kind==.Spot {value=u.intensity/(2*math.PI*(1-min(cos_cone,1-1e-6)))} else {value=u.intensity/(4*math.PI)}
        case .EV:value=math.pow(2,u.intensity)
        case .Nits:
            // The capsule of its source: sphere and cylinder, in m².
            r,l:=m.radius,max(u.source_length,0)/100
            value=u.intensity*4*math.PI*r*(r+0.5*l)
        case .Unitless:value=u.intensity*16/10000
        }
    case .Rect:
        m.size={max(u.source_width,0)/100,max(u.source_height,0)/100}
        area:=m.size.x*m.size.y
        if area<=0 {break}
        switch u.units {
        case .Nits:value=u.intensity
        case .Candelas:value=u.intensity/area
        case .Lumens:value=u.intensity/(math.PI*area)
        case .EV:
            value=math.pow(2,u.intensity)/area
            if u.broken_ev {value*=u.intensity}
        case .Unitless:value=u.intensity*16/10000/area
        }
    }
    color:=u.color
    if u.use_temperature {color*=mm.blackbody_linear(u.temperature)}
    peak:=max(color.r,color.g,color.b)
    if peak>1 {color/=peak;value*=peak}
    m.color=color
    m.value=max(value,0)
    return
}

// The light of a component as Unreal keeps it, with the defaults of the
// constructors of ULightComponent and its classes.
unreal_light :: proc(c:^Context,component:int,kind:Light_Kind) -> (u:Unreal_Light) {
    d:=c.d
    ref:=d.components[component].ref
    u.kind=kind
    default_intensity:=f64(kind==.Directional?10:5000)
    intensity,_:=level.real_of(d,ref,"Intensity",default_intensity)
    u.intensity=f32(intensity)
    units,_:=level.enum_of(d,ref,"IntensityUnits","Unitless")
    u.units=light_units_parse(units)
    u.color,_=color_of(d,ref,"LightColor",{1,1,1})
    u.use_temperature,_=level.bool_of(d,ref,"bUseTemperature",false)
    temperature,_:=level.real_of(d,ref,"Temperature",6500)
    u.temperature=f32(temperature)
    attenuation,_:=level.real_of(d,ref,"AttenuationRadius",1000)
    u.attenuation_radius=f32(attenuation)
    radius,_:=level.real_of(d,ref,"SourceRadius",0)
    length,_:=level.real_of(d,ref,"SourceLength",0)
    u.source_radius,u.source_length=f32(radius),f32(length)
    u.inverse_squared,_=level.bool_of(d,ref,"bUseInverseSquaredFalloff",true)
    exponent,_:=level.real_of(d,ref,"LightFalloffExponent",8)
    u.falloff_exponent=f32(exponent)
    inner,_:=level.real_of(d,ref,"InnerConeAngle",0)
    outer,_:=level.real_of(d,ref,"OuterConeAngle",44)
    u.inner_cone,u.outer_cone=f32(inner),f32(outer)
    width,_:=level.real_of(d,ref,"SourceWidth",64)
    height,_:=level.real_of(d,ref,"SourceHeight",64)
    u.source_width,u.source_height=f32(width),f32(height)
    if kind==.Rect && u.units==.EV {
        broken,found:=level.bool_of(d,ref,"bLightRequiresBrokenEVMath",false)
        if found {u.broken_ev=broken} else {u.broken_ev=fortnite_version(c,ref)<RECT_LIGHT_FIXED_EV}
    }
    return
}

// FFortniteMainBranchObjectVersion::RectLightFixedEVUnitConversion.
@(private)
RECT_LIGHT_FIXED_EV :: 203

// The FFortniteMainBranchObjectVersion of the package of an object; 0 when it has none.
@(private)
fortnite_version :: proc(c:^Context,ref:level.Ref) -> i32 {
    version,found:=unreal.custom_version(level.library_package(c.d.library,int(ref.pkg)),unreal.FORTNITE_MAIN_VERSION)
    return found?version:0
}


// The light of a component on an entity under its actor: it shines toward
// the -Z of its entity, where Unreal's shines along +X, and takes its shape
// from the scale of the entity, which Unreal's does not have.
light_add :: proc(c:^Context,actor,component:int,kind:Light_Kind) -> bool {
    u:=unreal_light(c,component,kind)
    m,approximated:=light_convert(u)
    scale:=[3]f32{1,1,1}
    if kind==.Rect {scale={max(m.size.x,1e-3),max(m.size.y,1e-3),1}}
    e,ok:=component_entity(c,actor,component,FACING,scale)
    if !ok {return false}
    name:=c.d.actors[actor].label
    value:=m.value
    switch kind {
    case .Directional:
        sun:=render.Sun{color=m.color,illuminance=m.value,disc=true}
        if !component_set(c,e,"Sun",&sun) {return false}
        append(&c.suns,Sun_Candidate{e,c.section,m.value*max(m.color.r,m.color.g,m.color.b)})
    case .Point:
        light:=render.Point_Light{color=m.color,intensity=m.value,range=m.range,radius=m.radius}
        if !component_set(c,e,"Point_Light",&light) {return false}
    case .Spot:
        light:=render.Spot_Light{color=m.color,intensity=m.value,range=m.range,radius=m.radius,angle=m.angle}
        if !component_set(c,e,"Spot_Light",&light) {return false}
    case .Rect:
        light:=render.Rect_Light{color=m.color,luminance=m.value,range=m.range}
        if !component_set(c,e,"Rect_Light",&light) {return false}
    }
    unit:="cd"
    switch kind {
    case .Directional:unit="lx"
    case .Rect:unit="nit"
    case .Point,.Spot:
    }
    units:=LIGHT_UNIT_NAMES
    from:=units[u.units] if kind!=.Directional else "lx"
    append(&c.report.lights,Light_Note{name=clone(c,name),kind=kind,units=from,intensity=u.intensity,value=value,unit=unit,approximated=approximated})
    ref:=c.d.components[component].ref
    names:=LIGHT_NAMES
    if affects,found:=level.bool_of(c.d,ref,"bAffectsWorld",true);found && !affects {component_off(c,e,names[kind])}
    if level.path_of(c.d,ref,"IESTexture")!="" {c.notes[.IES]+=1}
    if level.path_of(c.d,ref,"LightFunctionMaterial")!="" {c.notes[.Light_Function]+=1}
    if shadows,_:=level.bool_of(c.d,ref,"CastShadows",true);!shadows {c.notes[.No_Shadows]+=1}
    if .Falloff in approximated {c.notes[.Falloff]+=1}
    if .Source_Length in approximated {c.notes[.Source_Length]+=1}
    if .Cone_Clamped in approximated {c.notes[.Cone_Clamped]+=1}
    return true
}

LIGHT_NAMES :: [Light_Kind]string{.Point="Point_Light",.Spot="Spot_Light",.Rect="Rect_Light",.Directional="Sun"}

// What turns Unreal's +X (Mirai's +Z), which lights and cameras face, to the
// -Z that Mirai's face, keeping up as up.
FACING :: mm.Quat(quaternion(w=0,x=0,y=1,z=0))
