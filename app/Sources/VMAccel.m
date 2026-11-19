// Acceleratori: MaliMetal subpage for the hardware services that stand in for the iPhone's accelerators
// (docs/ANALISI-ACCELERATORI-2026-11-04.md): the scaler (AppleM2ScalerCSCDriver, kernel VivaScaler.cpp), the JPEG
// encoder (AppleJPEGDriver, VivaJPEG.cpp), MetalPerformanceShaders on MaliMetal (mpstest) and the hardware video
// decoder (kernel VivaVDEC, fork 0213; the clean-room VideoToolbox decoder vivavt from the vdec repo, loaded into
// mediaserverd where iOS runs every VTDecompressionSession). Shows what the running kernel publishes, edits the
// boot-args that turn the services on at the next boot, and runs tests: the scaler test draws a source, the CPU
// reference and the service's result side by side.
#import "VMApp.h"
#import <IOSurface/IOSurfaceRef.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>

// ---- IOKit and IOSurfaceAccelerator through dlsym (no headers in the iOS SDK) ------------------------------------------

typedef unsigned int vm_io_object_t;
static CFMutableDictionaryRef (*pIOServiceMatching)(const char *);
static vm_io_object_t (*pIOServiceGetMatchingService)(unsigned int, CFDictionaryRef);
static int (*pIORegistryEntryCreateCFProperties)(vm_io_object_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
static int (*pIOObjectRelease)(vm_io_object_t);
typedef void *IOSARef;
static int (*pIOSACreate)(CFAllocatorRef, CFDictionaryRef, IOSARef *);
static int (*pIOSATransfer)(IOSARef, IOSurfaceRef, IOSurfaceRef, CFDictionaryRef, void *, void *, void *);

static void VMAccelLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (io) {
            pIOServiceMatching = dlsym(io, "IOServiceMatching");
            pIOServiceGetMatchingService = dlsym(io, "IOServiceGetMatchingService");
            pIORegistryEntryCreateCFProperties = dlsym(io, "IORegistryEntryCreateCFProperties");
            pIOObjectRelease = dlsym(io, "IOObjectRelease");
        }
        void *sa = dlopen("/System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator", RTLD_LAZY);
        if (sa) {
            pIOSACreate = dlsym(sa, "IOSurfaceAcceleratorCreate");
            pIOSATransfer = dlsym(sa, "IOSurfaceAcceleratorTransferSurface");
        }
    });
}

// Registry properties of the first service of that class, or nil when it is not published.
static NSDictionary *VMServiceProperties(const char *cls) {
    VMAccelLoad();
    if (!pIOServiceMatching || !pIOServiceGetMatchingService || !pIORegistryEntryCreateCFProperties) return nil;
    vm_io_object_t s = pIOServiceGetMatchingService(0, pIOServiceMatching(cls));
    if (!s) return nil;
    CFMutableDictionaryRef props = NULL;
    pIORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0);
    pIOObjectRelease(s);
    return props ? CFBridgingRelease(props) : @{};
}

// ---- Scaler test: two IOSurfaces, the service's transfer, a CPU reference -----------------------------------------------

static IOSurfaceRef VMSurface(int w, int h) {
    NSDictionary *p = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4,
                         (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
    return IOSurfaceCreate((__bridge CFDictionaryRef)p);
}

static void VMPattern(IOSurfaceRef s) {
    IOSurfaceLock(s, 0, NULL);
    uint8_t *b = IOSurfaceGetBaseAddress(s);
    size_t bpr = IOSurfaceGetBytesPerRow(s), w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s);
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
        uint8_t *p = b + y * bpr + x * 4;
        BOOL check = ((x / 16) + (y / 16)) & 1;
        p[0] = (uint8_t)(255 * y / (h - 1));            // B
        p[1] = check ? 220 : 40;                       // G
        p[2] = (uint8_t)(255 * x / (w - 1));           // R
        p[3] = 255;
    }
    IOSurfaceUnlock(s, 0, NULL);
}

// Bilinear reference with the kernel's sampling (pixel centres, clamp to edge).
static void VMReference(IOSurfaceRef src, uint8_t *out, int dw, int dh) {
    IOSurfaceLock(src, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *b = IOSurfaceGetBaseAddress(src);
    size_t bpr = IOSurfaceGetBytesPerRow(src);
    int sw = (int)IOSurfaceGetWidth(src), sh = (int)IOSurfaceGetHeight(src);
    for (int j = 0; j < dh; j++) for (int i = 0; i < dw; i++) {
        double fx = (i + 0.5) * sw / dw - 0.5, fy = (j + 0.5) * sh / dh - 0.5;
        int x0 = (int)floor(fx), y0 = (int)floor(fy);
        double ax = fx - x0, ay = fy - y0;
        for (int c = 0; c < 4; c++) {
            double v = 0;
            for (int q = 0; q < 4; q++) {
                int xx = MIN(MAX(x0 + (q & 1), 0), sw - 1), yy = MIN(MAX(y0 + (q >> 1), 0), sh - 1);
                double wgt = ((q & 1) ? ax : 1 - ax) * ((q >> 1) ? ay : 1 - ay);
                v += wgt * b[yy * bpr + xx * 4 + c];
            }
            out[(j * dw + i) * 4 + c] = (uint8_t)lround(v);
        }
    }
    IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, NULL);
}

