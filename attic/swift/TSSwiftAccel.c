// TeraScale Swift - conformance lookup accelerator (docs/OTTIMIZZAZIONE-SWIFT.md).
//
// libswiftCore answers a failed swift_conformsToProtocol by scanning every conformance record of every loaded image
// (70k-180k records in a SwiftUI app, 1-4 ms per lookup on this CPU), and AttributeGraph asks "Equatable?" for
// thousands of types that are not. This module installs an override through the runtime's own per-entry-point override
// word (data only, no code patching) and answers "no" itself when the records prove it:
//   - struct/enum: no record of the protocol names the type descriptor (phase 1);
//   - struct/enum whose only candidates are conditional ("Foo: P where T: Q") and each has a requirement on a generic
//     parameter that fails, asked again through the runtime's entry point (phase 2; SwiftUI nests these 10-20 deep:
//     ModifiedContent<ModifiedContent<...>, ...>);
//   - classes: no record names a descriptor, ObjC class or ObjC class name along the superclass chain (phase 2);
//   - tuples, functions and metatypes: no record can name them, and this runtime has no built-in conformances for
//     them (unless a record names a type of the Builtin module: experimental tuple conformances).
// Everything else (positives, existentials, foreign and C-imported types) goes to the runtime unchanged.
//
// Index: per queried protocol, built lazily on its first query and extended when images are added: a hash multiset
// of the protocol's conformance descriptors keyed by the type descriptor they name, plus the ObjC classes and class
// names its records name. Finding a protocol's records would mean visiting all records (scattered over hundreds of
// images, ~1.3 ms per protocol here); the first visit leaves a one-byte fingerprint of each record's protocol, so later
// protocols only read a contiguous byte array and visit the records whose fingerprint matches (~1 in 256).
#include "TSSwiftAccel.h"
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

typedef const void *(*ConformsFn)(const void *type, const void *proto);

// Metadata kinds (x86_64 with ObjC interop); a class's "kind" is its isa, above 0x7FF.
enum { MKStruct = 0x200, MKEnum = 0x201, MKOptional = 0x202, MKTuple = 0x301, MKFunction = 0x302, MKMetatype = 0x304,
       MKObjCClassWrapper = 0x305, MKExistentialMetatype = 0x306, MKLastEnumerated = 0x7FF };
// Context descriptor kinds and flags.
enum { CKClass = 16, CKStruct = 17, CKEnum = 18, CKProtocol = 3, CFGeneric = 0x80, CFImportInfo = 1u << 18 };
// Conformance descriptor flags.
enum { RFRetroactive = 1u << 6, RFConformanceOfProtocol = 1u << 18 };

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static int gValidate;
static ConformsFn gCommon;              // exported swift_conformsToProtocolCommon: conditional requirements go through it
static _Thread_local int tlsDepth;      // nesting of conditional-requirement lookups on this thread
enum { MaxDepth = 32 };                 // generic arguments nest finitely (a type cannot contain itself): a stack guard

typedef struct { const int32_t *rec; uint32_t n; uint8_t *fp; } Section;   // fp: protocol fingerprint per record
static Section *gSections;
static uint32_t gNSections, gCapSections;
static uint64_t gRecords;
// Images whose add-image callback has finished. While dyld counts more (an image is being added on another thread and
// the runtime may already see its conformances), the fast path is off.
static _Atomic uint32_t gImagesSeen;

typedef struct {
    const void *proto;
    const int32_t **tab;                // conformance descriptors keyed by the type descriptor they name (NULL = empty)
    uint32_t cap, count;
    const void **classes;               // ObjC class objects named by records (IndirectObjCClass)
    const char **names;                 // ObjC class names named by records (DirectObjCClassName)
    uint32_t nClasses, nNames, capClasses, capNames;
    int unsafe;                         // has records we cannot key (conformance of a protocol, unknown kinds)
    int builtin;                        // a record names a type of the Builtin module (tuple conformances)
} ProtoIndex;
static ProtoIndex **gProtos;
static uint32_t gNProtos, gCapProtos;

static struct {
    _Atomic uint64_t fastNominal, fastConditional, fastClass, fastStructural, fastNs, deferred, deferredNs, deferredNo, deferredNoNs,
                     mismatches, indexNs;
} st;
static int gHooks;
static char gMismatch[256];

