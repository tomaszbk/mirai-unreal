package unreal_scene

import "core:math"
import "core:math/linalg"
import img "mirai:cook/image"
import render "mirai:engine/render"

// How Unreal's tonemapper takes the exposed image to an SDR display: its film
// curve, applied to each channel over the AP1 primaries, after it widens
// bright saturated colours and before it encodes sRGB. A colour brighter
// than the display runs to white one channel at a time, so a bright violet
// turns pink and then white, where a transform that keeps hue keeps it
// violet. Baked as Mirai's display LUT of the project (Display_Transform.LUT).
Unreal_Film :: struct {
    slope,toe,shoulder:f64,          // FilmSlope, FilmToe, FilmShoulder
    black_clip,white_clip:f64,       // FilmBlackClip, FilmWhiteClip
    blue_correction:f64,             // BlueCorrection: how much bright blues keep from turning violet
    expand_gamut:f64,                // ExpandGamut: how much bright saturated colours widen
    tone_curve_amount:f64,           // ToneCurveAmount: 0 leaves the colours untouched by the curve
}

// The defaults of Unreal's post process.
UNREAL_FILM :: Unreal_Film{slope=0.88,toe=0.55,shoulder=0.26,black_clip=0,white_clip=0.04,blue_correction=0.6,expand_gamut=1,tone_curve_amount=1}

// A display LUT of the film written at path: an RGBA PNG in the layout of
// render.display_lut_texture_size, to import uncompressed as data; and the
// exposed gray it shows as Mirai's transforms show the card
// (Display_Transform_Settings.lut_gray). Its eight bits a channel are those
// of the display it encodes for.
display_lut_write :: proc(film:Unreal_Film,path:string) -> (gray:f32,ok:bool) {
    size:=render.display_lut_texture_size()
    pixels:=display_lut_pixels(film,context.temp_allocator)
    if img.image_write(path,{pixels=pixels,width=size.x,height=size.y})!=.None {return}
    return film_gray(film,film_matrices()),true
}

// The RGBA8 texels of the display LUT of the film, rows from the top.
display_lut_pixels :: proc(film:Unreal_Film,allocator:=context.allocator) -> []u8 {
    size:=render.display_lut_texture_size()
    n:=render.DISPLAY_LUT_SIZE
    m:=film_matrices()
    pixels:=make([]u8,size.x*size.y*4,allocator)
    for z in 0..<n {
        for y in 0..<n {
            for x in 0..<n {
                scene:=[3]f64{f64(render.display_lut_value(x)),f64(render.display_lut_value(y)),f64(render.display_lut_value(z))}
                shown:=film_encode(film,m,scene)
                px:=(z%render.DISPLAY_LUT_COLUMNS)*n+x
                py:=(z/render.DISPLAY_LUT_COLUMNS)*n+y
                at:=(py*size.x+px)*4
                for c in 0..<3 {pixels[at+c]=u8(math.round(clamp(shown[c],0,1)*255))}
                pixels[at+3]=255
            }
        }
    }
    return pixels
}

// The exposed gray the film shows as the linear light render.DISPLAY_GRAY.
film_gray :: proc(film:Unreal_Film,m:Film_Matrices) -> f32 {
    low,high:=math.log2(f64(1e-4)),math.log2(f64(100))
    for _ in 0..<60 {
        mid:=0.5*(low+high)
        g:=math.pow(2,mid)
        if srgb_decode(film_encode(film,m,{g,g,g}).g)<f64(render.DISPLAY_GRAY) {low=mid} else {high=mid}
    }
    return f32(math.pow(2,0.5*(low+high)))
}

// The matrices of the film, from the chromaticities of the primaries.
@(private)
Film_Matrices :: struct {
    srgb_to_ap1,ap1_to_srgb,ap1_to_ap0,ap0_to_ap1,expand,blue,blue_inverse:matrix[3,3]f64,
    luma:[3]f64, // the luminance of an AP1 colour
}

