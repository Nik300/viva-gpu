// Viva Metal - command queue, command buffer, blit and compute encoders.
// Encoders record closures; at commit the queue replays them on the device's serial GPU queue (vmg_cmd_* calls),
// flushes to the driver, reports "scheduled", and reports completion when the driver's fence signals (handlers,
// status, waitUntilCompleted through the _MTLCommandBuffer machinery, as in metal-shim).
#import "VMPrivate.h"
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <unistd.h>

#define VM_CATCH_ALL(cls) + (void)initialize { if (self == [cls class]) TSMtlInstallCatchAll(self); }

static VMCommandBuffer *VMEncoderCB(_MTLCommandEncoder *enc) { return (VMCommandBuffer *)[(id)enc commandBuffer]; }
static VMDevice *VMEncoderDevice(_MTLCommandEncoder *enc) { return (VMDevice *)[VMEncoderCB(enc) device]; }

#pragma mark - Blit encoder

@interface VMBlitEncoder : _MTLCommandEncoder <MTLBlitCommandEncoder>
@end

@implementation VMBlitEncoder
VM_CATCH_ALL(VMBlitEncoder)

- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)doff
                  size:(NSUInteger)size {
    if (!size) return;
    VMDevice *d = VMEncoderDevice(self);
    VMBuffer *s = (VMBuffer *)src, *t = (VMBuffer *)dst;
    [VMEncoderCB(self) recordCommand:^{ vmg_cmd_copy_buffer(d.vmg, s.vmg, so, t.vmg, doff, size); }];
}

- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
    if (!range.length) return;
    VMDevice *d = VMEncoderDevice(self);
    VMBuffer *b = (VMBuffer *)buffer;
    [VMEncoderCB(self) recordCommand:^{ vmg_cmd_fill_buffer(d.vmg, b.vmg, range.location, range.length, value); }];
}

- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)off sourceBytesPerRow:(NSUInteger)bpr
   sourceBytesPerImage:(NSUInteger)bpi sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)slice
      destinationLevel:(NSUInteger)level destinationOrigin:(MTLOrigin)o options:(MTLBlitOption)options {
    VMDevice *d = VMEncoderDevice(self);
    VMBuffer *b = (VMBuffer *)src;
    VMTexture *t = (VMTexture *)dst;
    [VMEncoderCB(self) writeTexture:dst];
    [VMEncoderCB(self) recordCommand:^{
        vmg_cmd_copy_buffer_to_texture(d.vmg, b.vmg, off, bpr, bpi, t.vmg, (unsigned)slice, (unsigned)level, (uint32_t)o.x,
                                       (uint32_t)o.y, (uint32_t)o.z, (uint32_t)size.width, (uint32_t)size.height,
                                       (uint32_t)MAX(size.depth, 1));
    }];
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)off sourceBytesPerRow:(NSUInteger)bpr
   sourceBytesPerImage:(NSUInteger)bpi sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)slice
      destinationLevel:(NSUInteger)level destinationOrigin:(MTLOrigin)o {
    [self copyFromBuffer:src sourceOffset:off sourceBytesPerRow:bpr sourceBytesPerImage:bpi sourceSize:size toTexture:dst
        destinationSlice:slice destinationLevel:level destinationOrigin:o options:MTLBlitOptionNone];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)o
             sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)off
 destinationBytesPerRow:(NSUInteger)bpr destinationBytesPerImage:(NSUInteger)bpi options:(MTLBlitOption)options {
    VMDevice *d = VMEncoderDevice(self);
    VMTexture *t = (VMTexture *)src;
    VMBuffer *b = (VMBuffer *)dst;
    [VMEncoderCB(self) useSurface:src.iosurface];
    [VMEncoderCB(self) recordCommand:^{
        vmg_cmd_copy_texture_to_buffer(d.vmg, t.vmg, (unsigned)slice, (unsigned)level, (uint32_t)o.x, (uint32_t)o.y,
                                       (uint32_t)o.z, (uint32_t)size.width, (uint32_t)size.height,
                                       (uint32_t)MAX(size.depth, 1), b.vmg, off, bpr, bpi);
    }];
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)o
             sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)off
 destinationBytesPerRow:(NSUInteger)bpr destinationBytesPerImage:(NSUInteger)bpi {
    [self copyFromTexture:src sourceSlice:slice sourceLevel:level sourceOrigin:o sourceSize:size toBuffer:dst
        destinationOffset:off destinationBytesPerRow:bpr destinationBytesPerImage:bpi options:MTLBlitOptionNone];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so
             sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)ds
       destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg {
    VMDevice *d = VMEncoderDevice(self);
    VMTexture *s = (VMTexture *)src, *t = (VMTexture *)dst;
    [VMEncoderCB(self) useSurface:src.iosurface];
    [VMEncoderCB(self) writeTexture:dst];
    [VMEncoderCB(self) recordCommand:^{
        vmg_cmd_copy_texture(d.vmg, s.vmg, (unsigned)ss, (unsigned)sl, (uint32_t)so.x, (uint32_t)so.y, (uint32_t)so.z,
                             (uint32_t)size.width, (uint32_t)size.height, (uint32_t)MAX(size.depth, 1), t.vmg, (unsigned)ds,
                             (unsigned)dl, (uint32_t)dorg.x, (uint32_t)dorg.y, (uint32_t)dorg.z);
    }];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl sliceCount:(NSUInteger)sliceCount levelCount:(NSUInteger)levelCount {
    for (NSUInteger s = 0; s < sliceCount; s++)
        for (NSUInteger l = 0; l < levelCount; l++) {
            NSUInteger lvl = sl + l;
            MTLSize size = MTLSizeMake(MAX(src.width >> lvl, 1), MAX(src.height >> lvl, 1),
                                       src.textureType == MTLTextureType3D ? MAX(src.depth >> lvl, 1) : 1);
            [self copyFromTexture:src sourceSlice:ss + s sourceLevel:lvl sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:size
                        toTexture:dst destinationSlice:ds + s destinationLevel:dl + l destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
}

- (void)copyFromTexture:(id<MTLTexture>)src toTexture:(id<MTLTexture>)dst {
    NSUInteger slices = src.arrayLength * (src.textureType == MTLTextureTypeCube || src.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    [self copyFromTexture:src sourceSlice:0 sourceLevel:0 toTexture:dst destinationSlice:0 destinationLevel:0
               sliceCount:slices levelCount:MIN(src.mipmapLevelCount, dst.mipmapLevelCount)];
}

- (void)generateMipmapsForTexture:(id<MTLTexture>)texture {
    if (texture.mipmapLevelCount < 2) return;
    VMDevice *d = VMEncoderDevice(self);
    VMTexture *t = (VMTexture *)texture;
    [VMEncoderCB(self) recordCommand:^{ vmg_cmd_generate_mipmaps(d.vmg, t.vmg); }];
}

- (void)synchronizeResource:(id<MTLResource>)resource {}
- (void)synchronizeTexture:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level {}
- (void)updateFence:(id<MTLFence>)fence {}
- (void)waitForFence:(id<MTLFence>)fence {}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture {}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture {}
@end

id<MTLBlitCommandEncoder> VMNewBlitEncoder(VMCommandBuffer *cb) { return [[VMBlitEncoder alloc] initWithCommandBuffer:cb]; }

#pragma mark - Compute encoder

@interface VMComputeEncoder : _MTLCommandEncoder <MTLComputeCommandEncoder>
@end

@implementation VMComputeEncoder {
    uint32_t _shared[8];
    VMComputePipelineState *_pipeline;
}
VM_CATCH_ALL(VMComputeEncoder)

- (MTLDispatchType)dispatchType { return MTLDispatchTypeSerial; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state { _pipeline = (VMComputePipelineState *)state; }

- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    VMDevice *d = VMEncoderDevice(self);
    VMBuffer *b = (VMBuffer *)buffer;
    [VMEncoderCB(self) recordCommand:^{ vmg_cmd_set_buffer(d.vmg, VMG_COMPUTE, (unsigned)index, b.vmg, offset, 0); }];
}
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index {
    VMDevice *d = VMEncoderDevice(self);
    [VMEncoderCB(self) recordCommand:^{ vmg_cmd_set_buffer_offset(d.vmg, VMG_COMPUTE, (unsigned)index, offset); }];
}
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
}
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index {
    NSUInteger off = 0;
    VMBuffer *chunk = [VMEncoderCB(self) inlineBufferWithBytes:bytes length:length offset:&off];
    [self setBuffer:chunk offset:off atIndex:index];
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    VMDevice *d = VMEncoderDevice(self);
    VMTexture *t = (VMTexture *)texture;
    if (texture.usage & MTLTextureUsageShaderWrite) [VMEncoderCB(self) writeTexture:texture];
    else [VMEncoderCB(self) useSurface:texture.iosurface];
    [VMEncoderCB(self) recordCommand:^{ vmg_cmd_set_texture(d.vmg, VMG_COMPUTE, (unsigned)index, t.vmg); }];
}
- (void)setTextures:(const id<MTLTexture> __unsafe_unretained *)textures withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setTexture:textures[i] atIndex:range.location + i];
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    VMDevice *d = VMEncoderDevice(self);
    VMSamplerState *s = (VMSamplerState *)sampler;
    [VMEncoderCB(self) recordCommand:^{ vmg_cmd_set_sampler(d.vmg, VMG_COMPUTE, (unsigned)index, s.vmg, s.lodMin, s.lodMax); }];
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMin lodMaxClamp:(float)lodMax atIndex:(NSUInteger)index {
    [self setSamplerState:sampler atIndex:index];
}
- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained *)samplers withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setSamplerState:samplers[i] atIndex:range.location + i];
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index { if (index < 8) _shared[index] = (uint32_t)length; }

