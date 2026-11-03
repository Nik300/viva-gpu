// Viva Metal - Gallium back-end: command execution on the GPU queue (render passes, draws, dispatches, blits,
// fences). See vmg.h.
#include "vmg_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "util/hash_table.h"
#include "util/u_inlines.h"
#include "util/u_math.h"
#include "util/u_gen_mipmap.h"
#include "util/format/u_format.h"
#include "compiler/shader_enums.h"
#include <IOSurface/IOSurfaceRef.h>

static mesa_shader_stage gl_stage(enum vmg_stage s)
{
    return s == VMG_VERTEX ? MESA_SHADER_VERTEX : s == VMG_FRAGMENT ? MESA_SHADER_FRAGMENT : MESA_SHADER_COMPUTE;
}

// ---- IOSurface/buffer copies (when the driver cannot alias the memory) -------------------------------------------------

void vmg_texture_sync(vmg_device *dev, vmg_texture *t, bool to_texture)
{
    if (!t || !t->surface_copy || (!t->surface_id && !t->buffer)) return;
    // dev->copy_epoch changes at every command buffer and every copy-out (some surface/buffer changed): a texture
    // copies in once per change, not at every draw that samples it; after its own copy-out it is up to date.
    if (to_texture && t->copy_epoch == dev->copy_epoch) return;
    if (!to_texture) dev->copy_epoch++;
    t->copy_epoch = dev->copy_epoch;
    IOSurfaceRef s = NULL;
    uint8_t *base;
    size_t bpr;
    if (t->buffer) {
        base = (uint8_t *)t->buffer->map + t->buffer_offset;
        bpr = t->buffer_bpr;
    } else {
        s = IOSurfaceLookup(t->surface_id);
        if (!s) return;
        bool planar = IOSurfaceGetPlaneCount(s) > 0;
        base = planar ? IOSurfaceGetBaseAddressOfPlane(s, t->plane) : IOSurfaceGetBaseAddress(s);
        bpr = planar ? IOSurfaceGetBytesPerRowOfPlane(s, t->plane) : IOSurfaceGetBytesPerRow(s);
    }
    uint32_t w = t->res->width0, h = t->res->height0;
    if (s) IOSurfaceLock(s, to_texture ? kIOSurfaceLockReadOnly : 0, NULL);
    if (to_texture) {
        struct pipe_box box;
        u_box_2d(0, 0, (int)w, (int)h, &box);
        dev->pipe->texture_subdata(dev->pipe, t->res, 0, PIPE_MAP_WRITE, &box, base, (unsigned)bpr, 0);
    } else {
        struct pipe_box box;
        u_box_2d(0, 0, (int)w, (int)h, &box);
        struct pipe_transfer *x = NULL;
        uint8_t *m = dev->pipe->texture_map(dev->pipe, t->res, 0, PIPE_MAP_READ, &box, &x);
        if (m) {
            unsigned row = util_format_get_stride(t->res->format, w);
            for (uint32_t y = 0; y < h; y++) memcpy(base + y * bpr, m + y * x->stride, row);
            dev->pipe->texture_unmap(dev->pipe, x);
        }
    }
    if (s) {
        IOSurfaceUnlock(s, to_texture ? kIOSurfaceLockReadOnly : 0, NULL);
        CFRelease(s);
    }
}

// ---- Render passes --------------------------------------------------------------------------------------------------

static void set_surface(struct pipe_surface *ps, vmg_texture *t, unsigned level, unsigned slice, unsigned plane)
{
    memset(ps, 0, sizeof *ps);
    if (!t) return;
    ps->texture = t->res;
    ps->format = t->format;
    ps->level = t->first_level + level;
    unsigned layer = t->res->target == PIPE_TEXTURE_3D ? plane : t->first_layer + slice;
    ps->first_layer = ps->last_layer = (uint16_t)layer;
}

