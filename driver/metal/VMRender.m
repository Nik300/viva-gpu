// Viva Metal - render command encoder. Each call is recorded in order and replayed on the GPU queue as vmg_cmd_*
// (Metal state applies to the draws that follow it).
#import "VMPrivate.h"
#import <TargetConditionals.h>

#define VM_CATCH_ALL(cls) + (void)initialize { if (self == [cls class]) TSMtlInstallCatchAll(self); }

@interface VMRenderEncoder : _MTLCommandEncoder <MTLRenderCommandEncoder>
- (instancetype)initWithCommandBuffer:(VMCommandBuffer *)cb descriptor:(MTLRenderPassDescriptor *)desc;
@end

static enum vmg_load VMLoad(MTLLoadAction a) { return a == MTLLoadActionClear ? VMG_LOAD_CLEAR : a == MTLLoadActionLoad ? VMG_LOAD_LOAD : VMG_LOAD_DONTCARE; }
static enum vmg_store VMStore(MTLStoreAction a) {
    switch (a) {
    case MTLStoreActionStore: return VMG_STORE_STORE;
    case MTLStoreActionMultisampleResolve: return VMG_STORE_RESOLVE;
    case MTLStoreActionStoreAndMultisampleResolve: return VMG_STORE_STORE_RESOLVE;
    case MTLStoreActionUnknown: return VMG_STORE_STORE;
    default: return VMG_STORE_DONTCARE;
    }
}

static void VMAttachment(vmg_attachment *out, MTLRenderPassAttachmentDescriptor *a, NSMutableArray *keep) {
    VMTexture *t = (VMTexture *)a.texture, *r = (VMTexture *)a.resolveTexture;
    if (!t) return;
    [keep addObject:t];
    if (r) [keep addObject:r];
    out->texture = t.vmg;
    out->level = (unsigned)a.level;
    out->slice = (unsigned)a.slice;
    out->depth_plane = (unsigned)a.depthPlane;
    out->resolve = r.vmg;
    out->resolve_level = (unsigned)a.resolveLevel;
    out->resolve_slice = (unsigned)a.resolveSlice;
    out->resolve_depth_plane = (unsigned)a.resolveDepthPlane;
    out->load = VMLoad(a.loadAction);
    out->store = VMStore(a.storeAction);
}

@implementation VMRenderEncoder {
    VMDevice *_device;
    VMCommandBuffer *_cb;
    VMRenderPipelineState *_pipeline;
    uint8_t _cull, _winding, _fill, _clip;   // Metal defaults: none, clockwise, fill, clip
}
VM_CATCH_ALL(VMRenderEncoder)

- (instancetype)initWithCommandBuffer:(VMCommandBuffer *)cb descriptor:(MTLRenderPassDescriptor *)desc {
    if (!(self = [super initWithCommandBuffer:cb])) return nil;
    _cb = cb;
    _device = (VMDevice *)cb.device;
    vmg_pass_desc pass = {0};
    NSMutableArray *keep = [NSMutableArray array];
    for (unsigned i = 0; i < VMG_MAX_COLOR; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = desc.colorAttachments[i];
        if (!c.texture) continue;
        VMAttachment(&pass.color[i], c, keep);
        MTLClearColor cc = c.clearColor;
        pass.color[i].clear[0] = cc.red; pass.color[i].clear[1] = cc.green; pass.color[i].clear[2] = cc.blue; pass.color[i].clear[3] = cc.alpha;
        [cb useSurface:c.texture.iosurface];
    }
    VMAttachment(&pass.depth, desc.depthAttachment, keep);
    pass.depth.clear[0] = desc.depthAttachment.clearDepth;
    VMAttachment(&pass.stencil, desc.stencilAttachment, keep);
    pass.stencil.clear_stencil = desc.stencilAttachment.clearStencil;
    pass.width = (uint32_t)desc.renderTargetWidth;
    pass.height = (uint32_t)desc.renderTargetHeight;
    pass.layers = (uint32_t)desc.renderTargetArrayLength;
    pass.samples = (uint32_t)desc.defaultRasterSampleCount;
    VMBuffer *vis = (VMBuffer *)desc.visibilityResultBuffer;
    if (vis) [keep addObject:vis];
    pass.visibility = vis.vmg;
    for (id k in keep) [cb keepAlive:k];
    VMDevice *d = _device;
    [cb recordCommand:^{ vmg_cmd_begin_pass(d.vmg, &pass); }];
    TSMtlStat(TSStatPasses, 1);
    return self;
}

