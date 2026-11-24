package cooked

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"

// 6 Native Mirai Cooked Material Archetype Templates (`//! mirai surface`):
//   1. Standard_SMR   - PBR .mat v6 with ORM/SMR, M.R AO, M.G cavity, M.B subsurface, +Y normals
//   2. Foliage_3Color - Two-sided masked .mat v6 + Material_Diffuse_Transmission + 3-color gradient,
//                       1.5x backface boost, MasksTexture.R alpha, IsFlowers/IsFlowerV2 blend
//   3. Layered_UV1    - Up to 6 material layers (Diffuse/Normal/ORM) selected by UV1.u
//   4. Toon           - Cel-shaded diffuse ramp + crisp specular band
//   5. Glass          - Refractive/translucent .mat v6 glass with Fresnel & tint
//   6. Skin_SSS       - OpenPBR Material_Subsurface .mat v6 driven by M.B, roughness bounds & cavity

Material_Archetype :: enum u8 {
    Standard_SMR,
    Foliage_3Color,
    Layered_UV1,
    Toon,
    Glass,
    Skin_SSS,
}

Cooked_Program_Texture :: struct {
    param:string, // parameter field name in Parameters struct (e.g. "t_diffuse")
    path:string,  // Unreal texture object path ("" when unbound)
}

// Classifies the canonical archetype from an explicit sidecar `archetype` string
// or by inspecting shading model, blend mode, and Fortnite/UE parameter signatures.
cooked_material_detect_archetype :: proc(explicit:string,m:^Cooked_Material) -> Material_Archetype {
    if explicit!="" {
        low:=strings.to_lower(explicit,context.temp_allocator)
        switch low {
        case "foliage","foliage_3color","leaf","leaves","vegetation":
            return .Foliage_3Color
        case "layered","layered_uv1","building","multi_layer":
            return .Layered_UV1
        case "toon","cel","stylized":
            return .Toon
        case "glass","translucent","refraction","crystal":
            return .Glass
        case "skin","skin_sss","subsurface","sss","eye","hair":
            return .Skin_SSS
        case "standard","standard_smr","pbr","default":
            return .Standard_SMR
        }
    }
    // Auto-detect from shading model and high-signal Fortnite parameter names.
    shading:=short_enum_str(m.shading_model)
    if shading=="MSM_TwoSidedFoliage" || shading=="TwoSidedFoliage" {return .Foliage_3Color}
    if has_vec_any(m.vectors,{"Color1_Base","Color2_Lit","Color3_Shadows","FlowerColorMult"}) ||
       has_switch_any(m.switches,{"IsFlowers","IsFlowerV2"}) {
        return .Foliage_3Color
    }
    if has_layered_uv1_textures(m.textures) {return .Layered_UV1}
    if has_switch_any(m.switches,{"UseToon","ToonShading","CelShading","IsToon"}) ||
       strings.contains(strings.to_lower(m.name,context.temp_allocator),"toon") {
        return .Toon
    }
    if shading=="MSM_ThinTranslucent" || shading=="ThinTranslucent" ||
       (m.info.alpha_mode==.Blend && !m.info.unlit &&
        (m.info.transmission>0 || strings.contains(strings.to_lower(m.name,context.temp_allocator),"glass"))) {
        return .Glass
    }
    if shading=="MSM_Subsurface" || shading=="Subsurface" ||
       shading=="MSM_PreintegratedSkin" || shading=="PreintegratedSkin" ||
       shading=="MSM_SubsurfaceProfile" || shading=="SubsurfaceProfile" {
        if !m.info.two_sided {return .Skin_SSS}
    }
    return .Standard_SMR
}

