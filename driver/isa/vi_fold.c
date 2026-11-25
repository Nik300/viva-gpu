// Viva ISA compiler: constant folding, 16-bit lane peepholes and branch folding on the Valhall IR (before RA).
//
// What NIR's constant folding and nir_opt_algebraic give the Mesa path, done on the machine IR (the ISA path has no
// intermediate language). Measured on CoreAnimation's iOS shaders on the phone: ~40% of the instructions were moves
// of 16-bit lanes (U16_TO_U32 to extract a half, MKVEC to put halves back together, F16_TO_F32 + V2F32_TO_V2F16
// round trips of half vectors), and branches on conditions that are constant once the function constants are known.
//
// - Constant folding: an instruction whose sources are all constants (immediates, or registers defined once by a
//   constant move) becomes `MOV.i32 d = #value`, which copy propagation then forwards.
// - Lanes: a source read through one 16-bit lane (MKVEC lane0/lane1, F16_TO_F32/U16_TO_U32/... lane0) reads the
//   original register's lane instead of an extracted copy (U16_TO_U32 x.hL, or a lane of an MKVEC). Packed v2f16
//   ALU sources built by MKVEC from the two halves of one word take that word with a swizzle.
// - Round trips: V2F32_TO_V2F16(F16_TO_F32 x.ha, F16_TO_F32 y.hb) = MKVEC(x.ha, y.hb) (exact); MKVEC(x.h0, x.h1) = x.
// - Branches on constants become jumps (or disappear); blocks no longer reachable lose their code and edges, so
//   phi registers written only on the surviving path become ordinary values.
// VMG_ISA_NO_FOLD=1 turns all of this off (A/B on the device).
#include "vi.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "util/half_float.h"
#include "util/macros.h"

bool vi_fold_disabled(void)
{
    static int off = -1;
    if (off < 0) off = getenv("VMG_ISA_NO_FOLD") != NULL;
    return off;
}

// ---- Definitions per register word -------------------------------------------------------------------------------------

typedef struct { unsigned *base; unsigned *ndef; vi_instr **def; unsigned nvregs; } defmap;

static void defmap_build(vi_shader *s, defmap *m)
{
    unsigned n = vi_num_vregs(s), total = 0;
    m->nvregs = n;
    m->base = malloc((n + 1) * sizeof *m->base);
    for (unsigned v = 0; v < n; v++) { m->base[v] = total; total += vi_vreg_get(s, v)->nwords; }
    m->base[n] = total;
    m->ndef = calloc(total ? total : 1, sizeof *m->ndef);
    m->def = calloc(total ? total : 1, sizeof *m->def);
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        vi_ref *w[2] = { &I->dest, &I->sw };
        for (unsigned k = 0; k < 2; k++) {
            if (w[k]->kind != VI_VREG || w[k]->value >= n) continue;
            unsigned cnt = w[k]->count ? w[k]->count : 1;
            for (unsigned q = 0; q < cnt; q++) {
                unsigned idx = m->base[w[k]->value] + w[k]->word + q;
                if (idx >= total) continue;
                m->ndef[idx]++; m->def[idx] = I;
            }
        }
    }
}

static void defmap_free(defmap *m) { free(m->base); free(m->ndef); free(m->def); }

// A word whose value is the same wherever it is read: defined once, not a phi variable, not precoloured.
static bool stable(vi_shader *s, defmap *m, vi_ref r)
{
    if (r.kind == VI_IMM || r.kind == VI_FAU || r.kind == VI_SPECIAL) return true;
    if (r.kind != VI_VREG || r.value >= m->nvregs) return false;
    vi_vreg_info *info = vi_vreg_get(s, r.value);
    if (info->multi_def || info->fixed >= 0) return false;
    return m->ndef[m->base[r.value] + r.word] == 1;
}

// The single instruction writing exactly this one-word source (dest, one word, no partial write), or NULL.
static vi_instr *def_of(vi_shader *s, defmap *m, vi_ref r)
{
    if (r.kind != VI_VREG || (r.count && r.count != 1) || !stable(s, m, r)) return NULL;
    vi_instr *D = m->def[m->base[r.value] + r.word];
    if (!D || D->dest.kind != VI_VREG || D->dest.value != r.value || D->dest.word != r.word) return NULL;
    if ((D->dest.count && D->dest.count != 1) || D->f.set[VAF_dest_width] || D->flow || D->target) return NULL;
    return D;
}

// Fields set on I other than `allowed` (list ended by VAF_COUNT).
static bool only_fields(const vi_instr *I, const enum va_field *allowed)
{
    for (unsigned f = 0; f < VAF_COUNT; f++) {
        if (!I->f.set[f]) continue;
        bool ok = false;
        for (const enum va_field *a = allowed; *a != VAF_COUNT; a++) if (*a == (enum va_field)f) { ok = true; break; }
        if (!ok) return false;
    }
    return true;
}

static int64_t fval(const vi_instr *I, enum va_field f, int64_t dflt) { return I->f.set[f] ? I->f.v[f] : dflt; }

// Constant value of a source: an immediate or a register defined once by a constant move.
static bool cval(vi_shader *s, defmap *m, vi_ref r, uint32_t *x)
{
    if (r.kind == VI_IMM) { *x = r.value; return true; }
    vi_instr *D = def_of(s, m, r);
    if (!D) return false;
    static const enum va_field none[] = { VAF_COUNT };
    static const enum va_field imm[] = { VAF_imm1w, VAF_COUNT };
    if (D->op == VA_MOV_IMM_I32 && only_fields(D, imm)) { *x = (uint32_t)D->f.v[VAF_imm1w]; return true; }
    if (D->op == VA_MOV_I32 && D->src[0].kind == VI_IMM && only_fields(D, none)) { *x = D->src[0].value; return true; }
    return false;
}

static void make_mov(vi_instr *I, vi_ref src)
{
    vi_ref d = I->dest;
    I->op = VA_MOV_I32;
    va_vals_init(&I->f);
    for (unsigned k = 0; k < 4; k++) I->src[k] = vi_none();
    src.last = false;
    if (src.kind == VI_VREG) src.count = 1;
    I->src[0] = src;
    I->dest = d;
}

