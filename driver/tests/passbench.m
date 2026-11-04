// What a render pass costs on the phone's GPU: full-screen passes (the size of CoreAnimation's framebuffer) on a
// linear IOSurface (what backboardd renders into) and on a private texture (Panfrost: AFBC), with each load/store
// combination, and full-screen blended draws within one pass. Times are commit -> completed, median of the runs.
// Usage: passbench [runs]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>

id<MTLDevice> TSMtlCreateDevice(void);

enum { W = 1125, H = 2436 };

static NSString *const kMSL = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { V v; float2 t = float2((i << 1) & 2, i & 2); v.p = float4(t * 2 - 1, 0, 1); return v; }\n"
    "fragment half4 fs(constant float4 &c [[buffer(0)]]) { return half4(c); }\n";

static double ms(uint64_t abs) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)abs * tb.numer / tb.denom / 1e6;
}

static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

static id<MTLTexture> surfaceTexture(id<MTLDevice> dev) {
    size_t bpr = (W * 4 + 63) & ~(size_t)63;
    NSDictionary *p = @{ (id)kIOSurfaceWidth: @W, (id)kIOSurfaceHeight: @H, (id)kIOSurfaceBytesPerElement: @4,
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

int main(int argc, char **argv) {
    @autoreleasepool {
        int runs = argc > 1 ? atoi(argv[1]) : 15;
        id<MTLDevice> dev = TSMtlCreateDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kMSL options:nil error:&err];
        if (!lib) { fprintf(stderr, "passbench: %s\n", err.description.UTF8String); return 1; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) { fprintf(stderr, "passbench: %s\n", err.description.UTF8String); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
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
    }
    return 0;
}
