# Viva Manager

App per iOS 16 sul telefono (viva): gestisce il driver Metal, i boot-arg, SpringBoard e mostra le statistiche.

| Sezione | Cosa fa | Come |
|---|---|---|
| **MaliMetal** | flag del driver (`VMG_*`, `VGPU_*`, …) con descrizioni, modifica a mano, riavvio di backboardd | `VivaMTLDriver.bundle/vmg.env` scritto dall'helper (la prima volta tiene `vmg.env.orig`) |
| **Boot Args** | riga del prossimo avvio: catalogo per gruppi, argomenti liberi, modifica a mano, riavvio | `kern.viva_nextbootargs` (richiesta KA2); senza, `/private/var/root/viva-next-bootargs` |
| **SpringBoard** | 259 chiavi di 51 classi di default di SpringBoard (iOS 16.7), valori salvati, chiavi nuove, riavvio di SpringBoard | `CFPreferences` come utente mobile |
| **Stat** | CPU (per core, processi), RAM (composizione, paginazione, processi), GPU (frequenza, DVFS, job, errori, memoria, display, controlli), MaliMetal (per processo: command buffer, draw, latenze, tempo GPU, chiamate al kernel, cache) | Mach, `vmhelper procs`, `kern.viva_link` (richiesta KA1), pagine `/private/var/tmp/vmg-stats/<pid>` del driver |

Le due sysctl del kernel sono descritte in `../docs/RICHIESTE-KERNEL.md` (KA1, KA2): senza, l'app lo dice e usa i ripieghi.

`vmhelper` (setuid root nel bundle) fa solo operazioni fisse: scrivere `vmg.env`, riavviare SpringBoard o backboardd,
comandi `gpu`/`disp`/`bat` del link, boot-arg, riavvio, elenco processi. Accetta solo Viva Manager come processo padre.

Build: CI `app.yml` (artefatto `viva-manager`), oppure `app/build.sh` con Xcode; `app/build.sh check` controlla i
sorgenti con i soli Command Line Tools. Installazione: `app/install.sh [VivaManager.tar]` (link USB).
