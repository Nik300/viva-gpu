// Viva Metal - AIR (Metal's LLVM IR) -> NIR translator.
//
// Input: the bitcode Metal.framework keeps in every MTLFunction, parsed with the system libLLVM (vmg_llvm.h) and
// cleaned with LLVM passes (inline, sroa, instcombine, simplifycfg, lowerswitch), as in metal-shim.
// Output: a NIR shader for a Gallium driver (llvmpipe on the Mac, Panfrost on the phone).
//
// Design (differs from metal-shim's AIR -> GLSL on purpose):
//   - Every memory is byte addressed. A pointer is (space, slot, byte offset):
//       device/constant buffers [[buffer(n)]]  -> SSBO n            (load_ssbo / store_ssbo: Metal layouts exact)
//       threadgroup memory                     -> shared memory     (load_shared / store_shared)
//       private memory (allocas)               -> scratch           (load_scratch / store_scratch)
//       constant tables (module globals)       -> constant buffer 1 (the shader's pool)
//     so type punning, pointer arithmetic and casts need no special cases. LLVM's SROA already turned the allocas
//     that matter into SSA values; what is left is dynamically indexed.
//   - Control flow is emitted unstructured (one NIR block per LLVM block, goto / goto_if), then
//     nir_lower_goto_ifs structures it, as spirv_to_nir does for OpenCL. Phis are local variables stored on the
//     incoming edges, turned back into SSA by nir_lower_vars_to_ssa.
//   - Inputs/outputs come from the !air.vertex / !air.fragment / !air.kernel metadata; varyings get
//     VARYING_SLOT_VAR0 + (index of their key in the pipeline's table), so the vertex and fragment functions of a
//     pipeline, translated separately, agree.
//   - Textures: nir_tex_instr with texture_index = [[texture(n)]], sampler_index = [[sampler(n)]] or a constexpr
//     sampler at VMG_CONSTEXPR_SAMPLER_BASE + k. Written textures are images with the same index.
//
// Constant buffer 0 = per-draw system values (VMG_SYSVAL_HEADER bytes, uploaded by the encoder, vmg_exec.c):
//   0   uint32 threadgroup_offset[8]   byte offset of each [[threadgroup(n)]] argument in shared memory
//   32  uint32 threads_per_grid[3], pad
//   48  uint32 render target sample count (air.get_num_samples), reserved[3]
//   64  uint32 buffer_base[32]         byte offset of each [[buffer(n)]] binding inside its SSBO, only with
//                                      VMG_SSBO_BASE=1 (drivers that realign SSBO bindings; Panfrost does not)
// Constant buffer 1 = the shader's constant pool (module constant tables), bound from the shader object.
//
// constexpr sampler word (MSL), as decoded by metal-shim: address s/t/r 3 bits each (bits 0-8), mag 9-10, min
// 11-12, mip 13-14, coord::pixel 15, compare 16-19, max anisotropy - 1 20-23, lod min/max as half 24-39/40-55,
// border 56-57.
#include "vmg_internal.h"
#include "vmg_llvm.h"
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nir.h"
#include "nir_builder.h"
#include "nir_builtin_builder.h"
#include "compiler/glsl_types.h"
#include "util/hash_table.h"
#include "util/ralloc.h"
#include "util/u_dynarray.h"

#define TS_LLVM_DEFINE(ret, name, args) ret (*ts_##name) args;
TS_LLVM_FUNCS(TS_LLVM_DEFINE)
TS_LLVM_OPTIONAL_FUNCS(TS_LLVM_DEFINE)
#undef TS_LLVM_DEFINE

static int g_llvm_loaded;
static const char *g_llvm_failure;
static void llvm_load_once(void)
{
    const char *paths[] = {
        "/usr/lib/libLLVM.dylib",   // iOS 16 (shared cache)
        "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib",
        "/System/Library/PrivateFrameworks/GPUCompiler.framework/Libraries/libLLVM.dylib",
    };
    void *h = NULL;
    for (unsigned i = 0; i < sizeof paths / sizeof paths[0] && !h; i++) h = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
    if (!h) { g_llvm_failure = "libLLVM not found"; return; }
#define TS_LLVM_RESOLVE(ret, name, args) \
    if (!(ts_##name = (ret (*) args)dlsym(h, #name))) { g_llvm_failure = "libLLVM lacks " #name; return; }
    TS_LLVM_FUNCS(TS_LLVM_RESOLVE)
#undef TS_LLVM_RESOLVE
#define TS_LLVM_RESOLVE_OPT(ret, name, args) ts_##name = (ret (*) args)dlsym(h, #name);
    TS_LLVM_OPTIONAL_FUNCS(TS_LLVM_RESOLVE_OPT)
#undef TS_LLVM_RESOLVE_OPT
    g_llvm_loaded = 1;
}

int vmg_llvm_load(const char **error)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, llvm_load_once);
    if (error) *error = g_llvm_failure;
    return g_llvm_loaded;
}

char *vmg_strdup_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *s = NULL;
    if (vasprintf(&s, fmt, ap) < 0) s = NULL;
    va_end(ap);
    return s;
}

const char *vmg_air_tag(void) { return "vmg-air-nir-1"; }

// ---- Values ---------------------------------------------------------------------------------------------------------

typedef enum { V_NONE, V_SSA, V_AGG, V_PTR, V_TEX, V_SMP } vkind;
typedef enum { SP_SSBO, SP_SHARED, SP_SCRATCH, SP_POOL } vspace;

typedef struct val {
    vkind kind;
    nir_def *def;                 // V_SSA
    unsigned n; struct val **e;   // V_AGG members
    vspace sp; nir_def *slot;     // V_PTR: SSBO index (32-bit, SP_SSBO only)
    nir_def *off;                 //        byte offset (32-bit)
    int index;                    // V_TEX: [[texture(n)]]; V_SMP: sampler slot
    uint64_t word;                // V_SMP constexpr word
    bool pixel;                   // V_SMP: coord::pixel
} val;

typedef struct {
    LLVMModuleRef mod;
    LLVMTargetDataRef td;
    LLVMValueRef fn;
    mesa_shader_stage stage;
    nir_shader *s;
    nir_builder b;
    nir_function_impl *impl;
    void *mem;                    // ralloc context for vals
    struct hash_table *vals;      // LLVMValueRef -> val*
    struct hash_table *blocks;    // LLVMBasicBlockRef -> nir_block*
    struct hash_table *phis;      // LLVMValueRef (phi) -> nir_variable*
    struct hash_table *globals;   // LLVMValueRef (global) -> val* (pointers: space + offset in index)
    const vmg_air_input *in;
    vmg_reflection *refl;
    struct util_dynarray *pool;
    // Outputs: one per return member.
    unsigned nout;
    nir_variable *out[40];
    bool out_int_cast[40];
    nir_variable *color_out[VMG_MAX_COLOR];   // render target variables (also read by programmable blending)
    nir_variable *tex_vars[VMG_MAX_TEXTURES], *img_vars[VMG_MAX_TEXTURES], *smp_vars[32];
    unsigned scratch, shared;
    bool no_nans;                 // fast math (Metal's default): NaN constants are poison
    char *error;
} T;

#define FAIL(t, ...) do { if (!(t)->error) (t)->error = vmg_strdup_printf(__VA_ARGS__); return NULL; } while (0)
#define FAILB(t, ...) do { if (!(t)->error) (t)->error = vmg_strdup_printf(__VA_ARGS__); return false; } while (0)

static val *vnew(T *t, vkind k) { val *v = rzalloc(t->mem, val); v->kind = k; return v; }
static val *vssa(T *t, nir_def *d) { val *v = vnew(t, V_SSA); v->def = d; return v; }
static val *vptr(T *t, vspace sp, nir_def *slot, nir_def *off) { val *v = vnew(t, V_PTR); v->sp = sp; v->slot = slot; v->off = off; return v; }

static char *llvm_name(LLVMValueRef v)
{
    size_t len = 0;
    const char *n = v ? ts_LLVMGetValueName2(v, &len) : NULL;
    return n && len ? strndup(n, len) : NULL;
}

// ---- Types ----------------------------------------------------------------------------------------------------------

// Drivers without fp16 (llvmpipe on most Macs): half values are 32-bit floats in registers and 16-bit in memory.
// Panfrost has native fp16 and keeps them 16-bit. Set per translation (thread local: pipelines translate in parallel).
static _Thread_local bool g_half32;

// LLVM 12+ separates poison from undef; iOS 16's libLLVM has no LLVMIsPoison (and treats both as undef).
static bool is_undef(LLVMValueRef v) { return ts_LLVMIsUndef(v) || (ts_LLVMIsPoison && ts_LLVMIsPoison(v)); }

static bool is_half_type(LLVMTypeRef t)
{
    if (ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind) t = ts_LLVMGetElementType(t);
    return ts_LLVMGetTypeKind(t) == LLVMHalfTypeKind;
}

static bool scalar_info(LLVMTypeRef t, unsigned *bits, bool *flt)
{
    switch (ts_LLVMGetTypeKind(t)) {
    case LLVMIntegerTypeKind: *bits = ts_LLVMGetIntTypeWidth(t); *flt = false; return *bits <= 64;
    case LLVMHalfTypeKind: *bits = g_half32 ? 32 : 16; *flt = true; return true;
    case LLVMFloatTypeKind: *bits = 32; *flt = true; return true;
    case LLVMDoubleTypeKind: *bits = 64; *flt = true; return true;
    case LLVMBFloatTypeKind: return false;
    default: return false;
    }
}

// (bits, components, float) of a scalar or vector type; false for aggregates/pointers.
static bool type_info(LLVMTypeRef t, unsigned *bits, unsigned *comps, bool *flt)
{
    if (ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind) {
        *comps = ts_LLVMGetVectorSize(t);
        return scalar_info(ts_LLVMGetElementType(t), bits, flt);
    }
    *comps = 1;
    return scalar_info(t, bits, flt);
}

static bool is_float(LLVMTypeRef t) { unsigned b, c; bool f = false; return type_info(t, &b, &c, &f) && f; }
static bool is_aggregate(LLVMTypeRef t) { LLVMTypeKind k = ts_LLVMGetTypeKind(t); return k == LLVMStructTypeKind || k == LLVMArrayTypeKind; }
static bool is_ptr(LLVMTypeRef t) { return ts_LLVMGetTypeKind(t) == LLVMPointerTypeKind; }
static uint64_t tsize(T *t, LLVMTypeRef ty) { return ts_LLVMABISizeOfType(t->td, ty); }
static uint64_t tstore(T *t, LLVMTypeRef ty) { return ts_LLVMStoreSizeOfType(t->td, ty); }

static const struct glsl_type *glsl_for(unsigned bits, unsigned comps, bool flt)
{
    enum glsl_base_type base;
    if (bits == 1) base = GLSL_TYPE_BOOL;
    else if (flt) base = bits == 16 ? GLSL_TYPE_FLOAT16 : bits == 64 ? GLSL_TYPE_DOUBLE : GLSL_TYPE_FLOAT;
    else base = bits == 8 ? GLSL_TYPE_UINT8 : bits == 16 ? GLSL_TYPE_UINT16 : bits == 64 ? GLSL_TYPE_UINT64 : GLSL_TYPE_UINT;
    return glsl_vector_type(base, comps);
}

static const struct glsl_type *glsl_for_def(nir_def *d) { return glsl_for(d->bit_size, d->num_components, false); }

// ---- Constants ------------------------------------------------------------------------------------------------------

static val *value(T *t, LLVMValueRef v);
static val *const_expr(T *t, LLVMValueRef c);

static nir_def *zero_of(T *t, LLVMTypeRef ty)
{
    unsigned bits, comps; bool flt;
    if (!type_info(ty, &bits, &comps, &flt)) return NULL;
    return nir_imm_zero(&t->b, comps, bits);
}

static val *zero_val(T *t, LLVMTypeRef ty)
{
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (k == LLVMStructTypeKind || k == LLVMArrayTypeKind) {
        unsigned n = k == LLVMStructTypeKind ? ts_LLVMCountStructElementTypes(ty) : ts_LLVMGetArrayLength(ty);
        val *a = vnew(t, V_AGG);
        a->n = n; a->e = ralloc_array(t->mem, val *, n ? n : 1);
        for (unsigned i = 0; i < n; i++) {
            LLVMTypeRef et = k == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(ty, i) : ts_LLVMGetElementType(ty);
            if (!(a->e[i] = zero_val(t, et))) return NULL;
        }
        return a;
    }
    if (k == LLVMPointerTypeKind) return vptr(t, SP_SCRATCH, NULL, nir_imm_int(&t->b, 0));
    nir_def *z = zero_of(t, ty);
    return z ? vssa(t, z) : NULL;
}

static nir_def *scalar_const(T *t, LLVMValueRef c, LLVMTypeRef ty)
{
    unsigned bits; bool flt;
    if (!scalar_info(ty, &bits, &flt)) return NULL;
    if (is_undef(c) || ts_LLVMIsAConstantAggregateZero(c)) return nir_imm_zero(&t->b, 1, bits);
    if (flt) {
        LLVMBool lost;
        double d = ts_LLVMConstRealGetDouble(c, &lost);
        // Under fast math Apple's compiler leaves NaN constants that the GPU never lets through, e.g. CoreAnimation's
        // rounded clip (TbdsXc_*: mix(backdrop, NaN, coverage), only coverage 0 survives). NIR folds them through
        // flrp into NaN everywhere (black corners). They are poison there: any value is right, 0 keeps the rest.
        if (d != d && t->no_nans) d = 0;
        return nir_imm_floatN_t(&t->b, d, bits);
    }
    if (ts_LLVMIsAConstantInt(c)) {
        uint64_t u = ts_LLVMConstIntGetZExtValue(c);
        return bits == 1 ? nir_imm_bool(&t->b, u & 1) : nir_imm_intN_t(&t->b, u, bits);
    }
    return NULL;
}

static val *constant(T *t, LLVMValueRef c)
{
    LLVMTypeRef ty = ts_LLVMTypeOf(c);
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (ts_LLVMIsAConstantExpr(c)) return const_expr(t, c);
    if (ts_LLVMIsAGlobalVariable(c) || ts_LLVMIsAFunction(c)) return value(t, c);
    if (is_undef(c) || ts_LLVMIsAConstantAggregateZero(c) || ts_LLVMIsAConstantPointerNull(c))
        return zero_val(t, ty);
    if (k == LLVMVectorTypeKind) {
        unsigned n = ts_LLVMGetVectorSize(ty);
        LLVMTypeRef et = ts_LLVMGetElementType(ty);
        nir_def *comps[16];
        if (n > 16) FAIL(t, "vector of %u", n);
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef e = ts_LLVMIsAConstantDataSequential(c) ? ts_LLVMGetElementAsConstant(c, i) : ts_LLVMGetOperand(c, i);
            if (!(comps[i] = scalar_const(t, e, et))) FAIL(t, "unsupported vector constant");
        }
        return vssa(t, nir_vec(&t->b, comps, n));
    }
    if (k == LLVMStructTypeKind || k == LLVMArrayTypeKind) {
        unsigned n = k == LLVMStructTypeKind ? ts_LLVMCountStructElementTypes(ty) : ts_LLVMGetArrayLength(ty);
        val *a = vnew(t, V_AGG);
        a->n = n; a->e = ralloc_array(t->mem, val *, n ? n : 1);
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef e = ts_LLVMIsAConstantDataSequential(c) ? ts_LLVMGetElementAsConstant(c, i) : ts_LLVMGetOperand(c, i);
            if (!(a->e[i] = constant(t, e))) return NULL;
        }
        return a;
    }
    nir_def *d = scalar_const(t, c, ty);
    if (!d) FAIL(t, "unsupported constant");
    return vssa(t, d);
}

// Bytes of a constant (constant pool): little-endian, data layout offsets.
static bool serialize_const(T *t, LLVMValueRef c, uint8_t *out, uint64_t size)
{
    LLVMTypeRef ty = ts_LLVMTypeOf(c);
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (is_undef(c) || ts_LLVMIsAConstantAggregateZero(c) || ts_LLVMIsAConstantPointerNull(c)) {
        memset(out, 0, size);
        return true;
    }
    if (k == LLVMStructTypeKind) {
        unsigned n = ts_LLVMCountStructElementTypes(ty);
        memset(out, 0, size);
        for (unsigned i = 0; i < n; i++) {
            uint64_t off = ts_LLVMOffsetOfElement(t->td, ty, i);
            LLVMTypeRef et = ts_LLVMStructGetTypeAtIndex(ty, i);
            if (!serialize_const(t, ts_LLVMGetOperand(c, i), out + off, tstore(t, et))) return false;
        }
        return true;
    }
    if (k == LLVMArrayTypeKind || k == LLVMVectorTypeKind) {
        unsigned n = k == LLVMArrayTypeKind ? ts_LLVMGetArrayLength(ty) : ts_LLVMGetVectorSize(ty);
        LLVMTypeRef et = ts_LLVMGetElementType(ty);
        uint64_t es = k == LLVMArrayTypeKind ? tsize(t, et) : tstore(t, et);
        memset(out, 0, size);
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef e = ts_LLVMIsAConstantDataSequential(c) ? ts_LLVMGetElementAsConstant(c, i) : ts_LLVMGetOperand(c, i);
            if (!serialize_const(t, e, out + i * es, tstore(t, et))) return false;
        }
        return true;
    }
    unsigned bits; bool flt;
    if (!scalar_info(ty, &bits, &flt)) return false;
    if (ts_LLVMGetTypeKind(ty) == LLVMHalfTypeKind) bits = 16;   // memory form, even when widened in registers
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

// ---- Memory ---------------------------------------------------------------------------------------------------------

static unsigned align_of(uint64_t a) { return a ? (unsigned)MIN2(a, 16) : 4; }

static nir_def *sysval_word(T *t, unsigned byte_off, unsigned comps);