// ---- Constant folding -------------------------------------------------------------------------------------------------

static float f32(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static uint32_t u32(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

static bool normal_or_zero(float f) { return f == 0.0f || isnormal(f); }

static float clampf(float x, int64_t c)
{
    switch (c) {
    case VA_CLAMP_M_CLAMP_0_INF: return x < 0 ? 0 : x;
    case VA_CLAMP_M_CLAMP_M1_1: return x < -1 ? -1 : x > 1 ? 1 : x;
    case VA_CLAMP_M_CLAMP_0_1: return x < 0 ? 0 : x > 1 ? 1 : x;
    default: return x;
    }
}

static uint16_t lane16(uint32_t w, unsigned lane) { return (uint16_t)(w >> (16 * (lane & 1))); }

// v2f16 source k after its swizzle (h01 = identity when unset).
static void swz_lanes(const vi_instr *I, unsigned k, uint32_t w, uint16_t out[2])
{
    static const enum va_field swz[3] = { VAF_swz0, VAF_swz1, VAF_swz2 };
    int64_t s = fval(I, swz[k], VA_SWIZ_M_H01);
    static const uint8_t sel[4][2] = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } };
    out[0] = lane16(w, sel[s & 3][0]);
    out[1] = lane16(w, sel[s & 3][1]);
}

// Value of an all-constant instruction; false when it is not foldable.
static bool fold_value(vi_shader *s, defmap *m, vi_instr *I, uint32_t *out)
{
    uint32_t a = 0, b = 0, c = 0;
    bool ha = I->src[0].kind != VI_NONE, hb = I->src[1].kind != VI_NONE, hc = I->src[2].kind != VI_NONE;
    if (I->src[3].kind != VI_NONE || I->sr.kind || I->sw.kind) return false;
    if ((ha && !cval(s, m, I->src[0], &a)) || (hb && !cval(s, m, I->src[1], &b)) || (hc && !cval(s, m, I->src[2], &c))) return false;
    switch (I->op) {
    case VA_MKVEC_V2I16: {
        static const enum va_field ok[] = { VAF_lane0, VAF_lane1, VAF_COUNT };
        if (!only_fields(I, ok) || !ha || !hb) return false;
        *out = lane16(a, (unsigned)fval(I, VAF_lane0, 0)) | (uint32_t)lane16(b, (unsigned)fval(I, VAF_lane1, 0)) << 16;
        return true;
    }
    case VA_U16_TO_U32: case VA_S16_TO_S32: case VA_F16_TO_F32: {
        static const enum va_field ok[] = { VAF_lane0, VAF_COUNT };
        if (!only_fields(I, ok) || !ha) return false;
        uint16_t h = lane16(a, (unsigned)fval(I, VAF_lane0, 0));
        if (I->op == VA_U16_TO_U32) *out = h;
        else if (I->op == VA_S16_TO_S32) *out = (uint32_t)(int32_t)(int16_t)h;
        else {
            float f = _mesa_half_to_float(h);
            if (!normal_or_zero(f)) return false;
            *out = u32(f);
        }
        return true;
    }
    case VA_V2F32_TO_V2F16: {
        static const enum va_field ok[] = { VAF_COUNT };
        if (!only_fields(I, ok) || !ha || !hb) return false;
        float x = f32(a), y = f32(b);
        if (!normal_or_zero(x) || !normal_or_zero(y)) return false;
        uint16_t hx = _mesa_float_to_half(x), hy = _mesa_float_to_half(y);
        if (!normal_or_zero(_mesa_half_to_float(hx)) || !normal_or_zero(_mesa_half_to_float(hy))) return false;
        *out = hx | (uint32_t)hy << 16;
        return true;
    }
    case VA_AND_I32: case VA_OR_I32: case VA_XOR_I32:
    case VA_LSHIFT_OR_I32: case VA_RSHIFT_OR_I32: case VA_LSHIFT_AND_I32: case VA_RSHIFT_AND_I32: case VA_LSHIFT_XOR_I32: {
        static const enum va_field ok[] = { VAF_not_result, VAF_not2, VAF_lanes1, VAF_COUNT };
        if (!only_fields(I, ok) || fval(I, VAF_lanes1, 0) != 0 || !ha || !hc) return false;
        uint32_t sh = hb ? b : 0;
        if (sh > 31) return false;
        uint32_t x = I->op == VA_RSHIFT_OR_I32 || I->op == VA_RSHIFT_AND_I32 ? a >> sh : a << sh;
        uint32_t y = fval(I, VAF_not2, 0) ? ~c : c;
        uint32_t r = I->op == VA_AND_I32 || I->op == VA_LSHIFT_AND_I32 || I->op == VA_RSHIFT_AND_I32 ? x & y
                   : I->op == VA_XOR_I32 || I->op == VA_LSHIFT_XOR_I32 ? x ^ y : x | y;
        *out = fval(I, VAF_not_result, 0) ? ~r : r;
        return true;
    }
    case VA_IADD_U32: case VA_IADD_S32: case VA_ISUB_U32: case VA_ISUB_S32: {
        static const enum va_field ok[] = { VAF_COUNT };
        if (!only_fields(I, ok) || !ha || !hb) return false;
        *out = I->op == VA_IADD_U32 || I->op == VA_IADD_S32 ? a + b : a - b;
        return true;
    }
    case VA_FADD_F32: case VA_FMUL_F32: case VA_FMIN_F32: case VA_FMAX_F32: {
        static const enum va_field ok[] = { VAF_clamp, VAF_COUNT };
        if (!only_fields(I, ok) || !ha || !hb) return false;
        float x = f32(a), y = f32(b), r;
        if (!normal_or_zero(x) || !normal_or_zero(y)) return false;
        r = I->op == VA_FADD_F32 ? x + y : I->op == VA_FMUL_F32 ? x * y : I->op == VA_FMIN_F32 ? fminf(x, y) : fmaxf(x, y);
        r = clampf(r, fval(I, VAF_clamp, 0));
        if (!normal_or_zero(r)) return false;
        *out = u32(r);
        return true;
    }
    case VA_FADD_V2F16: case VA_FMUL_V2F16: case VA_FMIN_V2F16: case VA_FMAX_V2F16: {
        static const enum va_field ok[] = { VAF_clamp, VAF_swz0, VAF_swz1, VAF_COUNT };
        if (!only_fields(I, ok) || !ha || !hb) return false;
        uint16_t la[2], lb[2], r16[2];
        swz_lanes(I, 0, a, la); swz_lanes(I, 1, b, lb);
        for (unsigned q = 0; q < 2; q++) {
            float x = _mesa_half_to_float(la[q]), y = _mesa_half_to_float(lb[q]), r;
            if (!normal_or_zero(x) || !normal_or_zero(y)) return false;
            r = I->op == VA_FADD_V2F16 ? x + y : I->op == VA_FMUL_V2F16 ? x * y : I->op == VA_FMIN_V2F16 ? fminf(x, y) : fmaxf(x, y);
            r = clampf(r, fval(I, VAF_clamp, 0));
            r16[q] = _mesa_float_to_half(r);
            if (!normal_or_zero(_mesa_half_to_float(r16[q]))) return false;
        }
        *out = r16[0] | (uint32_t)r16[1] << 16;
        return true;
    }
    default:
        return false;
    }
}

