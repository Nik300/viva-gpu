// Viva ISA compiler: stage inputs and outputs (B1-B11), FAU and sysvals, following the v9 ABI that Gallium's
// Panfrost driver expects (docs/ISA-ABI-V9.md).
//
// Vertex (IDVS, malloc mode): attributes with LD_ATTR_IMM (table 1, index = [[attribute(n)]], which is the vertex
// element index vmg creates), vertex id = r60 (base included), instance id = r61 + base_instance (sysval).
// Outputs go to the IDVS buffers through LEA_BUF_IMM (table 61) + STORE: the position, viewport-transformed by the
// shader (sysvals VIEWPORT_SCALE/OFFSET, w = 1/w), point size as f16, varyings at the offsets of our own layout
// (every varying 32 bits per component). The program is compiled three times: position, position without point
// size, varyings (vmg_isa.c lays them out).
// Fragment: varyings with LD_VAR_IMM / LD_VAR_FLAT_IMM through the attribute table (the FS slot index), so the
// binary does not depend on the vertex shader's layout; frag coord from r59 (+0.5) and LD_VAR_SPECIAL; outputs
// with ATEST (coverage r60), ZS_EMIT, then BLEND per render target with the colour in r0-r3 (blend shaders may
// clobber r0-r15 and r48). FAU words 0-3 are the blend constants (sysval 0), which blend shaders read.
// Compute: ids from preloads (r55-r62), sizes from sysvals, threads_per_grid from our constant buffer 0.
#include "vi_sel.h"
#include <string.h>

// ---- Metadata -------------------------------------------------------------------------------------------------------

typedef struct { LLVMValueRef ops[64]; unsigned n; } mdops;

static void md_operands(LLVMValueRef node, mdops *o)
{
    o->n = node ? ts_LLVMGetMDNodeNumOperands(node) : 0;
    if (o->n > 64) o->n = 64;
    if (o->n) {
        LLVMValueRef tmp[256];
        ts_LLVMGetMDNodeOperands(node, tmp);
        memcpy(o->ops, tmp, o->n * sizeof(LLVMValueRef));
    }
}

static const char *md_string(LLVMValueRef v, unsigned *len) { *len = 0; return v ? ts_LLVMGetMDString(v, len) : NULL; }

static bool md_is(LLVMValueRef v, const char *str)
{
    unsigned len;
    const char *s = md_string(v, &len);
    return s && len == strlen(str) && !memcmp(s, str, len);
}

static bool md_has(const mdops *o, const char *str)
{
    for (unsigned i = 0; i < o->n; i++) if (md_is(o->ops[i], str)) return true;
    return false;
}

static long md_int_after(const mdops *o, const char *key, long fallback)
{
    for (unsigned i = 0; i + 1 < o->n; i++)
        if (md_is(o->ops[i], key) && o->ops[i + 1] && ts_LLVMIsAConstantInt(o->ops[i + 1]))
            return (long)ts_LLVMConstIntGetSExtValue(o->ops[i + 1]);
    return fallback;
}

static int varying_slot(S *t, const char *key, unsigned len)
{
    for (unsigned i = 0; i < t->in->varying_count; i++)
        if (strlen(t->in->varyings[i]) == len && !memcmp(t->in->varyings[i], key, len)) return (int)i;
    return -1;
}

// ---- FAU, sysvals ---------------------------------------------------------------------------------------------------

vi_ref sel_fau_ubo(S *t, unsigned ubo, unsigned byte_offset)
{
    struct pan_fau_layout *f = t->fau;
    for (unsigned i = 0; i < f->count; i++)
        if (!BITSET_TEST(f->is_const, i) && f->words[i].relocation.ubo == ubo && f->words[i].relocation.offset == byte_offset)
            return vi_fau(i);
    if (f->count >= f->max) return vi_none();
    struct pan_ubo_relocation r = { (uint16_t)ubo, (uint16_t)byte_offset };
    return vi_fau(pan_fau_emit_reloc(f, r));
}

vi_ref sel_fau_const_pair(S *t, uint32_t lo, uint32_t hi)
{
    struct pan_fau_layout *f = t->fau;
    for (unsigned i = 0; i + 1 < f->count; i += 2)
        if (BITSET_TEST(f->is_const, i) && BITSET_TEST(f->is_const, i + 1) && f->words[i].constant == lo && f->words[i + 1].constant == hi) {
            vi_ref r = vi_fau(i); r.count = 2; return r;
        }
    if (f->count & 1) pan_fau_emit_const(f, 0);   // pairs start on an even word
    if (f->count + 2 > f->max) return vi_none();
    unsigned w = pan_fau_emit_const(f, lo);
    pan_fau_emit_const(f, hi);
    vi_ref r = vi_fau(w); r.count = 2;
    return r;
}

unsigned sel_sysval(S *t, unsigned type, unsigned id)
{
    unsigned v = (id << 16) | type;
    for (unsigned i = 0; i < t->nsysvals; i++) if (t->sysvals[i] == v) return i;
    if (t->nsysvals >= 32) return 31;
    t->sysvals[t->nsysvals] = v;
    return t->nsysvals++;
}

vi_ref sel_sysval_comp(S *t, unsigned type, unsigned id, unsigned comp)
{
    unsigned i = sel_sysval(t, type, id);
    vi_ref r = sel_fau_ubo(t, VI_UBO_SYSVALS, 16 * i + 4 * comp);
    if (r.kind) return r;
    // FAU full: load from the sysval UBO
    t->ubo_mask |= 1u << VI_UBO_SYSVALS;
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_LD_PKA_I32);
    I->sw = d; I->src[0] = vi_imm(16 * i + 4 * comp); I->src[1] = vi_imm(VI_UBO_SYSVALS);
    return d;
}

vi_ref sel_pair(S *t, vi_ref lo, vi_ref hi)
{
    uint32_t v = vi_new_vreg(t->s, 2);
    vi_ref parts[2] = { lo, hi };
    for (unsigned k = 0; k < 2; k++) {
        vi_instr *I = parts[k].kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
        if (parts[k].kind == VI_IMM) vi_set(I, VAF_imm1w, parts[k].value); else I->src[0] = parts[k];
        I->dest = vi_vreg(v, k, 1);
    }
    return vi_vreg(v, 0, 2);
}

// PAN_SYSVAL_* types (gallium/drivers/panfrost/pan_context.h)
enum { SYS_VIEWPORT_SCALE = 1, SYS_VIEWPORT_OFFSET = 2, SYS_NUM_WORK_GROUPS = 5, SYS_LOCAL_GROUP_SIZE = 8,
       SYS_RT_CONVERSION = 13, SYS_VERTEX_INSTANCE_OFFSETS = 14, SYS_BLEND_CONSTANTS = 16 };

// ---- I/O state ------------------------------------------------------------------------------------------------------

enum { O_NONE, O_POSITION, O_VARYING, O_PSIZE, O_COLOR, O_DEPTH, O_SAMPLE_MASK };

typedef struct {
    struct { int kind; int slot; unsigned ncomp; bool flt, sint; unsigned bits; sv *val; unsigned index; } out[40];
    unsigned nout;
    bool color_float[8];
    sv *instance_id;
} IO;

static IO *io(S *t) { return t->io; }

// Values copied out at `ret` live in multi-definition registers, written on every path that returns.
static sv *out_reg(S *t, unsigned bits, unsigned n)
{
    sv *v = sv_val(t, bits, n);
    vi_vreg_get(t->s, v->vreg)->multi_def = true;
    return v;
}

static vi_ref preload(S *t, unsigned reg) { return sel_mov32(t, vi_reg(reg)); }

// ---- Vertex inputs (B1, B2) -----------------------------------------------------------------------------------------

