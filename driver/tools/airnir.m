// airnir: translates every function of a .metal / .metallib with vmg_air (AIR -> NIR) and compiles it with a Gallium
// driver: llvmpipe (default) or Panfrost's Valhall compiler for the Mali-G57 (VMG_DRIVER=panfrost, on the vgpu mock).
// Usage: airnir file.metal|file.metallib [-v] [function]     (-v prints the NIR)
// The AIR comes from the system Metal compiler (MTLCreateSystemDefaultDevice). Function constants are specialized to
// zero (AIR_CONST=<hex bytes> to use other bytes), as in metal-shim's airtrans.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../vmg.h"

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: airnir file.metal|file.metallib [-v] [function]\n"); return 2; }
    BOOL verbose = NO;
    const char *only = NULL;
    for (int i = 2; i < argc; i++) { if (!strcmp(argv[i], "-v")) verbose = YES; else only = argv[i]; }
    char err[256];
    vmg_device *dev = vmg_device_create(NULL, err, sizeof err);
    if (!dev) { fprintf(stderr, "vmg: %s\n", err); return 1; }
    printf("driver: %s\n", vmg_device_get_info(dev)->name);
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSString *path = @(argv[1]);
    NSError *e = nil;
    id<MTLLibrary> lib = [path.pathExtension isEqualToString:@"metallib"]
        ? [d newLibraryWithURL:[NSURL fileURLWithPath:path] error:&e]
        : [d newLibraryWithSource:[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] options:nil error:&e];
    if (!lib) { fprintf(stderr, "%s\n", e.description.UTF8String); return 1; }

    NSMutableArray<id<MTLFunction>> *funcs = [NSMutableArray array];
    for (NSString *name in [lib.functionNames sortedArrayUsingSelector:@selector(compare:)]) {
        if (only && strcmp(name.UTF8String, only)) continue;
        id<MTLFunction> f = [lib newFunctionWithName:name];
        if (f.functionConstantsDictionary.count) {
            MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
            uint8_t bytes[64] = {0};
            const char *hex = getenv("AIR_CONST");
            for (int i = 0; hex && i < 64 && isxdigit(hex[2 * i]) && isxdigit(hex[2 * i + 1]); i++) sscanf(hex + 2 * i, "%2hhx", &bytes[i]);
            for (MTLFunctionConstant *k in f.functionConstantsDictionary.allValues) [cv setConstantValue:bytes type:k.type atIndex:k.index];
            id<MTLFunction> sf = [lib newFunctionWithName:name constantValues:cv error:nil];
            if (sf) f = sf;
        }
        [funcs addObject:f];
    }
    // Varying table: every key the library's vertex functions write (a pipeline would use its own vertex function).
    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    for (id<MTLFunction> f in funcs) {
        if (f.functionType != MTLFunctionTypeVertex) continue;
        NSData *bc = [(id)f respondsToSelector:@selector(bitcodeData)] ? [(id)f performSelector:@selector(bitcodeData)] : nil;
        unsigned n = 0;
        char *error = NULL;
        char **k = bc ? vmg_air_vertex_outputs(bc.bytes, bc.length, &n, &error) : NULL;
        for (unsigned i = 0; i < n; i++) { [keys addObject:@(k[i])]; free(k[i]); }
        free(k); free(error);
    }
    const char **varyings = calloc(keys.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < keys.count; i++) varyings[i] = keys[i].UTF8String;

    int ok = 0, total = 0;
    for (id<MTLFunction> f in funcs) {
        total++;
        NSData *bc = [(id)f respondsToSelector:@selector(bitcodeData)] ? [(id)f performSelector:@selector(bitcodeData)] : nil;
        if (!bc.length) { printf("  FAIL  %-32s no AIR bitcode from the system compiler\n", f.name.UTF8String); continue; }
        vmg_air_input in = { .bitcode = bc.bytes, .bitcode_size = bc.length, .varyings = varyings,
                             .varying_count = (unsigned)keys.count };
        char *error = NULL;
        if (verbose) {
            char *text = vmg_air_to_nir_text(dev, &in, &error);
            if (text) { printf("%s\n", text); free(text); }
            free(error); error = NULL;
        }
        vmg_reflection refl;
        vmg_shader *sh = vmg_shader_create(dev, &in, &refl, &error);
        if (!sh) { printf("  FAIL  %-32s %s\n", f.name.UTF8String, error ? error : "?"); free(error); continue; }
        printf("  ok    %-32s buffers 0x%x textures 0x%x samplers 0x%x+%u attribs 0x%x colors 0x%x\n", f.name.UTF8String,
               refl.buffers_used, refl.textures_used | refl.textures_written, refl.samplers_used, refl.constexpr_samplers,
               refl.vertex_inputs, refl.color_outputs);
        vmg_shader_release(dev, sh);
        ok++;
    }
    printf("%d/%d translated and compiled\n", ok, total);
    vmg_device_destroy(dev);
    return ok == total ? 0 : 1;
} }
