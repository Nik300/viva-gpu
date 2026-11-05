// Viva ISA compiler: arithmetic, comparisons, casts, vectors and the math library (E1-E13, A11).
//
// 32-bit values map to one Valhall instruction per component. Half floats (E5) use the packed v2f16 instructions
// two lanes at a time where Valhall has them (add, mul, fma, min, max, neg, abs, compare/select via CSEL.v2f16,
// rounding); everything else is computed in f32 and packed back (V2F32_TO_V2F16). 8/16-bit integers are computed
// in 32 bits (zero/sign extended as the operation needs) and packed back. 64-bit integers use the .64 forms where
// Valhall has them (add, sub, mul, logic, shifts). Doubles are not supported (fallback).
#include "vi_sel.h"
#include <math.h>
#include <string.h>

static uint32_t fbits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

// Odd integer widths (iN with N not 1/8/16/32/64) are kept in 32-bit words whose high bits may hold garbage:
// operations whose result depends on them get the value zero/sign-extended from bit N first.
static unsigned llvm_int_width(LLVMTypeRef ty)
{
    if (ts_LLVMGetTypeKind(ty) == LLVMVectorTypeKind) ty = ts_LLVMGetElementType(ty);
    return ts_LLVMGetTypeKind(ty) == LLVMIntegerTypeKind ? ts_LLVMGetIntTypeWidth(ty) : 0;
}

static bool odd_width(unsigned w) { return w > 1 && w < 32 && w != 8 && w != 16; }

static vi_ref extend_odd(S *t, vi_ref x, unsigned w, bool sgn)
{
    vi_ref d = sel_tmp(t);
    if (!sgn) {
        vi_instr *I = E(t, VA_AND_I32); I->dest = d; I->src[0] = x; I->src[2] = vi_imm((1u << w) - 1);
        return d;
    }
    vi_ref l = sel_tmp(t);
    vi_instr *I = E(t, VA_LSHIFT_OR_I32); I->dest = l; I->src[0] = x; I->src[1] = vi_imm(32 - w); I->src[2] = vi_imm(0);
    I = E(t, VA_ARSHIFT_OR_I32); I->dest = d; I->src[0] = l; I->src[1] = vi_imm(32 - w); I->src[2] = vi_imm(0);
    return d;
}

static sv *normalize_odd(S *t, sv *v, unsigned w, bool sgn)
{
    if (!odd_width(w) || v->bits != 32) return v;
    vi_ref c[16];
    for (unsigned k = 0; k < v->ncomp; k++) c[k] = v->is_const ? vi_imm(sgn ? (uint32_t)(((int32_t)(v->cw[k] << (32 - w))) >> (32 - w)) : v->cw[k] & ((1u << w) - 1))
                                                           : extend_odd(t, sv_word(t, v, k), w, sgn);
    return sv_from_comps32(t, 32, v->ncomp, c);
}

// ---- Elementwise engine ---------------------------------------------------------------------------------------------

typedef vi_ref (*fn32)(S *t, int op, vi_ref *a, unsigned nargs);

// Result of `bits` x n from operands widened to 32 bits (how), one fn() per component. Scalar operands broadcast.
static sv *map32(S *t, unsigned rbits, bool rfloat, unsigned n, unsigned nargs, sv **args, int how, fn32 fn, int op)
{
    vi_ref r[16];
    for (unsigned c = 0; c < n; c++) {
        vi_ref a[4];
        for (unsigned k = 0; k < nargs; k++) {
            sv *x = args[k];
            unsigned cc = x->ncomp == 1 ? 0 : c;
            int h = how;
            if (x->bits == 16 && how == X_F32) h = X_F32;
            else if (how == X_F32) h = X_ZEXT;
            a[k] = sv_comp32(t, x, cc, h);
        }
        r[c] = fn(t, op, a, nargs);
        if (!r[c].kind) return NULL;
    }
    if (rbits == 16 && rfloat) {
        // f32 -> packed f16 pairs
        sv *res = sv_val(t, 16, n);
        for (unsigned c = 0; c < n; c += 2) {
            vi_instr *I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(res->vreg, c / 2, 1);
            I->src[0] = r[c];
            I->src[1] = c + 1 < n ? r[c + 1] : vi_imm(0);
        }
        return res;
    }
    return sv_from_comps32(t, rbits, n, r);
}

// ---- Float ----------------------------------------------------------------------------------------------------------

enum { OP_FADD, OP_FSUB, OP_FMUL, OP_FDIV, OP_FREM, OP_FNEG, OP_FMA, OP_FMIN, OP_FMAX, OP_FABS, OP_FSAT, OP_FLOOR,
       OP_CEIL, OP_TRUNC, OP_RINT, OP_ROUND, OP_FRACT, OP_SQRT, OP_RSQRT, OP_RCP, OP_EXP2, OP_LOG2, OP_SIN, OP_COS,
       OP_POW, OP_SIGN, OP_COPYSIGN, OP_LDEXP, OP_FMOD };

static vi_ref f1(S *t, enum va_op op, vi_ref a)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, op);
    I->dest = d; I->src[0] = a;
    return d;
}

static vi_ref fmul(S *t, vi_ref a, vi_ref b)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_FMUL_F32);
    I->dest = d; I->src[0] = a; I->src[1] = b;
    return d;
}

static vi_ref fadd(S *t, vi_ref a, vi_ref b, bool negb)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_FADD_F32);
    I->dest = d; I->src[0] = a; I->src[1] = b;
    if (negb) vi_set(I, VAF_neg1, 1);
    return d;
}

static vi_ref ffma(S *t, vi_ref a, vi_ref b, vi_ref c)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_FMA_F32);
    I->dest = d; I->src[0] = a; I->src[1] = b; I->src[2] = c;
    return d;
}

static vi_ref fround(S *t, vi_ref a, int mode)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_FROUND_F32);
    I->dest = d; I->src[0] = a; vi_set(I, VAF_round, mode);
    return d;
}

// exp2: FEXP on the 8.24 fixed-point input, with the float input for NaN propagation (Valhall's FEXP).
static vi_ref fexp2(S *t, vi_ref x, uint32_t log2_base)
{
    vi_ref scale = sel_tmp(t);
    vi_instr *I = E(t, VA_FMA_RSCALE_F32);
    I->dest = scale; I->src[0] = x; I->src[1] = vi_imm(log2_base); I->src[2] = vi_imm(0x80000000); I->src[3] = vi_imm(24);
    vi_set(I, VAF_special, VA_FMA_RSCALE_SPECIAL_32_M_NONE); vi_set(I, VAF_round, VA_FMA_RSCALE_ROUND_M_NONE);
    vi_ref fixed = sel_tmp(t);
    I = E(t, VA_F32_TO_S32);
    I->dest = fixed; I->src[0] = scale; vi_set(I, VAF_round, VA_ROUND_INTEGER_M_NONE);
    vi_ref d = sel_tmp(t);
    I = E(t, VA_FEXP_F32);
    I->dest = d; I->src[0] = fixed; I->src[1] = scale;
    return d;
}

// log2: FLOGD(x) * (x - 1, scaled) + exponent
static vi_ref flog2(S *t, vi_ref x)
{
    vi_ref e = sel_tmp(t);
    vi_instr *I = E(t, VA_FREXPE_F32);
    I->dest = e; I->src[0] = x; vi_set(I, VAF_special, VA_FREXP_SPECIAL_M_LOG);
    vi_ref ef = sel_tmp(t);
    I = E(t, VA_S32_TO_F32); I->dest = ef; I->src[0] = e;
    vi_ref add = sel_tmp(t);
    I = E(t, VA_FADD_LSCALE_F32); I->dest = add; I->src[0] = vi_imm(fbits(-1.0f)); I->src[1] = x;
    vi_ref ld = f1(t, VA_FLOGD_F32, x);
    return ffma(t, ld, add, ef);
}

// sin/cos: Valhall's coarse tables (bottom 6 bits * pi/32) plus a second order Taylor correction.
static vi_ref fsincos(S *t, vi_ref x, bool cos)
{
    vi_ref xu6 = ffma(t, x, vi_imm(fbits(2.0f / 3.14159f)), vi_imm(0x49400000));
    vi_ref e = ffma(t, fadd(t, xu6, vi_imm(0x49400000), true), vi_imm(fbits(-3.14159f / 2.0f)), x);
    vi_ref sinx = sel_tmp(t), cosx = sel_tmp(t);
    vi_instr *I = E(t, VA_FSIN_TABLE_U6); I->dest = sinx; I->src[0] = xu6; vi_set(I, VAF_offset, 0);
    I = E(t, VA_FCOS_TABLE_U6); I->dest = cosx; I->src[0] = xu6; vi_set(I, VAF_offset, 0);
    vi_ref e2 = sel_tmp(t);
    I = E(t, VA_FMA_RSCALE_F32);
    I->dest = e2; I->src[0] = e; I->src[1] = e; I->src[2] = vi_imm(0x80000000); I->src[3] = vi_imm(0xFFFFFFFF);
    vi_set(I, VAF_special, VA_FMA_RSCALE_SPECIAL_32_M_NONE); vi_set(I, VAF_round, VA_FMA_RSCALE_ROUND_M_NONE);
    vi_ref quad = sel_tmp(t);
    I = E(t, VA_FMA_F32); I->dest = quad; I->src[0] = e2; I->src[1] = cos ? cosx : sinx; I->src[2] = vi_imm(0x80000000);
    vi_set(I, VAF_neg0, 1);
    vi_ref lin = sel_tmp(t);
    I = E(t, VA_FMA_F32); I->dest = lin; I->src[0] = e; I->src[1] = cos ? sinx : cosx; I->src[2] = quad;
    if (cos) vi_set(I, VAF_neg1, 1);
    vi_set(I, VAF_clamp, VA_CLAMP_M_CLAMP_M1_1);
    return fadd(t, lin, cos ? cosx : sinx, false);
}

static vi_ref fop(S *t, int op, vi_ref *a, unsigned nargs)
{
    (void)nargs;
    vi_ref d;
    vi_instr *I;
    switch (op) {
    case OP_FADD: return fadd(t, a[0], a[1], false);
    case OP_FSUB: return fadd(t, a[0], a[1], true);
    case OP_FMUL: return fmul(t, a[0], a[1]);
    case OP_FDIV: return fmul(t, a[0], f1(t, VA_FRCP_F32, a[1]));
    case OP_FREM: case OP_FMOD: {
        // a - b * trunc(a / b)
        vi_ref q = fround(t, fmul(t, a[0], f1(t, VA_FRCP_F32, a[1])), VA_ROUND_INTEGER_M_ROUND_ZERO);
        d = sel_tmp(t);
        I = E(t, VA_FMA_F32); I->dest = d; I->src[0] = q; I->src[1] = a[1]; I->src[2] = a[0]; vi_set(I, VAF_neg0, 1);
        return d;
    }
    case OP_FNEG: return f1(t, VA_FNEG_F32, a[0]);
    case OP_FABS: return f1(t, VA_FABS_F32, a[0]);
    case OP_FMA: return ffma(t, a[0], a[1], a[2]);
    case OP_FMIN: case OP_FMAX:
        d = sel_tmp(t);
        I = E(t, op == OP_FMIN ? VA_FMIN_F32 : VA_FMAX_F32); I->dest = d; I->src[0] = a[0]; I->src[1] = a[1];
        vi_set(I, VAF_sem, VA_SEM_M_NAN_SUPPRESS);
        return d;
    case OP_FSAT:
        d = sel_tmp(t);
        I = E(t, VA_FADD_F32); I->dest = d; I->src[0] = a[0]; I->src[1] = vi_imm(0); vi_set(I, VAF_clamp, VA_CLAMP_M_CLAMP_0_1);
        return d;
    case OP_FLOOR: return fround(t, a[0], VA_ROUND_INTEGER_M_ROUND_DOWN);
    case OP_CEIL: return fround(t, a[0], VA_ROUND_INTEGER_M_ROUND_UP);
    case OP_TRUNC: return fround(t, a[0], VA_ROUND_INTEGER_M_ROUND_ZERO);
    case OP_RINT: return fround(t, a[0], VA_ROUND_INTEGER_M_NONE);
    case OP_ROUND: return fround(t, a[0], VA_ROUND_INTEGER_M_ROUND_NA);   // halfway away from zero
    case OP_FRACT: return fadd(t, a[0], fround(t, a[0], VA_ROUND_INTEGER_M_ROUND_DOWN), true);
    case OP_RSQRT: return f1(t, VA_FRSQ_F32, a[0]);
    case OP_RCP: return f1(t, VA_FRCP_F32, a[0]);
    case OP_SQRT: {
        // x * rsqrt(x), 0 for x = 0
        vi_ref m = fmul(t, a[0], f1(t, VA_FRSQ_F32, a[0]));
        return sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_F32, a[0], vi_imm(0), vi_imm(0), m);
    }
    case OP_EXP2: return fexp2(t, a[0], fbits(1.0f));
    case OP_LOG2: return flog2(t, a[0]);
    case OP_SIN: return fsincos(t, a[0], false);
    case OP_COS: return fsincos(t, a[0], true);
    case OP_POW: return fexp2(t, fmul(t, a[1], flog2(t, a[0])), fbits(1.0f));
    case OP_SIGN: {
        vi_ref p = sel_csel(t, VA_CMPF_M_GT, VA_CSEL_F32, a[0], vi_imm(0), vi_imm(fbits(1.0f)), vi_imm(0));
        return sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, a[0], vi_imm(0), vi_imm(fbits(-1.0f)), p);
    }
    case OP_COPYSIGN: {
        // (a & 0x7fffffff) | (b & 0x80000000)
        vi_ref m = sel_tmp(t);
        I = E(t, VA_AND_I32); I->dest = m; I->src[0] = a[0]; I->src[2] = vi_imm(0x7fffffff);
        vi_ref s = sel_tmp(t);
        I = E(t, VA_AND_I32); I->dest = s; I->src[0] = a[1]; I->src[2] = vi_imm(0x80000000);
        d = sel_tmp(t);
        I = E(t, VA_OR_I32); I->dest = d; I->src[0] = m; I->src[2] = s;
        return d;
    }
    case OP_LDEXP:
        d = sel_tmp(t);
        I = E(t, VA_LDEXP_F32); I->dest = d; I->src[0] = a[0]; I->src[1] = a[1];
        return d;
    default:
        return vi_none();
    }
}

