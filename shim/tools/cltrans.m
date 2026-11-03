// Developer tool (TeraScale Compute): translate the kernels of an MSL file or metallib to OpenCL C and, with
// --build, compile them on the GPU. Prints the source (or only a summary with --quiet) and a final N/M line.
// --path creates each pipeline on the shim device with compute on and prints the path it takes (gl, cl, or why
// it does not run): the coverage of a system library.
// A .air file or a directory of them (TSMTL_CL_SAVE_DIR: kernels as an app specialized them) works too.
// Usage: cltrans file.metal|file.metallib|file.air|dir [function] [--build] [--quiet] [--path]
#import <Foundation/Foundation.h>
#define CL_SILENCE_DEPRECATION 1
#import <OpenCL/opencl.h>
#import "TSPrivate.h"
#import "TSMetal.h"

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: cltrans file.metal|file.metallib [function] [--build] [--quiet]\n"); return 2; }
    BOOL build = NO, quiet = NO, showPath = NO;
    NSString *only = nil;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--build")) build = YES;
        else if (!strcmp(argv[i], "--quiet")) quiet = YES;
        else if (!strcmp(argv[i], "--path")) showPath = YES;
        else only = @(argv[i]);
    }
    if (showPath) setenv("TSMTL_COMPUTE", "1", 1);
    id<MTLDevice> d = TSMtlCreateDevice();
    NSString *path = @(argv[1]);
    NSError *e = nil;
    cl_device_id dev = NULL;
    cl_context ctx = NULL;
    if (build) {
        clGetDeviceIDs(NULL, CL_DEVICE_TYPE_GPU, 1, &dev, NULL);
        ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, NULL);
    }
    __block int total = 0, translated = 0, built = 0;
    NSCountedSet *paths = [NSCountedSet set];
    void (^check)(NSString *, NSData *) = ^(NSString *name, NSData *bc) {
        NSString *err = nil;
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        TSCLKernelSource *k = TSAirTranslateOpenCL(bc, &err);
        double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
        if (!k) { printf("== %s: NOT TRANSLATED: %s\n", name.UTF8String, err.UTF8String); return; }
        translated++;
        printf("== %s: translated in %.1f ms (%lu args, tg %lu bytes%s)\n", name.UTF8String, ms,
               (unsigned long)(k.args.length / sizeof(TSCLArgSpec)), (unsigned long)k.staticThreadgroupMemory, k.barriers ? ", barriers" : "");
        if (!quiet) printf("%s\n", k.source.UTF8String);
        if (!build) return;
        const char *src = k.source.UTF8String;
        cl_int status;
        cl_program prog = clCreateProgramWithSource(ctx, 1, &src, NULL, &status);
        t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        status = clBuildProgram(prog, 1, &dev, k.options.UTF8String, NULL, NULL);
        ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
        char log[1 << 16] = "";
        clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof log, log, NULL);
        if (status == CL_SUCCESS) {
            cl_kernel kern = clCreateKernel(prog, "ts_kernel", &status);
            size_t wg = 0;
            if (kern) clGetKernelWorkGroupInfo(kern, dev, CL_KERNEL_WORK_GROUP_SIZE, sizeof wg, &wg, NULL);
            printf("   built in %.1f ms, max work-group %zu\n", ms, wg);
            if (kern) clReleaseKernel(kern);
            built++;
        } else {
            printf("   BUILD FAILED (%d) in %.1f ms\n%s\n", status, ms, log);
            if (quiet) printf("%s\n", k.source.UTF8String);
        }
        clReleaseProgram(prog);
    };
    // Kernels saved by TSMTL_CL_SAVE_DIR (specialized bitcode as the app created it): a .air file or a directory of them.
    BOOL isDir = NO;
    if ([path.pathExtension isEqualToString:@"air"] ||
        ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] && isDir)) {
        NSArray *files = isDir ? [[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil] sortedArrayUsingSelector:@selector(compare:)]
                               : @[path.lastPathComponent];
        NSString *dir = isDir ? path : path.stringByDeletingLastPathComponent;
        for (NSString *file in files) {
            if (![file.pathExtension isEqualToString:@"air"]) continue;
            NSString *name = file.stringByDeletingPathExtension;
            if (only && ![name hasPrefix:only]) continue;
            total++;
            check(name, [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:file]]);
        }
        printf("cltrans: %d kernels, %d translated%s\n", total, translated, build ? [NSString stringWithFormat:@", %d built", built].UTF8String : "");
        return 0;
    }
    id<MTLLibrary> lib = [path.pathExtension isEqualToString:@"metallib"]
        ? [d newLibraryWithURL:[NSURL fileURLWithPath:path] error:&e]
        : [d newLibraryWithSource:[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] options:nil error:&e];
    if (!lib) { fprintf(stderr, "%s\n", e.description.UTF8String); return 1; }
    for (NSString *name in [lib.functionNames sortedArrayUsingSelector:@selector(compare:)]) {
        if (only && ![name isEqualToString:only]) continue;
        id<MTLFunction> f = [lib newFunctionWithName:name];
        if (f.functionType != MTLFunctionTypeKernel) continue;
        if (f.functionConstantsDictionary.count) {   // zero specialization, as airtrans
            MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
            uint8_t zero[64] = {0};
            for (MTLFunctionConstant *k in f.functionConstantsDictionary.allValues) [cv setConstantValue:zero type:k.type atIndex:k.index];
            f = [lib newFunctionWithName:name constantValues:cv error:nil] ?: f;
        }
        total++;
        if (showPath) {
            id<MTLComputePipelineState> p = [d newComputePipelineStateWithFunction:f error:nil];
            NSString *how = [(id)p valueForKey:@"computePath"];
            NSString *kind = [how isEqualToString:@"gl"] || [how isEqualToString:@"cl"] ? how : @"refused";
            [paths addObject:kind];
            printf("== %-48s %s\n", name.UTF8String, how.UTF8String);
            continue;
        }
        check(name, (NSData *)[(id)f performSelector:@selector(bitcodeData)]);
    }
    if (showPath) {
        printf("cltrans: %d kernels: %lu GL pass, %lu OpenCL, %lu refused\n", total, (unsigned long)[paths countForObject:@"gl"],
               (unsigned long)[paths countForObject:@"cl"], (unsigned long)[paths countForObject:@"refused"]);
        return 0;
    }
    printf("cltrans: %d kernels, %d translated%s\n", total, translated,
           build ? [NSString stringWithFormat:@", %d built", built].UTF8String : "");
    return 0;
} }
