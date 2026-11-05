// Viva ISA compiler: copy propagation and dead code elimination on the Valhall IR (before register allocation).
//
// Copy propagation replaces the uses of `MOV.i32 v = x` (v a single-definition one-word register) by x when x is a
// single-definition register word, or (in ALU instructions only) a uniform / constant. Staging operands and
// 64-bit pairs keep their registers (they must be contiguous vectors). Dead code elimination removes
// instructions without side effects whose results are never read; that is also how the IDVS position and
// varying programs lose each other's work.
#include "vi.h"
#include <stdlib.h>
#include <string.h>
#include "util/macros.h"

static bool side_effects(const vi_instr *I)
{
    if (I->is_nop || I->target || I->flow) return true;
    switch (I->op) {
    case VA_BLEND: case VA_ATEST: case VA_ZS_EMIT: case VA_BARRIER: case VA_DISCARD_F32: case VA_ST_CVT: case VA_ST_TILE:
    case VA_STORE_I8: case VA_STORE_I16: case VA_STORE_I24: case VA_STORE_I32: case VA_STORE_I48: case VA_STORE_I64:
    case VA_STORE_I96: case VA_STORE_I128: case VA_ATOM_I32: case VA_ATOM_I64: case VA_ATOM_RETURN_I32: case VA_ATOM_RETURN_I64:
    case VA_ATOM1_I32: case VA_ATOM1_I64: case VA_ATOM1_RETURN_I32: case VA_ATOM1_RETURN_I64: case VA_AXCHG_I32: case VA_AXCHG_I64:
    case VA_ACMPXCHG_I32: case VA_ACMPXCHG_I64: case VA_BRANCH: case VA_JUMP: case VA_NOP:
        return true;
    default:
        return false;
    }
}

typedef struct { unsigned defs; vi_instr *def; unsigned uses; } vinfo;

// Per word of every register: number of definitions and the (last) defining instruction.
typedef struct { unsigned *base; unsigned *wdefs; vi_instr **wdef; } winfo;

static void count(vi_shader *s, vinfo *vi, winfo *wi)
{
    unsigned n = vi_num_vregs(s);
    memset(vi, 0, n * sizeof *vi);
    unsigned total = 0;
    for (unsigned v = 0; v < n; v++) { wi->base[v] = total; total += vi_vreg_get(s, v)->nwords; }
    memset(wi->wdefs, 0, total * sizeof *wi->wdefs);
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        vi_ref *w[2] = { &I->dest, &I->sw };
        for (unsigned k = 0; k < 2; k++) {
            if (w[k]->kind != VI_VREG) continue;
            vi[w[k]->value].defs++; vi[w[k]->value].def = I;
            unsigned cnt = w[k]->count ? w[k]->count : 1;
            for (unsigned q = 0; q < cnt; q++) {
                unsigned idx = wi->base[w[k]->value] + w[k]->word + q;
                wi->wdefs[idx]++; wi->wdef[idx] = I;
            }
        }
        vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        for (unsigned k = 0; k < 5; k++) if (r[k]->kind == VI_VREG) vi[r[k]->value].uses++;
    }
}

// The single MOV that defines word w of v, or NULL.
static vi_instr *word_mov(vi_shader *s, winfo *wi, uint32_t v, unsigned w)
{
    if (vi_vreg_get(s, v)->multi_def || vi_vreg_get(s, v)->fixed >= 0) return NULL;
    unsigned idx = wi->base[v] + w;
    if (wi->wdefs[idx] != 1) return NULL;
    vi_instr *D = wi->wdef[idx];
    if (D->op != VA_MOV_I32 || D->dest.kind != VI_VREG || (D->dest.count && D->dest.count != 1) || D->f.set[VAF_dest_width]) return NULL;
    return D;
}

static bool stable_word(vi_shader *s, winfo *wi, vi_ref x)
{
    if (x.kind != VI_VREG) return false;
    if (vi_vreg_get(s, x.value)->multi_def) return false;
    return wi->wdefs[wi->base[x.value] + x.word] == 1;
}

static bool copy_prop(vi_shader *s, vinfo *vi, winfo *wi)
{
    (void)vi;
    bool progress = false;
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        bool msg = vi_is_msg(I);
        for (unsigned k = 0; k < 4; k++) {
            vi_ref *r = &I->src[k];
            if (r->kind != VI_VREG) continue;
            unsigned cnt = r->count ? r->count : 1;
            if (cnt > 1) {
                // a pair (64-bit source) whose words are copies of consecutive words of one register
                vi_instr *D0 = word_mov(s, wi, r->value, r->word);
                if (!D0 || !stable_word(s, wi, D0->src[0])) continue;
                vi_ref first = D0->src[0];
                bool ok = (first.word % 2) == 0 && vi_vreg_get(s, first.value)->nwords >= first.word + cnt;
                for (unsigned q = 1; q < cnt && ok; q++) {
                    vi_instr *Dq = word_mov(s, wi, r->value, r->word + q);
                    ok = Dq && Dq->src[0].kind == VI_VREG && Dq->src[0].value == first.value && Dq->src[0].word == first.word + q &&
                         stable_word(s, wi, Dq->src[0]);
                }
                if (!ok) continue;
                r->value = first.value; r->word = first.word;
                progress = true;
                continue;
            }
            vi_instr *D = word_mov(s, wi, r->value, r->word);
            if (!D) continue;
            vi_ref x = D->src[0];
            if (x.kind == VI_VREG) {
                if (!stable_word(s, wi, x)) continue;
                x.count = 1; x.last = false;
            } else if (x.kind == VI_FAU || x.kind == VI_SPECIAL || x.kind == VI_IMM) {
                if (msg || I->op == VA_BLEND) continue;
                bool other = false;
                for (unsigned q = 0; q < 4; q++) if (q != k && (I->src[q].kind == VI_FAU || I->src[q].kind == VI_SPECIAL)) other = true;
                if (other && x.kind != VI_IMM) continue;
                if (x.kind == VI_SPECIAL && x.word == 3) continue;
            } else continue;
            *r = x;
            progress = true;
        }
        // whole staging vectors: every word a copy of the matching word of one register
        vi_ref *sr = &I->sr;
        if (sr->kind == VI_VREG && sr->word == 0) {
            unsigned cnt = sr->count ? sr->count : 1;
            vi_vreg_info *info = vi_vreg_get(s, sr->value);
            if (info->nwords != cnt || info->fixed >= 0) continue;
            vi_instr *D0 = word_mov(s, wi, sr->value, 0);
            if (!D0 || D0->src[0].kind != VI_VREG || D0->src[0].word != 0 || !stable_word(s, wi, D0->src[0])) continue;
            uint32_t u = D0->src[0].value;
            vi_vreg_info *ui = vi_vreg_get(s, u);
            if (ui->nwords != cnt || ui->fixed >= 0) continue;
            bool ok = true;
            for (unsigned q = 1; q < cnt && ok; q++) {
                vi_instr *Dq = word_mov(s, wi, sr->value, q);
                ok = Dq && Dq->src[0].kind == VI_VREG && Dq->src[0].value == u && Dq->src[0].word == q && stable_word(s, wi, Dq->src[0]);
            }
            if (!ok) continue;
            sr->value = u;
            progress = true;
        }
    }
    return progress;
}