- (void)dispatch:(MTLSize)groups threads:(MTLSize)threads grid:(MTLSize)grid indirect:(id<MTLBuffer>)indirect offset:(NSUInteger)ioff {
    VMComputePipelineState *p = _pipeline;
    if (!p.vmg) { TSMtlStatAlways(TSStatComputeRejected, 1); return; }
    VMDevice *d = VMEncoderDevice(self);
    vmg_dispatch_info info = {0};
    info.pipeline = p.vmg;
    info.groups[0] = (uint32_t)groups.width; info.groups[1] = (uint32_t)groups.height; info.groups[2] = (uint32_t)groups.depth;
    info.threads[0] = (uint32_t)threads.width; info.threads[1] = (uint32_t)threads.height; info.threads[2] = (uint32_t)threads.depth;
    info.grid[0] = (uint32_t)grid.width; info.grid[1] = (uint32_t)grid.height; info.grid[2] = (uint32_t)grid.depth;
    memcpy(info.shared_sizes, _shared, sizeof _shared);
    VMBuffer *ib = (VMBuffer *)indirect;
    info.indirect_offset = ioff;
    [VMEncoderCB(self) keepAlive:p];
    [VMEncoderCB(self) recordCommand:^{
        vmg_dispatch_info i2 = info;
        i2.indirect = ib.vmg;
        vmg_cmd_dispatch(d.vmg, &i2);
    }];
    TSMtlStat(TSStatDispatches, 1);
}
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)threads {
    [self dispatch:groups threads:threads grid:MTLSizeMake(0, 0, 0) indirect:nil offset:0];
}
- (void)dispatchThreads:(MTLSize)grid threadsPerThreadgroup:(MTLSize)threads {
    [self dispatch:MTLSizeMake(0, 0, 0) threads:threads grid:grid indirect:nil offset:0];
}
- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)offset threadsPerThreadgroup:(MTLSize)threads {
    [self dispatch:MTLSizeMake(1, 1, 1) threads:threads grid:MTLSizeMake(0, 0, 0) indirect:buffer offset:offset];
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope {
    VMDevice *d = VMEncoderDevice(self);
    [VMEncoderCB(self) recordCommand:^{ vmg_cmd_barrier(d.vmg); }];
}
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained *)resources count:(NSUInteger)count {
    [self memoryBarrierWithScope:MTLBarrierScopeBuffers];
}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage {}
- (void)useResources:(const id<MTLResource> __unsafe_unretained *)resources count:(NSUInteger)count usage:(MTLResourceUsage)usage {}
- (void)useHeap:(id<MTLHeap>)heap {}
- (void)updateFence:(id<MTLFence>)fence {}
- (void)waitForFence:(id<MTLFence>)fence {}
- (void)endEncoding {
    VMDevice *d = VMEncoderDevice(self);
    [VMEncoderCB(self) recordCommand:^{ vmg_cmd_barrier(d.vmg); }];   // Metal orders encoders on a queue
    [super endEncoding];
}
@end

