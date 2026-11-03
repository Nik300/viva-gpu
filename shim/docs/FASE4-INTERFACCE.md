# Fase 4 – Contratto tra kext, bundle e app di controllo

Questo file fissa nomi, percorsi e formati condivisi da:
- **bundle** del driver Metal (`TeraScaleMTLDriver.bundle`, codice in `src/`), caricato da Metal.framework dentro le app;
- **kext** Lilu `TSMetalEnabler.kext` (codice in `kext/`), iniettato da OpenCore;
- **app di controllo** `TeraScale Metal.app` + comando `tsmtl` (codice in `gui/`).

## Percorsi
| Cosa | Percorso | Proprietario |
|---|---|---|
| Bundle del driver | `/Library/GPUBundles/TeraScaleMTLDriver.bundle` (eseguibile `Contents/MacOS/TeraScaleMTLDriver`, classe principale `TSMtlDevice`, id `com.terascale.mtldriver`) | root:wheel, 755 |
| Cartella di configurazione | `/Library/GPUBundles/TeraScaleMTLDriver.config/` | l'utente (giulia:staff), 755 |
| Policy per app | `/Library/GPUBundles/TeraScaleMTLDriver.config/policy.plist` | l'utente, 644 |
| Kext | `EFI/OC/Kexts/TSMetalEnabler.kext` sulla EFI (disk0s1), id `com.terascale.TSMetalEnabler` | |
| App di controllo | `/Applications/TeraScale Metal.app` (id `com.terascale.mtlshim.monitor`) | l'utente |
| Comando | `/usr/local/bin/tsmtl` (script che chiama l'eseguibile dell'app) | |
| TeraScale Glass: shader | `/Library/GPUBundles/TeraScaleMTLDriver.config/glass/glass.glsl` (+ `glass.plist`), scritti da `tools/glassgen` | l'utente, 644 |
| TeraScale Glass: stato | `/var/tmp/TeraScaleGlass/` (`DISABLE`, `starts`, `status.plist`) | 0777 senza sticky: la scrivono sia `_windowserver` sia l'utente |
| TeraScale Swift: interruttore | `/var/tmp/TeraScaleSwift/DISABLE` (`tsmtl swift kill`) | l'utente, senza sudo; letto all'avvio di ogni processo |

Perché `/Library/GPUBundles`: Metal cerca `<MetalPluginName>.bundle` con `gpu_bundle_find_trusted` (libsystem_sandbox) prima in
`/Library/GPUBundles` e poi in `/System/Library/Extensions`. Con la SIP di OCLP (0x803, filesystem non protetto) il controllo di
"fiducia" accetta il percorso, quindi il volume di sistema sigillato non si tocca. Il profilo `system-graphics` delle sandbox consente
la lettura (e quindi anche la mappatura del codice) di tutto `/Library/GPUBundles`: anche la cartella di configurazione è leggibile
dalle app in sandbox.

Per i test senza installazione: variabile `TSMTL_CONFIG_DIR=<cartella>` (vale per bundle, app e `tsmtl`).

