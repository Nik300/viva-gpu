# Acceleratori dell'iPhone e cosa può sostituirli su MT6781 (2026-11-04)

# Stato (2026-11-05 sera)

Prima la domanda di partenza: **le animazioni lente non dipendevano da un acceleratore mancante.** Durante gli swipe
della home la GPU era occupata al 96% e il tempo per job scala con 1/frequenza GPU (limite di calcolo, non di DRAM):
il colpevole era il codice generato dal compilatore ISA diretto, 2,5-3 volte più lungo di quello di Mesa. Corretto
(`docs/ISA-COMPILATORE.md`, sezione Prestazioni): swipe della home da 36,5 a 27,2 ms per frame (27 → 37 fps), alla pari
col percorso NIR. Il reverse engineering di IOSurfaceAccelerator conferma che la composizione normale di CoreAnimation
**non passa dallo scaler** (serve per detach di layer su piani hardware, mirroring/clone, HDR, conversioni video).

| Voce | Stato | Dettagli |
|---|---|---|
| A. IOSurfaceAccelerator (`AppleM2ScalerCSCDriver`) | **kernel 0170: servizio completo, backend CPU** | ABI in `docs/ABI-IOSURFACEACCELERATOR.md`; `iokit/Kernel/arm/VivaScaler.cpp` (fork, patch 0170). Selettore 1 con notifica asincrona, BGRA/RGBA/ARGB con scala bilineare/nearest, NV12 (420v/420f) → RGB. Boot-arg `vivascaler` 0 (default, non pubblicato) / 1 CPU / 2 MDP con ripiego CPU; `vivascalerformats` per tenere fuori i formati che VideoToolbox non deve mandare. Backend MDP: accensione, clock, bypass M4U e instradamento RDMA0→WROT0 trovati sul telefono (`docs/MDP-MT6781.md` §10), contenuto scritto ancora sbagliato → segnaposto. |
| B. JPEG (`AppleJPEGDriver`) | **kernel 0170: encoder hardware jpgenc** | ABI in `docs/ABI-APPLEJPEGDRIVER.md`, registri in `docs/JPGENC-MT6781.md`; codifica NV12 validata a mano sul telefono (JFIF corretto). `VivaJPEGHW.cpp` + `VivaJPEG.cpp`: classe `VivaJPEGEncoder` con nome `AppleJPEGDriver`, la trova solo l'encoder di VideoToolbox (decodifica e CMPhoto restano software). 'yuvf' (YUYV) e '420f' (NV12). Boot-arg `vivajpeg`. |
| C. Video (`AppleAVD`/`AppleAVE2`) | **non realizzabile** | il kernel Linux di MT6781 (`mtk-vcu`) inoltra solo messaggi a `/dev/vpud`: la programmazione del decoder sta nel demone proprietario `vpud` di Android. |
| D. MPS / MPSGraph | **funziona** | `mpstest` sul telefono: blur, Sobel, Lanczos, conversione, matmul, MPSGraph tutti ok (MPSGraph: funzioni collegate da `MTLLinkedFunctions.privateFunctions`, puntatori in memoria privata divisi in valori). |

Pannello: Viva Manager > MaliMetal > Acceleratori (stato, interruttori del prossimo avvio, test scaler/JPEG/MPS).
Immagine di boot con 0170: `out/xnu-ufs-rw-0170.img` (stessa riga di comando della 0154, acceleratori spenti).

Prerequisito comune ad A (backend MDP), B e C resta un driver M4U (anche minimo, bypass come lo scanout).

---


Domanda: cosa ha questo SoC (Helio G96: Mali-G57 MC2 + blocchi multimediali MediaTek) per simulare l'hardware
dell'iPhone X (A11) che iOS usa (acceleratore JPEG, acceleratore IOSurface, ...), cosa no, quanto costa e come.

## 1. Cosa cerca iOS (dyld cache 20H392, stringhe dei servizi IOKit)

