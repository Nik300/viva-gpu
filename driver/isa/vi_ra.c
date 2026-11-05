// Viva ISA compiler: liveness and register allocation.
//
// Linear scan over the final block layout. Each virtual register gets one interval (the hull of every point where
// it is live), so values live around a loop keep their register for the whole loop. Multi-word registers take
// consecutive, even-aligned registers (staging vectors and 64-bit pairs must start on an even register). Registers
// named directly by the selector (preloads, ABI registers) are fixed intervals the allocator works around.
// Out of registers -> failure: the function falls back to the NIR path (spilling: vi_spill, if enabled).
#include "vi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "util/ralloc.h"

typedef void (*ref_cb)(vi_ref *r, bool write, void *data);

// Calls cb for every register operand of I: reads first, then writes.
static void foreach_ref(vi_instr *I, ref_cb cb, void *data)
{
    for (unsigned k = 0; k < 4; k++) if (I->src[k].kind == VI_VREG || I->src[k].kind == VI_REG) cb(&I->src[k], false, data);
    if (I->sr.kind == VI_VREG || I->sr.kind == VI_REG) cb(&I->sr, false, data);
    if (I->dest.kind == VI_VREG || I->dest.kind == VI_REG) cb(&I->dest, true, data);
    if (I->sw.kind == VI_VREG || I->sw.kind == VI_REG) cb(&I->sw, true, data);
}

static unsigned ref_words(const vi_ref *r) { return r->count ? r->count : 1; }

// ---- Liveness (per word of every virtual register) --------------------------------------------------------------------
// A write defines whole words (the selector never writes half a word), so liveness is exact per word; a vector built
// word by word is live only from its first written word on.

static unsigned *g_base;   // first word index of each vreg (set by vi_liveness)

typedef struct { vi_shader *s; BITSET_WORD *use, *def; } live_ctx;

static void live_ref(vi_ref *r, bool write, void *data)
{
    live_ctx *c = data;
    if (r->kind != VI_VREG) return;
    unsigned b = g_base[r->value] + r->word, n = ref_words(r);
    for (unsigned w = b; w < b + n; w++) {
        if (write) BITSET_SET(c->def, w);
        else if (!BITSET_TEST(c->def, w)) BITSET_SET(c->use, w);
    }
}

void vi_liveness(vi_shader *s)
{
    unsigned n = vi_num_vregs(s), total = 0;
    g_base = ralloc_array(s->mem, unsigned, n + 1);
    for (unsigned v = 0; v < n; v++) { g_base[v] = total; total += vi_vreg_get(s, v)->nwords; }
    g_base[n] = total;
    s->live_words = total;
    s->live_base = g_base;
    unsigned words = BITSET_WORDS(total ? total : 1);
    BITSET_WORD *use = rzalloc_array(s->mem, BITSET_WORD, words * s->nblocks), *def = rzalloc_array(s->mem, BITSET_WORD, words * s->nblocks);
    vi_foreach_block(s, blk) {
        blk->live_in = rzalloc_array(s->mem, BITSET_WORD, words);
        blk->live_out = rzalloc_array(s->mem, BITSET_WORD, words);
        live_ctx c = { s, use + words * blk->index, def + words * blk->index };
        vi_foreach_instr(blk, I) {
            // Reads of this instruction happen before its writes.
            for (unsigned k = 0; k < 4; k++) if (I->src[k].kind == VI_VREG) live_ref(&I->src[k], false, &c);
            if (I->sr.kind == VI_VREG) live_ref(&I->sr, false, &c);
            if (I->dest.kind == VI_VREG) live_ref(&I->dest, true, &c);
            if (I->sw.kind == VI_VREG) live_ref(&I->sw, true, &c);
        }
    }
    bool progress = true;
    while (progress) {
        progress = false;
        vi_foreach_block_rev(s, blk) {
            BITSET_WORD *u = use + words * blk->index, *d = def + words * blk->index;
            for (unsigned w = 0; w < words; w++) {
                BITSET_WORD out = 0;
                for (unsigned k = 0; k < 2; k++) if (blk->succ[k]) out |= blk->succ[k]->live_in[w];
                BITSET_WORD in = u[w] | (out & ~d[w]);
                if (out != blk->live_out[w] || in != blk->live_in[w]) progress = true;
                blk->live_out[w] = out;
                blk->live_in[w] = in;
            }
        }
    }
}

// ---- Allocation -----------------------------------------------------------------------------------------------------

typedef struct { int start, end; } interval;