## policy.plist
```
Version     integer  1
AutoEnable  bool     true   ; "auto su tutte": lo shim è attivo per ogni app nelle cartelle Applicazioni, salvo eccezioni
Apps        dict     chiave = id dell'app, valore = dict:
              Enabled  bool     attiva/disattiva lo shim per questa app (vince su AutoEnable)
              Name     string   nome da mostrare (facoltativo)
              Path     string   percorso del bundle .app (facoltativo)
Spoof       dict     facoltativo, letto dal **kext** (sezione Spoofing dell'app):
              Auto   bool    true = spoofing automatico su Safari, Chrome e i processi WebKit
              Model  string  modello da far vedere (predefinito "iMac19,1")
              Apps   dict    chiave = id dell'app, valore = dict:
                       Enabled  bool    attiva/disattiva lo spoofing per questa app (vince su Auto)
                       Match    string  sottostringa del percorso dell'eseguibile (per un .app: "<percorso .app>/")
                       Name, Path       facoltativi, per l'interfaccia
System      dict     facoltativo (sezione Sistema dell'app, docs/PIANO-GLASS.md, docs/PIANO-COMPUTE.md):
              Compute  dict    TeraScale Compute (compute Metal come passate GL o su OpenCL 1.2), letto dal **bundle**:
                Enabled  bool    false = spento salvo le app dell'elenco; assente o true = acceso per tutte le app
                                 in cui lo shim è attivo (predefinito true dalla 0.10.0)
                Apps     dict    chiave = id dell'app, valore = dict: Enabled (vince su Compute.Enabled), Name, Path
              Glass  dict    TeraScale Glass, il vetro di Apple nel compositore di WindowServer (Moraea):
                Enabled  bool    true = il **kext** lascia entrare il bundle in WindowServer e il **bundle** sostituisce lo
                                 shader del vetro di Moraea (predefinito false)
                Trial    dict    facoltativo: Deadline (integer, secondi Unix: niente <date>, che OSUnserializeXML
                                 del kext non conosce e che gli rende illeggibile tutto il file). Passata la data,
                                 il componente torna al vetro di Moraea
                                 (anche mentre gira); `tsmtl glass confirm` toglie Trial
              Swift  dict    TeraScale Swift, l'acceleratore delle ricerche di conformità del runtime Swift, letto dal
                             **bundle** all'avvio di ogni processo che lo carica (dalla 0.12.0) e dall'app di controllo:
                Enabled  bool    false = spento salvo l'elenco; assente o true = acceso in tutti i processi, salvo
                                 l'elenco e i processi critici (predefinito true dalla 0.12.2, false prima)
                Validate bool    true = ogni risposta rapida viene confrontata con il runtime (che ha l'ultima parola)
                                 e le differenze vanno nel log (`last-mismatch=`); predefinito false
                Apps     dict    chiave = id dell'app (anche `proc:<nome>`), valore = dict: Enabled (vince su
                                 Swift.Enabled e sui processi critici), Name, Path
Experimental dict    obsoleto: `Experimental.Compute` (stesso schema di `System.Compute`) è dove i driver fino alla
              0.9.0 leggevano il compute, con predefinito spento. Il bundle 0.10 lo legge ancora quando manca
              `System.Compute`; l'app, se il file lo contiene, lo riscrive uguale a `System.Compute` (per un driver
              vecchio ancora installato). Da togliere dopo la 0.10.
```
Regole automatiche del kext (id → sottostringa): `com.google.Chrome` → `/Google Chrome.app/`, `com.apple.Safari` →
`/Safari.app/`, `com.apple.WebKit` → `/WebKit.framework/` (servizi XPC GPU/WebContent di WebKit, condivisi da tutte le app con
una vista web). Ordine: voci con `Enabled = false` che corrispondono → niente spoofing; poi voci con `Enabled = true`; poi, se
`Auto`, le regole automatiche. Per spegnere una regola automatica basta una voce con lo stesso id e `Enabled = false` (senza
`Match` il kext usa la sottostringa della regola automatica). Il kext rilegge il file quando cambia (al massimo una volta al
secondo), con le credenziali del kernel, quindi vale anche nei processi in sandbox. Il file deve restare in **XML** e senza `<date>` (`OSUnserializeXML` non li conosce: tutto il file risulterebbe assente).
Effetto: solo la proprietà `model` di `IOPlatformExpertDevice` letta da quei processi (è quella che usa ANGLE; `hw.model` non conta).

