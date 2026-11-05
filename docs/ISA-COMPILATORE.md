# Compilatore diretto AIR → Valhall (Mali-G57 MC2, v9)

Implementazione di `docs/ANALISI-ISA-DIRETTA-2026-11-04.md`. Tutto opt-in: `VMG_ISA=1` (spento = tutto come prima,
AIR → NIR → Panfrost). Nessuna rappresentazione intermedia di Mesa (né NIR né BIR) nel percorso di compilazione:
l'LLVM IR di AIR viene tradotto direttamente in istruzioni Valhall (opcode della descrizione ISA di Arm), poi
allocazione registri, flow control e codifica sono nostri. A Gallium arriva solo un nir_shader "guscio" (stadio e
bit di I/O, nessun codice) che la patch Mesa 0006 riconosce e sostituisce col binario precompilato.

ABI hardware usata: `docs/ISA-ABI-V9.md` (estratta dal codice di Panfrost/Bifrost, con citazioni).

## File (`driver/isa/`)

| File | Cosa fa |
|---|---|
| `gen_va_v9.py` → `va_v9_gen.[ch]` | tabelle di codifica generate da `mesa/src/src/panfrost/compiler/kraid/isa-v9-v14.xml` (Arm Ltd, MIT): 366 istruzioni v9, campi, enum, campi calcolati |
| `va_encode.[ch]` | encoder (campi fissi, impostati, calcolati, default; controlli di range) |
| `vi.h`, `vi_core.c` | IR macchina: istruzioni Valhall + registri virtuali (immagine in registro = immagine in memoria) |
| `vi_sel*.c` | selezione da AIR: `vi_sel.c` (valori, costanti, CFG in RPO, phi, switch), `_alu` (E1-E13), `_mem` (C1-C10), `_tex` (D1-D9), `_io` (B1-B11, FAU, sysval), `_sg` (F1-F4, derivate E12) |
| `vi_opt.c` | if-conversion, fusione blocchi, copy propagation per parola, DCE, fusione FMUL+FADD → FMA, split dei vettori, scheduling (spostamento tra blocchi control-equivalenti + list scheduler bottom-up per pressione) |
| `vi_ra.c` | liveness per parola, linear scan (ordine r0-r15, r48-r63, poi r16-r47 → 32/64 registri), precolorati, clobber dei BLEND, spill in TLS |
| `vi_flow.c` | slot dei messaggi, attese (scoreboard), wait0126/ATEST, BLEND, BARRIER, reconverge, end, discard delle helper |
| `vi_pack.c` | costanti (tabella hardware, FAU, registri), prologo blend shader, layout, offset dei salti, codifica, padding |
| `vmg_isa.c` | opzioni/toggle, compilazione (3 programmi IDVS per il vertice), `pan_shader_info`, guscio NIR, hook, cache, statistiche |
| `test/core_test.c` | test del nucleo (RA, flow, pack) con il disassemblatore di Mesa |

Altro: `mesa/patches/0006-panfrost-precompiled-shader.patch` (hook `pan_isa_hooks.h`), `driver/vmg_air.c`
(`vmg_air_module_load`: A1 condiviso), `driver/vmg_screen.c` (percorso ISA in `vmg_shader_create`, cache A9,
varianti B7), `driver/metal/VMDevice.m` (`VMG_ISA_STRICT`: pipeline non creata se il percorso ISA fallisce),
`driver/vmg_shm_stats.h` v2 (contatori ISA, product id GPU).

## Variabili

`VMG_ISA=1` acceso; `VMG_ISA_NO_<ID>=1` funzionalità sul percorso NIR; `VMG_ISA_ONLY=<ID,...>` solo quelle (più
l'infrastruttura A*); `VMG_ISA_STRICT=1` un ripiego è un errore; `VMG_TRACE_ISA=1|<funzione>` IR e disassemblato.
Strumenti: `VMG_PRECOMPILE=1` (i fragment shader NIR compilati subito, per `BIFROST_MESA_DEBUG=shaders,internal`
e `MESA_SHADER_CACHE_DISABLE=true`: confronto col codice di Mesa).

## Stato (2026-11-05)

Tutte le funzionalità A1-G4 di §4 hanno un percorso ISA, un toggle `VMG_ISA_NO_<ID>` e almeno un caso di test
(`driver/tests/isa_cases.m`, 89 casi; `isatest` da riga di comando, sezione "Test ISA" in Viva Manager).

Copertura sul Mac (Panfrost su mock, `VMG_ISA_STRICT=1`, anche sotto AddressSanitizer): QuartzCore 141/141,
RenderBox 47/47 (compreso lo shader che fa crashare chronod sul percorso NIR, G1), corpus metal-shim 10/10,
kernel 22/22 + 11/11, test ISA 143 funzioni su 143. Il mock non esegue i job: la correttezza dei risultati è
verificata solo strutturalmente (encoder contro i casi di test di Mesa e il suo disassemblatore, codice confrontato
con quello di Mesa sugli stessi shader). **La verifica vera è `isatest` sul telefono.**

Soluzioni scelte per le lacune:
- G2: `dispatchThreadsPerTile` chiude la pass (conservando gli attachment), esegue il tile kernel come compute
  (un threadgroup per tile; imageblock = load/store sulle immagini degli attachment, slot `VMG_TILE_IMAGE_BASE`),
  riapre la pass in load (`vmg_cmd_dispatch_tile`). Corretto ma costoso; il device resta Apple3, quindi
  CoreAnimation non lo usa.
- G3: puntatori device/constant letti dalla memoria (argument buffer, `gpuAddress` ora restituisce l'indirizzo GPU
  vero) → LOAD/STORE globali a 64 bit. Texture e sampler dentro argument buffer: non gestiti.
- G4: `newVisibleFunctionTableWithDescriptor`, `functionHandleWithFunction`, `setVisibleFunctionTable`; la voce è
  l'indice della funzione collegata + 1; la chiamata indiretta diventa una scelta tra le funzioni collegate
  (inlined), che l'if-conversion trasforma spesso in codice lineare.

Limiti noti: allocatore lineare (alcuni shader a 64 registri dove Mesa ne usa 25-32; il blur `asg_frag_lpf` ha
1 spill); D9 senza fusione TEX_DUAL; nessuna misura di prestazioni.

Bug del driver esistente trovati lungo la strada: texture buffer dimensionati in texel invece che in byte (overflow
dell'heap a ogni copia: corretto in `texture_template`); puntatori di sampler non più validi rimasti legati tra un
command buffer e l'altro (`bind_stage`, non corretto); `phase3`/`translate` crashano già a HEAD con llvmpipe sul Mac.
