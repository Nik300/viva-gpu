# TeraScale Metal Shim: piano (revisione 12: Liquid Glass e .mslbundle, driver 0.8.0)

## Filosofia
Le app devono **rilevare un device Metal e avviarsi**.
- Quello che OpenGL 4.1 sa fare in modo efficiente viene eseguito davvero.
- Le funzioni complesse vengono accettate e trasformate in no-op o in un fallback economico.
- Gli effetti moderni (blur, ray tracing, MPS, ecc.) restano spenti.
- Mai restituire `nil` dove un'app si aspetta un oggetto: meglio un oggetto "vuoto" che un crash.

## Risultati della Fase 0 (verificati su questo Mac, sola lettura)
| Domanda | Risposta | Prova |
|---|---|---|
| Come Metal trova un driver? | Ascolta i servizi `IOAccelerator` e legge `MetalPluginName` e `MetalPluginClassName` | stringhe di Metal.framework: `IOAccelerator`, `IOServiceAddMatchingNotification`, `MetalPluginName`, `MetalPluginClassName` |
| Oggi | l'acceleratore `AMDTurksGraphicsAccelerator` pubblica solo `IOGLBundleName`, quindi 0 device Metal | `ioreg`, `MTLCopyAllDevices` = 0 |
| Interfaccia del driver | classe device con `-initWithAcceleratorPort:` che estende `_MTLDevice`. La base gestisce librerie e funzioni e il frontend del compilatore; il driver fornisce buffer, texture, sampler, code, encoder, pipeline e varianti degli shader | introspezione runtime di `AppleParavirtDevice : MTLIOAccelDevice : _MTLDevice` |
| Modello di riferimento | `AppleParavirtGPUMetal.bundle` (binario su disco): serializza i comandi (`PGSerializer*`) e li invia altrove, come faremo noi verso OpenGL | `otool -ov` → 28 classi |
| Shader | Metal.framework compila MSL → AIR e chiama un **plugin di compilazione** del driver con 4 funzioni C (`MTLCompilerCreate/Delete/BuildRequestWithOptions/ReleaseReply`); la richiesta contiene un `llvm::Module` | export di `libAppleParavirtCompilerPlugin.dylib` |
| LLVM | `GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib` espone 1120 funzioni dell'API C di LLVM (parse, write bitcode, iterazione IR) | `dyld_info -exports` |
| Back-end disponibili | OpenGL 4.1 core (niente compute né SSBO), OpenCL 1.2 sulla GPU | sonde CGL/CL |

## Architettura
```
App ─► Metal.framework ─► IOAccelerator "AMDTurksGraphicsAccelerator"
                              │  MetalPluginName      = TeraScaleMTLDriver
                              │  MetalPluginClassName = TSMtlDevice
                              ▼
                    TeraScaleMTLDriver.bundle  (TSMtlDevice : _MTLDevice)
                      ├─ risorse:  MTLBuffer → buffer GL + copia CPU, MTLTexture → texture GL / IOSurface
                      ├─ comandi:  encoder che registrano una lista di comandi, rieseguita su un thread GL
                      ├─ shader:   plugin MTLCompiler (C, libLLVM di sistema): AIR → GLSL 4.10
                      │            se la traduzione fallisce: shader di fallback (passthrough o colore pieno)
                      ├─ present:  CAMetalLayer → IOSurface → CGLTexImageIOSurface2D
                      └─ stub:     compute, ICB, argument buffer, acceleration structure, ecc. → no-op
Registrazione: plugin Lilu `TSMetalEnabler.kext`, iniettato da OpenCore, che aggiunge le 2 proprietà all'acceleratore.
```

### Sicurezza (fondamentale)
- **Lista di esclusione dei processi**: `WindowServer`, `loginwindow`, `Dock`, `SystemUIServer`, `ControlCenter`, `NotificationCenter`, `WallpaperAgent` e simili. Per questi `initWithAcceleratorPort:` restituisce `nil`, così lo stack non-Metal di OCLP che disegna il desktop resta com'è. Va verificato che Metal.framework scarti un device `nil` senza problemi.
- **Interruttore generale**: senza il kext Lilu (avvio dalla EFI della chiavetta, oppure kext disabilitato in `config.plist`) Metal torna a 0 device e il sistema è esattamente com'è oggi.
- **Lista di inclusione facoltativa** (`/Library/Preferences/com.terascale.mtlshim.plist`) per abilitare lo shim solo per app scelte durante i test.

## Cosa viene fatto davvero, cosa diventa no-op
| Funzione | Trattamento |
|---|---|
| Device info, `supportsFamily`, limiti, `supportsFeatureSet` | dichiara **MTLGPUFamilyMac2 / Common2**, limiti presi dai valori GL reali, ray tracing / dynamic libraries / function pointer = NO |
| Buffer (shared / managed / private) | buffer GL; `contents` = copia CPU, caricata al commit (o con `didModifyRange`) |
| Texture 1D/2D/3D/cube/array, mipmap, formati comuni e BC1–3 | texture GL; i formati non supportati diventano RGBA8 |
| Sampler, depth/stencil, blending, viewport, scissor, cull, MSAA | stato GL |
| Render pass, load/store, clear, MRT fino a 8 | FBO GL |
| Draw (indicizzati, instanced, indiretti) | GL nativo |
| Blit (copie, fill, mipmap) | `glCopyImageSubData` assente in 4.1 → `glBlitFramebuffer` / copie tramite PBO |
| Shader vertex/fragment | traduzione AIR → GLSL 4.10; fallback se non traducibile |
| Compute encoder | **no-op** (accetta tutto, non esegue). Facoltativo più avanti: kernel semplici su OpenCL |
| Fence, event, shared event | semplificati: sincronizzazione al commit |
| Heap, argument buffer, ICB, acceleration structure, visible function table, tile shader, rasterization rate map | oggetti validi ma inerti |
| `CAMetalLayer` / drawable / present | IOSurface condivisa con GL |
| Cattura, contatori, statistiche | disattivati |