// ---- 16-bit lane peepholes --------------------------------------------------------------------------------------------

// Instructions reading a single 16-bit lane of source 0 through lane0 (h0/h1).
static bool lane0_reader(enum va_op op)
{
    return op == VA_U16_TO_U32 || op == VA_S16_TO_S32 || op == VA_F16_TO_F32 || op == VA_U16_TO_F32 || op == VA_S16_TO_F32 ||
           op == VA_F16_TO_S32 || op == VA_F16_TO_U32 || op == VA_FRCP_F16 || op == VA_FRSQ_F16;
}

static bool v2f16_alu(enum va_op op)
{
    return op == VA_FADD_V2F16 || op == VA_FMUL_V2F16 || op == VA_FMA_V2F16 || op == VA_FMIN_V2F16 || op == VA_FMAX_V2F16;
}

// Where lane `lane` of source r really comes from: through U16_TO_U32 x.hL (lane 0 only: its high half is zero) and
// MKVEC lanes. On success *x/*xl are the original source and its lane.
static bool lane_origin(vi_shader *s, defmap *m, vi_ref r, unsigned lane, vi_ref *x, unsigned *xl)
{
    vi_instr *D = def_of(s, m, r);
    if (!D) return false;
    static const enum va_field l0[] = { VAF_lane0, VAF_COUNT };
    static const enum va_field l01[] = { VAF_lane0, VAF_lane1, VAF_COUNT };
    vi_ref src;
    unsigned sl;
    static const enum va_field nf[] = { VAF_COUNT };
    uint32_t c1, c2;
    if (D->op == VA_U16_TO_U32 && lane == 0 && only_fields(D, l0)) { src = D->src[0]; sl = (unsigned)fval(D, VAF_lane0, 0); }
    else if ((D->op == VA_RSHIFT_OR_I32 || D->op == VA_LSHIFT_OR_I32) && only_fields(D, nf) && cval(s, m, D->src[1], &c1) && c1 == 16 &&
             cval(s, m, D->src[2], &c2) && c2 == 0) {
        // x >> 16: lane 0 = x.h1, lane 1 = 0; x << 16: lane 0 = 0, lane 1 = x.h0
        bool right = D->op == VA_RSHIFT_OR_I32;
        if ((right && lane == 1) || (!right && lane == 0)) { *x = vi_imm(0); *xl = 0; return true; }
        src = D->src[0]; sl = right ? 1 : 0;
    }
    else if (D->op == VA_MKVEC_V2I16 && only_fields(D, l01)) {
        src = D->src[lane]; sl = (unsigned)fval(D, lane ? VAF_lane1 : VAF_lane0, 0);
    } else return false;
    if (src.kind == VI_NONE || !stable(s, m, src)) return false;
    if (src.kind == VI_VREG && src.count > 1) return false;
    if (src.kind == VI_SPECIAL) return false;
    *x = src; x->last = false; if (x->kind == VI_VREG) x->count = 1;
    *xl = sl & 1;
    return true;
}

static bool same_word(vi_ref a, vi_ref b)
{
    return a.kind == b.kind && a.value == b.value && (a.kind != VI_VREG || a.word == b.word);
}

static vi_ref imm_lane(vi_ref x, unsigned lane)
{
    // an immediate's lane as an immediate read through lane h0
    return vi_imm(lane16(x.value, lane));
}

