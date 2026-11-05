// Test cases of the AIR -> Valhall ISA compiler and their runner (see isa_cases.h). Every case draws or dispatches a
// minimal pipeline whose shader exercises one feature of docs/ANALISI-ISA-DIRETTA-2026-11-04.md §4, and recomputes
// the same formula on the CPU. Inputs are deterministic functions of the texel / element index, shared by the setup
// (GPU resources) and the reference.
#import "isa_cases.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

#pragma clang diagnostic ignored "-Winitializer-overrides"   // table entries re-set .id after the FR()/CS() macros

@implementation ISAInputs
- (instancetype)init {
    if ((self = [super init])) {
        _buffers = [NSMutableDictionary dictionary];
        _textures = [NSMutableDictionary dictionary];
        _samplers = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

// ---- Helpers shared by setups and references --------------------------------------------------------------------------

#define PIX(c) for (int y = 0; y < (c)->h; y++) for (int x = 0; x < (c)->w; x++)
#define OUT(x, y) (out + ((size_t)(y) * c->w + (size_t)(x)) * 4)
static void set4(double *o, double a, double b, double cc, double d) { o[0] = a; o[1] = b; o[2] = cc; o[3] = d; }
static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }
static float h_round(float f) { return (float)(_Float16)f; }   // f32 -> f16 (round to nearest even) -> f32

// 16x16 RGBA8 pattern: (i * 16, j * 16, (i ^ j) * 16, 255).
static void t16(int i, int j, uint8_t p[4]) { p[0] = (uint8_t)(i * 16); p[1] = (uint8_t)(j * 16); p[2] = (uint8_t)((i ^ j) * 16); p[3] = 255; }
static void t16b(int i, int j, uint8_t p[4]) { p[0] = (uint8_t)((15 - j) * 16); p[1] = (uint8_t)(i * 16 + 8); p[2] = 128; p[3] = 255; }
static void tmip(int level, uint8_t p[4]) { p[0] = (uint8_t)(level * 50); p[1] = (uint8_t)(255 - level * 50); p[2] = (level & 1) ? 255 : 0; p[3] = 255; }
static float tdepth(int i, int j) { return (float)(i + j + 0.25) / 32.0f; }   // 16x16 Depth32Float

static id<MTLTexture> mktex(ISAInputs *in, MTLTextureType type, MTLPixelFormat f, int w, int h, int d, int mips, MTLTextureUsage u) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = type;
    td.pixelFormat = f;
    td.width = (NSUInteger)w;
    td.height = (NSUInteger)h;
    if (type == MTLTextureType3D) td.depth = (NSUInteger)d;
    else if (type == MTLTextureType2DArray) td.arrayLength = (NSUInteger)d;
    td.mipmapLevelCount = (NSUInteger)mips;
    td.usage = u;
    return [in.device newTextureWithDescriptor:td];
}

// 2D RGBA8 texture from a texel function (level 0) and, for mips > 1, tmip() colours for the other levels.
static id<MTLTexture> tex_rgba8(ISAInputs *in, int w, int h, int mips, void (*fn)(int, int, uint8_t *)) {
    id<MTLTexture> t = mktex(in, MTLTextureType2D, MTLPixelFormatRGBA8Unorm, w, h, 1, mips, MTLTextureUsageShaderRead);
    for (int l = 0; l < mips; l++) {
        int lw = MAX(w >> l, 1), lh = MAX(h >> l, 1);
        uint8_t *b = malloc((size_t)lw * lh * 4);
        for (int j = 0; j < lh; j++) for (int i = 0; i < lw; i++) {
            if (l == 0 && fn) fn(i, j, b + (j * lw + i) * 4); else tmip(l, b + (j * lw + i) * 4);
        }
        [t replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)lw, (NSUInteger)lh) mipmapLevel:(NSUInteger)l withBytes:b bytesPerRow:(NSUInteger)lw * 4];
        free(b);
    }
    return t;
}

static id<MTLTexture> tex_depth16(ISAInputs *in) {
    id<MTLTexture> t = mktex(in, MTLTextureType2D, MTLPixelFormatDepth32Float, 16, 16, 1, 1, MTLTextureUsageShaderRead);
    float b[256];
    for (int j = 0; j < 16; j++) for (int i = 0; i < 16; i++) b[j * 16 + i] = tdepth(i, j);
    [t replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:b bytesPerRow:64];
    return t;
}

static id<MTLSamplerState> smp(ISAInputs *in, bool linear, bool mips, MTLSamplerAddressMode a, MTLCompareFunction cmp) {
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.minFilter = d.magFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = mips ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterNotMipmapped;
    d.sAddressMode = d.tAddressMode = d.rAddressMode = a;
    d.compareFunction = cmp;
    return [in.device newSamplerStateWithDescriptor:d];
}

static id<MTLBuffer> buf(ISAInputs *in, const void *p, size_t n) {
    return p ? [in.device newBufferWithBytes:p length:n options:MTLResourceStorageModeShared]
             : [in.device newBufferWithLength:n options:MTLResourceStorageModeShared];
}

// ---- MSL plumbing -------------------------------------------------------------------------------------------------------

#define MSL_HEAD "#include <metal_stdlib>\nusing namespace metal;\n"
// Full-screen triangle; the fragment shaders take floor(p.xy) as the pixel (x, y).
#define FS_VS "struct V { float4 p [[position]]; };\n" \
    "vertex V vs(uint i [[vertex_id]]) { V v; float2 t = float2((i << 1) & 2, i & 2); v.p = float4(t * 2 - 1, 0, 1); return v; }\n"
// Points (64x64 grid, one per pixel) with a flat colour.
#define PT_VS "struct VO { float4 p [[position]]; float4 c [[flat]]; float ps [[point_size]]; };\n" \
    "static float4 pt(uint x, uint y) { return float4((float(x) + 0.5) / 32.0 - 1.0, 1.0 - (float(y) + 0.5) / 32.0, 0, 1); }\n" \
    "fragment float4 fp(VO v [[stage_in]]) { return v.c; }\n"
// Subgroup kernels: 4096 threads in groups of 64; v is the lane's input, meta = lane | simdgroup << 8 | width << 16.
#define SG_HEAD "kernel void k(device uint4 *o [[buffer(0)]], uint gid [[thread_position_in_grid]], " \
    "uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]], uint n [[threads_per_simdgroup]]) {\n" \
    "  uint v = (gid * 37 + 11) % 101; uint meta = lane | sg << 8 | n << 16;\n"
#define SG_GRID .gw = 4096, .gh = 1, .tw = 64, .th = 1

// ==== A: infrastructure ===================================================================================================

static const char kA2[] = FS_VS
    "fragment float4 fs(V v [[stage_in]]) {\n"
    "  int x = int(v.p.x), y = int(v.p.y);\n"
    "  if (((x ^ y) & 8) != 0) return float4(1, 0, 0, 1);\n"
    "  float s = 0;\n"
    "  for (int i = 0; i < (x & 15); i++) { if (i == y % 7) continue; s += float(i); if (s > 40) break; }\n"
    "  int k = 0; while (k * k < y) k++;\n"
    "  float4 c;\n"
    "  if (s > 20) c = float4(s / 100, 0.5, float(k) / 8, 1); else c = float4(0, s / 100, float(k) / 8, 0.5);\n"
    "  return c; }\n";
static void ref_A2(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        double *o = OUT(x, y);
        if ((x ^ y) & 8) { set4(o, 1, 0, 0, 1); continue; }
        float s = 0;
        for (int i = 0; i < (x & 15); i++) { if (i == y % 7) continue; s += (float)i; if (s > 40) break; }
        int k = 0;
        while (k * k < y) k++;
        if (s > 20) set4(o, s / 100.0f, 0.5, k / 8.0, 1); else set4(o, 0, s / 100.0f, k / 8.0, 0.5);
    }
}

// 32 live floats (8 float4) through 4 rounds where each one reads two others.
static const char kA3[] = FS_VS
    "#define RND r0 = r0 * r7.yzwx * 0.5 + r3.wxyz * 0.5; r1 = r1 * r0.yzwx * 0.5 + r4.wxyz * 0.5; r2 = r2 * r1.yzwx * 0.5 + r5.wxyz * 0.5; "
    "r3 = r3 * r2.yzwx * 0.5 + r6.wxyz * 0.5; r4 = r4 * r3.yzwx * 0.5 + r7.wxyz * 0.5; r5 = r5 * r4.yzwx * 0.5 + r0.wxyz * 0.5; "
    "r6 = r6 * r5.yzwx * 0.5 + r1.wxyz * 0.5; r7 = r7 * r6.yzwx * 0.5 + r2.wxyz * 0.5;\n"
    "fragment float4 fs(V v [[stage_in]]) {\n"
    "  float2 q = floor(v.p.xy) / 64.0;\n"
    "  float4 r0 = float4(q.x, q.y, 0.5, 0.25);\n"
    "  float4 r1 = r0.yxwz * 0.9 + 0.05, r2 = r1.zwxy * 0.8 + 0.1, r3 = r2.wzyx * 0.7 + 0.15, r4 = r3.xzyw * 0.6 + 0.2;\n"
    "  float4 r5 = r4.ywxz * 0.5 + 0.25, r6 = r5.zxwy * 0.4 + 0.3, r7 = r6.wyzx * 0.3 + 0.35;\n"
    "  RND RND RND RND\n"
    "  return r0 * r1 + r2 * r3 + r4 * r5 + r6 * r7; }\n";
typedef struct { float v[4]; } f4;
static f4 swz(f4 a, int i, int j, int k, int l) { return (f4){{a.v[i], a.v[j], a.v[k], a.v[l]}}; }
static f4 lin(f4 a, float m, float b) { for (int i = 0; i < 4; i++) a.v[i] = a.v[i] * m + b; return a; }
static void ref_A3(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        f4 r[8];
        r[0] = (f4){{x / 64.0f, y / 64.0f, 0.5f, 0.25f}};
        r[1] = lin(swz(r[0], 1, 0, 3, 2), 0.9f, 0.05f);
        r[2] = lin(swz(r[1], 2, 3, 0, 1), 0.8f, 0.1f);
        r[3] = lin(swz(r[2], 3, 2, 1, 0), 0.7f, 0.15f);
        r[4] = lin(swz(r[3], 0, 2, 1, 3), 0.6f, 0.2f);
        r[5] = lin(swz(r[4], 1, 3, 0, 2), 0.5f, 0.25f);
        r[6] = lin(swz(r[5], 2, 0, 3, 1), 0.4f, 0.3f);
        r[7] = lin(swz(r[6], 3, 1, 2, 0), 0.3f, 0.35f);
        for (int round = 0; round < 4; round++)
            for (int k = 0; k < 8; k++) {
                f4 a = swz(r[(k + 7) % 8], 1, 2, 3, 0), b = swz(r[(k + 3) % 8], 3, 0, 1, 2);
                for (int i = 0; i < 4; i++) r[k].v[i] = r[k].v[i] * a.v[i] * 0.5f + b.v[i] * 0.5f;
            }
        double *o = OUT(x, y);
        for (int i = 0; i < 4; i++) o[i] = r[0].v[i] * r[1].v[i] + r[2].v[i] * r[3].v[i] + r[4].v[i] * r[5].v[i] + r[6].v[i] * r[7].v[i];
    }
}

static const char kA6[] = FS_VS
    "fragment float4 fs(V v [[stage_in]]) {\n"
    "  float x = floor(v.p.x), y = floor(v.p.y);\n"
    "  uint h = uint(x) * 0x9E3779B9u + uint(y) * 0x85EBCA6Bu;\n"
    "  return float4(x * 0.0123456789 + 0.0625, y * -0.00732421875 + 0.98046875, float(h >> 24) * 0.00392156862745098,\n"
    "                (x + y) * -1.5e-3 + 0.75); }\n";
static void ref_A6(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        uint32_t h = (uint32_t)x * 0x9E3779B9u + (uint32_t)y * 0x85EBCA6Bu;
        set4(OUT(x, y), x * 0.0123456789f + 0.0625f, y * -0.00732421875f + 0.98046875f, (h >> 24) / 255.0, (x + y) * -1.5e-3f + 0.75f);
    }
}

// CoreAnimation's rounded clip: mix(backdrop, NaN, coverage). Under fast math the NaN constant is poison (0 in the
// translator): only coverage 0 is defined, and it must give the backdrop.
static const char kA11[] = FS_VS
    "fragment float4 fs(V v [[stage_in]]) {\n"
    "  float cov = step(32.0, v.p.x);\n"
    "  float4 back = float4(floor(v.p.xy) / 64.0, 0.5, 1);\n"
    "  return mix(back, float4(NAN), cov); }\n";
static void ref_A11(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        if (x < 32) set4(OUT(x, y), x / 64.0, y / 64.0, 0.5, 1); else set4(OUT(x, y), NAN, NAN, NAN, NAN);
    }
}

// ==== B: stages, inputs and outputs ========================================================================================

static const char kB1[] =
    "struct VI { float2 pos [[attribute(0)]]; float4 col [[attribute(1)]]; float k [[attribute(2)]]; };\n"
    "struct VO { float4 p [[position]]; float4 c [[flat]]; float ps [[point_size]]; };\n"
    "vertex VO vs(VI i [[stage_in]]) { VO o; o.p = float4(i.pos, 0, 1); o.c = float4(i.col.rgb, i.k); o.ps = 1; return o; }\n"
    "fragment float4 fp(VO v [[stage_in]]) { return v.c; }\n";
typedef struct { float pos[2]; uint8_t col[4]; float k; } b1_vertex;
static void setup_B1(ISAInputs *in) {
    b1_vertex *v = calloc(64 * 64, sizeof *v);
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
        b1_vertex *p = &v[y * 64 + x];
        p->pos[0] = (x + 0.5f) / 32 - 1;
        p->pos[1] = 1 - (y + 0.5f) / 32;
        p->col[0] = (uint8_t)(x * 4); p->col[1] = (uint8_t)(y * 4); p->col[2] = (uint8_t)((x + y) * 2); p->col[3] = 255;
        p->k = x * 0.01f + y;
    }
    in.buffers[@1] = buf(in, v, 64 * 64 * sizeof *v);
    free(v);
}
static void pipe_B1(MTLRenderPipelineDescriptor *d) {
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 1;
    vd.attributes[1].format = MTLVertexFormatUChar4Normalized; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 1;
    vd.attributes[2].format = MTLVertexFormatFloat; vd.attributes[2].offset = 12; vd.attributes[2].bufferIndex = 1;
    vd.layouts[1].stride = sizeof(b1_vertex);
    d.vertexDescriptor = vd;
}
static void ref_B1(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), x * 4 / 255.0, y * 4 / 255.0, (x + y) * 2 / 255.0, x * 0.01f + y);
}

static const char kB2[] = PT_VS
    "vertex VO vs(uint vid [[vertex_id]], uint iid [[instance_id]], uint bv [[base_vertex]], uint bi [[base_instance]]) {\n"
    "  VO o; o.p = pt(vid - bv, iid - bi); o.c = float4(vid, iid, bv, bi) / 256.0; o.ps = 1; return o; }\n";
static void setup_B2(ISAInputs *in) {
    uint16_t idx[64];
    for (int i = 0; i < 64; i++) idx[i] = (uint16_t)i;
    in.extra = buf(in, idx, sizeof idx);
}
static void draw_B2(id<MTLRenderCommandEncoder> e, ISAInputs *in, const isa_case *c, int n) {
    for (int i = 0; i < n; i++)
        [e drawIndexedPrimitives:MTLPrimitiveTypePoint indexCount:64 indexType:MTLIndexTypeUInt16 indexBuffer:in.extra
               indexBufferOffset:0 instanceCount:64 baseVertex:7 baseInstance:2];
}
static void ref_B2(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), (x + 7) / 256.0, (y + 2) / 256.0, 7 / 256.0, 2 / 256.0);
}

static const char kB3[] =
    "struct VO3 { float4 p [[position]]; float4 a [[user(alpha)]] [[flat]]; float b [[user(beta)]] [[flat]]; float ps [[point_size]]; };\n"
    "struct FI3 { float4 p [[position]]; float4 a [[user(alpha)]] [[flat]]; float b [[user(beta)]] [[flat]]; };\n"
    "vertex VO3 vs(uint vid [[vertex_id]]) {\n"
    "  uint x = vid % 64, y = vid / 64; VO3 o;\n"
    "  o.p = float4((float(x) + 0.5) / 32.0 - 1.0, 1.0 - (float(y) + 0.5) / 32.0, 0, 1);\n"
    "  o.a = float4(x / 64.0, y / 64.0, 0.25, 1); o.b = float(x * y) / 4096.0; o.ps = 1; return o; }\n"
    "fragment float4 fp(FI3 v [[stage_in]]) { return float4(v.a.xy, v.b, v.a.w); }\n";
static void ref_B3(const isa_case *c, const double *g, double *out) { PIX(c) set4(OUT(x, y), x / 64.0, y / 64.0, x * y / 4096.0, 1); }

