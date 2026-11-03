// TeraScale Swift - conformance lookup accelerator (docs/OTTIMIZZAZIONE-SWIFT.md). Plain C, no GL/CL: the driver
// bundle, libTSMetal, the control app and build/libTSSwift.dylib (tests) all build it from this one file.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Phase 0 facts about the process, cheap to collect: logged by the driver whether the accelerator is on or off.
typedef struct {
    uint32_t launchMode;        // _dyld_launch_mode(): 1 = launched with a prebuilt closure
    int preoptimized;           // _dyld_has_preoptimized_swift_protocol_conformances(SwiftUICore or libswiftCore): 1/0, -1 unknown
    int cacheOverridden;        // dyld_shared_cache_some_image_overridden(): 1 with OCLP's roots, -1 unknown
    uint32_t images;            // images loaded now
    double secondsSinceStart;   // since the process started (-1 unknown)
    int hookable;               // entry points whose override word was recognised (3 = all; 0 = no Swift runtime)
} TSSwiftDiag;

typedef struct {
    int hooks;                  // entry points hooked (3 when fully active)
    uint64_t fastNominal;       // "no" answered from the index: struct/enum without any candidate record
    uint64_t fastConditional;   // struct/enum whose candidates all have a failing conditional requirement
    uint64_t fastClass;         // classes: no candidate along the superclass chain
    uint64_t fastStructural;    // tuples, functions, metatypes: no record can name them
    uint64_t fastNs;            // time spent answering those
    uint64_t deferred, deferredNs;  // lookups left to the runtime (positives, ambiguous cases)
    uint64_t deferredNo, deferredNoNs;  // of which the runtime answered "no" (what is left to accelerate)
    uint64_t mismatches;        // validation: fast "no" where the runtime said yes (must stay 0)
    uint64_t indexNs;           // time spent building the per-protocol indexes
    uint32_t protocols, sections;
    uint64_t records, indexBytes;
} TSSwiftStats;

enum { TSSwiftValidate = 1 };   // also ask the runtime on every fast "no" and count mismatches

TSSwiftDiag TSSwiftDiagnose(void);
// Installs the override in swift_conformsToProtocol, swift_conformsToProtocol2 and swift_conformsToProtocolCommon.
// Returns the number of entry points hooked (0..3); an entry point already overridden by someone else (another copy
// of this module included), or whose code does not have the expected shape, is left alone. Idempotent.
int TSSwiftInstall(int flags);
void TSSwiftGetStats(TSSwiftStats *out);
uint64_t TSSwiftFastTotal(const TSSwiftStats *s);
// Validation: "<type> : <protocol>" of the last mismatch, or NULL.
const char *TSSwiftLastMismatch(void);

#ifdef __cplusplus
}
#endif