// Byte offset of a buffer pointer inside its SSBO: the pointer's offset plus the binding's base (system values).
static nir_def *ssbo_offset(T *t, val *p)
{
    nir_builder *b = &t->b;
    // Panfrost aligns SSBO bindings to 4 bytes, as Metal does: bindings are exact and no base is needed. The base table
    // (VMG_SSBO_BASE=1) is for drivers that would realign bindings.
    static int base_on = -1;
    if (base_on < 0) base_on = getenv("VMG_SSBO_BASE") != NULL;
    if (!base_on) return p->off;
    nir_def *base;
    if (nir_src_is_const(nir_src_for_ssa(p->slot))) base = sysval_word(t, 64 + 4 * (unsigned)nir_src_as_uint(nir_src_for_ssa(p->slot)), 1);
    else base = nir_load_ubo(b, 1, 32, nir_imm_int(b, 0), nir_iadd_imm(b, nir_imul_imm(b, p->slot, 4), 64), .align_mul = 4,
                             .align_offset = 0, .range_base = 0, .range = VMG_SYSVAL_HEADER);
    return nir_iadd(b, p->off, base);
}

static nir_def *mem_load(T *t, val *p, unsigned comps, unsigned bits, unsigned align)
{
    nir_builder *b = &t->b;
    unsigned lbits = bits == 1 ? 8 : bits;
    nir_def *d;
    switch (p->sp) {
    case SP_SSBO:
        d = nir_load_ssbo(b, comps, lbits, p->slot, ssbo_offset(t, p), .align_mul = MIN2(align, 4), .align_offset = 0);
        break;
    case SP_POOL:
        d = nir_load_ubo(b, comps, lbits, nir_imm_int(b, 1), p->off, .align_mul = align, .align_offset = 0,
                         .range_base = 0, .range = 65536);
        break;
    case SP_SHARED: d = nir_load_shared(b, comps, lbits, p->off, .align_mul = align, .align_offset = 0); break;
    default: d = nir_load_scratch(b, comps, lbits, p->off, .align_mul = align, .align_offset = 0); break;
    }
    if (bits == 1) d = nir_ine_imm(b, d, 0);
    return d;
}

static bool mem_store(T *t, val *p, nir_def *d, unsigned align)
{
    nir_builder *b = &t->b;
    if (d->bit_size == 1) d = nir_b2iN(b, d, 8);
    switch (p->sp) {
    case SP_SSBO:
        nir_store_ssbo(b, d, p->slot, ssbo_offset(t, p), .align_mul = MIN2(align, 4), .align_offset = 0,
                       .write_mask = nir_component_mask(d->num_components));
        return true;
    case SP_SHARED:
        nir_store_shared(b, d, p->off, .align_mul = align, .align_offset = 0, .write_mask = nir_component_mask(d->num_components));
        return true;
    case SP_SCRATCH:
        nir_store_scratch(b, d, p->off, .align_mul = align, .align_offset = 0, .write_mask = nir_component_mask(d->num_components));
        return true;
    default: FAILB(t, "store into constant memory");
    }
}

static val *ptr_add(T *t, val *p, nir_def *bytes)
{
    return vptr(t, p->sp, p->slot, nir_iadd(&t->b, p->off, bytes->bit_size == 32 ? bytes : nir_u2u32(&t->b, bytes)));
}
static val *ptr_add_imm(T *t, val *p, int64_t bytes) { return bytes ? vptr(t, p->sp, p->slot, nir_iadd_imm(&t->b, p->off, bytes)) : p; }

// Typed load, recursing into aggregates (members at their data-layout offsets).
static val *load_typed(T *t, val *p, LLVMTypeRef ty, unsigned align)
{
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (k == LLVMStructTypeKind || k == LLVMArrayTypeKind) {
        unsigned n = k == LLVMStructTypeKind ? ts_LLVMCountStructElementTypes(ty) : ts_LLVMGetArrayLength(ty);
        val *a = vnew(t, V_AGG);
        a->n = n; a->e = ralloc_array(t->mem, val *, n ? n : 1);
        for (unsigned i = 0; i < n; i++) {
            LLVMTypeRef et = k == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(ty, i) : ts_LLVMGetElementType(ty);
            uint64_t off = k == LLVMStructTypeKind ? ts_LLVMOffsetOfElement(t->td, ty, i) : i * tsize(t, et);
            if (!(a->e[i] = load_typed(t, ptr_add_imm(t, p, (int64_t)off), et, off % align ? 1 : align))) return NULL;
        }
        return a;
    }
    if (k == LLVMPointerTypeKind) FAIL(t, "pointer loaded from memory (argument buffers are not supported yet)");
    unsigned bits, comps; bool flt;
    if (!type_info(ty, &bits, &comps, &flt)) FAIL(t, "load of an unsupported type");
    bool widen = g_half32 && is_half_type(ty);   // 16-bit in memory, 32-bit in registers
    unsigned mbits = widen ? 16 : bits;
    nir_def *d;
    if (comps == 3 || comps > 4) {
        // vec3 and wide vectors: per component (a 3-component SSBO load is fine, but keep alignment simple).
        nir_def *c[16];
        unsigned es = (mbits == 1 ? 8 : mbits) / 8;
        for (unsigned i = 0; i < comps; i++) c[i] = mem_load(t, ptr_add_imm(t, p, i * es), 1, mbits, MIN2(align, es));
        d = nir_vec(&t->b, c, comps);
    } else d = mem_load(t, p, comps, mbits, align);
    return vssa(t, widen ? nir_f2f32(&t->b, d) : d);
}

static bool store_typed(T *t, val *p, val *v, LLVMTypeRef ty, unsigned align)
{
    LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
    if (k == LLVMStructTypeKind || k == LLVMArrayTypeKind) {
        if (v->kind != V_AGG) FAILB(t, "aggregate store of a non-aggregate");
        for (unsigned i = 0; i < v->n; i++) {
            LLVMTypeRef et = k == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(ty, i) : ts_LLVMGetElementType(ty);
            uint64_t off = k == LLVMStructTypeKind ? ts_LLVMOffsetOfElement(t->td, ty, i) : i * tsize(t, et);
            if (!store_typed(t, ptr_add_imm(t, p, (int64_t)off), v->e[i], et, off % align ? 1 : align)) return false;
        }
        return true;
    }
    if (v->kind != V_SSA) FAILB(t, "store of a pointer or texture into memory");
    unsigned bits, comps; bool flt;
    if (!type_info(ty, &bits, &comps, &flt)) FAILB(t, "store of an unsupported type");
    nir_def *d = v->def;
    if (g_half32 && is_half_type(ty)) { d = nir_f2f16(&t->b, d); bits = 16; }
    if (comps == 3 || comps > 4) {
        unsigned es = (bits == 1 ? 8 : bits) / 8;
        for (unsigned i = 0; i < comps; i++)
            if (!mem_store(t, ptr_add_imm(t, p, i * es), nir_channel(&t->b, d, i), MIN2(align, es))) return false;
        return true;
    }
    return mem_store(t, p, d, align);
}

// ---- Values of LLVM operands ----------------------------------------------------------------------------------------

static val *global(T *t, LLVMValueRef g)
{
    char *name = llvm_name(g);
    LLVMValueRef init = ts_LLVMGetInitializer(g);
    LLVMTypeRef ty = ts_LLVMGetElementType(ts_LLVMTypeOf(g));
    unsigned as = ts_LLVMGetPointerAddressSpace(ts_LLVMTypeOf(g));
    val *v = NULL;
    if (name && !strncmp(name, "__air_sampler_state", 19)) {
        LLVMValueRef word = init ? (ts_LLVMIsAConstantDataSequential(init) ? ts_LLVMGetElementAsConstant(init, 0) : ts_LLVMGetOperand(init, 0)) : NULL;
        uint64_t w = word && ts_LLVMIsAConstantInt(word) ? ts_LLVMConstIntGetZExtValue(word) : 0;
        unsigned k = 0;
        for (; k < t->refl->constexpr_samplers && t->refl->constexpr_words[k] != w; k++) {}
        if (k == t->refl->constexpr_samplers) {
            if (k >= 16) { free(name); FAIL(t, "more than 16 constexpr samplers"); }
            t->refl->constexpr_words[k] = w;
            t->refl->constexpr_samplers++;
        }
        v = vnew(t, V_SMP);
        v->index = VMG_CONSTEXPR_SAMPLER_BASE + k;
        v->word = w;
        v->pixel = (w >> 15) & 1;
    } else if (as == 3) {
        // threadgroup variable: static shared memory
        uint64_t a = 16, sz = tsize(t, ty);
        t->shared = (unsigned)((t->shared + a - 1) & ~(a - 1));
        v = vptr(t, SP_SHARED, NULL, NULL);
        v->index = (int)t->shared;
        t->shared += (unsigned)sz;
    } else if (init) {
        uint64_t sz = tsize(t, ty);
        unsigned off = (unsigned)((t->pool->size + 15) & ~15u);
        uint8_t *dst;
        while (t->pool->size < off) util_dynarray_append_typed(t->pool, uint8_t, 0);
        dst = util_dynarray_grow(t->pool, uint8_t, sz);
        if (!serialize_const(t, init, dst, sz)) { free(name); FAIL(t, "constant table %s not serializable", name ? name : "?"); }
        v = vptr(t, SP_POOL, NULL, NULL);
        v->index = (int)off;
    } else {
        char msg[128];
        snprintf(msg, sizeof msg, "global %s without initializer", name ? name : "?");
        free(name);
        FAIL(t, "%s", msg);
    }
    free(name);
    return v;
}

static val *gep(T *t, LLVMValueRef inst, unsigned nops);

static val *const_expr(T *t, LLVMValueRef c)
{
    switch (ts_LLVMGetConstOpcode(c)) {
    case LLVMBitCast: case LLVMAddrSpaceCast: return value(t, ts_LLVMGetOperand(c, 0));
    case LLVMGetElementPtr: return gep(t, c, (unsigned)ts_LLVMGetNumOperands(c));
    default: FAIL(t, "unsupported constant expression %d", ts_LLVMGetConstOpcode(c));
    }
}

// Values defined at the point of use: constants and globals are materialized in the current block (NIR's CSE and
// constant folding clean up the duplicates). A global's memory placement is decided once (t->globals) and its
// pointer rebuilt at every use, so no definition has to dominate uses in other blocks.
static val *value(T *t, LLVMValueRef v)
{
    struct hash_entry *he = _mesa_hash_table_search(t->vals, v);
    if (he) return he->data;
    if (ts_LLVMIsAGlobalVariable(v)) {
        he = _mesa_hash_table_search(t->globals, v);
        val *g = he ? he->data : global(t, v);
        if (!g) return NULL;
        if (!he) _mesa_hash_table_insert(t->globals, v, g);
        if (g->kind != V_PTR) return g;
        return vptr(t, g->sp, NULL, nir_imm_int(&t->b, g->index));
    }
    if (ts_LLVMIsAConstant(v)) return constant(t, v);
    char *txt = ts_LLVMPrintValueToString(v);
    if (!t->error) t->error = vmg_strdup_printf("value used before its definition: %.120s", txt ? txt : "?");
    ts_LLVMDisposeMessage(txt);
    return NULL;
}

static nir_def *ssa(T *t, LLVMValueRef v)
{
    val *x = value(t, v);
    if (!x) return NULL;
    if (x->kind != V_SSA) FAIL(t, "expected a scalar or vector value");
    return x->def;
}

// ---- GEP ------------------------------------------------------------------------------------------------------------

static val *gep(T *t, LLVMValueRef inst, unsigned nops)
{
    val *base = value(t, ts_LLVMGetOperand(inst, 0));
    if (!base) return NULL;
    if (base->kind != V_PTR) FAIL(t, "GEP on a non-pointer");
    // Typed pointers (iOS 16's libLLVM): the source element type is the pointee of the base operand.
    LLVMTypeRef ty = ts_LLVMGetGEPSourceElementType ? ts_LLVMGetGEPSourceElementType(inst)
                                                    : ts_LLVMGetElementType(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0)));
    nir_builder *b = &t->b;
    int64_t cst = 0;
    nir_def *dyn = NULL;
    for (unsigned i = 1; i < nops; i++) {
        LLVMValueRef idx = ts_LLVMGetOperand(inst, i);
        if (i == 1) {
            uint64_t es = tsize(t, ty);
            if (ts_LLVMIsAConstantInt(idx)) cst += ts_LLVMConstIntGetSExtValue(idx) * (int64_t)es;
            else {
                nir_def *x = ssa(t, idx);
                if (!x) return NULL;
                x = nir_imul_imm(b, x->bit_size == 32 ? x : nir_i2i32(b, x), (int64_t)es);
                dyn = dyn ? nir_iadd(b, dyn, x) : x;
            }
            continue;
        }
        LLVMTypeKind k = ts_LLVMGetTypeKind(ty);
        if (k == LLVMStructTypeKind) {
            unsigned m = (unsigned)ts_LLVMConstIntGetZExtValue(idx);
            cst += (int64_t)ts_LLVMOffsetOfElement(t->td, ty, m);
            ty = ts_LLVMStructGetTypeAtIndex(ty, m);
        } else if (k == LLVMArrayTypeKind || k == LLVMVectorTypeKind) {
            LLVMTypeRef et = ts_LLVMGetElementType(ty);
            uint64_t es = k == LLVMArrayTypeKind ? tsize(t, et) : tstore(t, et);
            if (ts_LLVMIsAConstantInt(idx)) cst += ts_LLVMConstIntGetSExtValue(idx) * (int64_t)es;
            else {
                nir_def *x = ssa(t, idx);
                if (!x) return NULL;
                x = nir_imul_imm(b, x->bit_size == 32 ? x : nir_i2i32(b, x), (int64_t)es);
                dyn = dyn ? nir_iadd(b, dyn, x) : x;
            }
            ty = et;
        } else FAIL(t, "GEP into a scalar");
    }
    val *p = ptr_add_imm(t, base, cst);
    return dyn ? ptr_add(t, p, dyn) : p;
}

// ---- Entry interface ------------------------------------------------------------------------------------------------

typedef struct { LLVMValueRef ops[64]; unsigned n; } mdops;

static void md_operands(LLVMValueRef node, mdops *o)
{
    o->n = node ? ts_LLVMGetMDNodeNumOperands(node) : 0;
    if (o->n > 64) o->n = 64;
    if (o->n) {
        LLVMValueRef tmp[256];
        unsigned total = ts_LLVMGetMDNodeNumOperands(node);
        if (total > 256) total = 256;
        ts_LLVMGetMDNodeOperands(node, tmp);
        memcpy(o->ops, tmp, o->n * sizeof(LLVMValueRef));
    }
}

static const char *md_string(LLVMValueRef v, unsigned *len)
{
    *len = 0;
    if (!v) return NULL;
    const char *s = ts_LLVMGetMDString(v, len);
    return s;
}

static bool md_is(LLVMValueRef v, const char *str)
{
    unsigned len;
    const char *s = md_string(v, &len);
    return s && len == strlen(str) && !memcmp(s, str, len);
}

static bool md_has(const mdops *o, const char *str)
{
    for (unsigned i = 0; i < o->n; i++) if (md_is(o->ops[i], str)) return true;
    return false;
}

static long md_int_after(const mdops *o, const char *key, long fallback)
{
    for (unsigned i = 0; i + 1 < o->n; i++)
        if (md_is(o->ops[i], key) && o->ops[i + 1] && ts_LLVMIsAConstantInt(o->ops[i + 1]))
            return (long)ts_LLVMConstIntGetSExtValue(o->ops[i + 1]);
    return fallback;
}

static void md_string_after(const mdops *o, const char *key, char *out, size_t size)
{
    out[0] = 0;
    for (unsigned i = 0; i + 1 < o->n; i++) {
        unsigned len;
        const char *s;
        if (md_is(o->ops[i], key) && (s = md_string(o->ops[i + 1], &len))) {
            snprintf(out, size, "%.*s", (int)len, s);
            return;
        }
    }
}

static int varying_slot(T *t, const char *key, unsigned len)
{
    for (unsigned i = 0; i < t->in->varying_count; i++)
        if (strlen(t->in->varyings[i]) == len && !memcmp(t->in->varyings[i], key, len)) return (int)i;
    return -1;
}

static nir_variable *make_var(T *t, nir_variable_mode mode, const struct glsl_type *type, int location, const char *name)
{
    nir_variable *v = nir_variable_create(t->s, mode, type, name);
    v->data.location = location;
    v->data.driver_location = location;
    return v;
}

static nir_def *sysval_word(T *t, unsigned byte_off, unsigned comps)
{
    return nir_load_ubo(&t->b, comps, 32, nir_imm_int(&t->b, 0), nir_imm_int(&t->b, (int)byte_off), .align_mul = 4,
                        .align_offset = 0, .range_base = 0, .range = VMG_SYSVAL_HEADER);
}

static nir_def *fit_lanes(T *t, nir_def *d, LLVMTypeRef ty)
{
    unsigned bits, comps; bool flt;
    if (!type_info(ty, &bits, &comps, &flt)) return d;
    if (d->num_components > comps) d = nir_trim_vector(&t->b, d, comps);
    if (d->bit_size != bits && !flt && bits != 1) d = nir_u2uN(&t->b, d, bits);
    if (d->bit_size != bits && flt) d = nir_f2fN(&t->b, d, bits);
    return d;
}

