package unreal_scene

import "core:math"
import "core:mem"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

// The light Unreal's SkyAtmosphere gives the height fog of its level, worked
// out at import as Unreal's renderer works it out every frame: the air lit by
// its sun, marched along rays with the light that reaches each point through
// the air and what the air scatters again (a table by height and angle of the
// sun), sampled as Unreal samples it. Kilometres and 1/km, Unreal's axes (+Z
// up), the eye on the top of the planet.

// The air of a SkyAtmosphereComponent as Unreal's renderer takes it.
@(private)
Unreal_Air :: struct {
    bottom,top:f64,                   // radii of the ground and of the top of the air
    rayleigh:[3]f64,                  // scattering at the ground
    mie_scattering,mie_extinction:[3]f64,
    rayleigh_rate,mie_rate:f64,       // of the density per km of height, in powers of e
    ozone:[3]f64,                     // absorption where the density of the ozone is one
    ozone_tip:f64,                    // the height where its two lines meet
    ozone_lines:[2][2]f64,            // under and over it: slope and value at the ground
    ground_albedo:[3]f64,
    multiple:f64,                     // MultiScatteringFactor
    height_fog:f64,                   // HeightFogContribution
    sky_factor,light_factor:[3]f64,   // SkyLuminanceFactor, SkyAndAerialPerspectiveLuminanceFactor
    lowest_sun:f64,                   // TransmittanceMinLightElevationAngle, degrees
}

@(private)
unreal_air_read :: proc(d:^level.Document,ref:level.Ref) -> (air:Unreal_Air) {
    real :: proc(d:^level.Document,ref:level.Ref,name:string,default:f64) -> f64 {
        value,_:=level.real_of(d,ref,name,default)
        return value
    }
    scaled :: proc(d:^level.Document,ref:level.Ref,color,scale:string,default_color:[3]f32,default_scale:f64) -> [3]f64 {
        tint,_:=color_of(d,ref,color,default_color)
        s:=real(d,ref,scale,default_scale)
        return {max(f64(tint.r)*s,0),max(f64(tint.g)*s,0),max(f64(tint.b)*s,0)}
    }
    air.bottom=real(d,ref,"BottomRadius",6360)
    air.top=air.bottom+max(real(d,ref,"AtmosphereHeight",60),0.1)
    albedo,_:=color_of(d,ref,"GroundAlbedo",mm.srgb_to_linear([3]f32{170,170,170}/255))
    air.ground_albedo={f64(albedo.r),f64(albedo.g),f64(albedo.b)}
    air.multiple=clamp(real(d,ref,"MultiScatteringFactor",1),0,100)
    air.rayleigh=scaled(d,ref,"RayleighScattering","RayleighScatteringScale",{0.005802/0.0331,0.013558/0.0331,1},0.0331)
    air.rayleigh_rate=-1/real(d,ref,"RayleighExponentialDistribution",8)
    air.mie_scattering=scaled(d,ref,"MieScattering","MieScatteringScale",{1,1,1},0.003996)
    air.mie_extinction=air.mie_scattering+scaled(d,ref,"MieAbsorption","MieAbsorptionScale",{1,1,1},0.000444)
    air.mie_rate=-1/real(d,ref,"MieExponentialDistribution",1.2)
    air.ozone=scaled(d,ref,"OtherAbsorption","OtherAbsorptionScale",{0.000650/0.001881,1,0.000085/0.001881},0.001881)
    tent:=struct_chain(d,ref,"OtherTentDistribution")
    tip,_:=chain_real(&tent,"TipAltitude",25)
    value,_:=chain_real(&tent,"TipValue",1)
    width,_:=chain_real(&tent,"Width",15)
    if width>0 && value>0 {
        slope:=value/width
        air.ozone_tip=tip
        air.ozone_lines={{slope,value-tip*slope},{-slope,value+tip*slope}}
    }
    air.height_fog=real(d,ref,"HeightFogContribution",1)
    air.lowest_sun=real(d,ref,"TransmittanceMinLightElevationAngle",-90)
    factor :: proc(d:^level.Document,ref:level.Ref,name:string) -> [3]f64 {
        c,_:=color_of(d,ref,name,{1,1,1})
        return {f64(c.r),f64(c.g),f64(c.b)}
    }
    air.sky_factor=factor(d,ref,"SkyLuminanceFactor")
    air.light_factor=factor(d,ref,"SkyAndAerialPerspectiveLuminanceFactor")
    return
}

