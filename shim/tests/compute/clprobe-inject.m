// Compute C0.2: OpenCL inside a real app process (sandbox, Apple app), with the extension's own runtime
// (src/compute/TSCLRuntime.c). Two builds of this file:
//   build/libTSCLProbe.dylib  injected by tools/shim-run.sh --cl-probe (runs 2 s after launch, in the app)
//   build/clprobe-hardened    the same probe as an executable signed with hardened runtime + App Sandbox
//                             (tests/compute/run-hardened.sh), since shim-run copies lose the hardened runtime
// Reports to stderr (the copy's log, apps/<App>.log): sandbox state, CL device, kernel build times (cold source,
// same source again, a fixed source that a previous launch may have cached), the GL -> CL -> GL handoff through
// TSCLRuntime with its result, and which files the CL compiler wrote (where its cache lives in a container).
#define GL_SILENCE_DEPRECATION
#define CL_SILENCE_DEPRECATION
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#include "../../src/compute/TSCLRuntime.h"

int sandbox_check(pid_t pid, const char *operation, int type, ...);

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

#define P(...) do { fprintf(stderr, "[TSCLProbe] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)

static void logLine(void *ctx, TSCLLogLevel level, const char *msg) { P("runtime: %s", msg); }

static double build(cl_context ctx, cl_device_id dev, const char *src, cl_program *out) {
    cl_int e;
    double t0 = now_ms();
    cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &e);
    e = clBuildProgram(p, 1, &dev, "", NULL, NULL);
    double t = now_ms() - t0;
    if (e) {
        char log[2048] = "";
        clGetProgramBuildInfo(p, dev, CL_PROGRAM_BUILD_LOG, sizeof log, log, NULL);
        P("build failed %d: %s", e, log);
        clReleaseProgram(p);
        *out = NULL;
        return t;
    }
    *out = p;
    return t;
}

// Files written under `root` since `since` whose path mentions the CL compiler.
static void listNewFiles(NSString *root, NSDate *since) {
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root]
        includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLIsRegularFileKey] options:0 errorHandler:nil];
    int n = 0;
    for (NSURL *u in en) {
        NSDate *m = nil;
        NSNumber *reg = nil;
        [u getResourceValue:&m forKey:NSURLContentModificationDateKey error:nil];
        [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
        if (!reg.boolValue || [m compare:since] == NSOrderedAscending) continue;
        NSString *p = u.path.lowercaseString;
        if (![p containsString:@"opencl"] && ![p containsString:@"cvms"] && ![p containsString:@"com.apple.metal"] &&
            ![p containsString:@"gpuarchiver"] && ![p containsString:@"clcache"]) continue;
        if (n++ < 12) P("  new file: %s", u.path.UTF8String);
    }
    if (!n) P("  no new compiler files under %s", root.UTF8String);
}

