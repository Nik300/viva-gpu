// TeraScale Compute, G3 (docs/OTTIMIZZAZIONE-COMPUTE.md, section 1): where CL-only buffers should live when VRAM
// is short. A kernel reads and writes two buffers of the given size; placements: default (the driver picks VRAM),
// CL_MEM_ALLOC_HOST_PTR, CL_MEM_USE_HOST_PTR (page-aligned host memory). Prints GB/s moved (read + write) and the
// VRAM pressure counters of the Radeon before and after each case.
// Build: make build/vramplace   Run: build/vramplace [MB ...]   (default: 32 64)
#define CL_SILENCE_DEPRECATION 1
#include <OpenCL/opencl.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

// PerformanceStatisticsAccum of the Radeon accelerator (running totals; reading it resets nothing).
static int64_t accum(const char *key) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return -1;
    int64_t v = -1;
    io_registry_entry_t s;
    while ((s = IOIteratorNext(it))) {
        io_name_t cls = "";
        IOObjectGetClass(s, cls);
        if (v < 0 && !strncmp(cls, "AMD", 3)) {
            CFDictionaryRef d = IORegistryEntryCreateCFProperty(s, CFSTR("PerformanceStatisticsAccum"), kCFAllocatorDefault, 0);
            if (d && CFGetTypeID(d) == CFDictionaryGetTypeID()) {
                CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
                CFNumberRef n = CFDictionaryGetValue(d, k);
                if (n) CFNumberGetValue(n, kCFNumberSInt64Type, &v);
                CFRelease(k);
            }
            if (d) CFRelease(d);
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return v;
}

static const char *kSource =
    "__kernel void rw(__global const float4 *a, __global float4 *b) {\n"
    "  size_t i = get_global_id(0);\n"
    "  b[i] = a[i] * 1.0001f + b[i];\n"
    "}\n";

int main(int argc, char **argv) {
    cl_platform_id platform;
    cl_device_id dev;
    if (clGetPlatformIDs(1, &platform, NULL) || clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, 1, &dev, NULL)) {
        printf("vramplace: no OpenCL GPU\n");
        return 1;
    }
    char name[128] = "";
    cl_ulong global = 0, maxAlloc = 0;
    clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof name, name, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_GLOBAL_MEM_SIZE, sizeof global, &global, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof maxAlloc, &maxAlloc, NULL);
    printf("%s: %llu MB global, %llu MB per allocation\n", name, global >> 20, maxAlloc >> 20);
    cl_int err;
    cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
    cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err);
    cl_program prog = clCreateProgramWithSource(ctx, 1, &kSource, NULL, &err);
    if (clBuildProgram(prog, 1, &dev, NULL, NULL, NULL)) { printf("vramplace: build failed\n"); return 1; }
    cl_kernel k = clCreateKernel(prog, "rw", &err);

    int sizes[8] = { 32, 64 }, nsizes = 2;
    if (argc > 1) for (nsizes = 0; nsizes < argc - 1 && nsizes < 8; nsizes++) sizes[nsizes] = atoi(argv[nsizes + 1]);
    const char *names[3] = { "default (VRAM)", "ALLOC_HOST_PTR", "USE_HOST_PTR" };
    printf("%-8s %-16s %10s %14s %14s\n", "MB each", "placement", "GB/s", "pageOut MB", "evictWait ms");
    for (int si = 0; si < nsizes; si++) {
        size_t bytes = (size_t)sizes[si] << 20;
        if (bytes > maxAlloc) { printf("%-8d skipped: above the per-allocation limit\n", sizes[si]); continue; }
        for (int p = 0; p < 3; p++) {
            void *host[2] = { NULL, NULL };
            cl_mem m[2];
            for (int b = 0; b < 2; b++) {
                cl_mem_flags flags = CL_MEM_READ_WRITE;
                if (p == 1) flags |= CL_MEM_ALLOC_HOST_PTR;
                if (p == 2) {
                    if (posix_memalign(&host[b], 4096, bytes)) return 1;
                    memset(host[b], 0, bytes);
                    flags |= CL_MEM_USE_HOST_PTR;
                }
                m[b] = clCreateBuffer(ctx, flags, bytes, host[b], &err);
                if (!m[b]) { printf("clCreateBuffer(%s, %d MB): %d\n", names[p], sizes[si], err); return 1; }
                float zero = 0;
                clEnqueueFillBuffer(q, m[b], &zero, sizeof zero, 0, bytes, 0, NULL, NULL);
            }
            clSetKernelArg(k, 0, sizeof(cl_mem), &m[0]);
            clSetKernelArg(k, 1, sizeof(cl_mem), &m[1]);
            size_t n = bytes / 16;
            clEnqueueNDRangeKernel(q, k, 1, NULL, &n, NULL, 0, NULL, NULL);   // warm-up: placement happens here
            clFinish(q);
            int64_t po0 = accum("texturePageOutBytes"), ew0 = accum("vramEvictionWaitTime");
            const int R = 20;
            double t0 = now_s();
            for (int r = 0; r < R; r++) clEnqueueNDRangeKernel(q, k, 1, NULL, &n, NULL, 0, NULL, NULL);
            clFinish(q);
            double s = now_s() - t0;
            int64_t po1 = accum("texturePageOutBytes"), ew1 = accum("vramEvictionWaitTime");
            printf("%-8d %-16s %10.1f %14.1f %14.1f\n", sizes[si], names[p], 3.0 * bytes * R / s / 1e9,
                   po0 >= 0 && po1 >= po0 ? (po1 - po0) / 1048576.0 : -1.0, ew0 >= 0 && ew1 >= ew0 ? (ew1 - ew0) / 1e6 : -1.0);
            for (int b = 0; b < 2; b++) { clReleaseMemObject(m[b]); free(host[b]); }
        }
    }
    clReleaseKernel(k);
    clReleaseProgram(prog);
    clReleaseCommandQueue(q);
    clReleaseContext(ctx);
    return 0;
}