static bool declare_inputs(T *t, LLVMValueRef node)
{
    mdops list;
    md_operands(node, &list);
    unsigned nparams = ts_LLVMCountParams(t->fn);
    nir_builder *b = &t->b;
    for (unsigned a = 0; a < list.n; a++) {
        mdops o;
        md_operands(list.ops[a], &o);
        if (!o.n || !ts_LLVMIsAConstantInt(o.ops[0])) FAILB(t, "malformed input metadata");
        unsigned idx = (unsigned)ts_LLVMConstIntGetZExtValue(o.ops[0]);
        if (idx >= nparams) continue;
        LLVMValueRef param = ts_LLVMGetParam(t->fn, idx);
        LLVMTypeRef pt = ts_LLVMTypeOf(param);
        LLVMValueRef rolev = o.n > 1 ? o.ops[1] : NULL;
        val *v = NULL;
        unsigned bits = 32, comps = 1; bool flt = false;
        bool scalar = type_info(pt, &bits, &comps, &flt);
        if (md_is(rolev, "air.vertex_input")) {
            long loc = md_int_after(&o, "air.location_index", idx);
            if (!scalar || loc < 0 || loc >= VMG_MAX_VERTEX_ATTRIBS) FAILB(t, "vertex input %ld", loc);
            const struct glsl_type *gt = glsl_vector_type(flt ? GLSL_TYPE_FLOAT : GLSL_TYPE_UINT, 4);
            nir_variable *var = make_var(t, nir_var_shader_in, gt, VERT_ATTRIB_GENERIC0 + (int)loc, "attr");
            var->data.driver_location = (unsigned)loc;
            t->refl->vertex_inputs |= 1u << loc;
            nir_def *d = nir_load_var(b, var);
            if (flt && bits == 16) d = nir_f2f16(b, d);
            if (!flt && bits != 32) d = nir_u2uN(b, d, bits);
            v = vssa(t, nir_trim_vector(b, d, comps));
        } else if (md_is(rolev, "air.vertex_id")) {
            v = vssa(t, fit_lanes(t, nir_load_vertex_id(b), pt));
        } else if (md_is(rolev, "air.instance_id")) {
            v = vssa(t, fit_lanes(t, nir_iadd(b, nir_load_instance_id(b), nir_load_base_instance(b)), pt));
        } else if (md_is(rolev, "air.base_instance")) {
            v = vssa(t, fit_lanes(t, nir_load_base_instance(b), pt));
        } else if (md_is(rolev, "air.base_vertex")) {
            v = vssa(t, fit_lanes(t, nir_load_base_vertex(b), pt));
        } else if (md_is(rolev, "air.fragment_input")) {
            unsigned klen;
            const char *key = o.n > 2 ? md_string(o.ops[2], &klen) : NULL;
            int slot = key ? varying_slot(t, key, klen) : -1;
            if (!scalar) FAILB(t, "aggregate fragment input");
            if (slot >= 32) FAILB(t, "more than 32 varyings");
            if (slot < 0 && getenv("VMG_TRACE")) {
                fprintf(stderr, "vmg: fragment input %.*s not written by the vertex function; table:", key ? (int)klen : 1, key ? key : "?");
                for (unsigned k = 0; k < t->in->varying_count; k++) fprintf(stderr, " [%s]", t->in->varyings[k]);
                fprintf(stderr, "\n");
            }
            if (slot < 0) {
                // Not written by the vertex function: Metal leaves it undefined; read zeros.
                v = vssa(t, nir_imm_zero(b, comps, bits));
            } else {
                const struct glsl_type *gt = glsl_for(flt ? 32 : 32, comps, flt);
                nir_variable *var = make_var(t, nir_var_shader_in, gt, VARYING_SLOT_VAR0 + slot, "varying");
                if (md_has(&o, "air.flat") || !flt) var->data.interpolation = INTERP_MODE_FLAT;
                else if (md_has(&o, "air.no_perspective")) var->data.interpolation = INTERP_MODE_NOPERSPECTIVE;
                else var->data.interpolation = INTERP_MODE_SMOOTH;
                if (md_has(&o, "air.centroid")) var->data.centroid = true;
                else if (md_has(&o, "air.sample")) var->data.sample = true;
                nir_def *d = nir_load_var(b, var);
                if (flt && bits == 16) d = nir_f2f16(b, d);
                if (!flt && bits != 32) d = nir_u2uN(b, d, bits);
                v = vssa(t, d);
            }
        } else if (md_is(rolev, "air.position")) {
            v = vssa(t, fit_lanes(t, nir_load_frag_coord(b), pt));
        } else if (md_is(rolev, "air.front_facing")) {
            nir_def *ff = nir_load_front_face(b, 1);
            v = vssa(t, bits == 1 ? ff : nir_b2iN(b, ff, bits));
        } else if (md_is(rolev, "air.point_coord")) {
            v = vssa(t, fit_lanes(t, nir_load_point_coord(b), pt));
        } else if (md_is(rolev, "air.sample_id")) {
            t->refl->reads_sample_id = true;
            v = vssa(t, fit_lanes(t, nir_load_sample_id(b), pt));
        } else if (md_is(rolev, "air.sample_mask")) {
            v = vssa(t, fit_lanes(t, nir_load_sample_mask_in(b), pt));
        } else if (md_is(rolev, "air.render_target")) {
            // Programmable blending: [[color(n)]] read in the fragment function (framebuffer fetch).
            long n = o.n > 2 && ts_LLVMIsAConstantInt(o.ops[2]) ? (long)ts_LLVMConstIntGetZExtValue(o.ops[2]) : 0;
            if (n < 0 || n >= VMG_MAX_COLOR) FAILB(t, "color input %ld", n);
            nir_variable *var = t->color_out[n];
            if (!var) {
                const struct glsl_type *gt = glsl_vector_type(flt ? GLSL_TYPE_FLOAT : GLSL_TYPE_UINT, 4);
                var = t->color_out[n] = make_var(t, nir_var_shader_out, gt, FRAG_RESULT_DATA0 + (int)n, "color");
                var->data.driver_location = (unsigned)n;
            }
            var->data.fb_fetch_output = true;
            t->s->info.fs.uses_fbfetch_output = true;
            t->refl->color_inputs |= 1u << n;
            nir_def *d = nir_load_var(b, var);
            if (flt && bits == 16) d = nir_f2f16(b, d);
            v = vssa(t, nir_trim_vector(b, d, comps));
        } else if (md_is(rolev, "air.buffer") && md_int_after(&o, "air.address_space", ts_LLVMGetPointerAddressSpace(pt)) == 3) {
            // [[threadgroup(n)]]: dynamic threadgroup memory, placed by the encoder (offset in the system values).
            long slot = md_int_after(&o, "air.location_index", 0);
            if (slot < 0 || slot >= 8) FAILB(t, "threadgroup argument %ld", slot);
            t->refl->dynamic_shared_slots |= 1u << slot;
            t->s->info.cs.has_variable_shared_mem = true;
            v = vptr(t, SP_SHARED, NULL, sysval_word(t, (unsigned)slot * 4, 1));
        } else if (md_is(rolev, "air.buffer")) {
            long slot = md_int_after(&o, "air.location_index", 0);
            if (slot < 0 || slot >= VMG_MAX_BUFFERS) FAILB(t, "buffer %ld", slot);
            t->refl->buffers_used |= 1u << slot;
            v = vptr(t, SP_SSBO, nir_imm_int(b, (int)slot), nir_imm_int(b, 0));
        } else if (md_is(rolev, "air.texture")) {
            long slot = md_int_after(&o, "air.location_index", 0);
            if (slot < 0 || slot >= VMG_MAX_TEXTURES) FAILB(t, "texture %ld", slot);
            v = vnew(t, V_TEX);
            v->index = (int)slot;
        } else if (md_is(rolev, "air.sampler")) {
            long slot = md_int_after(&o, "air.location_index", 0);
            if (slot < 0 || slot >= VMG_MAX_SAMPLERS) FAILB(t, "sampler %ld", slot);
            t->refl->samplers_used |= 1u << slot;
            v = vnew(t, V_SMP);
            v->index = (int)slot;
        } else if (md_is(rolev, "air.threadgroup")) {
            long slot = md_int_after(&o, "air.location_index", 0);
            if (slot < 0 || slot >= 8) FAILB(t, "threadgroup argument %ld", slot);
            t->refl->dynamic_shared_slots |= 1u << slot;
            t->s->info.cs.has_variable_shared_mem = true;
            v = vptr(t, SP_SHARED, NULL, sysval_word(t, (unsigned)slot * 4, 1));
        } else if (t->stage == MESA_SHADER_COMPUTE) {
            nir_def *d = NULL;
            if (md_is(rolev, "air.thread_position_in_grid")) d = nir_load_global_invocation_id(b, 32);
            else if (md_is(rolev, "air.thread_position_in_threadgroup")) d = nir_load_local_invocation_id(b);
            else if (md_is(rolev, "air.threadgroup_position_in_grid")) d = nir_load_workgroup_id(b);
            else if (md_is(rolev, "air.threadgroups_per_grid")) d = nir_load_num_workgroups(b);
            else if (md_is(rolev, "air.threads_per_threadgroup")) d = nir_load_workgroup_size(b);
            else if (md_is(rolev, "air.threads_per_grid")) d = sysval_word(t, 32, 3);
            else if (md_is(rolev, "air.thread_index_in_threadgroup")) d = nir_load_local_invocation_index(b);
            else if (md_is(rolev, "air.thread_index_in_simdgroup")) d = nir_load_subgroup_invocation(b);
            else if (md_is(rolev, "air.simdgroup_index_in_threadgroup")) d = nir_load_subgroup_id(b);
            else if (md_is(rolev, "air.threads_per_simdgroup")) d = nir_load_subgroup_size(b);
            else if (md_is(rolev, "air.simdgroups_per_threadgroup")) d = nir_load_num_subgroups(b);
            else if (md_is(rolev, "air.thread_index_in_quadgroup")) d = nir_iand_imm(b, nir_load_subgroup_invocation(b), 3);
            else if (md_is(rolev, "air.quadgroup_index_in_threadgroup"))
                d = nir_ushr_imm(b, nir_load_local_invocation_index(b), 2);
            if (!d) {
                unsigned len;
                const char *s = md_string(rolev, &len);
                FAILB(t, "unsupported kernel input %.*s", (int)len, s ? s : "?");
            }
            if (scalar && comps < d->num_components) d = nir_trim_vector(b, d, comps);
            if (scalar && bits != d->bit_size && bits != 1) d = nir_u2uN(b, d, bits);
            v = vssa(t, d);
        } else {
            unsigned len;
            const char *s = md_string(rolev, &len);
            FAILB(t, "unsupported input %.*s", (int)len, s ? s : "?");
        }
        _mesa_hash_table_insert(t->vals, param, v);
    }
    return true;
}

static LLVMTypeRef return_type(T *t)
{
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(t->fn); bb; bb = ts_LLVMGetNextBasicBlock(bb)) {
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
        if (term && ts_LLVMGetInstructionOpcode(term) == LLVMRet && ts_LLVMGetNumOperands(term) > 0)
            return ts_LLVMTypeOf(ts_LLVMGetOperand(term, 0));
    }
    return NULL;
}

static bool declare_outputs(T *t, LLVMValueRef node)
{
    mdops list;
    md_operands(node, &list);
    LLVMTypeRef rt = return_type(t);
    for (unsigned a = 0; a < list.n; a++) {
        mdops o;
        md_operands(list.ops[a], &o);
        LLVMTypeRef mt = !rt ? NULL : ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind
                                     ? (a < ts_LLVMCountStructElementTypes(rt) ? ts_LLVMStructGetTypeAtIndex(rt, a) : NULL)
                                     : a == 0 ? rt : NULL;
        nir_variable *var = NULL;
        unsigned bits = 32, comps = 1; bool flt = true;
        if (mt) type_info(mt, &bits, &comps, &flt);
        LLVMValueRef rolev = o.n ? o.ops[0] : NULL;
        if (md_is(rolev, "air.position")) {
            var = make_var(t, nir_var_shader_out, glsl_vec4_type(), VARYING_SLOT_POS, "position");
        } else if (md_is(rolev, "air.vertex_output")) {
            unsigned klen;
            const char *key = o.n > 1 ? md_string(o.ops[1], &klen) : NULL;
            int slot = key ? varying_slot(t, key, klen) : -1;
            if (slot >= 32) FAILB(t, "more than 32 varyings");
            if (slot >= 0) {
                var = make_var(t, nir_var_shader_out, glsl_for(32, comps, flt), VARYING_SLOT_VAR0 + slot, "varying");
                if (!flt) var->data.interpolation = INTERP_MODE_FLAT;
            }
        } else if (md_is(rolev, "air.point_size")) {
            var = make_var(t, nir_var_shader_out, glsl_float_type(), VARYING_SLOT_PSIZ, "psize");
        } else if (md_is(rolev, "air.render_target")) {
            long n = o.n > 1 && ts_LLVMIsAConstantInt(o.ops[1]) ? (long)ts_LLVMConstIntGetZExtValue(o.ops[1]) : 0;
            long index = o.n > 2 && ts_LLVMIsAConstantInt(o.ops[2]) ? (long)ts_LLVMConstIntGetZExtValue(o.ops[2]) : 0;
            if (n < 0 || n >= VMG_MAX_COLOR) FAILB(t, "render target %ld", n);
            bool sint = false, uint = false;
            if (!flt) {
                uint32_t fmt = t->in->color_formats ? t->in->color_formats[n] : 0;
                sint = fmt && vmg_format_is_signed_integer(fmt);
                uint = !sint;
            }
            enum glsl_base_type base = flt ? GLSL_TYPE_FLOAT : sint ? GLSL_TYPE_INT : GLSL_TYPE_UINT;
            if (index == 0 && t->color_out[n]) var = t->color_out[n];
            else {
                var = make_var(t, nir_var_shader_out, glsl_vector_type(base, 4), FRAG_RESULT_DATA0 + (int)n, "color");
                var->data.driver_location = (unsigned)(n + index * VMG_MAX_COLOR);
                var->data.index = (int)index;
                if (index == 0) t->color_out[n] = var;
            }
            (void)uint;
            t->refl->color_outputs |= 1u << n;
        } else if (md_is(rolev, "air.depth")) {
            var = make_var(t, nir_var_shader_out, glsl_float_type(), FRAG_RESULT_DEPTH, "depth");
            t->refl->writes_depth = true;
        } else if (md_is(rolev, "air.sample_mask")) {
            var = make_var(t, nir_var_shader_out, glsl_int_type(), FRAG_RESULT_SAMPLE_MASK, "samplemask");
            t->refl->writes_sample_mask = true;
        } else if (md_is(rolev, "air.clip_distance")) {
            var = NULL;   // dropped (as in metal-shim)
        } else {
            unsigned len;
            const char *s = md_string(rolev, &len);
            FAILB(t, "unsupported output %.*s", (int)len, s ? s : "?");
        }
        if (t->nout >= 40) FAILB(t, "too many outputs");
        t->out[t->nout++] = var;
    }
    return true;
}

static bool emit_return(T *t, LLVMValueRef term)
{
    if (ts_LLVMGetNumOperands(term) == 0 || !t->nout) return true;
    val *rv = value(t, ts_LLVMGetOperand(term, 0));
    if (!rv) return false;
    for (unsigned i = 0; i < t->nout; i++) {
        nir_variable *var = t->out[i];
        if (!var) continue;
        val *m = rv->kind == V_AGG ? (i < rv->n ? rv->e[i] : NULL) : (i == 0 ? rv : NULL);
        if (!m || m->kind != V_SSA) FAILB(t, "output %u is not a value", i);
        nir_def *d = m->def;
        const struct glsl_type *gt = var->type;
        unsigned want = glsl_get_vector_elements(gt);
        bool fvar = glsl_get_base_type(gt) == GLSL_TYPE_FLOAT;
        if (d->bit_size == 1) d = nir_b2i32(&t->b, d);
        if (fvar && d->bit_size == 16) d = nir_f2f32(&t->b, d);
        if (!fvar && d->bit_size != 32) {
            bool sint = glsl_get_base_type(gt) == GLSL_TYPE_INT;
            d = sint ? nir_i2i32(&t->b, d) : nir_u2u32(&t->b, d);
        }
        if (d->num_components < want) d = nir_pad_vector_imm_int(&t->b, d, 0, want);
        if (d->num_components > want) d = nir_trim_vector(&t->b, d, want);
        nir_store_var(&t->b, var, d, nir_component_mask(want));
    }
    return true;
}

// ---- Instructions ---------------------------------------------------------------------------------------------------

static val *binary(T *t, LLVMValueRef inst, LLVMOpcode op)
{
    nir_def *x = ssa(t, ts_LLVMGetOperand(inst, 0)), *y = ssa(t, ts_LLVMGetOperand(inst, 1));
    if (!x || !y) return NULL;
    nir_builder *b = &t->b;
    nir_def *r;
    switch (op) {
    case LLVMAdd: r = nir_iadd(b, x, y); break;
    case LLVMSub: r = nir_isub(b, x, y); break;
    case LLVMMul: r = nir_imul(b, x, y); break;
    case LLVMUDiv: r = nir_udiv(b, x, y); break;
    case LLVMSDiv: r = nir_idiv(b, x, y); break;
    case LLVMURem: r = nir_umod(b, x, y); break;
    case LLVMSRem: r = nir_irem(b, x, y); break;
    case LLVMShl: r = nir_ishl(b, x, nir_u2u32(b, y)); break;
    case LLVMLShr: r = nir_ushr(b, x, nir_u2u32(b, y)); break;
    case LLVMAShr: r = nir_ishr(b, x, nir_u2u32(b, y)); break;
    case LLVMAnd: r = nir_iand(b, x, y); break;
    case LLVMOr: r = nir_ior(b, x, y); break;
    case LLVMXor: r = nir_ixor(b, x, y); break;
    case LLVMFAdd: r = nir_fadd(b, x, y); break;
    case LLVMFSub: r = nir_fsub(b, x, y); break;
    case LLVMFMul: r = nir_fmul(b, x, y); break;
    case LLVMFDiv: r = nir_fdiv(b, x, y); break;
    case LLVMFRem: r = nir_frem(b, x, y); break;
    default: FAIL(t, "binary opcode %d", op);
    }
    return vssa(t, r);
}

