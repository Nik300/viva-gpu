// TeraScale Metal Shim - system integration (Phase 4). Metal.framework finds this code through the
// IOAccelerator properties MetalPluginName/MetalPluginClassName (set by TSMetalEnabler.kext) and loads
// /Library/GPUBundles/TeraScaleMTLDriver.bundle into any process that enumerates devices. This file
// decides, once per process, whether the shim serves that process (per-app policy), and feeds the
// control app's statistics. Contract: docs/FASE4-INTERFACCE.md.
#import "TSPrivate.h"
#import "TSMetal.h"
#import <mach-o/dyld.h>
#import <mach/mach_time.h>
#import <notify.h>
#import <os/lock.h>
#import <IOKit/IOKitLib.h>
#import <pwd.h>

#pragma mark - Identity and policy

NSString *TSMtlConfigDir(void) {
    const char *dir = getenv("TSMTL_CONFIG_DIR");
    return dir && *dir ? @(dir) : @"/Library/GPUBundles/TeraScaleMTLDriver.config";
}
#define TSConfigDir TSMtlConfigDir

// The outermost .app around the executable, so helpers, XPC services and extensions follow their app.
// Outside any .app, a system XPC service is named by its .xpc bundle (com.apple.WebKit.GPU, ...).
static void TSIdentify(NSString *__strong *appId, NSString *__strong *name, NSString *__strong *appPath) {
    char raw[PATH_MAX], exe[PATH_MAX];
    uint32_t size = sizeof raw;
    if (_NSGetExecutablePath(raw, &size) != 0 || !realpath(raw, exe)) strlcpy(exe, getprogname(), sizeof exe);
    NSString *path = @(exe);
    NSRange app = [path rangeOfString:@".app/"];
    if (app.location == NSNotFound) app = [path rangeOfString:@".xpc/"];
    if (app.location != NSNotFound) {
        NSString *bundlePath = [path substringToIndex:NSMaxRange(app) - 1];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *ident = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? info[@"CFBundleIdentifier"] : nil;
        if (ident.length) {
            NSString *display = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
            *appId = ident;
            *name = [display isKindOfClass:[NSString class]] && [display length] ? display
                                                                                  : bundlePath.lastPathComponent.stringByDeletingPathExtension;
            *appPath = bundlePath;
            return;
        }
    }
    *appId = [@"proc:" stringByAppendingString:path.lastPathComponent];
    *name = path.lastPathComponent;
    *appPath = path;
}

// Processes that draw the desktop with the OCLP OpenGL stack: never served, whatever the policy says.
static BOOL TSIsCritical(void) {
    static const char *const names[] = { "WindowServer", "loginwindow", "Dock", "SystemUIServer", "ControlCenter",
                                         "NotificationCenter", "WallpaperAgent", "WindowManager" };
    const char *me = getprogname();
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        if (!strcmp(me, names[i])) return YES;
    return NO;
}

// WebKit's GPU process draws WebGL for Safari (and for every app that embeds a web view); it is not
// inside Safari.app, so "auto" names it explicitly.
static BOOL TSIsAutoSystemService(NSString *appId) {
    return [appId isEqualToString:@"com.apple.WebKit.GPU"];
}

static BOOL TSInApplicationsFolder(NSString *appPath) {
    // The real home, not the sandbox container that NSHomeDirectory() returns inside sandboxed apps.
    struct passwd *pw = getpwuid(getuid());
    NSString *home = pw && pw->pw_dir ? @(pw->pw_dir) : NSHomeDirectory();
    NSArray *roots = @[ @"/Applications/", @"/System/Applications/", [home stringByAppendingString:@"/Applications/"],
                        @"/System/Volumes/Preboot/Cryptexes/App/System/Applications/" ];
    for (NSString *root in roots)
        if ([appPath hasPrefix:root]) return YES;
    return NO;
}

static BOOL tsInjected;   // device created through TSMtlCreateDevice (tests, DYLD injection)

