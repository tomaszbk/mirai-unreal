// The buffer of velocity and density an output material of FluidNinja reads
// at uv, from the fluid of a grid: fluid_ninja_buffer("fluid", uv).
// FluidNinja lays its simulation along Unreal's X and Y: u runs along X, the
// z of Mirai, and v along Y, the -x of Mirai, so the texture of the world of
// the fluid is read turned, and its velocity (red and green) is along u and v.
#ifndef FLUID_NINJA_SLANG
#define FLUID_NINJA_SLANG
#include "vfx_world_texture.slang"
#define fluid_ninja_buffer(name, uv) fluid_ninja_buffer_named(uint(getStringHash(name)), uv)

float4 fluid_ninja_buffer_named(uint name, float2 uv) {
    float4 fluid = vfx_world_texture_uv_named(name, float2(1.0 - uv.y, uv.x));
    return float4(fluid.y, -fluid.x, fluid.z, fluid.w);
}
#endif