static val *compare(T *t, LLVMValueRef inst, bool flt)
{
    val *xv = value(t, ts_LLVMGetOperand(inst, 0)), *yv = value(t, ts_LLVMGetOperand(inst, 1));
    if (!xv || !yv) return NULL;
    nir_builder *b = &t->b;
    if (xv->kind == V_PTR && yv->kind == V_PTR) {
        // Pointer comparison: same space assumed; compare byte offsets (and slots).
        nir_def *eq = nir_ieq(b, xv->off, yv->off);
        if (xv->slot && yv->slot) eq = nir_iand(b, eq, nir_ieq(b, xv->slot, yv->slot));
        LLVMIntPredicate p = ts_LLVMGetICmpPredicate(inst);
        if (p == LLVMIntEQ) return vssa(t, eq);
        if (p == LLVMIntNE) return vssa(t, nir_inot(b, eq));
        nir_def *x = xv->off, *y = yv->off;
        switch (p) {
        case LLVMIntULT: case LLVMIntSLT: return vssa(t, nir_ult(b, x, y));
        case LLVMIntULE: case LLVMIntSLE: return vssa(t, nir_uge(b, y, x));
        case LLVMIntUGT: case LLVMIntSGT: return vssa(t, nir_ult(b, y, x));
        default: return vssa(t, nir_uge(b, x, y));
        }
    }
    if (xv->kind != V_SSA || yv->kind != V_SSA) FAIL(t, "comparison of non-values");
    nir_def *x = xv->def, *y = yv->def, *r;
    if (!flt) {
        switch (ts_LLVMGetICmpPredicate(inst)) {
        case LLVMIntEQ: r = nir_ieq(b, x, y); break;
        case LLVMIntNE: r = nir_ine(b, x, y); break;
        case LLVMIntUGT: r = nir_ult(b, y, x); break;
        case LLVMIntUGE: r = nir_uge(b, x, y); break;
        case LLVMIntULT: r = nir_ult(b, x, y); break;
        case LLVMIntULE: r = nir_uge(b, y, x); break;
        case LLVMIntSGT: r = nir_ilt(b, y, x); break;
        case LLVMIntSGE: r = nir_ige(b, x, y); break;
        case LLVMIntSLT: r = nir_ilt(b, x, y); break;
        case LLVMIntSLE: r = nir_ige(b, y, x); break;
        default: FAIL(t, "icmp predicate");
        }
        return vssa(t, r);
    }
    nir_def *ord = nir_iand(b, nir_feq(b, x, x), nir_feq(b, y, y));
    switch (ts_LLVMGetFCmpPredicate(inst)) {
    case LLVMRealPredicateFalse: r = nir_imm_false(b); if (x->num_components > 1) r = nir_imm_zero(b, x->num_components, 1); break;
    case LLVMRealOEQ: r = nir_feq(b, x, y); break;
    case LLVMRealOGT: r = nir_flt(b, y, x); break;
    case LLVMRealOGE: r = nir_fge(b, x, y); break;
    case LLVMRealOLT: r = nir_flt(b, x, y); break;
    case LLVMRealOLE: r = nir_fge(b, y, x); break;
    case LLVMRealONE: r = nir_iand(b, nir_fneu(b, x, y), ord); break;
    case LLVMRealORD: r = ord; break;
    case LLVMRealUNO: r = nir_inot(b, ord); break;
    case LLVMRealUEQ: r = nir_inot(b, nir_iand(b, nir_fneu(b, x, y), ord)); break;
    case LLVMRealUGT: r = nir_inot(b, nir_fge(b, y, x)); break;
    case LLVMRealUGE: r = nir_inot(b, nir_flt(b, x, y)); break;
    case LLVMRealULT: r = nir_inot(b, nir_fge(b, x, y)); break;
    case LLVMRealULE: r = nir_inot(b, nir_flt(b, y, x)); break;
    case LLVMRealUNE: r = nir_fneu(b, x, y); break;
    case LLVMRealPredicateTrue: r = nir_inot(b, nir_imm_zero(b, x->num_components, 1)); break;
    default: FAIL(t, "fcmp predicate");
    }
    return vssa(t, r);
}

static val *cast(T *t, LLVMValueRef inst, LLVMOpcode op)
{
    LLVMValueRef srcv = ts_LLVMGetOperand(inst, 0);
    LLVMTypeRef to = ts_LLVMTypeOf(inst), from = ts_LLVMTypeOf(srcv);
    nir_builder *b = &t->b;
    if (op == LLVMBitCast || op == LLVMAddrSpaceCast) {
        val *v = value(t, srcv);
        if (!v) return NULL;
        if (v->kind != V_SSA || is_ptr(to)) return v;   // pointer casts keep the pointer (memory is untyped)
        unsigned tb, tc; bool tf;
        if (!type_info(to, &tb, &tc, &tf)) FAIL(t, "bitcast to an aggregate");
        nir_def *d = v->def;
        bool from_half = g_half32 && is_half_type(ts_LLVMTypeOf(srcv)), to_half = g_half32 && is_half_type(to);
        if (from_half) d = nir_f2f16(b, d);           // the bits of a half are its 16-bit form
        if (to_half) tb = 16;
        if (d->bit_size == tb && d->num_components == tc) return vssa(t, to_half ? nir_f2f32(b, d) : d);
        if (d->bit_size == 1 || tb == 1) FAIL(t, "bitcast of booleans");
        nir_def *r = nir_extract_bits(b, &d, 1, 0, tc, tb);
        return vssa(t, to_half ? nir_f2f32(b, r) : r);
    }
    if (op == LLVMPtrToInt || op == LLVMIntToPtr) FAIL(t, "pointer/integer conversion");
    nir_def *x = ssa(t, srcv);
    if (!x) return NULL;
    unsigned tb, tc; bool tf;
    if (!type_info(to, &tb, &tc, &tf)) FAIL(t, "cast to an aggregate");
    (void)from;
    switch (op) {
    case LLVMTrunc:
        if (tb == 1) return vssa(t, nir_ine_imm(b, nir_iand_imm(b, x, 1), 0));
        return vssa(t, nir_u2uN(b, x, tb));
    case LLVMZExt: return vssa(t, x->bit_size == 1 ? nir_b2iN(b, x, tb) : nir_u2uN(b, x, tb));
    case LLVMSExt: return vssa(t, x->bit_size == 1 ? nir_ineg(b, nir_b2iN(b, x, tb)) : nir_i2iN(b, x, tb));
    case LLVMFPToUI: return vssa(t, tb == 1 ? nir_fneu_imm(b, x, 0) : nir_f2uN(b, x, tb));
    case LLVMFPToSI: return vssa(t, tb == 1 ? nir_fneu_imm(b, x, 0) : nir_f2iN(b, x, tb));
    case LLVMUIToFP: return vssa(t, x->bit_size == 1 ? nir_b2fN(b, x, tb) : nir_u2fN(b, x, tb));
    case LLVMSIToFP: return vssa(t, x->bit_size == 1 ? nir_fneg(b, nir_b2fN(b, x, tb)) : nir_i2fN(b, x, tb));
    case LLVMFPTrunc: case LLVMFPExt: return vssa(t, nir_f2fN(b, x, tb));
    default: FAIL(t, "cast opcode %d", op);
    }
}

static val *select_inst(T *t, LLVMValueRef inst)
{
    nir_def *c = ssa(t, ts_LLVMGetOperand(inst, 0));
    val *x = value(t, ts_LLVMGetOperand(inst, 1)), *y = value(t, ts_LLVMGetOperand(inst, 2));
    if (!c || !x || !y) return NULL;
    nir_builder *b = &t->b;
    if (x->kind == V_SSA && y->kind == V_SSA) return vssa(t, nir_bcsel(b, c, x->def, y->def));
    if (x->kind == V_PTR && y->kind == V_PTR) {
        if (x->sp != y->sp) FAIL(t, "select between memories");
        nir_def *slot = x->slot && y->slot ? nir_bcsel(b, c, x->slot, y->slot) : x->slot;
        return vptr(t, x->sp, slot, nir_bcsel(b, c, x->off, y->off));
    }
    FAIL(t, "select of aggregates or resources");
}

static val *extract_value(T *t, val *agg, const unsigned *idx, unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        if (!agg || agg->kind != V_AGG || idx[i] >= agg->n) FAIL(t, "extractvalue out of range");
        agg = agg->e[idx[i]];
    }
    return agg;
}

static val *copy_agg(T *t, val *a)
{
    val *c = vnew(t, V_AGG);
    c->n = a->n; c->e = ralloc_array(t->mem, val *, a->n ? a->n : 1);
    memcpy(c->e, a->e, a->n * sizeof(val *));
    return c;
}

static val *insert_value(T *t, val *agg, val *v, const unsigned *idx, unsigned n)
{
    if (!agg || agg->kind != V_AGG || idx[0] >= agg->n) FAIL(t, "insertvalue out of range");
    val *c = copy_agg(t, agg);
    c->e[idx[0]] = n == 1 ? v : insert_value(t, agg->e[idx[0]], v, idx + 1, n - 1);
    return c->e[idx[0]] ? c : NULL;
}

static val *shuffle(T *t, LLVMValueRef inst)
{
    nir_def *x = ssa(t, ts_LLVMGetOperand(inst, 0)), *y = ssa(t, ts_LLVMGetOperand(inst, 1));
    if (!x || !y) return NULL;
    unsigned n = ts_LLVMGetNumMaskElements ? ts_LLVMGetNumMaskElements(inst) : ts_LLVMGetVectorSize(ts_LLVMTypeOf(inst));
    nir_def *c[16];
    if (n > 16) FAIL(t, "shuffle of %u lanes", n);
    // Older LLVM (iOS 16): the mask is the third operand, a constant vector.
    LLVMValueRef mask = ts_LLVMGetMaskValue ? NULL : ts_LLVMGetNumOperands(inst) > 2 ? ts_LLVMGetOperand(inst, 2) : NULL;
    if (!ts_LLVMGetMaskValue && !mask) FAIL(t, "shuffle mask not readable");
    for (unsigned i = 0; i < n; i++) {
        int m;
        if (ts_LLVMGetMaskValue) m = ts_LLVMGetMaskValue(inst, i);
        else if (is_undef(mask)) m = -1;
        else if (ts_LLVMIsAConstantAggregateZero(mask)) m = 0;
        else {
            LLVMValueRef e = ts_LLVMIsAConstantDataSequential(mask) ? ts_LLVMGetElementAsConstant(mask, i) : ts_LLVMGetOperand(mask, i);
            m = !e || is_undef(e) ? -1 : (int)ts_LLVMConstIntGetZExtValue(e);
        }
        if (m < 0) c[i] = nir_undef(&t->b, 1, x->bit_size);
        else c[i] = (unsigned)m < x->num_components ? nir_channel(&t->b, x, (unsigned)m) : nir_channel(&t->b, y, (unsigned)m - x->num_components);
    }
    return vssa(t, nir_vec(&t->b, c, n));
}

// ---- Calls: math --------------------------------------------------------------------------------------------------

static bool name_is(const char *name, const char *prefix) { return !strncmp(name, prefix, strlen(prefix)); }

static nir_def *arg(T *t, LLVMValueRef call, unsigned i) { return ssa(t, ts_LLVMGetOperand(call, i)); }

static nir_def *fround_away(nir_builder *b, nir_def *x)
{
    return nir_fmul(b, nir_fsign(b, x), nir_ffloor(b, nir_fadd_imm(b, nir_fabs(b, x), 0.5)));
}

static val *math(T *t, LLVMValueRef inst, const char *name)
{
    nir_builder *b = &t->b;
    // air.<op>[.<sign>].<type> / llvm.<op>.<type>
    char op[64];
    const char *p = strchr(name, '.') + 1;
    const char *dot = strchr(p, '.');
    snprintf(op, sizeof op, "%.*s", dot ? (int)(dot - p) : (int)strlen(p), p);
    const char *o = op;
    if (name_is(o, "fast_")) o += 5;
    else if (name_is(o, "precise_")) o += 8;
    bool u = strstr(name, ".u.") != NULL || strstr(name, ".u8") || strstr(name, ".u16") || strstr(name, ".u32") || strstr(name, ".u64");
    unsigned nargs = ts_LLVMGetNumArgOperands(inst);
    nir_def *a[4] = {0};
    for (unsigned i = 0; i < nargs && i < 4; i++) {
        LLVMTypeRef at = ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i));
        if (is_ptr(at) || ts_LLVMGetTypeKind(at) == LLVMMetadataTypeKind) continue;
        if (!(a[i] = arg(t, inst, i))) return NULL;
    }
    LLVMTypeRef rt = ts_LLVMTypeOf(inst);
    bool flt = is_float(rt) || (a[0] && nargs && is_float(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0))));
    nir_def *r = NULL;