// Native v2f16 for the operations Valhall has in packed form.
static sv *half_native(S *t, int op, unsigned n, unsigned nargs, sv **args)
{
    enum va_op vop;
    switch (op) {
    case OP_FADD: case OP_FSUB: vop = VA_FADD_V2F16; break;
    case OP_FMUL: vop = VA_FMUL_V2F16; break;
    case OP_FMA: vop = VA_FMA_V2F16; break;
    case OP_FMIN: vop = VA_FMIN_V2F16; break;
    case OP_FMAX: vop = VA_FMAX_V2F16; break;
    case OP_FNEG: vop = VA_FNEG_V2F16; break;
    case OP_FABS: vop = VA_FABS_V2F16; break;
    case OP_FSAT: vop = VA_FADD_V2F16; break;
    case OP_FLOOR: case OP_CEIL: case OP_TRUNC: case OP_RINT: vop = VA_FROUND_V2F16; break;
    default: return NULL;
    }
    for (unsigned k = 0; k < nargs; k++) if (args[k]->bits != 16) return NULL;
    sel_use(t, VMG_ISA_E5);
    sv *r = sv_val(t, 16, n);
    static const enum va_field swz[3] = { VAF_swz0, VAF_swz1, VAF_swz2 };
    for (unsigned w = 0; w < (n + 1) / 2; w++) {
        vi_instr *I = E(t, vop);
        I->dest = vi_vreg(r->vreg, w, 1);
        for (unsigned k = 0; k < nargs; k++) {
            sv *x = args[k];
            bool bcast = x->ncomp == 1;
            I->src[k] = sv_word(t, x, bcast ? 0 : w);
            if (va_has_field(vop, swz[k])) vi_set(I, swz[k], bcast ? VA_SWIZ_M_H00 : VA_SWIZ_M_H01);
        }
        if (op == OP_FSUB) vi_set(I, VAF_neg1, 1);
        if (op == OP_FSAT) { I->src[1] = vi_imm(0); vi_set(I, VAF_swz1, VA_SWIZ_M_H00); vi_set(I, VAF_clamp, VA_CLAMP_M_CLAMP_0_1); }
        if (op == OP_FMIN || op == OP_FMAX) vi_set(I, VAF_sem, VA_SEM_M_NAN_SUPPRESS);
        if (vop == VA_FROUND_V2F16)
            vi_set(I, VAF_round, op == OP_FLOOR ? VA_ROUND_INTEGER_M_ROUND_DOWN : op == OP_CEIL ? VA_ROUND_INTEGER_M_ROUND_UP :
                                 op == OP_TRUNC ? VA_ROUND_INTEGER_M_ROUND_ZERO : VA_ROUND_INTEGER_M_NONE);
    }
    return r;
}

static sv *float_op(S *t, int op, unsigned nargs, sv **args)
{
    unsigned bits = args[0]->bits, n = 1;
    for (unsigned k = 0; k < nargs; k++) if (args[k]->ncomp > n) n = args[k]->ncomp;
    if (bits == 64) SFAIL(t, "double precision arithmetic");
    if (bits == 16) {
        USE(t, E5);
        sv *r = half_native(t, op, n, nargs, args);
        if (r || t->error) return r;
    }
    return map32(t, bits, true, n, nargs, args, X_F32, fop, op);
}

// ---- Integer --------------------------------------------------------------------------------------------------------

enum { OP_ADD, OP_SUB, OP_MUL, OP_UDIV, OP_SDIV, OP_UREM, OP_SREM, OP_SHL, OP_LSHR, OP_ASHR, OP_AND, OP_OR, OP_XOR,
       OP_UMIN, OP_UMAX, OP_SMIN, OP_SMAX, OP_IABS, OP_CLZ, OP_CTZ, OP_POPCNT, OP_BITREV, OP_UMULHI, OP_SMULHI,
       OP_UADDSAT, OP_SADDSAT, OP_USUBSAT, OP_SSUBSAT, OP_UHADD, OP_SHADD, OP_URHADD, OP_SRHADD, OP_UABSDIFF,
       OP_SABSDIFF, OP_ROTL, OP_ROTR, OP_EXTRACT_U, OP_EXTRACT_S, OP_INSERT, OP_NOT };

static vi_ref logic(S *t, enum va_op op, vi_ref a, vi_ref b)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, op);
    I->dest = d; I->src[0] = a; I->src[2] = b;
    return d;
}

static vi_ref shift(S *t, enum va_op op, vi_ref a, vi_ref amount)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, op);
    I->dest = d; I->src[0] = a; I->src[1] = amount; I->src[2] = vi_imm(0);
    return d;
}

static vi_ref icmp32(S *t, enum va_op op, int cmpf, vi_ref a, vi_ref b)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, op);
    I->dest = d; I->src[0] = a; I->src[1] = b;
    vi_set(I, VAF_cmpf, cmpf); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
    return d;
}

// 32 x 32 -> 64-bit product (IMUL.u64/s64: the multiplier takes 32-bit operands, the low word of each 64-bit source
// with widen w0, the only full-word widen the hardware accepts; it writes the whole 64-bit product).
static vi_ref mul_wide(S *t, vi_ref a, vi_ref b, bool sgn)
{
    uint32_t pa = vi_new_vreg(t->s, 2), pb = vi_new_vreg(t->s, 2), pr = vi_new_vreg(t->s, 2);
    vi_ref parts[4] = { a, vi_imm(0), b, vi_imm(0) };
    uint32_t regs[2] = { pa, pb };
    for (unsigned k = 0; k < 4; k++) {
        vi_instr *I = parts[k].kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
        if (parts[k].kind == VI_IMM) vi_set(I, VAF_imm1w, parts[k].value); else I->src[0] = parts[k];
        I->dest = vi_vreg(regs[k / 2], k % 2, 1);
    }
    vi_instr *I = E(t, sgn ? VA_IMUL_S64 : VA_IMUL_U64);
    I->dest = vi_vreg(pr, 0, 2); I->src[0] = vi_vreg(pa, 0, 2); I->src[1] = vi_vreg(pb, 0, 2);
    vi_set(I, VAF_widen0, VA_WIDEN_INT_M_W0); vi_set(I, VAF_widen1, VA_WIDEN_INT_M_W0);
    return vi_vreg(pr, 0, 2);
}

// 64-bit product of two 32-bit values (unsigned or signed), high word.
static vi_ref mulhi(S *t, vi_ref a, vi_ref b, bool sgn)
{
    vi_ref p = mul_wide(t, a, b, sgn);
    return sel_mov32(t, vi_vreg(p.value, 1, 1));
}

static vi_ref udiv(S *t, vi_ref n, vi_ref d, bool mod)
{
    vi_ref df = f1(t, VA_U32_TO_F32, d);
    vi_ref rcp = fmul(t, f1(t, VA_FRCP_F32, df), vi_imm(fbits(4294966784.0f)));
    vi_ref rcpi = sel_tmp(t);
    vi_instr *I = E(t, VA_F32_TO_U32); I->dest = rcpi; I->src[0] = rcp; vi_set(I, VAF_round, VA_ROUND_INTEGER_M_ROUND_ZERO);
    vi_ref negd = sel_alu2(t, VA_ISUB_S32, vi_imm(0), d);
    vi_ref nrd = sel_alu2(t, VA_IMUL_U32, rcpi, negd);
    rcpi = sel_alu2(t, VA_IADD_U32, rcpi, mulhi(t, rcpi, nrd, false));
    vi_ref q = mulhi(t, n, rcpi, false);
    vi_ref r = sel_alu2(t, VA_ISUB_S32, n, sel_alu2(t, VA_IMUL_U32, q, d));
    for (unsigned step = 0; step < 2; step++) {
        vi_ref ge = icmp32(t, VA_ICMP_U32, VA_CMPF_M_GE, r, d);
        if (!mod) q = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, ge, vi_imm(0), sel_iadd_imm(t, q, 1), q);
        r = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, ge, vi_imm(0), sel_alu2(t, VA_ISUB_S32, r, d), r);
    }
    return mod ? r : q;
}

static vi_ref iabs(S *t, vi_ref a) { return sel_alu1(t, VA_IABS_S32, a); }
static vi_ref ineg(S *t, vi_ref a) { return sel_alu2(t, VA_ISUB_S32, vi_imm(0), a); }