static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void add(_Atomic uint64_t *c, uint64_t v) { atomic_fetch_add_explicit(c, v, memory_order_relaxed); }
static const void *rel(const int32_t *p) { return (const char *)p + *p; }
static const void *relInd(const int32_t *p) {
    int32_t o = *p;
    const char *a = (const char *)p + (o & ~1);
    return (o & 1) ? *(const void *const *)a : a;
}
static uint32_t hashp(const void *p) { return (uint32_t)(((uintptr_t)p * 0x9E3779B97F4A7C15ull) >> 32); }
static uint8_t fingerprint(const void *proto) { return (uint8_t)(hashp(proto) >> 24); }

#pragma mark - Index

// The type descriptor a conformance record names (kinds 0 and 1), NULL for ObjC classes.
static const void *recordDescriptor(const int32_t *cd) {
    unsigned kind = ((uint32_t)cd[3] >> 3) & 7;
    if (kind == 0) return rel(&cd[1]);
    if (kind == 1) return *(const void *const *)rel(&cd[1]);
    return NULL;
}

static void tabInsert(ProtoIndex *pi, const int32_t *cd, const void *d) {
    for (uint32_t h = hashp(d);; h++) {
        const int32_t **e = &pi->tab[h & (pi->cap - 1)];
        if (!*e) { *e = cd; pi->count++; return; }
    }
}
static void tabAdd(ProtoIndex *pi, const int32_t *cd, const void *d) {
    if ((pi->count + 1) * 2 > pi->cap) {
        const int32_t **old = pi->tab;
        uint32_t oc = pi->cap;
        pi->cap = oc ? oc * 2 : 64;
        pi->tab = calloc(pi->cap, sizeof *pi->tab);
        pi->count = 0;
        for (uint32_t i = 0; i < oc; i++) if (old[i]) tabInsert(pi, old[i], recordDescriptor(old[i]));
        free(old);
    }
    tabInsert(pi, cd, d);
}
// Collects the records naming d into out; -1 when there are more than max.
static int tabFind(const ProtoIndex *pi, const void *d, const int32_t **out, int max) {
    int n = 0;
    if (!pi->cap) return 0;
    for (uint32_t h = hashp(d);; h++) {
        const int32_t *e = pi->tab[h & (pi->cap - 1)];
        if (!e) return n;
        if (recordDescriptor(e) == d) {
            if (n == max) return -1;
            out[n++] = e;
        }
    }
}
static void push(const void ***arr, uint32_t *n, uint32_t *cap, const void *v) {
    if (*n == *cap) { *cap = *cap ? *cap * 2 : 8; *arr = realloc(*arr, *cap * sizeof **arr); }
    (*arr)[(*n)++] = v;
}

// The name of the module a context descriptor lives in.
static const char *moduleName(const uint32_t *d) {
    while (d && (d[0] & 0x1F) != 0) d = relInd((const int32_t *)&d[1]);
    return d ? rel((const int32_t *)&d[2]) : "";
}

// Adds the records of one section that conform to pi->proto.
static void indexSection(ProtoIndex *pi, Section *s) {
    if (!s->fp && (s->fp = malloc(s->n)))
        for (uint32_t k = 0; k < s->n; k++) s->fp[k] = fingerprint(relInd((const int32_t *)rel(&s->rec[k])));
    uint8_t want = fingerprint(pi->proto);
    for (uint32_t k = 0; k < s->n; k++) {
        if (s->fp && s->fp[k] != want) continue;
        const int32_t *cd = rel(&s->rec[k]);
        if (relInd(&cd[0]) != pi->proto) continue;
        uint32_t fl = (uint32_t)cd[3];
        unsigned kind = (fl >> 3) & 7;
        if (fl & RFConformanceOfProtocol) { pi->unsafe = 1; continue; }
        if (kind <= 1) {
            const void *d = recordDescriptor(cd);
            if (d) tabAdd(pi, cd, d);
            if (d && !strcmp(moduleName(d), "Builtin")) pi->builtin = 1;
        } else if (kind == 2) {
            push((const void ***)&pi->names, &pi->nNames, &pi->capNames, rel(&cd[1]));
        } else if (kind == 3) {
            const void *cls = *(const void *const *)rel(&cd[1]);
            if (cls) push(&pi->classes, &pi->nClasses, &pi->capClasses, cls);   // NULL: weak class not present
        } else {
            pi->unsafe = 1;
        }
    }
}

