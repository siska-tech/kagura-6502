// KAGURA-6502: 6502 byte accesses -> kagura_hyperram_ctrl (one PSRAM die, 32-bit words).
// System clock domain (same clock as the bus engine and the controller).
//   * write: posted. One-entry buffer; wb_full tells the bus engine to stretch
//     PHI2 only if a second PSRAM write arrives before the first was accepted.
//   * read : issued when requested; rd_done pulses with the byte. A pending
//     buffered write is always sent first (program order is kept).
// Byte address -> controller word address = baddr[21:2], lane = baddr[1:0]
// (controller convention: byte i of a word is wr_data/rd_data[8*i +: 8];
//  data_mask bit i = 1 masks byte i).
module k65_psram_port (
    input  wire        clk,
    input  wire        rst,
    // bus engine side
    input  wire        wr_go,          // push a write (only when !wb_full)
    input  wire [21:0] wr_addr,
    input  wire [7:0]  wr_data,
    output wire        wb_full,
    input  wire        rd_go,          // request a read (one outstanding)
    input  wire [21:0] rd_addr,
    output reg         rd_done,        // 1-clock pulse
    output reg  [7:0]  rd_byte,
    // kagura_hyperram_ctrl side
    output wire        cmd,            // 1 write, 0 read
    output wire        cmd_en,
    input  wire        cmd_rdy,
    output wire [19:0] addr,
    output wire [31:0] cmd_wdata,
    output wire [3:0]  cmd_mask,
    input  wire [31:0] rdata,
    input  wire        rdata_valid
);
    reg        wb_v;
    reg [21:0] wb_a;
    reg [7:0]  wb_d;
    reg        rq_v, rq_issued;
    reg [21:0] rq_a;
    assign wb_full = wb_v;

    wire do_wr = wb_v;
    wire do_rd = !wb_v && rq_v && !rq_issued;
    assign cmd_en    = do_wr || do_rd;
    assign cmd       = do_wr;
    assign addr      = do_wr ? wb_a[21:2] : rq_a[21:2];
    assign cmd_wdata = {4{wb_d}};
    assign cmd_mask  = ~(4'b0001 << wb_a[1:0]);
    wire accept = cmd_en && cmd_rdy;

    always @(posedge clk) begin
        if (rst) begin
            wb_v <= 1'b0; rq_v <= 1'b0; rq_issued <= 1'b0; rd_done <= 1'b0; rd_byte <= 8'h00;
        end else begin
            rd_done <= 1'b0;
            if (accept && do_wr) wb_v <= 1'b0;
            if (wr_go) begin wb_v <= 1'b1; wb_a <= wr_addr; wb_d <= wr_data; end
            if (accept && do_rd) rq_issued <= 1'b1;
            if (rq_issued && rdata_valid) begin
                rd_done   <= 1'b1;
                rd_byte   <= rdata[8 * rq_a[1:0] +: 8];
                rq_v      <= 1'b0;
                rq_issued <= 1'b0;
            end
            if (rd_go) begin rq_v <= 1'b1; rq_a <= rd_addr; rq_issued <= 1'b0; end
        end
    end
endmodule
