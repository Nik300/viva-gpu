// TeraScale Metal Shim - render command encoder over OpenGL 4.1.
// Encoding (app thread) packs commands as POD records into an arena and drops set* calls
// that repeat the current state. On the GPU queue one block per pass replays the arena
// into a TSGLRenderPass, which keeps a shadow of the GL state so that each draw issues
// only the GL calls whose values changed (docs/OTTIMIZZAZIONE.md, B1-B4).
#import "TSPrivate.h"
#import <dlfcn.h>
#import <os/lock.h>

#pragma mark - GL streaming buffers (GPU queue only)

// All setBytes payloads of a recording live in one staging buffer, re-specified with
// glBufferData when the replay starts (the driver gives draws still in flight the old
// storage, so there is no wait). Constant data bound at offsets GL cannot use directly
// (not 256-aligned) is copied into a ring that is orphaned only when it wraps; `gen`
// changes on every orphan.
static GLuint gStagingBuffer;
typedef struct { GLuint buffer; GLintptr offset, capacity; uint32_t gen; } TSGLRing;
static TSGLRing gCopyRing = { 0, 0, 1 << 20, 1 };

static void TSRingReserve(TSGLRing *r, GLsizeiptr bytes) {
    if (!r->buffer) glGenBuffers(1, &r->buffer);
    if (r->gen > 1 && r->offset + bytes <= r->capacity) return;
    r->capacity = MAX(r->capacity, bytes * 2);
    glBindBuffer(GL_COPY_WRITE_BUFFER, r->buffer);
    glBufferData(GL_COPY_WRITE_BUFFER, r->capacity, NULL, GL_STREAM_DRAW);
    r->offset = 0;
    r->gen++;
}

static GLintptr TSRingWrite(TSGLRing *r, const void *data, GLsizeiptr size) {
    GLsizeiptr aligned = (MAX(size, 16) + 255) & ~(GLsizeiptr)255;
    TSRingReserve(r, aligned);
    GLintptr at = r->offset;
    glBindBuffer(GL_COPY_WRITE_BUFFER, r->buffer);
    if (size) glBufferSubData(GL_COPY_WRITE_BUFFER, at, size, data);
    TSMtlStat(TSStatBufferUploadBytes, size);
    r->offset = at + aligned;
    return at;
}

#pragma mark - Draw profiling (TSMTL_PROFILE=1)

// One GL_TIME_ELAPSED query per draw, summed per pipeline (vertex/fragment function names) and printed
// every 5 s, heaviest first. Results are collected when available, never waited for in a frame.
int gTSMtlProfileOn;
static struct { GLuint query; __unsafe_unretained NSString *name; } gProf[8192];
static int gProfHead, gProfTail;
static NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *gProfTotals;   // name -> [ns, draws]
static uint64_t gProfLastPrint;

__attribute__((constructor)) static void TSProfileInit(void) { gTSMtlProfileOn = getenv("TSMTL_PROFILE") != NULL; }

// Bisection knobs for rendering bugs (docs/FINDINGS-RENDERING.md): TSMTL_NO_SHADOW=1 re-issues every GL
// state for every draw; TSMTL_NO_DEDUP=1 keeps every set* call the app encodes; TSMTL_SYNC_DRAW=1 glFinish per draw.
static int gTSNoShadow, gTSNoDedup, gTSSyncDraw, gTSPassEndSync, gTSPassLog, gTSNoDepth;
__attribute__((constructor)) static void TSBisectInit(void) {
    gTSNoDepth = getenv("TSMTL_NO_DEPTH") != NULL;   // depth test off everywhere (bisection only: breaks 3D)
    gTSPassLog = getenv("TSMTL_PASS_LOG") != NULL;   // one stderr line per pass: wall-clock time, target size
    // TSMTL_PASS_END_SYNC=<bits> after every pass: 1 glFinish, 2 lock/unlock its IOSurface attachments, 4 also read them.
    const char *pes = getenv("TSMTL_PASS_END_SYNC");
    gTSPassEndSync = pes ? atoi(pes) : 0;
    gTSSyncDraw = getenv("TSMTL_SYNC_DRAW") != NULL;   // glFinish after every draw
    gTSNoShadow = getenv("TSMTL_NO_SHADOW") != NULL;
    gTSNoDedup = getenv("TSMTL_NO_DEDUP") != NULL;
}

static void TSProfileCollect(BOOL wait) {
    while (gProfTail != gProfHead) {
        GLint ready = 0;
        if (!wait) glGetQueryObjectiv(gProf[gProfTail].query, GL_QUERY_RESULT_AVAILABLE, &ready);
        if (!wait && !ready) break;
        GLuint64 ns = 0;
        glGetQueryObjectui64v(gProf[gProfTail].query, GL_QUERY_RESULT, &ns);
        NSString *name = gProf[gProfTail].name ?: @"?";
        NSMutableArray *t = gProfTotals[name];
        if (!t) gProfTotals[name] = t = [@[@0ull, @0ull] mutableCopy];
        t[0] = @([t[0] unsignedLongLongValue] + ns);
        t[1] = @([t[1] unsignedLongLongValue] + 1);
        gProfTail = (gProfTail + 1) % 8192;
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - gProfLastPrint < 5000000000ull || !gProfTotals.count) return;
    gProfLastPrint = now;
    NSArray *names = [gProfTotals keysSortedByValueUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [b[0] compare:a[0]];
    }];
    uint64_t all = 0;
    for (NSString *n in names) all += [gProfTotals[n][0] unsignedLongLongValue];
    fprintf(stderr, "[TSMtl %d] draw GPU time per pipeline, last 5 s (total %.1f ms):\n", getpid(), all / 1e6);
    for (NSUInteger i = 0; i < MIN(names.count, 12); i++) {
        NSArray *t = gProfTotals[names[i]];
        fprintf(stderr, "  %8.1f ms %6llu draws  %s\n", [t[0] unsignedLongLongValue] / 1e6, [t[1] unsignedLongLongValue], [names[i] UTF8String]);
    }
    [gProfTotals removeAllObjects];
}

static void TSProfileBegin(TSMtlRenderPipelineState *p) {
    if (!gProfTotals) gProfTotals = [NSMutableDictionary dictionary];
    TSProfileCollect((gProfHead + 1) % 8192 == gProfTail);
    if (!gProf[gProfHead].query) glGenQueries(1, &gProf[gProfHead].query);
    gProf[gProfHead].name = p.profileName;
    glBeginQuery(GL_TIME_ELAPSED, gProf[gProfHead].query);
}

static void TSProfileEnd(void) {
    glEndQuery(GL_TIME_ELAPSED);
    gProfHead = (gProfHead + 1) % 8192;
}

#pragma mark - Enum mapping

static GLenum TSGLPrimitive(MTLPrimitiveType t) {
    switch (t) {
    case MTLPrimitiveTypePoint:         return GL_POINTS;
    case MTLPrimitiveTypeLine:          return GL_LINES;
    case MTLPrimitiveTypeLineStrip:     return GL_LINE_STRIP;
    case MTLPrimitiveTypeTriangleStrip: return GL_TRIANGLE_STRIP;
    default:                            return GL_TRIANGLES;
    }
}

static GLenum TSGLBlendFactor(MTLBlendFactor f) {
    static const GLenum map[] = {
        GL_ZERO, GL_ONE, GL_SRC_COLOR, GL_ONE_MINUS_SRC_COLOR, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA,
        GL_DST_COLOR, GL_ONE_MINUS_DST_COLOR, GL_DST_ALPHA, GL_ONE_MINUS_DST_ALPHA, GL_SRC_ALPHA_SATURATE,
        GL_CONSTANT_COLOR, GL_ONE_MINUS_CONSTANT_COLOR, GL_CONSTANT_ALPHA, GL_ONE_MINUS_CONSTANT_ALPHA,
        GL_SRC1_COLOR, GL_ONE_MINUS_SRC1_COLOR, GL_SRC1_ALPHA, GL_ONE_MINUS_SRC1_ALPHA };
    return f < sizeof map / sizeof map[0] ? map[f] : GL_ONE;
}

static GLenum TSGLBlendOp(MTLBlendOperation op) {
    static const GLenum map[] = { GL_FUNC_ADD, GL_FUNC_SUBTRACT, GL_FUNC_REVERSE_SUBTRACT, GL_MIN, GL_MAX };
    return op < 5 ? map[op] : GL_FUNC_ADD;
}

static GLenum TSGLStencilOp(MTLStencilOperation op) {
    static const GLenum map[] = { GL_KEEP, GL_ZERO, GL_REPLACE, GL_INCR, GL_DECR, GL_INVERT, GL_INCR_WRAP, GL_DECR_WRAP };
    return op < 8 ? map[op] : GL_KEEP;
}

static GLenum TSGLCompareFunc(MTLCompareFunction f) {
    static const GLenum map[] = { GL_NEVER, GL_LESS, GL_EQUAL, GL_LEQUAL, GL_GREATER, GL_NOTEQUAL, GL_GEQUAL, GL_ALWAYS };
    return f < 8 ? map[f] : GL_ALWAYS;
}

typedef struct { GLint size; GLenum type; GLboolean normalized, integer; } TSGLVertexFormat;

static TSGLVertexFormat TSGLVertexFormatFor(MTLVertexFormat f) {
#define V(n, t, norm, i) return (TSGLVertexFormat){ n, t, norm, i }
    switch (f) {
    case MTLVertexFormatUChar:  V(1, GL_UNSIGNED_BYTE, 0, 1); case MTLVertexFormatUChar2: V(2, GL_UNSIGNED_BYTE, 0, 1);
    case MTLVertexFormatUChar3: V(3, GL_UNSIGNED_BYTE, 0, 1); case MTLVertexFormatUChar4: V(4, GL_UNSIGNED_BYTE, 0, 1);
    case MTLVertexFormatChar:   V(1, GL_BYTE, 0, 1); case MTLVertexFormatChar2: V(2, GL_BYTE, 0, 1);
    case MTLVertexFormatChar3:  V(3, GL_BYTE, 0, 1); case MTLVertexFormatChar4: V(4, GL_BYTE, 0, 1);
    case MTLVertexFormatUCharNormalized:  V(1, GL_UNSIGNED_BYTE, 1, 0); case MTLVertexFormatUChar2Normalized: V(2, GL_UNSIGNED_BYTE, 1, 0);
    case MTLVertexFormatUChar3Normalized: V(3, GL_UNSIGNED_BYTE, 1, 0); case MTLVertexFormatUChar4Normalized: V(4, GL_UNSIGNED_BYTE, 1, 0);
    case MTLVertexFormatCharNormalized:   V(1, GL_BYTE, 1, 0); case MTLVertexFormatChar2Normalized: V(2, GL_BYTE, 1, 0);
    case MTLVertexFormatChar3Normalized:  V(3, GL_BYTE, 1, 0); case MTLVertexFormatChar4Normalized: V(4, GL_BYTE, 1, 0);
    case MTLVertexFormatUShort:  V(1, GL_UNSIGNED_SHORT, 0, 1); case MTLVertexFormatUShort2: V(2, GL_UNSIGNED_SHORT, 0, 1);
    case MTLVertexFormatUShort3: V(3, GL_UNSIGNED_SHORT, 0, 1); case MTLVertexFormatUShort4: V(4, GL_UNSIGNED_SHORT, 0, 1);
    case MTLVertexFormatShort:   V(1, GL_SHORT, 0, 1); case MTLVertexFormatShort2: V(2, GL_SHORT, 0, 1);
    case MTLVertexFormatShort3:  V(3, GL_SHORT, 0, 1); case MTLVertexFormatShort4: V(4, GL_SHORT, 0, 1);
    case MTLVertexFormatUShortNormalized:  V(1, GL_UNSIGNED_SHORT, 1, 0); case MTLVertexFormatUShort2Normalized: V(2, GL_UNSIGNED_SHORT, 1, 0);
    case MTLVertexFormatUShort3Normalized: V(3, GL_UNSIGNED_SHORT, 1, 0); case MTLVertexFormatUShort4Normalized: V(4, GL_UNSIGNED_SHORT, 1, 0);
    case MTLVertexFormatShortNormalized:   V(1, GL_SHORT, 1, 0); case MTLVertexFormatShort2Normalized: V(2, GL_SHORT, 1, 0);
    case MTLVertexFormatShort3Normalized:  V(3, GL_SHORT, 1, 0); case MTLVertexFormatShort4Normalized: V(4, GL_SHORT, 1, 0);
    case MTLVertexFormatHalf:  V(1, GL_HALF_FLOAT, 0, 0); case MTLVertexFormatHalf2: V(2, GL_HALF_FLOAT, 0, 0);
    case MTLVertexFormatHalf3: V(3, GL_HALF_FLOAT, 0, 0); case MTLVertexFormatHalf4: V(4, GL_HALF_FLOAT, 0, 0);
    case MTLVertexFormatFloat:  V(1, GL_FLOAT, 0, 0); case MTLVertexFormatFloat2: V(2, GL_FLOAT, 0, 0);
    case MTLVertexFormatFloat3: V(3, GL_FLOAT, 0, 0); case MTLVertexFormatFloat4: V(4, GL_FLOAT, 0, 0);
    case MTLVertexFormatInt:  V(1, GL_INT, 0, 1); case MTLVertexFormatInt2: V(2, GL_INT, 0, 1);
    case MTLVertexFormatInt3: V(3, GL_INT, 0, 1); case MTLVertexFormatInt4: V(4, GL_INT, 0, 1);
    case MTLVertexFormatUInt:  V(1, GL_UNSIGNED_INT, 0, 1); case MTLVertexFormatUInt2: V(2, GL_UNSIGNED_INT, 0, 1);
    case MTLVertexFormatUInt3: V(3, GL_UNSIGNED_INT, 0, 1); case MTLVertexFormatUInt4: V(4, GL_UNSIGNED_INT, 0, 1);
    case MTLVertexFormatInt1010102Normalized:  V(4, GL_INT_2_10_10_10_REV, 1, 0);
    case MTLVertexFormatUInt1010102Normalized: V(4, GL_UNSIGNED_INT_2_10_10_10_REV, 1, 0);
    case MTLVertexFormatUChar4Normalized_BGRA: V(GL_BGRA, GL_UNSIGNED_BYTE, 1, 0);
    default: V(0, 0, 0, 0);
    }
#undef V
}

#pragma mark - Prebaked state (B2)

