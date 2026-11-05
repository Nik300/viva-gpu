// Viva ISA compiler: textures and samplers (D1-D9).
//
// Valhall texturing: one message instruction (TEX_SINGLE / TEX_FETCH / TEX_GATHER, TEX_GRADIENT for explicit
// gradients) with a 64-bit descriptor operand and the coordinates in staging registers, in the order
//   S, T, R | array index | compare reference | offsets (u8 x4) | lod | gradient descriptor (2)
// The descriptor operand is the "narrow" form: texture table 4 / index in the low word with sampler table 3 /
// index, a constant FAU pair. Cube maps take (s with the face in bits 29-31, t) from CUBEFACE1/2 + CUBE_SSEL/TSEL.
// Sizes and level counts are read from the texture descriptor itself (resource table 62). Images (written
// textures) are table 5: LD_TEX for reads, LEA_TEX + ST_CVT for writes.
#include "vi_sel.h"
#include <stdlib.h>
#include <string.h>

enum { DIM_1D, DIM_2D, DIM_3D, DIM_CUBE };

typedef struct { int dim; bool array, ms, buffer; unsigned coords; } shape;

static shape shape_of(const char *op)
{
    shape s = {0};
    s.array = strstr(op, "_array") != NULL;
    s.ms = strstr(op, "_ms") != NULL;
    if (strstr(op, "_cube")) { s.dim = DIM_CUBE; s.coords = 3; }
    else if (strstr(op, "_3d")) { s.dim = DIM_3D; s.coords = 3; }
    else if (strstr(op, "_1d")) { s.dim = DIM_1D; s.coords = 1; }
    else if (strstr(op, "_buffer")) { s.dim = DIM_1D; s.coords = 1; s.buffer = true; }
    else { s.dim = DIM_2D; s.coords = 2; }
    return s;
}

static sv *arg(S *t, LLVMValueRef inst, unsigned i)
{
    if (i >= (unsigned)ts_LLVMGetNumArgOperands(inst)) SFAIL(t, "texture call: missing argument %u", i);
    return sel_ssa(t, ts_LLVMGetOperand(inst, i));
}

static bool is_ptr_arg(LLVMValueRef inst, unsigned i)
{
    return i < (unsigned)ts_LLVMGetNumArgOperands(inst) && ts_LLVMGetTypeKind(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i))) == LLVMPointerTypeKind;
}

static void use_texture(S *t, int index)
{
    // D9: several textures in one shader (each its own message, as Mesa does on Valhall: TEX_DUAL is unused there)
    if ((t->refl->textures_used & ~(1u << index)) && !(t->refl->textures_used & (1u << index))) sel_use(t, VMG_ISA_D9);
    t->refl->textures_used |= 1u << index;
    if ((unsigned)index + 1 > t->info.texture_count) t->info.texture_count = (unsigned)index + 1;
}

static void use_sampler(S *t, int index)
{
    if (index < 32) t->refl->samplers_used |= index < VMG_MAX_SAMPLERS ? 1u << index : 0;
    if ((unsigned)index + 1 > t->info.sampler_count) t->info.sampler_count = (unsigned)index + 1;
}

// Narrow descriptor operand: texture (table 4) and sampler (table 3) indices; `narrow` = the immediate bits.
static vi_ref descriptor(S *t, int tex, int samp, uint32_t narrow)
{
    uint32_t lo = (4u << 27) | ((uint32_t)tex << 16) | (3u << 11) | (uint32_t)samp;
    vi_ref r = sel_fau_const_pair(t, lo, narrow);
    if (r.kind) return r;
    return sel_pair(t, vi_imm(lo), vi_imm(narrow));
}

// Result packing: dest words in write-mask order, then the LLVM type (32-bit / f16 / u16 / one component for depth).
static sv *tex_result(S *t, LLVMTypeRef rt, vi_ref raw, unsigned ncomp_read, bool depth_one)
{
    LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
    unsigned bits = 32, n = 4; bool flt = true;
    sel_type_info(vt, &bits, &n, &flt);
    if (depth_one) n = 1;
    vi_ref c[4];
    for (unsigned k = 0; k < n; k++) c[k] = k < ncomp_read ? vi_vreg(raw.value, k, 1) : vi_imm(0);
    sv *v;
    if (bits == 16 && flt) {
        v = sv_val(t, 16, n);
        for (unsigned k = 0; k < n; k += 2) {
            vi_instr *I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(v->vreg, k / 2, 1); I->src[0] = c[k]; I->src[1] = k + 1 < n ? c[k + 1] : vi_imm(0);
        }
    } else v = sv_from_comps32(t, bits, n, c);
    if (ts_LLVMGetTypeKind(rt) != LLVMStructTypeKind) return v;
    // { value, residency }: always resident
    sv *a = sv_new(t, SV_AGG);
    unsigned m = ts_LLVMCountStructElementTypes(rt);
    a->n = m; a->e = ralloc_array(t->mem, sv *, m);
    a->e[0] = v;
    for (unsigned i = 1; i < m; i++) { uint32_t one = 1; a->e[i] = sv_const(t, 1, 1, &one); }
    return a;
}

