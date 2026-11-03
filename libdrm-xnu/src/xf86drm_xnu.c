// libdrm for XNU: the libdrm entry points Mesa's Panfrost uses (SYMBOLS.txt), implemented on the Viva GPU client
// (vgpu/, uapi/viva_gpu_uapi.h). The DRM fd is a vgpu fd; DRM_IOCTL_PANFROST_* and the syncobj ioctls become vgpu
// selectors with the same structures. A "dma-buf fd" is an IOSurface plane (vmg_drm_surface_fd): importing it maps
// the surface's pages into the GPU (VGPU_SEL_IMPORT_IOSURFACE). Anything else returns -ENOSYS.
#include <errno.h>
#include <stdbool.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>
#include <IOSurface/IOSurfaceRef.h>
#include "xf86drm.h"
#include "libdrm/drm.h"
#include "libdrm/panfrost_drm.h"
#include "../../vgpu/vgpu.h"

_Static_assert(sizeof(struct drm_panfrost_submit) == sizeof(struct vgpu_submit), "submit layout");
_Static_assert(sizeof(struct drm_panfrost_create_bo) == sizeof(struct vgpu_create_bo), "create_bo layout");
_Static_assert(sizeof(struct drm_panfrost_madvise) == sizeof(struct vgpu_madvise), "madvise layout");
_Static_assert(sizeof(struct drm_syncobj_wait) == sizeof(struct vgpu_syncobj_wait), "syncobj_wait layout");
_Static_assert(sizeof(struct drm_panfrost_sync_bo) == sizeof(struct vgpu_sync_bo), "sync_bo layout");

static int ret_errno(int r) { if (r < 0) { errno = -r; return -1; } return r; }

// ---- ioctl ----------------------------------------------------------------------------------------------------------

// Imported IOSurface planes that do not start on a page: the GPU offset is the plane, the CPU mapping starts at the
// page (uapi). Panfrost expects both to address the same byte, so drmMap adds the plane's offset in the page.
// Imported surfaces also remember (surface, plane): importing one again returns the same handle, as dma-buf imports do
// on Linux, so Panfrost sees one BO and orders the jobs that write and read it (two Metal textures over one surface).
typedef struct { int fd; uint32_t handle; uint64_t token; uint32_t in_page; uint32_t surface, plane; } BOInfo;
static BOInfo g_bo[1024];
static unsigned g_bo_count;
static pthread_mutex_t g_bo_lock = PTHREAD_MUTEX_INITIALIZER;

static BOInfo *bo_info(int fd, uint32_t handle, bool create)
{
    for (unsigned i = 0; i < g_bo_count; i++) if (g_bo[i].fd == fd && g_bo[i].handle == handle) return &g_bo[i];
    if (!create || g_bo_count == 1024) return NULL;
    g_bo[g_bo_count] = (BOInfo){ fd, handle, 0, 0, 0, 0 };
    return &g_bo[g_bo_count++];
}

static void bo_forget(int fd, uint32_t handle)
{
    pthread_mutex_lock(&g_bo_lock);
    BOInfo *b = bo_info(fd, handle, false);
    if (b) *b = g_bo[--g_bo_count];
    pthread_mutex_unlock(&g_bo_lock);
}

static void map_cache_drop(int fd, uint32_t handle);

// ---- Batched submits and the completion page (kernel uapi minor >= 2, K0h) ------------------------------------------

// Per connection: SUBMITs are queued (with copies of their arrays: Panfrost frees them on return) and sent together
// with SUBMIT_BATCH, in order, before any other kernel call that could depend on them and whenever the queue holds
// VGPU_BATCH_MAX of them (default 16: the GPU starts on a frame's first passes while the CPU replays the rest).
// The kernel's job number of every submit is kept per BO: a BO whose last job is at or below the completion page's
// watermark is idle, so WAIT_BO is answered without a kernel call (not for imported IOSurfaces: other processes' jobs
// count there, nor for write-back cached BOs: their CPU caches are invalidated by the kernel's wait).
// VGPU_NO_SUBMIT_BATCH=1, VGPU_NO_LOCAL_WAIT=1: one call per SUBMIT / every WAIT_BO to the kernel, as before.
enum { BO_SHARED = 1, BO_WB = 2 };
typedef struct {
    struct vgpu_submit s;
    uint32_t *arrays;            // bo_handles then in_syncs
} QueuedSubmit;
typedef struct {
    pthread_mutex_t lock;
    uint32_t minor;
    const struct vgpu_completion *page;
    size_t page_size;
    bool batch, local_wait;
    unsigned batch_max;
    QueuedSubmit q[64];
    unsigned qn;
    uint32_t *bo_seq; uint8_t *bo_flags; uint32_t bo_cap;   // index = BO handle
} FdState;
static FdState *g_fd_state[1024];
static pthread_mutex_t g_fd_state_lock = PTHREAD_MUTEX_INITIALIZER;