void TSGLBakePipeline(MTLRenderPipelineDescriptor *desc, TSGLPipelineState *out) {
    memset(out, 0, sizeof *out);
    MTLVertexDescriptor *vd = desc.vertexDescriptor;
    for (GLuint i = 0; i < 16 && vd; i++) {
        MTLVertexAttributeDescriptor *a = vd.attributes[i];
        TSGLVertexFormat vf = TSGLVertexFormatFor(a.format);
        if (!vf.size || a.bufferIndex > 30) continue;
        MTLVertexBufferLayoutDescriptor *l = vd.layouts[a.bufferIndex];
        out->attribs[i] = (TSGLAttrib){ vf.size, vf.type, vf.normalized, vf.integer, (uint8_t)a.bufferIndex, (uint8_t)l.stepFunction,
                                        (uint32_t)a.offset, (uint32_t)l.stride, (uint32_t)MAX(l.stepRate, 1) };
        out->attribMask |= 1 << i;
    }
    for (int i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *c = desc.colorAttachments[i];
        TSGLColorState *s = &out->color[i];
        MTLColorWriteMask m = c.writeMask;
        s->mask[0] = (m & MTLColorWriteMaskRed) != 0; s->mask[1] = (m & MTLColorWriteMaskGreen) != 0;
        s->mask[2] = (m & MTLColorWriteMaskBlue) != 0; s->mask[3] = (m & MTLColorWriteMaskAlpha) != 0;
        s->blend = c.blendingEnabled;
        if (!s->blend) continue;   // the remaining fields stay zero so equal states compare equal
        s->rgbOp = TSGLBlendOp(c.rgbBlendOperation); s->alphaOp = TSGLBlendOp(c.alphaBlendOperation);
        s->srcRGB = TSGLBlendFactor(c.sourceRGBBlendFactor); s->dstRGB = TSGLBlendFactor(c.destinationRGBBlendFactor);
        s->srcAlpha = TSGLBlendFactor(c.sourceAlphaBlendFactor); s->dstAlpha = TSGLBlendFactor(c.destinationAlphaBlendFactor);
    }
    out->multisample = desc.rasterSampleCount > 1;
    out->alphaToCoverage = desc.alphaToCoverageEnabled;
}

void TSGLBakeDepthStencil(MTLDepthStencilDescriptor *ds, TSGLDepthStencil *out) {
    memset(out, 0, sizeof *out);
    out->depthTest = ds.depthCompareFunction != MTLCompareFunctionAlways || ds.depthWriteEnabled;
    out->depthWrite = ds.depthWriteEnabled;
    out->depthFunc = TSGLCompareFunc(ds.depthCompareFunction);
    MTLStencilDescriptor *faces[2] = { ds.frontFaceStencil, ds.backFaceStencil };
    for (int f = 0; f < 2; f++) {
        MTLStencilDescriptor *sd = faces[f];
        out->face[f] = (TSGLStencilFace){ TSGLCompareFunc(sd.stencilCompareFunction), TSGLStencilOp(sd.stencilFailureOperation),
                                          TSGLStencilOp(sd.depthFailureOperation), TSGLStencilOp(sd.depthStencilPassOperation),
                                          sd.readMask, sd.writeMask };
    }
}

#pragma mark - Command recording (B1)

// Commands are POD records in 64 KB chunks recycled through a small pool. Objects are
// referenced by raw pointer and retained once per change when the command buffer keeps
// references. setBytes payloads go to a separate 256-aligned staging area that the replay
// uploads in one call.
typedef struct TSChunk { struct TSChunk *next; uint32_t used, cap; _Alignas(16) uint8_t data[]; } TSChunk;
enum { TSChunkSize = 64 << 10, TSChunkPoolMax = 64 };
static os_unfair_lock gChunkLock = OS_UNFAIR_LOCK_INIT;
static TSChunk *gChunkPool;
static int gChunkPoolCount;

static TSChunk *TSChunkNew(uint32_t need) {
    TSChunk *c = NULL;
    if (need <= TSChunkSize) {
        os_unfair_lock_lock(&gChunkLock);
        if ((c = gChunkPool)) { gChunkPool = c->next; gChunkPoolCount--; }
        os_unfair_lock_unlock(&gChunkLock);
    }
    if (!c) {
        uint32_t cap = MAX(need, (uint32_t)TSChunkSize);
        c = malloc(sizeof *c + cap);
        c->cap = cap;
    }
    c->next = NULL;
    c->used = 0;
    return c;
}

static void TSChunkRelease(TSChunk *c) {
    while (c) {
        TSChunk *next = c->next;
        os_unfair_lock_lock(&gChunkLock);
        BOOL pooled = c->cap == TSChunkSize && gChunkPoolCount < TSChunkPoolMax;
        if (pooled) { c->next = gChunkPool; gChunkPool = c; gChunkPoolCount++; }
        os_unfair_lock_unlock(&gChunkLock);
        if (!pooled) free(c);
        c = next;
    }
}

typedef enum : uint32_t {
    TSOpPipeline = 1, TSOpDepthStencil, TSOpViewport, TSOpScissor, TSOpCull, TSOpWinding, TSOpFill, TSOpDepthClip,
    TSOpDepthBias, TSOpStencilRef, TSOpBlendColor, TSOpBuffer, TSOpBytes, TSOpOffset, TSOpTexture, TSOpSampler,
    TSOpDraw, TSOpDrawIndexed, TSOpDrawIndirect, TSOpDrawIndexedIndirect, TSOpVisibility,
} TSOp;

typedef struct { uint32_t op, size; } TSCmd;
typedef struct { TSCmd h; const void *object; } TSCmdObject;                       // pipeline, depth/stencil
typedef struct { TSCmd h; uint32_t value; } TSCmdU32;                             // cull, winding, fill, depth clip
typedef struct { TSCmd h; MTLViewport v; } TSCmdViewport;
typedef struct { TSCmd h; MTLScissorRect r; } TSCmdScissor;
typedef struct { TSCmd h; float bias, slope; } TSCmdDepthBias;
typedef struct { TSCmd h; uint32_t front, back; } TSCmdStencilRef;
typedef struct { TSCmd h; float rgba[4]; } TSCmdBlendColor;
typedef struct { TSCmd h; uint8_t stage, index; const void *buffer; uint64_t offset, stride; } TSCmdBuffer;
typedef struct { TSCmd h; uint8_t stage, index; uint32_t length, staged; } TSCmdBytes;
typedef struct { TSCmd h; uint8_t stage, index; uint64_t offset; } TSCmdOffset;
typedef struct { TSCmd h; uint8_t stage; uint16_t index; uint32_t seed; const void *object; } TSCmdBinding;   // texture (seed: IOSurface at encode), sampler
typedef struct { TSCmd h; uint32_t type, start, count, instances, baseInstance; } TSCmdDraw;
typedef struct { TSCmd h; uint32_t mode; uint64_t offset; } TSCmdVisibility;
typedef struct {
    TSCmd h; uint32_t type, indexType, count, instances, baseInstance; int32_t baseVertex; const void *indexBuffer; uint64_t offset;
} TSCmdDrawIndexed;
typedef struct {
    TSCmd h; uint32_t type, indexType; const void *indirect, *indexBuffer; uint64_t indirectOffset, indexOffset;
} TSCmdDrawIndirect;

typedef struct {
    TSChunk *head, *tail;
    uint8_t *staging;
    uint32_t stagingSize, stagingCap;
    const void **retained;
    uint32_t retainedCount, retainedCap;
    BOOL retain;
} TSRecording;

static void *TSRecord(TSRecording *r, TSOp op, uint32_t size) {
    size = (size + 7) & ~7u;
    TSChunk *t = r->tail;
    if (!t || t->used + size > t->cap) {
        TSChunk *c = TSChunkNew(size);
        if (t) t->next = c; else r->head = c;
        r->tail = t = c;
    }
    TSCmd *h = (TSCmd *)(t->data + t->used);
    t->used += size;
    h->op = op;
    h->size = size;
    return h;
}

static void TSRecordRetain(TSRecording *r, const void *object) {
    if (!r->retain || !object) return;
    if (r->retainedCount == r->retainedCap) {
        r->retainedCap = MAX(r->retainedCap * 2, 64);
        r->retained = realloc(r->retained, r->retainedCap * sizeof *r->retained);
    }
    r->retained[r->retainedCount++] = CFRetain(object);
}

static uint32_t TSRecordStage(TSRecording *r, const void *bytes, uint32_t length) {
    uint32_t at = r->stagingSize, aligned = (MAX(length, 16) + 255) & ~255u;
    if (at + aligned > r->stagingCap) {
        r->stagingCap = MAX(r->stagingCap * 2, MAX(at + aligned, 16384u));
        r->staging = realloc(r->staging, r->stagingCap);
    }
    memcpy(r->staging + at, bytes, length);
    r->stagingSize = at + aligned;
    return at;
}

static void TSRecordingFree(TSRecording *r) {
    if (!r) return;
    TSChunkRelease(r->head);
    for (uint32_t i = 0; i < r->retainedCount; i++) CFRelease(r->retained[i]);
    free(r->retained);
    free(r->staging);
    free(r);
}

// Owns a recording from endEncoding until its replay; frees it even if the command buffer is dropped.
@interface TSRecordingBox : NSObject { @public TSRecording *rec; }
@end
@implementation TSRecordingBox
- (void)dealloc { TSRecordingFree(rec); }
@end

#pragma mark - Pass framebuffers (GPU queue)

// B6 (docs/OTTIMIZZAZIONE-AIR.md §7): creating, checking and deleting a framebuffer and a vertex array for every pass
// cost ~23 us of ~100 (bench/passfloor, bench/cpubench passes). Framebuffers are kept per device, keyed by their
// resolved attachments and checked only when created; GL recycles texture names, so a texture's entries go before
// it is deleted (TSMtlForgetFramebufferTexture). One vertex array per device: every replay forgets the GL shadow,
// so the attributes a pass does not use are disabled again. TSMTL_NO_FBO_CACHE=1 creates both per pass (A/B).
enum { TSFBOCacheSize = 32 };
typedef struct {
    TSGLAttachment att[9];   // colors 0-7, depth / stencil
    GLenum dsPoint;
    GLsizei drawCount;
} TSFBOKey;
typedef struct {
    TSFBOKey key;
    GLuint fbo;
    uint64_t used;
} TSFBOEntry;
typedef struct {
    TSFBOEntry e[TSFBOCacheSize];
    int count;
    uint64_t clock;
    GLuint vao;
} TSPassCache;

static BOOL TSFBOCacheOff(void) {
    static int off = -1;
    if (off < 0) off = getenv("TSMTL_NO_FBO_CACHE") != NULL;
    return off;
}

static TSPassCache *TSPassCacheOf(TSMtlDevice *device) {
    if (!device.passCache) device.passCache = calloc(1, sizeof(TSPassCache));
    return device.passCache;
}

// The bound draw framebuffer for key (created, attached and checked on a miss); 0 if incomplete, *status says why.
static GLuint TSPassFramebuffer(TSMtlDevice *device, const TSFBOKey *key, const GLenum *drawBuffers, GLenum *status) {
    TSPassCache *c = TSPassCacheOf(device);
    BOOL cache = !TSFBOCacheOff();
    for (int i = 0; cache && i < c->count; i++)
        if (!memcmp(&c->e[i].key, key, sizeof *key)) {
            c->e[i].used = ++c->clock;
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, c->e[i].fbo);
            *status = GL_FRAMEBUFFER_COMPLETE;
            TSMtlStat(TSStatFBOHits, 1);
            return c->e[i].fbo;
        }
    GLuint fbo;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
    for (int i = 0; i < 9; i++)
        if (key->att[i].target) TSGLAttach(i < 8 ? GL_COLOR_ATTACHMENT0 + (GLenum)i : key->dsPoint, &key->att[i]);
    glDrawBuffers(MAX(key->drawCount, 1), drawBuffers);
    *status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
    if (*status != GL_FRAMEBUFFER_COMPLETE || !cache) {
        if (*status == GL_FRAMEBUFFER_COMPLETE) return fbo;   // A/B: deleted at the end of the pass
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &fbo);
        return 0;
    }
    int slot = c->count;
    if (slot == TSFBOCacheSize) {   // evict the least recently used
        slot = 0;
        for (int i = 1; i < c->count; i++) if (c->e[i].used < c->e[slot].used) slot = i;
        glDeleteFramebuffers(1, &c->e[slot].fbo);
    } else c->count++;
    c->e[slot] = (TSFBOEntry){ *key, fbo, ++c->clock };
    return fbo;
}

void TSMtlForgetFramebufferTexture(TSMtlDevice *device, GLuint name) {
    TSPassCache *c = device.passCache;
    if (!name || !c) return;
    for (int i = 0; i < c->count;) {
        BOOL holds = NO;
        for (int k = 0; k < 9; k++) holds |= c->e[i].key.att[k].target && c->e[i].key.att[k].name == name;
        if (!holds) { i++; continue; }
        glDeleteFramebuffers(1, &c->e[i].fbo);
        c->e[i] = c->e[--c->count];
    }
}

#pragma mark - Pass executor (GPU queue)

typedef struct {
    __unsafe_unretained TSMtlBuffer *buffer;
    uint32_t staged, length;            // setBytes: payload offset in the staging area + 1 (0 = buffer binding)
    NSUInteger offset, stride;
    GLuint gl, glTex, glTex4, glTex2;   // resolved GL objects; 0 = not yet resolved since the slot changed
    NSUInteger glLength;
    uint32_t copyGen;                   // copy of unaligned constant data in the copy ring
    GLintptr copyAt;
    GLsizeiptr copySize;
} TSSlot;

typedef struct {
    uint8_t cull, offset, clamp, pad;
    GLenum cullFace, frontFace, polygonMode;
    float slope, bias;
} TSRaster;

typedef struct {
    uint8_t depthTest, depthWrite, stencil, pad;
    GLenum depthFunc;
    TSGLStencilFace face[2];
    uint32_t ref[2];
} TSDepthStencilGL;

// What the GL context currently holds, as far as this pass knows. Reset (all bytes 0xFF, i.e.
// "unknown") at every recording replay, so code outside the render path may change GL state freely.
typedef struct {
    GLuint program, arrayBuffer, elementBuffer, activeUnit;
    GLuint ubo[62];
    GLintptr uboOffset[62];
    GLsizeiptr uboSize[62];
    GLuint tex[32], sampler[32];
    GLenum texTarget[32];
    struct { GLuint buffer; GLintptr pointer; GLsizei stride; GLint size; GLenum type; uint8_t normalized, integer, enabled; GLuint divisor; } attr[16];
    MTLViewport viewport;
    uint8_t scissorEnabled;
    MTLScissorRect scissor;
    TSRaster raster;
    TSDepthStencilGL ds;
    TSGLColorState color[8];
    uint8_t multisample, alphaToCoverage;
    float blendColor[4];
    uint32_t restartType;
} TSGLShadow;

enum {
    TSDirtyPipeline = 1 << 0, TSDirtyResources = 1 << 1, TSDirtyVertex = 1 << 2, TSDirtyViewport = 1 << 3,
    TSDirtyScissor = 1 << 4, TSDirtyRaster = 1 << 5, TSDirtyDepthStencil = 1 << 6, TSDirtyBlendColor = 1 << 7,
    TSDirtyFixed = TSDirtyViewport | TSDirtyScissor | TSDirtyRaster | TSDirtyDepthStencil | TSDirtyBlendColor,
};

