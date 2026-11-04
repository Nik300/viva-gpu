// Viva Metal - private Metal.framework declarations and the driver's classes.
// The _MTL* base classes are exported by Metal.framework; only the selectors we call or override are declared.
// Base layer (catch-all, inert objects, log, statistics, pixel format info) comes from metal-shim unchanged; the
// GPU work goes through vmg (../vmg.h): Gallium + NIR, llvmpipe on the Mac, Panfrost on the phone.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#include "../vmg.h"

// macOS-only Metal pixel formats (marked unavailable in the iOS SDK), by value.
enum { VM_PF_D24S8 = 255, VM_PF_X24S8 = 262 };

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

// (Viva: VMDevice.m sets _limits by field name from the ivar's type encoding; this struct is metal-shim's macOS view.)
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


@class VMDevice;

// CAMetalLayer adjustments for layers presenting on our device (VMLayer.m). Idempotent.
void TSMtlInstallLayerTuning(void);

@interface TSMtlInert : _MTLObjectWithLabel
- (instancetype)initWithDevice:(id<MTLDevice>)device protocols:(NSArray<Protocol *> *)protocols;
@property (readonly) id<MTLDevice> device;
@end

@class VMBuffer;

// The device. One vmg device (pipe_screen + pipe_context) driven from a serial GPU queue.
@interface VMDevice : _MTLDevice <MTLDevice>
@property (readonly) vmg_device *vmg;
@property (readonly) dispatch_queue_t gpuQueue;   // the only place vmg_cmd_* / maps run
@property (readonly) dispatch_queue_t completionQueue;   // waits for command buffers in the kernel, in commit order
- (instancetype)initWithDriver:(const char *)driver;
- (void)gpuSync:(dispatch_block_t)block;
- (void)gpuAsync:(dispatch_block_t)block;
- (BOOL)isOnGPUQueue;
- (void)trackAllocation:(int64_t)delta;
// Command buffers' setBytes chunks, reused once the command buffer that used one has completed (a new buffer per
// command buffer cost a buffer creation, and a dispatch_sync on the GPU queue, at every frame).
- (VMBuffer *)takeInlineChunk:(NSUInteger)length;
- (void)returnInlineChunk:(VMBuffer *)chunk;
@end

@interface VMBuffer : _MTLObjectWithLabel <MTLBuffer>
- (instancetype)initWithDevice:(VMDevice *)device length:(NSUInteger)length options:(MTLResourceOptions)options
                         bytes:(void *)bytes deallocator:(void (^)(void *, NSUInteger))deallocator;
@property (readonly) vmg_resource *vmg;
@end

@interface VMTexture : _MTLObjectWithLabel <MTLTexture>
- (instancetype)initWithDevice:(VMDevice *)device descriptor:(MTLTextureDescriptor *)desc iosurface:(IOSurfaceRef)surface
                         plane:(NSUInteger)plane;
- (instancetype)initWithDevice:(VMDevice *)device descriptor:(MTLTextureDescriptor *)desc buffer:(VMBuffer *)buffer
                        offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow;
@property (readonly) vmg_texture *vmg;
@end

@interface VMSamplerState : _MTLSamplerState <MTLSamplerState>
@property (readonly) vmg_sampler *vmg;
@property (readonly) float lodMin, lodMax;
@end

@interface VMDepthStencilState : _MTLDepthStencilState <MTLDepthStencilState>
@property (readonly) vmg_dsa *vmg;
@end

// AIR bitcode of a function (specialized, as Metal hands it to drivers) and of its linked visible functions.
NSData *VMBitcodeOfFunction(id<MTLFunction> function);

@interface VMRenderPipelineState : _MTLObjectWithLabel <MTLRenderPipelineState>
- (instancetype)initWithDevice:(VMDevice *)device descriptor:(MTLRenderPipelineDescriptor *)desc error:(NSError **)error;
@property (readonly) vmg_render_pipeline *vmg;   // NULL when the shaders could not be translated (draws are skipped)
@property (readonly) NSString *failure;
@end

@interface VMComputePipelineState : _MTLObjectWithLabel <MTLComputePipelineState>
- (instancetype)initWithDevice:(VMDevice *)device function:(id<MTLFunction>)function error:(NSError **)error;
@property (readonly) vmg_compute_pipeline *vmg;  // NULL when the kernel could not be translated (dispatches are skipped)
@property (readonly) NSString *failure;
@end

@interface VMCommandQueue : _MTLCommandQueue <MTLCommandQueue>
@end

@interface VMCommandBuffer : _MTLCommandBuffer <MTLCommandBuffer>
- (void)recordCommand:(dispatch_block_t)command;
// Encode time: setBytes data, copied into this command buffer's inline chunk. Returns the chunk and the offset.
- (VMBuffer *)inlineBufferWithBytes:(const void *)bytes length:(NSUInteger)length offset:(NSUInteger *)offset;
// Keeps an object alive until the command buffer completes (unretained-reference command buffers too).
- (void)keepAlive:(id)object;
- (void)useSurface:(IOSurfaceRef)surface;
// The GPU writes it (render target, blit destination, shader write): its IOSurface, if any, is written by this command
// buffer, and commit either promises it to the kernel (K0i) or submits before returning.
- (void)writeTexture:(id<MTLTexture>)texture;
@property (readonly) BOOL writesSurface;
// Commit: a kernel promise on the written IOSurfaces, or 0 (see VMCommands.m).
- (uint32_t)promiseWrittenSurfaces:(VMDevice *)device;
@property (nonatomic) void *vmgTrace;   // VMG_TRACE_FRAME record (VMCommands.m)
@end

id<MTLRenderCommandEncoder> VMNewRenderEncoder(VMCommandBuffer *cb, MTLRenderPassDescriptor *desc);
id<MTLComputeCommandEncoder> VMNewComputeEncoder(VMCommandBuffer *cb);
id<MTLBlitCommandEncoder> VMNewBlitEncoder(VMCommandBuffer *cb);
