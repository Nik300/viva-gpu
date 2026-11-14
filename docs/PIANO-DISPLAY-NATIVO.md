# Piano: iOS 16 alle proporzioni native del pannello di viva (1080×2400, 360×800 pt @3x)

Ricerca del 2026-11-13, solo lettura: nessun sorgente del kernel, nessun file del telefono e nessun altro documento
è stato modificato. La root del telefono è iOS 16.7.16 **20H392** dell'iPhone X (iPhone10,3, D22AP). Cache dyld
usata: `research-dsc/20H392__iPhone10,3_6/dyld_shared_cache_arm64` (la stessa build), analizzata con `ipsw` 3.1
(`ipsw dyld str|disass|xref|dump|macho --strings`). Kernel di riferimento:
`fork/research/bt0154/xnu/iokit/Kernel/arm/SweetFramebuffer.cpp` (letto, non toccato). Cache MobileGestalt letta dal
telefono con `viva-link.py pull` il 2026-11-13.

Obiettivi:
- **a)** SpringBoard, Dynamic Island e app di sistema adattate al pannello (360×800 pt @3x), isola attorno al foro
  della fotocamera;
- **b)** app di terze parti che non si adattano: in finestra di compatibilità con bande nere (come le app iPhone 8
  su iPhone X);
- **c)** app adattive (Auto Layout + launch storyboard / `UILaunchScreen`, SwiftUI): a tutto schermo alla nuova misura.

Legenda: **[V]** verificato (disassemblato, stringa, file, valore letto), **[S]** stima o deduzione da verificare.

## 0. In breve

1. Oggi il kernel presenta un pannello **1125×2436** (iPhone X) e mostra la **finestra centrata 1080×2400** senza
   scala: si perdono 22 px a sinistra/destra e 18 px sopra/sotto (`fOffX = 22`, `fOffY = 18`, scanout dall'indirizzo
   `pa + 18·pitch + 22·4`) [V]. Il tocco è mappato nello stesso spazio [V].
2. Tutto ciò che iOS sa dello schermo nasce da **tre sorgenti**, tutte controllabili da noi senza toccare la cache dyld:
   - il kernel (`AppleCLCD`: dimensione, dot pitch) → MobileGestalt `main-screen-*` e `MGScreenClass`, CoreAnimation,
     FrontBoard, `UIScreen` [V];
   - l'ADT (`/arm-io/disp0 canvas-width/height`, `/product artwork-device-subtype`, `/product display-corner-radius`,
     `/chosen display-scale`/`display-rotation`) [V];
   - la cache di MobileGestalt (valori calcolati una volta e poi letti da tutti i processi) [V].
3. **1080×2400 non è in nessuna tabella** [V]: MobileGestalt dà `MGScreenClass` −1; SpringBoard classifica 360×800
   come "iPhone X (D22, Zoomed)" (tipo 4) e manda a ogni app un notch 209×30 pt che non combacia con nessuna tabella
   della status bar → "No status bar visual provider for screen", barra rossa rdar://45025538 (la 0061). Ma **status
   bar, safe area e area di esclusione di ogni app sono decise da SpringBoard** e spedite via XPC (§2.2): basta un
   tweak in SpringBoard che dichiari un'area di esclusione a y > 0 (l'isola) per avere `_DynamicSplitMedium` in tutte
   le app. La geometria dell'isola **non dipende dalla misura**: centrata in X, 125 × 36,67 pt a 11,33 pt dal bordo [V].
   Senza hook, a 360×800 **tutte** le app di terze parti finirebbero in compatibilità 375×667 (§2.3), anche quelle
   adattive: serve un hook di `-[SBApplication _defaultClassicMode]`.
4. Lo "schermo blu" di P8 (`sweetfb_native=1`) è quasi certamente un **disaccordo tra fonti**: il boot-arg cambia solo
   il kernel, mentre l'ADT (`canvas` 1125×2436, cotto nel boot.img) e la cache di MobileGestalt (1125×2436, classe 15,
   ArtworkDeviceSubType 2556 scritto a mano) restano quelli dell'iPhone X [S, da confermare col log].
5. Architettura raccomandata: **kernel/ADT come unica sorgente di verità** (una sola variabile cambia display, canvas,
   dot pitch, tocco, subtype, raggio degli angoli), **cache di MobileGestalt rigenerata** (nessuna modifica a mano),
   **un solo tweak in SpringBoard** ("VivaDisplay", stesso meccanismo di VivaIsland) per ciò che è scritto nel codice:
   tipo di schermo / area di esclusione / inset (→ status bar e safe area di tutte le app), geometria dell'isola,
   modalità di compatibilità per app. L'iniezione globale in UIKit (kernel: `amfi_check_dyld_policy_self`, §4.3 D3)
   resta un'opzione di riserva, non un requisito.

## 1. Stato attuale (evidenze)

### 1.1 Kernel: presentazione iPhone X, finestra centrata

`SweetFramebuffer.cpp` [V]:
- `SWEET_FB_LOGICAL_W/H = 1125/2436`, `SWEET_FB_DOT_PITCH = 458` (righe 163-173). Con `sweetfb_native=1`:
  `fLogicalW/H = fWidth/fHeight` = 1080×2400, offset 0 (righe 458-467). **Il dot pitch resta 458** anche in nativo.
- `kSweetFBGetDisplaySize` (sel 2946) restituisce `fLogicalW/H`; `kSweetFBGetDotPitch` restituisce 458.
- Copia CPU: coordinate logiche − `fOffX/fOffY` (riga 1107). Scanout diretto (`AppleCLCD::scanout`, riga ~1420): solo
  superfici esattamente `fLogicalW×fLogicalH`, indirizzo `pa + fOffY·bytesPerRow + fOffX·4` → con 1125×2436 il
  pannello vede x 22..1101, y 18..2417 della superficie di CA. **È un ritaglio, non una scala né un letterbox.**
