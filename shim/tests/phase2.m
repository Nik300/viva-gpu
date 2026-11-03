// Phase 2 acceptance test: real rendering through OpenGL, verified pixel by pixel.
// Built twice: phase2 uses the hand-written GLSL below, phase3 (-DTS_TRANSLATED) registers
// nothing, so every shader goes through the AIR -> GLSL translator.
// Shaders are real MSL (compiled to AIR by the system); each function also has a
// hand-written GLSL translation following the shim ABI. These pairs are the
// reference cases for the Phase 3 AIR -> GLSL translator.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import "TSMetal.h"

static int failures, checks;
#define CHECK(cond, ...) do { checks++; if (cond) printf("  ok   "); else { failures++; printf("  FAIL "); } \
    printf(__VA_ARGS__); printf("\n"); } while (0)

static NSString *const kMSL = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VIn  { float2 pos [[attribute(0)]]; float4 color [[attribute(1)]]; };\n"
    "struct TIn  { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };\n"
    "struct IIn  { float2 pos [[attribute(0)]]; float2 offset [[attribute(2)]]; };\n"
    "struct VOut { float4 pos [[position]]; float4 color; float2 uv; };\n"
    "struct U    { float4 tint; float depth; };\n"
    "vertex VOut vs_color(VIn in [[stage_in]]) { VOut o; o.pos = float4(in.pos, 0.5, 1); o.color = in.color; o.uv = 0; return o; }\n"
    "fragment float4 fs_color(VOut in [[stage_in]]) { return in.color; }\n"
    "vertex VOut vs_depth(VIn in [[stage_in]], constant U &u [[buffer(1)]]) { VOut o; o.pos = float4(in.pos, u.depth, 1); o.color = 0; o.uv = 0; return o; }\n"
    "fragment float4 fs_tint(VOut in [[stage_in]], constant U &u [[buffer(0)]]) { return u.tint; }\n"
    "vertex VOut vs_tex(TIn in [[stage_in]]) { VOut o; o.pos = float4(in.pos, 0.5, 1); o.color = 0; o.uv = in.uv; return o; }\n"
    "fragment float4 fs_tex(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, in.uv); }\n"
    "vertex VOut vs_inst(IIn in [[stage_in]]) { VOut o; o.pos = float4(in.pos + in.offset, 0.5, 1); o.color = float4(0, 0, 1, 1); o.uv = 0; return o; }\n"
    "vertex VOut vs_untranslated(VIn in [[stage_in]]) { VOut o; o.pos = float4(in.pos, 0.5, 1); o.color = in.color; o.uv = 0; return o; }\n";

static void registerGLSL(void) {
#ifdef TS_TRANSLATED
    return;
#endif
    NSString *varyingsOut = @"out vec4 v_color; out vec2 v_uv;\n";
    NSString *varyingsIn = @"in vec4 v_color; in vec2 v_uv;\nlayout(location = 0) out vec4 o0;\n";
    TSMtlRegisterGLSL(@"vs_color", [varyingsOut stringByAppendingString:
        @"layout(location = 0) in vec2 a_pos; layout(location = 1) in vec4 a_color;\n"
        "void main() { gl_Position = vec4(a_pos, 0.5, 1.0); v_color = a_color; v_uv = vec2(0); }\n"]);
    TSMtlRegisterGLSL(@"fs_color", [varyingsIn stringByAppendingString:@"void main() { o0 = v_color; }\n"]);
    TSMtlRegisterGLSL(@"vs_depth", [varyingsOut stringByAppendingString:
        @"layout(location = 0) in vec2 a_pos;\nuniform vbuf1 { vec4 tint; float depth; };\n"
        "void main() { gl_Position = vec4(a_pos, depth, 1.0); v_color = vec4(0); v_uv = vec2(0); }\n"]);
    TSMtlRegisterGLSL(@"fs_tint", [varyingsIn stringByAppendingString:
        @"uniform fbuf0 { vec4 tint; float depth; };\nvoid main() { o0 = tint; }\n"]);
    TSMtlRegisterGLSL(@"vs_tex", [varyingsOut stringByAppendingString:
        @"layout(location = 0) in vec2 a_pos; layout(location = 1) in vec2 a_uv;\n"
        "void main() { gl_Position = vec4(a_pos, 0.5, 1.0); v_color = vec4(0); v_uv = a_uv; }\n"]);
    TSMtlRegisterGLSL(@"fs_tex", [varyingsIn stringByAppendingString:
        @"uniform sampler2D ftex0_s0;\nvoid main() { o0 = texture(ftex0_s0, v_uv); }\n"]);
    TSMtlRegisterGLSL(@"vs_inst", [varyingsOut stringByAppendingString:
        @"layout(location = 0) in vec2 a_pos; layout(location = 2) in vec2 a_offset;\n"
        "void main() { gl_Position = vec4(a_pos + a_offset, 0.5, 1.0); v_color = vec4(0, 0, 1, 1); v_uv = vec2(0); }\n"]);
}

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> lib;