static FdState *fd_state(int fd)
{
    if (fd < 0 || fd >= 1024) return NULL;
    pthread_mutex_lock(&g_fd_state_lock);
    FdState *st = g_fd_state[fd];
    if (!st) {
        st = calloc(1, sizeof *st);
        pthread_mutex_init(&st->lock, NULL);
        struct vgpu_version v = {0};
        if (!vgpu_ioctl(fd, VGPU_SEL_GET_VERSION, &v)) st->minor = v.minor;
        if (st->minor >= 2) {
            st->page_size = v.page_size ? v.page_size : 16384;
            st->page = vgpu_mmap(fd, VGPU_MAP_COMPLETION, st->page_size);
            st->batch = !getenv("VGPU_NO_SUBMIT_BATCH");
            st->local_wait = st->page && !getenv("VGPU_NO_LOCAL_WAIT");
            const char *m = getenv("VGPU_BATCH_MAX");
            st->batch_max = m ? (unsigned)atoi(m) : 16;
            if (st->batch_max < 1) st->batch_max = 1;
            if (st->batch_max > 64) st->batch_max = 64;
        }
        g_fd_state[fd] = st;
    }
    pthread_mutex_unlock(&g_fd_state_lock);
    return st;
}

// Lock held: per-BO table.
static void bo_track(FdState *st, uint32_t handle, uint32_t seq, uint8_t set_flags, bool reset)
{
    if (handle >= st->bo_cap) {
        uint32_t cap = st->bo_cap ? st->bo_cap : 1024;
        while (cap <= handle) cap *= 2;
        st->bo_seq = realloc(st->bo_seq, cap * sizeof *st->bo_seq);
        st->bo_flags = realloc(st->bo_flags, cap);
        memset(st->bo_seq + st->bo_cap, 0, (cap - st->bo_cap) * sizeof *st->bo_seq);
        memset(st->bo_flags + st->bo_cap, 0, cap - st->bo_cap);
        st->bo_cap = cap;
    }
    if (reset) { st->bo_seq[handle] = 0; st->bo_flags[handle] = 0; }
    if (seq) st->bo_seq[handle] = seq;
    st->bo_flags[handle] |= set_flags;
}

static void record_submit(FdState *st, const struct vgpu_submit *s)
{
    const uint32_t *h = (const uint32_t *)(uintptr_t)s->bo_handles;
    for (uint32_t i = 0; i < s->bo_handle_count; i++) bo_track(st, h[i], s->seq, 0, false);
}

// Lock held: sends the queue. A failing submit is reported and skipped; the ones after it still go, as separate
// SUBMIT calls would have.
static void flush_locked(int fd, FdState *st)
{
    if (!st->qn) return;
    struct vgpu_submit subs[64];
    for (unsigned i = 0; i < st->qn; i++) subs[i] = st->q[i].s;
    unsigned start = 0;
    while (start < st->qn) {
        struct vgpu_submit_batch b = { (uintptr_t)&subs[start], st->qn - start, sizeof(struct vgpu_submit), 0, 0 };
        int r = vgpu_ioctl(fd, VGPU_SEL_SUBMIT_BATCH, &b);
        for (unsigned i = 0; i < b.done; i++) record_submit(st, &subs[start + i]);
        start += b.done;
        if (r) {
            fprintf(stderr, "vgpu: batched submit failed (%d): job dropped\n", r);
            start++;
        }
    }
    for (unsigned i = 0; i < st->qn; i++) free(st->q[i].arrays);
    st->qn = 0;
}

static void flush_fd(int fd)
{
    FdState *st = fd_state(fd);
    if (!st || !st->batch) return;
    pthread_mutex_lock(&st->lock);
    flush_locked(fd, st);
    pthread_mutex_unlock(&st->lock);
}

