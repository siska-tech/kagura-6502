# BIOS・BASIC と実機起動（RTL v1.0 RC）

Tang の USB シリアルを 115200 baud、8N1 に設定します。CPU の電源、PHI2、RESB の解除を確認し、BIOS が有効な BASIC イメージを見つけられない場合は `NO BASIC IMAGE - LOADER READY` を待ちます。初回の給電・接続は [組み立て指南書](../board/README.md) を参照してください。

XIAO は FPGA の状態フレームを受け取り、READY が連続して有効になってから RESB を解除します。同梱の [MicroPython スクリプト](../xiao/phase1/main.py) と現行 RC の組み合わせは実機未確認です。USB キーボード入力には XIAO の USB ホスト／HID 処理と FPGA 側のコンソール入力経路が必要です。

## BASIC のビルドとロード

リポジトリのルートで実行します。

```sh
bash fpga/tools/build_cc65.sh
bash fpga/basic/sw/build_sw.sh
```

`fpga/basic/sw/build/` に `basic_frame.bin` と `basic_fast_frame.bin` が生成されます。前者はインタプリタ本体を PSRAM で実行し、後者はコード部分を高速 RAM にコピーします。どちらかのフレームをバイナリのまま送信し、BIOS から `OK` を受信した後に ASCII の `B` を 1 バイト送ります。ローダと BASIC の実機対話は照合待ちです。

| コマンド | フォーマットと動作 |
| --- | --- |
| `L` | `L addr16 len16 data[len] sum16`。16 ビット値はリトルエンディアン。sum16 はデータのバイト和の下位 16 ビット。応答は OK または ER と CR LF |
| `B` | PSRAM の $9800 にある BASIC イメージを検査して起動 |
| `G` | `G addr16`。指定したアドレスへジャンプ |

BIOS はイメージのヘッダとチェックサムを検査します。インタプリタのイメージを置く PSRAM 領域はシステム I/O の $D00C で書き込み保護します。実装は [BIOS ソース](../fpga/basic/sw/bios.s) を参照してください。
