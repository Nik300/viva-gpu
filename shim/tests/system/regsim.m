// Test-only: simulates what TSMetalEnabler.kext and the /Library/GPUBundles install provide, so the
// real Metal.framework registration path (MTLIOAccelService -> gpu_bundle_find_trusted -> NSBundle ->
// +[TSMtlDevice alloc] initWithAcceleratorPort:) can be exercised without touching the system.
// DYLD_INSERT_LIBRARIES=libTSRegSim.dylib TSMTL_SIM_BUNDLE=<path to TeraScaleMTLDriver.bundle>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

#define TS_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static const struct { const void *r; const void *e; } ts_interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&replacee };

int gpu_bundle_find_trusted(const char *name, char *out, size_t size);

static CFTypeRef TSSimProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    if (key && IOObjectConformsTo(entry, "AMDTurksGraphicsAccelerator")) {
        if (CFEqual(key, CFSTR("MetalPluginName"))) return CFStringCreateCopy(NULL, CFSTR("TeraScaleMTLDriver"));
        if (CFEqual(key, CFSTR("MetalPluginClassName"))) return CFStringCreateCopy(NULL, CFSTR("TSMtlDevice"));
    }
    return IORegistryEntryCreateCFProperty(entry, key, allocator, options);
}

static int TSSimFindTrusted(const char *name, char *out, size_t size) {
    const char *bundle = getenv("TSMTL_SIM_BUNDLE");
    if (bundle && name && !strcmp(name, "TeraScaleMTLDriver")) {
        if (!strcmp(bundle, "none")) return 1;   // as when the bundle is not installed
        fprintf(stderr, "[regsim] gpu_bundle_find_trusted(%s) -> %s\n", name, bundle);
        return strlcpy(out, bundle, size) < size ? 0 : -1;
    }
    return gpu_bundle_find_trusted(name, out, size);
}

TS_INTERPOSE(TSSimProperty, IORegistryEntryCreateCFProperty)
TS_INTERPOSE(TSSimFindTrusted, gpu_bundle_find_trusted)