// SUBMIT: queued (0) or sent now (the kernel's result).
static int submit(int fd, struct vgpu_submit *a)
{
    FdState *st = fd_state(fd);
    if (!st || !st->batch) {
        int r = vgpu_ioctl(fd, VGPU_SEL_SUBMIT, a);
        if (!r && st && st->minor >= 2) {
            pthread_mutex_lock(&st->lock);
            record_submit(st, a);
            pthread_mutex_unlock(&st->lock);
        }
        return r;
    }
    if (a->bo_handle_count > 4096 || a->in_sync_count > 256) return -EINVAL;
    uint32_t *arrays = malloc(((size_t)a->bo_handle_count + a->in_sync_count + 1) * sizeof(uint32_t));
    if (!arrays) return -ENOMEM;
    memcpy(arrays, (const void *)(uintptr_t)a->bo_handles, a->bo_handle_count * sizeof(uint32_t));
    memcpy(arrays + a->bo_handle_count, (const void *)(uintptr_t)a->in_syncs, a->in_sync_count * sizeof(uint32_t));
    pthread_mutex_lock(&st->lock);
    QueuedSubmit *q = &st->q[st->qn++];
    q->s = *a;
    q->s.bo_handles = (uintptr_t)arrays;
    q->s.in_syncs = (uintptr_t)(arrays + a->bo_handle_count);
    q->s.seq = 0;
    q->arrays = arrays;
    if (st->qn >= st->batch_max) flush_locked(fd, st);
    pthread_mutex_unlock(&st->lock);
    return 0;
}

