# Viva GPU: contratto kernel ↔ userspace

Questo è ciò che il driver XNU (patch `fork/xnu/patches/01xx-viva-gpu-*`, fasi G1-G2 di
`fork/docs/PIANO-GPU.md`) deve implementare perché il driver Metal funzioni sul telefono. Il lato userspace è
già scritto e provato sul Mac contro il kernel simulato (`vgpu/vgpu_mock.c`). Le strutture sono in
[`viva_gpu_uapi.h`](viva_gpu_uapi.h).

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

| Selettore | Semantica (equivalente Linux) | Note per XNU |
|---|---|---|
| `GET_VERSION` | — | `major` = `VGPU_UAPI_MAJOR`; `gpu_id` = registro `GPU_ID`; `page_size` = 16384 |
| `GET_PARAM` | `DRM_PANFROST_GET_PARAM` | valori letti in G1 (`GPU_ID >> 16`, `SHADER_PRESENT`, `*_FEATURES`, `JS_FEATURES*`...). `SELECTED_COHERENCY`: probabilmente `NONE` sul MT6781 (da misurare) |
| `CREATE_BO` | `DRM_PANFROST_CREATE_BO` | memoria wired; `offset` = GPU VA in **[`VGPU_VA_START`, `VGPU_VA_END`)** = [32 MiB, 4 GiB): Mesa lo presuppone. Granulo GPU 4 KiB, pagine XNU 16 KiB (4 PTE per pagina). `HEAP`: cresce su fault (tiler); `NOEXEC`; `WB_MMAP` = mappatura CPU cacheabile |
| `MMAP_BO` | `DRM_PANFROST_MMAP_BO` | `offset` = token; la mappatura avviene con `IOConnectMapMemory64(conn, memoryType = token)` → `clientMemoryForType` restituisce la memoria della BO. **Mappature cacheabili** (patch 0100): il kernel pulisce e invalida le cache CPU delle BO attorno a ogni job, quindi CPU e GPU restano allineate senza intervento dell'userspace (`SELECTED_COHERENCY` = `NONE`; `SYNC_BO` resta disponibile ma non è necessario). Per le IOSurface la mappatura parte dalla pagina del piano (vedi `IMPORT_IOSURFACE`) |
| `GET_BO_OFFSET` | `DRM_PANFROST_GET_BO_OFFSET` | |
| `GEM_CLOSE` | `DRM_IOCTL_GEM_CLOSE` | la BO resta viva finché un job che la usa non è finito |
| `SUBMIT` | `DRM_PANFROST_SUBMIT` | `requirements & FS` → JS0 (fragment), altrimenti JS1 (vertex/tiler/compute). Attende gli `in_syncs`, segnala `out_sync` a fine catena. Timeout + soft reset con errore al syncobj (mai panic) |
| `WAIT_BO` | `DRM_PANFROST_WAIT_BO` | timeout assoluto `CLOCK_MONOTONIC` |
| `MADVISE` | `DRM_PANFROST_MADVISE` | cache di BO di Mesa |
| `SYNCOBJ_CREATE/DESTROY/WAIT/RESET/SIGNAL` | `DRM_IOCTL_SYNCOBJ_*` binari | `WAIT_ALL`, `WAIT_FOR_SUBMIT` |
| `SYNCOBJ_TRANSFER` | (Viva) | `dst` prende la fence corrente di `src`: sostituisce export/import di sync file, che Panfrost usa per le fence (`libdrm-xnu`) |
| `IMPORT_IOSURFACE` | (Viva; al posto di dma-buf) | mappa nella GPU le pagine di una surface di `SweetSurface` (patch 0046), senza copie; restituisce `offset`, `bytes_per_row`, dimensioni e formato. La BO parte dalla pagina che contiene il primo byte del piano: `offset` (e `GET_BO_OFFSET`) è l'indirizzo GPU del primo byte del piano, la mappatura CPU parte dalla pagina, quindi il piano sta a mappatura + (`offset` & (page_size − 1)); `libdrm-xnu` lo somma in `drmMap`. La surface resta viva finché esiste la BO |
| `IMPORT_USERPTR` | (Viva) | `newBufferWithBytesNoCopy`: wire delle pagine del task e mappatura GPU. **Lato Mesa manca ancora** il `resource_from_handle` per i buffer in Panfrost (oggi questi buffer vengono copiati) |
| `SYNC_BO` | `DRM_PANFROST_SYNC_BO` | manutenzione delle cache CPU per le BO `WB_MMAP` |
| `QUERY_BO_INFO` | `DRM_PANFROST_QUERY_BO_INFO` | |
| `JM_CTX_CREATE/DESTROY` | `DRM_PANFROST_JM_CTX_*` | un solo contesto per connessione: `handle` = 1 |

## Cosa non serve
- Niente nodo DRM, niente dma-buf, niente sync file, niente KMS: la presentazione passa per le IOSurface e
  `AppleCLCD` (e, in G8, per lo scanout diretto).
- I contatori di prestazioni (`PERFCNT_*`) non sono usati (la patch Mesa 0002 li disattiva su XNU).

## Prova
Lo stesso eseguibile `vgpu/test_vgpu` gira sul Mac (mock) e sul telefono (`VGPU_BACKEND=iokit`). Sul telefono
salta solo il submit, perché lì serve una catena di job valida. Il primo job vero è il `WRITE_VALUE` di G2.
