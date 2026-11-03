// TeraScale Compute - OpenCL path of the core (docs/PIANO-COMPUTE.md). Kernels the GL path cannot express
// (TSAirTranslator kernel mode) are translated to OpenCL C (TSAirOpenCL.m), built once per process on a CL
// context that shares the device's GL objects, and dispatched from the GPU queue through TSCLRuntime:
//   - OpenCL.framework is loaded with dlopen at the first kernel that needs it (never with compute off);
//   - one CL submission per run of consecutive dispatches, closed before the next GL command of the
//     command buffer (TSMtlCommandBuffer -execute) and before its completion fence, which therefore also
//     covers the kernels (measured: the GPU runs CL and GL work in submission order);
//   - buffers are the GL buffers of TSMtlBuffer (CL writes make GL the truth until the CPU copy is merged
//     back at completion, TSMtlBuffer -didWriteGPU), textures the GL textures of TSMtlTexture (IOSurfaces
//     through their rectangle texture, in place);
//   - kernels that only look at their grid position run as one enqueue rounded up to a 16x16 (2D) or
//     256-wide (1D) work-group, the extra threads returning at once (C4, E3: the driver's own 1D strips run
//     2D image kernels at half speed); other dispatchThreads grids that are not a multiple of the
//     threadgroup run as up to 8 enqueues (uniform part plus edges with smaller work-groups), so barriers
//     keep Metal's non-uniform threadgroup semantics.
// Cost control (docs/OTTIMIZZAZIONE-COMPUTE.md): every translation and build happens once even when several
// threads ask at the same time (A1, A2), built programs are kept on disk next to the GLSL cache (A3), kernel
// arguments are only set when they change (C3), and the CL context is released after a long idle time and
// recreated on demand (M4; sooner under VRAM pressure, M3).
#import "TSPrivate.h"
#define TS_CL_DYNAMIC 1
#import "compute/TSCLRuntime.h"
#import "compute/TSCLApi.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>

#pragma mark - OpenCL entry points

#define TS_CL_DEFINE(ret, name, args) ret (*ts_##name) args;
TS_CL_FUNCS(TS_CL_DEFINE)
#undef TS_CL_DEFINE

bool TSCLApiLoad(const char **error) {
    static bool loaded;
    static const char *failure;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/OpenCL.framework/OpenCL", RTLD_NOW | RTLD_LOCAL);
        if (!h) { failure = "OpenCL.framework not found"; return; }
#define TS_CL_RESOLVE(ret, name, args) \
        if (!(ts_##name = (ret (*) args)dlsym(h, #name))) { failure = "OpenCL lacks " #name; return; }
        TS_CL_FUNCS(TS_CL_RESOLVE)
#undef TS_CL_RESOLVE
        loaded = true;
    });
    if (error) *error = failure;
    return loaded;
}

#pragma mark - Knobs