static bool peephole(vi_shader *s, defmap *m, vi_instr *I)
{
    if (I->flow || I->target || I->dest.kind != VI_VREG || I->f.set[VAF_dest_width]) return false;
    bool progress = false;
    vi_ref x;
    unsigned xl;

    // MKVEC lanes read through extracts / other MKVECs
    if (I->op == VA_MKVEC_V2I16) {
        static const enum va_field l01[] = { VAF_lane0, VAF_lane1, VAF_COUNT };
        if (!only_fields(I, l01)) return false;
        for (unsigned k = 0; k < 2; k++) {
            enum va_field lf = k ? VAF_lane1 : VAF_lane0;
            unsigned lane = (unsigned)fval(I, lf, 0);
            if (!lane_origin(s, m, I->src[k], lane, &x, &xl)) continue;
            if (x.kind == VI_IMM) { I->src[k] = imm_lane(x, xl); va_set(&I->f, lf, 0); }
            else { I->src[k] = x; va_set(&I->f, lf, xl); }
            progress = true;
        }
        // MKVEC(x.h0, x.h1) = x
        if (same_word(I->src[0], I->src[1]) && I->src[0].kind != VI_IMM && fval(I, VAF_lane0, 0) == 0 && fval(I, VAF_lane1, 0) == 1) {
            make_mov(I, I->src[0]);
            return true;
        }
        return progress;
    }

    // single-lane readers
    if (lane0_reader(I->op)) {
        static const enum va_field l0[] = { VAF_lane0, VAF_COUNT };
        if (!only_fields(I, l0)) return false;
        unsigned lane = (unsigned)fval(I, VAF_lane0, 0);
        if (lane_origin(s, m, I->src[0], lane, &x, &xl) && x.kind != VI_IMM) {
            I->src[0] = x; va_set(&I->f, VAF_lane0, xl);
            return true;
        }
        return false;
    }

    // V2F32_TO_V2F16(F16_TO_F32 x.ha, F16_TO_F32 y.hb) = MKVEC(x.ha, y.hb)
    if (I->op == VA_V2F32_TO_V2F16) {
        static const enum va_field none[] = { VAF_COUNT };
        static const enum va_field l0[] = { VAF_lane0, VAF_COUNT };
        if (!only_fields(I, none)) return false;
        vi_instr *P = def_of(s, m, I->src[0]), *Q = def_of(s, m, I->src[1]);
        if (!P || !Q || P->op != VA_F16_TO_F32 || Q->op != VA_F16_TO_F32 || !only_fields(P, l0) || !only_fields(Q, l0)) return false;
        if (!stable(s, m, P->src[0]) || !stable(s, m, Q->src[0]) || P->src[0].kind == VI_SPECIAL || Q->src[0].kind == VI_SPECIAL) return false;
        vi_ref a = P->src[0], b = Q->src[0];
        unsigned la = (unsigned)fval(P, VAF_lane0, 0), lb = (unsigned)fval(Q, VAF_lane0, 0);
        vi_ref d = I->dest;
        I->op = VA_MKVEC_V2I16;
        va_vals_init(&I->f);
        a.last = b.last = false;
        if (a.kind == VI_VREG) a.count = 1;
        if (b.kind == VI_VREG) b.count = 1;
        if (a.kind == VI_IMM) { a = imm_lane(a, la); la = 0; }
        if (b.kind == VI_IMM) { b = imm_lane(b, lb); lb = 0; }
        I->src[0] = a; I->src[1] = b; I->src[2] = I->src[3] = vi_none();
        va_set(&I->f, VAF_lane0, la); va_set(&I->f, VAF_lane1, lb);
        I->dest = d;
        return true;
    }

    // packed half ALU: a source built from the two halves of one word is that word with a swizzle
    if (v2f16_alu(I->op)) {
        static const enum va_field swz[3] = { VAF_swz0, VAF_swz1, VAF_swz2 };
        static const uint8_t sel[4][2] = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } };
        for (unsigned k = 0; k < 3; k++) {
            if (I->src[k].kind != VI_VREG || !va_has_field(I->op, swz[k])) continue;
            int64_t sw = fval(I, swz[k], VA_SWIZ_M_H01);
            unsigned want[2] = { sel[sw & 3][0], sel[sw & 3][1] };
            vi_ref o[2];
            unsigned ol[2];
            bool ok = true;
            for (unsigned q = 0; q < 2 && ok; q++) ok = lane_origin(s, m, I->src[k], want[q], &o[q], &ol[q]);
            if (!ok || !same_word(o[0], o[1]) || o[0].kind == VI_IMM) continue;
            unsigned ns = ol[0] == 0 ? (ol[1] == 0 ? VA_SWIZ_M_H00 : VA_SWIZ_M_H01) : (ol[1] == 0 ? VA_SWIZ_M_H10 : VA_SWIZ_M_H11);
            I->src[k] = o[0];
            va_set(&I->f, swz[k], ns);
            progress = true;
        }
        return progress;
    }
    return false;
}

// ---- 8-bit lanes, zero extensions, identities, constant compares ------------------------------------------------------
// RenderBox's enums (uchar) arrive as `MKVEC.v2i8 x.b0, #0, #0` (zero extension) + `MKVEC.v2i16 .h0, #0` + `U8_TO_U32
// .b0`: three instructions for one AND. Byte readers read the original byte; extensions of values whose upper bits are
// already zero become copies. Float identities that hold for every input (x + -0, x * 1 + -0), CSELs whose arms are
// the same value or whose comparison is constant, compares and conversions of constants.

// Where byte `byte` of source r comes from (through MKVEC.v2i8 / v2i16, U8/U16_TO_U32); a constant byte as *imm.
static bool byte_origin(vi_shader *s, defmap *m, vi_ref r, unsigned byte, vi_ref *x, unsigned *xb, int depth)
{
    if (r.kind == VI_IMM) { *x = vi_imm((r.value >> (8 * byte)) & 0xff); *xb = 0; return true; }
    vi_instr *D = def_of(s, m, r);
    if (!D || depth > 4) return false;
    static const enum va_field l0[] = { VAF_lane0, VAF_COUNT };
    static const enum va_field l01[] = { VAF_lane0, VAF_lane1, VAF_COUNT };
    vi_ref src;
    unsigned sb;
    if (D->op == VA_MKVEC_V2I8 && only_fields(D, l01)) {
        if (byte == 0) { src = D->src[0]; sb = (unsigned)fval(D, VAF_lane0, 0) & 3; }
        else if (byte == 1) { src = D->src[1]; sb = (unsigned)fval(D, VAF_lane1, 0) & 3; }
        else { src = D->src[2]; sb = byte - 2; }
    } else if (D->op == VA_MKVEC_V2I16 && only_fields(D, l01)) {
        unsigned k = byte / 2;
        src = D->src[k]; sb = 2 * ((unsigned)fval(D, k ? VAF_lane1 : VAF_lane0, 0) & 1) + (byte & 1);
    } else if (D->op == VA_U16_TO_U32 && only_fields(D, l0)) {
        if (byte >= 2) { *x = vi_imm(0); *xb = 0; return true; }
        src = D->src[0]; sb = 2 * ((unsigned)fval(D, VAF_lane0, 0) & 1) + byte;
    } else if (D->op == VA_U8_TO_U32 && only_fields(D, l0)) {
        if (byte >= 1) { *x = vi_imm(0); *xb = 0; return true; }
        src = D->src[0]; sb = (unsigned)fval(D, VAF_lane0, 0) & 3;
    } else return false;
    if (src.kind == VI_NONE || src.kind == VI_SPECIAL || !stable(s, m, src) || (src.kind == VI_VREG && src.count > 1)) return false;
    if (src.kind == VI_IMM) { *x = vi_imm((src.value >> (8 * sb)) & 0xff); *xb = 0; return true; }
    vi_ref deeper; unsigned db;
    if (byte_origin(s, m, src, sb, &deeper, &db, depth + 1)) { *x = deeper; *xb = db; return true; }
    *x = src; x->last = false; if (x->kind == VI_VREG) x->count = 1;
    *xb = sb;
    return true;
}

