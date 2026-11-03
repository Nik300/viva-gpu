// TeraScale Compute corpus (tests/compute/ctest.m): kernels that need OpenCL, each checked against a CPU reference.
#include <metal_stdlib>
using namespace metal;

kernel void vadd(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]], device float *c [[buffer(2)]],
                 uint gid [[thread_position_in_grid]]) {
    c[gid] = a[gid] + b[gid];
}

struct SaxpyParams { float a; uint n; };

// dispatchThreads with a grid that is not a multiple of the threadgroup: bounds come from the grid.
kernel void saxpy(device const float *x [[buffer(0)]], device float *y [[buffer(1)]], constant SaxpyParams &p [[buffer(2)]],
                  uint gid [[thread_position_in_grid]]) {
    if (gid >= p.n) return;
    y[gid] = p.a * x[gid] + y[gid];
}

// Threadgroup memory + barriers: one partial sum per threadgroup.
kernel void reduce_sum(device const float *in [[buffer(0)]], device float *out [[buffer(1)]],
                       uint gid [[thread_position_in_grid]], uint lid [[thread_index_in_threadgroup]],
                       uint tgid [[threadgroup_position_in_grid]], uint tgsize [[threads_per_threadgroup]]) {
    threadgroup float scratch[256];
    scratch[lid] = in[gid];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = tgsize / 2; s > 0; s >>= 1) {
        if (lid < s) scratch[lid] += scratch[lid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) out[tgid] = scratch[0];
}

// Dynamic threadgroup memory (setThreadgroupMemoryLength) and an exclusive prefix sum (Hillis-Steele).
kernel void scan_block(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], threadgroup uint *tmp [[threadgroup(0)]],
                       uint gid [[thread_position_in_grid]], uint lid [[thread_position_in_threadgroup]],
                       uint n [[threads_per_threadgroup]]) {
    tmp[lid] = lid > 0 ? in[gid - 1] : 0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint off = 1; off < n; off <<= 1) {
        uint v = lid >= off ? tmp[lid - off] : 0;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        tmp[lid] += v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    out[gid] = tmp[lid];
}

kernel void histogram(device const uchar *data [[buffer(0)]], device atomic_uint *bins [[buffer(1)]],
                      uint gid [[thread_position_in_grid]]) {
    atomic_fetch_add_explicit(&bins[data[gid]], 1, memory_order_relaxed);
}

