// Viva Metal - direct AIR -> Valhall ISA compiler: driver glue.
//
// vmg_isa_compile: AIR (vmg_air_module_load, A1) -> Valhall IR (vi_sel*.c) -> optimization, constants, register
// allocation, flow control, encoding (vi_*.c) -> a program: binary + pan_shader_info + sysvals + varying layout.
// Vertex functions become the three IDVS programs Panfrost expects on v9 (position, position without point size,
// varyings). Gallium gets a "shell" nir_shader (stage and I/O information, no code) named "vmg-isa:<program>";
// the hooks of Mesa patch 0006 (pan_isa_hooks.h) hand Panfrost the precompiled program for it.
#include "vmg_isa.h"
#include "vi_sel.h"
#include "vmg_isa_api.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include "nir.h"
#include "nir_builder.h"
#include "panfrost/compiler/pan_isa_hooks.h"
// struct panfrost_sysvals (gallium/drivers/panfrost/pan_context.h, MAX_SYSVAL_COUNT = 32): pan_context.h pulls in the
// kernel interface headers, so the layout is repeated here.
struct panfrost_sysvals {
   unsigned sysvals[32];
   unsigned sysval_count;
};
#include "panfrost/compiler/bifrost/valhall/disassemble.h"
#include "util/hash_table.h"
#include "util/set.h"

void vi_optimize(vi_shader *s);
void vi_schedule_pressure(vi_shader *s);
void vi_split_vectors(vi_shader *s);
void sel_vs_layout(S *t, LLVMValueRef outputs_md);
bool sel_function(S *t, LLVMValueRef outputs_md, LLVMValueRef inputs_md, vi_block **exit_out);

// ---- Options --------------------------------------------------------------------------------------------------------

void vmg_isa_options_from_env(vmg_isa_options *o)
{
    memset(o, 0, sizeof *o);
    const char *e = getenv("VMG_ISA");
    o->enabled = e && *e && *e != '0';
    e = getenv("VMG_ISA_STRICT");
    o->strict = e && *e && *e != '0';
    o->trace = getenv("VMG_TRACE_ISA");
    char name[32];
    for (unsigned f = 0; f < VMG_ISA_FEATURE_COUNT; f++) {
        snprintf(name, sizeof name, "VMG_ISA_NO_%s", vmg_isa_feature_name[f]);
        e = getenv(name);
        if (e && *e && *e != '0') o->disabled |= 1ull << f;
    }
    // VMG_ISA_ONLY=<ID,...>: only those features (and the infrastructure, A*) stay on the ISA path.
    e = getenv("VMG_ISA_ONLY");
    if (e && *e) {
        uint64_t keep = 0;
        for (unsigned f = 0; f < VMG_ISA_FEATURE_COUNT; f++) {
            const char *n = vmg_isa_feature_name[f];
            size_t len = strlen(n);
            if (n[0] == 'A') { keep |= 1ull << f; continue; }
            for (const char *p = e; (p = strstr(p, n)); p += len)
                if ((p == e || p[-1] == ',' || p[-1] == ' ') && (p[len] == 0 || p[len] == ',' || p[len] == ' ')) { keep |= 1ull << f; break; }
        }
        o->disabled |= ~keep & ((1ull << VMG_ISA_FEATURE_COUNT) - 1);
    }
}

void vmg_isa_options_key(const vmg_isa_options *o, char *buf, size_t size)
{
    snprintf(buf, size, "isa=%d/%llx", o->enabled, (unsigned long long)o->disabled);
}

// ---- Stats ----------------------------------------------------------------------------------------------------------

static pthread_mutex_t g_stats_lock = PTHREAD_MUTEX_INITIALIZER;
static vmg_isa_stats g_stats;

void vmg_isa_get_stats(vmg_isa_stats *out)
{
    pthread_mutex_lock(&g_stats_lock);
    *out = g_stats;
    pthread_mutex_unlock(&g_stats_lock);
}

void vmg_isa_counters(uint64_t *functions, uint64_t *fallbacks, uint64_t *compile_us, char *last_fallback, size_t size)
{
    pthread_mutex_lock(&g_stats_lock);
    *functions = g_stats.functions; *fallbacks = g_stats.fallbacks; *compile_us = g_stats.compile_us;
    if (size) snprintf(last_fallback, size, "%s", g_stats.last_fallback);
    pthread_mutex_unlock(&g_stats_lock);
}

