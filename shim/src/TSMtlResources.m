// TeraScale Metal Shim - buffers and textures.
//
// Coherency model:
//   Buffers  - the CPU copy is the truth (GL 4.1 has no compute, so the GPU never
//              writes buffers). Shared storage is re-uploaded once per executed command
//              buffer (CPU writes are not tracked); private storage only uploads the
//              ranges our blits wrote; managed storage the ranges from didModifyRange
//              (until the app first calls it, it is treated like shared).
//   Textures - one GL "mirror" per texture object (GL 4.1 has no texture views, so a
//              view gets its own unless it can alias the root's: same GL format renders
//              straight into the root; full-range views also sample it). The root keeps a
//              CPU generation counter plus the regions written since the last full change,
//              so its mirror re-uploads only those; the mirror that last rendered is the
//              "GPU owner" and is read back before anybody else touches the data.
//   IOSurface textures - a GL_TEXTURE_RECTANGLE bound to the surface is the truth for
//              rendering; sampling goes through a 2D copy refreshed by a GPU blit.
#import "TSPrivate.h"
#import <mach/mach.h>
#import <os/lock.h>

static NSUInteger TSRoundPage(NSUInteger n) { return (MAX(n, 1) + vm_page_size - 1) & ~(NSUInteger)(vm_page_size - 1); }

static MTLResourceOptions TSResourceOptions(MTLStorageMode s, MTLCPUCacheMode c, MTLHazardTrackingMode h) {
    return (s << MTLResourceStorageModeShift) | (c << MTLResourceCPUCacheModeShift) | (h << MTLResourceHazardTrackingModeShift);
}

#pragma mark - Buffer

@implementation TSMtlBuffer {
    TSMtlDevice *_device;
    void *_contents;
    NSUInteger _length;
    NSUInteger _allocated;
    MTLResourceOptions _options;
    MTLPurgeableState _purgeable;
    void (^_deallocator)(void *, NSUInteger);
    BOOL _owned;
    GLuint _gl, _glTex, _glTex4, _glTex2;
    uint64_t _glEpoch;
    uint32_t _storageGen, _texGen, _tex4Gen, _tex2Gen;   // re-specifications of _gl, and the one each texture-buffer view saw
    // Bytes the GL copy lacks (any thread writes, GPU queue reads); _dirtyAll = everything.
    os_unfair_lock _dirtyLock;
    NSRange _dirty[8];
    int _dirtyCount;
    BOOL _dirtyAll, _rangesTracked;
    uint8_t *_uploaded;   // large untracked buffers: snapshot of what GL holds, diffed per execution (GPU queue)
    // TeraScale Compute (GPU queue): an OpenCL kernel wrote the GL buffer and the CPU copy has not caught up;
    // _clBase is what GL held before (shared/managed), so only the bytes the GPU changed are merged back.
    BOOL _glAhead;
    uint8_t *_clBase;
}

// Shared buffers are written by the CPU without notice, so each execution used to re-upload them whole
// (VectorKit: ~70 MB per 5 s while panning). From this size on, the contents are compared with the last
// upload in 4 KB blocks and only changed blocks go to GL; memcmp is far cheaper than the upload.
enum { TSDiffUploadMin = 64 << 10, TSDiffBlock = 4096 };

// Measured (Chrome/Graphite, docs/FINDINGS-RENDERING.md §18): after glBufferData re-specifies a buffer, a
// texture-buffer view attached to it can keep reading the old storage on this driver, so vertex pulling
// draws empty or stale instances. Views are re-attached (glTexBuffer) after every re-specification.
// Knobs for A/B: TSMTL_NO_TBO_REATTACH=1 (old behaviour), TSMTL_NO_ORPHAN=1 (glBufferSubData, never re-specify).
static int gTSNoOrphan, gTSTBOReattach;
__attribute__((constructor)) static void TSBufferKnobsInit(void) {
    gTSNoOrphan = getenv("TSMTL_NO_ORPHAN") != NULL;
    gTSTBOReattach = getenv("TSMTL_NO_TBO_REATTACH") == NULL;
}

+ (void)initialize { if (self == [TSMtlBuffer class]) TSMtlInstallCatchAll(self); }

- (instancetype)initWithDevice:(TSMtlDevice *)device length:(NSUInteger)length options:(MTLResourceOptions)options
                         bytes:(void *)bytes deallocator:(void (^)(void *, NSUInteger))deallocator {
    if (!(self = [super init])) return nil;
    _device = device;
    _length = length;
    _options = options;
    _purgeable = MTLPurgeableStateNonVolatile;
    _dirtyLock = OS_UNFAIR_LOCK_INIT;
    _dirtyAll = YES;
    if (bytes) {
        _contents = bytes;
        _deallocator = [deallocator copy];
        _allocated = length;
    } else {
        _allocated = TSRoundPage(length);
        if (posix_memalign(&_contents, vm_page_size, _allocated)) return nil;
        memset(_contents, 0, _allocated);
        _owned = YES;
        [_device trackAllocation:(int64_t)_allocated];
    }
    return self;
}

- (void)dealloc {
    free(_uploaded);
    free(_clBase);
    GLuint gl = _gl, tex = _glTex, tex4 = _glTex4, tex2 = _glTex2;
    TSMtlDevice *device = _device;
    if (gl || tex || tex4 || tex2) [_device gpuAsync:^{
        if (gTSComputeCLActive) TSMtlComputeForget(device, gl, 0);
        if (tex) glDeleteTextures(1, &tex);
        if (tex4) glDeleteTextures(1, &tex4);
        if (tex2) glDeleteTextures(1, &tex2);
        if (gl) glDeleteBuffers(1, &gl);
    }];
    if (_owned) { free(_contents); [_device trackAllocation:-(int64_t)_allocated]; }
    else if (_deallocator) _deallocator(_contents, _length);
}

// (Re)specifies the storage bound to GL_COPY_WRITE_BUFFER with `length` bytes of `data` (NULL = undefined),
// padded to a multiple of 16: the RGBA32UI / RG32UI views drop a partial last texel, and coalesced loads
// (TSAirTranslator blockWord:at:) read the last words of a buffer through them.
static void TSSpecifyStorage(NSUInteger length, const void *data) {
    NSUInteger padded = MAX((length + 15) & ~(NSUInteger)15, 16);
    if (padded == length) { glBufferData(GL_COPY_WRITE_BUFFER, (GLsizeiptr)length, data, GL_DYNAMIC_DRAW); return; }
    glBufferData(GL_COPY_WRITE_BUFFER, (GLsizeiptr)padded, NULL, GL_DYNAMIC_DRAW);
    if (data && length) glBufferSubData(GL_COPY_WRITE_BUFFER, 0, (GLsizeiptr)length, data);
}

// GPU queue: uploads the blocks of a large untracked buffer that differ from the last upload. The
// snapshot is taken first and GL is fed from it, so a concurrent CPU write is caught next time.
- (void)uploadChangedBlocks {
    NSUInteger changed = 0;
    NSRange runs[64];
    int nruns = 0;
    BOOL many = NO;
    const uint8_t *cur = _contents;
    for (NSUInteger off = 0; off < _length; off += TSDiffBlock) {
        NSUInteger n = MIN((NSUInteger)TSDiffBlock, _length - off);
        if (!memcmp(cur + off, _uploaded + off, n)) continue;
        memcpy(_uploaded + off, cur + off, n);
        changed += n;
        if (nruns && NSMaxRange(runs[nruns - 1]) == off) runs[nruns - 1].length += n;
        else if (nruns < 64) runs[nruns++] = NSMakeRange(off, n);
        else { runs[63].length = off + n - runs[63].location; many = YES; }
    }
    if (!changed) return;
    TSMtlStat(TSStatBufferUploadBytes, changed);
    glBindBuffer(GL_COPY_WRITE_BUFFER, _gl);
    if (gTSNoOrphan && (many || changed * 2 > _length)) {
        glBufferSubData(GL_COPY_WRITE_BUFFER, 0, (GLsizeiptr)_length, _uploaded);
    } else if (many || changed * 2 > _length) {
        _storageGen++;
        if (gTSComputeCLActive) TSMtlComputeForget(_device, _gl, 0);
        TSSpecifyStorage(_length, _uploaded);   // orphan: no wait
    } else {
        for (int i = 0; i < nruns; i++)
            glBufferSubData(GL_COPY_WRITE_BUFFER, (GLintptr)runs[i].location, (GLsizeiptr)runs[i].length, _uploaded + runs[i].location);
    }
    glBindBuffer(GL_COPY_WRITE_BUFFER, 0);
}

