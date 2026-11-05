# ABI AppleJPEGDriver (codec JPEG hardware) — iOS 16.7.16, 20H392, iPhone10,3 / A11

Reverse engineering statico del dyld shared cache
`research-dsc/20H392__iPhone10,3_6/dyld_shared_cache_arm64` con `ipsw` (2026-11-05).
Tutti gli indirizzi sono VA nel cache (slide 0) e si possono ricontrollare con
`ipsw dyld disass <dsc> --vaddr <addr> --count N`.

Scopo: implementare sul port XNU per MT6781 un IOService compatibile che offra **solo la
codifica** JPEG (l'MT6781 ha un encoder JPEG hardware, nessun decoder), senza rompere la
decodifica: tutti i client devono continuare a decodificare in software.

Legenda affidabilità: **[certo]** = letto direttamente nel codice; **[dedotto]** = inferito
da come i chiamanti usano il valore; **[ignoto]** = non determinabile staticamente (vedi §10).

Documento gemello: `ABI-IOSURFACEACCELERATOR.md` (scaler M2, usato anche dal plugin di
resize di AppleJPEG.framework).

---

## 0. Riassunto per chi ha fretta

| Voce | Valore |
|---|---|
| Nome cercato | `"AppleJPEGDriver"`. **Due modi di matching diversi**: l'encoder VideoToolbox usa `IOServiceNameMatching` (nome dell'entry), tutti gli altri (decoder VideoToolbox, CMPhoto, MobileGestalt) usano `IOServiceMatching` (classe). |
| `IOServiceOpen` type | sempre `0`. |
| Shared memory | **nessuna**: nessun client importa `IOConnectMapMemory`, `IOConnectCallScalarMethod` o `IOConnectCallAsync*`. Solo `IOConnectCallStructMethod` (+ `IOConnectSetNotificationPort` per la decodifica asincrona). |
| Selettori usati | **1** decode (struct in 0x58 / out 0x58) · **3** encode (0x58 / 0x58) · **4** encode "ext" con tabelle di quantizzazione (0x1000 / 0x1000) · **5** decode "ext" (0x1000 / 0x1000). 0, 2, ≥6 mai usati. |
| Buffer | sempre **ID di IOSurface** (+ dimensione di allocazione) dentro la struct: sorgente e destinazione. Nessun puntatore utente. Il bitstream JPEG viene scritto dal kernel nella IOSurface destinazione a partire dall'offset 0; la lunghezza ritorna in `out+0x10`. |
| Encode | sempre **sincrono** (nessuna callback). Codice speciale `kIOReturnOverrun` (0xE00002E8) = buffer di uscita troppo piccolo → i client ritentano con qualità più bassa o buffer più grande. |
| Decode | sincrono, oppure asincrono con callback nella struct (+0x30/+0x38/+0x40) e notifica `kIOAsyncCompletionNotificationType` sulla porta registrata con `IOConnectSetNotificationPort(conn, 0, port, 0)`. |
| Proprietà registry lette | `AppleJPEGRequiresMCUAlignment` (encoder VT), `AppleJPEGNumCores`, `AppleJPEGSupportsAppleInterchangeFormats`, `AppleJPEGSupportsMissingEOI`, `AppleJPEGSupportsRSTLogging` (CMPhoto / decoder VT). Tutte lette con `IORegistryEntryGetProperty` e **richiedono esattamente 4 byte**. |
| MobileGestalt | una sola domanda booleana con chiave offuscata `m+FD6mX8VZzP95hOhM+jow` = "esiste un servizio di classe AppleJPEGDriver" (§6). |
| Software | ImageIO e AppleJPEG.framework **non** parlano mai col driver: decodifica/codifica di `UIImage`/`CGImageSource`/`CGImageDestination` resta software comunque (eccetto il percorso UIKit di §5.4). |
| Raccomandazione | **Fase 1**: pubblicare un servizio che si *chiama* `AppleJPEGDriver` ma ha classe diversa → lo vede solo l'encoder VideoToolbox, nessun decoder lo trova. **Fase 2** (encode delle foto della fotocamera via CMPhoto): classe `AppleJPEGDriver`, selettori 1/5 rifiutati con `kIOReturnUnsupported`; i client principali ripiegano sul software, alcuni percorsi CMPhoto "solo hardware" no (§7). |

---

## 1. Client nel cache

Ricerca di stringhe (`ipsw dyld str … AppleJPEGDriver`): la stringa compare **solo** in 4 immagini.

| Immagine | Stringa | Funzione che la usa |
|---|---|---|
| `/System/Library/VideoEncoders/JPEGH1.videoencoder` | `0x20519ee70` | `_H1JPEGEncoder_CheckExistance` (`0x20519cc1c`), `_H1JPEGEncoder_CreateInstance` (`0x20519cd04`) |
| `/System/Library/VideoDecoders/JPEGH1.videodecoder` | `0x1f0f38f1d` | `__initalizeService` (`0x1f0f38558`) |
| `CMPhoto.framework` | `0x1a5e27de9` | `__initalizeService` (`0x1a5d99058`) |
| `libMobileGestalt.dylib` | `0x19c5b9534` | funzione anonima `0x19c5754c0` |

`AppleJPEG.framework` (codec software Apple, `EmbeddedAppleJPEG-192`) importa solo
`IOServiceMatching`/`IOSurfaceAccelerator*` per lo scaler M2: **non usa il driver JPEG**.
ImageIO usa direttamente `applejpeg_*` (software) e non importa le API JPEG hardware di CMPhoto.

