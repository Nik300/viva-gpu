// Draw bounds on the CPU (P4 of docs/ANALISI-PRESTAZIONI-2026-11-06.md) and constant-colour clear draws (P5).
//
// P4: every CoreAnimation draw comes with a full-framebuffer scissor, and Panfrost renders a batch over the union of
// its draws' scissors: a pass that only redraws the dock still loads and stores 2.74 Mpx. The positions of a draw's
// few vertices are computed here, on the CPU, from the same AIR (translated to NIR once per vertex shader, with its own
// reflection) and the same bindings as the GPU will see; the draw then gets a scissor equal to their bounding box
// (one pixel of margin) intersected with Metal's. Only straight-line shaders made of a small set of operations are
// evaluated (constants, vertex attributes, constant/push/storage buffer loads, vertex/instance ids, float and integer
// arithmetic, selects); anything else, a buffer the GPU may have written, more than 64 vertices or instances, an
// indirect draw, a vertex behind the eye: no bounds, the scissor stays as Metal set it. VMG_NO_DRAW_BOUNDS=1: off.
//
// P5: a pass whose first draw writes constant colours with a fragment shader that does nothing else, blending off,
// full write masks, no depth/stencil state, over the whole framebuffer: replaced by pipe->clear (the tiles start from
// the clear colour instead of being loaded). VMG_NO_CLEAR_DRAW=1: off. CoreAnimation's attachment_clear is mostly not
// the first draw of its pass (it clears the clip mask mid-pass), so this rarely applies to it.
#include "vmg_internal.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "compiler/nir/nir.h"
#include "util/format/u_format.h"
#include "util/u_math.h"

#define BOUNDS_MAX_VERTICES 64
static const char *g_why;             // last reason a draw got no bounds (VMG_TRACE_DRAW=1)
#define FAIL(r) do { g_why = (r); return false; } while (0)
#define STR2(x) #x
#define STR(x) STR2(x)
#define RF do { g_why = "line " STR(__LINE__); return false; } while (0)
#define BOUNDS_MAX_DEFS     4096

struct vmg_shader_bounds {
    nir_shader *nir;                  // the vertex shader (single block), or a fragment shader with constant outputs
    vmg_reflection refl;              // of this translation (push window layout, buffers)
    uint8_t *pool; size_t pool_size;  // constant tables (constant buffer 1)
    // Fragment shaders (P5): colours written with constants, and their bits.
    uint32_t const_colors;
    uint32_t color_bits[VMG_MAX_COLOR][4];
};

static bool bounds_enabled(void)
{
    static int on = -1;
    if (on < 0) on = getenv("VMG_NO_DRAW_BOUNDS") == NULL;
    return on;
}

static bool clear_draw_enabled(void)
{
    static int on = -1;
    if (on < 0) on = getenv("VMG_NO_CLEAR_DRAW") == NULL;
    return on;
}

static bool single_block(nir_function_impl *impl)
{
    return exec_list_length(&impl->body) == 1;
}

static bool has_loop(struct exec_list *list)
{
    foreach_list_typed(nir_cf_node, node, node, list) {
        if (node->type == nir_cf_node_loop) return true;
        if (node->type == nir_cf_node_if) {
            nir_if *nif = nir_cf_node_as_if(node);
            if (has_loop(&nif->then_list) || has_loop(&nif->else_list)) return true;
        }
    }
    return false;
}

// Fragment shader made only of constant stores to colour outputs (no discard, no reads).
static bool analyze_constant_fs(struct vmg_shader_bounds *b)
{
    nir_function_impl *impl = nir_shader_get_entrypoint(b->nir);
    if (!single_block(impl)) return false;
    nir_foreach_block(block, impl) {
        nir_foreach_instr(instr, block) {
            if (instr->type == nir_instr_type_load_const || instr->type == nir_instr_type_deref) continue;
            if (instr->type != nir_instr_type_intrinsic) return false;
            nir_intrinsic_instr *in = nir_instr_as_intrinsic(instr);
            if (in->intrinsic != nir_intrinsic_store_deref) return false;
            nir_variable *var = nir_deref_instr_get_variable(nir_src_as_deref(in->src[0]));
            if (!var || var->data.mode != nir_var_shader_out || var->data.location < FRAG_RESULT_DATA0) return false;
            unsigned rt = var->data.location - FRAG_RESULT_DATA0;
            nir_def *v = in->src[1].ssa;
            if (rt >= VMG_MAX_COLOR || nir_def_instr(v)->type != nir_instr_type_load_const || v->bit_size != 32 ||
                nir_intrinsic_write_mask(in) != (1u << v->num_components) - 1)
                return false;
            nir_load_const_instr *lc = nir_instr_as_load_const(nir_def_instr(v));
            for (unsigned c = 0; c < 4; c++) b->color_bits[rt][c] = c < v->num_components ? lc->value[c].u32 : (c == 3 ? 0x3f800000u : 0);
            b->const_colors |= 1u << rt;
        }
    }
    return b->const_colors != 0;
}