- (GLuint)glBuffer {
    uint64_t epoch = _device.executionEpoch;
    MTLStorageMode mode = self.storageMode;
    BOOL untracked = mode == MTLStorageModeShared || (mode == MTLStorageModeManaged && !_rangesTracked);
    BOOL newEpoch = _glEpoch != epoch;
    _glEpoch = epoch;
    // A new execution re-uploads untracked buffers from the CPU copy. With OpenCL writes not merged yet, GL
    // only gets the bytes the CPU changed since the kernel's snapshot (D1); failing that, the GPU's bytes are
    // read back into the CPU copy first (blocking).
    if (_glAhead && newEpoch && untracked) {
        if ([self uploadCPUChangesOverGPU]) {
            os_unfair_lock_lock(&_dirtyLock);
            _dirtyAll = NO;
            _dirtyCount = 0;
            os_unfair_lock_unlock(&_dirtyLock);
            return _gl;
        }
        [self syncFromGL];
    }
    if (untracked && _uploaded && _gl) {
        os_unfair_lock_lock(&_dirtyLock);
        BOOL dirty = _dirtyAll || _dirtyCount;
        _dirtyAll = NO;
        _dirtyCount = 0;
        os_unfair_lock_unlock(&_dirtyLock);
        if (newEpoch || dirty) [self uploadChangedBlocks];
        return _gl;
    }
    if (untracked && newEpoch) [self didWriteCPU];
    os_unfair_lock_lock(&_dirtyLock);
    BOOL all = _dirtyAll || !_gl;
    NSRange ranges[8];
    int count = _dirtyCount;
    memcpy(ranges, _dirty, sizeof ranges);
    _dirtyAll = NO;
    _dirtyCount = 0;
    os_unfair_lock_unlock(&_dirtyLock);
    NSUInteger bytes = 0;
    for (int i = 0; i < count; i++) bytes += ranges[i].length;
    BOOL fresh = !_gl;
    if (!_gl) glGenBuffers(1, &_gl);
    if (!all && !count) return _gl;
    glBindBuffer(GL_COPY_WRITE_BUFFER, _gl);
    TSMtlStat(TSStatBufferUploadBytes, all || bytes * 2 > _length ? _length : bytes);
    if (untracked && _length >= TSDiffUploadMin && !_uploaded && (_uploaded = malloc(_length))) {
        // First upload of a large untracked buffer: from now on only changed blocks are sent.
        memcpy(_uploaded, _contents, _length);
        _storageGen++;
        if (gTSComputeCLActive) TSMtlComputeForget(_device, _gl, 0);
        TSSpecifyStorage(_length, _uploaded);
    } else if (gTSNoOrphan && !fresh && (all || bytes * 2 > _length)) {
        glBufferSubData(GL_COPY_WRITE_BUFFER, 0, (GLsizeiptr)MAX(_length, 4), _contents);
    } else if (all || bytes * 2 > _length) {
        // Re-specify: draws still in flight keep the old storage, nothing waits.
        _storageGen++;
        if (gTSComputeCLActive) TSMtlComputeForget(_device, _gl, 0);
        TSSpecifyStorage(_length, _length ? _contents : NULL);
    } else {
        for (int i = 0; i < count; i++)
            glBufferSubData(GL_COPY_WRITE_BUFFER, (GLintptr)ranges[i].location, (GLsizeiptr)ranges[i].length, (uint8_t *)_contents + ranges[i].location);
    }
    glBindBuffer(GL_COPY_WRITE_BUFFER, 0);
    return _gl;
}

- (uint32_t)glStorageGeneration { return _storageGen; }

// A texture-buffer view of the GL storage in `format`, re-attached after re-specification when TSMTL_TBO_REATTACH asks.
static GLuint TSTextureBufferView(GLuint buffer, GLenum format, GLuint *tex, uint32_t *gen, uint32_t storageGen) {
    if (!*tex || (gTSTBOReattach && *gen != storageGen)) {
        if (!*tex) glGenTextures(1, tex);
        *gen = storageGen;
        glBindTexture(GL_TEXTURE_BUFFER, *tex);
        glTexBuffer(GL_TEXTURE_BUFFER, format, buffer);
        glBindTexture(GL_TEXTURE_BUFFER, 0);
    }
    return *tex;
}

- (GLuint)glTextureBuffer { GLuint b = self.glBuffer; return TSTextureBufferView(b, GL_R32UI, &_glTex, &_texGen, _storageGen); }
- (GLuint)glTextureBuffer4 { GLuint b = self.glBuffer; return TSTextureBufferView(b, GL_RGBA32UI, &_glTex4, &_tex4Gen, _storageGen); }
- (GLuint)glTextureBuffer2 { GLuint b = self.glBuffer; return TSTextureBufferView(b, GL_RG32UI, &_glTex2, &_tex2Gen, _storageGen); }

- (void)didWriteCPU {
    os_unfair_lock_lock(&_dirtyLock);
    _dirtyAll = YES;
    _dirtyCount = 0;
    os_unfair_lock_unlock(&_dirtyLock);
}

// Records a written byte range; overlapping or adjacent ranges merge, overflow means "all".
- (void)didWriteRange:(NSRange)range {
    if (NSMaxRange(range) > _length) range.length = range.location < _length ? _length - range.location : 0;
    if (!range.length) return;
    os_unfair_lock_lock(&_dirtyLock);
    if (!_dirtyAll) {
        int i = 0;
        for (; i < _dirtyCount; i++) {
            NSRange d = _dirty[i];
            if (range.location > NSMaxRange(d) || d.location > NSMaxRange(range)) continue;
            NSUInteger lo = MIN(d.location, range.location), hi = MAX(NSMaxRange(d), NSMaxRange(range));
            _dirty[i] = NSMakeRange(lo, hi - lo);
            break;
        }
        if (i == _dirtyCount) {
            if (_dirtyCount < 8) _dirty[_dirtyCount++] = range;
            else { _dirtyAll = YES; _dirtyCount = 0; }
        }
    }
    os_unfair_lock_unlock(&_dirtyLock);
}

// D1, GPU queue: GL holds the GPU's writes and _clBase what GL held before them, so a byte where the CPU copy
// differs from _clBase was written by the CPU since: send exactly those bytes, leaving the GPU's alone (Metal
// leaves bytes both sides wrote undefined). The base takes the sent values, so the merge at completion keeps
// later CPU writes. NO (nothing sent) when there is no base or the changes are too scattered.
- (BOOL)uploadCPUChangesOverGPU {
    if (!_clBase || !_gl) return NO;
    enum { TSMaxRuns = 64 };
    NSRange runs[TSMaxRuns];
    int nruns = 0;
    const uint8_t *cpu = _contents;
    for (NSUInteger off = 0; off < _length; off += TSDiffBlock) {
        NSUInteger n = MIN((NSUInteger)TSDiffBlock, _length - off);
        if (!memcmp(cpu + off, _clBase + off, n)) continue;
        for (NSUInteger i = off; i < off + n; i++) {
            if (cpu[i] == _clBase[i]) continue;
            NSUInteger j = i + 1;
            while (j < off + n && cpu[j] != _clBase[j]) j++;
            // Runs stay exact (only touching runs merge): the bytes between two runs may hold GPU writes.
            if (nruns && NSMaxRange(runs[nruns - 1]) == i) runs[nruns - 1].length = j - runs[nruns - 1].location;
            else if (nruns < TSMaxRuns) runs[nruns++] = NSMakeRange(i, j - i);
            else return NO;
            i = j - 1;
        }
    }
    if (!nruns) return YES;
    glBindBuffer(GL_COPY_WRITE_BUFFER, _gl);
    NSUInteger bytes = 0;
    for (int r = 0; r < nruns; r++) {
        glBufferSubData(GL_COPY_WRITE_BUFFER, (GLintptr)runs[r].location, (GLsizeiptr)runs[r].length, cpu + runs[r].location);
        memcpy(_clBase + runs[r].location, cpu + runs[r].location, runs[r].length);
        if (_uploaded) memcpy(_uploaded + runs[r].location, cpu + runs[r].location, runs[r].length);
        bytes += runs[r].length;
    }
    glBindBuffer(GL_COPY_WRITE_BUFFER, 0);
    TSMtlStat(TSStatBufferUploadBytes, bytes);
    return YES;
}

// GPU queue: bytes as the GPU sees them at this point of the command stream (D2): from GL when an OpenCL
// kernel wrote the buffer and the CPU copy has not caught up (after submitting the open CL run, which may hold
// that write), else from the CPU copy. Reads only `range`, not the whole buffer.
- (void)getGPUBytes:(void *)dst range:(NSRange)range {
    if (NSMaxRange(range) > _length) { memset(dst, 0, range.length); return; }
    if (_glAhead && _gl) {
        TSMtlComputeEndRun();
        glBindBuffer(GL_COPY_READ_BUFFER, _gl);
        glGetBufferSubData(GL_COPY_READ_BUFFER, (GLintptr)range.location, (GLsizeiptr)range.length, dst);
        glBindBuffer(GL_COPY_READ_BUFFER, 0);
        TSMtlStat(TSStatReadbacks, 1);
        return;
    }
    memcpy(dst, (const uint8_t *)_contents + range.location, range.length);
}

- (BOOL)gpuAhead { return _glAhead; }

// TeraScale Compute: GL may hold newer bytes than the CPU copy after an OpenCL write.
- (void)prepareGPUWrite {
    if (_glAhead) return;   // the snapshot of the first write in flight stays the base
    MTLStorageMode mode = self.storageMode;
    if (mode == MTLStorageModePrivate || mode == MTLStorageModeMemoryless || !_length) return;
    if (!_clBase) _clBase = malloc(_length);
    if (_clBase) memcpy(_clBase, _uploaded ?: (uint8_t *)_contents, _length);   // what GL holds right after glBuffer
}

- (void)didWriteGPU {
    if (_glAhead) return;
    _glAhead = YES;
    MTLStorageMode mode = self.storageMode;
    if (mode == MTLStorageModePrivate || mode == MTLStorageModeMemoryless) return;   // merged only when the CPU copy is needed
    TSMtlBuffer *buffer = self;   // kept alive until the merge; the device does not hold the block afterwards
    [_device addPostFlushWork:^{ [buffer syncFromGL]; }];   // runs once the GPU has executed the command buffer
}

