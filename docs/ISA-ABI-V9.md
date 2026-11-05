# Valhall v9 (Mali-G57) shader ABI for the Gallium Panfrost JM driver

What a compiler that goes straight from AIR to Valhall machine code has to emit and report so that
`gallium/drivers/panfrost` (arch 9, JM, malloc-IDVS) accepts its shaders. All facts come from Mesa 26.2.6.
Only arch 9 and the Gallium path are covered.

**Source root**: `gpu/mesa/src/src/`. Abbreviations used in citations:

| tag | file |
|---|---|
| BC | panfrost/compiler/bifrost/bifrost_compile.c |
| BN | panfrost/compiler/bifrost/bifrost_nir.c |
| CH | panfrost/compiler/bifrost/compiler.h |
| RA | panfrost/compiler/bifrost/bi_ra.c |
| PU | panfrost/compiler/bifrost/bi_opt_push_ubo.c |
| VP / VF / VM / VL / VV / VK / VI / VS | valhall/ va_pack.c / va_insert_flow.c / va_merge_flow.c / va_mark_last.c / va_validate.c / va_lower_constants.c / va_lower_isel.c / va_lower_split_64bit.c |
| VCH / VH | valhall/va_compiler.h / valhall/valhall.h |
| ISA | panfrost/compiler/bifrost/valhall/ISA.xml |
| PC / PCC | panfrost/compiler/pan_compiler.h / pan_compiler.c |
| PN | panfrost/compiler/pan_nir.h |
| FSO / FSI / VSO / TEX / IMG / NOP / CV | panfrost/compiler/pan_nir_lower_fs_outputs.c / _fs_inputs.c / _vs_outputs.c / _tex.c / _image.c / _noperspective.c / pan_nir_collect_varyings.c |
| GS / GC / GCH / GJ / GX / GSV / GRI / GB | gallium/drivers/panfrost/ pan_shader.c / pan_cmdstream.c / pan_cmdstream.h / pan_jm.c / pan_context.h / pan_nir_lower_sysvals.c / pan_nir_lower_res_indices.c / pan_blend_cso.c |
| LS / V9 | panfrost/lib/pan_shader.h / panfrost/genxml/v9.xml |
| HK | panfrost/compiler/pan_isa_hooks.h (our hook) |

Throughout, "FAU word *w*" means 32-bit push word *w*. FAU slot *k* is the 64-bit pair (words 2k, 2k+1). The
disassembler prints slot *k* as `u<k>.w0` / `u<k>.w1`.

---

## 0. Hook integration (our fork)

`panfrost_shader_compile` calls `pan_isa_hooks->compile(nir, key, &binary, &info, &sysvals)`. When it returns
NULL, Gallium uses `binary`, `info` and `sysvals` as they are. It runs no lowering, no sysval pass and no
`pan_shader_update_info` (GS:107-138, HK:39-44). In that case Gallium only does the following:
- It sets `info.wls_size = MAX2(req_local_mem, info.wls_size)` (GS:133-134).
- It uploads the binary with 128-byte alignment (GS:314-317). An empty binary (`size==0`) means no
  shader program descriptor (GC:4457-4458).
- It runs `pan_earlyzs_analyze(&info)` (GS:426) and `panfrost_analyze_sysvals` (GS:330).

So the hook must fill every field listed in §12 itself, including `info.varyings.formats` with the
`known` flags set.

---

## 1. Preloaded registers

### 1.1 Register map (arch ≥ 9), from CH:1116-1244 (`bi_preload_reg`)

| stage | reg | content | bits / notes |
|---|---|---|---|
| compute | r55 | local_id.x / .y | x = [15:0], y = [31:16] (u16). BC:2083-2089 uses `u16_to_u32(half(r55,0))`, `half(r55,1)` |
| compute | r56 | local_id.z | [15:0] |
| compute | r57, r58, r59 | workgroup_id.x, .y, .z | 32-bit |
| compute | r60, r61, r62 | global_invocation_id.x, .y, .z | 32-bit, computed by hardware (`has_cs_global_id`, bifrost_compile.h:136) |
| vertex | r59 | INTERNAL_ID = IDVS output-buffer index | used for LEA_BUF to the position or varying FIFO (BC:1958, VSO:61) |
| vertex | r60 | vertex_id | **includes the base**: for indexed draws it is index + index_bias, otherwise first + i (§5.6) |
| vertex | r61 | instance_id | zero-based (§5.6) |
| vertex | r62 | draw_id | arch ≥ 9. The Gallium sysval is used only for arch < 10 (GSV:79-83) |
| vertex | r63 | view_id | only used for arch ≥ 14 (BC:2158-2161) |
| fragment | r57 | primitive_id | |
| fragment | r58 | primitive flags | on v9, `front_facing = (r58 == 0)`. The `&1` mask is only applied for v11+ (BC:2017-2028) |
| fragment | r59 | pixel position | x = [15:0], y = [31:16] (u16, integer pixel, top-left origin) (BC:1945-1948) |
| fragment | r60 | cumulative coverage | [15:0]. ATEST/ZS_EMIT read it and write it back here (RA:466-485) |
| fragment | r61 | rasterizer coverage / sample id / centroid id | [15:0] sample_mask_in. Sample id = `(r61 >> 16) & 0x1f`: use a 5-bit mask because upper bits read garbage (BC:886-895). Centroid id is [31:24] |
| fragment | r62–r63 | "frame arg" (64-bit) | layer_id = byte 0 of r62 (BC:2165-2170) |
| blend shader | r0–r3, r4–r7 | src0 / src1 colour | inputs to blend shaders (CH:1225-1240) |
| blend shader | r48 | blend link (return address) | CH:1241-1242 |

### 1.2 How `info->preload` is computed
- `preload = first_block->reg_live_in`, the registers read before being written (BC:4688-4690).
- On Valhall, every **fragment** shader also forces `preload |= BIT(60)|BIT(61)`. A blend shader may run in the
  same thread and needs r60/r61 (BC:4692-4704).
- The IDVS varying shader gets its own mask in `info->vs.secondary_preload` (BC:4712-4716).
- The driver only uses bits 48..63: `SHADER_PROGRAM.preload.r48_r63 = preload >> 48` (GC:4497, 4516, 4531;
  V9:892-903). The bits for r55..r63 are bits 7..15 of that field.
- Rule: set bit *n* for every register in r48–r63 that the program reads before writing. Fragment
  shaders always set bits 60 and 61.

---

## 2. Fragment outputs

### 2.1 What Mesa emits: one epilogue in the last block (FSO:91-203)
1. Color outputs are collected into temporaries. Color0's `.w` is set to 1.0 before the first instruction
   (FSO:110-117).
2. `coverage = written_sample_mask & load_sample_mask(r60)` if `FRAG_RESULT_SAMPLE_MASK` is written.
   Otherwise `coverage = cumulative_coverage (r60)` (FSO:121-130). Gallium also wraps a written mask as
   `multisampled ? mask : orig_mask`, using the MULTISAMPLED sysval (GS:79-95).
3. **ATEST** (always, unless this is a blit): `coverage = ATEST(coverage, alpha_rt0, atest_datum)`.
   `alpha` is `color0.w` when RT0 is a float type, else 1.0f (FSO:138-150).
4. **ZS_EMIT**, only if depth or stencil is written and `!early_fragment_tests`:
   `coverage = ZS_EMIT(depth f32, stencil u32, coverage)` with `.z` / `.stencil` (FSO:153-176). ZS_EMIT
   always comes after ATEST ("EMIT_ZS requires an ATEST", FSO:154). Note that the comment at
   lib/pan_earlyzs.c:40 says "ZS_EMIT must precede ATEST", which contradicts the code. Follow the code.
5. **BLEND** for RT i = 0..7 in ascending order, only for written RTs. If `FRAG_RESULT_COLOR` is written, it
   is broadcast to every RT (FSO:178-200).
6. An FS with no outputs still emits ATEST (FSO:100-101 only skips when `skip_atest`, which is blit only). So
   a real FS is never empty.

### 2.2 ATEST
- Operands: staging dest = r60, src0 = coverage, src1 = alpha, src2 = FAU special `atest_datum`
  (page 0, index 5) (BC:1633-1645; VP:84-85).