## Fasi
| Fase | Contenuto | Si chiude quando | Modifiche al sistema |
|---|---|---|---|
| **0 ✅** | ricognizione | questo documento | nessuna |
| **1 ✅ – Prototipo in-process** | `TSMtlDevice` in un dylib, creato direttamente da un'app di test (senza IORegistry). Buffer, texture, coda e command buffer vuoti | `id<MTLDevice>` funzionante dentro il test; `MTLCreateSystemDefaultDevice` resta nil | nessuna |
| **2 ✅ – Render** | encoder di render, stato, FBO, present su IOSurface/`CAMetalLayer`, shader passthrough | finestra di test con clear e triangolo | nessuna |
| **3 ✅ – Traduttore AIR → GLSL** | AIR → GLSL (sottoinsieme: aritmetica, vettori, texture sample, uniform/buffer); cache su disco | sample Apple base e un'app wgpu/egui (in-process) | nessuna |
| **3b ✅ – Ottimizzazione** (prima di ogni altra fase) | shader strutturati e IR ripulito con la libLLVM di sistema; comandi POD con stato precalcolato e dirty bit; upload incrementali; cache dei programmi, cache su disco e riscaldamento al link. Dettagli e misure in `docs/OTTIMIZZAZIONE.md` | criteri di chiusura raggiunti (vedi `docs/OTTIMIZZAZIONE.md`) | nessuna (solo la cache in `~/Library/Caches/com.terascale.mtlshim`) |
| **4 – Registrazione** (pronta, da installare) | kext Lilu che aggiunge le proprietà e la deroga alla library validation; bundle in `/Library/GPUBundles` (volume dati, non sigillato); policy per app; app di controllo `tsmtl` | `MTLCopyAllDevices` = 1 per le app, 0 per WindowServer (verificato in simulazione, `make test` → system) | EFI (OpenCore) + `/Library/GPUBundles`, `/Applications`, `/usr/local/bin` con `system/install.sh`; **il volume di sistema non si tocca**. Dettagli: `docs/FASE4.md` |
| **5 – Compatibilità** | prova con le app che ti servono; per ognuna si aggiungono gli stub mancanti | lista di app che si avviano | come Fase 4 |

Stima: Fasi 1–2 in poche sessioni di lavoro; Fase 3 è la più lunga; Fase 5 è iterativa.

## Risultati della Fase 1 (2026-10-30)
Codice in `src/` (`libTSMetal.dylib`), test in `tests/phase1.m` (`make test` → 44/44, stabile su 5 esecuzioni).

| Scoperta | Dettaglio |
|---|---|
| `-[_MTLDevice init]` funziona senza acceleratore | il rischio "dati privati obbligatori" non si è verificato per la creazione del device |
| Famiglie GPU = `-featureProfile` | `initGPUFamilySupport` → `getSupportedFamilies(profile)`. Mappa sondata: 0–12 = GPU Apple; **10000** = Common1-2; **10001** = Mac2 + Common1-3 (scelto); 10002 = + Metal3 |
| Limiti = ivar `_limits` (offset 8, 264 byte, 65 campi) | struct in `TSPrivate.h`, scritta solo se gli offset coincidono (controllo a runtime) |
| Coda / command buffer | sottoclassi di `_MTLCommandQueue` / `_MTLCommandBuffer`; il driver implementa `submitCommandBuffers:count:` e poi chiama `didScheduleWithStartTime:…` + `commandBufferDidComplete:startTime:completionTime:error:` → handler, stato, `waitUntilCompleted` e ordine funzionano |
| Encoder | sottoclassi di `_MTLCommandEncoder`; blit eseguiti davvero (CPU), render/compute inerti |
| Rete di sicurezza | catch-all `forwardInvocation:` su tutte le classi: ogni selettore mancante restituisce zero/nil invece di un'eccezione; con `TSMTL_LOG=1` elenca i metodi mancanti per app |
| **MSL → AIR funziona già** | `newLibraryWithSource:` produce `_MTLLibrary`/`_MTLFunction` validi usando il compilatore di sistema |
| **Pipeline = nil senza errore** | `newRenderPipelineStateWithDescriptor:error:` → nil, error nil: serve il back-end (`newVertexVariantWithCompilerOutput:…`, `newRenderPipelineWithDescriptor:vertexVariant:fragmentVariant:errorMessage:` come in Paravirt). Primo lavoro della Fase 2 |
| VRAM | 256 MB reali (ioreg `ATY,memsize`); `maxBufferLength` = 256 MB |

Limiti noti del prototipo: risorse solo in memoria CPU (allineata a pagina, pronta per GL client storage); viste texture con formati di dimensione diversa non convertite; `generateMipmaps` no-op fino alla Fase 2.

## Risultati della Fase 2 (2026-10-30)
`make test` → phase1 44/44, phase2 26/26 (pixel verificati). `build/window [secondi]` apre una finestra con `CAMetalLayer`, clear animato e triangolo che ruota.