- (void)syncFromGL {
    if (!_glAhead) return;
    _glAhead = NO;
    TSMtlComputeJoin();
    uint8_t *gpu = _gl && _length ? malloc(_length) : NULL;
    if (!gpu) { free(_clBase); _clBase = NULL; return; }
    glBindBuffer(GL_COPY_READ_BUFFER, _gl);
    glGetBufferSubData(GL_COPY_READ_BUFFER, 0, (GLsizeiptr)_length, gpu);
    glBindBuffer(GL_COPY_READ_BUFFER, 0);
    TSMtlStat(TSStatReadbacks, 1);
    uint8_t *cpu = _contents;
    if (_clBase) {
        // Three-way merge: bytes the GPU changed win, the rest keeps what the CPU may have written meanwhile.
        NSUInteger words = _length / 8;
        const uint64_t *g = (const uint64_t *)gpu, *b = (const uint64_t *)_clBase;
        for (NSUInteger w = 0; w < words; w++) {
            if (g[w] == b[w]) continue;
            for (NSUInteger i = w * 8; i < w * 8 + 8; i++) if (gpu[i] != _clBase[i]) cpu[i] = gpu[i];
        }
        for (NSUInteger i = words * 8; i < _length; i++) if (gpu[i] != _clBase[i]) cpu[i] = gpu[i];
        free(_clBase);
        _clBase = NULL;
    } else {
        memcpy(cpu, gpu, _length);
    }
    if (_uploaded) memcpy(_uploaded, gpu, _length);   // the snapshot is what GL holds
    free(gpu);
}

- (id<MTLDevice>)device { return _device; }
// On the GPU queue (blits, constant buffers, indirect arguments) the CPU copy must include OpenCL writes.
- (void *)contents {
    if (_glAhead && [_device isOnGPUQueue]) [self syncFromGL];
    return _contents;
}
- (NSUInteger)length { return _length; }
- (NSUInteger)allocatedSize { return _allocated; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (_options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift; }
- (MTLCPUCacheMode)cpuCacheMode { return (_options & MTLResourceCPUCacheModeMask) >> MTLResourceCPUCacheModeShift; }
- (MTLHazardTrackingMode)hazardTrackingMode { return (_options & MTLResourceHazardTrackingModeMask) >> MTLResourceHazardTrackingModeShift; }
- (uint64_t)gpuAddress { return (uint64_t)_contents; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){ (uint64_t)(__bridge void *)self }; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable {}
- (void)didModifyRange:(NSRange)range { _rangesTracked = YES; [self didWriteRange:range]; }
- (void)addDebugMarker:(NSString *)marker range:(NSRange)range {}
- (void)removeAllDebugMarkers {}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
    MTLPurgeableState old = _purgeable;
    if (state != MTLPurgeableStateKeepCurrent) _purgeable = state;
    return old;
}

- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow {
    return [[TSMtlTexture alloc] initWithDevice:_device descriptor:desc buffer:self offset:offset bytesPerRow:bytesPerRow];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<TSMtlBuffer %p length=%lu label=%@>", self, (unsigned long)_length, self.label];
}
@end

#pragma mark - Texture

static GLenum TSGLTarget(MTLTextureType t) {
    switch (t) {
    case MTLTextureType1D:                 return GL_TEXTURE_1D;
    case MTLTextureType1DArray:            return GL_TEXTURE_1D_ARRAY;
    case MTLTextureType2DArray:            return GL_TEXTURE_2D_ARRAY;
    case MTLTextureType2DMultisample:      return GL_TEXTURE_2D_MULTISAMPLE;
    case MTLTextureType2DMultisampleArray: return GL_TEXTURE_2D_MULTISAMPLE_ARRAY;
    case MTLTextureTypeCube:               return GL_TEXTURE_CUBE_MAP;
    case MTLTextureTypeCubeArray:          return GL_TEXTURE_CUBE_MAP_ARRAY;
    case MTLTextureType3D:                 return GL_TEXTURE_3D;
    case MTLTextureTypeTextureBuffer:      return GL_TEXTURE_BUFFER;
    default:                               return GL_TEXTURE_2D;
    }
}

static GLint TSGLSwizzle(MTLTextureSwizzle s) {
    static const GLint map[] = { GL_ZERO, GL_ONE, GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA };
    return s < 6 ? map[s] : GL_ZERO;
}

@implementation TSMtlTexture {
    TSMtlDevice *_device;
    MTLTextureDescriptor *_desc;
    TSPixelFormatInfo _pf;
    TSGLFormat _glFormat;
    // Storage: exactly one of _memory, _surface, _buffer owns the bytes; a view uses _parent's.
    void *_memory;
    NSUInteger _memorySize;
    IOSurfaceRef _surface;
    NSUInteger _plane;
    TSMtlBuffer *_buffer;
    NSUInteger _bufferOffset, _bufferRowPitch;
    TSMtlTexture *_parent;          // always the root (views of views are flattened)
    NSUInteger _parentLevel, _parentSlice;
    NSUInteger _levelOffset[16], _sliceSize;
    MTLPurgeableState _purgeable;
    // GL mirror of this object (GPU queue only).
    GLuint _glTex, _glRect;
    GLenum _glTarget;
    uint64_t _glGen, _glEpoch, _glSurfaceSerial;
    uint32_t _tboGen;   // GL_TEXTURE_BUFFER mirror: storage generation of the buffer it is attached to
    uint32_t _glRectSeed;           // IOSurface seed when _glRect was (re)bound to the surface
    uint64_t _glRectEpoch;          // execution epoch of the last rebind (TSMTL_REBIND_ALWAYS)
    BOOL _rectFailed, _glValid;     // _glValid: the mirror holds the CPU contents of generation _glGen
    BOOL _aliasRender, _aliasSample; // view that renders into / samples the root's GL texture
    // Root-only coherency state, guarded by the root's unfair lock (B9).
    os_unfair_lock _lock;
    uint64_t _cpuGen, _fullGen;     // _fullGen: last generation that changed more than the listed regions
    struct { uint64_t gen; uint32_t level, slice; MTLRegion region; } _regions[16];
    int _regionCount;
    TSMtlTexture *_gpuOwner;
    BOOL _surfaceWritePending;
    BOOL _surfaceGLWritten;         // root: our GL rendered or blitted into the surface at least once
    uint32_t _uploadSeed;           // TSMTL_SURFACE_UPLOAD: surface seed of the last CPU upload (0 = none)
}

// Bumped on every GL write to any IOSurface (GPU queue only). Several Metal textures can wrap one
// surface, so a sampling copy refreshes when any surface was written since it was made.
static uint64_t gSurfaceWrites;

+ (void)initialize { if (self == [TSMtlTexture class]) TSMtlInstallCatchAll(self); }

