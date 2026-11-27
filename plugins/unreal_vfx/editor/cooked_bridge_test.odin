package unreal_vfx_editor

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import shaders "mirai:cook/shaders"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

// Whether a Vfx program compiles, where the tools that compile it are.
@(private="file")
program_compiles :: proc(t:^testing.T,name,source:string) {
    folder:=".mirai/tmp/cooked-vfx-test"
    _=os.make_directory_all(folder)
    shader_path,_:=filepath.join({folder,strings.concatenate({name,".slang"},context.temp_allocator)},context.temp_allocator)
    _=os.write_entire_file(shader_path,transmute([]u8)source)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)
    if !testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {return}
    vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
    sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
    res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
    testing.expectf(t,res.error=="" && res.errors==0,"%s does not compile: %s %v",name,res.error,res.diagnostics)
    if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"%s: its stages did not compile: %v",name,res.diagnostics)}
}

// An emitter gives a layer for each renderer that is on, drawn by what that renderer binds:
// its own colour and size, its material, its mesh, and the vertex factory of its kind.
@(test)
cooked_niagara_bridge_gives_a_layer_for_each_renderer :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)

    doc:=`{
  "Schema": "ue5parse.niagara/2",
  "Name": "NS_Slash",
  "Package": "/Game/FX/NS_Slash",
  "Kind": "NiagaraSystem",
  "UserParameters": [{"Name": "User.Scale", "Type": "NiagaraFloat", "Value": 1.5}],
  "Materials": [
    {"Path": "/Game/FX/MI_Slash.MI_Slash", "Name": "MI_Slash", "BlendMode": "BLEND_Additive", "ShadingModel": "MSM_Unlit", "TwoSided": true,
     "Vectors": {"EmissiveColor": {"Value": [0.3, 0.8, 1.0, 1.0], "From": "MI_Slash"}}}
  ],
  "Emitters": [
    {
      "Name": "Arc",
      "Enabled": true,
      "Target": "CPU",
      "Settings": {"bLocalSpace": true, "PreAllocationCount": 64},
      "Scripts": [
        {"Usage": "ParticleSpawnScript", "Target": "CPU", "Outputs": [
          {"Attribute": "Lifetime", "Value": {"Literal": 0.35}},
          {"Attribute": "SpriteSize", "Components": {"x": {"Literal": 120.0}, "y": {"Literal": 60.0}}},
          {"Attribute": "GlowSize", "Components": {"x": {"Literal": 300.0}, "y": {"Literal": 300.0}}},
          {"Attribute": "Scale", "Components": {"x": {"Literal": 2.0}, "y": {"Literal": 2.0}, "z": {"Literal": 2.0}}},
          {"Attribute": "RibbonWidth", "Value": {"Literal": 25.0}},
          {"Attribute": "Color", "Components": {"x": {"Literal": 0.4}, "y": {"Literal": 0.9}, "z": {"Literal": 1.0}, "w": {"Literal": 1.0}}},
          {"Attribute": "Glow", "Components": {"x": {"Literal": 4.0}, "y": {"Literal": 0.0}, "z": {"Literal": 4.0}, "w": {"Literal": 0.5}}},
          {"Attribute": "Position", "Components": {"x": {"Literal": 50.0}, "y": {"Literal": 0.0}, "z": {"Literal": 100.0}}},
          {"Attribute": "Shown", "Components": {"x": {"Literal": 0.0}, "y": {"Literal": 0.0}, "z": {"Literal": 10.0}}},
          {"Attribute": "DynamicMaterialParameter", "Components": {"x": {"Parameter": "User.Scale", "Source": "User", "Value": 1.5, "Type": "float"}}}
        ]},
        {"Usage": "ParticleUpdateScript", "Target": "CPU",
         "Outputs": [{"Attribute": "Age", "Value": {"Op": "add", "Args": [{"Attribute": "Age", "DataSet": 0}, {"Parameter": "Engine.DeltaTime", "Source": "Engine"}]}}],
         "KeepConditions": [{"Op": "cmplt", "Args": [{"Attribute": "Age", "DataSet": 0}, {"Attribute": "Lifetime", "DataSet": 0}]}]}
      ],
      "Renderers": [
        {"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties", "Enabled": true,
         "Materials": [{"Slot": 0, "From": "Material", "Material": "/Game/FX/MI_Slash.MI_Slash"}],
         "Settings": {"Alignment": "ENiagaraSpriteAlignment::VelocityAligned", "FacingMode": "ENiagaraSpriteFacingMode::FaceCamera", "SubImageSize": {"X": 2.0, "Y": 2.0},
                      "PivotInUVSpace": {"X": 0.5, "Y": 1.0}, "SortOrderHint": 3},
         "Bindings": {"PositionBinding": "Particles.Position", "ColorBinding": "Particles.Color", "SpriteSizeBinding": "Particles.SpriteSize"}},
        {"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties", "Enabled": true,
         "Materials": [{"Slot": 0, "From": "Material", "Material": "/Game/FX/MI_Glow.MI_Glow"}],
         "Settings": {"Alignment": "ENiagaraSpriteAlignment::Unaligned", "FacingMode": "ENiagaraSpriteFacingMode::FaceCamera"},
         "Bindings": {"PositionBinding": "Particles.Shown", "ColorBinding": "Particles.Glow", "SpriteSizeBinding": "Particles.GlowSize"}},
        {"Kind": "mesh", "Class": "NiagaraMeshRendererProperties", "Enabled": true,
         "Materials": [{"Slot": 0, "From": "OverrideMaterials", "Material": "/Game/FX/MI_Slash.MI_Slash"}],
         "Meshes": [{"Mesh": "/Game/FX/SM_Arc.SM_Arc", "Scale": {"X": 1.0, "Y": 2.0, "Z": 0.5}, "Rotation": {"Pitch": 90.0, "Yaw": 0.0, "Roll": 0.0}, "PivotOffset": {"X": 0.0, "Y": 0.0, "Z": 0.0}}],
         "Settings": {"FacingMode": "ENiagaraMeshFacingMode::CameraPosition"},
         "Bindings": {"ScaleBinding": "Particles.Scale"}},
        {"Kind": "ribbon", "Class": "NiagaraRibbonRendererProperties", "Enabled": true,
         "Settings": {"FacingMode": "ENiagaraRibbonFacingMode::Screen", "UV0Settings": {"DistributionMode": "ENiagaraRibbonUVDistributionMode::TiledOverRibbonLength", "TilingLength": 200.0}},
         "Bindings": {"RibbonWidthBinding": "Particles.RibbonWidth"}},
        {"Kind": "light", "Class": "NiagaraLightRendererProperties", "Enabled": true,
         "Settings": {"bUseInverseSquaredFalloff": false, "RadiusScale": 2.0, "DefaultExponent": 1.0, "ColorAdd": {"X": 1.0, "Y": 0.5, "Z": 0.25}}},
        {"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties", "Enabled": false},
        {"Kind": "decal", "Class": "NiagaraDecalRendererProperties", "Enabled": true}
      ]
    }
  ]
}`
    sys,err:=cooked_niagara_build(doc,alloc)
    _,bad:=err.?
    if !testing.expect(t,!bad) || !testing.expect_value(t,len(sys.emitters),1) {return}
    em:=sys.emitters[0]
    testing.expect_value(t,em.name,"Arc")
    testing.expect_value(t,len(em.warnings),1) // the decal renderer
    if !testing.expect_value(t,len(em.layers),5) {return}

    sprite:=em.layers[0]
    testing.expect_value(t,sprite.factory,"NiagaraSpriteVF")
    testing.expect_value(t,sprite.material_path,"/Game/FX/MI_Slash.MI_Slash")
    testing.expect_value(t,sprite.info.render,effect.Particle_Render.Velocity)
    testing.expect_value(t,sprite.info.blend,effect.Particle_Blend.Additive)
    testing.expect_value(t,sprite.info.flipbook,[2]u32{2,2})
    testing.expect_value(t,sprite.info.max_particles,u32(64))
    testing.expect_value(t,sprite.order,i32(3))
    testing.expect(t,sprite.info.local_space && !sprite.info.lit && sprite.info.rate==0)
    testing.expect_value(t,len(sprite.notes),0)
    testing.expect_value(t,base.text_get(sprite.info.program[:]),"Cooked_NS_Slash_Arc")
    testing.expect(t,strings.contains(sprite.program_source,"visual.data[0]"))
    held:=false
    for limit in sprite.limits {held|=strings.contains(limit,"held at")}
    testing.expect(t,held) // a pivot at the end of the sprite is not shown

    // The second sprite renderer draws other attributes of the same particles.
    glow:=em.layers[1]
    testing.expect_value(t,glow.info.render,effect.Particle_Render.Billboard)
    testing.expect_value(t,base.text_get(glow.info.program[:]),"Cooked_NS_Slash_Arc_1")
    testing.expect(t,strings.contains(glow.program_source,"a.f_Glow_x") && strings.contains(glow.program_source,"a.f_GlowSize_x"))
    testing.expect(t,strings.contains(glow.program_source,"a.f_Shown_x"))
    testing.expect(t,!strings.contains(sprite.program_source,"visual.color = float4(max(float3(fv(a.f_Glow_x)"))

    mesh:=em.layers[2]
    testing.expect_value(t,mesh.factory,"NiagaraMeshVF")
    testing.expect_value(t,mesh.info.render,effect.Particle_Render.Mesh)
    testing.expect_value(t,mesh.info.facing,effect.Particle_Facing.Emitter)
    if testing.expect_value(t,len(mesh.mesh_paths),1) {testing.expect_value(t,mesh.mesh_paths[0],"/Game/FX/SM_Arc.SM_Arc")}
    testing.expect(t,mesh.info.scale!=[3]f32{1,1,1})
    // It faces the eye, turned as its renderer turns the mesh, each side its own share of its size.
    testing.expect(t,strings.contains(mesh.program_source,"float3 dir = normalize(nv_place_back(ctx, mirai_vfx_view().position, NV_LOCAL) - at);"))
    testing.expect(t,strings.contains(mesh.program_source,"visual.orientation = ")&&strings.contains(mesh.program_source,"visual.scale = sides / largest;"))
    testing.expect(t,strings.contains(sprite.program_source,"visual.scale = float3(sides / largest, 1.0);"))

    ribbon:=em.layers[3]
    testing.expect_value(t,ribbon.factory,"NiagaraRibbonVF")
    testing.expect_value(t,ribbon.info.render,effect.Particle_Render.Ribbon)
    testing.expectf(t,abs(ribbon.info.ribbon_tile-2)<1e-4,"tile %v",ribbon.info.ribbon_tile)

    light:=em.layers[4]
    testing.expect_value(t,light.factory,"")
    testing.expect(t,light.info.light.intensity>0 && abs(light.info.light.range-2)<1e-4)
    testing.expect(t,strings.contains(light.program_source,"visual.size = 0.0"))

    for layer in em.layers {
        if layer.program_name!="" {program_compiles(t,layer.program_name,layer.program_source)}
    }
}