// Applies the selected archetype's native Mirai .mat v6 settings, parameters,
// texture bindings, and `//! mirai surface` Slang shader onto `m`.
cooked_material_apply_archetype :: proc(m:^Cooked_Material,archetype:Material_Archetype,allocator:=context.allocator) {
    m.archetype=archetype
    params:=make([dynamic]asset.Material_Parameter,allocator)
    ptexs:=make([dynamic]Cooked_Program_Texture,allocator)
    notes:=make([dynamic]string,allocator)

    add_tex :: proc(params:^[dynamic]asset.Material_Parameter,ptexs:^[dynamic]Cooked_Program_Texture,name,path:string,alloc:mem.Allocator) {
        p:asset.Material_Parameter
        asset.text_set(p.name[:],name)
        p.kind=.Texture
        p.components=1
        append(params,p)
        append(ptexs,Cooked_Program_Texture{strings.clone(name,alloc),strings.clone(path,alloc)})
    }
    add_vec4 :: proc(params:^[dynamic]asset.Material_Parameter,name:string,v:[4]f32) {
        p:asset.Material_Parameter
        asset.text_set(p.name[:],name)
        p.kind=.Float
        p.components=4
        for c in 0..<4 {p.value[c]=f64(v[c])}
        append(params,p)
    }

    r_min,has_rmin:=find_scalar_any(m.scalars,{"RoughnessMin","MinRoughness","SpecularRoughnessMin"})
    r_max,has_rmax:=find_scalar_any(m.scalars,{"RoughnessMax","MaxRoughness","SpecularRoughnessMax"})
    if !has_rmin {r_min=0}
    if !has_rmax {r_max=1}
    r_min=clamp(r_min,0,1)
    r_max=clamp(max(r_max,r_min),0,1)

    diff_path:=m.texture_paths[.Base_Color]
    norm_path:=m.texture_paths[.Normal]
    orm_path:=m.texture_paths[.Metallic_Roughness]
    if orm_path=="" {orm_path=find_tex_any(m.textures,{"SpecularMasks","Specular_Masks","SMR","SRM","ORM","MRA"})}
    masks_path:=find_tex_any(m.textures,{"MasksTexture","MaskTexture","Masks","M","SubsurfaceMask","CavityMask","OpacityMask"})
    if masks_path=="" && m.texture_paths[.Mask]!=orm_path {masks_path=m.texture_paths[.Mask]}

    // Distinguish standard ORM (R=AO, G=Roughness, B=Metallic) from Fortnite SpecularMasks
    // (R=Specular, G=Metallic, B=Roughness, or SwizzleRoughnessToGreen: R=Specular, G=Roughness, B=Metallic).
    m.smr_layout=detect_smr_layout(m)
    smr_mode:=f32(m.smr_layout)

    switch archetype {
    case .Standard_SMR:
        prog_name:=archetype_program_name("Cooked_Standard_SMR",m.name,allocator)
        sss_w:=m.info.subsurface.weight
        if sss_w==0 {
            if sw,ok:=find_scalar_any(m.scalars,{"SubsurfaceWeight","SubsurfaceStrength"});ok && sw>0 {
                sss_w=clamp(sw,0,1)
            } else if so,ok_op:=find_scalar_any(m.scalars,{"SubsurfaceOpacity"});ok_op {
                sh:=short_enum_str(m.shading_model)
                sss_w=sh=="MSM_SubsurfaceProfile"||sh=="SubsurfaceProfile" ? clamp(so,0,1) : clamp(1-so,0,1)
            }
        }
        sss_rad:=m.info.subsurface.radius>0 ? m.info.subsurface.radius : 0.015
        sss_col:=clamp_rgb(m.info.subsurface.color!={} ? m.info.subsurface.color : [3]f32{1,1,1})
        if sss_w>0 {
            m.info.diffuse_transmission={}
            m.info.subsurface={weight=sss_w,color=sss_col,radius=clamp(sss_rad,0,asset.MATERIAL_SUBSURFACE_RADIUS_MAX)}
        } else {
            m.info.subsurface={}
        }
        add_tex(&params,&ptexs,"t_diffuse",diff_path,allocator)
        add_tex(&params,&ptexs,"t_normal",norm_path,allocator)
        add_tex(&params,&ptexs,"t_smr",orm_path,allocator)
        add_tex(&params,&ptexs,"t_masks",masks_path,allocator)
        add_vec4(&params,"base_tint",{m.info.base_color.x,m.info.base_color.y,m.info.base_color.z,m.info.opacity})
        add_vec4(&params,"sss_color",{sss_col.x,sss_col.y,sss_col.z,clamp(sss_rad,0,asset.MATERIAL_SUBSURFACE_RADIUS_MAX)})
        add_vec4(&params,"pbr_bounds",{r_min,r_max,m.info.metallic,sss_w})
        add_vec4(&params,"cavity_ao",{m.info.occlusion_strength,0.5,m.info.normal_scale,smr_mode})
        m.program_name=prog_name
        m.program_source=emit_standard_smr_slang(prog_name,allocator)
        asset.text_set(m.info.program[:],prog_name)

    case .Foliage_3Color:
        prog_name:=archetype_program_name("Cooked_Foliage_3Color",m.name,allocator)
        m.info.two_sided=true
        m.info.subsurface={}
        if m.info.alpha_mode==.Opaque {
            m.info.alpha_mode=.Mask
            if m.info.alpha_cutoff<=0 {m.info.alpha_cutoff=0.3333}
        }
        c1:=[3]f32{m.info.base_color.x,m.info.base_color.y,m.info.base_color.z}
        if v,ok:=find_vec_any(m.vectors,{"Color1_Base","Color1","BaseColor"});ok {c1=clamp_rgb(v.xyz)}
        c2:=c1
        if v,ok:=find_vec_any(m.vectors,{"Color2_Lit","Color2","LitColor"});ok {c2=clamp_rgb(v.xyz)}
        c3:=c1*0.5
        if v,ok:=find_vec_any(m.vectors,{"Color3_Shadows","Color3","ShadowColor"});ok {c3=clamp_rgb(v.xyz)}
        flower_mult:=[3]f32{1,1,1}
        if v,ok:=find_vec_any(m.vectors,{"FlowerColorMult","FlowerColor","FlowerTint"});ok {flower_mult=clamp_rgb(v.xyz)}
        is_flowers:=f32(0)
        if b,ok:=find_switch_any(m.switches,{"IsFlowers","IsFlowerV2","bIsFlowers"});ok && b {is_flowers=1}
        if s,ok:=find_scalar_any(m.scalars,{"IsFlowers","IsFlowerV2"});ok && s>0.5 {is_flowers=1}
        backface_boost:f32=1.5
        if s,ok:=find_scalar_any(m.scalars,{"BackfaceBoost","SubsurfaceBoost"});ok && s>0 {backface_boost=s}
        dt_w:=m.info.diffuse_transmission.weight>0 ? m.info.diffuse_transmission.weight : 0.5
        m.info.diffuse_transmission={weight=clamp(dt_w,0.01,1),color=c2}
        // Mirai masked coverage reads maps.mask.a (Surface programs never decide masked cut-out).
        // When Fortnite packs leaf cut-out in MasksTexture.R, record mask_alpha_channel = 0 so
        // texture import/cooking swizzles R -> A before binding maps.mask.
        opacity_mask_path:=find_tex_any(m.textures,{"OpacityMask","AlphaMask","Opacity"})
        if opacity_mask_path!="" {
            m.texture_paths[.Mask]=opacity_mask_path
            m.mask_alpha_channel=3
        } else if masks_path!="" {
            m.texture_paths[.Mask]=masks_path
            m.mask_alpha_channel=0
            append(&notes,strings.clone("foliage MasksTexture stores alpha cut-out in R; swizzle R->A into maps.mask.a for Mirai masked coverage",allocator))
        }
        add_tex(&params,&ptexs,"t_diffuse",diff_path,allocator)
        add_tex(&params,&ptexs,"t_normal",norm_path,allocator)
        add_tex(&params,&ptexs,"t_masks",masks_path,allocator)
        add_tex(&params,&ptexs,"t_orm",orm_path,allocator)
        add_vec4(&params,"color1_base",{c1.x,c1.y,c1.z,smr_mode})
        add_vec4(&params,"color2_lit",{c2.x,c2.y,c2.z,1})
        add_vec4(&params,"color3_shadows",{c3.x,c3.y,c3.z,1})
        add_vec4(&params,"flower_color_mult",{flower_mult.x,flower_mult.y,flower_mult.z,is_flowers})
        add_vec4(&params,"foliage_params",{r_min,r_max,backface_boost,dt_w})
        m.program_name=prog_name
        m.program_source=emit_foliage_3color_slang(prog_name,allocator)
        asset.text_set(m.info.program[:],prog_name)

    case .Layered_UV1:
        prog_name:=archetype_program_name("Cooked_Layered_UV1",m.name,allocator)
        if m.info.subsurface.weight>0 && m.info.diffuse_transmission.weight>0 {m.info.diffuse_transmission={}}
        diffs,norms,orms,layer_count:=extract_uv1_layers(m.textures,diff_path,norm_path,orm_path)
        for i in 0..<6 {add_tex(&params,&ptexs,fmt.tprintf("t_diff_%d",i),diffs[i],allocator)}
        for i in 0..<6 {add_tex(&params,&ptexs,fmt.tprintf("t_norm_%d",i),norms[i],allocator)}
        for i in 0..<6 {add_tex(&params,&ptexs,fmt.tprintf("t_orm_%d",i),orms[i],allocator)}
        uv_scale:f32=1
        if s,ok:=find_scalar_any(m.scalars,{"Tiling","UVScale","UVTiling"});ok && s>0 {uv_scale=s}
        add_vec4(&params,"layer_params",{f32(max(layer_count,1)),r_min,r_max,uv_scale})
        add_vec4(&params,"tint",{m.info.base_color.x,m.info.base_color.y,m.info.base_color.z,m.info.metallic})
        m.program_name=prog_name
        m.program_source=emit_layered_uv1_slang(prog_name,allocator)
        asset.text_set(m.info.program[:],prog_name)

    case .Toon:
        prog_name:=archetype_program_name("Cooked_Toon",m.name,allocator)
        if m.info.subsurface.weight>0 && m.info.diffuse_transmission.weight>0 {m.info.diffuse_transmission={}}
        shadow_col:=[3]f32{m.info.base_color.x*0.45,m.info.base_color.y*0.45,m.info.base_color.z*0.55}
        if v,ok:=find_vec_any(m.vectors,{"ShadowColor","ShadowTint","Color3_Shadows","ToonShadowColor"});ok {shadow_col=clamp_rgb(v.xyz)}
        steps:f32=3
        if s,ok:=find_scalar_any(m.scalars,{"ToonSteps","RampSteps","CelBands"});ok && s>=1 {steps=clamp(s,1,8)}
        spec_thresh:f32=0.65
        if s,ok:=find_scalar_any(m.scalars,{"SpecThreshold","SpecularBand"});ok {spec_thresh=clamp(s,0.05,0.99)}
        add_tex(&params,&ptexs,"t_diffuse",diff_path,allocator)
        add_tex(&params,&ptexs,"t_normal",norm_path,allocator)
        add_tex(&params,&ptexs,"t_orm",orm_path,allocator)
        add_vec4(&params,"base_tint",{m.info.base_color.x,m.info.base_color.y,m.info.base_color.z,steps})
        add_vec4(&params,"shadow_tint",{shadow_col.x,shadow_col.y,shadow_col.z,spec_thresh})
        add_vec4(&params,"rim_params",{r_min,r_max,0.0,smr_mode})
        append(&notes,strings.clone("toon view-dependent rim is omitted: Mirai surface programs do not see the camera",allocator))
        m.program_name=prog_name
        m.program_source=emit_toon_slang(prog_name,allocator)
        asset.text_set(m.info.program[:],prog_name)

    case .Glass:
        prog_name:=archetype_program_name("Cooked_Glass",m.name,allocator)
        m.info.alpha_mode=.Blend
        m.info.subsurface={}
        m.info.diffuse_transmission={}
        ior:=m.info.ior>1 ? m.info.ior : 1.5
        if s,ok:=find_scalar_any(m.scalars,{"IOR","Refraction","IndexOfRefraction"});ok && s>=1 {ior=clamp(s,1,2.5)}
        m.info.ior=ior
        if m.info.transmission<=0 {m.info.transmission=clamp(1-m.info.opacity*0.5,0.2,0.95)}
        glass_op:=clamp(m.info.opacity,0.05,1)
        if _,has_fe:=find_scalar_any(m.scalars,{"FresnelExponent","FresnelPower"});has_fe {
            append(&notes,strings.clone("glass uses Mirai physical IOR Fresnel: custom FresnelExponent is not evaluated in surface programs",allocator))
        }
        add_tex(&params,&ptexs,"t_diffuse",diff_path,allocator)
        add_tex(&params,&ptexs,"t_normal",norm_path,allocator)
        add_tex(&params,&ptexs,"t_roughness",orm_path,allocator)
        add_vec4(&params,"glass_tint",{m.info.base_color.x,m.info.base_color.y,m.info.base_color.z,glass_op})
        add_vec4(&params,"glass_params",{ior,m.info.transmission,m.info.normal_scale,smr_mode})
        add_vec4(&params,"rough_params",{r_min,min(r_max,0.35),1.0,1.0})
        m.program_name=prog_name
        m.program_source=emit_glass_slang(prog_name,allocator)
        asset.text_set(m.info.program[:],prog_name)

    case .Skin_SSS:
        prog_name:=archetype_program_name("Cooked_Skin_SSS",m.name,allocator)
        m.info.diffuse_transmission={}
        sss_w:=m.info.subsurface.weight>0 ? m.info.subsurface.weight : 0.85
        sss_col:=clamp_rgb(m.info.subsurface.color!={} ? m.info.subsurface.color : [3]f32{0.95,0.35,0.2})
        sss_rad:=m.info.subsurface.radius>0 ? m.info.subsurface.radius : 0.012
        m.info.subsurface={
            weight=clamp(sss_w,0.01,1),
            color=sss_col,
            radius=clamp(sss_rad,0.001,asset.MATERIAL_SUBSURFACE_RADIUS_MAX),
        }
        add_tex(&params,&ptexs,"t_diffuse",diff_path,allocator)
        add_tex(&params,&ptexs,"t_normal",norm_path,allocator)
        add_tex(&params,&ptexs,"t_smr",orm_path,allocator)
        add_tex(&params,&ptexs,"t_masks",masks_path,allocator)
        add_vec4(&params,"base_tint",{m.info.base_color.x,m.info.base_color.y,m.info.base_color.z,smr_mode})
        add_vec4(&params,"sss_params",{sss_col.x,sss_col.y,sss_col.z,m.info.subsurface.radius})
        add_vec4(&params,"skin_bounds",{r_min,r_max,m.info.subsurface.weight,m.info.occlusion_strength})
        m.program_name=prog_name
        m.program_source=emit_skin_sss_slang(prog_name,allocator)
        asset.text_set(m.info.program[:],prog_name)
    }

    m.program_parameters=params[:]
    m.program_textures=ptexs[:]
    m.notes=notes[:]
}