// Reads a 32-bit word of a resource descriptor through table 62 (the resource tables themselves).
static vi_ref descriptor_word(S *t, unsigned table, int index, unsigned word)
{
    vi_ref d = sel_tmp(t), off = sel_mov32(t, vi_imm((unsigned)index * 32 + word * 4));
    vi_instr *I = E(t, VA_LD_PKA_I32);
    I->sw = d;
    I->src[0] = off;
    I->src[1] = vi_imm((62u << 24) | table);
    vi_set(I, VAF_lane, VA_LOAD_LANE_32_M_NONE);
    return d;
}

// A texture slot without a texture has a null descriptor: halfword 0 is 0.
vi_ref sel_texture_is_null(S *t, int index)
{
    use_texture(t, index);
    vi_ref w0 = descriptor_word(t, 4, index, 0);
    vi_ref h = sel_tmp(t);
    vi_instr *I = E(t, VA_AND_I32); I->dest = h; I->src[0] = w0; I->src[2] = vi_imm(0xffff);
    vi_ref r = sel_tmp(t);
    I = E(t, VA_ICMP_U32); I->dest = r; I->src[0] = h; I->src[1] = vi_imm(0);
    vi_set(I, VAF_cmpf, VA_CMPF_M_EQ); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
    return r;
}

static vi_ref half_of(S *t, vi_ref w, unsigned lane)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_U16_TO_U32); I->dest = d; I->src[0] = w; vi_set(I, VAF_lane0, lane);
    return d;
}

// Size of level `lod` along each axis: max((size_minus_1 + 1) >> lod, 1).
static vi_ref level_size(S *t, vi_ref minus1, vi_ref lod)
{
    vi_ref sz = sel_iadd_imm(t, minus1, 1);
    if (lod.kind == VI_IMM && !lod.value) return sz;
    vi_ref s = sel_tmp(t);
    vi_instr *I = E(t, VA_RSHIFT_OR_I32); I->dest = s; I->src[0] = sz; I->src[1] = lod; I->src[2] = vi_imm(0);
    return sel_csel(t, VA_CMPF_M_LT, VA_CSEL_U32, s, vi_imm(1), vi_imm(1), s);
}

static sv *query(S *t, LLVMValueRef inst, const char *op, sv *tv, shape sh)
{
    USE(t, D6);
    unsigned nargs = ts_LLVMGetNumArgOperands(inst);
    vi_ref lod = vi_imm(0);
    if (nargs > 1 && !sh.ms) {
        sv *l = arg(t, inst, 1);
        if (!l) return NULL;
        lod = sv_comp32(t, l, 0, X_ZEXT);
    }
    unsigned table = 4;
    use_texture(t, tv->index);
    vi_ref r;
    if (sel_name_is(op, "get_num_mip_levels")) {
        vi_ref w2 = descriptor_word(t, table, tv->index, 2);
        vi_ref x = sel_tmp(t);
        vi_instr *I = E(t, VA_RSHIFT_AND_I32); I->dest = x; I->src[0] = w2; I->src[1] = vi_imm(16); I->src[2] = vi_imm(0x1f);
        r = sel_iadd_imm(t, x, 1);
    } else if (sel_name_is(op, "get_num_samples")) {
        if (!sh.ms) r = vi_imm(1);
        else {
            // samples: the image's sample count sysval (IMAGE_SAMPLES, id = texture | dim << 7 | array << 9)
            r = sel_mov32(t, sel_sysval_comp(t, 20, (unsigned)tv->index | (1u << 7) | (sh.array ? 1u << 9 : 0), 0));
        }
    } else {
        vi_ref w1 = descriptor_word(t, table, tv->index, 1);
        if (sel_name_is(op, "get_width")) r = level_size(t, half_of(t, w1, 0), lod);
        else if (sel_name_is(op, "get_height")) r = level_size(t, half_of(t, w1, 1), lod);
        else if (sel_name_is(op, "get_depth")) r = level_size(t, half_of(t, descriptor_word(t, table, tv->index, 7), 0), lod);
        else r = sel_iadd_imm(t, half_of(t, descriptor_word(t, table, tv->index, 6), 0), 1);   // array size
    }
    unsigned bits = 32, n = 1; bool flt;
    sel_type_info(ts_LLVMTypeOf(inst), &bits, &n, &flt);
    return sv_from_comps32(t, bits, 1, &r);
}

// Explicit / bias LOD as s16 8:8 fixed point: f32_to_s32(clamp(x/16, -1, 1) * 4096) & 0xffff
static vi_ref fixed_8_8(S *t, vi_ref x)
{
    vi_ref m = sel_tmp(t);
    vi_instr *I = E(t, VA_FMUL_F32); I->dest = m; I->src[0] = x; I->src[1] = vi_imm(0x3d800000);   // 1/16
    vi_ref c = sel_tmp(t);
    I = E(t, VA_FADD_F32); I->dest = c; I->src[0] = m; I->src[1] = vi_imm(0); vi_set(I, VAF_clamp, VA_CLAMP_M_CLAMP_M1_1);
    vi_ref s = sel_tmp(t);
    I = E(t, VA_FMUL_F32); I->dest = s; I->src[0] = c; I->src[1] = vi_imm(0x45800000);   // 4096
    vi_ref i = sel_tmp(t);
    I = E(t, VA_F32_TO_S32); I->dest = i; I->src[0] = s; vi_set(I, VAF_round, VA_ROUND_INTEGER_M_NONE);
    vi_ref d = sel_tmp(t);
    I = E(t, VA_AND_I32); I->dest = d; I->src[0] = i; I->src[2] = vi_imm(0xffff);
    return d;
}

