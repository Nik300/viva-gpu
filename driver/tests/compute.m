// Compute on the Viva Metal driver: buffers, threadgroup memory + barriers, atomics, texture writes, dispatchThreads
// (non-uniform grid), threadgroup arguments, setBytes. Runs on llvmpipe on the Mac.
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

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
    "  s[l] = l * 3; threadgroup_barrier(mem_flags::mem_threadgroup); a[l] = s[(l + 1) % 32]; }\n"
    // Programmable blending (framebuffer fetch), as CoreAnimation's fixed_frag_lph_cph on iOS: a clip mask in a
    // second, memoryless attachment, then a draw without blending that mixes the destination by the mask.
    "struct VOut { float4 pos [[position]]; };\n"
    "vertex VOut fs_quad(uint v [[vertex_id]]) { float2 p = float2((v << 1) & 2, v & 2); VOut o; o.pos = float4(p * 2 - 1, 0, 1); return o; }\n"
    "fragment half4 fetch_one(half4 dst [[color(0)]]) { return dst * half4(0.5h, 1, 1, 1) + half4(0, 0, 0.25h, 0); }\n"
    "struct Two { half4 c0 [[color(0)]]; half4 c1 [[color(1)]]; };\n"
    "fragment Two clip_write(VOut i [[stage_in]]) { Two o; o.c0 = 0; o.c1 = half4(i.pos.x < 4 ? 1.0h : 0.0h); return o; }\n"
    "fragment Two clip_write_all(VOut i [[stage_in]], half4 dst [[color(0)]]) { Two o; o.c0 = dst; o.c1 = half4(i.pos.x < 4 ? 1.0h : 0.0h); return o; }\n"
    "struct TwoF { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; };\n"
    "fragment TwoF mrt_plain() { TwoF o; o.c0 = float4(0, 1, 0, 1); o.c1 = float4(0, 0, 1, 1); return o; }\n"
    "fragment Two clip_apply(half4 dst [[color(0)]], half4 clip [[color(1)]]) {\n"
    "  Two o; o.c0 = mix(dst, half4(1, 0, 0, 1), clip.r); o.c1 = clip; return o; }\n";

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

    printf("framebuffer fetch\n");
    MTLTextureDescriptor *fd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:8 height:8 mipmapped:NO];
    fd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    fd.storageMode = MTLStorageModeShared;
    id<MTLTexture> c0 = [dev newTextureWithDescriptor:fd];
    fd.storageMode = MTLStorageModeMemoryless;
    __block id<MTLTexture> c1 = [dev newTextureWithDescriptor:fd];
    if (!c1) { fd.storageMode = MTLStorageModePrivate; c1 = [dev newTextureWithDescriptor:fd]; }
    id<MTLRenderPipelineState> (^rpipe)(NSString *, unsigned) = ^id<MTLRenderPipelineState>(NSString *fs, unsigned n) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"fs_quad"];
        d.fragmentFunction = [lib newFunctionWithName:fs];
        for (unsigned i = 0; i < n; i++) d.colorAttachments[i].pixelFormat = MTLPixelFormatBGRA8Unorm;
        if ([fs isEqualToString:@"clip_write"]) d.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
        NSError *e = nil;
        id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        if (!p) printf("  pipeline %s: %s\n", fs.UTF8String, e.description.UTF8String);
        return p;
    };
    void (^pass)(unsigned, NSArray *) = ^(unsigned n, NSArray *pipes) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = c0;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0.5, 0.5, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (n > 1) {
            rp.colorAttachments[1].texture = c1;
            rp.colorAttachments[1].loadAction = c1.storageMode == MTLStorageModeShared ? MTLLoadActionClear : MTLLoadActionDontCare;
            rp.colorAttachments[1].storeAction = c1.storageMode == MTLStorageModeShared ? MTLStoreActionStore : MTLStoreActionDontCare;
        }
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        for (id<MTLRenderPipelineState> p in pipes) {
            [e setRenderPipelineState:p];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [e endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
    };
    uint8_t fb[8 * 8 * 4];
    id<MTLRenderPipelineState> one = rpipe(@"fetch_one", 1);
    if (one) {
        pass(1, @[one]);
        [c0 getBytes:fb bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
        // BGRA: expect r 0.25 (64), g 0.5 (128), b 0.75 (191)
        CHECK(abs(fb[2] - 64) <= 2 && abs(fb[1] - 128) <= 2 && abs(fb[0] - 191) <= 2, "[[color(0)]] read (rgb %u %u %u)", fb[2], fb[1], fb[0]);
    }
    // VMG_FETCH_VARIANT: 1 = c1 private, stored and read back; 2 = also clip_write writes c0 (full mask)
    const char *fv = getenv("VMG_FETCH_VARIANT");
    int variant = fv ? atoi(fv) : 0;
    if (variant) { fd.storageMode = MTLStorageModeShared; c1 = [dev newTextureWithDescriptor:fd]; }
    // 3 = clip_write alone, 4 = plain MRT (float outputs, no fetch): c1 read back
    NSString *wn = variant == 2 ? @"clip_write_all" : variant == 4 ? @"mrt_plain" : @"clip_write";
    id<MTLRenderPipelineState> w = rpipe(wn, 2), a = rpipe(@"clip_apply", 2);
    if (variant >= 3 && w) {
        pass(2, @[w]);
        uint8_t m[8 * 8 * 4];
        [c1 getBytes:m bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
        [c0 getBytes:fb bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
        printf("  variant %d: c0 (%u %u %u %u) c1 x1 (%u %u %u %u) x6 (%u %u %u %u)\n", variant, fb[2], fb[1], fb[0], fb[3],
               m[(2 * 8 + 1) * 4 + 2], m[(2 * 8 + 1) * 4 + 1], m[(2 * 8 + 1) * 4], m[(2 * 8 + 1) * 4 + 3],
               m[(2 * 8 + 6) * 4 + 2], m[(2 * 8 + 6) * 4 + 1], m[(2 * 8 + 6) * 4], m[(2 * 8 + 6) * 4 + 3]);
        w = nil;
    }
    if (w && a) {
        pass(2, @[w, a]);
        [c0 getBytes:fb bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
        const uint8_t *in = fb + (2 * 8 + 1) * 4, *out = fb + (2 * 8 + 6) * 4;   // x 1: clipped in, x 6: out
        CHECK(in[2] == 255 && in[1] == 0 && abs(out[2] - 128) <= 2 && abs(out[1] - 128) <= 2,
              "clip mask in [[color(1)]], mix with [[color(0)]] (in %u %u %u, out %u %u %u)", in[2], in[1], in[0], out[2], out[1], out[0]);
        if (c1.storageMode == MTLStorageModeShared) {
            uint8_t m[8 * 8 * 4];
            [c1 getBytes:m bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
            printf("  c1 after the pass: x1 %u, x6 %u\n", m[(2 * 8 + 1) * 4], m[(2 * 8 + 6) * 4]);
        }
    }

    printf("%d/%d checks passed\n", checks - failures, checks);
    return failures != 0;
} }