Consumatori indiretti (importano API CMPhoto che a loro volta possono usare il driver):
MediaToolbox (wrapper `FigPhotoJPEG*` → `CMPhotoJPEG*`, `FigPhotoCompression*`), CMCapture e
AVFCapture (`CMPhotoCompressionSession*` = foto della fotocamera), MediaAnalysis, UIKitCore
(`CMPhotoJPEGDecodeSession*` in `_UIOldCGImageDecompressor`), ChatKit, IMTranscoderAgent
(`IMEmbeddedHardwareJPEGTranscoder` → `CMPhotoJPEGCreateIOSurfaceFromJPEG` /
`CMPhotoJPEGCreateJPEGFromIOSurface`), Photos/PhotosFormats/VectorKit/AppleCV3D (solo
`CMPhotoDecompressionSession*`).

---

## 2. Ricerca e apertura del servizio

### 2.1 Encoder VideoToolbox (`JPEGH1.videoencoder`)

`_JPEGH1EncoderRegister` (`0x20519cb70`): chiama `_H1JPEGEncoder_CheckExistance`; **solo se
ritorna vero** registra `_H1JPEGEncoder_CreateInstance` per i codec `'jpeg'` (0x6A706567,
`0x20519cb8c`) e `'sjpg'` (0x736A7067, `0x20519cb9c`) con `VTRegisterVideoEncoder`. [certo]

`_H1JPEGEncoder_CheckExistance` (`0x20519cbc0`):
`IOMasterPort` → `IOServiceNameMatching("AppleJPEGDriver")` (`0x20519cc20`) →
`IOServiceGetMatchingServices`; esiste ⇔ la chiamata ritorna 0 (`0x20519cc3c`). Nota: con
`GetMatchingServices` "ritorna 0" vale anche con iteratore vuoto [dedotto: in pratica il
plugin si registra comunque; il controllo vero è in CreateInstance].

`_H1JPEGEncoder_CreateInstance` (`0x20519cc58`):
1. `IOServiceNameMatching("AppleJPEGDriver")` (`0x20519cd08`), `IOServiceGetMatchingServices`,
   **primo** elemento con `IOIteratorNext` (`0x20519cd30`).
2. `IOServiceOpen(service, mach_task_self(), 0, &connect)` (`0x20519cd50`).
3. Errore (nessun servizio / open fallita) → ritorna **-8888** (`0xFFFFDD48`, `0x20519cda4`)
   e l'istanza non viene creata.
4. Successo: storage+0x1C = service, +0x20 = connect (`0x20519ce30`); poi legge
   `IORegistryEntryGetProperty(service, "AppleJPEGRequiresMCUAlignment", buf, &size=4)`
   (`0x20519cdcc`): se ritorna 0 **e** `size == 4` → flag = `buf[0]` (primo byte), altrimenti
   flag = **1** (`0x20519cde8`). Flag salvato in storage+0x50.

Finalize (`0x20519ce38`): `IOServiceClose(connect)`, `IOObjectRelease(service)`.

**Conseguenza per il kernel**: `IOServiceNameMatching` produce `{IONameMatch = "AppleJPEGDriver"}`
che confronta il **nome** dell'entry (`IORegistryEntry::getName`, di default il nome della classe,
modificabile con `setName()`), non la classe.

### 2.2 Decoder VideoToolbox (`JPEGH1.videodecoder`) e CMPhoto

Codice quasi identico nei due (CMPhoto ne contiene una copia):

`__initalizeService` (decoder VT `0x1f0f38528`, CMPhoto `0x1a5d99028`), eseguito una volta per
processo con `pthread_once`:
- `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleJPEGDriver"))`
  (`0x1f0f3855c`/`0x1a5d9905c`) → globale `__jpegService` (il servizio **non** viene mai
  rilasciato).
- `IORegistryEntryGetProperty(service, "AppleJPEGNumCores", &n, &size=4)`; se ok e size==4,
  `__numberOfJPEGCores = n` (`0x1f0f385b0`). Se `n ≥ 2` → semaforo da `n` (accesso concorrente),
  altrimenti mutex ricorsivo `__jpegLock` (`0x1f0f385dc`).

`__openDriverConnection` (`0x1f0f3863c` / `0x1a5d888f0`): se `__jpegService != 0`,
`IOServiceOpen(service, mach_task_self(), 0, &c)`; ritorna `c` oppure 0.
`__openService` / `__closeService`: lo stesso con acquisizione del semaforo/mutex attorno
(una sola richiesta per "core" alla volta, lato utente). Le funzioni `JPEGDeviceInterface_*`
ricevono un `connect` già aperto oppure 0 = "apri, chiama, chiudi" (`0x1f0f38700`).
Se l'open fallisce ritornano `kIOReturnNotOpen` (0xE00002CD, `0x1f0f38734`, `0x1a5dde390`).

Il registro del decoder VT è **incondizionato**: `_JPEGH1Register` (`0x1f0f36010`) registra
`'jpeg'`, `'dmb1'` (0x646D6231) e `'sjpg'` sempre. Senza servizio `StartSession` fallisce con
-12913 `kVTVideoDecoderNotAvailableNowErr` (`0x1f0f36f04`) [certo]; VideoToolbox passa allora
al decoder software (`JPEGVideoDecoder` / `AppleJPEGVideoDecoder` dentro VideoToolbox)
[dedotto]. `VTAvoidHardwareJPEGDecoders` (`0x194ef4380`) è una costante `return 0` su iOS.

### 2.3 Riepilogo di cosa deve esistere nel kernel

- Un `IOService` `registerService()`-ato. Con **classe** `AppleJPEGDriver` lo trovano tutti;
  con classe diversa ma `setName("AppleJPEGDriver")` lo trova solo l'encoder VT (§8).
- `newUserClient` che accetta `type == 0`.
- `externalMethod` per i selettori 1, 3, 4, 5 (struct in / struct out).
- `registerNotificationPort(port, type 0, refCon 0)` (solo se si implementa il decode asincrono;
  i client non controllano il valore di ritorno di `IOConnectSetNotificationPort`,
  `0x1f0f36bf0`, `0x1a5d724d4`).

