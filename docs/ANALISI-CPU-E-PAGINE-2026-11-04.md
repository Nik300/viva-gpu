# Analisi 2026-11-04 (pomeriggio): CPU del Helio G96 e pagine di CoreAnimation

Kernel 0140, driver finale del mattino (push window). Misure sul telefono, sola lettura salvo i binari di test
`viva-tests/cpubench`, `cpubench2`, `cr.sh`, `cr2.sh`.

## 1. La CPU (MT6781 = Helio G96: 6x Cortex-A55 + 2x Cortex-A76)

### Cosa vede iOS

`sysctl`: `hw.ncpu 8`, `hw.nperflevels 1` (un solo cluster "Standard"), `hw.cpufamily 0` (sconosciuta),
`hw.cpufrequency 2000000000` (valore fisso dell'ADT, non misurato). Feature ARMv8.2 corrette: LSE atomics, CRC32,
AES/SHA1/SHA256/PMULL, FP16, DotProd, RDM, LRCPC, DPB; niente PAC (la userland è quella di iPhone X/A11, arm64
puro). libdispatch sceglie già le varianti `$VARIANT$armv81`. Non manca nessuna estensione che il codice A11 usi.

### Frequenze reali (link `gpu clocks`, PLL di apmixedsys)

| PLL | ora | massimo (OPP del DT stock) |
|---|---|---|
| ARMPLL_LL (A55) | 1865 MHz (OPP13, 0.98 V) | 2000 MHz (1.03 V) |
| ARMPLL_BL (A76) | **1084 MHz (OPP4, 0.775 V)** | **2050 MHz (1.12 V)** |
| CCIPLL | **611 MHz** | 1400 MHz (CCI-table di dvfsp) |

Nessuno imposta le frequenze nel nostro port: restano quelle lasciate da LK. La CSRAM del DVFS ibrido
(`dvfsp@0x11bc00`, dove Linux scrive le tabelle per MCUPM) contiene dati casuali: nessuno l'ha inizializzata.

### Velocità misurata per core (`cpubench2`: blocchi di lavoro etichettati col core, da TPIDR_EL0)

| core | blocco ALU (8 catene indipendenti) | memcpy 4 MB |
|---|---|---|
| cpu 0-5 (A55 @1865) | 1080 us | 2.1-2.2 GB/s (da solo), 1.3 GB/s (4 thread) |
| cpu 6-7 (A76 @1084) | **1270 us (più lento degli A55)** | 2.5-2.6 GB/s |

Per clock l'A76 fa 1.46x l'A55 in questo test. A 2050 MHz farebbe il blocco in circa 670 us: **1.6x un A55 e 1.9x
quello di oggi** (sul codice UI reale, con rami e accessi a memoria, il vantaggio dell'A76 è di solito maggiore).

### Scheduler

Con 1-2 thread il lavoro gira solo su cpu 0-4: XNU sceglie il core libero col numero più basso, e un cluster unico
non preferisce gli A76 (`__ARM_AMP__` non è attivo). Quindi i thread della UI (render di CA in backboardd, app,
replay del driver) girano quasi sempre sugli A55, e gli A76 lavorano solo quando ci sono 6 o più thread pronti.
Attenzione: preferire gli A76 *oggi* peggiorerebbe le cose, perché a 1084 MHz sono più lenti.

### Altro che ruba CPU (misurato con `ps` durante gli scroll)

- `vmd` (VisualVoicemail): 10.5 s di CPU su 11 s, cioè un core intero, sempre.
- **Crash loop di `chronod` (widget) nel nostro stack**: il thread `com.viva.metal.gpu` va in trap in
  `bi_emit_alu.cold.1` (compilatore Bifrost di Mesa: un'operazione ALU non gestita in uno shader di RenderBox,
  da `vmg_cmd_set_render_pipeline` -> `panfrost_bind_fs_state`). chronod viene rilanciato e crasha di nuovo
  (13 report). `launchd` + `ReportCrash` costano circa 3-4.7 s di CPU ogni 11 s, e i widget non si disegnano.
- 294 report in CrashReporter (OTAUpdate 37, backboardd/assetsd/Siri TTS 25 ciascuno, Preferences 18; molti vecchi).
- L'orologio di sistema è ancora al 1969.

### "Funzioni Metal CPU" e acceleratori

Metal non ha funzioni CPU da implementare: il lavoro CPU del driver (encode, replay, traduzione con cache) è nostro
ed è già stato ottimizzato. Sugli iPhone l'hardware dedicato che manca qui è JPEG (AppleJPEGDriver), decodifica e
codifica video H.264/HEVC (AVD/AVE) e lo scaler/convertitore di IOSurfaceAccelerator. Senza, quel lavoro va in
software sulla CPU oppure fallisce. Pesa su foto, video e primo caricamento delle immagini, non sul frame rate
delle animazioni misurato qui. AMX non c'entra: l'A11 non ce l'ha, quindi la userland non lo usa.
`hw.cpufamily 0` probabilmente conta poco: si può far dichiarare la famiglia dell'A11 per compatibilità, a bassa priorità.

### Cosa servirebbe (in ordine)

1. **DVFS della CPU nel kernel**: A76 fino a 2050 MHz, A55 fino a 2000 MHz, CCI fino a 1400 MHz. Due strade:
   - (a) quella di Linux "ibrida": tabelle in CSRAM più il firmware MCUPM. Non sappiamo se LK carica MCUPM.
   - (b) quella diretta di `mt_cpufreq` legacy, consigliata: Vsram_proc e Vproc11/12 dell'MT6358 via pwrap (VivaPwrap
     esiste già), poi PCW/posdiv dell'ARMPLL e del CCIPLL. Ordine: in salita prima la tensione poi la frequenza, in
     discesa il contrario.
   - Rischi: una tensione sbagliata blocca il telefono e manca la protezione termica. Prima bisogna leggere i
     sensori termici e aggiungere un limite.
   - Primo passo prudente: comando di link per leggere tensioni e frequenze, poi un OPP fisso scelto a mano, poi un
     governor semplice. Tutto dietro boot-arg.
2. **Scheduler**: solo dopo il punto 1, preferire gli A76 quando sono liberi (patch piccola sulla scelta del core).
   L'AMP completo di Apple (cluster E/P, `cluster-type` nell'ADT, Edge scheduler) è un lavoro molto più grande.
