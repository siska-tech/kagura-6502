# Third-party and reference sources

> KAGURA-6502 自体のライセンスは**未決定**。以下は、リポジトリに置いた第三者ソースと、参考にした設計の記録。

## hdl-util/hdmi（Sameer Puri）: 検証の基準としてだけ使う

| 項目 | 内容 |
|---|---|
| 配置 | [third_party/hdl-util-hdmi/](third_party/hdl-util-hdmi/)（**改変なし**） |
| 上流 | https://github.com/hdl-util/hdmi 、revision `83b1c9543a91b776671a44e68e130f81cae437b7` |
| ライセンス | MIT OR Apache-2.0（両方の本文を保持） |
| 取得元 | KAGURA-9 / kagura-hd と同じ固定 revision |
| 完全性 | `manifest.json` の 12 ファイルの SHA256 と一致すること |
| 用途 | **FPGA イメージには入れない。** `fpga/phase3/sim/tb_tmds_equiv.sv` が、`src/tmds_channel.sv`（KAGURA-9 の実機で実績あり）と自作の `k65_tmds_enc` を全シンボルで比較する基準としてだけ使う |

## KAGURA-9（siska-tech、Apache-2.0）: PSRAM コントローラと PHY（取り込み）

| 項目 | 内容 |
|---|---|
| 配置 | [third_party/kagura-9/](third_party/kagura-9/): `kagura_hyperram_ctrl.sv`、`kagura_hyperram_phy_gowin.sv`、`LICENSE` |
| 出所 | ローカルの `../Kagura`（KAGURA-9）、コミット `1ea0519`（`git show HEAD:<path>`）。両ファイルの最終変更は `b11eb9d` |
| 改変 | **なし**（改行コードを LF にしただけ） |
| SHA-256（LF） | ctrl `b310e96e56c4d3b7297b493b2e4b1b4b12f4410f1e07e83190045748881aca77`、phy `d770118d4b257f75a8514e96a5d293716795807c24bc3b2f5e7ceceff1401de8` |
| 実績 | KAGURA-9 の Tang Nano 9K（die 0、54 MHz、CK 67.5°、rd_latency 6）で、実機 memtest 1 GiB・0 error（KAGURA-9 `docs/psram.md`） |
| 用途 | Phase 2 の CPU 主記憶 |

## KAGURA-9 / kagura-hd（siska-tech）: 参考設計

HDMI 送信部 `fpga/rtl/hdmi/k65_hdmi_tx.sv` と `k65_hdmi_phy.v` は**新規に書いたもの**で、ソースはコピーしていない。実機で実績のある KAGURA-9（hdl-util/hdmi 派生）の挙動に、次の点を合わせた。

- データ島の channel 0 bit 3 を常に 1 にする
- 音声サンプルパケットの channel status / parity / B フラグの配置
- AVI / AIF のバイト値（VIC 4、16:9、IT content）
- ACR の N=6144 / CTS=74250
- OSER10 を GSR のみでリセットする方式

SPD は自前で生成している。hdl-util の SPD は文字 `'0'`（0x30）を NUL に置き換える（"KAGURA-6502" が "KAGURA-65␀2" になる）が、KAGURA-6502 ではこの挙動を引き継いでいない。


## mist64/msbasic（Michael Steil ほか）: KAGURA BASIC のインタプリタ本体

| 項目 | 内容 |
|---|---|
| 配置 | [third_party/msbasic/](third_party/msbasic/)（**改変なし**）。KAGURA の構成に必要な 31 ファイルと `README.md` だけを置いた。OEM 固有のファイル（Apple、Commodore など）と、元 ROM のダンプ（`orig/*.bin`）は置いていない |
| 上流 | https://github.com/mist64/msbasic 、commit `2a0bc2fe0db13f8cf1b5c40b1d5617263cdb9cb4`（2026-04-04） |
| ライセンス | 上流の README.md に「License: 2-clause BSD」とある（LICENSE ファイルと著作権表示の行は上流に無い。README のクレジットは Michael Steil ほか）。README をそのまま同梱した |
| 完全性 | `MANIFEST.sha256`（32 ファイル）。`fpga/basic/sw/build_sw.sh` がビルドのたびに照合する |
| 確認 | cc65 V2.19 でビルドした 9 版（cbmbasic1/2、kbdbasic、osi、kb9、applesoft、microtan、aim65、sym1）が、上流の `orig/*.bin` とバイト単位で一致した（ツールチェーンの確認。2026-11-13） |
| 用途 | KAGURA BASIC。KAGURA 固有の部分は `fpga/basic/sw/kagura/` に新規に書いた（上流ファイルは変更しない） |
| 配布の注意 | BASIC のバイナリ（`fpga/basic/sw/build/basic*.bin`）は生成物で、リポジトリには置かない。バイナリを配布する場合は、この節の表示（BSD-2 の条件）と、下記の Microsoft の MIT 表示を添えること |

## Microsoft BASIC for 6502 Version 1.1（Microsoft、MIT）

| 項目 | 内容 |
|---|---|
| 配置 | [third_party/microsoft-basic-m6502/](third_party/microsoft-basic-m6502/): `LICENSE`（MIT）と `README.md` だけ（ソース `m6502.asm` は置いていない） |
| 上流 | https://github.com/microsoft/BASIC-M6502 、commit `7460af2c03ae19c0e60ff327489229d2005b9357`（2025-09-03） |
| 関係 | msbasic は Microsoft BASIC の各 OEM 版を再構成したもの。Microsoft は 2025-09 に Version 1.1（KIM-1 = `REALIO=1`、OSI、PET、Apple の条件付き）のソースを MIT で公開した。KAGURA BASIC は **KIM-1 版（1.1）の構成**を基にしたので、元のコードは MIT 公開の範囲にある。OEM 固有の追加（Commodore の拡張など）は KAGURA の構成では有効にしていない |
| 未確認 | msbasic の BSD-2 と Microsoft の MIT の関係（再構成物の権利関係）は、法的な確認をしていない。製品として配布する前に確認すること |

## 比較のために使ったが、リポジトリに入れていないもの

| ソース | 版 | 用途 | 理由 |
|---|---|---|---|
| cc65 | V2.19（`555282497c3ecf8b313d87d5973093af19c35bd5`、zlib ライセンス） | ca65 / ld65（BIOS と BASIC のビルド） | ツール。`fpga/tools/build_cc65.sh` で `build/tools/` にローカルビルドする（システムには入れない） |
