# TeraScale Swift: accelerare il runtime Swift su questa macchina – ricerca e implementazione (2026-11-02)

Seguito di `docs/OTTIMIZZAZIONE-AIR.md` §6 (pagina "Sfondi" di Impostazioni). Macchina: iMac12,1, Core i5 Sandy Bridge a
4 thread, 4 GB di RAM, macOS 26 con OCLP/Moraea, runtime Swift 6.3 (`__swift63_hooks`). Strumenti, prototipo e dati
grezzi: `exp/swiftrt/` (dati in `exp/swiftrt/data/`).

## 1. Sintesi

1. **Una ricerca di conformità fallita scandisce tutti i record di conformità di tutte le immagini caricate**, a
   ~20 ns per record su questa CPU. In un processo con SwiftUI i record sono 69 000 (1,4 ms per ricerca); nell'app
   TeraScale Metal, dopo 15 s, sono 180 000 in 1086 immagini (2–4 ms per ricerca, picchi di 87 ms). SwiftUI, tramite
   AttributeGraph, chiede per migliaia di tipi "è `Equatable`?", e quasi sempre la risposta è no.
2. **Su questa macchina le tabelle precalcolate di dyld non coprono i "no".** dyld le abilita solo per i processi
   lanciati con una closure precalcolata (`PrebuiltLoaderSet`), e qui nessuna immagine risulta pre-ottimizzata
   (0 su 125). Le root di OCLP (SkyLight, IOSurface, OpenGL, CoreDisplay, IOAccelerator… 22 immagini caricate dal disco
   invece che dalla shared cache) rendono `dyld_shared_cache_some_image_overridden()` vero. **Ipotesi H1**, da verificare
   dentro System Settings (fase 0): su un Mac di serie le app Apple scandiscono solo i ~4000 record fuori dalla cache,
   cioè ~17 volte meno lavoro; su questo Mac le root di OCLP lo impediscono.
3. **Esiste un punto di aggancio pulito.** Ognuno dei quattro ingressi `swift_conformsToProtocol*` del runtime legge la
   propria funzione di override da una variabile atomica nei dati di libswiftCore (1 = nessun override) e, se c'è, la
   chiama. Scrivere lì un puntatore è un **aggancio di soli dati**: nessuna patch del codice, nessun problema di firma.
   Il meccanismo ufficiale (sezione `__swift63_hooks`) invece si legge solo dall'eseguibile principale, quindi non serve
   per le app Apple.
4. **Il prototipo funziona.** `exp/swiftrt/tsswift.c` indicizza, per ogni protocollo chiesto, i descrittori di tipo
   nominati dai suoi record e risponde subito "no" per le struct e le enum che nessun record nomina; tutto il resto va
   al runtime. Sull'app TeraScale Metal: **CPU nei primi 15 s da 11,4 s a 7,4 s (−35%, 3 prove per lato)**, **0 risposte
   diverse dal runtime** in 2600 confronti (modalità di validazione), 0,75 MB di memoria per processo. Restano ~2–3 s
   di ricerche che una fase 2 può ridurre (conformità condizionali, classi).
5. **Consegna e copertura**: il bundle `TeraScaleMTLDriver` è già caricato in System Settings, `Wallpaper.appex`,
   `WallpaperAerialsExtension` e `NeptuneOneWallpaper` (lo dice il log della policy), con la deroga alla library validation
   del kext. Arriva però tardi: ~7 s dopo l'avvio in System Settings, ~1,5 s in `Wallpaper.appex`.
6. **Raccomandazione: tenere il progetto sotto TeraScale**, come modulo "TeraScale Swift" nel core del bundle (lo stesso
   schema di Compute), con chiave di policy, kill switch e categoria di log propri, e codice separabile. Un progetto a
   parte dovrebbe ricostruire proprio la parte più delicata, cioè entrare nei processi Apple, e oggi non ha un veicolo
   migliore (§9).
7. **Implementato nel driver 0.12.0 (§11)**: fasi 0, 1, 2 e 4 tranne l'accensione predefinita. Oltre al prototipo,
   risponde da solo anche per le conformità condizionali, le classi e le tuple/funzioni/metatipi. App TeraScale Metal:
   **CPU nei primi 15 s da 8,97 s a 3,78 s (−58%)**, 0 differenze dal runtime su ~5000 risposte rapide per avvio;
   restano al runtime ~100 ricerche fallite (0,1–0,2 s). Spento per impostazione predefinita: `tsmtl swift on`.
8. **La decodifica software degli Aerial (`VTDecoderXPCService`, ~1,3 core a pagina aperta) resta fuori**: non è Swift,
   e la GPU non espone UVD a VideoToolbox. Il rimedio resta uno sfondo statico.

