// Viva ISA compiler: memory (C1-C10). Pointers are (memory, byte offset) as on the NIR path:
//   [[buffer(n)]]          SSBO n (table 6): loads LD_PKA.iN offset, handle; stores/atomics LEA_PKA -> address
//   small constant buffers constant buffer 0's push window (C2): constant offsets are pushed FAU words
//   system values header   constant buffer 0 (C3): pushed words
//   module constant tables hardware UBO 2 (C4), LD_PKA
//   threadgroup memory     workgroup-local pointer (special FAU) + offset (C5)
//   private memory         thread-local pointer + offset, .force accesses, never across 16 bytes (C6)
#include "vi_sel.h"
#include <string.h>

static unsigned align_of(uint64_t a) { return a ? (unsigned)MIN2(a, 16) : 4; }

// ---- Arguments --------------------------------------------------------------------------------------------------------

typedef struct { LLVMValueRef ops[64]; unsigned n; } mdops;

static bool md_is(LLVMValueRef v, const char *str)
{
    unsigned len = 0;
    const char *s = v ? ts_LLVMGetMDString(v, &len) : NULL;
    return s && len == strlen(str) && !memcmp(s, str, len);
}

static long md_int_after(const mdops *o, const char *key, long fallback)
{
    for (unsigned i = 0; i + 1 < o->n; i++)
        if (md_is(o->ops[i], key) && o->ops[i + 1] && ts_LLVMIsAConstantInt(o->ops[i + 1]))
            return (long)ts_LLVMConstIntGetSExtValue(o->ops[i + 1]);
    return fallback;
}

static unsigned push_used(S *t)
{
    unsigned used = 0;
    for (unsigned i = 0; i < VMG_MAX_BUFFERS; i++)
        if (t->refl->push_slots >> i & 1) used = MAX2(used, t->refl->push_offset[i] + ((t->refl->push_size[i] + 15u) & ~15u));
    return used;
}

sv *sel_buffer_arg(S *t, const mdops *o, LLVMTypeRef pt)
{
    long slot = md_int_after(o, "air.location_index", 0);
    long space = md_int_after(o, "air.address_space", ts_LLVMGetPointerAddressSpace(pt));
    if (space == 3) {
        extern sv *sel_threadgroup_arg(S *t, long slot);
        return sel_threadgroup_arg(t, slot);
    }
    if (slot < 0 || slot >= VMG_MAX_BUFFERS) SFAIL(t, "buffer %ld", slot);
    long size = md_int_after(o, "air.buffer_size", 0);
    unsigned need = (unsigned)((MAX2(size, 0) + 15) & ~15);
    sv *p = sv_new(t, SV_PTR);
    p->slot = (int)slot;
    unsigned used = push_used(t);
    if (t->push && space == 2 && size > 0 && need <= VMG_PUSH_WINDOW - used && !(t->refl->push_slots & (1u << slot))) {
        USE(t, C2);
        t->refl->push_slots |= 1u << slot;
        t->refl->push_offset[slot] = (uint16_t)used;
        t->refl->push_size[slot] = (uint16_t)size;
        p->space = SP_PUSH;
        p->off = sv_const32(t, VMG_SYSVAL_HEADER + used);
        return p;
    }
    USE(t, C1);
    t->refl->buffers_used |= 1u << slot;
    p->space = SP_SSBO;
    p->off = sv_const32(t, 0);
    return p;
}

sv *sel_threadgroup_arg(S *t, long slot)
{
    USE(t, C5);
    if (slot < 0 || slot >= 8) SFAIL(t, "threadgroup argument %ld", slot);
    t->refl->dynamic_shared_slots |= 1u << slot;
    sv *p = sv_new(t, SV_PTR);
    p->space = SP_SHARED; p->slot = -1;
    // byte offset of the argument in shared memory: system values header word `slot`
    vi_ref w = sel_mov32(t, sel_fau_ubo(t, VI_UBO_CB0, 4 * (unsigned)slot));
    p->off = sv_from_comps32(t, 32, 1, &w);
    return p;
}

sv *sel_sysval_word(S *t, unsigned byte_off)
{
    USE(t, C3);
    vi_ref w = sel_fau_ubo(t, VI_UBO_CB0, byte_off);
    return sv_from_comps32(t, 32, 1, &w);
}

// ---- Globals ----------------------------------------------------------------------------------------------------------

static bool serialize_const(S *t, LLVMValueRef c, uint8_t *out, uint64_t size);

