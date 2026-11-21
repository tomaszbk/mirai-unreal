package unreal_fog_editor

import "core:fmt"
import "core:math"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import unreal_scene "project:plugins/unreal/editor/scene"
import evolume "mirai:engine/volume"
import mm "mirai:std/math"
import fog "plugins:fog/runtime"

// The height fog of an Unreal level imported by the editor: a fog that thins
// with the height over where the actor is, and its second fog
// (SecondFogData) another one added to it over where the actor is raised by
// its offset. Unreal's fills the world; a fog of Mirai fills a box, that of
// what the level shows, with its base, where it has its density, at the
// height of the actor: over it both thin alike, and under it Unreal's grows
// without end and Mirai's holds.
// Unreal's density and height falloff are FogDensity/1000 per centimetre in
// powers of two. Where it is thick, Unreal's fog shows its
// FogInscatteringLuminance whatever lights it, and under a SkyAtmosphere the
// light of the sky of the atmosphere too (unreal_scene.fog_sky): Mirai's
// glow. Around its sun it adds a lobe without shadows, which Mirai's fog
// gives as the light of the sun it scatters, shadowed (lobe_scatter); no
// other light of the scene reaches Unreal's height fog.
// Unreal's volumetric fog (`bEnableVolumetricFog`), which lights the medium by
// the scene, maps directly to Mirai's volumetric fog: its `VolumetricFogAlbedo`
// becomes `color`, `VolumetricFogScatteringDistribution` becomes `anisotropy`,
// `VolumetricFogEmissive` becomes `glow`, and `FogDensity` is scaled by
// Unreal's `0.5 * VolumetricFogExtinctionScale` match factor (`volumetric_rate`).
// Without `bEnableVolumetricFog`, Mirai translates Unreal's legacy height fog
// (`FogInscatteringLuminance` + atmosphere sky into `glow`, and its sun lobe
// into `lobe_scatter`). What depends on the eye (where the fog starts and
// stops being drawn and the opacity it stops at) and its cubemap colors are
// left out with a warning.
// Unreal draws one height fog in a scene, the first: so does the import.
@(storage)
Fog_Unreal :: struct {provider:unreal_scene.Translator_Provider}

fog_unreal_default :: proc() -> (f:Fog_Unreal) {
    f.provider.count=1
    f.provider.translators[0]={classes={0="ExponentialHeightFog"},translate=fogs_translate}
    return
}

// FogDensity or FogHeightFalloff of Unreal as its height fog takes them, per
// metre in powers of e.
fog_rate :: proc(unreal_value:f64) -> f64 {return unreal_value/10*math.LN2}

// FogDensity as Unreal's volumetric fog converts it to extinction per metre:
// FogDensity / 1000 per cm * 100 cm/m * 0.5 (MatchHeightFogFactor) * ExtinctionScale.
volumetric_rate :: proc(unreal_density,extinction_scale:f64) -> f64 {
    return max(unreal_density,0)*0.05*max(extinction_scale,0)
}

// VolumetricFogEmissive as Unreal scales it (1/10000 nits/cm = 0.01 nits/m) into
// Mirai's thick-fog glow (nits = emission_per_m / density), matching Unreal's
// emission per metre at the fog's base density.
volumetric_glow :: proc(emissive:[3]f32,density:f64) -> (glow:[3]f32) {
    if !(density>0) {return}
    scale:=f32(0.01/density)
    return {max(emissive.r,0)*scale,max(emissive.g,0)*scale,max(emissive.b,0)*scale}
}

// The main-stream version of a package from which Unreal reads
// FogInscatteringLuminance and DirectionalInscatteringLuminance; before it
// it takes the colors FogInscatteringColor and DirectionalInscatteringColor
// for them, which have defaults of their own.
INSCATTERING_LUMINANCE_VERSION :: 47
INSCATTERING_COLOR_DEFAULT :: [3]f32{0.447,0.638,1}
DIRECTIONAL_COLOR_DEFAULT :: [3]f32{0.25,0.25,0.125}