// ---- Clean-room Mirai Surface Slang templates --------------------------------------

@(private="file")
NORMAL_HELPER :: `float3 cooked_normal_gl(Mirai_Surface_Context ctx, uint tex, Mirai_Dual2 uv, float scale) {
    if (tex == 0xffffffffu) return ctx.normal;
    float4 n = mirai_sample_texture(ctx, tex, uv);
    float2 xy = (n.xy * 2.0 - 1.0) * scale;
    float z = sqrt(saturate(1.0 - dot(xy, xy)));
    float3 b = ctx.tangent.w * cross(ctx.vertex_normal, ctx.tangent.xyz);
    return normalize(ctx.tangent.xyz * xy.x + b * xy.y + ctx.vertex_normal * z);
}
// Unpacks ORM (mode 0: R=AO, G=Roughness, B=Metallic), Fortnite SpecularMasks
// (mode 1: R=Specular, G=Metallic, B=Roughness), or SwizzleRoughnessToGreen
// (mode 2: R=Specular, G=Roughness, B=Metallic) without channel swaps.
void cooked_unpack_smr(float4 tex, float mode, out float ao, out float spec, out float rough, out float metal) {
    if (mode < 0.5) {
        ao = tex.r; spec = 0.5; rough = tex.g; metal = tex.b;
    } else if (mode < 1.5) {
        ao = 1.0; spec = tex.r; metal = tex.g; rough = tex.b;
    } else {
        ao = 1.0; spec = tex.r; rough = tex.g; metal = tex.b;
    }
}
void cooked_apply_specular(inout Mirai_Surface s, float specular, float cavity) {
    float f0 = 0.08 * saturate(specular);
    float r = sqrt(max(f0, 0.02));
    s.specular_ior = (1.0 + r) / (1.0 - r);
    s.specular_factor = saturate(min(f0 / 0.02, 1.0) * cavity);
}
`