sv *sel_global(S *t, LLVMValueRef g)
{
    struct hash_entry *he = _mesa_hash_table_search(t->globals, g);
    sv *placed = he ? he->data : NULL;
    if (!placed) {
        char *name = sel_name(g);
        LLVMValueRef init = ts_LLVMGetInitializer(g);
        LLVMTypeRef ty = ts_LLVMGetElementType(ts_LLVMTypeOf(g));
        unsigned as = ts_LLVMGetPointerAddressSpace(ts_LLVMTypeOf(g));
        if (name && !strncmp(name, "__air_sampler_state", 19)) {
            USE(t, D7);
            LLVMValueRef word = init ? (ts_LLVMIsAConstantDataSequential(init) ? ts_LLVMGetElementAsConstant(init, 0) : ts_LLVMGetOperand(init, 0)) : NULL;
            uint64_t w = word && ts_LLVMIsAConstantInt(word) ? ts_LLVMConstIntGetZExtValue(word) : 0;
            unsigned k = 0;
            for (; k < t->refl->constexpr_samplers && t->refl->constexpr_words[k] != w; k++) {}
            if (k == t->refl->constexpr_samplers) {
                if (k >= 16) { free(name); SFAIL(t, "more than 16 constexpr samplers"); }
                t->refl->constexpr_words[k] = w;
                t->refl->constexpr_samplers++;
            }
            placed = sv_new(t, SV_SMP);
            placed->index = VMG_CONSTEXPR_SAMPLER_BASE + (int)k;
            placed->word = w;
            placed->pixel = (w >> 15) & 1;
        } else if (as == 3) {
            USE(t, C5);
            uint64_t sz = sel_tsize(t, ty);
            t->shared = (t->shared + 15) & ~15u;
            placed = sv_new(t, SV_PTR);
            placed->space = SP_SHARED; placed->slot = -1; placed->index = (int)t->shared;
            t->shared += (unsigned)sz;
        } else if (init) {
            USE(t, C4);
            uint64_t sz = sel_tsize(t, ty);
            unsigned off = (unsigned)((t->pool->size + 15) & ~15);
            while (t->pool->size < off) util_dynarray_append(t->pool, (uint8_t){0});
            uint8_t *dst = util_dynarray_grow(t->pool, uint8_t, sz);
            if (!serialize_const(t, init, dst, sz)) { free(name); SFAIL(t, "constant table not serializable"); }
            placed = sv_new(t, SV_PTR);
            placed->space = SP_POOL; placed->slot = -1; placed->index = (int)off;
        } else {
            free(name);
            SFAIL(t, "global without initializer");
        }
        free(name);
        _mesa_hash_table_insert(t->globals, g, placed);
    }
    if (placed->kind != SV_PTR) return placed;
    sv *p = sv_new(t, SV_PTR);
    p->space = placed->space; p->slot = -1;
    p->off = sv_const32(t, (uint32_t)placed->index);
    return p;
}

static bool serialize_const(S *t, LLVMValueRef c, uint8_t *out, uint64_t size)
{
    LLVMTypeRef ty = ts_LLVMTypeOf(c);
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (ts_LLVMIsUndef(c) || ts_LLVMIsAConstantAggregateZero(c) || ts_LLVMIsAConstantPointerNull(c)) { memset(out, 0, size); return true; }
    if (k == LLVMStructTypeKind) {
        unsigned n = ts_LLVMCountStructElementTypes(ty);
        memset(out, 0, size);
        for (unsigned i = 0; i < n; i++) {
            uint64_t off = ts_LLVMOffsetOfElement(t->td, ty, i);
            if (!serialize_const(t, ts_LLVMGetOperand(c, i), out + off, sel_tstore(t, ts_LLVMStructGetTypeAtIndex(ty, i)))) return false;
        }
        return true;
    }
    if (k == LLVMArrayTypeKind || k == LLVMVectorTypeKind) {
        unsigned n = k == LLVMArrayTypeKind ? ts_LLVMGetArrayLength(ty) : ts_LLVMGetVectorSize(ty);
        LLVMTypeRef et = ts_LLVMGetElementType(ty);
        uint64_t es = k == LLVMArrayTypeKind ? sel_tsize(t, et) : sel_tstore(t, et);
        memset(out, 0, size);
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef e = ts_LLVMIsAConstantDataSequential(c) ? ts_LLVMGetElementAsConstant(c, i) : ts_LLVMGetOperand(c, i);
            if (!serialize_const(t, e, out + i * es, sel_tstore(t, et))) return false;
        }
        return true;
    }
    unsigned bits, n; bool flt;
    if (!sel_type_info(ty, &bits, &n, &flt)) return false;
    uint64_t u = 0;
    if (flt) {
        LLVMBool lost;
        double d = ts_LLVMConstRealGetDouble(c, &lost);
        if (bits == 32) { float f = (float)d; memcpy(&u, &f, 4); }
        else if (bits == 64) memcpy(&u, &d, 8);
        else u = _mesa_float_to_half((float)d);
    } else if (ts_LLVMIsAConstantInt(c)) u = ts_LLVMConstIntGetZExtValue(c);
    else return false;
    memcpy(out, &u, (bits + 7) / 8);
    return true;
}

// ---- Pointers ---------------------------------------------------------------------------------------------------------

static sv *ptr_add(S *t, sv *p, vi_ref bytes)
{
    sv *q = sv_new(t, SV_PTR);
    *q = *p;
    if (bytes.kind == VI_IMM && !bytes.value) return q;
    vi_ref o = sv_word(t, p->off, 0);
    vi_ref r;
    if (o.kind == VI_IMM && bytes.kind == VI_IMM) r = vi_imm(o.value + bytes.value);
    else if (o.kind == VI_IMM && o.value == 0) r = bytes;
    else if (bytes.kind == VI_IMM) r = sel_iadd_imm(t, o, (int32_t)bytes.value);
    else r = sel_alu2(t, VA_IADD_U32, o, bytes);
    q->off = sv_from_comps32(t, 32, 1, &r);
    return q;
}

