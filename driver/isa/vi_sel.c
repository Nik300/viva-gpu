// Viva ISA compiler: instruction selection driver. AIR (LLVM IR, after vmg_air_module_load) -> Valhall IR (vi.h).
//
// Control flow (A2): LLVM's blocks are laid out in reverse post-order (loops reducible: back edges are the only
// backward jumps), so the hardware's reconvergence at .reconverge points (vi_flow.c) sees structured-enough code.
// A conditional branch becomes BRANCHZ.eq to the false successor plus a fallthrough into the true one; edges that
// carry phi copies, or whose target is not next in the layout, get their own small block. Phis are multi-definition
// registers written on each incoming edge (through temporaries, so phis reading each other see the old values).
// Every `ret` jumps to one exit block where the stage outputs are written (vi_sel_io.c).
#include "vi_sel.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

const char *const vmg_isa_feature_name[VMG_ISA_FEATURE_COUNT] = {
#define VMG_ISA_NAME(id) #id,
    VMG_ISA_FEATURES(VMG_ISA_NAME)
#undef VMG_ISA_NAME
};

bool sel_use(S *t, enum vmg_isa_feature f)
{
    t->used |= 1ull << f;
    if (t->opt->disabled >> f & 1) {
        if (!t->error) t->error = vmg_strdup_printf("feature %s disabled (VMG_ISA_NO_%s / VMG_ISA_ONLY)", vmg_isa_feature_name[f], vmg_isa_feature_name[f]);
        return false;
    }
    return true;
}

// ---- Types ----------------------------------------------------------------------------------------------------------

static bool scalar_info(LLVMTypeRef ty, unsigned *bits, bool *flt)
{
    switch (ts_LLVMGetTypeKind(ty)) {
    case LLVMIntegerTypeKind:
        *bits = ts_LLVMGetIntTypeWidth(ty); *flt = false;
        // odd widths (i3, i24...) live in 32-bit words; operations that care normalize them (sel_int_width)
        if (*bits > 1 && *bits < 32 && *bits != 8 && *bits != 16) *bits = 32;
        return *bits == 1 || *bits == 8 || *bits == 16 || *bits == 32 || *bits == 64;
    case LLVMHalfTypeKind: *bits = 16; *flt = true; return true;
    case LLVMFloatTypeKind: *bits = 32; *flt = true; return true;
    case LLVMDoubleTypeKind: *bits = 64; *flt = true; return true;
    default: return false;
    }
}

bool sel_type_info(LLVMTypeRef ty, unsigned *bits, unsigned *ncomp, bool *flt)
{
    if (ts_LLVMGetTypeKind(ty) == LLVMVectorTypeKind) {
        *ncomp = ts_LLVMGetVectorSize(ty);
        return *ncomp <= 16 && scalar_info(ts_LLVMGetElementType(ty), bits, flt);
    }
    *ncomp = 1;
    return scalar_info(ty, bits, flt);
}

bool sel_is_float(LLVMTypeRef ty) { unsigned b, n; bool f = false; return sel_type_info(ty, &b, &n, &f) && f; }
uint64_t sel_tsize(S *t, LLVMTypeRef ty) { return ts_LLVMABISizeOfType(t->td, ty); }
uint64_t sel_tstore(S *t, LLVMTypeRef ty) { return ts_LLVMStoreSizeOfType(t->td, ty); }

char *sel_name(LLVMValueRef v)
{
    size_t len = 0;
    const char *n = v ? ts_LLVMGetValueName2(v, &len) : NULL;
    return n && len ? strndup(n, len) : NULL;
}

bool sel_name_is(const char *name, const char *prefix) { return name && !strncmp(name, prefix, strlen(prefix)); }

// ---- Values ---------------------------------------------------------------------------------------------------------

unsigned sv_words(unsigned bits, unsigned ncomp)
{
    if (bits == 1) return ncomp;
    return (bits * ncomp + 31) / 32;
}

sv *sv_new(S *t, sv_kind k) { sv *v = rzalloc(t->mem, sv); v->kind = (uint8_t)k; return v; }

sv *sv_val(S *t, unsigned bits, unsigned ncomp)
{
    sv *v = sv_new(t, SV_VAL);
    v->bits = (uint8_t)bits; v->ncomp = (uint8_t)ncomp;
    v->vreg = vi_new_vreg(t->s, sv_words(bits, ncomp));
    return v;
}

sv *sv_const(S *t, unsigned bits, unsigned ncomp, const uint32_t *words)
{
    sv *v = sv_new(t, SV_VAL);
    v->bits = (uint8_t)bits; v->ncomp = (uint8_t)ncomp; v->is_const = true;
    memcpy(v->cw, words, sv_words(bits, ncomp) * 4);
    return v;
}

sv *sv_const32(S *t, uint32_t x) { return sv_const(t, 32, 1, &x); }

vi_ref sv_word(S *t, sv *v, unsigned w)
{
    (void)t;
    if (v->is_const) return vi_imm(v->cw[w]);
    return vi_vreg(v->vreg, w, 1);
}

vi_instr *E(S *t, enum va_op op) { return vi_emit(&t->b, op); }

vi_ref sel_tmp(S *t) { return vi_vreg(vi_new_vreg(t->s, 1), 0, 1); }

vi_ref sel_mov32(S *t, vi_ref x)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I;
    if (x.kind == VI_IMM) { I = E(t, VA_MOV_IMM_I32); vi_set(I, VAF_imm1w, x.value); }
    else { I = E(t, VA_MOV_I32); I->src[0] = x; }
    I->dest = d;
    return d;
}

sv *sv_materialize(S *t, sv *v)
{
    if (v->kind != SV_VAL || !v->is_const) return v;
    sv *r = sv_val(t, v->bits, v->ncomp);
    unsigned n = sv_words(v->bits, v->ncomp);
    for (unsigned w = 0; w < n; w++) {
        vi_instr *I = E(t, VA_MOV_IMM_I32);
        I->dest = vi_vreg(r->vreg, w, 1);
        vi_set(I, VAF_imm1w, v->cw[w]);
    }
    return r;
}