static sv *vertex_input(S *t, unsigned loc, unsigned bits, unsigned n, bool flt)
{
    USE(t, B1);
    t->info.attributes_read |= 1u << loc;
    t->refl->vertex_inputs |= 1u << loc;
    sv *raw = sv_val(t, 32, 4);
    vi_instr *I;
    if (loc < 16) {
        I = E(t, VA_LD_ATTR_IMM);
        vi_set(I, VAF_encoded_attribute_table_index, 1);
        vi_set(I, VAF_attribute_index, loc);
    } else {
        I = E(t, VA_LD_ATTR);
        I->src[2] = vi_imm((1u << 24) | loc);
    }
    I->sw = vi_vreg(raw->vreg, 0, 4);
    I->src[0] = vi_reg(60);
    I->src[1] = sv_word(t, io(t)->instance_id, 0);
    vi_set(I, VAF_register_format, flt ? VA_REGISTER_FILE_FORMAT_GENERAL_M_F32 : VA_REGISTER_FILE_FORMAT_GENERAL_M_AUTO32);
    vi_set(I, VAF_vecsize, VA_VECSIZE_VARYING_M_V4);
    vi_ref c[4];
    for (unsigned k = 0; k < n && k < 4; k++) c[k] = vi_vreg(raw->vreg, k, 1);
    if (flt && bits == 16) {
        sv *r = sv_val(t, 16, n);
        for (unsigned k = 0; k < n; k += 2) {
            I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(r->vreg, k / 2, 1); I->src[0] = c[k]; I->src[1] = k + 1 < n ? c[k + 1] : vi_imm(0);
        }
        return r;
    }
    if (bits == 32 && n == 4) return raw;
    return sv_from_comps32(t, bits, n, c);
}

// ---- Fragment inputs (B4, B5, B9) -----------------------------------------------------------------------------------

static sv *fragment_input(S *t, const mdops *o, unsigned bits, unsigned n, bool flt)
{
    USE(t, B4);
    unsigned klen;
    const char *key = o->n > 2 ? md_string(o->ops[2], &klen) : NULL;
    int slot = key ? varying_slot(t, key, klen) : -1;
    if (slot >= 32) SFAIL(t, "more than 32 varyings");
    if (slot < 0) { uint32_t z[8] = {0}; return sv_const(t, bits, n, z); }   // not written by the vertex function
    bool flat = md_has(o, "air.flat") || !flt;
    bool noperspective = !flat && md_has(o, "air.no_perspective");
    bool centroid = md_has(o, "air.centroid"), sample = md_has(o, "air.sample");
    // FS slot index = order of first use; the format registry tells Gallium which VS location each index reads.
    struct pan_varying_layout *L = &t->fs_formats;
    unsigned idx = L->count;
    for (unsigned i = 0; i < L->count; i++) if (L->slots[i].location == VARYING_SLOT_VAR0 + slot) idx = i;
    if (idx == L->count) {
        if (L->count >= PAN_MAX_VARYINGS) SFAIL(t, "too many varyings");
        L->slots[idx] = (struct pan_varying_slot){ .location = VARYING_SLOT_VAR0 + slot,
            .alu_type = flt ? nir_type_float32 : nir_type_uint32, .ncomps = n, .section = PAN_VARYING_SECTION_GENERIC, .offset = -1 };
        L->count++;
        L->known |= PAN_VARYING_FORMAT_KNOWN;
    } else if (L->slots[idx].ncomps < n) L->slots[idx].ncomps = n;
    if (idx >= 256) SFAIL(t, "varying index %u", idx);
    if (noperspective) t->fs_noperspective |= 1u << slot;
    t->info.uses_ld_var = true;
    if (flat) t->info.flat = true;
    if (sample) t->info.sample_shading = true;
    sv *raw = sv_val(t, 32, n);
    vi_instr *I;
    if (flat) {
        I = E(t, VA_LD_VAR_FLAT_IMM);
    } else {
        I = E(t, VA_LD_VAR_IMM);
        I->src[0] = vi_reg(61);
        vi_set(I, VAF_update, VA_UPDATE_MODE_M_STORE);
        vi_set(I, VAF_encoded_sample, sample ? VA_ENCODED_SAMPLE_POSITION_NONE_M_SAMPLE : centroid ? VA_ENCODED_SAMPLE_POSITION_NONE_M_CENTROID
                                                                                                : VA_ENCODED_SAMPLE_POSITION_NONE_M_CENTER_OR_NONE);
        I->varying = true;
    }
    vi_set(I, VAF_encoded_varying_table_index, 1);
    vi_set(I, VAF_varying_index, idx);
    vi_set(I, VAF_register_format, flt ? VA_REGISTER_FILE_FORMAT_GENERAL_M_F32 : VA_REGISTER_FILE_FORMAT_GENERAL_M_AUTO32);
    vi_set(I, VAF_vecsize, n - 1);
    I->sw = vi_vreg(raw->vreg, 0, n);
    vi_ref c[4];
    for (unsigned k = 0; k < n; k++) c[k] = vi_vreg(raw->vreg, k, 1);
    if (noperspective) {
        // the vertex shader multiplied by w: multiply by the interpolated 1/w (frag_w)
        vi_ref w = sel_tmp(t);
        I = E(t, VA_LD_VAR_SPECIAL);
        I->sw = w; I->src[0] = vi_reg(61);
        vi_set(I, VAF_varying_name, VA_VARYING_NAME_M_FRAG_W); vi_set(I, VAF_vecsize, VA_VECSIZE_VARYING_M_NONE);
        vi_set(I, VAF_sample_position, VA_SAMPLE_POSITION_M_CENTER);
        I->varying = true;
        for (unsigned k = 0; k < n; k++) {
            vi_ref d = sel_tmp(t);
            I = E(t, VA_FMUL_F32); I->dest = d; I->src[0] = c[k]; I->src[1] = w;
            c[k] = d;
        }
    }
    if (flt && bits == 16) {
        sv *r = sv_val(t, 16, n);
        for (unsigned k = 0; k < n; k += 2) {
            I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(r->vreg, k / 2, 1); I->src[0] = c[k]; I->src[1] = k + 1 < n ? c[k + 1] : vi_imm(0);
        }
        return r;
    }
    if (bits == 32 && !noperspective) return raw;
    return sv_from_comps32(t, bits, n, c);
}

static vi_ref var_special(S *t, unsigned name, unsigned vecsize, vi_ref *out2)
{
    vi_ref d;
    uint32_t v = 0;
    vi_instr *I = E(t, VA_LD_VAR_SPECIAL);
    if (vecsize) { v = vi_new_vreg(t->s, 2); I->sw = vi_vreg(v, 0, 2); d = vi_vreg(v, 0, 1); if (out2) *out2 = vi_vreg(v, 1, 1); }
    else { d = sel_tmp(t); I->sw = d; }
    I->src[0] = vi_reg(61);
    vi_set(I, VAF_varying_name, name);
    vi_set(I, VAF_vecsize, vecsize);
    vi_set(I, VAF_sample_position, VA_SAMPLE_POSITION_M_CENTER);
    I->varying = true;
    return d;
}

