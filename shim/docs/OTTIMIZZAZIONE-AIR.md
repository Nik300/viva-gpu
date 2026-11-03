# Ottimizzazione avanzata di AIR per TeraScale – ricerca (2026-11-02)

Macchina: iMac con Radeon HD 6750M (TeraScale 2, VLIW5, 256 MB di VRAM), Core i5 Sandy Bridge a 4 thread, 4 GB di
RAM, OpenGL 4.1 ATI-1.66.42, OpenCL 1.2, macOS 26 con OCLP/Moraea. Driver installato 0.9.0, build 0.10.0.
Strumenti ed esperimenti di questa ricerca: `exp/airopt/` (dati grezzi in `exp/airopt/data/`).
**Implementazione: §9** (build 0.11.0, stesso giorno): fatto tutto il piano di §8 più B6 e B7; P4 valutato e non fatto,
B4 spento di default (nessun guadagno misurato).

## 1. Sintesi

1. **La creazione delle pipeline la decide quasi tutta la compilazione differita del driver** (la "warm-up" al primo
   draw): il 99–100% del tempo di uno shader, contro pochi ms di `glCompileShader` + `glLinkProgram`. Il costo cresce in
   modo **fortemente superlineare** (pendenza log-log 2,4, r = 0,92 su 68 fragment shader veri presi dalla cache):
   ~3 ms sotto 1 KB, ~10 ms a 2 KB, 0,6 s a 7 KB, 4,4 s a 12,8 KB, **15–52 s** a 30–34 KB.
2. **Causa principale trovata: i load da buffer `device` letti una parola (4 byte) alla volta.** Unire i load scalari
   adiacenti della stessa struct in un solo `texelFetch` da 16 byte porta la compilazione hardware da **530 a 41 ms**
   (17 → 7 fetch) e da **4,0–5,0 s a 80–87 ms** (35 → 13 fetch): 13× e ~50×, con lo stesso shader per tutto il resto.
   111 dei 413 shader distinti in cache hanno load di questo tipo da unire, e 57 ne hanno 16 o più. È una modifica
   del traduttore AIR (`wordAt:` in `src/TSAirTranslator.m`), da fare con una variante per l'allineamento (§4.1).
3. **La tua idea, "precompilare e comprimere i kernel standard", vale nella forma giusta.** Il codice macchina di GL
   non si può precompilare: il driver non ha program binary (`GL_NUM_PROGRAM_BINARY_FORMATS = 0`) e macOS non ha una
   cache GL di sistema su disco. Il GLSL è già precompilato (`.mslbundle`, cache su disco) e OpenCL ha già i binari
   su disco (0,3–0,8 ms invece di 60–1100 ms). Comprimere i byte non serve: minimizzare il testo (−13% di byte) non
   cambia il costo (rapporto mediano 0,97). Serve invece "comprimere" il **lavoro** che lo shader chiede al
   compilatore: meno fetch, meno varianti, meno programmi. La coalescenza dei load ne è il primo caso misurato.
   Il builder dei `.mslbundle` compila già ogni shader sul driver vero: può anche misurarne il costo e scegliere
   la variante che costa meno (§5).
4. **La pagina "Sfondi" di Impostazioni non è un problema di GPU né di AIR**, e la tua idea non la migliorerebbe.
   Misurato: all'apertura System Settings crea **0 pipeline e 0 draw** e il carico GPU resta al 7%. Il lag è CPU:
   - **apertura a freddo**: ~24 s di CPU su 4 thread in ~20 s. Il 97% del tempo attivo di System Settings e l'89%
     di `Wallpaper.appex` è nel runtime Swift (`swift_conformsToProtocol`), chiamato da AttributeGraph di SwiftUI.
     Ogni prima ricerca di conformità costa ~1 ms su questa CPU;
   - **pagina aperta**: `VTDecoderXPCService` decodifica le anteprime Aerial **in software** con ~1,3 core di
     continuo. Questa GPU non espone la decodifica hardware né di HEVC né di H.264.

   Interventi utili: uno sfondo statico invece di un Aerial; al limite, un progetto a parte sul runtime Swift (§6.4).
5. **Altri colli di bottiglia individuati**, in ordine di peso: la coda GPU seriale che fa attendere le pipeline
   dietro i frame; il rilascio bloccante dei run CL (1,5–7 ms per run in Mappe); la cache GLSL su disco mai potata
   (3775 file per 413 shader distinti); RAM e VRAM. Piano in §8.

## 2. Dove va il tempo di una pipeline

| Fase | Chi la fa | Costo misurato | Si può mettere in cache? |
|---|---|---|---|
| AIR → passi LLVM → GLSL | noi (`TSAirTranslate`) | 3–10 ms per shader | sì: cache su disco e `.mslbundle` (0 ms dal secondo avvio) |
| `glCompileShader` (front-end GLSL) | driver | 1–30 ms | no |
| `glLinkProgram` | driver | 0,3–15 ms | no |
| **compilazione differita al primo draw** | driver (compilatore AMD) | **2 ms – 50 s**, superlineare | **no**: nessun program binary, nessuna cache GL di sistema |
| esecuzione di un draw piccolo | GPU | 0,1–1,9 ms (incluso `glFinish`) | – |
| kernel OpenCL: build | driver CL | 60–1100 ms | **sì**: binari CL su disco, 0,3–0,8 ms (A3 di `OTTIMIZZAZIONE-COMPUTE.md`) |