struct vmg_shader_bounds *vmg_bounds_create(vmg_device *dev, const vmg_air_input *in, enum vmg_stage stage, const char *name)
{
    static int force = -1;   // VMG_DRAW_BOUNDS=1: also on llvmpipe (tests: a wrong box cuts pixels there too)
    if (force < 0) force = getenv("VMG_DRAW_BOUNDS") != NULL;
    if (!dev->panfrost && !force) return NULL;
    if (stage == VMG_VERTEX ? !bounds_enabled() : stage != VMG_FRAGMENT || !clear_draw_enabled() || !name || !strstr(name, "clear"))
        return NULL;
    struct util_dynarray pool;
    util_dynarray_init(&pool, NULL);
    struct vmg_shader_bounds *b = calloc(1, sizeof *b);
    vmg_air_input in2 = *in;
    in2.half32 = false;
    char *err = NULL;
    b->nir = vmg_air_translate(dev->screen->nir_options[MESA_SHADER_FRAGMENT], &in2, &b->refl, &pool, &err);
    free(err);
    bool ok = b->nir && b->nir->info.stage == (stage == VMG_VERTEX ? MESA_SHADER_VERTEX : MESA_SHADER_FRAGMENT);
    if (ok) {
        bool progress;
        do {
            progress = false;
            NIR_PASS(progress, b->nir, nir_lower_vars_to_ssa);
            NIR_PASS(progress, b->nir, nir_opt_copy_prop);
            NIR_PASS(progress, b->nir, nir_opt_constant_folding);
            NIR_PASS(progress, b->nir, nir_opt_dce);
            NIR_PASS(progress, b->nir, nir_opt_dead_cf);
        } while (progress);
        nir_function_impl *impl = nir_shader_get_entrypoint(b->nir);
        nir_index_ssa_defs(impl);
        ok = impl->ssa_alloc <= BOUNDS_MAX_DEFS && !has_loop(&impl->body);
        if (ok && stage == VMG_FRAGMENT) ok = analyze_constant_fs(b);
    }
    if (ok && pool.size) {
        b->pool = malloc(pool.size);
        memcpy(b->pool, pool.data, pool.size);
        b->pool_size = pool.size;
    }
    util_dynarray_fini(&pool);
    if (getenv("VMG_TRACE_BOUNDS_NIR") && b->nir) nir_print_shader(b->nir, stderr);
    if (getenv("VMG_TRACE_DRAW"))
        fprintf(stderr, "vmg: bounds %s %s: %s\n", stage == VMG_VERTEX ? "vertex" : "clear", name ? name : "?",
                ok ? "evaluated on the CPU" : !b->nir ? "no NIR" : has_loop(&nir_shader_get_entrypoint(b->nir)->body) ? "loop" : "not supported");
    if (!ok) { vmg_bounds_free(b); return NULL; }
    return b;
}

void vmg_bounds_free(struct vmg_shader_bounds *b)
{
    if (!b) return;
    ralloc_free(b->nir);
    free(b->pool);
    free(b);
}

// ---- Evaluation ------------------------------------------------------------------------------------------------------

typedef struct {
    vmg_device *dev;
    const vmg_render_pipeline *p;
    const struct vmg_shader_bounds *b;
    uint8_t header[VMG_SYSVAL_HEADER + VMG_PUSH_WINDOW];
    uint32_t (*v)[4];                 // SSA values (bits), by def index
    uint32_t vertex_id, vertex_zero_base, first_vertex, base_vertex, base_instance;
    float pos[4];
    bool pos_written;
    nir_block *prev_block;            // last block evaluated (phis pick their source by it)
} eval_ctx;

