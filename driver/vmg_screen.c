// Viva Metal - Gallium back-end: device, resources, state objects, shaders and pipelines (see vmg.h).
#include "vmg_internal.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOSurface/IOSurfaceRef.h>
#include <TargetConditionals.h>
#include "nir.h"
#include "nir_builder.h"
#include "compiler/glsl_types.h"
#include "util/hash_table.h"
#include "util/u_dynarray.h"
#include "util/u_inlines.h"
#include "util/u_math.h"
#include "util/half_float.h"
#include "util/format/u_format.h"
#include "util/xmlconfig.h"
#include "util/driconf.h"
#include "drm-uapi/drm_fourcc.h"
#include "panfrost/pan_public.h"
#if VMG_HAVE_LLVMPIPE
#include "llvmpipe/lp_public.h"
#include "sw/null/null_sw_winsys.h"
#include "frontend/sw_winsys.h"
#endif
#include "../vgpu/vgpu.h"

// ---- Device ---------------------------------------------------------------------------------------------------------

static uint32_t rasterizer_hash(const void *key) { return _mesa_hash_data(key, sizeof(struct pipe_rasterizer_state)); }
static bool rasterizer_equal(const void *a, const void *b) { return !memcmp(a, b, sizeof(struct pipe_rasterizer_state)); }

// Variables for processes we do not start (backboardd): KEY=VALUE lines, without overriding the environment.
static void load_env_file(void)
{
    // In the bundle first: every process that loads the driver may read it (backboardd's sandbox may not reach /var/root).
    FILE *f = fopen("/System/Library/Extensions/VivaMTLDriver.bundle/vmg.env", "r");
    if (!f) f = fopen("/private/var/root/viva-tests/vmg.env", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        char *eq = strchr(line, '=');
        if (line[0] == '#' || !eq || eq == line) continue;
        *eq = 0;
        setenv(line, eq + 1, 0);
    }
    fclose(f);
}

vmg_device *vmg_device_create(const char *which, char *error, size_t error_size)
{
    load_env_file();
    if (!which) which = getenv("VMG_DRIVER");
#if TARGET_OS_IPHONE
    if (!which) which = "panfrost";
#else
    if (!which) which = VMG_HAVE_LLVMPIPE ? "llvmpipe" : "panfrost";
#endif
    vmg_device *dev = calloc(1, sizeof *dev);
    dev->copy_epoch = 1;   // new textures (copy_epoch 0) copy in at their first use, also in the first command buffer
    dev->fd = -1;
    glsl_type_singleton_init_or_ref();
    if (!strcmp(which, "panfrost")) {
        dev->fd = vgpu_open();
        if (dev->fd < 0) {
            snprintf(error, error_size, "vgpu_open failed (%s back-end): %s", vgpu_backend_name(), strerror(-dev->fd));
            free(dev);
            return NULL;
        }
        // driconf: Panfrost's option table with its defaults (no configuration files on the phone).
        static const driOptionDescription panfrost_driconf[] = {
#include "panfrost/driinfo_panfrost.h"
        };
        static driOptionCache info, options;
        static bool parsed;
        if (!parsed) { driParseOptionInfo(&info, panfrost_driconf, ARRAY_SIZE(panfrost_driconf)); parsed = true; }
        struct pipe_screen_config config = { .driver_name_is_inferred = false, .options = &options, .options_info = &info };
        dev->screen = panfrost_create_screen(dev->fd, &config, NULL);
        dev->panfrost = true;
#if VMG_HAVE_LLVMPIPE
    } else if (!strcmp(which, "llvmpipe")) {
        dev->winsys = null_sw_create();
        dev->screen = dev->winsys ? llvmpipe_create_screen(dev->winsys) : NULL;
#endif
    } else {
        snprintf(error, error_size, "unknown driver %s", which);
        free(dev);
        return NULL;
    }
    if (!dev->screen) {
        snprintf(error, error_size, "%s: screen creation failed", which);
        if (dev->fd >= 0) vgpu_close(dev->fd);
        free(dev);
        return NULL;
    }
    dev->pipe = dev->screen->context_create(dev->screen, NULL, 0);
    if (!dev->pipe) {
        snprintf(error, error_size, "%s: context creation failed", which);
        dev->screen->destroy(dev->screen);
        free(dev);
        return NULL;
    }
    const struct pipe_caps *caps = &dev->screen->caps;
    vmg_device_info *info = &dev->info;
    snprintf(info->name, sizeof info->name, "%s", dev->screen->get_name(dev->screen));
    snprintf(info->driver, sizeof info->driver, "%s", which);
    info->max_texture_2d = caps->max_texture_2d_size;
    info->max_texture_3d = 1u << (caps->max_texture_3d_levels ? caps->max_texture_3d_levels - 1 : 11);
    info->max_texture_cube = 1u << (caps->max_texture_cube_levels ? caps->max_texture_cube_levels - 1 : 13);
    info->max_texture_layers = caps->max_texture_array_layers;
    info->max_samples = 1;
    for (unsigned s = 8; s > 1; s >>= 1)
        if (dev->screen->is_format_supported(dev->screen, PIPE_FORMAT_R8G8B8A8_UNORM, PIPE_TEXTURE_2D, s, s, PIPE_BIND_RENDER_TARGET)) {
            info->max_samples = s;
            break;
        }
    info->max_threads_per_group = dev->screen->compute_caps.max_threads_per_block ? dev->screen->compute_caps.max_threads_per_block : 256;
    info->max_shared_memory = (uint32_t)MIN2(dev->screen->compute_caps.max_local_size ? dev->screen->compute_caps.max_local_size : 32768, 32768);
    unsigned sg = dev->screen->compute_caps.subgroup_sizes;
    info->subgroup_size = sg ? 1u << (31 - __builtin_clz(sg)) : (dev->panfrost ? 16 : 8);
    info->video_memory = dev->screen->compute_caps.max_global_size ? dev->screen->compute_caps.max_global_size : 1ull << 30;
    info->unified_memory = true;

    dev->raster_cache = _mesa_hash_table_create(NULL, rasterizer_hash, rasterizer_equal);
    struct pipe_sampler_state ss = {0};
    ss.wrap_s = ss.wrap_t = ss.wrap_r = PIPE_TEX_WRAP_CLAMP_TO_EDGE;
    ss.min_img_filter = ss.mag_img_filter = PIPE_TEX_FILTER_NEAREST;
    ss.min_mip_filter = PIPE_TEX_MIPFILTER_NONE;
    ss.max_lod = 1000;
    dev->sampler_default = dev->pipe->create_sampler_state(dev->pipe, &ss);
    dev->velems_empty = dev->pipe->create_vertex_elements_state(dev->pipe, 0, NULL);
    struct pipe_blend_state bs = {0};
    bs.rt[0].colormask = PIPE_MASK_RGBA;
    dev->blend_default = dev->pipe->create_blend_state(dev->pipe, &bs);
    struct pipe_depth_stencil_alpha_state dsa = {0};
    dsa.depth_func = PIPE_FUNC_ALWAYS;
    dev->dsa_default = dev->pipe->create_depth_stencil_alpha_state(dev->pipe, &dsa);
    {
        // Empty fragment shader for pipelines without a fragment function.
        nir_builder b = nir_builder_init_simple_shader(MESA_SHADER_FRAGMENT, dev->screen->nir_options[MESA_SHADER_FRAGMENT], "vmg_empty_fs");
        struct pipe_shader_state fs = { .type = PIPE_SHADER_IR_NIR, .ir.nir = b.shader };
        dev->fs_empty = dev->pipe->create_fs_state(dev->pipe, &fs);
    }
    // Default raster state: Metal defaults (no cull, CCW? Metal's default front face is clockwise).
    struct pipe_rasterizer_state *r = &dev->raster;
    memset(r, 0, sizeof *r);
    r->half_pixel_center = 1;
    r->bottom_edge_rule = 0;
    r->clip_halfz = 1;
    r->depth_clip_near = r->depth_clip_far = 1;
    r->scissor = 1;
    r->multisample = 1;
    r->front_ccw = 0;
    r->line_width = 1;
    r->point_size = 1;
    r->point_size_per_vertex = 1;
    r->sprite_coord_mode = PIPE_SPRITE_COORD_UPPER_LEFT;
    r->fill_front = r->fill_back = PIPE_POLYGON_MODE_FILL;
    r->rasterizer_discard = 0;
    dev->raster_dirty = true;
    return dev;
}

