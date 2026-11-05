# ABI IOSurfaceAccelerator ↔ AppleM2ScalerCSCDriver (iOS 16.7.16, 20H392, iPhone10,3 / A11)

Reverse engineering statico del dyld shared cache
`research-dsc/20H392__iPhone10,3_6/dyld_shared_cache_arm64` con `ipsw` (2026-11-05).
Tutti gli indirizzi sono VA nel cache (slide 0) e si possono ricontrollare con
`ipsw dyld disass <dsc> --vaddr <addr> --count N`.

Scopo: implementare sul port XNU per MT6781 un IOService compatibile, così che
QuartzCore / ImageIO / VideoToolbox ecc. o funzionino oppure ripieghino in modo pulito.

Legenda affidabilità: **[certo]** = letto direttamente nel codice; **[dedotto]** = inferito
da come i chiamanti usano il valore; **[ignoto]** = non determinabile staticamente (vedi §7).

---

## 0. Riassunto per chi ha fretta

| Voce | Valore |
|---|---|
| Classe kernel cercata | `IOServiceMatching("AppleM2ScalerCSCDriver")` → `IOServiceGetMatchingService(kIOMainPortDefault, …)`. Nessuna proprietà aggiuntiva nel matching. |
| Servizio alternativo | `"AppleSRSDriver"` solo se il dict di Create contiene la chiave `"Sharpener"` (super-resolution; non serve su A11). |
| `IOServiceOpen` type | `0` (M2Scaler). Per SRS: `0x00B00000 \| strength`. |
| Chiamate durante Create | **nessuna** `IOConnectCall*`. Solo match + open. |
| Porta notifiche | `IOConnectSetNotificationPort(connect, type=0, port, ref=0)`, fatta **pigramente** in `IOSurfaceAcceleratorGetRunLoopSource`. |
| Transfer/Transform/Blit | **selettore 1**, `IOConnectCallStructMethod` (sincrono dal punto di vista Mach), input struct **0x170 byte**, output **nessuno**. L'asincronia è gestita dal kernel: se il campo callback della struct è ≠0 il kernel deve mandare un messaggio di completamento `kIOAsyncCompletionNotificationType` alla porta registrata. |
| Altri selettori | 0 CaptureSurface (struct 0x40) · 2 AbortTransfers (0 arg) · 3 AbortCaptures (0 arg) · 4 SetCustomFilter (struct 0x20) · 5 GetID (0 in / 1 scalar out) · 7 ConfigurePerformanceStats (1 scalar in) · 8 KernelTests (struct 0xFA8) · 9 GetHistogram (struct 8 byte = puntatore utente). Il 6 non è usato dal framework. |
| Proprietà registry lette | `IOSurfaceAcceleratorCapabilitiesDict` (CFDictionary, sull'entry stessa, senza ricorsione), `PerformanceStats` (CFDictionary). |
| Consumatori principali | QuartzCore (backboardd/WindowServer: detach layer su IOMFB, mirroring/clone, HDR, copie display), VideoToolbox (VTPixelTransferSession), CMCapture/CMImaging (camera), CoreRE, AppleJPEG (plugin recode), ImageIO (solo color-match CIF10→P3), MobileIcons (solo test di presenza). |
| Se Create fallisce | Tutti i consumatori analizzati ripiegano (GPU/CPU/software) o saltano la funzione; nessuno va in crash. Effetto collaterale: `IOSurfaceAcceleratorCreate` stampa `"IOServiceMatchingfailed for: AppleM2ScalerCSCDriver"` su **stderr** a ogni tentativo e QuartzCore ritenta a ogni uso. |

---

## 1. Ricerca e apertura del servizio

### 1.1 Oggetto CF `IOSurfaceAcceleratorRef`

`_IOSurfaceAcceleratorCreate` @ `0x1d3c21b64`: `_CFRuntimeCreateInstance(NULL, typeID, 0x20, NULL)`
(`0x1d3c21bb4`), quindi l'istanza è 0x10 (header CFRuntimeBase) + 0x20 byte:

| Offset | Tipo | Significato | Fonte |
|---|---|---|---|
| +0x10 | `IONotificationPortRef` | creato in GetRunLoopSource | `0x1d3c22df8` |
| +0x18 | `CFRunLoopSourceRef` | idem | `0x1d3c22e24` |
| +0x20 | `io_service_t` | servizio matchato | `0x1d3c21c64` |
| +0x24 | `io_connect_t` | user client | `0x1d3c21c64` |
| +0x28 | `uint32` | cache dell'ID (selettore 5); 0xFF per SRS | `0x1d3c22dac`, `0x1d3c22d68` |
| +0x2c | `uint32` | 1 = istanza SRS (AppleSRSDriver), 0 = M2Scaler | `0x1d3c21bf4` |

Finalize (`0x1d3c21cec`): `IONotificationPortDestroy(+0x10)` se presente, poi `IOServiceClose(+0x24)`.
Il `io_service_t` non viene mai rilasciato (leak innocuo).

### 1.2 Sequenza di Create

Prototipo [dedotto dai chiamanti]:
`IOReturn IOSurfaceAcceleratorCreate(CFAllocatorRef alloc, CFDictionaryRef options, IOSurfaceAcceleratorRef *out)`.

1. `*out = NULL` (`0x1d3c21b88`).
2. Se `options != NULL` e contiene la chiave CFString `"Sharpener"` (`0x1d3c21bd4`):
   servizio = `"AppleSRSDriver"`, `type = 0xB00000 | srs_getStrength(options)`
   (`0x1d3c21bf8`), flag SRS (+0x2c) = 1. `srs_getStrength` (`0x1d3c22c8c`) legge `"Strength"`:
   `StrengthWeak`→1, `StrengthNormal`→0, `StrengthStrong`→3, assente/sconosciuto→0.
3. Altrimenti servizio = `"AppleM2ScalerCSCDriver"` (`0x1d3c21c14`), `type = 0`.
4. `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))` (`0x1d3c21c28`–`0x1d3c21c34`).
   - fallisce → `fprintf(stderr, "IOServiceMatchingfailed for: %s\n")`, ritorna
     **`0xE00002C0` (kIOReturnNoDevice)** (`0x1d3c21c8c`), `*out` resta NULL.
5. `IOServiceOpen(service, mach_task_self(), type, &connect)` (`0x1d3c21c54`).
   - errore → ritorna l'errore di IOServiceOpen tale e quale, `*out` NULL.
6. Successo → salva service/connect (+0x20/+0x24), `*out = ref`, ritorna 0.

**Nessuna `IOConnectCall*`, nessun `IOConnectMapMemory`, nessuna proprietà letta in Create.**

Nota per il kernel: `IOServiceMatching` produce `{IOProviderClass = "AppleM2ScalerCSCDriver"}`;
il matching usa l'ereditarietà delle metaclassi, quindi la nostra classe deve **chiamarsi**
`AppleM2ScalerCSCDriver` (o derivare da una classe con quel nome) ed essere `registerService()`-ata.
`newUserClient` deve accettare `type == 0`.

### 1.3 Porta di notifica / run loop source

`_IOSurfaceAcceleratorGetRunLoopSource` @ `0x1d3c22dc4`:
- se +0x18 già valorizzato lo ritorna;
- altrimenti `IONotificationPortCreate(kIOMainPortDefault)` → +0x10,
  `IOConnectSetNotificationPort(connect, 0 /*type*/, IONotificationPortGetMachPort(port), 0 /*reference*/)`
  (`0x1d3c22e10`–`0x1d3c22e18`), `IONotificationPortGetRunLoopSource` → +0x18.

Quindi lato kernel serve `IOUserClient::registerNotificationPort(port, type=0, refCon=0)`.
Il framework **non** usa mai `IOConnectCallAsync*`: l'asyncRef deve essere costruito dal kernel
a partire dalla porta registrata e dai campi callback della struct (§2.4).

### 1.4 Altre funzioni "di servizio"

- `IOSurfaceAcceleratorGetServiceObject(ref, io_service_t *svc, io_connect_t *conn)` @ `0x1d3c22c5c`:
  copia +0x20/+0x24; `0xE00002BC` se un argomento è NULL.
- `IOSurfaceAcceleratorGetStatistics(ref)` @ `0x1d3c22e90`: **nessuna chiamata al user client**,
  `IORegistryEntryCreateCFProperty(service, "PerformanceStats", NULL, 0)`; ritorna il dict (o NULL
  se non è un CFDictionary). Su SRS ritorna NULL.
- `IOSurfaceAcceleratorGetFrameworkInfo(out)` @ `0x1d3c233a4`: `*out = 0`, ritorna
  `0xE00002F0` (kIOReturnNotFound) — stub.
- `IOSurfaceAcceleratorTransferSurfaceWithSwap` (`0x1d3c22f18`) e `IOSurfaceAcceleratorBlitSurfaceWithSwap`
  (`0x1d3c22f3c`): **stub che ritornano 0 senza fare nulla**.
- `IOSurfaceAcceleratorConditionalTransferSurfaceWithSwap` (`0x1d3c22f20`): identico a TransferSurface.

---

## 2. Transfer / Transform / Blit — selettore 1

### 2.1 Prototipi e instradamento

Tutti e tre convergono in `prepareTransformBuffersAndOptions` (`0x1d3c21d28`) e
`transformSurface` (`0x1d3c22878`), che per l'M2Scaler fa (`0x1d3c229d8`–`0x1d3c229fc`):

```c
IOConnectCallStructMethod(connect, 1, &req, 0x170, NULL, NULL);   // tail-call
```

Il valore ritornato dalle API pubbliche è esattamente il `kern_return_t`/`IOReturn` di questa
chiamata (oppure `0xE00002C2` se il parsing delle opzioni fallisce, vedi §2.5).

| API | Indirizzo | Firma [dedotta: argomenti → campi] |
|---|---|---|
| `IOSurfaceAcceleratorTransformSurface` | `0x1d3c219cc` | `(ref, IOSurfaceRef src, IOSurfaceRef dst, CFDictionaryRef opts, const IOSA_TransformRects *rects /*48 B, nullable*/, const IOSA_Completion *cpl /*24 B, nullable*/)` |
| `IOSurfaceAcceleratorTransferSurface` | `0x1d3c21cb8` | `(ref, src, dst, opts, IOSA_Callback cb, void *refcon, void *refcon2)` → `convertToTransform(ref, src, dst, opts, NULL, NULL, cb, refcon, refcon2)` |
| `IOSurfaceAcceleratorBlitSurface` | `0x1d3c219ac` | `(ref, src, const IOSA_LegacySrcRect *srcRect, dst, const IOSA_Rect32 *dstRect, opts, cb, refcon, refcon2)` → `convertToTransform(ref, src, dst, opts, srcRect, dstRect, cb, refcon, refcon2)` |

La firma di TransferSurface è confermata da CMCapture (`0x1a21852cc`–`0x1a21852ec`:
`x4 = _accelCompletionCallback`, `x5 = &ctx`, `x6 = 0`) e da QuartzCore, che passa a
TransformSurface come `cpl` una tripla `{CA::WindowServer::transfer_complete, refcon, refcon2}`
(`0x18832add8`–`0x18832adec`, `0x18832aeb8`).

Differenza tra i percorsi: `prepareTransformBuffersAndOptions` riceve un flag `legacy`
(w3): TransformSurface passa 0 (`0x1d3c21a58`), convertToTransform passa 1 (`0x1d3c21b34`).
Con `legacy == 0` alla fine viene **forzato il bit 0x1000** (FixUpscaling) nei flag
(`0x1d3c226bc`–`0x1d3c226cc`).

### 2.2 Struct di richiesta (input del selettore 1) — 0x170 byte

Il buffer è sullo stack, azzerato per 0x170 byte (`0x1d3c219f4`–`0x1d3c21a24`), poi riempito.
Tutti i campi sono little-endian.

| Offset | Size | Campo | Riempito da / note |
|---|---|---|---|
| 0x000 | u32 | `srcSurfaceID` = `IOSurfaceGetID(src)` | `0x1d3c21d80` |
| 0x004 | u32 | `dstSurfaceID` = `IOSurfaceGetID(dst)` | `0x1d3c21d74` |
| 0x008 | u64 | `callback` (puntatore funzione utente, 0 = nessuna notifica) | `0x1d3c21a30`, `0x1d3c21ae4` |
| 0x010 | u64 | `refcon` | idem |
| 0x018 | u64 | `refcon2` | `0x1d3c21a38`, `0x1d3c21ae8` |
| 0x020 | u64 | `flags` (bitfield, §2.3) | vari |
| 0x028 | u64 | `src.x` in virgola fissa 16.16 (u64) | §2.6 |
| 0x030 | u64 | `src.y` 16.16 | |
| 0x038 | u64 | `src.width` 16.16 | |
| 0x040 | u64 | `src.height` 16.16 | |
| 0x048 | u64 | riservato, sempre 0 | `0x1d3c21d84` |
| 0x050 | u64 | riservato, sempre 0 | `0x1d3c21d68` |
| 0x058 | u32 | `dst.x` (pixel interi) | |
| 0x05c | u32 | `dst.y` | |
| 0x060 | u32 | `dst.width` | |
| 0x064 | u32 | `dst.height` | |
| 0x068 | u32 | `AlphaOverride` valore | `0x1d3c22008` |
| 0x06c | u32 | `BorderFillX` | `0x1d3c2217c` |
| 0x070 | u32 | `BorderFillY` | |
| 0x074 | u32 | `BorderFillWidth` | `0x1d3c22184` |
| 0x078 | u32 | `BorderFillHeight` | |
| 0x07c | u32 | `BorderFillAlpha` (opzionale) | `0x1d3c221b4` |
| 0x080 | u32 | `BorderFillRedY` | `0x1d3c2218c` |
| 0x084 | u32 | `BorderFillGreenCb` | |
| 0x088 | u32 | `BorderFillBlueCr` | `0x1d3c22194` |
| 0x08c | u16 | `WriteOnlyModeAlpha` | `0x1d3c22030` |
| 0x08e | u16 | `WriteOnlyModeRedLuma` | `0x1d3c22050` |
| 0x090 | u16 | `WriteOnlyModeGreenCb` | `0x1d3c22070` |
| 0x092 | u16 | `WriteOnlyModeBlueCr` | `0x1d3c22090` |
| 0x094 | 8 B | riservato (0) | — |
| 0x09c | u32 | `HistogramBinMode` | `0x1d3c221c8` |
| 0x0a0 | u32 | `HistogramOffsetX` | `0x1d3c221ec` |
| 0x0a4 | u32 | `HistogramOffsetY` | |
| 0x0a8 | u32 | `HistogramWidth` | |
| 0x0ac | u32 | `HistogramHeight` | `0x1d3c22228` |
| 0x0b0 | u32[] | `HistogramPixelBins[i]` (solo se BinMode==2; ogni valore < 0x10000) | `0x1d3c222ac` |
| 0x0d0 | 4 × 0x28 | `comm[4]` (canali dati ausiliari HDR/ASE/HCU, §2.7) | `0x1d3c224c4`–`0x1d3c225d8` |
| 0x170 | — | fine | |

Note:
- `HistogramPixelBins` non ha limite di conteggio nel framework: il CFArray viene copiato a partire
  da +0xB0 per `CFArrayGetCount` elementi. Lo spazio prima di `comm[]` è 8 voci; oltre si
  sovrascrive `comm[0]` (bug del framework). Il kernel deve validare.
- Rettangoli tutti a zero (TransferSurface, o Transform con `rects == NULL`) ⇒ [dedotto] "intera
  superficie" sorgente → intera destinazione. Il kernel deve gestire questo caso perché
  `IOSurfaceAcceleratorTransferSurface` passa sempre rect nulli.

### 2.3 Bitfield `flags` (+0x20) e mappatura delle chiavi del dizionario

Valori di chiave (CFString) risolti dalla sezione `__cfstring` (`0x1dab98260…`); i simboli esportati
`kIOSurfaceAccelerator*` (`0x1dab98058…`) puntano a queste stringhe. Notare che
`kIOSurfaceAcceleratorSymmetricTransformKey` = `"Transform"` e `kIOSurfaceAcceleratorComm` =
`"IOSurfaceAcceleratorCommApi"`. `getNumber` legge con `CFNumberGetValue(kCFNumberIntType=9)`
(`0x1d3c22ad8`), `getBoolean` usa `CFBooleanGetValue` (`0x1d3c22864`).

| Bit (valore) | Chiave (simbolo / stringa) | Tipo | Note + indirizzo |
|---|---|---|---|
| 0–1 (+ bit ≥2) | `kIOSurfaceAcceleratorSymmetricTransformKey` / `"Transform"` | number | OR diretto nei bit bassi. Valido se `(v & ~3)` ha ≤1 bit acceso, altrimenti errore "Invalid flip/rotate" (`0x1d3c21de8`–`0x1d3c21e04`, OR in `0x1d3c21e60`). [dedotto] bit0/bit1 = flip, bit2 (0x4) = rotazione 90°; QuartzCore usa solo `v & 7` (`0x18832ab70`). Direzione dei flip/rotazione [ignoto]. |
| 6 (0x40) | `kIOSurfaceAcceleratorUseCustomFilter` / `"CustomFilter"` | bool | `0x1d3c21f34`; usa i coefficienti del selettore 4 |
| 7 (0x80) | `kIOSurfaceAcceleratorUseNearestFilter` / `"NearestFilter"` | bool | `0x1d3c21f54` |
| 8 (0x100) | `kIOSurfaceAcceleratorOptOutBlitClip` / `"OptOutBlitClip"` | bool | `0x1d3c21f74` |
| 9 (0x200) | `kIOSurfaceAcceleratorLockInScaler` / `"LockInScaler"` | bool | `0x1d3c21f94` |
| 10 (0x400) | `kIOSurfaceAcceleratorSkipAsyncCallback` / `"SkipAsyncCallback"` | bool | `0x1d3c21fb4` |
| 12 (0x1000) | `kIOSurfaceAcceleratorFixUpscaling` / `"FixUpscaling"` | bool | `0x1d3c21fd4`; **forzato a 1 da TransformSurface** (`0x1d3c226c8`) |
| 13–14 (v<<13) | `kIOSurfaceAcceleratorDitherControl` / `"DitherControl"` | number 0..3 | default **1** se chiave assente (`0x1d3c21f04`), 0x2000 anche con `opts == NULL` (`0x1d3c21e50`); ≥4 → errore (`0x1d3c21e88`) |
| 15–17 (v<<15) | *(nessuna chiave)* cositing croma | 1..6 | ricavato da `dst`: `IOSurfaceCopyValue(dst, kIOSurfaceChromaLocationTopField)`: Left/DV420→1, Center→2, TopLeft→3, Top→4, BottomLeft→5, Bottom→6, altro→errore (`0x1d3c225ec`–`0x1d3c22850`). Se il valore manca: `IOSurfaceGetBulkAttachments(dst)` byte +0x3D, tabella `{1,2,3,4,5,6,1}` @ `0x1d3c235f4`. OR in `0x1d3c226a8`. |
| 18 (0x40000) | `kIOSurfaceAcceleratorAlphaOverride` / `"AlphaOverride"` | number | valore in +0x68 (`0x1d3c21ffc`) |
| 28 (0x10000000) | `BorderFillX/Y/Width/Height/RedY/GreenCb/BlueCr` | number ×7 | bit e campi solo se **tutte e 7** presenti; `BorderFillAlpha` opzionale (`0x1d3c220c4`–`0x1d3c221b4`) |
| 29 (0x20000000) | `kIOSurfaceAcceleratorHistogramBinMode` / `"HistogramBinMode"` (+ OffsetX/Y, Width, Height, PixelBins) | number | `0x1d3c221d4`. `HistogramMaxPixelValue` **non** viene letto. |
| 30 (0x40000000) | `kIOSurfaceAcceleratorZeroFill` / `"ZeroFill"` | number ≠0 | `0x1d3c222e4` |
| 31 (0x80000000) | `kIOSurfaceAcceleratorDisablePseudoLinearScaling` | bool | `0x1d3c22338` |
| 32 | `kIOSurfaceAcceleratorPixelAveraging` | bool | `0x1d3c22358` |
| 33 | `kIOSurfaceAcceleratorEdgeMirroring` | bool | `0x1d3c22378` |
| 35+ (v<<35) | `kIOSurfaceAcceleratorUnwireSurfaceKey` / `"UnwireSurface"` | number | `0x1d3c21dc0` (con v>1 sconfina nei bit 36+) |
| 36–38 (v<<36) | `kDisplayColorRemapModeKey` / `"ColorRemapMode"` | number 0..4 | >4 → errore (`0x1d3c2230c`–`0x1d3c22318`) |
| 39 | `kIOSurfaceAcceleratorDirectionalScalingEnable` | bool | `0x1d3c22398` |
| 40 | `kIOSurfaceAcceleratorHDREnable` | bool | `0x1d3c223b8` |
| 41 | `kIOSurfaceAcceleratorEnhanceEnable` | bool | `0x1d3c223f8` |
| 42 | `kIOSurfaceAcceleratorNoiseEstimationEnable` | bool | `0x1d3c223d8` |
| 43 | `kIOSurfaceAcceleratorReadOnly` | bool | `0x1d3c22418` |
| 44 | `kIOSurfaceAcceleratorHtpcLargeHeaders` | bool | `0x1d3c22438` |
| 45 | `kIOSurfaceAcceleratorVraScaling` | bool | `0x1d3c22458` |
| 46 | `kIOSurfaceAcceleratorNoPowerEarlyBail` | bool | `0x1d3c22478` |
| 47 | `kIOSurfaceAcceleratorHighPriority` | bool | `0x1d3c22498` |
| 48 | `WriteOnlyModeAlpha/RedLuma/GreenCb/BlueCr` | number ×4 | bit solo se tutte e 4 presenti (`0x1d3c22098`) |
| 49 | `kIOSurfaceAcceleratorFilmGrainEnable` | bool | `0x1d3c220b8` |
| 51 | `kIOSurfaceAcceleratorReducedPrecisionFractionalOffsets` | bool | `0x1d3c224b8` |
| — | `"IOSurfaceAcceleratorCommApi"` | CFArray di CFData | §2.7 |

Bit mai scritti dal framework: 2–5 (salvo via Transform), 11, 34, 50, 52–63.

**Chiavi esportate ma ignorate dal parser** (nessun riferimento nel codice):
`kIOSurfaceAcceleratorForceMaxSpeedKey` (VideoToolbox e CMCapture la impostano comunque),
`kIOSurfaceAcceleratorHistogramMaxPixelValue`, le `*ApiVersion` (HCU/HDR/ASE). Le chiavi
`Sharpener*`/`Strength*` valgono solo per l'istanza SRS (§3.8).

Non esiste nessuna chiave per matrice CSC, range video/full, primaries o transfer function: il
kernel le deve dedurre dalle **IOSurface stesse** (pixel format + attachment come
`kIOSurfaceYCbCrMatrix`, `kIOSurfaceColorPrimaries`, bulk attachments). Su A11 il driver Apple
lo fa in kernel; per noi è un punto da implementare/semplificare (§6).

### 2.4 Completamento asincrono

Lato framework la chiamata è sempre `IOConnectCallStructMethod` sincrona. La semantica
asincrona è questa [dedotto, coerente con tutti i chiamanti]:

- `callback == 0` (+0x08): operazione sincrona, il kernel ritorna a lavoro finito.
- `callback != 0` e `SkipAsyncCallback` (bit 10) non impostato: il kernel può ritornare subito
  `kIOReturnSuccess` e, a lavoro finito, inviare alla porta registrata col
  `registerNotificationPort(type 0)` un messaggio di completamento IOKit.
- Se la chiamata ritorna errore, il chiamante invoca **da sé** la callback con l'errore
  (QuartzCore `0x18832b31c`–`0x18832b328`), quindi il kernel **non** deve inviare la notifica in
  quel caso.

Formato del messaggio verificato in `IODispatchCalloutFromCFMessage` (IOKit, `0x18e5518e0`):
`msgh_id == 0x35` (53, `kOSNotificationMessageID`), header `OSNotificationHeader64`,
`type & 0xfff == 0x96` (150, `kIOAsyncCompletionNotificationType` 64-bit),
`reference[1]` = funzione, `reference[2]` = refcon, contenuto = `IOReturn result` +
`uint64 args[n]`. Dispatch: n==0 → `f(refcon, result)`; **n==1 → `f(refcon, result, args[0])`**
(`0x18e551a3c`–`0x18e551a44`); n==2 → `f(refcon, result, a0, a1)`; altrimenti
`f(refcon, result, &args, n)`.

QuartzCore usa callback `void cb(void *refcon, int result, void *refcon2)`
(`CA::WindowServer::transfer_complete`, `scaler_stats_transfer_complete` @ `0x1884b8a5c`), quindi
il kernel deve fare l'equivalente di:

```c++
OSAsyncReference64 ref;                    // ref[0] = wake port registrata (type 0)
ref[kIOAsyncCalloutFuncIndex]   = req.callback;   // +0x08
ref[kIOAsyncCalloutRefconIndex] = req.refcon;     // +0x10
io_user_reference_t arg = req.refcon2;            // +0x18
sendAsyncResult64(ref, status, &arg, 1);
```

Il messaggio viene consegnato tramite la `CFRunLoopSource` di `IONotificationPort`, che il
chiamante aggiunge al proprio run loop (QuartzCore: `CFRunLoopAddSource(CFRunLoopGetCurrent(),
src, kCFRunLoopDefaultMode)` @ `0x18832af08`–`0x18832af28`; CMCapture: `kCFRunLoopCommonModes`).
**Se il kernel non invia mai la notifica, QuartzCore non rilascia le risorse della copia**
(la callback è l'unico punto in cui lo fa).

Comportamento con callback ≠0 ma senza porta registrata: [ignoto] (vedi §7).

### 2.5 Errori generati dal framework (prima del kernel)

`0xE00002C2` (kIOReturnBadArgument) con syslog di livello 3 se: `src`/`dst`/struct NULL
(`0x1d3c21e28`), Transform non valido, DitherControl ≥4, ColorRemapMode >4, histogram bin
non-CFNumber o ≥0x10000, CommApi CFData di lunghezza ≠0x28 o tipo non valido, chroma location
non riconosciuta.

### 2.6 Rettangoli

- **TransformSurface** `rects` (48 byte) copiati 1:1 da `prepareTransformRectangles`
  (`0x1d3c22be0`): `[0x00..0x20)` → +0x28 (src 4×u64 16.16), `[0x20..0x30)` → +0x58 (dst 4×u32).
  Esempi reali: QuartzCore costruisce src con `fcvtzu …, #16` (`0x18832b200`–`0x18832b228`);
  ImageIO usa `{0, bandY<<16, w<<16, h<<16}` + dst `{0,0,w,h}` (`0x18bacf994`–`0x18bacf9b4`).
- **BlitSurface** `srcRect` legacy = 6×u32 `{x, y, w, h, fracX, fracY}`, convertito in
  `convertToTransform` (`0x1d3c21af4`–`0x1d3c21b18`):
  `src.x = (x<<16) | (fracX<<14)`, `src.y = (y<<16) | (fracY<<14)`, `src.w = w<<16`,
  `src.h = h<<16`; quindi `frac` è in quarti di pixel. `dstRect` = 4×u32 copiato in +0x58.
  I rect vengono usati solo se **entrambi** i puntatori sono non nulli.

### 2.7 `comm[4]` (+0xD0, 4 × 0x28 byte)

Ogni elemento del CFArray `"IOSurfaceAcceleratorCommApi"` è un CFData di **esattamente 0x28 byte**
`{u32 inType; u32 pad; u64 inAddr; u32 inSize; u32 outType; u64 outAddr; u64 unused}`.
`inType` (0..4) seleziona lo slot e la dimensione (jump table @ `0x1d3c235e0`):

| inType | slot | inSize usato |
|---|---|---|
| 0 | 0 | 0 |
| 1 | 0 | 0x238 |
| 2 | 1 | 0x9008 |
| 3 | 2 | dal blob (+0x10) |
| 4 | 3 | dal blob (+0x10) |

`outType` 0..2 → `outSize` = `{0, 0x17C, 0x1008}` (tabella @ `0x1d3c235e8`). Slot nella struct:
`+0 inType, +8 inAddr, +0x10 inSize, +0x14 outType, +0x18 outAddr, +0x20 outSize`
(`0x1d3c225a0`–`0x1d3c225d8`). `inAddr/outAddr` sono **puntatori nello spazio utente** che il
kernel legge/scrive. Usato da QuartzCore per statistiche ASE (`CA::ASEScalerStatistics`, CFData
da 0x28 a `0x18832ae4c`) e per HDR (tone mapping), da CMCapture e CoreRE per HDR. Per A11 senza
HDR/ASE nel nostro scaler: il kernel può ignorare gli slot (lasciando invariati i buffer di
output) — [dedotto] i chiamanti trattano le statistiche come opzionali.

---

## 3. Gli altri selettori

| Sel | API (indirizzo) | Metodo | Input | Output | Note |
|---|---|---|---|---|---|
| 0 | `IOSurfaceAcceleratorCaptureSurface` (`0x1d3c22f60`) | StructMethod | struct **0x40** | — | §3.1 |
| 1 | Transfer/Transform/Blit | StructMethod | struct **0x170** | — | §2 |
| 2 | `IOSurfaceAcceleratorAbortTransfers` (`0x1d3c22efc`) | ScalarMethod | 0 | 0 | |
| 3 | `IOSurfaceAcceleratorAbortCaptures` (`0x1d3c22f44`) | ScalarMethod | 0 | 0 | |
| 4 | `IOSurfaceAcceleratorSetCustomFilter` (`0x1d3c22af0`) | StructMethod | struct **0x20** | — | §3.2 |
| 5 | `IOSurfaceAcceleratorGetID` (`0x1d3c22d20`) | ScalarMethod | 0 | **1** scalar | §3.3 |
| 6 | — | — | — | — | non usato dal framework |
| 7 | `IOSurfaceAcceleratorConfigurePerformanceStats` (`0x1d3c22e3c`) | ScalarMethod | **1** scalar (u32 esteso a u64) | 0 | su SRS ritorna `0xE00002C7` senza chiamare |
| 8 | `IOSurfaceAcceleratorKernelTests` (`0x1d3c23274`) | StructMethod | struct **0xFA8** | — | il primo u32 deve essere ≤1000 altrimenti `0xE00002C2` lato utente |
| 9 | `IOSurfaceAcceleratorGetHistogram` (`0x1d3c232a8`) | StructMethod | struct **8** (u64 puntatore utente) | — | §3.4 |

### 3.1 CaptureSurface (sel 0, 0x40 byte)

Argomenti: `(ref, IOSurfaceRef surf, CFDictionaryRef opts, a3, a4, a5, a6, a7, stack: a8, a9, cpl[3])`.
Struct (`0x1d3c22fb0`–`0x1d3c22fd4`):
`+0x00 cb, +0x08 refcon, +0x10 refcon2` (copiati dallo stack, 24 byte), `+0x18 u64 transform<<1`,
`+0x20 u32 IOSurfaceGetID(surf)`, `+0x24 a4, +0x28 a5, +0x2c a6, +0x30 a7, +0x34 a8, +0x38 a9, +0x3c a3`.
Controlli: `a8+a6 ≤ a4` e `a9+a7 ≤ a5` (rect dentro i limiti, quindi a4/a5 = larghezza/altezza
sorgente, a6/a7 = origine, a8/a9 = dimensione) altrimenti `0xE00002C2`. Transform letto da
`"Transform"` con la stessa validazione. Nessun consumatore trovato nei framework analizzati.

### 3.2 SetCustomFilter (sel 4, 0x20 byte)

`IOSurfaceAcceleratorSetCustomFilter(ref, u32 vRatio, u32 vTaps, u32 vPhases, u32 hRatio, u32 hTaps, u32 hPhases, const uint32_t *coeffs)`
— nomi dedotti. Struct (`prepareCustomFilter` @ `0x1d3c22b64`):

| Off | Campo |
|---|---|
| 0x00 | u32 vRatio — rapporto dst/src in virgola fissa 1.15 (QuartzCore: `(dstH<<15)/srcH`, `0x18832b014`–`0x18832b01c`) |
| 0x04 | u32 vTaps |
| 0x08 | u32 vPhases |
| 0x0c | u32 hRatio — `(dstW<<15)/srcW` |
| 0x10 | u32 hTaps |
| 0x14 | u32 hPhases |
| 0x18 | u64 **puntatore utente** al buffer coefficienti |

Tutti e 7 i valori devono essere ≠0, altrimenti `0xE00002C2` senza chiamare il kernel.
Il kernel deve fare copyin del buffer: layout [dedotto da QuartzCore `0x18832b058`–`0x18832b0bc`
e da `SetFilterCoefficients`] = 4 blocchi consecutivi di `int32`:
`V0[vTaps×vPhases]`, `V1[vTaps×vPhases]`, `H0[hTaps×hPhases]`, `H1[hTaps×hPhases]`, indice
`tap*phases + phase`; probabilmente set luma e croma. Formato numerico: virgola fissa con
`IOSurfaceAcceleratorFilterCoefficientsPrePointBits` / `PostPointBits` presi dal capabilities dict
(QuartzCore scrive il tap centrale = `1<<PostPointBits`). Dimensione = `4*(2*vT*vP + 2*hT*hP)`.

`IOSurfaceAcceleratorSetFilterCoefficients` (`0x1d3c23088`, deprecata, stampa un warning) costruisce
un buffer di 0x600 byte e chiama `SetCustomFilter(ref, 0x8000 - n*0x1000, 4, 16, idem, 8, 16, buf)`
con `n = filter->flags & 0xF` (≤7); se `flags` bit31 è impostato ripete per un secondo filtro a +0x604.

QuartzCore **ignora** il valore di ritorno del selettore 4 (`0x18832b0d4`).

### 3.3 GetID (sel 5)

`IOConnectCallScalarMethod(connect, 5, NULL, 0, &out, &cnt=1)`; il u64 viene troncato a u32 e
messo in cache in +0x28 (solo se non era già ≠0). Se la chiamata fallisce ritorna l'errore ma
scrive comunque in `*id` il valore in cache. Per SRS ritorna 0xFF senza chiamare.
Significato [ignoto]: probabilmente indice dell'istanza scaler. Nessun consumatore analizzato lo usa.

### 3.4 GetHistogram (sel 9)

`IOSurfaceAcceleratorGetHistogram(ref, IOSA_Histogram *h)` dove `h` è un buffer utente di
**0x620 byte** (VideoToolbox lo azzera con `bzero(…, 0x620)` @ `0x194ccefa0`):

1. Legge `IORegistryEntrySearchCFProperty(service, "IOService", "IOSurfaceAcceleratorCapabilitiesDict", NULL, 0)`
   e da lì `kSurfaceAcceleratorCapabilitiesHistogramValues` (SInt32) = N. Senza dict o chiave →
   `0xE00002BC` senza chiamare il kernel.
2. `IOConnectCallStructMethod(connect, 9, &ptr, 8, NULL, NULL)` con `ptr = (u64)(h + 4)`:
   il kernel scrive (copyout) `3 × N` u32 a quell'indirizzo utente.
3. Al successo: `h->count(+0) = N`, `h->ch[0](+0x608) = h+4`, `h->ch[1](+0x610) = h+4+4N`,
   `h->ch[2](+0x618) = h+4+8N`. Spazio dati 0x604 byte ⇒ **N ≤ 128**.

L'istogramma va prima configurato con le chiavi `Histogram*` durante un Transform (bit 29).
Usato da VideoToolbox (`0x194ccefb8`) e CMImaging (`-[FigM2MController copyHistogram:]`).

### 3.5 Proprietà registry che il servizio deve pubblicare

`IOSurfaceAcceleratorCapabilitiesDict` (OSDictionary) sull'entry del servizio — tutti la cercano con
`IORegistryEntrySearchCFProperty(svc, "IOService", key, NULL, 0)` (nessun flag di ricorsione,
quindi deve stare **sull'entry stessa**). Chiavi lette dai consumatori:

| Chiave | Letto da | Default/uso se mancante |
|---|---|---|
| `IOSurfaceAcceleratorCapabilitiesMinSourceWidth/Height` | QuartzCore, AppleJPEG | QC: 16 / 16 |
| `…MaxSourceWidth/Height` | QC, AppleJPEG | QC: 16384 / 16384 |
| `…MinDestWidth/Height` | QC, AppleJPEG | QC: 4 / 4 |
| `…MaxDestWidth/Height` | QC, AppleJPEG | QC: 4096 / 4096 |
| `…MaxHUpscale/MaxVUpscale` (int, fattore) | QC, AppleJPEG | QC: 4.0 |
| `…MaxHDownscale/MaxVDownscale` (int, QC salva 1/x) | QC, AppleJPEG | QC: 1/4 |
| `IOSurfaceAcceleratorFilterVerticalTapsCount/PhasesCount` | QC, AppleJPEG (si aspetta **vTaps == 9**, altrimenti warning) | QC: 0 |
| `IOSurfaceAcceleratorFilterHorizontalTapsCount/PhasesCount` | QC, AppleJPEG | QC: 0 |
| `IOSurfaceAcceleratorFilterCoefficientsPrePointBits/PostPointBits` | QC | 0 |
| `IOSurfaceAcceleratorFormatIn2Planes420/Out2Planes420/In2Planes422/Out2Planes422` | AppleJPEG | plugin disabilitato |
| `kSurfaceAcceleratorCapabilitiesAccessibility` (int≠0) | QC (`iosurface_accelerator_supports_color_remap`) | false |
| `kSurfaceAcceleratorCapabilitiesColorManager` (int≠0) | QC, ImageIO | false → ImageIO non usa lo scaler |
| `IOSurfaceAcceleratorCapabilitiesDirectionalScaling` (bool) | QC | false |
| `IOSurfaceAcceleratorCapabilitiesASEPolyMaxHRatio/VRatio/ASEMinRatio` | QC | 0 |
| `IOSurfaceAcceleratorCapabilitiesHDR` (bool) | QC (`CADeviceHasHardwareAcceleratedHDR` @ `0x1884cbaa0`) | false |
| `kSurfaceAcceleratorCapabilitiesHistogramValues` (int) | framework (GetHistogram) | GetHistogram fallisce |

Defaults QuartzCore letti da `0x18855c060` (copiati in `ScalerLimits::limits()::limits` @ `0x1dcdf8670`);
i valori del registry sovrascrivono solo se ≥1 (`0x1883a8e90` e seguenti). VideoToolbox ha la sua
`_scalerCapabilities` (non dettagliata qui). Nome della proprietà `PerformanceStats` per GetStatistics.

### 3.6 Selettori dell'istanza SRS (solo per completezza)

Con +0x2c == 1 `transformSurface` chiama `IOConnectCallStructMethod(connect, 1, in, 0x58, out, &0x58)`
(`0x1d3c22a80`–`0x1d3c22a98`), struct: `+0 src/dst ID (8B), +8 cb, +0x10 refcon, +0x18 refcon2,
+0x20 0, +0x24 SharpenerMode (Static=1 default, Dynamic=0), +0x28 strength, +0x2c SourceCleaness
(Noisy=0, Normal=1 default, Clean=2), +0x30 SourceSharpness (Blur=0, Sharp=1 default), +0x34 getpid()`.
Non serve per A11.

---

## 4. Chi usa IOSurfaceAccelerator nel cache

`ipsw dyld imports … IOSurfaceAccelerator`: QuartzCore, ImageIO, VideoToolbox, WebCore, Vision,
CMCapture, MediaAnalysis, Portrait, AppleCVA, CMImaging, FRC, AppleJPEG, ASEProcessing,
MobileIcons, FusionTracker, HDRProcessing, AVD.videodecoder, VisionCore, CoreRE.
CMPhoto e CoreMedia **non** lo importano direttamente (passano da VideoToolbox / CMCapture).

### 4.1 QuartzCore (prioritario: è in backboardd)

Funzioni che lo usano (tutte nel lato "WindowServer", quindi processo **backboardd**):

1. **`CA::WindowServer::IOSurface::copy_iosurface(...)`** @ `0x18832aa6c` — il cuore. Chiamata da
   `IOMFBDisplay::copy_surface` (`0x1883286e4`), a sua volta chiamata da:
   - `IOMFBDisplay::detach_layer` (`0x18831008c`) — layer "staccati" su un piano hardware IOMFB
     (tipicamente video/contenuti a tutto schermo) che richiedono scalatura/CSC;
   - `IOMFBDisplay::finish_update` (`0x1882d1cc4` "CA Backward DM", `0x1882d3818`) — percorsi HDR
     (backward display mapping, HDR clone) e display wireless/clone
     (`IOMobileFramebuffer::get_wireless_surface_options` @ `0x1882d1d78`);
   - `IOMFBDisplay::finish_skylight_update`, `IOMFBDisplay::clone_update` — mirroring/clone.

   Opzioni passate (`0x18832abfc`–`0x18832ad00`): `Transform` = `flags & 7`, `NearestFilter`
   (true se flag 0x200), `ColorRemapMode` (arg), e se è richiesto l'enhance (flag 0x1000):
   `EnhanceEnable`, `NoiseEstimationEnable`, `DirectionalScalingEnable`; `CustomFilter = true` se
   scala ≠1 e flag bit13; `IOSurfaceAcceleratorCommApi` con un CFData 0x28 per le statistiche ASE.
   Prima di trasformare con filtro custom chiama `SetCustomFilter` (sel 4). Chiama
   `TransformSurface` (`0x18832b2fc`) con rect e — se il flag 0x800 non è impostato — con la
   completion `{transfer_complete | scaler_stats_transfer_complete, refcon, refcon2}` e
   run-loop source registrata. Con flag 0x800 è sincrona e invoca la callback da sé.

   **Se Create fallisce** (`0x18832ab4c` → `0x18832b144`): `copy_iosurface` ritorna `false`
   immediatamente. L'acceleratore è memorizzato nel display (+0xE8) e **ritentato a ogni chiamata**
   (quindi a ogni chiamata stampa la riga su stderr di §1.2). Nel `detach_layer` un fallimento
   porta al percorso di non-detach (codice motivo 6, `0x1883100b8`) ⇒ [dedotto] il layer viene
   composto dalla GPU come gli altri. Anche se le protection options delle due superfici
   differiscono ritorna false (`0x18832af68`).

2. **`CA::ScalerUtil::ScalerLimits::limits()`** (block @ `0x1883a8d94`): legge il capabilities dict
   via `IOServiceGetMatchingService("AppleM2ScalerCSCDriver")` **senza** aprire il servizio. Se il
   servizio non esiste restano i default (§3.5): QuartzCore potrebbe quindi considerare "staccabile"
   un layer e poi fallire in `copy_iosurface` (fallback come sopra). Usato da
   `AppleDisplay::detachable_layer_impl`, `iosurface_accelerator_supports_size_p/scale_p/color_remap`,
   `IOMFBDisplay::clone_update`, `HDRProcessorInternal::create_surface_with_forward_dm`.

3. **`CA::OGL::GLESContext::attach_surface_texture`** (`0x1884090c4`): solo backend GLES (legacy);
   se Create fallisce ritorna -1 (texture non agganciata). Su iOS 16 con Metal non è il percorso
   normale.

4. **`CA::HDRProcessorInternal::create_surface_with_forward_dm` / `tonemap_surface_internal`**
   (`0x1884654a8`, `0x188466700`): HDR, chiavi `SkipAsyncCallback`, `Transform`, `FilmGrainEnable`,
   `HDREnable`, `IOSurfaceAcceleratorCommApi`. Fallimento → log "Failed to create
   IOSurfaceAccelerator: 0x%X" (`0x188465c6c`). Attivo solo se il dict dichiara
   `IOSurfaceAcceleratorCapabilitiesHDR`.

5. **`___CADeviceHasHardwareAcceleratedHDR_block_invoke`** (`0x1884cbaa0`): solo lettura registry.

Conclusione QuartzCore: la composizione normale delle animazioni (render Metal + swap IOMFB) **non**
passa da IOSurfaceAccelerator. Lo scaler entra in gioco per detach di layer hardware, mirroring,
HDR e alcune copie. Assenza del servizio = fallback GPU + spam su stderr.

### 4.2 ImageIO

- `IIOIOSurfaceWrapper::copy_and_colormatch_CIF10_to_P3_MSR` (`0x18bacf7e0`): unico uso.
  Create con opzioni NULL; se fallisce salta direttamente all'uscita (`0x18bacf840` →
  `0x18bacfac4`) ⇒ [dedotto] fallback sul percorso CPU. Transform sincrono per bande, opzioni NULL,
  rect `{0, y<<16, w<<16, h<<16}` / `{0,0,w,h}`; errore → log "TransformSurface-band err".
- Abilitato solo se `MGCopyAnswer("Aixt/MEN2O2B7f+8m4TxUA")` (display a gamut esteso) **e** il
  capabilities dict contiene `kSurfaceAcceleratorCapabilitiesColorManager` (block @ `0x18bb02d98`).
  Senza quella chiave ImageIO non tocca lo scaler.

### 4.3 AppleJPEG

`_plugin_iosaccelerator_create` (`0x1d3bec33c`) / `_resize`: plugin di ridimensionamento usato solo
da `_recode_all` e `_set_active_plugin` (transcodifica/recode, non la normale decodifica ImageIO).
Legge il capabilities dict (vTaps, hTaps, formati 2-plane 420/422, min/max, up/down scale); se manca
→ "Unable to get scaler capabilities" e il plugin si distrugge. Opzioni del Transform: solo
`DitherControl = 0`; chiamata sincrona (`0x1d3becf18`, `x5 = 0`). Errore → "Rescaling error: 0x%X".

### 4.4 VideoToolbox

- `_FigRegisterIOSurfacePixelTransferCapabilityOnce` (`0x194cc85a4`): se
  `VTAvoidHardwarePixelTransfer()` o se `IOSurfaceAcceleratorCreate` fallisce (`0x194cc86d0`) **non
  registra** le capability hardware ⇒ VTPixelTransferSession usa i percorsi software. Se riesce,
  registra decine di coppie di formati (`VTRegisterPixelTransferCapability[MxN]`).
- `_figIOSurfaceAcceleratedPixelTransfer_TransferM2` (`0x194ccda9c`): opzioni
  `CustomFilter`, `ForceMaxSpeed` (ignorata), `DitherControl`, `Transform`, `Histogram*`; Transform
  **sincrono** (`x5 = 0`, `0x194cce8e0`, `0x194ccef00`), `SetCustomFilter`, `GetHistogram`.
- `SRSEnhancementFilter_*`: istanza SRS (non su A11).
- CoreMedia/CMPhoto/AVFoundation passano da qui per conversioni di formato/scala.

### 4.5 Altri

- **CMCapture** (`_FigSetupIOSurfaceAccelerator`, `BWPixelTransferNode`): TransferSurface
  **asincrona** con `_accelCompletionCallback` + run loop source in `kCFRunLoopCommonModes`;
  chiavi `LockInScaler`, `ForceMaxSpeed`, `SkipAsyncCallback`, `HDREnable`, `CommApi`, `CustomFilter`.
  Solo pipeline camera.
- **CMImaging** (`FigM2MController`): Transform (sync, flag interno `sync_m2m`), SetCustomFilter,
  istogrammi.
- **CoreRE** (`re::VideoHDRProcessor`): HDR video.
- **MobileIcons** (`_use_scaler_for_statistics` @ `0x1d4154c54`): crea l'acceleratore una volta e
  ritorna solo "esiste/non esiste" (+ GetServiceObject); nessun transfer.
- WebCore, Vision, AVD.videodecoder: l'estrazione automatica non ha trovato riferimenti diretti
  (nome immagine ambiguo per `ipsw`); non analizzati in dettaglio.

---

## 5. Codici di ritorno rilevanti

| Codice | Nome | Dove |
|---|---|---|
| `0x00000000` | kIOReturnSuccess | |
| `0xE00002BC` | kIOReturnError | GetHistogram senza capabilities; GetServiceObject arg NULL |
| `0xE00002BD` | kIOReturnNoMemory | SetFilterCoefficients malloc fallita |
| `0xE00002C0` | kIOReturnNoDevice | Create: servizio non trovato |
| `0xE00002C2` | kIOReturnBadArgument | validazioni lato utente (§2.5, §3) |
| `0xE00002C7` | kIOReturnUnsupported | ConfigurePerformanceStats su SRS |
| `0xE00002F0` | kIOReturnNotFound | GetFrameworkInfo |

---

## 6. Raccomandazione: sottoinsieme minimo per il port MT6781

### Opzione A — non pubblicare il servizio (zero lavoro, già funzionante)

Tutti i consumatori analizzati ripiegano. Costo: in backboardd ogni tentativo di
`copy_iosurface`/detach rifà `IOServiceGetMatchingService` e stampa
`"IOServiceMatchingfailed for: AppleM2ScalerCSCDriver"` su stderr; VideoToolbox usa conversioni
software (più lente per video/camera). ImageIO non ne risente.

### Opzione B — servizio minimo compatibile (consigliata se si vuole il detach/clone hardware o meno spam)

Classe `AppleM2ScalerCSCDriver : IOService`, `registerService()`, user client type 0 con:

| Selettore | Implementazione minima | Ritorno atteso |
|---|---|---|
| `registerNotificationPort(type 0)` | salvare la porta | `kIOReturnSuccess` |
| **1** (struct in 0x170, out 0) | validare dimensione esatta 0x170; risolvere `srcSurfaceID`/`dstSurfaceID` (lookup IOSurface nel task chiamante); eseguire la copia/scala/CSC (GPU Mali, DMA o anche CPU in kernel) per i formati che ci interessano (BGRA/RGBA 8888, NV12 420v/420f, eventualmente 10-bit); rect a zero = superficie intera; rispettare `Transform` (bit 0–2), `NearestFilter`, `ZeroFill`/`BorderFill` se semplice; ignorare gli altri bit. Se `callback != 0` e bit 0x400 non impostato: **sempre** inviare `sendAsyncResult64(ref{port, cb, refcon}, status, {refcon2}, 1)` dopo la fine, anche in caso di errore asincrono. | `kIOReturnSuccess`; `kIOReturnUnsupported` (0xE00002C7) per formati/combinazioni non gestite (i chiamanti ripiegano); `kIOReturnBadArgument` per ID non validi |
| 4 (struct 0x20) | accettare e (facoltativo) memorizzare; QuartzCore ignora l'esito | `kIOReturnSuccess` |
| 5 (0→1 scalar) | ritornare 0 | `kIOReturnSuccess` |
| 2, 3 | no-op (attendere i lavori pendenti se asincroni) | `kIOReturnSuccess` |
| 7 (1 scalar) | no-op | `kIOReturnSuccess` |
| 0, 8, 9 | non implementati | `kIOReturnUnsupported` |
| 6 / altri | — | `kIOReturnBadArgument` |

Proprietà da pubblicare: `IOSurfaceAcceleratorCapabilitiesDict` con almeno i limiti
Min/Max Source/Dest, Max Up/Downscale, `IOSurfaceAcceleratorFilterVertical/HorizontalTapsCount` e
`PhasesCount` (valori Apple per A11 [ignoti]; QuartzCore usa vTaps/hTaps/phases solo per costruire
il filtro custom, quindi valori piccoli tipo 4/16 vanno bene se il sel 4 viene ignorato), **senza**
`kSurfaceAcceleratorCapabilitiesColorManager`, `…HDR`, `…Accessibility`, `…DirectionalScaling`,
`kSurfaceAcceleratorCapabilitiesHistogramValues` (così ImageIO, HDR e istogrammi restano spenti),
e **senza** le chiavi `IOSurfaceAcceleratorFormat*2Planes*` se non si vuole il plugin AppleJPEG.
`PerformanceStats` facoltativa.

Attenzione: pubblicando il servizio VideoToolbox registra tutte le capability hardware e poi
manderà al selettore 1 molte combinazioni (YUV 4:2:0/4:2:2/4:4:4, 10-bit, rotazioni, istogrammi).
Ogni errore diventa un errore di `VTPixelTransferSessionTransferImage` (non c'è fallback
automatico per singola chiamata — [dedotto] dal ritorno diretto `0x194cce8e4` → `FigSignalErrorAt`).
Se lo scaler supporta solo pochi formati, valutare di **nascondere il servizio a VideoToolbox**
(es. `VTAvoidHardwarePixelTransfer`, [ignoto] come si attiva) oppure implementare tutti i formati.
Per il solo QuartzCore (detach/clone) bastano BGRA↔BGRA con scala e, per il video, NV12→BGRA.

---

## 7. Cose non determinabili staticamente e probe runtime suggerito

Da fare su un iPhone X stock (o su qualunque A11 con 16.x) e/o sul telefono con un servizio
"spia" che logga tutto:

1. `ioreg -l -w0 -c AppleM2ScalerCSCDriver` su A11 stock: valori reali di
   `IOSurfaceAcceleratorCapabilitiesDict` (taps/phases, limiti, HistogramValues, flag), presenza di
   `PerformanceStats`, `IOUserClientClass`.
2. Nel nostro user client spia, per ogni chiamata loggare: `pid`/nome processo, selettore, dimensioni
   in/out, e per il sel 1 il dump completo dei 0x170 byte + pixel format, dimensioni e attachment
   (`YCbCrMatrix`, primaries, transfer, chroma location) delle due IOSurface. Serve a fissare:
   - la semantica esatta dei bit 0–5 di `Transform` (direzione flip/rotazione),
   - quali bit di `flags` arrivano davvero da backboardd/mediaserverd,
   - se `callback != 0` arriva senza porta registrata,
   - i casi a rect nulli.
3. Contare quante volte backboardd chiama Create/selettore 1 durante animazioni normali (attesa: 0
   in composizione GPU pura; >0 solo con video a tutto schermo, mirroring, screenshot).
4. Verificare che il messaggio di completamento con 1 argomento (`refcon2`) faccia scattare
   `CA::WindowServer::transfer_complete` (breakpoint/log in backboardd) e che senza messaggio le
   superfici restino trattenute.
5. Semantica di `UnwireSurface`, `LockInScaler`, `OptOutBlitClip`, `VraScaling`, `HtpcLargeHeaders`,
   `ReadOnly`: [ignota]; per il port si possono ignorare.
6. Selettore 6 e il formato di `KernelTests` (0xFA8): [ignoti], nessun consumatore.
