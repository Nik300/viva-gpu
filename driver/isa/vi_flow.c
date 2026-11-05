// Viva ISA compiler: flow control for a register-allocated shader.
//
// Hardware rules (Valhall v9; Arm's ISA description and the behaviour Mesa relies on):
//  - Message (asynchronous) instructions signal one of the slots 0-2; a later instruction reading or writing a
//    register an outstanding message writes must first wait on that slot. Memory accesses are serialized among
//    themselves; varying loads that update the hidden barycentric register wait for the previous ones.
//  - A wait is the flow of the instruction BEFORE the one that needs it (flow applies after an instruction).
//  - BLEND / ST_TILE / LD_TILE need every slot (wait); ATEST and ZS_EMIT need slots 0,1,2,6 (wait0126); ATEST is
//    followed by wait0; BARRIER uses slot 7 and is followed by wait.
//  - reconverge on the last instruction of a block that ends in a (possibly divergent) branch, or that falls into
//    a block with several predecessors; end on the last instruction of the shader's exit blocks.
//  - Fragment shaders terminate helper invocations (discard flow) once nothing needs them any more.
// Waits and discards are inserted as NOPs, then merged into neighbouring instructions where allowed.
#include "vi.h"
#include <string.h>
#include "util/ralloc.h"

#define F_NONE 0
#define F_WAIT0126 8
#define F_WAIT 9
#define F_RECONVERGE 10
#define F_DISCARD 13
#define F_END 15

static bool is_wait_or_none(uint8_t f) { return f <= F_WAIT; }

static uint8_t union_waits(uint8_t x, uint8_t y)
{
    if (x == F_WAIT || y == F_WAIT) return F_WAIT;
    if (x == F_WAIT0126 || y == F_WAIT0126) return F_WAIT0126;
    return x | y;
}

static vi_instr *nop_at(vi_shader *s, vi_block *blk, vi_instr *before, uint8_t flow)
{
    vi_builder b = { s, blk, before };
    vi_instr *I = vi_emit(&b, VA_NOP);
    I->is_nop = true;
    I->flow = flow;
    return I;
}

static uint64_t ref_mask(const vi_ref *r)
{
    if (r->kind != VI_REG) return 0;
    unsigned n = r->count ? r->count : 1;
    return (n >= 64 ? ~0ull : ((1ull << n) - 1)) << r->value;
}

static uint64_t read_mask(const vi_instr *I)
{
    uint64_t m = ref_mask(&I->sr);
    for (unsigned k = 0; k < 4; k++) m |= ref_mask(&I->src[k]);
    return m;
}

static uint64_t write_mask(const vi_instr *I) { return ref_mask(&I->dest) | ref_mask(&I->sw); }

// ---- Scoreboard ----------------------------------------------------------------------------------------------------

typedef struct { uint64_t write[3]; uint8_t memory, varying; } sb_state;

static uint8_t pop(sb_state *st, unsigned slot)
{
    st->write[slot] = 0;
    st->memory &= (uint8_t)~(1u << slot);
    st->varying &= (uint8_t)~(1u << slot);
    return (uint8_t)(1u << slot);
}

static uint8_t depend(sb_state *st, const vi_instr *I)
{
    uint8_t w = 0;
    uint64_t rw = read_mask(I) | write_mask(I);
    for (unsigned k = 0; k < 3; k++) if (st->write[k] & rw) w |= pop(st, k);
    if (I->varying) for (unsigned k = 0; k < 3; k++) if (st->varying >> k & 1) w |= pop(st, k);
    if (I->memory) for (unsigned k = 0; k < 3; k++) if (st->memory >> k & 1) w |= pop(st, k);
    if (I->op == VA_BARRIER)
        for (unsigned k = 0; k < 3; k++) if (st->write[k] || ((st->memory | st->varying) >> k & 1)) w |= pop(st, k);
    return w;
}

static void push(sb_state *st, const vi_instr *I)
{
    if (I->slot < 0 || I->slot > 2) return;
    st->write[I->slot] |= ref_mask(&I->sw) | (vi_is_msg(I) ? ref_mask(&I->dest) : 0);
    if (I->memory) st->memory |= (uint8_t)(1u << I->slot);
    if (I->varying) st->varying |= (uint8_t)(1u << I->slot);
}

static void sb_from(vi_block *blk, sb_state *st)
{
    memset(st, 0, sizeof *st);
    util_dynarray_foreach(&blk->preds, vi_block *, p) {
        for (unsigned k = 0; k < 3; k++) st->write[k] |= (*p)->sb_write_out[k];
        st->memory |= (*p)->sb_out[0];
        st->varying |= (*p)->sb_out[1];
    }
}

