// Viva GPU: kernel simulated in-process (VGPU_BACKEND=mock), for tests on the Mac without the phone.
// BOs are anonymous memory with a GPU VA from the Panfrost range [32 MiB, 4 GiB) (first fit, like the kernel); each
// vgpu_mmap returns a new shared alias of the memory (mach_vm_remap), so munmap of a CPU mapping never frees the BO. Submits complete
// immediately: out_sync is signalled, nothing runs. GET_PARAM answers as a Mali-G57 MC2 (VGPU_MOCK_GPU_ID overrides
// the product id, e.g. 9093).
#include "vgpu.h"
#include <errno.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <IOSurface/IOSurfaceRef.h>

#define MAX_HANDLES 65536

typedef struct {
    void *addr;          // the BO's memory; NULL = free handle
    uint64_t va;         // GPU virtual address (page aligned)
    uint64_t gpu_offset; // imported IOSurface plane: offset of the plane in its first page (GPU offset = va + this)
    size_t size;
    uint32_t flags, madv;
    bool imported;
    IOSurfaceRef surface;   // imported: kept alive while the BO exists
} MockBO;

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    MockBO *bos;          // index = handle
    uint8_t *syncobj;     // index = handle: 0 free, 1 unsignalled, 2 signalled
    uint32_t nextBO, nextSync;
} MockConn;

// GPU VA allocator: first fit over the BOs sorted by address (linear scan; tests have few BOs).
static uint64_t va_alloc(MockConn *c, size_t size)
{
    uint64_t start = VGPU_VA_START;
    for (;;) {
        bool moved = false;
        for (uint32_t i = 1; i < MAX_HANDLES; i++) {
            MockBO *b = &c->bos[i];
            if (b->addr && b->va < start + size && start < b->va + b->size) { start = b->va + b->size; moved = true; }
        }
        if (!moved) break;
    }
    return start + size <= VGPU_VA_END ? start : 0;
}

static vgpu_mock_submit_hook g_hook;
static void *g_hookCtx;
void vgpu_mock_set_submit_hook(vgpu_mock_submit_hook hook, void *ctx) { g_hook = hook; g_hookCtx = ctx; }

static int mock_open(void **out)
{
    MockConn *c = calloc(1, sizeof *c);
    c->bos = calloc(MAX_HANDLES, sizeof(MockBO));
    c->syncobj = calloc(MAX_HANDLES, 1);
    c->nextBO = c->nextSync = 1;
    pthread_mutex_init(&c->lock, NULL);
    pthread_cond_init(&c->cond, NULL);
    *out = c;
    return 0;
}

static void mock_close(void *conn)
{
    MockConn *c = conn;
    for (uint32_t i = 1; i < MAX_HANDLES; i++)
        if (c->bos[i].surface) CFRelease(c->bos[i].surface);
        else if (c->bos[i].addr && !c->bos[i].imported) munmap(c->bos[i].addr, c->bos[i].size);
    free(c->bos);
    free(c->syncobj);
    free(c);
}

static uint64_t mock_gpu_id(void)
{
    const char *env = getenv("VGPU_MOCK_GPU_ID");
    return env ? strtoul(env, NULL, 16) : 0x9091;
}

