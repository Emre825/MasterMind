// Self-checking testbench for the MasterMind scorer (mastermind.v).
//
// After reset, the first cycle with vld_in=1 starts ph0; the 2-cycle
// heartbeat then free-runs, so a new input is accepted every 2 cycles.
// Result for an input appears 4 cycles later as a 1-cycle vld_out pulse.
//
// an independent golden model computes the expected (plus,minus);
// a small FIFO scoreboard matches each vld_out pulse against the oldest
// outstanding input (handles the 4-cycle latency / up-to-2 in flight).
//
// when we apply an input, apply task computes the expected score of that input
// and pushes it onto FIFO (scoreboard). When vld_out pulses, checker pops the oldest entry
// and compares against the DUT output.
// 
// Test sequence: 
// 2 specific examples to check if the golden model is working correctly, not counted in checked
// 12 directed cases to check specific scenarios (full match, no match, permutation, repeats, leading zeros etc.), all of them are counted in checked
// 3 gap tests to check that bubbles in the input stream do not cause spurious vld_out pulses, all of them are counted in checked
// 100 random cases to check overall robustness, all of them are counted in checked
// 2 reset tests to check that reset flushes in-flight inputs and restarts cleanly, only 1 of them is counted in checked
// Total: 116 checked & counted tests + 3 checked & uncounted tests
`timescale 1ns/1ps

module tb_scorer;
    localparam DIGIT_W = 4;
    localparam SCORE_W = 3;

    // DUT connections
    reg                clk, rst, vld_in;
    reg  [DIGIT_W-1:0] ref4, ref3, ref2, ref1, ref0;
    reg  [DIGIT_W-1:0] guess4, guess3, guess2, guess1, guess0;
    wire [SCORE_W-1:0] plus, minus;
    wire               vld_out;

    scorer #(.DIGIT_W(DIGIT_W), .SCORE_W(SCORE_W)) dut (
        .clk(clk), .rst(rst), .vld_in(vld_in),
        .ref4(ref4), .ref3(ref3), .ref2(ref2), .ref1(ref1), .ref0(ref0),
        .guess4(guess4), .guess3(guess3), .guess2(guess2), .guess1(guess1), .guess0(guess0),
        .plus(plus), .minus(minus), .vld_out(vld_out)
    );

    // clock: 10 ns period
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // scoreboard FIFO + counters
    reg [SCORE_W-1:0]   exp_plus  [0:1023];
    reg [SCORE_W-1:0]   exp_minus [0:1023];
    reg [DIGIT_W*5-1:0] exp_ref   [0:1023];   // secret code, kept for printing
    reg [DIGIT_W*5-1:0] exp_guess [0:1023];   // guess code,  kept for printing
    integer wr_ptr, rd_ptr;
    integer pass, fail;

    // temporary variables
    reg [SCORE_W-1:0] ep_tb, em_tb; 
    reg [DIGIT_W-1:0] rr4, rr3, rr2, rr1, rr0, gg4, gg3, gg2, gg1, gg0;
    integer n;

    // golden model: expected (plus, minus) for a (ref, guess) pair
    task golden;
        input [DIGIT_W-1:0] r4, r3, r2, r1, r0;
        input [DIGIT_W-1:0] g4, g3, g2, g1, g0;
        output [SCORE_W-1:0] o_plus;
        output [SCORE_W-1:0] o_minus;
        integer v, cr, cg, tot, pl;
        begin
            pl = (r4==g4) + (r3==g3) + (r2==g2) + (r1==g1) + (r0==g0); // plus count
            tot = 0;
            for (v = 0; v < 10; v = v + 1) begin
                cr = (r4==v) + (r3==v) + (r2==v) + (r1==v) + (r0==v); // count of digit v in reference
                cg = (g4==v) + (g3==v) + (g2==v) + (g1==v) + (g0==v); // count of digit v in guess
                tot = tot + ((cr < cg) ? cr : cg);
            end
            o_plus  = pl;
            o_minus = tot - pl;
        end
    endtask

    // checker: on every vld_out pulse, match against the FIFO head
    always @(negedge clk) begin
        if (vld_out === 1'b1) begin
            if (rd_ptr == wr_ptr) begin
                $display("[%0t] ERROR: unexpected vld_out (scoreboard empty), got (+%0d -%0d)",
                         $time, plus, minus);
                fail = fail + 1;
            end else begin
                // secret code, guess code => score
                $display("%0d%0d%0d%0d%0d, %0d%0d%0d%0d%0d => +%0d -%0d",
                         exp_ref[rd_ptr][4*DIGIT_W +: DIGIT_W], exp_ref[rd_ptr][3*DIGIT_W +: DIGIT_W],
                         exp_ref[rd_ptr][2*DIGIT_W +: DIGIT_W], exp_ref[rd_ptr][1*DIGIT_W +: DIGIT_W],
                         exp_ref[rd_ptr][0*DIGIT_W +: DIGIT_W],
                         exp_guess[rd_ptr][4*DIGIT_W +: DIGIT_W], exp_guess[rd_ptr][3*DIGIT_W +: DIGIT_W],
                         exp_guess[rd_ptr][2*DIGIT_W +: DIGIT_W], exp_guess[rd_ptr][1*DIGIT_W +: DIGIT_W],
                         exp_guess[rd_ptr][0*DIGIT_W +: DIGIT_W],
                         plus, minus);
                if (plus === exp_plus[rd_ptr] && minus === exp_minus[rd_ptr]) begin
                    pass = pass + 1;
                end else begin
                    $display("[%0t] MISMATCH #%0d: got (+%0d -%0d) expected (+%0d -%0d)",
                             $time, rd_ptr, plus, minus, exp_plus[rd_ptr], exp_minus[rd_ptr]);
                    fail = fail + 1;
                end
                rd_ptr = rd_ptr + 1;
            end
        end
    end

    // drivers
    // Present one input: valid on the ph0 cycle, bubble on the following ph1 cycle.
    task apply;
        input [DIGIT_W-1:0] r4, r3, r2, r1, r0;
        input [DIGIT_W-1:0] g4, g3, g2, g1, g0;
        reg [SCORE_W-1:0] ep, em;
        begin
            @(negedge clk);
            ref4=r4; ref3=r3; ref2=r2; ref1=r1; ref0=r0;
            guess4=g4; guess3=g3; guess2=g2; guess1=g1; guess0=g0;
            vld_in = 1'b1;
            golden(r4,r3,r2,r1,r0,g4,g3,g2,g1,g0,ep,em);
            exp_plus[wr_ptr]  = ep;
            exp_minus[wr_ptr] = em;
            exp_ref[wr_ptr]   = {r4,r3,r2,r1,r0};
            exp_guess[wr_ptr] = {g4,g3,g2,g1,g0};
            wr_ptr = wr_ptr + 1;
            @(negedge clk);
            vld_in = 1'b0;
        end
    endtask

    // Empty input slots (each = 2 cycles, keeps ph0 alignment); no output expected.
    task gap;
        input integer slots;
        integer k;
        begin
            vld_in = 1'b0;
            for (k = 0; k < 2*slots; k = k + 1) @(negedge clk);
        end
    endtask

    // Idle cycles to let in-flight results drain out and get checked.
    task drain;
        input integer ncyc;
        integer k;
        begin
            vld_in = 1'b0;
            for (k = 0; k < ncyc; k = k + 1) @(negedge clk);
        end
    endtask

    // Synchronous reset pulse, then one idle cycle (DUT waits, run=0).
    task do_reset;
        begin
            @(negedge clk);
            rst = 1'b1; vld_in = 1'b0;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
        end
    endtask

    // pick a random digit 0..9
    task rand_vec;
        output [DIGIT_W-1:0] a4,a3,a2,a1,a0,b4,b3,b2,b1,b0;
        integer t;
        begin
            t=$random%10; if(t<0) t=t+10; a4=t;
            t=$random%10; if(t<0) t=t+10; a3=t;
            t=$random%10; if(t<0) t=t+10; a2=t;
            t=$random%10; if(t<0) t=t+10; a1=t;
            t=$random%10; if(t<0) t=t+10; a0=t;
            t=$random%10; if(t<0) t=t+10; b4=t;
            t=$random%10; if(t<0) t=t+10; b3=t;
            t=$random%10; if(t<0) t=t+10; b2=t;
            t=$random%10; if(t<0) t=t+10; b1=t;
            t=$random%10; if(t<0) t=t+10; b0=t;
        end
    endtask

    // main sequence
    initial begin
        $dumpfile("scorer_tb.vcd");
        $dumpvars(0, tb_scorer);

        rst=1'b1; vld_in=1'b0;
        ref4=0; ref3=0; ref2=0; ref1=0; ref0=0;
        guess4=0; guess3=0; guess2=0; guess1=0; guess0=0;
        wr_ptr=0; rd_ptr=0; pass=0; fail=0;

        // sanity-check the golden model itself against two specific examples
        golden(9,1,0,1,7,4,1,5,7,1,ep_tb,em_tb);
        if (ep_tb!==1 || em_tb!==2) begin
            $display("GOLDEN MODEL BUG: 91017 vs 41571 gave (+%0d -%0d), expected (+1 -2)", ep_tb, em_tb);
            fail = fail + 1;
        end
        golden(1,4,1,4,1,0,1,0,0,0,ep_tb,em_tb);
        if (ep_tb!==0 || em_tb!==1) begin
            $display("GOLDEN MODEL BUG: 14141 vs 01000 gave (+%0d -%0d), expected (+0 -1)", ep_tb, em_tb);
            fail = fail + 1;
        end

        // directed cases (back-to-back, full cycle time=2 stream)
        do_reset;
        $display("\nDirected Case Scores:");
        apply(9,1,0,1,7, 4,1,5,7,1);   // +1 -2  specific example 1
        apply(1,4,1,4,1, 0,1,0,0,0);   // +0 -1  specific example 2
        apply(1,2,3,4,5, 1,2,3,4,5);   // +5 -0  full match
        apply(0,0,0,0,0, 1,1,1,1,1);   // +0 -0  zero overlap
        apply(1,2,3,4,5, 5,4,3,2,1);   // +1 -4  permutation
        apply(1,1,1,1,1, 1,1,0,0,0);   // +2 -0  repeats
        apply(1,2,1,2,1, 2,1,2,1,2);   // +0 -4  repeats, all minus
        apply(4,1,5,7,1, 9,1,0,1,7);   // +1 -2  swap of example 1 (scorer symmetry)
        apply(0,1,0,0,0, 1,4,1,4,1);   // +0 -1  swap of example 2 (scorer symmetry)
        apply(0,0,0,1,2, 2,1,0,0,0);   // +1 -4  leading zeros
        apply(9,9,9,9,9, 9,9,9,9,9);   // +5 -0  another full match
        apply(1,2,3,4,0, 0,4,3,2,1);   // +1 -4
        drain(8);

        // gaps between valid inputs (bubbles must yield vld_out = 0)
        do_reset;
        $display("\nGap Test Scores:");
        apply(9,1,0,1,7, 4,1,5,7,1);
        gap(1);
        apply(1,2,3,4,5, 1,2,3,4,5);
        gap(2);
        apply(0,0,0,0,0, 1,1,1,1,1);
        drain(8);

        // random stream at full throughput
        do_reset;
        $display("\nRandom Test Scores:");
        for (n = 0; n < 100; n = n + 1) begin
            rand_vec(rr4,rr3,rr2,rr1,rr0, gg4,gg3,gg2,gg1,gg0);
            apply(rr4,rr3,rr2,rr1,rr0, gg4,gg3,gg2,gg1,gg0);
        end
        drain(8);

        // reset asserted while an input is in flight: must flush + restart
        do_reset;
        $display("\nReset Test Scores:");
        apply(7,7,7,7,7, 7,7,7,0,0);          // loaded, then killed by reset below
        @(negedge clk); rst = 1'b1; vld_in = 1'b0;
        for (n = 0; n < 4; n = n + 1) begin
            @(negedge clk);
            if (vld_out !== 1'b0) begin
                $display("[%0t] ERROR: vld_out asserted during reset", $time);
                fail = fail + 1;
            end
        end
        rst = 1'b0;
        rd_ptr = wr_ptr;                       
        @(negedge clk);
        apply(9,1,0,1,7, 4,1,5,7,1);           // restart; must score +1 -2
        drain(8);

        // report
        $display("");
        $display("================ TB SUMMARY ================");
        $display("  checked : %0d", pass + fail);
        $display("  passed  : %0d", pass);
        $display("  failed  : %0d", fail);
        if (rd_ptr !== wr_ptr)
            $display("  WARNING : %0d expected result(s) never appeared", wr_ptr - rd_ptr);
        if (fail == 0 && rd_ptr === wr_ptr)
            $display("  RESULT  : ALL TESTS PASSED");
        else
            $display("  RESULT  : TESTS FAILED");
        $display("============================================");
        $finish;
    end

    // safety net: stop a runaway simulation
    initial begin
        #500000;
        $display("ERROR: timeout - simulation did not finish");
        $finish;
    end

endmodule