typedef struct {
    interval *iv;          // per vreg
    interval *wiv;         // per word of every vreg (g_base)
    interval fixed[VI_NUM_REGS];
    int pos;
    int clobber_pos[64]; uint64_t clobber_mask[64]; unsigned nclobber;
} ra_ctx;

// Allocation order: r0-r15 and r48-r63 first (the 32-register mode of Valhall, twice the threads), then r16-r47.
static const uint8_t kOrder[VI_NUM_REGS] = {
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
};

static void extend(interval *i, int p)
{
    if (i->start < 0 || p < i->start) i->start = p;
    if (p > i->end) i->end = p;
}

static void ra_ref(vi_ref *r, bool write, void *data)
{
    ra_ctx *c = data;
    int p = c->pos + (write ? 1 : 0);
    if (r->kind == VI_VREG) {
        extend(&c->iv[r->value], p);
        for (unsigned w = 0; w < ref_words(r); w++) extend(&c->wiv[g_base[r->value] + r->word + w], p);
    }
    else if (r->kind == VI_REG)
        for (unsigned w = 0; w < ref_words(r) && r->value + w < VI_NUM_REGS; w++) extend(&c->fixed[r->value + w], p);
}

static int cmp_start(const void *a, const void *b, void *ctx)
{
    const interval *iv = ctx;
    int x = *(const int *)a, y = *(const int *)b;
    return iv[x].start != iv[y].start ? iv[x].start - iv[y].start : x - y;
}

static void rewrite_ref(vi_ref *r, bool write, void *data)
{
    (void)write;
    vi_shader *s = data;
    if (r->kind != VI_VREG) return;
    vi_vreg_info *v = vi_vreg_get(s, r->value);
    r->kind = VI_REG;
    r->value = (uint32_t)(v->phys + r->word);
    r->word = 0;
}

static bool overlaps(interval a, interval b) { return a.start >= 0 && b.start >= 0 && a.start <= b.end && b.start <= a.end; }

