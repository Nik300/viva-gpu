# Viva GPU: contratto kernel ↔ userspace

Il contratto tra il driver Metal (`vgpu/`, `libdrm-xnu/`) e il driver XNU `VivaGPUAccelerator` (patch
`0100-viva-gpu-mali` e successive di [ios-viva](https://github.com/Nik300/ios-viva/tree/viva/xnu/patches)). Entrambi
i lati sono implementati e girano sul telefono; sul Mac il kernel è sostituito dal mock in-process
(`vgpu/vgpu_mock.c`). Le strutture sono in [`viva_gpu_uapi.h`](viva_gpu_uapi.h), versione **1.2**
(`VGPU_UAPI_MAJOR`/`MINOR`).

## Servizio IOKit
- Classe **`VivaGPUAccelerator`**, sottoclasse di **`IOAcceleratorES`**: Metal di iOS 16 cerca i servizi con
  `IOServiceMatching("IOAcceleratorES")`. La patch definisce `IOAcceleratorES` (sottoclasse di `IOService`)
  perché il nostro kernel non ha `IOGPUFamily`.
- Proprietà del servizio: `MetalPluginName = "VivaMTLDriver"` e `MetalPluginClassName = "VMDevice"` (Metal
  carica `/System/Library/Extensions/VivaMTLDriver.bundle` e la classe `VMDevice`).
- Con il boot-arg `vivagpu=0` il servizio non viene pubblicato: Metal vede 0 device.
- `IOServiceOpen(type = VGPU_CLIENT_TYPE)` crea un `VivaGPUUserClient`, cioè una connessione con il proprio
  spazio di indirizzi GPU, le proprie BO e i propri syncobj. Mesa ne apre una per device Metal.

## Chiamate
`IOConnectCallStructMethod(selector, &args, sizeof args, &args, &outSize)`: la struttura entra e torna aggiornata.
La dimensione va controllata con `vgpu_selector_size[]`. I puntatori dentro le strutture (`in_syncs`,
`bo_handles`, `handles`, `ops`) sono indirizzi del task chiamante, da leggere con `copyin` (o con un
`IOMemoryDescriptor::withAddressRange` sul task). Gli errori si restituiscono come `kIOReturn*`; `vgpu` li
converte in errno (tabella in `vgpu_iokit.c`).

**Percorso veloce** (minor ≥ 1, patch 0118): `IOConnectTrap2(conn, VGPU_TRAP_CALL, selector, &args)` fa la stessa
cosa senza un messaggio Mach (il kernel legge e riscrive la struttura con `copyin`/`copyout`). `vgpu` lo usa per tutti
i selettori quando il kernel lo offre (`VGPU_NO_TRAP=1` per tornare al metodo struct).

**Pagina di completamento** (minor ≥ 2, K0h): `IOConnectMapMemory64(type = VGPU_MAP_COMPLETION)` mappa in sola
lettura una `struct vgpu_completion` per connessione. Ogni job della connessione con `seq <= completed` è finito
(confronto wrap-safe). `libdrm-xnu` risponde a `WAIT_BO` da qui senza entrare nel kernel, tranne per le IOSurface
condivise con altri processi (`VGPU_NO_LOCAL_WAIT=1` per disattivarlo).

| Selettore | Semantica (equivalente Linux) | Note per XNU |
|---|---|---|
| `GET_VERSION` | — | `major` = `VGPU_UAPI_MAJOR`; `gpu_id` = registro `GPU_ID`; `page_size` = 16384 |
| `GET_PARAM` | `DRM_PANFROST_GET_PARAM` | valori letti dai registri (`GPU_ID >> 16`, `SHADER_PRESENT`, `*_FEATURES`, `JS_FEATURES*`...). `SELECTED_COHERENCY` = `NONE`: la GPU del MT6781 non è IO-coerente |
| `CREATE_BO` | `DRM_PANFROST_CREATE_BO` | memoria wired; `offset` = GPU VA in **[`VGPU_VA_START`, `VGPU_VA_END`)** = [32 MiB, 4 GiB): Mesa lo presuppone. Granulo GPU 4 KiB, pagine XNU 16 KiB (4 PTE per pagina). `HEAP`: cresce su fault (tiler); `NOEXEC`; `WB_MMAP` = mappatura CPU cacheabile |
| `MMAP_BO` | `DRM_PANFROST_MMAP_BO` | `offset` = token; la mappatura avviene con `IOConnectMapMemory64(conn, memoryType = token)` → `clientMemoryForType` restituisce la memoria della BO. La coerenza è compito del kernel, mai dell'userspace: le BO senza `WB_MMAP` sono mappate write-combined (`vivagpuwc`, patch 0112); quelle `WB_MMAP` vengono invalidate in modo pigro, solo quando l'userspace le attende (`vivagpulazy`, patch 0104); le cache della GPU si puliscono attorno a ogni catena, saltando i flush già fatti (`vivagpuflushid`, 0115). `SYNC_BO` resta disponibile ma non è necessario. La mappatura resta valida fino a `GEM_CLOSE` (`libdrm-xnu` la rimuove prima di chiudere la BO). Per le IOSurface la mappatura parte dalla pagina del piano (vedi `IMPORT_IOSURFACE`) |
| `GET_BO_OFFSET` | `DRM_PANFROST_GET_BO_OFFSET` | |
| `GEM_CLOSE` | `DRM_IOCTL_GEM_CLOSE` | la BO resta viva finché un job che la usa non è finito. Le BO sono contate per processo (`vivagpumem`, `vivagpumemtotal`): oltre il limite `CREATE_BO` fallisce con `kIOReturnNoMemory` |
| `SUBMIT` | `DRM_PANFROST_SUBMIT` | `requirements & FS` → JS0 (fragment), altrimenti JS1 (vertex/tiler/compute). Attende gli `in_syncs`, segnala `out_sync` a fine catena. Code FIFO per connessione e per slot; **sincronizzazione implicita**: ogni job attende l'ultima fence di ogni sua BO e IOSurface, anche tra processi (K0). Catene oltre 3 s fermate, fault MMU confinati alla catena e al suo spazio di indirizzi, errore al syncobj: mai panic. `seq` del job scritto nella struttura (per la pagina di completamento) |
| `WAIT_BO` | `DRM_PANFROST_WAIT_BO` | timeout assoluto `CLOCK_MONOTONIC` |
| `MADVISE` | `DRM_PANFROST_MADVISE` | cache di BO di Mesa |
| `SYNCOBJ_CREATE/DESTROY/WAIT/RESET/SIGNAL` | `DRM_IOCTL_SYNCOBJ_*` binari | `WAIT_ALL`, `WAIT_FOR_SUBMIT` |
| `SYNCOBJ_TRANSFER` | (Viva) | `dst` prende la fence corrente di `src`: sostituisce export/import di sync file, che Panfrost usa per le fence (`libdrm-xnu`) |
| `IMPORT_IOSURFACE` | (Viva; al posto di dma-buf) | mappa nella GPU le pagine di una surface di `SweetSurface` (patch 0046), senza copie; restituisce `offset`, `bytes_per_row`, dimensioni e formato. La BO parte dalla pagina che contiene il primo byte del piano: `offset` (e `GET_BO_OFFSET`) è l'indirizzo GPU del primo byte del piano, la mappatura CPU parte dalla pagina, quindi il piano sta a mappatura + (`offset` & (page_size − 1)); `libdrm-xnu` lo somma in `drmMap`. La surface resta viva finché esiste la BO |
| `IMPORT_USERPTR` | (Viva) | `newBufferWithBytesNoCopy`: wire delle pagine del task e mappatura GPU. implementato nel kernel e nel mock, ma **il driver non lo usa**: i buffer NoCopy diventano alias di BO quando l'allineamento lo permette, altrimenti copie condivise tracciate per generazione o hash XXH3 |
| `SYNC_BO` | `DRM_PANFROST_SYNC_BO` | manutenzione delle cache CPU per le BO `WB_MMAP` |
| `QUERY_BO_INFO` | `DRM_PANFROST_QUERY_BO_INFO` | |
| `JM_CTX_CREATE/DESTROY` | `DRM_PANFROST_JM_CTX_*` | un solo contesto per connessione: `handle` = 1 |
| `SUBMIT_BATCH` | (Viva, minor ≥ 2) | fino a 64 `SUBMIT` in una chiamata; si ferma al primo che fallisce (`done` = quanti sono stati accodati). `libdrm-xnu` accoda i submit e li manda ogni `VGPU_BATCH_MAX` (16) o prima di qualunque altra chiamata (`VGPU_NO_SUBMIT_BATCH=1` per disattivarlo) |
| `SURFACE_PROMISE` | (Viva, minor ≥ 2, K0i) | una fence non ancora segnalata diventa l'ultima fence GPU di fino a 16 IOSurface i cui job non sono ancora stati inviati: `IOSurfaceLock`, il display, `WAIT_BO` e i job di altri processi la attendono. Si risolve con `SYNCOBJ_TRANSFER` o con un `SUBMIT` che la usa come `out_sync`; dopo `timeout_ms` (default 1000, max 5000) si segnala con errore. Usato con `VMG_SURFACE_PROMISE=1` |

## Cosa non serve
- Niente nodo DRM, niente dma-buf, niente sync file, niente KMS: la presentazione passa per le IOSurface e
  `AppleCLCD` (coda di swap, `SwapWait`, scanout diretto delle surface contigue).
- I contatori di prestazioni (`PERFCNT_*`) non sono usati (la patch Mesa 0002 li disattiva su XNU).

## Prova
Lo stesso eseguibile `vgpu/test_vgpu` gira sul Mac contro il mock (28/28) e sul telefono (`VGPU_BACKEND=iokit`),
dove salta solo il submit, perché lì serve una catena di job valida. Il contratto completo, submit compresi, è
esercitato sul telefono dal driver stesso e dai test di `driver/tests` (`isatest`, `passbench`, `mpstest`).
Sul kernel, `gpu selftest` del link USB esegue un job `WRITE_VALUE` (e, con `fault`, un fault MMU controllato).
