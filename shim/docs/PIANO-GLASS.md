# TeraScale Glass: vetro nativo nelle barre laterali, la "via di mezzo" (piano, approvato il 2026-11-02)

## Obiettivo
La funzione si chiama **TeraScale Glass** e si gestisce dalla nuova sezione **"Sistema"** dell'app TeraScale Metal
(vedi "Integrazione nell'app").

Ottenere l'aspetto del Liquid Glass di Apple nelle barre laterali e nelle finestre AppKit (Finder, Impostazioni, …)
**senza** cambiare chi compone il desktop. WindowServer continua a usare il compositore OpenGL di OCLP/Moraea; solo
lo shader del vetro di Moraea viene sostituito dallo shader di Apple (gli shader AIR di QuartzCore tradotti in GLSL dal
nostro traduttore). Si sviluppa in un laboratorio fuori da WindowServer; WindowServer vero viene toccato solo alla
fine, su un volume di prova, con le reti di sicurezza descritte sotto.

Scartata: sostituire Moraea con lo SkyLight di serie (WindowServer su Metal, cioè lo shim come GPU del desktop).
Richiederebbe di ricostruire l'uscita sul display, la sincronizzazione vera e altro: mesi di lavoro, rischio alto.
Il costo GPU invece non è un problema, vedi le misure.

## Cosa sappiamo (verificato il 2026-11-02)
**Chi disegna cosa**
- Le barre laterali e il vetro delle finestre AppKit li compone **WindowServer**. Le app non fanno nessun draw
  (Impostazioni: 9 pipeline di prewarm, 0 draw). Lo shim Metal non entra in WindowServer: il kext non concede la
  deroga alla library validation ai processi del desktop (`docs/FASE4.md`) e `TSMtlSystem.m` li esclude.
- Spotlight e SwiftUI in `drawingGroup` sono RenderBox in-process. È già sistemato nella 0.8.0
  (`docs/PIANO.md`, ultima sezione).

**SkyLight installato da OCLP**
- `SkyLight` (221 KB) è lo shim di Moraea. Riesporta `SkyLightOriginal`, uno SkyLight 600 (compatibility 64.0.0), che
  importa **solo** `CARenderOGL*` (il renderer OpenGL di QuartzCore 1195.17.2) e nessuna funzione del renderer Metal.
  WindowServer non può usare il renderer Metal di CoreAnimation nemmeno con un device Metal.
- Lo shim non usa interpose: al caricamento patcha in memoria il codice già caricato (`mach_vm_protect`, `memmem`,
  `mach_vm_read_overwrite`, `_dyld_get_image_*`). Le patch si attivano solo se `getprogname()` è "WindowServer".
- Il vetro di Moraea è GLSL **1.20** (`#version 120`, `attribute`/`varying`, `texture2D`, `GL_ARB_shader_texture_lod`),
  quindi il contesto OpenGL del renderer OGL è di tipo legacy: OpenGL 2.1 su questo driver, con le estensioni
  elencate nella fase 3. Funzioni e uniform (dalle stringhe del binario):
  - `cg9m_sdf`, `cg9m_sc`, `cg9m_nrm`: forma e normali;
  - `cg9m_mip` (`cg9m_mipT`): campioni sfocati per livello di mip;
  - `cg9m_vblur`, `cg9m_vbl`: sfocatura variabile;
  - `cg9m_keyFill` (`cg9m_kf[5]`) e `cg9m_kfLobe`: riflessi;
  - `cg9m_sdfFill` (`cg9m_sfa[2]`) e `cg9m_sdfGrad` (`cg9m_sga[2]`, `cg9m_sgT`);
  - `cg9m_vcmb` (`function_arg[11]`, matrice colore vibrante);
  - parametri generali in `cg9m_g[26]`;
  - macro `CG9M_CM`, `CG9M_CA`, `CG9M_T0`, `CG9M_RT`, `CG9M_RS`, `CG9M_N0`.
- Nello shim c'è la stringa `/var/tmp/SkyLight-CGL3A2-DISABLE`: probabilmente un file che, se esiste, spegne una delle
  patch. Il significato **non è verificato**.
- Preferenza globale attuale: `NSGlassDiffusionSetting = 1`.

**Vetro nativo di Apple (riferimento)**
- `tools/caglass` sotto `DYLD_INSERT_LIBRARIES=build/libTSMetalInject.dylib` disegna con il renderer Metal di
  CoreAnimation sul device dello shim: gli shader originali di QuartzCore, tradotti. È il riferimento "perfetto".