// Clip distance 0.25 - x (NDC) on the full-screen triangle: pixels from x = 40 on are clipped.
static const char kB3c[] =
    "struct VC { float4 p [[position]]; float cd [[clip_distance]] [1]; };\n"
    "struct FC { float4 p [[position]]; };\n"
    "vertex VC vs(uint i [[vertex_id]]) {\n"
    "  float2 t = float2((i << 1) & 2, i & 2) * 2 - 1; VC o; o.p = float4(t, 0, 1); o.cd[0] = 0.25 - t.x; return o; }\n"
    "fragment float4 fs(FC v [[stage_in]]) { return float4(floor(v.p.xy) / 64.0, 1, 1); }\n";
static void ref_B3c(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        if (x == 39 || x == 40) set4(OUT(x, y), NAN, NAN, NAN, NAN);   // next to the clip edge
        else if (x > 40) set4(OUT(x, y), 0.1f, 0.2f, 0.3f, 0.4f);
        else set4(OUT(x, y), x / 64.0, y / 64.0, 1, 1);
    }
}

// Perspective-correct, noperspective, flat (provoking vertex 0) and centroid varyings on a triangle with w = 1, 2, 4.
#define B4_VS "vertex VO4 vs(uint i [[vertex_id]]) {\n" \
    "  float2 t = float2((i << 1) & 2, i & 2) * 2 - 1; float w = i == 0 ? 1.0 : (i == 1 ? 2.0 : 4.0);\n" \
    "  float val = float(i) * 0.5 + 0.25; VO4 o; o.p = float4(t * w, 0, w); o.a = val; o.b = val; o.c = val + 1; o.d = val; return o; }\n" \
    "fragment float4 fs(VO4 v [[stage_in]]) { return float4(v.a, v.b, v.c, v.d); }\n"
static const char kB4[] =
    "struct VO4 { float4 p [[position]]; float a; float b [[center_perspective]]; float c [[flat]]; float d [[centroid_perspective]]; };\n" B4_VS;
static const char kB4s[] =
    "struct VO4 { float4 p [[position]]; float a [[sample_perspective]]; float b; float c [[flat]]; float d [[sample_perspective]]; };\n" B4_VS;
static const char kB4n[] =
    "struct VN { float4 p [[position]]; float b [[center_no_perspective]]; float d [[centroid_no_perspective]]; };\n"
    "vertex VN vs(uint i [[vertex_id]]) {\n"
    "  float2 t = float2((i << 1) & 2, i & 2) * 2 - 1; float w = i == 0 ? 1.0 : (i == 1 ? 2.0 : 4.0);\n"
    "  float val = float(i) * 0.5 + 0.25; VN o; o.p = float4(t * w, 0, w); o.b = val; o.d = val; return o; }\n"
    "fragment float4 fs(VN v [[stage_in]]) { return float4(v.b, v.d, 1, 1); }\n";
static void b4_interp(int x, int y, double *persp, double *noper) {
    double X = (x + 0.5) / 32 - 1, Y = 1 - (y + 0.5) / 32;
    double l1 = (X + 1) / 4, l2 = (Y + 1) / 4, l0 = 1 - l1 - l2;
    const double a[3] = {0.25, 0.75, 1.25}, w[3] = {1, 2, 4};
    *noper = l0 * a[0] + l1 * a[1] + l2 * a[2];
    *persp = (l0 * a[0] / w[0] + l1 * a[1] / w[1] + l2 * a[2] / w[2]) / (l0 / w[0] + l1 / w[1] + l2 / w[2]);
}
// flat: Metal's provoking vertex is the first (1.25); the last one (2.25) is rasterizer state, not the compiler's: accepted.
static double b4_flat(const isa_case *c, const double *g, int x, int y) {
    return g && g[((size_t)y * c->w + x) * 4 + 2] == 2.25 ? 2.25 : 1.25;
}
static void ref_B4(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        double p, n;
        b4_interp(x, y, &p, &n);
        set4(OUT(x, y), p, p, b4_flat(c, g, x, y), p);
    }
}
static void ref_B4n(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        double p, n;
        b4_interp(x, y, &p, &n);
        set4(OUT(x, y), n, n, 1, 1);
    }
}
static void ref_B4s(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        double p, n;
        b4_interp(x, y, &p, &n);
        set4(OUT(x, y), p, p, b4_flat(c, g, x, y), p);
    }
}

// Two triangles: upper-left clockwise in NDC (front with the default winding), lower-right counter-clockwise.
static const char kB5[] =
    "struct V2 { float4 p [[position]]; };\n"
    "vertex V2 vs(uint i [[vertex_id]]) {\n"
    "  float x = (i == 1 || i == 3 || i == 5) ? 1.0 : -1.0, y = (i == 0 || i == 1 || i == 3) ? 1.0 : -1.0;\n"
    "  V2 v; v.p = float4(x, y, 0, 1); return v; }\n"
    "fragment float4 fs(V2 v [[stage_in]], bool ff [[front_facing]], uint sid [[sample_id]]) {\n"
    "  return float4(v.p.x / 64.0, v.p.y / 64.0, ff ? 1.0 : 0.0, float(get_num_samples()) * 0.25 + float(sid)); }\n";
static const char kB5m[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], uint m [[sample_mask]]) { return float4(floor(v.p.xy) / 64.0, float(m), 1); }\n";
static void ref_B5m(const isa_case *c, const double *g, double *out) { PIX(c) set4(OUT(x, y), x / 64.0, y / 64.0, 1, 1); }
static void draw_B5(id<MTLRenderCommandEncoder> e, ISAInputs *in, const isa_case *c, int n) {
    for (int i = 0; i < n; i++) [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}
static void ref_B5(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), (x + 0.5) / 64, (y + 0.5) / 64, x + y == 63 ? NAN : x + y < 63 ? 1 : 0, 0.25);
}

static const char kB5p[] =
    "struct VO5 { float4 p [[position]]; float ps [[point_size]]; };\n"
    "vertex VO5 vs(uint vid [[vertex_id]]) {\n"
    "  uint x = vid % 8, y = vid / 8; VO5 o;\n"
    "  o.p = float4((float(x) * 8 + 4) / 32.0 - 1.0, 1.0 - (float(y) * 8 + 4) / 32.0, 0, 1); o.ps = 8; return o; }\n"
    "fragment float4 fp(VO5 v [[stage_in]], float2 pc [[point_coord]]) { return float4(pc, floor(v.p.xy) / 64.0); }\n";
static void draw_B5p(id<MTLRenderCommandEncoder> e, ISAInputs *in, const isa_case *c, int n) {
    for (int i = 0; i < n; i++) [e drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:64];
}
static void ref_B5p(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), ((x & 7) + 0.5) / 8, ((y & 7) + 0.5) / 8, x / 64.0, y / 64.0);
}

// [[depth(any)]]: two draws with depth test Less; the second wins where its depth is smaller (y <= x).
static const char kB6[] = FS_VS
    "struct O { float4 c [[color(0)]]; float d [[depth(any)]]; };\n"
    "fragment O fs(V v [[stage_in]], constant uint &which [[buffer(0)]]) {\n"
    "  float x = floor(v.p.x), y = floor(v.p.y); O o;\n"
    "  if (which == 0) { o.c = float4(1, 0, x / 64.0, 1); o.d = (x + 0.5) / 64.0; }\n"
    "  else { o.c = float4(0, 1, y / 64.0, 0.5); o.d = (y + 0.25) / 64.0; }\n"
    "  return o; }\n";
static const char kB6m[] = FS_VS
    "struct O { float4 c [[color(0)]]; uint m [[sample_mask]]; };\n"
    "fragment O fs(V v [[stage_in]]) { O o; o.c = float4(floor(v.p.xy) / 64.0, 1, 1); o.m = v.p.x < 8 ? 0u : 0xffffffffu; return o; }\n";
static void ref_B6m(const isa_case *c, const double *g, double *out) {
    PIX(c) { if (x < 8) set4(OUT(x, y), 0.1f, 0.2f, 0.3f, 0.4f); else set4(OUT(x, y), x / 64.0, y / 64.0, 1, 1); }
}
static void setup_B6(ISAInputs *in) {
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = MTLCompareFunctionLess;
    d.depthWriteEnabled = YES;
    in.extra = [in.device newDepthStencilStateWithDescriptor:d];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    in.depth = [in.device newTextureWithDescriptor:td];
}
static void pipe_depth(MTLRenderPipelineDescriptor *d) { d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float; }
static void pass_depth(MTLRenderPassDescriptor *p, ISAInputs *in) {
    p.depthAttachment.texture = in.depth;
    p.depthAttachment.loadAction = MTLLoadActionClear;
    p.depthAttachment.clearDepth = 1;
    p.depthAttachment.storeAction = MTLStoreActionDontCare;
}
static void draw_B6(id<MTLRenderCommandEncoder> e, ISAInputs *in, const isa_case *c, int n) {
    [e setDepthStencilState:in.extra];
    for (int i = 0; i < n; i++)
        for (uint32_t w = 0; w < 2; w++) {
            [e setFragmentBytes:&w length:sizeof w atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
}
static void ref_B6(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        if (y <= x) set4(OUT(x, y), 0, 1, y / 64.0, 0.5);
        else set4(OUT(x, y), 1, 0, x / 64.0, 1);
    }
}

// Dual-source blending: out = src0 * src1.
static const char kB6d[] = FS_VS
    "struct O { float4 a [[color(0), index(0)]]; float4 b [[color(0), index(1)]]; };\n"
    "fragment O fs(V v [[stage_in]]) {\n"
    "  float x = floor(v.p.x), y = floor(v.p.y); O o;\n"
    "  o.a = float4(x / 64.0, y / 64.0, 1, 1); o.b = float4(0.5, 1, y / 64.0, 0.25); return o; }\n";
static void pipe_B6d(MTLRenderPipelineDescriptor *d) {
    MTLRenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[0];
    a.blendingEnabled = YES;
    a.sourceRGBBlendFactor = MTLBlendFactorSource1Color;
    a.sourceAlphaBlendFactor = MTLBlendFactorSource1Alpha;
    a.destinationRGBBlendFactor = a.destinationAlphaBlendFactor = MTLBlendFactorZero;
}
static void ref_B6d(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), x / 64.0 * 0.5, y / 64.0, y / 64.0, 0.25);
}

static const char kB7[] = FS_VS
    "struct O { float4 a [[color(0)]]; float4 b [[color(1)]]; };\n"
    "fragment O fs(V v [[stage_in]]) { O o; o.a = float4(floor(v.p.xy) / 64.0, 0.25, 1); o.b = float4(1); return o; }\n";
static void ref_B7(const isa_case *c, const double *g, double *out) { PIX(c) set4(OUT(x, y), x / 64.0, y / 64.0, 0.25, 1); }

static const char kB8[] = FS_VS
    "fragment float4 fs(V v [[stage_in]]) {\n"
    "  int x = int(v.p.x), y = int(v.p.y);\n"
    "  if ((x + y) % 3 == 0) discard_fragment();\n"
    "  return float4(x / 64.0, y / 64.0, 1, 1); }\n";
static void ref_B8(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        if ((x + y) % 3 == 0) set4(OUT(x, y), 0.1f, 0.2f, 0.3f, 0.4f); else set4(OUT(x, y), x / 64.0, y / 64.0, 1, 1);
    }
}

// Framebuffer fetch: a plumbing draw writes a pattern, the case's draw reads [[color(0)]].
#define PATTERN_FS "fragment half4 prep(V v [[stage_in]]) {\n" \
    "  float2 q = floor(v.p.xy); return half4(float4(q.x * 4, q.y * 4, (q.x + q.y) * 2, 255) / 255.0); }\n"
static const char kB9[] = FS_VS PATTERN_FS
    "fragment half4 fs(V v [[stage_in]], half4 d [[color(0)]]) { return half4(d.g, d.r, 1.0h - d.b, d.a * 0.25h); }\n";
static void ref_pattern_swap(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), y * 4 / 255.0, x * 4 / 255.0, 1 - (x + y) * 2 / 255.0, 0.25);
}

static const char kB10[] =
    "kernel void k(device uint4 *o [[buffer(0)]], uint2 gid [[thread_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]],\n"
    "  uint2 tg [[threadgroup_position_in_grid]], uint2 ntg [[threadgroups_per_grid]], uint2 tpt [[threads_per_threadgroup]],\n"
    "  uint2 tpg [[threads_per_grid]], uint li [[thread_index_in_threadgroup]], uint sl [[thread_index_in_simdgroup]],\n"
    "  uint sg [[simdgroup_index_in_threadgroup]], uint sw [[threads_per_simdgroup]], uint nsg [[simdgroups_per_threadgroup]],\n"
    "  uint ql [[thread_index_in_quadgroup]], uint qg [[quadgroup_index_in_threadgroup]]) {\n"
    "  uint ok = (sg * sw + sl == li ? 1u : 0u) | (qg * 4 + ql == li ? 2u : 0u) | (nsg == (64 + sw - 1) / sw ? 4u : 0u) |\n"
    "            (popcount(sw) == 1 && sw >= 4 && sw <= 64 ? 8u : 0u);\n"
    "  o[gid.y * 64 + gid.x] = uint4(gid.x | gid.y << 8 | lid.x << 16 | lid.y << 24, tg.x | tg.y << 8 | ntg.x << 16 | ntg.y << 24,\n"
    "                                tpt.x | tpt.y << 8 | tpg.x << 16 | tpg.y << 24, li | ok << 16); }\n";
static void ref_B10(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        uint32_t lx = x & 7, ly = y & 7;
        set4(OUT(x, y), (uint32_t)x | (uint32_t)y << 8 | lx << 16 | ly << 24, (uint32_t)(x >> 3) | (uint32_t)(y >> 3) << 8 | 8u << 16 | 8u << 24,
             8u | 8u << 8 | 64u << 16 | 64u << 24, (ly * 8 + lx) | 15u << 16);
    }
}

static const char kB11[] =
    "kernel void k(device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]], uint2 n [[threads_per_grid]]) {\n"
    "  o[p.y * 64 + p.x] = float4(p.x, p.y, n.x, n.y); }\n";
static void ref_B11(const isa_case *c, const double *g, double *out) {
    PIX(c) { if (x < 61 && y < 59) set4(OUT(x, y), x, y, 61, 59); else set4(OUT(x, y), 0, 0, 0, 0); }
}

// ==== C: memory ===========================================================================================================

static const char kC1[] =
    "kernel void k(device float4 *o [[buffer(0)]], device const float *a [[buffer(1)]], device const float *b [[buffer(2)]],\n"
    "              uint2 p [[thread_position_in_grid]]) {\n"
    "  device const float *s = (p.x & 1) ? a : b;\n"
    "  s += p.y;\n"
    "  device const float *t = a + p.x;\n"
    "  for (uint i = 0; i < (p.y & 3); i++) t += 64;\n"
    "  o[p.y * 64 + p.x] = float4(s[p.x], *t, s[1], float(p.x)); }\n";
static float c1a(int i) { return i * 0.5f; }
static float c1b(int i) { return 1000.0f - i; }
static void setup_C1(ISAInputs *in) {
    float a[512], b[512];
    for (int i = 0; i < 512; i++) { a[i] = c1a(i); b[i] = c1b(i); }
    in.buffers[@1] = buf(in, a, sizeof a);
    in.buffers[@2] = buf(in, b, sizeof b);
}
static void ref_C1(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        float (*s)(int) = (x & 1) ? c1a : c1b;
        set4(OUT(x, y), s(y + x), c1a(x + 64 * (y & 3)), s(y + 1), x);
    }
}

static const char kC2[] = FS_VS
    "struct P { float4 scale; float2 off; uint n; float k; };\n"
    "fragment float4 fs(V v [[stage_in]], constant float4 &c [[buffer(0)]], constant P &p [[buffer(1)]]) {\n"
    "  float2 q = floor(v.p.xy); return float4(q * p.scale.xy + p.off, c.z * float(p.n), c.w + p.k * q.x); }\n";
typedef struct { float scale[4]; float off[2]; uint32_t n; float k; } c2_params;
static void setup_C2(ISAInputs *in) {
    float cc[4] = {0.1f, 0.2f, 0.3f, 0.4f};
    c2_params p = {{1 / 64.0f, 1 / 32.0f, 0, 0}, {0.01f, -0.5f}, 3, 0.001f};
    in.buffers[@0] = buf(in, cc, sizeof cc);
    in.buffers[@1] = buf(in, &p, sizeof p);
}
static void ref_C2(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), x * (1 / 64.0f) + 0.01f, y * (1 / 32.0f) - 0.5f, 0.3f * 3, 0.4f + 0.001f * x);
}

static const char kC3[] =
    "kernel void k(device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]], uint2 tpg [[threads_per_grid]],\n"
    "              uint2 ntg [[threadgroups_per_grid]], uint2 tpt [[threads_per_threadgroup]]) {\n"
    "  o[p.y * 64 + p.x] = float4(tpg.x, tpg.y, ntg.x * 100 + ntg.y, tpt.x * tpt.y); }\n";