sv *sel_gep(S *t, LLVMValueRef inst, unsigned nops)
{
    sv *base = sel_value(t, ts_LLVMGetOperand(inst, 0));
    if (!base) return NULL;
    if (base->kind != SV_PTR) SFAIL(t, "GEP on a non-pointer");
    LLVMTypeRef ty = ts_LLVMGetGEPSourceElementType ? ts_LLVMGetGEPSourceElementType(inst)
                                                    : ts_LLVMGetElementType(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0)));
    int64_t cst = 0;
    vi_ref dyn = vi_none();
    for (unsigned i = 1; i < nops; i++) {
        LLVMValueRef idx = ts_LLVMGetOperand(inst, i);
        uint64_t es;
        if (i == 1) es = sel_tsize(t, ty);
        else {
            LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
            if (k == LLVMStructTypeKind) {
                unsigned m = (unsigned)ts_LLVMConstIntGetZExtValue(idx);
                cst += (int64_t)ts_LLVMOffsetOfElement(t->td, ty, m);
                ty = ts_LLVMStructGetTypeAtIndex(ty, m);
                continue;
            }
            if (k != LLVMArrayTypeKind && k != LLVMVectorTypeKind) SFAIL(t, "GEP into a scalar");
            LLVMTypeRef et = ts_LLVMGetElementType(ty);
            es = k == LLVMArrayTypeKind ? sel_tsize(t, et) : sel_tstore(t, et);
            ty = et;
        }
        if (ts_LLVMIsAConstantInt(idx)) { cst += ts_LLVMConstIntGetSExtValue(idx) * (int64_t)es; continue; }
        sv *x = sel_ssa(t, idx);
        if (!x) return NULL;
        vi_ref xi = sv_word(t, x, 0);   // low word (64-bit indices: offsets fit 32 bits)
        if (x->bits < 32) xi = sv_comp32(t, x, 0, X_SEXT);
        vi_ref m = sel_imul_imm(t, xi, (uint32_t)es);
        dyn = dyn.kind ? sel_alu2(t, VA_IADD_U32, dyn, m) : m;
    }
    sv *p = ptr_add(t, base, vi_imm((uint32_t)cst));
    return dyn.kind ? ptr_add(t, p, dyn) : p;
}

sv *sel_alloca(S *t, LLVMValueRef inst)
{
    USE(t, C6);
    LLVMTypeRef ty = ts_LLVMGetAllocatedType(inst);
    unsigned a = align_of(ts_LLVMGetAlignment(inst));
    if (a < 4) a = 4;
    t->scratch = (t->scratch + a - 1) & ~(a - 1);
    sv *p = sv_new(t, SV_PTR);
    p->space = SP_SCRATCH; p->slot = -1;
    p->off = sv_const32(t, t->scratch);
    t->scratch += (unsigned)sel_tsize(t, ty);
    return p;
}

// ---- Access primitives --------------------------------------------------------------------------------------------------

static const enum va_op kLdPka[5] = { 0, VA_LD_PKA_I32, VA_LD_PKA_I64, VA_LD_PKA_I96, VA_LD_PKA_I128 };
static const enum va_op kLoad[5] = { 0, VA_LOAD_I32, VA_LOAD_I64, VA_LOAD_I96, VA_LOAD_I128 };
static const enum va_op kStore[5] = { 0, VA_STORE_I32, VA_STORE_I64, VA_STORE_I96, VA_STORE_I128 };

// 64-bit address of shared / private memory + offset (the high word never carries, ABI §10).
static vi_ref local_address(S *t, sv *p, int *imm)
{
    bool shared = p->space == SP_SHARED;
    vi_ref base = vi_special(1, shared ? 2 * 3 : 2 * 1);   // workgroup / thread local pointer
    vi_ref o = sv_word(t, p->off, 0);
    if (o.kind == VI_IMM && o.value < 0x8000) {
        *imm = (int)o.value;
        vi_ref lo = sel_mov32(t, base), hi = sel_mov32(t, (vi_ref){ VI_SPECIAL, base.word, 1, false, base.value + 1 });
        return sel_pair(t, lo, hi);
    }
    *imm = 0;
    vi_ref lo = sel_alu2(t, VA_IADD_U32, base, o.kind == VI_IMM ? sel_mov32(t, o) : o);
    vi_ref hi = sel_mov32(t, (vi_ref){ VI_SPECIAL, base.word, 1, false, base.value + 1 });
    return sel_pair(t, lo, hi);
}

vi_ref sel_ssbo_handle(S *t, const sv *p) { (void)t; return p->slot >= 0 ? vi_imm((6u << 24) | (unsigned)p->slot) : p->dyn_handle; }
#define ssbo_handle(t, slot_unused) sel_ssbo_handle(t, p)

// Address of an SSBO byte offset (stores, atomics, loads through a pointer chosen at run time).
// The buffer handle of LEA_PKA/LD_PKA is read from one lane for the whole warp: a pointer whose buffer differs between
// threads (select/phi of [[buffer(a)]] and [[buffer(b)]]) took one lane's buffer everywhere on the phone (C1). Such a
// pointer gets the address in every candidate buffer (uniform handles) and each thread selects its own.
static vi_ref ssbo_address(S *t, sv *p)
{
    vi_ref o = sv_word(t, p->off, 0);
    if (o.kind == VI_IMM) o = sel_mov32(t, o);
    if (p->slot >= 0 || !p->slot_mask) {
        uint32_t a = vi_new_vreg(t->s, 2);
        vi_instr *I = E(t, VA_LEA_PKA);
        I->sw = vi_vreg(a, 0, 2);
        I->src[0] = o;
        I->src[1] = ssbo_handle(t, p->slot);
        return vi_vreg(a, 0, 2);
    }
    vi_ref lo = vi_imm(0), hi = vi_imm(0);
    for (uint32_t m = p->slot_mask; m; m &= m - 1) {
        unsigned slot = (unsigned)__builtin_ctz(m);
        uint32_t a = vi_new_vreg(t->s, 2);
        vi_instr *I = E(t, VA_LEA_PKA);
        I->sw = vi_vreg(a, 0, 2);
        I->src[0] = o;
        I->src[1] = vi_imm((6u << 24) | slot);
        vi_ref h = vi_imm((6u << 24) | slot);
        lo = sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_U32, p->dyn_handle, h, vi_vreg(a, 0, 1), lo);
        hi = sel_csel(t, VA_CMPF_M_EQ, VA_CSEL_U32, p->dyn_handle, h, vi_vreg(a, 1, 1), hi);
    }
    return sel_pair(t, lo, hi);
}

