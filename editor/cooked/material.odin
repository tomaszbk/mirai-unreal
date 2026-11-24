package cooked

import "core:encoding/json"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"

// Converts `ue5parse material` / `uobject.material_params_json` cooked JSON
// into a native Mirai v6 material (`asset.Material_Info` + `.mat` bytes +
// classified texture slot bindings), wiring Unreal's TwoSidedFoliage and
// Subsurface shading models directly to Mirai's Material_Diffuse_Transmission
// and Material_Subsurface.

Cooked_Scalar :: struct {
    name:string,
    value:f32,
    from:string,
}

Cooked_Vector :: struct {
    name:string,
    value:[4]f32,
    from:string,
}

Cooked_Texture :: struct {
    name:string,
    path:string,
    from:string,
}

Cooked_Switch :: struct {
    name:string,
    value:bool,
    from:string,
}

// Channel packing layout of the metallic/roughness/specular mask texture.
SMR_Layout :: enum u8 {
    ORM,                // R = AO, G = Roughness, B = Metallic (standard glTF/UE ORM)
    Fortnite_SMR,       // R = Specular, G = Metallic, B = Roughness (Fortnite SpecularMasks default)
    Fortnite_SRM_Green, // R = Specular, G = Roughness, B = Metallic (SwizzleRoughnessToGreen = true)
}

Cooked_Material :: struct {
    name:string,
    path:string,
    parent:string,
    blend_mode:string,
    shading_model:string,
    archetype:Material_Archetype,
    smr_layout:SMR_Layout,
    // Channel (0=R..3=A) of the source mask texture holding masked opacity cut-out.
    // Standard Mirai maps.mask reads .A (3); Fortnite MasksTexture stores cut-out in .R (0)
    // and must be swizzled to .A when importing/cooking the mask texture.
    mask_alpha_channel:u8,
    info:asset.Material_Info,
    texture_paths:[asset.Material_Map_Kind]string,
    program_name:string,
    program_source:string, // generated `//! mirai surface` Slang shader
    program_parameters:[]asset.Material_Parameter,
    program_textures:[]Cooked_Program_Texture,
    notes:[]string,
    scalars:[]Cooked_Scalar,
    vectors:[]Cooked_Vector,
    textures:[]Cooked_Texture,
    switches:[]Cooked_Switch,
    referenced_textures:[]string,
    dynamic_params:[]string,
}

// Frees all allocations owned by a Cooked_Material produced with `allocator`.
cooked_material_destroy :: proc(m:^Cooked_Material,allocator:=context.allocator) {
    delete(m.name,allocator)
    delete(m.path,allocator)
    delete(m.parent,allocator)
    delete(m.blend_mode,allocator)
    delete(m.shading_model,allocator)
    delete(m.program_name,allocator)
    delete(m.program_source,allocator)
    delete(m.program_parameters,allocator)
    for pt in m.program_textures {
        delete(pt.param,allocator)
        delete(pt.path,allocator)
    }
    delete(m.program_textures,allocator)
    for n in m.notes {delete(n,allocator)}
    delete(m.notes,allocator)
    for s in m.scalars {delete(s.name,allocator);delete(s.from,allocator)}
    delete(m.scalars,allocator)
    for v in m.vectors {delete(v.name,allocator);delete(v.from,allocator)}
    delete(m.vectors,allocator)
    for t in m.textures {delete(t.name,allocator);delete(t.path,allocator);delete(t.from,allocator)}
    delete(m.textures,allocator)
    for sw in m.switches {delete(sw.name,allocator);delete(sw.from,allocator)}
    delete(m.switches,allocator)
    for r in m.referenced_textures {delete(r,allocator)}
    delete(m.referenced_textures,allocator)
    for d in m.dynamic_params {delete(d,allocator)}
    delete(m.dynamic_params,allocator)
    m^={}
}

