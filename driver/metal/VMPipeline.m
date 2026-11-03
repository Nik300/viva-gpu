// Viva Metal - render and compute pipelines: AIR of the functions -> vmg shaders (vmg_air.c) + fixed-function state.
// A pipeline whose functions cannot be translated still exists (never nil, as in metal-shim): its draws/dispatches
// are skipped and -failure says why (logged once).
#import "VMPrivate.h"

#define VM_CATCH_ALL(cls) + (void)initialize { if (self == [cls class]) TSMtlInstallCatchAll(self); }

NSData *VMBitcodeOfFunction(id<MTLFunction> function) {
    if (![(id)function respondsToSelector:@selector(bitcodeData)]) return nil;
    NSData *bitcode = (NSData *)[(id)function performSelector:@selector(bitcodeData)];
    return bitcode.length ? bitcode : nil;
}

// Bitcode of the linked (visible) functions, by name.
static NSDictionary<NSString *, NSData *> *VMLinkedBitcode(MTLLinkedFunctions *lf) {
    if (!lf) return nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSArray<id<MTLFunction>> *list in @[lf.functions ?: @[], lf.privateFunctions ?: @[]])
        for (id<MTLFunction> f in list) {
            NSData *bc = VMBitcodeOfFunction(f);
            if (bc && f.name) d[f.name] = bc;
        }
    return d.count ? d : nil;
}

// Translates one function into a vmg shader on the GPU queue (create_*_state is a context call).
static vmg_shader *VMShaderFor(VMDevice *device, id<MTLFunction> function, MTLLinkedFunctions *linked,
                               NSArray<NSString *> *varyings, const uint32_t *colorFormats, NSString **failure) {
    NSData *bitcode = VMBitcodeOfFunction(function);
    if (!bitcode) { *failure = [NSString stringWithFormat:@"%@: no AIR bitcode", function.name]; return NULL; }
    NSDictionary<NSString *, NSData *> *lb = VMLinkedBitcode(linked);
    NSUInteger nl = lb.count, nv = varyings.count;
    const void **lptr = calloc(nl + 1, sizeof(void *));
    size_t *lsize = calloc(nl + 1, sizeof(size_t));
    const char **lname = calloc(nl + 1, sizeof(char *));
    NSUInteger i = 0;
    for (NSString *name in lb) { lptr[i] = lb[name].bytes; lsize[i] = lb[name].length; lname[i] = name.UTF8String; i++; }
    const char **vk = calloc(nv + 1, sizeof(char *));
    for (i = 0; i < nv; i++) vk[i] = varyings[i].UTF8String;
    vmg_air_input in = { .bitcode = bitcode.bytes, .bitcode_size = bitcode.length, .linked = lptr, .linked_size = lsize,
                         .linked_names = lname, .linked_count = (unsigned)nl, .varyings = vk, .varying_count = (unsigned)nv,
                         .color_formats = colorFormats };
    __block vmg_shader *sh = NULL;
    __block char *error = NULL;
    [device gpuSync:^{ sh = vmg_shader_create(device.vmg, &in, NULL, &error); }];
    if (!sh) *failure = [NSString stringWithFormat:@"%@: %s", function.name, error ? error : "translation failed"];
    free(error);
    free(lptr); free(lsize); free(lname); free(vk);
    return sh;
}

#pragma mark - Render pipeline

@implementation VMRenderPipelineState {
    __weak VMDevice *_device;
    VMDevice *_strongDevice;
    MTLRenderPipelineDescriptor *_desc;
    vmg_shader *_vs, *_fs;
}
VM_CATCH_ALL(VMRenderPipelineState)

