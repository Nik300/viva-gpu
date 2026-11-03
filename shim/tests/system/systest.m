// Phase 4 check through the real Metal.framework device discovery (see regsim.m).
// Prints one line per fact; exit 0 if the device count matches argv[1].
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreGraphics/CGDirectDisplayMetal.h>
#import <IOKit/IOKitLib.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        long expect = argc > 1 ? atol(argv[1]) : 1;
        NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
        printf("devices=%lu\n", (unsigned long)all.count);
        for (id<MTLDevice> d in all) printf("device class=%s name=%s registryID=0x%llx\n", object_getClassName(d), d.name.UTF8String, d.registryID);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("default=%s same=%d\n", dev ? object_getClassName(dev) : "nil", dev && all.count && dev == all[0]);
        id<MTLDevice> disp = CGDirectDisplayCopyCurrentMetalDevice(CGMainDisplayID());
        printf("display device=%s same=%d\n", disp ? object_getClassName(disp) : "nil", disp && dev && disp == dev);
        if (dev) {
            // Clear a texture through a render pass and read it back.
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModeManaged;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 1.0, 1.0);
            id<MTLCommandQueue> q = [dev newCommandQueue];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit synchronizeResource:tex];
            [blit endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            uint8_t px[4] = {0};
            [tex getBytes:px bytesPerRow:32 fromRegion:MTLRegionMake2D(3, 3, 1, 1) mipmapLevel:0];
            printf("clear pixel=%d,%d,%d,%d status=%ld\n", px[0], px[1], px[2], px[3], (long)cb.status);
            // TeraScale Compute: a kernel that needs OpenCL (device store). Off (default): pipeline "off", dispatch ignored.
            id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
                                   "kernel void k(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i * 3 + 1; }\n"
                                                    options:nil error:nil];
            id<MTLComputePipelineState> cp = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:nil];
            id<MTLBuffer> out = [dev newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> ccb = [q commandBuffer];
            id<MTLComputeCommandEncoder> ce = [ccb computeCommandEncoder];
            [ce setComputePipelineState:cp];
            [ce setBuffer:out offset:0 atIndex:0];
            [ce dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [ce endEncoding];
            [ccb commit];
            [ccb waitUntilCompleted];
            NSString *path = [(id)cp respondsToSelector:@selector(computePath)] ? [(id)cp valueForKey:@"computePath"] : @"?";
            printf("compute path=%s value=%u\n", path.UTF8String, ((uint32_t *)out.contents)[63]);
        }
        if (getenv("SYSTEST_HOLD")) sleep(atoi(getenv("SYSTEST_HOLD")));
        return (long)all.count == expect ? 0 : 1;
    }
}
