# KAGURA-6502 ピン割当表 v0.2（Tang Nano 9K）

**状態:** ピン割当は一次資料と照合済み（Confirmed）。Gowin の P&R でピン制約を満たすことも確認済み（Provisionally Validated）。**実機では未確認**。
**対象ボード:** Sipeed Tang Nano 9K（GW1NR-LV9QN88PC6/I5, device version C）
**制約ファイル:** [fpga/constraints/tn9k_kagura6502.cst](../fpga/constraints/tn9k_kagura6502.cst)

> ⚠ **Tang Nano 9K のオンボード TF（microSD）スロットは A8–A11 と配線を共有している。現行のピン割当では TF カードを使わない。カードを挿すと CPU のアドレスバスと衝突する。**

---

## 1. 根拠資料（一次資料）

| 資料 | 確認した内容 |
|---|---|
| Gowin IDE 1.9.12.04 `data/device/GW1NR-9/QFN88P.json` | 各ピンのバンク、兼用機能（JTAG / SSPI / CPU / PLL 入力など） |
| Sipeed `Tang_nano_9K_3674_schematics.pdf`（Rev 2024-03-11） | ヘッダ J5/J6 の配線、オンボード周辺との共有、VCCIO、電源系統 |
| WDC `w65c02s.pdf` Figure 3-1（埋め込み画像から抽出）、Table 6-2 / 6-3 | DIP-40 のピン番号、DC/AC 特性 |
| Raspberry Pi RP2040 Datasheet（Table 615、PADS_BANK0、電気的特性） | GPIO のリセット時状態（入力 + プルダウン 50〜80 kΩ）、VOH / VOL |
| Seeed XIAO RP2040 Wiki、`Seeed-Studio-XIAO-RP2040-v1.3.pdf` | D 番号と GPIO の対応、3.3 V LDO（RS3236-3.3） |
| Gowin UG289（GPIO）§3.3 | コンフィギュレーション中の GPIO は Hi-Z + 弱プルアップ |
| Gowin DS117 2.9.3E Table 4-1 / 4-12 | 絶対最大定格、LVCMOS33 の VIH(max) = 3.6 V、VOH = VCCO − 0.4 V @ 8 mA |
| Toll TMI7003C V1.5 | 3 チャンネル 1.5 A 降圧 DC-DC、VFB 0.588〜0.612 V |

### 1.1 バンク電圧と電源系統（回路図より）

| ネット | 電圧 | 供給元 | 用途 |
|---|---|---|---|
| VCCO0_1_2_3V3 | 3.3 V | TMI7003C の 1 チャンネル（680 k / 150 k） | FPGA Bank 0/1/2 の I/O |
| +3V3 | 3.3 V | TMI7003C の**別の**チャンネル（680 k / 150 k） | ヘッダ J6-24、BL702 など。**CPU の VDD はここから取る** |
| VCCO3_1V8 | 1.8 V | TMI7003C の 3 つ目のチャンネル（300 k / 150 k） | FPGA Bank 3（LED、ボタン、JTAG、J6-2〜9） |
| +1V2 | 1.2 V | ME6211C12（+3V3 から） | FPGA コア |
| +5V | 5 V | USB-C VBUS → IC3（型番は回路図テキストからは読めず） | ヘッダ J6-18 |


### 1.2 ヘッダで使える I/O の実数

| 区分 | 本数 | 内訳 |
|---|---|---|
| 3.3 V 汎用 I/O | **29** | J5 の 22 本 + J6-1, 10, 11, 19, 20, 21, 22 |
| 1.8 V 汎用 I/O | 8 | J6-2〜9（FPGA 79〜86） |
| HDMI 専用（GPIO には使えない） | 8 | J6-12〜17、J5-23/24（HDMI コネクタと同じネット） |
| 電源 | 3 | J6-18 +5V、J6-23 GND、J6-24 +3V3 |

FPGA ピン 19/20/47/50 はヘッダに出ていない。59〜62 はオンボード SPI Flash、17/18 は BL702 UART に固定されている。

---

## 2. 割当サマリ

