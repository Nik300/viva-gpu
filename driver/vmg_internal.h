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

struct vmg_resource {
    struct pipe_resource *res;
    struct pipe_transfer *transfer;   // persistent map of a buffer (contents)
    void *map;
    size_t size;
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
};

struct vmg_sampler { void *cso; struct pipe_sampler_state state; };
struct vmg_dsa { void *cso; };

struct vmg_shader {
    enum vmg_stage stage;
    void *cso;                        // driver shader (vs/fs/compute state)
    vmg_reflection refl;
    struct pipe_resource *pool_buffer; // constant buffer 1 (NULL when the shader has no constant tables)
    uint8_t *pool; size_t pool_size;
    struct vmg_sampler *constexpr_samplers[16];
};

struct vmg_render_pipeline {
    vmg_render_pipeline_desc desc;
    void *blend, *velems;
    unsigned velem_buffer[VMG_MAX_VERTEX_ATTRIBS];   // Metal buffer slot of each Gallium vertex buffer
    unsigned velem_buffers;
    uint32_t velem_strides[VMG_MAX_VERTEX_ATTRIBS];
};

struct vmg_compute_pipeline { vmg_shader *kernel; };

struct vmg_fence { struct pipe_fence_handle *fence; };

// Encoder state on the GPU queue (vmg_exec.c).
struct vmg_stage_bindings {
    struct pipe_shader_buffer buffers[VMG_MAX_BUFFERS];
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
    uint32_t sysvals[VMG_STAGES][VMG_SYSVAL_HEADER / 4];   // constant buffer 0 (drivers read user buffers at draw time)
    vmg_render_pipeline *pipeline;
    struct pipe_framebuffer_state fb;
    vmg_pass_desc pass;
    bool in_pass;
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
// vmg_formats.c
enum pipe_format vmg_pipe_format(unsigned mtl_format);
enum pipe_format vmg_vertex_format(unsigned mtl_vertex_format);
bool vmg_format_is_depth(unsigned mtl_format), vmg_format_is_stencil(unsigned mtl_format);
bool vmg_format_is_integer(unsigned mtl_format), vmg_format_is_signed_integer(unsigned mtl_format);

// vmg_drm.c: an fd standing for an IOSurface plane, that libdrm-xnu's drmPrimeFDToHandle imports through
// VGPU_SEL_IMPORT_IOSURFACE (so Panfrost's resource_from_handle needs no change).
int vmg_drm_surface_fd(int device_fd, uint32_t surface_id, unsigned plane);
void vmg_drm_surface_fd_close(int fd);

char *vmg_strdup_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
