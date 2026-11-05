# Analisi 2026-11-04: dalla traduzione AIR → NIR alla compilazione diretta in ISA Mali (Valhall v9)

Domanda: passare gradualmente da AIR → NIR → compilatore Valhall di Mesa a una compilazione diretta AIR → ISA del
Mali-G57, senza rompere nulla. Servono: (1) la lista completa delle funzionalità da portare, (2) la priorità, basata
sulle misure fatte finora, di quale pesa di più sugli fps a causa della traduzione, (3) le fonti pubbliche sull'ISA
del G57 e i riferimenti di Mesa che compilano NIR in ISA Mali.

Base: `driver/vmg_air.c` (traduttore, 2459 righe), `driver/vmg_screen.c` (creazione shader e varianti), Mesa 26.2.6
in `mesa/src`, misure in `FINDINGS-2026-11-03.md`, `ANALISI-CPU-E-PAGINE-2026-11-04.md`, `ANALISI-KERNEL-RENDERING.md`.
Le stime sono segnate come tali.

## 0. Prima di tutto: cosa dicono le misure (da leggere prima della lista)

- **Impostazioni (scroll)**: catena in serie, GPU occupata **37%**, intervallo = somma di render CA (8,6 ms) + GPU
  (17,1 ms) + attesa frame end (9,0 ms). Il limite è latenza e CPU, non il codice degli shader. Un compilatore ISA
  migliore qui dà **circa 0 fps** finché la catena resta in serie (stima).
- **Home (swipe)**: GPU occupata **76%**, circa 21 ms di GPU per frame. Qui il codice degli shader conta. Ma
  `passbench` dice che buona parte di quei 21 ms sono load+store dei pass (2,9-3,6 ms ciascuno, 4 segmenti per frame
  per i blur di sfondo): è lavoro a funzione fissa (tile buffer ↔ memoria), che nessun compilatore cambia. La parte
  attribuibile agli shader è quindi una frazione dei 21 ms (stima: 5-9 ms, da misurare, vedi §2.0).
- **L'unica misura diretta di un costo "da traduzione"** è il push window: leggere una costante da un buffer (SSBO)
  in ogni frammento portava un draw a tutto schermo da 0,76 a 1,3 ms; con il push in FAU passbench è sceso da 15,3 a
  9,4 ms e sulla home il job medio da 1229 a 1112 µs (GPU done 36 → 29 ms).
- **Il costo indiretto più grande** viene da un bug del compilatore, non dalla qualità del codice: `chronod` va in
  crash loop in `bi_emit_alu.cold.1` e `launchd` + `ReportCrash` consumano 3-4,7 s di CPU ogni 11 s. Ruba CPU proprio
  alla catena seriale di Impostazioni.

Conclusione pratica: la compilazione diretta ha senso per (a) controllare dove vanno costanti e risorse (FAU, push),
(b) il percorso frammento su una GPU piccola (uscite, framebuffer fetch, HSR), (c) eliminare i crash e le lacune del
compilatore, (d) togliere la compilazione a ogni avvio. Non è la leva per gli fps di Impostazioni: lì contano
ancora CPU (DVFS 0145, A76) e la catena dei frame.

## 1. Architettura consigliata per un passaggio senza rotture

### 1.1 Il punto di innesto (seam)

Oggi: `vmg_shader_create` → `vmg_air_translate` (AIR → NIR) → `create_{vs,fs,compute}_state` di Panfrost →
`panfrost_shader_compile` (`gallium/drivers/panfrost/pan_shader.c:95`) → `pan_shader_compile` → Bifrost/Valhall
(o Kraid, se compilato) → binario + `struct pan_shader_info` (`panfrost/compiler/pan_compiler.h:426`).

Il nuovo compilatore deve produrre **le stesse due cose**: il binario e una `pan_shader_info` corretta (registri
usati, preload, TLS/WLS, flag del frammento per early-Z/FPK/HSR, IDVS e varyings per il vertice, intervalli di FAU
spinti). Il resto del driver Gallium (descrittori RSD, attributi, blend, job) resta quello di Panfrost.

