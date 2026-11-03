// TeraScale Metal Shim - command queue, command buffer and encoders.
// Encoders record closures; the queue replays them on the device's serial GPU queue
// and then reports schedule/completion through the _MTLCommandBuffer machinery
// (handlers, status, waitUntilCompleted, -[MTLCommandQueue finish]).
// Render encoders live in TSMtlRender.m.
#import "TSPrivate.h"
#import <mach/mach_time.h>
#import <objc/runtime.h>

#pragma mark - Encoders

@interface TSMtlBlitEncoder : _MTLCommandEncoder <MTLBlitCommandEncoder>
@end
// Compute: GL 4.1 has no compute shaders. With TeraScale Compute on, kernels that work as fragment
// shaders run as GL passes (TSMtlComputePipelineState); every other dispatch is a no-op.
@interface TSMtlComputeEncoder : _MTLCommandEncoder <MTLComputeCommandEncoder>
@end
@interface TSMtlResourceStateEncoder : _MTLCommandEncoder <MTLResourceStateCommandEncoder>
@end
@interface TSMtlAccelerationStructureEncoder : _MTLCommandEncoder <MTLAccelerationStructureCommandEncoder>
@end

id<MTLRenderCommandEncoder> TSMtlNewRenderEncoder(TSMtlCommandBuffer *cb, MTLRenderPassDescriptor *desc);
id<MTLParallelRenderCommandEncoder> TSMtlNewParallelRenderEncoder(TSMtlCommandBuffer *cb, MTLRenderPassDescriptor *desc);

#define TS_ENCODER_CATCH_ALL(cls) + (void)initialize { if (self == [cls class]) TSMtlInstallCatchAll(self); }

static TSMtlCommandBuffer *TSEncoderCB(_MTLCommandEncoder *enc) { return (TSMtlCommandBuffer *)[(id)enc commandBuffer]; }

@implementation TSMtlBlitEncoder
TS_ENCODER_CATCH_ALL(TSMtlBlitEncoder)

- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)srcOff toBuffer:(id<MTLBuffer>)dst
     destinationOffset:(NSUInteger)dstOff size:(NSUInteger)size {
    [TSEncoderCB(self) recordCommand:^{
        // D3: when OpenCL wrote either buffer and the CPU copy has not caught up, copy in GL and leave the result
        // there (merged back at completion like a kernel write) instead of reading the whole buffer back now.
        TSMtlBuffer *s = (TSMtlBuffer *)src, *t = (TSMtlBuffer *)dst;
        if (gTSComputeCLActive && size && [s isKindOfClass:[TSMtlBuffer class]] && [t isKindOfClass:[TSMtlBuffer class]] &&
            (s.gpuAhead || t.gpuAhead)) {
            GLuint sg = [s glBuffer], dg = [t glBuffer];
            if (s.gpuAhead || t.gpuAhead) {
                [t prepareGPUWrite];
                glBindBuffer(GL_COPY_READ_BUFFER, sg);
                glBindBuffer(GL_COPY_WRITE_BUFFER, dg);
                glCopyBufferSubData(GL_COPY_READ_BUFFER, GL_COPY_WRITE_BUFFER, (GLintptr)srcOff, (GLintptr)dstOff, (GLsizeiptr)size);
                glBindBuffer(GL_COPY_READ_BUFFER, 0);
                glBindBuffer(GL_COPY_WRITE_BUFFER, 0);
                [t didWriteGPU];
                return;
            }
        }
        memmove((uint8_t *)dst.contents + dstOff, (uint8_t *)src.contents + srcOff, size);
        [(TSMtlBuffer *)dst didWriteRange:NSMakeRange(dstOff, size)];
    }];
}

- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
    [TSEncoderCB(self) recordCommand:^{
        memset((uint8_t *)buffer.contents + range.location, value, range.length);
        [(TSMtlBuffer *)buffer didWriteRange:range];
    }];
}

- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)srcOff sourceBytesPerRow:(NSUInteger)rowPitch
 sourceBytesPerImage:(NSUInteger)imagePitch sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
    destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level destinationOrigin:(MTLOrigin)origin {
    [self copyFromBuffer:src sourceOffset:srcOff sourceBytesPerRow:rowPitch sourceBytesPerImage:imagePitch sourceSize:size
               toTexture:dst destinationSlice:slice destinationLevel:level destinationOrigin:origin options:MTLBlitOptionNone];
}

- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)srcOff sourceBytesPerRow:(NSUInteger)rowPitch
 sourceBytesPerImage:(NSUInteger)imagePitch sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
    destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level destinationOrigin:(MTLOrigin)origin
             options:(MTLBlitOption)options {
    MTLRegion region = { origin, size };
    [TSEncoderCB(self) useSurface:dst.iosurface];
    [TSEncoderCB(self) recordCommand:^{
        if (gTSMtlDrawTrace)
            fprintf(stderr, "[TSDraw] blit buffer %p+%lu -> %p:%lux%lu%s (%lu,%lu) %lux%lu\n", src, (unsigned long)srcOff, dst,
                    (unsigned long)dst.width, (unsigned long)dst.height, dst.iosurface ? ":ios" : "", (unsigned long)origin.x,
                    (unsigned long)origin.y, (unsigned long)size.width, (unsigned long)size.height);
        [dst replaceRegion:region mipmapLevel:level slice:slice withBytes:(uint8_t *)src.contents + srcOff
               bytesPerRow:rowPitch bytesPerImage:imagePitch];
    }];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level
           sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)dstOff destinationBytesPerRow:(NSUInteger)rowPitch destinationBytesPerImage:(NSUInteger)imagePitch {
    [self copyFromTexture:src sourceSlice:slice sourceLevel:level sourceOrigin:origin sourceSize:size toBuffer:dst
        destinationOffset:dstOff destinationBytesPerRow:rowPitch destinationBytesPerImage:imagePitch options:MTLBlitOptionNone];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level
           sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)dstOff destinationBytesPerRow:(NSUInteger)rowPitch destinationBytesPerImage:(NSUInteger)imagePitch
                options:(MTLBlitOption)options {
    MTLRegion region = { origin, size };
    [TSEncoderCB(self) useSurface:src.iosurface];
    [TSEncoderCB(self) recordCommand:^{
        [src getBytes:(uint8_t *)dst.contents + dstOff bytesPerRow:rowPitch bytesPerImage:imagePitch
           fromRegion:region mipmapLevel:level slice:slice];
        [(TSMtlBuffer *)dst didWriteCPU];
    }];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)srcSlice sourceLevel:(NSUInteger)srcLevel
           sourceOrigin:(MTLOrigin)srcOrigin sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)dstSlice destinationLevel:(NSUInteger)dstLevel destinationOrigin:(MTLOrigin)dstOrigin {
    [TSEncoderCB(self) useSurface:src.iosurface];
    [TSEncoderCB(self) useSurface:dst.iosurface];
    [TSEncoderCB(self) recordCommand:^{
        if (gTSMtlDrawTrace)
            fprintf(stderr, "[TSDraw] blit %p:%lux%lu (%lu,%lu) %lux%lu -> %p:%lux%lu (%lu,%lu)\n", src, (unsigned long)src.width,
                    (unsigned long)src.height, (unsigned long)srcOrigin.x, (unsigned long)srcOrigin.y, (unsigned long)size.width,
                    (unsigned long)size.height, dst, (unsigned long)dst.width, (unsigned long)dst.height,
                    (unsigned long)dstOrigin.x, (unsigned long)dstOrigin.y);
        if ([src isKindOfClass:[TSMtlTexture class]] &&
            [(TSMtlTexture *)src gpuCopyFromSlice:srcSlice level:srcLevel origin:srcOrigin size:size toTexture:(TSMtlTexture *)dst
                                            slice:dstSlice level:dstLevel origin:dstOrigin])
            return;
        TSPixelFormatInfo pf = TSPixelFormatGetInfo(src.pixelFormat);
        NSUInteger rowPitch = ((size.width + pf.blockWidth - 1) / pf.blockWidth) * pf.bytesPerBlock;
        NSUInteger imagePitch = rowPitch * ((size.height + pf.blockHeight - 1) / pf.blockHeight);
        void *tmp = malloc(imagePitch * size.depth);
        if (!tmp) return;
        [src getBytes:tmp bytesPerRow:rowPitch bytesPerImage:imagePitch fromRegion:(MTLRegion){srcOrigin, size}
          mipmapLevel:srcLevel slice:srcSlice];
        [dst replaceRegion:(MTLRegion){dstOrigin, size} mipmapLevel:dstLevel slice:dstSlice withBytes:tmp
               bytesPerRow:rowPitch bytesPerImage:imagePitch];
        free(tmp);
    }];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)srcSlice sourceLevel:(NSUInteger)srcLevel
              toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)dstSlice destinationLevel:(NSUInteger)dstLevel
             sliceCount:(NSUInteger)sliceCount levelCount:(NSUInteger)levelCount {
    for (NSUInteger s = 0; s < sliceCount; s++)
        for (NSUInteger l = 0; l < levelCount; l++) {
            NSUInteger lvl = srcLevel + l;
            MTLSize size = MTLSizeMake(MAX(src.width >> lvl, 1), MAX(src.height >> lvl, 1),
                                       src.textureType == MTLTextureType3D ? MAX(src.depth >> lvl, 1) : 1);
            [self copyFromTexture:src sourceSlice:srcSlice + s sourceLevel:lvl sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:size
                        toTexture:dst destinationSlice:dstSlice + s destinationLevel:dstLevel + l destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
}

- (void)copyFromTexture:(id<MTLTexture>)src toTexture:(id<MTLTexture>)dst {
    NSUInteger slices = src.arrayLength * (src.textureType == MTLTextureTypeCube || src.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    [self copyFromTexture:src sourceSlice:0 sourceLevel:0 toTexture:dst destinationSlice:0 destinationLevel:0
               sliceCount:slices levelCount:MIN(src.mipmapLevelCount, dst.mipmapLevelCount)];
}

- (void)generateMipmapsForTexture:(id<MTLTexture>)texture {
    if (![texture isKindOfClass:[TSMtlTexture class]] || texture.mipmapLevelCount < 2) return;
    [TSEncoderCB(self) useSurface:texture.iosurface];
    [TSEncoderCB(self) recordCommand:^{
        TSMtlTexture *t = (TSMtlTexture *)texture;
        GLenum target;
        GLuint name = [t glTextureForSampling:&target];
        glBindTexture(target, name);
        glGenerateMipmap(target);
        glBindTexture(target, 0);
        [t didRenderGL];
    }];
}
- (void)synchronizeResource:(id<MTLResource>)resource {}
- (void)synchronizeTexture:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level {}
- (void)updateFence:(id<MTLFence>)fence {}
- (void)waitForFence:(id<MTLFence>)fence {}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture {}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture {}
@end

@implementation TSComputeDispatch
@end

// GPU queue: one dispatch as a GL pass. The viewport is the grid clipped to the written texture, one
// fragment per thread; the program is the kernel translated as a fragment shader (TSAirTranslator).
// Leaves GL in the state render passes expect to find: they reset their GL shadow at every replay.
static void TSComputeRunGL(TSComputeDispatch *d) {
    TSMtlComputePipelineState *p = d->pipeline;
    NSInteger out = p.outputTextureIndex;
    TSMtlTexture *dst = out >= 0 && out < 32 ? (TSMtlTexture *)d->textures[out] : nil;
    if (![dst isKindOfClass:[TSMtlTexture class]]) { TSMtlCompute(@"dispatch skipped: no texture bound at the written slot %ld", (long)out); return; }
    if (d->grid.depth > 1) TSMtlCompute(@"dispatch with a 3D grid (depth %lu): only z = 0 runs", (unsigned long)d->grid.depth);
    // IOSurface textures read in place through the rectangle variant, as in render passes; buffers bound at
    // offsets that are not 16-aligned through the word-by-word variant.
    uint32_t mask = 0;
    for (NSUInteger i = 0; i < p.rectSlotCount; i++) {
        NSUInteger slot = p.rectSlots[i] & 0xff;
        if (p.rectSlots[i] & TSSlotBuffer) { if (slot < 31 && (d->offsets[slot] & 15)) mask |= 1u << i; continue; }
        TSMtlTexture *t = slot < 32 ? (TSMtlTexture *)d->textures[slot] : nil;
        if ([t isKindOfClass:[TSMtlTexture class]] && t.iosurface && [t glRectangleForSampling]) mask |= 1u << i;
    }
    TSGLProgram *prog = [p programForRectMask:mask];
    if (!prog) return;
    for (NSUInteger i = 0; i < prog->_textureCount; i++)
        if (prog->_textures[i].kind < 2 && prog->_textures[i].index < 32 && d->textures[prog->_textures[i].index] == dst) {
            TSMtlCompute(@"dispatch skipped: the kernel reads the texture it writes (slot %u)", prog->_textures[i].index);
            return;
        }

    static GLuint fbo, vao, ubos[31];
    if (!fbo) { glGenFramebuffers(1, &fbo); glGenVertexArrays(1, &vao); glGenBuffers(31, ubos); }
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
    if (![dst attachToFramebuffer:GL_COLOR_ATTACHMENT0 level:0 slice:0 depthPlane:0]) {
        TSMtlCompute(@"dispatch skipped: cannot render into %lux%lu format %lu", (unsigned long)dst.width, (unsigned long)dst.height,
                     (unsigned long)dst.pixelFormat);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        return;
    }
    GLenum drawBuffer = GL_COLOR_ATTACHMENT0;
    glDrawBuffers(1, &drawBuffer);
    GLenum status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        TSMtlCompute(@"dispatch skipped: framebuffer status 0x%x for format %lu", status, (unsigned long)dst.pixelFormat);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        return;
    }
    glDisablei(GL_BLEND, 0);
    glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glDisable(GL_DEPTH_TEST); glDisable(GL_STENCIL_TEST); glDisable(GL_CULL_FACE); glDisable(GL_SCISSOR_TEST);
    glDisable(GL_POLYGON_OFFSET_FILL); glDisable(GL_SAMPLE_ALPHA_TO_COVERAGE); glDisable(GL_RASTERIZER_DISCARD);
    glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
    glEnable(GL_FRAMEBUFFER_SRGB);   // write() to an sRGB texture encodes, like a render target
    GLsizei w = (GLsizei)MIN(d->grid.width, dst.width), h = (GLsizei)MIN(d->grid.height, dst.height);
    glViewport(0, 0, w, h);
    glUseProgram(prog->_program);
    glBindVertexArray(vao);
    if (prog->_gridLocation >= 0) glUniform3i(prog->_gridLocation, (GLint)d->grid.width, (GLint)d->grid.height, (GLint)d->grid.depth);
    if (prog->_threadgroupLocation >= 0)
        glUniform3i(prog->_threadgroupLocation, (GLint)MAX(d->threadgroup.width, 1), (GLint)MAX(d->threadgroup.height, 1),
                    (GLint)MAX(d->threadgroup.depth, 1));
    if (prog->_outSizeLocation >= 0) glUniform2i(prog->_outSizeLocation, (GLint)dst.width, (GLint)dst.height);

    // Constant buffers: the CPU copy is the truth, copied into a uniform buffer per slot (orphaned each dispatch).
    for (NSUInteger i = 0; i < prog->_blockCount; i++) {
        const TSGLBinding *b = &prog->_blocks[i];
        if (b->index >= 31) continue;
        id<MTLBuffer> buf = d->buffers[b->index];
        NSUInteger off = d->offsets[b->index], size = MAX((NSUInteger)b->size, 16);
        NSUInteger avail = buf && off < buf.length ? MIN(buf.length - off, size) : 0;
        glBindBuffer(GL_UNIFORM_BUFFER, ubos[b->index]);
        glBufferData(GL_UNIFORM_BUFFER, size, NULL, GL_STREAM_DRAW);
        if (avail) glBufferSubData(GL_UNIFORM_BUFFER, 0, avail, (const uint8_t *)buf.contents + off);
        glBindBufferBase(GL_UNIFORM_BUFFER, b->stage * 31 + b->index, ubos[b->index]);
    }
    // Textures, device buffers (texture buffers) and samplers. Names are resolved first: uploads use unit 79.
    glActiveTexture(GL_TEXTURE0 + 79);
    NSUInteger n = MIN(prog->_textureCount, 32);
    GLuint names[32], samplers[32];
    GLenum targets[32];
    for (NSUInteger i = 0; i < n; i++) {
        const TSGLBinding *t = &prog->_textures[i];
        names[i] = samplers[i] = 0;
        targets[i] = prog->_targets[i];
        if (t->kind >= 2) {
            TSMtlBuffer *buf = t->index < 31 ? (TSMtlBuffer *)d->buffers[t->index] : nil;
            if (![buf isKindOfClass:[TSMtlBuffer class]]) continue;
            names[i] = t->kind == 2 ? [buf glTextureBuffer] : t->kind == 3 ? [buf glTextureBuffer4] : [buf glTextureBuffer2];
            if (t->aux >= 0) glUniform1i(t->aux, (GLint)d->offsets[t->index]);
            continue;
        }
        TSMtlTexture *tex = t->index < 32 ? (TSMtlTexture *)d->textures[t->index] : nil;
        if (![tex isKindOfClass:[TSMtlTexture class]]) continue;
        TSMtlSamplerState *smp = t->sampler < 16 ? (TSMtlSamplerState *)d->samplers[t->sampler] : nil;
        if (![smp isKindOfClass:[TSMtlSamplerState class]]) smp = nil;
        if (t->rect) {
            names[i] = [tex glRectangleForSampling];
            static GLuint plain;
            if (!plain) plain = TSGLCreateRectangleSampler(0);
            samplers[i] = t->kind == 1 ? TSGLRectangleSamplerForConstexpr(t->key) : smp ? smp.glRectangleSampler : plain;
        } else {
            names[i] = [tex glTextureForSampling:&targets[i]];
            samplers[i] = t->kind == 1 ? (GLuint)t->aux : smp.glSampler;
        }
    }
    for (NSUInteger i = 0; i < n; i++) {
        GLuint unit = (GLuint)prog->_textures[i].unit;
        glActiveTexture(GL_TEXTURE0 + unit);
        glBindTexture(targets[i], names[i]);
        glBindSampler(unit, samplers[i]);
    }
    glActiveTexture(GL_TEXTURE0);
    for (NSUInteger i = 0; i < prog->_infoCount; i++) {
        const TSGLBinding *info = &prog->_infos[i];
        id<MTLTexture> tex = info->index < 32 ? d->textures[info->index] : nil;
        glUniform2i(info->aux, (GLint)MAX(tex.sampleCount, 1), (GLint)MAX(tex.mipmapLevelCount, 1));
    }
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);
    glUseProgram(0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    [dst didRenderGL];
    TSMtlStat(TSStatDispatches, 1);
}

@implementation TSMtlComputeEncoder {
    TSMtlComputePipelineState *_pipeline;
    id<MTLBuffer> _buffers[31];
    NSUInteger _offsets[31];
    id<MTLTexture> _textures[32];
    id<MTLSamplerState> _samplers[16];
    NSUInteger _threadgroupMemory[31];
}
TS_ENCODER_CATCH_ALL(TSMtlComputeEncoder)
- (MTLDispatchType)dispatchType { return MTLDispatchTypeSerial; }

- (void)setComputePipelineState:(id<MTLComputePipelineState>)state {
    _pipeline = [(id)state isKindOfClass:[TSMtlComputePipelineState class]] ? (TSMtlComputePipelineState *)state : nil;
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (index < 31) { _buffers[index] = buffer; _offsets[index] = offset; }
}
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index { if (index < 31) _offsets[index] = offset; }
- (void)setBuffers:(const id<MTLBuffer> [])buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
}
// Inline data goes into the command buffer's inline chunk (C1), so constant and device bindings treat it alike.
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index {
    if (index >= 31) return;
    NSUInteger offset = 0;
    _buffers[index] = [TSEncoderCB(self) inlineBufferWithBytes:bytes length:MAX(length, 1) offset:&offset];
    _offsets[index] = offset;
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    if (index < 32) _textures[index] = texture;
    else TSMtlCompute(@"texture slot %lu ignored (32 supported)", (unsigned long)index);
}
- (void)setTextures:(const id<MTLTexture> [])textures withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setTexture:textures[i] atIndex:range.location + i];
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index { if (index < 16) _samplers[index] = sampler; }
- (void)setSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMin lodMaxClamp:(float)lodMax atIndex:(NSUInteger)index {
    [self setSamplerState:sampler atIndex:index];
}
- (void)setSamplerStates:(const id<MTLSamplerState> [])samplers withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setSamplerState:samplers[i] atIndex:range.location + i];
}
// Dynamic threadgroup memory: __local arguments of OpenCL kernels (the GL path has none). Dispatches run in order.
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index { if (index < 31) _threadgroupMemory[index] = length; }
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope {}
- (void)memoryBarrierWithResources:(const id<MTLResource> [])resources count:(NSUInteger)count {}
- (void)updateFence:(id<MTLFence>)fence {}
- (void)waitForFence:(id<MTLFence>)fence {}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage {}
- (void)useResources:(const id<MTLResource> [])resources count:(NSUInteger)count usage:(MTLResourceUsage)usage {}
- (void)useHeap:(id<MTLHeap>)heap {}

