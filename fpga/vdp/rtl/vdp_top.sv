// KAGURA-6502 integrated top: BASIC platform (k65_basic_core, 8 KiB fast RAM, BIOS,
// PSRAM) + VDP (k65_vdp: 320x176 tiles/sprites, border, palette/wave, HDMI audio).
// Derived from fpga/basic/rtl/basic_top.sv; the status screen and the test tone are
// replaced by the VDP. The core's $D300-$D3FF window (EXT_EN=1) is the VDP register set.
// Build options (`define, see fpga/vdp/syn): K65_NPAT, K65_PAT_FLAT, K65_SHARE_PW, K65_OAM_DBL.
//
// Inherited description (Phase 2):
//   rPLL#2 (system): 27 * 2 = 54 MHz CLKOUT -> CPU bus engine, PSRAM controller, I/O
//                    CLKOUTP = same 54 MHz shifted 67.5 deg (PSDA 3) -> PSRAM CK
//                    (KAGURA-9 hardware-measured centre of the 22.5..112.5 deg window)
//   rPLL#1 (video) : 371.25 MHz serial, CLKDIV /5 -> 74.25 MHz pixel -> HDMI + status screen
// Only crossing system -> pixel: quasi-static status bits for the status screen,
// through 2-FF synchronisers (display only; a multi-bit value may tear for one frame).
// PSRAM: die 0 via KAGURA-9 kagura_hyperram_ctrl + kagura_hyperram_phy_gowin
// (production wiring: PHY output enables from the widened phy_*_tx windows).
`ifndef K65_CYC
`define K65_CYC 16
`endif
`ifndef K65_FAST
`define K65_FAST 8192
`endif
`ifndef K65_ROMB
`define K65_ROMB 2048
`endif
`ifndef K65_ROMHEX
`define K65_ROMHEX "../../basic/sw/bios2k_vdp.hex"
`endif
`ifndef K65_NPAT
`define K65_NPAT 1024
`endif
`ifndef K65_PAT_FLAT
`define K65_PAT_FLAT 0
`endif
`ifndef K65_SHARE_PW
`define K65_SHARE_PW 1
`endif
`ifndef K65_OAM_DBL
`define K65_OAM_DBL 0
`endif
`ifndef K65_PAL256HEX
`define K65_PAL256HEX "../rtl/vdp_palette256.hex"
`endif
`ifndef K65_PALHEX
`define K65_PALHEX "../rtl/vdp_palette.hex"
`endif
// K65_AUDIO 1 (fpga/audio): core window $D300-$D4FF (EXT_EN=2), k65_audio at $D400-$D41F
// (pulse 0-2, noise, 6-channel mixer) drives the HDMI samples and the PWM pins; k65_vdp
// keeps the wave channels and the 48 kHz tick. K65_AUDIO 0: the VDP-only build as before.
`ifndef K65_AUDIO
`define K65_AUDIO 0
`endif
module vdp_top #(
    parameter integer CYC  = `K65_CYC,          // 16: 3.375 MHz (54: 1.000, 27: 2.000)
    parameter integer FAST = `K65_FAST,         // fast RAM bytes
    parameter integer ROMB = `K65_ROMB          // Boot ROM bytes (4096 / 2048)
) (
    input  wire        clk27,
    input  wire [15:0] cpu_a,
    inout  wire [7:0]  cpu_d,
    input  wire        cpu_rwb,
    output wire        cpu_phi2,
    inout  wire        cpu_irqb,
    input  wire        cpu_sync_1v8,
    output wire        xiao_tx,
    input  wire        xiao_rx,
    output wire        bl_uart_tx,
    input  wire        bl_uart_rx,
    output wire        aud_pwm_l,
    output wire        aud_pwm_r,
    input  wire        user_btn_n,
    input  wire [1:0]  btn_n,
    output wire [5:0]  led_n,
    output wire [3:0]  dbg,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,
    // embedded PSRAM (SiP pads, names fixed by Gowin)
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    inout  wire [1:0]  IO_psram_rwds,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    output wire [1:0]  O_psram_cs_n
);
    // ------------------------------------------------------------------ clocks
    wire clk_sys, clk_ck, sys_lock;
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW1NR-9C"),
        .IDIV_SEL(0), .FBDIV_SEL(1), .ODIV_SEL(8),      // 27 * 2 = 54 MHz, VCO 432 MHz
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .DYN_SDIV_SEL(2), .PSDA_SEL("0011"), .DUTYDA_SEL("1000"), .DYN_DA_EN("false"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
    ) u_pll_sys (
        .CLKOUT(clk_sys), .LOCK(sys_lock), .CLKOUTP(clk_ck), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
    wire clk_ser, vid_lock, clk_pix;
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW1NR-9C"),
        .IDIV_SEL(3), .FBDIV_SEL(54), .ODIV_SEL(2),     // 27 * 55 / 4 = 371.25 MHz
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .DYN_SDIV_SEL(2), .PSDA_SEL("0000"), .DUTYDA_SEL("1000"), .DYN_DA_EN("false"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
    ) u_pll_vid (
        .CLKOUT(clk_ser), .LOCK(vid_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) u_div (
        .HCLKIN(clk_ser), .RESETN(vid_lock), .CALIB(1'b0), .CLKOUT(clk_pix)
    );
    wire locks = sys_lock && vid_lock;
    GSR u_gsr (.GSRI(locks));                 // not from a fabric register

    reg [15:0] rst_sys_sr = 16'hFFFF, rst_pix_sr = 16'hFFFF;
    always @(posedge clk_sys or negedge locks)
        if (!locks) rst_sys_sr <= 16'hFFFF; else rst_sys_sr <= {rst_sys_sr[14:0], 1'b0};
    always @(posedge clk_pix or negedge locks)
        if (!locks) rst_pix_sr <= 16'hFFFF; else rst_pix_sr <= {rst_pix_sr[14:0], 1'b0};
    wire rst_sys = rst_sys_sr[15], rst_pix = rst_pix_sr[15];

    // ------------------------------------------------------------------ CPU core (system)
    wire [7:0] d_out; wire d_oe, irq_low, uart_tx, con_tx;
    wire [5:0] led;
    wire mon_ready, mon_vec_seen, mon_boot_ok, mon_bus_err;
    wire [7:0] mon_sig, mon_irq_cnt;
    wire ps_cmd, ps_cmd_en, ps_cmd_rdy, ps_rdata_valid, ps_init_calib;
    wire [19:0] ps_addr; wire [31:0] ps_wdata, ps_rdata; wire [3:0] ps_mask;
    wire       x_wr, x_rd, vdp_irq; wire [7:0] x_addr, x_wd, x_rd_data; wire [3:0] x_page;
    k65_basic_core #(.CYC(CYC), .FAST_RAM_BYTES(FAST), .ROM_BYTES(ROMB), .EXT_EN(`K65_AUDIO ? 2 : 1),
                     .ROM_FILE(`K65_ROMHEX)) u_core (
        .clk(clk_sys), .rst(rst_sys),
        .a_in(cpu_a), .rwb_in(cpu_rwb), .d_in(cpu_d),
        .phi2(cpu_phi2), .d_out(d_out), .d_oe(d_oe), .irq_low(irq_low),
        .uart_tx(uart_tx), .con_tx(con_tx), .con_rx(bl_uart_rx),
        .ext_wr(x_wr), .ext_rd(x_rd), .ext_addr(x_addr), .ext_page(x_page), .ext_wdata(x_wd), .ext_rdata(x_rd_data),
        .ext_irq(vdp_irq),
        .sync_in(cpu_sync_1v8), .led(led), .dbg(dbg),
        .ps_cmd(ps_cmd), .ps_cmd_en(ps_cmd_en), .ps_cmd_rdy(ps_cmd_rdy), .ps_addr(ps_addr),
        .ps_wdata(ps_wdata), .ps_mask(ps_mask), .ps_rdata(ps_rdata), .ps_rdata_valid(ps_rdata_valid),
        .ps_init_calib(ps_init_calib),
        .mon_a_sample(), .mon_w_capture(), .mon_ready(mon_ready), .mon_vec_seen(mon_vec_seen),
        .mon_boot_ok(mon_boot_ok), .mon_vec(), .mon_sig(mon_sig), .mon_cycles(),
        .mon_irq_cnt(mon_irq_cnt), .mon_bus_err(mon_bus_err), .mon_stretch()
    );
    assign cpu_d      = d_oe ? d_out : 8'hzz;
    assign cpu_irqb   = irq_low ? 1'b0 : 1'bz;
    assign xiao_tx    = uart_tx;
    assign bl_uart_tx = con_tx;                // console (BASIC) on the BL702 USB-UART

    // ------------------------------------------------------------------ PSRAM die 0 (system / CK)
    wire p_reset_n, p_cs_n, p_ck_en, p_dq_oe, p_rwds_oe, p_rwds_r, p_rwds_f, p_dq_tx, p_rwds_tx;
    wire [7:0] p_dq_r, p_dq_f, p_in_r, p_in_f;
    // k65_psram_ctrl = unmodified KAGURA-9 controller with the fixed settings and
    // the tVCS-compliant power-up wait (INIT_CYCLES 18432 = 170.7 us, see the wrapper)
    k65_psram_ctrl u_psctl (
        .clk(clk_sys), .rst(rst_sys),
        .cmd(ps_cmd), .cmd_en(ps_cmd_en), .cmd_rdy(ps_cmd_rdy), .addr(ps_addr),
        .wr_data(ps_wdata), .data_mask(ps_mask), .rd_data(ps_rdata), .rd_data_valid(ps_rdata_valid),
        .init_calib(ps_init_calib), .phy_reset_n(p_reset_n), .phy_cs_n(p_cs_n), .phy_ck_en(p_ck_en),
        .phy_dq_oe(p_dq_oe), .phy_dq_o_rise(p_dq_r), .phy_dq_o_fall(p_dq_f), .phy_rwds_oe(p_rwds_oe),
        .phy_rwds_o_rise(p_rwds_r), .phy_rwds_o_fall(p_rwds_f), .phy_dq_tx(p_dq_tx), .phy_rwds_tx(p_rwds_tx),
        .phy_dq_i_rise(p_in_r), .phy_dq_i_fall(p_in_f)
    );
    kagura_hyperram_phy_gowin u_psphy (
        .clk(clk_sys), .clk_ck(clk_ck), .phy_reset_n(p_reset_n), .phy_cs_n(p_cs_n),
        .phy_ck_en(p_ck_en), .phy_dq_oe(p_dq_tx), .phy_dq_o_rise(p_dq_r), .phy_dq_o_fall(p_dq_f),
        .phy_rwds_oe(p_rwds_tx), .phy_rwds_o_rise(p_rwds_r), .phy_rwds_o_fall(p_rwds_f),
        .phy_dq_i_rise(p_in_r), .phy_dq_i_fall(p_in_f), .phy_rwds_i_rise(), .phy_rwds_i_fall(),
        .O_psram_ck(O_psram_ck[0]), .O_psram_ck_n(O_psram_ck_n[0]), .O_psram_reset_n(O_psram_reset_n[0]),
        .O_psram_cs_n(O_psram_cs_n[0]), .IO_psram_rwds(IO_psram_rwds[0]), .IO_psram_dq(IO_psram_dq[7:0])
    );
    // die 1 unused: CK low, CS# high, RESET# low, bus released
    assign {O_psram_ck[1], O_psram_ck_n[1], O_psram_reset_n[1], O_psram_cs_n[1]} = 4'b0101;
    assign IO_psram_rwds[1]   = 1'bz;
    assign IO_psram_dq[15:8]  = 8'hzz;

    // ------------------------------------------------------------------ VDP (system + pixel)
    wire s_valid, s_ready;
    wire [31:0] s_data;
    wire [10:0] cx; wire [9:0] cy; wire [23:0] rgb;
    wire [7:0] v_rdata, a_rdata;
    wire x_vdp = (`K65_AUDIO == 0) || (x_page == 4'h3);
    wire x_aud = (`K65_AUDIO != 0) && (x_page == 4'h4);
    assign x_rd_data = x_aud ? a_rdata : v_rdata;
    wire lg_valid, lg_pwm_l, lg_pwm_r; wire [31:0] lg_data;
    wire t_tick, t_wrdy; wire [7:0] t_s0, t_s1, t_v0, t_v1; wire [1:0] t_wen;
    k65_vdp #(.NPAT(`K65_NPAT), .PAT_FLAT(`K65_PAT_FLAT), .SHARE_PW(`K65_SHARE_PW),
              .OAM_DBL(`K65_OAM_DBL), .PAL_FILE(`K65_PALHEX), .PAL256_FILE(`K65_PAL256HEX)) u_vdp (
        .clk(clk_sys), .rst(rst_sys),
        .reg_wr(x_wr && x_vdp && x_addr[7:6] == 2'b00), .reg_rd(x_rd && x_vdp && x_addr[7:6] == 2'b00),
        .reg_addr(x_addr[5:0]), .reg_wdata(x_wd), .reg_rdata(v_rdata), .irq(vdp_irq),
        .clk_pix(clk_pix), .rst_pix(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .sample_valid(lg_valid), .sample_ready(`K65_AUDIO ? 1'b1 : s_ready), .sample_data(lg_data),
        .pwm_l(lg_pwm_l), .pwm_r(lg_pwm_r),
        .aud_tick(t_tick), .aud_wrdy(t_wrdy), .aud_s0(t_s0), .aud_s1(t_s1), .aud_v0(t_v0), .aud_v1(t_v1), .aud_wen(t_wen),
        .mon_render_ovr(), .mon_render_max()
    );
    generate
        if (`K65_AUDIO) begin : g_audio
            wire a_pwm_l, a_pwm_r;
            k65_audio u_aud (
                .clk(clk_sys), .rst(rst_sys),
                .reg_wr(x_wr && x_aud && x_addr[7:5] == 3'd0), .reg_rd(x_rd && x_aud && x_addr[7:5] == 3'd0),
                .reg_addr(x_addr[4:0]), .reg_wdata(x_wd), .reg_rdata(a_rdata),
                .clk_pix(clk_pix), .rst_pix(rst_pix), .tick(t_tick), .wv_rdy(t_wrdy), .wv_s0(t_s0), .wv_s1(t_s1),
                .wv_v0(t_v0), .wv_v1(t_v1), .wv_en(t_wen),
                .sample_valid(s_valid), .sample_ready(s_ready), .sample_data(s_data),
                .pwm_l(a_pwm_l), .pwm_r(a_pwm_r), .mon_apply(), .mon_mix(), .mon_drops()
            );
            assign aud_pwm_l = a_pwm_l; assign aud_pwm_r = a_pwm_r;
        end else begin : g_noaudio
            assign a_rdata = 8'h00;
            assign s_valid = lg_valid; assign s_data = lg_data;
            assign aud_pwm_l = lg_pwm_l; assign aud_pwm_r = lg_pwm_r;
        end
    endgenerate
    wire [9:0] sym0, sym1, sym2;
    k65_hdmi_tx u_hdmi (
        .clk(clk_pix), .rst(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .sample_valid(s_valid), .sample_data(s_data), .sample_ready(s_ready),
        .sym0(sym0), .sym1(sym1), .sym2(sym2)
    );
    k65_hdmi_phy u_phy (
        .clk_pixel(clk_pix), .clk_serial(clk_ser), .sym0(sym0), .sym1(sym1), .sym2(sym2),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    assign led_n = ~led;
    wire unused_ok = &{1'b0, xiao_rx, user_btn_n, btn_n};
endmodule