static sv *frag_coord(S *t, unsigned n, unsigned bits)
{
    USE(t, B5);
    t->info.reads_frag_coord = true;
    vi_ref c[4];
    // r59: pixel x, y as u16 (integer pixel centre in Gallium): Metal's centres are at +0.5.
    for (unsigned k = 0; k < 2; k++) {
        vi_ref d = sel_tmp(t);
        vi_instr *I = E(t, VA_U16_TO_F32); I->dest = d; I->src[0] = vi_reg(59); vi_set(I, VAF_lane0, k);
        vi_ref h = sel_tmp(t);
        I = E(t, VA_FADD_F32); I->dest = h; I->src[0] = d; I->src[1] = vi_imm(0x3f000000);
        c[k] = h;
    }
    if (n > 2) c[2] = var_special(t, VA_VARYING_NAME_M_FRAG_Z, 0, NULL);
    if (n > 3) c[3] = var_special(t, VA_VARYING_NAME_M_FRAG_W, 0, NULL);
    if (bits == 16) {
        sv *r = sv_val(t, 16, n);
        for (unsigned k = 0; k < n; k += 2) {
            vi_instr *I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(r->vreg, k / 2, 1); I->src[0] = c[k]; I->src[1] = k + 1 < n ? c[k + 1] : vi_imm(0);
        }
        return r;
    }
    return sv_from_comps32(t, 32, n, c);
}

// Framebuffer fetch (B9): LD_TILE of render target n at the current pixel, sample 0.
static sv *color_input(S *t, unsigned n, unsigned bits, unsigned ncomp, bool flt)
{
    USE(t, B9);
    t->info.fbfetch = true;
    t->info.outputs_read |= 1u << (FRAG_RESULT_DATA0 + n);
    t->refl->color_inputs |= 1u << n;
    // pixel indices: sample | rt << 8 | x(0) << 16 | y(255) << 24 (current pixel)
    vi_ref pix = vi_imm((n << 8) | (255u << 24));
    vi_ref cov = sel_tmp(t);
    vi_instr *I = E(t, VA_AND_I32); I->dest = cov; I->src[0] = vi_reg(60); I->src[2] = vi_imm(0x1f);
    vi_ref conv = sel_sysval_comp(t, SYS_RT_CONVERSION, n | ((bits == 16 ? 16 : 32) << 4), 0);
    sv *raw = sv_val(t, 32, 4);
    I = E(t, VA_LD_TILE);
    I->sw = vi_vreg(raw->vreg, 0, 4);
    I->src[0] = pix; I->src[1] = cov; I->src[2] = conv;
    vi_set(I, VAF_register_format, flt ? VA_REGISTER_FILE_FORMAT_GENERAL_M_F32 : VA_REGISTER_FILE_FORMAT_GENERAL_M_U32);
    vi_set(I, VAF_vecsize, VA_VECSIZE_VARYING_M_V4);
    vi_set(I, VAF_z_stencil, 0);
    vi_ref c[4];
    for (unsigned k = 0; k < 4; k++) c[k] = vi_vreg(raw->vreg, k, 1);
    if (flt && bits == 16) {
        sv *r = sv_val(t, 16, ncomp);
        for (unsigned k = 0; k < ncomp; k += 2) {
            I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(r->vreg, k / 2, 1); I->src[0] = c[k]; I->src[1] = k + 1 < ncomp ? c[k + 1] : vi_imm(0);
        }
        return r;
    }
    return sv_from_comps32(t, bits, ncomp, c);
}

// ---- Compute inputs (B10) -------------------------------------------------------------------------------------------

static vi_ref local_index(S *t)
{
    vi_ref lx = sel_tmp(t), ly = sel_tmp(t), lz = sel_tmp(t);
    vi_instr *I = E(t, VA_U16_TO_U32); I->dest = lx; I->src[0] = vi_reg(55); vi_set(I, VAF_lane0, 0);
    I = E(t, VA_U16_TO_U32); I->dest = ly; I->src[0] = vi_reg(55); vi_set(I, VAF_lane0, 1);
    I = E(t, VA_U16_TO_U32); I->dest = lz; I->src[0] = vi_reg(56); vi_set(I, VAF_lane0, 0);
    vi_ref sx = sel_sysval_comp(t, SYS_LOCAL_GROUP_SIZE, 0, 0), sy = sel_sysval_comp(t, SYS_LOCAL_GROUP_SIZE, 0, 1);
    // (z * sy + y) * sx + x
    vi_ref zy = sel_alu2(t, VA_IADD_U32, sel_alu2(t, VA_IMUL_U32, lz, sy), ly);
    return sel_alu2(t, VA_IADD_U32, sel_alu2(t, VA_IMUL_U32, zy, sx), lx);
}

static sv *fit(S *t, vi_ref *c, unsigned have, unsigned n, unsigned bits)
{
    vi_ref r[4];
    for (unsigned k = 0; k < n; k++) r[k] = k < have ? c[k] : vi_imm(0);
    if (bits == 1) bits = 32;
    return sv_from_comps32(t, bits, n, r);
}

static sv *compute_input(S *t, LLVMValueRef rolev, unsigned bits, unsigned n)
{
    USE(t, B10);
    vi_ref c[3];
    unsigned have = 3;
    if (md_is(rolev, "air.thread_position_in_grid")) { for (unsigned k = 0; k < 3; k++) c[k] = preload(t, 60 + k); }
    else if (md_is(rolev, "air.thread_position_in_threadgroup")) {
        c[0] = sel_tmp(t); c[1] = sel_tmp(t); c[2] = sel_tmp(t);
        vi_instr *I = E(t, VA_U16_TO_U32); I->dest = c[0]; I->src[0] = vi_reg(55); vi_set(I, VAF_lane0, 0);
        I = E(t, VA_U16_TO_U32); I->dest = c[1]; I->src[0] = vi_reg(55); vi_set(I, VAF_lane0, 1);
        I = E(t, VA_U16_TO_U32); I->dest = c[2]; I->src[0] = vi_reg(56); vi_set(I, VAF_lane0, 0);
    } else if (md_is(rolev, "air.threadgroup_position_in_grid")) { for (unsigned k = 0; k < 3; k++) c[k] = preload(t, 57 + k); }
    else if (md_is(rolev, "air.threadgroups_per_grid")) { for (unsigned k = 0; k < 3; k++) c[k] = sel_sysval_comp(t, SYS_NUM_WORK_GROUPS, 0, k); }
    else if (md_is(rolev, "air.threads_per_threadgroup")) { for (unsigned k = 0; k < 3; k++) c[k] = sel_sysval_comp(t, SYS_LOCAL_GROUP_SIZE, 0, k); }
    else if (md_is(rolev, "air.threads_per_grid")) { for (unsigned k = 0; k < 3; k++) c[k] = sel_fau_ubo(t, VI_UBO_CB0, 32 + 4 * k); }
    else if (md_is(rolev, "air.thread_index_in_threadgroup")) { c[0] = local_index(t); have = 1; }
    else if (md_is(rolev, "air.thread_index_in_simdgroup")) { USE(t, F1); c[0] = sel_mov32(t, vi_special(3, 2)); have = 1; t->info.subgroups = true; }
    else if (md_is(rolev, "air.simdgroup_index_in_threadgroup")) {
        USE(t, F1);
        vi_ref li = local_index(t);
        c[0] = sel_tmp(t);
        vi_instr *I = E(t, VA_RSHIFT_OR_I32); I->dest = c[0]; I->src[0] = li; I->src[1] = vi_imm(4); I->src[2] = vi_imm(0);
        have = 1; t->info.subgroups = true;
    } else if (md_is(rolev, "air.threads_per_simdgroup")) { c[0] = vi_imm(16); have = 1; }
    else if (md_is(rolev, "air.simdgroups_per_threadgroup")) {
        vi_ref sx = sel_sysval_comp(t, SYS_LOCAL_GROUP_SIZE, 0, 0), sy = sel_sysval_comp(t, SYS_LOCAL_GROUP_SIZE, 0, 1), sz = sel_sysval_comp(t, SYS_LOCAL_GROUP_SIZE, 0, 2);
        vi_ref total = sel_alu2(t, VA_IMUL_U32, sel_alu2(t, VA_IMUL_U32, sel_mov32(t, sx), sy), sz);
        c[0] = sel_tmp(t);
        vi_ref tt = sel_iadd_imm(t, total, 15);
        vi_instr *I = E(t, VA_RSHIFT_OR_I32); I->dest = c[0]; I->src[0] = tt; I->src[1] = vi_imm(4); I->src[2] = vi_imm(0);
        have = 1;
    } else if (md_is(rolev, "air.thread_index_in_quadgroup")) {
        USE(t, F2);
        c[0] = sel_tmp(t);
        vi_ref lid = sel_mov32(t, vi_special(3, 2));
        vi_instr *I = E(t, VA_AND_I32); I->dest = c[0]; I->src[0] = lid; I->src[2] = vi_imm(3);
        have = 1; t->info.subgroups = true;
    } else if (md_is(rolev, "air.quadgroup_index_in_threadgroup")) {
        USE(t, F2);
        c[0] = sel_tmp(t);
        vi_ref li = local_index(t);
        vi_instr *I = E(t, VA_RSHIFT_OR_I32); I->dest = c[0]; I->src[0] = li; I->src[1] = vi_imm(2); I->src[2] = vi_imm(0);
        have = 1;
    } else {
        unsigned len;
        const char *s = md_string(rolev, &len);
        SFAIL(t, "unsupported kernel input %.*s", (int)len, s ? s : "?");
    }
    for (unsigned k = 0; k < have; k++) if (c[k].kind == VI_FAU) c[k] = sel_mov32(t, c[k]);
    return fit(t, c, have, n, bits);
}