- (void)dispatchGrid:(MTLSize)grid threadgroup:(MTLSize)threadgroup selector:(SEL)sel {
    [self dispatchGrid:grid threadgroup:threadgroup indirect:nil offset:0 selector:sel];
}

- (void)dispatchGrid:(MTLSize)grid threadgroup:(MTLSize)threadgroup indirect:(id<MTLBuffer>)indirect offset:(NSUInteger)indirectOffset
            selector:(SEL)sel {
    TSMtlComputePipelineState *p = _pipeline;
    TSMtlStat(TSStatComputeRecorded, 1);
    if (!p.runsOnGL && !p.clKernel) {
        TSMtlStat(TSStatComputeInert, 1);
        // Same category as before compute existed: the log shows which apps would use it.
        TSMtlUnimpl(@"-[TSMtlComputeEncoder %s]: kernel not run (%@)", sel_getName(sel), p ? p.computePath : @"no pipeline");
        return;
    }
    if (!indirect && (!grid.width || !grid.height || !grid.depth)) return;
    TSComputeDispatch *d = [TSComputeDispatch new];
    d->pipeline = p;
    d->grid = grid;
    d->threadgroup = threadgroup;
    d->indirect = indirect;
    d->indirectOffset = indirectOffset;
    TSMtlCommandBuffer *cb = TSEncoderCB(self);
    for (int i = 0; i < 31; i++) { d->buffers[i] = _buffers[i]; d->offsets[i] = _offsets[i]; d->threadgroupMemory[i] = _threadgroupMemory[i]; }
    for (int i = 0; i < 32; i++) { d->textures[i] = _textures[i]; if (_textures[i].iosurface) [cb useSurface:_textures[i].iosurface]; }
    for (int i = 0; i < 16; i++) d->samplers[i] = _samplers[i];
    BOOL gl = p.runsOnGL;
    dispatch_block_t run = ^{
        if (d->indirect) {
            // MTLDispatchThreadgroupsIndirectArguments, read when the command runs: earlier work may have written it,
            // an OpenCL kernel of this very run included (D2: only these 12 bytes are read back from GL).
            uint32_t a[3] = { 0, 0, 0 };
            if (d->indirectOffset + sizeof a <= d->indirect.length) {
                if ([(id)d->indirect isKindOfClass:[TSMtlBuffer class]])
                    [(TSMtlBuffer *)d->indirect getGPUBytes:a range:NSMakeRange(d->indirectOffset, sizeof a)];
                else memcpy(a, (uint8_t *)d->indirect.contents + d->indirectOffset, sizeof a);
            }
            if (!a[0] || !a[1] || !a[2]) return;
            d->grid = MTLSizeMake(a[0] * d->threadgroup.width, a[1] * d->threadgroup.height, a[2] * d->threadgroup.depth);
        }
        if (gl) TSComputeRunGL(d);
        else TSMtlCLDispatch(d);
    };
    if (gl) [cb recordCommand:run];
    else [cb recordComputeCommand:run];
}
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)tg {
    [self dispatchGrid:MTLSizeMake(groups.width * tg.width, groups.height * tg.height, groups.depth * tg.depth) threadgroup:tg selector:_cmd];
}
- (void)dispatchThreads:(MTLSize)threads threadsPerThreadgroup:(MTLSize)tg {
    [self dispatchGrid:threads threadgroup:tg selector:_cmd];
}
- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)offset
                         threadsPerThreadgroup:(MTLSize)tg {
    if (!buffer) return;
    [self dispatchGrid:MTLSizeMake(0, 0, 0) threadgroup:tg indirect:buffer offset:offset selector:_cmd];
}
@end

