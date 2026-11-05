// Viva ISA compiler: IR construction and printing.
#include "vi.h"
#include <stdlib.h>
#include <string.h>
#include "util/ralloc.h"

vi_shader *vi_shader_create(int stage)
{
    void *mem = ralloc_context(NULL);
    vi_shader *s = rzalloc(mem, vi_shader);
    s->mem = mem;
    s->stage = stage;
    list_inithead(&s->blocks);
    util_dynarray_init(&s->vregs, mem);
    return s;
}

void vi_shader_free(vi_shader *s)
{
    if (!s) return;
    free(s->error);
    ralloc_free(s->mem);
}

vi_block *vi_block_create(vi_shader *s)
{
    vi_block *b = rzalloc(s->mem, vi_block);
    list_inithead(&b->instrs);
    util_dynarray_init(&b->preds, s->mem);
    b->index = s->nblocks++;
    list_addtail(&b->link, &s->blocks);
    return b;
}

void vi_block_add_succ(vi_block *from, vi_block *to)
{
    if (!to || from->succ[0] == to || from->succ[1] == to) return;
    if (!from->succ[0]) from->succ[0] = to;
    else from->succ[1] = to;
    util_dynarray_append(&to->preds, from);
}

uint32_t vi_new_vreg(vi_shader *s, unsigned nwords)
{
    vi_vreg_info v = { (uint8_t)nwords, (uint8_t)(nwords > 1 ? 2 : 1), -1, -1, false };
    util_dynarray_append(&s->vregs, v);
    return vi_num_vregs(s) - 1;
}

vi_instr *vi_emit(vi_builder *b, enum va_op op)
{
    vi_instr *I = rzalloc(b->s->mem, vi_instr);
    I->op = op;
    I->slot = -1;
    va_vals_init(&I->f);
    if (b->before) list_addtail(&I->link, &b->before->link);
    else list_addtail(&I->link, &b->block->instrs);
    return I;
}

static void print_ref(FILE *fp, vi_ref r)
{
    switch (r.kind) {
    case VI_VREG: fprintf(fp, "v%u", r.value); if (r.word || r.count > 1) fprintf(fp, "[%u:%u]", r.word, r.word + (r.count ? r.count : 1) - 1); break;
    case VI_REG: fprintf(fp, "r%u", r.value); if (r.count > 1) fprintf(fp, ":r%u", r.value + r.count - 1); break;
    case VI_FAU: fprintf(fp, "u%u.w%u", r.value / 2, r.value & 1); break;
    case VI_IMM: fprintf(fp, "#0x%x", r.value); break;
    case VI_SPECIAL: fprintf(fp, "special%u.%u", r.word, r.value); break;
    case VI_TABLE: fprintf(fp, "lut%u", r.value); break;
    default: fprintf(fp, "_"); break;
    }
    if (r.last) fprintf(fp, "^");
}

void vi_print(vi_shader *s, FILE *fp)
{
    vi_foreach_block(s, blk) {
        fprintf(fp, "block%u", blk->index);
        if (blk->succ[0] || blk->succ[1]) fprintf(fp, " -> %d %d", blk->succ[0] ? (int)blk->succ[0]->index : -1, blk->succ[1] ? (int)blk->succ[1]->index : -1);
        fprintf(fp, ":\n");
        vi_foreach_instr(blk, I) {
            const struct va_op_info *oi = &va_op_info[I->op];
            fprintf(fp, "    %s%s%s", oi->name, oi->variant ? "." : "", oi->variant ? oi->variant : "");
            if (I->flow) fprintf(fp, ".flow%u", I->flow);
            if (I->slot >= 0) fprintf(fp, ".slot%d", I->slot);
            fprintf(fp, " ");
            if (I->dest.kind) { print_ref(fp, I->dest); fprintf(fp, " = "); }
            if (I->sw.kind) { fprintf(fp, "@"); print_ref(fp, I->sw); fprintf(fp, " = "); }
            if (I->sr.kind) { fprintf(fp, "@"); print_ref(fp, I->sr); fprintf(fp, ", "); }
            for (unsigned k = 0; k < 4; k++) if (I->src[k].kind) { print_ref(fp, I->src[k]); fprintf(fp, ", "); }
            for (unsigned f = 0; f < VAF_COUNT; f++) if (I->f.set[f]) fprintf(fp, "%s=%lld ", va_field_name[f], (long long)I->f.v[f]);
            if (I->target) fprintf(fp, "-> block%u", I->target->index);
            fprintf(fp, "\n");
        }
    }
}
