# Richieste per il kernel (driver GPU, patch 0100 e successive)

Da: lato userspace (`~/Developer/ios-viva/gpu`). Obiettivo: `backboardd` e tutto CoreAnimation sul driver Metal
(fase G7 di `fork/docs/PIANO-GPU.md`), con `vivagpu=2`. In ordine di priorità. Per ognuna c'è il perché e cosa
serve a me per verificarla.

## Bloccanti per G7

### K0h. Submit a lotti e contatore di completamento condiviso (2026-11-04, analisi userspace) — adottato con 0119
Userspace (libdrm-xnu, minor >= 2): SUBMIT_BATCH ogni 16 submit e prima di ogni altra chiamata, WAIT_BO risposte dalla
pagina di completamento (non per le IOSurface importate né per i BO WB). K0i: promessa al commit per i command buffer
che scrivono IOSurface non copiate. Da verificare sul telefono: `gpu calls` (submit_batch, surf_promise) e `VGPU_STATS`.

Dopo le ottimizzazioni userspace (vedi FINDINGS, 2026-11-04 sera) per frame restano ~100 SUBMIT e ~50 WAIT_BO. Le
WAIT_BO rimaste sono quasi tutte sul BO del pool di un batch dello stesso frame: userspace non può sapere che il suo
ultimo job è finito senza chiederlo. Le SUBMIT sono 2 per pass (job vertex/tiler + job fragment, slot diversi su JM).
- Serve:
  1. un selettore `SUBMIT_BATCH`: un array di `vgpu_submit` in una chiamata, eseguiti in ordine come N SUBMIT (stesse
     dipendenze implicite). libdrm-xnu accoderebbe le submit e le invierebbe insieme prima di ogni attesa, mappatura o
     fence (2 x N chiamate -> 1 per command buffer);
  2. una pagina in sola lettura mappata nel processo con il numero dell'ultimo job completato della connessione, e il
     numero del job restituito da SUBMIT: WAIT_BO con timeout 0 e il controllo dei fence diventano una lettura di
     memoria in libdrm-xnu.