- (void)endEncoding {
    VMDevice *d = _device;
    [_cb recordCommand:^{ vmg_cmd_end_pass(d.vmg); }];
    [super endEncoding];
}

#pragma mark State

- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)state {
    VMRenderPipelineState *p = (VMRenderPipelineState *)state;
    _pipeline = p;
    [_cb keepAlive:p];
    if (!p.vmg) return;
    VMDevice *d = _device;
    vmg_render_pipeline *rp = p.vmg;
    [_cb recordCommand:^{ vmg_cmd_set_render_pipeline(d.vmg, rp); }];
}

- (void)setViewport:(MTLViewport)v {
    VMDevice *d = _device;
    vmg_viewport vp = { v.originX, v.originY, v.width, v.height, v.znear, v.zfar };
    [_cb recordCommand:^{ vmg_cmd_set_viewport(d.vmg, &vp); }];
}
- (void)setViewports:(const MTLViewport *)viewports count:(NSUInteger)count { if (count) [self setViewport:viewports[0]]; }
- (void)setScissorRect:(MTLScissorRect)r {
    VMDevice *d = _device;
    [_cb recordCommand:^{ vmg_cmd_set_scissor(d.vmg, (uint32_t)r.x, (uint32_t)r.y, (uint32_t)r.width, (uint32_t)r.height); }];
}
- (void)setScissorRects:(const MTLScissorRect *)rects count:(NSUInteger)count { if (count) [self setScissorRect:rects[0]]; }

// Raster state is kept here and sent whole (vmg caches the rasterizer objects).
- (void)sendRaster:(uint8_t)cull winding:(uint8_t)winding fill:(uint8_t)fill clip:(uint8_t)clip {
    VMDevice *d = _device;
    [_cb recordCommand:^{ vmg_cmd_set_raster(d.vmg, cull, winding, fill, clip); }];
}
- (void)setCullMode:(MTLCullMode)mode { _cull = (uint8_t)mode; [self sendRaster:_cull winding:_winding fill:_fill clip:_clip]; }
- (void)setFrontFacingWinding:(MTLWinding)w { _winding = (uint8_t)w; [self sendRaster:_cull winding:_winding fill:_fill clip:_clip]; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)m { _fill = (uint8_t)m; [self sendRaster:_cull winding:_winding fill:_fill clip:_clip]; }
- (void)setDepthClipMode:(MTLDepthClipMode)m { _clip = (uint8_t)m; [self sendRaster:_cull winding:_winding fill:_fill clip:_clip]; }
- (void)setDepthBias:(float)bias slopeScale:(float)slope clamp:(float)clamp {
    VMDevice *d = _device;
    [_cb recordCommand:^{ vmg_cmd_set_depth_bias(d.vmg, bias, slope, clamp); }];
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)state {
    VMDepthStencilState *s = (VMDepthStencilState *)state;
    [_cb keepAlive:s];
    VMDevice *d = _device;
    vmg_dsa *dsa = s.vmg;
    [_cb recordCommand:^{ vmg_cmd_set_dsa(d.vmg, dsa); }];
}
- (void)setStencilReferenceValue:(uint32_t)v { [self setStencilFrontReferenceValue:v backReferenceValue:v]; }
- (void)setStencilFrontReferenceValue:(uint32_t)front backReferenceValue:(uint32_t)back {
    VMDevice *d = _device;
    [_cb recordCommand:^{ vmg_cmd_set_stencil_ref(d.vmg, front, back); }];
}
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
    VMDevice *d = _device;
    [_cb recordCommand:^{ float c[4] = { r, g, b, a }; vmg_cmd_set_blend_color(d.vmg, c); }];
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset {
    VMDevice *d = _device;
    [_cb recordCommand:^{ vmg_cmd_set_visibility(d.vmg, (uint8_t)mode, offset); }];
}

#pragma mark Bindings