static id<MTLTexture> makeTarget(MTLPixelFormat fmt, NSUInteger size) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:size height:size mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [dev newTextureWithDescriptor:d];
}

static uint32_t pixel(id<MTLTexture> t, NSUInteger x, NSUInteger y) {
    uint32_t p = 0;
    [t getBytes:&p bytesPerRow:4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
    return p;
}

static BOOL near(uint32_t p, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    int c[4] = { p & 0xff, (p >> 8) & 0xff, (p >> 16) & 0xff, p >> 24 }, e[4] = { r, g, b, a };
    for (int i = 0; i < 4; i++) if (abs(c[i] - e[i]) > 2) return NO;
    return YES;
}

static id<MTLRenderPipelineState> pipeline(NSString *vs, NSString *fs, MTLVertexDescriptor *vd, void (^tweak)(MTLRenderPipelineDescriptor *)) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:vs];
    d.fragmentFunction = [lib newFunctionWithName:fs];
    d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    if (tweak) tweak(d);
    NSError *err = nil;
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) printf("  pipeline %s/%s: %s\n", vs.UTF8String, fs.UTF8String, err.description.UTF8String);
    return p;
}

// float2 position + float4 color, interleaved.
static MTLVertexDescriptor *colorLayout(void) {
    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[1].format = MTLVertexFormatFloat4;
    vd.attributes[1].offset = 8;
    vd.layouts[0].stride = 24;
    return vd;
}

// float2 position + float2 uv, interleaved.
static MTLVertexDescriptor *uvLayout(void) {
    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[1].format = MTLVertexFormatFloat2;
    vd.attributes[1].offset = 8;
    vd.layouts[0].stride = 16;
    return vd;
}

static MTLRenderPassDescriptor *passFor(id<MTLTexture> t, MTLClearColor clear) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = clear;
    return rp;
}

static void run(void (^encode)(id<MTLCommandBuffer> cb)) {
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    encode(cb);
    [cb commit];
    [cb waitUntilCompleted];
}

// Upper-left half of the target: (-1,1) (1,1) (-1,-1), counter-clockwise in y-up NDC... see the winding test.
static const float kTopLeftTri[] = { -1, 1, 1, 0, 0, 1,   -1, -1, 1, 0, 0, 1,   1, 1, 1, 0, 0, 1 };