- (instancetype)initCommonWithDevice:(TSMtlDevice *)device descriptor:(MTLTextureDescriptor *)desc {
    if (!(self = [super init])) return nil;
    _device = device;
    _desc = [desc copy];
    _desc.mipmapLevelCount = MIN(MAX(_desc.mipmapLevelCount, 1), 16);
    _pf = TSPixelFormatGetInfo(_desc.pixelFormat);
    _glFormat = TSGLFormatFor(_desc.pixelFormat);
    _purgeable = MTLPurgeableStateNonVolatile;
    _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (instancetype)initWithDevice:(TSMtlDevice *)device descriptor:(MTLTextureDescriptor *)desc iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane {
    if (!(self = [self initCommonWithDevice:device descriptor:desc])) return nil;
    if (surface) {
        _surface = (IOSurfaceRef)CFRetain(surface);
        _plane = plane;
        _desc.mipmapLevelCount = 1;
        return self;
    }
    // Tightly packed: slice-major, each slice holds all its mip levels.
    NSUInteger w = _desc.width, h = _desc.height, d = _desc.depth, off = 0;
    for (NSUInteger l = 0; l < _desc.mipmapLevelCount; l++) {
        _levelOffset[l] = off;
        off += [self rowPitchForWidth:w] * ((h + _pf.blockHeight - 1) / _pf.blockHeight) * d * _desc.sampleCount;
        w = MAX(w / 2, 1); h = MAX(h / 2, 1); d = MAX(d / 2, 1);
    }
    _sliceSize = off;
    _memorySize = TSRoundPage(_sliceSize * [self sliceCount]);
    if (posix_memalign(&_memory, vm_page_size, _memorySize)) return nil;
    memset(_memory, 0, _memorySize);
    [_device trackAllocation:(int64_t)_memorySize];
    return self;
}

- (instancetype)initWithDevice:(TSMtlDevice *)device descriptor:(MTLTextureDescriptor *)desc
                        buffer:(TSMtlBuffer *)buffer offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow {
    if (!(self = [self initCommonWithDevice:device descriptor:desc])) return nil;
    _desc.mipmapLevelCount = 1;
    _buffer = buffer;
    _bufferOffset = offset;
    _bufferRowPitch = bytesPerRow;
    return self;
}

- (instancetype)initViewOf:(TSMtlTexture *)parent pixelFormat:(MTLPixelFormat)format type:(MTLTextureType)type
                    levels:(NSRange)levels slices:(NSRange)slices swizzle:(MTLTextureSwizzleChannels)swizzle {
    if (parent->_parent) {
        levels.location += parent->_parentLevel;
        slices.location += parent->_parentSlice;
        parent = parent->_parent;
    }
    MTLTextureDescriptor *desc = [parent->_desc copy];
    desc.pixelFormat = format;
    desc.textureType = type;
    desc.mipmapLevelCount = MAX(levels.length, 1);
    desc.swizzle = swizzle;
    NSUInteger shift = levels.location;
    desc.width = MAX(desc.width >> shift, 1);
    desc.height = MAX(desc.height >> shift, 1);
    if (type == MTLTextureType3D) desc.depth = MAX(desc.depth >> shift, 1);
    BOOL cube = type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray;
    desc.arrayLength = MAX(slices.length / (cube ? 6 : 1), 1);
    if (!(self = [self initCommonWithDevice:parent->_device descriptor:desc])) return nil;
    _parent = parent;
    _parentLevel = levels.location;
    _parentSlice = slices.location;
    // Same GL format: render straight into the root's texture. Same target, swizzle and full
    // ranges: sample it too. Everything else keeps a mirror of its own (B7).
    MTLTextureSwizzleChannels ps = parent->_desc.swizzle;
    TSGLFormat pf = parent->_glFormat;
    _aliasRender = !parent->_surface && !parent->_buffer && _glFormat.supported && _glFormat.internalFormat == pf.internalFormat &&
                   _glFormat.format == pf.format && _glFormat.type == pf.type && parent->_desc.sampleCount == _desc.sampleCount;
    _aliasSample = _aliasRender && TSGLTarget(type) == TSGLTarget(parent->_desc.textureType) && levels.location == 0 &&
                   _desc.mipmapLevelCount == parent->_desc.mipmapLevelCount && slices.location == 0 &&
                   slices.length == [parent sliceCount] && !memcmp(&ps, &swizzle, sizeof ps);
    return self;
}

- (void)dealloc {
    GLuint tex = _glTex, rect = _glRect;
    GLenum target = _glTarget;
    TSMtlDevice *device = _device;
    if (tex || rect) [_device gpuAsync:^{
        if (gTSComputeCLActive) { TSMtlComputeForget(device, tex, target); TSMtlComputeForget(device, rect, GL_TEXTURE_RECTANGLE); }
        TSMtlForgetFramebufferTexture(device, tex);
        TSMtlForgetFramebufferTexture(device, rect);
        if (tex) glDeleteTextures(1, &tex);
        if (rect) glDeleteTextures(1, &rect);
    }];
    if (_memory) { free(_memory); [_device trackAllocation:-(int64_t)_memorySize]; }
    if (_surface) CFRelease(_surface);
}

- (TSMtlTexture *)root { return _parent ? _parent : self; }
- (IOSurfaceRef)rootSurface { return self.root->_surface; }

- (NSUInteger)rowPitchForWidth:(NSUInteger)w { return ((w + _pf.blockWidth - 1) / _pf.blockWidth) * _pf.bytesPerBlock; }

- (NSUInteger)sliceCount {
    MTLTextureType t = _desc.textureType;
    return _desc.arrayLength * (t == MTLTextureTypeCube || t == MTLTextureTypeCubeArray ? 6 : 1);
}

- (uint8_t *)addressForLevel:(NSUInteger)level slice:(NSUInteger)slice rowPitch:(NSUInteger *)rowPitch imagePitch:(NSUInteger *)imagePitch {
    if (_parent) return [_parent addressForLevel:level + _parentLevel slice:slice + _parentSlice rowPitch:rowPitch imagePitch:imagePitch];
    NSUInteger w = MAX(_desc.width >> level, 1), h = MAX(_desc.height >> level, 1);
    NSUInteger rows = (h + _pf.blockHeight - 1) / _pf.blockHeight;
    if (_surface) {
        *rowPitch = IOSurfaceGetBytesPerRowOfPlane(_surface, _plane);
        *imagePitch = *rowPitch * rows;
        return IOSurfaceGetBaseAddressOfPlane(_surface, _plane);
    }
    if (_buffer) {
        *rowPitch = _bufferRowPitch;
        *imagePitch = _bufferRowPitch * rows;
        return (uint8_t *)_buffer.contents + _bufferOffset;
    }
    if (level >= _desc.mipmapLevelCount || slice >= [self sliceCount]) return NULL;
    *rowPitch = [self rowPitchForWidth:w];
    *imagePitch = *rowPitch * rows;
    return (uint8_t *)_memory + slice * _sliceSize + _levelOffset[level];
}

- (void)beginAccess {
    if (_parent) [_parent beginAccess];
    else if (_surface) IOSurfaceLock(_surface, 0, NULL);
}

- (void)endAccess {
    if (_parent) [_parent endAccess];
    else if (_surface) IOSurfaceUnlock(_surface, 0, NULL);
}

#define TS_LOCK(t) os_unfair_lock_lock(&(t)->_lock)
#define TS_UNLOCK(t) os_unfair_lock_unlock(&(t)->_lock)

#pragma mark CPU side coherency

- (void)syncForCPURead {
    TSMtlTexture *root = self.root;
    BOOL needed;
    TS_LOCK(root);
    needed = root->_gpuOwner != nil || root->_surfaceWritePending;
    TS_UNLOCK(root);
    if (needed) [_device gpuSync:^{ [root readbackOwner]; }];
}

- (void)didWriteCPU {
    TSMtlTexture *root = self.root;
    TS_LOCK(root);
    root->_fullGen = ++root->_cpuGen;
    root->_regionCount = 0;
    TS_UNLOCK(root);
}

// A CPU write limited to one region of (level, slice), in this texture's coordinates.
- (void)didWriteRegion:(MTLRegion)region level:(NSUInteger)level slice:(NSUInteger)slice {
    TSMtlTexture *root = self.root;
    BOOL sameBlocks = _pf.blockWidth == root->_pf.blockWidth && _pf.bytesPerBlock == root->_pf.bytesPerBlock;
    TS_LOCK(root);
    root->_cpuGen++;
    if (!sameBlocks || root->_regionCount == 16) {
        root->_fullGen = root->_cpuGen;
        root->_regionCount = 0;
    } else {
        __typeof__(root->_regions[0]) *r = &root->_regions[root->_regionCount++];
        r->gen = root->_cpuGen;
        r->level = (uint32_t)(level + _parentLevel);
        r->slice = (uint32_t)(slice + _parentSlice);
        r->region = region;
    }
    TS_UNLOCK(root);
}

// GPU queue, root only: bring the CPU copy up to date with the GPU owner.
- (void)readbackOwner {
    TSMtlTexture *owner;
    BOOL surfacePending;
    TS_LOCK(self);
    owner = _gpuOwner;
    surfacePending = _surfaceWritePending;
    _gpuOwner = nil;
    _surfaceWritePending = NO;
    TS_UNLOCK(self);
    TSMtlComputeJoin();   // an OpenCL run may have written the texture (B4: its release may still be in flight)
    if (surfacePending) glFinish();
    if (!owner) return;
    if (gTSMtlTraceOn) {
        NSArray<NSString *> *stack = [NSThread callStackSymbols];
        NSMutableArray *callers = [NSMutableArray array];
        for (NSUInteger i = 2; i < MIN(stack.count, 9); i++) {
            NSString *f = [stack[i] substringFromIndex:MIN((NSUInteger)59, stack[i].length)];
            [callers addObject:[f componentsSeparatedByString:@" + "].firstObject];
        }
        TSMtlTraceOnce(@"readback %@ via %@", owner, [callers componentsJoinedByString:@" < "]);
    }
    [owner readbackGL];
    TS_LOCK(self);
    _fullGen = ++_cpuGen;
    _regionCount = 0;
    owner->_glGen = _cpuGen;
    owner->_glValid = YES;
    TS_UNLOCK(self);
}

#pragma mark GL mirror (GPU queue)

- (void)createGLTexture {
    _glTarget = TSGLTarget(_desc.textureType);
    glGenTextures(1, &_glTex);
    glBindTexture(_glTarget, _glTex);
    TSGLFormat f = _glFormat;
    NSUInteger slices = [self sliceCount];
    if (_glTarget == GL_TEXTURE_BUFFER) {
        TSMtlBuffer *buffer = self.root->_buffer;
        if (buffer) { glTexBuffer(GL_TEXTURE_BUFFER, f.internalFormat, buffer.glBuffer); _tboGen = buffer.glStorageGeneration; }
        glBindTexture(_glTarget, 0);
        return;
    }
    if (_glTarget == GL_TEXTURE_2D_MULTISAMPLE) {
        glTexImage2DMultisample(_glTarget, (GLsizei)_desc.sampleCount, f.internalFormat, (GLsizei)_desc.width, (GLsizei)_desc.height, GL_TRUE);
    } else if (_glTarget == GL_TEXTURE_2D_MULTISAMPLE_ARRAY) {
        glTexImage3DMultisample(_glTarget, (GLsizei)_desc.sampleCount, f.internalFormat, (GLsizei)_desc.width, (GLsizei)_desc.height,
                                (GLsizei)slices, GL_TRUE);
    } else {
        for (GLint l = 0; l < (GLint)_desc.mipmapLevelCount; l++) {
            GLsizei w = (GLsizei)MAX(_desc.width >> l, 1), h = (GLsizei)MAX(_desc.height >> l, 1), d = (GLsizei)MAX(_desc.depth >> l, 1);
            GLsizei blocks = (GLsizei)(((w + _pf.blockWidth - 1) / _pf.blockWidth) * ((h + _pf.blockHeight - 1) / _pf.blockHeight) * _pf.bytesPerBlock);
            switch (_glTarget) {
            case GL_TEXTURE_1D:
                glTexImage1D(_glTarget, l, f.internalFormat, w, 0, f.format, f.type, NULL); break;
            case GL_TEXTURE_1D_ARRAY:
                glTexImage2D(_glTarget, l, f.internalFormat, w, (GLsizei)slices, 0, f.format, f.type, NULL); break;
            case GL_TEXTURE_CUBE_MAP:
                for (GLenum face = 0; face < 6; face++) {
                    if (f.compressed) glCompressedTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + face, l, f.internalFormat, w, h, 0, blocks, NULL);
                    else glTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + face, l, f.internalFormat, w, h, 0, f.format, f.type, NULL);
                }
                break;
            case GL_TEXTURE_2D_ARRAY: case GL_TEXTURE_CUBE_MAP_ARRAY:
                if (f.compressed) glCompressedTexImage3D(_glTarget, l, f.internalFormat, w, h, (GLsizei)slices, 0, blocks * (GLsizei)slices, NULL);
                else glTexImage3D(_glTarget, l, f.internalFormat, w, h, (GLsizei)slices, 0, f.format, f.type, NULL);
                break;
            case GL_TEXTURE_3D:
                glTexImage3D(_glTarget, l, f.internalFormat, w, h, d, 0, f.format, f.type, NULL); break;
            default:
                if (f.compressed) glCompressedTexImage2D(_glTarget, l, f.internalFormat, w, h, 0, blocks, NULL);
                else glTexImage2D(_glTarget, l, f.internalFormat, w, h, 0, f.format, f.type, NULL);
            }
        }
        glTexParameteri(_glTarget, GL_TEXTURE_BASE_LEVEL, 0);
        glTexParameteri(_glTarget, GL_TEXTURE_MAX_LEVEL, (GLint)_desc.mipmapLevelCount - 1);
        glTexParameteri(_glTarget, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(_glTarget, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }
    if (_glTarget != GL_TEXTURE_2D_MULTISAMPLE && _glTarget != GL_TEXTURE_2D_MULTISAMPLE_ARRAY) [self applySwizzle:_glTarget];
    glBindTexture(_glTarget, 0);
    if (glGetError() != GL_NO_ERROR) TSMtlError(@"GL error creating %@", self);
}

// Texture swizzle of the descriptor (A8 reads as alpha) on the texture bound to `target`.
- (void)applySwizzle:(GLenum)target {
    MTLTextureSwizzleChannels s = _desc.swizzle;
    GLint swizzle[4] = { TSGLSwizzle(s.red), TSGLSwizzle(s.green), TSGLSwizzle(s.blue), TSGLSwizzle(s.alpha) };
    if (_desc.pixelFormat == MTLPixelFormatA8Unorm) { swizzle[0] = swizzle[1] = swizzle[2] = GL_ZERO; swizzle[3] = GL_RED; }
    glTexParameteriv(target, GL_TEXTURE_SWIZZLE_RGBA, swizzle);
}

- (BOOL)canTransferPixels {
    return _glFormat.supported && _glTarget != GL_TEXTURE_2D_MULTISAMPLE && _glTarget != GL_TEXTURE_2D_MULTISAMPLE_ARRAY
        && _glTarget != GL_TEXTURE_BUFFER;
}

// CPU copy -> GL mirror.
- (void)uploadGL {
    if (_glTarget == GL_TEXTURE_BUFFER) {
        // The view reads the buffer's GL copy: bring it up to date, and re-attach if its storage changed.
        TSMtlBuffer *buffer = self.root->_buffer;
        GLuint gl = buffer.glBuffer;
        if (gl && gTSTBOReattach && _tboGen != buffer.glStorageGeneration) {
            _tboGen = buffer.glStorageGeneration;
            glBindTexture(GL_TEXTURE_BUFFER, _glTex);
            glTexBuffer(GL_TEXTURE_BUFFER, _glFormat.internalFormat, gl);
            glBindTexture(GL_TEXTURE_BUFFER, 0);
        }
        return;
    }
    if (![self canTransferPixels]) return;
    TSMtlStat(TSStatTextureUploadBytes, _sliceSize * [self sliceCount] ?: _desc.width * _desc.height * _pf.bytesPerBlock);
    TSGLFormat f = _glFormat;
    glBindTexture(_glTarget, _glTex);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    [self beginAccess];
    NSUInteger slices = _glTarget == GL_TEXTURE_3D ? 1 : [self sliceCount];
    for (GLint l = 0; l < (GLint)_desc.mipmapLevelCount; l++) {
        GLsizei w = (GLsizei)MAX(_desc.width >> l, 1), h = (GLsizei)MAX(_desc.height >> l, 1), d = (GLsizei)MAX(_desc.depth >> l, 1);
        for (GLint s = 0; s < (GLint)slices; s++) {
            NSUInteger rowPitch, imagePitch;
            uint8_t *p = [self addressForLevel:l slice:s rowPitch:&rowPitch imagePitch:&imagePitch];
            if (!p) continue;
            glPixelStorei(GL_UNPACK_ROW_LENGTH, f.compressed ? 0 : (GLint)(rowPitch / _pf.bytesPerBlock));
            glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, f.compressed ? 0 : (GLint)(imagePitch / rowPitch));
            GLsizei bytes = (GLsizei)imagePitch;
            switch (_glTarget) {
            case GL_TEXTURE_1D:
                glTexSubImage1D(_glTarget, l, 0, w, f.format, f.type, p); break;
            case GL_TEXTURE_1D_ARRAY:
                glTexSubImage2D(_glTarget, l, 0, s, w, 1, f.format, f.type, p); break;
            case GL_TEXTURE_CUBE_MAP:
                if (f.compressed) glCompressedTexSubImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + s, l, 0, 0, w, h, f.internalFormat, bytes, p);
                else glTexSubImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + s, l, 0, 0, w, h, f.format, f.type, p);
                break;
            case GL_TEXTURE_2D_ARRAY: case GL_TEXTURE_CUBE_MAP_ARRAY:
                if (f.compressed) glCompressedTexSubImage3D(_glTarget, l, 0, 0, s, w, h, 1, f.internalFormat, bytes, p);
                else glTexSubImage3D(_glTarget, l, 0, 0, s, w, h, 1, f.format, f.type, p);
                break;
            case GL_TEXTURE_3D:
                glTexSubImage3D(_glTarget, l, 0, 0, 0, w, h, d, f.format, f.type, p); break;
            default:
                if (f.compressed) glCompressedTexSubImage2D(_glTarget, l, 0, 0, w, h, f.internalFormat, bytes, p);
                else glTexSubImage2D(_glTarget, l, 0, 0, w, h, f.format, f.type, p);
            }
        }
    }
    [self endAccess];
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, 0);
    glBindTexture(_glTarget, 0);
}

