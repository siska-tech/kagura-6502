#!/usr/bin/env bash
# Build the KAGURA-6502 integrated BASIC + VDP + 6-channel audio Gowin variants (Git Bash on
# Windows, any cwd). usage: build_audio.sh [name ...]   (default: all variants below)
# Derived from fpga/vdp/syn/build_vdp.sh. Each line: name NPAT [PLACE (place_option, default 2)].
# CPU side fixed: 3.375 MHz, fast RAM 8 KiB, Boot ROM 2 KiB; VDP: banked patterns, palette +
# wave in one SDPB, OAM single block (the recommended vdp_p1024 structure). Reports of record
# -> build-logs/audio/<name>/. Exit code = number of failed checks (build, STA violated
# endpoints, DPB, OSER10, pins, BSRAM > 26, LUT-RAM (SSRAM) above the VDP baseline of 16).
set -uo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../../.. && pwd)
GW=/c/Gowin/Gowin_V1.9.12.04_x64/IDE/bin/gw_sh.exe
variants=(
  "aud_p1024      1024"
)
want=("$@")
fails=0
for v in "${variants[@]}"; do
  read -r name npat place <<<"$v"; place=${place:-2}
  if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
  rm -rf "impl_$name" impl; mkdir -p "impl_$name"
  K65_PLACE=$place K65_NAME=$name K65_NPAT=$npat timeout 1200 "$GW" run_audio.tcl > "impl_$name/gw_run_$name.log" 2>&1
  rc=$?
  [ -d impl ] && mv impl "impl_$name/impl"
  cp "gen/cfg_$name.v" audio.sdc "impl_$name/" 2>/dev/null
  d="impl_$name"; r="$d/impl/pnr/$name"
  mkdir -p "$ROOT/build-logs/audio/$name"
  cp "$d/gw_run_$name.log" "$d/cfg_$name.v" "$ROOT/build-logs/audio/$name/" 2>/dev/null
  if [ $rc != 0 ] || [ ! -f "$r.tr" ]; then
    echo "--- $name (NPAT=$npat place_option=$place): GOWIN FAILED (rc=$rc)"
    grep -iE "error" "$d/gw_run_$name.log" | head -6
    fails=$((fails+1)); continue
  fi
  echo "--- $name (NPAT=$npat, 6-channel audio, place_option=$place)"
  grep -E "^  (Logic|Register|BSRAM|SSRAM|I/O Port|rPLL|CLKDIV) " "$r.rpt.txt" | sed 's/  */ /g'
  grep -E "Numbers of (Setup|Hold) Violated" "$r.tr"
  echo "Fmax: $(grep -E "^\s+[0-9]\s+clk_(sys|ck|pix)\s+[0-9.]+\(MHz\)" "$r.tr" | awk '{printf "%s %s / ", $2, $4}')"
  nv=$(grep -E "Numbers of (Setup|Hold) Violated" "$r.tr" | awk -F: '{s+=$2} END{print s+0}')
  [ "$nv" = 0 ] || { echo "STA FAIL: $name ($nv violated endpoints)"; fails=$((fails+1)); }
  vg="$d/impl/gwsynthesis/$name.vg"
  echo "BSRAM primitives: $(grep -o -E '^\s*(DPB|DPX9B|SDPB|SDPX9B|SP|SPX9|pROM|pROMX9)\s' "$vg" | sort | uniq -c | tr -s ' \n' ' ')"
  ndpb=$(grep -c -E '^\s*(DPB|DPX9B)\s' "$vg")
  [ "$ndpb" = 0 ] || { echo "DPB used: $name"; fails=$((fails+1)); }
  nbs=$(grep -E "^  BSRAM " "$r.rpt.txt" | grep -oE "[0-9]+/26" | cut -d/ -f1)
  [ -n "$nbs" ] && [ "$nbs" -le 26 ] || { echo "BSRAM over budget: '$nbs'"; fails=$((fails+1)); }
  nss=$(grep -E "SSRAM\(RAM16\)" "$r.rpt.txt" | awk -F'|' '{gsub(/ /, "", $2); print $2}')
  grep -E "SSRAM\(RAM16\)|LUT,ALU,ROM16|MULT" "$r.rpt.txt" | sed 's/  */ /g'
  [ "${nss:-0}" -le 16 ] && echo "SSRAM (LUT RAM): ${nss:-0} (VDP baseline 16: nothing moved out of BSRAM)" \
    || { echo "SSRAM $nss > 16: a memory was moved to LUT RAM"; fails=$((fails+1)); }
  nos=$(grep -c -E 'defparam .*u_ser *\.LSREN="false"' "$vg")
  [ "$nos" = 4 ] && echo "OSER10 GSR-only: $nos/4" || { echo "OSER10 LSREN check FAIL ($nos)"; fails=$((fails+1)); }
  bash "$ROOT/fpga/tools/check_pins.sh" "$ROOT/fpga/constraints/tn9k_kagura6502.cst" "$r.rpt.txt" || fails=$((fails+1))
  cp "$r.rpt.txt" "$r.tr" "$r.pin.html" "$d/impl/gwsynthesis/${name}_syn.rpt.html" "$d/audio.sdc" \
     "$ROOT/build-logs/audio/$name/"
done
echo "### build_audio: failed checks = $fails"
exit $fails
