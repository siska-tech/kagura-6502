// KAGURA-6502 HDMI PHY for GW1NR-9: 4 x OSER10 (10:1, LSB first) + ELVDS_OBUF.
// OSER10 use the chip GSR only (GSREN="true", LSREN="false", RESET tied low):
// there is no fabric reset path from the pixel domain into the 371.25 MHz
// serial domain (the path that failed STA in pincheck; UG289: RESET is async).
// The clock lane is sent through an OSER10 as 5 ones + 5 zeros like the data lanes.
module k65_hdmi_phy (
    input  wire       clk_pixel,          // 74.25 MHz (PCLK)
    input  wire       clk_serial,         // 371.25 MHz (FCLK), CLKDIV /5 source
    input  wire [9:0] sym0,
    input  wire [9:0] sym1,
    input  wire [9:0] sym2,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);
    wire [9:0] lane [0:3];
    assign lane[0] = sym0;
    assign lane[1] = sym1;
    assign lane[2] = sym2;
    assign lane[3] = 10'b0000011111;
    wire [3:0] ser;
    genvar i;
    generate for (i = 0; i < 4; i = i + 1) begin : g_lane
        OSER10 #(.GSREN("true"), .LSREN("false")) u_ser (
            .Q(ser[i]), .PCLK(clk_pixel), .FCLK(clk_serial), .RESET(1'b0),
            .D0(lane[i][0]), .D1(lane[i][1]), .D2(lane[i][2]), .D3(lane[i][3]), .D4(lane[i][4]),
            .D5(lane[i][5]), .D6(lane[i][6]), .D7(lane[i][7]), .D8(lane[i][8]), .D9(lane[i][9])
        );
    end endgenerate
    ELVDS_OBUF u_ck (.I(ser[3]), .O(tmds_clk_p), .OB(tmds_clk_n));
    generate for (i = 0; i < 3; i = i + 1) begin : g_obuf
        ELVDS_OBUF u_d (.I(ser[i]), .O(tmds_d_p[i]), .OB(tmds_d_n[i]));
    end endgenerate
endmodule