// CPU copy -> GL mirror for one region of (level, slice); root mirrors of uncompressed 1D/2D/3D/array/cube textures.
- (void)uploadRegion:(MTLRegion)r level:(GLint)l slice:(GLint)s {
    NSUInteger rowPitch, imagePitch;
    [self beginAccess];
    uint8_t *p = [self addressForLevel:l slice:s rowPitch:&rowPitch imagePitch:&imagePitch];
    if (p) [self glWriteRegion:r level:l slice:s bytes:p + r.origin.z * imagePitch + r.origin.y * rowPitch + r.origin.x * _pf.bytesPerBlock
                      rowPitch:rowPitch imagePitch:imagePitch];
    [self endAccess];
}

// Client bytes (first texel of the region) -> GL mirror, for one region of (level, slice).
- (void)glWriteRegion:(MTLRegion)r level:(GLint)l slice:(GLint)s bytes:(const uint8_t *)p rowPitch:(NSUInteger)rowPitch
           imagePitch:(NSUInteger)imagePitch {
    TSGLFormat f = _glFormat;
    TSMtlStat(TSStatTextureUploadBytes, r.size.width * r.size.height * r.size.depth * _pf.bytesPerBlock);
    {
        glBindTexture(_glTarget, _glTex);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(rowPitch / _pf.bytesPerBlock));
        glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, rowPitch ? (GLint)(imagePitch / rowPitch) : 0);
        GLint x = (GLint)r.origin.x, y = (GLint)r.origin.y, z = (GLint)r.origin.z;
        GLsizei w = (GLsizei)r.size.width, h = (GLsizei)r.size.height, d = (GLsizei)r.size.depth;
        switch (_glTarget) {
        case GL_TEXTURE_1D: glTexSubImage1D(_glTarget, l, x, w, f.format, f.type, p); break;
        case GL_TEXTURE_1D_ARRAY: glTexSubImage2D(_glTarget, l, x, s, w, 1, f.format, f.type, p); break;
        case GL_TEXTURE_CUBE_MAP: glTexSubImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + s, l, x, y, w, h, f.format, f.type, p); break;
        case GL_TEXTURE_2D_ARRAY: case GL_TEXTURE_CUBE_MAP_ARRAY: glTexSubImage3D(_glTarget, l, x, y, s, w, h, 1, f.format, f.type, p); break;
        case GL_TEXTURE_3D: glTexSubImage3D(_glTarget, l, x, y, z, w, h, d, f.format, f.type, p); break;
        default: glTexSubImage2D(_glTarget, l, x, y, w, h, f.format, f.type, p);
        }
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, 0);
        glBindTexture(_glTarget, 0);
    }
}