vi_ref sv_vec(S *t, sv *v)
{
    sv *m = sv_materialize(t, v);
    return vi_vreg(m->vreg, 0, sv_words(m->bits, m->ncomp));
}

vi_ref sel_alu2(S *t, enum va_op op, vi_ref a, vi_ref b)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, op);
    I->dest = d; I->src[0] = a; I->src[1] = b;
    return d;
}

vi_ref sel_alu1(S *t, enum va_op op, vi_ref a)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, op);
    I->dest = d; I->src[0] = a;
    return d;
}

vi_ref sel_iadd_imm(S *t, vi_ref a, int32_t imm)
{
    if (!imm && a.kind != VI_IMM) return a;
    if (a.kind == VI_IMM) return vi_imm(a.value + (uint32_t)imm);
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_IADD_IMM_I32);
    I->dest = d; I->src[0] = a; vi_set(I, VAF_imm1w, (uint32_t)imm);
    return d;
}

vi_ref sel_imul_imm(S *t, vi_ref a, uint32_t imm)
{
    if (a.kind == VI_IMM) return vi_imm(a.value * imm);
    if (imm == 1) return a;
    if (imm && !(imm & (imm - 1))) {
        // x << log2(imm): LSHIFT_OR.i32 x, shift, 0
        vi_ref d = sel_tmp(t);
        vi_instr *I = E(t, VA_LSHIFT_OR_I32);
        I->dest = d; I->src[0] = a; I->src[1] = vi_imm((uint32_t)__builtin_ctz(imm)); I->src[2] = vi_imm(0);
        return d;
    }
    return sel_alu2(t, VA_IMUL_U32, a, vi_imm(imm));
}

vi_ref sel_csel(S *t, int cmpf, enum va_op op, vi_ref a, vi_ref b, vi_ref x, vi_ref y)
{
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, op);
    I->dest = d; I->src[0] = a; I->src[1] = b; I->src[2] = x; I->src[3] = y;
    vi_set(I, VAF_cmpf, cmpf);
    return d;
}

// Booleans are 0/1 words; a mask (0 / ~0) for MUX-like uses.
vi_ref sel_bool_to_mask(S *t, vi_ref b) { return sel_alu2(t, VA_ISUB_S32, vi_imm(0), b); }

vi_ref sv_comp32(S *t, sv *v, unsigned c, int how)
{
    if (v->bits == 32 || v->bits == 1) return sv_word(t, v, c);
    if (v->bits == 64) return sv_word(t, v, 2 * c);   // low word (callers handle 64-bit explicitly)
    unsigned w = c * v->bits / 32, lane = (c * v->bits % 32) / v->bits;
    if (v->is_const) {
        uint32_t x = v->cw[w] >> (lane * v->bits);
        if (v->bits == 16) {
            x &= 0xffff;
            if (how == X_F32) { float f = _mesa_half_to_float((uint16_t)x); uint32_t u; memcpy(&u, &f, 4); return vi_imm(u); }
            if (how == X_SEXT) x = (uint32_t)(int32_t)(int16_t)x;
        } else {
            x &= 0xff;
            if (how == X_F32) { float f = (float)x; uint32_t u; memcpy(&u, &f, 4); return vi_imm(u); }
            if (how == X_SEXT) x = (uint32_t)(int32_t)(int8_t)x;
        }
        return vi_imm(x);
    }
    vi_ref src = vi_vreg(v->vreg, w, 1);
    vi_ref d = sel_tmp(t);
    vi_instr *I;
    if (v->bits == 16) {
        I = E(t, how == X_F32 ? VA_F16_TO_F32 : how == X_SEXT ? VA_S16_TO_S32 : VA_U16_TO_U32);
        vi_set(I, VAF_lane0, lane);
    } else {
        I = E(t, how == X_SEXT ? VA_S8_TO_S32 : VA_U8_TO_U32);
        vi_set(I, VAF_lane0, lane);
    }
    I->dest = d; I->src[0] = src;
    return d;
}

sv *sv_from_comps32(S *t, unsigned bits, unsigned ncomp, vi_ref *c32)
{
    bool all_const = true;
    for (unsigned c = 0; c < ncomp; c++) if (c32[c].kind != VI_IMM) all_const = false;
    if (all_const) {
        uint32_t w[16] = {0};
        for (unsigned c = 0; c < ncomp; c++) {
            if (bits == 32 || bits == 1) w[c] = c32[c].value;
            else w[c * bits / 32] |= (c32[c].value & ((1u << bits) - 1)) << (c * bits % 32);
        }
        return sv_const(t, bits, ncomp, w);
    }
    sv *r = sv_val(t, bits, ncomp);
    if (bits == 32 || bits == 1) {
        for (unsigned c = 0; c < ncomp; c++) {
            vi_instr *I = c32[c].kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
            if (c32[c].kind == VI_IMM) vi_set(I, VAF_imm1w, c32[c].value); else I->src[0] = c32[c];
            I->dest = vi_vreg(r->vreg, c, 1);
        }
    } else if (bits == 16) {
        for (unsigned c = 0; c < ncomp; c += 2) {
            vi_instr *I = E(t, VA_MKVEC_V2I16);
            I->dest = vi_vreg(r->vreg, c / 2, 1);
            I->src[0] = c32[c];
            I->src[1] = c + 1 < ncomp ? c32[c + 1] : vi_imm(0);
            vi_set(I, VAF_lane0, 0); vi_set(I, VAF_lane1, 0);
        }
    } else {   // 8-bit: two MKVEC.v2i8 per word: bytes (a, b) over the half of the third source
        for (unsigned c = 0; c < ncomp; c += 4) {
            vi_ref hi = vi_imm(0);
            if (c + 2 < ncomp) {
                vi_ref h = sel_tmp(t);
                vi_instr *I = E(t, VA_MKVEC_V2I8);
                I->dest = h; I->src[0] = c32[c + 2]; I->src[1] = c + 3 < ncomp ? c32[c + 3] : vi_imm(0); I->src[2] = vi_imm(0);
                vi_set(I, VAF_lane0, 0); vi_set(I, VAF_lane1, 0);
                hi = h;
            }
            vi_ref lo = sel_tmp(t);
            vi_instr *I = E(t, VA_MKVEC_V2I8);
            I->dest = lo; I->src[0] = c32[c]; I->src[1] = c + 1 < ncomp ? c32[c + 1] : vi_imm(0); I->src[2] = vi_imm(0);
            vi_set(I, VAF_lane0, 0); vi_set(I, VAF_lane1, 0);
            // word = lo.h0 | hi.h0 << 16
            vi_instr *M = E(t, VA_MKVEC_V2I16);
            M->dest = vi_vreg(r->vreg, c / 4, 1);
            M->src[0] = lo; M->src[1] = hi;
            vi_set(M, VAF_lane0, 0); vi_set(M, VAF_lane1, 0);
        }
    }
    return r;
}

