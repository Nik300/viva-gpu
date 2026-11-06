// Viva ISA compiler: instruction selection from AIR (LLVM IR) to Valhall (internal).
#pragma once
#include "vi.h"
#include "vmg_isa.h"
#include "vmg_internal.h"
#include "vmg_llvm.h"
#include "util/hash_table.h"
#include "util/ralloc.h"
#include "util/half_float.h"
#include "panfrost/compiler/pan_compiler.h"

typedef enum { SV_NONE, SV_VAL, SV_PTR, SV_AGG, SV_TEX, SV_SMP } sv_kind;
typedef enum { SP_SSBO, SP_SHARED, SP_SCRATCH, SP_POOL, SP_PUSH, SP_GLOBAL } sv_space;   // SP_GLOBAL: 64-bit GPU address (G3)

// A selected LLVM value.
typedef struct sv {
    uint8_t kind;
    // SV_VAL: register image (see vi.h) of ncomp elements of `bits` bits (1 = boolean, one word each)
    uint8_t bits, ncomp;
    bool is_const;
    uint32_t vreg;            // !is_const
    uint32_t cw[16];          // is_const: the words
    // SV_PTR: byte offset `off` (32-bit SV_VAL) into memory `space`; SSBO: binding `slot` (constant)
    uint8_t space;
    int slot;                 // >= 0: [[buffer(slot)]]; -2: chosen at run time (dyn_handle), one of slot_mask
    struct sv *off;
    vi_ref dyn_handle;        // SSBO resource handle (6 << 24 | slot) in a register
    vi_ref addr;              // SP_GLOBAL: base address (2-word register), `off` added to it
    uint32_t slot_mask;
    // SV_AGG
    unsigned n;
    struct sv **e;
    // SV_TEX / SV_SMP
    int index;
    uint64_t word;            // constexpr sampler word
    bool pixel;               // coord::pixel sampler
} sv;

typedef struct S {
    vi_shader *s;
    vi_builder b;
    void *mem;
    LLVMModuleRef mod;
    LLVMTargetDataRef td;
    LLVMValueRef fn;
    int stage;                         // MESA_SHADER_*
    const vmg_air_input *in;
    const vmg_isa_options *opt;
    vmg_reflection *refl;
    struct util_dynarray *pool;
    struct hash_table *vals;           // LLVMValueRef -> sv*
    struct hash_table *blocks;         // LLVMBasicBlockRef -> vi_block*
    struct hash_table *phis;           // LLVMValueRef (phi) -> sv* (multi-def vreg)
    struct hash_table *globals;        // LLVMValueRef -> sv* (placement)
    uint64_t used;                     // features used (bit = enum vmg_isa_feature)
    bool no_nans;
    bool push;                         // small constant buffers in the push window (C2)
    unsigned scratch, shared;
    char *error;
    void *io;                          // stage I/O state (vi_sel_io.c)
    struct { struct sv *result; vi_block *cont; } *iret;   // inside a callee inlined at an indirect call (G4)
    unsigned inline_depth;
    // Results for pan_shader_info (vmg_isa.c)
    struct pan_fau_layout *fau;        // pushed words: UBO relocations / constants
    unsigned sysvals[32], nsysvals;    // PAN_SYSVAL(type, id) per sysval slot (UBO 1, 16 bytes each)
    uint32_t ubo_mask;                 // hardware UBOs read through LD_PKA
    int idvs;                          // vertex: 0 = all outputs, 1 = position (+psiz), 2 = position without psiz, 3 = varyings
    uint32_t attached;                 // fragment: render targets with an attachment (B7), ~0 = all
    struct pan_varying_layout vs_layout, fs_formats;
    uint32_t fs_noperspective;
    struct {
        bool discard, writes_depth, writes_stencil, writes_coverage, reads_frag_coord, reads_face, reads_point_coord,
             reads_primitive_id, sample_shading, helpers, uses_ld_var, flat, early_fragment_tests, writes_global,
             barrier, subgroups, writes_psiz, fbfetch;
        uint32_t outputs_read, colors_written;
        uint64_t outputs_written;
        unsigned blend_type[8], blend_src1_type;
        uint32_t attributes_read;
        unsigned texture_count, sampler_count;
        uint64_t images_used;
    } info;
} S;

// FAU / sysvals / UBOs (vi_sel_io.c). Hardware UBOs: 0 = constant buffer 0 (system values header + push window),
// 1 = Gallium's sysval UBO (every ISA shader requests at least one sysval), 2 = the constant pool.
#define VI_UBO_CB0 0
#define VI_UBO_SYSVALS 1
#define VI_UBO_POOL 2
vi_ref sel_fau_ubo(S *t, unsigned ubo, unsigned byte_offset);         // a pushed UBO word (FAU)
vi_ref sel_fau_const_pair(S *t, uint32_t lo, uint32_t hi);            // a 64-bit FAU slot of constants (count 2)
unsigned sel_sysval(S *t, unsigned type, unsigned id);                // slot index of PAN_SYSVAL(type, id)
vi_ref sel_sysval_comp(S *t, unsigned type, unsigned id, unsigned comp);
vi_ref sel_pair(S *t, vi_ref lo, vi_ref hi);                          // 2-word register pair
vi_ref sel_ssbo_handle(S *t, const sv *p);                            // resource handle of an SSBO pointer

#define SFAIL(t, ...) do { if (!(t)->error) (t)->error = vmg_strdup_printf(__VA_ARGS__); return NULL; } while (0)
#define SFAILB(t, ...) do { if (!(t)->error) (t)->error = vmg_strdup_printf(__VA_ARGS__); return false; } while (0)