// Resolves texture paths on `m` into native Mirai Asset_Ids on both standard
// Material_Info.maps slots and archetype program_parameters (.Texture entries).
cooked_material_bind_textures :: proc(
    m:^Cooked_Material,
    resolve:proc(path:string,user:rawptr) -> base.Asset_Id,
    user:rawptr=nil,
) {
    if resolve==nil {return}
    maps:=asset.material_maps(&m.info.maps)
    for kind in asset.Material_Map_Kind {
        if path:=m.texture_paths[kind];path!="" {
            if id:=resolve(path,user);id!={} {
                maps[kind].texture=id
            }
        }
    }
    for pt in m.program_textures {
        if pt.path=="" {continue}
        id:=resolve(pt.path,user)
        if id=={} {continue}
        for &param in m.program_parameters {
            if param.kind==.Texture && base.text_get(param.name[:])==pt.param {
                param.texture=id
                break
            }
        }
    }
}

// Parses cooked material JSON (`ue5parse material` or canonical sidecar JSON)
// into a native Mirai v6 Material_Info + archetype Slang surface program.
cooked_material_parse :: proc(json_text:string,allocator:=context.allocator) -> (m:Cooked_Material,err:Maybe(Error)) {
    root,perr:=parse_json(json_text,context.temp_allocator)
    if perr!=nil {return {},perr}
    obj,ok:=json_obj(root)
    if !ok {return {},Error{"material","root JSON value must be an object"}}

    m.info=asset.MATERIAL_DEFAULTS
    m.mask_alpha_channel=3 // standard .A channel on Mirai maps.mask
    m.name=strings.clone(json_str(obj["Name"],json_str(obj["name"])),allocator)
    m.path=strings.clone(json_str(obj["Path"],json_str(obj["path"])),allocator)
    m.parent=strings.clone(json_str(obj["Parent"],json_str(obj["parent"])),allocator)

    // Support both flat properties (BlendMode/ShadingModel/TwoSided) and nested Material:{BlendMode:{Value:...}}.
    mat_sub,_:=json_obj(obj["Material"])
    prop_str :: proc(obj,sub:json.Object,key,fallback:string) -> string {
        if v,has:=obj[key];has {
            inner,_:=unwrap_entry(v)
            if s:=json_str(inner);s!="" {return s}
        }
        if sub!=nil {
            if v,has:=sub[key];has {
                inner,_:=unwrap_entry(v)
                if s:=json_str(inner);s!="" {return s}
            }
        }
        return fallback
    }
    prop_bool :: proc(obj,sub:json.Object,key:string,fallback:bool) -> bool {
        if v,has:=obj[key];has {
            inner,_:=unwrap_entry(v)
            return json_bool(inner,fallback)
        }
        if sub!=nil {
            if v,has:=sub[key];has {
                inner,_:=unwrap_entry(v)
                return json_bool(inner,fallback)
            }
        }
        return fallback
    }
    prop_f32 :: proc(obj,sub:json.Object,key:string,fallback:f32) -> f32 {
        if v,has:=obj[key];has {
            inner,_:=unwrap_entry(v)
            if f,fok:=json_f32(inner,fallback);fok {return f}
        }
        if sub!=nil {
            if v,has:=sub[key];has {
                inner,_:=unwrap_entry(v)
                if f,fok:=json_f32(inner,fallback);fok {return f}
            }
        }
        return fallback
    }

    m.blend_mode=strings.clone(prop_str(obj,mat_sub,"BlendMode","BLEND_Opaque"),allocator)
    m.shading_model=strings.clone(prop_str(obj,mat_sub,"ShadingModel","MSM_DefaultLit"),allocator)
    two_sided:=prop_bool(obj,mat_sub,"TwoSided",false)
    m.info.two_sided=two_sided
    clip:=prop_f32(obj,mat_sub,"OpacityMaskClipValue",0.3333)

    // BlendMode -> Mirai Alpha_Mode.
    blend:=short_enum(m.blend_mode)
    switch blend {
    case "BLEND_Masked","Masked":
        m.info.alpha_mode=.Mask
        m.info.alpha_cutoff=clamp(clip,0,1)
    case "BLEND_Additive","Additive":
        m.info.alpha_mode=.Additive
    case "BLEND_Translucent","Translucent","BLEND_AlphaComposite","AlphaComposite",
         "BLEND_TranslucentColoredTransmittance","BLEND_Modulate","Modulate","BLEND_AlphaHoldout":
        m.info.alpha_mode=.Blend
    }

    // Collect parameters (supports Scalars/Vectors/Textures/StaticSwitches AND lowercase sidecar aliases).
    scalars:=make([dynamic]Cooked_Scalar,allocator)
    vectors:=make([dynamic]Cooked_Vector,allocator)
    textures:=make([dynamic]Cooked_Texture,allocator)
    switches:=make([dynamic]Cooked_Switch,allocator)

    for key in ([]string{"Scalars","scalars"}) {
        if s_obj,has:=json_obj(obj[key]);has {
            for k,v in s_obj {
                val,from:=unwrap_entry(v)
                if f,fok:=json_f32(val);fok {
                    append(&scalars,Cooked_Scalar{strings.clone(k,allocator),f,strings.clone(from,allocator)})
                }
            }
        }
    }
    for key in ([]string{"Vectors","vectors"}) {
        if v_obj,has:=json_obj(obj[key]);has {
            for k,v in v_obj {
                val,from:=unwrap_entry(v)
                if vec,vok:=json_vec4(val);vok {
                    append(&vectors,Cooked_Vector{strings.clone(k,allocator),vec,strings.clone(from,allocator)})
                }
            }
        }
    }
    for key in ([]string{"Textures","textures"}) {
        if t_obj,has:=json_obj(obj[key]);has {
            for k,v in t_obj {
                val,from:=unwrap_entry(v)
                path:=json_str(val)
                if path!="" {
                    append(&textures,Cooked_Texture{strings.clone(k,allocator),strings.clone(path,allocator),strings.clone(from,allocator)})
                }
            }
        }
    }
    for key in ([]string{"StaticSwitches","static_switches","switches"}) {
        if sw_obj,has:=json_obj(obj[key]);has {
            for k,v in sw_obj {
                val,from:=unwrap_entry(v)
                append(&switches,Cooked_Switch{strings.clone(k,allocator),json_bool(val),strings.clone(from,allocator)})
            }
        }
    }
    // Canonical sidecar unified `parameters` map (dispatches by JSON value type).
    if p_obj,has:=json_obj(obj["parameters"]);has {
        for k,v in p_obj {
            val,from:=unwrap_entry(v)
            #partial switch x in val {
            case json.Boolean:
                append(&switches,Cooked_Switch{strings.clone(k,allocator),bool(x),strings.clone(from,allocator)})
            case json.Float,json.Integer:
                if f,fok:=json_f32(val);fok {
                    append(&scalars,Cooked_Scalar{strings.clone(k,allocator),f,strings.clone(from,allocator)})
                }
            case json.String:
                if string(x)!="" {
                    append(&textures,Cooked_Texture{strings.clone(k,allocator),strings.clone(string(x),allocator),strings.clone(from,allocator)})
                }
            case json.Array,json.Object:
                if vec,vok:=json_vec4(val);vok {
                    append(&vectors,Cooked_Vector{strings.clone(k,allocator),vec,strings.clone(from,allocator)})
                }
            }
        }
    }
    refs:=make([dynamic]string,allocator)
    if r_arr,has:=json_arr(obj["ReferencedTextures"]);has {
        for item in r_arr {
            if s:=json_str(item);s!="" {append(&refs,strings.clone(s,allocator))}
        }
    }
    dyn:=make([dynamic]string,allocator)
    if d_arr,has:=json_arr(obj["DynamicParameterNames"]);has {
        for item in d_arr {
            if s:=json_str(item);s!="" {append(&dyn,strings.clone(s,allocator))}
        }
    }

    // Sort for deterministic output regardless of JSON map iteration order.
    slice.sort_by(scalars[:],proc(a,b:Cooked_Scalar) -> bool {return a.name<b.name})
    slice.sort_by(vectors[:],proc(a,b:Cooked_Vector) -> bool {return a.name<b.name})
    slice.sort_by(textures[:],proc(a,b:Cooked_Texture) -> bool {return a.name<b.name})
    slice.sort_by(switches[:],proc(a,b:Cooked_Switch) -> bool {return a.name<b.name})

    m.scalars=scalars[:]
    m.vectors=vectors[:]
    m.textures=textures[:]
    m.switches=switches[:]
    m.referenced_textures=refs[:]
    m.dynamic_params=dyn[:]

    // Map high-ROI parameter values onto native Material_Info (v6).
    if v,found:=find_vector(m.vectors,{"BaseColor","BaseColorTint","Tint","DiffuseColor","Color","AlbedoTint","Albedo"});found {
        m.info.base_color={max(v.x,0),max(v.y,0),max(v.z,0)}
    }
    if v,found:=find_vector(m.vectors,{"EmissiveColor","Emissive","EmissiveTint","GlowColor"});found {
        intensity:f32=1
        if s,has_i:=find_scalar(m.scalars,{"EmissiveIntensity","EmissiveStrength","EmissivePower","EmissiveBoost","GlowIntensity"});has_i {
            intensity=max(s,0)
        }
        m.info.emission={max(v.x,0)*intensity,max(v.y,0)*intensity,max(v.z,0)*intensity}
    }
    if s,found:=find_scalar(m.scalars,{"Roughness","RoughnessMultiplier","RoughnessMax","RoughnessValue"});found {
        m.info.roughness=clamp(s,0,1)
    }
    if s,found:=find_scalar(m.scalars,{"Metallic","MetallicMultiplier","Metalness","MetallicValue"});found {
        m.info.metallic=clamp(s,0,1)
    }
    if s,found:=find_scalar(m.scalars,{"Opacity","Alpha","OpacityMultiplier"});found && m.info.alpha_mode!=.Opaque {
        m.info.opacity=clamp(s,0,1)
    }
    if s,found:=find_scalar(m.scalars,{"Specular","SpecularScale"});found {
        f0:=0.08*clamp(s,0,1)
        if f0>=0.02 {
            r:=math.sqrt(f0)
            m.info.ior=(1+r)/(1-r)
            m.info.specular_factor=1
        } else {
            r:=math.sqrt(f32(0.02))
            m.info.ior=(1+r)/(1-r)
            m.info.specular_factor=f0/0.02
        }
    }

    // Wire ShadingModel directly to Mirai v6 Material_Subsurface / Material_Diffuse_Transmission.
    // UE MSM_Subsurface and MSM_PreintegratedSkin invert Opacity (0 = max scatter, 1 = opaque);
    // UE MSM_SubsurfaceProfile uses Opacity directly (0 = none, 1 = full scatter).
    shading:=short_enum(m.shading_model)
    sss_color:=[3]f32{1,1,1}
    if v,found:=find_vector(m.vectors,{"SubsurfaceColor","SubsurfaceTint","FoliageSubsurfaceColor","ScatterColor","SkinSubsurfaceColor"});found {
        sss_color={clamp(v.x,0,1),clamp(v.y,0,1),clamp(v.z,0,1)}
    }
    sss_weight:f32=1
    if s,found:=find_scalar(m.scalars,{"SubsurfaceWeight","SubsurfaceStrength"});found {
        sss_weight=clamp(s,0,1)
    } else if s,found_op:=find_scalar(m.scalars,{"SubsurfaceOpacity","Opacity"});found_op {
        if shading=="MSM_SubsurfaceProfile" || shading=="SubsurfaceProfile" {
            sss_weight=clamp(s,0,1)
        } else {
            sss_weight=clamp(1-s,0,1)
        }
    }
    sss_radius:f32=0.015
    if s,found:=find_scalar(m.scalars,{"SubsurfaceRadius","ScatterRadius"});found {
        // Unreal SubsurfaceRadius may be in cm if > 0.1; clamp to Mirai's 0.1m max.
        r:=s>asset.MATERIAL_SUBSURFACE_RADIUS_MAX ? s*UNREAL_TO_MIRAI_SCALE : s
        sss_radius=clamp(r,0,asset.MATERIAL_SUBSURFACE_RADIUS_MAX)
    }

    switch shading {
    case "MSM_Unlit","Unlit":
        m.info.unlit=true
    case "MSM_TwoSidedFoliage","TwoSidedFoliage":
        apply_diffuse_transmission(&m.info,sss_color)
    case "MSM_Subsurface","Subsurface","MSM_PreintegratedSkin","PreintegratedSkin":
        if two_sided {
            apply_diffuse_transmission(&m.info,sss_color)
        } else {
            m.info.diffuse_transmission={}
            m.info.subsurface={
                weight=sss_weight,
                color=sss_color,
                radius=shading=="MSM_PreintegratedSkin"||shading=="PreintegratedSkin" ? min(sss_radius,0.012) : sss_radius,
            }
        }
    case "MSM_SubsurfaceProfile","SubsurfaceProfile":
        m.info.diffuse_transmission={}
        m.info.subsurface={weight=sss_weight,color=sss_color,radius=min(sss_radius,0.012)}
    case "MSM_ClearCoat","ClearCoat":
        coat_w:f32=1
        coat_r:f32=0.1
        if s,has:=find_scalar(m.scalars,{"ClearCoat","CoatWeight"});has {coat_w=clamp(s,0,1)}
        if s,has:=find_scalar(m.scalars,{"ClearCoatRoughness","CoatRoughness"});has {coat_r=clamp(s,0,1)}
        m.info.coat={weight=coat_w,roughness=coat_r,color={1,1,1},ior=1.5,normal_scale=1}
    case "MSM_Cloth","Cloth":
        fuzz_w:f32=0.5
        if s,has:=find_scalar(m.scalars,{"Cloth","Fuzz","FuzzWeight"});has {fuzz_w=clamp(s,0,1)}
        m.info.fuzz={weight=fuzz_w,color=sss_color,roughness=0.5}
    case "MSM_ThinTranslucent","ThinTranslucent":
        m.info.transmission=clamp(1-m.info.opacity,0,1)
        m.info.opacity=1
    }

    // Preshader-evaluated overrides take highest priority when present.
    if eval,has:=json_obj(obj["Evaluated"]);has {
        if bc,bok:=json_vec4(eval["BaseColorTint"]);bok {
            m.info.base_color={max(bc.x,0),max(bc.y,0),max(bc.z,0)}
        }
        if em,eok:=json_vec4(eval["EmissiveColor"]);eok && (em.x>0||em.y>0||em.z>0) {
            m.info.emission={max(em.x,0),max(em.y,0),max(em.z,0)}
        }
    }

    // Classify cooked texture parameter names onto Mirai Material_Map_Kind slots.
    // On opaque materials, Fortnite multi-channel MasksTexture (AO/Cavity/SSS) belongs
    // only to the Surface program's t_masks slot, not to Mirai's alpha-cutout maps.mask.
    for tex in m.textures {
        if kind,matched:=classify_texture_slot(tex.name);matched && m.texture_paths[kind]=="" {
            if kind==.Mask && m.info.alpha_mode==.Opaque && is_pbr_data_mask_name(tex.name) {
                continue
            }
            m.texture_paths[kind]=tex.path
        }
    }

    // Detect & apply one of the 6 native Mirai cooked material archetype templates.
    explicit_arch:=json_str(obj["archetype"],json_str(obj["Archetype"]))
    arch:=cooked_material_detect_archetype(explicit_arch,&m)
    cooked_material_apply_archetype(&m,arch,allocator)
    return m,nil
}