// Cube coordinates: (s | face << 29, t) for the given direction.
static void cube_coords(S *t, vi_ref x, vi_ref y, vi_ref z, vi_ref *s_out, vi_ref *t_out)
{
    vi_ref mx = sel_tmp(t), face = sel_tmp(t);
    vi_instr *I = E(t, VA_CUBEFACE1); I->dest = mx; I->src[0] = x; I->src[1] = y; I->src[2] = z;
    I = E(t, VA_CUBEFACE2); I->dest = face; I->src[0] = x; I->src[1] = y; I->src[2] = z;
    vi_ref s = sel_tmp(t), tt = sel_tmp(t);
    I = E(t, VA_CUBE_SSEL); I->dest = s; I->src[0] = z; I->src[1] = x; I->src[2] = face;
    I = E(t, VA_CUBE_TSEL); I->dest = tt; I->src[0] = y; I->src[1] = z; I->src[2] = face;
    vi_ref half_over = sel_tmp(t);
    I = E(t, VA_FRCP_F32); I->dest = half_over; I->src[0] = mx;
    vi_ref h = sel_tmp(t);
    I = E(t, VA_FMUL_F32); I->dest = h; I->src[0] = half_over; I->src[1] = vi_imm(0x3f000000);
    vi_ref ss = sel_tmp(t), ts = sel_tmp(t);
    I = E(t, VA_FMA_F32); I->dest = ss; I->src[0] = s; I->src[1] = h; I->src[2] = vi_imm(0x3f000000); vi_set(I, VAF_clamp, VA_CLAMP_M_CLAMP_0_1);
    I = E(t, VA_FMA_F32); I->dest = ts; I->src[0] = tt; I->src[1] = h; I->src[2] = vi_imm(0x3f000000); vi_set(I, VAF_clamp, VA_CLAMP_M_CLAMP_0_1);
    // s & 0x1fffffff | face & 0xe0000000 (face is pre-shifted)
    vi_ref lo = sel_tmp(t), hi = sel_tmp(t), packed = sel_tmp(t);
    I = E(t, VA_AND_I32); I->dest = lo; I->src[0] = ss; I->src[2] = vi_imm(0x1fffffff);
    I = E(t, VA_AND_I32); I->dest = hi; I->src[0] = face; I->src[2] = vi_imm(0xe0000000);
    I = E(t, VA_OR_I32); I->dest = packed; I->src[0] = lo; I->src[2] = hi;
    *s_out = packed; *t_out = ts;
}

// Staging vector from up to 8 words.
static vi_ref staging(S *t, vi_ref *w, unsigned n)
{
    uint32_t v = vi_new_vreg(t->s, n);
    for (unsigned k = 0; k < n; k++) {
        vi_instr *I = w[k].kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
        if (w[k].kind == VI_IMM) vi_set(I, VAF_imm1w, w[k].value); else I->src[0] = w[k];
        I->dest = vi_vreg(v, k, 1);
    }
    return vi_vreg(v, 0, n);
}

