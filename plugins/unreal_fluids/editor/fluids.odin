package unreal_fluids_editor

import unreal_scene "project:plugins/unreal/editor/scene"
import fluids "plugins:fluids/runtime"

// The output materials of FluidNinja read the buffers of its simulation,
// which its Blueprints give them as they run. The one of velocity and density
// (VelocityDensityBuffer: velocity in red and green, density in blue) is the
// first layer of the fluid, with a vfx.Particle_World_Texture of layer 0:
// they read it by UV over its grid, turned to Unreal's axes (fluid_ninja.slang).
@(storage)
Fluids_Unreal :: struct {provider:unreal_scene.Translator_Provider}

fluids_unreal_default :: proc() -> (f:Fluids_Unreal) {
    f.provider.read_count=1
    f.provider.reads[0]={texture="VelocityDensityBuffer",include="fluid_ninja.slang",function="fluid_ninja_buffer",name=fluids.GRID}
    return
}