void vmg_isa_note(bool ok, const char *fn, const char *why, uint64_t us, bool cached)
{
    pthread_mutex_lock(&g_stats_lock);
    if (ok) g_stats.functions++;
    else {
        g_stats.fallbacks++;
        snprintf(g_stats.last_fallback, sizeof g_stats.last_fallback, "%s: %s", fn ? fn : "?", why ? why : "?");
    }
    g_stats.compile_us += us;
    if (cached) g_stats.cache_hits++;
    pthread_mutex_unlock(&g_stats_lock);
}

// ---- Program --------------------------------------------------------------------------------------------------------

typedef struct vmg_isa_program vmg_isa_program;
struct vmg_isa_program {
    int stage;
    uint32_t vs_noperspective;    // vertex: the noperspective mask this binary was built for
    vmg_isa_program *variants;    // vertex: binaries for other noperspective masks (Panfrost's key), a list
    vmg_isa_program *next;
    void *input;                  // vertex: deep copy of the input (variants are compiled at draw time)
    vmg_isa_options opt;
    char name[64];
    struct util_dynarray binary;
    struct pan_shader_info info;
    struct panfrost_sysvals sysvals;
    struct pan_varying_layout vs_layout;
    uint32_t fs_noperspective;
    uint64_t features;            // features used (stats, tests)
};

static uint64_t now_us(void) { struct timeval tv; gettimeofday(&tv, NULL); return (uint64_t)tv.tv_sec * 1000000 + (uint64_t)tv.tv_usec; }

static LLVMValueRef entry_md(LLVMModuleRef mod, int *stage)
{
    const char *kinds[] = { "air.vertex", "air.fragment", "air.kernel" };
    const int stages[] = { MESA_SHADER_VERTEX, MESA_SHADER_FRAGMENT, MESA_SHADER_COMPUTE };
    for (unsigned i = 0; i < 3; i++) {
        if (!ts_LLVMGetNamedMetadataNumOperands(mod, kinds[i])) continue;
        LLVMValueRef node;
        ts_LLVMGetNamedMetadataOperands(mod, kinds[i], &node);
        *stage = stages[i];
        return node;
    }
    return NULL;
}

static bool want_trace(const vmg_isa_options *o, const char *fn)
{
    if (o->disabled >> VMG_ISA_A10 & 1) return false;   // diagnostics off
    return o->trace && *o->trace && (!strcmp(o->trace, "1") || (fn && !strcmp(o->trace, fn)));
}

// Physical registers read before being written in the program (preloads), r48-r63 only matter to the driver.
static uint64_t preload_mask(vi_shader *s)
{
    uint64_t written = 0, preload = 0;
    vi_foreach_block(s, blk) vi_foreach_instr(blk, I) {
        vi_ref *r[5] = { &I->src[0], &I->src[1], &I->src[2], &I->src[3], &I->sr };
        for (unsigned k = 0; k < 5; k++) {
            if (r[k]->kind != VI_REG) continue;
            unsigned n = r[k]->count ? r[k]->count : 1;
            for (unsigned w = 0; w < n; w++) if (!(written >> (r[k]->value + w) & 1)) preload |= 1ull << (r[k]->value + w);
        }
        vi_ref *w[2] = { &I->dest, &I->sw };
        for (unsigned k = 0; k < 2; k++) {
            if (w[k]->kind != VI_REG) continue;
            unsigned n = w[k]->count ? w[k]->count : 1;
            for (unsigned q = 0; q < n; q++) written |= 1ull << (w[k]->value + q);
        }
        // only the straight-line start matters; stop at the first branch
        if (I->target) return preload & 0xffff000000000000ull;
    }
    return preload & 0xffff000000000000ull;
}

typedef struct {
    S t;
    vi_shader *s;
    LLVMContextRef ctx;
    LLVMModuleRef mod;
} unit;

