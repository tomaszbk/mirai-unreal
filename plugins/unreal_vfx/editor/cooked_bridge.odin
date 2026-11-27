package unreal_vfx_editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"
import cooked "project:plugins/unreal/editor/cooked"

// Cooked -> Native Mirai VFX Bridge: consumes `ue5parse niagara` JSON
// (`Schema: "ue5parse.niagara/2"`, including VectorVM2-decompiled scripts)
// and builds native Mirai `.particle` assets (`effect.Particle_Info` +
// validated bytes), generated Mirai Vfx Slang shaders (`//! mirai vfx ...`),
// and native `.mat` v6 materials (`cooked.Cooked_Material`).

// One renderer of an emitter: a layer of the effect.
Cooked_Vfx_Layer :: struct {
    renderer:string,       // "sprite", "mesh", "ribbon" or "light", as the description names it
    factory:string,        // the vertex factory of the game's shaders that draws it; "" for a light
    info:effect.Particle_Info,
    program_name:string,   // "" when its scripts read what has no answer here: see notes
    program_source:string, // the Vfx program that runs its scripts (cooked_program.odin)
    notes:[]string,        // what its scripts read that is not answered
    limits:[]string,       // what its particles show that an effect cannot
    material_path:string,  // of the game: what draws its particles
    mesh_paths:[]string,   // of the game: what its particles are, for a mesh renderer
    order:i32,             // among the layers of its system, the lower drawn first (SortOrderHint)
    textures:[]string,     // what the parameters field0, field1... of its program take: vector fields of the game, by path
    follows:string,        // the socket or bone of a skeletal mesh its emitter goes on; "" for none
    follows_socket:bool,
    resources:[]Cooked_Vfx_Resource, // Mirai resources (`//! resource <name> <kind>`) its program binds
}

Cooked_Vfx_Emitter :: struct {
    name:string,
    enabled:bool,
    gpu:bool,
    layers:[]Cooked_Vfx_Layer,
    warnings:[]string,
}

Cooked_Vfx_System :: struct {
    name:string,
    pkg:string,
    emitters:[]Cooked_Vfx_Emitter,
    materials:[]cooked.Cooked_Material,
}

// Frees all allocations owned by a Cooked_Vfx_System produced with `allocator`.
cooked_vfx_system_destroy :: proc(sys:^Cooked_Vfx_System,allocator:=context.allocator) {
    delete(sys.name,allocator)
    delete(sys.pkg,allocator)
    for &em in sys.emitters {
        delete(em.name,allocator)
        for &layer in em.layers {
            delete(layer.renderer,allocator)
            delete(layer.factory,allocator)
            delete(layer.program_name,allocator)
            delete(layer.program_source,allocator)
            delete(layer.material_path,allocator)
            for mp in layer.mesh_paths {delete(mp,allocator)}
            delete(layer.mesh_paths,allocator)
            for n in layer.notes {delete(n,allocator)}
            delete(layer.notes,allocator)
            for n in layer.limits {delete(n,allocator)}
            delete(layer.limits,allocator)
            for n in layer.textures {delete(n,allocator)}
            delete(layer.textures,allocator)
            delete(layer.follows,allocator)
            for r in layer.resources {delete(r.name,allocator);delete(r.kind,allocator)}
            delete(layer.resources,allocator)
        }
        delete(em.layers,allocator)
        for w in em.warnings {delete(w,allocator)}
        delete(em.warnings,allocator)
    }
    delete(sys.emitters,allocator)
    for &m in sys.materials {cooked.cooked_material_destroy(&m,allocator)}
    delete(sys.materials,allocator)
    sys^={}
}