@implementation TSMtlResourceStateEncoder
TS_ENCODER_CATCH_ALL(TSMtlResourceStateEncoder)
@end

@implementation TSMtlAccelerationStructureEncoder
TS_ENCODER_CATCH_ALL(TSMtlAccelerationStructureEncoder)
@end

#pragma mark - Command buffer

// TSMTL_EARLY_COMPLETION=1: the old behaviour (signals and completion as soon as the CPU has issued
// the GL commands), for A/B tests against the fence-deferred completion (B2).
static BOOL TSEarlyCompletion(void) {
    static int early = -1;
    if (early < 0) early = getenv("TSMTL_EARLY_COMPLETION") != NULL;
    return early;
}

// GPU queue only: highest value each shared event will reach once the GL commands issued so far
// complete, so waits behind a deferred signal are not reported as unsatisfied.
static NSMapTable<id, NSNumber *> *TSIssuedSignals(void) {
    static NSMapTable *map;
    if (!map) map = [NSMapTable weakToStrongObjectsMapTable];
    return map;
}

@implementation TSMtlCommandBuffer {
    NSMutableArray<dispatch_block_t> *_commands;
    NSMutableIndexSet *_clCommands;   // indices of OpenCL dispatches in _commands
    NSLock *_lock;
    NSMutableArray<dispatch_block_t> *_signals;   // GPU queue only: deferred to GPU completion
    CFMutableSetRef _surfaces;   // IOSurfaces used, under _lock until commit
    TSMtlBuffer *_inline;        // C1: chunk being filled by setBytes, under _lock
    NSUInteger _inlineUsed;
    NSMutableArray<TSMtlBuffer *> *_inlineChunks;   // every chunk this command buffer used
}

