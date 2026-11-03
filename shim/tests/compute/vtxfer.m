// TeraScale Compute, B1 of docs/OTTIMIZZAZIONE-COMPUTE.md: VideoToolbox's pixel transfer (VTPixelTransferSession)
// on the shim device, checked against VideoToolbox's own software path and an analytic CPU reference.
// VTMTSComputeFunction (the only compute kernel Apple Maps runs) is VT's Metal transfer kernel: when VT picks the
// Metal path on our device it runs on the OpenCL path (TSMtlComputeCL.m + TSAirOpenCL.m).
//
// How VT finds its device: it calls MTLCreateSystemDefaultDevice / MTLCopyAllDevices (VideoToolbox imports both).
// Without the shim both return nothing on this Mac and VT converts in software. So the test runs itself again
// with DYLD_INSERT_LIBRARIES=build/libTSMetalInject.dylib (the interposer answers with the shim device), unless
// --no-shim. The binary does not link libTSMetal: the shim's symbols come from the injected dylib (one copy of
// the TSMtl classes and counters), or from build/libTSMetal.dylib dlopen'ed for --queue.
//
// Per case, two sessions on the same source: "gpu" (VT's default choice; Metal if VT takes it) and "sw"
// (EnableGPUAcceleratedTransfer = false). Checks: gpu vs sw, and both vs an analytic BT.601 reference (smooth
// content, so chroma siting and scaling filters stay within tolerance). The shim's counters (dispatches, recorded,
// skipped, inert, CL runs, passes) are read around each gpu transfer and decide whether VTMTSComputeFunction ran.
//
// Build:
//   clang -fobjc-arc -O1 -g -Wall -mmacosx-version-min=26.0 -DTS_SOURCE_DIR=\"$PWD\" -Isrc -framework Foundation \
//     -framework Metal -framework IOSurface -framework CoreVideo -framework VideoToolbox tests/compute/vtxfer.m -o build/vtxfer
// Run:   build/vtxfer                 (re-runs itself with the injection dylib, TSMTL_COMPUTE=1 unless set)
//        build/vtxfer --no-shim       (no Metal device: what VT does without the shim, software only)
//        build/vtxfer --queue         (no injection: our queue handed to VT via kVTPixelTransferPropertyKey_MetalSubmissionQueue)
//        build/vtxfer --save DIR      (writes every result as PPM/PGM for tools/imgdiff or a viewer)
//        build/vtxfer --require-metal (exit 1 when VT never ran a Metal kernel on our device)
// Logs: TSMTL_LOG=1 TSMTL_COMPUTE=1 build/vtxfer 2>&1 | grep "compute:"
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <spawn.h>
#import <mach-o/dyld.h>
#import <math.h>
#import "TSPrivate.h"   // TSStat indices only; the counters are looked up with dlsym

extern char **environ;

#pragma mark - Shim access (dlsym: injected dylib or dlopen'ed libTSMetal)

typedef id<MTLDevice> (*CreateDeviceFn)(void);
static _Atomic uint64_t *gStats;     // gTSMtlStats
static int *gStatsOn;                // gTSMtlStatsOn
static const char *gShimSource = "none";

static BOOL bindShim(BOOL allowDlopen) {
    if (!dlsym(RTLD_DEFAULT, "TSMtlCreateDevice")) {
        if (!allowDlopen) return NO;
        if (!dlopen(TS_SOURCE_DIR "/build/libTSMetal.dylib", RTLD_NOW | RTLD_GLOBAL)) {
            printf("dlopen libTSMetal: %s\n", dlerror());
            return NO;
        }
        gShimSource = "build/libTSMetal.dylib (dlopen)";
    } else gShimSource = "build/libTSMetalInject.dylib (DYLD_INSERT_LIBRARIES)";
    gStats = dlsym(RTLD_DEFAULT, "gTSMtlStats");
    gStatsOn = dlsym(RTLD_DEFAULT, "gTSMtlStatsOn");
    if (gStatsOn) *gStatsOn |= TSStatsByEnv;   // count dispatches even without TSMTL_STATS
    return gStats != NULL;
}