static void ref_C3(const isa_case *c, const double *g, double *out) {
    PIX(c) { if (y < 48) set4(OUT(x, y), 64, 48, 806, 64); else set4(OUT(x, y), 0, 0, 0, 0); }
}

static const float kC4T[16] = {0.5f, -1.25f, 3.0f, 7.75f, -0.125f, 2.5f, 9.0f, -6.5f, 1.0f, 0.0625f, -3.75f, 4.25f, 8.5f, -2.0f, 0.375f, 5.5f};
static const float kC4Q[4][4] = {{1, 2, 3, 4}, {-1, -2, -3, -4}, {0.5f, 0.25f, 0.125f, 0.0625f}, {10, 20, 30, 40}};
static const char kC4[] =
    "constant float T[16] = { 0.5, -1.25, 3.0, 7.75, -0.125, 2.5, 9.0, -6.5, 1.0, 0.0625, -3.75, 4.25, 8.5, -2.0, 0.375, 5.5 };\n"
    "constant float4 Q[4] = { float4(1, 2, 3, 4), float4(-1, -2, -3, -4), float4(0.5, 0.25, 0.125, 0.0625), float4(10, 20, 30, 40) };\n"
    "kernel void k(device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  uint i = (p.x * 7 + p.y) & 15;\n"
    "  o[p.y * 64 + p.x] = float4(T[i], T[(i + 5) & 15], Q[p.y & 3].x, Q[p.x & 3].w); }\n";
static void ref_C4(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int i = (x * 7 + y) & 15;
        set4(OUT(x, y), kC4T[i], kC4T[(i + 5) & 15], kC4Q[y & 3][0], kC4Q[x & 3][3]);
    }
}

static const char kC5[] =
    "kernel void k(device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]], uint l [[thread_index_in_threadgroup]]) {\n"
    "  threadgroup float tmp[64]; threadgroup float2 t2[64];\n"
    "  tmp[l] = float(p.x * 3 + p.y); t2[l] = float2(p.y, l);\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  o[p.y * 64 + p.x] = float4(tmp[63 - l], tmp[(l + 1) & 63], t2[(l * 5) & 63].x, t2[(l * 5) & 63].y); }\n";
static void ref_C5(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), (63 - x) * 3 + y, ((x + 1) & 63) * 3 + y, y, (x * 5) & 63);
}

static const char kC6[] =
    "kernel void k(device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  float a[16];\n"
    "  for (int i = 0; i < 16; i++) a[i] = float(i * int(p.x + 1)) * 0.5;\n"
    "  uint j = (p.x * p.y) & 15; a[j] += 1.0;\n"
    "  o[p.y * 64 + p.x] = float4(a[(p.x + p.y) & 15], a[j], a[15 - (p.y & 15)], float(j)); }\n";
static void ref_C6(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        float a[16];
        for (int i = 0; i < 16; i++) a[i] = (float)(i * (x + 1)) * 0.5f;
        int j = (x * y) & 15;
        a[j] += 1;
        set4(OUT(x, y), a[(x + y) & 15], a[j], a[15 - (y & 15)], j);
    }
}

static const char kC7[] =
    "struct S { packed_float3 a; uint b; float2 c; float d[2]; };\n"
    "kernel void k(device float4 *o [[buffer(0)]], device const S *in [[buffer(1)]], device S *out [[buffer(2)]],\n"
    "              uint2 p [[thread_position_in_grid]]) {\n"
    "  uint i = p.y * 64 + p.x; S s = in[(p.x + p.y * 3) & 63];\n"
    "  out[i] = s;\n"
    "  o[i] = float4(s.a.x + s.d[1], s.a.y * s.c.x, float(s.b) + s.a.z, s.c.y - s.d[0]); }\n";
typedef struct { float a[3]; uint32_t b; float c[2]; float d[2]; } c7_s;   // 32 bytes, as the MSL struct
static void setup_C7(ISAInputs *in) {
    c7_s s[64];
    for (int k = 0; k < 64; k++)
        s[k] = (c7_s){{(float)k, k * 0.5f, (float)-k}, (uint32_t)k * 3, {0.25f * k, 1.0f - k}, {k * 0.125f, 2.0f * k}};
    in.buffers[@1] = buf(in, s, sizeof s);
    in.buffers[@2] = buf(in, NULL, 64 * 64 * sizeof(c7_s));
}
static void ref_C7(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int k = (x + y * 3) & 63;
        set4(OUT(x, y), k + 2.0f * k, k * 0.5f * (0.25f * k), (float)(k * 3) + (float)-k, (1.0f - k) - k * 0.125f);
    }
}

static const char kC8[] =
    "struct Blob { float v[8]; };\n"
    "kernel void k(device float4 *o [[buffer(0)]], device const Blob *in [[buffer(1)]], device Blob *tmp [[buffer(2)]],\n"
    "              uint2 p [[thread_position_in_grid]]) {\n"
    "  uint i = p.y * 64 + p.x;\n"
    "  tmp[i] = in[(p.x + p.y) & 31];\n"
    "  float z[8]; for (int j = 0; j < 8; j++) z[j] = 0.0;\n"
    "  z[p.x & 7] = 1.0;\n"
    "  Blob b = tmp[i];\n"
    "  o[i] = float4(b.v[p.x & 7], b.v[(p.x + 3) & 7], z[p.y & 7], z[(p.x + 1) & 7] + b.v[7]); }\n";
static void setup_C8(ISAInputs *in) {
    float v[32 * 8];
    for (int i = 0; i < 32 * 8; i++) v[i] = (float)i;
    in.buffers[@1] = buf(in, v, sizeof v);
    in.buffers[@2] = buf(in, NULL, 64 * 64 * 32);
}
static void ref_C8(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int k = (x + y) & 31;
        set4(OUT(x, y), k * 8 + (x & 7), k * 8 + ((x + 3) & 7), (y & 7) == (x & 7) ? 1 : 0, k * 8 + 7);
    }
}

// Device atomics: 4096 threads on 1024 uint4 counters (4 threads each), then the final values.
static const char kC9[] =
    "kernel void k(device atomic_uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "  uint j = (i & 1023) * 4;\n"
    "  atomic_fetch_add_explicit(&o[j], i, memory_order_relaxed);\n"
    "  atomic_fetch_max_explicit(&o[j + 1], (i * 2654435761u) >> 20, memory_order_relaxed);\n"
    "  atomic_fetch_or_explicit(&o[j + 2], 1u << (i >> 10), memory_order_relaxed);\n"
    "  atomic_fetch_xor_explicit(&o[j + 2], 1u << ((i >> 10) + 8), memory_order_relaxed);\n"
    "  atomic_fetch_and_explicit(&o[j + 2], 0xffffu, memory_order_relaxed);\n"
    "  atomic_fetch_sub_explicit(&o[j + 3], 1u, memory_order_relaxed);\n"
    "}\n";
// Compare-and-swap loop (add 2) and exchange to the same value.
static const char kC9x[] =
    "kernel void k(device atomic_uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "  uint j = (i & 1023) * 4;\n"
    "  uint e = atomic_load_explicit(&o[j], memory_order_relaxed);\n"
    "  while (!atomic_compare_exchange_weak_explicit(&o[j], &e, e + 2, memory_order_relaxed, memory_order_relaxed)) {}\n"
    "  atomic_exchange_explicit(&o[j + 1], j + 7, memory_order_relaxed);\n"
    "  uint z = 0; atomic_compare_exchange_weak_explicit(&o[j + 2], &z, 0u, memory_order_relaxed, memory_order_relaxed);\n"
    "}\n";
static void ref_C9x(const isa_case *c, const double *g, double *out) { PIX(c) set4(OUT(x, y), 8, (y * 64 + x) * 4 + 7, 0, 0); }
static void ref_C9(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        uint32_t i0 = (uint32_t)(y * 64 + x), mx = 0;
        for (uint32_t t = 0; t < 4; t++) { uint32_t h = ((i0 + t * 1024) * 2654435761u) >> 20; if (h > mx) mx = h; }
        set4(OUT(x, y), 4 * i0 + 6144, mx, 0xF0F, 0xfffffffcu);   // 0 - 4 wraps
    }
}

static const char kC9t[] =
    "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]], uint l [[thread_index_in_threadgroup]]) {\n"
    "  threadgroup atomic_uint s[4];\n"
    "  if (l < 4) atomic_store_explicit(&s[l], l == 2 ? 0xffffffffu : 0u, memory_order_relaxed);\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  atomic_fetch_add_explicit(&s[0], l + p.y, memory_order_relaxed);\n"
    "  atomic_fetch_max_explicit(&s[1], l ^ p.y, memory_order_relaxed);\n"
    "  atomic_fetch_min_explicit(&s[2], (l * 37 + p.y) % 61 + 3, memory_order_relaxed);\n"
    "  atomic_exchange_explicit(&s[3], p.y + 5, memory_order_relaxed);\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  o[p.y * 64 + p.x] = uint4(atomic_load_explicit(&s[0], memory_order_relaxed), atomic_load_explicit(&s[1], memory_order_relaxed),\n"
    "                            atomic_load_explicit(&s[2], memory_order_relaxed), atomic_load_explicit(&s[3], memory_order_relaxed)); }\n";
static void ref_C9t(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        uint32_t mx = 0, mn = 0xffffffffu;
        for (uint32_t l = 0; l < 64; l++) {
            uint32_t a = l ^ (uint32_t)y, b = (l * 37 + (uint32_t)y) % 61 + 3;
            if (a > mx) mx = a;
            if (b < mn) mn = b;
        }
        set4(OUT(x, y), 2016 + 64 * y, mx, mn, y + 5);
    }
}

static const char kC10[] =
    "kernel void k(device float4 *o [[buffer(0)]], device float *sc [[buffer(1)]], uint2 p [[thread_position_in_grid]],\n"
    "              uint l [[thread_index_in_threadgroup]]) {\n"
    "  uint base = p.y * 64;\n"
    "  sc[base + l] = float(l * l + p.y);\n"
    "  threadgroup_barrier(mem_flags::mem_device);\n"
    "  float a = sc[base + (63 - l)];\n"
    "  simdgroup_barrier(mem_flags::mem_none);\n"
    "  o[base + l] = float4(a, sc[base + ((l + 1) & 63)], float(l), 1); }\n";
static void setup_C10(ISAInputs *in) { in.buffers[@1] = buf(in, NULL, 64 * 64 * 4); }
static void ref_C10(const isa_case *c, const double *g, double *out) {
    PIX(c) { int r = 63 - x, n = (x + 1) & 63; set4(OUT(x, y), r * r + y, n * n + y, x, 1); }
}

// ==== D: textures and samplers =============================================================================================

static void setup_tex16_nearest(ISAInputs *in) {
    in.textures[@0] = tex_rgba8(in, 16, 16, 1, t16);
    in.samplers[@0] = smp(in, false, false, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionNever);
}

static const char kD1a[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  float2 uv = v.p.xy / 64.0; float4 a = t.sample(s, uv); float4 b = t.sample(s, uv, int2(1, -1));\n"
    "  return float4(a.r, a.g, b.r, b.g); }\n";
static void ref_D1a(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int i = x >> 2, j = y >> 2;
        set4(OUT(x, y), i * 16 / 255.0, j * 16 / 255.0, clampi(i + 1, 0, 15) * 16 / 255.0, clampi(j - 1, 0, 15) * 16 / 255.0);
    }
}

static const char kD1b[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return t.sample(s, v.p.xy / 64.0); }\n";
static void setup_D1b(ISAInputs *in) {
    in.textures[@0] = tex_rgba8(in, 16, 16, 1, t16);
    in.samplers[@0] = smp(in, true, false, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionNever);
}
static void ref_D1b(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        double u = (x + 0.5) / 4 - 0.5, v = (y + 0.5) / 4 - 0.5;
        int i0 = (int)floor(u), j0 = (int)floor(v);
        double fu = u - i0, fv = v - j0;
        uint8_t p00[4], p10[4], p01[4], p11[4];
        t16(clampi(i0, 0, 15), clampi(j0, 0, 15), p00);
        t16(clampi(i0 + 1, 0, 15), clampi(j0, 0, 15), p10);
        t16(clampi(i0, 0, 15), clampi(j0 + 1, 0, 15), p01);
        t16(clampi(i0 + 1, 0, 15), clampi(j0 + 1, 0, 15), p11);
        double *o = OUT(x, y);
        for (int k = 0; k < 4; k++)
            o[k] = ((p00[k] * (1 - fu) + p10[k] * fu) * (1 - fv) + (p01[k] * (1 - fu) + p11[k] * fu) * fv) / 255.0;
    }
}

static const char kD1c[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  float2 uv = v.p.xy / 64.0;\n"
    "  return float4(t.sample(s, uv, level(floor(v.p.x / 16.0))).r, t.sample(s, uv, bias(3.0)).r,\n"
    "                t.sample(s, uv, gradient2d(float2(0.25, 0), float2(0, 0.25))).r, 1); }\n";
static const char kD1m[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  float2 uv = v.p.xy / 64.0;\n"
    "  return float4(t.sample(s, uv, bias(0.0), min_lod_clamp(3.0)).r, t.sample(s, uv, min_lod_clamp(2.0)).r,\n"
    "                t.sample(s, uv, bias(3.0), min_lod_clamp(2.0)).r, 1); }\n";
static void setup_D1c(ISAInputs *in) {
    in.textures[@0] = tex_rgba8(in, 16, 16, 5, NULL);
    in.samplers[@0] = smp(in, false, true, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionNever);
}
static void ref_D1c(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), (x >> 4) * 50 / 255.0, 50 / 255.0, 100 / 255.0, 1);
}
static void ref_D1m(const isa_case *c, const double *g, double *out) { PIX(c) set4(OUT(x, y), 150 / 255.0, 100 / 255.0, 100 / 255.0, 1); }

static const char kD1d[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture3d<float> t3 [[texture(0)]], texture2d_array<float> ta [[texture(1)]],\n"
    "                   texturecube<float> tc [[texture(2)]], sampler s [[sampler(0)]]) {\n"
    "  float2 q = floor(v.p.xy), uv = v.p.xy / 64.0;\n"
    "  float a = t3.sample(s, float3(uv, (float(int(q.x + q.y) & 3) + 0.5) / 4.0)).r;\n"
    "  float b = ta.sample(s, uv, uint(q.x + q.y) % 3).r;\n"
    "  uint f = uint(q.x) * 6 / 64; float m = (q.y - 32.0) / 64.0 * 0.8;\n"
    "  float3 d = f == 0 ? float3(1, m, 0.3) : f == 1 ? float3(-1, m, 0.3) : f == 2 ? float3(m, 1, 0.3) :\n"
    "             f == 3 ? float3(m, -1, 0.3) : f == 4 ? float3(m, 0.3, 1) : float3(m, 0.3, -1);\n"
    "  return float4(a, b, tc.sample(s, d).r, 1); }\n";
static id<MTLTexture> tex_cube4(ISAInputs *in, int (*fn)(int f, int i, int j)) {
    id<MTLTexture> t = mktex(in, MTLTextureTypeCube, MTLPixelFormatRGBA8Unorm, 4, 4, 1, 1, MTLTextureUsageShaderRead);
    for (int f = 0; f < 6; f++) {
        uint8_t b[64];
        for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
            uint8_t *p = b + (j * 4 + i) * 4;
            p[0] = (uint8_t)fn(f, i, j); p[1] = p[2] = 0; p[3] = 255;
        }
        [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:(NSUInteger)f withBytes:b bytesPerRow:16 bytesPerImage:64];
    }
    return t;
}
static int cube_face(int f, int i, int j) { return f * 40 + 20; }
static int cube_texel(int f, int i, int j) { return f * 40 + (i + j * 4) * 2; }
static void setup_D1d(ISAInputs *in) {
    id<MTLTexture> t3 = mktex(in, MTLTextureType3D, MTLPixelFormatRGBA8Unorm, 4, 4, 4, 1, MTLTextureUsageShaderRead);
    uint8_t b[4 * 4 * 4 * 4] = {0};
    for (int k = 0; k < 4; k++) for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
        uint8_t *p = b + ((k * 4 + j) * 4 + i) * 4;
        p[0] = (uint8_t)((i + 4 * j + 16 * k) * 4); p[3] = 255;
    }
    [t3 replaceRegion:MTLRegionMake3D(0, 0, 0, 4, 4, 4) mipmapLevel:0 slice:0 withBytes:b bytesPerRow:16 bytesPerImage:64];
    id<MTLTexture> ta = mktex(in, MTLTextureType2DArray, MTLPixelFormatRGBA8Unorm, 4, 4, 3, 1, MTLTextureUsageShaderRead);
    for (int s = 0; s < 3; s++) {
        uint8_t a[64] = {0};
        for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) { a[(j * 4 + i) * 4] = (uint8_t)((i + 4 * j) * 8 + s * 60); a[(j * 4 + i) * 4 + 3] = 255; }
        [ta replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:(NSUInteger)s withBytes:a bytesPerRow:16 bytesPerImage:64];
    }
    in.textures[@0] = t3;
    in.textures[@1] = ta;
    in.textures[@2] = tex_cube4(in, cube_face);
    in.samplers[@0] = smp(in, false, false, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionNever);
}
static void ref_D1d(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int i = x >> 4, j = y >> 4, f = x * 6 / 64;
        set4(OUT(x, y), (i + 4 * j + 16 * ((x + y) & 3)) * 4 / 255.0, ((i + 4 * j) * 8 + ((x + y) % 3) * 60) / 255.0, cube_face(f, 0, 0) / 255.0, 1);
    }
}