In Chrome (`docs/FINDINGS-RENDERING.md` §22) ogni pipeline attende in media 0,6–0,85 s perché la coda GPU è seriale:
la compilazione di un programma (link ~50 ms + warm-up ~170 ms) passa davanti o dietro ai frame. Quindi accorciare la
warm-up di uno shader accorcia anche l'attesa di tutti quelli in coda dopo di lui.

### Misura: costo contro dimensione (`exp/airopt/glsize.m`)
Banco: un fragment shader vero dalla cache GLSL, un vertex shader generato che scrive tutti i suoi varying, poi
compile, link e un draw con il punto **fuori dal volume di clip**. Così il driver valida e compila tutto, ma lo shader
non gira mai: con buffer pieni di zeri un ciclo potrebbe girare sulla GPU fino al watchdog. Verificato: subito dopo,
un draw visibile costa 0,1–1,9 ms, quindi la compilazione era già avvenuta nel draw fuori clip. Ogni misura ha un
commento diverso nel sorgente, così nessuna cache del driver indicizzata sul sorgente può aiutare. Campione:
78 shader stratificati per decile di dimensione più gli 8 più grandi sotto i 200 KB. 68 misurati; i più grandi
non sono stati misurati perché avrebbero tenuto il driver occupato per minuti.

| Dimensione | n | Mediana | compile | link | compilazione differita | totale | totale minimizzato |
|---|---|---|---|---|---|---|---|
| 0–1 KB | 21 | 0,3 KB | 1,1 ms | 0,4 ms | 1,8 ms | 3,2 ms | 3,4 ms |
| 1–3 KB | 28 | 2,0 KB | 3,2 ms | 0,9 ms | 6,2 ms | 10,3 ms | 9,1 ms |
| 3–10 KB | 13 | 4,0 KB | 5,7 ms | 1,6 ms | 21,8 ms | 29,1 ms | 31,9 ms |
| 10–20 KB | 1 | 12,8 KB | 10,3 ms | 2,9 ms | 4395 ms | 4408 ms | 5749 ms |
| 20–40 KB | 5 | 31,8 KB | 22,5 ms | 9,1 ms | 15182 ms | 15213 ms | 13755 ms |

Cosa se ne ricava:
- **la dimensione da sola non spiega il costo.** Uno shader da 22,9 KB (528 temporanei, quasi nessun load da buffer)
  compila in 43 ms; uno da 12,8 KB ne chiede 4400. Lo shader da 34 KB (52 s) contiene di fatto quello da 12,8 KB
  (4,4 s) più quello da 22,9 KB (43 ms): i costi non si sommano, si moltiplicano;
- il rumore sui giganti è alto: lo stesso shader da 31,8 KB (tre copie in cache) ha dato 14,1, 15,2 e 30,3 s;
- **minimizzare non serve.** Il testo senza commenti, rientri e righe vuote è più corto del 13%, ma il rapporto
  mediano dei tempi è 0,97 (da 0,55 a 1,30, cioè rumore).

### Ipotesi verificate e scartate
| Ipotesi | Prova | Esito |
|---|---|---|
| Testo più corto = compilazione più rapida | minimizzazione (−13% byte) | nessun effetto (0,97 mediano) |
| Le centinaia di temporanei dichiarati in cima a `main()` allungano la vita delle variabili | variante con dichiarazione al punto di definizione per le variabili assegnate una volta al livello esterno (141/145 e 233/245 spostate, `exp/airopt/scope.py`) | nessun effetto: 545–559 contro 557–617 ms; 4062–4296 contro 4055–4341 ms |
| Il costo lo fanno i fetch da texture buffer | coalescenza dei load (`exp/airopt/coal.py`) | **confermata**: 13–50× (§4.1) |

## 3. Il collo di bottiglia "pipeline creation": diagnosi

Gli shader lenti hanno in comune molte chiamate `ts_ld_<buf>(base + C)`: letture di struct per istanza o per oggetto
da un buffer `device`, che lo shim espone come texture buffer R32UI (una parola per `texelFetch`). Esempio reale
(lo shader da 12,8 KB):
```glsl
w58 = ts_ld_fssbo1((t54 + 144));
w60 = ts_ld_fssbo1((t54 + 148));
w62 = ts_ld_fssbo1((t54 + 152));      // tre fetch per un float3: stessi 16 byte
w64 = ts_ld_fssbo1((t54 + 160));
...
t55 = uintBitsToFloat(texelFetch(fssbo1_4, (fssbo1_off + (t54 + 80)) >> 4));   // qui invece un fetch da 16 byte
```
Il traduttore usa già la vista RGBA32UI `_4` quando l'IR carica un `float4` allineato a 16 (A3 di
`docs/OTTIMIZZAZIONE.md`). Quando invece l'IR carica scalari (campi `float`, `packed_float3`, struct), fa un fetch per
parola, anche se le parole stanno nella stessa finestra di 16 byte. `wordAt:` le memoizza per blocco, ma non le
raggruppa.

| Shader | Fetch da 4 byte | Texture | Compilazione differita |
|---|---|---|---|
| 4,5 KB | 0 | 6 | 11 ms |
| 4,8 KB | 5 | 3 | 68 ms |
| 7,0 KB | 17 | 3 | 564 ms |
| 12,8 KB | 35 | 12 | 4395 ms |
| 22,9 KB | 1 | 3 | 43 ms |
| 31,8 KB | 18 | 24 | 14–30 s |
| 34,1 KB | 35 | 12 | 52 s |

