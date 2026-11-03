// build/libTSSwift.dylib: TeraScale Swift injected with DYLD_INSERT_LIBRARIES (tests, measurements on unsigned apps).
// Env: TSSWIFT_OFF=1 (load but do not hook), TSSWIFT_VALIDATE=1 (ask the runtime on every fast "no", count mismatches),
//      TSSWIFT_STATS=s1,s2,... (statistics on stderr at those seconds and at exit).
#include "../../src/swift/TSSwiftAccel.h"
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void report(void) {
    TSSwiftStats s;
    TSSwiftGetStats(&s);
    fprintf(stderr, "[tsswift %d %s] hooks %d; fast no %llu (nominal %llu, conditional %llu, class %llu, structural %llu) in %.1f ms; "
            "deferred %llu (%.0f ms), of which no %llu (%.0f ms); mismatches %llu%s%s; %u protocols indexed in %.1f ms (%.0f KB), "
            "%u sections, %llu records\n", getpid(), getprogname(), s.hooks, TSSwiftFastTotal(&s), s.fastNominal,
            s.fastConditional, s.fastClass, s.fastStructural, s.fastNs / 1e6, s.deferred, s.deferredNs / 1e6, s.deferredNo, s.deferredNoNs / 1e6,
            s.mismatches, TSSwiftLastMismatch() ? ", last: " : "", TSSwiftLastMismatch() ?: "", s.protocols, s.indexNs / 1e6,
            s.indexBytes / 1024.0, s.sections, s.records);
}

__attribute__((constructor)) static void init(void) {
    const char *stats = getenv("TSSWIFT_STATS");
    if (stats) {
        TSSwiftDiag g = TSSwiftDiagnose();
        fprintf(stderr, "[tsswift %d] launch mode %#x, preoptimized %d, cache overridden %d, %u images, %.2f s since start, "
                "hookable %d\n", getpid(), g.launchMode, g.preoptimized, g.cacheOverridden, g.images, g.secondsSinceStart, g.hookable);
    }
    if (getenv("TSSWIFT_OFF")) return;
    const char *v = getenv("TSSWIFT_VALIDATE");
    TSSwiftInstall(v && *v && strcmp(v, "0") ? TSSwiftValidate : 0);
    if (stats) {
        atexit(report);
        for (char *e = strdup(stats), *t; (t = strsep(&e, ","));)
            if (atof(t) > 0)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(t) * 1e9)), dispatch_get_global_queue(0, 0), ^{ report(); });
    }
}
