// 8N1 UART receiver (KAGURA-6502 console). rx idles high.
// 2-FF synchroniser, start bit confirmed at its middle, data sampled at bit
// centres (DIV sysclk per bit), stop bit must be high (else the byte is dropped:
// framing error / break). One-cycle 'valid' pulse per received byte.
module k65_uart_rx #(
    parameter integer DIV = 469          // sysclk / baud (54 MHz / 115200 = 468.75)
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg        valid,
    output reg  [7:0] data
);
    localparam integer HALF_M1 = DIV / 2 - 1;
    localparam integer DIV_M1  = DIV - 1;
    reg [2:0]  sync;                    // sync[2] is the synchronised input
    reg [15:0] cnt;
    reg [3:0]  nbit;                    // 0 idle, 1 start, 2..9 data, 10 stop
    reg [7:0]  sh;
    always @(posedge clk) begin
        sync  <= {sync[1:0], rx};
        valid <= 1'b0;
        if (rst) begin
            sync <= 3'b111; nbit <= 4'd0; cnt <= 16'd0;
        end else if (nbit == 4'd0) begin
            if (sync[2:1] == 2'b10) begin nbit <= 4'd1; cnt <= 16'd0; end   // falling edge
        end else if ((nbit == 4'd1) ? (cnt == HALF_M1[15:0]) : (cnt == DIV_M1[15:0])) begin
            cnt <= 16'd0;
            if (nbit == 4'd1) begin
                nbit <= sync[2] ? 4'd0 : 4'd2;                 // glitch: back to idle
            end else if (nbit == 4'd10) begin
                nbit <= 4'd0;
                if (sync[2]) begin valid <= 1'b1; data <= sh; end
            end else begin
                sh   <= {sync[2], sh[7:1]};
                nbit <= nbit + 4'd1;
            end
        end else cnt <= cnt + 16'd1;
    end
endmodule
