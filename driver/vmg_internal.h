// Viva Metal - Gallium back-end internals shared by the vmg_*.c files (never included by Objective-C).
#pragma once
#include "vmg.h"
#include <pthread.h>
#include "pipe/p_context.h"
#include "pipe/p_defines.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "util/format/u_formats.h"

struct nir_shader;
struct nir_shader_compiler_options;
struct util_dynarray;

// Constant buffer 0 of every stage: per-draw system values (layout in vmg_air.c); constant buffer 1: the shader's pool.
#define VMG_SYSVAL_HEADER 192
// Then the push window: the bytes of small constant buffers (vmg_reflection.push_slots), copied in at each draw.
#define VMG_PUSH_WINDOW 256

struct vmg_resource {
    struct pipe_resource *res;
    struct pipe_transfer *transfer;   // persistent map of a buffer (contents)
    void *map;
    size_t size;
    // Buffer textures over this buffer (vmg_texture_sync) copy in again only after something may have changed it:
    // the GPU (every command that may write it bumps gpu_writes) or the CPU. A newBufferWithBytesNoCopy buffer the
    // driver could not alias (user_copy: the bytes were copied into the BO at creation) changes on the CPU only
    // through -contents (cpu_access); every other buffer is hashed.
    uint64_t gpu_writes;
    bool user_copy;
    volatile bool cpu_access;
    void *user_ptr;                   // user_copy: the client's memory (cached; the BO mapping is write-combined)
    // user_copy buffers: the copied textures over them, shared by every texture over the same region with the same
    // layout. CoreAnimation makes new texture objects over the same image buffers (the wallpaper, ~10 MB, when the
    // home screen comes back): each started with its own full copy-in.
    struct vmg_buffer_copy *copies;
};

struct vmg_buffer_copy {
    struct vmg_buffer_copy *next;
    size_t offset, bpr;
    struct pipe_resource *res;        // owned reference
    uint64_t gen;                     // buffer->gpu_writes at its last copy-in
    bool filled;
};

struct vmg_texture {
    struct pipe_resource *res;        // owned reference
    struct vmg_texture *parent;       // views keep their parent alive
    enum pipe_format format;          // view format
    enum pipe_texture_target target;  // view target
    unsigned first_level, last_level, first_layer, last_layer;
    uint8_t swizzle[4];               // PIPE_SWIZZLE_*
    struct pipe_sampler_view *view;   // created on first sampling (GPU queue)
    vmg_texture_desc desc;
    unsigned mtl_format;
    // IOSurface textures the driver cannot alias (llvmpipe with another stride): copied in before use and out after
    // writes, on the GPU queue.
    uint32_t surface_id; unsigned plane;
    bool surface_copy;
    void *surface;                    // IOSurfaceRef of a copied surface texture (retained: a lookup is a kernel call)
    uint32_t surface_seed;            // seed after the last copy (CPU writers bump it at unlock): unchanged = no copy-in
    bool surface_seed_valid;
    // Linear textures over a buffer the driver cannot alias (Panfrost: no user memory): same, from/to the buffer.
    vmg_resource *buffer; size_t buffer_offset, buffer_bpr;
    uint64_t buffer_hash;             // XXH3 of the buffer bytes at the last copy-in: unchanged = no copy-in
    uint64_t buffer_gen;              // buffer->gpu_writes at the last copy-in (user_copy buffers: no hashing)
    struct vmg_buffer_copy *bcopy;    // user_copy buffers: the shared copy this texture samples (else NULL)
    bool buffer_hash_valid;
    uint64_t copy_epoch;              // dev->copy_epoch at the last copy (see vmg_texture_sync)
    bool copy_out_pending;            // the GPU wrote it this command buffer; copied out at the flush (vmg_flush)
};

// Copied textures (surface_copy): IOSurface/buffer -> texture (to_texture) or back.
void vmg_texture_sync(vmg_device *dev, vmg_texture *t, bool to_texture);
// After the GPU wrote a copied texture: copy-out now (buffers) or at the flush (surfaces, vmg_flush).
void vmg_texture_written(vmg_device *dev, vmg_texture *t);
// A texture going away: its pending copy-out is made now.
void vmg_texture_forget(vmg_device *dev, vmg_texture *t);

struct vmg_sampler { void *cso; struct pipe_sampler_state state; };
struct vmg_dsa { void *cso; };

struct vmg_shader {
    enum vmg_stage stage;
    void *cso;                        // driver shader (vs/fs/compute state)
    vmg_reflection refl;
    struct pipe_resource *pool_buffer; // constant buffer 1 (NULL when the shader has no constant tables)
    uint8_t *pool; size_t pool_size;
    struct vmg_sampler *constexpr_samplers[16];
    char name[64];                    // entry point (traces)
    // Fragment shaders writing several colours keep their NIR: a pipeline without an attachment for one of them gets a
    // variant without that output (Metal drops the write; Panfrost would read a blend descriptor past its table).
    struct nir_shader *nir_keep; uint32_t colors_written;
    // Direct AIR -> Valhall ISA path (VMG_ISA=1, driver/isa): the compiled program behind the CSO, and a copy of the
    // input for fragment variants (outputs without an attachment dropped, B7).
    struct vmg_isa_program *isa;
    struct vmg_isa_input *isa_in;
};

