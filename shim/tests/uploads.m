// Phase 3b execution test for incremental uploads and aliased views (B6, B7) and the render-pass framebuffer
// cache (B6 of docs/OTTIMIZZAZIONE-AIR.md): after each partial CPU or blit write, what the GPU samples must equal
// the CPU contents.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import "TSMetal.h"

static int failures, checks;
#define CHECK(cond, ...) do { checks++; if (cond) printf("  ok   "); else { failures++; printf("  FAIL "); } \
    printf(__VA_ARGS__); printf("\n"); } while (0)

static NSString *const kMSL = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct VO { float4 pos [[position]]; };\n"
    "vertex VO fullscreen(uint vid [[vertex_id]]) { float2 p = float2((vid << 1) & 2, vid & 2); VO o; o.pos = float4(p * 2 - 1, 0, 1); return o; }\n"
    "fragment float4 copy0(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) { return t.read(uint2(in.pos.xy)); }\n"
    "fragment float4 copy1(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) { return t.read(uint2(in.pos.xy) / 2, 1); }\n"
    "fragment float4 halves(VO in [[stage_in]], constant float4 *c [[buffer(0)]]) { return c[int(in.pos.x) / 32]; }\n";

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> lib;
enum { N = 64 };

static id<MTLRenderPipelineState> pipeline(NSString *fs) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"fullscreen"];
    d.fragmentFunction = [lib newFunctionWithName:fs];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    return [dev newRenderPipelineStateWithDescriptor:d error:nil];
}

static id<MTLTexture> texture(NSUInteger mips, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:N height:N mipmapped:mips > 1];
    d.mipmapLevelCount = mips;
    d.usage = usage;
    return [dev newTextureWithDescriptor:d];
}