@(private="file")
emit_standard_smr_slang :: proc(name:string,allocator:mem.Allocator) -> string {
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"//! mirai surface %s\n",name)
    strings.write_string(&b,`//! parameter t_diffuse {"kind":"texture","srgb":true,"normal":false}
//! parameter t_normal {"kind":"texture","srgb":false,"normal":true}
//! parameter t_smr {"kind":"texture","srgb":false,"normal":false}
//! parameter t_masks {"kind":"texture","srgb":false,"normal":false}
//! parameter base_tint {"default":[1,1,1,1]}
//! parameter sss_color {"default":[1,1,1,0.015]}
//! parameter pbr_bounds {"default":[0,1,0,0]}
//! parameter cavity_ao {"default":[1,0.5,1,0]}
`)
    fmt.sbprintf(&b,"namespace %s {{\n",name)
    strings.write_string(&b,`struct Parameters {
    uint t_diffuse;
    uint t_normal;
    uint t_smr;
    uint t_masks;
    float4 base_tint;
    float4 sss_color;
    float4 pbr_bounds;
    float4 cavity_ao;
};
`)
    strings.write_string(&b,NORMAL_HELPER)
    strings.write_string(&b,`Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    Mirai_Dual2 uv = mirai_uv0(ctx);
    float4 diff = p.t_diffuse != 0xffffffffu ? mirai_sample_texture(ctx, p.t_diffuse, uv) : float4(1.0);
    float smr_ao = 1.0, smr_spec = 0.5, smr_rough = 0.5, smr_metal = 0.0;
    if (p.t_smr != 0xffffffffu) {
        cooked_unpack_smr(mirai_sample_texture(ctx, p.t_smr, uv), p.cavity_ao.w, smr_ao, smr_spec, smr_rough, smr_metal);
    }
    float4 m = p.t_masks != 0xffffffffu ? mirai_sample_texture(ctx, p.t_masks, uv) : float4(1.0, 1.0, 0.0, 1.0);
    float ao = lerp(1.0, m.r * smr_ao, saturate(p.cavity_ao.x));
    float cavity = lerp(1.0, m.g, saturate(p.cavity_ao.y));
    s.base_color = diff.rgb * p.base_tint.rgb * cavity;
    s.alpha = diff.a * p.base_tint.a;
    s.normal = cooked_normal_gl(ctx, p.t_normal, uv, p.cavity_ao.z);
    s.roughness = saturate(lerp(p.pbr_bounds.x, p.pbr_bounds.y, smr_rough));
    s.metallic = saturate(max(smr_metal, p.pbr_bounds.z));
    s.occlusion = saturate(ao);
    cooked_apply_specular(s, smr_spec, cavity);
    float sss_w = saturate(p.pbr_bounds.w * (p.t_masks != 0xffffffffu ? m.b : 1.0));
    if (sss_w > 0.0) {
        s.subsurface_weight = sss_w;
        s.subsurface_color = saturate(p.sss_color.rgb);
        s.subsurface_radius = clamp(p.sss_color.a, 0.0, 0.1);
    }
    return s;
}
}
`)
    return strings.to_string(b)
}

