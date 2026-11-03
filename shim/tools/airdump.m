// Developer tool: compile an MSL file with the shim device and print the AIR (LLVM IR)
// of every function. Usage: airdump file.metal|file.metallib [function]
// A translation record (rec/<sha>.bin, tools/mslbundle) prints its function and the linked ones.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "TSMetal.h"
typedef void *Ctx, *Buf, *Mod;
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: airdump file.metal [function]\n"); return 2; }
    void *h = dlopen("/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib", RTLD_NOW | RTLD_LOCAL);
    Ctx (*ctxCreate)(void) = dlsym(h, "LLVMContextCreate");
    Buf (*mkbuf)(const char *, size_t, const char *) = dlsym(h, "LLVMCreateMemoryBufferWithMemoryRangeCopy");
    int (*parse)(Ctx, Buf, Mod *) = dlsym(h, "LLVMParseBitcodeInContext2");
    char *(*print)(Mod) = dlsym(h, "LLVMPrintModuleToString");
    NSString *path = @(argv[1]);
    if ([path.pathExtension isEqualToString:@"bin"]) {
        NSDictionary *r = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:path] options:0 format:NULL error:nil];
        NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:r[@"linked"] ?: @{}];
        printf("; record: app %s, %s %s, interp %s\n", [r[@"app"] UTF8String], [r[@"stage"] UTF8String], [r[@"name"] UTF8String],
               [[r[@"interp"] description] UTF8String]);
        all[@""] = r[@"bitcode"];
        for (NSString *k in [all.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSData *bc = all[k];
            Mod m = NULL;
            if (parse(ctxCreate(), mkbuf(bc.bytes, bc.length, "air"), &m)) { printf("; parse failed\n"); continue; }
            printf("; ===== %s\n%s\n", k.length ? [@"linked " stringByAppendingString:k].UTF8String : [r[@"name"] UTF8String], print(m));
        }
        return 0;
    }
    id<MTLDevice> d = TSMtlCreateDevice();
    NSError *e = nil;
    id<MTLLibrary> lib = [path.pathExtension isEqualToString:@"metallib"]
        ? [d newLibraryWithURL:[NSURL fileURLWithPath:path] error:&e]
        : [d newLibraryWithSource:[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] options:nil error:&e];
    if (!lib) { fprintf(stderr, "%s\n", e.description.UTF8String); return 1; }
    for (NSString *name in [lib.functionNames sortedArrayUsingSelector:@selector(compare:)]) {
        if (argc > 2 && ![name isEqualToString:@(argv[2])]) continue;
        id<MTLFunction> f = [lib newFunctionWithName:name];
        if (f.functionConstantsDictionary.count) {   // same zero specialization as airtrans
            MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
            uint8_t zero[64] = {0};
            // AIR_CONST=<hex bytes> (e.g. 00001000 = uint bit 20) fills every constant with those bytes instead of zero.
            const char *hex = getenv("AIR_CONST");
            for (int i = 0; hex && i < 64 && isxdigit(hex[2 * i]) && isxdigit(hex[2 * i + 1]); i++)
                sscanf(hex + 2 * i, "%2hhx", &zero[i]);
            for (MTLFunctionConstant *k in f.functionConstantsDictionary.allValues) [cv setConstantValue:zero type:k.type atIndex:k.index];
            f = [lib newFunctionWithName:name constantValues:cv error:nil] ?: f;
        }
        NSData *bc = (NSData *)[(id)f performSelector:@selector(bitcodeData)];
        Mod m = NULL;
        if (parse(ctxCreate(), mkbuf(bc.bytes, bc.length, "air"), &m)) { printf("; %s: parse failed\n", name.UTF8String); continue; }
        printf("; ===== %s\n%s\n", name.UTF8String, print(m));
    }
} return 0; }
