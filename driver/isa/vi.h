// Viva ISA compiler: machine IR for the direct AIR -> Valhall v9 (Mali-G57) path.
//
// The IR is Valhall itself: every instruction is an opcode of Arm's ISA description (va_v9_gen.h) with its fields,
// plus virtual registers that register allocation turns into r0-r63. There is no intermediate language between
// LLVM IR and this: vi_sel.c selects Valhall instructions straight from the AIR, vi_ra.c allocates registers,
// vi_flow.c adds the flow control (waits, reconverge, end), vi_pack.c encodes.
//
// Values: a virtual register (vreg) is 1..8 consecutive 32-bit words. A value's register image is its memory image
// (little endian): component c of a vector of b-bit elements is at byte c*b/8, so 16-bit vectors are packed two per
// word (v2f16 instructions), 8-bit four per word, 64-bit values take two words, and bitcasts are free. Booleans
// (i1) are one word each, 0 or 1. Scalars narrower than 32 bits sit in the low bits; the bits above are undefined.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include "va_encode.h"
#include "util/bitset.h"
#include "util/list.h"
#include "util/u_dynarray.h"

#define VI_MAX_WORDS 8
#define VI_NUM_REGS 64

typedef enum {
    VI_NONE,
    VI_VREG,      // virtual register (index), word offset
    VI_REG,       // physical register (fixed: preloads, blend ABI)
    VI_FAU,       // user uniform word (FAU word index: 2 * pair + word)
    VI_IMM,       // 32-bit constant (lowered to the hardware table, FAU or a register before packing)
    VI_SPECIAL,   // special FAU: page, index (0xE0 + 2 * entry + word)
    VI_TABLE,     // hardware small-constant table entry (0xC0 + i), after constant lowering
} vi_kind;

typedef struct {
    uint8_t kind;
    uint8_t word;      // VI_VREG: first word used; VI_SPECIAL: page
    uint8_t count;     // words read (staging / 64-bit sources)
    bool last;         // last use of the register (set after RA)
    uint32_t value;    // vreg index / register / FAU word / immediate / special index / table entry
} vi_ref;

static inline vi_ref vi_none(void) { vi_ref r = { VI_NONE, 0, 0, false, 0 }; return r; }
static inline vi_ref vi_vreg(uint32_t v, unsigned word, unsigned count) { vi_ref r = { VI_VREG, (uint8_t)word, (uint8_t)count, false, v }; return r; }
static inline vi_ref vi_reg(unsigned reg) { vi_ref r = { VI_REG, 0, 1, false, reg }; return r; }
static inline vi_ref vi_imm(uint32_t x) { vi_ref r = { VI_IMM, 0, 1, false, x }; return r; }
static inline vi_ref vi_fau(unsigned word) { vi_ref r = { VI_FAU, 0, 1, false, word }; return r; }
static inline vi_ref vi_special(unsigned page, unsigned index) { vi_ref r = { VI_SPECIAL, (uint8_t)page, 1, false, index }; return r; }
static inline bool vi_is_vreg(vi_ref r) { return r.kind == VI_VREG; }

struct vi_block;

typedef struct vi_instr {
    struct list_head link;
    enum va_op op;
    vi_ref dest;           // register destination (dest_register_index)
    vi_ref src[4];         // src0..src3
    vi_ref sr;             // staging registers read
    vi_ref sw;             // staging registers written
    va_vals f;             // every other field (modifiers, offsets, formats)
    uint8_t flow;          // VA_FLOW_CONTROL_M_* (the selector may set end on BLEND; the rest comes from vi_flow.c)
    uint8_t wait_before;   // scoreboard result: slots 0-2 to wait on before this instruction
    int8_t slot;           // message slot, -1 none
    struct vi_block *target;   // branch target (BRANCH*, JUMP)
    // Scoreboard properties (set by the selector)
    bool memory;           // asynchronous memory access (ordering)
    bool varying;          // varying load (hidden register)
    bool helpers;          // needs helper invocations (derivatives, implicit-lod textures)
    bool blend;            // BLEND: wait slot 6/7 before, special handling
    bool is_nop;           // flow-only NOP
    uint64_t clobber;      // registers this instruction may destroy (BLEND: a blend shader uses r0-r15, r48)
    uint32_t pc;           // byte offset after layout
} vi_instr;

