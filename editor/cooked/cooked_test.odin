package cooked

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "mirai:asset"
import shaders "mirai:cook/shaders"
import "mirai:std/base"

@(test)
cooked_material_builds_native_v6_subsurface_and_foliage :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)

    Case :: struct {
        json:string,
        alpha:asset.Alpha_Mode,
        unlit:bool,
        want_sss:bool,
        want_dt:bool,
    }
    cases:=[]Case{
        {
            json=`{"Name":"MI_Skin","BlendMode":"BLEND_Opaque","ShadingModel":"MSM_Subsurface","TwoSided":false,
                "Scalars":{"Roughness":{"Value":0.45,"From":"MI_Skin"},"SubsurfaceOpacity":{"Value":0.2,"From":"MI_Skin"},"SubsurfaceRadius":{"Value":1.5,"From":"MI_Skin"}},
                "Vectors":{"BaseColor":{"Value":[0.8,0.6,0.5,1],"From":"MI_Skin"},"SubsurfaceColor":{"Value":[0.95,0.25,0.15,1],"From":"MI_Skin"}},
                "Textures":{"DiffuseMap":{"Value":"/Game/T_Skin_D.T_Skin_D","From":"MI_Skin"},"NormalMap":{"Value":"/Game/T_Skin_N.T_Skin_N","From":"MI_Skin"},"SpecularMasks":{"Value":"/Game/T_Skin_S.T_Skin_S","From":"MI_Skin"}}}`,
            alpha=.Opaque,want_sss=true,
        },
        {
            json=`{"Name":"MI_Leaf","BlendMode":"BLEND_Masked","ShadingModel":"MSM_TwoSidedFoliage","TwoSided":true,"OpacityMaskClipValue":0.4,
                "Vectors":{"BaseColor":{"Value":[0.2,0.5,0.1,1],"From":"MI_Leaf"},"SubsurfaceColor":{"Value":[0.4,0.8,0.1,1],"From":"MI_Leaf"}},
                "Textures":{"BaseColor":{"Value":"/Game/T_Leaf_D.T_Leaf_D","From":"MI_Leaf"},"OpacityMask":{"Value":"/Game/T_Leaf_M.T_Leaf_M","From":"MI_Leaf"}}}`,
            alpha=.Mask,want_dt=true,
        },
        {
            json=`{"Name":"MI_Slash","BlendMode":"BLEND_Additive","ShadingModel":"MSM_Unlit","TwoSided":true,
                "Scalars":{"EmissiveIntensity":4.0},"Vectors":{"EmissiveColor":[0.2,0.7,1.0,1.0]}}`,
            alpha=.Additive,unlit=true,
        },
    }
    for tc in cases {
        cm,err:=cooked_material_parse(tc.json,alloc)
        _,bad:=err.?
        if !testing.expect(t,!bad) {continue}
        testing.expect_value(t,cm.info.alpha_mode,tc.alpha)
        testing.expect_value(t,cm.info.unlit,tc.unlit)
        if tc.want_sss {
            // UE MSM_Subsurface inverts Opacity: 1 - 0.2 = 0.8 scatter weight.
            testing.expectf(t,abs(cm.info.subsurface.weight-0.8)<1e-4,"sss weight %v",cm.info.subsurface.weight)
            testing.expectf(t,abs(cm.info.subsurface.radius-0.015)<1e-4,"sss radius %v",cm.info.subsurface.radius)
            testing.expectf(t,abs(cm.info.subsurface.color.x-0.95)<1e-4,"sss color %v",cm.info.subsurface.color)
            testing.expect_value(t,cm.texture_paths[.Base_Color],"/Game/T_Skin_D.T_Skin_D")
            testing.expect_value(t,cm.texture_paths[.Normal],"/Game/T_Skin_N.T_Skin_N")
            // SpecularMasks MUST classify as Metallic_Roughness (never Mask) with Fortnite_SMR layout.
            testing.expect_value(t,cm.texture_paths[.Metallic_Roughness],"/Game/T_Skin_S.T_Skin_S")
            testing.expect_value(t,cm.texture_paths[.Mask],"")
            testing.expect_value(t,cm.smr_layout,SMR_Layout.Fortnite_SMR)
        }
        if tc.want_dt {
            testing.expect(t,cm.info.diffuse_transmission.weight>0.5)
            testing.expect_value(t,cm.info.subsurface.weight,f32(0))
            testing.expect_value(t,cm.texture_paths[.Mask],"/Game/T_Leaf_M.T_Leaf_M")
        }
        // Round-trip as real Mirai .mat v6 bytes!
        raw,berr:=cooked_material_bytes(&cm,alloc)
        testing.expect_value(t,berr,asset.Error.None)
        testing.expect(t,len(raw)>0)
        types:asset.Types
        asset.types_init(&types)
        defer asset.types_destroy(&types)
        a:asset.Asset
        testing.expect_value(t,asset.asset_open(&a,raw),asset.Error.None)
        defer asset.asset_close(&a)
        view,verr:=asset.material_view(&a,&types)
        testing.expect_value(t,verr,asset.Error.None)
        testing.expect_value(t,view.info.alpha_mode,tc.alpha)
        testing.expect_value(t,view.info.subsurface.weight,cm.info.subsurface.weight)
        testing.expect_value(t,view.info.diffuse_transmission.weight,cm.info.diffuse_transmission.weight)
    }
}

