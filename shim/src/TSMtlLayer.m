// TeraScale Metal Shim - CAMetalLayer tuning for layers that present our drawables.
// Presentation through CoreAnimation takes ~27 ms from commit to screen here (measured with
// build/window TIMELINE=1), against ~16 ms on a real Metal driver. With 2 drawables a layer can
// then present only every other refresh (31 fps measured, 53 fps with 3), so layers on our device
// get at least TSMTL_DRAWABLES (default 3) drawables. Other layers in the process are untouched.
//
// CoreAnimation's own Metal renderer (in-process CA, e.g. Terminal, Safari, TextEdit) draws with
// a generic uber pipeline while the specialized one compiles asynchronously. The generic
// fixed_frag_* variant switches at runtime over every sampling routine and colour opcode, so
// once inlined and unrolled for GLSL it is 1.6 MB / 70k lines: ~7.5 s to compile and link on
// TeraScale when idle and close to a minute under load, with the CA render thread (and through
// it the main thread) blocked in -newRenderPipelineStateWithDescriptor:. CA's own debug option
// CA_DISABLE_GENERIC_SHADERS makes it create only the small specialized pipelines (~0.2 s each).
// An explicit CA_DISABLE/FORCE_GENERIC_SHADERS in the environment wins; TSMTL_GENERIC_SHADERS=1
// keeps CA's default.
#import "TSPrivate.h"
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static void TSDisableCAGenericShaders(void) {
    if (getenv("TSMTL_GENERIC_SHADERS") || getenv("CA_DISABLE_GENERIC_SHADERS") || getenv("CA_FORCE_GENERIC_SHADERS")) return;
    const char *(*name)(unsigned) = dlsym(RTLD_DEFAULT, "CAGetDebugOptionEnvVariableName");
    void (*set)(unsigned, uint8_t) = dlsym(RTLD_DEFAULT, "CASetDebugOption");
    if (!name || !set) return;
    for (unsigned i = 0; i <= 0x101; i++) {
        const char *n = name(i);
        if (n && !strcmp(n, "CA_DISABLE_GENERIC_SHADERS")) {
            set(i, 1);
            TSMtlLog(@"CoreAnimation generic shaders disabled (debug option %u)", i);
            return;
        }
    }
    TSMtlWarn(@"CA_DISABLE_GENERIC_SHADERS not found, CoreAnimation may build its generic pipeline");
}

static NSUInteger TSMinDrawables(void) {
    static NSUInteger n;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *e = getenv("TSMTL_DRAWABLES");
        n = e ? (NSUInteger)MAX(MIN(atoi(e), 3), 2) : 3;
    });
    return n;
}

// X1 (docs/OTTIMIZZAZIONE-COMPUTE.md): Maps spends up to 1.1 s per second in nextDrawable with the GPU 1-5 % busy,
// i.e. drawables come back late from presentation. TSMTL_DISPLAY_SYNC=0 turns displaySyncEnabled off on our
// layers (presents do not wait for the next vblank, drawables recycle sooner; A/B knob, default unchanged).
static int TSDisplaySync(void) {
    static int v = -2;
    if (v == -2) v = getenv("TSMTL_DISPLAY_SYNC") ? atoi(getenv("TSMTL_DISPLAY_SYNC")) : -1;
    return v;
}

static void (*gSetMaxDrawables)(id, SEL, NSUInteger);
static void (*gSetDevice)(id, SEL, id);
static id (*gNextDrawable)(id, SEL);

// TSMTL_STATS: time apps spend blocked in nextDrawable (presentation backlog).
static id TSNextDrawable(CAMetalLayer *self, SEL _cmd) {
    if (gTSMtlTraceOn)
        TSMtlTraceOnce(@"CAMetalLayer %p: %.0fx%.0f drawables %lu displaySync %d withTransaction %d opaque %d fmt %lu", self,
                       self.drawableSize.width, self.drawableSize.height, (unsigned long)self.maximumDrawableCount, self.displaySyncEnabled,
                       self.presentsWithTransaction, self.opaque, (unsigned long)self.pixelFormat);
    if (!gTSMtlStatsOn) return gNextDrawable(self, _cmd);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    id d = gNextDrawable(self, _cmd);
    uint64_t us = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000;
    TSMtlStat(TSStatDrawableWaitMicros, us);
    if (us >= 2000) TSMtlStat(TSStatDrawableBlocks, 1);   // waits that cost a frame's worth of time, not a lock
    return d;
}

static void TSSetMaximumDrawableCount(CAMetalLayer *self, SEL _cmd, NSUInteger count) {
    if ([self.device isKindOfClass:[TSMtlDevice class]] && count < TSMinDrawables()) {
        TSMtlLog(@"CAMetalLayer %p asks for %lu drawables, using %lu", self, (unsigned long)count, (unsigned long)TSMinDrawables());
        count = TSMinDrawables();
    }
    gSetMaxDrawables(self, _cmd, count);
}

static void TSSetDevice(CAMetalLayer *self, SEL _cmd, id device) {
    gSetDevice(self, _cmd, device);
    if (![device isKindOfClass:[TSMtlDevice class]]) return;
    if (self.maximumDrawableCount < TSMinDrawables()) gSetMaxDrawables(self, @selector(setMaximumDrawableCount:), TSMinDrawables());
    if (TSDisplaySync() >= 0) self.displaySyncEnabled = TSDisplaySync() != 0;
}

void TSMtlInstallLayerTuning(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TSDisableCAGenericShaders();
        Class cls = NSClassFromString(@"CAMetalLayer");
        Method m1 = cls ? class_getInstanceMethod(cls, @selector(setMaximumDrawableCount:)) : NULL;
        Method m2 = cls ? class_getInstanceMethod(cls, @selector(setDevice:)) : NULL;
        if (!m1 || !m2) return;
        gSetMaxDrawables = (void *)method_setImplementation(m1, (IMP)TSSetMaximumDrawableCount);
        gSetDevice = (void *)method_setImplementation(m2, (IMP)TSSetDevice);
        Method m3 = class_getInstanceMethod(cls, @selector(nextDrawable));
        if (m3) gNextDrawable = (void *)method_setImplementation(m3, (IMP)TSNextDrawable);
    });
}