void vmg_device_destroy(vmg_device *dev)
{
    if (!dev) return;
    hash_table_foreach(dev->raster_cache, he) dev->pipe->delete_rasterizer_state(dev->pipe, he->data), free((void *)he->key);
    _mesa_hash_table_destroy(dev->raster_cache, NULL);
    if (dev->sampler_default) dev->pipe->delete_sampler_state(dev->pipe, dev->sampler_default);
    if (dev->dsa_default) dev->pipe->delete_depth_stencil_alpha_state(dev->pipe, dev->dsa_default);
    if (dev->fs_empty) dev->pipe->delete_fs_state(dev->pipe, dev->fs_empty);
    if (dev->velems_empty) dev->pipe->delete_vertex_elements_state(dev->pipe, dev->velems_empty);
    if (dev->blend_default) dev->pipe->delete_blend_state(dev->pipe, dev->blend_default);
    pipe_sampler_view_reference(&dev->null_view, NULL);
    free(dev->copy_out);
    dev->pipe->destroy(dev->pipe);
    dev->screen->destroy(dev->screen);
    if (dev->fd >= 0) vgpu_close(dev->fd);
    glsl_type_singleton_decref();
    free(dev);
}

const vmg_device_info *vmg_device_get_info(vmg_device *dev) { return &dev->info; }

bool vmg_format_supported(vmg_device *dev, unsigned mtl_format, bool render_target, bool sampler)
{
    enum pipe_format f = vmg_pipe_format(mtl_format);
    if (f == PIPE_FORMAT_NONE) return false;
    unsigned bind = 0;
    if (render_target) bind |= util_format_is_depth_or_stencil(f) ? PIPE_BIND_DEPTH_STENCIL : PIPE_BIND_RENDER_TARGET;
    if (sampler) bind |= PIPE_BIND_SAMPLER_VIEW;
    return dev->screen->is_format_supported(dev->screen, f, PIPE_TEXTURE_2D, 0, 0, bind ? bind : PIPE_BIND_SAMPLER_VIEW);
}

// ---- Buffers --------------------------------------------------------------------------------------------------------

vmg_resource *vmg_buffer_create(vmg_device *dev, size_t size, void *user_memory, void **contents)
{
    struct pipe_resource templ = {0};
    templ.target = PIPE_BUFFER;
    templ.format = PIPE_FORMAT_R8_UNORM;
    templ.width0 = (unsigned)MAX2(size, 16);
    templ.height0 = templ.depth0 = templ.array_size = 1;
    templ.bind = PIPE_BIND_VERTEX_BUFFER | PIPE_BIND_INDEX_BUFFER | PIPE_BIND_CONSTANT_BUFFER | PIPE_BIND_SHADER_BUFFER |
                 PIPE_BIND_COMMAND_ARGS_BUFFER | PIPE_BIND_QUERY_BUFFER | PIPE_BIND_SAMPLER_VIEW;
    templ.usage = PIPE_USAGE_STAGING;   // CPU-visible, cached on unified memory
    templ.flags = PIPE_RESOURCE_FLAG_MAP_PERSISTENT | PIPE_RESOURCE_FLAG_MAP_COHERENT;
    vmg_resource *r = calloc(1, sizeof *r);
    r->size = size;
    if (user_memory && dev->screen->resource_from_user_memory)
        r->res = dev->screen->resource_from_user_memory(dev->screen, &templ, user_memory);
    if (!r->res) r->res = dev->screen->resource_create(dev->screen, &templ);
    if (!r->res) { free(r); return NULL; }
    struct pipe_box box;
    u_box_1d(0, templ.width0, &box);
    r->map = dev->pipe->buffer_map(dev->pipe, r->res, 0,
                                   PIPE_MAP_READ | PIPE_MAP_WRITE | PIPE_MAP_PERSISTENT | PIPE_MAP_COHERENT | PIPE_MAP_UNSYNCHRONIZED,
                                   &box, &r->transfer);
    if (user_memory && r->map != user_memory && r->map) memcpy(r->map, user_memory, size);   // copy fallback
    if (contents) *contents = r->map;
    return r;
}

void vmg_resource_release(vmg_device *dev, vmg_resource *r)
{
    if (!r) return;
    if (r->transfer) dev->pipe->buffer_unmap(dev->pipe, r->transfer);
    pipe_resource_reference(&r->res, NULL);
    free(r);
}

// ---- Textures -------------------------------------------------------------------------------------------------------

static enum pipe_texture_target target_of(enum vmg_texture_type t)
{
    switch (t) {
    case VMG_TEX_1D: return PIPE_TEXTURE_1D;
    case VMG_TEX_1D_ARRAY: return PIPE_TEXTURE_1D_ARRAY;
    case VMG_TEX_2D: case VMG_TEX_2D_MS: return PIPE_TEXTURE_2D;
    case VMG_TEX_2D_ARRAY: case VMG_TEX_2D_MS_ARRAY: return PIPE_TEXTURE_2D_ARRAY;
    case VMG_TEX_CUBE: return PIPE_TEXTURE_CUBE;
    case VMG_TEX_CUBE_ARRAY: return PIPE_TEXTURE_CUBE_ARRAY;
    case VMG_TEX_3D: return PIPE_TEXTURE_3D;
    case VMG_TEX_BUFFER: return PIPE_BUFFER;
    }
    return PIPE_TEXTURE_2D;
}