@(test)
cooked_sockets_and_anim_events_convert_cleanly :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)

    // UE cm Z-up socket -> Mirai metres +Y up -Z forward: (100, 200, 50) cm -> (2.0, 0.5, -1.0) m.
    ue_json:=`{"Sockets":[{"SocketName":"WeaponTip","BoneName":"weapon_r","RelativeLocation":{"X":100,"Y":200,"Z":50},"RelativeRotation":{"Pitch":0,"Yaw":90,"Roll":0},"RelativeScale":{"X":1,"Y":2,"Z":3}}]}`
    socks,err:=cooked_sockets_parse(ue_json,alloc)
    _,bad:=err.?
    testing.expect(t,!bad && len(socks)==1)
    if len(socks)==1 {
        testing.expect_value(t,socks[0].name,"WeaponTip")
        testing.expect_value(t,socks[0].bone,"weapon_r")
        testing.expectf(t,math.abs(socks[0].position.x-2.0)<1e-5 && math.abs(socks[0].position.y-0.5)<1e-5 && math.abs(socks[0].position.z-(-1.0))<1e-5,"pos %v",socks[0].position)
        testing.expect_value(t,socks[0].scale,[3]f32{2,3,1})
    }

    // glTF node extras.socket preserves bone parent and right-handed metres.
    gltf_json:=`{"nodes":[{"name":"hand_r","children":[1]},{"name":"GripSocket","translation":[0.1,0.2,-0.3],"rotation":[0,0,0,1],"extras":{"socket":true}}]}`
    gsocks,gerr:=cooked_sockets_parse(gltf_json,alloc)
    _,gbad:=gerr.?
    testing.expect(t,!gbad && len(gsocks)==1)
    if len(gsocks)==1 {
        testing.expect_value(t,gsocks[0].name,"GripSocket")
        testing.expect_value(t,gsocks[0].bone,"hand_r")
        testing.expect_value(t,gsocks[0].position,[3]f32{0.1,0.2,-0.3})
    }

    // Cooked anim events JSON.
    ev_json:=`{"Name":"AM_Katana_Combo","SequenceLength":1.25,"RateScale":1.0,
        "Notifies":[{"Name":"SwingSFX","Class":"AnimNotify_PlaySound","Time":0.15}],
        "NotifyStates":[{"Name":"HitWindow","Class":"AnimNotifyState_Melee","Start":0.2,"End":0.55}],
        "SyncMarkers":[{"Name":"RightFootDown","Time":0.4}],
        "Sections":[{"Name":"Combo1","Start":0.0,"NextSectionName":"Combo2"}]}`
    ev,everr:=cooked_anim_events_parse(ev_json,alloc)
    _,ebad:=everr.?
    testing.expect(t,!ebad)
    testing.expect_value(t,ev.name,"AM_Katana_Combo")
    testing.expect_value(t,len(ev.notifies),2)
    if len(ev.notifies)==2 {
        testing.expect_value(t,ev.notifies[0].name,"SwingSFX")
        testing.expectf(t,math.abs(ev.notifies[1].duration-0.35)<1e-4,"dur %v",ev.notifies[1].duration)
    }
    testing.expect_value(t,len(ev.sync_markers),1)
    testing.expect_value(t,len(ev.sections),1)

    // Hostile JSON returns structured Error without crashing.
    _,herr:=cooked_material_parse("{broken",alloc)
    _,hbad:=herr.?
    testing.expect(t,hbad)
}

