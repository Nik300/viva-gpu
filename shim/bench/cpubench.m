// CPU-side benchmark of the Metal -> GL command translation (the shim's own overhead).
// Scenario "ui":     1 pass, many small draws with egui-like state changes.
// Scenario "passes": many render passes with few draws (post-processing / shadow chains).
// Scenario "bigcb":  draws whose vertex shader reads `constant T *` of unknown size.
// Reports encode cost (app thread) and execute cost (GPU queue: commit -> completed).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <mach/mach_time.h>
#import "TSMetal.h"

static double nowUs(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e3; }

static NSString *const kMSL = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct VIn { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; uchar4 color [[attribute(2)]]; };\n"
    "struct VOut { float4 pos [[position]]; float2 uv [[user(loc0)]]; float4 color [[user(loc1)]]; };\n"
    "struct U { float2 screen; float2 pad; };\n"
    "vertex VOut vs_ui(VIn in [[stage_in]], constant U &u [[buffer(1)]]) {\n"
    "  VOut o; o.pos = float4(in.pos / u.screen * 2 - 1, 0, 1); o.uv = in.uv; o.color = float4(in.color) / 255; return o; }\n"
    "fragment float4 fs_ui(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return in.color * t.sample(s, in.uv); }\n"
    "fragment float4 fs_ui2(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return in.color * t.sample(s, in.uv).r; }\n"
    "struct Inst { float4 offset; };\n"
    "vertex VOut vs_ptr(VIn in [[stage_in]], constant Inst *inst [[buffer(1)]], uint iid [[instance_id]]) {\n"
    "  VOut o; o.pos = float4(in.pos + inst[iid].offset.xy, 0, 1); o.uv = in.uv; o.color = 1; return o; }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *only = argc > 1 ? argv[1] : NULL;
    id<MTLDevice> dev = TSMtlCreateDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kMSL options:nil error:&e];
    if (!lib) { fprintf(stderr, "%s\n", e.description.UTF8String); return 1; }
    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[1].format = MTLVertexFormatFloat2; vd.attributes[1].offset = 8;
    vd.attributes[2].format = MTLVertexFormatUChar4; vd.attributes[2].offset = 16;
    vd.layouts[0].stride = 20;
    id<MTLRenderPipelineState> (^pipe)(NSString *, NSString *, BOOL) = ^(NSString *vs, NSString *fs, BOOL blend) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:vs];
        d.fragmentFunction = [lib newFunctionWithName:fs];
        d.vertexDescriptor = vd;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        d.colorAttachments[0].blendingEnabled = blend;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        double t0 = nowUs();
        NSError *err = nil;
        id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        printf("  pipeline %s/%s%s: %.1f ms\n", vs.UTF8String, fs.UTF8String, blend ? " (blend)" : "", (nowUs() - t0) / 1e3);
        return p;
    };
    printf("pipeline creation (translate + compile + link, in-memory cache only):\n");
    id<MTLRenderPipelineState> p1 = pipe(@"vs_ui", @"fs_ui", YES), p2 = pipe(@"vs_ui", @"fs_ui2", YES), p3 = pipe(@"vs_ui", @"fs_ui", NO);
    id<MTLRenderPipelineState> pp = pipe(@"vs_ptr", @"fs_ui", YES);
    (void)p3;

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:256 height:256 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t1 = [dev newTextureWithDescriptor:td], t2 = [dev newTextureWithDescriptor:td];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
    // Shared vertex buffer: 2000 quads x 6 vertices x 20 bytes = 240 KB, rewritten by the CPU every frame (like egui).
    const int D = 2000;
    id<MTLBuffer> vb = [dev newBufferWithLength:D * 6 * 20 options:MTLResourceStorageModeShared];
    id<MTLBuffer> inst = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    float screen[4] = { 256, 256, 0, 0 };
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = rt;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;

    // ---- ui: per draw setPipeline (every 10) + setVertexBuffer offset + setVertexBytes + texture/sampler + scissor + draw
    if (!only || !strcmp(only, "ui")) {
        const int F = 200;
        double enc = 0, exec = 0, t0;
        for (int f = 0; f < F; f++) {
            memset(vb.contents, f & 0xff, vb.length);   // the app rewrites its vertices every frame
            t0 = nowUs();
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
            for (int d = 0; d < D; d++) {
                if (d % 10 == 0) [en setRenderPipelineState:(d / 10) & 1 ? p2 : p1];
                [en setVertexBuffer:vb offset:d * 120 atIndex:0];
                [en setVertexBytes:screen length:16 atIndex:1];
                [en setFragmentTexture:(d & 1) ? t1 : t2 atIndex:0];
                [en setFragmentSamplerState:smp atIndex:0];
                [en setScissorRect:(MTLScissorRect){ d % 200, d % 100, 50, 50 }];
                [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
            [en endEncoding];
            double t1 = nowUs(); enc += t1 - t0;
            [cb commit];
            [cb waitUntilCompleted];
            exec += nowUs() - t1;
        }
        printf("ui:     %d draws/frame   encode %.2f us/draw   execute %.2f us/draw   => %.0f draws/s single-threaded, %.1f ms/frame\n",
               D, enc / F / D, exec / F / D, 1e6 / ((enc + exec) / F / D), (enc + exec) / F / 1e3);
    }
    // ---- passes: 100 passes x 4 draws
    if (!only || !strcmp(only, "passes")) {
        const int F = 100, P = 100;
        double enc = 0, exec = 0, t0;
        for (int f = 0; f < F; f++) {
            t0 = nowUs();
            id<MTLCommandBuffer> cb = [q commandBuffer];
            for (int p = 0; p < P; p++) {
                id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
                [en setRenderPipelineState:p1];
                [en setVertexBuffer:vb offset:0 atIndex:0];
                [en setVertexBytes:screen length:16 atIndex:1];
                [en setFragmentTexture:t1 atIndex:0];
                [en setFragmentSamplerState:smp atIndex:0];
                for (int d = 0; d < 4; d++) [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                [en endEncoding];
            }
            double t1 = nowUs(); enc += t1 - t0;
            [cb commit];
            [cb waitUntilCompleted];
            exec += nowUs() - t1;
        }
        printf("passes: %d passes x 4 draws  encode %.2f us/pass   execute %.2f us/pass\n", P, enc / F / P, exec / F / P);
    }
    // ---- bigcb: constant Inst *inst (size unknown -> 64 KB uniform block) bound from a buffer
    if (!only || !strcmp(only, "bigcb")) {
        const int F = 100, N = 500;
        double enc = 0, exec = 0, t0;
        for (int f = 0; f < F; f++) {
            t0 = nowUs();
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
            [en setRenderPipelineState:pp];
            [en setFragmentTexture:t1 atIndex:0];
            [en setFragmentSamplerState:smp atIndex:0];
            [en setVertexBuffer:vb offset:0 atIndex:0];
            [en setVertexBuffer:inst offset:0 atIndex:1];
            for (int d = 0; d < N; d++) [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [en endEncoding];
            double t1 = nowUs(); enc += t1 - t0;
            [cb commit];
            [cb waitUntilCompleted];
            exec += nowUs() - t1;
        }
        printf("bigcb:  %d draws reading constant T* (64 KB block)  encode %.2f us/draw   execute %.2f us/draw\n", N, enc / F / N, exec / F / N);
    }
    // ---- uploads: small replaceRegion on a big texture; big shared buffer bound every frame
    if (!only || !strcmp(only, "uploads")) {
        MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2048 height:2048 mipmapped:NO];
        bd.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> atlas = [dev newTextureWithDescriptor:bd];
        uint32_t patch[64 * 64]; memset(patch, 0x7f, sizeof patch);
        id<MTLBuffer> big = [dev newBufferWithLength:16 << 20 options:MTLResourceStorageModeShared];
        const int F = 50;
        double tTex = 0, tBuf = 0, tNone = 0;
        for (int f = 0; f < F; f++) {
            for (int mode = 0; mode < 3; mode++) {
                if (mode == 0) [atlas replaceRegion:MTLRegionMake2D((f * 64) % 2048, 0, 64, 64) mipmapLevel:0 withBytes:patch bytesPerRow:256];
                double t0 = nowUs();
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
                [en setRenderPipelineState:p1];
                [en setVertexBuffer:(mode == 1 ? big : vb) offset:0 atIndex:0];
                [en setVertexBytes:screen length:16 atIndex:1];
                [en setFragmentTexture:(mode == 0 ? atlas : t1) atIndex:0];
                [en setFragmentSamplerState:smp atIndex:0];
                [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                [en endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                double dt = nowUs() - t0;
                if (mode == 0) tTex += dt; else if (mode == 1) tBuf += dt; else tNone += dt;
            }
        }
        printf("uploads: 1 draw after a 64x64 replaceRegion on a 2048^2 texture: %.2f ms/cb\n", tTex / F / 1e3);
        printf("uploads: 1 draw binding a 16 MB shared buffer (rewritten or not):  %.2f ms/cb\n", tBuf / F / 1e3);
        printf("uploads: 1 draw, nothing changed:                                  %.2f ms/cb\n", tNone / F / 1e3);
    }
    // ---- views: render into a view, then sample the parent (or the same object)
    if (!only || !strcmp(only, "views")) {
        MTLTextureDescriptor *vdsc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1024 height:1024 mipmapped:NO];
        vdsc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        id<MTLTexture> parent = [dev newTextureWithDescriptor:vdsc];
        id<MTLTexture> view = [parent newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm];
        const int F = 30;
        for (int mode = 0; mode < 2; mode++) {
            id<MTLTexture> target = mode ? view : parent;
            double t0 = nowUs();
            for (int f = 0; f < F; f++) {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                MTLRenderPassDescriptor *r1 = [MTLRenderPassDescriptor renderPassDescriptor];
                r1.colorAttachments[0].texture = target; r1.colorAttachments[0].loadAction = MTLLoadActionClear;
                r1.colorAttachments[0].clearColor = MTLClearColorMake(f & 1, 0, 0, 1);
                [[cb renderCommandEncoderWithDescriptor:r1] endEncoding];
                id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
                [en setRenderPipelineState:p1];
                [en setVertexBuffer:vb offset:0 atIndex:0];
                [en setVertexBytes:screen length:16 atIndex:1];
                [en setFragmentTexture:parent atIndex:0];
                [en setFragmentSamplerState:smp atIndex:0];
                [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                [en endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
            }
            printf("views: render to %s, then sample the parent: %.2f ms/frame\n", mode ? "a full-range VIEW" : "the texture itself", (nowUs() - t0) / F / 1e3);
        }
    }
    // ---- loop forever for profiling with `sample`
    if (only && !strcmp(only, "profile")) {
        for (;;) @autoreleasepool {
            memset(vb.contents, 1, vb.length);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
            for (int d = 0; d < D; d++) {
                if (d % 10 == 0) [en setRenderPipelineState:(d / 10) & 1 ? p2 : p1];
                [en setVertexBuffer:vb offset:d * 120 atIndex:0];
                [en setVertexBytes:screen length:16 atIndex:1];
                [en setFragmentTexture:(d & 1) ? t1 : t2 atIndex:0];
                [en setFragmentSamplerState:smp atIndex:0];
                [en setScissorRect:(MTLScissorRect){ d % 200, d % 100, 50, 50 }];
                [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
            [en endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
        }
    }
} return 0; }