void vmg_cmd_begin_pass(vmg_device *dev, const vmg_pass_desc *pass)
{
    struct pipe_context *pipe = dev->pipe;
    dev->pass = *pass;
    static int trace_draw = -1;   // VMG_TRACE_DRAW=1: every pass (attachments, load/store) and draw (shader, blend)
    if (trace_draw < 0) trace_draw = getenv("VMG_TRACE_DRAW") != NULL;
    if (trace_draw) {
        fprintf(stderr, "vmg: pass");
        for (unsigned i = 0; i < VMG_MAX_COLOR; i++) {
            const vmg_attachment *a = &pass->color[i];
            if (!a->texture) continue;
            fprintf(stderr, " c%u %p %ux%u %s load %d store %d clear %.2f,%.2f,%.2f,%.2f", i, (void *)a->texture,
                    a->texture->res->width0, a->texture->res->height0, util_format_short_name(a->texture->format), a->load,
                    a->store, a->clear[0], a->clear[1], a->clear[2], a->clear[3]);
        }
        if (pass->stencil.texture) fprintf(stderr, " stencil load %d clear %u", pass->stencil.load, pass->stencil.clear_stencil);
        if (pass->depth.texture) fprintf(stderr, " depth load %d", pass->depth.load);
        fprintf(stderr, "\n");
    }
    struct pipe_framebuffer_state *fb = &dev->fb;
    memset(fb, 0, sizeof *fb);
    uint32_t w = 0, h = 0;
    unsigned ncb = 0;
    for (unsigned i = 0; i < VMG_MAX_COLOR; i++) {
        const vmg_attachment *a = &pass->color[i];
        if (!a->texture) continue;
        vmg_texture_sync(dev, a->texture, true);
        set_surface(&fb->cbufs[i], a->texture, a->level, a->slice, a->depth_plane);
        ncb = i + 1;
        uint32_t lw = u_minify(a->texture->res->width0, a->texture->first_level + a->level);
        uint32_t lh = u_minify(a->texture->res->height0, a->texture->first_level + a->level);
        w = w ? MIN2(w, lw) : lw;
        h = h ? MIN2(h, lh) : lh;
    }
    fb->nr_cbufs = (uint8_t)ncb;
    vmg_texture *zs = pass->depth.texture ? pass->depth.texture : pass->stencil.texture;
    if (zs) {
        const vmg_attachment *a = pass->depth.texture ? &pass->depth : &pass->stencil;
        set_surface(&fb->zsbuf, zs, a->level, a->slice, a->depth_plane);
        uint32_t lw = u_minify(zs->res->width0, zs->first_level + a->level), lh = u_minify(zs->res->height0, zs->first_level + a->level);
        w = w ? MIN2(w, lw) : lw;
        h = h ? MIN2(h, lh) : lh;
    }
    if (!w || !h) { w = MAX2(pass->width, 1); h = MAX2(pass->height, 1); }
    fb->width = w;
    fb->height = h;
    fb->layers = (uint16_t)MAX2(pass->layers, 1);
    fb->samples = (uint8_t)(pass->samples > 1 ? pass->samples : 0);
    pipe->set_framebuffer_state(pipe, fb);
    dev->in_pass = true;

    // Metal defaults for the pass: viewport and scissor cover the framebuffer.
    vmg_viewport vp = { 0, 0, w, h, 0, 1 };
    vmg_cmd_set_viewport(dev, &vp);
    dev->scissor.minx = dev->scissor.miny = 0;
    dev->scissor.maxx = (uint16_t)w;
    dev->scissor.maxy = (uint16_t)h;
    pipe->set_scissor_states(pipe, 0, 1, &dev->scissor);
    uint32_t samples = 1;
    for (unsigned i = 0; i < ncb; i++) if (pass->color[i].texture) samples = MAX2(samples, (uint32_t)MAX2(pass->color[i].texture->res->nr_samples, 1));
    dev->pass.samples = samples;
    dev->raster.multisample = samples > 1;   // single-sample: pixel centers (llvmpipe uses sample positions otherwise)

    // Load actions.
    for (unsigned i = 0; i < ncb; i++) {
        const vmg_attachment *a = &pass->color[i];
        if (!a->texture || a->load != VMG_LOAD_CLEAR) continue;
        union pipe_color_union c;
        if (util_format_is_pure_sint(a->texture->format)) for (int k = 0; k < 4; k++) c.i[k] = (int)a->clear[k];
        else if (util_format_is_pure_uint(a->texture->format)) for (int k = 0; k < 4; k++) c.ui[k] = (unsigned)a->clear[k];
        else for (int k = 0; k < 4; k++) c.f[k] = (float)a->clear[k];
        pipe->clear(pipe, PIPE_CLEAR_COLOR0 << i, 0, 0, NULL, &c, 0, 0);
    }
    unsigned zsclear = 0;
    if (pass->depth.texture && pass->depth.load == VMG_LOAD_CLEAR) zsclear |= PIPE_CLEAR_DEPTH;
    if (pass->stencil.texture && pass->stencil.load == VMG_LOAD_CLEAR && util_format_has_stencil(util_format_description(zs->format)))
        zsclear |= PIPE_CLEAR_STENCIL;
    if (zsclear) pipe->clear(pipe, zsclear, 0, 0xff, NULL, NULL, pass->depth.clear[0], pass->stencil.clear_stencil);

    // Every encoder starts from Metal's default state.
    dev->raster.cull_face = PIPE_FACE_NONE;
    dev->raster.front_ccw = 0;   // MTLWindingClockwise (see vmg_cmd_set_raster)
    dev->raster.fill_front = dev->raster.fill_back = PIPE_POLYGON_MODE_FILL;
    dev->raster.depth_clip_near = dev->raster.depth_clip_far = 1;
    dev->raster.offset_tri = 0; dev->raster.offset_units = dev->raster.offset_scale = dev->raster.offset_clamp = 0;
    dev->raster_dirty = true;
    dev->pipeline = NULL;
    dev->dsa = NULL;
    pipe->bind_depth_stencil_alpha_state(pipe, dev->dsa_default);
    dev->visibility_mode = 0;
}

static void end_visibility(vmg_device *dev);

