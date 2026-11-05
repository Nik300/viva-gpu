// Core passes of the ISA compiler on a hand-built shader: RA, flow, packing, then Mesa's Valhall disassembler.
#include "vi.h"
#include <stdlib.h>
#include "panfrost/compiler/bifrost/valhall/disassemble.h"

int main(void)
{
    vi_shader *s = vi_shader_create(5 /* compute */);
    vi_block *b0 = vi_block_create(s), *b1 = vi_block_create(s), *b2 = vi_block_create(s);
    vi_block_add_succ(b0, b1); vi_block_add_succ(b0, b2); vi_block_add_succ(b1, b2);
    vi_builder b = { s, b0, NULL };
    uint32_t v0 = vi_new_vreg(s, 1), v1 = vi_new_vreg(s, 1), v2 = vi_new_vreg(s, 1), addr = vi_new_vreg(s, 2);
    vi_instr *I = vi_emit(&b, VA_MOV_I32); I->dest = vi_vreg(v0, 0, 1); I->src[0] = vi_reg(60);
    I = vi_emit(&b, VA_FADD_F32); I->dest = vi_vreg(v1, 0, 1); I->src[0] = vi_vreg(v0, 0, 1); I->src[1] = vi_imm(0x3f800000);
    I = vi_emit(&b, VA_FADD_F32); I->dest = vi_vreg(v2, 0, 1); I->src[0] = vi_vreg(v1, 0, 1); I->src[1] = vi_imm(0x40200000);
    I = vi_emit(&b, VA_MOV_I32); I->dest = vi_vreg(addr, 0, 1); I->src[0] = vi_fau(0);
    I = vi_emit(&b, VA_MOV_I32); I->dest = vi_vreg(addr, 1, 1); I->src[0] = vi_fau(1);
    I = vi_emit(&b, VA_BRANCH); I->src[0] = vi_vreg(v0, 0, 1); I->target = b2; vi_set(I, VAF_not, 1);
    b.block = b1;
    I = vi_emit(&b, VA_STORE_I32); I->sr = vi_vreg(v2, 0, 1); I->src[0] = vi_vreg(addr, 0, 2); vi_set(I, VAF_offset, 0); I->memory = true;
    b.block = b2;
    I = vi_emit(&b, VA_STORE_I32); I->sr = vi_vreg(v1, 0, 1); I->src[0] = vi_vreg(addr, 0, 2); vi_set(I, VAF_offset, 4); I->memory = true;
    vi_lower_constants(s);
    if (!vi_register_allocate(s)) { printf("RA: %s\n", s->error); return 1; }
    vi_insert_flow(s, false);
    vi_print(s, stdout);
    struct util_dynarray bin; util_dynarray_init(&bin, NULL);
    if (!vi_pack(s, &bin)) { printf("pack: %s\n", s->error); return 1; }
    disassemble_valhall(stdout, bin.data, bin.size, false);
    return 0;
}
