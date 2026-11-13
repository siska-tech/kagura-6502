# KAGURA-6502 — RTL v1.0 RC

**W65C02S 実機照合待ち。** Tang Nano 9K（GW1NR-LV9QN88PC6/I5、device version C）向けの統合版です。CPU 3.375 MHz、PSRAM 主記憶、高速 RAM 8 KiB、Boot ROM 2 KiB、VDP 320×176（1024 パターン、256 スプライト）、HDMI 720p60、6ch 音源（48 kHz ステレオ、HDMI / PWM）の構成です。

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