// Number of high bits known to be zero (0, 16 or 24).
static unsigned zero_high(vi_shader *s, defmap *m, vi_ref r)
{
    if (r.kind == VI_IMM) return r.value <= 0xff ? 24 : r.value <= 0xffff ? 16 : 0;
    vi_instr *D = def_of(s, m, r);
    if (!D) return 0;
    uint32_t c, c2;
    static const enum va_field l0[] = { VAF_lane0, VAF_COUNT };
    static const enum va_field l01[] = { VAF_lane0, VAF_lane1, VAF_COUNT };
    switch (D->op) {
    case VA_U8_TO_U32: return only_fields(D, l0) ? 24 : 0;
    case VA_U16_TO_U32: return only_fields(D, l0) ? 16 : 0;
    case VA_MKVEC_V2I8:
        if (!only_fields(D, l01) || !cval(s, m, D->src[2], &c) || (c & 0xffff)) return 0;
        return cval(s, m, D->src[1], &c2) && ((c2 >> (8 * (fval(D, VAF_lane1, 0) & 3))) & 0xff) == 0 ? 24 : 16;
    case VA_MKVEC_V2I16:
        if (!only_fields(D, l01) || !cval(s, m, D->src[1], &c)) return 0;
        return lane16(c, (unsigned)fval(D, VAF_lane1, 0)) == 0 ? 16 : 0;
    case VA_RSHIFT_OR_I32: {
        static const enum va_field nf[] = { VAF_COUNT };
        if (!only_fields(D, nf) || !cval(s, m, D->src[1], &c) || c > 31 || !cval(s, m, D->src[2], &c2) || c2 != 0) return 0;
        unsigned z = c + (D->src[0].kind == VI_VREG ? (D->src[0].value != r.value ? zero_high(s, m, D->src[0]) : 0) : 0);
        return z >= 24 ? 24 : z >= 16 ? 16 : 0;
    }
    case VA_AND_I32: case VA_LSHIFT_AND_I32: case VA_RSHIFT_AND_I32: {
        static const enum va_field ok[] = { VAF_lanes1, VAF_COUNT };
        if (!only_fields(D, ok) || fval(D, VAF_lanes1, 0) != 0 || !cval(s, m, D->src[2], &c)) return 0;
        if (D->op != VA_AND_I32 && D->op != VA_RSHIFT_AND_I32 && !(D->src[1].kind == VI_NONE || (cval(s, m, D->src[1], &c2) && c2 == 0))) return 0;
        return c <= 0xff ? 24 : c <= 0xffff ? 16 : 0;
    }
    default: return 0;
    }
}

static bool cmp_const(int cmpf, int kind, uint32_t a, uint32_t b, bool *res)
{
    // kind: 0 unsigned, 1 signed, 2 float
    if (kind == 2) {
        float x = f32(a), y = f32(b);
        if (!normal_or_zero(x) || !normal_or_zero(y)) return false;
        switch (cmpf) {
        case VA_CMPF_M_EQ: *res = x == y; return true;
        case VA_CMPF_M_NE: *res = x != y; return true;
        case VA_CMPF_M_GT: *res = x > y; return true;
        case VA_CMPF_M_GE: *res = x >= y; return true;
        case VA_CMPF_M_LT: *res = x < y; return true;
        case VA_CMPF_M_LE: *res = x <= y; return true;
        default: return false;
        }
    }
    int64_t x = kind ? (int64_t)(int32_t)a : (int64_t)a, y = kind ? (int64_t)(int32_t)b : (int64_t)b;
    switch (cmpf) {
    case VA_CMPF_M_EQ: *res = x == y; return true;
    case VA_CMPF_M_NE: *res = x != y; return true;
    case VA_CMPF_M_GT: *res = x > y; return true;
    case VA_CMPF_M_GE: *res = x >= y; return true;
    case VA_CMPF_M_LT: *res = x < y; return true;
    case VA_CMPF_M_LE: *res = x <= y; return true;
    default: return false;
    }
}

static int csel_kind(enum va_op op)
{
    switch (op) {
    case VA_CSEL_U32: return 0;
    case VA_CSEL_S32: return 1;
    case VA_CSEL_F32: return 2;
    default: return -1;
    }
}

static bool byte_reader(enum va_op op)
{
    return op == VA_U8_TO_U32 || op == VA_S8_TO_S32 || op == VA_U8_TO_F32 || op == VA_S8_TO_F32;
}

