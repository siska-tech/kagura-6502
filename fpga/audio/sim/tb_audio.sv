// KAGURA-6502 6-channel audio testbench (Verilator 5, --timing).
//   k65_vdp (wave 0/1, 48 kHz tick, palette/wave SDPB) + k65_audio (pulse 0-2, noise,
//   6-channel mixer, PWM) + k65_hdmi_tx (sample hand-off, data islands, TMDS symbols).
// The CPU side is driven through the register ports (writes >= 16 sysclk apart, as a
// 3.375 MHz W65C02S). Every write is placed 40..1400 clk_pix after a 48 kHz tick, so the
// tick at which it takes effect is unambiguous (see "safe()").
// Checks (all independent of the DUT's internals except the tick used as time base):
//   * reference model (this file): every mixed sample == model, in order
//   * produced -> accepted by the HDMI transmitter: same sequence (no drop / duplicate)
//   * TMDS decode of the audio sample packets == accepted sequence (tb_hdmi_aud_mon)
//   * PWM bit stream within the first-order delta-sigma bound of each sample (tb_pwm_check)
//   * 48 kHz tick period (1546 / 1547 clk_pix, 800 per video frame)
//   * wave-only output with MVOL = 128 == the legacy k65_vdp mixer, bit for bit
//   * measured pulse frequency, noise period 32767 (and no shorter period), clipping
// Plusargs: +seed=N, faults (negative tests): +fault_noready +fault_mvol +fault_lfsr
//   +fault_pwm +fault_hdmimon +fault_commit
`timescale 1ps/1ps
module tb_audio;
    logic clk = 0, clk_pix = 0;
    always #9259 clk = ~clk;                    // 54 MHz
    always #6734 clk_pix = ~clk_pix;            // 74.25 MHz
    logic rst = 1, rst_pix = 1;
    initial begin repeat (20) @(posedge clk); rst = 0; end
    initial begin repeat (20) @(posedge clk_pix); rst_pix = 0; end

    // ------------------------------------------------------------------ DUT
    logic v_wr = 0, v_rd = 0, a_wr = 0, a_rd = 0; logic [5:0] r_addr = 0; logic [7:0] r_wdata = 0;
    wire [7:0] v_rdata, a_rdata; wire v_irq;
    wire [10:0] cx; wire [9:0] cy; wire [23:0] rgb;
    wire lg_valid; wire [31:0] lg_data;           // legacy wave-only mix of k65_vdp
    wire t_tick, t_wrdy; wire [7:0] t_s0, t_s1, t_v0, t_v1; wire [1:0] t_wen;
    k65_vdp #(.NPAT(1024), .PAL_FILE("../../vdp/rtl/vdp_palette.hex"), .PAL256_FILE("../../vdp/rtl/vdp_palette256.hex")) u_vdp (
        .clk(clk), .rst(rst), .reg_wr(v_wr), .reg_rd(v_rd), .reg_addr(r_addr), .reg_wdata(r_wdata),
        .reg_rdata(v_rdata), .irq(v_irq), .clk_pix(clk_pix), .rst_pix(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .sample_valid(lg_valid), .sample_ready(1'b1), .sample_data(lg_data), .pwm_l(), .pwm_r(),
        .aud_tick(t_tick), .aud_wrdy(t_wrdy), .aud_s0(t_s0), .aud_s1(t_s1), .aud_v0(t_v0), .aud_v1(t_v1), .aud_wen(t_wen),
        .mon_render_ovr(), .mon_render_max());
    wire s_valid, s_ready_h; wire [31:0] s_data; wire pwm_l, pwm_r, m_apply, m_mix; wire [15:0] m_drops;
    logic blk = 0;                                // +fault_noready: the transmitter stops taking samples
    wire  s_ready = s_ready_h && !blk;
    k65_audio u_aud (
        .clk(clk), .rst(rst), .reg_wr(a_wr), .reg_rd(a_rd), .reg_addr(r_addr[4:0]), .reg_wdata(r_wdata), .reg_rdata(a_rdata),
        .clk_pix(clk_pix), .rst_pix(rst_pix), .tick(t_tick), .wv_rdy(t_wrdy), .wv_s0(t_s0), .wv_s1(t_s1),
        .wv_v0(t_v0), .wv_v1(t_v1), .wv_en(t_wen),
        .sample_valid(s_valid), .sample_ready(s_ready), .sample_data(s_data), .pwm_l(pwm_l), .pwm_r(pwm_r),
        .mon_apply(m_apply), .mon_mix(m_mix), .mon_drops(m_drops));
    wire [9:0] sym0, sym1, sym2;
    k65_hdmi_tx u_hdmi (.clk(clk_pix), .rst(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .sample_valid(s_valid && !blk), .sample_data(s_data), .sample_ready(s_ready_h), .sym0(sym0), .sym1(sym1), .sym2(sym2));
    wire acc = s_valid && s_ready;
    logic fault_mon = 0;
    tb_hdmi_aud_mon u_mon (.clk(clk_pix), .rst(rst_pix), .s0(sym0), .s1(sym1), .s2(sym2),
        .acc_v(acc), .acc_d(s_data ^ {31'd0, fault_mon}), .cx(cx), .cy(cy));
    tb_pwm_check u_pwm (.clk(clk_pix), .rst(rst_pix), .sample(s_data), .pwm_l(pwm_l), .pwm_r(pwm_r));

    int errors = 0;
    task automatic fail(input string m); errors++; if (errors <= 30) $display("[%0.3f us] ERROR: %s", $realtime / 1.0e6, m); endtask

    // ------------------------------------------------------------------ tick bookkeeping
    int since_tick = 0, n_tick = 0, tick_bad = 0, last_tick_clk = -1, clk_n = 0;
    int frame_ticks = 0, n_frames = 0;
    always @(posedge clk_pix) if (!rst_pix) begin
        clk_n++; since_tick++;
        if (t_tick) begin
            if (last_tick_clk >= 0 && !(clk_n - last_tick_clk inside {1546, 1547})) begin
                tick_bad++; fail($sformatf("tick interval %0d clk_pix", clk_n - last_tick_clk));
            end
            last_tick_clk = clk_n; since_tick = 0; n_tick++; frame_ticks++;
        end
        if (cx == 0 && cy == 0) begin
            if (n_frames >= 1 && frame_ticks != 800) fail($sformatf("%0d ticks in a video frame (expected 800)", frame_ticks));
            n_frames++; frame_ticks = 0;
        end
    end
    // COMMIT handshake: longest time BUSY (STATUS b0) stays 1, in sysclk (must be < one CPU
    // bus cycle = 16 sysclk at 3.375 MHz, so that a CPU can never read BUSY = 1)
    int busy_run = 0, busy_max = 0, n_busy = 0;
    always @(posedge clk) if (!rst) begin
        if (u_aud.busy) busy_run++;
        else begin if (busy_run > 0) n_busy++; if (busy_run > busy_max) busy_max = busy_run; busy_run = 0; end
    end
    // a write must land 40..1400 clk_pix after a tick (the next tick is >= 1546 clocks away)
    task automatic safe();
        @(posedge clk_pix);
        if (since_tick < 40 || since_tick > 1400) begin
            @(posedge clk_pix iff t_tick);
            repeat (40) @(posedge clk_pix);
        end
        @(posedge clk); #1;
    endtask

    // ------------------------------------------------------------------ reference model
    typedef struct { logic [23:0] step [4]; logic [7:0] duty [4]; logic [7:0] vol [4];   // [3] of step/duty unused
                     logic [15:0] per; logic [7:0] mvol; logic [3:0] en; } cfg_t;
    cfg_t m_w, m_snap, m_a;                       // written / captured by COMMIT / active
    logic [3:0] m_prst = 0, m_prst_snap = 0;
    bit   m_pend = 0, commit_since_tick = 0, apply_since_commit = 0;
    logic [23:0] mph [3]; logic [14:0] mlfsr = 15'd1; logic [15:0] mcnt = 0;
    // wave channels (k65_vdp legacy semantics, live registers)
    logic [7:0] t_wave [2][256];
    logic [23:0] w_inc [2]; logic [7:0] w_vol [2]; logic [1:0] w_en = 0; logic [23:0] wph [2];
    logic [31:0] expq [$], prodq [$];
    int n_mix = 0, n_cmp_bad = 0, n_acc_cmp = 0, n_compat = 0, n_compat_bad = 0;
    int clamp_pos = 0, clamp_neg = 0, max_abs = 0;
    logic [7:0] lastv [6];                        // voice samples of the last tick (for the checks)
    bit compat_on = 0;
    logic [31:0] lg_at_tick;
    function automatic logic [15:0] mixside(input int acc, input logic [7:0] mv);
        int g = (acc * int'(mv)) >>> 4;
        if (g < 0 && -g > max_abs) max_abs = -g; else if (g > max_abs) max_abs = g;
        if (g > 32767)  begin clamp_pos++; return 16'h7FFF; end
        if (g < -32768) begin clamp_neg++; return 16'h8000; end
        return 16'(g);
    endfunction
    task automatic model_tick();
        logic [3:0] rp; int al = 0, ar = 0; logic signed [7:0] v [6];
        if (m_pend) begin m_a = m_snap; rp = m_prst_snap; m_pend = 0;
            if (!apply_since_commit) fail("COMMIT not applied before the next tick");
        end else rp = 4'd0;
        commit_since_tick = 0;
        for (int c = 0; c < 3; c++) begin
            logic [23:0] pe = rp[c] ? 24'd0 : mph[c];
            if (m_a.en[c]) begin
                v[c] = (m_a.step[c] == 0 || m_a.duty[c] == 0) ? 8'sd0 : (pe[23:16] < m_a.duty[c]) ? 8'sd127 : -8'sd127;
                mph[c] = pe + m_a.step[c];
            end else begin v[c] = 0; mph[c] = pe; end
        end
        begin
            logic [14:0] le = rp[3] ? 15'd1 : mlfsr; logic [15:0] ce = rp[3] ? m_a.per : mcnt;
            if (m_a.en[3]) begin
                v[3] = le[14] ? 8'sd127 : -8'sd127;
                if (ce == 0) begin mlfsr = {le[13:0], le[14] ^ le[13]}; mcnt = m_a.per; end
                else begin mlfsr = le; mcnt = ce - 1; end
            end else begin v[3] = 0; mlfsr = le; mcnt = ce; end
        end
        for (int c = 0; c < 2; c++) begin
            wph[c] = w_en[c] ? wph[c] + w_inc[c] : 24'd0;
            v[4 + c] = w_en[c] ? $signed(t_wave[c][wph[c][23:16]]) : 8'sd0;
        end
        for (int c = 0; c < 6; c++) begin
            logic [7:0] vol = (c < 4) ? m_a.vol[c] : w_vol[c - 4];
            al += int'(v[c]) * int'(vol[7:4]); ar += int'(v[c]) * int'(vol[3:0]);
            lastv[c] = v[c];
        end
        expq.push_back({mixside(ar, m_a.mvol), mixside(al, m_a.mvol)});
        compat_on = (m_a.en == 0) && (w_en == 2'b11) && (m_a.mvol == 8'd128);
    endtask
    always @(posedge clk_pix) if (!rst_pix && t_tick) model_tick();
    always @(posedge clk_pix) if (!rst_pix && m_apply) apply_since_commit = 1;
    // compare at the DUT's mix point; then produced -> accepted by the HDMI transmitter
    // (same order, nothing lost or repeated). One block: a sample can be produced and
    // accepted in the same clock, so the push must come before the pop.
    always @(negedge clk_pix) if (!rst_pix) begin
      if (m_mix) begin
        logic [31:0] e;
        n_mix++;
        prodq.push_back(s_data);
        if (expq.size() == 0) fail("mixed sample without a model sample");
        else begin
            e = expq.pop_front();
            if (s_data !== e) begin n_cmp_bad++; if (n_cmp_bad <= 10) fail($sformatf("sample #%0d = %08h, model %08h", n_mix, s_data, e)); end
        end
        if (compat_on) begin
            n_compat++;
            if (s_data !== lg_data) begin n_compat_bad++; if (n_compat_bad <= 5) fail($sformatf("wave-only sample %08h != legacy k65_vdp mix %08h", s_data, lg_data)); end
        end
      end
      if (acc) begin
        logic [31:0] p;
        n_acc_cmp++;
        if (prodq.size() == 0) fail("transmitter accepted a sample that was not produced");
        else begin p = prodq.pop_front(); if (s_data !== p) fail($sformatf("accepted sample %08h != produced %08h (dropped or repeated sample)", s_data, p)); end
      end
    end

    // ------------------------------------------------------------------ register access
    // the caller has called safe(); the model is updated at the same time as the write
    task automatic bus(input bit aud, input [5:0] a, input [7:0] d);
        r_addr = a; r_wdata = d;
        if (aud) a_wr = 1; else v_wr = 1;
        @(posedge clk); #1; a_wr = 0; v_wr = 0;
        repeat (14) @(posedge clk);
    endtask
    task automatic awr(input [4:0] a, input [7:0] d);
        int c = a[4:3];
        safe();
        if (a[4:3] != 2'd3) case (a[2:0])
            3'd0: m_w.step[c][7:0] = d; 3'd1: m_w.step[c][15:8] = d; 3'd2: m_w.step[c][23:16] = d;
            3'd3: m_w.duty[c] = d; 3'd4: m_w.vol[c] = d; default: ;
        endcase else case (a[2:0])
            3'd0: m_w.per[7:0] = d; 3'd1: m_w.per[15:8] = d; 3'd2: m_w.vol[3] = d; 3'd3: m_w.mvol = d;
            3'd4: m_w.en = d[3:0]; 3'd5: m_prst = d[3:0];
            3'd7: begin m_snap = m_w; m_prst_snap = m_prst; m_prst = 0; m_pend = 1; apply_since_commit = 0; end
            default: ;
        endcase
        bus(1, {1'b0, a}, d);
    endtask
    task automatic ard(input [4:0] a, output [7:0] d);
        safe();
        r_addr = {1'b0, a};
        repeat (2) @(posedge clk); d = a_rdata;
        #1; a_rd = 1; @(posedge clk); #1; a_rd = 0;
        repeat (13) @(posedge clk);
    endtask
    task automatic commit(); awr(5'h1F, 8'h00); endtask
    task automatic vwr(input [5:0] a, input [7:0] d);
        safe();
        case (a)
            6'd16: w_inc[0][7:0] = d; 6'd17: w_inc[0][15:8] = d; 6'd18: w_inc[0][23:16] = d; 6'd19: w_vol[0] = d;
            6'd20: w_inc[1][7:0] = d; 6'd21: w_inc[1][15:8] = d; 6'd22: w_inc[1][23:16] = d; 6'd23: w_vol[1] = d;
            6'd24: w_en = d[1:0];
            default: ;
        endcase
        bus(0, a, d);
    endtask
    task automatic set_pulse(input int c, input [23:0] step, input [7:0] duty, input [7:0] vol);
        awr(5'(c * 8 + 0), step[7:0]); awr(5'(c * 8 + 1), step[15:8]); awr(5'(c * 8 + 2), step[23:16]);
        awr(5'(c * 8 + 3), duty); awr(5'(c * 8 + 4), vol);
    endtask
    task automatic set_wave_inc(input int c, input [23:0] inc); vwr(6'(16 + 4 * c), inc[7:0]); vwr(6'(17 + 4 * c), inc[15:8]); vwr(6'(18 + 4 * c), inc[23:16]); endtask
    // wave memory: VRAM $09A00 + 256*c + n, written as 16-bit words (even byte held, odd byte writes)
    logic [7:0] wbuf [256];
    task automatic put_wave(input int c, input int first, input int n);   // n even, first even
        logic [16:0] a = 17'h09A00 + 17'(256 * c + first);
        vwr(0, a[7:0]); vwr(1, a[15:8]); vwr(2, {7'd0, a[16]});
        for (int i = first; i < first + n; i += 2) begin
            vwr(3, wbuf[i]);
            safe(); t_wave[c][i] = wbuf[i]; t_wave[c][i + 1] = wbuf[i + 1];   // the odd byte writes the word
            bus(0, 6'd3, wbuf[i + 1]);
        end
    endtask
    task automatic ticks(input int n); repeat (n) @(posedge clk_pix iff t_tick); endtask

    // ------------------------------------------------------------------ measurements
    // rising zero crossings of L (accepted samples) while meas_on
    // frequency = (crossings - 1) periods between the first and the last crossing; each crossing
    // is quantised to one sample, so the error is at most 2 samples over that span
    bit meas_on = 0; int meas_x = 0, meas_n = 0, meas_first = 0, meas_last = 0; logic signed [15:0] meas_prev = 0;
    always @(negedge clk_pix) if (!rst_pix && acc && meas_on) begin
        logic signed [15:0] l = s_data[15:0];
        if (meas_n > 0 && meas_prev <= 0 && l > 0) begin
            if (meas_x == 0) meas_first = meas_n;
            meas_last = meas_n; meas_x++;
        end
        meas_prev = l; meas_n++;
    end
    task automatic measure(input string what, input int n, input real f_exp);
        real f, tol; int lo, hi, span;
        meas_x = 0; meas_n = 0; meas_prev = 0; meas_on = 1; ticks(n); meas_on = 0;
        span = meas_last - meas_first;
        f = (meas_x > 1) ? (meas_x - 1) * 48000.0 / span : 0.0;
        tol = f_exp * 2.0 / span;
        lo = $floor(f_exp * meas_n / 48000.0) - 1; hi = $ceil(f_exp * meas_n / 48000.0) + 1;
        $display("FREQ %s: %0d rising crossings in %0d samples, %0d periods in %0d samples -> %0.3f Hz (expected %0.3f Hz, tolerance %0.3f)",
                 what, meas_x, meas_n, meas_x - 1, span, f, f_exp, tol);
        if (meas_x < lo || meas_x > hi) fail($sformatf("frequency %s: %0d crossings, expected %0d..%0d", what, meas_x, lo, hi));
        if (f < f_exp - tol || f > f_exp + tol) fail($sformatf("frequency %s: %0.3f Hz", what, f));
    endtask
    // noise bit sequence (sign of L) while noise_on
    bit noise_on = 0; bit nbits [$];
    always @(negedge clk_pix) if (!rst_pix && m_mix && noise_on) nbits.push_back(!s_data[15]);
    // clamp counters per segment
    task automatic seg(input string name);
        $display("SEG %-28s tick %0d: model clamps +%0d/-%0d so far, max |pre-clamp| %0d", name, n_tick, clamp_pos, clamp_neg, max_abs);
    endtask

    // ------------------------------------------------------------------ scenario
    initial begin
        logic [7:0] d; int seed;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        void'($urandom(seed));
        for (int c = 0; c < 4; c++) begin m_w.step[c] = 0; m_w.duty[c] = 0; end for (int c = 0; c < 3; c++) mph[c] = 0;
        for (int c = 0; c < 4; c++) m_w.vol[c] = 0;
        m_w.per = 0; m_w.mvol = 8'd32; m_w.en = 0; m_a = m_w; m_snap = m_w;
        for (int c = 0; c < 2; c++) begin w_inc[c] = 0; w_vol[c] = 0; wph[c] = 0; for (int i = 0; i < 256; i++) t_wave[c][i] = 8'h00; end
        if ($test$plusargs("fault_mvol"))   force u_aud.y_mvol = 8'd31;
        if ($test$plusargs("fault_lfsr"))   force u_aud.lfsr[0] = 1'b1;
        if ($test$plusargs("fault_pwm"))    force u_aud.pwm_l = 1'b0;
        if ($test$plusargs("fault_commit")) force u_aud.c_m = 1'b0;
        if ($test$plusargs("fault_hdmimon")) fault_mon = 1;
        wait (!rst && !rst_pix);
        ticks(4);

        seg("reset state / read-back");
        ard(5'h1B, d); if (d !== 8'd32) fail($sformatf("MVOL reset %02h", d));
        ard(5'h1E, d); if (d !== 8'h00) fail($sformatf("STATUS after reset %02h", d));
        begin   // every register: write a random value, read it back, then restore 0 (no COMMIT)
            logic [7:0] wv [32];
            int regs [17] = '{0,1,2,3,4,8,9,10,11,12,16,17,18,19,20,24,25};
            foreach (regs[i]) begin wv[regs[i]] = 8'($urandom); awr(5'(regs[i]), wv[regs[i]]); end
            awr(5'h1A, 8'h5A); awr(5'h1C, 8'h0F); awr(5'h1D, 8'h0A);
            foreach (regs[i]) begin ard(5'(regs[i]), d); if (d !== wv[regs[i]]) fail($sformatf("read-back $D4%02h = %02h, wrote %02h", regs[i], d, wv[regs[i]])); end
            ard(5'h1A, d); if (d !== 8'h5A) fail("read-back NOISE VOL");
            ard(5'h1C, d); if (d !== 8'h0F) fail("read-back ENABLE");
            ard(5'h1D, d); if (d !== 8'h0A) fail("read-back PRST");
            ard(5'h05, d); if (d !== 8'h00) fail("unused register $D405 not 0");
            foreach (regs[i]) awr(5'(regs[i]), 8'h00);
            awr(5'h1A, 8'h00); awr(5'h1C, 8'h00); awr(5'h1D, 8'h00);
        end
        ticks(50);   // nothing committed: output must stay 0 (model)
        // STATUS read in the bus cycle right after COMMIT: BUSY must already be 0
        for (int k = 0; k < 4; k++) begin commit(); ard(5'h1E, d); if (d[0]) fail("STATUS BUSY = 1 in the cycle after COMMIT"); end

        // ---------------- Phase 1: the existing wave channels
        seg("wave: legacy compatibility");
        for (int c = 0; c < 2; c++) begin for (int i = 0; i < 256; i++) wbuf[i] = 8'($urandom); put_wave(c, 0, 256); end
        awr(5'h1B, 8'd128); commit();              // MVOL 128 = the earlier wave-only scale (x8)
        set_wave_inc(0, 24'd153791); set_wave_inc(1, 24'd1234567);   // 440 Hz / 3532 Hz
        vwr(19, 8'hF3); vwr(23, 8'h5C); vwr(24, 8'h03);
        ticks(2000);
        seg("wave: volume / frequency changes");
        vwr(19, 8'h0F); ticks(300); vwr(19, 8'hF0); vwr(23, 8'hFF); ticks(300);
        set_wave_inc(0, 24'hFFFFFF); ticks(300); set_wave_inc(0, 24'd1); ticks(300);
        seg("wave: table update while playing");
        for (int k = 0; k < 8; k++) begin
            for (int i = 0; i < 256; i++) wbuf[i] = 8'($urandom);
            put_wave(k % 2, 32 * k, 32); ticks(50);
        end
        seg("wave: disable / enable");
        vwr(24, 8'h01); ticks(200); vwr(24, 8'h02); ticks(200); vwr(24, 8'h03); ticks(200);
        seg("wave: frequency");
        for (int i = 0; i < 256; i++) wbuf[i] = (i < 128) ? 8'd100 : -8'sd100;
        put_wave(0, 0, 256); vwr(24, 8'h01); vwr(19, 8'hFF); set_wave_inc(0, 24'd153791);
        ticks(2); measure("wave0 440 Hz", 4800, 440.0 * 1.0);
        vwr(24, 8'h00);
        $display("wave-only samples compared with the legacy mix: %0d (mismatch %0d)", n_compat, n_compat_bad);
        if (n_compat < 3000) fail("too few legacy-compatible samples compared");

        // ---------------- Phase 2: pulse + noise
        seg("pulse: frequency");
        awr(5'h1B, 8'd32);
        set_pulse(0, 24'd153791, 8'd128, 8'hFF); awr(5'h1C, 8'h01); commit();
        ticks(2); measure("pulse0 440 Hz", 4800, 153791 * 48000.0 / 16777216.0);
        set_pulse(1, 24'd349525, 8'd64, 8'hF0); awr(5'h1C, 8'h02); commit();
        ticks(2); measure("pulse1 1000 Hz duty 1/4", 4800, 349525 * 48000.0 / 16777216.0);
        set_pulse(2, 24'd4194304, 8'd128, 8'hFF); awr(5'h1C, 8'h04); commit();
        ticks(2); measure("pulse2 12 kHz", 2400, 4194304 * 48000.0 / 16777216.0);
        seg("pulse: duty / step boundaries");
        begin
            logic [7:0] du [7] = '{8'd0, 8'd1, 8'd2, 8'd127, 8'd128, 8'd254, 8'd255};
            for (int k = 0; k < 7; k++) begin set_pulse(0, 24'd65536, du[k], 8'hFF); awr(5'h1C, 8'h01); commit(); ticks(300); end
        end
        set_pulse(0, 24'd0, 8'd128, 8'hFF); commit(); ticks(50);                 // STEP 0: silent
        set_pulse(0, 24'h7FFFFF, 8'd128, 8'hFF); commit(); ticks(100);
        set_pulse(0, 24'h800000, 8'd128, 8'hFF); commit(); ticks(100);
        set_pulse(0, 24'hFFFFFF, 8'd200, 8'hFF); commit(); ticks(100);
        seg("pulse: enable hold / phase reset");
        set_pulse(0, 24'd100003, 8'd77, 8'hF7); set_pulse(1, 24'd200001, 8'd200, 8'h7F); set_pulse(2, 24'd300007, 8'd128, 8'h88);
        awr(5'h1C, 8'h07); commit(); ticks(137);
        awr(5'h1C, 8'h05); commit(); ticks(91);                                   // p1 held
        awr(5'h1C, 8'h07); commit(); ticks(57);                                   // p1 continues
        awr(5'h1D, 8'h02); commit(); ticks(45);                                   // p1 phase reset (enabled)
        awr(5'h1C, 8'h06); awr(5'h1D, 8'h01); commit(); ticks(33);                // p0 reset while disabled
        awr(5'h1C, 8'h07); commit(); ticks(60);
        seg("pulse: commit atomicity");
        awr(5'h00, 8'h55); awr(5'h01, 8'h66); awr(5'h04, 8'h11); ticks(200);      // not committed yet
        awr(5'h02, 8'h03); commit(); ticks(100);
        seg("noise: full period (PERIOD 0)");
        awr(5'h1C, 8'h00); commit(); ticks(3);
        awr(5'h18, 8'h00); awr(5'h19, 8'h00); awr(5'h1A, 8'h10); awr(5'h1C, 8'h08); awr(5'h1D, 8'h08);
        commit(); ticks(1);
        nbits.delete(); noise_on = 1; ticks(32767 + 600); noise_on = 0;
        begin
            int n = nbits.size(), bad = 0, ones = 0;
            int divs [6] = '{7, 31, 151, 217, 1057, 4681};
            for (int i = 0; i + 32767 < n; i++) if (nbits[i] != nbits[i + 32767]) bad++;
            for (int i = 0; i < 32767; i++) ones += nbits[i];
            $display("NOISE: %0d bits recorded, period-32767 mismatches %0d, ones in one period %0d (m-sequence: 16384)", n, bad, ones);
            if (n < 33000 || bad != 0) fail("noise sequence is not periodic with 32767");
            if (ones != 16384) fail("noise period does not hold 16384 ones");
            foreach (divs[k]) begin
                bit per = 1;
                for (int i = 0; i + divs[k] < 32767; i++) if (nbits[i] != nbits[i + divs[k]]) begin per = 0; break; end
                if (per) fail($sformatf("noise is periodic with %0d (< 32767)", divs[k]));
            end
        end
        seg("noise: PERIOD semantics");
        awr(5'h18, 8'd5); commit(); ticks(40);                                    // reload only at COUNT 0
        awr(5'h18, 8'd2); commit(); ticks(40);
        awr(5'h1D, 8'h08); commit(); ticks(40);                                   // reset: LFSR 1, COUNT = PERIOD
        awr(5'h18, 8'hFF); awr(5'h19, 8'h01); awr(5'h1D, 8'h08); commit(); ticks(1200);
        awr(5'h1C, 8'h00); commit(); ticks(20); awr(5'h1C, 8'h08); commit(); ticks(600);   // held while disabled

        // ---------------- Phase 3: mixer gain and clipping
        seg("mix: 6 voices full scale, MVOL 32");
        for (int i = 0; i < 256; i++) wbuf[i] = 8'd127;
        put_wave(0, 0, 256); put_wave(1, 0, 256);
        set_wave_inc(0, 24'd1000); set_wave_inc(1, 24'd2000); vwr(19, 8'hFF); vwr(23, 8'hFF); vwr(24, 8'h03);
        set_pulse(0, 24'd1, 8'd255, 8'hFF); set_pulse(1, 24'd1, 8'd255, 8'hFF); set_pulse(2, 24'd1, 8'd255, 8'hFF);
        awr(5'h18, 8'd0); awr(5'h19, 8'd0); awr(5'h1A, 8'hFF); awr(5'h1B, 8'd32); awr(5'h1C, 8'h0F); awr(5'h1D, 8'h0F); commit();
        begin
            int cp = clamp_pos, cn = clamp_neg; max_abs = 0;
            ticks(2000);
            $display("MIX MVOL 32, all six voices at +-full scale: max |sample| %0d, clamps %0d (expected max 22860, 0 clamps)", max_abs, clamp_pos + clamp_neg - cp - cn);
            if (clamp_pos + clamp_neg != cp + cn) fail("clipping at the reset MVOL with six voices");
            if (max_abs != 22860) fail($sformatf("six-voice full-scale peak %0d (expected 22860)", max_abs));
            for (int i = 0; i < 256; i++) wbuf[i] = -8'sd128;
            put_wave(0, 0, 256); put_wave(1, 0, 256);
            // duty 1: +127 only while phase[23:16] == 0 (1 tick in 16 with this STEP)
            set_pulse(0, 24'h100000, 8'd1, 8'hFF); set_pulse(1, 24'h100000, 8'd1, 8'hFF); set_pulse(2, 24'h100000, 8'd1, 8'hFF);
            awr(5'h1D, 8'h07); commit(); ticks(1); max_abs = 0;
            ticks(2000);
            $display("MIX MVOL 32, negative full scale: max |sample| %0d, clamps %0d (expected 22920, 0)", max_abs, clamp_pos + clamp_neg - cp - cn);
            if (clamp_pos + clamp_neg != cp + cn) fail("clipping at the reset MVOL with six voices (negative)");
            if (max_abs != 22920) fail($sformatf("six-voice negative peak %0d (expected 22920)", max_abs));
        end
        seg("mix: MVOL 255 clipping");
        begin
            int cp = clamp_pos, cn = clamp_neg;
            awr(5'h1B, 8'd255); commit(); ticks(500);                            // negative clip
            for (int i = 0; i < 256; i++) wbuf[i] = 8'd127;
            put_wave(0, 0, 256); put_wave(1, 0, 256);
            set_pulse(0, 24'd1, 8'd255, 8'hFF); set_pulse(1, 24'd1, 8'd255, 8'hFF); set_pulse(2, 24'd1, 8'd255, 8'hFF);
            commit(); ticks(500);                                                 // positive clip
            $display("MIX MVOL 255: clamps +%0d / -%0d", clamp_pos - cp, clamp_neg - cn);
            if (clamp_pos - cp < 100 || clamp_neg - cn < 100) fail("clipping not exercised in both directions");
        end
        seg("mix: pan / volume 0 / MVOL 0");
        set_pulse(0, 24'd153791, 8'd128, 8'hF0); set_pulse(1, 24'd99999, 8'd128, 8'h0F); set_pulse(2, 24'd77777, 8'd50, 8'h00);
        awr(5'h1A, 8'h81); awr(5'h1B, 8'd32); vwr(19, 8'h3C); vwr(23, 8'h00); commit(); ticks(800);
        awr(5'h1B, 8'd0); commit(); ticks(200);
        awr(5'h1B, 8'd17); commit(); ticks(200);

        // ---------------- random stress: random registers, commits and wave edits
        seg("random");
        for (int r = 0; r < 120; r++) begin
            int k = $urandom % 10;
            case (k)
                0, 1: begin set_pulse($urandom % 3, 24'($urandom), 8'($urandom), 8'($urandom)); commit(); end
                2: begin awr(5'h18, 8'($urandom % 8)); awr(5'h19, 8'h00); awr(5'h1A, 8'($urandom)); commit(); end
                3: begin awr(5'h1C, 8'($urandom)); awr(5'h1D, 8'($urandom)); commit(); end
                4: begin awr(5'h1B, 8'($urandom % 64)); commit(); end
                5: begin set_wave_inc($urandom % 2, 24'($urandom)); end
                6: begin vwr(6'(19 + 4 * ($urandom % 2)), 8'($urandom)); vwr(24, 8'($urandom)); end
                7: begin int c = $urandom % 2, f = 2 * ($urandom % 120); wbuf[f] = 8'($urandom); wbuf[f + 1] = 8'($urandom);
                          for (int i = 0; i < 16; i++) wbuf[f + i] = 8'($urandom); put_wave(c, f, 16); end
                8: begin awr(5'(($urandom % 3) * 8 + 3), 8'($urandom)); end        // written, not committed
                default: ;
            endcase
            ticks(1 + $urandom % 60);
        end

        // ---------------- negative test: the transmitter stops taking samples
        if ($test$plusargs("fault_noready")) begin
            seg("fault: no ready");
            blk = 1; ticks(4); blk = 0; ticks(4);
            ard(5'h1E, d); $display("STATUS after blocking = %02h, DUT drop count %0d", d, m_drops);
            if (d[1] && m_drops > 0) fail("samples were dropped (DROP status set)");
            ard(5'h1E, d); if (d[1]) fail("STATUS DROP not cleared by reading");
        end
        ticks(20);
        ard(5'h1E, d);
        if (d !== 8'h00) fail($sformatf("STATUS at the end %02h (BUSY / DROP)", d));
        if (m_drops != 0) fail($sformatf("%0d samples dropped", m_drops));

        $display("%s", u_mon.summary());
        $display("%s", u_pwm.summary());
        $display("TICKS %0d, video frames %0d, bad tick intervals %0d", n_tick, n_frames, tick_bad);
        $display("COMMIT: %0d handshakes, BUSY at most %0d sysclk (a CPU bus cycle is 16)", n_busy, busy_max);
        if (n_busy < 50 || busy_max >= 16) fail("COMMIT handshake too slow (or not exercised)");
        $display("SAMPLES mixed %0d, model mismatches %0d, accepted %0d, legacy-compatible %0d (mismatch %0d), model clamps +%0d / -%0d",
                 n_mix, n_cmp_bad, n_acc_cmp, n_compat, n_compat_bad, clamp_pos, clamp_neg);
        if (u_mon.errors) fail("HDMI audio monitor errors");
        if (u_pwm.errors) fail("PWM check errors");
        if (u_mon.n_dec < n_acc_cmp - 8) fail("decoded fewer samples than were accepted");
        if (n_mix < 60000) fail("too few samples");
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #(3s); fail("timeout"); $display("RESULT: FAIL"); $finish; end
endmodule