// Table-driven check across all 6 native Mirai cooked material archetype templates:
// verifies canonical sidecar parsing, .mat v6 round-trip, and real slangc compilation.
@(test)
cooked_material_six_archetypes_roundtrip_and_compile_slang :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)

    Case :: struct {
        label:string,
        json:string,
        want_arch:Material_Archetype,
        want_alpha:asset.Alpha_Mode,
        want_two_sided:bool,
        want_sss:bool,
        want_dt:bool,
        want_snippets:[]string,
    }
    cases:=[]Case{
        {
            label="standard_smr",
            json=`{"name":"MI_MetalProp","archetype":"standard","BlendMode":"BLEND_Opaque","ShadingModel":"MSM_DefaultLit",
                "parameters":{"RoughnessMin":0.2,"RoughnessMax":0.85,"Metallic":0.1,"SubsurfaceWeight":0.4,"BaseColor":[0.7,0.7,0.75,1]},
                "textures":{"Diffuse":"/Game/T_Prop_D.T_Prop_D","Normal":"/Game/T_Prop_N.T_Prop_N","SpecularMasks":"/Game/T_Prop_S.T_Prop_S","MasksTexture":"/Game/T_Prop_M.T_Prop_M"}}`,
            want_arch=.Standard_SMR,want_alpha=.Opaque,want_sss=true,
            want_snippets={"//! mirai surface Cooked_Standard_SMR","cooked_normal_gl","s.subsurface_weight","s.occlusion"},
        },
        {
            label="foliage_3color",
            json=`{"name":"MI_PineTree","archetype":"foliage","BlendMode":"BLEND_Masked","ShadingModel":"MSM_TwoSidedFoliage","TwoSided":true,"OpacityMaskClipValue":0.35,
                "parameters":{"Color1_Base":[0.18,0.42,0.1,1],"Color2_Lit":[0.35,0.65,0.15,1],"Color3_Shadows":[0.08,0.2,0.05,1],
                    "FlowerColorMult":[0.95,0.4,0.6,1],"IsFlowers":true,"RoughnessMin":0.3,"RoughnessMax":0.8},
                "textures":{"Diffuse":"/Game/T_Leaf_D.T_Leaf_D","Normal":"/Game/T_Leaf_N.T_Leaf_N","MasksTexture":"/Game/T_Leaf_M.T_Leaf_M"}}`,
            want_arch=.Foliage_3Color,want_alpha=.Mask,want_two_sided=true,want_dt=true,
            want_snippets={"//! mirai surface Cooked_Foliage_3Color","masks.b * 2.0","flower_color_mult","s.diffuse_transmission_color"},
        },
        {
            label="layered_uv1",
            json=`{"name":"MI_Building_Brick","archetype":"layered","BlendMode":"BLEND_Opaque","ShadingModel":"MSM_DefaultLit",
                "parameters":{"Tiling":2.0,"RoughnessMin":0.3,"RoughnessMax":0.9},
                "textures":{"Diffuse":"/Game/T_L1_D.T_L1_D","Diffuse_Texture_2":"/Game/T_L2_D.T_L2_D","Diffuse_Texture_3":"/Game/T_L3_D.T_L3_D",
                    "Normal_Texture_2":"/Game/T_L2_N.T_L2_N","ORM_Texture_6":"/Game/T_L6_ORM.T_L6_ORM"}}`,
            want_arch=.Layered_UV1,want_alpha=.Opaque,
            want_snippets={"//! mirai surface Cooked_Layered_UV1","ctx.uv1.x","t_diff_5","t_orm_5"},
        },
        {
            label="toon",
            json=`{"name":"MI_Hero_Toon","archetype":"toon","BlendMode":"BLEND_Opaque","ShadingModel":"MSM_DefaultLit",
                "parameters":{"BaseColor":[0.9,0.25,0.2,1],"ShadowColor":[0.3,0.15,0.25,1],"ToonSteps":4,"SpecThreshold":0.7},
                "textures":{"Diffuse":"/Game/T_Toon_D.T_Toon_D","Normal":"/Game/T_Toon_N.T_Toon_N"}}`,
            want_arch=.Toon,want_alpha=.Opaque,
            want_snippets={"//! mirai surface Cooked_Toon","spec_band","shadow_tint","floor(shade * steps"},
        },
        {
            label="glass",
            json=`{"name":"MI_Window_Glass","archetype":"glass","BlendMode":"BLEND_Translucent","ShadingModel":"MSM_ThinTranslucent",
                "parameters":{"BaseColor":[0.85,0.95,1.0,1],"Opacity":0.3,"IOR":1.52,"FresnelExponent":4.0},
                "textures":{"Normal":"/Game/T_Glass_N.T_Glass_N"}}`,
            want_arch=.Glass,want_alpha=.Blend,
            want_snippets={"//! mirai surface Cooked_Glass","glass_params","s.specular_ior"},
        },
        {
            label="skin_sss",
            json=`{"name":"MI_Char_Skin","archetype":"skin","BlendMode":"BLEND_Opaque","ShadingModel":"MSM_SubsurfaceProfile",
                "parameters":{"BaseColor":[0.85,0.62,0.5,1],"SubsurfaceColor":[0.95,0.3,0.18,1],"SubsurfaceOpacity":0.9,"SubsurfaceRadius":1.2,"RoughnessMin":0.25,"RoughnessMax":0.7},
                "textures":{"Diffuse":"/Game/T_Skin_D.T_Skin_D","Normal":"/Game/T_Skin_N.T_Skin_N","SpecularMasks":"/Game/T_Skin_S.T_Skin_S","MasksTexture":"/Game/T_Skin_M.T_Skin_M"}}`,
            want_arch=.Skin_SSS,want_alpha=.Opaque,want_sss=true,
            want_snippets={"//! mirai surface Cooked_Skin_SSS","s.subsurface_weight = saturate(p.skin_bounds.z * m.b)","s.subsurface_radius"},
        },
    }

    folder:=".mirai/tmp/cooked-archetypes-test"
    _=os.make_directory_all(folder)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)

    for tc in cases {
        cm,err:=cooked_material_parse(tc.json,alloc)
        _,bad:=err.?
        if !testing.expectf(t,!bad,"%s parse failed: %v",tc.label,err) {continue}
        testing.expect_value(t,cm.archetype,tc.want_arch)
        testing.expect_value(t,cm.info.alpha_mode,tc.want_alpha)
        testing.expect_value(t,cm.info.two_sided,tc.want_two_sided)
        if tc.want_sss {testing.expectf(t,cm.info.subsurface.weight>0,"%s expected subsurface weight > 0",tc.label)}
        if tc.want_dt {testing.expectf(t,cm.info.diffuse_transmission.weight>0,"%s expected diffuse transmission > 0",tc.label)}
        for snip in tc.want_snippets {
            testing.expectf(t,strings.contains(cm.program_source,snip),"%s missing %q in Slang:\n%s",tc.label,snip,cm.program_source)
        }
        // Round-trip .mat v6 bytes (including program_parameters).
        raw,berr:=cooked_material_bytes(&cm,alloc)
        testing.expect_value(t,berr,asset.Error.None)
        types:asset.Types
        asset.types_init(&types)
        a:asset.Asset
        testing.expect_value(t,asset.asset_open(&a,raw),asset.Error.None)
        view,verr:=asset.material_view(&a,&types)
        testing.expect_value(t,verr,asset.Error.None)
        testing.expect_value(t,len(view.parameters),len(cm.program_parameters))
        asset.asset_close(&a)
        asset.types_destroy(&types)
        // Verify Slang compiles cleanly with Mirai's shader checker / slangc (must actually run).
        if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
            shader_path,_:=filepath.join({folder,fmt.tprintf("%s.slang",cm.program_name)},context.temp_allocator)
            _=os.write_entire_file(shader_path,transmute([]u8)cm.program_source)
            res:=shaders.program_check({root=root,project=folder,path=shader_path},context.temp_allocator)
            testing.expectf(t,res.error=="" && res.errors==0 && res.compiled,"%s Slang compile failed: %s %v",tc.label,res.error,res.diagnostics)
        }
    }
}