3. Correggere l'assert Bifrost (crash loop di chronod) e spegnere vmd.

### Guadagno atteso

Il render di CA in backboardd costa 7.5-8.6 ms per frame, quasi sempre su un A55. Su un A76 a 2050 MHz scenderebbe a
circa 4.5-5.5 ms, e si accorcerebbe anche il replay/flush del driver. In Impostazioni la catena in serie passerebbe da
circa 36 a circa 30 ms (da circa 28 a circa 33 fps). Sulla home serve poco, perché è limitata dalla GPU (busy 76%).
Più evidente su avvio delle app, decodifica di immagini/video in software e layout.

## 2. Pagine di CoreAnimation (SwapWait)

Misure (`disp lat`, intervalli oltre 8 frame esclusi):

| scena | vsync -> SwapEnd (render CA) | SwapEnd -> GPU done | scelto -> a schermo | somma | SwapEnd ogni | GPU busy |
|---|---|---|---|---|---|---|
| Impostazioni, scroll | 8.6 ms | 17.1 ms | 9.0 ms | 34.7 ms | **35.8 ms** | 37% |
| Home, swipe | 7.5 ms | 30.5 ms | 8.5 ms | 46.5 ms | **28.0 ms** | 76% |

- **Impostazioni**: l'intervallo è uguale alla somma, quindi è tutto in serie. Il frame successivo parte solo quando
  il precedente è a schermo, e la GPU resta ferma per il 63% del tempo. SwapWait risponde "busy" circa 5 volte per frame.