// Serializes a Cooked_Material's native v6 Material_Info + program parameters
// into Mirai `.mat` bytes.
cooked_material_bytes :: proc(m:^Cooked_Material,allocator:=context.allocator) -> ([]u8,asset.Error) {
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    return asset.material_bytes(&types,{info=m.info,parameters=m.program_parameters},allocator)
}

@(private="file")
apply_diffuse_transmission :: proc(info:^asset.Material_Info,sss:[3]f32) {
    info.subsurface={}
    mb:=max(info.base_color.x,max(info.base_color.y,info.base_color.z))
    ms:=max(sss.x,max(sss.y,sss.z))
    total:=mb+ms
    if total<=1e-6 {return}
    w:=clamp(ms/total,0,1)
    scale:=f32(1)/max(total,1)
    info.base_color={
        clamp(info.base_color.x*scale/max(1-w,1e-6),0,1),
        clamp(info.base_color.y*scale/max(1-w,1e-6),0,1),
        clamp(info.base_color.z*scale/max(1-w,1e-6),0,1),
    }
    info.diffuse_transmission={
        weight=w,
        color={
            clamp(sss.x*scale/max(w,1e-6),0,1),
            clamp(sss.y*scale/max(w,1e-6),0,1),
            clamp(sss.z*scale/max(w,1e-6),0,1),
        },
    }
}

