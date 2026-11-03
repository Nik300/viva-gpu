// vgpu self-test: BO life cycle, CPU mappings, syncobjs, submit, IOSurface import. Runs against the mock on the Mac
// and unchanged against the kernel (VGPU_BACKEND=iokit) on the phone, where submit needs a valid job chain (skipped).
#include "vgpu.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <IOSurface/IOSurfaceRef.h>
#include <CoreFoundation/CoreFoundation.h>

static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static IOSurfaceRef make_surface(int w, int h)
{
    int bpe = 4;
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int fmt = 'BGRA';
    CFNumberRef nw = CFNumberCreate(NULL, kCFNumberIntType, &w), nh = CFNumberCreate(NULL, kCFNumberIntType, &h),
                nb = CFNumberCreate(NULL, kCFNumberIntType, &bpe), nf = CFNumberCreate(NULL, kCFNumberIntType, &fmt);
    CFDictionarySetValue(d, kIOSurfaceWidth, nw);
    CFDictionarySetValue(d, kIOSurfaceHeight, nh);
    CFDictionarySetValue(d, kIOSurfaceBytesPerElement, nb);
    CFDictionarySetValue(d, kIOSurfacePixelFormat, nf);
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(nw); CFRelease(nh); CFRelease(nb); CFRelease(nf); CFRelease(d);
    return s;
}