// What reaches the air from Unreal's sun and the light it adds to the
// height fog by HeightFogContribution: ambient, the sky far away as a medium
// of uniform phase scatters it, in nits; sun, the illuminance of the sun
// through the air over 4π, which the fog shows around the sun in its
// directional lobe. Zero without a SkyAtmosphere or a sun of it.
// sun_luminance: of the light of the sun of the fog, which multiplies its
// DirectionalInscatteringLuminance. light and scattering: that sun as the
// import writes it, its illuminance in each channel (lux) and the share of
// it media scatter.
Fog_Sky :: struct {ambient,sun,light:[3]f32,sun_luminance,scattering:f32}

fog_sky :: proc(c:^Context) -> (f:Fog_Sky) {
    d:=c.d
    atmosphere:=-1
    for actor in d.actors {
        if actor.class.name=="SkyAtmosphere" && actor.root>=0 {atmosphere=actor.root;break}
    }
    // Unreal's sun of the atmosphere is its brightest directional light of
    // index zero; the fog's is that one, or the brightest directional light.
    sun,any:=-1,-1
    sun_light,any_light:[3]f64
    for component,k in d.components {
        if component.class.name!="DirectionalLightComponent" {continue}
        if on,_:=level.bool_of(d,component.ref,"bAffectsWorld",true);!on {continue}
        m,_:=light_convert(unreal_light(c,k,.Directional))
        light:=[3]f64{f64(m.color.r*m.value),f64(m.color.g*m.value),f64(m.color.b*m.value)}
        if any<0 || unreal_luminance(light)>unreal_luminance(any_light) {any,any_light=k,light}
        version,_:=unreal.custom_version(level.library_package(d.library,int(component.ref.pkg)),unreal.UE5_MAIN_STREAM_VERSION)
        atmospheric:bool
        if version>=DIR_LIGHTS_ARE_ATMOSPHERE_LIGHTS {
            atmospheric,_=level.bool_of(d,component.ref,"bAtmosphereSunLight",true)
        } else {
            atmospheric,_=level.bool_of(d,component.ref,"bUsedAsAtmosphereSunLight",false)
        }
        index,_:=level.real_of(d,component.ref,"AtmosphereSunLightIndex",0)
        if !atmospheric || index!=0 {continue}
        if sun<0 || unreal_luminance(light)>unreal_luminance(sun_light) {sun,sun_light=k,light}
    }
    if sun>=0 {any,any_light=sun,sun_light}
    if any>=0 {
        f.sun_luminance=f32(unreal_luminance(any_light))
        _,m,_:=light_written(c,any,.Directional)
        f.light,f.scattering=m.color*m.value,m.scattering
    }
    if atmosphere<0 || sun<0 {return}
    world,error:=level.component_world(d,sun)
    if error.code!=.None {return}
    // The light shines toward its +X, Mirai's -Z; Unreal's x, y and z are Mirai's -z, x and y.
    forward:=mm.quat_rotate(world.rotation,{0,0,-1})
    toward:=-[3]f64{-f64(forward.z),f64(forward.x),f64(forward.y)}
    toward/=max(math.sqrt(toward.x*toward.x+toward.y*toward.y+toward.z*toward.z),1e-12)
    air:=unreal_air_read(d,d.components[atmosphere].ref)
    ambient,ok:=air_distant_light(&air,toward,sun_light)
    if !ok {
        warn(c,"the light the atmosphere gives the height fog could not be worked out: out of memory")
        return
    }
    ground:=sun_light*air_ground_transmittance(&air,toward)
    for i in 0..<3 {
        f.ambient[i]=f32(air.height_fog*ambient[i])
        f.sun[i]=f32(air.height_fog*ground[i]/(4*math.PI))
    }
    return
}

// The UE5MainStreamObjectVersion from which a directional light lights the
// atmosphere unless it says not to (bAtmosphereSunLight); before it, only
// when it says so (bUsedAsAtmosphereSunLight).
@(private)
DIR_LIGHTS_ARE_ATMOSPHERE_LIGHTS :: 38

// The luminance Unreal weighs a linear color by.
@(private)
unreal_luminance :: proc "contextless" (c:[3]f64) -> f64 {return 0.3*c.r+0.59*c.g+0.11*c.b}

