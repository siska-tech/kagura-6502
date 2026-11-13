// KAGURA-6502 BASIC + VDP + 6-channel audio build = vdp.sdc unchanged (no new exceptions). The audio
// crossings (COMMIT toggle + one-clock register copy, acknowledge / drop toggles) are between the
// asynchronous clk_sys / clk_pix groups already declared below; see docs/audio-6ch.md.
// KAGURA-6502 VDP integrated build timing constraints = basic.sdc (system / pixel clocks asynchronous; the VDP crosses only through SDPB blocks, a toggle + index and quasi-static audio registers)
create_clock -name clk27 -period 37.037 [get_ports {clk27}]
// system PLL: 54 MHz, and the same clock at 67.5 deg for PSRAM CK (static PSDA=3;
// STA does not infer the phase, so it is stated explicitly - as in KAGURA-9)
create_generated_clock -name clk_sys -source [get_ports {clk27}] -multiply_by 2 [get_pins {u_pll_sys/CLKOUT}]
create_generated_clock -name clk_ck  -source [get_ports {clk27}] -multiply_by 2 -phase 67.5 [get_pins {u_pll_sys/CLKOUTP}]
// video PLL: 371.25 MHz serial, 74.25 MHz pixel
create_generated_clock -name clk_ser -source [get_ports {clk27}] -multiply_by 55 -divide_by 4 [get_pins {u_pll_vid/CLKOUT}]
create_generated_clock -name clk_pix -source [get_pins {u_pll_vid/CLKOUT}] -divide_by 5 [get_pins {u_div/CLKOUT}]
// system <-> pixel: only the 2-FF status synchronisers (st_m/st_p) cross
set_clock_groups -asynchronous -group [get_clocks {clk_sys clk_ck}] -group [get_clocks {clk_pix clk_ser}]

// ---- W65C02S bus (docs/bus-timing.md, re-based on the 54 MHz system clock) ----
// max = tCO(PHI2) 14.0 (STA, 54 MHz build) + PCB 1 + tADS/tMDS 40 + PCB 1 = 56.0 ns
// min = tCO(PHI2) min 8.7 + tAH/tDHW 10 = 18.7 ns -> 17.0 kept (conservative)
set_input_delay -clock clk_sys -max 56.0 [get_ports {cpu_a[*] cpu_rwb cpu_d[*]}]
set_input_delay -clock clk_sys -min 17.0 [get_ports {cpu_a[*] cpu_rwb cpu_d[*]}]
// address/RWB captured T_ASAMP=4 edges after the PHI2-fall edge
set_multicycle_path -to [get_regs {u_core/a_q_*_s0 u_core/rw_q_s0}] -setup -end 4
set_multicycle_path -to [get_regs {u_core/a_q_*_s0 u_core/rw_q_s0}] -hold  -end 3
// write data captured CYC-1-HALF edges after the PHI2-rise edge; 7 = CYC 16 (tightest)
set_multicycle_path -to [get_regs {u_core/wdata_q_*_s0}] -setup -end 7
set_multicycle_path -to [get_regs {u_core/wdata_q_*_s0}] -hold  -end 6
set_output_delay -clock clk_sys 0 [get_ports {cpu_phi2 cpu_d[*] cpu_irqb}]

// ---- slow / asynchronous ports ----
set_false_path -from [get_ports {cpu_sync_1v8 btn_n[*] bl_uart_rx xiao_rx user_btn_n}]
set_false_path -to   [get_ports {xiao_tx bl_uart_tx led_n[*] dbg[*] aud_pwm_l aud_pwm_r}]

report_timing -setup -max_paths 30 -max_common_paths 1
report_timing -hold  -max_paths 30 -max_common_paths 1
report_timing -setup -from [get_ports {cpu_a[*] cpu_d[*] cpu_rwb}] -max_paths 40 -max_common_paths 1
report_timing -hold  -from [get_ports {cpu_a[*] cpu_d[*] cpu_rwb}] -max_paths 40 -max_common_paths 1
report_timing -setup -to   [get_ports {cpu_phi2 cpu_d[*] cpu_irqb}] -max_paths 40 -max_common_paths 1
report_timing -hold  -to   [get_ports {cpu_phi2 cpu_d[*] cpu_irqb}] -max_paths 40 -max_common_paths 1
report_timing -setup -from [get_clocks {clk_sys}] -to [get_clocks {clk_ck}] -max_paths 10 -max_common_paths 1
report_timing -setup -from [get_clocks {clk_ck}] -to [get_clocks {clk_sys}] -max_paths 10 -max_common_paths 1