| servizio IOKit (A11) | cosa fa | chi lo usa (immagini nel dyld cache) | senza: |
|---|---|---|---|
| `AppleM2ScalerCSCDriver` | scaler + conversione colore (MSR): scala, ruota, converte YUV<->RGB e formati tra IOSurface (API `IOSurfaceAccelerator`) | IOSurfaceAccelerator, **QuartzCore**, ImageIO, AppleJPEG, CMPhoto, VideoToolbox, VideoProcessing, CMImaging, Portrait, VectorKit, AirPlay | alcuni percorsi hanno un fallback CPU (vImage), altri falliscono e basta |
| `AppleJPEGDriver` | decodifica/codifica JPEG hardware | CMPhoto, JPEGH1.videodecoder/encoder, MobileGestalt | AppleJPEG decodifica in software (CPU) |
| `AppleAVD` / `AppleVXD` | decodifica video H.264/HEVC | VideoToolbox | decoder software di VideoToolbox (CPU), quando esiste per quel profilo |
| `AppleAVE2Driver` | codifica video | VideoToolbox, ReplayKit, FaceTime | nessuna codifica hardware |
| `H11ANEIn` | Neural Engine | CoreML, Vision | CoreML ripiega su GPU/CPU |
| `AppleH10CamIn` | ISP / fotocamera | CMCapture | niente fotocamera (fuori scopo) |

## 2. Cosa ha MT6781 (DTB live)

| blocco | indirizzo | equivalente iPhone | note |
|---|---|---|---|
| **MDP**: `mdp_rdma0`, `mdp_rsz`/`rsz1`, `mdp_wrot0/1`, `mdp_tdshp0`, `mdp_aal0`, `mdp_hdr0`, `mdp_mutex` | 0x1b000000.. | **M2 Scaler/CSC** | lettura con conversione di formato (RDMA), ridimensionamento (RSZ), rotazione/flip e scrittura (WROT); YUV<->RGB, 420/422/BGRA/RGBA. È il pezzo giusto per `IOSurfaceAccelerator`. |
| `disp_rsz0`, `disp_ovl0/ovl0_2l`, `disp_ccorr/color/gamma/aal` | 0x14000000.. | pipeline display | già in uso per lo scanout (OVL) |
| **`jpgenc`** | 0x17030000 | metà di AppleJPEG (codifica) | **MT6781 non ha un decoder JPEG hardware** (in Android la decodifica JPEG è software, libjpeg-turbo) |
| `vdec` / `vdec_fmt` | 0x16000000 / 0x16080000 | AppleAVD | H.264/HEVC/VP9; il driver Linux (mtk-vcodec) dipende da firmware (VCU/SCP) e IPC |
| `venc` | 0x17000000, 0x17020000 | AppleAVE2 | H.264/HEVC, stessa dipendenza da firmware |
| `m4u` (5 istanze), `smi_larb*`, `gce_mbox` (CMDQ) | 0x14016000.., 0x1022c000 | DART + code di comandi | **prerequisito** di MDP/JPEG/codec: gli engine accedono alla memoria tramite IOMMU M4U (oppure in bypass con indirizzi fisici, come lo scanout) |
| nessun APU/MDLA | — | ANE | niente Neural Engine su Helio G96 |
| Mali-G57 MC2 | — | GPU | già usata via Metal (il nostro driver): può fare scala/CSC con shader |

## 3. Cosa si può simulare e come

### A. IOSurfaceAccelerator (`AppleM2ScalerCSCDriver`): conviene, priorità alta

Due backend possibili:

1. **MDP hardware nel kernel** (consigliato). Kernel IOService `AppleM2ScalerCSCDriver` con lo stesso ABI del
   user client (selettori e strutture di `IOSurfaceAcceleratorTransferSurface`, da ricavare dal dyld cache) e una
   pipeline RDMA -> RSZ -> WROT per trasferimento:
   - le IOSurface sono già fisicamente contigue sotto 4 GiB con `vivascanout=1`, quindi un primo passo può
     lavorare con M4U in bypass (come lo scanout) senza un driver IOMMU completo;
   - formati: BGRA/RGBA 8888, 420v/420f (NV12 video/full range), 422, 10 bit in un secondo tempo; matrici CSC
     601/709, range video/full;
   - asincrono con completamento a interruzione (MDP mutex/WROT done) e IOSurface "in uso" per tutta la durata.