// The sizes and sample counts of Unreal's tables of the air, and the height
// the sky far away is seen from.
@(private) AIR_TRANSMITTANCE_SIZE :: [2]int{256,64}
@(private) AIR_TRANSMITTANCE_SAMPLES :: 10
@(private) AIR_MULTIPLE_SIZE :: 32
@(private) AIR_MULTIPLE_SAMPLES :: 15
@(private) AIR_DISTANT_SAMPLES :: 10
@(private) AIR_DISTANT_HEIGHT :: 6
@(private) AIR_DISTANT_GROUP :: 8
// Where along each step Unreal samples the air.
@(private) AIR_SAMPLE_OFFSET :: 0.3
// How far over the ground the planet that shadows a point starts.
@(private) AIR_PLANET_OFFSET :: 0.001

// The tables of the air: the transmittance toward the top of the air (its
// square root, as Unreal keeps it) by height and angle, and what the air
// scatters again by height and angle of the sun.
@(private="file")
Air_Tables :: struct {
    transmittance:[][3]f64,
    multiple:[][3]f64,
}

// The light of the sky far away for a sun of
// illuminance light toward sun, as a medium of uniform phase scatters it.
@(private)
air_distant_light :: proc(air:^Unreal_Air,sun,light:[3]f64) -> (luminance:[3]f64,ok:bool) {
    tables:Air_Tables
    error:mem.Allocator_Error
    tables.transmittance,error=make([][3]f64,AIR_TRANSMITTANCE_SIZE.x*AIR_TRANSMITTANCE_SIZE.y,context.temp_allocator)
    if error!=nil {return}
    tables.multiple,error=make([][3]f64,AIR_MULTIPLE_SIZE*AIR_MULTIPLE_SIZE,context.temp_allocator)
    if error!=nil {return}
    for y in 0..<AIR_TRANSMITTANCE_SIZE.y {
        for x in 0..<AIR_TRANSMITTANCE_SIZE.x {
            height,cosine:=transmittance_place(air,{(f64(x)+0.5)/f64(AIR_TRANSMITTANCE_SIZE.x),(f64(y)+0.5)/f64(AIR_TRANSMITTANCE_SIZE.y)})
            r:=air_march(air,nil,{0,0,height},{0,math.sqrt(1-cosine*cosine),cosine},false,AIR_TRANSMITTANCE_SAMPLES,{0,0,1},{})
            tables.transmittance[y*AIR_TRANSMITTANCE_SIZE.x+x]={math.sqrt(math.exp(-r.depth.x)),math.sqrt(math.exp(-r.depth.y)),math.sqrt(math.exp(-r.depth.z))}
        }
    }
    // What the air scatters again: the light that reaches a point from up and
    // down, spread over the sphere, scattered again and again.
    for y in 0..<AIR_MULTIPLE_SIZE {
        for x in 0..<AIR_MULTIPLE_SIZE {
            cosine:=(f64(x)+0.5)/AIR_MULTIPLE_SIZE*2-1
            toward:=[3]f64{0,math.sqrt(clamp(1-cosine*cosine,0,1)),cosine}
            origin:=[3]f64{0,0,air.bottom+(f64(y)+0.5)/AIR_MULTIPLE_SIZE*(air.top-air.bottom)}
            up:=air_march(air,&tables,origin,{0,0,1},true,AIR_MULTIPLE_SAMPLES,toward,{1,1,1})
            down:=air_march(air,&tables,origin,{0,0,-1},true,AIR_MULTIPLE_SAMPLES,toward,{1,1,1})
            once:=(up.luminance+down.luminance)*0.5
            r:=(up.multiple+down.multiple)*0.5
            tables.multiple[y*AIR_MULTIPLE_SIZE+x]=once*(1+r+r*r+r*r*r+r*r*r*r)*air.multiple
        }
    }
    // Unreal's directions over the sphere: a jittered grid of its random stream.
    seed:=u32(0xDE4DC0DE)
    fraction :: proc(seed:^u32) -> f32 {
        seed^=seed^*196314165+907633515
        return transmute(f32)(0x3F800000|(seed^>>9))-1
    }
    origin:=[3]f64{0,0,air.bottom+AIR_DISTANT_HEIGHT}
    for i in 0..<AIR_DISTANT_GROUP {
        for j in 0..<AIR_DISTANT_GROUP {
            u0:=(f32(i)+fraction(&seed))*(1/f32(AIR_DISTANT_GROUP))
            u1:=(f32(j)+fraction(&seed))*(1/f32(AIR_DISTANT_GROUP))
            z:=1-2*f64(u0)
            across:=math.sqrt(1-z*z)
            phi:=2*math.PI*f64(u1)
            r:=air_march(air,&tables,origin,{across*math.cos(phi),across*math.sin(phi),z},false,AIR_DISTANT_SAMPLES,sun,light*air.light_factor,multiple=true)
            luminance+=r.luminance*air.sky_factor
        }
    }
    return luminance/(AIR_DISTANT_GROUP*AIR_DISTANT_GROUP),true
}

