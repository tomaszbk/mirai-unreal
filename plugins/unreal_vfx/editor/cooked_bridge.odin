package unreal_vfx_editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"
import cooked "project:plugins/unreal/editor/cooked"

// Cooked -> Native Mirai VFX Bridge: consumes `ue5parse niagara` JSON
// (`Schema: "ue5parse.niagara/2"`, including VectorVM2-decompiled scripts)
// and builds native Mirai `.particle` assets (`effect.Particle_Info` +
// validated bytes), generated Mirai Vfx Slang shaders (`//! mirai vfx ...`),
// and native `.mat` v6 materials (`cooked.Cooked_Material`).

Cooked_Vfx_Emitter :: struct {
    name:string,
    enabled:bool,
    gpu:bool,
    info:effect.Particle_Info,
    particle_bytes:[]u8,
    program_name:string,
    program_source:string, // generated Mirai Vfx Slang shader
    material_path:string,
    mesh_paths:[]string,
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
        delete(em.particle_bytes,allocator)
        delete(em.program_name,allocator)
        delete(em.program_source,allocator)
        delete(em.material_path,allocator)
        for mp in em.mesh_paths {delete(mp,allocator)}
        delete(em.mesh_paths,allocator)
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
    color_add:[3]f32,          // UNiagaraLightRendererProperties::ColorAdd
    has_color_add:bool,
    explicit_range_m:f32,      // explicit light range in metres (>0 overrides radius_cm)
    explicit_intensity:f32,    // explicit intensity in cd (>0 overrides fallback)
    explicit_source_radius_m:f32,
    particle_radius_cm:f32,    // Particles.LightRadius (cm) when known
    particle_intensity:f32,    // Particles.LightIntensity / LightBrightness when known
    particle_color:[3]f32,     // Particles.LightColor when known
    has_particle_color:bool,
    particle_scattering:f32,   // >=0 when explicitly specified
    renderer_scattering:f32,   // default 1.0
    indirect:f32,              // default 1.0
    shadows:bool,
    max_lights:u16,            // default 1
    fallback_sprite_size_m:f32,
    fallback_color:[4]f32,
}

// Builds a native Mirai effect.Particle_Light from extracted Niagara light renderer
// properties, using sensible defaults only when a property is absent.
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
    lintensity:=p.explicit_intensity
    if lintensity<=0 {lintensity=p.particle_intensity}
    if lintensity<=0 {
        // When no explicit intensity is authored, derive candela from ColorAdd / HDR particle color.
        cmax:=max(p.fallback_color.x,max(p.fallback_color.y,p.fallback_color.z))
        add_max:=max(p.color_add.x,max(p.color_add.y,p.color_add.z))
        drive:=max(max(cmax,add_max),1.0)
        lintensity=100.0*max(diffuse_scale,0.1)*drive
    }
    lcolor:[3]f32
    if p.has_particle_color {
        lcolor={max(p.particle_color.x,0),max(p.particle_color.y,0),max(p.particle_color.z,0)}
    } else if p.has_color_add {
        lcolor={max(p.color_add.x,0),max(p.color_add.y,0),max(p.color_add.z,0)}
    } else if p.fallback_color.x>0 || p.fallback_color.y>0 || p.fallback_color.z>0 {
        cmax:=max(p.fallback_color.x,max(p.fallback_color.y,p.fallback_color.z))
        if cmax>1e-4 {lcolor={p.fallback_color.x/cmax,p.fallback_color.y/cmax,p.fallback_color.z/cmax}}
    }
    if lcolor=={} {lcolor={1,1,1}}
    lradius:=p.explicit_source_radius_m>0 ? p.explicit_source_radius_m : min(max(p.fallback_sprite_size_m*0.5,0),max(lrange,0))
    lscatter:=p.particle_scattering>=0 ? p.particle_scattering : max(p.renderer_scattering,0)
    return {
        color=lcolor,
        intensity=max(lintensity,0),
        range=max(lrange,0),
        radius=clamp(lradius,0,max(lrange,0)),
        max_lights=max(p.max_lights,1),
        shadows=p.shadows,
        indirect=max(p.indirect,0),
        scattering=max(lscatter,0),
    }
}

