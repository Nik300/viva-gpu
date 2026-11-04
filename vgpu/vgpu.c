// Viva GPU userspace client: fd table and dispatch to the back-end (see vgpu.h).
#include "vgpu.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
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
    [VGPU_SEL_IMPORT_USERPTR] = sizeof(struct vgpu_import_userptr),
    [VGPU_SEL_SUBMIT_BATCH] = sizeof(struct vgpu_submit_batch),
    [VGPU_SEL_SURFACE_PROMISE] = sizeof(struct vgpu_surface_promise),
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

// VGPU_STATS=1: kernel calls per selector, and the time spent in them, printed at exit.
static _Atomic uint64_t g_stat_calls[VGPU_SEL_COUNT], g_stat_ns[VGPU_SEL_COUNT];
static const char *const g_stat_names[VGPU_SEL_COUNT] = {
    [VGPU_SEL_GET_VERSION] = "GET_VERSION", [VGPU_SEL_GET_PARAM] = "GET_PARAM", [VGPU_SEL_CREATE_BO] = "CREATE_BO",
    [VGPU_SEL_MMAP_BO] = "MMAP_BO", [VGPU_SEL_GET_BO_OFFSET] = "GET_BO_OFFSET", [VGPU_SEL_GEM_CLOSE] = "GEM_CLOSE",
    [VGPU_SEL_SUBMIT] = "SUBMIT", [VGPU_SEL_WAIT_BO] = "WAIT_BO", [VGPU_SEL_MADVISE] = "MADVISE",
    [VGPU_SEL_SYNCOBJ_CREATE] = "SYNCOBJ_CREATE", [VGPU_SEL_SYNCOBJ_DESTROY] = "SYNCOBJ_DESTROY",
    [VGPU_SEL_SYNCOBJ_WAIT] = "SYNCOBJ_WAIT", [VGPU_SEL_SYNCOBJ_RESET] = "SYNCOBJ_RESET",
    [VGPU_SEL_SYNCOBJ_SIGNAL] = "SYNCOBJ_SIGNAL", [VGPU_SEL_IMPORT_IOSURFACE] = "IMPORT_IOSURFACE",
    [VGPU_SEL_SYNC_BO] = "SYNC_BO", [VGPU_SEL_QUERY_BO_INFO] = "QUERY_BO_INFO", [VGPU_SEL_JM_CTX_CREATE] = "JM_CTX_CREATE",
    [VGPU_SEL_JM_CTX_DESTROY] = "JM_CTX_DESTROY", [VGPU_SEL_SYNCOBJ_TRANSFER] = "SYNCOBJ_TRANSFER",
    [VGPU_SEL_IMPORT_USERPTR] = "IMPORT_USERPTR", [VGPU_SEL_SUBMIT_BATCH] = "SUBMIT_BATCH",
    [VGPU_SEL_SURFACE_PROMISE] = "SURFACE_PROMISE",
};
static int g_stats = -1;
static _Atomic uint64_t g_cnt[VGPU_SEL_COUNT], g_jobs;   // always counted (VMG_TRACE_FRAME)

void vgpu_counters(uint64_t calls[VGPU_SEL_COUNT], uint64_t *jobs)
{
    for (unsigned i = 0; i < VGPU_SEL_COUNT; i++) calls[i] = atomic_load_explicit(&g_cnt[i], memory_order_relaxed);
    *jobs = atomic_load_explicit(&g_jobs, memory_order_relaxed);
}

static void print_stats(void)
{
    fprintf(stderr, "vgpu stats (calls, total ms, us per call):\n");
    for (unsigned i = 0; i < VGPU_SEL_COUNT; i++) {
        uint64_t n = g_stat_calls[i], ns = g_stat_ns[i];
        if (n) fprintf(stderr, "  %-17s %8llu %9.1f %7.1f\n", g_stat_names[i] ? g_stat_names[i] : "?", (unsigned long long)n,
                       ns / 1e6, ns / 1e3 / n);
    }
}

int vgpu_ioctl(int fd, enum vgpu_selector sel, void *arg)
{
    void *conn = lookup(fd);
    if (!conn) return -EBADF;
    if ((unsigned)sel >= VGPU_SEL_COUNT || !arg) return -EINVAL;
    if (g_stats < 0) {
        g_stats = getenv("VGPU_STATS") != NULL;
        if (g_stats) atexit(print_stats);
    }
    atomic_fetch_add_explicit(&g_cnt[sel], 1, memory_order_relaxed);
    if (sel == VGPU_SEL_SUBMIT) atomic_fetch_add_explicit(&g_jobs, 1, memory_order_relaxed);
    else if (sel == VGPU_SEL_SUBMIT_BATCH)
        atomic_fetch_add_explicit(&g_jobs, ((struct vgpu_submit_batch *)arg)->count, memory_order_relaxed);
    if (!g_stats) return backend()->ioctl(conn, sel, arg, selector_size[sel]);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int r = backend()->ioctl(conn, sel, arg, selector_size[sel]);
    g_stat_ns[sel] += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    g_stat_calls[sel]++;
    return r;
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