static uint64_t TSNow(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// TSMTL_CL_RETILE=0: keep the app's work-group shape and the edge enqueues for every kernel (A/B for C4, E3).
static BOOL TSCLRetile(void) {
    static int on = -1;
    if (on < 0) on = !getenv("TSMTL_CL_RETILE") || atoi(getenv("TSMTL_CL_RETILE")) != 0;
    return on;
}

// TSMTL_CL_IDLE=<seconds>: release the CL context after that long without a dispatch (default 30; 0 = never).
// Measured: the context's own footprint is ~0.2 MB here, so this is housekeeping, not a VRAM lever.
static double TSCLIdleSeconds(void) {
    static double s = -1;
    if (s < 0) s = getenv("TSMTL_CL_IDLE") ? atof(getenv("TSMTL_CL_IDLE")) : 30;
    return s;
}

#pragma mark - Per-device state

int gTSComputeCLActive;
_Thread_local void *gTSCLOpenRun;
// GPU queue: runtime whose last run ended asynchronously and has not been joined yet (B4).
static _Thread_local TSCLRuntime *gTSCLPendingRT;

@interface TSCLDeviceState : NSObject {
@public
    __weak TSMtlDevice *device;
    TSCLRuntime *rt;                   // NULL before the first kernel and after an idle release
    NSString *failure;                 // OpenCL cannot work in this process (permanent)
    NSString *deviceTag;               // CL device name + driver version: part of the binary cache key
    NSMutableDictionary<NSString *, TSCLKernel *> *programs;   // CL source + options -> kernel (built or being built)
    NSMutableDictionary<NSNumber *, NSValue *> *samplers;      // GPU queue: cl_sampler by (normalized, address, filter)
    cl_mem nullImages[5];              // GPU queue: B5 placeholders (1D, 1D array, 2D, 2D array, 3D)
    int building;                      // builds using rt's context right now (no idle release meanwhile)
    _Atomic uint64_t lastUse;          // uptime ns of the last dispatch
    dispatch_source_t idleTimer;
    uint64_t contexts;                 // CL contexts created so far (1 + recreations after idle releases)
}
@end
@implementation TSCLDeviceState
@end

@implementation TSCLKernel
- (void)dealloc { free(argCache); }
@end

static void TSCLLogToShim(void *ctx, TSCLLogLevel level, const char *message) {
    if (level == TSCLLogError) TSMtlCompute(@"OpenCL error: %s", message);
    else TSMtlCompute(@"%s", message);
}

static char kTSCLStateKey;

// Any thread. The state object only; the CL context comes with TSCLEnsureRuntimeLocked.
static TSCLDeviceState *TSCLState(TSMtlDevice *device, BOOL create) {
    TSCLDeviceState *st = objc_getAssociatedObject(device, &kTSCLStateKey);
    if (st || !create) return st;
    @synchronized (device) {
        st = objc_getAssociatedObject(device, &kTSCLStateKey);
        if (st) return st;
        st = [TSCLDeviceState new];
        st->device = device;
        st->programs = [NSMutableDictionary dictionary];
        st->samplers = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(device, &kTSCLStateKey, st, OBJC_ASSOCIATION_RETAIN);
    }
    return st;
}

static void TSCLArmIdleTimer(TSCLDeviceState *st);

// Under @synchronized (st). Creates the CL context on the device's GL share group (the first one costs
// 0.2-0.3 s, see C0.2; a recreation after an idle release 12-28 ms).
static BOOL TSCLEnsureRuntimeLocked(TSCLDeviceState *st) {
    if (st->rt) return YES;
    if (st->failure) return NO;
    TSMtlDevice *device = st->device;
    const char *err = NULL;
    if (!device) { st->failure = @"device gone"; return NO; }
    if (!TSCLApiLoad(&err)) { st->failure = [NSString stringWithFormat:@"OpenCL unavailable: %s", err]; return NO; }
    uint64_t t0 = TSNow();
    // Profiling only records timestamps; events (and their cost) are only asked for while stats are on (G2).
    BOOL profiling = !getenv("TSMTL_CL_PROFILE") || atoi(getenv("TSMTL_CL_PROFILE")) != 0;
    TSCLRuntimeConfig cfg = { CGLGetShareGroup(device.glContext), TSCLLogToShim, NULL, profiling };
    st->rt = TSCLRuntimeCreate(&cfg);
    if (!st->rt) { st->failure = @"no OpenCL context on the device's GL share group"; return NO; }
    char name[128] = "", version[128] = "";
    clGetDeviceInfo(TSCLRuntimeDevice(st->rt), CL_DEVICE_NAME, sizeof name, name, NULL);
    clGetDeviceInfo(TSCLRuntimeDevice(st->rt), CL_DRIVER_VERSION, sizeof version, version, NULL);
    st->deviceTag = [NSString stringWithFormat:@"%s|%s", name, version];
    st->contexts++;
    TSMtlCompute(@"OpenCL context on %s (driver %s) in %.0f ms%@", name, version, (TSNow() - t0) / 1e6,
                 st->contexts > 1 ? @", recreated after an idle release" : @"");
    atomic_store(&st->lastUse, TSNow());
    gTSComputeCLActive = 1;
    TSCLArmIdleTimer(st);
    return YES;
}

#pragma mark - Logging of dropped dispatches (B6)

// GPU queue. One line per (kernel, reason) every 5 s at most, with the count of the ones held back: a kernel
// refused at 60 fps no longer fills the log, and later kernels are still reported (the per-site limit of
// TS_LOG_AT would silence them for the rest of the process).
static void TSCLSkip(TSCLKernel *k, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void TSCLSkip(TSCLKernel *k, NSString *fmt, ...) {
    TSMtlStat(TSStatComputeSkipped, 1);
    va_list ap;
    va_start(ap, fmt);
    NSString *reason = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSMutableDictionary<NSString *, NSMutableArray *> *seen;   // key -> [last ns, held back]
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSString *key = [NSString stringWithFormat:@"%p %@", k, reason];
    uint64_t now = TSNow(), held = 0;
    BOOL emit = NO;
    os_unfair_lock_lock(&lock);
    if (!seen) seen = [NSMutableDictionary dictionary];
    NSMutableArray *e = seen[key];
    if (!e || now - [e[0] unsignedLongLongValue] >= 5000000000ull) {
        held = e ? [e[1] unsignedLongLongValue] : 0;
        seen[key] = [NSMutableArray arrayWithObjects:@(now), @0, nil];
        emit = YES;
    } else {
        e[1] = @([e[1] unsignedLongLongValue] + 1);
    }
    os_unfair_lock_unlock(&lock);
    if (emit)
        TSMtlLogAt(TSLogCompute, NULL, @"dispatch of %@ skipped: %@%@", k->name, reason,
                   held ? [NSString stringWithFormat:@" (%llu more since the last report)", held] : @"");
}

#pragma mark - Kernels

static NSString *TSCLBuildLog(cl_program prog, cl_device_id dev) {
    size_t size = 0;
    clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, 0, NULL, &size);
    if (!size) return @"";
    char *log = malloc(size + 1);
    clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, size, log, NULL);
    log[size] = 0;
    NSString *s = @(log);
    free(log);
    // The first errors are what matters; warnings about prototypes are noise.
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *l in [s componentsSeparatedByString:@"\n"])
        if ([l containsString:@"error"] && lines.count < 4) [lines addObject:[l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    return lines.count ? [lines componentsJoinedByString:@" | "] : [s substringToIndex:MIN(s.length, (NSUInteger)300)];
}

// A1, A2: one computation per key even when several threads ask at once (VideoToolbox creates the same
// pipeline on 4 threads in the same millisecond). The first caller computes under the entry's lock, the
// others wait on it and read the result.
@interface TSCLOnce : NSObject {
@public
    BOOL done;
    id value;   // TSCLKernelSource, or NSString with the reason
}
@end
@implementation TSCLOnce
@end

static TSCLKernelSource *TSCLTranslation(NSData *bitcode, NSString **error) {
    static NSMutableDictionary<NSData *, TSCLOnce *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSMutableDictionary dictionary]; });
    TSCLOnce *entry;
    @synchronized (table) {
        entry = table[bitcode];
        if (!entry) table[bitcode] = entry = [TSCLOnce new];
    }
    @synchronized (entry) {
        if (!entry->done) {
            NSString *terr = nil;
            uint64_t t0 = TSNow();
            TSCLKernelSource *src = TSAirTranslateOpenCL(bitcode, &terr);
            TSMtlStat(TSStatTranslateMicros, (TSNow() - t0) / 1000);
            entry->value = src ?: (id)(terr ?: @"translation failed");
            entry->done = YES;
        }
    }
    if ([entry->value isKindOfClass:[TSCLKernelSource class]]) return entry->value;
    *error = entry->value;
    return nil;
}

// A3: CL program binaries on disk, keyed by source, options and CL device/driver.
static NSData *TSCLBinaryKey(NSString *deviceTag, TSCLKernel *k) {
    NSString *key = [NSString stringWithFormat:@"tscl-bin-1\n%@\n%@\n%@", deviceTag, k->options, k->source];
    return [key dataUsingEncoding:NSUTF8StringEncoding];
}