// Parses a `ue5parse.niagara/2` JSON document into native Mirai `.particle`
// emitters + Vfx Slang shaders + native `.mat` v6 materials.
cooked_niagara_build :: proc(json_text:string,allocator:=context.allocator) -> (sys:Cooked_Vfx_System,err:Maybe(cooked.Error)) {
    if len(json_text)==0 {return {},cooked.Error{"niagara","empty JSON"}}
    root,jerr:=json.parse_string(json_text,allocator=context.temp_allocator)
    if jerr!=.None {return {},cooked.Error{"niagara","malformed JSON"}}
    obj,ok:=root.(json.Object)
    if !ok {return {},cooked.Error{"niagara","root JSON value must be an object"}}
    if schema:=jstr(obj["Schema"]);schema!="" && !strings.has_prefix(schema,"ue5parse.niagara/") {
        return {},cooked.Error{"niagara",fmt.aprintf("unexpected schema %q",schema,allocator=allocator)}
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

    // Collect system user parameters as default scalar/vector lookup.
    user_params:=make(map[string]f32,allocator=context.temp_allocator)
    if up,has_u:=obj["UserParameters"].(json.Array);has_u {
        for item in up {
            if uobj,uok:=item.(json.Object);uok {
                if v,vok:=jf32(uobj["Value"]);vok {user_params[jstr(uobj["Name"])]=v}
            }
        }
    }

    em_list:=make([dynamic]Cooked_Vfx_Emitter,allocator)
    if emitters,has_e:=obj["Emitters"].(json.Array);has_e {
        for item in emitters {
            eobj,eok:=item.(json.Object)
            if !eok {continue}
            append(&em_list,build_cooked_emitter(sys.name,eobj,mat_by_path,user_params,allocator))
        }
    }
    sys.emitters=em_list[:]
    return sys,nil
}

@(private="file")
build_cooked_emitter :: proc(
    system_name:string,
    eobj:json.Object,
    mat_by_path:map[string]^cooked.Cooked_Material,
    user_params:map[string]f32,
    allocator:mem.Allocator,
) -> (out:Cooked_Vfx_Emitter) {
    out.name=strings.clone(jstr(eobj["Name"],"Emitter"),allocator)
    out.enabled=jbool(eobj["Enabled"],true)
    out.gpu=strings.equal_fold(jstr(eobj["Target"]),"GPU")
    out.info=effect.PARTICLE_DEFAULTS
    out.info.rate=0 // Only set rate/bursts from actual emitter scripts or fallback below.
    out.info.size_over_life=effect.PARTICLE_CURVE_ONE

    warns:=make([dynamic]string,allocator)
    if note:=jstr(eobj["Note"]);note!="" {append(&warns,strings.clone(note,allocator))}

    // Settings (bLocalSpace, etc.).
    if settings,has_s:=eobj["Settings"].(json.Object);has_s {
        out.info.local_space=jbool(settings["bLocalSpace"],false)
        if alloc_count,ok:=jf32(settings["AllocationCount"]);ok && alloc_count>0 {
            out.info.max_particles=u32(clamp(alloc_count,1,65536))
        }
    }

    // EmitterScripts (SpawnRate, SpawnBurst, LoopDuration, DepthFade).
    burst_idx:=0
    if escripts,has_es:=eobj["EmitterScripts"].(json.Array);has_es {
        for s in escripts {
            sobj,sok:=s.(json.Object)
            if !sok {continue}
            if outs,has_o:=sobj["Outputs"].(json.Array);has_o {
                for o in outs {
                    oobj,ook:=o.(json.Object)
                    if !ook {continue}
                    attr:=jstr(oobj["Attribute"])
                    val,has_val:=eval_literal(oobj["Value"])
                    if !has_val {continue}
                    low:=strings.to_lower(attr,context.temp_allocator)
                    switch {
                    case strings.contains(low,"spawnrate") && !strings.contains(low,"scale"):
                        if val>0 {out.info.rate=max(out.info.rate,val)}
                    case strings.contains(low,"spawnburst") && strings.has_suffix(low,".count"):
                        if val>0 && burst_idx<effect.PARTICLE_BURSTS {
                            out.info.bursts[burst_idx]={time=0,count=u32(clamp(val+0.5,0,1e6)),cycles=1,interval=0}
                            burst_idx+=1
                        }
                    case strings.contains(low,"loopduration"):
                        if val>0 {out.info.duration=val}
                    case strings.contains(low,"depthfade"):
                        if val>0 {out.info.soft=val*cooked.UNREAL_TO_MIRAI_SCALE}
                    }
                }
            }
        }
    }

    // Extract DataInterfaces curves (ShaderLUT) -> size_over_life / color_over_life.
    Curve_LUT :: struct {name:string,samples:[]f32,channels:int}
    curves:=make([dynamic]Curve_LUT,context.temp_allocator)
    if dis,has_di:=eobj["DataInterfaces"].(json.Array);has_di {
        for di in dis {
            dobj,dok:=di.(json.Object)
            if !dok {continue}
            class:=jstr(dobj["Class"])
            cname:=jstr(dobj["Name"])
            if lut,has_l:=dobj["ShaderLUT"].(json.Array);has_l && len(lut)>0 {
                samples:=make([]f32,len(lut),context.temp_allocator)
                for x,i in lut {samples[i],_=jf32(x,0)}
                ch:=strings.contains(class,"ColorCurve") ? 4 : strings.contains(class,"VectorCurve") ? 3 : strings.contains(class,"Vector2DCurve") ? 2 : 1
                append(&curves,Curve_LUT{cname,samples,ch})
                low:=strings.to_lower(cname,context.temp_allocator)
                if ch==1 && (strings.contains(low,"size") || strings.contains(low,"scale")) {
                    out.info.size_over_life=sample_curve_1d(samples)
                } else if ch==4 && strings.contains(low,"color") {
                    out.info.color_over_life=sample_gradient_4d(samples)
                }
            }
        }
    }

    // Renderers -> Particle_Render, Particle_Blend, Particle_Light (v10), flipbook, material, meshes.
    meshes:=make([dynamic]string,allocator)
    has_light_renderer:=false
    light_radius_scale:f32=1
    light_diffuse_scale:f32=1
    light_color_add:[3]f32
    light_shadows:=false
    light_max:u16=1
    light_indirect:f32=1
    light_scattering:f32=1
    light_explicit_intensity:f32=0
    light_explicit_range:f32=0
    light_explicit_radius:f32=0
    if rends,has_r:=eobj["Renderers"].(json.Array);has_r {
        for r in rends {
            robj,rok:=r.(json.Object)
            if !rok {continue}
            kind:=jstr(robj["Kind"],jstr(robj["Class"]))
            low_kind:=strings.to_lower(kind,context.temp_allocator)
            if strings.contains(low_kind,"light") {
                has_light_renderer=true
                if rs,ok:=jf32(robj["RadiusScale"]);ok && rs>0 {light_radius_scale=rs}
                if ds,ok:=jf32(robj["DiffuseScale"]);ok && ds>0 {light_diffuse_scale=ds}
                if ca,ok:=jvec3(robj["ColorAdd"]);ok {light_color_add={max(ca.x,0),max(ca.y,0),max(ca.z,0)}}
                if c_val,ok:=jvec3(robj["Color"]);ok && (c_val.x>0||c_val.y>0||c_val.z>0) {
                    light_color_add={max(c_val.x,0),max(c_val.y,0),max(c_val.z,0)}
                }
                light_shadows=jbool(robj["bMegaLightsCastShadows"],false) || jbool(robj["bCastShadows"],false)
                if ml,ok:=jf32(robj["MaxLights"]);ok && ml>=1 {light_max=u16(clamp(ml,1,65535))}
                if ind,ok:=jf32(robj["IndirectLightingIntensity"]);ok && ind>=0 {light_indirect=ind}
                if sc,ok:=jf32(robj["VolumetricScatteringIntensity"]);ok && sc>=0 {light_scattering=sc}
                if li,ok:=jf32(robj["Intensity"]);ok && li>0 {light_explicit_intensity=li}
                if lr,ok:=jf32(robj["Radius"]);ok && lr>0 {light_explicit_range=lr*cooked.UNREAL_TO_MIRAI_SCALE}
                if lsr,ok:=jf32(robj["SourceRadius"]);ok && lsr>0 {light_explicit_radius=lsr*cooked.UNREAL_TO_MIRAI_SCALE}
                continue
            }
            if mat:=jstr(robj["Material"]);mat!="" && out.material_path=="" {
                out.material_path=strings.clone(mat,allocator)
                if cm,found:=mat_by_path[mat];found {
                    out.info.lit=!cm.info.unlit
                    #partial switch cm.info.alpha_mode {
                    case .Additive: out.info.blend=.Additive
                    case .Blend,.Mask,.Opaque: out.info.blend=.Alpha
                    }
                }
            }
            if sub,has_sub:=robj["SubImageSize"].(json.Object);has_sub {
                sx,_:=jf32(sub["X"],1)
                sy,_:=jf32(sub["Y"],1)
                out.info.flipbook={u32(max(sx,1)),u32(max(sy,1))}
            }
            switch {
            case strings.contains(low_kind,"sprite"):
                align:=jstr(robj["Alignment"])
                if strings.contains(align,"Velocity") {
                    out.info.render=.Velocity
                } else if strings.contains(align,"Custom") {
                    out.info.render=.Horizontal
                } else {
                    out.info.render=.Billboard
                }
            case strings.contains(low_kind,"ribbon"):
                out.info.render=.Ribbon
                if strings.contains(jstr(robj["FacingMode"]),"Custom") {
                    out.info.ribbon_axis=.Emitter_Up
                }
            case strings.contains(low_kind,"mesh"):
                out.info.render=.Mesh
                facing:=jstr(robj["FacingMode"])
                if strings.contains(facing,"Velocity") {out.info.facing=.Velocity} else {out.info.facing=.Emitter}
                if m_arr,has_ms:=robj["Meshes"].(json.Array);has_ms {
                    for me in m_arr {
                        if s,sok:=me.(json.String);sok && s!="" {append(&meshes,strings.clone(s,allocator))}
                        if mobj,mok:=me.(json.Object);mok {
                            if mp:=jstr(mobj["Mesh"]);mp!="" {append(&meshes,strings.clone(mp,allocator))}
                        }
                    }
                }
            case strings.contains(low_kind,"beam"):
                out.info.render=.Beam
            }
        }
    }
    out.mesh_paths=meshes[:]

    // Parse particle scripts (Spawn & Update) -> extract lifetime/size/color/light + generate Vfx Slang shader.
    spawn_script,update_script:json.Object
    has_spawn,has_update:=false,false
    if scripts,has_sc:=eobj["Scripts"].(json.Array);has_sc {
        for s in scripts {
            sobj,sok:=s.(json.Object)
            if !sok {continue}
            usage:=jstr(sobj["Usage"])
            if strings.contains(usage,"Spawn") {
                spawn_script,has_spawn=sobj,true
            } else if strings.contains(usage,"Update") {
                update_script,has_update=sobj,true
            }
        }
    }

    // Extract scalar defaults from Spawn outputs into Particle_Info (lifetime, size, color, light).
    spawn_light_radius_cm:f32=0
    spawn_light_intensity:f32=0
    spawn_light_scatter:f32=-1
    spawn_light_color:[3]f32
    has_spawn_light_color:=false
    if has_spawn {
        if outs,has_o:=spawn_script["Outputs"].(json.Array);has_o {
            for o in outs {
                oobj,ook:=o.(json.Object)
                if !ook {continue}
                attr:=jstr(oobj["Attribute"])
                val,has_v:=eval_literal(oobj["Value"])
                if !has_v {continue}
                switch attr {
                case "Lifetime":
                    if val>0 {out.info.lifetime={val,val}}
                case "SpriteSize.x","SpriteSize":
                    if val>0 {
                        m:=val*cooked.UNREAL_TO_MIRAI_SCALE
                        out.info.size={m,m}
                    }
                case "Color.x": out.info.colors[0].x=clamp(val,0,10);out.info.colors[1].x=out.info.colors[0].x
                case "Color.y": out.info.colors[0].y=clamp(val,0,10);out.info.colors[1].y=out.info.colors[0].y
                case "Color.z": out.info.colors[0].z=clamp(val,0,10);out.info.colors[1].z=out.info.colors[0].z
                case "Color.w": out.info.colors[0].w=clamp(val,0,1);out.info.colors[1].w=out.info.colors[0].w
                case "LightRadius":
                    if val>0 {spawn_light_radius_cm=val}
                case "LightIntensity","LightBrightness":
                    if val>0 {spawn_light_intensity=val}
                case "LightVolumetricScattering":
                    if val>=0 {spawn_light_scatter=val}
                case "LightColor.x": spawn_light_color.x=max(val,0);has_spawn_light_color=true
                case "LightColor.y": spawn_light_color.y=max(val,0);has_spawn_light_color=true
                case "LightColor.z": spawn_light_color.z=max(val,0);has_spawn_light_color=true
                }
            }
        }
    }

    // Populate Mirai .particle v10 Particle_Light via shared Niagara light helper.
    if has_light_renderer || spawn_light_radius_cm>0 || spawn_light_intensity>0 {
        out.info.light=niagara_particle_light({
            radius_scale=light_radius_scale,
            diffuse_scale=light_diffuse_scale,
            color_add=light_color_add,
            has_color_add=light_color_add!={},
            explicit_range_m=light_explicit_range,
            explicit_intensity=light_explicit_intensity,
            explicit_source_radius_m=light_explicit_radius,
            particle_radius_cm=spawn_light_radius_cm,
            particle_intensity=spawn_light_intensity,
            particle_color=spawn_light_color,
            has_particle_color=has_spawn_light_color,
            particle_scattering=spawn_light_scatter,
            renderer_scattering=light_scattering,
            indirect=light_indirect,
            shadows=light_shadows,
            max_lights=light_max,
            fallback_sprite_size_m=out.info.size[0],
            fallback_color=out.info.colors[0],
        })
    }

    // Ensure non-zero spawn activity if emitter had neither rate nor bursts in EmitterScripts.
    if out.info.rate==0 && burst_idx==0 {
        out.info.bursts[0]={time=0,count=1,cycles=1,interval=0}
    }

    // Generate native Mirai Vfx Slang program from decompiled expression trees when CPU scripts exist.
    if has_spawn || has_update {
        prog_name:=cooked_program_name(system_name,out.name,allocator)
        prog_src:=emit_cooked_vfx_slang(prog_name,eobj,spawn_script,has_spawn,update_script,has_update,user_params,allocator)
        out.program_name=prog_name
        out.program_source=prog_src
        base.text_set(out.info.program[:],prog_name)
    }

    if prob:=effect.particle_validate({info=out.info});prob.message!="" {
        append(&warns,fmt.aprintf("particle validation (%s): %s",prob.field,prob.message,allocator=allocator))
    }
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    if pbytes,perr:=effect.particle_bytes(&types,{info=out.info},allocator);perr==.None {
        out.particle_bytes=pbytes
    } else {
        append(&warns,fmt.aprintf("particle_bytes failed: %v",perr,allocator=allocator))
    }
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

@(private="file")
attr_field :: proc(name:string) -> string {
    // Strip Particles. prefix and sanitize dots/spaces into a flat float field name.
    clean:=strings.trim_prefix(name,"Particles.")
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"f_")
    write_ident(&b,clean)
    return strings.to_string(b)
}

