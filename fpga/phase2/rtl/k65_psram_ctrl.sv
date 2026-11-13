// KAGURA-6502: PSRAM controller with the project's fixed settings, in ONE place.
// Thin wrapper around the unmodified KAGURA-9 controller
// (third_party/kagura-9/kagura_hyperram_ctrl.sv, 1ea0519). Used by phase2_top,
// the Phase 2 testbench and every later 54 MHz design, so that the hardware-proven
// settings and the power-up wait cannot drift apart between RTL and simulation.
//
// Hardware-proven in KAGURA-9 (54 MHz, die 0, memtest 1 GiB / 0 errors) - keep:
//   lat_cycles 14 (fixed 2x latency, CR0 = 0x8F1F), rd_latency 6, ADDR_WIDTH 20,
//   CK phase 67.5 deg (set in the PLL, not here).
//
// Power-up wait (changed 2026-11-13, phase0/exp74 finding X-3):
//   The controller holds RESET# low for INIT_CYCLES/2 clocks, releases it, waits
//   another INIT_CYCLES/2 clocks and then writes CR0 (the first access).
//   W955D8MBYA datasheet A01-002 Table 11: tVCS >= 150 us (from RESET# high when
//   RESET# is held low during power-up).
//     KAGURA-9 default 4096  @ 54 MHz: RESET# high -> CR0 = 2048 clk = 37.9 us  (violates tVCS)
//     KAGURA-6502      18432 @ 54 MHz: RESET# high -> CR0 = 9216 clk = 170.7 us (tVCS +13.8 %)
//   RESET# low is also 170.7 us (tRP >= 200 ns). Total controller init 341.3 us.
//   KAGURA-9 passed memtest with 4096; the longer wait only adds idle time before
//   the first access, it does not change any access timing.
module k65_psram_ctrl #(
    parameter integer INIT_CYCLES = 18432    // see above; testbenches override it only for negative tests
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cmd,
    input  logic        cmd_en,
    output logic        cmd_rdy,
    input  logic [19:0] addr,
    input  logic [31:0] wr_data,
    input  logic [3:0]  data_mask,
    output logic [31:0] rd_data,
    output logic        rd_data_valid,
    output logic        init_calib,
    output logic        phy_reset_n,
    output logic        phy_cs_n,
    output logic        phy_ck_en,
    output logic        phy_dq_oe,
    output logic [7:0]  phy_dq_o_rise,
    output logic [7:0]  phy_dq_o_fall,
    output logic        phy_rwds_oe,
    output logic        phy_rwds_o_rise,
    output logic        phy_rwds_o_fall,
    output logic        phy_dq_tx,
    output logic        phy_rwds_tx,
    input  logic [7:0]  phy_dq_i_rise,
    input  logic [7:0]  phy_dq_i_fall
);
    kagura_hyperram_ctrl #(.ADDR_WIDTH(20), .INIT_CYCLES(INIT_CYCLES)) u_ctrl (
        .clk(clk), .rst_n(!rst), .lat_cycles(5'd14), .rd_latency(3'd6),
        .cmd(cmd), .cmd_reg(1'b0), .cmd_en(cmd_en), .cmd_rdy(cmd_rdy), .addr(addr),
        .wr_data(wr_data), .data_mask(data_mask), .rd_data(rd_data), .rd_data_valid(rd_data_valid),
        .init_calib(init_calib), .phy_reset_n(phy_reset_n), .phy_cs_n(phy_cs_n), .phy_ck_en(phy_ck_en),
        .phy_dq_oe(phy_dq_oe), .phy_dq_o_rise(phy_dq_o_rise), .phy_dq_o_fall(phy_dq_o_fall),
        .phy_rwds_oe(phy_rwds_oe), .phy_rwds_o_rise(phy_rwds_o_rise), .phy_rwds_o_fall(phy_rwds_o_fall),
        .phy_dq_tx(phy_dq_tx), .phy_rwds_tx(phy_rwds_tx),
        .phy_dq_i_rise(phy_dq_i_rise), .phy_dq_i_fall(phy_dq_i_fall)
    );
endmodule