// policy.plist, read once per process (changes apply to apps launched afterwards).
static NSDictionary *TSPolicyPlist(void) {
    static NSDictionary *plist;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        plist = [NSDictionary dictionaryWithContentsOfFile:[TSConfigDir() stringByAppendingPathComponent:@"policy.plist"]];
    });
    return plist;
}

static NSDictionary *TSDict(id v) { return [v isKindOfClass:[NSDictionary class]] ? v : nil; }

const TSMtlPolicy *TSMtlProcessPolicy(void) {
    static TSMtlPolicy policy;
    static NSString *appId, *name, *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TSIdentify(&appId, &name, &path);
        policy.appId = appId; policy.name = name; policy.path = path;
        NSDictionary *plist = TSPolicyPlist();
        NSDictionary *apps = [plist[@"Apps"] isKindOfClass:[NSDictionary class]] ? plist[@"Apps"] : nil;
        NSDictionary *entry = [apps[appId] isKindOfClass:[NSDictionary class]] ? apps[appId] : nil;
        id autoEnable = plist[@"AutoEnable"];
        if (tsInjected) {
            policy.enabled = YES; policy.reason = "injected";
        } else if (TSIsCritical()) {
            policy.enabled = NO; policy.reason = "critical";
        } else if ([entry[@"Enabled"] isKindOfClass:[NSNumber class]]) {
            policy.enabled = [entry[@"Enabled"] boolValue]; policy.reason = "list";
        } else if ((![autoEnable isKindOfClass:[NSNumber class]] || [autoEnable boolValue]) && (TSInApplicationsFolder(path) || TSIsAutoSystemService(appId))) {
            policy.enabled = YES; policy.reason = plist ? "auto" : "nopolicy";
        } else {
            policy.enabled = NO; policy.reason = "outside";
        }
        TSMtlLogAt(TSLogPolicy, NULL, @"policy: %s id=%@ reason=%s name=%@ path=%@", policy.enabled ? "on" : "off",
                   appId, policy.reason, name, path);
    });
    return &policy;
}

// TeraScale Compute (docs/PIANO-COMPUTE.md, "Policy"): System.Compute (Experimental.Compute until 0.9.0, still read
// when System.Compute is absent), decided once per process after the shim's own policy. Order: TSMTL_COMPUTE=0/1
// (tests, shim-run.sh), shim off, the app's entry, the global switch, on (off until 0.9.0).
BOOL TSMtlComputeEnabled(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const TSMtlPolicy *p = TSMtlProcessPolicy();
        NSDictionary *policy = TSPolicyPlist();
        NSDictionary *compute = TSDict(TSDict(policy[@"System"])[@"Compute"]) ?: TSDict(TSDict(policy[@"Experimental"])[@"Compute"]);
        NSDictionary *entry = TSDict(TSDict(compute[@"Apps"])[p->appId]);
        const char *env = getenv("TSMTL_COMPUTE"), *reason;
        if (env && *env) { on = strcmp(env, "0") != 0; reason = "env"; }
        else if (!p->enabled) { on = NO; reason = "shim-off"; }
        else if ([entry[@"Enabled"] isKindOfClass:[NSNumber class]]) { on = [entry[@"Enabled"] boolValue]; reason = "list"; }
        else if ([compute[@"Enabled"] isKindOfClass:[NSNumber class]]) { on = [compute[@"Enabled"] boolValue]; reason = "global"; }
        else { on = YES; reason = "default"; }
        NSString *version = [NSBundle bundleForClass:[TSMtlDevice class]].infoDictionary[@"CFBundleShortVersionString"] ?: @"dev";
        TSMtlLogAt(TSLogCompute, NULL, @"%s id=%@ reason=%s version=%@", on ? "on" : "off", p->appId, reason, version);
    });
    return on;
}

