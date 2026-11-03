// Phase 1 acceptance test: an id<MTLDevice> from the shim works in-process, while
// the system still reports no Metal device. Run with TSMTL_LOG=1 to see stub misses.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import "TSMetal.h"

static int failures, checks;
#define CHECK(cond, ...) do { checks++; if (cond) printf("  ok   "); else { failures++; printf("  FAIL "); } \
    printf(__VA_ARGS__); printf("\n"); } while (0)

static void testDevice(id<MTLDevice> dev) {
    printf("device\n");
    CHECK([dev conformsToProtocol:@protocol(MTLDevice)], "conforms to MTLDevice");
    CHECK(dev.name.length > 0, "name = \"%s\"", dev.name.UTF8String);
    CHECK([dev supportsFamily:MTLGPUFamilyMac2], "supportsFamily Mac2");
    CHECK([dev supportsFamily:MTLGPUFamilyCommon2], "supportsFamily Common2");
    CHECK(![dev supportsFamily:MTLGPUFamilyMetal3], "no Metal3");
    CHECK(![dev supportsFamily:MTLGPUFamilyApple1], "no Apple families");
    CHECK(dev.registryID != 0, "registryID = 0x%llx", dev.registryID);
    CHECK(dev.recommendedMaxWorkingSetSize >= (256ull << 20), "working set = %llu MB", dev.recommendedMaxWorkingSetSize >> 20);
    CHECK(dev.maxBufferLength >= (256ull << 20), "maxBufferLength = %lu MB", (unsigned long)(dev.maxBufferLength >> 20));
    CHECK(dev.argumentBuffersSupport == MTLArgumentBuffersTier1, "argument buffers tier 1");
    CHECK(!dev.supportsRaytracing && !dev.hasUnifiedMemory && !dev.isLowPower, "raytracing/unified/lowPower = NO");
    CHECK([dev supportsTextureSampleCount:1] && [dev supportsTextureSampleCount:4], "sample counts 1 and 4");
    MTLSize tg = dev.maxThreadsPerThreadgroup;
    CHECK(tg.width == 1024, "maxThreadsPerThreadgroup %lux%lux%lu", (unsigned long)tg.width, (unsigned long)tg.height, (unsigned long)tg.depth);
}