static vi_ref iop(S *t, int op, vi_ref *a, unsigned nargs)
{
    (void)nargs;
    vi_instr *I;
    vi_ref d;
    switch (op) {
    case OP_ADD: return sel_alu2(t, VA_IADD_U32, a[0], a[1]);
    case OP_SUB: return sel_alu2(t, VA_ISUB_S32, a[0], a[1]);
    case OP_MUL: return sel_alu2(t, VA_IMUL_U32, a[0], a[1]);
    case OP_UDIV: return udiv(t, a[0], a[1], false);
    case OP_UREM: return udiv(t, a[0], a[1], true);
    case OP_SDIV: {
        vi_ref q = udiv(t, iabs(t, a[0]), iabs(t, a[1]), false);
        vi_ref sx = logic(t, VA_XOR_I32, a[0], a[1]);
        return sel_csel(t, VA_CMPF_M_LT, VA_CSEL_S32, sx, vi_imm(0), ineg(t, q), q);
    }
    case OP_SREM: {
        vi_ref r = udiv(t, iabs(t, a[0]), iabs(t, a[1]), true);
        return sel_csel(t, VA_CMPF_M_LT, VA_CSEL_S32, a[0], vi_imm(0), ineg(t, r), r);
    }
    case OP_SHL: return shift(t, VA_LSHIFT_OR_I32, a[0], a[1]);
    case OP_LSHR: return shift(t, VA_RSHIFT_OR_I32, a[0], a[1]);
    case OP_ASHR: return shift(t, VA_ARSHIFT_OR_I32, a[0], a[1]);
    case OP_AND: return logic(t, VA_AND_I32, a[0], a[1]);
    case OP_OR: return logic(t, VA_OR_I32, a[0], a[1]);
    case OP_XOR: return logic(t, VA_XOR_I32, a[0], a[1]);
    case OP_NOT: return sel_alu1(t, VA_NOT_I32, a[0]);
    case OP_UMIN: return sel_csel(t, VA_CMPF_M_LT, VA_CSEL_U32, a[0], a[1], a[0], a[1]);
    case OP_UMAX: return sel_csel(t, VA_CMPF_M_GT, VA_CSEL_U32, a[0], a[1], a[0], a[1]);
    case OP_SMIN: return sel_csel(t, VA_CMPF_M_LT, VA_CSEL_S32, a[0], a[1], a[0], a[1]);
    case OP_SMAX: return sel_csel(t, VA_CMPF_M_GT, VA_CSEL_S32, a[0], a[1], a[0], a[1]);
    case OP_IABS: return iabs(t, a[0]);
    case OP_CLZ:
        d = sel_tmp(t); I = E(t, VA_CLZ_U32); I->dest = d; I->src[0] = a[0]; vi_set(I, VAF_mask, 0);
        return d;
    case OP_CTZ: {
        // clz(bitreverse(x)), 32 for 0 (CLZ of 0 is 32)
        vi_ref r = sel_alu1(t, VA_BITREV_I32, a[0]);
        d = sel_tmp(t); I = E(t, VA_CLZ_U32); I->dest = d; I->src[0] = r; vi_set(I, VAF_mask, 0);
        return d;
    }
    case OP_POPCNT: return sel_alu1(t, VA_POPCOUNT_I32, a[0]);
    case OP_BITREV: return sel_alu1(t, VA_BITREV_I32, a[0]);
    case OP_UMULHI: return mulhi(t, a[0], a[1], false);
    case OP_SMULHI: return mulhi(t, a[0], a[1], true);
    case OP_UADDSAT: case OP_SADDSAT: case OP_USUBSAT: case OP_SSUBSAT:
        d = sel_tmp(t);
        I = E(t, op == OP_UADDSAT ? VA_IADD_U32 : op == OP_SADDSAT ? VA_IADD_S32 : op == OP_USUBSAT ? VA_ISUB_U32 : VA_ISUB_S32);
        I->dest = d; I->src[0] = a[0]; I->src[1] = a[1]; vi_set(I, VAF_saturate, VA_SATURATE_M_SAT);
        return d;
    case OP_UHADD: case OP_SHADD: case OP_URHADD: case OP_SRHADD:
        d = sel_tmp(t);
        I = E(t, op == OP_UHADD || op == OP_URHADD ? VA_HADD_U32 : VA_HADD_S32);
        I->dest = d; I->src[0] = a[0]; I->src[1] = a[1];
        vi_set(I, VAF_round, op == OP_URHADD || op == OP_SRHADD ? 1 : 0);
        return d;
    case OP_UABSDIFF: case OP_SABSDIFF: {
        enum va_op cs = op == OP_UABSDIFF ? VA_CSEL_U32 : VA_CSEL_S32;
        vi_ref ab = sel_alu2(t, VA_ISUB_S32, a[0], a[1]), ba = sel_alu2(t, VA_ISUB_S32, a[1], a[0]);
        return sel_csel(t, VA_CMPF_M_GT, cs, a[0], a[1], ab, ba);
    }
    case OP_ROTL: case OP_ROTR: {
        vi_ref amt = logic(t, VA_AND_I32, a[1], vi_imm(31));
        vi_ref inv = sel_alu2(t, VA_ISUB_S32, vi_imm(32), amt);
        vi_ref x = shift(t, op == OP_ROTL ? VA_LSHIFT_OR_I32 : VA_RSHIFT_OR_I32, a[0], amt);
        vi_ref y = shift(t, op == OP_ROTL ? VA_RSHIFT_OR_I32 : VA_LSHIFT_OR_I32, a[0], inv);
        vi_ref r = logic(t, VA_OR_I32, x, y);
        return sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_U32, amt, vi_imm(0), a[0], r);
    }
    case OP_EXTRACT_U: case OP_EXTRACT_S: {
        // (x << (32 - off - bits)) >> (32 - bits), 0 when bits = 0
        vi_ref l = sel_alu2(t, VA_ISUB_S32, sel_alu2(t, VA_ISUB_S32, vi_imm(32), a[1]), a[2]);
        vi_ref r = sel_alu2(t, VA_ISUB_S32, vi_imm(32), a[2]);
        vi_ref x = shift(t, op == OP_EXTRACT_U ? VA_RSHIFT_OR_I32 : VA_ARSHIFT_OR_I32, shift(t, VA_LSHIFT_OR_I32, a[0], l), r);
        return sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_U32, a[2], vi_imm(0), vi_imm(0), x);
    }
    case OP_INSERT: {
        // mask = ((1 << bits) - 1) << off ; (base & ~mask) | ((insert << off) & mask)
        vi_ref ones = sel_iadd_imm(t, shift(t, VA_LSHIFT_OR_I32, vi_imm(1), a[3]), -1);
        ones = sel_csel(t, VA_CMPF_M_GE, VA_CSEL_U32, a[3], vi_imm(32), vi_imm(0xffffffff), ones);
        vi_ref mask = shift(t, VA_LSHIFT_OR_I32, ones, a[2]);
        vi_ref ins = logic(t, VA_AND_I32, shift(t, VA_LSHIFT_OR_I32, a[1], a[2]), mask);
        d = sel_tmp(t);
        I = E(t, VA_AND_I32); I->dest = d; I->src[0] = a[0]; I->src[2] = mask; vi_set(I, VAF_not2, 1);
        return logic(t, VA_OR_I32, d, ins);
    }
    default: return vi_none();
    }
}

static bool op_signed(int op) { return op == OP_SDIV || op == OP_SREM || op == OP_ASHR || op == OP_SMIN || op == OP_SMAX ||
                                       op == OP_IABS || op == OP_SMULHI || op == OP_SADDSAT || op == OP_SSUBSAT ||
                                       op == OP_SHADD || op == OP_SRHADD || op == OP_SABSDIFF || op == OP_EXTRACT_S; }

static sv *int64_op(S *t, int op, sv **args)
{
    enum va_op o;
    switch (op) {
    case OP_ADD: o = VA_IADD_U64; break;
    case OP_SUB: o = VA_ISUB_U64; break;
    case OP_MUL: {
        // lo(a) * lo(b) as a 64-bit product, plus the cross terms in the high word
        sel_use(t, VMG_ISA_E9);
        unsigned n = args[0]->ncomp;
        sv *r = sv_val(t, 64, n);
        sv *a = sv_materialize(t, args[0]), *b = sv_materialize(t, args[1]);
        for (unsigned c = 0; c < n; c++) {
            vi_ref al = vi_vreg(a->vreg, 2 * c, 1), ah = vi_vreg(a->vreg, 2 * c + 1, 1);
            vi_ref bl = vi_vreg(b->vreg, 2 * c, 1), bh = vi_vreg(b->vreg, 2 * c + 1, 1);
            vi_ref p = mul_wide(t, al, bl, false);
            vi_ref cross = sel_alu2(t, VA_IADD_U32, sel_alu2(t, VA_IMUL_U32, al, bh), sel_alu2(t, VA_IMUL_U32, ah, bl));
            vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(r->vreg, 2 * c, 1); I->src[0] = vi_vreg(p.value, 0, 1);
            vi_ref hi = sel_alu2(t, VA_IADD_U32, vi_vreg(p.value, 1, 1), cross);
            I = E(t, VA_MOV_I32); I->dest = vi_vreg(r->vreg, 2 * c + 1, 1); I->src[0] = hi;
        }
        return r;
    }
    case OP_AND: o = VA_AND_I64; break;
    case OP_OR: o = VA_OR_I64; break;
    case OP_XOR: o = VA_XOR_I64; break;
    case OP_SHL: o = VA_LSHIFT_OR_I64; break;
    case OP_LSHR: o = VA_RSHIFT_OR_I64; break;
    case OP_ASHR: o = VA_ARSHIFT_OR_I64; break;
    default: SFAIL(t, "64-bit integer operation %d", op);
    }
    sel_use(t, VMG_ISA_E9);
    unsigned n = args[0]->ncomp;
    sv *r = sv_val(t, 64, n);
    sv *a = sv_materialize(t, args[0]), *b = sv_materialize(t, args[1]);
    for (unsigned c = 0; c < n; c++) {
        vi_instr *I = E(t, o);
        I->dest = vi_vreg(r->vreg, 2 * c, 2);
        if (va_has_field(o, VAF_widen0)) vi_set(I, VAF_widen0, 0);
        if (va_has_field(o, VAF_widen1)) vi_set(I, VAF_widen1, 0);
        I->src[0] = vi_vreg(a->vreg, 2 * c, 2);
        if (o == VA_LSHIFT_OR_I64 || o == VA_RSHIFT_OR_I64 || o == VA_ARSHIFT_OR_I64) {
            I->src[1] = vi_vreg(b->vreg, 2 * c, 2);   // amount: low word of the pair
            I->src[2] = vi_imm(0);
        } else if (o == VA_AND_I64 || o == VA_OR_I64 || o == VA_XOR_I64) {
            I->src[2] = vi_vreg(b->vreg, 2 * c, 2);
        } else I->src[1] = vi_vreg(b->vreg, 2 * c, 2);
    }
    return r;
}

static sv *int_op(S *t, int op, unsigned nargs, sv **args)
{
    unsigned bits = args[0]->bits, n = 1;
    for (unsigned k = 0; k < nargs; k++) if (args[k]->ncomp > n) n = args[k]->ncomp;
    if (bits == 64) return int64_op(t, op, args);
    if (bits == 1 && (op == OP_AND || op == OP_OR || op == OP_XOR)) {
        // booleans 0/1: bitwise ops keep 0/1
        return map32(t, 1, false, n, nargs, args, X_ZEXT, iop, op);
    }
    if (bits == 1) SFAIL(t, "arithmetic on booleans");
    return map32(t, bits, false, n, nargs, args, op_signed(op) ? X_SEXT : X_ZEXT, iop, op);
}

sv *sel_alu_instr(S *t, LLVMValueRef inst, LLVMOpcode op)
{
    USE(t, E1);
    sv *a[3];
    unsigned nargs = op == LLVMFNeg ? 1 : 2;
    for (unsigned k = 0; k < nargs; k++) if (!(a[k] = sel_ssa(t, ts_LLVMGetOperand(inst, k)))) return NULL;
    unsigned iw = llvm_int_width(ts_LLVMTypeOf(inst));
    if (odd_width(iw)) {
        bool sgn = op == LLVMSDiv || op == LLVMSRem || op == LLVMAShr;
        if (op == LLVMUDiv || op == LLVMURem || op == LLVMLShr || sgn) a[0] = normalize_odd(t, a[0], iw, sgn);
        if (op == LLVMUDiv || op == LLVMURem || op == LLVMSDiv || op == LLVMSRem) a[1] = normalize_odd(t, a[1], iw, sgn);
    }
    switch (op) {
    case LLVMFAdd: return float_op(t, OP_FADD, 2, a);
    case LLVMFSub: return float_op(t, OP_FSUB, 2, a);
    case LLVMFMul: return float_op(t, OP_FMUL, 2, a);
    case LLVMFDiv: return float_op(t, OP_FDIV, 2, a);
    case LLVMFRem: return float_op(t, OP_FREM, 2, a);
    case LLVMFNeg: return float_op(t, OP_FNEG, 1, a);
    case LLVMAdd: return int_op(t, OP_ADD, 2, a);
    case LLVMSub: return int_op(t, OP_SUB, 2, a);
    case LLVMMul: return int_op(t, OP_MUL, 2, a);
    case LLVMUDiv: return int_op(t, OP_UDIV, 2, a);
    case LLVMSDiv: return int_op(t, OP_SDIV, 2, a);
    case LLVMURem: return int_op(t, OP_UREM, 2, a);
    case LLVMSRem: return int_op(t, OP_SREM, 2, a);
    case LLVMShl: return int_op(t, OP_SHL, 2, a);
    case LLVMLShr: return int_op(t, OP_LSHR, 2, a);
    case LLVMAShr: return int_op(t, OP_ASHR, 2, a);
    case LLVMAnd: return int_op(t, OP_AND, 2, a);
    case LLVMOr: return int_op(t, OP_OR, 2, a);
    case LLVMXor: return int_op(t, OP_XOR, 2, a);
    default: SFAIL(t, "unsupported binary operator %d", op);
    }
}

// ---- Comparisons and select (E2) ------------------------------------------------------------------------------------