static int get_param(struct vgpu_get_param *p)
{
    switch (p->param) {
    case VGPU_PARAM_GPU_PROD_ID: p->value = mock_gpu_id(); break;
    case VGPU_PARAM_GPU_REVISION: p->value = 0; break;
    case VGPU_PARAM_SHADER_PRESENT: p->value = 0x5; break;          // MC2: two cores (Valhall core masks are sparse)
    case VGPU_PARAM_TILER_PRESENT: case VGPU_PARAM_L2_PRESENT: p->value = 1; break;
    case VGPU_PARAM_STACK_PRESENT: p->value = 0; break;
    case VGPU_PARAM_AS_PRESENT: p->value = 0xff; break;
    case VGPU_PARAM_JS_PRESENT: p->value = 0x7; break;
    case VGPU_PARAM_L2_FEATURES: p->value = 0x07110206; break;      // 256 KiB L2, 64-byte lines (typical G57)
    case VGPU_PARAM_CORE_FEATURES: p->value = 0; break;
    case VGPU_PARAM_TILER_FEATURES: p->value = 0x809; break;
    case VGPU_PARAM_MEM_FEATURES: p->value = 0x1; break;
    case VGPU_PARAM_MMU_FEATURES: p->value = 0x2830; break;
    case VGPU_PARAM_THREAD_FEATURES: p->value = 0x4010000; break;
    case VGPU_PARAM_MAX_THREADS: p->value = 1024; break;
    case VGPU_PARAM_THREAD_MAX_WORKGROUP_SZ: case VGPU_PARAM_THREAD_MAX_BARRIER_SZ: p->value = 1024; break;
    case VGPU_PARAM_COHERENCY_FEATURES: p->value = 1u << VGPU_COHERENCY_NONE; break;
    case VGPU_PARAM_SELECTED_COHERENCY: p->value = VGPU_COHERENCY_NONE; break;
    case VGPU_PARAM_TEXTURE_FEATURES0: p->value = 0xc1ffff9e; break;
    case VGPU_PARAM_TEXTURE_FEATURES1: case VGPU_PARAM_TEXTURE_FEATURES2: case VGPU_PARAM_TEXTURE_FEATURES3:
        p->value = 0; break;
    case VGPU_PARAM_NR_CORE_GROUPS: p->value = 1; break;
    case VGPU_PARAM_THREAD_TLS_ALLOC: p->value = 0; break;
    case VGPU_PARAM_AFBC_FEATURES: p->value = 0; break;
    case VGPU_PARAM_SYSTEM_TIMESTAMP: p->value = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 77; break;  // 13 MHz
    case VGPU_PARAM_SYSTEM_TIMESTAMP_FREQUENCY: p->value = 13000000; break;
    case VGPU_PARAM_ALLOWED_JM_CTX_PRIORITIES: p->value = 1u << 1; break;   // medium only
    default:
        if (p->param >= VGPU_PARAM_JS_FEATURES0 && p->param <= VGPU_PARAM_JS_FEATURES15) {
            unsigned js = p->param - VGPU_PARAM_JS_FEATURES0;
            p->value = js == 0 ? 0x20e : js < 3 ? 0x1fe : 0;   // JS0 fragment, JS1/2 vertex+tiler+compute
            break;
        }
        return -EINVAL;
    }
    return 0;
}

static MockBO *bo(MockConn *c, uint32_t h) { return h && h < MAX_HANDLES && c->bos[h].addr ? &c->bos[h] : NULL; }

static int wait_syncobjs(MockConn *c, struct vgpu_syncobj_wait *w)
{
    // Submits complete at once, so an unsignalled syncobj only becomes signalled through SIGNAL (or never).
    const uint32_t *h = (const uint32_t *)(uintptr_t)w->handles;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    int64_t left = w->timeout_nsec - (int64_t)now;
    for (;;) {
        uint32_t done = 0, first = UINT32_MAX;
        for (uint32_t i = 0; i < w->count_handles; i++) {
            if (!h[i] || h[i] >= MAX_HANDLES || !c->syncobj[h[i]]) return -EINVAL;
            if (c->syncobj[h[i]] == 2) { done++; if (first == UINT32_MAX) first = i; }
        }
        if ((w->flags & VGPU_SYNCOBJ_WAIT_ALL) ? done == w->count_handles : done > 0) {
            w->first_signaled = first == UINT32_MAX ? 0 : first;
            return 0;
        }
        if (left <= 0) return -ETIME;
        // Relative wait on the condition (macOS has no monotonic pthread_cond_timedwait); re-check after.
        struct timespec rel = { (time_t)(left / 1000000000), (long)(left % 1000000000) };
        pthread_cond_timedwait_relative_np(&c->cond, &c->lock, &rel);
        left = w->timeout_nsec - (int64_t)clock_gettime_nsec_np(CLOCK_MONOTONIC);
    }
}

