// Loads the Swift runtime and the driver bundle (argv[1]) the way a Swift app gets them, asks two cold lookups and
// prints the accelerator's counters: tests/swift/bundle.sh checks them against the policy it wrote.
#include <dlfcn.h>
#include <stdio.h>
#include "../../src/swift/TSSwiftAccel.h"

int main(int argc, char **argv) {
    if (!dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_NOW) || !dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 1; }
    const void *(*conforms)(const void *, const void *) = dlsym(RTLD_DEFAULT, "swift_conformsToProtocolCommon");
    const void *eq = dlsym(RTLD_DEFAULT, "$sSQMp"), *intType = dlsym(RTLD_DEFAULT, "$sSiN"), *mirror = dlsym(RTLD_DEFAULT, "$ss6MirrorVN");
    int yes = conforms(intType, eq) != NULL, no = conforms(mirror, eq) == NULL;
    void (*get)(TSSwiftStats *) = dlsym(RTLD_DEFAULT, "TSSwiftGetStats");
    TSSwiftStats s = { 0 };
    if (get) get(&s);
    printf("answers %s hooks=%d fast=%llu\n", yes && no ? "ok" : "WRONG", s.hooks, s.fastNominal + s.fastConditional + s.fastClass + s.fastStructural);
    return !(yes && no);
}