Il compilatore della VLIW5 raggruppa i fetch in clausole TEX, e con molti fetch dipendenti da indirizzi calcolati
il suo scheduler e l'allocatore di registri crescono in modo superlineare. È un'ipotesi coerente con i numeri: il
meccanismo interno del driver non si vede. Quello che si misura è la leva: meno fetch.

## 4. Tecniche per la creazione delle pipeline, in ordine di resa

### 4.1 Coalescenza dei load scalari (P1) – misurata, priorità massima
**Misura** (`exp/airopt/coal.py`: raggruppa `ts_ld_<buf>((tN + C))` con lo stesso `tN` e lo stesso `C / 16` in un
`uvec4` letto dalla vista `_4`, poi `.x/.y/.z/.w`; due ripetizioni):
| Shader | Fetch | Prima | Dopo |
|---|---|---|---|
| 7,0 KB | 17 → 7 | 528 / 530 ms | **41 / 40 ms** |
| 12,8 KB | 35 → 13 | 5017 / 4050 ms | **87 / 80 ms** |

Diffusione (413 shader distinti in cache): 152 leggono buffer a parole, 57 con 16 o più parole, 111 con load da unire.
Con la regola conservativa dell'esperimento si elimina il 28% di tutti i fetch da 4 byte (523 su 1870). La regola
copre solo la forma `(tN + C)`; quella vera vedrebbe anche gli offset costanti e le basi composte.

**Come farlo nel traduttore** (`src/TSAirTranslator.m`):
- in `wordAt:` la chiave di memo diventa `(buf, expr, C >> 4)` quando l'allineamento della parte dinamica
  (`p->align`) è ≥ 16. Il blocco si legge una volta come `uvec4 q = texelFetch(<buf>_4, (<buf>_off + expr + C16) >> 4)`
  e ogni parola diventa `q.x`…`q.w`. Con `p->align` = 8 si usa una vista RG32UI `<buf>_2` (da aggiungere al runtime
  come `_4`);
- **vincolo di correttezza**: le viste coprono tutto il buffer e `<buf>_off` è l'offset di binding. Per i load scalari
  Metal garantisce un offset allineato solo a 4, non a 16 (la vista `_4` di oggi è legale solo perché legge
  `float4`). Quindi: variante del programma `TSA_<stage><n>` ("offset del buffer n allineato a 16"), con il codice
  coalescente sotto `#if` e quello a parole come ripiego. Il runtime sceglie la variante al draw, dal valore di
  `_off`, con lo stesso meccanismo delle varianti rettangolo (`programForRectMask:`). Nel caso comune la variante usata
  dovrebbe essere una sola (WebGPU, quindi Chrome/Dawn, impone offset di binding multipli di 256; per le altre app
  va misurato: un contatore delle varianti `TSA_*` nelle statistiche lo dirà);
- lo stesso vale per i vertex shader (`vssbo`) e per i buffer `constant` letti con indice dinamico
  (`fbuf_d[o >> 4][(o >> 2) & 3]`, dove la selezione dinamica della componente costa ALU);
- prova: `make test` (corpus `translate` e `cfg` al pixel), più un test nuovo con letture di struct a offset 4, 8 e
  12 e binding a offset non allineati, così la variante di ripiego viene esercitata.

Effetto atteso oltre alla compilazione: meno istruzioni TEX anche in esecuzione (non misurato). La A3 aveva già dato
1,4–4× sugli schemi di buffer.

### 4.2 Misurare il costo nel builder dei `.mslbundle` e scegliere la variante migliore (P2) – la tua idea, nella forma possibile
`tools/mslbundle build` compila già ogni shader sul driver vero, e se la modalità normale non compila prova le
altre (senza strutturazione, senza passi). Si può estendere così:
- misurare per ogni shader anche la compilazione differita, con il draw fuori clip di `glsize`, e scriverla nel
  bundle (`Info.plist`: `CompileMs`). Ne esce l'elenco degli shader costosi per app, senza aspettare che un utente
  li noti;
- per gli shader oltre una soglia (per esempio 100 ms) provare le varianti del traduttore (normale, coalescente,
  senza unroll completo, senza strutturazione) e tenere **la più economica che compila**, verificata al pixel con
  lo stesso controllo dei `Rescued`. Il bundle conterrà allora il GLSL "più facile" per questo driver;
- costo: tempo di build (alcuni minuti in più per bundle, una volta per versione del traduttore). Nessun costo a runtime.

Questa è la parte realizzabile del "precompilare e comprimere": non il binario, che il driver non concede, ma il
sorgente che il driver compila più in fretta, scelto misurando.

### 4.3 Meno programmi distinti (P3)
- In Chrome il 27% dei programmi linkati non viene mai disegnato: programmi base di pipeline disegnate solo nella
  variante rettangolo, e viceversa. Il collegamento pigro alla prima necessità è stato misurato peggiore (1,4×, perché
  svuota la coda a metà passata). Proposta diversa: **registrare nel bundle quale variante ogni pipeline ha
  disegnato l'ultima volta** (la registrazione esiste già) e collegare subito quella, invece di indovinare. Il
  tentativo "tutto rettangolo" di §22 indovinava alla cieca.
- Dedup delle varianti Dawn che differiscono solo per costanti (già in elenco in `FINDINGS-RENDERING.md`): portare
  le costanti in uniform quando non cambiano il controllo di flusso.

