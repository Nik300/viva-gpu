// Viva GPU: interface between the XNU driver (VivaGPUAccelerator, fork/xnu/patches/01xx-viva-gpu-*) and userspace
// (vgpu/, used by Mesa's Panfrost through libdrm-xnu and by the Metal driver). Shared by C (userspace) and C++ (kernel).
//
// Model: the semantics of Linux's DRM_PANFROST_* ioctls and DRM syncobjs, so Mesa's Panfrost needs no logic changes.
// Every structure keeps the layout of its drm_panfrost_* / drm_syncobj_* counterpart (natural alignment, u64 user
// pointers); the kernel reads the arrays they point to from the calling task (copyin). Plus IOSurface import.
//
// Transport: IOServiceOpen(type VGPU_CLIENT_TYPE) on the service of class VGPU_SERVICE_CLASS, then
// IOConnectCallStructMethod(selector, &args, sizeof args, &args, &size): the structure goes in and comes back
// updated (output fields filled). A BO is mapped with IOConnectMapMemory64(conn, memoryType = BO handle, ...).
// Errors: the kernel returns kIOReturn*; vgpu translates them to -errno.
//
// Fast path (minor >= 1): IOConnectTrap2(conn, VGPU_TRAP_CALL, selector, &args) does the same as the struct method
// (the kernel reads the structure from the caller with copyin and writes it back with copyout) without a Mach
// message. vgpu uses it for every selector when the kernel offers it.
#pragma once
#include <stdint.h>

#define VGPU_SERVICE_CLASS   "VivaGPUAccelerator"   // subclass of IOAcceleratorES (Metal matches that class)
#define VGPU_CLIENT_TYPE     0x76677075u           // 'vgpu'
#define VGPU_UAPI_MAJOR      1
#define VGPU_UAPI_MINOR      2
#define VGPU_TRAP_CALL       0                     // IOConnectTrap2 index (minor >= 1)
#define VGPU_MAP_COMPLETION  0x10000u              // IOConnectMapMemory64 type: struct vgpu_completion (minor >= 2)

// GPU virtual addresses: Mesa's Panfrost (panfrost_kmod) assumes the Linux driver's range, [32 MiB, 4 GiB) per
// connection, with VA management in the kernel. Every offset the kernel returns lies in it.
#define VGPU_VA_START 0x2000000ull
#define VGPU_VA_END   (1ull << 32)

enum vgpu_selector {
    VGPU_SEL_GET_VERSION = 0,       // struct vgpu_version
    VGPU_SEL_GET_PARAM,             // struct vgpu_get_param            (drm_panfrost_get_param)
    VGPU_SEL_CREATE_BO,             // struct vgpu_create_bo            (drm_panfrost_create_bo)
    VGPU_SEL_MMAP_BO,               // struct vgpu_mmap_bo              (drm_panfrost_mmap_bo: offset = BO handle)
    VGPU_SEL_GET_BO_OFFSET,         // struct vgpu_get_bo_offset        (drm_panfrost_get_bo_offset)
    VGPU_SEL_GEM_CLOSE,             // struct vgpu_gem_close            (drm_gem_close)
    VGPU_SEL_SUBMIT,                // struct vgpu_submit               (drm_panfrost_submit)
    VGPU_SEL_WAIT_BO,               // struct vgpu_wait_bo              (drm_panfrost_wait_bo)
    VGPU_SEL_MADVISE,               // struct vgpu_madvise              (drm_panfrost_madvise)
    VGPU_SEL_SYNCOBJ_CREATE,        // struct vgpu_syncobj_create       (drm_syncobj_create)
    VGPU_SEL_SYNCOBJ_DESTROY,       // struct vgpu_syncobj_destroy      (drm_syncobj_destroy)
    VGPU_SEL_SYNCOBJ_WAIT,          // struct vgpu_syncobj_wait         (drm_syncobj_wait)
    VGPU_SEL_SYNCOBJ_RESET,         // struct vgpu_syncobj_array        (drm_syncobj_array)
    VGPU_SEL_SYNCOBJ_SIGNAL,        // struct vgpu_syncobj_array        (drm_syncobj_array)
    VGPU_SEL_IMPORT_IOSURFACE,      // struct vgpu_import_iosurface     (Viva only)
    VGPU_SEL_SYNC_BO,               // struct vgpu_sync_bo              (drm_panfrost_sync_bo: CPU cache maintenance)
    VGPU_SEL_QUERY_BO_INFO,         // struct vgpu_query_bo_info        (drm_panfrost_query_bo_info)
    VGPU_SEL_JM_CTX_CREATE,         // struct vgpu_jm_ctx               (drm_panfrost_jm_ctx_create; one context only)
    VGPU_SEL_JM_CTX_DESTROY,        // struct vgpu_jm_ctx               (drm_panfrost_jm_ctx_destroy)
    VGPU_SEL_SYNCOBJ_TRANSFER,      // struct vgpu_syncobj_transfer     (Viva: dst takes src's current fence; stands in
                                    //  for sync-file export/import, which XNU lacks)
    VGPU_SEL_IMPORT_USERPTR,        // struct vgpu_import_userptr       (Viva: newBufferWithBytesNoCopy; pages wired)
    VGPU_SEL_SUBMIT_BATCH,          // struct vgpu_submit_batch         (Viva, minor >= 2: N SUBMITs in one call)
    VGPU_SEL_SURFACE_PROMISE,       // struct vgpu_surface_promise      (Viva, minor >= 2: K0i)
    VGPU_SEL_COUNT
};