// One program (one IDVS part for vertex functions) from the module.
static bool compile_one(const vmg_air_input *in, const vmg_isa_options *opt, LLVMModuleRef mod, int idvs, uint32_t attached,
                        vmg_reflection *refl, struct util_dynarray *pool, struct pan_fau_layout *fau, struct util_dynarray *bin,
                        S *out_state, char **error)
{
    int stage;
    LLVMValueRef node = entry_md(mod, &stage);
    if (!node) { *error = strdup("not a vertex, fragment or kernel function"); return false; }
    LLVMValueRef ops[64];
    unsigned nops = ts_LLVMGetMDNodeNumOperands(node);
    if (nops > 64) nops = 64;
    LLVMValueRef tmp[256];
    ts_LLVMGetMDNodeOperands(node, tmp);
    memcpy(ops, tmp, nops * sizeof(LLVMValueRef));
    S *t = out_state;
    memset(t, 0, sizeof *t);
    t->mem = ralloc_context(NULL);
    t->s = vi_shader_create(stage);
    t->s->fau = fau;
    t->b.s = t->s;
    t->mod = mod;
    t->td = ts_LLVMCreateTargetData(ts_LLVMGetDataLayoutStr(mod));
    t->fn = nops ? ops[0] : NULL;
    t->stage = stage;
    t->in = in; t->opt = opt; t->refl = refl; t->pool = pool;
    t->fau = fau;
    t->idvs = idvs;
    t->attached = attached;
    t->fs_noperspective = stage == MESA_SHADER_VERTEX ? opt->vs_noperspective : 0;
    static int no_push = -1;
    if (no_push < 0) no_push = getenv("VMG_NO_PUSH") != NULL;
    t->push = !no_push;
    t->vals = _mesa_pointer_hash_table_create(t->mem);
    t->blocks = _mesa_pointer_hash_table_create(t->mem);
    t->phis = _mesa_pointer_hash_table_create(t->mem);
    t->globals = _mesa_pointer_hash_table_create(t->mem);
    t->no_nans = true;
    if (ts_LLVMGetStringAttributeAtIndex && ts_LLVMGetStringAttributeValue && t->fn) {
        LLVMAttributeRef a = ts_LLVMGetStringAttributeAtIndex(t->fn, ~0u, "no-nans-fp-math", 15);
        unsigned len = 0;
        const char *v = a ? ts_LLVMGetStringAttributeValue(a, &len) : NULL;
        t->no_nans = v && len == 4 && !strncmp(v, "true", 4);
    }
    bool ok = t->fn && ts_LLVMIsAFunction(t->fn);
    if (!ok) t->error = strdup("entry point not found");
    if (ok) ok = sel_use(t, VMG_ISA_A1) && sel_use(t, VMG_ISA_A8);
    if (ok && stage == MESA_SHADER_VERTEX) sel_vs_layout(t, nops > 1 ? ops[1] : NULL);
    vi_block *exit = NULL;
    if (ok) ok = sel_function(t, nops > 1 ? ops[1] : NULL, nops > 2 ? ops[2] : NULL, &exit);
    if (ok) ok = sel_io_finish(t);
    if (ok) ok = sel_use(t, VMG_ISA_A6) && sel_use(t, VMG_ISA_A3) && sel_use(t, VMG_ISA_A4) && sel_use(t, VMG_ISA_A5) && sel_use(t, VMG_ISA_A7);
    char *fname = t->fn ? sel_name(t->fn) : NULL;
    bool trace = want_trace(opt, fname);
    if (ok) {
        vi_optimize(t->s);
        if (trace) { fprintf(stderr, "vmg-isa: %s (stage %d, idvs %d) selected:\n", fname ? fname : "?", stage, idvs); vi_print(t->s, stderr); }
        vi_lower_constants(t->s);
        vi_split_vectors(t->s);
        vi_schedule_pressure(t->s);
        t->s->tls_size = (t->scratch + 15) & ~15u;
        if (!vi_register_allocate(t->s)) { ok = false; t->error = t->s->error ? strdup(t->s->error) : strdup("register allocation"); }
    }
    if (ok) {
        vi_insert_flow(t->s, stage == MESA_SHADER_FRAGMENT);
        unsigned start = bin->size;
        if (!vi_pack(t->s, bin)) { ok = false; t->error = strdup(t->s->error ? t->s->error : "encoding"); }
        else if (trace) {
            fprintf(stderr, "vmg-isa: %s: %u bytes, %u work registers (%u live at most), %u spills\n", fname ? fname : "?", bin->size - start, t->s->work_regs, t->s->max_live, t->s->spills);
            disassemble_valhall(stderr, (uint8_t *)bin->data + start, bin->size - start, false);
        }
    }
    if (!ok) {
        *error = t->error ? t->error : strdup("compilation failed");
        t->error = NULL;
    }
    free(fname);
    ts_LLVMDisposeTargetData(t->td);
    return ok;
}

