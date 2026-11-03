# TeraScale Compute: piano (bozza 5, 2026-11-02) – compute Metal su OpenCL 1.2

## Stato: fuori dalla sperimentazione, driver 0.10.0 (2026-11-02)
Deciso dall'utente il 2026-11-02 ("è pronto"), dopo la 0.7.0 installata con il compute acceso per tutte le app. Rispetto ai
criteri di "Uscita dalla sperimentazione" (in fondo) il periodo di due settimane non è stato atteso: vale l'uso reale con
il compute acceso ovunque e il caso di Mappe, dove senza compute i risultati sono sbagliati.
- **App:** la voce "Compute (OpenCL)" del gruppo "Sperimentale" diventa **"TeraScale Compute"** nel gruppo **"Sistema"**,
  sotto TeraScale Glass (`gui/Sources/App.swift`, `ComputeView.swift`, app 1.2.0). Il gruppo "Sperimentale" sparisce.
  Con il compute acceso per tutte l'elenco è di **eccezioni**: un'app aggiunta entra spenta (prima entrava accesa).
- **Policy:** `System.Compute` (accanto a `System.Glass`) invece di `Experimental.Compute`; il driver legge ancora la
  vecchia chiave quando la nuova manca, e l'app riscrive la vecchia uguale alla nuova se il file la contiene (un driver
  ≤0.9.0 ancora installato non perde le impostazioni: `update.sh` installa solo il driver). Da togliere dopo la 0.10.
- **Predefinito acceso:** senza `System.Compute.Enabled` il compute è acceso (motivo `default`). OpenCL resta caricato
  solo dai processi che usano un kernel che ne ha bisogno; le app senza kernel compute non cambiano.
- CLI: `tsmtl compute` mostra `System.Compute.Enabled` e se è il predefinito; `system/update-compute.sh` non è più legato
  alla 0.7 e non chiede più di accendere Mappe (avvisa solo se il compute è spento ovunque).
- Prove: `tests/system/run.sh` 14/14 (nuovi: acceso senza policy, vecchia chiave ancora letta).

## Stato: versione sperimentale 0.7.0 (2026-11-02)
Ottimizzazioni e correzioni di `docs/OTTIMIZZAZIONE-COMPUTE.md` (dettagli e misure nella sua sezione "Stato").
Installazione come prima: `zsh system/update-compute.sh` (driver **0.7.0** + app 1.1.0), ritorno `--revert`.
- **Mappe: il compute serve davvero.** A/B al Colosseo (`tools/maps-landmark.sh`): senza compute il modello 3D del
  Colosseo è nero e la satellite 3D tutta rossa; con il compute `VTMTSComputeFunction` gira su OpenCL (500–600 run per
  corsa, nessuno saltato) e i fotogrammi sono corretti. Nella 0.6.0 il kernel si compilava ma non partiva mai.
- Compilazioni: una per chiave anche in parallelo, binari CL su disco (0,3–0,8 ms invece di 60–1100 ms), varianti
  asincrone e precompilazione al caricamento della libreria.
- Costi per dispatch dimezzati (`setBytes` senza buffer nuovi, cache di `cl_mem` e argomenti), niente riletture bloccanti
  dei buffer scritti da CL, rilascio del contesto CL dopo 30 s di inattività.
- Corretto un bug della 0.6.0: un command buffer poteva risultare completato prima dei suoi kernel CL.
- Limiti della 0.6.0 tolti: indirizzamento per asse dei sampler, `is_null_texture`, `lod` non nullo accettato quando la
  texture non ha mip; cache su disco dei binari CL.
- Prove: `ctest` 42/42, `tests/system/run.sh` 13/13. Resta da fare: rilascio degli oggetti GL fuori dalla coda GPU
  (1,5–7 ms per run in Mappe).

## Stato: versione sperimentale 0.6.0 (2026-11-01)
C0–C4 fatti, C5 avviato (app vere, sotto "Benchmark"). Installazione: `zsh system/update-compute.sh` (driver 0.6.0 + app
1.1.0; niente EFI, niente kext, niente riavvio), ritorno: `zsh system/update-compute.sh --revert`.

**Scostamento dal piano: il percorso OpenCL vive nel core, non in un bundle a parte.** Un bundle separato caricato nelle
app con library validation (tutte quelle Apple e le app hardened) richiede la deroga del kext 1.2, cioè EFI e riavvio.
Le ragioni per separarlo restano coperte così:
- OpenCL.framework si carica con `dlopen` solo al primo kernel che ne ha bisogno (`src/compute/TSCLApi.h`,
  `TS_CL_DYNAMIC`): con il compute spento, o con soli kernel del percorso GL, il processo non lo carica nemmeno;
