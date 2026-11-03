// TeraScale Metal Shim - private Metal.framework declarations and shared internals.
// The _MTL* base classes are exported by Metal.framework (see Metal.tbd); only the
// selectors we call or override are declared here. Verified on macOS 26.7.1.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>

#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"

@interface _MTLObjectWithLabel : NSObject
@property (copy) NSString *label;
@end

@interface _MTLDevice : NSObject
- (void)initGPUFamilySupport;
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options error:(NSError **)error;
- (void)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options completionHandler:(MTLNewLibraryCompletionHandler)handler;
- (id<MTLBinaryArchive>)newBinaryArchiveWithDescriptor:(MTLBinaryArchiveDescriptor *)desc error:(NSError **)error;
@end

@interface _MTLCommandQueue : _MTLObjectWithLabel
- (instancetype)initWithDevice:(id)device descriptor:(MTLCommandQueueDescriptor *)descriptor;
- (void)commandBufferDidComplete:(id)cb startTime:(uint64_t)start completionTime:(uint64_t)end error:(NSError *)error;
@end

@interface _MTLCommandBuffer : _MTLObjectWithLabel
- (instancetype)initWithQueue:(id)queue retainedReferences:(BOOL)retained;
- (id)commandQueue;
- (void)setCurrentCommandEncoder:(id)encoder;
- (void)didScheduleWithStartTime:(uint64_t)start endTime:(uint64_t)end error:(NSError *)error;
- (void)presentDrawable:(id<MTLDrawable>)drawable;
- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)t;
- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)d;
@end

@interface _MTLCommandEncoder : _MTLObjectWithLabel
- (instancetype)initWithCommandBuffer:(id)commandBuffer;
- (void)endEncoding;
@end

@interface _MTLSamplerState : NSObject
- (instancetype)initWithDevice:(id)device samplerDescriptor:(MTLSamplerDescriptor *)desc;
@end

@interface _MTLDepthStencilState : NSObject
- (instancetype)initWithDevice:(id)device depthStencilDescriptor:(MTLDepthStencilDescriptor *)desc;
@end

// Layout of -[_MTLDevice _limits] (ivar at offset 8, 264 bytes), generated from the
// runtime type encoding. Checked against the live ivar offsets in TSMtlDevice.
typedef struct {
    uint32_t maxFramebufferStorageBits, linearTextureArrayAlignmentBytes, linearTextureArrayAlignmentSlice;
    uint32_t maxTileBuffers, maxTileTextures, maxTileSamplers, maxTileInlineDataSize, minTilePixels;
    uint32_t maxColorAttachments, maxVertexAttributes, maxVertexBuffers, maxVertexTextures, maxVertexSamplers;
    uint32_t maxVertexInlineDataSize, maxInterpolants;
    uint32_t maxFragmentBuffers, maxFragmentTextures, maxFragmentSamplers, maxFragmentInlineDataSize;
    uint32_t maxComputeBuffers, maxComputeTextures, maxComputeSamplers, maxComputeInlineDataSize;
    uint32_t maxComputeLocalMemorySizes, maxTotalComputeThreadsPerThreadgroup, maxComputeThreadgroupMemory;
    float maxLineWidth, maxPointSize;
    uint32_t maxVisibilityQueryOffset, padmaxBufferLength, minConstantBufferAlignmentBytes, minBufferNoCopyAlignmentBytes;
    uint32_t maxTextureWidth1D, maxTextureWidth2D, maxTextureHeight2D, maxTextureWidth3D, maxTextureHeight3D;
    uint32_t maxTextureDepth3D, maxTextureDimensionCube, maxTextureLayers;
    uint32_t linearTextureAlignmentBytes, iosurfaceTextureAlignmentBytes, iosurfaceReadOnlyTextureAlignmentBytes;
    uint32_t deviceLinearTextureAlignmentBytes, deviceLinearReadOnlyTextureAlignmentBytes;
    uint32_t maxFunctionConstantIndices, maxComputeThreadgroupMemoryAlignmentBytes, maxInterpolatedComponents;
    uint32_t maxTessellationFactor, maxIndirectBuffers, maxIndirectTextures, maxIndirectSamplers;
    uint32_t maxIndirectSamplersPerDevice, maxFenceInstances, maxViewportCount, maxCustomSamplePositions;
    uint32_t maxVertexAmplificationFactor, maxVertexAmplificationCount, maxTextureBufferWidth, maxComputeAttributes;
    uint32_t maxIOCommandsInFlight, maxPredicatedNestingDepth, maxAccelerationStructureLevels, maxConstantBufferArguments;
    uint64_t maxBufferLength;
} TSMtlLimits;
_Static_assert(sizeof(TSMtlLimits) == 264, "_MTLDevice _limits layout changed");

