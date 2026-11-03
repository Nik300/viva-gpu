// Viva Metal - the device. _MTLDevice implements libraries, functions and family queries; we supply the driver part
// (resources, queues, pipelines, limits) on vmg (Gallium: llvmpipe on the Mac, Panfrost on the phone).
//
// Creation: Metal.framework on iOS calls -initWithAcceleratorPort: on the class named by the kernel service's
// MetalPluginClassName (docs/PIANO-GPU.md, G0). Tests create it with VMCreateDevice() / TSMtlCreateDevice().
#import "VMPrivate.h"
#import <objc/runtime.h>
#import <stdatomic.h>
#import <TargetConditionals.h>

// Implemented by _MTLDevice (checked at runtime), not declared in its header.
@interface _MTLDevice (VMLibraries)
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error;
@end

// MTLDeviceFeatureProfile (probed by metal-shim on macOS: 10001 = Mac2 + Common1..3). iOS 16 / Apple4: to be probed
// on the phone (G0 question 2); until then the Mac value is used on the Mac only.
#if TARGET_OS_IPHONE
enum { VMFeatureProfile = 4 };          // placeholder: Apple4 (A11); confirm with getSupportedFamilies on iOS 16
#else
enum { VMFeatureProfile = 10001 };
#endif

@interface VMHeap : TSMtlInert <MTLHeap>
- (instancetype)initWithDevice:(VMDevice *)device descriptor:(MTLHeapDescriptor *)desc;
@end

@implementation VMDevice {
    NSString *_name;
    _Atomic int64_t _allocated;
    io_service_t _accelerator;
}

static const void *const VMGPUQueueKey = &VMGPUQueueKey;

+ (void)initialize {
    if (self != [VMDevice class]) return;
    TSMtlInstallCatchAll(self);
    Protocol *spi = objc_getProtocol("MTLDeviceSPI");
    if (spi) class_addProtocol(self, spi);
}

- (instancetype)initWithDriver:(const char *)driver {
    if (!(self = [super init])) return nil;
    char err[256] = "";
    _vmg = vmg_device_create(driver, err, sizeof err);
    if (!_vmg) {
        TSMtlError(@"vmg device: %s", err);
        return nil;
    }
    const vmg_device_info *info = vmg_device_get_info(_vmg);
    _name = [NSString stringWithUTF8String:info->name];
    _gpuQueue = dispatch_queue_create("com.viva.metal.gpu", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_gpuQueue, VMGPUQueueKey, (__bridge void *)self, NULL);
    [self fillLimits];
    [self initGPUFamilySupport];
    TSMtlInstallLayerTuning();
    TSMtlLog(@"device ready: %@ (%s)", _name, info->driver);
    return self;
}

// iOS: Metal.framework (_MTLRegisterDevices) with the IOAcceleratorES service.
- (instancetype)initWithAcceleratorPort:(io_service_t)port {
    if ((self = [self initWithDriver:NULL])) _accelerator = port;
    return self;
}

- (void)dealloc {
    // The last reference often goes away inside a release block running on the GPU queue itself.
    vmg_device *v = _vmg;
    if (!v) return;
    if (self.isOnGPUQueue) vmg_device_destroy(v);
    else dispatch_sync(_gpuQueue, ^{ vmg_device_destroy(v); });
}

- (BOOL)isOnGPUQueue { return dispatch_get_specific(VMGPUQueueKey) == (__bridge void *)self; }
- (void)gpuSync:(dispatch_block_t)block { if (self.isOnGPUQueue) block(); else dispatch_sync(_gpuQueue, block); }
- (void)gpuAsync:(dispatch_block_t)block { dispatch_async(_gpuQueue, block); }
- (void)trackAllocation:(int64_t)delta {
    atomic_fetch_add(&_allocated, delta);
    atomic_fetch_add_explicit(&gTSMtlAllocatedBytes, delta, memory_order_relaxed);
}

