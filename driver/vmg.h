// Viva Metal - Gallium back-end: the C interface between the Metal driver (Objective-C, VM*.m) and Mesa
// (Gallium + NIR, vmg_*.c). Mesa headers stay out of the Objective-C side.
//
// Threading: resource and state-object creation may happen on any thread (the screen is thread safe); everything
// that takes a vmg_device and records or executes GPU work (vmg_cmd_*, maps, fences) runs on the device's GPU
// queue only (the pipe_context is not thread safe).
//
// Conventions (Metal): framebuffer row 0 on top, NDC y up, depth 0..1. The viewport maps NDC to window coordinates
// with a negative y scale, so no shader flips anything.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vmg_device vmg_device;
typedef struct vmg_resource vmg_resource;
typedef struct vmg_texture vmg_texture;          // a resource plus view parameters (MTLTexture, including views)
typedef struct vmg_sampler vmg_sampler;
typedef struct vmg_dsa vmg_dsa;
typedef struct vmg_shader vmg_shader;
typedef struct vmg_render_pipeline vmg_render_pipeline;
typedef struct vmg_compute_pipeline vmg_compute_pipeline;
typedef struct vmg_fence vmg_fence;
typedef struct vmg_query vmg_query;

enum vmg_stage { VMG_VERTEX = 0, VMG_FRAGMENT = 1, VMG_COMPUTE = 2, VMG_STAGES };
enum { VMG_MAX_BUFFERS = 31, VMG_MAX_TEXTURES = 32, VMG_MAX_SAMPLERS = 16, VMG_MAX_COLOR = 8,
       VMG_MAX_VERTEX_ATTRIBS = 31, VMG_CONSTEXPR_SAMPLER_BASE = 16 };   // constexpr samplers: slots 16..31

// ---- Device -------------------------------------------------------------------------------------------------------
typedef struct {
    char name[64];                 // "Mali-G57 MC2", "llvmpipe (LLVM 23.1, 128 bits)"
    char driver[16];               // "panfrost", "llvmpipe"
    uint32_t max_texture_2d, max_texture_3d, max_texture_cube, max_texture_layers;
    uint32_t max_samples;          // highest supported MSAA count (power of two)
    uint32_t max_threads_per_group, max_shared_memory, subgroup_size;
    uint64_t video_memory;         // bytes the GPU may use (shared RAM on both)
    bool unified_memory;
} vmg_device_info;

// which: "panfrost", "llvmpipe" or NULL (VMG_DRIVER, else panfrost on iOS and llvmpipe on macOS).
vmg_device *vmg_device_create(const char *which, char *error, size_t error_size);
void vmg_device_destroy(vmg_device *dev);
const vmg_device_info *vmg_device_get_info(vmg_device *dev);
// MTLPixelFormat support (VMFormats.m fills the table at start): renderable / filterable / supported at all.
bool vmg_format_supported(vmg_device *dev, unsigned mtl_format, bool render_target, bool sampler);

// ---- Resources ----------------------------------------------------------------------------------------------------
// Buffers: always CPU-visible; *contents receives a persistent, coherent mapping (Metal's -contents). With
// user_memory (newBufferWithBytesNoCopy) the buffer aliases that memory where the driver can (else NULL).
vmg_resource *vmg_buffer_create(vmg_device *dev, size_t size, void *user_memory, void **contents);
void vmg_resource_release(vmg_device *dev, vmg_resource *res);

enum vmg_texture_type { VMG_TEX_1D, VMG_TEX_1D_ARRAY, VMG_TEX_2D, VMG_TEX_2D_ARRAY, VMG_TEX_2D_MS,
                        VMG_TEX_2D_MS_ARRAY, VMG_TEX_CUBE, VMG_TEX_CUBE_ARRAY, VMG_TEX_3D, VMG_TEX_BUFFER };