static void texture_template(vmg_device *dev, const vmg_texture_desc *d, struct pipe_resource *templ)
{
    memset(templ, 0, sizeof *templ);
    templ->target = target_of(d->type);
    templ->format = vmg_pipe_format(d->mtl_format);
    templ->width0 = MAX2(d->width, 1);
    templ->height0 = (uint16_t)MAX2(d->height, 1);
    templ->depth0 = (uint16_t)(d->type == VMG_TEX_3D ? MAX2(d->depth, 1) : 1);
    unsigned layers = MAX2(d->array_length, 1);
    if (d->type == VMG_TEX_CUBE) layers = 6;
    if (d->type == VMG_TEX_CUBE_ARRAY) layers *= 6;
    templ->array_size = (uint16_t)layers;
    templ->last_level = (uint8_t)(MAX2(d->mip_levels, 1) - 1);
    templ->nr_samples = templ->nr_storage_samples = (uint8_t)(d->samples > 1 ? d->samples : 0);
    templ->bind = PIPE_BIND_SAMPLER_VIEW;
    if (d->render_target) templ->bind |= util_format_is_depth_or_stencil(templ->format) ? PIPE_BIND_DEPTH_STENCIL : PIPE_BIND_RENDER_TARGET;
    if (d->shader_write) templ->bind |= PIPE_BIND_SHADER_IMAGE;
    templ->usage = PIPE_USAGE_DEFAULT;
    (void)dev;
}

static vmg_texture *texture_wrap(struct pipe_resource *res, const vmg_texture_desc *d)
{
    vmg_texture *t = calloc(1, sizeof *t);
    t->res = res;
    t->desc = *d;
    t->mtl_format = d->mtl_format;
    t->format = res->format;
    t->target = res->target;
    t->first_level = 0;
    t->last_level = res->last_level;
    t->first_layer = 0;
    t->last_layer = res->target == PIPE_TEXTURE_3D ? 0 : res->array_size - 1;
    t->swizzle[0] = PIPE_SWIZZLE_X; t->swizzle[1] = PIPE_SWIZZLE_Y; t->swizzle[2] = PIPE_SWIZZLE_Z; t->swizzle[3] = PIPE_SWIZZLE_W;
    if (util_format_is_depth_or_stencil(res->format)) {
        // Metal samples depth as (d, 0, 0, 1)
        t->swizzle[1] = t->swizzle[2] = PIPE_SWIZZLE_0;
        t->swizzle[3] = PIPE_SWIZZLE_1;
    }
    if (d->mtl_format == 1 /* MTLPixelFormatA8Unorm */) {
        t->swizzle[0] = t->swizzle[1] = t->swizzle[2] = PIPE_SWIZZLE_0;
    }
    return t;
}

vmg_texture *vmg_texture_create(vmg_device *dev, const vmg_texture_desc *d)
{
    struct pipe_resource templ;
    texture_template(dev, d, &templ);
    if (templ.format == PIPE_FORMAT_NONE) return NULL;
    struct pipe_resource *res = NULL;
    // VMG_NO_AFBC_UPLOAD=1 (to measure on the phone): textures only sampled (filled by the CPU: replaceRegion, blit
    // from a buffer) get the u-interleaved layout instead of AFBC. Panfrost uploads AFBC through a staging texture and
    // a GPU blit submitted at once (an extra batch per upload); u-interleaved is tiled by the CPU, but a partial update
    // of a texture the GPU is still reading waits for it.
    static int no_afbc = -1;
    if (no_afbc < 0) no_afbc = getenv("VMG_NO_AFBC_UPLOAD") != NULL;
    if (no_afbc && dev->panfrost && dev->screen->resource_create_with_modifiers && !d->render_target && !d->shader_write &&
        !d->memoryless && templ.target == PIPE_TEXTURE_2D && !templ.nr_samples) {
        uint64_t mod = DRM_FORMAT_MOD_ARM_16X16_BLOCK_U_INTERLEAVED;
        res = dev->screen->resource_create_with_modifiers(dev->screen, &templ, &mod, 1);
    }
    if (!res) res = dev->screen->resource_create(dev->screen, &templ);
    return res ? texture_wrap(res, d) : NULL;
}

vmg_texture *vmg_texture_create_iosurface(vmg_device *dev, const vmg_texture_desc *d, uint32_t surface_id, unsigned plane)
{
    struct pipe_resource templ;
    texture_template(dev, d, &templ);
    if (templ.format == PIPE_FORMAT_NONE) return NULL;
    templ.bind |= PIPE_BIND_SHARED | PIPE_BIND_LINEAR;
    struct pipe_resource *res = NULL;
    if (dev->panfrost) {
        // The kernel imports the surface pages as a BO (VGPU_SEL_IMPORT_IOSURFACE through drmPrimeFDToHandle, see
        // vmg_drm.c): the winsys handle carries the surface id as a "dma-buf fd".
        struct winsys_handle wh = {0};
        wh.type = WINSYS_HANDLE_TYPE_FD;
        wh.handle = (unsigned)vmg_drm_surface_fd(dev->fd, surface_id, plane);
        IOSurfaceRef s = IOSurfaceLookup(surface_id);
        uint32_t sfmt = 0, sw = 0, sh = 0;
        if (s) {
            wh.stride = (unsigned)(IOSurfaceGetPlaneCount(s) ? IOSurfaceGetBytesPerRowOfPlane(s, plane) : IOSurfaceGetBytesPerRow(s));
            sfmt = IOSurfaceGetPixelFormat(s);
            sw = (uint32_t)IOSurfaceGetWidth(s); sh = (uint32_t)IOSurfaceGetHeight(s);
            CFRelease(s);
        }
        static int logged;
        if ((wh.stride & 63) && logged < 32) {
            logged++;
            fprintf(stderr, "vmg: IOSurface %u plane %u %ux%u '%c%c%c%c' bpr %u: pitch not 64-aligned, copied (texture %ux%u %s)\n",
                    surface_id, plane, sw, sh, sfmt >> 24, (sfmt >> 16) & 0xff, (sfmt >> 8) & 0xff, sfmt & 0xff, wh.stride,
                    templ.width0, templ.height0, util_format_short_name(templ.format));
        }
        wh.modifier = 0;   // DRM_FORMAT_MOD_LINEAR
        // Valhall wants linear rows aligned to 64 bytes: surfaces with other pitches (many of CoreAnimation's layer
        // surfaces) cannot be imported and get a separate texture, copied from/to the surface around each use.
        if (wh.stride && !(wh.stride & 63))
            res = dev->screen->resource_from_handle(dev->screen, &templ, &wh, PIPE_HANDLE_USAGE_FRAMEBUFFER_WRITE);
        vmg_drm_surface_fd_close((int)wh.handle);
        if (!res) {
            templ.bind &= ~(unsigned)PIPE_BIND_SHARED;
            res = dev->screen->resource_create(dev->screen, &templ);
            if (!res) return NULL;
            vmg_texture *t = texture_wrap(res, d);
            t->surface_id = surface_id; t->plane = plane; t->surface_copy = true;
            t->surface = (void *)IOSurfaceLookup(surface_id);
            return t;
        }
    } else {
        // llvmpipe: alias the surface memory when the layout matches (stride checked after creation), else copy.
        IOSurfaceRef s = IOSurfaceLookup(surface_id);
        if (!s) return NULL;
        void *base = IOSurfaceGetPlaneCount(s) ? IOSurfaceGetBaseAddressOfPlane(s, plane) : IOSurfaceGetBaseAddress(s);
        size_t bpr = IOSurfaceGetPlaneCount(s) ? IOSurfaceGetBytesPerRowOfPlane(s, plane) : IOSurfaceGetBytesPerRow(s);
        templ.bind &= ~(unsigned)PIPE_BIND_SHARED;
        if (dev->screen->resource_from_user_memory && !getenv("VMG_NO_ALIAS")) res = dev->screen->resource_from_user_memory(dev->screen, &templ, base);
        if (res) {
            struct winsys_handle wh = {0};
            unsigned stride = 0;
            uint64_t value = 0;
            if (dev->screen->resource_get_param &&
                dev->screen->resource_get_param(dev->screen, dev->pipe, res, 0, 0, 0, PIPE_RESOURCE_PARAM_STRIDE, 0, &value))
                stride = (unsigned)value;
            (void)wh;
            if (stride != bpr) pipe_resource_reference(&res, NULL);
        }
        CFRelease(s);
        if (!res) {
            res = dev->screen->resource_create(dev->screen, &templ);
            if (!res) return NULL;
            vmg_texture *t = texture_wrap(res, d);
            t->surface_id = surface_id; t->plane = plane; t->surface_copy = true;
            t->surface = (void *)IOSurfaceLookup(surface_id);
            return t;
        }
    }
    if (!res) return NULL;
    vmg_texture *t = texture_wrap(res, d);
    t->surface_id = surface_id; t->plane = plane;
    return t;
}