void vmg_cmd_end_pass(vmg_device *dev)
{
    struct pipe_context *pipe = dev->pipe;
    end_visibility(dev);
    const vmg_pass_desc *pass = &dev->pass;
    // Resolves.
    const vmg_attachment *atts[VMG_MAX_COLOR + 2];
    unsigned n = 0;
    for (unsigned i = 0; i < VMG_MAX_COLOR; i++) atts[n++] = &pass->color[i];
    atts[n++] = &pass->depth;
    for (unsigned i = 0; i < n; i++) {
        const vmg_attachment *a = atts[i];
        if (!a->texture || !a->resolve || (a->store != VMG_STORE_RESOLVE && a->store != VMG_STORE_STORE_RESOLVE)) continue;
        struct pipe_blit_info b = {0};
        b.src.resource = a->texture->res;
        b.src.format = a->texture->format;
        b.src.level = a->texture->first_level + a->level;
        u_box_3d(0, 0, (int)(a->texture->first_layer + a->slice), (int)u_minify(a->texture->res->width0, b.src.level),
                 (int)u_minify(a->texture->res->height0, b.src.level), 1, &b.src.box);
        b.dst.resource = a->resolve->res;
        b.dst.format = a->resolve->format;
        b.dst.level = a->resolve->first_level + a->resolve_level;
        unsigned dl = a->resolve->res->target == PIPE_TEXTURE_3D ? a->resolve_depth_plane : a->resolve->first_layer + a->resolve_slice;
        u_box_3d(0, 0, (int)dl, b.src.box.width, b.src.box.height, 1, &b.dst.box);
        b.mask = util_format_is_depth_or_stencil(b.src.format) ? PIPE_MASK_Z : PIPE_MASK_RGBA;
        b.filter = PIPE_TEX_FILTER_NEAREST;
        pipe->blit(pipe, &b);
        vmg_texture_sync(dev, a->resolve, false);
    }
    // Store actions: discard what Metal does not keep (memoryless, dontCare on whole textures).
    for (unsigned i = 0; i < n; i++) {
        const vmg_attachment *a = atts[i];
        if (!a->texture) continue;
        if ((a->store == VMG_STORE_DONTCARE || a->store == VMG_STORE_RESOLVE) && a->texture->desc.memoryless && pipe->invalidate_resource)
            pipe->invalidate_resource(pipe, a->texture->res);
        else vmg_texture_sync(dev, a->texture, false);
    }
    dev->in_pass = false;
    // Neutral state: the pipeline objects of this pass may be released (on this queue) before the next one.
    pipe->bind_vertex_elements_state(pipe, dev->velems_empty);
    pipe->bind_blend_state(pipe, dev->blend_default);
    pipe->bind_fs_state(pipe, dev->fs_empty);
    pipe->bind_vs_state(pipe, NULL);
    pipe->bind_depth_stencil_alpha_state(pipe, dev->dsa_default);
    for (unsigned s = 0; s < 2; s++) {
        mesa_shader_stage gs = gl_stage((enum vmg_stage)s);
        pipe->set_sampler_views(pipe, gs, 0, 0, VMG_MAX_TEXTURES, NULL);
        pipe->set_shader_buffers(pipe, gs, 0, VMG_MAX_BUFFERS, NULL, 0);
        void *none[VMG_MAX_SAMPLERS + 16] = {0};
        for (unsigned k = 0; k < VMG_MAX_SAMPLERS + 16; k++) none[k] = dev->sampler_default;
        pipe->bind_sampler_states(pipe, gs, 0, VMG_MAX_SAMPLERS + 16, none);
    }
    dev->pipeline = NULL;
    dev->dsa = NULL;
}

// ---- State ----------------------------------------------------------------------------------------------------------

void vmg_cmd_set_render_pipeline(vmg_device *dev, vmg_render_pipeline *p)
{
    struct pipe_context *pipe = dev->pipe;
    dev->pipeline = p;
    pipe->bind_vs_state(pipe, p->desc.vertex ? p->desc.vertex->cso : NULL);
    pipe->bind_fs_state(pipe, p->fs_variant ? p->fs_variant : p->desc.fragment ? p->desc.fragment->cso : dev->fs_empty);
    pipe->bind_blend_state(pipe, p->blend);
    pipe->bind_vertex_elements_state(pipe, p->velems);
    pipe->set_sample_mask(pipe, 0xffffffff);
    if (dev->raster.rasterizer_discard != !p->desc.rasterization_enabled) {
        dev->raster.rasterizer_discard = !p->desc.rasterization_enabled;
        dev->raster_dirty = true;
    }
    for (unsigned s = 0; s < 2; s++) dev->stage[s].dirty_buffers = dev->stage[s].dirty_textures = dev->stage[s].dirty_samplers = ~0u;
}

void vmg_cmd_set_viewport(vmg_device *dev, const vmg_viewport *vp)
{
    struct pipe_viewport_state *v = &dev->viewport;
    v->scale[0] = (float)(vp->w * 0.5);
    v->scale[1] = (float)(-vp->h * 0.5);
    v->scale[2] = (float)(vp->zfar - vp->znear);
    v->translate[0] = (float)(vp->x + vp->w * 0.5);
    v->translate[1] = (float)(vp->y + vp->h * 0.5);
    v->translate[2] = (float)vp->znear;
    v->swizzle_x = PIPE_VIEWPORT_SWIZZLE_POSITIVE_X;
    v->swizzle_y = PIPE_VIEWPORT_SWIZZLE_POSITIVE_Y;
    v->swizzle_z = PIPE_VIEWPORT_SWIZZLE_POSITIVE_Z;
    v->swizzle_w = PIPE_VIEWPORT_SWIZZLE_POSITIVE_W;
    dev->pipe->set_viewport_states(dev->pipe, 0, 1, v);
}

void vmg_cmd_set_scissor(vmg_device *dev, uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    dev->scissor.minx = (uint16_t)MIN2(x, dev->fb.width);
    dev->scissor.miny = (uint16_t)MIN2(y, dev->fb.height);
    dev->scissor.maxx = (uint16_t)MIN2(x + w, dev->fb.width);
    dev->scissor.maxy = (uint16_t)MIN2(y + h, dev->fb.height);
    dev->pipe->set_scissor_states(dev->pipe, 0, 1, &dev->scissor);
}

void vmg_cmd_set_raster(vmg_device *dev, uint8_t cull, uint8_t winding, uint8_t fill, uint8_t depth_clip)
{
    struct pipe_rasterizer_state *r = &dev->raster;
    // MTLCullMode None 0, Front 1, Back 2. MTLWinding Clockwise 0, CounterClockwise 1: Metal evaluates the winding
    // in its y-up NDC; our viewport flips y, which reverses the orientation Gallium sees.
    r->cull_face = cull == 1 ? PIPE_FACE_FRONT : cull == 2 ? PIPE_FACE_BACK : PIPE_FACE_NONE;
    r->front_ccw = winding == 1;
    r->fill_front = r->fill_back = fill == 1 ? PIPE_POLYGON_MODE_LINE : PIPE_POLYGON_MODE_FILL;
    r->depth_clip_near = r->depth_clip_far = depth_clip == 0;   // MTLDepthClipModeClip 0, Clamp 1
    r->depth_clamp = depth_clip == 1;
    dev->raster_dirty = true;
}

void vmg_cmd_set_depth_bias(vmg_device *dev, float bias, float slope, float clamp)
{
    struct pipe_rasterizer_state *r = &dev->raster;
    r->offset_tri = r->offset_line = r->offset_point = bias != 0 || slope != 0;
    r->offset_units = bias;
    r->offset_scale = slope;
    r->offset_clamp = clamp;
    r->offset_units_unscaled = 0;
    dev->raster_dirty = true;
}

