// KAGURA-6502 VDP: 320x176 tile + sprite video, 16-colour palettes, border, 2-ch wave audio.
// Specification: docs/vdp-320x176.md. Two clock domains:
//   clk (system, 54 MHz) : CPU register window, VRAM (patterns / map / OAM), renderer,
//                          line-buffer write side, palette / wave write side
//   clk_pix (74.25 MHz)  : 1280x720 scan-out at 4x4 (logical 320x180), border, palette
//                          lookup, wave player (HDMI audio samples)
// The only crossings: the line-buffer and palette/wave SDPB blocks (written in clk,
// read in clk_pix), a toggle + index for "render line L" (clk_pix -> clk), and
// quasi-static audio registers (2-FF synchronised; tearing is harmless).
//
// Screen: logical lines 0..179 (720/4). Lines 0,1 and 178,179 are BORDER (each = 4
// HDMI lines, 16 HDMI lines total). Lines 2..177 are the active area, screen rows
// sy = 0..175 = 22 rows of 8x8 tiles; 320 px = 40 tiles. The border is produced in
// the output stage from a palette index: it uses no pattern, map or OAM entry.
//
// Build-time options (resource comparison, docs/vdp-320x176.md §5):
//   NPAT      pattern count (64..1024). Banked: ceil(NPAT/64) blocks of 512x32.
//   PAT_FLAT  1: one flat array of NPAT*8 words (Gowin chooses the blocks) instead of banks
//   SHARE_PW  1: palette (256x16) and wave memory (2x256 B) in ONE SDPB block, read port
//                time-shared in clk_pix (palette 1 of every 4 clocks); 0: two blocks
//   OAM_DBL   1: OAM shadow (CPU) + active (renderer) copied at frame start (v0.3 plan,
//                2 blocks); 0: one OAM block shared by CPU and renderer (port arbitration)
module k65_vdp #(
    parameter integer NPAT     = 1024,
    parameter integer PAT_FLAT = 0,
    parameter integer SHARE_PW = 1,
    parameter integer OAM_DBL  = 0,
    parameter         PAL_FILE = "vdp_palette.hex",  // 512 words: 256 RGB565 + 256 wave (= 0), SHARE_PW=1
    parameter         PAL256_FILE = "vdp_palette256.hex"  // the 256 palette words only, SHARE_PW=0
) (
    // ---------------- system domain (CPU side)
    input  wire        clk,
    input  wire        rst,
    input  wire        reg_wr,            // end-of-cycle write pulse
    input  wire        reg_rd,            // end-of-cycle read pulse (side effects)
    input  wire [5:0]  reg_addr,
    input  wire [7:0]  reg_wdata,
    output reg  [7:0]  reg_rdata,         // combinational from the registers
    output wire        irq,
    // ---------------- pixel domain
    input  wire        clk_pix,
    input  wire        rst_pix,
    input  wire [10:0] cx,
    input  wire [9:0]  cy,
    output reg  [23:0] rgb,
    output reg         sample_valid,
    input  wire        sample_ready,
    output reg  [31:0] sample_data,
    output reg         pwm_l,
    output reg         pwm_r,
    // ---------------- wave channels for an external mixer (k65_audio), pixel domain
    output wire        aud_tick,          // 48 kHz sample tick (one clk_pix pulse)
    output wire        aud_wrdy,          // wave samples of this tick valid (the legacy mix clock)
    output wire [7:0]  aud_s0,            // signed 8-bit wave samples
    output wire [7:0]  aud_s1,
    output wire [7:0]  aud_v0,            // volume registers as synchronised (b7..4 L, b3..0 R)
    output wire [7:0]  aud_v1,
    output reg  [1:0]  aud_wen,           // ACTRL b1..0 as used at aud_tick
    // ---------------- observability (testbench)
    output reg         mon_render_ovr,    // a render request arrived while still busy (sticky)
    output reg  [12:0] mon_render_max     // longest line render, sysclk
);
    localparam integer NB   = (NPAT + 63) / 64;           // pattern banks of 64 patterns
    localparam integer PATW = NPAT * 8;                   // flat: words
    generate
        if (NPAT < 64 || NPAT > 1024) begin : g_err_npat k65_vdp_param_error_npat e(); end
    endgenerate

    // =====================================================================
    // Registers ($D300 + reg_addr)
    // =====================================================================
    reg [16:0] vaddr;
    reg [7:0]  vinc, ctrl, border, scy;
    reg [8:0]  scx;
    reg [7:0]  pref;                      // VDATA prefetch
    reg        st_vblank, st_ovf, st_ovf_frame;
    reg [7:0]  cur_line;
    reg [23:0] a_inc0, a_inc1;
    reg [7:0]  a_vol0, a_vol1, a_ctrl;
    reg        busy;
    assign irq = ctrl[7] && st_vblank;

    always @(*) begin
        case (reg_addr)
            6'd0:  reg_rdata = vaddr[7:0];
            6'd1:  reg_rdata = vaddr[15:8];
            6'd2:  reg_rdata = {7'd0, vaddr[16]};
            6'd3:  reg_rdata = pref;
            6'd4:  reg_rdata = vinc;
            6'd5:  reg_rdata = ctrl;
            6'd6:  reg_rdata = {st_vblank, st_ovf, 5'd0, busy};
            6'd7:  reg_rdata = border;
            6'd8:  reg_rdata = scx[7:0];
            6'd9:  reg_rdata = {7'd0, scx[8]};
            6'd10: reg_rdata = scy;
            6'd11: reg_rdata = cur_line;
            6'd12: reg_rdata = NPAT[7:0];
            6'd13: reg_rdata = {5'd0, NPAT[10:8]};
            6'd16: reg_rdata = a_inc0[7:0];
            6'd17: reg_rdata = a_inc0[15:8];
            6'd18: reg_rdata = a_inc0[23:16];
            6'd19: reg_rdata = a_vol0;
            6'd20: reg_rdata = a_inc1[7:0];
            6'd21: reg_rdata = a_inc1[15:8];
            6'd22: reg_rdata = a_inc1[23:16];
            6'd23: reg_rdata = a_vol1;
            6'd24: reg_rdata = a_ctrl;
            default: reg_rdata = 8'h00;
        endcase
    end

    // CPU VRAM operations: one at a time (the next CPU access is >= 16 sysclk later)
    //   op_wr: write cpu_wd at cpu_a; then prefetch at the incremented address
    reg        op_pend, op_wr;
    reg [16:0] cpu_a;
    reg [7:0]  cpu_wd;
    wire       op_done;
    reg        frame_start;              // pulse from the renderer (line 0 request)

    always @(posedge clk) begin
        if (rst) begin
            vaddr <= 17'd0; vinc <= 8'd1; ctrl <= 8'h03; border <= 8'h00; scx <= 9'd0; scy <= 8'd0;
            st_vblank <= 1'b0; st_ovf <= 1'b0; op_pend <= 1'b0; op_wr <= 1'b0;
            a_inc0 <= 24'd0; a_inc1 <= 24'd0; a_vol0 <= 8'h00; a_vol1 <= 8'h00; a_ctrl <= 8'h00;
            cpu_a <= 17'd0; cpu_wd <= 8'h00;
        end else begin
            if (op_done) op_pend <= 1'b0;
            if (frame_start) begin st_vblank <= 1'b1; if (st_ovf_frame) st_ovf <= 1'b1; end
            if (reg_wr) begin
                case (reg_addr)
                    6'd0:  vaddr[7:0]  <= reg_wdata;
                    6'd1:  vaddr[15:8] <= reg_wdata;
                    6'd2:  begin vaddr[16] <= reg_wdata[0];                       // -> prefetch
                                 cpu_a <= {reg_wdata[0], vaddr[15:0]}; op_wr <= 1'b0; op_pend <= 1'b1; end
                    6'd3:  begin cpu_a <= vaddr; cpu_wd <= reg_wdata; op_wr <= 1'b1; op_pend <= 1'b1;
                                 vaddr <= vaddr + {9'd0, vinc}; end
                    6'd4:  vinc   <= reg_wdata;
                    6'd5:  ctrl   <= reg_wdata;
                    6'd7:  border <= reg_wdata;
                    6'd8:  scx[7:0] <= reg_wdata;
                    6'd9:  scx[8]   <= reg_wdata[0];
                    6'd10: scy    <= reg_wdata;
                    6'd16: a_inc0[7:0]   <= reg_wdata;
                    6'd17: a_inc0[15:8]  <= reg_wdata;
                    6'd18: a_inc0[23:16] <= reg_wdata;
                    6'd19: a_vol0 <= reg_wdata;
                    6'd20: a_inc1[7:0]   <= reg_wdata;
                    6'd21: a_inc1[15:8]  <= reg_wdata;
                    6'd22: a_inc1[23:16] <= reg_wdata;
                    6'd23: a_vol1 <= reg_wdata;
                    6'd24: a_ctrl <= reg_wdata;
                    default: ;
                endcase
            end
            if (reg_rd && reg_addr == 6'd3) begin                    // VDATA read: advance + prefetch
                vaddr <= vaddr + {9'd0, vinc};
                cpu_a <= vaddr + {9'd0, vinc}; op_wr <= 1'b0; op_pend <= 1'b1;
            end
            if (reg_rd && reg_addr == 6'd6) begin st_vblank <= 1'b0; st_ovf <= 1'b0; end
        end
    end

    // =====================================================================
    // CPU VRAM sequencer: owns the VRAM ports while active (renderer waits)
    //   IDLE; RD read (RMW); MG merge into a register (keeps BSRAM->mux->BSRAM out of one
    //   clock); WR write; PF prefetch read; PFC capture. At most 7 sysclk per operation.
    //   VRAM map: $00000-$07FFF patterns, $08000-$08FFF map, $09000-$097FF OAM,
    //             $09800-$09BFF palette (words 0..255) + wave (words 256..511), write-only
    // =====================================================================
    localparam [2:0] Q_IDLE = 3'd0, Q_RD = 3'd1, Q_WR = 3'd2, Q_PF = 3'd3, Q_PFC = 3'd4, Q_MG = 3'd5;
    reg [31:0] q_mw;                    // merged word for the RMW write
    reg [2:0]  q;
    reg [16:0] q_a;
    wire       q_pat = (q_a[16:15] == 2'b00);
    wire       q_map = (q_a[16:12] == 5'b01000);
    wire       q_oam = (q_a[16:11] == 6'b010010);
    wire       q_pw  = (q_a[16:10] == 7'b0100110);
    wire       q_word = q_pat || q_oam;                         // 32-bit memories: RMW
    assign op_done = (q == Q_PFC);
    wire       cpu_busy = (q != Q_IDLE);

    // memory-port request from the CPU sequencer
    reg        c_en, c_we;
    reg [16:0] c_a;
    reg [31:0] c_wd32;
    reg [7:0]  c_wd8;
    wire [31:0] pat_q, oam_q;
    wire [7:0]  map_lo_q, map_hi_q;
    reg  [7:0]  pw_lo_latch;

    function automatic [31:0] merge32(input [31:0] w, input [1:0] lane, input [7:0] b);
        merge32 = w;
        case (lane)
            2'd0: merge32[31:24] = b;
            2'd1: merge32[23:16] = b;
            2'd2: merge32[15:8]  = b;
            default: merge32[7:0] = b;
        endcase
    endfunction
    function automatic [7:0] lane32(input [31:0] w, input [1:0] lane);
        case (lane)
            2'd0: lane32 = w[31:24];
            2'd1: lane32 = w[23:16];
            2'd2: lane32 = w[15:8];
            default: lane32 = w[7:0];
        endcase
    endfunction

    reg pw_we; reg [8:0] pw_wa; reg [15:0] pw_wd;
    always @(posedge clk) begin
        pw_we <= 1'b0;
        if (rst) begin
            q <= Q_IDLE; pref <= 8'h00; pw_lo_latch <= 8'h00;
        end else begin
            case (q)
                Q_IDLE: if (op_pend && !op_done) begin q_a <= cpu_a; q <= op_wr ? Q_RD : Q_PF; end
                Q_RD:   q <= Q_MG;               // read issued (word memories), data next
                Q_MG: begin
                          q_mw <= q_pat ? merge32(pat_q, q_a[1:0], cpu_wd) : merge32(oam_q, q_a[1:0], cpu_wd);
                          q <= Q_WR;
                      end
                Q_WR: begin                      // merge/write issued this cycle
                          if (q_pw) begin
                              if (!q_a[0]) pw_lo_latch <= cpu_wd;
                              else begin pw_we <= 1'b1; pw_wa <= q_a[9:1]; pw_wd <= {cpu_wd, pw_lo_latch}; end
                          end
                          q_a <= vaddr; q <= Q_PF;  // vaddr already incremented
                      end
                Q_PF:   q <= Q_PFC;
                Q_PFC: begin
                          pref <= q_pat ? lane32(pat_q, q_a[1:0]) :
                                  q_oam ? lane32(oam_q, q_a[1:0]) :
                                  q_map ? (q_a[0] ? map_hi_q : map_lo_q) : 8'h00;
                          q <= Q_IDLE;
                      end
                default: q <= Q_IDLE;
            endcase
        end
    end
    // port signals of the sequencer (combinational on q)
    always @(*) begin
        c_en = 1'b0; c_we = 1'b0; c_a = q_a;
        c_wd8 = cpu_wd; c_wd32 = 32'd0;
        case (q)
            Q_RD:  begin c_en = 1'b1; end
            Q_WR:  begin c_en = 1'b1; c_we = 1'b1;
                         c_wd32 = q_mw; end
            Q_PF:  begin c_en = 1'b1; end
            default: ;
        endcase
    end

    // =====================================================================
    // VRAM: patterns, map (2 byte lanes), OAM. Single-port blocks, port mux:
    //   cpu_busy -> sequencer, else renderer. Read data appears one clock later and
    //   is consumed by the requester in that clock (renderer never reads while the
    //   sequencer is active; the sequencer never uses data issued by the renderer).
    // =====================================================================
    reg        r_pat_en;  reg [9:0]  r_pat_p;  reg [2:0] r_pat_row;
    reg        r_map_en;  reg [10:0] r_map_a;
    reg        r_oam_en;  reg [8:0]  r_oam_a;

    // --- patterns
    wire        pc_sel  = cpu_busy && q_pat;
    wire [9:0]  pa_pat  = pc_sel ? c_a[14:5] : r_pat_p;
    wire [2:0]  pa_row  = pc_sel ? c_a[4:2]  : r_pat_row;
    wire        pa_we   = pc_sel && c_we && (c_a[14:5] < NPAT);
    wire [31:0] pa_wd   = c_wd32;
    reg  [3:0]  pat_bank_q;                  // bank of the last read (output mux)
    reg         pat_oor_q;                   // last read was >= NPAT
    always @(posedge clk) begin pat_bank_q <= pa_pat[9:6]; pat_oor_q <= (pa_pat >= NPAT); end
    generate
        if (PAT_FLAT) begin : g_pat_flat
            reg [31:0] pmem [0:PATW-1];
            reg [31:0] pq;
            wire [12:0] wa = {pa_pat, pa_row};
            always @(posedge clk) begin
                if (pa_we) pmem[wa] <= pa_wd;
                else if (wa < PATW) pq <= pmem[wa];
            end
            assign pat_q = pat_oor_q ? 32'd0 : pq;
        end else begin : g_pat_bank
            wire [31:0] bq [0:NB-1];
            genvar b;
            for (b = 0; b < NB; b = b + 1) begin : g_b
                reg [31:0] pmem [0:511];
                reg [31:0] pq;
                always @(posedge clk) begin
                    if (pa_we && pa_pat[9:6] == b) pmem[{pa_pat[5:0], pa_row}] <= pa_wd;
                    else                           pq <= pmem[{pa_pat[5:0], pa_row}];
                end
                assign bq[b] = pq;
            end
            assign pat_q = pat_oor_q ? 32'd0 : bq[pat_bank_q];
        end
    endgenerate

    // --- map: 64 x 32 entries, low byte = pattern[7:0], high = {pal[3:0], vflip, hflip, pattern[9:8]}
    wire        mc_sel = cpu_busy && q_map;
    wire [10:0] ma     = mc_sel ? c_a[11:1] : r_map_a;
    reg  [7:0]  map_lo [0:2047];
    reg  [7:0]  map_hi [0:2047];
    reg  [7:0]  mlo_q, mhi_q;
    always @(posedge clk) begin
        if (mc_sel && c_we && !c_a[0]) map_lo[ma] <= c_wd8; else mlo_q <= map_lo[ma];
    end
    always @(posedge clk) begin
        if (mc_sel && c_we &&  c_a[0]) map_hi[ma] <= c_wd8; else mhi_q <= map_hi[ma];
    end
    assign map_lo_q = mlo_q;
    assign map_hi_q = mhi_q;

    // --- OAM: 256 x 8 bytes = 512 words of 32 bits (word 2i = bytes 0-3, 2i+1 = bytes 4-7)
    //   byte0 Y[7:0], byte1 {enable, size16, 5'b0, Y[8]}, byte2 X[7:0], byte3 {7'b0, X[8]},
    //   byte4 pattern[7:0], byte5 {2'b0, vflip, hflip, 2'b0, pattern[9:8]}, byte6 {4'b0, pal}, byte7 -
    wire        oc_sel = cpu_busy && q_oam;
    wire [8:0]  oa_r   = r_oam_a;
    wire [31:0] oam_r_q;                    // renderer view
    generate
        if (OAM_DBL) begin : g_oam_dbl
            // shadow (CPU) + active (renderer); copied word by word at frame start
            reg [31:0] shadow [0:511];
            reg [31:0] active [0:511];
            reg [31:0] sq, aq;
            reg        cp_on; reg [9:0] cp_i; reg cp_wr; reg [8:0] cp_wa;
            always @(posedge clk) begin
                if (oc_sel && c_we) shadow[c_a[10:2]] <= c_wd32;
                else                sq <= shadow[oc_sel ? c_a[10:2] : cp_i[8:0]];
            end
            always @(posedge clk) begin
                if (rst) begin cp_on <= 1'b0; cp_i <= 10'd0; cp_wr <= 1'b0; end
                else begin
                    cp_wr <= cp_on && !oc_sel; cp_wa <= cp_i[8:0];
                    if (frame_start) begin cp_on <= 1'b1; cp_i <= 10'd0; end
                    else if (cp_on && !oc_sel) begin
                        if (cp_i == 10'd511) cp_on <= 1'b0;
                        cp_i <= cp_i + 10'd1;
                    end
                end
            end
            always @(posedge clk) begin
                if (cp_wr) active[cp_wa] <= sq;
                else       aq <= active[oa_r];
            end
            assign oam_q = sq;
            assign oam_r_q = aq;
        end else begin : g_oam_one
            reg [31:0] omem [0:511];
            reg [31:0] oq;
            wire [8:0] oa = oc_sel ? c_a[10:2] : oa_r;
            always @(posedge clk) begin
                if (oc_sel && c_we) omem[oa] <= c_wd32;
                else                oq <= omem[oa];
            end
            assign oam_q = oq;
            assign oam_r_q = oq;
        end
    endgenerate

    // =====================================================================
    // Line buffer (SDPB): 2 halves x 512 x 8 bit. Pixel = {pal[3:0], colour[3:0]},
    // colour 0 = backdrop (palette entry 0). x = 320 holds the line's border index.
    // =====================================================================
    reg        lb_we;
    reg [9:0]  lb_wa;
    reg [7:0]  lb_wd;
    reg [7:0]  lbuf [0:1023];
    always @(posedge clk) if (lb_we) lbuf[lb_wa] <= lb_wd;

    // =====================================================================
    // Render requests (clk_pix -> clk): toggle + line index (stable for 4 HDMI lines)
    // =====================================================================
    reg        req_tgl_p;
    reg [7:0]  req_line_p;
    reg [2:0]  req_sync;
    always @(posedge clk) req_sync <= {req_sync[1:0], req_tgl_p};
    wire       req = req_sync[2] ^ req_sync[1];

    // =====================================================================
    // Renderer (clk)
    // =====================================================================
    localparam [4:0] R_IDLE = 5'd0, R_META = 5'd1, R_BGM = 5'd2, R_BGMW = 5'd3, R_BGP = 5'd4,
                     R_BGPW = 5'd5, R_BGD = 5'd6, R_SCN = 5'd7, R_SCNW = 5'd8, R_SPA = 5'd9,
                     R_SPAW = 5'd10, R_SPB = 5'd11, R_SPBW = 5'd12, R_SPP = 5'd13, R_SPPW = 5'd14,
                     R_SPD = 5'd15, R_DONE = 5'd16;
    reg [4:0]  rs;
    reg [7:0]  r_line, r_sy, r_wy;
    reg [5:0]  r_t;                       // tile 0..40
    reg [2:0]  r_px;
    reg [15:0] r_ment;
    reg [31:0] r_word;
    reg [8:0]  r_i;                       // OAM scan index 0..256
    reg [6:0]  r_cnt;                     // hits on this line (max 64)
    reg [7:0]  hit [0:63];                // hit list (distributed RAM)
    wire [7:0] hit_cur = hit[r_cnt[5:0] - 6'd1];   // sprite being drawn (list is drawn last to first)
    reg [8:0]  s_x;  reg [4:0] s_row; reg s_big, s_hf, s_vf; reg [9:0] s_pat; reg [3:0] s_pal;
    reg        s_half;                    // 0 / 1 for 16-wide sprites
    reg [7:0]  border_frame;
    reg [12:0] r_clk;
    wire       r_bg  = ctrl[0], r_spr = ctrl[1];
    wire [9:0] bg_x  = {1'b0, r_t, 3'd0} + {7'd0, r_px} - {7'd0, scx[2:0]};   // screen x (may be <0 or >=320)
    wire [5:0] bg_col = scx[8:3] + r_t;
    wire [3:0] bg_nib = r_word[31 - 4 * (r_ment[10] ? (7 - r_px) : r_px) -: 4];
    // sprite: Y,X bias 16 (so -16..495); row inside sprite
    wire [9:0] sp_row_w = {2'b00, r_sy} + 10'd16 - {1'b0, oam_r_q[16], oam_r_q[31:24]};
    wire [9:0] sp_x  = {1'b0, s_x} - 10'd16 + {6'd0, s_half, 3'd0} + {7'd0, r_px};
    wire [3:0] sp_nib = r_word[31 - 4 * (s_hf ? (7 - r_px) : r_px) -: 4];
    wire       ren_ok = !cpu_busy;        // renderer may use the VRAM ports this clock

    always @(*) begin
        r_pat_en = 1'b0; r_map_en = 1'b0; r_oam_en = 1'b0;
        r_map_a = {r_wy[7:3], bg_col};
        r_oam_a = 9'd0; r_pat_p = 10'd0; r_pat_row = 3'd0;
        case (rs)
            R_BGP:  begin r_pat_p = r_ment[9:0]; r_pat_row = r_wy[2:0] ^ {3{r_ment[11]}}; end
            R_SCN:  r_oam_a = {r_i[7:0], 1'b0};
            R_SPA:  r_oam_a = {hit_cur, 1'b0};
            R_SPB:  r_oam_a = {hit_cur, 1'b1};
            R_SPP:  begin
                        r_pat_p   = s_pat + (s_big ? ({8'd0, s_row[3], 1'b0} + {9'd0, s_half ^ s_hf}) : 10'd0);
                        r_pat_row = s_row[2:0];
                    end
            default: ;
        endcase
    end

    always @(posedge clk) begin
        lb_we <= 1'b0;
        frame_start <= 1'b0;
        if (rst) begin
            rs <= R_IDLE; busy <= 1'b0; mon_render_ovr <= 1'b0; mon_render_max <= 13'd0;
            border_frame <= 8'h00; st_ovf_frame <= 1'b0; cur_line <= 8'd0;
        end else begin
            if (busy && r_clk != 13'h1FFF) r_clk <= r_clk + 13'd1;
            if (req && busy) mon_render_ovr <= 1'b1;
            case (rs)
                R_IDLE: if (req) begin
                            r_line <= req_line_p; cur_line <= req_line_p; busy <= 1'b1; r_clk <= 13'd0;
                            rs <= R_META;
                            if (req_line_p == 8'd0) begin
                                border_frame <= border; frame_start <= 1'b1; st_ovf_frame <= 1'b0;
                            end
                        end
                R_META: begin                        // border index of this line -> x=320
                            lb_we <= 1'b1; lb_wa <= {r_line[0], 9'd320};
                            lb_wd <= {4'd0, (border[7] ? border[3:0] : border_frame[3:0])};
                            r_sy <= r_line - 8'd2;
                            r_wy <= r_line - 8'd2 + scy;
                            r_t <= 6'd0; r_px <= 3'd0;
                            rs <= (r_line < 8'd2 || r_line >= 8'd178) ? R_DONE : R_BGM;
                        end
                // ---------------- background: 41 tiles
                R_BGM:  if (ren_ok) rs <= R_BGMW;                       // map read issued
                R_BGMW: begin r_ment <= {map_hi_q, map_lo_q}; rs <= R_BGP; end
                R_BGP:  if (ren_ok) rs <= R_BGPW;                       // pattern read issued
                R_BGPW: begin r_word <= pat_q; r_px <= 3'd0; rs <= R_BGD; end
                R_BGD:  begin
                            if (!bg_x[9] && bg_x < 10'd320) begin
                                lb_we <= 1'b1; lb_wa <= {r_line[0], bg_x[8:0]};
                                lb_wd <= (r_bg && bg_nib != 4'd0) ? {r_ment[15:12], bg_nib} : 8'h00;
                            end
                            r_px <= r_px + 3'd1;
                            if (r_px == 3'd7) begin
                                if (r_t == 6'd40) begin r_i <= 9'd0; r_cnt <= 7'd0; rs <= r_spr ? R_SCN : R_DONE; end
                                else begin r_t <= r_t + 6'd1; rs <= R_BGM; end
                            end
                        end
                // ---------------- sprites: scan 0..255, keep up to 64 hits, draw in reverse
                R_SCN:  if (r_i == 9'd256) rs <= (r_cnt == 7'd0) ? R_DONE : R_SPA;
                        else if (ren_ok) rs <= R_SCNW;
                R_SCNW: begin
                            if (oam_r_q[23] && sp_row_w < (oam_r_q[22] ? 10'd16 : 10'd8)) begin
                                if (r_cnt != 7'd64) begin hit[r_cnt[5:0]] <= r_i[7:0]; r_cnt <= r_cnt + 7'd1; end
                                else st_ovf_frame <= 1'b1;
                            end
                            r_i <= r_i + 9'd1;
                            rs <= R_SCN;
                        end
                R_SPA:  if (ren_ok) rs <= R_SPAW;
                R_SPAW: begin
                            s_row <= sp_row_w[4:0]; s_big <= oam_r_q[22];
                            s_x <= {oam_r_q[0], oam_r_q[15:8]};
                            rs <= R_SPB;
                        end
                R_SPB:  if (ren_ok) rs <= R_SPBW;
                R_SPBW: begin
                            s_pat <= {oam_r_q[17:16], oam_r_q[31:24]};
                            s_hf  <= oam_r_q[20]; s_vf <= oam_r_q[21];
                            s_pal <= oam_r_q[11:8];
                            if (oam_r_q[21]) s_row <= (s_big ? 5'd15 : 5'd7) - s_row;
                            s_half <= 1'b0;
                            rs <= R_SPP;
                        end
                R_SPP:  if (ren_ok) rs <= R_SPPW;
                R_SPPW: begin r_word <= pat_q; r_px <= 3'd0; rs <= R_SPD; end
                R_SPD:  begin
                            if (sp_nib != 4'd0 && !sp_x[9] && sp_x < 10'd320) begin
                                lb_we <= 1'b1; lb_wa <= {r_line[0], sp_x[8:0]}; lb_wd <= {s_pal, sp_nib};
                            end
                            r_px <= r_px + 3'd1;
                            if (r_px == 3'd7) begin
                                if (s_big && !s_half) begin s_half <= 1'b1; rs <= R_SPP; end
                                else begin
                                    r_cnt <= r_cnt - 7'd1;
                                    rs <= (r_cnt == 7'd1) ? R_DONE : R_SPA;
                                end
                            end
                        end
                R_DONE: begin
                            busy <= 1'b0; rs <= R_IDLE;
                            if (r_clk > mon_render_max) mon_render_max <= r_clk;
                        end
                default: rs <= R_IDLE;
            endcase
        end
    end

    // =====================================================================
    // Pixel domain: render requests, scan-out with border, palette, wave player
    // =====================================================================
    // Pipeline (edges named by the cx value they sample; target pixel tx):
    //   cx=tx-5: txr/tyr <= cx+5 (one register load of cx/cy: keeps cx fan-out low)
    //   cx=tx-4: line-buffer read      cx=tx-3: palette read      cx=tx-2: rgb_next
    //   cx=tx-1: rgb_r                 cx=tx  : rgb (output register, contract "rgb <= f(cx)")
    // Own position counters (vx, vy) = (cx, cy) of the same clock. cx/cy are compared only
    // once per clock at the frame origin (resync), which keeps the load on k65_hdmi_tx's
    // cx/cy registers minimal (its data-island paths start at cx).
    reg [10:0] vx; reg [9:0] vy;
    wire       at0 = (cx == 11'd0) && (cy == 10'd0);
    always @(posedge clk_pix) begin
        if (rst_pix)      begin vx <= 11'd0; vy <= 10'd0; end
        else if (at0)     begin vx <= 11'd1; vy <= 10'd0; end          // next clock: cx = 1
        else if (vx == 11'd1649) begin vx <= 11'd0; vy <= (vy == 10'd749) ? 10'd0 : vy + 10'd1; end
        else              vx <= vx + 11'd1;
    end
    reg [10:0] tx; reg [9:0] ty;
    reg        cx0_r; reg [9:0] cy_r;
    always @(posedge clk_pix) begin
        if (vx + 11'd5 >= 11'd1650) begin tx <= vx + 11'd5 - 11'd1650; ty <= (vy == 10'd749) ? 10'd0 : vy + 10'd1; end
        else begin tx <= vx + 11'd5; ty <= vy; end
        cx0_r <= (vx == 11'd0); cy_r <= vy;
    end
    always @(posedge clk_pix) begin
        if (rst_pix) begin req_tgl_p <= 1'b0; req_line_p <= 8'd0; end
        else if (cx0_r) begin
            if (cy_r == 10'd720) begin req_line_p <= 8'd0; req_tgl_p <= ~req_tgl_p; end
            else if (cy_r <= 10'd712 && cy_r[1:0] == 2'b00) begin  // display line L -> render L+1 (1..179)
                req_line_p <= cy_r[9:2] + 8'd1;
                req_tgl_p  <= ~req_tgl_p;
            end
        end
    end

    // line-buffer read (pixel side)
    reg  [7:0] lb_q;
    reg  [9:0] lb_ra;
    wire [7:0] t_ly = ty[9:2];
    wire       t_vis = (tx < 11'd1280) && (ty < 10'd720);
    wire       t_brd = (t_ly < 8'd2) || (t_ly >= 8'd178);
    always @(*) lb_ra = {t_ly[0], (t_brd ? 9'd320 : tx[10:2])};
    always @(posedge clk_pix) lb_q <= lbuf[lb_ra];
    // pipeline flags
    reg        p1_go, p1_vis, p1_brd, p2_vis, p2_go, p3_vis;
    always @(posedge clk_pix) begin
        p1_go  <= t_vis && (tx[1:0] == 2'b00);          // lb_q valid next clock
        p1_vis <= t_vis; p1_brd <= t_brd;
        p2_go  <= p1_go; p2_vis <= p1_vis; p3_vis <= p2_vis;
    end
    // palette address from the line-buffer byte (border: palette 0 index)
    wire [7:0] pal_idx = p1_brd ? {4'd0, lb_q[3:0]} : (lb_q[3:0] == 4'd0 ? 8'd0 : lb_q);

    // palette / wave memory
    reg  [15:0] pw_q, pal_q;
    reg         wv_req, wv_issued;
    reg  [8:0]  wv_a;
    wire        pal_slot = p1_go;                       // palette read this clock
    generate
        if (SHARE_PW) begin : g_pw_share
            reg [15:0] pwm [0:511];
            initial $readmemh(PAL_FILE, pwm);
            always @(posedge clk) if (pw_we) pwm[pw_wa] <= pw_wd;
            always @(posedge clk_pix) pw_q <= pwm[pal_slot ? {1'b0, pal_idx} : wv_a];
            always @(*) pal_q = pw_q;
        end else begin : g_pw_split
            reg [15:0] palm [0:255];
            reg [15:0] wavm [0:255];
            reg [15:0] pq, wq;
            initial $readmemh(PAL256_FILE, palm);
            always @(posedge clk) if (pw_we && !pw_wa[8]) palm[pw_wa[7:0]] <= pw_wd;
            always @(posedge clk) if (pw_we &&  pw_wa[8]) wavm[pw_wa[7:0]] <= pw_wd;
            always @(posedge clk_pix) pq <= palm[pal_idx];
            always @(posedge clk_pix) wq <= wavm[wv_a[7:0]];
            always @(*) begin pal_q = pq; pw_q = wq; end
        end
    endgenerate

    // rgb: RGB565 -> 24 bit (rgb_next per 4-clock group), then two registers
    reg [23:0] rgb_next, rgb_r;
    always @(posedge clk_pix) begin
        if (p2_go) rgb_next <= {pal_q[15:11], pal_q[15:13], pal_q[10:5], pal_q[10:9], pal_q[4:0], pal_q[4:2]};
        rgb_r <= p3_vis ? rgb_next : 24'h000000;
        rgb   <= rgb_r;
    end

    // ---------------- wave player: 2 channels, 256 signed 8-bit samples each
    reg [23:0] i0_m, i0_p, i1_m, i1_p; reg [7:0] v0_m, v0_p, v1_m, v1_p, ac_m, ac_p;
    always @(posedge clk_pix) begin
        i0_m <= a_inc0; i0_p <= i0_m; i1_m <= a_inc1; i1_p <= i1_m;
        v0_m <= a_vol0; v0_p <= v0_m; v1_m <= a_vol1; v1_p <= v1_m; ac_m <= a_ctrl; ac_p <= ac_m;
    end
    reg [13:0] acc; reg tick;
    always @(posedge clk_pix) begin
        if (rst_pix) begin acc <= 14'd0; tick <= 1'b0; end
        else if (acc >= 14'd12367) begin acc <= acc + 14'd8 - 14'd12375; tick <= 1'b1; end
        else begin acc <= acc + 14'd8; tick <= 1'b0; end
    end
    reg [23:0] ph0, ph1;
    reg [1:0]  wst;                       // 0 idle, 1 ch0, 2 ch1
    reg signed [7:0] s0, s1;
    reg        got;                       // read issued last clock (shared: not a palette slot)
    always @(*) wv_a = (wst == 2'd1) ? {1'b1, 1'b0, ph0[23:17]} : {1'b1, 1'b1, ph1[23:17]};
    wire       wv_can = SHARE_PW ? !pal_slot : 1'b1;
    reg        wsel;                      // byte select of the issued read
    assign aud_tick = tick;
    assign aud_wrdy = (wst == 2'd3) && !tick;
    assign aud_s0 = s0; assign aud_s1 = s1; assign aud_v0 = v0_p; assign aud_v1 = v1_p;
    always @(posedge clk_pix) if (rst_pix) aud_wen <= 2'b00; else if (tick) aud_wen <= ac_p[1:0];
    always @(posedge clk_pix) begin
        if (rst_pix) begin
            wst <= 2'd0; ph0 <= 24'd0; ph1 <= 24'd0; got <= 1'b0; s0 <= 8'sd0; s1 <= 8'sd0;
            sample_valid <= 1'b0; sample_data <= 32'd0;
        end else begin
            if (sample_valid && sample_ready) sample_valid <= 1'b0;
            got <= 1'b0;
            if (got) begin
                if (wst == 2'd1) begin s0 <= wsel ? pw_q[15:8] : pw_q[7:0]; wst <= 2'd2; end
                else             begin s1 <= wsel ? pw_q[15:8] : pw_q[7:0]; wst <= 2'd3; end
            end else if ((wst == 2'd1 || wst == 2'd2) && wv_can) begin
                got <= 1'b1; wsel <= (wst == 2'd1) ? ph0[16] : ph1[16];
            end
            if (tick) begin
                ph0 <= ac_p[0] ? ph0 + i0_p : 24'd0;
                ph1 <= ac_p[1] ? ph1 + i1_p : 24'd0;
                wst <= 2'd1;
            end else if (wst == 2'd3) begin
                // mix: sample (s8) x volume (u4), L = high nibble, R = low nibble
                // |127 x 15 x 2| << 3 = 30480 < 32768: no overflow
                sample_data[15:0]  <= ($signed({{8{s0[7]}}, s0}) * $signed({12'd0, v0_p[7:4]}) +
                                       $signed({{8{s1[7]}}, s1}) * $signed({12'd0, v1_p[7:4]})) <<< 3;
                sample_data[31:16] <= ($signed({{8{s0[7]}}, s0}) * $signed({12'd0, v0_p[3:0]}) +
                                       $signed({{8{s1[7]}}, s1}) * $signed({12'd0, v1_p[3:0]})) <<< 3;
                sample_valid <= 1'b1;
                wst <= 2'd0;
            end
        end
    end
    // PWM (debug / fallback) from the left/right sample, 1st-order delta-sigma
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