// ---- Begin: inputs --------------------------------------------------------------------------------------------------

sv *sel_buffer_arg(S *t, const mdops *o, LLVMTypeRef pt);   // vi_sel_mem.c
sv *sel_threadgroup_arg(S *t, long slot);

static bool declare_inputs(S *t, LLVMValueRef node)
{
    mdops list;
    md_operands(node, &list);
    unsigned nparams = ts_LLVMCountParams(t->fn);
    for (unsigned a = 0; a < list.n; a++) {
        mdops o;
        md_operands(list.ops[a], &o);
        if (!o.n || !ts_LLVMIsAConstantInt(o.ops[0])) SFAILB(t, "malformed input metadata");
        unsigned idx = (unsigned)ts_LLVMConstIntGetZExtValue(o.ops[0]);
        if (idx >= nparams) continue;
        LLVMValueRef param = ts_LLVMGetParam(t->fn, idx);
        LLVMTypeRef pt = ts_LLVMTypeOf(param);
        LLVMValueRef rolev = o.n > 1 ? o.ops[1] : NULL;
        sv *v = NULL;
        unsigned bits = 32, n = 1; bool flt = false;
        bool scalar = sel_type_info(pt, &bits, &n, &flt);
        if (md_is(rolev, "air.vertex_input")) {
            long loc = md_int_after(&o, "air.location_index", idx);
            if (!scalar || loc < 0 || loc >= VMG_MAX_VERTEX_ATTRIBS) SFAILB(t, "vertex input %ld", loc);
            v = vertex_input(t, (unsigned)loc, bits, n, flt);
        } else if (md_is(rolev, "air.vertex_id")) {
            USEB(t, B2);
            vi_ref c = preload(t, 60);
            v = fit(t, &c, 1, n, bits);
        } else if (md_is(rolev, "air.instance_id")) {
            USEB(t, B2);
            v = io(t)->instance_id;
        } else if (md_is(rolev, "air.base_instance") || md_is(rolev, "air.base_vertex")) {
            USEB(t, B2);
            vi_ref c = sel_mov32(t, sel_sysval_comp(t, SYS_VERTEX_INSTANCE_OFFSETS, 0, md_is(rolev, "air.base_vertex") ? 1 : 2));
            v = fit(t, &c, 1, n, bits);
        } else if (md_is(rolev, "air.fragment_input")) {
            if (!scalar) SFAILB(t, "aggregate fragment input");
            v = fragment_input(t, &o, bits, n, flt);
        } else if (md_is(rolev, "air.position")) {
            v = frag_coord(t, n, bits);
        } else if (md_is(rolev, "air.front_facing")) {
            USEB(t, B5);
            t->info.reads_face = true;
            vi_ref d = sel_tmp(t);
            vi_instr *I = E(t, VA_ICMP_U32); I->dest = d; I->src[0] = vi_reg(58); I->src[1] = vi_imm(0);
            vi_set(I, VAF_cmpf, VA_CMPF_M_EQ); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
            v = fit(t, &d, 1, 1, bits);
        } else if (md_is(rolev, "air.point_coord")) {
            USEB(t, B5);
            t->info.reads_point_coord = true;
            vi_ref c[2];
            c[0] = var_special(t, VA_VARYING_NAME_M_POINT, VA_VECSIZE_VARYING_M_V2, &c[1]);
            v = fit(t, c, 2, n, bits);
        } else if (md_is(rolev, "air.sample_id")) {
            USEB(t, B5);
            t->refl->reads_sample_id = true;
            t->info.sample_shading = true;
            vi_ref d = sel_tmp(t);
            vi_instr *I = E(t, VA_RSHIFT_AND_I32); I->dest = d; I->src[0] = vi_reg(61); I->src[1] = vi_imm(16); I->src[2] = vi_imm(0x1f);
            v = fit(t, &d, 1, 1, bits);
        } else if (md_is(rolev, "air.sample_mask") || md_is(rolev, "air.sample_mask_in")) {
            USEB(t, B5);
            vi_ref d = sel_tmp(t);
            vi_instr *I = E(t, VA_U16_TO_U32); I->dest = d; I->src[0] = vi_reg(61); vi_set(I, VAF_lane0, 0);
            v = fit(t, &d, 1, 1, bits);
        } else if (md_is(rolev, "air.render_target")) {
            long rt = o.n > 2 && ts_LLVMIsAConstantInt(o.ops[2]) ? (long)ts_LLVMConstIntGetZExtValue(o.ops[2]) : 0;
            if (rt < 0 || rt >= VMG_MAX_COLOR) SFAILB(t, "color input %ld", rt);
            v = color_input(t, (unsigned)rt, bits, n, flt);
        } else if (md_is(rolev, "air.visible_function_table")) {
            // visible function table (G4): a buffer of uint32 entries (driver/metal VMVisibleFunctionTable)
            USEB(t, G4);
            v = sel_buffer_arg(t, &o, pt);
            if (v && v->kind == SV_PTR && v->space == SP_PUSH) { USEB(t, C2); }
        } else if (md_is(rolev, "air.indirect_buffer")) {
            // argument buffer (G3): a buffer whose contents include pointers (64-bit GPU addresses)
            USEB(t, G3);
            v = sel_buffer_arg(t, &o, pt);
        } else if (md_is(rolev, "air.buffer") || md_is(rolev, "air.threadgroup")) {
            v = md_is(rolev, "air.threadgroup") ? sel_threadgroup_arg(t, md_int_after(&o, "air.location_index", 0)) : sel_buffer_arg(t, &o, pt);
        } else if (md_is(rolev, "air.texture")) {
            long slot = md_int_after(&o, "air.location_index", 0);
            if (slot < 0 || slot >= VMG_MAX_TEXTURES) SFAILB(t, "texture %ld", slot);
            v = sv_new(t, SV_TEX);
            v->index = (int)slot;
        } else if (md_is(rolev, "air.sampler")) {
            long slot = md_int_after(&o, "air.location_index", 0);
            if (slot < 0 || slot >= VMG_MAX_SAMPLERS) SFAILB(t, "sampler %ld", slot);
            t->refl->samplers_used |= 1u << slot;
            v = sv_new(t, SV_SMP);
            v->index = (int)slot;
        } else if (md_is(rolev, "air.imageblock") || md_is(rolev, "air.imageblock_data")) {
            // tile kernel's imageblock (G2): its reads/writes address the attachments (vmg_cmd_dispatch_tile)
            USEB(t, G2);
            v = sv_new(t, SV_NONE);
        } else if (t->stage == MESA_SHADER_COMPUTE) {
            v = compute_input(t, rolev, bits, n);
        } else {
            unsigned len;
            const char *s = md_string(rolev, &len);
            SFAILB(t, "unsupported input %.*s", (int)len, s ? s : "?");
        }
        if (!v) return false;
        _mesa_hash_table_insert(t->vals, param, v);
    }
    return true;
}