void vmg_cmd_set_dsa(vmg_device *dev, vmg_dsa *dsa)
{
    dev->dsa = dsa;
    dev->pipe->bind_depth_stencil_alpha_state(dev->pipe, dsa ? dsa->cso : dev->dsa_default);
}

void vmg_cmd_set_stencil_ref(vmg_device *dev, uint32_t front, uint32_t back)
{
    dev->stencil_ref.ref_value[0] = (uint8_t)front;
    dev->stencil_ref.ref_value[1] = (uint8_t)back;
    dev->pipe->set_stencil_ref(dev->pipe, dev->stencil_ref);
}

void vmg_cmd_set_blend_color(vmg_device *dev, const float rgba[4])
{
    struct pipe_blend_color c;
    memcpy(c.color, rgba, sizeof c.color);
    dev->pipe->set_blend_color(dev->pipe, &c);
}

void vmg_cmd_set_buffer(vmg_device *dev, enum vmg_stage stage, unsigned slot, vmg_resource *buf, size_t offset, size_t stride)
{
    if (slot >= VMG_MAX_BUFFERS) return;
    struct vmg_stage_bindings *b = &dev->stage[stage];
    struct pipe_shader_buffer *sb = &b->buffers[slot];
    sb->buffer = buf ? buf->res : NULL;
    sb->buffer_offset = (unsigned)offset;
    sb->buffer_size = buf ? (unsigned)(buf->res->width0 - offset) : 0;
    b->strides[slot] = (uint32_t)stride;
    b->dirty_buffers |= 1u << slot;
}

void vmg_cmd_set_buffer_offset(vmg_device *dev, enum vmg_stage stage, unsigned slot, size_t offset)
{
    if (slot >= VMG_MAX_BUFFERS) return;
    struct vmg_stage_bindings *b = &dev->stage[stage];
    struct pipe_shader_buffer *sb = &b->buffers[slot];
    if (!sb->buffer) return;
    sb->buffer_offset = (unsigned)offset;
    sb->buffer_size = (unsigned)(sb->buffer->width0 - offset);
    b->dirty_buffers |= 1u << slot;
}

void vmg_cmd_set_texture(vmg_device *dev, enum vmg_stage stage, unsigned slot, vmg_texture *tex)
{
    if (slot >= VMG_MAX_TEXTURES) return;
    static int trace = -1;
    if (trace < 0) trace = getenv("VMG_TRACE") != NULL;
    if (trace && tex)
        fprintf(stderr, "vmg: stage %d texture %u: %p %ux%u %s levels %u %s%s\n", stage, slot, (void *)tex, tex->res->width0, tex->res->height0,
                util_format_short_name(tex->res->format), tex->res->last_level + 1,
                tex->buffer ? "buffer-copy" : tex->surface_copy ? "surface-copy" : tex->surface_id ? "surface" : "plain",
                tex->parent ? " (view)" : "");
    dev->stage[stage].textures[slot] = tex;
    dev->stage[stage].dirty_textures |= 1u << slot;
}

void vmg_cmd_set_sampler(vmg_device *dev, enum vmg_stage stage, unsigned slot, vmg_sampler *s, float lod_min, float lod_max)
{
    (void)lod_min; (void)lod_max;
    if (slot >= VMG_MAX_SAMPLERS) return;
    static int trace_draw = -1;
    if (trace_draw < 0) trace_draw = getenv("VMG_TRACE_DRAW") != NULL;
    if (trace_draw && s)
        fprintf(stderr, "vmg: stage %d sampler %u: wrap %u %u filter %u %u norm %d border %.0f,%.0f,%.0f,%.0f\n", stage, slot,
                s->state.wrap_s, s->state.wrap_t, s->state.min_img_filter, s->state.mag_img_filter, !s->state.unnormalized_coords,
                s->state.border_color.f[0], s->state.border_color.f[1], s->state.border_color.f[2], s->state.border_color.f[3]);
    dev->stage[stage].samplers[slot] = s;
    dev->stage[stage].dirty_samplers |= 1u << slot;
}

// ---- Visibility (occlusion) queries ---------------------------------------------------------------------------------

typedef struct { struct pipe_query *q; vmg_resource *buffer; size_t offset; bool boolean; } vis_entry;
static vis_entry *g_vis;   // queries of the command buffers not yet flushed (GPU queue only)
static unsigned g_vis_count, g_vis_cap;

static void end_visibility(vmg_device *dev)
{
    if (!dev->occlusion) return;
    dev->pipe->end_query(dev->pipe, dev->occlusion);
    if (g_vis_count == g_vis_cap) { g_vis_cap = g_vis_cap ? g_vis_cap * 2 : 32; g_vis = realloc(g_vis, g_vis_cap * sizeof *g_vis); }
    g_vis[g_vis_count++] = (vis_entry){ dev->occlusion, dev->pass.visibility, dev->visibility_offset, dev->visibility_mode == 1 };
    dev->occlusion = NULL;
}

void vmg_cmd_set_visibility(vmg_device *dev, uint8_t mode, size_t offset)
{
    // MTLVisibilityResultMode: Disabled 0, Boolean 1, Counting 2
    end_visibility(dev);
    dev->visibility_mode = mode;
    dev->visibility_offset = offset;
    if (!mode || !dev->pass.visibility) return;
    dev->occlusion = dev->pipe->create_query(dev->pipe, mode == 1 ? PIPE_QUERY_OCCLUSION_PREDICATE : PIPE_QUERY_OCCLUSION_COUNTER, 0);
    if (dev->occlusion) dev->pipe->begin_query(dev->pipe, dev->occlusion);
}

// ---- Draw-time binding ----------------------------------------------------------------------------------------------