- f16 alpha is passed as `half(alpha,0)` (swizzle .h0). ISA:1774-1788 marks src1 `swizzle="true"`.
- The coverage input must be r60 (or a FAU value). A coverage mask in any other register breaks early-ZS
  with per-pixel shading (RA:473-485). The result is also allocated to r60 (RA:467-471).
- Slot 0 (VF:525-527). Flow: the instruction **before** ATEST carries `wait0126`, and ATEST itself carries
  `wait0` (VF:443-446; ISA:55-58).

### 2.3 ZS_EMIT
- Staging dest = r60, src0 = depth (f32), src1 = stencil, src2 = coverage. Modifier bits: `.stencil` is bit 24,
  `.z` is bit 25 (VP:589-594; ISA:1790-1804). Slot 0.
- The preceding instruction carries `wait0126` (VF:447-450).

### 2.4 BLEND (one per RT)
- IR operands (BC:1658-1709): staging src = colour (vec4), src1 = coverage (r60), src2/src3 = blend descriptor
  lo/hi = FAU special `blend_descriptor_<rt>` .w0/.w1 (page 0, index 8+rt) (BC:1626-1631; VP:99-100;
  ISA:87-111). `I->blend_target = rt`.
- Encoding (VP:999-1018): bits 0-7 = the 64-bit descriptor source. Bits 8-15 = `target` =
  `branch_offset >> 3` (multiple of 8, ≤ 2040). Bits 16-23 = coverage, which **must be a register**
  (`va_pack_reg`). Vecsize is always v4. The staging register and count come from the generic `sr_count`
  path (VP:860-869).
- Staging registers are precoloured: colour in **r0–r3** (sr_count 4 for 32-bit types, 2 for 16-bit types
  packed as v2f16×2), dual-source colour in **r4–r7**. The second source is not encoded; Mesa only
  precolours it (RA:450-465). With more than one RT, Mesa copies each colour into r0..r3 right before its
  BLEND (BC:1683-1692).
- Register format = `bi_reg_fmt_for_nir(type)`: f16 = 3, f32 = 2, s16 = 5, u16 = 7, s32 = 4, u32 = 6
  (BC:375-394; ISA:498-508). When `nir->info.fs.untyped_color_outputs` is set it is **AUTO** = 0
  (BC:1676-1678).
- A blend shader may run inside BLEND. Blend shaders clobber **r0–r15 and r48**, so nothing live across a
  BLEND may sit in those registers (RA:390-399).
- Info: `info->bifrost.blend[rt].type = T` (nir_alu_type: float32 = 0xA0, float16 = 0x90, int32 = 0x22,
  uint32 = 0x24, int16 = 0x12, uint16 = 0x14; nir_defines.h:133-137). For dual-source,
  `info->bifrost.blend_src1_type = T2` (BC:1702-1707). Gallium keys the blend shader on these types
  (pan_context.c:213-219). `return_offset` is only written by the Bifrost packer (bifrost/bi_pack.c:680) and
  read only for arch ≤ 7 (GC:375-380). **Leave it 0 on v9.**
- Flow: the instruction **before** each BLEND carries `.wait` (slots 0,1,2,6,7) (VF:427-431). The last BLEND of
  the program carries `.end` (end-of-block NOP merged into it, VM:62-85).

### 2.5 Blend-shader call sequence after every BLEND (VP:1160-1201, `va_lower_blend`)
After each BLEND, emit exactly two instructions:
```
BLEND (not last)  : target(branch_offset) = 16   ; FF blending skips the next 2 instrs
  IADD_IMM.i32 r48, pc, #8                        ; pc = special page3 program_counter = address of NEXT instr
  BRANCHZI.eq.absolute  0(lut), blend_descriptor_<rt>.w1
BLEND.end (last)  : target = 0
  IADD_IMM.i32 r48, 0(lut), #0                    ; r48 = 0 means the blend shader terminates the thread
  BRANCHZI.eq.absolute  0(lut), blend_descriptor_<rt>.w1
```
- With fixed-function blending, BLEND either branches `target` bytes ahead or ends the program
  (`.end`). With a blend shader, BLEND ignores flow and target and falls through into the IADD_IMM and
  BRANCHZI (ISA:1748-1767).
- The blend shader returns with `BRANCHZI.ne r48` (BC:1711-1721).
- BRANCHZI is always encoded absolute, bit 40 (VP:492-503). On v9 the descriptor `.w1` holds the blend
  shader PC (V9:568-570, 585-599: Internal Blend word 1 = "Blend Shader.PC"). This is inferred from the
  layout plus the fact that Mesa uses src3.
- r48 must be free at every BLEND. Mesa precolours BLEND's (not encoded) dest to r48 (RA:461-463).

### 2.6 Sample mask, discard, alpha-to-coverage
- Discard: Mesa lowers `terminate` to `demote` (BN:405-416).
  - `demote` → `DISCARD.f32 0, 0, eq`.
  - `demote_if(c)` → `DISCARD.b32(c)`, which is rewritten to `DISCARD.f32(c, 0, ne)`, or fused with a
    preceding FCMP (BC:1979-1992; bi_opt_mod_props.c:105-130, 501-512).
  - DISCARD only flags the thread. Termination happens when the whole quad is discarded, or at an
    instruction with `.discard` flow (BN:405-412; ISA:829-840).
  - Set `info.fs.can_discard = true`; this makes `sidefx` true and forces late coverage (PCC:255-261;
    pan_earlyzs.c:61-62).
- Alpha-to-coverage is pure driver state (DCD `alpha_to_coverage`, GJ:649). ATEST applies it using
  `atest_datum`, which is why ATEST is always emitted.
- `info.fs.writes_coverage` must be set if the sample mask is written. It drives
  `shader_modifies_coverage` (GJ:636-640).

### 2.7 Empty programs
- `va_insert_flow_control_nops` leaves a program with zero instructions empty (no `NOP.end`, VF:357-366).
  `bi_pack_valhall` keeps it at size 0 (VP:1225-1239), and the driver then omits the program descriptor
  (GC:4452-4458).
- For a fragment shader, an empty binary is only valid when `panfrost_fs_required()` is false
  (GCH:194-229).
- A non-empty program that would otherwise be empty must be at least `NOP.end` (ISA:793-802).

---

## 3. Framebuffer fetch (reading a colour attachment)

Mesa lowers `load_output` to `load_tile_pan` (BN:623-647, BC:1445-1466):
```
LD_TILE.<regfmt>.v<n>  dest, pixel_indices, coverage, conversion
```
- **pixel_indices** (u32): `sample | rt<<8 | x<<16 | y<<24` with x = 0 and y = 255 ("current pixel")
  (PN:19-43; bifrost/bifrost.h:567-574). For depth use rt = 255, for stencil rt = 254; in both cases also set
  the `z_stencil` bit 36 (VP:596-599). Mesa's `load_output` always uses **sample 0** (BN:640). For
  per-sample fetch, put `(r61>>16)&0x1f` in the sample byte.
- **coverage** = `r60 & 0x1f` (PN:46-49).
- **conversion** = word 0 of the `PAN_SYSVAL_RT_CONVERSION` sysval, id `rt | (bitsize<<4)` (GSV:106-111).
  The driver fills it with `pan_blend_get_internal_desc(fmt, rt, size) >> 32`, or a NONE-format conversion if
  the RT is unbound (GC:1287-1302).
- **regfmt** = `bi_reg_fmt_for_nir(dest_type)`. vecsize = n-1.
- Flow: the preceding instruction carries `.wait` (VF:433-441). `wait_resource` is v10+ only (VF:437).
- Info: `info.fs.outputs_read` = the `FRAG_RESULT_*` bitmask read (PCC:250). This forces
  `can_fpk = false` (PCC:269-271).
- The `hsr.*` fields are arch ≥ 13 only (BC:4643-4644). Leave them zero.

---

## 4. Fragment inputs (varyings and system values)

