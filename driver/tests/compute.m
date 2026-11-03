// Compute on the Viva Metal driver: buffers, threadgroup memory + barriers, atomics, texture writes, dispatchThreads
// (non-uniform grid), threadgroup arguments, setBytes. Runs on llvmpipe on the Mac.
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

id<MTLDevice> TSMtlCreateDevice(void);

static int failures, checks;
#define CHECK(c, ...) do { checks++; if (c) printf("  ok   "); else { failures++; printf("  FAIL "); } printf(__VA_ARGS__); printf("\n"); } while (0)

static NSString *const kMSL = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void square(device float *a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a[i] = a[i] * a[i]; }\n"
    "kernel void reverse_group(device uint *a [[buffer(0)]], uint l [[thread_position_in_threadgroup]],\n"
    "                          uint g [[threadgroup_position_in_grid]], uint n [[threads_per_threadgroup]]) {\n"
    "  threadgroup uint tmp[64];\n"
    "  tmp[l] = a[g * n + l];\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  a[g * n + l] = tmp[n - 1 - l]; }\n"
    "kernel void histogram(device const uint *in [[buffer(0)]], device atomic_uint *bins [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "  atomic_fetch_add_explicit(&bins[in[i] & 3], 1, memory_order_relaxed); }\n"
    "kernel void fill_tex(texture2d<float, access::write> t [[texture(0)]], constant float4 &c [[buffer(0)]],\n"
    "                     uint2 p [[thread_position_in_grid]]) { t.write(c * float(p.x + p.y), p); }\n"
    "kernel void read_tex(texture2d<float> t [[texture(0)]], device float4 *out [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  out[p.y * 4 + p.x] = t.read(p); }\n"
    "kernel void grid_size(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]], uint n [[threads_per_grid]]) { out[i] = n; }\n"
    "kernel void tg_arg(device uint *a [[buffer(0)]], threadgroup uint *s [[threadgroup(0)]], uint l [[thread_position_in_threadgroup]]) {\n"
    "  s[l] = l * 3; threadgroup_barrier(mem_flags::mem_threadgroup); a[l] = s[(l + 1) % 32]; }\n";

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> lib;

static id<MTLComputePipelineState> kpipe(NSString *name) {
    NSError *e = nil;
    id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:name] error:&e];
    return p;
}

