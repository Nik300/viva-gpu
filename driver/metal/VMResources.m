// Viva Metal - buffers, textures, samplers and depth/stencil states on vmg.
// Buffers live in GPU-visible memory mapped persistently into the process: -contents is that mapping, no copies
// (unlike metal-shim's GL path). Textures are Gallium resources; CPU access (replaceRegion, getBytes) goes through
// the GPU queue, ordered after the work submitted before it.
#import "VMPrivate.h"
#import <stdatomic.h>

#define VM_CATCH_ALL(cls) + (void)initialize { if (self == [cls class]) TSMtlInstallCatchAll(self); }

#pragma mark - Buffer

@implementation VMBuffer {
    __weak VMDevice *_device;
    VMDevice *_strongDevice;   // keeps the vmg device alive until the resource is released on its queue
    NSUInteger _length;
    MTLResourceOptions _options;
    void *_contents;
    void (^_deallocator)(void *, NSUInteger);
    void *_userBytes;
}
VM_CATCH_ALL(VMBuffer)

- (instancetype)initWithDevice:(VMDevice *)device length:(NSUInteger)length options:(MTLResourceOptions)options
                         bytes:(void *)bytes deallocator:(void (^)(void *, NSUInteger))deallocator {
    if (!(self = [super init])) return nil;
    _device = _strongDevice = device;
    _length = length;
    _options = options;
    _userBytes = bytes;
    _deallocator = [deallocator copy];
    __block void *contents = NULL;
    __block vmg_resource *r = NULL;
    [device gpuSync:^{ r = vmg_buffer_create(device.vmg, MAX(length, 1), bytes, &contents); }];   // maps through the pipe_context
    _vmg = r;
    if (!_vmg) return nil;
    _contents = contents;
    [device trackAllocation:(int64_t)length];
    return self;
}

- (void)dealloc {
    vmg_resource *r = _vmg;
    VMDevice *d = _strongDevice;
    if (r && d) [d gpuAsync:^{ vmg_resource_release(d.vmg, r); }];
    [d trackAllocation:-(int64_t)_length];
    if (_deallocator) _deallocator(_userBytes, _length);
}

- (id<MTLDevice>)device { return _device; }
- (NSUInteger)length { return _length; }
- (void *)contents { return _contents; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)((_options & MTLResourceCPUCacheModeMask) >> MTLResourceCPUCacheModeShift); }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (NSUInteger)allocatedSize { return _length; }
- (void)didModifyRange:(NSRange)range {}   // coherent mapping
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return MTLPurgeableStateNonVolatile; }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable {}
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (uint64_t)gpuAddress { return (uint64_t)(uintptr_t)_contents; }   // Metal 3 API (not in Apple4): unique and non-zero
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bpr {
    return [[VMTexture alloc] initWithDevice:_device descriptor:desc buffer:self offset:offset bytesPerRow:bpr];
}
@end

#pragma mark - Texture

static enum vmg_texture_type VMTextureType(MTLTextureType t, NSUInteger samples) {
    switch (t) {
    case MTLTextureType1D: return VMG_TEX_1D;
    case MTLTextureType1DArray: return VMG_TEX_1D_ARRAY;
    case MTLTextureType2DArray: return VMG_TEX_2D_ARRAY;
    case MTLTextureType2DMultisample: return VMG_TEX_2D_MS;
    case MTLTextureType2DMultisampleArray: return VMG_TEX_2D_MS_ARRAY;
    case MTLTextureTypeCube: return VMG_TEX_CUBE;
    case MTLTextureTypeCubeArray: return VMG_TEX_CUBE_ARRAY;
    case MTLTextureType3D: return VMG_TEX_3D;
    case MTLTextureTypeTextureBuffer: return VMG_TEX_BUFFER;
    default: return samples > 1 ? VMG_TEX_2D_MS : VMG_TEX_2D;
    }
}

static vmg_texture_desc VMTextureDesc(MTLTextureDescriptor *d) {
    vmg_texture_desc t = {0};
    t.type = VMTextureType(d.textureType, d.sampleCount);
    t.mtl_format = (unsigned)d.pixelFormat;
    t.width = (uint32_t)d.width; t.height = (uint32_t)d.height; t.depth = (uint32_t)d.depth;
    t.array_length = (uint32_t)d.arrayLength; t.mip_levels = (uint32_t)d.mipmapLevelCount; t.samples = (uint32_t)d.sampleCount;
    t.render_target = (d.usage & MTLTextureUsageRenderTarget) != 0 || d.usage == MTLTextureUsageUnknown;
    t.shader_write = (d.usage & MTLTextureUsageShaderWrite) != 0;
    t.memoryless = d.storageMode == MTLStorageModeMemoryless;
    return t;
}