static void free_state(S *t)
{
    vi_shader_free(t->s);
    ralloc_free(t->mem);
    free(t->error);
}

static void fill_info(vmg_isa_program *p, S *t, uint64_t gpu_id)
{
    struct pan_shader_info *info = &p->info;
    (void)gpu_id;
    info->stage = (mesa_shader_stage)t->stage;
    info->work_reg_count = MAX2(info->work_reg_count, t->s->work_regs);
    info->tls_size = MAX2(info->tls_size, (t->s->tls_size + 15) & ~15u);
    info->outputs_written = t->info.outputs_written;
    info->writes_global = t->info.writes_global;
    info->ubo_count = 3;
    info->ubo_mask |= t->ubo_mask;
    info->texture_count = MAX2(info->texture_count, t->info.texture_count);
    info->sampler_count = MAX2(info->sampler_count, t->info.sampler_count);
    info->images_used |= t->info.images_used;
    info->attribute_count = 0;
    p->features |= t->used;
    switch (t->stage) {
    case MESA_SHADER_VERTEX:
        info->attributes_read = t->info.attributes_read;
        info->attributes_read_count = util_bitcount(t->info.attributes_read);
        info->attribute_count = info->attributes_read_count;
        info->vs.writes_point_size = t->info.writes_psiz;
        info->vs.idvs = true;
        info->varyings.formats = t->vs_layout;
        break;
    case MESA_SHADER_FRAGMENT:
        info->fs.writes_depth = t->info.writes_depth;
        info->fs.writes_coverage = t->info.writes_coverage;
        info->fs.outputs_read = t->info.outputs_read;
        info->fs.sample_shading = t->info.sample_shading;
        info->fs.can_discard = t->info.discard;
        info->fs.sidefx = t->info.writes_global || t->info.discard;
        info->fs.can_early_z = !info->fs.sidefx && !info->fs.writes_depth && !info->fs.writes_coverage;
        info->fs.can_fpk = !info->fs.writes_depth && !info->fs.writes_coverage && !info->fs.can_discard && !info->fs.outputs_read;
        info->fs.reads_frag_coord = t->info.reads_frag_coord;
        info->fs.reads_face = t->info.reads_face;
        info->fs.reads_point_coord = t->info.reads_point_coord;
        info->contains_barrier = t->info.helpers;
        info->preload |= (1ull << 60) | (1ull << 61);
        for (unsigned r = 0; r < 8; r++) info->bifrost.blend[r].type = t->info.blend_type[r];
        info->bifrost.blend_src1_type = t->info.blend_src1_type;
        info->bifrost.uses_ld_var = t->info.uses_ld_var;
        info->bifrost.uses_flat_shading = t->info.flat;
        info->varyings.formats = t->fs_formats;
        info->varyings.formats.known |= PAN_VARYING_FORMAT_KNOWN;
        info->varyings.noperspective = t->fs_noperspective;
        break;
    default:
        info->wls_size = t->shared;
        info->contains_barrier = t->info.barrier;
        info->cs.allow_merging_workgroups = !t->shared && !t->info.barrier && !t->info.subgroups && !t->refl->dynamic_shared_slots;
        break;
    }
    p->sysvals.sysval_count = t->nsysvals;
    memcpy(p->sysvals.sysvals, t->sysvals, t->nsysvals * sizeof(unsigned));
}

static void pad_program(struct util_dynarray *bin, unsigned start)
{
    (void)start;
    // vi_pack already pads each non-empty program to ALIGN(size + 16, 128)
}

