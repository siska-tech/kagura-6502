// KAGURA-6502 compact HDMI transmitter (from scratch), fixed 1280x720p60 (CEA VIC 4).
// Pixel clock 74.25 MHz. Output: three 10-bit TMDS symbols per clock (LSB first),
// to be serialised by k65_hdmi_phy (OSER10).
//
// Video source contract (same as hdl-util/hdmi): the source REGISTERS rgb from
// (cx, cy): rgb <= f(cx, cy). The rgb seen here is then the colour of the pixel
// that was at (cx, cy) one clock earlier, which is what stage 1 encodes.
//
// Line layout (x = pixel position of the symbol):
//   0..1279     video data (lines 0..719)
//   1280..1283  control
//   1284..1291  data-island preamble  \
//   1292..1293  leading guard band     | only on lines where a packet is pending
//   1294..1325  one 32-clock packet    |  (at most one packet per line)
//   1326..1327  trailing guard band   /
//   1390..1429  hsync (positive)
//   1640..1647  video preamble        \  only before an active line
//   1648..1649  video guard band      /
// vsync (positive) lines 725..729, edges aligned to the hsync leading edge (x=1390).
//
// Packets: one per line is enough (needed ~220 per frame, 750 lines):
//   priority  audio sample (4 samples)  >  ACR (every 1 ms)  >  AIF > AVI > SPD (once per frame)
//   ACR: N=6144, CTS=74250 (48 kHz from 74.25 MHz). AVI: RGB, 16:9, VIC 4, IT content.
// Compatibility choices taken from hdl-util/hdmi (proven on hardware in KAGURA-9):
//   channel 0 bit 3 is 1 for all data-island characters; channel status / parity /
//   B-flag layout of the audio sample packet; AVI/AIF byte values.
module k65_hdmi_tx #(
    parameter [8*8-1:0]  VENDOR  = "KAGURA",          // SPD vendor (NUL padded on the right)
    parameter [8*16-1:0] PRODUCT = "KAGURA-6502"      // SPD product description
) (
    input  wire        clk,                 // pixel clock 74.25 MHz
    input  wire        rst,
    output reg  [10:0] cx,                  // pixel the source should produce now
    output reg  [9:0]  cy,
    input  wire [23:0] rgb,                 // registered by the source from cx/cy
    input  wire        sample_valid,        // 48 kHz stereo samples {right, left}
    input  wire [31:0] sample_data,
    output wire        sample_ready,
    output wire [9:0]  sym0,                // TMDS channel 0 (blue / sync / header)
    output wire [9:0]  sym1,                // channel 1 (green)
    output wire [9:0]  sym2                 // channel 2 (red)
);
    // ------------------------------------------------------------------
    // constant packets (built at elaboration; checksum included)
    // packet vector: [23:0] header, [24+56*j +: 56] subpacket j (PB 7j..7j+6)
    // ------------------------------------------------------------------
    function automatic [247:0] infoframe(input [7:0] typ, input [7:0] ver, input [4:0] len,
                                         input [8*27-1:0] pbs);     // PB1..PB27, PB1 in [7:0]
        reg [7:0] sum;
        integer i;
        begin
            sum = typ + ver + {3'b000, len};
            for (i = 0; i < 27; i = i + 1) if (i < len) sum = sum + pbs[8*i +: 8];
            infoframe = {pbs, 8'd0 - sum, 3'b000, len, ver, typ};   // {PB27..PB1, PB0=checksum, HB2..HB0}
        end
    endfunction
    // left-aligned ASCII parameter -> PB bytes, first character first
    function automatic [8*27-1:0] spd_bytes(input [8*8-1:0] v, input [8*16-1:0] p);
        reg [8*27-1:0] r;
        integer i, n;
        begin
            r = 0;
            n = 0;                                  // vendor: skip leading NULs of the literal
            for (i = 7; i >= 0; i = i - 1) if (v[8*i +: 8] != 0 || n != 0) begin
                r[8*n +: 8] = v[8*i +: 8]; n = n + 1; end
            n = 0;
            for (i = 15; i >= 0; i = i - 1) if (p[8*i +: 8] != 0 || n != 0) begin
                r[8*(8+n) +: 8] = p[8*i +: 8]; n = n + 1; end
            r[8*24 +: 8] = 8'h08;                   // PB25 source device: game
            spd_bytes = r;
        end
    endfunction
    localparam [19:0] CTS = 20'd74250, NV = 20'd6144;
    localparam [55:0] ACR_SUB = {NV[7:0], NV[15:8], 4'h0, NV[19:16], CTS[7:0], CTS[15:8], 4'h0, CTS[19:16], 8'h00};
    localparam [247:0] PKT_ACR = {ACR_SUB, ACR_SUB, ACR_SUB, ACR_SUB, 24'h000001};
    localparam [247:0] PKT_AIF = infoframe(8'h84, 8'h01, 5'd10, {{26{8'h00}}, 8'h01});
    localparam [247:0] PKT_AVI = infoframe(8'h82, 8'h02, 5'd13, {{22{8'h00}}, 8'h00, 8'h04, 8'h80, 8'h28, 8'h00});
    localparam [247:0] PKT_SPD = infoframe(8'h83, 8'h01, 5'd25, spd_bytes(VENDOR, PRODUCT));

    // ------------------------------------------------------------------
    // stage 0: position counters
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin                           // start in vertical blanking: the first active
            cx <= 11'd0; cy <= 10'd720;          // line then gets its preamble and guard band
        end else if (cx == 11'd1649) begin
            cx <= 11'd0;
            cy <= (cy == 10'd749) ? 10'd0 : cy + 10'd1;
        end else cx <= cx + 11'd1;
    end

    // ------------------------------------------------------------------
    // audio sample buffer (4 samples per audio sample packet)
    // ------------------------------------------------------------------
    reg  [31:0] smp [0:3];
    reg  [2:0]  scount;
    reg         asp_lock;                   // samples frozen while their packet is sent
    assign sample_ready = (scount != 3'd4) && !asp_lock;
    reg  [7:0]  frame_idx;                  // IEC 60958 frame index of sample 0 (0..188, step 4)

    // ------------------------------------------------------------------
    // packet scheduling (decided at x == 1280)
    // ------------------------------------------------------------------
    localparam [2:0] P_NONE = 3'd0, P_ASP = 3'd1, P_ACR = 3'd2, P_AIF = 3'd3, P_AVI = 3'd4, P_SPD = 3'd5;
    reg  [16:0] acr_t;
    reg         acr_pend;
    reg  [2:0]  if_pend;                    // {SPD, AVI, AIF}
    reg  [2:0]  sel;                        // packet of the current line
    reg         isl;                        // this line has a data island

    wire        at_decide = (cx == 11'd1280);
    wire        frame_end = (cx == 11'd1279) && (cy == 10'd719);

    always @(posedge clk) begin
        if (rst) begin
            acr_t <= 17'd0; acr_pend <= 1'b1; if_pend <= 3'b111; sel <= P_NONE; isl <= 1'b0;
            scount <= 3'd0; asp_lock <= 1'b0; frame_idx <= 8'd0;
        end else begin
            if (acr_t == 17'd74249) begin acr_t <= 17'd0; acr_pend <= 1'b1; end
            else acr_t <= acr_t + 17'd1;
            if (frame_end) if_pend <= 3'b111;
            if (sample_valid && sample_ready) begin
                smp[scount[1:0]] <= sample_data;
                scount <= scount + 3'd1;
            end
            if (at_decide) begin
                isl <= 1'b1;
                if (scount == 3'd4)      begin sel <= P_ASP; asp_lock <= 1'b1; end
                else if (acr_pend)       begin sel <= P_ACR; acr_pend <= 1'b0; end
                else if (if_pend[0])     begin sel <= P_AIF; if_pend[0] <= 1'b0; end
                else if (if_pend[1])     begin sel <= P_AVI; if_pend[1] <= 1'b0; end
                else if (if_pend[2])     begin sel <= P_SPD; if_pend[2] <= 1'b0; end
                else                     begin sel <= P_NONE; isl <= 1'b0; end
            end
            if (cx == 11'd1328) begin                  // packet finished
                isl <= 1'b0;
                if (sel == P_ASP) begin
                    asp_lock  <= 1'b0;
                    scount    <= 3'd0;
                    frame_idx <= (frame_idx == 8'd188) ? 8'd0 : frame_idx + 8'd4;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // packet bits for clock k of the packet (x = 1294 + k)
    // ------------------------------------------------------------------
    wire [4:0] k = cx[4:0] - 5'd14;                  // 1294 = 0b10100001110 -> low 5 bits 14
    // audio sample packet: subpacket j = {P_R,C_R,U_R,V_R,P_L,C_L,U_L,V_L, R24, L24}
    function automatic cs_bit(input [7:0] fi, input right);   // channel status (48 kHz, 16 bit)
        cs_bit = (fi == 8'd2) || (fi == (right ? 8'd21 : 8'd20)) || (fi == 8'd25) || (fi == 8'd33);
    endfunction
    function automatic [55:0] asp_sub(input [31:0] s, input [7:0] fi);
        reg cl, cr;
        begin
            cl = cs_bit(fi, 1'b0);
            cr = cs_bit(fi, 1'b1);
            asp_sub = {^{cr, s[31:16]}, cr, 2'b00, ^{cl, s[15:0]}, cl, 2'b00,
                       s[31:16], 8'h00, s[15:0], 8'h00};
        end
    endfunction
    wire [7:0]  fi1 = frame_idx + 8'd1, fi2 = frame_idx + 8'd2, fi3 = frame_idx + 8'd3;
    wire [23:0] asp_hdr = {fi3 == 8'd0, fi2 == 8'd0, fi1 == 8'd0, frame_idx == 8'd0, 4'h0, 8'h0F, 8'h02};
    wire [55:0] asp_s0 = asp_sub(smp[0], frame_idx), asp_s1 = asp_sub(smp[1], fi1),
                asp_s2 = asp_sub(smp[2], fi2),       asp_s3 = asp_sub(smp[3], fi3);

    reg [23:0] hdr_v;
    reg [55:0] s0_v, s1_v, s2_v, s3_v;
    always @(*) begin
        case (sel)
            P_ASP:   begin hdr_v = asp_hdr; s0_v = asp_s0; s1_v = asp_s1; s2_v = asp_s2; s3_v = asp_s3; end
            P_ACR:   begin hdr_v = PKT_ACR[23:0]; {s3_v, s2_v, s1_v, s0_v} = PKT_ACR[247:24]; end
            P_AIF:   begin hdr_v = PKT_AIF[23:0]; {s3_v, s2_v, s1_v, s0_v} = PKT_AIF[247:24]; end
            P_AVI:   begin hdr_v = PKT_AVI[23:0]; {s3_v, s2_v, s1_v, s0_v} = PKT_AVI[247:24]; end
            default: begin hdr_v = PKT_SPD[23:0]; {s3_v, s2_v, s1_v, s0_v} = PKT_SPD[247:24]; end
        endcase
    end
    // data bits of packet clock k (header: 1 bit, subpackets: bits 2k and 2k+1);
    // vectors are zero-extended so that the parity clocks (k >= 24 / 28) never index out of range
    wire [31:0] hdr32 = {8'h00, hdr_v};
    wire [63:0] s0_64 = {8'h00, s0_v}, s1_64 = {8'h00, s1_v}, s2_64 = {8'h00, s2_v}, s3_64 = {8'h00, s3_v};
    wire       hb  = hdr32[k];
    wire [5:0] kk6 = {k, 1'b0};
    wire [1:0] sd0 = s0_64[kk6 +: 2], sd1 = s1_64[kk6 +: 2], sd2 = s2_64[kk6 +: 2], sd3 = s3_64[kk6 +: 2];

    // serial BCH (G(x)=1+x^6+x^7+x^8), LSB first; parity follows the data bits
    function automatic [7:0] bch1(input [7:0] e, input d);
        bch1 = (e >> 1) ^ ((e[0] ^ d) ? 8'h83 : 8'h00);
    endfunction
    reg [7:0] eh, e0, e1, e2, e3;
    wire in_pkt = isl && (cx >= 11'd1294) && (cx <= 11'd1325);
    wire hdr_par = (k >= 5'd24);
    wire sub_par = (k >= 5'd28);
    wire       h_bit = hdr_par ? eh[0] : hb;
    wire [1:0] b0 = sub_par ? e0[1:0] : sd0, b1 = sub_par ? e1[1:0] : sd1,
               b2 = sub_par ? e2[1:0] : sd2, b3 = sub_par ? e3[1:0] : sd3;
    always @(posedge clk) begin
        if (!in_pkt) begin
            eh <= 8'd0; e0 <= 8'd0; e1 <= 8'd0; e2 <= 8'd0; e3 <= 8'd0;
        end else begin
            eh <= hdr_par ? (eh >> 1) : bch1(eh, hb);
            e0 <= sub_par ? (e0 >> 2) : bch1(bch1(e0, sd0[0]), sd0[1]);
            e1 <= sub_par ? (e1 >> 2) : bch1(bch1(e1, sd1[0]), sd1[1]);
            e2 <= sub_par ? (e2 >> 2) : bch1(bch1(e2, sd2[0]), sd2[1]);
            e3 <= sub_par ? (e3 >> 2) : bch1(bch1(e3, sd3[0]), sd3[1]);
        end
    end

    // ------------------------------------------------------------------
    // stage 1: per-symbol period / control decisions (for pixel x = cx)
    // ------------------------------------------------------------------
    wire next_line_active = (cy < 10'd719) || (cy == 10'd749);
    wire hs = (cx >= 11'd1390) && (cx < 11'd1430);
    wire vs = (cy == 10'd724) ? (cx >= 11'd1390) :
              (cy == 10'd729) ? (cx <  11'd1390) :
              (cy >= 10'd725) && (cy < 10'd729);
    localparam [2:0] M_CTL = 3'd0, M_VID = 3'd1, M_VGB = 3'd2, M_ISL = 3'd3, M_IGB = 3'd4;
    reg [2:0] m1;
    reg [1:0] c0_1, c1_1, c2_1;               // control bits per channel
    reg [3:0] n0_1, n1_1, n2_1;               // TERC4 nibbles per channel
    always @(posedge clk) begin
        if (rst) begin
            m1 <= M_CTL; c0_1 <= 2'b00; c1_1 <= 2'b00; c2_1 <= 2'b00;
            n0_1 <= 4'h0; n1_1 <= 4'h0; n2_1 <= 4'h0;
        end else begin
            c0_1 <= {vs, hs};
            c1_1 <= 2'b00; c2_1 <= 2'b00;
            if (cx < 11'd1280 && cy < 10'd720) m1 <= M_VID;
            else if (isl && (cx == 11'd1292 || cx == 11'd1293 || cx == 11'd1326 || cx == 11'd1327)) m1 <= M_IGB;
            else if (in_pkt) m1 <= M_ISL;
            else if (cx >= 11'd1648 && next_line_active) m1 <= M_VGB;
            else m1 <= M_CTL;
            // preambles: data island CTL0..3 = 1,0,1,0 ; video CTL0..3 = 1,0,0,0
            if (isl && cx >= 11'd1284 && cx < 11'd1292) begin c1_1 <= 2'b01; c2_1 <= 2'b01; end
            if (cx >= 11'd1640 && cx < 11'd1648 && next_line_active) c1_1 <= 2'b01;
            // island characters: ch0 = {bit3=1, header bit / guard 1, vsync, hsync}
            n0_1 <= {1'b1, in_pkt ? h_bit : 1'b1, vs, hs};
            n1_1 <= {b3[0], b2[0], b1[0], b0[0]};
            n2_1 <= {b3[1], b2[1], b1[1], b0[1]};
        end
    end

    // ------------------------------------------------------------------
    // TMDS encoders (2 more pipeline stages)
    // ------------------------------------------------------------------
    k65_tmds_enc #(.CH(0)) u_e0 (.clk(clk), .mode(m1), .d(rgb[7:0]),   .c(c0_1), .nib(n0_1), .q(sym0));
    k65_tmds_enc #(.CH(1)) u_e1 (.clk(clk), .mode(m1), .d(rgb[15:8]),  .c(c1_1), .nib(n1_1), .q(sym1));
    k65_tmds_enc #(.CH(2)) u_e2 (.clk(clk), .mode(m1), .d(rgb[23:16]), .c(c2_1), .nib(n2_1), .q(sym2));
endmodule

// One TMDS channel: video 8b/10b with DC balance, control, TERC4, guard bands.
// Latency: 2 clocks from (mode, d, c, nib) to q.
module k65_tmds_enc #(
    parameter integer CH = 0
) (
    input  wire       clk,
    input  wire [2:0] mode,          // 0 control, 1 video, 2 video guard, 3 island, 4 island guard
    input  wire [7:0] d,
    input  wire [1:0] c,
    input  wire [3:0] nib,
    output reg  [9:0] q
);
    function automatic [3:0] pop8(input [7:0] v);
        pop8 = {3'd0, v[0]} + {3'd0, v[1]} + {3'd0, v[2]} + {3'd0, v[3]} +
               {3'd0, v[4]} + {3'd0, v[5]} + {3'd0, v[6]} + {3'd0, v[7]};
    endfunction
    function automatic [9:0] terc4(input [3:0] n);
        case (n)
            4'h0: terc4 = 10'b1010011100; 4'h1: terc4 = 10'b1001100011;
            4'h2: terc4 = 10'b1011100100; 4'h3: terc4 = 10'b1011100010;
            4'h4: terc4 = 10'b0101110001; 4'h5: terc4 = 10'b0100011110;
            4'h6: terc4 = 10'b0110001110; 4'h7: terc4 = 10'b0100111100;
            4'h8: terc4 = 10'b1011001100; 4'h9: terc4 = 10'b0100111001;
            4'hA: terc4 = 10'b0110011100; 4'hB: terc4 = 10'b1011000110;
            4'hC: terc4 = 10'b1010001110; 4'hD: terc4 = 10'b1001110001;
            4'hE: terc4 = 10'b0101100011; default: terc4 = 10'b1011000011;
        endcase
    endfunction
    function automatic [9:0] ctrl(input [1:0] cc);
        case (cc)
            2'b00: ctrl = 10'b1101010100; 2'b01: ctrl = 10'b0010101011;
            2'b10: ctrl = 10'b0101010100; default: ctrl = 10'b1010101011;
        endcase
    endfunction
    localparam [9:0] VGB = (CH == 1) ? 10'b0100110011 : 10'b1011001100;

    // stage A: transition minimisation
    wire [3:0] n1d = pop8(d);
    wire       use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && !d[0]);
    function automatic [8:0] tmin(input [7:0] v, input xn);   // transition-minimised word
        reg [8:0] r;
        integer j;
        begin
            r[0] = v[0];
            for (j = 1; j < 8; j = j + 1) r[j] = xn ? ~(r[j-1] ^ v[j]) : (r[j-1] ^ v[j]);
            r[8] = !xn;
            tmin = r;
        end
    endfunction
    wire [8:0] qm_c = tmin(d, use_xnor);

    reg [8:0] qm; reg [3:0] n1q; reg [2:0] ma; reg [9:0] other;
    always @(posedge clk) begin
        qm  <= qm_c;
        n1q <= pop8(qm_c[7:0]);
        ma  <= mode;
        case (mode)
            3'd2:    other <= VGB;
            3'd3:    other <= terc4(nib);
            3'd4:    other <= (CH == 0) ? terc4({2'b11, c}) : 10'b0100110011;   // ch0: {1,1,vsync,hsync}
            default: other <= ctrl(c);
        endcase
    end

    // stage B: DC balance (disparity reset outside video)
    reg signed [5:0] cnt = 6'sd0;
    wire signed [5:0] diff = $signed({1'b0, n1q, 1'b0}) - 6'sd8;     // n1 - n0 = 2*n1 - 8
    always @(posedge clk) begin
        if (ma != 3'd1) begin
            cnt <= 6'sd0;
            q   <= other;
        end else if (cnt == 0 || diff == 0) begin
            q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + (qm[8] ? 6'sd2 : 6'sd0) - diff;
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - (qm[8] ? 6'sd0 : 6'sd2) + diff;
        end
    end
endmodule