static void draw(id<MTLTexture> target, id<MTLRenderPipelineState> p, id<MTLTexture> tex, id<MTLBuffer> buf) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:p];
    if (tex) [e setFragmentTexture:tex atIndex:0];
    if (buf) [e setFragmentBuffer:buf offset:0 atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

static void clearTo(id<MTLTexture> target, MTLClearColor c) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = c;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

static uint32_t px(id<MTLTexture> t, NSUInteger x, NSUInteger y) {
    uint32_t p = 0;
    [t getBytes:&p bytesPerRow:4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
    return p;
}

static void fill(id<MTLTexture> t, MTLRegion r, uint32_t color) {
    uint32_t *p = malloc(r.size.width * r.size.height * 4);
    for (NSUInteger i = 0; i < r.size.width * r.size.height; i++) p[i] = color;
    [t replaceRegion:r mipmapLevel:0 withBytes:p bytesPerRow:r.size.width * 4];
    free(p);
}

int main(void) { @autoreleasepool {
    dev = TSMtlCreateDevice();
    queue = [dev newCommandQueue];
    NSError *e = nil;
    lib = [dev newLibraryWithSource:kMSL options:nil error:&e];
    if (!lib) { printf("%s\n", e.description.UTF8String); return 1; }
    id<MTLRenderPipelineState> copy0 = pipeline(@"copy0"), copy1 = pipeline(@"copy1"), halves = pipeline(@"halves");
    id<MTLTexture> rt = texture(1, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    const uint32_t red = 0xff0000ff, green = 0xff00ff00, blue = 0xffff0000, yellow = 0xff00ffff, cyan = 0xffffff00;

    printf("texture region uploads\n");
    id<MTLTexture> t = texture(1, MTLTextureUsageShaderRead);
    fill(t, MTLRegionMake2D(0, 0, N, N), red);
    draw(rt, copy0, t, nil);
    CHECK(px(rt, 5, 5) == red, "full replaceRegion sampled (0x%08x)", px(rt, 5, 5));
    fill(t, MTLRegionMake2D(8, 8, 16, 16), green);
    draw(rt, copy0, t, nil);
    CHECK(px(rt, 10, 10) == green && px(rt, 0, 0) == red && px(rt, 30, 30) == red && px(rt, 23, 8) == green && px(rt, 24, 8) == red,
          "partial replaceRegion: inside green, outside red (0x%08x 0x%08x 0x%08x)", px(rt, 10, 10), px(rt, 0, 0), px(rt, 24, 8));
    id<MTLBuffer> staging = [dev newBufferWithLength:8 * 8 * 4 options:MTLResourceStorageModeShared];
    for (int i = 0; i < 64; i++) ((uint32_t *)staging.contents)[i] = blue;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:32 sourceBytesPerImage:256 sourceSize:MTLSizeMake(8, 8, 1)
            toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(40, 40, 0)];
    [b endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    fill(t, MTLRegionMake2D(60, 0, 4, 4), yellow);
    draw(rt, copy0, t, nil);
    CHECK(px(rt, 41, 41) == blue && px(rt, 61, 1) == yellow && px(rt, 10, 10) == green && px(rt, 50, 50) == red,
          "blit + replaceRegion in one catch-up (0x%08x 0x%08x 0x%08x 0x%08x)", px(rt, 41, 41), px(rt, 61, 1), px(rt, 10, 10), px(rt, 50, 50));
    for (int i = 0; i < 20; i++) fill(t, MTLRegionMake2D(i * 3, 62, 2, 2), cyan);   // more regions than the list keeps
    draw(rt, copy0, t, nil);
    CHECK(px(rt, 57, 63) == cyan && px(rt, 41, 41) == blue && px(rt, 2, 30) == red, "region list overflow falls back to a full upload");

    printf("buffer ranges\n");
    simd_float4 cols[2] = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 } };
    id<MTLBuffer> src = [dev newBufferWithBytes:cols length:sizeof cols options:MTLResourceStorageModeShared];
    id<MTLBuffer> priv = [dev newBufferWithLength:sizeof cols options:MTLResourceStorageModePrivate];
    cb = [queue commandBuffer];
    b = [cb blitCommandEncoder];
    [b copyFromBuffer:src sourceOffset:0 toBuffer:priv destinationOffset:0 size:sizeof cols];
    [b endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    draw(rt, halves, nil, priv);
    CHECK(px(rt, 5, 5) == red && px(rt, 40, 5) == green, "private buffer filled by a blit (0x%08x 0x%08x)", px(rt, 5, 5), px(rt, 40, 5));
    ((simd_float4 *)src.contents)[1] = (simd_float4){ 0, 0, 1, 1 };
    cb = [queue commandBuffer];
    b = [cb blitCommandEncoder];
    [b copyFromBuffer:src sourceOffset:16 toBuffer:priv destinationOffset:16 size:16];
    [b endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    draw(rt, halves, nil, priv);
    CHECK(px(rt, 5, 5) == red && px(rt, 40, 5) == blue, "partial blit into a private buffer (0x%08x 0x%08x)", px(rt, 5, 5), px(rt, 40, 5));
    id<MTLBuffer> managed = [dev newBufferWithBytes:cols length:sizeof cols options:MTLResourceStorageModeManaged];
    draw(rt, halves, nil, managed);
    ((simd_float4 *)managed.contents)[0] = (simd_float4){ 1, 1, 0, 1 };
    [managed didModifyRange:NSMakeRange(0, 16)];
    draw(rt, halves, nil, managed);
    CHECK(px(rt, 5, 5) == yellow && px(rt, 40, 5) == green, "managed buffer: didModifyRange (0x%08x 0x%08x)", px(rt, 5, 5), px(rt, 40, 5));
    ((simd_float4 *)src.contents)[0] = (simd_float4){ 0, 1, 1, 1 };
    draw(rt, halves, nil, src);
    CHECK(px(rt, 5, 5) == cyan, "shared buffer: CPU write without notification is seen (0x%08x)", px(rt, 5, 5));

    // Large shared buffers are uploaded block by block (only what changed since the last upload).
    id<MTLBuffer> big = [dev newBufferWithLength:256 << 10 options:MTLResourceStorageModeShared];
    NSUInteger at = 200 << 10;
    void (^drawBig)(void) = ^{
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        id<MTLCommandBuffer> c = [queue commandBuffer];
        id<MTLRenderCommandEncoder> e = [c renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:halves];
        [e setFragmentBuffer:big offset:at atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        [c commit];
        [c waitUntilCompleted];
    };
    simd_float4 *bc = (simd_float4 *)((uint8_t *)big.contents + at);
    bc[0] = (simd_float4){ 1, 0, 0, 1 }; bc[1] = (simd_float4){ 0, 1, 0, 1 };
    drawBig();
    CHECK(px(rt, 5, 5) == red && px(rt, 40, 5) == green, "large shared buffer, first upload (0x%08x 0x%08x)", px(rt, 5, 5), px(rt, 40, 5));
    bc[1] = (simd_float4){ 0, 0, 1, 1 };
    memset(big.contents, 7, 100);   // another block changes too
    drawBig();
    CHECK(px(rt, 5, 5) == red && px(rt, 40, 5) == blue, "large shared buffer, changed block re-sent (0x%08x)", px(rt, 40, 5));
    drawBig();
    CHECK(px(rt, 40, 5) == blue, "large shared buffer, unchanged: nothing re-sent, data intact");

    printf("views\n");
    id<MTLTexture> parent = texture(2, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView);
    id<MTLTexture> full = [parent newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
    id<MTLTexture> level1 = [parent newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D
                                                           levels:NSMakeRange(1, 1) slices:NSMakeRange(0, 1)];
    clearTo(full, MTLClearColorMake(1, 1, 0, 1));
    draw(rt, copy0, parent, nil);
    CHECK(px(rt, 7, 7) == yellow, "render into a full-range view, sample the parent (0x%08x)", px(rt, 7, 7));
    clearTo(level1, MTLClearColorMake(0, 1, 1, 1));
    draw(rt, copy1, parent, nil);
    CHECK(px(rt, 7, 7) == cyan, "render into a level-1 view, sample level 1 of the parent (0x%08x)", px(rt, 7, 7));
    draw(rt, copy0, full, nil);
    CHECK(px(rt, 7, 7) == yellow, "level 0 untouched, sampled through the full view (0x%08x)", px(rt, 7, 7));
    uint32_t q[4] = {0};
    [level1 getBytes:q bytesPerRow:8 fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0];
    CHECK(q[0] == cyan && q[3] == cyan, "CPU read of the level-1 view sees the rendered data (0x%08x)", q[0]);

    printf("CPU patches of rendered textures\n");
    id<MTLTexture> painted = texture(1, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    clearTo(painted, MTLClearColorMake(1, 0, 0, 1));                 // the GPU holds the newest data
    fill(painted, MTLRegionMake2D(4, 4, 8, 8), green);               // written into GL, no readback
    draw(rt, copy0, painted, nil);
    CHECK(px(rt, 5, 5) == green && px(rt, 20, 20) == red, "rendered texture patched by the CPU, sampled (0x%08x 0x%08x)",
          px(rt, 5, 5), px(rt, 20, 20));
    CHECK(px(painted, 5, 5) == green && px(painted, 2, 2) == red, "and read back by the CPU (0x%08x 0x%08x)", px(painted, 5, 5), px(painted, 2, 2));
    fill(painted, MTLRegionMake2D(0, 0, 2, 2), blue);                // CPU copy is current again: CPU path
    draw(rt, copy0, painted, nil);
    CHECK(px(rt, 1, 1) == blue && px(rt, 5, 5) == green, "later CPU patch after the readback (0x%08x)", px(rt, 1, 1));

    printf("render-pass framebuffer cache (B6)\n");
    // Targets created and released one after another: GL recycles their names, and a framebuffer cached for the
    // old texture must not be reused for the new one. 40 > the 32 cached framebuffers, so eviction runs too.
    int wrong = 0;
    for (int i = 0; i < 40; i++) @autoreleasepool {
        id<MTLTexture> tmp = texture(1, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        double v = (i + 1) / 64.0;
        clearTo(tmp, MTLClearColorMake(v, 1 - v, i & 1, 1));
        uint32_t want = 0xff000000u | ((i & 1) ? 0xff0000u : 0) | ((uint32_t)lround((1 - v) * 255) << 8) | (uint32_t)lround(v * 255);
        if (px(tmp, 3, 3) != want) wrong++;
    }
    CHECK(!wrong, "recycled texture names: each new target gets its own clear (%d wrong of 40)", wrong);
    clearTo(rt, MTLClearColorMake(0, 0, 1, 1));
    CHECK(px(rt, 3, 3) == blue, "a long-lived target still renders after the evictions (0x%08x)", px(rt, 3, 3));

    printf("\n%d/%d checks passed\n", checks - failures, checks);
    return failures ? 1 : 0;
} }
