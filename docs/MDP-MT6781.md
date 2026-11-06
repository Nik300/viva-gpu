# MDP MT6781 (Helio G96, "viva"): guida di programmazione a livello di registri

Data: 2026-11-05. Obiettivo: un "transfer" IOSurface fatto dal nostro kernel XNU bare-metal (niente Linux, niente
CMDQ/GCE come esecutore di comandi, niente SCP): leggere un'immagine dalla memoria fisica (MDP_RDMA0), scalarla se serve
(MDP_RSZ0), convertire il formato colore e scriverla in un altro buffer fisico (MDP_WROT0), con le porte del larb2 in
bypass M4U (indirizzi fisici), come fa già lo scanout.

Stato: **documento di riferimento, niente è ancora stato provato sul telefono.** Le parti marcate [I] o [G] vanno
verificate nell'ordine della sezione 8. Due cose in particolare non sono documentate in nessun sorgente pubblico per
MT6781: **i valori dei mux di instradamento di mdpsys** (sezione 5.3) e **i numeri di interrupt GIC dei motori**
(sezione 6). Per entrambe c'è una procedura di scoperta via peek/poke.

## 0. Legenda delle fonti

- **[S:xxx]** = letto nel sorgente indicato (sigle sotto). **[UP]** = Linux upstream. **[DT]** = `dtb/viva-live.dts`.
- **[I]** = dedotto con un ragionamento esplicito (analogia con un chip della stessa famiglia, coerenza fra più fonti).
  **Da verificare.**
- **[G]** = ipotesi debole, solo un punto di partenza per i test.

| sigla | file (Xiaomi `MiCode/Xiaomi_Kernel_OpenSource`, ramo `viva-r-oss`, salvo dove indicato) |
|---|---|
| MDP | `drivers/misc/mediatek/mdp/mt6781/mdp.c`, `mt6781/mdp_base.h`, `mt6781/mdp_engine.h` |
| MDPC | `drivers/misc/mediatek/mdp/mdp_common.c` (reset, dump RDMA/WROT) |
| CLK | `drivers/clk/mediatek/clk-mt6781.c` |
| PG | `drivers/clk/mediatek/clk-mt6781-pg.c` (MTCMOS) |
| SMI | `drivers/misc/mediatek/smi/smi_drv.c`, `smi_reg.h`, `smi/mt6781/smi_conf.h`, `smi/mt6781/smi_hw.h`; `drivers/memory/mtk-smi.c` |
| M4U | `drivers/misc/mediatek/include/mt-plat/mt6781/include/mach/pseudo_m4u.h`, `include/dt-bindings/memory/mt6781-larb-port.h` |
| GCE | `include/dt-bindings/gce/mt6781-gce.h`, `drivers/mailbox/mtk-cmdq-mailbox.c`, `drivers/misc/mediatek/mdp/cmdq_reg.h` |
| DRM | `drivers/gpu/drm/mediatek/mtk_drm_ddp.c`, `mtk_drm_ddp.h` (mutex del display MT6781) |
| CFG | `arch/arm64/configs/viva_defconfig` |
| UP | `torvalds/linux`: `drivers/media/platform/mediatek/mdp3/` (`mdp_reg_rdma.h`, `mdp_reg_rsz.h`, `mdp_reg_wrot.h`, `mtk-mdp3-comp.c`, `mtk-mdp3-cmdq.c`, `mtk-mdp3-regs.h`, `mdp_cfg_data.c`), `drivers/soc/mediatek/mtk-mutex.c`, `arch/arm64/boot/dts/mediatek/mt8186.dtsi` |
| CR | ChromiumOS kernel `chromeos-5.10`, `drivers/media/platform/mtk-mdp3/mdp_reg_wrot.h`, `mdp_reg_rdma.h` (offset in più rispetto a UP) |
| MML | Xiaomi ramo `daumier-s-oss` (MT6983), `drivers/gpu/drm/mediatek/mml/`: `mtk-mml-rdma.c`, `mtk-mml-wrot.c`, `mtk-mml-rsz.c`, `mtk-mml-color.h`, `mtk-mml-mutex.c`, `tile_mdp_func.c`, `DpTileScaler.c`, `mtk-mml-tdshp.c`, `mtk-mml-aal.c`, `mtk-mml-hdr.c`. È il successore di MDP con **gli stessi offset di registro** di RDMA/RSZ/WROT, e calcola tutti i valori nel kernel (il driver MDP di MT6781 invece li riceve dalla libreria chiusa `libdpframework`). Contiene i dati per MT6893. |
| RSZFW | `NothingOSS/android_kernel_5.15_nothing_mt6886`, `drivers/gpu/drm/mediatek/mml/mtk-mml-rsz-fw.c`: il "firmware" del resizer (passo, algoritmo, `CON_1`/`CON_2`) |
| 6893 | `OnePlusOSS/android_kernel_5.10_oneplus_mt6895`: `include/dt-bindings/mml/mml-mt6893.h`, `arch/arm64/boot/dts/mediatek/mt6893.dtsi` (mux di mdpsys e moduli del mutex), `include/dt-bindings/gce/mt6893-gce.h` |
| JPG | `gpu/docs/JPGENC-MT6781.md` (documento fratello: dominio DIS, SMI common, bit del bypass larb già verificati sui sorgenti) |
| FB | `fork/research/bt0154/xnu/iokit/Kernel/arm/SweetFramebuffer.cpp` |

I sorgenti scaricati sono in `scratchpad/re-mdp/` di questa sessione (non nel repo).

### Perché i registri vengono da più sorgenti

Il driver MDP di viva (`drivers/misc/mediatek/mdp`) non programma RDMA/RSZ/WROT: esegue liste di comandi GCE costruite
in userspace da `libdpframework` (chiusa). Dal kernel viva si ricavano solo indirizzi, clock, reset, dump e
porte M4U. I significati dei campi vengono da UP (MT8183/MT8195, valori calcolati dal firmware SCP, quindi solo offset
e maschere) e soprattutto da MML (MT6893/MT6983), dove MediaTek ha spostato nel kernel tutto il calcolo. Gli offset di
RDMA/RSZ/WROT coincidono in MT6781 (dump [S:MDP][S:MDPC]), UP e MML; i dump del kernel viva leggono esattamente
gli offset di MML (per esempio WROT `0x018`/`0x0D0` per il debug, RDMA `0x038` `COMP_CON`, `0x098`, `0x148`, `0x150`).
Quindi l'IP è la stessa famiglia [I, forte]. Dove un campo cambia fra le generazioni è segnalato.

## 1. Mappa hardware

| blocco | PA | clock (indice nel provider mdpsys = bit di `MDPSYS_CG_CON0`) | note |
|---|---|---|---|
| `mdpsys_config` | 0x1B000000 | APB_BUS 7, IMG_DL_ASYNC0/1 2/3, RELAY0/1 (CG1 bit 0/8) | gate dei clock, reset, mux di instradamento [DT][S:CLK] |
| `mdp_mutex` | 0x1B001000 | MUTEX0 = 11 | [DT] |
| `smi_larb2` | 0x1B002000 | "scp-dis" (power domain DIS) + "mdp-smi" = SMI0 bit 6 | `mediatek,larb-id = 2` [DT] |
| `mdp_rdma0` | 0x1B003000 | RDMA0 = 0 | anche "GCE"/"GCE_TIMER" (infracfg_ao) [DT] |
| (riservato) | 0x1B004000 | (RDMA1 = 4) | slot di RDMA1, senza nodo [DT][S:CLK] |
| `mdp_aal0` | 0x1B005000 | AAL0 = 15 | [DT][S:CLK] |
| (riservato) | 0x1B006000 | | [DT] |
| `mdp_hdr0` | 0x1B007000 | HDR0 = 10 | [DT] |
| `mdp_rsz0` | 0x1B008000 | RSZ0 = 9 | [DT] |
| `mdp_rsz1` | 0x1B009000 | RSZ1 = 13 | nodo DT con nome sbagliato `@1bf009000`, `reg` giusto [DT] |
| `mdp_wrot0` | 0x1B00A000 | WROT0 = 8 | [DT] |
| `mdp_wrot1` | 0x1B00B000 | WROT1 = 12 | [DT] |
| `mdp_tdshp0` | 0x1B00C000 | TDSHP0 = 1 | [DT] |
| `gce_mbox` | 0x1022C000 (16 KiB) | infracfg_ao | GIC SPI 0xAA e 0xAB [DT] |
| SPM | 0x10006000 | sempre acceso | [DT][S:PG] |
| `infracfg_ao` | 0x10001000 | sempre acceso | protezioni bus, gate GCE [S:PG][S:CLK] |
| `topckgen` | 0x10000000 | sempre acceso | mux `mdp_sel` [S:CLK] |
| `smi_common` | 0x14002000 | dominio DIS | condiviso col display [DT] |
| `dispsys_config` | 0x14000000 | dominio DIS | gate SMI in `MMSYS_CG_CON0` [S:CLK] |

Indirizzi dei motori confermati anche da `mdp_base[]` in [S:MDP mdp_base.h]. Porte M4U di larb2 [S:M4U larb-port.h]:

| porta larb2 | ID M4U | nome | registro `SMI_LARB_NON_SEC_CON(p)` |
|---|---|---|---|
| 0 | `MTK_M4U_ID(2,0)` | `M4U_PORT_L2_MDP_RDMA0` | 0x1B002380 |
| 1 | `MTK_M4U_ID(2,1)` | `M4U_PORT_L2_MDP_RDMA1` | 0x1B002384 |
| 2 | `MTK_M4U_ID(2,2)` | `M4U_PORT_L2_MDP_WROT0` | 0x1B002388 |
| 3 | `MTK_M4U_ID(2,3)` | `M4U_PORT_L2_MDP_WROT1` | 0x1B00238C |
| 4 | `MTK_M4U_ID(2,4)` | `M4U_PORT_L2_MDP_DISP_FAKE0` | 0x1B002390 |

Solo RDMA0, WROT0 e WROT1 accedono alla memoria (`mdp_engine_port[]` [S:MDP mdp_base.h]); RSZ, AAL, HDR, TDSHP sono
motori "in linea" senza DMA.

## 2. Accensione: power domain, clock, verifiche

### 2.1 Cosa fa Linux

- MDP **non ha un power domain proprio**: sta nel dominio **DIS**, lo stesso del display. Lista dei domini MT6781
  [S:PG `SYS_*`]: MD1, CONN, DIS, VEN, VDE, CAM, ISP, MFG0..3, ISP2, IPE, CAM_RAWA/B, CSI; il larb2 dichiara
  `clocks = <&scpsys 3 ...>` = "scp-dis" [DT] e `smi_subsys_to_larbs[SYS_DIS]` contiene il larb 2 [S:SMI smi_hw.h].
  **Con il display acceso, il dominio di MDP è già acceso** [I, forte].
- `cmdq_mdp_enable_common_clock(true)` [S:MDP]: `smi_bus_prepare_enable(SMI_LARB2)` (clock di larb2 = scp-dis +
  MDP CG bit 6), poi `MDP_APB_BUS` (bit 7), poi `MDP_MUTEX0` (bit 11).
- `cmdq_mdp_enable_clock(engine)` [S:MDP]: un gate per motore (tabella sezione 1); per RDMA0/WROT0/WROT1 chiama anche
  `m4u_config_port(Virtuality=1)` ("1 for IOVA, 0 for PA"), cioè mette la porta in modalità M4U. **Noi faremo il
  contrario (sezione 3).**
- Senza `CMDQ_PWR_AWARE`, `cmdqMdpClockOn` scrive `0xFFFFFFFF` in `MDPSYS_CG_CLR0` (0x108) e `CG_CLR1` (0x118) [S:MDP]:
  conferma che scrivere 1 nei registri CLR **accende** i clock.

### 2.2 Gate dei clock di mdpsys [S:CLK `mdp0_cg_regs`, `mdp1_cg_regs`, `mdp_clks`]