typedef struct {
    enum vmg_texture_type type;
    unsigned mtl_format;           // MTLPixelFormat
    uint32_t width, height, depth, array_length, mip_levels, samples;
    bool render_target, shader_write, memoryless;
} vmg_texture_desc;

vmg_texture *vmg_texture_create(vmg_device *dev, const vmg_texture_desc *desc);
// Texture over an IOSurface plane (linear, no copy where the driver can alias it). surface_id = IOSurfaceGetID.
vmg_texture *vmg_texture_create_iosurface(vmg_device *dev, const vmg_texture_desc *desc, uint32_t surface_id, unsigned plane);
// Linear texture over a buffer (newTextureWithDescriptor:offset:bytesPerRow:).
vmg_texture *vmg_texture_create_buffer(vmg_device *dev, const vmg_texture_desc *desc, vmg_resource *buffer,
                                       size_t offset, size_t bytes_per_row);
// View of `parent` (newTextureViewWithPixelFormat:textureType:levels:slices:[swizzle:]). swizzle: 4 x MTLTextureSwizzle.
vmg_texture *vmg_texture_create_view(vmg_device *dev, vmg_texture *parent, unsigned mtl_format, enum vmg_texture_type type,
                                     uint32_t first_level, uint32_t levels, uint32_t first_slice, uint32_t slices,
                                     const uint8_t swizzle[4]);
void vmg_texture_release(vmg_device *dev, vmg_texture *tex);
// The texture is a copy of its IOSurface/buffer (the driver could not alias it): copied in and out by the CPU.
bool vmg_texture_is_copied(vmg_texture *tex);
// GPU queue. Region in texels of `level`; slice = array layer / cube face / 3D z for 2D regions (depth = 1).
void vmg_texture_write(vmg_device *dev, vmg_texture *tex, unsigned level, unsigned slice, uint32_t x, uint32_t y,
                       uint32_t z, uint32_t w, uint32_t h, uint32_t d, const void *data, size_t row_pitch, size_t image_pitch);
void vmg_texture_read(vmg_device *dev, vmg_texture *tex, unsigned level, unsigned slice, uint32_t x, uint32_t y,
                      uint32_t z, uint32_t w, uint32_t h, uint32_t d, void *data, size_t row_pitch, size_t image_pitch);

// ---- State objects (immutable, any thread) ------------------------------------------------------------------------
typedef struct {
    uint8_t min_filter, mag_filter, mip_filter;   // MTLSamplerMinMagFilter / MTLSamplerMipFilter
    uint8_t address[3];                           // MTLSamplerAddressMode s, t, r
    uint8_t max_anisotropy, compare;              // compare: MTLCompareFunction (Never = off)
    uint8_t border;                               // MTLSamplerBorderColor
    bool normalized, lod_average;
    float lod_min, lod_max;
} vmg_sampler_desc;
vmg_sampler *vmg_sampler_create(vmg_device *dev, const vmg_sampler_desc *desc);
// Same from a 64-bit constexpr sampler word of MSL (state layout documented in vmg_air.c).
vmg_sampler *vmg_sampler_create_constexpr(vmg_device *dev, uint64_t word);
void vmg_sampler_release(vmg_device *dev, vmg_sampler *s);

typedef struct { uint8_t func, fail, depth_fail, pass; uint32_t read_mask, write_mask; } vmg_stencil_face;
typedef struct {
    uint8_t depth_func;                           // MTLCompareFunction (Always + no write = depth off)
    bool depth_write, stencil;
    vmg_stencil_face front, back;
} vmg_dsa_desc;
vmg_dsa *vmg_dsa_create(vmg_device *dev, const vmg_dsa_desc *desc);
void vmg_dsa_release(vmg_device *dev, vmg_dsa *dsa);