static LLVMTypeRef return_type(S *t)
{
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(t->fn); bb; bb = ts_LLVMGetNextBasicBlock(bb)) {
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
        if (term && ts_LLVMGetInstructionOpcode(term) == LLVMRet && ts_LLVMGetNumOperands(term) > 0)
            return ts_LLVMTypeOf(ts_LLVMGetOperand(term, 0));
    }
    return NULL;
}

static bool declare_outputs(S *t, LLVMValueRef node)
{
    mdops list;
    md_operands(node, &list);
    LLVMTypeRef rt = return_type(t);
    IO *x = io(t);
    for (unsigned a = 0; a < list.n; a++) {
        mdops o;
        md_operands(list.ops[a], &o);
        LLVMTypeRef mt = !rt ? NULL : ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind
                                     ? (a < ts_LLVMCountStructElementTypes(rt) ? ts_LLVMStructGetTypeAtIndex(rt, a) : NULL)
                                     : a == 0 ? rt : NULL;
        unsigned bits = 32, n = 1; bool flt = true;
        LLVMValueRef rolev = o.n ? o.ops[0] : NULL;
        if (mt && !sel_type_info(mt, &bits, &n, &flt) && !md_is(rolev, "air.clip_distance")) SFAILB(t, "output %u of an unsupported type", a);
        if (x->nout >= 40) SFAILB(t, "too many outputs");
        typeof(x->out[0]) *out = &x->out[x->nout++];
        memset(out, 0, sizeof *out);
        out->ncomp = n; out->flt = flt; out->bits = bits;
        if (md_is(rolev, "air.position")) {
            USEB(t, B3);
            out->kind = O_POSITION;
            out->val = out_reg(t, 32, 4);
            t->info.outputs_written |= VARYING_BIT_POS;
        } else if (md_is(rolev, "air.vertex_output")) {
            USEB(t, B3);
            unsigned klen;
            const char *key = o.n > 1 ? md_string(o.ops[1], &klen) : NULL;
            int slot = key ? varying_slot(t, key, klen) : -1;
            if (slot >= 32) SFAILB(t, "more than 32 varyings");
            if (slot >= 0) {
                out->kind = O_VARYING; out->slot = slot;
                out->val = out_reg(t, 32, n);
                t->info.outputs_written |= BITFIELD64_BIT(VARYING_SLOT_VAR0 + slot);
            }
        } else if (md_is(rolev, "air.point_size")) {
            USEB(t, B3);
            out->kind = O_PSIZE;
            out->val = out_reg(t, 32, 1);
            t->info.writes_psiz = true;
            t->info.outputs_written |= VARYING_BIT_PSIZ;
        } else if (md_is(rolev, "air.render_target")) {
            USEB(t, B6);
            long rtn = o.n > 1 && ts_LLVMIsAConstantInt(o.ops[1]) ? (long)ts_LLVMConstIntGetZExtValue(o.ops[1]) : 0;
            long index = o.n > 2 && ts_LLVMIsAConstantInt(o.ops[2]) ? (long)ts_LLVMConstIntGetZExtValue(o.ops[2]) : 0;
            if (rtn < 0 || rtn >= VMG_MAX_COLOR || index < 0 || index > 1) SFAILB(t, "render target %ld", rtn);
            out->kind = O_COLOR; out->slot = (int)rtn; out->index = (unsigned)index;
            if (!flt) {
                uint32_t fmt = t->in->color_formats ? t->in->color_formats[rtn] : 0;
                out->sint = fmt && vmg_format_is_signed_integer(fmt);
            }
            // 16-bit float outputs stay packed (v2f16 x 2, register format f16); everything else 32-bit
            unsigned rbits = flt && bits == 16 ? 16 : 32;
            out->bits = rbits;
            out->val = out_reg(t, rbits, 4);
            t->refl->color_outputs |= 1u << rtn;
            if (index == 0) t->info.colors_written |= 1u << rtn;
            t->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0 + rtn);
        } else if (md_is(rolev, "air.depth")) {
            USEB(t, B6);
            out->kind = O_DEPTH;
            out->val = out_reg(t, 32, 1);
            t->refl->writes_depth = true;
            t->info.writes_depth = true;
            t->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DEPTH);
        } else if (md_is(rolev, "air.sample_mask")) {
            USEB(t, B6);
            out->kind = O_SAMPLE_MASK;
            out->val = out_reg(t, 32, 1);
            t->refl->writes_sample_mask = true;
            t->info.writes_coverage = true;
            t->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_SAMPLE_MASK);
        } else if (md_is(rolev, "air.clip_distance")) {
            out->kind = O_NONE;   // dropped (as on the NIR path)
        } else {
            unsigned len;
            const char *s = md_string(rolev, &len);
            SFAILB(t, "unsupported output %.*s", (int)len, s ? s : "?");
        }
    }
    return true;
}

bool sel_io_begin(S *t, LLVMValueRef outputs_md, LLVMValueRef inputs_md)
{
    IO *x = rzalloc(t->mem, IO);
    t->io = x;
    if (t->stage == MESA_SHADER_FRAGMENT) {
        // Sysval 0 = blend constants, FAU words 0-3 (blend shaders read them from the fragment shader's FAU).
        sel_sysval(t, SYS_BLEND_CONSTANTS, 0);
        for (unsigned k = 0; k < 4; k++) sel_fau_ubo(t, VI_UBO_SYSVALS, 4 * k);
        t->s->reserved_regs |= (1ull << 60) | (1ull << 61);   // coverage and sample/centroid ids, read up to the BLENDs
    } else if (t->stage == MESA_SHADER_VERTEX) {
        sel_sysval(t, SYS_VIEWPORT_SCALE, 0);
        sel_sysval(t, SYS_VIEWPORT_OFFSET, 0);
        // instance id = r61 (zero-based) + base_instance
        vi_ref bi = sel_sysval_comp(t, SYS_VERTEX_INSTANCE_OFFSETS, 0, 2);
        vi_ref iid = sel_alu2(t, VA_IADD_U32, vi_reg(61), bi);
        x->instance_id = sv_from_comps32(t, 32, 1, &iid);
        t->s->reserved_regs |= (1ull << 59) | (1ull << 60);   // IDVS buffer index and vertex id
    } else {
        sel_sysval(t, SYS_LOCAL_GROUP_SIZE, 0);
    }
    return declare_outputs(t, outputs_md) && declare_inputs(t, inputs_md);
}

// ---- Return: outputs into their registers ---------------------------------------------------------------------------