sv *sv_scalar(S *t, sv *v, unsigned c)
{
    if (v->ncomp == 1) return v;
    if (v->bits == 64) {
        if (v->is_const) return sv_const(t, 64, 1, &v->cw[2 * c]);
        sv *r = sv_val(t, 64, 1);
        for (unsigned w = 0; w < 2; w++) { vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(r->vreg, w, 1); I->src[0] = vi_vreg(v->vreg, 2 * c + w, 1); }
        return r;
    }
    if (v->bits == 32 || v->bits == 1) {
        if (v->is_const) return sv_const(t, v->bits, 1, &v->cw[c]);
        sv *r = sv_new(t, SV_VAL);
        // share the register: a 1-word view would need a sub-register; copy instead (cheap, coalesced later)
        r = sv_val(t, v->bits, 1);
        vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(r->vreg, 0, 1); I->src[0] = vi_vreg(v->vreg, c, 1);
        return r;
    }
    vi_ref x = sv_comp32(t, v, c, X_ZEXT);
    return sv_from_comps32(t, v->bits, 1, &x);
}

// ---- Constants ------------------------------------------------------------------------------------------------------

static bool is_undef(LLVMValueRef v) { return ts_LLVMIsUndef(v) || (ts_LLVMIsPoison && ts_LLVMIsPoison(v)); }

static bool scalar_const_bits(S *t, LLVMValueRef c, unsigned bits, bool flt, uint64_t *out)
{
    if (is_undef(c) || ts_LLVMIsAConstantAggregateZero(c)) { *out = 0; return true; }
    if (flt) {
        LLVMBool lost;
        double d = ts_LLVMConstRealGetDouble(c, &lost);
        if (d != d && t->no_nans) { sel_use(t, VMG_ISA_A11); d = 0; }   // fast math: NaN constants are poison
        if (bits == 32) { float f = (float)d; uint32_t u; memcpy(&u, &f, 4); *out = u; }
        else if (bits == 64) memcpy(out, &d, 8);
        else *out = _mesa_float_to_half((float)d);
        return true;
    }
    if (ts_LLVMIsAConstantInt(c)) { *out = ts_LLVMConstIntGetZExtValue(c); return true; }
    return false;
}

static sv *zero_val(S *t, LLVMTypeRef ty);

static sv *constant(S *t, LLVMValueRef c)
{
    LLVMTypeRef ty = ts_LLVMTypeOf(c);
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (ts_LLVMIsAConstantExpr(c)) {
        switch (ts_LLVMGetConstOpcode(c)) {
        case LLVMBitCast: case LLVMAddrSpaceCast: return sel_value(t, ts_LLVMGetOperand(c, 0));
        case LLVMGetElementPtr: return sel_gep(t, c, (unsigned)ts_LLVMGetNumOperands(c));
        default: SFAIL(t, "unsupported constant expression %d", ts_LLVMGetConstOpcode(c));
        }
    }
    if (ts_LLVMIsAGlobalVariable(c) || ts_LLVMIsAFunction(c)) return sel_value(t, c);
    if (is_undef(c) || ts_LLVMIsAConstantAggregateZero(c) || ts_LLVMIsAConstantPointerNull(c)) return zero_val(t, ty);
    if (k == LLVMStructTypeKind || k == LLVMArrayTypeKind) {
        unsigned n = k == LLVMStructTypeKind ? ts_LLVMCountStructElementTypes(ty) : ts_LLVMGetArrayLength(ty);
        sv *a = sv_new(t, SV_AGG);
        a->n = n; a->e = ralloc_array(t->mem, sv *, n ? n : 1);
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef e = ts_LLVMIsAConstantDataSequential(c) ? ts_LLVMGetElementAsConstant(c, i) : ts_LLVMGetOperand(c, i);
            if (!(a->e[i] = constant(t, e))) return NULL;
        }
        return a;
    }
    unsigned bits, n; bool flt;
    if (!sel_type_info(ty, &bits, &n, &flt)) SFAIL(t, "unsupported constant type");
    uint32_t w[32] = {0};
    for (unsigned i = 0; i < n; i++) {
        LLVMValueRef e = k == LLVMVectorTypeKind ? (ts_LLVMIsAConstantDataSequential(c) ? ts_LLVMGetElementAsConstant(c, i) : ts_LLVMGetOperand(c, i)) : c;
        uint64_t x;
        if (!scalar_const_bits(t, e, bits, flt, &x)) SFAIL(t, "unsupported vector constant");
        if (bits == 64) { w[2 * i] = (uint32_t)x; w[2 * i + 1] = (uint32_t)(x >> 32); }
        else if (bits == 32) w[i] = (uint32_t)x;
        else if (bits == 1) w[i] = (uint32_t)(x & 1);
        else w[i * bits / 32] |= (uint32_t)(x & ((1ull << bits) - 1)) << (i * bits % 32);
    }
    return sv_const(t, bits, n, w);
}

