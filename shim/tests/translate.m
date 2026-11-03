// Phase 3 execution test: shaders from tests/corpus/apps.metal go through the AIR -> GLSL
// translator and their results are compared with values computed by hand.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import <IOSurface/IOSurface.h>
#import "TSMetal.h"

static int failures, checks;
#define CHECK(cond, ...) do { checks++; if (cond) printf("  ok   "); else { failures++; printf("  FAIL "); } \
    printf(__VA_ARGS__); printf("\n"); } while (0)

static NSString *const kExtraMSL = @
    "\nvertex TexData tex_vertex(uint vid [[vertex_id]]) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
    "  TexData o; o.position = float4(p * 2.0 - 1.0, 0, 1); o.textureCoordinate = float2(p.x, 1.0 - p.y); return o; }\n"
    // air.pack.* / air.unpack.* (VectorKit's Icon::shadow_vertex uses pack_half_to_unorm4x8).
    "struct PackIn { float4 u8; float4 s8; float4 u16s16; uint4 words; };\n"
    "struct PackOut { float4 unpacked [[color(0)]]; uint4 packed [[color(1)]]; };\n"
    "fragment PackOut packing(constant PackIn &in [[buffer(0)]]) {\n"
    "  PackOut o;\n"
    "  o.packed = uint4(pack_half_to_unorm4x8(half4(in.u8)), pack_float_to_snorm4x8(in.s8),\n"
    "                   pack_float_to_unorm2x16(in.u16s16.xy), pack_float_to_snorm2x16(in.u16s16.zw));\n"
    "  float4 a = unpack_unorm4x8_to_float(in.words.x);\n"
    "  float2 b = unpack_snorm2x16_to_float(in.words.y);\n"
    "  half4 c = unpack_snorm4x8_to_half(in.words.z);\n"
    "  float2 d = unpack_unorm2x16_to_float(in.words.w);\n"
    "  o.unpacked = float4(a.y, b.x, float(c.x), d.y);\n"
    "  return o; }\n"
    // ANGLE (Chrome's WebGL) resolves antialiased framebuffers by drawing with a texture2d_ms read.
    "fragment float4 read_ms(TexData in [[stage_in]], texture2d_ms<float, access::read> t [[texture(0)]]) {\n"
    "  uint2 c = uint2(in.textureCoordinate * float2(t.get_width(), t.get_height()));\n"
    "  float4 s = 0;\n"
    "  for (uint i = 0; i < t.get_num_samples(); i++) s += t.read(c, i);\n"
    "  return s / float(t.get_num_samples()); }\n"
    // Arrays of arrays (not in GLSL 4.10): RenderBox's filter_blur copies a struct with float[3][2] and
    // float[8][2] by value and indexes it dynamically; plus a local 2D array and a constant 2D table.
    "struct AoA { float m[3][2]; float offs[8][2]; int n; int k; };\n"
    "constant float aoa_tab[2][2] = { { 1, 2 }, { 3, 4 } };\n"
    "fragment float4 array_of_arrays(constant AoA &in [[buffer(0)]]) {\n"
    "  AoA g = in;\n"
    "  float2 s = 0;\n"
    "  for (int i = 0; i < g.n; i++) s += float2(g.offs[i][0], g.offs[i][1]);\n"
    "  float t[2][3];\n"
    "  for (int i = 0; i < 2; i++) for (int j = 0; j < 3; j++) t[i][j] = float(i * 3 + j);\n"
    "  t[g.k & 1][g.k % 3] += 100;\n"
    "  return float4(s, g.m[g.k][1] + aoa_tab[g.k & 1][1], t[1][g.k % 3]); }\n"
    // constexpr sampler in pixel coordinates (RenderBox's filter_blur): texel (x, y) is at (x + 0.5, y + 0.5).
    "fragment float4 pixel_coords(float4 pos [[position]], texture2d<float> t [[texture(0)]]) {\n"
    "  constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);\n"
    "  return t.sample(s, float2(3.5, 1.5) - floor(pos.xy) * float2(1, 0)); }\n"
    // Visible function resolved at pipeline creation (RenderBox's custom_effect / primitive_custom call SwiftUI's glass
    // shaders this way: `<name>.MTL_VISIBLE_FN_REF`, linked through MTLLinkedFunctions.privateFunctions).
    "[[visible]] float4 tint_fn(float2 p, float4 c);\n"
    "fragment float4 uses_visible(float4 pos [[position]], constant float4 &c [[buffer(0)]]) {\n"
    "  return tint_fn(floor(pos.xy), c); }\n"
    // Type punning in private memory (RenderBox's alpha_effect after SROA): two halves stored into a float, read as
    // a float; a float stored and read back as its bits.
    "fragment float4 punned(constant half4 &h [[buffer(0)]], constant float &f [[buffer(1)]]) {\n"
    "  thread float x; thread half *hp = (thread half *)&x; hp[0] = h.x; hp[1] = h.y;\n"
    "  thread uint u; *(thread float *)&u = f;\n"
    "  return float4(as_type<uint>(x) & 0xFFFF, as_type<uint>(x) >> 16, u >> 16, u & 0xFFFF); }\n"
    // A texel offset that is not a constant (QuartzCore's simple_rim loops over it); a vector lane picked by a bool.
    "fragment float4 dynamic_offset(float4 pos [[position]], texture2d<float> t [[texture(0)]], constant int2 &o [[buffer(0)]]) {\n"
    "  constexpr sampler s(filter::nearest, address::clamp_to_edge);\n"
    "  float2 sel = float2(1, 2);\n"
    "  return float4(t.sample(s, float2(1.5, 1.5) / 4.0, o).b, sel[o.x > 0], 0, 1); }\n"
    // Sampling the pass's own color attachment (RenderBox's glass shape passes): needs a texture barrier.
    "fragment float4 read_target(float4 pos [[position]], texture2d<float> t [[texture(0)]]) {\n"
    "  return t.read(uint2(pos.xy)) + float4(0.25, 0, 0, 0); }\n"
    "fragment float4 fill_quarter(float4 pos [[position]]) { return float4(0.25, 0.5, 0, 1); }\n";