struct vmg_render_pipeline {
    vmg_render_pipeline_desc desc;
    void *blend, *velems;
    void *fs_variant;                 // fragment shader without the outputs that have no attachment (NULL: the shader's)
    struct vmg_isa_program *fs_variant_isa;   // its program on the ISA path
    unsigned velem_buffer[VMG_MAX_VERTEX_ATTRIBS];   // Metal buffer slot of each Gallium vertex buffer
    unsigned velem_buffers;
    uint32_t velem_strides[VMG_MAX_VERTEX_ATTRIBS];
};

struct vmg_compute_pipeline { vmg_shader *kernel; };

struct vmg_fence { struct pipe_fence_handle *fence; };

// Encoder state on the GPU queue (vmg_exec.c).
struct vmg_stage_bindings {
    struct pipe_shader_buffer buffers[VMG_MAX_BUFFERS];
    vmg_resource *res[VMG_MAX_BUFFERS];   // the buffers bound there (push window copies, write tracking)
    uint32_t strides[VMG_MAX_BUFFERS];
    vmg_texture *textures[VMG_MAX_TEXTURES];
    vmg_sampler *samplers[VMG_MAX_SAMPLERS];
    uint32_t dirty_buffers, dirty_textures, dirty_samplers;
};

struct vmg_device {
    struct pipe_screen *screen;
    struct pipe_context *pipe;
    struct sw_winsys *winsys;         // llvmpipe
    int fd;                           // panfrost: vgpu connection
    vmg_device_info info;
    bool panfrost;

    // GPU queue state
    struct vmg_stage_bindings stage[VMG_STAGES];
    uint32_t sysvals[VMG_STAGES][(VMG_SYSVAL_HEADER + VMG_PUSH_WINDOW) / 4];   // constant buffer 0 (drivers read user buffers at draw time)
    vmg_render_pipeline *pipeline;
    struct pipe_framebuffer_state fb;
    vmg_pass_desc pass;
    bool in_pass;
    // VMG_TRACE_CB: fragment shaders drawn by the current command buffer (printed at the flush when the set changes)
    const char *cb_fs[24]; unsigned cb_fs_count, cb_draws; char cb_last[512];
    uint64_t copy_epoch;               // bumped by every vmg_flush and every copy-out of a copied texture
    vmg_cb_stats stats;                // VMG_TRACE_FRAME (vmg_stats_take)
    vmg_texture **copy_out; unsigned copy_out_count, copy_out_cap;   // surface textures written, copied out at the flush
    struct pipe_rasterizer_state raster;
    void *raster_cso; bool raster_dirty;
    struct hash_table *raster_cache;  // pipe_rasterizer_state -> cso
    vmg_dsa *dsa;
    struct pipe_stencil_ref stencil_ref;
    struct pipe_viewport_state viewport;
    struct pipe_scissor_state scissor; bool scissor_set;
    struct pipe_query *occlusion; uint8_t visibility_mode; size_t visibility_offset;
    void *sampler_default;            // for unbound sampler slots
    void *dsa_default;                // Metal's default: no depth/stencil test
    void *fs_empty;                   // depth-only pipelines (no fragment function)
    void *velems_empty, *blend_default;   // neutral state bound between passes, so released pipelines' objects
                                          // are never left bound (u_blitter saves and restores bound state)
    struct pipe_sampler_view *null_view;
};

// vmg_air.c
struct nir_shader *vmg_air_translate(const struct nir_shader_compiler_options *options, const vmg_air_input *in,
                                     vmg_reflection *refl, struct util_dynarray *pool, char **error);
char **vmg_air_vertex_outputs_uncached(const void *bitcode, size_t size, unsigned *count, char **error);
// vmg_formats.c
enum pipe_format vmg_pipe_format(unsigned mtl_format);
enum pipe_format vmg_vertex_format(unsigned mtl_vertex_format);
bool vmg_format_is_depth(unsigned mtl_format), vmg_format_is_stencil(unsigned mtl_format);
bool vmg_format_is_integer(unsigned mtl_format), vmg_format_is_signed_integer(unsigned mtl_format);

// vmg_drm.c: an fd standing for an IOSurface plane, that libdrm-xnu's drmPrimeFDToHandle imports through
// VGPU_SEL_IMPORT_IOSURFACE (so Panfrost's resource_from_handle needs no change).
int vmg_drm_surface_fd(int device_fd, uint32_t surface_id, unsigned plane);
void vmg_drm_surface_fd_close(int fd);
// An fd standing for one of this process's BOs (GEM handle): Panfrost's import of it finds the BO it already has.
// Closed with vmg_drm_surface_fd_close.
int vmg_drm_bo_fd(int device_fd, uint32_t handle);
// libdrm-xnu (xf86drm.h, not included here).
int drmSurfacePromiseXNU(int fd, const uint32_t *surface_ids, uint32_t count, uint32_t timeout_ms, uint32_t *handle);
int drmSyncobjCopyXNU(int fd, uint32_t dst, uint32_t src);
int drmSyncobjReleaseXNU(int fd, uint32_t handle);
int drmSyncobjDestroy(int fd, uint32_t handle);

char *vmg_strdup_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
