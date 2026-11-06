# Dynamic Island: avviso "Viva Link · USB" in SpringBoard (VivaIsland)

Tweak di SpringBoard (`app/tweak/VivaIsland.m` → `VivaIsland.dylib`) che mostra lo stato del link USB nell'isola:
avviso per ~3 s quando lo strumento host si collega (`kern.viva_linkstate` = 2), poi un indicatore compatto finché il
link resta attivo, niente quando finisce. Impostazioni e "Test isola" in Viva Manager → SpringBoard → *Dynamic Island ·
Viva Link*. Ricerca del 2026-11-06 su iOS 16.7.x **20H392** (la root del telefono è l'immagine iPhone X D22AP,
IPSW iPhone10,3/10,6).

## 1. Ricerca

### Dove sta il codice dell'isola

La cache del telefono contiene già tutto: non serve la cache di un iPhone 14 Pro. Cache usata:
`research-dsc/20H392__iPhone10,3_6/dyld_shared_cache_arm64` (la stessa build del telefono, fuori da git), class-dump in
`research-dsc/cd/` (`ipsw class-dump <DSC> <dylib>`), disassemblato con `ipsw dyld disass --symbol`.

| Immagine nella cache D22AP | Contenuto |
|---|---|
| `PrivateFrameworks/SystemAperture.framework` | `SAAssertion`, `SAAutomaticallyInvalidatingAssertion`, protocolli `SAInvalidatable` |
| `PrivateFrameworks/SystemApertureUI.framework` | `SAUISystemApertureManager` (registra gli elementi, li ordina, crea i view controller), `SAUIElementView(Controller)`, `SAUIElementAssertion`, layout modes |
| `PrivateFrameworks/SpringBoardUIServices.framework` | `SBUISystemApertureContentProvider`, `SBUISystemApertureCustomContentProvider` / `Text…` / `Image…`, `SBUISystemApertureLayoutModeDescription` |
| `PrivateFrameworks/SpringBoard.framework` | `SBSystemApertureController`, `SBSystemApertureViewController`, gli elementi concreti (`SBSystemApertureProvidedContentElement`, `SBAlertProvidedContentElement`, `SBActivityProvidedContentElement`, `SBPowerAlertElement`, `SBRingerAlertElement`, …) e i protocolli `SAElement*` |

