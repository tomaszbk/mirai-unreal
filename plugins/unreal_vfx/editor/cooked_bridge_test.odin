package unreal_vfx_editor

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "mirai:asset"
import shaders "mirai:cook/shaders"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

// Cooked `ue5parse.niagara/2` JSON builds validated Mirai `.particle` bytes,
// native `.mat` v6 materials, and a compiling Mirai Vfx Slang shader.
@(test)
cooked_niagara_bridge_builds_particle_and_compiles_vfx_slang :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)

    doc:=`{
  "Schema": "ue5parse.niagara/2",
  "Name": "NS_Katana_Slash",
  "Package": "/Game/FX/NS_Katana_Slash",
  "Kind": "NiagaraSystem",
  "UserParameters": [{"Name": "User.Scale", "Type": "NiagaraFloat", "Value": 1.5}],
  "Materials": [
    {
      "Path": "/Game/FX/MI_Slash.MI_Slash",
      "Name": "MI_Slash",
      "BlendMode": "BLEND_Additive",
      "ShadingModel": "MSM_Unlit",
      "TwoSided": true,
      "Vectors": {"EmissiveColor": {"Value": [0.3, 0.8, 1.0, 1.0], "From": "MI_Slash"}}
    }
  ],
  "Emitters": [
    {
      "Name": "SlashArc",
      "Enabled": true,
      "Target": "CPU",
      "Settings": {"bLocalSpace": true, "AllocationCount": 64},
      "EmitterScripts": [
        {
          "Usage": "EmitterUpdateScript",
          "Outputs": [
            {"Attribute": "SlashArc.SpawnBurst_Instantaneous.SpawnBurst.Count", "Value": {"Literal": 8.0}},
            {"Attribute": "SlashArc.CurrentLoopDuration", "Value": {"Literal": 0.45}},
            {"Attribute": "SlashArc.DepthFade", "Value": {"Literal": 120.0}}
          ]
        }
      ],
      "Scripts": [
        {
          "Usage": "ParticleSpawnScript",
          "Target": "CPU",
          "Outputs": [
            {"Attribute": "Lifetime", "Value": {"Literal": 0.35}},
            {"Attribute": "SpriteSize.x", "Value": {"Literal": 120.0}},
            {"Attribute": "SpriteSize.y", "Value": {"Literal": 120.0}},
            {"Attribute": "Color.x", "Value": {"Literal": 0.4}},
            {"Attribute": "Color.y", "Value": {"Literal": 0.9}},
            {"Attribute": "Color.z", "Value": {"Literal": 1.0}},
            {"Attribute": "Color.w", "Value": {"Literal": 1.0}},
            {"Attribute": "Position.x", "Value": {"Literal": 50.0}},
            {"Attribute": "Position.y", "Value": {"Literal": 0.0}},
            {"Attribute": "Position.z", "Value": {"Literal": 100.0}},
            {"Attribute": "DynamicMaterialParameter.x", "Value": {"Parameter": "User.Scale", "Value": 1.5}}
          ]
        },
        {
          "Usage": "ParticleUpdateScript",
          "Target": "CPU",
          "Outputs": [
            {"Attribute": "Age", "Value": {"Op": "add", "Args": [{"Attribute": "Age"}, {"Parameter": "Engine.DeltaTime"}]}},
            {"Attribute": "Position.z", "Value": {"Op": "mad", "Args": [{"Attribute": "Velocity.z"}, {"Parameter": "Engine.DeltaTime"}, {"Attribute": "Position.z"}]}}
          ],
          "KeepConditions": [
            {"Op": "cmplt", "Args": [{"Attribute": "Age"}, {"Attribute": "Lifetime"}]}
          ]
        }
      ],
      "DataInterfaces": [
        {"Name": "Emitter.ScaleSize.FloatCurve", "Class": "NiagaraDataInterfaceCurve", "ShaderLUT": [0.2, 0.8, 1.0, 0.5, 0.0]}
      ],
      "Renderers": [
        {
          "Kind": "NiagaraSpriteRendererProperties",
          "Alignment": "ENiagaraSpriteAlignment::VelocityAligned",
          "SubImageSize": {"X": 2, "Y": 2},
          "Material": "/Game/FX/MI_Slash.MI_Slash"
        }
      ]
    }
  ]
}`

    sys,err:=cooked_niagara_build(doc,alloc)
    _,bad:=err.?
    if !testing.expect(t,!bad) {return}
    testing.expect_value(t,sys.name,"NS_Katana_Slash")
    testing.expect_value(t,len(sys.materials),1)
    if !testing.expect_value(t,len(sys.emitters),1) {return}

    em:=sys.emitters[0]
    testing.expect_value(t,em.name,"SlashArc")
    testing.expect(t,em.info.local_space)
    testing.expect_value(t,em.info.render,effect.Particle_Render.Velocity)
    testing.expect_value(t,em.info.blend,effect.Particle_Blend.Additive)
    testing.expect(t,!em.info.lit)
    testing.expect_value(t,em.info.flipbook,[2]u32{2,2})
    testing.expect_value(t,em.info.bursts[0].count,u32(8))
    testing.expectf(t,abs(em.info.soft-1.2)<1e-4,"soft %v",em.info.soft)
    testing.expectf(t,abs(em.info.lifetime[0]-0.35)<1e-4,"lifetime %v",em.info.lifetime)
    testing.expectf(t,abs(em.info.size[0]-1.2)<1e-4,"size %v",em.info.size)
    testing.expect(t,len(em.particle_bytes)>0)

    // Round-trip .particle bytes through Mirai's effect.particle_view.
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    a:asset.Asset
    testing.expect_value(t,asset.asset_open(&a,em.particle_bytes),asset.Error.None)
    defer asset.asset_close(&a)
    view,verr:=effect.particle_view(&a,&types)
    testing.expect_value(t,verr,asset.Error.None)
    testing.expect_value(t,view.info.render,effect.Particle_Render.Velocity)
    testing.expect_value(t,view.info.blend,effect.Particle_Blend.Additive)

    // Verify generated Vfx Slang shader has consistent age/lifetime seconds,
    // KeepConditions evaluated AFTER particle.age assignment, and compiles with slangc.
    testing.expect(t,strings.contains(em.program_source,"//! mirai vfx Cooked_NS_Katana_Slash_SlashArc"))
    testing.expect(t,strings.contains(em.program_source,"visual.data[0]"))
    testing.expect(t,strings.contains(em.program_source,"ue_to_mirai_pos"))
    age_idx:=strings.last_index(em.program_source,"particle.age = max(a.f_Age, 0.0);")
    kill_idx:=strings.index(em.program_source,"particle.age = particle.lifetime;")
    testing.expectf(t,age_idx>0 && kill_idx>age_idx,"kill condition must follow particle.age assignment (age=%d kill=%d):\n%s",age_idx,kill_idx,em.program_source)
    testing.expect(t,!strings.contains(em.program_source,"saturate(a.f_Age / a.f_Lifetime)"))

    folder:=".mirai/tmp/cooked-vfx-test"
    _=os.make_directory_all(folder)
    shader_path,_:=filepath.join({folder,"Cooked_NS_Katana_Slash_SlashArc.slang"},context.temp_allocator)
    _=os.write_entire_file(shader_path,transmute([]u8)em.program_source)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)
    if testing.expectf(t,cwd_err==nil,"cwd failed: %v",cwd_err) {
        vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
        sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
        res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
        testing.expectf(t,res.error=="" && res.errors==0,"Vfx Slang compile failed: %s %v",res.error,res.diagnostics)
        if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"Vfx Slang stages did not compile: %v",res.diagnostics)}
    }
}

