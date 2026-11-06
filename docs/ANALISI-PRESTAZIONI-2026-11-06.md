# Analisi dell'efficienza grafica (2026-11-06): verdetto e piano

Domanda: con acceleratori (0170-0181), compilatore diretto AIR → Valhall (`VMG_ISA=1`) e kernel 0180 sul telefono,
le animazioni sono al limite dell'hardware (MT6781: Mali-G57 MC2, 6×A55 + 2×A76) o il software rallenta ancora la
presentazione dei frame?

Tutte le misure di questo documento sono state prese oggi sul telefono (kernel 0180, driver di HEAD con `VMG_ISA=1`,
scanout acceso, `vivascaler=2 vivajpeg=1`), senza riavviare il kernel. Le stime sono segnate come tali.

## Verdetto: opzione 2, il software rallenta ancora, ma con un tetto hardware preciso

Le due scene misurate danno risposte diverse, e il verdetto le tiene insieme:

| scena | oggi | dopo il piano (stima) | tetto dell'hardware |
|---|---|---|---|
| Home, swipe tra pagine (render server, GPU-bound) | 26,4-27,5 ms per frame (37 fps), GPU occupata 90-93 % | ~21-22 ms (45-48 fps) | **la GPU riempie ~30 schermate blended per frame: 60 fps non raggiungibili con questo albero di layer** |
| Impostazioni, scroll (app-driven, catena in serie) | 42,9 ms (23 fps) col governor CPU; 32,7 ms (31 fps) con i clock CPU al massimo | ~16,7-20 ms (50-60 fps) se la catena si sovrappone come sulla home | GPU 14 ms per frame < 16,7 ms: 60 fps possibili |

In altre parole: **sulla home il limite è il fill-rate del G57 MC2 e nessun compilatore o acceleratore lo sposta**;
restano 4-5 ms per frame di lavoro inutile da togliere. **Nelle app il frame rate è dimezzato dal software**: il
governor CPU tiene i cluster al minimo durante gli scroll, e la catena app → CA → GPU → schermo gira in serie e si
quantizza a 2 vsync per frame. Il piano (§4) è ordinato per resa misurata.

## 1. Misure di oggi

### 1.1 Home, swipe (12 andate e ritorno, `anim.sh`: `disp lat` + `gpu lat`)

| | governor CPU (clock al minimo) | clock CPU fissi al massimo |
|---|---|---|
| SwapEnd ogni | **27,5 ms** (559 swap) | **26,4 ms** (440 swap) |
| vsync → SwapEnd (render CA) | 7,6 ms | 9,0 ms |
| SwapEnd → GPU done | 40,6 ms (2 frame in coda sulla GPU) | 41,1 ms |
| scelto → a schermo | 8,3 ms | 8,6 ms |
| GPU occupata | 90 % | 93 % |
| job sull'hardware | 1066 µs medi, 24 job per frame | 1069 µs, 24 per frame |
| frame copiati dalla CPU / in scanout | 400 / 159 ("surface not contiguous") | – |

La home è GPU-bound: ~25 ms di GPU per frame, due frame in volo, i clock CPU non contano.

### 1.2 Impostazioni, scroll (6 andate e ritorno, `scroll.sh`)

| | governor CPU | clock CPU al massimo |
|---|---|---|
| SwapEnd ogni | **42,9 ms** (23 fps) | **32,7 ms** (31 fps) |
| vsync → SwapEnd | 8,7 ms | 8,5 ms |
| SwapEnd → GPU done | 18,1 ms | 15,9 ms |
| scelto → a schermo | 8,5 ms | 8,3 ms |
| somma | 35,3 ms | 32,7 ms (= intervallo: tutto in serie) |
| GPU occupata | 31 % | 41 % |
| job per frame | 23 (676 µs medi) → **14-15 ms di GPU per frame** | 23 (615 µs) |

Con i clock al massimo l'intervallo è esattamente 2 vsync (33,3 ms): render (8,5) + GPU (14) + attesa del frame end
non stanno in un periodo, e il frame successivo parte solo quando il precedente è a schermo.

### 1.3 Cluster CPU durante uno scroll di 5 s (`cpu status` del kernel 0145)