---

## 3. Codifica

### 3.1 Struct di richiesta comune (selettore 3, 0x58 byte) [certo salvo dove indicato]

Stessa forma per entrambi i client (VT: `fp-0xC0` in `_jpeg_encodeFrameSync` `0x20519dc54`;
CMPhoto: `sp+0x150` in `__createJPEGFromCVPixelBuffer` `0x1a5df3e00…`). La struct è azzerata
prima del riempimento. Little-endian.

| Off | Tipo | Campo | VT (indirizzo) | CMPhoto (indirizzo) |
|---|---|---|---|---|
| 0x00 | u32 | `srcSurfaceID` (`IOSurfaceGetID`) | `0x20519deac` | `0x1a5df3e08` |
| 0x04 | u32 | `srcAllocSize` (`IOSurfaceGetAllocSize`) | `0x20519ded4` | `0x1a5df3e20` |
| 0x08 | u32 | `dstSurfaceID` | `0x20519deb8` | `0x1a5df3e14` |
| 0x0C | u32 | `dstAllocSize` | `0x20519dee0` | `0x1a5df3e2c` |
| 0x10 | u32 | sempre 0 | — | — |
| 0x14 | u32 | larghezza immagine | `0x20519dec4` | `0x1a5df3e34` |
| 0x18 | u32 | altezza immagine | idem | `0x1a5df3e3c` |
| 0x1C | u32 | **livello di qualità** (preset hardware, §3.4) | `0x20519dec8` | `0x1a5df3e5c` |
| 0x20 | u32 | **flag** (§3.3) | `0x20519dee4` (= 1) | `0x1a5df3e60` |
| 0x24 | u32 | crop: x di partenza nella sorgente | 0 | `0x1a5df3e58` (se crop) |
| 0x28 | u32 | crop: y di partenza | 0 | idem |
| 0x2C | u32 | **formato croma** dell'uscita: 0=4:2:0, 1=4:2:2, 2=4:4:4, 3=4:1:1, 4=grigio [dedotto dalla tabella `0x1a5e25ac0` e dal parser SOF del decoder `0x1f0f37964…`] | 0 per `'jpeg'`, 1 per `'sjpg'` (`0x20519defc`) | `0x1a5df3e70` |
| 0x30 | 3×u64 | callback / refcon / arg — **solo decode**, 0 in encode | 0 | 0 |
| 0x48 | u32 | id di richiesta per `kdebug_trace` (solo diagnostica) | 0 | `[sp+0xa0]` |
| 0x4C–0x53 | — | usati solo in decode (§4) | 0 | 0 |
| 0x54 | u32 | = 1 in CMPhoto, 0 in VT. Se ≠0 e `AppleJPEGSupportsRSTLogging` e `w·h > 3 000 000`, CMPhoto mette a 1 il campo ext +0x58 (`0x1a5dde178`–`0x1a5dde1b4`). Significato [ignoto]: probabilmente "abilita restart marker". | — | `0x1a5df3e68` |

### 3.2 Struct "ext" (selettore 4, 0x1000 byte in, 0x1000 out)

Usata quando il client fornisce tabelle di quantizzazione proprie. I primi 0x58 byte sono
**identici** alla struct del §3.1 (copia 1:1, `0x1a5dde2a4`–`0x1a5dde2c8`), poi:

| Off | Tipo | Campo |
|---|---|---|
| 0x20 | u32 | flag: in più il **bit 3 (0x8) = "tabelle custom presenti"** (`0x1a5dde304`, `0x1a5d6af94`) |
| 0x58 | u32 | "RST logging" (0/1) (`0x1a5dde30c`, `0x1a5d6af6c`) |
| 0x5C | u8[64] | tabella di quantizzazione **luma** (`0x1a5dde2d4`, `0x1a5d6af80`) |
| 0x9C | u8[64] | tabella di quantizzazione **croma** (`0x1a5dde2ec`, `0x1a5d6af90`) |
| 0xDC–0xFFF | — | zero |

Le tabelle sono 64 byte ciascuna (es. `_sAppleQualityQMArray_Luma` @ `0x1a5e25b4f`,
`_Chroma` @ `0x1a5e25ccf`, passo 0x40) [certo sulla dimensione; ordine zig-zag o naturale
**[ignoto]**].

Chi usa il selettore 4:
- `JPEGDeviceInterface_encodeJPEGExt` (`0x1a5d6f5dc`) chiamata da `__encodeBuffer`
  (`0x1a5d6aff0`): è il percorso del **`CMPhotoCompressionSession`**, cioè delle foto della
  fotocamera (CMCapture/AVFCapture) e di MediaToolbox/MediaAnalysis. Usa **sempre** le tabelle
  (bit 3 forzato, `0x1a5d6af94`) e `+0x1C = 0`.
- `JPEGDeviceInterface_encodeJPEG` (`0x1a5dde128`, percorso `CMPhotoJPEGEncodeSession` /
  `CMPhotoJPEGCreateJPEGFromCVPixelBuffer`) usa il selettore 4 se ha tabelle o se deve
  attivare l'RST logging, altrimenti il **3** (`0x1a5dde360`).
- L'encoder VideoToolbox usa **solo il 3**.

### 3.3 Bit di `flags` (+0x20)

| Bit | Significato | Fonte |
|---|---|---|
| 0 (0x1) | VT: sempre 1. CMPhoto: opzione `kCMPhotoCompressionOption_IncreaseRoundingPoint` / `"JPEGIncreaseRoundingPoint"` (`0x1a5d6af18`, `0x1a5df3de0`). [dedotto: arrotondamento della quantizzazione] |
| 3 (0x8) | tabelle custom in +0x5C/+0x9C (solo selettore 4) |
| 4 (0x10) | `kCMPhotoCompressionOption_ForceHighSpeed` / `"JPEGHighSpeedEncode"` (`0x1a5d6af34`, `0x1a5df3dec`) [dedotto: clock massimo] |

