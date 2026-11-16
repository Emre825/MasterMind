// MasterMind top module (5-digit, base-10)
//
// histogram module: per-digit-value counter            (combinational leaf)
// plus_count module: positional (exact) match counter  (combinational leaf)
// minsum5 module: 5-wide sum-of-min reducer            (combinational leaf)
// scorer module: folded 2-stage / 2-phase top level    (sequential)
//
// SS1 & SS2 means Super Stage 1 & 2, they are distinct hardware blocks.
// SS1 is for histogram + plus_count and SS2 is for minsum5, SS2 uses the outputs of SS1.
// Both stages take 2 cycles so the total latency is 4 cycles.
// phase0 (ph0) and phase1 (ph1) are the actual FSM states.
// ph0 is the first cycle work of SS1 & SS2, ph1 is the second cycle work of SS1 & SS2.
// In these phases & states, both SS1 and SS2 works simultaneously on different data.
// s1 & s2 registers are folding holds.
// s1 holds the output of ph0 in SS1, s2 holds the output of ph0 in SS2.
// We need these registers because each stage reuses one unit across its two cycles to reduce area.
// P1 & out registers are pipeline-boundary registers.
// P1 holds the output of SS1 and out holds the output of SS2 (the final score).
`timescale 1ns/1ps

// Folded functional pipeline: latency 4 cycles, Cycle time 2 cycles (new input every 2 cycles).
// One histogram (ref on ph0, guess on ph1) and one minsum5 (bins 0..4 on ph0,
// bins 5..9 on ph1) are time-shared. vld_in starts the 2-phase heartbeat.
// minus = total - plus, total = sum over values of min(ref_count, guess_count).
module scorer #(
    parameter DIGIT_W = 4,
    parameter SCORE_W = 3
) (
    input clk, rst, vld_in,
    input [DIGIT_W-1:0] ref4, ref3, ref2, ref1, ref0,
    input [DIGIT_W-1:0] guess4, guess3, guess2, guess1, guess0,
    output reg [SCORE_W-1:0] plus, minus,
    output reg vld_out
);

    localparam HW   = 10*SCORE_W;   // packed histogram width (bin k at [k*SCORE_W +: SCORE_W])
    localparam HALF = 5*SCORE_W;    // one histogram half (5 bins) fed to minsum5

    // control
    reg run, ph, run_nxt, ph_nxt;
    reg is_ph0, is_ph1;             // ph0: load / hist_ref / minsum-low ; ph1: hist_guess / finalize

    // SS1 (histogram stage) hold registers
    reg [HW-1:0]      s1_href, s1_href_nxt;
    reg [DIGIT_W-1:0] s1_g4, s1_g3, s1_g2, s1_g1, s1_g0;
    reg [DIGIT_W-1:0] s1_g4_nxt, s1_g3_nxt, s1_g2_nxt, s1_g1_nxt, s1_g0_nxt;
    reg [SCORE_W-1:0] s1_plus, s1_plus_nxt;
    reg               s1_vld, s1_vld_nxt;

    // P1 pipeline register (between the two stages)
    reg [HW-1:0]      p1_href, p1_href_nxt, p1_hguess, p1_hguess_nxt;
    reg [SCORE_W-1:0] p1_plus, p1_plus_nxt;
    reg               p1_vld, p1_vld_nxt;

    // SS2 (minsum stage) hold registers
    reg [SCORE_W-1:0] s2_low, s2_low_nxt, s2_plus, s2_plus_nxt;
    reg               s2_vld, s2_vld_nxt;

    // output next-state
    reg [SCORE_W-1:0] plus_nxt, minus_nxt;
    reg               vld_out_nxt;

    // datapath combinational
    reg  [DIGIT_W-1:0] hd4, hd3, hd2, hd1, hd0;   // histogram input (ref or stored guess)
    reg  [HALF-1:0]    ms_a, ms_b;                // minsum input (selected histogram half)
    wire [HW-1:0]      hbins;                     // shared histogram output
    wire [SCORE_W-1:0] plus_w;                    // positional (exact) matches
    wire [SCORE_W-1:0] minsum_s;                  // shared minsum output

    // shared functional units
    histogram #(.DIGIT_W(DIGIT_W), .SCORE_W(SCORE_W)) u_hist (
        .d4(hd4), .d3(hd3), .d2(hd2), .d1(hd1), .d0(hd0),
        .h0(hbins[0*SCORE_W +: SCORE_W]), .h1(hbins[1*SCORE_W +: SCORE_W]),
        .h2(hbins[2*SCORE_W +: SCORE_W]), .h3(hbins[3*SCORE_W +: SCORE_W]),
        .h4(hbins[4*SCORE_W +: SCORE_W]), .h5(hbins[5*SCORE_W +: SCORE_W]),
        .h6(hbins[6*SCORE_W +: SCORE_W]), .h7(hbins[7*SCORE_W +: SCORE_W]),
        .h8(hbins[8*SCORE_W +: SCORE_W]), .h9(hbins[9*SCORE_W +: SCORE_W])
    );

    plus_count #(.DIGIT_W(DIGIT_W), .SCORE_W(SCORE_W)) u_plus (
        .r4(ref4), .r3(ref3), .r2(ref2), .r1(ref1), .r0(ref0),
        .g4(guess4), .g3(guess3), .g2(guess2), .g1(guess1), .g0(guess0),
        .p(plus_w)
    );

    minsum5 #(.SCORE_W(SCORE_W)) u_min (
        .a0(ms_a[0*SCORE_W +: SCORE_W]), .a1(ms_a[1*SCORE_W +: SCORE_W]),
        .a2(ms_a[2*SCORE_W +: SCORE_W]), .a3(ms_a[3*SCORE_W +: SCORE_W]),
        .a4(ms_a[4*SCORE_W +: SCORE_W]),
        .b0(ms_b[0*SCORE_W +: SCORE_W]), .b1(ms_b[1*SCORE_W +: SCORE_W]),
        .b2(ms_b[2*SCORE_W +: SCORE_W]), .b3(ms_b[3*SCORE_W +: SCORE_W]),
        .b4(ms_b[4*SCORE_W +: SCORE_W]),
        .s(minsum_s)
    );

    // phase
    always @* begin
        is_ph1 = run & ph;
        is_ph0 = ~is_ph1;
    end

    // vld_in starts ph0; afterwards the phase free-runs so SS2 keeps draining.
    always @* begin
        run_nxt = run;
        ph_nxt  = ph;
        if (rst) begin
            run_nxt = 1'b0;
            ph_nxt  = 1'b0;
        end else if (!run) begin
            if (vld_in) begin
                run_nxt = 1'b1;
                ph_nxt  = 1'b1;
            end
        end else begin
            ph_nxt = ~ph;
        end
    end

    // histogram input mux: ref on ph0, stored guess on ph1
    always @* begin
        hd4 = ref4; hd3 = ref3; hd2 = ref2; hd1 = ref1; hd0 = ref0;
        if (is_ph1) begin
            hd4 = s1_g4; hd3 = s1_g3; hd2 = s1_g2; hd1 = s1_g1; hd0 = s1_g0;
        end
    end

    // SS1 capture (ph0): ref histogram, guess digits (for ph1), plus, valid
    always @* begin
        s1_href_nxt = s1_href;
        s1_g4_nxt = s1_g4; s1_g3_nxt = s1_g3; s1_g2_nxt = s1_g2; s1_g1_nxt = s1_g1; s1_g0_nxt = s1_g0;
        s1_plus_nxt = s1_plus;
        s1_vld_nxt  = s1_vld;
        if (rst) begin
            s1_vld_nxt = 1'b0;
        end else if (is_ph0) begin
            s1_href_nxt = hbins;
            s1_g4_nxt = guess4; s1_g3_nxt = guess3; s1_g2_nxt = guess2; s1_g1_nxt = guess1; s1_g0_nxt = guess0;
            s1_plus_nxt = plus_w;
            s1_vld_nxt  = vld_in;
        end
    end

    // P1 capture (ph1): both histograms + plus + valid
    always @* begin
        p1_href_nxt   = p1_href;
        p1_hguess_nxt = p1_hguess;
        p1_plus_nxt   = p1_plus;
        p1_vld_nxt    = p1_vld;
        if (rst) begin
            p1_vld_nxt = 1'b0;
        end else if (is_ph1) begin
            p1_href_nxt   = s1_href;
            p1_hguess_nxt = hbins;
            p1_plus_nxt   = s1_plus;
            p1_vld_nxt    = s1_vld;
        end
    end

    // minsum input mux: low half (bins 0..4) on ph0, high half (bins 5..9) on ph1
    always @* begin
        ms_a = p1_href[0 +: HALF];
        ms_b = p1_hguess[0 +: HALF];
        if (is_ph1) begin
            ms_a = p1_href[HALF +: HALF];
            ms_b = p1_hguess[HALF +: HALF];
        end
    end

    // SS2 capture (ph0): low-bin partial sum, plus, valid
    always @* begin
        s2_low_nxt  = s2_low;
        s2_plus_nxt = s2_plus;
        s2_vld_nxt  = s2_vld;
        if (rst) begin
            s2_vld_nxt = 1'b0;
        end else if (is_ph0) begin
            s2_low_nxt  = minsum_s;
            s2_plus_nxt = p1_plus;
            s2_vld_nxt  = p1_vld;
        end
    end

    // output (ph1): minus = total - plus, total = low + high; vld_out is a 1-cycle pulse
    always @* begin
        plus_nxt    = plus;
        minus_nxt   = minus;
        vld_out_nxt = 1'b0;
        if (rst) begin
            vld_out_nxt = 1'b0;
        end else if (is_ph1) begin
            plus_nxt    = s2_plus;
            minus_nxt   = s2_low + minsum_s - s2_plus;
            vld_out_nxt = s2_vld;
        end
    end

    // registers
    always @(posedge clk) begin
        run <= #1 run_nxt;
        ph  <= #1 ph_nxt;
        s1_href <= #1 s1_href_nxt;
        s1_g4 <= #1 s1_g4_nxt; s1_g3 <= #1 s1_g3_nxt; s1_g2 <= #1 s1_g2_nxt; s1_g1 <= #1 s1_g1_nxt; s1_g0 <= #1 s1_g0_nxt;
        s1_plus <= #1 s1_plus_nxt;
        s1_vld  <= #1 s1_vld_nxt;
        p1_href   <= #1 p1_href_nxt;
        p1_hguess <= #1 p1_hguess_nxt;
        p1_plus   <= #1 p1_plus_nxt;
        p1_vld    <= #1 p1_vld_nxt;
        s2_low  <= #1 s2_low_nxt;
        s2_plus <= #1 s2_plus_nxt;
        s2_vld  <= #1 s2_vld_nxt;
        plus    <= #1 plus_nxt;
        minus   <= #1 minus_nxt;
        vld_out <= #1 vld_out_nxt;
    end
endmodule

// Counts how many of the five input digits equal to each value 0..9:
// h0 + h1 + ... + h9 == 5. Each count is in the range 0..5 and fits in 3 bits. Purely combinational.
module histogram #(
    parameter DIGIT_W = 4,
    parameter SCORE_W = 3
) (
    input  [DIGIT_W-1:0] d4, d3, d2, d1, d0,         // five digits (d4 = most significant)
    output reg [SCORE_W-1:0] h0, h1, h2, h3, h4,     // count of value 0,1,2,3,4
    output reg [SCORE_W-1:0] h5, h6, h7, h8, h9      // count of value 5,6,7,8,9
);

    // Helper: how many of the five digits {x0..x4} equal `val`.
    // Each (==) yields 1 bit; the SCORE_W-wide result sums them (max = 5).
    function [SCORE_W-1:0] cnt5;
        input [DIGIT_W-1:0] val;                 // value to look for
        input [DIGIT_W-1:0] x0, x1, x2, x3, x4;  // the five digits
        begin
            cnt5 = (x0 == val) + (x1 == val) + (x2 == val) + (x3 == val) + (x4 == val);
        end
    endfunction

    // The same cnt5 expression is reused 10 times.
    always @* begin
        h0 = cnt5(4'd0, d4, d3, d2, d1, d0);
        h1 = cnt5(4'd1, d4, d3, d2, d1, d0);
        h2 = cnt5(4'd2, d4, d3, d2, d1, d0);
        h3 = cnt5(4'd3, d4, d3, d2, d1, d0);
        h4 = cnt5(4'd4, d4, d3, d2, d1, d0);
        h5 = cnt5(4'd5, d4, d3, d2, d1, d0);
        h6 = cnt5(4'd6, d4, d3, d2, d1, d0);
        h7 = cnt5(4'd7, d4, d3, d2, d1, d0);
        h8 = cnt5(4'd8, d4, d3, d2, d1, d0);
        h9 = cnt5(4'd9, d4, d3, d2, d1, d0);
    end
endmodule

// Counts positions where ref and guess hold the same digit (exact matches).
// p = (r4==g4) + (r3==g3) + ... + (r0==g0), range 0..5, fits in 3 bits.
module plus_count #(
    parameter DIGIT_W = 4,
    parameter SCORE_W = 3
) (
    input  [DIGIT_W-1:0] r4, r3, r2, r1, r0,     // reference digits
    input  [DIGIT_W-1:0] g4, g3, g2, g1, g0,     // guess digits
    output reg [SCORE_W-1:0] p                   // number of exact (value+position) matches
);

    // Sum of the five position-wise equalities into the SCORE_W-wide result.
    always @* begin
        p = (r4 == g4) + (r3 == g3) + (r2 == g2) + (r1 == g1) + (r0 == g0);
    end
endmodule

// Sum of per-value minimums for one half (5 bins) of the histograms:
// s = min(a0,b0) + min(a1,b1) + ... + min(a4,b4), range 0..5, fits in 3 bits.
// The scorer folds the low (0..4) and high (5..9) bins through one instance.
module minsum5 #(
    parameter SCORE_W = 3
) (
    input  [SCORE_W-1:0] a0, a1, a2, a3, a4,     // one histogram's bins (e.g. ref)
    input  [SCORE_W-1:0] b0, b1, b2, b3, b4,     // the other histogram's bins (e.g. guess)
    output reg [SCORE_W-1:0] s                   // sum of the five min(a,b)
);

    // Per-pair minimum: comparator + mux.
    function [SCORE_W-1:0] min2;
        input [SCORE_W-1:0] a, b;
        begin
            min2 = (a < b) ? a : b;
        end
    endfunction

    always @* begin
        s = min2(a0, b0) + min2(a1, b1) + min2(a2, b2) + min2(a3, b3) + min2(a4, b4);
    end
endmodule
