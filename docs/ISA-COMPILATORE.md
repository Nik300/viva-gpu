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

Limiti noti: allocatore lineare (alcuni shader a 64 registri dove Mesa ne usa 25-32; i blur `asg_frag_lpf` e
`asg_50_frag_lph` hanno 1 e 2 spill: il list scheduler è goloso e non sposta insieme i più consumatori di uno stesso
campione). Pass di pressione: sink (ogni istruzione, anche TEX/LOAD se non attraversa store, scende al primo uso
senza allungare la vita degli operandi; se il risultato ha spill si ricompila senza e si tiene il migliore,
`VMG_ISA_NO_SINK=1` lo spegne): 165 programmi di QuartzCore su 180 a 32 registri (prima 154). Rematerializzazione
opt-in (`VMG_ISA_REMAT=1`, nessun guadagno misurato). `VMG_LLVM_HIDE=nome,...` simula sul Mac il libLLVM più vecchio
di iOS 16 (funzioni opzionali assenti).

Telefono (2026-11-05, `isatest` un caso per processo, driver come da `app/Resources/isa-verified.json`): **percorso ISA
83/89, percorso NIR 74/89, nessun crash**. I 6 KO rimasti sull'ISA falliscono identici anche sul percorso NIR (bug del
driver o dell'hardware, non del compilatore): B3 clip_distance (Valhall non ha piani di clip: andrebbe emulato con un
discard nel fragment shader), D1 min_lod_clamp (il clamp nel registro di bias viene ignorato), D4 read di cube come array,
di texture su buffer e di depth2d, G2 (il tile kernel gira ma le sue scritture non arrivano al pass che riprende). Sul
percorso NIR in più: B5/B6 (frag coord e sample_mask con shading per campione), B10, C9 cmpxchg, D1 lineare e 3D/cube, G3,
G4 (limiti del traduttore NIR, che il percorso ISA colma).

Bug trovati sul telefono e corretti in questa sessione: crash con `LLVMGetNumMaskElements` assente in iOS 16; campo
`align(n)` dell'XML trattato come scala (registri delle destinazioni a 64 bit dimezzati: IADD.u64 dei puntatori, IMUL.u64,
shift a 64 bit); IMUL.u64 con widen fuori specifica (l'encoder ora rifiuta i valori non ammessi dal `restrict` dell'XML);
indice di lane di CLPER che deve essere uniforme (shuffle con indice per thread); handle dei buffer di LEA_PKA/LD_PKA
uniforme (puntatore che sceglie il buffer per thread: anche sul percorso NIR, con `nir_lower_non_uniform_access`); regola
FAU dei 64 bit (al più due parole distinte tra uniform e costanti per istruzione); salto di fallthrough mancante dopo
l'inserimento di blocchi; ordine del risultato di TEX_GATHER; indice di layer come float per TEX_SINGLE/GATHER; coefficiente
mancante di atan; cmpxchg che restituisce il valore vecchio; voti e ballot per quad; operandi emessi dopo l'istruzione che
li legge (`VMG_ISA_CHECK=1` li cerca); sampler constexpr emessi da iOS 16 come semplice i64 (anche NIR); texture su buffer
come vista sul buffer (anche NIR); gather_compare e voti per quad anche sul percorso NIR.

## Prestazioni (2026-11-05 sera): codice alla pari con Mesa sugli shader di CoreAnimation

Sintomo: con `VMG_ISA=1` le animazioni erano più lente che col percorso NIR. Misura sul telefono (swipe della home,
6 andate e ritorno, `disp lat`/`gpu status`): GPU occupata al 96%, un frame ogni **36,5 ms (27 fps)**, job medio 1486 µs,
contro 26,8 ms e 1004 µs del percorso NIR. Il codice ISA degli shader reali di CA era 2,5-3 volte più lungo di quello di
Mesa: ~40% delle istruzioni erano spostamenti di metà registro a 16 bit (U16_TO_U32, MKVEC, F16_TO_F32 +
V2F32_TO_V2F16), salti su condizioni costanti (function constant), campionamenti in f32 riconvertiti in f16, MOV per
costruire i vettori di staging. La GPU è limitata dal calcolo (job 1015 µs a 920-950 MHz, 1530 µs a 588 MHz), quindi la
lunghezza del codice si traduce direttamente in tempo.