// What a document that is no system, or a broken one, gives: an error or nothing, never a crash.
@(test)
cooked_niagara_bridge_survives_hostile_documents :: proc(t:^testing.T) {
    for doc in ([]string{
        ``,`[]`,`{`,`{"Schema": "other/1"}`,`{"Emitters": 3}`,`{"Emitters": [3, null, {"Renderers": 7}]}`,
        `{"Emitters": [{"Name": 5, "Renderers": [null, 1, {"Kind": 9}, {"Kind": "mesh", "Meshes": [1, {"Mesh": 2}], "Settings": 4, "Materials": [1, {}]}]}]}`,
        `{"Emitters": [{"Renderers": [{"Kind": "sprite", "Settings": {"SubImageSize": {"X": 1e30, "Y": -5}, "SortOrderHint": 1e30, "PivotInUVSpace": {"X": "a"}}, "Bindings": {"ColorBinding": 7, "PositionBinding": ""}}], "Scripts": [{"Usage": "ParticleSpawnScript", "Outputs": [{"Attribute": "Color"}]}]}]}`,
    }) {
        sys,err:=cooked_niagara_build(doc)
        _=err
        cooked_vfx_system_destroy(&sys)
    }
}

// UE6's simple-light calibration: intensity * effective colour, for colours above and below 1,
// from the particle and from the renderer.
@(test)
niagara_light_matches_the_simple_light_of_unreal :: proc(t:^testing.T) {
    // Table-driven UE6 simple-light calibration: assert exact intensity * effective_color
    // across HDR (>1) and dim (<1) colors for BOTH particle-color and explicit-color lights.
    Light_Case :: struct {
        label:string,
        params:Niagara_Light_Params,
        particle_rgb:[3]f32, // effective color Mirai uses when light.color == {0,0,0}
        want_zero_color:bool,
        want_eff:[3]f32,     // expected light.intensity * effective_color (cd)
    }
    // Windowed factor for radius_scale=4m, half=2m, exp=1: 0.75 * 4 = 3.0.
    // Inverse-squared factor: 1 / 10000.
    cases:=[]Light_Case{
        {
            label="explicit_hdr_inv_sq",
            params={radius_scale=2.0,diffuse_scale=1.0,inverse_squared=true,color_add={10,5,2},has_color_add=true,particle_scattering=-1,renderer_scattering=1,indirect=1},
            want_eff={10.0/10000.0,5.0/10000.0,2.0/10000.0},
        },
        {
            label="explicit_dim_inv_sq",
            params={radius_scale=2.0,diffuse_scale=1.0,inverse_squared=true,color_add={0.5,0.25,0.1},has_color_add=true,particle_scattering=-1,renderer_scattering=1,indirect=1},
            want_eff={0.5/10000.0,0.25/10000.0,0.1/10000.0},
        },
        {
            label="explicit_hdr_windowed",
            params={radius_scale=4.0,diffuse_scale=1.0,inverse_squared=false,default_exponent=1.0,particle_color={10,5,2},has_particle_color=true,particle_scattering=-1,renderer_scattering=1,indirect=1},
            want_eff={30.0,15.0,6.0},
        },
        {
            label="explicit_dim_windowed",
            params={radius_scale=4.0,diffuse_scale=1.0,inverse_squared=false,default_exponent=1.0,particle_color={0.5,0.25,0.1},has_particle_color=true,particle_scattering=-1,renderer_scattering=1,indirect=1},
            want_eff={1.5,0.75,0.3},
        },
        {
            label="particle_hdr_raw_windowed",
            params={radius_scale=4.0,diffuse_scale=1.0,inverse_squared=false,default_exponent=1.0,fallback_color={10,5,2,1},fallback_color_intensity=1.0,particle_scattering=-1,renderer_scattering=1,indirect=1},
            particle_rgb={10,5,2},want_zero_color=true,
            want_eff={30.0,15.0,6.0},
        },
        {
            label="particle_hdr_scaled_windowed",
            params={radius_scale=4.0,diffuse_scale=1.0,inverse_squared=false,default_exponent=1.0,fallback_color={1,0.5,0.2,1},fallback_color_intensity=10.0,particle_scattering=-1,renderer_scattering=1,indirect=1},
            particle_rgb={1,0.5,0.2},want_zero_color=true,
            want_eff={30.0,15.0,6.0},
        },
        {
            label="particle_dim_windowed",
            params={radius_scale=4.0,diffuse_scale=1.0,inverse_squared=false,default_exponent=1.0,fallback_color={0.5,0.25,0.1,1},fallback_color_intensity=1.0,particle_scattering=-1,renderer_scattering=1,indirect=1},
            particle_rgb={0.5,0.25,0.1},want_zero_color=true,
            want_eff={1.5,0.75,0.3},
        },
    }
    for tc in cases {
        got:=niagara_particle_light(tc.params)
        if tc.want_zero_color {
            testing.expectf(t,got.color=={0,0,0},"%s expected {0,0,0} color, got %v",tc.label,got.color)
        } else {
            peak:=max(got.color.x,max(got.color.y,got.color.z))
            testing.expectf(t,abs(peak-1.0)<1e-4,"%s explicit color must be normalized to peak 1, got %v",tc.label,got.color)
        }
        eff_col:=got.color=={} ? tc.particle_rgb : got.color
        eff:=eff_col*got.intensity
        testing.expectf(t,abs(eff.x-tc.want_eff.x)<1e-5 && abs(eff.y-tc.want_eff.y)<1e-5 && abs(eff.z-tc.want_eff.z)<1e-5,"%s eff %v != want %v (intensity=%v color=%v)",tc.label,eff,tc.want_eff,got.intensity,got.color)
    }

    // Zero-intensity black light stays disabled (intensity == 0).
    dark:=niagara_particle_light({radius_scale=2.0,diffuse_scale=1.0,inverse_squared=true,particle_scattering=-1,renderer_scattering=1,indirect=1})
    testing.expect_value(t,dark.intensity,f32(0))
    testing.expect_value(t,dark.color,[3]f32{0,0,0})

}

