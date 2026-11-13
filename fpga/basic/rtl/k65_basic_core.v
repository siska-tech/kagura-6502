// KAGURA-6502 BASIC platform core (54 MHz system clock).
// Derived from k65_exp_core (exp74, d4e8dcc) = Phase 2 core (61a36fa) + FAST_RAM_BYTES.
// The bus engine (PHI2 generator, stretch, sampling points, PSRAM port) is unchanged;
// additions for running BASIC, all inside the existing $D000-$D00F I/O block:
//   * console UART (8N1, CON_DIV): $D00A data (W: send, R: pop RX FIFO), $D00B status
//   * RX FIFO (2**RXF_LOG2 bytes, default 64) so that a pasted program is not lost while
//     the CPU is busy (status bit 2 = overrun, cleared by reading $D00B)
//   * PSRAM write protect: $D00C = first protected page P (0 = off). CPU writes to
//     PSRAM physical byte addresses [P*256, $C000) are dropped (the bus cycle
//     completes normally, nothing is written). Used to make the BASIC interpreter
//     image in PSRAM behave like ROM (also stops MS BASIC's RAM-size probe there).
//     Physical address compare, so the bank window cannot bypass it.
//   * ROM_BYTES (4096 / 2048): Boot ROM at $10000-ROM_BYTES; with 2048 the range
//     $F000-$F7FF becomes PSRAM (linear), for the BSRAM trade-off study.
//
// Inherited description (Phase 2 / exp74):
// KAGURA-6502 Phase 2 core: W65C02S bus engine on the 54 MHz system clock,
// BSRAM fast RAM + Boot ROM, CPU main RAM in PSRAM (kagura_hyperram_ctrl), I/O,
// bus monitor and UART status frames. (Phase 1 core kept unchanged as baseline.)
//
// Everything runs in ONE clock domain (system clock, 54 MHz on hardware), the
// same clock as the PSRAM controller. PHI2 is a plain register output.
//
// Bus cycle timeline, sysclk edges after the edge that drives PHI2 low:
//   edge 0            PHI2 -> 0, write committed (BSRAM / I/O / PSRAM write buffer)
//   edge D_HOLD       read data released                         [tDHR >= 10 ns]
//   edge T_ASAMP      address / RWB sampled                       [tADS <= 40 ns]
//   edge T_ASAMP+1    decode registered, PSRAM byte address formed
//   edge T_ASAMP+2    PSRAM read issued (reads only)
//   edge HALF         PHI2 -> 1                                   (HALF = CYC/2, CYC may be odd)
//   edge T_DRV        read data driven                            T_DRV = max(HALF, T_ASAMP+3)
//   edge CYC-1        write data captured                         [tMDS <= 40 ns after PHI2 rise]
//   (hold)            PHI2 kept high while a PSRAM read is not back (+S_SETUP edges),
//                     or while a PSRAM write finds the write buffer still full
//
// Memory map (architecture v0.3):
//   $0000-$07FF  fast RAM 2 KiB (BSRAM)           0 wait
//   $0800-$BFFF  PSRAM, linear (byte address = CPU address)
//   $C000-$CFFF  PSRAM bank window: byte address = {BANK[9:0], A[11:0]}  (BANK at $D005/$D006)
//   $D000-$D00F  I/O                                0 wait
//   $D010-$DFFF  unmapped (reads $FF, bus_err), except the EXT_EN window:
//                $D300-$D3FF (EXT_EN=1) or $D300-$D4FF (EXT_EN=2) -> ext_* port, 0 wait
//   $E000-$EFFF  PSRAM, linear
//   $F000-$FFFF  Boot ROM 4 KiB (BSRAM, write-protect)  0 wait
// (BASIC platform: fast RAM = FAST_RAM_BYTES, Boot ROM = ROM_BYTES, see the top of the file)
module k65_basic_core #(
    parameter integer FAST_RAM_BYTES = 8192,   // fast RAM size ($0000..size-1), 2048..32768
    parameter integer ROM_BYTES  = 4096,     // Boot ROM size at the top of memory: 4096 or 2048
    parameter integer CON_DIV    = 469,      // console UART: 54 MHz / 115200 Bd
    parameter integer RXF_LOG2   = 6,        // console RX FIFO depth = 64 bytes
    parameter integer EXT_EN     = 0,        // 1: $D300-$D3FF -> ext_* port (VDP); 2: $D300-$D4FF (VDP + audio); 0: unmapped as before
    parameter integer CYC        = 54,       // sysclk per PHI2 period (54: 1.000 MHz @ 54 MHz)
    parameter integer T_ASAMP    = 4,        // 4 x 18.5 ns = 74 ns > tADS + pad/PCB
    parameter integer D_HOLD     = 2,        // 37 ns read-data hold after PHI2 fall
    parameter integer S_SETUP    = 2,        // PSRAM data on the bus >= 2 edges before PHI2 fall
    parameter integer READY_PHI2 = 256,
    parameter integer UART_DIV   = 469,      // 115200 Bd @ 54 MHz
    parameter integer HB_LOG2    = 20,
    parameter integer TIMER_LOG2 = 18,
    parameter         ROM_FILE   = "boot_rom.hex"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] a_in,
    input  wire        rwb_in,
    input  wire [7:0]  d_in,
    output reg         phi2,
    output reg  [7:0]  d_out,
    output reg         d_oe,
    output wire        irq_low,
    output wire        uart_tx,
    output wire        con_tx,               // console UART (CPU-driven)
    input  wire        con_rx,
    // external I/O window $D300-$D3FF (EXT_EN=1): 0 wait, same timing as $D000-$D00F
    output wire        ext_wr,               // end-of-cycle write pulse
    output wire        ext_rd,               // end-of-cycle read pulse (for read side effects)
    output wire [7:0]  ext_addr,
    output wire [3:0]  ext_page,             // address bits 11..8 of the access (3 = $D3xx, 4 = $D4xx)
    output wire [7:0]  ext_wdata,
    input  wire [7:0]  ext_rdata,            // sampled every clock (registered here)
    input  wire        ext_irq,
    input  wire        sync_in,
    output wire [5:0]  led,
    output wire [3:0]  dbg,
    // PSRAM controller (kagura_hyperram_ctrl user side)
    output wire        ps_cmd,
    output wire        ps_cmd_en,
    input  wire        ps_cmd_rdy,
    output wire [19:0] ps_addr,
    output wire [31:0] ps_wdata,
    output wire [3:0]  ps_mask,
    input  wire [31:0] ps_rdata,
    input  wire        ps_rdata_valid,
    input  wire        ps_init_calib,
    // observability / testbench hooks
    output wire        mon_a_sample,
    output wire        mon_w_capture,
    output wire        mon_ready,
    output reg         mon_vec_seen,
    output reg         mon_boot_ok,
    output reg  [15:0] mon_vec,
    output reg  [7:0]  mon_sig,
    output reg  [31:0] mon_cycles,
    output reg  [7:0]  mon_irq_cnt,
    output reg         mon_bus_err,
    output reg  [15:0] mon_stretch            // PHI2 cycles that were stretched
);
    localparam integer HALF  = CYC / 2;
    localparam integer T_DRV = (HALF > T_ASAMP + 3) ? HALF : T_ASAMP + 3;
    localparam integer I_END = CYC - 1, I_WCAP = CYC - 2, I_ASM1 = T_ASAMP - 1, I_AS1 = T_ASAMP + 1;
    localparam integer I_DRV1 = T_DRV - 1, I_DH1 = D_HOLD - 1, I_RDY1 = READY_PHI2 - 1;
    localparam [7:0] P_END  = I_END[7:0],  P_WCAP = I_WCAP[7:0], P_HALF = HALF[7:0];
    localparam [7:0] P_ASM1 = I_ASM1[7:0], P_AS   = T_ASAMP[7:0], P_AS1 = I_AS1[7:0], P_DRV1 = I_DRV1[7:0];
    localparam [7:0] P_DH1  = I_DH1[7:0];
    localparam [2:0] P_SSET = S_SETUP[2:0];
    localparam [15:0] P_RDY1 = I_RDY1[15:0];
    localparam [5:0] P_FL1  = 6'd57;

    generate
        if (D_HOLD < 1 || D_HOLD >= HALF) begin : g_err_dhold      k65_param_error_dhold      e(); end
        if (T_DRV > CYC - 3)              begin : g_err_too_fast   k65_param_error_too_fast   e(); end
        if (T_ASAMP <= D_HOLD)            begin : g_err_asamp      k65_param_error_asamp      e(); end
        if (S_SETUP < 1 || S_SETUP > 6)   begin : g_err_ssetup     k65_param_error_ssetup     e(); end
        if (FAST_RAM_BYTES < 2048 || FAST_RAM_BYTES > 32768 || FAST_RAM_BYTES % 2048 != 0)
                                          begin : g_err_fast       k65_param_error_fast_ram   e(); end
        if (ROM_BYTES != 4096 && ROM_BYTES != 2048)
                                          begin : g_err_rom        k65_param_error_rom_bytes  e(); end
    endgenerate

    // =====================================================================
    // PHI2 generator with stretch
    // =====================================================================
    reg  [7:0] ph;
    wire       hold_high;
    wire       at_end   = (ph == P_END);
    wire       cyc_end  = at_end && !hold_high;
    wire [7:0] ph_next  = cyc_end ? 8'd0 : (at_end ? ph : ph + 8'd1);
    reg        stretched;
    always @(posedge clk) begin
        if (rst) begin
            ph <= 8'd0; phi2 <= 1'b0; stretched <= 1'b0; mon_stretch <= 16'd0;
        end else begin
            ph   <= ph_next;
            phi2 <= (ph_next >= P_HALF);
            if (at_end && hold_high) stretched <= 1'b1;
            if (cyc_end) begin
                if (stretched) mon_stretch <= mon_stretch + 16'd1;
                stretched <= 1'b0;
            end
        end
    end

    // =====================================================================
    // Address / control capture and decode
    // =====================================================================
    reg  [15:0] a_q;
    reg         rw_q;
    reg  [7:0]  wdata_q;
    assign mon_a_sample  = (ph == P_ASM1);
    assign mon_w_capture = (ph == P_WCAP);

    wire d_ram  = ({16'd0, a_q} < FAST_RAM_BYTES);
    wire d_io   = (a_q[15:4]  == 12'hD00);
    wire d_rom  = ({16'd0, a_q} >= 32'h10000 - ROM_BYTES);
    wire d_ext  = (EXT_EN != 0) && ((a_q[15:8] == 8'hD3) || (EXT_EN >= 2 && a_q[15:8] == 8'hD4));
    wire d_none = (a_q[15:12] == 4'hD) && !d_io && !d_ext;
    wire d_ps   = !(d_ram || d_io || d_rom || d_none || d_ext);
    reg  [9:0]  bank;
    reg  sel_ram, sel_ps, sel_io, sel_rom, sel_none, sel_ext;
    reg  [21:0] ps_baddr;
    always @(posedge clk) begin
        if (mon_a_sample)  begin a_q <= a_in; rw_q <= rwb_in; end
        if (mon_w_capture) wdata_q <= d_in;
        if (ph == P_AS) begin
            sel_ram <= d_ram; sel_ps <= d_ps; sel_io <= d_io; sel_rom <= d_rom; sel_none <= d_none; sel_ext <= d_ext;
            ps_baddr <= (a_q[15:12] == 4'hC) ? {bank, a_q[11:0]} : {6'd0, a_q};
        end
    end

    // =====================================================================
    // I/O registers ($D000-$D00F)
    // =====================================================================
    reg        irq_pend;
    reg [7:0]  led_reg, sig_reg;
    reg        rom_wp, tmr_en;
    reg [TIMER_LOG2-1:0] tmr;
    wire   ext_irq_on = (EXT_EN != 0) && ext_irq;
    assign irq_low = irq_pend || ext_irq_on;

    reg [7:0] io_rd;
    always @(posedge clk) begin
        case (a_q[3:0])
            4'h0:    io_rd <= {irq_pend, ext_irq_on, 5'd0, mon_ready};
            4'h1:    io_rd <= led_reg;
            4'h2:    io_rd <= {7'd0, ps_init_calib};
            4'h3:    io_rd <= sig_reg;
            4'h4:    io_rd <= {7'd0, rom_wp};
            4'h5:    io_rd <= bank[7:0];
            4'h6:    io_rd <= {6'd0, bank[9:8]};
            4'h9:    io_rd <= {7'd0, tmr_en};
            4'hA:    io_rd <= rxf_head;
            4'hB:    io_rd <= {5'd0, rx_ovr, con_tx_ready, rxf_avail};
            4'hC:    io_rd <= ps_wp;
            default: io_rd <= 8'h00;
        endcase
    end

    // =====================================================================
    // Console UART ($D00A data, $D00B status) and PSRAM write protect ($D00C)
    //   $D00B read: bit0 RX byte available, bit1 TX can accept a byte,
    //               bit2 RX overrun (FIFO full when a byte arrived); reading $D00B clears it
    //   $D00A read pops the RX FIFO (side effect once per bus cycle, at its end)
    // =====================================================================
    reg  [7:0] ps_wp;
    reg  [7:0] con_hold;           // TX holding register
    reg        con_hold_v;
    wire       con_busy;
    wire       con_tx_ready = !con_hold_v;
    reg        con_go;
    always @(posedge clk) begin
        con_go <= 1'b0;
        if (rst) begin
            con_hold_v <= 1'b0; con_hold <= 8'h00;
        end else begin
            if (wr_commit && sel_io && a_q[3:0] == 4'hA) begin con_hold <= wdata_q; con_hold_v <= 1'b1; end
            else if (con_hold_v && !con_busy && !con_go) begin con_go <= 1'b1; con_hold_v <= 1'b0; end
        end
    end
    reg [7:0] con_tx_byte;
    always @(posedge clk) if (con_hold_v && !con_busy && !con_go) con_tx_byte <= con_hold;
    k65_uart_tx #(.DIV(CON_DIV)) u_con_tx (
        .clk(clk), .rst(rst), .data(con_tx_byte), .valid(con_go), .busy(con_busy), .tx(con_tx)
    );

    wire       rx_v;
    wire [7:0] rx_b;
    k65_uart_rx #(.DIV(CON_DIV)) u_con_rx (.clk(clk), .rst(rst), .rx(con_rx), .valid(rx_v), .data(rx_b));
    localparam integer RXN = 1 << RXF_LOG2;
    reg  [7:0] rxf [0:RXN-1];
    reg  [RXF_LOG2:0] rxf_wp, rxf_rp;
    reg        rx_ovr;
    wire       rxf_avail = (rxf_wp != rxf_rp);
    wire       rxf_full  = (rxf_wp[RXF_LOG2-1:0] == rxf_rp[RXF_LOG2-1:0]) && (rxf_wp[RXF_LOG2] != rxf_rp[RXF_LOG2]);
    wire [7:0] rxf_head  = rxf[rxf_rp[RXF_LOG2-1:0]];
    wire       rx_pop    = cyc_end && rw_q && sel_io && a_q[3:0] == 4'hA && rxf_avail;
    wire       rx_stat_rd = cyc_end && rw_q && sel_io && a_q[3:0] == 4'hB;
    always @(posedge clk) begin
        if (rst) begin
            rxf_wp <= 0; rxf_rp <= 0; rx_ovr <= 1'b0;
        end else begin
            if (rx_v) begin
                if (!rxf_full) begin rxf[rxf_wp[RXF_LOG2-1:0]] <= rx_b; rxf_wp <= rxf_wp + 1'b1; end
                else rx_ovr <= 1'b1;
            end else if (rx_stat_rd) rx_ovr <= 1'b0;
            if (rx_pop) rxf_rp <= rxf_rp + 1'b1;
        end
    end

    wire wr_commit = cyc_end && !rw_q;

    always @(posedge clk) begin
        if (rst) begin
            irq_pend <= 1'b0; led_reg <= 8'd0; sig_reg <= 8'd0; bank <= 10'd0;
            rom_wp <= 1'b1; tmr_en <= 1'b0; tmr <= 0; ps_wp <= 8'h00;
        end else begin
            tmr <= tmr + 1'b1;
            if (tmr_en && tmr == 0) irq_pend <= 1'b1;
            if (wr_commit && sel_io) begin
                case (a_q[3:0])
                    4'h0: irq_pend   <= 1'b0;
                    4'h1: led_reg    <= wdata_q;
                    4'h3: sig_reg    <= wdata_q;
                    4'h4: rom_wp     <= wdata_q[0];
                    4'h5: bank[7:0]  <= wdata_q;
                    4'h6: bank[9:8]  <= wdata_q[1:0];
                    4'h9: tmr_en     <= wdata_q[0];
                    4'hC: ps_wp      <= wdata_q;
                    default: ;
                endcase
            end
        end
    end

    // =====================================================================
    // BSRAM (single-port, normal write mode) with output pipeline register
    // =====================================================================
    localparam integer FA_W = $clog2(FAST_RAM_BYTES);
    reg [7:0] ram  [0:FAST_RAM_BYTES-1];
    localparam integer RA_W = $clog2(ROM_BYTES);
    reg [7:0] rom  [0:ROM_BYTES-1];
    initial $readmemh(ROM_FILE, rom);
    reg [7:0] ram_q, ram_q2, rom_q, rom_q2;
    always @(posedge clk) begin
        if (wr_commit && sel_ram) ram[a_q[FA_W-1:0]] <= wdata_q;
        else                      ram_q <= ram[a_q[FA_W-1:0]];
        ram_q2 <= ram_q;
    end
    always @(posedge clk) begin
        if (wr_commit && sel_rom && !rom_wp) rom[a_q[RA_W-1:0]] <= wdata_q;
        else                                 rom_q <= rom[a_q[RA_W-1:0]];
        rom_q2 <= rom_q;
    end

    // =====================================================================
    // PSRAM: read issued after decode, write posted at the PHI2 fall
    // =====================================================================
    wire       wb_full, ps_rd_done;
    wire [7:0] ps_rd_byte;
    reg        ps_done;
    reg  [2:0] ps_age;                 // edges since the read data arrived (saturating)
    reg  [7:0] ps_rdata_q;
    wire       ps_rd_go = (ph == P_AS1) && sel_ps && rw_q;
    always @(posedge clk) begin
        if (rst) begin
            ps_done <= 1'b1; ps_age <= 3'd7; ps_rdata_q <= 8'hFF;
        end else if (ps_rd_go) begin
            ps_done <= 1'b0; ps_age <= 3'd0;
        end else if (!ps_done) begin
            if (ps_rd_done) begin ps_done <= 1'b1; ps_rdata_q <= ps_rd_byte; end
        end else if (ps_age != 3'd7) begin
            ps_age <= ps_age + 3'd1;
        end
    end
    // reads: wait for the data, then S_SETUP edges on the bus before PHI2 falls
    // writes: commit only when the one-entry write buffer is free
    // PSRAM write protect ($D00C): physical byte address in [ps_wp*256, $C000)
    reg wp_hit;
    always @(posedge clk) if (ph == P_AS1)
        wp_hit <= (ps_wp != 8'h00) && (ps_baddr[21:16] == 6'd0) &&
                  (ps_baddr[15:8] >= ps_wp) && (ps_baddr[15:14] != 2'b11);
    assign hold_high = sel_ps && (rw_q ? !(ps_done && ps_age >= P_SSET) : (wb_full && !wp_hit));

    k65_psram_port u_port (
        .clk(clk), .rst(rst),
        .wr_go(wr_commit && sel_ps && !wp_hit), .wr_addr(ps_baddr), .wr_data(wdata_q), .wb_full(wb_full),
        .rd_go(ps_rd_go), .rd_addr(ps_baddr), .rd_done(ps_rd_done), .rd_byte(ps_rd_byte),
        .cmd(ps_cmd), .cmd_en(ps_cmd_en), .cmd_rdy(ps_cmd_rdy), .addr(ps_addr),
        .cmd_wdata(ps_wdata), .cmd_mask(ps_mask), .rdata(ps_rdata), .rdata_valid(ps_rdata_valid)
    );

    // =====================================================================
    // Read data drive
    // =====================================================================
    reg  [7:0] ext_q;
    always @(posedge clk) ext_q <= ext_rdata;
    assign ext_wr    = wr_commit && sel_ext;
    assign ext_rd    = cyc_end && rw_q && sel_ext;
    assign ext_addr  = a_q[7:0];
    assign ext_page  = a_q[11:8];
    assign ext_wdata = wdata_q;
    wire [7:0] rd_mux = sel_ram ? ram_q2 :
                        sel_rom ? rom_q2 :
                        sel_ps  ? ps_rdata_q :
                        sel_io  ? io_rd  :
                        sel_ext ? ext_q  : 8'hFF;
    always @(posedge clk) begin
        if (rst) begin
            d_oe <= 1'b0; d_out <= 8'hFF;
        end else begin
            if (ph == P_DRV1 && rw_q) begin
                d_oe  <= 1'b1;
                d_out <= rd_mux;
            end else if (sel_ps && rw_q && ps_done && ps_age == 3'd0 && d_oe) begin
                d_out <= ps_rdata_q;                 // PSRAM data that arrived after T_DRV
            end
            if (ph == P_DH1) d_oe <= 1'b0;
        end
    end

    // =====================================================================
    // READY: PSRAM initialised and PHI2 running for READY_PHI2 cycles
    // =====================================================================
    reg [15:0] phi2_cnt;
    reg        ready_r;
    assign mon_ready = ready_r;
    always @(posedge clk) begin
        if (rst) begin phi2_cnt <= 0; ready_r <= 1'b0; end
        else if (cyc_end && !ready_r) begin
            if (phi2_cnt != P_RDY1) phi2_cnt <= phi2_cnt + 16'd1;
            else if (ps_init_calib) ready_r <= 1'b1;
        end
    end

    // =====================================================================
    // Bus monitor (no SYNC needed): reset-vector detection, counters
    // A cycle is evaluated at its PHI2 fall with the data actually on the bus.
    // =====================================================================
    reg [1:0]  vstate;
    reg [7:0]  vlo;
    reg [15:0] mon_wr_cnt, mon_last_wa;
    reg [7:0]  mon_last_wd;
    wire [7:0] cyc_data = rw_q ? d_out : wdata_q;

    // address-match flags, precomputed at decode time (timing: keeps the 16-bit
    // comparators off the cyc_end -> counter path)
    reg m_fffc, m_fffd, m_fffe, m_vec;
    always @(posedge clk) if (ph == P_AS) begin
        m_fffc <= (a_q == 16'hFFFC);
        m_fffd <= (a_q == 16'hFFFD);
        m_fffe <= (a_q == 16'hFFFE);
        m_vec  <= (a_q == mon_vec);
    end
    // stage 1: latch the finished cycle; stage 2 (below) updates the monitor
    reg        ev_v, ev_rw, ev_fffc, ev_fffd, ev_fffe, ev_vec, ev_none;
    reg [15:0] ev_a;
    reg [7:0]  ev_d;
    always @(posedge clk) begin
        ev_v <= cyc_end && !rst;
        if (cyc_end) begin
            ev_rw <= rw_q; ev_a <= a_q; ev_d <= cyc_data; ev_none <= sel_none;
            ev_fffc <= m_fffc; ev_fffd <= m_fffd; ev_fffe <= m_fffe; ev_vec <= m_vec;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            vstate <= 0; mon_vec_seen <= 1'b0; mon_boot_ok <= 1'b0; mon_vec <= 16'h0000;
            mon_sig <= 8'h00; mon_cycles <= 0; mon_irq_cnt <= 0; mon_bus_err <= 1'b0;
            mon_wr_cnt <= 0; mon_last_wa <= 0; mon_last_wd <= 0; vlo <= 0;
        end else if (ev_v) begin
            mon_cycles <= mon_cycles + 32'd1;
            mon_sig    <= sig_reg;
            if (!ev_rw) begin
                mon_wr_cnt  <= mon_wr_cnt + 16'd1;
                mon_last_wa <= ev_a;
                mon_last_wd <= ev_d;
            end
            if (ev_rw && ev_fffe) mon_irq_cnt <= mon_irq_cnt + 8'd1;
            if (mon_vec_seen && ev_none) mon_bus_err <= 1'b1;
            case (vstate)
                2'd1: if (ev_rw && ev_fffd) begin
                          mon_vec      <= {ev_d, vlo};
                          mon_vec_seen <= 1'b1;
                          mon_boot_ok  <= 1'b0;
                          mon_cycles   <= 32'd0;       // count from the vector fetch
                          mon_wr_cnt   <= 16'd0;
                          mon_bus_err  <= 1'b0;
                          mon_irq_cnt  <= 8'd0;
                          vstate       <= 2'd2;
                      end else vstate <= 2'd0;
                2'd2: begin
                          mon_boot_ok <= ev_rw && ev_vec;
                          vstate      <= 2'd0;
                      end
                default: ;
            endcase
            if (ev_rw && ev_fffc) begin vlo <= ev_d; vstate <= 2'd1; end
        end
    end

    // =====================================================================
    // Status frame over UART (to XIAO and to BL702):
    //   "K65 S=ss V=vvvv C=cccccccc W=wwww L=aaaa:dd G=gg I=ii*xx\r\n"  (58 chars)
    //   S bits: 0 alive, 1 READY, 2 vector seen, 3 first fetch at vector,
    //           4 bus error, 5 ROM write-protect, 6 IRQ pending, 7 SYNC input
    //   xx = 8-bit sum of all characters before '*'
    // =====================================================================
    // frame length = 58 characters (index 0..57, see P_FL1)
    reg  [HB_LOG2-1:0] hb;
    reg  [5:0]  fidx;
    reg         fbusy;
    reg  [7:0]  fsum;
    reg  [7:0]  s_st, s_g, s_i, s_ld;
    reg  [15:0] s_v, s_w, s_l;
    reg  [31:0] s_c;
    wire        tx_busy;
    reg         tx_valid;
    reg  [7:0]  tx_byte;

    function [7:0] hexc(input [3:0] n);
        hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
    endfunction

    reg [7:0] ch;
    always @(*) begin
        case (fidx)
            6'd0: ch = "K";  6'd1: ch = "6";  6'd2: ch = "5";  6'd3: ch = " ";
            6'd4: ch = "S";  6'd5: ch = "=";
            6'd6: ch = hexc(s_st[7:4]); 6'd7: ch = hexc(s_st[3:0]);
            6'd8: ch = " ";  6'd9: ch = "V";  6'd10: ch = "=";
            6'd11: ch = hexc(s_v[15:12]); 6'd12: ch = hexc(s_v[11:8]);
            6'd13: ch = hexc(s_v[7:4]);   6'd14: ch = hexc(s_v[3:0]);
            6'd15: ch = " "; 6'd16: ch = "C"; 6'd17: ch = "=";
            6'd18: ch = hexc(s_c[31:28]); 6'd19: ch = hexc(s_c[27:24]);
            6'd20: ch = hexc(s_c[23:20]); 6'd21: ch = hexc(s_c[19:16]);
            6'd22: ch = hexc(s_c[15:12]); 6'd23: ch = hexc(s_c[11:8]);
            6'd24: ch = hexc(s_c[7:4]);   6'd25: ch = hexc(s_c[3:0]);
            6'd26: ch = " "; 6'd27: ch = "W"; 6'd28: ch = "=";
            6'd29: ch = hexc(s_w[15:12]); 6'd30: ch = hexc(s_w[11:8]);
            6'd31: ch = hexc(s_w[7:4]);   6'd32: ch = hexc(s_w[3:0]);
            6'd33: ch = " "; 6'd34: ch = "L"; 6'd35: ch = "=";
            6'd36: ch = hexc(s_l[15:12]); 6'd37: ch = hexc(s_l[11:8]);
            6'd38: ch = hexc(s_l[7:4]);   6'd39: ch = hexc(s_l[3:0]);
            6'd40: ch = ":";
            6'd41: ch = hexc(s_ld[7:4]);  6'd42: ch = hexc(s_ld[3:0]);
            6'd43: ch = " "; 6'd44: ch = "G"; 6'd45: ch = "=";
            6'd46: ch = hexc(s_g[7:4]);   6'd47: ch = hexc(s_g[3:0]);
            6'd48: ch = " "; 6'd49: ch = "I"; 6'd50: ch = "=";
            6'd51: ch = hexc(s_i[7:4]);   6'd52: ch = hexc(s_i[3:0]);
            6'd53: ch = "*";
            6'd54: ch = hexc(fsum[7:4]);  6'd55: ch = hexc(fsum[3:0]);
            6'd56: ch = 8'h0D;
            default: ch = 8'h0A;
        endcase
    end

    // ch is registered (ch_r) before it is sent / summed (timing); ch_ok marks
    // that ch_r already reflects the current fidx.
    reg [7:0] ch_r;
    reg       ch_ok;
    always @(posedge clk) ch_r <= ch;

    always @(posedge clk) begin
        if (rst) begin
            hb <= 0; fidx <= 0; fbusy <= 1'b0; fsum <= 0; tx_valid <= 1'b0; tx_byte <= 8'h00;
            ch_ok <= 1'b0;
        end else begin
            hb <= hb + 1'b1;
            tx_valid <= 1'b0;
            if (!fbusy) begin
                ch_ok <= 1'b0;
                if (hb == 0) begin
                    fbusy <= 1'b1; fidx <= 0; fsum <= 0;
                    s_st <= {sync_in, irq_pend, rom_wp, mon_bus_err, mon_boot_ok,
                             mon_vec_seen, ready_r, 1'b1};
                    s_v <= mon_vec; s_c <= mon_cycles; s_w <= mon_wr_cnt;
                    s_l <= mon_last_wa; s_ld <= mon_last_wd; s_g <= mon_sig; s_i <= mon_irq_cnt;
                end
            end else if (!ch_ok) begin
                ch_ok <= 1'b1;
            end else if (!tx_busy && !tx_valid) begin
                tx_byte  <= ch_r;
                tx_valid <= 1'b1;
                ch_ok    <= 1'b0;
                if (fidx < 6'd53) fsum <= fsum + ch_r;
                if (fidx == P_FL1) fbusy <= 1'b0;
                else               fidx  <= fidx + 6'd1;
            end
        end
    end

    k65_uart_tx #(.DIV(UART_DIV)) u_tx (
        .clk(clk), .rst(rst), .data(tx_byte), .valid(tx_valid), .busy(tx_busy), .tx(uart_tx)
    );

    // =====================================================================
    // LEDs / debug pins
    // =====================================================================
    assign led = {mon_bus_err | (mon_sig == 8'hEE), led_reg[0], (mon_sig == 8'hC3),
                  mon_boot_ok, mon_vec_seen, ready_r};
    assign dbg = {wr_commit, mon_vec_seen, d_oe, phi2};
endmodule