// Verifies SpecularMasks vs ORM packing detection, no blind SSS on Standard_SMR,
// strict mutual exclusivity between subsurface and diffuse_transmission,
// collision-free <= 63-byte program names, active texture binding, nearest-later
// marker pairing, and zero memory leaks under Odin's default tracking allocator.
@(test)
cooked_review_invariants_and_zero_leaks :: proc(t:^testing.T) {
    // 1. Standard_SMR with MasksTexture + SpecularMasks (SwizzleRoughnessToGreen) must NOT blindly enable SSS,
    //    and opaque PBR MasksTexture binds to program t_masks rather than alpha-cutout maps.mask.
    std_json:=`{"name":"MI_Rock","BlendMode":"BLEND_Opaque","ShadingModel":"MSM_DefaultLit",
        "StaticSwitches":{"SwizzleRoughnessToGreen":true},
        "textures":{"Diffuse":"/Game/T_Rock_D","SpecularMasks":"/Game/T_Rock_S","MasksTexture":"/Game/T_Rock_M"}}`
    cm,err:=cooked_material_parse(std_json)
    defer cooked_material_destroy(&cm)
    _,bad:=err.?
    testing.expect(t,!bad)
    testing.expect_value(t,cm.archetype,Material_Archetype.Standard_SMR)
    testing.expect_value(t,cm.info.subsurface.weight,f32(0))
    testing.expect_value(t,cm.smr_layout,SMR_Layout.Fortnite_SRM_Green)
    testing.expect_value(t,cm.texture_paths[.Metallic_Roughness],"/Game/T_Rock_S")
    testing.expect_value(t,cm.texture_paths[.Mask],"")
    testing.expect(t,strings.contains(cm.program_source,"cooked_unpack_smr("))

    // Word-boundary token matching: "T_Uniform_D", "T_Storm_D", "T_Transform_D" must stay Base_Color, never ORM.
    for uname in ([]string{"T_Uniform_D","T_Storm_D","T_Transform_D"}) {
        kind,matched:=classify_texture_slot(uname)
        testing.expectf(t,matched && kind==.Base_Color,"%s misclassified as %v",uname,kind)
    }
    orm_kind,orm_ok:=classify_texture_slot("T_Prop_ORM")
    testing.expect(t,orm_ok && orm_kind==.Metallic_Roughness)

    // Foliage MasksTexture records mask_alpha_channel=0 (R->A swizzle note) and omits dead s.alpha = masks.r / fake backface hack.
    fol_json:=`{"name":"MI_Foliage_Test","archetype":"foliage","BlendMode":"BLEND_Masked","ShadingModel":"MSM_TwoSidedFoliage",
        "textures":{"Diffuse":"/Game/T_Leaf_D","MasksTexture":"/Game/T_Leaf_M"}}`
    cm_fol,fol_err:=cooked_material_parse(fol_json)
    defer cooked_material_destroy(&cm_fol)
    testing.expect(t,fol_err==nil)
    testing.expect_value(t,cm_fol.mask_alpha_channel,u8(0))
    testing.expect(t,len(cm_fol.notes)>0)
    testing.expect(t,!strings.contains(cm_fol.program_source,"s.alpha = masks.r"))
    testing.expect(t,!strings.contains(cm_fol.program_source,"dot(ctx.normal, ctx.vertex_normal)"))

    // Toon & Glass emit honest notes without fake dot(n, vertex_normal) view hacks or 0.15 emission.
    glass_json:=`{"name":"MI_CleanGlass","archetype":"glass","parameters":{"IOR":1.52,"FresnelExponent":4.0}}`
    cm_glass,g_err:=cooked_material_parse(glass_json)
    defer cooked_material_destroy(&cm_glass)
    testing.expect(t,g_err==nil && len(cm_glass.notes)>0)
    testing.expect(t,!strings.contains(cm_glass.program_source,"dot(n, normalize(ctx.vertex_normal))"))
    testing.expect(t,!strings.contains(cm_glass.program_source,"s.emission"))

    toon_json:=`{"name":"MI_CleanToon","archetype":"toon"}`
    cm_toon,t_err:=cooked_material_parse(toon_json)
    defer cooked_material_destroy(&cm_toon)
    testing.expect(t,t_err==nil && len(cm_toon.notes)>0)
    testing.expect(t,!strings.contains(cm_toon.program_source,"dot(n, normalize(ctx.vertex_normal))"))
    testing.expect(t,!strings.contains(cm_toon.program_source,"s.emission"))

    // Bind textures into both Material_Info.maps and program_parameters and round-trip .mat v6.
    resolver :: proc(path:string,user:rawptr) -> base.Asset_Id {
        return {base.hash64(transmute([]u8)path)|1,1}
    }
    cooked_material_bind_textures(&cm,resolver)
    testing.expect(t,cm.info.maps.base_color.texture!={})
    testing.expect(t,cm.info.maps.metallic_roughness.texture!={})
    bound_params:=0
    for p in cm.program_parameters {if p.kind==.Texture && p.texture!={} {bound_params+=1}}
    testing.expect_value(t,bound_params,3)
    raw,berr:=cooked_material_bytes(&cm)
    defer delete(raw)
    testing.expect_value(t,berr,asset.Error.None)

    // 2. Mutual exclusivity: conflicting ShadingModel + archetype override still passes asset.material_check.
    conflict_fol:=`{"name":"MI_Conflict_Fol","archetype":"foliage","ShadingModel":"MSM_Subsurface",
        "Scalars":{"SubsurfaceOpacity":0.2},"Vectors":{"SubsurfaceColor":[0.9,0.2,0.1,1]}}`
    cf,ferr:=cooked_material_parse(conflict_fol)
    defer cooked_material_destroy(&cf)
    testing.expect(t,ferr==nil)
    testing.expect_value(t,cf.info.subsurface.weight,f32(0))
    testing.expect(t,cf.info.diffuse_transmission.weight>0)
    fraw,fberr:=cooked_material_bytes(&cf)
    defer delete(fraw)
    testing.expect_value(t,fberr,asset.Error.None)

    conflict_skin:=`{"name":"MI_Conflict_Skin","archetype":"skin","ShadingModel":"MSM_TwoSidedFoliage",
        "Vectors":{"SubsurfaceColor":[2.5,0.4,-0.2,1]}}`
    cs,serr:=cooked_material_parse(conflict_skin)
    defer cooked_material_destroy(&cs)
    testing.expect(t,serr==nil)
    testing.expect_value(t,cs.info.diffuse_transmission.weight,f32(0))
    testing.expect(t,cs.info.subsurface.weight>0)
    // Clamped SSS color in both Material_Info and sss_params.
    testing.expect(t,cs.info.subsurface.color.x<=1 && cs.info.subsurface.color.z>=0)
    for &p in cs.program_parameters {
        if base.text_get(p.name[:])=="sss_params" {
            testing.expect(t,p.value[0]<=1 && p.value[2]>=0)
        }
    }
    sraw,sberr:=cooked_material_bytes(&cs)
    defer delete(sraw)
    testing.expect_value(t,sberr,asset.Error.None)

    // 3. Long program names stay <= 63 bytes, match info.program verbatim, and never collide.
    long_a:=`{"name":"MI_VeryLongFortniteMaterialAssetNameThatExceedsMiraiSixtyFourByteLimit_VariantA"}`
    long_b:=`{"name":"MI_VeryLongFortniteMaterialAssetNameThatExceedsMiraiSixtyFourByteLimit_VariantB"}`
    ca,_:=cooked_material_parse(long_a)
    defer cooked_material_destroy(&ca)
    cb,_:=cooked_material_parse(long_b)
    defer cooked_material_destroy(&cb)
    testing.expect(t,len(ca.program_name)<=asset.MATERIAL_NAME_BYTES-1)
    testing.expect(t,len(cb.program_name)<=asset.MATERIAL_NAME_BYTES-1)
    testing.expect(t,ca.program_name!=cb.program_name)
    testing.expect_value(t,base.text_get(ca.info.program[:]),ca.program_name)
    testing.expect_value(t,base.text_get(cb.info.program[:]),cb.program_name)

    // 4. Sockets & anim events destroy cleanly with 0 leaks + unsorted multi-pair markers pair with nearest later end.
    socks,_:=cooked_sockets_parse(`{"Sockets":[{"SocketName":"Tip","BoneName":"hand_r","RelativeLocation":{"X":10,"Y":0,"Z":0}}]}`)
    defer cooked_sockets_destroy(socks)
    testing.expect_value(t,len(socks),1)

    ev,_:=cooked_anim_events_parse(`{"Name":"AM_Combo","SequenceLength":2.0,"Notifies":[
        {"Name":"Trail_Off","Time":1.20},
        {"Name":"Trail_On","Time":0.10},
        {"Name":"Trail_On","Time":0.80},
        {"Name":"Trail_Off","Time":0.40}
    ],"SyncMarkers":[{"Name":"Step","Time":0.5}]}`)
    defer cooked_anim_events_destroy(&ev)
    markers:=cooked_anim_markers(&ev)
    defer cooked_anim_markers_destroy(markers)
    tl:=cooked_anim_timeline_events(&ev)
    defer cooked_anim_timeline_events_destroy(tl)
    paired:=cooked_anim_paired_spans(&ev)
    defer cooked_anim_paired_spans_destroy(paired)
    if testing.expect_value(t,len(paired),2) {
        testing.expectf(t,math.abs(paired[0].start_time-0.10)<1e-4 && math.abs(paired[0].end_time-0.40)<1e-4,"pair0 %v",paired[0])
        testing.expectf(t,math.abs(paired[1].start_time-0.80)<1e-4 && math.abs(paired[1].end_time-1.20)<1e-4,"pair1 %v",paired[1])
    }
}

