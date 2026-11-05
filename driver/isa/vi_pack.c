// Viva ISA compiler: constant lowering, blend-shader prologs, layout and encoding.
#include "vi.h"
#include <stdlib.h>
#include <string.h>
#include "util/ralloc.h"
#include "panfrost/compiler/pan_compiler.h"

// Valhall's hardware constant table (source encoding 0xC0 + i), from Arm's / Mesa's ISA description.
static const uint32_t kTable[32] = {
    0x00000000, 0xFFFFFFFF, 0x7FFFFFFF, 0xFAFCFDFE, 0x01000000, 0x80002000, 0x70605030, 0xC0B0A090,
    0x03020100, 0x07060504, 0x0B0A0908, 0x0F0E0D0C, 0x13121110, 0x17161514, 0x1B1A1918, 0x1F1E1D1C,
    0x3F800000, 0x3DCCCCCD, 0x3EA2F983, 0x3F317218, 0x40490FDB, 0x00000000, 0x477FFF00, 0x5C005BF8,
    0x2E660000, 0x34000000, 0x38000000, 0x3C000000, 0x40000000, 0x44000000, 0x48000000, 0x42480000,
};

int vi_table_index(uint32_t x)
{
    for (int i = 0; i < 32; i++) if (kTable[i] == x) return i;
    return -1;
}

// FAU "slot" of a source: user pair (64-bit) or special entry; -1 for registers / table.
static int fau_slot(const vi_ref *r)
{
    if (r->kind == VI_FAU) return (int)(r->value / 2);
    if (r->kind == VI_SPECIAL) return 0x1000 + r->word * 64 + (int)(r->value / 2);
    return -1;
}