@interface TSGLRenderPass : NSObject {
@public
    TSMtlDevice *_device;
    MTLRenderPassDescriptor *_desc;
    GLuint _fbo, _vao;
    GLsizei _width, _height;
    BOOL _valid, _hasDepth, _hasStencil;
    // Metal state
    __unsafe_unretained TSMtlRenderPipelineState *_pipeline;
    __unsafe_unretained TSMtlDepthStencilState *_depthStencil;
    TSSlot _buffers[2][31];
    __unsafe_unretained TSMtlTexture *_textures[2][128];
    __unsafe_unretained TSMtlSamplerState *_samplers[2][16];
    __unsafe_unretained TSMtlTexture *_colorTex[8];   // color attachments (sampling one needs a texture barrier)
    BOOL _feedback;                     // the bound textures include a color attachment: barrier before each draw
    MTLViewport _viewport;
    MTLScissorRect _scissor;
    BOOL _scissorSet;
    MTLCullMode _cull;
    MTLWinding _winding;
    MTLTriangleFillMode _fill;
    float _depthBias, _slopeScale;
    MTLDepthClipMode _depthClip;
    uint32_t _stencilFront, _stencilBack;
    float _blendColor[4];
    uint32_t _dirty;
    // Cached from the current pipeline (valid after TSDirtyPipeline is handled)
    __unsafe_unretained TSGLProgram *_prog;
    uint32_t _rectMask;                 // rectangle-texture variant of the program in use (rectSlots bits)
    GLuint _program;
    const TSGLPipelineState *_gls;
    TSGLProgramUniforms *_uniforms;
    const TSGLBinding *_blocks, *_texs, *_infos;
    NSUInteger _blockCount, _texCount, _infoCount;
    GLint _baseInstanceLoc, _baseVertexLoc;
    BOOL _instanceAttribs;
    NSUInteger _vertexBaseInstance;
    long _vertexShift;                  // added to `first` / basevertex: vertex buffer offsets folded into the draw
    // Resolved GL names per binding slot, cleared when the slot changes
    GLuint _texName[2][128], _smpName[2][16];
    GLenum _texTarget[2][128];
    GLuint _texRect[2][128];
    uint32_t _texEncSeed[2][128];       // TSMTL_DRAW_TRACE: IOSurface seed when the binding was encoded            // GL_TEXTURE_RECTANGLE of an IOSurface texture (~0 = none, 0 = not resolved)
    __unsafe_unretained id _indexBuffer;
    GLuint _indexGL;
    // Replay
    const uint8_t *_staging;
    TSGLShadow _gl;
    // Visibility results: the open occlusion query and the finished ones of this pass.
    GLuint _query;
    uint32_t _queryMode;
    uint64_t _queryOffset;
    NSMutableData *_queries;            // TSVisibilityQuery entries
}
@end

typedef struct { GLuint query; uint32_t mode; uint64_t offset; } TSVisibilityQuery;

@implementation TSGLRenderPass

- (instancetype)initWithDevice:(TSMtlDevice *)device descriptor:(MTLRenderPassDescriptor *)desc {
    if ((self = [super init])) { _device = device; _desc = [desc copy]; }
    return self;
}

static NSString *TSTraceTexture(id<MTLTexture> t) {
    if (!t) return @"-";
    return [NSString stringWithFormat:@"fmt%lu type%lu x%lu %lux%lu%@", (unsigned long)t.pixelFormat, (unsigned long)t.textureType,
            (unsigned long)t.sampleCount, (unsigned long)t.width, (unsigned long)t.height, t.iosurface ? @" iosurface" : @""];
}

static void TSTracePass(MTLRenderPassDescriptor *d) {
    NSMutableString *m = [NSMutableString stringWithString:@"pass"];
    for (NSUInteger i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[i];
        if (!a.texture) continue;
        [m appendFormat:@" c%lu[%@ load%lu store%lu", (unsigned long)i, TSTraceTexture(a.texture), (unsigned long)a.loadAction, (unsigned long)a.storeAction];
        if (a.resolveTexture) [m appendFormat:@" resolve->%@", TSTraceTexture(a.resolveTexture)];
        [m appendString:@"]"];
    }
    if (d.depthAttachment.texture) [m appendFormat:@" depth[%@ load%lu store%lu]", TSTraceTexture(d.depthAttachment.texture),
                                    (unsigned long)d.depthAttachment.loadAction, (unsigned long)d.depthAttachment.storeAction];
    if (d.stencilAttachment.texture) [m appendFormat:@" stencil[%@]", TSTraceTexture(d.stencilAttachment.texture)];
    if (d.renderTargetWidth) [m appendFormat:@" rt %lux%lu", (unsigned long)d.renderTargetWidth, (unsigned long)d.renderTargetHeight];
    TSMtlTraceOnce(@"%@", m);
}

static const uint8_t *TSSlotBytes(TSGLRenderPass *p, TSSlot *s, NSUInteger *avail);

static NSString *TSDrawTraceTexture(id<MTLTexture> t) {
    if (!t) return @"-";
    return [NSString stringWithFormat:@"%p:%lux%lu%@%@", t, (unsigned long)t.width, (unsigned long)t.height,
            t.iosurface ? [NSString stringWithFormat:@":ios#%u", IOSurfaceGetID(t.iosurface)] : @"",
            t.parentTexture ? [NSString stringWithFormat:@":view(%p)", t.parentTexture] : @""];
}

- (void)drawTrace:(NSString *)what instances:(NSUInteger)instances baseInstance:(NSUInteger)baseInstance {
    NSMutableString *m = [NSMutableString stringWithFormat:@"[TSDraw]   %@ inst %lu+%lu shift %ld fn %@ rect 0x%x vp %.0f,%.0f %.0fx%.0f",
        what, (unsigned long)instances, (unsigned long)baseInstance, _vertexShift,
        _pipeline.descriptor.fragmentFunction.name ?: _pipeline.descriptor.vertexFunction.name, _rectMask,
        _viewport.originX, _viewport.originY, _viewport.width, _viewport.height];
    GLint sc[4];
    glGetIntegerv(GL_SCISSOR_BOX, sc);
    [m appendFormat:@" sc %@ %ld,%ld %ldx%ld gl %d %d,%d %dx%d", _scissorSet ? @"on" : @"off", (long)_scissor.x, (long)_scissor.y,
        (long)_scissor.width, (long)_scissor.height, glIsEnabled(GL_SCISSOR_TEST), sc[0], sc[1], sc[2], sc[3]];
    for (int i = 0; i < 8; i++)
        if (_textures[1][i]) {
            [m appendFormat:@" t%d=%@", i, TSDrawTraceTexture(_textures[1][i])];
            IOSurfaceRef ios = _textures[1][i].iosurface;
            if (ios) {
                uint32_t now = IOSurfaceGetSeed(ios), enc = _texEncSeed[1][i];
                [m appendFormat:@" seed enc %u exec %u%@", enc, now, enc && enc != now ? @" !!RACE" : @""];
                IOSurfaceLock(ios, kIOSurfaceLockReadOnly, NULL);
                size_t w = IOSurfaceGetWidth(ios), h = IOSurfaceGetHeight(ios), pitch = IOSurfaceGetBytesPerRow(ios), op = 0;
                const uint8_t *base = IOSurfaceGetBaseAddress(ios);
                if (IOSurfaceGetBytesPerElement(ios) == 4 && w * h <= 2048 * 2048)
                    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) if (((const uint32_t *)(base + y * pitch))[x] >> 24) op++;
                IOSurfaceUnlock(ios, kIOSurfaceLockReadOnly, NULL);
                [m appendFormat:@" cpu%zu%% inuse%d", op * 100 / MAX(w * h, 1), IOSurfaceIsInUse(ios)];
            }
            if ((gTSMtlDrawTraceHeavy & (ios ? TSHeavySurface : TSHeavyTexture)) && [_textures[1][i] isKindOfClass:[TSMtlTexture class]])
                [m appendString:ios ? [_textures[1][i] surfaceCoherencyReport] : [_textures[1][i] glContentReport]];
        }
    // GL state against what the encoder believes it set ("!!" = mismatch).
    GLint prog = 0, fbo = 0, vao = 0, bi = 0;
    GLfloat vp[4];
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fbo);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
    glGetFloatv(GL_VIEWPORT, vp);
    if ((GLuint)prog != _program) [m appendFormat:@" !!prog %d/%u", prog, _program];
    if ((GLuint)fbo != _fbo) [m appendFormat:@" !!fbo %d/%u", fbo, _fbo];
    if ((GLuint)vao != _vao) [m appendFormat:@" !!vao %d/%u", vao, _vao];
    if (vp[0] != _viewport.originX || vp[1] != _viewport.originY || vp[2] != _viewport.width || vp[3] != _viewport.height)
        [m appendFormat:@" !!vp %.0f,%.0f %.0fx%.0f", vp[0], vp[1], vp[2], vp[3]];
    if (glIsEnabled(GL_SCISSOR_TEST) != _scissorSet) [m appendString:@" !!scissor-enable"];
    if (_scissorSet && (sc[0] != (GLint)_scissor.x || sc[1] != (GLint)_scissor.y || sc[2] != (GLint)_scissor.width || sc[3] != (GLint)_scissor.height))
        [m appendString:@" !!scissor-box"];
    {
        GLint df = 0; GLboolean dm = 0, cm[4] = { 0 };
        glGetIntegerv(GL_DEPTH_FUNC, &df);
        glGetBooleanv(GL_DEPTH_WRITEMASK, &dm);
        glGetBooleani_v(GL_COLOR_WRITEMASK, 0, cm);
        GLint bs = 0, bd = 0, beq = 0;
        glGetIntegeri_v(GL_BLEND_SRC_RGB, 0, &bs); glGetIntegeri_v(GL_BLEND_DST_RGB, 0, &bd); glGetIntegeri_v(GL_BLEND_EQUATION_RGB, 0, &beq);
        [m appendFormat:@" depth %d f0x%x w%d stencil %d blend %d 0x%x/0x%x/0x%x mask %d%d%d%d", glIsEnabled(GL_DEPTH_TEST), df, dm,
            glIsEnabled(GL_STENCIL_TEST), glIsEnabledi(GL_BLEND, 0), bs, bd, beq, cm[0], cm[1], cm[2], cm[3]];
    }
    // What GL really has on the texture units the program samples (name, size, sampler filter/wrap).
    for (NSUInteger i = 0; i < MIN(_texCount, 32); i++) {
        const TSGLBinding *t = &_texs[i];
        if (t->kind >= 2) continue;
        GLint act, name = 0, smp = 0, w = -1, h = -1, minf = 0, ws = 0;
        GLenum target = t->rect ? GL_TEXTURE_RECTANGLE : GL_TEXTURE_2D;
        glGetIntegerv(GL_ACTIVE_TEXTURE, &act);
        glActiveTexture(GL_TEXTURE0 + (GLenum)t->unit);
        glGetIntegerv(t->rect ? GL_TEXTURE_BINDING_RECTANGLE : GL_TEXTURE_BINDING_2D, &name);
        glGetIntegerv(GL_SAMPLER_BINDING, &smp);
        glGetTexLevelParameteriv(target, 0, GL_TEXTURE_WIDTH, &w);
        glGetTexLevelParameteriv(target, 0, GL_TEXTURE_HEIGHT, &h);
        glActiveTexture((GLenum)act);
        if (smp) { glGetSamplerParameteriv((GLuint)smp, GL_TEXTURE_MIN_FILTER, &minf); glGetSamplerParameteriv((GLuint)smp, GL_TEXTURE_WRAP_S, &ws); }
        [m appendFormat:@" u%d=%s%d %dx%d s%d/0x%x/0x%x", t->unit, t->rect ? "R" : "", name, w, h, smp, minf, ws];
    }
    if (_baseInstanceLoc >= 0) {
        glGetUniformiv((GLuint)prog, _baseInstanceLoc, &bi);
        [m appendFormat:@" bi=%d%@", bi, bi != (GLint)baseInstance ? @"!!" : @""];
    }
    // Bound buffers: CPU bytes at the binding offset against the GL copy the draw reads.
    for (int st = 0; st < 2; st++)
        for (int i = 0; i < 31; i++) {
            TSSlot *sl = &_buffers[st][i];
            if (sl->staged) {
                [m appendFormat:@" %c%d=bytes(%u)[", "vf"[st], i, sl->length];
                NSUInteger avail = 0;
                const uint32_t *w = (const uint32_t *)TSSlotBytes(self, sl, &avail);
                for (NSUInteger q = 0; w && q < MIN(avail, 64) / 4; q++) [m appendFormat:@"%s%u", q ? "," : "", w[q]];
                [m appendString:@"]"];
                continue;
            }
            if (!sl->buffer || ![sl->buffer isKindOfClass:[TSMtlBuffer class]]) continue;
            NSUInteger len = sl->buffer.length, off = sl->offset, n = off < len ? MIN(len - off, 65536) : 0;
            [m appendFormat:@" %c%d=%p+%lu/%lu m%lu", "vf"[st], i, sl->buffer, (unsigned long)off, (unsigned long)len,
                (unsigned long)sl->buffer.storageMode];
            if (n) {   // FNV-1a of the CPU bytes the draw can see, to compare the same draw across frames
                uint32_t h = 2166136261u;
                const uint8_t *c = (const uint8_t *)sl->buffer.contents + off;
                for (NSUInteger q = 0; q < n; q++) h = (h ^ c[q]) * 16777619u;
                [m appendFormat:@" #%08x", h];
                if (getenv("TSMTL_DRAW_TRACE_DIR")) {   // each distinct content once, as buf-<hash>.bin
                    static NSMutableSet *saved;
                    if (!saved) saved = [NSMutableSet set];
                    if (![saved containsObject:@(h)]) {
                        [saved addObject:@(h)];
                        char path[1024];
                        snprintf(path, sizeof path, "%s/buf-%08x.bin", getenv("TSMTL_DRAW_TRACE_DIR"), h);
                        FILE *f = fopen(path, "wb");
                        if (f) { fwrite(c, 1, n, f); fclose(f); }
                    }
                }
            }
            if (!n || !sl->gl || !(gTSMtlDrawTraceHeavy & TSHeavyBuffers)) continue;
            static uint8_t glb[65536];
            TSMtlComputeJoin();
            glBindBuffer(GL_COPY_READ_BUFFER, sl->gl);
            glGetBufferSubData(GL_COPY_READ_BUFFER, (GLintptr)off, (GLsizeiptr)n, glb);
            glBindBuffer(GL_COPY_READ_BUFFER, 0);
            const uint8_t *cpu = (const uint8_t *)sl->buffer.contents + off;
            if (memcmp(cpu, glb, n)) {
                size_t k = 0;
                while (k < n && cpu[k] == glb[k]) k++;
                size_t diff = 0;
                for (size_t q = 0; q < n; q++) diff += cpu[q] != glb[q];
                [m appendFormat:@"!!BUF(byte %zu cpu %02x gl %02x, %zu bytes differ)", k, cpu[k], glb[k], diff];
            }
        }
    const TSGLPipelineState *ps = _gls;
    for (uint32_t bits = ps->attribMask; bits; bits &= bits - 1) {
        GLuint i = (GLuint)__builtin_ctz(bits);
        const TSGLAttrib *a = &ps->attribs[i];
        if (a->step != MTLVertexStepFunctionPerInstance || a->type != GL_FLOAT) continue;
        TSSlot *s = &_buffers[0][a->buffer];
        NSUInteger avail, stride = s->stride ? s->stride : a->stride;
        const uint8_t *p = TSSlotBytes(self, s, &avail);
        NSUInteger at = (baseInstance / MAX(a->stepRate, 1)) * stride + a->offset;
        if (!p || at + a->size * 4 > avail) continue;
        float v[4] = { 0 };
        memcpy(v, p + at, a->size * 4);
        [m appendFormat:@" a%u[b%u+%lu]=", i, a->buffer, (unsigned long)s->offset];
        for (int k = 0; k < a->size; k++) [m appendFormat:@"%s%g", k ? "," : "", v[k]];
    }
    fprintf(stderr, "%s\n", m.UTF8String);
}