static const TSStat kWatched[] = { TSStatComputeRecorded, TSStatDispatches, TSStatComputeSkipped, TSStatComputeInert,
                                   TSStatCLRuns, TSStatCLBuilds, TSStatPasses, TSStatDraws, TSStatPipelines };
static const char *kWatchedNames[] = { "recorded", "dispatches", "skipped", "inert", "clRuns", "clBuilds",
                                       "passes", "draws", "pipelines" };
enum { kNWatched = sizeof kWatched / sizeof kWatched[0] };
typedef struct { uint64_t v[kNWatched]; } Counters;
static Counters readCounters(void) {
    Counters c = {0};
    if (gStats) for (int i = 0; i < kNWatched; i++) c.v[i] = atomic_load(&gStats[kWatched[i]]);
    return c;
}
static Counters diffCounters(Counters a, Counters b) {
    Counters d;
    for (int i = 0; i < kNWatched; i++) d.v[i] = b.v[i] - a.v[i];
    return d;
}
static NSString *countersString(Counters d) {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < kNWatched; i++) [s appendFormat:@"%s%s %llu", i ? ", " : "", kWatchedNames[i], d.v[i]];
    return s;
}
#define C_RECORDED 0
#define C_DISPATCHES 1
#define C_SKIPPED 2
#define C_INERT 3
#define C_CLRUNS 4

#pragma mark - Pixel buffers

static CVPixelBufferRef makeBuffer(OSType format, size_t w, size_t h) {
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                             (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(NULL, w, h, format, (__bridge CFDictionaryRef)attrs, &pb);
    if (r != kCVReturnSuccess) { printf("CVPixelBufferCreate %.4s %zux%zu: %d\n", (char *)&(OSType){CFSwapInt32HostToBig(format)}, w, h, r); exit(2); }
    // BT.601 matrix, BT.709 primaries and transfer function on every buffer: no colour matching, only the matrix.
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    if (format != kCVPixelFormatType_32BGRA)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, kCVAttachmentMode_ShouldPropagate);
    return pb;
}