### 4.1 Choosing the instruction (FSI:54-93)
- If a VS varying layout is known (`inputs->varying_layout`, key `vs_varying_layout.known != 0`, GS:297-301)
  **and** `slot->offset < 256` (`pan_ld_var_buf_off_size(9)=256`, PC:592-601): use **LD_VAR_BUF[_IMM]**
  with **byte** offset = `slot->offset` of the VS layout.
- Otherwise use **LD_VAR[_IMM]** / **LD_VAR_FLAT[_IMM]** through attribute descriptors in table
  `PAN_TABLE_ATTRIBUTE` (1), index = FS input index (`base`). Then set `info.bifrost.uses_ld_var = true`
  (FSI:78-79).
- Gallium compiles the FS without a layout when `clip_plane_enable` is set (GS:373-374). That forces the
  LD_VAR path.
- Interpolated (smooth) loads: `load_var_buf_pan` / `load_var_pan`. Flat loads: `*_flat_*`. Flat loads set
  `info.bifrost.uses_flat_shading = true` (BC:660-661, 745-748). That flag disables primitive rotation
  (GCH:306-311).

### 4.2 LD_VAR_BUF_IMM / LD_VAR_BUF (BC:719-811; VP:550-570; ISA:968-1014)
- Opcode `.f32`/`.f16` = destination size. regfmt = F16 or F32. Integer regfmts are not supported (use
  float regfmt with a flat source format; the conversion is a no-op).
- `source_format` (ISA:732-743): src_flat32 = 0, src_flat16 = 1, src_f32 = 2, src_f16 = 3. Smooth loads use
  F32/F16 matching the in-memory size; flat loads use FLAT32/FLAT16. Bits 24-25.
- **index** (byte offset) is in bits 16-23 on v9 (VP:555-559).
- src0 = barycentric source (§4.4). For flat loads src0 = 0. `sample` mode is bits 38-39, `update` = STORE (0)
  is bits 36-37.
- The in-memory size of a varying is the **VS layout** size. If the FS wants another bit size, load at the
  layout size and convert (BN:893-905, pan_nir_resize_varying_io.c:73-107). If a slot is missing in the VS
  layout, the value is 0.

### 4.3 LD_VAR_IMM / LD_VAR (descriptor path)
- `LD_VAR_IMM`: table bits 8-11 (= 1), index bits 12-19 (< 256) (VP:560-563; BC:680-704).
- The index refers to `fs->info.varyings.formats.slots[i]`. Gallium builds one ATTRIBUTE descriptor per FS slot
  with `table=61`, `offset=1024+vs_offset`, `stride=generic_size_B`, `packet_stride=generic_size_B+16`
  (GC:3099-3152). This is why the FS `varyings.formats` must use the same indexing as the shader's
  LD_VAR indices.
- regfmt from the type. Flat loads of 16-bit ints are not encodable (BC:663-664).

### 4.4 Interpolation operand (src0) and sample mode (BC:276-372)

| NIR / Metal | sample mode (bits 38-39) | src0 |
|---|---|---|
| center (default, `[[center_perspective]]`) | center = 0 | **r61** (centroid-id preload) |
| centroid | centroid = 1 | r61 |
| sample | sample = 2 | r61 |
| at_sample(s) | sample = 2 | `MKVEC.v2i16(dontcare, s)`: sample index in the high 16 bits |
| at_offset(x,y) | explicit = 3 | v2s16 8:8 fixed-point offset from the top-left: `f2i16((off+0.5)*256)` |

Update mode is always `store` (0) for LD_VAR*. LD_VAR_SPECIAL uses `clobber` (3) (BC:1436-1440; ISA:691-701).

### 4.5 noperspective
- The hardware only has perspective and flat interpolation (NOP:8-28).
- VS: multiply each noperspective output by `pos.w`, using the **pre-transform** W = 1/(stored 1/W). The VS
  needs the FS's noperspective mask; Gallium passes it as the key `noperspective_varyings`, with bit i =
  VAR0+i (NOP:152-200; GS:219-222, HK:23).
- FS: multiply the loaded value by `LD_VAR_SPECIAL frag_w` (NOP:118-135).
- Report the FS mask in `info.varyings.noperspective` (BN:916-917). With the hook, the driver gets it from
  `create_layout(..., fs_noperspective)` (HK:36-38).

### 4.6 Special inputs

| input | code |
|---|---|
| frag position xy | `U32_TO_F32` of the u16 halves of r59. Gallium advertises `fs_coord_pixel_center_integer` (pan_screen.c:810), so **Metal must add 0.5** |
| frag z | `LD_VAR_SPECIAL.v1.f32 name=frag_z(3)`, src0 = r61, center, clobber (pan_nir_lower_var_special.c:16-38; BC:1420-1442; ISA:927-939) |
| frag w | same, name = frag_w (2). NIR's `frag_coord_w` maps here directly |
| point coord | `LD_VAR_SPECIAL.v2 name=point(0)`. The name goes in bits 12-15 (VP:551-553). The value of name 1 is reserved (bifrost/ISA.xml:6818-6825) |
| front facing | `ICMP r58 == 0` (BC:2017-2028) |
| primitive id | r57 |
| sample id | `RSHIFT_AND r61, 0x1f, 16` (BC:886-895) |
| sample_mask_in | `U16_TO_U32(r61.h0)` (BC:1999-2003) |
| helper invocation | `sample_mask_in == 0` (pan_nir_lower_helper_invocation.c) |
| sample position | `load_sample_positions_pan` lowers to the **SAMPLE_POSITIONS sysval** (a 64-bit pointer, GSV:64-65; GC:1257-1266). Then `LOAD.i32 [ptr + sample_id*4]`: two s16 in 8:8 fixed point, scale ×1/256 (pan_nir_lower_sample_position.c). Without sample shading the value is (0.5,0.5). The special FAU `sample` (page 0 idx 6, BC:1994-1997) is not used on the Gallium path because sysval lowering runs first |
| layer id | `U8_TO_U32(r62.b0)` |

---

## 5. Vertex shader (malloc IDVS)

### 5.1 IDVS is mandatory on v9
- Gallium asserts `idvs` ("Memory allocated IDVS required on Valhall", GJ:1016). Set `info.vs.idvs = true`
  (BN:1171-1186 returns true on v9 unless `no_idvs`, which is XFB only).
- The program is compiled **twice** from the same source (BN:1296-1306, BC:4376-4400):
  - **Position shader** (`BI_IDVS_POSITION`): only outputs in buckets POSITION (`VARYING_SLOT_POS`) and
    ATTRIB (`PSIZ`, `LAYER`, `PRIMITIVE_ID`) (VH:179-210).
  - **Varying shader** (`BI_IDVS_VARYING`): only bucket VARY, i.e. all other outputs. Everything else is
    DCE'd.

### 5.2 Binary layout (BC:4663-4757; VP:1225-1239)
```
offset 0               : position shader (with psiz store if PSIZ written), zero pad to ALIGN(size+16,128)
info.vs.no_psiz_offset : same position shader, psiz STORE replaced by NOP (flow kept)   [only if PSIZ written]
info.vs.secondary_offset : varying shader, zero padded
```
- Every program is followed by zero padding to `ALIGN_POT(size + 16, 128)`. Empty programs get no padding.
- `secondary_enable = (binary.size > secondary_offset)`: the varying shader is non-empty.
- `secondary_preload` and `secondary_work_reg_count` come from the varying shader.
- If position is never written, no varying shader is built (BC:4669-4676).
- Driver use (GC:4484-4532; GCH:232-252):
  - `programs[0]` = binary+0. It is used for POINTS and is the IDVS/points variant.
  - `programs[1]` = binary + `no_psiz_offset`, used for all other primitives. With `no_psiz_offset == 0` it is
    identical to programs[0].
  - `programs[2]` = binary + `secondary_offset`.
  - All of them use `info.preload` / `info.work_reg_count`, except programs[2], which uses the `secondary_*`
    fields.
  - The vertex warp limit is HALF for position programs and FULL for the varying program.

### 5.3 Output stores (VSO:50-97, 265-345)
- Every output is written to the hardware FIFO through **table 61 (encoded as table 13), index 0**. `LEA_BUF_IMM`
  table and index go in bits 8-11 / 12-19 (VP:513-516; VH:146-163).