// ---- Shaders and pipelines ----------------------------------------------------------------------------------------
// Reflection of a translated function (vmg_air.c), used by the encoders to bind only what the shader reads.
typedef struct {
    enum vmg_stage stage;
    uint32_t buffers_used;                        // bit n = [[buffer(n)]]
    uint32_t buffers_written;
    uint32_t textures_used;                       // bit n = [[texture(n)]]
    uint32_t textures_written;                    // compute/fragment writes (shader images)
    uint32_t samplers_used;                       // bit n = [[sampler(n)]]
    uint32_t constexpr_samplers;                  // count, at VMG_CONSTEXPR_SAMPLER_BASE + i
    uint64_t constexpr_words[16];
    uint32_t vertex_inputs;                       // bit n = [[attribute(n)]]
    uint32_t color_outputs, color_inputs;         // render targets written / read (programmable blending)
    bool writes_depth, writes_sample_mask, discards, reads_sample_id;
    uint32_t threadgroup[3];                      // compute: fixed size if known (0 = from the dispatch)
    uint32_t static_shared;                       // compute: threadgroup memory declared in the shader
    uint32_t dynamic_shared_slots;                // compute: bit n = [[threadgroup(n)]] sized by the encoder
} vmg_reflection;

// Translation input: AIR bitcode of one function (+ linked visible functions), varying slot assignment shared by
// the vertex and fragment functions of one pipeline.
typedef struct {
    const void *bitcode; size_t bitcode_size;
    const void *const *linked; const size_t *linked_size; const char *const *linked_names; unsigned linked_count;
    const char *const *varyings; unsigned varying_count;   // keys in slot order: VARYING_SLOT_VAR0 + i
    const uint32_t *color_formats;                          // fragment: MTLPixelFormat per render target (int/uint outputs)
    bool half32;                                            // set by vmg: the driver has no fp16 (half as 32-bit float)
} vmg_air_input;

// AIR -> NIR -> driver shader. NULL with *error set when the function cannot be translated.
vmg_shader *vmg_shader_create(vmg_device *dev, const vmg_air_input *in, vmg_reflection *refl, char **error);
void vmg_shader_release(vmg_device *dev, vmg_shader *sh);
// Varying keys a vertex function writes (to build the pipeline's slot table). Free with free(); NULL on error.
char **vmg_air_vertex_outputs(const void *bitcode, size_t size, unsigned *count, char **error);
// Translation tag (cache keys) and a dump of the NIR of a function (tools).
const char *vmg_air_tag(void);
char *vmg_air_to_nir_text(vmg_device *dev, const vmg_air_input *in, char **error);

typedef struct {
    uint8_t format;                               // MTLVertexFormat
    uint8_t buffer;                               // [[buffer(n)]] slot of the vertex stage
    uint32_t offset;
} vmg_vertex_attrib;
typedef struct {
    uint32_t stride, step_rate; uint8_t step_function;   // MTLVertexStepFunction
} vmg_vertex_layout;
typedef struct {
    bool enabled; uint8_t write_mask;             // MTLColorWriteMask
    uint8_t rgb_op, alpha_op, src_rgb, dst_rgb, src_alpha, dst_alpha;   // MTLBlendOperation / MTLBlendFactor
    uint32_t format;                              // MTLPixelFormat (0 = none)
} vmg_color_attachment;
typedef struct {
    vmg_shader *vertex, *fragment;                // fragment may be NULL (depth-only)
    uint32_t attrib_mask;
    vmg_vertex_attrib attribs[VMG_MAX_VERTEX_ATTRIBS];
    vmg_vertex_layout layouts[VMG_MAX_BUFFERS];
    vmg_color_attachment color[VMG_MAX_COLOR];
    uint32_t depth_format, stencil_format;
    uint32_t samples;
    bool alpha_to_coverage, alpha_to_one, rasterization_enabled;
    uint8_t topology_class;                       // MTLPrimitiveTopologyClass
} vmg_render_pipeline_desc;
vmg_render_pipeline *vmg_render_pipeline_create(vmg_device *dev, const vmg_render_pipeline_desc *desc, char **error);
void vmg_render_pipeline_release(vmg_device *dev, vmg_render_pipeline *p);
vmg_compute_pipeline *vmg_compute_pipeline_create(vmg_device *dev, vmg_shader *kernel, char **error);
void vmg_compute_pipeline_release(vmg_device *dev, vmg_compute_pipeline *p);
// threadExecutionWidth / maxTotalThreadsPerThreadgroup of a compute pipeline.
void vmg_compute_pipeline_limits(vmg_device *dev, vmg_compute_pipeline *p, uint32_t *simd_width, uint32_t *max_threads);

