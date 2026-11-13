# KAGURA-6502

KAGURA-6502 は、実物の W65C02S を CPU に使う自作 6502 コンピュータです。専用キャリア基板 Rev.A に Tang Nano 9K と XIAO RP2040 を組み合わせ、HDMI ディスプレイと USB キーボードで使えるスタンドアロンの BASIC 機を目指しています。

![KAGURA-6502 キャリア基板 Rev.A の KiCad 3D レンダリング](board/rev-a-3d.png)

*キャリア基板 Rev.A（72 × 48 mm、4 層）の設計データから生成したイメージ。*

| 構成 | 役割 |
| --- | --- |
| W65C02S | 3.375 MHz で BIOS と KAGURA BASIC を実行 |
| Tang Nano 9K | CPU バス、PSRAM 主記憶、8 KiB 高速 RAM、2 KiB Boot ROM。320×176 のタイル・スプライト映像を HDMI 720p60 で出力し、6ch 音源を HDMI / PWM に出力 |
| XIAO RP2040 | CPU のリセットを監督。キャリア基板の USB-A にキーボードをつなぐための配線を備える |

**RTL v1.0 RC は W65C02S 実機照合待ちです。** 現行版のコンソールは Tang Nano 9K の USB シリアルです。BIOS から KAGURA BASIC を UART でロードします。基板上の USB-A からキー入力を使うには、XIAO の USB ホスト／HID ファームウェアと、FPGA のコンソール入力経路の実装が必要です。