// Emits a valid Mirai Vfx Slang shader (`//! mirai vfx <name>`) from cooked
// `ue5parse.niagara/2` decompiled expression trees.
@(private="file")
emit_cooked_vfx_slang :: proc(
    prog_name:string,
    eobj:json.Object,
    spawn_script:json.Object,has_spawn:bool,
    update_script:json.Object,has_update:bool,
    user_params:map[string]f32,
    allocator:mem.Allocator,
) -> string {
    // Collect all scalar particle attribute components written or declared.
    fields:=make([dynamic]string,context.temp_allocator)
    field_set:=make(map[string]bool,allocator=context.temp_allocator)
    add_field :: proc(fields:^[dynamic]string,set:^map[string]bool,name:string) {
        if name=="" {return}
        f:=attr_field(name)
        if f in set {return}
        set[f]=true
        append(fields,f)
    }

    collect_script_attrs :: proc(fields:^[dynamic]string,set:^map[string]bool,sc:json.Object) {
        if outs,has:=sc["Outputs"].(json.Array);has {
            for o in outs {
                if oobj,ok:=o.(json.Object);ok {
                    add_field(fields,set,jstr(oobj["Attribute"]))
                }
            }
        }
    }
    if has_spawn {collect_script_attrs(&fields,&field_set,spawn_script)}
    if has_update {collect_script_attrs(&fields,&field_set,update_script)}
    // Also ensure core attributes exist if referenced in expressions.
    for core_attr in ([]string{"Age","Lifetime","Position.x","Position.y","Position.z","Velocity.x","Velocity.y","Velocity.z","Color.x","Color.y","Color.z","Color.w","SpriteSize.x","SpriteSize.y","SpriteRotation","SubImageIndex","MaterialRandom"}) {
        add_field(&fields,&field_set,core_attr)
    }
    slice.sort(fields[:])

    s:=strings.builder_make(allocator)
    fmt.sbprintf(&s,"//! mirai vfx %s\n//! moves\n//! parameter scale {{\"default\":1,\"min\":0,\"max\":100}}\n",prog_name)
    fmt.sbprintf(&s,"namespace %s {{\n",prog_name)
    strings.write_string(&s,"struct Parameters { float scale; };\n")
    strings.write_string(&s,"struct Attributes {\n")
    for f in fields {fmt.sbprintf(&s,"    float %s;\n",f)}
    strings.write_string(&s,"};\n")
    strings.write_string(&s,"float3 ue_to_mirai_pos(float3 p) { return float3(p.y, p.z, -p.x) * 0.01; }\n")
    strings.write_string(&s,"float3 mirai_to_ue_pos(float3 p) { return float3(-p.z, p.x, p.y) * 100.0; }\n")
    strings.write_string(&s,"float vfx_div(float a, float b) { return abs(b) > 1e-8 ? a / b : 0.0; }\n")

    // initialize()
    strings.write_string(&s,"void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {\n")
    strings.write_string(&s,"    uint seed = particle.seed;\n")
    strings.write_string(&s,"    float3 p_ue = mirai_to_ue_pos(particle.position);\n")
    strings.write_string(&s,"    float3 v_ue = mirai_to_ue_pos(particle.velocity);\n")
    strings.write_string(&s,"    a.f_Position_x = p_ue.x; a.f_Position_y = p_ue.y; a.f_Position_z = p_ue.z;\n")
    strings.write_string(&s,"    a.f_Velocity_x = v_ue.x; a.f_Velocity_y = v_ue.y; a.f_Velocity_z = v_ue.z;\n")
    strings.write_string(&s,"    a.f_Age = 0.0; a.f_Lifetime = max(particle.lifetime, 1e-4);\n")
    strings.write_string(&s,"    a.f_Color_x = 1.0; a.f_Color_y = 1.0; a.f_Color_z = 1.0; a.f_Color_w = 1.0;\n")
    strings.write_string(&s,"    a.f_SpriteSize_x = 20.0; a.f_SpriteSize_y = 20.0;\n")
    if has_spawn {
        emit_script_outputs(&s,spawn_script,field_set,user_params)
    }
    strings.write_string(&s,"    particle.position = ue_to_mirai_pos(float3(a.f_Position_x, a.f_Position_y, a.f_Position_z));\n")
    strings.write_string(&s,"    particle.velocity = ue_to_mirai_pos(float3(a.f_Velocity_x, a.f_Velocity_y, a.f_Velocity_z));\n")
    strings.write_string(&s,"    particle.lifetime = max(a.f_Lifetime, 1e-4);\n")
    strings.write_string(&s,"    particle.age = max(a.f_Age, 0.0);\n")
    strings.write_string(&s,"}\n")

    // update()
    strings.write_string(&s,"void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {\n")
    strings.write_string(&s,"    uint seed = particle.seed ^ uint(ctx.time * 1000.0);\n")
    if has_update {
        emit_script_outputs(&s,update_script,field_set,user_params)
    } else {
        strings.write_string(&s,"    a.f_Age += ctx.delta_time;\n")
    }
    strings.write_string(&s,"    particle.position = ue_to_mirai_pos(float3(a.f_Position_x, a.f_Position_y, a.f_Position_z));\n")
    strings.write_string(&s,"    particle.velocity = ue_to_mirai_pos(float3(a.f_Velocity_x, a.f_Velocity_y, a.f_Velocity_z));\n")
    strings.write_string(&s,"    particle.rotation = a.f_SpriteRotation * 0.0174532925;\n")
    strings.write_string(&s,"    particle.lifetime = max(a.f_Lifetime, 1e-4);\n")
    strings.write_string(&s,"    particle.age = max(a.f_Age, 0.0);\n")
    // Evaluate KeepConditions AFTER updating age/lifetime so kill conditions are never overwritten.
    if has_update {
        if keeps,has_k:=update_script["KeepConditions"].(json.Array);has_k {
            for kc in keeps {
                expr:=emit_expr(kc,field_set,user_params,0)
                fmt.sbprintf(&s,"    if (!(%s != 0.0)) particle.age = particle.lifetime;\n",expr)
            }
        }
    }
    strings.write_string(&s,"}\n")

    // render()
    strings.write_string(&s,"void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {\n")
    strings.write_string(&s,"    visual.color = float4(max(a.f_Color_x, 0.0), max(a.f_Color_y, 0.0), max(a.f_Color_z, 0.0), saturate(a.f_Color_w));\n")
    strings.write_string(&s,"    float sz = max(a.f_SpriteSize_x, a.f_SpriteSize_y) * 0.01 * max(p.scale, 0.0);\n")
    strings.write_string(&s,"    if (sz > 0.0) visual.size = sz;\n")
    strings.write_string(&s,"    visual.frame = a.f_SubImageIndex;\n")
    strings.write_string(&s,"    visual.random = a.f_MaterialRandom;\n")
    // Emit DynamicMaterialParameter0..3 -> visual.data[0..3] when present.
    for slot in 0..<4 {
        prefix:=slot==0 ? "DynamicMaterialParameter" : fmt.tprintf("DynamicMaterialParameter%d",slot)
        fx:=attr_field(fmt.tprintf("%s.x",prefix))
        if fx in field_set {
            fy:=attr_field(fmt.tprintf("%s.y",prefix))
            fz:=attr_field(fmt.tprintf("%s.z",prefix))
            fw:=attr_field(fmt.tprintf("%s.w",prefix))
            ex:=fx in field_set ? fmt.tprintf("a.%s",fx) : "0.0"
            ey:=fy in field_set ? fmt.tprintf("a.%s",fy) : "0.0"
            ez:=fz in field_set ? fmt.tprintf("a.%s",fz) : "0.0"
            ew:=fw in field_set ? fmt.tprintf("a.%s",fw) : "0.0"
            fmt.sbprintf(&s,"    visual.data[%d] = float4(%s, %s, %s, %s); visual.given |= %du;\n",slot,ex,ey,ez,ew,1<<uint(slot))
        }
    }
    strings.write_string(&s,"}\n}\n")
    return strings.to_string(s)
}

