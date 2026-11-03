# TeraScale Compute: ottimizzazione (bozza 2, 2026-11-02)

Seguito di `docs/PIANO-COMPUTE.md` (versione sperimentale 0.6.0). Raccoglie tre cose:
1. dove mettere i dati del compute per non togliere VRAM a OpenGL (valutazione del 2026-11-01);
2. cosa fa davvero il percorso OpenCL in Mappe vicino ai monumenti (sessione del 2026-11-01, 22:47–22:52);
3. la lista degli interventi sul percorso OpenCL, con priorità e ordine di lavoro.

Tutte le misure sono di questo iMac (iMac12,1, i3-2100, HD 6750M con **256 MB** di VRAM, driver CL "1.2 May 8 2018"),
macOS 26.6.

## Sintesi
- **iGPU (HD 2000): scartata.** Non è visibile né a OpenGL né a OpenCL, e Sandy Bridge non ha mai avuto OpenCL su GPU.
- **Partizionare la VRAM tra GL e CL: non serve, lo fa già il driver.** Il driver AMD sposta le risorse tra VRAM e memoria
  di sistema secondo l'uso. Possiamo però decidere noi dove mettere i dati del solo CL (`CL_MEM_USE_HOST_PTR`), e conviene
  farlo quando la VRAM scarseggia.
- **Mappe: nello scenario riprodotto OpenCL non lavora.** Colosseo in 3D standard e satellite, da 375 m a 12 m di scala,
  panoramiche: **0 dispatch, 0 run CL**. L'unico kernel (`VTMTSComputeFunction` di VideoToolbox) viene compilato
  **8 volte** (4 thread × 2 varianti), una volta in **412 ms**. Il collo di bottiglia misurato è un altro: fino a
  **1,1 s al secondo di attesa del drawable**.
- Il difetto visivo descritto ("si bugga avvicinandosi ai monumenti") **non è ancora riprodotto** dalle catture
  automatiche: serve una descrizione precisa (vedi "Da chiarire").

Le due righe su Mappe qui sopra sono superate dalla sezione "Stato": con la 0.7.0 il kernel di VideoToolbox lavora, e
senza compute i monumenti in 3D si vedono sbagliati.

## Stato: versione 0.7.0 (2026-11-02)

Interventi fatti tra il 2026-11-01 e il 2026-11-02, versione del driver **0.7.0** (`system/update-compute.sh`).
Istantanea prima delle modifiche: `snapshots/pre-compute-opt-20261101-2301.tgz`. Verifiche: `make test-compute` (ctest
42/42, glkernels, cltrans 21/22 con `simd_sum` rifiutato, clruntime, bufcoherence, dispatchbench con controllo di
completamento, `ctest --idle`) e `tests/system/run.sh` 13/13.

### A/B in Mappe (G1, Colosseo, copia con lo shim di `build/`, 0.7.0)
Catture e riassunti in `apps/landmark-colosseo-ab-1102/{compute,nocompute,compute-nosync}/`.

| | compute acceso | compute spento | compute acceso, `TSMTL_DISPLAY_SYNC=0` |
|---|---|---|---|
| Monumento 3D (standard, zoom 4) | corretto | **modello del Colosseo nero** | corretto |
| Satellite 3D (zoom 2 e panoramica) | corretto | **finestra tutta rossa** | corretto |
| Satellite 2D, standard 2D | corretti | corretti | corretti |
| Dispatch registrati / eseguiti / saltati | 524 / 524 / 0 | 630 / 0 (inerti) / 0 | 592 / 592 / 0 |
| Compilazioni CL | 0 (binari dalla cache su disco) | – | 0 |
| Tempo GPU dei kernel CL | 269 ms in tutta la corsa | – | 309 ms |
| Sottomissione CL (`cl submit ms`) | 1178 ms, ~2,2 ms per run | – | 967 ms, ~1,6 ms per run |
| Attesa `nextDrawable` (blocchi) | 9439 ms (459) | 8959 ms (488) | 10284 ms (504) |