- Pipeline usate (scene `all`, `glass`, `sidebar`, `clear`):
  - `variable_blur_vert_lpf/glass_background_no_bleed_lpf`
  - `sdf_filter_vert_lpf/glass_background_sdf_no_bleed_lpf`
  - `downsample_blur_vert_lpf/{downsample_4,downsample_8,narrow_blur_11,variable_blur_downsample}_frag_lpf`
  - gli shader generici `Vfx*`

  Tutto il vetro di QuartzCore si traduce: 150/158 funzioni, le 8 che mancano sono varianti `render_target` per GPU Apple.
- **Costo misurato** a 1920×1080, la risoluzione dello schermo, con contenuto che si muove sotto i materiali
  (`CAGLASS_SIZE=1920x1080 CAGLASS_FRAMES=5000 TSMTL_PROFILE=1`):

  | Cosa | GPU per fotogramma |
  |---|---|
  | totale | ~1,5 ms (~9% di 60 fps) |
  | `glass_background_no_bleed` | 0,13 ms |
  | copia a schermo intero | 0,87 ms |
  | riempimenti | 0,19 ms |
  | sfocature | < 0,05 ms |

**Laboratorio (nessun rischio)**: `tools/caglass` con `CAGLASS_OGL=1` usa il renderer OpenGL di CoreAnimation su un
FBO fuori dallo schermo.
- Se la copia del binario si chiama `WindowServer`, le patch di Moraea si attivano nel processo di prova:
  ```
  cp tools/caglass /tmp/lab/WindowServer
  CAGLASS_OGL=1 /tmp/lab/WindowServer out.png all
  ```
  La barra laterale esce **identica** a quella del WindowServer vero. Il pannello `NSGlassEffectView` invece
  **non compare** nel laboratorio (punto aperto, fase 0).
- Con un nome diverso si vede il renderer OGL di Apple senza patch: barra laterale grigia piatta, vetro come
  rettangolo bianco.
- Riferimento del WindowServer vero per la stessa scena: `CAGLASS_WINDOW=5 tools/caglass x all`, poi
  `screencapture -l<window>`. Il programma stampa il numero della finestra.

## Piano
**Fase 0: il laboratorio uguale a WindowServer.** Far comparire il pannello di vetro anche in `CAGLASS_OGL` +
"WindowServer". Ipotesi da verificare:
- la scena del vetro passa da funzioni di `SkyLightOriginal` (backdrop, `CARenderOGLSetBackdropSubstituteColor`,
  feature flag) che `CARenderer` non chiama;
- serve `CARenderOGLSetFeatureFlags` o lo stesso contesto CGL (profilo, formati) che usa WindowServer;
- conviene chiamare direttamente `CARenderOGLNew`/`CARenderOGLRender` come fa `SkyLightOriginal`, invece di `CARenderer`.

Criterio: `tools/imgdiff` tra laboratorio e cattura del WindowServer vero quasi a zero, sulle scene `all` e `glass`.

**Fase 1: capire i punti di aggancio di Moraea.** Nel laboratorio, un interpose solo per il processo di prova
(`glShaderSource`, `glUniform*`, `glBindTexture`, `glDrawArrays/Elements`) registra:
- i programmi GLSL completi che Moraea genera;
- i valori di `cg9m_g[26]`, `cg9m_kf`, `cg9m_sfa`, `cg9m_sga`, `function_arg` per ogni draw del vetro;
- le texture in ingresso: backdrop, mip, gradiente.

Ne esce una tabella `cg9m_g[k]` → significato: raggio, spessore del bordo, intensità della rifrazione, tinta, ecc.
Strumenti già pronti per il confronto: `tools/sheet`, `tools/imgdiff`.