static void testClearAndTriangle(void) {
    printf("clear + triangle\n");
    id<MTLTexture> t = makeTarget(MTLPixelFormatRGBA8Unorm, 64);
    run(^(id<MTLCommandBuffer> cb) { [[cb renderCommandEncoderWithDescriptor:passFor(t, MTLClearColorMake(0.25, 0.5, 0.75, 1))] endEncoding]; });
    CHECK(near(pixel(t, 10, 10), 64, 128, 191, 255), "clear color (0x%08x)", pixel(t, 10, 10));

    id<MTLRenderPipelineState> p = pipeline(@"vs_color", @"fs_color", colorLayout(), nil);
    CHECK(p != nil, "pipeline from registered GLSL");
    run(^(id<MTLCommandBuffer> cb) {
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:passFor(t, MTLClearColorMake(0, 0, 0, 1))];
        [e setRenderPipelineState:p];
        [e setVertexBytes:kTopLeftTri length:sizeof kTopLeftTri atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    });
    CHECK(near(pixel(t, 4, 4), 255, 0, 0, 255), "top-left is inside (y not flipped)");
    CHECK(near(pixel(t, 55, 4), 255, 0, 0, 255), "top-right is inside (x not flipped)");
    CHECK(near(pixel(t, 4, 55), 255, 0, 0, 255), "bottom-left is inside");
    CHECK(near(pixel(t, 59, 59), 0, 0, 0, 255), "bottom-right is outside");

    // Same triangle from a real MTLBuffer, with culling: the vertex order above is
    // counter-clockwise in y-up NDC, so it is front-facing only with CCW winding.
    id<MTLBuffer> vb = [dev newBufferWithBytes:kTopLeftTri length:sizeof kTopLeftTri options:MTLResourceStorageModeShared];
    for (int ccw = 0; ccw < 2; ccw++) {
        run(^(id<MTLCommandBuffer> cb) {
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:passFor(t, MTLClearColorMake(0, 0, 0, 1))];
            [e setRenderPipelineState:p];
            [e setCullMode:MTLCullModeBack];
            [e setFrontFacingWinding:ccw ? MTLWindingCounterClockwise : MTLWindingClockwise];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
        });
        uint32_t px = pixel(t, 4, 4);
        if (ccw) CHECK(near(px, 255, 0, 0, 255), "CCW triangle drawn with winding CCW + cull back");
        else CHECK(near(px, 0, 0, 0, 255), "CCW triangle culled with winding CW + cull back");
    }
}

static void testDepthAndUniforms(void) {
    printf("depth + uniform blocks\n");
    id<MTLTexture> t = makeTarget(MTLPixelFormatRGBA8Unorm, 32);
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:32 height:32 mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget;
    dd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [dev newTextureWithDescriptor:dd];
    id<MTLRenderPipelineState> p = pipeline(@"vs_depth", @"fs_tint", colorLayout(), ^(MTLRenderPipelineDescriptor *d) {
        d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    });
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
    dsd.depthCompareFunction = MTLCompareFunctionLess;
    dsd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dsd];
    static const float quad[] = { -1, -1, 0, 0, 0, 0,  1, -1, 0, 0, 0, 0,  -1, 1, 0, 0, 0, 0,  1, 1, 0, 0, 0, 0 };
    typedef struct { float tint[4]; float depth; float pad[3]; } U;
    static U layers[3] = { {{1, 0, 0, 1}, 0.3f}, {{0, 1, 0, 1}, 0.6f}, {{0, 0, 1, 1}, 0.1f} };
    __block BOOL afterTwo = NO;
    for (int n = 2; n <= 3; n++) {
        run(^(id<MTLCommandBuffer> cb) {
            MTLRenderPassDescriptor *rp = passFor(t, MTLClearColorMake(0, 0, 0, 1));
            rp.depthAttachment.texture = depth;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.clearDepth = 1.0;
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:p];
            [e setDepthStencilState:ds];
            [e setVertexBytes:quad length:sizeof quad atIndex:0];
            for (int i = 0; i < n; i++) {
                [e setVertexBytes:&layers[i] length:sizeof(U) atIndex:1];
                [e setFragmentBytes:&layers[i] length:sizeof(U) atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            }
            [e endEncoding];
        });
        if (n == 2) afterTwo = near(pixel(t, 16, 16), 255, 0, 0, 255);
    }
    CHECK(afterTwo, "farther green quad rejected by depth test (red stays)");
    CHECK(near(pixel(t, 16, 16), 0, 0, 255, 255), "nearer blue quad passes (0x%08x)", pixel(t, 16, 16));
}

static id<MTLRenderPipelineState> texPipeline(void) { return pipeline(@"vs_tex", @"fs_tex", uvLayout(), nil); }