static bool dce(vi_shader *s, vinfo *vi)
{
    bool progress = false;
    vi_foreach_block(s, blk) vi_foreach_instr_safe(blk, I) {
        if (side_effects(I)) continue;
        bool used = false, any = false;
        vi_ref *w[2] = { &I->dest, &I->sw };
        for (unsigned k = 0; k < 2; k++) {
            if (w[k]->kind == VI_REG) used = true;    // writes a fixed register (ABI)
            if (w[k]->kind == VI_VREG) { any = true; if (vi[w[k]->value].uses) used = true; }
        }
        if (!any || used) continue;
        list_del(&I->link);
        progress = true;
    }
    return progress;
}

// Unconditional branches (BRANCHZ.eq #0) to the next block in the layout: fall through instead.
static void drop_fallthrough_jumps(vi_shader *s)
{
    vi_foreach_block(s, blk) {
        if (list_is_empty(&blk->instrs)) continue;
        vi_instr *I = list_last_entry(&blk->instrs, vi_instr, link);
        if (I->op != VA_BRANCH || !I->target || I->src[0].kind != VI_IMM || I->src[0].value != 0 || !I->f.set[VAF_not]) continue;
        // next block with instructions or the target itself
        struct list_head *l = blk->link.next;
        bool next = false;
        while (l != &s->blocks) {
            vi_block *b = list_entry(l, vi_block, link);
            if (b == I->target) { next = true; break; }
            if (!list_is_empty(&b->instrs)) break;
            l = l->next;
        }
        if (next) list_del(&I->link);
    }
}

void vi_if_convert(vi_shader *s);
void vi_merge_blocks(vi_shader *s);
void vi_fuse_fma(vi_shader *s);
void vi_remat(vi_shader *s);

void vi_optimize(vi_shader *s)
{
    vi_if_convert(s);
    vi_merge_blocks(s);
    drop_fallthrough_jumps(s);
    // sizes after if-conversion (it creates registers)
    unsigned n = vi_num_vregs(s), words = 0;
    for (unsigned v = 0; v < n; v++) words += vi_vreg_get(s, v)->nwords;
    // phi registers left with one definition (after if-conversion) are ordinary values
    {
        unsigned *defs = calloc(n ? n : 1, sizeof *defs);
        vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
            if (I->dest.kind == VI_VREG) defs[I->dest.value]++;
            if (I->sw.kind == VI_VREG) defs[I->sw.value]++;
        }
        for (unsigned v = 0; v < n; v++) {
            vi_vreg_info *vi2 = vi_vreg_get(s, v);
            if (vi2->multi_def && defs[v] == 1 && vi2->nwords == 1) vi2->multi_def = false;
        }
        free(defs);
    }
    vinfo *vi = malloc((n ? n : 1) * sizeof *vi);
    winfo wi = { malloc((n ? n : 1) * sizeof(unsigned)), malloc((words ? words : 1) * sizeof(unsigned)), malloc((words ? words : 1) * sizeof(vi_instr *)) };
    for (unsigned iter = 0; iter < 16; iter++) {
        count(s, vi, &wi);
        bool p = copy_prop(s, vi, &wi);
        count(s, vi, &wi);
        p |= dce(s, vi);
        if (!p) break;
    }
    vi_fuse_fma(s);
    vi_remat(s);
    free(vi); free(wi.base); free(wi.wdefs); free(wi.wdef);
}

// ---- Pressure scheduling ----------------------------------------------------------------------------------------------
// Moves every instruction without side effects down to just before its first use in the block (LLVM tends to hoist
// all texture samples of a blur to the top, keeping every result alive at once). Operands must be single-definition
// registers or constants, so moving the instruction later reads the same values; results used in other blocks stay.

static bool movable(vi_shader *s, vi_instr *I)
{
    if (side_effects(I) || I->memory || I->varying || I->blend) return false;
    if (I->op == VA_CLPER || I->op == VA_WMASK) return false;   // lane operations: keep the active set as written
    vi_ref *w[2] = { &I->dest, &I->sw };
    bool any = false;
    for (unsigned k = 0; k < 2; k++) {
        if (w[k]->kind == VI_REG) return false;
        if (w[k]->kind == VI_VREG) {
            vi_vreg_info *vi = vi_vreg_get(s, w[k]->value);
            if (vi->multi_def || vi->fixed >= 0) return false;
            any = true;
        }
    }
    if (!any) return false;
    vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
    for (unsigned k = 0; k < 5; k++) {
        if (r[k]->kind == VI_REG) return false;
        if (r[k]->kind == VI_VREG && vi_vreg_get(s, r[k]->value)->multi_def) return false;
    }
    return true;
}

static bool reads_vreg_of(const vi_instr *U, const vi_instr *I)
{
    const vi_ref *w[2] = { &I->dest, &I->sw };
    const vi_ref *r[5] = { &U->src[0], &U->src[1], &U->src[2], &U->src[3], &U->sr };
    for (unsigned a = 0; a < 2; a++) {
        if (w[a]->kind != VI_VREG) continue;
        for (unsigned b = 0; b < 5; b++) if (r[b]->kind == VI_VREG && r[b]->value == w[a]->value) return true;
    }
    // another definition of the same register (vectors built word by word): keep the order
    const vi_ref *uw[2] = { &U->dest, &U->sw };
    for (unsigned a = 0; a < 2; a++) for (unsigned b = 0; b < 2; b++)
        if (w[a]->kind == VI_VREG && uw[b]->kind == VI_VREG && uw[b]->value == w[a]->value) return true;
    return false;
}

// Dominators (dom) and post-dominators (pdom) as bit sets over block indices.
typedef struct { unsigned n; BITSET_WORD *dom, *pdom; vi_block **blk; } domtree;