// After a traced draw: share of opaque pixels in color attachment 0 (private targets only, IOSurfaces are big).
- (void)drawTracePost {
    id<MTLTexture> t = _desc.colorAttachments[0].texture;
    if (!t || t.iosurface || (t.pixelFormat != MTLPixelFormatBGRA8Unorm && t.pixelFormat != MTLPixelFormatRGBA8Unorm)) return;
    TSMtlComputeJoin();
    GLint prevRead;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, _fbo);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    size_t n = (size_t)_width * _height, opaque = 0;
    uint32_t *px = malloc(n * 4);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    glReadPixels(0, 0, _width, _height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, px);
    for (size_t i = 0; i < n; i++) if (px[i] >> 24) opaque++;
    // Pixels this draw changed (against the previous traced draw on the same target), in texture rows.
    static uint32_t *prev;
    static size_t prevN;
    static GLuint prevFBO;
    NSString *changed = @"";
    if (prev && prevN == n && prevFBO == _fbo) {
        long x0 = LONG_MAX, y0 = LONG_MAX, x1 = -1, y1 = -1;
        for (size_t i = 0; i < n; i++)
            if (px[i] != prev[i]) {
                long x = (long)(i % _width), y = (long)(i / _width);
                x0 = MIN(x0, x); x1 = MAX(x1, x); y0 = MIN(y0, y); y1 = MAX(y1, y);
            }
        changed = x1 < 0 ? @" changed none" : [NSString stringWithFormat:@" changed x %ld..%ld y %ld..%ld", x0, x1, y0, y1];
    }
    free(prev);
    prev = px; prevN = n; prevFBO = _fbo;
    glBindFramebuffer(GL_READ_FRAMEBUFFER, prevRead);
    fprintf(stderr, "[TSDraw]     -> target %zu%% opaque%s\n", opaque * 100 / MAX(n, 1), changed.UTF8String);
}

- (void)begin {
    if (gTSMtlTraceOn) TSTracePass(_desc);
    if (gTSMtlDrawTrace) {
        NSMutableString *m = [NSMutableString stringWithString:@"[TSDraw] pass"];
        for (NSUInteger i = 0; i < 8; i++) {
            MTLRenderPassColorAttachmentDescriptor *a = _desc.colorAttachments[i];
            if (a.texture) [m appendFormat:@" c%lu=%@ load%lu store%lu", (unsigned long)i, TSDrawTraceTexture(a.texture),
                            (unsigned long)a.loadAction, (unsigned long)a.storeAction];
        }
        if (_desc.depthAttachment.texture) [m appendFormat:@" depth=%@ load%lu clear%g", TSDrawTraceTexture(_desc.depthAttachment.texture),
                                            (unsigned long)_desc.depthAttachment.loadAction, _desc.depthAttachment.clearDepth];
        fprintf(stderr, "%s\n", m.UTF8String);
    }
    memset(_buffers, 0, sizeof _buffers);
    memset(_textures, 0, sizeof _textures);
    memset(_samplers, 0, sizeof _samplers);
    memset(_texName, 0, sizeof _texName);
    memset(_texRect, 0, sizeof _texRect);
    memset(_smpName, 0, sizeof _smpName);
    _pipeline = nil;
    _depthStencil = nil;
    _scissorSet = NO;
    _cull = MTLCullModeNone;
    _winding = MTLWindingClockwise;
    _fill = MTLTriangleFillModeFill;
    _depthBias = _slopeScale = 0;
    _depthClip = MTLDepthClipModeClip;
    _stencilFront = _stencilBack = 0;
    memset(_blendColor, 0, sizeof _blendColor);
    _dirty = TSDirtyFixed;
    _program = 0;
    _width = (GLsizei)_desc.renderTargetWidth;
    _height = (GLsizei)_desc.renderTargetHeight;
    TSMtlStat(TSStatPasses, 1);
    if (gTSPassLog) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        id<MTLTexture> c0 = _desc.colorAttachments[0].texture;
        fprintf(stderr, "[TSPass] %ld.%03ld %lux%lu%s load%lu\n", (long)ts.tv_sec, ts.tv_nsec / 1000000, (unsigned long)c0.width,
                (unsigned long)c0.height, c0.iosurface ? ":ios" : "", (unsigned long)_desc.colorAttachments[0].loadAction);
    }

    TSFBOKey key;
    memset(&key, 0, sizeof key);   // compared with memcmp
    GLenum drawBuffers[8];
    BOOL any = NO;
    for (GLsizei i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = _desc.colorAttachments[i];
        drawBuffers[i] = GL_NONE;
        if (![a.texture isKindOfClass:[TSMtlTexture class]]) continue;
        TSMtlTexture *t = (TSMtlTexture *)a.texture;
        if (![t glAttachment:&key.att[i] level:a.level slice:a.slice depthPlane:a.depthPlane]) continue;
        _colorTex[i] = t;
        drawBuffers[i] = GL_COLOR_ATTACHMENT0 + i;
        key.drawCount = i + 1;
        any = YES;
        if (!_width) { _width = (GLsizei)MAX(t.width >> a.level, 1); _height = (GLsizei)MAX(t.height >> a.level, 1); }
    }
    TSMtlTexture *depth = (TSMtlTexture *)_desc.depthAttachment.texture, *stencil = (TSMtlTexture *)_desc.stencilAttachment.texture;
    if (depth || stencil) {
        TSMtlTexture *t = depth ? depth : stencil;
        MTLRenderPassAttachmentDescriptor *a = depth ? (id)_desc.depthAttachment : (id)_desc.stencilAttachment;
        BOOL packed = t.glFormat.stencil;
        GLenum attachment = depth ? (packed ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT) : GL_STENCIL_ATTACHMENT;
        if ([t glAttachment:&key.att[8] level:a.level slice:a.slice depthPlane:a.depthPlane]) {
            key.dsPoint = attachment;
            _hasDepth = depth != nil;
            _hasStencil = packed;
            any = YES;
            if (!_width) { _width = (GLsizei)MAX(t.width >> a.level, 1); _height = (GLsizei)MAX(t.height >> a.level, 1); }
        }
        if (stencil && stencil != depth && depth)
            TSMtlWarn(@"separate depth and stencil textures are not supported, stencil ignored");
    }
    GLenum status = 0;
    _fbo = any ? TSPassFramebuffer(_device, &key, drawBuffers, &status) : 0;
    _valid = _fbo != 0;
    if (!_valid) {
        TSMtlError(@"render pass skipped: framebuffer status 0x%x (attachments %d)", status, any);
        return;
    }

    if (TSFBOCacheOff()) glGenVertexArrays(1, &_vao);
    else {
        TSPassCache *c = TSPassCacheOf(_device);
        if (!c->vao) glGenVertexArrays(1, &c->vao);
        _vao = c->vao;
    }
    glBindVertexArray(_vao);
    glEnable(GL_FRAMEBUFFER_SRGB);
    glEnable(GL_PROGRAM_POINT_SIZE);
    glEnable(GL_PRIMITIVE_RESTART);   // Metal always restarts strips at the all-ones index; only affects glDrawElements*
    glPointParameteri(GL_POINT_SPRITE_COORD_ORIGIN, GL_LOWER_LEFT);   // = Metal's top-left after the y flip
    glDisable(GL_SCISSOR_TEST);
    _viewport = (MTLViewport){ 0, 0, _width, _height, 0, 1 };

    // Load actions.
    for (GLint i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = _desc.colorAttachments[i];
        if (drawBuffers[i] == GL_NONE || a.loadAction != MTLLoadActionClear) continue;
        MTLClearColor c = a.clearColor;
        glColorMaski(i, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        TSGLFormat f = ((TSMtlTexture *)a.texture).glFormat;
        if (f.integer && f.isSigned) { GLint v[4] = { c.red, c.green, c.blue, c.alpha }; glClearBufferiv(GL_COLOR, i, v); }
        else if (f.integer) { GLuint v[4] = { c.red, c.green, c.blue, c.alpha }; glClearBufferuiv(GL_COLOR, i, v); }
        else { GLfloat v[4] = { c.red, c.green, c.blue, c.alpha }; glClearBufferfv(GL_COLOR, i, v); }
    }
    BOOL clearDepth = _hasDepth && _desc.depthAttachment.loadAction == MTLLoadActionClear;
    BOOL clearStencil = _hasStencil && _desc.stencilAttachment.texture && _desc.stencilAttachment.loadAction == MTLLoadActionClear;
    GLfloat d = _desc.depthAttachment.clearDepth;
    GLint s = _desc.stencilAttachment.clearStencil;
    if (clearDepth) glDepthMask(GL_TRUE);
    if (clearStencil) glStencilMask(0xFF);
    if (clearDepth && clearStencil) glClearBufferfi(GL_DEPTH_STENCIL, 0, d, s);
    else if (clearDepth) glClearBufferfv(GL_DEPTH, 0, &d);
    else if (clearStencil) glClearBufferiv(GL_STENCIL, 0, &s);
}

// Heavy draw trace with TSMTL_DRAW_TRACE_DIR=<dir>: color attachment 0 of every pass (e.g. Chrome's root
// IOSurface, offscreen layers), saved as <dir>/pass-<n>-<w>x<h>.bmp after the pass, to see where a picture goes wrong.
- (void)drawTraceSaveSurface {
    static int seq;
    if (!getenv("TSMTL_DRAW_TRACE_DIR")) return;
    int pass = seq++;
    for (int k = 0; k < 8; k++) if (_colorTex[k]) [self drawTraceSaveAttachment:k pass:pass];
}

// Attachment 0 as pass-<n>-<w>x<h>[-ios].bmp, the others as pass-<n>-<w>x<h>-c<k>.bmp.
- (void)drawTraceSaveAttachment:(int)k pass:(int)seq {
    id<MTLTexture> t = _desc.colorAttachments[k].texture;
    IOSurfaceRef ios = t.iosurface;
    char name[64];
    if (k) snprintf(name, sizeof name, "pass-%04d-%dx%d-c%d.bmp", seq, _width, _height, k);
    else snprintf(name, sizeof name, "pass-%04d-%dx%d%s.bmp", seq, _width, _height, ios ? "-ios" : "");
    TSMtlComputeJoin();
    glFinish();
    if (ios) {
        if (IOSurfaceGetBytesPerElement(ios) != 4) return;
        IOSurfaceLock(ios, kIOSurfaceLockReadOnly, NULL);
        TSMtlDrawTraceSaveBMP(name, (int32_t)IOSurfaceGetWidth(ios), (int32_t)IOSurfaceGetHeight(ios),
                              IOSurfaceGetBaseAddress(ios), IOSurfaceGetBytesPerRow(ios));
        IOSurfaceUnlock(ios, kIOSurfaceLockReadOnly, NULL);
        return;
    }
    if (t.sampleCount > 1 || TSPixelFormatGetInfo(t.pixelFormat).blockWidth != 1 || !t.pixelFormat) return;
    BOOL bytes = t.pixelFormat == MTLPixelFormatBGRA8Unorm || t.pixelFormat == MTLPixelFormatRGBA8Unorm;
    uint32_t *px = malloc((size_t)_width * _height * 4);
    float *fl = bytes ? NULL : malloc((size_t)_width * _height * 16);   // other color formats: as floats, clamped
    if (!px || (!bytes && !fl)) { free(px); free(fl); return; }
    GLint prevRead;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, _fbo);
    glReadBuffer(GL_COLOR_ATTACHMENT0 + k);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    if (bytes) glReadPixels(0, 0, _width, _height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, px);
    else {
        glReadPixels(0, 0, _width, _height, GL_RGBA, GL_FLOAT, fl);
        for (size_t i = 0, n = (size_t)_width * _height; i < n; i++) {
            uint32_t c[4];
            for (int k = 0; k < 4; k++) c[k] = (uint32_t)lrintf(fminf(fmaxf(fl[4 * i + k], 0.f), 1.f) * 255.f);
            px[i] = c[2] | c[1] << 8 | c[0] << 16 | c[3] << 24;
        }
        free(fl);
    }
    glBindFramebuffer(GL_READ_FRAMEBUFFER, prevRead);
    TSMtlDrawTraceSaveBMP(name, _width, _height, px, (size_t)_width * 4);
    free(px);
}

- (void)passEndSync {
    TSMtlComputeJoin();
    if (gTSPassEndSync & 1) glFinish();
    if (!(gTSPassEndSync & 6)) return;
    for (int i = 0; i < 8; i++) {
        IOSurfaceRef ios = _desc.colorAttachments[i].texture.iosurface;
        if (!ios) continue;
        IOSurfaceLock(ios, kIOSurfaceLockReadOnly, NULL);
        if (gTSPassEndSync & 4) {
            volatile uint32_t sum = 0;
            const uint8_t *base = IOSurfaceGetBaseAddress(ios);
            for (size_t k = 0, n = IOSurfaceGetAllocSize(ios); k < n; k += 4096) sum += base[k];
        }
        IOSurfaceUnlock(ios, kIOSurfaceLockReadOnly, NULL);
    }
}