static UIImage *VMImageFromBGRA(const uint8_t *px, int w, int h, size_t bpr) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate((void *)px, w, h, 8, bpr, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    UIImage *u = [UIImage imageWithCGImage:img];
    CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    return u;
}

@interface VMAccelTestResult : NSObject
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, strong, nullable) UIImage *source, *reference, *result;
@end
@implementation VMAccelTestResult
@end

static VMAccelTestResult *VMRunScalerTest(void) {
    VMAccelTestResult *r = [VMAccelTestResult new];
    VMAccelLoad();
    if (!pIOSACreate || !pIOSATransfer) { r.summary = @"IOSurfaceAccelerator.framework non trovato"; return r; }
    IOSARef acc = NULL;
    int err = pIOSACreate(kCFAllocatorDefault, NULL, &acc);
    if (err || !acc) {
        r.summary = [NSString stringWithFormat:@"Servizio non disponibile (IOSurfaceAcceleratorCreate 0x%x): attiva vivascaler e riavvia", err];
        return r;
    }
    const int SW = 256, SH = 192, DW = 160, DH = 120;
    IOSurfaceRef src = VMSurface(SW, SH), dst = VMSurface(DW, DH);
    VMPattern(src);
    uint8_t *ref = calloc(DW * DH, 4);
    VMReference(src, ref, DW, DH);
    NSDictionary *before = VMServiceProperties("AppleM2ScalerCSCDriver")[@"VivaScalerStats"];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    err = pIOSATransfer(acc, src, dst, NULL, NULL, NULL, NULL);
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
    NSDictionary *after = VMServiceProperties("AppleM2ScalerCSCDriver")[@"VivaScalerStats"];
    BOOL mdp = [after[@"mdp"] longLongValue] > [before[@"mdp"] longLongValue];
    IOSurfaceLock(dst, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *d = IOSurfaceGetBaseAddress(dst);
    size_t bpr = IOSurfaceGetBytesPerRow(dst);
    int maxErr = 0, bad = 0;
    for (int j = 0; j < DH; j++) for (int i = 0; i < DW; i++) for (int c = 0; c < 4; c++) {
        int e = abs((int)d[j * bpr + i * 4 + c] - (int)ref[(j * DW + i) * 4 + c]);
        maxErr = MAX(maxErr, e);
        // the MDP's resizer filters differently from bilinear (6 taps / accumulation): loose bound, the checker's edges
        if (e > (mdp ? 24 : 3)) bad++;
    }
    BOOL pass = mdp ? bad < DW * DH * 4 / 50 : bad == 0;
    r.result = VMImageFromBGRA(d, DW, DH, bpr);
    IOSurfaceUnlock(dst, kIOSurfaceLockReadOnly, NULL);
    r.reference = VMImageFromBGRA(ref, DW, DH, DW * 4);
    IOSurfaceLock(src, kIOSurfaceLockReadOnly, NULL);
    r.source = VMImageFromBGRA(IOSurfaceGetBaseAddress(src), SW, SH, IOSurfaceGetBytesPerRow(src));
    IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, NULL);
    r.summary = err ? [NSString stringWithFormat:@"KO: TransferSurface 0x%x", err]
                    : [NSString stringWithFormat:@"%@ — BGRA 256×192 → 160×120 su %@, errore max %d, %d valori oltre %d, %.2f ms",
                       pass ? @"OK" : @"KO", mdp ? @"motori MDP (resizer)" : @"CPU (bilineare)", maxErr, bad, mdp ? 24 : 3, ms];
    free(ref);
    CFRelease(src); CFRelease(dst);
    CFRelease((CFTypeRef)acc);
    return r;
}

// ---- Scaler NV12 test: 420f -> BGRA at the same size (the MDP path with vivascaler=2) ---------------------------------

