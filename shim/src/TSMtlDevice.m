// TeraScale Metal Shim - the device. _MTLDevice already implements libraries,
// functions, pipelines plumbing and family queries; we supply the driver part
// (resources, queues, limits), following what AppleParavirtDevice overrides.
#import "TSPrivate.h"
#import "TSMetal.h"
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <stdatomic.h>

@interface TSMtlHeap : TSMtlInert <MTLHeap>
- (instancetype)initWithDevice:(TSMtlDevice *)device descriptor:(MTLHeapDescriptor *)desc;
@end

// Work waiting for the GL commands before its fence to execute on the GPU.
@interface TSGPUCompletion : NSObject {
@public
    GLsync fence;
    void *clEvent;   // OpenCL runs of the command buffer (TSMtlComputeTakeRunEvent)
    dispatch_block_t work;
}
@end
@implementation TSGPUCompletion
@end

// Implemented by _MTLDevice (checked at runtime on macOS 26), not declared in its header.
@interface _MTLDevice (TSLibraries)
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error;
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error;
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error;
@end

@implementation TSMtlDevice {
    TSGLInfo _gl;
    NSString *_name;
    uint64_t _registryID;
    io_service_t _accelerator;
    _Atomic int64_t _allocated;
    CGLContextObj _glContext;
    uint64_t _executionEpoch;
    NSMutableArray<dispatch_block_t> *_postFlush;   // GPU queue only
    NSMutableArray<TSGPUCompletion *> *_pending;   // GPU queue only, in fence order
    BOOL _pollScheduled;
    id _acceleratorServiceObject;   // MTLIOAccelService, when Metal.framework created us (Phase 4)
}

static const void *const TSGPUQueueKey = &TSGPUQueueKey;

+ (void)initialize {
    if (self != [TSMtlDevice class]) return;
    TSMtlInstallCatchAll(self);
    // MTLAddDevice asserts this for driver devices; methods we lack are answered by the catch-all.
    Protocol *spi = objc_getProtocol("MTLDeviceSPI");
    if (spi) class_addProtocol(self, spi);
}

// The IOAccelerator of the GL renderer (first IOAccelerator if the renderer gave no ID). Kept for
// the device lifetime: SkyLight (CGDirectDisplayCopyCurrentMetalDevice, used by VectorKit) picks
// the device whose -acceleratorPort is the same Mach port name as the display's accelerator.
static io_service_t TSAcceleratorService(uint64_t registryID) {
    io_service_t svc = registryID ? IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID)) : 0;
    return svc ? svc : IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
}

// CoreImage moves its kernels to Metal as soon as it finds a device. Its CIKL kernels
// (+[CIKernel kernelWithString:], e.g. ImageKit's alpha clamp in Preview) then need argument
// reflection from -[MTLCompiler reflectionWithFunction:...], i.e. from the driver compiler plugin
// we do not have: the reflection comes back empty and CIKernelReflection::consolidate writes
// through a null vector (Preview segfaulted on every image). Compute never runs here either.
// CI_ENABLE_METAL_GPU=0 keeps CoreImage on the OpenGL/CPU path it used before the shim.
// CoreImage reads the variable once, before its first device lookup, so this only helps when
// something else (CoreAnimation, in apps) created the device first. An explicit value wins.
static void TSDisableCoreImageMetal(void) {
    if (setenv("CI_ENABLE_METAL_GPU", "0", 0) == 0 && !strcmp(getenv("CI_ENABLE_METAL_GPU"), "0"))
        TSMtlLog(@"CoreImage Metal path disabled (CI_ENABLE_METAL_GPU=0)");
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    TSMtlInstallLayerTuning();
    TSDisableCoreImageMetal();
    _glContext = TSGLCreateContext(&_gl);
    if (!_glContext) {
        TSMtlError(@"OpenGL 4.1 core context unavailable, using conservative limits");
        snprintf(_gl.renderer, sizeof _gl.renderer, "TeraScale");
        _gl.maxTextureSize = 8192; _gl.max3DTextureSize = 2048; _gl.maxCubeMapSize = 8192; _gl.maxArrayLayers = 2048;
        _gl.maxColorAttachments = 8; _gl.maxSamples = 4; _gl.maxVertexAttribs = 16; _gl.maxVaryingComponents = 64;
        _gl.maxTextureBufferSize = 1 << 24; _gl.maxPointSize = 64; _gl.maxLineWidth = 1;
    }
    _name = [NSString stringWithUTF8String:_gl.renderer];
    _accelerator = TSAcceleratorService(_gl.registryID);
    if (_accelerator) IORegistryEntryGetRegistryEntryID(_accelerator, &_registryID);
    _gpuQueue = dispatch_queue_create("com.terascale.mtlshim.gpu", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_gpuQueue, TSGPUQueueKey, (__bridge void *)self, NULL);
    [self fillLimits];
    [self initGPUFamilySupport];
    TSMtlLog(@"device ready: %@ (VRAM %llu MB, registryID 0x%llx)", _name, _gl.vramBytes >> 20, _registryID);
    return self;
}

