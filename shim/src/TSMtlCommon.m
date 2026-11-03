// TeraScale Metal Shim - catch-all forwarding, logging, pixel formats, inert objects.
#import "TSPrivate.h"
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>

int gTSMtlLogOn, gTSMtlTraceOn;

__attribute__((constructor)) static void TSMtlLogInit(void) {
    const char *v = getenv("TSMTL_LOG");
    gTSMtlLogOn = v && *v && *v != '0';
    v = getenv("TSMTL_TRACE");
    gTSMtlTraceOn = v && *v && *v != '0';
}

int gTSMtlDrawTrace, gTSMtlDrawTraceArmed, gTSMtlDrawTraceHeavy;

__attribute__((constructor)) static void TSMtlDrawTraceInit(void) {
    gTSMtlDrawTraceArmed = getenv("TSMTL_DRAW_TRACE") != NULL;
    const char *heavy = getenv("TSMTL_DRAW_TRACE_HEAVY");
    gTSMtlDrawTraceHeavy = !heavy ? 0 : atoi(heavy) == 1 ? ~0 : atoi(heavy);
}

void TSMtlDrawTraceSaveBMP(const char *name, int32_t w, int32_t h, const void *base, size_t pitch) {
    static const char *dir;
    static int checked;
    if (!checked) { checked = 1; dir = getenv("TSMTL_DRAW_TRACE_DIR"); }
    if (!dir) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f) return;
    // BITMAPFILEHEADER + BITMAPINFOHEADER, 32 bpp BGRA, top-down (negative height).
    uint32_t size = 54 + (uint32_t)(w * h * 4);
    uint8_t hdr[54] = { 'B', 'M' };
    memcpy(hdr + 2, &size, 4);
    uint32_t off = 54, info = 40; int32_t nh = -h; uint16_t planes = 1, bpp = 32;
    memcpy(hdr + 10, &off, 4); memcpy(hdr + 14, &info, 4); memcpy(hdr + 18, &w, 4); memcpy(hdr + 22, &nh, 4);
    memcpy(hdr + 26, &planes, 2); memcpy(hdr + 28, &bpp, 2);
    fwrite(hdr, 1, sizeof hdr, f);
    for (int32_t y = 0; y < h; y++) fwrite((const uint8_t *)base + y * pitch, 4, (size_t)w, f);
    fclose(f);
    fprintf(stderr, "[TSDraw]   saved %s\n", path);
}

void TSMtlDrawTraceTick(void) {
    static const char *trigger;
    static int left, checked;
    if (!checked) { checked = 1; trigger = getenv("TSMTL_DRAW_TRACE"); }
    if (!trigger) return;
    if (left > 0) {
        gTSMtlDrawTrace = 1;
        fprintf(stderr, "[TSDraw] ---- command buffer (%d left)\n", --left);
        return;
    }
    gTSMtlDrawTrace = 0;
    FILE *f = fopen(trigger, "r");
    if (!f) return;
    // The file may hold the number of command buffers to trace.
    int count = 0;
    if (fscanf(f, "%d", &count) != 1) count = 0;
    fclose(f);
    unlink(trigger);
    const char *n = getenv("TSMTL_DRAW_TRACE_CBS");
    left = count > 0 ? count : n ? atoi(n) : 3;
    if (left > 0) TSMtlDrawTraceTick();
}

void TSMtlTraceOnce(NSString *fmt, ...) {
    if (!gTSMtlTraceOn) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSMutableSet<NSString *> *seen;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    if (!seen) seen = [NSMutableSet set];
    BOOL first = seen.count < 500 && ![seen containsObject:msg];
    if (first) [seen addObject:msg];
    os_unfair_lock_unlock(&lock);
    if (first) fprintf(stderr, "[TSMtl %d] %s\n", getpid(), msg.UTF8String);
}

static os_log_t TSLogHandle(TSLogCategory c) {
    static os_log_t handles[TSLogCategoryCount];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char *names[TSLogCategoryCount] = { "general", "warning", "error", "unimplemented", "policy", "stats", "compute", "glass", "swift" };
        for (int i = 0; i < TSLogCategoryCount; i++) handles[i] = os_log_create("com.terascale.mtlshim", names[i]);
    });
    return handles[c];
}

void TSMtlLogAt(TSLogCategory category, _Atomic uint32_t *site, NSString *fmt, ...) {
    static const os_log_type_t types[TSLogCategoryCount] = {
        OS_LOG_TYPE_INFO, OS_LOG_TYPE_DEFAULT, OS_LOG_TYPE_ERROR, OS_LOG_TYPE_DEFAULT, OS_LOG_TYPE_DEFAULT, OS_LOG_TYPE_DEFAULT,
        OS_LOG_TYPE_DEFAULT, OS_LOG_TYPE_DEFAULT, OS_LOG_TYPE_DEFAULT };
    os_log_t log = TSLogHandle(category);
    if (!gTSMtlLogOn && !os_log_type_enabled(log, types[category])) return;
    uint32_t n = site ? atomic_fetch_add_explicit(site, 1, memory_order_relaxed) : 0;
    if (n > TS_LOG_SITE_LIMIT) return;
    NSString *msg;
    if (n == TS_LOG_SITE_LIMIT) {
        msg = @"(further messages from this point of the driver are suppressed in this process)";
    } else {
        va_list ap;
        va_start(ap, fmt);
        msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
    }
    os_log_with_type(log, types[category], "%{public}s", msg.UTF8String);
    if (gTSMtlLogOn && category != TSLogStats) {
        static const char *tags[TSLogCategoryCount] = { "", "warning: ", "error: ", "unimplemented: ", "", "", "compute: ", "glass: " };
        fprintf(stderr, "[TSMtl] %s%s\n", tags[category], msg.UTF8String);
    }
}