static VMAccelTestResult *VMRunNV12Test(void) {
    VMAccelTestResult *r = [VMAccelTestResult new];
    VMAccelLoad();
    if (!pIOSACreate || !pIOSATransfer) { r.summary = @"IOSurfaceAccelerator.framework non trovato"; return r; }
    IOSARef acc = NULL;
    int err = pIOSACreate(kCFAllocatorDefault, NULL, &acc);
    if (err || !acc) { r.summary = [NSString stringWithFormat:@"Servizio non disponibile (0x%x)", err]; return r; }
    const int W = 640, H = 360;
    NSDictionary *planeY = @{ (id)kIOSurfacePlaneWidth: @(W), (id)kIOSurfacePlaneHeight: @(H), (id)kIOSurfacePlaneBytesPerElement: @1,
                              (id)kIOSurfacePlaneBytesPerRow: @(W), (id)kIOSurfacePlaneOffset: @0, (id)kIOSurfacePlaneSize: @(W * H) };
    NSDictionary *planeC = @{ (id)kIOSurfacePlaneWidth: @(W / 2), (id)kIOSurfacePlaneHeight: @(H / 2), (id)kIOSurfacePlaneBytesPerElement: @2,
                              (id)kIOSurfacePlaneBytesPerRow: @(W), (id)kIOSurfacePlaneOffset: @(W * H), (id)kIOSurfacePlaneSize: @(W * H / 2) };
    NSDictionary *p = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfacePixelFormat: @((uint32_t)'420f'),
                         (id)kIOSurfaceAllocSize: @(W * H * 3 / 2), (id)kIOSurfacePlaneInfo: @[ planeY, planeC ] };
    IOSurfaceRef src = IOSurfaceCreate((__bridge CFDictionaryRef)p), dst = VMSurface(W, H);
    if (!src || !dst) { r.summary = @"IOSurfaceCreate fallita"; if (src) CFRelease(src); if (dst) CFRelease(dst); CFRelease((CFTypeRef)acc); return r; }
    IOSurfaceLock(src, 0, NULL);
    uint8_t *y = IOSurfaceGetBaseAddressOfPlane(src, 0), *uv = IOSurfaceGetBaseAddressOfPlane(src, 1);
    size_t yb = IOSurfaceGetBytesPerRowOfPlane(src, 0), cb = IOSurfaceGetBytesPerRowOfPlane(src, 1);
    for (int j = 0; j < H; j++) for (int i = 0; i < W; i++) y[j * yb + i] = (uint8_t)(255 * i / (W - 1));
    for (int j = 0; j < H / 2; j++) for (int i = 0; i < W / 2; i++) {
        uv[j * cb + 2 * i] = (uint8_t)(255 * j / (H / 2 - 1));                 // U
        uv[j * cb + 2 * i + 1] = (uint8_t)(255 - 255 * i / (W / 2 - 1));      // V
    }
    // CPU reference: BT.601 full range, chroma replicated
    uint8_t *ref = malloc(W * H * 4);
    for (int j = 0; j < H; j++) for (int i = 0; i < W; i++) {
        double Y = y[j * yb + i], U = uv[(j / 2) * cb + (i / 2) * 2] - 128.0, V = uv[(j / 2) * cb + (i / 2) * 2 + 1] - 128.0;
        double R = Y + 1.402 * V, G = Y - 0.344136 * U - 0.714136 * V, B = Y + 1.772 * U;
        uint8_t *q = ref + (j * W + i) * 4;
        q[0] = (uint8_t)MAX(0, MIN(255, lround(B))); q[1] = (uint8_t)MAX(0, MIN(255, lround(G)));
        q[2] = (uint8_t)MAX(0, MIN(255, lround(R))); q[3] = 255;
    }
    IOSurfaceUnlock(src, 0, NULL);
    NSDictionary *before = VMServiceProperties("AppleM2ScalerCSCDriver")[@"VivaScalerStats"];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    err = pIOSATransfer(acc, src, dst, NULL, NULL, NULL, NULL);
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
    NSDictionary *after = VMServiceProperties("AppleM2ScalerCSCDriver")[@"VivaScalerStats"];
    BOOL mdp = [after[@"mdp"] longLongValue] > [before[@"mdp"] longLongValue];
    IOSurfaceLock(dst, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *d = IOSurfaceGetBaseAddress(dst);
    size_t db = IOSurfaceGetBytesPerRow(dst);
    int maxErr = 0, bad = 0;
    for (int j = 0; j < H; j++) for (int i = 0; i < W; i++) for (int c = 0; c < 3; c++) {
        int e = abs((int)d[j * db + i * 4 + c] - (int)ref[(j * W + i) * 4 + c]);
        maxErr = MAX(maxErr, e);
        if (e > 6) bad++;
    }
    r.result = VMImageFromBGRA(d, W, H, db);
    IOSurfaceUnlock(dst, kIOSurfaceLockReadOnly, NULL);
    r.reference = VMImageFromBGRA(ref, W, H, W * 4);
    r.source = r.reference;
    r.summary = err ? [NSString stringWithFormat:@"KO: TransferSurface 0x%x", err]
                    : [NSString stringWithFormat:@"%@ — 420f 640×360 → BGRA, errore max %d, %d valori oltre 6, %.2f ms, %@",
                       bad == 0 ? @"OK" : @"KO", maxErr, bad, ms, mdp ? @"motori MDP" : @"CPU (MDP non usato)"];
    free(ref);
    CFRelease(src); CFRelease(dst); CFRelease((CFTypeRef)acc);
    return r;
}

// ---- JPEG test: VideoToolbox's JPEG encoder (the hardware one when AppleJPEGDriver is published) ----------------------