- (void)dealloc {
    if (_accelerator) IOObjectRelease(_accelerator);
    free(_passCache);   // its GL objects go with the context
}

// Writes the base class _limits struct; the base answers several limit queries from it.
- (void)fillLimits {
    Ivar limitsIvar = class_getInstanceVariable([_MTLDevice class], "_limits");
    Ivar nextIvar = class_getInstanceVariable([_MTLDevice class], "_serialQueue");
    if (!limitsIvar || !nextIvar || ivar_getOffset(nextIvar) - ivar_getOffset(limitsIvar) != sizeof(TSMtlLimits)) {
        TSMtlWarn(@"_MTLDevice _limits layout changed, limits not written");
        return;
    }
    TSMtlLimits *l = (TSMtlLimits *)((uint8_t *)(__bridge void *)self + ivar_getOffset(limitsIvar));
    memset(l, 0, sizeof *l);
    // Binding counts are the Metal Mac2 values apps assume; the shader translator remaps them onto GL units.
    l->maxColorAttachments = MIN(_gl.maxColorAttachments, 8);
    l->maxVertexAttributes = MIN(_gl.maxVertexAttribs, 31);
    l->maxVertexBuffers = l->maxFragmentBuffers = l->maxComputeBuffers = 31;
    l->maxVertexTextures = l->maxFragmentTextures = l->maxComputeTextures = 128;
    l->maxVertexSamplers = l->maxFragmentSamplers = l->maxComputeSamplers = 16;
    l->maxVertexInlineDataSize = l->maxFragmentInlineDataSize = l->maxComputeInlineDataSize = 4096;
    l->maxInterpolants = MAX(_gl.maxVaryingComponents / 4, 16);
    l->maxInterpolatedComponents = MAX(_gl.maxVaryingComponents, 64);
    l->maxComputeLocalMemorySizes = l->maxComputeThreadgroupMemory = 32768;
    l->maxTotalComputeThreadsPerThreadgroup = 1024;
    l->maxComputeThreadgroupMemoryAlignmentBytes = 16;
    l->maxLineWidth = _gl.maxLineWidth;
    l->maxPointSize = _gl.maxPointSize;
    l->maxVisibilityQueryOffset = 65528;
    l->minConstantBufferAlignmentBytes = 256;
    l->minBufferNoCopyAlignmentBytes = 4096;
    l->maxTextureWidth1D = l->maxTextureWidth2D = l->maxTextureHeight2D = _gl.maxTextureSize;
    l->maxTextureWidth3D = l->maxTextureHeight3D = l->maxTextureDepth3D = _gl.max3DTextureSize;
    l->maxTextureDimensionCube = _gl.maxCubeMapSize;
    l->maxTextureLayers = _gl.maxArrayLayers;
    l->linearTextureAlignmentBytes = l->linearTextureArrayAlignmentBytes = 256;
    l->iosurfaceTextureAlignmentBytes = l->iosurfaceReadOnlyTextureAlignmentBytes = 256;
    l->deviceLinearTextureAlignmentBytes = l->deviceLinearReadOnlyTextureAlignmentBytes = 256;
    l->maxFunctionConstantIndices = 65536;
    l->maxTessellationFactor = 64;
    l->maxIndirectBuffers = 31; l->maxIndirectTextures = 128; l->maxIndirectSamplers = 16;
    l->maxIndirectSamplersPerDevice = 2048;
    l->maxFenceInstances = 16384;
    l->maxViewportCount = 1;
    l->maxVertexAmplificationFactor = l->maxVertexAmplificationCount = 1;
    l->maxTextureBufferWidth = _gl.maxTextureBufferSize;
    l->maxComputeAttributes = 31;
    l->maxIOCommandsInFlight = 16;
    l->maxConstantBufferArguments = 31;
    l->maxBufferLength = self.maxBufferLength;
}