static int fcmpf(LLVMRealPredicate p, bool *never, bool *always)
{
    *never = *always = false;
    switch (p) {
    case LLVMRealOEQ: case LLVMRealUEQ: return VA_CMPF_M_EQ;
    case LLVMRealOGT: case LLVMRealUGT: return VA_CMPF_M_GT;
    case LLVMRealOGE: case LLVMRealUGE: return VA_CMPF_M_GE;
    case LLVMRealOLT: case LLVMRealULT: return VA_CMPF_M_LT;
    case LLVMRealOLE: case LLVMRealULE: return VA_CMPF_M_LE;
    case LLVMRealONE: case LLVMRealUNE: return VA_CMPF_M_NE;
    case LLVMRealORD: return -2;   // x == x
    case LLVMRealUNO: return -3;   // x != x
    case LLVMRealPredicateFalse: *never = true; return 0;
    default: *always = true; return 0;
    }
}

vi_ref sel_texture_is_null(S *t, int index);   // vi_sel_tex.c

sv *sel_compare(S *t, LLVMValueRef inst, bool flt)
{
    USE(t, E2);
    if (!flt) {
        // resources: is_null_texture (texture vs null), pointer comparisons (same memory: the offsets)
        sv *pa = sel_value(t, ts_LLVMGetOperand(inst, 0)), *pb = sel_value(t, ts_LLVMGetOperand(inst, 1));
        if (!pa || !pb) return NULL;
        LLVMIntPredicate p = ts_LLVMGetICmpPredicate(inst);
        if (pa->kind == SV_TEX || pb->kind == SV_TEX) {
            sv *tex = pa->kind == SV_TEX ? pa : pb;
            vi_ref isnull = sel_texture_is_null(t, tex->index);
            vi_ref r = isnull;
            if (p == LLVMIntNE) r = sel_alu2(t, VA_ISUB_S32, vi_imm(1), isnull);
            return sv_from_comps32(t, 1, 1, &r);
        }
        if (pa->kind == SV_PTR && pb->kind == SV_PTR) {
            vi_ref x = sv_word(t, pa->off, 0), y = sv_word(t, pb->off, 0);
            if (x.kind == VI_IMM) x = sel_mov32(t, x);
            int cf = p == LLVMIntEQ ? VA_CMPF_M_EQ : p == LLVMIntNE ? VA_CMPF_M_NE : (p == LLVMIntUGT || p == LLVMIntSGT) ? VA_CMPF_M_GT :
                     (p == LLVMIntUGE || p == LLVMIntSGE) ? VA_CMPF_M_GE : (p == LLVMIntULT || p == LLVMIntSLT) ? VA_CMPF_M_LT : VA_CMPF_M_LE;
            vi_ref r = sel_tmp(t);
            vi_instr *I = E(t, VA_ICMP_U32); I->dest = r; I->src[0] = x; I->src[1] = y;
            vi_set(I, VAF_cmpf, cf); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
            return sv_from_comps32(t, 1, 1, &r);
        }
    }
    sv *a = sel_ssa(t, ts_LLVMGetOperand(inst, 0)), *b = sel_ssa(t, ts_LLVMGetOperand(inst, 1));
    if (!a || !b) return NULL;
    unsigned n = a->ncomp;
    vi_ref r[16];
    if (flt) {
        bool never, always;
        int cmpf = fcmpf(ts_LLVMGetFCmpPredicate(inst), &never, &always);
        if (a->bits == 64) SFAIL(t, "double comparison");
        for (unsigned c = 0; c < n; c++) {
            if (never || always) { r[c] = vi_imm(always); continue; }
            vi_ref x = sv_comp32(t, a, c, X_F32), y = sv_comp32(t, b, b->ncomp == 1 ? 0 : c, X_F32);
            int cf = cmpf;
            if (cmpf == -2) { cf = VA_CMPF_M_EQ; y = x; }
            if (cmpf == -3) { cf = VA_CMPF_M_NE; y = x; }
            vi_ref d = sel_tmp(t);
            vi_instr *I = E(t, VA_FCMP_F32);
            I->dest = d; I->src[0] = x; I->src[1] = y;
            vi_set(I, VAF_cmpf, cf); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
            r[c] = d;
        }
        return sv_from_comps32(t, 1, n, r);
    }
    LLVMIntPredicate p = ts_LLVMGetICmpPredicate(inst);
    bool sgn = p == LLVMIntSGT || p == LLVMIntSGE || p == LLVMIntSLT || p == LLVMIntSLE;
    unsigned cw = llvm_int_width(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0)));
    if (odd_width(cw)) { a = normalize_odd(t, a, cw, sgn); b = normalize_odd(t, b, cw, sgn); }
    int cf = p == LLVMIntEQ ? VA_CMPF_M_EQ : p == LLVMIntNE ? VA_CMPF_M_NE : (p == LLVMIntUGT || p == LLVMIntSGT) ? VA_CMPF_M_GT :
             (p == LLVMIntUGE || p == LLVMIntSGE) ? VA_CMPF_M_GE : (p == LLVMIntULT || p == LLVMIntSLT) ? VA_CMPF_M_LT : VA_CMPF_M_LE;
    for (unsigned c = 0; c < n; c++) {
        if (a->bits == 64) {
            // hi compare, lo compare unsigned when hi equal
            sv *am = sv_materialize(t, a), *bm = sv_materialize(t, b);
            vi_ref ah = vi_vreg(am->vreg, 2 * c + 1, 1), bh = vi_vreg(bm->vreg, 2 * c + 1, 1);
            vi_ref al = vi_vreg(am->vreg, 2 * c, 1), bl = vi_vreg(bm->vreg, 2 * c, 1);
            if (cf == VA_CMPF_M_EQ || cf == VA_CMPF_M_NE) {
                vi_ref x = logic(t, VA_OR_I32, logic(t, VA_XOR_I32, ah, bh), logic(t, VA_XOR_I32, al, bl));
                r[c] = icmp32(t, VA_ICMP_U32, cf, x, vi_imm(0));
            } else {
                vi_ref hi = icmp32(t, sgn ? VA_ICMP_S32 : VA_ICMP_U32, cf, ah, bh);
                vi_ref lo = icmp32(t, VA_ICMP_U32, cf, al, bl);
                vi_ref heq = icmp32(t, VA_ICMP_U32, VA_CMPF_M_EQ, ah, bh);
                r[c] = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, heq, vi_imm(0), lo, hi);
            }
            continue;
        }
        vi_ref x = sv_comp32(t, a, c, sgn ? X_SEXT : X_ZEXT), y = sv_comp32(t, b, b->ncomp == 1 ? 0 : c, sgn ? X_SEXT : X_ZEXT);
        r[c] = icmp32(t, sgn ? VA_ICMP_S32 : VA_ICMP_U32, cf, x, y);
    }
    return sv_from_comps32(t, 1, n, r);
}

sv *sel_select(S *t, LLVMValueRef inst)
{
    USE(t, E2);
    sv *c = sel_value(t, ts_LLVMGetOperand(inst, 0)), *x = sel_value(t, ts_LLVMGetOperand(inst, 1)), *y = sel_value(t, ts_LLVMGetOperand(inst, 2));
    if (!c || !x || !y) return NULL;
    if (c->kind != SV_VAL) SFAIL(t, "select condition");
    if (x->kind == SV_PTR || y->kind == SV_PTR) {
        // pointers into the same memory: select the offsets
        if (x->kind != SV_PTR || y->kind != SV_PTR || x->space != y->space) SFAIL(t, "select between different memories");
        if (x->slot != y->slot && x->space != SP_SSBO) SFAIL(t, "select between different memories");
        sv *p = sv_new(t, SV_PTR);
        p->space = x->space; p->slot = x->slot;
        if (x->slot != y->slot || x->slot < 0) {
            // buffers chosen at run time: select the resource handles too (C1)
            p->slot = -2;
            p->slot_mask = (x->slot >= 0 ? 1u << x->slot : x->slot_mask) | (y->slot >= 0 ? 1u << y->slot : y->slot_mask);
            p->dyn_handle = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, sv_word(t, c, 0), vi_imm(0), sel_ssbo_handle(t, x), sel_ssbo_handle(t, y));
        }
        vi_ref o = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, sv_word(t, c, 0), vi_imm(0), sv_word(t, x->off, 0), sv_word(t, y->off, 0));
        p->off = sv_from_comps32(t, 32, 1, &o);
        return p;
    }
    if (x->kind != SV_VAL || y->kind != SV_VAL) SFAIL(t, "select of aggregates");
    unsigned words = sv_words(x->bits, x->ncomp);
    if (c->ncomp == 1 || x->bits == 32 || x->bits == 1) {
        vi_ref w[16];
        bool vec_cond = c->ncomp > 1;
        if (vec_cond && (x->bits == 16 || x->bits == 8 || x->bits == 64)) goto per_comp;
        for (unsigned k = 0; k < words; k++)
            w[k] = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, sv_word(t, c, vec_cond ? k : 0), vi_imm(0), sv_word(t, x, k), sv_word(t, y, k));
        sv *r = sv_val(t, x->bits, x->ncomp);
        for (unsigned k = 0; k < words; k++) { vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(r->vreg, k, 1); I->src[0] = w[k]; }
        return r;
    }
per_comp:;
    vi_ref r[16];
    for (unsigned k = 0; k < x->ncomp; k++)
        r[k] = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, sv_word(t, c, k), vi_imm(0), sv_comp32(t, x, k, X_ZEXT), sv_comp32(t, y, k, X_ZEXT));
    return sv_from_comps32(t, x->bits, x->ncomp, r);
}

// ---- Casts (E3) -----------------------------------------------------------------------------------------------------

static sv *retype(S *t, sv *v, unsigned bits, unsigned n)
{
    sv *r = sv_new(t, SV_VAL);
    *r = *v;
    r->bits = (uint8_t)bits; r->ncomp = (uint8_t)n;
    (void)t;
    return r;
}