static ProtoIndex *indexFor(const void *proto) {
    for (uint32_t i = 0; i < gNProtos; i++) if (gProtos[i]->proto == proto) return gProtos[i];
    uint64_t t0 = now();
    ProtoIndex *pi = calloc(1, sizeof *pi);
    pi->proto = proto;
    for (uint32_t i = 0; i < gNSections; i++) indexSection(pi, &gSections[i]);
    push((const void ***)&gProtos, &gNProtos, &gCapProtos, pi);
    add(&st.indexNs, now() - t0);
    return pi;
}

static void addImage(const struct mach_header *mh, intptr_t slide) {
    unsigned long size = 0;
    const int32_t *r = (const int32_t *)getsectiondata((const void *)mh, "__TEXT", "__swift5_proto", &size);
    if (r && size) {
        os_unfair_lock_lock(&gLock);
        if (gNSections == gCapSections) {
            gCapSections = gCapSections ? gCapSections * 2 : 512;
            gSections = realloc(gSections, gCapSections * sizeof *gSections);
        }
        Section *s = &gSections[gNSections++];
        s->rec = r;
        s->n = (uint32_t)(size / 4);
        s->fp = NULL;
        gRecords += s->n;
        for (uint32_t i = 0; i < gNProtos; i++) indexSection(gProtos[i], s);
        os_unfair_lock_unlock(&gLock);
    }
    atomic_fetch_add(&gImagesSeen, 1);
}

#pragma mark - Deciding

// The struct/enum type descriptor of a metadata, or NULL when the fast path does not apply.
static const uint32_t *nominalDescriptor(const uintptr_t *md) {
    if (md[0] != MKStruct && md[0] != MKEnum && md[0] != MKOptional) return NULL;
    const uint32_t *d = (const uint32_t *)md[1];
    if (!d) return NULL;
    uint32_t fl = d[0];
    if ((fl & 0x1F) != CKStruct && (fl & 0x1F) != CKEnum) return NULL;
    if (fl & CFImportInfo) return NULL;                // C-imported: matched by name
    if (((fl >> 16) & 3) == 2) return NULL;            // foreign metadata initialization
    // Module "__C" / "__C_Synthesized": imported or synthesized types are not unique by address.
    return strncmp(moduleName(d), "__C", 3) ? d : NULL;
}

// Index of a depth-0 generic parameter from its mangled name ("x", "qz", "q_", "q<n>_"), -1 for anything else.
static int paramIndex(const char *s) {
    if (s[0] == 'x' && !s[1]) return 0;
    if (s[0] != 'q') return -1;
    if ((s[1] == 'z' || s[1] == '_') && !s[2]) return s[1] == 'z' ? 0 : 1;
    int n = 0, i = 1;
    if (s[1] < '0' || s[1] > '9') return -1;
    for (; s[i] >= '0' && s[i] <= '9'; i++) if ((n = n * 10 + s[i] - '0') > 4096) return -1;
    return s[i] == '_' && !s[i + 1] ? n + 2 : -1;
}

