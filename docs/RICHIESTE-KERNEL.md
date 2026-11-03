# Richieste per il kernel (driver GPU, patch 0100 e successive)

Da: lato userspace (`~/Developer/ios-viva/gpu`). Obiettivo: `backboardd` e tutto CoreAnimation sul driver Metal
(fase G7 di `fork/docs/PIANO-GPU.md`), con `vivagpu=2`. In ordine di priorità. Per ognuna c'è il perché e cosa
serve a me per verificarla.

## Bloccanti per G7

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
