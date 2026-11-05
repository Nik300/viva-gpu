// Viva ISA compiler: SIMD-group and quad functions (F1-F4) and derivatives (E12).
//
// Valhall warps are 16 lanes (the Metal SIMD-group). CLPER reads a register of another lane (lane index, or
// lane ^ mask) inside a group of 2/4/8/16 lanes, with a chosen value for inactive lanes; WMASK turns a per-lane
// boolean into the mask of the lanes where it holds (ballot). Reductions are butterflies of CLPER.xor with the
// operation's identity for inactive lanes. Derivatives are differences with the neighbour in the 2x2 quad
// (CLPER.xor 1 / 2 in groups of 4), sign-corrected for odd lanes, as the hardware's quad layout requires.
#include "vi_sel.h"
#include <string.h>

static vi_ref lane_id(S *t) { return sel_mov32(t, vi_special(3, 2)); }

static vi_ref clper(S *t, vi_ref x, vi_ref lane, int op, int group, int inactive)
{
    vi_ref d = sel_tmp(t);
    vi_ref xs = x.kind == VI_IMM ? sel_mov32(t, x) : x;
    vi_instr *I = E(t, VA_CLPER);
    I->dest = d;
    I->src[0] = xs;
    I->src[1] = lane;
    vi_set(I, VAF_lane_op, op);
    vi_set(I, VAF_subgroup, group);
    vi_set(I, VAF_inactive_result, inactive);
    vi_set(I, VAF_lanes1, VA_SHIFT_BITWISE_I32_LANES_M_B0);
    return d;
}

static vi_ref ballot(S *t, vi_ref b)
{
    vi_ref d = sel_tmp(t);
    vi_ref bs = b.kind == VI_IMM ? sel_mov32(t, b) : b;
    vi_instr *I = E(t, VA_WMASK);
    I->dest = d; I->src[0] = bs;
    vi_set(I, VAF_subgroup, VA_CLPER_SUBGROUP_SIZE_M_SUBGROUP16);
    return d;
}

static vi_ref first_lane(S *t)
{
    vi_ref m = ballot(t, vi_imm(1));
    vi_ref r = sel_alu1(t, VA_BITREV_I32, m);
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_CLZ_U32); I->dest = d; I->src[0] = r; vi_set(I, VAF_mask, 0);
    return d;
}

// The 4 bits of a SIMD-group mask that belong to the thread's quad (quad_any/all/ballot are per quad).
static vi_ref quad_bits(S *t, vi_ref m)
{
    vi_ref base = sel_tmp(t), lid = lane_id(t);   // (the lane id MOV must come first)
    vi_instr *I = E(t, VA_AND_I32); I->dest = base; I->src[0] = lid; I->src[2] = vi_imm(~3u);
    vi_ref sh = sel_tmp(t);
    I = E(t, VA_RSHIFT_OR_I32); I->dest = sh; I->src[0] = m; I->src[1] = base; I->src[2] = vi_imm(0);
    vi_ref r = sel_tmp(t);
    I = E(t, VA_AND_I32); I->dest = r; I->src[0] = sh; I->src[2] = vi_imm(15u);
    return r;
}

static sv *arg(S *t, LLVMValueRef inst, unsigned i)
{
    if (i >= (unsigned)ts_LLVMGetNumArgOperands(inst)) SFAIL(t, "missing argument");
    return sel_ssa(t, ts_LLVMGetOperand(inst, i));
}

// Applies f to each 32-bit word of x (values move between lanes bit-exactly).
typedef vi_ref (*word_fn)(S *t, vi_ref w, void *ctx);

static sv *per_word(S *t, sv *x, word_fn f, void *ctx)
{
    sv *m = sv_materialize(t, x);
    unsigned n = sv_words(m->bits, m->ncomp);
    sv *r = sv_val(t, m->bits, m->ncomp);
    for (unsigned w = 0; w < n; w++) {
        vi_ref v = f(t, vi_vreg(m->vreg, w, 1), ctx);
        vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(r->vreg, w, 1); I->src[0] = v;
    }
    return r;
}

