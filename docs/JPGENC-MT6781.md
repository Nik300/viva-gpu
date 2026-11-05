# JPGENC MT6781 (Helio G96, "viva"): guida di programmazione a livello di registri

Data: 2026-11-05. Obiettivo: codificare in JPEG un'immagine YUV (NV12/NV21/YUYV/YVYU) presa dalla memoria fisica,
dal nostro kernel XNU bare-metal, senza Linux e (all'inizio) senza tabelle di pagine M4U, cioè con le porte
del larb in bypass e indirizzi fisici.

Stato: **documento di riferimento, niente è ancora stato provato sul telefono.** Le sezioni 5 e 7 dicono cosa verificare
prima e in che ordine.

## 0. Legenda delle fonti

Ogni fatto porta un'etichetta:

- **[S:xxx]** = letto nel sorgente indicato. Tutti i percorsi sono nel kernel Xiaomi `MiCode/Xiaomi_Kernel_OpenSource`,
  ramo `viva-r-oss`, salvo **[UP]** = Linux upstream `torvalds/linux`,
  `drivers/media/platform/mediatek/jpeg/mtk_jpeg_enc_hw.{c,h}` + `mtk_jpeg_core.c`.
- **[DT]** = device tree vivo `dtb/viva-live.dts`.
- **[I]** = dedotto (ragionamento o analogia), **da verificare sul telefono**.

Abbreviazioni dei sorgenti:

| sigla | file |
|---|---|
| ENC | `drivers/media/platform/mtk-jpeg/mtk_jpeg_enc_hw.c`, `mtk_jpeg_enc_hw.h`, `mtk_jpeg_enc_reg.h` |
| CORE | `drivers/media/platform/mtk-jpeg/mtk_jpeg_core.c`, `mtk_jpeg_core.h` |
| V2 | `drivers/misc/mediatek/jpeg/v2/jpeg_drv_enc.c`, `jpeg_drv_reg.h`, `jpeg_drv_common.h`, `jpeg_drv.c` (driver legacy) |
| PG | `drivers/clk/mediatek/clk-mt6781-pg.c` (MTCMOS) |
| CLK | `drivers/clk/mediatek/clk-mt6781.c`, `include/dt-bindings/clock/mt6781-clk.h` |
| SMI | `drivers/misc/mediatek/smi/smi_drv.c`, `smi_reg.h`, `smi/mt6781/smi_conf.h`, `smi/mt6781/smi_port.h`, `smi/mt6781/smi_hw.h` |
| M4U | `drivers/misc/mediatek/pseudo_m4u/pseudo_m4u_v2.c`, `drivers/misc/mediatek/include/mt-plat/mt6781/include/mach/pseudo_m4u.h`, `include/dt-bindings/memory/mt6781-larb-port.h` |

### Quale driver usa davvero viva

- `arch/arm64/configs/viva_defconfig` contiene `CONFIG_VIDEO_MEDIATEK_JPEG=y`, `CONFIG_MACH_MT6781=y`,
  `CONFIG_MTK_PLATFORM="mt6785"`, `CONFIG_MTK_PSEUDO_M4U=y`, `CONFIG_MTK_IOMMU_V2=y`, `CONFIG_MTK_SMI_EXT=y` [S:viva_defconfig].
- Il driver V4L2 `drivers/media/platform/mtk-jpeg` ha `.compatible = "mediatek,jpgenc"` nella sua tabella OF [S:CORE],
  esattamente il compatible del nodo `jpgenc@17030000` [DT]. Il suo Makefile ha rami espliciti per `CONFIG_MACH_MT6781`
  [S:drivers/media/platform/mtk-jpeg/Makefile]. **È questo il driver di riferimento.**
- Il driver legacy V2 cerca `"mediatek,venc_jpg"` [S:V2 jpeg_drv.c], che nel DT di viva non c'è: viene compilato
  (piattaforma "mt6785") ma non dovrebbe fare probe [I]. È comunque utile: stessi registri, più commenti e controlli.
- Upstream [UP] è la stessa famiglia di IP (stessi offset da 0x100 a 0x318); aggiunge i registri `*_EXT`
  (0x584..0x594) per indirizzi a 34 bit, usati solo dalle varianti con `support_34bit` (mt8195). Il driver MT6781
  non li tocca mai [S:ENC].

## 1. Mappa hardware (dal device tree vivo)

| blocco | PA | note |
|---|---|---|
| `jpgenc@17030000` | 0x17030000, 64 KiB | `interrupts = <0 0xf5 4>` = GIC SPI 245, livello alto, **INTID 277**; `clocks = <&venc_gcon 3>` "jpgenc"; `mediatek,larb = <&smi_larb7>`; `iommus = <&m4u 0xe9>`; `port-id = <0xe9 0xea 0xeb 0xec>`; `cshot-spec = <0x170>` [DT] |
| `venc_gcon@17000000` (phandle 0x32) | 0x17000000, 64 KiB | provider dei clock VENC, `mediatek,venc_gcon` [DT] |
| `smi_larb7@17010000` (phandle 0x7e) | 0x17010000, 4 KiB | `mediatek,smi-id = 7`; `clocks = <&scpsys 6>, <&venc_gcon 2>, <&venc_gcon 3>` = "scp-venc", "venc-set1", "venc-set2" [DT] |
| `venc@17020000` | 0x17020000 | encoder video H.264 (stesso larb7, IRQ SPI 0xf3), non lo tocchiamo [DT] |
| `scpsys@10001000` | reg[0]=0x10001000 infracfg_ao, reg[1]=0x10006000 SPM, reg[2]=0x1020e000 infracfg, reg[3]=0x10000000 topckgen, reg[4]=0x14002000 smi_common [DT], indici usati da `mt_scpsys_init` [S:PG] |
| `topckgen@10000000` | 0x10000000 | mux `venc_sel` [DT][S:CLK] |
| `smi_common@14002000` | 0x14002000 | nel dominio DIS (display), già acceso [DT] |
| `dispsys_config@14000000` | 0x14000000 | gate SMI common in MMSYS_CG_CON0 [S:CLK] |

Porte M4U: `MTK_M4U_ID(larb, port) = (larb << 5) | port` [S:M4U mt6781-larb-port.h], quindi 0xe9..0xec = larb 7,
porte 9..12:

| ID | larb7 porta | nome | indice in `port-id` |
|---|---|---|---|
| 0xe9 | 9 | `M4U_PORT_L7_JPGENC_Y_RDMA` | 0 = YRDMA (lettura luma / YUYV) |
| 0xea | 10 | `M4U_PORT_L7_JPGENC_C_RDMA` | 1 = CRDMA (lettura croma) |
| 0xeb | 11 | `M4U_PORT_L7_JPGENC_Q_TABLE` | 2 = QTBLE |
| 0xec | 12 | `M4U_PORT_L7_JPGENC_BSDMA` | 3 = BSDMA (scrittura bitstream) |

[S:M4U mt6781-larb-port.h][S:CORE `MTK_JPEG_PORT_INDEX_*`]. Le porte 0..8 di larb7 sono del VENC video: non toccarle.

## 2. Accensione: power domain, clock, verifica

### 2.1 Cosa fa Linux (catena completa)

1. `mtk_jpeg_clk_on_ctx()` [S:CORE]: `smi_bus_prepare_enable(7)` → abilita il clock dello SMI common e poi i clock del
   nodo larb7 [S:SMI]: `scp-venc` (power gate `SCP_SYS_VEN` = 6 [S:CLK binding]), `venc-set1` (VENC_GCON 2),
   `venc-set2` (VENC_GCON 3).
2. Poi `clk_prepare_enable("jpgenc")` = VENC_GCON 3 [S:CORE][DT].
3. Poi, per le 4 porte jpgenc, `m4u_config_port(Virtuality=1)` → attiva la traduzione M4U (bit 0 di
   `SMI_LARB_NON_SEC_CON`) [S:CORE][S:M4U]. **Noi faremo l'opposto (sezione 3).**
4. Il power gate `pg_ven` ha `parent = pg_dis` e `pre_clk = venc_sel` [S:PG `PGATE(SCP_SYS_VEN, pg_ven, pg_dis, venc_sel, SYS_VEN)`]:
   prima di accendere VEN, il dominio DIS deve essere acceso e il mux `venc_sel` abilitato.
5. Dopo l'accensione di VEN, la callback SMI `smi_subsys_after_on(SYS_VEN)` (larb mask `1<<7` [S:SMI smi_hw.h])
   riprogramma larb7: OSTD per porta e bit di throttle (2.5) [S:SMI].

### 2.2 Prerequisiti (dominio DIS e SMI common)

Lo SMI common (0x14002000) è nel dominio DIS e serve anche al display: sul telefono che mostra immagini è già acceso [I].
Verificarlo comunque:

- `peek 0x1000616C` (SPM `PWR_STATUS`) e `peek 0x10006170` (`PWR_STATUS_2ND`): bit 21 (`DIS_PWR_STA_MASK`) = 1 in entrambi [S:PG].
- `peek 0x14000100` (`MMSYS_CG_CON0`, `sta_ofs` 0x100, set 0x104, clr 0x108): i bit 11 (`mm_smi_infra`), 17 (`mm_smi_common`),
  22 (`mm_smi_gals`), 24 (`mm_smi_iommu`) devono essere **0** (gate MM0 normali: bit=1 vuol dire clock spento) [S:CLK].
  Se uno è a 1: `poke 0x14000108 (1<<n)` (registro CLR) [S:CLK `mm0_cg_regs`]. Nel nostro kernel i gate SMI sono
  `*_DUMMY` (Linux non li spegne mai) [S:CLK].

### 2.3 Mux `venc_sel` (topckgen)

`MUX_CLR_SET_UPD(TOP_MUX_VENC, "venc_sel", venc_parents, CK_CFG_9, CK_CFG_9_SET, CK_CFG_9_CLR, 0, 3, INV_BIT, 0x008, 5)` [S:CLK]:

| campo | valore |
|---|---|
| `CLK_CFG_9` | 0x100000D0 (stato), SET 0x100000D4, CLR 0x100000D8 |
| selettore | bit [2:0] |
| bit di gate | nessuno (`INV_BIT`) |
| aggiornamento | scrivere `1<<5` in `CLK_CFG_UPDATE1` = 0x10000008 |

Genitori (indice → sorgente) [S:CLK `venc_parents`]: 0 clk26m, 1 mmpll_ck, 2 mainpll_d2_d2, 3 mainpll_d2,
4 univpll_d3, 5 univpll_d2_d2, 6 mainpll_d3, 7 mmpll_ck.

Il DT dichiara per mmdvfs `venc_step0/1/2` = 0x230/0x1c2/0x16c = 560/450/364 MHz [DT]. **Scelta consigliata: 6 = mainpll_d3
(≈364 MHz, PLL principale sempre accesa)** [I: 364 MHz = 1092/3, coincide con `venc_step2`]. Con 0 (26 MHz) l'encoder
funziona comunque, solo più lento [I].

Sequenza (dal codice del mux [S:`drivers/clk/mediatek/clk-mux.c`: scrive clr, poi set, poi `BIT(upd_shift)` in `upd_ofs`]):

```
peek 0x100000D0                 ; leggere: se [2:0] è già != 0 si può saltare
poke 0x100000D8 0x00000007      ; CLR bit [2:0]
poke 0x100000D4 0x00000006      ; SET = 6 (mainpll_d3)
poke 0x10000008 0x00000020      ; CLK_CFG_UPDATE1, bit 5
peek 0x100000D0                 ; atteso [2:0] = 6
```

### 2.4 Power domain VEN (MTCMOS) - `spm_mtcmos_ctrl_ven(STA_POWER_ON)` [S:PG]

Registri [S:PG]:

| nome | PA | bit |
|---|---|---|
| `POWERON_CONFIG_EN` | 0x10006000 | scrivere `(0xB16 << 16) \| 1` = **0x0B160001** prima di ogni PWR_CON (chiave SPM) |
| `PWR_STATUS` | 0x1000616C | VEN = bit 18 |
| `PWR_STATUS_2ND` | 0x10006170 | VEN = bit 18 |
| `VEN_PWR_CON` | 0x10006348 | 0 `PWR_RST_B`, 1 `PWR_ISO`, 2 `PWR_ON`, 3 `PWR_ON_2ND`, 4 `PWR_CLK_DIS`, 8 `SRAM_PDN`, 12 `SRAM_PDN_ACK` |
| `INFRA_TOPAXI_PROTECTEN_1` | 0x10001250 | stato protezione bus |
| `INFRA_TOPAXI_PROTECTEN_1_SET` | 0x100012A8 | |
| `INFRA_TOPAXI_PROTECTEN_1_CLR` | 0x100012AC | VEN: step1 = bit 31, step2 = bit 19 |
| `INFRA_TOPAXI_PROTECTEN_STA1_1` | 0x10001258 | ack protezione |

Accensione, nell'ordine esatto del sorgente (ogni passo è un read-modify-write di `VEN_PWR_CON`):

1. `POWERON_CONFIG_EN = 0x0B160001`
2. `VEN_PWR_CON |= PWR_ON (0x4)`
3. `VEN_PWR_CON |= PWR_ON_2ND (0x8)`
4. attendere `PWR_STATUS` bit 18 = 1 **e** `PWR_STATUS_2ND` bit 18 = 1
5. `VEN_PWR_CON &= ~PWR_CLK_DIS (0x10)`
6. `VEN_PWR_CON &= ~PWR_ISO (0x2)`
7. `VEN_PWR_CON |= PWR_RST_B (0x1)`
8. `VEN_PWR_CON &= ~SRAM_PDN (0x100)`
9. attendere `VEN_PWR_CON` bit 12 (`VEN_SRAM_PDN_ACK_BIT0`) = 0
10. `INFRA_TOPAXI_PROTECTEN_1_CLR = 1<<19` (rilascio step 2)
11. `INFRA_TOPAXI_PROTECTEN_1_CLR = 1<<31` (rilascio step 1). Il sorgente non controlla l'ack dopo il rilascio.

Spegnimento (ordine inverso, per completezza [S:PG]): SET bit 31 e attesa `STA1_1` bit 31; SET bit 19 e attesa bit 19;
`SRAM_PDN=1` e attesa ack bit 12 = 1; `ISO=1`; `CLK_DIS=1`; `RST_B=0`; `PWR_ON=0`; `PWR_ON_2ND=0`; attesa bit 18 = 0
in entrambi gli status.

Valori attesi [I]: da spento `VEN_PWR_CON` vale tipicamente 0x00001112 (ISO, CLK_DIS, SRAM_PDN, ack); da acceso
**0x0000000D** (RST_B, ON, ON_2ND). Calcolare sempre a partire dal valore letto.

### 2.5 Clock gate VENC_GCON (0x17000000, dentro il dominio VEN)

**Non leggere 0x17000000 finché VEN non è acceso**: è un registro del dominio VEN [I: il nodo sta in 0x17000000 come il
resto di VENCSYS]. Un accesso APB a un dominio spento o senza clock su MediaTek di solito blocca il bus (telefono
appeso), non dà un errore [I].

Gate [S:CLK `venc_global_con_clks` + binding]:

| ID DT | nome | bit |
|---|---|---|
| 1 | `venc_larb` | 0 |
| 2 | `venc_venc` (usato anche da larb7 come "venc-set1") | 4 |
| 3 | `venc_jpgenc` (il clock "jpgenc", anche "venc-set2" di larb7) | 8 |
| 4 | `venc_gals` | 28 |

Registri: `sta_ofs` 0x0, `set_ofs` 0x4, `clr_ofs` 0x8; ops `mtk_clk_gate_ops_setclr_inv_dummy` [S:CLK]:
logica **invertita**, bit = 1 → clock acceso; `enable` = read-modify-write con bit a 1 **sull'offset 0x0**
(`regmap_update_bits(sta_ofs)`); `disable` non fa niente (dummy: Linux non spegne mai questi gate).

```
peek 0x17000000
poke 0x17000000 (valore | 0x10000111)   ; come fa il sorgente (RMW su 0x0)
; in alternativa [I]: poke 0x17000004 0x10000111 (registro SET)
peek 0x17000000                          ; attesi bit 0,4,8,28 = 1
```

### 2.6 Riprogrammazione di larb7 dopo l'accensione (quello che fa la callback SMI)

Dopo un'accensione da zero i registri del larb tornano ai valori di reset [I]. Linux riscrive [S:SMI smi_conf.h `smi_larb7_init_pair`]:

| registro | PA | valore |
|---|---|---|
| `SMI_LARB_OSTDL_PORT(9)` | 0x17010224 | 0x5 |
| `SMI_LARB_OSTDL_PORT(10)` | 0x17010228 | 0x3 |
| `SMI_LARB_OSTDL_PORT(11)` | 0x1701022C | 0x1 |
| `SMI_LARB_OSTDL_PORT(12)` | 0x17010230 | 0x5 |

(`SMI_LARB_OSTDL_PORT(p) = 0x200 + 4p` [S:SMI smi_reg.h].) Inoltre `smi_larb_port_set()` fa `NON_SEC_CON(p) |= 0x8`
(throttle di banda) su tutte le porte 0..12 di larb7 (`smi_larb_bw_thrt_en_port[7] = {0, 13}`) [S:SMI]. Per una prima
prova è facoltativo [I]; se un valore di reset dell'OSTD fosse 0 il master non potrebbe avere richieste pendenti e resterebbe fermo, quindi
gli OSTD conviene scriverli [I].

### 2.7 Come verificare che il blocco è alimentato prima di toccare 0x17030000

Ordine sicuro (ogni passo legge solo cose già alimentate):

1. `peek 0x1000616C`, `peek 0x10006170`: bit 18 (VEN) e bit 21 (DIS) = 1.
2. `peek 0x10006348`: bit 0 = 1, bit 1 = 0, bit 4 = 0, bit 8 = 0, bit 12 = 0 (atteso 0x0000000D [I]).
3. `peek 0x10001250`: bit 19 e 31 = 0 (protezione bus rilasciata) [S:PG per i bit; [I] usare lo stato `PROTECTEN_1` come controllo].
4. `peek 0x17000000`: bit 0, 4, 8, 28 = 1.
5. Solo ora: `peek 0x17030100 0x87` (dump da 0x100 a 0x318, come `jpeg_drv_enc_dump_reg`, `JPEG_ENC_REG_COUNT = 0x31C` [S:V2]).
6. Test di vita usato dal driver V2 (`jpeg_drv_enc_verify_state_and_reset`) [S:V2]: dopo il reset (RSTB 0,0,1,1) leggere
   `ULTRA_THRES` (0x318) e poi `DMA_ADDR0` (0x124). **Se `DMA_ADDR0` vale 0xFFFFFFFF**, l'APB del jpgenc non risponde
   ("JPGENC APB R/W issue"): il driver spegne, legge `ULTRA_THRES` e riaccende. Per noi vuol dire clock o power sbagliati.
7. Lettura-scrittura: `poke 0x17030170 0x12340000` + `peek 0x17030170` (registro indirizzo luma, innocuo).

## 3. Larb7 in bypass (indirizzi fisici) per le porte jpgenc

Registro per porta [S:M4U pseudo_m4u.h]: `SMI_LARB_NON_SEC_CONx(p) = 0x380 + 4p`, con:

- bit 0 `F_SMI_MMU_EN`: 1 = l'indirizzo passa da M4U (IOVA), 0 = bypass;
- bit [15:8] `F_SMI_ADDR_BIT32`: bit alti dell'indirizzo (in modalità virtuale `bit32<<8|bit32<<10|bit32<<12|bit32<<14`);
- bit 1 (|0x2, "cmd group", solo larb0/1) e bit 3 (|0x8, throttle) [S:SMI `smi_larb_port_set`];
- bit [19:16]: sysram, solo mt6885/6893 [S:SMI `smi_sysram_enable`].

Il bypass come lo fa `pseudo_config_port(Virtuality=0)` [S:M4U pseudo_m4u_v2.c]:

```
value = old & ~F_SMI_ADDR_BIT32 & ~F_SMI_MMU_EN     ; cioè old & ~0x0000FF01
```

Il percorso Linux (utente) rifiuta il bypass (`"cannot bypass iommu"`), ma per il kernel è ammesso [S:M4U].

Per le nostre porte:

| porta | PA del registro | operazione |
|---|---|---|
| 9 Y_RDMA | 0x170103A4 | `&= ~0xFF01` |
| 10 C_RDMA | 0x170103A8 | `&= ~0xFF01` |
| 11 Q_TABLE | 0x170103AC | `&= ~0xFF01` |
| 12 BSDMA | 0x170103B0 | `&= ~0xFF01` |

```
peek 0x170103A4 4        ; valori attuali (dopo un'accensione da zero probabilmente 0 = già in bypass [I])
poke 0x170103A4 (v9  & ~0xFF01)
poke 0x170103A8 (v10 & ~0xFF01)
poke 0x170103AC (v11 & ~0xFF01)
poke 0x170103B0 (v12 & ~0xFF01)
peek 0x170103A4 4        ; bit 0 = 0 su tutte e quattro
```

Esiste anche `SMI_LARB_SEC_CONx(p) = 0xf80 + 4p` (bit 0 MMU_EN sicuro, bit 1 SEC_EN, [11:8] dominio) [S:M4U];
è accessibile solo dal mondo sicuro [I] e non va toccato. Se una porta fosse marcata sicura dal TEE, il bypass non
funzionerebbe [I] (improbabile per jpgenc senza percorso video sicuro).

Vincoli del bypass [I]:

- i registri indirizzo del jpgenc sono a 32 bit e il bypass azzera i bit 32+: **usare solo PA < 4 GiB** (la DRAM parte da
  0x40000000, quindi 3 GiB utilizzabili);
- il jpgenc **non è cache-coherent**: pulire la D-cache (clean) sul sorgente prima dello start e invalidare la
  destinazione prima di leggerla dalla CPU;
- evitare regioni protette da EMI MPU / carve-out TEE.

## 4. Registri del codificatore (base 0x17030000)

### 4.1 Mappa

Offset identici in [S:ENC mtk_jpeg_enc_reg.h], [S:V2 jpeg_drv_reg.h] e [UP]:

| off | nome | uso nella codifica | fonte |
|---|---|---|---|
| 0x100 | `RSTB` | bit 0: reset attivo basso. Reset = scrivere 0 poi 1 | S:ENC/V2 |
| 0x104 | `CTRL` | controllo, vedi 4.2 | S:ENC/V2 |
| 0x108 | `QUALITY` | bit [15:0] = indice di qualità (vedi 4.3); il driver conserva [31:16] | S:ENC |
| 0x10C | `BLK_NUM` | numero totale di blocchi 8x8 (Y+Cb+Cr) **meno 1** | S:CORE/UP |
| 0x110 | `BLK_CNT` | contatore blocchi (sola lettura, avanzamento) | S nome; [I] semantica |
| 0x11C | `INT_STS` | stato interrupt; si azzera scrivendo 0 | S:ENC |
| 0x120 | `DST_ADDR0` | indirizzo del buffer di uscita, `& ~0xF` | S:ENC |
| 0x124 | `DMA_ADDR0` | puntatore di scrittura corrente/finale del bitstream | S:ENC |
| 0x128 | `STALL_ADDR0` | limite del buffer `(dst + size) & ~0xF` | S:ENC |
| 0x138 | `OFFSET_ADDR` | offset iniziale di scrittura rispetto a DST_ADDR0, `& ~0xF` | S:ENC |
| 0x13C | `CURR_DMA_ADDR` | (solo V2) | S:V2 |
| 0x150 | `RST_MCU_NUM` | intervallo di restart in MCU | S:ENC |
| 0x154 | `IMG_SIZE` | `(width << 16) \| height` | S:ENC |
| 0x158 | `GULTRA_TRESH` | soglia ultra (non usato) | S:V2 |
| 0x160 | `DEBUG_INFO0` | bit 13 = GMC idle (usato dal warm reset) | S:V2 |
| 0x164 | `DEBUG_INFO1` | debug | S |
| 0x168 | `TOTAL_CYCLE` | cicli della codifica | S:V2 |
| 0x16C | `BYTE_OFFSET_MASK` | 4 bit bassi dell'indirizzo di uscita (`dst & 0xF`) | S:ENC |
| 0x170 | `SRC_LUMA_ADDR` | sorgente Y (o YUYV interleaved) | S:ENC |
| 0x174 | `SRC_CHROMA_ADDR` | sorgente CbCr (NV12/NV21) | S:ENC |
| 0x178 | `STRIDE` | "memory stride" = byte per riga in memoria | S:ENC |
| 0x17C | `IMG_STRIDE` | "image stride" = larghezza in byte arrotondata | S:ENC |
| 0x208 | `MEM_CYCLE` | (solo V2) | S:V2 |
| 0x300 | `DCM_CTRL` | clock gating dinamico (non usato) | S:ENC |
| 0x304..0x310 | `SMI_DEBUG0..3` | debug lato SMI | S:V2 |
| 0x314 | `CODEC_SEL` | il reset lo scrive sempre a 0 | S:ENC |
| 0x318 | `ULTRA_THRES` | soglia ultra (letto nel test APB) | S:V2 |
| 0x800 | `PASS2_RSTB` | (solo V2, non usato) | S:V2 |
| 0x584..0x594 | `*_EXT` (34 bit) | **non** su MT6781 (solo upstream mt8195) | UP |

### 4.2 `CTRL` (0x104)

| bit | maschera | nome | uso |
|---|---|---|---|
| 0 | 0x1 | `ENABLE` | start (impostato con INT_EN) [S:ENC] |
| 1 | 0x2 | `DIS_GMC` | definito, "not support" [S:V2] |
| 2 | 0x4 | `INT_EN` | abilita l'interrupt [S:ENC] |
| 4:3 | 0x18 | `YUV_FORMAT` | 0 YUYV, 1 YVYU, 2 NV12, 3 NV21 [S:ENC/CORE] |
| 5 | 0x20 | `FILE_FORMAT` | 0 = "JPG mode", 1 = "JFIF/EXIF mode" [S:V2 commento] |
| 7 | 0x80 | `GRAY_EN` | definito, mai usato [S:V2]; scala di grigi [I] |
| 9 | 0x200 | `ULTRA_HIGH_EN` | definito, mai usato [S:V2] |
| 10 | 0x400 | `RESTART_EN` | 1 se `RST_MCU_NUM != 0` [S:ENC] |
| 14:12 | 0x7000 | `BURST_TYPE` | definito, mai usato [S:V2] |
| 16 | 0x10000 | `SELF_INIT` | definito, mai usato [S:V2] |
| 20 | 0x100000 | `RDMA_PADDING_EN` | **lo start del driver MT6781 lo imposta** [S:ENC] (assente in V2 e [UP]) |
| 29 | 0x20000000 | `RDMA_RIGHT_PADDING_EN` | lo start MT6781 lo imposta [S:ENC] |
| 30 | 0x40000000 | `RDMA_PADDING_0_EN` | lo start MT6781 lo **azzera** [S:ENC] |

Senso dei bit di padding [I]: riempire i bordi destro e inferiore fino a multipli di MCU ripetendo l'ultimo pixel (bit 30 = 0)
invece di zeri. Con 256x256 (multiplo di 16) non dovrebbero avere effetto.

Start del driver MT6781 [S:ENC `mtk_jpeg_enc_start`]:
`CTRL = (CTRL | INT_EN | ENABLE | (1<<20) | (1<<29)) & ~(1<<30)`.

### 4.3 Qualità e tabelle di quantizzazione

Il JPGENC **non ha tabelle di quantizzazione programmabili** nei driver: si sceglie una di 15 tabelle interne con un
indice in `QUALITY[15:0]` [S:ENC `mtk_jpeg_enc_set_quality`, S:CORE enum]. Nessuno dei tre driver scrive un indirizzo di
tabella Q, eppure esiste la porta DMA `JPGENC_Q_TABLE` (larb7/11). Upstream c'è solo `Q_TBL_ADDR_EXT` (0x58C, 34 bit,
mt8195). Quindi [I]: le tabelle stanno in ROM/SRAM interna e la porta QTBL forse è usata internamente; la teniamo in
bypass come le altre. **Da verificare**: dopo la prima codifica, controllare che il DQT nell'header abbia valori sensati.