static const char kD2[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]], sampler n [[sampler(1)]]) {\n"
    "  constexpr sampler gt(compare_func::greater, filter::nearest, address::clamp_to_edge);\n"
    "  float2 uv = v.p.xy / 64.0;\n"
    "  return float4(t.sample_compare(s, uv, 0.5), t.sample_compare(gt, uv, 0.5), t.sample(n, uv), 1); }\n";
static void setup_D2(ISAInputs *in) {
    in.textures[@0] = tex_depth16(in);
    in.samplers[@0] = smp(in, false, false, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionLessEqual);
    in.samplers[@1] = smp(in, false, false, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionNever);
}
static void ref_D2(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        float d = tdepth(x >> 2, y >> 2);
        set4(OUT(x, y), 0.5f <= d ? 1 : 0, 0.5f > d ? 1 : 0, d, 1);
    }
}

static const char kD3[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return t.gather(s, v.p.xy / 64.0, int2(1, 0), component::y); }\n";
static void tgather(int i, int j, uint8_t p[4]) { p[0] = 0; p[1] = (uint8_t)(i * 16 + j); p[2] = 0; p[3] = 255; }
static void setup_D3(ISAInputs *in) {
    in.textures[@0] = tex_rgba8(in, 16, 16, 1, tgather);
    in.samplers[@0] = smp(in, false, false, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionNever);
}
// gather: x = (i0, j1), y = (i1, j1), z = (i1, j0), w = (i0, j0)
static void gather_ij(int x, int y, int ox, int *i0, int *i1, int *j0, int *j1) {
    int i = (int)floor((x + 0.5) / 4 - 0.5) + ox, j = (int)floor((y + 0.5) / 4 - 0.5);
    *i0 = clampi(i, 0, 15); *i1 = clampi(i + 1, 0, 15); *j0 = clampi(j, 0, 15); *j1 = clampi(j + 1, 0, 15);
}
static void ref_D3(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int i0, i1, j0, j1;
        gather_ij(x, y, 1, &i0, &i1, &j0, &j1);
        set4(OUT(x, y), (i0 * 16 + j1) / 255.0, (i1 * 16 + j1) / 255.0, (i1 * 16 + j0) / 255.0, (i0 * 16 + j0) / 255.0);
    }
}

static const char kD3c[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return t.gather_compare(s, v.p.xy / 64.0, 0.5); }\n";
static void setup_D3c(ISAInputs *in) {
    in.textures[@0] = tex_depth16(in);
    in.samplers[@0] = smp(in, false, false, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionLessEqual);
}
static void ref_D3c(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int i0, i1, j0, j1;
        gather_ij(x, y, 0, &i0, &i1, &j0, &j1);
#define CMP(i, j) (0.5f <= tdepth(i, j) ? 1.0 : 0.0)
        set4(OUT(x, y), CMP(i0, j1), CMP(i1, j1), CMP(i1, j0), CMP(i0, j0));
#undef CMP
    }
}

static const char kD4[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], texturecube<float> tc [[texture(2)]]) {\n"
    "  uint2 q = uint2(v.p.xy);\n"
    "  return float4(t.read(q / 4).r, t.read(q / 8, 1).g, float(q.x), tc.read(q / 16, (q.x + q.y) % 6).r); }\n";
static const char kD4b[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture_buffer<float> tb [[texture(1)]]) {\n"
    "  uint2 q = uint2(v.p.xy); return float4(tb.read((q.x + q.y * 64) & 255).r, float(q.x), float(q.y), 1); }\n";
static const char kD4d[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], depth2d<float> t [[texture(0)]]) {\n"
    "  uint2 q = uint2(v.p.xy) / 4; return float4(t.read(q), t.read(uint2(q.y, q.x)), float(q.x), float(q.y)); }\n";
static void setup_D4(ISAInputs *in) {
    id<MTLTexture> t = mktex(in, MTLTextureType2D, MTLPixelFormatRGBA8Unorm, 16, 16, 1, 2, MTLTextureUsageShaderRead);
    uint8_t l0[16 * 16 * 4], l1[8 * 8 * 4] = {0};
    for (int j = 0; j < 16; j++) for (int i = 0; i < 16; i++) t16(i, j, l0 + (j * 16 + i) * 4);
    for (int j = 0; j < 8; j++) for (int i = 0; i < 8; i++) l1[(j * 8 + i) * 4 + 1] = (uint8_t)((i + j * 8) * 3);
    [t replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:l0 bytesPerRow:64];
    [t replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:1 withBytes:l1 bytesPerRow:32];
    in.textures[@0] = t;
    in.textures[@2] = tex_cube4(in, cube_texel);
}
static void ref_D4(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int f = (x + y) % 6;
        set4(OUT(x, y), (x >> 2) * 16 / 255.0, (((x >> 3) + (y >> 3) * 8) * 3) / 255.0, x, cube_texel(f, x >> 4, y >> 4) / 255.0);
    }
}
static void setup_D4b(ISAInputs *in) {
    float tb[256];
    for (int k = 0; k < 256; k++) tb[k] = k * 0.5f;
    id<MTLBuffer> b = buf(in, tb, sizeof tb);
    MTLTextureDescriptor *bd = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Float width:256
                                                                            resourceOptions:MTLResourceStorageModeShared usage:MTLTextureUsageShaderRead];
    id<MTLTexture> bt = [b newTextureWithDescriptor:bd offset:0 bytesPerRow:1024];
    if (bt) in.textures[@1] = bt;
}
static void ref_D4b(const isa_case *c, const double *g, double *out) { PIX(c) set4(OUT(x, y), ((x + 64 * y) & 255) * 0.5, x, y, 1); }
static void setup_D4d(ISAInputs *in) { in.textures[@0] = tex_depth16(in); }
static void ref_D4d(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), tdepth(x >> 2, y >> 2), tdepth(y >> 2, x >> 2), x >> 2, y >> 2);
}

static const char kD5[] =
    "kernel void k(texture2d<float, access::write> o [[texture(0)]], texture2d<float, access::read_write> rw [[texture(1)]],\n"
    "              uint2 p [[thread_position_in_grid]]) {\n"
    "  float v = rw.read(p).r; rw.write(float4(v * 2 + 1), p); o.write(float4(p.x, p.y, v, v * 3), p); }\n";
static void setup_D5(ISAInputs *in) {
    id<MTLTexture> t = mktex(in, MTLTextureType2D, MTLPixelFormatR32Float, 64, 64, 1, 1, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    float *b = malloc(64 * 64 * 4);
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) b[y * 64 + x] = x * 0.25f + y;
    [t replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:b bytesPerRow:256];
    free(b);
    in.textures[@1] = t;
}
static void ref_D5(const isa_case *c, const double *g, double *out) {
    PIX(c) { float v = x * 0.25f + y; set4(OUT(x, y), x, y, v, v * 3); }
}

static const char kD6[] =
    "kernel void k(device uint4 *o [[buffer(0)]], texture2d<float> a [[texture(1)]], texture3d<float> b [[texture(2)]],\n"
    "              texture2d_array<float> c [[texture(3)]], texturecube<float> d [[texture(4)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  uint lod = p.x & 3;\n"
    "  o[p.y * 64 + p.x] = uint4(a.get_width(lod), a.get_height(lod), a.get_num_mip_levels(),\n"
    "                            b.get_depth() * 100 + c.get_array_size() * 10 + d.get_width()); }\n";
static void setup_D6(ISAInputs *in) {
    in.textures[@1] = mktex(in, MTLTextureType2D, MTLPixelFormatRGBA8Unorm, 16, 8, 1, 5, MTLTextureUsageShaderRead);
    in.textures[@2] = mktex(in, MTLTextureType3D, MTLPixelFormatRGBA8Unorm, 4, 4, 4, 1, MTLTextureUsageShaderRead);
    in.textures[@3] = mktex(in, MTLTextureType2DArray, MTLPixelFormatRGBA8Unorm, 4, 4, 3, 1, MTLTextureUsageShaderRead);
    in.textures[@4] = mktex(in, MTLTextureTypeCube, MTLPixelFormatRGBA8Unorm, 4, 4, 1, 1, MTLTextureUsageShaderRead);
}
static void ref_D6(const isa_case *c, const double *g, double *out) {
    PIX(c) { int l = x & 3; set4(OUT(x, y), 16 >> l, MAX(8 >> l, 1), 5, 434); }
}

static const char kD7[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s3 [[sampler(3)]]) {\n"
    "  constexpr sampler px(coord::pixel, filter::nearest, address::clamp_to_edge);\n"
    "  float2 q = floor(v.p.xy);\n"
    "  float4 a = t.sample(px, (q + 0.5) / 4.0);\n"
    "  float4 b = t.sample(s3, (q + 0.5) / 32.0);\n"
    "  return float4(a.r, a.g, b.r, b.g); }\n";
static void setup_D7(ISAInputs *in) {
    in.textures[@0] = tex_rgba8(in, 16, 16, 1, t16);
    in.samplers[@3] = smp(in, false, false, MTLSamplerAddressModeRepeat, MTLCompareFunctionNever);
}
static void ref_D7(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), (x >> 2) * 16 / 255.0, (y >> 2) * 16 / 255.0, ((x >> 1) & 15) * 16 / 255.0, ((y >> 1) & 15) * 16 / 255.0);
}

static const char kD8[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture2d<uint> a [[texture(0)]], texture2d<int> b [[texture(1)]],\n"
    "                   texture2d<half> c [[texture(2)]], depth2d<float> d [[texture(3)]], sampler s [[sampler(0)]]) {\n"
    "  uint2 q = uint2(v.p.xy) / 4; float2 uv = v.p.xy / 64.0;\n"
    "  return float4(float(a.read(q).r), float(b.read(q).r), float(c.sample(s, uv).r), d.sample(s, uv)); }\n";
static void setup_D8(ISAInputs *in) {
    id<MTLTexture> a = mktex(in, MTLTextureType2D, MTLPixelFormatRGBA8Uint, 16, 16, 1, 1, MTLTextureUsageShaderRead);
    id<MTLTexture> b = mktex(in, MTLTextureType2D, MTLPixelFormatR16Sint, 16, 16, 1, 1, MTLTextureUsageShaderRead);
    id<MTLTexture> h = mktex(in, MTLTextureType2D, MTLPixelFormatRGBA16Float, 16, 16, 1, 1, MTLTextureUsageShaderRead);
    uint8_t ab[16 * 16 * 4] = {0};
    int16_t bb[16 * 16];
    _Float16 hb[16 * 16 * 4];
    for (int j = 0; j < 16; j++) for (int i = 0; i < 16; i++) {
        int k = j * 16 + i;
        ab[k * 4] = (uint8_t)(i * 16 + j);
        bb[k] = (int16_t)((i - j) * 100);
        hb[k * 4] = (_Float16)(i * 0.25f + j / 32.0f); hb[k * 4 + 1] = hb[k * 4 + 2] = 0; hb[k * 4 + 3] = 1;
    }
    [a replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:ab bytesPerRow:64];
    [b replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:bb bytesPerRow:32];
    [h replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:hb bytesPerRow:128];
    in.textures[@0] = a;
    in.textures[@1] = b;
    in.textures[@2] = h;
    in.textures[@3] = tex_depth16(in);
    in.samplers[@0] = smp(in, false, false, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionNever);
}
static void ref_D8(const isa_case *c, const double *g, double *out) {
    PIX(c) { int i = x >> 2, j = y >> 2; set4(OUT(x, y), i * 16 + j, (i - j) * 100, i * 0.25 + j / 32.0, tdepth(i, j)); }
}

static const char kD9[] = FS_VS
    "fragment float4 fs(V v [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]], sampler s [[sampler(0)]]) {\n"
    "  float2 uv = v.p.xy / 64.0; return a.sample(s, uv) * 0.5 + b.sample(s, uv) * 0.25; }\n";
static void setup_D9(ISAInputs *in) {
    in.textures[@0] = tex_rgba8(in, 16, 16, 1, t16);
    in.textures[@1] = tex_rgba8(in, 16, 16, 1, t16b);
    in.samplers[@0] = smp(in, false, false, MTLSamplerAddressModeClampToEdge, MTLCompareFunctionNever);
}
static void ref_D9(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        uint8_t a[4], b[4];
        t16(x >> 2, y >> 2, a);
        t16b(x >> 2, y >> 2, b);
        double *o = OUT(x, y);
        for (int k = 0; k < 4; k++) o[k] = a[k] / 255.0 * 0.5 + b[k] / 255.0 * 0.25;
    }
}

// ==== E: ALU and math library ==============================================================================================

static const char kE1[] =
    "kernel void k(device int4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  int x = int(p.x), y = int(p.y);\n"
    "  int a = x * 37 - 1200 + y; int b = (y % 13) - 6; if (b == 0) b = 7;\n"
    "  uint ua = uint(a) * 2654435761u, ub = uint(y * 3 + 1);\n"
    "  o[p.y * 64 + p.x] = int4(a / b, a % b, int(ua / ub), int((ua % ub) ^ (ua >> (p.y & 31)) ^ (uint(a) << (p.x & 7)) ^ uint(a >> (p.y & 7)))); }\n";
static void ref_E1(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int32_t a = x * 37 - 1200 + y, b = (y % 13) - 6;
        if (b == 0) b = 7;
        uint32_t ua = (uint32_t)a * 2654435761u, ub = (uint32_t)(y * 3 + 1);
        set4(OUT(x, y), a / b, a % b, (int32_t)(ua / ub),
             (int32_t)((ua % ub) ^ (ua >> (y & 31)) ^ ((uint32_t)a << (x & 7)) ^ (uint32_t)(a >> (y & 7))));
    }
}

static const char kE1f[] = FS_VS
    "fragment float4 fs(V v [[stage_in]]) {\n"
    "  float x = floor(v.p.x), y = floor(v.p.y);\n"
    "  return float4((x - 31.5) / (y + 0.25), -(x * 0.75), x * y * 0.001 - 1.0, (x + y) / 7.0); }\n";
static void ref_E1f(const isa_case *c, const double *g, double *out) {
    PIX(c) set4(OUT(x, y), (x - 31.5) / (y + 0.25), -(x * 0.75), x * y * 0.001 - 1.0, (x + y) / 7.0);
}

static const char kE2[] =
    "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  int a = int(p.x) - 32, b = 16 - int(p.y); uint ua = uint(a), ub = uint(b);\n"
    "  float fa = float(a) * 0.5, fb = float(b) * 0.25;\n"
    "  uint m = uint(a < b) | uint(a <= b) << 1 | uint(a == b) << 2 | uint(a != b) << 3 | uint(ua < ub) << 4 | uint(ua >= ub) << 5 |\n"
    "           uint(fa < fb) << 6 | uint(fa >= fb) << 7 | uint(fa == fb) << 8 | uint(fa != fb) << 9 | uint(fa <= fb) << 10 | uint(fa > fb) << 11;\n"
    "  o[p.y * 64 + p.x] = uint4(m, a > b ? ua : ub, select(1u, 2u, fa > fb), uint(bool(p.x & 4) && !bool(p.y & 2))); }\n";
static void ref_E2(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int32_t a = x - 32, b = 16 - y;
        uint32_t ua = (uint32_t)a, ub = (uint32_t)b;
        float fa = a * 0.5f, fb = b * 0.25f;
        uint32_t m = (uint32_t)(a < b) | (uint32_t)(a <= b) << 1 | (uint32_t)(a == b) << 2 | (uint32_t)(a != b) << 3 |
                     (uint32_t)(ua < ub) << 4 | (uint32_t)(ua >= ub) << 5 | (uint32_t)(fa < fb) << 6 | (uint32_t)(fa >= fb) << 7 |
                     (uint32_t)(fa == fb) << 8 | (uint32_t)(fa != fb) << 9 | (uint32_t)(fa <= fb) << 10 | (uint32_t)(fa > fb) << 11;
        set4(OUT(x, y), m, a > b ? ua : ub, fa > fb ? 2 : 1, ((x & 4) && !(y & 2)) ? 1 : 0);
    }
}

static const char kE3[] =
    "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  float f = (float(p.x) - 32.0) * 0.75 + float(p.y) * 0.0625;\n"
    "  o[p.y * 64 + p.x] = uint4(uint(int(f)), uint(abs(f) * 16.0), as_type<uint>(float(half(f))),\n"
    "                            uint(int(char(p.x * 9 + p.y))) ^ (uint(ushort(p.x * 3000 + p.y)) << 8)); }\n";
