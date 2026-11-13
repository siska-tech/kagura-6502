// 8N1 UART transmitter. tx idles high.
module k65_uart_tx #(
    parameter integer DIV = 645          // sysclk / baud (74.25 MHz / 115200 = 644.5)
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,              // pulse while !busy to send one byte
    output wire       busy,
    output reg        tx
);
    reg [9:0]  sh;
    reg [3:0]  nbit;
    reg [15:0] cnt;
    localparam integer DIV_M1 = DIV - 1;
    localparam [15:0] DIVM1 = DIV_M1[15:0];
    assign busy = (nbit != 0);
    always @(posedge clk) begin
        if (rst) begin
            tx <= 1'b1; nbit <= 0; cnt <= 0; sh <= 10'h3FF;
        end else if (nbit == 0) begin
            tx <= 1'b1;
            if (valid) begin
                sh   <= {1'b1, data, 1'b0};
                nbit <= 4'd10;
                cnt  <= 0;
            end
        end else begin
            tx <= sh[0];
            if (cnt == DIVM1) begin
                cnt  <= 0;
                sh   <= {1'b1, sh[9:1]};
                nbit <= nbit - 4'd1;
            end else cnt <= cnt + 16'd1;
        end
    end
endmodule