@implementation VMTexture {
    __weak VMDevice *_device;
    VMDevice *_strongDevice;
    MTLTextureDescriptor *_desc;
    IOSurfaceRef _surface;
    NSUInteger _plane;
    VMTexture *_parent;
    VMBuffer *_buffer;
    NSUInteger _bufferOffset, _bufferBytesPerRow;
    NSUInteger _parentLevel, _parentSlice;
    MTLTextureSwizzleChannels _swizzle;
}
VM_CATCH_ALL(VMTexture)

- (instancetype)initWithDevice:(VMDevice *)device descriptor:(MTLTextureDescriptor *)desc iosurface:(IOSurfaceRef)surface
                         plane:(NSUInteger)plane {
    if (!(self = [super init])) return nil;
    _device = _strongDevice = device;
    _desc = [desc copy];
    _swizzle = desc.swizzle;
    vmg_texture_desc td = VMTextureDesc(desc);
    if (surface) {
        _surface = (IOSurfaceRef)CFRetain(surface);
        _plane = plane;
        __block vmg_texture *t = NULL;
        [device gpuSync:^{ t = vmg_texture_create_iosurface(device.vmg, &td, IOSurfaceGetID(surface), (unsigned)plane); }];
        _vmg = t;
    } else {
        _vmg = vmg_texture_create(device.vmg, &td);
    }
    if (!_vmg) {
        TSMtlError(@"texture %lux%lu format %lu type %lu not created", (unsigned long)desc.width, (unsigned long)desc.height,
                   (unsigned long)desc.pixelFormat, (unsigned long)desc.textureType);
        return nil;
    }
    return self;
}

- (instancetype)initWithDevice:(VMDevice *)device descriptor:(MTLTextureDescriptor *)desc buffer:(VMBuffer *)buffer
                        offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow {
    if (!(self = [super init])) return nil;
    _device = _strongDevice = device;
    _desc = [desc copy];
    _swizzle = desc.swizzle;
    _buffer = buffer; _bufferOffset = offset; _bufferBytesPerRow = bytesPerRow;
    vmg_texture_desc td = VMTextureDesc(desc);
    __block vmg_texture *t = NULL;
    [device gpuSync:^{ t = vmg_texture_create_buffer(device.vmg, &td, buffer.vmg, offset, bytesPerRow); }];
    _vmg = t;
    return _vmg ? self : nil;
}

- (instancetype)initViewOf:(VMTexture *)parent format:(MTLPixelFormat)format type:(MTLTextureType)type levels:(NSRange)levels
                    slices:(NSRange)slices swizzle:(const MTLTextureSwizzleChannels *)swizzle {
    if (!(self = [super init])) return nil;
    _device = _strongDevice = parent->_strongDevice;
    _parent = parent;
    _desc = [parent->_desc copy];
    _desc.pixelFormat = format;
    _desc.textureType = type;
    _desc.mipmapLevelCount = levels.length;
    _desc.width = MAX(parent.width >> levels.location, 1);
    _desc.height = MAX(parent.height >> levels.location, 1);
    if (type == MTLTextureType3D) _desc.depth = MAX(parent.depth >> levels.location, 1);
    NSUInteger faces = type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray ? 6 : 1;
    _desc.arrayLength = MAX(slices.length / faces, 1);
    _parentLevel = levels.location; _parentSlice = slices.location;
    _surface = parent->_surface ? (IOSurfaceRef)CFRetain(parent->_surface) : NULL;
    _plane = parent->_plane;
    _swizzle = swizzle ? *swizzle : parent->_swizzle;
    uint8_t sw[4] = { (uint8_t)_swizzle.red, (uint8_t)_swizzle.green, (uint8_t)_swizzle.blue, (uint8_t)_swizzle.alpha };
    _vmg = vmg_texture_create_view(_device.vmg, parent.vmg, (unsigned)format, VMTextureType(type, _desc.sampleCount),
                                   (uint32_t)levels.location, (uint32_t)levels.length, (uint32_t)slices.location,
                                   (uint32_t)slices.length, swizzle ? sw : NULL);
    return _vmg ? self : nil;
}

