// vctl: drives the phone's UI from the USB link (viva-link.py run -- /private/var/root/viva-tests/vctl ...), so the
// driver can be tested on real screens without anyone holding the phone.
//   vctl open BUNDLE-ID              launch / bring an app to the front (com.apple.Preferences, ...)
//   vctl tap X Y                     one finger, X Y in 0..1 of the screen (portrait, origin top left)
//   vctl swipe X1 Y1 X2 Y2 [MS]      drag (default 300 ms)
//   vctl home                        the home button
//   vctl shot PATH                   the render server's framebuffers as PATH-N.png
//   vctl burst PATH N MS [CMD ...]   N frames MS apart (changed framebuffers, 1:3) while CMD runs
//   vctl surf ID PATH                one IOSurface's planes as PATH-pN.raw (+ layout, how much is non-zero)
//   vctl ls DIR                      directory listing, newest first (iOS has no ls)
//   vctl unlock                      unlock (no passcode) through FrontBoard
//   vctl kill NAME [SIG]             signal every process with that name (default SIGKILL; iOS has no kill):
//                                    `vctl kill backboardd` restarts the render server with a new driver (launchd
//                                    starts it again, SpringBoard follows)
// Touches are digitizer events dispatched into backboardd's HID event system (private IOKit HID API, entitlement
// com.apple.private.hid.client.event-dispatch, see vctl.entitlements); apps open through SpringBoardServices.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <signal.h>
#import <sys/sysctl.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int type, CFDictionaryRef);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t ts, uint32_t transducer, uint32_t index, uint32_t identity,
                                             uint32_t mask, uint32_t buttons, double x, double y, double z, double tip,
                                             double barrel, Boolean range, Boolean touch, uint32_t options);
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t ts, uint32_t index, uint32_t identity, uint32_t mask,
                                                   double x, double y, double z, double tip, double twist, Boolean range,
                                                   Boolean touch, uint32_t options);
IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t ts, uint32_t page, uint32_t usage, Boolean down, uint32_t flags);
void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, long value);
void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
CFTypeRef IOHIDServiceClientGetRegistryID(IOHIDServiceClientRef);

enum { kHand = 3, kRange = 1, kTouch = 2, kPosition = 4, kIdentity = 32 };
#define kDigitizerIsDisplayIntegrated ((11u << 16) | 25)   // kIOHIDEventTypeDigitizer, field 25
static const uint64_t kSender = 0x000000010000027Full;      // a digitizer-like sender id

static IOHIDEventSystemClientRef client(void) {
    // Admin (0) can dispatch; a plain IOHIDEventSystemClientCreate client (monitor) cannot. VCTL_CLIENT_TYPE overrides.
    static IOHIDEventSystemClientRef c;
    if (!c) {
        const char *t = getenv("VCTL_CLIENT_TYPE");
        c = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, t ? atoi(t) : 0, NULL);
        if (getenv("VCTL_VERBOSE")) fprintf(stderr, "vctl: HID client %p (type %d)\n", (void *)c, t ? atoi(t) : 0);
    }
    return c;
}

// backboardd routes touches by sender: the phone's own touchscreen service (primary usage page 0x0D, digitizer),
// else a digitizer-like id. VCTL_SENDER overrides.
static uint64_t sender(void) {
    static uint64_t id;
    if (id) return id;
    id = kSender;
    if (getenv("VCTL_SENDER")) return id = strtoull(getenv("VCTL_SENDER"), NULL, 0);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client());
    for (CFIndex i = 0; services && i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef sv = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        NSNumber *page = CFBridgingRelease(IOHIDServiceClientCopyProperty(sv, CFSTR("PrimaryUsagePage")));
        NSNumber *usage = CFBridgingRelease(IOHIDServiceClientCopyProperty(sv, CFSTR("PrimaryUsage")));
        NSNumber *reg = (__bridge NSNumber *)IOHIDServiceClientGetRegistryID(sv);
        if (getenv("VCTL_VERBOSE"))
            fprintf(stderr, "vctl: service 0x%llx page 0x%x usage 0x%x\n", reg.unsignedLongLongValue, page.unsignedIntValue, usage.unsignedIntValue);
        if (page.unsignedIntValue == 0x0d && reg) id = reg.unsignedLongLongValue;
    }
    if (services) CFRelease(services);
    if (getenv("VCTL_VERBOSE")) fprintf(stderr, "vctl: sender 0x%llx\n", id);
    return id;
}

