package cooked

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:asset"

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
                "Scalars":{"Roughness":{"Value":0.45,"From":"MI_Skin"},"SubsurfaceOpacity":{"Value":0.8,"From":"MI_Skin"},"SubsurfaceRadius":{"Value":1.5,"From":"MI_Skin"}},
                "Vectors":{"BaseColor":{"Value":[0.8,0.6,0.5,1],"From":"MI_Skin"},"SubsurfaceColor":{"Value":[0.95,0.25,0.15,1],"From":"MI_Skin"}},
                "Textures":{"DiffuseMap":{"Value":"/Game/T_Skin_D.T_Skin_D","From":"MI_Skin"},"NormalMap":{"Value":"/Game/T_Skin_N.T_Skin_N","From":"MI_Skin"}}}`,
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
            testing.expectf(t,abs(cm.info.subsurface.weight-0.8)<1e-4,"sss weight %v",cm.info.subsurface.weight)
            testing.expectf(t,abs(cm.info.subsurface.radius-0.015)<1e-4,"sss radius %v",cm.info.subsurface.radius)
            testing.expectf(t,abs(cm.info.subsurface.color.x-0.95)<1e-4,"sss color %v",cm.info.subsurface.color)
            testing.expect_value(t,cm.texture_paths[.Base_Color],"/Game/T_Skin_D.T_Skin_D")
            testing.expect_value(t,cm.texture_paths[.Normal],"/Game/T_Skin_N.T_Skin_N")
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