| Tema | Scelta / risultato |
|---|---|
| `CAMetalLayer` | **verificato con cattura della finestra composta da WindowServer** (2 scatti a 1,5 s: frame aggiornati, orientamento e verso di rotazione corretti). Accetta il device dello shim; i drawable sono IOSurface creati tramite il nostro `newTextureWithDescriptor:iosurface:plane:`; `presentDrawable` funziona (~53 fps con un NSTimer, limite del test) |
| Thread GL | un contesto CGL 4.1 core per device, usato solo su `gpuQueue`; il submit esegue, fa `glFlush` e solo dopo notifica "scheduled" (il present parte da lì) |
| Coordinate | il wrapper GLSL del vertex shader applica `y = -y`, `z = 2z - w` → la riga 0 resta in alto ovunque (texture, viewport, scissor, IOSurface), senza capovolgere dati |
| Winding | assunto: Metal valuta il winding in NDC y-su (come GL) → con il flip, Metal CW = `GL_CCW`. **Da confermare con un'app reale** |
| Coerenza dati | buffer: fa fede la CPU, upload GL una volta per command buffer (private: solo dopo scritture blit); texture: contatore di generazione + "GPU owner" con readback su richiesta; viste = texture GL separate sincronizzate |
| IOSurface | rendering su `GL_TEXTURE_RECTANGLE` legata alla surface (zero copie); per campionarla, copia GPU verso una 2D |
| Uniform | ring UBO allineato a 256: copre `setBytes`, offset non allineati, buffer scritti dalla CPU |
| Pipeline | costruite dallo shim (override pubblici di `newRenderPipelineState…`); GLSL dal registro (ABI in `src/TSMtlPipeline.m`); senza GLSL → fallback magenta, mai nil. Le pipeline di compute sono oggetti inerti |
| Prestazioni | ~105.000 draw/s di overhead CPU (200 frame × 50 draw a ~2100 fps) |

Non ancora supportato: depth e stencil in texture separate (si usa solo il depth), BC6H/BC7 (manca BPTC su questa GPU → texture nera), viewport multipli, query di occlusione, `setVertexBuffer` letto come storage buffer negli shader (serve la mappatura su texture buffer nella Fase 3), sampler `constexpr` (Fase 3).

## Risultati della Fase 3, parte principale (2026-10-31)
`make test`: phase1 44/44, phase2 26/26 (GLSL a mano), **phase3 26/26 (stessi test, shader tutti tradotti)**, **translate 12/12** (shader del corpus `tests/corpus/apps.metal` eseguiti e confrontati con valori calcolati). `tools/airtrans file.metal` traduce e compila con il driver ogni funzione di un file; `tools/airdump` stampa l'AIR. La finestra di prova usa ormai solo il traduttore (verificata con cattura).

| Tema | Scelta / risultato |
|---|---|
| Sorgente | `-[_MTLFunction bitcodeData]` = bitcode AIR (wrapper `0B17C0DE`); letto con la **libLLVM di sistema** (`GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib`, nella dyld cache) via API C caricata con `dlsym` (`src/TSLLVM.h`) |
| Interfaccia | dai metadati `!air.vertex` / `!air.fragment`: attributi, `vertex_id`/`instance_id` (+ uniform `ts_base_instance`), varying collegati per chiave (`generated(...)`, `user(locN)`) con le interpolazioni prese dal fragment, render target, depth, sample mask, point size/coord, front facing |
| Memoria dei buffer | puntatore = (buffer, offset in byte); letture ricostruite da parole a 32 bit → layout Metal esatti (`packed_float3`, `half`, array in struct, stride). `constant` → UBO `uvec4[]` (dimensione dai metadati, 64 KB se ignota); `device` → texture buffer R32UI + uniform `_off` (GL 4.1 non ha SSBO) |
| Memoria privata | `alloca` e tabelle `constant` → variabili/costanti GLSL con percorsi lvalue |
| Controllo di flusso | 1 blocco → codice lineare; altrimenti macchina a stati `while/switch` in reverse post-order, phi → copie parallele sugli archi |
| Texture | sample (bias/level/gradient/offset), 2D/array/cube/3D, compare (shadow), read (`texelFetch`), gather, dimensioni. Una uniform GLSL per coppia (texture, sampler): `ftexT_sS`, `ftexT_kXXXX` per i sampler `constexpr` (formato dei bit decodificato, vedi sotto), `_c` per il confronto |
| Sampler `constexpr` | parola a 64 bit: address s/t/r 3 bit ciascuno, mag 9-10, min 11-12, mip 13-14, pixel 15, compare 16-19 (enum MSL), anisotropia-1 20-23, lod min/max come half 24-39/40-55, bordo 56-57 |
| Cache | per (bitcode, interpolazioni); `TSMTL_DUMP_GLSL=1` stampa il GLSL generato |

Non ancora supportato (la pipeline usa il fallback magenta e `TSMTL_LOG=1` dice perché): chiamate a funzioni non inlinate, scritture in buffer `device` dal fragment (ignorate), texture `read_write`/scrittura, atomiche, operazioni simdgroup/quad, argument buffer, function constants (non provati), buffer `constant` > 64 KB, array di array. Prestazioni: shader con cicli diventano macchine a stati, più lenti su TeraScale.