vmg_texture *vmg_texture_create_buffer(vmg_device *dev, const vmg_texture_desc *d, vmg_resource *buffer, size_t offset, size_t bpr)
{
    // Linear texture over a buffer: a texture aliasing the buffer's memory when the driver allows user memory with
    // that stride; otherwise a separate texture (contents copied by the encoder on use).
    struct pipe_resource templ;
    texture_template(dev, d, &templ);
    if (templ.format == PIPE_FORMAT_NONE) return NULL;
    templ.bind |= PIPE_BIND_LINEAR;
    struct pipe_resource *res = NULL;
    if (buffer->map && dev->screen->resource_from_user_memory && !getenv("VMG_NO_ALIAS")) {   // VMG_NO_ALIAS: the copy path
        res = dev->screen->resource_from_user_memory(dev->screen, &templ, (uint8_t *)buffer->map + offset);
        uint64_t stride = 0;
        if (res && dev->screen->resource_get_param &&
            dev->screen->resource_get_param(dev->screen, dev->pipe, res, 0, 0, 0, PIPE_RESOURCE_PARAM_STRIDE, 0, &stride) &&
            stride != bpr)
            pipe_resource_reference(&res, NULL);
    }
    // Panfrost: a linear texture over the buffer's own BO (Valhall wants offset and row pitch aligned to 64 bytes,
    // the alignment the device reports to Metal). The copy below was made at every command buffer that sampled the
    // texture, reading the write-combined buffer: CoreAnimation's images, glyphs and gradients, every frame.
    static int no_alias = -1;
    if (no_alias < 0) no_alias = getenv("VMG_NO_ALIAS") != NULL;
    uint64_t last_row = (uint64_t)util_format_get_stride(templ.format, templ.width0);
    uint64_t need = (uint64_t)offset + (uint64_t)bpr * (util_format_get_nblocksy(templ.format, templ.height0) - 1) + last_row;
    if (!res && dev->panfrost && !no_alias && !(offset & 63) && bpr && !(bpr & 63) && bpr >= last_row &&
        need <= buffer->res->width0 && templ.target == PIPE_TEXTURE_2D && templ.last_level == 0 && templ.array_size == 1 &&
        !templ.nr_samples && !util_format_is_compressed(templ.format)) {
        struct winsys_handle kms = { .type = WINSYS_HANDLE_TYPE_KMS };
        if (dev->screen->resource_get_handle(dev->screen, dev->pipe, buffer->res, &kms, 0)) {
            struct winsys_handle wh = {0};
            wh.type = WINSYS_HANDLE_TYPE_FD;
            int fd = vmg_drm_bo_fd(dev->fd, kms.handle);
            if (fd >= 0) {
                wh.handle = (unsigned)fd;
                wh.stride = (unsigned)bpr;
                wh.offset = (unsigned)offset;
                wh.modifier = 0;   // DRM_FORMAT_MOD_LINEAR
                res = dev->screen->resource_from_handle(dev->screen, &templ, &wh, 0);
                vmg_drm_surface_fd_close(fd);
            }
        }
    }
    if (res) return texture_wrap(res, d);
    static int logged;
    if (dev->panfrost && logged < 16) {
        logged++;
        fprintf(stderr, "vmg: buffer texture %ux%u %s offset %zu bpr %zu: copied at each command buffer that samples it\n",
                templ.width0, templ.height0, util_format_short_name(templ.format), offset, bpr);
    }
    res = dev->screen->resource_create(dev->screen, &templ);
    if (!res) return NULL;
    vmg_texture *t = texture_wrap(res, d);
    if (buffer->map) { t->buffer = buffer; t->buffer_offset = offset; t->buffer_bpr = bpr; t->surface_copy = true; }
    return t;
}

static enum pipe_texture_target view_target(enum vmg_texture_type t) { return target_of(t); }

vmg_texture *vmg_texture_create_view(vmg_device *dev, vmg_texture *parent, unsigned mtl_format, enum vmg_texture_type type,
                                     uint32_t first_level, uint32_t levels, uint32_t first_slice, uint32_t slices,
                                     const uint8_t swizzle[4])
{
    (void)dev;
    vmg_texture *t = calloc(1, sizeof *t);
    pipe_resource_reference(&t->res, parent->res);
    t->parent = parent;
    t->desc = parent->desc;
    t->desc.type = type;
    t->desc.mtl_format = mtl_format;
    t->mtl_format = mtl_format;
    t->format = vmg_pipe_format(mtl_format);
    t->target = view_target(type);
    t->first_level = parent->first_level + first_level;
    t->last_level = t->first_level + MAX2(levels, 1) - 1;
    t->first_layer = parent->first_layer + first_slice;
    t->last_layer = t->first_layer + MAX2(slices, 1) - 1;
    if (parent->res->target == PIPE_TEXTURE_3D) t->first_layer = t->last_layer = 0;
    static const uint8_t map[6] = { PIPE_SWIZZLE_0, PIPE_SWIZZLE_1, PIPE_SWIZZLE_X, PIPE_SWIZZLE_Y, PIPE_SWIZZLE_Z, PIPE_SWIZZLE_W };
    for (unsigned i = 0; i < 4; i++) t->swizzle[i] = swizzle ? map[MIN2(swizzle[i], 5)] : parent->swizzle[i];
    t->surface_id = parent->surface_id; t->plane = parent->plane; t->surface_copy = parent->surface_copy;
    if (parent->surface) t->surface = (void *)CFRetain(parent->surface);
    t->buffer = parent->buffer; t->buffer_offset = parent->buffer_offset; t->buffer_bpr = parent->buffer_bpr;
    return t;
}