static void compute_dom(vi_shader *s, domtree *d)
{
    unsigned n = 0;
    vi_foreach_block(s, b) n = MAX2(n, b->index + 1);
    unsigned w = BITSET_WORDS(n);
    d->n = n;
    d->dom = calloc((size_t)n * w, sizeof(BITSET_WORD));
    d->pdom = calloc((size_t)n * w, sizeof(BITSET_WORD));
    d->blk = calloc(n, sizeof(vi_block *));
    vi_block *entry = list_first_entry(&s->blocks, vi_block, link);
    vi_foreach_block(s, b) {
        d->blk[b->index] = b;
        BITSET_WORD *D = d->dom + b->index * w, *P = d->pdom + b->index * w;
        if (b == entry) BITSET_SET(D, b->index); else memset(D, 0xff, w * sizeof(BITSET_WORD));
        if (!b->succ[0] && !b->succ[1]) BITSET_SET(P, b->index); else memset(P, 0xff, w * sizeof(BITSET_WORD));
    }
    BITSET_WORD *tmp = malloc(w * sizeof(BITSET_WORD));
    bool progress = true;
    while (progress) {
        progress = false;
        vi_foreach_block(s, b) {
            if (b == entry) continue;
            memset(tmp, 0xff, w * sizeof(BITSET_WORD));
            bool anyp = false;
            util_dynarray_foreach(&b->preds, vi_block *, p) { anyp = true; for (unsigned k = 0; k < w; k++) tmp[k] &= d->dom[(*p)->index * w + k]; }
            if (!anyp) memset(tmp, 0, w * sizeof(BITSET_WORD));
            BITSET_SET(tmp, b->index);
            if (memcmp(tmp, d->dom + b->index * w, w * sizeof(BITSET_WORD))) { memcpy(d->dom + b->index * w, tmp, w * sizeof(BITSET_WORD)); progress = true; }
        }
        vi_foreach_block_rev(s, b) {
            if (!b->succ[0] && !b->succ[1]) continue;
            memset(tmp, 0xff, w * sizeof(BITSET_WORD));
            for (unsigned q = 0; q < 2; q++) if (b->succ[q]) for (unsigned k = 0; k < w; k++) tmp[k] &= d->pdom[b->succ[q]->index * w + k];
            BITSET_SET(tmp, b->index);
            if (memcmp(tmp, d->pdom + b->index * w, w * sizeof(BITSET_WORD))) { memcpy(d->pdom + b->index * w, tmp, w * sizeof(BITSET_WORD)); progress = true; }
        }
    }
    free(tmp);
}

// a and b execute under the same condition: a dominates b and b post-dominates a.
static bool control_equivalent(domtree *d, vi_block *a, vi_block *b)
{
    unsigned w = BITSET_WORDS(d->n);
    return BITSET_TEST(d->dom + b->index * w, a->index) && BITSET_TEST(d->pdom + a->index * w, b->index);
}

static bool in_loop(vi_block *b) { (void)b; return false; }

void vi_schedule_blocks(vi_shader *s);

// ---- Sinking ----------------------------------------------------------------------------------------------------------
// Bottom-up from the end of each block, an instruction moves down to just before the first instruction that reads it,
// when that does not lengthen the life of its operands (each is read again at or after the new place, or is the
// single-use result of an instruction that will follow it down). Texture samples and loads move too, but not across
// stores or other side effects. A blur that samples everything first and accumulates at the end becomes
// sample-and-accumulate, one texture at a time; the list scheduler then only refines.
static bool sink_barrier(const vi_instr *I)
{
    return side_effects(I) || I->blend || I->clobber || I->varying || (I->memory && side_effects(I)) ||
           I->op == VA_CLPER || I->op == VA_WMASK || I->is_nop;
}

static bool sinkable(vi_shader *s, vi_instr *I)
{
    if (side_effects(I) || I->varying || I->blend || I->clobber || I->helpers || I->is_nop) return false;
    if (I->op == VA_CLPER || I->op == VA_WMASK) return false;
    bool any = false;
    vi_ref *w[2] = { &I->dest, &I->sw };
    for (unsigned k = 0; k < 2; k++) {
        if (w[k]->kind == VI_REG) return false;
        if (w[k]->kind == VI_VREG) {
            vi_vreg_info *vi = vi_vreg_get(s, w[k]->value);
            if (vi->multi_def || vi->fixed >= 0) return false;
            any = true;
        }
    }
    if (!any) return false;
    vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
    for (unsigned k = 0; k < 5; k++) {
        if (r[k]->kind == VI_REG) return false;
        if (r[k]->kind == VI_VREG && vi_vreg_get(s, r[k]->value)->multi_def) return false;
    }
    return true;
}

static bool reads_v(const vi_instr *J, uint32_t v)
{
    const vi_ref *r[5] = { &J->src[0], &J->src[1], &J->src[2], &J->src[3], &J->sr };
    for (unsigned k = 0; k < 5; k++) if (r[k]->kind == VI_VREG && r[k]->value == v) return true;
    return false;
}

void vi_sink(vi_shader *s)
{
    if (getenv("VMG_ISA_NO_SINK")) return;
    vi_liveness(s);
    unsigned n = vi_num_vregs(s);
    unsigned *uses = calloc(n ? n : 1, sizeof *uses), *defs = calloc(n ? n : 1, sizeof *defs);
    vi_instr **def = calloc(n ? n : 1, sizeof *def);
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        for (unsigned k = 0; k < 5; k++) if (r[k]->kind == VI_VREG) {
            bool seen = false;   // readers, not reads: x * x is one use
            for (unsigned k2 = 0; k2 < k; k2++) if (r[k2]->kind == VI_VREG && r[k2]->value == r[k]->value) seen = true;
            if (!seen) uses[r[k]->value]++;
        }
        vi_ref *w[2] = { &I->dest, &I->sw };
        for (unsigned k = 0; k < 2; k++) if (w[k]->kind == VI_VREG) { defs[w[k]->value]++; def[w[k]->value] = I; }
    }
    vi_foreach_block(s, blk) {
        vi_instr *I = list_is_empty(&blk->instrs) ? NULL : list_last_entry(&blk->instrs, vi_instr, link);
        while (I) {
            vi_instr *prev = I->link.prev == &blk->instrs ? NULL : list_entry(I->link.prev, vi_instr, link);
            if (!sinkable(s, I)) { I = prev; continue; }
            // first reader in the block, with no barrier for a memory read on the way
            vi_ref *w[2] = { &I->dest, &I->sw };
            vi_instr *U = NULL;
            bool blocked = false;
            for (struct list_head *l = I->link.next; l != &blk->instrs && !U; l = l->next) {
                vi_instr *J = list_entry(l, vi_instr, link);
                for (unsigned k = 0; k < 2; k++) if (w[k]->kind == VI_VREG && reads_v(J, w[k]->value)) U = J;
                if (!U && (J->target || (I->memory && sink_barrier(J)))) { blocked = true; break; }
            }
            if (blocked || !U || I->link.next == &U->link) { I = prev; continue; }
            // operands must stay alive down there anyway
            bool ok = true;
            vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
            for (unsigned k = 0; k < 5 && ok; k++) {
                if (r[k]->kind != VI_VREG) continue;
                uint32_t x = r[k]->value;
                bool later = false;
                for (unsigned q = 0; q < vi_vreg_get(s, x)->nwords && !later; q++)
                    if (BITSET_TEST(blk->live_out, s->live_base[x] + q)) later = true;
                for (struct list_head *l = &U->link; l != &blk->instrs && !later; l = l->next) {
                    vi_instr *J = list_entry(l, vi_instr, link);
                    if (J != I && reads_v(J, x)) later = true;
                }
                if (later) continue;
                // read only here, and every definition (a vector may be built word by word) is an instruction of
                // this block above I that can follow
                bool follows = uses[x] == 1;
                unsigned found = 0;
                for (struct list_head *l = blk->instrs.next; l != &I->link && follows; l = l->next) {
                    vi_instr *D = list_entry(l, vi_instr, link);
                    if ((D->dest.kind == VI_VREG && D->dest.value == x) || (D->sw.kind == VI_VREG && D->sw.value == x)) {
                        found++;
                        if (!sinkable(s, D)) follows = false;
                    }
                }
                if (!follows || found != defs[x]) ok = false;
            }
            if (getenv("VMG_ISA_DEBUG_SINK")) { fprintf(stderr, "sink %s %s: ", ok ? "MOVE" : "keep", va_op_info[I->op].name); vi_print_instr(I, stderr); }
            if (ok) { list_del(&I->link); list_addtail(&I->link, &U->link); }
            I = prev;
        }
    }
    free(uses); free(defs); free(def);
}

