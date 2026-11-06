// What a render pass costs on the phone's GPU: full-screen passes (the size of CoreAnimation's framebuffer) on a
// linear IOSurface (what backboardd renders into) and on a private texture (Panfrost: AFBC), with each load/store
// combination, and full-screen blended draws within one pass. Times are commit -> completed, median of the runs.
// P9 (docs/ANALISI-PRESTAZIONI-2026-11-06.md): GPU memory bandwidth, a compute copy of a framebuffer-sized buffer
// (read + write) and a texture-to-texture blit; below ~10 GB/s the DRAM clock (DVFSRC) is worth configuring.
// Usage: passbench [runs] [bw]          (bw: only the bandwidth part)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

id<MTLDevice> TSMtlCreateDevice(void);

enum { W = 1125, H = 2436 };

static NSString *const kMSL = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { V v; float2 t = float2((i << 1) & 2, i & 2); v.p = float4(t * 2 - 1, 0, 1); return v; }\n"
    "fragment half4 fs(constant float4 &c [[buffer(0)]]) { return half4(c); }\n"
    "fragment half4 fs_lit() { return half4(0.5, 0.2, 0.3, 0.25); }\n"
    "fragment half4 fs_tex(V v [[stage_in]], texture2d<half> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return t.sample(s, v.p.xy / float2(1125, 2436)) * half(0.25); }\n"
    "kernel void copy4(device const uint4 *a [[buffer(0)]], device uint4 *b [[buffer(1)]], uint i [[thread_position_in_grid]]) { b[i] = a[i]; }\n"
    "kernel void fill4(device uint4 *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] = uint4(i); }\n";

static id<MTLTexture> g_src;   // sampled by fs_tex
static id<MTLSamplerState> g_smp;

static double ms(uint64_t abs) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)abs * tb.numer / tb.denom / 1e6;
}

static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

static id<MTLTexture> surfaceTexture(id<MTLDevice> dev) {
    size_t bpr = (W * 4 + 63) & ~(size_t)63;
    NSDictionary *p = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
                         (id)kIOSurfaceBytesPerRow: @(bpr), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)p);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d iosurface:s plane:0];
    CFRelease(s);
    return t;
}

static id<MTLTexture> privateTexture(id<MTLDevice> dev) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:d];
}

// passes passes of draws full-screen blended draws each; returns the median ms per command buffer.
static double run(id<MTLCommandQueue> q, id<MTLRenderPipelineState> ps, id<MTLTexture> t, int passes, int draws,
                  MTLLoadAction load, MTLStoreAction store, int runs) {
    double *v = calloc(runs, sizeof *v);
    for (int r = -2; r < runs; r++) {   // two warm-up runs
        id<MTLCommandBuffer> cb = [q commandBuffer];
        for (int p = 0; p < passes; p++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = t;
            rp.colorAttachments[0].loadAction = load;
            rp.colorAttachments[0].storeAction = store;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.3, 1);
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:ps];
            [e setFragmentTexture:g_src atIndex:0];
            [e setFragmentSamplerState:g_smp atIndex:0];
            for (int i = 0; i < draws; i++) {
                float c[4] = { 0.5f, 0.1f * (i % 10), 0.3f, 0.25f };
                [e setFragmentBytes:c length:sizeof c atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
            [e endEncoding];
        }
        uint64_t t0 = mach_absolute_time();
        [cb commit];
        [cb waitUntilCompleted];
        if (r >= 0) v[r] = ms(mach_absolute_time() - t0);
    }
    qsort(v, runs, sizeof *v, cmp);
    double m = v[runs / 2];
    free(v);
    return m;
}

// Median ms of a command buffer made by `encode`.
static double timed(id<MTLCommandQueue> q, int runs, void (^encode)(id<MTLCommandBuffer>)) {
    double *v = calloc(runs, sizeof *v);
    for (int r = -2; r < runs; r++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        encode(cb);
        uint64_t t0 = mach_absolute_time();
        [cb commit];
        [cb waitUntilCompleted];
        if (r >= 0) v[r] = ms(mach_absolute_time() - t0);
    }
    qsort(v, runs, sizeof *v, cmp);
    double m = v[runs / 2];
    free(v);
    return m;
}