static sv *read_texture(S *t, LLVMValueRef inst, const char *op, sv *tv, shape sh)
{
    // read_<shape>(tex, coord, [layer/face], [offset], [lod | sample])
    unsigned nargs = ts_LLVMGetNumArgOperands(inst), i = 1;
    if (is_ptr_arg(inst, 1)) i = 2;
    sv *coord = arg(t, inst, i++);
    if (!coord) return NULL;
    vi_ref layer = vi_none();
    if (sh.array || sh.dim == DIM_CUBE) { sv *l = arg(t, inst, i++); if (!l) return NULL; layer = sv_comp32(t, l, 0, X_ZEXT); }
    if (i < nargs && ts_LLVMGetTypeKind(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i))) == LLVMVectorTypeKind) i++;
    vi_ref lod = vi_imm(0);
    if (i < nargs) { sv *l = arg(t, inst, i); if (!l) return NULL; lod = sv_comp32(t, l, 0, X_ZEXT); }
    bool rw = strstr(op, "read_write") != NULL;
    LLVMTypeRef rt = ts_LLVMTypeOf(inst);
    bool depth = strstr(op, "depth") != NULL;
    if (sh.buffer) {
        USE(t, D4);
        // LEA_BUF of the element, then LD_CVT with the descriptor's conversion (word 7, table 62)
        use_texture(t, tv->index);
        vi_ref x = sv_comp32(t, coord, 0, X_ZEXT);
        uint32_t a = vi_new_vreg(t->s, 2);
        vi_instr *I = E(t, VA_LEA_BUF);
        I->sw = vi_vreg(a, 0, 2); I->src[0] = x; I->src[1] = vi_imm((4u << 24) | (unsigned)tv->index);
        vi_ref cvt = descriptor_word(t, 4, tv->index, 7);
        vi_ref conv = sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_U32, cvt, vi_imm(0), vi_imm((95u << 12) | 231u), cvt);
        uint32_t d = vi_new_vreg(t->s, 4);
        I = E(t, VA_LD_CVT);
        I->sw = vi_vreg(d, 0, 4); I->src[0] = vi_vreg(a, 0, 2); I->src[2] = conv;
        unsigned b = 32, n = 4; bool f = true;
        LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
        sel_type_info(vt, &b, &n, &f);
        vi_set(I, VAF_register_format, f ? VA_REGISTER_FILE_FORMAT_GENERAL_M_F32 : VA_REGISTER_FILE_FORMAT_GENERAL_M_U32);
        vi_set(I, VAF_vecsize, VA_VECSIZE_VARYING_M_V4);
        vi_set(I, VAF_offset, 0);
        I->memory = true;
        return tex_result(t, rt, vi_vreg(d, 0, 4), 4, false);
    }
    if (rw && t->stage != MESA_SHADER_VERTEX) {
        USE(t, D5);
        // image load: LD_TEX_IMM (table 5), coordinates as u16 pairs
        t->refl->textures_written |= 1u << tv->index;
        t->info.images_used |= 1ull << tv->index;
        vi_ref c[3] = { sv_comp32(t, coord, 0, X_ZEXT), coord->ncomp > 1 ? sv_comp32(t, coord, 1, X_ZEXT) : vi_imm(0),
                        coord->ncomp > 2 ? sv_comp32(t, coord, 2, X_ZEXT) : layer.kind ? layer : vi_imm(0) };
        vi_ref xy = sel_tmp(t), zw = sel_tmp(t);
        vi_instr *I = E(t, VA_MKVEC_V2I16); I->dest = xy; I->src[0] = c[0]; I->src[1] = c[1]; vi_set(I, VAF_lane0, 0); vi_set(I, VAF_lane1, 0);
        I = E(t, VA_MKVEC_V2I16); I->dest = zw; I->src[0] = coord->ncomp > 2 ? c[2] : vi_imm(0); I->src[1] = coord->ncomp > 2 ? (layer.kind ? layer : vi_imm(0)) : (layer.kind ? layer : vi_imm(0));
        vi_set(I, VAF_lane0, 0); vi_set(I, VAF_lane1, 0);
        if (coord->ncomp <= 2 && layer.kind) { I->src[0] = vi_imm(0); I->src[1] = layer; }
        uint32_t d = vi_new_vreg(t->s, 4);
        if (tv->index < 16) {
            I = E(t, VA_LD_TEX_IMM);
            vi_set(I, VAF_encoded_texture_table_index, 5); vi_set(I, VAF_texture_index, tv->index);
        } else { I = E(t, VA_LD_TEX); I->src[2] = vi_imm((5u << 24) | (unsigned)tv->index); }
        I->sw = vi_vreg(d, 0, 4); I->src[0] = xy; I->src[1] = zw;
        unsigned b = 32, n = 4; bool f = true;
        LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
        sel_type_info(vt, &b, &n, &f);
        vi_set(I, VAF_register_format, f ? VA_REGISTER_FILE_FORMAT_GENERAL_M_F32 : VA_REGISTER_FILE_FORMAT_GENERAL_M_U32);
        vi_set(I, VAF_vecsize, VA_VECSIZE_VARYING_M_V4);
        I->memory = true;
        return tex_result(t, rt, vi_vreg(d, 0, 4), 4, false);
    }
    USE(t, D4);
    use_texture(t, tv->index);
    // TEX_FETCH reads sampler 0 of the table (Gallium always has one); not a Metal sampler argument
    if (t->info.sampler_count < 1) t->info.sampler_count = 1;
    // TEX_FETCH: coords (cube = 2D array), array, offset word (ms index in .z, lod in .w)
    vi_ref w[8];
    unsigned n = 0;
    unsigned dims = sh.dim == DIM_CUBE ? 2 : sh.coords;
    for (unsigned k = 0; k < dims; k++) w[n++] = sv_comp32(t, coord, k, X_ZEXT);
    bool array = sh.array || sh.dim == DIM_CUBE;
    if (array) {
        vi_ref l = layer;
        if (sh.dim == DIM_CUBE && sh.array) {
            // cube array: layer * 6 + face (face given as the layer argument after the array index? Metal: face, then array)
            l = layer;
        }
        w[n++] = l;
    }
    // offset word: (0, 0, ms index, lod)
    vi_ref offs;
    if (sh.ms) {
        vi_ref sidx = lod;   // for MS reads the last argument is the sample
        offs = sel_tmp(t);
        vi_instr *I = E(t, VA_LSHIFT_OR_I32); I->dest = offs; I->src[0] = sidx; I->src[1] = vi_imm(16); I->src[2] = vi_imm(0);
    } else {
        vi_ref l = sel_csel(t, VA_CMPF_M_GT, VA_CSEL_U32, lod, vi_imm(255), vi_imm(255), lod);
        offs = sel_tmp(t);
        vi_instr *I = E(t, VA_LSHIFT_OR_I32); I->dest = offs; I->src[0] = l; I->src[1] = vi_imm(24); I->src[2] = vi_imm(0);
    }
    w[n++] = offs;
    vi_ref sr = staging(t, w, n);
    uint32_t d = vi_new_vreg(t->s, 4);
    vi_ref desc = descriptor(t, tv->index, 0, 0);
    vi_instr *I = E(t, VA_TEX_FETCH);
    I->sr = sr; I->sw = vi_vreg(d, 0, depth ? 1 : 4);
    I->src[0] = desc;
    vi_set(I, VAF_dimensionality, sh.dim == DIM_CUBE ? DIM_2D : sh.dim);
    vi_set(I, VAF_array_enable, array);
    vi_set(I, VAF_texel_offset, 1);
    vi_set(I, VAF_write_mask, depth ? 1 : 15);
    vi_set(I, VAF_register_width, 1);
    vi_set(I, VAF_wide_indices, 0);
    vi_set(I, VAF_skip, 0);
    return tex_result(t, rt, vi_vreg(d, 0, 4), depth ? 1 : 4, depth);
}

