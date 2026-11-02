// What the HLSL of Niagara's translator expects of the shader around it,
// for the Vfx programs the import translates from it (vfx/editor,
// niagara_program.odin): the state of the thread that runs a script, its
// random numbers and helpers, and the space of Unreal the scripts compute
// in: centimetres, Z up, Mirai's x is Unreal's -y, Mirai's y its z and
// Mirai's z its x.
#ifndef MIRAI_NIAGARA_SLANG
#define MIRAI_NIAGARA_SLANG
#include "mirai_vfx.slang"
#include "unreal_noise.slang"

#ifndef PI
#define PI 3.14159265358979
#endif
#define TWO_PI (2.0 * PI)
#define HALF_PI (0.5 * PI)
#define INV_PI (1.0 / PI)
#define INV_TWO_PI (0.5 / PI)
#define NIAGARA_DISPATCH_TYPE_ONE_D 0
#define NIAGARA_DISPATCH_TYPE_TWO_D 1
#define NIAGARA_DISPATCH_TYPE_THREE_D 2
#define NIAGARA_DISPATCH_TYPE_CUSTOM 3
#define GetEngineOwnerLWCTile() Engine_Owner_LWCTile.xyz
#define BRANCH [branch]
#define UNROLL [unroll]
#define LOOP [loop]
#define FLATTEN [flatten]

// The thread that runs a script, as the glue of a program sets it.
static Mirai_Vfx_Context niagara_ctx;
static uint3 GDispatchThreadId;
static uint3 GGroupThreadId;
static uint GLinearThreadId;
static uint GEmitterTickCounter;
static uint GRandomSeedOffset;
static uint EmitterTickCounter;
static int GGPUExecIndex;
static uint GSpawnStartInstance;
static float Emitter_SpawnInterval;
static float Emitter_InterpSpawnStartDt;
static int Emitter_SpawnGroup;
static int Engine_ExecutionCount;
static int RandomCounterDeterministic;
static int RandomCounterNonDeterministic;
static uint niagara_stage_iteration;
static uint niagara_stage_iterations;
static int2 niagara_id; // of the particle a script runs on: its slot in its range and its seed
static bool niagara_spawn_dropped; // the entry of a data channel that starts the particle asks for fewer than it

// Large world coordinates: Mirai's worlds keep every tile at zero.
struct FLWCVector3 { float3 Tile; float3 Offset; };
struct FLWCVector4 { float4 Tile; float4 Offset; };
struct FLWCScalar { float Tile; float Offset; };
FLWCVector3 MakeLWCVector3(float3 tile, float3 offset) { FLWCVector3 v; v.Tile = tile; v.Offset = offset; return v; }
FLWCVector4 MakeLWCVector4(float4 tile, float4 offset) { FLWCVector4 v; v.Tile = tile; v.Offset = offset; return v; }
FLWCVector3 LWCPromote(float3 v) { return MakeLWCVector3(float3(0.0), v); }
FLWCVector4 LWCPromote(float4 v) { return MakeLWCVector4(float4(0.0), v); }
float3 LWCToFloat(FLWCVector3 v) { return v.Tile * 2097152.0 + v.Offset; }
float4 LWCToFloat(FLWCVector4 v) { return v.Tile * 2097152.0 + v.Offset; }
float3 LWCGetTile(FLWCVector3 v) { return v.Tile; }
float4 LWCGetTile(FLWCVector4 v) { return v.Tile; }
FLWCVector3 LWCSetTile(FLWCVector3 v, float3 tile) { v.Tile = tile; return v; }
FLWCVector3 LWCAdd(FLWCVector3 a, float3 b) { a.Offset += b; return a; }
FLWCVector3 LWCSubtract(FLWCVector3 a, float3 b) { a.Offset -= b; return a; }
float3 LWCSubtract(FLWCVector3 a, FLWCVector3 b) { return LWCToFloat(a) - LWCToFloat(b); }

// The view of the frame as Unreal's View uniforms give it, in Unreal's space.
struct FLWCMatrix { float4x4 M; float3 Tile; };
float4x4 LWCToFloat(FLWCMatrix m) { return m.M; }
// The double floats of Unreal are the floats of Mirai.
float4x4 DFDemote(FLWCMatrix m) { return m.M; }
float4x4 DFDemote(float4x4 m) { return m; }
float3 DFDemote(FLWCVector3 v) { return LWCToFloat(v); }
float3 DFDemote(float3 v) { return v; }
// HLSL builds a matrix of rows and scalars mixed: three rows, a vector of three and the last scalar.
extension float4x4 {
    __init(float4 a, float4 b, float4 c, float3 d, float e) { this = float4x4(a, b, c, float4(d, e)); }
}
struct Niagara_View {
    FLWCMatrix WorldToClip;
    FLWCMatrix ClipToWorld;
    float4x4 TranslatedWorldToClip;
    float4 ScreenPositionScaleBias;
    float3 ViewForward;
    float3 ViewRight;
    float3 ViewUp;
    FLWCVector3 WorldCameraOrigin;
    float3 ViewOrigin;
    float4 ViewSizeAndInvSize;
    float4 BufferSizeAndInvSize;
    float4 ViewRectMin;
};
static Niagara_View View;
static Niagara_View PrimaryView;

