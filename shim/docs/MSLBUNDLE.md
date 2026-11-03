# Shader precompilati: `.mslbundle` (driver 0.8.0)

## Cosa sono
Un `.mslbundle` contiene le traduzioni AIR → GLSL di cui un'app ha bisogno, già fatte e già verificate sul driver GL di
questa GPU. Il driver le prende da lì invece di tradurre a runtime: niente libLLVM, niente pass di pulizia, niente
traduzioni alla prima apertura, anche nelle app in sandbox, che hanno ciascuna la propria cache.

```
/Library/GPUBundles/TeraScaleMTLDriver.config/mslbundles/      (cartella dell'utente: niente sudo)
  com.apple.Spotlight.mslbundle/
    Info.plist                 BundleID, TranslatorTag, Shaders, Rescued, Failed, Built, Functions
    shaders/<sha256>.plist     { glsl, q }  (lo stesso record della cache su disco)
  com.apple.Maps.mslbundle/ ...
  system.mslbundle/            shader usati da più app + semi dei framework (CoreAnimation, RenderBox/SwiftUI)
```
`<sha256>` è l'hash degli input della traduzione: bitcode, qualificatori dei varying e bitcode delle funzioni
collegate (`TSMtlTranslationKey`). Il traduttore non fa parte dell'hash. Ne fa parte invece il `TranslatorTag`
del bundle, che contiene la revisione dei sorgenti del traduttore (`TS_TRANSLATOR_REV`, hash di
`src/TSAirTranslator.m` e `src/TSLLVM.h`, calcolato dal Makefile). Se il tag del bundle è diverso da quello del
driver, il bundle viene ignorato e il log lo dice. Il tag non dipende più dall'ora di build, quindi la cache su disco
sopravvive anche alle ricompilazioni che non toccano il traduttore.

## Ordine di ricerca nel driver (`TSShaderSource`, `src/TSMtlPipeline.m`)
1. GLSL registrato a mano (test)
2. cache in memoria
3. bundle dell'app: id della `.app` più esterna, così l'helper GPU di Chrome usa `com.google.Chrome`; poi il bundle id del processo; poi `system.mslbundle`
4. cache su disco
5. traduzione

`TSMTL_NO_MSLBUNDLE=1` salta i bundle (A/B). Il contatore `mslHits` (JSON delle statistiche, `tsmtl stats`) e la voce
`mslbundle hits` di `TSMTL_STATS=1` contano gli shader presi dai bundle.

## Da dove vengono gli shader: la registrazione
Il driver registra ogni traduzione che un'app gli chiede, una volta per coppia app+shader e solo gli input, nel
formato `{app, name, stage, bitcode, interp, linked}`. Il file sta accanto alla cache GLSL dell'app:
`<Caches>/com.terascale.mtlshim/rec/<sha>.bin`, oppure `com.apple.metal/tsmtl-rec-<sha>/functions0.data` nelle sandbox
che lasciano passare solo la cache di Metal. `TSMTL_RECORD=0` spegne la registrazione; i test lanciati da `make` non
registrano.

## Come si costruiscono
`tools/mslbundle` (`zsh system/mslbundle.sh` lo usa per tutti i passaggi):
- `list`: app e shader registrati, cercati in `~/Library/Caches`, in ogni container e sotto `DARWIN_USER_CACHE_DIR`.
- `build`: traduce ogni record con lo stesso traduttore del driver, compila il GLSL con il driver GL vero (anche
  nella variante con le IOSurface come texture rettangolo) e scrive un bundle per app più `system.mslbundle`. Il
  bundle viene sostituito in modo atomico. Se il GLSL della modalità normale non compila su questa GPU, il builder
  prova le altre modalità del traduttore (senza strutturazione, senza pass) e tiene la prima che compila. Questi
  shader vengono contati come `Rescued`: a runtime l'app avrebbe avuto lo shader di ripiego. Gli shader che non si
  traducono in nessun modo finiscono in `Failed`, con l'errore, e restano al traduttore a runtime.
- `try record.bin|dir [-v]`: traduce e compila dei record, per riprodurre un problema. `tools/airdump record.bin`
  stampa l'IR della funzione e di quelle collegate.
- `check`: dice se i bundle installati valgono per il traduttore attuale.

Semi di sistema: `tools/caglass` (il renderer Metal di CoreAnimation con `CARenderer` sul device dello shim, con
`NSGlassEffectView` e la barra laterale `NSVisualEffectView`) e `tools/rbglass` (vetro di SwiftUI disegnato da
RenderBox in un `drawingGroup`, il percorso di Spotlight). `system/mslbundle.sh seed` li esegue e poi compila i bundle.

`system/update.sh` ricompila i bundle subito dopo aver installato un driver nuovo: un bundle compilato da un altro
traduttore verrebbe ignorato.

## Misure (rbglass, 29 pipeline, cache su disco spenta)
| | senza bundle | con bundle |
|---|---|---|
| traduzioni | 41, 127 ms | 0 |
| creazione delle pipeline | 714 ms | 595 ms |
| link GL + warm-up | 239 + 411 ms | 242 + 409 ms |
| memoria (picco) | 53,6 MB | 51,6 MB |

Il bundle elimina tutto il lavoro sulla CPU che dipende da noi. Resta il tempo del driver GL (compilazione e link,
poi la compilazione differita al primo draw), che nessun formato precompilato può evitare: questo driver non
supporta i program binary (`GL_NUM_PROGRAM_BINARY_FORMATS = 0`). Il guadagno cresce con il numero di shader: Mappe ne
ha centinaia. Il secondo vantaggio è che ogni shader del bundle è già stato compilato su questa GPU, quindi gli
errori del compilatore GLSL non arrivano più all'app.