static sv *write_texture(S *t, LLVMValueRef inst, sv *tv, shape sh)
{
    USE(t, D5);
    // write_<shape>(tex, coord, [layer/face], value, lod, access)
    unsigned i = 1, nargs = ts_LLVMGetNumArgOperands(inst);
    sv *coord = arg(t, inst, i++);
    if (!coord) return NULL;
    vi_ref layer = vi_none();
    if (sh.array || sh.dim == DIM_CUBE) { sv *l = arg(t, inst, i++); if (!l) return NULL; layer = sv_comp32(t, l, 0, X_ZEXT); }
    unsigned vi = i++;
    sv *data = arg(t, inst, vi);
    if (!data) return NULL;
    (void)nargs;
    bool flt = sel_is_float(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, vi)));
    t->refl->textures_written |= 1u << tv->index;
    t->info.images_used |= 1ull << tv->index;
    t->info.writes_global = true;
    vi_ref c0 = sv_comp32(t, coord, 0, X_ZEXT), c1 = coord->ncomp > 1 ? sv_comp32(t, coord, 1, X_ZEXT) : vi_imm(0);
    vi_ref c2 = coord->ncomp > 2 ? sv_comp32(t, coord, 2, X_ZEXT) : vi_imm(0);
    vi_ref xy = sel_tmp(t), zw = sel_tmp(t);
    vi_instr *I = E(t, VA_MKVEC_V2I16); I->dest = xy; I->src[0] = c0; I->src[1] = c1; vi_set(I, VAF_lane0, 0); vi_set(I, VAF_lane1, 0);
    I = E(t, VA_MKVEC_V2I16); I->dest = zw; I->src[0] = coord->ncomp > 2 ? c2 : vi_imm(0); I->src[1] = layer.kind ? layer : vi_imm(0);
    vi_set(I, VAF_lane0, 0); vi_set(I, VAF_lane1, 0);
    if (coord->ncomp > 2 && layer.kind) { I->src[0] = c2; }
    // LEA_TEX -> {address lo, hi, conversion}
    uint32_t a = vi_new_vreg(t->s, 3);
    if (tv->index < 16) {
        I = E(t, VA_LEA_TEX_IMM);
        vi_set(I, VAF_encoded_texture_table_index, 5); vi_set(I, VAF_texture_index, tv->index);
    } else { I = E(t, VA_LEA_TEX); I->src[2] = vi_imm((5u << 24) | (unsigned)tv->index); }
    I->sw = vi_vreg(a, 0, 3); I->src[0] = xy; I->src[1] = zw;
    vi_ref w[4];
    for (unsigned k = 0; k < 4; k++) w[k] = k < data->ncomp ? sv_comp32(t, data, k, flt ? X_F32 : X_ZEXT) : vi_imm(0);
    vi_ref val = staging(t, w, 4);
    vi_ref addr = sel_pair(t, vi_vreg(a, 0, 1), vi_vreg(a, 1, 1));
    I = E(t, VA_ST_CVT);
    I->sr = val; I->src[0] = addr; I->src[2] = vi_vreg(a, 2, 1);
    vi_set(I, VAF_register_format, flt ? VA_REGISTER_FILE_FORMAT_GENERAL_M_F32 : VA_REGISTER_FILE_FORMAT_GENERAL_M_U32);
    vi_set(I, VAF_vecsize, VA_VECSIZE_VARYING_M_V4);
    vi_set(I, VAF_offset, 0);
    I->memory = true;
    return sv_new(t, SV_NONE);
}

