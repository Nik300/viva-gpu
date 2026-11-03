# Fase 4 – Registrazione di sistema (2026-10-31)

Obiettivo: le app trovano il device Metal da sole, senza iniezione, con `MTLCopyAllDevices` = 1 per le app e 0 per WindowServer.
Contratto fra i pezzi: `docs/FASE4-INTERFACCE.md`. Installazione: `system/install.sh`; ripristino: `system/rollback.sh`.

## Come Metal trova il driver (misurato su questo Mac)
1. `MTLIOAccelServiceGlobalContext` ascolta la pubblicazione degli `IOAccelerator`; per ciascuno, `getMetalPluginClassForService`
   legge `MetalPluginName` e `MetalPluginClassName` dall'acceleratore.
2. Il percorso del bundle lo dà `gpu_bundle_find_trusted` (libsystem_sandbox): prova **`/Library/GPUBundles/<nome>.bundle`** e poi
   `/System/Library/Extensions/<nome>.bundle`, accettando il primo "fidato" (`rootless_check_trusted_class(..., "KernelExtensionManagement")`).
   Con la SIP di OCLP (0x803, filesystem non protetto) il controllo restituisce 0 (fidato) per qualsiasi percorso: verificato.
   Quindi **il volume di sistema sigillato non serve**: il bundle va sul volume dati, che gli aggiornamenti e OCLP non toccano.
3. `NSBundle` carica il bundle; Metal fa `[[classe alloc] initWithAcceleratorPort:]`, chiama `_setAcceleratorService:` e controlla
   (`MTLAddDevice`) che il device dichiari il protocollo privato `MTLDeviceSPI` (427 metodi obbligatori: ne implementavamo già 411,
   il resto lo copre il catch-all).
4. Sandbox: il profilo `system-graphics` (incluso da quasi tutte le app in sandbox e dal processo GPU di WebKit) consente la lettura
   di `/Library/GPUBundles`; in un profilo `(deny default)` un file leggibile è anche mappabile come codice, a meno di un divieto
   esplicito (provato con `sandbox-exec`).

## Pezzi
| Pezzo | Dove | Cosa fa |
|---|---|---|
| `TSMetalEnabler.kext` (Lilu 1.7.1, `kext/`) | EFI, iniettato da OpenCore dopo Lilu e AMFIPass, solo Darwin 25 | mette le due proprietà sull'acceleratore della Radeon (`IOGLBundleName = AMDRadeonX3000GLDriver`); deroga alla library validation per il solo eseguibile del bundle |
| `TeraScaleMTLDriver.bundle` (`src/`, `make`) | `/Library/GPUBundles` | lo shim; decide per processo con la policy; log os_log per categorie; statistiche a richiesta |
| policy | `/Library/GPUBundles/TeraScaleMTLDriver.config/policy.plist` | "auto su tutte" + lista per app; scrivibile dall'utente |
| `TeraScale Metal.app` + `tsmtl` (`gui/`) | `/Applications`, `/usr/local/bin` | carico e statistiche della GPU, log filtrati, lista per app, stato |

### Library validation
Le app con hardened runtime (quasi tutte quelle notarizzate) e tutte le app Apple caricano solo codice firmato Apple o dello stesso
team: AMFI scarterebbe in silenzio il nostro bundle firmato ad-hoc. AMFI applica il controllo in due voci della sua tabella di policy
MAC `mac_ops`: `file_check_library_validation` (slot 64) e `file_check_mmap` (slot 36); XNU rilegge la tabella a ogni controllo.
Il kext sostituisce **i due puntatori** (non il codice di AMFI, così convive con le patch di AMFIPass, che nasconde i propri simboli)
con funzioni che chiamano prima AMFI e trasformano un rifiuto in un via libera solo se:
- il file è esattamente `/Library/GPUBundles/TeraScaleMTLDriver.bundle/Contents/MacOS/TeraScaleMTLDriver`,
- appartiene a root e non è scrivibile da gruppo e altri (`vnode_getattr`),
- il processo non è WindowServer, loginwindow, Dock, SystemUIServer, ControlCenter, NotificationCenter, WallpaperAgent o WindowManager.

Gli slot si trovano per valore (indirizzo delle due funzioni di AMFI, simboli letti da Lilu dal binario su disco, stesso UUID di quello
caricato): se non corrispondono, la deroga non viene installata e il sistema resta com'è (`TSLVHook` lo dice).
Sicurezza: scrivere in `/Library/GPUBundles` richiede root, e root su questo Mac può già caricare kext (SIP 0x803), quindi la deroga
non dà a nessuno un potere che non abbia già. Spegnimento: boot-arg `-tsmtlnolv` (solo la deroga) o `-tsmtloff` (tutto il kext).