// CPU bytes of a buffer the GPU has not written (the push window's rule); NULL otherwise.
static const uint8_t *cpu_bytes(vmg_resource *res)
{
    if (!res || !res->res || res->gpu_writes) return NULL;
    return res->user_ptr && !res->cpu_access ? (const uint8_t *)res->user_ptr : (const uint8_t *)res->map;
}

static bool read_buffer(eval_ctx *e, unsigned slot, uint64_t off, void *dst, unsigned n)
{
    if (slot >= VMG_MAX_BUFFERS) RF;
    const struct vmg_stage_bindings *sb = &e->dev->stage[VMG_VERTEX];
    vmg_resource *res = sb->res[slot];
    const uint8_t *m = cpu_bytes(res);
    uint64_t at = sb->buffers[slot].buffer_offset + off;
    if (!m || !sb->buffers[slot].buffer || at + n > res->res->width0) RF;
    memcpy(dst, m + at, n);
    return true;
}

// Constant buffer 0 as bind_stage builds it for this translation's reflection.
static bool build_header(eval_ctx *e)
{
    const vmg_reflection *r = &e->b->refl;
    memset(e->header, 0, sizeof e->header);
    uint32_t *h = (uint32_t *)e->header;
    for (uint32_t p = r->push_slots; p; p &= p - 1) {
        unsigned slot = __builtin_ctz(p), size = r->push_size[slot];
        if (VMG_SYSVAL_HEADER + r->push_offset[slot] + size > sizeof e->header) RF;
        uint8_t *dst = e->header + VMG_SYSVAL_HEADER + r->push_offset[slot];
        const struct vmg_stage_bindings *sb = &e->dev->stage[VMG_VERTEX];
        vmg_resource *res = sb->res[slot];
        if (!res || !res->res) continue;   // zeros, as bind_stage
        size_t off = sb->buffers[slot].buffer_offset;
        if (off >= res->res->width0) continue;
        const uint8_t *m = cpu_bytes(res);
        if (!m) RF;
        unsigned n = (unsigned)MIN2((size_t)size, res->res->width0 - off);
        memcpy(dst, m + off, n);
    }
    h[12] = e->dev->pass.samples ? e->dev->pass.samples : 1;
    return true;   // header[16 + i] (SSBO base remainders) stay 0: offsets are 4-byte aligned without VMG_SSBO_BASE
}

static bool fetch_attrib(eval_ctx *e, unsigned attr, unsigned vertex, uint32_t out[4])
{
    const vmg_render_pipeline_desc *d = &e->p->desc;
    out[0] = out[1] = out[2] = 0;
    out[3] = 0x3f800000u;
    if (attr >= VMG_MAX_VERTEX_ATTRIBS || !(d->attrib_mask & (1u << attr))) return true;   // unbound: (0, 0, 0, 1)
    const vmg_vertex_attrib *a = &d->attribs[attr];
    if (a->buffer >= VMG_MAX_BUFFERS) RF;
    const vmg_vertex_layout *l = &d->layouts[a->buffer];
    unsigned index = l->step_function == 1 ? vertex : l->step_function == 2 ? e->base_instance / MAX2(l->step_rate, 1) : 0;
    enum pipe_format f = vmg_vertex_format(a->format);
    const struct util_format_description *desc = util_format_description(f);
    if (f == PIPE_FORMAT_NONE || !desc || desc->block.bits % 8) RF;
    uint8_t raw[16];
    unsigned bytes = desc->block.bits / 8;
    if (bytes > sizeof raw || !read_buffer(e, a->buffer, (uint64_t)index * l->stride + a->offset, raw, bytes)) RF;
    if (util_format_is_pure_integer(f)) {
        uint32_t ui[4] = { 0, 0, 0, 1 };
        util_format_unpack_rgba(f, ui, raw, 1);
        memcpy(out, ui, sizeof ui);
    } else {
        float fl[4] = { 0, 0, 0, 1 };
        util_format_unpack_rgba(f, fl, raw, 1);
        memcpy(out, fl, sizeof fl);
    }
    return true;
}