Il binario `SpringBoard.app/SpringBoard` è uno stub di 113 KB (`__text` = 4 byte, salta a `SBSystemAppMain`): il codice
è tutto in `SpringBoard.framework` nella cache. Copia del binario 20H392: `research-dsc/springboard-20H392/`
(ad hoc, identifier `com.apple.springboard`, 395 entitlement, 20 load command, 14 944 byte liberi nell'header).
L'isola è attiva solo per MobileGestalt (ArtworkDeviceSubType 2556): il codice c'è su ogni iPhone con iOS 16.

### Percorso di registrazione (disassemblato)

```
[UIApp systemApertureControllerForMainDisplay]              // -[SpringBoard ...] -> windowSceneManager.connectedWindowScenes
  -> SBSystemApertureController -registerElement:            // = [_systemApertureViewController registerElement:]
     -> SBSystemApertureViewController -registerElement:      // [[el viewProvider] systemApertureLayoutSpecifyingOverrider]
                                                              //   addBehaviorOverridingParticipant:self
        -> SAUISystemApertureManager -registerElement:        // log "Asked to register element"; crea SAUIElementAssertion,
                                                              //   il view controller (SAUIElementViewController), riordina;
                                                              //   per gli alert: invalidazione dell'alertAssertion
                                                              //   => invalidazione dell'elemento
        <- SAUIElementAssertion (SAAssertion, <SAInvalidatable>)
```

- Il valore di ritorno è l'**asserzione**: l'elemento resta finché l'asserzione è valida; `-invalidateWithReason:` lo
  toglie. Il manager tiene gli elementi in un `NSPointerArray` debole: chi registra deve tenerli in vita.
- `-[SAAssertion addInvalidationBlock:]`: blocco chiamato con due oggetti (asserzione, motivo) all'invalidazione.
- `systemApertureLayoutSpecifyingOverrider` è una categoria di `NSObject` (SystemApertureUI): qualsiasi oggetto va bene.

### Protocolli che un elemento deve implementare

- `SAElement <SAElementIdentifying>`: `elementIdentifier`, `clientIdentifier`, `viewProvider`, `elementHost` (weak).
- `SAElementViewProviding`: `element`; opz. `_canShowWhileLocked`, `handleElementViewEvent:`.
- `SAUIElementViewProviding <SAElementViewProviding, SAUIElementLayoutAxisObserving>`: `leadingView`, `trailingView`,
  `minimalView`, opz. `detachedMinimalView`, `layoutAxis`.
- `SAUILayoutSpecifying`: `layoutMode`, `preferredLayoutMode`, `minimum/maximumSupportedLayoutMode`,
  `setLayoutMode:reason:`, `layoutHost` (weak), opz. `sizeThatFitsSize:forProvidedView:inLayoutMode:`,
  `preferredEdgeOutsetsForLayoutMode:suggestedOutsets:maximumOutsets:`, `layoutHostContainerViewDidLayoutSubviews:`…
- Comportamento: `SAAlertBehavior` (`hasAlertBehavior`, `alertHost`) per un avviso temporaneo, `SAActivityBehavior`
  (`hasActivityBehavior`, `activityHost`) per un'attività persistente, `SAIndicatorBehavior` per il puntino privacy.

Non serve implementarli a mano: **SpringBoard ha già la classe concreta** `SBSystemApertureProvidedContentElement`
(implementa tutto quanto sopra) con le due sottoclassi `SBAlertProvidedContentElement` e
`SBActivityProvidedContentElement`. È il modo in cui SpringBoard stesso costruisce gli avvisi "In carica" e
"Silenzioso":

```objc
// -[SBPowerAlertElement initWithIdentifier:style:batteryPercentage:lowPowerModeEnabled:action:] (riassunto)
provider = [SBUISystemApertureContentProvider new];
provider.leadingContentViewProvider = [[SBUISystemApertureCustomContentProvider alloc] initWithView:label];
provider.trailingContentViewProvider = ...; provider.minimalContentViewProvider = ...;
self = [super initWithIdentifier:identity contentProvider:provider];
```

- `-[SBSystemApertureProvidedContentElement initWithIdentifier:contentProvider:]`: il primo argomento **non è una
  stringa** ma un oggetto `<SAElementIdentifying>` (ne copia `elementIdentifier` e `clientIdentifier`; SpringBoard passa
  `SBChargingSystemApertureElementProvider`). `clientIdentifier` di SpringBoard = `SBSystemApertureClientIdentifier()` =
  `"com.apple.springboard"`. Asserisce che entrambi gli argomenti siano non nil.
- Imposta `minimumSupportedLayoutMode = maximumSupportedLayoutMode = preferredLayoutMode = 3` (compact). Le viste
  (`leadingView`, `trailingView`, `minimalView`, `_primaryView`…) vengono prese pigramente da
  `contentProvider.xxxContentViewProvider.providedView`. Il layout (`layoutHostContainerViewDidLayoutSubviews:`) agisce
  solo in compact: misura le viste con `systemLayoutSizeFittingSize:` (per questo VivaIsland fissa larghezza e altezza
  con vincoli, come la vista della batteria di SBPowerAlertElement) e asserisce che la vista misurata sia leading o
  trailing.
- `_canShowWhileLocked` = YES, `shouldSuppressElementWhileOnCoversheet` = NO: visibile anche sulla schermata di blocco.
- `SBSystemApertureElementAuthority` ordina gli elementi per promozione senza filtri sull'identificatore.

### Layout mode e durate

`SBUISystemApertureLayoutModeDescription` (tabella in SpringBoardUIServices): **1 inactive, 2 minimal, 3 compact,
4 custom** (custom = l'isola espansa grande; -1/0 non validi). Gli avvisi di sistema come "In carica" o "Silenzioso"
sono *compact* allargati (testo a sinistra della fotocamera, icona/valore a destra), non *custom*.

`-[SBSystemApertureViewController alertingDurationForHost:]`: **3,0 s** (7 s per il navigatore), oppure
`preferredAlertingDuration:` dell'elemento se lo implementa. Alla fine l'`alertAssertion` si invalida e il manager
invalida l'asserzione dell'elemento: un elemento con comportamento alert sparisce da solo dopo 3 s.

Cornice dell'isola: `-[SBSystemApertureController defaultIslandFrameInCoordinateSpace:]` (da
`minimumSensorRegionFrame` del view controller). Su 2556: 1125x2436 px, x 375-749, y 34-143 = 125 x 36,7 pt a y 11,3.

## 2. Implementazione

### Percorso principale: elementi di sistema (fattibile, nessun hook)

`VIElementPresenter` usa solo classi e selettori esistenti, verificati con `NSClassFromString` /
`instancesRespondToSelector:` prima dell'uso (nessuna sottoclasse, nessun `method_exchangeImplementations`):

1. **Avviso** (3 s): `SBAlertProvidedContentElement`, identificatore `it.viva.island.notice`, leading = icona
   `cable.connector` verde + "Viva Link", trailing = "USB" verde, minimal = icona. Lo toglie il sistema dopo 3 s
   (durata di alert); VivaIsland lo invalida comunque a 3,4 s.
2. **Indicatore** (finché il link è attivo): all'invalidazione dell'avviso (blocco di invalidazione) registra
   `SBActivityProvidedContentElement` `it.viva.island.link`: leading = icona, trailing = "USB" piccolo, minimal = icona;
   `minimumSupportedLayoutMode = 2` così, accanto a un'altra attività (musica, timer), diventa il cerchietto minimal.
3. Fine link: `invalidateWithReason:` delle asserzioni tenute.

Stato 1 (computer senza strumento): niente, oppure (impostazione "Avviso «USB standard»", spenta di default) un avviso
grigio "USB · standard" di 3 s senza indicatore.

### Ripiego: overlay

`VIOverlayPresenter`, usato se manca una classe o un selettore, se `registerElement:` fallisce o solleva, se la
protezione crash è scattata, o se l'utente sceglie "Forza overlay". Finestra `VIPassThroughWindow` (`hitTest:` → nil,
`userInteractionEnabled = NO`, mai key) nella scena della finestra dell'isola (`SBSystemApertureController._window`,
livello + 1; altrimenti la scena principale a livello status bar + 100). Pillola nera con `cornerCurve` continua alla
cornice dell'isola letta da SpringBoard (o dalla geometria sopra), espansione con animazione a molla (larghezza schermo -
22 pt, alta 72 pt, icona + "Viva Link · USB" + "Strumento di debug collegato"), dopo 3 s si stringe all'isola + 30 pt per
lato (icona a sinistra, "USB" a destra), si richiude nell'isola e sparisce a fine link.