static cl_program TSCLProgramFromBinary(cl_context ctx, cl_device_id dev, NSData *binary, NSString *options) {
    size_t len = binary.length;
    const unsigned char *bytes = binary.bytes;
    cl_int status = CL_SUCCESS, binStatus = CL_SUCCESS;
    cl_program prog = clCreateProgramWithBinary(ctx, 1, &dev, &len, &bytes, &binStatus, &status);
    if (!prog) return NULL;
    if (binStatus != CL_SUCCESS || clBuildProgram(prog, 1, &dev, options.UTF8String, NULL, NULL) != CL_SUCCESS) {
        clReleaseProgram(prog);
        return NULL;
    }
    return prog;
}

static NSData *TSCLProgramBinary(cl_program prog) {
    size_t size = 0;
    if (clGetProgramInfo(prog, CL_PROGRAM_BINARY_SIZES, sizeof size, &size, NULL) != CL_SUCCESS || !size) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    unsigned char *ptr = data.mutableBytes;
    if (clGetProgramInfo(prog, CL_PROGRAM_BINARIES, sizeof ptr, &ptr, NULL) != CL_SUCCESS) return nil;
    return data;
}

static void TSCLArgCacheReset(TSCLKernel *k);

// Any thread. Builds k on the current context (the binary from disk when there is one); a kernel whose
// context was released (M4) is rebuilt the same way. NO with k->failure (or the runtime's) set.
static BOOL TSCLBuild(TSCLDeviceState *st, TSCLKernel *k) {
    @synchronized (k) {
        if (k->kernel) return YES;
        if (k->failure) return NO;
        cl_context ctx;
        cl_device_id dev;
        NSString *tag;
        @synchronized (st) {
            if (!TSCLEnsureRuntimeLocked(st)) { k->failure = st->failure; return NO; }
            st->building++;
            ctx = TSCLRuntimeContext(st->rt);
            dev = TSCLRuntimeDevice(st->rt);
            tag = st->deviceTag;
        }
        uint64_t t0 = TSNow();
        NSURL *file = TSMtlDiskCacheFile(@"cl", TSCLBinaryKey(tag, k));
        NSData *binary = file ? [NSData dataWithContentsOfURL:file] : nil;
        cl_program prog = binary ? TSCLProgramFromBinary(ctx, dev, binary, k->options) : NULL;
        BOOL fromDisk = prog != NULL;
        cl_int status = CL_SUCCESS;
        if (fromDisk) {
            TSMtlStatAlways(TSStatCLBinaryHits, 1);
        } else {
            const char *text = k->source.UTF8String;
            prog = clCreateProgramWithSource(ctx, 1, &text, NULL, &status);
            if (prog) status = clBuildProgram(prog, 1, &dev, k->options.UTF8String, NULL, NULL);
            TSMtlStatAlways(TSStatCLBuilds, 1);
        }
        double ms = (TSNow() - t0) / 1e6;
        if (!prog || status != CL_SUCCESS) {
            k->failure = [NSString stringWithFormat:@"clBuildProgram failed (%d): %@", status, prog ? TSCLBuildLog(prog, dev) : @""];
            if (getenv("TSMTL_CL_DUMP")) fprintf(stderr, "[TSMtl] OpenCL source of %s:\n%s\n", k->name.UTF8String, k->source.UTF8String);
            if (prog) clReleaseProgram(prog);
        } else {
            if (!fromDisk && file) TSMtlDiskCacheWrite(file, TSCLProgramBinary(prog));
            cl_kernel kern = clCreateKernel(prog, "ts_kernel", &status);
            if (!kern) k->failure = [NSString stringWithFormat:@"clCreateKernel failed (%d)", status];
            else {
                size_t wg = 256;
                cl_ulong local = 0;
                clGetKernelWorkGroupInfo(kern, dev, CL_KERNEL_WORK_GROUP_SIZE, sizeof wg, &wg, NULL);
                clGetKernelWorkGroupInfo(kern, dev, CL_KERNEL_LOCAL_MEM_SIZE, sizeof local, &local, NULL);
                BOOL rebuild = k->built;
                k->maxThreads = wg;
                TSCLArgCacheReset(k);
                k->kernel = kern;
                TSMtlCompute(@"kernel %@ runs on OpenCL: %@ in %.1f ms, %lu arguments, work-group <= %zu, local memory %llu bytes%@%@",
                             k->name, rebuild ? @"rebuilt" : fromDisk ? @"binary from the disk cache" : @"built", ms,
                             (unsigned long)(k->args.length / sizeof(TSCLArgSpec)), wg, (unsigned long long)local,
                             k->barriers ? @", barriers" : @"", k->guarded ? @", any work-group shape" : @"");
            }
            clReleaseProgram(prog);   // the kernel keeps it alive
        }
        k->built = YES;
        @synchronized (st) { st->building--; }
        return k->kernel != NULL;
    }
}

// TSMTL_CL_SAVE_DIR=<dir>: every kernel that reaches the OpenCL path is saved as <dir>/<name>-<hash>.air (its
// bitcode as the app specialized it) for tools/cltrans <dir> --build: VideoToolbox's VTMTSComputeFunction has
// 204 function constants and only the app knows its values (B1).
static void TSCLSaveBitcode(NSString *name, NSData *bitcode) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *d = getenv("TSMTL_CL_SAVE_DIR");
        if (d && *d) dir = @(d);
        if (dir) [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    if (!dir) return;
    NSString *file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%08lx.air", name ?: @"kernel",
                                                          (unsigned long)(bitcode.hash ^ bitcode.length * 2654435761u) & 0xffffffff]];
    if (![NSFileManager.defaultManager fileExistsAtPath:file]) [bitcode writeToFile:file atomically:YES];
}

