// TeraScale Compute: per-dispatch cost of the OpenCL path (docs/OTTIMIZZAZIONE-COMPUTE.md, C1-C4 and E3), for A/B
// between driver builds. Links whatever libTSMetal.dylib sits next to it (or in -rpath), so the same source
// measures an older build too.
//   small: 1000 saxpy dispatches per command buffer, each with its own setBytes (C1: inline data, C3: arguments)
//   image: a 2048x2048 texture kernel dispatched in 256x1 strips, as apps that size groups for 1D do (E3)
// With TSMTL_STATS=1 it also checks that command buffer completion waits for the kernels (GPU time from profiling).
// Build: make build/dispatchbench   Run: [TSMTL_STATS=1] build/dispatchbench [rounds]
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <sys/resource.h>
#import <math.h>
#import <dlfcn.h>
#import "TSMetal.h"

static const char *kSource =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct P { float a; uint n; };\n"
    "kernel void saxpy(device const float *x [[buffer(0)]], device float *y [[buffer(1)]], constant P &p [[buffer(2)]],\n"
    "                  uint gid [[thread_position_in_grid]]) { if (gid < p.n) y[gid] = p.a * x[gid] + y[gid]; }\n"
    "kernel void lumaimg(texture2d<float, access::read> src [[texture(0)]], device float *out [[buffer(0)]],\n"
    "                    uint2 gid [[thread_position_in_grid]], uint2 size [[threads_per_grid]]) {\n"
    "    float4 c = src.read(gid);\n"
    "    out[gid.y * size.x + gid.x] = dot(c.rgb, float3(0.299, 0.587, 0.114));\n"
    "}\n";

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static double cpu_ms(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1e3 + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e3;
}

int main(int argc, char **argv) { @autoreleasepool {
    int rounds = argc > 1 ? atoi(argv[1]) : 10;
    setenv("TSMTL_COMPUTE", "1", 0);
    id<MTLDevice> dev = TSMtlCreateDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSource) options:nil error:&e];
    if (!lib) { printf("library: %s\n", e.description.UTF8String); return 1; }
    id<MTLComputePipelineState> saxpy = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"saxpy"] error:&e];
    id<MTLComputePipelineState> luma = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"lumaimg"] error:&e];
    printf("paths: saxpy %s, lumaimg %s\n", [[(id)saxpy valueForKey:@"computePath"] UTF8String], [[(id)luma valueForKey:@"computePath"] UTF8String]);

    const NSUInteger N = 1024, D = 1000;
    id<MTLBuffer> X = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> Y = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModePrivate];
    const NSUInteger S = 2048;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:S height:S mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> img = [dev newTextureWithDescriptor:td];
    uint8_t *px = malloc(S * S * 4);
    for (NSUInteger i = 0; i < S * S; i++) { px[i * 4] = (uint8_t)i; px[i * 4 + 1] = (uint8_t)(i >> 8); px[i * 4 + 2] = 77; px[i * 4 + 3] = 255; }
    [img replaceRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0 withBytes:px bytesPerRow:S * 4];
    id<MTLBuffer> O = [dev newBufferWithLength:S * S * 4 options:MTLResourceStorageModeShared];      // checked once
    id<MTLBuffer> OP = [dev newBufferWithLength:S * S * 4 options:MTLResourceStorageModePrivate];    // timed (no readback)

    double smallWall = 0, smallCPU = 0, imageWall = 0;
    for (int r = -1; r < rounds; r++) {   // round -1 warms up (builds, wraps)
        double w0 = now_ms(), c0 = cpu_ms();
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:saxpy];
        [enc setBuffer:X offset:0 atIndex:0]; [enc setBuffer:Y offset:0 atIndex:1];
        for (NSUInteger i = 0; i < D; i++) {
            struct { float a; uint32_t n; } p = { 1.0f + i * 1e-3f, (uint32_t)N };
            [enc setBytes:&p length:sizeof p atIndex:2];
            [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        }
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (r >= 0) { smallWall += now_ms() - w0; smallCPU += cpu_ms() - c0; }

        w0 = now_ms();
        cb = [q commandBuffer];
        enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:luma];
        [enc setTexture:img atIndex:0]; [enc setBuffer:r < rounds - 1 ? OP : O offset:0 atIndex:0];
        for (int i = 0; i < 4; i++) [enc dispatchThreads:MTLSizeMake(S, S, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (r >= 0 && r < rounds - 1) imageWall += now_ms() - w0;
    }
    printf("small: %.1f us per dispatch (commit to completion), %.1f us CPU per dispatch (all threads)\n",
           smallWall / rounds / D * 1000, smallCPU / rounds / D * 1000);
    NSUInteger bad = 0;
    const float *o = O.contents;
    for (NSUInteger i = 0; i < S * S; i += 997) {
        float want = (px[i * 4] * 0.299f + px[i * 4 + 1] * 0.587f + 77 * 0.114f) / 255.0f;
        if (fabsf(o[i] - want) > 2e-3f) bad++;
    }
    printf("image: %.2f ms per 2048x2048 dispatch in 256x1 groups (%lu of %lu sampled outputs wrong)\n", imageWall / MAX(rounds - 1, 1) / 4,
           (unsigned long)bad, (unsigned long)(S * S / 997 + 1));
    free(px);
    // With TSMTL_STATS=1 the OpenCL path profiles its kernels (G2): GPU time per kernel since the start.
    NSDictionary *(*times)(void) = (NSDictionary *(*)(void))dlsym(RTLD_DEFAULT, "TSMtlComputeKernelTimes");
    NSDictionary *t = times ? times() : nil;
    for (NSString *name in t) {
        double ms = [t[name][0] doubleValue];
        unsigned long long n = [t[name][1] unsignedLongLongValue];
        printf("gpu: %s %.3f ms per enqueue (%llu enqueues)\n", name.UTF8String, n ? ms / n : 0, n);
    }
    // Regression (fixed 2026-11-02): command buffers completed before their OpenCL kernels had even reached the GPU.
    NSArray *lumaT = t[@"lumaimg"];
    if (lumaT && [lumaT[1] unsignedLongLongValue]) {
        double gpu = [lumaT[0] doubleValue] / [lumaT[1] unsignedLongLongValue], wall = imageWall / MAX(rounds - 1, 1) / 4;
        BOOL waits = wall >= 0.9 * gpu;
        printf("completion %s: %.2f ms from commit to completion per dispatch, %.2f ms of GPU time\n",
               waits ? "waits for the kernels" : "EARLY (before the kernels ran)", wall, gpu);
        if (!waits || bad) return 1;
    }
    return 0;
} }