## 2. Il problema di partenza
Da `OTTIMIZZAZIONE-AIR.md` §6: all'apertura a freddo di Impostazioni → Sfondi, ~24 s di CPU su 4 thread in ~20 s.
System Settings 10,8 s e `Wallpaper.appex` 8,9 s, con il 97% e l'89% del tempo attivo in `libswiftCore`
(`swift_conformsToProtocol`), chiamato da AttributeGraph (`LayoutDescriptor::Builder::should_visit_fields`,
`metadata::equatable`). La GPU non c'entra: 0 pipeline e 0 draw.

## 3. Come il runtime cerca una conformità, e perché qui costa tanto

### 3.1 Costo lineare nel numero di record (`exp/swiftrt/gen-conf.py`, `count.c`)
Banco: 2000 struct distinte non `Equatable` e 2000 istanze generiche `G<E_i>`, ognuna con `x is any Equatable` la prima
volta (ricerca fallita a freddo).

| Processo | Immagini | Record di conformità | Mediana per ricerca fallita | ns per record |
|---|---|---|---|---|
| solo Foundation | 383 | 28 324 | 0,61–0,64 ms | ~22 |
| con SwiftUI caricato | 524 | 72 838 | 1,29–1,44 ms | ~20 |
| app TeraScale Metal dopo 15 s | 1086 | 180 192 | 2–4 ms (media; 87 ms il caso peggiore) | – |
| seconda ricerca dello stesso tipo | – | – | 0,001 ms (cache del runtime) | – |

- Le istanze generiche non si aiutano tra loro: `G<E_1>`, `G<E_2>`… pagano ciascuna la scansione intera, anche con
  `SWIFT_DEBUG_ENABLE_CACHE_PROTOCOL_CONFORMANCES_BY_TYPE_DESCRIPTOR` (attivo di default: per i "no" non cambia nulla).
- `sample` sul banco: il tempo è nella lambda per descrittore di `swift_conformsToProtocolMaybeInstantiateSuperclasses`
  (confronto del protocollo, poi `getMatchingType`/`equalContexts` per i record dello stesso protocollo).
- Chi gonfia i record: SwiftUI 10 199, SwiftUICore 8977, poi **IntelligencePlatformLibrary 6392, PromptKit 2276,
  ModelCatalog 2113, TokenGeneration 1882, ModelManagerServices 1546**: framework di Apple Intelligence caricati di
  riflesso, inutili su questa macchina, ~15 000 record su 69 000.

### 3.2 Le tabelle di dyld (`dyldconf.c`, `preopt.c`, `roots.c`, `launchmode.c`)
| Domanda | Risposta |
|---|---|
| La shared cache ha le tabelle Swift? | sì: `_dyld_swift_optimizations_version()` = 1 |
| `_dyld_find_protocol_conformance(Equatable, Int)` | trovata (tipo 0) |
| `_dyld_find_protocol_conformance(Equatable, Mirror)` | "non trovata" (2), **mai "fallimento definitivo"** (3) |
| `_dyld_has_preoptimized_swift_protocol_conformances` | **falso per tutte le 125 immagini** con record |
| `dyld_shared_cache_some_image_overridden()` | **vero**: 22 immagini `/System` caricate dal disco (le root di OCLP) |
| `_dyld_launch_mode()` di un binario di terze parti | 0x20: nessuna closure precalcolata |

Il disassemblato di `dyld4::APIs::_dyld_has_preoptimized_swift_protocol_conformances` mostra la condizione: l'immagine
ha Swift **e** il processo ha un `PrebuiltLoaderSet` con `hasOptimizedSwift()` **e** l'immagine è fra i suoi loader.
Il runtime salta nella scansione solo le sezioni delle immagini pre-ottimizzate. Senza closure precalcolata (qui:
tutti i processi provati) scandisce tutto.

**H1 (da verificare)**: le app di sistema, System Settings incluso, hanno la loro closure nella shared cache. dyld la
scarta quando un'immagine della cache è sostituita sul disco, e OCLP ne sostituisce 22. Se H1 è vera, su un Mac di serie
System Settings scandirebbe solo i record fuori cache (~4000: 0,08 ms per ricerca invece di 1,4–4 ms). La prova si fa
in un minuto dall'interno del processo (fase 0): `_dyld_launch_mode()` e `_dyld_has_preoptimized_…(SwiftUI)`.
Se H1 è falsa, il progetto vale lo stesso: le app di terze parti (inclusa la nostra) non hanno closure nemmeno su un
Mac di serie, e su questa CPU il costo per record è alto in ogni caso.