- Sequence for each output slot:
  ```
  LEA_BUF_IMM.table13.index0  [a_lo,a_hi] = r59 (+4 if section==ATTRIBS)   ; 2 staging regs, message slot
  (IADD.u64 / offset)          addr = a + slot.offset
  STORE.iNN  value, [addr], #imm_off, .istream (POSITION/ATTRIBS) | .estream (GENERIC)
  ```
  `memory_access`: none = 0, istream = 1, estream = 2, force = 3, in bits 24-25 (VP:770-780; ISA:607-613).
  `STORE` takes a 16-bit signed offset in bits 8-23, so slot offsets can go into the immediate.
- **Position**: section POSITION, offset 0, 4×f32 = `STORE.i128`. The value must already be
  **viewport-transformed** (§5.4).
- **Point size**: section ATTRIBS, offset 0, **f16** (`STORE.i16`), structure index r59+4 (CV:258-288). The
  write must be tagged so it can be removed for the no_psiz variant (BC:1733-1739, 4729-4754). Gallium clamps it
  with `nir_lower_point_size(1.0, 0)` (BN:943). Layer is u8 at ATTRIBS+2; primitive_id is u32 at ATTRIBS+12.
- **Generic varyings** (`VARYING_SLOT_VAR0+i`): section GENERIC, offset from the VS layout, structure index r59.
  Each value is stored at the layout's bit size; convert f32→f16 if the layout says 16-bit (BN:893-905).
- Layout rules (CV:413-448, `pan_build_varying_layout_compact`):
  - For each generic slot in index order: `size = ncomps*bytes`, `align = next_pow2(size)`,
    `offset = align(running, align)`.
  - `generic_size_B` = the end of the last slot. It must be < 4096.
  - The driver sets `vertex_packet_stride = generic_size_B + 16` and `vertex_attribute_stride = generic_size_B`
    (GJ:806-818).

### 5.4 Viewport transform is the shader's job (BN:942; nir_lower_viewport_transform.c)
```
w_r   = clamp(1/pos.w, -32768, +32768)
out.xyz = pos.xyz * w_r * VIEWPORT_SCALE.xyz + VIEWPORT_OFFSET.xyz
out.w   = w_r
```
- `VIEWPORT_SCALE` and `VIEWPORT_OFFSET` are sysvals (vec3 f32) (GSV:88-92; GC:1061-1082).
- Depth range [0,1] versus [-1,1] is driver state baked into scale/offset (pipe_viewport_state).

### 5.5 Attributes (BC:488-558; GRI:171-187; GC:4062-4100)
- Vertex element *i* is attribute descriptor *i* in **table 1** (`PAN_TABLE_ATTRIBUTE`). Gallium uploads
  `num_elements` descriptors in pipe vertex-element order (GC:974-982; GCH:289-291). Each descriptor references
  **table 2** (`PAN_TABLE_ATTRIBUTE_BUFFER`) entry `vertex_buffer_index`, which holds the per-slot BUFFER
  descriptors (GC:940-972).
- Index < 16 → `LD_ATTR_IMM`: src0 = vertex id (r60), src1 = instance id (r61), `table` bits 16-19 = 1,
  `index` bits 20-23 (VP:575-578; ISA:1076-1095).
- Index ≥ 16 → `LD_ATTR` with a third source = handle `(1<<24)|index` (ISA:1097-1112). The index must be
  warp-uniform.
- regfmt:
  - 32-bit int: AUTO (0). The fetch is bit-exact; signedness is not checked.
  - f32: F32. f16: F16. u16 / s16: U16 / S16.
- vecsize = comps+component-1. For component ≠ 0, load wider and select components (BC:467-486).
- `info.attributes_read` = `inputs_read`, `attribute_count` = popcount (PCC:222-225). v9 Gallium does not read
  them, but fill them anyway.

### 5.6 vertex_id / instance_id / base_vertex / base_instance
- Valhall gives the absolute vertex id in r60. NIR's `load_vertex_id` maps to r60 directly; the
  `raw + offset` lowering only applies for arch ≤ 7 (BC:2035-2047; BN:417-419).
- PRIMITIVE.base_vertex_offset is `index_bias` (indexed draw) or `draw->start` (non-indexed) (GJ:752-761).
  So r60 = `index + base_vertex` or `start + i`. This matches Metal `[[vertex_id]]`.
- r61 = `gl_InstanceID`, zero-based. `base_instance` is **not** added, and Gallium v9 does not offset
  instanced attribute buffers by base_instance (only the v≤7 path does, GC:2533). Metal
  `[[instance_id]]` includes base_instance, so add the sysval. Suggestion: also pass
  `r61 + base_instance` as the instance source of `LD_ATTR*`.
- `PAN_SYSVAL_VERTEX_INSTANCE_OFFSETS` (vec4) (GSV:70-77; GC:1415-1419): u[0] = `offset_start` (only set
  for non-indexed draws on v9), **u[1] = base_vertex** (index_bias of indexed draws, else 0),
  **u[2] = base_instance**.
- `draw_id` is r62.

### 5.7 VS info fields
`vs.idvs`, `vs.secondary_enable`, `vs.secondary_offset`, `vs.secondary_preload`, `vs.secondary_work_reg_count`,
`vs.no_psiz_offset`, `vs.writes_point_size` (enables the FP16 point-size array, GJ:715-716,
pan_context.c:83-89), and `vs.needs_extended_fifo`. The last one is unused by Gallium; it is true only when
LAYER or PRIMITIVE_ID is written (VSO:26-48, 293-304). Also `varyings.formats` = the full VS layout with
`known = FORMAT|LAYOUT` (BN:945-948).

---

## 6. Compute

- Preloads: see §1. `local_invocation_index` is lowered to the id (`lower_cs_local_index_to_id`,
  bifrost_compile.h:137).
- **Workgroup size**: sysval `PAN_SYSVAL_LOCAL_GROUP_SIZE` (type 8, §9). It is not in FAU or a preloaded register.
- **Number of workgroups**: sysval `PAN_SYSVAL_NUM_WORK_GROUPS`.
  - For indirect dispatch, the driver patches these words in place. It patches **either** the sysval UBO copy
    **or** the pushed FAU copy: `num_wg_sysval[]` is overwritten by whichever path runs last (GC:1375-1381,
    1600-1611).
  - Read all three words consistently from one place: all pushed, or none pushed.
- **Shared memory**: address = FAU special `workgroup_local_pointer` (page 1, idx 3) 64-bit pair.
  - Constant offsets fit in `LOAD/STORE` imm16. Otherwise compute `lo = IADD(wls.lo, off)` with `hi = wls.hi`
    (no carry) (BC:1052-1080).
  - The pair must be in an even register pair, or be the whole FAU pair (§11.6).
  - Shared atomics use the same address.
- `info.wls_size` = shared bytes (PCC:290-293). Gallium sets it to `MAX2(req_local_mem, ·)` (GS:133-134,
  267-268) and adds `variable_shared_mem` at dispatch (GC:1671).
- **Barrier**: `BARRIER` with slot 7 and the `.wait` flow on the BARRIER itself (VF:418-420, 525-526;
  ISA:857-865). Every general slot must be waited on before it: there is a `wait012` on a prior instruction
  (VF:194-219, a DDK-matching workaround). Only `SCOPE_WORKGROUP` execution barriers emit BARRIER; other scopes
  only order instructions (BC:1760-1785). Set `info.contains_barrier`.
- `info.cs.allow_merging_workgroups` (GS:225-227; BN:580-621) is true iff all of:
  - `shared_size == 0`
  - no workgroup-scope barrier
  - no subgroup operation
  - no `subgroup_invocation` read

  The driver ANDs it with `variable_shared_mem == 0` (GJ:385-392).
- Subgroup size is 16 (PC:578-589). Lane id = FAU special page 3 idx 1.

---

## 7. Resources

### 7.1 Tables (GX:331-348; GCH:255-302)
Handle = `(table << 24) | index` (PC:603-632). Gallium fixes the table numbering per stage:

| table | content | filled with |
|---|---|---|
| 0 `PAN_TABLE_UBO` | BUFFER descriptors | user UBOs + the sysval UBO at index 1 (§9) |
| 1 `PAN_TABLE_ATTRIBUTE` | ATTRIBUTE descriptors | VS: vertex elements. FS: varying descriptors (§4.3) |
| 2 `PAN_TABLE_ATTRIBUTE_BUFFER` | BUFFER | VS vertex buffers |
| 3 `PAN_TABLE_SAMPLER` | SAMPLER | `MAX2(sampler_count,1)`; there is always a sampler 0 (used for txf) |
| 4 `PAN_TABLE_TEXTURE` | TEXTURE | sampler views, `MAX2(bound, info.texture_count)` (GC:1935-1946) |
| 5 `PAN_TABLE_IMAGE` | TEXTURE | images, `last_bit(image_mask)` |
| 6 `PAN_TABLE_SSBO` | BUFFER | SSBOs, `last_bit(ssbo_mask)` |
| 61 (hardware) | IDVS position/varying FIFO buffers | §5.3 |
| 62 (hardware) | "the resource tables themselves" | raw descriptor reads: `LD_PKA` with handle `(62<<24)|table`, byte offset `index*32+word*4` (PN:63-79) |

- The `table` field of `*_IMM` encodings is 4 bits: tables 0..11 encode as-is, and 60..63 encode as 12..15
  (VH:146-163). The index limits of the `_IMM` forms are listed below each instruction.
- Mapping rules (GRI:124-260): texture handle = `pan_res_handle(4, tex_index)`, sampler =
  `pan_res_handle(3, samp_index)` (or (3,0) for txf), images = `(5,i)`, UBO = `(0,i)`, SSBO = `(6,i)`,
  vertex/FS inputs = `(1,i)`.

### 7.2 Texturing (TEX.c 723-974; BC:3491-3576; VP:1021-1069; ISA:3641-3760)
- Ops: tex/txb/txl/txd → **TEX_SINGLE**; txf/txf_ms → **TEX_FETCH**; tg4 → **TEX_GATHER**; txd computes its
  gradient descriptor with **TEX_GRADIENT** first (`lod_mode grdesc`). Buffer textures do not use TEX (see
  below).
- **64-bit descriptor source** (bits 0-7). It must be an even register pair or a FAU slot:
  - *narrow* form (both handles constant, tables valid, indices < 1024):
    lo = `tex_table<<27 | tex_index<<16 | samp_table<<11 | samp_index`, hi = "narrow" immediate bits
    (see below), `wide_indices` = 0.
  - *wide* form: lo = sampler handle, hi = texture handle (full `table<<24|idx`), `wide_indices` = 1 (bit 8).
- **Staging read registers, in this order, skipping absent ones** (TEX:787-800):
  `S, T, R, Q(coords) | array_index | shadow_ref | offset(u8x4) | lod | grdesc0, grdesc1`. Max 8.
  - **Cube**: coords are replaced by 2 regs, (s with face in bits 29-31, t), built with `CUBEFACE1`,
    `CUBEFACE2_V9`, `CUBE_SSEL`, `CUBE_TSEL` and `fsat(s*(0.5/max)+0.5)` (TEX:68-134).
  - **Array**: `array_enable` (bit 10) plus an array register. On v9 do not use the narrow array index
    (TEX:854-866).
  - **Shadow**: `shadow` (bit 12, TEX_SINGLE and TEX_GATHER only), compare reference register.
  - **Offset / ms index / txf lod**: one u8x4 = `(off_s, off_t, off_r|ms_idx, txf_lod≤255)` with
    `texel_offset` (bit 11). If all values are constant 4-bit numbers and the form is narrow, pack them as
    nibbles into `hi`: offset nibbles at bits 0/4/8, and on v9 a constant txf LOD ≤ 15 at bits 12-15
    (TEX:868-922).
  - **LOD** (TEX_SINGLE `lod_mode` bits 13-15): zero = 0, computed = 1, explicit = 4, computed_bias = 5,
    grdesc = 6 (ISA:486-496).
    - explicit: one register = `s16 8:8 fixed(clamp(lod,-16,16))`, zero-extended.
    - bias / min_lod: `(s16 bias 8:8) | (s16 minlod 8:8) << 16`.
- **Dest**: staging write. `write_mask` (bits 22-25) = components read. **Results are packed densely in the
  order of the set mask bits** (BC:3555-3575). `register_type` comes from the regfmt, and bit 46 = 32-bit
  result. `dimension`: 1d = 0, 2d = 1, 3d = 2, cube = 3 (bits 28-29).
- `skip` (bit 39): set it only when no helper invocation needs the result. Leaving it at 0 is always correct
  (bi_helper_invocations.c:7-37).
- Implicit-LOD texturing and derivatives require helper threads, so set `contains_barrier` (§12).
- **Buffer textures** (txf on a BUF): `LEA_BUF` (handle, element index) → 64-bit address. Conversion =
  descriptor word 7, read through table 62; 0 means "CONSTANT 0000" = `95<<12|231`. Then
  `LD_CVT.<regfmt>.v4 [addr], cvt` (TEX:704-721; PN:81-95).
- **Size queries**: read the TEXTURE descriptor through table 62 (PN:97-176).
  - width-1 = halfword 2, height-1 = halfword 3, depth-1 = halfword at word 7, array-1 = halfword at word 6.
  - levels = (word2>>16 & 0x1f) + 1.
  - Halfword 0 == 0 means a null descriptor.

### 7.3 Images (IMG:44-252; BC:1238-1317)
- Coordinates are packed as u16: `xy = x | y<<16`, `zw = z_or_sample | array<<16`. Cube is 2D-array.
  - For bounds checking, OR the discarded high halves together and put the result into an unused 16-bit
    slot, so out-of-bounds accesses fail.
  - MS-array with no free slot: write 0xFFFF into the sample half.
- **load**:
  - `LD_TEX_IMM` (table 5 in bits 16-19, index < 16 in bits 20-23), or `LD_TEX` with the handle as third
    source.
  - Two coordinate sources; regfmt from the type; staging dest (VP:580-584; ISA:1129-1168).
- **store**:
  - `LEA_TEX_IMM`/`LEA_TEX` → 3 staging regs `{addr_lo, addr_hi, icd}` (ISA:1208-1250).
  - Then `ST_CVT.auto value, [addr], icd`. regfmt AUTO for 32-bit values. Trim components to the format
    (IMG:186-233).
- **atomics**: `image_texel_address` = LEA_TEX → 64-bit address → global atomic (BN:869;
  IMG:235-252).

### 7.4 UBO, SSBO, global (BC:869-884, 983-996, 2172-2186; nir_lower_ssbo.c:24-37, 79-95)
- **UBO load**: `LD_PKA.iN dest, byte_offset, handle(0<<24|ubo)`. Offset is src0, handle is src1 (VP:785-792,
  `va_pack_load(..., true)`). N is 8..128 bits.
- **SSBO load**: `LD_PKA.iN dest, byte_offset, (6<<24)|ssbo` (native, BN:1013-1017).
- **SSBO store / atomic**: `LEA_PKA [a_lo,a_hi] = (offset, handle)` (2 staging regs), then
  `STORE` / `ATOM*` on the 64-bit address (ISA:1640-1652).
- **Global**: `LOAD.iN dest, [addr_pair], #imm16` / `STORE.iN src, [addr_pair], #imm16`. The 64-bit
  address is an even register pair or a FAU slot (VP:751-783).
- Accesses are at most 16 bytes and naturally aligned (BN:810-840).
- **Atomics** (BC:1360-1417; VP:899-962):
  - `ATOM_RETURN.i32` (staging `{arg}` → result), or `ATOM.i32` (no return), with op in bits 22-25.
    Op values: aadd = 2, asmin = 8, asmax = 9, aumin = 10, aumax = 11, aand = 12, aor = 13, axor = 14,
    axchg = 15 (ISA:745-766).
  - `ATOM1_RETURN` for inc / dec / umax1 / smax1 / or1 when the argument is the constant 1, or -1 for add
    (BC:1208-1235).
  - cmpxchg = `ATOM_RETURN` op axchg with `.compare` (bit 26), staging `{new, compare}` (BC:1146-1183).
  - 64-bit variants use 2 / 4 staging registers.