static void send(IOHIDEventRef e) {
    IOHIDEventSetSenderID(e, sender());
    IOHIDEventSystemClientDispatchEvent(client(), e);
    CFRelease(e);
}

static void finger(double x, double y, bool down, bool moved) {
    uint64_t ts = mach_absolute_time();
    uint32_t mask = (moved ? kPosition : kRange | kTouch | kIdentity);
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, kHand, 0, 0, mask, 0, x, y, 0, 0, 0,
                                                        down, down, 0);
    IOHIDEventSetIntegerValue(hand, kDigitizerIsDisplayIntegrated, 1);
    IOHIDEventRef f = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, 1, 2, mask, x, y, 0, down ? 1 : 0, 0,
                                                           down, down, 0);
    IOHIDEventAppendEvent(hand, f, 0);
    CFRelease(f);
    send(hand);
}

static void drag(double x1, double y1, double x2, double y2, int ms) {
    finger(x1, y1, true, false);
    int steps = ms > 0 ? ms / 16 : 0;
    for (int i = 1; i <= steps; i++) {
        usleep(16000);
        double t = (double)i / steps;
        finger(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, true, true);
    }
    usleep(50000);
    finger(x2, y2, false, false);
}

static void key(uint32_t page, uint32_t usage) {
    send(IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, true, 0));
    usleep(80000);
    send(IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, false, 0));
}

// FrontBoard's open service also unlocks a phone without passcode (__UnlockDevice).
static int open_frontboard(NSString *bundle) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    Class svc = NSClassFromString(@"FBSOpenApplicationService"), opt = NSClassFromString(@"FBSOpenApplicationOptions");
    if (!svc || !opt || ![svc respondsToSelector:@selector(serviceWithDefaultShellEndpoint)]) return -1;
    id s = [svc performSelector:@selector(serviceWithDefaultShellEndpoint)];
    id o = [opt performSelector:@selector(optionsWithDictionary:) withObject:@{ @"__UnlockDevice": @YES, @"__ActivateSuspended": @NO }];
    __block int result = 1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    SEL open = NSSelectorFromString(@"openApplication:withOptions:completion:");
    if (![s respondsToSelector:open]) return -1;
    void (^completion)(id, NSError *) = ^(id process, NSError *e) {
        if (e) fprintf(stderr, "FBSOpenApplicationService: %s\n", e.description.UTF8String);
        result = e ? 1 : 0;
        dispatch_semaphore_signal(done);
    };
    ((void (*)(id, SEL, id, id, id))[s methodForSelector:open])(s, open, bundle, o, completion);
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return result;
}

static int open_app(NSString *bundle) {
    if (open_frontboard(bundle) == 0) return 0;
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    int (*launch)(CFStringRef, Boolean) = sbs ? (int (*)(CFStringRef, Boolean))dlsym(sbs, "SBSLaunchApplicationWithIdentifier") : NULL;
    if (launch) {
        int r = launch((__bridge CFStringRef)bundle, false);
        if (r == 0) return 0;
        fprintf(stderr, "SBSLaunchApplicationWithIdentifier: %d, trying LSApplicationWorkspace\n", r);
    }
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    id w = [ws performSelector:@selector(defaultWorkspace)];
    BOOL ok = [w respondsToSelector:@selector(openApplicationWithBundleID:)] &&
              ((BOOL (*)(id, SEL, id))[w methodForSelector:@selector(openApplicationWithBundleID:)])(w, @selector(openApplicationWithBundleID:), bundle);
    return ok ? 0 : 1;
}

