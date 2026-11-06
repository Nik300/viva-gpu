// Draw bounds (vmg_bounds.c, P4/P5): small quads drawn the ways CoreAnimation draws them (a matrix in a constant
// buffer times a vertex attribute, as fixed_vert_lph_spc; corners chosen by vertex_id from a storage buffer, as
// path_blit_vert_lph; indexed strips; an off-screen and a partly off-screen quad) and a first-draw constant clear, on
// our device and on the Mac's GPU. The two images must match: a wrong box cuts pixels. Run with VMG_DRAW_BOUNDS=1 on
// llvmpipe (Panfrost has it on by default); VMG_TRACE_DRAW=1 shows each draw's box.
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

id<MTLDevice> TSMtlCreateDevice(void);

enum { W = 200, H = 120 };

static NSString *const kMSL = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct VIn { float4 pos [[attribute(0)]]; float4 col [[attribute(1)]]; };\n"
    "struct VOut { float4 pos [[position]]; float4 col; };\n"
    "struct M { float4x4 m; };\n"
    "vertex VOut mat_vert(VIn v [[stage_in]], constant M &u [[buffer(2)]]) { VOut o; o.pos = u.m * v.pos; o.col = v.col; return o; }\n"
    "struct Rect { float4 x; float4 y; float4 t; };\n"
    "vertex VOut id_vert(uint v [[vertex_id]], device const Rect &r [[buffer(2)]], device const float2 *c [[buffer(1)]]) {\n"
    "  float a = (v & 1) ? c[1].x : c[0].x, b = (v & 2) ? c[1].y : c[0].y;\n"
    "  VOut o; o.pos = float4(a * r.x.x + b * r.y.x + r.t.x, a * r.x.y + b * r.y.y + r.t.y, 0, 1); o.col = float4(0.2, 0.8, 0.3, 1); return o; }\n"
    "fragment float4 col_frag(VOut i [[stage_in]]) { return i.col; }\n"
    "struct Two { float4 c0 [[color(0)]]; };\n"
    "fragment Two clear_frag() { Two o; o.c0 = float4(0.1, 0.2, 0.3, 1); return o; }\n";

static uint8_t *render(id<MTLDevice> dev)
{
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kMSL options:nil error:&err];
    if (!lib) { fprintf(stderr, "library: %s\n", err.localizedDescription.UTF8String); exit(1); }
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat4; vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = 32;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.vertexFunction = [lib newFunctionWithName:@"mat_vert"];
    pd.fragmentFunction = [lib newFunctionWithName:@"col_frag"];
    pd.vertexDescriptor = vd;
    id<MTLRenderPipelineState> mat = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    pd.vertexDescriptor = nil;
    pd.vertexFunction = [lib newFunctionWithName:@"id_vert"];
    id<MTLRenderPipelineState> idp = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    pd.colorAttachments[0].blendingEnabled = NO;
    pd.fragmentFunction = [lib newFunctionWithName:@"clear_frag"];
    id<MTLRenderPipelineState> clr = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!mat || !idp || !clr) { fprintf(stderr, "pipeline: %s\n", err.localizedDescription.UTF8String); exit(1); }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;   // the first draw clears (P5)
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    // Full-screen constant clear (vertex_id corners over the whole NDC square).
    struct { float x[4], y[4], t[4]; } full = { { 2, 0, 0, 0 }, { 0, 2, 0, 0 }, { -1, -1, 0, 0 } };
    float corners[4] = { 0, 0, 1, 1 };
    [e setRenderPipelineState:clr];
    [e setVertexBytes:&full length:sizeof full atIndex:2];
    [e setVertexBytes:corners length:sizeof corners atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    // Quads in pixel units through a matrix (pixels -> NDC, y down), 6 vertices each.
    float m[16] = { 2.0f / W, 0, 0, 0, 0, -2.0f / H, 0, 0, 0, 0, 1, 0, -1, 1, 0, 1 };
    [e setRenderPipelineState:mat];
    [e setVertexBytes:m length:sizeof m atIndex:2];
    srand(7);
    for (int k = 0; k < 24; k++) {
        float x = (float)(rand() % (W + 40)) - 20, y = (float)(rand() % (H + 40)) - 20;
        float w = 3 + rand() % 40, h = 3 + rand() % 30;
        if (k == 5) { x = W + 50; y = 10; }             // entirely off screen
        float r = (rand() % 100) / 100.0f, g = (rand() % 100) / 100.0f, a = 0.4f + (rand() % 60) / 100.0f;
        float v[6][8], px[6][2] = { { x, y }, { x + w, y }, { x, y + h }, { x + w, y }, { x + w, y + h }, { x, y + h } };
        for (int i = 0; i < 6; i++) { v[i][0] = px[i][0] + 0.37f; v[i][1] = px[i][1] + 0.61f; v[i][2] = 0; v[i][3] = 1;
                                      v[i][4] = r * a; v[i][5] = g * a; v[i][6] = 0.3f * a; v[i][7] = a; }
        [e setVertexBytes:v length:sizeof v atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }
    // vertex_id quads (path_blit style), strips, one indexed.
    [e setRenderPipelineState:idp];
    for (int k = 0; k < 6; k++) {
        struct { float x[4], y[4], t[4]; } r = { { 0.3f, 0.05f * k, 0, 0 }, { -0.02f * k, 0.25f, 0, 0 }, { -0.9f + 0.3f * k, -0.6f + 0.1f * k, 0, 0 } };
        float c[4] = { 0, 0, 1, 1 };
        [e setVertexBytes:&r length:sizeof r atIndex:2];
        [e setVertexBytes:c length:sizeof c atIndex:1];
        if (k == 3) {
            uint16_t idx[4] = { 0, 1, 2, 3 };
            id<MTLBuffer> ib = [dev newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
            [e drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip indexCount:4 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
        } else [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint8_t *px = malloc(W * H * 4);
    [tex getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    return px;
}

int main(void) { @autoreleasepool {
    uint8_t *ours = render(TSMtlCreateDevice()), *ref = render(MTLCreateSystemDefaultDevice());
    unsigned bad = 0, maxd = 0;
    for (unsigned i = 0; i < W * H * 4; i++) {
        unsigned d = abs((int)ours[i] - (int)ref[i]);
        maxd = d > maxd ? d : maxd;
        bad += d > 2;
    }
    printf("bounds: %u of %u channels differ by more than 2 (max %u): %s\n", bad, W * H * 4, maxd, bad ? "FAIL" : "ok");
    FILE *f = fopen("/tmp/vmg-bounds.raw", "wb");
    if (f) { fwrite(ours, 1, W * H * 4, f); fclose(f); }
    return bad ? 1 : 0;
} }