vmg_isa_program *vmg_isa_compile(const vmg_air_input *in, const vmg_isa_options *opt, uint64_t gpu_id, uint32_t attached,
                                 vmg_reflection *refl, struct util_dynarray *pool, char **error)
{
    uint64_t t0 = now_us();
    *error = NULL;
    LLVMContextRef ctx;
    LLVMModuleRef mod;
    if (!vmg_air_module_load(in, &ctx, &mod, error)) return NULL;
    int stage;
    if (!entry_md(mod, &stage)) { *error = strdup("not a vertex, fragment or kernel function"); vmg_air_module_free(ctx, mod); return NULL; }
    vmg_isa_program *p = calloc(1, sizeof *p);
    util_dynarray_init(&p->binary, NULL);
    p->stage = stage;
    p->opt = *opt;
    p->vs_noperspective = opt->vs_noperspective;
    p->info.fau.max = PAN_MAX_PUSH;
    size_t pool_size = pool ? pool->size : 0;
    vmg_reflection r0;
    memset(&r0, 0, sizeof r0);
    r0.stage = stage == MESA_SHADER_VERTEX ? VMG_VERTEX : stage == MESA_SHADER_FRAGMENT ? VMG_FRAGMENT : VMG_COMPUTE;
    bool ok = true;
    char *fname = NULL;
    if (stage != MESA_SHADER_VERTEX) {
        S t;
        *refl = r0;
        ok = compile_one(in, opt, mod, 0, attached, refl, pool, &p->info.fau, &p->binary, &t, error);
        if (ok) {
            p->info.preload = preload_mask(t.s);
            fill_info(p, &t, gpu_id);
            p->fs_noperspective = t.fs_noperspective;
            if (stage == MESA_SHADER_COMPUTE) p->info.wls_size = t.shared;
            refl->static_shared = t.shared;
            fname = t.fn ? sel_name(t.fn) : NULL;
        }
        if (t.s) free_state(&t);
    } else {
        // IDVS: position (with point size), position without point size, varyings. One FAU layout and sysval list
        // for all three (they share the draw's uniforms): later parts reuse the words the first ones pushed.
        S t;
        *refl = r0;
        ok = compile_one(in, opt, mod, 1, ~0u, refl, pool, &p->info.fau, &p->binary, &t, error);
        bool psiz = ok && t.info.writes_psiz;
        unsigned nsys = 0, sys[32];
        if (ok) {
            p->info.preload = preload_mask(t.s);
            fill_info(p, &t, gpu_id);
            p->vs_layout = t.vs_layout;
            nsys = t.nsysvals; memcpy(sys, t.sysvals, sizeof sys);
            fname = t.fn ? sel_name(t.fn) : NULL;
        }
        if (t.s) free_state(&t);
        struct { int mode; unsigned *offset; } parts[2] = { { 2, &p->info.vs.no_psiz_offset }, { 3, &p->info.vs.secondary_offset } };
        for (unsigned k = 0; k < 2 && ok; k++) {
            if (parts[k].mode == 2 && !psiz) continue;
            unsigned start = p->binary.size;
            vmg_reflection rk = *refl;
            if (pool) pool->size = pool_size;   // the constant pool is rebuilt identically
            S u;
            ok = compile_one(in, opt, mod, parts[k].mode, ~0u, &rk, pool, &p->info.fau, &p->binary, &u, error);
            if (ok) {
                // sysvals must agree with the first part's slots: the same order of requests makes them identical
                for (unsigned q = 0; q < u.nsysvals && ok; q++)
                    if (q >= nsys || u.sysvals[q] != sys[q]) {
                        if (q >= nsys && nsys < 32) { sys[nsys++] = u.sysvals[q]; continue; }
                        ok = false; *error = strdup("IDVS parts disagree on sysvals");
                    }
                *parts[k].offset = start;
                if (parts[k].mode == 3) {
                    p->info.vs.secondary_enable = p->binary.size > start;
                    p->info.vs.secondary_preload = preload_mask(u.s);
                    p->info.vs.secondary_work_reg_count = u.s->work_regs;
                    p->info.tls_size = MAX2(p->info.tls_size, (u.s->tls_size + 15) & ~15u);
                    p->info.ubo_mask |= u.ubo_mask;
                    p->info.texture_count = MAX2(p->info.texture_count, u.info.texture_count);
                    p->info.sampler_count = MAX2(p->info.sampler_count, u.info.sampler_count);
                    p->features |= u.used;
                } else p->info.work_reg_count = MAX2(p->info.work_reg_count, u.s->work_regs);
            }
            if (u.s) free_state(&u);
        }
        if (ok) {
            p->sysvals.sysval_count = nsys;
            memcpy(p->sysvals.sysvals, sys, nsys * sizeof(unsigned));
            if (!p->info.vs.secondary_enable) p->info.vs.secondary_offset = 0;
        }
    }
    pad_program(&p->binary, 0);
    vmg_air_module_free(ctx, mod);
    snprintf(p->name, sizeof p->name, "%s", fname ? fname : "?");
    uint64_t us = now_us() - t0;
    vmg_isa_note(ok, fname, *error, us, false);
    free(fname);
    if (!ok) {
        if (pool) pool->size = pool_size;
        util_dynarray_fini(&p->binary);
        free(p);
        return NULL;
    }
    return p;
}