// Verifies animation events emit Mirai Animation_Marker_Desc spans (.Span_Begin/.Span_End)
// and paired point marker spans compatible with vfx_animation.Particle_Animation_Span
// and abilities.Ability_Window.span.
@(test)
cooked_anim_events_emit_mirai_spans_and_paired_markers :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)

    ev_json:=`{"Name":"AM_Katana_Slash","SequenceLength":1.2,"RateScale":1.0,
        "Notifies":[
            {"Name":"FortMeleeAnimTrails_On","Class":"AnimNotify_Trail","Time":0.12},
            {"Name":"SwingSFX","Class":"AnimNotify_PlaySound","Time":0.15},
            {"Name":"FortMeleeAnimTrails_Off","Class":"AnimNotify_Trail","Time":0.42}
        ],
        "NotifyStates":[
            {"Name":"MeleeHitWindow","Class":"AnimNotifyState_Melee","Start":0.18,"End":0.40}
        ],
        "SyncMarkers":[{"Name":"FootPlant","Time":0.30}],
        "Sections":[{"Name":"Slash1","Start":0.0},{"Name":"Recovery","Start":0.55}]}`

    ev,err:=cooked_anim_events_parse(ev_json,alloc)
    _,bad:=err.?
    if !testing.expect(t,!bad) {return}

    // Native Mirai Animation_Marker_Desc (duration > 0 -> .Span_Begin/.Span_End).
    markers:=cooked_anim_markers(&ev,alloc)
    testing.expect_value(t,len(markers),7)
    found_hit:=false
    for m in markers {
        if m.name=="MeleeHitWindow" {
            found_hit=true
            testing.expectf(t,math.abs(m.time-0.18)<1e-4 && math.abs(m.duration-0.22)<1e-4,"hit window %v",m)
        }
    }
    testing.expect(t,found_hit)

    // Timeline expansion (.Span_Begin / .Span_End + .Marker).
    tl:=cooked_anim_timeline_events(&ev,alloc)
    testing.expect_value(t,len(tl),6)
    begins,ends,points:=0,0,0
    for e in tl {
        switch e.kind {
        case .Span_Begin: begins+=1
        case .Span_End: ends+=1
        case .Marker: points+=1
        }
    }
    testing.expect(t,begins==1 && ends==1 && points==4)

    // Paired point markers for Particle_Animation_Span (span + end_marker).
    paired:=cooked_anim_paired_spans(&ev,alloc)
    if testing.expect_value(t,len(paired),1) {
        testing.expect_value(t,paired[0].base_name,"FortMeleeAnimTrails")
        testing.expect_value(t,paired[0].start_marker,"FortMeleeAnimTrails_On")
        testing.expect_value(t,paired[0].end_marker,"FortMeleeAnimTrails_Off")
        testing.expectf(t,math.abs(paired[0].start_time-0.12)<1e-4 && math.abs(paired[0].end_time-0.42)<1e-4,"paired times %v",paired[0])
    }
}