TSCLKernel *TSMtlCLKernelForFunction(TSMtlDevice *device, id<MTLFunction> function, NSString **error) {
    if (![(id)function respondsToSelector:@selector(bitcodeData)]) { *error = @"function has no bitcode"; return nil; }
    NSData *bitcode = (NSData *)[(id)function performSelector:@selector(bitcodeData)];
    if (!bitcode.length) { *error = @"empty bitcode"; return nil; }
    TSCLSaveBitcode(function.name, bitcode);
    TSCLKernelSource *src = TSCLTranslation(bitcode, error);
    if (!src) return nil;

    TSCLDeviceState *st = TSCLState(device, YES);
    NSString *key = [src.options stringByAppendingString:src.source];
    TSCLKernel *k;
    @synchronized (st) {
        if (st->failure) { *error = st->failure; return nil; }
        k = st->programs[key];
        if (!k) {
            k = [TSCLKernel new];
            k->args = src.args;
            k->staticThreadgroupMemory = src.staticThreadgroupMemory;
            k->barriers = src.barriers;
            k->shapeSensitive = src.shapeSensitive;
            k->guarded = src.guarded;
            k->name = function.name;
            k->source = src.source;
            k->options = src.options;
            st->programs[key] = k;
        }
    }
    // Built kernels whose context was released since stay valid: the next dispatch rebuilds them.
    if (k->built && !k->failure) return k;
    if (!TSCLBuild(st, k)) { *error = k->failure; return nil; }
    return k;
}

#pragma mark - Prewarming (A5)

// Kernels known to be created at a moment where a stall shows: VideoToolbox's pixel transfer (Maps decodes
// tiles with it) and VectorKit's texture downscale.
static BOOL TSCLPrewarmWanted(NSString *name) {
    static NSSet<NSString *> *names;
    static BOOL all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *s = [NSMutableSet setWithObjects:@"VTMTSComputeFunction", @"downscaleTexture", nil];
        const char *env = getenv("TSMTL_CL_PREWARM");
        if (env && !strcmp(env, "0")) [s removeAllObjects];
        else if (env && !strcmp(env, "*")) all = YES;
        else if (env) [s addObjectsFromArray:[@(env) componentsSeparatedByString:@","]];
        names = s;
    });
    return all || [names containsObject:name];
}

void TSMtlComputePrewarmLibrary(TSMtlDevice *device, id<MTLLibrary> library) {
    if (!library || !TSMtlComputeEnabled()) return;
    NSMutableArray<NSString *> *wanted = [NSMutableArray array];
    for (NSString *name in library.functionNames)
        if (TSCLPrewarmWanted(name)) [wanted addObject:name];
    if (!wanted.count) return;
    __weak TSMtlDevice *weakDevice = device;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *name in wanted) @autoreleasepool {
            TSMtlDevice *dev = weakDevice;
            if (!dev) return;
            id<MTLFunction> f = [library newFunctionWithName:name];
            // Functions with constants are specialized by the app: nothing to build before that.
            if (f.functionType != MTLFunctionTypeKernel || f.functionConstantsDictionary.count || TSMtlKernelFitsGL(f)) continue;
            uint64_t t0 = TSNow();
            NSString *error = nil;
            TSCLKernel *k = TSMtlCLKernelForFunction(dev, f, &error);
            TSMtlCompute(@"prewarmed kernel %@ in %.1f ms%@", name, (TSNow() - t0) / 1e6,
                         k ? @"" : [NSString stringWithFormat:@" (does not run on OpenCL: %@)", error]);
        }
    });
}

#pragma mark - Idle release (M4)

// GPU queue. Releases the CL context and everything made on it when nothing was dispatched for a while; the
// kernels keep their source and are rebuilt (from the disk cache) at their next dispatch.
static void TSCLReleaseIdle(TSCLDeviceState *st, double idleSeconds) {
    @synchronized (st) {
        if (!st->rt || st->building) return;
        if ((TSNow() - atomic_load(&st->lastUse)) / 1e9 < idleSeconds) return;
        if (gTSCLOpenRun == st->rt || gTSCLPendingRT == st->rt) TSMtlComputeEndRun();
        // No kernel lock here (TSCLBuild takes the kernel's, then the state's): builders are excluded by
        // `building`, dispatches by running on this queue.
        for (TSCLKernel *k in st->programs.allValues) {
            if (k->kernel) clReleaseKernel(k->kernel);
            k->kernel = NULL;
            TSCLArgCacheReset(k);
        }
        for (NSValue *v in st->samplers.allValues) clReleaseSampler(v.pointerValue);
        [st->samplers removeAllObjects];
        for (int i = 0; i < 5; i++) {
            if (st->nullImages[i]) clReleaseMemObject(st->nullImages[i]);
            st->nullImages[i] = NULL;
        }
        TSCLRuntimeDestroy(st->rt);
        st->rt = NULL;
        if (st->idleTimer) dispatch_source_cancel(st->idleTimer);
        st->idleTimer = nil;
        TSMtlCompute(@"OpenCL context released after %.0f s without dispatches", idleSeconds);
    }
}

// Under @synchronized (st), with a runtime: checks every 10 s (a third of the limit when shorter), from a
// utility queue, whether to release it.
static void TSCLArmIdleTimer(TSCLDeviceState *st) {
    double limit = TSCLIdleSeconds();
    if (limit <= 0 || st->idleTimer) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    __weak TSCLDeviceState *weak = st;
    uint64_t every = (uint64_t)(MIN(10.0, MAX(limit / 3, 0.5)) * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)every), every, every / 5);
    dispatch_source_set_event_handler(timer, ^{
        TSCLDeviceState *s = weak;
        TSMtlDevice *device = s ? s->device : nil;
        if (!device) return;
        double idle = limit;   // not shortened under VRAM pressure: Maps then recreated the context every 10 s
        if ((TSNow() - atomic_load(&s->lastUse)) / 1e9 < idle) return;
        [device gpuAsync:^{ TSCLReleaseIdle(s, idle); }];
    });
    st->idleTimer = timer;
    dispatch_resume(timer);
}

#pragma mark - Dispatch (GPU queue)

// Metal per-axis addressing as the kernel's manual addressing word (TSAirOpenCL.m, B3): 0 edge, 1 repeat,
// 2 mirrored repeat, 3 clamp to zero / border, 4 mirror clamp to edge.
static unsigned TSCLAxisCode(MTLSamplerAddressMode m) {
    switch (m) {
    case MTLSamplerAddressModeRepeat: return 1;
    case MTLSamplerAddressModeMirrorRepeat: return 2;
    case MTLSamplerAddressModeClampToZero: case MTLSamplerAddressModeClampToBorderColor: return 3;
    case MTLSamplerAddressModeMirrorClampToEdge: return 4;
    default: return 0;
    }
}

