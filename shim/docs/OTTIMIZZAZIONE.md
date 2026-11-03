# TeraScale Metal Shim: ottimizzazione (Fase 3b)

## Stato dell'implementazione (2026-10-31)

Implementato e misurato su questo iMac (HD 6750M, GL 4.1 ATI-1.66.42). `make test` è verde:
phase1 44/44, phase2 26/26, phase3 26/26, translate 12/12, **cfg 57/57** (nuovo: controllo di
flusso in 4 modalità di traduzione + forme di load verificate contro la CPU), **uploads 12/12**
(nuovo: upload incrementali e view). ArtCraft Launcher gira con il nuovo percorso: interfaccia
completa, shader strutturati, 0% CPU a riposo.

| Misura (`bench/`) | Prima | Dopo | Criterio |
|---|---|---|---|
| egui fragment, schermo intero 1080p | 19,03 ms | **0,56 ms** | < 1 ms ✓ |
| egui vertex, 3M vertici | 23–25 ms | 17,2 ms (5 fetch invece di 20) | — |
| blur, 16 tap | 18,15 ms | 4,40 ms | — |
| `constant float4 *` indicizzato | 3,03 ms | 0,73 ms | — |
| `constant half4 *` | 8,56 ms | 1,90 ms | — |
| matrici per istanza da device buffer | 25,8–27,5 ms | 18,4 ms | — |
| UI 2000 draw, CPU codifica + esecuzione | 16,4 µs/draw | **2,8–2,9 µs/draw** | < 3 µs ✓ |
| draw con `constant T *` di dimensione ignota | 23,3 µs/draw | 0,58 µs/draw | — |
| 100 pass × 4 draw | 80–130 µs/pass | 60 µs/pass | — |
| `replaceRegion` 64×64 su 2048² | 5,73 ms/cb | 0,73 ms/cb | — |
| render in una view, campionamento della madre | 5,91 ms/frame | 0,32 ms/frame | nessuna rilettura ✓ |
| primo frame con gli shader di egui | 33,6 ms | 1,9 ms (il costo passa alla creazione della pipeline) | nessuna compilazione nei frame ✓ |
| variante di pipeline con lo stesso programma | 3–4 ms | 0,1 ms | — |
| traduzione dal secondo avvio | 3–25 ms per shader | 0 (cache su disco) | ✓ |

Cosa è stato fatto, punto per punto:
- **A1** `TSAirTranslate` clona il modulo e lancia `inline,function(sroa,loop-unroll-full,sroa,early-cse,instcombine,dse,adce,simplifycfg,instcombine)`;
  se la traduzione dell'IR pulito fallisce, ritenta sull'IR originale. Corretto anche **C7** (buffer di memoria senza copia, liberato).
- **A2** `TSStructurer` (in `TSAirTranslator.m`) pianifica il codice strutturato prima di emettere: dominatori,
  cicli naturali, post-dominatori sul DAG senza archi all'indietro; if/else e `while (true)` con
  `break`/`continue`; i blocchi terminali (che finiscono in `return`) si duplicano entro un budget.
  Se il piano fallisce si ritenta dopo `lowerswitch,fix-irreducible,unify-loop-exits,structurizecfg`, e solo
  dopo si usa la macchina a stati. Tutti gli shader del corpus, di ArtCraft e del test `cfg` escono strutturati
  con l'IR pulito. `TSMTL_NO_PASSES=1` / `TSMTL_NO_STRUCT=1` servono per confronti A/B.
- **A3** allineamento noto degli offset nei puntatori ai buffer: `float4` allineati a 16 diventano un solo `uvec4`
  (constant buffer) o un fetch dalla vista RGBA32UI `<buf>_4` (device buffer); offset costanti come componenti
  statiche; parole e offset dei GEP memorizzati per blocco (i 20 load da 1 byte di egui sono 5 fetch).
