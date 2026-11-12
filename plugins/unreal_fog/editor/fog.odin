package unreal_fog_editor

import "core:fmt"
import "core:math"
import "project:plugins/unreal/editor/level"
import unreal_scene "project:plugins/unreal/editor/scene"
import evolume "mirai:engine/volume"
import fog "plugins:fog/runtime"

// The height fog of an Unreal level imported by the editor: a fog that
// fills the world and thins with the height over where the actor is, and its
// second fog (SecondFogData) another one added to it, over where the actor
// is raised by its offset. Unreal's density and height falloff are
// FogDensity/1000 per centimetre in powers of two; Mirai's are per metre in
// powers of e. Mirai lights its fog with the sun and the sky everywhere, as
// the volumetric fog of Unreal and its height fog under a SkyAtmosphere do:
// what the fog scatters is the albedo of that fog. The colors Unreal adds as
// light over its fog (FogInscatteringLuminance and its directional and
// cubemap colors, a radiance, not a share of what the fog scatters) have no
// medium behind them and are left out, as what depends on the eye and not on
// the medium: where the fog starts and stops being drawn and the opacity it
// stops at. Unreal fogs the sky as Mirai does, unless a cutoff stops it.
// Unreal draws one height fog in a scene, the first: so does the import.
@(storage)
Fog_Unreal :: struct {provider:unreal_scene.Translator_Provider}

fog_unreal_default :: proc() -> (f:Fog_Unreal) {
    f.provider.count=1
    f.provider.translators[0]={classes={0="ExponentialHeightFog"},translate=fogs_translate}
    return
}

// FogDensity or FogHeightFalloff of Unreal in Mirai's units, per metre.
fog_rate :: proc(unreal_value:f64) -> f32 {return f32(unreal_value/10*math.LN2)}

fogs_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"fog.translate")
    d:=c.d
    translated:=0
    for a in actors {
        root:=d.actors[a].root
        if root<0 {continue}
        if translated>0 {
            unreal_scene.warn(c,"%s: Unreal draws only the first height fog of a scene; this one is left out",d.actors[a].label)
            continue
        }
        ref:=d.components[root].ref
        label:=d.actors[a].label
        density,_:=level.real_of(d,ref,"FogDensity",0.02)
        falloff,_:=level.real_of(d,ref,"FogHeightFalloff",0.2)
        scattering,_:=level.real_of(d,ref,"VolumetricFogScatteringDistribution",0.2)
        albedo,_:=unreal_scene.color_of(d,ref,"VolumetricFogAlbedo",{1,1,1})
        volume:=fog.FOG_VOLUME_DEFAULT
        volume.density=fog_rate(density)
        volume.falloff=fog_rate(falloff)
        volume.color=albedo
        volume.anisotropy=clamp(f32(scattering),-0.95,0.95)
        world,_,error:=level.actor_world(d,a)
        if error.code!=.None {continue}
        world.scale={1,1,1}
        key:=unreal_scene.actor_key(c,a)
        e,made:=unreal_scene.entity_make(c,0,key,label,world)
        if !made || !unreal_scene.component_set(c,e,"Fog_Volume",&volume) {return translated}
        second:=unreal_scene.struct_chain(d,ref,"SecondFogData")
        if second_density,_:=unreal_scene.chain_real(&second,"FogDensity",0);second_density>0 {
            second_falloff,_:=unreal_scene.chain_real(&second,"FogHeightFalloff",0.2)
            offset,_:=unreal_scene.chain_real(&second,"FogHeightOffset",0)
            added:=volume
            added.density=fog_rate(second_density)
            added.falloff=fog_rate(second_falloff)
            // Added over the first, which it comes after.
            added.zone.mode,added.zone.priority=.Add,1
            place:=evolume.world()
            child,child_made:=unreal_scene.entity_make(c,e,fmt.tprintf("%s|second fog",key),fmt.tprintf("%s second fog",label),{position={0,f32(offset/100),0},rotation=1,scale=1})
            if !child_made || !unreal_scene.component_set(c,child,"Fog_Volume",&added) || !unreal_scene.component_set(c,child,"Volume",&place) {return translated}
        }
        if opacity,_:=level.real_of(d,ref,"FogMaxOpacity",1);opacity<1 {unreal_scene.warn(c,"%s: its fog stops at an opacity of %.2g in Unreal; a medium in Mirai lets less through the more of it there is",label,opacity)}
        if start,_:=level.real_of(d,ref,"StartDistance",0);start>0 {unreal_scene.warn(c,"%s: its fog starts %.3g m from the eye in Unreal; Mirai's medium is in the world and starts at the eye",label,start/100)}
        if cutoff,_:=level.real_of(d,ref,"FogCutoffDistance",0);cutoff>0 {unreal_scene.warn(c,"%s: its fog stops %.3g m from the eye in Unreal; Mirai's medium is in the world and goes on to the sky",label,cutoff/100)}
        if scale,_:=unreal_scene.color_of(d,ref,"SkyAtmosphereAmbientContributionColorScale",{1,1,1});scale!={1,1,1} {unreal_scene.warn(c,"%s: Unreal scales the light of the sky in its fog by %v; Mirai's fog takes the light of the sky as it is",label,scale)}
        translated+=1
    }
    return translated
}