### 4.4 Riscaldamento nei momenti di quiete (P4) – da valutare
I programmi noti di un'app (registrati) si potrebbero collegare e riscaldare sulla coda GPU quando è ferma, prima
che servano. È lo stesso principio della A5 del compute, che per OpenCL è già fatta. Rischi: occupa la coda proprio
all'avvio, e se l'app chiede subito un frame lo ritarda. Va misurato solo dopo P1, che riduce il problema alla
radice.

### 4.5 Cose che non funzionano (misurate, da non riprovare così)
- program binary GL: impossibili (`GL_NUM_PROGRAM_BINARY_FORMATS = 0`); `DARWIN_USER_CACHE_DIR` contiene solo
  `com.apple.metal` e `com.apple.metalfe`, nessuna cache GL;
- compilazione su un contesto condiviso: pipeline pronte 3× prima, ma il driver rifà il lavoro per contesto
  (+115 ms per programma, coda GPU ~11 s invece di ~6 s);
- programma base collegato pigramente: 1,4× peggio;
- minimizzazione del testo, compressione dei byte, dichiarazioni al punto di definizione: nessun effetto (§2).

## 5. Valutazione dell'idea: kernel standard precompilati e "compressi" per un'esecuzione quasi effimera

| Parte dell'idea | Stato | Verdetto |
|---|---|---|
| Precompilare la traduzione AIR → GLSL | fatto (cache su disco, `.mslbundle` per app e `system.mslbundle`) | già al massimo: 0 ms di traduzione |
| Precompilare il codice macchina GL | impossibile su questo driver | no |
| Precompilare i kernel OpenCL | fatto (binari CL su disco, A3) | sì, ~1 ms per kernel dopo il contesto (~29 ms, +50–80 MB) |
| Comprimere i byte (lzfse, minimizzazione) | misurato | inutile: il costo non dipende dai byte |
| "Comprimere" il lavoro chiesto al compilatore | misurato | **sì**: coalescenza 13–50× (§4.1) e scelta della variante più economica nel builder (§4.2) |
| Esecuzione quasi effimera dei kernel piccoli | misurato | lo è già: un draw piccolo costa 0,1–1,9 ms e uno shader sotto i 3 KB compila in ~10 ms. Il costo vero sta nei pochi shader pesanti |
| Lasciare spazio all'hard-compute | – | la risorsa contesa non è il tempo GPU dei kernel piccoli: sono la **coda GPU seriale**, occupata dalle compilazioni (secondi), e la **CPU** a 4 thread. P1 libera entrambe. GL non ha priorità tra contesti; OpenCL ha una coda propria, ma la GPU è una sola |

**Sui "kernel standard"** (filtri di CoreImage e CoreAnimation, blur, downscale): sono già piccoli, e il loro GLSL è
in `system.mslbundle` (semi `caglass`/`rbglass`). Un set di programmi scritti a mano e condivisi tra processi non
porterebbe nulla: senza program binary ogni processo li ricompila comunque una volta. Rendere effimeri quelli che
oggi non lo sono vuol dire ridurre il costo di compilazione dei pochi shader pesanti, cioè P1 + P2.

## 6. Caso di studio: la pagina "Sfondi" di Impostazioni

### 6.1 Chi lavora
La pagina non è un processo solo: l'interfaccia è `Wallpaper.appex` (ExtensionKit, fuori processo) e ogni tipo di
sfondo ha la sua estensione che produce le anteprime: Aerials, Image, Legacy, NeptuneOne (Tahoe), Sonoma,
Sequoia… Ci sono anche WallpaperAgent e `VTDecoderXPCService`. Lo shim è acceso solo in System Settings; in tutte
le estensioni è spento (motivo `outside`: stanno in `/System/Library/ExtensionKit`), e WallpaperAgent è un processo
critico.

### 6.2 Misure (`exp/airopt/wallpaper-measure.sh`, `sample`, `tsmtl stats`)
| Misura | Valore |
|---|---|
| CPU totale dell'apertura a freddo | ~24 s: System Settings 10,8, Wallpaper 8,9, Aerials 1,2, WallpaperAgent 0,9, VTDecoder 1,5, Image 0,5 |
| Picco | 7,8 s di CPU ogni 2 s (tutti e 4 i thread) per ~15 s |
| Lavoro GPU dello shim in System Settings | **0 pipeline, 0 draw**, carico GPU 7% |
| Tempo attivo nel runtime Swift (campioni `sample`, 8 s) | System Settings **96,6%** (`libswiftCore`), Wallpaper 88,6% |
| Chiamante | AttributeGraph `LayoutDescriptor::Builder::should_visit_fields` e `metadata::equatable` (SwiftUI che chiede per ogni tipo di view se è `Equatable`) |
| Costo di una ricerca a freddo (`exp/airopt/swiftconf.swift`, 524 immagini caricate) | ~1–5 ms la prima volta, 0,002–0,007 ms dopo. Le tabelle precalcolate della shared cache aiutano solo le conformità positive dei tipi di sistema (`Int`: 0,002 ms), non i "no" (~1 ms con o senza) |
| Seconda visita nello stesso processo | lavoro Swift quasi nullo (1,3 s), ma **`VTDecoderXPCService` a 3,5–4,4 s di CPU ogni 3 s** finché la pagina è aperta |
| Decodifica video hardware (`VTIsHardwareDecodeSupported`) | H.264 **no**, HEVC **no**, ProRes no |
| Memoria dei processi della pagina | ~300 MB RSS: Wallpaper 74, System Settings 71, Image 34, Aerials 32, Neptune 28, Agent 22, Legacy 17, VT 16 MB |
| Sfondo attuale | Aerial (`com.apple.wallpaper.choice.aerials`); il decoder aveva già 3 min 24 s di CPU in 47 min, poi 5 min 22 s dopo le prove |