// 64-bit address of a global pointer + byte offset; *imm takes a small constant offset when possible.
static vi_ref global_address(S *t, sv *p, vi_ref off, int *imm)
{
    if (off.kind == VI_IMM && off.value < 0x8000) { *imm = (int)off.value; return p->addr; }
    *imm = 0;
    vi_ref o = off.kind == VI_IMM ? sel_mov32(t, off) : off;
    vi_ref hi = sel_tmp(t);
    vi_instr *H = E(t, VA_ARSHIFT_OR_I32); H->dest = hi; H->src[0] = o; H->src[1] = vi_imm(31); H->src[2] = vi_imm(0);
    vi_ref pair = sel_pair(t, o, hi);
    uint32_t a = vi_new_vreg(t->s, 2);
    vi_instr *I = E(t, VA_IADD_U64);
    I->dest = vi_vreg(a, 0, 2); I->src[0] = p->addr; I->src[1] = pair;
    vi_set(I, VAF_widen0, 0); vi_set(I, VAF_widen1, 0);
    return vi_vreg(a, 0, 2);
}

// Loads `words` 32-bit words (1-4) at p + extra.
static vi_ref load_words(S *t, sv *p, unsigned words, unsigned extra)
{
    uint32_t d = vi_new_vreg(t->s, words);
    vi_ref off = sv_word(t, p->off, 0);
    if (extra) off = off.kind == VI_IMM ? vi_imm(off.value + extra) : sel_iadd_imm(t, off, (int32_t)extra);
    switch (p->space) {
    case SP_SSBO: case SP_POOL: {
        if (p->space == SP_SSBO && p->slot < 0 && p->slot_mask) {
            // buffer chosen per thread: a global load at its address (see ssbo_address)
            sv q = *p;
            sv o2 = { .kind = SV_VAL, .bits = 32, .ncomp = 1 };
            if (off.kind == VI_IMM) { o2.is_const = true; o2.cw[0] = off.value; } else o2.vreg = off.value;
            q.off = &o2;
            vi_instr *I = E(t, kLoad[words]);
            I->sw = vi_vreg(d, 0, words);
            I->src[0] = ssbo_address(t, &q);
            vi_set(I, VAF_offset, 0);
            if (words == 1) vi_set(I, VAF_lane, VA_LOAD_LANE_32_M_NONE);
            I->memory = true;
            break;
        }
        vi_ref o = off.kind == VI_IMM ? sel_mov32(t, off) : off;
        vi_instr *I = E(t, kLdPka[words]);
        I->sw = vi_vreg(d, 0, words);
        I->src[0] = o;
        I->src[1] = p->space == SP_SSBO ? ssbo_handle(t, p->slot) : vi_imm(VI_UBO_POOL);
        if (p->space == SP_SSBO) I->memory = true;
        else t->ubo_mask |= 1u << VI_UBO_POOL;
        if (words == 1) vi_set(I, VAF_lane, VA_LOAD_LANE_32_M_NONE);
        break;
    }
    case SP_PUSH:
        if (off.kind == VI_IMM) {
            bool ok = true;
            vi_ref w[4];
            for (unsigned k = 0; k < words && ok; k++) { w[k] = sel_fau_ubo(t, VI_UBO_CB0, off.value + 4 * k); if (!w[k].kind) ok = false; }
            if (ok) {
                for (unsigned k = 0; k < words; k++) { vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(d, k, 1); I->src[0] = w[k]; }
                break;
            }
        }
        t->ubo_mask |= 1u << VI_UBO_CB0;
        {
            vi_ref o = off.kind == VI_IMM ? sel_mov32(t, off) : off;
            vi_instr *I = E(t, kLdPka[words]);
            I->sw = vi_vreg(d, 0, words);
            I->src[0] = o;
            I->src[1] = vi_imm(VI_UBO_CB0);
            if (words == 1) vi_set(I, VAF_lane, VA_LOAD_LANE_32_M_NONE);
        }
        break;
    default: {
        sv q = *p;
        sv o2 = { .kind = SV_VAL, .bits = 32, .ncomp = 1 };
        if (off.kind == VI_IMM) { o2.is_const = true; o2.cw[0] = off.value; } else { o2.vreg = off.value; }
        q.off = &o2;
        int imm;
        vi_ref addr = p->space == SP_GLOBAL ? global_address(t, p, off, &imm) : local_address(t, &q, &imm);
        vi_instr *I = E(t, kLoad[words]);
        I->sw = vi_vreg(d, 0, words);
        I->src[0] = addr;
        vi_set(I, VAF_offset, imm);
        if (p->space == SP_SCRATCH) vi_set(I, VAF_access, VA_ACCESS_LOAD_M_FORCE);
        if (words == 1) vi_set(I, VAF_lane, VA_LOAD_LANE_32_M_NONE);
        I->memory = true;
        break;
    }
    }
    return vi_vreg(d, 0, words);
}

static bool store_words(S *t, sv *p, vi_ref value, unsigned words, unsigned extra)
{
    vi_ref off = sv_word(t, p->off, 0);
    if (extra) off = off.kind == VI_IMM ? vi_imm(off.value + extra) : sel_iadd_imm(t, off, (int32_t)extra);
    if (value.kind != VI_VREG) {
        uint32_t v = vi_new_vreg(t->s, 1);
        vi_instr *M = value.kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
        if (value.kind == VI_IMM) vi_set(M, VAF_imm1w, value.value); else M->src[0] = value;
        M->dest = vi_vreg(v, 0, 1);
        value = vi_vreg(v, 0, 1);
    }
    vi_ref addr;
    int imm = 0;
    switch (p->space) {
    case SP_SSBO: {
        sv q = *p;
        sv o2 = { .kind = SV_VAL, .bits = 32, .ncomp = 1 };
        if (off.kind == VI_IMM) { o2.is_const = true; o2.cw[0] = off.value; } else o2.vreg = off.value;
        q.off = &o2;
        addr = ssbo_address(t, &q);
        t->info.writes_global = true;
        break;
    }
    case SP_SHARED: case SP_SCRATCH: {
        sv q = *p;
        sv o2 = { .kind = SV_VAL, .bits = 32, .ncomp = 1 };
        if (off.kind == VI_IMM) { o2.is_const = true; o2.cw[0] = off.value; } else o2.vreg = off.value;
        q.off = &o2;
        addr = local_address(t, &q, &imm);
        break;
    }
    case SP_GLOBAL:
        addr = global_address(t, p, off, &imm);
        t->info.writes_global = true;
        break;
    default: SFAILB(t, "store into constant memory");
    }
    vi_instr *I = E(t, kStore[words]);
    I->sr = value; I->src[0] = addr;
    vi_set(I, VAF_offset, imm);
    if (p->space == SP_SCRATCH) vi_set(I, VAF_access, VA_ACCESS_STORE_M_FORCE);
    I->memory = true;
    return true;
}