// ---- Command execution (GPU queue) --------------------------------------------------------------------------------
enum vmg_load { VMG_LOAD_DONTCARE, VMG_LOAD_LOAD, VMG_LOAD_CLEAR };
enum vmg_store { VMG_STORE_DONTCARE, VMG_STORE_STORE, VMG_STORE_RESOLVE, VMG_STORE_STORE_RESOLVE };
typedef struct {
    vmg_texture *texture; unsigned level, slice, depth_plane;
    vmg_texture *resolve; unsigned resolve_level, resolve_slice, resolve_depth_plane;
    enum vmg_load load; enum vmg_store store;
    double clear[4];                              // color (float / int / uint by format), or clear[0] = depth
    uint32_t clear_stencil;
} vmg_attachment;
typedef struct {
    vmg_attachment color[VMG_MAX_COLOR];
    vmg_attachment depth, stencil;
    uint32_t width, height, layers, samples;      // framebuffer size when there is no attachment
    vmg_resource *visibility;                     // visibility result buffer (or NULL)
} vmg_pass_desc;

void vmg_cmd_begin_pass(vmg_device *dev, const vmg_pass_desc *pass);
void vmg_cmd_end_pass(vmg_device *dev);
void vmg_cmd_set_render_pipeline(vmg_device *dev, vmg_render_pipeline *p);
typedef struct { double x, y, w, h, znear, zfar; } vmg_viewport;
void vmg_cmd_set_viewport(vmg_device *dev, const vmg_viewport *vp);
void vmg_cmd_set_scissor(vmg_device *dev, uint32_t x, uint32_t y, uint32_t w, uint32_t h);
// MTLCullMode, MTLWinding, MTLTriangleFillMode, MTLDepthClipMode.
void vmg_cmd_set_raster(vmg_device *dev, uint8_t cull, uint8_t winding, uint8_t fill, uint8_t depth_clip);
void vmg_cmd_set_depth_bias(vmg_device *dev, float bias, float slope, float clamp);
void vmg_cmd_set_dsa(vmg_device *dev, vmg_dsa *dsa);
void vmg_cmd_set_stencil_ref(vmg_device *dev, uint32_t front, uint32_t back);
void vmg_cmd_set_blend_color(vmg_device *dev, const float rgba[4]);
void vmg_cmd_set_visibility(vmg_device *dev, uint8_t mode, size_t offset);   // MTLVisibilityResultMode
void vmg_cmd_set_buffer(vmg_device *dev, enum vmg_stage stage, unsigned slot, vmg_resource *buf, size_t offset, size_t stride);
// setVertexBufferOffset & co: same buffer, new offset.
void vmg_cmd_set_buffer_offset(vmg_device *dev, enum vmg_stage stage, unsigned slot, size_t offset);
void vmg_cmd_set_texture(vmg_device *dev, enum vmg_stage stage, unsigned slot, vmg_texture *tex);
void vmg_cmd_set_sampler(vmg_device *dev, enum vmg_stage stage, unsigned slot, vmg_sampler *s, float lod_min, float lod_max);

typedef struct {
    uint8_t primitive;                            // MTLPrimitiveType
    uint32_t start, count, instance_count, base_instance;
    // Indexed draws:
    vmg_resource *index_buffer; size_t index_offset; uint8_t index_size; int32_t base_vertex;
    // Indirect draws (count/instances read from this buffer by the GPU):
    vmg_resource *indirect; size_t indirect_offset;
} vmg_draw_info;
void vmg_cmd_draw(vmg_device *dev, const vmg_draw_info *draw);