| Modifica | File | Toggle (comportamento vecchio) |
|---|---|---|
| Constant folding sull'IR macchina (MKVEC, logica/shift, IADD/ISUB, conversioni 16/32 bit, FADD/FMUL/FMIN/FMAX f32 e v2f16) | `vi_fold.c` | `VMG_ISA_NO_FOLD=1` (spegne tutto il blocco) |
| Lane a 16 bit: le letture tramite U16_TO_U32/MKVEC leggono la metà originale; V2F32_TO_V2F16(F16_TO_F32 a, F16_TO_F32 b) = MKVEC; MKVEC(x.h0, x.h1) = x; sorgenti v2f16 costruite da MKVEC = parola originale con swizzle | `vi_fold.c` | idem |
| Salti su costanti → salti incondizionati / rimossi, blocchi irraggiungibili svuotati, phi rimasti con una definizione per parola → valori ordinari | `vi_fold.c`, `vi_opt.c` | idem |
| Modificatori abs/neg propagati nelle sorgenti float (fabs/fneg spariscono) | `vi_fold.c` | idem |
| MOV su se stessi rimossi dopo l'allocazione | `vi_fold.c` | idem |
| DCE per parola dei registri multi-parola | `vi_opt.c` | idem |
| Copie verso vettori di staging rinominate (il valore nasce già nella parola finale) | `vi_opt.c` | `VMG_ISA_NO_COALESCE=1` |
| RA: intervalli per parola + suggerimenti di copia per i vettori (la parola prende il registro della sorgente che muore lì) | `vi_ra.c` | `VMG_ISA_NO_VHINT=1` |
| Campionamenti `.v4f16` con larghezza registro 16 (2 registri, niente conversioni) | `vi_sel_tex.c` | `VMG_ISA_NO_TEX16=1` |
| clamp/dot/mix su half in v2f16 nativo | `vi_sel_alu.c` | `VMG_ISA_NO_HALF_NATIVE=1` |
| sqrt = rcp(rsqrt) come Mesa; fwidth senza la correzione di segno delle derivate | `vi_sel_alu.c`, `vi_sel_sg.c` | `VMG_ISA_NO_FOLD=1` |

Risultati:
- Corpus reale (134 input catturati sul telefono con `VMG_DUMP_AIR`, ricompilati sul Mac): istruzioni ISA/Mesa
  **1,55 → 1,19**; blur e downsample sotto Mesa (0,82-0,96), `fixed_frag_lph_cph` (66 varianti) 1,18.
- Telefono, swipe della home: **36,5 → 27,2 ms per frame (27 → 37 fps)**, job medio 1486 → 1015 µs: alla pari col
  percorso NIR (26,8 ms). Stessi 6 KO noti di `isatest` (identici sul NIR), schermate di home, Impostazioni e App Library
  (blur) corrette.

Strumenti nuovi: `VMG_DUMP_AIR=DIR` salva ogni input di shader (bitcode AIR specializzato, funzioni collegate, varying,
formati colore) come `DIR/<hash>.vair`; `airnir FILE.vair...` li ricompila sul Mac (con `VMG_TRACE_ISA=1` disassemblato e
statistiche, con `VMG_ISA=0 VMG_PRECOMPILE=1 BIFROST_MESA_DEBUG=shaderdb,internal` le statistiche di Mesa per confronto).

Restano sopra Mesa: costanti messe in registri (IADD_IMM) dove Mesa le impacchetta in FAU insieme alle uniform,
`p3_clamp_lph` (2,2×, non sul percorso delle animazioni), compute di VideoToolbox (`VTMTSComputeFunction`, spill a 64
registri: è il ripiego GPU delle conversioni IOSurface senza scaler hardware).

Viva Manager, MaliMetal > Compilatore ISA > **Selezione automatica**: accende l'ISA e le funzionalità secondo
`isa-verified.json` (ok / parity = fallisce uguale sul NIR / regression = spenta); nessun test eseguito sul dispositivo.
Rigenerare il file dopo un giro di test: `driver/tests/gen_isa_verified.py`.

Bug del driver esistente trovati lungo la strada: texture buffer dimensionati in texel invece che in byte (overflow
dell'heap a ogni copia: corretto in `texture_template`); puntatori a sampler/texture/buffer liberati rimasti legati tra un
command buffer e l'altro (corretto: `vmg_unbind_object` al rilascio); `phase3`/`translate` crashano già a HEAD con llvmpipe sul Mac.