static bool more_peepholes(vi_shader *s, defmap *m, vi_instr *I)
{
    if (I->flow || I->target || I->dest.kind != VI_VREG || I->f.set[VAF_dest_width] || I->sw.kind) return false;
    static const enum va_field none[] = { VAF_COUNT };
    static const enum va_field l0[] = { VAF_lane0, VAF_COUNT };
    static const enum va_field l01[] = { VAF_lane0, VAF_lane1, VAF_COUNT };
    uint32_t a, b;
    vi_ref x;
    unsigned xb;

    // single-byte readers: the original byte
    if (byte_reader(I->op) && only_fields(I, l0)) {
        unsigned lane = (unsigned)fval(I, VAF_lane0, 0) & 3;
        if (I->op == VA_U8_TO_U32 && lane == 0 && zero_high(s, m, I->src[0]) >= 24) { make_mov(I, I->src[0]); return true; }
        if (byte_origin(s, m, I->src[0], lane, &x, &xb, 0) && !same_word(x, I->src[0])) {
            if (x.kind == VI_IMM) { uint32_t v = x.value; bool sg = I->op == VA_S8_TO_S32 || I->op == VA_S8_TO_F32;
                if (I->op == VA_U8_TO_U32 || I->op == VA_S8_TO_S32) { make_mov(I, vi_imm(sg ? (uint32_t)(int32_t)(int8_t)v : v)); return true; }
                I->src[0] = vi_imm(v); va_set(&I->f, VAF_lane0, 0); return true; }
            I->src[0] = x; va_set(&I->f, VAF_lane0, xb);
            return true;
        }
        return false;
    }
    if (I->op == VA_U16_TO_U32 && only_fields(I, l0) && fval(I, VAF_lane0, 0) == 0 && zero_high(s, m, I->src[0]) >= 16) {
        make_mov(I, I->src[0]);
        return true;
    }
    // MKVEC.v2i8: byte sources read through other extensions; a zero extension of a byte that is already one
    if (I->op == VA_MKVEC_V2I8 && only_fields(I, l01)) {
        bool progress = false;
        for (unsigned k = 0; k < 2; k++) {
            enum va_field lf = k ? VAF_lane1 : VAF_lane0;
            unsigned lane = (unsigned)fval(I, lf, 0) & 3;
            if (!byte_origin(s, m, I->src[k], lane, &x, &xb, 0) || same_word(x, I->src[k])) continue;
            if (x.kind == VI_IMM) { I->src[k] = x; va_set(&I->f, lf, 0); }
            else { I->src[k] = x; va_set(&I->f, lf, xb); }
            progress = true;
        }
        if (fval(I, VAF_lane0, 0) == 0 && cval(s, m, I->src[1], &a) && cval(s, m, I->src[2], &b) &&
            ((a >> (8 * (fval(I, VAF_lane1, 0) & 3))) & 0xff) == 0 && (b & 0xffff) == 0 && zero_high(s, m, I->src[0]) >= 24) {
            make_mov(I, I->src[0]);
            return true;
        }
        return progress;
    }
    // MKVEC.v2i16(x.h0, #0) of a value whose upper half is zero
    if (I->op == VA_MKVEC_V2I16 && only_fields(I, l01) && fval(I, VAF_lane0, 0) == 0 && cval(s, m, I->src[1], &a) &&
        lane16(a, (unsigned)fval(I, VAF_lane1, 0)) == 0 && I->src[0].kind == VI_VREG && zero_high(s, m, I->src[0]) >= 16) {
        make_mov(I, I->src[0]);
        return true;
    }
    // shifts by 0 combined with 0 (OR / XOR) or ~0 (AND): the value itself
    if (I->op == VA_LSHIFT_OR_I32 || I->op == VA_RSHIFT_OR_I32 || I->op == VA_LSHIFT_XOR_I32 || I->op == VA_RSHIFT_XOR_I32 ||
        I->op == VA_LSHIFT_AND_I32 || I->op == VA_RSHIFT_AND_I32) {
        static const enum va_field nf[] = { VAF_COUNT };
        bool and_ = I->op == VA_LSHIFT_AND_I32 || I->op == VA_RSHIFT_AND_I32;
        if (only_fields(I, nf) && (I->src[1].kind == VI_NONE || (cval(s, m, I->src[1], &a) && a == 0)) && cval(s, m, I->src[2], &b) &&
            b == (and_ ? 0xffffffffu : 0u) && I->src[0].kind != VI_NONE && (I->src[0].kind != VI_VREG || stable(s, m, I->src[0]))) {
            make_mov(I, I->src[0]);
            return true;
        }
    }
    // x + -0 = x; x * 1 + -0 = x (exact for every x, signed zeros and NaNs included)
    if (I->op == VA_FADD_F32 && I->src[0].kind == VI_VREG) {
        static const enum va_field n1[] = { VAF_neg1, VAF_COUNT };
        if (only_fields(I, n1) && cval(s, m, I->src[1], &b) && (fval(I, VAF_neg1, 0) ? b ^ 0x80000000u : b) == 0x80000000u) {
            make_mov(I, I->src[0]);
            return true;
        }
    }
    if (I->op == VA_FMA_F32) {
        static const enum va_field n2[] = { VAF_neg2, VAF_COUNT };
        if (only_fields(I, n2) && cval(s, m, I->src[2], &b) && (fval(I, VAF_neg2, 0) ? b ^ 0x80000000u : b) == 0x80000000u) {
            for (unsigned k = 0; k < 2; k++)
                if (I->src[1 - k].kind == VI_VREG && cval(s, m, I->src[k], &a) && a == 0x3f800000u) { make_mov(I, I->src[1 - k]); return true; }
        }
    }
    // CSEL: both arms the same value; constant comparison
    int ck = csel_kind(I->op);
    if (ck >= 0) {
        static const enum va_field cm[] = { VAF_cmpf, VAF_COUNT };
        if (!only_fields(I, cm)) return false;
        if (same_word(I->src[2], I->src[3]) && (I->src[2].kind != VI_VREG || stable(s, m, I->src[2]))) { make_mov(I, I->src[2]); return true; }
        bool r;
        if (cval(s, m, I->src[0], &a) && cval(s, m, I->src[1], &b) && cmp_const((int)fval(I, VAF_cmpf, 0), ck, a, b, &r)) {
            make_mov(I, r ? I->src[2] : I->src[3]);
            return true;
        }
        return false;
    }
    // compares of constants (0/1 results)
    if (I->op == VA_FCMP_OR_F32 || I->op == VA_ICMP_OR_U32 || I->op == VA_ICMP_OR_S32) {
        static const enum va_field cm[] = { VAF_cmpf, VAF_result_type, VAF_COUNT };
        if (!only_fields(I, cm) || fval(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1) != VA_CMP_RESULT_TYPE_M_I1) return false;
        uint32_t c = 0;
        bool r;
        if (!cval(s, m, I->src[0], &a) || !cval(s, m, I->src[1], &b) || (I->src[2].kind != VI_NONE && !cval(s, m, I->src[2], &c))) return false;
        if (!cmp_const((int)fval(I, VAF_cmpf, 0), I->op == VA_FCMP_OR_F32 ? 2 : I->op == VA_ICMP_OR_S32, a, b, &r)) return false;
        make_mov(I, vi_imm((uint32_t)r | c));
        return true;
    }
    // integer -> float of small constants (exact)
    if ((I->op == VA_S32_TO_F32 || I->op == VA_U32_TO_F32) && only_fields(I, none) && cval(s, m, I->src[0], &a)) {
        int64_t v = I->op == VA_S32_TO_F32 ? (int64_t)(int32_t)a : (int64_t)a;
        if (v < -(1 << 24) || v > (1 << 24)) return false;
        make_mov(I, vi_imm(u32((float)v)));
        return true;
    }
    (void)l0;
    return false;
}