#define IS(s) (!strcmp(o, s))
    if (IS("sin")) r = nir_fsin(b, a[0]);
    else if (IS("cos")) r = nir_fcos(b, a[0]);
    else if (IS("tan")) r = nir_fdiv(b, nir_fsin(b, a[0]), nir_fcos(b, a[0]));
    else if (IS("asin")) r = nir_atan2(b, a[0], nir_fsqrt(b, nir_fsub(b, nir_imm_floatN_t(b, 1, a[0]->bit_size), nir_fmul(b, a[0], a[0]))));
    else if (IS("acos")) r = nir_atan2(b, nir_fsqrt(b, nir_fsub(b, nir_imm_floatN_t(b, 1, a[0]->bit_size), nir_fmul(b, a[0], a[0]))), a[0]);
    else if (IS("atan")) r = nir_atan(b, a[0]);
    else if (IS("atan2")) r = nir_atan2(b, a[0], a[1]);
    else if (IS("sinh") || IS("cosh") || IS("tanh")) {
        nir_def *e = nir_fexp2(b, nir_fmul_imm(b, a[0], M_LOG2E)), *ie = nir_frcp(b, e);
        nir_def *sh = nir_fmul_imm(b, nir_fsub(b, e, ie), 0.5), *ch = nir_fmul_imm(b, nir_fadd(b, e, ie), 0.5);
        r = IS("sinh") ? sh : IS("cosh") ? ch : nir_fdiv(b, sh, ch);
    } else if (IS("asinh")) r = nir_fmul_imm(b, nir_flog2(b, nir_fadd(b, a[0], nir_fsqrt(b, nir_fadd_imm(b, nir_fmul(b, a[0], a[0]), 1)))), M_LN2);
    else if (IS("acosh")) r = nir_fmul_imm(b, nir_flog2(b, nir_fadd(b, a[0], nir_fsqrt(b, nir_fadd_imm(b, nir_fmul(b, a[0], a[0]), -1)))), M_LN2);
    else if (IS("atanh")) r = nir_fmul_imm(b, nir_fmul_imm(b, nir_flog2(b, nir_fdiv(b, nir_fadd_imm(b, a[0], 1), nir_fsub(b, nir_imm_floatN_t(b, 1, a[0]->bit_size), a[0]))), M_LN2), 0.5);
    else if (IS("exp")) r = nir_fexp2(b, nir_fmul_imm(b, a[0], M_LOG2E));
    else if (IS("exp2")) r = nir_fexp2(b, a[0]);
    else if (IS("exp10")) r = nir_fexp2(b, nir_fmul_imm(b, a[0], 3.32192809488736234787));
    else if (IS("log")) r = nir_fmul_imm(b, nir_flog2(b, a[0]), M_LN2);
    else if (IS("log2")) r = nir_flog2(b, a[0]);
    else if (IS("log10")) r = nir_fmul_imm(b, nir_flog2(b, a[0]), 0.30102999566398119521);
    else if (IS("sqrt")) r = nir_fsqrt(b, a[0]);
    else if (IS("rsqrt")) r = nir_frsq(b, a[0]);
    else if (IS("floor")) r = nir_ffloor(b, a[0]);
    else if (IS("ceil")) r = nir_fceil(b, a[0]);
    else if (IS("trunc")) r = nir_ftrunc(b, a[0]);
    else if (IS("round")) r = fround_away(b, a[0]);
    else if (IS("rint") || IS("roundeven")) r = nir_fround_even(b, a[0]);
    else if (IS("fract")) r = nir_ffract(b, a[0]);
    else if (IS("sign")) r = nir_fsign(b, a[0]);
    else if (IS("saturate")) r = nir_fsat(b, a[0]);
    else if (IS("fabs") || (IS("abs") && flt)) r = nir_fabs(b, a[0]);
    else if (IS("abs")) r = nir_iabs(b, a[0]);
    else if (IS("dot")) r = nir_fdot(b, a[0], a[1]);
    else if (IS("cross")) r = nir_cross3(b, a[0], a[1]);
    else if (IS("length")) r = nir_fast_length(b, a[0]);
    else if (IS("normalize")) r = nir_fast_normalize(b, a[0]);
    else if (IS("distance")) r = nir_fast_distance(b, a[0], a[1]);
    else if (IS("reflect")) r = nir_fsub(b, a[0], nir_fmul(b, nir_fmul_imm(b, nir_fdot(b, a[1], a[0]), 2), a[1]));
    else if (IS("refract")) {
        nir_def *I = a[0], *N = a[1], *eta = a[2];
        nir_def *one = nir_imm_floatN_t(b, 1, I->bit_size);
        nir_def *d = nir_fdot(b, N, I);
        nir_def *k = nir_fsub(b, one, nir_fmul(b, nir_fmul(b, eta, eta), nir_fsub(b, one, nir_fmul(b, d, d))));
        nir_def *res = nir_fsub(b, nir_fmul(b, eta, I), nir_fmul(b, nir_fadd(b, nir_fmul(b, eta, d), nir_fsqrt(b, k)), N));
        r = nir_bcsel(b, nir_flt_imm(b, k, 0), nir_imm_zero(b, I->num_components, I->bit_size), res);
    } else if (IS("mix")) r = nir_flrp(b, a[0], a[1], a[2]);
    else if (IS("clamp")) r = flt ? nir_fmin(b, nir_fmax(b, a[0], a[1]), a[2]) : u ? nir_umin(b, nir_umax(b, a[0], a[1]), a[2]) : nir_imin(b, nir_imax(b, a[0], a[1]), a[2]);
    else if (IS("step")) r = nir_b2fN(b, nir_fge(b, a[1], a[0]), a[1]->bit_size);
    else if (IS("smoothstep")) r = nir_smoothstep(b, a[0], a[1], a[2]);
    else if (IS("min") || IS("fmin") || IS("minnum") || IS("minimum")) r = flt ? nir_fmin(b, a[0], a[1]) : u ? nir_umin(b, a[0], a[1]) : nir_imin(b, a[0], a[1]);
    else if (IS("max") || IS("fmax") || IS("maxnum") || IS("maximum")) r = flt ? nir_fmax(b, a[0], a[1]) : u ? nir_umax(b, a[0], a[1]) : nir_imax(b, a[0], a[1]);
    else if (IS("smin")) r = nir_imin(b, a[0], a[1]);
    else if (IS("smax")) r = nir_imax(b, a[0], a[1]);
    else if (IS("umin")) r = nir_umin(b, a[0], a[1]);
    else if (IS("umax")) r = nir_umax(b, a[0], a[1]);
    else if (IS("fmin3") || IS("min3")) r = flt ? nir_fmin(b, a[0], nir_fmin(b, a[1], a[2])) : u ? nir_umin(b, a[0], nir_umin(b, a[1], a[2])) : nir_imin(b, a[0], nir_imin(b, a[1], a[2]));
    else if (IS("fmax3") || IS("max3")) r = flt ? nir_fmax(b, a[0], nir_fmax(b, a[1], a[2])) : u ? nir_umax(b, a[0], nir_umax(b, a[1], a[2])) : nir_imax(b, a[0], nir_imax(b, a[1], a[2]));
    else if (IS("median3") || IS("fmedian3")) r = nir_fmax(b, nir_fmin(b, a[0], a[1]), nir_fmin(b, nir_fmax(b, a[0], a[1]), a[2]));
    else if (IS("pow") || IS("powr")) r = nir_fpow(b, a[0], a[1]);
    else if (IS("fma") || IS("fmuladd") || IS("mad"))    // exact fma only where the driver has it (llvmpipe: weak only)
        r = IS("fma") && nir_has_ffma(b->shader, a[0]->bit_size) ? nir_ffma(b, a[0], a[1], a[2]) : nir_ffma_weak(b, a[0], a[1], a[2]);
    else if (IS("isnan")) r = nir_fneu(b, a[0], a[0]);
    else if (IS("isinf")) r = nir_feq(b, nir_fabs(b, a[0]), nir_imm_floatN_t(b, INFINITY, a[0]->bit_size));
    else if (IS("isfinite")) r = nir_flt(b, nir_fabs(b, a[0]), nir_imm_floatN_t(b, INFINITY, a[0]->bit_size));
    else if (IS("signbit")) r = nir_ilt_imm(b, nir_extract_bits(b, &a[0], 1, 0, a[0]->num_components, a[0]->bit_size), 0);
    else if (IS("fmod")) r = nir_fsub(b, a[0], nir_fmul(b, a[1], nir_ftrunc(b, nir_fdiv(b, a[0], a[1]))));
    else if (IS("copysign")) r = nir_bcsel(b, nir_flt_imm(b, a[1], 0), nir_fneg(b, nir_fabs(b, a[0])), nir_fabs(b, a[0]));
    else if (IS("radians")) r = nir_fmul_imm(b, a[0], M_PI / 180.0);
    else if (IS("degrees")) r = nir_fmul_imm(b, a[0], 180.0 / M_PI);
    else if (IS("clz") || IS("ctlz")) r = nir_u2uN(b, nir_uclz(b, nir_u2u32(b, a[0])), a[0]->bit_size);
    else if (IS("ctz") || IS("cttz")) {
        nir_def *lsb = nir_find_lsb(b, a[0]);
        r = nir_u2uN(b, nir_bcsel(b, nir_ilt_imm(b, lsb, 0), nir_imm_int(b, (int)a[0]->bit_size), lsb), a[0]->bit_size);
    } else if (IS("popcount") || IS("ctpop")) r = nir_u2uN(b, nir_bit_count(b, a[0]), a[0]->bit_size);
    else if (IS("reverse_bits") || IS("bitreverse")) r = nir_bitfield_reverse(b, a[0]);
    else if (IS("extract_bits")) r = u ? nir_ubitfield_extract(b, a[0], nir_u2u32(b, a[1]), nir_u2u32(b, a[2])) : nir_ibitfield_extract(b, a[0], nir_u2u32(b, a[1]), nir_u2u32(b, a[2]));
    else if (IS("insert_bits")) r = nir_bitfield_insert(b, a[0], a[1], nir_u2u32(b, a[2]), nir_u2u32(b, a[3]));
    else if (IS("ldexp")) r = nir_ldexp(b, a[0], nir_i2i32(b, a[1]));
    else if (IS("mul_hi")) r = u ? nir_umul_high(b, a[0], a[1]) : nir_imul_high(b, a[0], a[1]);
    else if (IS("add_sat") || IS("uadd.sat") || IS("sadd")) r = u ? nir_uadd_sat(b, a[0], a[1]) : nir_iadd_sat(b, a[0], a[1]);
    else if (IS("sub_sat")) r = u ? nir_usub_sat(b, a[0], a[1]) : nir_isub_sat(b, a[0], a[1]);
    else if (IS("abs_diff")) r = u ? nir_isub(b, nir_umax(b, a[0], a[1]), nir_umin(b, a[0], a[1])) : nir_isub(b, nir_imax(b, a[0], a[1]), nir_imin(b, a[0], a[1]));
    else if (IS("hadd")) r = u ? nir_uhadd(b, a[0], a[1]) : nir_ihadd(b, a[0], a[1]);
    else if (IS("rhadd")) r = u ? nir_urhadd(b, a[0], a[1]) : nir_irhadd(b, a[0], a[1]);
    else if (IS("rotate")) r = nir_urol(b, a[0], nir_u2u32(b, a[1]));
    else if (IS("dfdx") || IS("dfdx_coarse") || IS("dfdx_fine")) r = nir_ddx(b, a[0]);
    else if (IS("dfdy") || IS("dfdy_coarse") || IS("dfdy_fine")) r = nir_ddy(b, a[0]);
    else if (IS("fwidth")) r = nir_fadd(b, nir_fabs(b, nir_ddx(b, a[0])), nir_fabs(b, nir_ddy(b, a[0])));
    else if (IS("all")) r = a[0]->num_components > 1 ? nir_ball(b, a[0]) : a[0];
    else if (IS("any")) r = a[0]->num_components > 1 ? nir_bany(b, a[0]) : a[0];
    else if (IS("select")) r = nir_bcsel(b, a[2], a[1], a[0]);
    else if (IS("pack") || IS("unpack")) {
        // Spelled out (portable: llvmpipe lacks some of NIR's packing opcodes after lowering).
        const char *fmt = dot ? dot + 1 : "";
        bool pack = IS("pack");
        if (strstr(fmt, "rgb565")) {
            // air.pack.unorm.rgb565 / unpack: 5:6:5 in the low 16 bits (red in the high bits, as MSL's packing).
            nir_def *x = nir_fsat(b, nir_f2f32(b, a[0]));
            if (pack) {
                nir_def *r5 = nir_f2u32(b, nir_fround_even(b, nir_fmul_imm(b, nir_channel(b, x, 0), 31)));
                nir_def *g6 = nir_f2u32(b, nir_fround_even(b, nir_fmul_imm(b, nir_channel(b, x, 1), 63)));
                nir_def *b5 = nir_f2u32(b, nir_fround_even(b, nir_fmul_imm(b, nir_channel(b, x, 2), 31)));
                r = nir_ior(b, nir_ishl_imm(b, r5, 11), nir_ior(b, nir_ishl_imm(b, g6, 5), b5));
            } else {
                nir_def *w = nir_u2u32(b, a[0]);
                nir_def *c[3] = {
                    nir_fmul_imm(b, nir_u2f32(b, nir_ubitfield_extract(b, w, nir_imm_int(b, 11), nir_imm_int(b, 5))), 1.0 / 31),
                    nir_fmul_imm(b, nir_u2f32(b, nir_ubitfield_extract(b, w, nir_imm_int(b, 5), nir_imm_int(b, 6))), 1.0 / 63),
                    nir_fmul_imm(b, nir_u2f32(b, nir_ubitfield_extract(b, w, nir_imm_int(b, 0), nir_imm_int(b, 5))), 1.0 / 31) };
                r = nir_vec(b, c, 3);
            }
        }
        bool snorm = name_is(fmt, "snorm");
        unsigned lanes = name_is(fmt + 5, "4x8") ? 4 : name_is(fmt + 5, "2x16") ? 2 : 0;
        if (lanes && !r) {
            unsigned bits = 32 / lanes;
            double scale = snorm ? (double)((1u << (bits - 1)) - 1) : (double)((1u << bits) - 1);
            nir_def *mask = nir_imm_int(b, (int)((1u << bits) - 1));
            if (pack) {
                nir_def *x = nir_f2f32(b, a[0]);
                x = snorm ? nir_fmin(b, nir_fmax(b, x, nir_imm_float(b, -1)), nir_imm_float(b, 1)) : nir_fsat(b, x);
                nir_def *q = nir_f2i32(b, nir_fround_even(b, nir_fmul_imm(b, x, scale)));
                nir_def *w = nir_imm_int(b, 0);
                for (unsigned k = 0; k < lanes; k++)
                    w = nir_ior(b, w, nir_ishl_imm(b, nir_iand(b, nir_channel(b, q, k), mask), k * bits));
                r = w;
            } else {
                nir_def *w = nir_u2u32(b, a[0]), *c[4];
                for (unsigned k = 0; k < lanes; k++) {
                    nir_def *f = snorm ? nir_i2f32(b, nir_ibitfield_extract(b, w, nir_imm_int(b, (int)(k * bits)), nir_imm_int(b, (int)bits)))
                                       : nir_u2f32(b, nir_ubitfield_extract(b, w, nir_imm_int(b, (int)(k * bits)), nir_imm_int(b, (int)bits)));
                    f = nir_fmul_imm(b, f, 1.0 / scale);
                    c[k] = snorm ? nir_fmax(b, f, nir_imm_float(b, -1)) : f;
                }
                r = nir_vec(b, c, lanes);
            }
        }
    }
#undef IS
    if (!r) FAIL(t, "unsupported intrinsic %s", name);
    if (ts_LLVMGetTypeKind(rt) == LLVMVoidTypeKind) return vnew(t, V_NONE);
    return vssa(t, fit_lanes(t, r, rt));
}

// air.convert.<f|s|u>.<dst type>.<f|s|u>.<src type>
static val *convert(T *t, LLVMValueRef inst, const char *name)
{
    char dk = 0, sk = 0;
    const char *p = name + strlen("air.convert.");
    if (name_is(p, "sat.")) p += 4;
    dk = p[0];
    const char *q = strchr(p, '.');
    q = q ? strchr(q + 1, '.') : NULL;
    if (!q) FAIL(t, "malformed %s", name);
    sk = q[1];
    nir_def *x = arg(t, inst, 0);
    if (!x) return NULL;
    LLVMTypeRef to = ts_LLVMTypeOf(inst);
    unsigned tb, tc; bool tf;
    if (!type_info(to, &tb, &tc, &tf)) FAIL(t, "convert to an aggregate");
    nir_builder *b = &t->b;
    nir_def *r;
    if (dk == 'f') {
        if (sk == 'f') r = nir_f2fN(b, x, tb);
        else if (x->bit_size == 1) r = nir_b2fN(b, x, tb);
        else r = sk == 'u' ? nir_u2fN(b, x, tb) : nir_i2fN(b, x, tb);
    } else if (sk == 'f') {
        if (tb == 1) r = nir_fneu_imm(b, x, 0);
        else r = dk == 'u' ? nir_f2uN(b, nir_fmax(b, x, nir_imm_floatN_t(b, 0, x->bit_size)), tb) : nir_f2iN(b, x, tb);
    } else {
        if (tb == 1) r = nir_ine_imm(b, x, 0);
        else if (x->bit_size == 1) r = nir_b2iN(b, x, tb);
        else r = sk == 's' ? nir_i2iN(b, x, tb) : nir_u2uN(b, x, tb);
    }
    return vssa(t, r);
}

// ---- Calls: textures ------------------------------------------------------------------------------------------------

static enum glsl_sampler_dim shape_of(const char *op, bool *array, bool *ms, unsigned *coords)
{
    *array = strstr(op, "_array") != NULL;
    *ms = strstr(op, "_ms") != NULL;
    if (strstr(op, "_cube")) { *coords = 3; return GLSL_SAMPLER_DIM_CUBE; }
    if (strstr(op, "_3d")) { *coords = 3; return GLSL_SAMPLER_DIM_3D; }
    if (strstr(op, "_1d")) { *coords = 1; return GLSL_SAMPLER_DIM_1D; }
    if (strstr(op, "_buffer")) { *coords = 1; return GLSL_SAMPLER_DIM_BUF; }
    *coords = 2;
    return *ms ? GLSL_SAMPLER_DIM_MS : GLSL_SAMPLER_DIM_2D;
}

static nir_alu_type tex_type(LLVMTypeRef rt)
{
    LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
    unsigned bits, comps; bool flt;
    if (!type_info(vt, &bits, &comps, &flt)) return nir_type_float32;
    return flt ? nir_type_float32 : nir_type_uint32;
}

static void use_texture(T *t, int index, bool image, enum glsl_sampler_dim dim, bool array, nir_alu_type type)
{
    if (image) {
        t->refl->textures_written |= 1u << index;
        BITSET_SET(t->s->info.images_used, index);
        if (!t->img_vars[index]) {
            const struct glsl_type *it = glsl_image_type(dim, array, nir_get_glsl_base_type_for_nir_type(type));
            nir_variable *v = nir_variable_create(t->s, nir_var_image, it, "image");
            v->data.binding = index;
            t->img_vars[index] = v;
        }
    } else {
        t->refl->textures_used |= 1u << index;
        BITSET_SET(t->s->info.textures_used, index);
        if (!t->tex_vars[index]) {
            const struct glsl_type *st = glsl_texture_type(dim, array, nir_get_glsl_base_type_for_nir_type(type));
            nir_variable *v = nir_variable_create(t->s, nir_var_uniform, st, "texture");
            v->data.binding = index;
            t->tex_vars[index] = v;
        }
    }
}

static val *tex_result(T *t, LLVMTypeRef rt, nir_def *d)
{
    LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
    unsigned bits, comps; bool flt;
    if (type_info(vt, &bits, &comps, &flt)) {
        if (d->num_components > comps) d = nir_trim_vector(&t->b, d, comps);
        if (bits != d->bit_size) d = flt ? nir_f2fN(&t->b, d, bits) : nir_u2uN(&t->b, d, bits);
    }
    if (ts_LLVMGetTypeKind(rt) != LLVMStructTypeKind) return vssa(t, d);
    // { value, residency }: always resident.
    val *a = vnew(t, V_AGG);
    unsigned n = ts_LLVMCountStructElementTypes(rt);
    a->n = n; a->e = ralloc_array(t->mem, val *, n);
    a->e[0] = vssa(t, d);
    for (unsigned i = 1; i < n; i++) {
        LLVMTypeRef et = ts_LLVMStructGetTypeAtIndex(rt, i);
        unsigned eb, ec; bool ef;
        type_info(et, &eb, &ec, &ef);
        a->e[i] = vssa(t, eb == 1 ? nir_imm_true(&t->b) : nir_imm_intN_t(&t->b, 1, eb));
    }
    return a;
}

static nir_def *texture_size(T *t, int index, enum glsl_sampler_dim dim, bool array, nir_def *lod, nir_alu_type type)
{
    nir_builder *b = &t->b;
    unsigned comps = glsl_get_sampler_dim_coordinate_components(dim) + (array ? 1 : 0);
    if (dim == GLSL_SAMPLER_DIM_CUBE) comps = 2 + (array ? 1 : 0);
    nir_tex_instr *tex = nir_tex_instr_create(t->s, dim == GLSL_SAMPLER_DIM_MS || dim == GLSL_SAMPLER_DIM_BUF ? 0 : 1);
    tex->op = nir_texop_txs;
    tex->sampler_dim = dim;
    tex->is_array = array;
    tex->dest_type = nir_type_int32;
    tex->texture_index = (unsigned)index;
    tex->sampler_index = 0;
    if (tex->num_srcs) tex->src[0] = nir_tex_src_for_ssa(nir_tex_src_lod, lod ? nir_u2u32(b, lod) : nir_imm_int(b, 0));
    nir_def_init(&tex->instr, &tex->def, comps, 32);
    nir_builder_instr_insert(b, &tex->instr);
    use_texture(t, index, false, dim, array, type);
    return &tex->def;
}