bool sel_io_return(S *t, LLVMValueRef term)
{
    IO *x = io(t);
    if (ts_LLVMGetNumOperands(term) == 0 || !x->nout) return true;
    sv *rv = sel_value(t, ts_LLVMGetOperand(term, 0));
    if (!rv) return false;
    for (unsigned i = 0; i < x->nout; i++) {
        typeof(x->out[0]) *out = &x->out[i];
        if (!out->kind || !out->val) continue;
        sv *m = rv->kind == SV_AGG ? (i < rv->n ? rv->e[i] : NULL) : (i == 0 ? rv : NULL);
        if (!m || m->kind != SV_VAL) SFAILB(t, "output %u is not a value", i);
        unsigned want = out->val->ncomp;
        vi_ref c[4];
        if (out->val->bits == 16) {
            // packed f16 colour: convert/pad to 4 halves
            for (unsigned k = 0; k < 4; k++) c[k] = k < m->ncomp ? sv_comp32(t, m, k, X_F32) : vi_imm(0);
            for (unsigned k = 0; k < 4; k += 2) {
                vi_instr *I = E(t, VA_V2F32_TO_V2F16);
                I->dest = vi_vreg(out->val->vreg, k / 2, 1); I->src[0] = c[k]; I->src[1] = c[k + 1];
            }
            continue;
        }
        for (unsigned k = 0; k < want; k++) {
            if (k >= m->ncomp) { c[k] = vi_imm(out->kind == O_COLOR && k == 3 && out->flt ? 0x3f800000 : 0); continue; }
            int how = m->bits == 16 && out->flt ? X_F32 : out->sint ? X_SEXT : X_ZEXT;
            c[k] = sv_comp32(t, m, k, how);
        }
        for (unsigned k = 0; k < want; k++) {
            vi_instr *I = c[k].kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
            if (c[k].kind == VI_IMM) vi_set(I, VAF_imm1w, c[k].value); else I->src[0] = c[k];
            I->dest = vi_vreg(out->val->vreg, k, 1);
        }
    }
    return true;
}

// ---- Finish: stores / blending in the exit block --------------------------------------------------------------------

static vi_ref lea_buf(S *t, vi_ref index)
{
    uint32_t a = vi_new_vreg(t->s, 2);
    vi_instr *I = E(t, VA_LEA_BUF_IMM);
    I->sw = vi_vreg(a, 0, 2);
    I->src[0] = index;
    vi_set(I, VAF_encoded_buffer_table_index, 13);   // table 61
    vi_set(I, VAF_buffer_index, 0);
    return vi_vreg(a, 0, 2);
}

static void store(S *t, enum va_op op, vi_ref addr, vi_ref value, int offset, int access)
{
    vi_instr *I = E(t, op);
    I->sr = value; I->src[0] = addr;
    vi_set(I, VAF_offset, offset);
    vi_set(I, VAF_access, access);
    I->memory = true;
}

static bool vertex_finish(S *t)
{
    IO *x = io(t);
    bool pos_mode = t->idvs == 0 || t->idvs == 1 || t->idvs == 2;
    bool var_mode = t->idvs == 0 || t->idvs == 3;
    for (unsigned i = 0; i < x->nout; i++) {
        typeof(x->out[0]) *out = &x->out[i];
        if (out->kind == O_POSITION && pos_mode) {
            // viewport transform: w_r = clamp(1/w), xyz * w_r * scale + offset, w = w_r
            vi_ref p[4];
            for (unsigned k = 0; k < 4; k++) p[k] = vi_vreg(out->val->vreg, k, 1);
            vi_ref rcp = sel_alu1(t, VA_FRCP_F32, p[3]);
            vi_ref wr = sel_csel(t, VA_CMPF_M_GT, VA_CSEL_F32, rcp, vi_imm(0x47000000), vi_imm(0x47000000), rcp);
            wr = sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, wr, vi_imm(0xc7000000), vi_imm(0xc7000000), wr);
            uint32_t pos = vi_new_vreg(t->s, 4);
            for (unsigned k = 0; k < 3; k++) {
                vi_ref m = sel_tmp(t);
                vi_instr *I = E(t, VA_FMUL_F32); I->dest = m; I->src[0] = p[k]; I->src[1] = wr;
                vi_ref sc = sel_mov32(t, sel_sysval_comp(t, SYS_VIEWPORT_SCALE, 0, k));
                vi_ref of = sel_sysval_comp(t, SYS_VIEWPORT_OFFSET, 0, k);
                I = E(t, VA_FMA_F32);
                I->dest = vi_vreg(pos, k, 1); I->src[0] = m; I->src[1] = sc; I->src[2] = of;
            }
            vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(pos, 3, 1); I->src[0] = wr;
            vi_ref a = lea_buf(t, vi_reg(59));
            store(t, VA_STORE_I128, a, vi_vreg(pos, 0, 4), 0, VA_ACCESS_STORE_M_ISTREAM);
        } else if (out->kind == O_PSIZE && t->idvs != 2 && pos_mode) {
            // f16, ATTRIBS section at structure index r59 + 4
            vi_ref h = sel_tmp(t);
            vi_instr *I = E(t, VA_V2F32_TO_V2F16); I->dest = h; I->src[0] = vi_vreg(out->val->vreg, 0, 1); I->src[1] = vi_imm(0);
            vi_ref a = lea_buf(t, sel_iadd_imm(t, vi_reg(59), 4));
            store(t, VA_STORE_I16, a, h, 0, VA_ACCESS_STORE_M_ISTREAM);
        } else if (out->kind == O_VARYING && var_mode) {
            const struct pan_varying_slot *s = pan_varying_layout_find_slot(&t->vs_layout, VARYING_SLOT_VAR0 + out->slot);
            if (!s) continue;
            unsigned n = out->val->ncomp;
            vi_ref a = lea_buf(t, vi_reg(59));
            vi_ref val = vi_vreg(out->val->vreg, 0, n);
            if (t->fs_noperspective >> out->slot & 1) {
                // noperspective: multiply by the pre-transform w (the fragment shader multiplies by 1/w)
                uint32_t m = vi_new_vreg(t->s, n);
                vi_ref w = vi_none();
                for (unsigned i2 = 0; i2 < x->nout; i2++) if (x->out[i2].kind == O_POSITION) w = vi_vreg(x->out[i2].val->vreg, 3, 1);
                for (unsigned k = 0; k < n; k++) {
                    vi_instr *I = E(t, VA_FMUL_F32); I->dest = vi_vreg(m, k, 1); I->src[0] = vi_vreg(out->val->vreg, k, 1); I->src[1] = w;
                }
                val = vi_vreg(m, 0, n);
            }
            static const enum va_op st[5] = { 0, VA_STORE_I32, VA_STORE_I64, VA_STORE_I96, VA_STORE_I128 };
            store(t, st[n], a, val, s->offset, VA_ACCESS_STORE_M_ESTREAM);
        }
    }
    return true;
}

static unsigned blend_regfmt(bool flt, bool sint, unsigned bits)
{
    if (flt) return bits == 16 ? VA_REGISTER_FILE_FORMAT_GENERAL_M_F16 : VA_REGISTER_FILE_FORMAT_GENERAL_M_F32;
    return sint ? VA_REGISTER_FILE_FORMAT_GENERAL_M_S32 : VA_REGISTER_FILE_FORMAT_GENERAL_M_U32;
}

static unsigned blend_type(bool flt, bool sint, unsigned bits)
{
    // nir_alu_type: float32 0xA0, float16 0x90, int32 0x22, uint32 0x24
    if (flt) return bits == 16 ? 0x90 : 0xA0;
    return sint ? 0x22 : 0x24;
}