static sv *zero_val(S *t, LLVMTypeRef ty)
{
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (k == LLVMStructTypeKind || k == LLVMArrayTypeKind) {
        unsigned n = k == LLVMStructTypeKind ? ts_LLVMCountStructElementTypes(ty) : ts_LLVMGetArrayLength(ty);
        sv *a = sv_new(t, SV_AGG);
        a->n = n; a->e = ralloc_array(t->mem, sv *, n ? n : 1);
        for (unsigned i = 0; i < n; i++) {
            LLVMTypeRef et = k == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(ty, i) : ts_LLVMGetElementType(ty);
            if (!(a->e[i] = zero_val(t, et))) return NULL;
        }
        return a;
    }
    if (k == LLVMPointerTypeKind) {
        sv *p = sv_new(t, SV_PTR);
        p->space = SP_SCRATCH; p->slot = -1; p->off = sv_const32(t, 0);
        return p;
    }
    unsigned bits, n; bool flt;
    if (!sel_type_info(ty, &bits, &n, &flt)) SFAIL(t, "unsupported zero type");
    uint32_t w[32] = {0};
    return sv_const(t, bits, n, w);
}

sv *sel_value(S *t, LLVMValueRef v)
{
    struct hash_entry *he = _mesa_hash_table_search(t->vals, v);
    if (he) return he->data;
    if (ts_LLVMIsAGlobalVariable(v)) return sel_global(t, v);
    if (ts_LLVMIsAConstant(v)) return constant(t, v);
    char *txt = ts_LLVMPrintValueToString(v);
    if (!t->error) t->error = vmg_strdup_printf("value used before its definition: %.120s", txt ? txt : "?");
    ts_LLVMDisposeMessage(txt);
    return NULL;
}

sv *sel_ssa(S *t, LLVMValueRef v)
{
    sv *x = sel_value(t, v);
    if (!x) return NULL;
    if (x->kind != SV_VAL) {
        char *txt = ts_LLVMPrintValueToString(v);
        if (!t->error) t->error = vmg_strdup_printf("expected a scalar or vector value: %.100s", txt ? txt : "?");
        ts_LLVMDisposeMessage(txt);
        return NULL;
    }
    return x;
}

// ---- Aggregates -----------------------------------------------------------------------------------------------------

static sv *extract_value(S *t, sv *a, const unsigned *idx, unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        if (a->kind != SV_AGG || idx[i] >= a->n) SFAIL(t, "extractvalue out of range");
        a = a->e[idx[i]];
    }
    return a;
}

static sv *insert_value(S *t, sv *a, sv *v, const unsigned *idx, unsigned n)
{
    if (!n) return v;
    if (a->kind != SV_AGG || idx[0] >= a->n) SFAIL(t, "insertvalue out of range");
    sv *c = sv_new(t, SV_AGG);
    c->n = a->n; c->e = ralloc_array(t->mem, sv *, a->n);
    memcpy(c->e, a->e, a->n * sizeof(sv *));
    if (!(c->e[idx[0]] = insert_value(t, a->e[idx[0]], v, idx + 1, n - 1))) return NULL;
    return c;
}

// ---- Control flow ---------------------------------------------------------------------------------------------------

static vi_block *block_after(S *t, vi_block *after)
{
    vi_block *b = vi_block_create(t->s);
    list_del(&b->link);
    list_add(&b->link, &after->link);
    return b;
}

static vi_block *block_of(S *t, LLVMBasicBlockRef bb)
{
    struct hash_entry *he = _mesa_hash_table_search(t->blocks, bb);
    return he ? he->data : NULL;
}

static vi_block *next_in_layout(S *t, vi_block *b)
{
    return b->link.next == &t->s->blocks ? NULL : list_entry(b->link.next, vi_block, link);
}

// Unconditional jump: BRANCHZ.eq on the constant zero.
static void jump(S *t, vi_block *from, vi_block *to)
{
    vi_builder save = t->b;
    t->b.block = from; t->b.before = NULL;
    vi_instr *I = E(t, VA_BRANCH);
    I->src[0] = vi_imm(0);
    vi_set(I, VAF_not, 1);
    I->target = to;
    t->b = save;
    vi_block_add_succ(from, to);
}

static bool has_phis(LLVMBasicBlockRef bb)
{
    LLVMValueRef i = ts_LLVMGetFirstInstruction(bb);
    return i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI;
}

// Copies for the phis of `to` on the edge from LLVM block `from`, emitted at the end of vi block `at`.
static bool edge_copies(S *t, LLVMBasicBlockRef from, LLVMBasicBlockRef to, vi_block *at)
{
    vi_builder save = t->b;
    t->b.block = at; t->b.before = NULL;
    struct { sv *phi; sv *tmp; } c[64];
    unsigned n = 0;
    for (LLVMValueRef i = ts_LLVMGetFirstInstruction(to); i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI; i = ts_LLVMGetNextInstruction(i)) {
        struct hash_entry *he = _mesa_hash_table_search(t->phis, i);
        if (!he) continue;
        sv *phi = he->data;
        for (unsigned k = 0; k < ts_LLVMCountIncoming(i); k++) {
            if (ts_LLVMGetIncomingBlock(i, k) != from) continue;
            sv *v = sel_value(t, ts_LLVMGetIncomingValue(i, k));
            if (!v) { t->b = save; return false; }
            if (v->kind == SV_PTR) {
                // pointer: (offset, resource handle)
                vi_ref w2[2] = { sv_word(t, v->off, 0), v->space == SP_SSBO ? sel_ssbo_handle(t, v) : vi_imm(0) };
                v = sv_from_comps32(t, 32, 2, w2);
            }
            if (v->kind != SV_VAL) { t->b = save; SFAILB(t, "phi of a resource"); }
            if (n >= 64) { t->b = save; SFAILB(t, "too many phis"); }
            // through a temporary: another phi of `to` may be read on the same edge
            unsigned words = sv_words(phi->bits, phi->ncomp);
            sv *tmp = sv_val(t, phi->bits, phi->ncomp);
            for (unsigned w = 0; w < words; w++) {
                vi_ref src = sv_word(t, v, w);
                vi_instr *I = src.kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
                if (src.kind == VI_IMM) vi_set(I, VAF_imm1w, src.value); else I->src[0] = src;
                I->dest = vi_vreg(tmp->vreg, w, 1);
            }
            c[n].phi = phi; c[n].tmp = tmp; n++;
            break;
        }
    }
    for (unsigned k = 0; k < n; k++) {
        unsigned words = sv_words(c[k].phi->bits, c[k].phi->ncomp);
        for (unsigned w = 0; w < words; w++) {
            vi_instr *I = E(t, VA_MOV_I32);
            I->dest = vi_vreg(c[k].phi->vreg, w, 1);
            I->src[0] = vi_vreg(c[k].tmp->vreg, w, 1);
        }
    }
    t->b = save;
    return true;
}