### 6.3 Conclusione
Il lag degli Sfondi ha due cause, nessuna delle due grafica:
1. **apertura**: migliaia di ricerche di conformità del runtime Swift a ~1 ms l'una, in due processi in parallelo.
   È SwiftUI su una CPU del 2011 con 4 GB di RAM. Si paga una volta per processo: per questo la seconda visita è
   leggera;
2. **pagina aperta**: le anteprime Aerial (video HEVC) decodificate in software, ~1,3 core di continuo.

Accendere lo shim nelle estensioni non aiuterebbe (System Settings, che lo ha acceso, non disegna nulla con Metal
su questa pagina) e porterebbe un contesto GL in più per processo. Precompilare kernel non toccherebbe nessuna
delle due cause.

### 6.4 Cosa si può fare
- **Subito, senza codice**: uno sfondo statico (immagine) invece di un Aerial. Toglie la decodifica software sulla
  pagina, e anche quella sul desktop e sulla schermata di blocco quando l'Aerial è in movimento.
- **Seguito (2026-11-02)**: ricerca completa in `docs/OTTIMIZZAZIONE-SWIFT.md`. Al posto della cache persistente qui
  sotto, un indice in processo agganciato tramite la variabile di override del runtime (−35% di CPU all'avvio di un'app
  SwiftUI, prototipo validato), proposto come modulo "TeraScale Swift".
- **Progetto a parte, rischioso, non consigliato ora**: una cache persistente delle conformità Swift. Il runtime ha un
  meccanismo di override delle sue funzioni (`swift_conformsToProtocol` incluso), pensato per le librerie di
  compatibilità. Una libreria caricata presto potrebbe ricordare su disco i risultati negativi per (tipo, protocollo)
  e risparmiare la scansione all'avvio di ogni app SwiftUI. Va caricata in ogni processo (non solo in quelli con
  Metal), dipende dalla versione esatta del runtime, e un errore rompe tutte le app Swift. Fuori dall'ambito di AIR.
- **Decodifica video**: la UVD3 di questa GPU non è esposta a VideoToolbox (nemmeno H.264) e non ha mai avuto HEVC.
  Non c'è una leva realistica lato shim.

## 7. Altri colli di bottiglia individuati

| # | Collo di bottiglia | Evidenza | Tecnica |
|---|---|---|---|
| B1 | Compilazione differita superlineare | §2–3 | P1 coalescenza, P2 builder che misura e sceglie |
| B2 | Coda GPU seriale: le pipeline attendono dietro i frame | Chrome: 0,6–0,85 s di attesa media per pipeline, coda occupata 5,9–8,8 s per caricamento | ridurre il lavoro (P1), meno programmi (P3); i contesti condivisi sono stati misurati peggiori |
| B3 | Fetch da texture buffer anche in esecuzione | stesso schema di B1; A3 aveva dato 1,4–4× sui buffer | P1 vale anche a runtime; vista RG32UI per gli allineamenti a 8 |
| B4 | Rilascio degli oggetti GL a fine run CL bloccato sulla coda del driver | 1,5–7 ms per run in Mappe, ~21 ms per run da 12 ms in dispatchbench | rilascio asincrono con un `cl_event` (TODO 5 di `OTTIMIZZAZIONE-COMPUTE.md`: è un ridisegno) |
| B5 | Cache GLSL su disco mai potata | 3775 file per 413 shader distinti (~9×); 3 copie di uno shader da 1,6 MB del 31 ottobre | potatura per `TranslatorTag` all'avvio di `update.sh` o del builder: risparmia disco e I/O, non tempo di compilazione |
| B6 | Costo per pass (FBO e VAO ricreati) | ~20 µs per pass (B5 di `OTTIMIZZAZIONE.md`, non fatto) | cache di FBO e VAO per pass |
| B7 | `half` letti da buffer | `constant half4` 1,90 ms contro 0,73 ms di `float4` (`OTTIMIZZAZIONE.md`) | coalescenza anche per gli `half` (due per parola), `ts_h2f` vettoriale |
| B8 | VRAM da 256 MB | libera 34–70 MB con Mappe aperta | posizionamento (M2/M5 di `OTTIMIZZAZIONE-COMPUTE.md`); niente di nuovo da fare ora |
| B9 | RAM da 4 GB | contesto CL +50–80 MB per processo; la pagina Sfondi da sola ~300 MB in 8 processi | rilascio del contesto CL a riposo (M4, fatto); non accendere lo shim dove non serve |
| B10 | Runtime Swift a freddo, decodifica video software | §6 | fuori da AIR (§6.4) |

## 8. Piano proposto

Stato: realizzato. P4 valutato con le misure e lasciato fuori; B4 fatto ma spento di default perché in Mappe non
rende. Dettagli e misure in §9.