// Writes the base class _limits struct (layout checked at runtime, as in metal-shim).
- (void)fillLimits {
    Ivar limitsIvar = class_getInstanceVariable([_MTLDevice class], "_limits");
    Ivar nextIvar = class_getInstanceVariable([_MTLDevice class], "_serialQueue");
    if (!limitsIvar || !nextIvar || ivar_getOffset(nextIvar) - ivar_getOffset(limitsIvar) != sizeof(TSMtlLimits)) {
        TSMtlWarn(@"_MTLDevice _limits layout changed, limits not written");
        return;
    }
    const vmg_device_info *info = vmg_device_get_info(_vmg);
    TSMtlLimits *l = (TSMtlLimits *)((uint8_t *)(__bridge void *)self + ivar_getOffset(limitsIvar));
    memset(l, 0, sizeof *l);
    l->maxColorAttachments = 8;
    l->maxVertexAttributes = 31;
    l->maxVertexBuffers = l->maxFragmentBuffers = l->maxComputeBuffers = 31;
    l->maxVertexTextures = l->maxFragmentTextures = l->maxComputeTextures = 31;
    l->maxVertexSamplers = l->maxFragmentSamplers = l->maxComputeSamplers = 16;
    l->maxVertexInlineDataSize = l->maxFragmentInlineDataSize = l->maxComputeInlineDataSize = 4096;
    l->maxInterpolants = 31;
    l->maxInterpolatedComponents = 124;
    l->maxComputeLocalMemorySizes = l->maxComputeThreadgroupMemory = info->max_shared_memory;
    l->maxTotalComputeThreadsPerThreadgroup = info->max_threads_per_group;
    l->maxComputeThreadgroupMemoryAlignmentBytes = 16;
    l->maxLineWidth = 1;
    l->maxPointSize = 511;
    l->maxVisibilityQueryOffset = 65528;
    l->minConstantBufferAlignmentBytes = 4;
    l->minBufferNoCopyAlignmentBytes = 16384;
    l->maxTextureWidth1D = l->maxTextureWidth2D = l->maxTextureHeight2D = info->max_texture_2d;
    l->maxTextureWidth3D = l->maxTextureHeight3D = l->maxTextureDepth3D = info->max_texture_3d;
    l->maxTextureDimensionCube = info->max_texture_cube;
    l->maxTextureLayers = info->max_texture_layers;
    l->linearTextureAlignmentBytes = l->linearTextureArrayAlignmentBytes = 64;
    l->iosurfaceTextureAlignmentBytes = l->iosurfaceReadOnlyTextureAlignmentBytes = 64;
    l->deviceLinearTextureAlignmentBytes = l->deviceLinearReadOnlyTextureAlignmentBytes = 64;
    l->maxFunctionConstantIndices = 65536;
    l->maxTessellationFactor = 16;
    l->maxIndirectBuffers = 31; l->maxIndirectTextures = 31; l->maxIndirectSamplers = 16;
    l->maxIndirectSamplersPerDevice = 1024;
    l->maxFenceInstances = 16384;
    l->maxViewportCount = 1;
    l->maxVertexAmplificationFactor = l->maxVertexAmplificationCount = 1;
    l->maxTextureBufferWidth = 1 << 27;
    l->maxComputeAttributes = 31;
    l->maxIOCommandsInFlight = 16;
    l->maxConstantBufferArguments = 31;
    l->maxBufferLength = self.maxBufferLength;
}

#pragma mark Identity and limits