// Local atomics, then one global atomic per bin and threadgroup; atomic min/max on signed ints.
kernel void histogram_local(device const uchar *data [[buffer(0)]], device atomic_uint *bins [[buffer(1)]],
                            device atomic_int *minmax [[buffer(2)]],
                            uint gid [[thread_position_in_grid]], uint lid [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint local[16];
    if (lid < 16) atomic_store_explicit(&local[lid], 0, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int v = int(data[gid]) - 100;
    atomic_fetch_add_explicit(&local[data[gid] & 15], 1, memory_order_relaxed);
    atomic_fetch_min_explicit(&minmax[0], v, memory_order_relaxed);
    atomic_fetch_max_explicit(&minmax[1], v, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lid < 16) atomic_fetch_add_explicit(&bins[lid], atomic_load_explicit(&local[lid], memory_order_relaxed), memory_order_relaxed);
}

kernel void float_atomic(device atomic_float *sum [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    atomic_fetch_add_explicit(sum, 0.5f, memory_order_relaxed);
}

// Struct buffers with float3 (16-byte stride), half data, integer math and control flow.
struct Particle { float3 pos; float3 vel; float life; uint flags; };
kernel void particles(device Particle *ps [[buffer(0)]], constant float &dt [[buffer(1)]], device half4 *colors [[buffer(2)]],
                      uint gid [[thread_position_in_grid]]) {
    Particle p = ps[gid];
    p.vel.y -= 9.8f * dt;
    p.pos += p.vel * dt;
    if (p.pos.y < 0) { p.pos.y = -p.pos.y; p.vel.y = -p.vel.y * 0.5f; p.flags |= 1u; }
    p.life = max(p.life - dt, 0.0f);
    ps[gid] = p;
    colors[gid] = half4(half3(p.life), half(1));
}

// Textures: read, sample with a sampler state, write; get_width/get_height.
kernel void blur_tex(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                     sampler s [[sampler(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 inv = 1.0 / float2(src.get_width(), src.get_height());
    float4 acc = 0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
            acc += src.sample(s, (float2(gid) + 0.5 + float2(dx, dy)) * inv);
    dst.write(acc / 9.0, gid);
}

// Texture -> buffer (luma), constexpr sampler.
kernel void luma(texture2d<float, access::sample> src [[texture(0)]], device float *out [[buffer(0)]],
                 uint2 gid [[thread_position_in_grid]], uint2 size [[threads_per_grid]]) {
    constexpr sampler nearest(coord::pixel, filter::nearest, address::clamp_to_edge);
    float4 c = src.sample(nearest, float2(gid) + 0.5);
    out[gid.y * size.x + gid.x] = dot(c.rgb, float3(0.299, 0.587, 0.114));
}

// Scattered texture writes (transpose) and an integer texture.
kernel void transpose_u(texture2d<uint, access::read> src [[texture(0)]], texture2d<uint, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    dst.write(src.read(gid) * 2u, uint2(gid.y, gid.x));
}

// Function constant: specialized at pipeline creation.
constant float scale [[function_constant(0)]];
kernel void scale_fc(device float *data [[buffer(0)]], uint gid [[thread_position_in_grid]]) { data[gid] *= scale; }

// 3D grid built-ins and the indirect dispatch argument layout.
kernel void grid3d(device uint *out [[buffer(0)]], uint3 gid [[thread_position_in_grid]], uint3 size [[threads_per_grid]],
                   uint3 tg [[threadgroup_position_in_grid]], uint3 ntg [[threadgroups_per_grid]]) {
    uint i = (gid.z * size.y + gid.y) * size.x + gid.x;
    out[i] = (tg.x + tg.y * ntg.x + tg.z * ntg.x * ntg.y) * 1000 + gid.x + gid.y * 10 + gid.z * 100;
}

// Math built-ins and a loop with a data-dependent trip count.
kernel void mathy(device const float4 *in [[buffer(0)]], device float4 *out [[buffer(1)]], device int *iters [[buffer(2)]],
                  uint gid [[thread_position_in_grid]]) {
    float4 v = in[gid];
    float4 r = sqrt(abs(v)) + sin(v) * cos(v) + exp2(clamp(v, -4.0f, 4.0f)) + fract(v) + floor(v) + pow(abs(v) + 1, 0.5f);
    r += mix(v, r, 0.25f) + step(0.5f, v) + smoothstep(0.0f, 1.0f, v) + rsqrt(abs(v) + 1) + fma(v, v, 1.0f);
    int n = 0;
    uint x = as_type<uint>(v.x) | 1u;
    while (x != 1 && n < 200) { x = (x & 1) ? 3 * x + 1 : x >> 1; n++; }
    iters[gid] = n + popcount(gid) + clz(gid + 1) + int(min(gid, 7u)) + abs(int(gid) - 50) / 3 + (int(gid) - 50) % 7;
    out[gid] = r;
}

// Needs simdgroup functions: rejected (no subgroups in OpenCL 1.2).
kernel void simd_sum(device const float *in [[buffer(0)]], device float *out [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    out[gid] = simd_sum(in[gid]);
}

// read_write texture: in OpenCL 1.2 a read view and a write view of the same image.
kernel void rw_double(texture2d<float, access::read_write> t [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    t.write(t.read(gid) * 2.0f, gid);
}

// Optimizations of docs/OTTIMIZZAZIONE-COMPUTE.md. is_null_texture (B5).
kernel void null_probe(texture2d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    out[gid] = is_null_texture(t) ? -1.0 : t.read(uint2(0, 0)).r;
}

// Per-axis addressing, sampler argument and constexpr sampler (B3).
kernel void sample_axes(texture2d<float, access::sample> t [[texture(0)]], sampler s [[sampler(0)]],
                        device const float2 *coords [[buffer(0)]], device float *out [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    constexpr sampler mixed(coord::normalized, filter::nearest, s_address::repeat, t_address::clamp_to_zero);
    out[gid * 2] = t.sample(s, coords[gid]).r;
    out[gid * 2 + 1] = t.sample(mixed, coords[gid]).r;
}

// Explicit mip level (B4): refused on a mipmapped texture, level 0 otherwise.
kernel void sample_level(texture2d<float, access::sample> t [[texture(0)]], device float *out [[buffer(0)]],
                         constant float &lod [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    constexpr sampler s(filter::nearest);
    out[gid] = t.sample(s, float2(0.5), level(lod)).r;
}

// setBytes on every dispatch (C1).
kernel void store_param(device uint *out [[buffer(0)]], constant uint2 &p [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    if (gid == 0) out[p.x] = p.y;
}

// Indirect arguments written by a kernel of the same run (D2); exact thread count of a rounded enqueue (C4).
kernel void write_indirect(device uint *args [[buffer(0)]], constant uint &groups [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    if (gid == 0) { args[0] = groups; args[1] = 1; args[2] = 1; }
}
kernel void count_threads(device atomic_uint *n [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    atomic_fetch_add_explicit(n, 1, memory_order_relaxed);
}