| 機能 | 本数 | 電圧 | 場所 |
|---|---|---|---|
| A0–A15 | 16 | 3.3 V | J5-15〜22、J5-1〜4、J6-1/10/11/19 |
| D0–D7 | 8 | 3.3 V | J5-5〜12 |
| RWB | 1 | 3.3 V | J5-13 |
| PHI2（FPGA 出力） | 1 | 3.3 V | J5-14 |
| IRQB（FPGA、0 / Hi-Z） | 1 | 3.3 V | J6-20 |
| **CPU バス小計** | **27** | | |
| XIAO UART TX / RX | 2 | 3.3 V | J6-21 / 22 |
| **3.3 V 合計** | **29 / 29** | | **余りなし** |
| PWM 音声 L / R（デバッグ用。主は HDMI 音声） | 2 | 1.8 V | J6-2 / 3 |
| 予約（未接続） | 1 | 1.8 V | J6-4（§3.1） |
| ユーザーボタン | 1 | 1.8 V | J6-5 |
| デバッグ出力 | 4 | 1.8 V | J6-6〜9 |
| HDMI | 8 | 3.3 V 差動 | オンボード固定 |

**FPGA に接続しない CPU 信号:**

- RDY: プルアップのみ。ウェイトは PHI2 ストレッチで実現する。
- RESB、NMIB: XIAO が駆動する。
- BE、SOB: プルアップで固定。
- SYNC、VPB、MLB、PHI1O、PHI2O: 未接続（NC）。


---

## 3. ヘッダ全ピン表（回路図 3674 と照合済み）

### J5（24 ピン、全て 3.3 V バンク）

| J5 | FPGA | Bank | 基板上の共有先 | 割当 | 方向（FPGA から見て） |
|---|---|---|---|---|---|
| 1 | 38 | 2 | **TF_CS**（10 kΩ プルアップ） | A8 | in |
| 2 | 37 | 2 | **TF_MOSI** | A9 | in |
| 3 | 36 | 2 | **TF_SCLK** | A10 | in |
| 4 | 39 | 2 | **TF_MISO** | A11 | in |
| 5 | 25 | 2 | なし | D0 | io |
| 6 | 26 | 2 | なし | D1 | io |
| 7 | 27 | 2 | なし | D2 | io |
| 8 | 28 | 2 | なし | D3 | io |
| 9 | 29 | 2 | なし | D4 | io |
| 10 | 30 | 2 | なし | D5 | io |
| 11 | 33 | 2 | RGB-LCD DE | D6 | io |
| 12 | 34 | 2 | RGB-LCD VS | D7 | io |
| 13 | 40 | 2 | RGB-LCD HS | RWB | in |
| 14 | 35 | 2 | RGB-LCD CK（GCLKT_4） | PHI2 | out |
| 15 | 41 | 2 | RGB-LCD B7 | A0 | in |
| 16 | 42 | 2 | RGB-LCD B6 | A1 | in |
| 17 | 51 | 1 | RGB-LCD B5（GCLKC_3） | A2 | in |
| 18 | 53 | 1 | RGB-LCD B4（DOUT/WE_N 兼用） | A3 | in |
| 19 | 54 | 1 | RGB-LCD B3（DIN/CLKHOLD_N 兼用） | A4 | in |
| 20 | 55 | 1 | RGB-LCD G7（SSPI_CS_N 兼用） | A5 | in |
| 21 | 56 | 1 | RGB-LCD G6（SO 兼用） | A6 | in |
| 22 | 57 | 1 | RGB-LCD G5（FASTRD_N 兼用） | A7 | in |
| 23 | 68 | 1 | HDMI_CK_N | （HDMI 専用） | — |
| 24 | 69 | 1 | HDMI_CK_P | （HDMI 専用） | — |

### J6（24 ピン）

