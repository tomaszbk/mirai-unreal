package unreal_lens_editor

import "core:math"
import unreal_scene "project:plugins/unreal/editor/scene"
import lens "plugins:lens/runtime"

// What the post process volumes of an Unreal level do through the lens: the
// importer makes each one the entity of its View_Volume, over its zone and
// Volume, and this adds there a Lens_Volume of its bloom and vignette. What
// a volume does not override of them is the lens's default, which is none.
@(storage)
Lens_Unreal :: struct {provider:unreal_scene.Translator_Provider}

lens_unreal_default :: proc() -> (l:Lens_Unreal) {
    l.provider.count=1
    l.provider.translators[0]={classes={0="PostProcessVolume"},translate=post_processes_translate}
    return
}

BLOOM_TINTS :: [6]string{"Bloom1Tint","Bloom2Tint","Bloom3Tint","Bloom4Tint","Bloom5Tint","Bloom6Tint"}
BLOOM_TINT_DEFAULTS :: [6]f32{0.3465,0.138,0.1176,0.066,0.066,0.061}

// Unreal's standard bloom adds to the image the blur of each of its six
// levels times its tint and a sixth of the intensity, k of the light in all;
// Mirai's lens gives the blur its share of the light of the image, which in
// Unreal's is k/(1+k). Mirai's bloom has no color: a tint counts by its
// luminance.
bloom_share :: proc "contextless" (intensity:f32,tints:[6][3]f32) -> f32 {
    sum:=f32(0)
    for tint in tints {sum+=0.2126*tint.r+0.7152*tint.g+0.0722*tint.b}
    k:=max(intensity*sum/len(tints),0)
    return k/(1+k)
}

// tan² of the angle off the axis at the corners of Unreal's default view:
// 90 degrees across at 16:9.
CORNER_TAN2 :: 1+(9.0/16)*(9.0/16)

// Unreal darkens by cos^4 of an angle whose tangent is the intensity times
// the distance from the center, √2 at the corners in any view; Mirai's lens
// takes the share vignette of the cos^4 falloff of the angles of its view.
// The share darkens the corners of Unreal's default view as Unreal does; it
// is at most 1, the whole falloff (whole: false when Unreal darkens more).
vignette_share :: proc "contextless" (intensity:f32) -> (share:f32,whole:bool) {
    unreal:=1/math.pow(1+2*intensity*intensity,2)
    natural:=1/math.pow(f32(1+CORNER_TAN2),2)
    share=(1-unreal)/(1-natural)
    return min(max(share,0),1),share<=1
}

post_processes_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"lens.translate")
    for a in actors {
        p,made:=unreal_scene.post_process_add(c,a,lens=true)
        if !made {continue}
        s:=&p.settings
        label:=c.d.actors[a].label
        look:=lens.LENS_VOLUME_DEFAULT
        look.zone=p.zone
        bloomed:=false
        for setting in unreal_scene.LENS_SETTINGS {
            if setting!="VignetteIntensity" && unreal_scene.setting_overridden(s,setting) {bloomed=true}
        }
        if bloomed && unreal_scene.setting_overridden(s,"BloomMethod") && unreal_scene.chain_enum(s,"BloomMethod","BM_SOG")=="BM_FFT" {
            unreal_scene.warn(c,"%s: its bloom is a convolution with an image in Unreal; Mirai's lens blurs by levels, so its bloom is not translated",label)
            bloomed=false
        }
        if bloomed {
            intensity,_:=unreal_scene.chain_real(s,"BloomIntensity",0.675)
            gaussian,_:=unreal_scene.chain_real(s,"BloomGaussianIntensity",1)
            tints:[6][3]f32
            defaults:=BLOOM_TINT_DEFAULTS
            tinted:=false
            for name,i in BLOOM_TINTS {
                tints[i],_=unreal_scene.chain_color(s,name,defaults[i])
                tinted||=tints[i].r!=tints[i].g || tints[i].g!=tints[i].b
            }
            if tinted {unreal_scene.warn(c,"%s: its bloom is tinted in Unreal; Mirai's lens scatters the light in its own colors",label)}
            look.lens.bloom=bloom_share(f32(intensity*gaussian),tints)
        }
        vignetted:=unreal_scene.setting_overridden(s,"VignetteIntensity")
        if vignetted {
            intensity,_:=unreal_scene.chain_real(s,"VignetteIntensity",0.4)
            whole:bool
            look.lens.vignette,whole=vignette_share(f32(intensity))
            if !whole {unreal_scene.warn(c,"%s: its vignette of %.3g darkens more than the natural falloff of a lens; Mirai's darkens the corners as much as that falloff",label,intensity)}
        }
        if !bloomed && !vignetted {continue}
        if !unreal_scene.component_set(c,p.entity,"Lens_Volume",&look) {break}
    }
    return len(actors)
}