@(private="file")
emit_foliage_3color_slang :: proc(name:string,allocator:mem.Allocator) -> string {
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"//! mirai surface %s\n",name)
    strings.write_string(&b,`//! parameter t_diffuse {"kind":"texture","srgb":true,"normal":false}
//! parameter t_normal {"kind":"texture","srgb":false,"normal":true}
//! parameter t_masks {"kind":"texture","srgb":false,"normal":false}
//! parameter t_orm {"kind":"texture","srgb":false,"normal":false}
//! parameter color1_base {"default":[0.2,0.45,0.1,0]}
//! parameter color2_lit {"default":[0.35,0.65,0.15,1]}
//! parameter color3_shadows {"default":[0.1,0.25,0.06,1]}
//! parameter flower_color_mult {"default":[1,1,1,0]}
//! parameter foliage_params {"default":[0.25,0.85,1.5,0.5]}
`)
    fmt.sbprintf(&b,"namespace %s {{\n",name)
    strings.write_string(&b,`struct Parameters {
    uint t_diffuse;
    uint t_normal;
    uint t_masks;
    uint t_orm;
    float4 color1_base;
    float4 color2_lit;
    float4 color3_shadows;
    float4 flower_color_mult;
    float4 foliage_params;
};
`)
    strings.write_string(&b,NORMAL_HELPER)
    strings.write_string(&b,`Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    Mirai_Dual2 uv = mirai_uv0(ctx);
    float4 diff = p.t_diffuse != 0xffffffffu ? mirai_sample_texture(ctx, p.t_diffuse, uv) : float4(1.0);
    float4 masks = p.t_masks != 0xffffffffu ? mirai_sample_texture(ctx, p.t_masks, uv) : float4(diff.a, 1.0, 0.5, 1.0);
    float orm_ao = 1.0, orm_spec = 0.5, orm_rough = 0.6, orm_metal = 0.0;
    if (p.t_orm != 0xffffffffu) {
        cooked_unpack_smr(mirai_sample_texture(ctx, p.t_orm, uv), p.color1_base.a, orm_ao, orm_spec, orm_rough, orm_metal);
    }
    // 3-color gradient driven by MasksTexture.b * 2.0 (Color1_Base -> Color2_Lit -> Color3_Shadows).
    float t = masks.b * 2.0;
    float3 grad = lerp(lerp(p.color1_base.rgb, p.color2_lit.rgb, saturate(t)), p.color3_shadows.rgb, saturate(t - 1.0));
    float3 albedo = grad * diff.rgb;
    // IsFlowers / IsFlowerV2 blends Diffuse * FlowerColorMult by MasksTexture.b.
    if (p.flower_color_mult.a > 0.5) {
        albedo = lerp(albedo, diff.rgb * p.flower_color_mult.rgb, saturate(masks.b));
    }
    s.base_color = saturate(albedo);
    s.normal = cooked_normal_gl(ctx, p.t_normal, uv, 1.0);
    s.roughness = saturate(lerp(p.foliage_params.x, p.foliage_params.y, orm_rough));
    s.metallic = 0.0;
    s.occlusion = saturate(masks.g * orm_ao);
    cooked_apply_specular(s, orm_spec, 1.0);
    s.diffuse_transmission_weight = saturate(p.foliage_params.w);
    s.diffuse_transmission_color = saturate(albedo * p.foliage_params.z);
    return s;
}
}
`)
    return strings.to_string(b)
}