- **Home**: l'intervallo è molto più corto della somma, quindi lì due frame si sovrappongono. Il limite è la GPU
  (busy 76%, circa 21 ms di GPU per frame); SwapWait "busy" circa 10 volte per frame.
- Quindi la frase del mattino ("CA tiene un solo frame in volo") vale per Impostazioni, non in generale. Il ring di CA
  permette due frame in volo almeno in alcuni casi.
- L'analisi statica di `can_update_` (ANALISI-SCANOUT-RE §1.2) dice che prima di riusare una pagina CA controlla con
  SwapWait tutte le pagine dalla testa a quella corrente. Il numero di pagine del ring (count a `this+0x360`) e chi
  lo decide non sono ancora stati letti.
- **Domanda aperta**: perché in Impostazioni la catena è in serie mentre sulla home no.
  - Ipotesi A: il ring cresce o cala in modo adattivo.
  - Ipotesi B: in Impostazioni il collo di bottiglia è il ciclo dell'app. Preferences fa il commit al tick successivo
    al frame mostrato, e la sua CPU è bassa (11%), quindi sarebbe un limite di latenza, non di calcolo.
- Per decidere servono:
  - il disassemblato di QuartzCore: quanti pagine, chi imposta il count, il gating dei commit dell'app. Il dyld cache
    va estratto dall'IPSW, ma servono circa 3 GB liberi sul Mac e ora ce ne sono 2.1;
  - un contatore nel kernel: superfici distinte per swap e quante pagine CA ha in uso quando SwapWait risponde busy;
  - uno spindump/kdebug di Preferences durante lo scroll.
- Leve possibili, dopo la verifica:
  - più pagine nel ring, se è configurabile;
  - ritirare prima la pagina vecchia: in scanout non si può, perché la OVL la legge fino allo switch;
  - accorciare ognuno dei tre tratti: CPU più veloce (sezione 1), GPU, e il tempo "scelto -> a schermo"
    (in media mezzo frame, normale per il double buffer).

## 3. Aggiornamento: disassemblato di QuartzCore (dyld cache 20H392 estratto)

Correzioni ad ANALISI-SCANOUT-RE §1.1-1.2:
- `+0x358` è la prossima pagina da disegnare, `+0x35c` l'ultima inviata. Il ring ha **3 pagine fisse** (ctor
  AppleDisplay @0x1883ad1e8: count 3, oppure 1 con CA_BENCHMARK). Nessuna impostazione lo cambia.
- `can_update_` @0x1882be944 controlla al massimo 2 slot, si ferma alla prima pagina occupata e **basta una pagina
  libera**. Quindi CA ammette 2 frame in volo: F(k+1) parte quando F(k-2) è ritirato, cioè quando F(k-1) è a schermo.
  Con esattamente una pagina libera imposta la modalità "triple buffered" (presentazione prevista un frame dopo).
- Se il controllo fallisce: polling di SwapWait fino a 1 ms (ogni 100 µs, `swap_wait_timeout`), poi la damage
  resta in sospeso e si riprova **alla vsync successiva**. Ogni mancato riuso costa una vsync intera.
- Nel kernel l'ordine è giusto: `vsyncFired` fa prima lo switch (`vblankTick`, che ritira la pagina vecchia) e solo
  dopo invia la notifica vsync a CA.
- Quindi la catena in serie di Impostazioni non viene dal ring di CA. Ipotesi principale: il **backing store
  dell'app**. Preferences ridisegna le celle in IOSurface (CABackingStore) e può riusarle solo quando
  `IOSurfaceIsInUse` torna 0, cioè dopo il frame GPU di backboardd che le legge; sulla home le icone non vengono
  ridisegnate.
- Verifiche:
  - il contatore dei fallimenti di `can_update` (display +0x258) prima e dopo uno scroll;
  - le use count (traps 0/1) per superficie, cioè per quanto tempo restano > 0 dopo il commit;
  - uno spindump di Preferences durante lo scroll.