static void run(void (^body)(id<MTLComputeCommandEncoder>)) {
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    body(e);
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

int main(void) { @autoreleasepool {
    dev = TSMtlCreateDevice();
    queue = [dev newCommandQueue];
    NSError *err = nil;
    lib = [dev newLibraryWithSource:kMSL options:nil error:&err];
    if (!lib) { printf("library: %s\n", err.description.UTF8String); return 1; }

    printf("buffers\n");
    float v[256];
    for (int i = 0; i < 256; i++) v[i] = (float)i;
    id<MTLBuffer> b = [dev newBufferWithBytes:v length:sizeof v options:MTLResourceStorageModeShared];
    id<MTLComputePipelineState> sq = kpipe(@"square");
    CHECK(sq.threadExecutionWidth > 0 && sq.maxTotalThreadsPerThreadgroup >= 64, "pipeline limits (simd %lu, max %lu)",
          (unsigned long)sq.threadExecutionWidth, (unsigned long)sq.maxTotalThreadsPerThreadgroup);
    run(^(id<MTLComputeCommandEncoder> e) {
        [e setComputePipelineState:sq];
        [e setBuffer:b offset:0 atIndex:0];
        [e dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    });
    float *r = b.contents;
    CHECK(r[3] == 9 && r[255] == 255.0f * 255.0f, "a[i] = a[i]^2 (%g %g)", r[3], r[255]);

    printf("threadgroup memory + barrier\n");
    uint32_t u[128];
    for (int i = 0; i < 128; i++) u[i] = (uint32_t)i;
    id<MTLBuffer> ub = [dev newBufferWithBytes:u length:sizeof u options:0];
    run(^(id<MTLComputeCommandEncoder> e) {
        [e setComputePipelineState:kpipe(@"reverse_group")];
        [e setBuffer:ub offset:0 atIndex:0];
        [e dispatchThreadgroups:MTLSizeMake(2, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    });
    uint32_t *ur = ub.contents;
    CHECK(ur[0] == 63 && ur[63] == 0 && ur[64] == 127 && ur[127] == 64, "groups reversed (%u %u %u %u)", ur[0], ur[63], ur[64], ur[127]);

    printf("atomics\n");
    uint32_t in[1000];
    for (int i = 0; i < 1000; i++) in[i] = (uint32_t)i;
    id<MTLBuffer> ib = [dev newBufferWithBytes:in length:sizeof in options:0];
    id<MTLBuffer> bins = [dev newBufferWithLength:16 options:0];
    memset(bins.contents, 0, 16);
    run(^(id<MTLComputeCommandEncoder> e) {
        [e setComputePipelineState:kpipe(@"histogram")];
        [e setBuffer:ib offset:0 atIndex:0];
        [e setBuffer:bins offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(1000, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    });
    uint32_t *h = bins.contents;
    CHECK(h[0] == 250 && h[1] == 250 && h[2] == 250 && h[3] == 250, "histogram of 1000 values, non-uniform grid (%u %u %u %u)", h[0], h[1], h[2], h[3]);

    printf("texture write + setBytes\n");
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:8 height:8 mipmapped:NO];
    td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    run(^(id<MTLComputeCommandEncoder> e) {
        float c[4] = { 1, 2, 3, 4 };
        [e setComputePipelineState:kpipe(@"fill_tex")];
        [e setTexture:t atIndex:0];
        [e setBytes:c length:sizeof c atIndex:0];
        [e dispatchThreadgroups:MTLSizeMake(2, 2, 1) threadsPerThreadgroup:MTLSizeMake(4, 4, 1)];
    });
    float px[4] = {0};
    [t getBytes:px bytesPerRow:8 * 16 fromRegion:MTLRegionMake2D(3, 2, 1, 1) mipmapLevel:0];
    CHECK(px[0] == 5 && px[3] == 20, "texel (3,2) = c * 5 (%g %g %g %g)", px[0], px[1], px[2], px[3]);

    // CoreAnimation's images, glyphs and gradients: a linear texture over a CPU-filled buffer (not aliased on Panfrost).
    id<MTLBuffer> lb = [dev newBufferWithLength:256 * 4 options:0];
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) ((uint32_t *)lb.contents)[y * 64 + x] = 0xff000000u | (uint32_t)(y * 16 + x);
    MTLTextureDescriptor *ld = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    ld.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> lt = [lb newTextureWithDescriptor:ld offset:0 bytesPerRow:256];
    id<MTLBuffer> lo = [dev newBufferWithLength:16 * 16 options:0];
    run(^(id<MTLComputeCommandEncoder> e) {
        [e setComputePipelineState:kpipe(@"read_tex")];
        [e setTexture:lt atIndex:0];
        [e setBuffer:lo offset:0 atIndex:0];
        [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(4, 4, 1)];
    });
    float *lr = lo.contents;
    CHECK(fabsf(lr[(2 * 4 + 3) * 4] * 255 - 35) < 0.5f && lr[(2 * 4 + 3) * 4 + 3] == 1,
          "linear texture over a buffer: texel (3,2) (%g %g)", lr[(2 * 4 + 3) * 4] * 255, lr[(2 * 4 + 3) * 4 + 3]);

    printf("grid size and threadgroup arguments\n");
    id<MTLBuffer> gb = [dev newBufferWithLength:4 * 100 options:0];
    run(^(id<MTLComputeCommandEncoder> e) {
        [e setComputePipelineState:kpipe(@"grid_size")];
        [e setBuffer:gb offset:0 atIndex:0];
        [e dispatchThreads:MTLSizeMake(100, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    });
    CHECK(((uint32_t *)gb.contents)[99] == 100, "threads_per_grid with dispatchThreads (%u)", ((uint32_t *)gb.contents)[99]);
    id<MTLBuffer> tb = [dev newBufferWithLength:4 * 32 options:0];
    run(^(id<MTLComputeCommandEncoder> e) {
        [e setComputePipelineState:kpipe(@"tg_arg")];
        [e setBuffer:tb offset:0 atIndex:0];
        [e setThreadgroupMemoryLength:32 * 4 atIndex:0];
        [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    });
    uint32_t *tr = tb.contents;
    CHECK(tr[0] == 3 && tr[31] == 0, "[[threadgroup(0)]] sized by the encoder (%u %u)", tr[0], tr[31]);

    printf("%d/%d checks passed\n", checks - failures, checks);
    return failures != 0;
} }