@(private="file")
emit_layered_uv1_slang :: proc(name:string,allocator:mem.Allocator) -> string {
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"//! mirai surface %s\n",name)
    for i in 0..<6 {fmt.sbprintf(&b,"//! parameter t_diff_%d {{\"kind\":\"texture\",\"srgb\":true,\"normal\":false}}\n",i)}
    for i in 0..<6 {fmt.sbprintf(&b,"//! parameter t_norm_%d {{\"kind\":\"texture\",\"srgb\":false,\"normal\":true}}\n",i)}
    for i in 0..<6 {fmt.sbprintf(&b,"//! parameter t_orm_%d {{\"kind\":\"texture\",\"srgb\":false,\"normal\":false}}\n",i)}
    strings.write_string(&b,`//! parameter layer_params {"default":[6,0,1,1]}
//! parameter tint {"default":[1,1,1,0]}
`)
    fmt.sbprintf(&b,"namespace %s {{\nstruct Parameters {{\n",name)
    for i in 0..<6 {fmt.sbprintf(&b,"    uint t_diff_%d;\n",i)}
    for i in 0..<6 {fmt.sbprintf(&b,"    uint t_norm_%d;\n",i)}
    for i in 0..<6 {fmt.sbprintf(&b,"    uint t_orm_%d;\n",i)}
    strings.write_string(&b,`    float4 layer_params;
    float4 tint;
};
`)
    strings.write_string(&b,NORMAL_HELPER)
    strings.write_string(&b,`Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    Mirai_Dual2 uv = mirai_uv0(ctx) * max(p.layer_params.w, 1e-4);
    int idx = clamp(int(floor(saturate(ctx.uv1.x) * max(p.layer_params.x, 1.0))), 0, 5);
    uint td = p.t_diff_0; uint tn = p.t_norm_0; uint to = p.t_orm_0;
    if (idx == 1) { td = p.t_diff_1; tn = p.t_norm_1; to = p.t_orm_1; }
    else if (idx == 2) { td = p.t_diff_2; tn = p.t_norm_2; to = p.t_orm_2; }
    else if (idx == 3) { td = p.t_diff_3; tn = p.t_norm_3; to = p.t_orm_3; }
    else if (idx == 4) { td = p.t_diff_4; tn = p.t_norm_4; to = p.t_orm_4; }
    else if (idx == 5) { td = p.t_diff_5; tn = p.t_norm_5; to = p.t_orm_5; }
    if (td == 0xffffffffu) td = p.t_diff_0;
    if (tn == 0xffffffffu) tn = p.t_norm_0;
    if (to == 0xffffffffu) to = p.t_orm_0;
    float4 diff = td != 0xffffffffu ? mirai_sample_texture(ctx, td, uv) : float4(1.0);
    float4 orm = to != 0xffffffffu ? mirai_sample_texture(ctx, to, uv) : float4(1.0, 0.5, 0.0, 1.0);
    s.base_color = diff.rgb * p.tint.rgb;
    s.normal = cooked_normal_gl(ctx, tn, uv, 1.0);
    s.occlusion = saturate(orm.r);
    s.roughness = saturate(lerp(p.layer_params.y, p.layer_params.z, orm.g));
    s.metallic = saturate(max(orm.b, p.tint.a));
    return s;
}
}
`)
    return strings.to_string(b)
}

@(private="file")
emit_toon_slang :: proc(name:string,allocator:mem.Allocator) -> string {
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"//! mirai surface %s\n",name)
    strings.write_string(&b,`//! parameter t_diffuse {"kind":"texture","srgb":true,"normal":false}
//! parameter t_normal {"kind":"texture","srgb":false,"normal":true}
//! parameter t_orm {"kind":"texture","srgb":false,"normal":false}
//! parameter base_tint {"default":[1,1,1,3]}
//! parameter shadow_tint {"default":[0.45,0.45,0.55,0.65]}
//! parameter rim_params {"default":[0,1,0.35,0.12]}
`)
    fmt.sbprintf(&b,"namespace %s {{\n",name)
    strings.write_string(&b,`struct Parameters {
    uint t_diffuse;
    uint t_normal;
    uint t_orm;
    float4 base_tint;
    float4 shadow_tint;
    float4 rim_params;
};
`)
    strings.write_string(&b,NORMAL_HELPER)
    strings.write_string(&b,`Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    Mirai_Dual2 uv = mirai_uv0(ctx);
    float4 diff = p.t_diffuse != 0xffffffffu ? mirai_sample_texture(ctx, p.t_diffuse, uv) : float4(1.0);
    float orm_ao = 1.0, orm_spec = 0.5, orm_rough = 0.4, orm_metal = 0.0;
    if (p.t_orm != 0xffffffffu) {
        cooked_unpack_smr(mirai_sample_texture(ctx, p.t_orm, uv), p.rim_params.w, orm_ao, orm_spec, orm_rough, orm_metal);
    }
    float3 n = cooked_normal_gl(ctx, p.t_normal, uv, 1.0);
    // Cel-shaded diffuse ramp quantized into discrete bands over surface elevation/AO.
    float shade = saturate((n.y * 0.5 + 0.5) * orm_ao);
    float steps = max(floor(p.base_tint.a + 0.5), 1.0);
    float band = floor(shade * steps + 0.5) / steps;
    float3 lit_col = diff.rgb * p.base_tint.rgb;
    float3 cel = lerp(lit_col * p.shadow_tint.rgb, lit_col, band);
    // Crisp specular band via step threshold.
    float spec_band = step(p.shadow_tint.a, 1.0 - orm_rough);
    s.base_color = saturate(cel);
    s.normal = n;
    s.roughness = saturate(lerp(lerp(p.rim_params.x, p.rim_params.y, orm_rough), 0.12, spec_band));
    s.metallic = saturate(orm_metal);
    s.specular_factor = lerp(0.25, 1.0, spec_band);
    s.occlusion = saturate(orm_ao);
    return s;
}
}
`)
    return strings.to_string(b)
}