@(private="file")
emit_script_outputs :: proc(s:^strings.Builder,sc:json.Object,field_set:map[string]bool,user_params:map[string]f32) {
    outs,has:=sc["Outputs"].(json.Array)
    if !has {return}
    // Snapshot into locals so outputs reading each other see prior-frame attribute values cleanly.
    for o,i in outs {
        oobj,ok:=o.(json.Object)
        if !ok {continue}
        attr:=jstr(oobj["Attribute"])
        if attr=="" {continue}
        f:=attr_field(attr)
        if !(f in field_set) {continue}
        expr:=emit_expr(oobj["Value"],field_set,user_params,0)
        fmt.sbprintf(s,"    float out_%d = %s;\n",i,expr)
    }
    for o,i in outs {
        oobj,ok:=o.(json.Object)
        if !ok {continue}
        attr:=jstr(oobj["Attribute"])
        if attr=="" {continue}
        f:=attr_field(attr)
        if !(f in field_set) {continue}
        fmt.sbprintf(s,"    a.%s = out_%d;\n",f,i)
    }
}

@(private="file")
emit_expr :: proc(v:json.Value,field_set:map[string]bool,user_params:map[string]f32,depth:int) -> string {
    if depth>32 {return "0.0"}
    obj,ok:=v.(json.Object)
    if !ok {
        if f,fok:=jf32(v);fok {return fmt_slang_f32(f)}
        return "0.0"
    }
    // Literal
    if lit,has:=obj["Literal"];has {
        if f,fok:=jf32(lit);fok {return fmt_slang_f32(f)}
        return "0.0"
    }
    // ExecIndex
    if _,has:=obj["ExecIndex"];has {
        return "float(particle.seed & 0xFFFFu)"
    }
    // Attribute
    if attr_v,has:=obj["Attribute"];has {
        attr:=jstr(attr_v)
        f:=attr_field(attr)
        if f in field_set {return fmt.tprintf("a.%s",f)}
        return "0.0"
    }
    // Parameter
    if param_v,has:=obj["Parameter"];has {
        pname:=jstr(param_v)
        switch pname {
        case "Engine.DeltaTime","Engine.WorldDeltaTime": return "ctx.delta_time"
        case "Engine.InverseDeltaTime": return "vfx_div(1.0, ctx.delta_time)"
        case "Engine.Time","Engine.RealTime","Engine.System.Age","Emitter.Age": return "ctx.time"
        case "Engine.Owner.Position.x": return "(-ctx.origin.z * 100.0)"
        case "Engine.Owner.Position.y": return "(ctx.origin.x * 100.0)"
        case "Engine.Owner.Position.z": return "(ctx.origin.y * 100.0)"
        }
        if val,has_v:=obj["Value"];has_v {
            if f,fok:=jf32(val);fok {return fmt_slang_f32(f)}
        }
        if u,found:=user_params[pname];found {return fmt_slang_f32(u)}
        return "0.0"
    }
    // Op
    if op_v,has:=obj["Op"];has {
        op:=jstr(op_v)
        args_arr,has_a:=obj["Args"].(json.Array)
        args:=make([]string,has_a ? len(args_arr) : 0,context.temp_allocator)
        for a,i in args_arr {args[i]=emit_expr(a,field_set,user_params,depth+1)}
        a0:=len(args)>0 ? args[0] : "0.0"
        a1:=len(args)>1 ? args[1] : "0.0"
        a2:=len(args)>2 ? args[2] : "0.0"
        switch op {
        case "add","addi": return fmt.tprintf("(%s + %s)",a0,a1)
        case "sub","subi": return fmt.tprintf("(%s - %s)",a0,a1)
        case "mul","muli": return fmt.tprintf("(%s * %s)",a0,a1)
        case "div","divi": return fmt.tprintf("vfx_div(%s, %s)",a0,a1)
        case "mad": return fmt.tprintf("(%s * %s + %s)",a0,a1,a2)
        case "lerp": return fmt.tprintf("lerp(%s, %s, %s)",a0,a1,a2)
        case "clamp","clampi": return fmt.tprintf("clamp(%s, %s, %s)",a0,a1,a2)
        case "min","mini": return fmt.tprintf("min(%s, %s)",a0,a1)
        case "max","maxi": return fmt.tprintf("max(%s, %s)",a0,a1)
        case "pow": return fmt.tprintf("(%s > 1e-8 ? pow(%s, %s) : 0.0)",a0,a0,a1)
        case "sqrt": return fmt.tprintf("sqrt(max(%s, 0.0))",a0)
        case "rsq": return fmt.tprintf("(%s > 1e-8 ? rsqrt(%s) : 0.0)",a0,a0)
        case "rcp": return fmt.tprintf("vfx_div(1.0, %s)",a0)
        case "neg","negi": return fmt.tprintf("(-%s)",a0)
        case "abs","absi": return fmt.tprintf("abs(%s)",a0)
        case "sin": return fmt.tprintf("sin(%s)",a0)
        case "cos": return fmt.tprintf("cos(%s)",a0)
        case "tan": return fmt.tprintf("tan(%s)",a0)
        case "asin": return fmt.tprintf("asin(clamp(%s, -1.0, 1.0))",a0)
        case "acos": return fmt.tprintf("acos(clamp(%s, -1.0, 1.0))",a0)
        case "atan": return fmt.tprintf("atan(%s)",a0)
        case "atan2": return fmt.tprintf("atan2(%s, %s)",a0,a1)
        case "exp": return fmt.tprintf("exp(%s)",a0)
        case "exp2": return fmt.tprintf("exp2(%s)",a0)
        case "log": return fmt.tprintf("(%s > 0.0 ? log(%s) : 0.0)",a0,a0)
        case "log2": return fmt.tprintf("(%s > 0.0 ? log2(%s) : 0.0)",a0,a0)
        case "floor": return fmt.tprintf("floor(%s)",a0)
        case "ceil": return fmt.tprintf("ceil(%s)",a0)
        case "round": return fmt.tprintf("round(%s)",a0)
        case "trunc": return fmt.tprintf("trunc(%s)",a0)
        case "frac": return fmt.tprintf("(%s - trunc(%s))",a0,a0)
        case "fmod": return fmt.tprintf("fmod(%s, %s)",a0,a1)
        case "sign","signi": return fmt.tprintf("(%s >= 0.0 ? 1.0 : -1.0)",a0)
        case "step": return fmt.tprintf("(%s >= %s ? 1.0 : 0.0)",a1,a0)
        case "random","randomi": return fmt.tprintf("(mirai_vfx_random(seed) * %s)",a0)
        case "cmplt","cmplti": return fmt.tprintf("(%s < %s ? 1.0 : 0.0)",a0,a1)
        case "cmple","cmplei": return fmt.tprintf("(%s <= %s ? 1.0 : 0.0)",a0,a1)
        case "cmpgt","cmpgti": return fmt.tprintf("(%s > %s ? 1.0 : 0.0)",a0,a1)
        case "cmpge","cmpgei": return fmt.tprintf("(%s >= %s ? 1.0 : 0.0)",a0,a1)
        case "cmpeq","cmpeqi": return fmt.tprintf("(%s == %s ? 1.0 : 0.0)",a0,a1)
        case "cmpneq","cmpneqi": return fmt.tprintf("(%s != %s ? 1.0 : 0.0)",a0,a1)
        case "select": return fmt.tprintf("(%s != 0.0 ? %s : %s)",a0,a1,a2)
        case "logic_and": return fmt.tprintf("((%s != 0.0 && %s != 0.0) ? 1.0 : 0.0)",a0,a1)
        case "logic_or": return fmt.tprintf("((%s != 0.0 || %s != 0.0) ? 1.0 : 0.0)",a0,a1)
        case "logic_xor": return fmt.tprintf("(((%s != 0.0) != (%s != 0.0)) ? 1.0 : 0.0)",a0,a1)
        case "logic_not": return fmt.tprintf("(%s == 0.0 ? 1.0 : 0.0)",a0)
        case "bit_and": return fmt.tprintf("float(int(%s) & int(%s))",a0,a1)
        case "bit_or": return fmt.tprintf("float(int(%s) | int(%s))",a0,a1)
        case "bit_xor": return fmt.tprintf("float(int(%s) ^ int(%s))",a0,a1)
        case "bit_not": return fmt.tprintf("float(~int(%s))",a0)
        case "bit_lshift": return fmt.tprintf("float(int(%s) << clamp(int(%s), 0, 31))",a0,a1)
        case "bit_rshift": return fmt.tprintf("float(int(%s) >> clamp(int(%s), 0, 31))",a0,a1)
        case "f2i","i2f": return fmt.tprintf("float(int(%s))",a0)
        case "f2b","i2b": return fmt.tprintf("(%s > 0.0 ? 1.0 : 0.0)",a0)
        case "b2f","b2i": return fmt.tprintf("(%s != 0.0 ? 1.0 : 0.0)",a0)
        case "fasi": return fmt.tprintf("float(asint(%s))",a0)
        case "iasf": return fmt.tprintf("asfloat(int(%s))",a0)
        case "half_to_float": return a0
        }
    }
    return "0.0"
}