// What a march along a ray gives: the light the air scatters toward its
// origin, the share of a uniform light the air scatters once and the
// optical depth.
@(private="file")
Air_March :: struct {luminance,multiple,depth:[3]f64}

// A march of samples steps from origin along dir to the top of the air or
// the ground, lit by a light of illuminance light toward toward, with the
// light off the ground when ground and the light the air scatters again when
// multiple.
@(private="file")
air_march :: proc(air:^Unreal_Air,tables:^Air_Tables,origin,dir:[3]f64,ground:bool,samples:int,toward,light:[3]f64,multiple:=false) -> (r:Air_March) {
    if dot3(origin,origin)<=air.bottom*air.bottom {return}
    bottom:=sphere_hits(origin,dir,air.bottom)
    top:=sphere_hits(origin,dir,air.top)
    end,ground_at:f64
    switch {
    case top.x<0 && top.y<0:return
    case bottom.x<0 && bottom.y<0:end=max(top.x,top.y)
    case:
        ground_at=max(0,min(bottom.x,bottom.y))
        end=ground_at
    }
    end=min(end,9000000)
    step:=end/f64(samples)
    UNIFORM :: 1/(4*math.PI)
    through:=[3]f64{1,1,1}
    lit:=light!={}
    for i in 0..<samples {
        p:=origin+dir*(end*(f64(i)+AIR_SAMPLE_OFFSET)/f64(samples))
        height:=math.sqrt(dot3(p,p))
        scattering,extinction:=air_sample(air,p)
        depth:=extinction*step
        passed:=[3]f64{math.exp(-depth.x),math.exp(-depth.y),math.exp(-depth.z)}
        r.depth+=depth
        source:[3]f64
        if lit {
            up:=p/height
            cosine:=dot3(toward,up)
            shadow:=sphere_nearest(p,toward,up*AIR_PLANET_OFFSET,air.bottom)>=0?0.0:1.0
            again:[3]f64
            if multiple {again=air_multiple(air,tables,cosine,height)}
            source=light*(shadow*air_transmittance(air,tables,cosine,height)*scattering*UNIFORM+again*scattering)
        }
        r.multiple+=through*scattering*step
        for c in 0..<3 {r.luminance[c]+=through[c]*(source[c]-source[c]*passed[c])/max(extinction[c],1e-9)}
        through*=passed
    }
    if ground && end==ground_at && lit {
        p:=origin+dir*ground_at
        height:=math.sqrt(dot3(p,p))
        up:=p/height
        facing:=clamp(dot3(up,toward),0,1)
        r.luminance+=light*air_transmittance(air,tables,dot3(toward,up),height)*through*facing*air.ground_albedo/math.PI
    }
    return
}

// The scattering and extinction of the air at p.
@(private="file")
air_sample :: proc(air:^Unreal_Air,p:[3]f64) -> (scattering,extinction:[3]f64) {
    height:=max(0,math.sqrt(dot3(p,p))-air.bottom)
    mie:=math.exp(air.mie_rate*height)
    rayleigh:=math.exp(air.rayleigh_rate*height)
    line:=air.ozone_lines[height<air.ozone_tip?0:1]
    ozone:=clamp(line[0]*height+line[1],0,1)
    scattering=mie*air.mie_scattering+rayleigh*air.rayleigh
    extinction=mie*air.mie_extinction+rayleigh*air.rayleigh+ozone*air.ozone
    return
}

// The height and the cosine from the zenith of a texel of the table of the
// transmittance (Bruneton's): more texels toward the horizon and the ground.
@(private="file")
transmittance_place :: proc(air:^Unreal_Air,uv:[2]f64) -> (height,cosine:f64) {
    h:=math.sqrt(air.top*air.top-air.bottom*air.bottom)
    rho:=h*uv.y
    height=math.sqrt(rho*rho+air.bottom*air.bottom)
    nearest:=air.top-height
    farthest:=rho+h
    d:=nearest+uv.x*(farthest-nearest)
    cosine=d==0?1:(h*h-rho*rho-d*d)/(2*height*d)
    return height,clamp(cosine,-1,1)
}