@(private="file")
emit_glass_slang :: proc(name:string,allocator:mem.Allocator) -> string {
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"//! mirai surface %s\n",name)
    strings.write_string(&b,`//! parameter t_diffuse {"kind":"texture","srgb":true,"normal":false}
//! parameter t_normal {"kind":"texture","srgb":false,"normal":true}
//! parameter t_roughness {"kind":"texture","srgb":false,"normal":false}
//! parameter glass_tint {"default":[0.9,0.97,1,0.35]}
//! parameter glass_params {"default":[1.5,0.8,1,0]}
//! parameter rough_params {"default":[0.02,0.2,1,1]}
`)
    fmt.sbprintf(&b,"namespace %s {{\n",name)
    strings.write_string(&b,`struct Parameters {
    uint t_diffuse;
    uint t_normal;
    uint t_roughness;
    float4 glass_tint;
    float4 glass_params;
    float4 rough_params;
};
`)
    strings.write_string(&b,NORMAL_HELPER)
    strings.write_string(&b,`Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    Mirai_Dual2 uv = mirai_uv0(ctx);
    float4 diff = p.t_diffuse != 0xffffffffu ? mirai_sample_texture(ctx, p.t_diffuse, uv) : float4(1.0);
    float rm_ao = 1.0, rm_spec = 0.5, rm_rough = 0.1, rm_metal = 0.0;
    if (p.t_roughness != 0xffffffffu) {
        cooked_unpack_smr(mirai_sample_texture(ctx, p.t_roughness, uv), p.glass_params.w, rm_ao, rm_spec, rm_rough, rm_metal);
    }
    s.base_color = saturate(diff.rgb * p.glass_tint.rgb);
    s.alpha = saturate(p.glass_tint.a * diff.a);
    s.normal = cooked_normal_gl(ctx, p.t_normal, uv, p.glass_params.z);
    s.roughness = saturate(lerp(p.rough_params.x, p.rough_params.y, rm_rough));
    s.metallic = 0.0;
    s.specular_ior = max(p.glass_params.x, 1.0);
    s.specular_factor = 1.0;
    return s;
}
}
`)
    return strings.to_string(b)
}

@(private="file")
emit_skin_sss_slang :: proc(name:string,allocator:mem.Allocator) -> string {
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"//! mirai surface %s\n",name)
    strings.write_string(&b,`//! parameter t_diffuse {"kind":"texture","srgb":true,"normal":false}
//! parameter t_normal {"kind":"texture","srgb":false,"normal":true}
//! parameter t_smr {"kind":"texture","srgb":false,"normal":false}
//! parameter t_masks {"kind":"texture","srgb":false,"normal":false}
//! parameter base_tint {"default":[1,1,1,0]}
//! parameter sss_params {"default":[0.95,0.35,0.2,0.012]}
//! parameter skin_bounds {"default":[0.2,0.75,0.85,1]}
`)
    fmt.sbprintf(&b,"namespace %s {{\n",name)
    strings.write_string(&b,`struct Parameters {
    uint t_diffuse;
    uint t_normal;
    uint t_smr;
    uint t_masks;
    float4 base_tint;
    float4 sss_params;
    float4 skin_bounds;
};
`)
    strings.write_string(&b,NORMAL_HELPER)
    strings.write_string(&b,`Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    Mirai_Dual2 uv = mirai_uv0(ctx);
    float4 diff = p.t_diffuse != 0xffffffffu ? mirai_sample_texture(ctx, p.t_diffuse, uv) : float4(1.0);
    float smr_ao = 1.0, smr_spec = 0.5, smr_rough = 0.5, smr_metal = 0.0;
    if (p.t_smr != 0xffffffffu) {
        cooked_unpack_smr(mirai_sample_texture(ctx, p.t_smr, uv), p.base_tint.a, smr_ao, smr_spec, smr_rough, smr_metal);
    }
    float4 m = p.t_masks != 0xffffffffu ? mirai_sample_texture(ctx, p.t_masks, uv) : float4(1.0, 1.0, 1.0, 1.0);
    float ao = lerp(1.0, m.r * smr_ao, saturate(p.skin_bounds.w));
    float cavity = lerp(1.0, m.g, 0.5);
    s.base_color = saturate(diff.rgb * p.base_tint.rgb * cavity);
    s.normal = cooked_normal_gl(ctx, p.t_normal, uv, 1.0);
    s.roughness = saturate(lerp(p.skin_bounds.x, p.skin_bounds.y, smr_rough));
    s.metallic = saturate(smr_metal);
    s.occlusion = saturate(ao);
    cooked_apply_specular(s, smr_spec, cavity);
    s.subsurface_weight = saturate(p.skin_bounds.z * m.b);
    s.subsurface_color = saturate(p.sss_params.rgb);
    s.subsurface_radius = clamp(p.sss_params.a, 0.0, 0.1);
    return s;
}
}
`)
    return strings.to_string(b)
}

// ---- Helpers ------------------------------------------------------------------------