- (void)end {
    if (_valid) [self resolveQueriesLater];
    if (_valid) {
        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_PRIMITIVE_RESTART);
        glActiveTexture(GL_TEXTURE0);
        for (GLint i = 0; i < 8; i++) {
            MTLRenderPassColorAttachmentDescriptor *a = _desc.colorAttachments[i];
            TSMtlTexture *t = (TSMtlTexture *)a.texture;
            if (!t) continue;
            [t didRenderGL];
            BOOL resolve = a.storeAction == MTLStoreActionMultisampleResolve || a.storeAction == MTLStoreActionStoreAndMultisampleResolve;
            TSMtlTexture *r = (TSMtlTexture *)a.resolveTexture;
            if (!resolve || !r) continue;
            GLuint fbo;
            glGenFramebuffers(1, &fbo);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
            if ([r attachToFramebuffer:GL_COLOR_ATTACHMENT0 level:a.resolveLevel slice:a.resolveSlice depthPlane:a.resolveDepthPlane]) {
                glDrawBuffer(GL_COLOR_ATTACHMENT0);
                glBindFramebuffer(GL_READ_FRAMEBUFFER, _fbo);
                glReadBuffer(GL_COLOR_ATTACHMENT0 + i);
                glBlitFramebuffer(0, 0, _width, _height, 0, 0, _width, _height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
                [r didRenderGL];
            }
            glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
            glDeleteFramebuffers(1, &fbo);
        }
        if (_desc.depthAttachment.texture) [(TSMtlTexture *)_desc.depthAttachment.texture didRenderGL];
        if (_desc.stencilAttachment.texture) [(TSMtlTexture *)_desc.stencilAttachment.texture didRenderGL];
        if (gTSMtlDrawTrace && (gTSMtlDrawTraceHeavy & TSHeavySave)) [self drawTraceSaveSurface];
        if (gTSPassEndSync) [self passEndSync];
    }
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    glBindVertexArray(0);
    if (TSFBOCacheOff()) {   // A/B: per pass, as before B6
        if (_vao) glDeleteVertexArrays(1, &_vao);
        if (_fbo) glDeleteFramebuffers(1, &_fbo);
    }
    _vao = _fbo = 0;
}

#pragma mark Replay

// Replays one recording (a render encoder, or one child of a parallel encoder).
- (void)run:(TSRecording *)rec {
    if (!_valid) return;
    memset(&_gl, 0xFF, sizeof _gl);
    _dirty |= TSDirtyPipeline | TSDirtyResources | TSDirtyVertex | TSDirtyFixed;
    _indexBuffer = nil;
    _staging = rec->staging;
    if (rec->stagingSize) {
        if (!gStagingBuffer) glGenBuffers(1, &gStagingBuffer);
        glBindBuffer(GL_COPY_WRITE_BUFFER, gStagingBuffer);
        glBufferData(GL_COPY_WRITE_BUFFER, rec->stagingSize, rec->staging, GL_STREAM_DRAW);
        TSMtlStat(TSStatBufferUploadBytes, rec->stagingSize);
    }
    for (TSChunk *c = rec->head; c; c = c->next) {
        for (uint32_t at = 0; at < c->used;) {
            const TSCmd *h = (const TSCmd *)(c->data + at);
            at += h->size;
            switch ((TSOp)h->op) {
            case TSOpPipeline: {
                TSMtlRenderPipelineState *p = (__bridge TSMtlRenderPipelineState *)((const TSCmdObject *)h)->object;
                if (p != _pipeline) { _pipeline = p; _dirty |= TSDirtyPipeline; }
                break;
            }
            case TSOpDepthStencil: {
                id o = (__bridge id)((const TSCmdObject *)h)->object;
                _depthStencil = [o isKindOfClass:[TSMtlDepthStencilState class]] ? o : nil;
                _dirty |= TSDirtyDepthStencil;
                break;
            }
            case TSOpViewport: _viewport = ((const TSCmdViewport *)h)->v; _dirty |= TSDirtyViewport; break;
            case TSOpScissor: _scissor = ((const TSCmdScissor *)h)->r; _scissorSet = YES; _dirty |= TSDirtyScissor; break;
            case TSOpCull: _cull = ((const TSCmdU32 *)h)->value; _dirty |= TSDirtyRaster; break;
            case TSOpWinding: _winding = ((const TSCmdU32 *)h)->value; _dirty |= TSDirtyRaster; break;
            case TSOpFill: _fill = ((const TSCmdU32 *)h)->value; _dirty |= TSDirtyRaster; break;
            case TSOpDepthClip: _depthClip = ((const TSCmdU32 *)h)->value; _dirty |= TSDirtyRaster; break;
            case TSOpDepthBias: _depthBias = ((const TSCmdDepthBias *)h)->bias; _slopeScale = ((const TSCmdDepthBias *)h)->slope; _dirty |= TSDirtyRaster; break;
            case TSOpStencilRef:
                _stencilFront = ((const TSCmdStencilRef *)h)->front; _stencilBack = ((const TSCmdStencilRef *)h)->back;
                _dirty |= TSDirtyDepthStencil;
                break;
            case TSOpBlendColor: memcpy(_blendColor, ((const TSCmdBlendColor *)h)->rgba, sizeof _blendColor); _dirty |= TSDirtyBlendColor; break;
            case TSOpBuffer: {
                const TSCmdBuffer *c = (const TSCmdBuffer *)h;
                TSSlot *s = &_buffers[c->stage][c->index];
                memset(s, 0, sizeof *s);
                s->buffer = (__bridge TSMtlBuffer *)c->buffer;
                s->offset = c->offset;
                s->stride = c->stride;
                _dirty |= c->stage ? TSDirtyResources : TSDirtyResources | TSDirtyVertex;
                break;
            }
            case TSOpBytes: {
                const TSCmdBytes *c = (const TSCmdBytes *)h;
                TSSlot *s = &_buffers[c->stage][c->index];
                memset(s, 0, sizeof *s);
                s->staged = c->staged + 1;
                s->length = c->length;
                _dirty |= c->stage ? TSDirtyResources : TSDirtyResources | TSDirtyVertex;
                break;
            }
            case TSOpOffset: {
                const TSCmdOffset *c = (const TSCmdOffset *)h;
                TSSlot *s = &_buffers[c->stage][c->index];
                s->offset = c->offset;
                s->copyGen = 0;
                _dirty |= c->stage ? TSDirtyResources : TSDirtyResources | TSDirtyVertex;
                break;
            }
            case TSOpTexture: {
                const TSCmdBinding *c = (const TSCmdBinding *)h;
                _textures[c->stage][c->index] = (__bridge TSMtlTexture *)c->object;
                _texEncSeed[c->stage][c->index] = c->seed;
                _texName[c->stage][c->index] = 0;
                _texRect[c->stage][c->index] = 0;
                _dirty |= TSDirtyResources;
                break;
            }
            case TSOpSampler: {
                const TSCmdBinding *c = (const TSCmdBinding *)h;
                _samplers[c->stage][c->index] = (__bridge TSMtlSamplerState *)c->object;
                _smpName[c->stage][c->index] = 0;
                _dirty |= TSDirtyResources;
                break;
            }
            case TSOpDraw: {
                const TSCmdDraw *c = (const TSCmdDraw *)h;
                [self drawPrimitives:c->type start:c->start count:c->count instances:c->instances baseInstance:c->baseInstance];
                break;
            }
            case TSOpDrawIndexed: {
                const TSCmdDrawIndexed *c = (const TSCmdDrawIndexed *)h;
                [self drawIndexed:c->type count:c->count indexType:c->indexType buffer:(__bridge id)c->indexBuffer offset:c->offset
                        instances:c->instances baseVertex:c->baseVertex baseInstance:c->baseInstance];
                break;
            }
            case TSOpDrawIndirect: {
                // Buffers are CPU-truth and the GPU never writes them, so the arguments can be read now.
                const TSCmdDrawIndirect *c = (const TSCmdDrawIndirect *)h;
                id<MTLBuffer> buffer = (__bridge id)c->indirect;
                MTLDrawPrimitivesIndirectArguments a;
                if (c->indirectOffset + sizeof a > buffer.length) break;
                memcpy(&a, (uint8_t *)buffer.contents + c->indirectOffset, sizeof a);
                [self drawPrimitives:c->type start:a.vertexStart count:a.vertexCount instances:a.instanceCount baseInstance:a.baseInstance];
                break;
            }
            case TSOpVisibility: {
                const TSCmdVisibility *c = (const TSCmdVisibility *)h;
                [self endQuery];
                if (c->mode != MTLVisibilityResultModeDisabled) [self beginQuery:c->mode offset:c->offset];
                break;
            }
            case TSOpDrawIndexedIndirect: {
                const TSCmdDrawIndirect *c = (const TSCmdDrawIndirect *)h;
                id<MTLBuffer> buffer = (__bridge id)c->indirect;
                MTLDrawIndexedPrimitivesIndirectArguments a;
                if (c->indirectOffset + sizeof a > buffer.length) break;
                memcpy(&a, (uint8_t *)buffer.contents + c->indirectOffset, sizeof a);
                NSUInteger indexSize = c->indexType == MTLIndexTypeUInt16 ? 2 : 4;
                [self drawIndexed:c->type count:a.indexCount indexType:c->indexType buffer:(__bridge id)c->indexBuffer
                           offset:c->indexOffset + a.indexStart * indexSize instances:a.instanceCount baseVertex:a.baseVertex
                     baseInstance:a.baseInstance];
                break;
            }
            }
        }
    }
    _staging = NULL;
}

#pragma mark Visibility results

// Metal counts samples per offset of the pass's visibility buffer while a mode is set; GL does it
// with one occlusion query per stretch of draws. Results are summed (counting) or OR-ed (boolean)
// per offset and written into the buffer once the command buffer is flushed, before completion.
- (void)beginQuery:(uint32_t)mode offset:(uint64_t)offset {
    if (![_desc.visibilityResultBuffer isKindOfClass:[TSMtlBuffer class]]) return;
    glGenQueries(1, &_query);
    glBeginQuery(mode == MTLVisibilityResultModeCounting ? GL_SAMPLES_PASSED : GL_ANY_SAMPLES_PASSED, _query);
    _queryMode = mode;
    _queryOffset = offset;
}

- (void)endQuery {
    if (!_query) return;
    glEndQuery(_queryMode == MTLVisibilityResultModeCounting ? GL_SAMPLES_PASSED : GL_ANY_SAMPLES_PASSED);
    if (!_queries) _queries = [NSMutableData data];
    TSVisibilityQuery q = { _query, _queryMode, _queryOffset };
    [_queries appendBytes:&q length:sizeof q];
    _query = 0;
}

- (void)resolveQueriesLater {
    [self endQuery];
    if (!_queries.length) return;
    NSData *queries = _queries;
    _queries = nil;
    TSMtlBuffer *buffer = (TSMtlBuffer *)_desc.visibilityResultBuffer;
    [_device addPostFlushWork:^{
        const TSVisibilityQuery *q = queries.bytes;
        NSUInteger n = queries.length / sizeof *q;
        NSMutableDictionary<NSNumber *, NSNumber *> *sums = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < n; i++) {
            GLuint64 v = 0;
            glGetQueryObjectui64v(q[i].query, GL_QUERY_RESULT, &v);
            glDeleteQueries(1, &q[i].query);
            uint64_t sum = sums[@(q[i].offset)].unsignedLongLongValue;
            sums[@(q[i].offset)] = @(q[i].mode == MTLVisibilityResultModeCounting ? sum + v : (sum || v ? 1 : 0));
        }
        for (NSNumber *offset in sums) {
            NSUInteger at = offset.unsignedIntegerValue;
            if (at + 8 > buffer.length) continue;
            uint64_t v = sums[offset].unsignedLongLongValue;
            memcpy((uint8_t *)buffer.contents + at, &v, 8);
            [buffer didWriteRange:NSMakeRange(at, 8)];
        }
    }];
}

#pragma mark State application

// GL buffer, byte offset and available length of a slot's data.
static BOOL TSSlotResolve(TSGLRenderPass *p, TSSlot *s, GLuint *buffer, GLintptr *offset, GLsizeiptr *avail) {
    if (s->staged) {
        *buffer = gStagingBuffer;
        *offset = s->staged - 1;
        *avail = s->length;
        return YES;
    }
    if (!s->buffer) return NO;
    if (!s->gl) {
        if (![s->buffer isKindOfClass:[TSMtlBuffer class]]) return NO;
        s->gl = [s->buffer glBuffer];
        s->glLength = s->buffer.length;
    }
    *buffer = s->gl;
    *offset = (GLintptr)s->offset;
    *avail = s->offset < s->glLength ? (GLsizeiptr)(s->glLength - s->offset) : 0;
    return YES;
}

static const uint8_t *TSSlotBytes(TSGLRenderPass *p, TSSlot *s, NSUInteger *avail) {
    if (s->staged) { *avail = s->length; return p->_staging + s->staged - 1; }
    if (s->buffer && s->offset < s->buffer.length) { *avail = s->buffer.length - s->offset; return (const uint8_t *)s->buffer.contents + s->offset; }
    *avail = 0;
    return NULL;
}

static inline void TSActiveUnit(TSGLShadow *g, GLuint unit) {
    if (g->activeUnit != unit) { glActiveTexture(GL_TEXTURE0 + unit); g->activeUnit = unit; }
}

static inline void TSArrayBuffer(TSGLShadow *g, GLuint buffer) {
    if (g->arrayBuffer != buffer) { glBindBuffer(GL_ARRAY_BUFFER, buffer); g->arrayBuffer = buffer; }
}