static void fillBuffer(CVPixelBufferRef pb, uint8_t value) {
    CVPixelBufferLockBaseAddress(pb, 0);
    size_t planes = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetPlaneCount(pb) : 1;
    for (size_t p = 0; p < planes; p++) {
        uint8_t *base = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetBaseAddressOfPlane(pb, p) : CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetBytesPerRowOfPlane(pb, p) : CVPixelBufferGetBytesPerRow(pb);
        size_t h = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetHeightOfPlane(pb, p) : CVPixelBufferGetHeight(pb);
        memset(base, value, bpr * h);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

// Smooth test image in [0,1] RGB at normalized coordinates (u,v): gradients plus low-frequency waves, full range
// of hues, no edges sharper than the 2x2 chroma blocks or the scaling filters can follow.
static void pattern(double u, double v, double rgb[3]) {
    rgb[0] = 0.5 + 0.45 * sin(2 * M_PI * (u * 1.0 + v * 0.3));
    rgb[1] = 0.05 + 0.9 * v;
    rgb[2] = 0.5 + 0.45 * cos(2 * M_PI * (u * 0.7 - v * 1.1));
}

static double clamp01(double x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
static uint8_t q8(double x) { return (uint8_t)lrint(x < 0 ? 0 : x > 255 ? 255 : x); }

// BT.601: Y' Cb Cr in [0,1] / [-0.5,0.5] <-> R'G'B' in [0,1]
static void rgbToYcc(const double rgb[3], double *y, double *cb, double *cr) {
    *y = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
    *cb = (rgb[2] - *y) / 1.772;
    *cr = (rgb[0] - *y) / 1.402;
}
static void yccToRgb(double y, double cb, double cr, double rgb[3]) {
    rgb[0] = clamp01(y + 1.402 * cr);
    rgb[1] = clamp01(y - 0.344136 * cb - 0.714136 * cr);
    rgb[2] = clamp01(y + 1.772 * cb);
}
static BOOL fullRange(OSType f) { return f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange; }
static double encY(double y, BOOL full) { return full ? y * 255 : 16 + 219 * y; }
static double encC(double c, BOOL full) { return full ? 128 + 255 * c : 128 + 224 * c; }
static double decY(double y, BOOL full) { return full ? y / 255 : (y - 16) / 219; }
static double decC(double c, BOOL full) { return full ? (c - 128) / 255 : (c - 128) / 224; }

// Writes the pattern into a BGRA or 420 biplanar buffer (chroma = average of the 2x2 block, left/centre siting).
static void drawPattern(CVPixelBufferRef pb) {
    OSType f = CVPixelBufferGetPixelFormatType(pb);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    if (f == kCVPixelFormatType_32BGRA) {
        uint8_t *base = CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++) {
                double rgb[3];
                pattern((x + 0.5) / w, (y + 0.5) / h, rgb);
                uint8_t *p = base + y * bpr + x * 4;
                p[0] = q8(rgb[2] * 255); p[1] = q8(rgb[1] * 255); p[2] = q8(rgb[0] * 255); p[3] = 255;
            }
    } else {
        BOOL full = fullRange(f);
        uint8_t *Y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *C = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++) {
                double rgb[3], yy, cb, cr;
                pattern((x + 0.5) / w, (y + 0.5) / h, rgb);
                rgbToYcc(rgb, &yy, &cb, &cr);
                Y[y * ybpr + x] = q8(encY(yy, full));
            }
        for (size_t y = 0; y < h / 2; y++)
            for (size_t x = 0; x < w / 2; x++) {
                double scb = 0, scr = 0;
                for (int j = 0; j < 2; j++)
                    for (int i = 0; i < 2; i++) {
                        double rgb[3], yy, cb, cr;
                        pattern((2 * x + i + 0.5) / w, (2 * y + j + 0.5) / h, rgb);
                        rgbToYcc(rgb, &yy, &cb, &cr);
                        scb += cb; scr += cr;
                    }
                C[y * cbpr + 2 * x] = q8(encC(scb / 4, full));
                C[y * cbpr + 2 * x + 1] = q8(encC(scr / 4, full));
            }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

#pragma mark - Comparison

typedef struct { double maxErr, meanErr; size_t over, samples; int worstX, worstY, worstC; int got, want; } Diff;

static void diffAdd(Diff *d, int got, int want, int x, int y, int c, int tol) {
    int e = abs(got - want);
    d->meanErr += e; d->samples++;
    if (e > tol) d->over++;
    if (e > d->maxErr) { d->maxErr = e; d->worstX = x; d->worstY = y; d->worstC = c; d->got = got; d->want = want; }
}
static void diffEnd(Diff *d) { if (d->samples) d->meanErr /= d->samples; }

// Per plane of two buffers of the same format and size (plane 0 = Y or BGRA, plane 1 = CbCr).
static void compareBuffers(CVPixelBufferRef a, CVPixelBufferRef b, Diff out[2], int tol) {
    memset(out, 0, sizeof(Diff) * 2);
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    BOOL planar = CVPixelBufferIsPlanar(a);
    size_t planes = planar ? 2 : 1;
    for (size_t p = 0; p < planes; p++) {
        const uint8_t *A = planar ? CVPixelBufferGetBaseAddressOfPlane(a, p) : CVPixelBufferGetBaseAddress(a);
        const uint8_t *B = planar ? CVPixelBufferGetBaseAddressOfPlane(b, p) : CVPixelBufferGetBaseAddress(b);
        size_t abpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(a, p) : CVPixelBufferGetBytesPerRow(a);
        size_t bbpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(b, p) : CVPixelBufferGetBytesPerRow(b);
        size_t w = planar ? CVPixelBufferGetWidthOfPlane(a, p) : CVPixelBufferGetWidth(a);
        size_t h = planar ? CVPixelBufferGetHeightOfPlane(a, p) : CVPixelBufferGetHeight(a);
        int comps = planar ? (p == 0 ? 1 : 2) : 4;
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++)
                for (int c = 0; c < comps; c++)
                    diffAdd(&out[p], A[y * abpr + x * comps + c], B[y * bbpr + x * comps + c], (int)x, (int)y, c, tol);
        diffEnd(&out[p]);
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
}

// Analytic reference of the destination: the pattern sampled at the destination's pixel centres (scaling a smooth
// image by any reasonable filter lands close to it), quantized like the destination format. 1-pixel border skipped
// (edge handling of the scalers differs).
static void compareAnalytic(CVPixelBufferRef dst, Diff out[2], int tol) {
    memset(out, 0, sizeof(Diff) * 2);
    OSType f = CVPixelBufferGetPixelFormatType(dst);
    size_t w = CVPixelBufferGetWidth(dst), h = CVPixelBufferGetHeight(dst);
    CVPixelBufferLockBaseAddress(dst, kCVPixelBufferLock_ReadOnly);
    if (f == kCVPixelFormatType_32BGRA) {
        const uint8_t *base = CVPixelBufferGetBaseAddress(dst);
        size_t bpr = CVPixelBufferGetBytesPerRow(dst);
        for (size_t y = 1; y + 1 < h; y++)
            for (size_t x = 1; x + 1 < w; x++) {
                double rgb[3];
                pattern((x + 0.5) / w, (y + 0.5) / h, rgb);
                const uint8_t *p = base + y * bpr + x * 4;
                diffAdd(&out[0], p[0], q8(rgb[2] * 255), (int)x, (int)y, 0, tol);
                diffAdd(&out[0], p[1], q8(rgb[1] * 255), (int)x, (int)y, 1, tol);
                diffAdd(&out[0], p[2], q8(rgb[0] * 255), (int)x, (int)y, 2, tol);
                diffAdd(&out[0], p[3], 255, (int)x, (int)y, 3, tol);
            }
    } else {
        BOOL full = fullRange(f);
        const uint8_t *Y = CVPixelBufferGetBaseAddressOfPlane(dst, 0), *C = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
        size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(dst, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);
        for (size_t y = 1; y + 1 < h; y++)
            for (size_t x = 1; x + 1 < w; x++) {
                double rgb[3], yy, cb, cr;
                pattern((x + 0.5) / w, (y + 0.5) / h, rgb);
                rgbToYcc(rgb, &yy, &cb, &cr);
                diffAdd(&out[0], Y[y * ybpr + x], q8(encY(yy, full)), (int)x, (int)y, 0, tol);
            }
        for (size_t y = 1; y + 1 < h / 2; y++)
            for (size_t x = 1; x + 1 < w / 2; x++) {
                double scb = 0, scr = 0;
                for (int j = 0; j < 2; j++)
                    for (int i = 0; i < 2; i++) {
                        double rgb[3], yy, cb, cr;
                        pattern((2 * x + i + 0.5) / w, (2 * y + j + 0.5) / h, rgb);
                        rgbToYcc(rgb, &yy, &cb, &cr);
                        scb += cb; scr += cr;
                    }
                diffAdd(&out[1], C[y * cbpr + 2 * x], q8(encC(scb / 4, full)), (int)x, (int)y, 0, tol);
                diffAdd(&out[1], C[y * cbpr + 2 * x + 1], q8(encC(scr / 4, full)), (int)x, (int)y, 1, tol);
            }
    }
    diffEnd(&out[0]); diffEnd(&out[1]);
    CVPixelBufferUnlockBaseAddress(dst, kCVPixelBufferLock_ReadOnly);
}

static NSString *diffString(const Diff *d) {
    return [NSString stringWithFormat:@"max %.0f mean %.3f over-tol %zu/%zu", d->maxErr, d->meanErr, d->over, d->samples];
}
static NSString *worstString(const Diff *d) {
    return [NSString stringWithFormat:@"worst at (%d,%d) c%d: %d vs %d", d->worstX, d->worstY, d->worstC, d->got, d->want];
}

// --save: BGRA -> PPM; 420 -> PGM of Y and PPM of the source pattern decoded on the CPU from the buffer's own planes.
static void saveBuffer(CVPixelBufferRef pb, NSString *dir, NSString *name) {
    if (!dir) return;
    OSType f = CVPixelBufferGetPixelFormatType(pb);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    NSMutableData *rgb = [NSMutableData dataWithLength:w * h * 3];
    uint8_t *o = rgb.mutableBytes;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (f == kCVPixelFormatType_32BGRA) {
        const uint8_t *base = CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++) {
                const uint8_t *p = base + y * bpr + x * 4;
                o[(y * w + x) * 3] = p[2]; o[(y * w + x) * 3 + 1] = p[1]; o[(y * w + x) * 3 + 2] = p[0];
            }
    } else {
        BOOL full = fullRange(f);
        const uint8_t *Y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *C = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++) {
                double c[3];
                yccToRgb(decY(Y[y * ybpr + x], full), decC(C[(y / 2) * cbpr + (x / 2) * 2], full),
                         decC(C[(y / 2) * cbpr + (x / 2) * 2 + 1], full), c);
                for (int k = 0; k < 3; k++) o[(y * w + x) * 3 + k] = q8(c[k] * 255);
            }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    NSMutableData *file = [[[NSString stringWithFormat:@"P6\n%zu %zu\n255\n", w, h] dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [file appendData:rgb];
    [file writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"ppm"]] atomically:YES];
}

#pragma mark - Sessions

static CFStringRef key(const char *name) {
    CFStringRef *p = dlsym(RTLD_DEFAULT, name);
    return p ? *p : NULL;
}

static id<MTLCommandQueue> gQueue;   // --queue

static VTPixelTransferSessionRef makeSession(BOOL gpu) {
    VTPixelTransferSessionRef s = NULL;
    OSStatus st = VTPixelTransferSessionCreate(NULL, &s);
    if (st) { printf("VTPixelTransferSessionCreate: %d\n", (int)st); exit(2); }
    VTSessionSetProperty(s, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Normal);
    VTSessionSetProperty(s, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4);
    VTSessionSetProperty(s, kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(s, kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    CFStringRef k;
    if (!gpu) {
        if ((k = key("kVTPixelTransferPropertyKey_EnableGPUAcceleratedTransfer")))
            printf("%s", VTSessionSetProperty(s, k, kCFBooleanFalse) ? "  (sw session: EnableGPUAcceleratedTransfer refused)\n" : "");
    } else {
        if ((k = key("kVTPixelTransferPropertyKey_MetalShouldWaitToComplete"))) VTSessionSetProperty(s, k, kCFBooleanTrue);
        if (gQueue && (k = key("kVTPixelTransferPropertyKey_MetalSubmissionQueue"))) {
            OSStatus r = VTSessionSetProperty(s, k, (__bridge CFTypeRef)gQueue);
            if (r) printf("  MetalSubmissionQueue refused: %d\n", (int)r);
        }
    }
    return s;
}

static NSString *conversionType(VTPixelTransferSessionRef s) {
    CFStringRef k = key("kVTPixelTransferPropertyKey_MostRecentConversionType");
    CFTypeRef v = NULL;
    OSStatus st = k ? VTSessionCopyProperty(s, k, NULL, &v) : -1;
    if (st || !v) return [NSString stringWithFormat:@"? (MostRecentConversionType: %d)", (int)st];
    return [CFBridgingRelease(v) description];
}
static NSString *chainDescription(VTPixelTransferSessionRef s) {
    CFStringRef k = key("kVTPixelTransferPropertyKey_MostRecentChainDescription");
    CFTypeRef v = NULL;
    if (!k || VTSessionCopyProperty(s, k, NULL, &v) || !v) return nil;
    id o = CFBridgingRelease(v);
    return [[o description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
}

#pragma mark - Cases

static NSString *fourcc(OSType f) {
    char c[5] = { (char)(f >> 24), (char)(f >> 16), (char)(f >> 8), (char)f, 0 };
    return @(c);
}

typedef struct { OSType src; size_t sw, sh; OSType dst; size_t dw, dh; } Case;

static int gFails, gMetalRuns, gComputeDispatches, gSkippedOrInert, gLost;
static NSString *gSaveDir;
static const int kTolVT = 2;        // gpu vs VT software: <= 2/255 per channel
static const int kTolAnalytic = 4;  // vs the analytic pattern: chroma siting, filters, rounding

static int gUntouched;

// At least 99.9 % of the bytes still hold the fill value (VT touches a handful of bytes in the cases it skips).
static BOOL untouched(CVPixelBufferRef pb, uint8_t value) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t total = 0, same = 0;
    BOOL planar = CVPixelBufferIsPlanar(pb);
    size_t planes = planar ? CVPixelBufferGetPlaneCount(pb) : 1;
    for (size_t p = 0; p < planes; p++) {
        const uint8_t *base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, p) : CVPixelBufferGetBaseAddress(pb);
        size_t bpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, p) : CVPixelBufferGetBytesPerRow(pb);
        size_t h = planar ? CVPixelBufferGetHeightOfPlane(pb, p) : CVPixelBufferGetHeight(pb);
        for (size_t i = 0; i < bpr * h; i++) same += base[i] == value;
        total += bpr * h;
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return total && same * 1000 >= total * 999;
}

static void runCase(const Case *c, BOOL shim) {
    NSString *name = [NSString stringWithFormat:@"%@ %zux%zu -> %@ %zux%zu", fourcc(c->src), c->sw, c->sh, fourcc(c->dst), c->dw, c->dh];
    NSString *file = [NSString stringWithFormat:@"%@-%zux%zu-to-%@-%zux%zu", fourcc(c->src), c->sw, c->sh, fourcc(c->dst), c->dw, c->dh];
    printf("== %s\n", name.UTF8String);
    CVPixelBufferRef src = makeBuffer(c->src, c->sw, c->sh);
    drawPattern(src);
    CVPixelBufferRef outGPU = makeBuffer(c->dst, c->dw, c->dh), outSW = makeBuffer(c->dst, c->dw, c->dh);
    fillBuffer(outGPU, 0x55); fillBuffer(outSW, 0xAA);   // different garbage: an untouched output cannot match

    VTPixelTransferSessionRef sw = makeSession(NO), gpu = makeSession(YES);
    OSStatus stSW = VTPixelTransferSessionTransferImage(sw, src, outSW);
    Counters before = readCounters();
    OSStatus stGPU = VTPixelTransferSessionTransferImage(gpu, src, outGPU);
    // second run of the same transfer: the first one may build pipelines (and wait on them)
    OSStatus stGPU2 = stGPU ? stGPU : VTPixelTransferSessionTransferImage(gpu, src, outGPU);
    Counters d = diffCounters(before, readCounters());
    NSString *typeSW = conversionType(sw), *typeGPU = conversionType(gpu), *chain = chainDescription(gpu);
    printf("  sw  session: status %d, conversion %s\n", (int)stSW, typeSW.UTF8String);
    printf("  gpu session: status %d/%d, conversion %s\n", (int)stGPU, (int)stGPU2, typeGPU.UTF8String);
    if (chain) printf("  gpu chain: %s\n", chain.UTF8String);
    if (shim) printf("  shim counters (2 transfers): %s\n", countersString(d).UTF8String);

    BOOL metal = [typeGPU isEqualToString:@"MetalConversion"];
    if (metal) gMetalRuns++;
    gComputeDispatches += (int)d.v[C_DISPATCHES];
    gSkippedOrInert += (int)(d.v[C_SKIPPED] + d.v[C_INERT]);
    long lost = (long)d.v[C_RECORDED] - (long)d.v[C_DISPATCHES] - (long)d.v[C_SKIPPED] - (long)d.v[C_INERT];
    if (lost > 0) gLost += (int)lost;
    if (shim && metal && d.v[C_DISPATCHES] == 0)
        printf("  NOTE  VT reports a Metal conversion but no compute dispatch ran on the shim (render passes %llu)\n", d.v[6]);
    if (d.v[C_SKIPPED] || d.v[C_INERT]) printf("  WARN  %llu dispatches skipped, %llu inert (see TSMTL_LOG=1 \"dispatch of ... skipped\")\n", d.v[C_SKIPPED], d.v[C_INERT]);

    if (stSW || stGPU || stGPU2) { printf("  FAIL  transfer error\n"); gFails++; goto done; }
    if (untouched(outGPU, 0x55) && untouched(outSW, 0xAA)) {
        // Measured on this iMac: BGRA -> 420v/420f at the same size returns noErr and writes nothing, with and without
        // the shim (VT hands it to the GVA "offline Gen6" Intel plugin, and no Intel accelerator is attached).
        printf("  skip  VideoToolbox wrote neither output (status 0): system path, the same without the shim\n");
        gUntouched++;
        goto done;
    }
    {
        Diff vs[2], an[2], anSW[2];
        compareBuffers(outGPU, outSW, vs, kTolVT);
        compareAnalytic(outGPU, an, kTolAnalytic);
        compareAnalytic(outSW, anSW, kTolAnalytic);
        BOOL planar = CVPixelBufferIsPlanar(outGPU);
        for (int p = 0; p < (planar ? 2 : 1); p++) {
            const char *plane = planar ? (p ? "CbCr" : "Y") : "BGRA";
            BOOL ok = vs[p].maxErr <= kTolVT;
            BOOL okA = an[p].maxErr <= kTolAnalytic;
            printf("  %s  gpu vs sw  %-4s %s%s%s\n", ok ? "ok  " : "FAIL", plane, diffString(&vs[p]).UTF8String,
                   ok ? "" : ", ", ok ? "" : worstString(&vs[p]).UTF8String);
            printf("  %s  gpu vs cpu %-4s %s%s%s\n", okA ? "ok  " : "FAIL", plane, diffString(&an[p]).UTF8String,
                   okA ? "" : ", ", okA ? "" : worstString(&an[p]).UTF8String);
            printf("  info  sw  vs cpu %-4s %s, %s\n", plane, diffString(&anSW[p]).UTF8String, worstString(&anSW[p]).UTF8String);
            if (!ok || !okA) gFails++;
        }
        saveBuffer(src, gSaveDir, [file stringByAppendingString:@"-src"]);
        saveBuffer(outGPU, gSaveDir, [file stringByAppendingString:@"-gpu"]);
        saveBuffer(outSW, gSaveDir, [file stringByAppendingString:@"-sw"]);
    }
done:
    VTPixelTransferSessionInvalidate(gpu); CFRelease(gpu);
    VTPixelTransferSessionInvalidate(sw); CFRelease(sw);
    CVPixelBufferRelease(src); CVPixelBufferRelease(outGPU); CVPixelBufferRelease(outSW);
}

#pragma mark - Main

static int reexecInjected(int argc, char **argv) {
    char exe[4096]; uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n)) return 2;
    setenv("DYLD_INSERT_LIBRARIES", TS_SOURCE_DIR "/build/libTSMetalInject.dylib", 1);
    setenv("TSMTL_VTXFER_CHILD", "1", 1);
    if (!getenv("TSMTL_COMPUTE")) setenv("TSMTL_COMPUTE", "1", 1);
    fflush(stdout);
    execve(exe, argv, environ);
    printf("execve: %s\n", strerror(errno));
    return 2;
}

int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    BOOL noShim = NO, viaQueue = NO, requireMetal = NO;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--no-shim")) noShim = YES;
        else if (!strcmp(argv[i], "--queue")) viaQueue = YES;
        else if (!strcmp(argv[i], "--require-metal")) requireMetal = YES;
        else if (!strcmp(argv[i], "--save") && i + 1 < argc) gSaveDir = @(argv[++i]);
        else { printf("usage: %s [--no-shim | --queue] [--require-metal] [--save DIR]\n", argv[0]); return 2; }
    }
    if (gSaveDir) [NSFileManager.defaultManager createDirectoryAtPath:gSaveDir withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL injected = dlsym(RTLD_DEFAULT, "TSMtlCreateDevice") != NULL;
    if (!noShim && !viaQueue && !injected) {
        if (getenv("TSMTL_VTXFER_CHILD")) { printf("FAIL  injection did not load (hardened runtime? SIP-protected path?)\n"); return 2; }
        return reexecInjected(argc, argv);
    }
    if (noShim && injected) printf("note: --no-shim but the shim is injected\n");
    BOOL shim = !noShim && bindShim(viaQueue);
    if (viaQueue) {
        if (getenv("TSMTL_COMPUTE") == NULL) setenv("TSMTL_COMPUTE", "1", 1);
        CreateDeviceFn create = (CreateDeviceFn)dlsym(RTLD_DEFAULT, "TSMtlCreateDevice");
        id<MTLDevice> dev = create ? create() : nil;
        gQueue = [dev newCommandQueue];
        printf("mode: --queue, shim from %s, device %s, queue handed to VT via MetalSubmissionQueue\n", gShimSource, dev.name.UTF8String);
    } else if (shim) {
        printf("mode: injected, shim from %s\n", gShimSource);
    } else printf("mode: no shim\n");

    id<MTLDevice> sys = MTLCreateSystemDefaultDevice();
    NSArray *all = MTLCopyAllDevices();
    printf("MTLCreateSystemDefaultDevice: %s (%s); MTLCopyAllDevices: %lu device(s)\n", sys ? sys.name.UTF8String : "nil",
           sys ? object_getClassName(sys) : "-", (unsigned long)all.count);
    printf("TSMTL_COMPUTE=%s\n", getenv("TSMTL_COMPUTE") ?: "(unset: policy)");

    const OSType v = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, f = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 bgra = kCVPixelFormatType_32BGRA;
    const Case cases[] = {
        { v, 640, 480, bgra, 640, 480 },
        { f, 640, 480, bgra, 640, 480 },
        { v, 640, 480, bgra, 320, 240 },
        { f, 512, 512, bgra, 768, 768 },
        { bgra, 640, 480, v, 640, 480 },
        { bgra, 640, 480, f, 640, 480 },
        { bgra, 640, 480, v, 320, 240 },
        { v, 640, 480, v, 320, 240 },
        { bgra, 640, 480, bgra, 400, 300 },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) runCase(&cases[i], shim);

    printf("\n");
    if (!shim)
        printf("VTMTSComputeFunction: NOT TESTED - no shim device in this run (VT used: see conversion lines)\n");
    else if (gComputeDispatches > 0)
        printf("VTMTSComputeFunction: RAN on the shim device - %d compute dispatches, %d/%zu transfers were Metal conversions\n",
               gComputeDispatches, gMetalRuns, sizeof cases / sizeof cases[0]);
    else
        printf("VTMTSComputeFunction: DID NOT RUN on the shim device - 0 compute dispatches, %d/%zu transfers reported Metal "
               "(skipped/inert %d, lost %d); output equality above says nothing about the OpenCL path\n",
               gMetalRuns, sizeof cases / sizeof cases[0], gSkippedOrInert, gLost);
    if (gUntouched) printf("note: %d transfers left both outputs untouched (VideoToolbox system path, not the shim)\n", gUntouched);
    if (gSkippedOrInert || gLost) printf("WARN  %d dispatches skipped or inert, %d recorded but never run\n", gSkippedOrInert, gLost);
    BOOL fail = gFails || (requireMetal && gComputeDispatches == 0);
    printf("%s: %d failing checks%s\n", fail ? "FAIL" : "PASS", gFails,
           requireMetal && gComputeDispatches == 0 ? " + no compute dispatch (--require-metal)" : "");
    return fail ? 1 : 0;
}}