// Immediates: hardware table, else a register (IADD_IMM / MOV_IMM before the instruction). An instruction reads at
// most one 64-bit FAU slot (user pair or special entry, one page): other FAU sources are moved to registers.
bool vi_lower_constants(vi_shader *s)
{
    vi_foreach_block(s, blk) vi_foreach_instr_safe(blk, I) {
        if (I->op == VA_IADD_IMM_I32 || I->op == VA_MOV_IMM_I32) continue;
        int slot = -1;
        vi_ref *refs[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        for (unsigned k = 0; k < 4; k++) {
            vi_ref *r = refs[k];
            if (r->kind == VI_IMM) {
                int t = vi_table_index(r->value);
                if (t >= 0 && r->count <= 1) { r->kind = VI_TABLE; r->value = (uint32_t)t; continue; }
                // a uniform constant (FAU), when this ALU instruction reads no other uniform (one 64-bit slot each)
                if (s->fau && !vi_is_msg(I) && I->op != VA_BLEND && slot < 0 && r->count <= 1) {
                    bool other = false;
                    for (unsigned q = k + 1; q < 4; q++) if (fau_slot(refs[q]) >= 0 || refs[q]->kind == VI_IMM) other = true;
                    if (!other) {
                        struct pan_fau_layout *f = s->fau;
                        int w = -1;
                        for (unsigned i = 0; i < f->count; i++) if (BITSET_TEST(f->is_const, i) && f->words[i].constant == r->value) { w = (int)i; break; }
                        if (w < 0 && f->count < f->max) w = (int)pan_fau_emit_const(f, r->value);
                        if (w >= 0) { *r = vi_fau((unsigned)w); slot = fau_slot(r); continue; }
                    }
                }
                vi_builder b = { s, blk, I };
                uint32_t v = vi_new_vreg(s, 1);
                vi_instr *M = vi_emit(&b, VA_MOV_IMM_I32);
                M->dest = vi_vreg(v, 0, 1);
                vi_set(M, VAF_imm1w, r->value);
                *r = vi_vreg(v, 0, 1);
                continue;
            }
            int fs = fau_slot(r);
            if (fs < 0) continue;
            if (slot < 0 || slot == fs) { slot = fs; continue; }
            vi_builder b = { s, blk, I };
            uint32_t v = vi_new_vreg(s, 1);
            vi_instr *M = vi_emit(&b, VA_MOV_I32);
            M->dest = vi_vreg(v, 0, 1);
            M->src[0] = *r;
            *r = vi_vreg(v, 0, 1);
        }
    }
    return true;
}

static int encode_src(const vi_ref *r, int *page, char *err, size_t errsz)
{
    switch (r->kind) {
    case VI_REG: return VA_SRC_REG(r->value, r->last);
    case VI_TABLE: return VA_SRC_IMM(r->value);
    case VI_FAU: {
        int p = (int)(r->value >> 6);
        if (*page >= 0 && *page != p) { snprintf(err, errsz, "two FAU pages in one instruction"); return -1; }
        *page = p;
        return VA_SRC_FAU(r->value);
    }
    case VI_SPECIAL:
        if (*page >= 0 && *page != r->word) { snprintf(err, errsz, "two FAU pages in one instruction"); return -1; }
        *page = r->word;
        return VA_SRC_SPECIAL(r->value);
    default:
        snprintf(err, errsz, "unlowered source kind %u", r->kind);
        return -1;
    }
}

// Blend shader calls (Valhall ABI, the same sequence Mesa's va_lower_blend emits): BLEND branches over the next two
// instructions when blending is fixed-function; with a blend shader execution continues into
//     IADD_IMM r48, <return address or 0 at the end>     BRANCHZI.absolute <blend descriptor word 1>
static void lower_blend(vi_shader *s)
{
    vi_foreach_block(s, blk) vi_foreach_instr_safe(blk, I) {
        if (I->op != VA_BLEND) continue;
        vi_instr *next = I->link.next == &blk->instrs ? NULL : list_entry(I->link.next, vi_instr, link);
        vi_builder b = { s, blk, next };
        bool end = I->flow == 15;
        vi_instr *A = vi_emit(&b, VA_IADD_IMM_I32);
        A->dest = vi_reg(48);
        if (end) A->src[0] = (vi_ref){ VI_TABLE, 0, 1, false, 0 };
        else A->src[0] = vi_special(3, 30);        // program counter (next instruction)
        vi_set(A, VAF_imm1w, end ? 0 : 2 * 8 - 8);
        vi_instr *J = vi_emit(&b, VA_JUMP);
        J->src[0] = (vi_ref){ VI_TABLE, 0, 1, false, 0 };
        J->src[1] = I->src[3];                     // blend descriptor, word 1: blend shader address
        vi_set(J, VAF_address_mode, 1);            // absolute
        vi_set(J, VAF_combine, 0);
        vi_set(J, VAF_not, 1);                     // .eq: branch when the source is zero
        // BRANCHZI.eq: branch when the source is zero (it is): see va_pack.c's BRANCHZI packing
        I->src[3] = vi_none();
        if (!end) vi_set(I, VAF_offset, 2 * 8);
        else vi_set(I, VAF_offset, 0);
    }
}

bool vi_pack(vi_shader *s, struct util_dynarray *binary)
{
    char err[256];
    if (s->stage == 4 /* MESA_SHADER_FRAGMENT */) lower_blend(s);
    // Layout
    uint32_t pc = 0;
    bool empty = true;
    vi_foreach_block(s, blk) {
        blk->pc = pc;
        vi_foreach_instr(blk, I) { I->pc = pc; pc += 8; empty = false; }
    }
    if (empty) return true;
    unsigned start = binary->size;
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        const struct va_op_info *oi = &va_op_info[I->op];
        va_vals v = I->f;
        int page = -1;
        static const enum va_field srcf[4] = { VAF_src0, VAF_src1, VAF_src2, VAF_src3 };
        for (unsigned k = 0; k < 4; k++) {
            if (!I->src[k].kind) continue;
            int e = encode_src(&I->src[k], &page, err, sizeof err);
            if (e < 0) goto fail;
            va_set(&v, srcf[k], e);
        }
        if (page >= 0 && va_has_field(I->op, VAF_fau_page_index)) va_set(&v, VAF_fau_page_index, page);
        if (I->dest.kind == VI_REG) va_set(&v, VAF_dest_register_index, I->dest.value);
        // Full-width destination unless the selector chose a lane.
        static const enum va_field dw[] = { VAF_dest_width, VAF_dest_width_narrow };
        for (unsigned k = 0; k < 2; k++) if (!v.set[dw[k]] && va_has_field(I->op, dw[k])) va_set(&v, dw[k], 3);
        if (oi->sr_read && oi->sr_write) {
            if (I->sr.kind == VI_REG) va_set(&v, VAF_staging_register_index, I->sr.value);
            if (I->sw.kind == VI_REG) va_set(&v, VAF_staging_register_write_index, I->sw.value);
        } else if (oi->sr_read) {
            if (I->sr.kind == VI_REG) va_set(&v, VAF_staging_register_index, I->sr.value);
        } else if (oi->sr_write) {
            if (I->sw.kind == VI_REG) va_set(&v, VAF_staging_register_index, I->sw.value);
            else if (I->dest.kind == VI_REG && !v.set[VAF_staging_register_index]) va_set(&v, VAF_staging_register_index, I->dest.value);
        }
        // Staging register counts from the operands (sr_count: n, or n % 8 for texture ops; sr_write_count: n - 1).
        {
            unsigned nr = I->sr.kind == VI_REG ? (I->sr.count ? I->sr.count : 1) : 0;
            unsigned nw = I->sw.kind == VI_REG ? (I->sw.count ? I->sw.count : 1) : 0;
            bool has_w = va_has_field(I->op, VAF_sr_write_count);
            if (va_has_field(I->op, VAF_sr_count) && !v.set[VAF_sr_count]) {
                unsigned n = has_w || oi->sr_read ? nr : nw;
                if (n) va_set(&v, VAF_sr_count, n & 7);
            }
            if (has_w && nw && !v.set[VAF_sr_write_count]) va_set(&v, VAF_sr_write_count, nw - 1);
        }
        va_set(&v, VAF_flow, I->flow);
        if (I->slot >= 0 && va_has_field(I->op, VAF_message_slot_index) && !v.set[VAF_message_slot_index])
            va_set(&v, VAF_message_slot_index, I->slot);
        if (I->target) {
            // Relative branch, in bytes from the next instruction.
            vi_block *t = I->target;
            int64_t off = (int64_t)t->pc - (int64_t)(I->pc + 8);
            va_set(&v, VAF_offset, off);
        }
        uint64_t w;
        if (va_encode(I->op, &v, &w, err, sizeof err)) goto fail;
        util_dynarray_append(binary, w);
    }
    {
        // Zero padding (keeps the prefetcher on valid words), aligned like Mesa: +16 bytes, up to 128.
        unsigned size = binary->size;
        unsigned aligned = (size + 16 + 127) & ~127u;
        memset(util_dynarray_grow(binary, uint8_t, aligned - size), 0, aligned - size);
    }
    (void)start;
    return true;
fail:
    free(s->error);
    s->error = strdup(err);
    return false;
}