static void ref_E3(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        float f = (x - 32.0f) * 0.75f + y * 0.0625f, fh = h_round(f);
        uint32_t bits;
        memcpy(&bits, &fh, 4);
        set4(OUT(x, y), (uint32_t)(int32_t)f, (uint32_t)(fabsf(f) * 16), bits,
             (uint32_t)(int32_t)(int8_t)(x * 9 + y) ^ ((uint32_t)(uint16_t)(x * 3000 + y) << 8));
    }
}

static const char kE4[] =
    "kernel void k(device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  float x = float(p.x), y = float(p.y);\n"
    "  float4 v = float4(x, y, x + y, x - y);\n"
    "  float e = v[(p.x + p.y) & 3];\n"
    "  v[(p.x * 3) & 3] = 100.0;\n"
    "  half4 h = half4(v.wzyx) * 0.5h;\n"
    "  ushort2 u = ushort2(p.x, p.y).yx + ushort2(1, 2);\n"
    "  o[p.y * 64 + p.x] = float4(e, v.x + v.y * 2.0 + v.z * 4.0 + v.w * 8.0, float(h.z) - float(h.y) + float(h.w), float(u.x) * 256.0 + float(u.y)); }\n";
static void ref_E4(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        double v[4] = {x, y, x + y, x - y};
        double e = v[(x + y) & 3];
        v[(x * 3) & 3] = 100;
        set4(OUT(x, y), e, v[0] + v[1] * 2 + v[2] * 4 + v[3] * 8, v[1] / 2 - v[2] / 2 + v[0] / 2, (y + 1) * 256.0 + x + 2);
    }
}

static const char kE5[] =
    "kernel void k(device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  half a = half(p.x) * 0.125h + 0.0625h * half(p.y);\n"
    "  half b = half(p.y + 1) * 0.3h;\n"
    "  half2 hv = half2(a, b) * half2(2.0h, 0.5h);\n"
    "  o[p.y * 64 + p.x] = float4(a * b, a + b * 3.0h, hv.x - hv.y, 1.0h / half(p.y + 1)); }\n";
static void ref_E5(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        float a = x * 0.125f + 0.0625f * y, b = h_round((y + 1) * h_round(0.3f));
        set4(OUT(x, y), h_round(a * b), h_round(a + h_round(b * 3)), h_round(h_round(a * 2) - h_round(b * 0.5f)), h_round(1.0f / (y + 1)));
    }
}

#define E6_TS "float t = (floor(v.p.x) - 32.0) / 8.0, s = (floor(v.p.y) - 32.0) / 10.0, u = (floor(v.p.x) + 0.5) / 32.0 - 1.0;\n" \
    "  float w = (floor(v.p.x) + 1.0) * (floor(v.p.y) + 1.0) / 64.0;\n"