### 3.3 Cosa fa una vera app SwiftUI (`exp/swiftrt/cfspy.c`, app TeraScale Metal, primi 15 s)
Interposer di `swift_conformsToProtocol{,2}` (le chiamate di AttributeGraph e SwiftUI passano di lì).

| Misura | Valore |
|---|---|
| Ricerche (di primo livello) | 5300–6300 |
| Tempo totale nelle ricerche (somma su tutti i thread) | 7,9–8,6 s (5,7 s con la cache dei file già calda) |
| di cui fallite | ~4100, **99% del tempo** |
| Protocollo | `Equatable` 1833 fallite, 7,45 s; `DynamicProperty` 368, 0,67 s; il resto <0,2 s |
| Fallite per tipo | struct 5,2–5,6 s, enum 1,3–1,5 s, classi ~1 s, altro ~0,4 s |
| Coppie (tipo, protocollo) distinte fra le fallite | 1500–1900; (descrittore, protocollo) 1080–1200 |
| Fallite **senza alcun record candidato** (struct/enum) | 1120 su 1533, **5,0 s su 6,5 s** |
| Indice di tutti i record (180 000) | 39 ms una volta |
| Dopo 10 s | si stabilizza: l'app ha finito di costruire le viste |

Il caso tipico di AttributeGraph: per ogni campo di ogni tipo di vista chiede se è `Equatable`, e quasi nessun tipo
privato di SwiftUI lo è. Ogni "no" costa una scansione intera.

## 4. Leve valutate

| Leva | Prova | Verdetto |
|---|---|---|
| Variabili `SWIFT_DEBUG_*` del runtime | elenco completo con `SWIFT_DEBUG_HELP=YES` | nessuna accorcia i "no"; e le app di sistema ignorano l'ambiente |
| Sezione ufficiale `__swift63_hooks` | `getOverrideSectionPtr` = `getsectiondata(_NSGetMachExecuteHeader(), "__DATA", "__swift63_hooks")`, minimo 0x198 byte | solo nell'eseguibile principale: va bene per le **nostre** app, non per quelle Apple |
| `DYLD_INSERT_LIBRARIES` | – | ignorata per i binari di piattaforma e per l'hardened runtime; solo per i test |
| Patch del codice di libswiftCore in memoria | – | le pagine della shared cache sono firmate: una pagina modificata invalida la firma (rischio di kill). Scartata |
| Patch da kernel con il UserPatcher di Lilu | – | sostituisce byte, non porta codice nuovo nel processo. Scartata |
| **Override tramite la variabile di cache dell'override** | `swift_conformsToProtocol`, `…2`, `…Common`: `movq X(%rip), %rax; cmpq $1, %rax` → se ≠ 1 e ≠ 0 `jmpq *%rax` con l'originale in `%rdx` | **scelta**: solo dati, nel formato che il runtime stesso prevede, e chi lo installa si può verificare e annullare |
| Togliere le root di OCLP | – | impossibile: servono a far funzionare la grafica |
| Cache persistente delle conformità su disco (idea di AIR §6.4) | – | superata dall'indice in processo: niente invalidazione e niente file. Resta utile per l'indice stesso (§10, fase 3) |
| Non caricare i framework di Apple Intelligence | – | non controllabile dall'esterno |

## 5. Il prototipo (`exp/swiftrt/tsswift.c`)
- **Aggancio**: decodifica l'istruzione `movq X(%rip)` in testa ai tre ingressi esportati, verifica il `cmpq $1` che
  segue e scrive con compare-and-swap il proprio puntatore se il valore è 0 o 1. Se il valore è un altro puntatore (un
  override altrui) o lo schema non corrisponde, non fa nulla. La firma dell'override è
  `(tipo, protocollo, originale)`, quella del runtime.
- **Indice**: per ogni protocollo chiesto (pigramente, alla prima richiesta), un insieme dei descrittori di tipo nominati
  dai suoi record (tipi 0 e 1 di riferimento; i nomi di classi ObjC servono solo per le classi). Le immagini aggiunte
  dopo si indicizzano nel callback di `_dyld_register_func_for_add_image`. 62 protocolli, 754 KB, 90–300 ms in tutto.
- **Risposta rapida** solo se: il tipo è struct, enum o optional; il descrittore non è importato da C (né
  "import info", né inizializzazione foreign, né modulo `__C*`, dove l'identità va per nome); il protocollo non ha
  record "conformance of protocol" (flag 1<<18); dyld non sta aggiungendo un'immagine in quel momento (conteggio delle
  immagini indicizzate = `_dyld_image_count()`). Altrimenti va all'originale.