int main(void)
{
    bool real = !strcmp(vgpu_backend_name(), "iokit");
    printf("backend: %s\n", vgpu_backend_name());
    int fd = vgpu_open();
    CHECK(fd >= 0, "vgpu_open = %d", fd);
    if (fd < 0) return 1;
    CHECK(vgpu_is_fd(fd), "fd registered");

    struct vgpu_version v = {0};
    CHECK(vgpu_ioctl(fd, VGPU_SEL_GET_VERSION, &v) == 0 && v.major == VGPU_UAPI_MAJOR, "version");
    printf("gpu: %s, GPU_ID 0x%08x, page %u\n", v.name, v.gpu_id, v.page_size);

    struct vgpu_get_param p = { .param = VGPU_PARAM_GPU_PROD_ID };
    CHECK(vgpu_ioctl(fd, VGPU_SEL_GET_PARAM, &p) == 0 && (p.value >> 12) == 9, "prod id 0x%llx is a Valhall v9", p.value);
    p.param = VGPU_PARAM_SHADER_PRESENT;
    CHECK(vgpu_ioctl(fd, VGPU_SEL_GET_PARAM, &p) == 0 && __builtin_popcountll(p.value) == 2, "2 shader cores (0x%llx)", p.value);

    struct vgpu_create_bo cb = { .size = 100000 };
    CHECK(vgpu_ioctl(fd, VGPU_SEL_CREATE_BO, &cb) == 0 && cb.handle && cb.offset, "create bo");
    struct vgpu_get_bo_offset go = { .handle = cb.handle };
    CHECK(vgpu_ioctl(fd, VGPU_SEL_GET_BO_OFFSET, &go) == 0 && go.offset == cb.offset, "bo offset stable");
    struct vgpu_mmap_bo mb = { .handle = cb.handle };
    CHECK(vgpu_ioctl(fd, VGPU_SEL_MMAP_BO, &mb) == 0, "mmap token");
    uint32_t *m1 = vgpu_mmap(fd, mb.offset, cb.size), *m2 = vgpu_mmap(fd, mb.offset, cb.size);
    CHECK(m1 && m2, "two CPU mappings");
    if (m1 && m2) {
        m1[1000] = 0xdeadbeef;
        CHECK(m2[1000] == 0xdeadbeef, "mappings share the BO pages");
        CHECK(vgpu_munmap(fd, m1, cb.size) == 0, "munmap");
        CHECK(m2[1000] == 0xdeadbeef, "BO survives an unmap");
        vgpu_munmap(fd, m2, cb.size);
    }
    struct vgpu_madvise ma = { .handle = cb.handle, .madv = VGPU_MADV_DONTNEED };
    CHECK(vgpu_ioctl(fd, VGPU_SEL_MADVISE, &ma) == 0, "madvise");

    struct vgpu_syncobj_create sc = {0}, sc2 = { .flags = VGPU_SYNCOBJ_CREATE_SIGNALED };
    CHECK(vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_CREATE, &sc) == 0 && vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_CREATE, &sc2) == 0, "syncobjs");
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    uint32_t hs[2] = { sc.handle, sc2.handle };
    struct vgpu_syncobj_wait w = { .handles = (uintptr_t)hs, .count_handles = 1, .timeout_nsec = (int64_t)now + 20000000 };
    CHECK(vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_WAIT, &w) == -ETIME, "unsignalled syncobj times out");
    w.handles = (uintptr_t)&hs[1];
    CHECK(vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_WAIT, &w) == 0, "signalled syncobj");
    struct vgpu_syncobj_array sa = { .handles = (uintptr_t)hs, .count_handles = 1 };
    CHECK(vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_SIGNAL, &sa) == 0, "signal");
    w.handles = (uintptr_t)hs; w.count_handles = 2; w.flags = VGPU_SYNCOBJ_WAIT_ALL;
    CHECK(vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_WAIT, &w) == 0, "wait all");
    CHECK(vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_RESET, &sa) == 0, "reset");

    if (!real) {
        // The mock runs nothing; the submit only checks handles and signals out_sync.
        uint32_t bos[1] = { cb.handle };
        struct vgpu_submit s = { .jc = cb.offset, .bo_handles = (uintptr_t)bos, .bo_handle_count = 1, .out_sync = sc.handle };
        CHECK(vgpu_ioctl(fd, VGPU_SEL_SUBMIT, &s) == 0, "submit");
        w.count_handles = 1; w.flags = 0;
        CHECK(vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_WAIT, &w) == 0, "out_sync signalled");
    }

    IOSurfaceRef surf = make_surface(64, 32);
    CHECK(surf != NULL, "IOSurface");
    if (surf) {
        struct vgpu_import_iosurface im = { .surface_id = IOSurfaceGetID(surf) };
        int r = vgpu_ioctl(fd, VGPU_SEL_IMPORT_IOSURFACE, &im);
        CHECK(r == 0 && im.handle && im.width == 64 && im.height == 32 && im.bytes_per_row >= 256,
              "import IOSurface (r %d, %ux%u, bpr %u)", r, im.width, im.height, im.bytes_per_row);
        struct vgpu_mmap_bo ms = { .handle = im.handle };
        if (r == 0 && vgpu_ioctl(fd, VGPU_SEL_MMAP_BO, &ms) == 0) {
            uint32_t *px = vgpu_mmap(fd, ms.offset, im.bytes_per_row * im.height);
            IOSurfaceLock(surf, 0, NULL);
            ((uint32_t *)IOSurfaceGetBaseAddress(surf))[5] = 0x12345678;
            IOSurfaceUnlock(surf, 0, NULL);
            CHECK(px && px[5] == 0x12345678, "BO aliases the surface memory");
            if (px) vgpu_munmap(fd, px, im.bytes_per_row * im.height);
        }
        struct vgpu_gem_close gc = { .handle = im.handle };
        CHECK(r != 0 || vgpu_ioctl(fd, VGPU_SEL_GEM_CLOSE, &gc) == 0, "close imported BO");
        CFRelease(surf);
    }

    // A plane that does not start on a page: GPU offset = the plane's first byte, CPU mapping = its page.
    {
        int w = 100, h = 10, bpe = 4, bpr = 448, size = bpr * h * 2 + 4096 + 448 * 3;   // plane 1 lands mid-page
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFMutableDictionaryRef p0 = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFMutableDictionaryRef p1 = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        int off1 = bpr * h + 448;   // not a multiple of the page
        int nums[] = { w, h, bpe, bpr, 0, off1, size, 'BGRA' };
        CFNumberRef n[8];
        for (int i = 0; i < 8; i++) n[i] = CFNumberCreate(NULL, kCFNumberIntType, &nums[i]);
        CFDictionarySetValue(p0, kIOSurfacePlaneWidth, n[0]); CFDictionarySetValue(p0, kIOSurfacePlaneHeight, n[1]);
        CFDictionarySetValue(p0, kIOSurfacePlaneBytesPerElement, n[2]); CFDictionarySetValue(p0, kIOSurfacePlaneBytesPerRow, n[3]);
        CFDictionarySetValue(p0, kIOSurfacePlaneOffset, n[4]);
        CFDictionarySetValue(p1, kIOSurfacePlaneWidth, n[0]); CFDictionarySetValue(p1, kIOSurfacePlaneHeight, n[1]);
        CFDictionarySetValue(p1, kIOSurfacePlaneBytesPerElement, n[2]); CFDictionarySetValue(p1, kIOSurfacePlaneBytesPerRow, n[3]);
        CFDictionarySetValue(p1, kIOSurfacePlaneOffset, n[5]);
        const void *pl[2] = { p0, p1 };
        CFArrayRef arr = CFArrayCreate(NULL, pl, 2, &kCFTypeArrayCallBacks);
        CFDictionarySetValue(d, kIOSurfaceWidth, n[0]); CFDictionarySetValue(d, kIOSurfaceHeight, n[1]);
        CFDictionarySetValue(d, kIOSurfaceAllocSize, n[6]); CFDictionarySetValue(d, kIOSurfacePixelFormat, n[7]);
        CFDictionarySetValue(d, kIOSurfacePlaneInfo, arr);
        IOSurfaceRef s2 = IOSurfaceCreate(d);
        uint32_t pg = v.page_size ? v.page_size : 16384;
        if (s2 && IOSurfaceGetPlaneCount(s2) == 2) {
            size_t real_off = (size_t)((uint8_t *)IOSurfaceGetBaseAddressOfPlane(s2, 1) - (uint8_t *)IOSurfaceGetBaseAddress(s2));
            struct vgpu_import_iosurface im = { .surface_id = IOSurfaceGetID(s2), .plane = 1 };
            int r = vgpu_ioctl(fd, VGPU_SEL_IMPORT_IOSURFACE, &im);
            CHECK(r == 0 && (im.offset & (pg - 1)) == (real_off & (pg - 1)), "plane 1 GPU offset keeps its offset in the page (%llx, plane at %zu)",
                  (unsigned long long)im.offset, real_off);
            struct vgpu_mmap_bo ms = { .handle = im.handle };
            if (r == 0 && vgpu_ioctl(fd, VGPU_SEL_MMAP_BO, &ms) == 0) {
                uint8_t *m = vgpu_mmap(fd, ms.offset, (im.offset & (pg - 1)) + im.size);
                IOSurfaceLock(s2, 0, NULL);
                ((uint32_t *)IOSurfaceGetBaseAddressOfPlane(s2, 1))[0] = 0xabcdef01;
                IOSurfaceUnlock(s2, 0, NULL);
                CHECK(m && *(uint32_t *)(m + (im.offset & (pg - 1))) == 0xabcdef01, "CPU mapping starts at the page; plane at + offset in page");
                if (m) vgpu_munmap(fd, m, (im.offset & (pg - 1)) + im.size);
            }
            struct vgpu_gem_close g2 = { .handle = im.handle };
            vgpu_ioctl(fd, VGPU_SEL_GEM_CLOSE, &g2);
        } else CHECK(0, "biplanar IOSurface");
        if (s2) CFRelease(s2);
        for (int i = 0; i < 8; i++) CFRelease(n[i]);
        CFRelease(arr); CFRelease(p0); CFRelease(p1); CFRelease(d);
    }

    struct vgpu_gem_close gc = { .handle = cb.handle };
    CHECK(vgpu_ioctl(fd, VGPU_SEL_GEM_CLOSE, &gc) == 0, "gem close");
    CHECK(vgpu_ioctl(fd, VGPU_SEL_GET_BO_OFFSET, &go) == -ENOENT, "closed handle is gone");
    CHECK(vgpu_close(fd) == 0 && !vgpu_is_fd(fd), "close");
    printf("%d/%d checks passed\n", checks - failures, checks);
    return failures != 0;
}