// TeraScale Swift (docs/OTTIMIZZAZIONE-SWIFT.md): System.Swift, decided once per process when the bundle loads, also
// where the shim is off (the wallpaper extensions run "outside"). Order: TSMTL_SWIFT=0/1 (tests), the app's entry,
// critical processes off, the global switch, on (default since 0.12.2, off before). The kill switch is checked by the
// caller (TSSwift.m).
BOOL TSMtlSwiftEnabled(BOOL *validate, const char **reason) {
    static BOOL on, check;
    static const char *why;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Not TSMtlProcessPolicy(): this runs in the bundle's constructor, before TSMtlCreateDevice marks a process
        // as injected, and that decision is made once.
        NSString *appId, *name, *path;
        TSIdentify(&appId, &name, &path);
        NSDictionary *swift = TSDict(TSDict(TSPolicyPlist()[@"System"])[@"Swift"]);
        NSDictionary *entry = TSDict(TSDict(swift[@"Apps"])[appId]);
        const char *env = getenv("TSMTL_SWIFT");
        if (env && *env) { on = strcmp(env, "0") != 0; why = "env"; }
        else if ([entry[@"Enabled"] isKindOfClass:[NSNumber class]]) { on = [entry[@"Enabled"] boolValue]; why = "list"; }
        else if (TSIsCritical()) { on = NO; why = "critical"; }
        else if ([swift[@"Enabled"] isKindOfClass:[NSNumber class]]) { on = [swift[@"Enabled"] boolValue]; why = "global"; }
        else { on = YES; why = "default"; }
        check = [swift[@"Validate"] isKindOfClass:[NSNumber class]] && [swift[@"Validate"] boolValue];
    });
    if (validate) *validate = check;
    if (reason) *reason = why;
    return on;
}

#pragma mark - Entry point for Metal.framework

// Metal instantiates the principal class as [[TSMtlDevice alloc] initWithAcceleratorPort:port].
// A process the policy excludes gets nil from +alloc, so no half-initialised _MTLDevice is ever
// released, and Metal sees no device there (as without the shim). Direct creation through
// TSMtlCreateDevice (tests, injection) is not subject to the policy.
static _Thread_local BOOL tsDirectCreation;

@implementation TSMtlDevice (TSSystem)

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    if (self == [TSMtlDevice class] && !tsDirectCreation && !TSMtlProcessPolicy()->enabled) return nil;
    return [super allocWithZone:zone];
}

- (instancetype)initWithAcceleratorPort:(io_service_t)port {
    if (!(self = [self init])) return nil;
    TSMtlStartStatsLease();
    return self;
}

@end

id<MTLDevice> TSMtlCreateDevice(void) {
    tsInjected = YES;
    tsDirectCreation = YES;
    TSMtlDevice *device = [TSMtlDevice alloc];
    tsDirectCreation = NO;
    device = [device init];
    if (device) TSMtlStartStatsLease();
    return device;
}

#pragma mark - VRAM pressure (M3)