static bool ra_try(vi_shader *s, int *spill)
{
    *spill = -1;
    unsigned n = vi_num_vregs(s);
    vi_liveness(s);
    ra_ctx c = {0};
    c.iv = calloc(n ? n : 1, sizeof *c.iv);
    for (unsigned v = 0; v < n; v++) c.iv[v].start = c.iv[v].end = -1;
    c.wiv = malloc((s->live_words ? s->live_words : 1) * sizeof *c.wiv);
    for (unsigned w = 0; w < s->live_words; w++) c.wiv[w].start = c.wiv[w].end = -1;
    for (unsigned r = 0; r < VI_NUM_REGS; r++) c.fixed[r].start = c.fixed[r].end = -1;
    int pos = 0;
    vi_foreach_block(s, blk) {
        int first = pos;
        vi_foreach_instr(blk, I) {
            c.pos = pos;
            foreach_ref(I, ra_ref, &c);
            if (I->clobber && c.nclobber < 64) { c.clobber_pos[c.nclobber] = pos; c.clobber_mask[c.nclobber++] = I->clobber; }
            pos += 2;
        }
        int last = pos > first ? pos - 1 : first;
        unsigned w, v = 0;
        BITSET_FOREACH_SET(w, blk->live_in, s->live_words) { while (g_base[v + 1] <= w) v++; extend(&c.iv[v], first); extend(&c.wiv[w], first); }
        v = 0;
        BITSET_FOREACH_SET(w, blk->live_out, s->live_words) { while (g_base[v + 1] <= w) v++; extend(&c.iv[v], last); extend(&c.wiv[w], last); }
    }
    // Coalescing hint: a one-word register copied from a word of another register prefers the same register.
    int *hint_src = malloc((n ? n : 1) * sizeof(int)), *hint_word = malloc((n ? n : 1) * sizeof(int));
    for (unsigned v = 0; v < n; v++) hint_src[v] = -1;
    // Vector hints (staging vectors built by copies, words of split message results): word q of V copied from word xw
    // of x. With per-word intervals, V may take x's register for that word when x's word dies at the copy, which
    // turns the copy into a move onto itself (dropped after RA). VMG_ISA_NO_VHINT=1 turns this off.
    typedef struct { uint8_t q, xw; uint32_t x; } vhint;
    enum { VHINTS = 8 };
    vhint *vh = calloc((n ? n : 1) * VHINTS, sizeof *vh);
    uint8_t *nvh = calloc(n ? n : 1, 1);
    static int no_vhint = -1;
    if (no_vhint < 0) no_vhint = getenv("VMG_ISA_NO_VHINT") != NULL;
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        if (I->op != VA_MOV_I32 || I->dest.kind != VI_VREG || I->src[0].kind != VI_VREG || ref_words(&I->src[0]) != 1 || ref_words(&I->dest) != 1) continue;
        if (vi_vreg_get(s, I->dest.value)->nwords == 1) { hint_src[I->dest.value] = (int)I->src[0].value; hint_word[I->dest.value] = I->src[0].word; }
        uint32_t v = I->dest.value;
        if (nvh[v] < VHINTS && I->src[0].value != v) { vh[v * VHINTS + nvh[v]] = (vhint){ I->dest.word, I->src[0].word, I->src[0].value }; nvh[v]++; }
    }
    // Precoloured registers first: their intervals become fixed ones the others avoid.
    for (unsigned v = 0; v < n; v++) {
        vi_vreg_info *info = vi_vreg_get(s, v);
        if (info->fixed < 0 || c.iv[v].start < 0) continue;
        for (unsigned w = 0; w < info->nwords; w++) {
            interval *f = &c.fixed[info->fixed + w];
            if (f->start >= 0 && overlaps(*f, c.iv[v])) { free(c.iv); free(c.wiv); free(vh); free(nvh); free(hint_src); free(hint_word); free(s->error); s->error = strdup("register allocation: precoloured registers overlap"); return false; }
            extend(f, c.iv[v].start); extend(f, c.iv[v].end);
        }
        info->phys = info->fixed;
    }
    int *order = malloc((n ? n : 1) * sizeof *order);
    unsigned m = 0;
    for (unsigned v = 0; v < n; v++) if (c.iv[v].start >= 0 && vi_vreg_get(s, v)->fixed < 0) order[m++] = (int)v;
    // By start (qsort_r's argument order differs between libcs; insertion sort is fine for shader sizes).
    for (unsigned i = 1; i < m; i++) {
        int x = order[i];
        unsigned j = i;
        while (j > 0 && cmp_start(&order[j - 1], &x, c.iv) > 0) { order[j] = order[j - 1]; j--; }
        order[j] = x;
    }
    int active[VI_NUM_REGS];             // vreg occupying each register, -1 free
    for (unsigned r = 0; r < VI_NUM_REGS; r++) active[r] = -1;
    bool ok = true;
    uint64_t used = 0;
    for (unsigned i = 0; i < m && ok; i++) {
        int v = order[i];
        interval iv = c.iv[v];
        vi_vreg_info *info = vi_vreg_get(s, (uint32_t)v);
        for (unsigned r = 0; r < VI_NUM_REGS; r++)
            if (active[r] >= 0 && c.iv[active[r]].end < iv.start) active[r] = -1;
        unsigned nw = info->nwords, al = info->align ? info->align : 1;
        // Registers destroyed by an instruction inside the interval (the value lives across it).
        uint64_t forbidden = s->reserved_regs;
        for (unsigned k = 0; k < c.nclobber; k++)
            if (iv.start < c.clobber_pos[k] && c.clobber_pos[k] < iv.end) forbidden |= c.clobber_mask[k];
        int chosen = -1;
        // vector / per-word hints: a base where every word is free, or held by a word of another register that is
        // dead before this word is first written
        for (unsigned h = 0; h < nvh[v] && chosen < 0 && info->fixed < 0 && !no_vhint; h++) {
            vhint hh = vh[v * VHINTS + h];
            vi_vreg_info *xi = vi_vreg_get(s, hh.x);
            if (xi->phys < 0) continue;
            int base = xi->phys + hh.xw - hh.q;
            if (base < 0 || base % al || base + (int)nw > VI_NUM_REGS) continue;
            if (!((base + (int)nw <= 16) || (base >= 48))) continue;   // stay in the 32-register set
            bool ok = true;
            for (unsigned w = 0; w < nw && ok; w++) {
                unsigned q = (unsigned)base + w;
                interval ww = c.wiv[g_base[v] + w];
                if ((forbidden >> q & 1) || overlaps(c.fixed[q], iv)) { ok = false; break; }
                int a = active[q];
                if (a < 0) continue;
                vi_vreg_info *ai = vi_vreg_get(s, (uint32_t)a);
                int aw = (int)q - ai->phys;
                if (a == v || aw < 0 || aw >= ai->nwords) { ok = false; break; }
                interval aww = c.wiv[g_base[a] + aw];
                // the other word must end before this word starts (a word never written is not live)
                if (ww.start < 0 || aww.end >= ww.start) ok = false;
                // and it must not come back to life later in this one's range (its register is reused for it)
                if (ok && aww.start > ww.start) ok = false;
            }
            if (ok) chosen = base;
        }
        if (chosen < 0 && info->fixed < 0 && nw == 1 && hint_src[v] >= 0) {
            vi_vreg_info *hi = vi_vreg_get(s, (uint32_t)hint_src[v]);
            int r = hi->phys >= 0 ? hi->phys + hint_word[v] : -1;
            // (only inside the 32-register set: a hint must not push the program to 64 registers)
            if (r >= 0 && r < VI_NUM_REGS && (r < 16 || r >= 48) && active[r] < 0 && !(forbidden >> r & 1) && !overlaps(c.fixed[r], iv)) chosen = r;
        }
        // two passes: first only ranges wholly inside r0-r15 / r48-r63 (32-register mode), then any
        // (VMG_ISA_NO_R48=1, diagnosis: never r48-r63 for ordinary values)
        static int no_r48 = -1;
        if (no_r48 < 0) no_r48 = getenv("VMG_ISA_NO_R48") != NULL;
        if (no_r48 && chosen >= 48 && info->fixed < 0) chosen = -1;
        for (unsigned pass = 0; pass < 2 && chosen < 0; pass++)
        for (unsigned o = 0; o < VI_NUM_REGS && chosen < 0; o++) {
            unsigned r = info->fixed >= 0 ? (unsigned)info->fixed : kOrder[o];
            if (no_r48 && info->fixed < 0 && r + nw > 48) continue;
            if (r % al || r + nw > VI_NUM_REGS) { if (info->fixed >= 0) break; continue; }
            if (pass == 0 && info->fixed < 0 && ((r < 16 && r + nw > 16) || (r >= 16 && r < 48))) continue;
            bool free_ = true;
            for (unsigned w = 0; w < nw && free_; w++) {
                unsigned q = r + w;
                if (active[q] >= 0 || (forbidden >> q & 1) || overlaps(c.fixed[q], iv)) free_ = false;
            }
            if (free_) chosen = (int)r;
            if (info->fixed >= 0) break;
        }
        if (chosen < 0) {
            free(s->error);
            s->error = info->fixed >= 0 ? strdup("register allocation: fixed register busy")
                                        : strdup("register allocation: out of registers");
            // spill candidate: the live register (or this one) whose interval ends last
            int best = info->fixed < 0 && !info->spill_temp ? v : -1, best_end = best >= 0 ? iv.end : -1;
            for (unsigned r = 0; r < VI_NUM_REGS; r++) {
                int a = active[r];
                if (a < 0) continue;
                vi_vreg_info *ai = vi_vreg_get(s, (uint32_t)a);
                if (ai->fixed >= 0 || ai->spill_temp) continue;
                if (c.iv[a].end > best_end) { best = a; best_end = c.iv[a].end; }
            }
            *spill = best;
            ok = false;
            break;
        }
        info->phys = (int16_t)chosen;
        for (unsigned w = 0; w < nw; w++) { active[chosen + w] = v; used |= 1ull << (chosen + w); }
        { unsigned live = 0; for (unsigned r = 0; r < VI_NUM_REGS; r++) live += active[r] >= 0; if (live > s->max_live) s->max_live = live;
          if (getenv("VMG_ISA_DEBUG_PEAK") && live >= (unsigned)atoi(getenv("VMG_ISA_DEBUG_PEAK"))) {
              fprintf(stderr, "peak %u at %d:", live, iv.start);
              int last = -1;
              for (unsigned r = 0; r < VI_NUM_REGS; r++) if (active[r] >= 0 && active[r] != last) { last = active[r];
                  vi_vreg_info *ai = vi_vreg_get(s, (uint32_t)last);
                  fprintf(stderr, " v%d(%u%s %d..%d)", last, ai->nwords, ai->multi_def ? "m" : "", c.iv[last].start, c.iv[last].end); }
              fprintf(stderr, "\n");
          } }
        static int dbg = -1;
        if (dbg < 0) dbg = getenv("VMG_ISA_DEBUG_RA") != NULL;
        if (dbg && chosen >= 16 && chosen < 48) {
            fprintf(stderr, "ra: v%d (%u words, align %u) -> r%d, interval %d..%d; busy:", v, nw, al, chosen, iv.start, iv.end);
            for (unsigned r = 0; r < VI_NUM_REGS; r++) if (active[r] >= 0 && active[r] != v) fprintf(stderr, " r%u=v%d", r, active[r]);
            fprintf(stderr, " forbidden %llx fixed:", (unsigned long long)forbidden);
            for (unsigned r = 0; r < VI_NUM_REGS; r++) if (c.fixed[r].start >= 0) fprintf(stderr, " r%u[%d..%d]", r, c.fixed[r].start, c.fixed[r].end);
            fprintf(stderr, " hint %d\n", hint_src[v]);
        }
    }
    free(order);
    free(c.iv);
    free(hint_src); free(hint_word); free(vh); free(nvh); free(c.wiv);
    if (!ok) return false;
    for (unsigned r = 0; r < VI_NUM_REGS; r++) if (c.fixed[r].start >= 0) used |= 1ull << r;
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) foreach_ref(I, rewrite_ref, s);
    // 32 work registers = r0-r15 + r48-r63 (Valhall's half register file); anything in r16-r47 needs 64.
    s->work_regs = (used & 0x0000ffffffff0000ull) ? 64 : 32;
    s->regs_used = used;
    return true;
}