- (void)trackAllocation:(int64_t)delta {
    atomic_fetch_add(&_allocated, delta);
    atomic_fetch_add_explicit(&gTSMtlAllocatedBytes, delta, memory_order_relaxed);
}

- (CGLContextObj)glContext { return _glContext; }
- (const TSGLInfo *)glInfo { return &_gl; }
- (uint64_t)executionEpoch { return _executionEpoch; }
- (BOOL)isOnGPUQueue { return dispatch_get_specific(TSGPUQueueKey) == (__bridge void *)self; }

- (void)addPostFlushWork:(dispatch_block_t)work {
    if (!_postFlush) _postFlush = [NSMutableArray array];
    [_postFlush addObject:work];
}

- (void)runPostFlushWork {
    if (!_postFlush.count) return;
    NSArray<dispatch_block_t> *work = _postFlush;
    _postFlush = nil;
    for (dispatch_block_t w in work) w();
}

- (NSArray<dispatch_block_t> *)takePostFlushWork {
    NSArray<dispatch_block_t> *work = _postFlush;
    _postFlush = nil;
    return work;
}

// The driver runs GL commands after glFlush returns; completion handlers and shared event
// signals must wait for the GPU, or clients recycle resources the GPU still reads (B2).
- (void)afterGPUCompletes:(dispatch_block_t)work {
    [self afterGPUCompletes:work clEvent:NULL];
}

- (void)afterGPUCompletes:(dispatch_block_t)work clEvent:(void *)clEvent {
    TSMtlComputeJoin();   // B4: no flush before an asynchronous end of an OpenCL run is submitted
    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    glFlush();
    if (!fence && !clEvent) { work(); return; }
    if (!_pending) _pending = [NSMutableArray array];
    TSGPUCompletion *c = [TSGPUCompletion new];
    c->fence = fence;
    c->clEvent = clEvent;
    c->work = work;
    [_pending addObject:c];
    [self pollCompletions];
}

// Non-blocking: reports, in order, every completion whose fence has passed; while some are
// left it polls again shortly (a command buffer submitted meanwhile also polls).
- (void)pollCompletions {
    while (_pending.count) {
        TSGPUCompletion *c = _pending[0];
        // A failed wait completes too: never leave a command buffer pending forever.
        if (c->fence && glClientWaitSync(c->fence, 0, 0) == GL_TIMEOUT_EXPIRED) break;
        if (c->fence) glDeleteSync(c->fence);
        c->fence = NULL;
        if (c->clEvent && !TSMtlComputeEventDone(c->clEvent)) break;
        TSMtlComputeEventRelease(c->clEvent);
        c->clEvent = NULL;
        [_pending removeObjectAtIndex:0];
        c->work();
    }
    if (!_pending.count || _pollScheduled) return;
    _pollScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_USEC), _gpuQueue, ^{
        self->_pollScheduled = NO;
        if (CGLGetCurrentContext() != self->_glContext) CGLSetCurrentContext(self->_glContext);
        [self pollCompletions];
    });
}

- (void)beginExecution {
    if (CGLGetCurrentContext() != _glContext) CGLSetCurrentContext(_glContext);
    _executionEpoch++;
    TSMtlDrawTraceTick();
}

- (void)gpuSync:(dispatch_block_t)block {
    if (self.isOnGPUQueue) { block(); return; }
    dispatch_sync(_gpuQueue, ^{
        CGLSetCurrentContext(self->_glContext);
        block();
    });
}

- (void)gpuAsync:(dispatch_block_t)block {
    dispatch_async(_gpuQueue, ^{
        CGLSetCurrentContext(self->_glContext);
        block();
    });
}