static bool fragment_finish(S *t)
{
    IO *x = io(t);
    typeof(x->out[0]) *color[8] = {0}, *color1[8] = {0}, *depth = NULL, *mask = NULL;
    for (unsigned i = 0; i < x->nout; i++) {
        typeof(x->out[0]) *o = &x->out[i];
        if (o->kind == O_COLOR) { if (o->index) color1[o->slot] = o; else color[o->slot] = o; }
        else if (o->kind == O_DEPTH) depth = o;
        else if (o->kind == O_SAMPLE_MASK) mask = o;
    }
    // coverage: r60, & the written sample mask
    vi_ref cov = vi_reg(60);
    if (mask) {
        vi_instr *I = E(t, VA_AND_I32);
        I->dest = vi_reg(60); I->src[0] = vi_reg(60); I->src[2] = vi_vreg(mask->val->vreg, 0, 1);
    }
    // ATEST with the alpha of render target 0 (1.0 if it is not float)
    vi_ref alpha = vi_imm(0x3f800000);
    if (color[0] && color[0]->flt && (t->attached & 1)) {
        if (color[0]->bits == 16) {
            vi_ref a = sel_tmp(t);
            vi_instr *I = E(t, VA_F16_TO_F32); I->dest = a; I->src[0] = vi_vreg(color[0]->val->vreg, 1, 1); vi_set(I, VAF_lane0, 1);
            alpha = a;
        } else alpha = vi_vreg(color[0]->val->vreg, 3, 1);
    }
    if (alpha.kind == VI_IMM) alpha = sel_mov32(t, alpha);
    vi_instr *A = E(t, VA_ATEST);
    A->sw = vi_reg(60); A->src[0] = cov; A->src[1] = alpha;
    A->src[2] = vi_special(0, 2 * 5);   // atest_datum
    if (depth && !t->info.early_fragment_tests) {
        vi_instr *Z = E(t, VA_ZS_EMIT);
        Z->sw = vi_reg(60); Z->src[0] = vi_vreg(depth->val->vreg, 0, 1); Z->src[1] = vi_imm(0); Z->src[2] = vi_reg(60);
        vi_set(Z, VAF_z, 1); vi_set(Z, VAF_stencil, 0);
    }
    // BLEND per render target, ascending; the last one ends the program.
    int last = -1;
    for (unsigned r = 0; r < 8; r++) if (color[r] && (t->attached >> r & 1)) last = (int)r;
    if (last < 0) {
        // no colour: ATEST already ran; end
        return true;
    }
    for (unsigned r = 0; r <= (unsigned)last; r++) {
        if (!color[r] || !(t->attached >> r & 1)) continue;
        unsigned words = color[r]->bits == 16 ? 2 : 4;
        uint32_t c = vi_new_vreg(t->s, words);
        vi_vreg_get(t->s, c)->fixed = 0;   // r0-r3: the blend shader ABI
        for (unsigned k = 0; k < words; k++) {
            vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(c, k, 1); I->src[0] = vi_vreg(color[r]->val->vreg, k, 1);
        }
        if (color1[r]) {
            uint32_t c1 = vi_new_vreg(t->s, words);
            vi_vreg_get(t->s, c1)->fixed = 4;   // dual-source colour in r4-r7
            for (unsigned k = 0; k < words; k++) {
                vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(c1, k, 1); I->src[0] = vi_vreg(color1[r]->val->vreg, k, 1);
            }
            // keep r4-r7 alive up to the BLEND (read by the blend shader, not encoded)
            t->info.blend_src1_type = blend_type(color1[r]->flt, color1[r]->sint, color1[r]->bits);
            vi_instr *K = E(t, VA_NOP); K->is_nop = true; K->src[0] = vi_vreg(c1, 0, words);
        }
        vi_instr *B = E(t, VA_BLEND);
        B->sr = vi_vreg(c, 0, words);
        B->src[0] = vi_special(0, 2 * (8 + r)); B->src[0].count = 2;   // blend descriptor of the target
        B->src[2] = vi_reg(60);
        B->src[3] = vi_special(0, 2 * (8 + r) + 1);                   // .w1: blend shader address (for vi_pack.c)
        vi_set(B, VAF_register_format, blend_regfmt(color[r]->flt, color[r]->sint, color[r]->bits));
        B->blend = true;
        B->clobber = 0xffffull | (1ull << 48);
        if ((int)r == last) B->flow = 15;   // end
        t->info.blend_type[r] = blend_type(color[r]->flt, color[r]->sint, color[r]->bits);
    }
    return true;
}

bool sel_io_finish(S *t)
{
    if (t->stage == MESA_SHADER_VERTEX) return vertex_finish(t);
    if (t->stage == MESA_SHADER_FRAGMENT) return fragment_finish(t);
    return true;
}

// The vertex shader's own layout: POS, PSIZ (if written), then every generic varying (32 bits per component).
void sel_vs_layout(S *t, LLVMValueRef outputs_md);
void sel_vs_layout(S *t, LLVMValueRef outputs_md)
{
    struct pan_varying_layout *L = &t->vs_layout;
    memset(L, 0, sizeof *L);
    mdops list;
    md_operands(outputs_md, &list);
    LLVMTypeRef rt = return_type(t);
    unsigned idx = 0, gen = 0;
    bool pos = false, psiz = false;
    struct { int slot; unsigned n; bool flt; } vary[32];
    unsigned nv = 0;
    for (unsigned a = 0; a < list.n; a++) {
        mdops o;
        md_operands(list.ops[a], &o);
        LLVMTypeRef mt = !rt ? NULL : ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind
                                     ? (a < ts_LLVMCountStructElementTypes(rt) ? ts_LLVMStructGetTypeAtIndex(rt, a) : NULL)
                                     : a == 0 ? rt : NULL;
        unsigned bits = 32, n = 1; bool flt = true;
        if (mt) sel_type_info(mt, &bits, &n, &flt);
        LLVMValueRef rolev = o.n ? o.ops[0] : NULL;
        if (md_is(rolev, "air.position")) pos = true;
        else if (md_is(rolev, "air.point_size")) psiz = true;
        else if (md_is(rolev, "air.vertex_output")) {
            unsigned klen;
            const char *key = o.n > 1 ? md_string(o.ops[1], &klen) : NULL;
            int slot = key ? varying_slot(t, key, klen) : -1;
            if (slot >= 0 && slot < 32 && nv < 32) { vary[nv].slot = slot; vary[nv].n = n; vary[nv].flt = flt; nv++; }
        }
    }
    if (pos) L->slots[idx++] = (struct pan_varying_slot){ .location = VARYING_SLOT_POS, .alu_type = nir_type_float32, .ncomps = 4,
                                                           .section = PAN_VARYING_SECTION_POSITION, .offset = 0 };
    if (psiz) L->slots[idx++] = (struct pan_varying_slot){ .location = VARYING_SLOT_PSIZ, .alu_type = nir_type_float16, .ncomps = 1,
                                                            .section = PAN_VARYING_SECTION_ATTRIBS, .offset = 0 };
    // generic varyings in location order
    for (unsigned s = 0; s < 32; s++) {
        for (unsigned k = 0; k < nv; k++) {
            if (vary[k].slot != (int)s) continue;
            unsigned size = vary[k].n * 4, align = 1;
            while (align < size) align <<= 1;
            unsigned off = (gen + align - 1) & ~(align - 1);
            gen = off + size;
            L->slots[idx++] = (struct pan_varying_slot){ .location = VARYING_SLOT_VAR0 + s,
                .alu_type = vary[k].flt ? nir_type_float32 : nir_type_uint32, .ncomps = vary[k].n,
                .section = PAN_VARYING_SECTION_GENERIC, .offset = (int)off };
            break;
        }
    }
    L->count = (uint8_t)idx;
    L->generic_size_B = (uint16_t)gen;
    L->known = PAN_VARYING_FORMAT_KNOWN | PAN_VARYING_LAYOUT_KNOWN;
}