Indici [S:CORE `enum JPEG_ENCODE_QUALITY_ENUM`, identici a UP]:

| qualità | indice | | qualità | indice |
|---|---|---|---|---|
| Q34 | 0xC | | Q80 | 0x1 |
| Q39 | 0x4 | | Q82 | 0xF |
| Q48 | 0x8 | | Q84 | 0x6 |
| Q60 | 0x0 | | Q87 | 0xB |
| Q64 | 0xE | | **Q90** | **0x2** |
| Q68 | 0x5 | | Q92 | 0x7 |
| Q74 | 0xA | | Q95 | 0x3 |
| | | | Q97 | 0x10 |

Mappatura del driver MT6781 da una qualità 0..100 [S:CORE `mtk_jpeg_set_param`]: ≥97→Q97, ≥95→Q95, ≥92→Q92, ≥90→Q90,
≥87→Q87, ≥84→Q84, ≥80→Q80, ≥74→Q74, ≥64→Q64, ≥60→Q60, altrimenti Q48 (Q34/39/68/82 non vengono mai scelti).
Upstream sceglie invece la prima voce con `q <= quality_param` [UP].

**Discrepanza**: il driver legacy V2 rifiuta 0x8 e 0xC (`"set quality failed"`) e numera Q48 = 0x9, Q34 = 0xD, senza Q97
[S:V2 `jpeg_drv_common.h`, `jpeg_drv_enc_set_quality`]. È per IP più vecchi [I]; per MT6781 valgono MT6781/UP.
In ogni caso **0x2 (Q90) è uguale ovunque**.