void vi_schedule_pressure(vi_shader *s)
{
    unsigned n = vi_num_vregs(s);
    int *home = malloc((n ? n : 1) * sizeof *home), *user = malloc((n ? n : 1) * sizeof *user);
    for (unsigned v = 0; v < n; v++) { home[v] = -1; user[v] = -2; }   // user: -2 none, -1 several blocks, else the block
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        vi_ref *w[2] = { &I->dest, &I->sw };
        for (unsigned k = 0; k < 2; k++) if (w[k]->kind == VI_VREG) home[w[k]->value] = (int)blk->index;
        vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        for (unsigned k = 0; k < 5; k++) {
            if (r[k]->kind != VI_VREG) continue;
            int *u = &user[r[k]->value];
            if (*u == -2) *u = (int)blk->index; else if (*u != (int)blk->index) *u = -1;
        }
    }
    domtree d;
    compute_dom(s, &d);
    // 1. Across blocks: an instruction whose results are read in one control-equivalent later block moves there
    //    (its operands are single-definition registers defined at or before it, so they dominate the new place).
    for (unsigned round = 0; round < 4; round++) {
        bool moved = false;
        vi_foreach_block(s, blk) {
            vi_instr *I = list_is_empty(&blk->instrs) ? NULL : list_last_entry(&blk->instrs, vi_instr, link);
            while (I) {
                vi_instr *prev = I->link.prev == &blk->instrs ? NULL : list_entry(I->link.prev, vi_instr, link);
                int target = -2;
                vi_ref *w[2] = { &I->dest, &I->sw };
                bool ok = movable(s, I);
                for (unsigned k = 0; k < 2 && ok; k++) {
                    if (w[k]->kind != VI_VREG) continue;
                    int u = user[w[k]->value];
                    if (u < 0 || u == (int)blk->index) ok = false;
                    else if (target == -2) target = u;
                    else if (target != u) ok = false;
                }
                if (ok && target >= 0 && d.blk[target] && control_equivalent(&d, blk, d.blk[target]) && !in_loop(d.blk[target])) {
                    vi_block *T = d.blk[target];
                    list_del(&I->link);
                    // before the first instruction of T that reads it
                    vi_instr *U = NULL;
                    vi_foreach_instr(T, J) if (reads_vreg_of(J, I) || J->target) { U = J; break; }
                    if (U) list_addtail(&I->link, &U->link); else list_addtail(&I->link, &T->instrs);
                    for (unsigned k = 0; k < 2; k++) if (w[k]->kind == VI_VREG) home[w[k]->value] = target;
                    // its operands are now read in T too
                    vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
                    for (unsigned k = 0; k < 5; k++) if (r[k]->kind == VI_VREG) {
                        int *u = &user[r[k]->value];
                        if (*u == (int)blk->index) {
                            // still read here by someone else? conservatively: several blocks
                            bool other = false;
                            vi_foreach_instr(blk, J) { vi_ref *q[5] = { &J->src[0], &J->src[1], &J->src[2], &J->src[3], &J->sr };
                                for (unsigned z = 0; z < 5; z++) if (q[z]->kind == VI_VREG && q[z]->value == r[k]->value) other = true; }
                            *u = other ? -1 : target;
                        } else if (*u != target) *u = -1;
                    }
                    moved = true;
                }
                I = prev;
            }
        }
        if (!moved) break;
    }
    free(d.dom); free(d.pdom); free(d.blk);
    bool *escapes = NULL;
    vi_schedule_blocks(s);
    free(home); free(user); free(escapes);
}

// ---- If-conversion ------------------------------------------------------------------------------------------------------
// A two-sided branch whose sides are short straight-line ALU code (block chains with single predecessors and
// successors) that meet again becomes straight-line code: both sides are computed, and the registers they assign
// for the join (phi variables) take the side's value with CSEL. Removes divergence and keeps values from living
// across branches (as Mesa's peephole select does on NIR).

#define IFCVT_MAX 48

static bool ifcvt_ok(vi_instr *I)
{
    if (I->is_nop || I->flow || I->target || vi_is_msg(I) || side_effects(I)) return false;
    if (I->dest.kind == VI_REG) return false;
    return true;
}

// Follows single-predecessor / single-successor blocks from `b`; returns the join block and the instruction count
// (unconditional branches excluded), or NULL when the chain is not convertible.
static vi_block *side_chain(vi_block *b, vi_block **chain, unsigned *nchain, unsigned *ninstr)
{
    *nchain = 0; *ninstr = 0;
    for (unsigned guard = 0; guard < 8; guard++) {
        if (util_dynarray_num_elements(&b->preds, vi_block *) != 1 || b->succ[1] || !b->succ[0]) return NULL;
        chain[(*nchain)++] = b;
        vi_foreach_instr(b, I) {
            if (I->op == VA_BRANCH && I->target && I->src[0].kind == VI_IMM && I->src[0].value == 0 && I->f.set[VAF_not]) continue;
            if (!ifcvt_ok(I)) return NULL;
            if (++*ninstr > IFCVT_MAX) return NULL;
        }
        vi_block *n = b->succ[0];
        if (util_dynarray_num_elements(&n->preds, vi_block *) > 1) return n;   // the join
        b = n;
    }
    return NULL;
}

static void remove_pred(vi_block *b, vi_block *p)
{
    unsigned n = util_dynarray_num_elements(&b->preds, vi_block *);
    vi_block **a = util_dynarray_begin(&b->preds);
    for (unsigned i = 0; i < n; i++) if (a[i] == p) { a[i] = a[n - 1]; util_dynarray_pop(&b->preds, vi_block *); return; }
}