Serve una patch Mesa nuova (`0006-panfrost-precompiled-shader.patch`): in `panfrost_shader_compile`, prima di
`pan_shader_compile`, una callback del driver vmg che, dato lo shader e la `panfrost_shader_key` (Panfrost compila
varianti per chiave: `rt_formats`, `nr_cbufs_for_fragcolor`, sprite coord, clip plane, `noperspective_varyings`,
`is_xfb`), restituisce binario + info, oppure "non supportato". È lo stesso schema per stadio che Mesa usa già per
Kraid (`pan_use_kraid()` in `compiler/pan_compiler.c:54`, `PAN_USE_KRAID=fs,vs,cs`).

### 1.2 Ripiego per funzione, come il push window di oggi

Per ogni funzione Metal: si prova il percorso ISA; se una qualunque operazione non è supportata **o è disattivata
dal suo toggle**, quella funzione intera passa da AIR → NIR → Panfrost come oggi. È lo stesso schema di
`vmg_air_translate`, che già ritraduce una funzione senza push se un puntatore spinto si mescola con un altro.
Nessuno shader resta mai senza codice: la copertura cresce funzione per funzione.

### 1.3 Come costruirlo (in ordine di rischio)

1. **AIR → BIR** (consigliato come primo passo): tradurre l'LLVM IR direttamente nell'IR del back-end Bifrost di
   Mesa (`bi_builder.h`, `bi_instr`) invece che in NIR, e riusare RA, scheduling, inserimento del flow
   (`va_insert_flow.c`), costanti (`va_lower_constants.c`) e packing (`va_pack.c`). Si salta NIR senza riscrivere
   subito un allocatore di registri. È C, nello stesso processo, compila per iOS come oggi.
2. Poi sostituire pezzo per pezzo i passi che limitano (selezione delle istruzioni, FAU, RA con meno di 32 registri
   per avere più thread). Encoder generato dalla descrizione ISA di Arm (`kraid/isa-v9-v14.xml`, §3.1).
3. **Alternativa da valutare subito, a basso costo**: Kraid (NIR → ISA in Rust, già nel nostro Mesa 26.2.6, default
   in Mesa 27.0). Non è "diretto da AIR", ma dice quanto vale un back-end ISA migliore *prima* di scriverne uno.
   Richiede `-Dpanfrost-rust=true` (ora spento) e quindi Rust cross-compilato per arm64-apple-ios: da verificare.

## 2. Requisito: ogni funzionalità porta con sé un test e un toggle in Viva Manager

Ogni voce della §4, quando passa al percorso ISA, deve arrivare insieme a due cose nell'app Viva Manager (`gpu/app`).
Senza queste due cose la funzionalità non è considerata portata.

### 2.1 Sezione di test con pannello

- Nuova sezione **"Test ISA"** in Viva Manager, una riga per funzionalità (ID della §4, es. `D3 gather`).
- Ogni riga apre un **pannello** (es. 256×256) disegnato con una pipeline Metal minima il cui shader usa *solo*
  quella funzionalità, compilata **forzatamente sul percorso ISA**.
- Accanto, la stessa immagine calcolata **dalla CPU** (implementazione di riferimento in C della stessa formula) e
  quella del percorso NIR. Sotto: mappa delle differenze, errore massimo, percentuale di pixel fuori tolleranza,
  esito (ok/ko). Così si vede subito se il codice ISA calcola la cosa giusta, sul Mali vero.
- Riga di tempi: ms GPU per draw con ISA e con NIR (come `passbench`), per avere anche l'A/B di prestazioni.
- Gli stessi casi girano anche da riga di comando (test `isa` in `viva-tests`, stile `compute`/`phase3`), così si
  possono lanciare via link senza toccare lo schermo.
- Nota d'interpretazione: ho inteso "renderizzato dalla CPU" come riferimento calcolato dalla CPU affiancato
  all'uscita GPU del codice ISA. Se intendevi altro (es. il pannello disegnato direttamente dalla CPU invocando
  quel codice), va corretto qui.

### 2.2 Toggle per singola funzionalità (A/B veloce)