- **Validazione** (`TSSWIFT_VALIDATE=1`): per ogni "no" rapido chiede anche al runtime. **0 differenze** in 2609 casi
  (due esecuzioni).

### Risultati sull'app TeraScale Metal (lancio a freddo, CPU del processo a 15 s)
| Prova | Senza | Con il prototipo |
|---|---|---|
| 1 | 12,22 s | 7,66 s |
| 2 | 11,31 s | 7,31 s |
| 3 | 10,71 s | 7,33 s |
| **media** | **11,41 s** | **7,43 s (−35%)** |

Con il prototipo: ~1370 "no" rapidi in 8–30 ms in tutto (prima ~5 s). Restano al runtime ~7000 ricerche, 2,2–3,1 s:
| Ricerche lasciate al runtime | Numero | Tempo |
|---|---|---|
| struct/enum trovate | 2858 | 160 ms |
| **struct/enum fallite con un candidato** (conformità condizionali: `ModifiedContent: Equatable where …`) | 565 | **1561 ms** |
| classi trovate / **fallite** | 1250 / 1571 | 3 / **948 ms** |
| altro (tuple, funzioni, esistenziali) trovate / **fallite** | 330 / 548 | 1 / **466 ms** |

## 6. Copertura nei processi della pagina Sfondi
Dal log della policy (`com.terascale.mtlshim:policy`): il bundle si carica in System Settings (`on`, `list`) e, con lo
shim spento (`outside`), in `Wallpaper`, `WallpaperAerialsExtension` e `NeptuneOneWallpaper`. Quindi il codice del
bundle gira già in tutti i processi del problema. Non c'è in `WallpaperAgent`, perché il kext ne rifiuta la deroga:
va bene così.

| Processo | Primo log del processo | Caricamento del bundle | Ritardo |
|---|---|---|---|
| System Settings (17:28) | 36,425 s | 43,512 s | **~7,1 s** |
| Wallpaper.appex | 40,362 s | 41,851 s | ~1,5 s |

Il bundle si carica quando il processo enumera i device Metal. In System Settings succede tardi: le ricerche dei primi
7 s non sarebbero accelerate. Effetto atteso sulla pagina Sfondi, **stimato e da misurare in fase 1**: in
`Wallpaper.appex` (8,9 s di CPU, quasi tutta Swift) da −35% (fase 1) a −60% o più (fase 2). In System Settings
conta solo la parte dopo il caricamento del bundle. Le visite successive ad altre pagine di Impostazioni e le app
SwiftUI aperte dopo ne beneficiano per intero.

## 7. Rischi e mitigazioni
| Rischio | Mitigazione |
|---|---|
| Un "no" sbagliato cambia la semantica (`as?`, `is`), non solo le prestazioni | condizioni conservative (§5); validazione con confronto al runtime in un corpus di test e su app vere prima di ogni attivazione; chiave per app |
| Cambio del runtime con un aggiornamento di macOS | schema dei byte verificato al caricamento; se non corrisponde, nessun aggancio e una riga di log. Nessuna scrittura alla cieca |
| Corsa fra `dlopen` su un altro thread e una ricerca | contatore delle immagini indicizzate contro `_dyld_image_count()`: fast path spento finché non coincidono (nel prototipo) |
| Tipi con identità per nome (importati da C, sintetizzati) | esclusi dal fast path |
| "Conformance of protocol" (flag nuovo di Swift 6.x) | protocollo marcato non sicuro: tutto al runtime |
| Memoria (4 GB) | ~0,75 MB per processo; con offset a 32 bit ~0,4 MB |
| Un bug tocca anche le app in cui lo shim Metal è spento | chiave `System.Swift` separata, kill switch su file, default spento fino a fine fase 2 |
| Un override altrui (strumenti di Apple, compatibilità) | se la variabile non vale 0 o 1 non si tocca |

## 8. Cosa non fa
Non tocca il volume di sistema, i file di Apple o la shared cache. Non persiste nulla. Non cambia la decodifica video.
Non accelera le ricerche fatte prima del caricamento del bundle.

## 9. Sotto TeraScale o un progetto nuovo?

