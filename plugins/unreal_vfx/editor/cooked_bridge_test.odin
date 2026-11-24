package unreal_vfx_editor

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "mirai:asset"
import shaders "mirai:cook/shaders"
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

    // Verify generated Vfx Slang shader compiles cleanly with Mirai's slangc checker.
    testing.expect(t,strings.contains(em.program_source,"//! mirai vfx Cooked_NS_Katana_Slash_SlashArc"))
    testing.expect(t,strings.contains(em.program_source,"visual.data[0]"))
    testing.expect(t,strings.contains(em.program_source,"ue_to_mirai_pos"))
    folder:=".mirai/tmp/cooked-vfx-test"
    _=os.make_directory_all(folder)
    shader_path,_:=filepath.join({folder,"Cooked_NS_Katana_Slash_SlashArc.slang"},context.temp_allocator)
    _=os.write_entire_file(shader_path,transmute([]u8)em.program_source)
    root,cwd_err:=os.get_working_directory(context.temp_allocator)
    if cwd_err==nil {
        vfx_dir,_:=filepath.join({root,"plugins","vfx","shaders"},context.temp_allocator)
        sources:=os.exists(vfx_dir) ? []shaders.Source{{name="vfx",folder=vfx_dir}} : nil
        res:=shaders.program_check({root=root,project=folder,sources=sources,path=shader_path},context.temp_allocator)
        if !strings.contains(res.error,"slangc") {
            testing.expectf(t,res.error=="" && res.errors==0,"Vfx Slang compile failed: %s %v",res.error,res.diagnostics)
            if os.exists(vfx_dir) {testing.expectf(t,res.compiled,"Vfx Slang stages did not compile: %v",res.diagnostics)}
        }
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
    testing.expectf(t,abs(l.color.x-0.4)<1e-3 && abs(l.color.y-0.8)<1e-3 && abs(l.color.z-1.0)<1e-3,"color %v",l.color)

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