**Id dell'app** = `CFBundleIdentifier` del bundle `.app` più esterno (fuori da ogni `.app`: del bundle `.xpc`) che contiene l'eseguibile del processo
(così helper, XPC service ed estensioni dentro `Chrome.app` o `Maps.app` seguono l'app). Per eseguibili fuori da ogni `.app`:
`proc:<nome dell'eseguibile>`.

**Decisione del bundle** (in `-[TSMtlDevice initWithAcceleratorPort:]`, una volta per processo):
1. processi critici, non modificabili dalla policy: `WindowServer`, `loginwindow`, `Dock`, `SystemUIServer`, `ControlCenter`,
   `NotificationCenter`, `WallpaperAgent`, `WindowManager` → **spento** (il kext rifiuta già il caricamento in questi processi);
2. voce in `Apps` con `Enabled` → quel valore;
3. `AutoEnable` vero e app in `/Applications`, `/System/Applications`, `~/Applications`,
   `/System/Volumes/Preboot/Cryptexes/App/System/Applications` → **acceso** (motivo `auto`);
   Eccezione: `com.apple.WebKit.GPU` (processo GPU di WebKit, cioè il WebGL di Safari e delle viste web) segue `AutoEnable` come un'app.
4. altrimenti → **spento** (motivo `outside`: demoni, agenti, servizi di sistema; si accendono solo con una voce in `Apps`).

Senza file o con file illeggibile: `AutoEnable = true`, `Apps` vuoto. Le modifiche valgono per le app avviate dopo.

**Decisione del compute** (`TSMtlComputeEnabled`, una volta per processo, al primo compute pipeline): `TSMTL_COMPUTE=0/1`
nell'ambiente (prove) → quel valore (motivo `env`); shim spento → spento (`shim-off`); voce in `System.Compute.Apps`
con `Enabled` → quel valore (`list`); `System.Compute.Enabled` → quel valore (`global`); altrimenti acceso (`default`;
fino alla 0.9.0 spento). Senza `System.Compute` si usa `Experimental.Compute` con le stesse regole.
Spento = `initWithAcceleratorPort:` restituisce `nil` e l'app vede 0 device Metal, come oggi.

**TeraScale Glass** (`src/TSGlass.m`). In WindowServer il device Metal resta spento (processo critico); il bundle avvia solo
il componente del vetro, e solo se: il kext l'ha lasciato caricare (`System.Glass.Enabled`), il file `DISABLE` non c'è,
`System.Glass` è acceso e la prova (se c'è) non è scaduta, la guardia sui crash non è scattata (3 avvii senza 2 minuti di
vita in mezzo → scrive `DISABLE`), `glass.glsl` esiste. Il file `DISABLE` e la policy vengono ricontrollati ogni secondo:
spegnere vale subito, senza riavvio (al primo uso di ogni programma lo shader torna quello di Moraea, rilinkato al
suo posto con le stesse location e gli stessi valori delle uniform). `status.plist`: `PID`, `State` (`active|off`),
`Detail`, `Replaced` (programmi di Moraea che usano lo shader di Apple), `Failed`, `Off`, `Date`.
**TeraScale Swift** (`src/TSSwift.m`, `src/swift/`, docs/OTTIMIZZAZIONE-SWIFT.md). Il costruttore del bundle, in ogni
processo con il runtime Swift, decide una volta: `TSMTL_SWIFT=0/1` nell'ambiente (prove) → quel valore (`env`); voce in
`System.Swift.Apps` con `Enabled` → quel valore (`list`); processo critico → spento (`critical`);
`System.Swift.Enabled` → quel valore (`global`); altrimenti acceso (`default`; fino alla 0.12.1 spento). Lo shim Metal dell'app non conta: vale
anche dove lo shim è spento (le estensioni degli sfondi). Con `/var/tmp/TeraScaleSwift/DISABLE` presente resta spento
(`kill-switch`). Acceso = scrive il proprio puntatore nelle variabili di override di `swift_conformsToProtocol`,
`…2` e `…Common` di libswiftCore (solo dati; se una vale già un altro puntatore non tocca nulla: `unhooked`).

Lato app (`src/TSGlassSidebar.m`): nelle app AppKit che caricano il bundle, con `System.Glass` acceso e senza `DISABLE`
(deciso all'avvio dell'app), sotto ogni barra laterale (`NSBlurryAlleywayView`) va un `NSVisualEffectView` behind-window
ridotto al backdrop, che mostra il desktop sfocato come Tahoe. Indipendente dallo shim Metal dell'app. Nei processi
AppKit senza NSApplication (helper GPU di Chrome, agenti) non crea mai l'applicazione: lavora solo con `NSApp` esistente.

## Log (os_log)
Subsystem `com.terascale.mtlshim`. Tutte le stringhe sono `%{public}`.
| Categoria | Livello | Contenuto | Filtro nell'app |
|---|---|---|---|
| `unimplemented` | default | funzione Metal non implementata o resa no-op (catch-all, compute, ICB, ...), una volta per processo e funzione | "Non implementate" |
| `error` | error | errore in una funzione implementata (traduzione fallita → shader di ripiego, errore GL, framebuffer incompleto, ...) | "Errori" |
| `warning` | default | funzione implementata in modo ridotto (formato sostituito, stencil separato ignorato, ...) | "Avvisi" |
| `general` | info | eventi normali (device pronto, cache, traduzioni) | "Generali" |
| `policy` | default | una riga per processo: `policy: on|off id=<id> reason=<auto|list|critical|outside|nopolicy> name=<nome> path=<percorso app>` | "Generali" + elenco "app viste" |
| `stats` | default | JSON su una riga (sotto), non mostrato nel log | — |
| `glass` | default | TeraScale Glass: avvio o motivo dello spegnimento, contesti agganciati, `program N now runs Apple's <shader>`, shader che non compilano (con ritorno a Moraea), spegnimento a caldo | "Glass" |
| `swift` | default | TeraScale Swift: una riga per processo all'avvio, accesa o no: `on|off|unhooked <nome> pid= reason=<env|list|critical|global|default|kill-switch> hooks= validate= version= launchMode= preoptimized= cacheOverridden= images= sinceStart= hookable=` (fatti della fase 0); se acceso, `stats <nome> pid= t=15s|60s|300s fast= nominal= conditional= class= structural= fastMs= deferred= deferredMs= deferredNo= deferredNoMs= mismatches= indexMs= indexKB= protocols= records=` (+ `last-mismatch=<tipo> : <protocollo>`) | "Swift" |
| `compute` | default | TeraScale Compute: `compute: on|off id=<id> reason=<env|shim-off|list|global|default> version=<driver>` (una per processo), percorso di ogni kernel (`runs as a GL pass`, `runs on OpenCL: built in …`, `does not run: …`), dispatch saltati con il motivo, errori OpenCL | "Compute" |

Lettura: `/usr/bin/log stream --style ndjson --level info --predicate 'subsystem == "com.terascale.mtlshim"'` (storico: `log show`).
Con `TSMTL_LOG=1` le stesse righe vanno anche su stderr (prove con l'iniezione).

## Statistiche per processo
Il bundle scrive la riga `stats` ogni secondo, solo per i processi con un device attivo e solo quando qualcuno guarda:
lo stato del nome Darwin notify `com.terascale.mtlshim.stats` contiene l'ora Unix (secondi) dell'ultimo "rinnovo"; il bundle scrive
se `ora - stato < 5`. L'app (o `tsmtl stats`) rinnova ogni 2 s con `notify_register_check` + `notify_set_state` **seguiti da
`notify_post`** (il post sveglia i processi: senza, il bundle non sa che qualcuno guarda), e all'uscita mette lo stato a 0 e fa un ultimo `notify_post`.
Il bundle non interroga nulla quando nessuno guarda: si registra con `notify_register_dispatch` e avvia il timer da 1 s solo dopo un post con lease valido.

JSON (valori dell'ultimo secondo, salvo dove indicato):
```
{"v":1,"pid":123,"app":"com.apple.Maps","name":"Maps","fps":29.8,"draws":1234,"passes":80,"cmdbufs":60,
 "gpuBusy":0.21,"bufKB":512,"texKB":2048,"readbacks":0,"translations":0,"links":0,"fallbacks":0,
 "pipelines":153,"memMB":96.5,"drawableWaitMs":700,"dispatches":0,"clRuns":0,"computeRejected":0}
```
`dispatches` (kernel eseguiti, GL e OpenCL) e `clRuns` (sottomissioni OpenCL) per secondo; `computeRejected` totale corrente.
`gpuBusy` = frazione del secondo in cui la coda GL dello shim ha lavorato; `fallbacks`, `pipelines` e `memMB` sono totali correnti.

## Statistiche della GPU (senza shim)
`IOAccelerator` della Radeon (`AMDTurksGraphicsAccelerator`). Misurato su questo Mac:
- **`PerformanceStatistics` si azzera a ogni lettura** (di chiunque: `ioreg`, Monitoraggio Attività, ...): restituisce quanto
  accumulato dalla lettura precedente. Va letta invece **`PerformanceStatisticsAccum`**: stessi campi, cresce leggendola da sola e
  ricomincia da zero solo quando qualcuno legge `PerformanceStatistics` (un delta negativo = azzeramento da parte di altri).
- **`Device Utilization %` non è un carico**: vale 100 anche a GPU ferma. Carico = delta di `hardwareWaitTime` (ns) / tempo trascorso
  (con un carico sintetico: 5% → 7-12%, 20% → 20-28%, 50% → 46-58%).
- **VRAM in uso = `inUseVidMemoryBytes`**. `vramFreeBytes` vale sempre 256 MB − `inUseSysMemoryBytes` − 139328 B: segue la memoria
  di sistema, non la VRAM.
- Altri campi utili: `inUseSysMemoryBytes`, `gartUsedBytes`, `gartSizeBytes`, `textureCount`, `surfaceCount`, `contextGLCount`,
  `bufferSwapCount` e `HWChannel PM4 | Commands Completed` (contatori → al secondo).
VRAM totale: `VRAM,totalMB` (256) sul nodo della GPU; nome: `model` = "AMD Radeon HD 6750M".

## Stato del kext
Il kext pubblica, sull'acceleratore della Radeon: `MetalPluginName = "TeraScaleMTLDriver"`, `MetalPluginClassName = "TSMtlDevice"`.
Sul proprio servizio (classe `TSMetalEnabler`, sotto `IOResources`): `TSVersion` (string), `TSAcceleratorPatched` (bool),
`TSLVHook` (string: `installed` o il motivo per cui la deroga non c'è), `TSLVAllowed` (numero di caricamenti del bundle consentiti in deroga alla library validation), `TSSpoof` (`installed` o motivo), `TSSpoofCount`, `TSSpoofLastProcess`, `TSLVRefused` (rifiutati perché il
processo è critico; dalla 1.2 WindowServer è consentito quando `System.Glass.Enabled` è vero), `TSLVLastProcess` (string). Boot-arg: `-tsmtloff` spegne tutto il kext, `-tsmtlnolv` solo la deroga, `-tsmtlnospoof` solo lo spoofing.
