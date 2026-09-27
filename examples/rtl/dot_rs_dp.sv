// -----------------------------------------------------------------------------
// dot_rs_dp.sv -- a fixed-point dot product with rounding and saturation,
// written so that the SAME description is either combinational or a four-stage
// pipeline, and nothing else changes.
//
//     y = clamp( round( SUM over i of  c[i] * x[i] ) )
//
// This is the "complex operation" to be staged: four operators of very different
// cost in one expression -- TAPS multiplies, an adder tree, a rounding add and a
// shift, and a two-sided clamp. Writing it as one `always_comb` and hoping for
// the best is how a design ends up with an fmax nobody can explain.
//
// WHERE THE CUTS GO, and why these four:
//
//   stage 1   the products          the multiply is the single biggest lump, and
//                                   the classic place to register (docs/21)
//   stage 2   the adder tree        ceil(log2 TAPS) levels of carry-propagate
//                                   adder, which is the second biggest
//   stage 3   round and shift       one more add, then a fixed shift, which is
//                                   free (it is wiring)
//   stage 4   clamp                 two comparisons and a mux
//
// Stage 3 looks too small to deserve a stage of its own, and on its own it is.
// It is a stage because of what it is NEXT to: fusing it into stage 2 puts an
// extra carry-propagate add after the tree, and fusing it into stage 4 puts the
// add in front of the comparators, whose results then depend on it. Either
// fusion makes one stage clearly the worst, and the worst stage sets the clock.
//
// ONE DESCRIPTION, ANY CUT SET. CUTS is a four-bit mask: bit k makes cut k a
// register, and a zero leaves it a wire. CUTS=4'b0000 is the combinational
// version, 4'b1111 the four-stage pipeline, and everything between is a cut set
// you can measure before committing to it:
//
//     CUTS   latency   longest combinational path, in gates, at the defaults
//     0000      0       47      <- one lump; fmax set by all of it
//     1111      4       38      <- four stages, and barely better. See below.
//
// The arithmetic therefore exists exactly once in the source and cannot drift
// between the pipelined design and the combinational reference it is proved
// against (formal/dot_rs_fv.sby). It is also the shape retiming likes -- docs/21
// section 6 -- because the operators sit between boundaries the tool can move.
//
// AND THE MEASUREMENT IS THE LESSON: four cuts bought 20%, because at these
// widths ONE OPERATOR IS MOST OF THE PATH. A 10x9 multiplier mapped to gates is
// about thirty levels deep, so stage 1 alone is nearly as long as the whole
// unpipelined expression, and no arrangement of cuts AROUND the operators can do
// better than the worst operator. The answers are to cut INSIDE the multiplier
// (or let a DSP block's internal registers do it -- docs/21 section 12), or to
// accept the clock the multiplier gives you. What you must not do is add stages
// and assume they helped: measure. docs/38 section 3 has the sweep.
//
// NO FLOW CONTROL HERE. This module has per-cut advance enables and no notion
// of valid, ready or flush. A global stall drives all four enables from one
// wire (dot_rs_global.sv); an elastic scheme drives them separately
// (dot_rs_elastic.sv). The datapath cannot tell the difference, which is the
// point of docs/38: the stall technique is a property of the CONTROL, and every
// technique in that document drives this same datapath.
//
// WIDTHS are computed, not guessed. An accumulator one bit short is a wrap, and
// a wrap here is a sample at the wrong end of the scale. See docs/18.
// -----------------------------------------------------------------------------
`default_nettype none

module dot_rs_dp #(
  parameter int unsigned TAPS   = 4,      // terms in the dot product
  parameter int unsigned XW     = 8,      // sample width, unsigned
  parameter int unsigned CW     = 10,     // coefficient width, signed
  parameter int unsigned CF     = 8,      // coefficient fraction bits
  parameter int unsigned YW     = 8,      // output width, unsigned, saturated
  // Bit k = 1 makes cut k a register. 4'b1111 = four stages, 4'b0000 = pure
  // combinational. Latency is the number of bits set.
  parameter logic [3:0]  CUTS   = 4'b1111
) (
  input  var logic                 clk,
  input  var logic                 rst_n,

  // Cut k advances when adv[ CUT_IX(k) ] is high, where CUT_IX(k) counts the
  // enabled cuts below k -- so a control block with LATENCY stages drives
  // adv[LATENCY-1:0] and the unused bits are ignored.
  input  var logic [3:0]           adv,

  input  var logic [TAPS*XW-1:0]   x,     // samples,      unsigned
  input  var logic [TAPS*CW-1:0]   c,     // coefficients, signed, CF fraction bits
  output var logic [YW-1:0]        y
);

  // `pipe_pkg::cuts_below(CUTS, 4)` is the latency; `cuts_below(CUTS, k)` is
  // which control stage owns cut k. Shared with the control wrappers through the
  // package so the two cannot disagree about the depth.
  localparam int unsigned LATENCY = pipe_pkg::cuts_below(CUTS, 4);

  localparam int unsigned PW   = CW + XW + 1;                  // one product
  localparam int unsigned TSUM = (TAPS <= 1) ? 1 : $clog2(TAPS);
  localparam int unsigned SW   = PW + TSUM + 1;                // tree + rounding
  localparam logic signed [SW-1:0] SAT_MAX = SW'((1 << YW) - 1);

  if (CF >= CW) begin : g_chk_cf
    $error("dot_rs_dp: CF (%0d) must be < CW (%0d)", CF, CW);
  end
  if (TAPS < 1) begin : g_chk_taps
    $error("dot_rs_dp: TAPS must be >= 1");
  end

  // ---- stage 1: the products ------------------------------------------------
  logic signed [PW-1:0] p_d [TAPS];
  logic signed [PW-1:0] p_q [TAPS];

  always_comb begin
    for (int i = 0; i < int'(TAPS); i++)
      // Widened AND signed before the multiply. One unsigned operand would make
      // the whole expression unsigned and the >>> below a logical shift --
      // docs/17 trap T6b. The {1'b0, ...} is what makes an unsigned sample into
      // a non-negative signed value.
      p_d[i] = PW'($signed(c[i*CW +: CW])) * PW'($signed({1'b0, x[i*XW +: XW]}));
  end

  if (CUTS[0]) begin : g_cut1
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        for (int i = 0; i < int'(TAPS); i++) p_q[i] <= '0;
      end else if (adv[pipe_pkg::cuts_below(CUTS, 0)]) begin
        for (int i = 0; i < int'(TAPS); i++) p_q[i] <= p_d[i];
      end
    end
  end else begin : g_wire1
    always_comb for (int i = 0; i < int'(TAPS); i++) p_q[i] = p_d[i];
  end

  // ---- stage 2: the adder tree ---------------------------------------------
  logic signed [SW-1:0] sum_d, sum_q;

  always_comb begin
    // A TREE, not a chain: pairwise, halving the live partial sums each round,
    // so the depth is ceil(log2 TAPS) rather than TAPS. Written as a procedural
    // loop because it is a reduction -- see docs/37 section 4.3, and docs/21
    // section 12 for why the chain version is the more common mistake.
    logic signed [SW-1:0] part [TAPS];
    for (int i = 0; i < int'(TAPS); i++) part[i] = SW'(p_q[i]);
    for (int s = 1; s < int'(TAPS); s = s * 2)
      for (int i = 0; i + s < int'(TAPS); i = i + 2*s)
        part[i] = part[i] + part[i + s];
    sum_d = part[0];
  end

  if (CUTS[1]) begin : g_cut2
    always_ff @(posedge clk or negedge rst_n) begin
      if      (!rst_n)                   sum_q <= '0;
      else if (adv[pipe_pkg::cuts_below(CUTS, 1)]) sum_q <= sum_d;
    end
  end else begin : g_wire2
    always_comb sum_q = sum_d;
  end

  // ---- stage 3: round half away from zero, then shift ----------------------
  logic signed [SW-1:0] sh_d, sh_q;

  always_comb begin
    sh_d = (sum_q + ((CF == 0) ? SW'(0) : (SW'(1) <<< (CF - 1)))) >>> CF;
  end

  if (CUTS[2]) begin : g_cut3
    always_ff @(posedge clk or negedge rst_n) begin
      if      (!rst_n)                   sh_q <= '0;
      else if (adv[pipe_pkg::cuts_below(CUTS, 2)]) sh_q <= sh_d;
    end
  end else begin : g_wire3
    always_comb sh_q = sh_d;
  end

  // ---- stage 4: clamp ------------------------------------------------------
  logic [YW-1:0] y_d;

  always_comb begin
    // Clamp, never wrap: clipping is visible and ordinary, wrapping turns a
    // full-scale sample into a near-zero one.
    if      (sh_q < 0)       y_d = '0;
    else if (sh_q > SAT_MAX) y_d = YW'(SAT_MAX);
    else                     y_d = sh_q[YW-1:0];
  end

  if (CUTS[3]) begin : g_cut4
    always_ff @(posedge clk or negedge rst_n) begin
      if      (!rst_n)                   y <= '0;
      else if (adv[pipe_pkg::cuts_below(CUTS, 3)]) y <= y_d;
    end
  end else begin : g_wire4
    always_comb y = y_d;
  end

`ifdef FORMAL
  // The clamp is a clamp. Stated on sh_q, where the unclamped value is visible.
  always @* begin
    f_clamp_lo : assert (!(sh_q < 0)       || (y_d == '0));
    f_clamp_hi : assert (!(sh_q > SAT_MAX) || (y_d == YW'(SAT_MAX)));
    f_clamp_id : assert ((sh_q < 0) || (sh_q > SAT_MAX) ||
                         (SW'($signed({1'b0, y_d})) == sh_q));
  end
`endif

endmodule

`default_nettype wire