**Fase 2: gli ingressi del vetro di Apple.** Dal riferimento Metal servono:
- le strutture uniform di `glass_background*`, `glass_foreground*`, `sdf_gen_*`, `simple_rim`, `variable_blur*`
  (metadati AIR con `tools/airdump`, valori con `TSMTL_DRAW_TRACE` + `TSMTL_DRAW_TRACE_DIR`, che salva i buffer
  `buf-<hash>.bin` a partire dall'offset di binding);
- la sequenza dei passaggi: SDF, gradienti, downsample, sfocatura, sfondo del vetro, primo piano, bordo.

Poi la mappa tra quegli ingressi e quello che Moraea ha a disposizione nei suoi punti di aggancio.

**Fase 3: lo shader sostitutivo, nello stesso contesto di Moraea (decisa il 2026-11-02).** Il GLSL del vetro di
Apple gira direttamente nel draw di Moraea, nel suo contesto legacy: niente secondo contesto, niente copie, niente
flush. Va fatto un **backend "GLSL 1.20 + `GL_EXT_gpu_shader4`"** del traduttore, limitato a ciò che serve al vetro.
Le conversioni sono quasi solo sintattiche:

| GLSL 4.10 (oggi) | GLSL 1.20 + `EXT_gpu_shader4` |
|---|---|
| `#version 410 core` | `#version 120` + `#extension GL_EXT_gpu_shader4 : require` (+ `GL_ARB_shader_texture_lod`, `GL_ARB_texture_rectangle`) |
| `in` / `out` dei varying, `noperspective` | `varying` (`noperspective varying` con gpu_shader4) |
| `layout(location = N) out vec4 oN` | `gl_FragData[N]` (`gl_FragColor` per un solo target) |
| `uint`, `uvec*`, operazioni sui bit, `floatBitsToUint` | `unsigned int`, `uvec*`, operazioni sui bit, `floatBitsToUint` (tutto in gpu_shader4) |
| `texture(s, uv)`, `textureLod`, `textureGrad` | `texture2D`, `texture2DLod`, `texture2DGradARB` |
| `texelFetch(s, p, l)`, `textureSize(s, l)` | `texelFetch2D`, `textureSize2D` |
| `sampler2DRect`, `texture(r, px)` | `sampler2DRect`, `texture2DRect` |
| UBO `uniform fbufN { uvec4 fbufN_d[K]; }` | `uniform uvec4 fbufN_d[K]`, caricato con `glUniform4uivEXT` (gli UBO non ci sono) |
| texture buffer (buffer `device`) | non servono al vetro; se servisse, una texture 2D intera |
| `fma`, `bitfieldExtract`/`Insert` | espansioni a mano (sono GLSL 4.00) |

Per non toccare il percorso delle app conviene un flag del traduttore (`TSAirGLSL120`) usato solo dal laboratorio e
dal codice per WindowServer. Si confronta nel laboratorio, pixel per pixel, con il riferimento Metal (`caglass`
Metal contro `caglass` OGL "WindowServer").

Verificato con una sonda (`CGLCreateContext` senza profilo, 2026-11-02):
- **Contesto legacy:** `2.1 ATI-1.66.42`, GLSL 1.20.
- **Presenti:** `EXT_gpu_shader4`, `EXT_texture_integer`, `ARB_texture_float`, `ARB_texture_rectangle`,
  `ARB_shader_texture_lod`, `EXT_framebuffer_object`, `NV_texture_barrier`.
- **Assenti:** uniform buffer object, texture buffer object.
- **Compilazione:** `#version 150` e `#version 410` rifiutati; uno shader 1.20 + gpu_shader4 con `unsigned int`,
  operazioni sui bit e `texelFetch2D` compila.

Resta da confermare (fase 0) che il contesto del renderer OGL **dentro** WindowServer e nel laboratorio sia proprio
legacy 2.1 con le stesse estensioni: `glGetString` chiamato nel contesto corrente durante il draw del vetro.

**Scartate**
- **Rendere il nostro 4.1 il motore di WindowServer.** Su macOS OpenGL 4.1 esiste solo come profilo "core", non
  retrocompatibile: niente fixed-function, niente GLSL 1.20, nessun profilo di compatibilità. Renderer OGL di
  CoreAnimation, SkyLight 600 e Moraea sono scritti per il contesto legacy, quindi servirebbe uno strato di
  traduzione legacy→core sotto l'intero compositore: stesso rischio di sostituire Moraea.
- **Ripiego, solo se il backend 1.20 non basta: un secondo contesto 4.1 nostro.** La condivisione di oggetti tra un
  contesto core e uno legacy non è permessa (`CGLCreateContext`: "invalid share context"), quindi lo scambio passa da
  IOSurface (`CGLTexImageIOSurface2D` in entrambi). Per ogni regione di vetro: copia dello sfondo, `glFlush`, cambio di
  contesto, i passaggi di Apple in 4.10, ritorno, composizione. Costo di sincronizzazione da misurare, più codice dentro
  WindowServer.

**Fase 4: come portarlo dentro WindowServer.** Domanda aperta, da decidere prima di scrivere codice di consegna:
- (a) **root patch del binario di Moraea**: sostituire le stringhe GLSL o i suoi punti di aggancio. Sta sul volume
  sigillato e un ripasso delle patch di OCLP la sovrascrive;
- (b) **una libreria nostra caricata in WindowServer** che sostituisce il programma del vetro di Moraea quando viene
  compilato (`glShaderSource`/`glLinkProgram`). Oggi nessun vettore la carica: il kext nega la deroga ai processi del
  desktop e il nostro driver non si carica in WindowServer. Servirebbe una deroga dedicata nel kext, limitata a un
  file preciso e al solo WindowServer, più un modo di caricarla. WindowServer è un binario di piattaforma, quindi le
  variabili `DYLD_*` non funzionano;
- per ognuna: un interruttore per spegnerla senza riavvio, più quello di Moraea se si conferma il suo significato.

**Fase 5: prova sul WindowServer vero**, solo con le reti di sicurezza (sezione sotto). Prima su un volume macOS di
prova, poi sul sistema principale.

**Fase 6: integrazione nell'app TeraScale Metal**: sezione "Sistema" → TeraScale Glass, CLI `tsmtl glass`, contratto
in `policy.plist`, passo di installazione (sezione "Integrazione nell'app").

## Integrazione nell'app: sezione "Sistema" → TeraScale Glass (fase 6)
TeraScale Glass è una funzione **di sistema**: agisce su WindowServer, non su un'app. Va quindi in una sezione nuova
della barra laterale di TeraScale Metal (`gui/Sources/App.swift`), **"Sistema"**, distinta da "Impostazioni" (policy
per app, spoofing, stato) e da "Sperimentale" (Compute). Oggi le sezioni sono "Monitor", "Impostazioni" e
"Sperimentale"; "Sistema" va tra "Impostazioni" e "Sperimentale" e TeraScale Glass è la sua prima voce.
(Dalla 0.10.0 anche TeraScale Compute è uscito dalla sperimentazione ed è la seconda voce di "Sistema"; la sezione
"Sperimentale" non c'è più finché non arriva una nuova funzione sperimentale.)

**App (SwiftUI)**
- `SidebarItem.glass`: titolo "TeraScale Glass", con un'icona SF Symbol da scegliere (per esempio `drop.halffull` o
  `square.on.square.intersection.dashed`), più una vista `GlassView` sul modello di `ComputeView.swift`.
- Stato in sola lettura:
  - componente installato o no, versione e tag del traduttore, coerenza con il driver installato;
  - attivo nel WindowServer in esecuzione, sì o no (lo scrive il componente, vedi "Contratto");
  - crash di WindowServer dall'attivazione (`/Library/Logs/DiagnosticReports/WindowServer_*`);
  - stato del ritorno automatico.
- Comandi:
  - interruttore on/off, con una conferma che spiega il rischio, senza riavvio (vedi la fase 4);
  - "prova per un avvio", cioè l'attivazione a scadenza con il ritorno automatico;
  - ripristino del vetro di Moraea;
  - parametri principali, se la fase 1-2 li rende esponibili: intensità della rifrazione, sfocatura, bordo.
- Un'anteprima affiancata, Moraea contro Apple contro TeraScale Glass, generata con il laboratorio
  (`tools/caglass`): utile per decidere senza toccare WindowServer.

**CLI (`tsmtl`)**: `tsmtl glass [--json]` (stato), `tsmtl glass on|off`, `tsmtl glass trial` (un solo avvio con ritorno
automatico) e `tsmtl glass revert`, sullo stesso stile di `tsmtl compute`.

**Contratto** (da aggiungere a `docs/FASE4-INTERFACCE.md`)
- `policy.plist` → `System.Glass = { Enabled: bool, Trial: { Armed: bool, Deadline: date }, Params: { ... } }`.
  Lo legge il componente dentro WindowServer, che deve poterlo leggere come `_windowserver`. Se il file manca o è
  illeggibile, TeraScale Glass resta spento.
- Il componente riporta il proprio stato in un file di stato o nel log `com.terascale.mtlshim`, categoria `glass`
  (attivo, versione, shader caricati, errori). L'app lo legge come fa con le statistiche.
- Lo spegnimento deve funzionare anche se l'app non si apre: un file interruttore (per esempio
  `/var/tmp/TeraScaleGlass-DISABLE`, sul modello di quello di Moraea), che `tsmtl glass off` crea anche via SSH.