// Unreal's centimetres and axes, and back.
float3 niagara_point(float3 mirai) { return float3(mirai.z, -mirai.x, mirai.y) * 100.0; }
float3 niagara_vector(float3 mirai) { return float3(mirai.z, -mirai.x, mirai.y) * 100.0; }
float3 niagara_direction(float3 mirai) { return float3(mirai.z, -mirai.x, mirai.y); }
float3 mirai_point(float3 unreal) { return float3(-unreal.y, unreal.z, unreal.x) * 0.01; }
float3 mirai_vector(float3 unreal) { return float3(-unreal.y, unreal.z, unreal.x) * 0.01; }
float3 mirai_direction(float3 unreal) { return float3(-unreal.y, unreal.z, unreal.x); }

// The transform of the emitter (Mirai rows) as a matrix of Unreal that takes
// a point of the system in Unreal's centimetres to the world (row vectors,
// as Unreal's HLSL multiplies them: mul(p, M)).
float4x4 niagara_local_to_world(float4 world[3]) {
    float3 o = niagara_point(float3(world[0].w, world[1].w, world[2].w));
    float3 x = niagara_direction(float3(world[0].z, world[1].z, world[2].z));
    float3 y = niagara_direction(-float3(world[0].x, world[1].x, world[2].x));
    float3 z = niagara_direction(float3(world[0].y, world[1].y, world[2].y));
    return float4x4(float4(x, 0.0), float4(y, 0.0), float4(z, 0.0), float4(o, 1.0));
}

float4x4 niagara_inverse(float4x4 m) {
    // An affine transform of row vectors: rotation and scale in the upper 3x3.
    float3x3 r = (float3x3)m;
    float3 a = r[0], b = r[1], c = r[2];
    float3 bc = cross(b, c), ca = cross(c, a), ab = cross(a, b);
    float det = dot(a, bc);
    float3x3 inv = abs(det) > 1e-20 ? transpose(float3x3(bc, ca, ab)) / det : float3x3(1, 0, 0, 0, 1, 0, 0, 0, 1);
    float3 t = -mul(m[3].xyz, inv);
    return float4x4(float4(inv[0], 0.0), float4(inv[1], 0.0), float4(inv[2], 0.0), float4(t, 1.0));
}