// MTLDeviceFeatureProfile values, found by probing getSupportedFamilies():
// 10001 = Mac2 + Common1..3, macOS feature sets 10000..10005, no Metal3 / Apple families.
enum { TSMtlFeatureProfileMac2 = 10001 };

// Real values read from the OpenGL 4.1 core context (TSGL.m).
typedef struct {
    char renderer[128];
    uint64_t vramBytes;
    uint64_t registryID;    // IOAccelerator of the renderer, 0 if unknown
    int maxTextureSize, max3DTextureSize, maxCubeMapSize, maxArrayLayers;
    int maxColorAttachments, maxSamples, maxVertexAttribs, maxTextureUnits, maxVertexTextureUnits;
    int maxUniformBlockSize, maxVaryingComponents, maxTextureBufferSize;
    float maxPointSize, maxLineWidth;
} TSGLInfo;
// Creates the device's OpenGL 4.1 core context and fills in its limits.
CGLContextObj TSGLCreateContext(TSGLInfo *out);

// Metal pixel format -> GL texture format. Unsupported formats map to RGBA8 (supported = NO).
typedef struct {
    GLenum internalFormat, format, type;
    BOOL supported, compressed, integer, isSigned, depth, stencil;
} TSGLFormat;
TSGLFormat TSGLFormatFor(MTLPixelFormat format);

// Catch-all for selectors we have not implemented: answers with a zero/nil return
// value instead of raising "unrecognized selector". Logs each miss once (category
// "unimplemented") so the missing stubs can be found per app.
void TSMtlInstallCatchAll(Class cls);