static void probe(void) { @autoreleasepool {
    NSDate *start = [NSDate dateWithTimeIntervalSinceNow:-1];
    P("pid %d %s, sandboxed: %s", getpid(), NSProcessInfo.processInfo.processName.UTF8String, sandbox_check(getpid(), NULL, 0) ? "yes" : "no");
    P("HOME %s", NSHomeDirectory().UTF8String);
    P("TMPDIR %s", NSTemporaryDirectory().UTF8String);
    // Workbench: can the shim read its policy from TSMTL_CONFIG_DIR inside this sandbox?
    const char *configDir = getenv("TSMTL_CONFIG_DIR");
    if (configDir) {
        NSString *pp = [@(configDir) stringByAppendingPathComponent:@"policy.plist"];
        int fd = open(pp.fileSystemRepresentation, O_RDONLY);
        P("policy %s: %s", pp.UTF8String, fd >= 0 ? "readable" : strerror(errno));
        if (fd >= 0) close(fd);
    }

    CGLPixelFormatAttribute attrs[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
                                        kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pf = NULL; GLint npf = 0;
    if (CGLChoosePixelFormat(attrs, &pf, &npf) || !pf) { P("no GL 4.1 pixel format"); return; }
    CGLContextObj gl = NULL;
    CGLCreateContext(pf, NULL, &gl);
    CGLSetCurrentContext(gl);
    P("GL %s / %s", glGetString(GL_VERSION), glGetString(GL_RENDERER));

    TSCLRuntimeConfig cfg = { CGLGetShareGroup(gl), logLine, NULL };
    double t0 = now_ms();
    TSCLRuntime *rt = TSCLRuntimeCreate(&cfg);
    if (!rt) { P("TSCLRuntimeCreate failed: OpenCL unusable here"); return; }
    char name[128] = "", ver[128] = "";
    clGetDeviceInfo(TSCLRuntimeDevice(rt), CL_DEVICE_NAME, sizeof name, name, NULL);
    clGetDeviceInfo(TSCLRuntimeDevice(rt), CL_DRIVER_VERSION, sizeof ver, ver, NULL);
    P("CL context on the share group: %s, driver %s (%.1f ms)", name, ver, now_ms() - t0);

    cl_context ctx = TSCLRuntimeContext(rt);
    cl_device_id dev = TSCLRuntimeDevice(rt);
    // Unique source (never cached), the same again, and a fixed source a previous launch may have cached.
    char unique[512];
    snprintf(unique, sizeof unique, "__kernel void k(__global float *p) { p[get_global_id(0)] = %d.0f + %f; }\n", getpid(), now_ms());
    const char *fixed =
        "__kernel void fill(__write_only image2d_t img, float4 c) {\n"
        "  write_imagef(img, (int2)(get_global_id(0), get_global_id(1)), c + (float4)(0.0f, 0.0f, 0.0f, 0.0f));\n"
        "}\n// ts probe fixed v1\n";
    cl_program p1, p2, p3;
    double cold = build(ctx, dev, unique, &p1);
    double again = build(ctx, dev, unique, &p2);
    double fixedTime = build(ctx, dev, fixed, &p3);
    P("clBuildProgram: new source %.1f ms, same source again %.1f ms, fixed source %.1f ms (fast on a 2nd launch = disk cache)",
      cold, again, fixedTime);
    if (!p3) { TSCLRuntimeDestroy(rt); return; }

    // GL -> CL -> GL through the runtime: CL writes a GL texture, GL reads it back.
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glFinish();
    cl_int e;
    cl_kernel k = clCreateKernel(p3, "fill", &e);
    TSCLGLObject obj = { tex, GL_TEXTURE_2D, 0 };
    size_t g[2] = {256, 256}, l[2] = {16, 16};
    double tHand = 0;
    for (int i = 0; i < 101; i++) {
        double a = now_ms();
        cl_mem m;
        TSCLRuntimeUse(rt, &obj, 1, &m);
        cl_float4 c = {{0.25f, 0.5f, i == 100 ? 1.0f : 0.0f, 1.0f}};
        clSetKernelArg(k, 0, sizeof m, &m);
        clSetKernelArg(k, 1, sizeof c, &c);
        TSCLRuntimeDispatch(rt, k, 2, NULL, g, l);
        TSCLRuntimeEndRun(rt);
        if (i) tHand += now_ms() - a;
    }
    uint8_t px[4];
    GLuint fbo;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    glReadPixels(200, 100, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    TSCLStats s = TSCLRuntimeGetStats(rt);
    BOOL ok = px[0] >= 63 && px[0] <= 65 && px[1] >= 127 && px[1] <= 129 && px[2] == 255 && px[3] == 255;
    P("handoff: 100 runs, %.3f ms CPU each, %llu submissions, %llu errors; GL reads %d,%d,%d,%d: %s", tHand / 100,
      s.runs, s.errors, px[0], px[1], px[2], px[3], ok ? "OK" : "WRONG");
    TSCLRuntimeDestroy(rt);

    P("files written by the CL compiler since launch:");
    listNewFiles(NSHomeDirectory(), start);
    listNewFiles(NSTemporaryDirectory(), start);
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (caches && ![caches hasPrefix:NSHomeDirectory()]) listNewFiles(caches, start);
    P("done: OpenCL %s in this process", ok ? "WORKS" : "FAILED");
}}

#ifdef TS_PROBE_EXECUTABLE
int main(void) { probe(); return 0; }
#else
__attribute__((constructor)) static void TSCLProbeStart(void) {
    // Main app only (helpers inherit DYLD_INSERT_LIBRARIES), after launch has settled.
    if (!NSBundle.mainBundle.bundleIdentifier || [NSBundle.mainBundle.bundlePath hasSuffix:@".xpc"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ probe(); });
}
#endif