// 1 when one of the record's conditional requirements provably fails for this struct/enum ("T: Q" on one of its
// generic parameters, and the argument does not conform); 0 when the record may apply.
static int requirementsFail(const int32_t *cd, const uintptr_t *md, const uint32_t *d) {
    uint32_t fl = (uint32_t)cd[3];
    unsigned nReq = (fl >> 8) & 0xFF;
    if (!nReq || ((fl >> 24) & 0xFF) || !(d[0] & CFGeneric) || !gCommon) return 0;
    // Struct and enum descriptors are 28 bytes, then TypeGenericContextDescriptorHeader: two relative pointers and
    // GenericContextDescriptorHeader {NumParams, NumRequirements, NumKeyArguments, Flags}, then one byte per parameter.
    const uint16_t *gh = (const uint16_t *)((const char *)d + 28 + 8);
    unsigned nParams = gh[0];
    if (gh[3] & 5) return 0;                           // type packs or value parameters: arguments are not 1:1
    const uint8_t *params = (const uint8_t *)(gh + 4);
    for (unsigned i = 0; i < nParams; i++) if (params[i] != 0x80) return 0;   // key type parameters only
    const int32_t *req = cd + 4 + ((fl & RFRetroactive) ? 1 : 0);
    for (unsigned r = 0; r < nReq; r++, req += 3) {
        uint32_t rf = (uint32_t)req[0];
        if ((rf & 0x1F) != 0 || (rf & 0x20)) continue;   // only protocol requirements on a single type
        int idx = paramIndex(rel(&req[1]));
        if (idx < 0 || (unsigned)idx >= nParams) continue;
        int32_t o = req[2];
        if (o & 2) continue;                               // ObjC protocol
        const char *a = (const char *)&req[2] + (o & ~3);
        const uint32_t *p2 = (o & 1) ? *(const uint32_t *const *)a : (const uint32_t *)a;
        if (!p2 || (p2[0] & 0x1F) != CKProtocol) continue;
        const void *arg = (const void *)md[2 + idx];      // value metadata: generic arguments start at word 2
        if (!arg) continue;
        tlsDepth++;
        const void *wt = gCommon(arg, p2);
        tlsDepth--;
        if (!wt) return 1;
    }
    return 0;
}

enum { Defer, NoNominal, NoConditional, NoClass, NoStructural };

static int decideNominal(const uintptr_t *md, const uint32_t *d, const void *proto) {
    enum { Max = 8 };
    const int32_t *cand[Max];
    os_unfair_lock_lock(&gLock);
    ProtoIndex *pi = indexFor(proto);
    int n = pi->unsafe ? -1 : tabFind(pi, d, cand, Max);
    os_unfair_lock_unlock(&gLock);
    if (n == 0) return NoNominal;
    if (n < 0 || tlsDepth >= MaxDepth) return Defer;
    for (int i = 0; i < n; i++) if (!requirementsFail(cand[i], md, d)) return Defer;
    return NoConditional;
}

// Classes: the runtime matches each class of the superclass chain against records naming its descriptor, its ObjC
// class object or its ObjC name. "No" only when none does along the whole chain, up to the root.
static int decideClass(const uintptr_t *md, const void *proto) {
    enum { Max = 32 };
    const uintptr_t *chain[Max];
    const void *descs[Max];
    const char *names[Max];
    int n = 0;
    for (const uintptr_t *c = md[0] == MKObjCClassWrapper ? (const uintptr_t *)md[1] : md; c; c = (const uintptr_t *)c[1]) {
        if (n == Max) return Defer;
        const uint32_t *desc = NULL;
        if (c[4] & 3) {   // Swift class (FAST_IS_SWIFT_LEGACY/STABLE): descriptor at word 8
            desc = (const uint32_t *)c[8];
            if (!desc || (desc[0] & 0x1F) != CKClass || (desc[0] & CFImportInfo)) return Defer;
            if (!c[1]) return Defer;  // with ObjC interop every Swift class has a superclass: metadata not complete
        }
        chain[n] = c;
        descs[n++] = desc;
    }
    os_unfair_lock_lock(&gLock);
    ProtoIndex *pi = indexFor(proto);
    uint32_t nNames = pi->nNames;
    int unsafe = pi->unsafe;
    os_unfair_lock_unlock(&gLock);
    if (unsafe) return Defer;
    // class_getName outside our lock: the ObjC runtime may take its own.
    if (nNames) for (int i = 0; i < n; i++) names[i] = class_getName((Class)(void *)chain[i]);
    int maybe = 0;
    os_unfair_lock_lock(&gLock);
    if (pi->nNames != nNames) maybe = 1;   // a name record arrived meanwhile
    for (int i = 0; i < n && !maybe; i++) {
        const int32_t *one;
        if (descs[i] && tabFind(pi, descs[i], &one, 1) != 0) maybe = 1;
        for (uint32_t k = 0; k < pi->nClasses && !maybe; k++) if (pi->classes[k] == chain[i]) maybe = 1;
        for (uint32_t k = 0; k < nNames && !maybe; k++) if (names[i] && !strcmp(pi->names[k], names[i])) maybe = 1;
    }
    os_unfair_lock_unlock(&gLock);
    return maybe ? Defer : NoClass;
}

