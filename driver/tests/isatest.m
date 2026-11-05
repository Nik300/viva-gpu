// The ISA compiler's test cases (isa_cases.m) from the command line: one line per case with the ISA result (forced on
// the ISA path, VMG_ISA_STRICT), the NIR result and the GPU time per draw of both. Exit status 1 when a case fails in
// the checked mode (ISA, or NIR with -mode nir).
// Usage: isatest [ID...] [-v] [-mode isa|nir|both]     (IDs of docs/ANALISI-ISA-DIRETTA-2026-11-04.md §4, e.g. D3 E6)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "isa_cases.h"

id<MTLDevice> TSMtlCreateDevice(void);

static void print_result(const char *mode, isa_result r) {
    printf("  %s %-2s err %-9.3g bad %6.2f%% %7.3f ms", mode, r.ok ? "ok" : "KO", r.max_err, r.pct_bad, r.gpu_ms);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        bool verbose = false, isa = true, nir = true;
        const char *ids[64];
        int nids = 0;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "-v")) verbose = true;
            else if (!strcmp(argv[i], "-mode") && i + 1 < argc) {
                const char *m = argv[++i];
                isa = !strcmp(m, "isa") || !strcmp(m, "both");
                nir = !strcmp(m, "nir") || !strcmp(m, "both");
                if (!isa && !nir) { fprintf(stderr, "isatest: -mode isa|nir|both\n"); return 2; }
            } else if (argv[i][0] == '-') {
                fprintf(stderr, "usage: isatest [ID...] [-v] [-mode isa|nir|both]\n");
                return 2;
            } else if (nids < 64) ids[nids++] = argv[i];
        }
        id<MTLDevice> dev = TSMtlCreateDevice();
        if (!dev) { fprintf(stderr, "isatest: no Metal device\n"); return 1; }
        bool llvmpipe = [dev.name rangeOfString:@"llvmpipe" options:NSCaseInsensitiveSearch].location != NSNotFound;
        printf("isatest on %s, %s (ms per draw/dispatch, mean of %d)\n", dev.name.UTF8String,
               isa && nir ? "ISA vs NIR" : isa ? "ISA only" : "NIR only", ISA_TIMING_RUNS);
        int run = 0, failed = 0, expected = 0;
        for (int i = 0; i < isa_case_count; i++) {
            const isa_case *c = &isa_cases[i];
            bool want = nids == 0;
            for (int k = 0; k < nids && !want; k++) want = !strcasecmp(ids[k], c->id);
            if (!want) continue;
            run++;
            if (llvmpipe && c->skip_llvmpipe) {
                printf("%-4s %-62.62s  saltato su llvmpipe\n       %s\n", c->id, c->title, c->mac_note ? c->mac_note : "");
                expected++;
                continue;
            }
            isa_result ri = {0}, rn = {0};
            if (isa) ri = isa_run_case(dev, c, ISA_MODE_ISA, NULL, NULL);
            if (nir) rn = isa_run_case(dev, c, ISA_MODE_NIR, NULL, NULL);
            isa_result checked = isa ? ri : rn;
            bool known = !checked.ok && llvmpipe && c->mac_note;   // llvmpipe cannot run it: reported, not counted
            if (!checked.ok && !known) failed++;
            if (known) expected++;
            printf("%-4s %-62.62s", c->id, c->title);
            if (isa) print_result("ISA", ri);
            if (nir) print_result("NIR", rn);
            printf("%s\n", known ? "  (llvmpipe: atteso)" : "");
            if (verbose || !checked.ok) {
                if (isa && ri.note[0]) printf("       ISA: %s\n", ri.note);
                if (nir && rn.note[0]) printf("       NIR: %s\n", rn.note);
                if (known) printf("       %s\n", c->mac_note);
            }
            if (verbose && isa) {
                char only[256];
                const char *o = isa_case_only(c, only, sizeof only);
                printf("       VMG_ISA_ONLY=%s\n", o ? o : "(non impostato)");
            }
            fflush(stdout);
        }
        printf("%d cases, %d failed%s", run, failed, isa ? " (ISA)" : " (NIR)");
        if (expected) printf(", %d not runnable on llvmpipe", expected);
        printf("\n");
        return failed != 0;
    }
}