// Edge from LLVM block `from` (vi block `at`, whose layout successor is `fall`) to `to`: returns the vi block that
// control should enter (an edge block with the copies, or the target itself).
static vi_block *edge_target(S *t, LLVMBasicBlockRef from, LLVMBasicBlockRef to, vi_block *at, bool conditional)
{
    vi_block *target = block_of(t, to);
    if (!has_phis(to)) return target;
    if (!conditional) {
        if (!edge_copies(t, from, to, at)) return NULL;
        return target;
    }
    vi_block *e = block_after(t, at);
    if (!edge_copies(t, from, to, e)) return NULL;
    jump(t, e, target);
    return e;
}

static bool terminator(S *t, LLVMValueRef term, LLVMBasicBlockRef bb, vi_block *exit)
{
    vi_block *cur = t->b.block;
    switch (ts_LLVMGetInstructionOpcode(term)) {
    case LLVMRet:
        if (t->iret) {
            // return of an inlined visible function: the value into the call's result, then on after the call
            if (ts_LLVMGetNumOperands(term) && t->iret->result) {
                sv *v = sel_ssa(t, ts_LLVMGetOperand(term, 0));
                if (!v) return false;
                sv *r = t->iret->result;
                for (unsigned w = 0; w < sv_words(r->bits, r->ncomp); w++) {
                    vi_ref src = sv_word(t, v, w);
                    vi_instr *I = src.kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
                    if (src.kind == VI_IMM) vi_set(I, VAF_imm1w, src.value); else I->src[0] = src;
                    I->dest = vi_vreg(r->vreg, w, 1);
                }
            }
            jump(t, t->b.block, t->iret->cont);
            return true;
        }
        if (!sel_io_return(t, term)) return false;
        jump(t, t->b.block, exit);
        return true;
    case LLVMUnreachable:
        jump(t, cur, exit);
        return true;
    case LLVMBr: {
        if (!ts_LLVMIsConditional(term)) {
            LLVMBasicBlockRef to = ts_LLVMGetSuccessor(term, 0);
            vi_block *target = edge_target(t, bb, to, cur, false);
            if (!target) return false;
            if (next_in_layout(t, cur) == target) vi_block_add_succ(cur, target);
            else jump(t, cur, target);
            return true;
        }
        sv *c = sel_ssa(t, ts_LLVMGetCondition(term));
        if (!c) return false;
        LLVMBasicBlockRef tb = ts_LLVMGetSuccessor(term, 0), fb = ts_LLVMGetSuccessor(term, 1);
        if (tb == fb) {
            vi_block *target = edge_target(t, bb, tb, cur, false);
            if (!target) return false;
            jump(t, cur, target);
            return true;
        }
        // Fallthrough block for the true edge (placed right after), branch to the false edge.
        vi_block *fall = block_after(t, cur);
        vi_block *ftarget = edge_target(t, bb, fb, fall, true);
        if (!ftarget) return false;
        vi_instr *I = E(t, VA_BRANCH);
        if (c->is_const) I->src[0] = vi_imm(c->cw[0]);
        else I->src[0] = vi_vreg(c->vreg, 0, 1);
        vi_set(I, VAF_not, 1);         // .eq: taken when the condition is false (zero)
        I->target = ftarget;
        vi_block_add_succ(cur, ftarget);
        vi_block_add_succ(cur, fall);
        // true edge: copies in `fall`, then on to the true block unless it follows
        vi_block *ttarget = block_of(t, tb);
        if (has_phis(tb) && !edge_copies(t, bb, tb, fall)) return false;
        if (next_in_layout(t, fall) == ttarget) vi_block_add_succ(fall, ttarget);
        else jump(t, fall, ttarget);
        return true;
    }
    case LLVMSwitch: {
        sv *sel = sel_ssa(t, ts_LLVMGetOperand(term, 0));
        if (!sel) return false;
        unsigned ncases = ts_LLVMGetNumSuccessors(term) - 1;
        vi_block *at = cur;
        for (unsigned k = 0; k < ncases; k++) {
            LLVMValueRef cv = ts_LLVMGetOperand(term, 2 + 2 * k);
            LLVMBasicBlockRef dest = ts_LLVMGetSuccessor(term, k + 1);
            t->b.block = at; t->b.before = NULL;
            vi_ref eq = sel_alu2(t, VA_ICMP_U32, sv_word(t, sel, 0), vi_imm((uint32_t)ts_LLVMConstIntGetZExtValue(cv)));
            vi_instr *cmp = list_last_entry(&at->instrs, vi_instr, link);
            vi_set(cmp, VAF_cmpf, VA_CMPF_M_EQ); vi_set(cmp, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
            vi_block *next = block_after(t, at);
            vi_block *target = edge_target(t, bb, dest, next, true);
            if (!target) return false;
            vi_instr *I = E(t, VA_BRANCH);
            I->src[0] = eq;              // taken when equal (nonzero)
            I->target = target;
            vi_block_add_succ(at, target);
            vi_block_add_succ(at, next);
            at = next;
        }
        t->b.block = at;
        LLVMBasicBlockRef def = ts_LLVMGetSuccessor(term, 0);
        vi_block *target = edge_target(t, bb, def, at, false);
        if (!target) return false;
        jump(t, at, target);
        return true;
    }
    default:
        SFAILB(t, "unsupported terminator %d", ts_LLVMGetInstructionOpcode(term));
    }
}

static unsigned rpo_blocks(S *t, LLVMValueRef fn, LLVMBasicBlockRef **out)
{
    unsigned nblocks = 0;
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(fn); bb; bb = ts_LLVMGetNextBasicBlock(bb)) nblocks++;
    LLVMBasicBlockRef *order = calloc(nblocks + 1, sizeof *order), *stack = calloc(nblocks + 1, sizeof *stack);
    unsigned *next_succ = calloc(nblocks + 1, sizeof *next_succ);
    struct hash_table *seen = _mesa_pointer_hash_table_create(t->mem);
    unsigned norder = 0, sp = 0;
    stack[sp] = ts_LLVMGetFirstBasicBlock(fn); next_succ[sp++] = 0;
    _mesa_hash_table_insert(seen, stack[0], NULL);
    while (sp) {
        LLVMBasicBlockRef bb = stack[sp - 1];
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
        unsigned ns = term ? ts_LLVMGetNumSuccessors(term) : 0;
        if (next_succ[sp - 1] < ns) {
            LLVMBasicBlockRef s2 = ts_LLVMGetSuccessor(term, next_succ[sp - 1]++);
            if (!_mesa_hash_table_search(seen, s2)) { _mesa_hash_table_insert(seen, s2, NULL); stack[sp] = s2; next_succ[sp++] = 0; }
        } else { order[norder++] = bb; sp--; }
    }
    free(stack); free(next_succ);
    *out = order;   // post-order: iterate backwards for RPO
    return norder;
}