// The uapi's timeouts are absolute CLOCK_MONOTONIC ns, the clock Mesa computes them from (os_time_get_nano) and the
// kernel compares them with (0120). A deadline at or before now is a poll.
static bool deadline_passed(int64_t timeout_ns)
{
    struct timespec ts;
    if (timeout_ns <= 0) return true;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return false;
    return timeout_ns <= (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

// WAIT_BO: 0 / -EBUSY answered here when the completion page settles it, else 1 (ask the kernel). A BO used by a
// queued submit sends the queue first.
static int wait_bo_local(int fd, struct vgpu_wait_bo *w)
{
    FdState *st = fd_state(fd);
    if (!st || st->minor < 2) return 1;
    pthread_mutex_lock(&st->lock);
    for (unsigned i = 0; i < st->qn; i++) {
        const uint32_t *h = (const uint32_t *)(uintptr_t)st->q[i].s.bo_handles;
        for (uint32_t k = 0; k < st->q[i].s.bo_handle_count; k++) {
            if (h[k] != w->handle) continue;
            // Its job is not even submitted: a poll is busy (Panfrost's BO cache polls the BO it just released),
            // a real wait sends the queue first.
            if (deadline_passed(w->timeout_ns)) { pthread_mutex_unlock(&st->lock); return -EBUSY; }
            flush_locked(fd, st);
            goto flushed;
        }
    }
flushed:;
    int answer = 1;
    if (st->local_wait && w->handle < st->bo_cap && !(st->bo_flags[w->handle] & (BO_SHARED | BO_WB))) {
        uint32_t seq = st->bo_seq[w->handle];
        uint32_t done = __atomic_load_n(&st->page->completed, __ATOMIC_ACQUIRE);
        if (!seq || (int32_t)(done - seq) >= 0) answer = 0;
        else if (deadline_passed(w->timeout_ns)) answer = -EBUSY;   // a poll: the job is ours and not finished
    } else if (st->local_wait && w->handle >= st->bo_cap) {
        answer = 0;   // never submitted, never imported (imports are tracked)
    }
    pthread_mutex_unlock(&st->lock);
    return answer;
}

static void bo_flags_set(int fd, uint32_t handle, uint8_t flags, bool reset)
{
    FdState *st = fd_state(fd);
    if (!st || st->minor < 2) return;
    pthread_mutex_lock(&st->lock);
    bo_track(st, handle, 0, flags, reset);
    pthread_mutex_unlock(&st->lock);
}

int drmIoctl(int fd, unsigned long request, void *arg)
{
    enum vgpu_selector sel;
    switch (request) {
    case DRM_IOCTL_PANFROST_SUBMIT: sel = VGPU_SEL_SUBMIT; break;
    case DRM_IOCTL_PANFROST_WAIT_BO: sel = VGPU_SEL_WAIT_BO; break;
    case DRM_IOCTL_PANFROST_CREATE_BO: sel = VGPU_SEL_CREATE_BO; break;
    case DRM_IOCTL_PANFROST_MMAP_BO: sel = VGPU_SEL_MMAP_BO; break;
    case DRM_IOCTL_PANFROST_GET_PARAM: sel = VGPU_SEL_GET_PARAM; break;
    case DRM_IOCTL_PANFROST_GET_BO_OFFSET: sel = VGPU_SEL_GET_BO_OFFSET; break;
    case DRM_IOCTL_PANFROST_MADVISE: sel = VGPU_SEL_MADVISE; break;
    case DRM_IOCTL_PANFROST_SYNC_BO: sel = VGPU_SEL_SYNC_BO; break;
    case DRM_IOCTL_PANFROST_QUERY_BO_INFO: sel = VGPU_SEL_QUERY_BO_INFO; break;
    case DRM_IOCTL_PANFROST_JM_CTX_CREATE: sel = VGPU_SEL_JM_CTX_CREATE; break;
    case DRM_IOCTL_PANFROST_JM_CTX_DESTROY: sel = VGPU_SEL_JM_CTX_DESTROY; break;
    case DRM_IOCTL_GEM_CLOSE: sel = VGPU_SEL_GEM_CLOSE; break;
    case DRM_IOCTL_SYNCOBJ_CREATE: sel = VGPU_SEL_SYNCOBJ_CREATE; break;
    case DRM_IOCTL_SYNCOBJ_DESTROY: sel = VGPU_SEL_SYNCOBJ_DESTROY; break;
    case DRM_IOCTL_SYNCOBJ_WAIT: sel = VGPU_SEL_SYNCOBJ_WAIT; break;
    case DRM_IOCTL_SYNCOBJ_RESET: sel = VGPU_SEL_SYNCOBJ_RESET; break;
    case DRM_IOCTL_SYNCOBJ_SIGNAL: sel = VGPU_SEL_SYNCOBJ_SIGNAL; break;
    case DRM_IOCTL_PANFROST_SET_LABEL_BO: return 0;   // labels are debugging aids only
    default:
        errno = ENOSYS;
        return -1;
    }
    // VGPU_TRACE_BO=1: GPU address ranges of BOs as they are created and closed (to place MMU fault addresses).
    static int trace_bo = -1;
    if (trace_bo < 0) trace_bo = getenv("VGPU_TRACE_BO") != NULL;
    if (trace_bo && sel == VGPU_SEL_GEM_CLOSE) fprintf(stderr, "vgpu: close %u\n", ((struct vgpu_gem_close *)arg)->handle);
    // MMAP_BO: the uapi's mmap token is the BO handle (VGPU_SEL_MMAP_BO), so no kernel call is needed; Panfrost asks
    // for it at every mapping of a BO taken from its cache.
    // MADVISE: the kernel stores the flag and never purges (retained = 1, VivaGPUUserClient), so it is answered here:
    // Panfrost calls it twice per BO it recycles through its cache. VGPU_MADVISE_KERNEL=1 sends it to the kernel.
    static int madv_kernel = -1;
    if (madv_kernel < 0) madv_kernel = getenv("VGPU_MADVISE_KERNEL") != NULL;
    int r;
    if (sel == VGPU_SEL_MMAP_BO) r = (((struct vgpu_mmap_bo *)arg)->offset = ((struct vgpu_mmap_bo *)arg)->handle, 0);
    else if (sel == VGPU_SEL_MADVISE && !madv_kernel) r = (((struct vgpu_madvise *)arg)->retained = 1, 0);
    else if (sel == VGPU_SEL_SUBMIT) r = submit(fd, arg);
    else if (sel == VGPU_SEL_WAIT_BO && (r = wait_bo_local(fd, arg)) <= 0) {}
    else {
        if (sel != VGPU_SEL_WAIT_BO) flush_fd(fd);   // anything else may depend on the queued submits
        r = vgpu_ioctl(fd, sel, arg);
    }
    if (!r && sel == VGPU_SEL_CREATE_BO)
        bo_flags_set(fd, ((struct vgpu_create_bo *)arg)->handle,
                     (((struct vgpu_create_bo *)arg)->flags & VGPU_BO_WB_MMAP) ? BO_WB : 0, true);
    if (!r && sel == VGPU_SEL_GEM_CLOSE) bo_flags_set(fd, ((struct vgpu_gem_close *)arg)->handle, 0, true);
    if (sel == VGPU_SEL_GEM_CLOSE && !r) map_cache_drop(fd, ((struct vgpu_gem_close *)arg)->handle);
    if (trace_bo && !r && sel == VGPU_SEL_CREATE_BO) {
        struct vgpu_create_bo *c = arg;
        fprintf(stderr, "vgpu: bo %u 0x%llx-0x%llx flags %x\n", c->handle, (unsigned long long)c->offset,
                (unsigned long long)(c->offset + c->size), c->flags);
    }
    if (!r && sel == VGPU_SEL_MMAP_BO) {
        struct vgpu_mmap_bo *m = arg;
        pthread_mutex_lock(&g_bo_lock);
        BOInfo *b = bo_info(fd, m->handle, false);
        if (b) b->token = m->offset;
        pthread_mutex_unlock(&g_bo_lock);
    }
    if (!r && sel == VGPU_SEL_GEM_CLOSE) bo_forget(fd, ((struct vgpu_gem_close *)arg)->handle);
    return ret_errno(r);
}

drmVersionPtr drmGetVersion(int fd)
{
    struct vgpu_version v = {0};
    if (vgpu_ioctl(fd, VGPU_SEL_GET_VERSION, &v)) return NULL;
    drmVersionPtr d = calloc(1, sizeof *d);
    // Mesa's pan_kmod picks the backend by name: report the Panfrost DRM driver, version 1.5 (JM contexts, SYNC_BO).
    d->version_major = 1;
    d->version_minor = 5;
    d->version_patchlevel = 0;
    d->name = strdup("panfrost");
    d->name_len = (int)strlen(d->name);
    d->date = strdup("20261103");
    d->date_len = (int)strlen(d->date);
    d->desc = strdup(v.name);
    d->desc_len = (int)strlen(d->desc);
    return d;
}

void drmFreeVersion(drmVersionPtr v)
{
    if (!v) return;
    free(v->name); free(v->date); free(v->desc);
    free(v);
}

int drmCloseBufferHandle(int fd, uint32_t handle)
{
    struct vgpu_gem_close c = { .handle = handle };
    flush_fd(fd);
    int r = vgpu_ioctl(fd, VGPU_SEL_GEM_CLOSE, &c);
    if (!r) { map_cache_drop(fd, handle); bo_forget(fd, handle); bo_flags_set(fd, handle, 0, true); }
    return ret_errno(r);
}

// ---- BO mappings ----------------------------------------------------------------------------------------------------

// Mappings stay alive after drmUnmap until the BO is closed (map_cache_drop): Panfrost unmaps every BO it puts back
// in its cache and maps it again when it takes it out, and IOConnectMapMemory64/IOConnectUnmapMemory64 cost far more
// than mmap/munmap on Linux (a third of the GPU queue's time in CoreAnimation's frames went there).
typedef struct { void *addr; size_t size; int fd; void *base; size_t map_size; uint64_t token; bool idle; } Mapping;
static Mapping *g_maps;
static size_t g_map_count, g_map_cap;
static pthread_mutex_t g_map_lock = PTHREAD_MUTEX_INITIALIZER;

int drmMap(int fd, drm_handle_t handle, drmSize size, drmAddressPtr address)
{
    pthread_mutex_lock(&g_map_lock);
    for (size_t i = 0; i < g_map_count; i++) {
        Mapping *m = &g_maps[i];
        if (m->idle && m->fd == fd && m->token == (uint64_t)handle && m->size == size) {
            m->idle = false;
            *address = m->addr;
            pthread_mutex_unlock(&g_map_lock);
            return 0;
        }
    }
    pthread_mutex_unlock(&g_map_lock);
    uint32_t in_page = 0;
    pthread_mutex_lock(&g_bo_lock);
    for (unsigned i = 0; i < g_bo_count; i++)
        if (g_bo[i].fd == fd && g_bo[i].token == (uint64_t)handle) { in_page = g_bo[i].in_page; break; }
    pthread_mutex_unlock(&g_bo_lock);
    size_t map_size = size + in_page;
    void *p = vgpu_mmap(fd, (uint64_t)handle, map_size);
    if (!p) return -errno;
    pthread_mutex_lock(&g_map_lock);
    if (g_map_count == g_map_cap) { g_map_cap = g_map_cap ? g_map_cap * 2 : 256; g_maps = realloc(g_maps, g_map_cap * sizeof *g_maps); }
    g_maps[g_map_count++] = (Mapping){ (uint8_t *)p + in_page, size, fd, p, map_size, (uint64_t)handle, false };
    pthread_mutex_unlock(&g_map_lock);
    *address = (uint8_t *)p + in_page;
    return 0;
}

int drmUnmap(drmAddress address, drmSize size)
{
    pthread_mutex_lock(&g_map_lock);
    for (size_t i = 0; i < g_map_count; i++) {
        if (g_maps[i].addr != address || g_maps[i].idle) continue;
        g_maps[i].idle = true;   // unmapped for real when the BO is closed
        pthread_mutex_unlock(&g_map_lock);
        (void)size;
        return 0;
    }
    pthread_mutex_unlock(&g_map_lock);
    return -EINVAL;
}

// The BO behind (fd, handle) is closed: its kept mappings go.
static void map_cache_drop(int fd, uint32_t handle)
{
    pthread_mutex_lock(&g_map_lock);
    for (size_t i = 0; i < g_map_count;) {
        Mapping m = g_maps[i];
        if (m.fd != fd || m.token != handle) { i++; continue; }
        g_maps[i] = g_maps[--g_map_count];
        vgpu_munmap(m.fd, m.base, m.map_size);
    }
    pthread_mutex_unlock(&g_map_lock);
}

// ---- IOSurfaces as dma-bufs -----------------------------------------------------------------------------------------

// A surface fd is a real file descriptor (an unlinked sparse temporary file whose size is the surface's, because
// Mesa asks lseek(fd, 0, SEEK_END) for the buffer size) registered with its surface id and plane.
// A BO fd (vmg_drm_bo_fd) stands for a BO of this process (handle): importing it returns the same handle, so Panfrost
// finds its own BO and a texture can alias a buffer (linear textures over MTLBuffers).
typedef struct { int fd; uint32_t surface, plane; bool is_bo; uint32_t bo_handle; } SurfaceFd;
static SurfaceFd g_surf[256];
static pthread_mutex_t g_surf_lock = PTHREAD_MUTEX_INITIALIZER;

int vmg_drm_surface_fd(int device_fd, uint32_t surface_id, unsigned plane)
{
    (void)device_fd;
    IOSurfaceRef s = IOSurfaceLookup(surface_id);
    if (!s) return -1;
    size_t total = IOSurfaceGetAllocSize(s);
    size_t plane_off = IOSurfaceGetPlaneCount(s)
        ? (size_t)((uint8_t *)IOSurfaceGetBaseAddressOfPlane(s, plane) - (uint8_t *)IOSurfaceGetBaseAddress(s)) : 0;
    size_t size = total - plane_off;   // bytes from the plane's first byte to the end, as the kernel reports
    CFRelease(s);
    char path[] = "/tmp/vgpu-surface-XXXXXX";
    const char *tmp = getenv("TMPDIR");
    char buf[1024];
    int fd;
    if (tmp) { snprintf(buf, sizeof buf, "%s/vgpu-surface-XXXXXX", tmp); fd = mkstemp(buf); if (fd >= 0) unlink(buf); }
    else { fd = mkstemp(path); if (fd >= 0) unlink(path); }
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)size)) { close(fd); return -1; }
    pthread_mutex_lock(&g_surf_lock);
    for (unsigned i = 0; i < 256; i++) if (!g_surf[i].fd) { g_surf[i] = (SurfaceFd){ fd, surface_id, plane }; break; }
    pthread_mutex_unlock(&g_surf_lock);
    return fd;
}