// A master shared by many materials declares parameters this one never set: only what the
// instance chain sets (Overridden, or its own name as the origin) gives a tint, an emission or
// a texture, and a trunk of the tree master takes its Trunk_ textures.
@(test)
cooked_material_takes_only_what_the_instance_sets :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)
    blade,err:=cooked_material_parse(`{"Name":"MI_Blade","BlendMode":"BLEND_Opaque","ShadingModel":"MSM_DefaultLit",
        "Scalars":{"emissive mult":{"Value":5.0,"From":"MI_Blade","Overridden":true},"Roughness":{"Value":0.1,"From":"M_Master"}},
        "Vectors":{"Tint":{"Value":[0,3.8,6,1],"From":"M_Master"},"Emissive Color":{"Value":[1.5,1.5,1.5,1],"From":"MI_Blade","Overridden":true}},
        "Textures":{"Diffuse":{"Value":"/Game/T_Blade_D.T_Blade_D","From":"MI_Blade","Overridden":true},"Detail_Diffuse":{"Value":"/Game/T_Detail_D.T_Detail_D","From":"M_Master"}},
        "Evaluated":{"BaseColorTint":{"R":0,"G":3.8,"B":6,"A":1,"Source":"Tint"}}}`,alloc)
    _,bad:=err.?
    if !testing.expect(t,!bad) {return}
    testing.expect_value(t,blade.info.base_color,[3]f32{1,1,1})
    testing.expect_value(t,blade.info.emission,[3]f32{7.5,7.5,7.5})
    testing.expect_value(t,blade.info.roughness,asset.MATERIAL_DEFAULTS.roughness)
    testing.expect_value(t,blade.texture_paths[.Base_Color],"/Game/T_Blade_D.T_Blade_D")

    off,off_err:=cooked_material_parse(`{"Name":"MI_Body","BlendMode":"BLEND_Opaque","ShadingModel":"MSM_DefaultLit",
        "StaticSwitches":{"Emissive":{"Value":false,"From":"M_Master"}},
        "Vectors":{"EmissiveColor":{"Value":[0,0.79,1,1],"From":"MI_Body","Overridden":true}}}`,alloc)
    _,bad=off_err.?
    if !testing.expect(t,!bad) {return}
    testing.expect_value(t,off.info.emission,[3]f32{0,0,0})

    trunk,trunk_err:=cooked_material_parse(`{"Name":"MI_Trunk","BlendMode":"BLEND_Opaque","ShadingModel":"MSM_DefaultLit",
        "StaticSwitches":{"IsTrunk":{"Value":true,"From":"MI_Trunk","Overridden":true}},
        "Textures":{"Diffuse":{"Value":"/Game/T_Leaf_D.T_Leaf_D","From":"MI_Leaves","Overridden":true},
            "Trunk_BaseColor":{"Value":"/Game/T_Bark_D.T_Bark_D","From":"MI_Trunk","Overridden":true},
            "Trunk_Normal":{"Value":"/Game/T_Bark_N.T_Bark_N","From":"MI_Trunk","Overridden":true}}}`,alloc)
    _,bad=trunk_err.?
    if !testing.expect(t,!bad) {return}
    testing.expect_value(t,trunk.texture_paths[.Base_Color],"/Game/T_Bark_D.T_Bark_D")
    testing.expect_value(t,trunk.texture_paths[.Normal],"/Game/T_Bark_N.T_Bark_N")
}