**Installazione**: un passo in `system/install.sh` e `update.sh` (`--glass`), separato dal driver, con backup in
`backups/` e revert. Per default è spento: lo si accende solo dalla sezione "Sistema" o con `tsmtl glass`.

## Reti di sicurezza (obbligatorie per le fasi 4-5)
- **Mai dalla sessione grafica.** Un crash di WindowServer chiude tutte le app, compreso il Terminale con Claude Code.
  Si lavora via SSH da un altro dispositivo, dentro `tmux`. Il Login remoto va attivato dall'utente: serve admin.
- **Ritorno automatico.** Un LaunchDaemon "a scadenza": la modifica vale per un solo avvio e, se non viene confermata
  entro N minuti, rimette i file originali e riavvia. Conta anche i report `WindowServer_*` in
  `/Library/Logs/DiagnosticReports`.
- **Volume di prova.** Il contenitore APFS (disk1) ha ~403 GB liberi: un secondo macOS 26 con le root patch di OCLP
  su un altro volume, così si sperimenta senza rischiare il principale. Escludere il nostro kext dalla EFI non annulla
  una modifica al volume di sistema, che va tolta con il revert delle patch di OCLP.
- **Backup** dei file toccati in `backups/`, come fanno `system/install.sh` e `update.sh`.