static void bind_stage(vmg_device *dev, enum vmg_stage stage, vmg_shader *sh, const uint32_t *extra_header, unsigned extra_words)
{
    struct pipe_context *pipe = dev->pipe;
    mesa_shader_stage gs = gl_stage(stage);
    struct vmg_stage_bindings *b = &dev->stage[stage];
    const vmg_reflection *r = &sh->refl;
    // Constant buffer 0: system values (buffer bases, grid, threadgroup offsets, sample count).
    uint32_t *header = dev->sysvals[stage];
    memset(header, 0, VMG_SYSVAL_HEADER);
    if (extra_header) memcpy(header, extra_header, extra_words * 4);
    header[12] = dev->pass.samples ? dev->pass.samples : 1;
    struct pipe_shader_buffer ssbo[VMG_MAX_BUFFERS];
    static int base_on = -1;
    if (base_on < 0) base_on = getenv("VMG_SSBO_BASE") != NULL;
    unsigned align_req = base_on ? MAX2(dev->screen->caps.shader_buffer_offset_alignment, 4) : 4;
    uint32_t used = r->buffers_used;
    unsigned count = used ? 32 - __builtin_clz(used) : 0;
    for (unsigned i = 0; i < count; i++) {
        ssbo[i] = b->buffers[i];
        if (!(used & (1u << i)) || !ssbo[i].buffer) { memset(&ssbo[i], 0, sizeof ssbo[i]); continue; }
        unsigned off = ssbo[i].buffer_offset, aligned = off & ~(align_req - 1);
        header[16 + i] = off - aligned;
        ssbo[i].buffer_offset = aligned;
        ssbo[i].buffer_size = ssbo[i].buffer->width0 - aligned;
    }
    pipe->set_shader_buffers(pipe, gs, 0, count, count ? ssbo : NULL, r->buffers_written);
    static int trace = -1;
    if (trace < 0) trace = getenv("VMG_TRACE") != NULL;
    if (trace)
        for (unsigned i = 0; i < count; i++)
            fprintf(stderr, "vmg: stage %d ssbo %u res %p off %u size %u base %u\n", stage, i, (void *)ssbo[i].buffer,
                    ssbo[i].buffer_offset, ssbo[i].buffer_size, header[16 + i]);
    struct pipe_constant_buffer cb = { .buffer = NULL, .buffer_offset = 0, .buffer_size = VMG_SYSVAL_HEADER, .user_buffer = header };
    pipe->set_constant_buffer(pipe, gs, 0, &cb);
    if (sh->pool_buffer) {
        struct pipe_constant_buffer pc = { .buffer = sh->pool_buffer, .buffer_offset = 0, .buffer_size = sh->pool_buffer->width0 };
        pipe->set_constant_buffer(pipe, gs, 1, &pc);
    }
    // Textures (sampler views) and images.
    struct pipe_sampler_view *views[VMG_MAX_TEXTURES] = {0};
    uint32_t tused = r->textures_used;
    unsigned tcount = tused ? 32 - __builtin_clz(tused) : 0;
    for (unsigned i = 0; i < tcount; i++) {
        vmg_texture *t = b->textures[i];
        if (!t || !(tused & (1u << i))) continue;
        if (!t->view) {
            struct pipe_sampler_view tmpl = {0};
            tmpl.format = t->format;
            tmpl.target = t->target;
            tmpl.swizzle_r = t->swizzle[0]; tmpl.swizzle_g = t->swizzle[1]; tmpl.swizzle_b = t->swizzle[2]; tmpl.swizzle_a = t->swizzle[3];
            if (t->target == PIPE_BUFFER) {
                tmpl.u.buf.offset = 0;
                tmpl.u.buf.size = t->res->width0;
            } else {
                tmpl.u.tex.first_level = t->first_level; tmpl.u.tex.last_level = t->last_level;
                tmpl.u.tex.first_layer = t->first_layer; tmpl.u.tex.last_layer = t->last_layer;
            }
            t->view = pipe->create_sampler_view(pipe, t->res, &tmpl);
        }
        if (t->surface_copy) vmg_texture_sync(dev, t, true);   // also inside a pass: CoreAnimation samples them in draws
        views[i] = t->view;
    }
    pipe->set_sampler_views(pipe, gs, 0, tcount, 0, views);
    uint32_t iused = r->textures_written;
    if (iused) {
        struct pipe_image_view img[VMG_MAX_TEXTURES];
        unsigned icount = 32 - __builtin_clz(iused);
        memset(img, 0, sizeof img);
        for (unsigned i = 0; i < icount; i++) {
            vmg_texture *t = b->textures[i];
            if (!t || !(iused & (1u << i))) continue;
            img[i].resource = t->res;
            img[i].format = t->format;
            img[i].access = img[i].shader_access = PIPE_IMAGE_ACCESS_READ_WRITE;
            if (t->target == PIPE_BUFFER) { img[i].u.buf.offset = 0; img[i].u.buf.size = t->res->width0; }
            else {
                img[i].u.tex.level = t->first_level;
                img[i].u.tex.first_layer = t->first_layer;
                img[i].u.tex.last_layer = t->last_layer;
                img[i].u.tex.single_layer_view = t->first_layer == t->last_layer && t->res->array_size > 1;
            }
        }
        pipe->set_shader_images(pipe, gs, 0, icount, 0, img);
    }
    // Samplers: Metal slots, then the shader's constexpr samplers.
    void *samplers[32] = {0};
    unsigned scount = 0;
    for (unsigned i = 0; i < VMG_MAX_SAMPLERS; i++) {
        if (!(r->samplers_used & (1u << i))) continue;
        samplers[i] = b->samplers[i] ? b->samplers[i]->cso : dev->sampler_default;
        scount = i + 1;
    }
    for (unsigned i = 0; i < r->constexpr_samplers; i++) {
        samplers[VMG_CONSTEXPR_SAMPLER_BASE + i] = sh->constexpr_samplers[i] ? sh->constexpr_samplers[i]->cso : dev->sampler_default;
        scount = VMG_CONSTEXPR_SAMPLER_BASE + i + 1;
    }
    for (unsigned i = 0; i < scount; i++) if (!samplers[i]) samplers[i] = dev->sampler_default;
    if (scount) pipe->bind_sampler_states(pipe, gs, 0, scount, samplers);
    if (trace && scount)
        for (unsigned i = 0; i < scount; i++)
            fprintf(stderr, "vmg: stage %d sampler %u %p%s\n", stage, i, samplers[i], samplers[i] == dev->sampler_default ? " (default)" : "");
}