// ---- Shell NIR and hooks ----------------------------------------------------------------------------------------------

static pthread_mutex_t g_live_lock = PTHREAD_MUTEX_INITIALIZER;
static struct set *g_live;

static void live_add(vmg_isa_program *p)
{
    pthread_mutex_lock(&g_live_lock);
    if (!g_live) g_live = _mesa_pointer_set_create(NULL);
    _mesa_set_add(g_live, p);
    pthread_mutex_unlock(&g_live_lock);
}

static bool live_has(vmg_isa_program *p)
{
    pthread_mutex_lock(&g_live_lock);
    bool r = g_live && _mesa_set_search(g_live, p);
    pthread_mutex_unlock(&g_live_lock);
    return r;
}

void vmg_isa_program_free(vmg_isa_program *p)
{
    if (!p) return;
    for (vmg_isa_program *v = p->variants, *n; v; v = n) { n = v->next; util_dynarray_fini(&v->binary); free(v); }
    pthread_mutex_lock(&g_live_lock);
    if (g_live) _mesa_set_remove_key(g_live, p);
    pthread_mutex_unlock(&g_live_lock);
    util_dynarray_fini(&p->binary);
    free(p);
}

static vmg_isa_program *program_of(const nir_shader *nir)
{
    const char *n = nir ? nir->info.name : NULL;
    if (!n || strncmp(n, "vmg-isa:", 8)) return NULL;
    vmg_isa_program *p = (vmg_isa_program *)(uintptr_t)strtoull(n + 8, NULL, 16);
    return live_has(p) ? p : NULL;
}

static bool hook_owns(const nir_shader *nir) { return program_of(nir) != NULL; }

static void hook_create_layout(const nir_shader *nir, uint64_t gpu_id, struct pan_varying_layout *vs_layout, uint32_t *fs_noperspective)
{
    (void)gpu_id;
    vmg_isa_program *p = program_of(nir);
    if (!p) return;
    if (p->stage == MESA_SHADER_VERTEX) *vs_layout = p->vs_layout;
    if (p->stage == MESA_SHADER_FRAGMENT) *fs_noperspective = p->fs_noperspective;
}

static vmg_isa_input_hook g_input_hook;   // vmg_screen.c: rebuilds a vertex variant from the shader's input

void vmg_isa_set_input_hook(vmg_isa_input_hook h) { g_input_hook = h; }
void vmg_isa_program_set_input(vmg_isa_program *p, void *input) { p->input = input; }

static nir_shader *hook_compile(const nir_shader *nir, const struct pan_isa_key *key, struct util_dynarray *binary,
                                struct pan_shader_info *info, struct panfrost_sysvals *sysvals)
{
    vmg_isa_program *p = program_of(nir);
    if (!p) return nir_shader_clone(NULL, nir);   // cannot happen (owns() checked); Mesa compiles the shell
    if (p->stage == MESA_SHADER_VERTEX && key->vs_noperspective_varyings != p->vs_noperspective && p->input && g_input_hook) {
        // A8: the fragment shader reads some varyings noperspective: the vertex shader multiplies them by w
        vmg_isa_program *v = p->variants;
        while (v && v->vs_noperspective != key->vs_noperspective_varyings) v = v->next;
        if (!v) {
            vmg_isa_options o = p->opt;
            o.vs_noperspective = key->vs_noperspective_varyings;
            o.trace = NULL;
            v = g_input_hook(p->input, &o);
            if (v) { v->next = p->variants; p->variants = v; }
        }
        if (v) p = v;
    }
    if (p->binary.size) util_dynarray_append_array(binary, uint8_t, p->binary.data, p->binary.size);
    *info = p->info;
    *sysvals = p->sysvals;
    return NULL;
}

static const struct pan_isa_hooks g_hooks = { hook_owns, hook_create_layout, hook_compile };

void vmg_isa_install_hooks(void) { pan_isa_hooks = &g_hooks; }

