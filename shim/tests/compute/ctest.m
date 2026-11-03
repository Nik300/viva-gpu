// TeraScale Compute, OpenCL path: the kernels of kernels.metal run through the real device (libTSMetal) and are
// checked against CPU references: buffers, struct/float3/half layouts, threadgroup memory and barriers, dynamic
// threadgroup memory, int32 and float atomics (global and local), textures (read, sample, write, integer, IOSurface),
// constexpr samplers, function constants, 3D grids, dispatchThreads edges, indirect dispatch, CPU/GPU buffer merge,
// compute followed by blits in the same command buffer, a simdgroup kernel (refused, no-op), and dispatch costs.
// Build: make build/ctest   Run: build/ctest [--off]   (--off: compute disabled, every kernel inert)
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach_time.h>
#import <libproc.h>
#import <math.h>
#import "TSMetal.h"

static int gFails, gChecks;
#define CHECK(cond, ...) do { gChecks++; if (cond) printf("  ok    "); else { printf("  FAIL  "); gFails++; } printf(__VA_ARGS__); printf("\n"); } while (0)

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static id<MTLDevice> gDev;
static id<MTLCommandQueue> gQueue;
static id<MTLLibrary> gLib;

static id<MTLComputePipelineState> pipelineFn(id<MTLFunction> f) {
    NSError *e = nil;
    id<MTLComputePipelineState> p = [gDev newComputePipelineStateWithFunction:f error:&e];
    if (!p) { printf("  FAIL  pipeline %s: %s\n", f.name.UTF8String, e.description.UTF8String); gFails++; }
    return p;
}
static id<MTLComputePipelineState> pipeline(NSString *name) { return pipelineFn([gLib newFunctionWithName:name]); }
static NSString *pathOf(id<MTLComputePipelineState> p) { return [(id)p valueForKey:@"computePath"]; }

static id<MTLBuffer> buffer(const void *bytes, NSUInteger length, MTLResourceOptions options) {
    return bytes ? [gDev newBufferWithBytes:bytes length:length options:options] : [gDev newBufferWithLength:length options:options];
}