// Sub-word access (8/16-bit scalars): read-modify-write of the containing word for stores; extraction for loads.
static vi_ref load_sub(S *t, sv *p, unsigned bits, unsigned extra)
{
    // load the aligned word and shift
    vi_ref off = sv_word(t, p->off, 0);
    if (extra) off = off.kind == VI_IMM ? vi_imm(off.value + extra) : sel_iadd_imm(t, off, (int32_t)extra);
    sv q = *p;
    sv o2 = { .kind = SV_VAL, .bits = 32, .ncomp = 1 };
    vi_ref aligned, shift;
    if (off.kind == VI_IMM) { aligned = vi_imm(off.value & ~3u); shift = vi_imm((off.value & 3) * 8); }
    else {
        aligned = sel_tmp(t);
        vi_instr *I = E(t, VA_AND_I32); I->dest = aligned; I->src[0] = off; I->src[2] = vi_imm(~3u);
        vi_ref lo = sel_tmp(t);
        I = E(t, VA_AND_I32); I->dest = lo; I->src[0] = off; I->src[2] = vi_imm(3u);
        shift = sel_imul_imm(t, lo, 8);
    }
    if (aligned.kind == VI_IMM) { o2.is_const = true; o2.cw[0] = aligned.value; } else o2.vreg = aligned.value;
    q.off = &o2;
    vi_ref w = load_words(t, &q, 1, 0);
    vi_ref d = sel_tmp(t);
    vi_instr *I = E(t, VA_RSHIFT_OR_I32); I->dest = d; I->src[0] = w; I->src[1] = shift; I->src[2] = vi_imm(0);
    (void)bits;
    return d;
}

static bool store_sub(S *t, sv *p, vi_ref value, unsigned bits, unsigned extra)
{
    vi_ref off = sv_word(t, p->off, 0);
    if (extra) off = off.kind == VI_IMM ? vi_imm(off.value + extra) : sel_iadd_imm(t, off, (int32_t)extra);
    if (p->space == SP_SSBO || p->space == SP_SHARED || p->space == SP_SCRATCH || p->space == SP_GLOBAL) {
        // byte / half stores exist: STORE.i8 / STORE.i16 with the lane of the source
        sv q = *p;
        sv o2 = { .kind = SV_VAL, .bits = 32, .ncomp = 1 };
        if (off.kind == VI_IMM) { o2.is_const = true; o2.cw[0] = off.value; } else o2.vreg = off.value;
        q.off = &o2;
        vi_ref addr;
        int imm = 0;
        if (p->space == SP_SSBO) { addr = ssbo_address(t, &q); t->info.writes_global = true; }
        else if (p->space == SP_GLOBAL) { addr = global_address(t, p, off, &imm); t->info.writes_global = true; }
        else addr = local_address(t, &q, &imm);
        vi_ref v = value.kind == VI_VREG ? value : sel_mov32(t, value);
        vi_instr *I = E(t, bits == 8 ? VA_STORE_I8 : VA_STORE_I16);
        I->sr = v; I->src[0] = addr;
        vi_set(I, VAF_offset, imm);
        vi_set(I, VAF_lane, 0);
        if (p->space == SP_SCRATCH) vi_set(I, VAF_access, VA_ACCESS_STORE_M_FORCE);
        I->memory = true;
        return true;
    }
    SFAILB(t, "store into constant memory");
}

// ---- Typed loads and stores (C7) --------------------------------------------------------------------------------------