typedef struct {
    vmg_compute_pipeline *pipeline;
    uint32_t groups[3], threads[3];               // threadgroups per grid, threads per threadgroup
    uint32_t grid[3];                             // dispatchThreads: exact grid (0 = whole groups)
    vmg_resource *indirect; size_t indirect_offset;
    uint32_t shared_sizes[8];                     // setThreadgroupMemoryLength:atIndex:
} vmg_dispatch_info;
void vmg_cmd_dispatch(vmg_device *dev, const vmg_dispatch_info *d);

void vmg_cmd_copy_buffer(vmg_device *dev, vmg_resource *src, size_t src_off, vmg_resource *dst, size_t dst_off, size_t size);
void vmg_cmd_fill_buffer(vmg_device *dev, vmg_resource *dst, size_t off, size_t size, uint8_t value);
void vmg_cmd_copy_texture(vmg_device *dev, vmg_texture *src, unsigned src_slice, unsigned src_level, uint32_t sx, uint32_t sy,
                          uint32_t sz, uint32_t w, uint32_t h, uint32_t d, vmg_texture *dst, unsigned dst_slice,
                          unsigned dst_level, uint32_t dx, uint32_t dy, uint32_t dz);
void vmg_cmd_copy_buffer_to_texture(vmg_device *dev, vmg_resource *src, size_t off, size_t row_pitch, size_t image_pitch,
                                    vmg_texture *dst, unsigned slice, unsigned level, uint32_t x, uint32_t y, uint32_t z,
                                    uint32_t w, uint32_t h, uint32_t d);
void vmg_cmd_copy_texture_to_buffer(vmg_device *dev, vmg_texture *src, unsigned slice, unsigned level, uint32_t x,
                                    uint32_t y, uint32_t z, uint32_t w, uint32_t h, uint32_t d, vmg_resource *dst,
                                    size_t off, size_t row_pitch, size_t image_pitch);
void vmg_cmd_generate_mipmaps(vmg_device *dev, vmg_texture *tex);
// Pipeline barrier between dependent passes (memoryBarrier, textureBarrier).
void vmg_cmd_barrier(vmg_device *dev);

// Submits everything recorded so far. *fence (if non-NULL) signals when the GPU has finished it.
void vmg_flush(vmg_device *dev, vmg_fence **fence);
// timeout_ns: 0 = poll; UINT64_MAX = forever. Returns true when signalled.
bool vmg_fence_wait(vmg_device *dev, vmg_fence *fence, uint64_t timeout_ns);
// Any thread: waits for the GPU only. Visibility results are written by vmg_fence_wait, on the GPU queue, when
// vmg_fence_has_results says there are some.
bool vmg_fence_wait_gpu(vmg_device *dev, vmg_fence *fence, uint64_t timeout_ns);
bool vmg_fence_has_results(vmg_fence *fence);
// Any thread once vmg_fence_has_results is false (else the GPU queue).
void vmg_fence_release(vmg_device *dev, vmg_fence *fence);

// Any thread (kernel uapi minor >= 2): a promise that the GPU will write these IOSurfaces. Their readers (other
// processes' jobs, IOSurfaceLock, the display) wait for it until vmg_surface_promise_resolve hands it the fence of the
// work that writes them (or for at most a second). Lets a command buffer that writes IOSurfaces return from commit
// before its replay. 0 = not available (too many surfaces, older kernel, llvmpipe).
uint32_t vmg_surface_promise(vmg_device *dev, const uint32_t *surface_ids, unsigned count);
// Any thread: the promise follows `fence` (NULL: signalled now) and is given back.
void vmg_surface_promise_resolve(vmg_device *dev, uint32_t promise, vmg_fence *fence);

#ifdef __cplusplus
}
#endif