static VMAccelTestResult *VMRunJpegTest(void) {
    VMAccelTestResult *r = [VMAccelTestResult new];
    const int W = 320, H = 240;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
        r.summary = @"CVPixelBufferCreate fallita";
        return r;
    }
    // gradient + checkerboard in YCbCr, and its RGB view for the left image
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    uint8_t *rgb = malloc(W * H * 4);
    for (int j = 0; j < H; j++) for (int i = 0; i < W; i++) {
        int Y = 16 + 220 * i / W + ((((i / 20) + (j / 20)) & 1) ? 0 : -10);
        int Cb = 128 + 100 * (j - H / 2) / H, Cr = 128 + 100 * (i - W / 2) / W;
        y[j * ybpr + i] = (uint8_t)MAX(0, MIN(255, Y));
        if (!(i & 1) && !(j & 1)) { uv[(j / 2) * cbpr + i] = (uint8_t)Cb; uv[(j / 2) * cbpr + i + 1] = (uint8_t)Cr; }
        double R = Y + 1.402 * (Cr - 128), G = Y - 0.344 * (Cb - 128) - 0.714 * (Cr - 128), B = Y + 1.772 * (Cb - 128);
        uint8_t *p = rgb + (j * W + i) * 4;
        p[0] = (uint8_t)MAX(0, MIN(255, B)); p[1] = (uint8_t)MAX(0, MIN(255, G)); p[2] = (uint8_t)MAX(0, MIN(255, R)); p[3] = 255;
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    r.source = VMImageFromBGRA(rgb, W, H, W * 4);
    free(rgb);
    NSDictionary *before = VMServiceProperties("AppleJPEGDriver")[@"VivaJPEGStats"];
    VTCompressionSessionRef vt = NULL;
    OSStatus st = VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_JPEG, NULL, NULL, NULL, NULL, NULL, &vt);
    if (st != noErr || !vt) { r.summary = [NSString stringWithFormat:@"VTCompressionSessionCreate: %d", (int)st]; CVPixelBufferRelease(pb); return r; }
    VTSessionSetProperty(vt, kVTCompressionPropertyKey_Quality, (__bridge CFTypeRef)@0.85);
    __block NSData *jpeg = nil;
    __block OSStatus encErr = 0;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    st = VTCompressionSessionEncodeFrameWithOutputHandler(vt, pb, CMTimeMake(0, 30), kCMTimeInvalid, NULL, NULL,
        ^(OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
            encErr = status;
            CMBlockBufferRef bb = sb ? CMSampleBufferGetDataBuffer(sb) : NULL;
            if (!bb) return;
            size_t len = CMBlockBufferGetDataLength(bb);
            NSMutableData *d = [NSMutableData dataWithLength:len];
            CMBlockBufferCopyDataBytes(bb, 0, len, d.mutableBytes);
            jpeg = d;
        });
    VTCompressionSessionCompleteFrames(vt, kCMTimeInvalid);
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
    VTCompressionSessionInvalidate(vt);
    CFRelease(vt);
    CVPixelBufferRelease(pb);
    NSDictionary *after = VMServiceProperties("AppleJPEGDriver")[@"VivaJPEGStats"];
    BOOL hw = after && [after[@"encodes"] longLongValue] > [before[@"encodes"] longLongValue];
    if (st != noErr || encErr != noErr || !jpeg.length) {
        r.summary = [NSString stringWithFormat:@"KO: encode %d/%d", (int)st, (int)encErr];
        return r;
    }
    CGImageSourceRef isrc = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    CGImageRef img = isrc ? CGImageSourceCreateImageAtIndex(isrc, 0, NULL) : NULL;
    if (img) { r.result = [UIImage imageWithCGImage:img]; CGImageRelease(img); }
    if (isrc) CFRelease(isrc);
    r.summary = [NSString stringWithFormat:@"%@ — 320×240 420f, %lu byte, %.1f ms, %@", r.result ? @"OK" : @"KO (non decodificabile)",
                 (unsigned long)jpeg.length, ms, hw ? @"codificato dall'hardware (jpgenc)" : @"codificato in software (servizio non usato)"];
    return r;
}

// ---- Video decoder test: .vtclip files (vdec tools/mkvtclip.py) through a VTDecompressionSession -------------------------

static NSString *const VMVivaVTLog = @"/private/var/mobile/Library/Logs/VivaVT.log";

// Lines of the vivavt log (written by the decoder inside mediaserverd).
static NSArray<NSString *> *VMVivaVTLines(void) {
    NSString *t = [NSString stringWithContentsOfFile:VMVivaVTLog encoding:NSUTF8StringEncoding error:nil];
    return t ? [t componentsSeparatedByString:@"\n"] : @[];
}

static NSUInteger VMCount(NSArray<NSString *> *lines, NSString *needle) {
    NSUInteger n = 0;
    for (NSString *l in lines) if ([l containsString:needle]) n++;
    return n;
}

typedef struct { int64_t pts; uint64_t hash; OSStatus status; } VMFrame;
typedef struct { VMFrame frames[64]; int n; } VMFrames;

static void VMOnFrame(void *ref, void *src, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef img, CMTime pts, CMTime dur) {
    VMFrames *f = ref;
    if (f->n >= 64) return;
    VMFrame *o = &f->frames[f->n++];
    o->pts = pts.value;
    o->status = status;
    o->hash = 0;
    if (status || !img) return;
    CVPixelBufferRef pb = (CVPixelBufferRef)img;
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    int ten = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    uint64_t hh = 0xcbf29ce484222325ull;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    for (size_t p = 0; p < 2 && CVPixelBufferGetPlaneCount(pb) == 2; p++) {
        const uint8_t *b = CVPixelBufferGetBaseAddressOfPlane(pb, p);
        size_t st = CVPixelBufferGetBytesPerRowOfPlane(pb, p), rows = p ? h / 2 : h;
        for (size_t r = 0; r < rows; r++)
            for (size_t x = 0; x < w * (ten ? 2 : 1); x++) hh = (hh ^ b[r * st + x]) * 0x100000001b3ull;
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    o->hash = hh;
}

static int VMByPts(const void *a, const void *b) {
    const VMFrame *x = a, *y = b;
    return x->pts < y->pts ? -1 : x->pts > y->pts;
}

// One clip: "nome: N/N bit-exact, X ms/frame, hardware|software"
static NSString *VMRunVideoClip(NSString *name, NSString *label) {
    NSData *d = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:name ofType:@"vtclip"]];
    if (d.length < 16) return [NSString stringWithFormat:@"%@: clip mancante", label];
    const uint8_t *p = d.bytes, *end = p + d.length;