static NSString *const kVisibleMSL = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "[[visible]] float4 tint_fn(float2 p, float4 c) { return float4(c.rgb * 0.5, p.x == 1.0 ? 1.0 : 0.0); }\n";

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> lib;

static id<MTLTexture> target(MTLPixelFormat f, NSUInteger size) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:size height:size mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [dev newTextureWithDescriptor:d];
}

static simd_float4 pixelF(id<MTLTexture> t, NSUInteger x, NSUInteger y) {
    simd_float4 p = 0;
    [t getBytes:&p bytesPerRow:16 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
    return p;
}

static uint32_t pixel8(id<MTLTexture> t, NSUInteger x, NSUInteger y) {
    uint32_t p = 0;
    [t getBytes:&p bytesPerRow:4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
    return p;
}

static BOOL close4(simd_float4 a, simd_float4 b, float eps) { return simd_reduce_max(simd_abs(a - b)) <= eps; }
static BOOL near8(uint32_t p, int r, int g, int b, int a) {
    int c[4] = { p & 0xff, (p >> 8) & 0xff, (p >> 16) & 0xff, p >> 24 }, e[4] = { r, g, b, a };
    for (int i = 0; i < 4; i++) if (abs(c[i] - e[i]) > 2) return NO;
    return YES;
}

static id<MTLRenderPipelineState> pipeline(NSString *vs, NSString *fs, MTLVertexDescriptor *vd, NSArray *formats, MTLPixelFormat depth) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:vs];
    d.fragmentFunction = [lib newFunctionWithName:fs];
    d.vertexDescriptor = vd;
    for (NSUInteger i = 0; i < formats.count; i++) d.colorAttachments[i].pixelFormat = [formats[i] unsignedIntegerValue];
    d.depthAttachmentPixelFormat = depth;
    NSError *e = nil;
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) printf("  pipeline %s/%s failed: %s\n", vs.UTF8String, fs.UTF8String, e.description.UTF8String);
    return p;
}