// ---- Spilling (A3) ------------------------------------------------------------------------------------------------------
// A spilled register lives in private memory (thread-local pointer + slot offset, .force accesses): every definition
// writes its words there, every use loads them into a short-lived copy. Slots are aligned to their size (at most 16
// bytes), so no access crosses a 16-byte line (v9 rule).

static vi_instr *tls_access(vi_shader *s, vi_block *blk, vi_instr *before, bool store, vi_ref reg, unsigned offset)
{
    vi_builder b = { s, blk, before };
    vi_instr *I = vi_emit(&b, store ? VA_STORE_I32 : VA_LOAD_I32);
    vi_ref tls = vi_special(1, 2);   // thread_local_pointer, 64-bit
    tls.count = 2;
    I->src[0] = tls;
    if (store) I->sr = reg; else I->sw = reg;
    va_set(&I->f, VAF_offset, offset);
    va_set(&I->f, VAF_access, 3);   // force: discarded and helper lanes too
    if (!store) va_set(&I->f, VAF_lane, 0);
    I->memory = true;
    return I;
}

static void spill_vreg(vi_shader *s, uint32_t v)
{
    vi_vreg_info *info = vi_vreg_get(s, v);
    unsigned size = info->nwords * 4, align = 4;
    while (align < size && align < 16) align <<= 1;
    unsigned base = (s->tls_size + align - 1) & ~(align - 1);
    s->tls_size = base + size;
    s->spills++;
    vi_foreach_block(s, blk) vi_foreach_instr_safe(blk, I) {
        if (I->is_nop && I->flow) continue;
        vi_ref *reads[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        for (unsigned k = 0; k < 5; k++) {
            vi_ref *r = reads[k];
            if (r->kind != VI_VREG || r->value != v) continue;
            unsigned n = r->count ? r->count : 1;
            uint32_t tmp = vi_new_vreg(s, n);
            vi_vreg_get(s, tmp)->spill_temp = true;
            for (unsigned q = 0; q < n; q++) tls_access(s, blk, I, false, vi_vreg(tmp, q, 1), base + 4 * (r->word + q));
            r->value = tmp; r->word = 0;
        }
        vi_ref *writes[2] = { &I->dest, &I->sw };
        vi_instr *next = I->link.next == &blk->instrs ? NULL : list_entry(I->link.next, vi_instr, link);
        for (unsigned k = 0; k < 2; k++) {
            vi_ref *w = writes[k];
            if (w->kind != VI_VREG || w->value != v) continue;
            unsigned n = w->count ? w->count : 1, word = w->word;
            uint32_t tmp = vi_new_vreg(s, n);
            vi_vreg_get(s, tmp)->spill_temp = true;
            w->value = tmp; w->word = 0;
            for (unsigned q = 0; q < n; q++) tls_access(s, blk, next, true, vi_vreg(tmp, q, 1), base + 4 * (word + q));
        }
    }
}

bool vi_register_allocate(vi_shader *s)
{
    for (unsigned round = 0; round < 256; round++) {
        int spill;
        if (ra_try(s, &spill)) return true;
        if (spill < 0) return false;
        for (unsigned v = 0; v < vi_num_vregs(s); v++) vi_vreg_get(s, v)->phys = -1;
        spill_vreg(s, (uint32_t)spill);
    }
    return false;
}