void vmg_texture_release(vmg_device *dev, vmg_texture *t)
{
    if (!t) return;
    vmg_texture_forget(dev, t);
    if (t->view) {
        if (dev->pipe->sampler_view_release) dev->pipe->sampler_view_release(dev->pipe, t->view);
        else pipe_sampler_view_reference(&t->view, NULL);
    }
    pipe_resource_reference(&t->res, NULL);
    if (t->surface) CFRelease(t->surface);
    free(t);
}

static unsigned layer_of(vmg_texture *t, unsigned slice, uint32_t z) { return t->res->target == PIPE_TEXTURE_3D ? z : t->first_layer + slice; }

void vmg_texture_write(vmg_device *dev, vmg_texture *t, unsigned level, unsigned slice, uint32_t x, uint32_t y, uint32_t z,
                       uint32_t w, uint32_t h, uint32_t d, const void *data, size_t row_pitch, size_t image_pitch)
{
    struct pipe_box box;
    u_box_3d((int)x, (int)y, (int)layer_of(t, slice, z), (int)w, (int)h, (int)MAX2(d, 1), &box);
    dev->pipe->texture_subdata(dev->pipe, t->res, t->first_level + level, PIPE_MAP_WRITE, &box, data,
                               (unsigned)row_pitch, (uintptr_t)image_pitch);
    if (t->surface_copy) vmg_texture_sync(dev, t, false);   // the surface/buffer stays the reference copy
}

void vmg_texture_read(vmg_device *dev, vmg_texture *t, unsigned level, unsigned slice, uint32_t x, uint32_t y, uint32_t z,
                      uint32_t w, uint32_t h, uint32_t d, void *data, size_t row_pitch, size_t image_pitch)
{
    struct pipe_box box;
    u_box_3d((int)x, (int)y, (int)layer_of(t, slice, z), (int)w, (int)h, (int)MAX2(d, 1), &box);
    struct pipe_transfer *xfer = NULL;
    uint8_t *map = dev->pipe->texture_map(dev->pipe, t->res, t->first_level + level, PIPE_MAP_READ, &box, &xfer);
    if (!map) return;
    const struct util_format_description *fd = util_format_description(t->res->format);
    unsigned rowBytes = util_format_get_stride(t->res->format, w);
    unsigned rows = util_format_get_nblocksy(t->res->format, h);
    (void)fd;
    for (unsigned k = 0; k < MAX2(d, 1); k++)
        for (unsigned r = 0; r < rows; r++)
            memcpy((uint8_t *)data + k * image_pitch + r * row_pitch, map + k * xfer->layer_stride + r * xfer->stride, rowBytes);
    dev->pipe->texture_unmap(dev->pipe, xfer);
}

// ---- Samplers and depth/stencil -------------------------------------------------------------------------------------

static unsigned wrap_of(uint8_t m)
{
    // MTLSamplerAddressMode: ClampToEdge 0, MirrorClampToEdge 1, Repeat 2, MirrorRepeat 3, ClampToZero 4, ClampToBorderColor 5
    switch (m) {
    case 1: return PIPE_TEX_WRAP_MIRROR_CLAMP_TO_EDGE;
    case 2: return PIPE_TEX_WRAP_REPEAT;
    case 3: return PIPE_TEX_WRAP_MIRROR_REPEAT;
    case 4: case 5: return PIPE_TEX_WRAP_CLAMP_TO_BORDER;
    default: return PIPE_TEX_WRAP_CLAMP_TO_EDGE;
    }
}

static unsigned compare_of(uint8_t f)
{
    // MTLCompareFunction: Never 0, Less 1, Equal 2, LessEqual 3, Greater 4, NotEqual 5, GreaterEqual 6, Always 7
    static const unsigned m[8] = { PIPE_FUNC_NEVER, PIPE_FUNC_LESS, PIPE_FUNC_EQUAL, PIPE_FUNC_LEQUAL, PIPE_FUNC_GREATER,
                                   PIPE_FUNC_NOTEQUAL, PIPE_FUNC_GEQUAL, PIPE_FUNC_ALWAYS };
    return m[f & 7];
}

static vmg_sampler *sampler_create(vmg_device *dev, const vmg_sampler_desc *d)
{
    struct pipe_sampler_state s = {0};
    s.wrap_s = wrap_of(d->address[0]); s.wrap_t = wrap_of(d->address[1]); s.wrap_r = wrap_of(d->address[2]);
    s.min_img_filter = d->min_filter ? PIPE_TEX_FILTER_LINEAR : PIPE_TEX_FILTER_NEAREST;
    s.mag_img_filter = d->mag_filter ? PIPE_TEX_FILTER_LINEAR : PIPE_TEX_FILTER_NEAREST;
    s.min_mip_filter = d->mip_filter == 0 ? PIPE_TEX_MIPFILTER_NONE : d->mip_filter == 1 ? PIPE_TEX_MIPFILTER_NEAREST : PIPE_TEX_MIPFILTER_LINEAR;
    s.max_anisotropy = d->max_anisotropy > 1 ? d->max_anisotropy : 0;
    if (d->compare) { s.compare_mode = PIPE_TEX_COMPARE_R_TO_TEXTURE; s.compare_func = compare_of(d->compare); }
    s.unnormalized_coords = !d->normalized;
    s.min_lod = d->lod_min;
    s.max_lod = d->lod_max;
    s.seamless_cube_map = 1;
    // MTLSamplerBorderColor: TransparentBlack 0, OpaqueBlack 1, OpaqueWhite 2
    // (ClampToZero = border transparent black, unless another axis uses ClampToBorderColor.)
    bool border_mode = d->address[0] == 5 || d->address[1] == 5 || d->address[2] == 5;
    unsigned border = border_mode ? d->border : 0;
    s.border_color.f[0] = s.border_color.f[1] = s.border_color.f[2] = border == 2 ? 1.0f : 0.0f;
    s.border_color.f[3] = border ? 1.0f : 0.0f;
    vmg_sampler *r = calloc(1, sizeof *r);
    r->state = s;
    r->cso = dev->pipe->create_sampler_state(dev->pipe, &s);
    return r;
}

vmg_sampler *vmg_sampler_create(vmg_device *dev, const vmg_sampler_desc *d) { return sampler_create(dev, d); }