```
ll   773 MHz (opp 14)  busy 0.1 .. 23 %     time ll : 774:100%
big  834 MHz (opp 14)  busy 1.4 .. 21 %     time big: 835:100%
cci  559 MHz (opp 14)                       time cci: 560:100%
```

I cluster non hanno mai lasciato l'OPP minimo durante lo scroll. Il governor (`viva_cpufreq.c`) misura il core più
occupato del cluster ogni 16 ms e sale al massimo solo oltre l'80 %; sotto, `need = MHz_attuale × busy / 700`. Un
thread UI che fa 8 ms di lavoro ogni 33 ms è occupato al 25 %: a 774 MHz chiede 276 MHz e resta al minimo per
sempre. In più la preferenza per gli A76 (`sched_viva_fast_cpus`) manda i thread UI su un A76 a 835 MHz, più lento
di un A55 a 2000. Prima della 0145 l'A55 girava fisso a 1865 MHz: su questo punto siamo **regrediti**.

Con `cpu gov off; cpu set ll 2000; big 2050; cci 1400` lo scroll passa da 42,9 a 32,7 ms per frame. Termico:
picco visto 87 °C (trip 85), 38-39 °C oggi; il boost deve restare sotto il controllo termico della 0147.

### 1.4 Costi unitari della GPU (`passbench`, 1125×2436 BGRA8, mediana di 15, ms per command buffer)

| | IOSurface lineare | privato |
|---|---|---|
| 1 pass, clear+store | 1,74 | 1,33 |
| 1 pass, load+store | 2,89 | 2,41 |
| 4 pass, load+store | 4,97 (**+0,69 per pass**) | 4,70 (**+0,76 per pass**) |
| 1 pass + 10 draw blended a schermo intero | 10,11 (**+0,80 per draw**) | 9,05 |
| 10 draw opachi a schermo intero (clear+store) | – | 1,53 (**+0,15 per draw**) |

Il numero "1 pass" contiene ~1,6 ms fissi (submit, attesa, risveglio): il costo marginale di un pass a schermo
intero con load+store è ~0,7-0,8 ms, di un layer blended a schermo intero ~0,8 ms, di un layer opaco ~0,15 ms
(hidden surface removal). 2,74 Mpx in 0,8 ms = 3,4 Gpx/s = **90 % del picco teorico del G57 MC2** (2 pixel per
clock per core × 2 core × 950 MHz = 3,8 Gpx/s). Il lavoro per pixel di CoreAnimation è già al limite del blender.

### 1.5 Struttura di un frame reale (`VMG_TRACE_DRAW=1 VMG_TRACE_FRAME=0`, trace di 733 command buffer)

Frame della home durante lo swipe (cb 700-730): **13 pass, 140 draw, 26 job**, GPU 24-25 ms (il minimo misurato,
24,1 ms, è il costo vero; i valori più alti sono coda dietro al frame prima). Composizione:

| pass | dimensione | draw | note |
|---|---|---|---|
| 4 segmenti del framebuffer | 1125×2436, load+store, IOSurface | 15, 22, 30, 39 | ogni segmento termina per un blur di sfondo; tutti i draw hanno scissor 0,0-1125,2436; `fixed_frag_lph_cph` (legge il clip mask in c1 memoryless), 1 `attachment_clear_frag_lph` e 1 `luma_boost_lph` a schermo intero |
| blur del dock / pillola | 64×64, 256×64, 128×64 | 1-5 | `downsample_8`, `narrow_blur_19` |
| blur cartella / widget | 364×364, 284×611, 147×310, 288×615 | 2-15 | `downsample_4`, `narrow_blur_19` |

I 4 segmenti costano ~3 ms di load+store; il resto (~21 ms) è riempimento di layer blended: icone di due pagine,
etichette, widget, sfondo, luma boost, ombre. Per confronto una GPU A11 (iPhone X) ha circa 3-4 volte il fill-rate
(stima da dati pubblici): lo stesso frame le costa ~7 ms.

Frame di Impostazioni (cb 600-610): 11-12 pass per frame, **4 segmenti a schermo intero** (barra di navigazione con
blur, isola dinamica 364×364, una regione 565×1220 con `narrow_blur_11`), 14 ms di GPU.