static void drawTextured(id<MTLTexture> target, id<MTLTexture> source, id<MTLSamplerState> s, id<MTLCommandBuffer> cb) {
    static const float quad[] = { -1, 1, 0, 0,  1, 1, 1, 0,  -1, -1, 0, 1,  1, -1, 1, 1 };   // uv (0,0) = top-left
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:passFor(target, MTLClearColorMake(0, 0, 0, 0))];
    [e setRenderPipelineState:texPipeline()];
    [e setVertexBytes:quad length:sizeof quad atIndex:0];
    [e setFragmentTexture:source atIndex:0];
    [e setFragmentSamplerState:s atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
}

static void testTexturing(void) {
    printf("texturing\n");
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:2 mipmapped:NO];
    id<MTLTexture> src = [dev newTextureWithDescriptor:d];
    uint32_t texels[4] = { 0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff };   // red green / blue white, row 0 on top
    [src replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:texels bytesPerRow:8];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    id<MTLSamplerState> nearest = [dev newSamplerStateWithDescriptor:sd];
    id<MTLTexture> t = makeTarget(MTLPixelFormatRGBA8Unorm, 64);
    run(^(id<MTLCommandBuffer> cb) { drawTextured(t, src, nearest, cb); });
    CHECK(near(pixel(t, 8, 8), 255, 0, 0, 255) && near(pixel(t, 56, 8), 0, 255, 0, 255) &&
          near(pixel(t, 8, 56), 0, 0, 255, 255) && near(pixel(t, 56, 56), 255, 255, 255, 255),
          "2x2 texture lands upright (TL %08x TR %08x BL %08x BR %08x)", pixel(t, 8, 8), pixel(t, 56, 8), pixel(t, 8, 56), pixel(t, 56, 56));

    uint32_t update = 0xff00ffff;   // CPU write after first use must reach the GL mirror
    [src replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&update bytesPerRow:4];
    run(^(id<MTLCommandBuffer> cb) { drawTextured(t, src, nearest, cb); });
    CHECK(near(pixel(t, 8, 8), 255, 255, 0, 255), "CPU update re-uploaded (0x%08x)", pixel(t, 8, 8));

    // Render to texture, then sample it in a second pass without any CPU round trip.
    id<MTLTexture> rt = makeTarget(MTLPixelFormatRGBA8Unorm, 16);
    run(^(id<MTLCommandBuffer> cb) {
        [[cb renderCommandEncoderWithDescriptor:passFor(rt, MTLClearColorMake(0, 1, 0, 1))] endEncoding];
        drawTextured(t, rt, nearest, cb);
    });
    CHECK(near(pixel(t, 30, 30), 0, 255, 0, 255), "render-to-texture then sample (0x%08x)", pixel(t, 30, 30));

    // Mipmap generation on the GPU.
    MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:YES];
    id<MTLTexture> mip = [dev newTextureWithDescriptor:md];
    uint32_t checker[16];
    for (int i = 0; i < 16; i++) checker[i] = ((i + i / 4) & 1) ? 0xffffffff : 0xff000000;
    [mip replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:checker bytesPerRow:16];
    run(^(id<MTLCommandBuffer> cb) {
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b generateMipmapsForTexture:mip];
        [b endEncoding];
    });
    uint32_t top = 0;
    [mip getBytes:&top bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:2];
    int gray = top & 0xff;
    CHECK(gray > 100 && gray < 160, "generateMipmaps: 1x1 level averages the checker (%d)", gray);
}