// Feature use: false (with t->error = "feature X disabled") when its toggle sends it to the NIR path.
bool sel_use(S *t, enum vmg_isa_feature f);
#define USE(t, F) do { if (!sel_use((t), VMG_ISA_##F)) return NULL; } while (0)
#define USEB(t, F) do { if (!sel_use((t), VMG_ISA_##F)) return false; } while (0)

// ---- Values ---------------------------------------------------------------------------------------------------------
sv *sv_new(S *t, sv_kind k);
sv *sv_val(S *t, unsigned bits, unsigned ncomp);           // fresh register value
sv *sv_const(S *t, unsigned bits, unsigned ncomp, const uint32_t *words);
sv *sv_const32(S *t, uint32_t x);
unsigned sv_words(unsigned bits, unsigned ncomp);
sv *sel_value(S *t, LLVMValueRef v);
sv *sel_ssa(S *t, LLVMValueRef v);                         // SV_VAL or fail
vi_ref sv_word(S *t, sv *v, unsigned w);                   // word w (VI_IMM if constant)
vi_ref sv_vec(S *t, sv *v);                                // whole value as one register range (materialized)
sv *sv_materialize(S *t, sv *v);                           // constant -> registers
// Component c widened to a 32-bit word: 32-bit as is, 16-bit/8-bit extracted (sign/zero/float per `how`).
enum { X_ZEXT, X_SEXT, X_F32 };
vi_ref sv_comp32(S *t, sv *v, unsigned c, int how);
sv *sv_from_comps32(S *t, unsigned bits, unsigned ncomp, vi_ref *c32);   // pack 32-bit words to an image
sv *sv_scalar(S *t, sv *v, unsigned c);                    // one element as its own value

// ---- Types ----------------------------------------------------------------------------------------------------------
bool sel_type_info(LLVMTypeRef ty, unsigned *bits, unsigned *ncomp, bool *flt);
bool sel_is_float(LLVMTypeRef ty);
uint64_t sel_tsize(S *t, LLVMTypeRef ty);
uint64_t sel_tstore(S *t, LLVMTypeRef ty);
char *sel_name(LLVMValueRef v);
bool sel_name_is(const char *name, const char *prefix);

// ---- Emission helpers -----------------------------------------------------------------------------------------------
vi_instr *E(S *t, enum va_op op);                                     // at the cursor
vi_ref sel_mov32(S *t, vi_ref x);                                     // x into a new 1-word vreg
vi_ref sel_tmp(S *t);                                                 // new 1-word vreg ref
vi_ref sel_alu2(S *t, enum va_op op, vi_ref a, vi_ref b);             // 32-bit dest
vi_ref sel_alu1(S *t, enum va_op op, vi_ref a);
vi_ref sel_iadd_imm(S *t, vi_ref a, int32_t imm);
vi_ref sel_imul_imm(S *t, vi_ref a, uint32_t imm);
vi_ref sel_csel(S *t, int cmpf, enum va_op op, vi_ref a, vi_ref b, vi_ref x, vi_ref y);   // (a cmp b) ? x : y
vi_ref sel_bool_to_mask(S *t, vi_ref b);

// ---- Parts ----------------------------------------------------------------------------------------------------------
sv *sel_alu_instr(S *t, LLVMValueRef inst, LLVMOpcode op);            // vi_sel_alu.c
sv *sel_compare(S *t, LLVMValueRef inst, bool flt);
sv *sel_cast(S *t, LLVMValueRef inst, LLVMOpcode op);
sv *sel_select(S *t, LLVMValueRef inst);
sv *sel_shuffle(S *t, LLVMValueRef inst);
sv *sel_extract_element(S *t, LLVMValueRef inst);
sv *sel_insert_element(S *t, LLVMValueRef inst);
sv *sel_math(S *t, LLVMValueRef inst, const char *name);              // air.* / llvm.* math
sv *sel_convert(S *t, LLVMValueRef inst, const char *name);           // air.convert.*

sv *sel_gep(S *t, LLVMValueRef inst, unsigned nops);                  // vi_sel_mem.c
sv *sel_load(S *t, LLVMValueRef inst);
bool sel_store(S *t, LLVMValueRef inst);
sv *sel_alloca(S *t, LLVMValueRef inst);
sv *sel_global(S *t, LLVMValueRef g);
sv *sel_memcpy_set(S *t, LLVMValueRef inst, bool set);
sv *sel_atomic(S *t, LLVMValueRef inst, const char *name);
sv *sel_barrier(S *t, LLVMValueRef inst, bool execution);
sv *sel_sysval_word(S *t, unsigned byte_off);                         // constant buffer 0 (system values header)

sv *sel_texture(S *t, LLVMValueRef inst, const char *name);           // vi_sel_tex.c

bool sel_io_begin(S *t, LLVMValueRef outputs_md, LLVMValueRef inputs_md);   // vi_sel_io.c
bool sel_io_return(S *t, LLVMValueRef ret);
sv *sel_io_call(S *t, LLVMValueRef inst, const char *name);           // stage builtins called as functions
bool sel_io_finish(S *t);

sv *sel_subgroup(S *t, LLVMValueRef inst, const char *name);          // vi_sel_sg.c
sv *sel_zext_odd(S *t, sv *v, LLVMTypeRef ty);                        // vi_sel_alu.c

bool sel_function(S *t, LLVMValueRef outputs_md, LLVMValueRef inputs_md, vi_block **exit_out);   // vi_sel.c