static sv *load_typed(S *t, sv *p, LLVMTypeRef ty, unsigned align, unsigned extra)
{
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (k == LLVMStructTypeKind || k == LLVMArrayTypeKind) {
        USE(t, C7);
        unsigned n = k == LLVMStructTypeKind ? ts_LLVMCountStructElementTypes(ty) : ts_LLVMGetArrayLength(ty);
        sv *a = sv_new(t, SV_AGG);
        a->n = n; a->e = ralloc_array(t->mem, sv *, n ? n : 1);
        for (unsigned i = 0; i < n; i++) {
            LLVMTypeRef et = k == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(ty, i) : ts_LLVMGetElementType(ty);
            uint64_t off = k == LLVMStructTypeKind ? ts_LLVMOffsetOfElement(t->td, ty, i) : i * sel_tsize(t, et);
            if (!(a->e[i] = load_typed(t, p, et, off % align ? 1 : align, extra + (unsigned)off))) return NULL;
        }
        return a;
    }
    if (k == LLVMPointerTypeKind) {
        // a device/constant pointer stored in memory (argument buffers, G3): its 64-bit GPU address
        USE(t, G3);
        unsigned as = ts_LLVMGetPointerAddressSpace(ty);
        if (as != 1 && as != 2) SFAIL(t, "pointer to address space %u loaded from memory", as);
        vi_ref a = load_words(t, p, 2, extra);
        sv *g = sv_new(t, SV_PTR);
        g->space = SP_GLOBAL; g->slot = -1;
        g->addr = a;
        g->off = sv_const32(t, 0);
        return g;
    }
    unsigned bits, n; bool flt;
    if (!sel_type_info(ty, &bits, &n, &flt)) SFAIL(t, "load of an unsupported type");
    unsigned mbits = bits == 1 ? 8 : bits;
    unsigned bytes = (mbits * n + 7) / 8;
    if (mbits >= 32 || (bytes % 4 == 0 && align >= 4)) {
        // whole words, in pieces of at most 16 bytes that keep private accesses inside 16-byte lines
        unsigned words = bytes / 4;
        sv *r = sv_val(t, bits == 1 ? 32 : bits, n);
        if (bits == 1) r->bits = 1;
        unsigned w = 0;
        while (w < words) {
            unsigned chunk = MIN2(4, words - w);
            if (align < 4 * chunk || p->space == SP_SCRATCH) {
                // conservative: word by word unless aligned (scratch: 16-byte lines)
                unsigned limit = align >= 16 ? 4 : align >= 8 ? 2 : 1;
                chunk = MIN2(chunk, limit);
            }
            vi_ref x = load_words(t, p, chunk, extra + 4 * w);
            for (unsigned c = 0; c < chunk; c++) { vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(r->vreg, w + c, 1); I->src[0] = vi_vreg(x.value, c, 1); }
            w += chunk;
        }
        if (bits == 1) {
            vi_ref c[16];
            for (unsigned i = 0; i < n; i++) { vi_ref b = vi_vreg(r->vreg, i, 1); c[i] = sel_alu2(t, VA_ICMP_U32, b, vi_imm(0)); vi_instr *I = list_last_entry(&t->b.block->instrs, vi_instr, link); vi_set(I, VAF_cmpf, VA_CMPF_M_NE); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1); }
            return sv_from_comps32(t, 1, n, c);
        }
        return r;
    }
    // 8/16-bit elements not word aligned: element by element
    vi_ref c[16];
    unsigned es = mbits / 8;
    for (unsigned i = 0; i < n; i++) {
        vi_ref x = load_sub(t, p, mbits, extra + i * es);
        if (bits == 1) {
            vi_ref m = sel_tmp(t);
            vi_instr *I = E(t, VA_AND_I32); I->dest = m; I->src[0] = x; I->src[2] = vi_imm(0xff);
            c[i] = sel_alu2(t, VA_ICMP_U32, m, vi_imm(0));
            I = list_last_entry(&t->b.block->instrs, vi_instr, link); vi_set(I, VAF_cmpf, VA_CMPF_M_NE); vi_set(I, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
        } else c[i] = x;
    }
    return sv_from_comps32(t, bits, n, c);
}

static bool store_typed(S *t, sv *p, sv *v, LLVMTypeRef ty, unsigned align, unsigned extra)
{
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (k == LLVMStructTypeKind || k == LLVMArrayTypeKind) {
        USEB(t, C7);
        if (v->kind != SV_AGG) SFAILB(t, "aggregate store of a non-aggregate");
        for (unsigned i = 0; i < v->n; i++) {
            LLVMTypeRef et = k == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(ty, i) : ts_LLVMGetElementType(ty);
            uint64_t off = k == LLVMStructTypeKind ? ts_LLVMOffsetOfElement(t->td, ty, i) : i * sel_tsize(t, et);
            if (!store_typed(t, p, v->e[i], et, off % align ? 1 : align, extra + (unsigned)off)) return false;
        }
        return true;
    }
    if (v->kind == SV_PTR) SFAILB(t, "pointer stored into memory");
    if (v->kind != SV_VAL) SFAILB(t, "store of a resource");
    unsigned bits, n; bool flt;
    if (!sel_type_info(ty, &bits, &n, &flt)) SFAILB(t, "store of an unsupported type");
    unsigned mbits = bits == 1 ? 8 : bits;
    unsigned bytes = (mbits * n + 7) / 8;
    if (bits != 1 && (mbits >= 32 || (bytes % 4 == 0 && align >= 4))) {
        unsigned words = bytes / 4, w = 0;
        sv *m = sv_materialize(t, v);
        while (w < words) {
            unsigned chunk = MIN2(4, words - w);
            unsigned limit = align >= 16 ? 4 : align >= 8 ? 2 : 1;
            chunk = MIN2(chunk, limit);
            vi_ref val = vi_vreg(m->vreg, w, chunk);
            if (w || chunk != sv_words(m->bits, m->ncomp)) {
                // staging registers must be a whole aligned vector: copy the chunk
                uint32_t c = vi_new_vreg(t->s, chunk);
                for (unsigned q = 0; q < chunk; q++) { vi_instr *I = E(t, VA_MOV_I32); I->dest = vi_vreg(c, q, 1); I->src[0] = vi_vreg(m->vreg, w + q, 1); }
                val = vi_vreg(c, 0, chunk);
            }
            if (!store_words(t, p, val, chunk, extra + 4 * w)) return false;
            w += chunk;
        }
        return true;
    }
    unsigned es = mbits / 8;
    for (unsigned i = 0; i < n; i++) {
        vi_ref x = sv_comp32(t, v, i, X_ZEXT);
        if (es == 4) { if (!store_words(t, p, x, 1, extra + 4 * i)) return false; }
        else if (!store_sub(t, p, x, mbits, extra + i * es)) return false;
    }
    return true;
}

sv *sel_load(S *t, LLVMValueRef inst)
{
    sv *p = sel_value(t, ts_LLVMGetOperand(inst, 0));
    if (!p) return NULL;
    if (p->kind != SV_PTR) SFAIL(t, "load from a non-pointer");
    if (p->space == SP_SSBO) USE(t, C1);
    return load_typed(t, p, ts_LLVMTypeOf(inst), align_of(ts_LLVMGetAlignment(inst)), 0);
}