int vmg_drm_bo_fd(int device_fd, uint32_t handle)
{
    (void)device_fd;
    // /dev/null: lseek gives size 0, so the fd can only import a BO Panfrost already has (its handle is known).
    int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    pthread_mutex_lock(&g_surf_lock);
    unsigned i = 0;
    for (; i < 256 && g_surf[i].fd; i++) {}
    if (i < 256) g_surf[i] = (SurfaceFd){ fd, 0, 0, true, handle };
    pthread_mutex_unlock(&g_surf_lock);
    if (i == 256) { close(fd); return -1; }
    return fd;
}

void vmg_drm_surface_fd_close(int fd)
{
    pthread_mutex_lock(&g_surf_lock);
    for (unsigned i = 0; i < 256; i++) if (g_surf[i].fd == fd) g_surf[i].fd = 0;
    pthread_mutex_unlock(&g_surf_lock);
    if (fd >= 0) close(fd);
}

int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle)
{
    SurfaceFd sf = {0};
    pthread_mutex_lock(&g_surf_lock);
    for (unsigned i = 0; i < 256; i++) if (g_surf[i].fd == prime_fd) sf = g_surf[i];
    pthread_mutex_unlock(&g_surf_lock);
    if (!sf.fd) { errno = EBADF; return -EBADF; }
    if (sf.is_bo) { *handle = sf.bo_handle; return 0; }
    pthread_mutex_lock(&g_bo_lock);
    for (unsigned i = 0; i < g_bo_count; i++)
        if (g_bo[i].fd == fd && g_bo[i].surface == sf.surface && g_bo[i].plane == sf.plane) {
            *handle = g_bo[i].handle;
            pthread_mutex_unlock(&g_bo_lock);
            return 0;
        }
    pthread_mutex_unlock(&g_bo_lock);
    struct vgpu_import_iosurface im = { .surface_id = sf.surface, .plane = sf.plane };
    flush_fd(fd);
    int r = vgpu_ioctl(fd, VGPU_SEL_IMPORT_IOSURFACE, &im);
    if (r) { errno = -r; return r; }
    bo_flags_set(fd, im.handle, BO_SHARED, true);   // other processes' jobs on the surface: WAIT_BO asks the kernel
    struct vgpu_version v = {0};
    uint32_t pg = vgpu_ioctl(fd, VGPU_SEL_GET_VERSION, &v) == 0 && v.page_size ? v.page_size : 16384;
    pthread_mutex_lock(&g_bo_lock);
    BOInfo *b = bo_info(fd, im.handle, true);
    if (b) { b->in_page = (uint32_t)(im.offset & (pg - 1)); b->surface = sf.surface; b->plane = sf.plane; }
    pthread_mutex_unlock(&g_bo_lock);
    static int trace_bo = -1;
    if (trace_bo < 0) trace_bo = getenv("VGPU_TRACE_BO") != NULL;
    if (trace_bo)
        fprintf(stderr, "vgpu: surface %u plane %u -> bo %u 0x%llx-0x%llx (%ux%u bpr %u)\n", sf.surface, sf.plane, im.handle,
                (unsigned long long)im.offset, (unsigned long long)(im.offset + im.size), im.width, im.height, im.bytes_per_row);
    *handle = im.handle;
    return 0;
}