static void testBuffers(id<MTLDevice> dev) {
    printf("buffers\n");
    NSUInteger before = dev.currentAllocatedSize;
    id<MTLBuffer> a = [dev newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
    CHECK(a && a.length == 1 << 20 && a.contents, "newBufferWithLength 1 MB");
    CHECK(dev.currentAllocatedSize >= before + (1 << 20), "currentAllocatedSize grows (%lu)", (unsigned long)dev.currentAllocatedSize);
    uint32_t data[4] = {1, 2, 3, 4};
    id<MTLBuffer> b = [dev newBufferWithBytes:data length:sizeof data options:MTLResourceStorageModeManaged];
    CHECK(b && memcmp(b.contents, data, sizeof data) == 0, "newBufferWithBytes copies");
    CHECK(b.storageMode == MTLStorageModeManaged, "storageMode managed");
    __block BOOL freed = NO;
    void *mem = NULL;
    posix_memalign(&mem, 4096, 4096);
    @autoreleasepool {
        id<MTLBuffer> c = [dev newBufferWithBytesNoCopy:mem length:4096 options:0 deallocator:^(void *p, NSUInteger n) { free(p); freed = YES; }];
        CHECK(c.contents == mem, "newBufferWithBytesNoCopy aliases memory");
        c = nil;
    }
    CHECK(freed, "no-copy deallocator called");
    b.label = @"test buffer";
    CHECK([b.label isEqualToString:@"test buffer"], "label");
    CHECK(b.gpuAddress != 0, "gpuAddress");
}

static void testTextures(id<MTLDevice> dev) {
    printf("textures\n");
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:32 mipmapped:YES];
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    CHECK(t && t.width == 64 && t.height == 32 && t.mipmapLevelCount == 7, "2D RGBA8 64x32 with 7 mips");
    uint32_t px[64 * 32];
    for (int i = 0; i < 64 * 32; i++) px[i] = 0xff000000u | i;
    [t replaceRegion:MTLRegionMake2D(0, 0, 64, 32) mipmapLevel:0 withBytes:px bytesPerRow:64 * 4];
    uint32_t out[16 * 8] = {0};
    [t getBytes:out bytesPerRow:16 * 4 fromRegion:MTLRegionMake2D(8, 4, 16, 8) mipmapLevel:0];
    CHECK(out[0] == px[4 * 64 + 8] && out[16 * 8 - 1] == px[11 * 64 + 23], "replaceRegion/getBytes sub-region round trip");
    uint32_t mip[2] = {0xdeadbeef, 0xcafebabe}, mipOut[2] = {0};
    [t replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:5 withBytes:mip bytesPerRow:8];
    [t getBytes:mipOut bytesPerRow:8 fromRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:5];
    CHECK(memcmp(mip, mipOut, 8) == 0, "mip level 5 round trip");

    MTLTextureDescriptor *cd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm size:16 mipmapped:NO];
    id<MTLTexture> cube = [dev newTextureWithDescriptor:cd];
    uint32_t face = 0x11223344, faceOut = 0;
    [cube replaceRegion:MTLRegionMake2D(3, 3, 1, 1) mipmapLevel:0 slice:4 withBytes:&face bytesPerRow:4 bytesPerImage:4];
    [cube getBytes:&faceOut bytesPerRow:4 bytesPerImage:4 fromRegion:MTLRegionMake2D(3, 3, 1, 1) mipmapLevel:0 slice:4];
    CHECK(cube.textureType == MTLTextureTypeCube && faceOut == face, "cube face 4 round trip");

    MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC1_RGBA width:16 height:16 mipmapped:NO];
    id<MTLTexture> bc = [dev newTextureWithDescriptor:bd];
    uint8_t blocks[4 * 4 * 8];
    for (int i = 0; i < (int)sizeof blocks; i++) blocks[i] = (uint8_t)i;
    uint8_t blocksOut[sizeof blocks] = {0};
    [bc replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:blocks bytesPerRow:4 * 8];
    [bc getBytes:blocksOut bytesPerRow:4 * 8 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
    CHECK(memcmp(blocks, blocksOut, sizeof blocks) == 0, "BC1 compressed round trip");

    id<MTLTexture> view = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    uint32_t v = 0;
    [view getBytes:&v bytesPerRow:4 fromRegion:MTLRegionMake2D(5, 0, 1, 1) mipmapLevel:0];
    CHECK(view.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB && view.parentTexture == t && v == px[5], "sRGB view shares storage");

    NSDictionary *props = @{ (id)kIOSurfaceWidth: @32, (id)kIOSurfaceHeight: @32, (id)kIOSurfaceBytesPerElement: @4,
                             (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
    id<MTLTexture> st = [dev newTextureWithDescriptor:sd iosurface:surf plane:0];
    uint32_t sp = 0xff00ff00;
    [st replaceRegion:MTLRegionMake2D(1, 2, 1, 1) mipmapLevel:0 withBytes:&sp bytesPerRow:4];
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    uint32_t raw = *(uint32_t *)((uint8_t *)IOSurfaceGetBaseAddress(surf) + 2 * IOSurfaceGetBytesPerRow(surf) + 4);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    CHECK(st.iosurface == surf && raw == sp, "IOSurface-backed texture writes into the surface");
    CFRelease(surf);

    MTLSamplerDescriptor *smp = [MTLSamplerDescriptor new];
    smp.minFilter = MTLSamplerMinMagFilterLinear;
    CHECK([dev newSamplerStateWithDescriptor:smp] != nil, "sampler state");
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
    dsd.depthCompareFunction = MTLCompareFunctionLess;
    dsd.depthWriteEnabled = YES;
    CHECK([dev newDepthStencilStateWithDescriptor:dsd] != nil, "depth/stencil state");
}

static void testCommands(id<MTLDevice> dev) {
    printf("commands\n");
    id<MTLCommandQueue> q = [dev newCommandQueue];
    CHECK(q && q.device == dev, "newCommandQueue");
    q.label = @"queue";

    id<MTLCommandBuffer> empty = [q commandBuffer];
    __block BOOL scheduled = NO, completed = NO;
    [empty addScheduledHandler:^(id<MTLCommandBuffer> cb) { scheduled = YES; }];
    [empty addCompletedHandler:^(id<MTLCommandBuffer> cb) { completed = YES; }];
    [empty commit];
    [empty waitUntilCompleted];
    CHECK(empty.status == MTLCommandBufferStatusCompleted, "empty command buffer completes (status %lu)", (unsigned long)empty.status);
    CHECK(scheduled && completed, "scheduled and completed handlers run");
    CHECK(empty.error == nil, "no error");

    id<MTLBuffer> src = [dev newBufferWithLength:256 options:0], dst = [dev newBufferWithLength:256 options:0];
    memset(src.contents, 0xab, 256);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromBuffer:src sourceOffset:16 toBuffer:dst destinationOffset:32 size:64];
    [blit fillBuffer:dst range:NSMakeRange(0, 8) value:0x5a];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint8_t *d = dst.contents;
    CHECK(d[0] == 0x5a && d[7] == 0x5a && d[8] == 0 && d[32] == 0xab && d[95] == 0xab && d[96] == 0, "blit copy + fill executed in order");

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> up = [dev newBufferWithLength:8 * 8 * 4 options:0], down = [dev newBufferWithLength:8 * 8 * 4 options:0];
    for (int i = 0; i < 64; i++) ((uint32_t *)up.contents)[i] = 0x01020300u + i;
    cb = [q commandBuffer];
    blit = [cb blitCommandEncoder];
    [blit copyFromBuffer:up sourceOffset:0 sourceBytesPerRow:32 sourceBytesPerImage:256 sourceSize:MTLSizeMake(8, 8, 1)
               toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1)
                 toBuffer:down destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    CHECK(memcmp(up.contents, down.contents, 256) == 0, "blit buffer -> texture -> buffer");

    // Encoders we accept but do not execute must swallow calls without crashing.
    cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setViewport:(MTLViewport){0, 0, 8, 8, 0, 1}];
    [re setVertexBuffer:up offset:0 atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setBuffer:up offset:0 atIndex:0];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted, "render + compute encoders accepted (inert)");

    id<MTLSharedEvent> ev = [dev newSharedEvent];
    cb = [q commandBuffer];
    [cb encodeSignalEvent:ev value:7];
    [cb commit];
    [cb waitUntilCompleted];
    CHECK(ev && ev.signaledValue == 7, "shared event signaled by GPU queue (value %llu)", ev.signaledValue);

    // Many in-flight buffers, then -finish style drain via the last one.
    id<MTLCommandBuffer> last = nil;
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (int i = 0; i < 100; i++) {
        last = [q commandBuffer];
        [last addCompletedHandler:^(id<MTLCommandBuffer> c) { @synchronized (order) { [order addObject:@(i)]; } }];
        [last commit];
    }
    [last waitUntilCompleted];
    usleep(10000);
    BOOL inOrder = order.count == 100;
    for (NSUInteger i = 0; inOrder && i < 100; i++) inOrder = order[i].intValue == (int)i;
    CHECK(inOrder, "100 command buffers completed in commit order (%lu)", (unsigned long)order.count);

    CHECK([dev newFence] != nil, "fence (inert)");
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
    hd.size = 4 << 20;
    id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
    id<MTLBuffer> hb = [heap newBufferWithLength:4096 options:0];
    CHECK(heap.size == 4 << 20 && hb && heap.usedSize >= 4096, "heap sub-allocation");
    MTLIndirectCommandBufferDescriptor *icbd = [MTLIndirectCommandBufferDescriptor new];
    CHECK([dev newIndirectCommandBufferWithDescriptor:icbd maxCommandCount:16 options:0] != nil, "indirect command buffer (inert)");
}

int main(void) {
    @autoreleasepool {
        printf("system\n");
        // Linking the library must not hijack system Metal. Calling MTLCreateSystemDefaultDevice here would
        // load the installed driver bundle (Phase 4) next to build/libTSMetal.dylib (duplicate classes), so
        // only check where the symbol resolves.
        Dl_info info = { 0 };
        CHECK(dladdr((void *)MTLCreateSystemDefaultDevice, &info) && info.dli_fname && strstr(info.dli_fname, "Metal.framework"),
              "MTLCreateSystemDefaultDevice still resolves to Metal.framework (system untouched)");
        id<MTLDevice> dev = TSMtlCreateDevice();
        CHECK(dev != nil, "TSMtlCreateDevice");
        if (!dev) return 1;
        testDevice(dev);
        testBuffers(dev);
        testTextures(dev);
        testCommands(dev);
        printf("\n%d/%d checks passed\n", checks - failures, checks);
    }
    return failures ? 1 : 0;
}