vmg_sampler *vmg_sampler_create_constexpr(vmg_device *dev, uint64_t w)
{
    // MSL constexpr sampler word (layout in vmg_air.c), decoded as metal-shim's TSGLSamplerForConstexpr does.
    // Word address values: 0 clamp_to_zero, 1 clamp_to_edge, 2 repeat, 3 mirrored_repeat, 4 clamp_to_border,
    // 5 mirrored_clamp_to_edge (-> MTLSamplerAddressMode). Compare: none, less, less_equal, greater, greater_equal,
    // equal, not_equal, always, never (-> MTLCompareFunction).
    static const uint8_t addr[8] = { 4, 0, 2, 3, 5, 1, 0, 0 };
    static const uint8_t cm[16] = { 0, 1, 3, 4, 6, 2, 5, 7, 0 };
    vmg_sampler_desc d = {0};
    for (unsigned i = 0; i < 3; i++) d.address[i] = addr[(w >> (3 * i)) & 7];
    d.mag_filter = ((w >> 9) & 3) != 0;
    d.min_filter = ((w >> 11) & 3) != 0;
    d.mip_filter = (uint8_t)((w >> 13) & 3);
    d.compare = cm[(w >> 16) & 15];
    d.max_anisotropy = (uint8_t)(((w >> 20) & 15) + 1);
    d.lod_min = _mesa_half_to_float((uint16_t)(w >> 24));
    d.lod_max = _mesa_half_to_float((uint16_t)(w >> 40));
    d.border = (uint8_t)((w >> 56) & 3);
    d.normalized = true;   // coord::pixel is divided by the texture size in the shader (vmg_air.c)
    if (getenv("VMG_TRACE"))
        fprintf(stderr, "vmg: constexpr sampler 0x%016llx: min %u mag %u mip %u addr %u %u %u lod %g..%g border %u\n",
                (unsigned long long)w, d.min_filter, d.mag_filter, d.mip_filter, d.address[0], d.address[1], d.address[2],
                d.lod_min, d.lod_max, d.border);
    return sampler_create(dev, &d);
}

void vmg_sampler_release(vmg_device *dev, vmg_sampler *s)
{
    if (!s) return;
    dev->pipe->delete_sampler_state(dev->pipe, s->cso);
    free(s);
}

static unsigned stencil_op(uint8_t o)
{
    // MTLStencilOperation: Keep 0, Zero 1, Replace 2, IncrementClamp 3, DecrementClamp 4, Invert 5, IncrementWrap 6, DecrementWrap 7
    static const unsigned m[8] = { PIPE_STENCIL_OP_KEEP, PIPE_STENCIL_OP_ZERO, PIPE_STENCIL_OP_REPLACE, PIPE_STENCIL_OP_INCR,
                                   PIPE_STENCIL_OP_DECR, PIPE_STENCIL_OP_INVERT, PIPE_STENCIL_OP_INCR_WRAP, PIPE_STENCIL_OP_DECR_WRAP };
    return m[o & 7];
}

vmg_dsa *vmg_dsa_create(vmg_device *dev, const vmg_dsa_desc *d)
{
    struct pipe_depth_stencil_alpha_state s = {0};
    s.depth_enabled = d->depth_func != 7 || d->depth_write;
    s.depth_writemask = d->depth_write;
    s.depth_func = compare_of(d->depth_func);
    if (d->stencil) {
        const vmg_stencil_face *f[2] = { &d->front, &d->back };
        for (unsigned i = 0; i < 2; i++) {
            s.stencil[i].enabled = 1;
            s.stencil[i].func = compare_of(f[i]->func);
            s.stencil[i].fail_op = stencil_op(f[i]->fail);
            s.stencil[i].zfail_op = stencil_op(f[i]->depth_fail);
            s.stencil[i].zpass_op = stencil_op(f[i]->pass);
            s.stencil[i].valuemask = f[i]->read_mask & 0xff;
            s.stencil[i].writemask = f[i]->write_mask & 0xff;
        }
    }
    vmg_dsa *r = calloc(1, sizeof *r);
    r->cso = dev->pipe->create_depth_stencil_alpha_state(dev->pipe, &s);
    return r;
}

void vmg_dsa_release(vmg_device *dev, vmg_dsa *d)
{
    if (!d) return;
    dev->pipe->delete_depth_stencil_alpha_state(dev->pipe, d->cso);
    free(d);
}

// Half as 32-bit float when the driver has no fp16 (or VMG_HALF32=1; VMG_HALF32=0 forces native half).
static bool vmg_half32(vmg_device *dev)
{
    const char *e = getenv("VMG_HALF32");
    if (e && *e) return *e != '0';
    return !dev->screen->shader_caps[MESA_SHADER_FRAGMENT].fp16;
}


// ---- Shaders --------------------------------------------------------------------------------------------------------

static mesa_shader_stage nir_stage_of(const void *bitcode, size_t size) { (void)bitcode; (void)size; return MESA_SHADER_NONE; }

