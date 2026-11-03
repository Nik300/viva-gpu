// TeraScale Metal Shim - in-process injection for testing real apps without touching the
// system: DYLD_INSERT_LIBRARIES=libTSMetalInject.dylib makes MTLCreateSystemDefaultDevice and
// MTLCopyAllDevices return the shim device in that process only. Apps with hardened runtime
// ignore DYLD_* variables; test those on an ad-hoc re-signed copy.
#import "../TSPrivate.h"
#import "../TSMetal.h"
#import <CoreGraphics/CGDirectDisplayMetal.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <sys/sysctl.h>

#define TS_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static const struct { const void *r; const void *e; } ts_interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&replacee };

static id<MTLDevice> TSSharedDevice(void) {
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        device = TSMtlCreateDevice();
        fprintf(stderr, "[TSMtl] injected into %s (pid %d): device %s\n", getprogname(), getpid(), device ? device.name.UTF8String : "(failed)");
    });
    return device;
}

// TSMTL_LOG=1: names the image that first asks for a device through each entry point, so a
// framework that finds its device some other way shows up as a missing caller.
static void TSLogCaller(const char *entry, const void *ret) {
    if (!gTSMtlLogOn) return;
    Dl_info info;
    const char *image = dladdr(ret, &info) && info.dli_fname ? info.dli_fname : "?";
    const char *base = strrchr(image, '/');
    TSMtlLog(@"%s called from %s (pid %d)", entry, base ? base + 1 : image, getpid());
}
#define TS_LOG_CALLER_ONCE(entry) do { \
    static _Atomic int logged; \
    if (!atomic_exchange(&logged, 1)) TSLogCaller(entry, __builtin_return_address(0)); \
} while (0)

// Same ownership as the originals: both return +1 (NS_RETURNS_RETAINED), callers release.
static id<MTLDevice> TSCreateSystemDefaultDevice(void) NS_RETURNS_RETAINED;
static id<MTLDevice> TSCreateSystemDefaultDevice(void) {
    TS_LOG_CALLER_ONCE("MTLCreateSystemDefaultDevice");
    return TSSharedDevice();
}

static NSArray<id<MTLDevice>> *TSCopyAllDevices(void) NS_RETURNS_RETAINED;
static NSArray<id<MTLDevice>> *TSCopyAllDevices(void) {
    TS_LOG_CALLER_ONCE("MTLCopyAllDevices");
    id<MTLDevice> d = TSSharedDevice();
    return d ? @[d] : @[];
}

static NSArray<id<MTLDevice>> *TSCopyAllDevicesWithObserver(id<NSObject> __strong *observer, MTLDeviceNotificationHandler handler) NS_RETURNS_RETAINED;
static NSArray<id<MTLDevice>> *TSCopyAllDevicesWithObserver(id<NSObject> __strong *observer, MTLDeviceNotificationHandler handler) {
    if (observer) *observer = [NSObject new];
    return TSCopyAllDevices();
}

// VectorKit (MapKit, Maps, Find My) asks CoreGraphics for the device driving the display
// instead of calling MTLCreateSystemDefaultDevice. One GPU drives every display here.
static id<MTLDevice> TSDisplayCopyCurrentMetalDevice(CGDirectDisplayID display) NS_RETURNS_RETAINED;
static id<MTLDevice> TSDisplayCopyCurrentMetalDevice(CGDirectDisplayID display) {
    TS_LOG_CALLER_ONCE("CGDirectDisplayCopyCurrentMetalDevice");
    return TSSharedDevice();
}

TS_INTERPOSE(TSCreateSystemDefaultDevice, MTLCreateSystemDefaultDevice)
TS_INTERPOSE(TSCopyAllDevices, MTLCopyAllDevices)
TS_INTERPOSE(TSCopyAllDevicesWithObserver, MTLCopyAllDevicesWithObserver)
TS_INTERPOSE(TSDisplayCopyCurrentMetalDevice, CGDirectDisplayCopyCurrentMetalDevice)

// TSMTL_MACHINE_MODEL=<model> (opt-in, test runs only): ANGLE, Chrome's GLES-on-Metal layer, refuses
// Metal on machine models older than a built-in minimum ("Disabling Metal because machine model
// "iMac12,1" is below the minium supported version") before asking for a device. The override
// answers hw.model and the platform expert's "model" with the given value in this process only.
static const char *TSModelOverride(void) {
    static const char *model;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *m = getenv("TSMTL_MACHINE_MODEL");
        model = m && *m ? m : NULL;
        if (model) fprintf(stderr, "[TSMtl] machine model reported as %s (pid %d)\n", model, getpid());
    });
    return model;
}

static int TSSysctlByName(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    const char *m = TSModelOverride();
    if (m && name && !strcmp(name, "hw.model") && !newp) {
        size_t need = strlen(m) + 1;
        if (oldp) {
            if (!oldlenp || *oldlenp < need) { errno = ENOMEM; return -1; }
            memcpy(oldp, m, need);
        }
        if (oldlenp) *oldlenp = need;
        return 0;
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static CFTypeRef TSRegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    const char *m = TSModelOverride();
    if (m && key && CFEqual(key, CFSTR("model")) && IOObjectConformsTo(entry, "IOPlatformExpertDevice"))
        return CFDataCreate(allocator, (const UInt8 *)m, (CFIndex)strlen(m) + 1);
    return IORegistryEntryCreateCFProperty(entry, key, allocator, options);
}

TS_INTERPOSE(TSSysctlByName, sysctlbyname)
TS_INTERPOSE(TSRegistryEntryCreateCFProperty, IORegistryEntryCreateCFProperty)