- (void)applyResources {
    TSGLShadow *g = &_gl;
    // Uniform blocks: setBytes payloads and 256-aligned buffer offsets are bound in place
    // (the GL driver accepts a range shorter than the declared block); others are copied.
    GLsizeiptr copies = 0;
    for (NSUInteger i = 0; i < _blockCount; i++) copies += (MAX(_blocks[i].size, 16) + 255) & ~255;
    uint32_t gen = gCopyRing.gen;
    TSRingReserve(&gCopyRing, copies);
    if (gCopyRing.gen != gen)   // orphaned: bindings into the old copy ring storage are gone
        for (int b = 0; b < 62; b++) if (g->ubo[b] == gCopyRing.buffer) g->ubo[b] = ~0u;
    for (NSUInteger i = 0; i < _blockCount; i++) {
        const TSGLBinding *b = &_blocks[i];
        TSSlot *s = &_buffers[b->stage][b->index];
        GLuint buffer = 0;
        GLintptr offset = 0;
        GLsizeiptr avail = 0, size;
        if (!TSSlotResolve(self, s, &buffer, &offset, &avail)) { buffer = 0; avail = 0; }
        if (buffer && !s->staged && (offset & 255)) {
            GLsizeiptr n = MIN(avail, (GLsizeiptr)b->size);
            if (s->copyGen != gCopyRing.gen || s->copySize < n) {
                s->copyAt = TSRingWrite(&gCopyRing, (const uint8_t *)s->buffer.contents + s->offset, n);
                s->copyGen = gCopyRing.gen;
                s->copySize = n;
            }
            buffer = gCopyRing.buffer;
            offset = s->copyAt;
            avail = n;
        }
        if (!buffer) {   // nothing bound: point at zeros
            static const uint8_t zeros[256];
            if (s->copyGen != gCopyRing.gen) { s->copyAt = TSRingWrite(&gCopyRing, zeros, sizeof zeros); s->copyGen = gCopyRing.gen; }
            buffer = gCopyRing.buffer;
            offset = s->copyAt;
            avail = 16;
        }
        size = MAX(MIN(avail, (GLsizeiptr)b->size), 16);
        GLuint point = b->stage * 31 + b->index;
        if (g->ubo[point] != buffer || g->uboOffset[point] != offset || g->uboSize[point] != size) {
            glBindBufferRange(GL_UNIFORM_BUFFER, point, buffer, offset, size);
            g->ubo[point] = buffer; g->uboOffset[point] = offset; g->uboSize[point] = size;
        }
    }
    // Textures: resolve names first (uploads use the scratch unit 79), then bind changed units.
    NSUInteger n = MIN(_texCount, 32);
    GLuint names[32], samplers[32];
    GLenum targets[32];
    BOOL feedback = NO;   // -> _feedback
    for (NSUInteger i = 0; i < n; i++) {
        const TSGLBinding *t = &_texs[i];
        if (t->kind == 3 || t->kind == 4) {
            TSSlot *s = &_buffers[t->stage][t->index];
            targets[i] = GL_TEXTURE_BUFFER;
            samplers[i] = 0;
            GLuint *view = t->kind == 3 ? &s->glTex4 : &s->glTex2;
            if (!*view && [s->buffer isKindOfClass:[TSMtlBuffer class]]) {
                TSActiveUnit(g, 79);
                *view = t->kind == 3 ? [s->buffer glTextureBuffer4] : [s->buffer glTextureBuffer2];
            }
            names[i] = *view;
            GLint off = (GLint)s->offset;   // a program that only reads 16-byte words has no kind-2 entry setting it
            if (t->aux >= 0 && _uniforms->bufferOffset[i] != off) { glUniform1i(t->aux, off); _uniforms->bufferOffset[i] = off; }
            continue;
        }
        if (t->kind == 2) {
            TSSlot *s = &_buffers[t->stage][t->index];
            targets[i] = GL_TEXTURE_BUFFER;
            samplers[i] = 0;
            if (!s->glTex && [s->buffer isKindOfClass:[TSMtlBuffer class]]) { TSActiveUnit(g, 79); s->glTex = [s->buffer glTextureBuffer]; }
            names[i] = s->glTex;
            if (s->staged) TSMtlUnimpl(@"setBytes on a device-memory binding is not supported yet");
            GLint off = (GLint)s->offset;
            if (t->aux >= 0 && _uniforms->bufferOffset[i] != off) { glUniform1i(t->aux, off); _uniforms->bufferOffset[i] = off; }
            continue;
        }
        if (t->rect) {
            // IOSurface sampled in place (the program variant was chosen for this binding, see -rectMask).
            GLuint rect = [self rectangleAt:t->stage index:t->index];
            names[i] = rect;
            targets[i] = GL_TEXTURE_RECTANGLE;
            if (t->kind == 1) samplers[i] = TSGLRectangleSamplerForConstexpr(t->key);
            else {
                __unsafe_unretained TSMtlSamplerState *smp = t->sampler < 16 ? _samplers[t->stage][t->sampler] : nil;
                static GLuint plain;
                if (!plain) plain = TSGLCreateRectangleSampler(0);
                samplers[i] = [smp isKindOfClass:[TSMtlSamplerState class]] ? smp.glRectangleSampler : plain;
            }
            continue;
        }
        if (_colorTex[0] && !feedback) {
            __unsafe_unretained TSMtlTexture *tex = _textures[t->stage][t->index];
            for (int k = 0; k < 8 && _colorTex[k]; k++) feedback |= tex == _colorTex[k];
        }
        if (!_texName[t->stage][t->index]) {
            __unsafe_unretained TSMtlTexture *tex = _textures[t->stage][t->index];
            GLenum target = GL_TEXTURE_2D;
            GLuint name = 0;
            if ([tex isKindOfClass:[TSMtlTexture class]]) { TSActiveUnit(g, 79); name = [tex glTextureForSampling:&target]; }
            _texName[t->stage][t->index] = name ? name : ~0u;
            _texTarget[t->stage][t->index] = target;
        }
        names[i] = _texName[t->stage][t->index] == ~0u ? 0 : _texName[t->stage][t->index];
        targets[i] = _texTarget[t->stage][t->index];
        if (t->kind == 1) samplers[i] = (GLuint)t->aux;
        else if (t->sampler >= 16) samplers[i] = 0;
        else {
            if (!_smpName[t->stage][t->sampler]) {
                __unsafe_unretained TSMtlSamplerState *smp = _samplers[t->stage][t->sampler];
                GLuint name = [smp isKindOfClass:[TSMtlSamplerState class]] ? smp.glSampler : 0;
                _smpName[t->stage][t->sampler] = name ? name : ~0u;
            }
            samplers[i] = _smpName[t->stage][t->sampler] == ~0u ? 0 : _smpName[t->stage][t->sampler];
        }
    }
    _feedback = feedback;
    for (NSUInteger i = 0; i < n; i++) {
        GLuint unit = (GLuint)_texs[i].unit;
        if (g->tex[unit] != names[i] || g->texTarget[unit] != targets[i]) {
            TSActiveUnit(g, unit);
            glBindTexture(targets[i], names[i]);
            g->tex[unit] = names[i];
            g->texTarget[unit] = targets[i];
        }
        if (g->sampler[unit] != samplers[i]) { glBindSampler(unit, samplers[i]); g->sampler[unit] = samplers[i]; }
    }
    // get_num_samples / get_num_mip_levels of the bound textures (TSAirTranslator texInfo:).
    for (NSUInteger i = 0; i < _infoCount; i++) {
        const TSGLBinding *t = &_infos[i];
        __unsafe_unretained TSMtlTexture *tex = t->index < 128 ? _textures[t->stage][t->index] : nil;
        BOOL valid = [tex isKindOfClass:[TSMtlTexture class]];
        GLint samples = valid ? (GLint)MAX(tex.sampleCount, 1) : 1, levels = valid ? (GLint)MAX(tex.mipmapLevelCount, 1) : 1;
        GLint packed = samples | levels << 16;
        if (_uniforms->texInfo[i] != packed) { glUniform2i(t->aux, samples, levels); _uniforms->texInfo[i] = packed; }
    }
}

- (void)applyVertexInputs:(NSUInteger)baseInstance {
    TSGLShadow *g = &_gl;
    const TSGLPipelineState *ps = _gls;
    _vertexBaseInstance = baseInstance;
    struct { GLuint buffer; GLintptr pointer; GLsizei stride; GLuint divisor; BOOL use; } want[16];
    uint32_t used = 0;   // locations with a want[] entry
    // Vertex buffer offsets that move by whole vertices are folded into first/basevertex
    // (unless the shader sees gl_VertexID), so attribute pointers stay put.
    BOOL canShift = !ps->usesVertexID;
    long shift = -1;
    for (uint32_t bits = ps->attribMask; bits; bits &= bits - 1) {
        GLuint i = (GLuint)__builtin_ctz(bits);
        const TSGLAttrib *a = &ps->attribs[i];
        TSSlot *s = &_buffers[0][a->buffer];
        if (a->step == MTLVertexStepFunctionConstant) {
            // Constant attributes: one value for every vertex, read on the CPU.
            NSUInteger avail;
            const uint8_t *p = TSSlotBytes(self, s, &avail);
            GLfloat v[4] = { 0, 0, 0, 1 };
            if (p && a->type == GL_FLOAT && a->offset + a->size * 4 <= avail) memcpy(v, p + a->offset, a->size * 4);
            if (g->attr[i].enabled) { glDisableVertexAttribArray(i); g->attr[i].enabled = 0; }
            glVertexAttrib4fv(i, v);
            continue;
        }
        GLuint buffer;
        GLintptr base;
        GLsizeiptr avail;
        if (!TSSlotResolve(self, s, &buffer, &base, &avail)) continue;
        GLsizei stride = (GLsizei)(s->stride ? s->stride : a->stride);
        GLuint divisor = a->step == MTLVertexStepFunctionPerInstance ? a->stepRate : 0;
        if (divisor) base += (GLintptr)((baseInstance / divisor) * (NSUInteger)stride);   // GL 4.1 has no baseInstance
        want[i].buffer = buffer;
        want[i].pointer = base + a->offset;
        want[i].stride = stride;
        want[i].divisor = divisor;
        want[i].use = YES;
        used |= 1u << i;
        if (divisor || !canShift) continue;
        __typeof__(g->attr[0]) *sh = &g->attr[i];
        GLintptr delta = want[i].pointer - sh->pointer;
        if (sh->buffer == buffer && sh->stride == stride && stride > 0 && sh->divisor == 0 && sh->enabled == 1 &&
            sh->size == a->size && sh->type == a->type && delta >= 0 && delta % stride == 0) {
            long k = (long)(delta / stride);
            if (shift < 0) shift = k; else if (shift != k) canShift = NO;
        } else canShift = NO;
    }
    BOOL keep = canShift && shift >= 0;
    _vertexShift = keep ? shift : 0;
    for (GLuint i = 0; i < 16; i++) {
        __typeof__(g->attr[0]) *sh = &g->attr[i];
        if (!(used & (1u << i))) {
            if (sh->enabled == 0) continue;
            if ((ps->attribMask & (1 << i)) && ps->attribs[i].step == MTLVertexStepFunctionConstant) continue;
            glDisableVertexAttribArray(i);
            sh->enabled = 0;
            continue;
        }
        const TSGLAttrib *a = &ps->attribs[i];
        if (keep && !want[i].divisor) continue;   // pointer stays, the draw adds _vertexShift
        if (sh->buffer != want[i].buffer || sh->pointer != want[i].pointer || sh->stride != want[i].stride ||
            sh->size != a->size || sh->type != a->type || sh->normalized != a->normalized || sh->integer != a->integer) {
            TSArrayBuffer(g, want[i].buffer);
            const void *ptr = (const void *)want[i].pointer;
            if (a->integer) glVertexAttribIPointer(i, a->size, a->type, want[i].stride, ptr);
            else glVertexAttribPointer(i, a->size, a->type, a->normalized, want[i].stride, ptr);
            sh->buffer = want[i].buffer; sh->pointer = want[i].pointer; sh->stride = want[i].stride;
            sh->size = a->size; sh->type = a->type; sh->normalized = a->normalized; sh->integer = a->integer;
        }
        if (sh->divisor != want[i].divisor) { glVertexAttribDivisor(i, want[i].divisor); sh->divisor = want[i].divisor; }
        if (sh->enabled != 1) { glEnableVertexAttribArray(i); sh->enabled = 1; }
    }
}

- (void)applyFixedFunction {
    TSGLShadow *g = &_gl;
    if ((_dirty & TSDirtyViewport) && memcmp(&g->viewport, &_viewport, sizeof _viewport)) {
        glViewportIndexedf(0, _viewport.originX, _viewport.originY, _viewport.width, _viewport.height);
        glDepthRange(_viewport.znear, _viewport.zfar);
        g->viewport = _viewport;
    }
    if (_dirty & TSDirtyScissor) {
        if (g->scissorEnabled != _scissorSet) { if (_scissorSet) glEnable(GL_SCISSOR_TEST); else glDisable(GL_SCISSOR_TEST); g->scissorEnabled = _scissorSet; }
        if (_scissorSet && memcmp(&g->scissor, &_scissor, sizeof _scissor)) {
            glScissor((GLint)_scissor.x, (GLint)_scissor.y, (GLsizei)_scissor.width, (GLsizei)_scissor.height);
            g->scissor = _scissor;
        }
    }
    if (_dirty & TSDirtyRaster) {
        TSRaster r;
        memset(&r, 0, sizeof r);
        r.cull = _cull != MTLCullModeNone;
        r.cullFace = _cull == MTLCullModeFront ? GL_FRONT : GL_BACK;
        // Metal judges winding in y-up NDC like GL; the vertex wrapper flips y, which mirrors
        // the triangle for GL, so the GL front face is the opposite of the Metal one.
        r.frontFace = _winding == MTLWindingClockwise ? GL_CCW : GL_CW;
        r.polygonMode = _fill == MTLTriangleFillModeLines ? GL_LINE : GL_FILL;
        r.offset = _depthBias != 0 || _slopeScale != 0;
        r.slope = _slopeScale;
        r.bias = _depthBias;
        r.clamp = _depthClip == MTLDepthClipModeClamp;
        TSRaster *o = &g->raster;
        if (o->cull != r.cull) { if (r.cull) glEnable(GL_CULL_FACE); else glDisable(GL_CULL_FACE); }
        if (r.cull && o->cullFace != r.cullFace) glCullFace(r.cullFace);
        if (o->frontFace != r.frontFace) glFrontFace(r.frontFace);
        if (o->polygonMode != r.polygonMode) glPolygonMode(GL_FRONT_AND_BACK, r.polygonMode);
        if (o->offset != r.offset) {
            if (r.offset) { glEnable(GL_POLYGON_OFFSET_FILL); glEnable(GL_POLYGON_OFFSET_LINE); }
            else { glDisable(GL_POLYGON_OFFSET_FILL); glDisable(GL_POLYGON_OFFSET_LINE); }
        }
        if (r.offset && (o->slope != r.slope || o->bias != r.bias)) glPolygonOffset(r.slope, r.bias);
        if (o->clamp != r.clamp) { if (r.clamp) glEnable(GL_DEPTH_CLAMP); else glDisable(GL_DEPTH_CLAMP); }
        if (!r.cull) r.cullFace = o->cullFace;
        if (!r.offset) { r.slope = o->slope; r.bias = o->bias; }
        *o = r;
    }
    if (_dirty & TSDirtyDepthStencil) {
        TSDepthStencilGL d;
        memset(&d, 0, sizeof d);
        const TSGLDepthStencil *ds = _depthStencil ? _depthStencil.glState : NULL;
        d.depthTest = _hasDepth && ds && ds->depthTest && !gTSNoDepth;
        d.depthWrite = d.depthTest && ds->depthWrite;
        d.depthFunc = d.depthTest ? ds->depthFunc : 0;
        d.stencil = _hasStencil && ds;
        if (d.stencil) { d.face[0] = ds->face[0]; d.face[1] = ds->face[1]; d.ref[0] = _stencilFront; d.ref[1] = _stencilBack; }
        if (memcmp(&g->ds, &d, sizeof d)) {
            if (d.depthTest) { glEnable(GL_DEPTH_TEST); glDepthFunc(d.depthFunc); glDepthMask(d.depthWrite ? GL_TRUE : GL_FALSE); }
            else { glDisable(GL_DEPTH_TEST); glDepthMask(GL_FALSE); }
            if (d.stencil) {
                glEnable(GL_STENCIL_TEST);
                GLenum faces[2] = { GL_FRONT, GL_BACK };
                for (int f = 0; f < 2; f++) {
                    glStencilFuncSeparate(faces[f], d.face[f].func, (GLint)d.ref[f], d.face[f].readMask);
                    glStencilOpSeparate(faces[f], d.face[f].fail, d.face[f].depthFail, d.face[f].pass);
                    glStencilMaskSeparate(faces[f], d.face[f].writeMask);
                }
            } else {
                glDisable(GL_STENCIL_TEST);
            }
            g->ds = d;
        }
    }
    if ((_dirty & TSDirtyBlendColor) && memcmp(g->blendColor, _blendColor, sizeof _blendColor)) {
        glBlendColor(_blendColor[0], _blendColor[1], _blendColor[2], _blendColor[3]);
        memcpy(g->blendColor, _blendColor, sizeof _blendColor);
    }
}