struct vgpu_version {
    uint32_t major, minor;          // out: VGPU_UAPI_MAJOR / MINOR of the kernel
    uint32_t gpu_id;                // out: GPU_ID register (product id << 16 | revision)
    uint32_t page_size;             // out: CPU page size used for BOs (16384 on XNU arm64)
    char name[32];                  // out: "Mali-G57 MC2"
};

// Parameters: the values of DRM_PANFROST_PARAM_* (panfrost_drm.h), so libdrm-xnu passes them through unchanged.
enum vgpu_param {
    VGPU_PARAM_GPU_PROD_ID = 0, VGPU_PARAM_GPU_REVISION, VGPU_PARAM_SHADER_PRESENT, VGPU_PARAM_TILER_PRESENT,
    VGPU_PARAM_L2_PRESENT, VGPU_PARAM_STACK_PRESENT, VGPU_PARAM_AS_PRESENT, VGPU_PARAM_JS_PRESENT,
    VGPU_PARAM_L2_FEATURES, VGPU_PARAM_CORE_FEATURES, VGPU_PARAM_TILER_FEATURES, VGPU_PARAM_MEM_FEATURES,
    VGPU_PARAM_MMU_FEATURES, VGPU_PARAM_THREAD_FEATURES, VGPU_PARAM_MAX_THREADS, VGPU_PARAM_THREAD_MAX_WORKGROUP_SZ,
    VGPU_PARAM_THREAD_MAX_BARRIER_SZ, VGPU_PARAM_COHERENCY_FEATURES,
    VGPU_PARAM_TEXTURE_FEATURES0, VGPU_PARAM_TEXTURE_FEATURES1, VGPU_PARAM_TEXTURE_FEATURES2,
    VGPU_PARAM_TEXTURE_FEATURES3,
    VGPU_PARAM_JS_FEATURES0, /* ... */ VGPU_PARAM_JS_FEATURES15 = VGPU_PARAM_JS_FEATURES0 + 15,
    VGPU_PARAM_NR_CORE_GROUPS, VGPU_PARAM_THREAD_TLS_ALLOC, VGPU_PARAM_AFBC_FEATURES,
    VGPU_PARAM_SYSTEM_TIMESTAMP, VGPU_PARAM_SYSTEM_TIMESTAMP_FREQUENCY,
    VGPU_PARAM_ALLOWED_JM_CTX_PRIORITIES, VGPU_PARAM_SELECTED_COHERENCY,
};
// VGPU_PARAM_SELECTED_COHERENCY values (drm_panfrost_gpu_coherency): MT6781 is expected to be NONE (to be measured).
#define VGPU_COHERENCY_ACE_LITE 0
#define VGPU_COHERENCY_ACE      1
#define VGPU_COHERENCY_NONE     31
struct vgpu_get_param { uint32_t param, pad; uint64_t value; };