bool sel_store(S *t, LLVMValueRef inst)
{
    sv *v = sel_value(t, ts_LLVMGetOperand(inst, 0)), *p = sel_value(t, ts_LLVMGetOperand(inst, 1));
    if (!v || !p) return false;
    if (p->kind != SV_PTR) SFAILB(t, "store to a non-pointer");
    if (p->space == SP_SSBO) { USEB(t, C1); t->refl->buffers_written |= p->slot >= 0 ? 1u << p->slot : p->slot_mask; }
    return store_typed(t, p, v, ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0)), align_of(ts_LLVMGetAlignment(inst)), 0);
}

// ---- memcpy / memset (C8) ---------------------------------------------------------------------------------------------

sv *sel_memcpy_set(S *t, LLVMValueRef inst, bool set)
{
    USE(t, C8);
    sv *dst = sel_value(t, ts_LLVMGetOperand(inst, 0));
    LLVMValueRef lenv = ts_LLVMGetOperand(inst, 2);
    if (!dst) return NULL;
    if (!ts_LLVMIsAConstantInt(lenv)) SFAIL(t, "memcpy/memset with a dynamic size");
    uint64_t len = ts_LLVMConstIntGetZExtValue(lenv);
    if (len > 4096) SFAIL(t, "memcpy/memset of %llu bytes", (unsigned long long)len);
    if (dst->kind != SV_PTR) SFAIL(t, "memcpy/memset into a non-pointer");
    if (dst->space == SP_SSBO) t->refl->buffers_written |= dst->slot >= 0 ? 1u << dst->slot : dst->slot_mask;
    if (set) {
        sv *byte = sel_ssa(t, ts_LLVMGetOperand(inst, 1));
        if (!byte) return NULL;
        vi_ref b = sv_comp32(t, byte, 0, X_ZEXT);
        vi_ref w = b.kind == VI_IMM ? vi_imm((b.value & 0xff) * 0x01010101u) : sel_imul_imm(t, b, 0x01010101u);
        uint64_t o = 0;
        for (; o + 4 <= len; o += 4) if (!store_words(t, dst, w, 1, (unsigned)o)) return NULL;
        for (; o < len; o++) if (!store_sub(t, dst, w, 8, (unsigned)o)) return NULL;
        return sv_new(t, SV_NONE);
    }
    sv *src = sel_value(t, ts_LLVMGetOperand(inst, 1));
    if (!src) return NULL;
    if (src->kind != SV_PTR) SFAIL(t, "memcpy from a non-pointer");
    uint64_t o = 0;
    for (; o + 4 <= len; o += 4) {
        vi_ref x = load_words(t, src, 1, (unsigned)o);
        if (!store_words(t, dst, x, 1, (unsigned)o)) return NULL;
    }
    for (; o < len; o++) if (!store_sub(t, dst, load_sub(t, src, 8, (unsigned)o), 8, (unsigned)o)) return NULL;
    return sv_new(t, SV_NONE);
}

// ---- Atomics (C9) and barriers (C10) ----------------------------------------------------------------------------------

static vi_ref atomic_address(S *t, sv *p)
{
    if (p->space == SP_SSBO) return ssbo_address(t, p);
    if (p->space == SP_GLOBAL) {
        int imm;
        vi_ref off = sv_word(t, p->off, 0);
        if (off.kind == VI_IMM && off.value == 0) return p->addr;
        if (off.kind == VI_IMM) off = sel_mov32(t, off);   // whole address (atomics take no offset here)
        return global_address(t, p, off, &imm);
    }
    int imm;
    vi_ref a = local_address(t, p, &imm);
    if (imm) {
        // fold the immediate into the low word
        vi_ref lo = sel_iadd_imm(t, vi_vreg(a.value, 0, 1), imm);
        return sel_pair(t, lo, vi_vreg(a.value, 1, 1));
    }
    return a;
}