id<MTLComputeCommandEncoder> VMNewComputeEncoder(VMCommandBuffer *cb) { return [[VMComputeEncoder alloc] initWithCommandBuffer:cb]; }

#pragma mark - Command buffer

enum { VMInlineChunk = 64 << 10, VMInlineAlign = 16 };

@implementation VMCommandBuffer {
    NSMutableArray<dispatch_block_t> *_commands;
    NSMutableArray *_keep;
    NSLock *_lock;
    CFMutableSetRef _surfaces;
    CFMutableSetRef _written;          // IOSurfaces the GPU writes
    BOOL _writesCopiedSurface;         // one of them through a copied texture (CPU copy-out during the replay)
    VMBuffer *_inline;
    NSUInteger _inlineUsed;
    NSMutableArray<VMBuffer *> *_inlineChunks;   // back to the device's pool at completion
}
VM_CATCH_ALL(VMCommandBuffer)

- (uint64_t)protectionOptions { return 0; }               // SPI (CoreAnimation): no content protection
- (void)setProtectionOptions:(uint64_t)options {}

- (instancetype)initWithQueue:(id)queue retainedReferences:(BOOL)retained {
    if ((self = [super initWithQueue:queue retainedReferences:retained])) {
        _commands = [NSMutableArray array];
        _keep = [NSMutableArray array];
        _lock = [NSLock new];
    }
    return self;
}
- (void)dealloc { if (_surfaces) CFRelease(_surfaces); if (_written) CFRelease(_written); }
- (id<MTLDevice>)device { return [(id<MTLCommandQueue>)[self commandQueue] device]; }

- (void)recordCommand:(dispatch_block_t)command {
    [_lock lock];
    [_commands addObject:[command copy]];
    [_lock unlock];
}
- (void)keepAlive:(id)object {
    if (!object) return;
    [_lock lock];
    [_keep addObject:object];
    [_lock unlock];
}
- (VMBuffer *)inlineBufferWithBytes:(const void *)bytes length:(NSUInteger)length offset:(NSUInteger *)offset {
    VMDevice *device = (VMDevice *)self.device;
    if (length > VMInlineChunk / 4) {
        *offset = 0;
        VMBuffer *b = (VMBuffer *)[device newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];
        [self keepAlive:b];
        return b;
    }
    NSUInteger aligned = (length + VMInlineAlign - 1) & ~(NSUInteger)(VMInlineAlign - 1);
    [_lock lock];
    if (!_inline || _inlineUsed + aligned > VMInlineChunk) {
        _inline = [device takeInlineChunk:VMInlineChunk];
        if (!_inlineChunks) _inlineChunks = [NSMutableArray array];
        [_inlineChunks addObject:_inline];
        _inlineUsed = 0;
    }
    VMBuffer *chunk = _inline;
    NSUInteger off = _inlineUsed;
    _inlineUsed += aligned;
    [_lock unlock];
    memcpy((uint8_t *)chunk.contents + off, bytes, length);
    *offset = off;
    return chunk;
}
- (void)useSurface:(IOSurfaceRef)surface {
    if (!surface) return;
    [_lock lock];
    if (!_surfaces) _surfaces = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    CFSetAddValue(_surfaces, surface);
    [_lock unlock];
}
- (void)writeTexture:(id<MTLTexture>)texture {
    IOSurfaceRef surface = texture.iosurface;
    if (!surface) return;
    [self useSurface:surface];
    [_lock lock];
    if (!_written) _written = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    CFSetAddValue(_written, surface);
    if (vmg_texture_is_copied(((VMTexture *)texture).vmg)) _writesCopiedSurface = YES;
    [_lock unlock];
}
- (BOOL)writesSurface { return _written != NULL; }