- Un gruppo **"Compilatore ISA (AIR → Valhall)"** in `app/Resources/malimetal-flags.json`, scritto in `vmg.env` come
  gli altri flag:
  - `VMG_ISA=1`: interruttore generale (spento = tutto come oggi);
  - `VMG_ISA_NO_<ID>` per ogni funzionalità (es. `VMG_ISA_NO_D3`, `VMG_ISA_NO_C2`): disattivata = ogni shader che la
    usa torna al percorso NIR (§1.2);
  - `VMG_ISA_ONLY=<ID,...>` per bisezione: solo quelle sul percorso ISA.
- I toggle devono entrare nella chiave della cache di traduzione (oggi blake3 include già "le variabili che il
  traduttore legge"), altrimenti un A/B legge binari vecchi.
- Applicazione: i processi nuovi li vedono subito; backboardd con `vctl kill backboardd` (~30 s), come oggi.
- Contatori in "Statistiche MaliMetal" (pagine `/private/var/tmp/vmg-stats/<pid>`): funzioni compilate in ISA,
  ripieghi su NIR con il motivo (prima operazione non supportata), tempo di compilazione.

## 3. Fonti

### 3.1 ISA del Mali-G57 (Valhall, arch v9)

Arm non pubblica un manuale dell'ISA Mali. Le fonti pubbliche sono:

| Fonte | Cosa contiene | Dove |
|---|---|---|
| **`isa-v9-v14.xml`** (Copyright 2026 **Arm Ltd**, MIT, "autogenerated") | descrizione completa delle istruzioni v9 (G57 = v9.0, file `major=9 minor=0 patch=12`): 603 istruzioni/varianti, campi con posizione e larghezza, unità di esecuzione, staging register, slot dei messaggi. **La fonte più autorevole che esiste**, fornita da Arm a Mesa per Kraid | `mesa/src/src/panfrost/compiler/kraid/isa-v9-v14.xml` (anche `isa-v15.xml`); generatore `kraid/tools/isa-gen.rs` |
| `valhall/ISA.xml` | descrizione da reverse engineering (Collabora, 2021), quella usata dal back-end C attuale | `mesa/src/src/panfrost/compiler/bifrost/valhall/ISA.xml`, `valhall.py`, `asm.py`, `disasm.py`, casi in `valhall/test/assembler-cases.txt` |
| Documentazione dell'ISA Valhall in PDF + assembler/disassembler | risultato del reverse engineering sul Mali-G78 (stessa ISA v9) | [Collabora: Reverse engineering the Mali G78](https://www.collabora.com/news-and-blog/news-and-events/reverse-engineering-the-mali-g78.html), [CNX: Valhall instruction set documentation](https://www.cnx-software.com/2021/07/23/mali-g78-gpu-valhall-instruction-set-documentation-reverse-engineering/) |
| Valhall su G57 in Panfrost (GLES 3.1 conforme) | dettagli tecnici del supporto G57 | [Collabora: Conformant open source support for Mali-G57](https://www.collabora.com/news-and-blog/news-and-events/conformant-open-source-support-for-mali-g57.html), [Phoronix](https://www.phoronix.com/news/Mali-G57-Conformant-GLES-3.1) |
| Kraid (nuovo compilatore Valhall in Rust) | progetto, modello dei registri, stato | [Collabora: Kraid, a new compiler for Panfrost](https://www.collabora.com/news-and-blog/news-and-events/kraid-a-new-compiler-for-panfrost.html), [Kraid is now a real compiler](https://collabora.com/news-and-blog/news-and-events/kraid-is-a-now-a-real-compiler.html), [Phoronix: merged in Mesa 26.2](https://phoronix.com/news/KRAID-Merged-To-Mesa), [Phoronix: default in Mesa 27.0](https://phoronix.com/news/Mesa-27.0-Goes-Kraid) |
| Descrittori hardware v9 (non ISA ma necessari: texture, sampler, attributi, RSD, blend) | XML dei descrittori + decoder | `mesa/src/src/panfrost/genxml/v9.xml`, `decode_jm.c` (pandecode) |
| Documentazione Mesa Panfrost | varyings, tiling, instancing, benchmark | `mesa/src/docs/drivers/panfrost.rst`, `docs/drivers/panfrost/*.rst` |
| Arm Mali Offline Compiler (Arm Performance Studio) | stima statica dei cicli per shader su Mali-G57 (da GLSL/SPIR-V), utile come termine di confronto, non dà l'ISA | [Arm community: Mobile Studio 2020.2](https://community.arm.com/developer/tools-software/graphics/b/blog/posts/game-cost-budgeting-and-more-with-mobile-studio-2020-2) |
| Contatori di prestazione del G57 | riferimento Arm dei contatori hardware (per misurare il costo vero degli shader) | "Mali-G57 Performance Counters Reference Guide" su developer.arm.com; libreria `libGPUCounters` di ARM-software |

### 3.2 Riferimenti di Mesa che compilano NIR in ISA Mali (tutti nel nostro albero, Mesa 26.2.6)

Ingresso e ABI:
- `src/panfrost/compiler/pan_compiler.c` / `.h`: scelta del back-end per architettura e stadio (`pan_use_kraid`,
  `PAN_USE_KRAID`), `pan_preprocess_nir`, `pan_postprocess_nir`, **`struct pan_shader_info`** (contratto da
  rispettare), `pan_stats`.
- `src/gallium/drivers/panfrost/pan_shader.c`: `panfrost_shader_compile`, varianti e chiavi; `pan_context.h`:
  `panfrost_fs_key`, `panfrost_vs_key`; `pan_cmdstream.c`: FAU, push delle costanti, RSD; `pan_blend_cso.c` e
  `pan_fb_preload.c`: shader interni (blend, preload) che restano su Mesa.
- `src/panfrost/lib/pan_shader.h`, `pan_blend.c`, `pan_earlyzs.c` (tabella early-Z/FPK dai flag dello shader).

Back-end C attuale (Bifrost + Valhall):
- `compiler/bifrost/bifrost_compile.c`: selezione delle istruzioni da NIR (`bi_emit_alu`, texture, I/O, atomiche);
  è qui il crash di chronod.
- `bifrost_nir.c`, `bifrost_nir_algebraic.py`: lowering NIR specifici; `bi_opt_push_ubo.c` (cosa va in FAU),
  `bi_opt_dual_tex.c`, `bi_helper_invocations.c`, `bi_opt_*` (copy prop, CSE, DCE, constant fold, mod props).
- RA e scheduling: `bi_ra.c`, `bi_ra_ssa.c`, `bi_spill_ssa.c`, `bi_lower_spill.c`, `bi_pressure_schedule.c`,
  `bi_liveness.c`.
- Valhall: `valhall/va_lower_isel.c`, `va_lower_constants.c`, `va_lower_split_64bit.c`, `va_optimize.c`,
  `va_insert_flow.c`, `va_merge_flow.c`, `va_mark_last.c`, `va_gather_hsr_info.c`, `va_validate.c`, `va_pack.c`
  (encoder), `va_perf.c` (stima statica dei cicli per unità), test in `valhall/test/`.
- Lowering comuni: `compiler/pan_nir_lower_*.c` (framebuffer, fs inputs/outputs, image, image_ms, tex,
  sample_position, vertex_id, vs_outputs, xfb, noperspective, helper_invocation, mem_to_global), `pan_nir_collect_varyings.c`.

Kraid (Rust, NIR → ISA, v9 e successive):
- `compiler/kraid/nir.rs` (selezione da NIR, con l'elenco esplicito di ciò che non supporta), `encode_v9.rs`
  (encoder dalla XML di Arm), `isa.rs`, `ra.rs`, `flow.rs`, `message_slots.rs`, `model.rs` (modello della GPU),
  `small_constants.rs`, `remat_constants.rs`, `legalize*.rs`.
- `kraid/hw_runner/`: esegue shader sul ferro per i test (idea da riprendere per i test di §2.1).

Fuori da questo albero: PanVK (`src/panfrost/vulkan`, stesso compilatore), driver kernel Linux
`drivers/gpu/drm/panfrost` (ABI dei job JM), repository [Mesa su freedesktop](https://gitlab.freedesktop.org/mesa/mesa).

## 4. Lista completa delle funzionalità da portare

Ricavata riga per riga da `vmg_air.c` e `vmg_screen.c`: tutto quello che il traduttore gestisce oggi, più quello che
Panfrost fa dopo di lui e che il percorso ISA deve rifare. "Stato" = cosa fa il percorso attuale.

### A. Infrastruttura (prerequisiti, nessuna funzionalità parte senza)

| ID | Funzionalità | Oggi | Note per l'ISA |
|---|---|---|---|
| A1 | Lettura del bitcode, linking delle visible function, inlining forzato, pulizia LLVM (`inline,sroa,early-cse,instcombine,dse,adce,simplifycfg`) | libLLVM di sistema (~LLVM 11, PM legacy) | si tiene uguale: è a monte di NIR |
| A2 | SSA, phi, CFG non strutturato → strutturato (`nir_lower_goto_ifs`), ritorni | NIR | Valhall vuole flusso strutturato e riconvergenza; serve un passo di strutturazione proprio |
| A3 | Allocazione registri (64 registri; ≤32 = doppia occupazione), spill in TLS | Bifrost RA | influisce sull'occupazione: misurare `work_reg_count` dei 24 shader di CA |
| A4 | Scheduling e bit di flow (attese sugli slot dei messaggi, `.return`, `discard`), `mark_last` | `va_insert_flow`/`va_merge_flow`/`va_mark_last` | da riusare finché possibile (§1.3) |
| A5 | Encoder | `va_pack.c` | generabile da `isa-v9-v14.xml` |
| A6 | Costanti: immediati, tabella costanti, FAU (uniform a 64 bit) | `va_lower_constants`, `bi_opt_push_ubo` | legato a C2 |
| A7 | ABI con Panfrost: `pan_shader_info` completa (maschera `preload` dei registri precaricati, TLS/WLS, flag FS, IDVS) | Panfrost | contratto §1.1 |
| A8 | Innesto in Mesa con varianti per `panfrost_shader_key`, ripiego per funzione | — | patch 0006 |
| A9 | Cache dei binari ISA su disco | solo AIR → NIR in cache; binari Valhall **ricompilati a ogni avvio** (disk_cache spento nella build iOS) | il percorso ISA mette in cache il binario finale |
| A10 | Diagnostica: disassemblato (`VMG_TRACE_ISA`), confronto con il percorso NIR, pandecode | `VMG_TRACE_AIR`, `VMG_TRACE_NIR` | |
| A11 | Semantica fast math: costanti NaN = 0 sotto `no-nans-fp-math`, `ffma` esatto vs debole | `vmg_air.c` | |

### B. Stadi, ingressi e uscite

| ID | Funzionalità (AIR) | Oggi (NIR / Panfrost) |
|---|---|---|
| B1 | `air.vertex_input` (location) | variabili input → attributi Panfrost (descrittori dai vertex element) |
| B2 | `air.vertex_id`, `instance_id`, `base_vertex`, `base_instance` | system value + `pan_nir_lower_vertex_id` |
| B3 | `air.position`, `vertex_output` (chiavi dei varying), `point_size`, `clip_distance` | output → IDVS (shader posizione + shader varying), `pan_nir_lower_vs_outputs`, layout varyings |
| B4 | `air.fragment_input` con `flat`, `no_perspective`, `centroid`, `sample` | `pan_nir_lower_fs_inputs`, chiave `noperspective_varyings` |
| B5 | `air.position` (frag coord), `front_facing`, `point_coord`, `sample_id`, `sample_mask` in, `get_num_samples` (sysval) | system value / `nir_lower_sysvals_to_varyings` |
| B6 | `air.render_target` uscita (tipi, indice), `air.depth`, `air.sample_mask` out; blend dual source (fattori SRC1) | `pan_nir_lower_fs_outputs`, ATEST/BLEND/ZS_EMIT nel back-end |
| B7 | Varianti senza le uscite che non hanno attachment (`fs_variant`) | clone NIR + `drop_color_outputs` a creazione pipeline |
| B8 | `air.discard_fragment` | `nir_terminate`; spegne early-Z/FPK |
| B9 | Framebuffer fetch: `air.render_target` come **ingresso** (CA: maschera di clip nel 2° attachment memoryless) | `pan_nir_lower_framebuffer` → LD_TILE; flag HSR |
| B10 | Compute: `thread_position_in_grid`, `..._in_threadgroup`, `threadgroup_position_in_grid`, `threadgroups_per_grid`, `threads_per_threadgroup`, `threads_per_grid` (sysval), `thread_index_in_threadgroup`, simdgroup/quadgroup index e dimensioni | system value + `nir_lower_compute_system_values` |
| B11 | Guardia `dispatchThreads` (thread oltre la griglia), `workgroup_size_variable` | inserita dal traduttore |

### C. Memoria

| ID | Funzionalità | Oggi |
|---|---|---|
| C1 | `[[buffer(n)]]` device/constant come SSBO; aritmetica dei puntatori (GEP), puntatori in select/phi | SSBO 0-30, LD_PKA nativo (v9) |
| C2 | **Push window**: buffer constant piccoli (`air.buffer_size`, 256 B in tutto) in cb0 dopo i sysval → FAU | `VMG_NO_PUSH`; ripiego dell'intera funzione se un puntatore spinto si mescola |
| C3 | Header sysval (192 B in cb0: griglia, sample count, ecc.) | `sysval_word` |
| C4 | Constant pool (globali costanti) in UBO 1 | `pool_buffer` |
| C5 | Memoria threadgroup (address space 3, `air.threadgroup`) | shared / WLS |
| C6 | Memoria privata (`alloca`) → registri o scratch | vars → SSA, scratch TLS |
| C7 | Load/store di aggregati (struct, array), allineamenti | `load_typed`/`store_typed` |
| C8 | `llvm.memcpy`, `memmove`, `memset` | `memcpy_set` |
| C9 | Atomiche `air.atomic.*`: add, sub, and, or, xor, min/max (s/u), xchg, cmpxchg, load, store; su device e threadgroup | `nir_atomic_op_*` |
| C10 | Barriere: `air.wg.barrier`, `air.mem_barrier`, `air.simdgroup.barrier`, `fence` | `barrier()` |

### D. Texture e sampler

| ID | Funzionalità | Oggi |
|---|---|---|
| D1 | `sample_*` 1d/2d/3d/cube/array, bias, lod, `_grad`, offset, min lod | `nir_tex_instr` → TEX_SINGLE/TEX_GRADIENT |
| D2 | `sample_compare` (depth, shadow) | tex con comparator |
| D3 | `gather` e `gather_compare` (componente, offset) | tg4 |
| D4 | `read_*` (txf, txf_ms), cube letti come 2D array, texture buffer | TEX_FETCH |
| D5 | `write_*` e `read_write` (image store/load), anche MS | `nir_image_*` + `pan_nir_lower_image*` |
| D6 | Query: width/height/depth/array_size, `get_num_mip_levels`, `get_num_samples` | txs, query_levels, texture_samples |
| D7 | Sampler legati (slot 0-15) e **constexpr** (dallo slot 16), `coord::pixel`, `get_read_sampler` | sampler Gallium creati dallo shader |
| D8 | Tipi dei risultati (float/int/uint, half), depth = un canale | `tex_result` |
| D9 | Coppie di texture fuse (dual tex) | `bi_opt_dual_tex` |

### E. ALU e libreria matematica

| ID | Funzionalità | Oggi |
|---|---|---|
| E1 | Aritmetica LLVM intera e float: add/sub/mul, udiv/sdiv/urem/srem (senza divisore hw), shl/lshr/ashr, and/or/xor, fadd/fsub/fmul/fdiv/frem, fneg, freeze | `binary()` |
| E2 | icmp/fcmp (ordinati/non ordinati), select, booleani a 1 bit | `compare()`, `pan_nir_lower_bool_to_bitsize` |
| E3 | Cast: trunc/zext/sext, fp↔int, fptrunc/fpext (f16↔f32), bitcast, addrspacecast, ptrtoint/inttoptr | `cast()` |
| E4 | Vettori: extract/insert element, shufflevector, swizzle su lane a 16 bit | MKVEC, `bi_lower_swizzle` |
| E5 | **half nativo** (v2f16), `VMG_HALF32` di ripiego | fp16 attivo su Valhall |
| E6 | Trascendenti: sin, cos, tan, asin, acos, atan, atan2, sinh/cosh/tanh, asinh/acosh/atanh, exp/exp2/exp10, log/log2/log10, pow/powr, sqrt, rsqrt | espansi in NIR (`nir_atan2`, fexp2, flog2…) |
| E7 | Funzioni comuni: floor, ceil, trunc, round (lontano da 0), rint/roundeven, fract, sign, saturate, abs (f/i), fma/mad/fmuladd, mix, clamp, step, smoothstep, min/max/min3/max3/median3 (f/s/u), fmod, copysign, ldexp, radians/degrees, isnan/isinf/isfinite/signbit | `math()` |
| E8 | Geometria: dot, cross, length, normalize, distance (fast), reflect, refract | `math()` |
| E9 | Bit: clz/ctlz, ctz/cttz, popcount, reverse_bits, extract_bits/insert_bits (s/u), rotate, mul_hi, add_sat/sub_sat, abs_diff, hadd/rhadd; interi a 64 bit | `math()` + `va_lower_split_64bit` |
| E10 | `air.convert.*` (f/s/u, anche `sat`) | `convert()` |
| E11 | pack/unpack unorm/snorm 4x8 e 2x16, unorm rgb565 | scritti a mano in NIR |
| E12 | Derivate: dfdx/dfdy (coarse/fine), fwidth; helper invocation | ddx/ddy, `bi_helper_invocations` |
| E13 | all/any/select vettoriali | `math()` |

### F. Subgroup e quad (`air.simd_*`, `air.quad_*`)

| ID | Funzionalità |
|---|---|
| F1 | shuffle, shuffle_xor, shuffle_up, shuffle_down |
| F2 | broadcast, broadcast_first, quad_broadcast |
| F3 | riduzioni sum, product, min, max (float/int/uint, anche cluster 4 per quad) |
| F4 | vote all/any, is_first (elect), ballot |

### G. Lacune di oggi (il percorso ISA può coprirle, il percorso NIR no o male)

| ID | Lacuna | Effetto misurato o noto |
|---|---|---|
| G1 | ALU non gestita in uno shader di RenderBox: assert in `bi_emit_alu.cold.1` | chronod in crash loop, widget non disegnati, 3-4,7 s di CPU ogni 11 s per launchd + ReportCrash |
| G2 | Imageblock / tile shading (46 kernel di QuartzCore) | non tradotti; Valhall ha accesso al tile buffer (LD_TILE/ST_TILE, cfr. `panfrost_nir_lower_pls`) |
| G3 | Argument buffer, ICB (`air.indirect_buffer`, VectorKit) | non tradotti (soprattutto modello di binding, poco ISA) |
| G4 | Chiamate indirette a visible function (oggi solo inlining) | — |

## 5. Priorità: cosa rallenta di più gli fps a causa della traduzione

### 5.0 Passo zero (prima di portare qualunque cosa, 1-2 giorni)

Le misure attuali sono per frame e per pass, non per shader. Per ordinare con i numeri servono:
1. **Statistiche statiche per shader** dei 24 shader di CA e di quelli di backboardd: `pan_stats` / `va_perf.c`
   (cicli per unità FMA/CVT/SFU/load-store/texture/varying, registri, thread), stampate da `VMG_TRACE`. Dice quali
   shader sono limitati da cosa.
2. **Peso per shader nella home**: `VMG_TRACE_DRAW` conta già i draw per shader; moltiplicato per area e cicli dà
   la classifica degli shader che costano di più.
3. **Kraid in A/B** (se il build Rust per iOS riesce): `PAN_USE_KRAID=fs` sulla home. Se Kraid non sposta il "GPU
   done" della home, nemmeno un compilatore nostro lo sposterà molto per sola qualità del codice.
4. Tempi di compilazione all'avvio delle app (oggi il binario Valhall non è in cache).

### 5.1 Classifica

| # | Area (ID) | Evidenza | Impatto atteso sugli fps |
|---|---|---|---|
| 1 | **Accesso alle costanti e alle risorse: FAU, push, UBO/SSBO** (C1, C2, C3, C4, A6) | **misurato**: costante da SSBO 1,3 vs 0,76 ms per draw a tutto schermo; home job 1229 → 1112 µs, GPU done 36 → 29 ms col push. Restano: funzioni che ripiegano senza push (puntatori mescolati), buffer > 256 B, dati `setBytes` | **il più alto** sulla home (GPU-bound). Con l'ISA si spinge in FAU tutto ciò che il driver conosce, senza il vincolo "solo UBO 0" di Panfrost |
| 2 | **Bug e lacune del compilatore** (G1, poi G2) | **misurato**: crash loop di chronod, 3-4,7 s di CPU ogni 11 s | alto su Impostazioni (CPU-bound). Attenzione: G1 si corregge anche senza ISA (fix nel lowering o nel traduttore): **da fare subito, a parte** |
| 3 | **Percorso frammento: uscite, framebuffer fetch, discard, flag HSR/FPK/early-Z** (B6, B8, B9, B7) | home GPU-bound al 76%; i draw opachi costano quasi zero solo grazie a HSR; CA legge la maschera di clip con framebuffer fetch, e LD_TILE + `can_fpk` spento disattivano proprio quell'eliminazione | medio-alto sulla home (**non misurato**: va contato quanti draw della home usano fbfetch o discard) |
| 4 | **Tempo di compilazione e varianti** (A9, B7, A8) | binari Valhall ricompilati a ogni avvio; Mac: cache AIR ca 2,32 → 0,15 s; peggior command buffer nelle transizioni 57 ms | non sugli fps a regime, ma sugli scatti di apertura app e di prima visualizzazione |
| 5 | **Texture e sampler** (D1, D7, D9, D2) | i blur di sfondo della home campionano molto (pass da 64×64 a 284×611) | medio-basso (non misurato); Bifrost usa già TEX_SINGLE e la fusione dual tex |
| 6 | **ALU, half, matematica** (E5, E6, E7, E8, E12, E1-E4, E9-E11, E13) | shader di CA semplici; un draw blended a tutto schermo costa 0,76 ms "al meglio" (limite di fill rate, non di ALU) | basso; da rivedere con i cicli di §5.0 (es. blur con pochi registri → più thread) |
| 7 | **Vertice e IDVS** (B1-B3) | CA disegna pochi vertici (quad) | molto basso |
| 8 | **Compute, atomiche, subgroup, barriere** (B10, B11, C5, C9, C10, F1-F4) | non sul percorso dei frame di CA | ~0 per gli fps; necessario per completezza (app, MPS, VectorKit) |
| 9 | **Imageblock, argument buffer, ICB** (G2, G3, G4) | funzioni oggi non eseguite | funzionalità, non fps |

### 5.2 Ordine di porting proposto (ogni passo con test + toggle di §2)

1. Infrastruttura A1-A11 con il sottoinsieme minimo per **uno** shader frammento semplice di CA (es.
   `fixed_frag_lph_cph`): B4, B5, B6, C2, C3, D1, D7, E1-E5, E7. Pannello di test: quel solo shader contro CPU e NIR.
2. Costanti e risorse complete (C1-C4, A6): la voce con il guadagno misurato.
3. Percorso frammento (B7, B8, B9) con flag HSR corretti; misura del GPU done della home.
4. Cache dei binari (A9) e varianti per chiave (A8).
5. Resto di texture (D2-D6, D8, D9), matematica (E6, E8-E13): copre i 24 shader di CA e i 194 di QuartzCore.
6. Vertice (B1-B3), poi compute/atomiche/subgroup (B10, B11, C5-C10, F1-F4).
7. Lacune (G2-G4).

Criterio di avanzamento a ogni passo: test del pannello ok sul telefono, nessuna differenza nelle schermate di
Impostazioni/App Store/home/App Library (blur), A/B col toggle su `ca` e sugli scroll come nelle misure precedenti.