- **A4** `ts_h2f` senza salti (denormali a zero, inf/NaN con payload, segno in OR).
- **B1** comandi POD in chunk da 64 KB riciclati, payload di `setBytes` in un'area di staging unica per pass,
  oggetti trattenuti una volta per cambio (solo con `retainedReferences`).
- **B2** stato di pipeline e depth/stencil convertito in struct GL alla creazione.
- **B3** `set*` ridondanti scartati già in codifica; in esecuzione un'ombra dello stato GL per replay emette
  solo le differenze; offset dei vertex buffer multipli dello stride ripiegati in `first`/`basevertex` quando
  lo shader non legge `gl_VertexID`.
- **B4** i blocchi uniform si legano al range disponibile (il driver accetta un range più corto del blocco
  dichiarato, misurato): niente più copie da 64 KB; offset non allineati a 256 copiati in un ring.
- **B6** texture: regioni sporche per (livello, slice) caricate con `glTexSubImage`; buffer: range scritti dai blit
  e da `didModifyRange` (un buffer `managed` è trattato come `shared` finché l'app non chiama `didModifyRange`).
- **B7** view con lo stesso formato GL: render direttamente nella texture radice; a range completo anche il
  campionamento.
- **B9** `os_unfair_lock` al posto di `@synchronized` nelle texture; `glGetError` solo con `TSMTL_LOG=1`.
- **C2** programmi GL condivisi tra pipeline con gli stessi due sorgenti (introspezione e uniform per programma).
- **C3** `~/Library/Caches/com.terascale.mtlshim/glsl/<sha256>.plist` (nelle app sandbox: la cartella Caches del
  container); la chiave include bitcode, interpolazioni e build del traduttore. `TSMTL_NO_DISK_CACHE=1` la spegne.
  Si può cancellare in qualunque momento.
- **C4, rivisto con una misura**: la variante compilata dal driver è **per contesto**. Un draw di riscaldamento su un
  contesto condiviso lascia il primo draw reale a ~30 ms, quindi la compilazione in un thread separato non serve
  su questo driver. Si fa invece un draw 1×1 sullo stesso contesto subito dopo il link, con risorse
  segnaposto legate (`TSMTL_NO_WARMUP=1` per disattivarlo). Lo stato di blend non provoca ricompilazioni.
- **Statistiche**: `TSMTL_STATS=1` stampa ogni 5 s draw, pass, command buffer, KB caricati (buffer e texture),
  riletture, traduzioni, hit della cache su disco, link e hit dei programmi.

Dopo le prove con Mappe e Chrome (2026-10-31, dettagli in `docs/PIANO.md`, "Correzioni dopo le prove dell'utente"):
- IOSurface campionate in posto con varianti `sampler2DRect` dei programmi: niente più copie per command buffer (Chrome: 31 MB/5 s → 0).
- Blit texture→texture in GPU e `replaceRegion` scritte direttamente in GL quando la GPU ha i dati più recenti (Mappe: riletture 36-94/5 s → 0).
- Buffer `shared` da 64 KB in su caricati a blocchi da 4 KB cambiati (era il punto "Buffer shared grandi" qui sotto).
- Cache delle traduzioni funzionante anche nella sandbox GPU di Chrome.
- `TSMTL_PROFILE=1`: tempo GPU per pipeline.

Non fatto (rifiniture, nessuna regressione rispetto a prima):
- B5 cache di FBO e VAO per pass (~20 µs per pass); B8 seed delle IOSurface campionate; A5 GLSL più compatto;
  C5 traduzione in parallelo; C6 separate shader objects.
- Buffer `shared` sotto i 64 KB: upload completo per command buffer (sopra: a blocchi cambiati, vedi sopra).
- View a range parziale **campionate**: hanno ancora il loro mirror (rilettura dalla radice dopo un render).
- egui vertex: restano le ALU che ricompongono le parole dai byte (+4% rispetto al GLSL a parole scritto a mano).

---

## Analisi originale (prima dell'implementazione)

Obiettivo: prima di qualunque altra fase, (1) rendere veloce il rendering sulla HD 6750M,
soprattutto la qualità degli shader GLSL generati, e (2) portare quasi a zero il costo della
traduzione, sia dei comandi Metal → GL sia degli shader AIR → GLSL.

Tutti i numeri qui sotto sono **misurati su questo iMac**: HD 6750M, GL 4.1 ATI-1.66.42.
I benchmark sono in `bench/`; si compilano con `bench/build.sh` e finiscono in `build/bench/`.

## Sintesi

1. **Il controllo di flusso a macchina a stati è il problema numero uno della GPU.**
   Lo shader di frammento reale di egui (ArtCraft) costa **19,0 ms** per ogni copertura
   dello schermo a 1920×1080. La stessa logica con controllo di flusso strutturato e IR
   ripulito costa **0,52 ms** (36×). Oggi una UI che ridisegna tutta la finestra è
   limitata dalla GPU a meno di 50 fps per questo solo shader.
2. **La pulizia dell'IR con la libLLVM di sistema è quasi gratis e vale da sola 3,5×.**
   `LLVMRunPasses` è esportata e conosce tutti i passi utili: inline, sroa, loop-unroll,
   instcombine, dse, simplifycfg, structurizecfg, fix-irreducible, unify-loop-exits e lowerswitch.
   Sullo shader di egui elimina un ciclo per pixel che azzera 8 byte di padding con un
   indice dinamico in un array locale.
3. **Lato CPU lo shim costa circa 10 volte il pavimento del driver.** Un draw costa oggi
   16,4 µs (2,2 di codifica e 14,3 di esecuzione). Lo stesso carico in GL puro, emettendo
   solo lo stato che cambia, costa 1,4–1,7 µs. Circa metà del tempo CPU va in runtime
   Objective-C, blocchi e malloc. Un altro 42% è nel driver, gonfiato dal fatto che
   riapplichiamo tutto lo stato a ogni draw.
4. **Il costo di traduzione è dominato dalla compilazione differita del driver al primo draw.**
   Questa costa da 18 a 206 ms con il GLSL di oggi. Con GLSL strutturato scende a 4–76 ms;
   per lo shader di frammento di egui passa da 124 a 6 ms. I *program binary* non esistono
   su questo driver (`GL_NUM_PROGRAM_BINARY_FORMATS = 0`), quindi la compilazione GLSL va
   fatta a ogni avvio. Va quindi resa piccola, unica per coppia di shader, asincrona e
   anticipata.

## Misure

### GPU (`gpubench`, `attrib`; tempo GPU con `GL_TIME_ELAPSED`, minimo di 5 giri, target 1920×1080)

Le colonne "dopo" sono GLSL scritto a mano nella forma che il traduttore ottimizzato deve
emettere. Fanno eccezione le righe "solo pulizia LLVM", che usano il traduttore di oggi
sull'IR ripulito.

| Caso | Oggi | Dopo | Guadagno | 1° draw oggi → dopo |
|---|---|---|---|---|
| egui fragment, schermo intero, dithering on | 19,03 ms | 0,52 ms (strutturato + IR pulito) | 36× | 88–125 → 5–6 ms |
| egui fragment, solo pulizia LLVM (macchina a stati) | 19,03 ms | 5,50 ms | 3,5× | 97 → 33 ms |
| egui vertex, vertex pulling, 3M vertici | 23–25 ms | 17,3 ms (strutturato) / 16,3 ms (+ fetch a parole) | 1,4× | 125–206 → 19 ms |
| blur con numero di tap uniforme (16) | 18,15 ms | 4,12 ms (ciclo `for`) | 4,4× | 28–56 → 8 ms |
| `constant float4 *pal` indicizzato per pixel | 3,03 ms | 0,77 ms (load `uvec4` interi) | 4,0× | 18 → 4 ms |
| `constant half4 *` (8 half per pixel) | 8,56 ms | 2,84 ms (`ts_h2f` senza salti) | 3,0× | 27 → 20 ms |
| `device float4x4 m[iid]` + `float4 p[vid]`, 3M vertici | 25,8–27,5 ms | 18,3 ms (fetch RGBA32UI) | 1,4× | 47 → 31 ms |

Osservazioni:
- La pulizia LLVM da sola non cambia il blur né il vertex shader di egui: lì il costo è la
  macchina a stati. Sul fragment di egui la pulizia toglie il ciclo sul padding, pari a 13,5 ms
  dei 19, e la struttura toglie il resto.
- `fma()` costa come `a*b+c` (2,564 ms in entrambi i casi): la mappatura attuale va bene.
- Il primo vertex test del primo giro ha dato 42,9 ms (GPU in uno stato di clock basso).
  Le ripetizioni danno 23–25 ms. Le misure dei fragment sono stabili al centesimo.

### CPU: traduzione dei comandi (`cpubench`, `glfloor`, `passfloor`)

| Caso | Oggi | Pavimento GL puro |
|---|---|---|
| UI, 2000 draw/frame (pipeline ogni 10, texture, scissor, setVertexBytes, offset VB) | codifica 2,18 + esecuzione 14,26 = **16,4 µs/draw** (33 ms/frame) | tutto lo stato a ogni draw: 6,34 µs; solo stato cambiato: **1,74 µs**; più dedup degli uniform: **1,39 µs** |
| render pass con 4 draw | 80–130 µs/pass | creazione + check + delete di FBO e VAO: ~21 µs, eliminabili con una cache |
| draw con `constant T *` di dimensione ignota (blocco da 64 KB) | 23,3 µs/draw (copia 64 KB a ogni draw) | ~1,5 µs (binding diretto, nessuna copia) |
| `replaceRegion` 64×64 su texture 2048² | 5,73 ms per command buffer (ricarica 16 MB) | ~0,35 ms (solo la regione) |
| buffer condiviso da 16 MB usato in un draw | 4,08 ms per command buffer, anche se non modificato | upload solo dei range usati o modificati |
| render in una view a range completo, poi campionamento della texture madre | 5,91 ms/frame (1024²) | 0,52 ms/frame (stessa GL texture) |
| GL multithread (`kCGLCEMPEngine`) | — | **peggiora**: 2,19 contro 1,74 µs/draw. Da non usare |

Profilo (`sample`) del caso UI, tempo esclusivo senza i thread inattivi:

| Categoria | Quota |
|---|---|
| GLEngine + driver AMD | 42,5% |
| Runtime Objective-C (msgSend, retain, release) | 34,3% |
| malloc + blocchi | 7,3% |
| codice dello shim | 6,5% |
| Foundation e Metal (descrittori, array) | 4,5% |
| memcpy/memset | 3,0% |

Nel driver dominano `gleUpdateDeferredStateFull`, `gpusLoadCurrentPipelinePrograms` e
`glrBindSysVertexProgram`. È la rivalidazione completa causata da `glUseProgram` e dal
re-binding di tutto a ogni draw.

### Costo di traduzione degli shader

| Fase | Costo oggi | Note |
|---|---|---|
| AIR → GLSL (parse LLVM + emissione) | 1–7 ms per funzione | cache solo in memoria, quindi si ripaga a ogni avvio |
| passi LLVM di pulizia | 1,2–3 ms per funzione | da aggiungere; il risultato va in cache su disco |
| `glCompileShader` + `glLinkProgram` | 2–17 ms per pipeline | ripetuti anche quando la coppia di shader è identica: 3,2–3,6 ms sprecati per ogni variante di blend |
| compilazione differita al 1° draw | 18–206 ms | blocca il thread GPU e causa uno scatto visibile; scala con la complessità del GLSL |
| program binary su disco | impossibile | `GL_NUM_PROGRAM_BINARY_FORMATS = 0` |

## Interventi lato GPU: qualità degli shader (`src/TSAirTranslator.m`)

**A1. Passi LLVM prima della traduzione.** Priorità alta, sforzo basso.
- Dove: `TSAirTranslate`, tra `LLVMParseBitcodeInContext2` e `[t translate]`.
- Come: aggiungere a `TSLLVM.h` le funzioni `LLVMRunPasses`, `LLVMCreatePassBuilderOptions`,
  `LLVMGetErrorMessage` e `LLVMDisposeErrorMessage`. `LLVMRunPasses` richiede un oggetto
  opzioni valido: con NULL va in crash. Pipeline di partenza, già provata su AIR:
  `inline,function(sroa,loop-unroll-full,sroa,early-cse,instcombine,dse,adce,simplifycfg,instcombine)`.
  Se la traduzione dell'IR ripulito fallisce, si ritenta sull'IR originale.
- Effetti collaterali positivi: l'inliner del traduttore (`inlineCall:`) diventa superfluo,
  e spariscono alloca, cicli di azzeramento e copie di struct.
- Da coprire nel traduttore: le forme prodotte da instcombine, cioè gli intrinseci `llvm.*`
  non ancora mappati (`fshl/fshr`, `bswap`, `umin/umax` vettoriali), shuffle con maschere
  `poison`, `freeze` e aritmetica i64 dei GEP canonicalizzati.

**A2. Controllo di flusso strutturato al posto della macchina `while/switch`.** Priorità
massima, sforzo medio-alto.
- Dove: `emitFunction:`, `terminator:block:`, `phiCopiesFrom:to:`.
- Come: aggiungere in coda ad A1 `lowerswitch,fix-irreducible,unify-loop-exits,structurizecfg`.
  Sono tutti disponibili e garantiscono un CFG emettibile con soli `if/else` e cicli a
  uscita singola. L'emettitore percorre l'albero dei dominatori:
  - un diamante diventa `if (c) { … } else { … }`, con il punto di fusione nel post-dominatore
    immediato;
  - un ciclo naturale diventa `while (true) { …; if (!c) break; }`;
  - i phi diventano assegnazioni in coda ai blocchi predecessori.

  La macchina a stati resta come ripiego per ciò che l'emettitore non riconosce.
- Perché conta tanto su TeraScale: con la macchina a stati tutti i temporanei sono vivi in
  tutto il ciclo. Questo alza la pressione sui registri, riduce le wavefront in volo e
  spezza le clause ALU e TEX, che il compilatore non può più raggruppare tra blocchi.
- Guadagno misurato: egui fragment 5,5 → 0,52 ms dopo A1, blur 4,4×, egui vertex 1,35×.
  Il primo draw diventa fino a 20 volte più rapido.

**A3. Load consapevoli dell'allineamento: vettoriali e a parole.** Priorità media.
- Dove: `load:type:extra:`, `gep:`, `declareBuffer:`.
- Come:
  - Propagare nei `TSVal` di tipo BufPtr l'allineamento noto della parte dinamica
    dell'offset (da `idx * size` dei GEP) e l'`align` delle istruzioni load.
  - Buffer `constant`: per load di 16 byte allineati emettere `uintBitsToFloat(d[o >> 4])`
    (un `uvec4` intero) invece di 4 parole con componente dinamica. Le matrici diventano
    4 letture invece di 16. Con offset statico emettere la componente costante (`d[k].y`).
  - Buffer `device`: creare sullo stesso buffer GL anche viste RGBA32UI e RG32UI (e RGB32UI,
    disponibile via `GL_ARB_texture_buffer_object_rgb32`) e scegliere il fetch più largo
    consentito. Metal impone che l'offset di binding sia allineato al tipo letto, fino a
    16 byte, quindi per un `float4` o un `float4x4` il fetch largo è sicuro.
  - Memoizzare per blocco le parole già lette (stessa base, stesso indice di parola).
    I 20 load da 1 byte di egui diventano 5 fetch. Il vettorizzatore LLVM non lo fa,
    perché vede `align 1`.
  - Esprimere gli indirizzi in parole o vec4, non in byte, quando l'allineamento lo
    permette. Sulle VLIW5 la moltiplicazione intera a 32 bit gira solo nello slot T.
- Guadagno misurato: indicizzazione dinamica dei constant buffer 4×, matrici per istanza
  1,4×, egui vertex 6%.

**A4. `ts_h2f` senza salti.** Priorità alta, sforzo minimo.
- Dove: `needHalf`.
- Come: `uintBitsToFloat((h & 0x7FFF) << 13) * 2^112`, più una `select` per inf e NaN e una
  per il segno. Gli half denormali vanno a zero, come fa comunque la GPU con i float denormali.
- Guadagno misurato: 3×. Gli attributi di vertice half restano a carico di GL, come oggi.

**A5. GLSL più compatto.** Priorità media, dopo A2.
- Come: dichiarare i valori nel punto di definizione dentro il loro blocco, non tutti in
  testa a `main`. Sostituire in linea le espressioni pure usate una sola volta.
- Effetto: meno codice da compilare. Con la sola pulizia LLVM il primo draw è già sceso
  da 97 a 33 ms.

## Interventi lato CPU: traduzione dei comandi (`src/TSMtlRender.m`, `src/TSMtlCommands.m`, `src/TSMtlResources.m`)

**B1. Flusso di comandi POD al posto dei blocchi.** Priorità massima.
- Oggi ogni `set*` e ogni draw creano un blocco sullo heap, lo inseriscono in un
  `NSMutableArray` e ne trattengono gli oggetti. `setBytes` crea anche un `NSData`.
- Come: un'arena lineare per encoder, a chunk da 64 KB riciclati dalla coda, con comandi
  `{opcode, argomenti}` impacchettati e i payload di `setBytes` copiati in linea. Gli
  oggetti si referenziano con puntatori non trattenuti; si trattengono una volta per command
  buffer, e solo se `retainedReferences`. Il `NSLock` di `recordCommand:` diventa inutile,
  perché un encoder si usa da un thread alla volta.
- Obiettivo: codifica da 0,3 µs a meno di 0,05 µs per chiamata API.

**B2. Stato della pipeline precalcolato.** Priorità alta.
- Oggi `applyVertexInputs` e `applyFixedFunction` leggono `MTLVertexDescriptor`,
  `colorAttachments[i]` (8 volte) e `MTLDepthStencilDescriptor` via messaggi Objective-C
  a ogni draw.
- Come: alla creazione di pipeline e depth/stencil state, convertire tutto in struct C di
  enum GL. Al draw nessuna chiamata Objective-C.

**B3. Ombra dello stato GL con dirty bit.** Priorità massima.
- Come: tracciare lo stato già impostato (programma, attributi per location, texture e
  sampler per unità, binding UBO, blend, depth/stencil, raster, viewport, scissor, FBO)
  e a ogni draw emettere solo le differenze.
- Un offset di vertex buffer multiplo dello stride diventa `first`, o `basevertex` nei draw
  indicizzati, senza ripuntare gli attributi.
- Guadagno misurato nel GL puro: da 6,34 µs/draw (tutto lo stato) a 1,74 µs/draw.

**B4. Uniform senza copie.** Priorità alta.
- Come:
  1. Un constant buffer dell'app con offset multiplo di 256 si lega direttamente come range
     UBO del suo buffer GL. Metal su macOS impone già l'allineamento a 256 per gli offset
     `constant`, e `GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT` vale 256.
  2. I `setBytes` di un command buffer vanno in un'unica area di staging, caricata una volta
     sola. Ogni draw fa solo `glBindBufferRange`.
  3. Payload identici consecutivi si deduplicano.
  4. Un blocco di dimensione ignota non deve mai causare una copia da 64 KB per draw.
- Guadagno misurato: draw con `constant T *` da 23,3 a ~1,5 µs; dedup da 1,74 a 1,39 µs nel GL puro.

**B5. Render pass economici.** Priorità media.
- Come: una cache di FBO con chiave sull'insieme degli attachment (nomi GL, livello, slice,
  piano). `glCheckFramebufferStatus` solo alla creazione, un VAO persistente e, invece di
  `[desc copy]` dell'intero `MTLRenderPassDescriptor`, solo i campi necessari copiati in
  una struct C.