sv *sel_cast(S *t, LLVMValueRef inst, LLVMOpcode op)
{
    USE(t, E3);
    LLVMValueRef src = ts_LLVMGetOperand(inst, 0);
    LLVMTypeRef dty = ts_LLVMTypeOf(inst);
    sv *x = sel_value(t, src);
    if (!x) return NULL;
    if (op == LLVMAddrSpaceCast || (op == LLVMBitCast && ts_LLVMGetTypeKind(dty) == LLVMPointerTypeKind)) return x;
    if (op == LLVMPtrToInt) {
        if (x->kind != SV_PTR) SFAIL(t, "ptrtoint of a non-pointer");
        if (x->space == SP_GLOBAL) {
            // address + offset, 64-bit
            vi_ref o = sv_word(t, x->off, 0);
            if (o.kind == VI_IMM) o = sel_mov32(t, o);
            vi_ref hi = sel_tmp(t);
            vi_instr *H = E(t, VA_ARSHIFT_OR_I32); H->dest = hi; H->src[0] = o; H->src[1] = vi_imm(31); H->src[2] = vi_imm(0);
            vi_ref pair = sel_pair(t, o, hi);
            sv *r = sv_val(t, 64, 1);
            vi_instr *I = E(t, VA_IADD_U64);
            I->dest = vi_vreg(r->vreg, 0, 2); I->src[0] = x->addr; I->src[1] = pair;
            vi_set(I, VAF_widen0, 0); vi_set(I, VAF_widen1, 0);
            return r;
        }
        unsigned b, n; bool f;
        sel_type_info(dty, &b, &n, &f);
        if (b == 64) { uint32_t z[2] = {0, 0}; sv *hi = sv_const(t, 32, 1, z); vi_ref w[2] = { sv_word(t, x->off, 0), sv_word(t, hi, 0) };
                       sv *r = sv_from_comps32(t, 32, 2, w); return retype(t, r, 64, 1); }
        return x->off;
    }
    if (op == LLVMIntToPtr) SFAIL(t, "inttoptr (pointer of unknown memory)");
    if (x->kind != SV_VAL) SFAIL(t, "cast of a non-value");
    unsigned db, dn; bool dflt;
    if (!sel_type_info(dty, &db, &dn, &dflt)) {
        char *txt = ts_LLVMPrintValueToString(inst);
        if (!t->error) t->error = vmg_strdup_printf("cast to an unsupported type: %.100s", txt ? txt : "?");
        ts_LLVMDisposeMessage(txt);
        return NULL;
    }
    unsigned n = x->ncomp;
    vi_ref r[16];
    switch (op) {
    case LLVMBitCast:
        if (x->bits == 1 || db == 1) SFAIL(t, "bitcast of booleans");
        if (x->bits * x->ncomp != db * dn) SFAIL(t, "bitcast changes size");
        return retype(t, x, db, dn);   // same register image
    case LLVMTrunc:
        if (db == 1) {
            for (unsigned c = 0; c < n; c++) r[c] = logic(t, VA_AND_I32, sv_comp32(t, x, c, X_ZEXT), vi_imm(1));
            return sv_from_comps32(t, 1, n, r);
        }
        if (x->bits == 64) { for (unsigned c = 0; c < n; c++) r[c] = sv_word(t, x, 2 * c); return sv_from_comps32(t, db, n, r); }
        for (unsigned c = 0; c < n; c++) r[c] = sv_comp32(t, x, c, X_ZEXT);
        return sv_from_comps32(t, db, n, r);
    case LLVMZExt: case LLVMSExt: {
        bool s = op == LLVMSExt;
        unsigned sw = llvm_int_width(ts_LLVMTypeOf(src));
        if (odd_width(sw)) x = normalize_odd(t, x, sw, s);
        for (unsigned c = 0; c < n; c++) {
            vi_ref v = sv_comp32(t, x, c, s ? X_SEXT : X_ZEXT);
            if (x->bits == 1 && s) v = ineg(t, v);
            r[c] = v;
        }
        if (db == 64) {
            vi_ref w[32];
            for (unsigned c = 0; c < n; c++) { w[2 * c] = r[c]; w[2 * c + 1] = s ? shift(t, VA_ARSHIFT_OR_I32, r[c], vi_imm(31)) : vi_imm(0); }
            sv *v = sv_from_comps32(t, 32, 2 * n, w);
            return retype(t, v, 64, n);
        }
        return sv_from_comps32(t, db, n, r);
    }
    case LLVMFPToUI: case LLVMFPToSI: {
        USE(t, E10);
        for (unsigned c = 0; c < n; c++) {
            vi_ref f = sv_comp32(t, x, c, X_F32);
            vi_ref d = sel_tmp(t);
            vi_instr *I = E(t, op == LLVMFPToUI ? VA_F32_TO_U32 : VA_F32_TO_S32);
            I->dest = d; I->src[0] = f; vi_set(I, VAF_round, VA_ROUND_INTEGER_M_ROUND_ZERO);
            r[c] = d;
        }
        if (db == 64) SFAIL(t, "float to 64-bit integer");
        return sv_from_comps32(t, db, n, r);
    }
    case LLVMUIToFP: case LLVMSIToFP: {
        USE(t, E10);
        bool s = op == LLVMSIToFP;
        unsigned sw = llvm_int_width(ts_LLVMTypeOf(src));
        if (odd_width(sw)) x = normalize_odd(t, x, sw, s);
        if (x->bits == 64) SFAIL(t, "64-bit integer to float");
        for (unsigned c = 0; c < n; c++) {
            vi_ref i = sv_comp32(t, x, c, s ? X_SEXT : X_ZEXT);
            if (x->bits == 1) i = sv_comp32(t, x, c, X_ZEXT);
            r[c] = f1(t, s && x->bits != 1 ? VA_S32_TO_F32 : VA_U32_TO_F32, i);
        }
        if (db == 16) {
            sv *v = sv_val(t, 16, n);
            for (unsigned c = 0; c < n; c += 2) {
                vi_instr *I = E(t, VA_V2F32_TO_V2F16);
                I->dest = vi_vreg(v->vreg, c / 2, 1); I->src[0] = r[c]; I->src[1] = c + 1 < n ? r[c + 1] : vi_imm(0);
            }
            return v;
        }
        return sv_from_comps32(t, 32, n, r);
    }
    case LLVMFPTrunc: case LLVMFPExt: {
        USE(t, E5);
        if (x->bits == 64 || db == 64) SFAIL(t, "double conversion");
        for (unsigned c = 0; c < n; c++) r[c] = sv_comp32(t, x, c, X_F32);
        if (db == 32) return sv_from_comps32(t, 32, n, r);
        sv *v = sv_val(t, 16, n);
        for (unsigned c = 0; c < n; c += 2) {
            vi_instr *I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(v->vreg, c / 2, 1); I->src[0] = r[c]; I->src[1] = c + 1 < n ? r[c + 1] : vi_imm(0);
        }
        return v;
    }
    default: SFAIL(t, "unsupported cast %d", op);
    }
}

// ---- Vectors (E4) ---------------------------------------------------------------------------------------------------

static vi_ref comp_raw(S *t, sv *v, unsigned c)
{
    if (v->bits == 64) return vi_none();
    return sv_comp32(t, v, c, X_ZEXT);
}

sv *sel_extract_element(S *t, LLVMValueRef inst)
{
    USE(t, E4);
    sv *v = sel_ssa(t, ts_LLVMGetOperand(inst, 0)), *i = sel_ssa(t, ts_LLVMGetOperand(inst, 1));
    if (!v || !i) return NULL;
    if (i->is_const) {
        unsigned c = i->cw[0];
        if (c >= v->ncomp) { uint32_t z[2] = {0}; return sv_const(t, v->bits, 1, z); }
        return sv_scalar(t, v, c);
    }
    if (v->bits == 64) SFAIL(t, "dynamic extract of a 64-bit vector");
    // CSEL chain on the index
    vi_ref r = comp_raw(t, v, 0);
    for (unsigned c = 1; c < v->ncomp; c++)
        r = sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_U32, sv_word(t, i, 0), vi_imm(c), comp_raw(t, v, c), r);
    return sv_from_comps32(t, v->bits, 1, &r);
}

sv *sel_insert_element(S *t, LLVMValueRef inst)
{
    USE(t, E4);
    sv *v = sel_ssa(t, ts_LLVMGetOperand(inst, 0)), *x = sel_ssa(t, ts_LLVMGetOperand(inst, 1)), *i = sel_ssa(t, ts_LLVMGetOperand(inst, 2));
    if (!v || !x || !i) return NULL;
    if (v->bits == 64) {
        if (!i->is_const) SFAIL(t, "dynamic insert into a 64-bit vector");
        vi_ref w[32];
        for (unsigned k = 0; k < 2u * v->ncomp; k++) w[k] = sv_word(t, v, k);
        w[2 * i->cw[0]] = sv_word(t, x, 0); w[2 * i->cw[0] + 1] = sv_word(t, x, 1);
        return retype(t, sv_from_comps32(t, 32, 2 * v->ncomp, w), 64, v->ncomp);
    }
    vi_ref r[16];
    vi_ref xv = comp_raw(t, x, 0);
    for (unsigned c = 0; c < v->ncomp; c++) {
        vi_ref old = comp_raw(t, v, c);
        if (i->is_const) r[c] = i->cw[0] == c ? xv : old;
        else r[c] = sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_U32, sv_word(t, i, 0), vi_imm(c), xv, old);
    }
    return sv_from_comps32(t, v->bits, v->ncomp, r);
}

// Element i of a shufflevector mask (-1 undefined). iOS 16's libLLVM (~LLVM 11) may lack LLVMGetMaskValue: the mask is
// then the third operand, a constant vector.
static int mask_value(LLVMValueRef inst, unsigned i)
{
    if (ts_LLVMGetMaskValue) return ts_LLVMGetMaskValue(inst, i);
    LLVMValueRef mask = ts_LLVMGetNumOperands(inst) > 2 ? ts_LLVMGetOperand(inst, 2) : NULL;
    if (!mask || ts_LLVMIsUndef(mask)) return -1;
    if (ts_LLVMIsAConstantAggregateZero(mask)) return 0;
    LLVMValueRef e = ts_LLVMIsAConstantDataSequential(mask) ? ts_LLVMGetElementAsConstant(mask, i) : ts_LLVMGetOperand(mask, i);
    return !e || ts_LLVMIsUndef(e) || !ts_LLVMIsAConstantInt(e) ? -1 : (int)ts_LLVMConstIntGetZExtValue(e);
}

sv *sel_shuffle(S *t, LLVMValueRef inst)
{
    USE(t, E4);
    sv *a = sel_ssa(t, ts_LLVMGetOperand(inst, 0)), *b = sel_ssa(t, ts_LLVMGetOperand(inst, 1));
    if (!a || !b) return NULL;
    unsigned n = ts_LLVMGetNumMaskElements ? ts_LLVMGetNumMaskElements(inst) : ts_LLVMGetVectorSize(ts_LLVMTypeOf(inst)), na = a->ncomp;
    if (!ts_LLVMGetMaskValue && !(ts_LLVMGetNumOperands(inst) > 2)) SFAIL(t, "shuffle mask not readable");
    if (n > 16) SFAIL(t, "shuffle of %u elements", n);
    if (a->bits == 64) {
        vi_ref w[32];
        for (unsigned c = 0; c < n; c++) {
            int m = mask_value(inst, c);
            sv *src = m < (int)na ? a : b;
            unsigned k = m < 0 ? 0 : (unsigned)(m < (int)na ? m : m - (int)na);
            w[2 * c] = m < 0 ? vi_imm(0) : sv_word(t, src, 2 * k);
            w[2 * c + 1] = m < 0 ? vi_imm(0) : sv_word(t, src, 2 * k + 1);
        }
        return retype(t, sv_from_comps32(t, 32, 2 * n, w), 64, n);
    }
    // Whole-word moves when the elements stay word aligned (32-bit, or 16-bit pairs kept together).
    vi_ref r[16];
    for (unsigned c = 0; c < n; c++) {
        int m = mask_value(inst, c);
        if (m < 0) { r[c] = vi_imm(0); continue; }
        r[c] = m < (int)na ? comp_raw(t, a, (unsigned)m) : comp_raw(t, b, (unsigned)m - na);
    }
    return sv_from_comps32(t, a->bits, n, r);
}

// ---- Math library (E6-E13) ------------------------------------------------------------------------------------------

static sv *arg(S *t, LLVMValueRef inst, unsigned i)
{
    if (i >= (unsigned)ts_LLVMGetNumArgOperands(inst)) SFAIL(t, "missing argument");
    return sel_ssa(t, ts_LLVMGetOperand(inst, i));
}

static bool fname_is(const char *op, const char *what)
{
    // op is "<name>.<type...>" (air.fast_sin.f32) or "<name>" ; compare the name part
    size_t n = strlen(what);
    return !strncmp(op, what, n) && (op[n] == '.' || op[n] == 0);
}

static sv *fcall(S *t, int op, LLVMValueRef inst, unsigned nargs)
{
    sv *a[3];
    for (unsigned k = 0; k < nargs; k++) if (!(a[k] = arg(t, inst, k))) return NULL;
    return float_op(t, op, nargs, a);
}

static sv *icall(S *t, int op, LLVMValueRef inst, unsigned nargs)
{
    sv *a[4];
    for (unsigned k = 0; k < nargs; k++) if (!(a[k] = arg(t, inst, k))) return NULL;
    return int_op(t, op, nargs, a);
}

// Float helper chains on 32-bit components (computed with fop/iop pieces).
typedef vi_ref (*chain_fn)(S *t, vi_ref *a);

static sv *fchain(S *t, LLVMValueRef inst, unsigned nargs, chain_fn fn)
{
    sv *a[3];
    for (unsigned k = 0; k < nargs; k++) if (!(a[k] = arg(t, inst, k))) return NULL;
    unsigned n = 1, bits = a[0]->bits;
    for (unsigned k = 0; k < nargs; k++) if (a[k]->ncomp > n) n = a[k]->ncomp;
    vi_ref r[16];
    for (unsigned c = 0; c < n; c++) {
        vi_ref x[3];
        for (unsigned k = 0; k < nargs; k++) x[k] = sv_comp32(t, a[k], a[k]->ncomp == 1 ? 0 : c, X_F32);
        r[c] = fn(t, x);
    }
    if (bits == 16) {
        sv *v = sv_val(t, 16, n);
        for (unsigned c = 0; c < n; c += 2) {
            vi_instr *I = E(t, VA_V2F32_TO_V2F16);
            I->dest = vi_vreg(v->vreg, c / 2, 1); I->src[0] = r[c]; I->src[1] = c + 1 < n ? r[c + 1] : vi_imm(0);
        }
        return v;
    }
    return sv_from_comps32(t, 32, n, r);
}