static void render(NSArray<id<MTLTexture>> *colors, id<MTLTexture> depth, void (^encode)(id<MTLRenderCommandEncoder>)) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (NSUInteger i = 0; i < colors.count; i++) {
        rp.colorAttachments[i].texture = colors[i];
        rp.colorAttachments[i].loadAction = MTLLoadActionClear;
        rp.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, 0);
    }
    if (depth) {
        rp.depthAttachment.texture = depth;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.clearDepth = 1;
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    encode(e);
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

static void testAppleTriangle(void) {
    printf("Apple Hello Triangle (vertex pulling, constant pointers)\n");
    typedef struct { simd_float2 position; simd_float4 color; } AAPLVertex;   // 32 bytes, color at 16
    static AAPLVertex v[3]; AAPLVertex v0[3] = { {{-32, -32}, {0.2f, 0.4f, 0.6f, 1}}, {{96, -32}, {0.2f, 0.4f, 0.6f, 1}}, {{-32, 96}, {0.2f, 0.4f, 0.6f, 1}} };
    memcpy(v, v0, sizeof v);
    simd_uint2 viewport = { 64, 64 };
    id<MTLTexture> t = target(MTLPixelFormatRGBA8Unorm, 64);
    id<MTLRenderPipelineState> p = pipeline(@"apple_vertex", @"apple_fragment", nil, @[@(MTLPixelFormatRGBA8Unorm)], MTLPixelFormatInvalid);
    render(@[t], nil, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:p];
        [e setVertexBytes:v length:sizeof v atIndex:0];
        [e setVertexBytes:&viewport length:sizeof viewport atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    });
    CHECK(near8(pixel8(t, 32, 32), 51, 102, 153, 255), "full-screen triangle with the buffer color (0x%08x)", pixel8(t, 32, 32));
}

static void testNagaEgui(void) {
    printf("naga / egui (packed u32 color, gamma decode, select, discard)\n");
    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[1].format = MTLVertexFormatFloat2;
    vd.attributes[1].offset = 8;
    vd.attributes[2].format = MTLVertexFormatUInt;
    vd.attributes[2].offset = 16;
    vd.layouts[0].stride = 20;
    typedef struct __attribute__((packed)) { float pos[2], uv[2]; uint32_t color; } V;
    uint32_t c = 0xFF0080FF;            // r=255 g=128 b=0 a=255
    static V quad[4], hole[4]; V quad0[4] = { {{0, 0}, {0, 0}, c}, {{64, 0}, {1, 0}, c}, {{0, 64}, {0, 1}, c}, {{64, 64}, {1, 1}, c} };
    V hole0[4] = { {{0, 0}, {0, 0}, 0x00FFFFFF}, {{32, 0}, {1, 0}, 0x00FFFFFF}, {{0, 32}, {0, 1}, 0x00FFFFFF}, {{32, 32}, {1, 1}, 0x00FFFFFF} };
    memcpy(quad, quad0, sizeof quad);
    memcpy(hole, hole0, sizeof hole);
    struct { simd_float2 screen; uint32_t pad[2]; } locals = { {64, 64}, {0, 0} };
    MTLTextureDescriptor *wd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    id<MTLTexture> white = [dev newTextureWithDescriptor:wd];
    uint32_t w = 0xffffffff;
    [white replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&w bytesPerRow:4];
    id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
    id<MTLTexture> t = target(MTLPixelFormatRGBA8Unorm, 64);
    id<MTLRenderPipelineState> p = pipeline(@"naga_vs_main", @"naga_fs_main", vd, @[@(MTLPixelFormatRGBA8Unorm)], MTLPixelFormatInvalid);
    render(@[t], nil, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:p];
        [e setVertexBytes:&locals length:sizeof locals atIndex:1];
        [e setFragmentTexture:white atIndex:0];
        [e setFragmentSamplerState:s atIndex:0];
        [e setVertexBytes:quad length:sizeof quad atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [e setVertexBytes:hole length:sizeof hole atIndex:0];      // alpha 0 -> discarded, must not overwrite
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    });
    float g = powf((128 / 255.f + 0.055f) / 1.055f, 2.4f);
    CHECK(near8(pixel8(t, 40, 40), 255, (int)roundf(g * 255), 0, 255), "linear color from packed sRGB u32 (0x%08x, g expected %d)", pixel8(t, 40, 40), (int)roundf(g * 255));
    CHECK(near8(pixel8(t, 10, 10), 255, (int)roundf(g * 255), 0, 255), "transparent quad discarded (0x%08x)", pixel8(t, 10, 10));
}