static bool if_convert_one(vi_shader *s, vi_block *h)
{
    if (!h->succ[0] || !h->succ[1] || list_is_empty(&h->instrs)) return false;
    vi_instr *br = list_last_entry(&h->instrs, vi_instr, link);
    if (br->op != VA_BRANCH || !br->target || br->src[0].kind != VI_VREG) return false;
    // BRANCHZ.eq cond: taken (to target) when cond == 0; .ne form (no `not`): taken when cond != 0
    bool taken_on_zero = br->f.set[VAF_not] && br->f.v[VAF_not];
    vi_block *taken = br->target, *fall = h->succ[0] == taken ? h->succ[1] : h->succ[0];
    vi_block *ct[8], *cf[8];
    unsigned nt, nf, it, itf;
    vi_block *jt = side_chain(fall, ct, &nt, &it), *jf = side_chain(taken, cf, &nf, &itf);
    // triangle: one side jumps straight to the join
    if (!jt && fall == jf) { jt = jf; nt = 0; it = 0; }
    if (!jf && taken == jt) { jf = jt; nf = 0; itf = 0; }
    if (!jt || jt != jf || jt == h) return false;
    vi_block *join = jt;
    vi_ref cond = br->src[0];
    // "true side" = executed when cond != 0
    vi_block **side_nz = taken_on_zero ? ct : cf, **side_z = taken_on_zero ? cf : ct;
    unsigned n_nz = taken_on_zero ? nt : nf, n_z = taken_on_zero ? nf : nt;
    // registers assigned for the join: multi-definition registers written in a side
    struct { uint32_t v; unsigned word; vi_ref nz, z; } sel[64];
    unsigned nsel = 0;
    vi_block **sides[2] = { side_nz, side_z };
    unsigned ns[2] = { n_nz, n_z };
    for (unsigned sidx = 0; sidx < 2; sidx++) for (unsigned k = 0; k < ns[sidx]; k++) vi_foreach_instr(sides[sidx][k], I) {
        vi_ref *w[2] = { &I->dest, &I->sw };
        for (unsigned q = 0; q < 2; q++) {
            if (w[q]->kind != VI_VREG || !vi_vreg_get(s, w[q]->value)->multi_def) continue;
            if ((w[q]->count ? w[q]->count : 1) != 1) return false;
            unsigned e = 0;
            for (; e < nsel; e++) if (sel[e].v == w[q]->value && sel[e].word == w[q]->word) break;
            if (e == nsel) { if (nsel == 64) return false; sel[nsel].v = w[q]->value; sel[nsel].word = w[q]->word; sel[nsel].nz = sel[nsel].z = vi_none(); nsel++; }
        }
    }
    // rename side writes of those registers to temporaries (the last write of each side wins)
    vi_builder b = { s, h, br };
    for (unsigned sidx = 0; sidx < 2; sidx++) for (unsigned k = 0; k < ns[sidx]; k++) {
        vi_foreach_instr_safe(sides[sidx][k], I) {
            if (I->op == VA_BRANCH) { list_del(&I->link); continue; }
            vi_ref *w[2] = { &I->dest, &I->sw };
            for (unsigned q = 0; q < 2; q++) {
                if (w[q]->kind != VI_VREG || !vi_vreg_get(s, w[q]->value)->multi_def) continue;
                for (unsigned e = 0; e < nsel; e++) if (sel[e].v == w[q]->value && sel[e].word == w[q]->word) {
                    uint32_t tmp = vi_new_vreg(s, 1);
                    *w[q] = vi_vreg(tmp, 0, 1);
                    if (sidx == 0) sel[e].nz = *w[q]; else sel[e].z = *w[q];
                }
            }
            // reads of a renamed register later in the same side read the temporary
            list_del(&I->link);
            list_addtail(&I->link, &br->link);
        }
    }
    // (reads of phi registers inside a side see the value before the branch: sides only write them through copies
    //  at their end, which the selector emits last, so no side reads its own write)
    for (unsigned e = 0; e < nsel; e++) {
        vi_ref old = vi_vreg(sel[e].v, sel[e].word, 1);
        vi_ref x = sel[e].nz.kind ? sel[e].nz : old, y = sel[e].z.kind ? sel[e].z : old;
        vi_instr *C = vi_emit(&b, VA_CSEL_U32);
        C->dest = old; C->src[0] = cond; C->src[1] = vi_imm(0); C->src[2] = x; C->src[3] = y;
        va_set(&C->f, VAF_cmpf, VA_CMPF_M_NE);
    }
    list_del(&br->link);
    // CFG: h -> join
    for (unsigned sidx = 0; sidx < 2; sidx++) for (unsigned k = 0; k < ns[sidx]; k++) {
        vi_block *x = sides[sidx][k];
        if (x->succ[0]) remove_pred(x->succ[0], x);
        x->succ[0] = x->succ[1] = NULL;
        util_dynarray_clear(&x->preds);
    }
    remove_pred(h->succ[0], h);
    remove_pred(h->succ[1], h);
    h->succ[0] = h->succ[1] = NULL;
    vi_block_add_succ(h, join);
    // fall into the join, or jump
    struct list_head *l = h->link.next;
    bool next = false;
    while (l != &s->blocks) {
        vi_block *nb = list_entry(l, vi_block, link);
        if (nb == join) { next = true; break; }
        if (!list_is_empty(&nb->instrs) || util_dynarray_num_elements(&nb->preds, vi_block *)) break;
        l = l->next;
    }
    if (!next) {
        vi_builder e = { s, h, NULL };
        vi_instr *J = vi_emit(&e, VA_BRANCH);
        J->src[0] = vi_imm(0); va_set(&J->f, VAF_not, 1); J->target = join;
    }
    return true;
}

void vi_if_convert(vi_shader *s)
{
    for (unsigned round = 0; round < 64; round++) {
        bool progress = false;
        vi_foreach_block(s, h) if (if_convert_one(s, h)) progress = true;
        if (!progress) break;
    }
}

// Straight-line block chains (A's only successor B, B's only predecessor A) become one block.
static void replace_pred(vi_block *b, vi_block *from, vi_block *to)
{
    util_dynarray_foreach(&b->preds, vi_block *, p) if (*p == from) *p = to;
}

void vi_merge_blocks(vi_shader *s)
{
    bool progress = true;
    while (progress) {
        progress = false;
        vi_foreach_block(s, a) {
            vi_block *b = a->succ[0];
            if (!b || a->succ[1] || b == a || util_dynarray_num_elements(&b->preds, vi_block *) != 1) continue;
            if (b == list_first_entry(&s->blocks, vi_block, link)) continue;
            vi_instr *last = list_is_empty(&a->instrs) ? NULL : list_last_entry(&a->instrs, vi_instr, link);
            if (last && last->target) {
                if (last->target != b || last->src[0].kind != VI_IMM || last->src[0].value != 0 || !last->f.set[VAF_not]) continue;
                list_del(&last->link);
            }
            vi_foreach_instr_safe(b, I) { list_del(&I->link); list_addtail(&I->link, &a->instrs); }
            a->succ[0] = b->succ[0]; a->succ[1] = b->succ[1];
            for (unsigned k = 0; k < 2; k++) if (a->succ[k]) replace_pred(a->succ[k], b, a);
            b->succ[0] = b->succ[1] = NULL;
            util_dynarray_clear(&b->preds);
            progress = true;
        }
    }
}

// ---- Bottom-up list scheduling for register pressure ---------------------------------------------------------------------
// Per block: a dependence graph (values, physical registers, the order of side effects and of varying loads, the
// branch last), then instructions are placed from the bottom choosing, among the ready ones, the one that adds the
// fewest live words (sources that become live minus results that stop being live). Mesa's bi_pressure_schedule
// does the same on BIR.

typedef struct { vi_instr *I; unsigned ndeps_left; unsigned *succ; unsigned nsucc, capsucc; unsigned order; bool done; } snode;