#pragma mark Identity and limits

- (NSString *)name { return _name; }
- (NSString *)familyName { return @"TeraScale"; }
- (NSString *)productName { return _name; }
- (NSString *)vendorName { return @"AMD"; }
- (unsigned long long)featureProfile { return TSMtlFeatureProfileMac2; }
- (uint64_t)registryID { return _registryID; }
- (unsigned int)acceleratorPort { return _accelerator; }
- (void)_setAcceleratorService:(id)service { _acceleratorServiceObject = service; }
- (uint64_t)dedicatedMemorySize { return _gl.vramBytes; }
- (uint64_t)sharedMemorySize { return 0; }
- (BOOL)metalAssertionsEnabled { return NO; }
- (void)setMetalAssertionsEnabled:(BOOL)enabled {}
- (MTLDeviceLocation)location { return MTLDeviceLocationBuiltIn; }
- (NSUInteger)locationNumber { return 0; }
- (BOOL)isLowPower { return NO; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }
- (BOOL)hasUnifiedMemory { return NO; }
- (uint64_t)maxTransferRate { return 0; }
- (uint64_t)peerGroupID { return 0; }
- (uint32_t)peerIndex { return 0; }
- (uint32_t)peerCount { return 0; }
- (uint64_t)recommendedMaxWorkingSetSize { return _gl.vramBytes ? _gl.vramBytes : 512ull << 20; }
- (NSUInteger)currentAllocatedSize { return (NSUInteger)MAX(atomic_load(&_allocated), 0); }
- (NSUInteger)maxBufferLength { return MAX(self.recommendedMaxWorkingSetSize / 2, 256ull << 20); }
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(1024, 1024, 64); }
- (NSUInteger)maxThreadgroupMemoryLength { return 32768; }
- (BOOL)isDepth24Stencil8PixelFormatSupported { return YES; }
- (BOOL)supportsSampleCount:(NSUInteger)count { return count == 1 || (count <= (NSUInteger)_gl.maxSamples && (count & (count - 1)) == 0); }
- (BOOL)supportsTextureSampleCount:(NSUInteger)count { return [self supportsSampleCount:count]; }
- (BOOL)supportsVertexAmplificationCount:(NSUInteger)count { return count == 1; }
- (BOOL)supportsBCTextureCompression { return YES; }
- (BOOL)isBCTextureCompressionSupported { return YES; }
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
- (MTLReadWriteTextureTier)readWriteTextureSupport { return MTLReadWriteTextureTierNone; }
- (MTLArgumentBuffersTier)argumentBuffersSupport { return MTLArgumentBuffersTier1; }
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(MTLPixelFormat)format { return 256; }
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)format { return 256; }
- (MTLSize)sparseTileSizeWithTextureType:(MTLTextureType)t pixelFormat:(MTLPixelFormat)f sampleCount:(NSUInteger)s { return MTLSizeMake(0, 0, 0); }
- (MTLSize)sparseTileSizeWithTextureType:(MTLTextureType)t pixelFormat:(MTLPixelFormat)f sampleCount:(NSUInteger)s sparsePageSize:(MTLSparsePageSize)p { return MTLSizeMake(0, 0, 0); }

#pragma mark Resources

- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    return [[TSMtlBuffer alloc] initWithDevice:self length:length options:options bytes:NULL deallocator:nil];
}

