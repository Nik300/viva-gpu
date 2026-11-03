// Translation corpus: constructs common in real apps (Apple samples, naga/wgpu output, games).
#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

// --- Apple "Hello Triangle": vertex pulling from a constant pointer + vertex_id ---
typedef struct { vector_float2 position; vector_float4 color; } AAPLVertex;
struct RasterizerData { float4 position [[position]]; float4 color; };
vertex RasterizerData apple_vertex(uint vertexID [[vertex_id]], constant AAPLVertex *vertices [[buffer(0)]],
                                   constant vector_uint2 *viewportSizePointer [[buffer(1)]]) {
    RasterizerData out;
    float2 pixelSpacePosition = vertices[vertexID].position.xy;
    vector_float2 viewportSize = vector_float2(*viewportSizePointer);
    out.position = vector_float4(0.0, 0.0, 0.0, 1.0);
    out.position.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.color = vertices[vertexID].color;
    return out;
}
fragment float4 apple_fragment(RasterizerData in [[stage_in]]) { return in.color; }

// --- Apple textured quad: half textures, constexpr sampler, half4 output ---
struct TexData { float4 position [[position]]; float2 textureCoordinate; };
fragment half4 apple_textured(TexData in [[stage_in]], texture2d<half> colorTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    const half4 colorSample = colorTexture.sample(textureSampler, in.textureCoordinate);
    return colorSample;
}

// --- naga / wgpu style (egui) ---
struct Locals { metal::float2 screen_size; uint _pad0; uint _pad1; };
metal::float3 linear_from_gamma_rgb(metal::float3 srgb) {
    metal::bool3 cutoff = srgb < metal::float3(0.04045);
    metal::float3 lower = srgb / metal::float3(12.92);
    metal::float3 higher = metal::pow((srgb + metal::float3(0.055)) / metal::float3(1.055), metal::float3(2.4));
    return metal::select(higher, lower, cutoff);
}
metal::float4 unpack_color(uint color) {
    return metal::float4(static_cast<float>(color & 255u), static_cast<float>((color >> 8u) & 255u),
                         static_cast<float>((color >> 16u) & 255u), static_cast<float>((color >> 24u) & 255u)) / metal::float4(255.0);
}
struct vs_mainInput { metal::float2 a_pos [[attribute(0)]]; metal::float2 a_tex_coord [[attribute(1)]]; uint a_color [[attribute(2)]]; };
struct vs_mainOutput { metal::float2 tex_coord [[user(loc0), center_perspective]]; metal::float4 color [[user(loc1), center_perspective]]; metal::float4 position [[position]]; };
vertex vs_mainOutput naga_vs_main(vs_mainInput varyings [[stage_in]], constant Locals& r_locals [[buffer(1)]]) {
    const auto a_pos = varyings.a_pos; const auto a_tex_coord = varyings.a_tex_coord; const auto a_color = varyings.a_color;
    metal::float4 _e3 = unpack_color(a_color);
    metal::float3 _e5 = linear_from_gamma_rgb(_e3.xyz);
    metal::float4 position = metal::float4(((2.0 * a_pos.x) / r_locals.screen_size.x) - 1.0, 1.0 - ((2.0 * a_pos.y) / r_locals.screen_size.y), 0.0, 1.0);
    const auto _tmp = vs_mainOutput {a_tex_coord, metal::float4(_e5, _e3.w), position};
    return vs_mainOutput { _tmp.tex_coord, _tmp.color, _tmp.position };
}
struct fs_mainInput { metal::float2 tex_coord [[user(loc0), center_perspective]]; metal::float4 color [[user(loc1), center_perspective]]; };
struct fs_mainOutput { metal::float4 member [[color(0)]]; };
fragment fs_mainOutput naga_fs_main(fs_mainInput varyings_1 [[stage_in]], metal::float4 position [[position]],
                                    metal::texture2d<float, metal::access::sample> r_tex_color [[texture(0)]],
                                    metal::sampler r_tex_sampler [[sampler(0)]]) {
    metal::float4 tex_linear = r_tex_color.sample(r_tex_sampler, varyings_1.tex_coord);
    metal::float4 out_color = varyings_1.color * tex_linear;
    if (out_color.w < 0.001) { metal::discard_fragment(); }
    return fs_mainOutput { out_color };
}

// --- Layout corner cases: half, packed_float3, array inside a struct, uint math ---
struct Material { packed_float3 albedo; float roughness; half4 tint; float weights[4]; uint flags; };
struct LayoutOut { float4 pos [[position]]; float3 c; };
vertex LayoutOut layout_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], device const Material *mats [[buffer(2)]],
                               device const packed_float3 *positions [[buffer(3)]]) {
    Material m = mats[iid];
    float3 p = positions[vid];
    LayoutOut o;
    o.pos = float4(p * m.roughness, 1);
    float w = 0;
    for (int i = 0; i < 4; i++) w += m.weights[i];
    o.c = m.albedo * float3(m.tint.rgb) * w + float((m.flags >> 3) % 5u) + float(vid / 3u);
    return o;
}

// --- Control flow: switch, while/break, local arrays, constant tables ---
constant float kGauss[5] = { 0.06, 0.24, 0.4, 0.24, 0.06 };
fragment float4 control_flow(LayoutOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                             constant int &mode [[buffer(0)]]) {
    float4 acc = 0;
    float local[8];
    for (int i = 0; i < 8; i++) local[i] = float(i) * in.c.x;
    switch (mode) {
        case 0: acc = float4(1, 0, 0, 1); break;
        case 1: for (int i = -2; i <= 2; i++) acc += t.sample(s, in.c.xy + float2(i, 0) * 0.01) * kGauss[i + 2]; break;
        case 2: { int k = 0; while (true) { acc.x += local[k & 7]; if (acc.x > 4.0 || ++k > 100) break; } break; }
        default: acc = float4(in.c, 1);
    }
    return acc;
}

// --- MRT + depth output, point sprites ---
struct GBuffer { float4 albedo [[color(0)]]; half4 normal [[color(1)]]; uint4 ids [[color(2)]]; float depth [[depth(any)]]; };
fragment GBuffer gbuffer(LayoutOut in [[stage_in]], bool front [[front_facing]]) {
    GBuffer g;
    g.albedo = float4(in.c, 1);
    g.normal = half4(front ? 1.0h : -1.0h);
    g.ids = uint4(uint(in.pos.x), uint(in.pos.y), 7, 9);
    g.depth = in.pos.z * 0.5;
    return g;
}
struct PointOut { float4 pos [[position]]; float size [[point_size]]; };
vertex PointOut point_vertex(uint vid [[vertex_id]]) { PointOut o; o.pos = float4(float(vid) * 0.1, 0, 0, 1); o.size = 8; return o; }
fragment float4 point_fragment(float2 pc [[point_coord]]) { return float4(pc, 0, 1); }
