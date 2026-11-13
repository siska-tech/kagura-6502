#!/usr/bin/env bash
# KAGURA-6502 BASIC platform software build (WSL or Git Bash with cc65 V2.19).
#   BIOS (Boot ROM 4 KiB and 2 KiB variants) + msbasic KAGURA image + testbench hex.
# Toolchain: cc65 V2.19 (tag commit 555282497c3ecf8b313d87d5973093af19c35bd5; its
# ca65 prints "V2.18 - Git 5552824"), built locally by tools/build_cc65.sh into
# build/tools/cc65-2.19 (not installed system-wide). Override with CC65=<bin dir>.
# Exit code != 0 on any error (including a third-party file hash mismatch).
set -euo pipefail
cd "$(dirname "$0")"
R=../../..
CC65=${CC65:-$R/build/tools/cc65-2.19/bin}
PY=${PY:-python3}
command -v "$PY" >/dev/null || PY="uv run --no-project python"
OUT=build
mkdir -p $OUT
"$CC65/ca65" --version 2>&1 | grep -q "Git 5552824" || { echo "need cc65 V2.19 (Git 5552824) at $CC65"; exit 1; }

# third-party sources must be the pinned, unmodified upstream files
( cd $R/third_party/msbasic && sha256sum -c --quiet MANIFEST.sha256 ) || { echo "msbasic files differ from MANIFEST"; exit 1; }

# ---- BIOS
for v in 4k 2k; do
  "$CC65/ca65" -g -I . -l $OUT/bios$v.lst bios.s -o $OUT/bios$v.o
  "$CC65/ld65" -C bios$v.cfg $OUT/bios$v.o -o $OUT/bios$v.bin -Ln $OUT/bios$v.lbl -m $OUT/bios$v.map
  $PY mkimage.py rom $OUT/bios$v.bin $OUT/bios$v.hex
  # VDP builds (fpga/vdp): same BIOS + VRAM clear at reset
  "$CC65/ca65" -g -D VDP -I . -l $OUT/bios${v}_vdp.lst bios.s -o $OUT/bios${v}_vdp.o
  "$CC65/ld65" -C bios$v.cfg $OUT/bios${v}_vdp.o -o $OUT/bios${v}_vdp.bin -Ln $OUT/bios${v}_vdp.lbl -m $OUT/bios${v}_vdp.map
  $PY mkimage.py rom $OUT/bios${v}_vdp.bin $OUT/bios${v}_vdp.hex
done

# ---- BASIC (msbasic upstream + kagura/ platform layer), two images:
#   basic      : whole interpreter runs from PSRAM ($9800-), program memory from $0300
#   basic_fast : CODE segment copied by the BIOS to fast RAM $0300-$1FFF, program from $2000
for v in basic basic_fast; do
  if [ $v = basic ]; then D=""; CFG=kagura/kagura.cfg; else D="-D FASTCODE"; CFG=kagura/kagura_fast.cfg; fi
  "$CC65/ca65" -g $D -I kagura -I $R/third_party/msbasic -l $OUT/$v.lst kagura/kagura_basic.s -o $OUT/$v.o
  "$CC65/ld65" -C $CFG $OUT/$v.o -o $OUT/${v}_raw.bin -Ln $OUT/$v.lbl -m $OUT/$v.map --dbgfile $OUT/$v.dbg
  $PY mkimage.py basic $OUT/${v}_raw.bin 9800 $OUT/$v.bin $OUT/${v}_psram.hex
  $PY mkimage.py frame $OUT/$v.bin 9800 $OUT/${v}_frame.bin
done
# negative-test image: one interpreter byte changed (checksum no longer matches)
awk 'NR==1000 { printf "%02x\n", (strtonum("0x" $0) + 1) % 256; next } { print }' \
  $OUT/basic_psram.hex > $OUT/basic_psram_bad.hex
cmp -s $OUT/basic_psram.hex $OUT/basic_psram_bad.hex && { echo "bad image not different"; exit 1; }

# ---- size / layout report
for v in basic basic_fast; do
$PY - "$OUT" $v <<'PYEOF'
import sys, re
out, v = sys.argv[1], sys.argv[2]
segs = {}
for l in open(f'{out}/{v}.map'):
    m = re.match(r'^(\w+)\s+([0-9A-F]{6})\s+([0-9A-F]{6})\s+([0-9A-F]{6})', l)
    if m and m.group(1) not in segs:
        segs[m.group(1)] = (int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16))
print(f'{v} segments (run address):', ', '.join(f'{k} ${a:04X}-${b:04X} ({n})' for k, (a, b, n) in segs.items() if n))
code = sum(n for k, (a, b, n) in segs.items() if k not in ('ZEROPAGE', 'DUMMY'))
print(f'{v}: image {code} bytes incl. 24-byte header; zero page ${segs["ZEROPAGE"][0]:02X}-${segs["ZEROPAGE"][1]:02X}')
PYEOF
done
for v in 4k 2k; do
  echo "BIOS $v: $(grep -E '^BIOS ' $OUT/bios$v.map | head -1)"
done
echo "build_sw: OK"