// The transmittance from a point at height toward the top of the air along
// cosine from the zenith, read from its table as a GPU reads it.
@(private="file")
air_transmittance :: proc(air:^Unreal_Air,tables:^Air_Tables,cosine,height:f64) -> [3]f64 {
    h:=math.sqrt(max(0,air.top*air.top-air.bottom*air.bottom))
    rho:=math.sqrt(max(0,height*height-air.bottom*air.bottom))
    discriminant:=height*height*(cosine*cosine-1)+air.top*air.top
    d:=max(0,-height*cosine+math.sqrt(max(discriminant,0)))
    nearest:=air.top-height
    farthest:=rho+h
    root:=bilinear(tables.transmittance,AIR_TRANSMITTANCE_SIZE,{(d-nearest)/(farthest-nearest),rho/h})
    return root*root
}

// What the air scatters again at height for a sun at cosine from the zenith.
@(private="file")
air_multiple :: proc(air:^Unreal_Air,tables:^Air_Tables,cosine,height:f64) -> [3]f64 {
    uv:=[2]f64{clamp(cosine*0.5+0.5,0,1),clamp((height-air.bottom)/(air.top-air.bottom),0,1)}
    return bilinear(tables.multiple,{AIR_MULTIPLE_SIZE,AIR_MULTIPLE_SIZE},uv)
}

// A table read between its texels at uv, clamped to its edge.
@(private="file")
bilinear :: proc(texels:[][3]f64,size:[2]int,uv:[2]f64) -> [3]f64 {
    x:=uv.x*f64(size.x)-0.5
    y:=uv.y*f64(size.y)-0.5
    fx,fy:=x-math.floor(x),y-math.floor(y)
    x0,y0:=int(math.floor(x)),int(math.floor(y))
    at :: proc(texels:[][3]f64,size:[2]int,x,y:int) -> [3]f64 {return texels[clamp(y,0,size.y-1)*size.x+clamp(x,0,size.x-1)]}
    upper:=at(texels,size,x0,y0)*(1-fx)+at(texels,size,x0+1,y0)*fx
    lower:=at(texels,size,x0,y0+1)*(1-fx)+at(texels,size,x0+1,y0+1)*fx
    return upper*(1-fy)+lower*fy
}

// The transmittance of the air from half a kilometre over the ground toward
// the sun, which Unreal multiplies the light of its sun by on the ground:
// fifteen steps with no offset, as Unreal counts them in single precision.
@(private)
air_ground_transmittance :: proc(air:^Unreal_Air,sun:[3]f64) -> [3]f64 {
    elevation:=math.atan2(sun.z,math.sqrt(sun.x*sun.x+sun.y*sun.y))
    elevation=max(elevation,air.lowest_sun*math.RAD_PER_DEG)
    origin:=[3]f64{0,0,air.bottom+0.5}
    dir:=[3]f64{math.cos(elevation),0,math.sin(elevation)}
    end:=sphere_nearest(origin,dir,{},air.top)
    depth:[3]f64
    if end>0 {
        STEPS :: 15
        step:=f32(1)/STEPS
        for along:=f32(0);along<1;along+=step {
            _,extinction:=air_sample(air,origin+dir*(end*f64(along)))
            depth+=extinction*(f64(step)*end)
        }
    }
    return {math.exp(-depth.x),math.exp(-depth.y),math.exp(-depth.z)}
}

// The distances along dir from origin to a sphere about the centre of the
// planet, near and far; both -1 without a hit.
@(private="file")
sphere_hits :: proc(origin,dir:[3]f64,radius:f64) -> [2]f64 {
    b:=2*dot3(dir,origin)
    c:=dot3(origin,origin)-radius*radius
    a:=dot3(dir,dir)
    discriminant:=b*b-4*a*c
    if discriminant<0 {return {-1,-1}}
    root:=math.sqrt(discriminant)
    return {(-b-root)/(2*a),(-b+root)/(2*a)}
}

// The distance to the nearest hit ahead with a sphere about centre, or -1.
@(private="file")
sphere_nearest :: proc(origin,dir,centre:[3]f64,radius:f64) -> f64 {
    hits:=sphere_hits(origin-centre,dir,radius)
    switch {
    case hits.x<0 && hits.y<0:return -1
    case hits.x<0:return max(0,hits.y)
    case hits.y<0:return max(0,hits.x)
    }
    return max(0,min(hits.x,hits.y))
}

@(private="file")
dot3 :: proc "contextless" (a,b:[3]f64) -> f64 {return a.x*b.x+a.y*b.y+a.z*b.z}