### Prova con un'app vera: ArtCraft Launcher 0.8.1 (wgpu + egui) — riuscita (2026-10-31)
- Iniezione senza toccare il sistema: `build/libTSMetalInject.dylib` (shim completo + `__DATA,__interpose` di `MTLCreateSystemDefaultDevice`, `MTLCopyAllDevices`, `MTLCopyAllDevicesWithObserver`, che restituiscono +1 come gli originali). ArtCraft ha l'hardened runtime senza entitlement, quindi si usa una **copia** in `apps/` firmata ad-hoc senza runtime; l'originale in `/Applications` è intatto. Script: `tools/shim-run.sh /Applications/App.app`.
- Risultato: interfaccia completa (testo, icone, dialoghi), ~9,5% CPU a riposo, 87 MB, nessun fallback, errore GL o metodo mancante nel log.
- Correzioni emerse: proprietà dei valori restituiti dall'interposer (+1, altrimenti over-release in winit); traduttore: **inlining delle funzioni non inlinate** dal compilatore (`sample_texture` di egui) e **aritmetica di puntatori negli array privati** (ciclo di azzeramento del padding generato da naga).
- `TSMTL_DUMP_DIR=<dir>` salva ogni sorgente MSL compilato dall'app (per riprodurre i problemi con `tools/airtrans`).

## Fase 3b – Ottimizzazione (analisi del 2026-10-31)
Analisi completa, con misure e piano di lavoro, in `docs/OTTIMIZZAZIONE.md`; benchmark in `bench/` (`bench/build.sh`).
Risultati principali, misurati su questo iMac:
- Lo shader di frammento reale di egui costa 19,0 ms per copertura a 1080p. La stessa logica con controllo di flusso strutturato e IR ripulito costa 0,52 ms (36×). La macchina a stati `while/switch` è il problema numero uno della GPU.
- `LLVMRunPasses` della libLLVM di sistema esegue inline, sroa, loop-unroll, instcombine, dse, simplifycfg e structurizecfg sull'AIR. Solo la pulizia vale 3,5× sullo shader di egui.
- CPU: 16,4 µs per draw oggi contro 1,4–1,7 µs del pavimento GL con solo lo stato cambiato. Circa metà del tempo va in runtime Objective-C, blocchi e malloc.
- Primo draw (compilazione differita del driver): fino a 206 ms con il GLSL di oggi. I program binary non esistono (`GL_NUM_PROGRAM_BINARY_FORMATS = 0`), quindi servono GLSL compatto, cache dei programmi, cache su disco e compilazione asincrona.

## Risultati della Fase 3b (2026-10-31)
Tutti i criteri di chiusura sono raggiunti; tabella completa e dettagli in `docs/OTTIMIZZAZIONE.md`.
- GPU: egui fragment 19,0 → 0,56 ms a 1080p; blur 18,2 → 4,4 ms; constant buffer indicizzati 4×; half 4,5×.
- CPU: UI da 2000 draw 16,4 → 2,8–2,9 µs/draw; niente copie da 64 KB per draw; `replaceRegion` piccole 8×
  più rapide; view senza rilettura GPU→CPU.
- Avvio: traduzioni in cache su disco; programmi condivisi tra varianti; la compilazione differita del driver
  (per contesto, misurato) si fa con un draw di riscaldamento alla creazione della pipeline, non nei frame.
- Nuovi test: `cfg` (57 controlli, controllo di flusso e forme di load), `uploads` (12 controlli).

## Prove con app Apple e Chrome (2026-10-31, prima della Fase 4)
Obiettivo: vedere dove si rompono le app Apple e Chrome sui Mac senza Metal, e cosa va sistemato nello shim.

| App | Senza shim | Con lo shim (iniezione) | Come si inietta |
|---|---|---|---|
| Mappe | interfaccia ok, **mappa vuota** (VectorKit disegna solo con Metal; il suo back-end GL non viene più usato) | **mappa completa** (etichette, rilievi, vetro sfocato), 0% CPU a riposo | copia firmata ad-hoc **senza entitlement** + `--home` |
| Dov'è | come Mappe | **mappa completa**; account e posizione non funzionano (i demoni vedono la firma vera) | come Mappe + `--fake-entitlements com.apple.findmy.` (senza, l'app si chiude da sola) |
| Safari | pagine ok, **WebGL perde subito il contesto**, WebGPU senza adapter | **non provabile con l'iniezione** | il GPU process è un servizio XPC di sistema con library validation |
| Chrome 156 | GPU process si chiude (ANGLE prova solo Metal), WebGL/WebGPU `null`, rendering software | **WebGL 1/2 ok anche con antialias, WebGPU ok**; WebGL Aquarium 500 pesci a ~49 fps | copia senza entitlement + `--model iMac19,1` + profilo e portachiavi finti |