// The render server's framebuffers: IOSurfaces of the screen's size (1125x2436, BGRA), written as PATH-N.png (one per
// surface found; the front one is the newest). Faster than dumping the scanout layer with the link's peek.
IOSurfaceRef IOSurfaceLookup(IOSurfaceID);
static int shot(const char *path) {
    int found = 0;
    for (IOSurfaceID sid = 1; sid < 8192; sid++) {
        IOSurfaceRef sf = IOSurfaceLookup(sid);
        if (!sf) continue;
        size_t w = IOSurfaceGetWidth(sf), h = IOSurfaceGetHeight(sf);
        uint32_t fmt = IOSurfaceGetPixelFormat(sf);
        if (getenv("VCTL_VERBOSE") && w >= 256) fprintf(stderr, "vctl: surface %u %zux%zu '%.4s' seed %u\n", sid, w, h, (char *)&(uint32_t){ __builtin_bswap32(fmt) }, IOSurfaceGetSeed(sf));
        if (w < 1000 || h < 2000 || (fmt != 'BGRA' && fmt != 'ARGB')) { CFRelease(sf); continue; }
        IOSurfaceLock(sf, kIOSurfaceLockReadOnly, NULL);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef c = CGBitmapContextCreate(IOSurfaceGetBaseAddress(sf), w, h, 8, IOSurfaceGetBytesPerRow(sf), cs,
                                               kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGImageRef img = c ? CGBitmapContextCreateImage(c) : NULL;
        IOSurfaceUnlock(sf, kIOSurfaceLockReadOnly, NULL);
        if (img) {
            NSString *out = [NSString stringWithFormat:@"%s-%d.png", path, found];
            CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:out], CFSTR("public.png"), 1, NULL);
            CGImageDestinationAddImage(d, img, NULL);
            CGImageDestinationFinalize(d);
            CFRelease(d);
            CGImageRelease(img);
            printf("%s: surface %u %zux%zu seed %u\n", out.UTF8String, sid, w, h, IOSurfaceGetSeed(sf));
            found++;
        }
        if (c) CGContextRelease(c);
        CGColorSpaceRelease(cs);
        CFRelease(sf);
    }
    if (!found) fprintf(stderr, "vctl: no framebuffer surface found\n");
    return found ? 0 : 1;
}