Huffman: nessun registro, tabelle standard dell'allegato K presumibilmente fisse [I].

### 4.4 Sorgente: formato, stride, indirizzi

Calcolo del driver MT6781 [S:CORE `mtk_jpeg_set_param`, `mtk_jpeg_try_fmt_mplane`] e scrittura [S:ENC]:

```
Is420        = (fmt == NV12 || fmt == NV21)
width_even   = (w + 1) & ~1
pad_w        = align(w, 16)
pad_h        = align(h, Is420 ? 16 : 8)
img_stride   = Is420 ? align(width_even, 16) : align(2*width_even, 32)   ; in byte
mem_stride   = bytesperline del piano 0 (Y o YUYV)
total_encdu  = (pad_w/16) * (pad_h / (Is420 ? 16 : 8)) * (Is420 ? 6 : 4) - 1

IMG_SIZE         = (w << 16) | h          ; w, h veri (crop), non arrotondati
CTRL[4:3]        = fmt
BLK_NUM          = total_encdu
IMG_STRIDE       = img_stride
STRIDE           = mem_stride
SRC_LUMA_ADDR    = indirizzo piano 0
SRC_CHROMA_ADDR  = indirizzo piano 1, oppure (1 solo piano NV12/NV21) luma + align_h * mem_stride
```

