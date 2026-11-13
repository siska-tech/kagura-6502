// Cycle-level model of one HyperBus PSRAM die at the kagura_hyperram_ctrl <-> PHY
// boundary (phy_* signals, one CK per clk, DDR byte pair per cycle).
// exp74 version of fpga/phase2/sim/k65_psram_phy_model.sv (written independently
// of KAGURA-9; the Phase 2 file is unchanged). Differences:
//   * clock-period aware: CLK_PS parameter; the datasheet times are checked in ns
//     (Winbond W955D8MBYA A01-002: Table 11, Table 14):
//       tCK >= 6 ns, LAT_COUNT x tCK >= tACC 36 ns, tCSM <= 4 us, tCSHI >= 6 ns,
//       RESET# low >= tRP 200 ns, RESET# high -> CS# low >= tRH 200 ns,
//       RESET# high -> first access >= tVCS 150 us (power-up rule; +no_tvcs disables)
//   * fault injection (negative tests of the testbenches), plusargs:
//       +ps_fault_late    read data returned one clock later than expected
//       +ps_fault_flip=N  flip bit 0 of every byte of the N-th read word (1-based)
//       +ps_fault_nowr=N  drop the N-th memory write
//       +ps_fault_cr0     reject the CR0 write (memory stays unconfigured)
//   * counters for the benchmark: n_rd, n_wr, n_reg, max_cs, busy clocks.
// It models what the controller must see, not pad timing; pad timing is in
// fpga/exp74/sim/phy (pin-level model).
module k65_psram_phy_model_t #(
    parameter integer LAT        = 14,        // CK index of the first data cycle (2 + 2 x latency count)
    parameter integer LAT_COUNT  = 6,         // CR0[7:4] = 0001b -> 6 clocks
    parameter integer RD_LAT     = 6,
    parameter [15:0]  CR0_EXPECT = 16'h8F1F,
    parameter integer CLK_PS     = 13468      // controller clock period (ps)
) (
    input  wire       clk,
    input  wire       phy_reset_n,
    input  wire       phy_cs_n,
    input  wire       phy_ck_en,
    input  wire       phy_dq_oe,
    input  wire [7:0] phy_dq_o_rise,
    input  wire [7:0] phy_dq_o_fall,
    input  wire       phy_rwds_oe,
    input  wire       phy_rwds_o_rise,
    input  wire       phy_rwds_o_fall,
    output wire [7:0] phy_dq_i_rise,
    output wire [7:0] phy_dq_i_fall
);
    localparam integer TCSM_MAX = 4_000_000 / CLK_PS;           // clocks
    localparam integer TRP_MIN  = (200_000 + CLK_PS - 1) / CLK_PS;
    localparam integer TRH_MIN  = (200_000 + CLK_PS - 1) / CLK_PS;
    localparam integer TVCS_MIN = (150_000_000 + CLK_PS - 1) / CLK_PS;
    integer errors = 0, n_rd = 0, n_wr = 0, n_reg = 0, max_cs = 0, n_rd_words = 0, n_wr_words = 0;
    longint busy = 0;
    bit [7:0] mem [int];
    logic reset_seen = 0, cr0_ok = 0;
    integer ck_idx = 0, cs_len = 0, rst_low = 0, since_rst = 0, cs_high = 99;
    logic [47:0] ca;
    logic [15:0] pair_q [0:RD_LAT];
    bit f_late, no_tvcs, f_cr0; int f_flip = 0, f_nowr = 0;
    initial begin
        f_late = $test$plusargs("ps_fault_late");
        f_cr0  = $test$plusargs("ps_fault_cr0");
        no_tvcs = $test$plusargs("no_tvcs");
        void'($value$plusargs("ps_fault_flip=%d", f_flip));
        void'($value$plusargs("ps_fault_nowr=%d", f_nowr));
        if (CLK_PS < 6000) err("clock period < tCK 6 ns");
        if (LAT_COUNT * CLK_PS < 36000) err("latency count x tCK < tACC 36 ns");
    end
    assign {phy_dq_i_rise, phy_dq_i_fall} = f_late ? pair_q[RD_LAT] : pair_q[RD_LAT-1];

    task automatic err(input string m);
        errors++;
        if (errors <= 10) $display("[%0t] PSRAM MODEL ERROR: %s", $time, m);
    endtask
    function automatic logic [7:0] rd8(input int a);
        return mem.exists(a) ? mem[a] : 8'hEE;
    endfunction

    always @(posedge clk) begin
        logic [15:0] drive;
        int w, k;
        drive = 16'($urandom);                       // bus garbage unless the memory drives
        if (!phy_reset_n) begin
            if (!phy_cs_n) err("CS# low during RESET#");
            rst_low++; since_rst = 0;
        end else begin
            if (rst_low > 0) begin
                if (rst_low < TRP_MIN) err($sformatf("RESET# low %0d clocks < tRP", rst_low));
                reset_seen <= 1;
            end
            rst_low = 0;
            if (since_rst < 1 << 30) since_rst++;
        end
        if (phy_cs_n) begin
            if (phy_ck_en) err("CK toggles with CS# high");
            ck_idx = 0; cs_len = 0;
            if (cs_high < 1000) cs_high++;          // saturate (cs_high * CLK_PS must not overflow)
        end else begin
            if (cs_len == 0) begin
                if (!reset_seen) err("access before any RESET# pulse");
                if (since_rst < TRH_MIN) err("CS# low < tRH after RESET#");
                if (!no_tvcs && since_rst < TVCS_MIN) err($sformatf("first access %0d clocks after RESET# < tVCS", since_rst));
                if (cs_high * CLK_PS < 6000) err("CS# high < tCSHI");
            end
            cs_high = 0;
            cs_len++; busy++;
            if (cs_len > max_cs) max_cs = cs_len;
            if (cs_len > TCSM_MAX) err($sformatf("CS# low for %0d cycles (> tCSM)", cs_len));
            if (phy_ck_en) begin
                if (ck_idx < 3) begin
                    if (!phy_dq_oe) err("CA not driven");
                    ca[47 - 16 * ck_idx -: 16] = {phy_dq_o_rise, phy_dq_o_fall};
                end else begin
                    w = int'({ca[44:16], ca[2:0]});
                    if (ca[46]) begin                          // register space
                        if (ca[47]) err("register read not expected");
                        else if (ck_idx == 3) begin
                            n_reg++;
                            if (!phy_dq_oe) err("CR data not driven");
                            if (w != 32'h800) err($sformatf("register write to %0h (not CR0)", w));
                            if ({phy_dq_o_rise, phy_dq_o_fall} != CR0_EXPECT)
                                err($sformatf("CR0 = %04h", {phy_dq_o_rise, phy_dq_o_fall}));
                            else if (!f_cr0) cr0_ok <= 1;
                        end
                    end else if (ck_idx >= LAT) begin              // memory data cycles
                        k = ck_idx - LAT;
                        if (!cr0_ok) err("memory access before CR0 was written");
                        if (ca[47]) begin
                            drive = {rd8(2 * (w + k)), rd8(2 * (w + k) + 1)};
                            if (k == 0) n_rd++;
                            // fault: bit 0 of all four bytes of the N-th read word
                            if (f_flip != 0 && n_rd == f_flip) drive = drive ^ 16'h0101;
                        end else begin
                            if (!phy_dq_oe || !phy_rwds_oe) err("write data / RWDS not driven");
                            if (k == 0) n_wr++;
                            if (!(f_nowr != 0 && n_wr == f_nowr)) begin
                                if (!phy_rwds_o_rise) mem[2 * (w + k)]     = phy_dq_o_rise;
                                if (!phy_rwds_o_fall) mem[2 * (w + k) + 1] = phy_dq_o_fall;
                            end
                        end
                    end else if (!ca[47] && phy_dq_oe && ck_idx > 3 && ck_idx < LAT - 1)
                        err("controller drives DQ during the write latency");
                end
                ck_idx++;
            end
        end
        pair_q[0] <= drive;
        for (int i = 1; i <= RD_LAT; i++) pair_q[i] <= pair_q[i-1];
    end
endmodule
