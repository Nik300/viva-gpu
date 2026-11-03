// Test-only: reports which image asks for the machine model and how (sysctl hw.model or the
// platform expert's "model" property). TS_PROBE_SPOOF=sysctl|ioreg|both answers iMac19,1 there.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <sys/sysctl.h>

#define TS_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static const struct { const void *r; const void *e; } ts_interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&replacee };

static const char *kModel = "iMac19,1";
static BOOL spoof(const char *src) { const char *m = getenv("TS_PROBE_SPOOF"); return m && (!strcmp(m, src) || !strcmp(m, "both")); }
static void report(const char *src, const void *ret) {
    Dl_info i; const char *img = dladdr(ret, &i) && i.dli_fname ? i.dli_fname : "?";
    const char *b = strrchr(img, '/');
    fprintf(stderr, "[modelprobe %d %s] %s asked by %s%s\n", getpid(), getprogname(), src, b ? b + 1 : img, spoof(src) ? " (spoofed)" : "");
}
static int TSSysctlByName(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && !strcmp(name, "hw.model") && !newp) {
        report("sysctl hw.model", __builtin_return_address(0));
        if (spoof("sysctl")) {
            size_t n = strlen(kModel) + 1;
            if (oldp && oldlenp && *oldlenp >= n) memcpy(oldp, kModel, n);
            if (oldlenp) *oldlenp = n;
            return 0;
        }
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
static CFTypeRef TSProperty(io_registry_entry_t e, CFStringRef key, CFAllocatorRef a, IOOptionBits o) {
    if (key && CFEqual(key, CFSTR("model")) && IOObjectConformsTo(e, "IOPlatformExpertDevice")) {
        report("IORegistry model", __builtin_return_address(0));
        if (spoof("ioreg")) return CFDataCreate(NULL, (const UInt8 *)kModel, strlen(kModel) + 1);
    }
    return IORegistryEntryCreateCFProperty(e, key, a, o);
}
TS_INTERPOSE(TSSysctlByName, sysctlbyname)
TS_INTERPOSE(TSProperty, IORegistryEntryCreateCFProperty)