// replaceRegion on a texture whose newest contents are in its own GL mirror (rendered, then patched by
// the CPU: VectorKit's 256x256 tiles): write the region straight into GL. The old path read the whole
// texture back to patch the CPU copy. NO when the CPU copy must take the write.
- (BOOL)glReplaceRegion:(MTLRegion)region level:(NSUInteger)level slice:(NSUInteger)slice bytes:(const uint8_t *)bytes
               rowPitch:(NSUInteger)rowPitch imagePitch:(NSUInteger)imagePitch {
    if (_parent || _surface || _buffer || _glFormat.compressed || !_glFormat.supported || _desc.sampleCount > 1) return NO;
    TS_LOCK(self);
    BOOL gpuNewer = _gpuOwner == self;
    TS_UNLOCK(self);
    if (!gpuNewer) return NO;
    __block BOOL done = NO;
    [_device gpuSync:^{
        TS_LOCK(self);
        BOOL still = self->_gpuOwner == self;
        TS_UNLOCK(self);
        if (!still || !self->_glTex || ![self canTransferPixels]) return;
        [self glWriteRegion:region level:(GLint)level slice:(GLint)slice bytes:bytes rowPitch:rowPitch
                 imagePitch:imagePitch ? imagePitch : rowPitch * region.size.height];
        done = YES;
    }];
    return done;
}

// GL mirror -> CPU copy.
- (void)readbackGL {
    if (!_glTex || ![self canTransferPixels] || _glFormat.compressed) return;
    TSMtlStat(TSStatReadbacks, 1);
    TSGLFormat f = _glFormat;
    glBindTexture(_glTarget, _glTex);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    [self beginAccess];
    BOOL layered = _glTarget == GL_TEXTURE_1D_ARRAY || _glTarget == GL_TEXTURE_2D_ARRAY || _glTarget == GL_TEXTURE_CUBE_MAP_ARRAY;
    NSUInteger slices = [self sliceCount];
    for (GLint l = 0; l < (GLint)_desc.mipmapLevelCount; l++) {
        NSUInteger rowPitch, imagePitch;
        if (layered) {
            // GL returns all layers of a level at once; scatter them into the slice-major layout.
            [self addressForLevel:l slice:0 rowPitch:&rowPitch imagePitch:&imagePitch];
            NSUInteger layerBytes = _glTarget == GL_TEXTURE_1D_ARRAY ? rowPitch : imagePitch;
            uint8_t *tmp = malloc(layerBytes * slices);
            if (!tmp) continue;
            glGetTexImage(_glTarget, l, f.format, f.type, tmp);
            for (NSUInteger s = 0; s < slices; s++) {
                uint8_t *dst = [self addressForLevel:l slice:s rowPitch:&rowPitch imagePitch:&imagePitch];
                if (dst) memcpy(dst, tmp + s * layerBytes, layerBytes);
            }
            free(tmp);
            continue;
        }
        NSUInteger faces = _glTarget == GL_TEXTURE_CUBE_MAP ? 6 : 1;
        for (NSUInteger s = 0; s < faces; s++) {
            uint8_t *dst = [self addressForLevel:l slice:s rowPitch:&rowPitch imagePitch:&imagePitch];
            if (!dst) continue;
            glPixelStorei(GL_PACK_ROW_LENGTH, (GLint)(rowPitch / _pf.bytesPerBlock));
            glPixelStorei(GL_PACK_IMAGE_HEIGHT, (GLint)(imagePitch / rowPitch));
            glGetTexImage(faces == 6 ? GL_TEXTURE_CUBE_MAP_POSITIVE_X + (GLenum)s : _glTarget, l, f.format, f.type, dst);
        }
    }
    [self endAccess];
    glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    glPixelStorei(GL_PACK_IMAGE_HEIGHT, 0);
    glBindTexture(_glTarget, 0);
}

// IOSurface textures: rectangle texture aliasing the surface (render target and truth).
- (GLuint)glRectangle {
    if (_glRect || _rectFailed) return _glRect;
    IOSurfaceRef surface = self.rootSurface;
    TSMtlStat(TSStatSurfaceBinds, 1);
    glGenTextures(1, &_glRect);
    _glRectSeed = IOSurfaceGetSeed(surface);
    glBindTexture(GL_TEXTURE_RECTANGLE, _glRect);
    CGLError err = CGLTexImageIOSurface2D(_device.glContext, GL_TEXTURE_RECTANGLE, _glFormat.internalFormat,
                                          (GLsizei)IOSurfaceGetWidthOfPlane(surface, self.root->_plane),
                                          (GLsizei)IOSurfaceGetHeightOfPlane(surface, self.root->_plane),
                                          _glFormat.format, _glFormat.type, surface, (GLuint)self.root->_plane);
    if (err == kCGLNoError) [self applySwizzle:GL_TEXTURE_RECTANGLE];
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);
    if (err != kCGLNoError) {
        TSMtlWarn(@"CGLTexImageIOSurface2D failed (%d) for %@", err, self);
        glDeleteTextures(1, &_glRect);
        _glRect = 0;
        _rectFailed = YES;
    }
    return _glRect;
}

// IOSurface textures: refresh the sampling copy from the rectangle with a GPU blit.
- (void)refreshFromRectangle {
    GLuint rect = [self glRectangle];
    if (!rect) { [self uploadGL]; return; }
    GLint prevRead, prevDraw;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDraw);
    GLuint fbo[2];
    glGenFramebuffers(2, fbo);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo[0]);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, rect, 0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo[1]);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _glTex, 0);
    GLint w = (GLint)_desc.width, h = (GLint)_desc.height;
    TSMtlStat(TSStatSurfaceCopyBytes, (uint64_t)w * h * _pf.bytesPerBlock);
    // This runs mid-pass (texture binding of a draw), behind the encoder's GL shadow: put the scissor
    // test back, or every later draw of the pass loses its clip (Chrome backdrop-filter layers).
    GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
    if (scissor) glDisable(GL_SCISSOR_TEST);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    if (scissor) glEnable(GL_SCISSOR_TEST);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, prevRead);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDraw);
    glDeleteFramebuffers(2, fbo);
}

static BOOL TSSurfaceUploadMode(void) {
    static int on = -1;
    if (on < 0) on = getenv("TSMTL_SURFACE_UPLOAD") != NULL;
    return on;
}

// Surfaces only the CPU writes (Chrome's raster tiles) are uploaded from their memory instead of being
// sampled through the driver's IOSurface binding (TSMTL_SURFACE_UPLOAD experiment).
- (BOOL)samplesSurfaceThroughUpload {
    return TSSurfaceUploadMode() && !self.root->_surfaceGLWritten && _desc.textureType == MTLTextureType2D && _pf.bytesPerBlock == 4 &&
           !_glFormat.compressed && !_glFormat.depth;
}

- (void)uploadFromSurface {
    IOSurfaceRef surface = self.rootSurface;
    uint32_t seed = IOSurfaceGetSeed(surface);
    if (_uploadSeed == seed && _glValid) return;
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    size_t pitch = IOSurfaceGetBytesPerRowOfPlane(surface, self.root->_plane);
    const uint8_t *base = IOSurfaceGetBaseAddressOfPlane(surface, self.root->_plane);
    glBindTexture(GL_TEXTURE_2D, _glTex);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(pitch / 4));
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)_desc.width, (GLsizei)_desc.height, _glFormat.format, _glFormat.type, base);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    seed = IOSurfaceGetSeed(surface);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    TSMtlStat(TSStatTextureUploadBytes, _desc.width * _desc.height * 4);
    _uploadSeed = seed;
    _glValid = YES;
}

- (GLuint)glRectangleForSampling {
    if (!self.rootSurface || _desc.textureType != MTLTextureType2D || _desc.sampleCount > 1 || _glFormat.depth || !_glFormat.supported)
        return 0;
    if ([self samplesSurfaceThroughUpload]) return 0;
    // TSMTL_NO_RECT=1 (bisection): sample IOSurfaces through the 2D copy refreshed by a GPU blit.
    static int noRect = -1;
    if (noRect < 0) noRect = getenv("TSMTL_NO_RECT") != NULL;
    if (noRect) return 0;
    GLuint rect = [self glRectangle];
    if (rect) [self rebindIfSurfaceChanged];
    return rect;
}

- (NSString *)glContentReport {
    if (_glFormat.compressed || _glFormat.depth || _pf.bytesPerBlock != 4 || _desc.textureType != MTLTextureType2D || _desc.sampleCount > 1)
        return @"";
    TSMtlTexture *src = _aliasSample ? self.root : self;
    GLuint name = src->_glTex;
    if (!name) return @" (no GL copy)";
    size_t w = _desc.width, h = _desc.height, opaque = 0;
    uint32_t *px = malloc(w * h * 4);
    if (!px) return @"";
    GLint unit;
    glGetIntegerv(GL_ACTIVE_TEXTURE, &unit);
    glActiveTexture(GL_TEXTURE0 + 79);
    glBindTexture(GL_TEXTURE_2D, name);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    glGetTexImage(GL_TEXTURE_2D, 0, _glFormat.format, _glFormat.type, px);
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture((GLenum)unit);
    for (size_t i = 0; i < w * h; i++) if (px[i] >> 24) opaque++;
    free(px);
    TSMtlTexture *root = self.root;
    return [NSString stringWithFormat:@" [gl%u %zu%% opaque owner %p gen %llu/%llu]", name, opaque * 100 / (w * h), root->_gpuOwner,
            _glGen, root->_cpuGen];
}