sv *sel_texture(S *t, LLVMValueRef inst, const char *name)
{
    const char *op = name + 4;
    bool is_tex = sel_name_is(op, "sample_") || sel_name_is(op, "read_") || sel_name_is(op, "write_") || sel_name_is(op, "gather_") ||
                  sel_name_is(op, "get_width_") || sel_name_is(op, "get_height_") || sel_name_is(op, "get_depth_") ||
                  sel_name_is(op, "get_array_size_") || sel_name_is(op, "get_num_mip_levels_") || sel_name_is(op, "get_num_samples_") ||
                  sel_name_is(op, "is_null_texture");
    if (!is_tex) return NULL;
    LLVMValueRef texArg = ts_LLVMGetOperand(inst, 0);
    LLVMTypeRef rt = ts_LLVMTypeOf(inst);
    if (ts_LLVMIsUndef(texArg)) {
        if (ts_LLVMGetTypeKind(rt) == LLVMVoidTypeKind) return sv_new(t, SV_NONE);
        unsigned b = 32, n = 4; bool f; sel_type_info(rt, &b, &n, &f);
        uint32_t z[8] = {0};
        return sv_const(t, b, n, z);
    }
    sv *tv = sel_value(t, texArg);
    if (!tv) return NULL;
    if (tv->kind != SV_TEX) SFAIL(t, "texture call on a non-texture");
    shape sh = shape_of(op);
    if (sel_name_is(op, "is_null_texture")) { USE(t, D6); vi_ref r = sel_texture_is_null(t, tv->index); return sv_from_comps32(t, 1, 1, &r); }
    if (sel_name_is(op, "get_")) return query(t, inst, op, tv, sh);
    if (sel_name_is(op, "write_")) return write_texture(t, inst, tv, sh);
    if (sel_name_is(op, "read_")) return read_texture(t, inst, op, tv, sh);

    // sample[_compare]_<shape>[_grad](tex, sampler, [i32 1 for depth/compare], coord, [layer], [ref], ...)
    // gather[_compare]_<shape>(tex, sampler, [i32 1], coord, [layer], [ref], [normalized, offset], [component])
    bool gather = sel_name_is(op, "gather");
    bool cmp = strstr(op, "_compare") != NULL;
    bool grad = strstr(op, "_grad") != NULL;
    bool depth = strstr(op, "depth") != NULL;
    if (gather) USE(t, D3); else if (cmp) USE(t, D2); else USE(t, D1);
    if (depth) USE(t, D8);
    sv *smp = sel_value(t, ts_LLVMGetOperand(inst, 1));
    if (!smp) return NULL;
    if (smp->kind != SV_SMP) SFAIL(t, "sample without a sampler");
    USE(t, D7);
    unsigned nargs = ts_LLVMGetNumArgOperands(inst), i = 2;
    if (cmp || depth) {
        LLVMValueRef x = ts_LLVMGetOperand(inst, 2);
        if (ts_LLVMIsAConstantInt(x) && ts_LLVMGetIntTypeWidth(ts_LLVMTypeOf(x)) == 32) i = 3;
    }
    sv *coord = arg(t, inst, i++);
    if (!coord) return NULL;
    use_texture(t, tv->index);
    use_sampler(t, smp->index);
    vi_ref c[3];
    for (unsigned k = 0; k < sh.coords; k++) c[k] = sv_comp32(t, coord, k, X_F32);
    if (smp->pixel && sh.dim != DIM_CUBE) {
        // coord::pixel: divide by the level-0 size (descriptor)
        vi_ref w1 = descriptor_word(t, 4, tv->index, 1);
        for (unsigned k = 0; k < sh.coords && k < 2; k++) {
            vi_ref sz = sel_iadd_imm(t, half_of(t, w1, k), 1);
            vi_ref f = sel_tmp(t);
            vi_instr *I = E(t, VA_U32_TO_F32); I->dest = f; I->src[0] = sz;
            vi_ref r = sel_tmp(t);
            I = E(t, VA_FRCP_F32); I->dest = r; I->src[0] = f;
            vi_ref q = sel_tmp(t);
            I = E(t, VA_FMUL_F32); I->dest = q; I->src[0] = c[k]; I->src[1] = r;
            c[k] = q;
        }
    }
    vi_ref layer = vi_none(), ref = vi_none();
    if (sh.array) {
        sv *l = arg(t, inst, i++);
        if (!l) return NULL;
        LLVMTypeRef lt = ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i - 1));
        // TEX_SINGLE/TEX_GATHER take the array index as a float (Mesa passes GL's float layer coordinate as is); an
        // integer 1 read as a float is a denormal, i.e. always layer 0 on the phone (D1 2D array)
        if (sel_is_float(lt)) layer = sv_comp32(t, l, 0, X_F32);
        else {
            vi_ref u = sv_comp32(t, l, 0, X_ZEXT);
            vi_ref f = sel_tmp(t);
            vi_instr *I = E(t, VA_U32_TO_F32); I->dest = f; I->src[0] = u.kind == VI_IMM ? sel_mov32(t, u) : u;
            layer = f;
        }
    }
    if (cmp) { sv *r = arg(t, inst, i++); if (!r) return NULL; ref = sv_comp32(t, r, 0, X_F32); }
    vi_ref w[8];
    unsigned n = 0;
    if (sh.dim == DIM_CUBE) {
        vi_ref s, tt;
        cube_coords(t, c[0], c[1], c[2], &s, &tt);
        w[n++] = s; w[n++] = tt;
    } else for (unsigned k = 0; k < sh.coords; k++) w[n++] = c[k];
    if (layer.kind) w[n++] = layer;
    if (ref.kind) w[n++] = ref;
    uint32_t narrow = 0;
    bool texel_offset = false;
    int lod_mode = VA_TEX_LOD_MODE_M_COMPUTED;
    vi_ref lodw = vi_none();
    unsigned gather_comp = 0;
    vi_ref grdesc = vi_none();
    if (grad) {
        // TEX_GRADIENT computes the gradient descriptor from (dx, dy) per axis
        sv *dx = arg(t, inst, i), *dy = arg(t, inst, i + 1);
        if (!dx || !dy) return NULL;
        i += 2;
        if (i < nargs && ts_LLVMGetTypeKind(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i))) == LLVMIntegerTypeKind &&
            ts_LLVMGetIntTypeWidth(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i))) == 1) i++;
        vi_ref gw[6];
        unsigned gn = 0, axes = sh.dim == DIM_CUBE ? 3 : sh.coords;
        for (unsigned k = 0; k < axes; k++) { gw[gn++] = sv_comp32(t, dx, k, X_F32); gw[gn++] = sv_comp32(t, dy, k, X_F32); }
        vi_ref gsr = staging(t, gw, gn);
        uint32_t gd = vi_new_vreg(t->s, 2);
        vi_ref gdesc = descriptor(t, tv->index, smp->index, 0);
        vi_instr *G = E(t, VA_TEX_GRADIENT);
        G->sr = gsr; G->sw = vi_vreg(gd, 0, 2);
        G->src[0] = gdesc;
        vi_set(G, VAF_dimensionality, sh.dim);
        vi_set(G, VAF_derivative_enable, 1);
        vi_set(G, VAF_lod_clamp_disable, 1);
        vi_set(G, VAF_lod_bias_disable, 1);
        vi_set(G, VAF_write_mask, 3);
        vi_set(G, VAF_register_width, 1);
        vi_set(G, VAF_wide_indices, 0);
        vi_set(G, VAF_skip, 0);
        grdesc = vi_vreg(gd, 0, 2);
        lod_mode = VA_TEX_LOD_MODE_M_GRDESC;
    } else {
        if (sh.dim != DIM_CUBE && i < nargs) i++;   // normalized-coordinates flag
        if (sh.dim != DIM_CUBE && i < nargs) {
            LLVMValueRef off = ts_LLVMGetOperand(inst, i++);
            if (!ts_LLVMIsAConstantAggregateZero(off)) {
                sv *o = sel_ssa(t, off);
                if (!o) return NULL;
                // constant offsets in [-8, 7]: nibbles of the narrow word; else a u8x4 register
                bool small = o->is_const;
                for (unsigned k = 0; k < o->ncomp && small; k++) { int32_t v = (int32_t)sv_comp32(t, o, k, X_SEXT).value; if (v < -8 || v > 7) small = false; }
                if (small) for (unsigned k = 0; k < o->ncomp; k++) narrow |= (sv_comp32(t, o, k, X_SEXT).value & 0xf) << (4 * k);
                else {
                    vi_ref oc[4] = { vi_imm(0), vi_imm(0), vi_imm(0), vi_imm(0) };
                    for (unsigned k = 0; k < o->ncomp && k < 3; k++) oc[k] = sv_comp32(t, o, k, X_SEXT);
                    sv *packed = sv_from_comps32(t, 8, 4, oc);
                    texel_offset = true;
                    lodw = vi_none();
                    w[n++] = sv_word(t, packed, 0);
                }
            }
        }
        if (gather) {
            if (!depth && i + 1 < nargs) {
                LLVMValueRef cv = ts_LLVMGetOperand(inst, i);
                if (ts_LLVMIsAConstantInt(cv)) gather_comp = (unsigned)ts_LLVMConstIntGetZExtValue(cv);
            }
        } else if (i + 1 < nargs) {
            LLVMValueRef isLod = ts_LLVMGetOperand(inst, i++);
            sv *amount = arg(t, inst, i++);
            if (!amount) return NULL;
            bool lod = ts_LLVMIsAConstantInt(isLod) && ts_LLVMConstIntGetZExtValue(isLod);
            vi_ref a = sv_comp32(t, amount, 0, X_F32);
            sv *minl = NULL;
            if (i < nargs) {
                LLVMValueRef minv = ts_LLVMGetOperand(inst, i);
                if (sel_is_float(ts_LLVMTypeOf(minv)) && !ts_LLVMIsAConstantFP(minv)) { minl = sel_ssa(t, minv); if (!minl) return NULL; }
            }
            if (lod || t->stage != MESA_SHADER_FRAGMENT) {
                if (!lod) a = vi_imm(0);
                if (a.kind == VI_IMM && a.value == 0) lod_mode = VA_TEX_LOD_MODE_M_NONE;   // zero lod
                else { lod_mode = VA_TEX_LOD_MODE_M_EXPLICIT; lodw = fixed_8_8(t, a); }
            } else if (!(a.kind == VI_IMM && a.value == 0) || minl) {
                lod_mode = VA_TEX_LOD_MODE_M_COMPUTED_BIAS;
                vi_ref bias = a.kind == VI_IMM && a.value == 0 ? vi_imm(0) : fixed_8_8(t, a);
                vi_ref mn = minl ? fixed_8_8(t, sv_comp32(t, minl, 0, X_F32)) : vi_imm(0);
                vi_ref d = sel_tmp(t);
                vi_instr *I = E(t, VA_MKVEC_V2I16); I->dest = d; I->src[0] = bias; I->src[1] = mn; vi_set(I, VAF_lane0, 0); vi_set(I, VAF_lane1, 0);
                lodw = d;
            }
        } else if (t->stage != MESA_SHADER_FRAGMENT) lod_mode = VA_TEX_LOD_MODE_M_NONE;
    }
    if (lodw.kind) w[n++] = lodw;
    if (grdesc.kind) { w[n++] = vi_vreg(grdesc.value, 0, 1); w[n++] = vi_vreg(grdesc.value, 1, 1); }
    if (n > 8) SFAIL(t, "too many texture operands");
    bool implicit = !gather && (lod_mode == VA_TEX_LOD_MODE_M_COMPUTED || lod_mode == VA_TEX_LOD_MODE_M_COMPUTED_BIAS);
    if (gather) implicit = false;
    vi_ref sr = staging(t, w, n);
    unsigned wm = (depth && !gather) || cmp ? (gather ? 15 : 1) : 15;
    // half results (sample_texture_*.v4f16): the texture unit writes them packed two per register (register width
    // 16, as Mesa does), instead of four f32 registers converted back with V2F32_TO_V2F16
    bool half_out = false;
    {
        LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
        unsigned rb = 32, rn = 4; bool rf = false;
        half_out = sel_type_info(vt, &rb, &rn, &rf) && rb == 16 && rf && rn == 4 && !gather && !depth && !cmp &&
                   !getenv("VMG_ISA_NO_TEX16");
    }
    uint32_t d = vi_new_vreg(t->s, half_out ? 2 : 4);
    vi_ref desc = descriptor(t, tv->index, smp->index, narrow);
    vi_instr *I = E(t, gather ? VA_TEX_GATHER : VA_TEX_SINGLE);
    I->sr = sr; I->sw = vi_vreg(d, 0, half_out ? 2 : util_bitcount(wm));
    I->src[0] = desc;
    vi_set(I, VAF_dimensionality, sh.dim);
    vi_set(I, VAF_array_enable, sh.array);
    vi_set(I, VAF_texel_offset, texel_offset);
    vi_set(I, VAF_compare_enable, cmp);
    if (!gather) vi_set(I, VAF_lod_mode, lod_mode);
    else { vi_set(I, VAF_gather_component, gather_comp & 3); vi_set(I, VAF_coordinate_mode, 0); }
    vi_set(I, VAF_write_mask, wm);
    vi_set(I, VAF_register_width, half_out ? 0 : 1);
    vi_set(I, VAF_wide_indices, 0);
    vi_set(I, VAF_skip, 0);
    if (implicit && t->stage == MESA_SHADER_FRAGMENT) { I->helpers = true; t->info.helpers = true; }
    if (half_out) {
        sv *v = sv_val(t, 16, 4);
        for (unsigned k = 0; k < 2; k++) { vi_instr *M = E(t, VA_MOV_I32); M->dest = vi_vreg(v->vreg, k, 1); M->src[0] = vi_vreg(d, k, 1); }
        if (ts_LLVMGetTypeKind(rt) != LLVMStructTypeKind) return v;
        sv *a = sv_new(t, SV_AGG);
        unsigned m = ts_LLVMCountStructElementTypes(rt);
        a->n = m; a->e = ralloc_array(t->mem, sv *, m);
        a->e[0] = v;
        for (unsigned i = 1; i < m; i++) { uint32_t one = 1; a->e[i] = sv_const(t, 1, 1, &one); }
        return a;
    }
    if (gather) {
        // TEX_GATHER returns the footprint as (h0, h1, h2, h3); Metal's order is (h2, h3, h1, h0) (what Mesa's code for
        // the same shader writes out: the D3 gather had channels 2 and 3 swapped on the phone).
        uint32_t g = vi_new_vreg(t->s, 4);
        static const unsigned order[4] = { 2, 3, 1, 0 };
        for (unsigned k = 0; k < 4; k++) {
            vi_instr *M = E(t, VA_MOV_I32); M->dest = vi_vreg(g, k, 1); M->src[0] = vi_vreg(d, order[k], 1);
        }
        d = g;
    }
    return tex_result(t, rt, vi_vreg(d, 0, 4), util_bitcount(wm), ((depth && !gather) || cmp) && !gather);
}