static void testBlendInstancingMSAA(void) {
    printf("blending, instancing, MSAA\n");
    id<MTLTexture> t = makeTarget(MTLPixelFormatRGBA8Unorm, 32);
    id<MTLRenderPipelineState> blend = pipeline(@"vs_color", @"fs_color", colorLayout(), ^(MTLRenderPipelineDescriptor *d) {
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    });
    static const float half[] = { -1, -1, 1, 0, 0, .5f,  1, -1, 1, 0, 0, .5f,  -1, 1, 1, 0, 0, .5f,  1, 1, 1, 0, 0, .5f };
    run(^(id<MTLCommandBuffer> cb) {
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:passFor(t, MTLClearColorMake(1, 1, 1, 1))];
        [e setRenderPipelineState:blend];
        [e setVertexBytes:half length:sizeof half atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [e endEncoding];
    });
    CHECK(near(pixel(t, 16, 16), 255, 128, 128, 128),
          "alpha blending 50%% red over white, alpha factors One/Zero (0x%08x)", pixel(t, 16, 16));

    // Indexed, instanced quads with a per-instance offset in buffer 1; baseInstance picks the second offset.
    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[2].format = MTLVertexFormatFloat2;
    vd.attributes[2].bufferIndex = 1;
    vd.layouts[0].stride = 8;
    vd.layouts[1].stride = 8;
    vd.layouts[1].stepFunction = MTLVertexStepFunctionPerInstance;
    id<MTLRenderPipelineState> inst = pipeline(@"vs_inst", @"fs_color", vd, nil);
    static const float corner[] = { -1, 1,  -0.5f, 1,  -1, 0.5f,  -0.5f, 0.5f };      // small quad at the top-left
    static const float offsets[] = { 0, 0,  1.5f, 0,  0, -1.5f };                   // TL, TR, BL
    static const uint16_t indices[] = { 0, 1, 2, 2, 1, 3 };
    id<MTLBuffer> ib = [dev newBufferWithBytes:indices length:sizeof indices options:0];
    id<MTLBuffer> ob = [dev newBufferWithBytes:offsets length:sizeof offsets options:0];
    run(^(id<MTLCommandBuffer> cb) {
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:passFor(t, MTLClearColorMake(0, 0, 0, 1))];
        [e setRenderPipelineState:inst];
        [e setVertexBytes:corner length:sizeof corner atIndex:0];
        [e setVertexBuffer:ob offset:0 atIndex:1];
        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib
               indexBufferOffset:0 instanceCount:1 baseVertex:0 baseInstance:1];          // only TR
        [e endEncoding];
    });
    CHECK(near(pixel(t, 28, 3), 0, 0, 255, 255) && near(pixel(t, 3, 3), 0, 0, 0, 255), "baseInstance selects the second offset");
    run(^(id<MTLCommandBuffer> cb) {
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:passFor(t, MTLClearColorMake(0, 0, 0, 1))];
        [e setRenderPipelineState:inst];
        [e setVertexBytes:corner length:sizeof corner atIndex:0];
        [e setVertexBuffer:ob offset:0 atIndex:1];
        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib
               indexBufferOffset:0 instanceCount:3];
        [e endEncoding];
    });
    CHECK(near(pixel(t, 3, 3), 0, 0, 255, 255) && near(pixel(t, 28, 3), 0, 0, 255, 255) &&
          near(pixel(t, 3, 28), 0, 0, 255, 255) && near(pixel(t, 28, 28), 0, 0, 0, 255), "3 instances placed by the offset buffer");

    // 4x MSAA rendered and resolved into a single-sample texture.
    MTLTextureDescriptor *msd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    msd.textureType = MTLTextureType2DMultisample;
    msd.sampleCount = 4;
    msd.usage = MTLTextureUsageRenderTarget;
    msd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> ms = [dev newTextureWithDescriptor:msd];
    id<MTLTexture> resolved = makeTarget(MTLPixelFormatRGBA8Unorm, 64);
    id<MTLRenderPipelineState> msp = pipeline(@"vs_color", @"fs_color", colorLayout(), ^(MTLRenderPipelineDescriptor *d) { d.rasterSampleCount = 4; });
    run(^(id<MTLCommandBuffer> cb) {
        MTLRenderPassDescriptor *rp = passFor(ms, MTLClearColorMake(0, 0, 0, 1));
        rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        rp.colorAttachments[0].resolveTexture = resolved;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:msp];
        [e setVertexBytes:kTopLeftTri length:sizeof kTopLeftTri atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    });
    int edge = -1;
    for (int x = 0; x < 64 && edge < 0; x++) {   // the diagonal must contain partially covered pixels
        uint32_t px = pixel(resolved, x, 63 - x);
        int r = px & 0xff;
        if (r > 20 && r < 235) edge = r;
    }
    CHECK(near(pixel(resolved, 4, 4), 255, 0, 0, 255) && near(pixel(resolved, 60, 60), 0, 0, 0, 255), "MSAA resolve");
    CHECK(edge > 0, "anti-aliased diagonal has intermediate values (%d)", edge);
}

