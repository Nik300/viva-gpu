// Viva GPU: the real kernel driver through IOKit (VGPU_BACKEND=iokit, default on iOS). See uapi/viva_gpu_uapi.h.
#include "vgpu.h"
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include "iokit_compat.h"

typedef struct {
    io_connect_t conn;
    pthread_mutex_t lock;
    // CPU mappings: IOConnectUnmapMemory64 needs the memory type (= BO handle) back.
    struct { mach_vm_address_t addr; uint32_t type; } *maps;
    size_t mapCount, mapCap;
} IOKitConn;

static int errno_for(kern_return_t kr)
{
    switch (kr) {
    case kIOReturnSuccess: return 0;
    case kIOReturnNoMemory: case kIOReturnNoResources: return -ENOMEM;
    case kIOReturnBadArgument: return -EINVAL;
    case kIOReturnNotPrivileged: case kIOReturnNotPermitted: return -EPERM;
    case kIOReturnNotFound: case kIOReturnNoDevice: return -ENOENT;
    case kIOReturnTimeout: return -ETIME;
    case kIOReturnBusy: return -EBUSY;
    case kIOReturnUnsupported: return -ENOTSUP;
    case kIOReturnAborted: return -EINTR;
    case kIOReturnIOError: return -EIO;
    default: return -EIO;
    }
}

static int iokit_open(void **out)
{
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(VGPU_SERVICE_CLASS));
    if (!svc) return -ENODEV;
    io_connect_t conn = MACH_PORT_NULL;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), VGPU_CLIENT_TYPE, &conn);
    IOObjectRelease(svc);
    if (kr != kIOReturnSuccess) return errno_for(kr);
    IOKitConn *c = calloc(1, sizeof *c);
    c->conn = conn;
    pthread_mutex_init(&c->lock, NULL);
    struct vgpu_version v = {0};
    size_t sz = sizeof v;
    kr = IOConnectCallStructMethod(conn, VGPU_SEL_GET_VERSION, &v, sizeof v, &v, &sz);
    if (kr != kIOReturnSuccess || v.major != VGPU_UAPI_MAJOR) {
        IOServiceClose(conn);
        free(c);
        return kr != kIOReturnSuccess ? errno_for(kr) : -EPROTO;
    }
    *out = c;
    return 0;
}

static void iokit_close(void *conn)
{
    IOKitConn *c = conn;
    IOServiceClose(c->conn);
    free(c->maps);
    free(c);
}

static int iokit_ioctl(void *conn, enum vgpu_selector sel, void *arg, size_t size)
{
    IOKitConn *c = conn;
    size_t out = size;
    return errno_for(IOConnectCallStructMethod(c->conn, sel, arg, size, arg, &out));
}

static void *iokit_mmap(void *conn, uint64_t token, size_t size)
{
    IOKitConn *c = conn;
    mach_vm_address_t addr = 0;
    mach_vm_size_t len = size;
    kern_return_t kr = IOConnectMapMemory64(c->conn, (uint32_t)token, mach_task_self(), &addr, &len, kIOMapAnywhere);
    if (kr != kIOReturnSuccess) { errno = -errno_for(kr); return NULL; }
    pthread_mutex_lock(&c->lock);
    if (c->mapCount == c->mapCap) {
        c->mapCap = c->mapCap ? c->mapCap * 2 : 64;
        c->maps = realloc(c->maps, c->mapCap * sizeof *c->maps);
    }
    c->maps[c->mapCount].addr = addr;
    c->maps[c->mapCount].type = (uint32_t)token;
    c->mapCount++;
    pthread_mutex_unlock(&c->lock);
    return (void *)(uintptr_t)addr;
}

static int iokit_munmap(void *conn, void *p, size_t size)
{
    IOKitConn *c = conn;
    (void)size;
    mach_vm_address_t addr = (mach_vm_address_t)(uintptr_t)p;
    pthread_mutex_lock(&c->lock);
    for (size_t i = 0; i < c->mapCount; i++) {
        if (c->maps[i].addr != addr) continue;
        uint32_t type = c->maps[i].type;
        c->maps[i] = c->maps[--c->mapCount];
        pthread_mutex_unlock(&c->lock);
        return errno_for(IOConnectUnmapMemory64(c->conn, type, mach_task_self(), addr));
    }
    pthread_mutex_unlock(&c->lock);
    return -EINVAL;
}

const struct vgpu_backend vgpu_backend_iokit = { "iokit", iokit_open, iokit_close, iokit_ioctl, iokit_mmap, iokit_munmap };