@(private="file")
eval_literal :: proc(v:json.Value) -> (f32,bool) {
    obj,ok:=v.(json.Object)
    if !ok {return jf32(v)}
    if lit,has:=obj["Literal"];has {return jf32(lit)}
    if val,has:=obj["Value"];has {return jf32(val)}
    return 0,false
}

@(private="file")
sample_curve_1d :: proc(samples:[]f32) -> (c:effect.Particle_Curve) {
    if len(samples)==0 {return effect.PARTICLE_CURVE_ONE}
    for i in 0..<effect.PARTICLE_CURVE_KEYS {
        t:=f32(i)/f32(effect.PARTICLE_CURVE_KEYS-1)
        idx:=int(t*f32(len(samples)-1)+0.5)
        c.times[i]=t
        c.values[i]=max(samples[clamp(idx,0,len(samples)-1)],0)
    }
    return
}

@(private="file")
sample_gradient_4d :: proc(samples:[]f32) -> (g:effect.Particle_Gradient) {
    count:=len(samples)/4
    if count==0 {return effect.PARTICLE_DEFAULTS.color_over_life}
    for i in 0..<effect.PARTICLE_CURVE_KEYS {
        t:=f32(i)/f32(effect.PARTICLE_CURVE_KEYS-1)
        idx:=clamp(int(t*f32(count-1)+0.5),0,count-1)
        g.times[i]=t
        g.colors[i]={
            max(samples[idx*4+0],0),
            max(samples[idx*4+1],0),
            max(samples[idx*4+2],0),
            clamp(samples[idx*4+3],0,1),
        }
    }
    return
}

@(private="file")
fmt_slang_f32 :: proc(v:f32) -> string {
    if math.is_nan(v) || math.is_inf(v) {return "0.0"}
    t:=fmt.tprintf("%g",v)
    if !strings.contains_any(t,".eE") {t=fmt.tprintf("%s.0",t)}
    return t
}

@(private="file")
jstr :: proc(v:json.Value,fallback:="") -> string {
    if s,ok:=v.(json.String);ok {return s}
    return fallback
}

@(private="file")
jbool :: proc(v:json.Value,fallback:=false) -> bool {
    if b,ok:=v.(json.Boolean);ok {return b}
    return fallback
}

@(private="file")
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