#define RD32(v) do { if (p + 4 > end) return [NSString stringWithFormat:@"%@: clip troncata", label]; memcpy(&(v), p, 4); p += 4; } while (0)
    uint32_t magic, codec, nps, ns;
    RD32(magic); RD32(codec); RD32(nps); RD32(ns);
    if (magic != 0x4c435456u || nps > 16 || ns > 64) return [NSString stringWithFormat:@"%@: clip non valida", label];
    const uint8_t *ps[16];
    size_t psl[16];
    for (uint32_t i = 0; i < nps; i++) { uint32_t l; RD32(l); if (p + l > end) return @"?"; ps[i] = p; psl[i] = l; p += l; }
    CMVideoFormatDescriptionRef fd = NULL;
    OSStatus err = codec == 0x68766331u
        ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, nps, ps, psl, 4, NULL, &fd)
        : CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, nps, ps, psl, 4, &fd);
    if (err) return [NSString stringWithFormat:@"%@: format description %d", label, (int)err];
    NSUInteger creates0 = VMCount(VMVivaVTLines(), @"] layout 0:");
    VMFrames *fr = calloc(1, sizeof *fr);
    VTDecompressionOutputCallbackRecord cb = { VMOnFrame, fr };
    VTDecompressionSessionRef session = NULL;
    err = VTDecompressionSessionCreate(NULL, fd, NULL, NULL, &cb, &session);
    if (err) { CFRelease(fd); free(fr); return [NSString stringWithFormat:@"%@: sessione VideoToolbox %d", label, (int)err]; }
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    for (uint32_t k = 0; k < ns; k++) {
        int32_t poc; uint32_t l;
        RD32(poc); RD32(l);
        if (p + l > end) break;
        CMBlockBufferRef bb = NULL;
        CMSampleBufferRef sb = NULL;
        err = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, l, NULL, NULL, 0, l, 0, &bb);
        if (!err) err = CMBlockBufferReplaceDataBytes(p, bb, 0, l);
        CMSampleTimingInfo ti = { CMTimeMake(1, 30), CMTimeMake(poc, 30), CMTimeMake(k, 30) };
        size_t ssz = l;
        if (!err) err = CMSampleBufferCreateReady(NULL, bb, fd, 1, 1, &ti, 1, &ssz, &sb);
        if (!err) VTDecompressionSessionDecodeFrame(session, sb, 0, NULL, NULL);
        if (sb) CFRelease(sb);
        if (bb) CFRelease(bb);
        p += l;
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session);
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0 / MAX(ns, 1u);
    VTDecompressionSessionInvalidate(session);
    CFRelease(session);
    CFRelease(fd);
    uint32_t nh = 0;
    RD32(nh);
    qsort(fr->frames, fr->n, sizeof fr->frames[0], VMByPts);
    int ok = 0;
    for (uint32_t i = 0; i < nh && i < (uint32_t)fr->n && p + 8 <= end; i++, p += 8) {
        uint64_t h;
        memcpy(&h, p, 8);
        ok += !fr->frames[i].status && fr->frames[i].hash == h;
    }
    uint32_t w = 0, hgt = 0;
    if (p + (nh > (uint32_t)fr->n ? (nh - fr->n) * 8 : 0) + 8 <= end) {
        p += nh > (uint32_t)fr->n ? (nh - fr->n) * 8 : 0;
        RD32(w); RD32(hgt);
    }
#undef RD32
    free(fr);
    BOOL hw = VMCount(VMVivaVTLines(), @"] layout 0:") > creates0;
    return [NSString stringWithFormat:@"%@ %ux%u: %d/%u bit-exact, %.1f ms/frame, %@", label, w, hgt, ok, nh, ms,
            hw ? @"hardware (VDEC)" : @"software (decoder di iOS)"];
}

static NSString *VMRunVideoTest(void) {
    NSArray *clips = @[@[@"h264-320", @"H.264 High, B a piramide"], @[@"h264-720p", @"H.264 High 720p"],
                       @[@"hevc-320", @"HEVC Main, B a piramide"], @[@"hevc10-320", @"HEVC Main 10"]];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSArray *c in clips) [lines addObject:VMRunVideoClip(c[0], c[1])];
    return [lines componentsJoinedByString:@"\n"];
}

