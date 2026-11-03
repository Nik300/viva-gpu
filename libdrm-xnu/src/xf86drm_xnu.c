// libdrm for XNU: the libdrm entry points Mesa's Panfrost uses (SYMBOLS.txt), implemented on the Viva GPU client
// (vgpu/, uapi/viva_gpu_uapi.h). The DRM fd is a vgpu fd; DRM_IOCTL_PANFROST_* and the syncobj ioctls become vgpu
// selectors with the same structures. A "dma-buf fd" is an IOSurface plane (vmg_drm_surface_fd): importing it maps
// the surface's pages into the GPU (VGPU_SEL_IMPORT_IOSURFACE). Anything else returns -ENOSYS.
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
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
    return ret_errno(vgpu_ioctl(fd, sel, arg));
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
    return ret_errno(vgpu_ioctl(fd, VGPU_SEL_GEM_CLOSE, &c));
}

// ---- BO mappings ----------------------------------------------------------------------------------------------------

typedef struct { void *addr; size_t size; int fd; } Mapping;
static Mapping *g_maps;
static size_t g_map_count, g_map_cap;
static pthread_mutex_t g_map_lock = PTHREAD_MUTEX_INITIALIZER;

int drmMap(int fd, drm_handle_t handle, drmSize size, drmAddressPtr address)
{
    void *p = vgpu_mmap(fd, (uint64_t)handle, size);
    if (!p) return -errno;
    pthread_mutex_lock(&g_map_lock);
    if (g_map_count == g_map_cap) { g_map_cap = g_map_cap ? g_map_cap * 2 : 256; g_maps = realloc(g_maps, g_map_cap * sizeof *g_maps); }
    g_maps[g_map_count++] = (Mapping){ p, size, fd };
    pthread_mutex_unlock(&g_map_lock);
    *address = p;
    return 0;
}

int drmUnmap(drmAddress address, drmSize size)
{
    pthread_mutex_lock(&g_map_lock);
    for (size_t i = 0; i < g_map_count; i++) {
        if (g_maps[i].addr != address) continue;
        int fd = g_maps[i].fd;
        g_maps[i] = g_maps[--g_map_count];
        pthread_mutex_unlock(&g_map_lock);
        return vgpu_munmap(fd, address, size);
    }
    pthread_mutex_unlock(&g_map_lock);
    return -EINVAL;
}

// ---- IOSurfaces as dma-bufs -----------------------------------------------------------------------------------------

// A surface fd is a real file descriptor (an unlinked sparse temporary file whose size is the surface's, because
// Mesa asks lseek(fd, 0, SEEK_END) for the buffer size) registered with its surface id and plane.
typedef struct { int fd; uint32_t surface, plane; } SurfaceFd;
static SurfaceFd g_surf[256];
static pthread_mutex_t g_surf_lock = PTHREAD_MUTEX_INITIALIZER;

int vmg_drm_surface_fd(int device_fd, uint32_t surface_id, unsigned plane)
{
    (void)device_fd;
    IOSurfaceRef s = IOSurfaceLookup(surface_id);
    if (!s) return -1;
    size_t size = IOSurfaceGetAllocSize(s);
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
    struct vgpu_import_iosurface im = { .surface_id = sf.surface, .plane = sf.plane };
    int r = vgpu_ioctl(fd, VGPU_SEL_IMPORT_IOSURFACE, &im);
    if (r) { errno = -r; return r; }
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
    struct vgpu_syncobj_create c = { .flags = flags };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_CREATE, &c);
    if (r) { errno = -r; return r; }
    *handle = c.handle;
    return 0;
}

int drmSyncobjDestroy(int fd, uint32_t handle)
{
    struct vgpu_syncobj_destroy d = { .handle = handle };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_DESTROY, &d);
    if (r) errno = -r;
    return r;
}

int drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles, int64_t timeout_nsec, unsigned flags,
                   uint32_t *first_signaled)
{
    struct vgpu_syncobj_wait w = { .handles = (uintptr_t)handles, .timeout_nsec = timeout_nsec, .count_handles = num_handles,
                                   .flags = flags };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_WAIT, &w);
    if (r) { errno = -r; return r; }
    if (first_signaled) *first_signaled = w.first_signaled;
    return 0;
}

int drmSyncobjReset(int fd, const uint32_t *handles, uint32_t handle_count)
{
    struct vgpu_syncobj_array a = { .handles = (uintptr_t)handles, .count_handles = handle_count };
    int r = vgpu_ioctl(fd, VGPU_SEL_SYNCOBJ_RESET, &a);
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
