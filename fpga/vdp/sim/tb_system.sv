// KAGURA-6502 system testbench: BASIC + VDP + PSRAM (derived from fpga/basic/sim/tb_basic.sv).
//   W65C02S cycle model (6502-sim w65c02s_cycle, pinned commit, see run_system.sh)
//   + k65_basic_core with EXT_EN=1 ($D300-$D3FF -> k65_vdp register port)
//   + k65_vdp (system 54 MHz + pixel 74.25 MHz) + k65_hdmi_tx (cx/cy, audio)
//   + k65_basic_core (54 MHz bus engine, FAST_RAM_BYTES, console UART, PSRAM WP)
//   + k65_psram_ctrl (unmodified KAGURA-9 controller, INIT_CYCLES 18432)
//   + k65_psram_phy_model_t (exp74 independent PSRAM model, datasheet times in ns)
//   + a terminal on the console UART that runs a dialogue script.
//
// CPU / board / bus checks are the ones of fpga/exp74/sim/tb_cpu.sv (same code):
//   contention at both ends, FPGA OE window, address / write-data sampling window,
//   address stable while PHI2 high, tPWH / tPWL, tDSR / tDHR (begin/end block, X-7),
//   read timeout, stretch only on PSRAM cycles, PSRAM model protocol / tVCS, reset
//   vector with VPB, unsupported opcode in the cycle model.
// Not checked here: per-instruction cycle counts against the datasheet (the pinned
// 6502-sim revision is itself validated against independent vectors; see docs).
//
// The PSRAM is preloaded with the BASIC image (PS_HEX) = what the BIOS loader or the
// XIAO would have put there; +load_over_uart instead sends the image through the
// BIOS loader on the console UART (slow).
//
// AUDIO=1 (fpga/audio): core EXT_EN=2, k65_audio at $D400 (pulse 0-2, noise, 6-channel mix)
// feeds the HDMI transmitter and the PWM pins; script "aud" programs all six channels from
// BASIC and checks every sample against a model while BASIC runs from PSRAM (PHI2 stretch).
// With AUDIO=0 the build is the VDP-only system as before (legacy wave-only mix).
// Always: TMDS decode of the audio packets vs the accepted samples, PWM delta-sigma bound.
// Plusargs: +script=poc|bench|noimg|vdp|aud  +trace=<csv>  +memsize=<n> (answer to MEMORY SIZE?)
`timescale 1ps/1ps
module tb_system #(
    parameter integer SYS_PS     = 18518,       // 54 MHz
    parameter integer CYC        = 16,          // 3.375 MHz
    parameter integer T_ASAMP    = 4,
    parameter integer D_HOLD     = 2,
    parameter integer S_SETUP    = 2,
    parameter integer FAST       = 8192,
    parameter integer ROMB       = 2048,
    parameter integer PS_INIT    = 18432,
    parameter         ROM        = "../../basic/sw/build/bios2k_vdp.hex",
    parameter         PS_HEX     = "../../basic/sw/build/basic_fast_psram.hex",
    parameter         FRAME      = "../../basic/sw/build/basic_fast_frame.bin",
    parameter integer NPAT       = 1024,
    parameter integer PAT_FLAT   = 0,
    parameter integer SHARE_PW   = 1,
    parameter integer OAM_DBL    = 0,
    parameter integer AUDIO      = 0,           // 1: k65_audio at $D400 (EXT_EN=2)
    parameter integer CON_DIV    = 469,         // 115200 Bd
    parameter integer RXF_LOG2   = 6,           // console RX FIFO 64 bytes (4 = 16 for the negative test)
    parameter integer TCO_PHI2   = 6000,
    parameter integer TCO_D      = 6000,
    parameter integer TIN        = 3000,
    parameter integer PCB        = 1000,
    parameter integer MAX_US     = 3000000       // simulated time limit (us)
);
    localparam integer T_ADS = 40000, T_AH = 10000, T_MDS = 40000, T_DHW = 10000;
    localparam integer T_DSR = 15000, T_DHR = 10000, T_PWH = 62000, T_PWL = 63000;
    localparam integer HALF = CYC / 2, T_DRV = (HALF > T_ASAMP + 3) ? HALF : T_ASAMP + 3;
    localparam integer NOM_HI = CYC - HALF;
    localparam longint BIT_PS = longint'(CON_DIV) * SYS_PS;

    // ------------------------------------------------------------------ clock / reset
    logic clk = 0;
    always #(SYS_PS / 2) clk = ~clk;
    logic rst = 1;
    initial begin repeat (20) @(posedge clk); rst = 0; end
    logic clk_pix = 0, rst_pix = 1;
    always #6734 clk_pix = ~clk_pix;            // 74.25 MHz (13.468 ns)
    initial begin repeat (20) @(posedge clk_pix); rst_pix = 0; end

    // ------------------------------------------------------------------ FPGA (core + PSRAM)
    wire [15:0] a_f; wire rw_f; wire [7:0] d_f; wire sync_f;
    wire [7:0] d_out; wire d_oe, phi2, irq_low, uart_tx, con_tx;
    logic con_rx = 1;
    wire mon_a_sample, mon_w_capture, mon_ready, mon_vec_seen, mon_boot_ok, mon_bus_err;
    wire [15:0] mon_vec, mon_stretch; wire [7:0] mon_sig, mon_irq_cnt; wire [31:0] mon_cycles;
    wire ps_cmd, ps_cmd_en, ps_cmd_rdy, ps_rdata_valid, ps_init_calib;
    wire [19:0] ps_addr; wire [31:0] ps_wdata, ps_rdata; wire [3:0] ps_mask;
    wire p_reset_n, p_cs_n, p_ck_en, p_dq_oe, p_rwds_oe, p_rwds_r, p_rwds_f, p_dq_tx, p_rwds_tx;
    wire [7:0] p_dq_r, p_dq_f, p_in_r, p_in_f;
    k65_psram_ctrl #(.INIT_CYCLES(PS_INIT)) u_psctl (
        .clk(clk), .rst(rst),
        .cmd(ps_cmd), .cmd_en(ps_cmd_en), .cmd_rdy(ps_cmd_rdy), .addr(ps_addr),
        .wr_data(ps_wdata), .data_mask(ps_mask), .rd_data(ps_rdata), .rd_data_valid(ps_rdata_valid),
        .init_calib(ps_init_calib), .phy_reset_n(p_reset_n), .phy_cs_n(p_cs_n), .phy_ck_en(p_ck_en),
        .phy_dq_oe(p_dq_oe), .phy_dq_o_rise(p_dq_r), .phy_dq_o_fall(p_dq_f), .phy_rwds_oe(p_rwds_oe),
        .phy_rwds_o_rise(p_rwds_r), .phy_rwds_o_fall(p_rwds_f), .phy_dq_tx(p_dq_tx), .phy_rwds_tx(p_rwds_tx),
        .phy_dq_i_rise(p_in_r), .phy_dq_i_fall(p_in_f));
    k65_psram_phy_model_t #(.CLK_PS(SYS_PS)) u_psram (
        .clk(clk), .phy_reset_n(p_reset_n), .phy_cs_n(p_cs_n), .phy_ck_en(p_ck_en), .phy_dq_oe(p_dq_oe),
        .phy_dq_o_rise(p_dq_r), .phy_dq_o_fall(p_dq_f), .phy_rwds_oe(p_rwds_oe),
        .phy_rwds_o_rise(p_rwds_r), .phy_rwds_o_fall(p_rwds_f), .phy_dq_i_rise(p_in_r), .phy_dq_i_fall(p_in_f));
    k65_basic_core #(.CYC(CYC), .T_ASAMP(T_ASAMP), .D_HOLD(D_HOLD), .S_SETUP(S_SETUP),
                     .FAST_RAM_BYTES(FAST), .ROM_BYTES(ROMB), .CON_DIV(CON_DIV), .RXF_LOG2(RXF_LOG2),
                     .EXT_EN(AUDIO ? 2 : 1), .ROM_FILE(ROM)) dut (
        .clk(clk), .rst(rst), .a_in(a_f), .rwb_in(rw_f), .d_in(d_f),
        .phi2(phi2), .d_out(d_out), .d_oe(d_oe), .irq_low(irq_low), .uart_tx(uart_tx),
        .con_tx(con_tx), .con_rx(con_rx),
        .ext_wr(x_wr), .ext_rd(x_rd), .ext_addr(x_addr), .ext_page(x_page), .ext_wdata(x_wd), .ext_rdata(x_rdata), .ext_irq(vdp_irq),
        .sync_in(sync_f), .led(), .dbg(),
        .mon_a_sample(mon_a_sample), .mon_w_capture(mon_w_capture), .mon_ready(mon_ready),
        .mon_vec_seen(mon_vec_seen), .mon_boot_ok(mon_boot_ok), .mon_vec(mon_vec),
        .mon_sig(mon_sig), .mon_cycles(mon_cycles), .mon_irq_cnt(mon_irq_cnt),
        .mon_bus_err(mon_bus_err), .mon_stretch(mon_stretch),
        .ps_cmd(ps_cmd), .ps_cmd_en(ps_cmd_en), .ps_cmd_rdy(ps_cmd_rdy), .ps_addr(ps_addr),
        .ps_wdata(ps_wdata), .ps_mask(ps_mask), .ps_rdata(ps_rdata), .ps_rdata_valid(ps_rdata_valid),
        .ps_init_calib(ps_init_calib));

    // ------------------------------------------------------------------ VDP + audio + HDMI (as vdp_top.sv / audio_top.sv)
    wire x_wr, x_rd, vdp_irq; wire [7:0] x_addr, x_wd, x_rdata, v_rdata, a_rdata; wire [3:0] x_page;
    wire [10:0] cx; wire [9:0] cy; wire [23:0] rgb;
    wire s_valid, s_ready; wire [31:0] s_data; wire vdp_ovr; wire [12:0] vdp_rmax;
    wire lg_valid; wire [31:0] lg_data; wire lg_pwm_l, lg_pwm_r;
    wire t_tick, t_wrdy; wire [7:0] t_s0, t_s1, t_v0, t_v1; wire [1:0] t_wen;
    wire au_valid, au_pwm_l, au_pwm_r, au_apply, au_mix; wire [31:0] au_data; wire [15:0] au_drops;
    wire x_vdp = (AUDIO == 0) || (x_page == 4'h3);
    wire x_aud = (AUDIO != 0) && (x_page == 4'h4);
    assign x_rdata = x_aud ? a_rdata : v_rdata;
    k65_vdp #(.NPAT(NPAT), .PAT_FLAT(PAT_FLAT), .SHARE_PW(SHARE_PW), .OAM_DBL(OAM_DBL),
              .PAL_FILE("../rtl/vdp_palette.hex"), .PAL256_FILE("../rtl/vdp_palette256.hex")) u_vdp (
        .clk(clk), .rst(rst),
        .reg_wr(x_wr && x_vdp && x_addr[7:6] == 2'b00), .reg_rd(x_rd && x_vdp && x_addr[7:6] == 2'b00),
        .reg_addr(x_addr[5:0]), .reg_wdata(x_wd), .reg_rdata(v_rdata), .irq(vdp_irq),
        .clk_pix(clk_pix), .rst_pix(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .sample_valid(lg_valid), .sample_ready(AUDIO ? 1'b1 : s_ready), .sample_data(lg_data),
        .pwm_l(lg_pwm_l), .pwm_r(lg_pwm_r),
        .aud_tick(t_tick), .aud_wrdy(t_wrdy), .aud_s0(t_s0), .aud_s1(t_s1), .aud_v0(t_v0), .aud_v1(t_v1), .aud_wen(t_wen),
        .mon_render_ovr(vdp_ovr), .mon_render_max(vdp_rmax));
    k65_audio u_aud (
        .clk(clk), .rst(rst), .reg_wr(x_wr && x_aud && x_addr[7:5] == 3'd0), .reg_rd(x_rd && x_aud && x_addr[7:5] == 3'd0),
        .reg_addr(x_addr[4:0]), .reg_wdata(x_wd), .reg_rdata(a_rdata),
        .clk_pix(clk_pix), .rst_pix(rst_pix), .tick(t_tick), .wv_rdy(t_wrdy), .wv_s0(t_s0), .wv_s1(t_s1),
        .wv_v0(t_v0), .wv_v1(t_v1), .wv_en(t_wen),
        .sample_valid(au_valid), .sample_ready(AUDIO ? s_ready : 1'b1), .sample_data(au_data), .pwm_l(au_pwm_l), .pwm_r(au_pwm_r),
        .mon_apply(au_apply), .mon_mix(au_mix), .mon_drops(au_drops));
    assign s_valid = AUDIO ? au_valid : lg_valid;
    assign s_data  = AUDIO ? au_data  : lg_data;
    wire [9:0] sym0, sym1, sym2;
    k65_hdmi_tx u_hdmi (.clk(clk_pix), .rst(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .sample_valid(s_valid), .sample_data(s_data), .sample_ready(s_ready), .sym0(sym0), .sym1(sym1), .sym2(sym2));
    tb_hdmi_aud_mon u_amon (.clk(clk_pix), .rst(rst_pix), .s0(sym0), .s1(sym1), .s2(sym2),
        .acc_v(s_valid && s_ready), .acc_d(s_data), .cx(cx), .cy(cy));
    tb_pwm_check u_pwmc (.clk(clk_pix), .rst(rst_pix), .sample(s_data),
        .pwm_l(AUDIO ? au_pwm_l : lg_pwm_l), .pwm_r(AUDIO ? au_pwm_r : lg_pwm_r));

    // ------------------------------------------------------------------ board: FPGA -> CPU
    wire phi2_c, foe_c, irq_c; wire [7:0] fd_c;
    k65_dly #(TCO_PHI2 + PCB)        u_bphi (.in(phi2),    .out(phi2_c));
    k65_dly #(TCO_D + PCB)           u_boe  (.in(d_oe),    .out(foe_c));
    k65_dly #(TCO_D + PCB, 8, 8'hFF) u_bd   (.in(d_out),   .out(fd_c));
    k65_dly #(TCO_D + PCB)           u_birq (.in(irq_low), .out(irq_c));

    // ------------------------------------------------------------------ CPU (6502-sim)
    logic resb = 0;
    wire  [15:0] c_addr, c_ipc; wire [7:0] c_dout, c_opc, c_din;
    wire  c_rwb, c_doe, c_sync, c_vpb_n, c_valid, c_dummy, c_rdylow, c_unsup, c_wait, c_stop, rdy;
    wire  [63:0] c_cycle;
    w65c02s_cycle u_cpu (
        .phi2(phi2_c), .resb(resb), .irqb(!irq_c), .nmib(1'b1), .rdy_in(rdy), .data_in(c_din),
        .address(c_addr), .instruction_pc(c_ipc), .data_out(c_dout), .opcode(c_opc),
        .rwb(c_rwb), .data_oe(c_doe), .sync(c_sync), .vpb_n(c_vpb_n), .valid(c_valid), .dummy(c_dummy),
        .rdy_drive_low(c_rdylow), .unsupported(c_unsup), .waiting(c_wait), .stopped(c_stop),
        .cycle_number(c_cycle));

    logic [15:0] a_pin = 16'hFFFF; logic rw_pin = 1, a_valid = 1;
    logic [7:0]  cd_pin = 8'hFF;   logic coe_pin = 0, cd_valid = 0;
    always @(negedge phi2_c) begin
        #(T_AH);
        a_valid = 0; a_pin = ~a_pin; rw_pin = ~rw_pin;
        coe_pin = 0; cd_valid = 0;
        #(T_ADS - T_AH);
        a_pin = c_addr; rw_pin = c_rwb; a_valid = 1;
    end
    always @(posedge phi2_c) begin
        if (c_valid && !c_rwb) begin
            #5000; coe_pin = 1; cd_pin = ~c_dout;
            #(T_MDS - 5000); cd_pin = c_dout; cd_valid = 1;
        end
    end
    logic contention;
    w65c02s_bus_resolver u_bus (
        .cpu_data(cd_pin), .device_data(fd_c), .cpu_oe(coe_pin), .device_oe(foe_c),
        .external_rdy_low(1'b0), .cpu_rdy_low(c_rdylow),
        .data(c_din), .contention(contention), .rdy(rdy));

    // ------------------------------------------------------------------ board: CPU -> FPGA
    wire coe_f, a_valid_f, cd_valid_f;
    k65_dly #(PCB + TIN, 16, 16'hFFFF) u_ba  (.in(a_pin), .out(a_f));
    k65_dly #(PCB + TIN, 1, 1'b1)      u_brw (.in(rw_pin), .out(rw_f));
    k65_dly #(PCB + TIN, 8, 8'hFF)     u_bcd (.in(coe_pin ? cd_pin : 8'hFF), .out(d_f));
    k65_dly #(PCB + TIN, 1, 1'b1)      u_bav (.in(a_valid), .out(a_valid_f));
    k65_dly #(PCB + TIN)               u_bcv (.in(cd_valid), .out(cd_valid_f));
    k65_dly #(PCB)                     u_boef(.in(coe_pin), .out(coe_f));
    k65_dly #(PCB + TIN)               u_bsy (.in(c_sync), .out(sync_f));

    // ------------------------------------------------------------------ checks (as tb_cpu)
    integer errors = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 25) $display("[%0.3f us] ERROR: %s", $realtime / 1.0e6, msg);
    endtask
    always @(posedge contention) fail("data bus contention at the CPU pins (resolver)");
    always @(posedge clk) if (coe_f && d_oe) fail("data bus contention at the FPGA pins");
    always @(posedge clk) if (!rst && d_oe) begin
        if (!dut.rw_q && dut.ph >= T_DRV) fail("FPGA drives D during a write cycle");
        if (dut.ph >= D_HOLD && dut.ph < T_DRV) fail($sformatf("FPGA OE outside its window (ph=%0d)", dut.ph));
    end
    always @(posedge clk) if (!rst && mon_a_sample && !a_valid_f)
        fail($sformatf("address sampled outside its valid window (a=%04h)", a_f));
    always @(posedge clk) if (!rst && mon_w_capture && !rw_f && !cd_valid_f)
        fail("write data captured outside its valid window");
    logic [15:0] a_smp; logic rw_smp; logic smp_v = 0;
    always @(posedge clk) begin
        if (mon_a_sample) begin a_smp = a_f; rw_smp = rw_f; smp_v = 1; end
        else if (smp_v && phi2 && (a_f !== a_smp || rw_f !== rw_smp)) begin
            fail($sformatf("address/RWB changed at the FPGA while PHI2 high (%04h -> %04h)", a_smp, a_f));
            smp_v = 0;
        end
        if (!phi2 && dut.ph == 0) smp_v = 0;
    end
    always @(c_addr or c_rwb) if (phi2_c && resb) fail("CPU address/RWB changed while PHI2 high");
    always @(c_dout) if (phi2_c && resb && !c_rwb) fail("CPU write data changed while PHI2 high");
    always @(c_unsup) if (c_unsup) fail($sformatf("cycle model: unsupported opcode %02h at %04h", c_opc, c_ipc));
    always @(c_stop)  if (c_stop && resb) fail($sformatf("CPU executed STP at %04h", c_ipc));
    realtime t_edge = 0;
    always @(phi2_c) begin
        realtime w = $realtime - t_edge;
        if (t_edge > 0) begin
            if (phi2_c == 1'b0 && w < T_PWH) fail($sformatf("PHI2 high %0.1f ns < tPWH", w / 1000.0));
            if (phi2_c == 1'b1 && w < T_PWL) fail($sformatf("PHI2 low %0.1f ns < tPWL", w / 1000.0));
        end
        t_edge = $realtime;
    end
    realtime t_fd = 0, t_fall = 0; logic prev_rd = 0, cur_rd = 0; logic [15:0] cur_a = 0;
    realtime min_dsr = 1.0e12, min_dhr = 1.0e12;
    longint n_fd_ev = 0;
    always @(fd_c or foe_c) begin t_fd = $realtime; n_fd_ev++; end
    always @(posedge phi2_c) begin cur_rd = resb && c_valid && c_rwb; cur_a = c_addr; end
    always @(negedge phi2_c) begin
        t_fall = $realtime;
        prev_rd = 0;
        if (cur_rd) begin
            if (!foe_c) fail($sformatf("read %04h: FPGA not driving at PHI2 fall", cur_a));
            else if ($realtime - t_fd < min_dsr) min_dsr = $realtime - t_fd;
            if (foe_c && $realtime - t_fd < T_DSR)
                fail($sformatf("read %04h: setup %0.1f ns < tDSR", cur_a, ($realtime - t_fd) / 1000.0));
            prev_rd = 1;
        end
    end
    always @(fd_c or foe_c) if (prev_rd) begin
        if ($realtime - t_fall < min_dhr) min_dhr = $realtime - t_fall;
        if (($realtime - t_fall) < T_DHR) begin
            fail($sformatf("read data hold (tDHR) %0.1f ns", ($realtime - t_fall) / 1000.0)); prev_rd = 0;
        end
    end
    // console RX FIFO: overrun is an error (reported once); track the highest occupancy
    integer rxf_max = 0;
    always @(posedge dut.rx_ovr) if (!rst) fail("console RX FIFO overrun");
    always @(posedge clk) if (!rst && int'(dut.rxf_wp - dut.rxf_rp) > rxf_max) rxf_max = int'(dut.rxf_wp - dut.rxf_rp);

    // ------------------------------------------------------------------ accounting
    longint n_cyc = 0, n_instr = 0, n_pscyc = 0, n_psrd = 0, n_str = 0, str_clk = 0, n_wpdrop = 0;
    longint n_fetch_ps = 0, n_fetch = 0;
    longint op_cnt [0:255];
    integer hi_clk = 0, vec_ok = 0;
    string sig_seq = "";
    localparam integer STRETCH_MAX = 200;
    integer tf = 0; longint trace_max = 0;
    initial begin
        string fn;
        for (int i = 0; i < 256; i++) op_cnt[i] = 0;
        if ($value$plusargs("trace=%s", fn)) begin
            tf = $fopen(fn, "w");
            if (!$value$plusargs("trace_max=%d", trace_max)) trace_max = 1 << 30;
            $fwrite(tf, "time_ns,cycle,addr,data,rwb,sync,region,phi2_high_ns\n");
        end
    end
    always @(posedge clk) if (!rst) begin
        if (phi2) hi_clk++;
        if (phi2 && hi_clk > STRETCH_MAX) begin
            fail("read timeout: PHI2 held high > 200 sysclk"); hi_clk = -1000000;
            finish_checks();
        end
        if (dut.cyc_end) begin
            logic [7:0] dat; logic st; string reg_s;
            dat = dut.rw_q ? dut.d_out : dut.wdata_q;
            st = (hi_clk > NOM_HI);
            if (resb) begin
                n_cyc++;
                if (dut.sel_ps) begin n_pscyc++; if (dut.rw_q) n_psrd++; else if (dut.wp_hit) n_wpdrop++; end
                if (st) begin
                    n_str++; str_clk += hi_clk - NOM_HI;
                    if (!dut.sel_ps) fail($sformatf("PHI2 stretched on a non-PSRAM cycle (%04h)", dut.a_q));
                end
                if (c_rwb && !c_vpb_n && dut.a_q == 16'hFFFD) vec_ok = 1;
                if (c_sync && rdy && !c_dummy) begin
                    n_instr++; op_cnt[dat]++; n_fetch++;
                    if (dut.sel_ps) n_fetch_ps++;
                end
                if (!dut.rw_q && dut.a_q == 16'hD003) sig_seq = {sig_seq, $sformatf("%02h ", dat)};
                if (tf != 0 && n_cyc <= trace_max) begin
                    reg_s = dut.sel_ram ? "fast" : dut.sel_rom ? "rom" : dut.sel_ps ? "psram" : dut.sel_io ? "io" : "none";
                    $fwrite(tf, "%0.1f,%0d,%04h,%02h,%0d,%0d,%s,%0.1f\n", $realtime / 1000.0, n_cyc, dut.a_q, dat,
                            dut.rw_q, c_sync, reg_s, hi_clk * SYS_PS / 1000.0);
                end
            end
            hi_clk = 0;
        end
    end

    // performance marks: MARK <name> elapsed since the previous mark
    typedef struct { longint t, c, i, p, r, s, sc, f, fp; } snap_t;
    snap_t mk;
    task automatic mark(input string name);
        $display("MARK %-10s t_us=%0.1f cycles=%0d instr=%0d ps_cycles=%0d ps_reads=%0d stretch_n=%0d stretch_us=%0.1f fetch=%0d fetch_ps=%0d",
                 name, ($time - mk.t) / 1.0e6, n_cyc - mk.c, n_instr - mk.i, n_pscyc - mk.p, n_psrd - mk.r,
                 n_str - mk.s, (str_clk - mk.sc) * SYS_PS / 1.0e6, n_fetch - mk.f, n_fetch_ps - mk.fp);
        mk = '{$time, n_cyc, n_instr, n_pscyc, n_psrd, n_str, str_clk, n_fetch, n_fetch_ps};
    endtask

    // ------------------------------------------------------------------ PSRAM preload (image already loaded)
    initial begin
        if (PS_HEX != "" && !$test$plusargs("load_over_uart") && !$test$plusargs("no_image")) begin : preload
            logic [7:0] img [0:65535];
            int base, e;
            for (int i = 0; i < 65536; i++) img[i] = 8'h00;
            $readmemh(PS_HEX, img);
            base = 'h9800;
            if (img[base] != "K") begin fail("PS_HEX: no image at $9800"); disable preload; end
            e = {img[base + 11], img[base + 10]};
            for (int a = base; a < e; a++) u_psram.mem[a] = img[a];
            $display("PSRAM preloaded with the BASIC image $%04h-$%04h (%0d bytes) from %s", base, e - 1, e - base, PS_HEX);
        end
    end

    // ------------------------------------------------------------------ RESB (the XIAO)
    initial begin : resb_ctl
        wait (mon_ready);
        repeat (8) @(negedge phi2_c);
        $display("[%0.3f us] RESB released after READY", $realtime / 1.0e6);
        #(T_AH * 2);
        resb = 1;
        mk = '{$time, n_cyc, n_instr, n_pscyc, n_psrd, n_str, str_clk, n_fetch, n_fetch_ps};
    end

    // ------------------------------------------------------------------ terminal on the console UART
    string con_all = "", con_line = "";
    integer con_mark = 0;                       // con_all index where the current expectation starts
    initial forever begin : term_rx
        logic [7:0] b;
        @(negedge con_tx);
        #(BIT_PS / 2);
        if (con_tx) continue;                   // glitch
        for (int i = 0; i < 8; i++) begin #(BIT_PS); b[i] = con_tx; end
        #(BIT_PS);
        if (!con_tx) fail("console TX framing error");
        con_all = {con_all, $sformatf("%c", b)};
        if (b == 8'h0A) begin
            $display("[%0.3f ms] CON> %s", $realtime / 1.0e9, con_line);
            con_line = "";
        end else if (b != 8'h0D) con_line = {con_line, $sformatf("%c", b)};
    end
    task automatic send_byte(input logic [7:0] b);
        con_rx = 0; #(BIT_PS);
        for (int i = 0; i < 8; i++) begin con_rx = b[i]; #(BIT_PS); end
        con_rx = 1; #(BIT_PS);
    endtask
    task automatic send(input string s);
        for (int i = 0; i < s.len(); i++) send_byte(s.getc(i));
    endtask
    function automatic integer find_from(input string hay, input string needle, input integer from);
        for (int i = from; i + needle.len() <= hay.len(); i++)
            if (hay.substr(i, i + needle.len() - 1) == needle) return i;
        return -1;
    endfunction
    // wait until 'needle' appears after con_mark; then move con_mark past it
    task automatic expect_out(input string needle, input longint timeout_us);
        longint t0 = $time; integer k;
        forever begin
            k = find_from(con_all, needle, con_mark);
            if (k >= 0) begin con_mark = k + needle.len(); return; end
            if ($time - t0 > timeout_us * 1000000) begin
                fail($sformatf("timeout waiting for console output \"%s\"", needle));
                finish_checks();
            end
            #(BIT_PS);
        end
    endtask
    // type a line: wait for the CR LF that MS BASIC prints after RETURN
    task automatic type_line(input string s);
        send({s, "\r"});
        expect_out({s, "\r\n"}, 200000);
    endtask

    // ------------------------------------------------------------------ video checks
    // Expected picture of the "vdp" script (logical 320 x 180; palette 0 = ZX colours):
    //   border lines 0,1,178,179: palette index exp_border
    //   tile (0,0) and tile (39,21): pattern 1 = colour 7 (white)
    //   sprites 16x16 pattern 2..5 = colour 4 (green) at x,y = (-4,100), (316,-4), (150,172)
    //   everything else: backdrop = palette entry 0 (black)
    logic [15:0] t_pal [0:511];
    initial $readmemh("../rtl/vdp_palette.hex", t_pal);
    function automatic [23:0] rgb565(input [15:0] v);
        return {v[15:11], v[15:13], v[10:5], v[10:9], v[4:0], v[4:2]};
    endfunction
    logic [3:0] exp_border = 4'd0;
    function automatic [7:0] exp_index(input int lx, input int ly);
        int sy = ly - 2;
        if (ly < 2 || ly >= 178) return {4'd0, exp_border};
        if ((lx >= -4 && lx <= 11 && sy >= 100 && sy <= 115) || (lx >= 316 && lx <= 331 && sy >= -4 && sy <= 11) ||
            (lx >= 150 && lx <= 165 && sy >= 172 && sy <= 187)) return 8'd4;
        if ((lx < 8 && sy < 8) || (lx >= 312 && sy >= 168)) return 8'd7;
        return 8'd0;
    endfunction
    int frame_no = 0, cmp_frame = -1, frames_compared = 0, n_cmp = 0, n_bad = 0;
    int fr_clk = 0, n_frame_period_bad = 0, n_mixed_border = 0;
    logic [23:0] brd_first; logic brd_seen = 0, brd_mixed = 0;
    always @(posedge clk_pix) if (!rst_pix) begin
        fr_clk++;
        if (cx == 0 && cy == 0) begin
            if (frame_no >= 2 && fr_clk != 1650 * 750) begin n_frame_period_bad++; fail($sformatf("frame period %0d clocks", fr_clk)); end
            fr_clk = 0;
        end
    end
    always @(negedge clk_pix) if (!rst_pix) begin
        int X, Y;
        if (cx == 0) begin X = 1649; Y = (cy == 0) ? 749 : cy - 1; end else begin X = cx - 1; Y = cy; end
        if (cx == 0 && cy == 0) begin
            if (frame_no == cmp_frame) frames_compared++;
            if (brd_mixed) n_mixed_border++;
            frame_no++; brd_seen = 0; brd_mixed = 0;
        end
        if (X < 1280 && Y < 720) begin
            int lx = X >> 2, ly = Y >> 2;
            if (ly < 2 || ly >= 178) begin               // border constant within a frame (frame latch)
                if (!brd_seen) begin brd_first = rgb; brd_seen = 1; end
                else if (rgb !== brd_first && !brd_mixed) begin
                    brd_mixed = 1; fail($sformatf("border colour changed inside frame %0d", frame_no));
                end
            end
            if (frame_no == cmp_frame) begin
                logic [23:0] e = rgb565(t_pal[exp_index(lx, ly)]);
                n_cmp++;
                if (rgb !== e) begin
                    n_bad++;
                    if (n_bad <= 12) fail($sformatf("frame %0d pixel (%0d,%0d) logical (%0d,%0d): rgb %06h expected %06h",
                                                    frame_no, X, Y, lx, ly, rgb, e));
                end
            end
        end
    end

    // ------------------------------------------------------------------ audio model (AUDIO=1, script "aud")
    // Register values come from snooping the core's external bus (x_wr / x_page / x_addr /
    // x_wd), not from k65_audio. COMMIT takes effect at the first tick after the copy
    // (mon_apply). The generator state (phases, LFSR, COUNT, wave phases) is taken from the
    // DUT ONCE at the sync point; after that every sample is predicted and compared.
    logic [23:0] ms_step [4], mc_step [4], ma_step [4];
    logic [7:0]  ms_duty [4], mc_duty [4], ma_duty [4], ms_vol [4], mc_vol [4], ma_vol [4];
    logic [7:0]  ms_mvol = 8'd32, mc_mvol = 8'd32, ma_mvol = 8'd32;
    logic [15:0] ms_per = 0, mc_per = 0, ma_per = 0;
    logic [3:0]  ms_en = 0, mc_en = 0, ma_en = 0, ms_prst = 0, mc_prst = 0, ma_rst = 0;
    bit          mc_wait = 0;
    logic [23:0] w_inc [2]; logic [7:0] w_vol [2]; logic [1:0] w_en = 0; logic [7:0] w_mem [2][256];
    logic [16:0] w_vaddr = 0; logic [7:0] w_vinc = 1, w_hold = 0;
    logic [23:0] m_ph [3], m_wph [2]; logic [14:0] m_lfsr; logic [15:0] m_cnt;
    bit aud_sync_req = 0, aud_on = 0, aud_skip = 0;
    logic [31:0] aud_q [$];
    int aud_cmp = 0, aud_bad = 0, aud_ticks = 0, aud_nonzero = 0;
    initial for (int c = 0; c < 4; c++) begin ms_step[c] = 0; ms_duty[c] = 0; ms_vol[c] = 0; ma_step[c] = 0; ma_duty[c] = 0; ma_vol[c] = 0; end
    initial for (int c = 0; c < 2; c++) begin w_inc[c] = 0; w_vol[c] = 0; for (int i = 0; i < 256; i++) w_mem[c][i] = 0; end
    always @(posedge clk) if (!rst && x_wr) begin
        if (x_page == 4'h4 && x_addr[7:5] == 3'd0) begin
            int c = x_addr[4:3];
            if (x_addr[4:3] != 2'd3) case (x_addr[2:0])
                3'd0: ms_step[c][7:0] = x_wd; 3'd1: ms_step[c][15:8] = x_wd; 3'd2: ms_step[c][23:16] = x_wd;
                3'd3: ms_duty[c] = x_wd; 3'd4: ms_vol[c] = x_wd; default: ;
            endcase else case (x_addr[2:0])
                3'd0: ms_per[7:0] = x_wd; 3'd1: ms_per[15:8] = x_wd; 3'd2: ms_vol[3] = x_wd; 3'd3: ms_mvol = x_wd;
                3'd4: ms_en = x_wd[3:0]; 3'd5: ms_prst = x_wd[3:0];
                3'd7: begin mc_step = ms_step; mc_duty = ms_duty; mc_vol = ms_vol; mc_mvol = ms_mvol; mc_per = ms_per;
                            mc_en = ms_en; mc_prst = ms_prst; ms_prst = 0; mc_wait = 1; end
                default: ;
            endcase
        end
        if (x_page == 4'h3 && x_addr[7:6] == 2'b00) case (x_addr[5:0])
            6'd0: w_vaddr[7:0] = x_wd; 6'd1: w_vaddr[15:8] = x_wd; 6'd2: w_vaddr[16] = x_wd[0]; 6'd4: w_vinc = x_wd;
            6'd3: begin
                if (w_vaddr >= 17'h09A00 && w_vaddr <= 17'h09BFF) begin
                    if (!w_vaddr[0]) w_hold = x_wd;
                    else begin w_mem[w_vaddr[8]][{w_vaddr[7:1], 1'b0}] = w_hold; w_mem[w_vaddr[8]][w_vaddr[7:0]] = x_wd; end
                end
                w_vaddr = w_vaddr + 17'(w_vinc);
            end
            6'd16: w_inc[0][7:0] = x_wd; 6'd17: w_inc[0][15:8] = x_wd; 6'd18: w_inc[0][23:16] = x_wd; 6'd19: w_vol[0] = x_wd;
            6'd20: w_inc[1][7:0] = x_wd; 6'd21: w_inc[1][15:8] = x_wd; 6'd22: w_inc[1][23:16] = x_wd; 6'd23: w_vol[1] = x_wd;
            6'd24: w_en = x_wd[1:0];
            default: ;
        endcase
    end
    function automatic logic [15:0] aud_clamp(input int a, input logic [7:0] mv);
        int g = (a * int'(mv)) >>> 4;
        return (g > 32767) ? 16'h7FFF : (g < -32768) ? 16'h8000 : 16'(g);
    endfunction
    always @(posedge clk_pix) if (!rst_pix) begin
        if (au_apply && mc_wait) begin           // the copy happened at the previous edge
            ma_step = mc_step; ma_duty = mc_duty; ma_vol = mc_vol; ma_mvol = mc_mvol; ma_per = mc_per; ma_en = mc_en;
            ma_rst = mc_prst; mc_wait = 0;
        end
        if (t_tick && aud_on) begin
            logic signed [7:0] v [6]; int al = 0, ar = 0;
            aud_ticks++;
            for (int c = 0; c < 3; c++) begin
                logic [23:0] pe = ma_rst[c] ? 24'd0 : m_ph[c];
                if (ma_en[c]) begin
                    v[c] = (ma_step[c] == 0 || ma_duty[c] == 0) ? 8'sd0 : (pe[23:16] < ma_duty[c]) ? 8'sd127 : -8'sd127;
                    m_ph[c] = pe + ma_step[c];
                end else begin v[c] = 0; m_ph[c] = pe; end
            end
            begin
                logic [14:0] le = ma_rst[3] ? 15'd1 : m_lfsr; logic [15:0] ce = ma_rst[3] ? ma_per : m_cnt;
                if (ma_en[3]) begin
                    v[3] = le[14] ? 8'sd127 : -8'sd127;
                    if (ce == 0) begin m_lfsr = {le[13:0], le[14] ^ le[13]}; m_cnt = ma_per; end
                    else begin m_lfsr = le; m_cnt = ce - 1; end
                end else begin v[3] = 0; m_lfsr = le; m_cnt = ce; end
            end
            for (int c = 0; c < 2; c++) begin
                m_wph[c] = w_en[c] ? m_wph[c] + w_inc[c] : 24'd0;
                v[4 + c] = w_en[c] ? $signed(w_mem[c][m_wph[c][23:16]]) : 8'sd0;
            end
            for (int c = 0; c < 6; c++) begin
                logic [7:0] vol = (c < 4) ? ma_vol[c] : w_vol[c - 4];
                al += int'(v[c]) * int'(vol[7:4]); ar += int'(v[c]) * int'(vol[3:0]);
            end
            aud_q.push_back({aud_clamp(ar, ma_mvol), aud_clamp(al, ma_mvol)});
        end
        if (t_tick) ma_rst = 0;
    end
    // sync point: at a tick edge, take the generator state from the DUT once (after that edge)
    always @(posedge clk_pix) if (!rst_pix && aud_sync_req && t_tick) begin
        #1;
        for (int c = 0; c < 3; c++) m_ph[c] = u_aud.ph[c];
        m_lfsr = u_aud.lfsr; m_cnt = u_aud.ncnt; m_wph[0] = u_vdp.ph0; m_wph[1] = u_vdp.ph1;
        aud_q.delete(); aud_skip = 1; aud_on = 1; aud_sync_req = 0;
        $display("[%0.3f us] AUD: model synchronised (ph0 %06h ph1 %06h lfsr %04h wave ph0 %06h)", $realtime / 1.0e6, m_ph[0], m_ph[1], m_lfsr, m_wph[0]);
    end
    // produced -> compared with the model; produced -> accepted by HDMI (same order, nothing lost / repeated)
    logic [31:0] prod_q [$]; int n_prod = 0, n_acc = 0; logic lg_prev = 0;
    always @(negedge clk_pix) if (!rst_pix) begin
        if (AUDIO ? au_mix : (lg_valid && !lg_prev)) begin prod_q.push_back(s_data); n_prod++; end
        lg_prev = lg_valid;
        if (AUDIO && aud_on && au_mix) begin
            if (aud_skip) aud_skip = 0;          // the sample of the sync tick (computed before the sync)
            else if (aud_q.size() == 0) fail("AUD: DUT sample without a model sample");
            else begin
                logic [31:0] e = aud_q.pop_front();
                aud_cmp++;
                if (au_data != 0) aud_nonzero++;
                if (au_data !== e) begin aud_bad++; if (aud_bad <= 10) fail($sformatf("AUD: sample #%0d = %08h, model %08h", aud_cmp, au_data, e)); end
            end
        end
        if (s_valid && s_ready) begin
            n_acc++;
            if (prod_q.size() == 0) fail("HDMI accepted a sample that was not produced");
            else begin logic [31:0] p = prod_q.pop_front(); if (p !== s_data) fail($sformatf("HDMI accepted %08h, produced %08h (dropped / repeated)", s_data, p)); end
        end
    end

    // ------------------------------------------------------------------ dialogue scripts
    string script = "poc";
    integer checks_done = 0;
    initial begin : dialogue
        string memsize;
        void'($value$plusargs("script=%s", script));
        if (!$value$plusargs("memsize=%s", memsize)) memsize = "";
        wait (resb);
        if (script == "noimg") begin
            expect_out("NO BASIC IMAGE - LOADER READY\r\n", 200000);
            mark("bios_noimg");
            checks_done = 1;
            finish_checks();
        end
        if ($test$plusargs("load_over_uart")) begin : uart_load
            integer fd, c;
            expect_out("NO BASIC IMAGE - LOADER READY\r\n", 200000);
            mark("bios_noimg");
            fd = $fopen(FRAME, "rb");
            if (fd == 0) begin fail({"cannot open ", FRAME}); finish_checks(); end
            begin
                // frame = 'L' addr len data sum 'B': send everything except the final 'B'
                // (the data itself may contain $42, so the length decides, not the value)
                logic [7:0] fb [$];
                c = $fgetc(fd);
                while (c >= 0) begin fb.push_back(c[7:0]); c = $fgetc(fd); end
                if (fb.size() < 8 || fb[fb.size() - 1] != 8'h42) fail("loader frame does not end with 'B'");
                for (int i = 0; i < fb.size() - 1; i++) send_byte(fb[i]);
            end
            expect_out("OK\r\n", 100000);
            mark("uart_load");
            send_byte(8'h42);                      // 'B': check the image and start BASIC
            $fclose(fd);
        end
        expect_out("MEMORY SIZE? ", 200000);
        mark("boot");
        if (memsize == "") send("\r"); else send({memsize, "\r"});
        expect_out("TERMINAL WIDTH? ", 5000000);
        mark("memsize");
        send("\r");
        expect_out(" BYTES FREE", 200000);
        expect_out("OK\r\n", 200000);
        mark("ready");
        if (script == "poc") begin
            type_line("PRINT 1+1");
            expect_out(" 2 \r\n", 200000);
            expect_out("OK\r\n", 200000);
            mark("print");
            type_line("10 FOR I=1 TO 10");
            type_line("20 PRINT I");
            type_line("30 NEXT I");
            mark("enter");
            type_line("RUN");
            for (int i = 1; i <= 10; i++) expect_out($sformatf(" %0d \r\n", i), 200000);
            expect_out("OK\r\n", 200000);
            mark("run");
            type_line("LIST");
            expect_out("10 FOR I=1 TO 10\r\n", 200000);
            expect_out("20 PRINT I\r\n", 200000);
            expect_out("30 NEXT I\r\n", 200000);
            expect_out("OK\r\n", 200000);
            mark("list");
            type_line("NEW");
            expect_out("OK\r\n", 200000);
            begin
                integer k0;
                type_line("LIST");
                k0 = con_mark;                   // just after the echoed "LIST" CR LF
                expect_out("OK\r\n", 200000);
                // between the echo and OK only CR / LF may appear (no program line)
                for (int i = k0; i < con_mark - 4; i++)
                    if (con_all.getc(i) != 8'h0D && con_all.getc(i) != 8'h0A) begin
                        fail($sformatf("LIST after NEW printed something: \"%s\"", con_all.substr(k0, con_mark - 1)));
                        break;
                    end
            end
            mark("new");
            // PSRAM write protect: POKE into the interpreter must not change it
            begin
                logic [7:0] v0; longint d0;
                v0 = u_psram.rd8('h9C00); d0 = n_wpdrop;
                type_line("POKE 39936,0:PRINT PEEK(39936)");
                expect_out($sformatf(" %0d \r\n", v0), 200000);
                expect_out("OK\r\n", 200000);
                if (u_psram.rd8('h9C00) != v0 || v0 == 0) fail("write protect: interpreter byte changed (or test byte is 0)");
                if (n_wpdrop == d0) fail("write protect: no dropped PSRAM write counted");
            end
            mark("wp");
            checks_done = 1;
        end else if (script == "vdp") begin
            // BASIC drives the VDP through POKE / PEEK only (no extension keywords)
            type_line("10 V=54016:POKE V+7,2");
            type_line("20 POKE V,32:POKE V+1,0:POKE V+2,0");
            type_line("30 FOR I=1 TO 32:POKE V+3,119:NEXT");
            type_line("40 FOR I=1 TO 128:POKE V+3,68:NEXT");
            type_line("50 POKE V,0:POKE V+1,128:POKE V+2,0:POKE V+3,1:POKE V+3,0");
            type_line("60 POKE V,206:POKE V+1,138:POKE V+3,1:POKE V+3,0");
            type_line("70 POKE V,0:POKE V+1,144:FOR I=0 TO 23:READ D:POKE V+3,D:NEXT");
            type_line("80 POKE 53251,90");
            type_line("90 DATA 116,192,12,0,2,0,0,0,12,192,76,1,2,0,0,0");
            type_line("100 DATA 188,192,166,0,2,0,0,0");
            mark("enter");
            type_line("RUN");
            expect_out("OK\r\n", 3000000);
            mark("vdp_run");
            if (mon_sig != 8'h5A) fail("BASIC program did not reach line 80");
            // register read-back through the core's $D3xx window
            type_line("PRINT PEEK(V+13)*256+PEEK(V+12)");
            expect_out($sformatf(" %0d \r\n", NPAT), 200000);
            expect_out("OK\r\n", 200000);
            type_line("POKE V,32:POKE V+1,0:POKE V+2,0:PRINT PEEK(V+3);PEEK(V+3)");
            expect_out(" 119  119 \r\n", 200000);
            expect_out("OK\r\n", 200000);
            mark("vdp_peek");
            if ($test$plusargs("fault_nospr")) force u_vdp.ctrl[1] = 1'b0;   // negative test: sprites disabled
            // compare the whole next frame (border = palette 0 index 2)
            exp_border = 4'd2;
            begin int f0 = frame_no; wait (frame_no == f0 + 1); cmp_frame = frame_no + 1; wait (frame_no == cmp_frame + 1); end
            mark("frame1");
            // border change, frame-latched: one frame later the border must be index 4
            type_line("POKE V+7,4:POKE 53251,91");
            expect_out("OK\r\n", 200000);
            exp_border = 4'd4;
            begin int f0 = frame_no; wait (frame_no == f0 + 2); cmp_frame = frame_no; wait (frame_no == cmp_frame + 1); end
            mark("frame2");
            checks_done = (frames_compared == 2) ? 1 : 0;
        end else if (script == "aud") begin
            // BASIC programs all six channels with POKE only (AUD-003 registers at $D400 = 54272)
            //  pulse0 440 Hz (STEP 153791) duty 1/2 vol L15 R15; pulse1 1000 Hz (349525) duty 1/4 vol L15
            //  noise PERIOD 3 vol L8 R8; ENABLE p0 p1 noise (11); PRST all; COMMIT
            //  wave0: sawtooth 0..255 (VRAM $09A00), INC $012345, vol L5 R10, ACTRL ch0
            // (lines <= 40 characters: the 64-byte console RX FIFO must not overflow while
            //  BASIC is still storing the previous line in PSRAM)
            type_line("10 A=54272:V=54016");
            type_line("20 POKE A,191:POKE A+1,88:POKE A+2,2");
            type_line("22 POKE A+3,128:POKE A+4,255");
            type_line("30 POKE A+8,85:POKE A+9,85:POKE A+10,5");
            type_line("32 POKE A+11,64:POKE A+12,240");
            type_line("40 POKE A+24,3:POKE A+25,0:POKE A+26,136");
            type_line("42 POKE A+28,11:POKE A+29,15:POKE A+31,0");
            type_line("50 POKE V,0:POKE V+1,154:POKE V+2,0");
            type_line("52 FOR I=0 TO 255:POKE V+3,I:NEXT");
            type_line("60 POKE V+16,69:POKE V+17,35:POKE V+18,1");
            type_line("62 POKE V+19,90:POKE V+24,1");
            type_line("70 POKE 53251,90");
            mark("enter");
            type_line("RUN");
            expect_out("OK\r\n", 3000000);
            mark("aud_setup");
            if (mon_sig != 8'h5A) fail("BASIC program did not reach line 70");
            type_line("PRINT PEEK(A+30);PEEK(A+27);PEEK(A+28);PEEK(A)");
            expect_out(" 0  32  11  191 \r\n", 200000);
            expect_out("OK\r\n", 200000);
            // from here on, every sample is predicted by the model
            aud_sync_req = 1; wait (aud_on);
            begin
                longint s0 = n_str, p0 = n_pscyc;
                type_line("NEW");
                expect_out("OK\r\n", 200000);
                type_line("10 DIM B(60):S=0");
                type_line("20 FOR I=1 TO 60:B(I)=I*3:NEXT");
                type_line("30 FOR I=1 TO 60:S=S+B(I):NEXT");
                type_line("40 PRINT S:PRINT PEEK(54302)");
                type_line("RUN");
                expect_out(" 5490 \r\n", 3000000);
                expect_out(" 0 \r\n", 200000);
                expect_out("OK\r\n", 200000);
                mark("aud_run");
                $display("AUD: %0d samples compared over %0d ticks (non-zero %0d, mismatches %0d); PHI2 stretches during the window %0d, PSRAM cycles %0d",
                         aud_cmp, aud_ticks, aud_nonzero, aud_bad, n_str - s0, n_pscyc - p0);
                if (n_str - s0 < 1000) fail("AUD: too few PHI2 stretches during the compared window");
                if (aud_cmp < 4000) fail("AUD: too few samples compared");
                if (aud_nonzero < aud_cmp / 2) fail("AUD: output mostly silent");
                if (au_drops != 0) fail($sformatf("AUD: %0d samples dropped", au_drops));
                checks_done = (aud_bad == 0) ? 1 : 0;
            end
        end else if (script == "bench") begin
            // interpreter-bound benchmark: no console output inside the loop
            type_line("10 A=0");
            type_line("20 FOR I=1 TO 200");
            type_line("30 A=A+I*I/7");
            type_line("40 NEXT I");
            type_line("50 PRINT A");
            mark("enter");
            type_line("RUN");
            mark("bench_start");
            expect_out("\r\nOK\r\n", 2000000);
            mark("bench_run");
            checks_done = 1;
        end
        finish_checks();
    end

    initial begin
        #(longint'(MAX_US) * 1000000);
        fail("simulation time limit");
        finish_checks();
    end

    task automatic finish_checks();
        integer nop = 0;
        $display("---- summary SYS_PS=%0d CYC=%0d (CPU %0.5f MHz) FAST=%0d ROM=%0d script=%s",
                 SYS_PS, CYC, 1.0e6 / (CYC * SYS_PS), FAST, ROMB, script);
        $display("SIG sequence: %s", sig_seq);
        for (int i = 0; i < 256; i++) if (op_cnt[i] != 0) nop++;
        $display("CPU: cycles=%0d instr=%0d distinct_opcodes=%0d psram_cycles=%0d (reads %0d, wp-dropped writes %0d) stretched=%0d (%0.1f us) model_cycle=%0d",
                 n_cyc, n_instr, nop, n_pscyc, n_psrd, n_wpdrop, n_str, str_clk * SYS_PS / 1.0e6, c_cycle);
        $display("CPU pins: min read setup %0.1f ns (tDSR 15), min read hold %0.1f ns (tDHR 10); checker events %0d",
                 min_dsr / 1000.0, min_dhr / 1000.0, n_fd_ev);
        $display("PSRAM model: reads=%0d writes=%0d reg=%0d maxCS=%0d errors=%0d; FPGA monitor: vec=%04h boot_ok=%0d bus_err=%0d",
                 u_psram.n_rd, u_psram.n_wr, u_psram.n_reg, u_psram.max_cs, u_psram.errors,
                 mon_vec, mon_boot_ok, mon_bus_err);
        begin
            string ops = "";
            for (int i = 0; i < 256; i++) if (op_cnt[i] != 0) ops = {ops, $sformatf("%02h ", i)};
            $display("opcodes executed: %s", ops);
        end
        $display("console RX FIFO: max occupancy %0d of %0d bytes", rxf_max, 1 << dut.RXF_LOG2);
        $display("VDP: NPAT=%0d frames=%0d compared=%0d pixels=%0d mismatches=%0d frame-period errors=%0d mixed-border frames=%0d render max=%0d sysclk overrun=%0d",
                 NPAT, frame_no, frames_compared, n_cmp, n_bad, n_frame_period_bad, n_mixed_border, vdp_rmax, vdp_ovr);
        if (script == "vdp" && (frames_compared != 2 || n_cmp != 2 * 1280 * 720)) fail("VDP frames not compared completely");
        if (vdp_ovr) fail("VDP render overrun");
        $display("%s", u_amon.summary());
        $display("%s", u_pwmc.summary());
        $display("AUDIO=%0d: samples produced %0d, accepted by HDMI %0d", AUDIO, n_prod, n_acc);
        if (u_amon.errors) fail("HDMI audio monitor errors");
        if (u_pwmc.errors) fail("PWM check errors");
        if (n_prod - n_acc > 1 || n_acc < 100) fail("samples produced / accepted do not match");
        if (n_fd_ev == 0) fail("tDSR checker saw no events");
        if (u_psram.errors != 0) fail("PSRAM model reported protocol errors");
        if (!vec_ok || mon_vec != (ROMB == 4096 ? 16'hF000 : 16'hF800) || !mon_boot_ok)
            fail("reset vector fetch (VPB, first fetch at the BIOS start) not seen");
        if (mon_bus_err) fail("FPGA monitor: unmapped access");
        if (!checks_done) fail("dialogue script did not complete");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        if (tf != 0) $fclose(tf);
        $finish;
    endtask
endmodule