- (id<MTLBuffer>)newBufferWithBytes:(const void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options {
    TSMtlBuffer *b = [[TSMtlBuffer alloc] initWithDevice:self length:length options:options bytes:NULL deallocator:nil];
    if (b && pointer) memcpy(b.contents, pointer, length);
    return b;
}

- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options
                              deallocator:(void (^)(void *, NSUInteger))deallocator {
    return [[TSMtlBuffer alloc] initWithDevice:self length:length options:options bytes:pointer deallocator:deallocator];
}

- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc {
    return [[TSMtlTexture alloc] initWithDevice:self descriptor:desc iosurface:NULL plane:0];
}

- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane {
    if (gTSMtlTraceOn && surface) {
        OSType cc = IOSurfaceGetPixelFormat(surface);
        TSMtlTraceOnce(@"iosurface texture fmt%lu usage 0x%lx %lux%lu surface '%c%c%c%c' %zux%zu plane %lu/%zu", (unsigned long)desc.pixelFormat,
                       (unsigned long)desc.usage, (unsigned long)desc.width, (unsigned long)desc.height,
                       (char)(cc >> 24), (char)(cc >> 16), (char)(cc >> 8), (char)cc,
                       IOSurfaceGetWidthOfPlane(surface, plane), IOSurfaceGetHeightOfPlane(surface, plane), (unsigned long)plane,
                       IOSurfaceGetPlaneCount(surface));
    }
    return [[TSMtlTexture alloc] initWithDevice:self descriptor:desc iosurface:surface plane:plane];
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
    return (id<MTLSamplerState>)[[TSMtlSamplerState alloc] initWithDevice:self samplerDescriptor:desc];
}

- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)desc {
    return (id<MTLDepthStencilState>)[[TSMtlDepthStencilState alloc] initWithDevice:self depthStencilDescriptor:desc];
}

- (id<MTLFence>)newFence {
    return (id<MTLFence>)[[TSMtlInert alloc] initWithDevice:self protocols:@[@protocol(MTLFence)]];
}

- (id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)desc {
    return [[TSMtlHeap alloc] initWithDevice:self descriptor:desc];
}

#pragma mark Libraries

// TSMTL_DUMP_DIR=<dir> saves every MSL source an app compiles (to study what to translate).
static void TSDumpSource(NSString *source) {
    const char *dir = getenv("TSMTL_DUMP_DIR");
    if (!dir || !source) return;
    static int counter;
    NSString *path = [NSString stringWithFormat:@"%s/%s-%d.metal", dir, getprogname(), __sync_fetch_and_add(&counter, 1)];
    [source writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    TSMtlLog(@"MSL source saved to %@", path);
}

// TeraScale Compute (A5): libraries holding kernels known to be created at a bad moment get their OpenCL
// kernels translated and built in the background as soon as they load (TSMtlComputePrewarmLibrary).
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options error:(NSError **)error {
    TSDumpSource(source);
    id<MTLLibrary> lib = [super newLibraryWithSource:source options:options error:error];
    TSMtlComputePrewarmLibrary(self, lib);
    return lib;
}

- (void)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options completionHandler:(MTLNewLibraryCompletionHandler)handler {
    TSDumpSource(source);
    __weak TSMtlDevice *weakSelf = self;
    [super newLibraryWithSource:source options:options completionHandler:^(id<MTLLibrary> lib, NSError *error) {
        TSMtlComputePrewarmLibrary(weakSelf, lib);
        handler(lib, error);
    }];
}

- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error {
    id<MTLLibrary> lib = [super newLibraryWithURL:url error:error];
    TSMtlComputePrewarmLibrary(self, lib);
    return lib;
}

- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    id<MTLLibrary> lib = [super newLibraryWithData:data error:error];
    TSMtlComputePrewarmLibrary(self, lib);
    return lib;
}

- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error {
    id<MTLLibrary> lib = [super newDefaultLibraryWithBundle:bundle error:error];
    TSMtlComputePrewarmLibrary(self, lib);
    return lib;
}

#pragma mark Pipelines
// The base class would hand the AIR to a driver compiler plugin we do not have;
// pipelines are built here from GLSL instead (TSMtlPipeline.m).

- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)desc error:(NSError **)error {
    return [[TSMtlRenderPipelineState alloc] initWithDevice:self descriptor:desc error:error];
}

- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)desc options:(MTLPipelineOption)options
                                                        reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error {
    if (reflection) *reflection = nil;
    return [self newRenderPipelineStateWithDescriptor:desc error:error];
}

- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)desc completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler {
    NSError *error = nil;
    id<MTLRenderPipelineState> state = [self newRenderPipelineStateWithDescriptor:desc error:&error];
    handler(state, error);
}

- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)desc options:(MTLPipelineOption)options
                           completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler {
    NSError *error = nil;
    id<MTLRenderPipelineState> state = [self newRenderPipelineStateWithDescriptor:desc error:&error];
    handler(state, nil, error);
}