// Shared inputs from UNiagaraLightRendererProperties and particle attributes,
// converted into a native Mirai .particle v10 effect.Particle_Light in one place.
@(private)
Niagara_Light_Params :: struct {
    radius_scale:f32,          // UNiagaraLightRendererProperties::RadiusScale (default 1.0)
    diffuse_scale:f32,         // UNiagaraLightRendererProperties::DiffuseScale (default 1.0)
    inverse_squared:bool,      // UNiagaraLightRendererProperties::bUseInverseSquaredFalloff (default true)
    default_exponent:f32,      // UNiagaraLightRendererProperties::DefaultExponent (default 1.0)
    alpha_scales_brightness:bool, // UNiagaraLightRendererProperties::bAlphaScalesBrightness
    color_add:[3]f32,          // UNiagaraLightRendererProperties::ColorAdd
    has_color_add:bool,
    explicit_range_m:f32,      // explicit light range in metres (>0 overrides radius_cm)
    explicit_intensity:f32,    // explicit intensity in cd (>0 overrides UE simple-light derivation)
    explicit_source_radius_m:f32,
    particle_radius_cm:f32,    // Particles.LightRadius (cm) when known
    particle_intensity:f32,    // Particles.LightIntensity / LightBrightness (cd) when known
    particle_color:[3]f32,     // Particles.LightColor when known
    has_particle_color:bool,
    particle_scattering:f32,   // >=0 when explicitly specified
    renderer_scattering:f32,   // default 1.0
    indirect:f32,              // default 1.0
    shadows:bool,
    fallback_sprite_size_m:f32,
    fallback_color:[4]f32,
    fallback_color_intensity:f32, // Particle_Info.intensity multiplying fallback_color.rgb
}

// Builds a native Mirai effect.Particle_Light from extracted UNiagaraLightRendererProperties
// using UE6's exact simple-light irradiance calibration:
//   SimpleLight.Color = ParticleColor * Brightness + ColorAdd
//   - Inverse squared (UE6 default): Irradiance = Color * DiffuseScale / d_cm^2 -> cd = peak / 10000
//   - Non-inverse squared (windowed exponent): matched at half radius -> cd = peak * 0.75^exp * (R/2)^2
@(private)
niagara_particle_light :: proc(p:Niagara_Light_Params) -> effect.Particle_Light {
    radius_scale:=p.radius_scale>0 ? p.radius_scale : 1.0
    diffuse_scale:=p.diffuse_scale>0 ? p.diffuse_scale : 1.0
    lrange:=p.explicit_range_m
    if lrange<=0 {
        if p.particle_radius_cm>0 {
            lrange=p.particle_radius_cm*cooked.UNREAL_TO_MIRAI_SCALE*max(radius_scale,0.01)
        } else {
            // UE UNiagaraLightRendererProperties default LightRadius (100 cm = 1 m) scaled by RadiusScale.
            lrange=1.0*max(radius_scale,0.1)
        }
    }
    brightness:=p.alpha_scales_brightness ? clamp(p.fallback_color.w,0,1) : f32(1)
    p_scale:=p.fallback_color_intensity>0 ? p.fallback_color_intensity : f32(1)
    fb_rgb:=[3]f32{max(p.fallback_color.x,0),max(p.fallback_color.y,0),max(p.fallback_color.z,0)}
    fb_peak:=max(fb_rgb.x,max(fb_rgb.y,fb_rgb.z))

    // Mirai multiplies light.intensity by light.color, or by unnormalized particle color
    // when light.color == {0,0,0}. Match exact intensity * effective_color in both cases:
    //  - Explicit color (LightColor / ColorAdd): always normalize light.color by peak when
    //    peak > 0 so dim colors (< 1) are never squared.
    //  - Particle-color light (light.color == {0,0,0}): do NOT multiply ue_peak by fb_peak,
    //    since Mirai already multiplies by the unnormalized particle color itself.
    lcolor:[3]f32
    ue_peak:f32
    if p.has_particle_color || p.has_color_add {
        base_rgb:=p.has_particle_color ? [3]f32{max(p.particle_color.x,0),max(p.particle_color.y,0),max(p.particle_color.z,0)} : fb_rgb*p_scale
        ue_color:=base_rgb*brightness+{max(p.color_add.x,0),max(p.color_add.y,0),max(p.color_add.z,0)}
        cmax:=max(ue_color.x,max(ue_color.y,ue_color.z))
        if cmax>0 {
            lcolor=ue_color/cmax
            ue_peak=cmax*max(diffuse_scale,0)
        }
    } else if fb_peak>0 {
        ue_peak=p_scale*brightness*max(diffuse_scale,0)
    }

    lintensity:=p.explicit_intensity
    if lintensity<=0 {lintensity=p.particle_intensity}
    if lintensity<=0 && ue_peak>0 {
        if p.inverse_squared {
            // UE simple lights divide by d_cm^2 = 10000 * d_m^2; Mirai divides by d_m^2.
            lintensity=ue_peak/10000.0
        } else {
            // Windowed radial falloff matched at half its attenuation radius (same as unreal_scene.light_convert).
            half:=lrange*0.5
            lintensity=ue_peak*math.pow(f32(0.75),max(p.default_exponent,0))*half*half
        }
    }
    lradius:=p.explicit_source_radius_m>0 ? p.explicit_source_radius_m : min(max(p.fallback_sprite_size_m*0.5,0),max(lrange,0))
    lscatter:=p.particle_scattering>=0 ? p.particle_scattering : max(p.renderer_scattering,0)
    return {
        color=lcolor,
        intensity=max(lintensity,0),
        range=max(lrange,0),
        radius=clamp(lradius,0,max(lrange,0)),
        shadows=p.shadows,
        indirect=max(p.indirect,0),
        scattering=max(lscatter,0),
    }
}