vmg_shader *vmg_shader_create(vmg_device *dev, const vmg_air_input *in, vmg_reflection *refl, char **error)
{
    (void)nir_stage_of;
    struct util_dynarray pool;
    util_dynarray_init(&pool, NULL);
    vmg_reflection r;
    // The options of the stage are needed before the stage is known: all graphics drivers here share them between
    // stages closely enough for the builder; the driver re-lowers in create_*_state.
    const struct nir_shader_compiler_options *opts = dev->screen->nir_options[MESA_SHADER_FRAGMENT];
    vmg_air_input in2 = *in;
    in2.half32 = vmg_half32(dev);
    nir_shader *nir = vmg_air_translate(opts, &in2, &r, &pool, error);
    if (!nir) { util_dynarray_fini(&pool); return NULL; }
    if (dev->screen->nir_options[nir->info.stage]) nir->options = dev->screen->nir_options[nir->info.stage];
    if (nir->info.stage == MESA_SHADER_FRAGMENT) {
        // Position / face / point coordinate as inputs where the driver does not take them as system values (llvmpipe).
        const struct pipe_caps *c = &dev->screen->caps;
        nir_lower_sysvals_to_varyings_options sv = { .frag_coord = !c->fs_position_is_sysval,
                                                    .front_face = !c->fs_face_is_integer_sysval,
                                                    .point_coord = !c->fs_point_is_sysval };
        NIR_PASS(_, nir, nir_lower_sysvals_to_varyings, &sv);
        nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
        nir->info.fs.origin_upper_left = true;
        for (unsigned i = 0; i < VMG_MAX_TEXTURES; i++) {
            if (r.textures_used & (1u << i)) BITSET_SET(nir->info.textures_used, i);
            if (r.textures_written & (1u << i)) BITSET_SET(nir->info.images_used, i);
        }
        for (unsigned i = 0; i < 32; i++)
            if ((i < VMG_MAX_SAMPLERS && (r.samplers_used & (1u << i))) ||
                (i >= VMG_CONSTEXPR_SAMPLER_BASE && i - VMG_CONSTEXPR_SAMPLER_BASE < r.constexpr_samplers))
                BITSET_SET(nir->info.samplers_used, i);
        nir->info.num_ssbos = VMG_MAX_BUFFERS;
        nir->info.num_ubos = 2;
    }
    if (dev->screen->finalize_nir) dev->screen->finalize_nir(dev->screen, nir, true);
    vmg_shader *sh = calloc(1, sizeof *sh);
    sh->stage = r.stage;
    snprintf(sh->name, sizeof sh->name, "%s", nir->info.name ? nir->info.name : "?");
    sh->refl = r;
    if (refl) *refl = r;
    sh->pool_size = pool.size;
    if (pool.size) { sh->pool = malloc(pool.size); memcpy(sh->pool, pool.data, pool.size); }
    util_dynarray_fini(&pool);
    if (sh->pool_size) {
        struct pipe_resource templ = {0};
        templ.target = PIPE_BUFFER;
        templ.format = PIPE_FORMAT_R8_UNORM;
        templ.width0 = (unsigned)align(sh->pool_size, 16);
        templ.height0 = templ.depth0 = templ.array_size = 1;
        templ.bind = PIPE_BIND_CONSTANT_BUFFER;
        templ.usage = PIPE_USAGE_IMMUTABLE;
        sh->pool_buffer = dev->screen->resource_create(dev->screen, &templ);
        if (sh->pool_buffer) dev->pipe->buffer_subdata(dev->pipe, sh->pool_buffer, PIPE_MAP_WRITE, 0, (unsigned)sh->pool_size, sh->pool);
    }
    for (unsigned i = 0; i < r.constexpr_samplers; i++) sh->constexpr_samplers[i] = vmg_sampler_create_constexpr(dev, r.constexpr_words[i]);

    // Compact driver locations for varyings and fragment outputs (Gallium drivers index their I/O arrays with them);
    // vertex inputs keep the attribute index, which the vertex elements follow.
    if (nir->info.stage == MESA_SHADER_VERTEX)
        nir_assign_io_var_locations(nir, nir_var_shader_out);
    if (nir->info.stage == MESA_SHADER_FRAGMENT) {
        nir_assign_io_var_locations(nir, nir_var_shader_in);
        nir_assign_io_var_locations(nir, nir_var_shader_out);
    }
    if (getenv("VMG_TRACE")) { fprintf(stderr, "vmg: creating %s shader %s\n", mesa_shader_stage_name(nir->info.stage), nir->info.name); if (getenv("VMG_TRACE_NIR")) nir_print_shader(nir, stderr); }
    if (nir->info.stage == MESA_SHADER_FRAGMENT) {
        sh->colors_written = (uint32_t)(nir->info.outputs_written >> FRAG_RESULT_DATA0) & 0xff;
        if (sh->colors_written & ~1u) sh->nir_keep = nir_shader_clone(NULL, nir);   // writes beyond colour 0
    }
    struct pipe_shader_state state = {0};
    state.type = PIPE_SHADER_IR_NIR;
    state.ir.nir = nir;
    state.report_compile_error = true;
    switch (nir->info.stage) {
    case MESA_SHADER_VERTEX: sh->cso = dev->pipe->create_vs_state(dev->pipe, &state); break;
    case MESA_SHADER_FRAGMENT: sh->cso = dev->pipe->create_fs_state(dev->pipe, &state); break;
    default: {
        struct pipe_compute_state cs = {0};
        cs.ir_type = PIPE_SHADER_IR_NIR;
        cs.prog = nir;
        cs.static_shared_mem = r.static_shared;
        sh->cso = dev->pipe->create_compute_state(dev->pipe, &cs);
        break;
    }
    }
    if (!sh->cso) {
        *error = state.error_message ? state.error_message : strdup("driver rejected the shader");
        vmg_shader_release(dev, sh);
        return NULL;
    }
    free(state.error_message);
    return sh;
}

void vmg_shader_release(vmg_device *dev, vmg_shader *sh)
{
    if (!sh) return;
    ralloc_free(sh->nir_keep);
    if (sh->cso) {
        if (sh->stage == VMG_VERTEX) dev->pipe->delete_vs_state(dev->pipe, sh->cso);
        else if (sh->stage == VMG_FRAGMENT) dev->pipe->delete_fs_state(dev->pipe, sh->cso);
        else dev->pipe->delete_compute_state(dev->pipe, sh->cso);
    }
    for (unsigned i = 0; i < 16; i++) vmg_sampler_release(dev, sh->constexpr_samplers[i]);
    pipe_resource_reference(&sh->pool_buffer, NULL);
    free(sh->pool);
    free(sh);
}

char *vmg_air_to_nir_text(vmg_device *dev, const vmg_air_input *in, char **error)
{
    struct util_dynarray pool;
    util_dynarray_init(&pool, NULL);
    vmg_reflection r;
    vmg_air_input in2 = *in;
    in2.half32 = vmg_half32(dev);
    nir_shader *nir = vmg_air_translate(dev->screen->nir_options[MESA_SHADER_FRAGMENT], &in2, &r, &pool, error);
    util_dynarray_fini(&pool);
    if (!nir) return NULL;
    char *buf = NULL;
    size_t len = 0;
    FILE *f = open_memstream(&buf, &len);
    nir_print_shader(nir, f);
    fclose(f);
    ralloc_free(nir);
    return buf;
}

// ---- Pipelines ------------------------------------------------------------------------------------------------------

static unsigned blend_factor(uint8_t f)
{
    // MTLBlendFactor
    static const unsigned m[] = {
        PIPE_BLENDFACTOR_ZERO, PIPE_BLENDFACTOR_ONE, PIPE_BLENDFACTOR_SRC_COLOR, PIPE_BLENDFACTOR_INV_SRC_COLOR,
        PIPE_BLENDFACTOR_SRC_ALPHA, PIPE_BLENDFACTOR_INV_SRC_ALPHA, PIPE_BLENDFACTOR_DST_COLOR, PIPE_BLENDFACTOR_INV_DST_COLOR,
        PIPE_BLENDFACTOR_DST_ALPHA, PIPE_BLENDFACTOR_INV_DST_ALPHA, PIPE_BLENDFACTOR_SRC_ALPHA_SATURATE,
        PIPE_BLENDFACTOR_CONST_COLOR, PIPE_BLENDFACTOR_INV_CONST_COLOR, PIPE_BLENDFACTOR_CONST_ALPHA,
        PIPE_BLENDFACTOR_INV_CONST_ALPHA, PIPE_BLENDFACTOR_SRC1_COLOR, PIPE_BLENDFACTOR_INV_SRC1_COLOR,
        PIPE_BLENDFACTOR_SRC1_ALPHA, PIPE_BLENDFACTOR_INV_SRC1_ALPHA,
    };
    return f < sizeof m / sizeof m[0] ? m[f] : PIPE_BLENDFACTOR_ONE;
}

static unsigned blend_op(uint8_t o)
{
    static const unsigned m[] = { PIPE_BLEND_ADD, PIPE_BLEND_SUBTRACT, PIPE_BLEND_REVERSE_SUBTRACT, PIPE_BLEND_MIN, PIPE_BLEND_MAX };
    return o < 5 ? m[o] : PIPE_BLEND_ADD;
}

// Removes the stores to colour outputs outside 'keep' (bit i = FRAG_RESULT_DATAi).
static bool drop_color_outputs(nir_builder *b, nir_intrinsic_instr *in, void *data)
{
    uint32_t keep = *(uint32_t *)data;
    if (in->intrinsic != nir_intrinsic_store_deref) return false;
    nir_variable *v = nir_intrinsic_get_var(in, 0);
    if (!v || v->data.mode != nir_var_shader_out || v->data.location < FRAG_RESULT_DATA0) return false;
    if (keep & (1u << (v->data.location - FRAG_RESULT_DATA0))) return false;
    nir_instr_remove(&in->instr);
    return true;
}