- Il piano CbCr usa lo stesso `STRIDE` del piano Y (c'è un solo registro di stride; in `try_fmt` i due piani NV12M hanno lo
  stesso `bytesperline`) [S:CORE].
- Per YUYV/YVYU il piano è unico; `SRC_CHROMA_ADDR` viene comunque scritto con `fb_addr[1]` (irrilevante) [S:ENC].
- Il codice upstream ha la stessa formula di `BLK_NUM` ("Total 8 x 8 block number of luma and chroma. The number of
  blocks is counted from 0") [UP].
- Sottocampionamento: NV12/NV21 → 4:2:0 (MCU 16x16, 6 blocchi), YUYV/YVYU → 4:2:2 (MCU 16x8, 4 blocchi) [S: formula].
  Niente 4:4:4, RGB o I420 a 3 piani: il campo formato ha 2 bit [S:ENC].
- Bug noto nel driver MT6781: la condizione `enc_format == NV12 || enc_format == NV21 && num_planes == 1` (precedenza
  di `&&`) [S:ENC]. Per noi è irrilevante: scriviamo entrambi gli indirizzi esplicitamente.

### 4.5 Destinazione

[S:ENC `mtk_jpeg_enc_set_dst_buf`, S:CORE `mtk_jpeg_set_enc_dst`]:

```
OFFSET_ADDR      = init_offset & ~0xF
BYTE_OFFSET_MASK = offset_mask & 0xF        ; = dst & 0xF
DST_ADDR0        = dst & ~0xF
STALL_ADDR0      = (dst + size) & ~0xF
```

- Driver MT6781: `dst = base_buffer & ~0xF` + `dst_offset` (controllo V4L2 privato `V4L2_CID_JPEG_DST_OFFSET`, scelto
  dall'HAL di MediaTek); `OFFSET_ADDR = 0`; `offset_mask = dst & 0xF`; `size = align(dimensione_piano, 128)` [S:CORE].
  Attenzione: l'arrotondamento a 128 può portare `STALL_ADDR0` oltre la fine reale del buffer.
- Upstream: `OFFSET_ADDR = enable_exif ? 64 KiB : 0` [UP].
- V2: `size >= 624` obbligatorio (`"stall size less than 624"`) [S:V2].
- Per noi: `dst` allineato a 16 byte (meglio 4 KiB), `OFFSET_ADDR = 0`, `BYTE_OFFSET_MASK = 0`.

### 4.6 Header JFIF/EXIF: cosa scrive l'hardware

Fatti dal sorgente:

- Il driver kernel MT6781 **non antepone niente**: il payload restituito è `DMA_ADDR0 - DST_ADDR0` byte a partire da
  `DST_ADDR0` [S:CORE `mtk_jpeg_irq` → `vb2_set_plane_payload(dst_buf, 0, result_size)`; S:ENC `mtk_jpeg_enc_get_file_size`].
  Nessun codice nel kernel genera SOI/DQT/DHT/SOF/SOS.
- `CTRL[5]`: 0 = "JPG mode", 1 = "JFIF/EXIF mode" [S:V2]. MT6781: impostato da `V4L2_CID_JPEG_ENABLE_EXIF` [S:CORE];
  upstream: impostato se l'applicazione chiede il marker APP1, e in quel caso l'uscita parte 64 KiB più avanti [UP].
- Il commento di `JPEG_ENC_DRV_IN` dice "encWidth/encHeight: HW directly fill to header" [S:V2 jpeg_drv.h]: è
  l'hardware a scrivere larghezza e altezza nell'header (SOF0).

Deduzioni [I] (alta confidenza):

- **Con `CTRL[5] = 0` l'hardware emette un JPEG completo**: SOI, (APP0 JFIF), DQT, SOF0, DHT, SOS, dati entropici, EOI.
  Motivo: upstream consegna il buffer così com'è come `V4L2_PIX_FMT_JPEG` alle applicazioni (GStreamer/Chrome) senza
  sintesi di header nello spazio utente, e il commento V2 sopra lo conferma.
- **Con `CTRL[5] = 1` l'hardware salta l'area iniziale (OFFSET_ADDR / dst_offset) e non scrive il SOI** (forse nemmeno APP0),
  così il software può mettere `FF D8` + APP1 (EXIF) davanti. Altrimenti un APP1 prima del SOI dell'hardware
  produrrebbe un file non valido.
- **Per noi: `CTRL[5] = 0`.** Verifica: i primi 4 byte devono essere `FF D8 FF E0` (`peek` restituisce 0xE0FFD8FF in
  little-endian) oppure `FF D8 FF DB` se non c'è APP0; gli ultimi 2 byte `FF D9`. Se invece l'uscita inizia con
  dati entropici, l'header va costruito in software (DQT dalla tabella dell'indice scelto: andrebbe ricavata codificando
  una volta in modalità JPG).

### 4.7 Intervallo di restart

`RST_MCU_NUM = N` (MCU tra marker RSTn) e `CTRL[10] = (N != 0)` [S:ENC]. Il DRI nell'header è a 16 bit → N ≤ 65535 [I].
Per la prima prova: 0.

## 5. Avvio, completamento, stato

### 5.1 Sequenza del driver MT6781 (`mtk_jpeg_device_run`) [S:CORE][S:ENC]

1. `mtk_jpeg_enc_reset`: `RSTB = 0`, `RSTB = 1`, `CODEC_SEL = 0`.
2. `mtk_jpeg_enc_set_config`:
   `IMG_SIZE`; `CTRL[4:3]` (RMW); `BLK_NUM`; `IMG_STRIDE`; `STRIDE`; `SRC_LUMA_ADDR`; `SRC_CHROMA_ADDR`;
   `OFFSET_ADDR`; `BYTE_OFFSET_MASK`; `DST_ADDR0`; `STALL_ADDR0`; `QUALITY` (RMW [15:0]);
   `CTRL[10]` + `RST_MCU_NUM`; `CTRL[5] = 0` e poi, se EXIF, `CTRL[5] = 1`.
3. `mtk_jpeg_enc_start`: `CTRL |= INT_EN|ENABLE|bit20|bit29`, `&= ~bit30`.
4. Interrupt → `mtk_jpeg_enc_get_int_status`: `sts = INT_STS & 0x13`; se diverso da 0, `INT_STS = 0` (azzeramento).
5. `mtk_jpeg_enc_enum_result`: dimensione = `DMA_ADDR0 - DST_ADDR0`; risultato DONE/STALL/VCODEC/sconosciuto.
6. Se il risultato è ≥ STALL: `mtk_jpeg_enc_reset`.

### 5.2 Bit di `INT_STS` (0x11C) [S:ENC mtk_jpeg_enc_reg.h, S:V2]

| bit | maschera | significato |
|---|---|---|
| 0 | 0x01 | `DONE`: codifica terminata, bitstream completo |
| 1 | 0x02 | `STALL`: il DMA ha raggiunto `STALL_ADDR0` (buffer di uscita pieno); l'encoder si ferma |
| 4 | 0x10 | `VCODEC_IRQ` (il driver lo tratta come errore, risultato 2); interrupt condiviso con il VENC / CODEC_SEL [I] |
| | 0x13 | `MASK_ALLIRQ` |

Senza interrupt (stato 0) dopo il timeout il driver V2 restituisce 3, fa il dump dei registri, chiama
`smi_debug_bus_hang_detect` e il warm reset [S:V2 jpeg_drv.c].

### 5.3 Dimensione prodotta

`size = DMA_ADDR0 - DST_ADDR0` [S:ENC, S:V2, UP]. Con `OFFSET_ADDR = 0` e `dst` allineato è il numero esatto di byte del
file [I: è il payload che V4L2 consegna]. Su varianti a 34 bit upstream `DMA_ADDR0` va moltiplicato per 4 (`<< 2`) [UP],
non su MT6781 [S:ENC].
`TOTAL_CYCLE` (0x168) dà i cicli impiegati [S:V2].

### 5.4 Interrupt GIC

SPI 245 (INTID 277), level-triggered alto [DT]. Il driver V2 lo registra con `IRQF_TRIGGER_LOW` [S:V2]: è roba vecchia,
fa fede il DT [I]. La linea si abbassa azzerando `INT_STS` [I]. Per le prove con peek/poke basta il polling di `INT_STS`
con la SPI mascherata nel GIC. Non è dimostrato che `INT_STS` si alzi con `INT_EN = 0`: impostare comunque `INT_EN` [I].

### 5.5 Recupero da errore: warm reset [S:V2 `jpeg_drv_enc_warm_reset`]

1. `CTRL &= ~ENABLE`; `CTRL |= ENABLE`.
2. attendere `DEBUG_INFO0` bit 13 (GMC idle), timeout ~0xFFFFF letture.
3. `RSTB &= ~1`; `RSTB |= 1`; `CODEC_SEL = 0`.

## 6. Esempio completo: 256x256 NV12, qualità 90, con peek/poke

### 6.1 Parametri calcolati

| grandezza | valore |
|---|---|
| `IMG_SIZE` | (256<<16)\|256 = **0x01000100** |
| pad_w, pad_h | 256, 256 |
| `BLK_NUM` | 16·16·6 − 1 = 1535 = **0x5FF** |
| `IMG_STRIDE` | align(256,16) = **0x100** |
| `STRIDE` | 256 = **0x100** |
| `CTRL` configurazione | NV12 (2<<3) = **0x00000010** (EXIF 0, restart 0) |
| `CTRL` start | 0x10 \| 0x4 \| 0x1 \| 0x100000 \| 0x20000000 = **0x20100015** |
| `QUALITY` | **0x2** (Q90) |
| luma | 65536 byte |
| croma | 32768 byte |
| uscita | 256 KiB è abbondante (un 256x256 a Q90 sta tipicamente in 10-40 KiB [I]); il caso peggiore è comunque sotto i 100 KiB [I] |

### 6.2 Memoria (indirizzi di esempio: sceglierne di liberi)

Servono 64 KiB + 32 KiB + 256 KiB contigui fisicamente, sotto 4 GiB, fuori da carve-out TEE e dal framebuffer.
Esempio con base `B` allineata a 64 KiB:

```
PA_Y  = B + 0x00000     (65536 B)
PA_C  = B + 0x10000     (32768 B)
PA_BS = B + 0x20000     (0x40000 B = 256 KiB) ; STALL = B + 0x60000
```

Contenuto sorgente: l'encoder accetta qualsiasi byte, quindi va bene anche memoria "sporca" per la prima prova
(il JPEG sarà valido ma rumoroso) [I]. Per un'immagine riconoscibile: Y = 0x80 ovunque e CbCr = 0x80 dà grigio uniforme
(file molto piccolo); per un gradiente, riempirlo col kernel. Riempire 96 KiB con `poke` sono 24576 comandi: meglio una
funzione di fill nel kernel. Se la scrittura passa da una mappatura cacheable, fare clean della D-cache prima dello start [I].

### 6.3 Sequenza (il simbolo `->` indica il valore atteso dalla lettura)

```
# ---------- A. prerequisiti (sola lettura, tutto già alimentato) ----------
peek 0x1000616C                       -> bit21 = 1 (DIS); bit18 = VEN (0 o 1)
peek 0x10006170                       -> bit21 = 1
peek 0x14000100                       -> bit11,17,22,24 = 0 (gate SMI MMSYS accesi)

# ---------- B. mux venc_sel = mainpll_d3 ----------
peek 0x100000D0
poke 0x100000D8 0x00000007
poke 0x100000D4 0x00000006
poke 0x10000008 0x00000020
peek 0x100000D0                       -> [2:0] = 6

# ---------- C. MTCMOS VEN (saltare se bit18 era già 1 e VEN_PWR_CON = 0xD) ----------
poke 0x10006000 0x0B160001            # chiave SPM
peek 0x10006348                       -> es. 0x00001112 (spento) [I]; chiamiamolo V
poke 0x10006348 V|0x4                 # PWR_ON
poke 0x10006348 V|0x4|0x8             # PWR_ON_2ND
peek 0x1000616C                       -> ripetere finché bit18 = 1
peek 0x10006170                       -> ripetere finché bit18 = 1
poke 0x10006348 (prec & ~0x10)        # CLK_DIS = 0
poke 0x10006348 (prec & ~0x02)        # ISO = 0
poke 0x10006348 (prec | 0x01)         # RST_B = 1
poke 0x10006348 (prec & ~0x100)       # SRAM_PDN = 0
peek 0x10006348                       -> ripetere finché bit12 = 0; atteso 0x0000000D
poke 0x100012AC 0x00080000            # rilascio protezione bus step2 (bit19)
poke 0x100012AC 0x80000000            # rilascio protezione bus step1 (bit31)
peek 0x10001250                       -> bit19 = 0, bit31 = 0

# ---------- D. clock VENCSYS (solo ora si può leggere 0x170xxxxx) ----------
peek 0x17000000                       -> W
poke 0x17000000 W|0x10000111          # larb, venc, jpgenc, gals
peek 0x17000000                       -> bit 0,4,8,28 = 1

# ---------- E. larb7: OSTD + bypass M4U delle porte 9..12 ----------
poke 0x17010224 0x5
poke 0x17010228 0x3
poke 0x1701022C 0x1
poke 0x17010230 0x5
peek 0x170103A4 4                     -> v9 v10 v11 v12
poke 0x170103A4 (v9  & ~0xFF01)
poke 0x170103A8 (v10 & ~0xFF01)
poke 0x170103AC (v11 & ~0xFF01)
poke 0x170103B0 (v12 & ~0xFF01)
peek 0x170103A4 4                     -> bit0 = 0 su tutte

# ---------- F. reset jpgenc + test APB ----------
poke 0x17030100 0x0
poke 0x17030100 0x0
poke 0x17030100 0x1
poke 0x17030100 0x1
peek 0x17030318                       # ULTRA_THRES (lettura richiesta dal workaround V2)
peek 0x17030124                       -> NON 0xFFFFFFFF (altrimenti clock/power sbagliati)
poke 0x17030314 0x0                   # CODEC_SEL

# ---------- G. configurazione ----------
poke 0x17030154 0x01000100            # IMG_SIZE 256x256
poke 0x17030104 0x00000010            # CTRL: NV12, JPG mode, no restart, no int/enable
poke 0x1703010C 0x000005FF            # BLK_NUM
poke 0x1703017C 0x00000100            # IMG_STRIDE
poke 0x17030178 0x00000100            # STRIDE (memoria)
poke 0x17030170 PA_Y                  # SRC_LUMA_ADDR
poke 0x17030174 PA_C                  # SRC_CHROMA_ADDR
poke 0x17030138 0x0                   # OFFSET_ADDR
poke 0x1703016C 0x0                   # BYTE_OFFSET_MASK (PA_BS allineato)
poke 0x17030120 PA_BS                 # DST_ADDR0
poke 0x17030128 PA_BS+0x40000         # STALL_ADDR0
peek 0x17030108                       -> Q ; poi:
poke 0x17030108 (Q & 0xFFFF0000)|0x2  # QUALITY = Q90
poke 0x17030150 0x0                   # RST_MCU_NUM = 0 (CTRL[10] già 0)
poke 0x1703011C 0x0                   # azzera INT_STS
peek 0x17030100 0x87                  # (facoltativo) dump 0x100..0x318 prima dello start

# ---------- H. start ----------
poke 0x17030104 0x20100015            # INT_EN|ENABLE|RDMA_PADDING|RIGHT_PADDING, NV12

# ---------- I. attesa ----------
peek 0x1703011C                       -> ripetere finché != 0; atteso 0x00000001 (DONE)
peek 0x17030124                       -> E = DMA_ADDR0 ; dimensione = E - PA_BS
peek 0x17030168                       -> TOTAL_CYCLE
poke 0x1703011C 0x0                   # azzera lo stato (abbassa la linea IRQ [I])

# ---------- J. verifica dell'uscita (invalidare la cache se si legge dalla CPU) ----------
peek PA_BS 4                          -> 0xE0FFD8FF ... (FF D8 FF E0 'J' 'F' 'I' 'F') [I]
peek (E-4) 1                          -> byte alti = D9 FF ... (fine con FF D9) [I]
```

Note:

- In G i `poke` a `CTRL` sono assoluti perché partiamo dal reset; il driver usa read-modify-write [S:ENC].
  Il valore di reset di `CTRL` non è documentato [I]: se il `peek` dopo il reset non è 0, conviene RMW anche qui.
- Il risultato si scarica con `peek PA_BS (size+3)/4` e si salva come `.jpg`.

### 6.4 Diagnosi se qualcosa non va

| sintomo | causa probabile | controllo |
|---|---|---|
| il `peek` a 0x1703xxxx blocca il telefono | VEN spento o clock VENC spento | passi 2.7 nell'ordine; mai leggere 0x170xxxxx prima di C/D |
| `DMA_ADDR0` = 0xFFFFFFFF dopo il reset | "APB R/W issue" [S:V2] | spegnere e riaccendere VEN, poi rifare D |
| `INT_STS` resta 0, `BLK_CNT` fermo a 0 | lettura sorgente bloccata: porta ancora in M4U (fault di traduzione) o SMI/larb non configurati | `peek 0x170103A4 4` bit 0; `peek 0x17010000` (`SMI_LARB_STAT`, ≠0 = occupato [S:SMI uso in `smi_debug_bus_hang_detect`]); `peek 0x17030304 4` (SMI_DEBUG) |
| `INT_STS` = 0x2 | buffer di uscita troppo piccolo (STALL) | aumentare la dimensione; `DMA_ADDR0` ≈ `STALL_ADDR0` |
| `INT_STS` = 0x10 | IRQ del codec video / CODEC_SEL | verificare `CODEC_SEL = 0` [I] |
| file senza `FF D8` iniziale | l'hardware non scrive l'header in questa modalità | vedere 4.6, costruire l'header in software |
| immagine con colori scambiati | NV12/NV21 invertiti | `CTRL[4:3]` 2 ↔ 3 |
| immagine "a strisce" | stride sbagliato | `STRIDE` = byte per riga reali, `IMG_STRIDE` = align(w,16) |

## 7. Limiti

| voce | valore | fonte |
|---|---|---|
| formati sorgente | YUYV, YVYU (4:2:2 interleaved, 1 piano); NV12, NV21 (4:2:0, Y + CbCr interleaved, 1 o 2 piani) | S:ENC/CORE |
| non supportati | RGB, I420/YV12 a 3 piani, 4:4:4, 4:0:0 dichiarato (bit `GRAY_EN` presente ma mai usato) | S:CORE (formati elencati), [I] su GRAY |
| dimensioni | `IMG_SIZE` ha 16 bit per lato: max 65535 x 65535 (V2 rifiuta valori > 0xFFFF); V4L2 min 32x32, `MTK_JPEG_MAX_WIDTH/HEIGHT = 65536` | S:V2, S:CORE |
| allineamento dimensioni in V4L2 | NV12/NV21: larghezza allineata a 16 e altezza a 16; YUYV: `bytesperline` = align(2·w_pari, 32), altezza allineata a 8 | S:CORE `try_fmt` |
| `IMG_STRIDE`, `STRIDE` | multipli di 16 (V2 rifiuta `& 0xF`); per YUYV/YVYU multipli di 32 (V2 controlla `& 0x1f`) | S:V2 |
| indirizzi luma/croma | allineati a 16 byte (V2 avvisa se `& 0x0F`) | S:V2 |
| uscita | `DST_ADDR0`/`STALL_ADDR0` a 16 byte (i 4 bit bassi in `BYTE_OFFSET_MASK`); dimensione ≥ 624 byte (V2); MT6781 arrotonda la dimensione a 128 | S:ENC/V2/CORE |
| indirizzi | registri a 32 bit, nessun `*_EXT` su MT6781 → PA < 4 GiB in bypass | S:ENC; [I] su PA |
| qualità | 15 livelli fissi (tabella 4.3), nessuna DQT personalizzata | S:CORE |
| restart | `RST_MCU_NUM` in MCU; ≤ 65535 per il DRI | S:ENC; [I] limite |
| EXIF | solo come area riservata (offset) + bit `FILE_FORMAT`; il contenuto APP1 lo scrive il software | S:CORE/UP; [I] dettagli |
| istanze | 1 core (`ncore`, `reg_base[0]`); `MTK_JPEG_MAX_NCORE = 2` nel codice ma il DT ha un solo jpgenc | S:CORE, DT |
| banda | `cshot-spec = 0x170` (368, "MP x fps" per la QoS) | DT, S:CORE (`cshot_spec_dts`) |
| frequenza | `venc_sel` fino a 560 MHz (mmpll), 450, 364 (step mmdvfs) | DT |

## 8. Punti aperti da verificare sul telefono

1. Header: con `CTRL[5] = 0` l'uscita inizia con `FF D8`? (4.6)
2. Valore di reset di `SMI_LARB_NON_SEC_CON` delle porte 9..12 dopo l'accensione di VEN (atteso 0 = bypass).
3. Valori di reset degli OSTD di larb7 (se ≠ 0 i poke OSTD del passo E sono superflui).
4. Registro SET di VENC_GCON (0x17000004) equivalente all'RMW su 0x0?
5. Il bit `GRAY_EN` (0x80) produce davvero un JPEG a 1 componente?
6. Dove legge la porta Q_TABLE (larb7/11), visto che nessun driver scrive un indirizzo di tabella.
7. Se VEN era già acceso da LK/iBoot, i registri larb7 potrebbero avere `MMU_EN = 1`: la sezione 3 lo copre comunque.