@(private)
film_matrices :: proc() -> (m:Film_Matrices) {
    D65:=[2]f64{0.3127,0.3290}
    D60:=[2]f64{0.32168,0.33767}
    srgb:=primaries_to_xyz({0.64,0.33},{0.30,0.60},{0.15,0.06},D65)
    ap0:=primaries_to_xyz({0.7347,0.2653},{0.0,1.0},{0.0001,-0.0770},D60)
    ap1:=primaries_to_xyz({0.713,0.293},{0.165,0.830},{0.128,0.044},D60)
    // Primaries between P3 and AP1 that bright saturated colours widen toward.
    wide:=primaries_to_xyz({0.6965,0.3065},{0.245,0.718},{0.1302,0.0456},D65)
    to_d60:=bradford(D65,D60)
    m.srgb_to_ap1=linalg.inverse(ap1)*to_d60*srgb
    m.ap1_to_srgb=linalg.inverse(m.srgb_to_ap1)
    m.ap1_to_ap0=linalg.inverse(ap0)*ap1
    m.ap0_to_ap1=linalg.inverse(m.ap1_to_ap0)
    m.expand=linalg.inverse(ap1)*wide*m.ap1_to_srgb
    // Bright blues desaturate toward white rather than turn violet: a correction in AP0.
    blue_ap0:=matrix[3,3]f64{
        0.9404372683,-0.0183068787,0.0778696104,
        0.0083786969, 0.8286599939,0.1629613092,
        0.0005471261,-0.0008833746,1.0003362486,
    }
    m.blue=m.ap0_to_ap1*blue_ap0*m.ap1_to_ap0
    m.blue_inverse=linalg.inverse(m.blue)
    m.luma={ap1[1,0],ap1[1,1],ap1[1,2]}
    return
}

// The matrix from linear RGB of three primaries and a white to CIE XYZ.
@(private)
primaries_to_xyz :: proc(r,g,b,w:[2]f64) -> matrix[3,3]f64 {
    xyz :: proc(c:[2]f64) -> [3]f64 {return {c.x/c.y,1,(1-c.x-c.y)/c.y}}
    pr,pg,pb,pw:=xyz(r),xyz(g),xyz(b),xyz(w)
    p:=matrix[3,3]f64{pr.x,pg.x,pb.x,pr.y,pg.y,pb.y,pr.z,pg.z,pb.z}
    s:=linalg.inverse(p)*pw
    return p*matrix[3,3]f64{s.x,0,0,0,s.y,0,0,0,s.z}
}

// The Bradford adaptation of XYZ from one white to another.
@(private)
bradford :: proc(from,to:[2]f64) -> matrix[3,3]f64 {
    cone:=matrix[3,3]f64{0.8951,0.2664,-0.1614,-0.7502,1.7135,0.0367,0.0389,-0.0685,1.0296}
    white :: proc(c:[2]f64) -> [3]f64 {return {c.x/c.y,1,(1-c.x-c.y)/c.y}}
    a,b:=cone*white(from),cone*white(to)
    return linalg.inverse(cone)*matrix[3,3]f64{b.x/a.x,0,0,0,b.y/a.y,0,0,0,b.z/a.z}*cone
}

// The encoded sRGB colour the display shows for an exposed scene-linear Rec.709 one.
@(private)
film_encode :: proc(film:Unreal_Film,m:Film_Matrices,scene:[3]f64) -> [3]f64 {
    c:=m.srgb_to_ap1*scene
    luma:=linalg.dot(c,m.luma)
    if luma>0 {
        chroma:=c/luma-1
        amount:=(1-math.pow(2,-4*linalg.dot(chroma,chroma)))*(1-math.pow(2,-4*film.expand_gamut*luma*luma))
        c=linalg.lerp(c,m.expand*c,amount)
    }
    c=linalg.lerp(c,m.blue*c,film.blue_correction)
    c=linalg.lerp(c,film_tone(film,m,c),film.tone_curve_amount)
    c=linalg.lerp(c,m.blue_inverse*c,film.blue_correction)
    out:=m.ap1_to_srgb*c
    for &v in out {v=srgb_encode(clamp(v,0,1))}
    return out
}