static void sn_edge(snode *nodes, unsigned from, unsigned to)
{
    // `from` must stay before `to`; bottom-up, `from` becomes ready when all its successors are placed
    snode *f = &nodes[from];
    for (unsigned k = 0; k < f->nsucc; k++) if (f->succ[k] == to) return;
    if (f->nsucc == f->capsucc) { f->capsucc = f->capsucc ? 2 * f->capsucc : 8; f->succ = realloc(f->succ, f->capsucc * sizeof(unsigned)); }
    f->succ[f->nsucc++] = to;
    nodes[from].ndeps_left++;
}

static void schedule_block(vi_shader *s, vi_block *blk, BITSET_WORD *live_out_words, unsigned *base)
{
    unsigned n = 0;
    vi_foreach_instr(blk, I) n++;
    if (n < 3) return;
    snode *nodes = calloc(n, sizeof *nodes);
    unsigned i = 0;
    vi_foreach_instr(blk, I) { nodes[i].I = I; nodes[i].order = i; i++; }
    unsigned nv = vi_num_vregs(s);
    int *last_def = malloc(nv * sizeof(int)); int *last_use = malloc(nv * sizeof(int));
    for (unsigned v = 0; v < nv; v++) last_def[v] = last_use[v] = -1;
    int reg_def[VI_NUM_REGS], reg_use[VI_NUM_REGS];
    for (unsigned r = 0; r < VI_NUM_REGS; r++) reg_def[r] = reg_use[r] = -1;
    int last_side = -1, last_vary = -1;
    unsigned *loads = malloc(n * sizeof *loads), nloads = 0;
    static int free_loads_off = -1;
    if (free_loads_off < 0) free_loads_off = getenv("VMG_ISA_SCHED_ORDER_LOADS") != NULL;
    for (i = 0; i < n; i++) {
        vi_instr *I = nodes[i].I;
        vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        vi_ref *w[2] = { &I->dest, &I->sw };
        for (unsigned k = 0; k < 5; k++) {
            if (r[k]->kind == VI_VREG) { if (last_def[r[k]->value] >= 0) sn_edge(nodes, (unsigned)last_def[r[k]->value], i); }
            else if (r[k]->kind == VI_REG) for (unsigned q = 0; q < (r[k]->count ? r[k]->count : 1u); q++) {
                unsigned g = r[k]->value + q; if (reg_def[g] >= 0) sn_edge(nodes, (unsigned)reg_def[g], i);
            }
        }
        for (unsigned k = 0; k < 2; k++) {
            if (w[k]->kind == VI_VREG) {
                uint32_t v = w[k]->value;
                if (last_def[v] >= 0) sn_edge(nodes, (unsigned)last_def[v], i);
                if (last_use[v] >= 0 && (unsigned)last_use[v] != i) sn_edge(nodes, (unsigned)last_use[v], i);
            } else if (w[k]->kind == VI_REG) for (unsigned q = 0; q < (w[k]->count ? w[k]->count : 1u); q++) {
                unsigned g = w[k]->value + q;
                if (reg_def[g] >= 0) sn_edge(nodes, (unsigned)reg_def[g], i);
                if (reg_use[g] >= 0 && (unsigned)reg_use[g] != i) sn_edge(nodes, (unsigned)reg_use[g], i);
            }
        }
        // Reads of memory (textures, loads) keep their place relative to stores and other side effects, not to each
        // other: a blur's samples can then move down next to the arithmetic that consumes them.
        bool side = side_effects(I) || I->memory || I->blend || I->is_nop || I->op == VA_CLPER || I->op == VA_WMASK || I->clobber;
        bool load = side && I->memory && !side_effects(I) && !I->blend && !I->clobber && !free_loads_off;
        if (load) {
            if (last_side >= 0) sn_edge(nodes, (unsigned)last_side, i);
            if (nloads < n) loads[nloads++] = i;
        } else if (side) {
            if (last_side >= 0) sn_edge(nodes, (unsigned)last_side, i);
            for (unsigned q = 0; q < nloads; q++) sn_edge(nodes, loads[q], i);
            nloads = 0;
            last_side = (int)i;
        }
        if (I->varying) { if (last_vary >= 0) sn_edge(nodes, (unsigned)last_vary, i); last_vary = (int)i; }
        // everything that clobbers registers (BLEND) stays ordered with all register accesses: conservative
        for (unsigned k = 0; k < 5; k++) {
            if (r[k]->kind == VI_VREG) last_use[r[k]->value] = (int)i;
            else if (r[k]->kind == VI_REG) for (unsigned q = 0; q < (r[k]->count ? r[k]->count : 1u); q++) reg_use[r[k]->value + q] = (int)i;
        }
        for (unsigned k = 0; k < 2; k++) {
            if (w[k]->kind == VI_VREG) last_def[w[k]->value] = (int)i;
            else if (w[k]->kind == VI_REG) for (unsigned q = 0; q < (w[k]->count ? w[k]->count : 1u); q++) reg_def[w[k]->value + q] = (int)i;
        }
    }
    free(loads);
    // a branch stays last; side effects stay after values they could clobber (BLEND) — covered by the chains above,
    // plus: every instruction precedes a final branch
    vi_instr *lastI = nodes[n - 1].I;
    if (lastI->target) for (i = 0; i + 1 < n; i++) sn_edge(nodes, i, n - 1);
    // and nothing moves across an instruction that clobbers registers
    for (i = 0; i < n; i++) if (nodes[i].I->clobber) {
        for (unsigned j = 0; j < i; j++) sn_edge(nodes, j, i);
        for (unsigned j = i + 1; j < n; j++) sn_edge(nodes, i, j);
    }
    // live words at the bottom
    unsigned total = base[nv];
    BITSET_WORD *live = calloc(BITSET_WORDS(total ? total : 1), sizeof(BITSET_WORD));
    if (live_out_words) memcpy(live, live_out_words, BITSET_WORDS(total ? total : 1) * sizeof(BITSET_WORD));
    vi_instr **out = malloc(n * sizeof *out);
    unsigned *recent = calloc(n, sizeof(unsigned));   // for each node: latest placement among its users (+1)
    for (unsigned placed = 0; placed < n; placed++) {
        int best = -1, best_score = 0;
        for (i = 0; i < n; i++) {
            if (nodes[i].done || nodes[i].ndeps_left) continue;
            vi_instr *I = nodes[i].I;
            int score = 0;
            vi_ref *w[2] = { &I->dest, &I->sw };
            for (unsigned k = 0; k < 2; k++) if (w[k]->kind == VI_VREG)
                for (unsigned q = 0; q < (w[k]->count ? w[k]->count : 1u); q++) if (BITSET_TEST(live, base[w[k]->value] + w[k]->word + q)) score--;
            vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
            for (unsigned k = 0; k < 5; k++) if (r[k]->kind == VI_VREG)
                for (unsigned q = 0; q < (r[k]->count ? r[k]->count : 1u); q++) {
                    unsigned word = base[r[k]->value] + r[k]->word + q;
                    if (BITSET_TEST(live, word)) continue;
                    bool dup = false;   // the same word read twice counts once
                    for (unsigned k2 = 0; k2 < k && !dup; k2++) if (r[k2]->kind == VI_VREG)
                        for (unsigned q2 = 0; q2 < (r[k2]->count ? r[k2]->count : 1u); q2++)
                            if (base[r[k2]->value] + r[k2]->word + q2 == word) dup = true;
                    for (unsigned q2 = 0; q2 < q; q2++) if (base[r[k]->value] + r[k]->word + q2 == word) dup = true;
                    if (!dup) score++;
                }
            // ties: the definition of what was just placed (depth first: chains stay short), then the original order
            static int depth_first = -1;
            if (depth_first < 0) depth_first = getenv("VMG_ISA_SCHED_DFS") != NULL;
            bool better = best < 0 || score < best_score ||
                          (score == best_score && (depth_first ? (recent[i] > recent[best] || (recent[i] == recent[best] && nodes[i].order > nodes[best].order))
                                                               : nodes[i].order > nodes[best].order));
            if (better) { best = (int)i; best_score = score; }
        }
        if (best < 0) { free(out); goto done; }   // cycle (cannot happen): keep the block as it was
        snode *b = &nodes[best];
        b->done = true;
        out[n - 1 - placed] = b->I;
        vi_instr *I = b->I;
        vi_ref *w[2] = { &I->dest, &I->sw };
        for (unsigned k = 0; k < 2; k++) if (w[k]->kind == VI_VREG)
            for (unsigned q = 0; q < (w[k]->count ? w[k]->count : 1u); q++) BITSET_CLEAR(live, base[w[k]->value] + w[k]->word + q);
        vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        for (unsigned k = 0; k < 5; k++) if (r[k]->kind == VI_VREG)
            for (unsigned q = 0; q < (r[k]->count ? r[k]->count : 1u); q++) BITSET_SET(live, base[r[k]->value] + r[k]->word + q);
        // predecessors (instructions that must come before) lose one dependent, and remember how recently
        for (i = 0; i < n; i++) {
            snode *p = &nodes[i];
            for (unsigned k = 0; k < p->nsucc; k++) if (p->succ[k] == (unsigned)best) { p->ndeps_left--; recent[i] = placed + 1; break; }
        }
    }
    list_inithead(&blk->instrs);
    for (i = 0; i < n; i++) list_addtail(&out[i]->link, &blk->instrs);
    free(out);
done:
    free(recent);
    for (i = 0; i < n; i++) free(nodes[i].succ);
    free(nodes); free(last_def); free(last_use); free(live);
}