// C1: setBytes data used to become a new MTLBuffer per call, i.e. per OpenCL dispatch a GL buffer, a
// clCreateFromGLBuffer that always missed the cache, an acquire and a Forget at release. It now goes into
// 64 KB managed chunks at 256-byte offsets; only the written ranges are uploaded (glBufferSubData, no
// re-specification, so the chunk's cl_mem stays cached), and a chunk returns to its device's pool once the
// command buffer has completed on the GPU.
enum { TSInlineChunk = 64 << 10, TSInlineAlign = 256, TSInlinePoolMax = 16 };
static char kTSInlinePoolKey;

static NSMutableArray<TSMtlBuffer *> *TSInlinePool(id<MTLDevice> device) {
    NSMutableArray *pool = objc_getAssociatedObject(device, &kTSInlinePoolKey);
    if (pool) return pool;
    @synchronized (device) {
        pool = objc_getAssociatedObject(device, &kTSInlinePoolKey);
        if (!pool) objc_setAssociatedObject(device, &kTSInlinePoolKey, pool = [NSMutableArray array], OBJC_ASSOCIATION_RETAIN);
    }
    return pool;
}

// TSMTL_NO_SURFACE_USE=1: do not hold IOSurface use counts (A/B tests).
static BOOL TSSurfaceUseOff(void) {
    static int off = -1;
    if (off < 0) off = getenv("TSMTL_NO_SURFACE_USE") != NULL;
    return off;
}

