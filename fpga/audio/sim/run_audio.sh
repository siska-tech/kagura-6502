#!/usr/bin/env bash
# KAGURA-6502 6-channel audio unit simulation (WSL, Verilator 5.032).
#   k65_vdp (wave 0/1) + k65_audio (pulse 0-2, noise, mixer, PWM) + k65_hdmi_tx, with an
#   independent reference model, HDMI TMDS decode of the audio packets and a PWM check.
# usage: run_audio.sh [lint|main|neg|all]   (default all). Exit code = failures.
set -uo pipefail
cd "$(dirname "$0")"
R=../../..
RTL="$R/fpga/vdp/rtl/k65_vdp.sv ../rtl/k65_audio.sv $R/fpga/rtl/hdmi/k65_hdmi_tx.sv"
TB="tb_hdmi_aud_mon.sv tb_pwm_check.sv tb_audio.sv"
mkdir -p build logs
what=${1:-all}
fails=0
if [ "$what" = lint ] || [ "$what" = all ]; then
  verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL --top-module k65_audio ../rtl/k65_audio.sv > logs/lint_k65_audio.log 2>&1 \
    && echo "ok   lint k65_audio (-Wall): no warnings" || { echo "BAD  lint k65_audio"; cat logs/lint_k65_audio.log | head -30; fails=$((fails+1)); }
fi
if [ "$what" != lint ]; then
  verilator --binary --timing -j 0 -Wno-fatal -Wno-WIDTH -Wno-INITIALDLY --top-module tb_audio -Mdir build/tb_audio \
    $RTL $TB > logs/build_tb_audio.log 2>&1 || { echo "build failed"; tail -30 logs/build_tb_audio.log; exit 1; }
fi
if [ "$what" = main ] || [ "$what" = all ]; then
  for seed in 1 2; do
    t0=$SECONDS
    build/tb_audio/Vtb_audio +seed=$seed > logs/audio_s$seed.log 2>&1
    r=$(grep -oE "RESULT: (PASS|FAIL)" logs/audio_s$seed.log | head -1)
    [ "$r" = "RESULT: PASS" ] && echo "ok   audio seed $seed: $r ($((SECONDS - t0)) s)" || { echo "BAD  audio seed $seed: '$r'"; fails=$((fails+1)); }
    grep -E "^(FREQ|NOISE|MIX|SAMPLES|TICKS|hdmi:|pwm:|wave-only)|ERROR" logs/audio_s$seed.log | head -24 | sed 's/^/     /'
  done
fi
# negative tests: each injected fault must make the run FAIL for the expected reason
if [ "$what" = neg ] || [ "$what" = all ]; then
  neg() {   # fault regex
    local f=$1 re=$2
    build/tb_audio/Vtb_audio +seed=3 +$f > logs/neg_$f.log 2>&1
    if grep -q "RESULT: PASS" logs/neg_$f.log; then echo "BAD  neg $f: not caught"; fails=$((fails+1))
    elif grep -qE "$re" logs/neg_$f.log; then echo "ok   neg $f: caught ($(grep -m1 -oE "$re" logs/neg_$f.log))"
    else echo "BAD  neg $f: failed for another reason"; grep -m3 ERROR logs/neg_$f.log; fails=$((fails+1)); fi
  }
  neg fault_noready  "dropped or repeated sample"
  neg fault_mvol     "sample #[0-9]+ = [0-9a-f]+, model"
  neg fault_lfsr     "noise sequence is not periodic|sample #[0-9]+ = [0-9a-f]+, model"
  neg fault_pwm      "ERROR \(pwm check\)"
  neg fault_hdmimon  "ERROR \(hdmi monitor\): decoded sample"
  neg fault_commit   "COMMIT not applied before the next tick"
fi
echo "== run_audio: failures = $fails"
exit $fails