// GL_TEXTURE_RECTANGLE of the IOSurface texture bound at a slot, 0 if it is not one.
- (GLuint)rectangleAt:(NSUInteger)stage index:(NSUInteger)index {
    GLuint r = _texRect[stage][index];
    if (!r) {
        __unsafe_unretained TSMtlTexture *tex = _textures[stage][index];
        if ([tex isKindOfClass:[TSMtlTexture class]]) { TSActiveUnit(&_gl, 79); r = [tex glRectangleForSampling]; }
        _texRect[stage][index] = r = r ? r : ~0u;
    }
    return r == ~0u ? 0 : r;
}

// Which variant slots of the pipeline need their variant right now: rectangle-capable slots holding IOSurface
// textures, device buffers with coalesced loads bound at offsets that are not 16-aligned.
- (uint32_t)rectMask {
    TSMtlRenderPipelineState *p = _pipeline;
    NSUInteger n = p.rectSlotCount;
    if (!n) return 0;
    const uint16_t *slots = p.rectSlots;
    uint32_t mask = 0;
    for (NSUInteger i = 0; i < n; i++) {
        int stage = (slots[i] >> 8) & 1, index = slots[i] & 0xff;
        if (slots[i] & TSSlotBuffer) { if (index < 31 && (_buffers[stage][index].offset & 15)) mask |= 1u << i; }
        else if ([self rectangleAt:stage index:index]) mask |= 1u << i;
    }
    return mask;
}

// The program variant for a rectangle mask. Linking one here happens mid-pass: put the pass
// framebuffer and vertex array back and forget the GL state shadow (the warm-up draw rebinds units).
- (TSGLProgram *)programForMask:(uint32_t)mask {
    uint64_t links = gTSGLProgramLinkCount;
    TSGLProgram *prog = [_pipeline programForRectMask:mask];
    [_pipeline noteDrawnMask:mask];
    if (gTSGLProgramLinkCount != links) {
        if (gTSMtlDrawTrace) fprintf(stderr, "[TSDraw]   link mid-pass: variant 0x%x\n", mask);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _fbo);
        glBindVertexArray(_vao);
        memset(&_gl, 0xFF, sizeof _gl);
        _dirty |= TSDirtyResources | TSDirtyVertex | TSDirtyFixed;
    }
    return prog;
}

- (BOOL)usePipeline {
    _rectMask = [self rectMask];
    TSGLProgram *prog = [self programForMask:_rectMask];
    if (prog && !prog->_drawn) { prog->_drawn = YES; TSMtlStat(TSStatProgramsDrawn, 1); }
    return [self useProgram:prog];
}

- (BOOL)useProgram:(TSGLProgram *)prog {
    TSMtlRenderPipelineState *p = _pipeline;
    TSGLShadow *g = &_gl;
    _prog = prog;
    _program = prog ? prog->_program : 0;
    if (!_program) return NO;
    _gls = p.glState;
    _uniforms = &prog->_uniforms;
    _blocks = prog->_blocks; _blockCount = prog->_blockCount;
    _texs = prog->_textures; _texCount = prog->_textureCount;
    _infos = prog->_infos; _infoCount = prog->_infoCount;
    _baseInstanceLoc = prog->_baseInstanceLocation;
    _baseVertexLoc = prog->_baseVertexLocation;
    _instanceAttribs = NO;
    for (int i = 0; i < 16; i++)
        if ((_gls->attribMask & (1 << i)) && _gls->attribs[i].step == MTLVertexStepFunctionPerInstance) _instanceAttribs = YES;
    if (g->program != _program) { glUseProgram(_program); g->program = _program; }
    for (GLuint i = 0; i < 8; i++) {
        const TSGLColorState *c = &_gls->color[i];
        TSGLColorState *o = &g->color[i];
        if (!memcmp(c, o, sizeof *c)) continue;
        if (memcmp(c->mask, o->mask, 4)) glColorMaski(i, c->mask[0], c->mask[1], c->mask[2], c->mask[3]);
        if (c->blend != o->blend) { if (c->blend) glEnablei(GL_BLEND, i); else glDisablei(GL_BLEND, i); }
        if (c->blend && (c->rgbOp != o->rgbOp || c->alphaOp != o->alphaOp)) glBlendEquationSeparatei(i, c->rgbOp, c->alphaOp);
        if (c->blend && (c->srcRGB != o->srcRGB || c->dstRGB != o->dstRGB || c->srcAlpha != o->srcAlpha || c->dstAlpha != o->dstAlpha))
            glBlendFuncSeparatei(i, c->srcRGB, c->dstRGB, c->srcAlpha, c->dstAlpha);
        // A disabled blend leaves the GL equation/factors untouched: remember what GL still holds.
        TSGLColorState keep = *c;
        if (!c->blend) { keep.rgbOp = o->rgbOp; keep.alphaOp = o->alphaOp; keep.srcRGB = o->srcRGB; keep.dstRGB = o->dstRGB;
                         keep.srcAlpha = o->srcAlpha; keep.dstAlpha = o->dstAlpha; }
        *o = keep;
    }
    if (g->multisample != _gls->multisample) { if (_gls->multisample) glEnable(GL_MULTISAMPLE); else glDisable(GL_MULTISAMPLE); g->multisample = _gls->multisample; }
    if (g->alphaToCoverage != _gls->alphaToCoverage) {
        if (_gls->alphaToCoverage) glEnable(GL_SAMPLE_ALPHA_TO_COVERAGE); else glDisable(GL_SAMPLE_ALPHA_TO_COVERAGE);
        g->alphaToCoverage = _gls->alphaToCoverage;
    }
    return YES;
}

- (BOOL)prepareDraw:(NSUInteger)baseInstance {
    if (!_pipeline) return NO;
    if (gTSNoShadow) {
        memset(&_gl, 0xFF, sizeof _gl);
        _dirty |= TSDirtyPipeline | TSDirtyResources | TSDirtyVertex | TSDirtyFixed;
    }
    TSMtlStat(TSStatDraws, 1);
    if (_dirty & TSDirtyPipeline) {
        if (![self usePipeline]) return NO;
        _dirty = (_dirty & ~TSDirtyPipeline) | TSDirtyResources | TSDirtyVertex;
    } else if ((_dirty & TSDirtyResources) && _pipeline.rectSlotCount) {
        // New textures or buffer offsets may switch between the base program and a variant (rectangle, unaligned).
        uint32_t mask = [self rectMask];
        if (mask != _rectMask) {
            _rectMask = mask;
            if (![self useProgram:[self programForMask:mask]]) return NO;
            _dirty |= TSDirtyVertex;
        }
    }
    if (!_program) return NO;
    if (gTSNoShadow) memset(_uniforms, 0xFF, sizeof *_uniforms);
    if (_baseInstanceLoc >= 0 && _uniforms->baseInstance != (GLint)baseInstance) {
        glUniform1i(_baseInstanceLoc, (GLint)baseInstance);
        _uniforms->baseInstance = (GLint)baseInstance;
    }
    if (_dirty & TSDirtyResources) [self applyResources];
    // A draw that samples a color attachment of its own pass (RenderBox's glass shape passes read back what the
    // previous draws wrote) needs those writes made visible first: without the barrier the GPU returns stale 8x8
    // tiles. GL_NV_texture_barrier, as Metal's textureBarrier; reads of texels the same draw writes stay undefined.
    if (_feedback) {
        static void (*barrier)(void);
        static dispatch_once_t once;
        dispatch_once(&once, ^{   // TSMTL_TEXTURE_BARRIER=0: off (A/B)
            const char *e = getenv("TSMTL_TEXTURE_BARRIER");
            if (!(e && *e == '0')) barrier = (void (*)(void))dlsym(RTLD_DEFAULT, "glTextureBarrierNV");
        });
        if (barrier) barrier();
        if (gTSMtlDrawTrace) fprintf(stderr, "[TSDraw]   texture barrier (draw samples a color attachment)\n");
    }
    if ((_dirty & TSDirtyVertex) || (_instanceAttribs && baseInstance != _vertexBaseInstance)) [self applyVertexInputs:baseInstance];
    if (_dirty & TSDirtyFixed) [self applyFixedFunction];
    _dirty = 0;
    return YES;
}

- (void)drawPrimitives:(MTLPrimitiveType)type start:(NSUInteger)start count:(NSUInteger)count
             instances:(NSUInteger)instances baseInstance:(NSUInteger)baseInstance {
    if (!count || !instances || ![self prepareDraw:baseInstance]) return;
    if (gTSMtlDrawTrace) [self drawTrace:[NSString stringWithFormat:@"draw t%lu v%lu+%lu", (unsigned long)type, (unsigned long)start, (unsigned long)count]
                               instances:instances baseInstance:baseInstance];
    if (gTSMtlProfileOn) TSProfileBegin(_pipeline);
    glDrawArraysInstanced(TSGLPrimitive(type), (GLint)(start + _vertexShift), (GLsizei)count, (GLsizei)instances);
    if (gTSMtlDrawTrace && (gTSMtlDrawTraceHeavy & TSHeavyTarget)) [self drawTracePost];
    if (gTSSyncDraw) { TSMtlComputeJoin(); glFinish(); }
    if (gTSMtlProfileOn) TSProfileEnd();
}

- (void)drawIndexed:(MTLPrimitiveType)type count:(NSUInteger)count indexType:(MTLIndexType)indexType buffer:(id)indexBuffer
             offset:(NSUInteger)offset instances:(NSUInteger)instances baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    if (!count || !instances || ![self prepareDraw:baseInstance]) return;
    if (indexBuffer != _indexBuffer) {
        _indexBuffer = indexBuffer;
        _indexGL = [indexBuffer isKindOfClass:[TSMtlBuffer class]] ? [(TSMtlBuffer *)indexBuffer glBuffer] : 0;
    }
    if (!_indexGL) return;
    TSGLShadow *g = &_gl;
    if (g->elementBuffer != _indexGL) { glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexGL); g->elementBuffer = _indexGL; }
    if (_baseVertexLoc >= 0 && _uniforms->baseVertex != (GLint)baseVertex) {
        glUniform1i(_baseVertexLoc, (GLint)baseVertex);
        _uniforms->baseVertex = (GLint)baseVertex;
    }
    BOOL u16 = indexType == MTLIndexTypeUInt16;
    if (g->restartType != indexType) { glPrimitiveRestartIndex(u16 ? 0xFFFF : 0xFFFFFFFF); g->restartType = (uint32_t)indexType; }
    if (gTSMtlDrawTrace) [self drawTrace:[NSString stringWithFormat:@"drawIdx t%lu n%lu off%lu bv%ld", (unsigned long)type, (unsigned long)count,
                                          (unsigned long)offset, (long)baseVertex] instances:instances baseInstance:baseInstance];
    if (gTSMtlProfileOn) TSProfileBegin(_pipeline);
    glDrawElementsInstancedBaseVertex(TSGLPrimitive(type), (GLsizei)count, u16 ? GL_UNSIGNED_SHORT : GL_UNSIGNED_INT,
                                      (const void *)offset, (GLsizei)instances, (GLint)(baseVertex + _vertexShift));
    if (gTSMtlDrawTrace && (gTSMtlDrawTraceHeavy & TSHeavyTarget)) [self drawTracePost];
    if (gTSSyncDraw) { TSMtlComputeJoin(); glFinish(); }
    if (gTSMtlProfileOn) TSProfileEnd();
}
@end

#pragma mark - Render command encoder

@interface TSMtlRenderEncoder : _MTLCommandEncoder <MTLRenderCommandEncoder>
- (instancetype)initWithCommandBuffer:(TSMtlCommandBuffer *)cb pass:(TSGLRenderPass *)pass parent:(id)parent;
- (TSRecordingBox *)takeRecording;
@end

@interface TSMtlParallelRenderEncoder : _MTLCommandEncoder <MTLParallelRenderCommandEncoder>
- (instancetype)initWithCommandBuffer:(TSMtlCommandBuffer *)cb descriptor:(MTLRenderPassDescriptor *)desc;
@end

// Last value recorded for each piece of state; a set* that repeats it records nothing.
// All bytes start at 0xFF: pointers ~0, NaN floats and huge integers never match a real value.
typedef struct {
    const void *pipeline, *depthStencil;
    const void *buffer[2][31];
    uint64_t offset[2][31], stride[2][31];
    uint32_t bytesLength[2][31], bytesAt[2][31];   // last setBytes payload in the staging area (~0 = none)
    const void *texture[2][128], *sampler[2][16];
    MTLViewport viewport;
    MTLScissorRect scissor;
    uint32_t cull, winding, fill, depthClip, stencilFront, stencilBack;
    float bias, slope, blend[4];
} TSEncodeShadow;

@implementation TSMtlRenderEncoder {
    TSGLRenderPass *_pass;
    __weak id _parent;
    TSRecordingBox *_box;
    TSRecording *_rec;
    TSEncodeShadow _sh;
}

+ (void)initialize { if (self == [TSMtlRenderEncoder class]) TSMtlInstallCatchAll(self); }

- (instancetype)initWithCommandBuffer:(TSMtlCommandBuffer *)cb pass:(TSGLRenderPass *)pass parent:(id)parent {
    if ((self = [super initWithCommandBuffer:cb])) {
        _pass = pass;
        _parent = parent;
        _box = [TSRecordingBox new];
        _box->rec = _rec = calloc(1, sizeof *_rec);
        _rec->retain = [(id)cb retainedReferences];
        memset(&_sh, 0xFF, sizeof _sh);
    }
    return self;
}

- (TSRecordingBox *)takeRecording {
    TSRecordingBox *b = _box;
    _box = nil;
    _rec = NULL;
    return b;
}

- (void)endEncoding {
    if (!_parent) {   // a parallel encoder collects its children's recordings itself
        TSGLRenderPass *pass = _pass;
        TSRecordingBox *box = [self takeRecording];
        [(TSMtlCommandBuffer *)[(id)self commandBuffer] recordCommand:^{
            [pass begin];
            [pass run:box->rec];
            [pass end];
            TSRecordingFree(box->rec);
            box->rec = NULL;
        }];
    }
    [super endEncoding];
}

#define REC(type, op) type *c = TSRecord(_rec, op, sizeof(type))

static void TSRecordObject(TSRecording *r, TSOp op, id object) {
    TSCmdObject *c = TSRecord(r, op, sizeof *c);
    c->object = (__bridge const void *)object;
    TSRecordRetain(r, c->object);
}

static void TSRecordU32(TSRecording *r, TSOp op, uint32_t v) { TSCmdU32 *c = TSRecord(r, op, sizeof *c); c->value = v; }

#pragma mark State

- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)state {
    if (_sh.pipeline == (__bridge const void *)state) return;
    _sh.pipeline = (__bridge const void *)state;
    TSRecordObject(_rec, TSOpPipeline, state);
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)state {
    if (_sh.depthStencil == (__bridge const void *)state) return;
    _sh.depthStencil = (__bridge const void *)state;
    TSRecordObject(_rec, TSOpDepthStencil, state);
}
- (void)setViewport:(MTLViewport)v {
    if (!memcmp(&_sh.viewport, &v, sizeof v)) return;
    _sh.viewport = v;
    REC(TSCmdViewport, TSOpViewport); c->v = v;
}
- (void)setViewports:(const MTLViewport *)v count:(NSUInteger)count { if (count) [self setViewport:v[0]]; }
- (void)setScissorRect:(MTLScissorRect)r {
    if (!memcmp(&_sh.scissor, &r, sizeof r)) return;
    _sh.scissor = r;
    REC(TSCmdScissor, TSOpScissor); c->r = r;
}
- (void)setScissorRects:(const MTLScissorRect *)r count:(NSUInteger)count { if (count) [self setScissorRect:r[0]]; }
- (void)setCullMode:(MTLCullMode)mode { if (_sh.cull != mode) { _sh.cull = (uint32_t)mode; TSRecordU32(_rec, TSOpCull, (uint32_t)mode); } }
- (void)setFrontFacingWinding:(MTLWinding)w { if (_sh.winding != w) { _sh.winding = (uint32_t)w; TSRecordU32(_rec, TSOpWinding, (uint32_t)w); } }
- (void)setTriangleFillMode:(MTLTriangleFillMode)m { if (_sh.fill != m) { _sh.fill = (uint32_t)m; TSRecordU32(_rec, TSOpFill, (uint32_t)m); } }
- (void)setDepthClipMode:(MTLDepthClipMode)m { if (_sh.depthClip != m) { _sh.depthClip = (uint32_t)m; TSRecordU32(_rec, TSOpDepthClip, (uint32_t)m); } }
- (void)setDepthBias:(float)bias slopeScale:(float)slope clamp:(float)clamp {
    if (_sh.bias == bias && _sh.slope == slope) return;
    _sh.bias = bias; _sh.slope = slope;
    REC(TSCmdDepthBias, TSOpDepthBias); c->bias = bias; c->slope = slope;
}
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b {
    if (_sh.stencilFront == f && _sh.stencilBack == b) return;
    _sh.stencilFront = f; _sh.stencilBack = b;
    REC(TSCmdStencilRef, TSOpStencilRef); c->front = f; c->back = b;
}
- (void)setStencilReferenceValue:(uint32_t)v { [self setStencilFrontReferenceValue:v backReferenceValue:v]; }
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
    float v[4] = { r, g, b, a };
    if (!memcmp(_sh.blend, v, sizeof v)) return;
    memcpy(_sh.blend, v, sizeof v);
    REC(TSCmdBlendColor, TSOpBlendColor); memcpy(c->rgba, v, sizeof v);
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset {
    REC(TSCmdVisibility, TSOpVisibility); c->mode = (uint32_t)mode; c->offset = offset;
}
- (void)setColorStoreAction:(MTLStoreAction)action atIndex:(NSUInteger)index {}
- (void)setDepthStoreAction:(MTLStoreAction)action {}
- (void)setStencilStoreAction:(MTLStoreAction)action {}
- (void)textureBarrier {}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before {}
- (void)updateFence:(id<MTLFence>)fence afterStages:(MTLRenderStages)stages {}
- (void)waitForFence:(id<MTLFence>)fence beforeStages:(MTLRenderStages)stages {}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage {}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {}
- (void)useResources:(const id<MTLResource> [])resources count:(NSUInteger)count usage:(MTLResourceUsage)usage {}
- (void)useResources:(const id<MTLResource> [])resources count:(NSUInteger)count usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {}
- (void)useHeap:(id<MTLHeap>)heap {}
- (void)useHeap:(id<MTLHeap>)heap stages:(MTLRenderStages)stages {}
- (void)useHeaps:(const id<MTLHeap> [])heaps count:(NSUInteger)count {}
- (void)useHeaps:(const id<MTLHeap> [])heaps count:(NSUInteger)count stages:(MTLRenderStages)stages {}
- (void)pushDebugGroup:(NSString *)string {}
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)string {}

#pragma mark Buffers, textures, samplers

- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset stride:(NSUInteger)stride stage:(int)stage index:(NSUInteger)index {
    if (index > 30) return;
    const void *b = (__bridge const void *)buffer;
    if (_sh.buffer[stage][index] == b && _sh.offset[stage][index] == offset && _sh.stride[stage][index] == stride) return;
    if (_sh.buffer[stage][index] == b && _sh.stride[stage][index] == stride) {
        _sh.offset[stage][index] = offset;
        REC(TSCmdOffset, TSOpOffset); c->stage = stage; c->index = index; c->offset = offset;
        return;
    }
    _sh.buffer[stage][index] = b; _sh.offset[stage][index] = offset; _sh.stride[stage][index] = stride;
    _sh.bytesLength[stage][index] = ~0u;
    REC(TSCmdBuffer, TSOpBuffer);
    c->stage = stage; c->index = index; c->buffer = b; c->offset = offset; c->stride = stride;
    TSRecordRetain(_rec, b);
}
- (void)setBytes:(const void *)bytes length:(NSUInteger)length stage:(int)stage index:(NSUInteger)index {
    if (index > 30) return;
    uint32_t n = (uint32_t)length;
    if (_sh.bytesLength[stage][index] == n && !memcmp(_rec->staging + _sh.bytesAt[stage][index], bytes, n)) return;
    uint32_t at = TSRecordStage(_rec, bytes, n);
    _sh.bytesLength[stage][index] = n; _sh.bytesAt[stage][index] = at;
    _sh.buffer[stage][index] = (const void *)~(uintptr_t)0;
    REC(TSCmdBytes, TSOpBytes); c->stage = stage; c->index = index; c->length = n; c->staged = at;
}
- (void)setOffset:(NSUInteger)offset stage:(int)stage index:(NSUInteger)index {
    if (index > 30 || _sh.offset[stage][index] == offset) return;
    _sh.offset[stage][index] = offset;
    REC(TSCmdOffset, TSOpOffset); c->stage = stage; c->index = index; c->offset = offset;
}
- (void)setTexture:(id<MTLTexture>)texture stage:(int)stage index:(NSUInteger)index {
    if (index > 127 || _sh.texture[stage][index] == (__bridge const void *)texture) return;
    _sh.texture[stage][index] = (__bridge const void *)texture;
    REC(TSCmdBinding, TSOpTexture); c->stage = stage; c->index = index; c->object = (__bridge const void *)texture;
    IOSurfaceRef surface = texture.iosurface;
    c->seed = gTSMtlDrawTraceArmed && surface ? IOSurfaceGetSeed(surface) : 0;
    TSRecordRetain(_rec, c->object);
    if (surface) [(TSMtlCommandBuffer *)[(id)self commandBuffer] useSurface:surface];
}
- (void)setSampler:(id<MTLSamplerState>)sampler stage:(int)stage index:(NSUInteger)index {
    if (index > 15 || _sh.sampler[stage][index] == (__bridge const void *)sampler) return;
    _sh.sampler[stage][index] = (__bridge const void *)sampler;
    REC(TSCmdBinding, TSOpSampler); c->stage = stage; c->index = index; c->object = (__bridge const void *)sampler;
    TSRecordRetain(_rec, c->object);
}

- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self setBuffer:b offset:o stride:0 stage:0 index:i]; }
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o attributeStride:(NSUInteger)s atIndex:(NSUInteger)i { [self setBuffer:b offset:o stride:s stage:0 index:i]; }
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self setOffset:o stage:0 index:i]; }
- (void)setVertexBufferOffset:(NSUInteger)o attributeStride:(NSUInteger)s atIndex:(NSUInteger)i { [self setOffset:o stage:0 index:i]; }
- (void)setVertexBuffers:(const id<MTLBuffer> [])b offsets:(const NSUInteger *)o withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setBuffer:b[k] offset:o[k] stride:0 stage:0 index:r.location + k];
}
- (void)setVertexBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i { [self setBytes:p length:n stage:0 index:i]; }
- (void)setVertexBytes:(const void *)p length:(NSUInteger)n attributeStride:(NSUInteger)s atIndex:(NSUInteger)i { [self setBytes:p length:n stage:0 index:i]; }
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self setTexture:t stage:0 index:i]; }
- (void)setVertexTextures:(const id<MTLTexture> [])t withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setTexture:t[k] stage:0 index:r.location + k];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self setSampler:s stage:0 index:i]; }
- (void)setVertexSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)a lodMaxClamp:(float)b atIndex:(NSUInteger)i { [self setSampler:s stage:0 index:i]; }
- (void)setVertexSamplerStates:(const id<MTLSamplerState> [])s withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setSampler:s[k] stage:0 index:r.location + k];
}

- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self setBuffer:b offset:o stride:0 stage:1 index:i]; }
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self setOffset:o stage:1 index:i]; }
- (void)setFragmentBuffers:(const id<MTLBuffer> [])b offsets:(const NSUInteger *)o withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setBuffer:b[k] offset:o[k] stride:0 stage:1 index:r.location + k];
}
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i { [self setBytes:p length:n stage:1 index:i]; }
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self setTexture:t stage:1 index:i]; }
- (void)setFragmentTextures:(const id<MTLTexture> [])t withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setTexture:t[k] stage:1 index:r.location + k];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self setSampler:s stage:1 index:i]; }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)a lodMaxClamp:(float)b atIndex:(NSUInteger)i { [self setSampler:s stage:1 index:i]; }
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> [])s withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setSampler:s[k] stage:1 index:r.location + k];
}

#pragma mark Draws

- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
         instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)baseInstance {
    if (gTSNoDedup) memset(&_sh, 0xFF, sizeof _sh);
    REC(TSCmdDraw, TSOpDraw);
    c->type = (uint32_t)type; c->start = (uint32_t)start; c->count = (uint32_t)count;
    c->instances = (uint32_t)instances; c->baseInstance = (uint32_t)baseInstance;
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances {
    [self drawPrimitives:type vertexStart:start vertexCount:count instanceCount:instances baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count {
    [self drawPrimitives:type vertexStart:start vertexCount:count instanceCount:1 baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)type indirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)offset {
    if (gTSNoDedup) memset(&_sh, 0xFF, sizeof _sh);
    REC(TSCmdDrawIndirect, TSOpDrawIndirect);
    c->type = (uint32_t)type; c->indirect = (__bridge const void *)buffer; c->indirectOffset = offset; c->indexBuffer = NULL;
    TSRecordRetain(_rec, c->indirect);
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType
                  indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)offset instanceCount:(NSUInteger)instances
                   baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    if (gTSNoDedup) memset(&_sh, 0xFF, sizeof _sh);
    REC(TSCmdDrawIndexed, TSOpDrawIndexed);
    c->type = (uint32_t)type; c->indexType = (uint32_t)indexType; c->count = (uint32_t)count; c->instances = (uint32_t)instances;
    c->baseInstance = (uint32_t)baseInstance; c->baseVertex = (int32_t)baseVertex;
    c->indexBuffer = (__bridge const void *)indexBuffer; c->offset = offset;
    TSRecordRetain(_rec, c->indexBuffer);
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType
                  indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)offset instanceCount:(NSUInteger)instances {
    [self drawIndexedPrimitives:type indexCount:count indexType:indexType indexBuffer:indexBuffer indexBufferOffset:offset
                  instanceCount:instances baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType
                  indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)offset {
    [self drawIndexedPrimitives:type indexCount:count indexType:indexType indexBuffer:indexBuffer indexBufferOffset:offset
                  instanceCount:1 baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer
            indexBufferOffset:(NSUInteger)offset indirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)indirectOffset {
    if (gTSNoDedup) memset(&_sh, 0xFF, sizeof _sh);
    REC(TSCmdDrawIndirect, TSOpDrawIndexedIndirect);
    c->type = (uint32_t)type; c->indexType = (uint32_t)indexType; c->indirect = (__bridge const void *)buffer;
    c->indirectOffset = indirectOffset; c->indexBuffer = (__bridge const void *)indexBuffer; c->indexOffset = offset;
    TSRecordRetain(_rec, c->indirect);
    TSRecordRetain(_rec, c->indexBuffer);
}
@end

#pragma mark - Parallel render command encoder

@implementation TSMtlParallelRenderEncoder {
    TSGLRenderPass *_pass;
    NSMutableArray<TSMtlRenderEncoder *> *_children;
}

+ (void)initialize { if (self == [TSMtlParallelRenderEncoder class]) TSMtlInstallCatchAll(self); }

- (instancetype)initWithCommandBuffer:(TSMtlCommandBuffer *)cb descriptor:(MTLRenderPassDescriptor *)desc {
    if ((self = [super initWithCommandBuffer:cb])) {
        _pass = [[TSGLRenderPass alloc] initWithDevice:(TSMtlDevice *)cb.device descriptor:desc];
        _children = [NSMutableArray array];
    }
    return self;
}

- (id<MTLRenderCommandEncoder>)renderCommandEncoder {
    TSMtlRenderEncoder *child = [[TSMtlRenderEncoder alloc] initWithCommandBuffer:[(id)self commandBuffer] pass:_pass parent:self];
    @synchronized (_children) { [_children addObject:child]; }
    return child;
}

- (void)endEncoding {
    TSGLRenderPass *pass = _pass;
    NSMutableArray<TSRecordingBox *> *recs = [NSMutableArray array];
    @synchronized (_children) {
        for (TSMtlRenderEncoder *child in _children) { TSRecordingBox *b = [child takeRecording]; if (b) [recs addObject:b]; }
        [_children removeAllObjects];
    }
    [(TSMtlCommandBuffer *)[(id)self commandBuffer] recordCommand:^{
        [pass begin];
        for (TSRecordingBox *b in recs) { [pass run:b->rec]; TSRecordingFree(b->rec); b->rec = NULL; }
        [pass end];
    }];
    [super endEncoding];
}
@end

#pragma mark - Factory used by TSMtlCommandBuffer

void TSMtlUsePassSurfaces(TSMtlCommandBuffer *cb, MTLRenderPassDescriptor *desc) {
    for (NSUInteger i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = desc.colorAttachments[i];
        [cb useSurface:a.texture.iosurface];
        [cb useSurface:a.resolveTexture.iosurface];
    }
    [cb useSurface:desc.depthAttachment.texture.iosurface];
    [cb useSurface:desc.stencilAttachment.texture.iosurface];
}

id<MTLRenderCommandEncoder> TSMtlNewRenderEncoder(TSMtlCommandBuffer *cb, MTLRenderPassDescriptor *desc) {
    TSMtlUsePassSurfaces(cb, desc);
    TSGLRenderPass *pass = [[TSGLRenderPass alloc] initWithDevice:(TSMtlDevice *)cb.device descriptor:desc];
    return [[TSMtlRenderEncoder alloc] initWithCommandBuffer:cb pass:pass parent:nil];
}

id<MTLParallelRenderCommandEncoder> TSMtlNewParallelRenderEncoder(TSMtlCommandBuffer *cb, MTLRenderPassDescriptor *desc) {
    TSMtlUsePassSurfaces(cb, desc);
    return [[TSMtlParallelRenderEncoder alloc] initWithCommandBuffer:cb descriptor:desc];
}