+ (void)initialize { if (self == [TSMtlCommandBuffer class]) TSMtlInstallCatchAll(self); }

- (instancetype)initWithQueue:(id)queue retainedReferences:(BOOL)retained {
    if ((self = [super initWithQueue:queue retainedReferences:retained])) {
        _commands = [NSMutableArray array];
        _lock = [NSLock new];
    }
    return self;
}

- (id<MTLDevice>)device { return [(id<MTLCommandQueue>)[self commandQueue] device]; }

- (void)recordCommand:(dispatch_block_t)command {
    [_lock lock];
    [_commands addObject:[command copy]];
    [_lock unlock];
}

- (void)recordCommands:(NSArray<dispatch_block_t> *)commands {
    [_lock lock];
    [_commands addObjectsFromArray:commands];
    [_lock unlock];
}

- (id<MTLBuffer>)inlineBufferWithBytes:(const void *)bytes length:(NSUInteger)length offset:(NSUInteger *)offset {
    id<MTLDevice> device = self.device;
    if (length > TSInlineChunk / 4) {   // Metal caps setBytes at 4 KB; anything larger keeps a buffer of its own
        *offset = 0;
        return [device newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];
    }
    NSUInteger aligned = (length + TSInlineAlign - 1) & ~(NSUInteger)(TSInlineAlign - 1);
    [_lock lock];
    if (!_inline || _inlineUsed + aligned > TSInlineChunk) {
        NSMutableArray<TSMtlBuffer *> *pool = TSInlinePool(device);
        TSMtlBuffer *chunk = nil;
        @synchronized (pool) {
            chunk = pool.lastObject;
            if (chunk) [pool removeLastObject];
        }
        _inline = chunk ?: (TSMtlBuffer *)[device newBufferWithLength:TSInlineChunk options:MTLResourceStorageModeManaged];
        _inlineUsed = 0;
        if (!_inlineChunks) _inlineChunks = [NSMutableArray array];
        [_inlineChunks addObject:_inline];
    }
    TSMtlBuffer *chunk = _inline;
    NSUInteger off = _inlineUsed;
    _inlineUsed += aligned;
    [_lock unlock];
    memcpy((uint8_t *)chunk.contents + off, bytes, length);
    [chunk didModifyRange:NSMakeRange(off, aligned)];   // aligned: consecutive ranges touch and merge into one
    *offset = off;
    return chunk;
}