int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd)
{
    // Exporting BOs as dma-bufs has no XNU equivalent here (sharing goes through IOSurfaces created by Metal).
    (void)fd; (void)handle; (void)flags; (void)prime_fd;
    errno = ENOSYS;
    return -ENOSYS;
}

// ---- Syncobjs -------------------------------------------------------------------------------------------------------

int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle)
{
    flush_fd(fd);
    struct vgpu_syncobj_create c = { .flags = flags };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_CREATE, &c);
    if (r) { errno = -r; return r; }
    *handle = c.handle;
    return 0;
}

int drmSyncobjDestroy(int fd, uint32_t handle)
{
    flush_fd(fd);
    struct vgpu_syncobj_destroy d = { .handle = handle };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_DESTROY, &d);
    if (r) errno = -r;
    return r;
}

int drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles, int64_t timeout_nsec, unsigned flags,
                   uint32_t *first_signaled)
{
    flush_fd(fd);
    struct vgpu_syncobj_wait w = { .handles = (uintptr_t)handles, .timeout_nsec = timeout_nsec, .count_handles = num_handles,
                                   .flags = flags };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_WAIT, &w);
    if (r) { errno = -r; return r; }
    if (first_signaled) *first_signaled = w.first_signaled;
    return 0;
}

int drmSyncobjReset(int fd, const uint32_t *handles, uint32_t handle_count)
{
    flush_fd(fd);
    struct vgpu_syncobj_array a = { .handles = (uintptr_t)handles, .count_handles = handle_count };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_RESET, &a);
    if (r) errno = -r;
    return r;
}