- Pool di pagine per lo scanout (`sweet_surface_pool_init(fLogicalW, fLogicalH, …)`) e `sweet_surface_scanout_w/h`
  seguono già `fLogical*`: in nativo le superfici sono 1080×2400 (pitch 4352 con l'allineamento 64).
- `SweetHID.cpp` 412-414: `fLogicalW/H = native ? 1080/2400 : 1125/2436`, offset come sopra [V]. `SurfaceWidth` 68 mm.
- `VivaMDP.cpp:220` dimensiona lo scaler su `1125 * 2448` (massimo, non dipende dalla modalità: in nativo basta).

ADT (`tools/mkadt.py`) [V]:
- `/arm-io/disp0`: `canvas-width/height` = `CANVAS` (1125×2436 di default; `--canvas=WxH` / `VIVA_CANVAS` dal commit
  4d09b3d). **È nel boot.img**: il boot-arg `sweetfb_native` (catalogo di Viva Manager, `Resources/bootargs.json`,
  impostabile senza riflashare grazie a 0180) non lo cambia.
- `/product`: copiato dall'ADT vero di D22AP (`research/ipsw-x/d22ap.adt`), con `artwork-display-gamut` = sRGB.
  Contiene `artwork-device-subtype` = **2436** (0x984), `artwork-scale-factor` 3, `front-cam-offset-from-center`,
  `thin-bezel`, `oled-display`; **non** contiene `display-corner-radius`.

### 1.2 MobileGestalt sul telefono

`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist`
(7983 byte, `CacheVersion` 20H392). Chiavi decodificate (nome offuscato = base64(MD5("MGCopyAnswer"+nome))[:22]) [V]:

| Chiave offuscata | Nome | Valore |
|---|---|---|
| `oPeik/9e8lQWMszEjbPzng` | `ArtworkTraits` | `ArtworkDeviceSubType` **2556** (scritto a mano per l'isola), scale 3, idiom phone, gamut sRGB |
| `ybGkijAwLTwevankfVzsDQ` | `MainScreenCanvasSizes` | 4 double: 1125, 2436, 1125, 2436 |
| `oBbtJ8x+s1q0OkaiocPuog` | (struttura schermo di `MGIOMFBSupport.c`, nome non risolto) | 24 byte: u32 **1125**, u32 **2436**, u32 **458** ppi, f32 **3.0**, f32 −1.0 (rotazione: `/chosen display-rotation` assente), u32 **15** (`MGScreenClass`) |
| `rJkMAGeVLdhP5+10G5hVcA` / `pMeQxE5szZTjLMk10TisDQ` | probabilmente offset della fotocamera frontale (da `front-cam-offset-from-center`) | `{375, 174, 0, 98}` |

Validità della cache (stringhe di libMobileGestalt) [V]: "cache %@ doesn't match OS %@" (`CacheVersion` ≠ build),
"cache UUID %@ doesn't match build UUID %@" (`CacheUUID`), "we're switching release types, invalidate cache",
"Cache file did not exist. Rebuilding.", "IOKit is still busy, don't build cache". **Nessun controllo sui valori
hardware**: finché il file resta, nessun cambiamento del kernel o dell'ADT arriva a UIKit/SpringBoard; cancellandolo
viene ricostruito al primo `MGCopyAnswer` con IOKit fermo.

### 1.3 Come MobileGestalt calcola lo schermo (`MGIOMFBSupport.c`, `sub_19c560a54`) [V]

1. Legge `IODeviceTree:/chosen display-scale` e `display-rotation` (rotazione in gradi → radianti, −1 se assente).
2. `IOMobileFramebufferGetMainDisplay` → `GetDisplaySize` (= sel 2946 del nostro kernel) → `GetDotPitch` (= 458).
3. Impacchetta `w<<40 | h<<24 | scale<<16 | ppi` e lo cerca in una tabella di schermi noti → `MGScreenClass`.
   Se non c'è: `os_log_fault("screen parameters are unexpected: MGScreenClass%dx%dx%dx%d SCREEN_TYPE(...)")` e
   classe **−1**. Estratto della tabella (dal disassemblato):

| px | scala | ppi | classe | dispositivo |
|---|---|---|---|---|
| 1080×1920 | 3 | 326 | 9 | Plus "zoomato" |
| 1242×2208 | 3 | 461 | 10 | iPhone 6+/7+/8+ |
| 1125×2436 | 3 | 458 | **15** | iPhone X/XS/11 Pro (oggi) |
| 828×1792 | 2 | 326 | 19 | XR/11 |
| 1242×2688 | 3 | 458 | 18 | XS Max |
| **1080×2340** | 3 | 476 | **22** | 12/13 mini (**360×780 pt**) |
| 1170×2532 | 3 | 460 | 24 | 12/13/14 |
| 1284×2778 | 3 | 458 | 25 | 12/13 Pro Max |
| 1179×2556 | 3 | 460 | **30** | 14 Pro |
| 1290×2796 | 3 | 460 | 31 | 14 Pro Max |

   **1080×2400 non c'è** con nessun ppi. Il valore più vicino è il mini (stessa larghezza, 360 pt).
4. `DeviceCornerRadius` (`sub_19c565ff8`): `IODeviceTree:/product display-corner-radius`, **8 byte = u32 numeratore,
   u32 denominatore** → float in punti. Se manca: 39.0 (raggio dell'iPhone X) solo per i dispositivi di una lista
   (`MGIsDeviceOneOfType`), altrimenti 0 [V].
5. `ArtworkTraits` (`sub_19c55a5d0`): `artwork-device-subtype` da `/product`, accettato solo se in una lista [V]:
   568-570, 1792, 2224, 2340, 2360, 2387/2388, 2436, 2532, **2556**, 2688, 2732, 2778, 2796. **2400 non è
   accettato** ("Unsupported artwork-device-subtype %d"). 2556 sì: si può mettere nell'ADT invece che a mano nella cache.

### 1.4 IOMobileFramebuffer userland [V]

- `__ioMobileFramebufferAlloc` legge le preferenze `com.apple.iokit.IOMobileGraphicsFamily`: `canvas_width`,
  `canvas_height` (seconda canvas: è il "Resolution Setter"/ResSet16 della comunità), `override_display_width/height`,
  `override_panel_width/height`, `enable_ktrace`, `benchmark`.
- `IOMobileFramebufferGetDisplaySize` chiama il callback del kernel; `GetCanvasSizes` restituisce quella misura più la
  canvas delle preferenze se impostata. Il nodo ADT `disp0` (`canvas-width/height`) è letto quando si contano i display
  di `/arm-io` (`display-subsystem`).
- Conclusione: le preferenze **non servono** (e sono pericolose: sono la causa dei boot loop della comunità). Il
  kernel decide già la misura.

### 1.5 Dynamic Island: geometria [V]

- `-[SBSystemApertureViewController minimumSensorRegionFrame]` e `_frameForSensorRegionInBounds:`:
  `UIRectCenteredXInRectScale(size = layoutMetrics.sensorRegionSize, view.bounds)`, `y = minimumScreenEdgeInsets.top`.
  **Centrata in X sullo schermo qualunque sia la larghezza.**
- `SBUISystemApertureLayoutMetrics` (SpringBoardUIServices), costanti in `__TEXT.__const` 0x1a3472780..:
  `sensorRegionSize` = **125.0 × 36.667 pt** (125.333 se `_deviceNativeScreenSizeIsLargePhone`, cioè D74),
  `_minimumScreenEdgeInset` = **11.333 pt** (0x1a34727d0), `interSensorRegionInWindowSpace` = {213.33 o 232, inset,
  9, 36.67}, `_maximumWidth` = `nativeBounds.width/scale − 2·11.333`.
- Nessuna chiave MobileGestalt o ADT per la posizione: **si sposta solo con un hook** di
  `-[SBUISystemApertureLayoutMetrics sensorRegionSize]` / `_minimumScreenEdgeInset` (e, per coerenza,
  `interSensorRegionInWindowSpace`).
- Oggi (1125×2436, ritaglio 22/18): isola x 375..749, y 34..143 px della superficie = x 353..727, y 16..125 px del
  pannello.

### 1.6 Il pannello (dati da Xiaomi / alberi Android)

| Grandezza | Valore | Fonte | Fiducia |
|---|---|---|---|
| Area attiva | 69,55 × 154,56 mm → **394,4 ppi**, 15,53 px/mm | `dsi_k6t_38_0c_0a_dsc_vdo.c` (MiCode viva-r-oss) `physical_width_um`/`height_um` | alta |
| Densità Android | 440 dpi (2,75 px/dp) | `TARGET_SCREEN_DENSITY` del device tree Lineage viva | alta |
| Cutout dichiarato | rettangolo x 503..577, y 0..93 px (`M 0,0 H -37 V 93 H 37 V 0 H 0 Z`) | overlay `config_mainBuiltInDisplayCutout` (Lineage viva) — valore generico Xiaomi | alta (è un contenitore) |
| Foro reale | centro ≈ (540, 52) px, raggio ≈ 24,5 px (Ø ≈ 3,2 mm) = centro (180, 17,3) pt, r 8,2 pt | cutout del Redmi Note 10 Pro (sweet), stesso 6,67" 1080×2400 | **media-bassa: misurare (F0)** |
| Raggio degli angoli | 90 px (30 pt); altri alberi 100-102 px | overlay `rounded_corner_radius` | media (valore software, il pannello non arrotonda in HW: `CONFIG_MTK_ROUND_CORNER_SUPPORT` spento) |
| Status bar Android | 88-96 px (29-32 pt) | overlay Lineage / MIUI Note 10 Pro | media |

Con l'isola di serie su 360 pt: x 117,5..242,5 pt (352..728 px), y 11,33..48 pt (**34..144 px**). Il foro stimato
(y 27,5..76,5 px) **sporgerebbe sopra l'isola di ~6 px**: va alzata (§4.3).

## 2. Come UIKit decide misura, status bar, safe area e compatibilità delle app

Indirizzi = VA della cache 20H392. Dump di lavoro (simboli, disassemblati) nello scratchpad della sessione, non in git.

### 2.1 Status bar: fornitore visuale (UIKitCore) [V]

- `__UIStatusBarGetVisualProviderClassForScreen` (0x1891aaa80). Per lo schermo integrato legge prima la suite
  `com.apple.UIKit`, chiave **`UIStatusBarVisualProviderClassName`** (classe via `NSClassFromString`, deve rispettare il
  protocollo; log "WARNING: Using overridden status bar visual provider class: %@"). Altrimenti scende
  `_UIStatusBarVisualProvider_iOS` → `_Phone` → … con `visualProviderSubclassForScreen:visualProviderInfo:`. Se il
  risultato è nil: "No status bar visual provider for screen %@ (width, scale, idiom, cornerRadius). Please see
  rdar://45025538" (0x1d5c6e828) e `_UIStatusBarVisualProvider_Fallback` = **la barra rossa** della 0061.
- `+[_UIStatusBarVisualProvider_Phone …]` (0x189ab546c) guarda `screen._exclusionArea.rect`:
  nessuna area → `_LegacyPhone`; **`rect.origin.y > 0` → `_DynamicSplit`** (isola); altrimenti → `_Split` (notch).
- `_DynamicSplit` (0x1899f9884): larghezza in punti ≤ 393 → **`_DynamicSplitMedium`**, altrimenti `DynamicSplit`.
  **Nessuna tabella di misure**: a 360 pt va bene.
- `_Split` (0x189ab566c): tabella di 9 classi che devono combaciare **esattamente** in larghezza nativa (px) e misura del
  notch (pt): 1125 (209×30), 1080 (226×34,33, `referenceScreenScale` 2,88: è il mini "zoomato"), 1080_Wide, 1170,
  1170_Wide, 1242, 828, 1284, 1284_Wide. Se nessuna combacia: `_FixedSplit` solo con la feature
  `os_feature_enabled("SpringBoard","Jindo")` spenta, altrimenti nil → Fallback (rosso).
- Conseguenza: con un'area di esclusione **a y > 0** (l'isola attorno al foro) **ogni app** usa `_DynamicSplitMedium`
  senza tabelle da far combaciare.

### 2.2 Da dove arriva l'area di esclusione (e la safe area) di ogni app [V]

- **Non da MobileGestalt né dal kernel**: `-[UIScreen _displayInfoProvider]` (0x188f732fc) costruisce un
  `UISDisplayContext` da `_UIScreenInitialDisplayConfigurationLoader.initialDisplayContext` =
  `UISApplicationInitializationContext.mainDisplayContext`, **inviato da SpringBoard via XPC** a ogni app (e corretto
  da `-[SBApplicationSupportServiceRequestContext _main_applyClassicModeLiesIfNecessaryToDisplayContext:]` per le app in
  compatibilità).
- Lato SpringBoard: `+[UISDisplaySingleRectShape(SpringBoard) sb_thisDeviceDisplayShape]` →
  `sb_displayShapeForScreenType:` (SpringBoard 0x1c5c3e348) con `SBHScreenTypeForCurrentDevice()`; gli inset da
  `+[UISApplicationSupportDisplayEdgeInfo(SBHScreenTypes) _sbh_displayEdgeInfoForScreenType:]` (SpringBoardHome
  0x1c547fa30): tabella per tipo + `SBHDisplayDomain.rootSettings.additionalTopSafeAreaInset`. Rettangoli: tipi X 3/4 =
  83,0,209×30 pt (notch); tipi 14 Pro 21/22 = x 402, y 34, 375×110 px (isola).
- `_SBHScreenTypeLookup` (SpringBoardHome 0x1c5321634): MobileGestalt DeviceClass, HomeButtonType,
  ArtworkDeviceSubType, `main-screen-class`, bounds di riferimento e scala. Senza corrispondenza esatta, per un telefono
  senza tasto Home scende per ≥ sulle misure di `SBDisplayMetrics` (SpringBoardServices 0x191579f30): 430×932 → 23,
  428×926 → 13, 414×896 → 5, 393×852 → 21 (14 Pro), 390×844 → 11, 375×812 → 3 (X), **altrimenti 4 = "iPhone X (D22,
  Zoomed)"**. **360×800 → tipo 4**: notch 209×30 su uno schermo 1080 px → nessuna classe `_Split` combacia → rosso.
  Con 2556 o 2436 è uguale. `SBHomeScreenDefaults.overriddenScreenType` vale solo nelle build interne.
- `-[UIScreen _displayCornerRadius]`: pref interna `DisplayCornerRadiusOverride` → `UISDeviceContextDeviceCornerRadiusKey`
  → MobileGestalt `DeviceCornerRadius` (quindi dall'ADT, §1.3).
- `__UIScreenTypeForScreen` (0x188e80260): 40 `_UIScreenType` noti; per 360×800 restituisce −1 (`-[UIScreen
  _screenType]`), usato da tabelle secondarie (tastiera, ecc.) [V che è −1, S sugli effetti].
- `+[UISApplicationSupportDisplayEdgeInfo defaultDisplayEdgeInfoForceInsets:]` (0x19345519c, per subtype: 2556 → top 59,
  bottom 34) è usato solo con la pref interna `ForceIOSDeviceInsets`.

**Quindi un tweak nel solo SpringBoard** (già iniettabile, DYNAMIC-ISLAND.md §3) decide area di esclusione, inset e
quindi status bar e safe area **di tutte le app**, senza iniezione globale.

### 2.3 Compatibilità ("classic mode") delle app [V salvo dove indicato]

- Valori (`_UIApplicationSceneStringForClassicMode`, 0x1891b4de0): 0 nessuna, 1 "phone" 320×480, 2 4", **3 4,7"
  (375×667)**, 4 5,5", **5 5,8" con angoli (375×812)**, 6 6,5" con angoli, 7-10 iPad, 100 TV.
  `_UIApplicationSceneClassicModeWantsSafeAreaInsets` è vero solo per 0, 5, 6.
- `-[SBApplicationInfo _loadFromProxy:]`: `usesSplashBoard` se Info.plist ha `UILaunchStoryboardName`,
  `UILaunchStoryboards` o le chiavi di `UILaunchScreen`/`UILaunchScreens` [S sul nome delle ultime due].
- `_bypassesClassicMode` (0x1c58719e8) → sempre nativa se: entitlement
  `com.apple.springboard.disablecompatibilitymode.forever` o `.late2022`, entitlement di view service, app di sistema.
  **Le app di sistema sono già native.**
- Altrimenti `_defaultClassicMode` (0x1c586e760) → `-[SBApplication _classicModeFromSupportedTypes]` (0x1c58720fc):
  nativa (0) **solo se la misura di riferimento dello schermo è esattamente** una voce di `SBDisplayMetrics`
  supportata dall'app (dall'SDK di link per le app con storyboard, dalle launch image per le altre). Poi una catena di
  ≥ che a 360 pt fallisce sempre; la coda (0x1c58729e4) dà **3 (375×667)** se l'app supporta quel tipo, poi 2, poi 1.
- **Conseguenza a 360×800 senza hook: anche le app con storyboard/SwiftUI finiscono in compatibilità** (375×667 ridotta).
  L'obiettivo c) richiede un hook in SpringBoard: `_defaultClassicMode` → 0 per le app con `usesSplashBoard`, e per le
  altre una modalità di compatibilità scelta da noi (§4.5). Alternativa per singole app: l'entitlement
  `disablecompatibilitymode` (TrollStore lo può aggiungere).

### 2.4 SwiftUI

Nessun percorso speciale: il dizionario `UILaunchScreen` imposta `usesSplashBoard`, quindi le app SwiftUI seguono le
regole delle app con storyboard (2.3) e ricevono status bar e safe area dallo stesso `UISDisplayContext` (2.2). Le
SwiftUI senza Auto Layout fisso si adattano a 360×800 come al mini (360 pt).

## 3. Perché `sweetfb_native=1` dava lo schermo blu

Nessun log della prova è rimasto (ANALISI-PRESTAZIONI §P8 dice solo "schermo blu con SpringBoard"). Dalla struttura
delle sorgenti [S]:

1. **Cache di MobileGestalt vecchia.** Con il boot-arg il kernel dice 1080×2400, ma la cache (stessa `CacheVersion`)
   continua a dire 1125×2436, classe 15, canvas 1125×2436. UIKit (`UIScreen`, che usa MobileGestalt per
   `_referenceBounds`/classe) e FrontBoard/CoreAnimation (che usano la misura reale del display) non concordano: le
   scene di SpringBoard sono dimensionate su 375×812 pt e il display di CA è 360×800 pt. Il blu uniforme è compatibile
   con lo sfondo/placeholder di una scena che non viene mai composta nel display (o con il colore di riempimento di
   backboardd) [S].
2. **ADT con canvas 1125×2436** mentre il kernel risponde 1080×2400 (il commit 4d09b3d lo dice esplicitamente: "must
   match what AppleCLCD reports"). Se il boot-arg è stato messo con Viva Manager (0180) l'ADT era quello di default.
3. Se anche cache e ADT fossero stati coerenti: SpringBoard classifica 360×800 come tipo 4 (notch 209×30) → nessun
   fornitore di status bar (barra rossa, §2.2), come prima della 0061; e tutte le app di terze parti in compatibilità
   375×667 (§2.3). Non dà blu, ma sono il secondo e il terzo ostacolo.
4. Dot pitch 458 in nativo: valore falso (394), irrilevante per la tabella (che manca comunque) ma usato da chi calcola
   mm/punti (`main-screen-pitch` in UIKitCore e SpringBoard).

Cosa deve cambiare: un solo interruttore che porti **insieme** kernel (misura, ppi, tocco), ADT (canvas, subtype,
raggio) e cache di MobileGestalt (rigenerata), più il tweak in SpringBoard (§4.4-4.5). Prima di
riprovare, raccogliere il log della prova (F1, test 1.3) per confermare l'ipotesi 1.

## 4. Architettura raccomandata

### 4.1 Scala: @3x, 360×800 pt

| Opzione | Punti | Pro | Contro |
|---|---|---|---|
| **@3x** | **360×800** | pixel 1:1; larghezza 360 pt già nota a iOS e alle app (iPhone 12/13 mini); asset @3x dell'iPhone X | altezza 800 pt mai vista (il mini è 780): le app con altezze fisse hanno 20 pt in più |
| @2,75 (densità Android) | 392,7×872,7 | caratteri un po' più piccoli, come su Android | punti frazionari, UIKit su iPhone usa solo scale intere per gli asset; `nativeScale` ≠ `scale` è solo per Display Zoom; molto rischioso |
| @3x presentato 375×812 (oggi) | 375×812 | funziona | ritaglio di 15×12 pt, 8 % di pixel in più, isola e angoli fuori posto |
| @3x presentato 1080×2340 (mini) | 360×780 | classe 22 nota a tutti, zero tweak per la status bar | 60 px di pannello sprecati (bande di 30 px o 60 px sotto) |

Scelta: **@3x, 360×800 pt**. Con un'area di esclusione a y > 0 la status bar `_DynamicSplitMedium` non ha tabelle di
misure (§2.1), quindi l'altezza 800 non è un problema per UIKit. Ripiego se il tweak in SpringBoard non bastasse:
**1080×2340 presentato come mini** (30 px neri sopra e sotto): misura nota, ma il mini ha il notch e il tipo SBH
corrispondente non ha l'isola.

Geometria proposta a 360×800 pt (da confermare con F0):
- angoli: raggio **30 pt** (90 px) → ADT `display-corner-radius` = `<30 1>`;
- isola: centrata (automatico), y **6 pt**, 120 × 34 pt (x 120..240, y 6..40 pt = 18..120 px, contiene il foro
  stimato 27..77 px con ≥ 9 px di margine) — valori nelle preferenze del tweak;
- status bar: 47-50 pt (quella del 14 Pro è 54 pt con isola a 11,33 pt; con l'isola a 6 pt bastano ~48 pt);
- safe area: top = status bar (≈ 48 pt), bottom 34 pt (indicatore home come su iPhone X), sinistra/destra 0.

### 4.2 Divisione del lavoro

| Cosa | Dove | Perché lì |
|---|---|---|
| Misura presentata 1080×2400, ppi 395, tocco 1:1, scanout senza offset | **kernel** (`sweetfb_native`, già c'è) + ppi | unica sorgente: arriva a CA, FrontBoard, MobileGestalt |
| `canvas-width/height` di `/arm-io/disp0` | **kernel** al boot (aggiornare la proprietà nel registro da `fLogicalW/H`) oppure `mkadt --canvas` | oggi è nel boot.img e non segue il boot-arg (causa di §3.2) |
| `artwork-device-subtype` 2556 | **ADT** `/product` | sopravvive alla rigenerazione della cache (oggi è una modifica a mano) |
| `display-corner-radius` 30/1 | **ADT** `/product` | letto da MobileGestalt → `DeviceCornerRadius` → UIKit/CA/SpringBoard (angoli delle app, switcher) |
| `/chosen display-rotation` | ADT, lasciare assente | |
| Classe dello schermo di MobileGestalt (−1) | lasciarla com'è | nessun consumatore critico trovato: status bar e safe area vengono da SpringBoard (§2.2); `_SBHScreenTypeLookup` la legge solo per il test `== 7` |
| Tipo di schermo SBH, area di esclusione (isola), inset sicuri | **tweak in SpringBoard** | arrivano a ogni app nel `UISDisplayContext` (§2.2) → status bar `_DynamicSplitMedium` e safe area ovunque |
| Geometria dell'isola | **tweak in SpringBoard** (`SBUISystemApertureLayoutMetrics`) | costanti nel codice (§1.5) |
| Modalità di compatibilità per app | **tweak in SpringBoard** (`-[SBApplication _defaultClassicMode]`) | §2.3: senza hook tutte le app di terze parti vanno in 375×667 |
| Iniezione in tutte le app | solo se servisse (kernel D3) | oggi non necessaria |

### 4.3 Richieste per il kernel/ADT (proposte, non implementate)

- **D1.** `sweetfb_native=1` (o un nuovo `vivadisplay=native|x`) imposta anche: `SWEET_FB_DOT_PITCH` = 395 in nativo;
  `IODeviceTree:/arm-io/disp0` `canvas-width/height` = `fLogicalW/H` (setProperty sull'entry del piano DeviceTree
  prima che backboardd parta); idem per `/product display-corner-radius` e `artwork-device-subtype` se si vogliono
  pilotare da boot-arg. Così Viva Manager (0180) basta per passare da una modalità all'altra senza riflashare.
- **D2.** `disp kv` espone `logical_width/height` (c'è già), più `dot_pitch` e `mode`.
- **D3 (riserva).** Policy AMFI per dyld (`amfi_check_dyld_policy_self`; `sweet_amfi.c` registra solo
  `mpo_vnode_check_signature`, nessun `mpo_policy_syscall`): rispondere con i flag che permettono
  `DYLD_INSERT_LIBRARIES`. Serve solo se qualche dettaglio di UIKit dentro le app (es. tabelle per `_screenType` −1:
  tastiera, ecc.) non si sistemasse da SpringBoard. Rischio: un tweak globale che crasha blocca ogni app →
  interruttore da boot-arg (`vivainject=0`).
- **D4 (ADT).** `mkadt.py --viva`: `/product artwork-device-subtype` = 2556 e `display-corner-radius` = `<30 1>`
  dietro un flag (`--native-display`), con `--canvas=1080x2400`. `front-cam-offset-from-center` andrebbe ricalcolato
  (posizione della fotocamera in µm dal centro; usato da Fotocamera/FaceTime, non urgente).

### 4.4 Il tweak (VivaDisplay, accanto a VivaIsland)

Una dylib in SpringBoard (stesso `LC_LOAD_WEAK_DYLIB` di VivaIsland, o fusa con essa), preferenze `it.viva.display`,
attiva solo se la misura di `UIScreen.mainScreen.nativeBounds` è 1080×2400 (così con il kernel in modalità X è
inerte). Hook, tutti con selettori verificati in 20H392:

1. **Tipo di schermo**: `SBHScreenTypeForCurrentDevice()` (funzione C, serve un hook di funzione: senza Substrate si
   evita) → meglio i due punti ObjC che lo consumano:
   - `+[UISDisplaySingleRectShape sb_displayShapeForScreenType:]` → rettangolo dell'isola in px (es. x 360, y 18,
     360×102 px per 120×34 pt a y 6 pt), **y > 0** (→ `_DynamicSplitMedium` in tutte le app);
   - `+[UISApplicationSupportDisplayEdgeInfo _sbh_displayEdgeInfoForScreenType:]` → inset: top ≈ 48 pt, bottom 34 pt,
     angoli = `DeviceCornerRadius`.
   Alternativa più ampia: forzare il tipo 21 (14 Pro, 393×852) dove SpringBoard lo chiede, ma tabelle e layout della
   home (griglia icone, dock) sono per 393 pt: da provare solo se 1. non basta [S].
2. **Isola**: `-[SBUISystemApertureLayoutMetrics sensorRegionSize]`, `_minimumScreenEdgeInset`,
   `interSensorRegionInWindowSpace` → valori di F0, coerenti col rettangolo del punto 1.
3. **Compatibilità**: §4.5.
4. **Home screen**: la griglia di SpringBoardHome per il tipo 4 ("X Zoomed") è pensata per 375 pt ridotto: verificare
   in F4; eventuale hook dei metrics di `SBIconListGridLayoutConfiguration` [S].

Hook senza Substrate/ElleKit: `method_setImplementation` / `class_replaceMethod` sui metodi ObjC (VivaIsland non
fa swizzle oggi: è un passo nuovo, ogni hook dietro un flag di preferenze e la stessa protezione crash).
VivaIsland: la geometria di ripiego (`islandFrame`, "x 375-749, y 34-143") va letta dalle stesse preferenze.

### 4.5 Compatibilità delle app (obiettivi b e c)

Hook di `-[SBApplication _defaultClassicMode]` (0x1c586e760):
- app di sistema / con entitlement `disablecompatibilitymode`: invariato (già 0);
- `info.usesSplashBoard` (launch storyboard, `UILaunchScreen`, SwiftUI) → **0** (nativa 360×800);
- altrimenti → valore originale se è 1-3 (app vecchie con launch image: 4,7" 375×667 ridotta a 360×640 con bande
  nere, come le app iPhone 8 su X); opzionalmente **5** (5,8" con angoli, 375×812 → 360×779,5, bande di ~10 pt) per le
  app che avevano solo l'immagine dell'iPhone X [S: verificare che `restrictedClassicModeDisplayConfigurationForDisplayConfiguration:classicMode:`
  scali verso il basso: oggi la usa solo per misure più piccole dello schermo];
- eccezioni per bundle id nelle preferenze (Viva Manager: "Forza nativa" / "Forza compatibilità").
Rischio: un'app con storyboard ma layout a misure fisse (375 pt) taglia 15 pt a destra: è lo stesso comportamento
del mini, accettabile.

## 5. Fasi

Ogni fase ha un test che si esegue con `viva-link.py` dal Mac (`L=fork/tools/viva-link.py`, da `ios-viva/`). Il
ripristino è sempre: riflashare il boot.img precedente in `boot_b` (`fastboot flash boot_b <img-precedente>`), e per
i cambi di userspace ripristinare la cache di MobileGestalt salvata (F1) e `vi-sb.sh restore`.

### F0. Misura del foro e degli angoli (nessun cambio di sistema)

- Una pagina di Viva Manager "Calibrazione display" disegna in coordinate del pannello (oggi: punto logico × 3 − (22,
  18)) un reticolo a passo 10 px nella zona y 0..160, cerchi concentrici centrati su x 540 e una cornice agli angoli.
  Foto del telefono → centro e raggio del foro, raggio degli angoli in px.
- In alternativa senza app: ADT/kernel non servono; si può disegnare con la console del kernel (fbcon) se esiste un
  comando di test pattern [S].
- Esito: centro/raggio del foro e raggio degli angoli in px; aggiornare la tabella §1.6 e le preferenze di §4.1.

### F1. Coerenza kernel + ADT + cache (modalità nativa senza tweak)

1. Salvare la cache: `python3 $L pull /private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist mg-backup.plist`.
2. Boot image con `VIVA_CANVAS=1080x2400` (+ D4) e `VIVA_EXTRA="... sweetfb_native=1"`; cancellare la cache sul
   telefono prima del riavvio (operazione dell'utente, non di questa ricerca) perché si rigeneri.
3. Test: `disp kv` → `logical_width=1080 logical_height=2400`; cache rigenerata: `ybGkij…` = 1080, 2400, …;
   struttura `oBbtJ8x…` = 1080/2400/395/3.0/−1/**−1**; `ArtworkTraits.ArtworkDeviceSubType` = 2556 senza modifiche a
   mano; log: `log show --predicate 'subsystem == "com.apple.MobileGestalt"'` con "screen parameters are unexpected".
4. Esito atteso: SpringBoard a 360×800 senza ritaglio, **barra rossa** (tipo SBH 4), isola centrata ma ~6 px troppo
   bassa, app di terze parti in finestra 375×667. Se è ancora blu: raccogliere `log` di SpringBoard/backboardd/FrontBoard (è l'informazione mancante di §3).

### F2. Prova rapida della status bar senza codice (facoltativa)

- Con F1 attivo: default `UIStatusBarVisualProviderClassName` = `_UIStatusBarVisualProvider_DynamicSplitMedium` nella
  suite `com.apple.UIKit` (utente mobile), riavvio di SpringBoard. Esito: la barra rossa sparisce almeno in SpringBoard e
  nelle app che leggono quella suite (le app sandboxed potrebbero leggerla dal proprio contenitore [S]). Serve solo a
  confermare §2.1 prima di scrivere il tweak; si toglie cancellando la chiave.

### F3. Isola sul foro (tweak in SpringBoard)

- VivaDisplay in SpringBoard con gli hook 2 di §4.4 (isola), valori di F0. Test: Viva Manager → *Test isola*; foto: il foro
  deve stare dentro la pillola compatta in ogni stato (compact, minimal, espansa, animazione "shake").
- Esito: isola centrata sul foro, contenuti leading/trailing non coperti dalla fotocamera.

### F4. Status bar, safe area e app di sistema

- Hook 1 di §4.4 (forma e inset). Test: Impostazioni, Telefono, Foto, Safari, Messaggi, Control Center (scorrimento
  dall'angolo destro), schermata di blocco, switcher (raggio delle schede = `DeviceCornerRadius`), griglia della home.
  Controllo dal Mac: in un'app di prova `UIScreen.mainScreen._exclusionArea` e `safeAreaInsets` della finestra; log
  senza "No status bar visual provider".

### F5. App di terze parti: compatibilità e app adattive

- Test con: un'app senza launch storyboard (deve andare in finestra di compatibilità con bande nere), un'app con
  `UILaunchStoryboardName` (deve andare a tutto schermo), un'app SwiftUI (`UILaunchScreen` nel plist), Sileo, TrollStore.
- Hook di §4.5. Esito: le prime a 360×640 con bande nere, le altre a 360×800; nessun cambio per le app di sistema.

### F6. Prestazioni

- `passbench` / trace del documento ANALISI-PRESTAZIONI: −8 % di pixel per pass, scanout senza offset (pitch 4352,
  superfici del pool 1080×2400).

## 6. Rischi

- **Boot loop**: si scrivono solo `boot_b` e `userdata`. Un kernel/ADT sbagliato si recupera riflashando il boot.img
  precedente (tenerlo accanto: `shim/out/viva-boot-<data>.img`). Il boot-arg da Viva Manager (0180) vale solo al
  prossimo avvio: se SpringBoard non parte, vivad resta raggiungibile dal link USB e si può rimettere la riga
  precedente.
- **Cache di MobileGestalt**: una cache rotta o incoerente blocca SpringBoard (e lockdownd/attivazione: UDID, numero di
  serie, `ProductType`). Salvarla sempre prima (F1.1); ripristino con `push` dal link. Non toccare `CacheData`.
- **Tweak globale (D3)**: un crash nel costruttore uccide ogni app; serve un interruttore da boot-arg e un elenco di
  esclusione (backboardd, launchd, demoni).
- **Subtype 2556 con 360×800**: combinazione mai vista da SpringBoard (asset e layout del 14 Pro su uno schermo più
  stretto): possibili asserzioni in SystemApertureUI; l'isola è già stata provata su 375 pt.
- **Preferenze `IOMobileGraphicsFamily`**: non usarle (seconda canvas, causa nota di boot loop su iPhone veri).
- **Fotocamera/Face ID**: `front-cam-offset-from-center` dell'iPhone X è sbagliato per viva; irrilevante finché la
  fotocamera non esiste.

## 7. Domande aperte

1. Posizione e diametro reali del foro (F0) — i dati Android di viva danno solo il rettangolo 74×93 px.
2. Il log della prova P8 (blu): conferma dell'ipotesi cache/canvas.
3. Se `sb_displayShapeForScreenType:` con y > 0 su un tipo SBH "X Zoomed" basta, o se SpringBoard (feature
   "Jindo", `SBFEffectiveArtworkSubtype`) richiede anche il tipo 21/22 per coerenza isola/status bar; e cosa fa la
   griglia della home col tipo 4 a 360 pt.
4. D3: quali flag di `amfi_check_dyld_policy_self` servono a dyld4 di 16.7 per accettare `DYLD_INSERT_LIBRARIES`.
5. Quale processo ricostruisce la cache su questa root dopo la cancellazione (il primo client con scrittura nel
   gruppo `systemgroup.com.apple.mobilegestaltcache`?) e se lo fa prima di SpringBoard ("IOKit is still busy, don't
   build cache" può rimandarlo): verificare in F1 che il file riappaia con `CacheVersion` 20H392.
6. Effetti di `-[UIScreen _screenType]` = −1 nelle app (tastiera, tabelle per tipo): se ce ne sono di visibili, D3.

## Fonti esterne

- MiCode/Xiaomi_Kernel_OpenSource, branch viva-r-oss, `drivers/gpu/drm/panel/dsi_k6t_38_0c_0a_dsc_vdo.c`.
- xiaomi-mt6781-devs/android_device_xiaomi_viva (overlay `config_mainBuiltInDisplayCutout`, `rounded_corner_radius`,
  `status_bar_height_*`, `TARGET_SCREEN_DENSITY`).
- LineageOS/android_device_xiaomi_sweet (cutout circolare del Redmi Note 10 Pro).
- Prior art iOS: DynamicCow / DynamicCowTS (matteozappia; MacDirtyCow/TrollStore, `ArtworkDeviceSubType` = 2556
  nella cache di MobileGestalt per l'isola sugli iPhone con notch, iOS 16.0-16.1.2), Resolution Setter / ResSet16
  (Cowabunga; `canvas_width/height` in `com.apple.iokit.IOMobileGraphicsFamily.plist`), tweak storici Upscale /
  LittleX(S) (hook di MobileGestalt `main-screen-*` e di `UIScreen`, nessuna rigenerazione di asset).

## 8. Calcoli della geometria (2026-11-13, `fork/tools/viva-display-geometry.py`)

Lo script ricalcola tutto da foro e angoli misurati (`--hole-x/-y/-r PX --corner PX --measured --json FILE`; il JSON è
quello che leggerà il tweak, preferenze `it.viva.display`). Valori di oggi con le **stime** di §1.6:

| Grandezza | Valore | Note |
|---|---|---|
| Pannello | 1080×2400 px = **360×800 pt @3x**, 394,4 ppi (1 pt = 0,193 mm) | dot pitch ADT/kernel 394 |
| Foro (stima) | centro (540, 52) px r 24,5 = (180, 17,33) pt r 8,17 | **da misurare** |
| Angoli | 90 px = 30 pt → ADT `display-corner-radius` `<90 3>` | da confermare |
| Isola compatta | **x 127,67 y 2 w 104,67 h 30,67 pt** = (383, 6, 314, 92) px, raggio 15,33 pt | centrata sul foro anche in y |
| Margini foro→bordo isola | 7,17 pt sopra/sotto, 44,17 pt ai lati | proporzioni Apple 125:36,67 |
| `sensorRegionSize` | 104,67 × 30,67 pt | hook `SBUISystemApertureLayoutMetrics` |
| `minimumScreenEdgeInsets` | top **2** pt, lati 11,33 pt (come Apple) | un valore unico (2) stringerebbe l'isola espansa ai bordi: l'hook deve separare top e lati |
| `_maximumWidth` (isola espansa) | 337,33 pt | 360 − 2×11,33 |
| `interSensorRegion` (pallino privacy) | (194, 2, 9, 30,67) pt | stessa distanza dal centro, in proporzione, del 14 Pro (a destra del foro) |
| Area di esclusione (`UISDisplaySingleRectShape`) | (383, 6, 314, 92) px | y > 0 → status bar `_DynamicSplitMedium` in tutte le app |
| Status bar | **53,67 pt fissi** (`+[_UIStatusBarVisualProvider_DynamicSplit height]`, notch: 47) | |
| Voci della status bar | centrate in y sull'area di esclusione (y 17,33 pt), 8 pt dall'isola (`cutoutEdgeInset`), 17/18 pt dai bordi (`edgeInsets`) | verificato nel disassemblato: `setupInContainerView:` usa `sensorAreaRect` = `_exclusionArea.rect` |
| Spazio per lato | 102,7 / 101,7 pt (14 Pro 109) | ora + rete/batteria ci stanno; se no `minimumItemScaleFactor` |
| Safe area verticale | top **53,67**, bottom 34, lati 0 pt | top = altezza della status bar (l'isola finisce a 32,67 pt) |
| Safe area orizzontale | lati 53,67, bottom 21 pt | |
| Indicatore home | inset 34 pt (come X / 14 Pro) | |

Scelte e motivi:
- **Isola centrata verticalmente sul foro.** Il foro è molto più in alto che sul 14 Pro (centro 17,3 pt contro ~30): con
  l'altezza Apple (36,67) la pillola partirebbe a −1 pt. Con 2 pt di distacco dal bordo l'altezza viene 30,67 pt e il foro
  ha 7,17 pt di margine sopra e sotto (sul 14 Pro ~10). Alternative: `--island-top 3` (h 28,67) o `--island-h 34`
  (non centrata, foro nella metà alta come la fotocamera Apple è nella metà destra).
- **Larghezza in proporzione Apple** (104,67 pt): con 360 pt di schermo restano ~102 pt per lato alla status bar, quasi
  quanto sul 14 Pro. Un'isola più stretta lascerebbe più spazio ma le viste compatte (timer, musica, "Viva Link") sono
  disegnate per ~125 pt: da valutare con gli screenshot.
- **Status bar non da toccare**: `_DynamicSplitMedium` si posiziona da sola sull'area di esclusione che SpringBoard manda
  alle app (§2.2), quindi basta l'hook di `sb_displayShapeForScreenType:` con il rettangolo sopra.
- **Compatibilità app di terze parti** (scala per stare in 360 pt di larghezza):

| Modo | Finestra dell'app | Scala | Mostrata | Bande nere |
|---|---|---|---|---|
| 3 (4,7", app senza storyboard con launch image iPhone 8) | 375×667 | 0,96 | 360×640,3 | 79,8 pt sopra e sotto |
| 5 (5,8", app "iPhone X") | 375×812 | 0,96 | 360×779,5 | 10,2 pt sopra e sotto |
| 6 (6,5") | 414×896 | 0,8696 | 360×779,1 | 10,4 pt sopra e sotto |

  Le app con storyboard/`UILaunchScreen`/SwiftUI: modo 0 (360×800 nativo). È l'effetto "iPhone 8 su iPhone X" chiesto.

### 8.1 Misura del foro senza app (sostituisce F0)

1. Sfondo chiaro in alto (es. Impostazioni), poi `python3 fork/tools/viva-link.py shot ~/foro-shot.png` (PNG esatto di
   ciò che il pannello mostra, sezione 8.2).
2. Foto del telefono, dritta e ravvicinata sulla parte alta, con le stesse cose a schermo.
3. Nella foto le cifre dell'ora e le icone hanno posizioni note in px dallo screenshot: due punti di riferimento danno
   scala e offset, quindi centro e raggio del foro (e la curva degli angoli) in px del pannello.
4. `viva-display-geometry.py --hole-x X --hole-y Y --hole-r R --corner C --measured --json display.json`.

### 8.2 Valutazione con gli screenshot

`viva-link.py shot [FILE] [--full] [--width N]`: salva sul Mac il framebuffer di CoreAnimation a schermo ritagliato alla
finestra del pannello (oggi 1080×2400 a offset 22,18 della superficie 1125×2436; in modalità nativa offset 0). Con il
kernel 0202 la superficie viene scelta da `disp kv shown_surface`; prima salva tutti i framebuffer (`FILE-N.png`).
Per ogni fase: screenshot di schermata di blocco, home, Centro di Controllo, Impostazioni, un'app di terze parti con
storyboard (Sileo) e una senza, isola compatta ed espansa (`vctl` per aprire le app, `watch` per aspettare l'utente).

### 8.3 Misure reali (2026-11-13, foto IMG_0255/0256 dell'utente)

Metodo: isola di oggi nello screenshot `viva-link.py shot` = x 263..817, y 16..125 px del pannello; nella foto ravvicinata
(2268×4032) la stessa isola = x 519..1790, y ~1042..1293 → 2,29 px di foto per px di pannello, uguale in x e y
(prospettiva trascurabile, rotazione 0,8° corretta). Il bordo alto del pannello nella foto cade a y ≈ 0 del pannello,
come deve. Seconda foto (telefono intero): bordi e curva dell'angolo in alto a sinistra, adattamento di un cerchio.

| Grandezza | Misura | Stima precedente |
|---|---|---|
| Centro del foro | **(543, 50) px** = (181, 16,67) pt (±2 px) | (540, 52) |
| Raggio del foro | **18 px visibili** (disco grigio dell'obiettivo); si usa 20 con margine | 24,5 |
| Raggio degli angoli | **110 px** (±10) = 36,67 pt → ADT `<110 3>` | 90 |

Il foro è 3 px (1 pt) a destra del centro: l'isola resta centrata sullo schermo (SpringBoard la centra comunque),
margini 44,3 / 42,3 pt ai lati. Geometria finale (`viva-display-geometry.py`, ora con questi valori di default;
JSON per il tweak in `gpu/docs/viva-display.json`):

| Grandezza | Valore |
|---|---|
| Isola compatta | **x 130, y 2, 100 × 29,33 pt** = (390, 6, 300, 88) px, raggio 14,67 pt; foro con 8 pt sopra e sotto |
| `interSensorRegion` | (193,33, 2, 9, 29,33) pt |
| Area di esclusione | (390, 6, 300, 88) px |
| Status bar | 53,67 pt, voci centrate a y 16,67 pt, ~104-105 pt per lato |
| Safe area | verticale top 53,67 / bottom 34; orizzontale lati 53,67 / bottom 21 |
| Angoli | 36,67 pt |

## 9. Tastiera (2026-11-14, solo lettura)

Problema riportato: in modalità nativa (0203/0204 + VivaDisplay) la tastiera di Safari (barra degli indirizzi) ha un
passo dei tasti di ~36,7 pt e la colonna di destra (p, cancella, invio) esce oltre 360 pt. Analisi statica della cache
20H392 e dei file di layout della root 20H392 (`/System/Library/PrivateFrameworks/TextInputUI.framework/
KBLayouts_iPhone.dat` e `KBLayouts_Dynamic.dat`, decodificati con un decoder Python che ricalca
`TUIKBGraphSerialization`, nello scratchpad della sessione). Nessuna prova sul telefono.

### 9.1 Dove stanno i layout [V]

- Non in CoreUI né negli `.artwork`: i layout KBStar (alberi `UIKBTree`) sono in **`TextInputUI.framework/
  KBLayouts_<DeviceClass>.dat`** (`+[TUIKeyboardLayoutFactory layoutsFileNameForDeviceClass]`, 0x18fc7725c:
  `MGCopyAnswer("DeviceClass")` → `KBLayouts_%@.dat`, iPod → iPhone; più `KBLayouts_Dynamic.dat` per i layout
  "Crescendo"). 4660 tastiere in quello dell'iPhone (2,3 MB).
- Formato: due dizionari in testa (larghezza → prefisso), poi un bplist nome → offset, poi il grafo serializzato
  (`-[TUIKBGraphSerialization setSerializedData:]` 0x18fc56b24, `objectForOffset:` 0x18fc573d0: byte tipo, nibble
  basso = tipo 0-13, alto = conteggio/flag).
- Tabelle dei prefissi (decodificate dal file):

| Dizionario | Larghezza (pt) → prefisso |
|---|---|
| "bordo minore" (ivar +0x30, verticale) | 320 → `iPhone-Portrait`, 375 → `iPhone-PortraitChoco`, 414 → `iPhone-PortraitTruffle`, 768 → `Wildcat-Portrait`, 1024 → `Wildcat-PortraitFudge` |
| altro bordo (ivar +0x38, orizzontale) | 480 `iPhone-Landscape`, 568 `iPhone-Caymen`, 667 `iPhone-LandscapeChoco`, 736 `iPhone-LandscapeTruffle`, 1024 `Wildcat-Landscape`, 1366 `Wildcat-LandscapeFudge` |

- Geometrie **assolute** per misura: `iPhone-Portrait-QWERTY-URL` 320×216, riga 1 = 10 tasti da **32 pt**
  (`248_320x216_iPhone-Proportional-Ten-on-Ten-Geometry-List`); `iPhone-PortraitChoco-QWERTY-URL` 375×216, tasti da
  **37,5 pt**; `iPhone-PortraitTruffle-…` 414×226, 41,4 pt.

### 9.2 Come UIKit sceglie il layout (iPhone, idioma 0) [V]

1. `-[UIKBScreenTraits initWithScreen:orientation:allowFloating:ignoreRemoteKeyboard:]` (0x188f6c1a4):
   `bounds` (ivar +0x68..+0x80) = bounds della finestra della tastiera attiva (`_activeKeyboardWindowForScreen:`) o,
   se manca, `-[UIScreen _boundsForInterfaceOrientation:]`; **`keyboardWidth` (+0x38) = `bounds.size.width`**;
   `isKeyboardMinorEdgeWidth` (+0x1b) = `min(screen._referenceBounds.size) == keyboardWidth`. Nessuna tabella,
   nessun `_screenType`, nessuna chiave MobileGestalt.
2. `_UIKeyboardGetKBStarName` (0x18911b198): per idioma 0 senza Crescendo e tipo ≠ 127 →
   `prefix = [[TUIKeyboardLayoutFactory sharedKeyboardFactory] keyboardPrefixForWidth:round(keyboardWidth)
   andEdge:isKeyboardMinorEdgeWidth]`, nome = `"%@-%@-%@-%@"` (prefisso, `KBStarLayoutStringForIdiom` es. `QWERTY`,
   mano, tipo es. `URL`), `--` compressi. Se il prefisso è nil → costante `iPhone-Portrait` (0x1d5c43748).
3. `-[TUIKBGraphSerialization keyboardPrefixForWidth:andEdge:]` (0x18fc5ee8c): chiavi ordinate **decrescenti**
   (blocco 0x18fca3000), restituisce il primo prefisso con `chiave ≤ width`. **360 → 320 → `iPhone-Portrait`**
   (con il flag di bordo falso: nessuna chiave ≤ 360 → nil → di nuovo `iPhone-Portrait`). Nessun caso −1/sconosciuto:
   la scelta è per soglie, 360 pt è gestito come lo Zoom schermo dei 320 pt.
4. Adattamento alla larghezza: `-[UIKeyboardLayoutStar stretchKeyboardToFitKeyplane:]` (0x18911d5b0) è vero sul
   telefono quando `keyboard.frame.width ≠ screenTraits.keyboardWidth` (falso solo per tastiera split generata,
   idioma 2, o `_shouldAttemptToAddSupplementaryControlKeys`, che vale solo per l'idioma tastiera 24 = iPad);
   `-[UIKeyboardLayoutStar setKeyplaneName:]` (0x188ffa0b8 / 0x188ffa3a4) chiama allora `-[UIKBTree elaborateLayoutWithSize:
   (screenTraits.bounds.width / keyboard.frame.width, stretchFactorHeight) scale:]`. Con 360: fattore 1,125, **passo
   36,0 pt, riga esattamente 360 pt**.
5. Altri ingressi controllati, irrilevanti a 360 pt: `_UIKeyboardComputeKeyboardIdiomFromScreenTraits` (0x18911e3f0,
   tabella iPhone 320×568 → 21, 375×667 → 22: 360×800 → **22**, come ogni iPhone moderno); `-[UIKBScreenTraits idiom]`
   usa `_UIScreenReferenceBoundsSizeForType` solo per l'iPad; `_UIKeyboardGetDerivedKeyboardForSpecificOrientation`
   ha invece un ramo iPhone decisivo (**corretto in §9.3**: la prima stesura lo dava solo per iPad); `+[UIKeyboard inputUIOOP]` richiede `os_feature UIKit/keyboard_oop` **e** idioma
   iPad: su iPhone la tastiera è **nel processo dell'app**.

### 9.3 Misure sul telefono e causa dello spostamento (aggiornato 2026-11-14)

Misure (nativo 360×800, Safari e Spotlight): passo dei tasti **36,0 pt** (= `iPhone-Portrait` 32 pt × 1,125, quindi
lo stiramento di §9.2.4 avviene), ma tutta l'area dei tasti è **spostata a destra di ~20 pt** = (360 − 320)/2: `q` a
x 23,3..52, `p` da 347 tagliata dal bordo; le altre righe uguali. Lato SpringBoard: `keyboardWidth` 360,
`isKeyboardMinorEdgeWidth` 1, idioma 0, `UIScreen` bounds/referenceBounds 360×800, `UITextEffectsWindow` 360×800,
`UIInputSetHostView` (0, 509; 360×291).

Causa [V nel codice; la centratura finale V dall'effetto misurato]: **due larghezze diverse per la stessa tastiera.**
1. I tasti sono stirati alla larghezza dello schermo: `-[UIKeyboardLayoutStar setKeyplaneName:]` (0x188ffa3a4..
   0x188ffa754) calcola `w = screenTraits.bounds.width − (padding sx + dx)` (`+[UIKeyboardImpl
   deviceSpecificPaddingForInterfaceOrientation:inputMode:]`, 0 in verticale) e chiama `-[UIKBTree
   elaborateLayoutWithSize:(w / keyboard.frame.width, …) scale: origin:(0, 0)]` → tasti da 0 a 360 **nelle coordinate
   della vista della tastiera**.
2. La vista della tastiera invece è larga **320**: `-[UIKeyboard setFrame:]` (0x18911c460) impone sempre la misura di
   `+[UIKeyboardImpl sizeForInterfaceOrientation:ignoreInputView:]` (0x18911c5cc) → `keyboardSizeForInterfaceOrientation:`
   → `defaultSizeForInterfaceOrientation:` (0x18911ca08) → `+[UIKeyboardLayoutStar keyboardSizeForInputMode:
   screenTraits:keyboardType:]` (0x18911cc0c) = **frame del KBStar nel .dat** (`iPhone-Portrait-…` = 320×216), salvo che
   esista una **tastiera derivata** (`_UIKeyboardGetDerivedKeyboard`, 0x18911cd78: se `keyboardSize` ≠ −1 la sostituisce).
   L'ospite (`UIInputSetHostView`, 360) centra la vista da 320 → origine x = 20; dentro, i tasti arrivano a 360 → fino a
   380 sullo schermo. È esattamente lo spostamento misurato.
3. **Chi decide la tastiera derivata** — `_UIKeyboardGetDerivedKeyboardForSpecificOrientation` (0x18975116c), ramo
   idioma 0 (0x189751398): confronta **`-[UIKBScreenTraits keyboardScreenReferenceSize]`** (= `screen._referenceBounds`
   della finestra della tastiera, 0x18912d804) con una **tabella esatta di 6 misure**:

| Misura di riferimento (pt) | Costanti | Tastiera derivata in verticale (0x189751680..0x189751a68) |
|---|---|---|
| 320×693 (mini/12 con Zoom) | 320.0 imm, 693 @0x189eabd08 | `iPhone-PortraitChoco`, `keyboardSize` = (larghezza − padding, 200) |
| **360×780** | 360 @0x189ea9570, 780 @0x189eabd10 | `iPhone-PortraitChoco`, (larghezza − padding, −1 = altezza del layout) |
| 390×844 | @0x189eaab00/08 | `iPhone-PortraitChoco`, (larghezza − padding, −1) |
| 393×852 | @0x189ea76e0, 0x189eabd28 | `iPhone-PortraitChoco`, idem |
| 428×926 | @0x189eabd18/20 | `iPhone-PortraitTruffle`, idem |
| 430×932 | @0x189eabd30/38 | `iPhone-PortraitTruffle`, idem |

   In orizzontale la stessa corrispondenza dà `iPhone-Caymen` / `iPhone-LandscapeTruffle` (0x189751548..0x1897515b4).
   Con la derivata `_UIKeyboardGetKBStarName` usa `derivedKBStarPrefixName` (0x18911b470) e la misura della vista è
   quella dello schermo: così un iPhone 12 (390) usa il layout da 375 stirato a 390 senza spostamenti.
   **360×800 non è in tabella** → nessuna derivata → prefisso dalla larghezza (`iPhone-Portrait`, 320) e vista larga
   320 centrata. (I 375×812/375×667/414×896 non ne hanno bisogno: il layout nativo ha già la loro larghezza.)
4. Non dipende da: `_screenType`, `MGScreenClass`, `ArtworkDeviceSubType`, `isKeyboardMinorEdgeWidth`, preferenze, flag
   nel .dat (il frame del KBStar è solo la misura di disegno, 320). `+[UIKeyboardImpl overrideNativeScreen]` e
   `enableProKeyboard` toccano solo il ramo iPad.

### 9.4 Leve non di codice [V salvo dove indicato]

- **Nessuna leva pulita.** L'unico ingresso è `keyboardScreenReferenceSize` = `_referenceBounds` dello schermo
  dell'app, che deve essere **esattamente** una misura della tabella. Per 360 pt c'è **360×780** (1080×2340 = il
  pannello del 12/13 mini, `MGScreenClass` 22 nota a MobileGestalt): presentare 1080×2340 (kernel/ADT, con 30 px neri
  sopra e sotto o 60 px sotto) farebbe usare a UIKit la strada del mini (`PortraitChoco` stirato a 360, nessuno
  spostamento) e probabilmente sistemerebbe anche altre tabelle (Centro di Controllo, griglia della home: [S]), al
  prezzo di 20 pt di altezza. È una scelta di prodotto, non una correzione della tastiera.
- `keyboardWidth` / scelta di una larghezza 375: non serve e non aiuta (anche `PortraitChoco` senza derivata avrebbe
  la vista larga 375 e taglierebbe a destra).
- Preferenze: nessuna (`com.apple.keyboard EnableMoltoCrescendo` porta ai layout iPad "Dynamic", vedi sotto, senza
  varianti URL/Email; sconsigliato). MobileGestalt/ADT: non letti da questo codice (solo tramite `_referenceBounds`).
- SpringBoard da solo non basta: `_referenceBounds` delle app viene dal contesto di display che SpringBoard manda, ma
  cambiarlo a 360×780 accorcerebbe tutte le app.
- Nota Crescendo (per completezza): `com.apple.keyboard` **`EnableMoltoCrescendo`** (`+[TUIKeyboardLayoutFactory
  crescendoLayouts]` 0x18fc77308) aggiunge `QWERTY` ai layout "Dynamic" (`KBLayouts_Dynamic.dat`, suffisso da
  `min(keyboardScreenReferenceSize)`: < 320 Mini, < 730 Small, < 815 Medium, < 1024 Large, altrimenti Grand,
  `keyboardSuffixForPortraitWidth:` 0x18fca2f7c); esistono solo `Dynamic-QWERTY-{Mini..Grand}`, niente URL/Email.

### 9.5 Correzione raccomandata (hook nel processo)

**Un solo metodo ObjC**: `-[UIKBScreenTraits keyboardScreenReferenceSize]` (0x18912d804) → se idioma 0 e il valore
originale è 360×800 (o 800×360), restituire **360×780** (rispettando l'orientamento). Il selettore ha solo 4 chiamanti
(xref): `_UIKeyboardGetKBStarName` (solo ramo Crescendo), `_UIKeyboardGetDerivedKeyboardForSpecificOrientation`,
`-[UIRemoteKeyboardWindowHosted keyboardWidthForCurrentDevice]` (finestra ospitata, usa già `GSMainScreenPointSize`) e
sé stesso: nessun effetto sul resto di UIKit. Risultato atteso (stessa strada del mini a 360 pt): derivata
`iPhone-PortraitChoco`, `keyboardSize` = 360 × altezza del layout (216 + barre), KBStar `iPhone-PortraitChoco-QWERTY-…`
stirato a 360 (fattore 0,96, passo 36 pt, tasti 34,1 pt), vista larga 360 → origine 0, nessun taglio; in orizzontale
`iPhone-Caymen` derivata alla larghezza.
- Alternativa equivalente per l'effetto visibile: `+[UIKeyboardImpl keyboardSizeForInterfaceOrientation:]` (0x18911c8c8)
  con larghezza = larghezza dello schermo meno il padding; lascia però il layout da 320 stirato (tasti più larghi del
  normale) e salta la logica della derivata (altezze, prefisso).
- Da non toccare: `_UIKeyboardGetDerivedKeyboardForSpecificOrientation` / `_UIKeyboardGetKBStarName` (funzioni C
  private), `-[UIKeyboard setFrame:]` (usata anche da tastiere esterne/di estensione), `_referenceBounds`.
- **Prova immediata**: l'hook va subito in VivaDisplay (SpringBoard) e si verifica sulla tastiera di Spotlight; per le
  app servirà l'iniezione globale (§4.3 D3), con lo stesso codice.
