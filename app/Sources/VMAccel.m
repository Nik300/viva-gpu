// Acceleratori: MaliMetal subpage for the hardware services that stand in for the iPhone's accelerators
// (docs/ANALISI-ACCELERATORI-2026-11-04.md): the scaler (AppleM2ScalerCSCDriver, kernel VivaScaler.cpp), the JPEG
// encoder (AppleJPEGDriver, VivaJPEG.cpp), MetalPerformanceShaders on MaliMetal (mpstest) and video (not possible:
// MediaTek's decoder is driven by the proprietary vpud daemon). Shows what the running kernel publishes, edits the
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

// ---- Screen -------------------------------------------------------------------------------------------------------------

enum { SecState, SecNext, SecScaler, SecJpeg, SecMPS, SecVideo, SecCount };

@implementation VMAccelViewController {
    NSDictionary *_scaler, *_jpeg;                  // registry properties (nil: not published)
    NSString *_bootargs;                            // current kernel command line
    NSMutableArray<NSString *> *_next;              // next boot tokens
    NSString *_nextSource, *_nextSaved;
    VMAccelTestResult *_scalerTest, *_jpegTest;
    NSString *_mpsOutput;
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
    default: return @"Video";
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    switch (s) {
    case SecNext: return @"Scaler: 1 = CPU nel kernel, 2 = motori MDP (con ripiego CPU). Con lo scaler pubblicato VideoToolbox gli manda tutte le sue conversioni: i formati spenti vengono rifiutati e lui ripiega da solo. Le modifiche valgono dopo il riavvio.";
    case SecVideo: return @"Il decoder/encoder video di MT6781 è programmato dal demone proprietario vpud di Android (il kernel Linux gli inoltra solo messaggi): senza quel codice non c'è un driver possibile. VideoToolbox continua a decodificare in software.";
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
    default: return 1;
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
    return [self subtitleCell:@"Decoder/encoder video (AppleAVD/AVE2)" detail:@"Non disponibile su MT6781"];
}

- (void)scalerMode:(UISegmentedControl *)seg {
    [self setNext:@"vivascaler" value:seg.selectedSegmentIndex ? [NSString stringWithFormat:@"%ld", (long)seg.selectedSegmentIndex] : nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (_running || ip.row > (ip.section == SecScaler ? 1 : 0)) return;
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