- la policy `Experimental.Compute` lo spegne per app o ovunque senza reinstallare; con il compute spento i rami nuovi
  del core sono un confronto ciascuno (`gTSComputeCLActive`, `_glAhead`, l'indice dei comandi CL del command buffer);
- il bundle separato con la deroga del kext 1.2 resta un'opzione per C6, se servirà aggiornarlo indipendentemente.

| Pezzo | Dove | Note |
|---|---|---|
| Traduttore AIR → OpenCL C | `src/TSAirOpenCL.m` | "C con goto": ogni valore SSA è una variabile, ogni blocco un'etichetta (ordine RPO), le phi copie parallele sugli archi; puntatori a byte con offset dal datalayout AIR (puntatori del device CL a 32 bit: offset in `int`); `vloadN`/`vstoreN` sotto l'allineamento naturale CL, `vload_half`/`vstore_half_rte` per `half`; i1 = `bool`, vettori di i1 = maschere `intN` 0/-1 |
| Percorso nel core | `src/TSMtlComputeCL.m` | contesto CL pigro sul share group del device, programmi in cache per sorgente, dispatch con bordi (fino a 8 enqueue, `ts_goff`), re-tiling dei gruppi > 256 solo per kernel che non leggono la forma del gruppo |
| Runtime GL↔CL | `src/compute/TSCLRuntime.c` | quello di C0.1, ora compilato nel core |
| Coerenza | `TSMtlBuffer` `prepareGPUWrite`/`didWriteGPU`/`syncFromGL`, `TSMtlTexture glTextureForCompute:` | buffer scritti da CL: GL è la verità fino al merge a tre vie (byte cambiati dalla GPU contro istantanea pre-dispatch) al completamento (shared/managed) o quando la copia CPU serve sulla coda GPU (blit, buffer costanti, argomenti indiretti); `Forget` prima di ogni `glBufferData`/`glDelete*`/rebind di IOSurface |
| Policy | `TSMtlComputeEnabled` in `src/TSMtlSystem.m` | ordine: `TSMTL_COMPUTE`, shim spento, voce dell'app, interruttore generale, spento; riga `compute: on\|off id=… reason=env\|shim-off\|list\|global\|default` |
| App e CLI | `gui/Sources/ComputeView.swift`, `tsmtl compute` | sezione "Sperimentale → Compute (OpenCL)" (dalla 0.10.0 "Sistema → TeraScale Compute"), filtro di log "Compute", `dispatch/s` e `clRun/s` in `tsmtl stats` |
| Prove | `make test-compute`, `tests/system/run.sh` | `ctest` 34/34 sul corpus `kernels.metal`, `glkernels`, policy 5 casi nel test di sistema (13/13), `cltrans --build/--path` |
| Benchmark | `tools/compute-bench.sh`, `tools/maps-bench.sh`, `tools/chrome-bench.sh`, `shim-run.sh --compute/--no-compute` | vedi "Benchmark" |

**Copertura misurata** (`tools/cltrans <metallib> --build` e `--path`):
| Libreria | Kernel | Risultato |
|---|---|---|
| corpus `tests/compute/kernels.metal` | 16 | 15 tradotti e compilati, `simd_sum` rifiutato (atteso); `ctest` 34/34 risultati esatti |
| CoreImage `default.metallib` | 60 | **60/60** tradotti e compilati |
| QuartzCore `default.metallib` | 24 | 7/24: gli altri usano simdgroup, imageblock, quadgroup (solo GPU Apple) |
| VectorKit `default.metallib` (Mappe) | 3 | `clearTexture` percorso GL, **`downscaleTexture` OpenCL** (scrive in `gid >> 1`: finora era un no-op), `DaVinci::resetLM` rifiutato (imageblock) |
| GridCraft (wgpu) | 2 | entrambi i `main_` su OpenCL |

**Limiti noti della 0.6.0** (la 0.7.0 toglie `is_null_texture` sempre falso, l'indirizzamento unico per tutti gli assi e la mancanza della cache su disco): `is_null_texture` vale sempre falso (un dispatch con una texture non legata viene saltato,
con una riga di log); `gather` emulato con 4 letture (clamp ai bordi); `sample` legge il livello 0, un indirizzamento
per tutti gli assi, un solo filtro; niente atomiche a 64 bit, `double`, simdgroup/quadgroup, imageblock, texture
depth/cube/buffer/multisample, scritture su texture 3D; gruppi oltre 256 thread solo per i kernel indipendenti dalla
forma del gruppo; nessuna cache su disco dei binari CL (quella per app di `CVMServer` basta: 1–4 ms al secondo avvio).

Nome di lavoro: **TeraScale Compute** (vedi "Uscita dalla sperimentazione" per il nome definitivo).
Contesto e misure di partenza: valutazione del 2026-11-01 (CoreAnimation e CoreImage non ne hanno bisogno, vedi sotto).

## Benchmark CON vs SENZA compute (2026-11-01, copie in `apps/`, driver 0.6.0 da `build/`)
Round alternati, `TSMTL_COMPUTE=1` contro `0`. App senza interazione: `tools/compute-bench.sh 2` (avvio fino alla finestra,
poi 12 s di riscaldamento e 10 s misurati); Mappe: `tools/maps-bench.sh` (vista 3D, panoramica con scroll, 15 s di
statistiche); Chrome: `tools/chrome-bench.sh` (YouTube, scroll sintetico).
| App | Kernel compute | SENZA | CON |
|---|---|---|---|
| Mappe | `VTMTSComputeFunction` (VideoToolbox) su OpenCL: build 1074 ms al primo avvio, 2,5 ms dal secondo (cache di CVMServer); ~6 dispatch e 6 run CL nella finestra di panoramica | frame 197 / 234, CPU 6,9 / 8,8 s, RSS 273 / 303 MB | frame 275 / 201, CPU 6,5 / 7,2 s, RSS 281 / 311 MB |
| GridCraft | 2 `main_` (wgpu) su OpenCL alla partenza, nessun dispatch senza interazione | avvio 3,9 s, RSS 155 MB | avvio 3,0 s, **RSS 212 MB** (contesto OpenCL + compilatore) |
| Chrome | nessuno | frame/15 s 1924 / 1866, coda GPU 3766 / 2326 ms | 1882 / 1838 / 1850, 2615 / 2456 / 2514 ms |
| Anteprima, Dov'è, ArtCraft Launcher | nessuno (OpenCL mai caricato) | RSS 80 / 182 / 54 MB | 81 / 206 / 63 MB (rumore: nessun contesto CL) |
| Impostazioni di Sistema | – | la copia non apre finestre né crea il device, anche senza compute: esclusa | – |
Conclusioni: nessuna regressione misurabile di frame o CPU; dove ci sono kernel ora girano (Mappe, GridCraft) invece di
essere no-op. Il costo è la memoria del contesto OpenCL (+50–60 MB) nei soli processi che lo creano, e la prima
compilazione (fino a ~1 s per kernel, una volta per app). Da fare in C5: verifica visiva di cosa produce
`VTMTSComputeFunction` in Mappe, scenari di GridCraft che lanciano i kernel, giochi con compute pesante.

## Obiettivo e perimetro
- Eseguire davvero i compute encoder Metal (`MTLComputeCommandEncoder`), che oggi sono no-op, sulla GPU tramite **OpenCL 1.2**,
  condividendo buffer e texture con il contesto OpenGL dello shim.
- Destinatari: app e giochi che usano compute generale (riduzioni, istogrammi, particelle, filtri propri), cioè quelli che oggi
  compaiono nella categoria `unimplemented` con `TSMtlComputeEncoder`. **Non** CoreAnimation e **non** CoreImage:
  - CoreAnimation su un device Mac2 sfoca con shader fragment; i suoi kernel compute sono quasi tutti per GPU Apple (imageblock, simdgroup).
  - CoreImage senza Metal usa il proprio backend OpenGL sulla stessa GPU (`CIContext … (opengl 1)`, blur 2048² ≈ 42 ms) e lo shim lo
    tiene lì (`CI_ENABLE_METAL_GPU=0`). Portarlo su Metal non lo renderebbe più veloce.
- È una **estensione separata** dal core: bundle e installazione propri, spenta per default, attivabile da una sezione
  "Funzioni sperimentali" dell'app, per tutto il sistema e per singola app. Con l'estensione spenta o assente il core si comporta
  esattamente come oggi.

## Fattibilità (fase C0) – già misurato su questo Mac
| Domanda | Risposta | Prova |
|---|---|---|
| OpenCL sulla GPU | OpenCL 1.2 (driver "1.2 May 8 2018"), 6 CU, workgroup max **256**, memoria locale 32 KB, immagini sì (128 in lettura, 8 in scrittura), atomiche int32 globali e locali; **niente fp16, niente subgroup, niente scrittura su immagini 3D** | `tests/compute/clprobe.c` |
| Dentro una sandbox da app | funziona: `deny default` + `system.sb` + `(system-graphics)` (come `application.sb`); build e kernel ok | `tests/compute/sandbox.sb` |
| Condivisione con il GL 4.1 core dello shim | `CL_CONTEXT_PROPERTY_USE_CGL_SHAREGROUP_APPLE` sul contesto CGL → 1 device (la Radeon). `clCreateFromGLBuffer`, `clCreateFromGLTexture` su `GL_TEXTURE_2D` RGBA8 e **RGBA16F**, e su **`GL_TEXTURE_RECTANGLE` da IOSurface**: tutti ok, dati scritti da CL letti giusti da GL e dalla superficie | `tests/compute/interop.m` |
| Costo di un passaggio GL→CL→GL | acquire + kernel 64×64 + release + `clFinish`: 0,8 ms il primo, poi ≈0,2 ms. **Scomposto e ridotto: vedi "Passaggio GL↔CL"** (una sottomissione per run, niente `clFinish`) | `interop.m`, `roundtrip.m`, `clcost.m` |
| Compilazione | da sorgente OpenCL C, a runtime (va messa in cache, vedi C2) | `clprobe.c` |

Restano da misurare in C0 (prima di scrivere codice nel driver):
1. ~~sincronizzazione **implicita** sotto carico~~ **fatto**: corretta su texture e buffer, anche con 10.000 dispatch senza
   attese della CPU (`runtime.m`, `bufcoherence.m`); vedi "Passaggio GL↔CL";
2. ~~OpenCL in un'app Apple con hardened runtime e in sandbox vera~~ **fatto** (C0.2, sotto);
3. ~~tempo di `clBuildProgram`~~ **fatto**: 65–365 ms a freddo da una CLI, fino a 4,4 s nel primo avvio di Anteprima (compilatore
   freddo + avvio dell'app), 0,7–4 ms a caldo. **C0 chiuso.**

## Architettura
```
App ─► Metal.framework ─► TeraScaleMTLDriver.bundle (core, invariato se l'estensione è spenta)
                            │  TSMtlComputeEncoder registra i comandi come oggi (blocchi nella coda GPU)
                            │  se la policy lo consente: dlopen dell'estensione al primo device
                            ▼
                 TeraScaleMTLCompute.bundle (estensione, /Library/GPUBundles)
                   ├─ ABI C versionata (TSComputeExtension): init, compileKernel, dispatch, release
                   ├─ traduttore AIR → OpenCL C (front-end AIR condiviso con il core: stesso sorgente)
                   ├─ runtime CL: contesto sul share group CGL del core, coda CL, cache dei binari
                   └─ interop: buffer/texture GL del core → cl_mem (acquire/release per dispatch)
```
### Confine core ↔ estensione
- Il core continua a possedere **tutti** gli oggetti Metal (pipeline, encoder, buffer, texture) e la coda GPU (thread GL).
  L'estensione non vede classi Objective-C del core: riceve solo una tabella C.
- **Host → estensione** (`TSComputeHost`, dato all'init): share group CGL, funzione di log (categoria `compute`), contatori per le
  statistiche, cartella cache, versione del traduttore.
- **Estensione → host** (`TSComputeExtension`, restituita da `TSComputeExtensionEntry(abiVersion)`):
  - `compileKernel(bitcode, len, nome)` → handle + riflessione minima (memoria threadgroup statica, thread massimi per gruppo dal
    `CL_KERNEL_WORK_GROUP_SIZE`, quali argomenti buffer/texture vengono scritti) oppure errore leggibile;
  - `dispatch(handle, binding[], grid, threadgroup, threadgroupMemoryLengths[])`: binding = (tipo, nome GL, target, formato,
    offset, IOSurface sì/no, byte inline per `setBytes`);
  - `endRun()` (chiude il run aperto, vedi "Passaggio GL↔CL"), `forget(nome GL, target)`, `release(handle)`.
- Versione ABI diversa, simbolo assente, `dlopen` rifiutato → riga `compute` di errore e compute no-op come oggi. Mai crash.
- Il front-end AIR (caricamento di libLLVM, pulizia con i passi LLVM, pianificazione del CFG strutturato, lettura dei metadati
  `!air.*`) viene separato da `TSAirTranslator.m` in sorgenti condivisi (`src/air/`) compilati in entrambi i binari. L'emettitore
  OpenCL C sta solo nell'estensione. Il GLSL non cambia.

### Perché un bundle a parte e non codice nel core
- Si installa, aggiorna e toglie indipendentemente (`update.sh --compute`), senza toccare il driver che disegna le app.
- Se l'estensione ha un difetto grave, basta spegnerla o cancellarla: il core non la carica.
- Costo: un secondo percorso nella deroga alla library validation del kext (vedi "Installazione").

## Passaggio GL↔CL (C0.1, misurato il 2026-11-01)
Obiettivo: che un dispatch in mezzo alle passate render costi quasi quanto una passata GL. Probe in `tests/compute/`
(`make compute`, `make test-compute`), GPU HD 6750M, driver CL "1.2 May 8 2018".

### Dove andavano gli 0,2 ms
| Chiamata (CPU del thread che la fa) | ms | Note |
|---|---|---|
| `glFlush` | 0,025 | ~0,003 se non c'è niente in coda |
| `clEnqueueAcquireGLObjects` | 0,010 | non cresce con il numero di oggetti (1→16: 0,009→0,017) |
| `clEnqueueNDRangeKernel` | 0,003 | solo accodamento |
| **`clEnqueueReleaseGLObjects`** | **0,13–0,22** | **è una sottomissione al driver**; *non* aspetta il kernel (con un kernel da 71 ms torna in 0,2 ms, stato QUEUED) |
| `clFlush` dopo il release | 0,045 | superfluo: il release ha già sottomesso |
| `clFinish` | = tempo GPU residuo | blocca il thread GPU del core: è quello che rende il costo "per dispatch" |
- Ogni sottomissione CL costa ~0,15–0,25 ms di CPU qualunque cosa contenga (anche senza oggetti GL: `clFlush` di un kernel vuoto
  0,17 ms), più ~0,035 ms per kernel che porta. Accodare senza sottomettere costa 0,002 ms.
- **Ordine sulla GPU**: un comando GL emesso dopo il release (anche una fence che non tocca oggetti condivisi) termina *dopo* il
  kernel CL (fence dopo un kernel da 71 ms: segnalata a 70–75 ms, kernel già completo). La GPU ha un'unica coda di comandi.
- **GL → CL**: l'acquire vede i comandi GL emessi prima, anche senza `glFlush` esplicito (lo teniamo: costa ~0, è nelle regole di
  `cl_APPLE_gl_sharing`).
- Code CL out-of-order: non supportate (`CL_INVALID_VALUE`).

### Regole del runtime (`src/compute/TSCLRuntime.{h,c}`)
1. **Una sottomissione per run.** Un *run* è la sequenza di dispatch consecutivi (anche di encoder compute diversi) fino al
   prossimo comando GL. Gli oggetti GL si acquisiscono man mano che i dispatch li usano (una volta per run; acquisire a pezzi
   costa come acquisire tutto all'inizio) e si rilasciano tutti insieme a fine run: un solo release = una sola sottomissione.
2. **Nessuna attesa.** Niente `clFinish`, niente eventi CL: il run si chiude *prima* del comando GL successivo e prima della fence di
   completamento del command buffer (B2), che quindi copre anche il lavoro CL. Completion handler, shared event e lettura dei
   buffer `shared` restano legati alla stessa fence.
3. **`cl_mem` in cache** per (nome GL, target, livello), un solo oggetto `CL_MEM_READ_WRITE` per oggetto GL; il core chiama
   `TSCLRuntimeForget` *prima* di `glDelete*`/ri-specifica (GL ricicla i nomi). `clCreateFromGLTexture` costa poco (0,001–0,005 ms)
   ma così non si paga mai nel percorso del dispatch.
4. **Threadgroup 2D sulle immagini.** Con `local = NULL` il driver sceglie strisce 1D e un kernel su immagine 1024² va a metà
   velocità della passata GL equivalente (1,7 contro 0,94 ms per giro); con 16×16, 32×8 o 64×4 è alla pari (0,97–1,0 ms). Metal
   passa sempre `threadsPerThreadgroup`, e il modello di Apple `threadExecutionWidth × (max/width)` dà 64×4 con i nostri limiti:
   va bene. Per i kernel senza barriere né memoria threadgroup che non leggono gli indici locali, il runtime può ritagliare
   un gruppo 1D da 256 in 16×16 (C4, da misurare su kernel veri).

### Risultato (`build/clruntime`, frame = passata GL + D dispatch + passata GL che legge il risultato + fence)
Costo in più rispetto allo stesso lavoro fatto con passate GL, ms per frame:
| Immagini | Strategia | D = 1 | D = 3 | D = 7 |
|---|---|---|---|---|
| 1024² (GPU piena) | per dispatch + `clFinish` (lo 0,2 ms della bozza 1) | +0,09…0,15 | +0,48…0,58 | +1,33…2,18 |
| | **runtime** | ≈0 (±0,03) | ≈0 | ≈0 (−0,06…+0,01) |
| 256² | per dispatch + `clFinish` | +0,13…0,36 | +0,58…1,28 | +1,21 |
| | **runtime** | +0,10…0,12 | +0,09…0,11 | +0,10…0,16 |
| 64² (GPU scarica) | per dispatch + `clFinish` | +0,23…0,25 | +0,58…0,68 | +1,36 |
| | **runtime** | +0,15…0,18 | +0,26…0,29 | +0,28…0,38 |
- Quando la GPU è il collo di bottiglia la sottomissione si nasconde dietro il lavoro GPU: **costo nullo**. Quando la GPU è scarica
  resta una sottomissione per run (≈0,1–0,3 ms del thread GPU del core, *non* del thread dell'app: il commit è asincrono).
- Correttezza: catene GL↔CL su texture R32F 1024² e buffer fino a 4 MB (letti dal core come texture buffer in una passata fragment),
  10.000 dispatch alternati a passate render senza attese della CPU, nome GL riciclato: tutto esatto.
- **Sottomissione asincrona** (`TSCLRuntimeEndRunAsync`: il release su un thread a parte, il thread GPU continua a codificare GL e si
  ricongiunge prima del suo `glFlush`): guadagno parziale e irregolare (attesa residua 0,05–0,47 ms invece di 0,13–0,35 con 150 draw
  da codificare), probabilmente perché le chiamate GL e la sottomissione CL si serializzano sullo stesso lock del share group.
  Resta nel runtime, spenta, da riprovare sulle app vere (C5) prima di decidere; il percorso predefinito è quello sincrono.
- Per arrivare a zero anche a GPU scarica c'è il **percorso GL** (sotto): i kernel "da fragment" non passano da OpenCL.

### Aggancio nel core (C1/C4)
- `TSMtlCommandBuffer` marca i comandi registrati dal compute encoder; in `execute`, prima di ogni comando non compute e dopo l'ultimo
  comando (prima di `glFlush` e della fence in `submitCommandBuffers`), chiama `endRun()` dell'estensione: costa un confronto quando
  non c'è un run aperto. I blocchi `gpuSync`/`gpuAsync` (upload, `getBytes`) girano fra un command buffer e l'altro, quindi a run chiuso.
- `TSMtlTexture`/`TSMtlBuffer`: `forget(nome, target)` prima di `glDelete*` e di ogni ri-specifica dello storage GL.
- Statistiche: `dispatches`, `clSubmits` (= run), `clSubmitMs`, `computeRejected`.

### Stranezza del driver GL trovata per strada
Un texture buffer letto dal **vertex shader durante il transform feedback** restituisce texel vecchi o zero oltre ~16K–28K punti,
anche senza OpenCL. Letto da un fragment shader (come fa il core) è corretto fino a 1M texel e più. Riguarda solo chi usasse il
transform feedback per emulare compute su buffer: non usarlo con texture buffer grandi.

## Percorso GL: kernel come passate fragment (fatto il 2026-11-01)
Il costo residuo di OpenCL è la sottomissione; un kernel che un fragment shader sa esprimere non ne ha bisogno.
- **Traduttore** (`TSAirTranslator.m`, modalità kernel per `!air.kernel`): `thread_position_in_grid` = `gl_FragCoord.xy`; le altre
  built-in di griglia e threadgroup da uniform (`ts_grid`, `ts_tg`); l'unica `write()` su una texture 2D **esattamente in `gid`**, livello
  0, diventa l'uscita `o0`; `get_width/height` di quella texture = `ts_out_size`; un thread che non scrive fa `discard` (il texel resta);
  `sample()` legge il livello 0 (niente derivate, come in Metal). Un marcatore `// ts_kernel_output N` dice alla pipeline quale slot.
  **Rifiutati** (restano per OpenCL, con il motivo): store in memoria device, atomiche, barriere (`air.wg.barrier`, finora ignorata),
  memoria threadgroup, `simd_*`/`quad_*`, scrittura in coordinate diverse da `gid`, più di una texture scritta, lettura della texture scritta.
- **Core**: `TSMtlComputePipelineState` vera (programma GL condiviso con la cache dei programmi, varianti rettangolo per le texture
  IOSurface lette in place); `TSMtlComputeEncoder` registra lo stato e ogni dispatch è una passata GL sulla texture scritta (FBO,
  viewport = griglia ∩ texture, buffer costanti in UBO, buffer device come texture buffer, sampler). Nessun oggetto OpenCL: vive nel core.
- **Acceso solo con `TSMTL_COMPUTE=1`** (in C1: la policy `Experimental.Compute`). Spento: pipeline inerte e dispatch no-op come prima,
  con la riga `unimplemented` su `TSMtlComputeEncoder` che serve a trovare le app interessate. Log nella nuova categoria `compute`
  (una riga per pipeline: "runs as a GL pass" o "does not run (needs OpenCL): motivo"); statistiche `dispatches`, `compute rejected`.
- **Prova**: `tests/compute/glkernels.metal` + `glkernels.m` (`make test-compute`): RGBA8, sRGB, R32Uint, RGBA32F, IOSurface come
  uscita e come ingresso, griglie più grandi e più piccole della texture, scritture parziali, buffer costanti/device con offset, built-in
  di threadgroup, 1.600 dispatch in ordine; i 4 kernel da OpenCL rifiutati e senza effetto; con `--off` tutto inerte. `make test` verde.
- **Costo** (stesso lavoro come passate render dello shim, tramite il device vero):
  | | dispatch GL | passata render |
  |---|---|---|
  | 64², 8 per command buffer | 0,023 ms ciascuno | 0,047–0,053 ms |
  | 256², 8 | 0,131 | 0,129 |
  | 1024², 8 | 1,76 | 1,77 |
  Cioè **nessun costo di passaggio**: a GPU scarica 0,02 ms per dispatch contro 0,1–0,3 ms per run del percorso CL.
- Bug del core trovato per strada e corretto: un programma che legge un buffer device solo a parole da 16 byte (`<nome>_4`) non
  riceveva l'offset del binding (`<nome>_off`), quindi leggeva dall'inizio del buffer se l'app lo legava con un offset. Valeva anche per
  il render (`TSMtlRender.m`); ora l'offset è impostato anche da quel binding.
- Prossimi passi possibili: scrittura in `gid + costante` (i kernel cuciti di CoreImage scrivono in `gid + offset uniforme`: basta
  spostare il viewport, ma l'offset sta in un buffer), più texture scritte della stessa dimensione (MRT, con `discard` per tutte),
  scrittura su slice di array/3D tramite layer dell'FBO.

## C0.2: OpenCL dentro un'app vera (2026-11-01)
| Caso | Risultato |
|---|---|
| Eseguibile con **hardened runtime** (`-o runtime`, senza eccezioni JIT) **+ App Sandbox** (`build/clprobe-hardened`) | contesto CL sul share group, build, passaggio GL→CL→GL con `TSCLRuntime`: **tutto ok** |
| **Anteprima** (copia ad-hoc *con* entitlement di sandbox, id `com.terascale.test.Preview`, `shim-run.sh --system --cl-probe`) | sandbox attiva, **tutto ok**, 0 errori; il bundle del driver si carica da `build/` |
| Cache del compilatore CL | la tiene `CVMServer` (servizio root di OpenGL.framework), **fuori dal container**: nessun file scritto dall'app; persiste fra gli avvii della stessa app (2° avvio: 1–4 ms), non è condivisa fra app diverse. La cache dei binari CL di C2 resta utile per non dipendere da essa |
| Avvio a freddo | primo contesto CL 220–310 ms e primo build fino a 4,4 s nel primo avvio di Anteprima: il runtime va creato **pigramente** (al primo dispatch CL), mai all'avvio del device |
Note per C1:
- La copia di `shim-run.sh` perde l'hardened runtime (serve per `DYLD_INSERT_LIBRARIES`): la prova hardened è l'eseguibile a parte.
- In una copia **sandboxed** il core non legge `TSMTL_CONFIG_DIR` sotto `~/metal-shim` (`Operation not permitted` → policy `outside`):
  per provare la policy `Experimental` in sandbox il workbench deve copiare `policy.plist` nel container dell'app (o in un percorso che la
  sandbox legge). L'estensione in `build/` invece si carica (come il driver).
- `tools/shim-run.sh --cl-probe` resta come strumento: aggiunge `build/libTSCLProbe.dylib` e scrive righe `[TSCLProbe]` nel log della copia.

## Cosa viene eseguito, cosa no (versione 1)
| Funzione Metal | Trattamento |
|---|---|
| Buffer `device`/`constant` | `__global` / `__constant` (oltre 64 KB o più di 8 argomenti costanti: `__global const`) |
| Memoria threadgroup statica e `setThreadgroupMemoryLength` | `__local` (statica nel kernel, dinamica come argomento `__local`) |
| `threadgroup_barrier`, `mem_fence` | `barrier(CLK_LOCAL_MEM_FENCE \| CLK_GLOBAL_MEM_FENCE)` secondo i flag |
| Built-in `thread_position_in_grid`, `threadgroup_position_in_grid`, `thread_index_in_threadgroup`, … | `get_global_id`, `get_group_id`, `get_local_id` + correzioni per i dispatch a blocchi (sotto) |
| `dispatchThreadgroups` | un `clEnqueueNDRangeKernel` |
| `dispatchThreads` con griglia non multipla | fino a 4 enqueue (2D) o 8 (3D): parte uniforme + bordi con `local` = resto e `global_work_offset`; le barriere restano corrette |
| Dispatch indiretto | argomenti letti dal buffer prima dell'enqueue (copia CPU o lettura GL) |
| Atomiche int32 su `device`/`threadgroup` | `atomic_*` di OpenCL 1.2 |
| Atomiche float (add) | ciclo `atomic_cmpxchg` su 32 bit |
| Atomiche a 64 bit | **non supportate** → kernel rifiutato (sotto) |
| `half` | calcolo in `float`; nei buffer `vload_half`/`vstore_half`; texture RGBA16F tramite `read_imagef`/`write_imagef` |
| Texture 1D/2D/2D array lette, campionate, scritte | `image1d_t`/`image2d_t`/`image2d_array_t` via `clCreateFromGLTexture` (anche rettangoli IOSurface) |
| Texture 3D | lettura sì; **scrittura no** (manca `cl_khr_3d_image_writes` sulla GPU) |
| Texture `read_write` | due `cl_mem` sulla stessa texture (lettura + scrittura): non garantito da CL 1.2, da verificare nel workbench; altrimenti rifiutata |
| Texture cube, texture buffer | cube: lettura come 2D array con selezione della faccia; texture buffer: `image1d_buffer_t` |
| Sampler | `sampler_t` CL (niente mip-filtering né anisotropia: si campiona il livello 0, con avviso) |
| Function constant | come per il GLSL: la funzione arriva già specializzata |
| `simd_*`, `quad_*`, simdgroup matrix | **non supportate** in v1 (niente subgroup in CL 1.2) |
| Imageblock, tile, ray tracing, function pointer, visible function table | **non supportate** (le GPU Apple sole le hanno) |
| Thread per threadgroup > 256 | la pipeline dichiara `maxTotalThreadsPerThreadgroup` reale (≤ 256); un dispatch più grande senza barriere viene diviso, con barriere è rifiutato |

"Rifiutato" significa: la pipeline esiste (mai `nil`, come per il render), il dispatch resta no-op come oggi, e una riga
`compute` di livello errore dice quale funzione Metal e quale kernel. Così l'app si comporta come adesso, non peggio.

### Coerenza della memoria
- I buffer Metal hanno una copia CPU caricata in GL al commit. Dopo un dispatch che **scrive** un buffer `shared` (dai metadati
  AIR: `air.read_write`/`air.write`, o store sul puntatore), la copia CPU va riletta da GL al completamento del command buffer,
  prima delle completion handler. Per i `managed` solo con `synchronizeResource:`, per i `private` mai.
- Le texture sono già "verità GL": niente da fare, `getBytes` legge come oggi.
- Ordine con il render: i comandi compute sono blocchi nella stessa coda GPU, quindi l'ordine fra passate render e dispatch è quello
  del command buffer. Il completamento resta la fence GL della B2: emessa dopo la chiusura del run, segnala dopo i kernel (misurato).

### Limiti del device con l'estensione attiva
Solo nei processi in cui il compute è acceso: `maxThreadsPerThreadgroup` = 256, `threadExecutionWidth` = 64 (wavefront AMD),
`maxThreadgroupMemoryLength` = 32768. Altrove restano i valori di oggi.

## Policy: sezione `Experimental` di policy.plist
**Dalla 0.10.0 la chiave è `System.Compute` (stesso schema) e il predefinito è acceso**; `Experimental.Compute` è letta
solo se `System.Compute` manca. Contratto aggiornato in `docs/FASE4-INTERFACCE.md`. Testo originale del piano:

Estensione del contratto in `docs/FASE4-INTERFACCE.md` (stesso file, stesso proprietario, sempre XML):
```
Experimental  dict     facoltativo
  Compute     dict
    Enabled   bool     false = spento ovunque (predefinito); true = acceso per tutte le app in cui lo shim è acceso
    Apps      dict     chiave = id dell'app (stesse regole dell'id del core), valore = dict:
                Enabled  bool     vince su Compute.Enabled per quest'app
                Name, Path        facoltativi, per l'interfaccia
```
**Decisione del core** (una volta per processo, in `TSMtlProcessPolicy`, dopo quella dello shim):
1. shim spento per il processo → compute spento (l'estensione non viene nemmeno cercata);
2. voce in `Experimental.Compute.Apps` → quel valore (motivo `list`);
3. `Experimental.Compute.Enabled` → quel valore (motivo `global`);
4. altrimenti spento (motivo `default`).
Acceso → il percorso GL del core (kernel da fragment) è attivo anche senza estensione; in più, bundle presente + ABI giusta →
`dlopen` (pigro, al primo kernel che serve a OpenCL: vedi C0.2); altrimenti motivo `missing`/`abi`/`load`. Le modifiche valgono per le app avviate
dopo, come per lo shim. `TSMTL_COMPUTE_BUNDLE=<percorso>` sostituisce il percorso installato (workbench); nei processi con
library validation un percorso diverso da quello autorizzato dal kext viene comunque rifiutato da AMFI.

## App di controllo: sezione "Funzioni sperimentali"
- Barra laterale: nuovo gruppo **"Sperimentale"** (sotto "Impostazioni") con la voce **"Compute (OpenCL)"**.
  Modello: la sezione Spoofing (`gui/Sources/SpoofView.swift`), che ha già interruttore generale + lista per app.
- Contenuto:
  - riquadro di avviso: cosa fa, che è sperimentale, che vale per le app avviate dopo;
  - stato: estensione installata (versione, firma, cdhash), deroga del kext attiva per il suo percorso, ABI compatibile col core;
  - interruttore **"Attiva per tutte le app"** (`Experimental.Compute.Enabled`);
  - lista per app (aggiungi con il pannello file, on/off, ripristina, rimuovi), come Spoofing;
  - "App viste di recente": dalle righe `compute: on|off id=… reason=…` del log, con stato e motivo;
  - pulsante "Apri il log del compute" → sezione Log con il solo filtro Compute.
- Se l'estensione non è installata la sezione resta visibile ma con i comandi disattivati e l'istruzione per installarla.
- CLI (`tsmtl`):
  `tsmtl compute status [--json]` · `tsmtl compute on|off` (tutte le app) ·
  `tsmtl compute enable|disable|reset|remove <id | percorso.app | proc:nome>` · `tsmtl log --filter compute`.
  `tsmtl status` aggiunge una riga per l'estensione.

## Log
- Stesso subsystem `com.terascale.mtlshim`, nuova categoria **`compute`** per tutto quello che riguarda l'estensione (anche le righe
  scritte dal core sul caricamento):
| Livello | Contenuto |
|---|---|
| default | `compute: on|off id=<id> reason=<list|global|default|missing|abi|load> version=<versione estensione>` (una per processo) |
| info | kernel tradotto/compilato/da cache, con tempi |
| default | funzione Metal di compute non supportata o ridotta (simdgroup, atomiche 64 bit, read_write, mip-filtering…), una volta per processo e kernel |
| error | traduzione o `clBuildProgram` falliti (con il log del compilatore CL abbreviato), errore CL in un dispatch |
- App: nuovo filtro **"Compute"** in `LogFilter` (`gui/Sources/LogSource.swift`), escluso da "Tutti" se l'estensione non è mai
  stata accesa, ed etichetta `COMPUT` nella vista. Nel filtro le righe `unimplemented` che riguardano `TSMtlComputeEncoder`
  compaiono anche con il compute spento, così si vede quali app ne beneficerebbero.
- Statistiche (riga `stats`): campi nuovi `dispatches`, `computeMs` (tempo CL), `clBuilds`, `computeRejected` (totale corrente).
  Mostrati nella sezione GPU solo per i processi con compute acceso.
- `build/tsmtl-fake-emitter` impara a scrivere anche righe `compute` (per provare l'app senza installare).

## Workbench (prima di installare)
Stesso principio della Fase 4: il codice vero di Metal.framework, con `libTSRegSim.dylib` al posto del kext e dei percorsi
installati, e nessuna modifica al sistema.
| Pezzo | Cosa fa |
|---|---|
| `make` | costruisce anche `build/TeraScaleMTLCompute.bundle` (firmato ad-hoc, come il core) e `tools/cltrans` |
| `tests/compute/clprobe.c`, `interop.m`, `sandbox.sb` | fase C0: capacità OpenCL, interop, sandbox (già presenti) |
| `tests/compute/roundtrip.m`, `clcost.m` | C0.1: costo per chiamata del passaggio GL↔CL, strategie a confronto, ordine sulla GPU, dimensione dei threadgroup (`TS_LOCAL=16x16`) |
| `tests/compute/bufcoherence.m` | C0.1: buffer GL scritti da CL e riletti come texture buffer, con attese e in pipeline |
| `tests/compute/runtime.m` (`build/clruntime`, `make test-compute`) | il runtime CL dell'estensione contro le strategie che sostituisce; buffer, stress da 10.000 dispatch, cache dei `cl_mem`; `TS_ENCODE=n` aggiunge n draw da codificare dopo il compute |
| `tools/cltrans file.metallib\|file.metal [funzione] [--build]` | come `airtrans`: stampa l'OpenCL C generato e, con `--build`, lo compila sulla GPU e riporta errori e tempo |
| `tests/compute/kernels.metal` + `tests/compute/ctest.m` | corpus con risultati di riferimento calcolati in CPU: somma vettori, saxpy, riduzione con memoria threadgroup e barriere, istogramma con atomiche, prefix-sum, blur con texture in lettura/scrittura, scrittura su IOSurface, buffer `half`, `setBytes`, `setThreadgroupMemoryLength`, `dispatchThreads` con bordi, dispatch indiretto, function constant, compute seguito da render nello stesso command buffer e viceversa, e un kernel simdgroup (atteso: rifiutato con riga di log) |
| `tests/compute/run.sh` (`make test-compute`) | via `regsim` e `TSMTL_CONFIG_DIR`, come `tests/system/run.sh`: compute spento → no-op + riga `unimplemented`; acceso per tutte; acceso per tutte ma spento per l'app; spento per tutte ma acceso per l'app; shim spento → compute spento; estensione assente → no-op senza crash; ABI sbagliata (bundle di prova) → no-op senza crash; corpus corretto con il compute acceso. Stampa N/M come `system 8/8` |
| ~~`tests/compute/stress.m`~~ | coperto da `runtime.m` (stress da 10.000 dispatch) e `bufcoherence.m` |
| corpus di sistema | `cltrans --build` su tutti i kernel di `QuartzCore default.metallib` (24), CoreImage `default.metallib` (60) e `ci_ubershader.metallib` (300): percentuale tradotta e compilata, come misura di copertura (non di utilità) |
| `tools/shim-run.sh … --system --compute` | nuova opzione: oltre a quanto fa `--system`, accende `Experimental.Compute` per la copia in `apps/system-config/policy.plist` e punta `TSMTL_COMPUTE_BUNDLE` a `build/` |
| app di controllo | `TSMTL_CONFIG_DIR=apps/system-config tsmtl gui --section compute` sulla stessa policy della copia |

## Installazione
- **Kext 1.2** (una volta sola, poi le estensioni si aggiornano senza riavvio): la deroga alla library validation accetta anche
  `/Library/GPUBundles/TeraScaleMTLCompute.bundle/Contents/MacOS/TeraScaleMTLCompute` (e il percorso `/System/Volumes/Data/…`),
  con gli stessi controlli: root, non scrivibile da gruppo e altri, processo non critico. Nuova proprietà `TSLVAllowedCompute`.
  Richiede `install.sh` (EFI) e riavvio, come ogni modifica al kext.
- `system/install.sh --compute`, `system/update.sh --compute [--revert]`, `system/rollback.sh` (toglie anche l'estensione):
  copia root:wheel, backup in `backups/install-*`, verifica della firma, elenco dei processi che la tengono caricata.
- Senza il kext 1.2 l'estensione funziona solo nei processi senza library validation (copie di prova, app non hardened);
  `tsmtl compute status` lo dice.

## Fasi
| Fase | Contenuto | Si chiude quando | Dimensione indicativa |
|---|---|---|---|
| C0 | **chiuso**: capacità, sandbox, interop, costo, sincronizzazione implicita, runtime del passaggio GL↔CL, app hardened in sandbox, Anteprima, tempi di build; in più il percorso GL nel core | — | probe |
| C1 | **fatto (nel core, vedi "Stato")**: scheletro: bundle dell'estensione, ABI, caricamento dal core, policy `Experimental`, righe `compute`, sezione dell'app e CLI, `run.sh` con i casi di policy, kext 1.2 pronto (non installato) | `make test-compute` passa i casi di policy con i dispatch ancora no-op; la sezione dell'app funziona con `TSMTL_CONFIG_DIR` | ~1.000 righe (metà Swift) |
| C2 | **fatto** (cache dei binari delegata a CVMServer): traduttore AIR → OpenCL C per buffer, aritmetica, memoria threadgroup, barriere, atomiche int32; cache dei binari CL su disco (chiave: sha256 di bitcode + tag del traduttore + versione del driver CL, come la cache GLSL) | corpus senza texture corretto; seconda esecuzione senza `clBuildProgram` | ~1.500 righe + estrazione di `src/air/` |
| C3 | **fatto**: texture e sampler via interop (2D, array, IOSurface rettangolari, RGBA8/BGRA8/RGBA16F/R32F…), `half`, `read_write` | corpus con texture corretto | ~600 righe |
| C4 | **fatto**: semantica dell'encoder: dispatch a bordi e indiretti, `setBytes`, coerenza dei buffer `shared`, ordine con il render, completamento, shared event, limiti del device e riflessione della pipeline | `stress.m` e tutto `run.sh` verdi; copertura del corpus di sistema misurata | ~600 righe |
| C5 | **avviato**: app vere: si parte dalle app che hanno `TSMtlComputeEncoder` in `unimplemented`; copie con `shim-run.sh --system --compute`, poi installazione con il compute acceso solo per loro | almeno un'app con effetto visibile corretto e senza regressioni di frame time con il compute spento | — |
| C6 | uscita dalla sperimentazione (criteri sotto) | — | — |

## Rischi
- **Driver OpenCL del 2018 su macOS 26**: deprecato, mai aggiornato; un bug nel compilatore CL può bloccare o far crashare l'app.
  Mitigazioni: spento per default, per app, cache dei binari (meno compilazioni), kernel rifiutati invece di rischiare.
- ~~**Sincronizzazione GL↔CL**~~: quella implicita è affidabile (C0.1); il costo residuo è una sottomissione CL per run
  (≈0,1–0,3 ms del thread GPU del core quando la GPU è scarica, nullo quando è piena). Un'app che alterna centinaia di run per frame
  (compute e render intercalati) pagherebbe ancora: in quel caso conta il percorso "kernel da fragment".
- **VRAM da 256 MB** condivisa fra GL e CL: oggetti grandi possono fallire l'allocazione → errore `compute` e no-op.
- **Workgroup massimo 256** contro i 1024 di Metal: molti kernel scritti per Apple silicon usano 512/1024 thread con barriere e vanno
  rifiutati. Le app che leggono `maxTotalThreadsPerThreadgroup` si adattano, le altre no.
- **Kernel con simdgroup**: frequenti nel codice moderno (riduzioni, ML). Un'emulazione con memoria locale è possibile ma lenta e
  non è in v1.
- Il traduttore cresce: tenere il front-end AIR unico (`src/air/`) evita due copie divergenti.

## Uscita dalla sperimentazione
**Fatta il 2026-11-02 (0.10.0), vedi "Stato" in cima:** sezione "Sistema" invece di "Impostazioni" (richiesta dell'utente,
accanto a TeraScale Glass), chiave `System.Compute` invece di `Compute`, predefinito acceso. Criteri del piano: C0–C5 chiusi; nessun crash attribuibile all'estensione per 2 settimane con il compute acceso per tutte le app; frame time
delle app senza compute invariato; corpus e `run.sh` verdi a ogni `update.sh`. Allora:
- la sezione passa da "Sperimentale" a "Impostazioni" e `Experimental.Compute` diventa `Compute` (il core legge entrambi per una
  versione);
- l'interruttore per tutte le app resta, ma il predefinito diventa acceso solo se il registro mostra che non peggiora nulla.

**Nome.** "Animation Accel" descrive male la funzione: le animazioni di CoreAnimation passano già dal render e non usano questa
estensione, che serve al calcolo generale (GPGPU, filtri, particelle). Proposta: **TeraScale Compute** (bundle
`TeraScaleMTLCompute.bundle`, categoria di log `compute`, voce "Compute" nell'app). Il nome dice cosa fa e segue
"TeraScale Metal". Se si vuole il suffisso "Accel", **"Compute Accel"** resta coerente.