// After GPU completion: the chunks can take the next command buffer's data.
- (void)recycleInlineChunks {
    [_lock lock];
    NSArray *chunks = _inlineChunks;
    _inlineChunks = nil;
    _inline = nil;
    [_lock unlock];
    if (!chunks.count) return;
    NSMutableArray<TSMtlBuffer *> *pool = TSInlinePool(self.device);
    @synchronized (pool) {
        for (TSMtlBuffer *chunk in chunks)
            if (pool.count < TSInlinePoolMax) [pool addObject:chunk];
    }
}

- (void)recordComputeCommand:(dispatch_block_t)command {
    [_lock lock];
    if (!_clCommands) _clCommands = [NSMutableIndexSet indexSet];
    [_clCommands addIndex:_commands.count];
    [_commands addObject:[command copy]];
    [_lock unlock];
}

// A CL run stays open across consecutive OpenCL dispatches and is submitted before anything else touches GL
// (render passes, blits, GL-path dispatches, the flush and completion fence that follow execute).
- (void)execute {
    [_lock lock];
    NSArray *commands = _commands;
    NSIndexSet *cl = _clCommands;
    _commands = [NSMutableArray array];
    _clCommands = nil;
    [_lock unlock];
    if (!cl) {
        for (dispatch_block_t command in commands) command();
        return;
    }
    NSUInteger i = 0;
    for (dispatch_block_t command in commands) {
        if (gTSCLOpenRun && ![cl containsIndex:i]) TSMtlComputeEndRunAsync();
        command();
        i++;
    }
    TSMtlComputeEndRun();
}

- (void)dealloc {
    if (_surfaces) CFRelease(_surfaces);
}

- (void)useSurface:(IOSurfaceRef)surface {
    if (!surface || TSSurfaceUseOff()) return;
    [_lock lock];
    if (!_surfaces) _surfaces = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    CFSetAddValue(_surfaces, surface);
    [_lock unlock];
}

static void TSIncrementUse(const void *s, void *ctx) { IOSurfaceIncrementUseCount((IOSurfaceRef)s); }
static void TSDecrementUse(const void *s, void *ctx) { IOSurfaceDecrementUseCount((IOSurfaceRef)s); }

// Commit: hold the use counts until the GPU has run the command buffer.
- (void)beginSurfaceUse {
    [_lock lock];
    if (_surfaces) CFSetApplyFunction(_surfaces, TSIncrementUse, NULL);
    [_lock unlock];
}
- (void)endSurfaceUse {
    [_lock lock];
    if (_surfaces) {
        CFSetApplyFunction(_surfaces, TSDecrementUse, NULL);
        CFRelease(_surfaces);
        _surfaces = NULL;
    }
    [_lock unlock];
}

- (NSArray<dispatch_block_t> *)takeSignals {
    NSArray<dispatch_block_t> *signals = _signals;
    _signals = nil;
    return signals;
}

- (id)startEncoder:(Class)cls {
    _MTLCommandEncoder *enc = [[cls alloc] initWithCommandBuffer:self];
    [self setCurrentCommandEncoder:enc];
    return enc;
}

- (id<MTLBlitCommandEncoder>)blitCommandEncoder { return [self startEncoder:[TSMtlBlitEncoder class]]; }
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)d { return [self startEncoder:[TSMtlBlitEncoder class]]; }
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
    id enc = TSMtlNewRenderEncoder(self, d);
    [self setCurrentCommandEncoder:enc];
    return enc;
}
- (id<MTLParallelRenderCommandEncoder>)parallelRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
    id enc = TSMtlNewParallelRenderEncoder(self, d);
    [self setCurrentCommandEncoder:enc];
    return enc;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder { return [self startEncoder:[TSMtlComputeEncoder class]]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)t { return [self startEncoder:[TSMtlComputeEncoder class]]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)d { return [self startEncoder:[TSMtlComputeEncoder class]]; }
- (id<MTLResourceStateCommandEncoder>)resourceStateCommandEncoder { return [self startEncoder:[TSMtlResourceStateEncoder class]]; }
- (id<MTLResourceStateCommandEncoder>)resourceStateCommandEncoderWithDescriptor:(MTLResourceStatePassDescriptor *)d {
    return [self startEncoder:[TSMtlResourceStateEncoder class]];
}
- (id<MTLAccelerationStructureCommandEncoder>)accelerationStructureCommandEncoder {
    return [self startEncoder:[TSMtlAccelerationStructureEncoder class]];
}
- (id<MTLAccelerationStructureCommandEncoder>)accelerationStructureCommandEncoderWithDescriptor:(MTLAccelerationStructurePassDescriptor *)d {
    return [self startEncoder:[TSMtlAccelerationStructureEncoder class]];
}

// Present variants (TSMTL_TRACE shows which one an app uses).
- (void)presentDrawable:(id<MTLDrawable>)drawable {
    if (gTSMtlTraceOn) TSMtlTraceOnce(@"presentDrawable:");
    TSMtlStat(TSStatPresents, 1);
    [super presentDrawable:drawable];
}
- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)t {
    if (gTSMtlTraceOn) TSMtlTraceOnce(@"presentDrawable:atTime:");
    TSMtlStat(TSStatPresents, 1);
    [super presentDrawable:drawable atTime:t];
}
- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)d {
    if (gTSMtlTraceOn) TSMtlTraceOnce(@"presentDrawable:afterMinimumDuration:%.4f", d);
    TSMtlStat(TSStatPresents, 1);
    [super presentDrawable:drawable afterMinimumDuration:d];
}