// The CL sampler for a Metal sampler state, and the addressing word for the kernel: 0 when OpenCL's single
// addressing mode does what Metal asks on every axis, else the per-axis codes (the sampler then clamps to edge).
static cl_sampler TSCLSamplerFor(TSCLDeviceState *st, id<MTLSamplerState> state, cl_uint *amOut) {
    MTLSamplerDescriptor *d = [(id)state isKindOfClass:[TSMtlSamplerState class]] ? [(TSMtlSamplerState *)state samplerDescriptor] : nil;
    BOOL normalized = d ? d.normalizedCoordinates : YES;
    unsigned c[3] = { TSCLAxisCode(d ? d.sAddressMode : 0), TSCLAxisCode(d ? d.tAddressMode : 0), TSCLAxisCode(d ? d.rAddressMode : 0) };
    BOOL manual = c[0] != c[1] || c[0] != c[2] || c[0] == 4;
    cl_uint am = 0;
    if (manual) am = (normalized ? 0x8000u : 0x10000u) | c[0] | c[1] << 4 | c[2] << 8;
    *amOut = am;
    cl_addressing_mode mode = CL_ADDRESS_CLAMP_TO_EDGE;
    if (!manual) {
        switch (c[0]) {
        case 1: mode = normalized ? CL_ADDRESS_REPEAT : CL_ADDRESS_CLAMP_TO_EDGE; break;
        case 2: mode = normalized ? CL_ADDRESS_MIRRORED_REPEAT : CL_ADDRESS_CLAMP_TO_EDGE; break;
        case 3: mode = CL_ADDRESS_CLAMP; break;
        default: break;
        }
    }
    cl_filter_mode fm = d && (d.minFilter == MTLSamplerMinMagFilterLinear || d.magFilter == MTLSamplerMinMagFilterLinear)
                      ? CL_FILTER_LINEAR : CL_FILTER_NEAREST;
    NSNumber *key = @(normalized * 100000 + mode * 10 + (fm == CL_FILTER_LINEAR));
    NSValue *hit = st->samplers[key];
    if (hit) return hit.pointerValue;
    cl_int err;
    cl_sampler s = clCreateSampler(TSCLRuntimeContext(st->rt), normalized, mode, fm, &err);
    if (s) st->samplers[key] = [NSValue valueWithPointer:s];
    else TSMtlCompute(@"clCreateSampler failed: %d", err);
    return s;
}

// B5: a 1x1 image standing for an unbound texture the kernel tests with is_null_texture (it is never read).
static cl_mem TSCLNullImage(TSCLDeviceState *st, const TSCLArgSpec *a) {
    static const cl_mem_object_type types[5] = { CL_MEM_OBJECT_IMAGE1D, CL_MEM_OBJECT_IMAGE1D_ARRAY, CL_MEM_OBJECT_IMAGE2D,
                                                 CL_MEM_OBJECT_IMAGE2D_ARRAY, CL_MEM_OBJECT_IMAGE3D };
    int i = a->dims == 3 ? 4 : a->dims == 1 ? (a->array ? 1 : 0) : (a->array ? 3 : 2);
    if (st->nullImages[i]) return st->nullImages[i];
    cl_image_format format = { CL_RGBA, CL_UNORM_INT8 };
    cl_image_desc desc = { .image_type = types[i], .image_width = 1, .image_height = 1, .image_depth = 1, .image_array_size = 1 };
    cl_int err;
    st->nullImages[i] = clCreateImage(TSCLRuntimeContext(st->rt), CL_MEM_READ_WRITE, &format, &desc, NULL, &err);
    if (!st->nullImages[i]) TSMtlCompute(@"placeholder image (type 0x%x) failed: %d", (unsigned)types[i], err);
    return st->nullImages[i];
}

// GL texture target an image argument of this shape accepts.
static BOOL TSCLTargetFits(const TSCLArgSpec *a, GLenum target) {
    switch (target) {
    case GL_TEXTURE_2D: case GL_TEXTURE_RECTANGLE: return a->dims == 2 && !a->array;
    case GL_TEXTURE_2D_ARRAY: return a->dims == 2 && a->array;
    case GL_TEXTURE_3D: return a->dims == 3;
    case GL_TEXTURE_1D: return a->dims == 1 && !a->array;
    case GL_TEXTURE_1D_ARRAY: return a->dims == 1 && a->array;
    default: return NO;
    }
}

// C3: the values last given to each argument of a cl_kernel, so unchanged ones are not set again (a dispatch
// of a 6-resource kernel made ~15 clSetKernelArg calls). Dropped when the runtime releases a cl_mem (handles
// can be reused) and when the kernel is rebuilt.
enum { TSCLCachedArgs = 112 };
typedef struct {
    TSCLRuntime *rt;
    uint64_t generation;
    struct { uint8_t set, local; uint16_t size; uint8_t bytes[16]; } a[TSCLCachedArgs];
} TSCLArgCache;

static void TSCLArgCacheReset(TSCLKernel *k) {
    if (k->argCache) memset(k->argCache, 0, sizeof(TSCLArgCache));
}

static TSCLArgCache *TSCLArgsFor(TSCLKernel *k, TSCLRuntime *rt) {
    TSCLArgCache *c = k->argCache;
    if (!c) c = k->argCache = calloc(1, sizeof *c);
    if (!c) return NULL;
    uint64_t gen = TSCLRuntimeGeneration(rt);
    if (c->rt != rt || c->generation != gen) {
        memset(c, 0, sizeof *c);
        c->rt = rt;
        c->generation = gen;
    }
    return c;
}