- (void)bindBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset index:(NSUInteger)index stage:(enum vmg_stage)stage {
    VMDevice *d = _device;
    VMBuffer *b = (VMBuffer *)buffer;
    if (b) [_cb keepAlive:b];
    vmg_resource *r = b.vmg;
    [_cb recordCommand:^{ vmg_cmd_set_buffer(d.vmg, stage, (unsigned)index, r, offset, 0); }];
}
- (void)bindOffset:(NSUInteger)offset index:(NSUInteger)index stage:(enum vmg_stage)stage {
    VMDevice *d = _device;
    [_cb recordCommand:^{ vmg_cmd_set_buffer_offset(d.vmg, stage, (unsigned)index, offset); }];
}
- (void)bindBytes:(const void *)bytes length:(NSUInteger)length index:(NSUInteger)index stage:(enum vmg_stage)stage {
    NSUInteger off = 0;
    VMBuffer *chunk = [_cb inlineBufferWithBytes:bytes length:length offset:&off];
    [self bindBuffer:chunk offset:off index:index stage:stage];
}
- (void)bindTexture:(id<MTLTexture>)texture index:(NSUInteger)index stage:(enum vmg_stage)stage {
    VMDevice *d = _device;
    VMTexture *t = (VMTexture *)texture;
    if (t) [_cb keepAlive:t];
    [_cb useSurface:texture.iosurface];
    vmg_texture *v = t.vmg;
    [_cb recordCommand:^{ vmg_cmd_set_texture(d.vmg, stage, (unsigned)index, v); }];
}
- (void)bindSampler:(id<MTLSamplerState>)sampler index:(NSUInteger)index stage:(enum vmg_stage)stage {
    VMDevice *d = _device;
    VMSamplerState *s = (VMSamplerState *)sampler;
    if (s) [_cb keepAlive:s];
    vmg_sampler *v = s.vmg;
    float mn = s.lodMin, mx = s.lodMax;
    [_cb recordCommand:^{ vmg_cmd_set_sampler(d.vmg, stage, (unsigned)index, v, mn, mx); }];
}

- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self bindBuffer:b offset:o index:i stage:VMG_VERTEX]; }
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o attributeStride:(NSUInteger)s atIndex:(NSUInteger)i { [self bindBuffer:b offset:o index:i stage:VMG_VERTEX]; }
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self bindOffset:o index:i stage:VMG_VERTEX]; }
- (void)setVertexBytes:(const void *)p length:(NSUInteger)l atIndex:(NSUInteger)i { [self bindBytes:p length:l index:i stage:VMG_VERTEX]; }
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained *)b offsets:(const NSUInteger *)o withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setVertexBuffer:b[k] offset:o[k] atIndex:r.location + k];
}
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self bindTexture:t index:i stage:VMG_VERTEX]; }
- (void)setVertexTextures:(const id<MTLTexture> __unsafe_unretained *)t withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setVertexTexture:t[k] atIndex:r.location + k];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self bindSampler:s index:i stage:VMG_VERTEX]; }
- (void)setVertexSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)mn lodMaxClamp:(float)mx atIndex:(NSUInteger)i { [self bindSampler:s index:i stage:VMG_VERTEX]; }
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __unsafe_unretained *)s withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setVertexSamplerState:s[k] atIndex:r.location + k];
}
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self bindBuffer:b offset:o index:i stage:VMG_FRAGMENT]; }
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self bindOffset:o index:i stage:VMG_FRAGMENT]; }
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)l atIndex:(NSUInteger)i { [self bindBytes:p length:l index:i stage:VMG_FRAGMENT]; }
- (void)setFragmentBuffers:(const id<MTLBuffer> __unsafe_unretained *)b offsets:(const NSUInteger *)o withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setFragmentBuffer:b[k] offset:o[k] atIndex:r.location + k];
}
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self bindTexture:t index:i stage:VMG_FRAGMENT]; }
- (void)setFragmentTextures:(const id<MTLTexture> __unsafe_unretained *)t withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setFragmentTexture:t[k] atIndex:r.location + k];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self bindSampler:s index:i stage:VMG_FRAGMENT]; }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)mn lodMaxClamp:(float)mx atIndex:(NSUInteger)i { [self bindSampler:s index:i stage:VMG_FRAGMENT]; }
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __unsafe_unretained *)s withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setFragmentSamplerState:s[k] atIndex:r.location + k];
}