- (instancetype)initWithDevice:(VMDevice *)device descriptor:(MTLRenderPipelineDescriptor *)desc error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _device = _strongDevice = device;
    _desc = [desc copy];
    self.label = desc.label;
    NSString *failure = nil;

    // Varying slots: the keys the vertex function writes, in its order (the fragment function looks them up).
    NSMutableArray<NSString *> *varyings = [NSMutableArray array];
    NSData *vbc = desc.vertexFunction ? VMBitcodeOfFunction(desc.vertexFunction) : nil;
    if (vbc) {
        unsigned n = 0;
        char *err = NULL;
        char **keys = vmg_air_vertex_outputs(vbc.bytes, vbc.length, &n, &err);
        for (unsigned i = 0; i < n; i++) { [varyings addObject:@(keys[i])]; free(keys[i]); }
        free(keys); free(err);
    }
    uint32_t formats[VMG_MAX_COLOR] = {0};
    for (unsigned i = 0; i < VMG_MAX_COLOR; i++) formats[i] = (uint32_t)desc.colorAttachments[i].pixelFormat;
    if (!desc.vertexFunction) failure = @"no vertex function";
    if (!failure) _vs = VMShaderFor(device, desc.vertexFunction, desc.vertexLinkedFunctions, varyings, NULL, &failure);
    if (!failure && desc.fragmentFunction)
        _fs = VMShaderFor(device, desc.fragmentFunction, desc.fragmentLinkedFunctions, varyings, formats, &failure);

    if (!failure) {
        vmg_render_pipeline_desc p = {0};
        p.vertex = _vs;
        p.fragment = _fs;
        MTLVertexDescriptor *vd = desc.vertexDescriptor;
        for (unsigned a = 0; a < VMG_MAX_VERTEX_ATTRIBS && vd; a++) {
            MTLVertexAttributeDescriptor *at = vd.attributes[a];
            if (at.format == MTLVertexFormatInvalid) continue;
            p.attrib_mask |= 1u << a;
            p.attribs[a].format = (uint8_t)at.format;
            p.attribs[a].buffer = (uint8_t)at.bufferIndex;
            p.attribs[a].offset = (uint32_t)at.offset;
        }
        for (unsigned b = 0; b < VMG_MAX_BUFFERS && vd; b++) {
            MTLVertexBufferLayoutDescriptor *l = vd.layouts[b];
            p.layouts[b].stride = (uint32_t)l.stride;
            p.layouts[b].step_rate = (uint32_t)l.stepRate;
            p.layouts[b].step_function = (uint8_t)l.stepFunction;
        }
        for (unsigned i = 0; i < VMG_MAX_COLOR; i++) {
            MTLRenderPipelineColorAttachmentDescriptor *c = desc.colorAttachments[i];
            p.color[i].format = (uint32_t)c.pixelFormat;
            p.color[i].enabled = c.blendingEnabled;
            p.color[i].write_mask = (uint8_t)c.writeMask;
            p.color[i].rgb_op = (uint8_t)c.rgbBlendOperation;
            p.color[i].alpha_op = (uint8_t)c.alphaBlendOperation;
            p.color[i].src_rgb = (uint8_t)c.sourceRGBBlendFactor;
            p.color[i].dst_rgb = (uint8_t)c.destinationRGBBlendFactor;
            p.color[i].src_alpha = (uint8_t)c.sourceAlphaBlendFactor;
            p.color[i].dst_alpha = (uint8_t)c.destinationAlphaBlendFactor;
        }
        p.depth_format = (uint32_t)desc.depthAttachmentPixelFormat;
        p.stencil_format = (uint32_t)desc.stencilAttachmentPixelFormat;
        p.samples = (uint32_t)MAX(desc.rasterSampleCount, 1);
        p.alpha_to_coverage = desc.alphaToCoverageEnabled;
        p.alpha_to_one = desc.alphaToOneEnabled;
        p.rasterization_enabled = desc.rasterizationEnabled;
        p.topology_class = (uint8_t)desc.inputPrimitiveTopology;
        __block vmg_render_pipeline *rp = NULL;
        __block char *err = NULL;
        [device gpuSync:^{ rp = vmg_render_pipeline_create(device.vmg, &p, &err); }];
        _vmg = rp;
        if (!rp) failure = [NSString stringWithFormat:@"pipeline state: %s", err ? err : "?"];
        free(err);
    }
    if (failure) {
        _failure = failure;
        TSMtlError(@"render pipeline %@ (%@/%@) not drawable: %@", desc.label, desc.vertexFunction.name, desc.fragmentFunction.name, failure);
    }
    TSMtlStatAlways(TSStatPipelines, 1);
    if (failure) TSMtlStatAlways(TSStatFallbacks, 1);
    return self;
}

- (void)dealloc {
    VMDevice *d = _strongDevice;
    vmg_render_pipeline *p = _vmg;
    vmg_shader *vs = _vs, *fs = _fs;
    [d gpuAsync:^{
        vmg_render_pipeline_release(d.vmg, p);
        vmg_shader_release(d.vmg, vs);
        vmg_shader_release(d.vmg, fs);
    }];
}

- (id<MTLDevice>)device { return _device; }
- (MTLRenderPipelineDescriptor *)descriptor { return _desc; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 0; }
- (BOOL)threadgroupSizeMatchesTileSize { return NO; }
- (NSUInteger)imageblockSampleLength { return 0; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){ (uint64_t)(uintptr_t)(__bridge void *)self }; }
@end

#pragma mark - Compute pipeline

@implementation VMComputePipelineState {
    __weak VMDevice *_device;
    VMDevice *_strongDevice;
    vmg_shader *_kernel;
    uint32_t _simd, _maxThreads;
    NSUInteger _staticThreadgroupMemory;
}
VM_CATCH_ALL(VMComputePipelineState)

- (instancetype)initWithDevice:(VMDevice *)device function:(id<MTLFunction>)function error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _device = _strongDevice = device;
    NSString *failure = nil;
    _kernel = VMShaderFor(device, function, nil, @[], NULL, &failure);
    if (_kernel) {
        __block vmg_compute_pipeline *p = NULL;
        __block char *err = NULL;
        __block uint32_t simd = 0, max = 0;
        [device gpuSync:^{
            p = vmg_compute_pipeline_create(device.vmg, self->_kernel, &err);
            if (p) vmg_compute_pipeline_limits(device.vmg, p, &simd, &max);
        }];
        _vmg = p;
        _simd = simd; _maxThreads = max;
        if (!p) failure = [NSString stringWithFormat:@"%@: %s", function.name, err ? err : "?"];
        free(err);
    }
    if (failure) {
        _failure = failure;
        TSMtlError(@"compute pipeline %@ does not run: %@", function.name, failure);
        _simd = 16; _maxThreads = 256;
    }
    TSMtlStatAlways(TSStatPipelines, 1);
    return self;
}

- (void)dealloc {
    VMDevice *d = _strongDevice;
    vmg_compute_pipeline *p = _vmg;
    vmg_shader *k = _kernel;
    [d gpuAsync:^{
        vmg_compute_pipeline_release(d.vmg, p);
        vmg_shader_release(d.vmg, k);
    }];
}

- (id<MTLDevice>)device { return _device; }
- (NSUInteger)threadExecutionWidth { return _simd; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _maxThreads; }
- (NSUInteger)staticThreadgroupMemoryLength { return _staticThreadgroupMemory; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d { return 0; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){ (uint64_t)(uintptr_t)(__bridge void *)self }; }
@end