## Criteri di riuscita
- Barra laterale e `NSGlassEffectView` uguali al riferimento Metal entro una soglia di `tools/imgdiff` da fissare in
  fase 2, in modalità chiara e scura, con `NSGlassDiffusionSetting` 0 e 1.
- Costo GPU del vetro ≤ ~2 ms per fotogramma a 1920×1080 (riferimento nativo 1,5 ms).
- Nessuna regressione negli altri effetti di Moraea: menu, Dock, Centro di controllo, ombre.
- Disattivabile senza riavvio: dalla sezione "Sistema" dell'app, da `tsmtl glass off` o con il file interruttore.

## Implementazione (2026-11-02, driver 0.9.0, kext 1.2.0)
Fatto in modo più semplice di quanto previsto nelle fasi 3-4: nessun secondo contesto, nessun hook sui draw, nessuna
modifica ai file di Moraea o di sistema.

**Come funziona** (`src/TSGlass.m`)
- Moraea genera due shader del vetro senza bleed: `cg9m_gbs(false)` (forma calcolata, porting di
  `glass_background_sdf_no_bleed`) e `cg9m_gbt(texcoord0_0, texcoord1_0, false)` (forma da una texture SDF di
  CoreAnimation, porting di `glass_background_no_bleed`; CoreAnimation passa a questa dopo pochi fotogrammi).
- Quando un programma che li contiene è stato linkato, il componente legge il sorgente del fragment shader, inserisce lo
  snippet con gli shader di Apple, sostituisce la chiamata di `main` e rilinka **dentro la stessa chiamata di
  `glLinkProgram`**: CoreAnimation e Moraea chiedono le location delle uniform al programma finale e continuano a pilotarlo
  come prima (Moraea carica `cg9m_g` prima di ogni draw). Il sorgente passa dalla `glShaderSource` di GLEngine (simbolo
  locale `_glShaderSourceARB_Exec[Thread]`), così l'hook di Moraea non lo vede. Se non compila: torna il sorgente di Moraea.
- Lo stato GL non viene toccato: il livello 1 della texture del vetro di Apple (`variable_blur_downsample`) è calcolato
  nello shader a partire da `texture0` (il ¼ del fondo che CoreAnimation prepara già); il livello 0 è `texture0` stesso.
- Hook solo sugli slot `link_program_ARB` e `use_program_object_ARB` della tabella del contesto (GLEngine sostituisce
  gli slot dei draw, quelli no). I contesti si trovano come fa Moraea: Moraea compone il desktop da sé e chiama QuartzCore
  con puntatori suoi, e il suo `CG9M_BeginRendering(renderer, …)` aggancia il contesto del renderer (`*(renderer +
  0x268)`) e poi chiama `*_gQCOrigBeginRendering`. Il componente mette uno stub "pre-chiamata" in quel puntatore (dati di
  Moraea, simbolo locale; lo riempie Moraea con `dispatch_after`, quindi si riprova ogni ¼ s per 2 minuti) e legge
  l'offset 0x268 dal codice di `CG9M_PatchShaderSource`. Gli stub sulle importazioni `CARenderOGL*` di SkyLightOriginal
  restano come ripiego: nel WindowServer vero non vengono chiamati (verificato il 2026-11-02).