- `robust_descriptors=true` is passed by Gallium (GS:244-248), but the BIR backend ignores it (grep). Bounds
  come from the descriptors.
- `PAN_SHADER_OOB_ADDRESS = 1<<63`: any address with the top bit set reads 0 and drops writes (PC:83-89).

---

## 8. FAU (uniforms)

### 8.1 Source encoding (VP:68-125; VCH:30-68; ISA:87-163)

| 8-bit source field | meaning |
|---|---|
| `0x00-0x3F` | register r0..r63, **bit 6 = last-use (discard) flag**. So a register source is `reg \| 0x40*last` |
| `0x80 \| (slot&31)<<1 \| hi` | uniform slot (64-bit). The page = `slot>>5` (0..3) goes in instruction bits 57-58 |
| `0xC0 + i` | hardware LUT immediate i (0..31), table below |
| `0xE0 \| s<<1 \| hi` | special FAU *s* of the page selected in bits 57-58 |

- Uniform slots 0..127 are architectural. The implementation limit is **64 slots = 128 words**
  (`PAN_MAX_PUSH`, PC:126-137). The driver passes `fau_count = ceil(words/2)` (GJ:320-321).
- An instruction may use only **one page** (bits 57-58), chosen from its first FAU source (VCH:59-68).

### 8.2 Special FAU (ISA:87-163; VCH:44-56; VP:76-104)

| page | idx | name | 64-bit content |
|---|---|---|---|
| 0 | 2 | warp_id | .w0 warp id, .w1 warps/core-1 |
| 0 | 4 | framebuffer_size | bounding box max X/Y |
| 0 | 5 | atest_datum | ATEST src2 |
| 0 | 6 | sample | sample positions (unused on the Gallium path) |
| 0 | 8+n | blend_descriptor_n | BLEND src, `.w1` = blend shader PC |
| 1 | 1 | thread_local_pointer | TLS base (64-bit) |
| 1 | 3 | workgroup_local_pointer | WLS base (64-bit) |
| 1 | 7 | resource_table_pointer | |
| 3 | 1 | lane_id | 0..15 |
| 3 | 3 | core_id | .w0 core id, .w1 core count-1 |
| 3 | 4 | shader_output | v12+ only |
| 3 | 15 | program_counter | address of the next instruction (used by the blend call) |

### 8.3 Hardware immediate LUT (`0xC0+i`) (ISA:8-48)
```
 0 0x00000000   1 0xFFFFFFFF   2 0x7FFFFFFF   3 0xFAFCFDFE   4 0x01000000   5 0x80002000
 6 0x70605030   7 0xC0B0A090   8 0x03020100   9 0x07060504  10 0x0B0A0908  11 0x0F0E0D0C
12 0x13121110  13 0x17161514  14 0x1B1A1918  15 0x1F1E1D1C  16 0x3F800000(1.0) 17 0x3DCCCCCD(0.1)
18 0x3EA2F983(1/pi) 19 0x3F317218(ln2) 20 0x40490FDB(pi) 21 0x00000000 22 0x477FFF00(65535.0)
23 0x5C005BF8(h:255,256) 24 0x2E660000(h0.1) 25 0x34000000(h0.25) 26 0x38000000(h0.5)
27 0x3C000000(h1.0) 28 0x40000000(h2.0) 29 0x44000000(h4.0) 30 0x48000000(h8.0) 31 0x42480000(h pi)
```
- A source may select a byte or half of an entry through its lane, swizzle or widen field. It may also negate
  an entry via `.neg` when the source has abs/neg (VK:112-193).
- Lookup order (VK:112-193):
  1. exact 32-bit value
  2. negated f32 / f16
  3. replicated f16 half
  4. zero/sign-extended byte or half (only 32-bit widen sources)
  5. exact f16 demotion
- Anything else goes to a pushed FAU constant, or to `IADD_IMM.i32 rd, lut0, #imm32`. The imm32 sits in
  bits 8-39 (VP:518-524, VK:16-21).
- **Staging sources never take immediates or FAU values.** Move them into registers first (VK:199-209, 300-302).

### 8.4 `pan_fau_layout` (PC:139-200)
- `words[i]` is either a UBO relocation `{ubo, byte offset}` or a constant (`is_const` bit set).
- `reserved` = number of leading driver-owned words. Gallium sets it to **0** (GS:152-155 never sets it).
- `count` = total words used. `max` = 128 (BN:1291-1293).
- Driver upload at draw time (GC:1580-1654):
  - Allocate `count*4` bytes.
  - For each relocation word: copy 4 bytes from the CPU copy of the sysval UBO (if `ubo == 1` and there
    are sysvals), else from **user** constant buffer `ubo_adj`. This asserts
    `!cb->buffer && cb->user_buffer` (GC:1631-1640), so **only CPU user buffers can be pushed**.
  - Constant words are copied as-is.
- `ubo` in a relocation uses **shader (hardware) numbering**: sysval UBO = 1, and user UBOs ≥ 1 shifted by +1
  (§9).

### 8.5 What Mesa pushes in a fragment shader (PU:91-207; GS:229-242)
1. Words 0..3 = **blend constants** = sysval UBO (1) bytes 0..15. They are always first and are not
   reordered.
   - The blend shader reads its constants from FAU words 0..3 of the FS context, because its own compile
     pushes `UBO1[0..15]` at word 0 (GB:40-56, 94-104).
   - **So every FS that may run with a constant-using blend shader must have FAU words 0..3 = blend
     constants, and therefore `sysvals[0] = PAN_SYSVAL_BLEND_CONSTANTS`** (GSV:258-261, which reserves
     sysval slot 0).
2. Then directly addressed, word-aligned, constant-offset UBO words from `pushable_ubos`, which is UBO0 plus the
   sysval UBO in Gallium, scanning from the highest UBO index down. Each push covers the access's channel
   count (PU:116-147).
3. Pushed accesses are rewritten to FAU moves. All other UBO accesses set `ubo_mask` bits (PU:164-207).
4. Promoted immediates fill the rest up to `max`, most frequent first, if `promote_immediates` is set
   (BC:4480-4510; VK:94-110).

---

## 9. Sysvals (Gallium, GSV and GC:1317-1428)

- Each sysval occupies one **vec4 (16 bytes)** in a CPU-built UBO bound at **UBO index 1**
  (`PAN_UBO_SYSVALS`, GX:324).
- When a shader has ≥ 1 sysval, `num_ubos = MAX2(1, num_ubos) + 1`, and **every user UBO with index ≥ 1 shifts to
  index+1** (GSV:159-177, 254-256; GC:1543-1576).
  - Consequence for our ABI: UBO0 (system header + push window) stays at 0, and our constant pool (user UBO 1)
    becomes hardware UBO 2 when sysvals exist.
- Fragment shaders **always** have sysvals in the NIR path, because blend constants are reserved
  (GSV:136-138).
- `info.ubo_count` must count the sysval UBO. The driver uses `ubo_count - 1` user UBOs (GC:1523).
- The hook returns `struct panfrost_sysvals {sysvals[32], sysval_count}` (GX:325-329). Entry *i* is
  `PAN_SYSVAL(type, id) = (id<<16)|type` (GX:287). Read component *c* of sysval *i* with `LD_PKA` from UBO 1
  at byte `16*i + 4*c`, or push it as a relocation `{ubo=1, offset=16*i+4*c}`.