// "Attivo in mediaserverd (pid N, dalle hh:mm:ss)" from the vivavt log, plus whether the binary loads it.
static NSString *VMVideoState(void) {
    NSData *msd = [NSData dataWithContentsOfFile:@"/usr/sbin/mediaserverd" options:NSDataReadingMappedIfSafe error:nil];
    BOOL patched = msd && [msd rangeOfData:[@"/var/jb/usr/lib/libvivavt.dylib" dataUsingEncoding:NSUTF8StringEncoding]
                                   options:0 range:NSMakeRange(0, msd.length)].location != NSNotFound;
    BOOL dylib = [NSFileManager.defaultManager fileExistsAtPath:@"/var/jb/usr/lib/libvivavt.dylib"];
    if (!patched) return @"mediaserverd originale: VideoToolbox decodifica in software (vdec vt/msd.sh per installarlo)";
    if (!dylib) return @"mediaserverd modificato ma libvivavt.dylib è spenta (vt-msd.sh on)";
    NSString *loaded = nil;
    NSUInteger creates = 0, errors = 0;
    for (NSString *l in VMVivaVTLines()) {
        if ([l containsString:@"loaded into mediaserverd"]) { loaded = l; creates = 0; errors = 0; }
        if ([l containsString:@"] layout 0:"]) creates++;      // a session the VDEC accepted
        if ([l containsString:@"error"]) errors++;
    }
    if (!loaded) return @"libvivavt installata, non ancora caricata da mediaserverd (log vuoto)";
    NSArray *w = [loaded componentsSeparatedByString:@" "];
    return [NSString stringWithFormat:@"Attivo in mediaserverd %@ dalle %@: %lu sessioni, %lu errori", w.count > 1 ? w[1] : @"",
            w.firstObject, (unsigned long)creates, (unsigned long)errors];
}

// ---- Screen -------------------------------------------------------------------------------------------------------------

enum { SecState, SecNext, SecScaler, SecJpeg, SecMPS, SecVideo, SecCount };

@implementation VMAccelViewController {
    NSDictionary *_scaler, *_jpeg;                  // registry properties (nil: not published)
    NSString *_bootargs;                            // current kernel command line
    NSMutableArray<NSString *> *_next;              // next boot tokens
    NSString *_nextSource, *_nextSaved;
    VMAccelTestResult *_scalerTest, *_jpegTest;
    NSString *_mpsOutput, *_videoOutput;
    NSDictionary *_vdec;                            // VivaVDEC registry properties (nil: not published)
    BOOL _running;
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Acceleratori";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Salva" style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(save)];
    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(pullRefresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;
    [self reload];
}

- (void)pullRefresh:(UIRefreshControl *)rc { [self reload]; [rc endRefreshing]; }

- (void)reload {
    _scaler = VMServiceProperties("AppleM2ScalerCSCDriver");
    _jpeg = VMServiceProperties("AppleJPEGDriver");
    _vdec = VMServiceProperties("VivaVDEC");
    _bootargs = [VMSystem sysctlString:"kern.bootargs"] ?: @"";
    VMRunHelper(@[@"bootargs-get"], nil, ^(int status, NSString *out) {
        NSArray *lines = [out componentsSeparatedByString:@"\n"];
        NSString *line = status == 0 && lines.count > 1 && [lines[1] length] ? lines[1] : self->_bootargs;
        self->_nextSource = status == 0 && lines.count ? lines[0] : @"none";
        self->_next = [NSMutableArray array];
        for (NSString *t in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) if (t.length) [self->_next addObject:t];
        self->_nextSaved = [self->_next componentsJoinedByString:@" "];
        [self.tableView reloadData];
        [self updateSave];
    });
    [self.tableView reloadData];
}

- (void)updateSave {
    self.navigationItem.rightBarButtonItem.enabled = _next && ![[_next componentsJoinedByString:@" "] isEqualToString:_nextSaved];
}

// Boot-arg value in a token list (nil: absent).
static NSString *VMArg(NSArray<NSString *> *tokens, NSString *key) {
    NSString *p = [key stringByAppendingString:@"="];
    for (NSString *t in tokens) if ([t hasPrefix:p]) return [t substringFromIndex:p.length];
    return nil;
}

- (void)setNext:(NSString *)key value:(nullable NSString *)value {
    NSString *p = [key stringByAppendingString:@"="];
    NSUInteger i = [_next indexOfObjectPassingTest:^BOOL(NSString *t, NSUInteger idx, BOOL *stop) { return [t hasPrefix:p]; }];
    if (i != NSNotFound) [_next removeObjectAtIndex:i];
    if (value) [_next addObject:[p stringByAppendingString:value]];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SecNext] withRowAnimation:UITableViewRowAnimationNone];
    [self updateSave];
}

- (void)save {
    NSString *line = [_next componentsJoinedByString:@" "];
    VMRunHelper(@[@"bootargs-set"], line, ^(int status, NSString *out) {
        if (status != 0) { VMAlert(self, @"Boot-arg non salvati", out); return; }
        self->_nextSaved = line;
        [self updateSave];
        VMToast(self, [out hasPrefix:@"kernel"] ? @"Salvati: valgono dal prossimo riavvio" : @"Salvati nel file (kernel senza KA2)");
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return SecCount; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
    case SecState: return @"Kernel in esecuzione";
    case SecNext: return @"Prossimo avvio";
    case SecScaler: return @"Test scaler (sorgente · riferimento CPU · servizio)";
    case SecJpeg: return @"Test JPEG (sorgente · JPEG decodificato)";
    case SecMPS: return @"MetalPerformanceShaders su MaliMetal";
    default: return @"Video (VDEC, decodifica hardware)";
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    switch (s) {
    case SecNext: return @"Scaler: 1 = CPU nel kernel, 2 = motori MDP (con ripiego CPU). Con lo scaler pubblicato VideoToolbox gli manda tutte le sue conversioni: i formati spenti vengono rifiutati e lui ripiega da solo. Le modifiche valgono dopo il riavvio.";
    case SecVideo: return @"Decoder clean-room (repo vdec): la libreria genera il programma di registri di ogni immagine, il kernel (VivaVDEC) lo esegue sul VDEC. iOS decodifica ogni sessione VideoToolbox dentro mediaserverd: lì è caricato il nostro decoder, scelto per H.264 e HEVC (Main, Main 10). Quello che il VDEC non sa fare resta al decoder software di iOS. L'encoder video (venc) non è ancora fatto.";
    default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
    case SecState: return 2;
    case SecNext: return 4;
    case SecScaler: return _scalerTest ? 3 : 2;
    case SecJpeg: return _jpegTest ? 2 : 1;
    case SecMPS: return _mpsOutput ? 2 : 1;
    default: return _videoOutput ? 4 : 3;
    }
}

static NSString *VMStatsLine(NSDictionary *stats, NSArray<NSString *> *keys) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in keys) if (stats[k]) [parts addObject:[NSString stringWithFormat:@"%@ %@", k, stats[k]]];
    return [parts componentsJoinedByString:@" · "];
}