// Everything runs in submission order on one serial queue and one GL context, so waits on our
// own signals are already satisfied on the GPU. Signals update the CPU-visible value of shared
// events once the GPU has executed the command buffer (submitCommandBuffers).
- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value {
    [self recordCommand:^{
        if (![(id)event respondsToSelector:@selector(setSignaledValue:)]) return;
        dispatch_block_t signal = ^{ [(id<MTLSharedEvent>)event setSignaledValue:value]; };
        if (TSEarlyCompletion()) { signal(); return; }
        if (!self->_signals) self->_signals = [NSMutableArray array];
        [self->_signals addObject:signal];
        if (value > [TSIssuedSignals() objectForKey:event].unsignedLongLongValue) [TSIssuedSignals() setObject:@(value) forKey:event];
    }];
}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value {
    [self recordCommand:^{
        uint64_t now = [(id)event respondsToSelector:@selector(signaledValue)] ? [(id<MTLSharedEvent>)event signaledValue] : value;
        now = MAX(now, [TSIssuedSignals() objectForKey:event].unsignedLongLongValue);
        if (now < value) TSMtlWarn(@"wait unsatisfied: event %p at %llu, command buffer waits for %llu", event, now, value);
        if (gTSMtlDrawTrace) fprintf(stderr, "[TSDraw] wait %p for %llu (now %llu)\n", event, value, now);
    }];
}
@end

#pragma mark - Command queue

@implementation TSMtlCommandQueue {
    __weak TSMtlDevice *_device;
}

+ (void)initialize { if (self == [TSMtlCommandQueue class]) TSMtlInstallCatchAll(self); }

- (instancetype)initWithDevice:(id)device descriptor:(MTLCommandQueueDescriptor *)descriptor {
    if ((self = [super initWithDevice:device descriptor:descriptor])) _device = device;
    return self;
}

- (id<MTLDevice>)device { return _device; }

- (id<MTLCommandBuffer>)commandBuffer {
    return [[TSMtlCommandBuffer alloc] initWithQueue:self retainedReferences:YES];
}

- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences {
    return [[TSMtlCommandBuffer alloc] initWithQueue:self retainedReferences:NO];
}

- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)desc {
    return [[TSMtlCommandBuffer alloc] initWithQueue:self retainedReferences:desc.retainedReferences];
}

// Called by -[_MTLCommandQueue] once command buffers are committed, in order.
- (void)submitCommandBuffers:(const id *)buffers count:(NSUInteger)count {
    TSMtlDevice *device = _device;
    for (NSUInteger i = 0; i < count; i++) {
        TSMtlCommandBuffer *cb = buffers[i];
        [cb beginSurfaceUse];
        dispatch_async(device.gpuQueue, ^{
            uint64_t start = mach_absolute_time();
            TSMtlStat(TSStatCommandBuffers, 1);
            [device beginExecution];
            [cb execute];
            // Flush before "scheduled": presentDrawable hands the IOSurface to the
            // compositor from the scheduled handler.
            static int sync = -1;
            if (sync < 0) sync = getenv("TSMTL_SYNC_COMPLETION") != NULL;
            if (sync) glFinish(); else glFlush();
            // glGetError round-trips into the driver: only when logging (B9).
            GLenum err = gTSMtlLogOn ? glGetError() : GL_NO_ERROR;
            if (err != GL_NO_ERROR) TSMtlError(@"GL error 0x%x in command buffer %@", err, cb.label);
            if (gTSMtlStatsOn) {
                static mach_timebase_info_data_t tb;
                if (!tb.denom) mach_timebase_info(&tb);
                TSMtlStat(TSStatGPUBusyMicros, (mach_absolute_time() - start) * tb.numer / tb.denom / 1000);
            }
            [cb didScheduleWithStartTime:start endTime:mach_absolute_time() error:nil];
            if (TSEarlyCompletion()) {
                [device runPostFlushWork];
                [cb endSurfaceUse];
                [cb recycleInlineChunks];
                [self commandBufferDidComplete:cb startTime:start completionTime:mach_absolute_time() error:nil];
                return;
            }
            // Signals, visibility results, IOSurface use and completion once the GPU has run the command buffer (B2),
            // OpenCL kernels included (their GPU work is not ordered before the GL fence).
            NSArray<dispatch_block_t> *signals = [cb takeSignals];
            NSArray<dispatch_block_t> *postFlush = [device takePostFlushWork];
            [device afterGPUCompletes:^{
                for (dispatch_block_t s in signals) s();
                for (dispatch_block_t w in postFlush) w();
                [cb endSurfaceUse];
                [cb recycleInlineChunks];
                [self commandBufferDidComplete:cb startTime:start completionTime:mach_absolute_time() error:nil];
            } clEvent:gTSComputeCLActive ? TSMtlComputeTakeRunEvent() : NULL];
        });
    }
}
@end