- **Programmi linkati prima dell'aggancio** (WindowServer disegna la schermata di login prima che Metal carichi il
  driver): al primo `glUseProgram` del contesto il componente cerca i programmi esistenti e ricostruisce quelli del
  vetro sul posto. Per poterlo fare lo shader composto tiene il codice di Moraea dietro una condizione mai vera ma non
  eliminabile (`cg9m_g[21].x < 0.0`): l'insieme delle uniform attive resta quello di Moraea e il driver AMD gli dà le
  stesse location (verificato con entrambe le varianti); i valori delle uniform vengono salvati e rimessi. Se una
  location cambiasse, torna lo shader di Moraea con i suoi valori.
- Interruttore a caldo: stesso meccanismo, al primo uso di ogni programma dopo il cambio lo shader passa a quello di
  Moraea (o torna a quello di Apple). Nessuna uniform in più.
- Ingresso in WindowServer: Metal carica già il bundle all'avvio; il kext 1.2 non lo rifiuta più **solo** per WindowServer
  e **solo** con `System.Glass.Enabled`. Lì il device Metal resta spento (processo critico): gira solo il componente.

**Mappa dei parametri** (`f1` di Apple ← `cg9m_g[26]` di Moraea), verificata sui buffer del renderer Metal per la stessa scena:

| `f1` di `glass_background_sdf_no_bleed` | `cg9m_g` |
|---|---|
| righe 0-2 (forma) | 23-25 |
| righe 3-7 (rifrazione, rampe, ombra) | 0-4 |
| righe 8 … 12.xy (tre matrici colore 3×4 in half) | 5-13, quattro half per riga |
| 12.zw | 14.xy |
| 13 | 14.zw, 15.xy |
| 14 | 15.zw, 16.xy |
| 15.w | 17.y |
| 16.zw | 18.xy |
| 17 | 18.zw, 19.xy |
| 18.xyz | 19.zw, 20.x |
| 19.x | 20.z |
| `f6.x` | 1 |

`glass_background_no_bleed` ha lo stesso `f1` senza le tre righe della forma. Varying: `sdf_uv` = `cg9m_v0`, `src_uv` =
`cg9m_v1` (normalizzato a `S0 = cg9m_g[21].xy`); nella variante a texture `texcoord0_0 · cg9m_g[21].zw` e
`texcoord1_0 · cg9m_g[22].zw`, SDF da `texture1` (`cg9m_g[22].xy` texel). Non mappate: le righe 15.xyz e 16.xy, usate solo
dalle varianti con bleed (che restano a Moraea; il componente lo scrive nel log).

**Traduzione**: `tools/glassgen` traduce dal `default.metallib` di QuartzCore `glass_background_sdf_no_bleed_lpf`,
`glass_background_no_bleed_lpf` e `variable_blur_downsample_frag_lpf` (lo stesso GLSL che il renderer Metal crea: nessuna
differenza di function constant) e li converte in GLSL 1.20 + `EXT_gpu_shader4` (`TSGlassBuildSnippet`: uniform → campi di
`cg9m_g`, half già spacchettati, `fma`/`mix` booleano/`abs` intero sostituiti, varianti rettangolo tolte). Poi compone e
linka lo snippet con gli shader veri di Moraea (`tests/glass/moraea-glass*.frag`, catturati con `exp/glspy`) in un contesto
legacy 2.1 e scrive `glass.glsl`.

**Misure nel laboratorio** (scena `glass`/`all`, 840×420, contro il renderer Metal di Apple sullo shim):

| | pixel diversi > 8/255 | > 24/255 |
|---|---|---|
| TeraScale Glass (3, 10, 50 fotogrammi) | 0,74-0,77% | 0,01% |
| WindowServer vero con Moraea (scena `all`) | 18,8% | 0,23% |