// The exponent of Unreal's lobe around the sun as it clamps it.
LOBE_EXPONENT_RANGE :: [2]f64{1e-6,1000}

// The anisotropy Mirai's fog takes, as it clamps it.
ANISOTROPY_MOST :: 0.95

// Unreal's lobe around its sun, lobe times the power n (exponent) of the
// cosine of the angle from the sun, as the light of a sun of illuminance
// light (lux per channel) that Mirai's fog scatters by the share scattering
// of it. The anisotropy: the one whose phase gathers its light toward the sun
// as the lobe does, its peak over all it scatters equal to the lobe's,
// cos^n over its integral 2π/(n+1). The color, the share of what it stops
// that it scatters: the one with which thick fog seen toward the sun shows
// the lobe's luminance, light*scattering*phase(0°)*color = lobe, each
// channel in [0, 1]; with both, the fog scatters as much of the sun in all
// as the lobe adds. Mirai's phase is Henyey-Greenstein, its peak
// (1+g)/(4π(1-g)²) of a whole of 1: equal to (n+1)/(2π) where
// a(1-g)² = 1+g with a = 2(n+1), whose root in [0, 1) is
// ((2a+1) - sqrt(8a+1))/(2a). held: a channel needed more than 1. No color
// where the sun gives the fog no light.
lobe_scatter :: proc(lobe,light:[3]f32,scattering,exponent:f64) -> (color:[3]f32,anisotropy:f32,held:bool) {
    a:=2*(clamp(exponent,LOBE_EXPONENT_RANGE[0],LOBE_EXPONENT_RANGE[1])+1)
    g:=clamp(((2*a+1)-math.sqrt(8*a+1))/(2*a),0,ANISOTROPY_MOST)
    peak:=(1+g)/(4*math.PI*(1-g)*(1-g))
    anisotropy=f32(g)
    for i in 0..<3 {
        given:=f64(light[i])*max(scattering,0)*peak
        if !(given>0) || !(lobe[i]>0) {continue}
        share:=f64(lobe[i])/given
        held||=share>1
        color[i]=f32(min(share,1))
    }
    return
}