// BO flags (DRM_PANFROST_BO_*).
#define VGPU_BO_NOEXEC   (1u << 0)
#define VGPU_BO_HEAP     (1u << 1)   // grows on GPU fault (tiler heap)
#define VGPU_BO_WB_MMAP  (1u << 2)   // CPU mapping write-back cached (patch 0100 maps every BO cacheable and
                                     // cleans/invalidates the CPU caches around each job itself)
struct vgpu_create_bo { uint32_t size, flags, handle, pad; uint64_t offset; };   // out: handle, offset = GPU VA (VGPU_VA_*)
struct vgpu_mmap_bo { uint32_t handle, flags; uint64_t offset; };                // out: offset = memoryType token
struct vgpu_get_bo_offset { uint32_t handle, pad; uint64_t offset; };
struct vgpu_gem_close { uint32_t handle, pad; };

// Job requirements (PANFROST_JD_REQ_*).
#define VGPU_JD_REQ_FS          (1u << 0)   // fragment job chain: JS0; else vertex/tiler/compute: JS1
#define VGPU_JD_REQ_CYCLE_COUNT (1u << 1)
struct vgpu_submit {
    uint64_t jc;                    // GPU VA of the first job descriptor
    uint64_t in_syncs;              // user pointer: uint32_t[in_sync_count] syncobj handles to wait on
    uint32_t in_sync_count;
    uint32_t out_sync;              // syncobj signalled when the chain completes (0 = none)
    uint64_t bo_handles;            // user pointer: uint32_t[bo_handle_count] BOs the chain uses (kept alive)
    uint32_t bo_handle_count;
    uint32_t requirements;
    uint32_t jm_ctx_handle;         // unused (single context per client)
    uint32_t seq;                   // out (minor >= 2, was pad): the job's number in the connection, see vgpu_completion
};

// N submits in one call (K0h), handled in order exactly as N SUBMIT calls (same implicit dependencies), under one
// gate acquisition. Stops at the first failing one: `done` = how many were queued, the call returns that one's error.
// Each element's `seq` is written back. count <= 64, stride = sizeof(struct vgpu_submit).
struct vgpu_submit_batch { uint64_t submits; uint32_t count, stride; uint32_t done, pad; };

// Completion page (K0h), one per connection, mapped read-only with IOConnectMapMemory64(type VGPU_MAP_COMPLETION):
// every job of the connection with seq <= completed has finished (successfully or not), as its out_sync would say.
// Jobs end out of order across slots: this is a watermark. Compare wrap-safe: (int32_t)(completed - seq) >= 0.
// It does not cover other processes' jobs on a shared IOSurface (WAIT_BO does).
struct vgpu_completion {
    uint32_t completed, submitted;  // low 32 bits
    uint64_t completed64, submitted64;
};

// K0i: a fence for IOSurfaces whose jobs are not submitted yet. The kernel puts a new unsignalled fence into
// `syncobj` and makes it the surfaces' last GPU fence: IOSurfaceLock, the display (K0c), WAIT_BO on the surface and
// other processes' jobs wait for it. This connection's own jobs on those surfaces do not (they wait for what came
// before). It is resolved when the syncobj's fence is replaced: SYNCOBJ_TRANSFER into it or a SUBMIT with it as
// out_sync = it signals with that fence; RESET/SIGNAL/DESTROY = at once. Unresolved after timeout_ms (0 = 1000,
// max 5000) it signals with an error. count <= 16.
struct vgpu_surface_promise { uint64_t surface_ids; uint32_t count, syncobj; uint32_t timeout_ms, pad; };
struct vgpu_wait_bo { uint32_t handle, pad; int64_t timeout_ns; };              // absolute, CLOCK_MONOTONIC
#define VGPU_MADV_WILLNEED 0
#define VGPU_MADV_DONTNEED 1
struct vgpu_madvise { uint32_t handle, madv, retained; };                       // out: retained