// Material layout as Metal sees it: packed_float3 @0, roughness @12, half4 tint @16, weights[4] @24, flags @40, size 48.
static void putMaterial(uint8_t *m, float roughness, uint32_t flags) {
    float albedo[3] = { 1, 2, 3 }, weights[4] = { 1, 1, 1, 1 };
    __fp16 tint[4] = { 0.5, 0.25, 1, 1 };
    memcpy(m, albedo, 12);
    memcpy(m + 12, &roughness, 4);
    memcpy(m + 16, tint, 8);
    memcpy(m + 24, weights, 16);
    memcpy(m + 40, &flags, 4);
}

static void testLayoutsAndControlFlow(void) {
    printf("buffer layouts (packed_float3, half, arrays, instance stride) + control flow\n");
    uint8_t mats[96] = {0};
    putMaterial(mats, 0, 0xffffffff);          // instance 0: wrong on purpose
    putMaterial(mats + 48, 1, 88);             // instance 1: roughness 1, flags 88 -> (88 >> 3) % 5 = 1
    float pos[9] = { -1, -1, 0.6f, 3, -1, 0.6f, -1, 3, 0.6f };   // packed_float3, stride 12
    id<MTLBuffer> mb = [dev newBufferWithBytes:mats length:sizeof mats options:0];
    id<MTLBuffer> pb = [dev newBufferWithBytes:pos length:sizeof pos options:0];
    MTLTextureDescriptor *hd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    id<MTLTexture> half = [dev newTextureWithDescriptor:hd];
    uint32_t h = 0x80808080;
    [half replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&h bytesPerRow:4];
    id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
    id<MTLRenderPipelineState> p = pipeline(@"layout_vertex", @"control_flow", nil, @[@(MTLPixelFormatRGBA32Float)], MTLPixelFormatInvalid);
    simd_float4 expect[4] = { {1, 0, 0, 1}, {128 / 255.f, 128 / 255.f, 128 / 255.f, 128 / 255.f}, {9, 0, 0, 0}, {3, 3, 13, 1} };
    const char *what[4] = { "switch case 0", "case 1: 5-tap loop over a constant table", "case 2: while/break over a local array",
                            "default: c = albedo*tint*sum(weights) + flags math (instance 1 via baseInstance)" };
    for (int mode = 0; mode < 4; mode++) {
        id<MTLTexture> t = target(MTLPixelFormatRGBA32Float, 16);
        render(@[t], nil, ^(id<MTLRenderCommandEncoder> e) {
            [e setRenderPipelineState:p];
            [e setVertexBuffer:mb offset:0 atIndex:2];
            [e setVertexBuffer:pb offset:0 atIndex:3];
            [e setFragmentBytes:&mode length:4 atIndex:0];
            [e setFragmentTexture:half atIndex:0];
            [e setFragmentSamplerState:s atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:1 baseInstance:1];
        });
        simd_float4 got = pixelF(t, 8, 8);
        CHECK(close4(got, expect[mode], 0.01f), "%s (%.3f %.3f %.3f %.3f)", what[mode], got.x, got.y, got.z, got.w);
    }
    // P1: the material loads are coalesced into 16-byte fetches, valid for 16-aligned bindings only. The same
    // materials at offsets 4 and 128 of one buffer: an aligned draw, then setVertexBufferOffset to 4 in the
    // same pass must switch to the word-by-word variant (TSU_v2).
    uint8_t shifted[256] = {0};
    memcpy(shifted + 4, mats, sizeof mats);
    memcpy(shifted + 128, mats, sizeof mats);
    putMaterial(shifted + 128 + 48, 1, 96);   // the aligned draw's instance 1: flags 96 -> (3, 3, 13) + 1, then overdrawn
    id<MTLBuffer> sb = [dev newBufferWithBytes:shifted length:sizeof shifted options:0];
    for (int pass = 0; pass < 2; pass++) {
        id<MTLTexture> t = target(MTLPixelFormatRGBA32Float, 16);
        int mode = 3;
        render(@[t], nil, ^(id<MTLRenderCommandEncoder> e) {
            [e setRenderPipelineState:p];
            [e setVertexBuffer:sb offset:pass ? 4 : 128 atIndex:2];
            [e setVertexBuffer:pb offset:0 atIndex:3];
            [e setFragmentBytes:&mode length:4 atIndex:0];
            [e setFragmentTexture:half atIndex:0];
            [e setFragmentSamplerState:s atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:1 baseInstance:1];
            if (!pass) {
                [e setVertexBufferOffset:4 atIndex:2];
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:1 baseInstance:1];
            }
        });
        simd_float4 got = pixelF(t, 8, 8);
        CHECK(close4(got, expect[3], 0.01f), "materials bound at offset 4 (%s): word-by-word variant (%.3f %.3f %.3f %.3f)",
              pass ? "new pass" : "after an aligned draw in the same pass", got.x, got.y, got.z, got.w);
    }
}