#define E6_REF double t = (x - 32) / 8.0, s = (y - 32) / 10.0, u = (x + 0.5) / 32 - 1, w = (x + 1.0) * (y + 1.0) / 64; (void)t; (void)s; (void)u; (void)w;
static const char kE6a[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E6_TS
    "  return float4(sin(t), cos(t * 1.3 + s), tan(t * 0.3), atan2(s, t + 0.01)); }\n";
static void ref_E6a(const isa_case *c, const double *g, double *out) { PIX(c) { E6_REF set4(OUT(x, y), sin(t), cos(t * 1.3 + s), tan(t * 0.3), atan2(s, t + 0.01)); } }
static const char kE6b[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E6_TS
    "  return float4(asin(u * 0.99), acos(u * 0.99), atan(u * 4.0 + s), acosh(1.0 + (floor(v.p.y) + 0.5) / 16.0)); }\n";
static void ref_E6b(const isa_case *c, const double *g, double *out) { PIX(c) { E6_REF set4(OUT(x, y), asin(u * 0.99), acos(u * 0.99), atan(u * 4 + s), acosh(1 + (y + 0.5) / 16)); } }
static const char kE6c[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E6_TS
    "  return float4(sinh(t * 0.5), cosh(t * 0.5), tanh(t), atanh(u * 0.9)); }\n";
static void ref_E6c(const isa_case *c, const double *g, double *out) { PIX(c) { E6_REF set4(OUT(x, y), sinh(t * 0.5), cosh(t * 0.5), tanh(t), atanh(u * 0.9)); } }
static const char kE6d[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E6_TS
    "  return float4(exp(t * 0.5), exp2(t), exp10(s * 0.5), asinh(t)); }\n";
static void ref_E6d(const isa_case *c, const double *g, double *out) { PIX(c) { E6_REF set4(OUT(x, y), exp(t * 0.5), exp2(t), pow(10, s * 0.5), asinh(t)); } }
static const char kE6e[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E6_TS
    "  return float4(log(w), log2(w), log10(w), sqrt(w)); }\n";
static void ref_E6e(const isa_case *c, const double *g, double *out) { PIX(c) { E6_REF set4(OUT(x, y), log(w), log2(w), log10(w), sqrt(w)); } }
static const char kE6f[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E6_TS
    "  return float4(pow(w, s), powr(w, 0.37), rsqrt(w), pow(w * 0.1, 1.5)); }\n";
static void ref_E6f(const isa_case *c, const double *g, double *out) { PIX(c) { E6_REF set4(OUT(x, y), pow(w, s), pow(w, 0.37), 1 / sqrt(w), pow(w * 0.1, 1.5)); } }

#define E7_V "float x = floor(v.p.x), y = floor(v.p.y); float r = (x - 32.0) * 0.25 + float(int(y) & 1) * 0.125;\n"
#define E7_REF float r = (x - 32) * 0.25f + (y & 1) * 0.125f;
static const char kE7a[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E7_V
    "  return float4(floor(r), ceil(r), trunc(r), round(r)); }\n";
static void ref_E7a(const isa_case *c, const double *g, double *out) { PIX(c) { E7_REF set4(OUT(x, y), floorf(r), ceilf(r), truncf(r), roundf(r)); } }
static const char kE7b[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E7_V
    "  return float4(rint(r), fract(r), sign(r), saturate(r * 0.3)); }\n";
static void ref_E7b(const isa_case *c, const double *g, double *out) {
    PIX(c) { E7_REF float s = r * 0.3f; set4(OUT(x, y), rintf(r), r - floorf(r), r > 0 ? 1 : r < 0 ? -1 : 0, s < 0 ? 0 : s > 1 ? 1 : s); }
}
static const char kE7c[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E7_V
    "  float a = x * 0.125, b = y * 0.0625 - 1.0;\n"
    "  return float4(fma(a, b, 0.3), mix(a, b, y / 64.0), clamp(r, -1.5, 2.25), smoothstep(-2.0, 3.0, r) + step(0.5, r) * 10.0); }\n";
static void ref_E7c(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        E7_REF
        double a = x * 0.125, b = y * 0.0625 - 1, t = y / 64.0, k = (r + 2) / 5;
        k = k < 0 ? 0 : k > 1 ? 1 : k;
        set4(OUT(x, y), a * b + 0.3, a + (b - a) * t, r < -1.5 ? -1.5 : r > 2.25 ? 2.25 : r, k * k * (3 - 2 * k) + (r >= 0.5 ? 10 : 0));
    }
}
static const char kE7d[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E7_V
    "  float w = (y - 32.0) * 0.125, a2 = (x + 0.5) * 0.5, b2 = float(int(y) & 7) + 1.75;\n"
    "  return float4(min3(r, -r * 0.5, 1.25), median3(r, w, 0.75), fmod(a2, b2),\n"
    "                copysign(ldexp(1.5, (int(y) & 7) - 4), r)); }\n";
static void ref_E7d(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        E7_REF
        double w = (y - 32) * 0.125, a2 = (x + 0.5) * 0.5, b2 = (y & 7) + 1.75, q = a2 / b2;
        double mn = fmin(fmin(r, -r * 0.5), 1.25), md = fmax(fmin(r, w), fmin(fmax(r, w), 0.75));
        // fast-math fmod = a - b * trunc(a / b): undefined right at integer quotients
        double fm = fabs(q - round(q)) < 1e-3 ? NAN : fmod(a2, b2);
        set4(OUT(x, y), mn, md, fm, copysign(ldexp(1.5, (y & 7) - 4), r));
    }
}
static const char kE7e[] =
    "kernel void k(device int4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  int a = int(p.x) * 3 - 100, b = 50 - int(p.y) * 2;\n"
    "  o[p.y * 64 + p.x] = int4(abs(a), min(a, b) * 1000 + max(a, b), int(max(p.x * 3u, p.y * 5u)) + int(min(p.x, p.y)) * 1000,\n"
    "                           clamp(a, -5, 9) * 10 + int(signbit(float(a) - 0.5)) + int(isfinite(float(b))) * 2); }\n";
static void ref_E7e(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int a = x * 3 - 100, b = 50 - y * 2;
        set4(OUT(x, y), abs(a), MIN(a, b) * 1000 + MAX(a, b), MAX(x * 3, y * 5) + MIN(x, y) * 1000, clampi(a, -5, 9) * 10 + (a <= 0 ? 1 : 0) + 2);
    }
}

#define E8_V "float x = floor(v.p.x), y = floor(v.p.y);\n" \
    "  float3 a = float3((x - 32.0) / 16.0, (y - 32.0) / 16.0, 0.5), b = float3(0.25, -0.75, (x + y) / 64.0);\n"
#define E8_REF double a[3] = {(x - 32) / 16.0, (y - 32) / 16.0, 0.5}, b[3] = {0.25, -0.75, (x + y) / 64.0};
static double dot3(const double *a, const double *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
static const char kE8a[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E8_V
    "  return float4(dot(a, b), length(a), distance(a, b), normalize(a).x); }\n";
static void ref_E8a(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        E8_REF
        double d[3] = {a[0] - b[0], a[1] - b[1], a[2] - b[2]};
        set4(OUT(x, y), dot3(a, b), sqrt(dot3(a, a)), sqrt(dot3(d, d)), a[0] / sqrt(dot3(a, a)));
    }
}
static const char kE8b[] = FS_VS "fragment float4 fs(V v [[stage_in]]) {\n  " E8_V
    "  float3 n = normalize(b), c = cross(a, b);\n"
    "  return float4(c.x, c.z, reflect(a, n).y, refract(normalize(a), float3(0, 0, 1), 0.8).z); }\n";
static void ref_E8b(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        E8_REF
        double lb = sqrt(dot3(b, b)), n[3] = {b[0] / lb, b[1] / lb, b[2] / lb};
        double la = sqrt(dot3(a, a)), i[3] = {a[0] / la, a[1] / la, a[2] / la};
        double ni = i[2], k = 1 - 0.64 * (1 - ni * ni);
        double rz = k < 0 ? 0 : 0.8 * i[2] - (0.8 * ni + sqrt(k));
        set4(OUT(x, y), a[1] * b[2] - a[2] * b[1], a[0] * b[1] - a[1] * b[0], a[1] - 2 * dot3(n, a) * n[1], rz);
    }
}

#define E9_V "uint u = (p.x * 0x9E3779B9u) ^ (p.y * 0x85EBCA6Bu) ^ (p.x << (p.y & 31)); uint v = u * 747796405u + 2891336453u;\n" \
    "  int iu = int(u), iv = int(v);\n"
#define E9_REF uint32_t u = ((uint32_t)x * 0x9E3779B9u) ^ ((uint32_t)y * 0x85EBCA6Bu) ^ ((uint32_t)x << (y & 31)); \
    uint32_t v = u * 747796405u + 2891336453u; int32_t iu = (int32_t)u, iv = (int32_t)v; (void)iu; (void)iv;
static const char kE9a[] = "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n  " E9_V
    "  o[p.y * 64 + p.x] = uint4(ctz(v), ctz(u), popcount(u), reverse_bits(u)); }\n";
static const char kE9z[] = "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n  " E9_V
    "  o[p.y * 64 + p.x] = uint4(clz(u), clz(v), clz(u >> (p.x & 31)), 0); }\n";
static uint32_t rev32(uint32_t v) { uint32_t r = 0; for (int i = 0; i < 32; i++) if (v & (1u << i)) r |= 1u << (31 - i); return r; }
static void ref_E9a(const isa_case *c, const double *g, double *out) {
    PIX(c) { E9_REF set4(OUT(x, y), v ? __builtin_ctz(v) : 32, u ? __builtin_ctz(u) : 32, __builtin_popcount(u), rev32(u)); }
}
static int clz32(uint32_t v) { return v ? __builtin_clz(v) : 32; }
static void ref_E9z(const isa_case *c, const double *g, double *out) {
    PIX(c) { E9_REF set4(OUT(x, y), clz32(u), clz32(v), clz32(u >> (x & 31)), 0); }
}
static const char kE9b[] = "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n  " E9_V
    "  uint off = p.x & 15, bits = (p.y & 15) + 1;\n"
    "  o[p.y * 64 + p.x] = uint4(extract_bits(u, off, bits), uint(extract_bits(iu, off, bits)), insert_bits(u, v, off, bits), rotate(u, v & 31)); }\n";
static void ref_E9b(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        E9_REF
        uint32_t off = x & 15, bits = (y & 15) + 1, mask = bits == 32 ? 0xffffffffu : (1u << bits) - 1;
        uint32_t e = (u >> off) & mask, se = (e & (1u << (bits - 1))) ? e | ~mask : e;
        uint32_t r = v & 31;
        set4(OUT(x, y), e, se, (u & ~(mask << off)) | ((v & mask) << off), r ? (u << r) | (u >> (32 - r)) : u);
    }
}
static const char kE9c[] = "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n  " E9_V
    "  o[p.y * 64 + p.x] = uint4(mulhi(u, v), uint(mulhi(iu, iv)), addsat(u, v), uint(subsat(iu, iv))); }\n";
static void ref_E9c(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        E9_REF
        uint64_t s = (uint64_t)u + v;
        int64_t d = (int64_t)iu - iv;
        d = d > INT32_MAX ? INT32_MAX : d < INT32_MIN ? INT32_MIN : d;
        set4(OUT(x, y), (uint32_t)(((uint64_t)u * v) >> 32), (uint32_t)(int32_t)(((int64_t)iu * iv) >> 32), s > 0xffffffffu ? 0xffffffffu : (uint32_t)s,
             (uint32_t)(int32_t)d);
    }
}
static const char kE9d[] = "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n  " E9_V
    "  ulong w = ulong(u) * ulong(v) + (ulong(p.x) << 40);\n"
    "  o[p.y * 64 + p.x] = uint4(absdiff(iu, iv), hadd(u, v), rhadd(u, v), uint(w >> 13) ^ uint(w)); }\n";
static void ref_E9d(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        E9_REF
        uint64_t w = (uint64_t)u * v + ((uint64_t)x << 40);
        set4(OUT(x, y), iu > iv ? (uint32_t)iu - (uint32_t)iv : (uint32_t)iv - (uint32_t)iu, (uint32_t)(((uint64_t)u + v) >> 1),
             (uint32_t)(((uint64_t)u + v + 1) >> 1), (uint32_t)(w >> 13) ^ (uint32_t)w);
    }
}

static const char kE10[] =
    "kernel void k(device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  int4 i = int4(int(p.x) - 32, int(p.y) * 1000, -int(p.x * p.y), int(p.x));\n"
    "  float4 f = float4(i);\n"
    "  uint4 un = uint4(abs(f) * 2.5);\n"
    "  half4 h = half4(f * 0.001);\n"
    "  char4 c = char4(int4(i.x * 5, i.y, i.z, i.w * 7));\n"
    "  o[p.y * 64 + p.x] = float4(f.x + f.z * 0.5, float(un.y + un.x), float(h.y) + float(h.z), float(c.x) + float(c.w) * 1000.0); }\n";
static void ref_E10(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        float fx = (float)(x - 32), fy = (float)(y * 1000), fz = (float)(-(x * y));
        uint32_t ux = (uint32_t)(fabsf(fx) * 2.5f), uy = (uint32_t)(fabsf(fy) * 2.5f);
        // half4(f) rounds to f16; a path that keeps half in fp32 (VMG_HALF32, llvmpipe) gives the unrounded sum: both pass.
        double hr = h_round(fy * 0.001f) + h_round(fz * 0.001f), hf = fy * 0.001f + fz * 0.001f;
        double gh = g ? g[((size_t)y * c->w + x) * 4 + 2] : hr;
        set4(OUT(x, y), fx + fz * 0.5f, (float)(uy + ux), fabs(gh - hf) < fabs(gh - hr) ? hf : hr,
             (float)(int8_t)((x - 32) * 5) + (float)(int8_t)(x * 7) * 1000.0f);
    }
}

static const char kE11[] =
    "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  float4 c = float4(float(p.x) / 63.0, float(p.y) / 63.0, 0.31, float(p.x + p.y) / 127.0);\n"
    "  uint h = p.x * 0x01030507u ^ p.y * 0x0B0D1113u;\n"
    "  ushort s = ushort(p.x * 997 + p.y * 13);\n"
    "  o[p.y * 64 + p.x] = uint4(pack_float_to_unorm4x8(c), pack_float_to_snorm4x8(c * 2.0 - 1.0),\n"
    "                            pack_float_to_unorm2x16(c.xy) ^ pack_float_to_snorm2x16(unpack_snorm2x16_to_float(h)),\n"
    "                            uint(pack_float_to_unorm565(unpack_unorm565_to_float(s))) |\n"
    "                            (pack_float_to_unorm4x8(unpack_unorm4x8_to_float(h)) == h ? 0x10000u : 0u)); }\n";
static void ref_E11(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        double v[4] = {x / 63.0, y / 63.0, 0.31, (x + y) / 127.0};
        uint32_t un = 0, sn = 0;
        for (int k = 0; k < 4; k++) {
            un |= (uint32_t)lround(v[k] * 255) << (8 * k);
            sn |= ((uint32_t)(int32_t)lround((v[k] * 2 - 1) * 127) & 0xff) << (8 * k);
        }
        uint32_t u16 = (uint32_t)lround(v[0] * 65535) | (uint32_t)lround(v[1] * 65535) << 16;
        uint32_t h = (uint32_t)x * 0x01030507u ^ (uint32_t)y * 0x0B0D1113u, sr = 0;
        for (int k = 0; k < 2; k++) {
            uint32_t half16 = (h >> (16 * k)) & 0xffff;
            sr |= (half16 == 0x8000 ? 0x8001 : half16) << (16 * k);
        }
        set4(OUT(x, y), un, sn, u16 ^ sr, (uint32_t)(uint16_t)(x * 997 + y * 13) | 0x10000u);
    }
}

static const char kE12[] = FS_VS
    "fragment float4 fs(V v [[stage_in]]) {\n"
    "  float f = v.p.x * 3.0 + v.p.y * 0.5, g = v.p.x * 0.25 - v.p.y;\n"
    "  return float4(dfdx(f), dfdy(f), fwidth(f), dfdy(g)); }\n";
static void ref_E12(const isa_case *c, const double *g, double *out) { PIX(c) set4(OUT(x, y), 3, 0.5, 3.5, -1); }

static const char kE13[] =
    "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  bool4 b = bool4(bool(p.x & 1), bool(p.x & 2), bool(p.y & 1), bool((p.x + p.y) & 4));\n"
    "  uint4 s = select(uint4(1, 2, 3, 4), uint4(10, 20, 30, 40), b);\n"
    "  o[p.y * 64 + p.x] = uint4(all(b), any(b), s.x + s.y + s.z + s.w, uint(b.x) | uint(b.y) << 1 | uint(b.z) << 2 | uint(b.w) << 3); }\n";
static void ref_E13(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        int b[4] = {x & 1, (x & 2) != 0, y & 1, ((x + y) & 4) != 0};
        int s = 0;
        for (int k = 0; k < 4; k++) s += b[k] ? (k + 1) * 10 : k + 1;
        set4(OUT(x, y), b[0] && b[1] && b[2] && b[3], b[0] || b[1] || b[2] || b[3], s, b[0] | b[1] << 1 | b[2] << 2 | b[3] << 3);
    }
}

// ==== F: subgroups and quads ===============================================================================================
// Threads of a group of 64 map to SIMD lanes linearly (lane = index % width, as on Mali and llvmpipe); the width
// comes from the GPU's own output (16 on Valhall), the panel without GPU output assumes 16.

static int sg_width(const double *g) {
    if (!g) return 16;
    uint32_t n = (uint32_t)g[2] >> 16;
    return (n >= 4 && n <= 64 && !(n & (n - 1))) ? (int)n : 16;
}
static uint32_t sgv(int gid) { return (uint32_t)(gid * 37 + 11) % 101; }
#define SG_REF int n = sg_width(g); \
    for (int i = 0; i < c->w * c->h; i++) { \
        int li = i % 64, lane = li % n, sg = li / n, base = i - li + sg * n; (void)base; \
        double *o = out + (size_t)i * 4; uint32_t meta = (uint32_t)(lane | sg << 8 | n << 16); (void)meta;
#define SG_END }

static const char kF1a[] = SG_HEAD
    "  o[gid] = uint4(simd_shuffle(v, ushort((lane * 3 + 1) & (n - 1))), simd_shuffle_xor(v, ushort(3)), meta,\n"
    "                 quad_shuffle(v, ushort((lane + 1) & 3))); }\n";
static void ref_F1a(const isa_case *c, const double *g, double *out) {
    SG_REF set4(o, sgv(base + ((lane * 3 + 1) & (n - 1))), sgv(base + (lane ^ 3)), meta, sgv(base + (lane & ~3) + ((lane + 1) & 3))); SG_END
}
static const char kF1b[] = SG_HEAD
    "  uint d = simd_shuffle_down(v, ushort(2)), u = simd_shuffle_up(v, ushort(3));\n"
    "  o[gid] = uint4(lane + 2 < n ? d : 0xffffffffu, lane >= 3 ? u : 0xffffffffu, meta, quad_shuffle_xor(v, ushort(2))); }\n";
static void ref_F1b(const isa_case *c, const double *g, double *out) {
    SG_REF set4(o, lane + 2 < n ? sgv(base + lane + 2) : 0xffffffffu, lane >= 3 ? sgv(base + lane - 3) : 0xffffffffu, meta, sgv(base + (lane ^ 2))); SG_END
}
static const char kF2[] = SG_HEAD
    "  o[gid] = uint4(simd_broadcast(v, ushort(5 & (n - 1))), simd_broadcast_first(v), meta, simd_broadcast(v, ushort(lane & 0))); }\n";
static const char kF2q[] = SG_HEAD
    "  o[gid] = uint4(quad_broadcast(v, ushort(2)), quad_broadcast(v, ushort(1)), meta, 0); }\n";
static void ref_F2(const isa_case *c, const double *g, double *out) {
    SG_REF set4(o, sgv(base + (5 & (n - 1))), sgv(base), meta, sgv(base)); SG_END
}
static void ref_F2q(const isa_case *c, const double *g, double *out) {
    SG_REF set4(o, sgv(base + (lane & ~3) + 2), sgv(base + (lane & ~3) + 1), meta, 0); SG_END
}
static const char kF3a[] = SG_HEAD
    "  o[gid] = uint4(uint(simd_sum(float(v))), uint(simd_product(gid % 3 == 0 ? 2.0 : 1.0)), meta, simd_min(v) | simd_max(v) << 16); }\n";
static void ref_F3a(const isa_case *c, const double *g, double *out) {
    SG_REF
        uint32_t s = 0, pr = 1, mn = 0xffffffffu, mx = 0;
        for (int l = 0; l < n; l++) {
            uint32_t v = sgv(base + l);
            s += v; pr *= (base + l) % 3 == 0 ? 2 : 1; mn = MIN(mn, v); mx = MAX(mx, v);
        }
        set4(o, s, pr, meta, mn | mx << 16);
    SG_END
}
static const char kF3b[] = SG_HEAD
    "  o[gid] = uint4(uint(quad_sum(float(v))), quad_product(1 + (v & 1)), meta, quad_min(v) | quad_max(v) << 16); }\n";
static void ref_F3b(const isa_case *c, const double *g, double *out) {
    SG_REF
        uint32_t s = 0, pr = 1, mn = 0xffffffffu, mx = 0;
        int q = base + (lane & ~3);
        for (int l = 0; l < 4; l++) { uint32_t v = sgv(q + l); s += v; pr *= 1 + (v & 1); mn = MIN(mn, v); mx = MAX(mx, v); }
        set4(o, s, pr, meta, mn | mx << 16);
    SG_END
}
static const char kF4[] = SG_HEAD
    "  bool pp = (gid % 128) < 64, q = (v % 7) == 0;\n"
    "  uint a = uint(simd_all(pp)) | uint(simd_all(q)) << 1 | uint(simd_any(q)) << 2 | uint(simd_any(pp && lane == 1)) << 3 |\n"
    "           uint(simd_is_first()) << 4;\n"
    "  uint qa = uint(quad_any(q)) | uint(quad_all(q)) << 1 | uint(static_cast<quad_vote::vote_t>(quad_ballot(q))) << 4;\n"
    "  o[gid] = uint4(a, uint(static_cast<simd_vote::vote_t>(simd_ballot(q))), meta, qa); }\n";
static void ref_F4(const isa_case *c, const double *g, double *out) {
    SG_REF
        int pp = (i % 128) < 64, all_q = 1, any_q = 0;
        uint32_t ballot = 0;
        for (int l = 0; l < n; l++) {
            int q = sgv(base + l) % 7 == 0;
            all_q &= q; any_q |= q;
            if (q && l < 32) ballot |= 1u << l;
        }
        uint32_t a = (uint32_t)pp | (uint32_t)all_q << 1 | (uint32_t)any_q << 2 | (uint32_t)pp << 3 | (uint32_t)(lane == 0) << 4;
        int qb = 0, q0 = base + (lane & ~3);
        for (int l = 0; l < 4; l++) if (sgv(q0 + l) % 7 == 0) qb |= 1 << l;
        set4(o, a, ballot, meta, (qb != 0) | (qb == 15) << 1 | qb << 4);
    SG_END
}

// ==== G: today's gaps ======================================================================================================

// 8/16-bit integer and half ALU (suspected shape of the RenderBox shader that crashes bi_emit_alu).
static const char kG1[] =
    "kernel void k(device uint4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  ushort a = ushort(p.x * 1000 + p.y); short b = short(int(p.y) * 300 - 9000); uchar c = uchar(p.x * 7); char d = char(int(p.y) * 5 - 100);\n"
    "  ushort e = ushort(a * 3u + ushort(b)); short f = short(b >> 3); uchar g = uchar(c * c);\n"
    "  half h = abs(half(d)) * min(half(c), 10.0h);\n"
    "  o[p.y * 64 + p.x] = uint4(e, uint(int(f)), uint(g) | uint(uchar(c >> 2)) << 8 | uint(uchar(d / char(3))) << 16, uint(as_type<ushort>(h))); }\n";
static void ref_G1(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        uint16_t a = (uint16_t)(x * 1000 + y);
        int16_t b = (int16_t)(y * 300 - 9000);
        uint8_t cc = (uint8_t)(x * 7);
        int8_t d = (int8_t)(y * 5 - 100);
        uint16_t e = (uint16_t)(a * 3u + (uint16_t)b);
        int16_t f = (int16_t)(b >> 3);
        uint8_t gg = (uint8_t)(cc * cc);
        _Float16 h = (_Float16)(fabsf((float)d) * fminf((float)cc, 10.0f));
        uint16_t hb;
        memcpy(&hb, &h, 2);
        set4(OUT(x, y), e, (uint32_t)(int32_t)f, (uint32_t)gg | (uint32_t)(uint8_t)(cc >> 2) << 8 | (uint32_t)(uint8_t)(d / 3) << 16, hb);
    }
}

// Tile shading: a pattern draw, then a tile kernel rewrites every pixel through the imageblock.
static const char kG2[] = FS_VS PATTERN_FS
    "struct Px { half4 c [[color(0)]]; };\n"
    "kernel void tk(imageblock<Px, imageblock_layout_implicit> ib, ushort2 l [[thread_position_in_threadgroup]]) {\n"
    "  Px p = ib.read(l); p.c = half4(p.c.g, p.c.r, 1.0h - p.c.b, p.c.a * 0.25h); ib.write(p, l); }\n";
static id extra_G2(ISAInputs *in, NSError **err) {
    MTLTileRenderPipelineDescriptor *d = [MTLTileRenderPipelineDescriptor new];
    d.tileFunction = [in.library newFunctionWithName:@"tk"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.threadgroupSizeMatchesTileSize = YES;
    if (![in.device respondsToSelector:@selector(newRenderPipelineStateWithTileDescriptor:options:reflection:error:)]) {
        if (err) *err = [NSError errorWithDomain:@"isa" code:1 userInfo:@{NSLocalizedDescriptionKey: @"no tile pipelines"}];
        return nil;
    }
    return [in.device newRenderPipelineStateWithTileDescriptor:d options:MTLPipelineOptionNone reflection:nil error:err];
}
static void pass_G2(MTLRenderPassDescriptor *p, ISAInputs *in) { p.tileWidth = 16; p.tileHeight = 16; }
static void draw_G2(id<MTLRenderCommandEncoder> e, ISAInputs *in, const isa_case *c, int n) {
    for (int i = 0; i < n; i++) {   // the case's pipeline draws the pattern, the tile pipeline (extra) rewrites it
        [e setRenderPipelineState:in.pipeline];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e setRenderPipelineState:in.extra];
        [e dispatchThreadsPerTile:MTLSizeMake(16, 16, 1)];
    }
}

// Argument buffer with a device pointer (GPU address) and a constant.
static const char kG3[] = FS_VS
    "struct Args { device const float4 *data; float4 k; };\n"
    "fragment float4 fs(V v [[stage_in]], constant Args &a [[buffer(0)]]) { return a.data[uint(v.p.x) & 63] * a.k; }\n";
static void setup_G3(ISAInputs *in) {
    float d[64 * 4];
    for (int i = 0; i < 64; i++) { d[i * 4] = i / 64.0f; d[i * 4 + 1] = 1 - i / 64.0f; d[i * 4 + 2] = 0.5f; d[i * 4 + 3] = 1; }
    id<MTLBuffer> data = buf(in, d, sizeof d);
    struct { uint64_t p, pad; float k[4]; } args = {0, 0, {1, 0.5f, 2, 1}};
    if ([data respondsToSelector:@selector(gpuAddress)]) args.p = data.gpuAddress;
    in.buffers[@0] = buf(in, &args, sizeof args);
    in.extra = data;
}
static void draw_G3(id<MTLRenderCommandEncoder> e, ISAInputs *in, const isa_case *c, int n) {
    [e useResource:in.extra usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    for (int i = 0; i < n; i++) [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}
static void ref_G3(const isa_case *c, const double *g, double *out) { PIX(c) set4(OUT(x, y), x / 64.0, (1 - x / 64.0) * 0.5, 1, 1); }

// Indirect calls through a visible function table.
static const char kG4[] =
    "[[visible]] float twice(float x) { return x * 2.0; }\n"
    "[[visible]] float plus1(float x) { return x + 1.0; }\n"
    "kernel void k(device float4 *o [[buffer(0)]], visible_function_table<float(float)> tab [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  float v = float(p.x + p.y * 64);\n"
    "  o[p.y * 64 + p.x] = float4(tab[p.x & 1](v), tab[(p.y >> 1) & 1](v * 0.5), 0, 1); }\n";
static id<MTLComputePipelineState> cpipe_G4(ISAInputs *in, id<MTLFunction> fn, NSError **err) {
    id<MTLFunction> f0 = [in.library newFunctionWithName:@"twice"], f1 = [in.library newFunctionWithName:@"plus1"];
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
    d.computeFunction = fn;
    MTLLinkedFunctions *lf = [MTLLinkedFunctions linkedFunctions];
    lf.functions = f0 && f1 ? @[f0, f1] : @[];
    d.linkedFunctions = lf;
    id<MTLComputePipelineState> p = [in.device newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionNone reflection:nil error:err];
    if (!p || !f0 || !f1) return nil;
    MTLVisibleFunctionTableDescriptor *td = [MTLVisibleFunctionTableDescriptor visibleFunctionTableDescriptor];
    td.functionCount = 2;
    id<MTLVisibleFunctionTable> t = [p respondsToSelector:@selector(newVisibleFunctionTableWithDescriptor:)] ? [p newVisibleFunctionTableWithDescriptor:td] : nil;
    if (!t) {
        if (err) *err = [NSError errorWithDomain:@"isa" code:2 userInfo:@{NSLocalizedDescriptionKey: @"no visible function tables"}];
        return nil;
    }
    [t setFunction:[p functionHandleWithFunction:f0] atIndex:0];
    [t setFunction:[p functionHandleWithFunction:f1] atIndex:1];
    in.extra = t;
    return p;
}
static void cbind_G4(id<MTLComputeCommandEncoder> e, ISAInputs *in) { [e setVisibleFunctionTable:in.extra atBufferIndex:1]; }
static void ref_G4(const isa_case *c, const double *g, double *out) {
    PIX(c) {
        double v = x + y * 64;
        set4(OUT(x, y), (x & 1) ? v + 1 : v * 2, ((y >> 1) & 1) ? v * 0.5 + 1 : v, 0, 1);
    }
}

// ==== The table =============================================================================================================

#define FR(ID) .id = #ID, .kind = ISA_FRAG, .out = ISA_OUT_RGBA32F, .w = 64, .h = 64, .msl = k##ID, .ref = ref_##ID
#define VT(ID) .id = #ID, .kind = ISA_VERT, .out = ISA_OUT_RGBA32F, .w = 64, .h = 64, .msl = k##ID, .ref = ref_##ID
#define CS(ID, OUTK) .id = #ID, .kind = ISA_COMPUTE, .out = OUTK, .w = 64, .h = 64, .msl = k##ID, .ref = ref_##ID
#define CLEAR .clear = {0.1f, 0.2f, 0.3f, 0.4f}
#define TRIG .tol = 2e-3, .rel = 3e-3, .vis_lo = -2, .vis_hi = 2

const isa_case isa_cases[] = {
    // A: infrastructure (VMG_ISA_ONLY left unset)
    {FR(A2), .title = "Flusso di controllo: if/else, cicli con break/continue, ritorno anticipato"},
    {FR(A3), .title = "Pressione sui registri: 32 valori vivi", .tol = 1e-4, .vis_hi = 4},
    {FR(A6), .title = "Costanti: immediati, tabella costanti, FAU"},
    {FR(A11), .title = "Fast math: costante NaN = 0 (mix con copertura)"},
    // B: stages, inputs and outputs
    {VT(B1), .title = "Ingressi vertice (vertex descriptor: float2, uchar4 norm, float)", .setup = setup_B1, .pipe = pipe_B1, .vis_hi = 1},
    {VT(B2), .title = "vertex_id, instance_id, base_vertex, base_instance", .draw = draw_B2, .setup = setup_B2},
    {VT(B3), .title = "Uscite vertice: varying con chiave, point_size"},
    {FR(B3c), .id = "B3", .title = "clip_distance (triangolo tagliato a x = 40)", CLEAR,
     .mac_note = "percorso NIR su llvmpipe: clip_distance non applicata (anche sui punti)"},
    {FR(B4), .title = "Varying: prospettico (w 1, 2, 4), flat, centroid", .tol = 2e-4, .rel = 2e-4, .vis_hi = 1.5},
    {FR(B4s), .id = "B4", .title = "Varying per campione (sample_perspective)", .tol = 2e-4, .rel = 2e-4, .vis_hi = 1.5},
    {FR(B4n), .id = "B4", .title = "Varying no_perspective (center, centroid)", .tol = 2e-4, .rel = 2e-4, .vis_hi = 1.5,
     .mac_note = "percorso NIR su llvmpipe: i varying no_perspective arrivano NaN"},
    {FR(B5), .title = "front_facing, frag coord, sample_id, num_samples", .draw = draw_B5},
    {FR(B5m), .id = "B5", .title = "sample_mask in ingresso",
     .mac_note = "percorso NIR: \"unsupported input air.sample_mask_in\", la pipeline non disegna"},
    {.id = "B5", .title = "point_coord (punti 8×8)", .kind = ISA_VERT, .out = ISA_OUT_RGBA32F, .w = 64, .h = 64, .msl = kB5p,
     .ref = ref_B5p, .draw = draw_B5p},
    {FR(B6), .title = "Uscita depth(any), due draw con depth test", .setup = setup_B6, .pipe = pipe_depth,
     .pass = pass_depth, .draw = draw_B6, CLEAR, .feats = "C2",
     .mac_note = "llvmpipe: il depth test non viene applicato in questo build (neanche con la z della posizione); phase3 va in "
                 "crash nel percorso vertici (llvm_middle_end_linear_run)"},
    {FR(B6m), .id = "B6", .title = "Uscita sample_mask (0 per x < 8)", CLEAR,
     .mac_note = "llvmpipe con un solo campione ignora la sample_mask in uscita"},
    {.id = "B6", .title = "Blend dual source (index(1))", .kind = ISA_FRAG, .out = ISA_OUT_RGBA8, .w = 64, .h = 64, .msl = kB6d,
     .ref = ref_B6d, .pipe = pipe_B6d, .tol = 0.006},
    {FR(B7), .title = "Variante senza le uscite che non hanno attachment"},
    {FR(B8), .title = "discard_fragment", CLEAR},
    {.id = "B9", .title = "Framebuffer fetch: [[color(0)]] in ingresso", .kind = ISA_FRAG, .out = ISA_OUT_RGBA8, .w = 64, .h = 64,
     .msl = kB9, .ref = ref_pattern_swap, .prep_fs = "prep", .tol = 0.006},
    {CS(B10, ISA_OUT_U32), .title = "Valori di sistema compute (griglia, gruppi, simdgroup, quad)", .groups = true},
    {CS(B11, ISA_OUT_F32), .title = "dispatchThreads non uniforme (guardia) 61×59", .gw = 61, .gh = 59, .vis_hi = 64},
    // C: memory
    {CS(C1, ISA_OUT_F32), .title = "Buffer device: aritmetica dei puntatori, select e phi", .setup = setup_C1, .vis_hi = 1000},
    {FR(C2), .title = "Push window: buffer constant piccoli in FAU", .setup = setup_C2},
    {CS(C3, ISA_OUT_F32), .title = "Sysval: threads_per_grid, threadgroups_per_grid", .gh = 48, .groups = true, .vis_hi = 1000},
    {CS(C4, ISA_OUT_F32), .title = "Constant pool: tabelle globali costanti", .vis_lo = -10, .vis_hi = 40},
    {CS(C5, ISA_OUT_F32), .title = "Memoria threadgroup + barriera", .tw = 64, .th = 1, .feats = "C10", .vis_hi = 256},
    {CS(C6, ISA_OUT_F32), .title = "Memoria privata con indice dinamico", .vis_hi = 512},
    {CS(C7, ISA_OUT_F32), .title = "Struct: load/store di aggregati, packed_float3", .setup = setup_C7, .feats = "C8", .vis_lo = -64, .vis_hi = 200},
    {CS(C8, ISA_OUT_F32), .title = "memcpy device→device, memset privato", .setup = setup_C8, .feats = "C6,C7", .vis_hi = 256},
    {.id = "C9", .title = "Atomiche device: add, max, or, xor, and, sub", .kind = ISA_COMPUTE, .out = ISA_OUT_U32,
     .w = 64, .h = 16, .msl = kC9, .ref = ref_C9, SG_GRID},
    {.id = "C9", .title = "Atomiche device: load + cmpxchg in un ciclo, xchg", .kind = ISA_COMPUTE, .out = ISA_OUT_U32,
     .w = 64, .h = 16, .msl = kC9x, .ref = ref_C9x, SG_GRID,
     .mac_note = "percorso NIR: cmpxchg (risultato {valore, i1}) non tradotto: \"expected a scalar or vector value\", il kernel "
                 "viene creato ma non gira"},
    {.id = "C9", .title = "Atomiche threadgroup: store, add, max, min, xchg, load", .kind = ISA_COMPUTE, .out = ISA_OUT_U32, .w = 64,
     .h = 64, .msl = kC9t, .ref = ref_C9t, .tw = 64, .th = 1, .feats = "C5,C10"},
    {CS(C10, ISA_OUT_F32), .title = "Barriere: memoria device e simdgroup", .setup = setup_C10, .tw = 64, .th = 1, .vis_hi = 4000},
    // D: textures and samplers
    {FR(D1a), .id = "D1", .title = "sample 2D nearest, con offset", .setup = setup_tex16_nearest, .feats = "D7"},
    {FR(D1b), .id = "D1", .title = "sample 2D lineare (tolleranza)", .setup = setup_D1b, .tol = 2.5 / 255, .feats = "D7"},
    {FR(D1c), .id = "D1", .title = "sample con level, bias, gradient", .setup = setup_D1c, .feats = "D7"},
    {FR(D1m), .id = "D1", .title = "sample con min_lod_clamp", .setup = setup_D1c, .feats = "D7",
     .mac_note = "percorso NIR: min_lod_clamp ignorato (campiona il livello 0)"},
    {FR(D1d), .id = "D1", .title = "sample 3D, 2D array, cube", .setup = setup_D1d, .feats = "D7"},
    {FR(D2), .title = "sample_compare (sampler legato e constexpr), sample di depth", .setup = setup_D2, .feats = "D7,D8"},
    {FR(D3), .title = "gather componente y con offset", .setup = setup_D3, .feats = "D7"},
    {FR(D3c), .id = "D3", .title = "gather_compare", .setup = setup_D3c, .feats = "D7,D8",
     .mac_note = "percorso NIR: gather_compare restituisce solo .x (y, z, w = 0), come un risultato shadow a 1 componente"},
    {FR(D4), .title = "read: 2D (anche mip 1), cube come array", .setup = setup_D4, .vis_hi = 1},
    {FR(D4b), .id = "D4", .title = "read di texture buffer", .setup = setup_D4b, .vis_hi = 64, .skip_llvmpipe = true,
     .mac_note = "driver: la texture su buffer R32Float 256 crea una risorsa di 256 byte (width in elementi, non in byte) e "
                 "vmg_texture_sync ci copia 1024 byte (heap overflow, vmg_exec.c:121 / vmg_screen.c:719)"},
    {FR(D4d), .id = "D4", .title = "read di depth2d", .setup = setup_D4d, .feats = "D8", .vis_hi = 1,
     .mac_note = "percorso NIR: depth2d::read restituisce sempre lo stesso texel (0,0390625 = texel (1,0)), le coordinate "
                 "non arrivano: da indagare nel traduttore (tex_result / txf su depth)"},
    {CS(D5, ISA_OUT_TEX), .title = "write e read_write di texture (compute)", .setup = setup_D5, .feats = "D4", .vis_hi = 200},
    {CS(D6, ISA_OUT_U32), .title = "Query: dimensioni per lod, mip, depth, array_size", .setup = setup_D6},
    {FR(D7), .title = "Sampler legato (slot 3, repeat) e constexpr coord::pixel", .setup = setup_D7},
    {FR(D8), .title = "Tipi dei risultati: uint, int, half, depth", .setup = setup_D8, .feats = "D4,D7", .vis_lo = -1500, .vis_hi = 255},
    {FR(D9), .title = "Due texture con lo stesso sampler (dual tex)", .setup = setup_D9, .feats = "D7"},
    // E: ALU and math library
    {CS(E1, ISA_OUT_I32), .title = "Interi: div/rem con e senza segno, shift, logiche"},
    {FR(E1f), .id = "E1", .title = "Float: fdiv, fneg, mul, add", .rel = 2e-6, .vis_lo = -2, .vis_hi = 2},
    {CS(E2, ISA_OUT_U32), .title = "Confronti int/uint/float, select, booleani"},
    {CS(E3, ISA_OUT_U32), .title = "Cast: trunc/sext/zext, fp↔int, f32→f16→f32, bitcast"},
    {CS(E4, ISA_OUT_F32), .title = "Vettori: extract/insert dinamici, swizzle, lane a 16 bit", .feats = "E5", .vis_lo = -100, .vis_hi = 1000},
    {CS(E5, ISA_OUT_F32), .title = "half nativo (v2f16), arrotondamento", .tol = 1e-3, .rel = 2e-3, .vis_hi = 50},
    {FR(E6a), .id = "E6", .title = "sin, cos, tan, atan2", TRIG},
    {FR(E6b), .id = "E6", .title = "asin, acos, atan, acosh", TRIG},
    {FR(E6c), .id = "E6", .title = "sinh, cosh, tanh, atanh", TRIG},
    {FR(E6d), .id = "E6", .title = "exp, exp2, exp10, asinh", TRIG},
    {FR(E6e), .id = "E6", .title = "log, log2, log10, sqrt", TRIG},
    {FR(E6f), .id = "E6", .title = "pow, powr, rsqrt", TRIG},
    {FR(E7a), .id = "E7", .title = "floor, ceil, trunc, round (lontano da 0)", .vis_lo = -8, .vis_hi = 8},
    {FR(E7b), .id = "E7", .title = "rint, fract, sign, saturate", .vis_lo = -8, .vis_hi = 8},
    {FR(E7c), .id = "E7", .title = "fma, mix, clamp, smoothstep + step", .rel = 1e-5, .vis_lo = -2, .vis_hi = 12},
    {FR(E7d), .id = "E7", .title = "min3, median3, fmod, copysign + ldexp", .rel = 1e-5, .vis_lo = -2, .vis_hi = 4},
    {CS(E7e, ISA_OUT_I32), .id = "E7", .title = "abs/min/max/clamp interi, signbit, isfinite"},
    {FR(E8a), .id = "E8", .title = "dot, length, distance, normalize", .tol = 1e-4, .rel = 1e-4, .vis_lo = -2, .vis_hi = 2},
    {FR(E8b), .id = "E8", .title = "cross, reflect, refract", .tol = 1e-4, .rel = 1e-4, .vis_lo = -2, .vis_hi = 2},
    {CS(E9a, ISA_OUT_U32), .id = "E9", .title = "ctz, popcount, reverse_bits"},
    {CS(E9z, ISA_OUT_U32), .id = "E9", .title = "clz", .skip_llvmpipe = true,
     .mac_note = "llvmpipe va in crash compilando clz (gallivm cast_type in visit_block, LLVMTypeOf(NULL))"},
    {CS(E9b, ISA_OUT_U32), .id = "E9", .title = "extract_bits (u/s), insert_bits, rotate"},
    {CS(E9c, ISA_OUT_U32), .id = "E9", .title = "mulhi (u/s), addsat, subsat"},
    {CS(E9d, ISA_OUT_U32), .id = "E9", .title = "absdiff, hadd, rhadd, interi a 64 bit"},
    {CS(E10, ISA_OUT_F32), .title = "Conversioni vettoriali (air.convert): int↔float, half, char", .feats = "E3", .rel = 1e-6, .vis_lo = -100, .vis_hi = 100},
    {CS(E11, ISA_OUT_U32), .title = "pack/unpack unorm/snorm 4x8 e 2x16, unorm565"},
    {FR(E12), .title = "Derivate: dfdx, dfdy, fwidth di funzioni lineari", .vis_lo = -1, .vis_hi = 4},
    {CS(E13, ISA_OUT_U32), .title = "all, any, select vettoriali"},
    // F: subgroups and quads
    {CS(F1a, ISA_OUT_U32), .id = "F1", .title = "simd_shuffle, shuffle_xor, quad_shuffle", SG_GRID},
    {CS(F1b, ISA_OUT_U32), .id = "F1", .title = "simd_shuffle_down/up, quad_shuffle_xor", SG_GRID},
    {CS(F2, ISA_OUT_U32), .title = "simd_broadcast (costante e uniforme), broadcast_first", SG_GRID},
    {CS(F2q, ISA_OUT_U32), .id = "F2", .title = "quad_broadcast", SG_GRID, .skip_llvmpipe = true,
     .mac_note = "llvmpipe non implementa quad_broadcast nei compute (abort: Unsupported intrinsic)"},
    {CS(F3a, ISA_OUT_U32), .id = "F3", .title = "simd_sum (float), product, min, max", SG_GRID},
    {CS(F3b, ISA_OUT_U32), .id = "F3", .title = "quad_sum, quad_product, quad_min, quad_max", SG_GRID},
    {CS(F4, ISA_OUT_U32), .title = "simd_all/any, is_first, ballot; quad_any/all/ballot", SG_GRID},
    // G: today's gaps
    {CS(G1, ISA_OUT_U32), .title = "ALU a 8/16 bit e half (forma sospetta di RenderBox)", .feats = "E3,E5"},
    {.id = "G2", .title = "Tile shading: imageblock letto e riscritto da un tile kernel", .kind = ISA_FRAG, .out = ISA_OUT_RGBA8, .w = 64,
     .h = 64, .msl = kG2, .fs = "prep", .ref = ref_pattern_swap, .extra = extra_G2, .pass = pass_G2, .draw = draw_G2, .tol = 0.006,
     .mac_note = "tile shading: il traduttore NIR non gestisce imageblock (G2), llvmpipe non ha tile pipeline"},
    {FR(G3), .title = "Argument buffer con puntatore device (gpuAddress)", .setup = setup_G3, .draw = draw_G3,
     .mac_note = "argument buffer con puntatori: non tradotti dal percorso NIR (G3)"},
    {CS(G4, ISA_OUT_F32), .title = "Chiamate indirette a visible function (function table)", .cpipe = cpipe_G4, .cbind = cbind_G4,
     .vis_hi = 8000, .mac_note = "visible function table: il percorso NIR fa solo inlining (G4)"},
};
const int isa_case_count = (int)(sizeof isa_cases / sizeof isa_cases[0]);

// ==== Runner =================================================================================================================

static const char *const kEnvNames[3] = {"VMG_ISA", "VMG_ISA_STRICT", "VMG_ISA_ONLY"};
typedef struct { char *old[3]; } env_save;

static const char *plumbing(isa_kind k) {
    return k == ISA_FRAG ? "B2,B3,B5,B6,E1,E3" : k == ISA_VERT ? "B2,B3,B4,B6,E1,E3" : "B10,C1,E1,E3";
}

const char *isa_case_only(const isa_case *c, char *b, size_t size) {
    if (c->id[0] == 'A') return NULL;
    snprintf(b, size, "%s,%s%s%s", c->id, c->feats ? c->feats : "", c->feats ? "," : "", plumbing(c->kind));
    return b;
}

static void env_push(env_save *s, const isa_case *c, int mode) {
    for (int i = 0; i < 3; i++) { const char *v = getenv(kEnvNames[i]); s->old[i] = v ? strdup(v) : NULL; }
    if (mode == ISA_MODE_ISA) {
        char only[256];
        setenv("VMG_ISA", "1", 1);
        setenv("VMG_ISA_STRICT", "1", 1);
        // Every feature on the ISA path (strict: a fallback fails the case). ISA_TEST_ONLY=1 narrows the ISA path to
        // the case's feature and its plumbing (VMG_ISA_ONLY), for bisection.
        const char *narrow = getenv("ISA_TEST_ONLY");
        if (narrow && *narrow == '1' && isa_case_only(c, only, sizeof only)) setenv("VMG_ISA_ONLY", only, 1); else unsetenv("VMG_ISA_ONLY");
    } else {
        setenv("VMG_ISA", "0", 1);
        unsetenv("VMG_ISA_STRICT");
        unsetenv("VMG_ISA_ONLY");
    }
}

static void env_pop(env_save *s) {
    for (int i = 0; i < 3; i++) {
        if (s->old[i]) setenv(kEnvNames[i], s->old[i], 1); else unsetenv(kEnvNames[i]);
        free(s->old[i]);
    }
}

static double wall_ms(uint64_t abs) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)abs * tb.numer / tb.denom / 1e6;
}

// GPU time of a completed command buffer: GPUStartTime/GPUEndTime when the driver fills them, else commit -> completed.
static double cb_ms(id<MTLCommandBuffer> cb, uint64_t t0) {
    double wall = wall_ms(mach_absolute_time() - t0);
    double s = cb.GPUStartTime, e = cb.GPUEndTime;
    return (s > 0 && e > s && (e - s) * 1000 <= wall * 1.5 + 1) ? (e - s) * 1000 : wall;
}

static bool is_int(isa_out o) { return o == ISA_OUT_U32 || o == ISA_OUT_I32; }

static void bind_render(id<MTLRenderCommandEncoder> e, ISAInputs *in) {
    for (NSNumber *k in in.buffers) {
        [e setVertexBuffer:in.buffers[k] offset:0 atIndex:k.unsignedIntegerValue];
        [e setFragmentBuffer:in.buffers[k] offset:0 atIndex:k.unsignedIntegerValue];
    }
    for (NSNumber *k in in.textures) {
        [e setVertexTexture:in.textures[k] atIndex:k.unsignedIntegerValue];
        [e setFragmentTexture:in.textures[k] atIndex:k.unsignedIntegerValue];
    }
    for (NSNumber *k in in.samplers) {
        [e setVertexSamplerState:in.samplers[k] atIndex:k.unsignedIntegerValue];
        [e setFragmentSamplerState:in.samplers[k] atIndex:k.unsignedIntegerValue];
    }
}

static void default_draw(id<MTLRenderCommandEncoder> e, const isa_case *c, int n) {
    for (int i = 0; i < n; i++) {
        if (c->kind == ISA_VERT) [e drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:(NSUInteger)(c->w * c->h)];
        else [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
}

static NSString *errText(NSError *e) { return e.localizedDescription ?: @"errore sconosciuto"; }

static bool run_render(const isa_case *c, ISAInputs *in, id<MTLCommandQueue> q, double *gpu, double *ms, NSString **note) {
    id<MTLDevice> dev = in.device;
    NSString *vsn = @(c->vs ?: "vs"), *fsn = @(c->fs ?: (c->kind == ISA_VERT ? "fp" : "fs"));
    id<MTLFunction> vs = [in.library newFunctionWithName:vsn], fs = [in.library newFunctionWithName:fsn];
    if (!vs || !fs) { *note = [NSString stringWithFormat:@"funzione %@ mancante", vs ? fsn : vsn]; return false; }
    MTLPixelFormat pf = c->out == ISA_OUT_RGBA8 ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA32Float;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs;
    d.fragmentFunction = fs;
    d.colorAttachments[0].pixelFormat = pf;
    if (c->kind == ISA_VERT) d.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
    if (c->pipe) c->pipe(d);
    NSError *err = nil;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!ps) { *note = [@"pipeline: " stringByAppendingString:errText(err)]; return false; }
    in.pipeline = ps;
    id<MTLRenderPipelineState> prep = nil;
    if (c->prep_fs) {
        d.fragmentFunction = [in.library newFunctionWithName:@(c->prep_fs)];
        prep = d.fragmentFunction ? [dev newRenderPipelineStateWithDescriptor:d error:&err] : nil;
        if (!prep) { *note = [@"pipeline di preparazione: " stringByAppendingString:errText(err)]; return false; }
    }
    if (c->extra) {
        in.extra = c->extra(in, &err);
        if (!in.extra) { *note = [@"pipeline aggiuntiva: " stringByAppendingString:errText(err)]; return false; }
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:(NSUInteger)c->w height:(NSUInteger)c->h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    if (!rt) { *note = @"render target non creato"; return false; }
    id<MTLCommandBuffer> (^encode)(int) = ^id<MTLCommandBuffer>(int n) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(c->clear[0], c->clear[1], c->clear[2], c->clear[3]);
        if (c->pass) c->pass(rp, in);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        bind_render(e, in);
        if (prep) {
            [e setRenderPipelineState:prep];
            default_draw(e, c, 1);
        }
        [e setRenderPipelineState:ps];
        if (c->draw) c->draw(e, in, c, n); else default_draw(e, c, n);
        [e endEncoding];
        return cb;
    };
    id<MTLCommandBuffer> cb = encode(1);
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) { *note = [@"command buffer: " stringByAppendingString:errText(cb.error)]; return false; }
    size_t n = (size_t)c->w * c->h;
    if (c->out == ISA_OUT_RGBA8) {
        uint8_t *b = malloc(n * 4);
        [rt getBytes:b bytesPerRow:(NSUInteger)c->w * 4 fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)c->w, (NSUInteger)c->h) mipmapLevel:0];
        for (size_t i = 0; i < n * 4; i++) gpu[i] = b[i] / 255.0;
        free(b);
    } else {
        float *b = malloc(n * 16);
        [rt getBytes:b bytesPerRow:(NSUInteger)c->w * 16 fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)c->w, (NSUInteger)c->h) mipmapLevel:0];
        for (size_t i = 0; i < n * 4; i++) gpu[i] = b[i];
        free(b);
    }
    cb = encode(ISA_TIMING_RUNS);
    uint64_t t0 = mach_absolute_time();
    [cb commit];
    [cb waitUntilCompleted];
    *ms = cb_ms(cb, t0) / ISA_TIMING_RUNS;
    return true;
}