static val *texture(T *t, LLVMValueRef inst, const char *name)
{
    nir_builder *b = &t->b;
    const char *op = name + 4;   // after "air."
    LLVMValueRef texArg = ts_LLVMGetOperand(inst, 0);
    LLVMTypeRef rt = ts_LLVMTypeOf(inst);
    if (is_undef(texArg)) {
        if (ts_LLVMGetTypeKind(rt) == LLVMVoidTypeKind) return vnew(t, V_NONE);
        return zero_val(t, rt);
    }
    val *tv = value(t, texArg);
    if (!tv) return NULL;
    if (tv->kind != V_TEX) FAIL(t, "texture call on a non-texture");
    bool array, ms;
    unsigned coords;
    enum glsl_sampler_dim dim = shape_of(op, &array, &ms, &coords);
    bool depth = strstr(op, "depth") != NULL;
    unsigned nargs = ts_LLVMGetNumArgOperands(inst);

    if (name_is(op, "get_")) {
        nir_def *lod = nargs > 1 ? arg(t, inst, 1) : NULL;
        if (nargs > 1 && !lod) return NULL;
        if (name_is(op, "get_num_samples")) {
            nir_tex_instr *tex = nir_tex_instr_create(t->s, 0);
            tex->op = nir_texop_texture_samples;
            tex->sampler_dim = dim; tex->is_array = array; tex->dest_type = nir_type_int32;
            tex->texture_index = (unsigned)tv->index;
            nir_def_init(&tex->instr, &tex->def, 1, 32);
            nir_builder_instr_insert(b, &tex->instr);
            use_texture(t, tv->index, false, dim, array, nir_type_float32);
            return vssa(t, fit_lanes(t, &tex->def, rt));
        }
        if (name_is(op, "get_num_mip_levels")) {
            nir_tex_instr *tex = nir_tex_instr_create(t->s, 0);
            tex->op = nir_texop_query_levels;
            tex->sampler_dim = dim; tex->is_array = array; tex->dest_type = nir_type_int32;
            tex->texture_index = (unsigned)tv->index;
            nir_def_init(&tex->instr, &tex->def, 1, 32);
            nir_builder_instr_insert(b, &tex->instr);
            use_texture(t, tv->index, false, dim, array, nir_type_float32);
            return vssa(t, fit_lanes(t, &tex->def, rt));
        }
        nir_def *size = texture_size(t, tv->index, dim, array, ms ? NULL : lod, nir_type_float32);
        unsigned c = name_is(op, "get_width") ? 0 : name_is(op, "get_height") ? 1 : name_is(op, "get_depth") ? 2
                   : /* array size */ size->num_components - 1;
        if (c >= size->num_components) c = size->num_components - 1;
        return vssa(t, fit_lanes(t, nir_channel(b, size, c), rt));
    }

    if (name_is(op, "write_")) {
        // write_<shape>(tex, coord, [layer/face], value, lod, access)
        unsigned wi = 1;
        nir_def *coord = arg(t, inst, wi++);
        if (!coord) return NULL;
        nir_def *layer = NULL;
        if (array || dim == GLSL_SAMPLER_DIM_CUBE) { if (!(layer = arg(t, inst, wi++))) return NULL; }
        unsigned vi = wi++;
        nir_def *data = arg(t, inst, vi);
        if (!data) return NULL;
        nir_def *lod = wi < nargs && !is_ptr(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, wi))) ? arg(t, inst, wi) : NULL;
        nir_alu_type type = is_float(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, vi))) ? nir_type_float32 : nir_type_uint32;
        if (data->bit_size != 32) data = type == nir_type_float32 ? nir_f2f32(b, data) : nir_u2u32(b, data);
        data = nir_pad_vector_imm_int(b, data, 0, 4);
        nir_def *c[4] = { nir_imm_int(b, 0), nir_imm_int(b, 0), nir_imm_int(b, 0), nir_imm_int(b, 0) };
        coord = nir_u2u32(b, coord);
        for (unsigned i = 0; i < coord->num_components && i < 3; i++) c[i] = nir_channel(b, coord, i);
        if (layer) c[coord->num_components] = nir_u2u32(b, layer);
        nir_image_store(b, nir_imm_int(b, tv->index), nir_vec(b, c, 4), nir_undef(b, 1, 32), data,
                        lod ? nir_u2u32(b, lod) : nir_imm_int(b, 0), .image_dim = dim, .image_array = array,
                        .src_type = type, .access = ACCESS_NON_READABLE);
        use_texture(t, tv->index, true, dim, array, type);
        return vnew(t, V_NONE);
    }

    if (name_is(op, "read_")) {
        // read_<shape>(tex, [sampler? no], coord, [layer/face], [offset], [lod | sample])
        unsigned i = 1;
        // Some read forms carry no sampler; the coordinate is the first integer vector/scalar after the texture.
        if (is_ptr(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 1)))) i = 2;
        nir_def *coord = arg(t, inst, i++);
        if (!coord) return NULL;
        coord = nir_u2u32(b, coord);
        nir_def *layer = NULL;
        if (array || dim == GLSL_SAMPLER_DIM_CUBE) { if (!(layer = arg(t, inst, i++))) return NULL; layer = nir_u2u32(b, layer); }
        if (i < nargs && ts_LLVMGetTypeKind(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i))) == LLVMVectorTypeKind) i++;   // offset
        nir_def *lod = i < nargs ? arg(t, inst, i) : NULL;
        if (i < nargs && !lod) return NULL;
        if (lod) lod = nir_u2u32(b, lod);
        nir_alu_type type = tex_type(rt);
        bool rw = strstr(name, "read_write") != NULL;
        if (rw && t->stage != MESA_SHADER_VERTEX) {
            nir_def *c[4] = { nir_imm_int(b, 0), nir_imm_int(b, 0), nir_imm_int(b, 0), nir_imm_int(b, 0) };
            for (unsigned k = 0; k < coord->num_components && k < 3; k++) c[k] = nir_channel(b, coord, k);
            if (layer) c[coord->num_components] = layer;
            nir_def *d = nir_image_load(b, 4, 32, nir_imm_int(b, tv->index), nir_vec(b, c, 4), nir_undef(b, 1, 32),
                                        lod ? lod : nir_imm_int(b, 0), .image_dim = dim, .image_array = array, .dest_type = type);
            use_texture(t, tv->index, true, dim, array, type);
            return tex_result(t, rt, d);
        }
        nir_def *c = coord;
        if (layer) c = nir_vec(b, (nir_def *[]){ nir_channel(b, coord, 0), nir_channel(b, coord, 1), layer }, 3);
        if (dim == GLSL_SAMPLER_DIM_CUBE) dim = GLSL_SAMPLER_DIM_2D, array = true;   // faces read as layers
        nir_tex_instr *tex = nir_tex_instr_create(t->s, 2);
        tex->op = ms ? nir_texop_txf_ms : nir_texop_txf;
        tex->sampler_dim = dim; tex->is_array = array; tex->dest_type = type;
        tex->coord_components = c->num_components;
        tex->texture_index = (unsigned)tv->index;
        tex->src[0] = nir_tex_src_for_ssa(nir_tex_src_coord, c);
        tex->src[1] = nir_tex_src_for_ssa(ms ? nir_tex_src_ms_index : nir_tex_src_lod, lod ? lod : nir_imm_int(b, 0));
        nir_def_init(&tex->instr, &tex->def, 4, 32);
        nir_builder_instr_insert(b, &tex->instr);
        use_texture(t, tv->index, false, dim, array, type);
        return tex_result(t, rt, depth ? nir_channel(b, &tex->def, 0) : &tex->def);
    }

    // sample[_compare]_<shape>[_grad](tex, sampler, [i32 1 for depth/compare], coord, [layer], [ref], ...)
    // gather[_compare]_<shape>(tex, sampler, [i32 1], coord, [layer], [ref], [i1 normalized, int2 offset], [component])
    bool gather = name_is(op, "gather");
    bool cmp = strstr(op, "_compare") != NULL;
    bool grad = strstr(op, "_grad") != NULL;
    val *sv = value(t, ts_LLVMGetOperand(inst, 1));
    if (!sv) return NULL;
    if (sv->kind != V_SMP) FAIL(t, "sample without a sampler");
    unsigned i = 2;
    if (cmp || depth) {
        LLVMValueRef x = ts_LLVMGetOperand(inst, 2);
        if (ts_LLVMIsAConstantInt(x) && ts_LLVMGetIntTypeWidth(ts_LLVMTypeOf(x)) == 32) i = 3;
    }
    nir_def *coord = arg(t, inst, i++);
    if (!coord) return NULL;
    coord = nir_f2f32(b, coord);
    if (sv->pixel && dim != GLSL_SAMPLER_DIM_CUBE) {
        nir_def *size = nir_i2f32(b, texture_size(t, tv->index, dim, array, NULL, nir_type_float32));
        coord = nir_fdiv(b, coord, nir_trim_vector(b, size, coord->num_components));
    }
    nir_def *layer = NULL, *ref = NULL;
    if (array) { if (!(layer = arg(t, inst, i++))) return NULL; layer = layer->bit_size == 32 && !is_float(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i - 1))) ? nir_u2f32(b, layer) : nir_f2f32(b, layer); }
    if (cmp) { if (!(ref = arg(t, inst, i++))) return NULL; ref = nir_f2f32(b, ref); }
    nir_tex_src srcs[8];
    unsigned ns = 0;
    nir_def *c = coord;
    if (layer) {
        nir_def *cc[4];
        for (unsigned k = 0; k < coord->num_components; k++) cc[k] = nir_channel(b, coord, k);
        cc[coord->num_components] = layer;
        c = nir_vec(b, cc, coord->num_components + 1);
    }
    srcs[ns++] = nir_tex_src_for_ssa(nir_tex_src_coord, c);
    if (ref) srcs[ns++] = nir_tex_src_for_ssa(nir_tex_src_comparator, ref);
    nir_texop texop = gather ? nir_texop_tg4 : nir_texop_tex;
    unsigned component = 0;
    if (grad) {
        nir_def *dx = arg(t, inst, i), *dy = arg(t, inst, i + 1);
        if (!dx || !dy) return NULL;
        srcs[ns++] = nir_tex_src_for_ssa(nir_tex_src_ddx, nir_f2f32(b, dx));
        srcs[ns++] = nir_tex_src_for_ssa(nir_tex_src_ddy, nir_f2f32(b, dy));
        texop = nir_texop_txd;
        i += 2;
        if (i < nargs && ts_LLVMGetTypeKind(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i))) == LLVMIntegerTypeKind &&
            ts_LLVMGetIntTypeWidth(ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i))) == 1) i++;
    } else {
        if (dim != GLSL_SAMPLER_DIM_CUBE && i < nargs) i++;   // normalized-coordinates flag
        if (dim != GLSL_SAMPLER_DIM_CUBE && i < nargs) {
            LLVMValueRef off = ts_LLVMGetOperand(inst, i++);
            if (!ts_LLVMIsAConstantAggregateZero(off)) {
                nir_def *o = ssa(t, off);
                if (!o) return NULL;
                srcs[ns++] = nir_tex_src_for_ssa(nir_tex_src_offset, nir_i2i32(b, o));
            }
        }
        if (gather) {
            if (!depth && i + 1 < nargs) {
                LLVMValueRef cv = ts_LLVMGetOperand(inst, i);
                if (ts_LLVMIsAConstantInt(cv)) component = (unsigned)ts_LLVMConstIntGetZExtValue(cv);
            }
        } else if (i + 1 < nargs) {
            LLVMValueRef isLod = ts_LLVMGetOperand(inst, i++);
            nir_def *amount = arg(t, inst, i++);
            if (!amount) return NULL;
            bool lod = ts_LLVMIsAConstantInt(isLod) && ts_LLVMConstIntGetZExtValue(isLod);
            if (lod || t->stage != MESA_SHADER_FRAGMENT) {
                srcs[ns++] = nir_tex_src_for_ssa(nir_tex_src_lod, lod ? nir_f2f32(b, amount) : nir_imm_float(b, 0));
                texop = nir_texop_txl;
            } else {
                nir_def *bias = nir_f2f32(b, amount);
                if (!nir_src_is_const(nir_src_for_ssa(bias)) || nir_src_as_float(nir_src_for_ssa(bias)) != 0) {
                    srcs[ns++] = nir_tex_src_for_ssa(nir_tex_src_bias, bias);
                    texop = nir_texop_txb;
                }
            }
            if (i < nargs) {
                LLVMValueRef minv = ts_LLVMGetOperand(inst, i);
                if (is_float(ts_LLVMTypeOf(minv)) && !(ts_LLVMIsAConstantFP(minv))) {
                    nir_def *mn = ssa(t, minv);
                    if (!mn) return NULL;
                    srcs[ns++] = nir_tex_src_for_ssa(nir_tex_src_min_lod, nir_f2f32(b, mn));
                }
            }
        }
    }
    nir_alu_type type = tex_type(rt);
    nir_tex_instr *tex = nir_tex_instr_create(t->s, ns);
    tex->op = texop;
    tex->sampler_dim = dim;
    tex->is_array = array;
    tex->is_shadow = cmp;
    tex->dest_type = type;
    tex->coord_components = c->num_components;
    tex->component = component;
    tex->texture_index = (unsigned)tv->index;
    tex->sampler_index = (unsigned)sv->index;
    memcpy(tex->src, srcs, ns * sizeof srcs[0]);
    nir_def_init(&tex->instr, &tex->def, 4, 32);
    nir_builder_instr_insert(b, &tex->instr);
    use_texture(t, tv->index, false, dim, array, type);
    BITSET_SET(t->s->info.samplers_used, sv->index);
    if (sv->index < 32 && !t->smp_vars[sv->index]) {
        // Sampler variables: some drivers (llvmpipe) size their sampler state from them.
        nir_variable *v = nir_variable_create(t->s, nir_var_uniform, glsl_bare_sampler_type(), "sampler");
        v->data.binding = sv->index;
        t->smp_vars[sv->index] = v;
    }
    nir_def *d = &tex->def;
    if ((depth && !gather) || cmp) d = nir_channel(b, d, 0);
    return tex_result(t, rt, d);
}

// ---- Calls: compute -------------------------------------------------------------------------------------------------

static val *barrier(T *t, LLVMValueRef inst, bool execution)
{
    // air.wg.barrier(i32 mem_flags, i32 scope) / air.mem_barrier(i32 mem_flags, i32 scope)
    unsigned flags = 0;
    LLVMValueRef fv = ts_LLVMGetNumArgOperands(inst) ? ts_LLVMGetOperand(inst, 0) : NULL;
    if (fv && ts_LLVMIsAConstantInt(fv)) flags = (unsigned)ts_LLVMConstIntGetZExtValue(fv);
    nir_variable_mode modes = 0;
    if (flags & 1) modes |= nir_var_mem_ssbo;      // mem_flags::mem_device
    if (flags & 2) modes |= nir_var_mem_shared;    // mem_threadgroup
    if (flags & 4) modes |= nir_var_image;         // mem_texture
    if (!modes && !execution) return vnew(t, V_NONE);
    if (t->stage != MESA_SHADER_COMPUTE) execution = false;
    nir_barrier(&t->b, .execution_scope = execution ? SCOPE_WORKGROUP : SCOPE_NONE,
                .memory_scope = modes & nir_var_mem_ssbo ? SCOPE_DEVICE : SCOPE_WORKGROUP,
                .memory_semantics = modes ? NIR_MEMORY_ACQ_REL : 0, .memory_modes = modes);
    return vnew(t, V_NONE);
}

static val *atomic(T *t, LLVMValueRef inst, const char *name)
{
    // air.atomic.<global|local>.<op>[.<s|u>].i32(ptr, value, [cmp], i32 order, i32 scope, i1 volatile)
    nir_builder *b = &t->b;
    const char *p = strchr(name + strlen("air.atomic."), '.');
    if (!p) FAIL(t, "malformed %s", name);
    p++;
    char op[32];
    const char *e = strchr(p, '.');
    snprintf(op, sizeof op, "%.*s", e ? (int)(e - p) : (int)strlen(p), p);
    bool u = strstr(name, ".u.") != NULL;
    val *ptr = value(t, ts_LLVMGetOperand(inst, 0));
    if (!ptr) return NULL;
    if (ptr->kind != V_PTR || (ptr->sp != SP_SSBO && ptr->sp != SP_SHARED)) FAIL(t, "atomic on unsupported memory");
    nir_def *data = arg(t, inst, 1);
    if (!data) return NULL;
    nir_atomic_op aop;
    bool swap = false, load = false, store = false;
    if (!strcmp(op, "add")) aop = nir_atomic_op_iadd;
    else if (!strcmp(op, "sub")) { aop = nir_atomic_op_iadd; data = nir_ineg(b, data); }
    else if (!strcmp(op, "and")) aop = nir_atomic_op_iand;
    else if (!strcmp(op, "or")) aop = nir_atomic_op_ior;
    else if (!strcmp(op, "xor")) aop = nir_atomic_op_ixor;
    else if (!strcmp(op, "min")) aop = u ? nir_atomic_op_umin : nir_atomic_op_imin;
    else if (!strcmp(op, "max")) aop = u ? nir_atomic_op_umax : nir_atomic_op_imax;
    else if (!strcmp(op, "xchg")) aop = nir_atomic_op_xchg;
    else if (!strcmp(op, "cmpxchg")) { aop = nir_atomic_op_cmpxchg; swap = true; }
    else if (!strcmp(op, "load")) { load = true; aop = nir_atomic_op_iadd; }
    else if (!strcmp(op, "store")) { store = true; aop = nir_atomic_op_xchg; }
    else FAIL(t, "unsupported atomic %s", name);
    if (load) return vssa(t, mem_load(t, ptr, 1, 32, 4));
    nir_def *r;
    if (swap) {
        // cmpxchg(ptr, expected*, desired, ...): AIR passes the expected value through a pointer.
        val *expp = value(t, ts_LLVMGetOperand(inst, 1));
        nir_def *desired = arg(t, inst, 2);
        if (!expp || !desired) return NULL;
        nir_def *expected = expp->kind == V_PTR ? mem_load(t, expp, 1, 32, 4) : expp->def;
        r = ptr->sp == SP_SSBO ? nir_ssbo_atomic_swap(b, 32, ptr->slot, ssbo_offset(t, ptr), expected, desired, .atomic_op = aop)
                               : nir_shared_atomic_swap(b, 32, ptr->off, expected, desired, .atomic_op = aop);
        if (expp->kind == V_PTR) mem_store(t, expp, r, 4);
        return vssa(t, nir_ieq(b, r, expected));
    }
    r = ptr->sp == SP_SSBO ? nir_ssbo_atomic(b, 32, ptr->slot, ssbo_offset(t, ptr), data, .atomic_op = aop)
                           : nir_shared_atomic(b, 32, ptr->off, data, .atomic_op = aop);
    if (store) return vnew(t, V_NONE);
    return vssa(t, r);
}

static val *subgroup(T *t, LLVMValueRef inst, const char *name)
{
    nir_builder *b = &t->b;
    nir_def *x = ts_LLVMGetNumArgOperands(inst) ? arg(t, inst, 0) : NULL;
    nir_def *y = ts_LLVMGetNumArgOperands(inst) > 1 ? arg(t, inst, 1) : NULL;
    bool quad = name_is(name, "air.quad_");
    const char *op = name + (quad ? 9 : 9);   // "air.simd_" and "air.quad_" are both 9 characters
    nir_def *r = NULL;
    if (name_is(op, "shuffle_xor")) r = quad ? nir_shuffle(b, x, nir_ixor(b, nir_load_subgroup_invocation(b), nir_u2u32(b, y))) : nir_shuffle_xor(b, x, nir_u2u32(b, y));
    else if (name_is(op, "shuffle_up")) r = nir_shuffle_up(b, x, nir_u2u32(b, y));
    else if (name_is(op, "shuffle_down")) r = nir_shuffle_down(b, x, nir_u2u32(b, y));
    else if (name_is(op, "shuffle")) {
        nir_def *lane = nir_u2u32(b, y);
        if (quad) lane = nir_ior(b, nir_iand_imm(b, nir_load_subgroup_invocation(b), ~3u), nir_iand_imm(b, lane, 3));
        r = nir_shuffle(b, x, lane);
    } else if (name_is(op, "broadcast_first")) r = nir_read_first_invocation(b, x);
    else if (name_is(op, "broadcast")) r = quad ? nir_quad_broadcast(b, x, nir_u2u32(b, y)) : nir_read_invocation(b, x, nir_u2u32(b, y));
    else if (name_is(op, "sum")) r = nir_reduce(b, x, .reduction_op = is_float(ts_LLVMTypeOf(inst)) ? nir_op_fadd : nir_op_iadd, .cluster_size = quad ? 4 : 0);
    else if (name_is(op, "product")) r = nir_reduce(b, x, .reduction_op = is_float(ts_LLVMTypeOf(inst)) ? nir_op_fmul : nir_op_imul, .cluster_size = quad ? 4 : 0);
    else if (name_is(op, "min")) r = nir_reduce(b, x, .reduction_op = is_float(ts_LLVMTypeOf(inst)) ? nir_op_fmin : strstr(name, ".u.") ? nir_op_umin : nir_op_imin, .cluster_size = quad ? 4 : 0);
    else if (name_is(op, "max")) r = nir_reduce(b, x, .reduction_op = is_float(ts_LLVMTypeOf(inst)) ? nir_op_fmax : strstr(name, ".u.") ? nir_op_umax : nir_op_imax, .cluster_size = quad ? 4 : 0);
    else if (name_is(op, "all")) r = nir_vote_all(b, 1, x);
    else if (name_is(op, "any")) r = nir_vote_any(b, 1, x);
    else if (name_is(op, "is_first")) r = nir_elect(b, 1);
    else if (name_is(op, "ballot")) r = nir_u2uN(b, nir_ballot(b, 1, 32, x), 64);
    if (!r) FAIL(t, "unsupported %s", name);
    return vssa(t, fit_lanes(t, r, ts_LLVMTypeOf(inst)));
}