// Parses a `ue5parse.niagara/2` JSON document into native Mirai `.particle`
// emitters + Vfx Slang shaders + native `.mat` v6 materials.
// A value a game gives a parameter of the user of a system in place of its default, by the
// name of the parameter ("User.ColorVariant").
Cooked_User_Value :: struct {name:string,value:f64}

cooked_niagara_build :: proc(json_text:string,allocator:=context.allocator,user:[]Cooked_User_Value=nil,fields:[]Cooked_Field=nil,skeleton:Cooked_Skeleton={}) -> (sys:Cooked_Vfx_System,err:Maybe(cooked.Error)) {
    if len(json_text)==0 {return {},cooked.Error{"niagara","empty JSON"}}
    root,jerr:=json.parse_string(json_text,allocator=context.temp_allocator)
    if jerr!=.None {return {},cooked.Error{"niagara","malformed JSON"}}
    obj,ok:=root.(json.Object)
    if !ok {return {},cooked.Error{"niagara","root JSON value must be an object"}}
    if schema:=jstr(obj["Schema"]);schema!="" && !strings.has_prefix(schema,"ue5parse.niagara/") {
        return {},cooked.Error{"niagara",fmt.tprintf("unexpected schema %q",schema)}
    }

    // What the game sets of the user's parameters, before the scripts read them.
    if params,has_params:=obj["UserParameters"].(json.Array);has_params {
        for item in params {
            pobj,pok:=item.(json.Object)
            if !pok {continue}
            for given in user {
                if jstr(pobj["Name"])==given.name {pobj["Value"]=json.Float(given.value)}
            }
        }
    }
    sys.name=strings.clone(jstr(obj["Name"],"NiagaraSystem"),allocator)
    sys.pkg=strings.clone(jstr(obj["Package"]),allocator)

    // Parse embedded cooked material descriptions (for BlendMode / ShadingModel / native .mat v6).
    mat_list:=make([dynamic]cooked.Cooked_Material,allocator)
    mat_by_path:=make(map[string]^cooked.Cooked_Material,allocator=context.temp_allocator)
    if mats,has_m:=obj["Materials"].(json.Array);has_m {
        for item in mats {
            if mobj,mok:=item.(json.Object);mok {
                if _,has_err:=mobj["Error"];has_err {continue}
                raw,merr:=json.marshal(item,allocator=context.temp_allocator)
                if merr!=nil {continue}
                if cm,cerr:=cooked.cooked_material_parse(string(raw),allocator);cerr==nil {
                    append(&mat_list,cm)
                }
            }
        }
    }
    sys.materials=mat_list[:]
    for &m in sys.materials {
        if m.path!="" {mat_by_path[m.path]=&m}
    }

    em_list:=make([dynamic]Cooked_Vfx_Emitter,allocator)
    if emitters,has_e:=obj["Emitters"].(json.Array);has_e {
        for item in emitters {
            eobj,eok:=item.(json.Object)
            if !eok {continue}
            append(&em_list,build_cooked_emitter(sys.name,obj,eobj,mat_by_path,fields,skeleton,allocator))
        }
    }
    sys.emitters=em_list[:]
    return sys,nil
}