- (void)dealloc {
    vmg_texture *t = _vmg;
    VMDevice *d = _strongDevice;
    if (t && d) [d gpuAsync:^{ vmg_texture_release(d.vmg, t); }];
    if (_surface) CFRelease(_surface);
}

- (id<MTLDevice>)device { return _device; }
- (MTLTextureType)textureType { return _desc.textureType; }
- (MTLPixelFormat)pixelFormat { return _desc.pixelFormat; }
- (NSUInteger)width { return _desc.width; }
- (NSUInteger)height { return _desc.height; }
- (NSUInteger)depth { return _desc.depth; }
- (NSUInteger)mipmapLevelCount { return _desc.mipmapLevelCount; }
- (NSUInteger)arrayLength { return _desc.arrayLength; }
- (NSUInteger)sampleCount { return _desc.sampleCount; }
- (MTLTextureUsage)usage { return _desc.usage; }
- (MTLStorageMode)storageMode { return _desc.storageMode; }
- (MTLCPUCacheMode)cpuCacheMode { return _desc.cpuCacheMode; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLResourceOptions)resourceOptions { return _desc.resourceOptions; }
- (BOOL)isFramebufferOnly { return NO; }
- (BOOL)allowGPUOptimizedContents { return YES; }
- (BOOL)isShareable { return NO; }
- (BOOL)isSparse { return NO; }
- (MTLTextureSwizzleChannels)swizzle { return _swizzle; }
- (IOSurfaceRef)iosurface { return _surface; }
- (NSUInteger)iosurfacePlane { return _plane; }
- (id<MTLTexture>)parentTexture { return _parent; }
- (NSUInteger)parentRelativeLevel { return _parentLevel; }
- (NSUInteger)parentRelativeSlice { return _parentSlice; }
- (id<MTLBuffer>)buffer { return _buffer; }
- (NSUInteger)bufferOffset { return _bufferOffset; }
- (NSUInteger)bufferBytesPerRow { return _bufferBytesPerRow; }
- (id<MTLResource>)rootResource { return _parent ? [_parent rootResource] : self; }
- (NSUInteger)allocatedSize { return [_device heapTextureSizeAndAlignWithDescriptor:_desc].size; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return MTLPurgeableStateNonVolatile; }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable {}
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){ (uint64_t)(uintptr_t)(__bridge void *)self }; }

