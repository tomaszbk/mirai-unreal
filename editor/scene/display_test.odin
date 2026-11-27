package unreal_scene

import "core:math"
import "core:testing"
import render "mirai:engine/render"

// Unreal's film shows a gray as a gray and the gray it reports as the light of
// Mirai's card; it turns a bright violet pink one channel at a time, where a
// dim one stays violet; and it comes out as a LUT texture of the engine's layout.
@(test)
the_film_of_unreal_bakes_into_a_display_lut :: proc(t:^testing.T) {
    m:=film_matrices()
    for g in ([]f64{0.01,0.18,1,8}) {
        c:=film_encode(UNREAL_FILM,m,{g,g,g})
        testing.expectf(t,abs(c.r-c.g)<2e-3&&abs(c.g-c.b)<2e-3,"a gray of %v stays gray: %v",g,c)
    }
    white:=film_encode(UNREAL_FILM,m,{1000,1000,1000})
    testing.expectf(t,white.g>0.99,"a very bright gray is white: %v",white)
    gray:=film_gray(UNREAL_FILM,m)
    shown:=srgb_decode(film_encode(UNREAL_FILM,m,{f64(gray),f64(gray),f64(gray)}).g)
    testing.expectf(t,abs(shown-f64(render.DISPLAY_GRAY))<1e-4,"its gray %v shows as %v, not %v",gray,shown,render.DISPLAY_GRAY)
    violet:=[3]f64{4.47,1.34,16}
    dim:=film_encode(UNREAL_FILM,m,violet*0.02)
    bright:=film_encode(UNREAL_FILM,m,violet*0.3)
    testing.expectf(t,dim.b>dim.r+0.2,"a dim violet stays violet: %v",dim)
    testing.expectf(t,bright.r>0.9&&bright.b>0.9,"a bright violet runs pink to white: %v",bright)

    size:=render.display_lut_texture_size()
    pixels:=display_lut_pixels(UNREAL_FILM,context.temp_allocator)
    testing.expect_value(t,len(pixels),size.x*size.y*4)
    // The texel of slice z (blue), at red x and green y, is the film of their lights.
    n:=render.DISPLAY_LUT_SIZE
    for p in ([][3]int{{0,0,0},{40,12,50},{n-1,n-1,n-1}}) {
        want:=film_encode(UNREAL_FILM,m,{f64(render.display_lut_value(p.x)),f64(render.display_lut_value(p.y)),f64(render.display_lut_value(p.z))})
        at:=(((p.z/render.DISPLAY_LUT_COLUMNS)*n+p.y)*size.x+(p.z%render.DISPLAY_LUT_COLUMNS)*n+p.x)*4
        for c in 0..<3 {testing.expectf(t,math.abs(f64(pixels[at+c])/255-want[c])<0.5/255+1e-9,"texel %v is %v, not %v",p,pixels[at:at+3],want)}
    }
}