Le differenze rimaste sono nel testo sfocato sotto il vetro: il ¼ di CoreAnimation OGL non è identico al `downsample_4` di
Metal, e il livello 1 è valutato in modo continuo invece che campionato da una texture 64×32. Prima, nel laboratorio, il
pannello di vetro di Moraea non compariva affatto (`cg9m_mipT` sull'unità di `texture0`): ora compare.

**Laboratorio**
```
make build/libTSMetal.dylib build/libTSGlassLab.dylib tools/glassgen
tools/glassgen -o <cfg>/glass                     # + <cfg>/policy.plist con System.Glass.Enabled
cp tools/caglass <lab>/WindowServer
rm -f <cfg>/TeraScaleGlass/starts                 # la guardia sui crash conta anche gli avvii del laboratorio
TSMTL_CONFIG_DIR=<cfg> DYLD_INSERT_LIBRARIES=build/libTSMetal.dylib CAGLASS_OGL=1 CAGLASS_FRAMES=10 \
  <lab>/WindowServer out.png all            # TSGLASS_LATE_TEST=10: programmi trattati come linkati prima dell'aggancio
```
(`build/libTSGlassLab.dylib`, l'interposer di `CGLCreateContext`, non serve più: il contesto arriva dall'aggancio su
Moraea, attivo anche nel laboratorio.) Nel laboratorio si carica anche il driver installato: il componente parte una
volta sola per processo (`TSGLASS_STARTED`).

**Prova sul WindowServer vero** (fase 5; non fatta dalla sessione grafica, vedi "Reti di sicurezza"):
1. `make && make test`, poi `zsh system/update.sh` (driver 0.9.0) e `zsh system/glass.sh prepare` (nessun effetto su
   WindowServer);
2. `zsh system/glass.sh kext` (kext 1.2 sulla EFI) e riavvio: con `System.Glass` spento il kext si comporta come la 1.1;
3. da SSH o dal Terminale: `tsmtl glass trial 15`, poi riavvio (su questo Mac il logout NON riavvia WindowServer: verificato il 2026-11-02, pid invariato): il componente entra al prossimo avvio di WindowServer;
4. `tsmtl glass` deve dire "attivo in WindowServer: N programmi"; `tsmtl log --filter glass` mostra i contesti e i
   programmi; se va bene `tsmtl glass confirm`, altrimenti non fare niente (dopo 15 minuti torna Moraea) o `tsmtl glass off`.

Reti di sicurezza del componente: `touch /var/tmp/TeraScaleGlass/DISABLE` (spegne entro un secondo, anche via SSH), guardia
sui crash (3 avvii di WindowServer in 2 minuti → spento finché non si riaccende), scadenza della prova, ritorno a Moraea se lo
shader non compila, `-tsmtlnolv` o `-tsmtloff` tra i boot-arg (il kext non lo carica più).

**Aperto**
- WindowServer vero, 2026-11-02: il driver entra (kext 1.2) e il componente parte, ma con gli stub su `CARenderOGL*`
  nessun contesto veniva agganciato (Moraea non passa da quelle importazioni). Corretto con l'aggancio su
  `_gQCOrigBeginRendering` e la ricostruzione dei programmi già linkati, provati nel laboratorio senza interposer
  (`make test-glass`: casi 3, 10 fotogrammi e "late").
- Varianti con bleed (`cg9m_gbs(true)`/`cg9m_gbt(..., true)`): WindowServer le usa (2 programmi su 6 il 2026-11-02).
  Mappate dopo: 15.xy = `cg9m_g[16].zw` (intervallo di distanza), 15.z = `g[17].x` (quantità), 16.xy = `g[17].zw`
  (coefficienti di luminanza), coerenti con i valori del renderer Metal; lo snippet ha `glass_background_sdf_lpf` e
  `glass_background_lpf` dietro `TSG_BLEED`. `glassgen` controlla tutte e quattro le varianti, comprese le location.
- **Barre laterali delle app (Impostazioni, Note): restano piatte, e non per lo shader.** Albero dei layer di una
  finestra con `NSSplitViewItem sidebar` (`caglass split`, `CAGLASS_LAYERS=1`): sotto la barra c'è un layer nero opaco e,
  a livello di finestra, un `CABackdropLayer` `NSCGSWindowBehindWindowCaptureBackdropGroup` (`windowServerAware`,
  `captureOnly`, sfocato, scala 1/8): la cattura di ciò che sta dietro la finestra, che WindowServer deve riempire e il
  vetro della barra usa. Il compositore di Moraea non la riempie (nel WindowServer vero la barra misura un colore unico,
  deviazione 0,9 = solo il rumore); i materiali "behind window" classici invece funzionano (prova con
  `CAGLASS_WINDOW=6 CAGLASS_BEHIND=1 caglass x all`).
- **Barre laterali: risolto lato app** (`src/TSGlassSidebar.m`, 2026-11-02). Prove sul WindowServer vero, con una
  finestra a righe dietro (le catture vanno fatte con `screencapture -R`: `-l` disegna la finestra da sola, senza
  niente dietro): togliere lo sfondo alla finestra e far disegnare la cattura della radice riproduce Tahoe, ma rende
  trasparente tutta la finestra; un `CABackdropLayer` nudo sotto la barra non basta (il vecchio WindowServer riempie il
  gruppo solo per le finestre in cui un `NSVisualEffectView` "behind window" ha registrato il backdrop); funziona un
  `NSVisualEffectView` behind-window sotto `NSBlurryAlleywayView`, ridotto al suo `CABackdropLayer` (via `fill`, `tone`,
  `desktop tint` e il filtro `colorSaturate`): 0,05% di pixel diversi oltre 16/255 dalla cattura vera. Il componente lo
  aggiunge nelle app AppKit (anche SwiftUI `NavigationSplitView`, cioè Impostazioni) quando `System.Glass` è acceso,
  all'avvio dell'app; serve solo il driver installato e riaprire le app, non il riavvio. Prova ripetibile:
  `tests/glass/sidebar.sh` (apre finestre per qualche secondo; deviazione della barra 0,9 senza, 8,2 con).
- **Chrome non si apriva** (driver installato alle 14:41, 2026-11-02): il componente parte in ogni processo AppKit che
  carica il bundle, e la scansione delle finestre già aperte chiedeva `+[NSApplication sharedApplication]`, che CREA
  l'applicazione. Nel processo GPU di Chrome (helper senza NSApplication, sandbox senza WindowServer) lanciava
  un'eccezione non presa: SIGSEGV, sei volte, poi il browser "GPU process isn't usable. Goodbye." (dump in
  `~/Library/Application Support/Google/Chrome/Crashpad/completed`, tipo `gpu-process`, frame `TSGlassSidebar.m:114`).
  Corretto: la scansione usa solo `NSApp` già esistente (letto con `dlsym`, mai creato) ed è dentro `@try`; le finestre
  successive arrivano comunque da `-viewDidMoveToWindow`. Prova: `tests/glass/helper.sh` (in `make test-glass`): un
  processo AppKit senza NSApplication e con WindowServer negato carica il driver e deve restare senza. Prova con
  Chrome: il bundle va messo dove la sandbox GPU legge (dentro la copia in `apps/`, `TSMTL_SIM_BUNDLE` +
  `libTSRegSim`); `~/metal-shim/build` e lo scratchpad non sono leggibili dall'helper GPU. `sidebar.sh` ora spegne il
  vetro esplicitamente nella prova "senza" (il driver installato ha anche lui il componente).
  `caglass split` e le variabili `CAGLASS_LAYERS`, `CAGLASS_UNCAPTURE`, `CAGLASS_CLEARWIN`, `CAGLASS_SIDEBAR_BACKDROP`,
  `CAGLASS_STRIP`, `CAGLASS_SPLIT_VEV`, `CAGLASS_SPLIT_EMPTY`, `CAGLASS_VEV_BEHIND` restano per le prove.