static int decideStructural(const void *proto) {
    os_unfair_lock_lock(&gLock);
    ProtoIndex *pi = indexFor(proto);
    int no = !pi->unsafe && !pi->builtin;
    os_unfair_lock_unlock(&gLock);
    return no ? NoStructural : Defer;
}

static void noteMismatch(const void *type, const void *proto) {
    typedef struct { const char *data; uintptr_t length; } TypeName;
    TypeName (*getName)(const void *, int) = (TypeName (*)(const void *, int))dlsym(RTLD_DEFAULT, "swift_getTypeName");
    TypeName t = getName ? getName(type, 1) : (TypeName){ "?", 1 };
    const char *p = rel((const int32_t *)proto + 2);
    os_unfair_lock_lock(&gLock);
    snprintf(gMismatch, sizeof gMismatch, "%.*s : %s", (int)t.length, t.data, p);
    os_unfair_lock_unlock(&gLock);
}

static const void *accel(const void *type, const void *proto, ConformsFn orig) {
    uint64_t t0 = now();
    const uintptr_t *md = type;
    int verdict = Defer;
    if (atomic_load(&gImagesSeen) >= _dyld_image_count()) {
        const uint32_t *d = nominalDescriptor(md);
        if (d) verdict = decideNominal(md, d, proto);
        else if (md[0] > MKLastEnumerated || md[0] == MKObjCClassWrapper) verdict = decideClass(md, proto);
        else if (md[0] == MKTuple || md[0] == MKFunction || md[0] == MKMetatype || md[0] == MKExistentialMetatype)
            verdict = decideStructural(proto);
    }
    if (verdict != Defer) {
        add(verdict == NoNominal ? &st.fastNominal : verdict == NoConditional ? &st.fastConditional :
            verdict == NoClass ? &st.fastClass : &st.fastStructural, 1);
        add(&st.fastNs, now() - t0);
        if (gValidate) {   // the runtime's answer wins: validation must not change behaviour
            const void *r = orig(type, proto);
            if (r) { add(&st.mismatches, 1); noteMismatch(type, proto); }
            return r;
        }
        return NULL;
    }
    const void *r = orig(type, proto);
    uint64_t dt = now() - t0;
    add(&st.deferred, 1);
    add(&st.deferredNs, dt);
    if (!r) { add(&st.deferredNo, 1); add(&st.deferredNoNs, dt); }
    return r;
}

// The override's signature is the runtime's: (type, protocol, original implementation).
static const void *override(const void *type, const void *proto, ConformsFn orig) { return accel(type, proto, orig); }

#pragma mark - Hook

// Each entry point caches its override in an atomic word read near the top of the function:
//   48 8B 05 <disp32>   movq disp(%rip), %rax
//   48 83 F8 01         cmpq $1, %rax         (1 = no override, 0 = not computed yet)
// Returns the word, or NULL when the code does not have that shape.
static _Atomic(uintptr_t) *overrideSlot(const char *sym) {
    const unsigned char *f = dlsym(RTLD_DEFAULT, sym);
    if (!f) return NULL;
    for (int off = 0; off < 40; off++) {
        const unsigned char *p = f + off;
        if (p[0] == 0x48 && p[1] == 0x8B && p[2] == 0x05 && p[7] == 0x48 && p[8] == 0x83 && p[9] == 0xF8 && p[10] == 0x01) {
            int32_t disp;
            memcpy(&disp, p + 3, 4);
            return (_Atomic(uintptr_t) *)(p + 7 + disp);
        }
    }
    return NULL;
}

static const char *const kEntries[] = { "swift_conformsToProtocol", "swift_conformsToProtocol2", "swift_conformsToProtocolCommon" };