[GitHub Releases](https://github.com/siska-tech/kagura-6502/releases/tag/v1.0-rc.1) で bitstream、ガーバー・ドリル、組み立て指南書をまとめて配布しています。回路図と PCB は [KiCad プロジェクト](board/kagura-6502.kicad_pro) を開いて確認できます。

## KAGURA-6502 の仕様諸元

以下は公開 bitstream `aud_p1024.fs` とキャリア基板 Rev.A の組み合わせです。

| 項目 | 仕様 |
| --- | --- |
| CPU | WDC W65C02S（DIP-40、3.3 V）。PHI2 は公称 3.375 MHz（54 MHz ÷ 16）。PSRAM アクセスの待ち時間に応じて PHI2 を伸長 |
| 主記憶 | Tang Nano 9K 内蔵 PSRAM のうち 4 MiB を使用。CPU の 64 KiB アドレス空間から 4 KiB のバンク窓で全域にアクセス |
| 高速 RAM / ROM | FPGA 内蔵 BSRAM に高速 RAM 8 KiB と BIOS ROM 2 KiB。高速 RAM、ROM、I/O は PHI2 の伸長なし |
| 起動と BASIC | Boot ROM の BIOS が起動し、UART ローダから PSRAM へ BASIC イメージを転送。KAGURA BASIC は Microsoft BASIC 1.1 系の msbasic をベースとし、インタプリタのコードを高速 RAM に置く構成も選択可能 |
| 映像出力 | HDMI 1280×720、60 Hz、ピクセルクロック 74.25 MHz。論理画面は 320×180 の 4 倍拡大で、上下各 2 論理ラインを除く 320×176 が描画領域 |
| 背景 | 8×8 ピクセルのタイル、表示範囲 40×22 タイル。1024 パターン（32 KiB）、4 bpp、16 色×16 パレット（RGB565）。水平・垂直スクロール、ボーダー色、VBLANK 割り込み |
| スプライト | 256 個を登録でき、1 ラインに最大 64 個を表示。8×8 または 16×16 ピクセル、水平・垂直反転 |
| 音源 | 6 ch（矩形波 3、15 ビット LFSR ノイズ 1、波形 2）。波形は各 256 サンプル。48 kHz・符号付き 16 ビットのステレオ PCM を HDMI へ送り、同じ音声を左右の PWM へ出力 |
| コンソール | Tang Nano 9K の USB-C 経由で BL702 USB-UART を使用。115200 baud、8N1 |
| 基板と外部端子 | キャリア基板 Rev.A、約 72×48 mm、4 層。Tang 側の HDMI と USB-C、キャリア側の USB-A、3.3 V SPI 拡張、PWM／デバッグヘッダ、外付けボタン端子 |
| リセットと給電 | XIAO RP2040 が FPGA の UART 状態フレームを監視して CPU の RESB を解除。主電源は Tang の USB-C。XIAO の給電経路は JP1 で選択し、USB-A の VBUS は Tang 側 5 V から PTC 経由で供給 |

### CPU メモリマップ

| CPU アドレス | 割り当て |
| --- | --- |
| `$0000–$1FFF` | 高速 RAM（ゼロページとスタックを含む） |
| `$2000–$BFFF`、`$E000–$F7FF` | PSRAM の直接アクセス領域。BASIC イメージの基準位置は `$9800` |
| `$C000–$CFFF` | PSRAM の 4 KiB バンク窓。バンク番号は `$D005–$D006` |
| `$D000–$D00F` | システム I/O。コンソール UART は `$D00A–$D00B`、PSRAM 書き込み保護は `$D00C` |
| `$D300–$D33F` | VDP。VRAM のアドレス／データ、表示・スクロール・割り込み、波形 2 ch の制御を含む |
| `$D400–$D41F` | 矩形波・ノイズ・マスター音量の制御。`$D41F` への書き込みで設定を一括反映 |
| `$F800–$FFFF` | BIOS ROM と CPU ベクタ |

詳細資料

- [VDP と VRAM](docs/vdp.md) — 画面座標、レジスタ、タイル・スプライトのデータ形式
- [6ch 音源](docs/audio.md) — レジスタ、波形メモリ、ミックスと設定反映
- [BIOS・BASIC と実機起動](docs/boot-and-basic.md) — 起動時の確認、BASIC イメージの生成と UART ローダの仕様
- [ピン割当](docs/pinmap.md) と [基板の組み立て指南書](board/README.md) — コネクタ、給電、初回通電

## 検証状況

この RC の bitstream は [aud_p1024.fs](release/aud_p1024.fs) の 1 点です。[SHA-256](release/SHA256SUMS) を照合できます。RTL の基準はローカル実装コミット `fdbc3a0`、Gowin Commercial 1.9.12.04、place option 2 / route option 1 です。保存済みの [統合シミュレーション](build-logs/audio/sim_system/sys_a1024_aud.log) は PASS、[STA](build-logs/audio/aud_p1024/aud_p1024.tr) は Setup / Hold 違反 0 / 0、[資源レポート](build-logs/audio/aud_p1024/aud_p1024.rpt.txt) は BSRAM 26 / 26 です。実機での CPU 起動、PSRAM、映像・音声は未確認です。波形チャンネルは 256 サンプル固定です。

**Tang Nano 9K の TF スロットにカードを挿さないでください。** CPU アドレス線 A8–A11 と信号を共有します。[ピン割当](docs/pinmap.md) を参照してください。

## 再現

Gowin Commercial 1.9.12.04 と Git Bash で `bash fpga/audio/syn/build_audio.sh aud_p1024` を実行します。生成先は `fpga/audio/syn/impl_aud_p1024/impl/pnr/aud_p1024.fs` です。保存レポートはビルド時に更新されます。

統合シミュレーションは WSL 上の Verilator 5.032 を使用します。ローカルの 6502-sim リポジトリを環境変数 `SIM6502` で指定してください。スクリプトがコミット `f00df4cb3bf639270f294965de1dea98bb55cfce` を参照します。

```sh
bash fpga/tools/build_cc65.sh
bash fpga/basic/sw/build_sw.sh
bash fpga/audio/sim/run_audio.sh all
bash fpga/vdp/sim/run_system.sh sys_a1024_aud
```

第三者ソースの表示とライセンスは [THIRD_PARTY.md](THIRD_PARTY.md) を参照してください。KAGURA-6502 自体のライセンスは未決定です。