static bool declare_phis(S *t, LLVMBasicBlockRef bb);
static bool instruction(S *t, LLVMValueRef inst);
static bool terminator(S *t, LLVMValueRef term, LLVMBasicBlockRef bb, vi_block *exit);
static _Thread_local vi_block *t_exit;

// Calls through visible function tables (G4): the callee is one of the pipeline's linked functions, chosen by the
// table entry (its index + 1). Each candidate is inlined here, in layout order: test, body, next test..., then the
// code after the call.
static sv *sel_indirect_call(S *t, LLVMValueRef inst)
{
    if (t->inline_depth >= 2) SFAIL(t, "indirect call nested too deeply");
    LLVMValueRef callee = ts_LLVMGetCalledValue(inst);
    sv *id = sel_ssa(t, callee);
    if (!id) return NULL;
    unsigned nargs = ts_LLVMGetNumArgOperands(inst);
    LLVMTypeRef rty = ts_LLVMTypeOf(inst);
    sv *result = NULL;
    if (ts_LLVMGetTypeKind(rty) != LLVMVoidTypeKind) {
        unsigned bits, n; bool flt;
        if (!sel_type_info(rty, &bits, &n, &flt)) SFAIL(t, "indirect call returning an aggregate");
        result = sv_val(t, bits, n);
        vi_vreg_get(t->s, result->vreg)->multi_def = true;
    }
    sv *args[16];
    if (nargs > 16) SFAIL(t, "indirect call with %u arguments", nargs);
    for (unsigned a = 0; a < nargs; a++) if (!(args[a] = sel_value(t, ts_LLVMGetOperand(inst, a)))) return NULL;
    vi_block *after = t->b.block;
    vi_block *test = t->b.block;
    struct { sv *result; vi_block *cont; } ir;
    ir.result = result;
    vi_block *cont = NULL;
    vi_block *pending_skip[64]; unsigned npending = 0;
    char name[32];
    for (unsigned k = 0; k < t->in->linked_count; k++) {
        snprintf(name, sizeof name, "vmg_linked_%u", k);
        LLVMValueRef fn = ts_LLVMGetNamedFunction(t->mod, name);
        if (!fn || ts_LLVMIsDeclaration(fn) || ts_LLVMCountParams(fn) != nargs) continue;
        // test: id == k + 1 ? fall into the body : skip to the next test
        t->b.block = test; t->b.before = NULL;
        vi_ref c = sel_tmp(t);
        vi_instr *I = E(t, VA_ICMP_U32);
        I->dest = c; I->src[0] = sv_word(t, id, 0); I->src[1] = vi_imm(k + 1);
        vi_set(I, VAF_cmpf, VA_CMPF_M_EQ); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
        vi_instr *B = E(t, VA_BRANCH);
        B->src[0] = c; vi_set(B, VAF_not, 1);   // taken (to the next test) when not equal
        if (npending < 64) pending_skip[npending++] = test;
        // body blocks, in RPO, right after the test
        LLVMBasicBlockRef *order;
        unsigned norder = rpo_blocks(t, fn, &order);
        vi_block *first = NULL;
        for (unsigned q = norder; q-- > 0;) {
            vi_block *vb = vi_block_create(t->s);
            list_del(&vb->link); list_add(&vb->link, &after->link); after = vb;
            if (!first) first = vb;
            _mesa_hash_table_insert(t->blocks, order[q], vb);
        }
        vi_block_add_succ(test, first);
        for (unsigned a = 0; a < nargs; a++) _mesa_hash_table_insert(t->vals, ts_LLVMGetParam(fn, a), args[a]);
        bool ok = true;
        for (unsigned q = norder; q-- > 0 && ok;) ok = declare_phis(t, order[q]);
        if (!cont) { cont = vi_block_create(t->s); list_del(&cont->link); }
        ir.cont = cont;
        void *saved = t->iret;
        t->iret = (void *)&ir;
        t->inline_depth++;
        for (unsigned q = norder; q-- > 0 && ok;) {
            LLVMBasicBlockRef bb = order[q];
            t->b.block = (vi_block *)_mesa_hash_table_search(t->blocks, bb)->data; t->b.before = NULL;
            LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
            for (LLVMValueRef i = ts_LLVMGetFirstInstruction(bb); i && i != term && ok; i = ts_LLVMGetNextInstruction(i)) ok = instruction(t, i);
            if (ok && (!term || !terminator(t, term, bb, t_exit))) ok = false;
            if (t->b.block != (vi_block *)_mesa_hash_table_search(t->blocks, bb)->data) {}
        }
        t->inline_depth--;
        t->iret = saved;
        // forget the callee's values: it may be inlined again at another call
        for (unsigned a = 0; a < nargs; a++) _mesa_hash_table_remove_key(t->vals, ts_LLVMGetParam(fn, a));
        for (unsigned q = 0; q < norder; q++) {
            _mesa_hash_table_remove_key(t->blocks, order[q]);
            for (LLVMValueRef i = ts_LLVMGetFirstInstruction(order[q]); i; i = ts_LLVMGetNextInstruction(i)) {
                _mesa_hash_table_remove_key(t->vals, i);
                _mesa_hash_table_remove_key(t->phis, i);
            }
        }
        free(order);
        if (!ok) return NULL;
        // the next test follows the body
        vi_block *next = vi_block_create(t->s);
        list_del(&next->link); list_add(&next->link, &after->link); after = next;
        B->target = next;
        vi_block_add_succ(test, next);
        test = next;
    }
    if (!cont) { cont = vi_block_create(t->s); list_del(&cont->link); }
    // no function matched: on after the call (result undefined)
    list_add(&cont->link, &after->link);
    jump(t, test, cont);
    t->b.block = cont; t->b.before = NULL;
    (void)pending_skip; (void)npending;
    return result ? result : sv_new(t, SV_NONE);
}