- (NSString *)name { return _name; }
- (NSString *)familyName { return @"Mali"; }
- (NSString *)productName { return _name; }
- (NSString *)vendorName { return @"ARM"; }
- (unsigned long long)featureProfile { return VMFeatureProfile; }
// The IOAcceleratorES service's id on iOS; a stable synthetic one when there is no service (tests on the Mac).
- (uint64_t)registryID {
    uint64_t id = 0;
    if (_accelerator) IORegistryEntryGetRegistryEntryID(_accelerator, &id);
    return id ? id : 0x5649564147505531ull;   // 'VIVAGPU1'
}
- (unsigned int)acceleratorPort { return _accelerator; }
- (uint64_t)dedicatedMemorySize { return 0; }
- (uint64_t)sharedMemorySize { return vmg_device_get_info(_vmg)->video_memory; }
- (BOOL)metalAssertionsEnabled { return NO; }
- (void)setMetalAssertionsEnabled:(BOOL)enabled {}
- (MTLDeviceLocation)location { return MTLDeviceLocationBuiltIn; }
- (NSUInteger)locationNumber { return 0; }
- (BOOL)isLowPower { return YES; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }
- (BOOL)hasUnifiedMemory { return YES; }
- (uint64_t)maxTransferRate { return 0; }
- (uint64_t)peerGroupID { return 0; }
- (uint32_t)peerIndex { return 0; }
- (uint32_t)peerCount { return 0; }
- (uint64_t)recommendedMaxWorkingSetSize { return vmg_device_get_info(_vmg)->video_memory; }
- (NSUInteger)currentAllocatedSize { return (NSUInteger)MAX(atomic_load(&_allocated), 0); }
- (NSUInteger)maxBufferLength { return 256ull << 20; }
- (MTLSize)maxThreadsPerThreadgroup {
    NSUInteger n = vmg_device_get_info(_vmg)->max_threads_per_group;
    return MTLSizeMake(n, n, 64);
}
- (NSUInteger)maxThreadgroupMemoryLength { return vmg_device_get_info(_vmg)->max_shared_memory; }
- (BOOL)isDepth24Stencil8PixelFormatSupported { return vmg_format_supported(_vmg, MTLPixelFormatDepth24Unorm_Stencil8, YES, NO); }
- (BOOL)supportsSampleCount:(NSUInteger)count { return count == 1 || (count <= vmg_device_get_info(_vmg)->max_samples && !(count & (count - 1))); }
- (BOOL)supportsTextureSampleCount:(NSUInteger)count { return [self supportsSampleCount:count]; }
- (BOOL)supportsVertexAmplificationCount:(NSUInteger)count { return count == 1; }
- (BOOL)supportsBCTextureCompression { return vmg_format_supported(_vmg, MTLPixelFormatBC1_RGBA, NO, YES); }
- (BOOL)isBCTextureCompressionSupported { return self.supportsBCTextureCompression; }
- (BOOL)areProgrammableSamplePositionsSupported { return NO; }
- (BOOL)supportsRaytracing { return NO; }
- (BOOL)supportsRaytracingFromRender { return NO; }
- (BOOL)supportsFunctionPointers { return NO; }
- (BOOL)supportsFunctionPointersFromRender { return NO; }
- (BOOL)supportsDynamicLibraries { return NO; }
- (BOOL)supportsRenderDynamicLibraries { return NO; }
- (BOOL)supports32BitFloatFiltering { return YES; }
- (BOOL)supports32BitMSAA { return YES; }
- (BOOL)supportsQueryTextureLOD { return YES; }
- (BOOL)supportsShaderBarycentricCoordinates { return NO; }
- (BOOL)supportsPrimitiveMotionBlur { return NO; }
- (BOOL)areRasterOrderGroupsSupported { return NO; }
- (BOOL)areBarycentricCoordsSupported { return NO; }
- (MTLReadWriteTextureTier)readWriteTextureSupport { return MTLReadWriteTextureTier1; }
- (MTLArgumentBuffersTier)argumentBuffersSupport { return MTLArgumentBuffersTier1; }
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(MTLPixelFormat)format { return 64; }
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)format { return 64; }
- (MTLSize)sparseTileSizeWithTextureType:(MTLTextureType)t pixelFormat:(MTLPixelFormat)f sampleCount:(NSUInteger)s { return MTLSizeMake(0, 0, 0); }

#pragma mark Resources

- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    return [[VMBuffer alloc] initWithDevice:self length:length options:options bytes:NULL deallocator:nil];
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options {
    VMBuffer *b = [[VMBuffer alloc] initWithDevice:self length:length options:options bytes:NULL deallocator:nil];
    if (b && pointer) memcpy(b.contents, pointer, length);
    return b;
}
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options
                              deallocator:(void (^)(void *, NSUInteger))deallocator {
    return [[VMBuffer alloc] initWithDevice:self length:length options:options bytes:pointer deallocator:deallocator];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc {
    return [[VMTexture alloc] initWithDevice:self descriptor:desc iosurface:NULL plane:0];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane {
    return [[VMTexture alloc] initWithDevice:self descriptor:desc iosurface:surface plane:plane];
}
- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    return (MTLSizeAndAlign){ (length + 255) & ~(NSUInteger)255, 256 };
}
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)desc {
    TSPixelFormatInfo pf = TSPixelFormatGetInfo(desc.pixelFormat);
    NSUInteger size = 0, w = desc.width, h = desc.height, d = desc.depth;
    for (NSUInteger lvl = 0; lvl < desc.mipmapLevelCount; lvl++) {
        size += ((w + pf.blockWidth - 1) / pf.blockWidth) * ((h + pf.blockHeight - 1) / pf.blockHeight) * pf.bytesPerBlock * d;
        w = MAX(w / 2, 1); h = MAX(h / 2, 1); d = MAX(d / 2, 1);
    }
    NSUInteger slices = desc.arrayLength * (desc.textureType == MTLTextureTypeCube || desc.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    return (MTLSizeAndAlign){ (size * slices * desc.sampleCount + 4095) & ~(NSUInteger)4095, 4096 };
}
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)desc {
    return (id<MTLSamplerState>)[[VMSamplerState alloc] initWithDevice:self samplerDescriptor:desc];
}
- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)desc {
    return (id<MTLDepthStencilState>)[[VMDepthStencilState alloc] initWithDevice:self depthStencilDescriptor:desc];
}
- (id<MTLFence>)newFence {
    // One serial GPU queue: fences between encoders of a queue are implied by submission order.
    return (id<MTLFence>)[[TSMtlInert alloc] initWithDevice:self protocols:@[@protocol(MTLFence)]];
}
- (id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)desc { return [[VMHeap alloc] initWithDevice:self descriptor:desc]; }

#pragma mark Pipelines

- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)desc error:(NSError **)error {
    return [[VMRenderPipelineState alloc] initWithDevice:self descriptor:desc error:error];
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)desc options:(MTLPipelineOption)options
                                                        reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error {
    if (reflection) *reflection = nil;
    return [self newRenderPipelineStateWithDescriptor:desc error:error];
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)desc completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        id<MTLRenderPipelineState> state = [self newRenderPipelineStateWithDescriptor:desc error:&error];
        handler(state, error);
    });
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)desc options:(MTLPipelineOption)options
                           completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        id<MTLRenderPipelineState> state = [self newRenderPipelineStateWithDescriptor:desc error:&error];
        handler(state, nil, error);
    });
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError **)error {
    return [[VMComputePipelineState alloc] initWithDevice:self function:function error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function options:(MTLPipelineOption)options
                                                        reflection:(MTLAutoreleasedComputePipelineReflection *)reflection error:(NSError **)error {
    if (reflection) *reflection = nil;
    return [self newComputePipelineStateWithFunction:function error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)desc options:(MTLPipelineOption)options
                                                          reflection:(MTLAutoreleasedComputePipelineReflection *)reflection error:(NSError **)error {
    if (reflection) *reflection = nil;
    return [self newComputePipelineStateWithFunction:desc.computeFunction error:error];
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)function completionHandler:(MTLNewComputePipelineStateCompletionHandler)handler {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        id<MTLComputePipelineState> s = [self newComputePipelineStateWithFunction:function error:&error];
        handler(s, error);
    });
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)function options:(MTLPipelineOption)options
                          completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)handler {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        id<MTLComputePipelineState> s = [self newComputePipelineStateWithFunction:function error:&error];
        handler(s, nil, error);
    });
}
// Archives hold native binaries of other GPUs: refuse files (clients compile instead), as metal-shim does.
- (id<MTLBinaryArchive>)newBinaryArchiveWithDescriptor:(MTLBinaryArchiveDescriptor *)desc error:(NSError **)error {
    if (!desc.url) return [super newBinaryArchiveWithDescriptor:desc error:error];
    if (error)
        *error = [NSError errorWithDomain:MTLBinaryArchiveDomain code:MTLBinaryArchiveErrorInvalidFile
                                 userInfo:@{NSLocalizedDescriptionKey: @"Binary archives are not supported; functions are compiled instead"}];
    return nil;
}
- (id<MTLIndirectCommandBuffer>)newIndirectCommandBufferWithDescriptor:(MTLIndirectCommandBufferDescriptor *)desc
                                                       maxCommandCount:(NSUInteger)count options:(MTLResourceOptions)options {
    return (id<MTLIndirectCommandBuffer>)[[TSMtlInert alloc] initWithDevice:self protocols:@[@protocol(MTLIndirectCommandBuffer)]];
}