// Slice for 2D regions: array layer / cube face; 3D textures address z through the region.
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)bytes
          bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi {
    if (!bytes || !region.size.width || !region.size.height) return;
    VMDevice *d = _device;
    vmg_texture *t = _vmg;
    [d gpuSync:^{
        vmg_texture_write(d.vmg, t, (unsigned)level, (unsigned)slice, (uint32_t)region.origin.x, (uint32_t)region.origin.y,
                          (uint32_t)region.origin.z, (uint32_t)region.size.width, (uint32_t)region.size.height,
                          (uint32_t)MAX(region.size.depth, 1), bytes, bpr, bpi ? bpi : bpr * region.size.height);
    }];
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)bpr {
    [self replaceRegion:region mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:bpr bytesPerImage:bpr * region.size.height];
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi fromRegion:(MTLRegion)region
     mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {
    if (!bytes || !region.size.width || !region.size.height) return;
    VMDevice *d = _device;
    vmg_texture *t = _vmg;
    [d gpuSync:^{
        vmg_texture_read(d.vmg, t, (unsigned)level, (unsigned)slice, (uint32_t)region.origin.x, (uint32_t)region.origin.y,
                         (uint32_t)region.origin.z, (uint32_t)region.size.width, (uint32_t)region.size.height,
                         (uint32_t)MAX(region.size.depth, 1), bytes, bpr, bpi ? bpi : bpr * region.size.height);
    }];
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level {
    [self getBytes:bytes bytesPerRow:bpr bytesPerImage:bpr * region.size.height fromRegion:region mipmapLevel:level slice:0];
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format {
    NSUInteger faces = _desc.textureType == MTLTextureTypeCube || _desc.textureType == MTLTextureTypeCubeArray ? 6 : 1;
    return [[VMTexture alloc] initViewOf:self format:format type:_desc.textureType levels:NSMakeRange(0, _desc.mipmapLevelCount)
                                  slices:NSMakeRange(0, _desc.arrayLength * faces) swizzle:NULL];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels
                                         slices:(NSRange)slices {
    return [[VMTexture alloc] initViewOf:self format:format type:type levels:levels slices:slices swizzle:NULL];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels
                                         slices:(NSRange)slices swizzle:(MTLTextureSwizzleChannels)swizzle {
    return [[VMTexture alloc] initViewOf:self format:format type:type levels:levels slices:slices swizzle:&swizzle];
}
@end

#pragma mark - Sampler and depth/stencil

@implementation VMSamplerState {
    MTLSamplerDescriptor *_desc;
    VMDevice *_vmDevice;
}
VM_CATCH_ALL(VMSamplerState)

- (instancetype)initWithDevice:(id)device samplerDescriptor:(MTLSamplerDescriptor *)desc {
    if (!(self = [super initWithDevice:device samplerDescriptor:desc])) return nil;
    _desc = [desc copy];
    _vmDevice = device;
    vmg_sampler_desc s = {0};
    s.min_filter = (uint8_t)desc.minFilter;
    s.mag_filter = (uint8_t)desc.magFilter;
    s.mip_filter = (uint8_t)desc.mipFilter;
    s.address[0] = (uint8_t)desc.sAddressMode; s.address[1] = (uint8_t)desc.tAddressMode; s.address[2] = (uint8_t)desc.rAddressMode;
    s.max_anisotropy = (uint8_t)desc.maxAnisotropy;
    s.compare = desc.compareFunction == MTLCompareFunctionNever ? 0 : (uint8_t)desc.compareFunction;
    s.border = (uint8_t)desc.borderColor;
    s.normalized = desc.normalizedCoordinates;
    s.lod_min = desc.lodMinClamp;
    s.lod_max = desc.lodMaxClamp;
    s.lod_average = desc.lodAverage;
    __block vmg_sampler *v = NULL;
    [(VMDevice *)device gpuSync:^{ v = vmg_sampler_create(((VMDevice *)device).vmg, &s); }];
    _vmg = v;
    _lodMin = desc.lodMinClamp;
    _lodMax = desc.lodMaxClamp;
    return self;
}
- (void)dealloc {
    vmg_sampler *s = _vmg;
    VMDevice *d = _vmDevice;
    if (s && d) [d gpuAsync:^{ vmg_sampler_release(d.vmg, s); }];
}
- (id<MTLDevice>)device { return _vmDevice; }
- (NSString *)label { return _desc.label; }
- (MTLSamplerDescriptor *)samplerDescriptor { return _desc; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){ (uint64_t)(uintptr_t)(__bridge void *)self }; }
@end

@implementation VMDepthStencilState {
    MTLDepthStencilDescriptor *_desc;
    VMDevice *_vmDevice;
}
VM_CATCH_ALL(VMDepthStencilState)

static vmg_stencil_face VMStencilFace(MTLStencilDescriptor *s) {
    vmg_stencil_face f = { (uint8_t)s.stencilCompareFunction, (uint8_t)s.stencilFailureOperation,
                           (uint8_t)s.depthFailureOperation, (uint8_t)s.depthStencilPassOperation, s.readMask, s.writeMask };
    return f;
}

- (instancetype)initWithDevice:(id)device depthStencilDescriptor:(MTLDepthStencilDescriptor *)desc {
    if (!(self = [super initWithDevice:device depthStencilDescriptor:desc])) return nil;
    _desc = [desc copy];
    _vmDevice = device;
    vmg_dsa_desc d = {0};
    d.depth_func = (uint8_t)desc.depthCompareFunction;
    d.depth_write = desc.depthWriteEnabled;
    MTLStencilDescriptor *front = desc.frontFaceStencil, *back = desc.backFaceStencil;
    d.stencil = front || back;
    MTLStencilDescriptor *def = [MTLStencilDescriptor new];
    d.front = VMStencilFace(front ?: def);
    d.back = VMStencilFace(back ?: def);
    __block vmg_dsa *v = NULL;
    [(VMDevice *)device gpuSync:^{ v = vmg_dsa_create(((VMDevice *)device).vmg, &d); }];
    _vmg = v;
    return self;
}
- (void)dealloc {
    vmg_dsa *s = _vmg;
    VMDevice *d = _vmDevice;
    if (s && d) [d gpuAsync:^{ vmg_dsa_release(d.vmg, s); }];
}
- (id<MTLDevice>)device { return _vmDevice; }
- (NSString *)label { return _desc.label; }
- (MTLDepthStencilDescriptor *)descriptor { return _desc; }
@end
