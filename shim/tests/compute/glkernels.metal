// Compute kernels for the GL fragment path (tests/compute/glkernels.m). The first group must run as GL passes;
// the "cl_" group needs OpenCL (buffer writes, atomics, threadgroup memory, barriers, scattered writes).
#include <metal_stdlib>
using namespace metal;

kernel void fill(texture2d<float, access::write> out [[texture(0)]], constant float4 &color [[buffer(0)]],
                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    out.write(color, gid);
}

kernel void invert(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = src.read(gid);
    dst.write(float4(1.0 - c.rgb, c.a), gid);
}

kernel void inc(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                uint2 gid [[thread_position_in_grid]]) {
    dst.write(src.read(gid) + 1.0, gid);
}

// Box blur with a sampler: in a kernel, sample() has no derivatives and must read level 0.
kernel void blur3(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                  sampler s [[sampler(0)]], uint2 gid [[thread_position_in_grid]]) {
    float2 size = float2(dst.get_width(), dst.get_height());
    float4 acc = 0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
            acc += src.sample(s, (float2(gid) + 0.5 + float2(dx, dy)) / size);
    dst.write(acc / 9.0, gid);
}

// Writes only even columns: the odd ones must keep their previous contents.
kernel void stripes(texture2d<float, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x & 1) return;
    out.write(float4(0, 1, 0, 1), gid);
}

// Device buffer read (texture buffer in GL) and the threadgroup built-ins.
kernel void rows(texture2d<float, access::write> out [[texture(0)]], device const float4 *colors [[buffer(1)]],
                 uint2 gid [[thread_position_in_grid]], uint2 tg [[threadgroup_position_in_grid]],
                 uint2 lid [[thread_position_in_threadgroup]], uint2 tpg [[threads_per_threadgroup]]) {
    float4 c = colors[gid.y % 4];
    c.b = float(tg.x * tpg.x + lid.x == gid.x);
    out.write(c, gid);
}

kernel void count_u(texture2d<uint, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]],
                    uint2 grid [[threads_per_grid]]) {
    out.write(uint4(gid.x + gid.y * grid.x, 7, 0, 1), gid);
}

// --- need OpenCL
kernel void cl_buffer_write(device float *out [[buffer(0)]], uint gid [[thread_position_in_grid]]) { out[gid] = gid; }

kernel void cl_atomic(device atomic_uint *hist [[buffer(0)]], texture2d<float, access::read> src [[texture(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    atomic_fetch_add_explicit(&hist[uint(src.read(gid).r * 255.0)], 1, memory_order_relaxed);
}

kernel void cl_threadgroup(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]]) {
    threadgroup float tile[16][16];
    tile[lid.y][lid.x] = src.read(gid).r;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    dst.write(float4(tile[15 - lid.y][15 - lid.x]), gid);
}

kernel void cl_scatter(texture2d<float, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    out.write(float4(1), uint2(gid.y, gid.x));
}