static void testGBuffer(void) {
    printf("MRT (float, half, uint) + depth output + front_facing\n");
    float pos[9] = { -1, -1, 0.6f, 3, -1, 0.6f, -1, 3, 0.6f };
    uint8_t mats[48] = {0};
    putMaterial(mats, 1, 0);
    id<MTLBuffer> mb = [dev newBufferWithBytes:mats length:sizeof mats options:0];
    id<MTLBuffer> pb = [dev newBufferWithBytes:pos length:sizeof pos options:0];
    id<MTLTexture> c0 = target(MTLPixelFormatRGBA32Float, 16), c1 = target(MTLPixelFormatRGBA16Float, 16), c2 = target(MTLPixelFormatRGBA32Uint, 16);
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> depth = [dev newTextureWithDescriptor:dd];
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
    dsd.depthCompareFunction = MTLCompareFunctionAlways;
    dsd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dsd];
    id<MTLRenderPipelineState> p = pipeline(@"layout_vertex", @"gbuffer", nil,
        @[@(MTLPixelFormatRGBA32Float), @(MTLPixelFormatRGBA16Float), @(MTLPixelFormatRGBA32Uint)], MTLPixelFormatDepth32Float);
    render(@[c0, c1, c2], depth, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:p];
        [e setDepthStencilState:ds];
        [e setVertexBuffer:mb offset:0 atIndex:2];
        [e setVertexBuffer:pb offset:0 atIndex:3];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    });
    uint32_t ids[4] = {0};
    [c2 getBytes:ids bytesPerRow:16 fromRegion:MTLRegionMake2D(5, 9, 1, 1) mipmapLevel:0];
    CHECK(ids[0] == 5 && ids[1] == 9 && ids[2] == 7 && ids[3] == 9, "uint4 target = (x, y, 7, 9) from [[position]] (%u %u %u %u)", ids[0], ids[1], ids[2], ids[3]);
    __fp16 n[4] = {0};
    [c1 getBytes:n bytesPerRow:8 fromRegion:MTLRegionMake2D(5, 9, 1, 1) mipmapLevel:0];
    CHECK(n[0] == -1, "half4 target: back-facing (CCW with default CW winding) -> -1 (%.1f)", (float)n[0]);
    simd_float4 c = pixelF(c0, 5, 9);   // instance 0, flags 0: albedo * tint * 4 = (2, 2, 12)
    CHECK(close4(c, (simd_float4){2, 2, 12, 1}, 0.01f), "float4 target (%.2f %.2f %.2f %.2f)", c.x, c.y, c.z, c.w);
    float d = 0;
    [depth getBytes:&d bytesPerRow:4 fromRegion:MTLRegionMake2D(5, 9, 1, 1) mipmapLevel:0];
    CHECK(fabsf(d - 0.3f) < 0.001f, "[[depth(any)]] = position.z * 0.5 (%.4f)", d);
}

static void testConstexprSampler(void) {
    printf("constexpr sampler (linear) + half texture\n");
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:2 mipmapped:NO];
    id<MTLTexture> checker = [dev newTextureWithDescriptor:d];
    uint32_t texels[4] = { 0xff000000, 0xffffffff, 0xffffffff, 0xff000000 };
    [checker replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:texels bytesPerRow:8];
    id<MTLTexture> t = target(MTLPixelFormatRGBA8Unorm, 2);
    id<MTLRenderPipelineState> p = pipeline(@"tex_vertex", @"apple_textured", nil, @[@(MTLPixelFormatRGBA8Unorm)], MTLPixelFormatInvalid);
    // A 2x2 target samples at the texel centers of a 2x2 texture: linear filtering then equals nearest,
    // so render to 1x1 instead, which samples the exact middle where the four texels blend.
    id<MTLTexture> one = target(MTLPixelFormatRGBA8Unorm, 1);
    render(@[one], nil, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:p];
        [e setFragmentTexture:checker atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    });
    int v = pixel8(one, 0, 0) & 0xff;
    CHECK(v > 120 && v < 136, "linear filtering from the constexpr sampler blends the checker (%d)", v);
    (void)t;
}