static vi_ref c_exp(S *t, vi_ref *a) { return fexp2(t, a[0], fbits((float)M_LOG2E)); }
static vi_ref c_exp10(S *t, vi_ref *a) { return fexp2(t, a[0], fbits((float)(M_LN10 / M_LN2))); }
static vi_ref c_log(S *t, vi_ref *a) { return fmul(t, flog2(t, a[0]), vi_imm(fbits((float)M_LN2))); }
static vi_ref c_log10(S *t, vi_ref *a) { return fmul(t, flog2(t, a[0]), vi_imm(fbits((float)(M_LN2 / M_LN10)))); }
static vi_ref c_tan(S *t, vi_ref *a) { return fmul(t, fsincos(t, a[0], false), f1(t, VA_FRCP_F32, fsincos(t, a[0], true))); }

// atan(x) for |x| <= 1: polynomial (max error ~1e-5, six terms), extended with pi/2 - atan(1/x).
static vi_ref atan_core(S *t, vi_ref x)
{
    vi_ref ax = f1(t, VA_FABS_F32, x);
    vi_ref big = sel_tmp(t);
    vi_instr *I = E(t, VA_FCMP_F32); I->dest = big; I->src[0] = ax; I->src[1] = vi_imm(fbits(1.0f));
    vi_set(I, VAF_cmpf, VA_CMPF_M_GT); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
    vi_ref z = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, big, vi_imm(0), f1(t, VA_FRCP_F32, ax), ax);
    vi_ref z2 = fmul(t, z, z);
    // atan(z) ~ z * (c0 + z2*(c1 + ... + z2*c5)) (the five-term form missed c5 and was off by ~0.01 near |z| = 1)
    static const float c[6] = { 0.99997726f, -0.33262347f, 0.19354346f, -0.11643287f, 0.05265332f, -0.01172120f };
    vi_ref p = vi_imm(fbits(c[5]));
    for (int k = 4; k >= 0; k--) p = ffma(t, p, z2, vi_imm(fbits(c[k])));
    vi_ref r = fmul(t, p, z);
    vi_ref rb = fadd(t, vi_imm(fbits(1.57079633f)), r, true);
    r = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, big, vi_imm(0), rb, r);
    // sign of x
    vi_ref m = sel_tmp(t);
    I = E(t, VA_AND_I32); I->dest = m; I->src[0] = x; I->src[2] = vi_imm(0x80000000);
    return logic(t, VA_OR_I32, r, m);
}
static vi_ref c_atan(S *t, vi_ref *a) { return atan_core(t, a[0]); }
static vi_ref c_atan2(S *t, vi_ref *a)
{
    // atan(y/x) adjusted by quadrant
    vi_ref y = a[0], x = a[1];
    vi_ref q = atan_core(t, fmul(t, y, f1(t, VA_FRCP_F32, x)));
    vi_ref pi = sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, y, vi_imm(0), vi_imm(fbits(-3.14159265f)), vi_imm(fbits(3.14159265f)));
    vi_ref adj = fadd(t, q, pi, false);
    vi_ref r = sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, x, vi_imm(0), adj, q);
    // x == 0: +-pi/2
    vi_ref half = sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, y, vi_imm(0), vi_imm(fbits(-1.57079633f)), vi_imm(fbits(1.57079633f)));
    return sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_F32, x, vi_imm(0), half, r);
}
static vi_ref c_asin(S *t, vi_ref *a)
{
    // atan(x / sqrt(1 - x^2))
    vi_ref x = a[0];
    vi_ref d = ffma(t, x, x, vi_imm(fbits(-1.0f)));     // x^2 - 1
    vi_ref one_m = f1(t, VA_FNEG_F32, d);
    vi_ref rs = f1(t, VA_FRSQ_F32, one_m);
    return atan_core(t, fmul(t, x, rs));
}
static vi_ref c_acos(S *t, vi_ref *a)
{
    vi_ref as = c_asin(t, a);
    return fadd(t, vi_imm(fbits(1.57079633f)), as, true);
}
static vi_ref c_sinh(S *t, vi_ref *a)
{
    vi_ref e = fexp2(t, a[0], fbits((float)M_LOG2E)), ei = f1(t, VA_FRCP_F32, e);
    return fmul(t, fadd(t, e, ei, true), vi_imm(fbits(0.5f)));
}
static vi_ref c_cosh(S *t, vi_ref *a)
{
    vi_ref e = fexp2(t, a[0], fbits((float)M_LOG2E)), ei = f1(t, VA_FRCP_F32, e);
    return fmul(t, fadd(t, e, ei, false), vi_imm(fbits(0.5f)));
}
static vi_ref c_tanh(S *t, vi_ref *a)
{
    // (e^2x - 1) / (e^2x + 1), clamped input
    vi_ref x = sel_csel(t, VA_CMPF_M_GT, VA_CSEL_F32, a[0], vi_imm(fbits(10.0f)), vi_imm(fbits(10.0f)), a[0]);
    x = sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, x, vi_imm(fbits(-10.0f)), vi_imm(fbits(-10.0f)), x);
    vi_ref e = fexp2(t, x, fbits((float)(2.0 * M_LOG2E)));
    return fmul(t, fadd(t, e, vi_imm(fbits(1.0f)), true), f1(t, VA_FRCP_F32, fadd(t, e, vi_imm(fbits(1.0f)), false)));
}
static vi_ref c_asinh(S *t, vi_ref *a)
{
    vi_ref x = a[0];
    vi_ref s = fmul(t, f1(t, VA_FABS_F32, ffma(t, x, x, vi_imm(fbits(1.0f)))), vi_imm(fbits(1.0f)));
    vi_ref sq = fmul(t, s, f1(t, VA_FRSQ_F32, s));
    vi_ref ax = f1(t, VA_FABS_F32, x);
    vi_ref l = fmul(t, flog2(t, fadd(t, ax, sq, false)), vi_imm(fbits((float)M_LN2)));
    vi_ref m = sel_tmp(t);
    vi_instr *I = E(t, VA_AND_I32); I->dest = m; I->src[0] = x; I->src[2] = vi_imm(0x80000000);
    return logic(t, VA_OR_I32, l, m);
}
static vi_ref c_acosh(S *t, vi_ref *a)
{
    vi_ref x = a[0];
    vi_ref s = ffma(t, x, x, vi_imm(fbits(-1.0f)));
    vi_ref sq = fmul(t, s, f1(t, VA_FRSQ_F32, s));
    return fmul(t, flog2(t, fadd(t, x, sq, false)), vi_imm(fbits((float)M_LN2)));
}
static vi_ref c_atanh(S *t, vi_ref *a)
{
    vi_ref x = a[0];
    vi_ref q = fmul(t, fadd(t, vi_imm(fbits(1.0f)), x, false), f1(t, VA_FRCP_F32, fadd(t, vi_imm(fbits(1.0f)), x, true)));
    return fmul(t, flog2(t, q), vi_imm(fbits((float)(0.5 * M_LN2))));
}
static vi_ref c_mix(S *t, vi_ref *a) { return ffma(t, fadd(t, a[1], a[0], true), a[2], a[0]); }
static vi_ref c_clamp(S *t, vi_ref *a)
{
    vi_ref m = sel_tmp(t);
    vi_instr *I = E(t, VA_FMAX_F32); I->dest = m; I->src[0] = a[0]; I->src[1] = a[1]; vi_set(I, VAF_sem, VA_SEM_M_NAN_SUPPRESS);
    vi_ref r = sel_tmp(t);
    I = E(t, VA_FMIN_F32); I->dest = r; I->src[0] = m; I->src[1] = a[2]; vi_set(I, VAF_sem, VA_SEM_M_NAN_SUPPRESS);
    return r;
}
static vi_ref c_step(S *t, vi_ref *a) { return sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, a[1], a[0], vi_imm(0), vi_imm(fbits(1.0f))); }
static vi_ref c_smoothstep(S *t, vi_ref *a)
{
    // t = sat((x - e0) / (e1 - e0)); t*t*(3 - 2t)
    vi_ref tt = fmul(t, fadd(t, a[2], a[0], true), f1(t, VA_FRCP_F32, fadd(t, a[1], a[0], true)));
    vi_ref s = sel_tmp(t);
    vi_instr *I = E(t, VA_FADD_F32); I->dest = s; I->src[0] = tt; I->src[1] = vi_imm(0); vi_set(I, VAF_clamp, VA_CLAMP_M_CLAMP_0_1);
    vi_ref p = ffma(t, s, vi_imm(fbits(-2.0f)), vi_imm(fbits(3.0f)));
    return fmul(t, fmul(t, s, s), p);
}
static vi_ref c_radians(S *t, vi_ref *a) { return fmul(t, a[0], vi_imm(fbits((float)(M_PI / 180.0)))); }
static vi_ref c_degrees(S *t, vi_ref *a) { return fmul(t, a[0], vi_imm(fbits((float)(180.0 / M_PI)))); }
static vi_ref fclass_cmp(S *t, vi_ref x, int kind)
{
    // 0: isnan (x != x), 1: isinf (|x| == inf), 2: isfinite (|x| < inf), 3: signbit
    vi_ref d = sel_tmp(t);
    if (kind == 3) {
        vi_instr *I = E(t, VA_RSHIFT_OR_I32); I->dest = d; I->src[0] = x; I->src[1] = vi_imm(31); I->src[2] = vi_imm(0);
        return d;
    }
    vi_ref ax = kind ? f1(t, VA_FABS_F32, x) : x;
    vi_instr *I = E(t, VA_FCMP_F32); I->dest = d; I->src[0] = ax; I->src[1] = kind ? vi_imm(0x7f800000) : x;
    vi_set(I, VAF_cmpf, kind == 0 ? VA_CMPF_M_NE : kind == 1 ? VA_CMPF_M_EQ : VA_CMPF_M_LT);
    vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
    return d;
}

static sv *fclass(S *t, LLVMValueRef inst, int kind)
{
    sv *x = arg(t, inst, 0);
    if (!x) return NULL;
    vi_ref r[16];
    for (unsigned c = 0; c < x->ncomp; c++) r[c] = fclass_cmp(t, sv_comp32(t, x, c, X_F32), kind);
    return sv_from_comps32(t, 1, x->ncomp, r);
}

// Reductions over vector components: dot, length, all/any.
static vi_ref fdot(S *t, sv *a, sv *b)
{
    vi_ref acc = fmul(t, sv_comp32(t, a, 0, X_F32), sv_comp32(t, b, 0, X_F32));
    for (unsigned c = 1; c < a->ncomp; c++) acc = ffma(t, sv_comp32(t, a, c, X_F32), sv_comp32(t, b, c, X_F32), acc);
    return acc;
}

static sv *f32_result(S *t, unsigned bits, unsigned n, vi_ref *r)
{
    if (bits != 16) return sv_from_comps32(t, 32, n, r);
    sv *v = sv_val(t, 16, n);
    for (unsigned c = 0; c < n; c += 2) {
        vi_instr *I = E(t, VA_V2F32_TO_V2F16);
        I->dest = vi_vreg(v->vreg, c / 2, 1); I->src[0] = r[c]; I->src[1] = c + 1 < n ? r[c + 1] : vi_imm(0);
    }
    return v;
}