// P9: GB/s of a compute copy (bytes read + written) and of a write-only fill, at 1x and 4x the framebuffer size (the
// fixed submit cost shows as the difference), and of a private texture blit.
static void bandwidth(id<MTLDevice> dev, id<MTLLibrary> lib, id<MTLCommandQueue> q, int runs) {
    NSError *err = nil;
    id<MTLComputePipelineState> copy = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copy4"] error:&err];
    id<MTLComputePipelineState> fill = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fill4"] error:&err];
    if (!copy || !fill) { printf("bandwidth: %s\n", err.description.UTF8String); return; }
    printf("bandwidth (P9), median of %d runs:\n", runs);
    double t1[2] = { 0, 0 };
    for (int k = 0; k < 2; k++) {
        NSUInteger bytes = (NSUInteger)W * H * 4 * (k ? 4 : 1), n = bytes / 16;
        id<MTLBuffer> a = [dev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        id<MTLBuffer> b = [dev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        NSUInteger tg = MIN(copy.maxTotalThreadsPerThreadgroup, (NSUInteger)256);
        double c = timed(q, runs, ^(id<MTLCommandBuffer> cb) {
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:copy];
            [e setBuffer:a offset:0 atIndex:0];
            [e setBuffer:b offset:0 atIndex:1];
            [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
            [e endEncoding];
        });
        double f = timed(q, runs, ^(id<MTLCommandBuffer> cb) {
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:fill];
            [e setBuffer:b offset:0 atIndex:0];
            [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
            [e endEncoding];
        });
        printf("  %5.1f MB: copy %.2f ms (%.1f GB/s read+write)  fill %.2f ms (%.1f GB/s)\n", bytes / 1e6, c,
               2 * bytes / c / 1e6, f, bytes / f / 1e6);
        if (k == 0) { t1[0] = c; t1[1] = f; }
        else printf("  marginal (4x - 1x): copy %.1f GB/s  fill %.1f GB/s\n", 2 * 3.0 * W * H * 4 / (c - t1[0]) / 1e6,
                    3.0 * W * H * 4 / (f - t1[1]) / 1e6);
    }
    id<MTLTexture> s = privateTexture(dev), d = privateTexture(dev);
    double bl = timed(q, runs, ^(id<MTLCommandBuffer> cb) {
        id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
        [e copyFromTexture:s sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                 toTexture:d destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [e endEncoding];
    });
    printf("  texture blit %dx%d private: %.2f ms (%.1f GB/s read+write)\n", W, H, bl, 2.0 * W * H * 4 / bl / 1e6);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int runs = argc > 1 ? atoi(argv[1]) : 15;
        bool bwOnly = argc > 2 && !strcmp(argv[2], "bw");
        id<MTLDevice> dev = TSMtlCreateDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kMSL options:nil error:&err];
        if (!lib) { fprintf(stderr, "passbench: %s\n", err.description.UTF8String); return 1; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        id<MTLRenderPipelineState> variants[4];   // fs_lit, fs_tex blended; fs_lit, fs unblended
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) { fprintf(stderr, "passbench: %s\n", err.description.UTF8String); return 1; }
        pd.fragmentFunction = [lib newFunctionWithName:@"fs_lit"];
        variants[0] = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs_tex"];
        variants[1] = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        pd.colorAttachments[0].blendingEnabled = NO;
        pd.fragmentFunction = [lib newFunctionWithName:@"fs_lit"];
        variants[2] = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        variants[3] = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        g_src = privateTexture(dev);
        g_smp = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        bandwidth(dev, lib, q, runs);
        if (bwOnly) return 0;
        id<MTLTexture> tex[2] = { surfaceTexture(dev), privateTexture(dev) };
        const char *names[2] = { "IOSurface (linear)", "private" };
        printf("passbench %dx%d BGRA8, median of %d runs (ms per command buffer)\n", W, H, runs);
        for (int k = 0; k < 2; k++) {
            if (!tex[k]) { printf("%s: no texture\n", names[k]); continue; }
            printf("%s:\n", names[k]);
            printf("  1 pass, 1 draw:   clear+dontcare %.2f  clear+store %.2f  load+store %.2f\n",
                   run(q, ps, tex[k], 1, 1, MTLLoadActionClear, MTLStoreActionDontCare, runs),
                   run(q, ps, tex[k], 1, 1, MTLLoadActionClear, MTLStoreActionStore, runs),
                   run(q, ps, tex[k], 1, 1, MTLLoadActionLoad, MTLStoreActionStore, runs));
            printf("  4 passes, 1 draw: load+store %.2f\n", run(q, ps, tex[k], 4, 1, MTLLoadActionLoad, MTLStoreActionStore, runs));
            printf("  1 pass, 10 full-screen blended draws: load+store %.2f\n",
                   run(q, ps, tex[k], 1, 10, MTLLoadActionLoad, MTLStoreActionStore, runs));
        }
        printf("private, 1 pass, 10 full-screen draws (clear+store), by fragment shader:\n");
        printf("  blended: constant buffer %.2f  literal %.2f  texture %.2f | opaque: literal %.2f  constant buffer %.2f\n",
               run(q, ps, tex[1], 1, 10, MTLLoadActionClear, MTLStoreActionStore, runs),
               variants[0] ? run(q, variants[0], tex[1], 1, 10, MTLLoadActionClear, MTLStoreActionStore, runs) : -1,
               variants[1] ? run(q, variants[1], tex[1], 1, 10, MTLLoadActionClear, MTLStoreActionStore, runs) : -1,
               variants[2] ? run(q, variants[2], tex[1], 1, 10, MTLLoadActionClear, MTLStoreActionStore, runs) : -1,
               variants[3] ? run(q, variants[3], tex[1], 1, 10, MTLLoadActionClear, MTLStoreActionStore, runs) : -1);
    }
    return 0;
}
