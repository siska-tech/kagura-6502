#!/usr/bin/env bash
# KAGURA-6502 VDP unit simulation (WSL, Verilator 5.032): whole-frame comparison with an
# independent reference renderer, for the build variants of fpga/vdp/syn/build_vdp.sh.
# usage: run_vdp.sh [name ...]   Exit code = failures.
set -uo pipefail
cd "$(dirname "$0")"
R=../../..
SRC="../rtl/k65_vdp.sv $R/fpga/rtl/hdmi/k65_hdmi_tx.sv tb_vdp.sv"
mkdir -p build logs
# name NPAT PAT_FLAT SHARE_PW OAM_DBL seed
cfgs=( "u_p1024        1024 0 1 0 1"
       "u_p1024_s2     1024 0 1 0 2"
       "u_p960          960 0 1 0 3"
       "u_p880          880 0 1 0 4"
       "u_p880_flat     880 1 1 0 5"
       "u_p1024_split  1024 0 0 0 6"
       "u_p1024_oamdbl 1024 0 1 1 7" )
want=("$@")
fails=0
for c in "${cfgs[@]}"; do
  read -r n np fl sh od seed <<<"$c"
  if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $n " ]]; then continue; fi
  b="build/$n"
  verilator --binary --timing -j 0 -Wno-fatal -Wno-WIDTH -Wno-INITIALDLY --top-module tb_vdp -Mdir "$b" \
    -GNPAT=$np -GPAT_FLAT=$fl -GSHARE_PW=$sh -GOAM_DBL=$od $SRC > "logs/build_$n.log" 2>&1 \
    || { echo "build failed: $n"; tail -20 "logs/build_$n.log"; fails=$((fails+1)); continue; }
  t0=$SECONDS
  "$b/Vtb_vdp" +seed=$seed > "logs/$n.log" 2>&1
  r=$(grep -oE "RESULT: (PASS|FAIL)" "logs/$n.log" | head -1)
  [ "$r" = "RESULT: PASS" ] && echo "ok   $n: $r ($((SECONDS - t0)) s)" || { echo "BAD  $n: '$r'"; fails=$((fails+1)); }
  grep -E "^compared|^STATUS|ERROR" "logs/$n.log" | head -8 | sed 's/^/     /'
done
# worst case: 256 sprites 16x16 on the same rows + CPU VRAM writes at full rate
if [ ${#want[@]} -eq 0 ] || [[ " ${want[*]} " =~ " worst " ]]; then
  build/u_p1024/Vtb_vdp +seed=9 +worst > logs/worst.log 2>&1
  grep -q "RESULT: PASS" logs/worst.log && echo "ok   worst: $(grep -oE "render max [0-9]+ sysclk \(budget [0-9]+\), overrun=[0-9]" logs/worst.log)"     || { echo "BAD  worst"; grep ERROR logs/worst.log | head -5; fails=$((fails+1)); }
fi
# +wavefull: both wave channels with random tables, every sample compared with a model while the
# whole frame is compared (palette / wave read-port sharing); also with +worst (CPU palette writes)
if [ ${#want[@]} -eq 0 ] || [[ " ${want[*]} " =~ " wave " ]]; then
  for v in "wave_p1024:+seed=11 +wavefull" "wave_worst:+seed=12 +wavefull +worst"; do
    n=${v%%:*}; pa=${v#*:}
    build/u_p1024/Vtb_vdp $pa > logs/$n.log 2>&1
    grep -q "RESULT: PASS" logs/$n.log && echo "ok   $n: $(grep -oE "WAVE: [0-9]+ samples compared with the model \([0-9]+ mismatches\), [0-9]+ ticks of which [0-9]+ during active video" logs/$n.log); $(grep -oE "compared [0-9]+ pixels, [0-9]+ mismatches" logs/$n.log)" \
      || { echo "BAD  $n"; grep ERROR logs/$n.log | head -5; fails=$((fails+1)); }
  done
  build/u_p1024/Vtb_vdp +seed=11 +wavefull +fault_wsel > logs/neg_fault_wsel.log 2>&1
  if grep -q "RESULT: PASS" logs/neg_fault_wsel.log; then echo "BAD  neg fault_wsel: not caught"; fails=$((fails+1))
  elif grep -qE "wave sample #[0-9]+ = " logs/neg_fault_wsel.log; then echo "ok   neg fault_wsel: caught ($(grep -m1 -oE "wave sample #[0-9]+ = [0-9a-f]+, model [0-9a-f]+" logs/neg_fault_wsel.log))"
  else echo "BAD  neg fault_wsel: failed for another reason"; fails=$((fails+1)); fi
fi
# negative tests: DUT faults injected during the compared frame must be caught by the pixel compare
if [ ${#want[@]} -eq 0 ] || [[ " ${want[*]} " =~ " neg " ]]; then
  for f in fault_border fault_hflip fault_sprpal fault_lbskip; do
    build/u_p1024/Vtb_vdp +seed=1 +$f > "logs/neg_$f.log" 2>&1
    if grep -q "RESULT: PASS" "logs/neg_$f.log"; then echo "BAD  neg $f: not caught"; fails=$((fails+1))
    elif grep -qE "pixel mismatches" "logs/neg_$f.log"; then echo "ok   neg $f: caught ($(grep -oE "[0-9]+ pixel mismatches" "logs/neg_$f.log"))"
    else echo "BAD  neg $f: failed for another reason"; fails=$((fails+1)); fi
  done
fi
echo "== run_vdp: failures = $fails"
exit $fails