// burst PATH N MS [ACTION ARGS...]: while ACTION runs (tap/swipe/open/home), N captures MS apart of the screen-sized
// surfaces whose content changed (downsampled 1:3, BGRA), written afterwards as PATH-NNN.png: animation frames.
static int dispatch_action(int argc, char **argv);
static int burst(const char *path, int n, int ms, int argc, char **argv) {
    IOSurfaceRef surf[4]; int ns = 0;
    for (IOSurfaceID sid = 1; sid < 8192 && ns < 4; sid++) {
        IOSurfaceRef sf = IOSurfaceLookup(sid);
        if (!sf) continue;
        // The panel's scanout surface (1080x2400, AppleCLCD copies each presented frame into it): what the screen
        // shows. The render server's 1125x2436 pair includes the back buffer being drawn (VCTL_BURST_RS=1 for those).
        bool rs = getenv("VCTL_BURST_RS") != NULL;
        size_t w = IOSurfaceGetWidth(sf), h = IOSurfaceGetHeight(sf);
        if (rs ? (w == 1125 && h == 2436) : (w == 1080 && h == 2400)) surf[ns++] = sf; else CFRelease(sf);
    }
    if (!ns) { fprintf(stderr, "vctl: no framebuffer surface\n"); return 1; }
    enum { DW = 360, DH = 800 };   // 1:3 of 1080x2400 (of 1125x2436: the top left 1080x2400)
    uint8_t **frames = calloc(n, sizeof *frames);
    double *when = calloc(n, sizeof *when);
    uint32_t seen[4] = {0};
    __block int done = 0;
    double t0 = CFAbsoluteTimeGetCurrent();
    if (argc > 0) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ dispatch_action(argc, argv); done = 1; });
    int got = 0;
    for (int i = 0; i < n * 4 && got < n; i++) {
        for (int k = 0; k < ns && got < n; k++) {
            // The GPU's writes do not bump the seed: a hash of a sparse grid of pixels tells a new frame.
            IOSurfaceLock(surf[k], kIOSurfaceLockReadOnly, NULL);
            const uint8_t *src = IOSurfaceGetBaseAddress(surf[k]);
            size_t bpr = IOSurfaceGetBytesPerRow(surf[k]);
            uint32_t seed = 2166136261u;
            for (int y = 0; y < (int)IOSurfaceGetHeight(surf[k]); y += 29)
                for (int x = 0; x < (int)IOSurfaceGetWidth(surf[k]); x += 17) seed = (seed ^ *(const uint32_t *)(src + y * bpr + x * 4)) * 16777619u;
            if (seed == seen[k]) { IOSurfaceUnlock(surf[k], kIOSurfaceLockReadOnly, NULL); continue; }
            seen[k] = seed;
            uint8_t *dst = frames[got] = malloc(DW * DH * 4);
            for (int y = 0; y < DH; y++)
                for (int x = 0; x < DW; x++) memcpy(dst + (y * DW + x) * 4, src + (y * 3) * bpr + (x * 3) * 4, 4);
            IOSurfaceUnlock(surf[k], kIOSurfaceLockReadOnly, NULL);
            when[got++] = CFAbsoluteTimeGetCurrent() - t0;
        }
        usleep(ms * 1000 / 4);
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    for (int i = 0; i < got; i++) {
        CGContextRef c = CGBitmapContextCreate(frames[i], DW, DH, 8, DW * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGImageRef img = CGBitmapContextCreateImage(c);
        NSString *out = [NSString stringWithFormat:@"%s-%03d.png", path, i];
        CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:out], CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(d, img, NULL);
        CGImageDestinationFinalize(d);
        CFRelease(d); CGImageRelease(img); CGContextRelease(c); free(frames[i]);
        printf("%s %.0f ms\n", out.UTF8String, when[i] * 1000);
    }
    CGColorSpaceRelease(cs);
    for (int k = 0; k < ns; k++) CFRelease(surf[k]);
    while (argc > 0 && !done) usleep(10000);
    return got ? 0 : 1;
}

// surf ID PATH: one IOSurface's planes as raw files PATH-pN.raw (and its layout on stdout), to look at its content.
static int surf(IOSurfaceID sid, const char *path) {
    IOSurfaceRef sf = IOSurfaceLookup(sid);
    if (!sf) { fprintf(stderr, "vctl: no surface %u\n", sid); return 1; }
    uint32_t fmt = IOSurfaceGetPixelFormat(sf);
    size_t planes = IOSurfaceGetPlaneCount(sf);
    printf("surface %u %zux%zu '%c%c%c%c' bpr %zu planes %zu seed %u\n", sid, IOSurfaceGetWidth(sf), IOSurfaceGetHeight(sf),
           fmt >> 24, fmt >> 16, fmt >> 8, fmt, IOSurfaceGetBytesPerRow(sf), planes, IOSurfaceGetSeed(sf));
    IOSurfaceLock(sf, kIOSurfaceLockReadOnly, NULL);
    for (size_t p = 0; p < (planes ? planes : 1); p++) {
        const uint8_t *b = planes ? IOSurfaceGetBaseAddressOfPlane(sf, p) : IOSurfaceGetBaseAddress(sf);
        size_t bpr = planes ? IOSurfaceGetBytesPerRowOfPlane(sf, p) : IOSurfaceGetBytesPerRow(sf);
        size_t h = planes ? IOSurfaceGetHeightOfPlane(sf, p) : IOSurfaceGetHeight(sf);
        size_t w = planes ? IOSurfaceGetWidthOfPlane(sf, p) : IOSurfaceGetWidth(sf);
        size_t nz = 0;
        for (size_t i = 0; i < bpr * h; i += 97) nz += b[i] != 0;
        printf("  plane %zu %zux%zu bpr %zu, %zu%% of samples non-zero\n", p, w, h, bpr, nz * 100 / (bpr * h / 97 + 1));
        char out[512];
        snprintf(out, sizeof out, "%s-p%zu.raw", path, p);
        FILE *f = fopen(out, "wb");
        if (f) { fwrite(b, 1, bpr * h, f); fclose(f); }
    }
    IOSurfaceUnlock(sf, kIOSurfaceLockReadOnly, NULL);
    CFRelease(sf);
    return 0;
}