- (NSString *)surfaceCoherencyReport {
    IOSurfaceRef surface = self.rootSurface;
    if (!surface || !_glRect || _pf.bytesPerBlock != 4) return @"";
    size_t w = IOSurfaceGetWidthOfPlane(surface, self.root->_plane), h = IOSurfaceGetHeightOfPlane(surface, self.root->_plane);
    uint32_t *gl = malloc(w * h * 4);
    if (!gl) return @"";
    // glGetTexImage returns zeros for IOSurface rectangles on this driver: read through a framebuffer.
    GLint prevRead;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
    GLuint fbo;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, _glRect, 0);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    GLenum status = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER);
    if (status == GL_FRAMEBUFFER_COMPLETE) glReadPixels(0, 0, (GLsizei)w, (GLsizei)h, _glFormat.format, _glFormat.type, gl);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, prevRead);
    glDeleteFramebuffers(1, &fbo);
    if (status != GL_FRAMEBUFFER_COMPLETE) { free(gl); return [NSString stringWithFormat:@" (fbo 0x%x)", status]; }
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = IOSurfaceGetBaseAddressOfPlane(surface, self.root->_plane);
    size_t pitch = IOSurfaceGetBytesPerRowOfPlane(surface, self.root->_plane), diff = 0, firstRow = SIZE_MAX;
    uint32_t c0 = 0, g0 = 0;
    size_t cpuOpaque = 0;
    for (size_t y = 0; y < h; y++) {
        const uint32_t *cpu = (const uint32_t *)(base + y * pitch);
        for (size_t x = 0; x < w; x++) {
            if (cpu[x] >> 24) cpuOpaque++;
            if (cpu[x] != gl[y * w + x]) { if (!diff) { c0 = cpu[x]; g0 = gl[y * w + x]; } diff++; if (firstRow == SIZE_MAX) firstRow = y; }
        }
    }
    uint32_t seed = IOSurfaceGetSeed(surface);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    free(gl);
    return diff ? [NSString stringWithFormat:@" STALE(%zu px differ from row %zu, seed %u/%u, cpu %08x gl %08x fmt 0x%x/0x%x sw %d)", diff, firstRow, seed, _glRectSeed, c0, g0,
                         _glFormat.format, _glFormat.type, (int)_desc.swizzle.red]
                : [NSString stringWithFormat:@" coherent(seed %u, %zu%% opaque)", seed, cpuOpaque * 100 / MAX(w * h, 1)];
}

// Another process (Chrome's renderer rasterizing tiles) or the CPU may have written the surface since it
// was bound; the seed moves on every such write. Rebinding makes the driver take the current contents.
- (void)rebindIfSurfaceChanged {
    static int disabled = -1;
    if (disabled < 0) disabled = getenv("TSMTL_NO_SEED_REBIND") != NULL;
    static int always = -1;
    if (always < 0) always = getenv("TSMTL_REBIND_ALWAYS") != NULL;
    IOSurfaceRef surface = self.rootSurface;
    uint32_t seed = IOSurfaceGetSeed(surface);
    uint64_t epoch = _device.executionEpoch;
    if (seed == _glRectSeed && !(always && _glRectEpoch != epoch)) return;
    _glRectEpoch = epoch;
    if (gTSMtlDrawTrace) fprintf(stderr, "[TSDraw]   surface %p seed %u -> %u%s\n", surface, _glRectSeed, seed, disabled ? " (not rebound)" : "");
    _glRectSeed = seed;
    TSMtlStat(TSStatSurfaceRebinds, 1);
    if (disabled) return;
    if (gTSComputeCLActive) TSMtlComputeForget(_device, _glRect, GL_TEXTURE_RECTANGLE);
    TSMtlForgetFramebufferTexture(_device, _glRect);   // re-specified: framebuffers holding it are checked again
    glBindTexture(GL_TEXTURE_RECTANGLE, _glRect);
    CGLTexImageIOSurface2D(_device.glContext, GL_TEXTURE_RECTANGLE, _glFormat.internalFormat,
                           (GLsizei)IOSurfaceGetWidthOfPlane(surface, self.root->_plane),
                           (GLsizei)IOSurfaceGetHeightOfPlane(surface, self.root->_plane),
                           _glFormat.format, _glFormat.type, surface, (GLuint)self.root->_plane);
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);
}

- (GLuint)glTextureForSampling:(GLenum *)target {
    TSMtlTexture *root = self.root;
    if (_aliasSample) return [root glTextureForSampling:target];
    if (!_glTex) [self createGLTexture];
    *target = _glTarget;
    uint64_t epoch = _device.executionEpoch;
    if (root->_surface && [self samplesSurfaceThroughUpload]) {
        [self uploadFromSurface];
        return _glTex;
    }
    if (root->_surface) {
        uint64_t serial = gSurfaceWrites;
        if (_glEpoch != epoch || _glSurfaceSerial != serial) {
            [self refreshFromRectangle];
            _glEpoch = epoch;
            _glSurfaceSerial = serial;
        }
        return _glTex;
    }
    TS_LOCK(root);
    __unsafe_unretained TSMtlTexture *owner = root->_gpuOwner;
    uint64_t gen = root->_cpuGen;
    TS_UNLOCK(root);
    if (owner == self) return _glTex;          // this mirror holds the newest data
    if (!owner && _glGen == gen && !root->_buffer) return _glTex;   // nothing changed since the last upload
    if (owner) [root readbackOwner];
    BOOL partial = NO;
    __typeof__(root->_regions[0]) regions[16];
    int count = 0;
    BOOL transferable = [self canTransferPixels];
    TS_LOCK(root);
    gen = root->_cpuGen;
    // The root mirror catches up region by region when it was current before the last full change.
    partial = self == root && _glValid && _glGen >= root->_fullGen && !root->_buffer && !_glFormat.compressed && transferable;
    for (int i = 0; partial && i < root->_regionCount; i++)
        if (root->_regions[i].gen > _glGen) regions[count++] = root->_regions[i];
    TS_UNLOCK(root);
    // Buffer-backed textures alias memory the app can change at any time: refresh per execution.
    BOOL stale = _glGen != gen || (root->_buffer && _glEpoch != epoch);
    if (stale) {
        if (partial && !root->_buffer) {
            for (int i = 0; i < count; i++) [self uploadRegion:regions[i].region level:regions[i].level slice:regions[i].slice];
        } else if (gen || root->_buffer) {   // generation 0 = never written by the CPU: nothing to upload
            [self uploadGL];
            _glValid = YES;
        }
        _glGen = gen;
        _glEpoch = epoch;
    }
    return _glTex;
}

- (GLuint)glTextureForCompute:(GLenum *)target {
    if (self.rootSurface && _desc.textureType == MTLTextureType2D && _desc.sampleCount == 1 && !_glFormat.depth && _glFormat.supported) {
        GLuint rect = [self glRectangle];
        if (rect) {
            [self rebindIfSurfaceChanged];
            *target = GL_TEXTURE_RECTANGLE;
            return rect;
        }
    }
    return [self glTextureForSampling:target];
}

- (BOOL)attachToFramebuffer:(GLenum)attachment level:(NSUInteger)level slice:(NSUInteger)slice depthPlane:(NSUInteger)plane {
    TSGLAttachment a;
    if (![self glAttachment:&a level:level slice:slice depthPlane:plane]) return NO;
    TSGLAttach(attachment, &a);
    return YES;
}

- (BOOL)glAttachment:(TSGLAttachment *)out level:(NSUInteger)level slice:(NSUInteger)slice depthPlane:(NSUInteger)plane {
    if (_aliasRender) return [_parent glAttachment:out level:level + _parentLevel slice:slice + _parentSlice depthPlane:plane];
    if (self.rootSurface) {
        GLuint rect = [self glRectangle];
        if (rect) {
            *out = (TSGLAttachment){ GL_TEXTURE_RECTANGLE, rect, 0, -1 };
            return YES;
        }
    }
    GLenum target;
    GLuint name = [self glTextureForSampling:&target];
    switch (target) {
    case GL_TEXTURE_CUBE_MAP:
        *out = (TSGLAttachment){ GL_TEXTURE_CUBE_MAP_POSITIVE_X + (GLenum)slice, name, (GLint)level, -1 }; break;
    case GL_TEXTURE_2D_ARRAY: case GL_TEXTURE_CUBE_MAP_ARRAY: case GL_TEXTURE_1D_ARRAY: case GL_TEXTURE_2D_MULTISAMPLE_ARRAY:
        *out = (TSGLAttachment){ target, name, (GLint)level, (GLint)slice }; break;
    case GL_TEXTURE_3D:
        *out = (TSGLAttachment){ target, name, (GLint)level, (GLint)plane }; break;
    case GL_TEXTURE_2D: case GL_TEXTURE_2D_MULTISAMPLE: case GL_TEXTURE_RECTANGLE:
        *out = (TSGLAttachment){ target, name, (GLint)level, -1 }; break;
    default:
        return NO;
    }
    return YES;
}

void TSGLAttach(GLenum attachment, const TSGLAttachment *a) {
    if (a->layer >= 0) glFramebufferTextureLayer(GL_DRAW_FRAMEBUFFER, attachment, a->name, a->level, a->layer);
    else glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, attachment, a->target, a->name, a->level);
}

- (void)didRenderGL {
    if (_aliasRender) { [_parent didRenderGL]; return; }
    TSMtlTexture *root = self.root;
    TS_LOCK(root);
    if (root->_surface && _glRect) {
        root->_surfaceWritePending = YES;
        root->_surfaceGLWritten = YES;
        gSurfaceWrites++;
        TSMtlStat(TSStatSurfaceWrites, 1);
    }
    else root->_gpuOwner = self;
    TS_UNLOCK(root);
}