Il kernel può ignorare i bit 0 e 4.

### 3.4 Qualità

**VideoToolbox** (`_jpeg_encodeFrameSync` `0x20519dcfc`–`0x20519ddb8`): proprietà
`kVTCompressionPropertyKey_Quality` (float 0..1, unica proprietà supportata; default
interno 0.85 ma il flag "impostata" resta 0). Livello:

```
se Quality non impostata            -> 4
x = (int)(144 / (1 + 32·q³) + 0.5)
x == 144 -> 0 ; x > 90 -> 1 ; x > 72 -> 2 ; x > 18 -> 3 ; x > 7 -> 4 ; x ≥ 5 -> 5 ; x < 5 -> 6
'sjpg' senza rate controller        -> 7
```
Quindi **livello più alto = qualità più alta** (q=1 → 6, q=0.85 → 5, q=0 → 0).

**CMPhoto** `CMPhotoJPEGEncodeSession` (`0x1a5df3f2c`–`0x1a5df3f38`): stesso campo; sul
`kIOReturnOverrun` decrementa (con il valore speciale 9 che riparte da 4) — il valore 9 è
usato insieme alle tabelle custom [dedotto]. `CMPhotoCompressionSession`: +0x1C = 0, la qualità
è tutta nelle tabelle.

Per l'MT6781 serve una tabella livello → qualità del jpgenc MTK, ad es.
0→~40, 1→~55, 2→~65, 3→~75, 4→~85, 5→~92, 6→~97, 7→~97 [proposta, non verificata].
Con tabelle custom (selettore 4) il kernel può stimare la qualità dalla tabella luma (ad es.
media dei coefficienti vs tabella standard IJG) se l'hardware non accetta tabelle arbitrarie.

### 3.5 Sorgente: formati pixel e allineamento

**VideoToolbox** (`_H1JPEGEncoder_StartSession` `0x20519d160`) impone gli attributi del pool di
pixel buffer in ingresso:

| `AppleJPEGRequiresMCUAlignment` | Formati accettati | Altri attributi |
|---|---|---|
| assente o `≠0` (default) | solo **`'yuvf'`** (4:2:2 packed YUYV full range, 0x79757666) | `ExtendedPixelsRight = (-w)&15`, `ExtendedPixelsBottom = (-h)&7` (padding all'MCU 16×8), `ExactBytesPerRow = [w+padR, w+padR]`, `PlaneAlignment = 0x20` (`0x20519d2fc`–`0x20519d3cc`) |
| `0` | `'420f'` (+ `'444f'` solo per `'sjpg'`) + `'yuvf'` | `PlaneAlignment = 0x10`, `BytesPerRowAlignment = 0x20` (`0x20519d3fc`–`0x20519d43c`) |

Nota: `ExactBytesPerRow = w+padR` per un formato a 2 byte/pixel sembra incoerente
(**[ignoto]** se CoreVideo lo interpreta in pixel); verificare al runtime.
Prima di ogni frame, se il buffer ha pixel estesi, `CVPixelBufferFillExtendedPixels`
(`0x20519de8c`).

`'sjpg'` (`0x20519d4c4`…): la sorgente `'444f'` viene impacchettata in un buffer `'yuvf'`
largo **2·w** (`_Copy_444_yuvz_arm`) e codificata con `+0x2C = 1`; la format description
d'uscita usa `out.width >> 1` (`0x20519dfb8`). È un trucco per avere 4:4:4 con un encoder
4:2:2 [dedotto].

**CMPhoto** (`__encodeBuffer` `0x1a5d6aaf0`–`0x1a5d6ad84`): usa la IOSurface del
`CVPixelBuffer` direttamente se formato e sottocampionamento sono compatibili (`'420f'`,
`'422f'`, `'444f'`, `'yuvf'`/`'yuvs'`, RGBA/BGRA), altrimenti converte prima con
`CMPhotoScaleAndRotateSession` in `'444f'`/`'420f'`/`'422f'` (tabella `"f444f024f224f224"` @
`0x1a5e25ab0`). Prima della richiesta chiama `IOSurfaceBindAccel(src, 0, 0)` (risultato
ignorato). Le RGB/YCbCr non-601 pongono restrizioni [dedotto: `kCVImageBufferYCbCrMatrix`
diversa da 601 disabilita il passaggio diretto].

Matrice colore, range: **nessun campo** nella struct; il kernel li deduce dalla IOSurface
(pixel format; i formati `f` sono full range BT.601).

### 3.6 Destinazione e risultato

- VT: IOSurface creata da `_createJPEGOutputSurface` (`0x20519da38`): `kIOSurfaceIsGlobal =
  true`, `kIOSurfacePixelFormat = 'JPEG'` (0x4A504547; `'yuvf'` per `'sjpg'`),
  `kIOSurfaceCacheMode = 0x400` (0x500 per `'sjpg'`), `AllocSize = round_page(level < 6 ?
  2·w·h/3 : 2·w·h)` con minimo 0x8000. Due surface in coda, ricreate più grandi se il livello
  sale a 6.
- CMPhoto: surface "di memoria" da `CMPhotoSurfacePoolCreateMemorySurface`, dimensione
  `max(round_page(hint), 0x8000)` (`0x1a5d6ae0c`–`0x1a5d6ae5c`).
- Uscita (out struct, stessa dimensione dell'ingresso):

| Off | Campo | Chi lo legge |
|---|---|---|
| 0x10 | **byte scritti** (JPEG completo, da offset 0 della surface destinazione) | VT `0x20519df2c`/`0x20519dfdc`; CMPhoto `0x1a5d6b140` |
| 0x14 | larghezza codificata | VT → `VTEncoderSessionCreateVideoFormatDescription` (`0x20519dfa4`) |
| 0x18 | altezza codificata | idem |

Il client copia `out.0x10` byte dall'indirizzo base della surface (`IOSurfaceLock` +
`IOSurfaceGetBaseAddress`, `0x20519e014`–`0x20519e02c`) e li emette così come sono: il kernel
deve produrre un **file JFIF completo (SOI … EOI)** [dedotto]. CMPhoto poi rianalizza lo stream
con `CMPhotoJFIFScanner` (marker, restart marker per la tabella AROT) e ci aggiunge EXIF/MPF
da sé.

### 3.7 Errori e ritentativi

| Ritorno del selettore | VideoToolbox | CMPhoto `CompressionSession` | CMPhoto `JPEGEncodeSession` |
|---|---|---|---|
| 0 | frame emesso | ok, `DidUseHW = 1` (`0x1a5d6b1b0`) | ok |
| **0xE00002E8** `kIOReturnOverrun` | se `dstAllocSize ≥ out.0x10` → ritenta con livello−1 fino a 0; se `dstAllocSize < out.0x10` → errore (`0x20519df24`–`0x20519df58`) | politica (§3.8): abbassa qualità (max 10 tentativi) / ingrandisce il buffer a `max(round_page(2·w·h), 1.5·alloc)` / errore | abbassa il livello e ritenta (`0x1a5df3f04`–`0x1a5df3f3c`) |
| altro | errore del frame (**nessun fallback software**) | modo "auto": **ripiega sul software** (`__encodeSW`, `0x1a5d6b418`–`0x1a5d6b428`) | se `JPEGSoftwareFallback` (default vero) → software via `CGImageDestination` (`0x1a5df3f70` → `0x1a5df2c08`) |

Quindi in caso di overrun il kernel deve ritornare 0xE00002E8 con `out.0x10 ≤ dstAllocSize`
(ad es. i byte effettivamente scritti o la capacità), altrimenti VT tratta l'overrun come errore.

### 3.8 Modi hardware/software in CMPhoto

`__encodeImageForIndex` (`0x1a5d6bf38`–`0x1a5d6bf88`) traduce le opzioni in `hwMode`
(argomento salvato a `[sp+0x3c]` di `__encodeBuffer`):

| `hwMode` | Opzione | Comportamento |
|---|---|---|
| 0 | nessuna | hardware se `sHWAvailable`, **fallback software se l'hardware fallisce** |
| 1 | `kCMPhotoCompressionOption_PreferSoftwareCodec` | solo software |
| 2 | `kCMPhotoCompressionOption_RequireHardwareCodec` | solo hardware; errore -16994 se assente |

`sHWAvailable` (`____isHWAvailable_block_invoke` `0x1a5defcec`) = "`IOServiceOpen` riuscita",
calcolato una volta per processo (apre e chiude subito una connessione).
`CMPhotoUnifiedJPEGEncoderEncodeStripToStream` passa un `hwMode ≠ 0` [certo che è ≠0, valore
dal chiamante] e non ha fallback. Politica overrun (`[sp+0x9c]`): 0 = abbassa qualità
(foto), 1 = ingrandisci buffer (strip/`__dispatch_encode`), 2 = errore.

---

## 4. Decodifica (da rifiutare)

### 4.1 Selettore 1 — 0x58 in / 0x58 out

`JPEGDeviceInterface_decodeJPEG` (VT `0x1f0f386b8`, CMPhoto `0x1a5d772b8`):
`IOConnectCallStructMethod(c, 1, in, 0x58, out, &0x58)`.

| Off | Campo | Fonte (decoder VT `_H1JPEGVideoDecoder_DecodeFrame`) |
|---|---|---|
| 0x00 / 0x04 | ID / alloc size della surface **sorgente** (bitstream, pixel format `'JPEG'`, `IsGlobal`, creata da `_jpeg_createSurfaceFromBBuf` `0x1f0f37b38`) | `0x1f0f37248`, `0x1f0f37278` |
| 0x08 / 0x0C | ID / alloc size della surface **destinazione** (pixel buffer del pool VT) | `0x1f0f37254`, `0x1f0f37284` |
| 0x14 / 0x18 | larghezza / altezza della destinazione | `0x1f0f37260` |
| 0x1C | 0 | `0x1f0f37288` |
| 0x20 | flag: 1, salvo decodifica `kVTDecodeFrame_1xRealTimePlayback` di immagini ≤ 720×480 (=0) [dedotto: "boost"] | `0x1f0f37290`–`0x1f0f372b0` |
| 0x2C | sottocampionamento dal SOF0: 0=4:2:0 (0x22), 1=4:2:2 (0x21), 2=4:4:4 (0x11), 3=4:1:1 (0x41), 4=grigio (1 componente) | `0x1f0f37964`–`0x1f0f379e8`, `0x1f0f372b4` |
| 0x30 | callback (0 = sincrono) | `0x1f0f372d8` (`_jpeg_asyncDecodeComplete`) |
| 0x38 | refcon | idem (storage del decoder) |
| 0x40 | argomento passato alla callback | `0x1f0f372dc` (contesto `calloc(0x30)`) |
| 0x48 | id kdebug (CMPhoto) | — |
| 0x4C / 0x50 | larghezza / altezza d'uscita | `0x1f0f372c0`, `0x1f0f372cc` |

Asincrono (solo codec `'sjpg'` nel decoder VT, `JPEGDecompressSurfaceAsync` in CMPhoto):
porta registrata con `IOConnectSetNotificationPort(c, 0, IONotificationPortGetMachPort(p), 0)`
(`0x1f0f36bf0`), consegna su dispatch queue (`IONotificationPortSetDispatchQueue`). La callback
ha forma `void cb(void *refcon, IOReturn result, void *arg)` → il kernel dovrebbe fare
`sendAsyncResult64(ref{port, in.0x30, in.0x38}, status, {in.0x40}, 1)` (stesso schema di
IOSurfaceAccelerator). **Per un servizio encode-only non serve**: basta ritornare errore in
modo sincrono; in quel caso nessun client attende la notifica (VT emette subito l'errore,
`0x1f0f375b0`).

### 4.2 Selettore 5 — 0x1000 in / 0x1000 out

`JPEGDeviceInterface_decodeJPEGExt` (CMPhoto `0x1a5dde02c`), chiamato da `JPEGDecompressSurface`
(`0x1a5d720d4`). Primi campi come il selettore 1; in più crop/scala in +0x54…+0x6C, e un
percorso "parallelo" a 2 strisce (+0x70…+0x80, offset dei restart marker) usato solo se
`AppleJPEGNumCores ≥ 2` **e** `AppleJPEGSupportsRSTLogging` (`0x1a5d72158`–`0x1a5d72198`).
L'uscita +0x14/+0x18 viene restituita al chiamante. Il codice `kIOReturnNotAligned`
(0xE00002D0) provoca un secondo tentativo con un'altra surface sorgente (`0x1a5d713a8`):
**non usarlo** per rifiutare.

### 4.3 Come i client scelgono decode vs encode

Non c'è un selettore di "modalità" né un tipo di `IOServiceOpen` diverso: encode e decode usano
la stessa connessione (type 0) e si distinguono solo per il selettore. Il kernel quindi
**non può** rifiutare il decode al momento dell'open senza rifiutare anche l'encode dello stesso
processo.

---

## 5. Comportamento dei client se il servizio manca o se il decode fallisce

### 5.1 Encoder VideoToolbox

- Servizio assente (per nome) → `'jpeg'`/`'sjpg'` hardware non registrati [dedotto da
  `0x20519cb80`]; VT usa un altro encoder registrato per `'jpeg'` se esiste (**[ignoto]**:
  VideoToolbox non contiene un encoder JPEG software; potrebbe non esserci alternativa →
  `VTCompressionSessionCreate('jpeg')` fallisce, come oggi sul telefono).
- Errore di encode → errore del frame, nessun fallback.

### 5.2 Decoder VideoToolbox (`JPEGH1.videodecoder`)

- Servizio assente: `StartSession` → -12913, VT passa ai decoder software [dedotto].
- Servizio presente: in `StartSession` crea comunque una **sessione software annidata**
  (`VTDecompressionSessionCreate` con `EnableHardwareAcceleratedVideoDecoder = false`,
  `0x1f0f36dc8`–`0x1f0f36e2c`). Per `'jpeg'`/`'dmb1'`, se il selettore 1 fallisce il frame va
  alla sessione software (`0x1f0f37550` → `0x1f0f37114`) e dopo il primo successo software il
  flag `+0xF0` rende **permanente** il software per quella sessione (`0x1f0f38238`).
  ⇒ rifiutare il selettore 1 costa **una** chiamata fallita per sessione. **[certo]**
- `'sjpg'`: nessun fallback (errore emesso). Codec raro.
- Solo baseline: se non trova un SOF0 (0xFFC0) il primo frame fallisce con -12910
  (`0x1f0f378dc`) prima di arrivare al driver.

### 5.3 CMPhoto — decoder "unificato" (`CMPhotoDecompressionSession`)

Usato da Photos, MediaToolbox, CMCapture, UIKit (container), VectorKit…
`CMPhotoUnifiedJPEGDecoderShouldUseHWForOperation` (`0x1a5d8ff2c`): hardware solo se
(operazione == 2) oppure (dimensione sopra la soglia **e** `sHWAvailable` **e**
`AppleJPEGSupportsAppleInterchangeFormats ≠ 0`). Se la decodifica hardware fallisce, rifà
`__prepare` in modo software e decodifica con `applejpeg_*` (`0x1a5d71560`–`0x1a5d715a0`).
⇒ Con `AppleJPEGSupportsAppleInterchangeFormats` assente/0 non tocca il driver (salvo op 2), e
comunque ripiega. **[certo]**

### 5.4 CMPhoto — `CMPhotoJPEGDecodeSession` (UIKit, ChatKit, MediaToolbox)

- `CMPhotoJPEGDecodeSessionCreate` (`0x1a5df81f0`) apre `numberOfJPEGCores` connessioni; se
  l'open fallisce ritorna -16071 (`0x1a5df850c`) → nessuna sessione.
- `fjds_createPixelBufferFromJPEGData` (`0x1a5df8630`) è **solo hardware**: se
  `JPEGDeviceInterface_supportsDecodeSize` è falso → -16076; se il driver fallisce → errore.
  Nessun fallback interno.
- `supportsDecodeSize` (`0x1a5d7cc3c`): con AIF=1 sempre vero; altrimenti vero se il
  sottocampionamento è 0..4 e le dimensioni superano minimi piccoli (8/16/32 px) — cioè **quasi
  sempre vero**.
- UIKitCore `-[_UIOldCGImageDecompressor _decompressEagerly:]` (`0x189c9d140`): crea una sessione
  globale `_jpegDecodeSessionRef` una volta; se esiste, decodifica in modo asincrono e attende;
  se la callback non segnala successo (flag 0x10, `0x189c9db44`), prosegue nel ramo software
  `CGImageSource`/`_UIImageRefFromData` (`0x189c9d538` → `0x189c9d5fc`). ⇒ UIKit ripiega
  [dedotto dal flusso, da verificare al runtime].
- ChatKit, MediaToolbox (`FigPhotoJPEGDecodeSession*`): comportamento sul fallimento
  **[ignoto]**.

### 5.5 CMPhoto — API "dirette"

`CMPhotoJPEGCreateCGImageFromJPEG` (`0x1a5dc5318`), `CMPhotoJPEGCreateIOSurfaceFromJPEG`
(`0x1a5dc3c74`), `CMPhotoJPEGDecodeJPEGIntoSurface` (`0x1a5dc56b4`): se `_jpegService == 0`
ritornano subito errore (il chiamante deve avere un suo software); se il servizio c'è usano
**solo** l'hardware (`__createPixelBufferFromJPEG` → `JPEGDecompressSurface`, errore propagato,
`0x1a5dc4b54`). `CMPhotoJPEGShouldUseHardwareDecode` (`0x1a5dc5a58`) dice "sì" se il servizio
esiste e l'immagine supera 0x40000 pixel (senza AIF) / 0x10000 (con AIF). Usati da ChatKit,
IMTranscoderAgent (trascodifica allegati iMessage) e dai wrapper `FigPhotoJPEG*` di
MediaToolbox. È il **rischio principale** della Fase 2 (§7).

