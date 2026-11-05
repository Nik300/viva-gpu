// Viva Metal - direct AIR -> Valhall ISA compiler: interface for vmg_screen.c (programs, shells, cache, hooks).
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "vmg_isa.h"

struct vmg_isa_program;
struct util_dynarray;
struct nir_shader;
struct nir_shader_compiler_options;
struct pan_shader_info;

// AIR -> program (binary, pan_shader_info, sysvals, varying layout). NULL + *error when the function needs a
// feature the ISA path lacks or that is disabled. attached: fragment render targets with an attachment (B7).
struct vmg_isa_program *vmg_isa_compile(const vmg_air_input *in, const vmg_isa_options *opt, uint64_t gpu_id, uint32_t attached,
                                        vmg_reflection *refl, struct util_dynarray *pool, char **error);
void vmg_isa_program_free(struct vmg_isa_program *p);
// The nir_shader handed to Gallium for the program (no code); Mesa patch 0006's hooks resolve it to the program.
struct nir_shader *vmg_isa_shell(struct vmg_isa_program *p, const struct nir_shader_compiler_options *options, const vmg_reflection *refl);
void vmg_isa_install_hooks(void);
const char *vmg_isa_program_name(const struct vmg_isa_program *p);
int vmg_isa_program_stage(const struct vmg_isa_program *p);
uint64_t vmg_isa_program_features(const struct vmg_isa_program *p);
const void *vmg_isa_program_binary(const struct vmg_isa_program *p, size_t *size);
const struct pan_shader_info *vmg_isa_program_info(const struct vmg_isa_program *p);
void *vmg_isa_program_serialize(const struct vmg_isa_program *p, size_t *size);
struct vmg_isa_program *vmg_isa_program_deserialize(const void *data, size_t size);
void vmg_isa_note(bool ok, const char *fn, const char *why, uint64_t us, bool cached);
// Vertex variants by Panfrost's key (noperspective varyings of the linked fragment shader): the program keeps its
// input (opaque, owned by vmg_screen.c) and the hook compiles a variant from it.
typedef struct vmg_isa_program *(*vmg_isa_input_hook)(void *input, const vmg_isa_options *opt);
void vmg_isa_set_input_hook(vmg_isa_input_hook h);
void vmg_isa_program_set_input(struct vmg_isa_program *p, void *input);