Altro visto nel trace:
- cb 731: `copies 1 in (10705 KB) 1 out (10705 KB)`, flush 23,4 ms: una IOSurface **1125×2436 BGRA con pitch 4512**
  (allineato a 32, non a 64) non si può importare su Valhall e viene copiata dentro e fuori dalla CPU: 23 ms di stallo
  sulla coda GPU, 2 volte in 33 frame di swipe (snapshot della home). Il kernel dichiara allineamento 64 (sel 13), ma
  il client passa `IOSurfaceBytesPerRow` esplicito e il kernel lo accetta com'è (`SweetSurface`, 0046).
- replay del driver per frame: 3-6 ms senza trace (stima dai cb più leggeri), 6-13 ms con il trace acceso.
- Pagine di CA: 3 superfici (804, 802, 801), usate 629 / 406 / 310 volte: una sola pagina libera alla volta.

### 1.6 Display

`disp`: pannello 1080×2400, mostrato come finestra centrata della superficie 1125×2436 (nessuna scala). Scanout
acceso, ma **la maggioranza dei frame viene copiata** (6474 copie contro 4815 scanout dal boot; durante lo swipe
400 contro 159), motivo "surface not contiguous": l'allocazione contigua (`inTaskWithPhysicalMask`, budget 96 MB)
fallisce per frammentazione e la pagina ricade su memoria sparsa. Ogni copia costa 3,1 ms di CPU (a 774 MHz) e la
pagina resta occupata fino alla copia.

### 1.7 Cosa non è il collo di bottiglia

- Compilatore ISA: alla pari con Mesa (ISA-COMPILATORE.md); lo shader caldo `fixed_frag_lph_cph` gira al 90 % del
  picco del blender, quindi un codice migliore non dà fps. Resta utile per correttezza, avvio e copertura.
- Acceleratori: la composizione di CA non passa dallo scaler (ANALISI-ACCELERATORI §Stato); nessun frame del trace
  usa VideoToolbox o JPEG.
- Latenza kernel per job: start latency 2-7 µs, IRQ → handler 0 µs via filtro, submit_batch 169 µs medi, GPU "idle
  con job in coda" 0 %. Le K0b/K0e/K0g sono risolte.
- GPU DVFS: 950 MHz sotto carico (load 97-99 %), boost dal display.

## 2. Limiti dell'hardware (ciò che nessun software cambia)

| limite | numero | effetto |
|---|---|---|
| Fill-rate del Mali-G57 MC2 | 2 px/clk/core, 2 core, 950 MHz = 3,8 Gpx/s; misurati 3,4 | un layer blended a schermo intero = 0,8 ms; la home ne ha l'equivalente di ~30 per frame |
| Tile write-back / preload | ~0,7-0,8 ms per load+store di 2,74 Mpx | ogni segmento aperto da un blur di CA costa 0,8 ms |
| Risoluzione logica dell'iPhone X | 1125×2436 = 2,74 Mpx su un pannello 1080×2400 | 8 % di pixel in più del necessario, e la finestra centrata |
| Struttura del frame di CoreAnimation | 4 segmenti + 8-9 pass di blur per frame, tutti i draw con scissor a schermo intero | è il render server di Apple: non si cambia, si può solo stringere l'area |
| Blender e texture unit | 4 texel/clk/core, 32 FMA/clk/core | `fixed_frag_lph_cph` è 1 campionamento + 1 fetch + blend: fissa |
| Pipeline del pannello | switch solo al frame end (16,7 ms), nessuna coda di swap nell'OVL | "scelto → a schermo" ≈ mezzo frame + copia |
| CPU | A55 2,0 GHz / A76 2,05 GHz (OPP0), LPDDR4X senza DVFS configurato | render CA 8,5 ms per frame anche al massimo: la catena app-driven non sta in 16,7 ms senza sovrapposizione |
| Termico | trip 85 °C, picco visto 87 °C | i clock massimi non sono sostenibili senza il throttle della 0147 |

Conseguenza: anche con tutto il piano la home con blur sta intorno a 45-48 fps; 60 fps sono alla portata delle
scene da app (scroll, transizioni semplici) dove la GPU sta sotto 16,7 ms per frame.