// fabs / fneg feeding a float instruction that has abs/neg modifiers on that source: the modifier instead (Mesa's
// bi_opt_mod_prop). Valhall applies abs before neg.
static bool mod_consumer(enum va_op op)
{
    return op == VA_FADD_F32 || op == VA_FMUL_F32 || op == VA_FMA_F32 || op == VA_FMIN_F32 || op == VA_FMAX_F32 ||
           op == VA_FCMP_F32 || op == VA_FCMP_OR_F32;
}

static bool mod_prop(vi_shader *s, defmap *m, vi_instr *I)
{
    if (!mod_consumer(I->op)) return false;
    static const enum va_field absf[3] = { VAF_abs0, VAF_abs1, VAF_abs2 }, negf[3] = { VAF_neg0, VAF_neg1, VAF_neg2 };
    static const enum va_field widen[3] = { VAF_widen0, VAF_widen1, VAF_widen2 };
    bool progress = false;
    for (unsigned k = 0; k < 3; k++) {
        if (I->src[k].kind != VI_VREG || !va_has_field(I->op, absf[k]) || !va_has_field(I->op, negf[k])) continue;
        if (fval(I, widen[k], 0)) continue;
        vi_instr *D = def_of(s, m, I->src[k]);
        if (!D || (D->op != VA_FABS_F32 && D->op != VA_FNEG_F32)) continue;
        static const enum va_field none[] = { VAF_COUNT };
        if (!only_fields(D, none) || !stable(s, m, D->src[0]) || D->src[0].kind == VI_SPECIAL) continue;
        if (D->src[0].kind == VI_VREG && D->src[0].count > 1) continue;
        vi_ref x = D->src[0];
        x.last = false;
        if (x.kind == VI_VREG) x.count = 1;
        if (D->op == VA_FABS_F32) va_set(&I->f, absf[k], 1);
        else if (!fval(I, absf[k], 0)) va_set(&I->f, negf[k], !fval(I, negf[k], 0));
        I->src[k] = x;
        progress = true;
    }
    return progress;
}

// One round of folding + peepholes over the whole shader; true on progress. Copy propagation and dead code
// elimination (vi_opt.c) clean up after it.
bool vi_fold(vi_shader *s)
{
    if (vi_fold_disabled()) return false;
    defmap m;
    defmap_build(s, &m);
    bool progress = false;
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        if (I->flow || I->target || I->is_nop || I->dest.kind != VI_VREG || I->f.set[VAF_dest_width]) continue;
        if ((I->dest.count && I->dest.count != 1) || I->sw.kind) continue;
        if (I->op == VA_MOV_I32 || I->op == VA_MOV_IMM_I32) continue;
        uint32_t v;
        if (fold_value(s, &m, I, &v)) { make_mov(I, vi_imm(v)); progress = true; continue; }
        // (the def map stays valid: peepholes only change sources and opcodes, never which words are written)
        if (peephole(s, &m, I)) progress = true;
        if (mod_prop(s, &m, I)) progress = true;
        if (I->op != VA_MOV_I32 && more_peepholes(s, &m, I)) progress = true;
    }
    defmap_free(&m);
    return progress;
}

// ---- Branch folding ---------------------------------------------------------------------------------------------------

static void drop_pred(vi_block *b, vi_block *p)
{
    unsigned n = util_dynarray_num_elements(&b->preds, vi_block *);
    vi_block **a = util_dynarray_begin(&b->preds);
    for (unsigned i = 0; i < n; i++) if (a[i] == p) { a[i] = a[n - 1]; util_dynarray_pop(&b->preds, vi_block *); return; }
}

static void drop_succ(vi_block *blk, vi_block *to)
{
    for (unsigned k = 0; k < 2; k++) if (blk->succ[k] == to) { blk->succ[k] = NULL; drop_pred(to, blk); break; }
    if (!blk->succ[0] && blk->succ[1]) { blk->succ[0] = blk->succ[1]; blk->succ[1] = NULL; }
}

// Branches on constants (after copy propagation) become jumps or go away; unreachable blocks are emptied and cut
// from the CFG. True when the CFG changed.
bool vi_fold_branches(vi_shader *s)
{
    if (vi_fold_disabled()) return false;
    bool changed = false;
    defmap m;
    defmap_build(s, &m);
    vi_foreach_block(s, blk) {
        if (list_is_empty(&blk->instrs)) continue;
        vi_instr *I = list_last_entry(&blk->instrs, vi_instr, link);
        if (I->op != VA_BRANCH || !I->target || I->flow) continue;
        static const enum va_field ok[] = { VAF_not, VAF_COUNT };
        if (!only_fields(I, ok)) continue;
        uint32_t c;
        if (!cval(s, &m, I->src[0], &c)) continue;
        bool on_zero = fval(I, VAF_not, 0) != 0;
        if (I->src[0].kind == VI_IMM && c == 0 && on_zero) {
            // already unconditional: just make sure no fallthrough edge is left
            vi_block *other = blk->succ[0] == I->target ? blk->succ[1] : blk->succ[0];
            if (other && other != I->target) { drop_succ(blk, other); changed = true; }
            continue;
        }
        bool taken = on_zero ? c == 0 : c != 0;
        vi_block *target = I->target;
        vi_block *fall = blk->succ[0] == target ? blk->succ[1] : blk->succ[0];
        if (taken) {
            I->src[0] = vi_imm(0);
            va_vals_init(&I->f);
            va_set(&I->f, VAF_not, 1);
            if (fall && fall != target) drop_succ(blk, fall);
        } else {
            list_del(&I->link);
            if (fall != target) drop_succ(blk, target);
        }
        changed = true;
    }
    defmap_free(&m);
    if (!changed) return false;
    // reachability from the entry block
    unsigned maxi = 0;
    vi_foreach_block(s, blk) if (blk->index + 1 > maxi) maxi = blk->index + 1;
    bool *seen = calloc(maxi ? maxi : 1, 1);
    vi_block **stack = malloc((maxi + 1) * sizeof *stack);
    unsigned sp = 0;
    vi_block *entry = list_first_entry(&s->blocks, vi_block, link);
    stack[sp++] = entry; seen[entry->index] = true;
    while (sp) {
        vi_block *b = stack[--sp];
        for (unsigned k = 0; k < 2; k++) if (b->succ[k] && !seen[b->succ[k]->index]) { seen[b->succ[k]->index] = true; stack[sp++] = b->succ[k]; }
    }
    vi_foreach_block(s, blk) {
        if (seen[blk->index]) continue;
        vi_foreach_instr_safe(blk, I) list_del(&I->link);
        for (unsigned k = 0; k < 2; k++) if (blk->succ[k]) { drop_pred(blk->succ[k], blk); blk->succ[k] = NULL; }
        util_dynarray_clear(&blk->preds);
    }
    free(seen); free(stack);
    return true;
}