- (UITableViewCell *)subtitleCell:(NSString *)title detail:(NSString *)detail {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.text = title;
    c.detailTextLabel.text = detail;
    c.detailTextLabel.numberOfLines = 0;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == SecState) {
        if (ip.row == 0) {
            NSString *d = _scaler ? [NSString stringWithFormat:@"Pubblicato, backend %@, formati 0x%@\n%@", _scaler[@"VivaScalerBackend"] ?: @"?",
                                      [NSString stringWithFormat:@"%x", [_scaler[@"VivaScalerFormats"] unsignedIntValue]],
                                      VMStatsLine(_scaler[@"VivaScalerStats"], @[@"transfers", @"cpu", @"mdp", @"unsupported", @"errors", @"clients"])]
                                  : [NSString stringWithFormat:@"Non pubblicato (vivascaler=%@)", VMArg([_bootargs componentsSeparatedByString:@" "], @"vivascaler") ?: @"0"];
            return [self subtitleCell:@"Scaler (AppleM2ScalerCSCDriver)" detail:d];
        }
        NSString *d = _jpeg ? [NSString stringWithFormat:@"Pubblicato, encoder jpgenc\n%@", VMStatsLine(_jpeg[@"VivaJPEGStats"] ?: @{}, @[@"encodes", @"failures", @"refused", @"bytes"])]
                            : [NSString stringWithFormat:@"Non pubblicato (vivajpeg=%@)", VMArg([_bootargs componentsSeparatedByString:@" "], @"vivajpeg") ?: @"0"];
        return [self subtitleCell:@"JPEG (AppleJPEGDriver, solo codifica)" detail:d];
    }
    if (ip.section == SecNext) {
        if (!_next) return [self subtitleCell:@"Lettura dei boot-arg…" detail:nil];
        if (ip.row == 0) {
            UITableViewCell *c = [self subtitleCell:@"Scaler" detail:nil];
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Spento", @"CPU", @"MDP"]];
            seg.selectedSegmentIndex = MIN(MAX([VMArg(_next, @"vivascaler") intValue], 0), 2);
            [seg addTarget:self action:@selector(scalerMode:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = seg;
            return c;
        }
        if (ip.row == 1 || ip.row == 2) {
            int mask = VMArg(_next, @"vivascalerformats") ? [VMArg(_next, @"vivascalerformats") intValue] : 3;
            int bit = ip.row == 1 ? 1 : 2;
            UITableViewCell *c = [self subtitleCell:ip.row == 1 ? @"Formati RGB a 32 bit" : @"Sorgenti YUV 4:2:0 (video)"
                                             detail:ip.row == 1 ? @"BGRA/RGBA/ARGB, scala e copia" : @"420v/420f → RGB (BT.601/709)"];
            VMSwitch *sw = [VMSwitch new];
            sw.on = (mask & bit) != 0;
            sw.onChange = ^(BOOL on) {
                int m = (mask & ~bit) | (on ? bit : 0);
                [self setNext:@"vivascalerformats" value:m == 3 ? nil : [NSString stringWithFormat:@"%d", m]];
            };
            c.accessoryView = sw;
            return c;
        }
        UITableViewCell *c = [self subtitleCell:@"Encoder JPEG hardware" detail:@"Codifica NV12/NV21 con jpgenc; la decodifica resta software"];
        VMSwitch *sw = [VMSwitch new];
        sw.on = [VMArg(_next, @"vivajpeg") intValue] > 0;
        sw.onChange = ^(BOOL on) { [self setNext:@"vivajpeg" value:on ? @"1" : nil]; };
        c.accessoryView = sw;
        return c;
    }
    if (ip.section == SecScaler) {
        if (ip.row <= 1) {
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            c.textLabel.text = _running ? @"In esecuzione…" : ip.row == 0 ? @"Test BGRA → BGRA con scala (CPU)" : @"Test NV12 (420f) → BGRA stessa dimensione (MDP)";
            c.textLabel.textColor = self.view.tintColor;
            return c;
        }
        UITableViewCell *c = [self subtitleCell:_scalerTest.summary detail:nil];
        c.textLabel.numberOfLines = 0;
        if (_scalerTest.source) {
            UIStackView *row = [UIStackView new];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.distribution = UIStackViewDistributionFillEqually;
            row.spacing = 6;
            for (UIImage *img in @[_scalerTest.source, _scalerTest.reference ?: [UIImage new], _scalerTest.result ?: [UIImage new]]) {
                UIImageView *v = [[UIImageView alloc] initWithImage:img];
                v.contentMode = UIViewContentModeScaleAspectFit;
                v.layer.magnificationFilter = kCAFilterNearest;
                [row addArrangedSubview:v];
            }
            row.frame = CGRectMake(0, 0, 300, 90);
            c.accessoryView = row;
        }
        return c;
    }
    if (ip.section == SecJpeg) {
        if (ip.row == 0) {
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            c.textLabel.text = _running ? @"In esecuzione…" : @"Esegui il test JPEG (VideoToolbox)";
            c.textLabel.textColor = self.view.tintColor;
            return c;
        }
        UITableViewCell *c = [self subtitleCell:_jpegTest.summary detail:nil];
        c.textLabel.numberOfLines = 0;
        if (_jpegTest.source) {
            UIStackView *row = [UIStackView new];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.distribution = UIStackViewDistributionFillEqually;
            row.spacing = 6;
            for (UIImage *img in @[_jpegTest.source, _jpegTest.result ?: [UIImage new]]) {
                UIImageView *v = [[UIImageView alloc] initWithImage:img];
                v.contentMode = UIViewContentModeScaleAspectFit;
                [row addArrangedSubview:v];
            }
            row.frame = CGRectMake(0, 0, 200, 75);
            c.accessoryView = row;
        }
        return c;
    }
    if (ip.section == SecMPS) {
        if (ip.row == 0) {
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            c.textLabel.text = _running ? @"In esecuzione…" : @"Esegui mpstest (blur, Sobel, Lanczos, conversione, matmul, MPSGraph)";
            c.textLabel.numberOfLines = 0;
            c.textLabel.textColor = self.view.tintColor;
            return c;
        }
        UITableViewCell *c = [self subtitleCell:@"Risultato" detail:_mpsOutput];
        c.detailTextLabel.font = VMMono(11);
        return c;
    }
    if (ip.row == 0)
        return [self subtitleCell:@"Decoder video hardware (VivaVDEC)"
                           detail:_vdec ? @"Pubblicato: H.264 (High, fino a 4:2:0 8 bit) e HEVC (Main, Main 10)"
                                        : @"Non pubblicato (kernel senza la patch 0213)"];
    if (ip.row == 1) return [self subtitleCell:@"VideoToolbox" detail:VMVideoState()];
    if (ip.row == 2) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = _running ? @"In esecuzione…" : @"Prova di decodifica (H.264, HEVC, HEVC 10 bit)";
        c.textLabel.textColor = self.view.tintColor;
        return c;
    }
    UITableViewCell *c = [self subtitleCell:@"Risultato" detail:_videoOutput];
    c.detailTextLabel.font = VMMono(11);
    return c;
}