### Policy per app
Ordine: processi critici sempre spenti → voce nella lista → "auto" per le app in `/Applications`, `/System/Applications`,
`~/Applications` e nel cryptex di Safari → altrimenti spento (demoni, agenti, servizi di sistema). L'id è il `CFBundleIdentifier`
del `.app` più esterno (helper, XPC ed estensioni seguono la loro app). Spento = `+[TSMtlDevice alloc]` restituisce `nil`:
nessun device mezzo inizializzato, Metal vede 0 device come oggi.
Perché "auto" non vale per demoni e servizi: il compute è ancora un no-op, e servizi come Core Image, l'analisi delle foto o le
anteprime cambierebbero percorso appena vedono un device Metal, con risultati vuoti.

## Prove (prima dell'installazione)
`build/libTSRegSim.dylib` simula solo le due cose che dà l'installazione (proprietà dell'acceleratore, percorso del bundle);
tutto il resto è il codice vero di Metal.framework. `make test` → `system 8/8`:
- abilitato: 1 `TSMtlDevice`, `MTLCreateSystemDefaultDevice` e `CGDirectDisplayCopyCurrentMetalDevice` (percorso di SkyLight/VectorKit)
  restituiscono lo stesso oggetto senza interposer, clear GPU corretto;
- fuori dalle cartelle Applicazioni, disattivato in lista, WindowServer (anche se in lista), bundle assente, bundle non caricabile:
  0 device, nessun crash.
- App vera: `tools/shim-run.sh "/Applications/ArtCraft Launcher.app" --system` → interfaccia completa, policy `on reason=list`.
- Log: categorie e livelli giusti in `log stream`; righe `stats` solo dopo il `notify_post` del lease.
- Kext: 320 simboli importati, tutti risolti (10 da Lilu, gli altri dalle KPI dichiarate) contro il kernel in uso (`kmutil libraries`);
  `oc-config.py` provato su una copia di `config.plist` (aggiunta in fondo, idempotente, rimozione = file identico all'originale).
  Il kext stesso si può provare solo al riavvio.

## Dopo l'installazione: cosa controllare
1. `tsmtl status`: kext caricato, `TSLVHook = installed`, proprietà sull'acceleratore, bundle presente.
2. ArtCraft **originale** da `/Applications` (hardened runtime, quindi passa dalla deroga): deve partire con il device.
3. Mappe da `/System/Applications` (app Apple in sandbox): mappa disegnata senza copie né iniezione.
4. `tsmtl log --filter error,unimplemented` e `TSLVRefused` per WindowServer & co.
Se il Mac non si avvia: Option all'accensione → EFI della chiavetta OCLP → `system/rollback.sh`.

## Spoofing del modello (kext 1.1, 2026-10-31)
Dopo l'installazione 1.0 Chrome restava in "Software Render": ANGLE spegne Metal sui modelli vecchi prima di chiedere un device.
Misurato con `tests/spoof/modelprobe.m` sulla copia di Chrome, con il driver di sistema installato: l'helper GPU legge la proprietà
`model` di `IOPlatformExpertDevice` via IOKit; falsificare `sysctl hw.model` non cambia nulla, falsificare quella proprietà dà
"ANGLE Metal Renderer: AMD Radeon HD 6750M". La libANGLE di WebKit (Safari) contiene lo stesso controllo e la stessa lettura.
- Il kext avvolge le quattro routine MIG del kernel dietro `IORegistryEntryCreateCFProperty`/`IORegistryEntryGetProperty`
  (`is_io_registry_entry_get_property{,_bin,_bin_buf,_bytes}`, firme verificate sul disassemblato del kernel installato): se un
  processo della lista legge `model` dalla platform expert, la lettura passa a un'"esca" della stessa classe con il modello scelto.
  Tutto il resto del sistema vede iMac12,1.
- Lista: sezione `Spoof` di `policy.plist` (contratto), automatico su Chrome, Safari e i servizi WebKit, più app aggiunte a mano.
  Il kext rilegge il file quando cambia, con le credenziali del kernel (vale anche per i processi in sandbox).
- Il processo GPU di WebKit (`com.apple.WebKit.GPU`, il WebGL di Safari) ora ha l'id del suo `.xpc` e segue "auto" anche per lo shim.
- Spegnimento: boot-arg `-tsmtlnospoof`; stato in `TSSpoof`, `TSSpoofCount`, `TSSpoofLastProcess`.

## Limiti noti
- Il compute resta un no-op: le app che dipendono dai risultati del compute ricevono dati vuoti (lo dice la categoria `unimplemented`).
- Un `Build and Install OpenCore` di OCLP riscrive la EFI e toglie il kext (il bundle resta, inerte): va rieseguito `install.sh`.