static void testPacking(void) {
    printf("pack/unpack to unorm/snorm 4x8 and 2x16\n");
    struct { simd_float4 u8, s8, u16s16; simd_uint4 words; } in = {
        { 0.25f, 0.5f, 1, 0 }, { -1, -0.25f, 0.75f, 1 }, { 0.25f, 1, -0.25f, 1 },
        { 0x00FF8040, 0x7FFFE000, 0x7F5FE081, 0xFFFF4000 } };
    id<MTLTexture> f = target(MTLPixelFormatRGBA32Float, 4), u = target(MTLPixelFormatRGBA32Uint, 4);
    id<MTLRenderPipelineState> p = pipeline(@"tex_vertex", @"packing", nil, @[@(MTLPixelFormatRGBA32Float), @(MTLPixelFormatRGBA32Uint)], MTLPixelFormatInvalid);
    render(@[f, u], nil, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:p];
        [e setFragmentBytes:&in length:sizeof in atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    });
    uint32_t w[4] = {0};
    [u getBytes:w bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    CHECK(w[0] == 0x00FF8040 && w[1] == 0x7F5FE081 && w[2] == 0xFFFF4000 && w[3] == 0x7FFFE000,
          "pack unorm4x8 (half), snorm4x8, unorm2x16, snorm2x16 (%08x %08x %08x %08x)", w[0], w[1], w[2], w[3]);
    simd_float4 v = pixelF(f, 1, 1);
    CHECK(close4(v, (simd_float4){ 128 / 255.f, -8192 / 32767.f, -1, 1 }, 0.001f),
          "unpack unorm4x8, snorm2x16, snorm4x8 (half), unorm2x16 (%.4f %.4f %.4f %.4f)", v.x, v.y, v.z, v.w);
}

static void testMultisampleRead(void) {
    printf("texture2d_ms read of a cleared 4x MSAA texture (draw-based resolve)\n");
    MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    md.textureType = MTLTextureType2DMultisample;
    md.sampleCount = 4;
    md.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    md.storageMode = MTLStorageModePrivate;
    id<MTLTexture> ms = [dev newTextureWithDescriptor:md];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = ms;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 1);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    [cb commit];
    id<MTLTexture> t = target(MTLPixelFormatRGBA8Unorm, 16);
    id<MTLRenderPipelineState> p = pipeline(@"tex_vertex", @"read_ms", nil, @[@(MTLPixelFormatRGBA8Unorm)], MTLPixelFormatInvalid);
    render(@[t], nil, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:p];
        [e setFragmentTexture:ms atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    });
    CHECK(near8(pixel8(t, 8, 8), 51, 102, 153, 255), "resolved by drawing (0x%08x)", pixel8(t, 8, 8));
}

static void testArrayOfArrays(void) {
    printf("arrays of arrays: struct copied by value, local 2D array, constant 2D table\n");
    struct { float m[3][2]; float offs[8][2]; int n, k; } in = { { { 0, 1 }, { 2, 3 }, { 4, 5 } }, {{0}}, 5, 1 };
    for (int i = 0; i < 8; i++) { in.offs[i][0] = i; in.offs[i][1] = 10 * i; }
    id<MTLTexture> f = target(MTLPixelFormatRGBA32Float, 4);
    id<MTLRenderPipelineState> p = pipeline(@"tex_vertex", @"array_of_arrays", nil, @[@(MTLPixelFormatRGBA32Float)], MTLPixelFormatInvalid);
    render(@[f], nil, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:p];
        [e setFragmentBytes:&in length:sizeof in atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    });
    simd_float4 v = pixelF(f, 1, 1);
    CHECK(close4(v, (simd_float4){ 10, 100, 7, 104 }, 0.001f), "dynamic indexing into wrapped inner arrays (%.1f %.1f %.1f %.1f)", v.x, v.y, v.z, v.w);
}