static sv *call(S *t, LLVMValueRef inst)
{
    LLVMValueRef callee = ts_LLVMGetCalledValue(inst);
    char *name = sel_name(callee);
    if (!name) { USE(t, G4); return sel_indirect_call(t, inst); }
    sv *r = NULL;
    if (sel_name_is(name, "llvm.lifetime") || sel_name_is(name, "llvm.dbg") || sel_name_is(name, "llvm.assume") ||
        sel_name_is(name, "llvm.experimental.noalias") || sel_name_is(name, "llvm.invariant") || sel_name_is(name, "air.set_"))
        r = sv_new(t, SV_NONE);
    else if (sel_name_is(name, "air.wg.barrier")) r = sel_barrier(t, inst, true);
    else if (sel_name_is(name, "air.mem_barrier") || sel_name_is(name, "air.simdgroup.barrier")) r = sel_barrier(t, inst, false);
    else if (sel_name_is(name, "llvm.memcpy") || sel_name_is(name, "llvm.memmove")) r = sel_memcpy_set(t, inst, false);
    else if (sel_name_is(name, "llvm.memset")) r = sel_memcpy_set(t, inst, true);
    else if (sel_name_is(name, "air.atomic.")) r = sel_atomic(t, inst, name);
    else if (sel_name_is(name, "air.simd_") || sel_name_is(name, "air.quad_")) r = sel_subgroup(t, inst, name);
    else if (sel_name_is(name, "air.convert.")) r = sel_convert(t, inst, name);
    else if ((r = sel_io_call(t, inst, name)) != NULL || t->error) {}
    else if (sel_name_is(name, "air.") && (r = sel_texture(t, inst, name)) != NULL) {}
    else if (t->error) {}
    else if (sel_name_is(name, "air.") || sel_name_is(name, "llvm.")) r = sel_math(t, inst, name);
    else if (!t->error) t->error = vmg_strdup_printf("call to %s (functions are inlined before compilation)", name);
    free(name);
    return r;
}

static bool instruction(S *t, LLVMValueRef inst)
{
    LLVMOpcode op = ts_LLVMGetInstructionOpcode(inst);
    sv *r = NULL;
    switch (op) {
    case LLVMAdd: case LLVMSub: case LLVMMul: case LLVMUDiv: case LLVMSDiv: case LLVMURem: case LLVMSRem:
    case LLVMShl: case LLVMLShr: case LLVMAShr: case LLVMAnd: case LLVMOr: case LLVMXor:
    case LLVMFAdd: case LLVMFSub: case LLVMFMul: case LLVMFDiv: case LLVMFRem: case LLVMFNeg:
        r = sel_alu_instr(t, inst, op); break;
    case LLVMFreeze: r = sel_value(t, ts_LLVMGetOperand(inst, 0)); break;
    case LLVMICmp: r = sel_compare(t, inst, false); break;
    case LLVMFCmp: r = sel_compare(t, inst, true); break;
    case LLVMTrunc: case LLVMZExt: case LLVMSExt: case LLVMFPToUI: case LLVMFPToSI: case LLVMUIToFP: case LLVMSIToFP:
    case LLVMFPTrunc: case LLVMFPExt: case LLVMBitCast: case LLVMAddrSpaceCast: case LLVMPtrToInt: case LLVMIntToPtr:
        r = sel_cast(t, inst, op); break;
    case LLVMSelect: r = sel_select(t, inst); break;
    case LLVMExtractElement: r = sel_extract_element(t, inst); break;
    case LLVMInsertElement: r = sel_insert_element(t, inst); break;
    case LLVMShuffleVector: r = sel_shuffle(t, inst); break;
    case LLVMExtractValue: {
        sv *a = sel_value(t, ts_LLVMGetOperand(inst, 0));
        r = a ? extract_value(t, a, ts_LLVMGetIndices(inst), ts_LLVMGetNumIndices(inst)) : NULL;
        break;
    }
    case LLVMInsertValue: {
        sv *a = sel_value(t, ts_LLVMGetOperand(inst, 0)), *v = sel_value(t, ts_LLVMGetOperand(inst, 1));
        r = a && v ? insert_value(t, a, v, ts_LLVMGetIndices(inst), ts_LLVMGetNumIndices(inst)) : NULL;
        break;
    }
    case LLVMAlloca: r = sel_alloca(t, inst); break;
    case LLVMGetElementPtr: r = sel_gep(t, inst, (unsigned)ts_LLVMGetNumOperands(inst)); break;
    case LLVMLoad: r = sel_load(t, inst); break;
    case LLVMStore: if (!sel_store(t, inst)) return false; r = sv_new(t, SV_NONE); break;
    case LLVMCall: r = call(t, inst); break;
    case LLVMPHI: {
        struct hash_entry *he = _mesa_hash_table_search(t->phis, inst);
        if (!he) SFAILB(t, "phi of an unsupported type");
        sv *phi = he->data;
        if (ts_LLVMGetTypeKind(ts_LLVMTypeOf(inst)) == LLVMPointerTypeKind) {
            // Pointer phis: the memory of the first known incoming pointer (all must agree), offset from the phi.
            sv *first = NULL;
            for (unsigned k = 0; k < ts_LLVMCountIncoming(inst) && !first; k++) {
                LLVMValueRef iv = ts_LLVMGetIncomingValue(inst, k);
                struct hash_entry *e = _mesa_hash_table_search(t->vals, iv);
                if (e) first = e->data;
                else if (ts_LLVMIsAConstant(iv) || ts_LLVMIsAArgument(iv)) first = sel_value(t, iv);
            }
            if (!first || first->kind != SV_PTR) SFAILB(t, "pointer phi with no known incoming pointer");
            if (first->space == SP_GLOBAL) SFAILB(t, "phi of a pointer loaded from memory");
            r = sv_new(t, SV_PTR);
            r->space = first->space; r->slot = first->slot;
            sv *off = sv_new(t, SV_VAL);
            off->bits = 32; off->ncomp = 1; off->vreg = phi->vreg;   // word 0 of the phi
            r->off = off;
            if (first->space == SP_SSBO) {
                // the buffer may differ per edge: the handle travels with the phi (word 1)
                r->slot = -2;
                r->slot_mask = t->refl->buffers_used;
                r->dyn_handle = vi_vreg(phi->vreg, 1, 1);
            }
        } else r = phi;
        break;
    }
    case LLVMFence: r = sv_new(t, SV_NONE); break;
    default: SFAILB(t, "unsupported instruction %d", op);
    }
    if (!r) return false;
    _mesa_hash_table_insert(t->vals, inst, r);
    return true;
}