static cl_int TSCLSetArg(TSCLKernel *k, TSCLArgCache *c, cl_uint i, size_t size, const void *value) {
    if (c && i < TSCLCachedArgs && size <= 16) {
        __typeof__(c->a[0]) *slot = &c->a[i];
        if (slot->set && slot->size == size && (value ? !slot->local && !memcmp(slot->bytes, value, size) : slot->local)) return CL_SUCCESS;
        cl_int err = clSetKernelArg(k->kernel, i, size, value);
        slot->set = err == CL_SUCCESS;
        slot->size = (uint16_t)size;
        slot->local = value == NULL;
        if (value) memcpy(slot->bytes, value, size);
        return err;
    }
    if (c && i < TSCLCachedArgs) c->a[i].set = 0;
    return clSetKernelArg(k->kernel, i, size, value);
}

// GPU queue: event of the newest ended run, until a command buffer's completion takes it.
static _Thread_local cl_event gTSCLRunEvent;

static void TSCLTakeEvent(TSCLRuntime *rt) {
    cl_event e = TSCLRuntimeTakeRunEvent(rt);
    if (!e) return;
    if (gTSCLRunEvent) clReleaseEvent(gTSCLRunEvent);   // in order: the newer event implies the older
    gTSCLRunEvent = e;
}

// B4 (docs/OTTIMIZZAZIONE-AIR.md §7): the release that submits a run waits for the driver's queue (the previous run):
// 1.5-7 ms per run in Maps, ~21 ms per 12 ms run in dispatchbench. A run that ends in the middle of a command buffer
// is released on the runtime's submitter thread while this queue encodes the GL commands after it (which may read
// what the run wrote: encoding them is fine, flushing them is not, tests/compute/runtime.m); the join comes before
// any flush, readback or fence. Measured on 0.11.0 it gains nothing (Maps: ~1 ms per run either way, dispatchbench and
// ctest --soak within noise), so it stays off by default: TSMTL_CL_ASYNC_END=1 turns it on (A/B).
void TSMtlComputeEndRunAsync(void) {
    static int sync = -1;
    if (sync < 0) sync = getenv("TSMTL_CL_ASYNC_END") == NULL;
    TSCLRuntime *rt = gTSCLOpenRun;
    if (!rt || sync) { TSMtlComputeEndRun(); return; }
    gTSCLOpenRun = NULL;
    if (!TSCLRuntimeInRun(rt)) return;
    if (gTSCLPendingRT && gTSCLPendingRT != rt) TSMtlComputeJoin();   // one runtime in flight at a time
    uint64_t t0 = TSNow();
    TSCLRuntimeEndRunAsync(rt);   // joins this runtime's previous asynchronous end first
    TSCLTakeEvent(rt);
    gTSCLPendingRT = rt;
    TSMtlStat(TSStatCLRuns, 1);
    TSMtlStat(TSStatCLSubmitMicros, (TSNow() - t0) / 1000);
}

void TSMtlComputeJoin(void) {
    TSCLRuntime *rt = gTSCLPendingRT;
    if (!rt) return;
    gTSCLPendingRT = NULL;
    uint64_t t0 = TSNow();
    TSCLRuntimeWaitSubmitted(rt);
    TSCLTakeEvent(rt);
    TSMtlStat(TSStatCLSubmitMicros, (TSNow() - t0) / 1000);
}

void TSMtlComputeEndRun(void) {
    TSCLRuntime *rt = gTSCLOpenRun;
    gTSCLOpenRun = NULL;
    if (rt && TSCLRuntimeInRun(rt)) {
        uint64_t t0 = TSNow();
        TSCLRuntimeEndRun(rt);   // a run in progress has no asynchronous end in flight (opening it joined)
        TSCLTakeEvent(rt);
        TSMtlStat(TSStatCLRuns, 1);
        TSMtlStat(TSStatCLSubmitMicros, (TSNow() - t0) / 1000);
    }
    TSMtlComputeJoin();
}

void *TSMtlComputeTakeRunEvent(void) {
    TSMtlComputeJoin();
    cl_event e = gTSCLRunEvent;
    gTSCLRunEvent = NULL;
    return e;
}

BOOL TSMtlComputeEventDone(void *event) {
    cl_int status = CL_COMPLETE;
    if (clGetEventInfo(event, CL_EVENT_COMMAND_EXECUTION_STATUS, sizeof status, &status, NULL) != CL_SUCCESS) return YES;
    if (status >= CL_SUBMITTED) TSCLRuntimeKickEvent(event);   // never handed to the GPU yet (deferred flush)
    return status <= CL_COMPLETE;   // CL_COMPLETE (0) or an error (negative): either way nothing more will happen
}

void TSMtlComputeEventRelease(void *event) { if (event) clReleaseEvent(event); }

void TSMtlComputeForget(TSMtlDevice *device, GLuint name, GLenum target) {
    if (!name) return;
    TSCLDeviceState *st = TSCLState(device, NO);
    if (st && st->rt) TSCLRuntimeForget(st->rt, name, target);
}

#pragma mark - GPU time per kernel (G2)

static NSMutableSet<TSCLKernel *> *gTimedKernels;
static os_unfair_lock gTimedLock = OS_UNFAIR_LOCK_INIT;

// CL thread: one enqueue of k finished (ctx owns a reference to k).
static void TSCLKernelTimed(void *ctx, uint64_t nanos) {
    TSCLKernel *k = (__bridge_transfer TSCLKernel *)ctx;
    if (!nanos) return;
    atomic_fetch_add_explicit(&k->gpuNanos, nanos, memory_order_relaxed);
    atomic_fetch_add_explicit(&k->gpuDispatches, 1, memory_order_relaxed);
    TSMtlStat(TSStatCLGPUMicros, nanos / 1000);
}

NSDictionary *TSMtlComputeKernelTimes(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    os_unfair_lock_lock(&gTimedLock);
    NSArray *kernels = gTimedKernels.allObjects;
    os_unfair_lock_unlock(&gTimedLock);
    for (TSCLKernel *k in kernels) {
        uint64_t ns = atomic_exchange(&k->gpuNanos, 0), n = atomic_exchange(&k->gpuDispatches, 0);
        if (!n) continue;
        NSArray *prev = out[k->name ?: @"?"];
        double ms = ns / 1e6 + [prev[0] doubleValue];
        out[k->name ?: @"?"] = @[ @(round(ms * 1000) / 1000), @(n + [prev[1] unsignedLongLongValue]) ];
    }
    return out;
}