// The film curve over an AP1 colour, after the glow and the red modifier of
// the ACES 1 reference rendering transform.
@(private)
film_tone :: proc(film:Unreal_Film,m:Film_Matrices,c:[3]f64) -> [3]f64 {
    a:=m.ap1_to_ap0*c
    high,low:=max(a.r,a.g,a.b),min(a.r,a.g,a.b)
    saturation:=(max(high,1e-10)-max(low,1e-10))/max(high,1e-2)
    // Glow: dark saturated colours a little brighter.
    yc:=(a.b+a.g+a.r+1.75*math.sqrt(max(a.b*(a.b-a.g)+a.g*(a.g-a.r)+a.r*(a.r-a.b),0)))/3
    x:=(saturation-0.4)/0.2
    t:=max(1-abs(x/2),0)
    shaper:=(1+math.sign(x)*(1-t*t))/2
    gain:=0.05*shaper
    glow:f64
    switch {
    case yc<=2.0/3.0*0.08:glow=gain
    case yc>=2*0.08:glow=0
    case:glow=gain*(0.08/yc-0.5)
    }
    a*=1+glow
    // Red modifier: saturated reds a little less bright.
    hue:=0.0
    if !(a.r==a.g&&a.g==a.b) {
        hue=math.to_degrees(math.atan2(math.sqrt(f64(3))*(a.g-a.b),2*a.r-a.g-a.b))
        if hue<0 {hue+=360}
    }
    if hue>180 {hue-=360}
    weight:=math.smoothstep(0.0,1.0,1-abs(2*hue/135))
    a.r+=weight*weight*saturation*(0.03-a.r)*(1-0.82)
    w:=m.ap0_to_ap1*a
    for &v in w {v=max(v,0)}
    y:=linalg.dot(w,m.luma)
    w=linalg.lerp([3]f64{y,y,y},w,0.96)
    // Toe, straight and shoulder in log10, matched so 0.18 shows as 0.18.
    toe_scale:=1+film.black_clip-film.toe
    shoulder_scale:=1+film.white_clip-film.shoulder
    toe_match:f64
    if film.toe>0.8 {
        toe_match=(1-film.toe-0.18)/film.slope+math.log10(f64(0.18))
    } else {
        bt:=(0.18+film.black_clip)/toe_scale-1
        toe_match=math.log10(f64(0.18))-0.5*math.ln((1+bt)/(1-bt))*(toe_scale/film.slope)
    }
    straight_match:=(1-film.toe)/film.slope-toe_match
    shoulder_match:=film.shoulder/film.slope-straight_match
    out:[3]f64
    for i in 0..<3 {
        l:=math.log10(max(w[i],1e-10))
        straight:=film.slope*(l+straight_match)
        toe:=l<toe_match ? -film.black_clip+2*toe_scale/(1+math.exp(-2*film.slope/toe_scale*(l-toe_match))) : straight
        shoulder:=l>shoulder_match ? 1+film.white_clip-2*shoulder_scale/(1+math.exp(2*film.slope/shoulder_scale*(l-shoulder_match))) : straight
        s:=clamp((l-toe_match)/(shoulder_match-toe_match),0,1)
        if shoulder_match<toe_match {s=1-s}
        s=(3-2*s)*s*s
        out[i]=toe+(shoulder-toe)*s
    }
    y=linalg.dot(out,m.luma)
    out=linalg.lerp([3]f64{y,y,y},out,0.93)
    for &v in out {v=max(v,0)}
    return out
}

@(private)
srgb_encode :: proc(v:f64) -> f64 {return v<=0.0031308 ? 12.92*v : 1.055*math.pow(v,1/2.4)-0.055}

@(private)
srgb_decode :: proc(v:f64) -> f64 {return v<=0.04045 ? v/12.92 : math.pow((v+0.055)/1.055,2.4)}
