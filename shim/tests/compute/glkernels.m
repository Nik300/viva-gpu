// TeraScale Compute, GL path: kernels from glkernels.metal run through the real device as GL passes.
// Checks results (formats, grids larger or smaller than the texture, partial writes, sRGB, IOSurface, device
// and constant buffers, samplers, threadgroup built-ins), that kernels needing OpenCL are refused and left as
// no-ops, and the cost of a dispatch against the same work done as a render pass.
// Build: make build/glkernels   Run: build/glkernels [--off]   (--off: compute disabled, every kernel inert)
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach_time.h>
#import "TSMetal.h"

static int gFails;
#define CHECK(cond, ...) do { if (cond) printf("  ok    "); else { printf("  FAIL  "); gFails++; } printf(__VA_ARGS__); printf("\n"); } while (0)

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static id<MTLDevice> gDev;
static id<MTLCommandQueue> gQueue;
static id<MTLLibrary> gLib;

static id<MTLComputePipelineState> pipeline(NSString *name) {
    NSError *e = nil;
    id<MTLComputePipelineState> p = [gDev newComputePipelineStateWithFunction:[gLib newFunctionWithName:name] error:&e];
    if (!p) { printf("  FAIL  pipeline %s: %s\n", name.UTF8String, e.description.UTF8String); gFails++; }
    return p;
}

static NSString *pathOf(id<MTLComputePipelineState> p) { return [(id)p valueForKey:@"computePath"]; }

static id<MTLTexture> texture(MTLPixelFormat f, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    return [gDev newTextureWithDescriptor:d];
}

static void fillTexture(id<MTLTexture> t, uint32_t rgba) {
    NSUInteger n = t.width * t.height;
    uint32_t *px = malloc(n * 4);
    for (NSUInteger i = 0; i < n; i++) px[i] = rgba;
    [t replaceRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0 withBytes:px bytesPerRow:t.width * 4];
    free(px);
}

static void readTexture(id<MTLTexture> t, void *out, NSUInteger bpp) {
    [t getBytes:out bytesPerRow:t.width * bpp fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0];
}