| J6 | FPGA | Bank / V | 基板上の共有先 | 割当 | 方向 |
|---|---|---|---|---|---|
| 1 | 63 | 1 / 3.3 | RGB-LCD INIT（RPLL_T_IN 兼用） | A12 | in |
| 2 | 86 | 3 / **1.8** | SPI-LCD BL_PWM | AUD_PWM_L（デバッグ・フォールバック用。主は HDMI 音声） | out |
| 3 | 85 | 3 / 1.8 | — | AUD_PWM_R（同上） | out |
| 4 | 84 | 3 / 1.8 | — | **予約**（未接続、FPGA 内部プルダウン） | in |
| 5 | 83 | 3 / 1.8 | — | USER_BTN_N（GND へのスイッチ、内部プルアップ） | in |
| 6–9 | 82–79 | 3 / 1.8 | — | DBG0–3 | out |
| 10 | 77 | 1 / 3.3 | SPI-LCD MO | A13 | in |
| 11 | 76 | 1 / 3.3 | SPI-LCD MCLK | A14 | in |
| 12–17 | 75–70 | 1 | HDMI D2/D1/D0 | （HDMI 専用） | — |
| 18 | — | — | +5V | 電源（§6） | — |
| 19 | 48 | 1 / 3.3 | SPI-LCD CS | A15 | in |
| 20 | 49 | 1 / 3.3 | SPI-LCD RS | IRQB | out（0 / Hi-Z） |
| 21 | 31 | 2 / 3.3 | RGB-LCD INIT | XIAO_TX（FPGA → XIAO） | out |
| 22 | 32 | 2 / 3.3 | RGB-LCD INIT | XIAO_RX（XIAO → FPGA） | in |
| 23 | — | — | GND | GND | — |
| 24 | — | — | +3V3 | CPU VDD、プルアップの供給元 | — |

### 3.1 1.8 V バンク（J6-2〜9）の安全性

| ピン | 接続先 | 外部からかかる電圧 | 判定 |
|---|---|---|---|
| J6-2/3 PWM 音声 | RC ローパスフィルタ（出力のみ） | なし | 安全 |
| J6-4 予約 | 未接続 | なし | 安全 |
| J6-5 ボタン | GND へのスイッチ。プルアップは FPGA 内部だけ | 0 V / 開放 | 安全 |
| J6-6〜9 DBG | ロジックアナライザのプローブ（入力専用） | なし | 安全。**プローブ側から電圧を出さないこと** |
| J6-2 の共有先 BL_PWM | SPI-LCD コネクタ（未使用） | なし | 安全 |

**3.3 V の信号は、1.8 V バンクに直接つながない。**

**将来の拡張候補（今回は実装しない）:** SYNC（CPU 出力、3.3 V）を J6-4 に入れる場合は、レベル変換を挟む（単方向バッファを 1.8 V で動かすか、抵抗分圧）。DS117 2.9.3E の表は LVCMOS18 の VIH(max) を 3.6 V と読める配置になっているが、表のレイアウトが曖昧で版も古い。そのため直結の根拠にはしない。

### 3.2 オンボード固定ピン（キャリア側の配線は不要）

| FPGA | 機能 | 用途 |
|---|---|---|
| 52 | 27 MHz 発振器 | 全クロックの源 |
| 17 / 18 | BL702 USB-UART | Phase 1 の状態フレーム（Tang の USB-C で見られる） |
| 10, 11, 13–16 | LED×6（1.8 V、Low アクティブ） | Phase 1 の状態表示 |
| 3 / 4 | S1 / S2（1.8 V） | 予備 |
| 59–62 | SPI Flash（P25Q32U、32 Mbit） | 将来のストレージ候補 |
| 内蔵 | PSRAM 64 Mbit | ヘッダは消費しない（P&R で SiP 内部パッドへの配置を確認） |

---

## 4. W65C02S 側の接続（DIP-40）

ピン番号は WDC データシートの Figure 3-1（PDF の埋め込み画像を取り出して目視）で確認した。

| CPU ピン | 信号 | 接続先 | 外付け部品 |
|---|---|---|---|
| 1 | VPB | NC | — |
| 2 | RDY | — | **3.3 kΩ プルアップ**（双方向。WAI 実行中は CPU が Low に引く） |
| 3 | PHI1O | NC | — |
| 4 | IRQB | Tang J6-20 | 10 kΩ プルアップ |
| 5 | MLB | NC | — |
| 6 | NMIB | XIAO D1 | **3.3 kΩ プルアップ**（v0.1 の 10 kΩ から変更。理由は phase1-bringup.md §4） |
| 7 | SYNC | NC | — |
| 8 | VDD | Tang J6-24 +3V3 | 100 nF + 10 µF |
| 9–20 | A0–A11 | §3 参照 | — |
| 21 | VSS | GND | — |
| 22–25 | A12–A15 | §3 参照 | — |
| 26–33 | D7–D0 | §3 参照 | — |
| 34 | RWB | Tang J5-13 | — |
| 35 | NC | — | — |
| 36 | BE | VDD | 10 kΩ プルアップ |
| 37 | PHI2 | Tang J5-14 | 10 kΩ プルアップ、33 Ω 直列抵抗のパッドを用意 |
| 38 | SOB | VDD | 10 kΩ プルアップ |
| 39 | PHI2O | NC | — |
| 40 | RESB | XIAO D0 | **10 kΩ プルダウン** |