| type (value) | id | contents (u32 lanes) | stages |
|---|---|---|---|
| VIEWPORT_SCALE (1) | 0 | f32 sx, sy, sz | VS |
| VIEWPORT_OFFSET (2) | 0 | f32 ox, oy, oz | VS |
| TEXTURE_SIZE (3) | txs id | sizes (on v9, the descriptor read is preferred, §7.2) | any |
| SSBO (4) | ssbo | u64 address (lanes 0-1), u32 size (lane 2) | any (for `get_ssbo_size`) |
| NUM_WORK_GROUPS (5) | 0 | grid x, y, z | CS |
| SAMPLER (7) | samp | f32 min_lod, max_lod, bias | |
| LOCAL_GROUP_SIZE (8) | 0 | block x, y, z | CS |
| WORK_DIM (9) | 0 | dim | CS |
| IMAGE_SIZE (10) / IMAGE_SAMPLES (20) | txs id | | |
| SAMPLE_POSITIONS (11) | 0 | u64 ptr to s16 8:8 (x,y) per sample | FS |
| MULTISAMPLED (12) | 0 | ~0 if samples > 1 else 0 | FS |
| RT_CONVERSION (13) | `rt \| bits<<4` | lane 0 = internal conversion descriptor | FS (LD_TILE) |
| VERTEX_INSTANCE_OFFSETS (14) | 0 | offset_start, **base_vertex**, **base_instance** | VS |
| DRAWID (15) | 0 | draw id (r62 is preferred on v9) | VS |
| BLEND_CONSTANTS (16) | 0 | f32 rgba | FS, must be index 0 |
| NUM_VERTICES (18), PRINTF_BUFFER (19), XFB (17) | | | |

`txs id = tex | dim<<7 | is_array<<9` (GX:314-320).

---

## 10. TLS / scratch / spilling

- `info.tls_size` = per-thread bytes. NIR scratch comes first; spill slots are appended after it, and when
  spilling the total is aligned to 16 (BN:1289; RA:1232-1327). The driver allocates
  `tls_size × thread_tls_alloc × cores` (GC:1676-1682; pan_job.c:848-849).
- Address = FAU special `thread_local_pointer` (page 1 idx 1, 64-bit) + a 16-bit signed immediate offset
  (< 0x8000). Accesses use `LOAD/STORE.iN` with **`.force`** memory access (value 3), which makes discarded or
  helper threads still execute them (RA:690-729; BC:1744-1750).
- Dynamic offset: `lo = IADD(tls.lo, off)`, `hi = tls.hi` (no carry), then form an even register pair (§11.6).
- v9 scratch rule: **an access must never straddle a 16-byte boundary**. Split smaller (BN:696-704). Max 16 bytes.

---

## 11. Flow control and encoding rules

### 11.1 Instruction word (VP:850-883)
- bits 0-23: srcs 0..2 (8 bits each)
- bits 24-25: regfmt (ops with regfmt)
- bits 28-29: vecsize
- bits 30-32: slot
- bits 33-35: staging count
- bits 36-38: staging write count - 1
- bits 40-47: dest = `reg | wrmask<<6`, with wrmask 1 = .h0, 2 = .h1, 3 = all (VP:173-187). For staging ops it
  is the staging register (bits 40-45) + sr_control (bits 46-47).
- bits 48-56: opcode
- bits 57-58: FAU page
- bits 59-62: flow

An instruction with no dest and no staging puts the placeholder `0xC0` in bits 40-47 (VP:614-617).

### 11.2 Flow values (ISA:50-85)

| value | flow |
|---|---|
| 0 | none |
| 1-7 | bitmask wait on slots {0,1,2} |
| 8 | wait0126 |
| 9 | wait (0,1,2,6,7) |
| 10 | reconverge |
| 12 | wait_resource (v10+) |
| 13 | discard |
| 15 | end |

**Flow takes effect after the instruction executes.** A wait required "before X" must therefore go on the
instruction preceding X, or on X's own async producer (VM:8-49, 117-145; ISA:55-58).

### 11.3 Message slots and dependencies (VF:14-41, 140-224; VF:509-532)
- Async (message) instructions get a slot in 0..2. Mesa assigns them round-robin.
- Fixed slots: BARRIER = 7; ATEST and ZS_EMIT = 0.
- The scoreboard model covers RAW and WAW on registers written by async instructions. WAR is handled by the
  hardware, because staging registers are read at issue (VF:31-34).
- **Memory ordering**: all non-UBO loads, stores, atomics and LD_TEX are serialized. Before a new one, wait
  for the slots of outstanding ones (VF:202-205).
- **Hidden varying register**: an `LD_VAR*` with update store or clobber must wait for every outstanding
  varying slot. At the **end of every block** that has outstanding varying loads, wait for all of them
  (VF:94-102, 196-200, 248-276).
- Before a BARRIER, wait for all general slots (VF:206-219).
- Before ATEST and ZS_EMIT: wait0126. Before BLEND, ST_TILE and LD_TILE: wait. After ATEST: wait0.

### 11.4 End, reconverge, discard
- Every block with no successors ends with `.end` on its **last** instruction (VF:330-339, 457-466). If the
  last instruction already has another flow, append `NOP.end`.
- A `NOP.end` may absorb preceding NOP waits, except `.wait` (slot 7) (VM:62-75).
- A branch target that is a terminal block gets `NOP.end` even when the block is empty (BC:4221-4245).
- `.reconverge` goes on the last instruction of a block that either has two successors, or whose single
  successor has more than one predecessor (bir.c:230-236; VF:467-471).
- Branches: `BRANCHZ` offset is a signed 27-bit number of **instructions** relative to the next instruction
  (bits 8-34), with `.eq` at bit 36 (ISA:804-827; VP:1083-1146). An unconditional jump is `BRANCHZ.eq lut0`
  (VI:70-78).
- Helper termination (FS only, an optimization):
  - Put `.discard` after the last instruction that needs helpers (TEX with computed LOD, CLPER, WMASK, and
    TEX_GRADIENT without derivatives), or at the start of the shader if helpers are never needed
    (VF:473-498; bi_helper_invocations.c:61-91).
  - A discard that can't be merged at the end of the shader may be dropped (VM:181-187).

### 11.5 Last-use (`^`) bits (VL:7-28, 114-193)
- Optional. They let the hardware skip register writes, and omitting them is correct.
- If used:
  - Never set the bit on staging sources.
  - Don't set it on a register still read as a staging source by a pending async instruction.
  - On a split 64-bit pair, set both halves or neither.
  - A source overwritten by the same instruction's dest counts as last use.

### 11.6 Register alignment
- Staging vectors of ≥ 2 registers start at an even register, for both reads and writes (RA:340-347, 380-387).
- Every 64-bit source (addresses, the BLEND or TEX descriptor, the atomic address) is an **even/odd register
  pair** or one whole FAU slot (`.w0` of slot k and `.w1` of slot k). LUT 64-bit sources must have hi = LUT0
  (VP:46-66; VS:7-14). Mixed register/FAU pairs are illegal; Mesa inserts collects.
- A vector must not cross r15→r48 in 32-register mode (RA:296-319).

### 11.7 FAU and immediate limits per instruction (VV:10-153)
- At most **one 64-bit uniform slot**.
- At most **64 bits of distinct FAU and LUT values** in total (two 32-bit words).
- At most **one special** value.
- One page per instruction.
- Non-message ALU instructions, **including ATEST and BLEND**, cannot combine a uniform with a special.
- Message instructions (except ATEST and BLEND) may use two FAU indices and have no LUT limit.
- Message-unit instructions, including ATEST and BLEND, may not use page-3 specials (lane_id, core_id, pc) or
  warp_id.
- Fix violations by moving the value into a register first (VV:156-175).

### 11.8 Padding and alignment
- After each program, append zeros up to `ALIGN(size+16, 128)` bytes (VP:1225-1239).
- The driver uploads with 128-byte alignment (GS:314-317).
- Bifrost's 128-byte prefetch rule (BC:31) is not applied on Valhall. The +16 zero instruction is just a
  separator.

---

## 12. `pan_shader_info` checklist (PC:426-570; PCC:210-322; BC:4663-4757)