// Fence snapshots (drmSyncobjSnapshotXNU): Panfrost takes one per fenced flush (every Metal command buffer) and drops it
// at completion. Syncobjs come back to a small pool instead of SYNCOBJ_DESTROY + SYNCOBJ_CREATE; TRANSFER replaces the
// fence a pooled syncobj held, so its state does not matter.
typedef struct { int fd; uint32_t handle; } PooledSyncobj;
static PooledSyncobj g_sync_pool[32];
static unsigned g_sync_pool_count;
static pthread_mutex_t g_sync_pool_lock = PTHREAD_MUTEX_INITIALIZER;

int drmSyncobjSnapshotXNU(int fd, uint32_t src, uint32_t *handle)
{
    flush_fd(fd);
    uint32_t h = 0;
    pthread_mutex_lock(&g_sync_pool_lock);
    for (unsigned i = g_sync_pool_count; i-- > 0;)
        if (g_sync_pool[i].fd == fd) { h = g_sync_pool[i].handle; g_sync_pool[i] = g_sync_pool[--g_sync_pool_count]; break; }
    pthread_mutex_unlock(&g_sync_pool_lock);
    if (!h) {
        struct vgpu_syncobj_create c = {0};
        int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_CREATE, &c);
        if (r) { errno = -r; return r; }
        h = c.handle;
    }
    struct vgpu_syncobj_transfer t = { .src = src, .dst = h };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_TRANSFER, &t);
    if (r) {
        drmSyncobjDestroy(fd, h);   // not back in the pool: it may be stale (fd of a closed connection reused)
        errno = -r;
        return r;
    }
    *handle = h;
    return 0;
}

int drmSyncobjReleaseXNU(int fd, uint32_t handle)
{
    pthread_mutex_lock(&g_sync_pool_lock);
    if (g_sync_pool_count < 32) {
        g_sync_pool[g_sync_pool_count++] = (PooledSyncobj){ fd, handle };
        pthread_mutex_unlock(&g_sync_pool_lock);
        return 0;
    }
    pthread_mutex_unlock(&g_sync_pool_lock);
    return drmSyncobjDestroy(fd, handle);
}