typedef struct vi_block {
    struct list_head link;
    struct list_head instrs;
    unsigned index;
    struct vi_block *succ[2];
    struct util_dynarray preds;      // vi_block *
    bool loop_header;
    // analysis
    BITSET_WORD *live_in, *live_out;
    uint64_t reg_live_in;            // after RA
    uint8_t sb_in[8], sb_out[8];     // scoreboard: per slot, kind bits (see vi_flow.c)
    uint64_t sb_write_in[8], sb_write_out[8];
    bool helpers_in;
    uint32_t pc;
} vi_block;

typedef struct {
    uint8_t nwords, align;
    int16_t phys;          // after RA, -1 = none
    int16_t fixed;         // precolored register, -1 = free
    bool multi_def;        // phi variable (not SSA)
    bool spill_temp;       // short-lived copy around a spilled register (never spilled itself)
} vi_vreg_info;

struct pan_fau_layout;

typedef struct vi_shader {
    void *mem;                      // ralloc context
    int stage;                      // MESA_SHADER_*
    struct list_head blocks;
    unsigned nblocks;
    struct util_dynarray vregs;     // vi_vreg_info
    // FAU: user uniform words pushed by the driver (index = FAU word); see vmg_isa.c
    unsigned fau_words;
    uint32_t fau_imm[64];           // immediates promoted to FAU (word index -> value), fau_imm_mask
    uint64_t fau_imm_mask;
    // results
    struct pan_fau_layout *fau;     // uniform words of the program (constants may be promoted into it)
    uint64_t reserved_regs;         // registers RA never assigns (ABI: blend link, preloads still needed)
    unsigned live_words; unsigned *live_base;   // vi_liveness: words of all vregs, first word of each
    unsigned work_regs;
    uint64_t regs_used;
    uint64_t preload;
    unsigned tls_size;              // private memory per thread: scratch (set by the selector) + spill slots
    unsigned spills;
    unsigned max_live;              // most registers in use at once (RA statistic)
    char *error;
} vi_shader;

// ---- Construction ---------------------------------------------------------------------------------------------------
vi_shader *vi_shader_create(int stage);
void vi_shader_free(vi_shader *s);
vi_block *vi_block_create(vi_shader *s);           // appended at the end of the layout
void vi_block_add_succ(vi_block *from, vi_block *to);
uint32_t vi_new_vreg(vi_shader *s, unsigned nwords);
static inline vi_vreg_info *vi_vreg_get(vi_shader *s, uint32_t v) { return util_dynarray_element(&s->vregs, vi_vreg_info, v); }
static inline unsigned vi_num_vregs(vi_shader *s) { return util_dynarray_num_elements(&s->vregs, vi_vreg_info); }

typedef struct { vi_shader *s; vi_block *block; vi_instr *before; } vi_builder;   // before = NULL: append
vi_instr *vi_emit(vi_builder *b, enum va_op op);
static inline void vi_set(vi_instr *I, enum va_field f, int64_t v) { va_set(&I->f, f, v); }

#define vi_foreach_block(s, blk) list_for_each_entry(vi_block, blk, &(s)->blocks, link)
#define vi_foreach_block_rev(s, blk) list_for_each_entry_rev(vi_block, blk, &(s)->blocks, link)
#define vi_foreach_instr(blk, I) list_for_each_entry(vi_instr, I, &(blk)->instrs, link)
#define vi_foreach_instr_safe(blk, I) list_for_each_entry_safe(vi_instr, I, &(blk)->instrs, link)
#define vi_foreach_instr_rev(blk, I) list_for_each_entry_rev(vi_instr, I, &(blk)->instrs, link)

static inline bool vi_is_msg(const vi_instr *I) { return va_op_info[I->op].unit == VA_UNIT_MSG; }
static inline bool vi_is_branch(const vi_instr *I) { return I->target != NULL; }

// ---- Passes ---------------------------------------------------------------------------------------------------------
bool vi_lower_constants(vi_shader *s);               // VI_IMM -> table / FAU / register
bool vi_register_allocate(vi_shader *s);             // vregs -> r0..r63 (false + s->error on failure)
void vi_insert_flow(vi_shader *s, bool fragment);    // slots, waits, reconverge, end, helper discard
void vi_mark_last(vi_shader *s);                     // last-use bits
bool vi_pack(vi_shader *s, struct util_dynarray *binary);   // false + s->error on encoding errors
void vi_print(vi_shader *s, FILE *fp);
bool vi_validate(vi_shader *s);

// Liveness of vregs (vi_ra.c), also used by the flow pass for helper analysis.
void vi_liveness(vi_shader *s);
