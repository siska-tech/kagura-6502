// HDMI audio monitor (testbench only, Verilator 5 --timing).
// Decodes the three TMDS lanes of k65_hdmi_tx independently of the transmitter: video
// guard bands / 1280-pixel video periods, data-island guard bands, TERC4 packet symbols.
// For every packet: BCH (ECC) of header and the 4 subpackets. For every audio sample
// packet (type 02): header (layout, sample_present), L/R parity, V/U = 0, low 8 bits of the
// 24-bit words = 0, IEC 60958 block-start (B) flags every 192 frames. Every decoded stereo
// sample is compared IN ORDER with the samples the transmitter accepted at its input
// (acc_v / acc_d), so a dropped, repeated or corrupted sample is reported.
// Per video frame (cx = cy = 0): number of decoded samples (expected 800 = 48 kHz / 60 Hz,
// +-4 because samples leave in packets of 4).
// Decoder functions follow fpga/phase3/sim/tb_phase3_av.sv.
module tb_hdmi_aud_mon (
    input logic        clk,
    input logic        rst,
    input logic [9:0]  s0, s1, s2,
    input logic        acc_v,          // sample accepted by the transmitter this clock
    input logic [31:0] acc_d,          // {R, L}
    input logic [10:0] cx,
    input logic [9:0]  cy
);
    localparam [9:0] GB0 = 10'b1011001100, GB1 = 10'b0100110011;
    int errors = 0, n_acc = 0, n_dec = 0, n_asp = 0, n_pkt = 0, n_frames = 0;
    int frame_dec = 0, frame_min = 1 << 30, frame_max = 0;
    logic [31:0] q [$];
    string name = "hdmi";
    task automatic fail(input string m);
        errors++;
        if (errors <= 10) $display("[%0.3f us] ERROR (%s monitor): %s", $realtime / 1.0e6, name, m);
    endtask

    function automatic logic [4:0] terc4(input logic [9:0] s);   // {valid, nibble}
        case (s)
            10'b1010011100: return 5'h10; 10'b1001100011: return 5'h11;
            10'b1011100100: return 5'h12; 10'b1011100010: return 5'h13;
            10'b0101110001: return 5'h14; 10'b0100011110: return 5'h15;
            10'b0110001110: return 5'h16; 10'b0100111100: return 5'h17;
            10'b1011001100: return 5'h18; 10'b0100111001: return 5'h19;
            10'b0110011100: return 5'h1A; 10'b1011000110: return 5'h1B;
            10'b1010001110: return 5'h1C; 10'b1001110001: return 5'h1D;
            10'b0101100011: return 5'h1E; 10'b1011000011: return 5'h1F;
            default:        return 5'h00;
        endcase
    endfunction
    function automatic logic [2:0] ctrl(input logic [9:0] s);    // {valid, c1, c0}
        case (s)
            10'b1101010100: return 3'b100; 10'b0010101011: return 3'b101;
            10'b0101010100: return 3'b110; 10'b1010101011: return 3'b111;
            default:        return 3'b000;
        endcase
    endfunction
    function automatic logic [7:0] bch_syn(input logic [63:0] cw, input int n_data);
        logic [7:0] e; e = 8'h00;
        for (int i = 0; i < n_data + 8; i++) e = (e >> 1) ^ ((e[0] ^ cw[i]) ? 8'h83 : 8'h00);
        return e;
    endfunction

    always @(posedge clk) if (!rst && acc_v) begin q.push_back(acc_d); n_acc++; end

    logic [31:0] h; logic [63:0] b [0:3];
    int pkt_bit = 0, video_left = 0, asp_idx = -1;
    logic pending_video = 0, in_island = 0;
    task automatic packet_done();
        n_pkt++;
        if (bch_syn({32'h0, h}, 24) != 0) fail($sformatf("header ECC, type %02h", h[7:0]));
        for (int j = 0; j < 4; j++) if (bch_syn(b[j], 56) != 0) fail($sformatf("subpacket %0d ECC, type %02h", j, h[7:0]));
        if (h[7:0] != 8'h02) return;
        n_asp++;
        if (h[11:8] != 4'hF || h[19:12] != 8'h00) fail($sformatf("ASP header %06h", h[23:0]));
        for (int j = 0; j < 4; j++) begin
            logic [31:0] got, exp;
            if (^{b[j][50:48], b[j][23:0]} != b[j][51]) fail("ASP: left parity");
            if (^{b[j][54:52], b[j][47:24]} != b[j][55]) fail("ASP: right parity");
            if (b[j][49:48] != 0 || b[j][53:52] != 0) fail("ASP: V/U bits not 0");
            if (b[j][7:0] != 0 || b[j][31:24] != 0) fail("ASP: low 8 bits of a 24-bit word not zero");
            if (h[20 + j]) begin
                if (asp_idx > 0) fail($sformatf("ASP: B flag at IEC frame %0d", asp_idx));
                asp_idx = 0;
            end else if (asp_idx == 0) fail("ASP: missing B flag at block start");
            if (asp_idx >= 0) asp_idx = (asp_idx + 1) % 192;
            got = {b[j][47:32], b[j][23:8]};
            n_dec++; frame_dec++;
            if (q.size() == 0) fail($sformatf("decoded sample %08h with no accepted sample pending", got));
            else begin
                exp = q.pop_front();
                if (got !== exp) fail($sformatf("decoded sample #%0d = %08h, accepted %08h", n_dec, got, exp));
            end
        end
    endtask

    always @(negedge clk) if (!rst) begin
        logic [4:0] t0, t1, t2; logic [2:0] c0; logic is_vgb, is_igb;
        t0 = terc4(s0); t1 = terc4(s1); t2 = terc4(s2); c0 = ctrl(s0);
        is_vgb = (s0 == GB0) && (s1 == GB1) && (s2 == GB0);
        is_igb = (s1 == GB1) && (s2 == GB1) && t0[4];
        if (video_left > 0) video_left--;
        else if (pending_video && !is_vgb) begin pending_video = 0; video_left = 1279; end
        else if (is_vgb) begin pending_video = 1; in_island = 0; end
        else if (is_igb) begin
            if (in_island && pkt_bit != 0) fail("island guard inside a packet");
            in_island = 1; pkt_bit = 0;
        end else if (t0[4] && t1[4] && t2[4] && in_island) begin
            logic [8:0] pb;
            pb = {t2[3:0], t1[3:0], t0[2]};
            h[pkt_bit] = pb[0];
            for (int j = 0; j < 4; j++) begin b[j][2 * pkt_bit] = pb[1 + j]; b[j][2 * pkt_bit + 1] = pb[5 + j]; end
            if (pkt_bit == 31) begin packet_done(); pkt_bit = 0; end else pkt_bit++;
        end else if (c0[2]) begin
            if (in_island && pkt_bit != 0) fail("control symbol inside a packet");
            in_island = 0;
        end else fail($sformatf("unclassified symbol %03h %03h %03h", s2, s1, s0));
    end
    // samples per video frame (the first frame after reset is partial)
    always @(posedge clk) if (!rst && cx == 0 && cy == 0) begin
        if (n_frames >= 1) begin
            if (frame_dec < frame_min) frame_min = frame_dec;
            if (frame_dec > frame_max) frame_max = frame_dec;
            if (frame_dec < 796 || frame_dec > 804) fail($sformatf("%0d samples decoded in one frame (expected 800 +- 4)", frame_dec));
        end
        n_frames++; frame_dec = 0;
    end
    function automatic string summary();
        return $sformatf("%s: packets %0d (ASP %0d), decoded samples %0d of %0d accepted (pending %0d), per frame %0d..%0d over %0d full frames, errors %0d",
                         name, n_pkt, n_asp, n_dec, n_acc, q.size(), frame_min, frame_max, n_frames > 1 ? n_frames - 1 : 0, errors);
    endfunction
endmodule