static void flush_raster(vmg_device *dev)
{
    if (!dev->raster_dirty) return;
    struct hash_entry *he = _mesa_hash_table_search(dev->raster_cache, &dev->raster);
    void *cso;
    if (he) cso = he->data;
    else {
        struct pipe_rasterizer_state *key = malloc(sizeof *key);
        *key = dev->raster;
        cso = dev->pipe->create_rasterizer_state(dev->pipe, key);
        _mesa_hash_table_insert(dev->raster_cache, key, cso);
    }
    dev->pipe->bind_rasterizer_state(dev->pipe, cso);
    dev->raster_cso = cso;
    dev->raster_dirty = false;
}

static enum mesa_prim prim_of(uint8_t p)
{
    // MTLPrimitiveType: Point 0, Line 1, LineStrip 2, Triangle 3, TriangleStrip 4
    static const enum mesa_prim m[5] = { MESA_PRIM_POINTS, MESA_PRIM_LINES, MESA_PRIM_LINE_STRIP, MESA_PRIM_TRIANGLES, MESA_PRIM_TRIANGLE_STRIP };
    return p < 5 ? m[p] : MESA_PRIM_TRIANGLES;
}

void vmg_cmd_draw(vmg_device *dev, const vmg_draw_info *d)
{
    vmg_render_pipeline *p = dev->pipeline;
    if (!p || !p->desc.vertex) return;
    struct pipe_context *pipe = dev->pipe;
    flush_raster(dev);
    bind_stage(dev, VMG_VERTEX, p->desc.vertex, NULL, 0);
    if (p->desc.fragment) bind_stage(dev, VMG_FRAGMENT, p->desc.fragment, NULL, 0);
    static int trace_cb = -1;
    if (trace_cb < 0) trace_cb = getenv("VMG_TRACE_CB") != NULL;
    if (trace_cb) {
        const char *n = p->desc.fragment ? p->desc.fragment->name : p->desc.vertex->name;
        unsigned i = 0;
        while (i < dev->cb_fs_count && strcmp(dev->cb_fs[i], n)) i++;
        if (i == dev->cb_fs_count && i < 24) dev->cb_fs[dev->cb_fs_count++] = n;
        dev->cb_draws++;
    }
    static int trace_draw = -1;
    if (trace_draw < 0) trace_draw = getenv("VMG_TRACE_DRAW") != NULL;
    if (trace_draw) {
        const vmg_color_attachment *c = &p->desc.color[0];
        fprintf(stderr, "vmg: draw %s/%s prim %u count %u inst %u blend %d %u,%u,%u,%u op %u,%u mask %x scissor %u,%u-%u,%u%s%s\n",
                p->desc.vertex->name, p->desc.fragment ? p->desc.fragment->name : "-", d->primitive, d->count,
                d->instance_count, c->enabled, c->src_rgb, c->dst_rgb, c->src_alpha, c->dst_alpha, c->rgb_op, c->alpha_op,
                c->write_mask, dev->scissor.minx, dev->scissor.miny, dev->scissor.maxx, dev->scissor.maxy,
                dev->dsa ? " dsa" : "", p->fs_variant ? " variant" : "");
    }
    // Vertex buffers: the vertex stage's buffer slots the vertex descriptor reads.
    struct pipe_vertex_buffer vb[VMG_MAX_VERTEX_ATTRIBS];
    memset(vb, 0, sizeof vb);
    for (unsigned i = 0; i < p->velem_buffers; i++) {
        const struct pipe_shader_buffer *sb = &dev->stage[VMG_VERTEX].buffers[p->velem_buffer[i]];
        vb[i].buffer.resource = sb->buffer;
        vb[i].buffer_offset = sb->buffer_offset;
    }
    if (p->velem_buffers) pipe->set_vertex_buffers(pipe, p->velem_buffers, vb);

    struct pipe_draw_info info = {0};
    info.mode = prim_of(d->primitive);
    info.start_instance = d->base_instance;
    info.instance_count = MAX2(d->instance_count, 1);
    struct pipe_draw_start_count_bias draw = { .start = d->start, .count = d->count, .index_bias = 0 };
    if (d->index_buffer) {
        info.index_size = d->index_size;
        info.index.resource = d->index_buffer->res;
        info.primitive_restart = true;   // Metal always restarts strips at the all-ones index
        info.restart_index = d->index_size == 2 ? 0xffff : 0xffffffff;
        draw.start = (unsigned)(d->index_offset / d->index_size);
        draw.index_bias = d->base_vertex;
    }
    struct pipe_draw_indirect_info ind = {0};
    if (d->indirect) {
        ind.buffer = d->indirect->res;
        ind.offset = (unsigned)d->indirect_offset;
        ind.draw_count = 1;
        ind.stride = d->index_buffer ? 20 : 16;
    }
    pipe->draw_vbo(pipe, &info, 0, d->indirect ? &ind : NULL, &draw, 1);
}