// K0i: promises the written IOSurfaces to the kernel (0: not possible). Not for copied surfaces: their copy-out locks
// the surface from this process during the replay, and IOSurfaceLock would wait for our own promise.
static void VMCollectSurfaceID(const void *value, void *ctx) {
    NSMutableData *ids = (__bridge NSMutableData *)ctx;
    uint32_t id = IOSurfaceGetID((IOSurfaceRef)value);
    [ids appendBytes:&id length:sizeof id];
}
- (uint32_t)promiseWrittenSurfaces:(VMDevice *)device {
    [_lock lock];
    BOOL copied = _writesCopiedSurface;
    NSMutableData *ids = [NSMutableData data];
    if (_written) CFSetApplyFunction(_written, VMCollectSurfaceID, (__bridge void *)ids);
    [_lock unlock];
    unsigned n = (unsigned)(ids.length / sizeof(uint32_t));
    if (copied || !n) return 0;
    return vmg_surface_promise(device.vmg, ids.bytes, n);
}
static void VMSurfaceUse(const void *value, void *ctx) {
    if (ctx) IOSurfaceIncrementUseCount((IOSurfaceRef)value); else IOSurfaceDecrementUseCount((IOSurfaceRef)value);
}
- (void)beginSurfaceUse { if (_surfaces) CFSetApplyFunction(_surfaces, VMSurfaceUse, (void *)1); }
- (void)endSurfaceUse { if (_surfaces) CFSetApplyFunction(_surfaces, VMSurfaceUse, NULL); }

- (void)execute {
    [_lock lock];
    NSArray *commands = _commands;
    _commands = [NSMutableArray array];
    [_lock unlock];
    for (dispatch_block_t command in commands) command();
}
- (void)releaseKept {
    [_lock lock];
    [_keep removeAllObjects];
    NSArray<VMBuffer *> *chunks = _inlineChunks;
    _inlineChunks = nil;
    _inline = nil;
    [_lock unlock];
    VMDevice *device = (VMDevice *)self.device;
    for (VMBuffer *chunk in chunks) [device returnInlineChunk:chunk];   // the GPU has read them
}

- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)desc {
    id<MTLRenderCommandEncoder> e = VMNewRenderEncoder(self, desc);
    [self setCurrentCommandEncoder:e];
    return e;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    id<MTLComputeCommandEncoder> e = VMNewComputeEncoder(self);
    [self setCurrentCommandEncoder:e];
    return e;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)type { return [self computeCommandEncoder]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)desc { return [self computeCommandEncoder]; }
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
    id<MTLBlitCommandEncoder> e = VMNewBlitEncoder(self);
    [self setCurrentCommandEncoder:e];
    return e;
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)desc { return [self blitCommandEncoder]; }
- (id<MTLParallelRenderCommandEncoder>)parallelRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)desc {
    return (id<MTLParallelRenderCommandEncoder>)[[TSMtlInert alloc] initWithDevice:self.device protocols:@[@protocol(MTLParallelRenderCommandEncoder)]];
}
// Events: one serial GPU queue, so waits are satisfied by order; signals run at completion.
// Values our command buffers have signalled, per event (plain MTLEvents have no readable value): VMG_TRACE_EVENT.
static NSMapTable *VMEventValues(void) {
    static NSMapTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSMapTable weakToStrongObjectsMapTable]; });
    return t;
}
static BOOL VMTraceEvents(void) {
    static int on = -1;
    if (on < 0) on = getenv("VMG_TRACE_EVENT") != NULL;
    return on;
}
- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value {
    __weak id<MTLEvent> e = event;
    // VMG_TRACE_EVENT: what matters on one serial queue is that the signaller ran before the waiter.
    [self recordCommand:^{
        id<MTLEvent> ev = e;
        if (ev && VMTraceEvents()) @synchronized (VMEventValues()) { [VMEventValues() setObject:@(value) forKey:ev]; }
    }];
    [self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        id<MTLEvent> ev = e;
        if ([(id)ev respondsToSelector:@selector(setSignaledValue:)]) [(id<MTLSharedEvent>)ev setSignaledValue:value];
    }];
}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value {
    if (!VMTraceEvents()) return;
    __weak id<MTLEvent> e = event;
    [self recordCommand:^{
        id<MTLEvent> ev = e;
        uint64_t have = 0;
        BOOL shared = [(id)ev respondsToSelector:@selector(signaledValue)];
        @synchronized (VMEventValues()) { have = [[VMEventValues() objectForKey:ev] unsignedLongLongValue]; }
        if (shared) have = MAX(have, [(id<MTLSharedEvent>)ev signaledValue]);   // also signalled by the CPU / others
        fprintf(stderr, "vmg: event wait %s %p value %llu, signalled %llu%s\n", shared ? "shared" : "plain", (__bridge void *)ev,
                (unsigned long long)value, (unsigned long long)have, have < value ? " UNSATISFIED" : "");
    }];
}
@end

#pragma mark - Command queue

@implementation VMCommandQueue {
    __weak VMDevice *_device;
}
VM_CATCH_ALL(VMCommandQueue)

- (instancetype)initWithDevice:(id)device descriptor:(MTLCommandQueueDescriptor *)descriptor {
    if ((self = [super initWithDevice:device descriptor:descriptor])) _device = device;
    return self;
}
- (id<MTLDevice>)device { return _device; }
- (id<MTLCommandBuffer>)commandBuffer { return [[VMCommandBuffer alloc] initWithQueue:self retainedReferences:YES]; }
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [[VMCommandBuffer alloc] initWithQueue:self retainedReferences:NO]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)desc {
    return [[VMCommandBuffer alloc] initWithQueue:self retainedReferences:desc.retainedReferences];
}

static void VMDidComplete(VMDevice *device, VMCommandQueue *queue, VMCommandBuffer *cb, vmg_fence *fence, uint64_t start) {
    vmg_fence_release(device.vmg, fence);
    [cb endSurfaceUse];
    [cb releaseKept];
    [queue commandBufferDidComplete:cb startTime:start completionTime:mach_absolute_time() error:nil];
}

// VMG_POLL_COMPLETION=1 (comparisons): the GPU queue polls the fence every 100 us without blocking. Each poll is a
// kernel call on the GPU queue, between the replays of the next command buffers, and completion comes up to a poll
// period (plus timer slack) late.
static void VMPollCompletion(VMDevice *device, VMCommandQueue *queue, VMCommandBuffer *cb, vmg_fence *fence, uint64_t start) {
    if (!vmg_fence_wait(device.vmg, fence, 0)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_USEC), device.gpuQueue, ^{
            VMPollCompletion(device, queue, cb, fence, start);
        });
        return;
    }
    VMDidComplete(device, queue, cb, fence, start);
}