Comandi (le copie stanno in `apps/`, gli originali non vengono toccati):
```
tools/shim-run.sh /System/Applications/Maps.app --no-entitlements --home
tools/shim-run.sh /System/Applications/FindMy.app --no-entitlements --home --fake-entitlements com.apple.findmy.
tools/shim-run.sh "/Volumes/Google Chrome/Google Chrome.app" --no-entitlements --model iMac19,1 -- \
    --user-data-dir=$HOME/metal-shim/apps/home-Chrome/profile --use-mock-keychain --no-first-run
```
Dopo le prove: `lsregister -u` sulle copie (vedi l'intestazione di `tools/shim-run.sh`).

### Correzioni emerse
| Dove | Problema | Correzione |
|---|---|---|
| interposer | VectorKit chiede il device a CoreGraphics (`CGDirectDisplayCopyCurrentMetalDevice`, che è SkyLight, qui quello patchato da OCLP) | interposto anche quello |
| device | SkyLight sceglie il device con `-acceleratorPort` uguale (stesso nome di porta Mach) all'acceleratore del display: il nostro rispondeva 0 | `acceleratorPort` e `registryID` presi dall'IOAccelerator del renderer GL effettivo (`kCGLRPRegistryID*`), non dal primo trovato (c'è anche l'Intel HD 3000 spento) |
| traduttore | `air.pack/unpack` unorm/snorm 4x8 e 2x16 | `packUnorm4x8` ecc.; snorm 2x16 scritto a mano (è GLSL 4.20) |
| traduttore | bitcast tra vettori di lunghezza diversa (`i32 → <4 x i8>`), e `half ↔ i16` che usava i 32 bit del float | bitcast generale per parole da 32 bit, `ts_f2h` (float → half, arrotondamento al pari) |
| traduttore | texture depth: `i32 1` prima delle coordinate anche senza compare; `gather` prendeva l'ultimo argomento (sempre 0) come componente e ignorava l'offset | argomenti corretti, `textureGatherOffset` |
| traduttore | `air.all/any`, `air.get_num_samples`, `fptoui/convert` verso `bool` e verso i8/i16, texture `undef` dopo la specializzazione | aggiunti |
| traduttore + encoder | `get_num_samples`/`get_num_mip_levels` di una texture erano il letterale `1`: **bug del driver** (un `while (true)` con numero di iterazioni costante dopo il folding perde il valore assegnato prima del `break`; misurato in GL puro) e quindi il resolve MSAA di ANGLE dava zero | uniform `?texinfo<N>` = (campioni, livelli) della texture legata, aggiornata dall'encoder: niente costanti e resolve con la media vera dei 4 campioni |
| strumenti | | `TSMTL_TRACE=1` (ogni forma di pass e pipeline una volta), PID nelle righe dell'interposer, `airdump`/`airtrans` leggono i `.metallib` e specializzano le function constant a zero, `shim-run.sh --no-shim/--home/--model/--fake-entitlements/-- args` |

Copertura: `tools/airtrans` su `VectorKit.framework/.../default.metallib` passa da 210/327 a **327/327** (tradotti e compilati dal driver). `make test`: translate 15/15 (nuovi: pack/unpack, lettura `texture2d_ms`).

### Cosa cambia per la Fase 4
1. **Library validation.** Mappe, Dov'è, Safari (e i suoi processi WebKit) e Chrome accettano solo codice firmato Apple, firmato dallo stesso team, oppure, su questo Mac, firmato con il certificato di OCLP: lo SkyLight patchato è firmato "OpenCore Legacy Patcher Software Signing" (Dortania Root CA) e AMFIPass lo fa accettare. Il nostro dylib ad-hoc viene scartato in silenzio. Il bundle della Fase 4 avrà lo stesso problema: serve un'eccezione mirata in AMFI (per esempio nel kext Lilu della Fase 4, limitata al cdhash del nostro bundle), oppure `amfi=0x80`, che OCLP ha abbandonato. **È una decisione da prendere prima di scrivere il kext.**
2. **Controllo del modello in ANGLE.** `IsMetalRendererAvailable` (ANGLE, `apple_platform_utils.mm`) spegne Metal se il modello è "troppo vecchio" e iMac12,1 lo è. La stessa stringa è nella shared cache di sistema, quindi anche WebKit (WebGL di Safari) lo farà, con qualsiasi device Metal. Con l'iniezione basta `TSMTL_MACHINE_MODEL`; a livello di sistema le strade sono uno spoof SMBIOS (globale, rischioso con OCLP) o una patch mirata: da studiare.
3. **Safari** si potrà provare solo con la Fase 4: il GPU process viene lanciato da launchd, non eredita variabili d'ambiente ed è un binario di piattaforma.
4. Positivo: il percorso SkyLight → `acceleratorPort` ora funziona, e con la registrazione vera `initWithAcceleratorPort:` darà la stessa porta.

### Effetti collaterali gestiti
- Le copie si registrano in LaunchServices con il bundle id originale, e le estensioni (widget di Dov'è) anche in pluginkit: `shim-run.sh` ora toglie le `.appex` dalle copie, e dopo le prove le copie sono state deregistrate.
- Mappe senza sandbox scrive comunque il suo `MapsSync_*.db` nel container vero (`~/Library/Containers/com.apple.Maps`); è la stessa versione dell'app, quindi lo schema è lo stesso, ma è bene saperlo.

## Correzioni dopo le prove dell'utente (2026-10-31, prima della Fase 4)
Problemi segnalati: (1) Mappe/Dov'è, zoom massimo: dettagli 3D magenta e fuori posto; (2) interfaccia di Chrome con glitch
all'hover, pagine lente, impostazioni instabili; (3) YouTube rompe il browser durante il caricamento; (4) scatti in generale.

| Problema | Causa trovata | Correzione |
|---|---|---|
| (1) poligoni magenta "messi male" | `DaVinci::ground_fragment` usa `air.extract_bits`: la pipeline cadeva nel fallback, che usa anche un vertex shader di ripiego senza trasformazioni (da qui la posizione sbagliata) | `extract_bits`/`insert_bits` (`bitfieldExtract/Insert`), `ldexp` |
| (1) in 3D niente etichette | `setVisibilityResultMode` era un no-op: VectorKit nasconde le etichette la cui query di occlusione restituisce 0 | query di occlusione GL (`GL_ANY_SAMPLES_PASSED`/`GL_SAMPLES_PASSED`) per tratto di draw, sommate per offset e scritte nel buffer dopo il `glFlush`, prima del completamento (`-[TSMtlDevice addPostFlushWork:]`) |
| (2)(3) riquadri rossi, testo gigante, hover sporco | Chrome (raster zero-copy) avvolge la stessa IOSurface in più `MTLTexture`: una scrive, l'altra campiona. La copia di campionamento si aggiornava una volta per command buffer e solo per le scritture fatte dallo stesso oggetto: contenuto vecchio | **IOSurface campionate in posto**: il traduttore emette ogni sampler 2D in due forme (`#if TSR_<stadio><slot>`: `sampler2D` o `sampler2DRect` con coordinate in texel); la pipeline collega al primo uso la variante per la maschera di slot che hanno un'IOSurface; l'encoder lega il `GL_TEXTURE_RECTANGLE` con un sampler compatibile (clamp, niente mip). Copie IOSurface: da ~31 MB/5 s a 0. Il percorso a copie rimasto usa un contatore globale di scritture su IOSurface |
| (2) pipeline Dawn in fallback | `[[color(0), index(1)]]` (dual-source blending) dichiarava `o0` due volte | `layout(location = 0, index = 1) out ... o0_1` |
| (2) Chrome lento a ogni avvio | la sandbox del processo GPU nega `~/Library/Caches`: nessuna traduzione restava in cache | la cache sceglie il primo percorso scrivibile; nelle sandbox che ammettono solo la cache shader di Metal usa `<DARWIN_USER_CACHE_DIR>[/<bundle>]/com.apple.metal/tsmtl-<sha>/functions0.data` (il nome che la regola di Chrome lascia passare). Al secondo avvio: 0 traduzioni |
| (4) Mappe: stalli a ogni fotogramma | VectorKit copia il fotogramma (sRGB) nel drawable (non sRGB) con un blit texture→texture, e corregge con `replaceRegion` tile appena disegnate: entrambe passavano da riletture GPU→CPU complete (36-94 ogni 5 s) | blit texture→texture in GPU (`glBlitFramebuffer`, anche tra gemelli sRGB: il driver copia i bit grezzi, `exp/srgbblit`); `replaceRegion` su una texture la cui copia GL è la più recente scrive direttamente in GL. Riletture: 0 |
| (4) upload dei buffer `shared` | ricaricati interi a ogni command buffer | dai 64 KB in su: confronto a blocchi da 4 KB con l'ultimo upload, solo i blocchi cambiati vanno a GL (`glBufferSubData`, o orfano se cambia più di metà) |
| (4) app che chiedono 2 drawable | la presentazione via CoreAnimation qui impiega ~27 ms dal commit (misurato): con 2 drawable si presenta un refresh sì e uno no (31 fps) | i `CAMetalLayer` sul nostro device hanno almeno 3 drawable (`TSMTL_DRAWABLES`, `src/TSMtlLayer.m`) |

Misure dopo le correzioni:
- Mappe, panning continuo in 3D (`tools/maps-bench.sh`): ~30 fps stabili, 0 riletture, coda GL dello shim occupata 4-21%. Il thread
  di rendering passa il 70-80% del tempo in `nextDrawable`: il limite è la presentazione (il layer usa `presentsWithTransaction`,
  WindowServer non-Metal ricompone anche i controlli "Liquid Glass" sopra la mappa), non lo shim né la GPU (profilo per draw:
  ~1,8 s di GPU ogni 5 s). Nascondere la barra laterale non cambia (150 fotogrammi ogni 5 s in entrambi i casi).
- `build/window` (triangolo, 1024×768): ~45-53 fps con 3 drawable; un'app OpenGL equivalente ~64-72 fps.
- Chrome: scroll di una pagina statica 58 fps (p99 33 ms); YouTube ~53 fps con scatti dovuti al suo JavaScript (processo GPU quasi fermo
  durante lo scroll). YouTube 854×480 riprodotto senza glitch dopo il caricamento; durante il caricamento resta ~1 s di tile non ancora
  rasterizzate (pipeline nuove da collegare: il driver non ha program binary).

Strumenti nuovi: `tools/cdp.py` (DevTools: naviga, valuta JS, scroll sintetici), `tools/chrome-test.sh` / `chrome-bench.sh`,
`tools/maps-bench.sh` (stato iniziale fisso da `apps/maps-bench-state`, `NOSIDEBAR=1`), `tools/mouse`, `tools/keys`, `tools/scroll`
(eventi veri: hover e panning), `tools/sheet` (provini delle catture a raffica, `SHEET_CROP`), `tools/winid <pid>`.
Variabili: `TSMTL_PROFILE=1` (tempo GPU per pipeline, una timer query per draw), `TSMTL_DRAWABLES`, `TSMTL_STATS` con nuove voci
(scritture IOSurface ≈ fotogrammi, coda GL occupata, bind IOSurface, attesa in `nextDrawable`), `TSMTL_TRACE` (configurazione dei
`CAMetalLayer`, formati delle IOSurface, chi provoca le riletture).
Test nuovi: phase2/phase3 33 (IOSurface condivisa scritta e campionata due volte nello stesso command buffer; risultati di visibilità;
copia texture→texture in GPU), uploads 18 (patch CPU su texture disegnate; buffer shared grandi a blocchi).

Limiti noti rimasti: IOSurface `RGBA` (non `BGRA`) rifiutate da `CGLTexImageIOSurface2D` (percorso a copie); compute ancora no-op
(VectorKit `downscaleTexture`/`clearTexture`, VideoToolbox); il tag della cache cambia a ogni build del traduttore.

## Rischi aperti (da verificare nelle fasi 3 e 4)
- `_MTLDevice` potrebbe richiedere dati privati (feature profile, target del compilatore) che vanno ricostruiti.
- Metal potrebbe cercare il bundle solo in `/System/Library/Extensions`, cioè sul volume di sistema sigillato: serve una root patch, come fa OCLP.
- Le app che verificano davvero i risultati del compute riceveranno dati vuoti.
- Ogni aggiornamento di macOS può cambiare le classi private: va ricontrollato a ogni release.

## Fase 4 (2026-10-31)
Tutto in `docs/FASE4.md` (come Metal trova il driver, deroga alla library validation, policy, prove) e
`docs/FASE4-INTERFACCE.md` (contratto fra kext, bundle e app di controllo). Decisioni prese:
1. **Library validation**: deroga mirata nel kext (solo l'eseguibile del bundle, di root, mai nei processi del desktop),
   ottenuta sostituendo due puntatori nella tabella `mac_ops` di AMFI; niente `amfi=0x80`.
2. **Posizione del bundle**: `/Library/GPUBundles` (Metal lo cerca lì prima di `/S/L/E`; con la SIP di OCLP è "fidato"):
   niente root patch del volume sigillato.
3. **Controllo del modello in ANGLE** (Chrome, WebGL di Safari): rimandato. Con l'iniezione basta `TSMTL_MACHINE_MODEL`;
   a livello di sistema servirebbe far rispondere `iMac19,1` a `hw.model` e alla proprietà `model` della platform expert solo
   per i processi GPU di Chrome/WebKit (aggancio nel kext): da decidere insieme.

## Blur di RenderBox (SwiftUI, Spotlight): driver 0.7.1 (2026-11-02)
Nei log del driver installato (0.7.0) `filter_blur` di RenderBox (il renderer Metal di SwiftUI: Spotlight, la nostra app,
`.blur()` dentro un `drawingGroup`) finiva nello shader di ripiego con `array of arrays`: contenuto non sfocato.
- **Riproduzione senza app:** `AIR_CONST=00001000 tools/airtrans .../RenderBox.framework/.../default.metallib filter_blur_fragment`
  (`AIR_CONST=<byte esadecimali>`, nuovo in `airtrans`/`airdump`, specializza le function constant con quei byte invece di zero;
  qui `shader_state` con il bit 20). La variante copia per valore `FilterGlobals`, che contiene `float[3][2]` e `float[8][2]`.
- **Correzione 1, array di array** (GLSL 4.10 non li ha): l'array interno diventa `struct A<k> { T a[M]; }`, l'esterno `A<k>[N]`,
  e i percorsi verso un elemento finiscono in `.a` (`x[i].a[j]`, anche con aritmetica di puntatori e phi). Costanti, zeri e
  letture dai buffer avvolgono gli elementi. In più le struct annidate avevano lo stesso nome (`S0` due volte): il nome
  ora viene riservato prima dei membri.
- **Correzione 2, emersa subito dopo:** il blur usa un sampler `constexpr` in **coordinate in pixel** (`coord::pixel`, bit 15
  della parola di stato), che il traduttore campionava come normalizzate: pass del blur tutto rosso. Ora 1D/2D dividono per
  `textureSize(s, 0)`, la variante rettangolo (IOSurface) usa la coordinata così com'è.
- **Verifica:** `tests/translate.m` 18/18 (nuovi: array di array con indici dinamici, sampler in pixel su texture 2D e IOSurface;
  senza la correzione 2 il test dà 16/18). Programma SwiftUI con `.blur()` + `drawingGroup()` iniettato: **0 pixel diversi**
  dal riferimento senza shim (driver 0.7.0: 1149 pixel diversi, cerchio non sfocato). Tutte le 256 varianti di
  `shader_state` provate (bit singoli, anche con il bit 20) si traducono. `make test` e `make test-compute` verdi;
  copertura invariata (VectorKit 328/328, QuartzCore 148/158, RenderBox 53/82: i fallimenti rimasti sono funzioni visibili
  e `render_target` in ingresso, non questo).
- Installazione: `zsh ~/metal-shim/system/update.sh` (solo il bundle, niente EFI né riavvio).

## Liquid Glass e shader precompilati: driver 0.8.0 (2026-11-02)
Obiettivo: il vetro nativo, cioè gli shader AIR di Apple tradotti in GLSL, per Spotlight e per le barre laterali, più
gli shader precompilati (`.mslbundle`, `docs/MSLBUNDLE.md`).

**Chi disegna il vetro su questo Mac** (verificato):
- **Spotlight e SwiftUI in un `drawingGroup`**: RenderBox disegna in-process con lo shim. Il vetro di SwiftUI
  (`displacementMap_v1`, `distanceGradient_v1`, `glassHighlight_v1`, `glow_v1`,
  `simplifiedShapeAwareGradientMask_v1`, `clampToEdges_v1`) è fatto di funzioni `[[stitchable]]` che RenderBox collega
  alle sue pipeline `custom_effect`/`primitive_custom` come *visible function* (`custom_fn.MTL_VISIBLE_FN_REF`,
  `MTLLinkedFunctions.privateFunctions = [custom_fn]`). Con la 0.7.1 finivano tutte nello shader di ripiego.
- **Barre laterali di Finder e Impostazioni, vetro delle finestre AppKit**: le compone **WindowServer** con il renderer
  OGL di CoreAnimation. Le app non fanno nessun draw: Impostazioni crea 9 pipeline di prewarm e 0 draw. Il `SkyLight`
  installato da OCLP è lo shim di Moraea (`SkyLight` + `SkyLightOriginal`), che dentro WindowServer sostituisce gli
  shader del renderer OGL con una propria imitazione GLSL del Liquid Glass (`cg9m_sdf`, `cg9m_keyFill`, `cg9m_vblur`, …).
  Lo shim Metal non entra in quel processo: il kext lo esclude di proposito, vedi "Sicurezza".

**Traduttore e driver: cosa mancava**
| Dove | Problema | Correzione |
|---|---|---|
| traduttore | chiamate a `<nome>.MTL_VISIBLE_FN_REF` (`section "air.externally_defined"`) | `TSAirTranslateLinked`: il bitcode delle funzioni collegate, per nome, viene caricato nello stesso contesto e unito con `LLVMLinkModules2` (definizioni rinominate `ts_linked_N`, il resto del modulo reso interno), poi la chiamata viene sostituita dalla definizione e i pass la inlinano. La pipeline passa `fragment/vertexLinkedFunctions`, e il loro bitcode entra nella chiave delle cache |
| traduttore | `alpha_effect`: due `half` scritti in un `float` privato e riletti come `float` (type punning lasciato da SROA) | variabili private reinterpretate tenute in parole `uint` con accesso a byte (`TSVWordPtr`, `ts_h2f`/`ts_f2h` per gli half) |
| traduttore | `simple_rim` di QuartzCore (il bordo luminoso del vetro): `sample(..., offset)` con offset non costante | spostamento delle coordinate in texel del livello campionato (`textureOffset` vuole una costante) |
| traduttore | `stroke_lines` (cursore e tratti di RenderBox): indice di vettore di tipo `i1` | `int(...)` |
| encoder | le passate della forma del vetro (campo di distanza, mappa di spostamento) campionano il **proprio** render target; anche il testo vibrante scritto su `color(1)` viene riletto da un draw successivo. Senza barriera la GPU AMD restituiva tile 8×8 vecchie: scaletta nella mappa di rifrazione | `glTextureBarrierNV` (`GL_NV_texture_barrier`, presente) prima di ogni draw che campiona un attachment del pass. `TSMTL_TEXTURE_BARRIER=0` per l'A/B |
| strumenti | | `tools/caglass` (CARenderer con il renderer Metal di CoreAnimation sul device dello shim: `NSGlassEffectView` e barra laterale in-process; `CAGLASS_WINDOW=s` mostra la stessa scena composta da WindowServer), `tools/rbglass` (vetro di SwiftUI via RenderBox), `TSMTL_DUMP_IR=1` (IR ripulito rifiutato), la traccia `TSMTL_DRAW_TRACE_DIR` salva anche gli attachment in formato float e quelli secondari (`pass-N-…-c1.bmp`), `airdump`/`mslbundle try` leggono i record `.bin` |

**Verifiche**
- `tests/translate.m` 22/22. Nuovi test: funzione visibile collegata, memoria reinterpretata (bit esatti), offset
  dinamico più indice bool, tre draw che rileggono il proprio target (0/100 senza barriera, 100/100 con).
  `make test` e `make test-compute` verdi.
- Copertura: QuartzCore **150/158**. Restano le 8 varianti `render_target` per GPU Apple; tutto il vetro nativo si
  traduce: `glass_background*`, `glass_foreground*`, `sdf_gen_*`, `simple_rim`, `rim_outline`, `brim_*`,
  `displacement_map`, `chromatic_aberration`, `variable_blur*`. VectorKit 328/328. RenderBox 53/82: le altre sono
  22 funzioni visibili (non sono entry point), 4 che vanno collegate alla pipeline, 2 `render_target`, 1 scrittura su
  texture da fragment.
- Vetro di SwiftUI in-process (`tools/rbglass`): 0 pipeline di ripiego, mappa di rifrazione liscia, bordo e
  rifrazione visibili.
- Vetro nativo di CoreAnimation in-process (`tools/caglass`): barra laterale e `NSGlassEffectView` disegnate dagli
  shader di QuartzCore tradotti, 0 ripieghi. Rispetto a WindowServer/Moraea la barra laterale è quasi identica; il
  pannello di vetro è più trasparente (sfocatura minore, bordi SDF), come il Liquid Glass vero.

**Rimasto aperto**
- Testo dentro un `GlassEffectContainer` disegnato in un `drawingGroup`: RenderBox scrive la copertura su `color(1)`
  e poi compone il testo "vibrante" con una matrice colore applicata alla destinazione. Quella destinazione è un layer
  che RenderBox stesso riempie di trasparente, quindi il testo esce con alpha 0. Dati e shader risultano coerenti (le
  uniform decodificate sono la matrice identità con alpha 0,95 e bias bianco) e l'origine non è stata trovata. Fuori
  dal container il testo c'è.
- Barre laterali con il vetro *nativo*: servirebbe CoreAnimation con il renderer Metal **dentro WindowServer**.
  Vuol dire togliere WindowServer dai processi critici (kext e `TSMtlSystem.m`), far accettare a SkyLight/Moraea un
  device Metal al posto del renderer OGL e, soprattutto, provarlo senza poter tornare indietro dall'interno della
  sessione: un crash di WindowServer chiude tutte le app. È una decisione dell'utente (vedi la risposta di fine
  sessione). La parte di traduzione è pronta, come mostra `tools/caglass`.
- I kernel `cnnConvArray_*` di Spotlight (Espresso: rete neurale, non il vetro) non girano: `air.is_uniform` e texture
  di indice 64.

**Shader precompilati**: `docs/MSLBUNDLE.md`. Il driver registra gli shader di ogni app e `system/mslbundle.sh` li
compila in `/Library/GPUBundles/TeraScaleMTLDriver.config/mslbundles` (senza sudo). `update.sh` lo esegue dopo
l'installazione. Con rbglass la traduzione passa da 127 ms a 0 e la creazione delle pipeline da 714 a 595 ms.
Installazione: `zsh ~/metal-shim/system/update.sh`.

**Seguito approvato (2026-11-02):** vetro di Apple dentro il compositore OGL di Moraea, prima in laboratorio e WindowServer solo alla fine: `docs/PIANO-GLASS.md`.
