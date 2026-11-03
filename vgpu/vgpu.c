// Viva GPU userspace client: fd table and dispatch to the back-end (see vgpu.h).
#include "vgpu.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <TargetConditionals.h>

static const uint32_t selector_size[VGPU_SEL_COUNT] = {
    [VGPU_SEL_GET_VERSION] = sizeof(struct vgpu_version),
    [VGPU_SEL_GET_PARAM] = sizeof(struct vgpu_get_param),
    [VGPU_SEL_CREATE_BO] = sizeof(struct vgpu_create_bo),
    [VGPU_SEL_MMAP_BO] = sizeof(struct vgpu_mmap_bo),
    [VGPU_SEL_GET_BO_OFFSET] = sizeof(struct vgpu_get_bo_offset),
    [VGPU_SEL_GEM_CLOSE] = sizeof(struct vgpu_gem_close),
    [VGPU_SEL_SUBMIT] = sizeof(struct vgpu_submit),
    [VGPU_SEL_WAIT_BO] = sizeof(struct vgpu_wait_bo),
    [VGPU_SEL_MADVISE] = sizeof(struct vgpu_madvise),
    [VGPU_SEL_SYNCOBJ_CREATE] = sizeof(struct vgpu_syncobj_create),
    [VGPU_SEL_SYNCOBJ_DESTROY] = sizeof(struct vgpu_syncobj_destroy),
    [VGPU_SEL_SYNCOBJ_WAIT] = sizeof(struct vgpu_syncobj_wait),
    [VGPU_SEL_SYNCOBJ_RESET] = sizeof(struct vgpu_syncobj_array),
    [VGPU_SEL_SYNCOBJ_SIGNAL] = sizeof(struct vgpu_syncobj_array),
    [VGPU_SEL_IMPORT_IOSURFACE] = sizeof(struct vgpu_import_iosurface),
    [VGPU_SEL_SYNC_BO] = sizeof(struct vgpu_sync_bo),
    [VGPU_SEL_QUERY_BO_INFO] = sizeof(struct vgpu_query_bo_info),
    [VGPU_SEL_JM_CTX_CREATE] = sizeof(struct vgpu_jm_ctx),
    [VGPU_SEL_JM_CTX_DESTROY] = sizeof(struct vgpu_jm_ctx),
    [VGPU_SEL_SYNCOBJ_TRANSFER] = sizeof(struct vgpu_syncobj_transfer),
};

#define MAX_FDS 1024
static void *g_conn[MAX_FDS];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static const struct vgpu_backend *g_backend;

static const struct vgpu_backend *backend(void)
{
    pthread_mutex_lock(&g_lock);
    if (!g_backend) {
        const char *env = getenv("VGPU_BACKEND");
#if TARGET_OS_IPHONE || defined(VGPU_DEFAULT_IOKIT)
        g_backend = &vgpu_backend_iokit;
#else
        g_backend = &vgpu_backend_mock;
#endif
        if (env && !strcmp(env, "iokit")) g_backend = &vgpu_backend_iokit;
        if (env && !strcmp(env, "mock")) g_backend = &vgpu_backend_mock;
    }
    pthread_mutex_unlock(&g_lock);
    return g_backend;
}

const char *vgpu_backend_name(void) { return backend()->name; }

int vgpu_open(void)
{
    const struct vgpu_backend *be = backend();
    void *conn = NULL;
    int err = be->open(&conn);
    if (err) return err;
    int fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (fd < 0 || fd >= MAX_FDS) {
        int e = fd < 0 ? errno : EMFILE;
        if (fd >= 0) close(fd);
        be->close(conn);
        return -e;
    }
    pthread_mutex_lock(&g_lock);
    g_conn[fd] = conn;
    pthread_mutex_unlock(&g_lock);
    return fd;
}

static void *lookup(int fd)
{
    if (fd < 0 || fd >= MAX_FDS) return NULL;
    pthread_mutex_lock(&g_lock);
    void *c = g_conn[fd];
    pthread_mutex_unlock(&g_lock);
    return c;
}

bool vgpu_is_fd(int fd) { return lookup(fd) != NULL; }

int vgpu_close(int fd)
{
    void *conn = lookup(fd);
    if (!conn) return -EBADF;
    pthread_mutex_lock(&g_lock);
    g_conn[fd] = NULL;
    pthread_mutex_unlock(&g_lock);
    backend()->close(conn);
    close(fd);
    return 0;
}

int vgpu_ioctl(int fd, enum vgpu_selector sel, void *arg)
{
    void *conn = lookup(fd);
    if (!conn) return -EBADF;
    if ((unsigned)sel >= VGPU_SEL_COUNT || !arg) return -EINVAL;
    return backend()->ioctl(conn, sel, arg, selector_size[sel]);
}

void *vgpu_mmap(int fd, uint64_t token, size_t size)
{
    void *conn = lookup(fd);
    if (!conn) { errno = EBADF; return NULL; }
    return backend()->mmap(conn, token, size);
}

int vgpu_munmap(int fd, void *addr, size_t size)
{
    void *conn = lookup(fd);
    if (!conn) return -EBADF;
    return backend()->munmap(conn, addr, size);
}