// CLPER takes the lane index from one lane for the whole warp (Mesa lowers divergent shuffles to a loop over uniform
// indices; on the phone a per-lane index read lane 15 everywhere). A per-lane index is therefore done as one CLPER per
// possible lane (immediate index, 16 for the SIMD-group or 4 inside the quad) and a select on the index.
typedef struct { vi_ref lane; int op, group; bool uniform; } perm;   // uniform: lane is the same in every thread
static bool uniform_ref(vi_ref r) { return r.kind == VI_IMM || r.kind == VI_FAU; }
static vi_ref do_perm(S *t, vi_ref w, void *ctx)
{
    perm *p = ctx;
    if (p->uniform || uniform_ref(p->lane) || p->op != VA_CLPER_LANE_OP_M_NONE)
        return clper(t, w, p->lane.kind == VI_IMM ? sel_mov32(t, p->lane) : p->lane, p->op, p->group, VA_CLPER_INACTIVE_RESULT_M_ZERO);
    unsigned n = p->group == VA_CLPER_SUBGROUP_SIZE_M_SUBGROUP4 ? 4 : 16;
    vi_ref r = clper(t, w, sel_mov32(t, vi_imm(0)), VA_CLPER_LANE_OP_M_NONE, p->group, VA_CLPER_INACTIVE_RESULT_M_ZERO);
    for (unsigned i = 1; i < n; i++) {
        vi_ref c = clper(t, w, sel_mov32(t, vi_imm(i)), VA_CLPER_LANE_OP_M_NONE, p->group, VA_CLPER_INACTIVE_RESULT_M_ZERO);
        r = sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_U32, p->lane, vi_imm(i), c, r);
    }
    return r;
}

// ---- Reductions (F3) --------------------------------------------------------------------------------------------------

enum { R_ADD, R_MUL, R_MIN, R_MAX };

static vi_ref combine(S *t, int op, bool flt, bool sgn, vi_ref a, vi_ref b)
{
    switch (op) {
    case R_ADD: return sel_alu2(t, flt ? VA_FADD_F32 : VA_IADD_U32, a, b);
    case R_MUL: return sel_alu2(t, flt ? VA_FMUL_F32 : VA_IMUL_U32, a, b);
    case R_MIN:
        if (flt) { vi_ref d = sel_tmp(t); vi_instr *I = E(t, VA_FMIN_F32); I->dest = d; I->src[0] = a; I->src[1] = b; vi_set(I, VAF_sem, VA_SEM_M_NAN_SUPPRESS); return d; }
        return sel_csel(t, VA_CMPF_M_LT, sgn ? VA_CSEL_S32 : VA_CSEL_U32, a, b, a, b);
    default:
        if (flt) { vi_ref d = sel_tmp(t); vi_instr *I = E(t, VA_FMAX_F32); I->dest = d; I->src[0] = a; I->src[1] = b; vi_set(I, VAF_sem, VA_SEM_M_NAN_SUPPRESS); return d; }
        return sel_csel(t, VA_CMPF_M_GT, sgn ? VA_CSEL_S32 : VA_CSEL_U32, a, b, a, b);
    }
}

static int identity(int op, bool flt, bool sgn)
{
    switch (op) {
    case R_ADD: return VA_CLPER_INACTIVE_RESULT_M_ZERO;
    case R_MUL: return flt ? VA_CLPER_INACTIVE_RESULT_M_F1 : VA_CLPER_INACTIVE_RESULT_M_I1;
    case R_MIN: return flt ? VA_CLPER_INACTIVE_RESULT_M_INF : sgn ? VA_CLPER_INACTIVE_RESULT_M_SMAX : VA_CLPER_INACTIVE_RESULT_M_UMAX;
    default: return flt ? VA_CLPER_INACTIVE_RESULT_M_INFN : sgn ? VA_CLPER_INACTIVE_RESULT_M_SMIN : VA_CLPER_INACTIVE_RESULT_M_ZERO;
    }
}

static sv *reduce(S *t, sv *x, int op, bool flt, bool sgn, bool quad)
{
    USE(t, F3);
    vi_ref r[16];
    for (unsigned c = 0; c < x->ncomp; c++) {
        vi_ref v = sv_comp32(t, x, c, flt ? X_F32 : sgn ? X_SEXT : X_ZEXT);
        for (unsigned m = 1; m < (quad ? 4u : 16u); m <<= 1) {
            vi_ref o = clper(t, v, vi_imm(m), VA_CLPER_LANE_OP_M_XOR, quad ? VA_CLPER_SUBGROUP_SIZE_M_SUBGROUP4 : VA_CLPER_SUBGROUP_SIZE_M_SUBGROUP16,
                             identity(op, flt, sgn));
            v = combine(t, op, flt, sgn, v, o);
        }
        r[c] = v;
    }
    if (flt && x->bits == 16) {
        sv *v = sv_val(t, 16, x->ncomp);
        for (unsigned c = 0; c < x->ncomp; c += 2) {
            vi_instr *I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(v->vreg, c / 2, 1); I->src[0] = r[c]; I->src[1] = c + 1 < x->ncomp ? r[c + 1] : vi_imm(0);
        }
        return v;
    }
    return sv_from_comps32(t, x->bits, x->ncomp, r);
}