static bool run_compute(const isa_case *c, ISAInputs *in, id<MTLCommandQueue> q, double *gpu, double *ms, NSString **note) {
    id<MTLDevice> dev = in.device;
    NSString *kn = @(c->kernel ?: "k");
    id<MTLFunction> fn = [in.library newFunctionWithName:kn];
    if (!fn) { *note = [NSString stringWithFormat:@"funzione %@ mancante", kn]; return false; }
    NSError *err = nil;
    id<MTLComputePipelineState> ps = c->cpipe ? c->cpipe(in, fn, &err) : [dev newComputePipelineStateWithFunction:fn error:&err];
    if (!ps) { *note = [@"pipeline: " stringByAppendingString:errText(err)]; return false; }
    size_t n = (size_t)c->w * c->h;
    id<MTLBuffer> ob = nil;
    id<MTLTexture> ot = nil;
    if (c->out == ISA_OUT_TEX) {
        ot = mktex(in, MTLTextureType2D, MTLPixelFormatRGBA32Float, c->w, c->h, 1, 1, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
        float *z = calloc(n, 16);
        [ot replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)c->w, (NSUInteger)c->h) mipmapLevel:0 withBytes:z bytesPerRow:(NSUInteger)c->w * 16];
        free(z);
    } else {
        ob = buf(in, NULL, n * 16);
        memset(ob.contents, 0, n * 16);
    }
    int gw = c->gw ? c->gw : c->w, gh = c->gh ? c->gh : c->h, tw = c->tw ? c->tw : 8, th = c->th ? c->th : 8;
    id<MTLCommandBuffer> (^encode)(int) = ^id<MTLCommandBuffer>(int runs) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps];
        for (NSNumber *k in in.buffers) [e setBuffer:in.buffers[k] offset:0 atIndex:k.unsignedIntegerValue];
        for (NSNumber *k in in.textures) [e setTexture:in.textures[k] atIndex:k.unsignedIntegerValue];
        for (NSNumber *k in in.samplers) [e setSamplerState:in.samplers[k] atIndex:k.unsignedIntegerValue];
        if (ob) [e setBuffer:ob offset:0 atIndex:0];
        if (ot) [e setTexture:ot atIndex:0];
        if (c->cbind) c->cbind(e, in);
        for (int r = 0; r < runs; r++) {
            if (c->groups) [e dispatchThreadgroups:MTLSizeMake((NSUInteger)(gw / tw), (NSUInteger)(gh / th), 1) threadsPerThreadgroup:MTLSizeMake((NSUInteger)tw, (NSUInteger)th, 1)];
            else [e dispatchThreads:MTLSizeMake((NSUInteger)gw, (NSUInteger)gh, 1) threadsPerThreadgroup:MTLSizeMake((NSUInteger)tw, (NSUInteger)th, 1)];
        }
        [e endEncoding];
        return cb;
    };
    id<MTLCommandBuffer> cb = encode(1);
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) { *note = [@"command buffer: " stringByAppendingString:errText(cb.error)]; return false; }
    if (ot) {
        float *b = malloc(n * 16);
        [ot getBytes:b bytesPerRow:(NSUInteger)c->w * 16 fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)c->w, (NSUInteger)c->h) mipmapLevel:0];
        for (size_t i = 0; i < n * 4; i++) gpu[i] = b[i];
        free(b);
    } else {
        const void *p = ob.contents;
        for (size_t i = 0; i < n * 4; i++)
            gpu[i] = c->out == ISA_OUT_U32 ? (double)((const uint32_t *)p)[i] : c->out == ISA_OUT_I32 ? (double)((const int32_t *)p)[i] : (double)((const float *)p)[i];
    }
    cb = encode(ISA_TIMING_RUNS);
    uint64_t t0 = mach_absolute_time();
    [cb commit];
    [cb waitUntilCompleted];
    *ms = cb_ms(cb, t0) / ISA_TIMING_RUNS;
    return true;
}