static void testViewsSurfacesFallback(void) {
    printf("views, IOSurface, blit after render, fallback\n");
    // sRGB view as render target: linear 0.5 is stored as ~188 in the shared storage.
    id<MTLTexture> base = makeTarget(MTLPixelFormatRGBA8Unorm, 16);
    id<MTLTexture> srgb = [base newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    run(^(id<MTLCommandBuffer> cb) { [[cb renderCommandEncoderWithDescriptor:passFor(srgb, MTLClearColorMake(0.5, 0.5, 0.5, 1))] endEncoding]; });
    int v = pixel(base, 5, 5) & 0xff;
    CHECK(v >= 186 && v <= 190, "sRGB view encodes into the parent storage (%d)", v);

    // Render into an IOSurface (what CAMetalLayer drawables are) and read the surface memory directly.
    NSDictionary *props = @{ (id)kIOSurfaceWidth: @32, (id)kIOSurfaceHeight: @32, (id)kIOSurfaceBytesPerElement: @4,
                             (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
    sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> st = [dev newTextureWithDescriptor:sd iosurface:surf plane:0];
    id<MTLRenderPipelineState> p = pipeline(@"vs_color", @"fs_color", colorLayout(), ^(MTLRenderPipelineDescriptor *d) {
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    });
    run(^(id<MTLCommandBuffer> cb) {
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:passFor(st, MTLClearColorMake(0, 0, 1, 1))];
        [e setRenderPipelineState:p];
        [e setVertexBytes:kTopLeftTri length:sizeof kTopLeftTri atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    });
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    uint8_t *mem = IOSurfaceGetBaseAddress(surf);
    size_t bpr = IOSurfaceGetBytesPerRow(surf);
    uint32_t tl = *(uint32_t *)(mem + 2 * bpr + 2 * 4), br = *(uint32_t *)(mem + 29 * bpr + 29 * 4);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    CHECK(tl == 0xffff0000 && br == 0xff0000ff, "IOSurface memory: red triangle top-left, blue clear bottom-right (BGRA %08x %08x)", tl, br);

    // The IOSurface texture can also be sampled (rectangle -> 2D copy).
    id<MTLTexture> t = makeTarget(MTLPixelFormatRGBA8Unorm, 32);
    run(^(id<MTLCommandBuffer> cb) { drawTextured(t, st, [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]], cb); });
    CHECK(near(pixel(t, 2, 2), 255, 0, 0, 255) && near(pixel(t, 29, 29), 0, 0, 255, 255), "IOSurface texture sampled upright");
    CFRelease(surf);

    // Two Metal textures over one IOSurface (Chrome: raster writes one, the compositor samples the other),
    // written and sampled twice in one command buffer: sampled in place, each sample sees the latest write.
    IOSurfaceRef shared = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    id<MTLTexture> writer = [dev newTextureWithDescriptor:sd iosurface:shared plane:0];
    id<MTLTexture> reader = [dev newTextureWithDescriptor:sd iosurface:shared plane:0];
    id<MTLTexture> first = makeTarget(MTLPixelFormatRGBA8Unorm, 32), second = makeTarget(MTLPixelFormatRGBA8Unorm, 32);
    MTLSamplerDescriptor *rep = [MTLSamplerDescriptor new];
    rep.sAddressMode = rep.tAddressMode = MTLSamplerAddressModeRepeat;   // rectangle textures clamp instead
    rep.mipFilter = MTLSamplerMipFilterLinear;                         // and ignore the mip filter
    id<MTLSamplerState> repeatSampler = [dev newSamplerStateWithDescriptor:rep];
    run(^(id<MTLCommandBuffer> cb) {
        [[cb renderCommandEncoderWithDescriptor:passFor(writer, MTLClearColorMake(1, 0, 0, 1))] endEncoding];
        drawTextured(first, reader, repeatSampler, cb);
        [[cb renderCommandEncoderWithDescriptor:passFor(writer, MTLClearColorMake(0, 1, 0, 1))] endEncoding];
        drawTextured(second, reader, repeatSampler, cb);
    });
    CHECK(near(pixel(first, 16, 16), 255, 0, 0, 255) && near(pixel(second, 16, 16), 0, 255, 0, 255),
          "one IOSurface, two textures: each sample sees the write before it (0x%08x 0x%08x)", pixel(first, 16, 16), pixel(second, 16, 16));
    // The same pipeline right after with a plain texture goes back to the sampler2D program.
    run(^(id<MTLCommandBuffer> cb) { drawTextured(first, second, repeatSampler, cb); });
    CHECK(near(pixel(first, 16, 16), 0, 255, 0, 255), "same pipeline, plain texture after an IOSurface");
    CFRelease(shared);

    // Blit that reads a texture rendered earlier in the same command buffer.
    id<MTLBuffer> out = [dev newBufferWithLength:16 * 16 * 4 options:0];
    id<MTLTexture> rt = makeTarget(MTLPixelFormatRGBA8Unorm, 16);
    run(^(id<MTLCommandBuffer> cb) {
        [[cb renderCommandEncoderWithDescriptor:passFor(rt, MTLClearColorMake(1, 0, 1, 1))] endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(16, 16, 1)
                  toBuffer:out destinationOffset:0 destinationBytesPerRow:64 destinationBytesPerImage:1024];
        [b endEncoding];
    });
    CHECK(near(((uint32_t *)out.contents)[100], 255, 0, 255, 255), "blit reads back a rendered texture (0x%08x)", ((uint32_t *)out.contents)[100]);

    // Texture-to-texture copies stay on the GPU (VectorKit copies its whole frame every frame): a rendered
    // source into part of a destination whose other texels came from the CPU, then the source rendered again.
    id<MTLTexture> dstT = makeTarget(MTLPixelFormatRGBA8Unorm, 16);
    uint32_t blue[16 * 16];
    for (int i = 0; i < 256; i++) blue[i] = 0xffff0000;
    [dstT replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:blue bytesPerRow:64];
    run(^(id<MTLCommandBuffer> cb) {
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 4, 1)
                 toTexture:dstT destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(8, 12, 0)];
        [b endEncoding];
        [[cb renderCommandEncoderWithDescriptor:passFor(rt, MTLClearColorMake(0, 1, 0, 1))] endEncoding];
    });
    CHECK(near(pixel(dstT, 12, 14), 255, 0, 255, 255) && near(pixel(dstT, 2, 2), 0, 0, 255, 255) && near(pixel(dstT, 12, 10), 0, 0, 255, 255),
          "texture copy: copied region from the render, the rest from the CPU (0x%08x 0x%08x)", pixel(dstT, 12, 14), pixel(dstT, 2, 2));

    // phase2: a function with no GLSL still yields a pipeline (fallback shader draws magenta).
    // phase3: the same function is translated from AIR and draws its real color (red).
    id<MTLRenderPipelineState> fb = pipeline(@"vs_untranslated", @"fs_color", colorLayout(), nil);
    CHECK(fb != nil, "function without hand-written GLSL -> pipeline is not nil");
    id<MTLTexture> ft = makeTarget(MTLPixelFormatRGBA8Unorm, 16);
    run(^(id<MTLCommandBuffer> cb) {
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:passFor(ft, MTLClearColorMake(0, 0, 0, 1))];
        [e setRenderPipelineState:fb];
        [e setVertexBytes:kTopLeftTri length:sizeof kTopLeftTri atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    });
#ifdef TS_TRANSLATED
    CHECK(near(pixel(ft, 2, 2), 255, 0, 0, 255), "translated shader draws red (0x%08x)", pixel(ft, 2, 2));
#else
    CHECK(near(pixel(ft, 2, 2), 255, 0, 255, 255), "fallback draws magenta (0x%08x)", pixel(ft, 2, 2));
#endif
}