### Polling, preferenze, notifiche

- `kern.viva_linkstate` (`sysctlbyname`, int) ogni 1 s su un timer GCD in una coda seriale utility (tolleranza 250 ms).
  Sysctl assente = 0. Comparsa immediata; scomparsa dopo due letture < 2 (antirimbalzo di 1 s).
- Preferenze `it.viva.island` (`/var/mobile/Library/Preferences/it.viva.island.plist`, CFPreferences come mobile):
  `Enabled` (sì), `StandardNotice` (no), `ForceOverlay` (no). Con `Enabled` = NO il timer si ferma.
- Notifiche Darwin: `it.viva.island.prefs` (rilettura), `it.viva.island.test` (avviso Viva Link + 6 s di indicatore,
  poi torna allo stato reale), `it.viva.island.status` (stato del tweak con `notify_set_state`: modo, ultimo stato del
  link, flag, pid; lo legge Viva Manager).
- Tutto il lavoro UI sulla coda principale, ogni chiamata privata dentro `@try`. Il costruttore fa solo
  `getprogname()` = SpringBoard e un observer: parte 3 s dopo `UIApplicationDidFinishLaunching` (o dopo 30 s).
- **Protezione crash**: prima di ogni `registerElement:` scrive `/var/mobile/Library/Caches/VivaIsland/pending`
  (conteggio all'avvio + 1), lo cancella 6 s dopo. Se SpringBoard muore in quella finestra per 2 avvii, il percorso di
  sistema si spegne e resta l'overlay. Viva Manager mostra "Protezione crash attiva" → *Riabilita isola* (o
  `vi-sb.sh guard`).

### Viva Manager

SpringBoard → *Dynamic Island · Viva Link* (`app/Sources/VMIsland.m`): stato del tweak (isola di sistema / overlay /
spento / non caricato), stato del link, SpringBoard modificato o originale, dylib presente, i tre interruttori,
*Test isola*, *Riavvia SpringBoard*. L'entitlement `com.apple.security.exception.shared-preference.read-write` include
`it.viva.island`.

## 3. Iniezione

