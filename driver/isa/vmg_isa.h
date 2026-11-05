// Viva Metal - direct AIR -> Valhall ISA compiler (Mali-G57 MC2, arch v9). Opt-in (VMG_ISA=1).
//
// Every feature of docs/ANALISI-ISA-DIRETTA-2026-11-04.md §4 has an ID (A1..G4) and a toggle VMG_ISA_NO_<ID>; a
// function that needs a disabled (or unsupported) feature is compiled on the AIR -> NIR -> Panfrost path instead.
// VMG_ISA_ONLY=<ID,...> keeps only those features on the ISA path; VMG_ISA_STRICT=1 makes such a fallback a shader
// creation error (tests). The environment is read at every shader creation (tests switch it between pipelines).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "vmg.h"

#define VMG_ISA_FEATURES(X) \
    X(A1) X(A2) X(A3) X(A4) X(A5) X(A6) X(A7) X(A8) X(A9) X(A10) X(A11) \
    X(B1) X(B2) X(B3) X(B4) X(B5) X(B6) X(B7) X(B8) X(B9) X(B10) X(B11) \
    X(C1) X(C2) X(C3) X(C4) X(C5) X(C6) X(C7) X(C8) X(C9) X(C10) \
    X(D1) X(D2) X(D3) X(D4) X(D5) X(D6) X(D7) X(D8) X(D9) \
    X(E1) X(E2) X(E3) X(E4) X(E5) X(E6) X(E7) X(E8) X(E9) X(E10) X(E11) X(E12) X(E13) \
    X(F1) X(F2) X(F3) X(F4) \
    X(G1) X(G2) X(G3) X(G4)

enum vmg_isa_feature {
#define VMG_ISA_ENUM(id) VMG_ISA_##id,
    VMG_ISA_FEATURES(VMG_ISA_ENUM)
#undef VMG_ISA_ENUM
    VMG_ISA_FEATURE_COUNT
};

extern const char *const vmg_isa_feature_name[VMG_ISA_FEATURE_COUNT];

// Options of one compilation, from the environment (vmg_isa_options_from_env) or set by tools.
typedef struct {
    bool enabled;                            // VMG_ISA
    bool strict;                             // VMG_ISA_STRICT
    uint64_t disabled;                       // bit = feature on the NIR path (VMG_ISA_NO_<ID>, VMG_ISA_ONLY)
    const char *trace;                       // VMG_TRACE_ISA: "1" every function, else a function name
    uint32_t vs_noperspective;               // vertex variants: varyings the fragment shader reads noperspective
} vmg_isa_options;

void vmg_isa_options_from_env(vmg_isa_options *o);
// Text of the options for cache keys (only what changes the compiled code).
void vmg_isa_options_key(const vmg_isa_options *o, char *buf, size_t size);

// Stats of this process (vmg_shm_stats / Viva Manager).
typedef struct {
    uint64_t functions, fallbacks, compile_us, cache_hits;
    char last_fallback[96];
} vmg_isa_stats;
void vmg_isa_get_stats(vmg_isa_stats *out);