## 3. Dove va il tempo oggi, in sintesi

```
Home (GPU-bound):          GPU 25 ms  ──── 4 segmenti 3 ms │ blur 1 ms │ layer blended ~21 ms
Impostazioni (in serie):   app+CA 8,5 ms → replay ~2 + GPU 14 ms → tick + frame end 8,3 ms = 32,7 ms (2 vsync)
                           con governor CPU: tutto a 774/835 MHz → 42,9 ms
Entrambe:                  60 % dei frame copiati dalla CPU (3,1 ms) perché le pagine non sono contigue
Ogni tanto:                23 ms di stallo per una IOSurface 1125×2436 con pitch 4512 copiata dentro e fuori
```

## 4. Piano delle modifiche (in ordine di resa misurata o stimata)

Ogni voce: dove, cosa, guadagno atteso, toggle, verifica. Le voci 1-2 e 6 sono kernel (da passare all'agente del
kernel), 4-5-7 sono driver (`gpu/`), 3 è prima di tutto una misura.

### P1. Governor CPU: boost per l'interfaccia (kernel, `osfmk/arm64/viva_cpufreq.c`, 0145/0147) — **+31 % fps nelle app, misurato**

Problema: soglia all'80 % del core più occupato, calcolo `need` proporzionale al clock attuale; un thread UI al
25 % resta al minimo. Modifiche:
1. **Boost da attività del display**: come la 0137 per la GPU, `AppleCLCD` segnala a `viva_cpufreq` ogni SwapEnd
   (e `IOHIDSystem`/il driver touch ogni evento): per 250 ms dall'ultimo segnale i cluster LL e big stanno a un OPP
   alto (default OPP 0, `vivacpuboost=MHz` per LL e big; `vivacpuboostms`). Sotto i limiti termici della 0147.
2. **Salita proporzionale all'utilizzo del singolo core, non al clock attuale**: `need = MHz_max × busy / 500`
   (sale sopra il 50 % del core più occupato), isteresi in discesa di 3 campioni come ora.
3. **Coerenza LL/big con la preferenza A76**: se `sched_viva_fast_cpus` è attivo, il cluster big non deve scendere
   sotto l'OPP a cui è più veloce di un A55 al suo OPP corrente (tabella: A76 ≥ 1,4 × MHz_A55 / 1,46), altrimenti
   la preferenza va spenta a runtime.
4. Link: `cpu boost on|off`, contatori "boost attivi / ms in boost" in `cpu status` e in `gpu kv`.

Verifica: `scroll.sh` → SwapEnd ogni ≤ 33 ms (oggi 42,9) e `time ll` con la maggioranza a 2000 durante lo scroll;
`anim.sh` invariata o meglio; temperatura stabile sotto 80 °C in 5 minuti di scroll continuo.

### P2. Pagine del framebuffer sempre contigue (kernel, `SweetSurface.cpp` / `SweetFramebuffer.cpp`) — niente copia CPU da 3,1 ms, un frame di latenza in meno

Problema: 60-70 % dei frame vanno nel percorso copia perché l'allocazione contigua delle pagine di CA fallisce.
Modifiche:
1. **Pool riservato al boot**: 4 buffer da `round_page(1125×2436×4)` = 44 MB presi contigui sotto 4 GiB all'avvio di
   `AppleCLCD` (prima della frammentazione), consegnati alle IOSurface a dimensione display (`sweet_surface_scanout_w/h`,
   4 byte, 1 piano) con `inTaskWithPhysicalMask` solo come ripiego. Rilascio al pool alla `free()` della superficie.
   Boot-arg `vivafbpool=N` (0 = come ora).
2. `disp` mostra: pagine dal pool / dal ripiego / sparse; `disp kv` `frames_copied` deve restare ~0 durante le animazioni.
3. Con tutte le pagine in scanout, la copia resta solo per frame parziali e per la console.

Verifica: `anim.sh` → "copies" invariato durante lo swipe e "frames scanned out" = swap; "scelto → a schermo" in calo
(oggi 8,3 ms); nessun tearing con `vctl burst`.

### P3. Catena in serie delle scene app-driven (misura, poi kernel/CA) — fino a 2× negli scroll