static bool declare_phis(S *t, LLVMBasicBlockRef bb)
{
    for (LLVMValueRef i = ts_LLVMGetFirstInstruction(bb); i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI; i = ts_LLVMGetNextInstruction(i)) {
        LLVMTypeRef ty = ts_LLVMTypeOf(i);
        unsigned bits = 32, n = 1; bool flt;
        if (ts_LLVMGetTypeKind(ty) == LLVMPointerTypeKind) n = 2;   // byte offset, SSBO handle
        else if (!sel_type_info(ty, &bits, &n, &flt)) SFAILB(t, "phi of an aggregate");
        sv *v = sv_val(t, bits, n);
        vi_vreg_get(t->s, v->vreg)->multi_def = true;
        _mesa_hash_table_insert(t->phis, i, v);
    }
    return true;
}

bool sel_function(S *t, LLVMValueRef outputs_md, LLVMValueRef inputs_md, vi_block **exit_out)
{
    USEB(t, A2);
    // Reverse post-order of the reachable blocks.
    unsigned nblocks = 0;
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(t->fn); bb; bb = ts_LLVMGetNextBasicBlock(bb)) nblocks++;
    LLVMBasicBlockRef *order = calloc(nblocks + 1, sizeof *order), *stack = calloc(nblocks + 1, sizeof *stack);
    unsigned *next_succ = calloc(nblocks + 1, sizeof *next_succ);
    struct hash_table *seen = _mesa_pointer_hash_table_create(t->mem);
    unsigned norder = 0, sp = 0;
    stack[sp] = ts_LLVMGetFirstBasicBlock(t->fn); next_succ[sp++] = 0;
    _mesa_hash_table_insert(seen, stack[0], NULL);
    while (sp) {
        LLVMBasicBlockRef bb = stack[sp - 1];
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
        unsigned ns = term ? ts_LLVMGetNumSuccessors(term) : 0;
        if (next_succ[sp - 1] < ns) {
            LLVMBasicBlockRef s2 = ts_LLVMGetSuccessor(term, next_succ[sp - 1]++);
            if (!_mesa_hash_table_search(seen, s2)) {
                _mesa_hash_table_insert(seen, s2, NULL);
                stack[sp] = s2; next_succ[sp++] = 0;
            }
        } else {
            order[norder++] = bb;
            sp--;
        }
    }
    bool ok = true;
    // Prologue block (preloads, inputs, the compute grid guard), then the LLVM blocks in RPO.
    vi_block *pro = vi_block_create(t->s);
    for (unsigned k = norder; k-- > 0;) {
        vi_block *vb = vi_block_create(t->s);
        _mesa_hash_table_insert(t->blocks, order[k], vb);
    }
    vi_block *exit = vi_block_create(t->s);
    *exit_out = exit;
    for (unsigned k = norder; k-- > 0 && ok;) ok = declare_phis(t, order[k]);
    vi_block *entry = block_of(t, order[norder - 1]);
    t->b.block = pro; t->b.before = NULL;
    t_exit = exit;
    if (ok) ok = sel_io_begin(t, outputs_md, inputs_md);
    if (ok && t->stage == MESA_SHADER_COMPUTE && sel_use(t, VMG_ISA_B11)) {
        // dispatchThreads: threads beyond threads_per_grid (constant buffer 0) do not exist in Metal.
        vi_ref out = vi_imm(0);
        for (unsigned k = 0; k < 3; k++) {
            vi_ref c = sel_tmp(t);
            vi_instr *I = E(t, VA_ICMP_U32);
            I->dest = c; I->src[0] = vi_reg(60 + k); I->src[1] = sel_fau_ubo(t, VI_UBO_CB0, 32 + 4 * k);
            vi_set(I, VAF_cmpf, VA_CMPF_M_GE); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
            if (out.kind == VI_IMM) out = c;
            else { vi_ref o = sel_tmp(t); I = E(t, VA_OR_I32); I->dest = o; I->src[0] = out; I->src[2] = c; out = o; }
        }
        vi_instr *B = E(t, VA_BRANCH);
        B->src[0] = out; B->target = exit;     // taken when out of the grid (nonzero)
        vi_block_add_succ(pro, exit);
    } else if (!ok) {
        // keep going: the error is reported below
    } else if (t->stage == MESA_SHADER_COMPUTE) ok = false;
    vi_block_add_succ(pro, entry);
    for (unsigned k = norder; k-- > 0 && ok;) {
        LLVMBasicBlockRef bb = order[k];
        t->b.block = block_of(t, bb); t->b.before = NULL;
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
        for (LLVMValueRef i = ts_LLVMGetFirstInstruction(bb); i && i != term && ok; i = ts_LLVMGetNextInstruction(i))
            ok = instruction(t, i);
        if (ok && (!term || !terminator(t, term, bb, exit))) ok = false;
    }
    free(order); free(stack); free(next_succ);
    // the exit block last in the layout
    list_del(&exit->link);
    list_addtail(&exit->link, &t->s->blocks);
    t->b.block = exit; t->b.before = NULL;
    return ok;
}