// Completion: the device's completion queue sleeps in the kernel on each fence, in commit order, and reports it from
// there (handlers run off the GPU queue, as Metal's own completion thread does). Only visibility results need the
// pipe_context: those are resolved on the GPU queue first.
static void VMWaitCompletion(VMDevice *device, VMCommandQueue *queue, VMCommandBuffer *cb, vmg_fence *fence, uint64_t start) {
    static int poll = -1;
    if (poll < 0) poll = getenv("VMG_POLL_COMPLETION") != NULL;
    if (poll) { VMPollCompletion(device, queue, cb, fence, start); return; }
    dispatch_async(device.completionQueue, ^{
        // Deadlines are absolute CLOCK_MONOTONIC (Mesa's os_time_get_nano; on Darwin gettimeofday - boottime), the
        // clock the kernel compares them with since 0120. Before 0120 the kernel used mach_continuous_time and a
        // deadline 1 s ahead came back expired at once (then 1 ms sleeps here: +10 ms per frame).
        unsigned waited_s = 0;
        for (;;) {
            uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            if (vmg_fence_wait_gpu(device.vmg, fence, NSEC_PER_SEC)) break;
            uint64_t took = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
            if (took >= NSEC_PER_SEC / 2) {
                if (++waited_s == 1 || waited_s % 10 == 0)
                    fprintf(stderr, "vmg: command buffer still running after %u s (GPU hang?)\n", waited_s);
            } else if (took < NSEC_PER_MSEC) {
                usleep(1000);   // an error or a deadline taken as expired at once: retry without spinning
            }
        }
        if (vmg_fence_has_results(fence)) [device gpuSync:^{ vmg_fence_wait(device.vmg, fence, 0); }];
        VMDidComplete(device, queue, cb, fence, start);
    });
}

// Called by -[_MTLCommandQueue] once command buffers are committed, in order.
- (void)submitCommandBuffers:(const id *)buffers count:(NSUInteger)count {
    VMDevice *device = _device;
    for (NSUInteger i = 0; i < count; i++) {
        VMCommandBuffer *cb = buffers[i];
        [cb beginSurfaceUse];
        // A command buffer that writes an IOSurface is replayed and submitted before commit returns (not waited
        // for): another process may read the surface as soon as this one tells it, e.g. SpringBoard's app snapshots
        // rendered by backboardd. The kernel makes readers (IOSurfaceLock, their GPU jobs) wait only for jobs it knows;
        // submitted later, the snapshot was read half drawn (black launch cards). Apple's driver registers the work at
        // commit too. VMG_ASYNC_SURFACE_COMMIT=1: asynchronous as before (comparisons).
        //
        // VMG_SURFACE_PROMISE=1 (kernel uapi minor >= 2, K0i, needs 0122 for K0j): the written surfaces are promised
        // to the kernel instead and the replay stays asynchronous. Off by default: on 0123 it rendered more frames but
        // the panel showed fewer (Settings scrolls ~25 fps vs ~42 synchronous; "frames shown anyway" 1 -> 37): the
        // display (K0c) keeps finding the newest frame's surfaces under a pending promise and waits up to 12 ticks.
        static int async_surface = -1, promises = -1;
        if (async_surface < 0) async_surface = getenv("VMG_ASYNC_SURFACE_COMMIT") != NULL;
        if (promises < 0) promises = getenv("VMG_SURFACE_PROMISE") != NULL;
        uint32_t promise = cb.writesSurface && !async_surface && promises ? [cb promiseWrittenSurfaces:device] : 0;
        void (^submit)(dispatch_block_t) = cb.writesSurface && !async_surface && !promise
                                               ? ^(dispatch_block_t b) { [device gpuSync:b]; }
                                               : ^(dispatch_block_t b) { [device gpuAsync:b]; };
        submit(^{
            uint64_t start = mach_absolute_time();
            TSMtlStat(TSStatCommandBuffers, 1);
            [cb execute];
            vmg_fence *fence = NULL;
            vmg_flush(device.vmg, &fence);
            vmg_surface_promise_resolve(device.vmg, promise, fence);
            // "Scheduled" after the flush: presentDrawable hands the IOSurface to the compositor from there.
            [cb didScheduleWithStartTime:start endTime:mach_absolute_time() error:nil];
            VMWaitCompletion(device, self, cb, fence, start);
        });
    }
}
@end