#pragma mark Commands

- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(MTLCommandQueueDescriptor *)desc {
    return [[VMCommandQueue alloc] initWithDevice:self descriptor:desc];
}
- (id<MTLCommandQueue>)newCommandQueue { return [self newCommandQueueWithDescriptor:[MTLCommandQueueDescriptor new]]; }
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count {
    MTLCommandQueueDescriptor *desc = [MTLCommandQueueDescriptor new];
    desc.maxCommandBufferCount = count;
    return [self newCommandQueueWithDescriptor:desc];
}
@end

#pragma mark - Heap (placement not emulated: each sub-allocation is an ordinary resource)

@implementation VMHeap {
    MTLHeapDescriptor *_desc;
    _Atomic int64_t _used;
}
- (instancetype)initWithDevice:(VMDevice *)device descriptor:(MTLHeapDescriptor *)desc {
    if ((self = [super initWithDevice:device protocols:@[@protocol(MTLHeap)]])) _desc = [desc copy];
    return self;
}
- (MTLStorageMode)storageMode { return _desc.storageMode; }
- (MTLCPUCacheMode)cpuCacheMode { return _desc.cpuCacheMode; }
- (MTLHazardTrackingMode)hazardTrackingMode { return _desc.hazardTrackingMode; }
- (MTLResourceOptions)resourceOptions { return _desc.resourceOptions; }
- (MTLHeapType)type { return _desc.type; }
- (NSUInteger)size { return _desc.size; }
- (NSUInteger)usedSize { return (NSUInteger)atomic_load(&_used); }
- (NSUInteger)currentAllocatedSize { return _desc.size; }
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)alignment {
    int64_t left = (int64_t)_desc.size - atomic_load(&_used);
    return left > 0 ? (NSUInteger)left & ~(alignment ? alignment - 1 : 0) : 0;
}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return MTLPurgeableStateNonVolatile; }
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    atomic_fetch_add(&_used, (int64_t)length);
    return [self.device newBufferWithLength:length options:options];
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset {
    return [self newBufferWithLength:length options:options];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc {
    atomic_fetch_add(&_used, (int64_t)[self.device heapTextureSizeAndAlignWithDescriptor:desc].size);
    return [self.device newTextureWithDescriptor:desc];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc offset:(NSUInteger)offset {
    return [self newTextureWithDescriptor:desc];
}
@end

#pragma mark - Entry points for tests and tools

id<MTLDevice> VMCreateDevice(void) NS_RETURNS_RETAINED;
id<MTLDevice> VMCreateDevice(void) { return [[VMDevice alloc] initWithDriver:NULL]; }
// metal-shim's test entry points, so its test suite runs unchanged on this driver.
id<MTLDevice> TSMtlCreateDevice(void) NS_RETURNS_RETAINED;
id<MTLDevice> TSMtlCreateDevice(void) { return VMCreateDevice(); }
void TSMtlRegisterGLSL(NSString *functionName, NSString *source) { (void)functionName; (void)source; }