// The Radeon's IOAccelerator (AMDTurksGraphicsAccelerator here; any AMD accelerator otherwise), as tsmtl finds it.
static io_registry_entry_t TSRadeonAccelerator(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return 0;
    io_registry_entry_t best = 0, s;
    while ((s = IOIteratorNext(it))) {
        io_name_t cls = "";
        IOObjectGetClass(s, cls);
        if (!strcmp(cls, "AMDTurksGraphicsAccelerator")) {
            if (best) IOObjectRelease(best);
            best = s;
            break;
        }
        if (!best && !strncmp(cls, "AMD", 3)) best = s;
        else IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return best;
}

// Reads PerformanceStatisticsAccum (running totals, not reset by reading: PerformanceStatistics is reset for
// everybody on every read, see gui/Sources/GPU.swift) at most once per second, from any thread. Pressure is
// 2 when the driver paged textures out of VRAM or waited for evictions since the previous sample, 1 when VRAM
// in use is within 24 MB of the total, else 0. TSMTL_VRAM_PRESSURE=<n> forces a value (tests).
int TSMtlVRAMPressure(void) {
    static const char *forced;
    static dispatch_once_t once;
    static io_registry_entry_t accel;
    static int64_t vramTotal;
    dispatch_once(&once, ^{
        forced = getenv("TSMTL_VRAM_PRESSURE");
        if (forced) return;
        accel = TSRadeonAccelerator();
        if (!accel) return;
        CFTypeRef mb = IORegistryEntrySearchCFProperty(accel, kIOServicePlane, CFSTR("VRAM,totalMB"), kCFAllocatorDefault,
                                                       kIORegistryIterateRecursively | kIORegistryIterateParents);
        if (mb && CFGetTypeID(mb) == CFNumberGetTypeID()) CFNumberGetValue(mb, kCFNumberSInt64Type, &vramTotal);
        else if (mb && CFGetTypeID(mb) == CFDataGetTypeID() && CFDataGetLength(mb) >= 4) vramTotal = *(const uint32_t *)CFDataGetBytePtr(mb);
        if (mb) CFRelease(mb);
        vramTotal *= 1048576;
    });
    if (forced) return atoi(forced);
    if (!accel) return 0;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static uint64_t lastSample;
    static int64_t lastPageOut = -1, lastEvictWait = -1;
    static int pressure;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    os_unfair_lock_lock(&lock);
    if (lastSample && now - lastSample < NSEC_PER_SEC) { int p = pressure; os_unfair_lock_unlock(&lock); return p; }
    lastSample = now;
    os_unfair_lock_unlock(&lock);
    NSDictionary *stats = CFBridgingRelease(IORegistryEntryCreateCFProperty(accel, CFSTR("PerformanceStatisticsAccum"), kCFAllocatorDefault, 0));
    if (![stats isKindOfClass:[NSDictionary class]]) return 0;
    int64_t pageOut = [stats[@"texturePageOutBytes"] longLongValue], evictWait = [stats[@"vramEvictionWaitTime"] longLongValue];
    int64_t inUse = [stats[@"inUseVidMemoryBytes"] longLongValue];
    os_unfair_lock_lock(&lock);
    int p = 0;
    if ((lastPageOut >= 0 && pageOut > lastPageOut) || (lastEvictWait >= 0 && evictWait > lastEvictWait)) p = 2;
    else if (vramTotal && inUse > vramTotal - (24 << 20)) p = 1;
    lastPageOut = pageOut;
    lastEvictWait = evictWait;
    pressure = p;
    os_unfair_lock_unlock(&lock);
    return p;
}

#pragma mark - Statistics lease

// The control app writes the Unix time into the state of this notify name and posts it every 2 s
// while it shows statistics. Nothing runs here until such a post arrives.
#define TS_STATS_NOTIFY "com.terascale.mtlshim.stats"

static int gLeaseToken = NOTIFY_TOKEN_INVALID;
static dispatch_queue_t gLeaseQueue;
static dispatch_source_t gLeaseTimer;   // gLeaseQueue only

static BOOL TSLeaseFresh(void) {
    uint64_t state = 0;
    if (notify_get_state(gLeaseToken, &state) != NOTIFY_STATUS_OK || !state) return NO;
    int64_t age = (int64_t)time(NULL) - (int64_t)state;
    return age >= -5 && age < 5;
}

static void TSEmitStats(uint64_t *last, double seconds) {
    uint64_t d[TSStatCount], now[TSStatCount];
    for (int i = 0; i < TSStatCount; i++) {
        now[i] = atomic_load_explicit(&gTSMtlStats[i], memory_order_relaxed);
        d[i] = now[i] - last[i];
        last[i] = now[i];
    }
    const TSMtlPolicy *p = TSMtlProcessPolicy();
    double frames = d[TSStatPresents] ? d[TSStatPresents] : d[TSStatSurfaceWrites];
    NSDictionary *line = @{
        @"v": @1, @"pid": @(getpid()), @"app": p->appId, @"name": p->name,
        @"fps": @(round(frames / seconds * 10) / 10),
        @"draws": @(d[TSStatDraws]), @"passes": @(d[TSStatPasses]), @"cmdbufs": @(d[TSStatCommandBuffers]),
        @"gpuBusy": @(round(d[TSStatGPUBusyMicros] / (seconds * 1e6) * 1000) / 1000),
        @"bufKB": @(d[TSStatBufferUploadBytes] >> 10), @"texKB": @(d[TSStatTextureUploadBytes] >> 10),
        @"readbacks": @(d[TSStatReadbacks]), @"translations": @(d[TSStatTranslations]), @"links": @(d[TSStatProgramLinks]),
        @"fallbacks": @(now[TSStatFallbacks]), @"pipelines": @(now[TSStatPipelines]), @"mslHits": @(now[TSStatBundleHits]),
        @"unalignedVariants": @(now[TSStatUnalignedVariants]),
        @"memMB": @(round(atomic_load(&gTSMtlAllocatedBytes) / 1048576.0 * 10) / 10),
        @"drawableWaitMs": @(d[TSStatDrawableWaitMicros] / 1000), @"drawableBlocks": @(d[TSStatDrawableBlocks]),
        // TeraScale Compute: dispatches run (GL + OpenCL), OpenCL submissions, pipelines that do not run (total).
        @"dispatches": @(d[TSStatDispatches]), @"clRuns": @(d[TSStatCLRuns]), @"computeRejected": @(now[TSStatComputeRejected]),
        // Dispatches encoded, dropped at execution, with no kernel to run (B2); OpenCL GPU time (G2), builds and
        // binaries from the disk cache (totals); VRAM pressure (M3).
        @"computeRecorded": @(d[TSStatComputeRecorded]), @"computeSkipped": @(d[TSStatComputeSkipped]),
        @"computeInert": @(d[TSStatComputeInert]), @"clGpuMs": @(round(d[TSStatCLGPUMicros] / 100.0) / 10),
        @"clBuilds": @(now[TSStatCLBuilds]), @"clBinaryHits": @(now[TSStatCLBinaryHits]), @"vramPressure": @(TSMtlVRAMPressure()),
    };
    NSDictionary *kernels = TSMtlComputeKernelTimes();
    if (kernels.count) {
        NSMutableDictionary *withKernels = [line mutableCopy];
        withKernels[@"clKernels"] = kernels;   // {name: [GPU ms, enqueues]} this interval
        line = withKernels;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:line options:NSJSONWritingSortedKeys error:NULL];
    if (json) TSMtlLogAt(TSLogStats, NULL, @"%@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
}

static void TSLeaseCheck(void) {   // gLeaseQueue
    if (gLeaseTimer || !TSLeaseFresh()) return;
    gTSMtlStatsOn |= TSStatsByLease;
    static uint64_t last[TSStatCount];
    for (int i = 0; i < TSStatCount; i++) last[i] = atomic_load_explicit(&gTSMtlStats[i], memory_order_relaxed);
    static uint64_t lastTime;
    lastTime = mach_absolute_time();
    gLeaseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gLeaseQueue);
    dispatch_source_set_timer(gLeaseTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 20);
    dispatch_source_set_event_handler(gLeaseTimer, ^{
        if (!TSLeaseFresh()) {
            gTSMtlStatsOn &= ~TSStatsByLease;
            dispatch_source_cancel(gLeaseTimer);
            gLeaseTimer = nil;
            return;
        }
        static mach_timebase_info_data_t tb;
        if (!tb.denom) mach_timebase_info(&tb);
        uint64_t t = mach_absolute_time();
        double seconds = (double)(t - lastTime) * tb.numer / tb.denom / 1e9;
        lastTime = t;
        TSEmitStats(last, seconds > 0.05 ? seconds : 1);
    });
    dispatch_resume(gLeaseTimer);
}

void TSMtlStartStatsLease(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLeaseQueue = dispatch_queue_create("com.terascale.mtlshim.stats", DISPATCH_QUEUE_SERIAL);
        if (notify_register_dispatch(TS_STATS_NOTIFY, &gLeaseToken, gLeaseQueue, ^(int token) { TSLeaseCheck(); }) != NOTIFY_STATUS_OK)
            return;
        dispatch_async(gLeaseQueue, ^{ TSLeaseCheck(); });   // the control app may already be open
    });
}