#pragma mark Draws

- (void)draw:(vmg_draw_info)info index:(id<MTLBuffer>)index indirect:(id<MTLBuffer>)indirect {
    if (!_pipeline.vmg) return;   // pipeline not translated: skipped (logged at creation)
    VMDevice *d = _device;
    VMBuffer *ib = (VMBuffer *)index, *ind = (VMBuffer *)indirect;
    if (ib) [_cb keepAlive:ib];
    if (ind) [_cb keepAlive:ind];
    [_cb recordCommand:^{
        vmg_draw_info i2 = info;
        i2.index_buffer = ib.vmg;
        i2.indirect = ind.vmg;
        vmg_cmd_draw(d.vmg, &i2);
    }];
    TSMtlStat(TSStatDraws, 1);
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
         instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    if (!count || !instances) return;
    vmg_draw_info i = { .primitive = (uint8_t)type, .start = (uint32_t)start, .count = (uint32_t)count,
                        .instance_count = (uint32_t)instances, .base_instance = (uint32_t)base };
    [self draw:i index:nil indirect:nil];
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)n {
    [self drawPrimitives:type vertexStart:start vertexCount:count instanceCount:n baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count {
    [self drawPrimitives:type vertexStart:start vertexCount:count instanceCount:1 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType
                  indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:(NSUInteger)offset instanceCount:(NSUInteger)instances
                   baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    if (!count || !instances || !buffer) return;
    vmg_draw_info i = { .primitive = (uint8_t)type, .count = (uint32_t)count, .instance_count = (uint32_t)instances,
                        .base_instance = (uint32_t)baseInstance, .index_offset = offset,
                        .index_size = indexType == MTLIndexTypeUInt16 ? 2 : 4, .base_vertex = (int32_t)baseVertex };
    [self draw:i index:buffer indirect:nil];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType
                  indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:(NSUInteger)offset instanceCount:(NSUInteger)instances {
    [self drawIndexedPrimitives:type indexCount:count indexType:indexType indexBuffer:buffer indexBufferOffset:offset
                  instanceCount:instances baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType
                  indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:(NSUInteger)offset {
    [self drawIndexedPrimitives:type indexCount:count indexType:indexType indexBuffer:buffer indexBufferOffset:offset
                  instanceCount:1 baseVertex:0 baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)type indirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)offset {
    vmg_draw_info i = { .primitive = (uint8_t)type, .indirect_offset = offset, .instance_count = 1 };
    [self draw:i index:nil indirect:buffer];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)buffer
            indexBufferOffset:(NSUInteger)offset indirectBuffer:(id<MTLBuffer>)indirect indirectBufferOffset:(NSUInteger)ioff {
    vmg_draw_info i = { .primitive = (uint8_t)type, .index_offset = offset, .index_size = indexType == MTLIndexTypeUInt16 ? 2 : 4,
                        .indirect_offset = ioff, .instance_count = 1 };
    [self draw:i index:buffer indirect:indirect];
}

#pragma mark Barriers and residency

- (void)recordBarrier {
    VMDevice *d = _device;
    [_cb recordCommand:^{ vmg_cmd_barrier(d.vmg); }];
}
#if TARGET_OS_OSX
- (void)textureBarrier { [self recordBarrier]; }
#endif
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before { [self recordBarrier]; }
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained *)resources count:(NSUInteger)count
                       afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before { [self recordBarrier]; }
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage {}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {}
- (void)useResources:(const id<MTLResource> __unsafe_unretained *)resources count:(NSUInteger)count usage:(MTLResourceUsage)usage {}
- (void)useHeap:(id<MTLHeap>)heap {}
- (void)updateFence:(id<MTLFence>)fence afterStages:(MTLRenderStages)stages {}
- (void)waitForFence:(id<MTLFence>)fence beforeStages:(MTLRenderStages)stages {}
@end

id<MTLRenderCommandEncoder> VMNewRenderEncoder(VMCommandBuffer *cb, MTLRenderPassDescriptor *desc) {
    return [[VMRenderEncoder alloc] initWithCommandBuffer:cb descriptor:desc];
}
