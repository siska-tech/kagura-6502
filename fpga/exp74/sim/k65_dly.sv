// Constant transport delay (integer ps) for testbench board/pin models.
// One process + FIFO: exact for any pulse train (no inertial filtering, no
// dropped trailing events). Self-tested by fpga/exp74/tools/selftest/tb_tdly.sv
// (same algorithm as k65_tdly).
`timescale 1ps/1ps
module k65_dly #(parameter integer D = 1000, parameter integer W = 1, parameter [W-1:0] INIT = '0) (
    input  wire  [W-1:0] in,
    output logic [W-1:0] out
);
    typedef struct { longint t; logic [W-1:0] v; } ev_t;
    ev_t q[$];
    int n_in = 0, n_out = 0;
    initial out = INIT;
    always @(in) begin q.push_back('{longint'($time) + D, in}); n_in++; end
    initial forever begin
        wait (n_in != n_out);
        if (q[0].t > longint'($time)) #(q[0].t - longint'($time));
        out = q[0].v;
        void'(q.pop_front());
        n_out++;
    end
endmodule