// The nir_shader Gallium sees: stage, name (the program), the I/O bits Panfrost reads at draw time.
nir_shader *vmg_isa_shell(vmg_isa_program *p, const nir_shader_compiler_options *options, const vmg_reflection *refl)
{
    nir_shader *s = nir_shader_create(NULL, (mesa_shader_stage)p->stage, options);
    nir_function *fn = nir_function_create(s, "main");
    fn->is_entrypoint = true;
    nir_function_impl_create(fn);
    char name[64];
    snprintf(name, sizeof name, "vmg-isa:%llx", (unsigned long long)(uintptr_t)p);
    s->info.name = ralloc_strdup(s, name);
    s->info.label = ralloc_strdup(s, p->name);
    s->info.separate_shader = true;
    s->info.outputs_written = p->info.outputs_written;
    s->info.num_ubos = 2;
    s->info.num_ssbos = VMG_MAX_BUFFERS;
    s->info.first_ubo_is_default_ubo = true;
    if (p->stage == MESA_SHADER_VERTEX) s->info.inputs_read = (uint64_t)refl->vertex_inputs << VERT_ATTRIB_GENERIC0;
    if (p->stage == MESA_SHADER_FRAGMENT) {
        s->info.fs.origin_upper_left = true;
        s->info.outputs_read = p->info.fs.outputs_read;
    }
    if (p->stage == MESA_SHADER_COMPUTE) {
        s->info.workgroup_size_variable = true;
        s->info.shared_size = p->info.wls_size;
    }
    for (unsigned i = 0; i < p->info.texture_count && i < 128; i++) BITSET_SET(s->info.textures_used, i);
    for (unsigned i = 0; i < p->info.sampler_count && i < 32; i++) BITSET_SET(s->info.samplers_used, i);
    for (unsigned i = 0; i < 64; i++) if (p->info.images_used >> i & 1) BITSET_SET(s->info.images_used, i);
    live_add(p);
    return s;
}

const char *vmg_isa_program_name(const vmg_isa_program *p) { return p->name; }
int vmg_isa_program_stage(const vmg_isa_program *p) { return p->stage; }
uint64_t vmg_isa_program_features(const vmg_isa_program *p) { return p->features; }
const void *vmg_isa_program_binary(const vmg_isa_program *p, size_t *size) { *size = p->binary.size; return p->binary.data; }
const struct pan_shader_info *vmg_isa_program_info(const vmg_isa_program *p) { return &p->info; }

// Serialized form for the translation cache (A9): header, binary.
typedef struct {
    uint32_t magic, stage, binary_size, fs_noperspective;
    uint64_t features;
    char name[64];
    struct pan_shader_info info;
    struct panfrost_sysvals sysvals;
    struct pan_varying_layout vs_layout;
} cached_program;

void *vmg_isa_program_serialize(const vmg_isa_program *p, size_t *size)
{
    *size = sizeof(cached_program) + p->binary.size;
    uint8_t *buf = calloc(1, *size);
    cached_program *h = (cached_program *)buf;
    h->magic = 0x56495341;   // VISA
    h->stage = (uint32_t)p->stage; h->binary_size = p->binary.size; h->fs_noperspective = p->fs_noperspective;
    h->features = p->features;
    memcpy(h->name, p->name, sizeof h->name);
    h->info = p->info; h->sysvals = p->sysvals; h->vs_layout = p->vs_layout;
    if (p->binary.size) memcpy(buf + sizeof *h, p->binary.data, p->binary.size);
    return buf;
}

vmg_isa_program *vmg_isa_program_deserialize(const void *data, size_t size)
{
    const cached_program *h = data;
    if (size < sizeof *h || h->magic != 0x56495341 || size != sizeof *h + h->binary_size) return NULL;
    vmg_isa_program *p = calloc(1, sizeof *p);
    util_dynarray_init(&p->binary, NULL);
    p->stage = (int)h->stage; p->fs_noperspective = h->fs_noperspective; p->features = h->features;
    memcpy(p->name, h->name, sizeof p->name);
    p->info = h->info; p->sysvals = h->sysvals; p->vs_layout = h->vs_layout;
    if (h->binary_size) util_dynarray_append_array(&p->binary, uint8_t, (const uint8_t *)data + sizeof *h, h->binary_size);
    return p;
}