- **Laboratorio e driver installato**: una copia di laboratorio chiamata WindowServer carica anche il driver installato.
  Senza `TSMTL_CONFIG_DIR` quella copia usava lo stato vero (`/var/tmp/TeraScaleGlass`): tre prove in due minuti hanno
  fatto scattare la guardia sui crash del WindowServer vero (2026-11-02). Dalla build successiva il componente parte solo
  nel WindowServer vero (`/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer`) o con
  `TSMTL_CONFIG_DIR`; fino all'installazione, mai lanciare la copia di laboratorio senza `TSMTL_CONFIG_DIR`.
- Le barre laterali di tipo `NSVisualEffectView` (`downsample_8` + `narrow_blur_11` nel renderer Metal) restano a Moraea.
- L'anteprima affiancata nella sezione Sistema (Moraea / Apple / TeraScale Glass) non c'è ancora.

## Stato alla consegna della pianificazione (2026-11-02, superato dalla sezione sopra)
- Driver 0.8.0 compilato e testato, **non installato**: `zsh ~/metal-shim/system/update.sh`.
- Pronti: `tools/caglass` (Metal, `CAGLASS_OGL`, `CAGLASS_WINDOW`, `CAGLASS_SIZE`, `CAGLASS_FRAMES`, ms per
  fotogramma), `tools/rbglass`, `tools/mslbundle`, `tools/imgdiff`, `tools/sheet`.
- Fase 0 da iniziare: il pannello di vetro non compare nel laboratorio OGL "WindowServer".
- Fase 3 decisa: backend del traduttore "GLSL 1.20 + `EXT_gpu_shader4`" nel contesto di Moraea; secondo contesto
  4.1 via IOSurface solo come ripiego.