void vi_schedule_blocks(vi_shader *s)
{
    if (getenv("VMG_ISA_NO_SCHED")) return;
    vi_liveness(s);
    vi_foreach_block(s, blk) schedule_block(s, blk, blk->live_out, s->live_base);
}

// ---- Vector splitting -------------------------------------------------------------------------------------------------
// A multi-word register written by a message (texture, varying, load results) and then only read word by word is
// copied to one register per word right after it is written: the vector then dies at once instead of living until
// its last component is read (register allocation works on whole registers).
void vi_split_vectors(vi_shader *s)
{
    unsigned n = vi_num_vregs(s);
    bool *vector_use = calloc(n ? n : 1, sizeof(bool));
    unsigned *defs = calloc(n ? n : 1, sizeof(unsigned));
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        for (unsigned k = 0; k < 5; k++) if (r[k]->kind == VI_VREG && (r[k]->count > 1 || k == 4)) vector_use[r[k]->value] = true;
        if (I->dest.kind == VI_VREG) defs[I->dest.value]++;
        if (I->sw.kind == VI_VREG) defs[I->sw.value]++;
    }
    uint32_t *map = malloc((n ? n : 1) * VI_MAX_WORDS * sizeof(uint32_t));
    vi_foreach_block(s, blk) vi_foreach_instr_safe(blk, I) {
        vi_ref w = I->sw;
        if (w.kind != VI_VREG || !vi_is_msg(I)) continue;
        vi_vreg_info *info = vi_vreg_get(s, w.value);
        if (info->nwords < 2 || info->nwords > VI_MAX_WORDS || vector_use[w.value] || defs[w.value] != 1 || info->multi_def || info->fixed >= 0) continue;
        unsigned nwords = info->nwords;   // (vi_new_vreg below may move the register table)
        vi_builder b = { s, blk, I->link.next == &blk->instrs ? NULL : list_entry(I->link.next, vi_instr, link) };
        for (unsigned q = 0; q < nwords; q++) {
            uint32_t sreg = vi_new_vreg(s, 1);
            vi_instr *M = vi_emit(&b, VA_MOV_I32);
            M->dest = vi_vreg(sreg, 0, 1); M->src[0] = vi_vreg(w.value, q, 1);
            map[w.value * VI_MAX_WORDS + q] = sreg;
        }
        vector_use[w.value] = true;   // mark as split (the MOVs read it)
        defs[w.value] = 1000;
        // rewrite later reads
        uint32_t v = w.value;
        vi_foreach_block(s, b2) vi_foreach_instr(b2, J) {
            if (J->op == VA_MOV_I32 && J->src[0].kind == VI_VREG && J->src[0].value == v && J->dest.kind == VI_VREG &&
                J->dest.value >= n && J->dest.value < vi_num_vregs(s) && map[v * VI_MAX_WORDS + J->src[0].word] == J->dest.value) continue;
            for (unsigned k = 0; k < 4; k++) {
                vi_ref *r = &J->src[k];
                if (r->kind == VI_VREG && r->value == v && (r->count ? r->count : 1) == 1) { r->value = map[v * VI_MAX_WORDS + r->word]; r->word = 0; }
            }
        }
    }
    free(vector_use); free(defs); free(map);
}