- Guadagno: ~21 µs per pass dalla sola cache di FBO e VAO.

**B6. Upload solo di ciò che è cambiato.** Priorità alta.
- Texture: regioni sporche per (livello, slice) da `replaceRegion` e dai blit, caricate con
  `glTexSubImage` solo su quei rettangoli. Misurato: 5,73 ms → ~0,35 ms.
- Buffer `managed`: usare i range di `didModifyRange:`, che oggi azzera solo un contatore.
- Buffer scritti da blit: il range è noto.
- Buffer `shared`: caricare solo i range effettivamente usati dai draw del command buffer,
  cioè vertici, indici e range UBO, non l'intero buffer. Misurato: 4,08 ms per CB con 16 MB.
- Facoltativo per lo streaming video: `GL_APPLE_client_storage` + `GL_APPLE_texture_range`.

**B7. Texture view senza rilettura sulla CPU.** Priorità alta per le app con catene di mip, bloom o view sRGB.
- Oggi una view ha un proprio mirror GL, e passare da view a texture madre causa
  `glGetTexImage` (stallo GPU→CPU) seguito da un nuovo upload.
- Come:
  - View con lo stesso formato: aliasare la GL texture della radice (render al livello e
    slice giusti, campionamento con i clamp di LOD del sampler).
  - View sRGB↔lineare: `GL_EXT_texture_sRGB_decode` (disponibile) per il campionamento e
    `GL_FRAMEBUFFER_SRGB` per il render.
  - Gli altri casi: copia lato GPU con blit o PBO, mai attraverso la CPU.