- Per verificare: `VGPU_STATS=1 VMG_CA_TIME=1 VMG_CA_SETTINGS=1 ca 61` (chiamate e tempo per selettore all'uscita).

### K0i. Fence "promessa" per le IOSurface prima della submit (2026-11-04, analisi userspace)
I command buffer che scrivono una IOSurface vengono rieseguiti e sottomessi prima che `commit` ritorni (altrimenti
SpringBoard legge snapshot a metà: chi legge aspetta solo i job che il kernel conosce). Così il thread di CA non può
preparare il frame dopo mentre la coda GPU riesegue il precedente.
- Serve: un selettore che, dati gli id delle IOSurface scritte, crei un fence non ancora segnalato e lo metta come
  `busy` sulle superfici (lo vedono IOSurfaceLock, K0c e le dipendenze implicite di altri processi); la SUBMIT
  successiva che lo indica (es. come out_sync) lo sostituisce con il fence del suo ultimo job. Con un timeout di
  sicurezza se la submit non arriva. Allora `commit` torna subito e la riesecuzione resta asincrona.
- Per verificare: `vctl burst` all'apertura di un'app e gli snapshot di SplashBoard (come per la scheda nera).


### K0g. Costo delle ioctl SUBMIT e WAIT_BO (2026-11-03, dopo 0117)
Con 0117 la GPU non è più il limite: scena Settings di `ca` a 950 MHz, job sull'hardware **24 us** in media, GPU
occupata l'1%, latenza di avvio 13-47 us (K0e ok). Il frame (oggi **18 ms**, era 28,5) è limitato dalla coda GPU del
driver, occupata ~77% del tempo; dopo aver tolto da userspace mmap/munmap (cache delle mappature in libdrm-xnu),
MMAP_BO e MADVISE (risposti senza kernel), il profilo della coda è: **SUBMIT 34%**, **WAIT_BO 23%**, il resto CPU.
~100 submit per frame (Panfrost: job vertex/tiler + fragment per pass, CA ~50 pass) -> ~60 us per SUBMIT.
WAIT_BO: Panfrost la chiama con timeout 0 a ogni riuso di un BO dalla sua cache, solo per sapere se è libero.
- Serve:
  1. `WAIT_BO` con `timeout_ns` già scaduto (o 0): percorso veloce senza gate né invalidazione lazy, solo la lettura
     di `busy->signalled` (la risposta è "occupato/libero"; l'invalidazione serve solo prima di una lettura CPU, che
     per i BO WC non c'è);
  2. `SUBMIT`: misurare dove vanno i ~60 us (copyin degli handle, per-BO: dipendenze implicite, `busy`, lazy
     invalidation; gate) e togliere il lavoro per BO che non serve (es. BO WC: niente manutenzione; dipendenza solo se
     `busy` non segnalato); un contatore in `gpu status` del tempo medio per selettore aiuterebbe;
  3. se possibile, un percorso IOConnect più leggero per questi due selettori (scalar method invece di struct,
     niente copia della struttura in uscita quando non serve).
- Per verificare: `VMG_CA_TIME=1 VMG_CA_SETTINGS=1 ca 61` (oggi ~18 ms), e il profilo `VMG_CA_PROFILE`.

### K0d. Tearing della copia nello scanout (2026-11-03, dopo 0114-0116)
K0c funziona: niente più frame a metà disegno. Restano però split orizzontali netti tra due frame completi durante le
animazioni (`vctl burst /tmp/b 24 30 open com.apple.Preferences`, 1-2 frame su ~8). `disp status`: scanout off,
layer OVL0_2L L0 = buffer LK 0x7bc10000, copie avg ~3,2 ms: AppleCLCD copia nel buffer che il pannello sta leggendo.
`disp scanout on` a runtime non basta ("surface not contiguous": CA alloca i framebuffer all'avvio).
- Serve, una delle due:
  1. doppio buffer del pannello: copiare in un secondo buffer 1080x2400 (es. la memoria di OVL0 L1 a 0x7c606000,
     oggi nera) e cambiare l'indirizzo del layer al vsync successivo alla fine della copia;
  2. `vivascanout=1` nell'immagine di boot (scanout diretto delle IOSurface, niente copia), se 0109 regge.
- Per verificare: `vctl burst` come sopra, nessun frame con una linea netta tra due frame diversi.

### K0e. Latenza tra job: ~0,28 ms per job, indipendente dal clock (2026-11-03, dopo 0114-0116)
Scena Settings di `ca` (`VMG_CA_TIME=1 VMG_CA_SETTINGS=1 ca 61`): 42 ms -> **28,5 ms** per frame con 0114-0115
(grazie!), ma identico a 300 e a 950 MHz fissi; 100 job per frame; profilo: tutti i thread userspace ~90% fermi.
Quindi ~0,28 ms per job sono la transizione IRQ -> completamento -> kick del job dipendente, non esecuzione.
- Serve: quando il job in testa alla coda di uno slot dipende solo dal job in esecuzione **sullo stesso slot** (caso
  tipico con K0: fragment dopo fragment), programmarlo subito nei registri `*_NEXT` (la GPU lo avvia da sola alla fine
  del corrente); per le dipendenze tra slot (fragment dopo il suo tiler) ridurre la latenza IRQ -> kick (kick
  direttamente dal filtro/handler dell'interrupt invece che dal workloop, se possibile). Un contatore del tempo medio
  IRQ->start in `gpu status` aiuterebbe a misurarlo.
- Per verificare: `ca` come sopra (oggi 28,5 ms; GPU pura stimata < 5 ms).

### K0c. AppleCLCD presenta frame non ancora finiti dalla GPU (2026-11-03, visto a schermo)
Durante le animazioni (es. apertura di un'app) a schermo compaiono frame a metà: tile neri, metà frame vecchio e metà
nuovo. Catturati dalla superficie di scanout con `vctl burst /tmp/b 24 40 open com.apple.Preferences` (confermato
dall'utente sul telefono). Causa: backboardd fa commit del command buffer e passa subito la IOSurface alla swap di
IOMobileFramebuffer, senza aspettare né "completed" né "scheduled". Su Apple è il kernel del display ad attendere le
scritture GPU in sospeso sulla superficie; `AppleCLCD::present()` (copia, 0056) e `AppleCLCD::scanout()` (0109)
invece leggono la superficie appena il timer vsync lo decide, anche con i job fragment ancora in esecuzione.
- Serve:
  1. in `VivaGPUAccelerator`: `bool surfaceIdle(uint32_t surfaceID)`, sotto il gate: per ogni BO importato
     (`kVivaBOSurface`) di quella IOSurface, in qualsiasi connessione, vero solo se `busy == NULL || busy->signalled`;
  2. in `AppleCLCD::present()` e in `scanout()`: per ogni layer abilitato, se la superficie non è idle **non copiarla e
     non puntarci lo scanout**: lasciare `fDirty = true` e riprovare al tick vsync dopo (niente attese nel timer);
  3. dopo la copia ricontrollare `surfaceIdle`: se nel frattempo è partito un job che scrive la stessa superficie
     (CA la riusa per il frame dopo), la copia può essere mista: rifarla al tick successivo.
- `busy` è il fence dell'ultimo job sul BO: è affidabile perché le submit di una connessione sono serializzate
  (libdrm-xnu oggi, K0 domani); con K0 in kernel vale anche tra processi.
- Per verificare: `vctl burst` come sopra, 3-4 volte: nessun frame con tile neri o metà vecchio/nuovo.
- Nota: con `sweetfb_hz` di default (10) lo schermo si aggiorna a 10 Hz anche quando la GPU fa di più; per la
  fluidità percepita conta quanto K0b.

### K0b. Latenza per job: è il collo di bottiglia del rendering (2026-11-03, misurato)
Scena "Impostazioni" del test `ca` (`VMG_CA_TIME=1 VMG_CA_SETTINGS=1 ca 61`, frame 360x640): **42 ms per frame
sia a 300 sia a 950 MHz**, ~100 job GPU per frame (CoreAnimation fa ~50 pass, quasi tutti offscreen 64x64 per
ombre/maschere; ogni pass = job vertex/tiler + job fragment). Profilo (`VMG_CA_PROFILE`): tutti i thread ~90% fermi
nel kernel; quindi ~0,4 ms fissi per job, 100 x 0,4 = 42 ms. `gpu status`: submit maintenance avg ~150 us e
**completion maintenance avg ~150 us, ~2,3 MB per job** (tutti i BO del job, non solo quelli che la CPU leggerà).
- Serve (in ordine di resa):
  1. togliere la manutenzione cache dal percorso critico del completamento: segnalare il fence subito e invalidare
     le cache CPU solo dei BO che la CPU poi mappa/legge (pigra, su `SYNC_BO`/mmap o su `WAIT_BO`), o solo dei BO
     scritti dalla GPU (render target), non di pool/shader/texture in sola lettura;
  2. lo stesso al submit: pulire solo i BO che la CPU ha scritto dall'ultima volta (dirty tracking per BO);
  3. accodare il job successivo già pronto in `JS_HEAD_NEXT`/`JS_COMMAND_NEXT` (niente bolla IRQ->kick tra job
     dipendenti dello stesso slot: le dipendenze di K0 sono quasi sempre "il job prima").
- Per verificare: `ca` come sopra (oggi 42 ms) e `cmd gpu status` (completion maintenance).

### K0. Sync implicita sui BO in SUBMIT (come `panfrost_job.c` su Linux) — 2026-11-03
`VivaGPUUserClient::submit` costruisce le dipendenze del job **solo dagli `in_syncs`**. Linux fa attendere ogni job
l'ultimo job su **ognuno dei BO** che elenca (tutti trattati come scritti: `DMA_RESV_USAGE_WRITE`), e Mesa ci conta:
il job vertex/tiler (slot 1) e il fragment (slot 0) di un batch sono **due submit senza in-sync tra loro**
(`jm_submit_batch`: "since there will be an implicit dep between them"), e tutti i batch condividono il tiler heap.
Da noi il fragment partiva mentre il tiler scriveva ancora le polygon list (o il tiler del batch dopo riscriveva
l'heap): mezzi triangoli, MMU fault a indirizzi garbage in slot 0, timeout in backboardd. Anche `WAIT_BO` ne soffre:
`bo->busy` è il fence dell'ultimo job, che su un altro slot può finire prima di un job precedente sullo stesso BO.
- Serve: in `VivaGPUAccelerator::submit`, prima di `bo->busy = fence`, se `bo->busy` non è segnalato aggiungerlo a
  `job->deps`. Con la catena ogni `busy` finisce dopo tutti i job precedenti sul BO, quindi `WAIT_BO` torna corretto.
  Vale anche tra connessioni/processi (IOSurface condivise).
- Intanto: `libdrm-xnu` serializza tutte le submit di una connessione con un syncobj (`submit_ordered`,
  `VGPU_NO_IMPLICIT_SYNC=1` lo spegne). Con la patch kernel lo tolgo (o lo lascio: diventa ridondante).

### K1. Tracciare cosa userspace chiede a `VivaGPUAccelerator` che non gestiamo
QuartzCore fa soft-link di `IOGPU.framework` per `IOGPUDeviceCreate` e `IOGPUDeviceSetDisplayParams`. Lo fa sul
servizio `IOAcceleratorES` che trova, cioè il nostro. `IOGPUDeviceCreate` apre un user client di tipo diverso da
`VGPU_CLIENT_TYPE` (quello di `IOGPUDeviceUserClient`) e ci chiama dei selettori.
- Serve: in `newUserClient` loggare **ogni tipo sconosciuto** (processo, tipo) e accettarlo con un user client
  "IOGPU minimo" che logga **ogni selettore** (numero, dimensioni in/out, primi byte) e risponde
  `kIOReturnUnsupported`. Se un selettore si rivela necessario, lo implementiamo dopo aver visto cosa chiede.
- Allo stesso modo: loggare le letture di proprietà del servizio fatte da `backboardd`, se la traccia IOKit della
  0049 le vede (`IORegistryEntryCreateCFProperty`). Metal e QuartzCore possono leggere chiavi che oggi non
  pubblichiamo (`IOGLESBundleName`, `MetalStatisticsName`, `PerformanceStatistics`...).

### K2. Formato dei framebuffer: niente colore esteso (XR10) per ora
L'identità è iPhone X (display P3). Se il display risulta wide-color, CoreAnimation compone in `BGR10_XR` /
`BGRA10_XR` (IOSurface `w30r` / `w40a`). Il driver li gestirà (decodifica e codifica affine: in lavorazione), ma `AppleCLCD`
copia il framebuffer assumendo `BGRA` 8 bit: lo schermo diventerebbe spazzatura.
- Serve, una delle due:
  - (a) `AppleCLCD` e i metadati del display (IOMFB, `/product`, MobileGestalt) dicono **sRGB, non P3**, così CA
    usa `BGRA8`;
  - (b) `AppleCLCD` converte `w30r`/`w40a` in BGRA nella copia.
- Per verificare: log del formato (fourcc) di ogni IOSurface passata a `SwapSetLayer`. Quel log serve comunque.

### K3. Costo della manutenzione delle cache sulle IOSurface
"Not yet: IOSurface cache flush cost (whole surface per job)". Con CoreAnimation sulla GPU ogni job tocca il
framebuffer (1125×2436×4 = 11 MB) e diverse surface di layer: pulire e invalidare tutte le BO del job, sempre,
costa più del rendering.
- Serve:
  - fare manutenzione **solo sulle BO che hanno una mappatura CPU** (molte surface di CA non ne hanno, o non la
    usano tra un frame e l'altro);
  - oppure tenere traccia degli intervalli scritti dalla CPU;
  - e, appena possibile, la **correzione dell'aperture per la RAM bassa**, che permetterebbe di nuovo mappature
    write-combined/uncached e niente pulizia delle BO.
- Per verificare: tempo medio del submit nel `gpu status` (o un contatore).

### K4. Velocità della GPU: OPP fissa a 300 MHz
Va bene per i test, ma per comporre l'interfaccia di iOS a 60 Hz il G57 MC2 serve più su. Il massimo nella
tabella del `gpufreq` di viva-r-oss è intorno a 950 MHz.
- Serve: una OPP più alta selezionabile con un boot-arg (per esempio `vivagpufreq=`), con le tensioni della
  tabella vendor. Più avanti, DVFS.

### K5. Fault MMU dell'userspace: niente reset completo
"A user MMU fault always costs a full reset" (316 ms). In G7 un bug di uno shader o del driver diventa un blocco
visibile di un terzo di secondo per ogni fault.
- Serve: fault → disattivare solo l'AS colpito e far fallire la catena, senza reset quando la GPU non è bloccata;
  reset solo al timeout.

## Importanti (subito dopo)

### K6. IOSurface: valori e lock come Metal se li aspetta
L'AGX importa `IOSurfaceCopyValue`, `IOSurfaceAlignProperty` e `IOSurfaceLock`. In `SweetSurface` i valori
vengono scartati (0046: `IOSurfaceCopyValue` restituisce sempre NULL).
- Serve: `SetValue`/`CopyValue`/`RemoveValue` veri (l'ABI è nelle NOTES del 2026-10-17). CoreAnimation e
  CoreVideo li usano per colorimetria e metadati.

### K7. Esecuzione di programmi e log dal Mac (`vivad`, fase G0 del piano)
Oggi non posso eseguire `vmprobe`, `test_vgpu` e `compute` sul telefono.
- Serve: un modo per lanciare un eseguibile e leggerne stdout/stderr dal link USB. Va bene anche un LaunchDaemon
  che esegue `/private/var/root/viva-tests/*` al boot con l'uscita su `/dev/console`, purché la console arrivi al
  link.
- Ancora meglio: `push FILE` per aggiornare il bundle senza riflashare 16 GB.

### K8. Memoria GPU per processo
Con CoreAnimation le BO crescono (surface, cache di BO di Mesa).
- Serve: un contatore per processo e un limite configurabile, visibili nel `gpu status`. In caso di memoria
  esaurita, rispondere `kIOReturnNoMemory` al `CREATE_BO`, mai un panic.

### K9. Scanout diretto delle IOSurface (G8)
Con la GPU che compone, la copia CPU di `AppleCLCD` (11 MB per frame) diventa il collo di bottiglia.
- Serve: riprogrammare il layer dell'OVL di MediaTek per leggere l'IOSurface presentata (indirizzo, pitch,
  ritaglio 1125×2436 → 1080×2400), applicato al vsync tramite il mutex del display.
- Ripiego: copia fatta dalla GPU, con un job di blit in kernel.

## Già allineato (per conferma)
- Coerenza: BO cacheabili, manutenzione in kernel attorno ai job, `SELECTED_COHERENCY = NONE`. Lato userspace
  non serve altro.
- IOSurface con piani fuori dal bordo di pagina: offset GPU = primo byte del piano, mappatura CPU dalla pagina.
  `libdrm-xnu` somma lo scarto (`gpu` commit "IOSurface planes off a page boundary").
- `IMPORT_USERPTR` (`newBufferWithBytesNoCopy`): lato kernel pronto. Lato Mesa manca il `resource_from_handle` dei
  buffer: oggi questi buffer vengono copiati, ed è sufficiente per CoreAnimation.

## Risposte del kernel (2026-11-03, patch 0101-0109 di `fork/`, da provare sul telefono)
Dettagli in `fork/VIVA.md`. Boot con `vivagpu=2`.

| Richiesta | Stato | Come verificarla |
|---|---|---|
| K1 | Ogni tipo di user client sconosciuto riceve un client "sonda": ogni selettore, trap, tipo di memoria e porta di notifica viene loggato e risponde `kIOReturnUnsupported` (`vivagpuprobe=0` per rifiutarli come prima). Anche le letture delle proprietà del servizio vengono loggate, una volta per coppia (processo, chiave), con found/MISSING. | `gpu probe`, righe `VIVA GPU: probe ...` / `reads property` |
| K2 | (b) fatto: AppleCLCD converte `w30r`, `w40a`/`w40m` e `l10r` in BGRA8 durante la copia. (a): l'ADT di viva dichiara `artwork-display-gamut = sRGB`; MobileGestalt potrebbe però avere il valore in cache. | log `SWEET FB: layer N format ...` a ogni cambio di formato |
| K3 | Le BO normali hanno manutenzione solo dopo la prima mappatura CPU. Le IOSurface sono "pigre": vengono pulite solo dopo un lock in scrittura della CPU e invalidate al lock successivo o prima della copia del display. **Contratto: l'accesso CPU a una IOSurface usata dalla GPU deve stare dentro IOSurfaceLock/Unlock** (oppure si mappa la BO con il client vgpu, che la rende "eager"). Con `vivagpucache=0` si torna al comportamento vecchio. L'aperture per la RAM bassa NON è corretta. | `gpu status`: tempo medio del submit, tempo di manutenzione, KiB per submit |
| K4 | Tabella vendor (segmento 0, letto dal devinfo). `vivagpufreq=MHz` (default 300, massimo 950), `vivagpumv` (margine, default 50 mV, limite a 0,9 V). A runtime: `gpu freq MHz`. DVFS non c'è ancora. | `gpu freq`, `gpu status` |
| K5 | Un fault MMU disattiva solo l'AS colpito e fa fallire la catena, senza reset. Il reset resta solo per i bus fault "veri" e al timeout. Dopo un fault, le catene fragment hanno un timeout di 500 ms finché una non termina bene. | `gpu selftest fault` → "no reset", poi `gpu selftest` |
| K6 | SetValue/CopyValue/RemoveValue/SetValues e gli attachment bulk, con l'ABI verificato sul disassemblato di 20H392. | — |
| K7 | Comandi del link: `push`, `pull`, `run`. Il demone `vivad` (`fork/tools/vivad`, compilato dalla CI) esegue i programmi e rimanda lo stdout. All'avvio esegue `/private/var/root/viva-tests/autorun/*`. Installazione senza riflashare: si fa `pull` di launchd.plist, poi `tools/viva-launchd-add.py`, poi `push` di plist e vivad, poi reboot. | `viva-link.py run test_vgpu` |
| K8 | Contatore per processo e limiti `vivagpumem` / `vivagpumemtotal` (MiB). Oltre il limite: `kIOReturnNoMemory`. | `gpu status` |
| K9 | Scanout diretto di una sola superficie a schermo intero, BGRA e contigua: cambiano solo ADDR e PITCH del layer OVL di LK. Spento di default (`vivascanout=1` o `disp scanout on`). Non è ancora sincronizzato al vblank. Prima va lanciato `disp regs` (solo lettura). | `disp`, `disp regs` |

## Risposte del kernel (2026-11-03, patch 0114-0115 di `fork/`, da provare sul telefono)
Analisi completa e verifiche in `docs/ANALISI-KERNEL-RENDERING.md`.

| Richiesta | Stato | Come verificarla |
|---|---|---|
| K0 | In `submit` ogni job aspetta il fence dell'ultimo job su ognuno dei suoi BO (tutti trattati come scritti). Per le IOSurface vale in qualunque connessione: il fence è anche sulla superficie. `WAIT_BO` su una IOSurface attende anche i job degli altri processi. | `gpu status`: `implicit dependencies` |
| K0b.1 | Nessuna manutenzione nell'IRQ di completamento. I BO mantenuti dalla CPU vanno in una lista e vengono invalidati una volta sola quando userspace attende (`WAIT_BO`, attesa su syncobj). I BO eseguibili (shader) non vengono mai invalidati. `vivagpulazy=0` = come prima. | `gpu status`: `lazy invalidation` |
| K0b.2 | I BO senza `VGPU_BO_WB_MMAP` sono **write-combined**, come Panfrost su Linux con GPU non coerente (Mesa con DRM 1.5 se lo aspetta). Niente da pulire al submit né da invalidare dopo. Dipende dalla 0112: se all'avvio va in panic in `pmap`, usare `vivagpuwc=0`. | `gpu status`: submit maintenance ~0 µs |
| K0b.3 | Non fatto: con il tiler heap condiviso le dipendenze alternano slot 1 e slot 0, quindi `JS_HEAD_NEXT` non accorcia nulla. Al suo posto: flush reduction e DVFS (0115). | — |
| K0c | `viva_gpu_surface_idle` (fence dell'ultimo job sulla superficie, in qualunque connessione). `AppleCLCD` mette in coda gli swap in ordine e a ogni tick mostra il più recente con le superfici finite. Se nessuno è pronto riprova al tick dopo, senza attese nel timer. Se durante la copia arriva un job nuovo, rifà la copia. Dopo 12 tick (`sweetfb_gpuwait`) mostra comunque l'ultimo frame; 0 disattiva l'attesa. Anche `IOSurfaceLock` aspetta la GPU (AvoidSync → `kIOReturnCannotLock`). | `vctl burst`; `disp`: `GPU sync (K0c)` |
| Nota `sweetfb_hz` | Default ora adattivo: copie entro il 25% di una CPU (`sweetfb_duty`), fino a 60 Hz. `sweetfb_hz=N` lo fissa. | `disp`: copies, avg µs |

## Risposte del kernel (2026-11-03, patch 0117 di `fork/`, da provare sul telefono)
Dettagli in `fork/VIVA.md`.

| Richiesta | Stato | Come verificarla |
|---|---|---|
| K0d | (1) fatto: doppio buffer del pannello. La copia va nel buffer che il pannello non sta leggendo: quello di LK (0x7bc10000) o il successivo nella memoria di LK (0x7c606000, quello che hai visto su OVL0 L1; prima di usarlo il kernel controlla che nessun layer abilitato lo legga). Il layer di LK passa all'altro buffer al frame end successivo, cioè quando sale il bit 1 di INTSTA dell'OVL (FME_CPL), letto in polling e calibrato al primo swap. Il timer vsync è agganciato in fase al pannello: scatta 1 ms (`sweetfb_lead`) prima del frame end previsto. Anche lo scanout (`vivascanout=1`) cambia indirizzo solo al frame end. Restano sul buffer a schermo come prima: frame che non coprono tutto il pannello, la surface di default e la console del kernel non silenziata. `sweetfb_flip=0` o `disp flip off` = comportamento vecchio. | `disp`: riga `double buffer (K0d) on`, periodo del frame (~16667 us), switch / missed / unsure. Se dice `off: no frame-end status from the OVL`, manda l'output di `disp regs` (ora include inten/intsta/addcon_dbg). Poi `vctl burst` come prima. |
| K0e | Kick dal filtro dell'IRQ dei job (contesto di interrupt primario). Dopo ogni kick, la testa della coda di ogni slot che aspetta solo job già sull'hardware viene "armata" (AS legato, JS_CONFIG pronto). Il filtro la avvia appena quei job segnalano done, senza aspettare che il thread del workloop si svegli. Vale sia tra slot (fragment dopo il suo tiler, vertex dopo il fragment per l'heap) sia sullo stesso slot. `JS_*_NEXT` non usato: il filtro riavvia lo slot in pochi µs, senza l'ambiguità "due job, un solo bit done". `vivagpufastkick=0` o `gpu fastkick off` = percorso vecchio. | `gpu lat` (anche in `gpu status`). Dopo `gpu lat reset` e un run di `ca`: % di tempo GPU occupata / job in coda ma nessuno in esecuzione / niente in coda, tempo medio per job sull'hardware, latenza di avvio (pronto al submit / dopo una dipendenza via workloop / via filtro), latenza IRQ → handler. Se "niente in coda" domina, il tempo è in userspace (submit/attese), non nel kick. |

## Risposte del kernel (2026-11-03, patch 0118 di `fork/`, da provare sul telefono)
Analisi in `docs/ANALISI-KERNEL-RENDERING.md`, sezione "Seconda analisi". Dettagli in `fork/VIVA.md`.

| Richiesta | Stato | Come verificarla |
|---|---|---|
| K0g (causa) | Trovata nel codice: ogni completamento di job, ogni SUBMIT con `out_sync` e ogni cambio di syncobj svegliava **tutti** i thread in attesa di tutti i processi, che riprendevano il gate uno per uno; le SUBMIT aspettavano in coda dietro di loro. Ora chi aspetta un fence dorme su quel fence; l'evento comune resta solo per attese ANY su più syncobj o su un syncobj senza fence. Semantica invariata. | `cmd gpu calls reset`, run di `ca`, `cmd gpu calls`: riga `waits` (risvegli a vuoto, mirati, generici) |
| K0g.1 | WAIT_BO con timeout scaduto: dentro il gate fa solo il controllo del fence (l'invalidazione pigra riguarda solo i BO `WB_MMAP` in lista, non i WC). Il costo che resta è il messaggio Mach + il gate, che ora non è più conteso dai risvegli: con la trap (sotto) resta ~solo la syscall. | `gpu calls`: `wait_bo` avg e gate avg |
| K0g.2 | `gpu calls` per selettore: chiamate (di cui via trap), tempo medio/massimo nel kernel (da `externalMethod` / trap all'uscita), attesa media/massima del gate. Il vostro tempo per chiamata meno questo = costo del messaggio Mach. | `cmd gpu calls` |
| K0g.3 | Fatto: **trap**. `IOConnectTrap2(conn, 0 /* VGPU_TRAP_CALL */, selector, (uintptr_t)&args)` fa esattamente quello che fa `IOConnectCallStructMethod(conn, selector, &args, size, &args, &size)` (copyin della struttura dalla vostra memoria, stessa dispatch, copyout dei campi in uscita), senza messaggio Mach. Vale per ogni selettore; ha senso per SUBMIT, WAIT_BO, SYNCOBJ_WAIT. Disponibile se `GET_VERSION` dà `minor >= 1` (il kernel di 0118 dà 1; il vostro controllo è solo su `major`, quindi compatibile). Errori: lo stesso `kIOReturn*` del metodo. | In `vgpu_iokit.c`: `iokit_ioctl` usa la trap se `minor >= 1`; poi `gpu calls` mostra la colonna trap = chiamate |
| Display (nuovo) | Presentazione anticipata: uno swap finito viene copiato appena arriva o appena termina il job GPU sulla sua IOSurface, non al tick vsync; il cambio di buffer avviene al frame end successivo. Un frame di latenza in meno (non più fps). `sweetfb_early=0` / `disp early off` = come 0117. | `cmd disp`: riga `early present` |
| CPU (nuovo) | `gpu clocks` legge le PLL di A55/A76/CCI/MFG (solo lettura). In questo port le frequenze CPU restano quelle di LK: se sono basse, sono il prossimo limite (vedi analisi). | `cmd gpu clocks` |

Nota per `vgpu_iokit.c` (proposta, non l'ho toccato):
```c
// dopo GET_VERSION: c->trap = v.minor >= 1;
static int iokit_ioctl(void *conn, enum vgpu_selector sel, void *arg, size_t size)
{
    IOKitConn *c = conn;
    if (c->trap) return errno_for(IOConnectTrap2(c->conn, 0 /* VGPU_TRAP_CALL */, (uintptr_t)sel, (uintptr_t)arg));
    size_t out = size;
    return errno_for(IOConnectCallStructMethod(c->conn, sel, arg, size, arg, &out));
}
```

## Risposte del kernel (2026-11-04, patch 0119 di `fork/`, da provare sul telefono; UAPI minor 2)
Strutture e commenti in `viva_gpu_uapi.h` della patch (copiate qui sotto l'essenziale). Tutto vale anche via trap
(`IOConnectTrap2(conn, 0, selector, &args)`, 0118).

| Richiesta | Stato | Note per userspace |
|---|---|---|
| K0h.1 | `VGPU_SEL_SUBMIT_BATCH` (21): `struct vgpu_submit_batch { u64 submits; u32 count, stride; u32 done, pad; }`, count <= 64, stride = `sizeof(struct vgpu_submit)`. In ordine, sotto un solo gate, identico a N SUBMIT (stesse dipendenze implicite, out_sync, ecc.). Tutti gli array vengono letti prima: un puntatore sbagliato fa fallire tutto senza accodare nulla; altrimenti si ferma al primo che fallisce, `done` = quanti accodati, la chiamata ritorna l'errore di quello. | Va mandato prima di ogni attesa, mappatura CPU, export di fence o promessa (K0i). |
| K0h.2 | `vgpu_submit.pad` diventa `seq` (out): numero del job nella connessione (anche negli elementi del batch). Pagina: `IOConnectMapMemory64(conn, 0x10000 /* VGPU_MAP_COMPLETION */, ...)`, sola lettura, `struct vgpu_completion { u32 completed, submitted; u64 completed64, submitted64; }`. **Soglia**: ogni job con seq <= completed è finito (bene o male), come direbbe il suo fence. Confronto: `(int32_t)(completed - seq) >= 0`. Aggiornata nel kernel prima che il fence segnali. | Non copre i job di **altri processi** sulle IOSurface condivise: per i BO importati da IOSurface resta WAIT_BO. Un job fallito conta come finito. |
| K0i | `VGPU_SEL_SURFACE_PROMISE` (22): `struct vgpu_surface_promise { u64 surface_ids; u32 count, syncobj; u32 timeout_ms, pad; }`, count <= 16. Il kernel mette un fence nuovo non segnalato in `syncobj` e lo rende l'ultimo fence delle superfici: lo aspettano IOSurfaceLock, il display (K0c), WAIT_BO e i job di **altri** processi. I job e le WAIT_BO **della vostra connessione** su quelle superfici non lo aspettano (aspettano quello che c'era prima): niente auto-deadlock durante la riesecuzione. | **Differenza dalla vostra proposta**: la risoluzione non è automatica alla prima SUBMIT con quell'out_sync, perché Panfrost usa un solo syncobj (`ctx->syncobj`) come out_sync di ogni submit: la promessa si chiuderebbe al primo job. Va fatta così: syncobj dedicato per la promessa; dopo l'ultima submit della riesecuzione `SYNCOBJ_TRANSFER(src = ctx->syncobj, dst = syncobj della promessa)` (oppure usare quel syncobj come out_sync dell'ultima submit). Allora la promessa segnala quando segnala quel fence. RESET/SIGNAL/DESTROY del syncobj o chiusura della connessione = segnala subito. Timeout (0 = 1000 ms, max 5000): segnala con errore e un log `surface promise not resolved in time`. |

Avvertenze K0i:
- Un `IOSurfaceLock` fatto **dal vostro stesso processo** su una superficie promessa aspetta la promessa (il kernel
  non sa chi chiama). Non fatelo sul thread che deve risolverla, o aspetta fino al timeout.
- Se due processi scrivono la stessa superficie mentre c'è una promessa, i job dell'altro la aspettano ma non la
  sostituiscono come ultimo fence: chi legge dopo la risoluzione potrebbe non aspettare il job dell'altro. Per CA (un
  solo scrittore per superficie) non succede.
- Contatori: `cmd gpu calls` (righe `submit_batch`, `surf_promise` e `surface promises: made, pending, timed out`).