fogs_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"fog.translate")
    d:=c.d
    translated:=0
    // What the level shows, which the fog fills, and the light its sky gives it.
    box:=mm.AABB_EMPTY
    sky:unreal_scene.Fog_Sky
    if len(actors)>0 {
        meshes:=make(map[string]level.Mesh_Box,context.temp_allocator)
        for _,a in d.actors {box=mm.aabb_merge(box,level.actor_bounds(d,a,&meshes))}
        sky=unreal_scene.fog_sky(c)
    }
    size:=mm.aabb_size(box)
    for a in actors {
        root:=d.actors[a].root
        if root<0 {continue}
        if translated>0 {
            unreal_scene.warn(c,"%s: Unreal draws only the first height fog of a scene; this one is left out",d.actors[a].label)
            continue
        }
        ref:=d.components[root].ref
        label:=d.actors[a].label
        if mm.aabb_is_empty(box) || !(size.x>0 && size.y>0 && size.z>0) {
            unreal_scene.warn(c,"%s: the level shows nothing around its height fog for it to fill; it is left out",label)
            continue
        }
        world,_,error:=level.actor_world(d,a)
        if error.code!=.None {continue}
        volumetric,_:=level.bool_of(d,ref,"bEnableVolumetricFog",false)
        density,_:=level.real_of(d,ref,"FogDensity",0.02)
        falloff,_:=level.real_of(d,ref,"FogHeightFalloff",0.2)
        volume:=fog.FOG_VOLUME_DEFAULT
        lobe:[3]f32
        exponent:=4.0
        held:bool
        extinction_scale:=1.0
        if volumetric {
            albedo,_:=unreal_scene.color_of(d,ref,"VolumetricFogAlbedo",{1,1,1})
            emissive,_:=unreal_scene.color_of(d,ref,"VolumetricFogEmissive",{})
            spread,_:=level.real_of(d,ref,"VolumetricFogScatteringDistribution",0.2)
            extinction_scale,_=level.real_of(d,ref,"VolumetricFogExtinctionScale",1)
            rate:=volumetric_rate(density,extinction_scale)
            volume.color={clamp(albedo.r,0,1),clamp(albedo.g,0,1),clamp(albedo.b,0,1)}
            volume.anisotropy=f32(clamp(spread,-ANISOTROPY_MOST,ANISOTROPY_MOST))
            volume.glow=volumetric_glow(emissive,rate)
            volume.density=f32(rate)
        } else {
            version,versioned:=unreal.custom_version(level.library_package(d.library,int(ref.pkg)),unreal.UE5_MAIN_STREAM_VERSION)
            glow,directional:[3]f32
            if versioned && version>=INSCATTERING_LUMINANCE_VERSION {
                glow,_=unreal_scene.color_of(d,ref,"FogInscatteringLuminance",{})
                directional,_=unreal_scene.color_of(d,ref,"DirectionalInscatteringLuminance",{})
            } else {
                glow,_=unreal_scene.color_of(d,ref,"FogInscatteringColor",INSCATTERING_COLOR_DEFAULT)
                directional,_=unreal_scene.color_of(d,ref,"DirectionalInscatteringColor",DIRECTIONAL_COLOR_DEFAULT)
            }
            cubemap,_:=level.reference_property(d,ref,"InscatteringColorCubemap")
            if cubemap!=0 {
                unreal_scene.warn(c,"%s: Unreal colors its fog from a cubemap; Mirai's fog takes the light around it instead and glows only with the light of the atmosphere",label)
                glow,directional={},{}
            }
            ambient,_:=unreal_scene.color_of(d,ref,"SkyAtmosphereAmbientContributionColorScale",{1,1,1})
            glow+=sky.ambient*ambient
            // Unreal goes from its glow and its lobe to the light of its sky light by this share.
            sky_share,_:=level.real_of(d,ref,"SkyLightCaptureAffectsHeightFogStrength",0)
            kept:=f32(1-clamp(sky_share,0,1))
            glow*=kept
            // The lobe Unreal adds around the sun: its directional luminance times the luminance of the sun, and the sun through the atmosphere.
            lobe=(directional*sky.sun_luminance+(cubemap!=0?{}:sky.sun))*kept
            exponent,_=level.real_of(d,ref,"DirectionalInscatteringExponent",4)
            volume.color,volume.anisotropy,held=lobe_scatter(lobe,sky.light,f64(sky.scattering),exponent)
            if volume.color=={} {volume.anisotropy=0}
            volume.glow=glow
            volume.density=f32(fog_rate(density))
        }
        volume.falloff=f32(fog_rate(falloff))
        volume.zone.blend=0
        height:=world.position.y
        volume.base=height-box.min.y
        place:=evolume.box(mm.aabb_half(box))
        key:=unreal_scene.actor_key(c,a)
        e,made:=unreal_scene.entity_make(c,0,key,label,{position=mm.aabb_center(box),rotation=1,scale=1})
        if !made || !unreal_scene.component_set(c,e,"Fog_Volume",&volume) || !unreal_scene.component_set(c,e,"Volume",&place) {return translated}
        second:=unreal_scene.struct_chain(d,ref,"SecondFogData")
        if second_density,_:=unreal_scene.chain_real(&second,"FogDensity",0);second_density>0 {
            second_falloff,_:=unreal_scene.chain_real(&second,"FogHeightFalloff",0.2)
            offset,_:=unreal_scene.chain_real(&second,"FogHeightOffset",0)
            added:=volume
            added.density=f32(volumetric_rate(second_density,extinction_scale) if volumetric else fog_rate(second_density))
            if volumetric {added.glow={}}
            added.base=volume.base+f32(offset/100)
            added.falloff=f32(fog_rate(second_falloff))
            // Added over the first, which it comes after.
            added.zone.mode,added.zone.priority=.Add,1
            child,child_made:=unreal_scene.entity_make(c,e,fmt.tprintf("%s|second fog",key),fmt.tprintf("%s second fog",label),{rotation=1,scale=1})
            if !child_made || !unreal_scene.component_set(c,child,"Fog_Volume",&added) || !unreal_scene.component_set(c,child,"Volume",&place) {return translated}
        }
        unreal_scene.warn(c,"%s: Unreal's height fog fills the world; Mirai's fills the box of what the level shows, %.3g by %.3g by %.3g m, and past it the haze is the air of the Sky",label,size.x,size.y,size.z)
        if volume.base>0 {unreal_scene.warn(c,"%s: under the height of its actor Unreal's fog grows thicker without end, %.3g times at the bottom of the level, %.3g m lower; Mirai's holds its density there",label,math.exp(f64(volume.falloff*volume.base)),volume.base)}
        if volumetric {
            distance,_:=level.real_of(d,ref,"VolumetricFogDistance",6000)
            vstart,_:=level.real_of(d,ref,"VolumetricFogStartDistance",0)
            unreal_scene.warn(c,"%s: Unreal limits volumetric fog to %.3g m from the eye and falls back to height fog past it; Mirai carries the volumetric medium (albedo %v, anisotropy %.3g, extinction scale %.3g) to the horizon",label,(vstart+distance)/100,volume.color,volume.anisotropy,extinction_scale)
            if vstart>0 {unreal_scene.warn(c,"%s: Unreal starts volumetric fog %.3g m from the eye; Mirai's medium is in the world and starts at the eye",label,vstart/100)}
        } else {
            if lobe!={} {
                from,_:=level.real_of(d,ref,"DirectionalInscatteringStartDistance",10000)
                if volume.color=={} {
                    unreal_scene.warn(c,"%s: Unreal adds to its fog a glow around its sun, %v nits looking at it and the power %.3g of the cosine away from it; the sun of the level scatters no light in Mirai's fog, so it is left out",label,lobe,exponent)
                } else {
                    unreal_scene.warn(c,"%s: Unreal adds to its fog a glow around its sun past %.3g m from the eye, %v nits looking at it and the power %.3g of the cosine away from it, without shadows; Mirai's fog scatters the sun from the eye on and with shadows, by the color %v and the anisotropy %.3g, which give that luminance toward the sun and as much light in all%s, and by that color it scatters the light around it too",label,from/100,lobe,exponent,volume.color,volume.anisotropy,held?" (a channel brighter than a color of 1 gives is held there)":"")
                }
            }
            if opacity,_:=level.real_of(d,ref,"FogMaxOpacity",1);opacity<1 {unreal_scene.warn(c,"%s: its fog stops at an opacity of %.2g in Unreal; a medium in Mirai lets less through the more of it there is",label,opacity)}
            if start,_:=level.real_of(d,ref,"StartDistance",0);start>0 {unreal_scene.warn(c,"%s: its fog starts %.3g m from the eye in Unreal; Mirai's medium is in the world and starts at the eye",label,start/100)}
            if cutoff,_:=level.real_of(d,ref,"FogCutoffDistance",0);cutoff>0 {unreal_scene.warn(c,"%s: its fog stops %.3g m from the eye in Unreal; Mirai's medium is in the world and goes on to the sky",label,cutoff/100)}
            if end,_:=level.real_of(d,ref,"EndDistance",0);end>0 {unreal_scene.warn(c,"%s: its fog thickens only to %.3g m from the eye in Unreal; Mirai's medium thickens all the way",label,end/100)}
        }
        translated+=1
    }
    return translated
}