// ---- Imageblocks of tile kernels (G2) ---------------------------------------------------------------------------------
// The tile kernel runs as compute, one threadgroup per tile (vmg_cmd_dispatch_tile): imageblock pixel (x, y) of
// colour n is texel tile_origin + (x, y) of image VMG_TILE_IMAGE_BASE + n, tile_origin = threadgroup id * tile size
// (system values 52, 56).
static sv *imageblock_access(S *t, LLVMValueRef inst, bool store)
{
    if (t->stage != MESA_SHADER_COMPUTE) SFAIL(t, "imageblock outside a tile kernel");
    unsigned a0 = store ? 1 : 0;
    LLVMValueRef rtv = ts_LLVMGetOperand(inst, a0);
    if (!ts_LLVMIsAConstantInt(rtv)) SFAIL(t, "imageblock colour index not constant");
    unsigned rt = (unsigned)ts_LLVMConstIntGetZExtValue(rtv);
    if (rt >= 8) SFAIL(t, "imageblock colour %u", rt);
    sv *coord = sel_ssa(t, ts_LLVMGetOperand(inst, a0 + 1));
    if (!coord) return NULL;
    unsigned slot = VMG_TILE_IMAGE_BASE + rt;
    t->refl->textures_written |= 1u << slot;
    t->info.images_used |= 1ull << slot;
    vi_ref ox = sel_alu2(t, VA_IMUL_U32, vi_reg(57), sel_mov32(t, sel_fau_ubo(t, VI_UBO_CB0, 52)));
    vi_ref oy = sel_alu2(t, VA_IMUL_U32, vi_reg(58), sel_mov32(t, sel_fau_ubo(t, VI_UBO_CB0, 56)));
    vi_ref x = sel_alu2(t, VA_IADD_U32, ox, sv_comp32(t, coord, 0, X_ZEXT));
    vi_ref y = sel_alu2(t, VA_IADD_U32, oy, sv_comp32(t, coord, 1, X_ZEXT));
    vi_ref xy = sel_tmp(t), zw = sel_mov32(t, vi_imm(0));
    vi_instr *I = E(t, VA_MKVEC_V2I16); I->dest = xy; I->src[0] = x; I->src[1] = y; vi_set(I, VAF_lane0, 0); vi_set(I, VAF_lane1, 0);
    vi_ref handle = sel_mov32(t, vi_imm((5u << 24) | slot));
    LLVMTypeRef vty = store ? ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0)) : ts_LLVMTypeOf(inst);
    unsigned bits = 32, n = 4; bool flt = true;
    sel_type_info(vty, &bits, &n, &flt);
    if (!store) {
        uint32_t d = vi_new_vreg(t->s, 4);
        I = E(t, VA_LD_TEX);
        I->sw = vi_vreg(d, 0, 4); I->src[0] = xy; I->src[1] = zw; I->src[2] = handle;
        vi_set(I, VAF_register_format, flt ? VA_REGISTER_FILE_FORMAT_GENERAL_M_F32 : VA_REGISTER_FILE_FORMAT_GENERAL_M_U32);
        vi_set(I, VAF_vecsize, VA_VECSIZE_VARYING_M_V4);
        I->memory = true;
        vi_ref c[4];
        for (unsigned k = 0; k < n && k < 4; k++) c[k] = vi_vreg(d, k, 1);
        if (flt && bits == 16) {
            sv *r = sv_val(t, 16, n);
            for (unsigned k = 0; k < n; k += 2) {
                I = E(t, VA_V2F32_TO_V2F16);
                I->dest = vi_vreg(r->vreg, k / 2, 1); I->src[0] = c[k]; I->src[1] = k + 1 < n ? c[k + 1] : vi_imm(0);
            }
            return r;
        }
        return sv_from_comps32(t, bits, n, c);
    }
    sv *val = sel_ssa(t, ts_LLVMGetOperand(inst, 0));
    if (!val) return NULL;
    uint32_t a = vi_new_vreg(t->s, 3);
    I = E(t, VA_LEA_TEX);
    I->sw = vi_vreg(a, 0, 3); I->src[0] = xy; I->src[1] = zw; I->src[2] = handle;
    vi_ref w[4];
    for (unsigned k = 0; k < 4; k++) w[k] = k < val->ncomp ? sv_comp32(t, val, k, flt ? X_F32 : X_ZEXT) : vi_imm(k == 3 && flt ? 0x3f800000 : 0);
    uint32_t sv4 = vi_new_vreg(t->s, 4);
    for (unsigned k = 0; k < 4; k++) {
        vi_instr *M = w[k].kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
        if (w[k].kind == VI_IMM) vi_set(M, VAF_imm1w, w[k].value); else M->src[0] = w[k];
        M->dest = vi_vreg(sv4, k, 1);
    }
    vi_ref addr = sel_pair(t, vi_vreg(a, 0, 1), vi_vreg(a, 1, 1));
    I = E(t, VA_ST_CVT);
    I->sr = vi_vreg(sv4, 0, 4); I->src[0] = addr; I->src[2] = vi_vreg(a, 2, 1);
    vi_set(I, VAF_register_format, flt ? VA_REGISTER_FILE_FORMAT_GENERAL_M_F32 : VA_REGISTER_FILE_FORMAT_GENERAL_M_U32);
    vi_set(I, VAF_vecsize, VA_VECSIZE_VARYING_M_V4);
    vi_set(I, VAF_offset, 0);
    I->memory = true;
    t->info.writes_global = true;
    return sv_new(t, SV_NONE);
}

// ---- Builtins called as functions --------------------------------------------------------------------------------------

sv *sel_derivative(S *t, LLVMValueRef inst, const char *name);   // vi_sel_sg.c

// NULL without an error when `name` is not one of them.
sv *sel_io_call(S *t, LLVMValueRef inst, const char *name)
{
    if (!strcmp(name, "air.discard_fragment")) {
        USE(t, B8);
        // DISCARD.f32 0 == 0: flags the lane; ATEST/BLEND drop it, the quad stops when all its lanes are discarded
        vi_instr *I = E(t, VA_DISCARD_F32);
        I->src[0] = vi_imm(0); I->src[1] = vi_imm(0);
        vi_set(I, VAF_cmpf, VA_CMPF_M_EQ);
        t->info.discard = true;
        t->refl->discards = true;
        return sv_new(t, SV_NONE);
    }
    if (sel_name_is(name, "air.get_num_samples")) {
        USE(t, B5);
        vi_ref w = t->stage == MESA_SHADER_FRAGMENT ? sel_mov32(t, sel_fau_ubo(t, VI_UBO_CB0, 48)) : vi_imm(1);
        unsigned bits = 32, n = 1; bool f;
        sel_type_info(ts_LLVMTypeOf(inst), &bits, &n, &f);
        return sv_from_comps32(t, bits, 1, &w);
    }
    if (sel_name_is(name, "air.get_function_pointer")) {
        // entry i of a visible function table: the linked function's index + 1 (G4)
        USE(t, G4);
        sv *tab = sel_value(t, ts_LLVMGetOperand(inst, 0)), *i = sel_ssa(t, ts_LLVMGetOperand(inst, 1));
        if (!tab || !i) return NULL;
        if (tab->kind != SV_PTR) SFAIL(t, "function table is not a buffer");
        extern sv *sel_load_word_at(S *t, sv *p, vi_ref byte_offset);
        vi_ref off = sv_word(t, i, 0);
        off = off.kind == VI_IMM ? vi_imm(off.value * 4) : sel_imul_imm(t, off, 4);
        return sel_load_word_at(t, tab, off);
    }
    if (sel_name_is(name, "air.load.implicit_imageblock") || sel_name_is(name, "air.store.implicit_imageblock")) {
        USE(t, G2);
        return imageblock_access(t, inst, sel_name_is(name, "air.store."));
    }
    if (!strcmp(name, "air.get_read_sampler")) {
        sv *s = sv_new(t, SV_SMP);
        s->index = 0;
        return s;
    }
    if (sel_name_is(name, "air.dfdx") || sel_name_is(name, "air.dfdy") || sel_name_is(name, "air.fwidth"))
        return sel_derivative(t, inst, name);
    return NULL;
}