- (BOOL)gpuCopyFromSlice:(NSUInteger)srcSlice level:(NSUInteger)srcLevel origin:(MTLOrigin)srcOrigin size:(MTLSize)size
               toTexture:(TSMtlTexture *)dst slice:(NSUInteger)dstSlice level:(NSUInteger)dstLevel origin:(MTLOrigin)dstOrigin {
    // Bit-exact only: same GL format (or its sRGB twin: Metal copies between them, and this driver's
    // blit never converts sRGB, measured with exp/srgbblit), renderable color or depth, single-sampled, 2D.
    TSGLFormat sf = _glFormat, df = dst->_glFormat;
    BOOL srgbTwins = (sf.internalFormat == GL_RGBA8 && df.internalFormat == GL_SRGB8_ALPHA8) ||
                     (sf.internalFormat == GL_SRGB8_ALPHA8 && df.internalFormat == GL_RGBA8);
    if (![dst isKindOfClass:[TSMtlTexture class]] || !sf.supported || !df.supported || sf.compressed || sf.integer != df.integer ||
        (sf.internalFormat != df.internalFormat && !srgbTwins) || sf.format != df.format || sf.type != df.type || sf.stencil ||
        _desc.sampleCount > 1 || dst->_desc.sampleCount > 1 || size.depth != 1 ||
        _desc.textureType == MTLTextureType3D || dst->_desc.textureType == MTLTextureType3D)
        return NO;
    GLint prevRead, prevDraw;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDraw);
    GLuint fbo[2];
    glGenFramebuffers(2, fbo);
    GLenum attachment = sf.depth ? GL_DEPTH_ATTACHMENT : GL_COLOR_ATTACHMENT0;
    // attachToFramebuffer brings each GL texture up to date first (uploads CPU-side changes).
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo[0]);
    BOOL ok = [self attachToFramebuffer:attachment level:srcLevel slice:srcOrigin.z + srcSlice depthPlane:0];
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo[1]);
    ok = ok && [dst attachToFramebuffer:attachment level:dstLevel slice:dstOrigin.z + dstSlice depthPlane:0];
    if (ok && !sf.depth) glDrawBuffer(GL_COLOR_ATTACHMENT0);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo[0]);
    if (ok && !sf.depth) glReadBuffer(GL_COLOR_ATTACHMENT0);
    ok = ok && glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE &&
         glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (ok) {
        GLint sx = (GLint)srcOrigin.x, sy = (GLint)srcOrigin.y, dx = (GLint)dstOrigin.x, dy = (GLint)dstOrigin.y;
        GLint w = (GLint)size.width, h = (GLint)size.height;
        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_FRAMEBUFFER_SRGB);   // raw copy: no sRGB decode/encode
        if (!sf.depth) glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        else glDepthMask(GL_TRUE);
        glBlitFramebuffer(sx, sy, sx + w, sy + h, dx, dy, dx + w, dy + h, sf.depth ? GL_DEPTH_BUFFER_BIT : GL_COLOR_BUFFER_BIT, GL_NEAREST);
        [dst didRenderGL];
    }
    glBindFramebuffer(GL_READ_FRAMEBUFFER, prevRead);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDraw);
    glDeleteFramebuffers(2, fbo);
    return ok;
}

- (TSGLFormat)glFormat { return _glFormat; }

#pragma mark CPU access

// Copies a region between the texture and client memory (toTexture = replaceRegion direction).
- (void)copyRegion:(MTLRegion)region level:(NSUInteger)level slice:(NSUInteger)slice client:(uint8_t *)client
       bytesPerRow:(NSUInteger)clientRowPitch bytesPerImage:(NSUInteger)clientImagePitch toTexture:(BOOL)toTexture {
    if (toTexture && [self glReplaceRegion:region level:level slice:slice bytes:client rowPitch:clientRowPitch imagePitch:clientImagePitch])
        return;
    [self syncForCPURead];
    [self beginAccess];
    NSUInteger rowPitch, imagePitch;
    uint8_t *base = [self addressForLevel:level slice:slice rowPitch:&rowPitch imagePitch:&imagePitch];
    if (base) {
        NSUInteger bx = region.origin.x / _pf.blockWidth, by = region.origin.y / _pf.blockHeight;
        NSUInteger rowBytes = ((region.size.width + _pf.blockWidth - 1) / _pf.blockWidth) * _pf.bytesPerBlock;
        NSUInteger rows = (region.size.height + _pf.blockHeight - 1) / _pf.blockHeight;
        if (!clientImagePitch) clientImagePitch = clientRowPitch * rows;
        for (NSUInteger z = 0; z < region.size.depth; z++)
            for (NSUInteger y = 0; y < rows; y++) {
                uint8_t *tex = base + (region.origin.z + z) * imagePitch + (by + y) * rowPitch + bx * _pf.bytesPerBlock;
                uint8_t *cli = client + z * clientImagePitch + y * clientRowPitch;
                if (toTexture) memcpy(tex, cli, MIN(rowBytes, clientRowPitch));
                else memcpy(cli, tex, MIN(rowBytes, clientRowPitch));
            }
    }
    [self endAccess];
    if (toTexture) [self didWriteRegion:region level:level slice:slice];
}

- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)bytes
          bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage {
    if (gTSMtlDrawTrace && self.rootSurface)
        fprintf(stderr, "[TSDraw] replaceRegion %p:%lux%lu:ios (%lu,%lu) %lux%lu thread %s\n", self, (unsigned long)_desc.width,
                (unsigned long)_desc.height, (unsigned long)region.origin.x, (unsigned long)region.origin.y, (unsigned long)region.size.width,
                (unsigned long)region.size.height, _device.isOnGPUQueue ? "gpu" : "app");
    [self copyRegion:region level:level slice:slice client:(uint8_t *)bytes bytesPerRow:bytesPerRow bytesPerImage:bytesPerImage toTexture:YES];
}

- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)bytesPerRow {
    [self copyRegion:region level:level slice:0 client:(uint8_t *)bytes bytesPerRow:bytesPerRow bytesPerImage:0 toTexture:YES];
}

- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage
      fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {
    [self copyRegion:region level:level slice:slice client:bytes bytesPerRow:bytesPerRow bytesPerImage:bytesPerImage toTexture:NO];
}

- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bytesPerRow fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level {
    [self copyRegion:region level:level slice:0 client:bytes bytesPerRow:bytesPerRow bytesPerImage:0 toTexture:NO];
}

#pragma mark Views and properties

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format {
    return [self newTextureViewWithPixelFormat:format textureType:_desc.textureType
                                        levels:NSMakeRange(0, _desc.mipmapLevelCount) slices:NSMakeRange(0, [self sliceCount])];
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels slices:(NSRange)slices {
    return [self newTextureViewWithPixelFormat:format textureType:type levels:levels slices:slices swizzle:_desc.swizzle];
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels
                                         slices:(NSRange)slices swizzle:(MTLTextureSwizzleChannels)swizzle {
    return [[TSMtlTexture alloc] initViewOf:self pixelFormat:format type:type levels:levels slices:slices swizzle:swizzle];
}

- (id<MTLTexture>)newTextureViewWithDescriptor:(MTLTextureViewDescriptor *)d {
    return [self newTextureViewWithPixelFormat:d.pixelFormat textureType:d.textureType levels:d.levelRange slices:d.sliceRange swizzle:d.swizzle];
}

- (id<MTLDevice>)device { return _device; }
- (MTLTextureType)textureType { return _desc.textureType; }
- (MTLPixelFormat)pixelFormat { return _desc.pixelFormat; }
- (NSUInteger)width { return _desc.width; }
- (NSUInteger)height { return _desc.height; }
- (NSUInteger)depth { return _desc.depth; }
- (NSUInteger)mipmapLevelCount { return _desc.mipmapLevelCount; }
- (NSUInteger)sampleCount { return _desc.sampleCount; }
- (NSUInteger)arrayLength { return _desc.arrayLength; }
- (MTLTextureUsage)usage { return _desc.usage; }
- (MTLStorageMode)storageMode { return _desc.storageMode; }
- (MTLCPUCacheMode)cpuCacheMode { return _desc.cpuCacheMode; }
- (MTLHazardTrackingMode)hazardTrackingMode { return _desc.hazardTrackingMode; }
- (MTLResourceOptions)resourceOptions { return TSResourceOptions(_desc.storageMode, _desc.cpuCacheMode, _desc.hazardTrackingMode); }
- (MTLTextureSwizzleChannels)swizzle { return _desc.swizzle; }
- (BOOL)allowGPUOptimizedContents { return _desc.allowGPUOptimizedContents; }
- (MTLTextureCompressionType)compressionType { return _desc.compressionType; }
- (BOOL)isFramebufferOnly { return NO; }
- (BOOL)isShareable { return NO; }
- (BOOL)isSparse { return NO; }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable {}
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (NSUInteger)allocatedSize { return _memorySize; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){ (uint64_t)(__bridge void *)self }; }
- (id<MTLTexture>)parentTexture { return _parent; }
- (NSUInteger)parentRelativeLevel { return _parentLevel; }
- (NSUInteger)parentRelativeSlice { return _parentSlice; }
- (id<MTLResource>)rootResource { return self.root; }
- (id<MTLBuffer>)buffer { return _buffer; }
- (NSUInteger)bufferOffset { return _bufferOffset; }
- (NSUInteger)bufferBytesPerRow { return _bufferRowPitch; }
- (IOSurfaceRef)iosurface { return _surface; }
- (NSUInteger)iosurfacePlane { return _plane; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
    MTLPurgeableState old = _purgeable;
    if (state != MTLPurgeableStateKeepCurrent) _purgeable = state;
    return old;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<TSMtlTexture %p type=%lu fmt=%lu %lux%lux%lu mips=%lu label=%@>", self,
            (unsigned long)_desc.textureType, (unsigned long)_desc.pixelFormat, (unsigned long)_desc.width,
            (unsigned long)_desc.height, (unsigned long)_desc.depth, (unsigned long)_desc.mipmapLevelCount, self.label];
}
@end
