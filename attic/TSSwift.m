// TeraScale Swift (docs/OTTIMIZZAZIONE-SWIFT.md): the Swift conformance accelerator, started by the driver bundle's
// constructor in every process that loads it (processes that enumerate Metal devices: System Settings, the wallpaper
// extensions, SwiftUI apps), whether the shim serves that process or not. Policy (System.Swift), kill switch and log
// here; the accelerator itself is plain C in src/swift/ and is shared with the control app and the tests.
#import "TSPrivate.h"
#import "swift/TSSwiftAccel.h"
#import <dlfcn.h>

// Kill switch: /var/tmp/TeraScaleSwift/DISABLE (tsmtl swift kill), or under TSMTL_CONFIG_DIR when that redirects the
// configuration. Read by processes started afterwards; the user can create and delete it without sudo.
static NSString *TSSwiftKillPath(void) {
    const char *config = getenv("TSMTL_CONFIG_DIR");
    return [(config && *config ? @(config) : @"/var/tmp") stringByAppendingPathComponent:@"TeraScaleSwift/DISABLE"];
}

// One line per process at 15 s, 60 s and 5 min: what the accelerator answered and what it left to the runtime
// (tsmtl swift stats reads these lines back from the log).
static void TSSwiftLogStats(int seconds) {
    TSSwiftStats s;
    TSSwiftGetStats(&s);
    const char *last = TSSwiftLastMismatch();
    TSMtlLogAt(TSLogSwift, NULL, @"stats %s pid=%d t=%ds fast=%llu nominal=%llu conditional=%llu class=%llu structural=%llu "
               "fastMs=%.1f deferred=%llu deferredMs=%.0f deferredNo=%llu deferredNoMs=%.0f mismatches=%llu indexMs=%.1f "
               "indexKB=%.0f protocols=%u records=%llu%s%s", getprogname(), getpid(), seconds, TSSwiftFastTotal(&s),
               s.fastNominal, s.fastConditional, s.fastClass, s.fastStructural, s.fastNs / 1e6, s.deferred,
               s.deferredNs / 1e6, s.deferredNo, s.deferredNoNs / 1e6, s.mismatches, s.indexNs / 1e6, s.indexBytes / 1024.0,
               s.protocols, s.records, last ? " last-mismatch=" : "", last ?: "");
}

__attribute__((constructor)) static void TSSwiftInit(void) {
    if (!dlsym(RTLD_DEFAULT, "swift_conformsToProtocolCommon")) return;   // no Swift runtime in this process
    @autoreleasepool {
        TSSwiftDiag g = TSSwiftDiagnose();
        BOOL validate = NO;
        const char *reason = "";
        BOOL on = TSMtlSwiftEnabled(&validate, &reason);
        if (on && access(TSSwiftKillPath().fileSystemRepresentation, F_OK) == 0) { on = NO; reason = "kill-switch"; }
        int hooks = on ? TSSwiftInstall(validate ? TSSwiftValidate : 0) : 0;
        NSString *version = [NSBundle bundleForClass:[TSMtlDevice class]].infoDictionary[@"CFBundleShortVersionString"] ?: @"dev";
        // Phase 0 facts, logged on or off: dyld launch mode (1 = prebuilt closure), whether SwiftUI's conformances are
        // pre-optimized, whether OCLP's roots override the shared cache, and how late the bundle arrived. "unhooked":
        // on, but the entry points were already overridden (the control app links its own copy) or not recognised.
        TSMtlLogAt(TSLogSwift, NULL, @"%s %s pid=%d reason=%s hooks=%d validate=%d version=%@ launchMode=%#x preoptimized=%d "
                   "cacheOverridden=%d images=%u sinceStart=%.2f hookable=%d", hooks ? "on" : on ? "unhooked" : "off", getprogname(), getpid(),
                   reason, hooks, validate, version, g.launchMode, g.preoptimized, g.cacheOverridden, g.images,
                   g.secondsSinceStart, g.hookable);
        if (!hooks) return;
        for (int i = 0; i < 3; i++) {
            int seconds = (int[]){ 15, 60, 300 }[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                           ^{ TSSwiftLogStats(seconds); });
        }
    }
}