| Ordine | Intervento | Sforzo | Effetto atteso | Rischio |
|---|---|---|---|---|
| 1 | **P1** coalescenza dei load scalari in `wordAt:`, con varianti `TSA_*` per l'allineamento di `_off` e vista `_2` | medio | warm-up degli shader con struct da buffer 10–50× più corta; meno TEX a runtime | correttezza degli allineamenti: test dedicato e corpus al pixel |
| 2 | **P2** `mslbundle build` misura la compilazione differita (`CompileMs`) e, sopra soglia, sceglie la variante più economica | basso–medio | elenco degli shader costosi per app; bundle con il GLSL "più facile" | solo tempo di build |
| 3 | B5 potatura della cache GLSL per `TranslatorTag` | basso | disco/I-O | nullo |
| 4 | **P3** variante disegnata l'ultima volta registrata nel bundle e collegata subito | medio | −27% dei link in Chrome | previsioni sbagliate = link a metà passata (misurato 1,4×) |
| 5 | B4 rilascio asincrono dei run CL | medio–alto | −1,5–7 ms per run in Mappe | ordine GL↔CL |
| 6 | P4 riscaldamento nei momenti di quiete | medio | pipeline pronte prima | ritardo del primo frame |

Prima prova dopo P1: rimisurare con `exp/airopt/glsize.m` gli stessi 68 shader (`exp/airopt/data/pick.txt`
contiene i nomi dei file in cache) e Chrome con `tools/chrome-loadbench.sh`, che dà i tempi di creazione delle
pipeline, il link, la warm-up e il tempo della coda GPU.

## 9. Implementazione (2026-11-02, build 0.11.0)

| Voce | Stato | Dove | Misura | Interruttore A/B |
|---|---|---|---|---|
| P1 coalescenza | fatto | `blockWord:` / `wordAt:` in `src/TSAirTranslator.m`, varianti `TSU_` in `src/TSMtlPipeline.m` | compilazione differita 143,5 → 50,1 s (2,9×) su 112 shader registrati ≤20 KB | `TSAirNoCoalesce` (traduttore) |
| P2 builder che misura | fatto | `tools/mslbundle.m` (`build`, `cost`), `system/mslbundle.sh` | vedi sotto | `--no-measure` |
| B5 potatura cache | fatto | `mslbundle prune`, in coda a `system/mslbundle.sh` | 3347 file (30,6 MB) da togliere, 1588 da tenere per 507 shader registrati | `--dry-run` |
| P3 variante predetta | fatto | `TSVariantFile` in `src/TSMtlPipeline.m` (`var/` nella cache su disco) | Chrome: 28 → 19 programmi per caricamento, tutti disegnati | – |
| B4 fine run CL asincrona | fatto, spento di default | `TSMtlComputeEndRunAsync` / `TSMtlComputeJoin` in `src/TSMtlComputeCL.m` | nessun guadagno misurabile (Mappe, dispatchbench, ctest) | `TSMTL_CL_ASYNC_END=1` lo accende |
| B6 cache di FBO e VAO | fatto | `TSPassFramebuffer` in `src/TSMtlRender.m` | `cpubench passes`: 98 → 87 µs per passata | `TSMTL_NO_FBO_CACHE=1` |
| B7 `half` da buffer | fatto | coppie `.xy`/`.zw` dei buffer `constant`, `ts_h2f` | `gpubench` [5]: 1,90 → 1,19 ms GPU, primo draw 16 → 8 ms | – |
| P4 riscaldamento nei momenti di quiete | valutato, non fatto | – | §9.8 | – |