| field | VS | FS | CS | how Mesa computes it / driver use |
|---|---|---|---|---|
| `stage` | ✓ | ✓ | ✓ | MESA_SHADER_* |
| `work_reg_count` | ✓ | ✓ | ✓ | **32** if allocation fits in r0-r15 plus r48-r63 (that is the 32-register mode, *not* r0-r31), else **64** (RA:427-438, 1279-1298). The driver uses `≤32 → 32_PER_THREAD`, else 64 (LS:31-38) |
| `preload` | ✓ | ✓ | ✓ | §1.2 |
| `tls_size` | ✓ | ✓ | ✓ | §10 (max over IDVS variants, BC:4707) |
| `wls_size` | | | ✓ | shared bytes |
| `contains_barrier` | | ✓ | ✓ | CS: any barrier. **FS: true if derivatives or implicit-LOD texturing are used** (`needs_coarse_quad_helper_invocations`), which sets `requires_helper_threads` (PCC:217-218, 276; nir_gather_info.c:913-934, 958-967; GC:4500-4501) |
| `writes_global` | ✓ | ✓ | ✓ | any memory store or atomic. Disables FPK-be-killed and forces late kill (GJ:614-616; pan_earlyzs.c:79-82) |
| `outputs_written` | ✓ | ✓ | | VS: VARYING_BIT_*. FS: FRAG_RESULT bits. **FS `render_target_mask = outputs_written >> FRAG_RESULT_DATA0`** (GJ:618-629). DATA0 = 4 |
| `ftz_fp16/32` | ✓ | ✓ | ✓ | on v9, fp16 ftz implies fp32 ftz (PCC:308-321). Maps to SHADER_PROGRAM ftz mode (GC:4418-4433) |
| `ubo_count` | ✓ | ✓ | ✓ | `num_ubos`, including the sysval UBO and gaps |
| `ubo_mask` | ✓ | ✓ | ✓ | UBOs needing a real descriptor (non-pushed access). Bit per shader index. Dynamic index → ~0 (PU:164-187; BN:1311) |
| `texture_count`, `sampler_count` | ✓ | ✓ | ✓ | `BITSET_LAST_BIT(textures_used)` (PCC:305-306). Sizes the texture table (GC:1942) |
| `images_used`, `attribute_count`, `attributes_read(_count)` | ✓ | ✓ | ✓ | PCC:222-225, 296-301 (not read by v9 Gallium) |
| `fau` | ✓ | ✓ | ✓ | §8.4-8.5. `max=128`, `reserved=0` |
| `varyings.formats` | ✓ | ✓ | | VS: full layout, `known=FORMAT\|LAYOUT`, `generic_size_B` (§5.3). FS: format registry with `known` including FORMAT, `count`, slot i = LD_VAR index (CV:338-411). **Gallium asserts these** (GC:3108-3109) |
| `varyings.noperspective` | | ✓ | | §4.5 |
| `vs.*` | ✓ | | | §5.7 |
| `fs.writes_depth/stencil/coverage` | | ✓ | | from outputs |
| `fs.can_discard`, `fs.sidefx` | | ✓ | | sidefx = writes_memory \|\| discard |
| `fs.early_fragment_tests` | | ✓ | | Metal `[[early_fragment_tests]]`. It also drops the ZS_EMIT |
| `fs.can_early_z`, `fs.can_fpk` | | ✓ | | PCC:263-271 |
| `fs.sample_shading` | | ✓ | | uses sample id/pos/sample interpolation → per-sample evaluation (GJ:631-633) |
| `fs.outputs_read` | | ✓ | | framebuffer fetch (§3) |
| `fs.untyped_color_outputs` | | ✓ | | §2.4 |
| `fs.reads_frag_coord / face / point_coord / primitive_id` | | ✓ | | PCC:278-288 (v9 Gallium doesn't use them) |
| `bifrost.blend[rt].type`, `blend_src1_type` | | ✓ | | §2.4. `return_offset = 0` |
| `bifrost.uses_flat_shading`, `uses_ld_var` | | ✓ | | §4.1 |
| `bifrost.wait_6/7`, `messages[]` | | | | v7 only. Leave 0 |
| `cs.allow_merging_workgroups` | | | ✓ | §6 |
| `separable` | ✓ | ✓ | | separate_shader |
| `has_shader_clk_instr` | ✓ | ✓ | ✓ | LD_GCLK used |
| `stats`, `stats_idvs_varying` | | | | debug only |

---

## 13. Pitfalls a from-scratch compiler will hit

### Missing instructions and ISel rewrites (VI:12-137; ISA list)
- There is no FMUL (`FMA x,y,-0.0`, BC:2876-2878) and no FSUB (`FADD` with `.neg`).
- No integer min/max (use `CSEL` with tied operands, ISA:907-913). No fsign or isign.
- No plain `ICMP`/`FCMP`: use `ICMP_OR/FCMP_OR a,b,0` (VI:16-58). Integer `CSEL` must be `.u32`/`.s32`, never
  `.i32` (VI:60-68).
- No JUMP (use `BRANCHZ.eq 0`). `AXCHG`/`ACMPXCHG` are `ATOM_RETURN` with `axchg` (VI:80-104).
- No integer divide: Mesa uses `nir_lower_idiv` (fp-based) (BN:1066-1070). No mul_high (BN:1073).
- 64-bit integer ops other than `IADD/ISUB.u64` and shifts are lowered (bifrost_compile.h:119). There is no
  fp64.
- f32→f16 conversion is `FADD.f32 x, -0.0` with an f16 rounding mode (BC:256-274). Use `V2F32_TO_V2F16` for
  pairs.
- `FRCP`, `FRSQ`, `FEXP` and `FLOGD` are native on G57. The approximation fallbacks are G71-only quirks
  (bi_quirks.h:31-40).
  - sin/cos: `FSIN_TABLE`/`FCOS_TABLE` with a Taylor correction (BC:2544-2582).
  - exp2: `F32_TO_S32` of `x·2^24`, then `FEXP` (BC:2452-2465).
  - log2: `FLOGD` + `FREXPE` (BC:2501-2508).

### Swizzles (bi_lower_swizzle.c:16-90; VP:221-242, 626-680)
- 16-bit sources with a swizzle field accept only h00, h10, h01 and h11.
- 32-bit swizzle sources accept only widen h0 and h1.
- Many ops have no swizzle field at all; emit MKVEC or a shift instead.
- `.neg`/`.abs` only exist on sources marked absneg. An illegal one is an encoding fault (VP:635-644).

### Derivatives (BC:1488-1553)
- fine ddx: `right = CLPER.i32(x, lane=1, xor, subgroup4)`, `d = right - x`. Then flip the sign:
  `d ^= (lane_id & 1) << 31` (for ddy, `(lane_id & 2) << 30`).
- coarse: `CLPER(x,0)` and `CLPER(x,axis)`, both with lane op none.
- Inactive lanes read 0 (`inactive_result zero`).
- Derivatives require helper threads, so set `contains_barrier` and keep TEX `skip = 0` when the result feeds
  a derivative.

### Varyings and IDVS
- The FS must never read `VARYING_SLOT_POS` through LD_VAR. Use r59 and LD_VAR_SPECIAL.
- Integer varyings must be flat. 16-bit flat ints are stored as float16 (CV:160-173).
- Every VS output must be stored at the layout's bit size. The layout uses `ncomps` of the widest write.
- The VS must apply the viewport transform and write 1/W (§5.4). Otherwise nothing rasterizes correctly.

### Blending and fragment outputs
- Never keep live values in r0–r15 or r48 across a BLEND.
- Put the coverage in r60 for ATEST, ZS_EMIT and BLEND.
- Every FS must emit ATEST, even with no colour outputs.

### FAU pushing
- Pushing UBO0 words is only legal when the bound UBO0 is a **CPU user buffer** (GC:1631-1640). Otherwise
  use `LD_PKA` and set `ubo_mask`.
- Blend constants must be FAU words 0-3 in the FS (§8.5).

### Sysvals
- Requesting any sysval shifts user UBOs ≥ 1 by one (§9). Fragment shaders in Mesa always do this.

### Encoding sizes
- `LD_VAR_BUF_IMM` reaches only byte offsets < 256 on v9. Beyond that, use the LD_VAR descriptor path
  with `uses_ld_var`.
- `LD_ATTR_IMM`, `LD_TEX_IMM` and `LEA_TEX_IMM` take an index < 16. LD_VAR_IMM takes < 256.

### Pairs and scratch
- Load/store addresses must be even register pairs. The high word of TLS/WLS addresses must not carry.
- Scratch accesses must not cross 16-byte boundaries on v9.

### Indirect dispatch
- `num_workgroups` is patched in only one place (§6).

### Base instance
- `instance_id` (r61) is zero-based, and v9 Gallium does not apply base_instance to instanced attributes.
  Handle it in the shader.