static int mock_ioctl(void *conn, enum vgpu_selector sel, void *arg, size_t size)
{
    MockConn *c = conn;
    (void)size;
    int ret = 0;
    pthread_mutex_lock(&c->lock);
    switch (sel) {
    case VGPU_SEL_GET_VERSION: {
        struct vgpu_version *v = arg;
        v->major = VGPU_UAPI_MAJOR; v->minor = VGPU_UAPI_MINOR;
        v->gpu_id = (uint32_t)(mock_gpu_id() << 16);
        v->page_size = (uint32_t)getpagesize();
        snprintf(v->name, sizeof v->name, "Mali-G57 MC2 (mock)");
        break;
    }
    case VGPU_SEL_GET_PARAM: ret = get_param(arg); break;
    case VGPU_SEL_CREATE_BO: {
        struct vgpu_create_bo *a = arg;
        size_t sz = ((size_t)a->size + getpagesize() - 1) & ~((size_t)getpagesize() - 1);
        if (!sz) { ret = -EINVAL; break; }
        uint32_t h = c->nextBO;
        while (h < MAX_HANDLES && c->bos[h].addr) h++;
        if (h >= MAX_HANDLES) { ret = -ENOMEM; break; }
        uint64_t va = va_alloc(c, sz);
        if (!va) { ret = -ENOSPC; break; }
        void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (p == MAP_FAILED) { ret = -ENOMEM; break; }
        c->bos[h] = (MockBO){ p, va, 0, sz, a->flags, VGPU_MADV_WILLNEED, false, NULL };
        c->nextBO = h + 1;
        a->handle = h;
        a->offset = va;
        break;
    }
    case VGPU_SEL_MMAP_BO: {
        struct vgpu_mmap_bo *a = arg;
        if (!bo(c, a->handle)) { ret = -ENOENT; break; }
        a->offset = a->handle;   // token = handle, as the kernel (uapi); handles start at 1
        break;
    }
    case VGPU_SEL_GET_BO_OFFSET: {
        struct vgpu_get_bo_offset *a = arg;
        MockBO *b = bo(c, a->handle);
        if (!b) { ret = -ENOENT; break; }
        a->offset = b->va + b->gpu_offset;
        break;
    }
    case VGPU_SEL_GEM_CLOSE: {
        struct vgpu_gem_close *a = arg;
        MockBO *b = bo(c, a->handle);
        if (!b) { ret = -ENOENT; break; }
        if (b->surface) CFRelease(b->surface);
        else if (!b->imported) munmap(b->addr, b->size);
        *b = (MockBO){0};
        if (a->handle < c->nextBO) c->nextBO = a->handle;
        break;
    }
    case VGPU_SEL_SUBMIT: {
        struct vgpu_submit *a = arg;
        if (!a->jc) { ret = -EINVAL; break; }
        const uint32_t *bos = (const uint32_t *)(uintptr_t)a->bo_handles;
        for (uint32_t i = 0; i < a->bo_handle_count; i++)
            if (!bo(c, bos[i])) { ret = -ENOENT; break; }
        if (ret) break;
        if (getenv("VGPU_MOCK_TRACE"))
            fprintf(stderr, "vgpu mock: submit jc 0x%llx %s, %u BOs, %u in-syncs, out-sync %u\n",
                    (unsigned long long)a->jc, (a->requirements & VGPU_JD_REQ_FS) ? "fragment" : "vertex/compute",
                    a->bo_handle_count, a->in_sync_count, a->out_sync);
        if (g_hook) {
            pthread_mutex_unlock(&c->lock);
            g_hook(a, g_hookCtx);
            pthread_mutex_lock(&c->lock);
        }
        if (a->out_sync) {
            if (a->out_sync >= MAX_HANDLES || !c->syncobj[a->out_sync]) { ret = -ENOENT; break; }
            c->syncobj[a->out_sync] = 2;
            pthread_cond_broadcast(&c->cond);
        }
        break;
    }
    case VGPU_SEL_WAIT_BO: {
        struct vgpu_wait_bo *a = arg;
        if (!bo(c, a->handle)) ret = -ENOENT;   // idle: nothing ever runs
        break;
    }
    case VGPU_SEL_MADVISE: {
        struct vgpu_madvise *a = arg;
        MockBO *b = bo(c, a->handle);
        if (!b) { ret = -ENOENT; break; }
        b->madv = a->madv;
        a->retained = 1;
        break;
    }
    case VGPU_SEL_SYNCOBJ_CREATE: {
        struct vgpu_syncobj_create *a = arg;
        uint32_t h = c->nextSync;
        while (h < MAX_HANDLES && c->syncobj[h]) h++;
        if (h >= MAX_HANDLES) { ret = -ENOMEM; break; }
        c->syncobj[h] = (a->flags & VGPU_SYNCOBJ_CREATE_SIGNALED) ? 2 : 1;
        c->nextSync = h + 1;
        a->handle = h;
        break;
    }
    case VGPU_SEL_SYNCOBJ_DESTROY: {
        struct vgpu_syncobj_destroy *a = arg;
        if (!a->handle || a->handle >= MAX_HANDLES || !c->syncobj[a->handle]) { ret = -EINVAL; break; }
        c->syncobj[a->handle] = 0;
        if (a->handle < c->nextSync) c->nextSync = a->handle;
        break;
    }
    case VGPU_SEL_SYNCOBJ_WAIT: ret = wait_syncobjs(c, arg); break;
    case VGPU_SEL_SYNCOBJ_RESET:
    case VGPU_SEL_SYNCOBJ_SIGNAL: {
        struct vgpu_syncobj_array *a = arg;
        const uint32_t *h = (const uint32_t *)(uintptr_t)a->handles;
        for (uint32_t i = 0; i < a->count_handles; i++)
            if (!h[i] || h[i] >= MAX_HANDLES || !c->syncobj[h[i]]) { ret = -EINVAL; break; }
        if (ret) break;
        for (uint32_t i = 0; i < a->count_handles; i++) c->syncobj[h[i]] = sel == VGPU_SEL_SYNCOBJ_SIGNAL ? 2 : 1;
        pthread_cond_broadcast(&c->cond);
        break;
    }
    case VGPU_SEL_IMPORT_IOSURFACE: {
        // In-process: the surface's own memory is the BO.
        struct vgpu_import_iosurface *a = arg;
        IOSurfaceRef s = IOSurfaceLookup(a->surface_id);
        if (!s) { ret = -ENOENT; break; }
        size_t planes = IOSurfaceGetPlaneCount(s);
        if (a->plane >= (planes ? planes : 1)) { CFRelease(s); ret = -EINVAL; break; }
        uint32_t h = c->nextBO;
        while (h < MAX_HANDLES && c->bos[h].addr) h++;
        if (h >= MAX_HANDLES) { CFRelease(s); ret = -ENOMEM; break; }
        // As the kernel (patch 0100): the BO covers [page of the plane, end of the surface); the GPU offset is the
        // plane's first byte, the CPU mapping starts at the page.
        size_t pg = (size_t)getpagesize();
        uint8_t *base = IOSurfaceGetBaseAddress(s);
        uint8_t *plane = planes ? IOSurfaceGetBaseAddressOfPlane(s, a->plane) : base;
        size_t total = IOSurfaceGetAllocSize(s);
        uint8_t *start = (uint8_t *)((uintptr_t)plane & ~(uintptr_t)(pg - 1));
        size_t vsize = ((size_t)(base + total - start) + pg - 1) & ~(pg - 1);
        uint64_t va = va_alloc(c, vsize);
        if (!va) { CFRelease(s); ret = -ENOSPC; break; }
        c->bos[h] = (MockBO){ start, va, (plane - start), vsize, 0, VGPU_MADV_WILLNEED, true, s };
        c->nextBO = h + 1;
        a->handle = h;
        a->offset = va + (uint64_t)(plane - start);
        a->size = total - (size_t)(plane - base);
        a->bytes_per_row = (uint32_t)(planes ? IOSurfaceGetBytesPerRowOfPlane(s, a->plane) : IOSurfaceGetBytesPerRow(s));
        a->pixel_format = IOSurfaceGetPixelFormat(s);
        a->width = (uint32_t)(planes ? IOSurfaceGetWidthOfPlane(s, a->plane) : IOSurfaceGetWidth(s));
        a->height = (uint32_t)(planes ? IOSurfaceGetHeightOfPlane(s, a->plane) : IOSurfaceGetHeight(s));
        break;
    }
    case VGPU_SEL_SYNC_BO: break;          // coherent: nothing to do
    case VGPU_SEL_QUERY_BO_INFO: {
        struct vgpu_query_bo_info *a = arg;
        MockBO *b = bo(c, a->handle);
        if (!b) { ret = -ENOENT; break; }
        a->create_flags = b->flags;
        a->extra_flags = b->imported ? VGPU_BO_IS_IMPORTED : 0;
        break;
    }
    case VGPU_SEL_SYNCOBJ_TRANSFER: {
        struct vgpu_syncobj_transfer *a = arg;
        if (!a->src || a->src >= MAX_HANDLES || !c->syncobj[a->src] || !a->dst || a->dst >= MAX_HANDLES || !c->syncobj[a->dst]) {
            ret = -EINVAL; break;
        }
        c->syncobj[a->dst] = c->syncobj[a->src];
        pthread_cond_broadcast(&c->cond);
        break;
    }
    case VGPU_SEL_IMPORT_USERPTR: {
        struct vgpu_import_userptr *a = arg;
        size_t pg = (size_t)getpagesize();
        if (!a->addr || !a->size || (a->addr & (pg - 1)) || (a->size & (pg - 1))) { ret = -EINVAL; break; }
        uint32_t h = c->nextBO;
        while (h < MAX_HANDLES && c->bos[h].addr) h++;
        uint64_t va = h < MAX_HANDLES ? va_alloc(c, a->size) : 0;
        if (!va) { ret = -ENOSPC; break; }
        c->bos[h] = (MockBO){ (void *)(uintptr_t)a->addr, va, 0, a->size, 0, VGPU_MADV_WILLNEED, true, NULL };
        c->nextBO = h + 1;
        a->handle = h;
        a->offset = va;
        break;
    }
    case VGPU_SEL_JM_CTX_CREATE: ((struct vgpu_jm_ctx *)arg)->handle = 1; break;
    case VGPU_SEL_JM_CTX_DESTROY: break;
    default: ret = -EINVAL;
    }
    pthread_mutex_unlock(&c->lock);
    return ret;
}

static void *mock_mmap(void *conn, uint64_t token, size_t size)
{
    MockConn *c = conn;
    pthread_mutex_lock(&c->lock);
    MockBO *b = bo(c, (uint32_t)token);
    void *src = b ? b->addr : NULL;
    size_t bsize = b ? b->size : 0;
    pthread_mutex_unlock(&c->lock);
    if (!src || size > bsize) { errno = EINVAL; return NULL; }
    vm_address_t dst = 0;   // vm_remap: mach_vm_remap is not in the iOS SDK
    vm_prot_t cur, max;
    kern_return_t kr = vm_remap(mach_task_self(), &dst, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                (vm_address_t)(uintptr_t)src, FALSE, &cur, &max, VM_INHERIT_SHARE);
    if (kr != KERN_SUCCESS) { errno = ENOMEM; return NULL; }
    return (void *)(uintptr_t)dst;
}

static int mock_munmap(void *conn, void *addr, size_t size)
{
    (void)conn;
    return munmap(addr, size) ? -errno : 0;
}

const struct vgpu_backend vgpu_backend_mock = { "mock", mock_open, mock_close, mock_ioctl, mock_mmap, mock_munmap };