`MDPSYS_CG_CON0` = 0x1B000100 (stato), `SET0` = 0x1B000104 (spegne), `CLR0` = 0x1B000108 (accende). Logica normale:
**bit a 1 = clock spento**. Ops `mtk_clk_gate_ops_setclr`.

| bit | clock | serve per noi |
|---|---|---|
| 0 | mdp_rdma0 | sì |
| 1 | mdp_tdshp0 | solo se TDSHP0 sta nel percorso (5.3) |
| 2 / 3 | mdp_img_dl_async0 / 1 | no (camera direct link) |
| 4 / 5 | mdp_rdma1 / mdp_tdshp1 | no |
| 6 | mdp_smi0 (ops dummy: Linux non lo spegne mai) | sì |
| 7 | mdp_apb_bus | sì |
| 8 | mdp_wrot0 | sì |
| 9 | mdp_rsz0 | sì |
| 10 | mdp_hdr0 | solo se nel percorso |
| 11 | mdp_mutex0 | sì |
| 12 | mdp_wrot1 | no |
| 13 | mdp_rsz1 | opzionale (per disabilitarlo, 4.1) |
| 14 | mdp_fake_eng0 | no |
| 15 | mdp_aal0 | solo se nel percorso |
| 16 / 17 | mdp_aal1 / mdp_color0 | no |

Secondo banco: `CG_CON1` per il clock driver è a **0x1B000120** (SET 0x124, CLR 0x128), bit 0
`mdp_img_dl_rel0_as0`, bit 8 `mdp_img_dl_rel1_as1` [S:CLK]; il dump di [S:MDP] chiama invece `CG_CON1` il registro
0x110 e `CG_CON2` lo 0x120. Non ci servono.

Valori da scrivere in `CLR0`:

- minimo (RDMA0, SMI0, APB, WROT0, RSZ0, MUTEX0) = **0x00000BC1**
- con tutti i motori PQ (+TDSHP0, HDR0, RSZ1, AAL0) = **0x0000AFC3**

Attenzione: la numerazione dei bit di **reset** (sezione 2.6) è quasi uguale ma non identica: AAL0 è CG bit 15 e
reset bit 16 [S:CLK][S:MDP].

### 2.3 Mux `mdp_sel` (topckgen)

`MUX_CLR_SET_UPD(TOP_MUX_MDP, "mdp_sel", mdp_parents, CK_CFG_10, CK_CFG_10_SET, CK_CFG_10_CLR, 24, 4, INV_BIT, 0x008, 12)`
[S:CLK], con `CK_CFG_10` = 0xE0, SET 0xE4, CLR 0xE8:

| campo | valore |
|---|---|
| stato | `CK_CFG_10` = 0x100000E0 |
| selettore | bit [27:24] (4 bit) |
| gate | nessuno gestito da Linux (`INV_BIT`); il bit 31 è il "pdn" del mux nello stile MediaTek [I: il codice disattivato `#if 0` di `mtk_topckgen_init` scrive 0x80808000 in `CK_CFG_10_SET`, cioè i bit 7 di ogni byte] |
| aggiornamento | scrivere `1<<12` in 0x10000008 |
| **attenzione** | lo stesso registro contiene `disp_sel` (bit [19:16]) e `vdec_sel`: usare **solo** SET/CLR, mai una scrittura diretta in 0xE0 |

Genitori [S:CLK `mdp_parents`]: 0 clk26m, 1 mainpll_d5, 2 univpll_d5, 3 mainpll_d2_d2, 4 univpll_d2_d2,
5 mainpll_d3, 6 univpll_d3, 7 mainpll_d2, 8 mmpll_ck.

Il DT dichiara per mmdvfs `mdp_step0/1/2 = <0x230 ..>, <0x1c2 ..>, <0x138 ..>` = 560/450/312 MHz, e il passo 2 usa il
genitore `TOP_UNIVPLL_D2_D2` (indice 0x0a della lista `clock-names` del nodo mmdvfs) [DT]. **Scelta consigliata: 4 =
univpll_d2_d2 (312 MHz)** [I]. Con 0 (26 MHz) MDP funziona ma è lento [I].

```
peek 0x100000E0                 ; se [27:24] != 0 e bit 31 = 0 si può saltare
poke 0x100000E8 0x0F000000      ; CLR bit [27:24]
poke 0x100000E4 0x04000000      ; SET = 4 (univpll_d2_d2)
poke 0x10000008 0x00001000      ; update, bit 12
peek 0x100000E0                 ; atteso [27:24] = 4, [19:16] (disp_sel) invariato
```

Se il bit 31 fosse 1 [I]: `poke 0x100000E8 0x80000000`.

### 2.4 Power domain DIS (solo se fosse spento)

Con il display acceso **non serve**. Per completezza, `spm_mtcmos_ctrl_dis(STA_POWER_ON)` [S:PG]:

| nome | PA | bit |
|---|---|---|
| `POWERON_CONFIG_EN` | 0x10006000 | scrivere 0x0B160001 (chiave `0xB16<<16 \| 1`) prima |
| `PWR_STATUS` / `PWR_STATUS_2ND` | 0x1000616C / 0x10006170 | DIS = bit 21 |
| `DIS_PWR_CON` | 0x10006354 | 0 RST_B, 1 ISO, 2 ON, 3 ON_2ND, 4 CLK_DIS, 8 SRAM_PDN, 12 SRAM_PDN_ACK |
| `INFRA_TOPAXI_PROTECTEN` (+SET 0x2A0, CLR 0x2A4, STA1 0x228) | 0x10001220 | DIS step 2: bit 1, 2, 10, 11 |
| `INFRA_TOPAXI_PROTECTEN_1` (+SET 0x2A8, CLR 0x2AC, STA1_1 0x258) | 0x10001250 | DIS step 1: bit 11, 12 |

Accensione: key; `|= ON`; `|= ON_2ND`; attendere bit 21 in entrambi gli status; `&= ~CLK_DIS`; `&= ~ISO`;
`|= RST_B`; `&= ~SRAM_PDN` e attendere bit 12 = 0; `PROTECTEN_CLR = 0x00000C06`; `PROTECTEN_1_CLR = 0x00001800`;
infine `MM_CG_CLR` (0x14000108) = 0x01000000 [S:PG]. Atteso da acceso: `DIS_PWR_CON` = 0x0000000D [I].

### 2.5 Verifica che il blocco è alimentato e con clock, **prima** di toccare 0x1B00xxxx

Un accesso APB a un blocco spento o senza clock su MediaTek di solito blocca il bus (telefono appeso, niente
eccezione) [I, stessa nota in JPG]. Ordine sicuro, ogni passo legge solo cose già alimentate:

1. `peek 0x1000616C` e `peek 0x10006170`: **bit 21 = 1** in entrambi (dominio DIS) [S:PG].
2. `peek 0x10006354`: bit 0 = 1, bit 1 = 0, bit 4 = 0, bit 8 = 0, bit 12 = 0 (atteso 0x0000000D) [S:PG bit][I valore].
3. `peek 0x10001220` e `peek 0x10001250`: bit 1/2/10/11 della prima e 11/12 della seconda = 0 (bus non protetto) [S:PG].
4. `peek 0x100000E0`: `mdp_sel` [27:24] != 0, bit 31 = 0 (2.3) [I].
5. `peek 0x14000100` (`MMSYS_CG_CON0`): bit 11 (`mm_smi_infra`), 17 (`mm_smi_common`), 22 (`mm_smi_gals`),
   24 (`mm_smi_iommu`) = 0 [S:CLK, come in JPG]. Col display acceso lo sono.
6. **Ora si può leggere mdpsys_config**: `peek 0x1B000100` (CG_CON0). È il primo accesso a 0x1B000000: se il telefono
   si blocca qui, il problema è `mdp_sel` o il dominio [I]. Valore atteso dopo il boot senza Linux: probabilmente
   molti bit a 1 (clock spenti) [G].
7. `poke 0x1B000108 0x00000BC1` (o 0xAFC3), poi `peek 0x1B000100`: i bit scritti devono essere 0.
8. `peek 0x1B000700`: `MMSYS_SW0_RST_B` (reset attivo basso, 2.6), atteso tutti i bit dei motori a 1 [I].
9. Solo ora i motori: `peek 0x1B003408` (RDMA `MON_STA_1`), `peek 0x1B00A014` (WROT `SOFT_RST_STAT`),
   `peek 0x1B008000` (RSZ `ENABLE`), `peek 0x1B001020` (MUTEX0 `EN`).
10. Prova scrittura-lettura innocua: `poke 0x1B003F00 0x12345600`, `peek 0x1B003F00` (RDMA `SRC_BASE_0`, il motore è
    fermo).

Regola: **mai** leggere un motore il cui bit in `CG_CON0` è 1 [I].

### 2.6 Reset

Reset di sistema dei motori [S:MDP `cmdq_mdp_reset_with_mmsys`]: `MMSYS_SW0_RST_B` = 0x1B000700 e `SW1_RST_B` =
0x1B000704, **bit a 0 = in reset**. Si scrive il complemento dei bit da resettare e subito dopo `0xFFFFFFFF`
("takes effect immediately, no need to poll"). Bit: 0 RDMA0, 1 TDSHP0, 2/3 img_dl_async0/1, 4 RDMA1, 5 TDSHP1, 6 smi0,
7 apb_bus, 8 WROT0, 9 RSZ0, 10 HDR0, 11 mdp_mutex0, 12 WROT1, 13 RSZ1, 14 HDR1, 15 fake_eng0, 16 AAL0, 17 AAL1,
18 COLOR0, 19 COLOR1. Esempio, reset di RDMA0+RSZ0+WROT0: `poke 0x1B000700 0xFFFFFCFE` poi `poke 0x1B000700 0xFFFFFFFF`.

Reset per motore [S:MDP `cmdqMdpResetEng`/`cmdqMdpClockOff`, S:MDPC `cmdq_mdp_loop_reset`]:

| motore | sequenza |
|---|---|
| RDMA0 | `poke 0x1B003008 1`; attendere `(peek 0x1B003408 & 0x7FF00) == 0x100` (stato "idle"), timeout 10 ms; `poke 0x1B003008 0` |
| WROT0 | `poke 0x1B00A010 1`; attendere `0x1B00A014` bit 0 = 1; `poke 0x1B00A010 0`; attendere bit 0 = 0 |
| RSZ0 | `poke 0x1B008000 0`, `poke 0x1B008000 0x10000`, `poke 0x1B008000 0` (bit 16 = reset) |
| TDSHP0 | `poke 0x1B00C100 0`, `poke 0x1B00C100 2`, `poke 0x1B00C100 0` |
| MOUT | dopo il reset di RDMA0 Linux impulsa il bit 2 di `MMSYS_MOUT_RST` = 0x1B000F00 (vecchio&~4, vecchio\|4, vecchio&~4) |

## 3. Larb2 e M4U in bypass

### 3.1 Come fa già il display

Lo scanout legge indirizzi fisici attraverso larb0/larb1 senza programmare l'M4U: `SweetFramebuffer` legge solo
`LARB_NON_SEC_CON(p)` (0x380 + 4p) e avvisa se il bit 0 è 1 ("may go through the M4U") [S:FB]. Il bit 0 era marcato
"(inferred)" nel nostro codice; ora è confermato: `F_SMI_MMU_EN = bit 0` [S:M4U pseudo_m4u.h].

### 3.2 Bit di `SMI_LARB_NON_SEC_CON(p)` (0x380 + 4p)

[S:M4U pseudo_m4u.h][S:SMI]:

- bit 0 `F_SMI_MMU_EN`: 1 = indirizzo tradotto dall'M4U (IOVA), **0 = bypass, indirizzo fisico**;
- bit [15:8] `F_SMI_ADDR_BIT32`: bit alti dell'indirizzo (34 bit);
- bit 1 (`|0x2`, "cmd group", solo per le porte OVL di larb0/1) e bit 3 (`|0x8`, throttle di banda, applicato da Linux a
  tutte le porte 0..4 di larb2: `smi_larb_bw_thrt_en_port[2] = {0, SMI_LARB2_PORT_NUM}`) [S:SMI];
- bit [19:16] sysram, solo mt6885/6893 [S:SMI `smi_sysram_enable`].

Bypass come lo fa `pseudo_config_port(Virtuality=0)`: `valore = vecchio & ~0x0000FF01` [S:M4U, vedi JPG 3].
`SMI_LARB_SEC_CONx(p)` (0xF80 + 4p) è lato sicuro: non toccarlo [I].

### 3.3 Inizializzazione di larb2

Dopo il boot senza Linux, larb2 potrebbe non essere mai stato inizializzato (LK usa solo larb0/1) [I]. Linux, quando
accende il larb, scrive [S:SMI smi_conf.h]:

| registro | PA | valore | fonte |
|---|---|---|---|
| `SMI_LARB_CMD_THRT_CON` (0x24) | 0x1B002024 | 0x00370256 | `smi_larb0_conf_pair`, usato per i larb 0..14 |
| `SMI_LARB_SW_FLAG` (0x40) | 0x1B002040 | 0x1 | idem |
| `SMI_LARB_OSTDL_PORT(0..3)` (0x200+4p) | 0x1B002200..0x1B00220C | 0x6 | `smi_larb2_init_pair` |
| `SMI_LARB_OSTDL_PORT(4)` | 0x1B002210 | 0x1 | idem |

Controlli in più:

- `SMI_LARB_SLP_CON` (0x00C) = 0x1B00200C: bit 0 `SLP_PROT_EN` deve essere 0 (se 1 il larb blocca il traffico) [S:SMI
  mtk-smi.c, definizione del bit][I uso].
- `SMI_LARB_STAT` (0x000) = 0x1B002000: diverso da 0 = larb occupato (`smi_debug_bus_hang_detect`) [S:SMI].
- SMI common: `SMI_BUS_SEL` = 0x14002220 atteso 0x1414 [S:SMI smi_conf.h]; `SMI_COMMON_CLAMP_EN` = 0x140023C0
  dovrebbe avere a 0 il bit della porta di larb2 [I: il clamp si alza solo quando il dominio del larb si spegne].

Sequenza (le porte 0 e 2 sono RDMA0 e WROT0):

```
peek 0x1B002000 1               ; STAT, atteso 0
peek 0x1B00200C 1               ; SLP_CON, bit 0 = 0
peek 0x1B002380 5               ; NON_SEC_CON porte 0..4
poke 0x1B002024 0x00370256
poke 0x1B002040 0x00000001
poke 0x1B002200 0x6
poke 0x1B002204 0x6
poke 0x1B002208 0x6
poke 0x1B00220C 0x6
poke 0x1B002210 0x1
poke 0x1B002380 ((v0 & ~0xFF01) | 0x8)   ; RDMA0: bypass + throttle
poke 0x1B002388 ((v2 & ~0xFF01) | 0x8)   ; WROT0: bypass + throttle
peek 0x1B002380 5               ; bit 0 = 0 sulle porte 0 e 2
```

Vincoli del bypass [I]:

- i registri indirizzo di RDMA/WROT sono a 32 bit; i registri `*_MSB`/`*_HIGH` (RDMA 0xF30.., WROT 0xF34..) esistono
  in MML ma non sono nei dump MT6781 [S:MML][S:MDP]: **usare solo PA < 4 GiB** (bit [15:8] di `NON_SEC_CON` a 0);
- MDP **non è cache-coherent**: clean della D-cache sul sorgente prima dello start, invalidate sulla destinazione dopo
  la fine;
- niente regioni protette da EMI MPU / TEE.

## 4. Registri per motore

Offset relativi alla base del motore. Le maschere UP sono quelle con cui il driver upstream scrive il registro: dicono
quali bit esistono.

### 4.1 MDP_RDMA0 (0x1B003000)

| off | nome | uso | fonte |
|---|---|---|---|
| 0x000 | `RDMA_EN` | bit 0 = motore abilitato | UP, MML |
| 0x008 | `RDMA_RESET` | bit 0 = reset (2.6) | UP, MDP |
| 0x010 | `RDMA_INTERRUPT_ENABLE` | abilitazione interrupt | MML (offset); [I] presente su MT6781 |
| 0x018 | `RDMA_INTERRUPT_STATUS` | stato interrupt | MML; [I] |
| 0x020 | `RDMA_CON` | bit 4 `simple_mode` (=1), bit 5 output 10 bit, bit 12 `lb_2b_mode` (=1 se non formato a blocchi). UP maschera 0x1110 | MML, UP |
| 0x028 | `RDMA_GMCIF_CON` | bit 0 command div, [6:4] tipo richiesta (7 = burst 8), bit 16 pre-ultra. Valore 0x00010071, maschera 0x0003F0F1 | MML, UP |
| 0x030 | `RDMA_SRC_CON` | formato, vedi sotto. UP maschera 0x03C8FE0F, MML 0x038CFE0F | MML, UP |
| 0x038 | `RDMA_COMP_CON` | compressione (UFO/AFBC): **0** | MML, CR, MDPC |
| 0x060 | `RDMA_MF_BKGD_SIZE_IN_BYTE` | stride del piano Y / unico piano, in byte (21 bit) | MML, UP |
| 0x068 | `RDMA_MF_BKGD_SIZE_IN_PXL` | solo 10 bit/AFBC | UP |
| 0x070 | `RDMA_MF_SRC_SIZE` | `(h << 16) \| w` letti (13+13 bit) | MML, UP |
| 0x078 | `RDMA_MF_CLIP_SIZE` | `(h << 16) \| w` in uscita (crop) | MML, UP |
| 0x080 | `RDMA_MF_OFFSET_1` | `(y << 16) \| x` offset del crop dentro il tile (maschera 0x003F001F) | MML, UP |
| 0x090 | `RDMA_SF_BKGD_SIZE_IN_BYTE` | stride del piano UV in byte | MML, UP |
| 0x100/0x108/0x110 | `RDMA_SRC_END_0/1/2` | fine dei piani; MML non li scrive, UP sì (`iova_end`) | UP; [I] valore = base + dimensione - 1 |
| 0x118/0x120/0x128 | `RDMA_SRC_OFFSET_0/1/2` | offset in byte del tile dentro ogni piano | MML, UP |
| 0x200 | `RDMA_TRANSFORM_0` | conversione colore, vedi sotto | MML, UP |
| 0x400.. | `RDMA_MON_STA_0..28` (passo 8) | debug | MDPC |
| 0x408 | `RDMA_MON_STA_1` | bit [18:8] stato: 0x1 idle, 0x2 wait sof, 0x4 reg update, 0x80 data running, 0x100 wait done, 0x200 warm reset, 0x400 wait reset; bit 20 "grep" = chiedere a SMI | MDPC |
| 0x4D0 | `RDMA_MON_STA_26` | [11:0] contatore orizzontale, [27:16] verticale | MDPC |
| 0xF00/0xF08/0xF10 | `RDMA_SRC_BASE_0/1/2` | indirizzo fisico dei piani Y / UV (o U) / V | MDP (`rdma_get_reg_offset_src_addr` = 0xF00), UP |

`RDMA_SRC_CON` [S:MML `rdma_config_frame`]:

| bit | campo |
|---|---|
| [3:0] | `hw_fmt` = 5 bit bassi del codice colore MTK (tabella 4.5) |
| [10:9] | `filterMode`: 2 = interpolazione 420→422 (sorgente 420 e destinazione non 420); 3 = altrimenti |
| 11 | 10 bit "loose" |
| 12 | campo interlacciato |
| 14 | `swap` (ordine R/B o U/V, tabella 4.5) |
| 15 | formato a blocchi MTK |
| 18 | numero di bit (10 bit) |
| 23 | tile 10 bit |
| 25 | `alpharot` (passaggio ARGB senza conversione, conserva l'alpha) |

`RDMA_TRANSFORM_0` [S:MML]: bit 16 `color_tran` (1 = converti RGB→YUV), `matrix_sel` a partire dal bit 23:
0 = RGB→YUV full range BT.601 ("JPEG"), 2 = RGB→BT.601 video, 3 = RGB→BT.709 video; 15 per il 10 bit.
**Conflitto [I]**: la maschera UP (MT8183/MT8195) è 0x0F110000, che non contiene il bit 23 e suggerisce `matrix_sel`
a [27:24]. Con `matrix_sel` = 0 il problema non c'è: **per le prove usare 0 (JPEG/full range)**, cioè
`TRANSFORM_0 = 0x00010000` con conversione e 0 senza. Per BT.601 video provare prima `0x01010000` (2<<23) e, se i
colori sono sbagliati, `0x02010000` (2<<24).

Quando RDMA converte: Linux/MML accende `color_tran` per **tutte** le sorgenti RGB, perché la pipeline interna di MDP
(RSZ, TDSHP, ...) lavora in YUV; WROT riconverte in RGB [S:MML `rdma_color_fmt`, `wrot_color_fmt`]. Con il solo
copia-senza-scala (RSZ in relay) si può lasciare tutto spento: i tre canali passano invariati (è ciò che fa MML in
modalità `alpharot`, dove azzera sia `color_tran` sia `mat_en`) [S:MML][I senza alpharot].

RDMA0 e RSZ1 condividono una SRAM su MT8183 (`rdma_rsz1_sram_sharing`; `init_rdma` disabilita RSZ1, bit 0 di 0x000)
[S:UP]. Su MT6781 non si sa [I]: non usare RSZ1; se si vede corruzione, accenderne il clock e scrivere
`poke 0x1B009000 0`.

### 4.2 MDP_RSZ0 (0x1B008000)

| off | nome | uso | fonte |
|---|---|---|---|
| 0x000 | `RSZ_ENABLE` | bit 0 = abilitato (0 = **relay**, passa i dati senza toccarli); bit 16 = reset | UP, MML, MDP |
| 0x004 | `RSZ_CON_1` | controllo principale, vedi sotto. UP maschera 0x03FFFDF3 | RSZFW, UP |
| 0x008 | `RSZ_CON_2` | vedi sotto. UP maschera 0x0FFFC290 (+0x3800 per tile) | RSZFW, MML |
| 0x00C | `RSZ_INT_FLAG` | flag interrupt | MDP (dump) |
| 0x010 | `RSZ_INPUT_IMAGE` | `(h << 16) \| w` del tile in ingresso | MML, UP |
| 0x014 | `RSZ_OUTPUT_IMAGE` | `(h << 16) \| w` del tile in uscita | MML, UP |
| 0x018 | `RSZ_HOR_COEFF_STEP` | passo orizzontale (23 bit) | RSZFW, UP |
| 0x01C | `RSZ_VER_COEFF_STEP` | passo verticale (23 bit) | RSZFW, UP |
| 0x020/0x024 | `LUMA_HOR_INT/SUB_OFFSET` | offset iniziale orizzontale (intero / frazione) | MML, UP |
| 0x028/0x02C | `LUMA_VER_INT/SUB_OFFSET` | offset iniziale verticale | MML, UP |
| 0x030/0x034 | `CHROMA_HOR_INT/SUB_OFFSET` | offset croma orizzontale | MML, UP |
| 0x044/0x048 | `RSZ_DEBUG_SEL` / `RSZ_DEBUG` | scrivere 2 in 0x044 e leggere 0x048: bit 0 out valid, 1 out ready, 2 in valid, 3 in ready (0x5 = "downstream hang", 0xA = "upstream hang") | MDP dump |
| 0x04C | `RSZ_TAP_ADAPT` | adattamento dei tap (miglioria, facoltativa) | RSZFW, MDP |
| 0x22C | `RSZ_ETC_CONTROL` | miglioramento bordi: **0** (UP e MML lo scrivono a 0) | UP, MML |

`RSZ_CON_1` [S:RSZFW `rsz_fw`]:

| bit | campo |
|---|---|
| 0 | `hori_scale` (Linux lo mette sempre a 1) |
| 1 | `vert_scale` (sempre 1) |
| 4 | `vert_first`: 1 se la larghezza cresce (upscale) o resta uguale |
| [6:5] | `hori_algo`: 0 = 6 tap FIR, 1 = accumulo sorgente (n tap), 2 = cubico 6n tap |
| [8:7] | `vert_algo` |
| [12:10] | `hori_trunc_bit` (solo algo 2, rapporti molto piccoli) |
| [15:13] | `vert_trunc_bit` |
| [20:16] | `hori_tbl`: tabella coefficienti = 7 se algo 0 e passo = 32768 (1:1), 9 se algo 0 altrimenti, 17 se algo 1 o 2 |
| [25:21] | `vert_tbl` (stesse regole) |
| 26 | `use121filter`: 1 se la sorgente **non** è sottocampionata orizzontalmente (RGB, YUV444): conversione 444→422 interna con filtro [1 2 1] |
| 31 | `int_wclr_en` = 1 |

`RSZ_CON_2` [S:RSZFW][S:MML `rsz_config_tile`]: bit 7 `tap_adapt_en`, 9 power saving, [16:14]/[19:17]/20 troncamento
cubico orizzontale, [23:21]/[26:24]/27 verticale; per tile: bit 11 `drs_lclip_en` (1 se 121filter e il tile non parte da
x=0), bit 12 `drs_padding_dis` (1 se l'ultima colonna del tile in ingresso ha indice dispari, cioè larghezza pari),
bit 13 `urs_clip_en` (0 sull'ultimo tile a destra). Per un tile unico di larghezza pari: **`CON_2 = 0x00001000`**
(con `tap_adapt` spento, consigliato per le prove [I]).

Algoritmo e passo [S:RSZFW `rsz_fw`, `rsz_config`]. Con `in` = larghezza (o altezza) sorgente, `out` = destinazione:

- scelta: `out >= in` (ingrandimento o 1:1) → algo 0; `in > 24*out` → algo 1; altrimenti (riduzione fino a 1/24) → algo 2;
- **algo 0 (6 tap)**: precisione 2^15; `step = floor(32768 * (in - 1) / (out - 1))`;
  offset di centratura `sub = (32768*(in-1) - step*(out-1)) / 2` (in unità 1/32768, intero = 0);
- **algo 1/2 (accumulo)**: precisione 2^20; `step = floor(2^20 * (out - 1) / (in - 1))`, +1 se il prodotto inverso non
  torna esatto; offset `sub = ((in-1)*step - (out-1)*2^20) / 2`; vale `step <= 2^20` (questi algoritmi non ingrandiscono)
  [S:DpTileScaler.c `forward_cub_acc`: "SCALING_UP_ERROR"];
- 1:1 su un asse: algo 0, `step = 32768`, tabella 7, offset 0.

Per un tile unico che copre tutto il frame, gli offset `LUMA_*_INT` valgono 0 e i `LUMA_*_SUB` valgono il `sub`
calcolato sopra (piccolo, mezzo pixel di centratura; con 0 l'immagine è spostata di meno di un pixel) [S:RSZFW
`rsz_auto_align` + S:MML DpTileScaler.c `forward_6_taps`/`forward_cub_acc` con `inTileStart = 0`]. Croma: per algo 0
`CHROMA_INT = LUMA_INT >> 1`, `CHROMA_SUB = LUMA_SUB` (se `LUMA_INT` pari) [S:DpTileScaler.c]; per algo 1/2 uguali al
luma.

### 4.3 MDP_WROT0 (0x1B00A000)

| off | nome | uso | fonte |
|---|---|---|---|
| 0x000 | `VIDO_CTRL` | formato e geometria, vedi sotto; maschera 0xF131510F | MML, UP |
| 0x004 | `VIDO_DMA_PERF` | non toccare | MDPC dump |
| 0x008 | `VIDO_MAIN_BUF_SIZE` | `(blk_width << 16) \| (line_num << 8) \| (filt_v << 4)`; maschere 0x1FFF7F00 + 0x77 | MML, UP |
| 0x010 | `VIDO_SOFT_RST` | bit 0 = reset | UP, MDP |
| 0x014 | `VIDO_SOFT_RST_STAT` | bit 0 = reset in corso | UP, MDP |
| 0x018 | `VIDO_INT_EN` | bit [15:8] = selettore del registro di debug 0x0D0 (usato dai dump); bit 0 abilitazione interrupt [G] | MDPC, MML |
| 0x01C | `VIDO_INT` | stato interrupt, maschera 0x7 | CR, MML |
| 0x020 | `VIDO_CROP_OFST` | `(y << 16) \| x` | MML, UP |
| 0x024 | `VIDO_TAR_SIZE` | `(h << 16) \| w` scritti | MML, UP |
| 0x028 | `VIDO_FRAME_SIZE` | solo AFBC | MML, CR |
| 0x02C | `VIDO_OFST_ADDR` | offset in byte del tile nel piano Y (28 bit) | MML, UP |
| 0x030 | `VIDO_STRIDE` | stride Y in byte (16 bit) | MML, UP |
| 0x038 / 0x03C | `VIDO_OFST_ADDR_C` / `VIDO_STRIDE_C` | piano UV | MML, UP |
| 0x048 | `VIDO_CTRL_2` | bit [2:0] numero di bit (0 = 8 bit) | MML, UP |
| 0x054 | `VIDO_DITHER` | [31:24] = **alpha fisso** scritto nei formati ARGB: 0xFF000000 | MML, UP |
| 0x068 / 0x06C | `VIDO_OFST_ADDR_V` / `VIDO_STRIDE_V` | terzo piano | MML, UP |
| 0x070 | `VIDO_EOL_SEL` (`VIDO_RSV_1`) | impostare il bit 31 | MML, UP |
| 0x074 | `VIDO_DMA_PREULTRA` | soglie: ARGB `(96<<12)+16` = 0x00060010, 2/3 piani `(216<<12)+196` = 0x000D80C4, RGB24/565 `(136<<12)+76` = 0x0008804C, YUYV `(176<<12)+136` = 0x000B0088 | MML |
| 0x078 | `VIDO_IN_SIZE` | `(h << 16) \| w` ricevuti | MML, UP |
| 0x07C | `VIDO_ROT_EN` | bit 0 = motore abilitato | MML, UP |
| 0x080 | `VIDO_FIFO_TEST` | MML scrive 256; UP solo se il firmware dà != 0. **Lasciare il reset** [I] | MML, UP |
| 0x084 | `VIDO_MAT_CTRL` | `(mat_sel << 4) \| mat_en` | MML, UP |
| 0x0D0 | `VIDO_DEBUG` | dato di debug scelto con 0x018 | MDPC, MML |
| 0x0DC / 0x0E0 | `VIDO_SCAN_10BIT` / `VIDO_PENDING_ZERO` | 0 per 8 bit | MML, UP |
| 0xF00/0xF04/0xF08 | `VIDO_BASE_ADDR` / `_C` / `_V` | indirizzo fisico dei piani | MDP (`wrot_get_reg_offset_dst_addr` = 0xF00), UP |

`VIDO_CTRL` [S:MML `wrot_config_frame`]: [3:0] `hw_fmt`, bit 8 `swap`, bit 12 `crop_en` (=1), bit 14 pre-ultra (=1),
bit 16 `alpharot`, [21:20] rotazione (0, 1 = 90, 2 = 180, 3 = 270), bit 24 flip orizzontale, [29:28] `uv_xsel`,
[31:30] `uv_ysel`. Per uscita RGB `uv_xsel = uv_ysel = 2`; per uscita 420 senza rotazione `0, 0` e `filt_v = 3`
(se la sorgente non è già 420, altrimenti 0) [S:MML `uv_table`].

`VIDO_MAT_CTRL`, `mat_sel` [S:MML commento in `wrot_color_fmt`]: 0 RGB→JPEG, 2 RGB→BT601, 3 RGB→BT709,
**4 JPEG→RGB, 6 BT601→RGB, 7 BT709→RGB**, 8 JPEG→BT601, 9 JPEG→BT709, 10 BT601→JPEG, 11 BT709→JPEG, 12 BT709→BT601,
13 BT601→BT709. "JPEG" = BT.601 full range, "BT601/BT709" = video range. **Non esiste BT.709 full range**: MML usa la
matrice BT709 video [S:MML]; per i '420f' BT.709 i colori saranno leggermente sbagliati.

`VIDO_MAIN_BUF_SIZE` per un tile largo `W` (con `tile_width` = 512, valore MML/MT6893 [S:MML]; per MT6781 [I]),
[S:MML `wrot_calc_setting`, `wrot_check_buf`, `wrot_calc_hw_buf_setting`]:

1. `fifo_max = 512 * L`, `max_line = L`, con `L` = 32 per RGB e YUV422 a 1 piano, 64 per YUV420 e Y8, 48 per YUV422 a
   2/3 piani;
2. `c1 = floor(fifo_max / (2W)) * 2`; `c2 = ceil(W / c1)`; `t = ceil(W / (4 c2)) * 4`;
   `line = (t > W) ? ceil(W/4)*4 : t`, poi `line = min(line, max_line)`;
3. finché non entra: `ceil(W/line)*line * line <= ybuf` (ybuf = 512*32 per RGB, 512*64 per formato 12, 512*48 per 9/13)
   e la stessa prova per l'UV (`uvbuf` = 512*32, 256*32, 256*48), togliere 4 a `line`;
4. `MAIN_BUF_SIZE = (W << 16) | (line << 8) | (filt_v << 4)`.

Valori già calcolati: BGRA W=256 → 0x01002000; BGRA W=128 → 0x00802000; BGRA W=480 → 0x01E02000;
NV12 W=256 (sorgente RGB, `filt_v`=3) → 0x01004030.

Offset per tile senza rotazione [S:MML `wrot_tile_calc`]: `OFST_ADDR = out_ys*stride + out_xs*Bpp`,
`OFST_ADDR_C = (out_ys >> vsh)*stride_c + (out_xs >> hsh)*bpp_uv/8`. Con flip/rotazione le formule cambiano (stesso
file, una per caso). Tile unico: tutti 0.

### 4.4 MDP_MUTEX (0x1B001000)

| off | nome | uso | fonte |
|---|---|---|---|
| 0x000 | `MUTEX_INTEN` | bit n = SOF del mutex n, bit n+16 = EOF del mutex n | DRM (mutex del display, stesso IP) [I per MDP] |
| 0x004 | `MUTEX_INTSTA` | stessi bit; si azzera scrivendo il complemento (`writel(~val)`) | DRM [I] |
| 0x008 | `MUTEX_CFG` | | DRM |
| 0x020 + 0x20n | `MUTEXn_EN` | 1 = parte il frame | MDP dump, UP, MML |
| 0x024 + 0x20n | `MUTEXn` / shadow | non usare | UP, MML |
| 0x028 + 0x20n | `MUTEXn_RST` | | UP |
| 0x02C + 0x20n | `MUTEXn_SOF` (`_CTL`) | **0 = single mode** (parte quando si scrive EN, niente sincronismo con DSI) | MDP dump, UP `mt8186_mdp_mutex_driver_data`, MML |
| 0x030 + 0x20n | `MUTEXn_MOD0` | maschera dei motori che ricevono lo start (SOF) | MDP dump, UP |
| 0x034 + 0x20n | `MUTEXn_MOD1` | moduli 32+: **0** | MDP dump, UP |

Il dump di [S:MDP] legge i mutex 0..4 a 0x20/0x2C/0x30/0x34 + 0x20n: coincide con `mt8186_mdp_mutex_driver_data`
(`mutex_mod_reg` 0x30, `mod1` 0x34, `sof_reg` 0x2C) [S:UP mtk-mutex.c].

**Bit dei moduli in `MOD0`** [I, forte]. Regola: *bit del modulo = numero dell'evento GCE "SOF" del motore meno la base
del sottosistema*. Verifiche:

- display MT6781: `MT6781_MUTEX_MOD_DISP_OVL0 BIT(0)`, `OVL0_2L 1`, `RDMA0 2`, `RSZ0 3`, `COLOR0 4`, `CCORR0 5`,
  `AAL0 7`, `GAMMA0 8`, `POSTMASK0 9`, `DITHER0 10`, `DSC_WRAP0 13`, `DSI0 14`, `WDMA0 15`, `PWM0 16` [S:DRM]; eventi
  GCE `DISP_OVL0_SOF` 384, `OVL0_2L` 385, `RDMA0` 386, `RSZ0` 387, `COLOR0` 388, `CCORR0` 389, `CCORR1` 390, `AAL0`
  391, `GAMMA0` 392, `POSTMASK0` 393, `DITHER0` 394, `DSC_WRAP0` 397, `DSI0` 398, `WDMA0` 399, `PWM0` 400 [S:GCE]:
  **tutti coincidono** (evento - 384);
- MT6893: moduli del mutex MML `rdma0 0 .. rsz0 12 .. wrot0 16 .. tdshp0 20 .. tcc0 24` [S:6893 dtsi] ed eventi
  `MDP_RDMA0_SOF 256 .. RSZ0 268 .. WROT0 272 .. TDSHP0 276 .. TCC0 280` [S:6893 gce.h]: coincidono (evento - 256);
- MT8186 (stesso mdpsys a 0x1B000000 e stesso larb2 a 0x1B002000 [S:UP mt8186.dtsi]): `MT8186_MUTEX_MOD_MDP_RDMA0 0,
  AAL0 2, HDR0 4, RSZ0 5, RSZ1 6, WROT0 7, TDSHP0 9` [S:UP mtk-mutex.c].

Eventi SOF MDP di MT6781 [S:GCE]: RDMA0 256, RDMA1 257, AAL0 258, AAL1 259, HDR0 260, RSZ0 261, RSZ1 262, WROT0 263,
WROT1 264, TDSHP0 265, TDSHP1 266, IMG_DL_RELAY0 267, RELAY1 268, COLOR0 269. Quindi su MT6781:

| motore | bit `MOD0` |
|---|---|
| RDMA0 | 0 (0x001) |
| RDMA1 | 1 |
| AAL0 | 2 (0x004) |
| AAL1 | 3 |
| HDR0 | 4 (0x010) |
| RSZ0 | 5 (0x020) |
| RSZ1 | 6 |
| WROT0 | 7 (0x080) |
| WROT1 | 8 |
| TDSHP0 | 9 (0x200) |
| TDSHP1 | 10 |
| camin (relay0) / camin2 | 11 / 12 |
| COLOR0 | 13 (MT8186 ha 14) |

Valori: RDMA0+WROT0 = **0x081**; RDMA0+RSZ0+WROT0 = **0x0A1**; con anche TDSHP0 = 0x2A1; con HDR0+AAL0 in più = 0x2B5.
Conferma sul telefono: `peek 0x14001030` (MOD0 del mutex 0 del display, programmato da LK) deve avere i bit del percorso
del display (per esempio 0 OVL0, 2 RDMA0, 4..10, 14 DSI0) [I]; per MDP, sezione 8.2.

Come lo usa Linux [S:UP mtk-mdp3-cmdq.c `mdp_path_subfrm_require`/`_run`; S:MML mtk-mml-mutex.c]: scrive `MOD0/MOD1` e
`SOF = 0` (single mode), configura i motori, poi **per ogni tile** azzera gli eventi SOF, scrive `EN = 1`, aspetta i SOF
dei motori e poi gli eventi di fine (EOF) dei motori. MML a fine lavoro scrive `EN = 0`.

### 4.5 Codici colore (comuni a RDMA e WROT)

`MML_FMT`/`MDP_COLOR`: `hw_fmt` = bit [4:0], `swap` = bit 5 [S:MML mtk-mml-color.h][S:UP mtk-mdp3-regs.h].

| formato MTK | `hw_fmt` | `swap` | byte in memoria (offset crescente) | FourCC iOS / V4L2 |
|---|---|---|---|---|
| RGB565 / BGR565 | 0 | 0 / 1 | | |
| RGB888 | 1 | 1 | R, G, B | V4L2 `RGB24` |
| BGR888 | 1 | 0 | B, G, R | V4L2 `BGR24` |
| **BGRA8888** | **2** | **0** | **B, G, R, A** | **'BGRA'**, V4L2 `ABGR32` (`AR24`) |
| RGBA8888 | 2 | 1 | R, G, B, A | 'RGBA' [I] |
| ARGB8888 | 3 | 1 | A, R, G, B | V4L2 `ARGB32` (`BA24`) |
| ABGR8888 | 3 | 0 | A, B, G, R | |
| UYVY / VYUY | 4 | 0 / 1 | | '2vuy' = UYVY |
| **YUYV** / YVYU | **5** | 0 / 1 | Y0 U Y1 V | 'yuvs' |
| GREY (Y8) | 7 | 0 | | |
| I420 / YV12 | 8 | 0 / 1 | 3 piani | |
| I422 / YV16 | 9 | 0 / 1 | 3 piani | |
| I444 / YV24 | 10 | 0 / 1 | 3 piani | |
| **NV12** / NV21 | **12** | 0 / 1 | Y, poi UV interlacciato | '420v'/'420f' = NV12 |
| NV16 / NV61 | 13 | 0 / 1 | | '422v'/'422f' [I] |
| NV24 / NV42 | 14 | 0 / 1 | | |

La corrispondenza V4L2 viene da `mdp_cfg_data.c` [S:UP] (`V4L2_PIX_FMT_ABGR32` → `MDP_COLOR_BGRA8888`,
`V4L2_PIX_FMT_ARGB32` → `MDP_COLOR_ARGB8888`, `RGB24` → `RGB888` con swap 1): quindi **swap = 1 vuol dire R per primo
in memoria** e il 'BGRA' di iOS è `hw_fmt 2, swap 0` [I, forte]. Bit per pixel: RGB32 32, RGB24 24, YUYV 16, Y 8, UV di
NV12 16 per campione di croma [S:MML `rdma_color_fmt`].

### 4.6 Motori PQ in relay (solo se stanno per forza nel percorso)

Da MML (generazione più nuova; per MT6781 [I]):

| motore | relay | dimensioni (anche in relay [I]) |
|---|---|---|
| TDSHP0 0x1B00C000 | `TDSHP_CTRL` (0x100) bit 0 = 1, `TDSHP_CFG` (0x110) bit 0 = 1 | `INPUT_SIZE` 0x120 e `OUTPUT_SIZE` 0x128 = `(w << 16) \| h` (attenzione: w in alto), `OUTPUT_OFFSET` 0x124 = 0 |
| AAL0 0x1B005000 | `AAL_EN` (0x000) = 1, `AAL_CFG` (0x020) bit 0 = 1 | `AAL_SIZE` 0x030 e `AAL_OUTPUT_SIZE` 0x034 = `(w << 16) \| h`, `OUTPUT_OFFSET` 0x038 = 0 |
| HDR0 0x1B007000 | `HDR_RELAY` (0x004) = 1 | `HDR_SIZE_0` 0x014 = `(h << 16) \| w` |
| RSZ0/RSZ1 | `RSZ_ENABLE` = 0 | nessuna |

## 5. Instradamento in mdpsys (MOUT / SEL / SOUT)

### 5.1 Registri [S:MDP `cmdq_mdp_dump_mmsys_config`]

| PA | nome |
|---|---|
| 0x1B000F00 | `MMSYS_MOUT_RST` (bit 2 = MOUT di RDMA0) [S:MDP `cmdqMdpResetEng`] |
| 0x1B000F10 / F14 | `ISP0_MOUT_EN` / `ISP1_MOUT_EN` |
| 0x1B000F20 / F24 | `MDP_RDMA0_MOUT_EN` / `MDP_RDMA1_MOUT_EN` |
| 0x1B000F28 | `MDP_AAL0_MOUT_EN` (non c'è su MT6853) |
| 0x1B000F30 / F34 | `MDP_PQ0_SEL_IN` / `MDP_PQ1_SEL_IN` |
| 0x1B000F70 / F74 | `MDP_WROT0_SEL_IN` / `MDP_WROT1_SEL_IN` |
| 0x1B000F80 / F84 | `MDP_PQ0_SOUT_SEL` / `MDP_PQ1_SOUT_SEL` |
| 0x1B000FD0..FD8 | `MDPSYS_MOUT_MASK0..2` |
| 0x1B000FE0..FE8 | `MDPSYS_DL_VALID0..2` (debug: c'è un dato valido sul collegamento) |
| 0x1B000FF0..FF8 | `MDPSYS_DL_READY0..2` (debug: il ricevente è pronto) |
| 0x1B000E00 / E04 | `MDPSYS_BUF_UNDERRUN` / `_ID` |

### 5.2 Cosa si sa della semantica

Nessun sorgente pubblico dà i valori per MT6781: li calcola `libdpframework` [I]. Il riferimento più vicino è la
tabella `mux-pins` di MT6893 [S:6893 dtsi], dove `MOUT_EN` è **una maschera (bit = destinazione)** e `SEL_IN`/`SOUT_SEL`
sono **un indice**:

| registro MT6893 | valori |
|---|---|
| `RDMA0_MOUT_EN` (0xF20) | bit 0 → FG0 (inizio del percorso PQ0), **bit 1 → WROT0 diretto** |
| `PQ0_SEL_IN` (0xF30) | 0 = FG0 (cioè RDMA0), 1..4 = camin1..4 |
| `PQ0_SOUT_SEL` (0xF40 su 6893) | 0 → HDR0, 1 → RSZ0 (salta HDR/AAL) |
| `AAL0_MOUT_EN` (0xF48 su 6893) | bit 0 → RSZ0, bit 1 → WROT0, bit 2 → RSZ2 |
| `WROT0_SEL_IN` (0xF70) | 0 = AAL0, 1 = TCC0 (fine catena PQ), **2 = RDMA0** |

MT6781 ha meno mux e offset diversi per alcuni (`AAL0_MOUT_EN` 0xF28, `PQ0_SOUT_SEL` 0xF80), quindi la tabella non si
copia. Ipotesi di partenza [G]:

- **percorso diretto** RDMA0 → WROT0: `RDMA0_MOUT_EN` con un solo bit verso WROT0 (provare 0x2, poi 0x1, 0x4, 0x8)
  e `WROT0_SEL_IN` = indice di RDMA0 (provare 2, 0, 1, 3);
- **percorso con resizer**: `RDMA0_MOUT_EN` verso PQ0, `PQ0_SEL_IN` = RDMA0 (provare 0), dentro PQ0 forse una catena
  fissa HDR0 → AAL0 (→ `AAL0_MOUT_EN` verso RSZ0) → RSZ0 → TDSHP0, `PQ0_SOUT_SEL` verso WROT0, `WROT0_SEL_IN` = PQ0.

### 5.3 Procedura di scoperta (da fare una volta, poi scrivere qui i valori)

1. Prima di tutto leggere i valori di reset: `peek 0x1B000F00 1`, `peek 0x1B000F10 0x20` (da 0xF10 a 0xF8C),
   `peek 0x1B000FD0 0xC` (MOUT_MASK, DL_VALID, DL_READY).
2. Preparare il caso più semplice: copia BGRA 64x64 senza conversione, RSZ in relay, mutex `MOD0 = 0x081`
   (sezione 7.1 con dimensioni ridotte).
3. Per ogni coppia (`RDMA0_MOUT_EN` in {1, 2, 4, 8}) x (`WROT0_SEL_IN` in {0, 1, 2, 3}): reset di RDMA0/WROT0 e del
   MOUT (2.6), scrivere i due mux, avviare (`MUTEX0_EN = 1`), aspettare 5 ms, leggere:
   - RDMA `MON_STA_1` (0x1B003408) [18:8]: 0x80 "data running" fermo = l'uscita di RDMA non è accettata da nessuno;
   - `DL_VALID`/`DL_READY`: il bit che resta valid=1, ready=0 indica il collegamento bloccato;
   - fine di WROT (6.2): se arriva, la coppia è giusta.
   Sono 16 prove: conviene farle con un comando `vctl` di prova nel kernel invece che a mano.
4. Se il diretto non esiste, ripetere con `MOD0` = tutti i motori PQ (0x2B5), tutti in relay (4.6), e provare
   `PQ0_SEL_IN`, `AAL0_MOUT_EN`, `PQ0_SOUT_SEL`, `WROT0_SEL_IN`. Un motore che ha ricevuto lo start (è in `MOD0`) ma non
   riceve dati resta fermo: il mutex non chiude il frame, ma la fine di WROT si vede lo stesso.

## 6. Interrupt e rilevamento della fine

### 6.1 Numeri GIC

- **Nessun nodo MDP del DT ha `interrupts`** (né `mdp_rdma0`, né `mdp_wrot0`, né `mdp_mutex`) [DT], e nemmeno il DT
  sorgente MT6781 di altri vendor [S:`bengris32/android_kernel_mediatek_4.19` `mt6781.dts`]. Il downstream non usa
  interrupt dei motori: aspetta gli eventi GCE dentro le liste di comandi [S:MDP, S:UP mtk-mdp3-cmdq.c].
- Interrupt vicini noti [DT]: `disp_mutex0` SPI 0x127 (295, INTID 327); `disp_ovl0` 0x129, `disp_ovl0_2l` 0x12A,
  `disp_rdma0` 0x12B, ... `disp_dither0` 0x133; `gce_mbox` SPI 0xAA e 0xAB (INTID 202 e 203).
- SPI non assegnati nel DT tra 0x100 e 0x140 (candidati [G]): 0x104-0x106, 0x109-0x111, 0x117-0x11A, 0x11E, 0x120,
  0x123-0x126, 0x128, 0x12F, 0x134, 0x135, 0x13E-0x13F.

Procedura per trovarli [I]: GICv3, distributore a 0x0C000000 [DT]; `GICD_ISPENDR<n>` = 0x0C000200 + 4n, un bit per INTID
(INTID = SPI + 32). Un interrupt di livello risulta pendente anche se disabilitato nel GIC.

1. abilitare la sorgente: `poke 0x1B001000 0x00010001` (mutex 0 SOF+EOF), `poke 0x1B003010 0x1` [G], WROT
   `VIDO_INT_EN` bit 0 [G] (attenzione: i bit [15:8] dello stesso registro sono il selettore di debug);
2. `peek 0x0C000200 32` prima e dopo un trasferimento, confrontare;
3. il bit nuovo è l'interrupt; azzerare la sorgente (`poke 0x1B001004 0` per il mutex [I], `VIDO_INT` 0x1B00A01C)
   e verificare che il bit pendente sparisca.

### 6.2 Fine senza interrupt (da usare per le prove)

In ordine di affidabilità:

1. **Evento GCE** [S:GCE]. Il GCE registra gli eventi hardware anche senza thread in esecuzione [I]. Registri
   [S:GCE mtk-cmdq-mailbox.c]: `SYNC_TOKEN_ID` = 0x1022C060, `SYNC_TOKEN_VAL` = 0x1022C064, `SYNC_TOKEN_UPD` = 0x1022C068.
   Leggere: `poke 0x1022C060 <id>` poi `peek 0x1022C064` (1 = evento arrivato). Azzerare: `poke 0x1022C068 <id>`.
   Impostare: `poke 0x1022C068 (0x10000 | id)`. Il clock GCE è `infracfg_ao` CG0 bit 9 (e bit 27 per il 26 MHz):
   stato 0x10001090 (1 = spento), CLR 0x10001084 [S:CLK `GATE_INFRA0(INFRACFG_AO_GCE_CG, ..., 9)`, `infra0_cg_regs`];
   controllare `peek 0x10001090` prima di leggere 0x1022Cxxx.

   | evento | id |
   |---|---|
   | `MDP_RDMA0_SOF` | 256 (0x100) |
   | `MDP_RSZ0_SOF` | 261 (0x105) |
   | `MDP_WROT0_SOF` | 263 (0x107) |
   | **`MDP_WROT0_FRAME_DONE`** (DT: `mdp_wrot0_write_frame_done`) | **291 (0x123)** |
   | `MDP_RSZ0_FRAME_DONE` | 299 (0x12B) |
   | `MDP_RDMA0_FRAME_DONE` | 303 (0x12F) |
   | `MDP_STREAM_DONE_ENG_EVENT_n` | 320 + n (fine del mutex n [I]) |
   | `MDP_WROT0_SW_RST_DONE` / `MDP_RDMA0_SW_RST_DONE` | 339 / 343 |

   Attenzione: gli id 0x12A..0x12F sono numeri di **evento GCE**, non SPI, anche se somigliano agli SPI del display.
2. **Stato di WROT** [S:MDPC dump][S:MML `wrot_debug_dump`]: `poke 0x1B00A018 0x300` (selettore 3), `peek 0x1B00A0D0`:
   bit 0 = 1 "frame done", 0 "sof"/in corso; bit 1 crop busy, 2 req, 3 valid. Con il selettore 0xA00 lo stesso
   registro dà `x_cnt` [15:0] e `y_cnt` [31:16] (avanzamento). Il selettore sovrascrive `VIDO_INT_EN`.
3. **Mutex**: `peek 0x1B001004`, bit 16 = EOF del mutex 0 [I, da DRM].
4. **RDMA**: `MON_STA_1` [18:8] torna 0x1 (idle) a fine frame [I].

Opzione per avere un vero interrupt senza conoscere gli SPI dei motori [I]: un thread GCE con un programma di due
istruzioni ("aspetta evento 0x123, poi EOC con IRQ") genera l'interrupt GCE (SPI 0xAA/0xAB). Il formato delle
istruzioni è in `drivers/mailbox/mtk-cmdq-mailbox.c` e `cmdq-pkt`; non serve all'inizio.

## 7. Sequenze passo-passo (peek/poke)

Convenzioni: `R` = 0x1B003000 (RDMA0), `Z` = 0x1B008000 (RSZ0), `W` = 0x1B00A000 (WROT0), `M` = 0x1B001000 (mutex).
`SRC`, `DST` = indirizzi fisici < 4 GiB, allineati a 16 byte [I]. I mux (5.3) restano segnaposto `<MOUT>`, `<WSEL>` ecc.
finché non sono scoperti.

**Sorgente e destinazione comode per le prove**: il framebuffer del display. Leggere indirizzo e pitch del layer di LK
come fa `disp` [S:FB]: per OVL0 layer 0 `peek 0x14005F40` (indirizzo) e `peek 0x14005044` (pitch); per gli altri layer
`OVL_L_ADDR(n)` = 0x14005F40 + 0x20n, pitch 0x14005044 + 0x20n, layer estesi `OVL_EL_ADDR(k)` = 0x14005FB0 + 4k. Con
`SRC = FB` (angolo in alto a sinistra) e `DST = FB + 1000*pitch` (stesso stride) il risultato **si vede sullo schermo**,
e il framebuffer è già fisicamente contiguo e non in cache. Qui sotto `P` = pitch del framebuffer (per 1080x2400 BGRA
P = 4320 = 0x10E0).

### 7.0 Preparazione (una volta)

```
; verifiche 2.5 punti 1-5
peek 0x1000616C
peek 0x10006170
peek 0x10006354
peek 0x100000E0
peek 0x14000100
; clock mdp_sel se serve (2.3), poi clock dei motori
poke 0x1B000108 0x00000BC1
peek 0x1B000100
; larb2 (3.3)
poke 0x1B002024 0x00370256
poke 0x1B002040 0x00000001
poke 0x1B002200 0x6
poke 0x1B002204 0x6
poke 0x1B002208 0x6
poke 0x1B00220C 0x6
poke 0x1B002210 0x1
peek 0x1B002380 4
poke 0x1B002380 <(v0 & ~0xFF01) | 0x8>
poke 0x1B002388 <(v2 & ~0xFF01) | 0x8>
; GCE per il polling della fine (6.2)
peek 0x10001090                 ; bit 9 = 0? altrimenti:
poke 0x10001084 0x00000200
```

### 7.1 BGRA → BGRA, stessa dimensione (256x256), senza conversione

```
; --- reset ---
poke 0x1B003008 1               ; RDMA reset
peek 0x1B003408                 ; attendere (v & 0x7FF00) == 0x100
poke 0x1B003008 0
poke 0x1B00A010 1               ; WROT reset
peek 0x1B00A014                 ; attendere bit 0 = 1
poke 0x1B00A010 0
peek 0x1B00A014                 ; attendere bit 0 = 0
poke 0x1B008000 0x10000         ; RSZ reset
poke 0x1B008000 0               ; RSZ in relay (ENABLE = 0)
; --- instradamento (5.3) ---
poke 0x1B000F20 <MOUT>          ; RDMA0_MOUT_EN, percorso diretto
poke 0x1B000F70 <WSEL>          ; WROT0_SEL_IN
; --- RDMA0 ---
poke 0x1B003028 0x00010071      ; GMCIF_CON (meglio: (vecchio & ~0x3F0F1) | 0x10071)
poke 0x1B003030 0x00000602      ; SRC_CON: fmt 2 (BGRA), filterMode 3, swap 0
poke 0x1B003038 0x00000000      ; COMP_CON
poke 0x1B003020 0x00001010      ; CON: simple_mode + lb_2b_mode
poke 0x1B003F00 <SRC>           ; SRC_BASE_0
poke 0x1B003100 <SRC + 255*P + 1023>   ; SRC_END_0 [I]
poke 0x1B003060 <P>             ; MF_BKGD_SIZE_IN_BYTE (stride sorgente)
poke 0x1B003090 0               ; SF_BKGD_SIZE_IN_BYTE
poke 0x1B003200 0x00000000      ; TRANSFORM_0: nessuna conversione
poke 0x1B003118 0               ; SRC_OFFSET_0
poke 0x1B003120 0
poke 0x1B003128 0
poke 0x1B003070 0x01000100      ; MF_SRC_SIZE  (256 << 16 | 256)
poke 0x1B003078 0x01000100      ; MF_CLIP_SIZE
poke 0x1B003080 0               ; MF_OFFSET_1
poke 0x1B003000 1               ; RDMA_EN
; --- WROT0 ---
poke 0x1B00A000 0xA0005002      ; CTRL: uv_ysel 2, uv_xsel 2, preultra, crop_en, fmt 2, swap 0
poke 0x1B00AF00 <DST>           ; BASE_ADDR
poke 0x1B00AF04 0
poke 0x1B00AF08 0
poke 0x1B00A030 <P>             ; STRIDE
poke 0x1B00A03C 0
poke 0x1B00A06C 0
poke 0x1B00A048 0               ; CTRL_2
poke 0x1B00A0DC 0               ; SCAN_10BIT
poke 0x1B00A0E0 0               ; PENDING_ZERO (bit 26)
poke 0x1B00A084 0x00000000      ; MAT_CTRL: nessuna conversione
poke 0x1B00A054 0xFF000000      ; DITHER: alpha fisso 0xFF
peek 0x1B00A070                 ; EOL_SEL:
poke 0x1B00A070 <v | 0x80000000>
poke 0x1B00A074 0x00060010      ; DMA_PREULTRA (ARGB)
poke 0x1B00A02C 0               ; OFST_ADDR
poke 0x1B00A038 0
poke 0x1B00A068 0
poke 0x1B00A078 0x01000100      ; IN_SIZE
poke 0x1B00A024 0x01000100      ; TAR_SIZE
poke 0x1B00A020 0               ; CROP_OFST
poke 0x1B00A008 0x01002000      ; MAIN_BUF_SIZE (W 256, 32 righe, filt_v 0)
poke 0x1B00A07C 1               ; ROT_EN
; --- mutex 0, start ---
poke 0x1B001030 0x00000081      ; MOD0: RDMA0 + WROT0
poke 0x1B001034 0               ; MOD1
poke 0x1B00102C 0               ; SOF = single mode
poke 0x1022C068 0x123           ; azzera evento WROT0 frame done
poke 0x1B001020 1               ; MUTEX0_EN = start
; --- attesa ---
poke 0x1022C060 0x123
peek 0x1022C064                 ; ripetere finché vale 1
; oppure: poke 0x1B00A018 0x300 ; peek 0x1B00A0D0 -> bit 0 = 1
; --- chiusura ---
poke 0x1B00A07C 0               ; ROT_EN = 0
poke 0x1B003000 0               ; RDMA_EN = 0
poke 0x1B001020 0               ; MUTEX0_EN = 0
```

Varianti:

- **conservare l'alpha** [I]: `alpharot` = bit 25 di `SRC_CON` (`0x02000602`) e bit 16 di `VIDO_CTRL` (`0xA0015002`),
  con entrambe le conversioni spente (MML lo fa solo sul percorso RDMA→WROT diretto e con sorgente e destinazione
  ARGB) [S:MML tp-mt6983 `alpharot`]. Il tiling in modalità alpharot vuole tagli a multipli di 4 [S:MML tile_mdp_func.c].
- RGBA invece di BGRA: swap = 1 (`SRC_CON 0x4602`, `VIDO_CTRL 0xA0005102`). BGRA → RGBA = swap solo su un lato.
- Se il diretto RDMA0→WROT0 non esiste, usare il percorso PQ0 della 7.2 con RSZ0 in relay (`ENABLE = 0`), gli altri
  motori PQ in relay (4.6) e i loro bit in `MOD0`.

### 7.2 BGRA con scala

La pipeline interna è YUV: per scalare RGB serve la conversione in RDMA e la riconversione in WROT. Si usa BT.601 full
range ("JPEG") nei due sensi, che evita l'ambiguità del bit 23/24 (4.1) e la perdita di livelli del video range.

**Ingrandimento 128x128 → 256x256** (algo 0). Calcoli [S:RSZFW]:
`step = floor(32768*127/255) = 16319 = 0x3FBF`; `sub = (32768*127 - 16319*255)/2 = 95 = 0x5F`;
`CON_1 = 0x1 | 0x2 | 1<<4 (vert_first) | 0<<5 | 0<<7 | 9<<16 | 9<<21 | 1<<26 | 1<<31 = 0x85290013`.

```
; reset come in 7.1, poi:
poke 0x1B008000 0x10000
poke 0x1B008000 0
; instradamento: RDMA0 -> PQ0 (RSZ0) -> WROT0 (5.3)
poke 0x1B000F20 <MOUT_PQ0>
poke 0x1B000F30 <PQ0_SEL>
poke 0x1B000F80 <PQ0_SOUT>
poke 0x1B000F70 <WSEL_PQ0>
; RDMA0: sorgente 128x128 BGRA con conversione RGB->YUV full range
poke 0x1B003028 0x00010071
poke 0x1B003030 0x00000602
poke 0x1B003038 0
poke 0x1B003020 0x00001010
poke 0x1B003F00 <SRC>
poke 0x1B003060 <P>
poke 0x1B003090 0
poke 0x1B003200 0x00010000      ; TRANSFORM_0: color_tran, matrix_sel 0 (JPEG)
poke 0x1B003118 0
poke 0x1B003070 0x00800080      ; MF_SRC_SIZE 128x128
poke 0x1B003078 0x00800080      ; MF_CLIP_SIZE
poke 0x1B003080 0
poke 0x1B003000 1
; RSZ0
poke 0x1B00822C 0               ; ETC_CONTROL
poke 0x1B008004 0x85290013      ; CON_1
poke 0x1B008008 0x00001000      ; CON_2 (drs_padding_dis, tap_adapt spento)
poke 0x1B008018 0x00003FBF      ; HOR_COEFF_STEP
poke 0x1B00801C 0x00003FBF      ; VER_COEFF_STEP
poke 0x1B008010 0x00800080      ; INPUT_IMAGE 128x128
poke 0x1B008014 0x01000100      ; OUTPUT_IMAGE 256x256
poke 0x1B008020 0               ; LUMA_HOR_INT
poke 0x1B008024 0x5F            ; LUMA_HOR_SUB
poke 0x1B008028 0               ; LUMA_VER_INT
poke 0x1B00802C 0x5F            ; LUMA_VER_SUB
poke 0x1B008030 0               ; CHROMA_HOR_INT
poke 0x1B008034 0x5F            ; CHROMA_HOR_SUB
poke 0x1B008000 1               ; RSZ_ENABLE
; WROT0: 256x256 BGRA, YUV full range -> RGB
; (come 7.1, con:)
poke 0x1B00A084 0x00000041      ; MAT_CTRL: mat_sel 4 (JPEG->RGB), mat_en
poke 0x1B00A078 0x01000100      ; IN_SIZE  256x256 (uscita di RSZ)
poke 0x1B00A024 0x01000100      ; TAR_SIZE
poke 0x1B00A008 0x01002000      ; MAIN_BUF_SIZE
poke 0x1B00A07C 1
; mutex: RDMA0 + RSZ0 + WROT0 (+ eventuali PQ in relay)
poke 0x1B001030 0x000000A1
poke 0x1B00102C 0
poke 0x1022C068 0x123
poke 0x1B001020 1
; attesa e chiusura come 7.1, più:
poke 0x1B008000 0
```

**Riduzione 256x256 → 128x128** (algo 2, cubico 6n tap). Calcoli [S:RSZFW]:
`step = floor(2^20*127/255) = 522232 = 0x7F7F8` (nessun +1: il prodotto inverso torna 2^20); `sub = (255*522232 -
127*2^20)/2 = 4`; `vert_first = 0`; `CON_1 = 0x3 | 2<<5 | 2<<7 | 17<<16 | 17<<21 | 1<<26 | 1<<31 = 0x86310143`;
troncamento cubico non necessario (rapporto 512/1024 <= 512 [S:RSZFW `rsz_auto_coef_trunc`]).
Differenze rispetto all'ingrandimento: `MF_SRC_SIZE`/`CLIP` 0x01000100, `CON_1 0x86310143`, step 0x0007F7F8 nei due assi,
`INPUT_IMAGE 0x01000100`, `OUTPUT_IMAGE 0x00800080`, tutti gli offset `*_SUB = 4` (o 0), WROT `IN_SIZE`/`TAR_SIZE`
0x00800080 e `MAIN_BUF_SIZE 0x00802000`.

Rapporti diversi sui due assi: calcolare `step`, algoritmo e tabella separatamente per x e y; `vert_first = 1` quando
la larghezza in uscita è >= a quella in ingresso [S:RSZFW]. Non ingrandire con gli algoritmi 1/2.

### 7.3 NV12 → BGRA (stessa dimensione 256x256)

Per avere una sorgente NV12 senza scriverla a mano: **prima** BGRA → NV12 con WROT (7.3a), **poi** NV12 → BGRA (7.3b).
Il ritorno deve ridare l'immagine originale con piccole differenze di croma (420).

Buffer: `Y` = 256*256 = 64 KiB, `UV` = 256*128 = 32 KiB; stride Y = 256, stride UV = 256.

**7.3a BGRA → NV12** (RDMA converte in YUV full range, WROT sottocampiona e scrive due piani):

```
; RDMA0 come 7.1 ma:
poke 0x1B003200 0x00010000      ; TRANSFORM_0: RGB -> YUV full range (JPEG)
; RSZ0 in relay (ENABLE = 0), percorso diretto se esiste
; WROT0:
poke 0x1B00A000 0x0000500C      ; CTRL: uv_ysel 0, uv_xsel 0, preultra, crop_en, fmt 12 (NV12), swap 0
poke 0x1B00AF00 <Y>
poke 0x1B00AF04 <UV>
poke 0x1B00AF08 0
poke 0x1B00A030 0x100           ; STRIDE Y
poke 0x1B00A03C 0x100           ; STRIDE_C
poke 0x1B00A06C 0x100           ; STRIDE_V (MML lo scrive uguale a C)
poke 0x1B00A084 0               ; MAT_CTRL: nessuna conversione (i dati sono già YUV)
poke 0x1B00A074 0x000D80C4      ; DMA_PREULTRA (2 piani)
poke 0x1B00A008 0x01004030      ; MAIN_BUF_SIZE: W 256, 64 righe, filt_v 3
; IN_SIZE, TAR_SIZE 0x01000100, offset 0, ROT_EN 1, mutex 0x081, start, attesa
```

**7.3b NV12 → BGRA**:

```
; RDMA0
poke 0x1B003030 0x0000040C      ; SRC_CON: fmt 12 (NV12), filterMode 2 (420 -> 422), swap 0
poke 0x1B003020 0x00001010
poke 0x1B003F00 <Y>             ; SRC_BASE_0
poke 0x1B003F08 <UV>            ; SRC_BASE_1
poke 0x1B003100 <Y + 0xFFFF>    ; SRC_END_0 [I]
poke 0x1B003108 <UV + 0x7FFF>   ; SRC_END_1 [I]
poke 0x1B003060 0x100           ; stride Y
poke 0x1B003090 0x100           ; stride UV
poke 0x1B003200 0               ; TRANSFORM_0: niente (la sorgente è già YUV)
poke 0x1B003118 0
poke 0x1B003120 0               ; SRC_OFFSET_1
poke 0x1B003070 0x01000100
poke 0x1B003078 0x01000100
poke 0x1B003000 1
; WROT0 come 7.1 ma:
poke 0x1B00A084 0x00000041      ; MAT_CTRL: JPEG (BT.601 full) -> RGB, per il giro di prova
; per '420v' BT.601 video: 0x61; per BT.709 video: 0x71
```

Se in 7.3b il croma esce sbagliato (WROT che riceve 422 direttamente da RDMA) [I], mettere RSZ0 nel percorso a 1:1
(algo 0, `step = 32768 = 0x8000` nei due assi, tabella 7, `use121filter = 0` perché la sorgente è sottocampionata:
`CON_1 = 0x3 | 1<<4 | 7<<16 | 7<<21 | 1<<31 = 0x80E70013`, offset 0), così il suo upsampler 422→444 fa il lavoro.
YUYV in ingresso: `SRC_CON = 0x00000605` (fmt 5, filterMode 3), un piano, stride = 2*W.

## 8. Ordine delle prove e cose da verificare

### 8.1 Ordine

1. 2.5: power e clock, primo accesso a mdpsys (`peek 0x1B000100`).
2. Dump dei mux e dei registri di debug ai valori di reset (5.3 punto 1); dump di RDMA (`peek 0x1B003000 0x50`),
   WROT (`peek 0x1B00A000 0x40`), RSZ (`peek 0x1B008000 0x10`), mutex (`peek 0x1B001000 0x10`).
3. Reset dei motori (2.6) e verifica degli stati: RDMA idle 0x100 in `MON_STA_1` [18:8]=0x1.
4. Larb2 (3.3) e GCE (6.2).
5. Scoperta dei mux (5.3) con 64x64.
6. 7.1 a 256x256, poi alpharot, poi 7.2, poi 7.3a/b.
7. Scoperta degli SPI (6.1).
8. Dimensioni grandi (8.3) e tiling.

### 8.2 Domande aperte e come chiuderle

| domanda | come verificarla |
|---|---|
| bit dei moduli del mutex (4.4) | dopo `MUTEX0_EN = 1` con `MOD0 = 1<<k`, leggere gli eventi GCE 256..269 (6.2): deve accendersi solo `256 + k` |
| mux di mdpsys (5.2) | procedura 5.3 |
| `matrix_sel` di RDMA al bit 23 o 24 (4.1) | 7.3a con `TRANSFORM_0 = 0x01010000` e poi `0x02010000`, confrontare con la conversione CPU BT.601 video |
| alpharot su MT6781 | 7.1 con le varianti, sorgente con alpha non 0xFF |
| `SRC_END_*` necessari e con quale valore | provare 0, poi base+size-1 |
| larghezza massima di un tile (8.3) | aumentare W finché WROT/RDMA non si bloccano o l'immagine si rompe |
| `RDMA_INTERRUPT_*` e `VIDO_INT_EN` bit 0 | procedura 6.1 |
| stato iniziale di `CK_CFG_10` bit 31 | `peek 0x100000E0` |

### 8.3 Limiti noti

- **Dimensioni per tile**: i campi dimensione sono a 13 bit (maschere 0x1FFF1FFF di `MF_SRC_SIZE`, `MF_CLIP_SIZE`,
  `VIDO_IN_SIZE`, `VIDO_TAR_SIZE`, `VIDO_CROP_OFST` [S:UP]): massimo 8191 in ogni direzione.
- **Larghezza massima di un tile** (dati di MT6893 in MML, il più vicino documentato; **per MT6781 [I]**, probabilmente
  uguali o minori):
  - RDMA `tile_width = 640` [S:MML `mt6893_rdma_data`]; il limite in ingresso vale L per YUV420 e formati a blocchi,
    2L per YUV422, **4L per RGB/YUV444/Y8** [S:MML `tile_rdma_init`] → 2560 pixel BGRA, 1280 YUYV, 640 NV12;
  - RSZ `tile_width = 544` [S:MML `mt6893_rsz_data`]: con 6 tap verticali o `vert_first` il tile in ingresso è al
    massimo L; altrimenti l'uscita è al massimo L-2 (o L/2-2 con algoritmi ad accumulo verticali) [S:MML `tile_prz_init`];
  - WROT `tile_width = 512` [S:MML `mml_wrot_data`]: uscita massima **2L = 1024** senza rotazione né flip, **L = 512** con
    rotazione 90/270 o flip [S:MML `tile_wrot_init`]; inoltre la FIFO (`MAIN_BUF_SIZE`, 4.3) deve contenere almeno
    qualche riga.
  - Conseguenza: **un frame largo 1080 (lo schermo di viva) richiede almeno 2 tile**, e con RSZ attivo almeno 3. Per le
    prove a mano restare a W <= 512.
- **Tiling** [S:MML `rdma_config_tile`, `wrot_config_tile`, `rsz_config_tile`; S:UP mtk-mdp3-cmdq.c]: per ogni tile
  verticale si riprogrammano `RDMA_SRC_OFFSET_0/1/2` (in byte: `x*Bpp + y*stride`, croma con gli shift), `MF_SRC_SIZE`,
  `MF_CLIP_SIZE`, `MF_OFFSET_1`; RSZ `INPUT/OUTPUT_IMAGE`, `CON_2` (bit 11..13) e gli offset `LUMA/CHROMA_*`; WROT
  `OFST_ADDR*`, `IN_SIZE`, `TAR_SIZE`, `CROP_OFST`, `MAIN_BUF_SIZE`; poi `MUTEX0_EN = 1` e attesa fine **per ogni
  tile**. Con RSZ i tile in ingresso si sovrappongono (6 tap: 2 pixel a sinistra, 3 a destra) e le posizioni vanno
  calcolate con `backward_*`/`forward_*` di `DpTileScaler.c` [S:MML] (da portare nel nostro driver così come sono).
- **Allineamenti**: per sorgenti/destinazioni 420/422 le coordinate x dei tile e le larghezze devono essere pari
  (`in_const_x = 2`) [S:MML `tile_rdma_init`]; WROT con larghezza dispari e `uv_xsel == 1` passa a 0 [S:MML]. Indirizzi
  base e stride: nessun vincolo scritto; usare multipli di 16 byte [I] (lo stride WROT è a 16 bit: massimo 65535 byte
  [S:UP maschera]).
- **Algoritmi del resizer**: ingrandimento solo con 6 tap; riduzione oltre 1/24 con accumulo sorgente; passo a 23 bit
  [S:RSZFW]. I formati RGB attraversano RSZ come YUV 422 (conversione 444→422 con filtro [1 2 1], `use121filter`):
  scalando RGB si perde metà della risoluzione di croma orizzontale [S:MML `rsz_prepare`][I effetto].
- **Alpha**: WROT scrive l'alpha fisso di `VIDO_DITHER[31:24]` in tutti i formati ARGB, salvo modalità alpharot
  (solo percorso diretto, senza conversioni, senza scala) [S:MML].
- **Colore**: niente matrice BT.709 full range; RDMA converte solo RGB→YUV, WROT entrambe le direzioni (4.1, 4.3).
  WROT non supporta lo swap U/V con 3 piani (MML scambia gli indirizzi) [S:MML].
- **Memoria**: PA < 4 GiB con larb in bypass; MDP non coerente con le cache (3.3) [I].
- **Frequenza**: 312-560 MHz (passi mmdvfs del DT) [DT].

## 9. Riepilogo dei registri usati (PA)

| PA | registro | valore tipico |
|---|---|---|
| 0x1000616C / 0x10006170 | SPM PWR_STATUS / _2ND | bit 21 = 1 |
| 0x10006354 | DIS_PWR_CON | 0x0000000D |
| 0x100000E0 / E4 / E8 | CK_CFG_10 / SET / CLR (`mdp_sel` [27:24]) | 4 |
| 0x10000008 | CLK_CFG_UPDATE1 | 0x00001000 |
| 0x10001090 / 0x10001084 | INFRA CG0 stato / CLR (GCE bit 9) | |
| 0x14000100 | MMSYS_CG_CON0 (SMI) | bit 11/17/22/24 = 0 |
| 0x1B000100 / 104 / 108 | MDPSYS_CG_CON0 / SET0 / CLR0 | CLR0 = 0xBC1 |
| 0x1B000700 | MMSYS_SW0_RST_B | 0xFFFFFFFF |
| 0x1B000F00..0x1B000FF8 | mux e debug di instradamento | 5.1 |
| 0x1B001020 / 2C / 30 / 34 | MUTEX0 EN / SOF / MOD0 / MOD1 | 1 / 0 / 0x81 o 0xA1 / 0 |
| 0x1B002024 / 040 / 200..210 | larb2 THRT / SW_FLAG / OSTDL | 0x370256 / 1 / 6,6,6,6,1 |
| 0x1B002380 / 0x1B002388 | larb2 NON_SEC_CON RDMA0 / WROT0 | bit 0 = 0 |
| 0x1B003000.. | RDMA0 | 4.1 |
| 0x1B008000.. | RSZ0 | 4.2 |
| 0x1B00A000.. | WROT0 | 4.3 |
| 0x1022C060 / 64 / 68 | GCE SYNC_TOKEN_ID / VAL / UPD | evento 0x123 |
| 0x0C000200.. | GICD_ISPENDR | 6.1 |

---

## 10. Risultati sul telefono (2026-11-05 notte, a mano via link USB)

Verificato:
- Accensione: con il display acceso DIS è su (`0x1000616C` bit 21), `mdp_sel` = 0x08, bus non protetto. Primo accesso a
  `0x1B000100` sicuro (0xFFFFFFFF = tutti i clock spenti); `poke 0x1B000108 0xBC1` → `0xFFFFF43E` (RDMA0, SMI0, APB,
  WROT0, RSZ0, MUTEX0 accesi). Motori leggibili e scrivibili (`SRC_BASE_0` scrittura/lettura ok).
- larb2: porte 0 e 2 da 0x1 (M4U) a 0x8 (bypass) ok; init OSTD/CMD_THRT/SW_FLAG come §3.3.
- **Instradamento diretto RDMA0 → WROT0: `RDMA0_MOUT_EN` (0x1B000F20) = 0x2 e `WROT0_SEL_IN` (0x1B000F70) = 0.**
  Con `MUTEX0_MOD0` = 0x81 e SOF = 0 il frame 64x64 si chiude: WROT done (debug 0x300 → bit 0 di 0x1B00A0D0), RDMA torna
  idle (`MON_STA_1` 0x00600100), `DL_VALID` a 0. Le altre 15 coppie lasciano RDMA in "data running" con il dato fermo in
  `DL_VALID` (bit 19+k per `MOUT` = 1<<k, bit 27 = ingresso di WROT0).
- **Il reset software di WROT (0x1B00A010) lascia `SOFT_RST_STAT` a 1 per sempre** se il motore non ha mai completato un
  frame: usare il reset di sistema `poke 0x1B000700 0xFFFFFCFE` poi `0xFFFFFFFF` (RDMA0+RSZ0+WROT0), che lo sblocca.
- `MUTEX_INTSTA` (0x1B001004) bit 0 si alza allo start: il mutex 0 parte.

Aperto: **il contenuto scritto da WROT non segue la sorgente**. Sorgente BGRA 64x64, stride 256, riga 0 con 16 colori
diversi: l'uscita è uno schema fisso con periodo 2 pixel (senza conversioni `ff330000 ff110000 …`, cioè R = byte 1 e
byte 3 del solo primo pixel, G = B = 0; con `TRANSFORM_0 = 0x10000` e `MAT_CTRL = 0x41` `ff810100 fffe0000 …`), anche
dove la sorgente cambia. Ipotesi da provare: formato del collegamento interno (RDMA in "simple mode" emette 4:2:2,
WROT con `uv_xsel/uv_ysel = 2` si aspetta 4:4:4?), `RDMA_CON` diverso per MT6781 (bit 12 `lb_2b_mode`), `MF_SRC_SIZE`
con w/h invertiti (qui 64x64, non distingue), percorso via PQ0 con RSZ0 in relay invece del diretto. Finché non è
chiuso il backend MDP dello scaler resta il segnaposto e lavora la CPU (`vivascaler=2` ripiega su 1).

### 10.1 Aggiornamento (2026-11-06): copia e NV12 → BGRA funzionano

- Le prove precedenti erano in parte falsate: **con lo schermo spento il dominio DIS si spegne e l'MDP perde clock e
  registri** (`CG_CON0` torna 0xFFFFFFFF). Ogni prova (e il driver) rifà clock, larb2, reset e mux; il driver usa la
  CPU se il pannello è spento.
- **I codici formato di RDMA su MT6781 non sono quelli di MML/mdp3**. Trovati provando 0..15 (`SRC_CON` = filterMode
  | codice):
  - BGRA 8888: **codice 14** (`SRC_CON` 0x60E) → copia esatta pixel per pixel con WROT `VIDO_CTRL` 0xA0005002;
  - NV12 4:2:0: **codice 1** (`SRC_CON` 0x601 croma replicata, 0x201 croma interpolata in orizzontale), con WROT
    `MAT_CTRL` 0x41 (BT.601 full) → valori attesi su righe 0-2 (croma verticale 4:2:0 corretta);
  - codice 5 = NV16 (croma per riga); 3 = 2 piani con un'altra disposizione; 11 = Y8 (grigio).
- **Larghezza massima di una striscia** RDMA0→WROT0: 640 pixel si chiudono, 1024 no. Il driver usa strisce da 512.
- Backend nel kernel: patch 0171 (`VivaMDP.cpp`), NV12 → BGRA alla stessa dimensione con `vivascaler=2`; tutto il
  resto (scala, RGB → RGB) resta alla CPU. Prossimo passo: percorso via RSZ0 per la scala.