Fatto osservato: in Impostazioni l'intervallo è la somma delle tre fasi e si quantizza a 2 vsync; sulla home due frame
si sovrappongono. Con 14 ms di GPU per frame, la sovrapposizione porterebbe gli scroll a 50-60 fps. Prima di
toccare qualcosa servono tre numeri, da raccogliere con un contatore nel kernel e un trace:
1. **Chi aspetta**: contatore per frame in `AppleCLCD` delle risposte "busy" di SwapWait (quale swap id, quale pagina:
   la precedente o quella a schermo) e del momento in cui ogni pagina viene ritirata rispetto al frame end; oggi
   `SwapWait busy` è cumulativo (6,2 per frame in Impostazioni, 20 sulla home).
2. **Quando parte il commit dell'app**: `VMG_TRACE_FRAME=0` in Preferences (il suo CA locale non usa la GPU, ma il
   log di `CA::Transaction::commit` è visibile con `vlog 10 Preferences`), confrontato con i tick vsync del kernel.
3. **Pagina del ring**: se CA aspetta sempre il ritiro della pagina N-1 (= frame N a schermo), con P2 il ritiro avviene
   allo switch; con la copia avviene a copia finita. Se invece aspetta il commit dell'app, il collo è la latenza vsync →
   app → CA (8,5 ms costanti anche a 2 GHz: è attesa, non calcolo).

Leve, a seconda del risultato: (a) ritirare la pagina copiata appena la copia è finita (già previsto, da verificare
che accada); (b) "early present" anche per il ritiro: notificare lo swap "displayed" appena lo switch è
programmato, non al frame end successivo; (c) anticipare la notifica vsync di CA (`sweetfb_lead`) per dare
all'app più tempo prima del render di CA; (d) se la catena resta in serie, la sola strada è accorciare le fasi
(P1, P4, P5). Guadagno: da 32,7 a 16,7-20 ms per frame negli scroll se (a)/(b) sbloccano la sovrapposizione.

### P4. Scissor dai vertici dei draw (driver, `vmg_exec.c`) — 2-3 ms per frame sulla home, ~1,5 in Impostazioni (stima)

Tutti i 140 draw di un frame hanno scissor 0,0-1125,2436, quindi Panfrost (`panfrost_batch_union_scissor`) apre ogni
segmento a tutto schermo: load+store di 2,74 Mpx anche per il segmento che disegna solo il dock. Modifica:
1. Per le pipeline di CA con vertex shader `fixed_vert_lph_spc` / `std_vert1_lph` (6 vertici, posizione in pixel
   dopo la matrice in cb0), al draw il replay legge i 6 vertici (dal chunk `setVertexBytes` o dal buffer, mai da BO
   write-combined: copia cached come per le texture) e applica la matrice sulla CPU; se il quad è dentro il
   framebuffer, il draw riceve uno scissor pari al suo bounding box (arrotondato ai tile da 16) intersecato con quello
   di Metal. La batch area di Panfrost diventa l'unione dei bounding box.
2. Le pass che contengono un draw a schermo intero (sfondo, `attachment_clear`, `luma_boost`) restano intere:
   il guadagno è sui segmenti 2-4 e sulle pass di Impostazioni dopo il blur della barra.
3. Toggle `VMG_NO_DRAW_BOUNDS=1`; `VMG_TRACE_DRAW` stampa il bounding box; contatore "tile risparmiati" in
   `vgpu_counters()`.

Rischio: bounding box sbagliato = taglio visibile. Verifica: screenshot pixel-identici (home, Impostazioni, App
Library) con e senza toggle; `anim.sh` job medio in calo.

### P5. `attachment_clear` → clear della pass (driver) — ~1 ms per frame (stima)

CA azzera il clip mask memoryless (c1) con un draw a schermo intero all'inizio di ogni segmento (1 per segmento,
4 per frame, `attachment_clear_frag_lph` con blend 0, scrive c0 e c1). Se il primo draw di una pass è questo shader
con quad a schermo intero e mask f, il replay lo sostituisce con `pipe->clear` sugli attachment che scrive (c1 sempre;
c0 solo se il colore è costante e la pass non ha load sul c0). Toggle `VMG_NO_CLEAR_DRAW=1`. Verifica: screenshot
identici, job medio -0,2 ms.