### 9.1 P1: coalescenza dei load
- Una parola di un buffer diventa una componente del blocco da 16 byte che la contiene (o della coppia da 8 byte
  quando la parte dinamica dell'offset è allineata solo a 8), letto una volta per blocco base. Buffer `device`: viste
  RGBA32UI `_4` e RG32UI `_2` sul buffer GL (riempito fino a un multiplo di 16). Buffer `constant`: l'elemento `uvec4`
  del blocco uniform; la coppia è il suo `.xy` o `.zw`, scelti dal bit 3 dell'offset (B7).
- **Allineamento.** Le viste indicizzano dall'inizio del buffer, quindi servono offset di binding multipli di 16, e
  Metal per i load scalari garantisce solo 4. Il codice a parole resta sotto `#if TSU_<stadio><indice>`; al draw il
  runtime collega la variante con `TSU_ = 1` per i binding non allineati, con lo stesso meccanismo delle varianti
  rettangolo. Il contatore "unaligned-buffer variants" delle statistiche dice quanto succede (Chrome: mai, WebGPU
  impone offset multipli di 256).
- **Analisi degli indici** (`TSKnownAlign`): Dawn indicizza i buffer come array di `u32` (`buf[i * 20 | 1]`,
  `buf[i * 20 + 2]`…). L'allineamento vero di `i * 20` mette le parole di un record in blocchi noti: lo shader di
  vertici Dawn più pesante passa da 6,2 s a 0,79 s (7,8×), con 6 fetch da 16 byte e 3 parole rimaste (`vid * 3` è
  allineato a 4: inevitabile).
- **Misura** (`mslbundle cost --max-kb 20`, dati in `exp/airopt/data/p1-cost20.tsv`): 112 shader registrati il cui
  GLSL cambia. Totale 143,5 s → 50,1 s (vertex 109,8 → 42,2 s, fragment 33,7 → 7,9 s); mediana 7,3× nella fascia
  50–500 ms e 8,5× sopra i 3 s. I due casi apparsi peggiori al primo giro erano rumore (ripetuti: 0,80 contro 0,83 s
  e 1,28 contro 1,29 s).
- Test: `cfg` (corpus al pixel contro il riferimento a parole, binding a offset 16, 4 e 8, gli ultimi due nella variante
  `TSU_`, schema Dawn `i*20 | k` con verifica sulla CPU).

### 9.2 P2: il builder dei `.mslbundle` misura e sceglie
`mslbundle build` misura la compilazione differita di ogni shader con il draw fuori clip di `glsize` e la scrive
nel bundle (`CompileMs`); sopra `--threshold` (100 ms) prova anche le altre modalità del traduttore (senza
strutturazione, senza passi, senza unroll completo con il nuovo `TSAirNoUnroll`, a parole) e tiene la più economica
che compila.
Gli shader sopra `--max-kb` (40) non si misurano (il driver può metterci minuti). `mslbundle cost` dà la tabella
coalescente contro parole per ogni registrazione. Il builder gira da `system/mslbundle.sh`, che `update.sh` chiama
dopo ogni aggiornamento.

Prova completa con `--max-kb 20` in una cartella temporanea (16 bundle, i bundle installati non toccati): 496
shader misurati, compilazione differita totale **60,7 s** con la coalescenza; 68 sopra i 100 ms, 10 sopra 1 s
(massimo 2,6 s). Sopra soglia il builder ha scelto un'altra modalità in 4 casi, tutti vertex shader: Dawn 1807 →
836 ms senza unroll completo, Dawn 1077 → 810 ms e 761 → 530 ms senza strutturazione, Terminal 928 → 731 ms senza
strutturazione. Shader traducibili e falliti per app identici ai bundle installati (Safari resta a 0: i suoi 51 sono
kernel di calcolo per il percorso OpenCL, non shader GL).

### 9.3 B5: potatura della cache GLSL
`mslbundle prune` tiene le voci che il traduttore attuale nomina per gli shader registrati e quelle scritte
nell'ultimo giorno, e cancella il resto; `system/mslbundle.sh` la esegue alla fine. Prova a secco su questa
macchina: 1588 file da tenere, 3347 da togliere (30,6 MB).

### 9.4 P3: la variante disegnata l'ultima volta
Quando una pipeline disegna con una variante diversa da quella registrata, il runtime scrive le sue macro `TSR_` /
`TSU_` in `var/<sha256 dei due sorgenti>` nella cache su disco; alla creazione successiva della stessa pipeline si
collega e si riscalda subito quella variante, e il programma base solo se serve davvero. La chiave è il GLSL, quindi
un traduttore nuovo riparte da zero. Statistica "predicted variants".

### 9.5 B4: fine asincrona dei run OpenCL
Un run CL che finisce a metà di un command buffer viene rilasciato sul thread di invio del runtime, mentre la coda
GPU codifica i comandi GL successivi (che possono leggere quanto il run ha scritto: codificarli va bene, mandarli
al driver no). `TSMtlComputeJoin` aspetta il rilascio prima di ogni flush, fence o lettura: completamento del
command buffer, `syncFromGL` dei buffer, letture delle texture, tracce. `ctest` ha casi compute → blit nello stesso
command buffer, cioè proprio questo percorso, e passa in entrambe le modalità.

Misura in Mappe (`tools/maps-bench.sh TSMTL_COMPUTE=1`, passaggio al 3D e panoramica, 18 run CL per prova, tre prove
per modalità alternate): tempo della coda GPU per i run **29 / 34 / 35 ms asincrono contro 19 / 11 / 32 ms
sincrono**. I "1,5–7 ms per run" del piano erano della 0.6.0–0.7.0: oggi la fine sincrona costa già ~1 ms per run.
`dispatchbench`: 2,96–3,04 ms contro 2,99–3,32 ms per dispatch, `ctest --soak 600`: 3,34 / 2,68 s contro 3,39 /
2,86 s: rumore. Siccome non rende e aggiunge punti di attesa che, se uno mancasse, diventerebbero una corsa GL ↔ CL,
la fine asincrona resta nel codice ma **spenta di default**; `TSMTL_CL_ASYNC_END=1` la accende per future prove.

Nota sul banco di Mappe: senza `--system` lo script caricava anche il driver installato accanto alla copia di
`build/` (avviso di `shim-run.sh`), e il `policy.plist` di prova (`apps/system-config`) ha il compute spento. Ora lo
script usa `--system` e il compute va acceso con `TSMTL_COMPUTE=1`.

### 9.6 B6: framebuffer e vertex array riusati
I framebuffer delle passate restano in una cache per dispositivo (32 voci, LRU) con chiave sugli attachment già
risolti (nome GL, target, livello, layer); `glCheckFramebufferStatus` solo alla creazione. GL ricicla i nomi delle
texture: prima di ogni `glDeleteTextures` (e quando una IOSurface viene riagganciata) si tolgono i framebuffer che
la contengono. Un solo vertex array per dispositivo: ogni replay dimentica l'ombra dello stato GL, quindi gli
attributi non usati vengono disattivati di nuovo. `cpubench passes`: 98 → 87 µs di esecuzione per passata
(`passfloor`, solo GL: 51 → 28 µs). Test in `uploads`: 40 target creati e distrutti uno dopo l'altro (nomi riciclati,
più delle 32 voci): ognuno riceve il suo colore. Senza la pulizia 39 su 40 sono sbagliati, quindi il test la
copre davvero.