- (void)scalerMode:(UISegmentedControl *)seg {
    [self setNext:@"vivascaler" value:seg.selectedSegmentIndex ? [NSString stringWithFormat:@"%ld", (long)seg.selectedSegmentIndex] : nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (_running || ip.row > (ip.section == SecScaler ? 1 : ip.section == SecVideo ? 2 : 0)) return;
    if (ip.section == SecVideo && ip.row != 2) return;
    if (ip.section == SecScaler) {
        _running = YES;
        BOOL nv12 = ip.row == 1;
        [tv reloadSections:[NSIndexSet indexSetWithIndex:SecScaler] withRowAnimation:UITableViewRowAnimationNone];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            VMAccelTestResult *r = nv12 ? VMRunNV12Test() : VMRunScalerTest();
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_running = NO;
                self->_scalerTest = r;
                self->_scaler = VMServiceProperties("AppleM2ScalerCSCDriver");
                [tv reloadData];
            });
        });
    } else if (ip.section == SecJpeg) {
        _running = YES;
        [tv reloadSections:[NSIndexSet indexSetWithIndex:SecJpeg] withRowAnimation:UITableViewRowAnimationNone];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            VMAccelTestResult *r = VMRunJpegTest();
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_running = NO;
                self->_jpegTest = r;
                self->_jpeg = VMServiceProperties("AppleJPEGDriver");
                [tv reloadData];
            });
        });
    } else if (ip.section == SecVideo) {
        _running = YES;
        [tv reloadSections:[NSIndexSet indexSetWithIndex:SecVideo] withRowAnimation:UITableViewRowAnimationNone];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *r = VMRunVideoTest();
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_running = NO;
                self->_videoOutput = r;
                [tv reloadData];
            });
        });
    } else if (ip.section == SecMPS) {
        _running = YES;
        [tv reloadSections:[NSIndexSet indexSetWithIndex:SecMPS] withRowAnimation:UITableViewRowAnimationNone];
        VMRunHelper(@[@"mpstest"], nil, ^(int status, NSString *out) {
            self->_running = NO;
            self->_mpsOutput = out.length ? out : [NSString stringWithFormat:@"(nessun output, stato %d)", status];
            [tv reloadData];
        });
    }
}

@end