sv *sel_atomic(S *t, LLVMValueRef inst, const char *name)
{
    USE(t, C9);
    const char *p = strchr(name + strlen("air.atomic."), '.');
    if (!p) SFAIL(t, "malformed %s", name);
    p++;
    char op[32];
    const char *e = strchr(p, '.');
    snprintf(op, sizeof op, "%.*s", e ? (int)(e - p) : (int)strlen(p), p);
    bool u = strstr(name, ".u.") != NULL;
    sv *ptr = sel_value(t, ts_LLVMGetOperand(inst, 0));
    if (!ptr) return NULL;
    if (ptr->kind != SV_PTR || (ptr->space != SP_SSBO && ptr->space != SP_SHARED && ptr->space != SP_GLOBAL)) SFAIL(t, "atomic on unsupported memory");
    if (ptr->space == SP_SSBO) { t->refl->buffers_written |= ptr->slot >= 0 ? 1u << ptr->slot : ptr->slot_mask; t->info.writes_global = true; }
    if (!strcmp(op, "load")) {
        vi_ref x = load_words(t, ptr, 1, 0);
        return sv_from_comps32(t, 32, 1, &x);
    }
    sv *data = sel_ssa(t, ts_LLVMGetOperand(inst, 1));
    if (!data && strcmp(op, "cmpxchg")) return NULL;
    t->error = t->error;   // (data may be a pointer for cmpxchg)
    int aop;
    bool neg = false;
    if (!strcmp(op, "add")) aop = VA_ATOM_OPERATION_M_AADD;
    else if (!strcmp(op, "sub")) { aop = VA_ATOM_OPERATION_M_AADD; neg = true; }
    else if (!strcmp(op, "and")) aop = VA_ATOM_OPERATION_M_AAND;
    else if (!strcmp(op, "or")) aop = VA_ATOM_OPERATION_M_AOR;
    else if (!strcmp(op, "xor")) aop = VA_ATOM_OPERATION_M_AXOR;
    else if (!strcmp(op, "min")) aop = u ? VA_ATOM_OPERATION_M_AUMIN : VA_ATOM_OPERATION_M_ASMIN;
    else if (!strcmp(op, "max")) aop = u ? VA_ATOM_OPERATION_M_AUMAX : VA_ATOM_OPERATION_M_ASMAX;
    else if (!strcmp(op, "xchg") || !strcmp(op, "store")) aop = VA_ATOM_OPERATION_M_AXCHG;
    else if (!strcmp(op, "cmpxchg")) aop = -1;
    else SFAIL(t, "unsupported atomic %s", name);
    vi_ref addr = atomic_address(t, ptr);
    if (aop < 0) {
        // cmpxchg(ptr, expected*, desired, ...): staging {desired, expected}, result = old value
        sv *expp = sel_value(t, ts_LLVMGetOperand(inst, 1));
        sv *desired = sel_ssa(t, ts_LLVMGetOperand(inst, 2));
        if (!expp || !desired) return NULL;
        vi_ref expected = expp->kind == SV_PTR ? load_words(t, expp, 1, 0) : sv_word(t, expp, 0);
        uint32_t st = vi_new_vreg(t->s, 2);
        vi_ref parts[2] = { sv_word(t, desired, 0), expected };
        for (unsigned k = 0; k < 2; k++) {
            vi_instr *I = parts[k].kind == VI_IMM ? E(t, VA_MOV_IMM_I32) : E(t, VA_MOV_I32);
            if (parts[k].kind == VI_IMM) vi_set(I, VAF_imm1w, parts[k].value); else I->src[0] = parts[k];
            I->dest = vi_vreg(st, k, 1);
        }
        vi_ref old = sel_tmp(t);
        vi_instr *I = E(t, VA_ACMPXCHG_I32);
        I->sr = vi_vreg(st, 0, 2); I->sw = old; I->src[0] = addr; vi_set(I, VAF_offset, 0);
        I->memory = true;
        if (expp->kind == SV_PTR) store_words(t, expp, old, 1, 0);
        // air.atomic.*.cmpxchg returns the old value (i32); Metal's frontend compares it with the expected value. As a
        // boolean the loop of atomic_compare_exchange_weak never ended on the phone (C9). An i1 result is the success.
        LLVMTypeRef rt = ts_LLVMTypeOf(inst);
        if (ts_LLVMGetTypeKind(rt) == LLVMIntegerTypeKind && ts_LLVMGetIntTypeWidth(rt) == 1) {
            vi_ref eq = sel_tmp(t);
            vi_instr *C = E(t, VA_ICMP_U32); C->dest = eq; C->src[0] = old; C->src[1] = expected;
            vi_set(C, VAF_cmpf, VA_CMPF_M_EQ); vi_set(C, VAF_result_type, VA_CMP_RESULT_TYPE_M_I1);
            return sv_from_comps32(t, 1, 1, &eq);
        }
        return sv_from_comps32(t, 32, 1, &old);
    }
    vi_ref arg = sv_word(t, data, 0);
    if (neg) arg = sel_alu2(t, VA_ISUB_S32, vi_imm(0), arg);
    vi_ref sa = sel_mov32(t, arg);
    vi_ref old = sel_tmp(t);
    vi_instr *I = E(t, aop == VA_ATOM_OPERATION_M_AXCHG ? VA_AXCHG_I32 : VA_ATOM_RETURN_I32);
    I->sr = sa; I->sw = old; I->src[0] = addr; vi_set(I, VAF_offset, 0);
    if (aop != VA_ATOM_OPERATION_M_AXCHG) vi_set(I, VAF_atom_opc, aop);
    I->memory = true;
    if (!strcmp(op, "store")) return sv_new(t, SV_NONE);
    return sv_from_comps32(t, 32, 1, &old);
}

sv *sel_barrier(S *t, LLVMValueRef inst, bool execution)
{
    USE(t, C10);
    unsigned flags = 0;
    LLVMValueRef fv = ts_LLVMGetNumArgOperands(inst) ? ts_LLVMGetOperand(inst, 0) : NULL;
    if (fv && ts_LLVMIsAConstantInt(fv)) flags = (unsigned)ts_LLVMConstIntGetZExtValue(fv);
    if (t->stage != MESA_SHADER_COMPUTE) execution = false;
    if (execution) {
        vi_instr *I = E(t, VA_BARRIER);
        (void)I;
        t->info.barrier = true;
    } else if (flags) {
        // memory ordering only: our memory accesses are already serialized (vi_flow.c); a full wait keeps it simple
        vi_instr *I = E(t, VA_NOP); I->is_nop = true; I->flow = 9;
    }
    return sv_new(t, SV_NONE);
}

// One 32-bit word at p + byte_offset (dynamic offsets allowed).
sv *sel_load_word_at(S *t, sv *p, vi_ref byte_offset)
{
    vi_ref o = sv_word(t, p->off, 0);
    vi_ref r = o.kind == VI_IMM && byte_offset.kind == VI_IMM ? vi_imm(o.value + byte_offset.value)
             : o.kind == VI_IMM && o.value == 0 ? byte_offset : sel_alu2(t, VA_IADD_U32, o.kind == VI_IMM ? sel_mov32(t, o) : o, byte_offset);
    sv q = *p;
    q.off = sv_from_comps32(t, 32, 1, &r);
    vi_ref w = load_words(t, &q, 1, 0);
    return sv_from_comps32(t, 32, 1, &w);
}
