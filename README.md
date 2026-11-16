# MasterMind Scorer — Methodology and Results

## 1. Design Methodology

**Function.** 
The `scorer` unit compares two 5-digit base-10 numbers (a reference code and a guess code (five 4-bit nibbles, 20 bits each)) and returns the MasterMind score `(plus, minus)`. `plus` is the number of digits matching in both value and position; `minus` is the number of remaining value matches under a one-to-one pairing. The score is computed as:

- `plus = Σ_i (ref[i] == guess[i])` ⇒ positional (exact) matches;
- `total = Σ_{d=0..9} min(count_ref(d), count_guess(d))` ⇒ per-value one-to-one matches;
- `minus = total − plus`.

**Modules**
- `histogram` — combinational; counts how many of the five digits equal each value 0–9 (ten 3-bit bins).
- `plus_count` — combinational; counts the five positional equalities.
- `minsum5` — combinational; sums `min(a_i, b_i)` over five histogram-bin pairs.
- `scorer` — sequential top level that time-shares the three units above.

**Architecture — functional pipeline with folding**
The scorer has a **latency of 4 cycles** and a **cycle time of 2 cycles** (a new input is accepted every 2 cycles). The four logical pipeline stages are folded onto **two physical engines (stages)**, each reused across a 2-cycle window by a 2-phase heartbeat (`ph0`/`ph1`):

**Histogram engine:** one shared `histogram` computes the reference histogram on `ph0` and the guess histogram on `ph1`; `plus_count` runs on `ph0`. Folding the reference and guess passes onto a single unit halves the histogram hardware.

**Min-sum engine:** one shared 5-wide `minsum5` reduces histogram bins 0–4 on `ph0` and bins 5–9 on `ph1`, then forms `minus = total − plus`. Folding the two bin-halves onto a single 5-wide reducer halves the reduction hardware versus a 10-wide unit.

Data flows through four register layers. A single 1-bit phase FSM drives the folding multiplexers; `vld_in` anchors `ph0` after reset, after which the 2-cycle heartbeat free-runs and `vld_out` is produced as a 1-cycle pulse four cycles after each input.

## 2. Behavioral Simulation

**Testbench (`tb_scorer.v`).** The testbench is self-checking. An independent golden model computes the expected `(plus, minus)` for each pair from software histograms, and is itself sanity-checked against the two worked specification examples before any stimulus is applied. Because a result appears 4 cycles after its input while a new input enters every 2 cycles (up to two inputs in flight at once), a FIFO scoreboard enqueues each expected result when the input is applied and dequeues/compares it when the matching `vld_out` pulse appears; an unexpected pulse (empty scoreboard) is also flagged as an error. For visibility, the testbench also prints every result to the console as `secret, guess => +plus -minus`, grouped under per-category headers (Directed / Gap / Random / Reset).

**Stimulus.** Inputs are driven on the anchored `ph0` phase. The suite contains 12 directed cases (the two specification examples, full match, zero overlap, permutation, repeated digits, swap-symmetry, leading zeros), 3 cases separated by input gaps (verifying that bubbles produce no output), 100 random vectors at full throughput, and a mid-stream reset (verifying that the pipeline flushes and re-anchors).

**Result.** 
Every check passes:
================ TB SUMMARY ================
  checked : 116
  passed  : 116
  failed  : 0

The 116 checked outputs are 12 directed + 3 gapped + 100 random + 1 post-reset vector; the deliberately flushed reset vector produces no output, and the two golden self-checks are software assertions that are not counted as DUT output pulses.

## 3. Synthesis

**Setup.** Synthesized with Vivado 2025.2, top module `scorer`, target device `xcku5p-ffva676-3-e` (Kintex UltraScale+). The clock is constrained to **1 ns (1 GHz)** via `create_clock` in `constraints.xdc` (deliberately over-constrained, far above the achievable frequency, to push the synthesizer toward maximum-speed optimization). No I/O-delay or pin constraints were applied. Synthesis completed with **0 errors, 0 warnings, and 0 critical warnings**.

**Utilization**
**Resource => Used** 
CLB LUTs => 177 
CLB registers (flip-flops, all FDRE) => 134 
Registers inferred as latch => 0 
DSP / Block RAM => 0 / 0 
Bonded IOB => 50 
Global clock buffer (BUFGCE) => 1 

The 134 flip-flops match the design's register count exactly and no latches were inferred, confirming the intended combinational/sequential split. The folding is directly visible in the RTL component statistics: **12 five-input adders** (10 histogram bins + 1 `plus_count` + 1 `minsum5`) confirm a single shared histogram and a single 5-wide reducer rather than duplicated units, and the fold multiplexers are present (two 15-bit muxes for the bin-half select, five 4-bit muxes for the reference/guess select). The phase-gated "hold" defaults were mapped to native flip-flop clock enables (FDRE).

**Timing (1 ns clock, post-synthesis)**
Check | Worst slack | Failing endpoints | Status 
----- | ----------- | ----------------- | ------ 
Setup |  −0.449 ns  |      17 / 240     | not met (over-constrained)  
Hold  |  −0.079 ns  |      45 / 240     | artifact — closes in implementation
PW    |  −0.122 ns  |       1 / 135     | artifact — period below clock minimum

The 1 ns target is intentionally beyond what the design can reach, so the useful information is the worst-case path it reveals, not whether 1 ns is met. From the setup slack, the worst register-to-register path is `1 − (−0.449) = 1.449 ns`, a **post-synthesis maximum-frequency estimate of ≈690 MHz**. 
The −0.079 ns hold result is the usual post-synthesis artifact (hold depends on routing delays that are only estimated before place-and-route, and is closed during implementation). 
The −0.122 ns pulse-width result reflects that a 1 ns period is below the clock network's minimum pulse width; both negative results clear at any feasible period.

## 4. Implementation

**Setup.** The synthesized netlist was placed and routed in Vivado 2025.2 (same device and 1 ns constraint). No pin/location constraints were applied; the 50 I/O ports were auto-placed and no bitstream was generated, as the study targets post-route timing and area rather than a physical device.

**Utilization (post-route)**
**Resource => Used**
CLB LUTs => 175 
CLB registers (flip-flops, all FDRE) => 134
DSP / Block RAM => 0 / 0 
Bonded IOB => 50

Physical optimization trimmed the LUT count slightly (177 → 175); the flip-flop count is unchanged at 134.

**Timing (1 ns clock, post-route)**
Check | Worst slack | Total negative slack | Status 
----- | ----------- | -------------------- | ------ 
Setup |  −0.284 ns  |       −7.739 ns      | not met (over-constrained) 
Hold  |  +0.002 ns  |        0.000 ns      | **met** 
PW    |  −0.122 ns  |       −0.122 ns      | artifact — period below clock minimum 

Routing completed with **0 failed routes** — the design is fully routed. **Hold is now met** (WHS = +0.002 ns, THS = 0): the router added delay on the short paths and closed the hold violations exactly as anticipated from the post-synthesis stage. Setup and pulse-width remain negative only because of the deliberate 1 ns over-constraint. From the post-route setup slack, the worst register-to-register path is `1 − (−0.284) = 1.284 ns`, a **maximum frequency of ≈780 MHz** — the definitive figure, and higher than the post-synthesis estimate because the actual routing delays on this small design are shorter than the pre-route estimate. Estimated total on-chip power is ≈0.51 W (dominated by device static power).

The end-to-end flow therefore confirms a correct (116/116 checks passed), fully routed design that reaches **≈780 MHz** post-route at a final cost of **175 LUTs and 134 flip-flops**, with the area-sharing folding intact (single histogram, single 5-wide reducer).