// GL 4.1 has no compute shaders: the pipeline always exists so apps can proceed, and runs only with
// TeraScale Compute on and a kernel that works as a fragment shader (TSMtlComputePipelineState).
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError **)error {
    return [[TSMtlComputePipelineState alloc] initWithDevice:self function:function];
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

// A4: the asynchronous variants build on a background queue (an OpenCL build can take 90-400 ms) and call the
// handler there, as Metal does from its compiler threads.
static dispatch_queue_t TSPipelineQueue(void) {
    return dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
}

- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)function completionHandler:(MTLNewComputePipelineStateCompletionHandler)handler {
    dispatch_async(TSPipelineQueue(), ^{ handler([self newComputePipelineStateWithFunction:function error:NULL], nil); });
}

- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)function options:(MTLPipelineOption)options
                          completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)handler {
    dispatch_async(TSPipelineQueue(), ^{ handler([self newComputePipelineStateWithFunction:function error:NULL], nil, nil); });
}

- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)desc options:(MTLPipelineOption)options
                            completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)handler {
    id<MTLFunction> function = desc.computeFunction;
    dispatch_async(TSPipelineQueue(), ^{ handler([self newComputePipelineStateWithFunction:function error:NULL], nil, nil); });
}

// Loading an archive asks -targetDeviceArchitecture for the GPU slice to read, and Metal asserts
// when it is nil (the _MTLDevice default): RenderBox (SwiftUI effects in Spotlight) aborted on its
// archive.metallib. Archives hold native GPU binaries the GLSL pipelines could never use, and an
// empty archive never serializes here, so every file is foreign: refuse it as the API allows.
// Clients fall back to compiling (RenderBox reports it as non-fatal). Empty archives stay as they were.
- (id<MTLBinaryArchive>)newBinaryArchiveWithDescriptor:(MTLBinaryArchiveDescriptor *)desc error:(NSError **)error {
    if (!desc.url) return [super newBinaryArchiveWithDescriptor:desc error:error];
    TSMtlLog(@"binary archive %@ not loaded: no native binaries on this device", desc.url.path);
    if (error)
        *error = [NSError errorWithDomain:MTLBinaryArchiveDomain code:MTLBinaryArchiveErrorInvalidFile
                                 userInfo:@{NSLocalizedDescriptionKey: @"Binary archives are not supported on the TeraScale shim; functions are compiled instead"}];
    return nil;
}

- (id<MTLIndirectCommandBuffer>)newIndirectCommandBufferWithDescriptor:(MTLIndirectCommandBufferDescriptor *)desc
                                                       maxCommandCount:(NSUInteger)count options:(MTLResourceOptions)options {
    return (id<MTLIndirectCommandBuffer>)[[TSMtlInert alloc] initWithDevice:self protocols:@[@protocol(MTLIndirectCommandBuffer)]];
}

#pragma mark Commands

- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(MTLCommandQueueDescriptor *)desc {
    return [[TSMtlCommandQueue alloc] initWithDevice:self descriptor:desc];
}

- (id<MTLCommandQueue>)newCommandQueue {
    return [self newCommandQueueWithDescriptor:[MTLCommandQueueDescriptor new]];
}

- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count {
    MTLCommandQueueDescriptor *desc = [MTLCommandQueueDescriptor new];
    desc.maxCommandBufferCount = count;
    return [self newCommandQueueWithDescriptor:desc];
}

@end

#pragma mark - Heap

// Placement is not emulated: each sub-allocation is an ordinary resource, the heap
// only keeps the accounting apps look at.
@implementation TSMtlHeap {
    MTLHeapDescriptor *_desc;
    _Atomic int64_t _used;
}
- (instancetype)initWithDevice:(TSMtlDevice *)device descriptor:(MTLHeapDescriptor *)desc {
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
- (MTLResourceOptions)optionsForResource:(MTLResourceOptions)options {
    return (options & ~(MTLResourceStorageModeMask | MTLResourceCPUCacheModeMask)) | (_desc.resourceOptions & (MTLResourceStorageModeMask | MTLResourceCPUCacheModeMask));
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    atomic_fetch_add(&_used, (int64_t)length);
    return [self.device newBufferWithLength:length options:[self optionsForResource:options]];
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

