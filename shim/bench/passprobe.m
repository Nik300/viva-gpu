// Probe: which LLVM new-PM passes does the system libLLVM know, and what do they do to AIR?
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import "TSMetal.h"
typedef void *Ctx, *Buf, *Mod, *Err;
static Ctx (*ctxCreate)(void); static Buf (*mkbuf)(const char *, size_t, const char *, int);
static int (*parse)(Ctx, Buf, Mod *); static char *(*print)(Mod); static Err (*runPasses)(Mod, const char *, void *, void *);
static char *(*errMsg)(Err); static void (*disposeMod)(Mod); static void *(*mkopts)(void); static void *opts;
static double ms(uint64_t t) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return t * tb.numer / tb.denom / 1e6; }
int main(int argc, char **argv) { @autoreleasepool {
    void *h = dlopen("/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib", RTLD_NOW | RTLD_LOCAL);
    ctxCreate = dlsym(h, "LLVMContextCreate"); mkbuf = dlsym(h, "LLVMCreateMemoryBufferWithMemoryRange");
    parse = dlsym(h, "LLVMParseBitcodeInContext2"); print = dlsym(h, "LLVMPrintModuleToString");
    runPasses = dlsym(h, "LLVMRunPasses"); errMsg = dlsym(h, "LLVMGetErrorMessage"); disposeMod = dlsym(h, "LLVMDisposeModule"); mkopts = dlsym(h, "LLVMCreatePassBuilderOptions"); opts = mkopts();
    id<MTLDevice> d = TSMtlCreateDevice();
    NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
    NSError *e = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e];
    if (!lib) { fprintf(stderr, "%s\n", e.description.UTF8String); return 1; }
    NSData *bc = (NSData *)[(id)[lib newFunctionWithName:@(argv[2])] performSelector:@selector(bitcodeData)];
    const char *pipelines[] = { "instcombine", "load-store-vectorizer", "structurizecfg", "fix-irreducible", "unify-loop-exits",
        "lowerswitch", "simplifycfg", "sroa", "gvn", "early-cse", "loop-simplify", "lcssa", "loop-unroll", "aggressive-instcombine",
        "reassociate", "sink", "dce", "adce", "mem2reg", "flattencfg", "lower-expect", "loop-rotate", "licm", "ipsccp", "always-inline",
        "default<O2>", NULL };
    for (int i = 0; pipelines[i]; i++) {
        Mod m = NULL; Ctx c = ctxCreate();
        if (parse(c, mkbuf(bc.bytes, bc.length, "air", 0), &m)) { printf("parse failed\n"); return 1; }
        uint64_t t0 = mach_absolute_time();
        Err err = runPasses(m, pipelines[i], NULL, opts);
        printf("%-24s %s (%.2f ms)\n", pipelines[i], err ? errMsg(err) : "OK", ms(mach_absolute_time() - t0));
        disposeMod(m);
    }
    if (argc > 3) {
        Mod m = NULL; parse(ctxCreate(), mkbuf(bc.bytes, bc.length, "air", 0), &m);
        Err err = runPasses(m, argv[3], NULL, opts);
        if (err) printf("ERR %s\n", errMsg(err)); else printf("%s\n", print(m));
    }
} return 0; }