// iOS has no /bin/ls: newest first, size and date.
static int ls(const char *dir) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *e = nil;
    NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:@(dir)]
                                includingPropertiesForKeys:@[ NSURLContentModificationDateKey, NSURLFileSizeKey ] options:0 error:&e];
    if (!items) { fprintf(stderr, "vctl: %s\n", e.description.UTF8String); return 1; }
    NSArray *sorted = [items sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da, *db;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [db compare:da];
    }];
    for (NSURL *u in sorted) {
        NSDate *d; NSNumber *n;
        [u getResourceValue:&d forKey:NSURLContentModificationDateKey error:nil];
        [u getResourceValue:&n forKey:NSURLFileSizeKey error:nil];
        printf("%10llu  %s  %s\n", n.unsignedLongLongValue, d.description.UTF8String, u.lastPathComponent.UTF8String);
    }
    return 0;
}

// kill NAME [SIG]: every process whose name (p_comm) is NAME.
static int killName(const char *name, int sig) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0)) { perror("vctl: sysctl"); return 1; }
    size += size / 4;
    struct kinfo_proc *procs = malloc(size);
    if (!procs || sysctl(mib, 3, procs, &size, NULL, 0)) { perror("vctl: sysctl"); free(procs); return 1; }
    int n = (int)(size / sizeof *procs), hit = 0;
    for (int i = 0; i < n; i++) {
        if (strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN)) continue;
        pid_t pid = procs[i].kp_proc.p_pid;
        if (kill(pid, sig)) printf("%s[%d]: %s\n", name, pid, strerror(errno));
        else { printf("%s[%d]: signal %d\n", name, pid, sig); hit++; }
    }
    free(procs);
    return hit ? 0 : 1;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) {
        fprintf(stderr, "usage: vctl open BUNDLE | tap X Y | swipe X1 Y1 X2 Y2 [MS] | home | unlock | shot PATH | ls DIR   (X Y in 0..1)\n");
        return 2;
    }
    if (!strcmp(argv[1], "kill") && argc >= 3) return killName(argv[2], argc >= 4 ? atoi(argv[3]) : SIGKILL);
    if (!strcmp(argv[1], "burst") && argc >= 5) return burst(argv[2], atoi(argv[3]), atoi(argv[4]), argc - 5, argv + 5);
    return dispatch_action(argc - 1, argv + 1);
} }

// One command: argv[0] is its name.
static int dispatch_action(int argc, char **argv) { @autoreleasepool {
    argc++; argv--;   // the parsing below counts the program name
    const char *cmd = argv[1];
    if (!strcmp(cmd, "open") && argc == 3) return open_app(@(argv[2]));
    if (!strcmp(cmd, "tap") && argc == 4) { drag(atof(argv[2]), atof(argv[3]), atof(argv[2]), atof(argv[3]), 0); usleep(100000); return 0; }
    if (!strcmp(cmd, "swipe") && argc >= 6) {
        drag(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]), argc > 6 ? atoi(argv[6]) : 300);
        usleep(100000);
        return 0;
    }
    if (!strcmp(cmd, "ls") && argc == 3) return ls(argv[2]);
    if (!strcmp(cmd, "surf") && argc == 4) return surf((IOSurfaceID)atoi(argv[2]), argv[3]);
    if (!strcmp(cmd, "shot") && argc == 3) return shot(argv[2]);
    if (!strcmp(cmd, "unlock")) return open_frontboard(@"com.apple.springboard") == 0 ? 0 : open_app(@"com.apple.Preferences");
    if (!strcmp(cmd, "home")) { key(0x0c, 0x40); return 0; }   // consumer page, Menu (the home button)
    fprintf(stderr, "vctl: unknown command %s\n", cmd);
    return 2;
} }