int drmSurfacePromiseXNU(int fd, const uint32_t *surface_ids, uint32_t count, uint32_t timeout_ms, uint32_t *handle)
{
    FdState *st = fd_state(fd);
    if (!st || st->minor < 2) { errno = ENOTSUP; return -ENOTSUP; }
    if (!count || count > 16) { errno = EINVAL; return -EINVAL; }
    uint32_t h = 0;
    pthread_mutex_lock(&g_sync_pool_lock);
    for (unsigned i = g_sync_pool_count; i-- > 0;)
        if (g_sync_pool[i].fd == fd) { h = g_sync_pool[i].handle; g_sync_pool[i] = g_sync_pool[--g_sync_pool_count]; break; }
    pthread_mutex_unlock(&g_sync_pool_lock);
    int r = 0;
    if (!h) {
        struct vgpu_syncobj_create c = {0};
        if ((r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_CREATE, &c))) { errno = -r; return r; }
        h = c.handle;
    }
    struct vgpu_surface_promise p = { (uintptr_t)surface_ids, count, h, timeout_ms, 0 };
    if ((r = vgpu_ioctl(fd, VGPU_SEL_SURFACE_PROMISE, &p))) {
        drmSyncobjDestroy(fd, h);
        errno = -r;
        return r;
    }
    *handle = h;
    return 0;
}

int drmSyncobjCopyXNU(int fd, uint32_t dst, uint32_t src)
{
    flush_fd(fd);   // src's fence must be the one of the submits made so far
    struct vgpu_syncobj_transfer t = { .src = src, .dst = dst };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_TRANSFER, &t);
    if (r) errno = -r;
    return r;
}

// Sync files (Linux fences as fds) do not exist on XNU. Panfrost uses them only to snapshot a syncobj's current fence
// (pan_fence.c: export from the context syncobj, import into a fresh one). An exported "sync file" is a /dev/null fd
// registered with a temporary syncobj holding the snapshot; importing transfers it and destroys the temporary.
typedef struct { int fd, dev; uint32_t syncobj; } SyncFile;
static SyncFile g_sync[64];
static pthread_mutex_t g_sync_lock = PTHREAD_MUTEX_INITIALIZER;

int drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd)
{
    flush_fd(fd);
    struct vgpu_syncobj_create c = {0};
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_CREATE, &c);
    if (r) { errno = -r; return r; }
    struct vgpu_syncobj_transfer t = { .src = handle, .dst = c.handle };
    r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_TRANSFER, &t);
    int sf = r ? -1 : open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (sf < 0) {
        struct vgpu_syncobj_destroy d = { .handle = c.handle };
        vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_DESTROY, &d);
        errno = r ? -r : EMFILE;
        return -errno;
    }
    pthread_mutex_lock(&g_sync_lock);
    unsigned slot = 0;
    for (; slot < 64 && g_sync[slot].fd; slot++) {}
    if (slot == 64) {
        // Table full: an exported fence was never imported (panfrost_fence_get_fd); reclaim the oldest entry.
        struct vgpu_syncobj_destroy d = { .handle = g_sync[0].syncobj };
        vgpu_ioctl(g_sync[0].dev, VGPU_SEL_SYNCOBJ_DESTROY, &d);
        slot = 0;
    }
    g_sync[slot] = (SyncFile){ sf, fd, c.handle };
    pthread_mutex_unlock(&g_sync_lock);
    *sync_file_fd = sf;
    return 0;
}

int drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd)
{
    flush_fd(fd);
    SyncFile f = {0};
    pthread_mutex_lock(&g_sync_lock);
    for (unsigned i = 0; i < 64; i++)
        if (g_sync[i].fd == sync_file_fd) { f = g_sync[i]; g_sync[i] = (SyncFile){0}; break; }
    pthread_mutex_unlock(&g_sync_lock);
    if (!f.fd) { errno = EINVAL; return -EINVAL; }
    struct vgpu_syncobj_transfer t = { .src = f.syncobj, .dst = handle };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_TRANSFER, &t);
    struct vgpu_syncobj_destroy d = { .handle = f.syncobj };
    vgpu_ioctl(f.dev, VGPU_SEL_SYNCOBJ_DESTROY, &d);
    if (r) errno = -r;
    return r;
}

int drmSyncobjFDToHandle(int fd, int obj_fd, uint32_t *handle)
{ (void)fd; (void)obj_fd; (void)handle; errno = ENOSYS; return -ENOSYS; }
// Timeline syncobjs: CSF (panthor) only; the Mali-G57 is a job-manager GPU.
int drmSyncobjTimelineWait(int fd, uint32_t *handles, uint64_t *points, unsigned num_handles, int64_t timeout_nsec,
                           unsigned flags, uint32_t *first_signaled)
{ (void)fd; (void)handles; (void)points; (void)num_handles; (void)timeout_nsec; (void)flags; (void)first_signaled; errno = ENOSYS; return -ENOSYS; }
int drmSyncobjTransfer(int fd, uint32_t dst_handle, uint64_t dst_point, uint32_t src_handle, uint64_t src_point, uint32_t flags)
{ (void)fd; (void)dst_handle; (void)dst_point; (void)src_handle; (void)src_point; (void)flags; errno = ENOSYS; return -ENOSYS; }