#define VGPU_SYNCOBJ_CREATE_SIGNALED   (1u << 0)
#define VGPU_SYNCOBJ_WAIT_ALL          (1u << 0)
#define VGPU_SYNCOBJ_WAIT_FOR_SUBMIT   (1u << 1)
struct vgpu_syncobj_create { uint32_t handle, flags; };
struct vgpu_syncobj_destroy { uint32_t handle, pad; };
struct vgpu_syncobj_wait {
    uint64_t handles;               // user pointer: uint32_t[count_handles]
    int64_t timeout_nsec;           // absolute, CLOCK_MONOTONIC
    uint32_t count_handles, flags;
    uint32_t first_signaled, pad;   // out
    uint64_t deadline_nsec;
};
struct vgpu_syncobj_array { uint64_t handles; uint32_t count_handles, pad; };

// Imports an IOSurface plane as a BO: same pages (no copy), mapped at a GPU VA, linear layout. The surface stays
// alive until the BO is closed. The BO starts at the page holding the plane's first byte: the GPU offset (here and
// in GET_BO_OFFSET) is the plane's first byte, while the CPU mapping (MMAP_BO + IOConnectMapMemory64) starts at the
// page, so the plane is at mapping + (offset & (page_size - 1)) (libdrm-xnu adds it in drmMap).
struct vgpu_import_iosurface {
    uint32_t surface_id, plane;     // in: IOSurfaceGetID, plane index
    uint32_t handle, pad;           // out
    uint64_t offset;                // out: GPU VA of the plane's first byte
    uint64_t size;                  // out: bytes from the plane's first byte to the end of the surface
    uint32_t bytes_per_row;         // out
    uint32_t pixel_format;          // out: IOSurface pixel format (fourcc)
    uint32_t width, height;         // out: plane size in pixels
};

#define VGPU_SYNC_CPU_CACHE_FLUSH            0
#define VGPU_SYNC_CPU_CACHE_FLUSH_INVALIDATE 1
struct vgpu_bo_sync_op { uint32_t handle, type, offset, size; };
struct vgpu_sync_bo { uint64_t ops; uint32_t op_count, pad; };   // ops: user pointer to vgpu_bo_sync_op[op_count]
#define VGPU_BO_IS_IMPORTED (1u << 0)
struct vgpu_query_bo_info { uint32_t handle, extra_flags, create_flags, pad; };
struct vgpu_jm_ctx { uint32_t handle, priority; };   // create: in priority (ignored), out handle (always 1)
struct vgpu_syncobj_transfer { uint32_t src, dst; };
// Wires the calling task's pages [addr, addr + size) (page aligned) and maps them at a GPU VA as a BO.
struct vgpu_import_userptr { uint64_t addr, size; uint32_t handle, pad; uint64_t offset; };   // out: handle, offset

#ifdef __cplusplus
// Kernel: argument sizes indexed by selector, checked before dispatch.
static const uint32_t vgpu_selector_size[VGPU_SEL_COUNT] = {
    sizeof(struct vgpu_version), sizeof(struct vgpu_get_param), sizeof(struct vgpu_create_bo),
    sizeof(struct vgpu_mmap_bo), sizeof(struct vgpu_get_bo_offset), sizeof(struct vgpu_gem_close),
    sizeof(struct vgpu_submit), sizeof(struct vgpu_wait_bo), sizeof(struct vgpu_madvise),
    sizeof(struct vgpu_syncobj_create), sizeof(struct vgpu_syncobj_destroy), sizeof(struct vgpu_syncobj_wait),
    sizeof(struct vgpu_syncobj_array), sizeof(struct vgpu_syncobj_array), sizeof(struct vgpu_import_iosurface),
    sizeof(struct vgpu_sync_bo), sizeof(struct vgpu_query_bo_info), sizeof(struct vgpu_jm_ctx), sizeof(struct vgpu_jm_ctx),
    sizeof(struct vgpu_syncobj_transfer), sizeof(struct vgpu_import_userptr), sizeof(struct vgpu_submit_batch),
    sizeof(struct vgpu_surface_promise),
};
#endif