| Criterio | Modulo di TeraScale | Progetto separato |
|---|---|---|
| Entrare nei processi Apple (System Settings, estensioni) | **già risolto**: bundle caricato da Metal, deroga LV del kext limitata al suo eseguibile | serve un veicolo nuovo: un'altra deroga nel kext (quindi comunque `TSMetalEnabler`) **e** un innesco di caricamento che oggi non esiste; l'alternativa è una root patch del volume di sistema, contraria al principio del progetto |
| Infrastruttura | policy per app, kill switch, log `os_log`, statistiche, `tsmtl`, app (sezione "Sistema"), `update.sh`, test di sistema | da rifare |
| Precedenti | Compute nel core (0.6.0, invece di un bundle a parte) e Glass: costruttore che legge la propria chiave (`TSGlassInit`) | – |
| Copertura | processi che enumerano Metal: quasi tutte le app GUI; System Settings da ~7 s | più ampia solo con un innesco precoce, che non c'è |
| Isolamento dei rischi | da costruire: chiave, kill switch e log separati | naturale |
| Identità | TeraScale è "far vivere questo iMac con macOS 26": la causa è la stessa piattaforma (root di OCLP, CPU del 2011) | più netta sulla carta |

**Raccomandazione: modulo "TeraScale Swift" dentro TeraScale**, nel core del bundle, come Compute:
- sorgente in `src/swift/` (C puro, senza dipendenze da GL/CL), costruttore `TSSwiftInit` come `TSGlassInit`;
- policy `System.Swift` (`Enabled`, lista per app), kill switch su file, categoria di log `swift`, contatori in
  `tsmtl stats`;
- voce "TeraScale Swift" nella sezione "Sistema" dell'app, sotto Glass e Compute; `tsmtl swift on|off|stats`;
- codice separabile: se un giorno ci sarà un veicolo di caricamento più precoce, il modulo si sposta senza riscriverlo.

Alla nostra app (TeraScale Metal.app, SwiftUI) conviene comunque collegare il modulo direttamente, o usare la sezione
ufficiale `__swift63_hooks` nel suo eseguibile: risparmia ~4 s di CPU a ogni avvio, senza dipendere dal bundle.

## 10. Piano
Stato al 2026-11-02 sera: fasi 0, 1, 2 e 4 fatte (§11). Driver 0.12.1 e app 1.3.2 installati; driver 0.12.2 (acceso
per impostazione predefinita, §11.8) pronto in build/; H1 decisa e A/B su
Sfondi fatto (§11.6); TeraScale Swift acceso per tutti i processi (`System.Swift.Enabled`, senza validazione). La fase 3
non serve (indici in ~40 ms, §11.4).