// Distinguishes ORM (R=AO, G=Roughness, B=Metallic) from Fortnite SpecularMasks
// (R=Specular, G=Metallic, B=Roughness, or SwizzleRoughnessToGreen: R=Specular, G=Roughness, B=Metallic).
@(private="file")
detect_smr_layout :: proc(m:^Cooked_Material) -> SMR_Layout {
    has_specular_masks:=false
    is_srm_name:=false
    for t in m.textures {
        low:=strings.to_lower(t.name,context.temp_allocator)
        if strings.contains(low,"specularmasks") || strings.contains(low,"specular_masks") || low=="smr" || strings.has_suffix(low,"_smr") {
            has_specular_masks=true
        }
        if low=="srm" || strings.has_suffix(low,"_srm") {
            has_specular_masks=true
            is_srm_name=true
        }
    }
    if !has_specular_masks {return .ORM}
    if sw,ok:=find_switch_any(m.switches,{"SwizzleRoughnessToGreen","bSwizzleRoughnessToGreen","RoughnessInGreen"});ok && sw {
        return .Fortnite_SRM_Green
    }
    if is_srm_name {return .Fortnite_SRM_Green}
    return .Fortnite_SMR
}

@(private="file")
archetype_program_name :: proc(prefix,mat_name:string,allocator:mem.Allocator) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,prefix)
    if mat_name!="" {
        strings.write_byte(&b,'_')
        for c in transmute([]u8)mat_name {
            ok:=(c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')
            strings.write_byte(&b,ok ? c : '_')
        }
    }
    text:=strings.to_string(b)
    max_len:=asset.MATERIAL_NAME_BYTES-1
    if len(text)>max_len {
        full:=strings.concatenate({prefix,":",mat_name},context.temp_allocator)
        h:=base.hash64(transmute([]u8)full)
        // 17 bytes reserved for "_" + 16 hex chars so truncated long names never collide.
        keep:=max(max_len-17,1)
        return fmt.aprintf("%s_%016x",text[:keep],h,allocator=allocator)
    }
    return strings.clone(text,allocator)
}

@(private="file")
clamp_rgb :: proc(c:[3]f32) -> [3]f32 {
    return {clamp(c.x,0,1),clamp(c.y,0,1),clamp(c.z,0,1)}
}

@(private="file")
short_enum_str :: proc(s:string) -> string {
    if i:=strings.last_index(s,"::");i>=0 {return s[i+2:]}
    return s
}

@(private="file")
find_scalar_any :: proc(list:[]Cooked_Scalar,names:[]string) -> (f32,bool) {
    for want in names {
        for s in list {if strings.equal_fold(s.name,want) {return s.value,true}}
    }
    return 0,false
}

@(private="file")
find_vec_any :: proc(list:[]Cooked_Vector,names:[]string) -> ([4]f32,bool) {
    for want in names {
        for v in list {if strings.equal_fold(v.name,want) {return v.value,true}}
    }
    return {},false
}

@(private="file")
has_vec_any :: proc(list:[]Cooked_Vector,names:[]string) -> bool {
    _,ok:=find_vec_any(list,names)
    return ok
}

@(private="file")
find_switch_any :: proc(list:[]Cooked_Switch,names:[]string) -> (bool,bool) {
    for want in names {
        for sw in list {if strings.equal_fold(sw.name,want) {return sw.value,true}}
    }
    return false,false
}

@(private="file")
has_switch_any :: proc(list:[]Cooked_Switch,names:[]string) -> bool {
    _,ok:=find_switch_any(list,names)
    return ok
}

@(private="file")
find_tex_any :: proc(list:[]Cooked_Texture,names:[]string) -> string {
    for want in names {
        for t in list {if strings.equal_fold(t.name,want) {return t.path}}
    }
    return ""
}

@(private="file")
has_layered_uv1_textures :: proc(list:[]Cooked_Texture) -> bool {
    for t in list {
        low:=strings.to_lower(t.name,context.temp_allocator)
        for suffix in ([]string{"_texture_2","_texture_3","_texture_4","_texture_5","_texture_6","_2","_3","_4","_5","_6"}) {
            if strings.has_suffix(low,suffix) && (strings.contains(low,"diffuse") || strings.contains(low,"normal") || strings.contains(low,"orm") || strings.contains(low,"texture")) {
                return true
            }
        }
    }
    return false
}

// Extracts up to 6 UV1 material layers (Diffuse/Normal/ORM) from *_Texture_2..6 / *_2..6.
@(private="file")
extract_uv1_layers :: proc(list:[]Cooked_Texture,base_diff,base_norm,base_orm:string) -> (diffs,norms,orms:[6]string,count:int) {
    diffs[0],norms[0],orms[0]=base_diff,base_norm,base_orm
    max_layer:=0
    for t in list {
        low:=strings.to_lower(t.name,context.temp_allocator)
        layer:=0
        for idx in 1..=6 {
            s1:=fmt.tprintf("_texture_%d",idx)
            s2:=fmt.tprintf("_%d",idx)
            if strings.has_suffix(low,s1) || strings.has_suffix(low,s2) {
                layer=idx-1
                break
            }
        }
        if layer>max_layer {max_layer=layer}
        switch {
        case strings.contains(low,"normal") || strings.contains(low,"norm"):
            if norms[layer]=="" {norms[layer]=t.path}
        case strings.contains(low,"orm") || strings.contains(low,"spec") || strings.contains(low,"rough") || strings.contains(low,"metal") || strings.contains(low,"mra"):
            if orms[layer]=="" {orms[layer]=t.path}
        case strings.contains(low,"diffuse") || strings.contains(low,"albedo") || strings.contains(low,"color") || strings.contains(low,"texture"):
            if diffs[layer]=="" {diffs[layer]=t.path}
        }
    }
    return diffs,norms,orms,max_layer+1
}