static void testPixelCoords(void) {
    printf("constexpr sampler with coord::pixel, 2D texture and IOSurface (rectangle) texture\n");
    uint32_t texels[4 * 4];
    for (int i = 0; i < 16; i++) texels[i] = 0xFF000000u | (uint32_t)(i * 16);   // BGRA: blue = 16 * index
    NSDictionary *props = @{ (id)kIOSurfaceWidth: @4, (id)kIOSurfaceHeight: @4, (id)kIOSurfaceBytesPerElement: @4,
                             (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
    IOSurfaceRef ios = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> plain = [dev newTextureWithDescriptor:d], surf = [dev newTextureWithDescriptor:d iosurface:ios plane:0];
    for (id<MTLTexture> src in @[plain, surf]) [src replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texels bytesPerRow:16];
    id<MTLRenderPipelineState> p = pipeline(@"tex_vertex", @"pixel_coords", nil, @[@(MTLPixelFormatBGRA8Unorm)], MTLPixelFormatInvalid);
    NSArray *names = @[@"2D texture", @"IOSurface"];
    for (NSUInteger k = 0; k < 2; k++) {
        id<MTLTexture> src = k ? surf : plain, t = target(MTLPixelFormatBGRA8Unorm, 4);
        render(@[t], nil, ^(id<MTLRenderCommandEncoder> e) {
            [e setRenderPipelineState:p];
            [e setFragmentTexture:src atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        });
        // Output column x samples texel (3 - x, 1) = index 4 + 3 - x.
        BOOL ok = YES;
        for (int x = 0; x < 4; x++) ok &= (pixel8(t, x, 2) & 0xFF) == (uint32_t)((4 + 3 - x) * 16);
        CHECK(ok, "%s: texel at pixel coordinates (got blue %u %u %u %u, expected 112 96 80 64)", [names[k] UTF8String],
              pixel8(t, 0, 2) & 0xFF, pixel8(t, 1, 2) & 0xFF, pixel8(t, 2, 2) & 0xFF, pixel8(t, 3, 2) & 0xFF);
    }
    CFRelease(ios);
}

static void testVisibleFunction(void) {
    printf("visible function linked at pipeline creation (MTLLinkedFunctions.privateFunctions)\n");
    NSError *err = nil;
    id<MTLLibrary> vis = [dev newLibraryWithSource:kVisibleMSL options:nil error:&err];
    id<MTLFunction> fn = [vis newFunctionWithName:@"tint_fn"];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"tex_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"uses_visible"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    MTLLinkedFunctions *lf = [MTLLinkedFunctions linkedFunctions];
    lf.privateFunctions = fn ? @[fn] : @[];
    d.fragmentLinkedFunctions = lf;
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    BOOL fallback = [[(id)p valueForKey:@"usesFallback"] boolValue];
    id<MTLTexture> f = target(MTLPixelFormatRGBA32Float, 4);
    simd_float4 c = { 0.5f, 1.0f, 2.0f, 0 };
    render(@[f], nil, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:p];
        [e setFragmentBytes:&c length:sizeof c atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    });
    simd_float4 a = pixelF(f, 1, 2), b = pixelF(f, 2, 2);
    CHECK(!fallback && close4(a, (simd_float4){ 0.25f, 0.5f, 1, 1 }, 0.001f) && close4(b, (simd_float4){ 0.25f, 0.5f, 1, 0 }, 0.001f),
          "linked tint_fn ran (%.2f %.2f %.2f %.2f / alpha %.0f, fallback %d)", a.x, a.y, a.z, a.w, b.w, fallback);
}

static void testPunnedPrivateMemory(void) {
    printf("type-punned private memory: halves into a float, a float read as uint\n");
    static const __fp16 h[4] = { 1.0, -2.0, 0, 0 };   // 0x3C00, 0xC000
    float fv = 1.5f;                      // 0x3FC00000
    id<MTLTexture> f = target(MTLPixelFormatRGBA32Float, 4);
    id<MTLRenderPipelineState> p = pipeline(@"tex_vertex", @"punned", nil, @[@(MTLPixelFormatRGBA32Float)], MTLPixelFormatInvalid);
    render(@[f], nil, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:p];
        [e setFragmentBytes:&h[0] length:4 * sizeof(__fp16) atIndex:0];
        [e setFragmentBytes:&fv length:sizeof fv atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    });
    simd_float4 v = pixelF(f, 1, 1);
    CHECK(close4(v, (simd_float4){ 0x3C00, 0xC000, 0x3FC0, 0 }, 0.5f), "bits 0x%04x 0x%04x / 0x%04x 0x%04x (expected 3c00 c000 / 3fc0 0000)",
          (unsigned)v.x, (unsigned)v.y, (unsigned)v.z, (unsigned)v.w);
}

static void testDynamicOffset(void) {
    printf("sample with a texel offset that is not a constant; bool vector index\n");
    uint32_t texels[16];
    for (int i = 0; i < 16; i++) texels[i] = 0xFF000000u | (uint32_t)(i * 16);   // BGRA: blue = 16 * index
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
    id<MTLTexture> src = [dev newTextureWithDescriptor:d];
    [src replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texels bytesPerRow:16];
    id<MTLRenderPipelineState> p = pipeline(@"tex_vertex", @"dynamic_offset", nil, @[@(MTLPixelFormatRGBA32Float)], MTLPixelFormatInvalid);
    static const int off[2][2] = { { 1, 2 }, { -1, 0 } };
    float blue[2], sel[2];
    for (int k = 0; k < 2; k++) {
        id<MTLTexture> f = target(MTLPixelFormatRGBA32Float, 4);
        const int *o = off[k];
        render(@[f], nil, ^(id<MTLRenderCommandEncoder> e) {
            [e setRenderPipelineState:p];
            [e setFragmentTexture:src atIndex:0];
            [e setFragmentBytes:o length:2 * sizeof(int) atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        });
        simd_float4 v = pixelF(f, 0, 0);
        blue[k] = roundf(v.x * 255); sel[k] = v.y;
    }
    // Texel (1, 1) moved by (1, 2) -> (2, 3) = index 14; by (-1, 0) -> (0, 1) = index 4.
    CHECK(blue[0] == 14 * 16 && blue[1] == 4 * 16 && sel[0] == 2 && sel[1] == 1, "offset texels %.0f %.0f (expected 224 64), lanes %.0f %.0f",
          blue[0], blue[1], sel[0], sel[1]);
}

static void testReadOwnTarget(void) {
    printf("draws sampling their own color attachment (texture barrier)\n");
    id<MTLTexture> t = target(MTLPixelFormatRGBA32Float, 64);
    id<MTLRenderPipelineState> fill = pipeline(@"tex_vertex", @"fill_quarter", nil, @[@(MTLPixelFormatRGBA32Float)], MTLPixelFormatInvalid);
    id<MTLRenderPipelineState> rd = pipeline(@"tex_vertex", @"read_target", nil, @[@(MTLPixelFormatRGBA32Float)], MTLPixelFormatInvalid);
    render(@[t], nil, ^(id<MTLRenderCommandEncoder> e) {
        [e setRenderPipelineState:fill];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e setRenderPipelineState:rd];
        [e setFragmentTexture:t atIndex:0];
        for (int i = 0; i < 3; i++) {   // each read sees the previous draw's result
            [e memoryBarrierWithScope:MTLBarrierScopeRenderTargets afterStages:MTLRenderStageFragment beforeStages:MTLRenderStageFragment];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
    });
    int good = 0;
    for (int y = 0; y < 64; y += 7) for (int x = 0; x < 64; x += 7) good += fabsf(pixelF(t, x, y).x - 1.0f) < 0.001f;
    CHECK(good == 100, "every sampled pixel = 0.25 + 3 x 0.25 (%d/100, pixel 10,10 = %.2f)", good, pixelF(t, 10, 10).x);
}

int main(void) {
    @autoreleasepool {
        dev = TSMtlCreateDevice();
        queue = [dev newCommandQueue];
        NSString *corpus = [NSString stringWithContentsOfFile:@TS_SOURCE_DIR "/tests/corpus/apps.metal" encoding:NSUTF8StringEncoding error:nil];
        NSError *err = nil;
        lib = [dev newLibraryWithSource:[corpus stringByAppendingString:kExtraMSL] options:nil error:&err];
        if (!lib) { printf("library: %s\n", err.description.UTF8String); return 1; }
        testAppleTriangle();
        testNagaEgui();
        testLayoutsAndControlFlow();
        testGBuffer();
        testConstexprSampler();
        testPacking();
        testMultisampleRead();
        testArrayOfArrays();
        testPixelCoords();
        testVisibleFunction();
        testPunnedPrivateMemory();
        testDynamicOffset();
        testReadOwnTarget();
        printf("\n%d/%d checks passed\n", checks - failures, checks);
    }
    return failures ? 1 : 0;
}