- Misurato: 5,91 → 0,52 ms/frame su 1024².

**B8. IOSurface campionate.** Priorità bassa.
- Oggi `glTextureForSampling` ripete il blit dal rettangolo a ogni command buffer.
- Come: confrontare `IOSurfaceGetSeed()` e ripetere il blit solo se la surface è cambiata.
  Mettere in cache i due FBO del blit.

**B9. Sincronizzazione leggera.** Priorità bassa.
- Come: sostituire i 2–3 `@synchronized` per texture campionata per draw con
  `os_unfair_lock` o contatori atomici. `glGetError` dopo ogni command buffer solo con `TSMTL_LOG`.

**Escluso:** il motore GL multithread, perché misurato più lento.

## Traduzione degli shader "quasi a costo zero" (`src/TSMtlPipeline.m`, `src/TSMtlDevice.m`)

**C1. GLSL migliore significa compilazione del driver più rapida.** Lo garantiscono A1, A2
e A5. È la leva più forte sugli scatti: da 124 a 6 ms sullo shader di egui.

**C2. Cache dei programmi GL.** Priorità alta.
- Come: chiave = hash di (GLSL vertex, GLSL fragment). Le pipeline che differiscono solo
  per blend, write mask, formati o layout dei vertici condividono lo stesso programma e le
  stesse tabelle di introspezione, con conteggio dei riferimenti. Oggi ogni variante
  ricompila e rilinka.

