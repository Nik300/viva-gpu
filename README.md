# viva GPU: Metal su Mali-G57 MC2 (Helio G96) per iOS 16

Driver Metal per iOS 16.7.16 su viva (Redmi Note 11 Pro 4G), costruito su Mesa (Gallium + Panfrost) partendo da
metal-shim. Piano generale: `../fork/docs/PIANO-GPU.md`. Questa cartella è un repository git a sé, separato da
`fork/`, per non interferire con il lavoro sul kernel (touch e così via).

**Stato (2026-11-03): tutto l'userspace è pronto e provato sul Mac; manca il driver di kernel (fasi G1-G2).**

## Architettura
```
App / framework iOS ─► Metal.framework ─► IOAcceleratorES "VivaGPUAccelerator" (kernel, da scrivere)
                                              MetalPluginName = VivaMTLDriver, MetalPluginClassName = VMDevice
                                                │
VivaMTLDriver.bundle ─ driver/metal/*.m   frontend Metal (device, risorse, pipeline, code, encoder)
                     ─ driver/vmg_*.c     back-end Gallium: vmg.h
                         ├─ vmg_air.c     AIR (bitcode di _MTLFunction, libLLVM di sistema) → NIR
                         ├─ Mesa statico  Panfrost (compilatore Valhall, driver Gallium) [llvmpipe solo sul Mac]
                         └─ libdrm-xnu ─► vgpu ─► IOKit (VivaGPUUserClient) │ mock in-process (Mac)
```

| Cartella | Contenuto |
|---|---|
| `uapi/` | contratto kernel ↔ userspace (`viva_gpu_uapi.h`) e la sua specifica (`README.md`): **cosa deve fare il kernel** |
| `vgpu/` | client del kernel: back-end IOKit (telefono) e mock (Mac); `test_vgpu` |
| `libdrm-xnu/` | le funzioni libdrm che usa Panfrost, implementate su vgpu (ioctl → selettori, IOSurface al posto di dma-buf, snapshot dei syncobj al posto dei sync file) |
| `mesa/` | Mesa 26.2.6: build statica (`build.sh macos`), patch (`patches/`), template iOS |
| `driver/` | back-end vmg (C), traduttore AIR → NIR, driver Metal (`metal/`), test e strumenti (`airnir`) |
| `ios/` | build per il telefono: `VivaMTLDriver.bundle` + test (serve l'SDK iOS) |
| `shim/` | metal-shim importato (back-end GL, riferimento e test) |

## Provare sul Mac
```sh
bash mesa/build.sh macos          # Mesa + libdrm-xnu + smoke test (~1 min)
make -C vgpu test                  # contratto sul mock: 28/28
make -C driver test metal          # back-end: llvmpipe 6/6, Panfrost sul mock 4/4
cd driver && for t in phase1 phase3 translate uploads compute; do out/macos/$t | tail -1; done
out/macos/airnir FILE.metal|FILE.metallib [-v] [funzione]      # AIR → NIR → driver (VMG_DRIVER=panfrost VGPU_BACKEND=mock)
```

Risultati (Apple Silicon, macOS 27), sui test di metal-shim e sui test nuovi:

| Test | llvmpipe | Panfrost sul mock |
|---|---|---|
| phase1 (device, risorse) | 43/44 (l'unico fallimento è voluto: il Mali ha memoria unificata) | nessun crash; i controlli che richiedono l'esecuzione GPU falliscono |
| phase3 (render: pipeline, varying, depth, texture, blend, MSAA) | **33/33** (= metal-shim GL) | nessun crash; job chain decodificate pulite con `pandecode` (`PAN_MESA_DEBUG=trace`) |
| translate (traduttore su shader veri) | **24/24** | come sopra |
| uploads (coerenza CPU/GPU) | **20/20** | come sopra |
| compute (threadgroup, atomiche, image write, griglie non uniformi) | **7/7** | come sopra |

Copertura del traduttore sulle librerie di sistema (identica con llvmpipe e con il compilatore Valhall per il G57):

| Libreria | Tradotte e compilate | Restano |
|---|---|---|
| corpus di metal-shim | 10/10 | — |
| QuartzCore | 194/240 | 46 kernel con imageblock (tile shading di Apple) |
| VectorKit | 331/340 | argument buffer / ICB (`air.indirect_buffer`), imageblock |

Variabili utili: `VMG_DRIVER=llvmpipe|panfrost`, `VGPU_BACKEND=mock|iokit`, `VMG_TRACE=1` (binding, shader,
sampler), `VMG_TRACE_NIR=1`, `TSMTL_LOG=1` (log del driver su stderr), `VMG_FEATURE_PROFILE`.

## Cosa manca per collegarlo al kernel
1. **Driver di kernel** (fasi G1-G2 del piano): servizio `VivaGPUAccelerator : IOAcceleratorES` e user client
   secondo `uapi/README.md`. Il lato userspace è già scritto e provato contro il mock.
2. **SDK iOS** (Xcode) per `ios/build.sh`: su questo Mac ci sono solo i Command Line Tools.
3. Prove sul telefono, rimaste dalla fase G0:
   - caricamento di un bundle fuori dalla shared cache;
   - profilo Apple4: il driver lo sceglie a runtime con `+[_MTLDevice featureProfile:supportsFeatureSet:]`;
   - cosa fa QuartzCore con `IOGPUDeviceCreate`.

   Offline è già verificato che `_limits`, `bitcodeData` e i selettori privati di code, command buffer ed encoder
   esistono in Metal di iOS 16. I limiti si scrivono per nome dalla codifica di tipo dell'ivar.

## Lacune note del driver (prossimi passi lato userspace)
- Argument buffer (tier 1) e ICB: non tradotti (pipeline senza draw, segnalate nel log).
- Imageblock / tile shader (Apple4): non esistono su Valhall.
- `newBufferWithBytesNoCopy`: su Panfrost oggi copia. Servono `IMPORT_USERPTR` nel kernel (già nel contratto) e
  `resource_from_handle` per i buffer in Panfrost.
- Formati XR10 resi come RGBA16F; PVRTC e YUV non ancora gestiti.
- Le pipeline si traducono in modo sincrono sulla coda GPU; servono la cache su disco dei binari NIR/Valhall e la
  precompilazione delle librerie di sistema, analoga alle `.mslbundle` di metal-shim.