2. **GPU Mali tramite un servizio userland** (alternativa o fallback). Un daemon che riceve le richieste da un
   kernel user client e le esegue con il nostro driver Metal (blit con scala e conversione via
   Gallium/u_blitter). È più flessibile sui formati ma ha più latenza (IPC + lavoro GPU), e la GPU è già il
   collo di bottiglia sulla home.

Piano (backend MDP):
1. RE dell'ABI: selettori del user client, struttura della richiesta, opzioni (crop, rotazione, CSC, dither),
   cosa si aspetta QuartzCore. Si può fare con il dyld cache estratto e un probe sul telefono che logga chi
   apre il servizio. **2-3 giorni.**
2. Stub kernel che risponde e fa la stessa operazione **con la CPU** (scala bilineare + CSC in NEON): sblocca
   subito i client che falliscono e dà un riferimento per i test. **2-3 giorni.**
3. Driver MDP: power domain MTCMOS (MDP), clock, MUTEX, RDMA/RSZ/WROT, larb/M4U in bypass, interrupt.
   Riferimento: Linux mtk-mdp3 / mdp_m4u downstream (Xiaomi viva-r-oss). **1-2 settimane.**
4. Formati e CSC (420v/420f/422/BGRA, 601/709), rotazione, tiling. **1 settimana.**
5. Test (confronto con lo stub CPU, pixel per pixel con tolleranza) e misure. **3-4 giorni.**

Totale: **circa 3-5 settimane** di lavoro, con il primo beneficio (stub CPU) dopo circa una settimana.

### B. JPEG (`AppleJPEGDriver`): solo la codifica è hardware

- **Decodifica**: MT6781 non ha un decoder JPEG hardware. Emularlo non ha senso (sarebbe CPU comunque).
  AppleJPEG ripiega già sul software. Con il DVFS della CPU (patch 0145) la decodifica sugli A76 è circa 1.9x
  più veloce di prima. In alternativa si può fare una decodifica ibrida GPU (Huffman sulla CPU, IDCT e
  conversione colore in compute shader), ma il guadagno è piccolo e il lavoro grande: **non consigliato**.
- **Codifica**: `jpgenc` può servire screenshot, foto e miniature. Serve l'ABI di AppleJPEGDriver (RE) e il driver
  jpgenc (Linux mtk_jpeg_enc_hw + M4U/bypass). **1.5-2 settimane**, guadagno modesto (la codifica JPEG non è sul
  percorso delle animazioni).

### C. Video (`AppleAVD` / `AppleAVE2`): possibile, ma è il lavoro più grande

- vdec/venc di MediaTek richiedono il firmware del coprocessore (VCU/SCP) e il suo protocollo IPC, oltre a M4U
  vero (buffer frammentati), alla gestione dei buffer di riferimento e alla conversione dei formati tile MTK
  (`vdec_fmt`). Poi bisogna implementare l'ABI di AppleAVD/AVE2 che VideoToolbox si aspetta (molto ricco).
- Stima: **2-3 mesi** per la sola decodifica H.264/HEVC. Nel frattempo VideoToolbox usa i decoder software, sulla
  CPU, dove esistono.

### D. Neural Engine: non c'è hardware

Helio G96 non ha APU/MDLA. CoreML ripiega su GPU/CPU. Da verificare: se MetalPerformanceShaders/MPSGraph (che
CoreML, Vision e CoreImage usano) funziona sul nostro driver Metal o si aspetta binari specifici delle GPU Apple.
Da qui dipende quanto lavoro GPU è davvero possibile per questi framework. Prima verifica: **1-2 giorni**.

## 4. Ordine consigliato

1. **IOSurfaceAccelerator**: prima lo stub CPU (1 settimana), poi MDP (2-4 settimane). È il servizio con più
   client, QuartzCore compreso.
2. Verifica di MPS/MPSGraph sul nostro driver (1-2 giorni): impatto su CoreImage, Vision, Foto.
3. Codifica JPEG hardware (jpgenc), solo se gli screenshot o le foto risultano lenti.
4. Video hardware: solo se serve davvero la riproduzione o registrazione video fluida.

Prerequisito comune a 1, 3 e 4: un driver M4U (anche minimo: bypass o pagine identità per i larb usati).
Per MDP e JPEG si può iniziare in bypass con memoria contigua, come lo scanout.
