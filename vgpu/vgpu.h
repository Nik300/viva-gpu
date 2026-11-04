// Viva GPU userspace client: the only code that talks to the kernel driver (uapi/viva_gpu_uapi.h).
// Used by libdrm-xnu (Mesa's Panfrost) and directly by tests.
//
// A connection is addressed by a file descriptor so that Mesa, which passes a DRM fd around, needs no changes:
// vgpu_open() returns a real fd (of /dev/null, so the number is unique and close() is harmless) registered in a
// table; vgpu_ioctl()/vgpu_mmap() on it go to the connection.
//
// Back-ends (VGPU_BACKEND, read once):
//   iokit  - VivaGPUAccelerator through IOKit (default on iOS)
//   mock   - kernel simulated in-process (default on macOS): BOs are anonymous memory with GPU VA = CPU address,
//            submits complete at once without running anything (VGPU_MOCK_TRACE=1 logs them). It exercises
//            all of Mesa's Panfrost up to the job chains, for tests on the Mac.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "../uapi/viva_gpu_uapi.h"

#ifdef __cplusplus
extern "C" {
#endif

// Opens a connection; returns an fd >= 0 or -errno.
int vgpu_open(void);
// Closes the connection behind fd (and the fd).
int vgpu_close(int fd);
// Whether fd was returned by vgpu_open and is still open.
bool vgpu_is_fd(int fd);
// One selector of viva_gpu_uapi.h; arg points to its structure (sizeof checked). Returns 0 or -errno.
int vgpu_ioctl(int fd, enum vgpu_selector sel, void *arg);
// Running totals (any thread; relaxed): kernel calls per selector, and job chains submitted (SUBMIT + batched ones).
void vgpu_counters(uint64_t calls[VGPU_SEL_COUNT], uint64_t *jobs);
// Maps a BO: token = vgpu_mmap_bo.offset. Returns the CPU address or NULL (errno set).
void *vgpu_mmap(int fd, uint64_t token, size_t size);
int vgpu_munmap(int fd, void *addr, size_t size);
// "iokit" or "mock".
const char *vgpu_backend_name(void);

// Back-end table (vgpu_iokit.c, vgpu_mock.c).
struct vgpu_backend {
    const char *name;
    int (*open)(void **conn);
    void (*close)(void *conn);
    int (*ioctl)(void *conn, enum vgpu_selector sel, void *arg, size_t size);
    void *(*mmap)(void *conn, uint64_t token, size_t size);
    int (*munmap)(void *conn, void *addr, size_t size);
};
extern const struct vgpu_backend vgpu_backend_iokit;
extern const struct vgpu_backend vgpu_backend_mock;

// Mock only: called after each submit with the chain's GPU VA (GPU VA = CPU address), e.g. to decode it with
// Mesa's pandecode. NULL = none.
typedef void (*vgpu_mock_submit_hook)(const struct vgpu_submit *submit, void *ctx);
void vgpu_mock_set_submit_hook(vgpu_mock_submit_hook hook, void *ctx);

#ifdef __cplusplus
}
#endif