| Fase | Contenuto | Si chiude quando | Installazione |
|---|---|---|---|
| **0 – Verifica** | build diagnostica del bundle: nel costruttore, log di `_dyld_launch_mode()`, `_dyld_has_preoptimized_…(SwiftUI)`, secondi dall'avvio del processo (`kinfo_proc`), immagini caricate, schema dell'aggancio riconosciuto sì/no (senza agganciare) | H1 decisa; ritardi di caricamento misurati in System Settings, Wallpaper e 3–4 app SwiftUI | `update.sh` (sudo, dall'utente) |
| **1 – Fast path struct/enum** | `src/swift/` dal prototipo (offset a 32 bit, indice in un solo passaggio su tutti i protocolli), policy, kill switch, log, statistiche; `tests/swift/`: corpus di validazione (generici, condizionali, tipi C, conformità retroattive in dylib caricate dopo, `dlopen` concorrente) con `TSSWIFT_VALIDATE` | 0 differenze sul corpus e su app vere; A/B su Sfondi con `exp/airopt/wallpaper-measure.sh`; nessun crash dopo una settimana con chiave per app | come fase 0 |
| **2 – Condizionali e classi** | requisiti condizionali semplici (protocollo su un parametro generico, valutato ricorsivamente con il fast path); classi (catena delle superclassi + record per nome ObjC); tipi non nominali | −60% o più di tempo nelle ricerche sull'app di prova, 0 differenze | come sopra |
| **3 – Facoltativa** | indice persistente per UUID della shared cache (mmap, condiviso fra processi); studio di un innesco più precoce senza toccare il volume di sistema | solo se la fase 1 mostra che l'indice costa troppo o arriva troppo tardi | – |
| **4 – Prodotto** | voce nell'app, `tsmtl swift`, default acceso dopo due settimane senza differenze | decisione dell'utente | `update.sh` |

## 11. Implementazione (driver 0.12.0, app 1.3.0)

### 11.1 Dove sta
| Parte | File |
|---|---|
| Acceleratore (C puro, condiviso da bundle, libTSMetal, app e test) | `src/swift/TSSwiftAccel.{h,c}` |
| Avvio nel bundle: policy, interruttore, log, statistiche | `src/TSSwift.m` (costruttore `TSSwiftInit`); `TSMtlSwiftEnabled` in `src/TSMtlSystem.m` |
| Avvio nell'app di controllo (prima delle viste SwiftUI) | `gui/Sources/SwiftAccelView.swift` (`SwiftControl.startInThisApp`), C collegato da `gui/build.sh` |
| Comando e sezione | `tsmtl swift …` (`gui/Sources/CLI.swift`), "TeraScale Swift" nella sezione "Sistema" |
| Contratto (policy, log, interruttore) | `docs/FASE4-INTERFACCE.md` |
| Test | `make test-swift`: `tests/swift/run.sh` (corpus) e `tests/swift/bundle.sh` (policy); `tests/swift/appcpu.sh` (A/B) |

### 11.2 Quando risponde "no" da solo
Sempre e solo se tutte le immagini caricate sono indicizzate (conteggio = `_dyld_image_count()`) e il protocollo non ha
record "conformance of protocol" o di tipo sconosciuto:
| Caso | Condizione | Nuovo rispetto al prototipo |
|---|---|---|
| struct/enum/Optional (`nominal`) | nessun record del protocollo nomina il descrittore; descrittore non importato da C né del modulo `__C*` | – |
| conformità condizionali (`conditional`) | ognuno dei record candidati (al massimo 8) ha un requisito `T: Q` su un parametro generico di profondità 0 (`x`, `q_`, `q<n>_`) che fallisce, chiesto di nuovo a `swift_conformsToProtocolCommon` (quindi anche all'acceleratore), al massimo 4 livelli; descrittore con soli parametri di tipo "chiave" (niente pack né valori) | sì: `ModifiedContent<…>: Equatable where …`, `Array`, `Optional`, `Dictionary` |
| classi (`class`) | lungo tutta la catena delle superclassi (anche le classi ObjC, fino alla radice) nessun record nomina il descrittore, l'oggetto classe ObjC (record di tipo 3) o il nome ObjC (tipo 2, confronto con `class_getName` fuori dal lock); una classe Swift con superclasse nulla (metadati incompleti) va al runtime | sì |
| tuple, funzioni, metatipi (`structural`) | nessun record può nominarli e questo runtime non ha conformità builtin per loro (verificato: `(1, 2) is any Equatable` è falso); al runtime se un record del protocollo nomina un tipo del modulo `Builtin` (le future "tuple conformances") | sì |

Tutto il resto (positivi, esistenziali, classi foreign/CF, tipi importati da C, requisiti same-type o su tipi associati,
parametri di tipi annidati in tipi generici) va al runtime com'è. Con `System.Swift.Validate` ogni "no" rapido viene
richiesto anche al runtime, la cui risposta vince; le differenze vanno nel log (`mismatches`, `last-mismatch`).

### 11.3 Correttezza
| Prova | Risultato |
|---|---|
| Corpus (`tests/swift/corpus.swift`, 193 righe, 3 ingressi + cast dinamici): generici condizionali a 1/2/3 parametri, annidati, same-type, tipi associati, requisiti multipli, Optional/Array/Dictionary/Result, tipi C (`timespec`, `CGPoint`, `NSRange`, enum e option set importati), classi Swift/ObjC, sottoclassi di `NSObject` e di `DateFormatter` con conformità in estensione, classi generiche, `@objc(nome)`, attori, tuple, funzioni, metatipi, esistenziali; conformità retroattive in una dylib caricata dopo (`dlopen`); 8 thread in concorrenza | output identico tra runtime, validazione e acceleratore; 8637 "no" rapidi, 0 differenze |
| App TeraScale Metal, validazione, 15 s | 4843 "no" rapidi (1758 nominal, 1057 conditional, 2028 class), **0 differenze** |
| App, 5 avvii con l'acceleratore (iniettato o collegato) | 0 differenze, ~5050 risposte rapide per avvio |
| Policy nel bundle (`tests/swift/bundle.sh`) | 8 casi: senza policy, predefinito, globale, validazione, voce per app on/off, interruttore, ambiente |
| Suite del driver (`make test`, `make test-compute`) | invariata, tutto verde |

### 11.4 Prestazioni (app TeraScale Metal, avvio a freddo, CPU del processo a 15 s)
| Prova | Spento | Acceso |
|---|---|---|
| app compilata, acceleratore collegato (3+3 avvii) | 10,16 / 8,54 / 8,22 s (media **8,97**) | 3,61 / 3,88 / 3,84 s (media **3,78**, **−58%**) |
| app installata, `build/libTSSwift.dylib` iniettata (3+3) | ~8 s | ~4 s (−50%) |
| prototipo (§5, per confronto) | 11,41 s | 7,43 s (−35%) |

| Contatori a 15 s (acceso) | Valore |
|---|---|
| risposte rapide | ~5050: nominal ~1800, conditional ~1080, class ~2050, structural ~120 |
| ricerche fallite lasciate al runtime | 98 (112–186 ms; erano 2684 e 2,9 s col prototipo) |
| indici | 84 protocolli in ~41 ms (113 ms prima delle impronte, 1,4 MB) |

Indici: la prima scansione lascia un'impronta di 1 byte del protocollo per ogni record (180 KB per 180 000 record); i
protocolli successivi leggono solo l'array contiguo e visitano i record con l'impronta giusta (~1 su 256). Per questo
la fase 3 (indice persistente) non serve.

### 11.5 Accensione e prova
Fatto il 2026-11-02 (§11.6). Passi, per rifarlo (l'installazione del driver richiede sudo, la fa l'utente):
1. `zsh ~/metal-shim/system/update.sh` (driver 0.12.0) e `zsh ~/metal-shim/system/install.sh --app` (app 1.3.0).
2. Prova mirata con validazione: `tsmtl swift validate on`, poi `tsmtl swift enable` per `com.apple.systempreferences`,
   `proc:Wallpaper`, `proc:WallpaperAerialsExtension`, `proc:NeptuneOneWallpaper` (id presi dal log della policy),
   oppure `tsmtl swift on` per tutti.
3. Misura su Sfondi con `exp/airopt/wallpaper-measure.sh` (A/B), verifica di H1 con le righe `launchMode=`/`preoptimized=`
   (`tsmtl swift stats`), differenze sempre 0.
4. Dopo due settimane senza differenze: validazione spenta e, a decisione dell'utente, accensione predefinita.
In caso di problemi: `tsmtl swift kill` (senza sudo, vale per i processi avviati da ora) o `tsmtl swift off`.

### 11.6 Sul driver installato: H1 e la pagina Sfondi (2026-11-02, 20:30–20:42)
**H1 (fase 0), dalle righe `swift` del log.** System Settings, `Wallpaper` e `WallpaperAerialsExtension` partono tutti
con `launchMode=0x20` (bit 1, "closure precalcolata", assente), `preoptimized=0` per SwiftUICore e
`cacheOverridden=1`. Quindi su questo Mac anche le app Apple scandiscono tutti i record (158 000 in System Settings,
123 000 in Wallpaper): l'acceleratore serve proprio lì. Il legame causale con le root di OCLP resta un'ipotesi, perché
manca un Mac di serie con cui confrontare, ma qui il fatto rilevante è deciso. Arrivo del bundle: System Settings
4,7–6,3 s dopo l'avvio, Wallpaper 1,1–2,1 s, WallpaperAerialsExtension 0,9–1,8 s.

**A/B** (`tests/swift/wallpaper-ab.sh 25`: apertura a freddo di Impostazioni → Sfondi, 25 s, CPU di System Settings,
Wallpaper, WallpaperAerialsExtension, NeptuneOneWallpaper, DesktopSettings; spento/acceso alternati):
| Prova | Spento | Acceso |
|---|---|---|
| 1–2 | 30,6 s (prima apertura, cache dei file fredda) | 14,4 s |
| 3–4 | 22,7 s | 13,2 s |
| 5–6 | 22,6 s | 12,6 s |
| **media** | **25,3 s** | **13,4 s (−47%; −41% senza la prima prova)** |

| Contatori a 15 s (acceso) | System Settings | Wallpaper | WallpaperAerialsExtension |
|---|---|---|---|
| risposte rapide | ~4890 (nominal ~2550, conditional ~960, class ~1330) | ~6230 (class ~3220) | ~3200 (tutte nominal, 4–8 ms) |
| "no" lasciati al runtime | ~228 (0,55–0,92 s) | ~150 (0,41–0,65 s) | 0–6 |

**Validazione** (`Validate` acceso, un'apertura, contatori a 60 s): **0 differenze su 18 674 risposte rapide** (System
Settings 7009, Wallpaper 6503, WallpaperAerialsExtension 5162). La decodifica video degli Aerial non cambia (~1,4 s per
apertura). Rimasto: in System Settings le ricerche dei primi ~5 s, prima dell'arrivo del bundle, non sono accelerate.

**Validazione allargata** (`Validate` acceso, 10 pannelli di Impostazioni aperti in sequenza, poi Freeform, Games, Stocks e
altre app di Apple, una alla volta): **0 differenze su 50 962 risposte rapide in 13 processi** (System Settings 8340,
Wallpaper 8141, WallpaperAerialsExtension 6135, DesktopSettings 6107, Games 4428, DisplaysExt 3863, NotificationsSettings
3456, ControlCenterSettings 2766, Stocks 2438, Appearance 2300, PowerPreferences 2161, Freeform 827). Weather, Clock,
Calculator, Journal, Passwords, Tips, Shortcuts, Reminders e Home non hanno caricato il driver nei 17 s della prova.

### 11.7 Driver 0.12.1, app 1.3.1: catene condizionali profonde
I "no" ancora lasciati al runtime in Games (848 ms), Wallpaper (650–880 ms) e Stocks (518 ms) hanno portato a tracciare,
nell'app TeraScale Metal, il motivo di ogni rinvio. Su 100, 68 (88 ms) erano catene `ModifiedContent<ModifiedContent<…>>`
più profonde dei 4 livelli di ricorsione della 0.12.0: al livello 5 il "no" andava al runtime, con una scansione intera
per ogni tipo di quel livello. Il limite serviva solo contro una ricorsione infinita, impossibile (un tipo non può
contenere se stesso come argomento generico): ora è 32, una guardia per lo stack. Il corpus ha catene di 6–12 livelli.
| App TeraScale Metal, 15 s | 0.12.0 | 0.12.1 |
|---|---|---|
| "no" lasciati al runtime | ~100 (110–190 ms) | **30 (26 ms)**: esistenziali 9, enum/struct importati da C 18, classi con un candidato 4 |
| tempo nel percorso rapido | 380–680 ms (comprese le scansioni a cascata) | **23–36 ms** |
| CPU del processo (3+3 avvii, policy spenta/accesa) | 8,97 → 3,78 s (−58%) | 9,05 → 3,60 s (**−60%**) |
Ciò che resta è proprio del runtime per scelta (§11.2).

A/B su Sfondi con la 0.12.1 installata (stesso script, 3+3): **23,03 s → 13,70 s (−41%)**, come la 0.12.0 a cache calda;
ma in System Settings i "no" lasciati al runtime costano 34–42 ms invece di 0,55–0,92 s, e il percorso rapido 34–166 ms
invece di 2–3 s. Il resto della CPU della pagina non sono più ricerche di conformità.

### 11.8 Accensione predefinita (driver 0.12.2, app 1.3.2)
Decisione dell'utente del 2026-11-02, dopo 0 differenze su ~70 000 risposte validate: senza `System.Swift` (o senza
`Enabled`) TeraScale Swift è **acceso**, salvo i processi critici e le eccezioni, come Compute. `tsmtl swift off` lo
spegne per tutti, `tsmtl swift kill` subito e senza sudo. `tests/swift/bundle.sh` ha 9 casi (acceso senza policy, spento
con `Enabled` falso). Sul Mac dell'utente non cambia nulla, perché la policy ha già `Enabled = true`.

## Appendice: riprodurre le misure
Tutto in `exp/swiftrt/`; i binari non sono nel repository, si ricompilano con `clang -O1 <file>.c -o <nome>`.
- Banco a freddo: `python3 gen-conf.py 2000 && xcrun swiftc -O conf.swift -o conf_ns` (~5 minuti), poi
  `./conf_ns plain,gen,again`; con i record di SwiftUI:
  `DYLD_INSERT_LIBRARIES=/System/Library/Frameworks/SwiftUI.framework/SwiftUI ./conf_ns plain,gen`.
- Record per immagine: `./count /System/Library/Frameworks/SwiftUI.framework/SwiftUI …`.
- dyld: `./dyldconf`, `./preopt <framework>`, `./roots <framework>…`, `./launchmode`.
- Disassemblare un ingresso del runtime: `clang -O1 fdump.c -o fdump && ./dis.sh swift_conformsToProtocol 160`
  (`./xref __swift63_hooks` trova chi legge la sezione degli override).
- App vera: `clang -O2 -dynamiclib cfspy.c -o cfspy.dylib -Wl,-undefined,dynamic_lookup`, poi
  `CFSPY_SECS=5,10,15 DYLD_INSERT_LIBRARIES=$PWD/cfspy.dylib "/Applications/TeraScale Metal.app/Contents/MacOS/TeraScaleMetal"`.
  Funziona solo con eseguibili senza hardened runtime (la nostra app è firmata ad-hoc senza).
- Implementazione: `make test-swift`; A/B su un eseguibile non firmato con hardened runtime:
  `tests/swift/appcpu.sh 15 [eseguibile]` (inietta `build/libTSSwift.dylib`, `TSSWIFT_OFF=1` per il lato spento).
- Prototipo: `clang -O2 -dynamiclib tsswift.c -o tsswift.dylib`, poi con `TSSWIFT_STATS=15` e, per la validazione,
  `TSSWIFT_VALIDATE=1`. Non caricare `cfspy` e `tsswift` insieme: `dlsym` restituirebbe l'interposer e l'aggancio
  salterebbe.
