#!/usr/bin/env bash
# KAGURA-6502 system simulation (WSL, Verilator 5.032): W65C02S cycle model (6502-sim,
# PINNED, read-only via git archive) + k65_basic_core (EXT_EN=1) + k65_vdp + k65_hdmi_tx
# + KAGURA-9 PSRAM controller + independent PSRAM model + console terminal.
# Needs the software build: fpga/basic/sw/build_sw.sh (BIOS with -D VDP, BASIC images).
# usage: run_system.sh [name ...]   Exit code = failures.
set -uo pipefail
cd "$(dirname "$0")"
R=../../..
SIM6502=${SIM6502:-/mnt/c/Users/Shion/Documents/Projects/6502-sim}
SIM6502_REV=${SIM6502_REV:-f00df4cb3bf639270f294965de1dea98bb55cfce}
CPUDIR=build/6502sim_${SIM6502_REV:0:7}
rm -rf "$CPUDIR"; mkdir -p "$CPUDIR"
git -C "$SIM6502" archive "$SIM6502_REV" rtl | tar -x -C "$CPUDIR" || { echo "cannot extract 6502-sim $SIM6502_REV"; exit 1; }
echo "6502-sim: pinned at $(git -C "$SIM6502" rev-parse "$SIM6502_REV") (working tree at $(git -C "$SIM6502" rev-parse --short HEAD), not used)"
CPU="$CPUDIR/rtl/w65c02s_cycle.sv $CPUDIR/rtl/w65c02s_bus_resolver.sv"
CORE="$R/fpga/basic/rtl/k65_basic_core.v $R/fpga/basic/rtl/k65_uart_rx.v $R/fpga/phase1/rtl/k65_uart_tx.v $R/fpga/phase2/rtl/k65_psram_port.sv"
VDP="../rtl/k65_vdp.sv $R/fpga/audio/rtl/k65_audio.sv $R/fpga/rtl/hdmi/k65_hdmi_tx.sv"
PS="$R/third_party/kagura-9/kagura_hyperram_ctrl.sv $R/fpga/phase2/rtl/k65_psram_ctrl.sv"
TB="$R/fpga/exp74/sim/k65_dly.sv $R/fpga/exp74/sim/k65_psram_phy_model_t.sv $R/fpga/audio/sim/tb_hdmi_aud_mon.sv $R/fpga/audio/sim/tb_pwm_check.sv tb_system.sv"
mkdir -p build logs
fails=0
# name NPAT AUDIO script plusargs   (AUDIO=1: core EXT_EN=2, k65_audio at $D400, 6-channel mix to HDMI / PWM)
cfgs=( "sys_p1024_vdp 1024 0 vdp +memsize=38912"
       "sys_p1024_poc 1024 0 poc +memsize=38912"
       "sys_p960_vdp   960 0 vdp +memsize=38912"
       "sys_a1024_aud 1024 1 aud +memsize=38912"
       "sys_a1024_vdp 1024 1 vdp +memsize=38912"
       "sys_a1024_poc 1024 1 poc +memsize=38912" )
want=("$@")
for c in "${cfgs[@]}"; do
  read -r n np au sc pa <<<"$c"
  if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $n " ]]; then continue; fi
  b="build/b_p${np}_a$au"
  if [ ! -x "$b/Vtb_system" ]; then
    verilator --binary --timing -j 0 -Wno-fatal -Wno-WIDTH -Wno-INITIALDLY -Wno-PINCONNECTEMPTY \
      --top-module tb_system -Mdir "$b" "-I$CPUDIR/rtl" -GNPAT=$np -GAUDIO=$au $CPU $CORE $VDP $PS $TB > "logs/build_p${np}_a$au.log" 2>&1 \
      || { echo "build failed: $n"; tail -30 "logs/build_p${np}_a$au.log"; fails=$((fails+1)); continue; }
  fi
  t0=$SECONDS
  "$b/Vtb_system" +script=$sc $pa > "logs/$n.log" 2>&1
  r=$(grep -oE "RESULT: (PASS|FAIL)" "logs/$n.log" | head -1)
  [ "$r" = "RESULT: PASS" ] && echo "ok   $n: $r ($((SECONDS - t0)) s wall)" || { echo "BAD  $n: '$r'"; fails=$((fails+1)); }
  grep -E "^MARK|^VDP:|^CPU:|^CPU pins|^AUD|^hdmi:|^pwm:|ERROR|BYTES FREE" "logs/$n.log" | head -30 | sed 's/^/     /'
done
# negative test: sprites forced off in the VDP -> the frame compare must report mismatches
if [ ${#want[@]} -eq 0 ] || [[ " ${want[*]} " =~ " neg " ]]; then
  build/b_p1024_a0/Vtb_system +script=vdp +memsize=38912 +fault_nospr > logs/neg_nospr.log 2>&1
  if grep -q "RESULT: PASS" logs/neg_nospr.log; then echo "BAD  neg fault_nospr: not caught"; fails=$((fails+1))
  elif grep -qE "mismatches=[1-9]" logs/neg_nospr.log; then echo "ok   neg fault_nospr: caught ($(grep -oE "mismatches=[0-9]+" logs/neg_nospr.log))"
  else echo "BAD  neg fault_nospr: failed for another reason"; fails=$((fails+1)); fi
fi
echo "== run_system: failures = $fails"
exit $fails