// Display: floats mapped from [vis_lo, vis_hi], integers by their low byte; alpha opaque; NaN (don't care) magenta.
static void visualize(const isa_case *c, const double *v, uint8_t *rgba) {
    double lo = c->vis_lo, hi = c->vis_hi;
    if (lo == 0 && hi == 0) hi = 1;
    for (int i = 0; i < c->w * c->h; i++) {
        for (int k = 0; k < 3; k++) {
            double x = v[i * 4 + k];
            if (isnan(x)) { rgba[i * 4] = 255; rgba[i * 4 + 1] = 0; rgba[i * 4 + 2] = 255; break; }
            if (is_int(c->out)) rgba[i * 4 + k] = (uint8_t)((uint32_t)(int64_t)x * 37u);
            else { double t = (x - lo) / (hi - lo); rgba[i * 4 + k] = (uint8_t)lround((t < 0 ? 0 : t > 1 ? 1 : t) * 255); }
        }
        rgba[i * 4 + 3] = 255;
    }
}

static void tolerance(const isa_case *c, double *tol, double *rel) {
    *tol = c->tol ? c->tol : c->out == ISA_OUT_RGBA8 ? 1.5 / 255 : is_int(c->out) ? 0 : 1e-5;
    *rel = c->rel;
}

isa_result isa_run_case(id<MTLDevice> dev, const isa_case *c, int mode, uint8_t *rgba_out, float *diff_out) {
    isa_result r = {0};
    size_t n = (size_t)c->w * c->h;
    double *gpu = calloc(n * 4, sizeof(double)), *ref = calloc(n * 4, sizeof(double));
    NSString *note = nil;
    bool ran = false;
    @autoreleasepool {
        env_save es;
        env_push(&es, c, mode);
        ISAInputs *in = [ISAInputs new];
        in.device = dev;
        NSError *err = nil;
        // A new library and new pipelines every run: the driver reads the VMG_ISA* variables at shader creation.
        in.library = [dev newLibraryWithSource:[@MSL_HEAD stringByAppendingString:@(c->msl)] options:[MTLCompileOptions new] error:&err];
        if (!in.library) note = [@"libreria: " stringByAppendingString:errText(err)];
        else {
            if (c->setup) c->setup(in);
            id<MTLCommandQueue> q = [dev newCommandQueue];
            ran = c->kind == ISA_COMPUTE ? run_compute(c, in, q, gpu, &r.gpu_ms, &note) : run_render(c, in, q, gpu, &r.gpu_ms, &note);
        }
        env_pop(&es);
    }
    c->ref(c, ran ? gpu : NULL, ref);
    const char *dump = getenv("ISA_DUMP");   // "x,y": print that pixel (debugging references)
    int dx, dy;
    if (ran && dump && sscanf(dump, "%d,%d", &dx, &dy) == 2 && dx >= 0 && dy >= 0 && dx < c->w && dy < c->h) {
        const double *gp = gpu + ((size_t)dy * c->w + dx) * 4, *rp = ref + ((size_t)dy * c->w + dx) * 4;
        fprintf(stderr, "%s (%d,%d) %s: GPU %.9g %.9g %.9g %.9g | ref %.9g %.9g %.9g %.9g\n", c->id, dx, dy, mode ? "NIR" : "ISA",
                gp[0], gp[1], gp[2], gp[3], rp[0], rp[1], rp[2], rp[3]);
    }
    if (ran) {
        double tol, rel;
        tolerance(c, &tol, &rel);
        size_t bad = 0;
        for (size_t i = 0; i < n; i++) {
            double worst = -1;
            bool b = false;
            for (int k = 0; k < 4; k++) {
                double e = ref[i * 4 + k], g = gpu[i * 4 + k];
                if (isnan(e)) continue;
                double lim = tol + rel * fabs(e), err = isinf(e) ? (g == e ? 0 : INFINITY) : fabs(g - e);
                if (isnan(g)) err = INFINITY;
                if (!isinf(err) && err > r.max_err) r.max_err = err;
                if (isinf(err) && r.max_err < 1e30) r.max_err = 1e30;
                if (err > lim) b = true;
                double q = lim > 0 ? err / lim : (err > 0 ? 1e9 : 0);
                if (q > worst) worst = q;
            }
            if (b) {
                static int dump_bad = -1;   // ISA_DUMP_BAD=N: print the first N wrong pixels (debugging)
                if (dump_bad < 0) dump_bad = getenv("ISA_DUMP_BAD") ? atoi(getenv("ISA_DUMP_BAD")) : 0;
                if ((int)bad < dump_bad)
                    fprintf(stderr, "%s bad (%zu,%zu): GPU %.9g %.9g %.9g %.9g | ref %.9g %.9g %.9g %.9g\n", c->id, i % (size_t)c->w,
                            i / (size_t)c->w, gpu[i * 4], gpu[i * 4 + 1], gpu[i * 4 + 2], gpu[i * 4 + 3], ref[i * 4], ref[i * 4 + 1],
                            ref[i * 4 + 2], ref[i * 4 + 3]);
                bad++;
            }
            if (diff_out) diff_out[i] = (float)worst;
        }
        r.pct_bad = 100.0 * bad / n;
        r.ok = r.pct_bad <= c->max_bad_pct;
        if (!note && !r.ok) {
            // First bad pixel, for the log.
            for (size_t i = 0; i < n && !note; i++)
                for (int k = 0; k < 4; k++) {
                    double e = ref[i * 4 + k], g = gpu[i * 4 + k];
                    if (isnan(e)) continue;
                    double tol2, rel2;
                    tolerance(c, &tol2, &rel2);
                    if (isnan(g) || fabs(g - e) > tol2 + rel2 * fabs(e)) {
                        note = [NSString stringWithFormat:@"primo errore (%zu,%zu) canale %d: GPU %.9g, atteso %.9g", i % (size_t)c->w,
                                i / (size_t)c->w, k, g, e];
                        break;
                    }
                }
        }
        if (rgba_out) visualize(c, gpu, rgba_out);
    } else {
        r.ok = false;
        r.pct_bad = 100;
        if (diff_out) for (size_t i = 0; i < n; i++) diff_out[i] = -1;
        if (rgba_out) memset(rgba_out, 0, n * 4);
    }
    if (note) snprintf(r.note, sizeof r.note, "%s", note.UTF8String);
    free(gpu);
    free(ref);
    return r;
}

void isa_cpu_reference(const isa_case *c, uint8_t *rgba_out) {
    size_t n = (size_t)c->w * c->h;
    double *ref = calloc(n * 4, sizeof(double));
    c->ref(c, NULL, ref);
    visualize(c, ref, rgba_out);
    free(ref);
}