// The particles a layer keeps alive at once where the emitter does not say: an emitter of
// the game sizes itself as it runs, an effect says it beforehand.
COOKED_PARTICLES_CPU :: 512
COOKED_PARTICLES_GPU :: 4096
// The cycle of a layer: its scripts keep their own loops and say when it emits, so the effect
// only starts it over when its emitter is started again.
COOKED_CYCLE_SECONDS :: f32(3600)

@(private="file")
RENDERER_FACTORIES :: [?][2]string{{"sprite","NiagaraSpriteVF"},{"mesh","NiagaraMeshVF"},{"ribbon","NiagaraRibbonVF"}}

@(private="file")
build_cooked_emitter :: proc(
    system_name:string,
    system:json.Object,
    eobj:json.Object,
    mat_by_path:map[string]^cooked.Cooked_Material,
    fields:[]Cooked_Field,
    skeleton:Cooked_Skeleton,
    allocator:mem.Allocator,
) -> (out:Cooked_Vfx_Emitter) {
    out.name=strings.clone(jstr(eobj["Name"],"Emitter"),allocator)
    out.enabled=jbool(eobj["Enabled"],true)
    out.gpu=strings.equal_fold(jstr(eobj["Target"]),"GPU")
    warns:=make([dynamic]string,allocator)
    if note:=jstr(eobj["Note"]);note!="" {append(&warns,strings.clone(note,allocator))}

    base_info:=effect.PARTICLE_DEFAULTS
    base_info.duration=COOKED_CYCLE_SECONDS
    base_info.rate=0
    base_info.soft=0
    base_info.lit=false
    base_info.size_over_life=effect.PARTICLE_CURVE_ONE
    base_info.color_over_life={colors={{1,1,1,1},{1,1,1,1},{},{},{},{},{},{}},times={0,1,1,1,1,1,1,1}}
    base_info.max_particles=out.gpu ? COOKED_PARTICLES_GPU : COOKED_PARTICLES_CPU
    if settings,has_s:=eobj["Settings"].(json.Object);has_s {
        base_info.local_space=jbool(settings["bLocalSpace"],false)
        if count,ok:=jf32(settings["PreAllocationCount"]);ok && count>0 {
            base_info.max_particles=u32(clamp(count,1,65536))
        }
    }

    has_scripts:=false
    if scripts,has_sc:=eobj["Scripts"].(json.Array);has_sc {
        for sc in scripts {
            if sobj,sok:=sc.(json.Object);sok && strings.contains(jstr(sobj["Usage"]),"Particle") {has_scripts=true}
        }
    }

    layers:=make([dynamic]Cooked_Vfx_Layer,allocator)
    rends,_:=eobj["Renderers"].(json.Array)
    for r,index in rends {
        robj,rok:=r.(json.Object)
        if !rok || !jbool(robj["Enabled"],true) {continue}
        kind:=strings.to_lower(jstr(robj["Kind"]),context.temp_allocator)
        settings,_:=robj["Settings"].(json.Object)
        layer:Cooked_Vfx_Layer
        layer.info=base_info
        limits:=make([dynamic]string,allocator)
        if order,ok:=jf32(settings["SortOrderHint"]);ok {layer.order=i32(clamp(order,-1e6,1e6))}
        if sub,has_sub:=settings["SubImageSize"].(json.Object);has_sub {
            sx,_:=jf32(sub["X"],1)
            sy,_:=jf32(sub["Y"],1)
            layer.info.flipbook={u32(clamp(sx,1,4096)),u32(clamp(sy,1,4096))}
        }
        switch kind {
        case "sprite":
            layer.info.render=.Billboard
            switch {
            case strings.contains(jstr(settings["Alignment"]),"VelocityAligned"):
                layer.info.render=.Velocity
            case strings.contains(jstr(settings["Alignment"]),"Custom"):
                append(&limits,strings.clone("SpriteAlignment of each particle: its sprites face the camera unturned",allocator))
            }
            if facing:=jstr(settings["FacingMode"]);facing!="" && !strings.has_suffix(facing,"::FaceCamera") {
                append(&limits,fmt.aprintf("sprites that face as %s: they face the camera",facing[strings.last_index(facing,":")+1:],allocator=allocator))
            }
            if pivot,has_pivot:=settings["PivotInUVSpace"].(json.Object);has_pivot {
                px,_:=jf32(pivot["X"],0.5)
                py,_:=jf32(pivot["Y"],0.5)
                // A velocity-aligned sprite is moved by its program (cooked_vfx_program).
                if (abs(px-0.5)>1e-3 || abs(py-0.5)>1e-3) && !strings.contains(jstr(settings["Alignment"]),"VelocityAligned") {
                    append(&limits,fmt.aprintf("sprites held at (%.2f, %.2f) of their image: they are held at its centre",px,py,allocator=allocator))
                }
            }
        case "ribbon":
            layer.info.render=.Ribbon
            if strings.contains(jstr(settings["FacingMode"]),"Custom") {layer.info.ribbon_axis=.Emitter_Up}
            if uv,has_uv:=settings["UV0Settings"].(json.Object);has_uv && strings.contains(jstr(uv["DistributionMode"]),"Tiled") {
                if tile,ok:=jf32(uv["TilingLength"]);ok && tile>0 {layer.info.ribbon_tile=tile*cooked.UNREAL_TO_MIRAI_SCALE}
            }
        case "mesh":
            layer.info.render=.Mesh
            facing:=jstr(settings["FacingMode"])
            switch {
            case strings.contains(facing,"Velocity"):
                layer.info.facing=.Velocity
            case:
                layer.info.facing=.Emitter
            }
            meshes:=make([dynamic]string,allocator)
            m_arr,_:=robj["Meshes"].(json.Array)
            for me in m_arr {
                mobj,mok:=me.(json.Object)
                if !mok {continue}
                path:=jstr(mobj["Mesh"])
                if path=="" || len(meshes)>=effect.PARTICLE_MESHES {continue}
                append(&meshes,strings.clone(path,allocator))
                if len(meshes)>1 {continue}
                // What the renderer gives its first mesh, along Mirai's axes.
                if ms,has_scale:=jvec3(mobj["Scale"]);has_scale&&ms.x>0&&ms.y>0&&ms.z>0 {
                    layer.info.scale=cooked.unreal_scale_to_mirai(ms)
                }
                // PivotOffset is applied by the generated Vfx program (cooked_program.odin).
            }
            layer.mesh_paths=meshes[:]
        case "light":
            layer.info.render=.Billboard
            radius_scale,_:=jf32(settings["RadiusScale"],1)
            diffuse_scale,_:=jf32(settings["DiffuseScale"],1)
            exponent,_:=jf32(settings["DefaultExponent"],1)
            color_add,_:=jvec3(settings["ColorAdd"])
            layer.info.light=niagara_particle_light({
                radius_scale=radius_scale,
                diffuse_scale=diffuse_scale,
                inverse_squared=jbool(settings["bUseInverseSquaredFalloff"],true),
                default_exponent=exponent,
                alpha_scales_brightness=jbool(settings["bAlphaScalesBrightness"],false),
                color_add={max(color_add.x,0),max(color_add.y,0),max(color_add.z,0)},
                has_color_add=color_add!={},
                particle_scattering=-1,
                renderer_scattering=1,
                indirect=1,
                shadows=jbool(settings["bMegaLightsCastShadows"],false),
                fallback_color={1,1,1,1},
                fallback_color_intensity=1,
            })
            append(&limits,strings.clone("the radius and the colour of the light of each particle: one light at the emitter, of the renderer's own values",allocator))
        case:
            append(&warns,fmt.aprintf("renderer %d of kind %q is not drawn",index,jstr(robj["Kind"]),allocator=allocator))
            delete(limits)
            continue
        }
        layer.renderer=strings.clone(kind,allocator)
        for pair in RENDERER_FACTORIES {
            if pair[0]==kind {layer.factory=strings.clone(pair[1],allocator)}
        }
        if mats,has_mats:=robj["Materials"].(json.Array);has_mats {
            for m in mats {
                path:=jstr((m.(json.Object) or_else nil)["Material"])
                if path=="" {continue}
                layer.material_path=strings.clone(path,allocator)
                if cm,found:=mat_by_path[path];found {
                    layer.info.lit=!cm.info.unlit
                    #partial switch cm.info.alpha_mode {
                    case .Additive: layer.info.blend=.Additive
                    case .Blend,.Mask,.Opaque: layer.info.blend=.Alpha
                    }
                }
                break
            }
        }

        // The program that runs its scripts, where everything they read is answered.
        if has_scripts {
            prog_name:=cooked_program_name(system_name,index==0 ? out.name : fmt.tprintf("%s_%d",out.name,index),allocator)
            program:=cooked_vfx_program(prog_name,system,eobj,robj,allocator,fields,skeleton)
            layer.notes=program.notes
            layer.textures=program.textures
            layer.follows,layer.follows_socket=program.follows,program.follows_socket
            layer.resources=program.resources
            for limit in program.limits {append(&limits,limit)}
            delete(program.limits,allocator)
            if len(program.notes)==0 {
                layer.program_name=prog_name
                layer.program_source=program.source
                base.text_set(layer.info.program[:],prog_name)
            } else {
                delete(program.source,allocator)
                delete(prog_name,allocator)
            }
        } else {
            notes:=make([dynamic]string,allocator)
            append(&notes,strings.clone("no particle scripts",allocator))
            layer.notes=notes[:]
        }
        layer.limits=limits[:]
        if prob:=effect.particle_validate({info=layer.info});prob.message!="" {
            append(&warns,fmt.aprintf("renderer %d (%s): %s",index,prob.field,prob.message,allocator=allocator))
        }
        append(&layers,layer)
    }
    out.layers=layers[:]
    out.warnings=warns[:]
    return
}