@(private="file")
unwrap_entry :: proc(v:json.Value) -> (val:json.Value,from:string) {
    if obj,ok:=v.(json.Object);ok {
        if inner,has:=obj["Value"];has {
            return inner,json_str(obj["From"])
        }
    }
    return v,""
}

@(private="file")
short_enum :: proc(s:string) -> string {
    if i:=strings.last_index(s,"::");i>=0 {return s[i+2:]}
    return s
}

@(private="file")
find_scalar :: proc(list:[]Cooked_Scalar,names:[]string) -> (f32,bool) {
    for want in names {
        for s in list {if strings.equal_fold(s.name,want) {return s.value,true}}
    }
    return 0,false
}

@(private="file")
find_vector :: proc(list:[]Cooked_Vector,names:[]string) -> ([4]f32,bool) {
    for want in names {
        for v in list {if strings.equal_fold(v.name,want) {return v.value,true}}
    }
    return {},false
}

// True when `token` appears in `low` bounded by non-letters (start/end or delimiters
// like '_', '-', '.', '/', ' ', digits), preventing substrings like "uniform" or "storm"
// from matching short acronyms such as "orm".
@(private="file")
has_token :: proc(low,token:string) -> bool {
    is_letter :: proc(b:u8) -> bool {return (b>='a' && b<='z') || (b>='A' && b<='Z')}
    n:=len(token)
    if n==0 || len(low)<n {return false}
    for i:=0;i+n<=len(low);i+=1 {
        if low[i:i+n]!=token {continue}
        left_ok:=i==0 || !is_letter(low[i-1])
        right_ok:=i+n==len(low) || !is_letter(low[i+n])
        if left_ok && right_ok {return true}
    }
    return false
}

