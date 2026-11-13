# KAGURA-6502 キャリア基板 Rev.A（設計版 0.5）

KiCad 10 用の基板ソースは [board ディレクトリ](https://github.com/siska-tech/kagura-6502/tree/main/board) にあります。
基板は 72 × 48 mm、4 層。表裏に GND ゾーンを配置した。上下の長辺から内側へ各 2 mm をケースの支持帯とし、全銅箔層で配線・ビア・パッド・ベタを禁止した。部品も禁止領域の内側に置かない。
[ピン割当表](https://github.com/siska-tech/kagura-6502/blob/main/docs/pinmap.md) に従い、W65C02S DIP-40、Tang Nano 9K、
XIAO RP2040 を接続する。HDMI 映像・音声には Tang のコネクタを使用する。

| 参照 | 部品・用途 |
| --- | --- |
| U1 | W65C02S DIP-40（15.24 mm 列間隔）。Tang の直下に配置。Tang 側には CPU とソケットの積み上げ高さを超える高さのソケットを使用する |
| J5、J6 | Tang 用 1×24、2.54 mm ソケット。USB-C を左、HDMI を右、部品面を上にする。上段が J6、下段が J5。各 1 番は左 |
| U2 | XIAO RP2040 を表面に直付け。USB-C は右端。W65C02S と長手方向の中心線を共有 |
| J3 | 外付けモーメンタリスイッチ。1: USER_BTN_N、2: GND |
| J4 | デバッグ。1: GND、2–3: PWM L/R、4–7: DBG0–3。すべて入力専用プローブで観測する（信号は 1.8 V） |
| JP1 | XIAO 給電ジャンパ |
| D1 | SS14。帯（カソード）を 1 番パッド側にする |
| R1、R3 | 3.3 kΩ |
| R2、R4–R7 | 10 kΩ |
| R8 | 33 Ω、PHI2 直列 |
| C1、C2 | 100 nF、10 µF。いずれも無極性 MLCC |
| J7 | USB Type-A ホスト、TE 292303-7。XIAO D4/D5 が D+/D− |
| J8 | 3.3 V SPI 汎用拡張ヘッダ（2.54 mm、6 ピン）。1: 3V3、2: GND、3: CS、4: SCK、5: MOSI、6: MISO |
| F1 | USB VBUS の 500 mA 保持 PTC。1206L050/15YR |
| R9、R10 | USB データ線の 22 Ω 直列抵抗 |
| R11、R12 | USB データ線の 15 kΩ プルダウン |


[Pico Carrier Board](https://github.com/siska-tech/kagura/tree/main/boards/pico-carrier-board) を参考に、Tang を上側、USB-A を左側に配置した。XIAO の直付けランドは参照基板と同寸で、KAGURA-6502 では基板表面の右端に配置した。Tang と XIAO の積み上げ高さ、および USB-C プラグの逃げを実装前に確認する。J5/J6 は幅 2.54 mm のソケットを想定している。

Tang は [Sipeed の外形図](https://dl.sipeed.com/fileList/TANG/Nano%209K/4_Dimensional_drawing/Tang_Nano_9K_3672_size.pdf) を参照し、ソケット列間隔を 22.86 mm とした。
XIAO のピン配列は [Seeed のピンアウト](https://wiki.seeedstudio.com/XIAO-RP2040/) を参照した。
発注前に両モジュールを現物と照合し、列間隔、1 番ピン、ソケット高さ、裏面部品とケーブルの逃げを確認する。

Tang の USB-C を主電源とし、J6-24 の 3.3 V を CPU に供給する。JP1 を閉じると
J6-18 の 5 V が D1 経由で XIAO に供給される。JP1 は初期状態では開放し、
使用する Tang のリビジョンで J6-18 の電圧と負荷時の電流余裕を確認してから閉じる。
XIAO を USB 接続する際は JP1 を開放する。給電されていないモジュールに
接続先から信号を入れないよう、XIAO 単体で書き込む場合はTang 側の信号への逆給電を避けられる状態で作業する。
Tang の TF スロットは CPU のアドレス線と共有するため、カードは挿さない。

USB ホストの VBUS は Tang の J6-18 から F1 を経由して供給する。
F1 はリセット可能な過電流保護で、Tang が 500 mA を給電できることを保証するものではない。
周辺機器を接続する前に Tang の 5 V 出力を負荷時に確認する。
USB ホストと SPI 周辺機器の利用には XIAO 側の対応ファームウェアが必要。
J8 は 3.3 V ロジック専用。標準の4ピン Grove とは機械的・電気的に互換性がない。

| 参照 | JLCPCB 部品番号 | 分類 |
| --- | --- | --- |
| R1、R3 | [C22978](https://jlcpcb.com/partdetail/23705-0603WAF3301T5E/C22978) | Basic |
| R2、R4–R7 | [C25804](https://jlcpcb.com/partdetail/C25804) | Basic |
| R8 | [C23140](https://jlcpcb.com/partdetail/0603WAF330JT5E/C23140) | Basic |
| R9、R10 | [C23345](https://jlcpcb.com/partdetail/C23345) | Basic |
| R11、R12 | [C22809](https://jlcpcb.com/partdetail/0603WAF1502T5E/C22809) | Basic |
| C1 | [C14663](https://jlcpcb.com/partdetail/C14663) | Basic |
| C2 | [C15850](https://jlcpcb.com/partdetail/C15850) | Basic |
| D1 | [C2480](https://jlcpcb.com/partdetail/C2480) | Basic |
| F1 | [C151162](https://jlcpcb.com/partdetail/Littelfuse-1206L05015YR/C151162) | Extended |

J7 は機械固定脚付きの SMT コネクタで、モジュール用ソケット類とともに別途手配する。

KiCad 10.0.8 の ERC、DRC、未配線、回路図と PCB の照合はすべて 0 件。
シンボルのピンは接続表に基づく受動型なので、ERC は信号方向や電源容量を検証しない。
初回通電では電源電圧、RESB の起動シーケンス、PHI2 の波形を確認する。
実機での嵌合・通電は未検証。


## 組み立てと初回確認

1. ガーバー ZIP を基板メーカーに渡し、4 層の銅箔、外形、PTH と NPTH のドリルが認識され、外形が 72 × 48 mm であることを確認する。
2. 背の低い部品から実装する。D1 の帯と CPU の 1 番ピンを基板の表示と照合する。Tang のソケットと CPU ソケットを仮置きし、重なりとコネクタの逃げを確認してからはんだ付けする。
3. 通電前に電源と GND の短絡を確認し、JP1 は開放する。モジュールを接続する前にピン番号と向きを確認する。XIAO の独立給電時は逆給電に注意する。
4. Tang Nano 9K 用の aud_p1024.fs の SHA-256 を確認して書き込む。CPU の電源、RESB、PHI2 を確認し、続いて HDMI 映像・音声と CPU の起動を確認する。リポジトリ内の XIAO スクリプトは Phase 1 向けで、現行 RC との組み合わせは未確認。

この配布版は W65C02S 実機照合待ちです。