- **Il difetto ai monumenti è riprodotto, ed è proprio l'assenza del compute**: senza `VTMTSComputeFunction` le texture
  dei modelli 3D e della satellite 3D non vengono convertite. Con la 0.7.0 il kernel gira su OpenCL e il risultato è giusto.
  Con la 0.6.0 il kernel veniva compilato ma non partiva mai (0 dispatch, vedi sezione 2).
- **X1 non serve**: `displaySyncEnabled` viene davvero spento (trace: `displaySync 0`), ma il layer di Mappe ha
  `presentsWithTransaction = 1`, quindi i present seguono i commit di CoreAnimation e non il vblank. L'attesa del drawable
  non cambia. Il knob resta per altre app; il default non cambia.
- `tools/cltrans apps/landmark-colosseo-compute-run1/cl --build` traduce e compila le due varianti reali salvate
  (`VTMTSComputeFunction` 80 ms di traduzione, `downscaleTexture` 1 ms).

### Esito degli interventi
| ID | Esito |
|---|---|
| A1, A2 | Fatti: una traduzione e una compilazione per chiave anche con chiamanti concorrenti. In Mappe 2 compilazioni invece di 8 |
| A3 | Fatto: binari CL su disco (`~/Library/Caches/com.terascale.mtlshim/cl/`), 0,3–0,8 ms per kernel invece di 60–1100 ms |
| A4, A5 | Fatti: varianti asincrone su una coda di sfondo; precompilazione al caricamento della libreria (`TSMTL_CL_PREWARM`) |
| B1 | Fatto `tests/compute/vtxfer.m`: `VTPixelTransferSession` pubblico non usa Metal su questo Mac (0 dispatch). Il kernel reale si verifica solo in Mappe (A/B sopra) |
| B2 | Fatto: contatori `computeRecorded/Skipped/Inert` |
| B3, B4, B5 | Fatti: indirizzamento per asse, `lod != 0` rifiutato solo con mip presenti, `is_null_texture` vero |
| B6 | Fatto: una riga per (kernel, motivo) ogni 5 s |
| C1 | Fatto: `setBytes` in blocchi gestiti da 64 KB riciclati a fine esecuzione. dispatchbench: ~50–70 µs di CPU per dispatch invece di 100–165 µs |
| C2, C3 | Fatti: tabella hash dei `cl_mem`, cache degli argomenti dei kernel |
| C4, E3 | Fatti: kernel che non leggono la forma del gruppo accodati una volta a 16×16 / 256 (`TSMTL_CL_RETILE=0` per l'A/B). Nessun guadagno GPU misurato su un kernel di luminanza |
| D1, D2, D3 | Fatti: invio del delta CPU invece della rilettura bloccante, argomenti indiretti letti da GL (corretto anche un bug di lettura vecchia), copie blit su GL quando un lato è più avanti sulla GPU |
| E1 | Misurato e lasciato: codice strutturato e "C con goto" danno binari e tempi uguali |
| E2 | Già così: accessi tipizzati quando l'allineamento dell'IR lo permette |
| E4 | Fatto: `-cl-fast-relaxed-math` per i kernel compilati in fast math, `-cl-mad-enable` per gli altri |
| G1, G2, G3 | Fatti: `tools/maps-landmark.sh`, tempi GPU dei kernel CL in `tsmtl stats` (`clGpuMs`, `clKernels`), `tests/compute/vramplace.c` |
| M2 | Non serve: non ci sono buffer solo CL da posizionare. vramplace con poca VRAM occupata: tutti i posizionamenti uguali |
| M3, M4 | Fatti: `TSMtlVRAMPressure()` (`vramPressure` nei dati), rilascio del contesto CL dopo 30 s senza dispatch (`TSMTL_CL_IDLE`) |
| M5 | Non fatto (bassa priorità) |
| X1 | Knob `TSMTL_DISPLAY_SYNC=0` e contatore `drawableBlocks`; senza effetto in Mappe (vedi sopra) |

### Bug trovato (presente nella 0.6.0) e corretto
Un fence GL non aspetta i kernel CL, quindi un command buffer poteva risultare completato prima che i suoi kernel fossero
eseguiti. Ora a fine run c'è un `clFlush` e il completamento aspetta il `cl_event` del run
(`TSMtlComputeTakeRunEvent`). `TSCL_FLUSH_MODE` 0/1/2 per l'A/B (default 0).

### Resta da fare
- **Rilascio fuori dalla coda GPU** (`TSCLRuntimeEndRunAsync`): il rilascio degli oggetti GL a fine run aspetta la coda
  del driver (il run precedente): ~21 ms per run da 12 ms di GPU in dispatchbench, 1,5–7 ms per run in Mappe (già
  5–20 ms nella 0.6.0). È la prossima leva sul costo per run.
- M5, solo se una misura lo chiede.

## 1. Memoria video: dove mettere i dati del compute

### Situazione misurata
| Grandezza | Valore | Fonte |
|---|---|---|
| VRAM totale | 256 MB | `system_profiler`, CGL `kCGLRPVideoMemoryMegabytes` |
| VRAM in uso a sistema quasi fermo | 177–233 MB | `PerformanceStatistics` di `AMDTurksGraphicsAccelerator`, `tsmtl stats` |
| VRAM libera con Mappe aperta | 34–70 MB | idem (`vramFree` di `tsmtl stats`) |
| GART (memoria di sistema mappata dalla GPU) | ~1,4 GB, 12–31 MB usati | idem |
| Dispositivi OpenCL | CPU (memoria unificata, 4 GB, 1 GB per allocazione), HD 6750M (256 MB, 128 MB per allocazione) | `clGetDeviceIDs` |
| Contesto OpenCL | +50–80 MB di memoria del processo | `docs/PIANO-COMPUTE.md`, "Benchmark" |

### Offload sulla grafica integrata (HD 2000): scartato
- `AppleIntelSNBGraphicsFB` e `AppleIntelHD3000Graphics` si caricano, ma nessun `IOAccelerator` Intel si aggancia:
  nessun renderer CGL, nessun dispositivo CL. Per le app la GPU integrata non esiste.
- Anche con un acceleratore attivo: Sandy Bridge non ha mai avuto OpenCL su GPU (né Apple né Intel; parte da Ivy Bridge).
- Potenza: 6 EU, all'incirca quanto i 2 core AVX della CPU. E i dati dovrebbero comunque passare dalla PCIe, perché le
  texture GL stanno nella VRAM della Radeon.
- **Variante praticabile: la CPU come dispositivo OpenCL.** Il codice OpenCL C di `TSAirOpenCL` funziona così com'è e non
  occupa VRAM. Prezzo: niente condivisione GL↔CL (copie sulla PCIe a ogni passaggio) e concorrenza con l'app su 2 core
  / 4 thread. Ha senso solo come ultima risorsa (intervento M5).

### Partizionamento dinamico GL/CL: già fatto dal driver
GL e CL dello stesso processo allocano dallo stesso gestore (`AMDRadeonX3000`). Quando la VRAM finisce, il kernel sposta
nella GART le risorse usate meno di recente (`texturePageOutBytes`, `vramEvictionWaitTime`). Non c'è una partizione da
regolare. Lo spostamento sotto pressione però costa caro:

| Kernel che legge e scrive due buffer da | VRAM (default) | `CL_MEM_ALLOC_HOST_PTR` | `CL_MEM_USE_HOST_PTR` |
|---|---|---|---|
| 32 MB l'uno (stanno in VRAM) | 19,6 GB/s | 19,8 GB/s | – |
| 64 MB l'uno (metà della VRAM) | **4,1 GB/s** (il driver continua a spostare) | 6,6 GB/s | **8,8 GB/s** |

Probe: `vram.c` (fuori dal repo, da portare in `tests/compute/vramplace.c`, intervento G3). I contatori di
`PerformanceStatistics` sono di sistema e si aggiornano circa una volta al secondo. Il probe prende l'ultimo
`IOAccelerator` trovato e gli risultava `vramFreeBytes` fermo a 256 MB, mentre `tsmtl stats` dà valori plausibili
(34–70 MB): M3 deve partire dal codice di `tsmtl`, non dal probe.

### Interventi sulla memoria
| ID | Intervento | Dove | Effetto atteso | Costo |
|---|---|---|---|---|
| M1 | **Niente copie CL dei dati GL.** Già così per buffer e texture (`cl_mem` creati sugli oggetti GL). Verificare che lo snapshot `_clBase` di `prepareGPUWrite` sia l'unica copia in più, e che sia solo memoria di sistema | `TSMtlResources.m:251` | nessuna VRAM in più per il compute | S |
| M2 | **Posizionamento dei buffer solo CL** (staging di `setBytes`, scratch, intervento C2) in `CL_MEM_USE_HOST_PTR` sopra una soglia di dimensione o quando c'è pressione | `TSCLRuntime.c` | non toglie VRAM a GL; 2× più veloce del default sotto pressione | M |
| M3 | **Segnale di pressione**: `texturePageOutBytes` e `vramEvictionWaitTime` dall'IORegistry, letti al massimo una volta al secondo fuori dalla coda GPU | nuovo `TSMtlVRAMPressure()` in `TSMtlSystem.m` | decide M2 e M4 | S |
| M4 | **Rilascio del contesto CL dopo inattività** (es. 30 s senza dispatch): `TSCLRuntimeDestroy`, poi ricreazione pigra (12–28 ms misurati) | `TSMtlComputeCL.m` (`TSCLState`) | −50–80 MB di memoria nei processi che usano il compute una volta sola (GridCraft all'avvio, Mappe) | M |
| M5 | **CPU come dispositivo di riserva** per kernel senza oggetti GL (solo buffer `shared`), quando M3 segnala pressione forte | `TSCLRuntime.c` (secondo contesto) | zero VRAM; utile solo per kernel piccoli | L, bassa priorità |

## 2. Mappe vicino ai monumenti: cosa succede davvero

### Sessione riprodotta (2026-11-01, Mappe di sistema, driver 0.6.0 installato, compute "on list")
Scenario: `maps://?ll=41.8902,12.4922` (Colosseo), Vista → Mostra mappa 3D, due e poi quattro "Ingrandisci" (fino a
12 m di scala, edifici 3D e modello del Colosseo visibili), passaggio a Satellite, satellite 3D da vicino (36 m),
panoramiche con `tools/scroll`. Statistiche: `tsmtl stats --json --watch 1`. Log: `log stream` sul sottosistema dello shim.

| Misura | Valore |
|---|---|
| Kernel compute visti | solo `VTMTSComputeFunction` (VideoToolbox, conversione dei pixel delle immagini decodificate) |
| Compilazioni | **8**: 4 all'avvio (stesso sorgente, 4 thread, stesso millisecondo, 5 ms ciascuna: cache di CVMServer), altre 4 al passaggio a Satellite (**90, 90, 121, 412 ms**) |
| `dispatches` / `clRuns` | **0 / 0** per tutta la sessione, in ogni secondo campionato |
| fps durante zoom e panoramica | 9–30 |
| `drawableWaitMs` (per secondo) | **295–1129** |
| `gpuBusy` | 0,2–4,7 % |
| Righe di errore o "skipped" del compute | nessuna |
| Catture | nessun artefatto visibile nei fotogrammi catturati (standard 3D, satellite, satellite 3D) |

### Cosa se ne ricava
- Nello scenario riprodotto **il rendering dei monumenti non passa da OpenCL**: i modelli 3D e la satellite si disegnano con
  il percorso GL. Se con il compute acceso Mappe va meglio, la causa va cercata altrove (vedi "Da chiarire", punto 3).
- **Le compilazioni duplicate e bloccanti sono reali**: 4 thread di VideoToolbox creano la stessa pipeline nello stesso
  momento e ognuno compila per conto suo. Al primo uso di una variante un thread resta fermo fino a 412 ms. Se è un thread
  che decodifica le tessere, le tessere arrivano in ritardo (le tessere grigie viste per ~10 s al passaggio a Satellite
  sono compatibili con questo, ma potrebbero essere solo rete). Interventi A1–A3.
- **Lo scatto durante il movimento viene dalla presentazione, non dalla GPU**: l'app passa fino a 1,1 s al secondo (somma
  su più thread) bloccata in `nextDrawable`, mentre la GPU è quasi ferma. Intervento X1, fuori dal compute ma il più
  visibile in Mappe.

### Da chiarire con l'utente prima di toccare il codice
1. **Che aspetto ha il difetto**: tessere nere o grigie, colori sbagliati, sfarfallio, triangoli "esplosi", scatti/blocchi,
   chiusura dell'app? Una registrazione dello schermo (Cmd-Shift-5) o due screenshot bastano.
2. **Dove e in che modalità**: mappa standard 3D, satellite, satellite 3D (Flyover), "Guardati intorno", tour Flyover?
   Quale monumento?
3. **Il confronto**: con il compute spento per Mappe (`tsmtl compute`, voce di Mappe) i monumenti non si vedono, o si
   vedono peggio? Se sì, in quale modalità: è lì che OpenCL lavora davvero e lo scenario va ripetuto in quel punto.

## 3. Interventi sul percorso OpenCL

Priorità: **P1** sicuramente utile ora (misurato o difetto evidente), **P2** utile quando arrivano app con più kernel,
**P3** solo se una misura lo chiede. Costo: S (ore), M (1–2 giorni), L (di più).

### A. Compilazione e avvio (visti in Mappe)
| ID | P | Intervento | Dove | Perché |
|---|---|---|---|---|
| A1 | P1 | **Una sola compilazione per sorgente anche in parallelo.** Oggi il controllo della cache e l'inserimento sono due sezioni critiche separate: chi arriva durante una compilazione la ripete. Mettere in `programs` una voce "in corso" (gruppo `dispatch` o `NSCondition`) e far aspettare gli altri | `TSMtlComputeCL.m:141`, `:180` | 4 compilazioni identiche nello stesso millisecondo, due volte in una sessione |
| A2 | P1 | **Stessa cosa per la traduzione AIR → OpenCL C** (la `NSCache` per bitcode ha lo stesso buco) | `TSMtlComputeCL.m:119` (`translations`) | traduzioni ripetute, meno costose ma inutili |
| A3 | P1 | **Cache su disco dei binari CL** (`CL_PROGRAM_BINARIES` → `~/Library/Caches/com.terascale.mtlshim/cl/<sha256>.bin`, chiave = sorgente + opzioni + versione driver CL; `clCreateProgramWithBinary`), come la cache GLSL (C3) | `TSMtlComputeCL.m` | 90–412 ms per variante nuova anche con l'app già avviata: la cache di CVMServer non copre le varianti nuove |
| A4 | P2 | **Varianti asincrone davvero asincrone**: `newComputePipelineStateWithFunction:completionHandler:` (e le altre due) compilano su una coda di sfondo invece che sul thread chiamante | `TSMtlDevice.m:414–426` | oggi bloccano il chiamante come la versione sincrona |
| A5 | P2 | **Pre-compilazione** quando una libreria contiene kernel noti (VectorKit, VideoToolbox): tradurre e compilare in sfondo alla `newFunctionWithName:` | `TSMtlPipeline.m:827` | sposta il costo fuori dal primo frame |

### B. Correttezza
| ID | P | Intervento | Dove | Perché |
|---|---|---|---|---|
| B1 | P1 | **Test di `VTMTSComputeFunction` fuori da Mappe**: una CLI che usa `VTPixelTransferSession` sul nostro device con i formati di Mappe (420 biplanare → BGRA, e il contrario), confronto con il risultato su CPU (`imgdiff`). È l'unico kernel reale di Mappe e oggi nessuno ne verifica l'uscita | `tests/compute/vtxfer.m` | se un giorno parte (vedi "Da chiarire", punto 3) deve essere giusto |
| B2 | P1 | **`dispatchGrid` registrato ma mai eseguito**: contare nei dati `computeRecorded` accanto a `dispatches`, per distinguere "nessun dispatch" da "dispatch persi" (es. command buffer mai committati) | `TSMtlCommands.m:338`, `TSMtlSystem.m` | in Mappe i dispatch sono 0: oggi non si sa se l'app non li chiede o se si perdono |
| B3 | P2 | **Indirizzamento per asse dei sampler**: si usa solo `sAddressMode`. OpenCL 1.2 ne ha uno solo: se gli assi differiscono, emettere il clamp/repeat a mano nel kernel invece di sbagliare in silenzio | `TSMtlComputeCL.m:191`, `TSAirOpenCL.m` | limite noto della 0.6.0 |
| B4 | P2 | **`sample` con LOD/mip**: oggi legge il livello 0. Con `lod` costante 0 è giusto; altrimenti rifiutare il kernel con un motivo leggibile (meglio no-op dichiarato che immagine sbagliata) | `TSAirOpenCL.m` | idem |
| B5 | P2 | **`is_null_texture` sempre falso**: passare un flag per argomento (bit in un `uint` extra) invece di saltare l'intero dispatch | `TSAirOpenCL.m`, `TSMtlComputeCL.m:271` | limite noto della 0.6.0 |
| B6 | P3 | **Log a raffica**: le righe "dispatch skipped" escono a ogni dispatch. Limitarle a una per (kernel, motivo) ogni 5 s | `TSMtlComputeCL.m` | con un kernel rifiutato a 60 fps il log diventa rumore e costa CPU |

### C. Costi per dispatch (CPU, coda GPU)
| ID | P | Intervento | Dove | Perché |
|---|---|---|---|---|
| C1 | P1 | **`setBytes` senza un `MTLBuffer` nuovo a ogni chiamata.** Oggi ogni `setBytes` crea un buffer, quindi un buffer GL, un `clCreateFromGLBuffer` (cache sempre mancata), un acquire e poi un `Forget`. Per i kernel CL: argomento per valore (≤ 4 KB, `__constant` struct) o anello di staging con un solo `cl_mem` e offset | `TSMtlCommands.m:302`, `TSMtlComputeCL.m:263` | diverse chiamate al driver in più per dispatch (creazione GL, wrap CL, rilascio) |
| C2 | P2 | **Cache dei `cl_mem` con tabella hash** invece della scansione lineare per (nome, target, livello) | `TSCLRuntime.c:126` | con molti buffer (VectorKit, giochi) la scansione cresce a ogni dispatch |
| C3 | P2 | **Argomenti invariati non reimpostati**: ricordare per kernel gli ultimi `cl_mem`/offset/sampler e chiamare `clSetKernelArg` solo per quelli cambiati | `TSMtlComputeCL.m:303–330` | ~10–20 chiamate per dispatch con 6 argomenti; costo piccolo ma a ogni dispatch |
| C4 | P3 | **Bordi della griglia**: fino a 8 enqueue per dispatch (~0,035 ms l'uno sulla sottomissione). Per i kernel che non leggono la forma del gruppo, un solo enqueue arrotondato con un controllo `gid < grid` nel kernel | `TSMtlComputeCL.m:335` | meno enqueue, sottomissioni più leggere |

### D. Coerenza della memoria
| ID | P | Intervento | Dove | Perché |
|---|---|---|---|---|
| D1 | P1 | **Rilettura dei buffer scritti da CL limitata a ciò che serve.** Oggi a ogni command buffer che scrive un buffer `shared`: snapshot completo (`memcpy`), `glGetBufferSubData` di tutto il buffer (bloccante, PCIe) e confronto byte per byte. Proposte: (a) intervallo scritto noto dal traduttore quando l'indice è `gid`-lineare; (b) rilettura asincrona (`glCopyBufferSubData` in un buffer di staging + fence, mappatura dopo) invece di bloccare la coda GPU | `TSMtlResources.m:251–296` | il costo scala con la dimensione del buffer, non con quanto scrive il kernel |
| D2 | P2 | **Argomenti indiretti senza stallo**: `dispatchThreadgroupsWithIndirectBuffer` legge `contents` sulla coda GPU, che fa scattare D1 in modo bloccante. Leggere solo i 12 byte (`glGetBufferSubData` di 12 byte, o `clEnqueueReadBuffer` di 12 byte nello stesso run) | `TSMtlCommands.m:356` | un dispatch indiretto oggi costa una rilettura completa del buffer |
| D3 | P2 | **Buffer `private` scritti da CL**: non serve snapshot né merge (nessuna copia CPU); verificare che `prepareGPUWrite` non allochi `_clBase` neanche per errore e che le copie blit leggano GL | `TSMtlResources.m:251` | memoria e tempo risparmiati |

### E. Qualità del codice generato (GPU)
La HD 6750M è TeraScale 2 (VLIW5): codice scalare usa 1 slot su 5, il controllo di flusso irriducibile è lento.
| ID | P | Intervento | Dove | Perché |
|---|---|---|---|---|
| E1 | P2 | **Codice strutturato anche per OpenCL**: usare il piano di `TSStructurer` (già usato per il GLSL, A2 di `docs/OTTIMIZZAZIONE.md`) invece di "C con goto" quando riesce | `TSAirOpenCL.m`, `TSAirTranslator.m` | il compilatore CL di AMD gestisce meglio cicli e if strutturati; misurare con `tools/compute-bench.sh` |
| E2 | P2 | **Accessi tipizzati quando l'allineamento è noto**: oggi puntatori a byte + `vloadN`; con offset noti multipli di 16 usare `float4*` diretti (come A3 del GLSL) | `TSAirOpenCL.m` | carichi vettoriali veri, meno istruzioni di indirizzamento |
| E3 | P2 | **Forma dei gruppi per i kernel su immagini**: se l'app chiede gruppi 1D su una griglia 2D (o la lascia al driver), usare 16×16 quando il kernel non legge la forma del gruppo | `TSMtlComputeCL.m:248–258` | misurato in C0.1: le strisce 1D del driver vanno a metà velocità |
| E4 | P3 | **`-cl-fast-relaxed-math` / `-cl-mad-enable`** solo per kernel compilati da Metal con `fastMathEnabled` (default di Metal) | `TSAirOpenCL.m` (opzioni) | Metal compila in fast math per default; OpenCL no |

### F. Memoria
Vedi sezione 1, interventi M1–M5.

### G. Strumenti e diagnostica
| ID | P | Intervento | Dove | Perché |
|---|---|---|---|---|
| G1 | P1 | **Scenario "monumenti" ripetibile**: `tools/maps-landmark.sh` (URL `maps://` del monumento, 3D, zoom, satellite, panoramica, catture a raffica, `tsmtl stats --json`) con `--compute/--no-compute` | `tools/` | questa sessione è stata fatta a mano; serve un A/B ripetibile |
| G2 | P1 | **Tempi GPU dei kernel CL** (eventi CL con profiling solo con `TSMTL_STATS`, sommati per kernel) in `tsmtl stats` | `TSCLRuntime.c` | oggi si vede il costo di sottomissione, non quello del kernel |
| G3 | P2 | Probe di posizionamento VRAM (sezione 1) in `tests/compute/vramplace.c`, dentro `make compute` | `tests/compute/` | ripetere la misura dopo M2 |

## 4. Visto in Mappe, fuori dal compute
| ID | P | Intervento | Dove | Perché |
|---|---|---|---|---|
| X1 | P1 | **Attesa del drawable**: fino a 1129 ms/s bloccati in `nextDrawable` con la GPU all'1–5 %. Capire dove si accumula il ritardo di presentazione (numero di drawable, `displaySyncEnabled`, quando torna libero il drawable dopo il present, IOSurface ancora in uso da WindowServer) | `TSMtlLayer.m:51–60` | è lo scatto più visibile durante zoom e panoramica, e non dipende dal compute |

## 5. Ordine di lavoro proposto
1. **Da chiarire** (sezione 2) e **G1**: senza il difetto riprodotto e uno scenario ripetibile, le correzioni sono alla cieca.
2. **A1, A2, A3**: compilazioni una sola volta e su disco (piccolo, misurabile subito in Mappe).
3. **B2, G2**: sapere se i dispatch mancano o si perdono, e quanto costano sulla GPU.
4. **X1**: lo scatto in movimento.
5. **C1, D1, D2**: i costi per dispatch e le riletture, appena c'è un'app che lancia dispatch a ogni frame.
6. **M2–M4**: posizionamento e rilascio della memoria.
7. **B1, B3–B5, E1–E4**: correttezza estesa e qualità del codice, guidate dai kernel delle app vere.

Ogni intervento si chiude con: `make test-compute` verde, `tests/system/run.sh` verde, A/B con `tools/maps-bench.sh`
(o G1) e `tools/compute-bench.sh`, riga nella sezione "Stato" di questo documento.