**C3. Cache su disco delle traduzioni.** Priorità alta.
- Come: `<NSCachesDirectory>/com.terascale.mtlshim/<sha256(bitcode ‖ interpolazioni ‖ versione traduttore)>`
  conterrà il GLSL e i qualificatori. Nelle app sandbox la cartella è quella del container.
  Per ogni app si registra anche l'elenco delle coppie usate, per il pre-riscaldamento (C4).
- Al secondo avvio scompaiono parse LLVM, passi e traduzione, cioè 3–10 ms per shader.

**C4. Compilazione asincrona e riscaldamento fuori dal thread di render.** Priorità alta.
- Come: un thread di compilazione con un secondo contesto CGL condiviso con quello di
  render. Esegue compile, link e un draw di riscaldamento su un FBO 1×1 del formato giusto,
  per forzare lì la compilazione differita del driver.
- La pipeline viene restituita subito; il primo uso attende solo se il programma non è
  ancora pronto, con `glFenceSync`/`glWaitSync`, core dalla 3.2.
- All'avvio si precompilano in background le coppie registrate dalla cache C3. Le varianti
  asincrone dell'API Metal (`completionHandler:`) diventano davvero asincrone.

**C5. Traduzione in parallelo.** Ogni traduzione usa il proprio `LLVMContext`, quindi può
girare su una coda concorrente.