## 5. XIAO RP2040 側の接続（Seeed Wiki と回路図 v1.3 で確認済み）

| XIAO | GPIO | 機能 | 接続先 |
|---|---|---|---|
| D6 | GPIO0 | UART0 TX | Tang J6-22（XIAO_RX） |
| D7 | GPIO1 | UART0 RX | Tang J6-21（XIAO_TX） |
| D0 | GPIO26 | RESB 駆動 | W65C02S pin 40 |
| D1 | GPIO27 | NMIB（オープンドレイン動作） | W65C02S pin 6 |
| D8 / D9 / D10 / D3 | GPIO2 / 4 / 3 / 29 | SPI0 SCK / MISO / MOSI / CS | microSD（キャリア上、任意） |
| D4 / D5 | GPIO6 / 7 | **USB ホストの D+ / D-**（PIO-USB / Torii-USB） | USB-A レセプタクル |
| D2 | GPIO28 | 予備 | — |
| 5V | — | VBUS | §6 |

## 6. 電源（未解決事項を含む）

| 項目 | 内容 | 状態 |
|---|---|---|
| Tang の 5 V 入力 | USB-C VBUS → IC3 → +5V。IC3 の型番と機能（スイッチ / ダイオード / ヒューズ）は回路図テキストから特定できなかった | **Open**（現物か回路図画像で確認する） |
| Tang の 3.3 V / 1.8 V | TMI7003C（各 1.5 A、3 チャンネル）。+3V3 と VCCO は別チャンネル | Confirmed（回路図） |
| Tang の 1.2 V | ME6211C12 LDO（+3V3 から） | Confirmed（回路図） |
| W65C02S の消費電流 | 3.3 V 時、コア最大 0.3 mA/MHz、テスタ負荷込み最大 1.0 mA/MHz。4.125 MHz で ≤ 4.2 mA | Confirmed（Table 6-2） |
| FPGA の消費電力 | Gowin Power Analyzer の推定値で pincheck 61.8 mW（PSRAM コントローラと VDP は含まない） | 推定値 |
| XIAO RP2040 の消費電流 | Seeed Wiki に記載なし。3.3 V は RS3236-3.3 LDO | **Open**（実測する） |
| XIAO と Tang の USB 同時接続 | XIAO 回路図にショットキーダイオード（NSR0320MW2T1G）があるが、VBUS と 5V ピンのどちら側に入っているか、テキスト抽出では特定できなかった | **Open**。確認できるまでは、**XIAO と Tang の USB を同時につながない**か、キャリア側にダイオード OR を入れる |
| 方針 | Tang の USB を主電源とし、Tang の +5V（J6-18）から XIAO の 5V ピンへショットキーダイオード経由で給電（第一候補） | 設計方針（未検証） |
| USB ホストの VBUS | Tang の +5V からポリスイッチ（またはロードスイッチ）経由で USB-A へ供給。接続機器の消費電流（USB 2.0 の上限は 500 mA）を含めて、Tang 側 USB の給電能力を確認する | **Open** |

## 7. 残課題

| # | 課題 | 状態 |
|---|---|---|
| P-1 | 3.3 V ピンの余りが 0。追加するには、XIAO リンクの 1 線化、1.8 V バンクへの移設（レベル変換）、外付けロジックのいずれかが必要 | Open |
| P-2 | TF スロットと A8–A11 が共有 → README と本書に警告を記載 | 対応済み（文書） |
| P-3 | RGB-LCD / SPI-LCD コネクタのスタブ、PHI2 の tR/tF ≤ 5 ns | Pending Hardware Validation |
| P-4 | USB VBUS 同時接続、IC3 の型番、XIAO 側ダイオードの位置 | Open |
| P-5 | +3V3 と VCCO の電圧差（CPU 制御入力の VIH マージン） | Pending Hardware Validation |
| P-6 | PSRAM コントローラ実装後に資源とタイミングを再検証 | Open（Phase 2） |
| P-7 | Tang Nano 9K の基板リビジョン差（回路図 3672 と 3674） | Open |