#import "TSLog.h"
// TSMTL_TRACE=1: logs each distinct render pass and pipeline shape once (formats, sample counts,
// load/store/resolve, IOSurface targets), to see how an app drives the device.
void TSMtlTraceOnce(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
extern int gTSMtlTraceOn;
// TSMTL_DRAW_TRACE=<file>: when <file> appears, the next N executed command buffers log every pass,
// draw and blit to stderr (the file is removed). N = number in the file, else TSMTL_DRAW_TRACE_CBS,
// else 3. GPU queue only.
extern int gTSMtlDrawTrace;
extern int gTSMtlDrawTraceArmed;   // TSMTL_DRAW_TRACE set: encoders record IOSurface seeds
extern int gTSMtlDrawTraceHeavy;   // TSMTL_DRAW_TRACE_HEAVY: GL readbacks per draw (slows the queue, can hide races)
// Bits of TSMTL_DRAW_TRACE_HEAVY (value 1 = all): readbacks can have side effects, so they can be bisected.
enum { TSHeavyTexture = 2, TSHeavySurface = 4, TSHeavyBuffers = 8, TSHeavyTarget = 16, TSHeavySave = 32 };
void TSMtlDrawTraceTick(void);
// Draw trace with TSMTL_DRAW_TRACE_DIR=<dir>: writes <dir>/<name> as a 32 bpp top-down BMP (rows of w BGRA pixels).
void TSMtlDrawTraceSaveBMP(const char *name, int32_t w, int32_t h, const void *base, size_t pitch);

// Statistics: cumulative counters, counted only while someone reads them. TSMTL_STATS=1 prints
// per-interval values to stderr every 5 seconds; the control app (tsmtl / TeraScale Metal.app)
// gets one JSON line per second through the "stats" log category while it holds the lease
// (TSMtlSystem.m). Pipelines and fallbacks are always counted (rare events, shown as totals).
#include <stdatomic.h>
typedef enum {
    TSStatDraws, TSStatPasses, TSStatCommandBuffers, TSStatBufferUploadBytes, TSStatTextureUploadBytes, TSStatReadbacks,
    TSStatTranslations, TSStatDiskCacheHits, TSStatProgramLinks, TSStatProgramHits, TSStatSurfaceCopyBytes,
    TSStatSurfaceWrites, TSStatGPUBusyMicros, TSStatSurfaceBinds, TSStatDrawableWaitMicros, TSStatPresents,
    TSStatPipelines, TSStatFallbacks, TSStatSurfaceRebinds,
    // Pipeline cost (µs): creation as the app sees it, GL link, warm-up draw, AIR translation; rectangle variants.
    TSStatPipelineMicros, TSStatLinkMicros, TSStatWarmupMicros, TSStatTranslateMicros, TSStatVariantLinks,
    TSStatProgramsDrawn, TSStatPipelineSyncMicros,
    // TeraScale Compute: dispatches run (GL and OpenCL paths); compute pipelines with no way to run (always counted);
    // OpenCL runs (= submissions) and their CPU time on the GPU queue; OpenCL program builds (always counted).
    TSStatDispatches, TSStatComputeRejected, TSStatCLRuns, TSStatCLSubmitMicros, TSStatCLBuilds,
    // Dispatches encoded (B2: recorded - run - skipped - inert = lost, e.g. never committed), dispatches the
    // GPU queue dropped (skipped), dispatches of pipelines with no path (inert); OpenCL program binaries loaded
    // from the disk cache (always counted); GPU time of OpenCL kernels (G2, profiled while stats are on).
    TSStatComputeRecorded, TSStatComputeSkipped, TSStatComputeInert, TSStatCLBinaryHits, TSStatCLGPUMicros,
    // X1: nextDrawable calls that blocked for 2 ms or more.
    TSStatDrawableBlocks,
    // Translations taken from a precompiled .mslbundle (always counted).
    TSStatBundleHits,
    // P1: variants linked for device buffers bound at offsets that are not 16-aligned (always counted).
    TSStatUnalignedVariants,
    // P3: pipelines created with the variant they drew last time (recorded) instead of the base program.
    TSStatPredictedVariants,
    // B6: render passes that found their framebuffer in the cache.
    TSStatFBOHits,
    TSStatCount
} TSStat;
enum { TSStatsByEnv = 1, TSStatsByLease = 2 };
extern int gTSMtlStatsOn;   // TSStatsByEnv | TSStatsByLease
extern _Atomic uint64_t gTSMtlStats[TSStatCount];
extern _Atomic int64_t gTSMtlAllocatedBytes;   // all devices of the process
static inline void TSMtlStat(TSStat s, uint64_t n) {
    if (gTSMtlStatsOn) atomic_fetch_add_explicit(&gTSMtlStats[s], n, memory_order_relaxed);
}
static inline void TSMtlStatAlways(TSStat s, uint64_t n) { atomic_fetch_add_explicit(&gTSMtlStats[s], n, memory_order_relaxed); }

// /Library/GPUBundles/TeraScaleMTLDriver.config, or TSMTL_CONFIG_DIR (TSMtlSystem.m).
NSString *TSMtlConfigDir(void);

// Phase 4 (TSMtlSystem.m): who this process is and whether the shim serves it.
typedef struct {
    BOOL enabled;
    const char *reason;          // auto, list, critical, outside, nopolicy, injected
    __unsafe_unretained NSString *appId, *name, *path;   // immortal (kept by a static)
} TSMtlPolicy;
const TSMtlPolicy *TSMtlProcessPolicy(void);
void TSMtlStartStatsLease(void);

// Pixel format storage info (block-compressed formats use 4x4 blocks).
typedef struct { uint32_t bytesPerBlock, blockWidth, blockHeight; } TSPixelFormatInfo;
TSPixelFormatInfo TSPixelFormatGetInfo(MTLPixelFormat format);

@class TSMtlDevice;

// CAMetalLayer adjustments for layers presenting on our device (TSMtlLayer.m). Idempotent.
void TSMtlInstallLayerTuning(void);

// Inert object for features we accept but do not run (ICB, argument encoders,
// acceleration structures, counters, ...). Conforms to the protocols it is created
// with and answers every selector of those protocols with zero/nil.
@interface TSMtlInert : _MTLObjectWithLabel
- (instancetype)initWithDevice:(id<MTLDevice>)device protocols:(NSArray<Protocol *> *)protocols;
@property (readonly) id<MTLDevice> device;
@end

@interface TSMtlDevice : _MTLDevice <MTLDevice>
@property (readonly) dispatch_queue_t gpuQueue;   // serial GPU thread: the only place GL is called
@property (readonly) CGLContextObj glContext;
@property (readonly) const TSGLInfo *glInfo;
@property (readonly) uint64_t executionEpoch;     // bumped for every executed command buffer
@property (nonatomic) void *passCache;            // GPU queue: render-pass framebuffers and vertex array (TSMtlRender.m)
- (void)trackAllocation:(int64_t)delta;
// Run on the GPU queue with the GL context current. gpuSync runs inline when already on it.
- (void)gpuSync:(dispatch_block_t)block;
- (void)gpuAsync:(dispatch_block_t)block;
- (BOOL)isOnGPUQueue;
- (void)beginExecution;   // GPU queue: makes the context current and bumps executionEpoch
// GPU queue: work that needs the command buffer's GL commands submitted (glFlush) and must finish
// before completion is reported, e.g. reading occlusion query results into visibility buffers.
- (void)addPostFlushWork:(dispatch_block_t)work;
- (void)runPostFlushWork;
- (NSArray<dispatch_block_t> *)takePostFlushWork;
// GPU queue: flushes and runs work once the GPU has executed every GL command issued so far
// (glFenceSync, polled without blocking). Works run in call order.
- (void)afterGPUCompletes:(dispatch_block_t)work;
// Same, once `clEvent` (TSMtlComputeTakeRunEvent, owned from here on) has completed too.
- (void)afterGPUCompletes:(dispatch_block_t)work clEvent:(void *)clEvent;
@end

@interface TSMtlBuffer : _MTLObjectWithLabel <MTLBuffer>
- (instancetype)initWithDevice:(TSMtlDevice *)device length:(NSUInteger)length options:(MTLResourceOptions)options
                         bytes:(void *)bytes deallocator:(void (^)(void *, NSUInteger))deallocator;
// GPU queue: GL buffer object holding the current contents (uploaded when stale).
- (GLuint)glBuffer;
// GPU queue: R32UI texture buffer over glBuffer, for device-memory reads in shaders.
- (GLuint)glTextureBuffer;
// GPU queue: RGBA32UI / RG32UI texture buffers over glBuffer, for 16- / 8-byte reads. The GL storage is
// padded to a multiple of 16 bytes, so the last block of the buffer is a whole texel of both views.
- (GLuint)glTextureBuffer4;
- (GLuint)glTextureBuffer2;
// GPU queue: bumped whenever glBuffer re-specifies the GL storage (texture-buffer views must re-attach).
- (uint32_t)glStorageGeneration;
// TeraScale Compute, GPU queue: an OpenCL kernel is about to write the GL buffer (snapshot for the merge) / has
// written it (GL is newer than the CPU copy until syncFromGL merges the bytes the GPU changed back into it, at
// command buffer completion for shared and managed buffers, or when the CPU copy is next needed on the GPU queue).
- (void)prepareGPUWrite;
- (void)didWriteGPU;
- (void)syncFromGL;
@property (readonly) BOOL gpuAhead;   // GL holds GPU writes the CPU copy lacks
// GPU queue: `range` as the GPU sees it now (GL after an OpenCL write, else the CPU copy); reads only that range.
- (void)getGPUBytes:(void *)dst range:(NSRange)range;
// The CPU copy was changed by us (blits); forces a re-upload even for private buffers.
- (void)didWriteCPU;
- (void)didWriteRange:(NSRange)range;
@end

// A render-target image of a GL texture: target is the glFramebufferTexture2D target (a cube face for cube maps),
// layer >= 0 selects glFramebufferTextureLayer. target 0 = no attachment.
typedef struct { GLenum target; GLuint name; GLint level, layer; } TSGLAttachment;
void TSGLAttach(GLenum attachment, const TSGLAttachment *a);   // on the bound draw framebuffer

@interface TSMtlTexture : _MTLObjectWithLabel <MTLTexture>
- (instancetype)initWithDevice:(TSMtlDevice *)device descriptor:(MTLTextureDescriptor *)desc
                     iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane;
- (instancetype)initWithDevice:(TSMtlDevice *)device descriptor:(MTLTextureDescriptor *)desc
                        buffer:(TSMtlBuffer *)buffer offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow;
// CPU address of (level, slice) plus its row and image pitch.
- (uint8_t *)addressForLevel:(NSUInteger)level slice:(NSUInteger)slice rowPitch:(NSUInteger *)rowPitch imagePitch:(NSUInteger *)imagePitch;
- (void)beginAccess;
- (void)endAccess;
// CPU side coherency (any thread): pull GPU-rendered data back before reading,
// and record CPU writes so the GL mirrors re-upload.
- (void)syncForCPURead;
- (void)didWriteCPU;
// GPU queue: GL texture for sampling, (re)uploaded when stale; target in *target.
- (GLuint)glTextureForSampling:(GLenum *)target;
// GPU queue: attach as a render target of the bound draw framebuffer.
- (BOOL)attachToFramebuffer:(GLenum)attachment level:(NSUInteger)level slice:(NSUInteger)slice depthPlane:(NSUInteger)plane;
// GPU queue: the GL image attachToFramebuffer would attach (brought up to date the same way), without attaching it.
- (BOOL)glAttachment:(TSGLAttachment *)out level:(NSUInteger)level slice:(NSUInteger)slice depthPlane:(NSUInteger)plane;
// GPU queue: GL wrote this texture (render pass, resolve, mipmap generation).
- (void)didRenderGL;
// GPU queue: texture-to-texture copy done by GL (glBlitFramebuffer), without a round trip through
// the CPU copies. NO when the formats or targets need the CPU path.
- (BOOL)gpuCopyFromSlice:(NSUInteger)srcSlice level:(NSUInteger)srcLevel origin:(MTLOrigin)srcOrigin size:(MTLSize)size
               toTexture:(TSMtlTexture *)dst slice:(NSUInteger)dstSlice level:(NSUInteger)dstLevel origin:(MTLOrigin)dstOrigin;
// GPU queue: GL texture an OpenCL kernel reads or writes (IOSurfaces: the rectangle, in place); target in *target.
- (GLuint)glTextureForCompute:(GLenum *)target;
// GPU queue: the GL_TEXTURE_RECTANGLE aliasing this texture's IOSurface, for sampling in place;
// 0 when the texture is not a plain 2D IOSurface texture or the driver refused the surface format.
- (GLuint)glRectangleForSampling;
- (NSString *)surfaceCoherencyReport;
- (NSString *)glContentReport;          // TSMTL_DRAW_TRACE: opaque pixels in the GL copy that would be sampled   // TSMTL_DRAW_TRACE: CPU view of the IOSurface vs what GL samples
@property (readonly) TSGLFormat glFormat;
@end

@interface TSMtlSamplerState : _MTLSamplerState <MTLSamplerState>
- (GLuint)glSampler;            // GPU queue
- (GLuint)glRectangleSampler;   // GPU queue: the variant for rectangle textures
- (MTLSamplerDescriptor *)samplerDescriptor;
@end

// Depth/stencil state converted to GL enums at creation (B2: no Objective-C at draw time).
typedef struct { GLenum func, fail, depthFail, pass; GLuint readMask, writeMask; } TSGLStencilFace;
typedef struct {
    uint8_t depthTest, depthWrite;
    GLenum depthFunc;
    TSGLStencilFace face[2];   // front, back
} TSGLDepthStencil;

@interface TSMtlDepthStencilState : _MTLDepthStencilState <MTLDepthStencilState>
@property (readonly) MTLDepthStencilDescriptor *descriptor;
@property (readonly) const TSGLDepthStencil *glState;
@end

// Binding of a GL program resource to a Metal slot (stage 0 = vertex, 1 = fragment).
// kind: 0 = texture + sampler slot, 1 = texture + constexpr sampler (key; aux = its GL sampler),
// 2 = device buffer as R32UI texture buffer (aux = location of the <name>_off uniform),
// 3 = the RGBA32UI view of a device buffer (<name>_4; aux = location of <name>_off as well), 4 = its RG32UI view (<name>_2).
// rect: the program samples this slot as GL_TEXTURE_RECTANGLE (IOSurface variant, see TSAirTranslator rectSlotFor:).
typedef struct { uint8_t stage, index, sampler, kind, rect; GLint unit; GLint size; GLint aux; uint64_t key; } TSGLBinding;
// Variant slot of a device buffer (see rectSlots): TSSlotBuffer | stage << 8 | index.
enum { TSSlotBuffer = 1 << 9 };

// Render pipeline fixed-function and vertex-input state in GL terms, built at creation (B2).
typedef struct {
    GLint size; GLenum type; uint8_t normalized, integer;
    uint8_t buffer;                     // Metal vertex buffer index
    uint8_t step;                       // MTLVertexStepFunction
    uint32_t offset, stride, stepRate;  // stride from the layout (0 = take it from setVertexBuffer:attributeStride:)
} TSGLAttrib;
typedef struct {
    uint8_t mask[4], blend;
    GLenum rgbOp, alphaOp, srcRGB, dstRGB, srcAlpha, dstAlpha;
} TSGLColorState;
typedef struct {
    uint16_t attribMask;                // vertex attribute locations in use
    TSGLAttrib attribs[16];
    TSGLColorState color[8];
    uint8_t multisample, alphaToCoverage;
    uint8_t usesVertexID;               // the vertex shader reads gl_VertexID: draws cannot fold buffer offsets into `first`
} TSGLPipelineState;
// Last values written to per-program uniforms (GPU queue only), so redundant glUniform calls are skipped.
typedef struct { GLint baseInstance, baseVertex; GLint bufferOffset[32]; GLint texInfo[8]; } TSGLProgramUniforms;
void TSGLBakePipeline(MTLRenderPipelineDescriptor *desc, TSGLPipelineState *out);
void TSGLBakeDepthStencil(MTLDepthStencilDescriptor *desc, TSGLDepthStencil *out);

// A linked GL program with its ABI bindings (TSMtlPipeline.m); shared by every pipeline with the same
// vertex + fragment source (C2). GPU queue only after creation.
@interface TSGLProgram : NSObject {
@public
    TSMtlDevice *_device;
    GLuint _program;
    TSGLBinding *_blocks, *_textures, _infos[8];
    NSUInteger _blockCount, _textureCount, _infoCount;
    GLint _baseInstanceLocation, _baseVertexLocation;
    GLint _gridLocation, _threadgroupLocation, _outSizeLocation;   // kernels as fragment shaders: ts_grid, ts_tg, ts_out_size
    TSGLProgramUniforms _uniforms;
    GLenum *_targets;   // texture target of each _textures entry (from the GLSL sampler type)
    BOOL _drawn;        // used by a draw at least once (stats: links minus drawn = wasted links)
}
@end

// Programs linked so far (GPU queue): a link (plus its warm-up draw) changes GL bindings, so a render
// pass that causes one mid-replay restores its framebuffer and forgets its GL state shadow.
extern uint64_t gTSGLProgramLinkCount;

// New GL sampler with the state of `sampler` (0 = defaults) that a GL_TEXTURE_RECTANGLE accepts:
// no mipmap filter, clamp instead of repeat. GPU queue.
GLuint TSGLCreateRectangleSampler(GLuint sampler);
// Same for a constexpr sampler word, cached like TSGLSamplerForConstexpr. GPU queue.
GLuint TSGLRectangleSamplerForConstexpr(uint64_t key);

@interface TSMtlRenderPipelineState : _MTLObjectWithLabel <MTLRenderPipelineState>
- (instancetype)initWithDevice:(TSMtlDevice *)device descriptor:(MTLRenderPipelineDescriptor *)desc error:(NSError **)error;
@property (readonly) MTLRenderPipelineDescriptor *descriptor;
@property (readonly) const TSGLPipelineState *glState;
@property (readonly) TSGLProgramUniforms *programUniforms;   // GPU queue only
@property (readonly) GLuint glProgram;
@property (readonly) BOOL usesFallback;
@property (readonly) const TSGLBinding *uniformBlocks;   // binding point = stage * 31 + index
@property (readonly) NSUInteger uniformBlockCount;
@property (readonly) const TSGLBinding *textures;        // unit = texture unit
// <stage>texinfo<N> uniforms (ivec2 sample count, mip levels of the texture at slot N; aux = location).
@property (readonly) const TSGLBinding *textureInfos;
@property (readonly) NSUInteger textureInfoCount;
@property (readonly) NSUInteger textureCount;
@property (readonly) GLint baseInstanceLocation, baseVertexLocation;
// Variant slots: 2D textures the shaders can sample as rectangle textures, and device buffers whose loads
// are coalesced (TSSlotBuffer set: the variant reads word by word, for bindings not 16-aligned).
// Bit i of a mask = rectSlots[i] (TSSlotBuffer | stage << 8 | index). programForRectMask: links the
// variant on first use (GPU queue).
@property (readonly) const uint16_t *rectSlots;
@property (readonly) NSUInteger rectSlotCount;
- (TSGLProgram *)programForRectMask:(uint32_t)mask;
@property (readonly) TSGLProgram *baseProgram;   // GPU queue; linked on first need when creation linked a recorded variant
// GPU queue: the encoder draws with the variant `mask`; recorded for the next creation of this pipeline (P3).
- (void)noteDrawnMask:(uint32_t)mask;
@property (readonly) NSString *profileName;   // "vertex/fragment" function names, interned (TSMTL_PROFILE)
@end
extern int gTSMtlProfileOn;

// TeraScale Compute: System.Compute in policy.plist (Experimental.Compute until 0.9.0) (TSMtlSystem.m); TSMTL_COMPUTE=0/1 overrides it.
BOOL TSMtlComputeEnabled(void);
// TeraScale Swift: System.Swift in policy.plist (TSMtlSystem.m, on by default since 0.12.2), independent of the shim's
// own policy; TSMTL_SWIFT=0/1
// overrides it. *validate: System.Swift.Validate (check every fast answer against the runtime).
BOOL TSMtlSwiftEnabled(BOOL *validate, const char **reason);

// OpenCL path (TSMtlComputeCL.m): a kernel built on the device's CL context, shared by pipelines with the same source.
// The cl_kernel goes away with the CL context after a long idle time (M4) and is rebuilt from source/options
// (disk cache) at the next dispatch.
@interface TSCLKernel : NSObject {
@public
    void *kernel;                  // cl_kernel; NULL until built, and after the context is released
    NSData *args;                  // TSCLArgSpec[]
    size_t maxThreads;             // CL_KERNEL_WORK_GROUP_SIZE
    NSUInteger staticThreadgroupMemory;
    BOOL barriers, shapeSensitive; // the kernel synchronizes / reads its threadgroup shape (no re-tiling)
    BOOL guarded;                  // returns for threads outside the grid: one enqueue, any work-group shape (C4)
    BOOL built;                    // a build was attempted (failure says why it did not work)
    NSString *name, *failure, *source, *options;
    void *argCache;                // GPU queue: arguments last set on the cl_kernel (C3)
    _Atomic uint64_t gpuNanos, gpuDispatches;   // G2: profiled GPU time
}
@end

// Compute pipeline. With compute on, a kernel the translator expresses as a fragment shader (one texture
// written at thread_position_in_grid, see TSAirTranslator) gets a GL program and its dispatches run as GL
// passes; any other kernel stays inert (dispatches are no-ops, as with compute off) and computePath says why.
@interface TSMtlComputePipelineState : TSMtlInert <MTLComputePipelineState>
- (instancetype)initWithDevice:(TSMtlDevice *)device function:(id<MTLFunction>)function;
@property (readonly) NSString *computePath;      // "gl", "cl", "off", or the reason the kernel does not run
@property (readonly) BOOL runsOnGL;
@property (readonly) TSCLKernel *clKernel;       // OpenCL path (runsOnGL = NO)
@property (readonly) NSInteger outputTextureIndex;   // texture slot the kernel writes (GL path)
@property (readonly) const uint16_t *rectSlots;  // as in TSMtlRenderPipelineState (fragment stage only)
@property (readonly) NSUInteger rectSlotCount;
- (TSGLProgram *)programForRectMask:(uint32_t)mask;   // GPU queue
@end

// TeraScale Compute, OpenCL path: AIR kernel -> OpenCL C 1.2 (TSAirOpenCL.m). The CL kernel "ts_kernel" takes
// uint4 ts_grid, ts_goff, ts_ngroups, ts_tg, uint ts_null (bit n: no texture at index n), then one group of
// arguments per TSCLArgSpec, in order:
//   buffer: __global uchar *base, uint byte offset;  local: __local uchar * (size from setThreadgroupMemoryLength);
//   texture: one image (two when readWrite: read view, write view);
//   sampler: sampler_t, uint addressing word (per-axis addressing done in the kernel, 0 = none; TSAirOpenCL.m).
typedef enum { TSCLArgBuffer, TSCLArgLocal, TSCLArgTexture, TSCLArgSampler } TSCLArgKind;
typedef struct {
    uint8_t kind, slot;
    uint8_t written;     // buffer or texture the kernel may write
    uint8_t readWrite;   // texture: access::read_write
    uint8_t dims, array; // texture shape
    uint8_t nullable;    // texture: the kernel calls is_null_texture on it (unbound = placeholder image + ts_null bit)
    uint8_t lod;         // texture: read, written or sampled at a level that may not be 0
} TSCLArgSpec;
@interface TSCLKernelSource : NSObject
@property NSString *source, *options;
@property NSData *args;                          // TSCLArgSpec[]
@property NSUInteger staticThreadgroupMemory;
@property BOOL barriers, shapeSensitive, guarded;
@end
TSCLKernelSource *TSAirTranslateOpenCL(NSData *bitcode, NSString **error);
NSString *TSAirOpenCLTag(void);

// GLSL source registered by hand for an MTLFunction name (tests, workarounds).
NSString *TSMtlGLSLForFunction(id<MTLFunction> function);

// AIR -> GLSL (TSAirTranslator.m). `interpolation` maps varying keys to the qualifiers the
// fragment shader uses (GLSL 4.10 requires them to match); a fragment translation returns them.
NSString *TSAirTranslate(NSData *bitcode, NSDictionary<NSString *, NSString *> *interpolation,
                         NSDictionary<NSString *, NSString *> **varyingQualifiers, NSString **error);
NSString *TSAirTranslatorTag(void);
// Same, with explicit options (tests compare the translation modes).
enum { TSAirNoPasses = 1, TSAirNoStructure = 2, TSAirNoCoalesce = 4, TSAirNoUnroll = 8 };
NSString *TSAirTranslateWithFlags(NSData *bitcode, NSDictionary<NSString *, NSString *> *interpolation,
                                  NSDictionary<NSString *, NSString *> **varyingQualifiers, NSString **error, unsigned flags);
// Same, resolving visible function references (`<name>.MTL_VISIBLE_FN_REF`) with the bitcode of the
// pipeline's linked functions, by name.
NSString *TSAirTranslateLinked(NSData *bitcode, NSDictionary<NSString *, NSData *> *linked,
                               NSDictionary<NSString *, NSString *> *interpolation,
                               NSDictionary<NSString *, NSString *> **varyingQualifiers, NSString **error, unsigned flags);
BOOL TSAirNeedsLinking(NSData *bitcode);
// Inputs of a translation (bitcode, varying qualifiers, linked functions) and SHA-256 in hex (TSMtlPipeline.m):
// the digest names the shader inside a precompiled .mslbundle.
NSData *TSMtlTranslationKey(NSData *bitcode, NSDictionary *interpolation, NSDictionary<NSString *, NSData *> *linked);
NSString *TSMtlHexDigest(NSData *data);
unsigned TSAirDefaultFlags(void);   // from TSMTL_NO_PASSES / TSMTL_NO_STRUCT
// Decodes a constexpr sampler word into GL sampler state (TSMtlPipeline.m). GPU queue.
GLuint TSGLSamplerForConstexpr(uint64_t key);
// New GL sampler object with the state of a Metal sampler descriptor. GPU queue.
GLuint TSGLCreateSampler(MTLSamplerDescriptor *desc);

@interface TSMtlCommandQueue : _MTLCommandQueue <MTLCommandQueue>
@end

@interface TSMtlCommandBuffer : _MTLCommandBuffer <MTLCommandBuffer>
- (void)recordCommand:(dispatch_block_t)command;
// An OpenCL dispatch: consecutive ones form one CL run; execute ends the run before any other command.
- (void)recordComputeCommand:(dispatch_block_t)command;
- (void)recordCommands:(NSArray<dispatch_block_t> *)commands;
- (void)execute;
// Encode time: the command buffer reads or writes this IOSurface. Like Metal, its use count is held
// from commit to GPU completion, so other processes see IOSurfaceIsInUse (Chrome reuses tiles by it).
- (void)useSurface:(IOSurfaceRef)surface;
// Encode time: setBytes data, copied into this command buffer's inline chunk (C1). Returns the chunk and the offset.
- (id<MTLBuffer>)inlineBufferWithBytes:(const void *)bytes length:(NSUInteger)length offset:(NSUInteger *)offset;
@end
// Bindings of one dispatch, captured at encode time (Metal semantics: the state at the dispatch call).
@interface TSComputeDispatch : NSObject {
@public
    TSMtlComputePipelineState *pipeline;
    id<MTLBuffer> buffers[31];
    NSUInteger offsets[31];
    NSUInteger threadgroupMemory[31];
    id<MTLTexture> textures[32];
    id<MTLSamplerState> samplers[16];
    MTLSize grid, threadgroup;
    id<MTLBuffer> indirect;      // dispatchThreadgroupsWithIndirectBuffer: grid = threadgroups read at execution
    NSUInteger indirectOffset;
}
@end
TSCLKernel *TSMtlCLKernelForFunction(TSMtlDevice *device, id<MTLFunction> function, NSString **error);
void TSMtlCLDispatch(TSComputeDispatch *d);            // GPU queue
void TSMtlComputeEndRun(void);                          // GPU queue: submits the open CL run, if any, and joins
// GPU queue (B4): submits the open CL run on the runtime's submitter thread; GL commands may be encoded after it,
// but TSMtlComputeJoin (or TSMtlComputeEndRun) must come before any flush, fence or readback.
void TSMtlComputeEndRunAsync(void);
void TSMtlComputeJoin(void);
// GPU queue: cl_event completing after every OpenCL run ended so far that no completion has taken yet (NULL if
// none). A GL fence does not wait for CL kernels GL does not depend on, so completion also waits for this.
void *TSMtlComputeTakeRunEvent(void);
BOOL TSMtlComputeEventDone(void *event);                // non-blocking
void TSMtlComputeEventRelease(void *event);
// GPU queue: before glDelete* or a re-specification of a GL object OpenCL may have wrapped (GL recycles names).
void TSMtlComputeForget(TSMtlDevice *device, GLuint name, GLenum target);
// A4/A5: translates and builds, in the background, the OpenCL kernels of a library a pipeline will need
// (known kernels, or all with TSMTL_CL_PREWARM=*; names separated by commas otherwise).
void TSMtlComputePrewarmLibrary(TSMtlDevice *device, id<MTLLibrary> library);
// TSMtlPipeline.m: the kernel would take the GL path (fragment pass) if a pipeline were made from it.
BOOL TSMtlKernelFitsGL(id<MTLFunction> function);
// Disk cache file for derived data (GLSL translations, OpenCL binaries) keyed by a SHA-256 of `key`;
// nil when no cache directory is writable or TSMTL_NO_DISK_CACHE is set. kind: "glsl", "cl".
NSURL *TSMtlDiskCacheFile(NSString *kind, NSData *key);
BOOL TSMtlDiskCacheWrite(NSURL *file, NSData *data);
// Statistics (TSMtlSystem.m): per-kernel OpenCL GPU time since the last call, {name: [ms, dispatches]}.
NSDictionary *TSMtlComputeKernelTimes(void);
// M3 (TSMtlSystem.m): VRAM pressure of the Radeon, read at most once per second from the IORegistry
// (system-wide counters). 0 none, 1 VRAM nearly full, 2 the driver is evicting (paging VRAM out).
int TSMtlVRAMPressure(void);
extern int gTSComputeCLActive;                          // some device of the process has an OpenCL context
extern _Thread_local void *gTSCLOpenRun;                // GPU queue: runtime with an open run

// The IOSurfaces of a render pass's attachments (useSurface: for each).
void TSMtlUsePassSurfaces(TSMtlCommandBuffer *cb, MTLRenderPassDescriptor *desc);
// GPU queue: before glDeleteTextures(name): drops the cached render-pass framebuffers holding it (GL recycles names).
void TSMtlForgetFramebufferTexture(TSMtlDevice *device, GLuint name);