#pragma mark - Catch-all

static BOOL TSFindInProtocol(Protocol *p, SEL sel, BOOL requiredOnly, struct objc_method_description *out) {
    for (int req = 1; req >= (requiredOnly ? 1 : 0); req--) {
        struct objc_method_description d = protocol_getMethodDescription(p, sel, req, YES);
        if (d.name) { *out = d; return YES; }
    }
    unsigned n;
    Protocol *__unsafe_unretained *adopted = protocol_copyProtocolList(p, &n);
    BOOL found = NO;
    for (unsigned i = 0; i < n && !found; i++) found = TSFindInProtocol(adopted[i], sel, requiredOnly, out);
    free(adopted);
    return found;
}

static NSArray<Protocol *> *TSProtocolsOf(id self) {
    if ([self isKindOfClass:[TSMtlInert class]]) return object_getIvar(self, class_getInstanceVariable([TSMtlInert class], "_protocols"));
    NSMutableArray *all = [NSMutableArray array];
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        unsigned n;
        Protocol *__unsafe_unretained *list = class_copyProtocolList(c, &n);
        for (unsigned i = 0; i < n; i++) [all addObject:list[i]];
        free(list);
    }
    return all;
}

static BOOL TSFindSelector(id self, SEL sel, BOOL requiredOnly, struct objc_method_description *out) {
    for (Protocol *p in TSProtocolsOf(self))
        if (TSFindInProtocol(p, sel, requiredOnly, out)) return YES;
    return NO;
}

static NSMethodSignature *TSCatchAllSignature(id self, SEL _cmd, SEL sel) {
    struct objc_method_description d;
    if (TSFindSelector(self, sel, NO, &d)) return [NSMethodSignature signatureWithObjCTypes:d.types];
    // Unknown (probably private) selector: answer as if it returned an integer zero.
    return [NSMethodSignature signatureWithObjCTypes:"Q@:"];
}

static void TSCatchAllForward(id self, SEL _cmd, NSInvocation *inv) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableSet *seen;
    // Inert objects stand in for a protocol: name the protocol, not TSMtlInert.
    NSString *owner = [self isKindOfClass:[TSMtlInert class]]
        ? [[TSProtocolsOf(self) valueForKey:@"description"] componentsJoinedByString:@","] : @(object_getClassName(self));
    NSString *key = [NSString stringWithFormat:@"-[%@ %s]", owner, sel_getName(inv.selector)];
    os_unfair_lock_lock(&lock);
    if (!seen) seen = [NSMutableSet set];
    BOOL first = seen.count < 500 && ![seen containsObject:key];
    if (first) [seen addObject:key];
    os_unfair_lock_unlock(&lock);
    if (first) TSMtlLogAt(TSLogUnimplemented, NULL, @"%@: not implemented, returns zero/nil", key);

    NSUInteger len = inv.methodSignature.methodReturnLength;
    if (len) {
        void *zero = calloc(1, len);
        [inv setReturnValue:zero];
        free(zero);
    }
}

static BOOL TSCatchAllResponds(id self, SEL _cmd, SEL sel) {
    if (class_respondsToSelector(object_getClass(self), sel)) return YES;
    // Required protocol methods are always "implemented" (by the catch-all);
    // optional ones are reported missing so apps take their fallback paths.
    struct objc_method_description d;
    return TSFindSelector(self, sel, YES, &d);
}

void TSMtlInstallCatchAll(Class cls) {
    class_addMethod(cls, @selector(methodSignatureForSelector:), (IMP)TSCatchAllSignature, "@@::");
    class_addMethod(cls, @selector(forwardInvocation:), (IMP)TSCatchAllForward, "v@:@");
    class_addMethod(cls, @selector(respondsToSelector:), (IMP)TSCatchAllResponds, "c@::");
}

#pragma mark - Inert objects

@implementation TSMtlInert {
    NSArray<Protocol *> *_protocols;
}
+ (void)initialize { if (self == [TSMtlInert class]) TSMtlInstallCatchAll(self); }
- (instancetype)initWithDevice:(id<MTLDevice>)device protocols:(NSArray<Protocol *> *)protocols {
    if ((self = [super init])) { _device = device; _protocols = [protocols copy]; }
    return self;
}
- (BOOL)conformsToProtocol:(Protocol *)protocol {
    for (Protocol *p in _protocols)
        if (protocol_isEqual(p, protocol) || protocol_conformsToProtocol(p, protocol)) return YES;
    return [super conformsToProtocol:protocol];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<TSMtlInert %p %@ label=%@>", self,
            [[_protocols valueForKey:@"description"] componentsJoinedByString:@","], self.label];
}
@end