// Builds a collision-free Slang identifier <= PARTICLE_NAME_BYTES-1 (63 bytes)
// for a cooked Niagara Vfx program so info.program always matches its namespace.
@(private="file")
cooked_program_name :: proc(sys_name,em_name:string,allocator:mem.Allocator) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"Cooked_")
    write_ident(&b,sys_name)
    strings.write_byte(&b,'_')
    write_ident(&b,em_name)
    text:=strings.to_string(b)
    max_len:=effect.PARTICLE_NAME_BYTES-1
    if len(text)>max_len {
        full:=strings.concatenate({sys_name,":",em_name},context.temp_allocator)
        h:=base.hash64(transmute([]u8)full)
        keep:=max(max_len-17,1)
        return fmt.aprintf("%s_%016x",text[:keep],h,allocator=allocator)
    }
    return strings.clone(text,allocator)
}

@(private="file")
write_ident :: proc(b:^strings.Builder,s:string) {
    for c in transmute([]u8)s {
        ok:=(c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')
        strings.write_byte(b,ok ? c : '_')
    }
}

@(private)
jstr :: proc(v:json.Value,fallback:="") -> string {
    if s,ok:=v.(json.String);ok {return s}
    return fallback
}

@(private)
jbool :: proc(v:json.Value,fallback:=false) -> bool {
    if b,ok:=v.(json.Boolean);ok {return b}
    return fallback
}

@(private)
jf32 :: proc(v:json.Value,fallback:f32=0) -> (f32,bool) {
    #partial switch x in v {
    case json.Float:
        if math.is_nan(x) || math.is_inf(x) {return fallback,false}
        return f32(x),true
    case json.Integer:
        return f32(x),true
    }
    return fallback,false
}

@(private="file")
jvec3 :: proc(v:json.Value) -> ([3]f32,bool) {
    if arr,ok:=v.(json.Array);ok && len(arr)>=3 {
        x,_:=jf32(arr[0],0);y,_:=jf32(arr[1],0);z,_:=jf32(arr[2],0)
        return {x,y,z},true
    }
    if obj,ok:=v.(json.Object);ok {
        out:[3]f32
        found:=false
        if a,has:=obj["X"];has {out.x,_=jf32(a,0);found=true}
        if a,has:=obj["R"];has {out.x,_=jf32(a,0);found=true}
        if a,has:=obj["Y"];has {out.y,_=jf32(a,0);found=true}
        if a,has:=obj["G"];has {out.y,_=jf32(a,0);found=true}
        if a,has:=obj["Z"];has {out.z,_=jf32(a,0);found=true}
        if a,has:=obj["B"];has {out.z,_=jf32(a,0);found=true}
        return out,found
    }
    return {},false
}