void vmg_cmd_dispatch(vmg_device *dev, const vmg_dispatch_info *d)
{
    vmg_shader *k = d->pipeline->kernel;
    struct pipe_context *pipe = dev->pipe;
    uint32_t header[12] = {0};
    // Threadgroup arguments, packed after the shader's static threadgroup memory.
    uint32_t off = align(k->refl.static_shared, 16), dyn = 0;
    for (unsigned i = 0; i < 8; i++) {
        header[i] = off + dyn;
        if (k->refl.dynamic_shared_slots & (1u << i)) dyn += align(d->shared_sizes[i], 16);
    }
    for (unsigned i = 0; i < 3; i++) {
        uint32_t th = MAX2(d->threads[i], 1);
        header[8 + i] = d->grid[0] ? d->grid[i] : MAX2(d->groups[i], 1) * th;
    }
    pipe->bind_compute_state(pipe, k->cso);
    bind_stage(dev, VMG_COMPUTE, k, header, 12);
    struct pipe_grid_info g = {0};
    g.work_dim = 3;
    for (unsigned i = 0; i < 3; i++) {
        g.block[i] = MAX2(d->threads[i], 1);
        if (d->grid[0]) {
            uint32_t total = MAX2(d->grid[i], 1);
            g.grid[i] = DIV_ROUND_UP(total, g.block[i]);
            g.last_block[i] = total % g.block[i];
        } else g.grid[i] = MAX2(d->groups[i], 1);
    }
    g.variable_shared_mem = dyn;
    if (d->indirect) { g.indirect = d->indirect->res; g.indirect_offset = (unsigned)d->indirect_offset; }
    pipe->launch_grid(pipe, &g);
    // As after render passes: nothing of the kernel stays bound once it may be released.
    pipe->bind_compute_state(pipe, NULL);
    pipe->set_sampler_views(pipe, MESA_SHADER_COMPUTE, 0, 0, VMG_MAX_TEXTURES, NULL);
    pipe->set_shader_buffers(pipe, MESA_SHADER_COMPUTE, 0, VMG_MAX_BUFFERS, NULL, 0);
    pipe->set_shader_images(pipe, MESA_SHADER_COMPUTE, 0, 0, VMG_MAX_TEXTURES, NULL);
}

// ---- Blits ----------------------------------------------------------------------------------------------------------

void vmg_cmd_copy_buffer(vmg_device *dev, vmg_resource *src, size_t so, vmg_resource *dst, size_t doff, size_t size)
{
    struct pipe_box box;
    u_box_1d((int)so, (int)size, &box);
    dev->pipe->resource_copy_region(dev->pipe, dst->res, 0, (unsigned)doff, 0, 0, src->res, 0, &box);
}

void vmg_cmd_fill_buffer(vmg_device *dev, vmg_resource *dst, size_t off, size_t size, uint8_t value)
{
    uint32_t v = value * 0x01010101u;
    if (!(off & 3) && !(size & 3)) dev->pipe->clear_buffer(dev->pipe, dst->res, (unsigned)off, (unsigned)size, &v, 4);
    else dev->pipe->clear_buffer(dev->pipe, dst->res, (unsigned)off, (unsigned)size, &value, 1);
}

void vmg_cmd_copy_texture(vmg_device *dev, vmg_texture *src, unsigned ss, unsigned sl, uint32_t sx, uint32_t sy, uint32_t sz,
                          uint32_t w, uint32_t h, uint32_t d, vmg_texture *dst, unsigned ds, unsigned dl, uint32_t dx, uint32_t dy, uint32_t dz)
{
    static int trace_draw = -1;
    if (trace_draw < 0) trace_draw = getenv("VMG_TRACE_DRAW") != NULL;
    if (trace_draw)
        fprintf(stderr, "vmg: copy %p (%u,%u) %ux%u -> %p (%u,%u)\n", (void *)src, sx, sy, w, h, (void *)dst, dx, dy);
    vmg_texture_sync(dev, src, true);
    struct pipe_box box;
    unsigned slayer = src->res->target == PIPE_TEXTURE_3D ? sz : src->first_layer + ss;
    unsigned dlayer = dst->res->target == PIPE_TEXTURE_3D ? dz : dst->first_layer + ds;
    u_box_3d((int)sx, (int)sy, (int)slayer, (int)w, (int)h, (int)MAX2(d, 1), &box);
    if (util_format_get_blocksize(src->res->format) == util_format_get_blocksize(dst->res->format) &&
        src->res->nr_samples == dst->res->nr_samples)
        dev->pipe->resource_copy_region(dev->pipe, dst->res, dst->first_level + dl, dx, dy, dlayer, src->res, src->first_level + sl, &box);
    else {
        struct pipe_blit_info b = {0};
        b.src.resource = src->res; b.src.format = src->format; b.src.level = src->first_level + sl; b.src.box = box;
        b.dst.resource = dst->res; b.dst.format = dst->format; b.dst.level = dst->first_level + dl;
        u_box_3d((int)dx, (int)dy, (int)dlayer, (int)w, (int)h, (int)MAX2(d, 1), &b.dst.box);
        b.mask = util_format_get_mask(src->format);
        b.filter = PIPE_TEX_FILTER_NEAREST;
        dev->pipe->blit(dev->pipe, &b);
    }
    vmg_texture_sync(dev, dst, false);
}

void vmg_cmd_copy_buffer_to_texture(vmg_device *dev, vmg_resource *src, size_t off, size_t row_pitch, size_t image_pitch,
                                    vmg_texture *dst, unsigned slice, unsigned level, uint32_t x, uint32_t y, uint32_t z,
                                    uint32_t w, uint32_t h, uint32_t d)
{
    // Read the buffer through a synchronized map (waits for earlier GPU writes to it), then upload.
    struct pipe_box sbox;
    u_box_1d((int)off, (int)(image_pitch * MAX2(d, 1) ? image_pitch * MAX2(d, 1) : row_pitch * h), &sbox);
    if (sbox.x + sbox.width > (int)src->res->width0) sbox.width = (int)src->res->width0 - sbox.x;
    struct pipe_transfer *x0 = NULL;
    uint8_t *data = dev->pipe->buffer_map(dev->pipe, src->res, 0, PIPE_MAP_READ, &sbox, &x0);
    if (!data) return;
    vmg_texture_write(dev, dst, level, slice, x, y, z, w, h, d, data, row_pitch, image_pitch ? image_pitch : row_pitch * h);
    dev->pipe->buffer_unmap(dev->pipe, x0);
    vmg_texture_sync(dev, dst, false);
}