// The rotation of a matrix of row vectors as a quaternion (x, y, z, w).
float4 niagara_quaternion(float3x3 m) {
    float3 x = normalize(m[0]), y = normalize(m[1]), z = normalize(m[2]);
    float trace = x.x + y.y + z.z;
    float4 q;
    if (trace > 0.0) {
        float s = sqrt(trace + 1.0) * 2.0;
        q = float4((y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s, 0.25 * s);
    } else if (x.x > y.y && x.x > z.z) {
        float s = sqrt(1.0 + x.x - y.y - z.z) * 2.0;
        q = float4(0.25 * s, (y.x + x.y) / s, (z.x + x.z) / s, (y.z - z.y) / s);
    } else if (y.y > z.z) {
        float s = sqrt(1.0 + y.y - x.x - z.z) * 2.0;
        q = float4((y.x + x.y) / s, 0.25 * s, (z.y + y.z) / s, (z.x - x.z) / s);
    } else {
        float s = sqrt(1.0 + z.z - x.x - y.y) * 2.0;
        q = float4((z.x + x.z) / s, (z.y + y.z) / s, 0.25 * s, (x.y - y.x) / s);
    }
    return normalize(q);
}

// The space the particles of an emitter are in: that of the system (local)
// or the world, both in Unreal's centimetres.
struct Niagara_Space { bool local; float4x4 to_world; float4x4 to_local; };
Niagara_Space niagara_space(Mirai_Vfx_Context ctx, bool local) {
    Niagara_Space w;
    w.local = local;
    w.to_world = niagara_local_to_world(ctx.world);
    w.to_local = niagara_inverse(w.to_world);
    return w;
}

// The matrix that takes a point of Unreal (centimetres) to one of Mirai.
float4x4 niagara_to_mirai() {
    return float4x4(float4(0.0, -0.01, 0.0, 0.0), float4(0.0, 0.0, 0.01, 0.0), float4(0.01, 0.0, 0.0, 0.0), float4(0.0, 0.0, 0.0, 1.0));
}

Niagara_View niagara_view() {
    Mirai_Vfx_View v = mirai_vfx_view();
    Niagara_View n = (Niagara_View)0;
    // Unreal multiplies row vectors: clip = mul(float4(p, 1), WorldToClip).
    n.WorldToClip.M = transpose(mul(v.view_projection, niagara_to_mirai()));
    n.ClipToWorld.M = niagara_inverse(n.WorldToClip.M);
    n.TranslatedWorldToClip = n.WorldToClip.M;
    n.ScreenPositionScaleBias = float4(0.5, -0.5, 0.5, 0.5);
    n.ViewForward = niagara_direction(v.forward);
    n.ViewOrigin = niagara_point(v.position);
    n.WorldCameraOrigin.Tile = float3(0.0);
    n.WorldCameraOrigin.Offset = n.ViewOrigin;
    n.ViewSizeAndInvSize = float4(v.resolution, 1.0 / max(v.resolution, float2(1.0)));
    n.BufferSizeAndInvSize = n.ViewSizeAndInvSize;
    return n;
}

void AcquireID(int dataset, out int index, out int tag) { index = niagara_id.x; tag = niagara_id.y; }
void UpdateID(int dataset, int index, int instance) {}

// The index of a spawning particle among those born this frame, as ExecIndex
// counts them (TotalSpawnedParticles plus it is its unique id); of another,
// its slot in the range of its emitter, which readers of particles take.
uint niagara_exec_index(Mirai_Vfx_Context ctx) {
    return ctx.birth != 0xFFFFFFFFu ? ctx.birth - ctx.born : mirai_vfx_particle_id(ctx).x;
}

// The state a script starts with: its thread and random streams.
void niagara_begin(Mirai_Vfx_Context ctx, uint linear, uint3 dispatch) {
    niagara_ctx = ctx;
    View = niagara_view();
    PrimaryView = View;
    if (ctx.particle != 0xFFFFFFFFu) niagara_id = int2(mirai_vfx_particle_id(ctx));
    // A thread over particles counts them by their slot, as ExecIndex does.
    if (ctx.particle != 0xFFFFFFFFu && ctx.birth == 0xFFFFFFFFu) linear = uint(niagara_id.x);
    GLinearThreadId = linear;
    GDispatchThreadId = dispatch;
    GGroupThreadId = uint3(0u);
    GGPUExecIndex = int(linear);
    GSpawnStartInstance = 0u;
    EmitterTickCounter = uint(ctx.time * 60.0);
    GEmitterTickCounter = EmitterTickCounter;
    GRandomSeedOffset = 0u;
    RandomCounterDeterministic = 0;
    RandomCounterNonDeterministic = -1;
    Emitter_SpawnInterval = 0.0;
    Emitter_InterpSpawnStartDt = 0.0;
    Emitter_SpawnGroup = 0;
    Engine_ExecutionCount = int(ctx.spawned);
    niagara_spawn_dropped = false;
}

// A condition of ENiagaraConditionalOperator: Equals, NotEqual, LessThan,
// LessThanOrEqual, GreaterThan, GreaterThanOrEqual.
bool niagara_compare(uint op, float a, float b) {
    switch (op) {
    case 0u: return a == b;
    case 1u: return a != b;
    case 2u: return a < b;
    case 3u: return a <= b;
    case 4u: return a > b;
    case 5u: return a >= b;
    }
    return false;
}
bool niagara_compare(uint op, int a, int b) {
    switch (op) {
    case 0u: return a == b;
    case 1u: return a != b;
    case 2u: return a < b;
    case 3u: return a <= b;
    case 4u: return a > b;
    case 5u: return a >= b;
    }
    return false;
}

void EnterStatScope(int scope) {}
void ExitStatScope() {}

float4 ModuloPrecise(float4 x, float4 y) { return x - y * trunc(x / y); }
float3 ModuloPrecise(float3 x, float3 y) { return x - y * trunc(x / y); }
float2 ModuloPrecise(float2 x, float2 y) { return x - y * trunc(x / y); }
float ModuloPrecise(float x, float y) { return x - y * trunc(x / y); }
int ModuloPrecise(int x, int y) { return x - y * (x / y); }
int Modulo(int x, int y) { return x - y * (x / y); }
// The integer division of the VectorVM: by zero is zero, the smallest int by -1 the largest.
int niagara_vm_divi(int a, int b) { return b == 0 ? 0 : (b == -1 && a == int(0x80000000u) ? 0x7fffffff : a / b); }
float4 Modulo(float4 x, float4 y) { return fmod(x, y); }
float3 Modulo(float3 x, float3 y) { return fmod(x, y); }
float2 Modulo(float2 x, float2 y) { return fmod(x, y); }
float Modulo(float x, float y) { return fmod(x, y); }
float4 Reciprocal(float4 x) { return 1.0 / x; }
float3 Reciprocal(float3 x) { return 1.0 / x; }
float2 Reciprocal(float2 x) { return 1.0 / x; }
float Reciprocal(float x) { return 1.0 / x; }
bool NiagaraAll(bool b) { return b; }
bool NiagaraAny(bool b) { return b; }
bool NiagaraAll(bool2 b) { return all(b); }
bool NiagaraAll(bool3 b) { return all(b); }
bool NiagaraAll(bool4 b) { return all(b); }
bool NiagaraAny(bool2 b) { return any(b); }
bool NiagaraAny(bool3 b) { return any(b); }
bool NiagaraAny(bool4 b) { return any(b); }
float length2(float2 v) { return dot(v, v); }
float length2(float3 v) { return dot(v, v); }
float length2(float4 v) { return dot(v, v); }

int ExecIndex() { return GGPUExecIndex; }

float NiagaraInternalNoise(uint u, uint v, uint s) {
    uint seed = (u * 1664525u + v) + s + GRandomSeedOffset;
    GRandomSeedOffset += seed;
    return float(Rand3DPCG32(int3(int(u), int(v), int(seed))).x) / 4294967296.0;
}

float4 rand4(int seed1, int seed2, int seed3, int seed4) {
    int4 v = int4(seed4, seed1, seed2, seed3) * 1664525 + 1013904223;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    return float4((v >> 8) & 0x00ffffff) / 16777216.0;
}

float3 rand3(int seed1, int seed2, int seed3, int seed4) {
    int3 v = int3(seed1, seed2, seed4 | (seed3 << 16)) * 1664525 + 1013904223;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return float3((v >> 8) & 0x00ffffff) / 16777216.0;
}

float rand(float x, int s1, int s2, int s3) { RandomCounterDeterministic += 1; return rand3(s1, s2, s3, RandomCounterDeterministic).x * x; }
float2 rand(float2 x, int s1, int s2, int s3) { RandomCounterDeterministic += 1; return rand3(s1, s2, s3, RandomCounterDeterministic).xy * x; }
float3 rand(float3 x, int s1, int s2, int s3) { RandomCounterDeterministic += 1; return rand3(s1, s2, s3, RandomCounterDeterministic).xyz * x; }
float4 rand(float4 x, int s1, int s2, int s3) { RandomCounterDeterministic += 1; return rand4(s1, s2, s3, RandomCounterDeterministic) * x; }
int rand(int x, int s1, int s2, int s3) { RandomCounterDeterministic += 1; return int(rand3(s1, s2, s3, RandomCounterDeterministic).x * float(x + 1)); }

float rand(float x) { RandomCounterNonDeterministic -= 1; return rand4(int(GLinearThreadId), int(EmitterTickCounter), int(GLinearThreadId), RandomCounterNonDeterministic).x * x; }
float2 rand(float2 x) { RandomCounterNonDeterministic -= 1; return rand4(int(GLinearThreadId), int(EmitterTickCounter), int(GLinearThreadId), RandomCounterNonDeterministic).xy * x; }
float3 rand(float3 x) { RandomCounterNonDeterministic -= 1; return rand4(int(GLinearThreadId), int(EmitterTickCounter), int(GLinearThreadId), RandomCounterNonDeterministic).xyz * x; }
float4 rand(float4 x) { RandomCounterNonDeterministic -= 1; return rand4(int(GLinearThreadId), int(EmitterTickCounter), int(GLinearThreadId), RandomCounterNonDeterministic) * x; }
int rand(int x) { RandomCounterNonDeterministic -= 1; return int(rand4(int(GLinearThreadId), int(EmitterTickCounter), int(GLinearThreadId), RandomCounterNonDeterministic).x * float(x + 1)); }

int hash_single(int a) {
    int x = (a ^ 61) ^ (a >> 16);
    x += x << 3;
    x ^= x >> 4;
    x *= 0x27d4eb2d;
    x ^= x >> 15;
    return x;
}
int hash(int a, int b) { return hash_single(a) ^ hash_single(b * 31); }
float hash_float(int a, int b) { return float(hash(a, b) & 0x00ffffff) / 16777216.0; }
float hash_float(float a, int b) { return float(hash(int(a * 16777216.0), b) & 0x00ffffff) / 16777216.0; }

float rand_float(float x) { return rand(x); }
float2 rand_float(float2 x) { return float2(rand_float(x.x), rand_float(x.y)); }
float3 rand_float(float3 x) { return float3(rand_float(x.x), rand_float(x.y), rand_float(x.z)); }
float4 rand_float(float4 x) { return float4(rand_float(x.x), rand_float(x.y), rand_float(x.z), rand_float(x.w)); }
int rand_int(int x) { return int(rand_float(float(x))); }
float rand_float(float x, int s1, int s2, int s3) { return rand(x, s1, s2, s3); }
float2 rand_float(float2 x, int s1, int s2, int s3) { return rand(x, s1, s2, s3); }
float3 rand_float(float3 x, int s1, int s2, int s3) { return rand(x, s1, s2, s3); }
float4 rand_float(float4 x, int s1, int s2, int s3) { return rand(x, s1, s2, s3); }
int rand_int(int x, int s1, int s2, int s3) { return rand(x - 1, s1, s2, s3); }

float4 NiagaraQuatSLerp(float4 q1, float4 q2, float slerp) {
    float raw = dot(q1, q2);
    float cosom = abs(raw);
    float scale0, scale1;
    if (cosom < 0.9999) {
        float omega = acos(cosom);
        float inv = 1.0 / sin(omega);
        scale0 = sin((1.0 - slerp) * omega) * inv;
        scale1 = sin(slerp * omega) * inv;
    } else {
        scale0 = 1.0 - slerp;
        scale1 = slerp;
    }
    scale1 = raw >= 0.0 ? scale1 : -scale1;
    return scale0 * q1 + scale1 * q2;
}

float4 NiagaraGPU_QuatMul(float4 q1, float4 q2) {
    float4 q;
    q.x = q1.w * q2.x + q1.x * q2.w + q1.y * q2.z - q1.z * q2.y;
    q.y = q1.w * q2.y - q1.x * q2.z + q1.y * q2.w + q1.z * q2.x;
    q.z = q1.w * q2.z + q1.x * q2.y - q1.y * q2.x + q1.z * q2.w;
    q.w = q1.w * q2.w - q1.x * q2.x - q1.y * q2.y - q1.z * q2.z;
    return q;
}

struct NiagaraRandInfo { int Seed1; int Seed2; int Seed3; };
NiagaraRandInfo MakeRandInfo() {
    GRandomSeedOffset += 1664525u;
    NiagaraRandInfo r;
    r.Seed1 = int(GLinearThreadId);
    r.Seed2 = int(GRandomSeedOffset);
    r.Seed3 = int(GEmitterTickCounter);
    return r;
}
float NiagaraRandomFloat(NiagaraRandInfo r) {
    return uint(r.Seed3) == 0xffffffffu ? NiagaraInternalNoise(uint(r.Seed1), uint(r.Seed2), uint(r.Seed3)) : rand(1.0, r.Seed1, r.Seed2, r.Seed3);
}
int NiagaraRandomInt(NiagaraRandInfo r, int range) { return int(floor(float(range) * NiagaraRandomFloat(r))); }
float3 NiagaraRandomBaryCoord(NiagaraRandInfo r) {
    float2 v = float2(NiagaraRandomFloat(r), NiagaraRandomFloat(r));
    float a = sqrt(v.x);
    return float3(1.0 - a, a * (1.0 - v.y), v.y * a);
}

// The cells of a grid resource, and a float of a cell by its index among
// the floats of the cell: from what the stage before left, or what this one
// leaves. Unit coordinates sample it between the middles of its cells,
// clamped to them; an axis of one cell takes it whole.
int3 niagara_grid_cells(uint r) { return max(mirai_vfx_grid(niagara_ctx, r).cells, int3(1)); }
float niagara_grid_load(uint r, int3 cell, int f, bool written) {
    Mirai_Vfx_Grid g = mirai_vfx_grid(niagara_ctx, r);
    return asfloat(mirai_vfx_grid_word_load(niagara_ctx, r, g.first + cell, uint(max(f, 0)), written));
}
void niagara_grid_store(uint r, int3 cell, int f, float value) {
    Mirai_Vfx_Grid g = mirai_vfx_grid(niagara_ctx, r);
    mirai_vfx_grid_word_store(niagara_ctx, r, g.first + cell, uint(max(f, 0)), asuint(value));
}
float4 niagara_grid_load4(uint r, int3 cell, bool written) {
    Mirai_Vfx_Grid g = mirai_vfx_grid(niagara_ctx, r);
    return written ? mirai_vfx_grid_load_written(niagara_ctx, r, g.first + cell, 0u) : mirai_vfx_grid_load(niagara_ctx, r, g.first + cell, 0u);
}
void niagara_grid_write4(uint r, int3 cell, float4 value) {
    Mirai_Vfx_Grid g = mirai_vfx_grid(niagara_ctx, r);
    mirai_vfx_grid_write(niagara_ctx, r, g.first + cell, 0u, value);
}
float niagara_grid_sample(uint r, float3 unit, int f) {
    int3 cells = niagara_grid_cells(r);
    float3 at = unit * float3(cells) - 0.5;
    int3 low = int3(floor(at));
    float3 along = at - float3(low);
    float sum = 0.0;
    for (uint corner = 0u; corner < 8u; corner++) {
        int3 side = int3(corner & 1u, (corner >> 1u) & 1u, corner >> 2u);
        float3 weights = lerp(1.0 - along, along, float3(side));
        if (cells.z == 1) weights.z = side.z == 0 ? 1.0 : 0.0;
        if (cells.y == 1) weights.y = side.y == 0 ? 1.0 : 0.0;
        float weight = weights.x * weights.y * weights.z;
        if (weight <= 0.0) continue;
        sum += weight * niagara_grid_load(r, clamp(low + side, int3(0), cells - 1), f, false);
    }
    return sum;
}

// A word of a cell of a grid by the linear index of the cell (x first).
int3 niagara_cell_of(uint r, int linear) {
    int3 n = niagara_grid_cells(r);
    return int3(linear % n.x, (linear / n.x) % n.y, linear / (n.x * n.y));
}
uint niagara_cell_word(uint r, int linear, int word, bool written) {
    if (linear < 0) return 0u;
    Mirai_Vfx_Grid g = mirai_vfx_grid(niagara_ctx, r);
    return mirai_vfx_grid_word_load(niagara_ctx, r, g.first + niagara_cell_of(r, linear), uint(word), written);
}
void niagara_cell_store(uint r, int linear, int word, uint value) {
    if (linear < 0) return;
    Mirai_Vfx_Grid g = mirai_vfx_grid(niagara_ctx, r);
    mirai_vfx_grid_word_store(niagara_ctx, r, g.first + niagara_cell_of(r, linear), uint(word), value);
}
uint niagara_cell_add(uint r, int linear, int word, uint value) {
    if (linear < 0) return 0u;
    Mirai_Vfx_Grid g = mirai_vfx_grid(niagara_ctx, r);
    return mirai_vfx_grid_word_add(niagara_ctx, r, g.first + niagara_cell_of(r, linear), uint(word), value);
}

// The particles of another emitter (a resource of kind emitter): the slot of
// one by its index, or by its id when tag is not -1 (the seed of the
// particle); -1 when it is not alive.
// An id of a particle not started when it was given (GetIDAtSpawnIndex)
// keeps its birth, as -2 - birth; its slot is looked up while it lives.
int niagara_read_slot(uint r, int index, int tag) {
    Mirai_Vfx_Particle p;
    if (index <= -2) {
        uint seed;
        int slot = mirai_vfx_emitter_birth(niagara_ctx, r, uint(-2 - index), seed);
        return tag == -1 || int(seed) == tag ? slot : -1;
    }
    if (index < 0 || !mirai_vfx_emitter_particle(niagara_ctx, r, uint(index), p)) return -1;
    if (tag != -1 && int(p.seed) != tag) return -1;
    return index;
}
int niagara_read_seed(uint r, int slot) {
    Mirai_Vfx_Particle p;
    return slot >= 0 && mirai_vfx_emitter_particle(niagara_ctx, r, uint(slot), p) ? int(p.seed) : -1;
}
uint niagara_read_word(uint r, int slot, int word) {
    return slot >= 0 ? mirai_vfx_emitter_word(niagara_ctx, r, uint(slot), uint(word)) : 0u;
}
float3 niagara_read_position(uint r, int slot, bool local) {
    Mirai_Vfx_Particle p;
    if (slot < 0 || !mirai_vfx_emitter_particle(niagara_ctx, r, uint(slot), p)) return float3(0.0);
    float3 at = niagara_point(p.position);
    return local ? mul(float4(at, 1.0), niagara_inverse(niagara_local_to_world(niagara_ctx.world))).xyz : at;
}
float3 niagara_read_velocity(uint r, int slot, bool local) {
    Mirai_Vfx_Particle p;
    if (slot < 0 || !mirai_vfx_emitter_particle(niagara_ctx, r, uint(slot), p)) return float3(0.0);
    float3 v = niagara_vector(p.velocity);
    return local ? mul(float4(v, 0.0), niagara_inverse(niagara_local_to_world(niagara_ctx.world))).xyz : v;
}

// The curl of the simplex noise of Unreal that Niagara's curl noise samples.
float3 niagara_curl_noise(float3 p) {
    float3x4 j = JacobianSimplex_ALU(p, false, 1.0);
    return float3(j[1][2] - j[2][1], j[2][0] - j[0][2], j[0][1] - j[1][0]);
}

#endif

// Niagara's FastPathLibrary: what scripts call by its name.
void FastPathDot4_FastPathLibrary(float4 A, float4 B, out float Value) { Value = dot(A, B); }
void FastPathTransformPosition_FastPathLibrary(float4x4 Mat, float3 Position, out float3 PositionTransformed) {
    PositionTransformed = mul(float4(Position, 1.0), Mat).xyz;
}
void FastMatrixToQuaternion_FastPathLibrary(float4x4 Mat, out float4 Quat) {
    float tr = Mat[0][0] + Mat[1][1] + Mat[2][2];
    if (tr > 0.0f) {
        float InvS = rsqrt(tr + 1.f);
        float s = 0.5f * InvS;
        Quat.x = (Mat[1][2] - Mat[2][1]) * s;
        Quat.y = (Mat[2][0] - Mat[0][2]) * s;
        Quat.z = (Mat[0][1] - Mat[1][0]) * s;
        Quat.w = 0.5f * rcp(InvS);
    } else if ((Mat[0][0] > Mat[1][1]) && (Mat[0][0] > Mat[2][2])) {
        float s = Mat[0][0] - Mat[1][1] - Mat[2][2] + 1.0f;
        float InvS = rsqrt(s);
        s = 0.5f * InvS;
        Quat.x = 0.5f * rcp(InvS);
        Quat.y = (Mat[0][1] + Mat[1][0]) * s;
        Quat.z = (Mat[0][2] + Mat[2][0]) * s;
        Quat.w = (Mat[1][2] - Mat[2][1]) * s;
    } else if (Mat[1][1] > Mat[2][2]) {
        float s = Mat[1][1] - Mat[2][2] - Mat[0][0] + 1.0f;
        float InvS = rsqrt(s);
        s = 0.5f * InvS;
        Quat.x = (Mat[1][0] + Mat[0][1]) * s;
        Quat.y = 0.5f * rcp(InvS);
        Quat.z = (Mat[1][2] + Mat[2][1]) * s;
        Quat.w = (Mat[2][0] - Mat[0][2]) * s;
    } else {
        float s = Mat[2][2] - Mat[0][0] - Mat[1][1] + 1.0f;
        float InvS = rsqrt(s);
        s = 0.5f * InvS;
        Quat.x = (Mat[2][0] + Mat[0][2]) * s;
        Quat.y = (Mat[2][1] + Mat[1][2]) * s;
        Quat.z = 0.5f * rcp(InvS);
        Quat.w = (Mat[0][1] - Mat[1][0]) * s;
    }
}
uint CalcLFSRValue(uint Seed, uint NumUniqueValues, int Iterations, uint4 Taps, uint Mask) {
    uint NextValue = (Seed + 1) & Mask;
    for (int i = 0; i < Iterations; i++) {
        do {
            uint Tap = 0;
            Tap ^= (Taps.x & NextValue) == 0 ? 0 : 1;
            Tap ^= (Taps.y & NextValue) == 0 ? 0 : 1;
            Tap ^= (Taps.z & NextValue) == 0 ? 0 : 1;
            Tap ^= (Taps.w & NextValue) == 0 ? 0 : 1;
            NextValue = (((NextValue << 1) | Tap) & Mask);
        } while (NextValue > NumUniqueValues);
    }
    return NextValue - 1;
}
void FastUniqueRandom_FastPathLibrary(int Seed, int NumUniqueValues, int Iterations, out int Result) {
    if (NumUniqueValues < 2) NumUniqueValues = 2;
    Seed %= NumUniqueValues;
    uint4 Taps;
    uint Mask;
    if (NumUniqueValues < 16) { Taps = uint4(1 << 3, 1 << 2, 0, 0); Mask = 0xF; }
    else if (NumUniqueValues < 256) { Taps = uint4(1 << 7, 1 << 5, 1 << 4, 1 << 3); Mask = 0xFF; }
    else if (NumUniqueValues < 4096) { Taps = uint4(1 << 11, 1 << 10, 1 << 7, 1 << 5); Mask = 0xFFF; }
    else if (NumUniqueValues < 65536) { Taps = uint4(1 << 15, 1 << 13, 1 << 12, 1 << 10); Mask = 0xFFFF; }
    else if (NumUniqueValues < 1048576) { Taps = uint4(1 << 19, 1 << 16, 0, 0); Mask = 0xFFFFF; }
    else { Taps = uint4(1 << 23, 1 << 22, 1 << 20, 1 << 19); Mask = 0xFFFFFF; }
    Result = int(CalcLFSRValue(uint(Seed), uint(NumUniqueValues), Iterations, Taps, Mask));
}

// CollisionQuery: the depth of the
// first view of the window where a point of Unreal falls, the point there and
// its normal, in the space of Unreal; a depth of -1 outside the view.
void niagara_query_scene_depth(float3 at, out float depth, out float3 camera, out bool inside, out float3 world, out float3 normal) {
    Mirai_Vfx_View v = mirai_vfx_view();
    depth = -1.0;
    world = float3(0.0);
    normal = float3(0.0, 0.0, 1.0);
    camera = niagara_point(v.position);
    float4 clip = mul(v.view_projection, float4(mirai_point(at), 1.0));
    float2 ndc = clip.xy / max(clip.w, 1e-6);
    inside = clip.w > 0.0 && all(abs(ndc) <= float2(1.0));
    if (!inside) return;
    float2 uv = ndc * float2(0.5, -0.5) + 0.5;
    float linear = mirai_vfx_scene_depth(uv);
    if (!(linear > 0.0)) return;
    // Along the ray of the pixel, to the depth it keeps.
    float4 far = mul(v.inverse_view_projection, float4(ndc, 1.0, 1.0));
    float3 ray = normalize(far.xyz / far.w - v.position);
    float3 p = v.position + ray * (linear / max(dot(ray, v.forward), 1e-4));
    depth = linear * 100.0;
    world = niagara_point(p);
    normal = niagara_direction(mirai_vfx_scene_normal(uv));
}

// The distance to the nearest surface of the scene and its gradient, as the
// global distance field gives them, from rays traced every way (decisions of
// mirai-imports): the nearest hit is the distance, its normal the gradient,
// negative inside a closed mesh. Beyond NIAGARA_FIELD_REACH it is that far.
#define NIAGARA_FIELD_REACH 4.0
#define NIAGARA_FIELD_RAYS 14
void niagara_query_distance(float3 at, out float distance, out float3 gradient, out bool valid) {
    static const float3 rays[NIAGARA_FIELD_RAYS] = {
        float3(1, 0, 0), float3(-1, 0, 0), float3(0, 1, 0), float3(0, -1, 0), float3(0, 0, 1), float3(0, 0, -1),
        float3(0.57735, 0.57735, 0.57735), float3(-0.57735, 0.57735, 0.57735), float3(0.57735, -0.57735, 0.57735), float3(-0.57735, -0.57735, 0.57735),
        float3(0.57735, 0.57735, -0.57735), float3(-0.57735, 0.57735, -0.57735), float3(0.57735, -0.57735, -0.57735), float3(-0.57735, -0.57735, -0.57735)};
    float3 p = mirai_point(at);
    float nearest = NIAGARA_FIELD_REACH;
    float3 n = float3(0.0, 0.0, 0.0);
    bool behind = false;
    for (int i = 0; i < NIAGARA_FIELD_RAYS; i++) {
        Mirai_Vfx_Hit h = mirai_vfx_trace(niagara_ctx, p, rays[i], nearest);
        if (!h.hit || h.distance >= nearest) continue;
        nearest = h.distance;
        n = h.inside ? -h.normal : h.normal;
        behind = h.inside;
    }
    distance = (behind ? -nearest : nearest) * 100.0;
    gradient = nearest < NIAGARA_FIELD_REACH ? niagara_direction(n) : float3(0.0, 0.0, 0.001);
    valid = true;
}

// The iteration of a simulation stage; a stage loops once.
int SimulationStage_GetNumIterations() { return int(niagara_stage_iterations); }
int SimulationStage_GetIterationIndex() { return int(niagara_stage_iteration); }
int SimulationStage_GetNumLoops() { return 1; }
int SimulationStage_GetLoopIndex() { return 0; }
float SimulationStage_GetNormalizedIterationIndex() { return float(SimulationStage_GetIterationIndex()) / float(max(SimulationStage_GetNumIterations(), 1) - 1); }
float SimulationStage_GetNormalizedLoopIndex() { return float(SimulationStage_GetLoopIndex()) / float(max(SimulationStage_GetNumLoops(), 1) - 1); }

// VectorField: a field of vectors baked into a grid of one cell a texel
// (niagara_vector_fields.odin), sampled between its texels over its bounds,
// wrapping along the axes it tiles.
// A texture baked into a grid flat along y, one texel a cell (rows along z):
// bilinear at uv between texels, repeating.
float4 niagara_texture_sample(uint r, float2 uv) {
    Mirai_Vfx_Grid g = mirai_vfx_grid(niagara_ctx, r);
    int2 n = max(g.cells.xz, int2(1));
    float2 p = uv * float2(n) - 0.5;
    int2 i0 = int2(floor(p));
    float2 f = p - float2(i0);
    float4 sum = float4(0.0);
    for (int k = 0; k < 4; k++) {
        int2 side = int2(k & 1, k >> 1);
        int2 corner = ((i0 + side) % n + n) % n;
        float2 w = lerp(1.0 - f, f, float2(side));
        sum += w.x * w.y * mirai_vfx_grid_load(niagara_ctx, r, g.first + int3(corner.x, 0, corner.y), 0u);
    }
    return sum;
}

float3 niagara_field_sample(uint r, float3 at, float3 low, float3 high, bool3 tile) {
    Mirai_Vfx_Grid g = mirai_vfx_grid(niagara_ctx, r);
    int3 n = max(g.cells, int3(1));
    float3 p = (at - low) / max(high - low, float3(1e-4)) * float3(n) - 0.5;
    int3 i0 = int3(floor(p));
    float3 f = p - float3(i0);
    float3 sum = float3(0.0);
    for (int k = 0; k < 8; k++) {
        int3 corner = i0 + int3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
        for (int axis = 0; axis < 3; axis++) {
            corner[axis] = tile[axis] ? ((corner[axis] % n[axis]) + n[axis]) % n[axis] : clamp(corner[axis], 0, n[axis] - 1);
        }
        float3 w = lerp(1.0 - f, f, float3(k & 1, (k >> 1) & 1, (k >> 2) & 1));
        sum += w.x * w.y * w.z * mirai_vfx_grid_load(niagara_ctx, r, g.first + corner, 0u).xyz;
    }
    return sum;
}