static cl_int TSCLEnqueue(TSCLRuntime *rt, TSCLKernel *k, const size_t *off, const size_t *global, const size_t *local) {
    if (!gTSMtlStatsOn || !TSCLRuntimeProfiling(rt)) return TSCLRuntimeDispatch(rt, k->kernel, 3, off, global, local);
    os_unfair_lock_lock(&gTimedLock);
    if (!gTimedKernels) gTimedKernels = [NSMutableSet set];
    [gTimedKernels addObject:k];
    os_unfair_lock_unlock(&gTimedLock);
    void *ctx = (__bridge_retained void *)k;
    cl_int err = TSCLRuntimeDispatchTimed(rt, k->kernel, 3, off, global, local, TSCLKernelTimed, ctx);
    if (err != CL_SUCCESS) CFRelease(ctx);
    return err;
}

#pragma mark - Dispatch

static size_t TSPow2AtLeast(size_t n, size_t cap) {
    size_t p = 1;
    while (p < n && p < cap) p <<= 1;
    return p;
}

// C4, E3: work-group of a kernel that runs with any shape: 16x16 for 2D/3D grids (narrower grids get
// fewer rows and wider rows), up to 256 wide for 1D grids.
static void TSCLChooseShape(const size_t grid[3], size_t maxThreads, size_t tg[3]) {
    size_t limit = MAX(MIN(maxThreads, (size_t)256), (size_t)1);
    tg[2] = 1;
    if (grid[1] > 1 || grid[2] > 1) {
        tg[1] = MIN(TSPow2AtLeast(grid[1], 16), limit);
        tg[0] = MIN(TSPow2AtLeast(grid[0], limit / tg[1]), limit / tg[1]);
    } else {
        tg[0] = MIN(TSPow2AtLeast(grid[0], limit), limit);
        tg[1] = 1;
    }
}