// Waits computed into I->flow (bitmask of slots 0-2) for every instruction; returns whether the block's output changed.
static bool sb_block(vi_block *blk, bool final)
{
    sb_state st;
    sb_from(blk, &st);
    vi_foreach_instr(blk, I) {
        uint8_t w = depend(&st, I);
        if (final) I->wait_before = w;
        push(&st, I);
    }
    // A varying load with .store waits for every varying load of the quad: pop them at the end of the block (as
    // Mesa does), so divergent paths never leave one outstanding.
    if (st.varying) {
        uint8_t w = 0;
        for (unsigned k = 0; k < 3; k++) if (st.varying >> k & 1) w |= pop(&st, k);
        if (final) blk->sb_in[7] = w;   // remembered: wait inserted at the end of the block
    }
    bool changed = memcmp(blk->sb_write_out, st.write, sizeof st.write) || blk->sb_out[0] != st.memory || blk->sb_out[1] != st.varying;
    memcpy(blk->sb_write_out, st.write, sizeof st.write);
    blk->sb_out[0] = st.memory;
    blk->sb_out[1] = st.varying;
    return changed;
}

static void assign_slots(vi_shader *s)
{
    unsigned counter = 0;
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        if (I->op == VA_BARRIER) I->slot = 7;
        else if (I->op == VA_ZS_EMIT || I->op == VA_ATEST) I->slot = 0;
        else if (vi_is_msg(I)) { I->slot = (int8_t)counter; counter = (counter + 1) % 3; }
    }
}

// ---- Helper invocations -----------------------------------------------------------------------------------------------

static bool block_uses_helpers(vi_block *blk)
{
    vi_foreach_instr(blk, I) if (I->helpers) return true;
    return false;
}

static void analyze_helpers(vi_shader *s)
{
    bool progress = true;
    vi_foreach_block(s, blk) blk->helpers_in = block_uses_helpers(blk);
    while (progress) {
        progress = false;
        vi_foreach_block_rev(s, blk) {
            bool h = blk->helpers_in || (blk->succ[0] && blk->succ[0]->helpers_in) || (blk->succ[1] && blk->succ[1]->helpers_in);
            if (h != blk->helpers_in) { blk->helpers_in = h; progress = true; }
        }
    }
}

static bool terminates_helpers(vi_block *blk)
{
    for (unsigned k = 0; k < 2; k++) if (blk->succ[k] && blk->succ[k]->helpers_in) return false;
    return true;
}

static bool discard_before_block(vi_block *blk)
{
    if (blk->helpers_in) return false;
    if (util_dynarray_num_elements(&blk->preds, vi_block *) != 1) return false;
    vi_block *pred = *util_dynarray_element(&blk->preds, vi_block *, 0);
    for (unsigned k = 0; k < 2; k++) if (pred->succ[k] && pred->succ[k]->helpers_in) return true;
    return false;
}

// ---- Merging --------------------------------------------------------------------------------------------------------

static vi_instr *prev_instr(vi_block *blk, vi_instr *I) { return I->link.prev == &blk->instrs ? NULL : list_entry(I->link.prev, vi_instr, link); }

static void merge_end_reconverge(vi_block *blk)
{
    if (list_is_empty(&blk->instrs) || list_is_singular(&blk->instrs)) return;
    vi_instr *last = list_last_entry(&blk->instrs, vi_instr, link);
    if (!last->is_nop || (last->flow != F_RECONVERGE && last->flow != F_END)) return;
    vi_instr *penult = prev_instr(blk, last);
    if (last->flow == F_END) {
        // end implies every wait except on barriers
        while (penult && penult->is_nop && penult->flow != F_WAIT) {
            list_del(&penult->link);
            penult = prev_instr(blk, last);
        }
        if (!penult) return;
    }
    if (penult->flow != F_NONE) return;
    penult->flow = last->flow;
    list_del(&last->link);
}

static void merge_waits(vi_block *blk)
{
    vi_instr *last_free = NULL;
    vi_foreach_instr_safe(blk, I) {
        if (last_free && I->is_nop && is_wait_or_none(I->flow)) {
            last_free->flow = union_waits(last_free->flow, I->flow);
            list_del(&I->link);
            continue;
        }
        if (vi_is_msg(I)) last_free = NULL;
        if (is_wait_or_none(I->flow) && !(I->is_nop && I->flow == F_NONE)) last_free = I;
    }
}