static inline float F(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static inline uint32_t U(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

static uint32_t mask_bits(uint32_t v, unsigned bits) { return bits >= 32 ? v : bits == 1 ? (v != 0) : v & ((1u << bits) - 1); }
static int32_t sext(uint32_t v, unsigned bits) { return bits >= 32 ? (int32_t)v : (int32_t)(v << (32 - bits)) >> (32 - bits); }

static bool eval_alu(eval_ctx *e, nir_alu_instr *alu)
{
    const nir_op_info *info = &nir_op_infos[alu->op];
    unsigned nc = alu->def.num_components, bits = alu->def.bit_size;
    uint32_t *dst = e->v[alu->def.index];
    for (unsigned c = 0; c < nc; c++) {
        uint32_t s[4] = { 0 };
        unsigned sb[4] = { 0 };
        for (unsigned i = 0; i < info->num_inputs && i < 4; i++) {
            unsigned comp = info->input_sizes[i] == 0 ? alu->src[i].swizzle[c] : alu->src[i].swizzle[0];
            s[i] = e->v[alu->src[i].src.ssa->index][comp];
            sb[i] = alu->src[i].src.ssa->bit_size;
        }
        // Float operations: 32-bit only.
        bool fop = info->output_type == nir_type_float || (info->num_inputs && info->input_types[0] == nir_type_float);
        if (fop && (bits != 32 && info->output_type == nir_type_float)) RF;
        if (fop && info->num_inputs && sb[0] != 32 && alu->op != nir_op_b2f32) RF;
        uint32_t r;
        switch (alu->op) {
        case nir_op_mov: r = s[0]; break;
        case nir_op_vec2: case nir_op_vec3: case nir_op_vec4: {
            unsigned comp = alu->src[c].swizzle[0];
            r = e->v[alu->src[c].src.ssa->index][comp];
            break;
        }
        case nir_op_fadd: r = U(F(s[0]) + F(s[1])); break;
        case nir_op_fsub: r = U(F(s[0]) - F(s[1])); break;
        case nir_op_fmul: r = U(F(s[0]) * F(s[1])); break;
        case nir_op_ffma: r = U(fmaf(F(s[0]), F(s[1]), F(s[2]))); break;
        case nir_op_fneg: r = U(-F(s[0])); break;
        case nir_op_fabs: r = U(fabsf(F(s[0]))); break;
        case nir_op_fmin: r = U(fminf(F(s[0]), F(s[1]))); break;
        case nir_op_fmax: r = U(fmaxf(F(s[0]), F(s[1]))); break;
        case nir_op_fsat: r = U(fminf(fmaxf(F(s[0]), 0.0f), 1.0f)); break;
        case nir_op_frcp: r = U(1.0f / F(s[0])); break;
        case nir_op_fdiv: r = U(F(s[0]) / F(s[1])); break;
        case nir_op_ffloor: r = U(floorf(F(s[0]))); break;
        case nir_op_fceil: r = U(ceilf(F(s[0]))); break;
        case nir_op_ftrunc: r = U(truncf(F(s[0]))); break;
        case nir_op_fsqrt: r = U(sqrtf(F(s[0]))); break;
        case nir_op_frsq: r = U(1.0f / sqrtf(F(s[0]))); break;
        case nir_op_flt: r = F(s[0]) < F(s[1]); break;
        case nir_op_fge: r = F(s[0]) >= F(s[1]); break;
        case nir_op_feq: r = F(s[0]) == F(s[1]); break;
        case nir_op_fneu: r = F(s[0]) != F(s[1]); break;
        case nir_op_iadd: r = s[0] + s[1]; break;
        case nir_op_isub: r = s[0] - s[1]; break;
        case nir_op_imul: r = s[0] * s[1]; break;
        case nir_op_ineg: r = -s[0]; break;
        case nir_op_ishl: r = s[0] << (s[1] & (bits - 1)); break;
        case nir_op_ushr: r = mask_bits(s[0], bits) >> (s[1] & (bits - 1)); break;
        case nir_op_ishr: r = (uint32_t)(sext(s[0], bits) >> (s[1] & (bits - 1))); break;
        case nir_op_iand: r = s[0] & s[1]; break;
        case nir_op_ior: r = s[0] | s[1]; break;
        case nir_op_ixor: r = s[0] ^ s[1]; break;
        case nir_op_inot: r = ~s[0]; break;
        case nir_op_imin: r = (uint32_t)MIN2(sext(s[0], sb[0]), sext(s[1], sb[1])); break;
        case nir_op_imax: r = (uint32_t)MAX2(sext(s[0], sb[0]), sext(s[1], sb[1])); break;
        case nir_op_umin: r = MIN2(mask_bits(s[0], sb[0]), mask_bits(s[1], sb[1])); break;
        case nir_op_umax: r = MAX2(mask_bits(s[0], sb[0]), mask_bits(s[1], sb[1])); break;
        case nir_op_ieq: r = mask_bits(s[0], sb[0]) == mask_bits(s[1], sb[1]); break;
        case nir_op_ine: r = mask_bits(s[0], sb[0]) != mask_bits(s[1], sb[1]); break;
        case nir_op_ilt: r = sext(s[0], sb[0]) < sext(s[1], sb[1]); break;
        case nir_op_ige: r = sext(s[0], sb[0]) >= sext(s[1], sb[1]); break;
        case nir_op_ult: r = mask_bits(s[0], sb[0]) < mask_bits(s[1], sb[1]); break;
        case nir_op_uge: r = mask_bits(s[0], sb[0]) >= mask_bits(s[1], sb[1]); break;
        case nir_op_bcsel: r = (s[0] & 1) ? s[1] : s[2]; break;
        case nir_op_b2f32: r = (s[0] & 1) ? 0x3f800000u : 0; break;
        case nir_op_b2i32: r = s[0] & 1; break;
        case nir_op_i2f32: r = U((float)sext(s[0], sb[0])); break;
        case nir_op_u2f32: r = U((float)mask_bits(s[0], sb[0])); break;
        case nir_op_f2i32: r = (uint32_t)(int32_t)F(s[0]); break;
        case nir_op_f2u32: r = (uint32_t)F(s[0]); break;
        case nir_op_u2u8: case nir_op_u2u16: case nir_op_u2u32: r = mask_bits(s[0], MIN2(sb[0], bits)); break;
        case nir_op_i2i8: case nir_op_i2i16: case nir_op_i2i32: r = (uint32_t)sext(s[0], sb[0]); break;
        default: g_why = nir_op_infos[alu->op].name; RF;
        }
        // 1-bit results are stored as 0/1; 32-bit booleans would be ~0: none of the ops above produce those.
        dst[c] = mask_bits(r, bits);
    }
    return true;
}

static bool const_index(nir_src s, eval_ctx *e, uint32_t *out)
{
    if (nir_src_is_const(s)) { *out = nir_src_as_uint(s); return true; }
    *out = e->v[s.ssa->index][0];
    return true;
}

static bool eval_intrinsic(eval_ctx *e, nir_intrinsic_instr *in, unsigned vertex)
{
    uint32_t *dst = nir_intrinsic_infos[in->intrinsic].has_dest ? e->v[in->def.index] : NULL;
    switch (in->intrinsic) {
    case nir_intrinsic_load_deref: {
        nir_variable *var = nir_deref_instr_get_variable(nir_src_as_deref(in->src[0]));
        if (!var || var->data.mode != nir_var_shader_in || var->data.location < VERT_ATTRIB_GENERIC0 || in->def.bit_size != 32)
            FAIL("input variable");
        uint32_t a[4];
        if (!fetch_attrib(e, var->data.location - VERT_ATTRIB_GENERIC0, vertex, a)) FAIL("attribute fetch");
        for (unsigned c = 0; c < in->def.num_components; c++) dst[c] = a[MIN2(c + var->data.location_frac, 3)];
        return true;
    }
    case nir_intrinsic_store_deref: {
        nir_variable *var = nir_deref_instr_get_variable(nir_src_as_deref(in->src[0]));
        if (!var || var->data.mode != nir_var_shader_out) RF;
        if (var->data.location != VARYING_SLOT_POS) return true;   // other outputs do not move the vertex
        if (in->src[1].ssa->bit_size != 32) RF;
        unsigned wm = nir_intrinsic_write_mask(in);
        for (unsigned c = 0; c < in->src[1].ssa->num_components && c + var->data.location_frac < 4; c++)
            if (wm & (1u << c)) e->pos[c + var->data.location_frac] = F(e->v[in->src[1].ssa->index][c]);
        e->pos_written = true;
        return true;
    }
    case nir_intrinsic_load_ubo: {
        uint32_t block, off;
        if (in->def.bit_size != 32 || !const_index(in->src[0], e, &block) || !const_index(in->src[1], e, &off)) RF;
        unsigned n = in->def.num_components * 4;
        if (block == 0) {
            if ((uint64_t)off + n > sizeof e->header) RF;
            memcpy(dst, e->header + off, n);
        } else if (block == 1) {
            if (!e->b->pool || (uint64_t)off + n > e->b->pool_size) RF;
            memcpy(dst, e->b->pool + off, n);
        } else RF;
        return true;
    }
    case nir_intrinsic_load_ssbo: {
        uint32_t slot, off;
        if (in->def.bit_size != 32 || !const_index(in->src[0], e, &slot) || !const_index(in->src[1], e, &off)) RF;
        if (!read_buffer(e, slot, off, dst, in->def.num_components * 4)) FAIL("storage buffer not readable");
        return true;
    }
    case nir_intrinsic_load_vertex_id: dst[0] = e->vertex_id; return true;
    case nir_intrinsic_load_vertex_id_zero_base: dst[0] = e->vertex_zero_base; return true;
    case nir_intrinsic_load_first_vertex: dst[0] = e->first_vertex; return true;
    case nir_intrinsic_load_base_vertex: dst[0] = e->base_vertex; return true;
    case nir_intrinsic_load_instance_id: dst[0] = 0; return true;
    case nir_intrinsic_load_base_instance: dst[0] = e->base_instance; return true;
    default: g_why = nir_intrinsic_infos[in->intrinsic].name; RF;
    }
}

static bool eval_block(eval_ctx *e, nir_block *block, unsigned vertex)
{
    nir_foreach_instr(instr, block) {
        switch (instr->type) {
        case nir_instr_type_deref: break;
        case nir_instr_type_load_const: {
            nir_load_const_instr *lc = nir_instr_as_load_const(instr);
            if (lc->def.bit_size == 64) RF;
            for (unsigned c = 0; c < lc->def.num_components; c++)
                e->v[lc->def.index][c] = lc->def.bit_size == 1 ? lc->value[c].b : lc->value[c].u32;
            break;
        }
        case nir_instr_type_undef: {
            nir_undef_instr *u = nir_instr_as_undef(instr);
            memset(e->v[u->def.index], 0, 16);
            break;
        }
        case nir_instr_type_phi: {
            // the value from the branch just taken (structured control flow: its last block)
            nir_phi_instr *phi = nir_instr_as_phi(instr);
            bool found = false;
            nir_foreach_phi_src(src, phi) {
                if (src->pred == e->prev_block) {
                    memcpy(e->v[phi->def.index], e->v[src->src.ssa->index], 16);
                    found = true;
                }
            }
            if (!found) RF;
            break;
        }
        case nir_instr_type_alu:
            if (nir_instr_as_alu(instr)->def.bit_size == 64) RF;
            if (!eval_alu(e, nir_instr_as_alu(instr))) return false;   // its reason
            break;
        case nir_instr_type_intrinsic:
            if (!eval_intrinsic(e, nir_instr_as_intrinsic(instr), vertex)) return false;
            break;
        default: FAIL("instruction type");
        }
    }
    e->prev_block = block;
    return true;
}

static bool eval_list(eval_ctx *e, struct exec_list *list, unsigned vertex)
{
    foreach_list_typed(nir_cf_node, node, node, list) {
        switch (node->type) {
        case nir_cf_node_block:
            if (!eval_block(e, nir_cf_node_as_block(node), vertex)) return false;
            break;
        case nir_cf_node_if: {
            nir_if *nif = nir_cf_node_as_if(node);
            bool cond = e->v[nif->condition.ssa->index][0] & 1;
            if (!eval_list(e, cond ? &nif->then_list : &nif->else_list, vertex)) return false;
            break;
        }
        default: FAIL("loop");
        }
    }
    return true;
}

static bool eval_vertex(eval_ctx *e, unsigned vertex)
{
    nir_function_impl *impl = nir_shader_get_entrypoint(e->b->nir);
    e->pos_written = false;
    e->prev_block = NULL;
    if (!eval_list(e, &impl->body, vertex)) return false;
    if (!e->pos_written) FAIL("no position");
    return true;
}

static bool read_index(const vmg_draw_info *d, unsigned i, uint32_t *out)
{
    const uint8_t *m = cpu_bytes(d->index_buffer);
    uint64_t at = d->index_offset + (uint64_t)i * d->index_size;
    if (!m || at + d->index_size > d->index_buffer->res->width0) RF;
    if (d->index_size == 2) { uint16_t v; memcpy(&v, m + at, 2); *out = v; }
    else if (d->index_size == 4) memcpy(out, m + at, 4);
    else RF;
    return true;
}

bool vmg_bounds_draw(vmg_device *dev, const vmg_render_pipeline *p, const vmg_draw_info *d, struct pipe_scissor_state *out)
{
    const struct vmg_shader_bounds *b = p->desc.vertex ? p->desc.vertex->bounds : NULL;
    if (!b) RF;
    if (d->indirect || d->count == 0 || d->count > BOUNDS_MAX_VERTICES || d->instance_count > 1 ||
        (d->primitive != 3 && d->primitive != 4) || !p->desc.rasterization_enabled)
        FAIL("draw kind");
    nir_function_impl *impl = nir_shader_get_entrypoint(b->nir);
    static _Thread_local uint32_t (*vals)[4];   // per replay thread (one GPU queue per device)
    static _Thread_local unsigned vals_cap;
    if (vals_cap < impl->ssa_alloc) {
        free(vals);
        vals_cap = MAX2(impl->ssa_alloc, 256);
        vals = calloc(vals_cap, sizeof *vals);
        if (!vals) { vals_cap = 0; RF; }
    }
    eval_ctx e = { .dev = dev, .p = p, .b = b, .v = vals, .base_instance = d->base_instance };
    if (!build_header(&e)) FAIL("push window not readable");
    const struct pipe_viewport_state *vp = &dev->viewport;
    float minx = INFINITY, miny = INFINITY, maxx = -INFINITY, maxy = -INFINITY;
    for (unsigned i = 0; i < d->count; i++) {
        uint32_t index = d->start + i;
        if (d->index_buffer) {
            if (!read_index(d, d->start + i, &index)) RF;
            if ((d->index_size == 2 && index == 0xffff) || (d->index_size == 4 && index == 0xffffffffu)) continue;   // restart
            e.vertex_zero_base = index;
            e.base_vertex = (uint32_t)d->base_vertex;
            e.first_vertex = (uint32_t)d->base_vertex;
            index += (uint32_t)d->base_vertex;
        } else {
            e.vertex_zero_base = i;
            e.base_vertex = 0;
            e.first_vertex = d->start;
        }
        e.vertex_id = index;
        if (!eval_vertex(&e, index)) return false;   // its reason
        float w = e.pos[3];
        if (!(w > 1e-6f) || !isfinite(e.pos[0]) || !isfinite(e.pos[1])) FAIL("w <= 0");   // behind the eye: clipping
        float x = vp->translate[0] + vp->scale[0] * (e.pos[0] / w);
        float y = vp->translate[1] + vp->scale[1] * (e.pos[1] / w);
        minx = MIN2(minx, x); maxx = MAX2(maxx, x);
        miny = MIN2(miny, y); maxy = MAX2(maxy, y);
    }
    if (!(minx <= maxx) || !(miny <= maxy)) RF;
    // One pixel of margin around the vertices (rasterization rules, rounding), then Metal's scissor.
    const struct pipe_scissor_state *s = &dev->scissor;
    float x0 = floorf(minx) - 1, y0 = floorf(miny) - 1, x1 = ceilf(maxx) + 1, y1 = ceilf(maxy) + 1;
    out->minx = (uint16_t)CLAMP(x0, (float)s->minx, (float)s->maxx);
    out->miny = (uint16_t)CLAMP(y0, (float)s->miny, (float)s->maxy);
    out->maxx = (uint16_t)CLAMP(x1, (float)out->minx, (float)s->maxx);
    out->maxy = (uint16_t)CLAMP(y1, (float)out->miny, (float)s->maxy);
    return true;
}

const char *vmg_bounds_why(void) { return g_why ? g_why : "?"; }

bool vmg_bounds_clear_colors(const vmg_shader *fs, uint32_t *mask, uint32_t bits[][4])
{
    const struct vmg_shader_bounds *b = fs ? fs->bounds : NULL;
    if (!b || !b->const_colors) return false;
    *mask = b->const_colors;
    memcpy(bits, b->color_bits, sizeof b->color_bits);
    return true;
}
