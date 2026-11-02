// Unreal's noise functions, for the programs translated from Unreal: the
// Noise and VectorNoise expressions of its materials, the curl noise of
// Niagara and the custom HLSL that calls them by their names. Unreal's
// texture noises read a table of random gradients; here a hash of the cell
// picks one of the same twelve gradients, with the period of the table: the
// same noise, with another draw of the gradients.
#ifndef MIRAI_UNREAL_NOISE_SLANG
#define MIRAI_UNREAL_NOISE_SLANG

uint3 Rand3DPCG16(int3 p) {
    uint3 v = uint3(p);
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v >> 16u;
}
uint3 Rand3DPCG32(int3 p) {
    uint3 v = uint3(p);
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}
float PseudoRandom(float2 xy) {
    float2 pos = frac(xy / 128.0) * 128.0 + float2(-64.340622, -72.465622);
    return frac(dot(pos.xyx * pos.xyy, float3(20.390625, 60.703125, 2.4281209)));
}
float RandBBSfloat(float seed) {
    float s = frac(seed / 4093.0);
    s = frac(s * s * 4093.0);
    s = frac(s * s * 4093.0);
    return s;
}
float3 NoiseTileWrap(float3 v, bool tiling, float repeat) { return tiling ? frac(v / repeat) * repeat : v; }
float4 PerlinRamp(float4 t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }
float4 MGradient(int seed, float3 offset) {
    uint r = Rand3DPCG16(int3(seed, 0, 0)).x;
    float3 direction = float3(uint3(r, r, r) & uint3(0x8000, 0x4000, 0x2000)) * float3(1.0 / 16384.0, 1.0 / 8192.0, 1.0 / 4096.0) - 1.0;
    return float4(direction, dot(direction, offset));
}
// The seeds of the eight corners of the cell of v (x the lowest bit of the
// corner, z the highest), and where v is in it.
float3 NoiseSeeds(float3 v, bool tiling, float repeat, out float seeds[8]) {
    float3 iv = floor(v);
    const float3 primes = float3(19.0, 47.0, 101.0);
    for (int c = 0; c < 8; c++) {
        float3 corner = iv + float3(c & 1, (c >> 1) & 1, (c >> 2) & 1);
        seeds[c] = dot(primes, tiling ? NoiseTileWrap(corner, true, repeat) : corner);
    }
    return frac(v);
}
// The eight values of the corners of a cell, blended by Perlin's ramp.
float NoiseCorners(float values[8], float3 fv) {
    float3 w = PerlinRamp(float4(fv, 0.0)).xyz;
    float i = lerp(lerp(values[0], values[1], w.x), lerp(values[2], values[3], w.x), w.y);
    float j = lerp(lerp(values[4], values[5], w.x), lerp(values[6], values[7], w.x), w.y);
    return lerp(i, j, w.z);
}
float GradientNoise3D_ALU(float3 v, bool tiling, float repeat) {
    float seeds[8];
    float3 fv = NoiseSeeds(v, tiling, repeat, seeds);
    float values[8];
    for (int c = 0; c < 8; c++) values[c] = MGradient(int(seeds[c]), fv - float3(c & 1, (c >> 1) & 1, (c >> 2) & 1)).w;
    return NoiseCorners(values, fv);
}
float ValueNoise3D_ALU(float3 v, bool tiling, float repeat) {
    float seeds[8];
    float3 fv = NoiseSeeds(v, tiling, repeat, seeds);
    float values[8];
    for (int c = 0; c < 8; c++) values[c] = RandBBSfloat(seeds[c]) * 2.0 - 1.0;
    return NoiseCorners(values, fv);
}
float4x3 SimplexCorners(float3 v) {
    float3 tet = floor(v + v.x / 3.0 + v.y / 3.0 + v.z / 3.0);
    float3 base = tet - tet.x / 6.0 - tet.y / 6.0 - tet.z / 6.0;
    float3 f = v - base;
    float3 g = step(f.yzx, f.xyz), h = 1.0 - g.zxy;
    float3 a1 = min(g, h) - 1.0 / 6.0, a2 = max(g, h) - 1.0 / 3.0;
    return float4x3(base, base + a1, base + a2, base + 0.5);
}
// Simplex noise and its Jacobian: J[i].w is component i of a vector noise
// and J[i].xyz its gradient.
float3x4 JacobianSimplex_ALU(float3 v, bool tiling, float repeat) {
    float4x3 T = SimplexCorners(v);
    float4x3 gvec[3];
    float4x3 fv;
    float3x4 grad;
    for (uint i = 0u; i < 4u; i++) {
        fv[i] = v - T[i];
        uint3 r = Rand3DPCG16(int3(floor(NoiseTileWrap(6.0 * T[i] + 0.5, tiling, repeat))));
        gvec[0][i] = float3(r.xxx & uint3(0x8000, 0x4000, 0x2000)) * float3(1.0 / 16384.0, 1.0 / 8192.0, 1.0 / 4096.0) - 1.0;
        gvec[1][i] = float3(r.yyy & uint3(0x8000, 0x4000, 0x2000)) * float3(1.0 / 16384.0, 1.0 / 8192.0, 1.0 / 4096.0) - 1.0;
        gvec[2][i] = float3(r.zzz & uint3(0x8000, 0x4000, 0x2000)) * float3(1.0 / 16384.0, 1.0 / 8192.0, 1.0 / 4096.0) - 1.0;
        grad[0][i] = dot(gvec[0][i], fv[i]);
        grad[1][i] = dot(gvec[1][i], fv[i]);
        grad[2][i] = dot(gvec[2][i], fv[i]);
    }
    const float scale = 1024.0 / 375.0;
    float4 d = float4(dot(fv[0], fv[0]), dot(fv[1], fv[1]), dot(fv[2], fv[2]), dot(fv[3], fv[3]));
    float4 s = saturate(2.0 * d);
    float4 sv = scale + s * (-3.0 * scale + s * (3.0 * scale - s * scale));
    float4 ds = -12.0 * scale + s * (24.0 * scale - s * 12.0 * scale);
    float3x4 dsm = float3x4(ds * float4(fv[0][0], fv[1][0], fv[2][0], fv[3][0]), ds * float4(fv[0][1], fv[1][1], fv[2][1], fv[3][1]), ds * float4(fv[0][2], fv[1][2], fv[2][2], fv[3][2]));
    float3x4 j;
    j[0] = float4(mul(sv, gvec[0]) + mul(dsm, grad[0]), dot(sv, grad[0]));
    j[1] = float4(mul(sv, gvec[1]) + mul(dsm, grad[1]), dot(sv, grad[1]));
    j[2] = float4(mul(sv, gvec[2]) + mul(dsm, grad[2]), dot(sv, grad[2]));
    return j;
}
// One of the twelve gradients of Unreal's tables (the middles of the edges
// of a cube), for a cell of a table with period cells along each axis.
float3 unreal_noise_gradient(int3 cell, int period) {
    int3 wrapped = ((cell % period) + period) % period;
    uint pick = Rand3DPCG16(wrapped).x % 12u;
    static const float3 gradients[12] = {float3(0, 1, 1), float3(1, 0, 1), float3(1, 1, 0), float3(0, 1, -1), float3(1, 0, -1), float3(1, -1, 0),
                                         float3(0, -1, 1), float3(-1, 0, 1), float3(-1, 1, 0), float3(0, -1, -1), float3(-1, 0, -1), float3(-1, -1, 0)};
    return gradients[pick];
}
// The gradient of the 2D table of 128 texels at a point of the 3D lattice:
// its z shears the table.
float3 unreal_sheared_gradient(float3 v) { return unreal_noise_gradient(int3(int2(floor(v.xy + v.z * float2(17.0, 89.0))), 0), 128); }
float GradientNoise3D_TEX(float3 v, bool tiling, float repeat) {
    float3 fv = frac(v);
    float3 iv0 = NoiseTileWrap(floor(v), true, repeat);
    float3 iv1 = NoiseTileWrap(iv0 + 1.0, true, repeat);
    float values[8];
    for (int c = 0; c < 8; c++) {
        int3 bit = int3(c & 1, (c >> 1) & 1, (c >> 2) & 1);
        float3 corner = float3(bit.x != 0 ? iv1.x : iv0.x, bit.y != 0 ? iv1.y : iv0.y, bit.z != 0 ? iv1.z : iv0.z);
        values[c] = dot(unreal_sheared_gradient(corner), fv - float3(bit));
    }
    return NoiseCorners(values, fv);
}
// Gradient noise over Unreal's 3D table of 15 cells a side, interpolated by
// Perlin's ramp (FastGradientPerlinNoise3D_TEX).
float FastGradientPerlinNoise3D_TEX(float3 xyz) {
    xyz = frac(xyz / 15.0) * 15.0;
    float3 fv = frac(xyz);
    float3 p0 = xyz - fv;
    float values[8];
    for (int c = 0; c < 8; c++) {
        float3 corner = p0 + float3(c & 1, (c >> 1) & 1, (c >> 2) & 1);
        values[c] = dot(unreal_noise_gradient(int3(corner), 15), xyz - corner);
    }
    return NoiseCorners(values, fv);
}
float SimplexNoise3D_TEX(float3 position) {
    float3 skewed = position + dot(position, 1.0 / 3.0);
    float3 a = floor(skewed), b = a + 1.0;
    float3 local = skewed - a;
    float largest = max(local.x, max(local.y, local.z)), smallest = min(local.x, min(local.y, local.z));
    float3 c = a + select(float3(largest) == local, float3(1.0), float3(0.0));
    float3 d = a + select(float3(smallest) != local, float3(1.0), float3(0.0));
    float3 corners[4] = {a, b, c, d};
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        float3 offset = position - (corners[i] - dot(corners[i], 1.0 / 6.0));
        float w = saturate(0.6 - dot(offset, offset));
        w *= w; w *= w;
        sum += dot(unreal_sheared_gradient(corners[i]), offset) * w;
    }
    return 32.0 * sum;
}
float3 VoronoiCornerSample(float3 pos, int quality) {
    float3 n = float3(Rand3DPCG16(int3(pos))) / 65535.0 - 0.5;
    if (quality <= 2) return normalize(n) * 0.2588;
    if (quality == 3) return normalize(n) * 0.3090;
    return n;
}
float4 VoronoiCompare(float4 best, float3 candidate, float3 offset, bool distance_only) {
    if (distance_only) return float4(0.0, 0.0, 0.0, min(best.w, dot(offset, offset)));
    float d = dot(offset, offset);
    return d > best.w ? best : float4(candidate, d);
}
float4 VoronoiNoise3D_ALU(float3 v, int quality, bool tiling, float repeat, bool distance_only) {
    float3 fv = frac(v), fv2 = frac(v + 0.5);
    float3 iv = floor(v), iv2 = floor(v + 0.5);
    float4 best = float4(0.0, 0.0, 0.0, 100.0);
    float3 p = float3(0.0), offset = float3(0.0);
    if (quality == 3) {
        for (offset.x = -1.0; offset.x <= 1.0; ++offset.x) {
            for (offset.y = -1.0; offset.y <= 1.0; ++offset.y) {
                for (offset.z = -1.0; offset.z <= 1.0; ++offset.z) {
                    p = offset + VoronoiCornerSample(NoiseTileWrap(iv2 + offset, tiling, repeat), quality);
                    best = VoronoiCompare(best, iv2 + p, fv2 - p, distance_only);
                }
            }
        }
    } else {
        for (offset.x = 0.0; offset.x <= 1.0; ++offset.x) {
            for (offset.y = 0.0; offset.y <= 1.0; ++offset.y) {
                for (offset.z = 0.0; offset.z <= 1.0; ++offset.z) {
                    p = offset + VoronoiCornerSample(NoiseTileWrap(iv + offset, tiling, repeat), quality);
                    best = VoronoiCompare(best, iv + p, fv - p, distance_only);
                    if (quality == 2) {
                        p = offset + VoronoiCornerSample(NoiseTileWrap(iv2 + offset, tiling, repeat) + 467.0, quality);
                        best = VoronoiCompare(best, iv2 + p, fv2 - p, distance_only);
                    }
                }
            }
        }
    }
    if (quality >= 4) {
        for (offset.x = -1.0; offset.x <= 2.0; offset.x += 3.0) {
            for (offset.y = 0.0; offset.y <= 1.0; ++offset.y) {
                for (offset.z = 0.0; offset.z <= 1.0; ++offset.z) {
                    p = offset.xyz + VoronoiCornerSample(NoiseTileWrap(iv + offset.xyz, tiling, repeat), quality);
                    best = VoronoiCompare(best, iv + p, fv - p, distance_only);
                    p = offset.yzx + VoronoiCornerSample(NoiseTileWrap(iv + offset.yzx, tiling, repeat), quality);
                    best = VoronoiCompare(best, iv + p, fv - p, distance_only);
                    p = offset.zxy + VoronoiCornerSample(NoiseTileWrap(iv + offset.zxy, tiling, repeat), quality);
                    best = VoronoiCompare(best, iv + p, fv - p, distance_only);
                }
            }
        }
    }
    return float4(best.xyz, sqrt(best.w));
}
float Noise3D_Multiplexer(int function, float3 position, int quality, bool tiling, float repeat) {
    switch (function) {
    case 0: return SimplexNoise3D_TEX(position);
    case 1: return GradientNoise3D_TEX(position, tiling, repeat);
    case 2: return FastGradientPerlinNoise3D_TEX(position);
    case 3: return GradientNoise3D_ALU(position, tiling, repeat);
    case 4: return ValueNoise3D_ALU(position, tiling, repeat);
    default: return VoronoiNoise3D_ALU(position, quality, tiling, repeat, true).w * 2.0 - 1.0;
    }
}
// Levels of noise, each level_scale times finer and that much fainter, from
// output_min to output_max.
float MaterialExpressionNoise(float3 position, float scale, int quality, int function, bool turbulence, uint levels, float output_min,
                              float output_max, float level_scale, float filter_width, bool tiling, float repeat) {
    position *= scale;
    filter_width *= scale;
    float result = 0.0;
    float strength = 1.0;
    for (uint i = 0u; i < levels; ++i) {
        strength *= saturate(1.0 - filter_width);
        float n = Noise3D_Multiplexer(function, position, quality, tiling, repeat);
        result += (turbulence ? abs(n) : n) * strength;
        position *= level_scale;
        repeat *= level_scale;
        strength /= level_scale;
        filter_width *= level_scale;
    }
    if (!turbulence) result = result * 0.5 + 0.5;
    return lerp(output_min, output_max, result);
}
// The same of a place of the world, which Unreal mirrors and repeats every
// 65536 units first.
float MaterialExpressionNoiseWorld(float3 position, float scale, int quality, int function, bool turbulence, uint levels, float output_min,
                                   float output_max, float level_scale, float filter_width, bool tiling, float repeat) {
    position = abs(65536.0 * frac(position / 65536.0));
    return MaterialExpressionNoise(position, scale, quality, function, turbulence, levels, output_min, output_max, level_scale, filter_width, tiling, repeat);
}
float4 MaterialExpressionVectorNoise(float3 position, int quality, int function, bool tiling, float tile_size) {
    float4 result = float4(0.0, 0.0, 0.0, 1.0);
    switch (function) {
    case 0: result.xyz = float3(Rand3DPCG16(int3(floor(NoiseTileWrap(position, tiling, tile_size))))) / 65535.0; break;
    case 1: {
        float3x4 j = JacobianSimplex_ALU(position, tiling, tile_size);
        result.xyz = float3(j[0].w, j[1].w, j[2].w);
        break;
    }
    case 2: result = JacobianSimplex_ALU(position, tiling, tile_size)[0]; break;
    case 3: {
        float3x4 j = JacobianSimplex_ALU(position, tiling, tile_size);
        result.xyz = float3(j[2][1] - j[1][2], j[0][2] - j[2][0], j[1][0] - j[0][1]);
        break;
    }
    default: result = VoronoiNoise3D_ALU(position, quality, tiling, tile_size, false); break;
    }
    return result;
}

#endif