// Verifies collision-free <= 63-byte program names, real bitwise/cast Slang ops,
// and zero memory leaks under Odin's default tracking allocator.
@(test)
cooked_niagara_bridge_names_bitwise_and_zero_leaks :: proc(t:^testing.T) {
    make_doc :: proc(em_name:string) -> string {
        return strings.concatenate({`{
          "Schema": "ue5parse.niagara/2",
          "Name": "NS_VeryLongCookedFortniteNiagaraSystemAssetNameExceedingLimit",
          "Emitters": [{
            "Name": "`,em_name,`",
            "Renderers": [{"Kind": "sprite", "Class": "NiagaraSpriteRendererProperties"}],
            "Scripts": [{
              "Usage": "ParticleSpawnScript",
              "Outputs": [
                {"Attribute": "Lifetime", "Value": {"Literal": 1.0}},
                {"Attribute": "SubImageIndex", "Value": {"Op": "bit_and", "Args": [{"Op": "f2i", "Args": [{"Literal": 7.9}]}, {"Literal": 3.0}]}},
                {"Attribute": "MaterialRandom", "Value": {"Op": "iasf", "Args": [{"Op": "bit_or", "Args": [{"Op": "fasi", "Args": [{"Literal": 0.5}]}, {"Literal": 0.0}]}]}}
              ]
            }]
          }]
        }`},context.temp_allocator)
    }
    sys_a,err_a:=cooked_niagara_build(make_doc("LongEmitterNameVariant_Alpha"))
    defer cooked_vfx_system_destroy(&sys_a)
    sys_b,err_b:=cooked_niagara_build(make_doc("LongEmitterNameVariant_Beta"))
    defer cooked_vfx_system_destroy(&sys_b)
    if !testing.expect(t,err_a==nil && err_b==nil) {return}
    if !testing.expect(t,len(sys_a.emitters)==1 && len(sys_b.emitters)==1) {return}
    if !testing.expect(t,len(sys_a.emitters[0].layers)==1 && len(sys_b.emitters[0].layers)==1) {return}
    pa,pb:=sys_a.emitters[0].layers[0].program_name,sys_b.emitters[0].layers[0].program_name
    testing.expect(t,len(pa)<=effect.PARTICLE_NAME_BYTES-1)
    testing.expect(t,len(pb)<=effect.PARTICLE_NAME_BYTES-1)
    testing.expect(t,pa!=pb)
    testing.expect_value(t,base.text_get(sys_a.emitters[0].layers[0].info.program[:]),pa)
    testing.expect_value(t,base.text_get(sys_b.emitters[0].layers[0].info.program[:]),pb)
    src:=sys_a.emitters[0].layers[0].program_source
    testing.expect(t,strings.contains(src,"int(") && strings.contains(src," & ") && strings.contains(src," | "))
    testing.expect(t,strings.contains(src,"asuint(") && strings.contains(src,"asfloat("))

    // Compile the bitwise/cast Slang program via slangc.
    folder:=".mirai/tmp/cooked-vfx-bitwise"
    _=os.make_directory_all(folder)
    shader_path,_:=filepath.join({folder,strings.concatenate({pa,".slang"},context.temp_allocator)},context.temp_allocator)
    _=os.write_entire_file(shader_path,transmute([]u8)src)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)
    if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
        vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
        sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
        res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
        testing.expectf(t,res.error=="" && res.errors==0,"bitwise Vfx Slang compile failed: %s %v",res.error,res.diagnostics)
        if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"bitwise Vfx Slang did not compile: %v",res.diagnostics)}
    }
}