static void *fragment_variant(vmg_device *dev, vmg_shader *fs, uint32_t attached)
{
    nir_shader *nir = nir_shader_clone(NULL, fs->nir_keep);
    nir_shader_intrinsics_pass(nir, drop_color_outputs, nir_metadata_control_flow, &attached);
    nir_remove_dead_variables(nir, nir_var_shader_out, NULL);
    nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
    nir_assign_io_var_locations(nir, nir_var_shader_out);
    struct pipe_shader_state state = {0};
    state.type = PIPE_SHADER_IR_NIR;
    state.ir.nir = nir;
    void *cso = dev->pipe->create_fs_state(dev->pipe, &state);
    free(state.error_message);
    return cso;
}

vmg_render_pipeline *vmg_render_pipeline_create(vmg_device *dev, const vmg_render_pipeline_desc *d, char **error)
{
    vmg_render_pipeline *p = calloc(1, sizeof *p);
    p->desc = *d;
    if (d->fragment && d->fragment->nir_keep) {
        uint32_t attached = 0;
        for (unsigned i = 0; i < VMG_MAX_COLOR; i++) if (d->color[i].format) attached |= 1u << i;
        if (d->fragment->colors_written & ~attached) p->fs_variant = fragment_variant(dev, d->fragment, attached);
    }
    struct pipe_blend_state bs = {0};
    bs.independent_blend_enable = 1;
    // Panfrost sizes its blend descriptors by max_rt (llvmpipe ignores it): left at 0, writes to [[color(1+)]] were
    // dropped (CoreAnimation's clip mask in colour 1: black outside the rounded corners on iOS).
    for (unsigned i = 0; i < VMG_MAX_COLOR; i++) if (d->color[i].format) bs.max_rt = i;
    bs.alpha_to_coverage = d->alpha_to_coverage;
    bs.alpha_to_one = d->alpha_to_one;
    for (unsigned i = 0; i < VMG_MAX_COLOR; i++) {
        const vmg_color_attachment *c = &d->color[i];
        struct pipe_rt_blend_state *rt = &bs.rt[i];
        // MTLColorWriteMask: Red 8, Green 4, Blue 2, Alpha 1
        rt->colormask = (c->write_mask & 8 ? PIPE_MASK_R : 0) | (c->write_mask & 4 ? PIPE_MASK_G : 0) |
                        (c->write_mask & 2 ? PIPE_MASK_B : 0) | (c->write_mask & 1 ? PIPE_MASK_A : 0);
        if (!c->format) rt->colormask = 0;
        if (c->enabled && c->format && !vmg_format_is_integer(c->format)) {
            rt->blend_enable = 1;
            rt->rgb_func = blend_op(c->rgb_op);
            rt->alpha_func = blend_op(c->alpha_op);
            rt->rgb_src_factor = blend_factor(c->src_rgb);
            rt->rgb_dst_factor = blend_factor(c->dst_rgb);
            rt->alpha_src_factor = blend_factor(c->src_alpha);
            rt->alpha_dst_factor = blend_factor(c->dst_alpha);
        }
    }
    p->blend = dev->pipe->create_blend_state(dev->pipe, &bs);

    // Vertex elements: one per [[attribute(n)]] the vertex function reads, in attribute order (= driver_location).
    struct pipe_vertex_element ve[VMG_MAX_VERTEX_ATTRIBS];
    unsigned n = 0;
    uint32_t inputs = d->vertex ? d->vertex->refl.vertex_inputs : 0;
    int buffer_index[VMG_MAX_BUFFERS];
    for (unsigned i = 0; i < VMG_MAX_BUFFERS; i++) buffer_index[i] = -1;
    unsigned last = inputs ? 32 - __builtin_clz(inputs) : 0;
    for (unsigned a = 0; a < last; a++) {
        struct pipe_vertex_element *e = &ve[n++];
        memset(e, 0, sizeof *e);
        if (!(inputs & (1u << a)) || !(d->attrib_mask & (1u << a))) {
            // Read by the shader but not described: zeros from a dummy element on buffer 0 with stride 0.
            e->src_format = PIPE_FORMAT_R32G32B32A32_FLOAT;
            e->vertex_buffer_index = 0;
            if (buffer_index[0] < 0) { buffer_index[0] = (int)p->velem_buffers; p->velem_buffer[p->velem_buffers++] = 0; }
            e->vertex_buffer_index = (unsigned)buffer_index[0];
            continue;
        }
        const vmg_vertex_attrib *at = &d->attribs[a];
        const vmg_vertex_layout *lay = &d->layouts[at->buffer];
        if (buffer_index[at->buffer] < 0) {
            buffer_index[at->buffer] = (int)p->velem_buffers;
            p->velem_buffer[p->velem_buffers] = at->buffer;
            p->velem_strides[p->velem_buffers] = lay->stride;
            p->velem_buffers++;
        }
        e->src_format = vmg_vertex_format(at->format);
        e->src_offset = at->offset;
        e->vertex_buffer_index = (unsigned)buffer_index[at->buffer];
        e->src_stride = lay->stride;
        // MTLVertexStepFunction: Constant 0, PerVertex 1, PerInstance 2
        if (lay->step_function == 2) e->instance_divisor = MAX2(lay->step_rate, 1);
        else if (lay->step_function == 0) e->src_stride = 0;
        e->dual_slot = false;
    }
    p->velems = dev->pipe->create_vertex_elements_state(dev->pipe, n, ve);
    if (!p->blend || (n && !p->velems)) {
        *error = strdup("driver rejected the pipeline state");
        vmg_render_pipeline_release(dev, p);
        return NULL;
    }
    return p;
}

void vmg_render_pipeline_release(vmg_device *dev, vmg_render_pipeline *p)
{
    if (!p) return;
    if (p->fs_variant) dev->pipe->delete_fs_state(dev->pipe, p->fs_variant);
    if (p->blend) dev->pipe->delete_blend_state(dev->pipe, p->blend);
    if (p->velems) dev->pipe->delete_vertex_elements_state(dev->pipe, p->velems);
    free(p);
}

vmg_compute_pipeline *vmg_compute_pipeline_create(vmg_device *dev, vmg_shader *kernel, char **error)
{
    (void)dev;
    if (!kernel || kernel->stage != VMG_COMPUTE) { *error = strdup("not a kernel"); return NULL; }
    vmg_compute_pipeline *p = calloc(1, sizeof *p);
    p->kernel = kernel;
    return p;
}

void vmg_compute_pipeline_release(vmg_device *dev, vmg_compute_pipeline *p) { (void)dev; free(p); }

void vmg_compute_pipeline_limits(vmg_device *dev, vmg_compute_pipeline *p, uint32_t *simd_width, uint32_t *max_threads)
{
    struct pipe_compute_state_object_info info = {0};
    if (dev->pipe->get_compute_state_info) dev->pipe->get_compute_state_info(dev->pipe, p->kernel->cso, &info);
    *simd_width = info.preferred_simd_size ? info.preferred_simd_size : dev->info.subgroup_size;
    *max_threads = info.max_threads ? info.max_threads : dev->info.max_threads_per_group;
}