**C6. Da valutare dopo C2:** `GL_ARB_separate_shader_objects` (disponibile) per compilare
ogni funzione una sola volta (N+M invece di N×M). Rischi da misurare: costo dei program
pipeline nel driver Apple/AMD e regole di corrispondenza delle interfacce.

**C7. Piccole correzioni.** In `TSAirTranslate` il buffer creato con
`LLVMCreateMemoryBufferWithMemoryRangeCopy` non viene mai liberato, perché
`LLVMParseBitcodeInContext2` non ne prende possesso. Va usata la variante senza copia e va
liberato il buffer.

## Ordine di lavoro proposto

| # | Intervento | Sforzo | Effetto atteso |
|---|---|---|---|
| 1 | A4 `ts_h2f` | minimo | 3× sui load half |
| 2 | A1 passi LLVM + copertura delle nuove forme IR | basso | 3,5× sullo shader di egui |
| 3 | A2 controllo di flusso strutturato | medio-alto | fino a 36× totale con A1; primo draw fino a 20× più rapido |
| 4 | B1 + B2 + B3 comandi POD, stato precalcolato, dirty bit | medio-alto | CPU per draw da 16,4 a ~2 µs |
| 5 | B4 + B6 + B7 uniform senza copie, upload incrementali, view | medio | elimina copie da 64 KB per draw, ricariche da 16 MB e stalli GPU→CPU |
| 6 | C2 + C3 + C4 cache dei programmi, cache su disco, compilazione asincrona | medio | pipeline pronta in ~0 ms dal secondo avvio, nessuno scatto sul thread di render |
| 7 | A3 load larghi e a parole | medio | 1,4–4× sui pattern di buffer |
| 8 | B5, B8, B9, A5, C5, C6 | vario | rifiniture |

I filoni A (traduttore) e B (encoder e risorse) toccano file diversi e possono procedere in parallelo.

**Criteri di chiusura della Fase 3b** (da misurare con `bench/`):
- `make test` resta verde, e il corpus `translate` resta corretto al pixel.
- egui fragment a schermo intero sotto 1 ms GPU.
- UI da 2000 draw sotto 3 µs/draw di CPU totale.
- Nessuna compilazione sul thread di render dal secondo avvio.
- Nessuna rilettura GPU→CPU nel percorso delle view.
- Da aggiungere: contatori con `TSMTL_STATS=1` (draw, chiamate GL, byte caricati,
  riletture, compilazioni, hit della cache) per verificare ogni passo su ArtCraft.

Questi interventi non dipendono da TeraScale, salvo la scelta della larghezza dei fetch:
valgono per qualunque GPU GL 4.1. La macchina a stati penalizza ogni GPU, ma le VLIW5 sono
il caso peggiore, quindi ottimizzare qui dà un limite inferiore affidabile anche per le
altre piattaforme.