Niente Substrate/ElleKit, e niente `DYLD_INSERT_LIBRARIES`: dyld chiede la policy con `amfi_check_dyld_policy_self`
(syscall della policy MAC "AMFI"), che lo stand-in del kernel (`sweet_amfi.c`) non registra. Si modifica quindi il
binario: `app/tweak/inject.sh` aggiunge `LC_LOAD_WEAK_DYLIB /var/jb/usr/lib/VivaIsland.dylib` (compatibility version 0,
nei 14 944 byte liberi dell'header), rifirma ad hoc con identifier e entitlement originali (verificati dopo la firma) e
rifiuta un binario già modificato. Il kernel marca piattaforma ogni binario firmato sulla root (`MNT_ROOTFS`); non c'è
policy di library validation, quindi SpringBoard può caricare una dylib ad hoc da `/var/jb`. `vi-sb.sh` (telefono) fa
copia di sicurezza, sostituzione atomica e ripristino.

### Installazione (dal Mac, link USB attivo; `L=fork/tools/viva-link.py`, da `ios-viva/`)

```sh
# 0. build (CI app.yml, artefatto viva-manager: VivaManager.app contiene VivaIsland.dylib e vi-sb.sh)
gpu/app/install.sh VivaManager.tar          # app + /var/jb/usr/lib/VivaIsland.dylib + /var/jb/usr/libexec/vi-sb.sh
# 1. binario di SpringBoard del telefono -> modificato sul Mac
python3 $L pull /System/Library/CoreServices/SpringBoard.app/SpringBoard /tmp/SpringBoard.phone
gpu/app/tweak/inject.sh /tmp/SpringBoard.phone gpu/app/out/SpringBoard.patched
# 2. sul telefono: SpringBoard.orig (la prima volta), sostituzione, riavvio di SpringBoard
python3 $L push gpu/app/out/SpringBoard.patched /private/var/mobile/SpringBoard.patched 755
python3 $L run -- /var/jb/bin/sh /var/jb/usr/libexec/vi-sb.sh install
python3 $L run -- /var/jb/bin/sh /var/jb/usr/libexec/vi-sb.sh status
```

Verifica: Viva Manager → SpringBoard → Dynamic Island: "Tweak in SpringBoard: isola di sistema", poi *Test isola*.
Log: `log stream --predicate 'subsystem == "it.viva.island"'` (o la console del link).

### Disinstallazione / ripristino (un comando)

```sh
python3 $L run -- /var/jb/bin/sh /var/jb/usr/libexec/vi-sb.sh restore   # SpringBoard <- SpringBoard.orig + riavvio
```

Alternative: `vi-sb.sh off` (sposta la dylib in `.off`: il caricamento debole non trova nulla, SpringBoard resta
modificato ma inerte; `on` la rimette), oppure l'interruttore "Avviso Viva Link" in Viva Manager. `vi-sb.sh` vive in
`/var/jb`, che resta raggiungibile da vivad anche se SpringBoard non parte. A mano, senza lo script:
`cp -p /System/Library/CoreServices/SpringBoard.app/SpringBoard.orig .../SpringBoard.new && mv -f .../SpringBoard.new .../SpringBoard && killall -9 SpringBoard`.

## 4. Rischi

- **Crash di SpringBoard** (il telefono non ha UI di recupero): un'asserzione `NSAssertionHandler` dentro un passaggio di
  layout di SystemApertureUI non passa dalle nostre `@try`. Mitigazioni: si usano le stesse classi e lo stesso schema di
  SBPowerAlertElement, tutte e tre le viste sono sempre fornite, la protezione crash torna all'overlay dopo 2 morti
  ravvicinate, e `vi-sb.sh restore`/`off` funziona dal link USB anche con SpringBoard in crash loop (vivad è un demone).
- **dyld e la dylib**: carico debole: se il file manca SpringBoard parte normalmente. Se il file c'è ma non si carica
  (firma, architettura), dyld4 dovrebbe ignorare l'errore per un carico debole; se così non fosse SpringBoard non
  partirebbe: `vi-sb.sh off` o `restore`. Un crash nel costruttore è improbabile (fa solo `getprogname` e un observer).
  Non copiare mai sopra la dylib in uso: `install.sh` e `vi-sb.sh` usano `mv` (inode nuovo).
- **Firma**: la nuova firma non lega più `Info.plist` (l'originale sì); né il kernel né FrontBoard lo verificano. Gli
  entitlement e l'identifier sono confrontati con l'originale da `inject.sh`. Se un aggiornamento della root cambia
  SpringBoard, rifare `inject.sh` dal nuovo binario (lo script rifiuta un binario già modificato; `vi-sb.sh install`
  rifiuta di sovrascrivere un originale assente se il binario sul telefono è già modificato).
- **Root fs in scrittura**: `vi-sb.sh` prova `mount -uw /` se serve; su viva la root è montata rw.
- **API private**: nomi e firme sono quelli di 20H392 (verificati nella cache); su un'altra build i controlli
  `respondsToSelector`/`NSClassFromString` portano all'overlay invece che a un crash, ma un cambiamento di semantica con lo
  stesso selettore (es. il primo argomento di `initWithIdentifier:contentProvider:`) non sarebbe rilevato.
- **Overlay**: disegnato sopra l'isola; se nel frattempo il sistema espande l'isola (chiamata, musica) la pillola la
  copre per la durata dell'avviso. Non intercetta mai i tocchi.
- **Sysctl**: senza la patch 0182 lo stato è sempre 0: nessun avviso (Viva Manager mostra "sysctl assente"); il test
  funziona comunque.
- **Build**: verificato con `app/build.sh check` (type-check Mac Catalyst) e un link Mac Catalyst della dylib; la build
  iOS vera la fa la CI (`app.yml`), nessuna prova sul telefono è stata fatta.