static void merge_discard(vi_block *blk)
{
    vi_foreach_instr_safe(blk, I) {
        if (!I->is_nop || I->flow != F_DISCARD) continue;
        vi_instr *prev = prev_instr(blk, I);
        if (prev && prev->flow == F_NONE) { prev->flow = F_DISCARD; list_del(&I->link); continue; }
        // else try the next instruction... only when it has no flow (discard may move down)
        if (I->link.next != &blk->instrs) {
            vi_instr *next = list_entry(I->link.next, vi_instr, link);
            if (next->flow == F_NONE && !next->is_nop && !vi_is_branch(next)) { next->flow = F_DISCARD; list_del(&I->link); }
        }
    }
}

// ---- Pass -----------------------------------------------------------------------------------------------------------

static bool reconverge_branches(vi_block *blk)
{
    if (!blk->succ[0]) return false;
    if (!blk->succ[1]) return util_dynarray_num_elements(&blk->succ[0]->preds, vi_block *) > 1;
    return true;
}

static bool shader_empty(vi_shader *s)
{
    vi_foreach_block(s, blk) if (!list_is_empty(&blk->instrs)) return false;
    return true;
}

void vi_insert_flow(vi_shader *s, bool fragment)
{
    if (shader_empty(s)) return;
    assign_slots(s);
    vi_foreach_block(s, blk) { memset(blk->sb_write_out, 0, sizeof blk->sb_write_out); memset(blk->sb_out, 0, sizeof blk->sb_out); blk->sb_in[7] = 0; }
    for (unsigned iter = 0; iter < 64; iter++) {
        bool changed = false;
        vi_foreach_block(s, blk) changed |= sb_block(blk, false);
        if (!changed) break;
    }
    vi_foreach_block(s, blk) sb_block(blk, true);
    if (fragment) analyze_helpers(s);

    vi_foreach_block(s, blk) {
        if (fragment && discard_before_block(blk)) {
            vi_instr *first = list_is_empty(&blk->instrs) ? NULL : list_first_entry(&blk->instrs, vi_instr, link);
            nop_at(s, blk, first, F_DISCARD);
        }
        vi_foreach_instr_safe(blk, I) {
            if (I->is_nop) continue;
            uint8_t waits = I->wait_before;
            if (I->op == VA_BLEND) {
                nop_at(s, blk, I, F_WAIT);
            } else if (I->op == VA_ST_TILE || I->op == VA_LD_TILE) {
                nop_at(s, blk, I, F_WAIT);
            } else if (I->op == VA_ATEST) {
                nop_at(s, blk, I, F_WAIT0126);
                vi_instr *next = I->link.next == &blk->instrs ? NULL : list_entry(I->link.next, vi_instr, link);
                nop_at(s, blk, next, 1);   // wait0 after
            } else if (I->op == VA_ZS_EMIT) {
                nop_at(s, blk, I, F_WAIT0126);
            } else if (I->op == VA_BARRIER) {
                vi_instr *next = I->link.next == &blk->instrs ? NULL : list_entry(I->link.next, vi_instr, link);
                nop_at(s, blk, next, F_WAIT);
            }
            if (waits) nop_at(s, blk, I, waits);
        }
        if (blk->sb_in[7]) nop_at(s, blk, NULL, blk->sb_in[7]);
        // Helper invocations die after their last use in a block none of whose successors needs them.
        if (fragment && blk->helpers_in && terminates_helpers(blk)) {
            vi_foreach_instr_rev(blk, I) {
                if (!I->helpers) continue;
                vi_instr *next = I->link.next == &blk->instrs ? NULL : list_entry(I->link.next, vi_instr, link);
                nop_at(s, blk, next, F_DISCARD);
                break;
            }
        }
        bool ends = !blk->succ[0] && !blk->succ[1];
        vi_instr *last = list_is_empty(&blk->instrs) ? NULL : list_last_entry(&blk->instrs, vi_instr, link);
        bool already_ends = last && !last->is_nop && last->flow == F_END;
        if (ends) {
            if (!already_ends && (blk == list_first_entry(&s->blocks, vi_block, link) || util_dynarray_num_elements(&blk->preds, vi_block *)))
                nop_at(s, blk, NULL, F_END);
        } else if (reconverge_branches(blk)) {
            nop_at(s, blk, NULL, F_RECONVERGE);
        }
    }
    vi_block *start = list_first_entry(&s->blocks, vi_block, link);
    if (fragment && !start->helpers_in)
        nop_at(s, start, list_is_empty(&start->instrs) ? NULL : list_first_entry(&start->instrs, vi_instr, link), F_DISCARD);

    vi_foreach_block(s, blk) {
        merge_end_reconverge(blk);
        merge_waits(blk);
        merge_discard(blk);
    }
}