### 5.6 MobileGestalt

Vedi §6: oggi (servizio assente) risponde `false`.

---

## 6. MobileGestalt

`libMobileGestalt.dylib`, funzione `0x19c5754c0`:
`IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleJPEGDriver"))`,
`IOObjectRelease`, ritorna `service != 0`. È referenziata dalla tabella delle domande a
`0x1d73330a8` (voce `{0x19c5b4b7e, 0x19c5754c0}`), chiave offuscata
**`m+FD6mX8VZzP95hOhM+jow`** (= `base64(md5("MGCopyAnswer" + nome))[:22]`; il nome in chiaro
**[ignoto]**: provati ~220 000 nomi plausibili con "JPEG", nessuna corrispondenza; formula
verificata con `UniqueDeviceID` → `re6Zb+zwFKJNlkQTUeT+/w`). È l'unica domanda MG legata al
JPEG hardware; usa il matching per **classe**, quindi con la Fase 1 resta `false`.
Chi la interroga **[ignoto]** (nessun client nel cache usa la stringa offuscata come
letterale CFString cercabile in modo semplice).

---

## 7. Proprietà registry da pubblicare

Tutte lette con `IORegistryEntryGetProperty(service, key, buf, &size)` con `size = 4` in
ingresso e controllo `ret == 0 && size == 4` in uscita (`0x20519cdd8`, `0x1f0f3859c`,
`0x1a5d9d29c`). Quindi pubblicarle come `OSNumber` a 32 bit (o `OSData` di 4 byte);
`OSBoolean`/`OSString` producono un `size` sbagliato e vengono ignorate.

