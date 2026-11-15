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
// glow. No light of the scene reaches that fog, so its albedo is black.
// Unreal's volumetric fog, which lights the fog by the scene, is drawn only
// near the eye and in place of that glow there, and not at all below high
// scalability: Mirai's fog is one medium to the horizon, and it is the height
// fog, which Unreal draws at every quality and everywhere past the volumetric
// one. What depends on the eye (where the fog starts and stops being drawn
// and the opacity it stops at), the glow it adds around the sun and its
// cubemap colors are left out with a warning.
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

// The main-stream version of a package from which Unreal reads
// FogInscatteringLuminance and DirectionalInscatteringLuminance; before it
// it takes the colors FogInscatteringColor and DirectionalInscatteringColor
// for them, which have defaults of their own.
INSCATTERING_LUMINANCE_VERSION :: 47
INSCATTERING_COLOR_DEFAULT :: [3]f32{0.447,0.638,1}
DIRECTIONAL_COLOR_DEFAULT :: [3]f32{0.25,0.25,0.125}

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
        // Unreal goes from its glow to the light of its sky light by this share.
        sky_share,_:=level.real_of(d,ref,"SkyLightCaptureAffectsHeightFogStrength",0)
        glow*=f32(1-clamp(sky_share,0,1))
        volumetric,_:=level.bool_of(d,ref,"bEnableVolumetricFog",false)
        density,_:=level.real_of(d,ref,"FogDensity",0.02)
        falloff,_:=level.real_of(d,ref,"FogHeightFalloff",0.2)
        volume:=fog.FOG_VOLUME_DEFAULT
        volume.color={}
        volume.glow=glow
        volume.falloff=f32(fog_rate(falloff))
        volume.zone.blend=0
        height:=world.position.y
        volume.density=f32(fog_rate(density))
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
            added.density=f32(fog_rate(second_density))
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
            start,_:=level.real_of(d,ref,"VolumetricFogStartDistance",0)
            unreal_scene.warn(c,"%s: at high scalability Unreal lights its fog by the scene to %.3g m from the eye, its volumetric fog, in place of its glow there; Mirai's fog is its height fog to the horizon, which glows and takes no light of the scene",label,(start+distance)/100)
        }
        // The lobe Unreal adds around the sun: its directional luminance times the luminance of the sun, and the sun through the atmosphere.
        if lobe:=directional*sky.sun_luminance+(cubemap!=0?{}:sky.sun);lobe!={} {
            exponent,_:=level.real_of(d,ref,"DirectionalInscatteringExponent",4)
            from,_:=level.real_of(d,ref,"DirectionalInscatteringStartDistance",10000)
            unreal_scene.warn(c,"%s: Unreal adds to its fog a glow around its sun past %.3g m from the eye, %v nits looking at it and the power %.3g of the cosine away from it, without shadows; Mirai's glow is the same every way and from the eye, so it is left out",label,from/100,lobe,exponent)
        }
        if opacity,_:=level.real_of(d,ref,"FogMaxOpacity",1);opacity<1 {unreal_scene.warn(c,"%s: its fog stops at an opacity of %.2g in Unreal; a medium in Mirai lets less through the more of it there is",label,opacity)}
        if start,_:=level.real_of(d,ref,"StartDistance",0);start>0 {unreal_scene.warn(c,"%s: its fog starts %.3g m from the eye in Unreal; Mirai's medium is in the world and starts at the eye",label,start/100)}
        if cutoff,_:=level.real_of(d,ref,"FogCutoffDistance",0);cutoff>0 {unreal_scene.warn(c,"%s: its fog stops %.3g m from the eye in Unreal; Mirai's medium is in the world and goes on to the sky",label,cutoff/100)}
        if end,_:=level.real_of(d,ref,"EndDistance",0);end>0 {unreal_scene.warn(c,"%s: its fog thickens only to %.3g m from the eye in Unreal; Mirai's medium thickens all the way",label,end/100)}
        translated+=1
    }
    return translated
}