### P6. `IOSurfaceBytesPerRow` arrotondato a 64 nel kernel (kernel, `SweetSurface.cpp` 0046) — toglie gli stalli da 23 ms

Il client (snapshot 1125×2436, bpr 4512; LA08 230×186, bpr 480; altri layer di CA) passa un pitch allineato a 32; il
kernel lo accetta e il driver deve copiare la superficie dentro e fuori a ogni uso (10,7 MB ↔ 23 ms). Modifica:
`s->bytesPerRow = round_up(bytesPerRow, 64)` quando il valore viene dal client e il formato è a 1 piano (i client
rileggono il pitch dal lock result +0x28: CA, ImageIO e IOSurface.framework lo fanno sempre; chi alloca con
`IOSurfaceAllocSize` esplicito resta com'è, perché il kernel controlla già `end <= allocSize`). Boot-arg
`vivasurfpitch=0` per tornare indietro. Verifica: log `pitch not 64-aligned, copied` assente in `VMG_STDERR` dopo un
giro di home/app/screenshot; `VMG_TRACE_FRAME=20` senza cb con `copies ... (10705 KB)`.

### P7. Transaction elimination sul framebuffer (driver + Mesa) — ~1 ms per frame (stima), bassa priorità

Panfrost attiva il CRC per tile (`panfrost_should_checksum`) solo sulle risorse che alloca lui, con il buffer CRC in
coda alla stessa BO; le pagine importate (IOSurface) non lo hanno. Con un CRC le store dei segmenti 2-4 scrivono
solo i tile cambiati (la store è ~0,45 ms a schermo intero). Serve: `pan_image_layout` con CRC in una BO separata per
le risorse importate (patch Mesa 0007), e `vmg_texture_create_iosurface` che la alloca. Toggle `PAN_MESA_DEBUG=nocrc`.

### P8. Rendering nativo 1080×2400 (kernel `sweetfb_native` + MobileGestalt) — -8 % di pixel, bassa priorità

Il percorso esiste (0061) ma dà schermo blu con SpringBoard; sistemarlo toglie la finestra centrata e 8 % dei pixel di
ogni pass. Va rifatto sopra scanout/K0d/scaler. Da valutare solo dopo P1-P6.

### P9. DRAM (DVFSRC) — prima misurare

Il DRAM resta all'OPP del preloader (0x10012000 vuoto). Il tempo per job scala con 1/clock GPU (compute-bound), ma la
parte load/store (~15 % del frame) potrebbe risentirne. Misura: benchmark di copia GPU (blit 11 MB) in `passbench`
→ GB/s; se sotto ~10 GB/s (LPDDR4X-4266 ×32 = 17 GB/s di picco), configurare il DVFSRC o fissare l'OPP alto.

### Cosa non fare

- Altro lavoro sul compilatore ISA per gli fps: lo shader caldo è al 90 % del picco del blender.
- Scaler/MDP per la composizione: CA non lo usa.
- Più pagine nel ring di CA: il conteggio è fisso a 3 nel binario (ANALISI-CPU-E-PAGINE §3).

## 5. Come rifare le misure

Script nello scratchpad di questa sessione (ricreabili da questo documento): `lk.sh SECS ARGS` (viva-link con
watchdog e retry su "Access denied"), `anim.sh` (home: reset di `disp lat`/`gpu lat`, 12 swipe, stampa), `scroll.sh`
(Impostazioni: 12 scroll verticali), `sw.sh` sul telefono (swipe di 5 s in background per leggere `cpu status` sotto
carico), `parse.py` (struttura dei pass dal trace `VMG_TRACE_DRAW=1 VMG_TRACE_FRAME=0 VMG_STDERR=/private/var/tmp/vmgtrace`).
Clock CPU fissi: `cmd cpu gov off; cmd cpu set ll 2000; cmd cpu set big 2050; cmd cpu set cci 1400`; ripristino
`cmd cpu gov on`. Il trace di oggi: 733 command buffer, 4411 pass, 46382 draw (`trace.txt`, 7,4 MB).