void TSMtlCLDispatch(TSComputeDispatch *d) {
    TSMtlComputePipelineState *p = d->pipeline;
    TSCLKernel *k = p.clKernel;
    TSMtlDevice *device = (TSMtlDevice *)p.device;
    TSCLDeviceState *st = TSCLState(device, NO);
    if (!k || !st) return;
    atomic_store(&st->lastUse, TSNow());
    // A context released while idle comes back here, and the kernel with it (M4).
    if (!k->kernel && !TSCLBuild(st, k)) { TSCLSkip(k, @"%@", k->failure ?: st->failure ?: @"no OpenCL kernel"); return; }
    TSCLRuntime *rt = st->rt;
    if (!rt) { TSCLSkip(k, @"no OpenCL context"); return; }
    const TSCLArgSpec *args = k->args.bytes;
    NSUInteger nargs = k->args.length / sizeof(TSCLArgSpec);
    if (nargs > 48) { TSCLSkip(k, @"%lu resources", (unsigned long)nargs); return; }

    // Threadgroup shape. Kernels that only look at their grid position get one of our choosing and run as one
    // enqueue; others keep the app's, re-tiled only when the app asks for more than the GPU has.
    size_t tg[3] = { MAX(d->threadgroup.width, 1), MAX(d->threadgroup.height, 1), MAX(d->threadgroup.depth, 1) };
    size_t grid[3] = { d->grid.width, d->grid.height, d->grid.depth };
    BOOL single = k->guarded && TSCLRetile();
    if (single) {
        TSCLChooseShape(grid, k->maxThreads, tg);
    } else if (tg[0] * tg[1] * tg[2] > k->maxThreads) {
        if (k->barriers || k->staticThreadgroupMemory || k->shapeSensitive) {
            TSCLSkip(k, @"threadgroup %zux%zux%zu > %zu threads", tg[0], tg[1], tg[2], k->maxThreads);
            return;
        }
        if (grid[1] > 1) { tg[0] = 16; tg[1] = MIN(k->maxThreads / 16, (size_t)16); tg[2] = 1; }
        else { tg[0] = k->maxThreads; tg[1] = tg[2] = 1; }
    }

    // GL objects first: resolving them can upload CPU-side data (GL commands), which must precede the acquire.
    TSCLGLObject objs[64];
    NSUInteger objArg[64];
    cl_mem argMem[64] = { 0 };
    cl_uint nobj = 0, nullMask = 0;
    for (NSUInteger i = 0; i < nargs; i++) {
        const TSCLArgSpec *a = &args[i];
        if (a->kind == TSCLArgBuffer) {
            TSMtlBuffer *b = (TSMtlBuffer *)d->buffers[a->slot];
            if (![b isKindOfClass:[TSMtlBuffer class]] || !b.length) { TSCLSkip(k, @"no buffer at index %u", a->slot); return; }
            GLuint name = [b glBuffer];
            if (a->written) [b prepareGPUWrite];
            objArg[nobj] = i;
            objs[nobj++] = (TSCLGLObject){ name, 0, 0 };
        } else if (a->kind == TSCLArgTexture) {
            TSMtlTexture *t = (TSMtlTexture *)d->textures[a->slot];
            if (![t isKindOfClass:[TSMtlTexture class]]) {
                if (!a->nullable) { TSCLSkip(k, @"no texture at index %u", a->slot); return; }
                if (!(argMem[i] = TSCLNullImage(st, a))) { TSCLSkip(k, @"no placeholder for the unbound texture %u", a->slot); return; }
                nullMask |= 1u << a->slot;
                continue;
            }
            if (a->lod && t.mipmapLevelCount > 1) {
                TSCLSkip(k, @"texture %u has %lu mip levels and the kernel uses a level other than 0 (OpenCL sees level 0 only)",
                         a->slot, (unsigned long)t.mipmapLevelCount);
                return;
            }
            GLenum target = 0;
            GLuint name = [t glTextureForCompute:&target];
            if (!name || !TSCLTargetFits(a, target)) {
                TSCLSkip(k, @"texture %u (type %lu, format %lu) cannot be an OpenCL image of this shape", a->slot,
                         (unsigned long)t.textureType, (unsigned long)t.pixelFormat);
                return;
            }
            objArg[nobj] = i;
            objs[nobj++] = (TSCLGLObject){ name, target, 0 };
        }
    }
    cl_mem mems[64];
    gTSCLOpenRun = rt;
    cl_int err = TSCLRuntimeUse(rt, objs, nobj, mems);
    if (err != CL_SUCCESS) { TSCLSkip(k, @"GL objects not shareable with OpenCL (%d)", err); return; }
    for (cl_uint j = 0; j < nobj; j++) argMem[objArg[j]] = mems[j];

    TSCLArgCache *cache = TSCLArgsFor(k, rt);
    cl_uint4 gridArg = {{ (cl_uint)grid[0], (cl_uint)grid[1], (cl_uint)grid[2], 0 }};
    cl_uint4 tgArg = {{ (cl_uint)tg[0], (cl_uint)tg[1], (cl_uint)tg[2], 0 }};
    cl_uint4 groups = {{ (cl_uint)((grid[0] + tg[0] - 1) / tg[0]), (cl_uint)((grid[1] + tg[1] - 1) / tg[1]),
                         (cl_uint)((grid[2] + tg[2] - 1) / tg[2]), 0 }};
    cl_uint4 zero = {{ 0 }};
    err = TSCLSetArg(k, cache, 0, sizeof gridArg, &gridArg);
    if (err == CL_SUCCESS) err = TSCLSetArg(k, cache, 1, sizeof zero, &zero);
    if (err == CL_SUCCESS) err = TSCLSetArg(k, cache, 2, sizeof groups, &groups);
    if (err == CL_SUCCESS) err = TSCLSetArg(k, cache, 3, sizeof tgArg, &tgArg);
    if (err == CL_SUCCESS) err = TSCLSetArg(k, cache, 4, sizeof nullMask, &nullMask);
    cl_uint ai = 5;
    for (NSUInteger i = 0; i < nargs && err == CL_SUCCESS; i++) {
        const TSCLArgSpec *a = &args[i];
        switch (a->kind) {
        case TSCLArgBuffer: {
            cl_uint off = (cl_uint)d->offsets[a->slot];
            err = TSCLSetArg(k, cache, ai++, sizeof(cl_mem), &argMem[i]);
            if (err == CL_SUCCESS) err = TSCLSetArg(k, cache, ai++, sizeof off, &off);
            break;
        }
        case TSCLArgLocal: {
            size_t size = (MAX(d->threadgroupMemory[a->slot], (NSUInteger)16) + 15) & ~(size_t)15;
            err = TSCLSetArg(k, cache, ai++, size, NULL);
            break;
        }
        case TSCLArgTexture:
            err = TSCLSetArg(k, cache, ai++, sizeof(cl_mem), &argMem[i]);
            if (err == CL_SUCCESS && a->readWrite) err = TSCLSetArg(k, cache, ai++, sizeof(cl_mem), &argMem[i]);
            break;
        case TSCLArgSampler: {
            cl_uint am = 0;
            cl_sampler s = TSCLSamplerFor(st, d->samplers[a->slot], &am);
            err = s ? TSCLSetArg(k, cache, ai++, sizeof s, &s) : CL_INVALID_SAMPLER;
            if (err == CL_SUCCESS) err = TSCLSetArg(k, cache, ai++, sizeof am, &am);
            break;
        }
        }
    }
    if (err != CL_SUCCESS) { TSCLSkip(k, @"clSetKernelArg failed (%d)", err); return; }

    if (single) {
        size_t off[3] = { 0, 0, 0 }, global[3];
        for (int i = 0; i < 3; i++) global[i] = (grid[i] + tg[i] - 1) / tg[i] * tg[i];
        err = TSCLEnqueue(rt, k, off, global, tg);
        if (err != CL_SUCCESS) { TSCLSkip(k, @"enqueue failed (%d)", err); return; }
    } else {
        // Uniform part, then the edges of each dimension with work-groups as large as what is left (Metal's
        // non-uniform threadgroups); ts_goff carries the threadgroup index of an edge's first group.
        size_t full[3], rem[3];
        for (int i = 0; i < 3; i++) { full[i] = grid[i] / tg[i] * tg[i]; rem[i] = grid[i] - full[i]; }
        for (int pz = 0; pz < 2; pz++)
            for (int py = 0; py < 2; py++)
                for (int px = 0; px < 2; px++) {
                    int part[3] = { px, py, pz };
                    size_t off[3], global[3], local[3];
                    cl_uint4 goff = {{ 0 }};
                    BOOL empty = NO;
                    for (int i = 0; i < 3; i++) {
                        off[i] = part[i] ? full[i] : 0;
                        global[i] = part[i] ? rem[i] : full[i];
                        local[i] = part[i] ? rem[i] : tg[i];
                        goff.s[i] = part[i] ? (cl_uint)(full[i] / tg[i]) : 0;
                        if (!global[i]) empty = YES;
                    }
                    if (empty) continue;
                    TSCLSetArg(k, cache, 1, sizeof goff, &goff);
                    err = TSCLEnqueue(rt, k, off, global, local);
                    if (err != CL_SUCCESS) { TSCLSkip(k, @"enqueue failed (%d)", err); return; }
                }
        TSCLSetArg(k, cache, 1, sizeof zero, &zero);
    }

    // What the kernel may have written is now newer in GL than in the CPU copies.
    for (NSUInteger i = 0; i < nargs; i++) {
        const TSCLArgSpec *a = &args[i];
        if (!a->written || (nullMask & (1u << a->slot) && a->kind == TSCLArgTexture)) continue;
        if (a->kind == TSCLArgBuffer) [(TSMtlBuffer *)d->buffers[a->slot] didWriteGPU];
        else if (a->kind == TSCLArgTexture) [(TSMtlTexture *)d->textures[a->slot] didRenderGL];
    }
    TSMtlStat(TSStatDispatches, 1);
}