### 9.7 B7: `half` letti da buffer
La parte "coalescenza" è P1: i `half` passano da `wordAt:`. Per i buffer `constant` mancava la coppia da 8 byte
(un `half4` ha passo 8): ogni parola era `fbuf_d[o >> 4][(o >> 2) & 3]`, con un indice di componente dinamico che
su TeraScale diventa una catena di selezioni. Ora è un solo elemento `uvec4` e `.xy`/`.zw`. La decodifica `ts_h2f`
mette l'esponente di inf/NaN con una somma (il payload resta) e il segno con una negazione invece di maschera e OR.
`gpubench` [5] (`constant half4` indicizzato per pixel): 1,90 → 1,42 ms con le coppie, 1,19 ms con la decodifica
nuova (−37%); primo draw 16 → 8 ms. Test nuovo in `cfg`: tutti i 65536 valori `half` confrontati bit per bit con la
conversione della CPU (NaN compresi, a parte il bit "quiet" che la CPU imposta); sbagliando di 1 la costante
dell'esponente il test fallisce.

### 9.8 P4: riscaldamento nei momenti di quiete – valutato, non fatto
Misura dopo P1 + P3 + B6 (`tools/chrome-loadbench.sh`, YouTube 30 s e poi il sito 30 s; log `exp/log-AIR*.txt`),
contro le misure del 2026-11-01 (`exp/log-NP*.txt`, `PR*`):

| | 2026-11-01 | 0.11.0 (AIR2 / AIR3) |
|---|---|---|
| programmi collegati per caricamento | 28 (27% mai disegnati) | 19 (tutti disegnati) |
| warm-up (compilazione differita) | 6,6 s | 1,5 / 2,1 s |
| attesa delle pipeline, somma | 18,8 s | 5,3 / 7,7 s |
| coda GPU occupata | 5,9–10,8 s | 3,3 / 4,2 s |
| draw nei 60 s | ~2200 | 17 600 / 19 800 |

Il primo caricamento dopo una ricompilazione (AIR1) ritraduce tutto (2,0 s di traduzione) e occupa la coda per
5,5 s, comunque sotto il vecchio intervallo. Le pagine si vedono corrette (`exp/load-AIR3-*.png`).

Perché P4 non conviene ora:
- le pipeline arrivano a raffiche quando una pagina appare (YouTube, poi il sito), cioè quando servono; tra le
  raffiche la coda è quasi ferma (1,3 s di lavoro su 60). All'avvio la coda non è mai "quieta": riscaldare lì
  ritarda il primo frame, che è il rischio già scritto in §4.4;
- per riscaldare prima bisogna sapere cosa servirà. Le registrazioni di un'app contengono tutto ciò che ha mai usato
  (507 shader registrati su questa macchina): collegarli tutti costerebbe decine di secondi di coda GPU e memoria su
  4 GB di RAM, per servirne una ventina;
- ogni collegamento con riscaldamento blocca la coda seriale per 50–250 ms: un frame che arriva in quel momento
  aspetta, cioè uno scatto visibile in cambio di un guadagno che dopo P1 è di ~2–3 s per caricamento, già spostati
  fuori dal percorso critico da P3;
- la compilazione su un contesto condiviso, l'unico modo per non occupare la coda, è già stata misurata peggiore
  (§4.5).

Se servirà in futuro, la forma ragionevole è ristretta: solo le pipeline con `CompileMs` alto nel bundle dell'app
(P2 le conosce), solo dopo che l'app ha presentato i primi frame e solo a coda vuota da almeno 1–2 s.

### 9.9 Prove
`make test` (phase1 44, phase2 33, phase3 33, translate 24, cfg 96, uploads 20, system 14: tutto ok) e
`make test-compute` (glkernels, ctest 42 controlli con e senza compute, cltrans 21/21, runtime, coerenza dei buffer,
rilascio a riposo: tutto ok). Chrome caricato tre volte con la build: pagine corrette.

## Appendice: riprodurre le misure
- Banco di compilazione: `clang -fobjc-arc -O1 -Wno-deprecated-declarations exp/airopt/glsize.m -framework Foundation
  -framework OpenGL -o glsize && ./glsize out.tsv <file della cache .plist>…`, poi `python3 exp/airopt/an.py out.tsv`.
  `GLSIZE_CHECK=1` aggiunge il draw visibile di controllo. **Non togliere il clip**: con buffer a zero alcuni shader
  girerebbero sulla GPU fino al watchdog.
- Varianti: `python3 exp/airopt/coal.py <in.plist> <out.plist>` (coalescenza), `exp/airopt/scope.py` (dichiarazioni).
  Il GLSL coalescente dell'esperimento presume la base allineata a 16 e serve solo a misurare la compilazione: i
  risultati dei pixel non sono stati verificati.
- Sfondi: `zsh exp/airopt/wallpaper-measure.sh <tag> 25` (apre Impostazioni → Sfondi e campiona i processi), poi
  `python3 exp/airopt/wallpaper-timeline.py <tag>.samples 2`; per il profilo, `sample <pid> 8 -mayDie -file …`.
- Runtime Swift: `xcrun swiftc -O exp/airopt/swiftconf.swift -o conf && ./conf` (con e senza
  `SWIFT_DEBUG_ENABLE_SHARED_CACHE_PROTOCOL_CONFORMANCES=0`).