// ---- Calls ----------------------------------------------------------------------------------------------------------

static val *memcpy_set(T *t, LLVMValueRef inst, bool set)
{
    val *dst = value(t, ts_LLVMGetOperand(inst, 0));
    LLVMValueRef lenv = ts_LLVMGetOperand(inst, 2);
    if (!dst) return NULL;
    if (!ts_LLVMIsAConstantInt(lenv)) FAIL(t, "memcpy/memset with a dynamic size");
    uint64_t len = ts_LLVMConstIntGetZExtValue(lenv);
    if (len > 65536) FAIL(t, "memcpy/memset of %llu bytes", (unsigned long long)len);
    if (dst->kind != V_PTR) FAIL(t, "memcpy/memset into a non-pointer");
    nir_builder *b = &t->b;
    if (set) {
        nir_def *byte = ssa(t, ts_LLVMGetOperand(inst, 1));
        if (!byte) return NULL;
        nir_def *w = nir_imul_imm(b, nir_u2u32(b, byte), 0x01010101);
        uint64_t o = 0;
        for (; o + 4 <= len; o += 4) if (!mem_store(t, ptr_add_imm(t, dst, (int64_t)o), w, 1)) return NULL;
        for (; o < len; o++) if (!mem_store(t, ptr_add_imm(t, dst, (int64_t)o), nir_u2u8(b, byte), 1)) return NULL;
        return vnew(t, V_NONE);
    }
    val *src = value(t, ts_LLVMGetOperand(inst, 1));
    if (!src) return NULL;
    if (src->kind != V_PTR) FAIL(t, "memcpy from a non-pointer");
    uint64_t o = 0;
    for (; o + 4 <= len; o += 4)
        if (!mem_store(t, ptr_add_imm(t, dst, (int64_t)o), mem_load(t, ptr_add_imm(t, src, (int64_t)o), 1, 32, 1), 1)) return NULL;
    for (; o < len; o++)
        if (!mem_store(t, ptr_add_imm(t, dst, (int64_t)o), mem_load(t, ptr_add_imm(t, src, (int64_t)o), 1, 8, 1), 1)) return NULL;
    return vnew(t, V_NONE);
}

static bool is_texture_op(const char *op)
{
    return name_is(op, "sample_") || name_is(op, "read_") || name_is(op, "write_") || name_is(op, "gather_") ||
           name_is(op, "get_width_") || name_is(op, "get_height_") || name_is(op, "get_depth_") ||
           name_is(op, "get_array_size_") || name_is(op, "get_num_mip_levels_") || name_is(op, "get_num_samples_");
}

static val *call(T *t, LLVMValueRef inst)
{
    LLVMValueRef callee = ts_LLVMGetCalledValue(inst);
    char *name = llvm_name(callee);
    if (!name) FAIL(t, "indirect call");
    val *r = NULL;
    nir_builder *b = &t->b;
    if (name_is(name, "llvm.lifetime") || name_is(name, "llvm.dbg") || name_is(name, "llvm.assume") ||
        name_is(name, "llvm.experimental.noalias") || name_is(name, "llvm.invariant") || name_is(name, "air.set_"))
        r = vnew(t, V_NONE);
    else if (!strcmp(name, "air.discard_fragment")) { nir_terminate(b); r = vnew(t, V_NONE); t->refl->discards = true; }
    else if (name_is(name, "air.wg.barrier")) r = barrier(t, inst, true);
    else if (name_is(name, "air.mem_barrier") || name_is(name, "air.simdgroup.barrier")) r = barrier(t, inst, false);
    else if (name_is(name, "air.get_num_samples")) r = vssa(t, fit_lanes(t, t->stage == MESA_SHADER_FRAGMENT ? sysval_word(t, 48, 1) : nir_imm_int(b, 1), ts_LLVMTypeOf(inst)));
    else if (!strcmp(name, "air.get_read_sampler")) { r = vnew(t, V_SMP); r->index = 0; }
    else if (name_is(name, "llvm.memcpy") || name_is(name, "llvm.memmove")) r = memcpy_set(t, inst, false);
    else if (name_is(name, "llvm.memset")) r = memcpy_set(t, inst, true);
    else if (name_is(name, "air.atomic.")) r = atomic(t, inst, name);
    else if (name_is(name, "air.simd_") || name_is(name, "air.quad_")) r = subgroup(t, inst, name);
    else if (name_is(name, "air.convert.")) r = convert(t, inst, name);
    else if (name_is(name, "air.") && is_texture_op(name + 4)) r = texture(t, inst, name);
    else if (name_is(name, "air.") || name_is(name, "llvm.")) r = math(t, inst, name);
    else if (!t->error) t->error = vmg_strdup_printf("call to %s (functions are inlined before translation)", name);
    free(name);
    return r;
}

// ---- Control flow ---------------------------------------------------------------------------------------------------

static nir_block *block_for(T *t, LLVMBasicBlockRef bb)
{
    struct hash_entry *he = _mesa_hash_table_search(t->blocks, bb);
    return he ? he->data : NULL;
}

static nir_variable *phi_var(T *t, LLVMValueRef phi)
{
    struct hash_entry *he = _mesa_hash_table_search(t->phis, phi);
    return he ? he->data : NULL;
}

// Stores the incoming values of the phis of `to` for the edge from `from` (at the builder's cursor).
static bool edge_copies(T *t, LLVMBasicBlockRef from, LLVMBasicBlockRef to)
{
    // Read every incoming value first (a phi may feed another phi of the same block).
    struct { nir_variable *var; nir_def *d; } copies[64];
    unsigned n = 0;
    for (LLVMValueRef i = ts_LLVMGetFirstInstruction(to); i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI; i = ts_LLVMGetNextInstruction(i)) {
        nir_variable *var = phi_var(t, i);
        if (!var) continue;   // pointer/aggregate phis are not supported (failed earlier)
        for (unsigned k = 0; k < ts_LLVMCountIncoming(i); k++) {
            if (ts_LLVMGetIncomingBlock(i, k) != from) continue;
            val *v = value(t, ts_LLVMGetIncomingValue(i, k));
            if (!v) return false;
            nir_def *d = v->kind == V_SSA ? v->def : v->kind == V_PTR ? v->off : NULL;
            if (!d) FAILB(t, "phi of a resource");
            if (n >= 64) FAILB(t, "too many phis");
            copies[n].var = var; copies[n].d = d; n++;
            break;
        }
    }
    for (unsigned k = 0; k < n; k++) nir_store_var(&t->b, copies[k].var, copies[k].d, nir_component_mask(copies[k].d->num_components));
    return true;
}

static nir_block *new_block(T *t)
{
    nir_block *nb = nir_block_create(t->impl);
    exec_list_push_tail(&t->impl->body, &nb->cf_node.node);
    nb->cf_node.parent = &t->impl->cf_node;
    return nb;
}

static bool has_phis(LLVMBasicBlockRef bb)
{
    LLVMValueRef i = ts_LLVMGetFirstInstruction(bb);
    return i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI;
}

static void goto_edge(T *t, LLVMBasicBlockRef from, LLVMBasicBlockRef to)
{
    edge_copies(t, from, to);
    nir_goto(&t->b, block_for(t, to));
}

static bool terminator(T *t, LLVMValueRef term, LLVMBasicBlockRef bb)
{
    nir_builder *b = &t->b;
    switch (ts_LLVMGetInstructionOpcode(term)) {
    case LLVMRet:
        if (!emit_return(t, term)) return false;
        nir_goto(b, t->impl->end_block);
        return true;
    case LLVMUnreachable:
        nir_goto(b, t->impl->end_block);
        return true;
    case LLVMBr:
        if (!ts_LLVMIsConditional(term)) {
            goto_edge(t, bb, ts_LLVMGetSuccessor(term, 0));
            return !t->error;
        } else {
            nir_def *c = ssa(t, ts_LLVMGetCondition(term));
            if (!c) return false;
            LLVMBasicBlockRef tb = ts_LLVMGetSuccessor(term, 0), fb = ts_LLVMGetSuccessor(term, 1);
            if (tb == fb) { goto_edge(t, bb, tb); return !t->error; }
            // Edges into blocks with phis get their own block for the copies.
            nir_block *tn = block_for(t, tb), *fn = block_for(t, fb);
            nir_block *te = tn, *fe = fn;
            if (has_phis(tb)) te = new_block(t);
            if (has_phis(fb)) fe = new_block(t);
            nir_goto_if(b, te, c, fe);
            if (te != tn) { b->cursor = nir_after_block(te); goto_edge(t, bb, tb); }
            if (fe != fn) { b->cursor = nir_after_block(fe); goto_edge(t, bb, fb); }
            return !t->error;
        }
    case LLVMSwitch: {
        // switch(cond, default, (value, dest)*): a chain of goto_if blocks, as spirv_to_nir does.
        nir_def *sel = ssa(t, ts_LLVMGetOperand(term, 0));
        if (!sel) return false;
        unsigned ncases = ts_LLVMGetNumSuccessors(term) - 1;
        for (unsigned k = 0; k < ncases; k++) {
            LLVMValueRef cv = ts_LLVMGetOperand(term, 2 + 2 * k);
            LLVMBasicBlockRef dest = ts_LLVMGetSuccessor(term, k + 1);
            nir_def *cond = nir_ieq_imm(b, sel, ts_LLVMConstIntGetZExtValue(cv));
            nir_block *next = new_block(t), *target = block_for(t, dest);
            nir_block *edge = has_phis(dest) ? new_block(t) : target;
            nir_goto_if(b, edge, cond, next);
            if (edge != target) { b->cursor = nir_after_block(edge); goto_edge(t, bb, dest); }
            b->cursor = nir_after_block(next);
        }
        goto_edge(t, bb, ts_LLVMGetSuccessor(term, 0));
        return !t->error;
    }
    default:
        FAILB(t, "unsupported terminator %d", ts_LLVMGetInstructionOpcode(term));
    }
}

static bool instruction(T *t, LLVMValueRef inst)
{
    LLVMOpcode op = ts_LLVMGetInstructionOpcode(inst);
    val *r = NULL;
    switch (op) {
    case LLVMAdd: case LLVMSub: case LLVMMul: case LLVMUDiv: case LLVMSDiv: case LLVMURem: case LLVMSRem:
    case LLVMShl: case LLVMLShr: case LLVMAShr: case LLVMAnd: case LLVMOr: case LLVMXor:
    case LLVMFAdd: case LLVMFSub: case LLVMFMul: case LLVMFDiv: case LLVMFRem:
        r = binary(t, inst, op); break;
    case LLVMFNeg: { nir_def *x = ssa(t, ts_LLVMGetOperand(inst, 0)); r = x ? vssa(t, nir_fneg(&t->b, x)) : NULL; break; }
    case LLVMFreeze: r = value(t, ts_LLVMGetOperand(inst, 0)); break;
    case LLVMICmp: r = compare(t, inst, false); break;
    case LLVMFCmp: r = compare(t, inst, true); break;
    case LLVMTrunc: case LLVMZExt: case LLVMSExt: case LLVMFPToUI: case LLVMFPToSI: case LLVMUIToFP: case LLVMSIToFP:
    case LLVMFPTrunc: case LLVMFPExt: case LLVMBitCast: case LLVMAddrSpaceCast: case LLVMPtrToInt: case LLVMIntToPtr:
        r = cast(t, inst, op); break;
    case LLVMSelect: r = select_inst(t, inst); break;
    case LLVMExtractElement: {
        nir_def *v = ssa(t, ts_LLVMGetOperand(inst, 0)), *i = ssa(t, ts_LLVMGetOperand(inst, 1));
        if (v && i) r = vssa(t, nir_src_is_const(nir_src_for_ssa(i)) ? nir_channel(&t->b, v, (unsigned)nir_src_as_uint(nir_src_for_ssa(i)))
                                                                    : nir_vector_extract(&t->b, v, nir_u2u32(&t->b, i)));
        break;
    }
    case LLVMInsertElement: {
        nir_def *v = ssa(t, ts_LLVMGetOperand(inst, 0)), *x = ssa(t, ts_LLVMGetOperand(inst, 1)), *i = ssa(t, ts_LLVMGetOperand(inst, 2));
        if (v && x && i) r = vssa(t, nir_src_is_const(nir_src_for_ssa(i)) ? nir_vector_insert_imm(&t->b, v, x, (unsigned)nir_src_as_uint(nir_src_for_ssa(i)))
                                                                          : nir_vector_insert(&t->b, v, x, nir_u2u32(&t->b, i)));
        break;
    }
    case LLVMShuffleVector: r = shuffle(t, inst); break;
    case LLVMExtractValue: {
        val *a = value(t, ts_LLVMGetOperand(inst, 0));
        r = a ? extract_value(t, a, ts_LLVMGetIndices(inst), ts_LLVMGetNumIndices(inst)) : NULL;
        break;
    }
    case LLVMInsertValue: {
        val *a = value(t, ts_LLVMGetOperand(inst, 0)), *v = value(t, ts_LLVMGetOperand(inst, 1));
        r = a && v ? insert_value(t, a, v, ts_LLVMGetIndices(inst), ts_LLVMGetNumIndices(inst)) : NULL;
        break;
    }
    case LLVMAlloca: {
        LLVMTypeRef ty = ts_LLVMGetAllocatedType(inst);
        unsigned a = align_of(ts_LLVMGetAlignment(inst));
        if (a < 4) a = 4;
        t->scratch = (t->scratch + a - 1) & ~(a - 1);
        r = vptr(t, SP_SCRATCH, NULL, nir_imm_int(&t->b, (int)t->scratch));
        t->scratch += (unsigned)tsize(t, ty);
        break;
    }
    case LLVMGetElementPtr: r = gep(t, inst, (unsigned)ts_LLVMGetNumOperands(inst)); break;
    case LLVMLoad: {
        val *p = value(t, ts_LLVMGetOperand(inst, 0));
        if (!p) return false;
        if (p->kind != V_PTR) FAILB(t, "load from a non-pointer");
        r = load_typed(t, p, ts_LLVMTypeOf(inst), align_of(ts_LLVMGetAlignment(inst)));
        break;
    }
    case LLVMStore: {
        val *v = value(t, ts_LLVMGetOperand(inst, 0)), *p = value(t, ts_LLVMGetOperand(inst, 1));
        if (!v || !p) return false;
        if (p->kind != V_PTR) FAILB(t, "store to a non-pointer");
        if (p->sp == SP_SSBO) {
            nir_def *slot = p->slot;
            if (nir_src_is_const(nir_src_for_ssa(slot))) t->refl->buffers_written |= 1u << nir_src_as_uint(nir_src_for_ssa(slot));
            else t->refl->buffers_written = ~0u;
        }
        return store_typed(t, p, v, ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0)), align_of(ts_LLVMGetAlignment(inst)));
    }
    case LLVMCall: r = call(t, inst); break;
    case LLVMPHI: {
        nir_variable *var = phi_var(t, inst);
        if (!var) FAILB(t, "phi of an unsupported type");
        nir_def *d = nir_load_var(&t->b, var);
        LLVMTypeRef ty = ts_LLVMTypeOf(inst);
        if (is_ptr(ty)) {
            // Pointer phis: the space and slot of the first incoming pointer (all must agree).
            val *first = NULL;
            for (unsigned k = 0; k < ts_LLVMCountIncoming(inst) && !first; k++) {
                LLVMValueRef iv = ts_LLVMGetIncomingValue(inst, k);
                struct hash_entry *he = _mesa_hash_table_search(t->vals, iv);
                if (he) first = he->data;
                else if (ts_LLVMIsAConstant(iv) || ts_LLVMIsAArgument(iv)) first = value(t, iv);
            }
            if (!first || first->kind != V_PTR) FAILB(t, "pointer phi with no known incoming pointer");
            r = vptr(t, first->sp, first->slot, d);
        } else r = vssa(t, d);
        break;
    }
    case LLVMFence: r = vnew(t, V_NONE); break;
    default: FAILB(t, "unsupported instruction %d", op);
    }
    if (!r) return false;
    _mesa_hash_table_insert(t->vals, inst, r);
    return true;
}

static bool declare_phis(T *t)
{
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(t->fn); bb; bb = ts_LLVMGetNextBasicBlock(bb)) {
        for (LLVMValueRef i = ts_LLVMGetFirstInstruction(bb); i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI; i = ts_LLVMGetNextInstruction(i)) {
            LLVMTypeRef ty = ts_LLVMTypeOf(i);
            const struct glsl_type *gt;
            if (is_ptr(ty)) gt = glsl_uint_type();
            else {
                unsigned bits, comps; bool flt;
                if (!type_info(ty, &bits, &comps, &flt)) FAILB(t, "phi of an aggregate");
                gt = glsl_for(bits, comps, false);
            }
            nir_variable *var = nir_local_variable_create(t->impl, gt, "phi");
            _mesa_hash_table_insert(t->phis, i, var);
        }
    }
    return true;
}

static bool emit_function(T *t)
{
    // One NIR block per LLVM block, in LLVM order (the entry first).
    bool first = true;
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(t->fn); bb; bb = ts_LLVMGetNextBasicBlock(bb)) {
        nir_block *nb;
        if (first) nb = nir_start_block(t->impl);
        else {
            nb = nir_block_create(t->impl);
            exec_list_push_tail(&t->impl->body, &nb->cf_node.node);
            nb->cf_node.parent = &t->impl->cf_node;
        }
        first = false;
        _mesa_hash_table_insert(t->blocks, bb, nb);
    }
    if (!declare_phis(t)) return false;
    // Instructions in reverse post-order: every definition is emitted before its uses (LLVM's block layout does not
    // promise that; phis read their back-edge values through variables).
    unsigned nblocks = 0;
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(t->fn); bb; bb = ts_LLVMGetNextBasicBlock(bb)) nblocks++;
    LLVMBasicBlockRef *order = calloc(nblocks, sizeof *order), *stack = calloc(nblocks * 2 + 2, sizeof *stack);
    unsigned *next_succ = calloc(nblocks * 2 + 2, sizeof *next_succ);
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
            order[norder++] = bb;   // post-order
            sp--;
        }
    }
    bool ok = true;
    for (unsigned k = norder; k-- > 0 && ok;) {
        LLVMBasicBlockRef bb = order[k];
        t->b.cursor = nir_after_block(block_for(t, bb));
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
        for (LLVMValueRef i = ts_LLVMGetFirstInstruction(bb); i && i != term && ok; i = ts_LLVMGetNextInstruction(i))
            ok = instruction(t, i);
        if (ok && (!term || !terminator(t, term, bb))) ok = false;
    }
    // Unreachable blocks were never filled: give them a jump so the CFG stays valid.
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(t->fn); bb && ok; bb = ts_LLVMGetNextBasicBlock(bb))
        if (!_mesa_hash_table_search(seen, bb)) { t->b.cursor = nir_after_block(block_for(t, bb)); nir_goto(&t->b, t->impl->end_block); }
    free(order); free(stack); free(next_succ);
    return ok;
}