typedef void (^Encode)(id<MTLComputeCommandEncoder> enc);
static void run(Encode encode) {
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    encode(enc);
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

static BOOL near(uint8_t a, int b) { return abs((int)a - b) <= 1; }

int main(int argc, char **argv) { @autoreleasepool {
    BOOL off = argc > 1 && !strcmp(argv[1], "--off");
    setenv("TSMTL_COMPUTE", off ? "0" : "1", 1);
    gDev = TSMtlCreateDevice();
    gQueue = [gDev newCommandQueue];
    NSString *dir = @(TS_SOURCE_DIR "/tests/compute");
    NSError *e = nil;
    gLib = [gDev newLibraryWithSource:[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"glkernels.metal"]
                                                                encoding:NSUTF8StringEncoding error:nil] options:nil error:&e];
    if (!gLib) { printf("library: %s\n", e.description.UTF8String); return 1; }
    printf("compute %s\n", off ? "off (TSMTL_COMPUTE=0)" : "on (TSMTL_COMPUTE=1)");

    NSArray *glKernels = @[@"fill", @"invert", @"inc", @"blur3", @"stripes", @"rows", @"count_u"];
    NSArray *clKernels = @[@"cl_buffer_write", @"cl_atomic", @"cl_threadgroup", @"cl_scatter"];
    printf("-- pipelines\n");
    for (NSString *k in glKernels) { NSString *p = pathOf(pipeline(k)); CHECK([p isEqualToString:off ? @"off" : @"gl"], "%-16s %s", k.UTF8String, p.UTF8String); }
    for (NSString *k in clKernels) {
        NSString *p = pathOf(pipeline(k));
        CHECK([p isEqualToString:off ? @"off" : @"cl"], "%-16s %s", k.UTF8String, p.UTF8String);
    }

    printf("-- results\n");
    // fill: constant buffer (setBytes), bounds check against the written texture's size, grid larger than it.
    id<MTLTexture> t = texture(MTLPixelFormatRGBA8Unorm, 64, 64);
    fillTexture(t, 0);
    id<MTLComputePipelineState> fill = pipeline(@"fill");
    run(^(id<MTLComputeCommandEncoder> enc) {
        float color[4] = {0.25f, 0.5f, 0.75f, 1.0f};
        [enc setComputePipelineState:fill];
        [enc setTexture:t atIndex:0];
        [enc setBytes:color length:sizeof color atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(5, 5, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];   // 80x80 > 64x64
    });
    uint8_t px[64 * 64 * 4];
    readTexture(t, px, 4);
    BOOL ok = YES;
    for (int i = 0; i < 64 * 64; i++) ok &= near(px[i * 4], 64) && near(px[i * 4 + 1], 128) && near(px[i * 4 + 2], 191) && px[i * 4 + 3] == 255;
    if (off) CHECK(px[0] == 0, "fill: no-op with compute off (px0 %d)", px[0]);
    else CHECK(ok, "fill 80x80 grid on 64x64 RGBA8: px(0,0)=%d,%d,%d,%d px(63,63)=%d,%d,%d,%d", px[0], px[1], px[2], px[3],
               px[(63 * 64 + 63) * 4], px[(63 * 64 + 63) * 4 + 1], px[(63 * 64 + 63) * 4 + 2], px[(63 * 64 + 63) * 4 + 3]);
    if (off) { printf("\n%s\n", gFails ? "glkernels: FAILURES" : "glkernels (off): all ok"); return gFails ? 1 : 0; }

    // dispatchThreads with a grid smaller than the texture: only that rectangle is written.
    fillTexture(t, 0);
    run(^(id<MTLComputeCommandEncoder> enc) {
        float color[4] = {1, 1, 1, 1};
        [enc setComputePipelineState:fill];
        [enc setTexture:t atIndex:0];
        [enc setBytes:color length:sizeof color atIndex:0];
        [enc dispatchThreads:MTLSizeMake(50, 30, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    });
    readTexture(t, px, 4);
    ok = YES;
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) ok &= px[(y * 64 + x) * 4] == ((x < 50 && y < 30) ? 255 : 0);
    CHECK(ok, "dispatchThreads 50x30 on 64x64: rectangle only (px(49,29)=%d px(50,29)=%d px(49,30)=%d)", px[(29 * 64 + 49) * 4],
          px[(29 * 64 + 50) * 4], px[(30 * 64 + 49) * 4]);

    // stripes: threads that do not write keep the old texel.
    fillTexture(t, 0xFF0000FF);   // red (RGBA8 little endian: R in the low byte)
    id<MTLComputePipelineState> stripes = pipeline(@"stripes");
    run(^(id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:stripes];
        [enc setTexture:t atIndex:0];
        [enc dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    });
    readTexture(t, px, 4);
    ok = YES;
    for (int i = 0; i < 64 * 64; i++) ok &= (i % 2 == 0) ? (px[i * 4] == 0 && px[i * 4 + 1] == 255) : (px[i * 4] == 255 && px[i * 4 + 1] == 0);
    CHECK(ok, "stripes: even columns written, odd ones kept (px0=%d,%d px1=%d,%d)", px[0], px[1], px[4], px[5]);

    // invert: read() of another texture.
    id<MTLTexture> src = texture(MTLPixelFormatRGBA8Unorm, 64, 64);
    uint8_t pattern[64 * 64 * 4];
    for (int i = 0; i < 64 * 64 * 4; i++) pattern[i] = (uint8_t)(i * 7);
    for (int i = 0; i < 64 * 64; i++) pattern[i * 4 + 3] = 200;
    [src replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:pattern bytesPerRow:256];
    id<MTLComputePipelineState> invert = pipeline(@"invert");
    run(^(id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:invert];
        [enc setTexture:src atIndex:0];
        [enc setTexture:t atIndex:1];
        [enc dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    });
    readTexture(t, px, 4);
    ok = YES;
    for (int i = 0; i < 64 * 64 * 4; i++) ok &= (i % 4 == 3) ? px[i] == 200 : near(px[i], 255 - pattern[i]);
    CHECK(ok, "invert: read() of a second texture, row order kept (px(3,5).r=%d expected %d)", px[(5 * 64 + 3) * 4], 255 - pattern[(5 * 64 + 3) * 4]);

    // blur3: sample() with a sampler at level 0, one white texel spreads to its 3x3 neighbourhood.
    fillTexture(src, 0xFF000000);
    uint32_t white = 0xFFFFFFFF;
    [src replaceRegion:MTLRegionMake2D(10, 20, 1, 1) mipmapLevel:0 withBytes:&white bytesPerRow:4];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    id<MTLSamplerState> nearest = [gDev newSamplerStateWithDescriptor:sd];
    id<MTLComputePipelineState> blur = pipeline(@"blur3");
    run(^(id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:blur];
        [enc setTexture:src atIndex:0];
        [enc setTexture:t atIndex:1];
        [enc setSamplerState:nearest atIndex:0];
        [enc dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    });
    readTexture(t, px, 4);
    int inside = px[(21 * 64 + 11) * 4], corner = px[(19 * 64 + 9) * 4], outside = px[(22 * 64 + 10) * 4];
    CHECK(near(inside, 28) && near(corner, 28) && outside == 0, "blur3: 1/9 around (10,20): (11,21)=%d (9,19)=%d (10,22)=%d", inside, corner, outside);

    // rows: device buffer (texture buffer) at an offset, threadgroup built-ins.
    float colors[8][4] = {{0}};
    for (int i = 0; i < 4; i++) { colors[i + 1][0] = i / 3.0f; colors[i + 1][1] = 1 - i / 3.0f; colors[i + 1][3] = 1; }
    id<MTLBuffer> cbuf = [gDev newBufferWithBytes:colors length:sizeof colors options:MTLResourceStorageModeShared];
    id<MTLComputePipelineState> rows = pipeline(@"rows");
    run(^(id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:rows];
        [enc setTexture:t atIndex:0];
        [enc setBuffer:cbuf offset:16 atIndex:1];
        [enc dispatchThreadgroups:MTLSizeMake(8, 16, 1) threadsPerThreadgroup:MTLSizeMake(8, 4, 1)];
    });
    readTexture(t, px, 4);
    ok = YES;
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
        uint8_t *p = &px[(y * 64 + x) * 4];
        ok &= near(p[0], (int)round(255 * (y % 4) / 3.0)) && near(p[1], (int)round(255 * (1 - (y % 4) / 3.0))) && p[2] == 255;
    }
    CHECK(ok, "rows: device buffer at offset 16, tg*tpg+lid == gid everywhere (px(5,6)=%d,%d,%d)", px[(6 * 64 + 5) * 4],
          px[(6 * 64 + 5) * 4 + 1], px[(6 * 64 + 5) * 4 + 2]);

    // count_u: unsigned integer texture, threads_per_grid.
    id<MTLTexture> u = texture(MTLPixelFormatR32Uint, 32, 16);
    id<MTLComputePipelineState> count = pipeline(@"count_u");
    run(^(id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:count];
        [enc setTexture:u atIndex:0];
        [enc dispatchThreads:MTLSizeMake(32, 16, 1) threadsPerThreadgroup:MTLSizeMake(32, 4, 1)];
    });
    uint32_t uv[32 * 16];
    readTexture(u, uv, 4);
    ok = YES;
    for (int i = 0; i < 32 * 16; i++) ok &= uv[i] == (uint32_t)i;
    CHECK(ok, "count_u: R32Uint = x + y * threads_per_grid.x (uv[37]=%u)", uv[37]);

    // sRGB target: write() encodes.
    id<MTLTexture> srgb = texture(MTLPixelFormatRGBA8Unorm_sRGB, 16, 16);
    run(^(id<MTLComputeCommandEncoder> enc) {
        float color[4] = {0.5f, 0.5f, 0.5f, 1};
        [enc setComputePipelineState:fill];
        [enc setTexture:srgb atIndex:0];
        [enc setBytes:color length:sizeof color atIndex:0];
        [enc dispatchThreads:MTLSizeMake(16, 16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    });
    readTexture(srgb, px, 4);
    CHECK(near(px[0], 188) && px[3] == 255, "sRGB: 0.5 stored as %d (expected 188)", px[0]);

    // IOSurface texture (what layers and CoreImage hand around).
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @64,
        (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')});
    MTLTextureDescriptor *sdesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
    sdesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    id<MTLTexture> st = [gDev newTextureWithDescriptor:sdesc iosurface:surf plane:0];
    run(^(id<MTLComputeCommandEncoder> enc) {
        float color[4] = {1, 0, 0, 1};
        [enc setComputePipelineState:fill];
        [enc setTexture:st atIndex:0];
        [enc setBytes:color length:sizeof color atIndex:0];
        [enc dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    });
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    uint8_t *sp = IOSurfaceGetBaseAddress(surf);
    CHECK(sp[2] == 255 && sp[0] == 0 && sp[(63 * 64 + 63) * 4 + 2] == 255, "IOSurface BGRA target: surface px0 B,G,R,A=%d,%d,%d,%d", sp[0], sp[1], sp[2], sp[3]);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    // ... and read in place by the next kernel (rectangle variant)
    run(^(id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:invert];
        [enc setTexture:st atIndex:0];
        [enc setTexture:t atIndex:1];
        [enc dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    });
    readTexture(t, px, 4);
    CHECK(px[0] == 0 && px[1] == 255 && px[2] == 255, "IOSurface as kernel input: inverted red = %d,%d,%d", px[0], px[1], px[2]);

    // Kernels that need OpenCL run there (the corpus is tests/compute/ctest.m): a scattered write into an IOSurface.
    fillTexture(t, 0x11223344);
    id<MTLComputePipelineState> scatter = pipeline(@"cl_scatter");
    run(^(id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:scatter];
        [enc setTexture:t atIndex:0];
        [enc dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    });
    readTexture(t, px, 4);
    CHECK(px[0] == 255 && px[1] == 255 && px[2] == 255 && px[3] == 255, "cl_scatter on OpenCL: %d,%d,%d,%d", px[0], px[1], px[2], px[3]);

    // inc chain: many dispatches in one command buffer, ping-pong, in order.
    printf("-- chain and cost\n");
    id<MTLComputePipelineState> inc = pipeline(@"inc");
    for (NSNumber *size in @[@64, @256, @1024]) {
        NSUInteger S = size.unsignedIntegerValue;
        id<MTLTexture> a = texture(MTLPixelFormatRGBA32Float, S, S), b = texture(MTLPixelFormatRGBA32Float, S, S);
        // Reference: the same work as render passes (fragment shader reading the other texture).
        id<MTLLibrary> rl = [gDev newLibraryWithSource:
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "vertex float4 vs_full(uint vid [[vertex_id]]) { float2 p = float2((vid << 1) & 2, vid & 2); return float4(p * 2.0 - 1.0, 0, 1); }\n"
             "fragment float4 fs_inc(float4 pos [[position]], texture2d<float> src [[texture(0)]]) { return src.read(uint2(pos.xy)) + 1.0; }\n"
                                               options:nil error:nil];
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [rl newFunctionWithName:@"vs_full"];
        rd.fragmentFunction = [rl newFunctionWithName:@"fs_inc"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        id<MTLRenderPipelineState> rp = [gDev newRenderPipelineStateWithDescriptor:rd error:nil];
        for (int mode = 0; mode < 2; mode++) {
            for (int D = 1; D <= 8; D *= 8) {
                int frames = S >= 1024 ? 60 : 200;
                float zero[4] = {0};
                NSUInteger rowBytes = S * 16;
                void *zeros = calloc(S * S, 16);
                [a replaceRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0 withBytes:zeros bytesPerRow:rowBytes];
                [b replaceRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0 withBytes:zeros bytesPerRow:rowBytes];
                free(zeros);
                (void)zero;
                id<MTLCommandBuffer> last = nil;
                double t0 = now_ms();
                for (int f = 0; f < frames; f++) {
                    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
                    for (int k = 0; k < D; k++) {
                        id<MTLTexture> from = (k % 2) ? b : a, to = (k % 2) ? a : b;
                        if (D % 2 && f % 2) { id<MTLTexture> x = from; from = to; to = x; }
                        if (mode == 0) {
                            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                            [enc setComputePipelineState:inc];
                            [enc setTexture:from atIndex:0];
                            [enc setTexture:to atIndex:1];
                            [enc dispatchThreads:MTLSizeMake(S, S, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                            [enc endEncoding];
                        } else {
                            MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
                            pd.colorAttachments[0].texture = to;
                            pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                            pd.colorAttachments[0].storeAction = MTLStoreActionStore;
                            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pd];
                            [enc setRenderPipelineState:rp];
                            [enc setFragmentTexture:from atIndex:0];
                            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                            [enc endEncoding];
                        }
                    }
                    [cb commit];
                    last = cb;
                }
                [last waitUntilCompleted];
                double ms = (now_ms() - t0) / frames;
                // Each step adds 1 along a single chain: the newest texture holds frames * D.
                int total = frames * D;
                id<MTLTexture> newest = (D % 2 == 0) ? a : ((frames % 2) ? b : a);
                float v[4];
                [newest getBytes:v bytesPerRow:rowBytes fromRegion:MTLRegionMake2D(S - 1, S - 1, 1, 1) mipmapLevel:0];
                if (mode == 0) CHECK(v[0] == total, "%4lu² D=%d: %d dispatches in order (value %g), %.3f ms/frame (%.3f per dispatch)",
                                     (unsigned long)S, D, total, v[0], ms, ms / D);
                else printf("        %4lu² D=%d: same work as render passes: %.3f ms/frame (%.3f per pass), value %g\n",
                            (unsigned long)S, D, ms, ms / D, v[0]);
            }
        }
    }
    printf("\n%s\n", gFails ? "glkernels: FAILURES" : "glkernels: all ok");
    return gFails ? 1 : 0;
}}