// Cooked Niagara emitter with UNiagaraLightRendererProperties populates
// Mirai .particle v10 effect.Particle_Light cleanly and round-trips at v10.
@(test)
cooked_niagara_bridge_emits_particle_v10_light :: proc(t:^testing.T) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    alloc:=mem.dynamic_arena_allocator(&arena)

    testing.expect_value(t,effect.PARTICLE_VERSION,u32(10))

    doc:=`{
  "Schema": "ue5parse.niagara/2",
  "Name": "NS_Katana_ImpactFlash",
  "Package": "/Game/FX/NS_Katana_ImpactFlash",
  "Kind": "NiagaraSystem",
  "Emitters": [
    {
      "Name": "ImpactLight",
      "Enabled": true,
      "Target": "CPU",
      "Settings": {"bLocalSpace": false, "AllocationCount": 8},
      "Scripts": [
        {
          "Usage": "ParticleSpawnScript",
          "Target": "CPU",
          "Outputs": [
            {"Attribute": "Lifetime", "Value": {"Literal": 0.25}},
            {"Attribute": "SpriteSize.x", "Value": {"Literal": 60.0}},
            {"Attribute": "Color.x", "Value": {"Literal": 0.4}},
            {"Attribute": "Color.y", "Value": {"Literal": 0.8}},
            {"Attribute": "Color.z", "Value": {"Literal": 1.0}},
            {"Attribute": "LightRadius", "Value": {"Literal": 450.0}},
            {"Attribute": "LightIntensity", "Value": {"Literal": 600.0}},
            {"Attribute": "LightVolumetricScattering", "Value": {"Literal": 1.5}}
          ]
        }
      ],
      "Renderers": [
        {
          "Kind": "NiagaraLightRendererProperties",
          "RadiusScale": 1.2,
          "DiffuseScale": 1.0,
          "bMegaLightsCastShadows": true,
          "MaxLights": 2,
          "IndirectLightingIntensity": 0.8
        }
      ]
    }
  ]
}`

    sys,err:=cooked_niagara_build(doc,alloc)
    _,bad:=err.?
    if !testing.expect(t,!bad) || !testing.expect_value(t,len(sys.emitters),1) {return}

    em:=sys.emitters[0]
    testing.expect_value(t,len(em.warnings),0)
    l:=em.info.light
    testing.expectf(t,abs(l.intensity-600.0)<1e-3,"intensity %v",l.intensity)
    testing.expectf(t,abs(l.range-5.4)<1e-3,"range %v (450cm * 1.2)",l.range)
    testing.expectf(t,abs(l.radius-0.3)<1e-3,"radius %v",l.radius)
    testing.expect_value(t,l.max_lights,u16(2))
    testing.expect(t,l.shadows)
    testing.expectf(t,abs(l.indirect-0.8)<1e-3,"indirect %v",l.indirect)
    testing.expectf(t,abs(l.scattering-1.5)<1e-3,"scattering %v",l.scattering)
    // No explicit LightColor / ColorAdd -> {0,0,0} so Mirai uses the particle's color.
    testing.expect_value(t,l.color,[3]f32{0,0,0})

    // UE6 simple-light calibration: inverse-squared divides UE cm^2 radiance by 10000;
    // non-inverse-squared windowed falloff matches at half its radius (peak * 0.75^exp * (R/2)^2).
    inv_sq:=niagara_particle_light({
        radius_scale=2.0,diffuse_scale=1.0,inverse_squared=true,
        color_add={50000,25000,10000},has_color_add=true,
        particle_scattering=-1,renderer_scattering=1,indirect=1,max_lights=1,
    })
    testing.expectf(t,abs(inv_sq.intensity-5.0)<1e-4,"inv_sq cd %v",inv_sq.intensity)
    testing.expectf(t,abs(inv_sq.color.x-1.0)<1e-4 && abs(inv_sq.color.y-0.5)<1e-4 && abs(inv_sq.color.z-0.2)<1e-4,"inv_sq normalized color %v",inv_sq.color)
    testing.expectf(t,abs(inv_sq.range-2.0)<1e-4,"range %v",inv_sq.range)

    windowed:=niagara_particle_light({
        radius_scale=4.0,diffuse_scale=1.0,inverse_squared=false,default_exponent=1.0,
        fallback_color={1,0.5,0.2,1},fallback_color_intensity=10.0,
        particle_scattering=-1,renderer_scattering=1,indirect=1,max_lights=1,
    })
    // range = 4m, half = 2m -> 10 * 0.75^1 * 2^2 = 30 cd; color stays {0,0,0} (uses particle color).
    testing.expectf(t,abs(windowed.intensity-30.0)<1e-4,"windowed cd %v",windowed.intensity)
    testing.expect_value(t,windowed.color,[3]f32{0,0,0})

    // Zero-intensity black light stays disabled (intensity == 0).
    dark:=niagara_particle_light({radius_scale=2.0,diffuse_scale=1.0,inverse_squared=true,particle_scattering=-1,renderer_scattering=1,indirect=1,max_lights=1})
    testing.expect_value(t,dark.intensity,f32(0))
    testing.expect_value(t,dark.color,[3]f32{0,0,0})

    // Binary .particle v10 round-trip preserves Particle_Light verbatim.
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    a:asset.Asset
    testing.expect_value(t,asset.asset_open(&a,em.particle_bytes),asset.Error.None)
    defer asset.asset_close(&a)
    testing.expect_value(t,asset.kind_check(&a,effect.PARTICLE_KIND,10),asset.Error.None)
    view,verr:=effect.particle_view(&a,&types)
    testing.expect_value(t,verr,asset.Error.None)
    testing.expect_value(t,view.info.light,l)
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
    pa,pb:=sys_a.emitters[0].program_name,sys_b.emitters[0].program_name
    testing.expect(t,len(pa)<=effect.PARTICLE_NAME_BYTES-1)
    testing.expect(t,len(pb)<=effect.PARTICLE_NAME_BYTES-1)
    testing.expect(t,pa!=pb)
    testing.expect_value(t,base.text_get(sys_a.emitters[0].info.program[:]),pa)
    testing.expect_value(t,base.text_get(sys_b.emitters[0].info.program[:]),pb)
    src:=sys_a.emitters[0].program_source
    testing.expect(t,strings.contains(src,"int(") && strings.contains(src," & ") && strings.contains(src," | "))
    testing.expect(t,strings.contains(src,"asint(") && strings.contains(src,"asfloat("))

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