static id<MTLTexture> texture(MTLPixelFormat f, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return [gDev newTextureWithDescriptor:d];
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

static uint32_t gRand = 12345;
static uint32_t rnd(void) { gRand = gRand * 1664525u + 1013904223u; return gRand >> 8; }
static float frnd(void) { return (float)(rnd() % 20000) / 1000.0f - 10.0f; }

int main(int argc, char **argv) { @autoreleasepool {
    BOOL off = argc > 1 && !strcmp(argv[1], "--off");
    BOOL idle = argc > 1 && !strcmp(argv[1], "--idle");   // M4: run with TSMTL_CL_IDLE=2 TSMTL_LOG=1
    setenv("TSMTL_COMPUTE", off ? "0" : "1", 1);
    gDev = TSMtlCreateDevice();
    gQueue = [gDev newCommandQueue];
    NSError *e = nil;
    gLib = [gDev newLibraryWithSource:[NSString stringWithContentsOfFile:@(TS_SOURCE_DIR "/tests/compute/kernels.metal")
                                                                encoding:NSUTF8StringEncoding error:nil] options:nil error:&e];
    if (!gLib) { printf("library: %s\n", e.description.UTF8String); return 1; }
    if (argc > 2 && !strcmp(argv[1], "--soak")) {   // leak check: the paths of the optimizations, many times
        int rounds = atoi(argv[2]);
        id<MTLComputePipelineState> store = pipeline(@"store_param"), ind = pipeline(@"write_indirect"), count = pipeline(@"count_threads"),
                                    add = pipeline(@"vadd"), nullP = pipeline(@"null_probe");
        const NSUInteger N = 65536;
        id<MTLBuffer> A = buffer(NULL, N * 4, MTLResourceStorageModeShared), C = buffer(NULL, N * 4, MTLResourceStorageModeShared),
                      PRIV = buffer(NULL, N * 4, MTLResourceStorageModePrivate), D = buffer(NULL, N * 4, MTLResourceStorageModeShared),
                      IND = buffer(NULL, 12, MTLResourceStorageModeShared), CNT = buffer(NULL, 4, MTLResourceStorageModeShared);
        for (int r = 0; r < rounds; r++) @autoreleasepool {
            id<MTLCommandBuffer> cb = [gQueue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:store]; [enc setBuffer:D offset:0 atIndex:0];
            for (uint32_t i = 0; i < 32; i++) {
                uint32_t pv[2] = { i, (uint32_t)r };
                [enc setBytes:pv length:sizeof pv atIndex:1];
                [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            }
            uint32_t groups = 4;
            [enc setComputePipelineState:ind]; [enc setBuffer:IND offset:0 atIndex:0]; [enc setBytes:&groups length:4 atIndex:1];
            [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [enc setComputePipelineState:count]; [enc setBuffer:CNT offset:0 atIndex:0];
            [enc dispatchThreadgroupsWithIndirectBuffer:IND indirectBufferOffset:0 threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [enc setComputePipelineState:add];
            [enc setBuffer:A offset:0 atIndex:0]; [enc setBuffer:A offset:0 atIndex:1]; [enc setBuffer:PRIV offset:0 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc setBuffer:C offset:0 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc setComputePipelineState:nullP]; [enc setTexture:nil atIndex:0]; [enc setBuffer:D offset:256 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [enc endEncoding];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromBuffer:PRIV sourceOffset:0 toBuffer:D destinationOffset:4096 size:N * 2];
            [blit endEncoding];
            [cb commit];
            ((float *)C.contents)[r % N] = 1;   // CPU write while the kernel's merge is pending
            if (r % 4 == 3) [cb waitUntilCompleted];
            if (r % (rounds / 10 ?: 1) == 0 || r == rounds - 1) {
                [cb waitUntilCompleted];
                struct rusage_info_v4 ru = { 0 };
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ru);
                printf("round %6d: footprint %.1f MB\n", r, ru.ri_phys_footprint / 1048576.0);
                fflush(stdout);
            }
        }
        return 0;
    }
    if (idle) {   // M4: the CL context goes away while idle and comes back for the next dispatch
        id<MTLComputePipelineState> p = pipeline(@"vadd");
        float a[256];
        for (int i = 0; i < 256; i++) a[i] = i;
        id<MTLBuffer> A = buffer(a, sizeof a, MTLResourceStorageModeShared), C = buffer(NULL, sizeof a, MTLResourceStorageModeShared);
        for (int round = 0; round < 2; round++) {
            memset(C.contents, 0, sizeof a);
            run(^(id<MTLComputeCommandEncoder> enc) {
                [enc setComputePipelineState:p];
                [enc setBuffer:A offset:0 atIndex:0]; [enc setBuffer:A offset:0 atIndex:1]; [enc setBuffer:C offset:0 atIndex:2];
                [enc dispatchThreads:MTLSizeMake(256, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            });
            struct rusage_info_v4 ru = { 0 };
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ru);
            CHECK(((float *)C.contents)[255] == 510.0f, "vadd %s (footprint %.1f MB, resident %.1f MB)", round ? "after the idle release" : "before the idle release",
                  ru.ri_phys_footprint / 1048576.0, ru.ri_resident_size / 1048576.0);
            if (!round) {
                [NSThread sleepForTimeInterval:6];
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ru);
                printf("        footprint while released: %.1f MB (resident %.1f MB)\n", ru.ri_phys_footprint / 1048576.0, ru.ri_resident_size / 1048576.0);
            }
        }
        printf("%s\n", gFails ? "ctest --idle: FAILURES" : "ctest --idle: all ok");
        return gFails ? 1 : 0;
    }
    printf("compute %s\n", off ? "off (TSMTL_COMPUTE=0)" : "on (TSMTL_COMPUTE=1)");
    const MTLResourceOptions shared = MTLResourceStorageModeShared;

    printf("-- pipelines\n");
    NSArray *names = @[@"vadd", @"saxpy", @"reduce_sum", @"scan_block", @"histogram", @"histogram_local", @"float_atomic", @"particles",
                       @"blur_tex", @"luma", @"transpose_u", @"grid3d", @"mathy", @"rw_double"];
    NSMutableDictionary<NSString *, id<MTLComputePipelineState>> *P = [NSMutableDictionary dictionary];
    double t0 = now_ms();
    for (NSString *n in names) {
        id<MTLComputePipelineState> p = pipeline(n);
        if (!p) continue;
        P[n] = p;
        // blur_tex writes one texture at gid: the GL path takes it (no OpenCL submission).
        NSString *want = off ? @"off" : [n isEqualToString:@"blur_tex"] ? @"gl" : @"cl";
        CHECK([pathOf(p) isEqualToString:want], "%-16s %s (max %lu threads)", n.UTF8String, pathOf(p).UTF8String,
              (unsigned long)p.maxTotalThreadsPerThreadgroup);
    }
    printf("  (%lu pipelines in %.0f ms)\n", (unsigned long)names.count, now_ms() - t0);
    id<MTLComputePipelineState> simd = pipeline(@"simd_sum");
    CHECK(off ? [pathOf(simd) isEqualToString:@"off"] : [pathOf(simd) containsString:@"simdgroup"], "simd_sum refused: %s", pathOf(simd).UTF8String);
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
    float scale = 2.5f;
    [cv setConstantValue:&scale type:MTLDataTypeFloat atIndex:0];
    id<MTLComputePipelineState> scaleFC = pipelineFn([gLib newFunctionWithName:@"scale_fc" constantValues:cv error:&e]);

    printf("-- buffers\n");
    {   // vadd: 100003 floats, 256-thread groups -> an edge enqueue
        const NSUInteger N = 100003;
        float *a = malloc(N * 4), *b = malloc(N * 4);
        for (NSUInteger i = 0; i < N; i++) { a[i] = frnd(); b[i] = frnd(); }
        id<MTLBuffer> A = buffer(a, N * 4, shared), B = buffer(b, N * 4, shared), C = buffer(NULL, N * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"vadd"]];
            [enc setBuffer:A offset:0 atIndex:0]; [enc setBuffer:B offset:0 atIndex:1]; [enc setBuffer:C offset:0 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        });
        const float *c = C.contents;
        NSUInteger bad = 0;
        for (NSUInteger i = 0; i < N; i++) if (c[i] != a[i] + b[i]) bad++;
        CHECK(off ? c[N - 1] == 0 : bad == 0, "vadd %lu floats with an edge group: %lu wrong", (unsigned long)N, (unsigned long)bad);
        free(a); free(b);
    }
    {   // saxpy: setBytes parameters, buffer offsets, 1000 threads in 64-groups
        const NSUInteger N = 1000;
        float *x = malloc((N + 16) * 4), *y = malloc((N + 16) * 4);
        for (NSUInteger i = 0; i < N + 16; i++) { x[i] = frnd(); y[i] = frnd(); }
        id<MTLBuffer> X = buffer(x, (N + 16) * 4, shared), Y = buffer(y, (N + 16) * 4, shared);
        struct { float a; uint32_t n; } prm = { 1.5f, (uint32_t)N };
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"saxpy"]];
            [enc setBuffer:X offset:16 atIndex:0]; [enc setBuffer:Y offset:64 atIndex:1]; [enc setBytes:&prm length:sizeof prm atIndex:2];
            [enc dispatchThreads:MTLSizeMake(N + 7, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        });
        const float *r = Y.contents;
        NSUInteger bad = 0;
        for (NSUInteger i = 0; i < 16; i++) if (r[i] != y[i]) bad++;   // before the offset: untouched
        for (NSUInteger i = 0; i < N; i++) if (fabsf(r[16 + i] - (1.5f * x[4 + i] + y[16 + i])) > 1e-4f) bad++;
        CHECK(off ? r[16] == y[16] : bad == 0, "saxpy with setBytes and offsets: %lu wrong", (unsigned long)bad);
        free(x); free(y);
    }
    {   // reduce_sum: threadgroup memory, barriers, threadgroup built-ins
        const NSUInteger G = 64, T = 256;
        float *in = malloc(G * T * 4);
        for (NSUInteger i = 0; i < G * T; i++) in[i] = (float)(rnd() % 1000) / 8.0f;
        id<MTLBuffer> I = buffer(in, G * T * 4, shared), O = buffer(NULL, G * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"reduce_sum"]];
            [enc setBuffer:I offset:0 atIndex:0]; [enc setBuffer:O offset:0 atIndex:1];
            [enc dispatchThreadgroups:MTLSizeMake(G, 1, 1) threadsPerThreadgroup:MTLSizeMake(T, 1, 1)];
        });
        const float *o = O.contents;
        NSUInteger bad = 0;
        for (NSUInteger g = 0; g < G; g++) {
            double s = 0;
            for (NSUInteger i = 0; i < T; i++) s += in[g * T + i];
            if (fabs(o[g] - s) > 1e-2) bad++;
        }
        CHECK(off ? o[0] == 0 : bad == 0, "reduce_sum %lu groups of %lu: %lu wrong", (unsigned long)G, (unsigned long)T, (unsigned long)bad);
        free(in);
    }
    {   // scan_block: dynamic threadgroup memory (setThreadgroupMemoryLength)
        const NSUInteger T = 128, G = 8;
        uint32_t *in = malloc(T * G * 4);
        for (NSUInteger i = 0; i < T * G; i++) in[i] = rnd() % 100;
        id<MTLBuffer> I = buffer(in, T * G * 4, shared), O = buffer(NULL, T * G * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"scan_block"]];
            [enc setBuffer:I offset:0 atIndex:0]; [enc setBuffer:O offset:0 atIndex:1];
            [enc setThreadgroupMemoryLength:T * 4 atIndex:0];
            [enc dispatchThreadgroups:MTLSizeMake(G, 1, 1) threadsPerThreadgroup:MTLSizeMake(T, 1, 1)];
        });
        const uint32_t *o = O.contents;
        NSUInteger bad = 0;
        for (NSUInteger g = 0; g < G; g++) {
            uint32_t acc = 0;
            for (NSUInteger i = 0; i < T; i++) {
                // lane 0 gets 0; lane i gets the sum of in[gid-1] over the block's lanes 1..i
                if (o[g * T + i] != acc) bad++;
                acc += in[g * T + i];
                if (i == 0) acc = in[g * T];   // lane 1 sees in[g*T]
            }
        }
        CHECK(off ? o[1] == 0 : bad == 0, "scan_block (dynamic threadgroup memory): %lu wrong", (unsigned long)bad);
        free(in);
    }
    {   // histogram (global atomics) and histogram_local (local atomics, atomic min/max on ints)
        const NSUInteger N = 1 << 18;
        uint8_t *data = malloc(N);
        for (NSUInteger i = 0; i < N; i++) data[i] = (uint8_t)(rnd() & 255);
        uint32_t ref[256] = {0}, ref16[16] = {0};
        int mn = INT32_MAX, mx = INT32_MIN;
        for (NSUInteger i = 0; i < N; i++) { ref[data[i]]++; ref16[data[i] & 15]++; mn = MIN(mn, data[i] - 100); mx = MAX(mx, data[i] - 100); }
        id<MTLBuffer> D = buffer(data, N, shared), H = buffer(NULL, 256 * 4, shared), H16 = buffer(NULL, 16 * 4, shared);
        int init[2] = { INT32_MAX, INT32_MIN };
        id<MTLBuffer> MM = buffer(init, 8, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"histogram"]];
            [enc setBuffer:D offset:0 atIndex:0]; [enc setBuffer:H offset:0 atIndex:1];
            [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc setComputePipelineState:P[@"histogram_local"]];
            [enc setBuffer:H16 offset:0 atIndex:1]; [enc setBuffer:MM offset:0 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
        });
        const uint32_t *h = H.contents, *h16 = H16.contents;
        const int *m = MM.contents;
        NSUInteger bad = 0, bad16 = 0;
        for (int i = 0; i < 256; i++) if (h[i] != ref[i]) bad++;
        for (int i = 0; i < 16; i++) if (h16[i] != ref16[i]) bad16++;
        CHECK(off ? h[0] == 0 : bad == 0, "histogram (global atomics, 2^18 bytes): %lu bins wrong", (unsigned long)bad);
        CHECK(off ? h16[0] == 0 : bad16 == 0 && m[0] == mn && m[1] == mx, "histogram_local (local atomics, atomic min/max): %lu bins wrong, min %d/%d max %d/%d",
              (unsigned long)bad16, m[0], mn, m[1], mx);
        free(data);
    }
    {   // float atomic add (compare-and-swap loop)
        float zero = 0;
        id<MTLBuffer> S = buffer(&zero, 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"float_atomic"]];
            [enc setBuffer:S offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(4096, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        });
        float s = *(float *)S.contents;
        CHECK(off ? s == 0 : s == 2048.0f, "float atomic add x4096: %g", s);
    }
    {   // particles: struct with float3 (16-byte aligned) members, constant float, half4 output
        typedef struct { float pos[4]; float vel[4]; float life; uint32_t flags; uint32_t pad[2]; } Particle;   // Metal layout: 48 bytes
        const NSUInteger N = 777;
        Particle *ps = calloc(N, sizeof(Particle)), *ref = calloc(N, sizeof(Particle));
        for (NSUInteger i = 0; i < N; i++) {
            for (int k = 0; k < 3; k++) { ps[i].pos[k] = frnd(); ps[i].vel[k] = frnd(); }
            ps[i].life = (float)(rnd() % 100) / 50.0f;
            ps[i].flags = (uint32_t)i << 4;
        }
        memcpy(ref, ps, N * sizeof(Particle));
        float dt = 0.125f;
        for (NSUInteger i = 0; i < N; i++) {
            Particle *p = &ref[i];
            p->vel[1] -= 9.8f * dt;
            for (int k = 0; k < 3; k++) p->pos[k] += p->vel[k] * dt;
            if (p->pos[1] < 0) { p->pos[1] = -p->pos[1]; p->vel[1] = -p->vel[1] * 0.5f; p->flags |= 1; }
            p->life = fmaxf(p->life - dt, 0);
        }
        id<MTLBuffer> PS = buffer(ps, N * sizeof(Particle), shared), COL = buffer(NULL, N * 8, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"particles"]];
            [enc setBuffer:PS offset:0 atIndex:0]; [enc setBytes:&dt length:4 atIndex:1]; [enc setBuffer:COL offset:0 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        });
        const Particle *r = PS.contents;
        const __fp16 *col = COL.contents;
        NSUInteger bad = 0;
        for (NSUInteger i = 0; i < N; i++) {
            for (int k = 0; k < 3; k++) if (fabsf(r[i].pos[k] - ref[i].pos[k]) > 1e-4f || fabsf(r[i].vel[k] - ref[i].vel[k]) > 1e-4f) { bad++; break; }
            if (fabsf(r[i].life - ref[i].life) > 1e-5f || r[i].flags != ref[i].flags) bad++;
            if (fabsf((float)col[i * 4] - ref[i].life) > 2e-3f || (float)col[i * 4 + 3] != 1.0f) bad++;
        }
        CHECK(off ? r[0].flags == 0 : bad == 0, "particles (struct/float3/half4): %lu wrong", (unsigned long)bad);
        free(ps); free(ref);
    }
    {   // CPU writes elsewhere in a shared buffer while the kernel writes its part: both survive the merge
        const NSUInteger N = 4096;
        float *a = calloc(N * 2, 4);
        for (NSUInteger i = 0; i < N * 2; i++) a[i] = (float)i;
        id<MTLBuffer> A = buffer(a, N * 4, shared), B = buffer(a, N * 4, shared), C = buffer(NULL, N * 2 * 4, shared);
        id<MTLCommandBuffer> cb = [gQueue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:P[@"vadd"]];
        [enc setBuffer:A offset:0 atIndex:0]; [enc setBuffer:B offset:0 atIndex:1]; [enc setBuffer:C offset:0 atIndex:2];
        [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [enc endEncoding];
        [cb commit];
        float *c = C.contents;
        for (NSUInteger i = N; i < 2 * N; i++) c[i] = -1.0f;   // the second half belongs to the CPU
        [cb waitUntilCompleted];
        NSUInteger bad = 0;
        for (NSUInteger i = 0; i < N; i++) if (c[i] != 2.0f * i && !off) bad++;
        for (NSUInteger i = N; i < 2 * N; i++) if (c[i] != -1.0f) bad++;
        CHECK(bad == 0, "CPU and GPU writes to different halves of a shared buffer merge: %lu wrong", (unsigned long)bad);
        free(a);
    }
    {   // compute -> blit (buffer copy reads the GPU-written buffer) in one command buffer; indirect dispatch
        const NSUInteger N = 1024;
        float *a = malloc(N * 4);
        for (NSUInteger i = 0; i < N; i++) a[i] = (float)i;
        id<MTLBuffer> A = buffer(a, N * 4, shared), C = buffer(NULL, N * 4, MTLResourceStorageModePrivate), D = buffer(NULL, N * 4, shared);
        uint32_t args[3] = { (uint32_t)(N / 64), 1, 1 };
        id<MTLBuffer> IND = buffer(args, sizeof args, shared);
        id<MTLCommandBuffer> cb = [gQueue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:P[@"vadd"]];
        [enc setBuffer:A offset:0 atIndex:0]; [enc setBuffer:A offset:0 atIndex:1]; [enc setBuffer:C offset:0 atIndex:2];
        [enc dispatchThreadgroupsWithIndirectBuffer:IND indirectBufferOffset:0 threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:C sourceOffset:0 toBuffer:D destinationOffset:0 size:N * 4];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        const float *d = D.contents;
        NSUInteger bad = 0;
        for (NSUInteger i = 0; i < N; i++) if (d[i] != 2.0f * i) bad++;
        CHECK(off ? d[1] == 0 : bad == 0, "indirect dispatch into a private buffer, then blit copy in the same command buffer: %lu wrong",
              (unsigned long)bad);
        free(a);
    }
    {   // function constant
        float v[256];
        for (int i = 0; i < 256; i++) v[i] = i;
        id<MTLBuffer> V = buffer(v, sizeof v, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:scaleFC];
            [enc setBuffer:V offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(256, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        });
        const float *r = V.contents;
        CHECK(off ? r[3] == 3 : r[3] == 7.5f && r[255] == 637.5f, "function constant scale 2.5: %g %g (%s)", r[3], r[255], pathOf(scaleFC).UTF8String);
    }
    {   // 3D grid built-ins with threadgroup positions
        const NSUInteger W = 12, H = 8, Dp = 4;
        id<MTLBuffer> O = buffer(NULL, W * H * Dp * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"grid3d"]];
            [enc setBuffer:O offset:0 atIndex:0];
            [enc dispatchThreadgroups:MTLSizeMake(3, 2, 2) threadsPerThreadgroup:MTLSizeMake(4, 4, 2)];
        });
        const uint32_t *o = O.contents;
        NSUInteger bad = 0;
        for (NSUInteger z = 0; z < Dp; z++) for (NSUInteger y = 0; y < H; y++) for (NSUInteger x = 0; x < W; x++) {
            uint32_t tg = (uint32_t)((x / 4) + (y / 4) * 3 + (z / 2) * 6);
            if (o[(z * H + y) * W + x] != tg * 1000 + x + y * 10 + z * 100) bad++;
        }
        CHECK(off ? o[1] == 0 : bad == 0, "3D grid built-ins: %lu wrong", (unsigned long)bad);
    }
    {   // dispatchThreads 2D edges: grid 37x23 in 16x16 groups (4 enqueues), kernel reads threads_per_grid
        id<MTLTexture> src = texture(MTLPixelFormatRGBA8Unorm, 37, 23);
        uint8_t *px = malloc(37 * 23 * 4);
        for (NSUInteger i = 0; i < 37 * 23 * 4; i++) px[i] = (uint8_t)rnd();
        [src replaceRegion:MTLRegionMake2D(0, 0, 37, 23) mipmapLevel:0 withBytes:px bytesPerRow:37 * 4];
        id<MTLBuffer> O = buffer(NULL, 37 * 23 * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"luma"]];
            [enc setTexture:src atIndex:0];
            [enc setBuffer:O offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(37, 23, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        });
        const float *o = O.contents;
        NSUInteger bad = 0;
        for (NSUInteger i = 0; i < 37 * 23; i++) {
            float l = (px[i * 4] * 0.299f + px[i * 4 + 1] * 0.587f + px[i * 4 + 2] * 0.114f) / 255.0f;
            if (fabsf(o[i] - l) > 2e-3f) bad++;
        }
        CHECK(off ? o[0] == 0 : bad == 0, "luma: texture -> buffer, constexpr pixel sampler, 2D edges: %lu wrong", (unsigned long)bad);
        free(px);
    }

    printf("-- textures\n");
    {   // blur with a sampler argument on RGBA32Float
        const NSUInteger S = 48;
        id<MTLTexture> src = texture(MTLPixelFormatRGBA32Float, S, S), dst = texture(MTLPixelFormatRGBA32Float, S, S);
        float *px = malloc(S * S * 16), *out = malloc(S * S * 16);
        for (NSUInteger i = 0; i < S * S * 4; i++) px[i] = (float)(rnd() % 256);
        [src replaceRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0 withBytes:px bytesPerRow:S * 16];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        id<MTLSamplerState> smp = [gDev newSamplerStateWithDescriptor:sd];
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"blur_tex"]];
            [enc setTexture:src atIndex:0]; [enc setTexture:dst atIndex:1]; [enc setSamplerState:smp atIndex:0];
            [enc dispatchThreads:MTLSizeMake(S, S, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        });
        [dst getBytes:out bytesPerRow:S * 16 fromRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0];
        NSUInteger bad = 0;
        for (NSInteger y = 0; y < (NSInteger)S; y++) for (NSInteger x = 0; x < (NSInteger)S; x++) for (int c = 0; c < 4; c++) {
            float acc = 0;
            for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                NSInteger sx = MIN(MAX(x + dx, 0), (NSInteger)S - 1), sy = MIN(MAX(y + dy, 0), (NSInteger)S - 1);
                acc += px[(sy * S + sx) * 4 + c];
            }
            if (fabsf(out[(y * S + x) * 4 + c] - acc / 9.0f) > 1e-3f) bad++;
        }
        CHECK(off ? out[0] == 0 : bad == 0, "blur_tex (sampler argument, RGBA32Float, GL path): %lu wrong", (unsigned long)bad);
        free(px); free(out);
    }
    {   // transpose of an integer texture (scattered writes, read_imageui / write_imageui)
        const NSUInteger W = 32, H = 16;
        id<MTLTexture> src = texture(MTLPixelFormatRGBA32Uint, W, H), dst = texture(MTLPixelFormatRGBA32Uint, H, W);
        uint32_t *px = malloc(W * H * 16), *out = calloc(W * H, 16);
        for (NSUInteger i = 0; i < W * H * 4; i++) px[i] = rnd() % 100000;
        [src replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 16];
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"transpose_u"]];
            [enc setTexture:src atIndex:0]; [enc setTexture:dst atIndex:1];
            [enc dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        });
        [dst getBytes:out bytesPerRow:H * 16 fromRegion:MTLRegionMake2D(0, 0, H, W) mipmapLevel:0];
        NSUInteger bad = 0;
        for (NSUInteger y = 0; y < H; y++) for (NSUInteger x = 0; x < W; x++) for (int c = 0; c < 4; c++)
            if (out[(x * H + y) * 4 + c] != px[(y * W + x) * 4 + c] * 2) bad++;
        CHECK(off ? out[0] == 0 : bad == 0, "transpose_u (RGBA32Uint, scattered writes): %lu wrong", (unsigned long)bad);
        free(px); free(out);
    }
    {   // read_write texture (RGBA16Float): read and write views of the same GL texture
        const NSUInteger S = 64;
        id<MTLTexture> t = texture(MTLPixelFormatRGBA16Float, S, S);
        __fp16 *px = malloc(S * S * 8), *out = malloc(S * S * 8);
        for (NSUInteger i = 0; i < S * S * 4; i++) px[i] = (__fp16)(float)(rnd() % 1000);
        [t replaceRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0 withBytes:px bytesPerRow:S * 8];
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"rw_double"]];
            [enc setTexture:t atIndex:0];
            [enc dispatchThreads:MTLSizeMake(S, S, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        });
        [t getBytes:out bytesPerRow:S * 8 fromRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0];
        NSUInteger bad = 0;
        for (NSUInteger i = 0; i < S * S * 4; i++) if ((float)out[i] != 2.0f * (float)px[i]) bad++;
        CHECK(off ? out[0] == px[0] : bad == 0, "read_write texture (RGBA16Float, two views): %lu wrong", (unsigned long)bad);
        free(px); free(out);
    }
    {   // IOSurface (BGRA8) read in place by a kernel
        NSDictionary *props = @{ (id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @32, (id)kIOSurfaceBytesPerElement: @4,
                                 (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        IOSurfaceLock(surf, 0, NULL);
        uint8_t *base = IOSurfaceGetBaseAddress(surf);
        size_t pitch = IOSurfaceGetBytesPerRow(surf);
        for (int y = 0; y < 32; y++) for (int x = 0; x < 64; x++) {
            uint8_t *p = base + y * pitch + x * 4;
            p[0] = (uint8_t)(x * 4); p[1] = (uint8_t)(y * 8); p[2] = 200; p[3] = 255;   // B G R A
        }
        IOSurfaceUnlock(surf, 0, NULL);
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:32 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [gDev newTextureWithDescriptor:d iosurface:surf plane:0];
        id<MTLBuffer> O = buffer(NULL, 64 * 32 * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"luma"]];
            [enc setTexture:t atIndex:0]; [enc setBuffer:O offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(64, 32, 1) threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
        });
        const float *o = O.contents;
        NSUInteger bad = 0;
        for (int y = 0; y < 32; y++) for (int x = 0; x < 64; x++) {
            float l = (200 * 0.299f + (y * 8) * 0.587f + (x * 4) * 0.114f) / 255.0f;
            if (fabsf(o[y * 64 + x] - l) > 2e-3f) bad++;
        }
        CHECK(off ? o[0] == 0 : bad == 0, "IOSurface BGRA8 read in place by OpenCL: %lu wrong", (unsigned long)bad);
        CFRelease(surf);
    }

    printf("-- math\n");
    {
        const NSUInteger N = 256;
        float *in = malloc(N * 16);
        for (NSUInteger i = 0; i < N * 4; i++) in[i] = frnd() * 0.5f;
        id<MTLBuffer> I = buffer(in, N * 16, shared), O = buffer(NULL, N * 16, shared), IT = buffer(NULL, N * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:P[@"mathy"]];
            [enc setBuffer:I offset:0 atIndex:0]; [enc setBuffer:O offset:0 atIndex:1]; [enc setBuffer:IT offset:0 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        });
        const float *o = O.contents;
        const int *it = IT.contents;
        NSUInteger bad = 0, badi = 0;
        for (NSUInteger g = 0; g < N; g++) {
            for (int c = 0; c < 4; c++) {
                float v = in[g * 4 + c];
                float fr = v - floorf(v);
                float r = sqrtf(fabsf(v)) + sinf(v) * cosf(v) + exp2f(fminf(fmaxf(v, -4), 4)) + fr + floorf(v) + powf(fabsf(v) + 1, 0.5f);
                float sm = fminf(fmaxf(v, 0), 1);
                sm = sm * sm * (3 - 2 * sm);
                r += (v + (r - v) * 0.25f) + (v >= 0.5f ? 1 : 0) + sm + 1 / sqrtf(fabsf(v) + 1) + (v * v + 1);
                if (fabsf(o[g * 4 + c] - r) > 1e-3f * fmaxf(1, fabsf(r))) bad++;
            }
            uint32_t x;
            memcpy(&x, &in[g * 4], 4);
            x |= 1;
            int n = 0;
            while (x != 1 && n < 200) { x = (x & 1) ? 3 * x + 1 : x >> 1; n++; }
            uint32_t gid = (uint32_t)g;
            int ref = n + __builtin_popcount(gid) + __builtin_clz(gid + 1) + (int)MIN(gid, 7u) + abs((int)gid - 50) / 3 + ((int)gid - 50) % 7;
            if (it[g] != ref) badi++;
        }
        CHECK(off ? it[0] == 0 : bad == 0 && badi == 0, "math built-ins: %lu float lanes, %lu integer results wrong", (unsigned long)bad, (unsigned long)badi);
        free(in);
    }
    {   // simd_sum is refused: the dispatch leaves the output alone
        float v[64];
        for (int i = 0; i < 64; i++) v[i] = 1;
        id<MTLBuffer> I = buffer(v, sizeof v, shared), O = buffer(NULL, sizeof v, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:simd];
            [enc setBuffer:I offset:0 atIndex:0]; [enc setBuffer:O offset:0 atIndex:1];
            [enc dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        });
        CHECK(((float *)O.contents)[0] == 0, "simd_sum dispatch is a no-op");
    }

    printf("-- optimizations (docs/OTTIMIZZAZIONE-COMPUTE.md)\n");
    {   // A1: four threads create the same new pipeline at once: one translation, one build, one kernel object
        MTLFunctionConstantValues *cv4 = [MTLFunctionConstantValues new];
        float unique = (float)(arc4random() % 100000) + 0.5f;   // a source no cache has seen
        [cv4 setConstantValue:&unique type:MTLDataTypeFloat atIndex:0];
        id<MTLFunction> f = [gLib newFunctionWithName:@"scale_fc" constantValues:cv4 error:&e];
        NSMutableArray *ps = [NSMutableArray array];
        dispatch_apply(4, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            id<MTLComputePipelineState> p = [gDev newComputePipelineStateWithFunction:f error:nil];
            @synchronized (ps) { if (p) [ps addObject:p]; }
        });
        id k0 = off || ps.count < 4 ? nil : [ps[0] valueForKey:@"clKernel"];
        BOOL same = ps.count == 4;
        for (NSUInteger i = 1; i < ps.count; i++) same &= [ps[i] valueForKey:@"clKernel"] == k0;
        CHECK(off || (k0 && same), "4 threads creating one new pipeline share one OpenCL kernel");
    }
    {   // A4: the asynchronous variant calls back off the calling thread with a working pipeline
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL ok = NO, other = NO;
        NSThread *caller = NSThread.currentThread;
        [gDev newComputePipelineStateWithFunction:[gLib newFunctionWithName:@"vadd"] completionHandler:^(id<MTLComputePipelineState> p, NSError *err) {
            ok = p != nil; other = NSThread.currentThread != caller;
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        CHECK(ok && other, "asynchronous pipeline creation completes on another thread");
    }
    id<MTLComputePipelineState> nullP = pipeline(@"null_probe"), axesP = pipeline(@"sample_axes"), levelP = pipeline(@"sample_level"),
                                storeP = pipeline(@"store_param"), indP = pipeline(@"write_indirect"), countP = pipeline(@"count_threads");
    {   // B5: is_null_texture
        float one = 5.0f;
        id<MTLTexture> t = texture(MTLPixelFormatR32Float, 1, 1);
        [t replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&one bytesPerRow:4];
        id<MTLBuffer> O = buffer(NULL, 2 * 64 * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:nullP];
            [enc setBuffer:O offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [enc setTexture:t atIndex:0];
            [enc setBuffer:O offset:64 * 4 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        });
        const float *o = O.contents;
        CHECK(off ? o[0] == 0 : o[0] == -1.0f && o[63] == -1.0f && o[64] == 5.0f && o[127] == 5.0f,
              "is_null_texture: unbound %.0f, bound %.0f", o[0], o[64]);
    }
    {   // B3: s repeat, t clamp_to_zero, as an MTLSamplerState and as a constexpr sampler
        float px[16];
        for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) px[y * 4 + x] = x + 10 * y + 1;
        id<MTLTexture> t = texture(MTLPixelFormatR32Float, 4, 4);
        [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.sAddressMode = MTLSamplerAddressModeRepeat;
        sd.tAddressMode = MTLSamplerAddressModeClampToZero;
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
        id<MTLSamplerState> smp = [gDev newSamplerStateWithDescriptor:sd];
        const float co[][2] = { { 1.3f, 0.6f }, { 0.3f, 1.2f }, { -0.2f, 0.3f }, { 0.6f, -0.4f }, { 2.9f, 0.9f }, { 0.1f, 0.1f } };
        const NSUInteger n = sizeof co / sizeof co[0];
        id<MTLBuffer> C = buffer(co, sizeof co, shared), O = buffer(NULL, n * 2 * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:axesP];
            [enc setTexture:t atIndex:0]; [enc setSamplerState:smp atIndex:0];
            [enc setBuffer:C offset:0 atIndex:0]; [enc setBuffer:O offset:0 atIndex:1];
            [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(n, 1, 1)];
        });
        const float *o = O.contents;
        NSUInteger bad = 0;
        for (NSUInteger i = 0; i < n; i++) {
            float u = co[i][0] - floorf(co[i][0]), v = co[i][1];
            float want = v < 0 || v >= 1 ? 0 : px[MIN((int)(v * 4), 3) * 4 + MIN((int)(u * 4), 3)];
            if (o[2 * i] != want || o[2 * i + 1] != want) bad++;
        }
        CHECK(off ? o[0] == 0 : bad == 0, "per-axis addressing (repeat x clamp-to-zero), argument and constexpr samplers: %lu wrong",
              (unsigned long)bad);
    }
    {   // B4: an explicit level on a mipmapped texture is refused (no-op); on a single level it reads level 0
        float lod = 1.0f, px[16];
        for (int i = 0; i < 16; i++) px[i] = 3.0f;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:4 mipmapped:YES];
        id<MTLTexture> mip = [gDev newTextureWithDescriptor:d], flat = texture(MTLPixelFormatR32Float, 4, 4);
        [mip replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
        [flat replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
        float init[2] = { 7.0f, 7.0f };
        id<MTLBuffer> O = buffer(init, sizeof init, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:levelP];
            [enc setBytes:&lod length:4 atIndex:1];
            [enc setTexture:mip atIndex:0]; [enc setBuffer:O offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [enc setTexture:flat atIndex:0]; [enc setBuffer:O offset:4 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        });
        const float *o = O.contents;
        CHECK(off ? o[0] == 7 && o[1] == 7 : o[0] == 7.0f && o[1] == 3.0f, "level(1): mipmapped texture refused (%.0f), single level reads level 0 (%.0f)",
              o[0], o[1]);
    }
    {   // C1: 600 dispatches with their own setBytes in one command buffer (several inline chunks)
        const NSUInteger D = 600;
        id<MTLBuffer> O = buffer(NULL, D * 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            [enc setComputePipelineState:storeP];
            [enc setBuffer:O offset:0 atIndex:0];
            for (uint32_t i = 0; i < D; i++) {
                uint32_t p[2] = { i, i * 3 + 1 };
                [enc setBytes:p length:sizeof p atIndex:1];
                [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            }
        });
        const uint32_t *o = O.contents;
        NSUInteger bad = 0;
        for (uint32_t i = 0; i < D; i++) if (o[i] != i * 3 + 1) bad++;
        CHECK(off ? o[0] == 0 : bad == 0, "setBytes on %lu dispatches of one command buffer: %lu wrong", (unsigned long)D, (unsigned long)bad);
    }
    {   // D2 + C4: a kernel writes the indirect arguments of the next dispatch in the same run; 1000x3 threads exactly
        uint32_t zero3[3] = { 0, 0, 0 };
        id<MTLBuffer> IND = buffer(zero3, sizeof zero3, shared), N1 = buffer(NULL, 4, shared), N2 = buffer(NULL, 4, shared);
        run(^(id<MTLComputeCommandEncoder> enc) {
            uint32_t groups = 5;
            [enc setComputePipelineState:indP];
            [enc setBuffer:IND offset:0 atIndex:0]; [enc setBytes:&groups length:4 atIndex:1];
            [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [enc setComputePipelineState:countP];
            [enc setBuffer:N1 offset:0 atIndex:0];
            [enc dispatchThreadgroupsWithIndirectBuffer:IND indirectBufferOffset:0 threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [enc setBuffer:N2 offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(1000, 3, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
        });
        uint32_t n1 = *(uint32_t *)N1.contents, n2 = *(uint32_t *)N2.contents;
        CHECK(off ? n1 == 0 : n1 == 320 && n2 == 3000, "indirect arguments from a kernel of the same run: %u threads (320); 1000x3 grid: %u threads",
              n1, n2);
    }
    {   // D1 + D3: kernel writes the first half of a shared buffer; before it completes the CPU writes the second
        // half and a second command buffer copies the whole buffer (kernel) and blits it; both halves arrive
        const NSUInteger N = 8192;
        float *a = malloc(N * 4);
        for (NSUInteger i = 0; i < N; i++) a[i] = (float)i;
        id<MTLBuffer> A = buffer(a, N * 4, shared), Z = buffer(NULL, 2 * N * 4, shared), C = buffer(NULL, 2 * N * 4, shared),
                      E = buffer(NULL, 2 * N * 4, shared), F = buffer(NULL, 2 * N * 4, shared);
        id<MTLCommandBuffer> cb1 = [gQueue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb1 computeCommandEncoder];
        [enc setComputePipelineState:P[@"vadd"]];
        [enc setBuffer:A offset:0 atIndex:0]; [enc setBuffer:A offset:0 atIndex:1]; [enc setBuffer:C offset:0 atIndex:2];
        [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [enc endEncoding];
        [cb1 commit];
        float *c = C.contents;
        for (NSUInteger i = N; i < 2 * N; i++) c[i] = -(float)i;
        id<MTLCommandBuffer> cb2 = [gQueue commandBuffer];
        enc = [cb2 computeCommandEncoder];
        [enc setComputePipelineState:P[@"vadd"]];
        [enc setBuffer:C offset:0 atIndex:0]; [enc setBuffer:Z offset:0 atIndex:1]; [enc setBuffer:E offset:0 atIndex:2];
        [enc dispatchThreads:MTLSizeMake(2 * N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb2 blitCommandEncoder];
        [blit copyFromBuffer:E sourceOffset:0 toBuffer:F destinationOffset:0 size:2 * N * 4];
        [blit endEncoding];
        [cb2 commit];
        [cb2 waitUntilCompleted];
        const float *ef[2] = { E.contents, F.contents };
        NSUInteger bad = 0;
        for (int b = 0; b < 2; b++) {
            for (NSUInteger i = 0; i < N; i++) if (ef[b][i] != 2.0f * i) bad++;
            for (NSUInteger i = N; i < 2 * N; i++) if (ef[b][i] != -(float)i) bad++;
        }
        for (NSUInteger i = N; i < 2 * N; i++) if (c[i] != -(float)i) bad++;
        CHECK(off ? ef[0][N] == 0 : bad == 0, "GPU half + CPU half of a buffer, next command buffer before completion, then blit: %lu wrong",
              (unsigned long)bad);
        free(a);
    }

    if (!off) {
        printf("-- cost (vadd 4096 floats, buffers already shared with OpenCL)\n");
        const NSUInteger N = 4096;
        id<MTLBuffer> A = buffer(NULL, N * 4, MTLResourceStorageModePrivate), C = buffer(NULL, N * 4, MTLResourceStorageModePrivate);
        for (NSNumber *dn in @[@1, @8, @64]) {
            NSUInteger D = dn.unsignedIntegerValue;
            Encode enc8 = ^(id<MTLComputeCommandEncoder> enc) {
                [enc setComputePipelineState:P[@"vadd"]];
                [enc setBuffer:A offset:0 atIndex:0]; [enc setBuffer:A offset:0 atIndex:1]; [enc setBuffer:C offset:0 atIndex:2];
                for (NSUInteger i = 0; i < D; i++) [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            };
            run(enc8);
            double s = now_ms();
            const int R = 50;
            for (int r = 0; r < R; r++) run(enc8);
            double ms = (now_ms() - s) / R;
            printf("        %3lu dispatches per command buffer: %.3f ms per command buffer (commit to completion), %.3f ms per dispatch\n",
                   (unsigned long)D, ms, ms / D);
        }
    }
    printf("\n%s (%d checks)\n", gFails ? "ctest: FAILURES" : off ? "ctest (off): all ok" : "ctest: all ok", gChecks);
    return gFails ? 1 : 0;
} }