static sv *geometry(S *t, LLVMValueRef inst, const char *op)
{
    USE(t, E8);
    sv *a = arg(t, inst, 0);
    if (!a) return NULL;
    unsigned bits = a->bits;
    vi_ref r[4];
    if (fname_is(op, "dot")) { sv *b = arg(t, inst, 1); if (!b) return NULL; r[0] = fdot(t, a, b); return f32_result(t, bits, 1, r); }
    if (fname_is(op, "length") || fname_is(op, "fast_length") || fname_is(op, "precise_length")) {
        vi_ref d = fdot(t, a, a);
        r[0] = fop(t, OP_SQRT, &d, 1);
        return f32_result(t, bits, 1, r);
    }
    if (fname_is(op, "distance") || fname_is(op, "fast_distance") || fname_is(op, "precise_distance")) {
        sv *b = arg(t, inst, 1);
        if (!b) return NULL;
        vi_ref acc = vi_none();
        for (unsigned c = 0; c < a->ncomp; c++) {
            vi_ref d = fadd(t, sv_comp32(t, a, c, X_F32), sv_comp32(t, b, c, X_F32), true);
            acc = c ? ffma(t, d, d, acc) : fmul(t, d, d);
        }
        r[0] = fop(t, OP_SQRT, &acc, 1);
        return f32_result(t, bits, 1, r);
    }
    if (fname_is(op, "normalize") || fname_is(op, "fast_normalize") || fname_is(op, "precise_normalize")) {
        vi_ref inv = f1(t, VA_FRSQ_F32, fdot(t, a, a));
        for (unsigned c = 0; c < a->ncomp; c++) r[c] = fmul(t, sv_comp32(t, a, c, X_F32), inv);
        return f32_result(t, bits, a->ncomp, r);
    }
    if (fname_is(op, "cross")) {
        sv *b = arg(t, inst, 1);
        if (!b) return NULL;
        vi_ref x[3], y[3];
        for (unsigned c = 0; c < 3; c++) { x[c] = sv_comp32(t, a, c, X_F32); y[c] = sv_comp32(t, b, c, X_F32); }
        for (unsigned c = 0; c < 3; c++) {
            unsigned i = (c + 1) % 3, j = (c + 2) % 3;
            vi_ref m = fmul(t, x[j], y[i]);
            vi_ref d = sel_tmp(t);
            vi_instr *I = E(t, VA_FMA_F32); I->dest = d; I->src[0] = x[i]; I->src[1] = y[j]; I->src[2] = m; vi_set(I, VAF_neg2, 1);
            r[c] = d;
        }
        return f32_result(t, bits, 3, r);
    }
    if (fname_is(op, "reflect")) {
        // i - 2 dot(n, i) n
        sv *n = arg(t, inst, 1);
        if (!n) return NULL;
        vi_ref d2 = fmul(t, fdot(t, n, a), vi_imm(fbits(-2.0f)));
        for (unsigned c = 0; c < a->ncomp; c++) r[c] = ffma(t, d2, sv_comp32(t, n, c, X_F32), sv_comp32(t, a, c, X_F32));
        return f32_result(t, bits, a->ncomp, r);
    }
    if (fname_is(op, "refract")) {
        // k = 1 - eta^2 (1 - dot(n,i)^2); k < 0 ? 0 : eta i - (eta dot + sqrt(k)) n
        sv *n = arg(t, inst, 1), *eta = arg(t, inst, 2);
        if (!n || !eta) return NULL;
        vi_ref e = sv_comp32(t, eta, 0, X_F32), d = fdot(t, n, a);
        vi_ref one_m = ffma(t, f1(t, VA_FNEG_F32, d), d, vi_imm(fbits(1.0f)));
        vi_ref k = ffma(t, f1(t, VA_FNEG_F32, fmul(t, e, e)), one_m, vi_imm(fbits(1.0f)));
        vi_ref sk = fop(t, OP_SQRT, &k, 1);
        vi_ref f = ffma(t, e, d, sk);
        for (unsigned c = 0; c < a->ncomp; c++) {
            vi_ref v = fadd(t, fmul(t, e, sv_comp32(t, a, c, X_F32)), fmul(t, f, sv_comp32(t, n, c, X_F32)), true);
            r[c] = sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, k, vi_imm(0), vi_imm(0), v);
        }
        return f32_result(t, bits, a->ncomp, r);
    }
    return NULL;
}

// pack/unpack (E11): unorm/snorm 4x8 and 2x16, unorm 565
static sv *packing(S *t, LLVMValueRef inst, const char *op)
{
    USE(t, E11);
    sv *a = arg(t, inst, 0);
    if (!a) return NULL;
    bool unpack = strstr(op, "unpack") != NULL;
    bool snorm = strstr(op, "snorm") != NULL;
    bool b8 = strstr(op, "4x8") != NULL, b565 = strstr(op, "565") != NULL;
    if (!unpack) {
        // float -> int per component, packed
        unsigned n = a->ncomp, bitsper = b8 ? 8 : 16;
        vi_ref w = vi_imm(0);
        unsigned shifts565[3] = { 11, 5, 0 }, max565[3] = { 31, 63, 31 };
        for (unsigned c = 0; c < n; c++) {
            vi_ref f = sv_comp32(t, a, c, X_F32);
            float scale = b565 ? (float)max565[c] : snorm ? (b8 ? 127.0f : 32767.0f) : (b8 ? 255.0f : 65535.0f);
            vi_ref cl = sel_tmp(t);
            vi_instr *I = E(t, VA_FADD_F32); I->dest = cl; I->src[0] = f; I->src[1] = vi_imm(0);
            vi_set(I, VAF_clamp, snorm ? VA_CLAMP_M_CLAMP_M1_1 : VA_CLAMP_M_CLAMP_0_1);
            vi_ref s = fround(t, fmul(t, cl, vi_imm(fbits(scale))), VA_ROUND_INTEGER_M_NONE);
            vi_ref iv = sel_tmp(t);
            I = E(t, snorm ? VA_F32_TO_S32 : VA_F32_TO_U32); I->dest = iv; I->src[0] = s; vi_set(I, VAF_round, VA_ROUND_INTEGER_M_ROUND_ZERO);
            vi_ref m = logic(t, VA_AND_I32, iv, vi_imm(b565 ? max565[c] : (1u << bitsper) - 1));
            vi_ref sh = shift(t, VA_LSHIFT_OR_I32, m, vi_imm(b565 ? shifts565[c] : c * bitsper));
            w = c ? logic(t, VA_OR_I32, w, sh) : sh;
        }
        return sv_from_comps32(t, b565 ? 16 : 32, 1, &w);
    }
    unsigned n = b565 ? 3 : b8 ? 4 : 2, bitsper = b8 ? 8 : 16;
    vi_ref x = sv_comp32(t, a, 0, X_ZEXT), r[4];
    unsigned shifts565[3] = { 11, 5, 0 }, bits565[3] = { 5, 6, 5 };
    unsigned rbits = 32;
    LLVMTypeRef rty = ts_LLVMTypeOf(inst);
    unsigned rb, rn; bool rf;
    if (sel_type_info(rty, &rb, &rn, &rf)) rbits = rb;
    for (unsigned c = 0; c < n; c++) {
        unsigned off = b565 ? shifts565[c] : c * bitsper, nb = b565 ? bits565[c] : bitsper;
        vi_ref args3[3] = { x, vi_imm(off), vi_imm(nb) };
        vi_ref iv = iop(t, snorm ? OP_EXTRACT_S : OP_EXTRACT_U, args3, 3);
        vi_ref f = f1(t, snorm ? VA_S32_TO_F32 : VA_U32_TO_F32, iv);
        float scale = b565 ? (float)((1u << nb) - 1) : snorm ? (b8 ? 127.0f : 32767.0f) : (b8 ? 255.0f : 65535.0f);
        f = fmul(t, f, vi_imm(fbits(1.0f / scale)));
        if (snorm) f = sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, f, vi_imm(fbits(-1.0f)), vi_imm(fbits(-1.0f)), f);
        r[c] = f;
    }
    return f32_result(t, rbits, n, r);
}

static sv *vec_bool_reduce(S *t, LLVMValueRef inst, bool all)
{
    USE(t, E13);
    sv *a = arg(t, inst, 0);
    if (!a) return NULL;
    vi_ref acc = sv_comp32(t, a, 0, X_ZEXT);
    if (a->bits != 1) acc = icmp32(t, VA_ICMP_U32, VA_CMPF_M_NE, acc, vi_imm(0));
    for (unsigned c = 1; c < a->ncomp; c++) {
        vi_ref x = sv_comp32(t, a, c, X_ZEXT);
        if (a->bits != 1) x = icmp32(t, VA_ICMP_U32, VA_CMPF_M_NE, x, vi_imm(0));
        acc = logic(t, all ? VA_AND_I32 : VA_OR_I32, acc, x);
    }
    return sv_from_comps32(t, 1, 1, &acc);
}