sv *sel_subgroup(S *t, LLVMValueRef inst, const char *name)
{
    bool quad = sel_name_is(name, "air.quad_");
    const char *op = name + 9;   // "air.simd_" / "air.quad_"
    t->info.subgroups = true;
    unsigned nargs = ts_LLVMGetNumArgOperands(inst);
    sv *x = nargs ? arg(t, inst, 0) : NULL;
    sv *y = nargs > 1 ? arg(t, inst, 1) : NULL;
    if ((nargs && !x) || (nargs > 1 && !y)) return NULL;
    bool flt = sel_is_float(ts_LLVMTypeOf(inst));
    bool sgn = strstr(name, ".s.") != NULL;
    int group = quad ? VA_CLPER_SUBGROUP_SIZE_M_SUBGROUP4 : VA_CLPER_SUBGROUP_SIZE_M_SUBGROUP16;
    perm p = { vi_none(), VA_CLPER_LANE_OP_M_NONE, group, false };
    if (sel_name_is(op, "shuffle_xor")) {
        USE(t, F1);
        p.lane = sv_comp32(t, y, 0, X_ZEXT); p.op = VA_CLPER_LANE_OP_M_XOR;
        if (!uniform_ref(p.lane)) {
            // per-thread mask: the lane index itself, inside the group
            vi_ref l = lane_id(t);
            if (quad) { vi_ref q = sel_tmp(t); vi_instr *I = E(t, VA_AND_I32); I->dest = q; I->src[0] = l; I->src[2] = vi_imm(3u); l = q; }
            vi_ref x2 = sel_tmp(t);
            vi_instr *I = E(t, VA_XOR_I32); I->dest = x2; I->src[0] = l; I->src[2] = p.lane;
            vi_ref m = sel_tmp(t);
            I = E(t, VA_AND_I32); I->dest = m; I->src[0] = x2; I->src[2] = vi_imm(quad ? 3u : 15u);
            p.lane = m; p.op = VA_CLPER_LANE_OP_M_NONE;
        }
        return per_word(t, x, do_perm, &p);
    }
    if (sel_name_is(op, "shuffle_up") || sel_name_is(op, "shuffle_down")) {
        USE(t, F1);
        // lane -/+ delta (out of range: the lane's own value, as Metal leaves it unchanged)
        vi_ref l = lane_id(t), d = sv_comp32(t, y, 0, X_ZEXT);
        bool up = sel_name_is(op, "shuffle_up");
        unsigned limit = quad ? 4 : 16;
        vi_ref within = l;
        if (quad) {
            within = sel_tmp(t);
            vi_instr *I = E(t, VA_AND_I32); I->dest = within; I->src[0] = l; I->src[2] = vi_imm(3u);
        }
        // index inside the group (unsigned compare: below 0 wraps above the limit)
        vi_ref src = sel_alu2(t, up ? VA_ISUB_S32 : VA_IADD_U32, within, d);
        p.lane = sel_csel(t, VA_CMPF_M_LT, VA_CSEL_U32, src, vi_imm(limit), src, within);
        return per_word(t, x, do_perm, &p);
    }
    if (sel_name_is(op, "shuffle") || sel_name_is(op, "broadcast_first") || sel_name_is(op, "broadcast")) {
        USE(t, F2);
        if (sel_name_is(op, "shuffle")) USE(t, F1);
        if (sel_name_is(op, "broadcast_first")) { p.lane = first_lane(t); p.uniform = true; }
        else p.lane = sv_comp32(t, y, 0, X_ZEXT);
        if (quad) {
            // index inside the quad (CLPER subgroup4 reads the lane of the thread's own quad)
            if (p.lane.kind == VI_IMM) p.lane = vi_imm(p.lane.value & 3u);
            else {
                vi_ref q = sel_tmp(t);
                vi_instr *I = E(t, VA_AND_I32); I->dest = q; I->src[0] = p.lane; I->src[2] = vi_imm(3u);
                p.lane = q;
            }
        }
        return per_word(t, x, do_perm, &p);
    }
    if (sel_name_is(op, "sum")) return reduce(t, x, R_ADD, flt, sgn, quad);
    if (sel_name_is(op, "product")) return reduce(t, x, R_MUL, flt, sgn, quad);
    if (sel_name_is(op, "min")) return reduce(t, x, R_MIN, flt, sgn, quad);
    if (sel_name_is(op, "max")) return reduce(t, x, R_MAX, flt, sgn, quad);
    if (sel_name_is(op, "all") || sel_name_is(op, "any")) {
        USE(t, F4);
        vi_ref b = sv_comp32(t, x, 0, X_ZEXT);
        bool all = sel_name_is(op, "all");
        if (all) b = sel_alu2(t, VA_ISUB_S32, vi_imm(1), b);   // !b
        vi_ref m = ballot(t, b);
        if (quad) m = quad_bits(t, m);
        vi_ref r = sel_tmp(t);
        vi_instr *I = E(t, VA_ICMP_U32); I->dest = r; I->src[0] = m; I->src[1] = vi_imm(0);
        vi_set(I, VAF_cmpf, all ? VA_CMPF_M_EQ : VA_CMPF_M_NE); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
        return sv_from_comps32(t, 1, 1, &r);
    }
    if (sel_name_is(op, "is_first")) {
        USE(t, F4);
        vi_ref r = sel_tmp(t), lid = lane_id(t), fl = first_lane(t);
        vi_instr *I = E(t, VA_ICMP_U32); I->dest = r; I->src[0] = lid; I->src[1] = fl;
        vi_set(I, VAF_cmpf, VA_CMPF_M_EQ); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
        return sv_from_comps32(t, 1, 1, &r);
    }
    if (sel_name_is(op, "ballot")) {
        USE(t, F4);
        vi_ref m = ballot(t, sv_comp32(t, x, 0, X_ZEXT));
        if (quad) m = quad_bits(t, m);
        vi_ref w[2] = { m, vi_imm(0) };
        sv *v = sv_from_comps32(t, 32, 2, w);
        unsigned b = 64, n = 1; bool f;
        sel_type_info(ts_LLVMTypeOf(inst), &b, &n, &f);
        if (b == 64) { v->bits = 64; v->ncomp = 1; }
        return v;
    }
    SFAIL(t, "unsupported %s", name);
}

