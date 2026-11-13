package unreal_lens_editor

import "core:math"
import unreal_scene "project:plugins/unreal/editor/scene"
import lens "plugins:lens/runtime"

// What the post process of an Unreal level does through the lens: the
// importer makes the look where no volume is and each volume the entity of
// its View_Volume, over its zone and Volume, and this adds there a
// Lens_Volume of its bloom and vignette, as Unreal blends them over the
// defaults of the project.
@(storage)
Lens_Unreal :: struct {provider:unreal_scene.Translator_Provider}

lens_unreal_default :: proc() -> (l:Lens_Unreal) {
    l.provider.count=1
    l.provider.translators[0]={classes={0="PostProcessVolume"},translate=post_processes_translate,map_scene=true}
    return
}

BLOOM_TINTS :: [6]string{"Bloom1Tint","Bloom2Tint","Bloom3Tint","Bloom4Tint","Bloom5Tint","Bloom6Tint"}

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

// The lens of post process settings as Unreal blends them; label names
// what overrides them in the warnings of what it overrides.
lens_of :: proc(c:^unreal_scene.Context,s:^unreal_scene.Post_Settings,label:string) -> (l:lens.Lens) {
    l=lens.LENS_DEFAULT
    if unreal_scene.post_enum(c,s,"BloomMethod")=="BM_FFT" {
        if unreal_scene.post_own(s,"BloomMethod") {unreal_scene.warn(c,"%s: its bloom is a convolution with an image in Unreal; Mirai's lens blurs by levels, so its bloom is not translated",label)}
    } else {
        intensity:=unreal_scene.post_real(c,s,"BloomIntensity")*unreal_scene.post_real(c,s,"BloomGaussianIntensity")
        tints:[6][3]f32
        tinted:=false
        for name,i in BLOOM_TINTS {
            v:=unreal_scene.post_vector(c,s,name)
            tints[i]={f32(v.x),f32(v.y),f32(v.z)}
            tinted||=unreal_scene.post_own(s,name) && (v.x!=v.y || v.y!=v.z)
        }
        if tinted {unreal_scene.warn(c,"%s: its bloom is tinted in Unreal; Mirai's lens scatters the light in its own colors",label)}
        l.bloom=bloom_share(f32(intensity),tints)
    }
    intensity:=unreal_scene.post_real(c,s,"VignetteIntensity")
    whole:bool
    l.vignette,whole=vignette_share(f32(intensity))
    if !whole && unreal_scene.post_own(s,"VignetteIntensity") {unreal_scene.warn(c,"%s: its vignette of %.3g darkens more than the natural falloff of a lens; Mirai's darkens the corners as much as that falloff",label,intensity)}
    return
}

// Each volume that overrides some of the lens gets the Lens_Volume of its
// settings; the look where no volume is, in the scene of the map, that of
// Unreal's defaults.
post_processes_translate :: proc(c:^unreal_scene.Context,actors:[]int) -> int {
    unreal_scene.zone(c,"lens.translate")
    if c.section==0 {
        if p,made:=unreal_scene.post_process_base(c);made {
            look:=lens.Lens_Volume{lens=lens_of(c,&p.settings,"the defaults"),zone=p.zone}
            if !unreal_scene.component_set(c,p.entity,"Lens_Volume",&look) {return 0}
        }
    }
    for a in actors {
        p,made:=unreal_scene.post_process_add(c,a,lens=true)
        if !made {continue}
        owned:=false
        for setting in unreal_scene.LENS_SETTINGS {owned||=unreal_scene.post_own(&p.settings,setting)}
        if !owned {continue}
        look:=lens.Lens_Volume{lens=lens_of(c,&p.settings,c.d.actors[a].label),zone=p.zone}
        if !unreal_scene.component_set(c,p.entity,"Lens_Volume",&look) {break}
    }
    return len(actors)
}