void vmg_cmd_copy_texture_to_buffer(vmg_device *dev, vmg_texture *src, unsigned slice, unsigned level, uint32_t x, uint32_t y,
                                    uint32_t z, uint32_t w, uint32_t h, uint32_t d, vmg_resource *dst, size_t off,
                                    size_t row_pitch, size_t image_pitch)
{
    vmg_texture_sync(dev, src, true);
    struct pipe_box dbox;
    size_t total = image_pitch ? image_pitch * MAX2(d, 1) : row_pitch * h;
    u_box_1d((int)off, (int)MIN2(total, dst->res->width0 - off), &dbox);
    struct pipe_transfer *x0 = NULL;
    uint8_t *out = dev->pipe->buffer_map(dev->pipe, dst->res, 0, PIPE_MAP_WRITE, &dbox, &x0);
    if (!out) return;
    vmg_texture_read(dev, src, level, slice, x, y, z, w, h, d, out, row_pitch, image_pitch ? image_pitch : row_pitch * h);
    dev->pipe->buffer_unmap(dev->pipe, x0);
}

void vmg_cmd_generate_mipmaps(vmg_device *dev, vmg_texture *t)
{
    util_gen_mipmap(dev->pipe, t->res, t->format, t->first_level, t->last_level, t->first_layer, t->last_layer,
                    PIPE_TEX_FILTER_LINEAR);
}

void vmg_cmd_barrier(vmg_device *dev)
{
    if (dev->pipe->memory_barrier) dev->pipe->memory_barrier(dev->pipe, PIPE_BARRIER_ALL);
    if (dev->pipe->texture_barrier && dev->in_pass) dev->pipe->texture_barrier(dev->pipe, PIPE_TEXTURE_BARRIER_SAMPLER);
}

// ---- Submission -----------------------------------------------------------------------------------------------------

struct vmg_fence_ext { struct vmg_fence base; vis_entry *vis; unsigned vis_count; bool resolved; };

void vmg_flush(vmg_device *dev, vmg_fence **out)
{
    dev->copy_epoch++;
    if (dev->cb_draws) {
        char line[512];
        int len = 0;
        for (unsigned i = 0; i < dev->cb_fs_count && len < (int)sizeof line - 1; i++)
            len += snprintf(line + len, sizeof line - (size_t)len, "%s%s", i ? " " : "", dev->cb_fs[i]);
        static int every = -1;   // VMG_TRACE_CB=2: every command buffer, not only when the set changes
        if (every < 0) every = getenv("VMG_TRACE_CB") && atoi(getenv("VMG_TRACE_CB")) >= 2;
        if (every || strcmp(line, dev->cb_last)) {
            fprintf(stderr, "vmg: cb: %u draws: %s\n", dev->cb_draws, line);
            memcpy(dev->cb_last, line, sizeof line);
        }
        dev->cb_fs_count = dev->cb_draws = 0;
    }
    struct pipe_fence_handle *f = NULL;
    dev->pipe->flush(dev->pipe, out || g_vis_count ? &f : NULL, 0);
    struct vmg_fence_ext *fe = NULL;
    if (out || g_vis_count) {
        fe = calloc(1, sizeof *fe);
        fe->base.fence = f;
        fe->vis = g_vis; fe->vis_count = g_vis_count;
        g_vis = NULL; g_vis_count = g_vis_cap = 0;
    }
    if (out) *out = &fe->base;
    else if (fe) {
        // Visibility results with no fence to wait on: wait now.
        vmg_fence_wait(dev, &fe->base, UINT64_MAX);
        vmg_fence_release(dev, &fe->base);
    }
}

static void resolve_visibility(vmg_device *dev, struct vmg_fence_ext *fe)
{
    if (fe->resolved) return;
    fe->resolved = true;
    // Metal: the value at an offset is the result of all the draws that used it in the pass (zeroed first).
    for (unsigned i = 0; i < fe->vis_count; i++) if (fe->vis[i].buffer && fe->vis[i].buffer->map)
        memset((uint8_t *)fe->vis[i].buffer->map + fe->vis[i].offset, 0, 8);
    for (unsigned i = 0; i < fe->vis_count; i++) {
        vis_entry *e = &fe->vis[i];
        union pipe_query_result r = {0};
        if (dev->pipe->get_query_result(dev->pipe, e->q, true, &r) && e->buffer && e->buffer->map) {
            uint64_t *slot = (uint64_t *)((uint8_t *)e->buffer->map + e->offset);
            if (e->boolean) *slot = *slot || r.b;
            else *slot += r.u64;
        }
        dev->pipe->destroy_query(dev->pipe, e->q);
    }
    free(fe->vis);
    fe->vis = NULL;
    fe->vis_count = 0;
}

bool vmg_fence_wait(vmg_device *dev, vmg_fence *fence, uint64_t timeout_ns)
{
    if (!fence) return true;
    struct vmg_fence_ext *fe = (struct vmg_fence_ext *)fence;
    bool done = !fence->fence || dev->screen->fence_finish(dev->screen, NULL, fence->fence, timeout_ns);
    if (done) resolve_visibility(dev, fe);
    return done;
}

void vmg_fence_release(vmg_device *dev, vmg_fence *fence)
{
    if (!fence) return;
    struct vmg_fence_ext *fe = (struct vmg_fence_ext *)fence;
    if (fe->vis_count) { vmg_fence_wait(dev, fence, UINT64_MAX); }
    if (fence->fence) dev->screen->fence_reference(dev->screen, &fence->fence, NULL);
    free(fe);
}
