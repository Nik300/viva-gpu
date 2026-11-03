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