// After RA: copies onto themselves.
void vi_drop_self_moves(vi_shader *s)
{
    if (vi_fold_disabled()) return;
    vi_foreach_block(s, blk) vi_foreach_instr_safe(blk, I) {
        if (I->op != VA_MOV_I32 || I->flow || I->target || I->is_nop || I->f.set[VAF_dest_width]) continue;
        if (I->dest.kind == VI_REG && I->src[0].kind == VI_REG && I->dest.value == I->src[0].value) list_del(&I->link);
    }
}

// ---- Copies after register allocation ------------------------------------------------------------------------------------
// `MOV d = s` left by RA (words of split message results, phi copies, operands kept apart): within the block, the
// readers of d read s instead while s still holds the value, and the MOV goes away; d must not be live at the end of
// the block unless it is written again first. Whole-register single-word reads only (vector and staging operands
// keep their registers). Liveness: a backward pass over physical registers. VMG_ISA_NO_REGCOPY=1 turns it off.

static uint64_t reg_mask(const vi_ref *r)
{
    if (r->kind != VI_REG) return 0;
    unsigned n = r->count ? r->count : 1;
    uint64_t m = 0;
    for (unsigned w = 0; w < n && r->value + w < 64; w++) m |= 1ull << (r->value + w);
    return m;
}

static uint64_t instr_reads(const vi_instr *I)
{
    return reg_mask(&I->src[0]) | reg_mask(&I->src[1]) | reg_mask(&I->src[2]) | reg_mask(&I->src[3]) | reg_mask(&I->sr);
}

static uint64_t instr_writes(const vi_instr *I) { return reg_mask(&I->dest) | reg_mask(&I->sw) | I->clobber; }

void vi_propagate_reg_copies(vi_shader *s)
{
    if (vi_fold_disabled() || getenv("VMG_ISA_NO_REGCOPY")) return;
    unsigned nb = 0;
    vi_foreach_block(s, b) nb = MAX2(nb, b->index + 1);
    uint64_t *use = calloc(nb + 1, 8), *def = calloc(nb + 1, 8), *in = calloc(nb + 1, 8), *out = calloc(nb + 1, 8);
    vi_foreach_block(s, b) {
        uint64_t u = 0, d = 0;
        vi_foreach_instr(b, I) { u |= instr_reads(I) & ~d; d |= instr_writes(I); }
        use[b->index] = u; def[b->index] = d;
    }
    for (bool changed = true; changed;) {
        changed = false;
        vi_foreach_block_rev(s, b) {
            uint64_t o = 0;
            for (unsigned k = 0; k < 2; k++) if (b->succ[k]) o |= in[b->succ[k]->index];
            uint64_t i = use[b->index] | (o & ~def[b->index]);
            if (o != out[b->index] || i != in[b->index]) { out[b->index] = o; in[b->index] = i; changed = true; }
        }
    }
    vi_foreach_block(s, b) vi_foreach_instr_safe(b, M) {
        if (M->op != VA_MOV_I32 || M->flow || M->target || M->is_nop || M->dest.kind != VI_REG || M->src[0].kind != VI_REG) continue;
        if ((M->dest.count && M->dest.count != 1) || (M->src[0].count && M->src[0].count != 1)) continue;
        bool other = false;
        for (unsigned f = 0; f < VAF_COUNT; f++) if (M->f.set[f]) other = true;
        if (other) continue;
        unsigned dr = M->dest.value, sr = M->src[0].value;
        uint64_t dm = 1ull << dr, sm = 1ull << sr;
        if (dr == sr || (s->reserved_regs & dm) || dr == 48) continue;
        vi_ref *reads[256];
        unsigned nr = 0;
        bool ok = true, s_gone = false, ended = false;
        for (struct list_head *l = M->link.next; l != &b->instrs && ok && !ended; l = l->next) {
            vi_instr *J = list_entry(l, vi_instr, link);
            vi_ref *rs[5] = { &J->src[0], &J->src[1], &J->src[2], &J->src[3], &J->sr };
            for (unsigned k = 0; k < 5 && ok; k++) {
                if (!(reg_mask(rs[k]) & dm)) continue;
                if (s_gone || k == 4 || (rs[k]->count && rs[k]->count != 1) || nr == 256) { ok = false; break; }
                reads[nr++] = rs[k];
            }
            uint64_t w = instr_writes(J);
            if (w & dm) ended = true;
            if (w & sm) s_gone = true;
        }
        if (!ok || (!ended && (out[b->index] & dm))) continue;
        for (unsigned k = 0; k < nr; k++) { reads[k]->value = sr; reads[k]->last = false; }
        list_del(&M->link);
    }
    free(use); free(def); free(in); free(out);
}