#pragma mark - Pixel formats

TSPixelFormatInfo TSPixelFormatGetInfo(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Unorm_sRGB:
    case MTLPixelFormatR8Snorm: case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatStencil8:
        return (TSPixelFormatInfo){1, 1, 1};
    case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint:
    case MTLPixelFormatR16Float: case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Unorm_sRGB: case MTLPixelFormatRG8Snorm:
    case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint: case MTLPixelFormatB5G6R5Unorm: case MTLPixelFormatA1BGR5Unorm:
    case MTLPixelFormatABGR4Unorm: case MTLPixelFormatBGR5A1Unorm: case MTLPixelFormatDepth16Unorm:
        return (TSPixelFormatInfo){2, 1, 1};
    case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint:
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float:
    case MTLPixelFormatDepth32Float_Stencil8: case MTLPixelFormatBGRA10_XR: case MTLPixelFormatBGRA10_XR_sRGB:
        return (TSPixelFormatInfo){8, 1, 1};
    case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float:
        return (TSPixelFormatInfo){16, 1, 1};
    case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB: case MTLPixelFormatBC4_RUnorm: case MTLPixelFormatBC4_RSnorm:
        return (TSPixelFormatInfo){8, 4, 4};
    case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB: case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB:
    case MTLPixelFormatBC5_RGUnorm: case MTLPixelFormatBC5_RGSnorm: case MTLPixelFormatBC6H_RGBFloat: case MTLPixelFormatBC6H_RGBUfloat:
    case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB:
        return (TSPixelFormatInfo){16, 4, 4};
    default: // 32-bit formats (RGBA8, BGRA8, RGB10A2, RG16, R32, Depth32Float, Depth24Stencil8, ...) and unknown ones
        return (TSPixelFormatInfo){4, 1, 1};
    }
}

#pragma mark - Statistics

int gTSMtlStatsOn;
_Atomic uint64_t gTSMtlStats[TSStatCount];
_Atomic int64_t gTSMtlAllocatedBytes;

// TSMTL_STATS=1: per-interval values on stderr every 5 seconds (counters are cumulative,
// so the lease emitter in TSMtlSystem.m can read them at the same time).
__attribute__((constructor)) static void TSMtlStatsInit(void) {
    if (!getenv("TSMTL_STATS")) return;
    gTSMtlStatsOn |= TSStatsByEnv;
    static const char *names[TSStatCount] = { "draws", "passes", "cmdbufs", "buffer upload KB", "texture upload KB", "readbacks",
                                              "translations", "disk cache hits", "program links", "program hits",
                                              "iosurface copy KB", "iosurface writes (~frames)", "gpu-queue busy ms", "iosurface GL binds",
                                              "nextDrawable wait ms", "presents", "pipelines", "fallback pipelines",
                                              "iosurface rebinds (seed changed)", "pipeline create ms", "link ms", "warm-up ms",
                                              "translate ms", "variant links", "programs drawn",
                                              "pipeline sync ms", "dispatches", "compute rejected", "cl runs", "cl submit ms",
                                              "cl builds", "dispatches recorded", "dispatches skipped", "dispatches inert",
                                              "cl binary hits", "cl gpu ms", "nextDrawable blocks", "mslbundle hits",
                                              "unaligned-buffer variants", "predicted variants", "framebuffer hits" };
    static uint64_t last[TSStatCount];
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        char line[1024];
        int n = snprintf(line, sizeof line, "[TSMtl %d] stats/5s:", getpid());
        uint64_t any = 0;
        for (int i = 0; i < TSStatCount; i++) {
            uint64_t now = atomic_load_explicit(&gTSMtlStats[i], memory_order_relaxed), v = now - last[i];
            last[i] = now;
            if (i < TSStatPipelines || i > TSStatSurfaceRebinds) any |= v;
            if (i == TSStatBufferUploadBytes || i == TSStatTextureUploadBytes || i == TSStatSurfaceCopyBytes) v /= 1024;
            if (i == TSStatGPUBusyMicros || i == TSStatDrawableWaitMicros || (i >= TSStatPipelineMicros && i <= TSStatTranslateMicros) ||
                i == TSStatPipelineSyncMicros || i == TSStatCLSubmitMicros || i == TSStatCLGPUMicros) v /= 1000;
            n += snprintf(line + n, sizeof line - n, " %s=%llu", names[i], (unsigned long long)v);
        }
        if (any) {   // idle intervals and processes without a device stay quiet
            fprintf(stderr, "%s\n", line);
            NSDictionary *kernels = TSMtlComputeKernelTimes();
            for (NSString *name in [kernels.allKeys sortedArrayUsingSelector:@selector(compare:)])
                fprintf(stderr, "[TSMtl %d]   cl kernel %s: %.3f ms GPU in %llu enqueues\n", getpid(), name.UTF8String,
                        [kernels[name][0] doubleValue], [kernels[name][1] unsignedLongLongValue]);
        }
    });
    dispatch_resume(timer);
}