// FMUL.f32 x, y feeding only one FADD.f32 (no modifiers that change the product): FMA.f32 x, y, other.
// Metal's default fast math allows the contraction.
void vi_fuse_fma(vi_shader *s)
{
    unsigned n = vi_num_vregs(s);
    unsigned *uses = calloc(n ? n : 1, sizeof(unsigned));
    vi_instr **def = calloc(n ? n : 1, sizeof(vi_instr *));
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        for (unsigned k = 0; k < 5; k++) if (r[k]->kind == VI_VREG) uses[r[k]->value]++;
        if (I->dest.kind == VI_VREG && vi_vreg_get(s, I->dest.value)->nwords == 1 && !vi_vreg_get(s, I->dest.value)->multi_def) def[I->dest.value] = I;
    }
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        if (I->op != VA_FADD_F32 || I->f.set[VAF_clamp] || I->f.set[VAF_round] || I->f.set[VAF_widen0] || I->f.set[VAF_widen1]) continue;
        for (unsigned k = 0; k < 2; k++) {
            vi_ref m = I->src[k];
            if (m.kind != VI_VREG || !uses[m.value]) continue;
            vi_instr *M = def[m.value];
            // A product of uniforms and constants (blur offsets: u * k) is fused into each of its FADDs: the FMUL goes
            // when its last FADD takes it.
            bool shared = uses[m.value] != 1;
            if (shared && M && (vi_is_vreg(M->src[0]) || vi_is_vreg(M->src[1]))) continue;
            if (!M || M->op != VA_FMUL_F32 || M->f.set[VAF_clamp] || M->f.set[VAF_round] || M->f.set[VAF_widen0] || M->f.set[VAF_widen1] ||
                M->f.set[VAF_abs0] || M->f.set[VAF_abs1]) continue;
            // the FMUL's operands must still hold the same values at the FADD: single-definition registers or uniforms
            bool ok = true;
            for (unsigned q = 0; q < 2; q++) if (M->src[q].kind == VI_VREG && vi_vreg_get(s, M->src[q].value)->multi_def) ok = false;
            if (M->src[0].kind == VI_REG || M->src[1].kind == VI_REG) ok = false;
            if (!ok) continue;
            bool negm = I->f.set[k ? VAF_neg1 : VAF_neg0] && I->f.v[k ? VAF_neg1 : VAF_neg0];
            unsigned o = 1 - k;
            vi_ref other = I->src[o];
            bool nego = I->f.set[o ? VAF_neg1 : VAF_neg0] && I->f.v[o ? VAF_neg1 : VAF_neg0];
            bool abso = I->f.set[o ? VAF_abs1 : VAF_abs0] && I->f.v[o ? VAF_abs1 : VAF_abs0];
            if (I->f.set[k ? VAF_abs1 : VAF_abs0] && I->f.v[k ? VAF_abs1 : VAF_abs0]) continue;
            bool neg0 = (M->f.set[VAF_neg0] && M->f.v[VAF_neg0]) ^ negm;
            bool neg1 = M->f.set[VAF_neg1] && M->f.v[VAF_neg1];
            va_vals f; va_vals_init(&f);
            I->op = VA_FMA_F32;
            I->src[0] = M->src[0]; I->src[1] = M->src[1]; I->src[2] = other;
            if (neg0) va_set(&f, VAF_neg0, 1);
            if (neg1) va_set(&f, VAF_neg1, 1);
            if (nego) va_set(&f, VAF_neg2, 1);
            if (abso) va_set(&f, VAF_abs2, 1);
            I->f = f;
            if (--uses[m.value] == 0) { list_del(&M->link); def[m.value] = NULL; }
            break;
        }
    }
    free(uses); free(def);
}

// ---- Rematerialization --------------------------------------------------------------------------------------------------
// (VMG_ISA_REMAT=1) A one-word value computed by one ALU instruction whose operands stay alive anyway (uniforms, constants, registers
// read again later) is computed again just before a use that comes after two or more messages, instead of being kept
// in a register across them. Blurs compute their sample coordinates (base +- k * step) for the textures and again
// for the weights after all samples: without this every coordinate lives across every texture result.
void vi_remat(vi_shader *s)
{
    if (!getenv("VMG_ISA_REMAT")) return;   // opt-in: no measurable gain on QuartzCore yet, more code
    vi_liveness(s);
    unsigned n = vi_num_vregs(s);
    unsigned *defs = calloc(n ? n : 1, sizeof *defs);
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        if (I->dest.kind == VI_VREG) defs[I->dest.value]++;
        if (I->sw.kind == VI_VREG) defs[I->sw.value]++;
    }
    int *last = malloc((n ? n : 1) * sizeof *last), *defpos = malloc((n ? n : 1) * sizeof *defpos);
    bool *simple = malloc(n ? n : 1);
    vi_foreach_block(s, blk) {
        unsigned ni = 0;
        vi_foreach_instr(blk, I) ni++;
        if (ni < 4) continue;
        vi_instr **ins = malloc(ni * sizeof *ins);
        unsigned *msgs = malloc((ni + 1) * sizeof *msgs);
        for (unsigned v = 0; v < n; v++) { last[v] = -1; defpos[v] = -1; simple[v] = true; }
        unsigned i = 0;
        msgs[0] = 0;
        vi_foreach_instr(blk, I) {
            ins[i] = I;
            msgs[i + 1] = msgs[i] + (vi_is_msg(I) ? 1 : 0);
            vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
            for (unsigned k = 0; k < 5; k++) {
                if (r[k]->kind != VI_VREG) continue;
                last[r[k]->value] = (int)i;
                if (k == 4 || (r[k]->count ? r[k]->count : 1) != 1) simple[r[k]->value] = false;
            }
            if (I->dest.kind == VI_VREG) defpos[I->dest.value] = (int)i;
            if (I->sw.kind == VI_VREG) { defpos[I->sw.value] = (int)i; simple[I->sw.value] = false; }
            i++;
        }
        for (unsigned d = 0; d < ni; d++) {
            vi_instr *D = ins[d];
            if (D->dest.kind != VI_VREG || D->sw.kind != VI_NONE || vi_is_msg(D) || D->clobber || D->helpers || !movable(s, D)) continue;
            uint32_t v = D->dest.value;
            vi_vreg_info *info = vi_vreg_get(s, v);
            if (defs[v] != 1 || info->nwords != 1 || info->fixed >= 0 || !simple[v] || defpos[v] != (int)d) continue;
            if (BITSET_TEST(blk->live_out, s->live_base[v])) continue;
            if (last[v] < 0 || msgs[last[v]] - msgs[d + 1] < 2) continue;
            uint32_t provider = v;
            int prev = (int)d, last_v = -1;
            for (unsigned p = d + 1; p < ni && (int)p <= last[v]; p++) {
                vi_instr *U = ins[p];
                bool reads = false;
                for (unsigned k = 0; k < 4; k++) if (U->src[k].kind == VI_VREG && U->src[k].value == v) reads = true;
                if (!reads) continue;
                if (msgs[p] - msgs[prev + 1] >= 2) {
                    bool ok = true;
                    for (unsigned k = 0; k < 4 && ok; k++) {
                        vi_ref x = D->src[k];
                        if (x.kind != VI_VREG) continue;
                        if (defs[x.value] != 1 || vi_vreg_get(s, x.value)->multi_def) ok = false;
                        else if (last[x.value] < (int)p && !BITSET_TEST(blk->live_out, s->live_base[x.value] + x.word)) ok = false;
                    }
                    if (ok) {
                        uint32_t nv = vi_new_vreg(s, 1);
                        vi_builder b = { s, blk, U };
                        vi_instr *C = vi_emit(&b, D->op);
                        struct list_head link = C->link;
                        *C = *D;
                        C->link = link;
                        C->dest = vi_vreg(nv, 0, 1);
                        provider = nv;
                    }
                }
                for (unsigned k = 0; k < 4; k++) if (U->src[k].kind == VI_VREG && U->src[k].value == v) U->src[k].value = provider;
                if (provider == v) last_v = (int)p;
                prev = (int)p;
            }
            last[v] = last_v;
        }
        free(ins); free(msgs);
    }
    free(defs); free(last); free(defpos); free(simple);
}
