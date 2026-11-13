// KAGURA-6502 audio: pulse x3 + noise x1 generators and the 6-channel mixer (AUD-002).
// Specification: docs/audio-6ch.md. The two wave channels stay in k65_vdp (their memory
// shares the palette SDPB); this module takes their samples at the legacy mix point.
//
// Clock domains
//   clk     (system, 54 MHz): CPU registers $D400-$D41F (one set, read back as written)
//   clk_pix (74.25 MHz)     : active copy of the registers, generators, mixer, HDMI samples, PWM
// Crossing (AUD-003, "one register set + COMMIT"): writing COMMIT ($D41F) flips a toggle.
// The pixel side synchronises it (2 FF), copies the whole register set in ONE clock and
// returns an acknowledge toggle (STATUS b0 BUSY = toggles differ). The copied registers
// do not change during the copy because the CPU cannot write again within one bus cycle
// (>= 8 sysclk = 148 ns; the copy happens <= 4 clk_pix = 54 ns after the COMMIT write).
// The copy is used from the next 48 kHz tick on, so a commit is atomic per sample.
//
// Sample tick, per channel (identical to kagura-hd docs/audio-spec.md, AUD-002):
//   pulse : out = (STEP==0 || DUTY==0) ? 0 : (phase[23:16] < DUTY ? +127 : -127);
//           then phase += STEP (mod 2^24)
//   noise : out = lfsr[14] ? +127 : -127; then if COUNT==0 { lfsr = {lfsr[13:0],
//           lfsr[14]^lfsr[13]}; COUNT = PERIOD } else COUNT--      (lfsr reset 1, 32767 states)
//   disabled channel: out = 0, phase / lfsr / COUNT held.
//   phase-reset request (PRST, taken by COMMIT): phase = 0 / lfsr = 1, COUNT = PERIOD before
//           the tick's computation (so the first sample after the reset is from phase 0),
//           independent of ENABLE.
// Mixer (one sample per tick, after the wave samples are ready):
//   acc_L = sum over the 6 voices of s8 * VOL_L (4 bit)    |acc| <= 6*128*15 = 11520
//   L     = clamp((acc_L * MVOL) >>> 4, -32768, 32767)     MVOL reset 32 (x2: no clipping
//           with all six voices at full scale, 23040); MVOL 128 = the earlier wave-only level
//   voices: p0 p1 p2 noise wave0 wave1; a disabled wave channel contributes 0.
module k65_audio (
    // ---------------- system domain
    input  wire        clk,
    input  wire        rst,
    input  wire        reg_wr,            // end-of-cycle write pulse
    input  wire        reg_rd,            // end-of-cycle read pulse (STATUS read clears DROP)
    input  wire [4:0]  reg_addr,
    input  wire [7:0]  reg_wdata,
    output reg  [7:0]  reg_rdata,         // combinational from the registers
    // ---------------- pixel domain
    input  wire        clk_pix,
    input  wire        rst_pix,
    input  wire        tick,              // 48 kHz tick (k65_vdp aud_tick)
    input  wire        wv_rdy,            // wave samples of this tick valid (k65_vdp aud_wrdy)
    input  wire [7:0]  wv_s0,
    input  wire [7:0]  wv_s1,
    input  wire [7:0]  wv_v0,
    input  wire [7:0]  wv_v1,
    input  wire [1:0]  wv_en,
    output reg         sample_valid,
    input  wire        sample_ready,
    output reg  [31:0] sample_data,       // {R, L}
    output reg         pwm_l,
    output reg         pwm_r,
    // ---------------- observability (testbench)
    output reg         mon_apply,         // clk_pix: the register copy happened this clock
    output reg         mon_mix,           // clk_pix: a new sample was loaded this clock
    output reg  [15:0] mon_drops          // clk_pix: samples overwritten before HDMI took them
);
    localparam [7:0] MVOL_RESET = 8'd32;

    // =====================================================================
    // System domain: registers ($D400 + reg_addr)
    // =====================================================================
    //  00-02 P0 STEP (L, M, H)  03 P0 DUTY  04 P0 VOL (b7..4 L, b3..0 R)
    //  08-0C P1 (same)          10-14 P2 (same)
    //  18-19 NOISE PERIOD (L, H)            1A NOISE VOL
    //  1B MVOL   1C ENABLE (b0..2 pulse 0..2, b3 noise)   1D PRST (same bits, taken by COMMIT)
    //  1E STATUS (R: b0 BUSY, b1 DROP sticky, cleared by reading)   1F COMMIT (W, any value)
    reg [23:0] r_step [0:2];
    reg [7:0]  r_duty [0:2];
    reg [7:0]  r_vol  [0:3];              // 0..2 pulse, 3 noise
    reg [15:0] r_per;
    reg [7:0]  r_mvol;
    reg [3:0]  r_en, r_prst, r_prst_c;    // r_prst_c: PRST captured by the last COMMIT
    reg        c_tg;                      // commit toggle
    reg        a_tg, d_tg;                // clk_pix: acknowledge / drop toggles
    reg        a_m, a_s;                  // acknowledge toggle, synchronised
    reg        d_m, d_s, d_d;             // drop toggle, synchronised + edge
    reg        st_drop;
    wire       busy = c_tg ^ a_s;
    wire [1:0] rc = reg_addr[4:3];        // pulse channel of 00-17

    always @(*) begin
        reg_rdata = 8'h00;
        if (reg_addr[4:3] != 2'd3) begin
            case (reg_addr[2:0])
                3'd0: reg_rdata = r_step[rc][7:0];
                3'd1: reg_rdata = r_step[rc][15:8];
                3'd2: reg_rdata = r_step[rc][23:16];
                3'd3: reg_rdata = r_duty[rc];
                3'd4: reg_rdata = r_vol[rc];
                default: reg_rdata = 8'h00;
            endcase
        end else begin
            case (reg_addr[2:0])
                3'd0: reg_rdata = r_per[7:0];
                3'd1: reg_rdata = r_per[15:8];
                3'd2: reg_rdata = r_vol[3];
                3'd3: reg_rdata = r_mvol;
                3'd4: reg_rdata = {4'd0, r_en};
                3'd5: reg_rdata = {4'd0, r_prst};
                3'd6: reg_rdata = {6'd0, st_drop, busy};
                default: reg_rdata = 8'h00;
            endcase
        end
    end

    always @(posedge clk) begin : sysregs
        integer i;
        if (rst) begin
            for (i = 0; i < 3; i = i + 1) begin r_step[i] <= 24'd0; r_duty[i] <= 8'd0; end
            for (i = 0; i < 4; i = i + 1) r_vol[i] <= 8'd0;
            r_per <= 16'd0; r_mvol <= MVOL_RESET; r_en <= 4'd0; r_prst <= 4'd0; r_prst_c <= 4'd0;
            c_tg <= 1'b0; a_m <= 1'b0; a_s <= 1'b0; d_m <= 1'b0; d_s <= 1'b0; d_d <= 1'b0; st_drop <= 1'b0;
        end else begin
            a_m <= a_tg; a_s <= a_m;
            d_m <= d_tg; d_s <= d_m; d_d <= d_s;
            if (reg_rd && reg_addr == 5'h1E) st_drop <= 1'b0;
            if (d_s ^ d_d) st_drop <= 1'b1;                    // a new drop wins over the clear
            if (reg_wr) begin
                if (reg_addr[4:3] != 2'd3) begin
                    case (reg_addr[2:0])
                        3'd0: r_step[rc][7:0]   <= reg_wdata;
                        3'd1: r_step[rc][15:8]  <= reg_wdata;
                        3'd2: r_step[rc][23:16] <= reg_wdata;
                        3'd3: r_duty[rc] <= reg_wdata;
                        3'd4: r_vol[rc]  <= reg_wdata;
                        default: ;
                    endcase
                end else begin
                    case (reg_addr[2:0])
                        3'd0: r_per[7:0]  <= reg_wdata;
                        3'd1: r_per[15:8] <= reg_wdata;
                        3'd2: r_vol[3]    <= reg_wdata;
                        3'd3: r_mvol      <= reg_wdata;
                        3'd4: r_en        <= reg_wdata[3:0];
                        3'd5: r_prst      <= reg_wdata[3:0];
                        3'd7: begin r_prst_c <= r_prst; r_prst <= 4'd0; c_tg <= ~c_tg; end   // COMMIT
                        default: ;
                    endcase
                end
            end
        end
    end

    // =====================================================================
    // Pixel domain: active copy (taken on COMMIT)
    // =====================================================================
    reg        c_m, c_s, c_d;
    reg [23:0] x_step [0:2];
    reg [7:0]  x_duty [0:2];
    reg [7:0]  x_vol  [0:3];
    reg [15:0] x_per;
    reg [7:0]  x_mvol;
    reg [3:0]  x_en, rst_pend;
    wire       apply = c_s ^ c_d;
    always @(posedge clk_pix) begin : copy
        integer i;
        if (rst_pix) begin
            c_m <= 1'b0; c_s <= 1'b0; c_d <= 1'b0; a_tg <= 1'b0;
            for (i = 0; i < 3; i = i + 1) begin x_step[i] <= 24'd0; x_duty[i] <= 8'd0; end
            for (i = 0; i < 4; i = i + 1) x_vol[i] <= 8'd0;
            x_per <= 16'd0; x_mvol <= MVOL_RESET; x_en <= 4'd0; mon_apply <= 1'b0;
        end else begin
            c_m <= c_tg; c_s <= c_m; c_d <= c_s;
            mon_apply <= apply;
            if (apply) begin
                for (i = 0; i < 3; i = i + 1) begin x_step[i] <= r_step[i]; x_duty[i] <= r_duty[i]; end
                for (i = 0; i < 4; i = i + 1) x_vol[i] <= r_vol[i];
                x_per <= r_per; x_mvol <= r_mvol; x_en <= r_en;
                a_tg <= c_s;
            end
        end
    end

    // =====================================================================
    // Pixel domain: generators (one step per tick)
    // =====================================================================
    reg [23:0] ph [0:2];
    reg [14:0] lfsr;
    reg [15:0] ncnt;
    reg [7:0]  vs [0:3];                  // signed 8-bit voice samples of the current tick
    always @(posedge clk_pix) begin : gen
        integer i;
        reg [23:0] pe;
        reg [14:0] le;
        reg [15:0] ce;
        if (rst_pix) begin
            for (i = 0; i < 3; i = i + 1) ph[i] <= 24'd0;
            for (i = 0; i < 4; i = i + 1) vs[i] <= 8'd0;
            lfsr <= 15'd1; ncnt <= 16'd0; rst_pend <= 4'd0;
        end else begin
            if (tick) begin
                for (i = 0; i < 3; i = i + 1) begin
                    pe = rst_pend[i] ? 24'd0 : ph[i];
                    if (x_en[i]) begin
                        vs[i] <= (x_step[i] == 24'd0 || x_duty[i] == 8'd0) ? 8'd0 :
                                 (pe[23:16] < x_duty[i]) ? 8'd127 : 8'h81;          // +127 / -127
                        ph[i] <= pe + x_step[i];
                    end else begin
                        vs[i] <= 8'd0;
                        ph[i] <= pe;
                    end
                end
                le = rst_pend[3] ? 15'd1 : lfsr;
                ce = rst_pend[3] ? x_per : ncnt;
                if (x_en[3]) begin
                    vs[3] <= le[14] ? 8'd127 : 8'h81;
                    if (ce == 16'd0) begin lfsr <= {le[13:0], le[14] ^ le[13]}; ncnt <= x_per; end
                    else             begin lfsr <= le; ncnt <= ce - 16'd1; end
                end else begin
                    vs[3] <= 8'd0; lfsr <= le; ncnt <= ce;
                end
                rst_pend <= 4'd0;
            end
            if (apply) rst_pend <= r_prst_c;   // after the tick: a copy in the tick clock waits for the next tick
        end
    end

    // =====================================================================
    // Pixel domain: mixer. Started by wv_rdy (a few clocks after tick; the generator
    // outputs of the same tick are already registered). The volumes and MVOL used are the
    // ones of the tick (y_*), so a COMMIT copy landing during the mix does not tear a sample.
    // One voice per clock: select (sample, volumes) -> product (s8 x u4, L and R) ->
    // accumulate; then master volume (s16 x u8), shift, clamp, output register.
    // =====================================================================
    reg  [7:0]  y_vol [0:3];
    reg  [7:0]  y_mvol;
    always @(posedge clk_pix) begin : snap
        integer k;
        if (rst_pix) begin
            for (k = 0; k < 4; k = k + 1) y_vol[k] <= 8'd0;
            y_mvol <= MVOL_RESET;
        end else if (tick) begin
            for (k = 0; k < 4; k = k + 1) y_vol[k] <= x_vol[k];
            y_mvol <= x_mvol;
        end
    end
    reg  [2:0]  mk;                       // voice select counter, 0 = idle
    reg  [7:0]  w0, w1;                   // wave samples latched at wv_rdy (0 if disabled)
    reg  [7:0]  wv0, wv1;                 // wave volumes latched at wv_rdy
    reg  signed [7:0] m_s;
    reg  [3:0]  m_vl, m_vr;
    reg         m_v, m_first, m_last, p_v, p_first, p_last, a_done;
    reg  signed [15:0] p_l, p_r;           // s8 x u4 products (13 bits significant)
    reg  signed [15:0] acc_l, acc_r;
    reg  signed [24:0] g_l, g_r;
    reg         g_v, c_v;
    always @(posedge clk_pix) begin
        if (rst_pix) begin
            mk <= 3'd0; m_v <= 1'b0; m_first <= 1'b0; m_last <= 1'b0;
            p_v <= 1'b0; p_first <= 1'b0; p_last <= 1'b0; a_done <= 1'b0; g_v <= 1'b0; c_v <= 1'b0;
            acc_l <= 16'sd0; acc_r <= 16'sd0; g_l <= 25'sd0; g_r <= 25'sd0;
            w0 <= 8'd0; w1 <= 8'd0; wv0 <= 8'd0; wv1 <= 8'd0;
            m_s <= 8'sd0; m_vl <= 4'd0; m_vr <= 4'd0; p_l <= 16'sd0; p_r <= 16'sd0;
        end else begin
            // stage S: voice select (p0 p1 p2 noise wave0 wave1)
            if (wv_rdy) begin
                w0 <= wv_en[0] ? wv_s0 : 8'd0; w1 <= wv_en[1] ? wv_s1 : 8'd0;
                wv0 <= wv_v0; wv1 <= wv_v1;
                mk <= 3'd1;
            end else if (mk != 3'd0) mk <= (mk == 3'd6) ? 3'd0 : mk + 3'd1;
            m_v <= (mk != 3'd0); m_first <= (mk == 3'd1); m_last <= (mk == 3'd6);
            case (mk)
                3'd1:    begin m_s <= vs[0]; {m_vl, m_vr} <= y_vol[0]; end
                3'd2:    begin m_s <= vs[1]; {m_vl, m_vr} <= y_vol[1]; end
                3'd3:    begin m_s <= vs[2]; {m_vl, m_vr} <= y_vol[2]; end
                3'd4:    begin m_s <= vs[3]; {m_vl, m_vr} <= y_vol[3]; end
                3'd5:    begin m_s <= w0;    {m_vl, m_vr} <= wv0;      end
                default: begin m_s <= w1;    {m_vl, m_vr} <= wv1;      end
            endcase
            // stage P: products
            p_v <= m_v; p_first <= m_first; p_last <= m_last;
            p_l <= m_s * $signed({1'b0, m_vl});
            p_r <= m_s * $signed({1'b0, m_vr});
            // stage A: accumulate (the first voice loads)
            a_done <= p_v && p_last;
            if (p_v) begin
                if (p_first) begin acc_l <= p_l; acc_r <= p_r; end
                else         begin acc_l <= acc_l + p_l; acc_r <= acc_r + p_r; end
            end
            // stage G: master volume
            g_v <= a_done;
            if (a_done) begin
                g_l <= acc_l * $signed({1'b0, y_mvol});
                g_r <= acc_r * $signed({1'b0, y_mvol});
            end
            c_v <= g_v;
        end
    end

    // stage C: shift, clamp, output register (and the HDMI handshake)
    function automatic [15:0] clamp16(input signed [24:0] g);
        reg signed [24:0] s;
        begin
            s = g >>> 4;
            if (s > 25'sd32767)       clamp16 = 16'h7FFF;
            else if (s < -25'sd32768) clamp16 = 16'h8000;
            else                      clamp16 = s[15:0];
        end
    endfunction
    always @(posedge clk_pix) begin
        if (rst_pix) begin
            sample_valid <= 1'b0; sample_data <= 32'd0; d_tg <= 1'b0; mon_mix <= 1'b0; mon_drops <= 16'd0;
        end else begin
            mon_mix <= 1'b0;
            if (sample_valid && sample_ready) sample_valid <= 1'b0;
            if (c_v) begin
                if (sample_valid && !sample_ready) begin              // previous sample not taken: dropped
                    d_tg <= ~d_tg;
                    if (mon_drops != 16'hFFFF) mon_drops <= mon_drops + 16'd1;
                end
                sample_data  <= {clamp16(g_r), clamp16(g_l)};
                sample_valid <= 1'b1;
                mon_mix      <= 1'b1;
            end
        end
    end

    // PWM (debug / fallback, AUD-004a): first-order delta-sigma of the same sample as HDMI
    reg [16:0] ds_l, ds_r;
    always @(posedge clk_pix) begin
        if (rst_pix) begin ds_l <= 17'd0; ds_r <= 17'd0; pwm_l <= 1'b0; pwm_r <= 1'b0; end
        else begin
            ds_l <= {1'b0, ds_l[15:0]} + {1'b0, ~sample_data[15],  sample_data[14:0]};
            ds_r <= {1'b0, ds_r[15:0]} + {1'b0, ~sample_data[31], sample_data[30:16]};
            pwm_l <= ds_l[16]; pwm_r <= ds_r[16];
        end
    end
endmodule