static void testThroughput(void) {
    printf("throughput\n");
    id<MTLTexture> t = makeTarget(MTLPixelFormatRGBA8Unorm, 256);
    id<MTLRenderPipelineState> p = pipeline(@"vs_color", @"fs_color", colorLayout(), nil);
    id<MTLBuffer> vb = [dev newBufferWithBytes:kTopLeftTri length:sizeof kTopLeftTri options:0];
    NSDate *start = [NSDate date];
    id<MTLCommandBuffer> last = nil;
    for (int frame = 0; frame < 200; frame++) {
        last = [queue commandBuffer];
        id<MTLRenderCommandEncoder> e = [last renderCommandEncoderWithDescriptor:passFor(t, MTLClearColorMake(0, 0, 0, 1))];
        [e setRenderPipelineState:p];
        [e setVertexBuffer:vb offset:0 atIndex:0];
        for (int d = 0; d < 50; d++) [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        [last commit];
    }
    [last waitUntilCompleted];
    double secs = -start.timeIntervalSinceNow;
    CHECK(last.status == MTLCommandBufferStatusCompleted, "200 frames x 50 draws: %.0f frames/s, %.0f draws/s", 200 / secs, 10000 / secs);
}

// Occlusion (visibility result) queries: VectorKit hides 3D labels whose test draw reports no samples.
static void testVisibility(void) {
    printf("visibility results\n");
    id<MTLTexture> t = makeTarget(MTLPixelFormatRGBA8Unorm, 32);
    id<MTLRenderPipelineState> p = pipeline(@"vs_color", @"fs_color", colorLayout(), nil);
    id<MTLBuffer> vis = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    memset(vis.contents, 0xAB, 64);
    run(^(id<MTLCommandBuffer> cb) {
        MTLRenderPassDescriptor *rp = passFor(t, MTLClearColorMake(0, 0, 0, 1));
        rp.visibilityResultBuffer = vis;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:p];
        [e setVertexBytes:kTopLeftTri length:sizeof kTopLeftTri atIndex:0];
        [e setVisibilityResultMode:MTLVisibilityResultModeBoolean offset:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:8];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];   // same offset: counts add up
        [e setScissorRect:(MTLScissorRect){ 31, 31, 1, 1 }];                         // the triangle misses this pixel
        [e setVisibilityResultMode:MTLVisibilityResultModeBoolean offset:16];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    });
    const uint64_t *v = vis.contents;
    CHECK(v[0] != 0, "boolean: visible draw is nonzero (%llu)", v[0]);
    CHECK(v[1] >= 2 * 496 && v[1] <= 2 * 528, "counting: two half-target triangles ~1024 samples (%llu)", v[1]);
    CHECK(v[2] == 0, "boolean: scissored-out draw is zero (%llu)", v[2]);
    CHECK(v[3] == 0xABABABABABABABABull, "offsets never selected are untouched");
}

int main(void) {
    @autoreleasepool {
        registerGLSL();
        dev = TSMtlCreateDevice();
        queue = [dev newCommandQueue];
        NSError *err = nil;
        lib = [dev newLibraryWithSource:kMSL options:nil error:&err];
        printf("library: %s\n", lib ? "compiled (MSL -> AIR)" : err.description.UTF8String);
        if (!lib) return 1;
        testClearAndTriangle();
        testDepthAndUniforms();
        testTexturing();
        testBlendInstancingMSAA();
        testViewsSurfacesFallback();
        testVisibility();
        testThroughput();
        printf("\n%d/%d checks passed\n", checks - failures, checks);
    }
    return failures ? 1 : 0;
}