| Chiave | Letta da | Default se assente | Valore consigliato per MT6781 |
|---|---|---|---|
| `AppleJPEGRequiresMCUAlignment` | encoder VT (solo `buf[0]`) | 1 | assente (=1 → solo `'yuvf'`, padding 16×8, che l'MTK jpgenc gestisce come YUYV) oppure 0 per accettare anche NV12 `'420f'` |
| `AppleJPEGNumCores` | decoder VT, CMPhoto | 0 (≤1 = mutex) | **assente o 1** (≥2 abilita il decode parallelo) |
| `AppleJPEGSupportsAppleInterchangeFormats` | CMPhoto | 0 | **assente** (tiene il decoder unificato in software e alza le soglie) |
| `AppleJPEGSupportsMissingEOI` | CMPhoto (`__createPixelBufferFromJPEG`) | 0 | assente |
| `AppleJPEGSupportsRSTLogging` | CMPhoto | 0 | assente |

Nessuna proprietà dichiara formati, dimensione massima o "decoder presente": la presenza del
servizio equivale a "encoder **e** decoder presenti". Limiti di dimensione non vengono letti
dal driver; CMPhoto ha soglie sue (`_g_cutOffJPEG`, `CMPhotoJPEGGetMaximumHardwareOutputDimensions`).

---

## 8. Sottoinsieme minimo per un servizio encode-only

### Fase 1 — solo VideoToolbox (raccomandata per iniziare: zero impatto sulla decodifica)

- Classe kernel con nome **diverso** (es. `VivaJPEGEncoder : IOService`), `setName("AppleJPEGDriver")`
  prima di `registerService()`. La trova solo `IOServiceNameMatching` (encoder VT); decoder VT,
  CMPhoto e MobileGestalt usano `IOServiceMatching` per classe e non la vedono ⇒ tutta la
  decodifica e la codifica CMPhoto restano software esattamente come oggi.
- User client type 0, `externalMethod`:

| Sel | Implementazione | Ritorno |
|---|---|---|
| 3 | validare `inSize == 0x58` e `outSize ≥ 0x58`; lookup `srcSurfaceID`/`dstSurfaceID` nel task chiamante (non richiedere surface globali: le surface d'ingresso dal pool VT non lo sono); accettare `'yuvf'` (YUYV full range) e, se `RequiresMCUAlignment = 0`, `'420f'` (NV12); dimensioni da +0x14/+0x18 (la surface può avere padding a 16×8); livello +0x1C → qualità MTK; scrivere JFIF completo all'offset 0 della destinazione; `out.0x10 = byte`, `out.0x14/0x18 = w/h` | 0 |
| 3 (buffer pieno) | `out.0x10 = min(byte, dstAllocSize)` | `0xE00002E8` |
| 3 con `+0x2C == 1` (`'sjpg'`) | opzionale: codificare la sorgente 2w-wide come 4:2:2 | oppure `kIOReturnUnsupported` |
| 1, 5 | non chiamati in Fase 1 | `kIOReturnUnsupported` (0xE00002C7) |
| 4 | non chiamato in Fase 1 | `kIOReturnUnsupported` |
| altri | — | `kIOReturnBadArgument` |

Attenzione: VT **non** ha fallback software sull'errore di encode; ogni errore diventa un frame
fallito. Se un formato non è gestito meglio non pubblicare il servizio.

### Fase 2 — anche CMPhoto (foto della fotocamera)

Classe `AppleJPEGDriver` (o nome + classe). In più rispetto alla Fase 1:

| Sel | Implementazione |
|---|---|
| **4** | indispensabile: `CMPhotoCompressionSession` usa **solo** il selettore 4 con tabelle custom. Leggere +0x5C/+0x9C (64 B) e programmarle nell'hardware se possibile, altrimenti stimare la qualità; accettare `'420f'` e `'yuvf'`/`'yuvs'`, rifiutare (`kIOReturnUnsupported`) `'444f'`, `'422f'` 2-plane, RGB → CMPhoto in modo auto ripiega sul software per quella foto. Crop +0x24/+0x28. |
| 1, 5 | rifiutare **subito** con `kIOReturnUnsupported` (0xE00002C7). Mai `0xE00002D0` (provoca un ritentativo) né `0xE00002E8`. Se `in.0x30 ≠ 0` (async) ritornare l'errore in modo sincrono e **non** mandare notifiche. |

Effetti sulla decodifica con la Fase 2 (servizio visibile per classe):

| Client | Effetto | Esito |
|---|---|---|
| VT `JPEGH1.videodecoder` `'jpeg'`/`'dmb1'` | 1 chiamata fallita per sessione, poi software | ok [certo] |
| VT `'sjpg'` | errore | rotto (raro) |
| `CMPhotoDecompressionSession` (Photos, MediaToolbox, CMCapture…) | con AIF assente non usa l'hardware; se lo usa ripiega | ok [certo] |
| UIKit `_UIOldCGImageDecompressor` | HW fallisce → `CGImageSource` | ok [dedotto] |
| `CMPhotoJPEGDecodeSession` in ChatKit / `FigPhotoJPEGDecodeSession` | errore propagato | **[ignoto]** |
| `CMPhotoJPEGCreateCGImageFromJPEG` & co. (ChatKit, IMTranscoderAgent, `FigPhotoJPEG*`) | `ShouldUseHardwareDecode` dice sì per immagini > 0x40000 px, poi errore | **rischio** [ignoto se i chiamanti ripiegano] |
| MobileGestalt `m+FD6mX8VZzP95hOhM+jow` | diventa `true` | [ignoto chi la usa] |

Quindi la Fase 2 va abilitata solo dopo il probe di §10 punto 3. Non esiste un modo di rendere
il servizio "visibile per classe" solo ai processi della fotocamera: il registry è globale, e
rifiutare l'`IOServiceOpen` per processo non aiuta perché le API CMPhoto di §5.5 decidono
"hardware" già dalla sola presenza del servizio e poi falliscono con `kIOReturnNotOpen`.
Finché il probe non è fatto, l'alternativa sicura resta la Fase 1.

---

## 9. Codici di ritorno rilevanti

| Codice | Dove |
|---|---|
| `0xE00002E8` kIOReturnOverrun | encode: buffer d'uscita insufficiente → ritentativi (§3.7) |
| `0xE00002CD` kIOReturnNotOpen | generato lato utente se `IOServiceOpen` fallisce dentro `JPEGDeviceInterface_*` |
| `0xE00002D0` kIOReturnNotAligned | decode ext: ritentativo con un'altra surface (CMPhoto `0x1a5d713a8`) |
| `0xE00002C7` kIOReturnUnsupported | consigliato per rifiutare decode e formati non gestiti |
| -8888 | encoder VT: servizio non trovato / open fallita |
| -12913 / -12910 | decoder VT: driver assente / JPEG non baseline |
| -16994, -16071, -16076 | CMPhoto: HW richiesto ma assente / open sessione decode fallita / dimensione non supportata |

---

## 10. Cose non determinabili staticamente e probe runtime suggerito

1. `ioreg -l -w0 -n AppleJPEGDriver` su un A11 stock: classe reale, `IOUserClientClass`,
   valori di `AppleJPEGNumCores`, `AppleJPEGRequiresMCUAlignment`,
   `AppleJPEGSupportsAppleInterchangeFormats`, `…MissingEOI`, `…RSTLogging`.
2. User client "spia" sul telefono (Fase 1): loggare processo, selettore, i 0x58/0x1000 byte e il
   pixel format/dimensioni/bytesPerRow delle due surface. Fissa: significato di +0x54, ordine
   delle tabelle Q (zig-zag?), se il bitstream atteso include già APP0/JFIF, bit di +0x20,
   comportamento di `ExactBytesPerRow` con `'yuvf'`.
3. Prima della Fase 2: registrare il servizio con classe `AppleJPEGDriver` che rifiuta 1/5 e
   verificare a mano: anteprime in Messaggi (ChatKit), allegati iMessage (IMTranscoderAgent),
   `UIImage(data:)` di JPEG grandi in un'app di prova, Foto. Se qualcuno mostra immagini vuote,
   restare alla Fase 1.
4. Nome in chiaro della chiave MobileGestalt `m+FD6mX8VZzP95hOhM+jow` e chi la consulta
   (breakpoint su `MGGetBoolAnswer`/`MGCopyAnswer` filtrando la stringa).
5. Se esiste un encoder VT software per `'jpeg'` (cioè cosa succede oggi a
   `VTCompressionSessionCreate(kCMVideoCodecType_JPEG)` sul telefono).
6. `'sjpg'`: quale framework lo usa davvero (sospetto foto spaziali/stereo, non A11).
