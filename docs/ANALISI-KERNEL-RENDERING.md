# Analisi di ottimizzazione del rendering: solo kernel (2026-11-03)

Riguarda il percorso kernel di un frame di CoreAnimation su Metal → Mesa Panfrost → `VivaGPUUserClient` →
`VivaGPUAccelerator` (Mali-G57) → `AppleCLCD` (pannello). Base: patch 0114 (K0, K0b, K0c). Le ottimizzazioni
scelte sono nella patch 0115. Le misure sono quelle di K0b. Le stime sono segnate come tali.

## Dove va il tempo (prima di 0114)

Scena "Impostazioni" del test `ca`: 42 ms per frame, sia a 300 sia a 950 MHz. Circa 100 job per frame, cioè
~50 pass, ognuno con un job vertex/tiler (slot 1) e un job fragment (slot 0). Circa 0,4 ms di costo fisso per job.

| # | Voce, per job | Prima | Dopo 0114/0115 | Note |
|---|---|---|---|---|
| 1 | Manutenzione cache CPU al submit (`dc civac` su ~2,3 MB di BO) | ~150 µs (misura) | **0** per i BO normali | 0114: BO write-combined come su Linux |
| 2 | Manutenzione cache CPU al completamento (nell'IRQ, prima del fence) | ~150 µs (misura) | **0** nell'IRQ | 0114: WC + invalidazione pigra alle attese |
| 3 | Syscall di submit: copyin, gate, OSArray, retain dei BO | ~10-30 µs (stima) | uguale | vedi "Non fatto" |
| 4 | Bolla IRQ → thread del work loop → `kick()` del job dopo | ~20-50 µs (stima) | uguale | i job sono in catena (vedi sotto) |
| 5 | Flush L2 della GPU a inizio job (clean+invalidate) | sempre | **saltato** se c'è già stato un flush dopo il submit | 0115: flush reduction |
| 6 | Esecuzione sulla GPU | 300 MHz fissi | **DVFS** 300..950 MHz | 0115: governor sul carico |

Frame (display):

| # | Voce | Prima | Dopo | Note |
|---|---|---|---|---|
| 7 | Frequenza di aggiornamento del pannello | 10 Hz fissi (`sweetfb_hz`) | **adattiva**: copie entro il 25% di una CPU | 0115 |
| 8 | Frame a metà (tile neri, metà vecchio/nuovo) | sì | **no**: viene mostrato solo un frame finito | 0114 (K0c) |
| 9 | Costo della copia (civac 11 MB + memcpy 10 MB verso memoria WC) | non misurato | misurato in `disp` (media µs) | la soluzione vera è lo scanout (sotto) |

Con 1+2 tolti, il costo fisso per job scende da ~0,4 ms a ~0,05-0,1 ms (stima: voci 3+4). Il frame da 42 ms
dovrebbe scendere verso 5-10 ms + tempo GPU. Da quel momento il tempo GPU conta, e il DVFS serve.

## Perché i job sono in catena (e perché `JS_HEAD_NEXT` non serve qui)

Con la sync implicita (K0) ogni job aspetta l'ultimo job su ognuno dei suoi BO, come su Linux. Mesa mette il
tiler heap in tutti i batch, quindi l'ordine è V1 → F1 → V2 → F2 → … e alterna sempre slot 1 e slot 0. Accodare il
job successivo in `JS_HEAD_NEXT` (K0b.3) aiuta solo quando la dipendenza è sullo **stesso** slot. Qui la dipendenza
è sempre sull'altro slot, quindi il guadagno sarebbe zero, mentre la gestione errori di due job per slot è
delicata (fault del primo con il secondo già partito). Non l'ho fatto. Per CA la bolla da accorciare è la 4.

## Fatto in 0115

- **Flush reduction** (`vivagpuflushid=1`): `JS_FLUSH_ID_NEXT` = `GPU_LATEST_FLUSH` letto al submit, come
  `panfrost_job.c` su ogni GPU con FLUSH_REDUCTION (tutte le Valhall). Ogni job finisce con un flush, quindi con i
  job uno dietro l'altro il flush iniziale non si fa quasi mai. È corretto perché qualunque riga dell'L2 presente
  all'avvio è stata caricata dopo l'ultimo flush, e quindi dopo le scritture CPU del submit.
- **DVFS** (`vivagpudvfs=1`, `vivagpufreq` = minimo, `vivagpufreqmax` = massimo, default 300..950): ogni 50 ms
  misura la frazione di tempo con una catena sulla GPU. Sopra l'85% passa subito al massimo. Altrimenti, dopo
  almeno 200 ms dall'ultimo aumento, scende all'OPP più lenta che lo terrebbe al 70%. Usa `setOpp()`, già provata
  a caldo con `gpu freq`. Inattivo al minimo: il timer si ferma. Link: `gpu dvfs [on|off]`. Se imposti `gpu freq
  MHz`, cambi il minimo.
- **Refresh adattivo del pannello**: senza `sweetfb_hz` una copia parte appena il "budget" lo permette.
  `sweetfb_duty` (default 25) è la percentuale massima di una CPU usata dalle copie: una copia da 4 ms permette
  60 Hz, una da 8 ms 30 Hz. `sweetfb_hz=N` torna al comportamento fisso. `disp` mostra numero e tempo medio delle
  copie.

## Non fatto (in ordine di resa attesa), con il motivo

1. **Scanout diretto sincronizzato al vblank** (0109 esiste, spento, mai provato): niente copia da 10 MB per
   frame. Mancano: provare `disp regs` (porte larb/M4U) e l'interrupt di frame-done di RDMA/DSI per cambiare
   l'indirizzo dell'OVL a vblank. Va fatto sul telefono, un passo alla volta.
2. **Latenza IRQ → kick (voce 4)**: prima misurarla. Proposta: timestamp in `jobInterrupt` e in `startJob`, istogramma
   in `gpu status`. Se è grande, si può far partire il job dopo direttamente dal filtro dell'interrupt
   (`IOFilterInterruptEventSource`), ma servirebbe un lock a spin al posto del gate sul percorso dei job: è un
   cambiamento grosso, da fare solo con i numeri in mano.
3. **Wakeup mirati**: oggi ogni completamento sveglia tutti i thread in attesa di qualunque fence (`fFenceEvent`).
   Con più processi in attesa ognuno si risveglia ~100 volte per frame per niente. Basta dormire sull'indirizzo
   del fence (e un evento comune solo per le attese "any" sui syncobj).
4. **Copia del display su un A76**: memcpy più veloce (stima ×1,5-2), ma serve sapere se il core è online prima
   di legarci un thread (con `cpus=6` o con un A76 che non parte il thread resterebbe fermo per sempre).
5. **Blit sulla GPU al posto della copia CPU** (ripiego di K9 se lo scanout non va): un job del kernel che copia
   la superficie nel pannello.
6. **Submit più leggero (voce 3)**: cache della lista di BO tra il submit vertex/tiler e il fragment dello stesso
   batch, che sono identiche. Pochi µs: conviene dopo la 2.

## Cosa cambia per lo userspace (`gpu/`)

- K0 è nel kernel: `submit_ordered` di `libdrm-xnu` diventa ridondante (`VGPU_NO_IMPLICIT_SYNC=1` per provare senza).
- K0c è nel kernel: il workaround nel driver (command buffer che scrivono una IOSurface segnalano "scheduled" solo
  a GPU finita) non serve più. Si può togliere dopo aver provato 0114 con `vctl burst`.
- Contratto cache, uguale a Linux con DRM 1.5: i BO senza `VGPU_BO_WB_MMAP` sono **write-combined**. La CPU li
  scrive senza manutenzione, ma leggerli è lento: per letture grosse dalla CPU conviene un BO con
  `VGPU_BO_WB_MMAP`. Per quei BO, e per la memoria importata con `IMPORT_USERPTR`, il kernel invalida le cache
  CPU quando userspace attende (`WAIT_BO`, attesa su syncobj), non dopo ogni job. Prima di leggere bisogna
  attendere, come già fa Mesa (`panfrost_bo_wait`) e come fa Metal (`waitUntilCompleted`).
- `IOSurfaceLock` ora aspetta i job GPU pendenti sulla superficie (con `kIOSurfaceLockAvoidSync` fallisce con
  `kIOReturnCannotLock`), come su Apple.

## Come verificarlo

| Cosa | Comando | Atteso |
|---|---|---|
| K0c | `vctl burst /tmp/b 24 40 open com.apple.Preferences`, 3-4 volte | nessun frame con tile neri o metà vecchio/nuovo |
| K0c, contatori | `cmd disp` | `GPU sync (K0c)`: vsync attesi > 0, "shown anyway" ~0 |
| K0b | `VMG_CA_TIME=1 VMG_CA_SETTINGS=1 ca 61`, poi `cmd gpu status` | ms/frame molto sotto 42; submit maintenance ~0; `lazy invalidation` con poche attese |
| K0 | `cmd gpu status` | `implicit dependencies` > 0; niente MMU fault in slot 0 |
| DVFS | `cmd gpu dvfs` durante l'animazione e dopo | sale fino a 950 sotto carico, torna a 300 da fermo |
| Fallback | boot-arg `vivagpuwc=0`, `vivagpulazy=0`, `vivagpuflushid=0`, `vivagpudvfs=0`, `sweetfb_gpuwait=0`, `sweetfb_hz=10` | ognuno riporta al comportamento di prima |

---

# Seconda analisi (2026-11-03 sera, dopo 0117): perché le animazioni sono ancora lente, solo kernel

Dati di partenza (misure userspace, `FINDINGS-2026-11-03.md`): scena Settings di `ca` 18 ms/frame, GPU occupata
~1%, job sull'hardware ~24 µs, latenza di avvio 13-47 µs. La GPU e il kick non sono più il limite. Il tempo è nelle
ioctl: **SUBMIT ~60 µs l'una** (~100 per frame) e **WAIT_BO** (Panfrost la chiama con timeout 0 a ogni riuso di un BO).

## Cosa costa una ioctl oggi (lettura del codice di 0117)

| Pezzo | Stima | Note |
|---|---|---|
| Messaggio Mach (`IOConnectCallStructMethod`: MIG, lookup delle porte, copia richiesta + risposta) | ~8-15 µs su A55 (stima) | uguale per ogni selettore |
| Gate del driver: attesa del lock | da 0 a decine di µs | **qui c'è il problema, sotto** |
| Lavoro dentro il gate di SUBMIT (2 OSArray, fence, job, per BO: retain, dipendenza implicita) | ~5-10 µs (stima) | lineare nei BO del batch |
| WAIT_BO con timeout 0, dentro il gate | ~1 µs | |

**Il problema principale: un solo evento di attesa per tutto il sistema.** Ogni thread che aspetta la GPU
(WAIT_BO con timeout, attese sui syncobj, `IOSurfaceLock`, in qualunque processo) dormiva su `fFenceEvent`. Ogni
completamento di job, ogni SUBMIT con `out_sync` (cioè tutte quelle di Panfrost) e ogni cambio di syncobj facevano
`commandWakeup(&fFenceEvent)`: **tutti** i thread in attesa si svegliavano, riprendevano il gate uno alla volta,
trovavano che il loro fence non era cambiato e tornavano a dormire. Con ~100 job e ~100 submit per frame, e diversi
thread in attesa (backboardd, SpringBoard, l'app, il test), sono migliaia di risvegli inutili al secondo, tutti
serializzati sullo stesso gate: la SUBMIT del thread che lavora davvero aspetta in coda dietro di loro. È coerente
con quello che misuravate: thread fermi nel kernel, SUBMIT lenta anche se dentro fa poco.

## Fatto in 0118

1. **Risvegli mirati.** Chi aspetta un fence preciso (WAIT_BO, syncobj wait con un handle o WAIT_ALL, IOSurfaceLock,
   K0c) dorme su quel fence. Il completamento di un job sveglia solo chi aspetta quel job. L'evento comune resta solo
   per le attese ANY su più syncobj e per un syncobj ancora senza fence (WAIT_FOR_SUBMIT), e viene svegliato solo se
   qualcuno ci dorme. Quando il fence di un syncobj viene sostituito (submit, reset, signal, transfer, destroy), chi
   dormiva sul vecchio viene svegliato e ricontrolla, come prima: la semantica non cambia.
2. **Percorso veloce senza messaggio Mach** (K0g.3): `IOConnectTrap2(conn, VGPU_TRAP_CALL /*0*/, selector, &args)`
   fa la stessa cosa del metodo struct (il kernel legge la struttura con copyin e la riscrive con copyout), per
   qualunque selettore. UAPI minor = 1. **Da adottare in userspace** (vedi RICHIESTE-KERNEL, risposta K0g).
3. **Misure** (K0g.2): `gpu calls` per selettore: numero di chiamate (quante via trap), tempo medio/massimo nel
   kernel, attesa media/massima del gate; numero di attese, risvegli "a vuoto", risvegli mirati e generici.
   `gpu calls reset` azzera. Il tempo misurato da userspace meno quello del kernel = costo del messaggio Mach.
4. **Presentazione anticipata del frame** (`sweetfb_early=1`, `disp early on|off`): finora un frame finito veniva
   copiato solo al tick vsync, 1 ms prima del frame end; la copia (~3 ms) finiva dopo, quindi il cambio di buffer
   slittava al frame end successivo: ~2 frame dal commit allo schermo. Ora la copia parte appena arriva lo swap o
   appena finisce un job GPU che usa IOSurface (se il frame è pronto e il budget `sweetfb_duty` lo permette) e il
   cambio avviene al primo frame end utile: **un frame di latenza in meno**. Non aumenta gli fps, migliora la
   risposta al tocco.
5. **`gpu clocks`** (solo lettura): frequenza di ARMPLL_LL (A55), ARMPLL_BL (A76), CCIPLL e MFGPLL. Su Android le
   frequenze CPU le gestisce il firmware MCUPM con il DVFS; in questo port nessuno le tocca, restano dove le ha
   lasciate LK. Ora che il limite è la CPU, è il primo numero da guardare (vedi sotto).

## Cosa non si può ottimizzare qui (o non conviene), e perché

- **La GPU in sé**: occupata ~1%. DVFS, flush reduction e fast kick sono già fatti; alzare la frequenza non cambia
  nulla finché il frame è limitato dalla CPU.
- **Il numero di ioctl per frame** (~200): lo decide Panfrost (2 submit per pass, WAIT_BO per riuso di BO). Il kernel
  può solo renderle più leggere. Ridurle (batch più grandi, cache dei BO senza WAIT_BO) è lato userspace.
- **Il costo di un messaggio Mach**: è di XNU. La trap lo evita, ma serve che userspace la usi.
- **Lavoro per BO in SUBMIT**: con i BO write-combined (0114) non c'è più manutenzione cache; restano retain e
  dipendenze implicite, pochi µs. Si potrebbe togliere l'OSArray per job, ma il guadagno è sotto la misura: va fatto
  solo se `gpu calls` mostra SUBMIT ancora alta dopo 0118.
- **Scheduler AMP**: XNU qui vede un solo cluster omogeneo (8 core uguali): i thread caldi (backboardd, render
  server) finiscono su un A55 tre volte su quattro, anche se ci sono due A76 liberi. Il supporto P/E di XNU
  (`__ARM_AMP__`) è una modifica grande e fuori dal driver GPU.
- **Frequenza CPU**: se `gpu clocks` mostra le CPU basse (LK di solito le lascia a un'OPP intermedia), il guadagno
  potenziale è grande ma richiede un driver DVFS CPU (MCUPM/CSRAM di MediaTek o ARMPLL diretto + tensioni VPROC del
  PMIC): progetto a sé, con rischio sul ferro. Prima misurare.
- **Copia del display** (~3,2 ms per frame su un core): resta finché non si prova lo scanout diretto (`vivascanout=1`
  all'avvio, 0109, ora con cambio al frame end da 0117). Non è il collo di bottiglia degli fps (una copia per frame,
  entro il 25% di un core) ma è CPU sottratta al resto.
- **Coalescenza dei timer** di XNU sul tick vsync: può ritardarlo fino a ~1 ms. Con il doppio buffer agganciato in
  fase non si accumula; effetto minore.

## Come verificarlo

| Cosa | Comando | Atteso |
|---|---|---|
| Risvegli mirati | `cmd gpu calls reset`, `ca` 61 frame, `cmd gpu calls` | "woke with nothing done" basso rispetto alle attese; generic wakeups ~0 |
| SUBMIT / WAIT_BO | stesso | gate avg pochi µs; submit avg kernel di gran lunga sotto i 60 µs misurati prima |
| Trap | dopo l'adozione in libdrm-xnu | colonna "trap" = numero chiamate; tempo userspace per chiamata in calo |
| Frame | `VMG_CA_TIME=1 VMG_CA_SETTINGS=1 ca 61` | sotto i 18 ms di 0117 |
| Early present | `cmd disp` | "frames shown before their tick" > 0 durante le animazioni |
| CPU | `cmd gpu clocks` | frequenze di A55/A76 (da confrontare col massimo ~2 GHz) |
| Fallback | `disp early off`; boot-arg `sweetfb_early=0` | comportamento di 0117 |