sv *sel_math(S *t, LLVMValueRef inst, const char *name)
{
    const char *op = name + (sel_name_is(name, "air.") ? 4 : 5);
    if (sel_name_is(op, "fast_")) op += 5;
    else if (sel_name_is(op, "precise_")) op += 8;
    // integer variants: air.<op>.s.i32 / air.<op>.u.i32
    bool u = strstr(name, ".u.") != NULL, s = strstr(name, ".s.") != NULL;
    sv *r = NULL;
    // E7 common
    if (fname_is(op, "fabs") || (fname_is(op, "abs") && !u && !s && !sel_name_is(name, "llvm.abs"))) { USE(t, E7); return fcall(t, OP_FABS, inst, 1); }
    if (fname_is(op, "fmin") || fname_is(op, "minnum") || (fname_is(op, "min") && !u && !s)) { USE(t, E7); return fcall(t, OP_FMIN, inst, 2); }
    if (fname_is(op, "fmax") || fname_is(op, "maxnum") || (fname_is(op, "max") && !u && !s)) { USE(t, E7); return fcall(t, OP_FMAX, inst, 2); }
    if (fname_is(op, "fma") || fname_is(op, "fmuladd") || fname_is(op, "mad")) { USE(t, E7); return fcall(t, OP_FMA, inst, 3); }
    if (fname_is(op, "floor")) { USE(t, E7); return fcall(t, OP_FLOOR, inst, 1); }
    if (fname_is(op, "ceil")) { USE(t, E7); return fcall(t, OP_CEIL, inst, 1); }
    if (fname_is(op, "trunc")) { USE(t, E7); return fcall(t, OP_TRUNC, inst, 1); }
    if (fname_is(op, "rint") || fname_is(op, "roundeven") || fname_is(op, "nearbyint")) { USE(t, E7); return fcall(t, OP_RINT, inst, 1); }
    if (fname_is(op, "round")) { USE(t, E7); return fcall(t, OP_ROUND, inst, 1); }
    if (fname_is(op, "fract")) { USE(t, E7); return fcall(t, OP_FRACT, inst, 1); }
    if (fname_is(op, "saturate")) { USE(t, E7); return fcall(t, OP_FSAT, inst, 1); }
    if (fname_is(op, "sign")) { USE(t, E7); return fcall(t, OP_SIGN, inst, 1); }
    if (fname_is(op, "copysign")) { USE(t, E7); return fcall(t, OP_COPYSIGN, inst, 2); }
    if (fname_is(op, "fmod")) { USE(t, E7); return fcall(t, OP_FMOD, inst, 2); }
    if (fname_is(op, "ldexp")) {
        USE(t, E7);
        sv *a = arg(t, inst, 0), *b = arg(t, inst, 1);
        if (!a || !b) return NULL;
        vi_ref rr[16];
        for (unsigned c = 0; c < a->ncomp; c++) { vi_ref x[2] = { sv_comp32(t, a, c, X_F32), sv_comp32(t, b, b->ncomp == 1 ? 0 : c, X_SEXT) }; rr[c] = fop(t, OP_LDEXP, x, 2); }
        return f32_result(t, a->bits, a->ncomp, rr);
    }
    if (fname_is(op, "mix")) { USE(t, E7); return fchain(t, inst, 3, c_mix); }
    if (fname_is(op, "fclamp") || (fname_is(op, "clamp") && !u && !s)) { USE(t, E7); return fchain(t, inst, 3, c_clamp); }
    if (fname_is(op, "step")) { USE(t, E7); return fchain(t, inst, 2, c_step); }
    if (fname_is(op, "smoothstep")) { USE(t, E7); return fchain(t, inst, 3, c_smoothstep); }
    if (fname_is(op, "radians")) { USE(t, E7); return fchain(t, inst, 1, c_radians); }
    if (fname_is(op, "degrees")) { USE(t, E7); return fchain(t, inst, 1, c_degrees); }
    if (fname_is(op, "isnan")) { USE(t, E7); return fclass(t, inst, 0); }
    if (fname_is(op, "isinf")) { USE(t, E7); return fclass(t, inst, 1); }
    if (fname_is(op, "isfinite")) { USE(t, E7); return fclass(t, inst, 2); }
    if (fname_is(op, "signbit")) { USE(t, E7); return fclass(t, inst, 3); }
    if (fname_is(op, "fmin3") || fname_is(op, "fmax3") || fname_is(op, "fmedian3") ||
        ((fname_is(op, "min3") || fname_is(op, "max3") || fname_is(op, "median3")) && !u && !s)) {
        USE(t, E7);
        sv *a[3];
        for (unsigned k = 0; k < 3; k++) if (!(a[k] = arg(t, inst, k))) return NULL;
        bool mn = strstr(op, "min") != NULL, mx = strstr(op, "max") != NULL;
        if (mn || mx) { sv *p[2] = { a[0], a[1] }; sv *x = float_op(t, mn ? OP_FMIN : OP_FMAX, 2, p); if (!x) return NULL; sv *q[2] = { x, a[2] }; return float_op(t, mn ? OP_FMIN : OP_FMAX, 2, q); }
        // median = max(min(a,b), min(max(a,b), c))
        sv *p[2] = { a[0], a[1] };
        sv *lo = float_op(t, OP_FMIN, 2, p), *hi = float_op(t, OP_FMAX, 2, p);
        if (!lo || !hi) return NULL;
        sv *q[2] = { hi, a[2] };
        sv *m = float_op(t, OP_FMIN, 2, q);
        if (!m) return NULL;
        sv *z[2] = { lo, m };
        return float_op(t, OP_FMAX, 2, z);
    }
    // E6 transcendentals
    if (fname_is(op, "sqrt")) { USE(t, E6); return fcall(t, OP_SQRT, inst, 1); }
    if (fname_is(op, "rsqrt")) { USE(t, E6); return fcall(t, OP_RSQRT, inst, 1); }
    if (fname_is(op, "exp2")) { USE(t, E6); return fcall(t, OP_EXP2, inst, 1); }
    if (fname_is(op, "log2")) { USE(t, E6); return fcall(t, OP_LOG2, inst, 1); }
    if (fname_is(op, "sin")) { USE(t, E6); return fcall(t, OP_SIN, inst, 1); }
    if (fname_is(op, "cos")) { USE(t, E6); return fcall(t, OP_COS, inst, 1); }
    if (fname_is(op, "pow") || fname_is(op, "powr")) { USE(t, E6); return fcall(t, OP_POW, inst, 2); }
    if (fname_is(op, "exp")) { USE(t, E6); return fchain(t, inst, 1, c_exp); }
    if (fname_is(op, "exp10")) { USE(t, E6); return fchain(t, inst, 1, c_exp10); }
    if (fname_is(op, "log")) { USE(t, E6); return fchain(t, inst, 1, c_log); }
    if (fname_is(op, "log10")) { USE(t, E6); return fchain(t, inst, 1, c_log10); }
    if (fname_is(op, "tan")) { USE(t, E6); return fchain(t, inst, 1, c_tan); }
    if (fname_is(op, "atan")) { USE(t, E6); return fchain(t, inst, 1, c_atan); }
    if (fname_is(op, "atan2")) { USE(t, E6); return fchain(t, inst, 2, c_atan2); }
    if (fname_is(op, "asin")) { USE(t, E6); return fchain(t, inst, 1, c_asin); }
    if (fname_is(op, "acos")) { USE(t, E6); return fchain(t, inst, 1, c_acos); }
    if (fname_is(op, "sinh")) { USE(t, E6); return fchain(t, inst, 1, c_sinh); }
    if (fname_is(op, "cosh")) { USE(t, E6); return fchain(t, inst, 1, c_cosh); }
    if (fname_is(op, "tanh")) { USE(t, E6); return fchain(t, inst, 1, c_tanh); }
    if (fname_is(op, "asinh")) { USE(t, E6); return fchain(t, inst, 1, c_asinh); }
    if (fname_is(op, "acosh")) { USE(t, E6); return fchain(t, inst, 1, c_acosh); }
    if (fname_is(op, "atanh")) { USE(t, E6); return fchain(t, inst, 1, c_atanh); }
    // E8 geometry
    if ((r = geometry(t, inst, op)) || t->error) return r;
    // E11
    if (sel_name_is(op, "pack_") || sel_name_is(op, "unpack_") || sel_name_is(op, "pack.") || sel_name_is(op, "unpack.")) return packing(t, inst, op);
    // E13
    if (fname_is(op, "all")) return vec_bool_reduce(t, inst, true);
    if (fname_is(op, "any")) return vec_bool_reduce(t, inst, false);
    if (fname_is(op, "select")) {
        USE(t, E13);
        sv *x = arg(t, inst, 0), *y = arg(t, inst, 1), *c = arg(t, inst, 2);
        if (!x || !y || !c) return NULL;
        vi_ref rr[16];
        for (unsigned k = 0; k < x->ncomp; k++)
            rr[k] = sel_csel(t, VA_CMPF_M_NE, VA_CSEL_U32, sv_comp32(t, c, c->ncomp == 1 ? 0 : k, X_ZEXT), vi_imm(0), sv_comp32(t, y, k, X_ZEXT), sv_comp32(t, x, k, X_ZEXT));
        return sv_from_comps32(t, x->bits, x->ncomp, rr);
    }
    // E9 integer / bits
    if (fname_is(op, "ctlz") || fname_is(op, "clz")) { USE(t, E9); return icall(t, OP_CLZ, inst, 1); }
    if (fname_is(op, "cttz") || fname_is(op, "ctz")) { USE(t, E9); return icall(t, OP_CTZ, inst, 1); }
    if (fname_is(op, "ctpop") || fname_is(op, "popcount")) { USE(t, E9); return icall(t, OP_POPCNT, inst, 1); }
    if (fname_is(op, "bitreverse") || fname_is(op, "reverse_bits")) { USE(t, E9); return icall(t, OP_BITREV, inst, 1); }
    if (fname_is(op, "mul_hi")) { USE(t, E9); return icall(t, u ? OP_UMULHI : OP_SMULHI, inst, 2); }
    if (fname_is(op, "add_sat") || fname_is(op, "uadd") || fname_is(op, "sadd")) { USE(t, E9); return icall(t, u || sel_name_is(op, "uadd") ? OP_UADDSAT : OP_SADDSAT, inst, 2); }
    if (fname_is(op, "sub_sat")) { USE(t, E9); return icall(t, u ? OP_USUBSAT : OP_SSUBSAT, inst, 2); }
    if (fname_is(op, "uadd.sat")) { USE(t, E9); return icall(t, OP_UADDSAT, inst, 2); }
    if (fname_is(op, "hadd")) { USE(t, E9); return icall(t, u ? OP_UHADD : OP_SHADD, inst, 2); }
    if (fname_is(op, "rhadd")) { USE(t, E9); return icall(t, u ? OP_URHADD : OP_SRHADD, inst, 2); }
    if (fname_is(op, "abs_diff")) { USE(t, E9); return icall(t, u ? OP_UABSDIFF : OP_SABSDIFF, inst, 2); }
    if (fname_is(op, "rotate") || fname_is(op, "fshl")) { USE(t, E9); return icall(t, OP_ROTL, inst, 2); }
    if (fname_is(op, "extract_bits")) { USE(t, E9); return icall(t, u ? OP_EXTRACT_U : OP_EXTRACT_S, inst, 3); }
    if (fname_is(op, "insert_bits")) { USE(t, E9); return icall(t, OP_INSERT, inst, 4); }
    if (fname_is(op, "abs") || sel_name_is(name, "llvm.abs")) { USE(t, E9); return icall(t, OP_IABS, inst, 1); }
    if (fname_is(op, "min") || fname_is(op, "umin") || fname_is(op, "smin")) { USE(t, E9); return icall(t, u || sel_name_is(op, "umin") ? OP_UMIN : OP_SMIN, inst, 2); }
    if (fname_is(op, "max") || fname_is(op, "umax") || fname_is(op, "smax")) { USE(t, E9); return icall(t, u || sel_name_is(op, "umax") ? OP_UMAX : OP_SMAX, inst, 2); }
    if (fname_is(op, "clamp")) {
        USE(t, E9);
        sv *a[3];
        for (unsigned k = 0; k < 3; k++) if (!(a[k] = arg(t, inst, k))) return NULL;
        sv *p[2] = { a[0], a[1] };
        sv *m = int_op(t, u ? OP_UMAX : OP_SMAX, 2, p);
        if (!m) return NULL;
        sv *q[2] = { m, a[2] };
        return int_op(t, u ? OP_UMIN : OP_SMIN, 2, q);
    }
    if (fname_is(op, "min3") || fname_is(op, "max3") || fname_is(op, "median3")) {
        USE(t, E9);
        sv *a[3];
        for (unsigned k = 0; k < 3; k++) if (!(a[k] = arg(t, inst, k))) return NULL;
        int mn = u ? OP_UMIN : OP_SMIN, mx = u ? OP_UMAX : OP_SMAX;
        sv *p[2] = { a[0], a[1] };
        if (fname_is(op, "min3") || fname_is(op, "max3")) {
            int o = fname_is(op, "min3") ? mn : mx;
            sv *x = int_op(t, o, 2, p); if (!x) return NULL;
            sv *q[2] = { x, a[2] }; return int_op(t, o, 2, q);
        }
        sv *lo = int_op(t, mn, 2, p), *hi = int_op(t, mx, 2, p);
        if (!lo || !hi) return NULL;
        sv *q[2] = { hi, a[2] }; sv *m = int_op(t, mn, 2, q); if (!m) return NULL;
        sv *z[2] = { lo, m }; return int_op(t, mx, 2, z);
    }
    if (fname_is(op, "mul24") || fname_is(op, "mad24")) {
        USE(t, E9);
        sv *a[3];
        unsigned na = fname_is(op, "mad24") ? 3 : 2;
        for (unsigned k = 0; k < na; k++) if (!(a[k] = arg(t, inst, k))) return NULL;
        sv *m = int_op(t, OP_MUL, 2, a);
        if (!m || na == 2) return m;
        sv *q[2] = { m, a[2] };
        return int_op(t, OP_ADD, 2, q);
    }
    if (fname_is(op, "fshr")) { USE(t, E9); return icall(t, OP_ROTR, inst, 2); }
    SFAIL(t, "unsupported call %s", name);
}

// air.convert.<f|s|u>.<dst>.<f|s|u>.<src>[.sat|.rte...]
sv *sel_convert(S *t, LLVMValueRef inst, const char *name)
{
    USE(t, E10);
    sv *x = arg(t, inst, 0);
    if (!x) return NULL;
    char dk = 0, sk = 0;
    const char *p = name + strlen("air.convert.");
    dk = p[0];
    const char *q = strchr(p, '.');
    q = q ? strchr(q + 1, '.') : NULL;
    sk = q ? q[1] : 0;
    bool sat = strstr(name, ".sat") != NULL;
    unsigned db, dn; bool dflt;
    if (!sel_type_info(ts_LLVMTypeOf(inst), &db, &dn, &dflt)) SFAIL(t, "convert to an unsupported type");
    if (db == 64 || x->bits == 64) SFAIL(t, "64-bit conversion");
    vi_ref r[16];
    for (unsigned c = 0; c < x->ncomp; c++) {
        vi_ref v;
        if (sk == 'f') {
            v = sv_comp32(t, x, c, X_F32);
            if (dk == 'f') { r[c] = v; continue; }
            if (sat && db < 32) {
                // clamp to the destination range in float
                float lo = dk == 's' ? -(float)(1u << (db - 1)) : 0.0f, hi = dk == 's' ? (float)((1u << (db - 1)) - 1) : (float)((1ull << db) - 1);
                v = sel_csel(t, VA_CMPF_M_LT, VA_CSEL_F32, v, vi_imm(fbits(lo)), vi_imm(fbits(lo)), v);
                v = sel_csel(t, VA_CMPF_M_GT, VA_CSEL_F32, v, vi_imm(fbits(hi)), vi_imm(fbits(hi)), v);
            }
            vi_ref d = sel_tmp(t);
            vi_instr *I = E(t, dk == 's' ? VA_F32_TO_S32 : VA_F32_TO_U32);
            I->dest = d; I->src[0] = v; vi_set(I, VAF_round, VA_ROUND_INTEGER_M_ROUND_ZERO);
            r[c] = d;
        } else {
            v = sv_comp32(t, x, c, sk == 's' ? X_SEXT : X_ZEXT);
            if (dk == 'f') { r[c] = f1(t, sk == 's' ? VA_S32_TO_F32 : VA_U32_TO_F32, v); continue; }
            if (sat && db < 32) {
                int64_t lo = dk == 's' ? -(1ll << (db - 1)) : 0, hi = dk == 's' ? (1ll << (db - 1)) - 1 : (1ll << db) - 1;
                enum va_op cs = sk == 's' ? VA_CSEL_S32 : VA_CSEL_U32;
                if (sk == 's') v = sel_csel(t, VA_CMPF_M_LT, cs, v, vi_imm((uint32_t)lo), vi_imm((uint32_t)lo), v);
                v = sel_csel(t, VA_CMPF_M_GT, cs, v, vi_imm((uint32_t)hi), vi_imm((uint32_t)hi), v);
            }
            r[c] = v;
        }
    }
    if (dk == 'f') return f32_result(t, db, x->ncomp, r);
    return sv_from_comps32(t, db, x->ncomp, r);
}
