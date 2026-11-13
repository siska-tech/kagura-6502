// PWM (first-order delta-sigma) consistency check (testbench only).
// The DUT computes, every clk_pix:  ds <= ds[15:0] + U(sample);  pwm <= ds[16]
// with U = offset-binary of the signed 16-bit sample. So the output bit at clock k+2 is the
// carry of adding the sample visible at clock k. For every run of N clocks with the same
// sample value u, a first-order modulator with a residue in [0, 65536) gives
//     ones = floor((r0 + N*u) / 65536)  ->  floor(N*u/65536) <= ones <= floor(N*u/65536) + 1
// This checker applies that bound to every run (each 48 kHz sample, ~1547 clocks) and to
// the whole simulation, for L (sample[15:0]) and R (sample[31:16]) separately. It does not
// look inside the DUT: it sees only the sample register and the two PWM pins.
module tb_pwm_check (
    input logic        clk,
    input logic        rst,
    input logic [31:0] sample,         // the register the modulator reads (HDMI sample)
    input logic        pwm_l,
    input logic        pwm_r
);
    int errors = 0, n_runs = 0;
    longint tot_n = 0, tot_u_l = 0, tot_u_r = 0, tot_l = 0, tot_r = 0;
    string name = "pwm";
    logic [31:0] d1, d2;               // sample delayed by 1 and 2 clocks
    logic        v1 = 0, v2 = 0;
    logic [31:0] run_s; int run_n = 0, run_l = 0, run_r = 0; logic run_on = 0;
    task automatic fail(input string m);
        errors++;
        if (errors <= 10) $display("[%0.3f us] ERROR (%s check): %s", $realtime / 1.0e6, name, m);
    endtask
    function automatic longint u16(input logic [15:0] s); return longint'({~s[15], s[14:0]}); endfunction
    task automatic close_run();
        longint ul = u16(run_s[15:0]), ur = u16(run_s[31:16]);
        longint fl = (run_n * ul) / 65536, fr = (run_n * ur) / 65536;
        if (run_l < fl || run_l > fl + 1) fail($sformatf("L run of %0d clocks at %04h: %0d ones, expected %0d..%0d", run_n, run_s[15:0], run_l, fl, fl + 1));
        if (run_r < fr || run_r > fr + 1) fail($sformatf("R run of %0d clocks at %04h: %0d ones, expected %0d..%0d", run_n, run_s[31:16], run_r, fr, fr + 1));
        n_runs++;
    endtask
    always @(negedge clk) begin
        if (rst) begin v1 = 0; v2 = 0; run_on = 0; end
        else begin
            // pwm now belongs to the sample seen two clocks ago (d2)
            if (v2) begin
                if (!run_on || d2 !== run_s) begin
                    if (run_on) close_run();
                    run_on = 1; run_s = d2; run_n = 0; run_l = 0; run_r = 0;
                end
                run_n++; run_l += pwm_l; run_r += pwm_r;
                tot_n++; tot_l += pwm_l; tot_r += pwm_r; tot_u_l += u16(d2[15:0]); tot_u_r += u16(d2[31:16]);
            end
            d2 = d1; v2 = v1; d1 = sample; v1 = 1;
        end
    end
    function automatic string summary();
        real el = tot_l - tot_u_l / 65536.0, er = tot_r - tot_u_r / 65536.0;
        if (el < -1.0 || el > 1.0 || er < -1.0 || er > 1.0) fail($sformatf("whole run: ones - sum(u)/65536 = %0.3f (L), %0.3f (R)", el, er));
        return $sformatf("%s: %0d sample runs checked over %0d clocks, whole-run error %0.3f / %0.3f counts (bound 1), duty L %0.5f R %0.5f, errors %0d",
                         name, n_runs, tot_n, el, er, tot_n ? tot_l * 1.0 / tot_n : 0.0, tot_n ? tot_r * 1.0 / tot_n : 0.0, errors);
    endfunction
endmodule