@(private="file")
is_pbr_data_mask_name :: proc(name:string) -> bool {
    low:=strings.to_lower(name,context.temp_allocator)
    return low=="maskstexture" || low=="masktexture" || low=="masks" || low=="m" ||
           strings.contains(low,"cavitymask") || strings.contains(low,"subsurfacemask")
}

@(private)
classify_texture_slot :: proc(name:string) -> (asset.Material_Map_Kind,bool) {
    low:=strings.to_lower(name,context.temp_allocator)
    switch {
    case strings.contains(low,"normal") || strings.has_suffix(low,"_n") || low=="n":
        return .Normal,true
    case strings.contains(low,"emissive") || strings.contains(low,"emission") || strings.contains(low,"glow"):
        return .Emission,true
    case strings.contains(low,"subsurface") || has_token(low,"sss"):
        return .Subsurface,true
    // Check packed PBR channel maps (SpecularMasks, SRM, SMR, ORM, MRA) BEFORE generic "mask"
    // so SpecularMasks is never misclassified as an opacity mask. Short acronyms require
    // token boundaries so names like "T_Uniform_D" or "T_Storm_D" are not misclassified.
    case strings.contains(low,"specularmasks") || strings.contains(low,"specular_masks") ||
         has_token(low,"srm") || has_token(low,"smr") ||
         has_token(low,"orm") || has_token(low,"mra") ||
         strings.contains(low,"rough") || strings.contains(low,"metal"):
        return .Metallic_Roughness,true
    case strings.contains(low,"specular") || strings.has_suffix(low,"_s"):
        return .Specular,true
    case strings.contains(low,"opacity") || strings.contains(low,"alpha") || strings.contains(low,"mask"):
        return .Mask,true
    case has_token(low,"ao") || strings.contains(low,"occlusion"):
        return .Occlusion,true
    case strings.contains(low,"diffuse") || strings.contains(low,"albedo") || strings.contains(low,"basecolor") || strings.contains(low,"base_color") || strings.contains(low,"color") || strings.has_suffix(low,"_d"):
        return .Base_Color,true
    }
    return .Base_Color,false
}