// ---- Module ---------------------------------------------------------------------------------------------------------

static const char *kCleanupPasses = "inline,function(sroa,early-cse,instcombine,dse,adce,simplifycfg,instcombine,simplifycfg)";

// Legacy pass manager (iOS 16's libLLVM has no LLVMRunPasses): the same two pipelines.
static char *run_passes_legacy(LLVMModuleRef mod, const char *pipeline)
{
    if (!ts_LLVMCreatePassManager || !ts_LLVMRunPassManager || !ts_LLVMAddAlwaysInlinerPass)
        return strdup("libLLVM has neither the new nor the legacy pass manager");
    LLVMPassManagerRef pm = ts_LLVMCreatePassManager();
    if (!strcmp(pipeline, "always-inline")) ts_LLVMAddAlwaysInlinerPass(pm);
    else {
#define ADD(p) if (ts_##p) ts_##p(pm)
        ADD(LLVMAddFunctionInliningPass);
        ADD(LLVMAddScalarReplAggregatesPass);
        ADD(LLVMAddPromoteMemoryToRegisterPass);
        ADD(LLVMAddEarlyCSEPass);
        ADD(LLVMAddInstructionCombiningPass);
        ADD(LLVMAddDeadStoreEliminationPass);
        ADD(LLVMAddAggressiveDCEPass);
        ADD(LLVMAddCFGSimplificationPass);
        ADD(LLVMAddInstructionCombiningPass);
        ADD(LLVMAddCFGSimplificationPass);
#undef ADD
    }
    ts_LLVMRunPassManager(pm, mod);
    ts_LLVMDisposePassManager(pm);
    return NULL;
}

static char *run_passes(LLVMModuleRef mod, const char *pipeline)
{
    if (!ts_LLVMRunPasses || !ts_LLVMCreatePassBuilderOptions || getenv("VMG_LLVM_LEGACY_PM"))
        return run_passes_legacy(mod, pipeline);
    LLVMPassBuilderOptionsRef opts = ts_LLVMCreatePassBuilderOptions();
    LLVMErrorRef err = ts_LLVMRunPasses(mod, pipeline, NULL, opts);
    ts_LLVMDisposePassBuilderOptions(opts);
    if (!err) return NULL;
    char *msg = ts_LLVMGetErrorMessage(err);
    char *copy = strdup(msg ? msg : "passes failed");
    ts_LLVMDisposeErrorMessage(msg);
    return copy;
}

// Every function defined in the module is inlined into the entry point (NIR translation has no calls): drop
// noinline, add alwaysinline; the "always-inline" pass then runs before the clean-up.
static void force_inlining(LLVMModuleRef mod, LLVMValueRef entry)
{
    if (!ts_LLVMGetEnumAttributeKindForName || !ts_LLVMRemoveEnumAttributeAtIndex || !ts_LLVMCreateEnumAttribute ||
        !ts_LLVMAddAttributeAtIndex || !ts_LLVMGetModuleContext)
        return;
    unsigned noinline = ts_LLVMGetEnumAttributeKindForName("noinline", 8);
    unsigned always = ts_LLVMGetEnumAttributeKindForName("alwaysinline", 12);
    unsigned optnone = ts_LLVMGetEnumAttributeKindForName("optnone", 7);
    LLVMAttributeRef a = ts_LLVMCreateEnumAttribute(ts_LLVMGetModuleContext(mod), always, 0);
    for (LLVMValueRef f = ts_LLVMGetFirstFunction(mod); f; f = ts_LLVMGetNextFunction(f)) {
        if (f == entry || ts_LLVMIsDeclaration(f)) continue;
        ts_LLVMRemoveEnumAttributeAtIndex(f, ~0u, noinline);
        ts_LLVMRemoveEnumAttributeAtIndex(f, ~0u, optnone);
        ts_LLVMAddAttributeAtIndex(f, ~0u, a);
    }
}

static LLVMValueRef entry_function(LLVMModuleRef mod)
{
    const char *kinds[] = { "air.vertex", "air.fragment", "air.kernel" };
    for (unsigned i = 0; i < 3; i++) {
        if (!ts_LLVMGetNamedMetadataNumOperands(mod, kinds[i])) continue;
        LLVMValueRef node;
        ts_LLVMGetNamedMetadataOperands(mod, kinds[i], &node);
        LLVMValueRef ops[256];
        if (ts_LLVMGetMDNodeNumOperands(node) > 256) return NULL;
        ts_LLVMGetMDNodeOperands(node, ops);
        return ops[0];
    }
    return NULL;
}

static const char kVisibleRef[] = ".MTL_VISIBLE_FN_REF";

// Resolves visible function references (`declare @<name>.MTL_VISIBLE_FN_REF`) with the linked functions' bitcode:
// parsed into the same context, definitions renamed, modules linked, references replaced (then inlined).
static char *link_visible(LLVMContextRef ctx, LLVMModuleRef mod, const vmg_air_input *in)
{
    for (unsigned i = 0; i < in->linked_count; i++) {
        LLVMMemoryBufferRef mb = ts_LLVMCreateMemoryBufferWithMemoryRange(in->linked[i], in->linked_size[i], "linked", 0);
        LLVMModuleRef lm = NULL;
        bool bad = ts_LLVMParseBitcodeInContext2(ctx, mb, &lm) || !lm;
        ts_LLVMDisposeMemoryBuffer(mb);
        if (bad) return vmg_strdup_printf("linked function %s: bitcode parse failed", in->linked_names[i]);
        char newname[64];
        snprintf(newname, sizeof newname, "vmg_linked_%u", i);
        LLVMValueRef def = ts_LLVMGetNamedFunction(lm, in->linked_names[i]);
        if (!def) { ts_LLVMDisposeModule(lm); continue; }
        ts_LLVMSetValueName2(def, newname, strlen(newname));
        if (ts_LLVMLinkModules2(mod, lm)) return vmg_strdup_printf("linking %s failed", in->linked_names[i]);
        char ref[256];
        snprintf(ref, sizeof ref, "%s%s", in->linked_names[i], kVisibleRef);
        LLVMValueRef decl = ts_LLVMGetNamedFunction(mod, ref), target = ts_LLVMGetNamedFunction(mod, newname);
        if (decl && target) {
            ts_LLVMReplaceAllUsesWith(decl, ts_LLVMConstBitCast(target, ts_LLVMTypeOf(decl)));
            ts_LLVMDeleteFunction(decl);
        }
    }
    return NULL;
}

static nir_shader *translate_module(const nir_shader_compiler_options *options, LLVMModuleRef mod, const vmg_air_input *in,
                                    vmg_reflection *refl, struct util_dynarray *pool, char **error)
{
    unsigned nv = ts_LLVMGetNamedMetadataNumOperands(mod, "air.vertex");
    unsigned nf = ts_LLVMGetNamedMetadataNumOperands(mod, "air.fragment");
    unsigned nk = ts_LLVMGetNamedMetadataNumOperands(mod, "air.kernel");
    if (!nv && !nf && !nk) { *error = strdup("not a vertex, fragment or kernel function"); return NULL; }
    T t = {0};
    t.mod = mod;
    t.td = ts_LLVMCreateTargetData(ts_LLVMGetDataLayoutStr(mod));
    t.stage = nv ? MESA_SHADER_VERTEX : nf ? MESA_SHADER_FRAGMENT : MESA_SHADER_COMPUTE;
    t.in = in; t.refl = refl; t.pool = pool;
    memset(refl, 0, sizeof *refl);
    refl->stage = t.stage == MESA_SHADER_VERTEX ? VMG_VERTEX : t.stage == MESA_SHADER_FRAGMENT ? VMG_FRAGMENT : VMG_COMPUTE;
    LLVMValueRef node;
    ts_LLVMGetNamedMetadataOperands(mod, nv ? "air.vertex" : nf ? "air.fragment" : "air.kernel", &node);
    mdops ops;
    md_operands(node, &ops);
    t.fn = ops.n ? ops.ops[0] : NULL;
    if (!t.fn || !ts_LLVMIsAFunction(t.fn)) { *error = strdup("entry point not found"); ts_LLVMDisposeTargetData(t.td); return NULL; }

    // Fast math unless the function says otherwise (no attribute API: Metal's default, fast math).
    t.no_nans = true;
    if (ts_LLVMGetStringAttributeAtIndex && ts_LLVMGetStringAttributeValue) {
        LLVMAttributeRef a = ts_LLVMGetStringAttributeAtIndex(t.fn, ~0u, "no-nans-fp-math", 15);
        unsigned len = 0;
        const char *v = a ? ts_LLVMGetStringAttributeValue(a, &len) : NULL;
        t.no_nans = v && len == 4 && !strncmp(v, "true", 4);
    }
    char *fname = llvm_name(t.fn);
    // VMG_TRACE_AIR=name: the entry point's LLVM IR (after inlining) and its NIR before optimization.
    const char *trace_air = getenv("VMG_TRACE_AIR");
    bool dump = trace_air && fname && !strcmp(trace_air, fname);
    if (dump) { char *txt = ts_LLVMPrintValueToString(t.fn); fprintf(stderr, "%s\n", txt); ts_LLVMDisposeMessage(txt); }
    t.b = nir_builder_init_simple_shader(t.stage, options, "%s", fname ? fname : "air");
    free(fname);
    t.s = t.b.shader;
    t.impl = t.b.impl;
    t.impl->structured = false;
    t.mem = ralloc_context(NULL);
    t.vals = _mesa_pointer_hash_table_create(t.mem);
    t.blocks = _mesa_pointer_hash_table_create(t.mem);
    t.phis = _mesa_pointer_hash_table_create(t.mem);
    t.globals = _mesa_pointer_hash_table_create(t.mem);
    if (t.stage == MESA_SHADER_FRAGMENT) {
        t.s->info.fs.origin_upper_left = true;   // Metal: row 0 on top
        t.s->info.fs.pixel_center_integer = false;
    }
    if (t.stage == MESA_SHADER_COMPUTE) t.s->info.workgroup_size_variable = true;

    bool ok = declare_inputs(&t, ops.n > 2 ? ops.ops[2] : NULL) && declare_outputs(&t, ops.n > 1 ? ops.ops[1] : NULL) &&
              emit_function(&t);
    nir_shader *s = t.s;
    if (ok) {
        s->scratch_size = t.scratch;
        s->info.shared_size = t.shared;
        refl->static_shared = t.shared;
        // Sysval SSBO + Metal buffers.
        s->info.num_ssbos = VMG_MAX_BUFFERS;
        s->info.num_ubos = 2;
        s->info.num_textures = 0;
        for (unsigned i = 0; i < VMG_MAX_TEXTURES; i++) if (refl->textures_used & (1u << i)) s->info.num_textures = i + 1;
        s->info.num_images = 0;
        for (unsigned i = 0; i < VMG_MAX_TEXTURES; i++) if (refl->textures_written & (1u << i)) s->info.num_images = i + 1;

        nir_sort_unstructured_blocks(t.impl);
        nir_validate_shader(s, "after AIR translation");
        if (dump) nir_print_shader(s, stderr);
        NIR_PASS(_, s, nir_lower_goto_ifs);
        if (t.stage == MESA_SHADER_COMPUTE) {
            // dispatchThreads: threads beyond threads_per_grid (system values) do not exist in Metal. The guard is
            // a no-op for dispatchThreadgroups, whose grid is whole groups.
            nir_builder gb = nir_builder_at(nir_before_impl(nir_shader_get_entrypoint(s)));
            t.b = gb;
            nir_def *gid = nir_load_global_invocation_id(&t.b, 32);
            nir_def *grid = sysval_word(&t, 32, 3);
            nir_push_if(&t.b, nir_bany(&t.b, nir_uge(&t.b, gid, grid)));
            nir_jump(&t.b, nir_jump_return);
            nir_pop_if(&t.b, NULL);
            NIR_PASS(_, s, nir_lower_returns);
        }
        NIR_PASS(_, s, nir_lower_vars_to_ssa);
        NIR_PASS(_, s, nir_lower_global_vars_to_local);
        NIR_PASS(_, s, nir_lower_vars_to_ssa);
        NIR_PASS(_, s, nir_lower_system_values);
        nir_lower_compute_system_values_options csv = {0};
        NIR_PASS(_, s, nir_lower_compute_system_values, &csv);
        bool progress;
        do {
            progress = false;
            NIR_PASS(progress, s, nir_opt_copy_prop);
            NIR_PASS(progress, s, nir_opt_dce);
            NIR_PASS(progress, s, nir_opt_cse);
            NIR_PASS(progress, s, nir_opt_constant_folding);
            NIR_PASS(progress, s, nir_opt_algebraic);
            NIR_PASS(progress, s, nir_opt_dead_cf);
            NIR_PASS(progress, s, nir_opt_if, 0);
            NIR_PASS(progress, s, nir_opt_remove_phis);
        } while (progress);
        NIR_PASS(_, s, nir_remove_dead_variables, nir_var_function_temp | nir_var_shader_temp, NULL);
        nir_shader_gather_info(s, nir_shader_get_entrypoint(s));
        // gather_info recomputes these from variables; keep the slots the translation used.
        for (unsigned i = 0; i < VMG_MAX_TEXTURES; i++) {
            if (refl->textures_used & (1u << i)) BITSET_SET(s->info.textures_used, i);
            if (refl->textures_written & (1u << i)) BITSET_SET(s->info.images_used, i);
        }
        for (unsigned i = 0; i < 32; i++) {
            if (refl->samplers_used & (1u << i)) BITSET_SET(s->info.samplers_used, i);
            if (i >= VMG_CONSTEXPR_SAMPLER_BASE && i - VMG_CONSTEXPR_SAMPLER_BASE < refl->constexpr_samplers)
                BITSET_SET(s->info.samplers_used, i);
        }
        s->info.num_ssbos = VMG_MAX_BUFFERS;
        s->info.num_ubos = 2;
        if (t.stage == MESA_SHADER_COMPUTE) s->info.workgroup_size_variable = true;
        if (t.stage == MESA_SHADER_FRAGMENT) { s->info.fs.origin_upper_left = true; s->info.fs.pixel_center_integer = false; }
    } else {
        *error = t.error ? t.error : strdup("translation failed");
        t.error = NULL;
        ralloc_free(s);
        s = NULL;
    }
    free(t.error);
    ralloc_free(t.mem);
    ts_LLVMDisposeTargetData(t.td);
    return s;
}

nir_shader *vmg_air_translate(const nir_shader_compiler_options *options, const vmg_air_input *in, vmg_reflection *refl,
                              struct util_dynarray *pool, char **error)
{
    g_half32 = in->half32;
    const char *loadError;
    *error = NULL;
    if (!vmg_llvm_load(&loadError)) { *error = strdup(loadError); return NULL; }
    glsl_type_singleton_init_or_ref();
    LLVMContextRef ctx = ts_LLVMContextCreate();
    LLVMMemoryBufferRef mb = ts_LLVMCreateMemoryBufferWithMemoryRange(in->bitcode, in->bitcode_size, "air", 0);
    LLVMModuleRef mod = NULL;
    bool bad = ts_LLVMParseBitcodeInContext2(ctx, mb, &mod) || !mod;
    ts_LLVMDisposeMemoryBuffer(mb);
    nir_shader *s = NULL;
    if (bad) *error = strdup("bitcode parse failed");
    else {
        char *err = in->linked_count ? link_visible(ctx, mod, in) : NULL;
        if (!err) {
            force_inlining(mod, entry_function(mod));
            err = run_passes(mod, "always-inline");
        }
        if (!err) err = run_passes(mod, kCleanupPasses);
        if (err) *error = err;
        else s = translate_module(options, mod, in, refl, pool, error);
        ts_LLVMDisposeModule(mod);
    }
    ts_LLVMContextDispose(ctx);
    glsl_type_singleton_decref();
    return s;
}

// Varying keys written by a vertex function, in metadata order (vmg_air_vertex_outputs, vmg_screen.c, caches it).
char **vmg_air_vertex_outputs_uncached(const void *bitcode, size_t size, unsigned *count, char **error)
{
    const char *loadError;
    *count = 0;
    if (!vmg_llvm_load(&loadError)) { *error = strdup(loadError); return NULL; }
    LLVMContextRef ctx = ts_LLVMContextCreate();
    LLVMMemoryBufferRef mb = ts_LLVMCreateMemoryBufferWithMemoryRange(bitcode, size, "air", 0);
    LLVMModuleRef mod = NULL;
    bool bad = ts_LLVMParseBitcodeInContext2(ctx, mb, &mod) || !mod;
    ts_LLVMDisposeMemoryBuffer(mb);
    char **keys = NULL;
    if (bad) *error = strdup("bitcode parse failed");
    else if (!ts_LLVMGetNamedMetadataNumOperands(mod, "air.vertex")) *error = strdup("not a vertex function");
    else {
        LLVMValueRef node;
        ts_LLVMGetNamedMetadataOperands(mod, "air.vertex", &node);
        mdops ops, outs;
        md_operands(node, &ops);
        md_operands(ops.n > 1 ? ops.ops[1] : NULL, &outs);
        keys = calloc(outs.n + 1, sizeof(char *));
        for (unsigned i = 0; i < outs.n; i++) {
            mdops o;
            md_operands(outs.ops[i], &o);
            unsigned len;
            const char *k;
            if (o.n > 1 && md_is(o.ops[0], "air.vertex_output") && (k = md_string(o.ops[1], &len))) keys[(*count)++] = strndup(k, len);
        }
    }
    if (mod) ts_LLVMDisposeModule(mod);
    ts_LLVMContextDispose(ctx);
    return keys;
}