int TSSwiftInstall(int flags) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gValidate = (flags & TSSwiftValidate) != 0;
        _Atomic(uintptr_t) *slots[3];
        int found = 0;
        for (int i = 0; i < 3; i++) found += (slots[i] = overrideSlot(kEntries[i])) != NULL;
        if (found < 3) return;   // a runtime we do not know: all or nothing
        for (int i = 0; i < 3; i++) {
            uintptr_t cur = atomic_load(slots[i]);
            if (cur > 1) return;  // someone else's override (or another copy of this module): leave it alone
        }
        gCommon = (ConformsFn)dlsym(RTLD_DEFAULT, "swift_conformsToProtocolCommon");
        _dyld_register_func_for_add_image(addImage);   // calls back now for every loaded image
        for (int i = 0; i < 3; i++) {
            uintptr_t cur = atomic_load(slots[i]);
            if (cur <= 1 && atomic_compare_exchange_strong(slots[i], &cur, (uintptr_t)override)) gHooks++;
        }
    });
    return gHooks;
}

#pragma mark - Diagnostics and statistics

TSSwiftDiag TSSwiftDiagnose(void) {
    TSSwiftDiag g = { .preoptimized = -1, .cacheOverridden = -1, .secondsSinceStart = -1 };
    uint32_t (*mode)(void) = dlsym(RTLD_DEFAULT, "_dyld_launch_mode");
    _Bool (*pre)(const void *) = dlsym(RTLD_DEFAULT, "_dyld_has_preoptimized_swift_protocol_conformances");
    _Bool (*over)(void) = dlsym(RTLD_DEFAULT, "dyld_shared_cache_some_image_overridden");
    if (mode) g.launchMode = mode();
    if (over) g.cacheOverridden = over();
    g.images = _dyld_image_count();
    const struct mach_header *core = NULL, *ui = NULL;
    for (uint32_t i = 0; i < g.images; i++) {
        const char *name = _dyld_get_image_name(i);
        const char *base = name ? strrchr(name, '/') : NULL;
        if (base && !strcmp(base, "/SwiftUICore")) ui = _dyld_get_image_header(i);
        if (base && !strcmp(base, "/libswiftCore.dylib")) core = _dyld_get_image_header(i);
    }
    if (pre && (ui || core)) g.preoptimized = pre(ui ? ui : core);
    struct kinfo_proc kp;
    size_t size = sizeof kp;
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(mib, 4, &kp, &size, NULL, 0) == 0 && size) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct timeval s = kp.kp_proc.p_starttime;
        g.secondsSinceStart = (tv.tv_sec - s.tv_sec) + (tv.tv_usec - s.tv_usec) / 1e6;
    }
    for (int i = 0; i < 3; i++) g.hookable += overrideSlot(kEntries[i]) != NULL;
    return g;
}

void TSSwiftGetStats(TSSwiftStats *out) {
    memset(out, 0, sizeof *out);
    out->hooks = gHooks;
    out->fastNominal = st.fastNominal;
    out->fastConditional = st.fastConditional;
    out->fastClass = st.fastClass;
    out->fastStructural = st.fastStructural;
    out->fastNs = st.fastNs;
    out->deferred = st.deferred;
    out->deferredNs = st.deferredNs;
    out->deferredNo = st.deferredNo;
    out->deferredNoNs = st.deferredNoNs;
    out->mismatches = st.mismatches;
    out->indexNs = st.indexNs;
    os_unfair_lock_lock(&gLock);
    out->protocols = gNProtos;
    out->sections = gNSections;
    out->records = gRecords;
    for (uint32_t i = 0; i < gNProtos; i++)
        out->indexBytes += sizeof(ProtoIndex) + gProtos[i]->cap * sizeof(void *) +
                           (gProtos[i]->capClasses + gProtos[i]->capNames) * sizeof(void *);
    out->indexBytes += gCapSections * sizeof(Section) + gCapProtos * sizeof(void *);
    for (uint32_t i = 0; i < gNSections; i++) if (gSections[i].fp) out->indexBytes += gSections[i].n;
    os_unfair_lock_unlock(&gLock);
}

uint64_t TSSwiftFastTotal(const TSSwiftStats *s) { return s->fastNominal + s->fastConditional + s->fastClass + s->fastStructural; }

const char *TSSwiftLastMismatch(void) { return gMismatch[0] ? gMismatch : NULL; }