// ---- Derivatives (E12) ------------------------------------------------------------------------------------------------

static vi_ref derivative(S *t, vi_ref x, unsigned axis, bool coarse)
{
    vi_ref left, right;
    int g = VA_CLPER_SUBGROUP_SIZE_M_SUBGROUP4;
    if (coarse) {
        left = clper(t, x, vi_imm(0), VA_CLPER_LANE_OP_M_NONE, g, VA_CLPER_INACTIVE_RESULT_M_ZERO);
        right = clper(t, x, vi_imm(axis), VA_CLPER_LANE_OP_M_NONE, g, VA_CLPER_INACTIVE_RESULT_M_ZERO);
        return sel_alu2(t, VA_FADD_F32, right, sel_alu1(t, VA_FNEG_F32, left));
    }
    left = x.kind == VI_IMM ? sel_mov32(t, x) : x;
    right = clper(t, x, vi_imm(axis), VA_CLPER_LANE_OP_M_XOR, g, VA_CLPER_INACTIVE_RESULT_M_ZERO);
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_FADD_F32); I->dest = d; I->src[0] = right; I->src[1] = left; vi_set(I, VAF_neg1, 1);
    // flip the sign on the lanes where the neighbour is on the other side: bit (axis) of the lane id
    vi_ref lane = lane_id(t);
    if (axis == 2) { vi_ref m = sel_tmp(t); I = E(t, VA_AND_I32); I->dest = m; I->src[0] = lane; I->src[2] = vi_imm(2); lane = m; }
    vi_ref r = sel_tmp(t);
    I = E(t, VA_LSHIFT_XOR_I32); I->dest = r; I->src[0] = lane; I->src[1] = vi_imm(axis == 1 ? 31 : 30); I->src[2] = d;
    return r;
}

sv *sel_derivative(S *t, LLVMValueRef inst, const char *name)
{
    USE(t, E12);
    t->info.helpers = true;
    sv *x = arg(t, inst, 0);
    if (!x) return NULL;
    bool coarse = strstr(name, "coarse") != NULL;
    bool fw = strstr(name, "fwidth") != NULL;
    unsigned axis = strstr(name, "dfdy") ? 2 : 1;
    vi_ref r[16];
    for (unsigned c = 0; c < x->ncomp; c++) {
        vi_ref v = sv_comp32(t, x, c, X_F32);
        vi_ref d;
        if (fw) {
            vi_ref dx = derivative(t, v, 1, coarse), dy = derivative(t, v, 2, coarse);
            vi_ref e = sel_tmp(t);
            vi_instr *I = E(t, VA_FADD_F32); I->dest = e; I->src[0] = dx; I->src[1] = dy; vi_set(I, VAF_abs0, 1); vi_set(I, VAF_abs1, 1);
            d = e;
        } else d = derivative(t, v, axis, coarse);
        r[c] = d;
    }
    // every CLPER above needs the helper lanes of the quad
    vi_foreach_instr(t->b.block, I) if (I->op == VA_CLPER) I->helpers = true;
    if (x->bits == 16) {
        sv *v = sv_val(t, 16, x->ncomp);
        for (unsigned c = 0; c < x->ncomp; c += 2) {
            vi_instr *I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(v->vreg, c / 2, 1); I->src[0] = r[c]; I->src[1] = c + 1 < x->ncomp ? r[c + 1] : vi_imm(0);
        }
        return v;
    }
    return sv_from_comps32(t, 32, x->ncomp, r);
}
