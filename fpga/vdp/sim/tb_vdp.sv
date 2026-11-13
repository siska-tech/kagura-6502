// KAGURA-6502 VDP unit testbench (Verilator 5, --timing).
//   k65_vdp (DUT) + k65_hdmi_tx (gives cx/cy and takes audio samples, as on the board).
//   The CPU side is driven directly through the register port (writes >= 16 sysclk apart,
//   like a 3.375 MHz W65C02S).
// Check: one whole 1280x720 frame is compared pixel by pixel with an INDEPENDENT reference
// renderer written here (per-pixel, from the tb's own copy of VRAM; not the DUT's line
// algorithm): border lines, background with fine scroll + map wrap + flips, out-of-range
// pattern = transparent, sprites 8x8 / 16x16 with flips, priority (lower index on top),
// 64-per-line limit, clipping at all four edges of the 320x176 area, palettes.
// Also: VDATA read-back (patterns / map / OAM), STATUS vblank once per frame, render
// overrun, HDMI line / frame period, audio samples (wave memory through the shared port).
// Plusargs: +seed=N
`timescale 1ps/1ps
module tb_vdp #(
    parameter integer NPAT     = 1024,
    parameter integer PAT_FLAT = 0,
    parameter integer SHARE_PW = 1,
    parameter integer OAM_DBL  = 0,
    parameter         PAL_FILE = "../rtl/vdp_palette.hex",
    parameter         PAL256_FILE = "../rtl/vdp_palette256.hex"
);
    logic clk = 0, clk_pix = 0;
    always #9259 clk = ~clk;                    // 54 MHz
    always #6734 clk_pix = ~clk_pix;            // 74.25 MHz
    logic rst = 1, rst_pix = 1;
    initial begin repeat (20) @(posedge clk); rst = 0; end
    initial begin repeat (20) @(posedge clk_pix); rst_pix = 0; end

    logic reg_wr = 0, reg_rd = 0; logic [5:0] reg_addr = 0; logic [7:0] reg_wdata = 0;
    wire [7:0] reg_rdata; wire irq;
    wire [10:0] cx; wire [9:0] cy; wire [23:0] rgb;
    wire s_valid, s_ready; wire [31:0] s_data;
    wire ovr; wire [12:0] rmax;
    k65_vdp #(.NPAT(NPAT), .PAT_FLAT(PAT_FLAT), .SHARE_PW(SHARE_PW), .OAM_DBL(OAM_DBL), .PAL_FILE(PAL_FILE), .PAL256_FILE(PAL256_FILE)) dut (
        .clk(clk), .rst(rst), .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata), .irq(irq), .clk_pix(clk_pix), .rst_pix(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .sample_valid(s_valid), .sample_ready(s_ready), .sample_data(s_data), .pwm_l(), .pwm_r(),
        .mon_render_ovr(ovr), .mon_render_max(rmax));
    k65_hdmi_tx u_hdmi (.clk(clk_pix), .rst(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .sample_valid(s_valid), .sample_data(s_data), .sample_ready(s_ready), .sym0(), .sym1(), .sym2());

    integer errors = 0;
    task automatic fail(input string m); errors++; if (errors <= 30) $display("[%0.3f us] ERROR: %s", $realtime / 1.0e6, m); endtask

    // ------------------------------------------------------------------ CPU-side access
    task automatic wr(input [5:0] a, input [7:0] d);
        @(posedge clk); #1; reg_addr = a; reg_wdata = d; reg_wr = 1;
        @(posedge clk); #1; reg_wr = 0;
        repeat (14) @(posedge clk);
    endtask
    task automatic rd(input [5:0] a, output [7:0] d);
        @(posedge clk); #1; reg_addr = a;
        repeat (2) @(posedge clk); d = reg_rdata;           // value seen by the CPU
        #1; reg_rd = 1; @(posedge clk); #1; reg_rd = 0;      // end of the bus cycle
        repeat (13) @(posedge clk);
    endtask
    task automatic setaddr(input [16:0] a); wr(0, a[7:0]); wr(1, a[15:8]); wr(2, {7'd0, a[16]}); endtask

    // ------------------------------------------------------------------ tb copy of VRAM
    logic [7:0]  t_pat [0:1023][0:31];
    logic [15:0] t_map [0:2047];
    logic [7:0]  t_oam [0:255][0:7];
    logic [15:0] t_pal [0:511];
    logic [7:0]  t_ctrl = 8'h03, t_border = 0, t_scy = 0; logic [8:0] t_scx = 0;
    initial $readmemh(PAL_FILE, t_pal);

    task automatic vram_write_bytes(input [16:0] a, input int n, input logic [7:0] b [0:63]);
        setaddr(a);
        for (int i = 0; i < n; i++) wr(3, b[i]);
    endtask
    task automatic put_pattern(input int p);
        logic [7:0] b [0:63];
        for (int i = 0; i < 32; i++) begin b[i] = 8'($urandom); t_pat[p][i] = (p < NPAT) ? b[i] : 8'h00; end
        // make some pixels transparent (nibble 0) on purpose
        b[5] = 8'h0F; b[18] = 8'hF0; if (p < NPAT) begin t_pat[p][5] = 8'h0F; t_pat[p][18] = 8'hF0; end
        vram_write_bytes(17'(p * 32), 32, b);
    endtask
    task automatic put_map(input int idx, input [15:0] v);
        logic [7:0] b [0:63]; b[0] = v[7:0]; b[1] = v[15:8];
        t_map[idx] = v; vram_write_bytes(17'h08000 + 17'(idx * 2), 2, b);
    endtask
    task automatic put_spr(input int n, input int x, input int y, input [9:0] pat, input bit big,
                           input bit hf, input bit vf, input [3:0] pal, input bit en);
        logic [7:0] b [0:63];
        b[0] = 8'(y); b[1] = {en, big, 5'd0, 1'(y >> 8)}; b[2] = 8'(x); b[3] = {7'd0, 1'(x >> 8)};
        b[4] = pat[7:0]; b[5] = {2'd0, vf, hf, 2'd0, pat[9:8]}; b[6] = {4'd0, pal}; b[7] = 8'h00;
        for (int i = 0; i < 8; i++) t_oam[n][i] = b[i];
        vram_write_bytes(17'h09000 + 17'(n * 8), 8, b);
    endtask
    task automatic put_pal(input int idx, input [15:0] v);
        logic [7:0] b [0:63]; b[0] = v[7:0]; b[1] = v[15:8];
        t_pal[idx] = v; vram_write_bytes(17'h09800 + 17'(idx * 2), 2, b);
    endtask

    // ------------------------------------------------------------------ reference renderer
    function automatic [3:0] pnib(input int p, input int r, input int c);
        logic [7:0] b; if (p >= NPAT) return 4'd0;
        b = t_pat[p][r * 4 + c / 2];
        return (c % 2 == 0) ? b[7:4] : b[3:0];
    endfunction
    function automatic [23:0] rgb565(input [15:0] v);
        return {v[15:11], v[15:13], v[10:5], v[10:9], v[4:0], v[4:2]};
    endfunction
    // returns the 8-bit pixel value {pal, colour} of logical (x, sy) for active rows
    int sl [0:63]; int sl_n; int n_cand;
    int cov_spr = 0, cov_bg = 0, cov_back = 0, cov_brd = 0, cov_limit_lines = 0;
    function automatic void spr_list(input int sy);
        sl_n = 0; n_cand = 0;
        for (int n = 0; n < 256; n++) begin
            int y = {t_oam[n][1][0], t_oam[n][0]}; int h = t_oam[n][1][6] ? 16 : 8; int row = sy + 16 - y;
            if (t_oam[n][1][7] && row >= 0 && row < h) begin n_cand++; if (sl_n < 64) begin sl[sl_n] = n; sl_n++; end end
        end
        if (n_cand > 64) cov_limit_lines++;
    endfunction
    bit spr_won;
    function automatic [7:0] ref_pix(input int x, input int sy);
        int wx = (t_scx + x) & 511, wy = (t_scy + sy) & 255;
        logic [15:0] e = t_map[(wy >> 3) * 64 + (wx >> 3)];
        int r = (wy & 7) ^ (e[11] ? 7 : 0), c = (wx & 7) ^ (e[10] ? 7 : 0);
        logic [3:0] nb = pnib(e[9:0], r, c);
        logic [7:0] v = (t_ctrl[0] && nb != 0) ? {e[15:12], nb} : 8'h00;
        spr_won = 0;
        if (t_ctrl[1])
            for (int k = 0; k < sl_n; k++) begin
                int n = sl[k]; int y = {t_oam[n][1][0], t_oam[n][0]}; int xs = {t_oam[n][3][0], t_oam[n][2]};
                bit big = t_oam[n][1][6]; bit hf = t_oam[n][5][4], vf = t_oam[n][5][5];
                int w = big ? 16 : 8; int row = sy + 16 - y; int col = x + 16 - xs;
                if (col >= 0 && col < w) begin
                    int rr = vf ? (w - 1 - row) : row, cc = hf ? (w - 1 - col) : col;
                    int p = {t_oam[n][5][1:0], t_oam[n][4]} + (big ? ((rr >= 8 ? 2 : 0) + (cc >= 8 ? 1 : 0)) : 0);
                    logic [3:0] sn = pnib(p, rr & 7, cc & 7);
                    if (sn != 0) begin v = {t_oam[n][6][3:0], sn}; spr_won = 1; break; end
                end
            end
        return v;
    endfunction

    // ------------------------------------------------------------------ frame capture + compare
    int frame_no = 0, cmp_frame = -1, n_cmp = 0, n_bad = 0;
    int line_clk = 0, last_line_clk = -1, lines_in_frame = 0;
    always @(negedge clk_pix) if (!rst_pix) begin
        int X, Y;
        // pixel X was registered at the previous edge: cx now = X + 1
        if (cx == 0) begin X = 1649; Y = (cy == 0) ? 749 : cy - 1; end else begin X = cx - 1; Y = cy; end
        if (cx == 0 && cy == 0) frame_no++;
        if (frame_no == cmp_frame && X < 1280 && Y < 720) begin
            int lx = X >> 2, ly = Y >> 2; logic [23:0] e;
            if (X % 4 == 0 && Y % 4 == 0 && lx == 0 && ly >= 2 && ly < 178) spr_list(ly - 2);
            if (ly < 2 || ly >= 178) begin e = rgb565(t_pal[{4'd0, t_border[3:0]}]); cov_brd++; end
            else begin
                logic [7:0] v = ref_pix(lx, ly - 2); e = rgb565(t_pal[v[3:0] == 0 ? 8'd0 : v]);
                if (spr_won) cov_spr++; else if (v[3:0] != 0) cov_bg++; else cov_back++;
            end
            n_cmp++;
            if (rgb !== e) begin
                n_bad++;
                if (n_bad <= 12) fail($sformatf("frame pixel (%0d,%0d) logical (%0d,%0d): rgb %06h expected %06h", X, Y, lx, ly, rgb, e));
            end
        end
    end
    // HDMI period checks: 1650 clocks per line, 750 lines per frame
    int fr_clk = 0, last_fr = -1;
    always @(posedge clk_pix) if (!rst_pix) begin
        fr_clk++;
        if (cx == 0 && cy == 0) begin
            if (last_fr >= 0 && fr_clk != 1650 * 750) fail($sformatf("frame period %0d clocks (expected %0d)", fr_clk, 1650 * 750));
            last_fr = fr_clk; fr_clk = 0;
        end
    end
    // vblank status: count frames seen by a polling "CPU"
    int vb_seen = 0;
    // audio samples
    int n_samp = 0, n_samp_ok = 0; logic aud_on = 0;
    bit wavefull = 0;
    always @(posedge clk_pix) if (s_valid && s_ready) begin
        n_samp++;
        if (aud_on && !wavefull) begin
            if (s_data[15:0] == 16'(64 * 15 * 8) && s_data[31:16] == 16'(64 * 3 * 8)) n_samp_ok++;
        end
    end
    // +wavefull: both wave channels with random tables and different increments; every sample
    // accepted by the transmitter during the compared frame is predicted by a model of the
    // legacy wave player (phase += INC at the tick, sample = table[phase[23:16]], L/R =
    // (s0*vol0 + s1*vol1) << 3). The phases are taken from the DUT once (sync); the tables and
    // registers are the tb's own copies. This exercises the palette / wave read-port sharing
    // while every pixel of the frame is compared.
    logic [7:0] t_wave [2][256]; logic [23:0] w_inc [2]; logic [7:0] w_vol [2];
    logic [23:0] m_wph [2]; logic [31:0] wq [$]; bit w_sync = 0, w_on = 0, w_skip = 0;
    int w_cmp = 0, w_bad = 0, w_ticks_in_active = 0, w_ticks = 0;
    always @(posedge clk_pix) if (!rst_pix && w_on && dut.tick) begin
        logic signed [7:0] s [2]; int l = 0, r = 0;
        for (int c = 0; c < 2; c++) begin m_wph[c] = m_wph[c] + w_inc[c]; s[c] = $signed(t_wave[c][m_wph[c][23:16]]); end
        for (int c = 0; c < 2; c++) begin l += int'(s[c]) * int'(w_vol[c][7:4]); r += int'(s[c]) * int'(w_vol[c][3:0]); end
        wq.push_back({16'(r * 8), 16'(l * 8)});
        w_ticks++; if (cx < 1280 && cy < 720) w_ticks_in_active++;
    end
    always @(posedge clk_pix) if (!rst_pix && w_sync && dut.tick) begin
        #1; m_wph[0] = dut.ph0; m_wph[1] = dut.ph1; wq.delete(); w_skip = 1; w_on = 1; w_sync = 0;
    end
    always @(negedge clk_pix) if (!rst_pix && w_on && s_valid && s_ready) begin
        if (w_skip) w_skip = 0;
        else if (wq.size() == 0) fail("wave: sample without a model sample");
        else begin
            logic [31:0] e = wq.pop_front();
            w_cmp++;
            if (s_data !== e) begin w_bad++; if (w_bad <= 8) fail($sformatf("wave sample #%0d = %08h, model %08h", w_cmp, s_data, e)); end
        end
    end

    initial begin
        logic [7:0] d; int seed;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        void'($urandom(seed));
        for (int p = 0; p < 1024; p++) for (int i = 0; i < 32; i++) t_pat[p][i] = 8'h00;
        for (int i = 0; i < 2048; i++) t_map[i] = 16'h0000;
        for (int n = 0; n < 256; n++) for (int i = 0; i < 8; i++) t_oam[n][i] = 8'h00;
        wait (!rst && !rst_pix);
        repeat (100) @(posedge clk);
        // VRAM, OAM and map are not initialised by hardware: clear map and OAM first
        setaddr(17'h08000); for (int i = 0; i < 4096; i++) wr(3, 8'h00);
        setaddr(17'h09000); for (int i = 0; i < 2048; i++) wr(3, 8'h00);
        // patterns used by the map and sprites: 0..39, the last valid ones, and NPAT (out of range)
        for (int p = 0; p < 40; p++) put_pattern(p);
        for (int p = NPAT - 8; p < NPAT; p++) put_pattern(p);
        if (NPAT < 1024) put_pattern(NPAT);              // must be ignored (writes dropped, reads 0)
        // map: 40 x 23 visible window + wrap region, random entries
        for (int r = 0; r < 32; r++) for (int c = 0; c < 64; c++) begin
            int p = ($urandom % 6 == 0) ? (NPAT - 8 + $urandom % 8) : ($urandom % 40);
            if ($urandom % 40 == 0) p = NPAT < 1024 ? NPAT : 1023;   // out-of-range (or last) pattern
            if (r < 24 && (c < 44 || c >= 60)) put_map(r * 64 + c, {4'($urandom), 2'($urandom), 10'(p)});
        end
        // palettes: a few custom colours in palettes 1..3
        for (int i = 16; i < 64; i++) put_pal(i, 16'($urandom));
        // scroll: fine x/y and wrap of the 64-column map
        wr(8, 8'd243); wr(9, 8'd1); t_scx = 9'd499;      // 499 -> columns 62,63,0,1,...
        wr(10, 8'd5); t_scy = 8'd5;
        // sprites: edges, flips, sizes, priority
        put_spr(0,   16 - 4,  16 + 40, 10'd2, 1, 0, 0, 4'd1, 1);   // x = -4 (left clip)
        put_spr(1, 16 + 316,  16 + 40, 10'd6, 1, 1, 0, 4'd2, 1);   // x = 316 (right clip), hflip
        put_spr(2,  16 + 100, 16 - 5,  10'd10, 1, 0, 1, 4'd3, 1);  // y = -5 (top clip), vflip
        put_spr(3,  16 + 150, 16 + 170, 10'd14, 1, 1, 1, 4'd1, 1); // y = 170 (bottom clip, border must stay)
        put_spr(4,  16 + 104, 16 - 1,  10'd20, 0, 0, 0, 4'd2, 1);  // 8x8 overlapping sprite 2 (4 on top of 2? no: 2 wins)
        put_spr(5,  16 + 200, 16 + 80, 10'(NPAT - 8), 0, 1, 1, 4'd3, 1);
        put_spr(6,  16 + 201, 16 + 82, 10'(NPAT - 4), 1, 0, 0, 4'd1, 0); // disabled
        put_spr(7,  0,        16 + 60, 10'd3, 1, 0, 0, 4'd2, 1);         // x = -16: fully left of screen
        put_spr(8,  16 + 320, 16 + 60, 10'd3, 1, 0, 0, 4'd2, 1);         // x = 320: fully right
        put_spr(9,  16 + 50,  16 + 176, 10'd3, 1, 0, 0, 4'd2, 1);        // y = 176: fully below (border)
        // 70 sprites on one line: only the first 64 (by index) may appear
        for (int n = 20; n < 90; n++) put_spr(n, 16 + (n - 20) * 4, 16 + 120, 10'(n % 40), 0, n[0], 0, 4'(n % 4), 1);
        // +worst: every sprite 16x16 on rows 100..115 (64 drawn per line, 256 scanned)
        if ($test$plusargs("worst")) for (int n = 0; n < 256; n++) put_spr(n, 16 + (n % 40) * 8, 16 + 100, 10'(n % 36), 1, n[0], n[1], 4'(n % 4), 1);
        // border (frame-latched)
        wr(7, 8'd2); t_border = 8'd2;
        // read-back through VDATA (prefetch): pattern 3 byte 7, map entry 65, OAM sprite 1 byte 2
        setaddr(17'(3 * 32 + 7)); rd(3, d); if (d !== t_pat[3][7]) fail($sformatf("VDATA pattern read %02h exp %02h", d, t_pat[3][7]));
        rd(3, d); if (d !== t_pat[3][8]) fail("VDATA auto-increment read");
        setaddr(17'h08000 + 17'(65 * 2 + 1)); rd(3, d); if (d !== t_map[65][15:8]) fail($sformatf("VDATA map read %02h exp %02h", d, t_map[65][15:8]));
        setaddr(17'h09000 + 17'(1 * 8 + 2)); rd(3, d); if (d !== t_oam[1][2]) fail($sformatf("VDATA OAM read %02h exp %02h", d, t_oam[1][2]));
        if (NPAT < 1024) begin setaddr(17'(NPAT * 32)); rd(3, d); if (d !== 8'h00) fail("pattern beyond NPAT reads non-zero"); end
        rd(12, d); if (d !== NPAT[7:0]) fail("PATCNT_L"); rd(13, d); if (d !== {5'd0, NPAT[10:8]}) fail("PATCNT_H");
        wavefull = $test$plusargs("wavefull");
        if (!wavefull) begin
            // audio: ch0 = constant 64, L vol 15 R vol 3; ch1 off (sample index 0 = 0)
            setaddr(17'h09A00); for (int i = 0; i < 256; i++) wr(3, 8'd64);
            wr(16, 8'h00); wr(17, 8'h10); wr(18, 8'h00); wr(19, 8'hF3); wr(24, 8'h01);
        end else begin
            // both channels: random tables; INC0 = 0x123457 (~1.3 kHz), INC1 = 0x7FFFFF (~24 kHz:
            // a new table word nearly every tick); vol0 = $F3, vol1 = $5C
            setaddr(17'h09A00);
            for (int c = 0; c < 2; c++) for (int i = 0; i < 256; i++) begin t_wave[c][i] = 8'($urandom); wr(3, t_wave[c][i]); end
            w_inc[0] = 24'h123457; w_inc[1] = 24'h7FFFFF; w_vol[0] = 8'hF3; w_vol[1] = 8'h5C;
            for (int c = 0; c < 2; c++) begin
                wr(6'(16 + 4 * c), w_inc[c][7:0]); wr(6'(17 + 4 * c), w_inc[c][15:8]); wr(6'(18 + 4 * c), w_inc[c][23:16]);
                wr(6'(19 + 4 * c), w_vol[c]);
            end
            wr(24, 8'h03);
            repeat (2000) @(posedge clk);                    // registers synchronised to clk_pix
            w_sync = 1; wait (w_on);
        end
        // capture: the frame after the next frame start (all writes done, border latched)
        begin int f0 = frame_no; wait (frame_no == f0 + 1); cmp_frame = frame_no + 1; aud_on = 1; end
        if ($test$plusargs("fault_border")) force dut.border = 8'd3;           // register differs from the tb copy
        if ($test$plusargs("fault_hflip"))  force dut.r_ment[10] = 1'b0;       // background hflip ignored
        if ($test$plusargs("fault_sprpal")) force dut.s_pal = 4'd0;            // sprite palette lost
        if ($test$plusargs("fault_lbskip")) force dut.lb_wa[0] = 1'b0;         // line-buffer address bit stuck
        if ($test$plusargs("fault_wsel"))   force dut.wsel = 1'b0;             // wave byte select stuck (low byte)
        // poll STATUS during that frame: vblank must be seen exactly once per frame
        fork
            begin
                int fstart = frame_no;
                while (frame_no <= cmp_frame) begin
                    rd(6, d); if (d[7]) vb_seen++;
                    // +worst: CPU VRAM writes at the highest rate (same value -> image unchanged)
                    if ($test$plusargs("worst")) begin
                        setaddr(17'h09800 + 17'd510);
                        for (int k = 0; k < 64; k++) begin wr(3, t_pal[255][7:0]); wr(3, t_pal[255][15:8]); setaddr(17'h09800 + 17'd510); end
                    end
                end
            end
        join
        $display("compared %0d pixels, %0d mismatches; render max %0d sysclk (budget %0d), overrun=%0d",
                 n_cmp, n_bad, rmax, 4 * 1650 * 54 / 74, ovr);
        $display("coverage (HDMI pixels): sprite %0d, background %0d, backdrop %0d, border %0d; lines with > 64 sprite candidates: %0d",
                 cov_spr, cov_bg, cov_back, cov_brd, cov_limit_lines / 4);
        if (cov_spr == 0 || cov_limit_lines == 0) fail("test did not exercise sprites / the 64-sprite limit");
        $display("STATUS vblank seen %0d times over %0d frames; samples %0d (ok %0d)", vb_seen, 2, n_samp, n_samp_ok);
        if (n_cmp != 1280 * 720) fail($sformatf("compared %0d pixels (expected 921600)", n_cmp));
        if (n_bad) fail($sformatf("%0d pixel mismatches", n_bad));
        if (ovr) fail("render overrun (a line was not finished in 4 HDMI lines)");
        if (vb_seen < 1 || vb_seen > 3) fail("vblank status not seen once per frame");
        if (!wavefull && n_samp_ok < 100) fail("wave samples did not reach the expected value");
        if (wavefull) begin
            $display("WAVE: %0d samples compared with the model (%0d mismatches), %0d ticks of which %0d during active video",
                     w_cmp, w_bad, w_ticks, w_ticks_in_active);
            if (w_cmp < 1000 || w_ticks_in_active < 500) fail("wave: too few samples compared");
        end
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #(200ms); fail("timeout"); $display("RESULT: FAIL"); $finish; end
endmodule
